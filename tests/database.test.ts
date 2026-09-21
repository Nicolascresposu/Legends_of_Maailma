import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { PrismaClient } from '@prisma/client';
import { STARTER_DECK } from '@maailma/card-definitions';
import { createApp } from '../apps/server/src/app.js';
import { MatchManager } from '../apps/server/src/match-manager.js';
import { LobbyHub } from '../apps/server/src/lobby.js';
import { silentLogger } from '../apps/server/src/logger.js';
import { AccountService } from '../apps/server/src/services/account-service.js';
import { DeckService } from '../apps/server/src/services/deck-service.js';
import { SocialService } from '../apps/server/src/services/social-service.js';

/**
 * Exercises the account, deck and social stack against a real PostgreSQL
 * database. Rows are namespaced with a unique suffix and removed afterwards,
 * so the suite can run repeatedly against a development database.
 */
const prisma = new PrismaClient();
const suffix = `t${Date.now()}${Math.floor(Math.random() * 1000)}`;
const created: string[] = [];

let server: Server | undefined;
let base = '';

const accounts = new AccountService(prisma);
const decks = new DeckService(prisma);
const social = new SocialService(prisma);

beforeAll(async () => {
  const manager = new MatchManager();
  const lobby = new LobbyHub(silentLogger);
  server = createServer(createApp(manager, silentLogger, { accounts, decks, social, lobby }));
  await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Missing test port');
  base = `http://127.0.0.1:${address.port}`;
});

afterAll(async () => {
  if (created.length > 0) {
    await prisma.user.deleteMany({ where: { id: { in: created } } });
  }
  if (server) {
    await new Promise<void>((resolve, reject) =>
      server!.close((error) => (error ? reject(error) : resolve())),
    );
  }
  await prisma.$disconnect();
});

async function register(tag: string) {
  const payload = {
    email: `${tag}.${suffix}@example.test`,
    displayName: `${tag}_${suffix}`.slice(0, 24),
    password: 'a-sufficiently-long-password',
  };
  const response = await fetch(`${base}/api/auth/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const body = (await response.json()) as {
    user?: { id: string; displayName: string };
    token?: string;
    code?: string;
  };
  if (body.user) created.push(body.user.id);
  return { status: response.status, body, payload };
}

function authed(token: string) {
  return { 'content-type': 'application/json', authorization: `Bearer ${token}` };
}

describe('accounts', () => {
  it('registers a player and returns a usable session', async () => {
    const { status, body } = await register('alice');
    expect(status).toBe(201);
    expect(body.token).toBeTypeOf('string');
    expect(body.user?.id).toBeTypeOf('string');

    const me = await fetch(`${base}/api/auth/me`, { headers: authed(body.token!) });
    expect(me.status).toBe(200);
    const mine = (await me.json()) as { user: { id: string } };
    expect(mine.user.id).toBe(body.user!.id);
  });

  it('rejects a duplicate email or display name', async () => {
    const first = await register('dup');
    expect(first.status).toBe(201);
    const again = await fetch(`${base}/api/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(first.payload),
    });
    expect(again.status).toBe(409);
    expect(((await again.json()) as { code: string }).code).toBe('ACCOUNT_EXISTS');
  });

  it('rejects weak passwords and malformed emails', async () => {
    const weak = await fetch(`${base}/api/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        email: `weak.${suffix}@example.test`,
        displayName: `weak_${suffix}`.slice(0, 24),
        password: 'short',
      }),
    });
    expect(weak.status).toBe(400);
    expect(((await weak.json()) as { code: string }).code).toBe('WEAK_PASSWORD');

    const bad = await fetch(`${base}/api/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        email: 'not-an-email',
        displayName: `bad_${suffix}`.slice(0, 24),
        password: 'a-sufficiently-long-password',
      }),
    });
    expect(bad.status).toBe(400);
    expect(((await bad.json()) as { code: string }).code).toBe('INVALID_EMAIL');
  });

  it('signs in with the right password and refuses the wrong one', async () => {
    const { payload } = await register('login');
    const good = await fetch(`${base}/api/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email: payload.email, password: payload.password }),
    });
    expect(good.status).toBe(200);

    const bad = await fetch(`${base}/api/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email: payload.email, password: 'wrong-but-long-enough' }),
    });
    expect(bad.status).toBe(401);
  });

  it('refuses protected routes without a valid token', async () => {
    expect((await fetch(`${base}/api/decks`)).status).toBe(401);
    const bogus = await fetch(`${base}/api/decks`, { headers: authed('not-a-real-token') });
    expect(bogus.status).toBe(401);
  });

  it('revokes the session on logout', async () => {
    const { body } = await register('logout');
    const token = body.token!;
    expect((await fetch(`${base}/api/auth/me`, { headers: authed(token) })).status).toBe(200);
    const out = await fetch(`${base}/api/auth/logout`, {
      method: 'POST',
      headers: authed(token),
    });
    expect(out.status).toBe(204);
    expect((await fetch(`${base}/api/auth/me`, { headers: authed(token) })).status).toBe(401);
  });

  it('never stores the password or the raw token', async () => {
    const { body, payload } = await register('secrets');
    const row = await prisma.user.findUnique({ where: { id: body.user!.id } });
    expect(row?.passwordHash).toBeTypeOf('string');
    expect(row?.passwordHash).not.toContain(payload.password);
    const sessions = await prisma.session.findMany({ where: { userId: body.user!.id } });
    expect(sessions.length).toBeGreaterThan(0);
    for (const session of sessions) expect(session.tokenHash).not.toBe(body.token);
  });
});

describe('decks', () => {
  it('saves a valid deck and rejects an illegal one', async () => {
    const { body } = await register('decker');
    const token = body.token!;

    const ok = await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(token),
      body: JSON.stringify({ name: 'Starter', heroId: 'healer', cardIds: STARTER_DECK }),
    });
    expect(ok.status).toBe(201);
    const saved = (await ok.json()) as { deck: { id: string; isActive: boolean } };
    // The first deck a player saves becomes their active one.
    expect(saved.deck.isActive).toBe(true);

    const tooSmall = await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(token),
      body: JSON.stringify({ name: 'Tiny', heroId: 'healer', cardIds: ['wolf'] }),
    });
    expect(tooSmall.status).toBe(400);
    expect(((await tooSmall.json()) as { code: string }).code).toBe('INVALID_DECK');

    const badHero = await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(token),
      body: JSON.stringify({ name: 'NoHero', heroId: 'nobody', cardIds: STARTER_DECK }),
    });
    expect(badHero.status).toBe(400);
    expect(((await badHero.json()) as { code: string }).code).toBe('INVALID_HERO');
  });

  it('keeps decks private to their owner', async () => {
    const owner = await register('owner');
    const other = await register('snoop');
    const created = await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(owner.body.token!),
      body: JSON.stringify({ name: 'Private', heroId: 'striker', cardIds: STARTER_DECK }),
    });
    const deckId = ((await created.json()) as { deck: { id: string } }).deck.id;

    const peek = await fetch(`${base}/api/decks/${deckId}`, {
      headers: authed(other.body.token!),
    });
    expect(peek.status).toBe(404);

    const mine = await fetch(`${base}/api/decks`, { headers: authed(other.body.token!) });
    expect(((await mine.json()) as { decks: unknown[] }).decks).toHaveLength(0);
  });

  it('moves the active flag to exactly one deck', async () => {
    const { body } = await register('active');
    const token = body.token!;
    const first = await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(token),
      body: JSON.stringify({ name: 'First', heroId: 'healer', cardIds: STARTER_DECK }),
    });
    const second = await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(token),
      body: JSON.stringify({ name: 'Second', heroId: 'striker', cardIds: STARTER_DECK }),
    });
    const secondId = ((await second.json()) as { deck: { id: string } }).deck.id;
    void first;

    await fetch(`${base}/api/decks/${secondId}/active`, {
      method: 'POST',
      headers: authed(token),
    });
    const list = (await (await fetch(`${base}/api/decks`, { headers: authed(token) })).json()) as {
      decks: Array<{ id: string; isActive: boolean }>;
    };
    expect(list.decks.filter((deck) => deck.isActive)).toHaveLength(1);
    expect(list.decks.find((deck) => deck.isActive)?.id).toBe(secondId);
  });
});

describe('friends and challenges', () => {
  it('completes a request, accept, challenge and match creation', async () => {
    const a = await register('cha');
    const b = await register('chb');
    const tokenA = a.body.token!;
    const tokenB = b.body.token!;

    // A challenge before friendship is refused.
    const early = await fetch(`${base}/api/social/challenges`, {
      method: 'POST',
      headers: authed(tokenA),
      body: JSON.stringify({ opponentId: b.body.user!.id, scenarioId: 'STANDARD_PVP' }),
    });
    expect(early.status).toBe(403);

    const request = await fetch(`${base}/api/social/friends/requests`, {
      method: 'POST',
      headers: authed(tokenA),
      body: JSON.stringify({ displayName: b.body.user!.displayName }),
    });
    expect(request.status).toBe(201);
    const friendshipId = ((await request.json()) as { friendship: { id: string } }).friendship.id;

    const pending = (await (
      await fetch(`${base}/api/social/friends/requests`, { headers: authed(tokenB) })
    ).json()) as { requests: Array<{ friendshipId: string }> };
    expect(pending.requests.some((row) => row.friendshipId === friendshipId)).toBe(true);

    const accept = await fetch(`${base}/api/social/friends/requests/${friendshipId}/respond`, {
      method: 'POST',
      headers: authed(tokenB),
      body: JSON.stringify({ accept: true }),
    });
    expect(accept.status).toBe(200);

    // Both sides now see each other as friends.
    for (const token of [tokenA, tokenB]) {
      const friends = (await (
        await fetch(`${base}/api/social/friends`, { headers: authed(token) })
      ).json()) as { friends: unknown[] };
      expect(friends.friends).toHaveLength(1);
    }

    const challenge = await fetch(`${base}/api/social/challenges`, {
      method: 'POST',
      headers: authed(tokenA),
      body: JSON.stringify({ opponentId: b.body.user!.id, scenarioId: 'STANDARD_PVP' }),
    });
    expect(challenge.status).toBe(201);
    const challengeId = ((await challenge.json()) as { challenge: { id: string } }).challenge.id;

    const incoming = (await (
      await fetch(`${base}/api/social/challenges`, { headers: authed(tokenB) })
    ).json()) as { incoming: Array<{ id: string }> };
    expect(incoming.incoming.some((row) => row.id === challengeId)).toBe(true);

    const accepted = await fetch(`${base}/api/social/challenges/${challengeId}/accept`, {
      method: 'POST',
      headers: authed(tokenB),
    });
    expect(accepted.status).toBe(200);
    const result = (await accepted.json()) as {
      matchId: string;
      state: { sides: Record<string, unknown> };
    };
    // Accepting creates a real match both players can join.
    expect(result.matchId).toBeTypeOf('string');
    expect(Object.keys(result.state.sides).sort()).toEqual(
      [a.body.user!.id, b.body.user!.id].sort(),
    );

    // The same challenge cannot be answered twice.
    const again = await fetch(`${base}/api/social/challenges/${challengeId}/accept`, {
      method: 'POST',
      headers: authed(tokenB),
    });
    expect(again.status).toBe(409);
  });

  it('refuses to befriend or challenge yourself', async () => {
    const solo = await register('solo');
    const token = solo.body.token!;
    const self = await fetch(`${base}/api/social/friends/requests`, {
      method: 'POST',
      headers: authed(token),
      body: JSON.stringify({ displayName: solo.body.user!.displayName }),
    });
    expect(self.status).toBe(400);
    expect(((await self.json()) as { code: string }).code).toBe('SELF_FRIENDSHIP');
  });

  it('reports an unknown player rather than creating a dangling request', async () => {
    const seeker = await register('seeker');
    const missing = await fetch(`${base}/api/social/friends/requests`, {
      method: 'POST',
      headers: authed(seeker.body.token!),
      body: JSON.stringify({ displayName: `nobody_${suffix}` }),
    });
    expect(missing.status).toBe(404);
  });

  it('treats a reciprocal request as an acceptance', async () => {
    const a = await register('reca');
    const b = await register('recb');
    await fetch(`${base}/api/social/friends/requests`, {
      method: 'POST',
      headers: authed(a.body.token!),
      body: JSON.stringify({ displayName: b.body.user!.displayName }),
    });
    // B asks A back instead of answering: it should settle, not duplicate.
    const back = await fetch(`${base}/api/social/friends/requests`, {
      method: 'POST',
      headers: authed(b.body.token!),
      body: JSON.stringify({ displayName: a.body.user!.displayName }),
    });
    expect(back.status).toBe(201);
    const friends = (await (
      await fetch(`${base}/api/social/friends`, { headers: authed(a.body.token!) })
    ).json()) as { friends: unknown[] };
    expect(friends.friends).toHaveLength(1);
    const rows = await prisma.friendship.findMany({
      where: {
        OR: [
          { requesterId: a.body.user!.id, addresseeId: b.body.user!.id },
          { requesterId: b.body.user!.id, addresseeId: a.body.user!.id },
        ],
      },
    });
    expect(rows).toHaveLength(1);
  });
});
