import { createServer } from 'node:http';
import { WebSocket, WebSocketServer } from 'ws';
import type { ServerMessage } from '@maailma/protocol';
import { isClientMessage } from '@maailma/protocol';
import { createApp } from './app.js';
import { MatchManager } from './match-manager.js';

const port = Number(process.env.PORT ?? 3000);
const manager = new MatchManager();
const server = createServer(createApp(manager));
const sockets = new Map<string, Set<WebSocket>>();
const sessions = new Map<WebSocket, { matchId: string; playerId: string }>();
const websocketServer = new WebSocketServer({ server, path: '/matches' });

websocketServer.on('connection', (socket) => {
  socket.on('message', (raw) => {
    try {
      const message: unknown = JSON.parse(raw.toString());
      if (!isClientMessage(message))
        return send(socket, { type: 'ERROR', code: 'BAD_MESSAGE', message: 'Unknown message' });
      if (message.type === 'JOIN_MATCH') {
        const engine = manager.get(message.matchId);
        if (!engine || !engine.state.sides[message.playerId]) {
          return send(socket, {
            type: 'ERROR',
            code: 'JOIN_REJECTED',
            message: 'Match or player not found',
          });
        }
        const room = sockets.get(message.matchId) ?? new Set<WebSocket>();
        room.add(socket);
        sockets.set(message.matchId, room);
        sessions.set(socket, { matchId: message.matchId, playerId: message.playerId });
        socket.once('close', () => {
          room.delete(socket);
          sessions.delete(socket);
          if (room.size === 0) sockets.delete(message.matchId);
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
          return send(socket, {
            type: 'ERROR',
            code: 'ACTOR_MISMATCH',
            message: 'Join the match as this player before selecting a Hero',
          });
        }
        try {
          manager.selectHero(message.matchId, message.playerId, message.heroDefinitionId);
          broadcast(message.matchId, {
            type: 'MATCH_STATE',
            state: manager.get(message.matchId)!.state,
          });
        } catch (error) {
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
        return send(socket, {
          type: 'ERROR',
          code: 'ACTOR_MISMATCH',
          message: 'Join the match as the action actor before submitting actions',
        });
      }
      const result = manager.act(message.matchId, message.action);
      if (!result.ok)
        return send(socket, {
          type: 'ERROR',
          code: result.error!.code,
          message: result.error!.message,
        });
      const engine = manager.get(message.matchId)!;
      broadcast(message.matchId, { type: 'GAME_EVENTS', events: result.events });
      broadcast(message.matchId, { type: 'MATCH_STATE', state: engine.state });
      broadcast(message.matchId, {
        type: 'TURN_CHANGED',
        activePlayerId: engine.state.activePlayerId,
        turn: engine.state.turn,
      });
      if (engine.state.phase === 'FINISHED') {
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

server.listen(port, () => console.log(`Maailma server listening on http://localhost:${port}`));
