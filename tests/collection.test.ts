import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { PrismaClient } from '@prisma/client';
import {
  CARD_DEFINITIONS,
  EXPANSION_DEFINITIONS,
  STARTER_COLLECTION,
  starterDeckFor,
} from '@maailma/card-definitions';
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
 * Collections: what each player owns, and how ownership gates play without
 * blocking deck building.
 */
const prisma = new PrismaClient();
const suffix = `c${Date.now()}${Math.floor(Math.random() * 1000)}`;
const created: string[] = [];

let server: Server | undefined;
let base = '';

const accounts = new AccountService(prisma);
const expansions = new ExpansionService(prisma);
const collections = new CollectionService(prisma, expansions);
const economy = new EconomyService(prisma, expansions);
const packs = new PackService(prisma, expansions);
const trades = new TradeService(prisma, expansions);
const decks = new DeckService(prisma, collections);
const social = new SocialService(prisma);

/** Cards outside the starter grant, so a test can rely on them being unowned. */
/**
 * Cards a new account does not start with, and could go and get.
 *
 * Restricted to released expansions: an unreleased set's cards are also
 * unowned, but they are not something a player can see or reach, so they
 * belong to the visibility tests rather than these.
 */
const RELEASED_COLLECTIBLE = Object.values(CARD_DEFINITIONS).filter(
  (card) => card.collectible && EXPANSION_DEFINITIONS[card.expansionId]?.policy.released === true,
);

// Neutral, so any deck may hold one: a class card would make a deck illegal
// for its class rather than merely unowned.
const UNOWNED = RELEASED_COLLECTIBLE.filter(
  (card) => !STARTER_COLLECTION.has(card.id) && card.classId === undefined,
).map((card) => card.id);

/** Every deck in this file is built for The Mender, a Priest. */
const PRIEST_STARTER = starterDeckFor('healer');

beforeAll(async () => {
  const manager = new MatchManager();
  const lobby = new LobbyHub(silentLogger);
  server = createServer(
    createApp(manager, silentLogger, {
      accounts,
      decks,
      social,
      collections,
      expansions,
      economy,
      packs,
      trades,
      lobby,
    }),
  );
  await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Missing test port');
  base = `http://127.0.0.1:${address.port}`;
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

function authed(token: string) {
  return { 'content-type': 'application/json', authorization: `Bearer ${token}` };
}

describe('collection contents', () => {
  it('grants the starter cards to a new account', async () => {
    const user = await register('grant');
    const rows = await prisma.collectionEntry.findMany({ where: { userId: user.user.id } });
    expect(rows.length).toBe(STARTER_COLLECTION.size);
    for (const row of rows) {
      expect(row.quantity).toBe(STARTER_COLLECTION.get(row.cardId));
    }
  });

  it('lists every released card with owned counts, including unowned ones', async () => {
    const user = await register('browse');
    const body = (await (
      await fetch(`${base}/api/collection`, { headers: authed(user.token) })
    ).json()) as { cards: Array<{ cardId: string; owned: number; copyLimit: number }> };

    // Everything released, and nothing that is not: an unreleased set's names
    // and rarities must not reach a player through this listing.
    expect(body.cards.length).toBe(RELEASED_COLLECTIBLE.length);
    const unreleased = Object.values(CARD_DEFINITIONS).filter(
      (card) => EXPANSION_DEFINITIONS[card.expansionId]?.policy.released !== true,
    );
    expect(unreleased.length).toBeGreaterThan(0);
    for (const card of unreleased) {
      expect(body.cards.map((row) => row.cardId)).not.toContain(card.id);
    }

    // Cards outside the starter deck exist in the listing but are unowned.
    for (const cardId of UNOWNED) {
      const entry = body.cards.find((card) => card.cardId === cardId);
      expect(entry, `${cardId} should be listed`).toBeDefined();
      expect(entry!.owned).toBe(0);
    }
    const wolf = body.cards.find((card) => card.cardId === 'wolf');
    expect(wolf?.owned).toBe(2);
  });

  it('caps a legendary at one copy and a common at two', async () => {
    const user = await register('caps');
    const legendary = Object.values(CARD_DEFINITIONS).find(
      (card) => card.rarity === 'LEGENDARY' && card.collectible,
    );
    expect(legendary).toBeDefined();

    await collections.grant(user.user.id, legendary!.id, 5);
    const entry = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user.user.id, cardId: legendary!.id } },
    });
    expect(entry?.quantity).toBe(1);

    await collections.grant(user.user.id, 'wolf', 9);
    const wolf = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user.user.id, cardId: 'wolf' } },
    });
    expect(wolf?.quantity).toBe(2);
  });

  it('keeps one player collection invisible to another', async () => {
    const a = await register('privcol');
    const b = await register('othercol');
    await collections.grant(a.user.id, UNOWNED[0]!, 1);

    const seen = (await (
      await fetch(`${base}/api/collection`, { headers: authed(b.token) })
    ).json()) as { cards: Array<{ cardId: string; owned: number }> };
    expect(seen.cards.find((card) => card.cardId === UNOWNED[0])?.owned).toBe(0);
  });
});

describe('deck readiness', () => {
  it('marks a starter deck playable', async () => {
    const user = await register('ready');
    const saved = await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(user.token),
      body: JSON.stringify({ name: 'Starter', heroId: 'healer', cardIds: PRIEST_STARTER }),
    });
    expect(saved.status).toBe(201);
    const list = (await (
      await fetch(`${base}/api/decks`, { headers: authed(user.token) })
    ).json()) as { decks: Array<{ readiness: { playable: boolean } }> };
    expect(list.decks[0]?.readiness.playable).toBe(true);
  });

  it('saves a deck with unowned cards but reports what is missing', async () => {
    const user = await register('missing');
    // Swap two starter cards for a card the player does not own.
    const cardIds = [...PRIEST_STARTER.slice(0, 28), UNOWNED[0]!, UNOWNED[0]!];
    const saved = await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(user.token),
      body: JSON.stringify({ name: 'Aspirational', heroId: 'healer', cardIds }),
    });
    // Saving is permitted: a player may build toward cards they lack.
    expect(saved.status).toBe(201);
    const deckId = ((await saved.json()) as { deck: { id: string } }).deck.id;

    const detail = (await (
      await fetch(`${base}/api/decks/${deckId}`, { headers: authed(user.token) })
    ).json()) as {
      deck: {
        readiness: {
          playable: boolean;
          missing: Array<{ cardId: string; required: number; owned: number }>;
        };
      };
    };
    expect(detail.deck.readiness.playable).toBe(false);
    const entry = detail.deck.readiness.missing.find((row) => row.cardId === UNOWNED[0]);
    expect(entry).toBeDefined();
    expect(entry!.owned).toBe(0);
    expect(entry!.required).toBe(2);
  });

  it('separates rule problems from ownership problems', async () => {
    const user = await register('split');
    const readiness = await collections.assessForUser(user.user.id, ['wolf', UNOWNED[0]!]);
    expect(readiness.playable).toBe(false);
    // Too few cards is a rule problem...
    expect(readiness.ruleErrors.join(' ')).toContain('30');
    // ...while the unowned legendary is an ownership problem.
    expect(readiness.missing.map((row) => row.cardId)).toContain(UNOWNED[0]);
  });

  it('assesses an arbitrary list without saving it', async () => {
    const user = await register('assess');
    const response = await fetch(`${base}/api/collection/assess`, {
      method: 'POST',
      headers: authed(user.token),
      body: JSON.stringify({ cardIds: PRIEST_STARTER }),
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { readiness: { playable: boolean } };
    expect(body.readiness.playable).toBe(true);
    // Nothing was stored.
    const decks = await prisma.deck.count({ where: { userId: user.user.id } });
    expect(decks).toBe(0);
  });

  it('counts copies, not just presence', async () => {
    const user = await register('copies');
    // Three copies of a card the player owns two of.
    const readiness = await collections.assessForUser(user.user.id, [
      ...Array.from({ length: 3 }, () => 'wolf'),
    ]);
    const wolf = readiness.missing.find((row) => row.cardId === 'wolf');
    expect(wolf).toBeDefined();
    expect(wolf!.required).toBe(3);
    expect(wolf!.owned).toBe(2);
  });
});

describe('ownership at match start', () => {
  async function befriend(
    a: { token: string },
    b: { token: string; user: { displayName: string } },
  ) {
    const request = await fetch(`${base}/api/social/friends/requests`, {
      method: 'POST',
      headers: authed(a.token),
      body: JSON.stringify({ displayName: b.user.displayName }),
    });
    const friendshipId = ((await request.json()) as { friendship: { id: string } }).friendship.id;
    await fetch(`${base}/api/social/friends/requests/${friendshipId}/respond`, {
      method: 'POST',
      headers: authed(b.token),
      body: JSON.stringify({ accept: true }),
    });
  }

  it('refuses to start a match with an unplayable deck', async () => {
    const challenger = await register('blka');
    const opponent = await register('blkb');
    await befriend(challenger, opponent);

    // The opponent's active deck uses a card they do not own.
    const cardIds = [...PRIEST_STARTER.slice(0, 28), UNOWNED[0]!, UNOWNED[0]!];
    await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(opponent.token),
      body: JSON.stringify({ name: 'Blocked', heroId: 'healer', cardIds }),
    });

    const sent = await fetch(`${base}/api/social/challenges`, {
      method: 'POST',
      headers: authed(challenger.token),
      body: JSON.stringify({ opponentId: opponent.user.id, scenarioId: 'STANDARD_PVP' }),
    });
    const challengeId = ((await sent.json()) as { challenge: { id: string } }).challenge.id;

    const accepted = await fetch(`${base}/api/social/challenges/${challengeId}/accept`, {
      method: 'POST',
      headers: authed(opponent.token),
    });
    expect(accepted.status).toBe(409);
    const body = (await accepted.json()) as { code: string; message: string };
    expect(body.code).toBe('DECK_NOT_PLAYABLE');
    // The message names the offending card, so a client can explain it.
    expect(body.message.toLowerCase()).toContain('needs');
  });

  it('starts a match once the missing cards are granted', async () => {
    const challenger = await register('okaya');
    const opponent = await register('okayb');
    await befriend(challenger, opponent);

    const cardIds = [...PRIEST_STARTER.slice(0, 29), UNOWNED[0]!];
    await fetch(`${base}/api/decks`, {
      method: 'POST',
      headers: authed(opponent.token),
      body: JSON.stringify({ name: 'AlmostReady', heroId: 'healer', cardIds }),
    });
    // Grant exactly the missing copy.
    await collections.grant(opponent.user.id, UNOWNED[0]!, 1);

    const sent = await fetch(`${base}/api/social/challenges`, {
      method: 'POST',
      headers: authed(challenger.token),
      body: JSON.stringify({ opponentId: opponent.user.id, scenarioId: 'STANDARD_PVP' }),
    });
    const challengeId = ((await sent.json()) as { challenge: { id: string } }).challenge.id;

    const accepted = await fetch(`${base}/api/social/challenges/${challengeId}/accept`, {
      method: 'POST',
      headers: authed(opponent.token),
    });
    expect(accepted.status).toBe(200);
    const result = (await accepted.json()) as { matchId: string };
    expect(result.matchId).toBeTypeOf('string');
  });

  it('lets a player with no saved deck play the starter deck', async () => {
    const challenger = await register('nodecka');
    const opponent = await register('nodeckb');
    await befriend(challenger, opponent);

    const sent = await fetch(`${base}/api/social/challenges`, {
      method: 'POST',
      headers: authed(challenger.token),
      body: JSON.stringify({ opponentId: opponent.user.id, scenarioId: 'STANDARD_PVP' }),
    });
    const challengeId = ((await sent.json()) as { challenge: { id: string } }).challenge.id;
    const accepted = await fetch(`${base}/api/social/challenges/${challengeId}/accept`, {
      method: 'POST',
      headers: authed(opponent.token),
    });
    expect(accepted.status).toBe(200);
  });
});

describe('orphaned cards', () => {
  it('reports stored card ids the registry no longer defines', async () => {
    const user = await register('orphan');
    await prisma.collectionEntry.create({
      data: { userId: user.user.id, cardId: 'retired_card', quantity: 2 },
    });
    await prisma.deck.create({
      data: {
        userId: user.user.id,
        name: 'Legacy',
        heroId: 'healer',
        cardIds: ['retired_card', ...Array.from({ length: 29 }, () => 'wolf')],
      },
    });

    const report = await collections.findOrphans();
    const entry = report.collection.find((row) => row.cardId === 'retired_card');
    expect(entry).toBeDefined();
    expect(entry!.rows).toBeGreaterThanOrEqual(1);
    const deck = report.decks.find((row) => row.name === 'Legacy');
    expect(deck).toBeDefined();
    expect(deck!.unknown).toContain('retired_card');
    expect(report.knownCardCount).toBeGreaterThan(0);
  });

  it('ignores a database whose cards all still exist', async () => {
    const user = await register('noorphan');
    const report = await collections.findOrphans();
    expect(report.collection.some((row) => row.cardId === 'wolf')).toBe(false);
    void user;
  });

  it('prunes orphaned collection rows but never touches decks', async () => {
    const user = await register('prune');
    await prisma.collectionEntry.create({
      data: { userId: user.user.id, cardId: 'prune_me', quantity: 1 },
    });
    const deck = await prisma.deck.create({
      data: {
        userId: user.user.id,
        name: 'Untouched',
        heroId: 'healer',
        cardIds: ['prune_me', ...Array.from({ length: 29 }, () => 'wolf')],
      },
    });

    const result = await collections.pruneOrphans();
    expect(result.cardIds).toContain('prune_me');
    expect(await prisma.collectionEntry.count({ where: { cardId: 'prune_me' } })).toBe(0);

    // The deck keeps every card it was saved with.
    const after = await prisma.deck.findUniqueOrThrow({ where: { id: deck.id } });
    expect(after.cardIds).toContain('prune_me');
    expect(after.cardIds).toHaveLength(30);
    // ...and still explains itself.
    const readiness = await collections.assessForUser(user.user.id, after.cardIds);
    expect(readiness.playable).toBe(false);
    expect(readiness.ruleErrors.join(' ')).toContain('prune_me');
  });

  it('refuses to prune when the registry looks unloaded', async () => {
    const service = new CollectionService(prisma);
    const real = service.findOrphans.bind(service);
    // A failed registry import would make every stored card look orphaned;
    // pruning then would wipe every collection.
    service.findOrphans = async () => ({ ...(await real()), knownCardCount: 0 });
    await expect(service.pruneOrphans()).rejects.toThrow(/Refusing to prune/);
  });
});
