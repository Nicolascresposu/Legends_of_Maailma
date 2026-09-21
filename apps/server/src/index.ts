import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { WebSocket, WebSocketServer } from 'ws';
import type { ServerMessage } from '@maailma/protocol';
import { isClientMessage } from '@maailma/protocol';
import { createApp } from './app.js';
import { createLoggerFromEnv, errorFields, type Logger } from './logger.js';
import { MatchManager } from './match-manager.js';
import { LobbyHub } from './lobby.js';
import { databaseReachable, prisma } from './db/prisma.js';
import { AccountService } from './services/account-service.js';
import { DeckService } from './services/deck-service.js';
import { SocialService } from './services/social-service.js';
import { CollectionService } from './services/collection-service.js';

const port = Number(process.env.PORT ?? 3000);
const logger = createLoggerFromEnv();
const manager = new MatchManager();
const lobby = new LobbyHub(logger);
const accounts = new AccountService(prisma);
const collections = new CollectionService(prisma);
const decks = new DeckService(prisma, collections);
const social = new SocialService(prisma);
const server = createServer(
  createApp(manager, logger, {
    accounts,
    decks,
    social,
    collections,
    lobby,
    databaseReachable: () => databaseReachable(),
  }),
);
const sockets = new Map<string, Set<WebSocket>>();
const sessions = new Map<WebSocket, { matchId: string; playerId: string; log: Logger }>();
// Two socket endpoints share one HTTP server, so neither may attach its own
// `upgrade` listener: whichever ran first would destroy sockets meant for the
// other. Both are created detached and fed by the single router below.
const websocketServer = new WebSocketServer({ noServer: true });
const lobbyServer = new WebSocketServer({ noServer: true });

server.on('upgrade', (request, socket, head) => {
  const pathname = new URL(request.url ?? '/', 'http://localhost').pathname;
  if (pathname === '/matches') {
    websocketServer.handleUpgrade(request, socket, head, (ws) =>
      websocketServer.emit('connection', ws, request),
    );
    return;
  }
  if (pathname === '/lobby') {
    lobbyServer.handleUpgrade(request, socket, head, (ws) =>
      lobbyServer.emit('connection', ws, request),
    );
    return;
  }
  socket.destroy();
});

/**
 * The lobby socket carries challenge and friend notifications.
 *
 * The token arrives as a query parameter because browsers cannot set headers
 * on a WebSocket handshake. It is never logged.
 */
lobbyServer.on('connection', (socket, request) => {
  const connectionId = randomUUID();
  const log = logger.child({ connectionId, channel: 'lobby' });
  const url = new URL(request.url ?? '/lobby', 'http://localhost');
  const token = url.searchParams.get('token') ?? undefined;

  accounts
    .authenticate(token)
    .then((user) => {
      if (!user) {
        log.warn('Lobby connection rejected');
        socket.send(
          JSON.stringify({ type: 'ERROR', code: 'UNAUTHENTICATED', message: 'Sign in first' }),
        );
        socket.close();
        return;
      }
      lobby.register(user.id, socket);
      log.info('Lobby connected', { userId: user.id, displayName: user.displayName });
      socket.send(JSON.stringify({ type: 'LOBBY_READY', userId: user.id }));
      socket.on('close', () => {
        lobby.unregister(socket);
        log.info('Lobby disconnected', { userId: user.id });
      });
    })
    .catch((error: unknown) => {
      log.error('Lobby authentication failed', errorFields(error));
      socket.close();
    });

  socket.on('error', (error) => log.error('Lobby socket error', errorFields(error)));
});

websocketServer.on('connection', (socket) => {
  const connectionId = randomUUID();
  const connectionLog = logger.child({ connectionId });
  connectionLog.debug('WebSocket connected');
  socket.once('close', () => connectionLog.debug('WebSocket disconnected'));
  socket.on('error', (error) => connectionLog.error('WebSocket error', errorFields(error)));

  socket.on('message', (raw) => {
    const log = sessions.get(socket)?.log ?? connectionLog;
    try {
      const message: unknown = JSON.parse(raw.toString());
      if (!isClientMessage(message)) {
        log.warn('Rejected unknown message', { bytes: raw.toString().length });
        return send(socket, { type: 'ERROR', code: 'BAD_MESSAGE', message: 'Unknown message' });
      }
      log.debug('Message received', { messageType: message.type });
      if (message.type === 'JOIN_MATCH') {
        const engine = manager.get(message.matchId);
        if (!engine || !engine.state.sides[message.playerId]) {
          log.warn('Join rejected', { matchId: message.matchId, playerId: message.playerId });
          return send(socket, {
            type: 'ERROR',
            code: 'JOIN_REJECTED',
            message: 'Match or player not found',
          });
        }
        const room = sockets.get(message.matchId) ?? new Set<WebSocket>();
        room.add(socket);
        sockets.set(message.matchId, room);
        const sessionLog = connectionLog.child({
          matchId: message.matchId,
          playerId: message.playerId,
        });
        sessions.set(socket, {
          matchId: message.matchId,
          playerId: message.playerId,
          log: sessionLog,
        });
        sessionLog.info('Player joined match', { room: room.size });
        socket.once('close', () => {
          room.delete(socket);
          sessions.delete(socket);
          if (room.size === 0) sockets.delete(message.matchId);
          sessionLog.info('Player left match', { room: room.size });
        });
        send(socket, { type: 'MATCH_STATE', state: engine.state });
        send(socket, {
          type: 'LEGAL_ACTIONS',
          playerId: message.playerId,
          actions: engine.getLegalActions(message.playerId),
        });
        return;
      }
      const session = sessions.get(socket);
      if (message.type === 'SELECT_HERO') {
        if (
          !session ||
          session.matchId !== message.matchId ||
          session.playerId !== message.playerId
        ) {
          log.warn('Hero selection rejected: actor mismatch', {
            matchId: message.matchId,
            playerId: message.playerId,
          });
          return send(socket, {
            type: 'ERROR',
            code: 'ACTOR_MISMATCH',
            message: 'Join the match as this player before selecting a Hero',
          });
        }
        try {
          manager.selectHero(message.matchId, message.playerId, message.heroDefinitionId);
          log.info('Hero selected', { heroDefinitionId: message.heroDefinitionId });
          broadcast(message.matchId, {
            type: 'MATCH_STATE',
            state: manager.get(message.matchId)!.state,
          });
        } catch (error) {
          log.warn('Hero selection rejected', {
            heroDefinitionId: message.heroDefinitionId,
            ...errorFields(error),
          });
          send(socket, {
            type: 'ERROR',
            code: 'HERO_SELECTION_REJECTED',
            message: error instanceof Error ? error.message : 'Hero selection failed',
          });
        }
        return;
      }
      if (
        !session ||
        session.matchId !== message.matchId ||
        session.playerId !== message.action.actorId
      ) {
        log.warn('Action rejected: actor mismatch', {
          matchId: message.matchId,
          actionType: message.action.type,
          actorId: message.action.actorId,
        });
        return send(socket, {
          type: 'ERROR',
          code: 'ACTOR_MISMATCH',
          message: 'Join the match as the action actor before submitting actions',
        });
      }
      const result = manager.act(message.matchId, message.action);
      if (!result.ok) {
        log.info('Action rejected', {
          actionType: message.action.type,
          code: result.error!.code,
          reason: result.error!.message,
        });
        return send(socket, {
          type: 'ERROR',
          code: result.error!.code,
          message: result.error!.message,
        });
      }
      const engine = manager.get(message.matchId)!;
      log.debug('Action applied', {
        actionType: message.action.type,
        events: result.events.length,
        turn: engine.state.turn,
        phase: engine.state.phase,
      });
      broadcast(message.matchId, { type: 'GAME_EVENTS', events: result.events });
      broadcast(message.matchId, { type: 'MATCH_STATE', state: engine.state });
      broadcast(message.matchId, {
        type: 'TURN_CHANGED',
        activePlayerId: engine.state.activePlayerId,
        turn: engine.state.turn,
      });
      if (engine.state.phase === 'FINISHED') {
        log.info('Match ended', {
          turn: engine.state.turn,
          ...(engine.state.winnerId ? { winnerId: engine.state.winnerId } : {}),
        });
        broadcast(message.matchId, {
          type: 'MATCH_ENDED',
          ...(engine.state.winnerId ? { winnerId: engine.state.winnerId } : {}),
        });
      } else {
        for (const playerId of engine.state.playerOrder) {
          sendToPlayer(message.matchId, playerId, {
            type: 'LEGAL_ACTIONS',
            playerId,
            actions: engine.getLegalActions(playerId),
          });
        }
      }
    } catch (error) {
      // Malformed input is a client fault; anything else is the server's.
      if (error instanceof SyntaxError) log.warn('Rejected malformed message', errorFields(error));
      else log.error('Message handling failed', errorFields(error));
      send(socket, {
        type: 'ERROR',
        code: 'BAD_MESSAGE',
        message: error instanceof Error ? error.message : 'Unknown error',
      });
    }
  });
});

function send(socket: WebSocket, message: ServerMessage): void {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

function broadcast(matchId: string, message: ServerMessage): void {
  for (const socket of sockets.get(matchId) ?? []) send(socket, message);
}

function sendToPlayer(matchId: string, playerId: string, message: ServerMessage): void {
  for (const socket of sockets.get(matchId) ?? []) {
    if (sessions.get(socket)?.playerId === playerId) send(socket, message);
  }
}

server.listen(port, () =>
  logger.info('Maailma server listening', { url: `http://localhost:${port}`, port }),
);
