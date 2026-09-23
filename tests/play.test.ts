import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { PrismaClient } from '@prisma/client';
import { starterDeckFor } from '@maailma/card-definitions';
import { createApp } from '../apps/server/src/app.js';
import { MatchManager, OPEN_SEAT_ID } from '../apps/server/src/match-manager.js';
import { LobbyHub } from '../apps/server/src/lobby.js';
import { silentLogger } from '../apps/server/src/logger.js';
import { AI_PLAYER_ID } from '../apps/server/src/routes/play-routes.js';
import { AccountService } from '../apps/server/src/services/account-service.js';
import { DeckService } from '../apps/server/src/services/deck-service.js';
import { SocialService } from '../apps/server/src/services/social-service.js';
import { CollectionService } from '../apps/server/src/services/collection-service.js';
import { ExpansionService } from '../apps/server/src/services/expansion-service.js';
import { EconomyService } from '../apps/server/src/services/economy-service.js';
import { PackService } from '../apps/server/src/services/pack-service.js';
import { TradeService } from '../apps/server/src/services/trade-service.js';

/**
 * Entering a match as a signed-in player: always with a deck of one's own
 * choosing, and only a playable one.
 */
const prisma = new PrismaClient();
const suffix = `pl${Date.now()}${Math.floor(Math.random() * 1000)}`;
const created: string[] = [];

let server: Server | undefined;
let base = '';
const manager = new MatchManager();

const accounts = new AccountService(prisma);
const expansions = new ExpansionService(prisma);
const collections = new CollectionService(prisma, expansions);
const decks = new DeckService(prisma, collections);

beforeAll(async () => {
  server = createServer(
    createApp(manager, silentLogger, {
      accounts,
      decks,
      social: new SocialService(prisma),
      collections,
      expansions,
      economy: new EconomyService(prisma, expansions),
      packs: new PackService(prisma, expansions),
      trades: new TradeService(prisma, expansions),
      lobby: new LobbyHub(silentLogger),
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

interface Player {
  id: string;
  token: string;
}

async function register(tag: string): Promise<Player> {
  const response = await fetch(`${base}/api/auth/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: `${tag}.${suffix}@example.test`,
      displayName: `${tag}_${suffix}`.slice(0, 24),
      password: 'a-sufficiently-long-password',
    }),
  });
  const body = (await response.json()) as { user: { id: string }; token: string };
  created.push(body.user.id);
  return { id: body.user.id, token: body.token };
}

function authed(token: string) {
  return { 'content-type': 'application/json', authorization: `Bearer ${token}` };
}

async function saveDeck(
  player: Player,
  heroId: string,
  cardIds: string[] = starterDeckFor(heroId),
): Promise<string> {
  const saved = await fetch(`${base}/api/decks`, {
    method: 'POST',
    headers: authed(player.token),
    body: JSON.stringify({ name: `${heroId} ${Math.random()}`.slice(0, 40), heroId, cardIds }),
  });
  return ((await saved.json()) as { deck: { id: string } }).deck.id;
}

async function start(player: Player, scenarioId: string, deckId?: string) {
  const response = await fetch(`${base}/api/play`, {
    method: 'POST',
    headers: authed(player.token),
    body: JSON.stringify({ scenarioId, ...(deckId ? { deckId } : {}) }),
  });
  return {
    status: response.status,
    body: (await response.json()) as {
      matchId: string;
      playerId: string;
      waitingForOpponent: boolean;
      code?: string;
    },
  };
}

async function join(player: Player, matchId: string, deckId?: string) {
  const response = await fetch(`${base}/api/play/${matchId}/join`, {
    method: 'POST',
    headers: authed(player.token),
    body: JSON.stringify(deckId ? { deckId } : {}),
  });
  return {
    status: response.status,
    body: (await response.json()) as { playerId?: string; code?: string },
  };
}

describe('entering a match with a chosen deck', () => {
  it('requires signing in', async () => {
    const response = await fetch(`${base}/api/play`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ scenarioId: 'BANDIT_AMBUSH' }),
    });
    expect(response.status).toBe(401);
  });

  it('refuses a player who picks no deck', async () => {
    const player = await register('nodeck');
    const result = await start(player, 'BANDIT_AMBUSH');
    expect(result.status).toBe(400);
    expect(result.body.code).toBe('DECK_REQUIRED');
  });

  it("refuses another player's deck as though it did not exist", async () => {
    const owner = await register('owner');
    const thief = await register('thief');
    const deckId = await saveDeck(owner, 'healer');
    const result = await start(thief, 'BANDIT_AMBUSH', deckId);
    expect(result.status).toBe(404);
    expect(result.body.code).toBe('DECK_NOT_FOUND');
  });

  it('refuses a deck that is not ready', async () => {
    const player = await register('unready');
    const deckId = await saveDeck(player, 'healer', starterDeckFor('healer').slice(0, 10));
    const result = await start(player, 'BANDIT_AMBUSH', deckId);
    expect(result.status).toBe(409);
    expect(result.body.code).toBe('DECK_NOT_PLAYABLE');
  });

  it('starts a match against the AI with the chosen deck and its hero', async () => {
    const player = await register('pve');
    const deckId = await saveDeck(player, 'striker');
    const result = await start(player, 'BANDIT_AMBUSH', deckId);
    expect(result.status).toBe(201);
    expect(result.body.waitingForOpponent).toBe(false);
    expect(result.body.playerId).toBe(player.id);

    const engine = manager.get(result.body.matchId)!;
    expect(engine.state.sides[player.id]!.hero.definitionId).toBe('striker');
    expect(engine.state.sides[AI_PLAYER_ID]!.controller).toBe('AI');
    const deck = engine.setup.players.find((entry) => entry.playerId === player.id)!.deck;
    expect([...deck].sort()).toEqual(starterDeckFor('striker').sort());
    expect(manager.legalActions(result.body.matchId, player.id).length).toBeGreaterThan(0);
  });
});

describe('an open PvP seat', () => {
  it('waits for an opponent, who takes the seat with a deck of their own', async () => {
    const creator = await register('host');
    const guest = await register('guest');
    const created = await start(creator, 'STANDARD_PVP', await saveDeck(creator, 'healer'));
    expect(created.status).toBe(201);
    expect(created.body.waitingForOpponent).toBe(true);
    const matchId = created.body.matchId;

    // Nobody may act while the seat is open, so the creator cannot get a
    // turn in before an opponent has even arrived.
    expect(manager.legalActions(matchId, creator.id)).toEqual([]);
    const early = manager.act(matchId, { type: 'END_TURN', actorId: creator.id });
    expect(early.error?.code).toBe('WAITING_FOR_OPPONENT');

    const joined = await join(guest, matchId, await saveDeck(guest, 'striker'));
    expect(joined.status).toBe(200);
    expect(joined.body.playerId).toBe(guest.id);

    const engine = manager.get(matchId)!;
    expect(engine.state.sides[OPEN_SEAT_ID]).toBeUndefined();
    expect(engine.state.sides[creator.id]!.hero.definitionId).toBe('healer');
    expect(engine.state.sides[guest.id]!.hero.definitionId).toBe('striker');
    const guestDeck = engine.setup.players.find((entry) => entry.playerId === guest.id)!.deck;
    expect([...guestDeck].sort()).toEqual(starterDeckFor('striker').sort());
    // And now the match has begun.
    const active = engine.state.activePlayerId;
    expect(manager.legalActions(matchId, active).length).toBeGreaterThan(0);
  });

  it('keeps the seat open when the joining deck is not ready', async () => {
    const creator = await register('host2');
    const guest = await register('guest2');
    const created = await start(creator, 'STANDARD_PVP', await saveDeck(creator, 'healer'));
    const matchId = created.body.matchId;

    const refused = await join(guest, matchId);
    expect(refused.status).toBe(400);
    expect(refused.body.code).toBe('DECK_REQUIRED');
    const unready = await join(
      guest,
      matchId,
      await saveDeck(guest, 'healer', starterDeckFor('healer').slice(0, 5)),
    );
    expect(unready.status).toBe(409);
    expect(unready.body.code).toBe('DECK_NOT_PLAYABLE');
    expect(manager.hasOpenSeat(matchId)).toBe(true);
  });

  it('has room for one opponent only', async () => {
    const creator = await register('host3');
    const guest = await register('guest3');
    const late = await register('late3');
    const created = await start(creator, 'STANDARD_PVP', await saveDeck(creator, 'healer'));
    const matchId = created.body.matchId;
    await join(guest, matchId, await saveDeck(guest, 'healer'));

    const third = await join(late, matchId, await saveDeck(late, 'healer'));
    expect(third.status).toBe(409);
    expect(third.body.code).toBe('SEAT_TAKEN');
    // The creator re-joining is not a claim, and changes nothing.
    const again = await join(creator, matchId);
    expect(again.status).toBe(200);
    expect(manager.get(matchId)!.state.sides[guest.id]).toBeDefined();
  });

  it('reports a match that does not exist', async () => {
    const guest = await register('lost');
    const result = await join(guest, 'no-such-match', await saveDeck(guest, 'healer'));
    expect(result.status).toBe(404);
    expect(result.body.code).toBe('MATCH_NOT_FOUND');
  });
});
