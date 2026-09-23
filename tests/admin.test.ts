import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { PrismaClient } from '@prisma/client';
import { STARTER_COLLECTION, starterDeckFor } from '@maailma/card-definitions';
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
import { PackService } from '../apps/server/src/services/pack-service.js';
import { TradeService } from '../apps/server/src/services/trade-service.js';

/**
 * The admin debug API, against a real database: an admin can look inside and
 * reshape any account, every change is on the record, and nobody else can
 * tell the API exists.
 */
const prisma = new PrismaClient();
const suffix = `ad${Date.now()}${Math.floor(Math.random() * 1000)}`;
const created: string[] = [];

let server: Server | undefined;
let base = '';
const manager = new MatchManager();
const expansions = new ExpansionService(prisma);
const collections = new CollectionService(prisma, expansions);
const decks = new DeckService(prisma, collections);
const trades = new TradeService(prisma, expansions);

interface Account {
  id: string;
  token: string;
  displayName: string;
}

let admin: Account;
let player: Account;

beforeAll(async () => {
  server = createServer(
    createApp(manager, silentLogger, {
      accounts: new AccountService(prisma),
      decks,
      social: new SocialService(prisma),
      collections,
      expansions,
      economy: new EconomyService(prisma, expansions),
      packs: new PackService(prisma, expansions),
      trades,
      lobby: new LobbyHub(silentLogger),
      prisma,
    }),
  );
  await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Missing test port');
  base = `http://127.0.0.1:${address.port}`;

  admin = await register('admin');
  await prisma.user.update({ where: { id: admin.id }, data: { isAdmin: true } });
  player = await register('player');
});

afterAll(async () => {
  await prisma.expansionPolicyOverride.deleteMany({});
  if (created.length > 0) await prisma.user.deleteMany({ where: { id: { in: created } } });
  if (server) {
    await new Promise<void>((resolve, reject) =>
      server!.close((error) => (error ? reject(error) : resolve())),
    );
  }
  await prisma.$disconnect();
});

async function register(tag: string): Promise<Account> {
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
  return { id: body.user.id, token: body.token, displayName: body.user.displayName };
}

/** Calls the admin API as `as` (the admin by default). */
async function call(
  method: string,
  path: string,
  body?: unknown,
  as: Account = admin,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const response = await fetch(`${base}/api/admin${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${as.token}` },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await response.text();
  return {
    status: response.status,
    body: text ? (JSON.parse(text) as Record<string, unknown>) : {},
  };
}

async function owned(userId: string, cardId: string): Promise<number> {
  const row = await prisma.collectionEntry.findUnique({
    where: { userId_cardId: { userId, cardId } },
  });
  return row?.quantity ?? 0;
}

describe('who may use it', () => {
  it('answers a signed-in player as though the API did not exist', async () => {
    for (const [method, path] of [
      ['GET', '/'],
      ['GET', '/users'],
      ['PUT', `/users/${player.id}/fragments`],
    ] as const) {
      const result = await call(
        method,
        path,
        method === 'GET' ? undefined : { balance: 9 },
        player,
      );
      expect(result.status, path).toBe(404);
    }
    // And nothing happened.
    expect((await call('GET', `/users/${player.id}`)).body.user).toMatchObject({ fragments: 0 });
  });

  it('refuses anyone not signed in', async () => {
    const response = await fetch(`${base}/api/admin/users`);
    expect(response.status).toBe(401);
  });

  it('confirms an admin', async () => {
    const result = await call('GET', '/');
    expect(result.status).toBe(200);
    expect(result.body.ok).toBe(true);
  });
});

describe('accounts', () => {
  it('finds accounts by name or email', async () => {
    const result = await call('GET', `/users?search=${encodeURIComponent(player.displayName)}`);
    const users = result.body.users as Array<{ id: string }>;
    expect(users.map((user) => user.id)).toContain(player.id);
  });

  it('shows everything about one account at once', async () => {
    const result = await call('GET', `/users/${player.id}`);
    expect(result.status).toBe(200);
    expect(result.body.user).toMatchObject({ id: player.id, isAdmin: false });
    expect(result.body.collection).toMatchObject({ distinctCards: STARTER_COLLECTION.size });
    expect(result.body).toHaveProperty('decks');
    expect(result.body).toHaveProperty('social');
    expect(result.body).toHaveProperty('recentLedger');
  });

  it('reports an account that does not exist', async () => {
    const result = await call('GET', '/users/no-such-user');
    expect(result.status).toBe(404);
    expect(result.body.code).toBe('USER_NOT_FOUND');
  });

  it('grants admin rights, but will not let an admin remove their own', async () => {
    const other = await register('promote');
    expect((await call('PATCH', `/users/${other.id}`, { isAdmin: true })).body).toMatchObject({
      isAdmin: true,
    });
    expect((await call('PATCH', `/users/${other.id}`, { isAdmin: false })).body).toMatchObject({
      isAdmin: false,
    });
    const self = await call('PATCH', `/users/${admin.id}`, { isAdmin: false });
    expect(self.status).toBe(409);
    expect(self.body.code).toBe('SELF_DEMOTION');
  });

  it('signs in as a player, and can sign them out everywhere', async () => {
    const target = await register('imperson');
    const issued = await call('POST', `/users/${target.id}/sessions`);
    expect(issued.status).toBe(201);
    const token = issued.body.token as string;

    const me = await fetch(`${base}/api/auth/me`, {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(((await me.json()) as { user: { id: string } }).user.id).toBe(target.id);

    const revoked = await call('DELETE', `/users/${target.id}/sessions`);
    expect(revoked.body.revoked).toBeGreaterThanOrEqual(2);
    const after = await fetch(`${base}/api/auth/me`, {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(after.status).toBe(401);
  });
});

describe('collection and Fragments', () => {
  it('sets an exact card count, and records it in the ledger', async () => {
    const target = await register('setcard');
    const result = await call('PUT', `/users/${target.id}/collection/darek_voln`, { quantity: 3 });
    expect(result.body).toMatchObject({ cardId: 'darek_voln', owned: 3, delta: 3 });
    expect(await owned(target.id, 'darek_voln')).toBe(3);

    await call('PUT', `/users/${target.id}/collection/darek_voln`, { quantity: 0 });
    expect(await owned(target.id, 'darek_voln')).toBe(0);

    const ledger = await call('GET', `/users/${target.id}/ledger`);
    const rows = ledger.body.transactions as Array<{
      type: string;
      cardId: string;
      quantity: number;
      metadata: { adminId: string; action: string };
    }>;
    const mine = rows.filter((row) => row.cardId === 'darek_voln');
    expect(mine.map((row) => row.quantity).sort()).toEqual([-3, 3]);
    for (const row of mine) {
      expect(row.type).toBe('ADMIN_GRANT');
      expect(row.metadata).toMatchObject({ adminId: admin.id, action: 'SET_CARD' });
    }
  });

  it('refuses an unknown card and an absurd count', async () => {
    expect((await call('PUT', `/users/${player.id}/collection/nope`, { quantity: 1 })).status).toBe(
      404,
    );
    const absurd = await call('PUT', `/users/${player.id}/collection/wolf`, { quantity: 1000 });
    expect(absurd.status).toBe(400);
    expect(absurd.body.code).toBe('INVALID_QUANTITY');
  });

  it('grants a playset of every released card, leaving unreleased ones alone', async () => {
    const target = await register('grantall');
    const result = await call('POST', `/users/${target.id}/collection/grant-all`, {});
    expect(result.body.changed).toBeGreaterThan(0);
    expect(await owned(target.id, 'darek_voln')).toBe(1);
    expect(await owned(target.id, 'warden_sentinel')).toBe(2);
    expect(await owned(target.id, 'kona_forgeheart')).toBe(0);

    await call('POST', `/users/${target.id}/collection/grant-all`, { includeUnreleased: true });
    expect(await owned(target.id, 'kona_forgeheart')).toBe(2);
  });

  it('resets a collection to the starter cards', async () => {
    const target = await register('reset');
    await call('PUT', `/users/${target.id}/collection/darek_voln`, { quantity: 1 });
    await call('PUT', `/users/${target.id}/collection/wolf`, { quantity: 9 });
    await call('POST', `/users/${target.id}/collection/reset`);
    expect(await owned(target.id, 'darek_voln')).toBe(0);
    expect(await owned(target.id, 'wolf')).toBe(STARTER_COLLECTION.get('wolf'));
  });

  it('sets and adjusts Fragments, never below zero', async () => {
    const target = await register('frag');
    expect(
      (await call('PUT', `/users/${target.id}/fragments`, { balance: 500 })).body,
    ).toMatchObject({ fragments: 500, delta: 500 });
    expect(
      (await call('POST', `/users/${target.id}/fragments`, { amount: -200 })).body,
    ).toMatchObject({ fragments: 300 });
    const overdrawn = await call('POST', `/users/${target.id}/fragments`, { amount: -301 });
    expect(overdrawn.status).toBe(400);
    const ledger = await call('GET', `/users/${target.id}/ledger`);
    const actions = (ledger.body.transactions as Array<{ metadata: { action: string } }>).map(
      (row) => row.metadata.action,
    );
    expect(actions).toEqual(expect.arrayContaining(['SET_FRAGMENTS', 'ADJUST_FRAGMENTS']));
  });

  it("opens a pack for a player, under the expansion's policy", async () => {
    const target = await register('pack');
    const opened = await call('POST', `/users/${target.id}/packs/CORE_PACK/open`, {
      seed: 'fixed',
    });
    expect(opened.status).toBe(200);
    expect((opened.body.pack as { cards: unknown[] }).cards).toHaveLength(5);
    const unreleased = await call('POST', `/users/${target.id}/packs/MACHINES_OF_KONA_PACK/open`);
    expect(unreleased.status).toBe(404);
  });
});

describe('decks, social and trades', () => {
  it('saves a ready starter deck in one step, numbering repeats', async () => {
    const target = await register('starter');
    const first = await call('POST', `/users/${target.id}/decks/starter`, { heroId: 'striker' });
    expect(first.status).toBe(201);
    const deck = first.body.deck as {
      name: string;
      heroId: string;
      readiness: { playable: boolean };
    };
    expect(deck).toMatchObject({ heroId: 'striker', name: 'The Striker' });
    expect(deck.readiness.playable).toBe(true);
    const second = await call('POST', `/users/${target.id}/decks/starter`, { heroId: 'striker' });
    expect((second.body.deck as { name: string }).name).toBe('The Striker 2');
    expect((await call('POST', `/users/${target.id}/decks/starter`, { heroId: 'x' })).status).toBe(
      400,
    );
  });

  it('makes two accounts friends at once', async () => {
    const a = await register('frienda');
    const b = await register('friendb');
    const result = await call('POST', '/friendships', { userA: a.id, userB: b.id });
    expect(result.status).toBe(201);
    expect((result.body.friendship as { status: string }).status).toBe('ACCEPTED');
    const overview = await call('GET', `/users/${a.id}`);
    const friends = (overview.body.social as { friends: Array<{ userId: string }> }).friends;
    expect(friends.map((friend) => friend.userId)).toContain(b.id);
  });

  it('cancels an open trade on behalf of its players', async () => {
    const a = await register('tradea');
    const b = await register('tradeb');
    const trade = await trades.create(a.id, b.id);
    const result = await call('POST', `/trades/${trade.id}/cancel`);
    expect(result.status).toBe(200);
    expect((result.body.trade as { status: string }).status).toBe('CANCELLED');
  });
});

describe('matches', () => {
  it('starts a debug match with cards the player does not own', async () => {
    const target = await register('debugmatch');
    // Legendaries the player has never owned: ownership is what is skipped.
    const cardIds = [
      ...starterDeckFor('healer').filter((id) => id !== 'wolf'),
      'darek_voln',
      'lio_varga',
    ];
    const result = await call('POST', '/matches', {
      userId: target.id,
      scenarioId: 'BANDIT_AMBUSH',
      heroId: 'healer',
      cardIds,
    });
    expect(result.status).toBe(201);
    const match = result.body.match as { matchId: string; players: Array<{ playerId: string }> };
    expect(match.players.map((entry) => entry.playerId)).toContain(target.id);

    const listed = await call('GET', '/matches');
    expect((listed.body.matches as Array<{ matchId: string }>).map((m) => m.matchId)).toContain(
      match.matchId,
    );
    const detail = await call('GET', `/matches/${match.matchId}`);
    expect(detail.body).toHaveProperty('state');
    expect(
      (detail.body.legalActions as Record<string, unknown[]>)[target.id]!.length,
    ).toBeGreaterThan(0);

    expect((await call('DELETE', `/matches/${match.matchId}`)).status).toBe(204);
    expect(manager.get(match.matchId)).toBeUndefined();
  });

  it('still judges a debug deck by the rules', async () => {
    const result = await call('POST', '/matches', {
      userId: player.id,
      scenarioId: 'BANDIT_AMBUSH',
      heroId: 'healer',
      cardIds: [
        ...starterDeckFor('healer').filter((id) => id !== 'healing_potion'),
        'firebolt',
        'firebolt',
      ],
    });
    expect(result.status).toBe(400);
    expect(result.body.code).toBe('INVALID_DECK');
    expect(String(result.body.message)).toContain('Firebolt is a Wizard card');
  });
});

describe('registry', () => {
  it('lists every definition, unreleased included', async () => {
    const result = await call('GET', '/registry');
    const cardIds = (result.body.cards as Array<{ id: string }>).map((card) => card.id);
    expect(cardIds).toContain('kona_forgeheart');
    expect((result.body.heroes as unknown[]).length).toBeGreaterThanOrEqual(2);
    const expansionIds = (result.body.expansions as Array<{ id: string }>).map((e) => e.id);
    expect(expansionIds).toContain('MACHINES_OF_KONA');
  });
});

describe('editing a live match', () => {
  async function debugMatch() {
    const target = await register(`edit${Math.floor(Math.random() * 1e6)}`);
    const created = await call('POST', '/matches', {
      userId: target.id,
      scenarioId: 'BANDIT_AMBUSH',
      heroId: 'healer',
    });
    const matchId = (created.body.match as { matchId: string }).matchId;
    return { target, matchId, engine: manager.get(matchId)! };
  }

  it("puts any card into either player's hand, and tells the players", async () => {
    const { target, matchId, engine } = await debugMatch();
    const heard: string[] = [];
    manager.onChange((id, events) => {
      if (id === matchId) heard.push(...events.map((event) => event.type));
    });
    const before = engine.state.sides[target.id]!.hand.length;

    const mine = await call('POST', `/matches/${matchId}/hand`, {
      playerId: target.id,
      cardId: 'darek_voln',
    });
    expect(mine.status).toBe(200);
    const hand = engine.state.sides[target.id]!.hand;
    expect(hand).toHaveLength(before + 1);
    expect(hand.at(-1)!.definitionId).toBe('darek_voln');
    // The opponent's hand too — here, the AI's — and unreleased cards as well.
    const theirs = await call('POST', `/matches/${matchId}/hand`, {
      playerId: 'ai',
      cardId: 'kona_forgeheart',
    });
    expect(theirs.status).toBe(200);
    expect(engine.state.sides.ai!.hand.at(-1)!.definitionId).toBe('kona_forgeheart');

    expect(heard).toEqual(['ADMIN_EDIT', 'ADMIN_EDIT']);
    expect(engine.state.debugEdits).toBe(2);
    // Edits are not actions: the log stays a record of play alone.
    expect(engine.state.actionLog).toHaveLength(0);
  });

  it('refuses an unknown card, an unknown player and a full hand', async () => {
    const { target, matchId, engine } = await debugMatch();
    const unknown = await call('POST', `/matches/${matchId}/hand`, {
      playerId: target.id,
      cardId: 'nope',
    });
    expect(unknown.body.code).toBe('UNKNOWN_CARD');
    const nobody = await call('POST', `/matches/${matchId}/hand`, {
      playerId: 'nobody',
      cardId: 'wolf',
    });
    expect(nobody.body.code).toBe('UNKNOWN_PLAYER');
    while (engine.state.sides[target.id]!.hand.length < 10) {
      await call('POST', `/matches/${matchId}/hand`, { playerId: target.id, cardId: 'wolf' });
    }
    const full = await call('POST', `/matches/${matchId}/hand`, {
      playerId: target.id,
      cardId: 'wolf',
    });
    expect(full.status).toBe(409);
    expect(full.body.code).toBe('HAND_FULL');
  });

  it("sets a Creature's Attack and Health, and one set to 0 dies", async () => {
    const { matchId, engine } = await debugMatch();
    // The ambush starts with a Mercenary on the AI's board.
    const creatureId = Object.keys(engine.state.sides.ai!.creatures)[0]!;
    const set = await call('POST', `/matches/${matchId}/stats`, {
      entityId: creatureId,
      attack: 9,
      health: 12,
    });
    expect(set.status).toBe(200);
    const creature = engine.state.sides.ai!.creatures[creatureId]!;
    expect(creature).toMatchObject({ currentAttack: 9, currentHealth: 12, maxHealth: 12 });

    const killed = await call('POST', `/matches/${matchId}/stats`, {
      entityId: creatureId,
      health: 0,
    });
    const types = (killed.body.events as Array<{ type: string }>).map((event) => event.type);
    expect(types).toEqual(['ADMIN_EDIT', 'CREATURE_DIED']);
    expect(engine.state.sides.ai!.creatures[creatureId]).toBeUndefined();
  });

  it("sets a Hero's Health, and its Attack through its Weapon", async () => {
    const { target, matchId, engine } = await debugMatch();
    const hero = `${target.id}:hero`;
    await call('POST', `/matches/${matchId}/stats`, { entityId: hero, health: 45 });
    expect(engine.state.sides[target.id]!.hero).toMatchObject({ currentHealth: 45, maxHealth: 45 });

    // The player has no Weapon; the ambushing AI starts with one.
    const unarmed = await call('POST', `/matches/${matchId}/stats`, { entityId: hero, attack: 3 });
    expect(unarmed.body.code).toBe('NO_WEAPON');
    await call('POST', `/matches/${matchId}/stats`, { entityId: 'ai:hero', attack: 7 });
    expect(engine.state.sides.ai!.hero.equippedWeapon!.currentAttack).toBe(7);

    // A Hero set to 0 loses the match.
    const lethal = await call('POST', `/matches/${matchId}/stats`, {
      entityId: 'ai:hero',
      health: 0,
    });
    expect((lethal.body.events as Array<{ type: string }>).map((event) => event.type)).toContain(
      'MATCH_ENDED',
    );
    expect(engine.state.winnerId).toBe(target.id);
    const afterwards = await call('POST', `/matches/${matchId}/stats`, {
      entityId: hero,
      health: 1,
    });
    expect(afterwards.body.code).toBe('MATCH_FINISHED');
  });

  it('refuses a negative stat or nothing to set', async () => {
    const { target, matchId } = await debugMatch();
    const hero = `${target.id}:hero`;
    expect(
      (await call('POST', `/matches/${matchId}/stats`, { entityId: hero, health: -1 })).body.code,
    ).toBe('INVALID_STAT');
    expect((await call('POST', `/matches/${matchId}/stats`, { entityId: hero })).body.code).toBe(
      'INVALID_STAT',
    );
    expect(
      (await call('POST', `/matches/${matchId}/stats`, { entityId: 'nobody', health: 1 })).body
        .code,
    ).toBe('UNKNOWN_ENTITY');
  });

  it('is not reachable by a player, even in their own match', async () => {
    const { matchId } = await debugMatch();
    const result = await call(
      'POST',
      `/matches/${matchId}/hand`,
      { playerId: player.id, cardId: 'wolf' },
      player,
    );
    expect(result.status).toBe(404);
  });
});
