import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { WebSocket, WebSocketServer } from 'ws';
import { randomUUID } from 'node:crypto';
import { PrismaClient } from '@prisma/client';
import { createApp } from '../apps/server/src/app.js';
import { MatchManager } from '../apps/server/src/match-manager.js';
import { LobbyHub } from '../apps/server/src/lobby.js';
import { silentLogger } from '../apps/server/src/logger.js';
import { AccountService } from '../apps/server/src/services/account-service.js';
import { DeckService } from '../apps/server/src/services/deck-service.js';
import { SocialService } from '../apps/server/src/services/social-service.js';
import { CollectionService } from '../apps/server/src/services/collection-service.js';
import { ExpansionService } from '../apps/server/src/services/expansion-service.js';
import { EconomyService } from '../apps/server/src/services/economy-service.js';

/**
 * Covers the lobby socket: authentication, and that a challenge sent over REST
 * reaches a connected opponent as a push.
 */
const prisma = new PrismaClient();
const suffix = `l${Date.now()}${Math.floor(Math.random() * 1000)}`;
const created: string[] = [];

let server: Server | undefined;
let base = '';
let wsBase = '';

const accounts = new AccountService(prisma);
const expansions = new ExpansionService(prisma);
const collections = new CollectionService(prisma, expansions);
const economy = new EconomyService(prisma, expansions);
const decks = new DeckService(prisma, collections);
const social = new SocialService(prisma);
const lobby = new LobbyHub(silentLogger);

beforeAll(async () => {
  const manager = new MatchManager();
  server = createServer(
    createApp(manager, silentLogger, {
      accounts,
      decks,
      social,
      collections,
      expansions,
      economy,
      lobby,
    }),
  );

  // Mirrors the lobby wiring in index.ts.
  const lobbyServer = new WebSocketServer({ noServer: true });
  server.on('upgrade', (upgradeRequest, socket, head) => {
    const pathname = new URL(upgradeRequest.url ?? '/', 'http://localhost').pathname;
    if (pathname !== '/lobby') {
      socket.destroy();
      return;
    }
    lobbyServer.handleUpgrade(upgradeRequest, socket, head, (ws) =>
      lobbyServer.emit('connection', ws, upgradeRequest),
    );
  });
  lobbyServer.on('connection', (socket, request) => {
    const url = new URL(request.url ?? '/lobby', 'http://localhost');
    const token = url.searchParams.get('token') ?? undefined;
    void randomUUID();
    accounts
      .authenticate(token)
      .then((user) => {
        if (!user) {
          socket.send(JSON.stringify({ type: 'ERROR', code: 'UNAUTHENTICATED' }));
          socket.close();
          return;
        }
        lobby.register(user.id, socket);
        socket.send(JSON.stringify({ type: 'LOBBY_READY', userId: user.id }));
        socket.on('close', () => lobby.unregister(socket));
      })
      .catch(() => socket.close());
  });

  await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Missing test port');
  base = `http://127.0.0.1:${address.port}`;
  wsBase = `ws://127.0.0.1:${address.port}`;
});

afterAll(async () => {
  if (created.length > 0) await prisma.user.deleteMany({ where: { id: { in: created } } });
  if (server) {
    await new Promise<void>((resolve, reject) =>
      server!.close((error) => (error ? reject(error) : resolve())),
    );
  }
  await prisma.$disconnect();
});

async function register(tag: string) {
  const response = await fetch(`${base}/api/auth/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: `${tag}.${suffix}@example.test`,
      displayName: `${tag}_${suffix}`.slice(0, 24),
      password: 'a-sufficiently-long-password',
    }),
  });
  const body = (await response.json()) as {
    user: { id: string; displayName: string };
    token: string;
  };
  created.push(body.user.id);
  return body;
}

/** Resolves with the next message of a given type, or rejects on timeout. */
function nextMessage(
  socket: WebSocket,
  type: string,
  timeoutMs = 4000,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${type}`)), timeoutMs);
    const onMessage = (raw: unknown) => {
      const parsed = JSON.parse(String(raw)) as Record<string, unknown>;
      if (parsed.type === type) {
        clearTimeout(timer);
        socket.off('message', onMessage);
        resolve(parsed);
      }
    };
    socket.on('message', onMessage);
  });
}

function connect(token: string): Promise<WebSocket> {
  const socket = new WebSocket(`${wsBase}/lobby?token=${encodeURIComponent(token)}`);
  return new Promise((resolve, reject) => {
    socket.once('open', () => resolve(socket));
    socket.once('error', reject);
  });
}

describe('lobby socket', () => {
  it('rejects a connection without a valid token', async () => {
    const socket = await connect('not-a-real-token');
    const error = await nextMessage(socket, 'ERROR');
    expect(error.code).toBe('UNAUTHENTICATED');
    socket.close();
  });

  it('accepts a signed-in player and reports readiness', async () => {
    const user = await register('ready');
    const socket = await connect(user.token);
    const hello = await nextMessage(socket, 'LOBBY_READY');
    expect(hello.userId).toBe(user.user.id);
    expect(lobby.isOnline(user.user.id)).toBe(true);
    socket.close();
  });

  it('pushes a challenge to a connected opponent', async () => {
    const challenger = await register('pusha');
    const opponent = await register('pushb');

    // Become friends first: challenges are friends-only.
    const request = await fetch(`${base}/api/social/friends/requests`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${challenger.token}` },
      body: JSON.stringify({ displayName: opponent.user.displayName }),
    });
    const friendshipId = ((await request.json()) as { friendship: { id: string } }).friendship.id;
    await fetch(`${base}/api/social/friends/requests/${friendshipId}/respond`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${opponent.token}` },
      body: JSON.stringify({ accept: true }),
    });

    const socket = await connect(opponent.token);
    await nextMessage(socket, 'LOBBY_READY');
    const incoming = nextMessage(socket, 'CHALLENGE_RECEIVED');

    const sent = await fetch(`${base}/api/social/challenges`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${challenger.token}` },
      body: JSON.stringify({ opponentId: opponent.user.id, scenarioId: 'STANDARD_PVP' }),
    });
    expect(sent.status).toBe(201);

    const pushed = await incoming;
    expect(pushed.fromDisplayName).toBe(challenger.user.displayName);
    expect(pushed.scenarioId).toBe('STANDARD_PVP');
    expect(pushed.challengeId).toBeTypeOf('string');
    socket.close();
  });

  it('tells both players the match id when a challenge is accepted', async () => {
    const challenger = await register('acca');
    const opponent = await register('accb');

    const request = await fetch(`${base}/api/social/friends/requests`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${challenger.token}` },
      body: JSON.stringify({ displayName: opponent.user.displayName }),
    });
    const friendshipId = ((await request.json()) as { friendship: { id: string } }).friendship.id;
    await fetch(`${base}/api/social/friends/requests/${friendshipId}/respond`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${opponent.token}` },
      body: JSON.stringify({ accept: true }),
    });

    const challengerSocket = await connect(challenger.token);
    await nextMessage(challengerSocket, 'LOBBY_READY');

    const sent = await fetch(`${base}/api/social/challenges`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${challenger.token}` },
      body: JSON.stringify({ opponentId: opponent.user.id, scenarioId: 'STANDARD_PVP' }),
    });
    const challengeId = ((await sent.json()) as { challenge: { id: string } }).challenge.id;

    // The challenger is waiting and must learn the match id without polling.
    const announced = nextMessage(challengerSocket, 'CHALLENGE_ACCEPTED');
    const accepted = await fetch(`${base}/api/social/challenges/${challengeId}/accept`, {
      method: 'POST',
      headers: { authorization: `Bearer ${opponent.token}` },
    });
    const result = (await accepted.json()) as { matchId: string };
    const push = await announced;
    expect(push.matchId).toBe(result.matchId);
    expect(push.yourPlayerId).toBe(challenger.user.id);
    challengerSocket.close();
  });

  it('drops a user from presence when their socket closes', async () => {
    const user = await register('bye');
    const socket = await connect(user.token);
    await nextMessage(socket, 'LOBBY_READY');
    expect(lobby.isOnline(user.user.id)).toBe(true);
    socket.close();
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(lobby.isOnline(user.user.id)).toBe(false);
  });
});
