import type { Prisma, PrismaClient, User } from '@prisma/client';
import {
  CARD_DEFINITIONS,
  CLASS_DEFINITIONS,
  HERO_DEFINITIONS,
  PACK_DEFINITIONS,
  SCENARIO_DEFINITIONS,
  getHeroDefinition,
  getScenarioDefinition,
  starterDeckFor,
} from '@maailma/card-definitions';
import { cardCopyLimit } from '@maailma/game-engine';
import { AI_PLAYER_ID, MatchEditError, type MatchManager } from '../match-manager.js';
import type { DebugEdit } from '@maailma/game-model';
import { AccountError, type AccountService } from './account-service.js';
import type { CollectionService } from './collection-service.js';
import type { DeckService } from './deck-service.js';
import type { EconomyService } from './economy-service.js';
import type { ExpansionService } from './expansion-service.js';
import type { PackService } from './pack-service.js';
import type { SocialService } from './social-service.js';
import type { TradeService } from './trade-service.js';

/** The largest count an admin may set one card to. Generous, but bounded. */
const MAX_ADMIN_COPIES = 99;

export interface AdminServices {
  prisma: PrismaClient;
  accounts: AccountService;
  collections: CollectionService;
  decks: DeckService;
  economy: EconomyService;
  expansions: ExpansionService;
  packs: PackService;
  social: SocialService;
  trades: TradeService;
  manager: MatchManager;
}

/** One account as the user list shows it. */
export interface AdminUserSummary {
  id: string;
  email: string;
  displayName: string;
  isAdmin: boolean;
  createdAt: Date;
  fragments: number;
}

/**
 * Operator tooling for testing and support: look inside any account and put it
 * into whatever state a test needs.
 *
 * Everything here is reachable only through the admin guard. Two rules hold
 * for every change it makes:
 *
 * - **It is recorded.** Changes to cards or Fragments are written to the
 *   economy ledger as `ADMIN_GRANT`, with the acting admin in the metadata, so
 *   a collection or a balance can always be accounted for — an admin grant is
 *   a transaction like any other, not a silent edit.
 * - **It goes through the rules where the rules apply.** A deck saved here is
 *   saved like any deck; a pack opened here respects the expansion's policy;
 *   a debug match is still judged by the engine's deck rules. What an admin
 *   may skip is ownership — that is the point of a test account — never
 *   legality.
 */
export class AdminService {
  constructor(private readonly services: AdminServices) {}

  private get prisma(): PrismaClient {
    return this.services.prisma;
  }

  // --- Accounts ------------------------------------------------------------

  /** Accounts whose display name or email contains `search`, newest first. */
  async searchUsers(search = '', limit = 50): Promise<AdminUserSummary[]> {
    const term = search.trim();
    const users = await this.prisma.user.findMany({
      where: term
        ? {
            OR: [
              { displayName: { contains: term, mode: 'insensitive' } },
              { email: { contains: term, mode: 'insensitive' } },
            ],
          }
        : {},
      orderBy: { createdAt: 'desc' },
      take: Math.min(Math.max(1, Math.trunc(limit)), 200),
      include: { economy: true },
    });
    return users.map((user) => summarize(user, user.economy?.fragmentBalance ?? 0));
  }

  /** Everything worth knowing about one account, in one read. */
  async overview(userId: string) {
    const user = await this.requireUser(userId);
    const { collections, decks, economy, social, trades } = this.services;
    const [entries, fragments, deckList, friends, requests, incoming, outgoing, openTrades] =
      await Promise.all([
        collections.entries(userId),
        economy.balance(userId),
        decks.listWithReadiness(userId),
        social.listFriends(userId),
        social.listPendingRequests(userId),
        social.listIncoming(userId),
        social.listOutgoing(userId),
        trades.list(userId, 'OPEN'),
      ]);
    const sessions = await this.prisma.session.count({
      where: { userId, revokedAt: null, expiresAt: { gt: new Date() } },
    });
    return {
      user: summarize(user, fragments),
      collection: {
        distinctCards: entries.filter((entry) => entry.quantity > 0).length,
        totalCopies: entries.reduce((sum, entry) => sum + entry.quantity, 0),
      },
      decks: deckList,
      social: { friends, pendingRequests: requests, incoming, outgoing },
      openTrades,
      activeSessions: sessions,
      matches: this.matchesFor(userId).map(matchSummary),
      recentLedger: await economy.history(userId, 20),
    };
  }

  /**
   * Grants or removes administrator rights. An admin may not remove their own,
   * so the last admin cannot lock everyone out by accident.
   */
  async setAdmin(adminId: string, userId: string, isAdmin: boolean): Promise<AdminUserSummary> {
    await this.requireUser(userId);
    if (adminId === userId && !isAdmin) {
      throw new AccountError('SELF_DEMOTION', 'You cannot remove your own admin rights', 409);
    }
    const user = await this.prisma.user.update({ where: { id: userId }, data: { isAdmin } });
    return summarize(user, await this.services.economy.balance(userId));
  }

  /** A session for the account, so a client can sign in as that player. */
  async impersonate(userId: string) {
    await this.requireUser(userId);
    return await this.services.accounts.issueSessionFor(userId);
  }

  /** Signs the account out everywhere. */
  async revokeSessions(userId: string): Promise<{ revoked: number }> {
    await this.requireUser(userId);
    return { revoked: await this.services.accounts.revokeSessions(userId) };
  }

  // --- Collection ----------------------------------------------------------

  /**
   * The collection as the player sees it, and the stored rows behind it.
   * The rows include what the player's view hides — unreleased cards, and
   * card ids the registry no longer knows.
   */
  async collection(userId: string) {
    await this.requireUser(userId);
    const [cards, entries] = await Promise.all([
      this.services.collections.browse(userId),
      this.services.collections.entries(userId),
    ]);
    return { cards, entries };
  }

  /** Sets exactly how many copies of a card the account owns. 0 removes it. */
  async setCardQuantity(adminId: string, userId: string, cardId: string, quantity: unknown) {
    await this.requireUser(userId);
    requireCard(cardId);
    const target = requireCount(quantity);
    return await this.prisma.$transaction(async (tx) => {
      const before = await ownedIn(tx, userId, cardId);
      await writeQuantity(tx, userId, cardId, target);
      if (target !== before) {
        await recordCards(tx, userId, adminId, 'SET_CARD', target - before, cardId, {
          from: before,
          to: target,
        });
      }
      return { cardId, owned: target, delta: target - before };
    });
  }

  /**
   * Tops every card up to at least `copies`, or to a playable set when left
   * out. Unreleased cards are left alone unless asked for, so a test account
   * does not end up holding a set that has not launched by mistake.
   */
  async grantAll(
    adminId: string,
    userId: string,
    options: { copies?: unknown; includeUnreleased?: unknown } = {},
  ) {
    await this.requireUser(userId);
    const fixed = options.copies === undefined ? undefined : requireCount(options.copies);
    const includeUnreleased = options.includeUnreleased === true;
    const policies = await this.services.expansions.policies();
    const cards = Object.values(CARD_DEFINITIONS).filter(
      (card) =>
        card.collectible &&
        (includeUnreleased || policies[card.expansionId]?.policy.released === true),
    );
    return await this.prisma.$transaction(async (tx) => {
      const changed: Array<{ cardId: string; from: number; to: number }> = [];
      for (const card of cards) {
        const want = fixed ?? cardCopyLimit(card.id);
        const before = await ownedIn(tx, userId, card.id);
        if (before >= want) continue;
        await writeQuantity(tx, userId, card.id, want);
        changed.push({ cardId: card.id, from: before, to: want });
      }
      const added = changed.reduce((sum, row) => sum + (row.to - row.from), 0);
      if (changed.length > 0) {
        await recordCards(tx, userId, adminId, 'GRANT_ALL', added, undefined, {
          includeUnreleased,
          cards: changed,
        });
      }
      return { changed: changed.length, copiesAdded: added };
    });
  }

  /** Empties the collection and grants the starter cards again, as on sign-up. */
  async resetCollection(adminId: string, userId: string) {
    await this.requireUser(userId);
    const removed = await this.prisma.$transaction(async (tx) => {
      const rows = await tx.collectionEntry.findMany({ where: { userId } });
      await tx.collectionEntry.deleteMany({ where: { userId } });
      const copies = rows.reduce((sum, row) => sum + row.quantity, 0);
      await recordCards(tx, userId, adminId, 'RESET_COLLECTION', -copies, undefined, {
        removed: rows.map((row) => ({ cardId: row.cardId, quantity: row.quantity })),
      });
      return copies;
    });
    await this.services.collections.grantStarter(userId);
    return { removedCopies: removed, entries: await this.services.collections.entries(userId) };
  }

  // --- Fragments -----------------------------------------------------------

  /** Adds (or, when negative, removes) Fragments. The balance never goes below 0. */
  async adjustFragments(adminId: string, userId: string, amount: unknown) {
    await this.requireUser(userId);
    const delta = Math.trunc(Number(amount));
    if (!Number.isFinite(delta) || delta === 0) {
      throw new AccountError('INVALID_QUANTITY', 'Amount must be a non-zero whole number');
    }
    const current = await this.services.economy.balance(userId);
    if (current + delta < 0) {
      throw new AccountError('INVALID_QUANTITY', `That would leave ${current + delta} Fragments`);
    }
    const balance = await this.services.economy.grantFragments(userId, delta, 'ADMIN_GRANT', {
      adminId,
      action: 'ADJUST_FRAGMENTS',
    });
    return { fragments: balance, delta };
  }

  /** Sets the balance to an exact figure, recorded as the difference. */
  async setFragments(adminId: string, userId: string, balance: unknown) {
    await this.requireUser(userId);
    const target = Math.trunc(Number(balance));
    if (!Number.isFinite(target) || target < 0) {
      throw new AccountError('INVALID_QUANTITY', 'Balance must be a whole number, 0 or more');
    }
    const current = await this.services.economy.balance(userId);
    if (target === current) return { fragments: current, delta: 0 };
    const updated = await this.services.economy.grantFragments(
      userId,
      target - current,
      'ADMIN_GRANT',
      { adminId, action: 'SET_FRAGMENTS', from: current, to: target },
    );
    return { fragments: updated, delta: target - current };
  }

  // --- Decks ---------------------------------------------------------------

  async decks(userId: string) {
    await this.requireUser(userId);
    return await this.services.decks.listWithReadiness(userId);
  }

  /**
   * Saves the starter deck of a hero's class to the account. With the
   * starter cards owned — every account has them — it is ready to play, which
   * makes it the quickest way to get a test account into a match.
   */
  async createStarterDeck(userId: string, heroId: unknown, name?: unknown) {
    await this.requireUser(userId);
    let hero;
    try {
      hero = getHeroDefinition(String(heroId ?? ''));
    } catch {
      throw new AccountError('INVALID_HERO', `Unknown hero: ${String(heroId ?? '') || '(none)'}`);
    }
    const base = typeof name === 'string' && name.trim() !== '' ? name.trim() : `${hero.name}`;
    const existing = new Set(
      (await this.services.decks.list(userId)).map((deck) => deck.name.toLowerCase()),
    );
    // Numbered rather than refused, so pressing the button twice makes two.
    let deckName = base.slice(0, 40);
    for (let n = 2; existing.has(deckName.toLowerCase()); n += 1) {
      deckName = `${base.slice(0, 36)} ${n}`;
    }
    const deck = await this.services.decks.create(userId, {
      name: deckName,
      heroId: hero.id,
      cardIds: starterDeckFor(hero.id),
    });
    return await this.services.decks.getWithReadiness(userId, deck.id);
  }

  async deleteDeck(userId: string, deckId: string): Promise<void> {
    await this.requireUser(userId);
    await this.services.decks.remove(userId, deckId);
  }

  // --- Packs and ledger ----------------------------------------------------

  /** Opens a pack for the account, under the same policy a player would face. */
  async openPack(userId: string, packId: string, seed?: unknown) {
    await this.requireUser(userId);
    if (!PACK_DEFINITIONS[packId]) {
      throw new AccountError('UNKNOWN_PACK', `Unknown pack: ${packId}`, 404);
    }
    return await this.services.packs.open(userId, packId, {
      ...(typeof seed === 'string' && seed !== '' ? { seed } : {}),
    });
  }

  async ledger(userId: string, limit: unknown) {
    await this.requireUser(userId);
    const count = Number.isFinite(Number(limit)) ? Number(limit) : 100;
    return await this.services.economy.history(userId, count);
  }

  // --- Social and trades ---------------------------------------------------

  /** Makes two accounts friends at once, skipping the request and answer. */
  async befriend(userA: string, userB: string) {
    if (userA === userB)
      throw new AccountError('SELF_FRIENDSHIP', 'An account cannot befriend itself');
    await this.requireUser(userA);
    await this.requireUser(userB);
    const existing = await this.prisma.friendship.findFirst({
      where: {
        OR: [
          { requesterId: userA, addresseeId: userB },
          { requesterId: userB, addresseeId: userA },
        ],
      },
    });
    if (existing) {
      return await this.prisma.friendship.update({
        where: { id: existing.id },
        data: { status: 'ACCEPTED', respondedAt: new Date() },
      });
    }
    return await this.prisma.friendship.create({
      data: { requesterId: userA, addresseeId: userB, status: 'ACCEPTED', respondedAt: new Date() },
    });
  }

  async trades(userId: string) {
    await this.requireUser(userId);
    return await this.services.trades.list(userId);
  }

  /** Cancels an open trade on behalf of its participants. Nothing moves. */
  async cancelTrade(tradeId: string) {
    const trade = await this.prisma.trade.findUnique({ where: { id: tradeId } });
    if (!trade) throw new AccountError('TRADE_NOT_FOUND', 'Trade not found', 404);
    return await this.services.trades.cancel(trade.participantAId, tradeId);
  }

  // --- Matches -------------------------------------------------------------

  listMatches() {
    return this.services.manager.list().map(matchSummary);
  }

  /** A live match in full: state, setup, and what each side may do now. */
  match(matchId: string) {
    const engine = this.requireMatch(matchId);
    const { manager } = this.services;
    return {
      summary: matchSummary(engine),
      state: engine.state,
      setup: engine.setup,
      legalActions: Object.fromEntries(
        engine.state.playerOrder.map((playerId) => [
          playerId,
          manager.legalActions(matchId, playerId),
        ]),
      ),
    };
  }

  /** Puts any card into either player's hand. */
  addCardToHand(matchId: string, playerId: unknown, cardId: unknown) {
    return this.edit(matchId, {
      type: 'ADD_CARD_TO_HAND',
      playerId: String(playerId ?? ''),
      definitionId: String(cardId ?? ''),
    });
  }

  /**
   * Sets a Hero's or Creature's Attack and/or Health. `entityId` is a Creature
   * instance id or `<playerId>:hero`; a Hero's Attack is its Weapon's.
   */
  setStats(matchId: string, entityId: unknown, attack: unknown, health: unknown) {
    const number = (value: unknown) =>
      value === undefined || value === null || value === '' ? undefined : Number(value);
    const edit: DebugEdit = { type: 'SET_STATS', entityId: String(entityId ?? '') };
    const a = number(attack);
    const h = number(health);
    if (a !== undefined) edit.attack = a;
    if (h !== undefined) edit.health = h;
    return this.edit(matchId, edit);
  }

  /** Applies an edit; the new state has already been pushed to the players. */
  private edit(matchId: string, edit: DebugEdit) {
    try {
      const events = this.services.manager.debugEdit(matchId, edit);
      const engine = this.requireMatch(matchId);
      return { events, summary: matchSummary(engine), debugEdits: engine.state.debugEdits ?? 0 };
    } catch (error) {
      if (error instanceof MatchEditError) {
        throw new AccountError(error.code, error.message, error.status);
      }
      throw error;
    }
  }

  endMatch(matchId: string): void {
    this.requireMatch(matchId);
    this.services.manager.remove(matchId);
  }

  /**
   * Starts a match for an account with any card list, owned or not.
   *
   * This is the test bench: try a card before anyone owns it. Ownership is
   * the only thing skipped — the engine still judges the deck, class included
   * — and the account plays it under its own id, so it can join from a client
   * signed in as that player. Against an AI scenario it starts at once; a PvP
   * scenario waits with its seat open, like any other.
   */
  async startDebugMatch(input: {
    userId?: unknown;
    scenarioId?: unknown;
    heroId?: unknown;
    cardIds?: unknown;
  }) {
    const userId = String(input.userId ?? '');
    await this.requireUser(userId);
    const scenarioId = String(input.scenarioId ?? '');
    let scenario;
    try {
      scenario = getScenarioDefinition(scenarioId);
    } catch {
      throw new AccountError('UNKNOWN_SCENARIO', `Unknown scenario: ${scenarioId || '(none)'}`);
    }
    const heroId = String(input.heroId ?? scenario.sideA.heroDefinitionId);
    try {
      getHeroDefinition(heroId);
    } catch {
      throw new AccountError('INVALID_HERO', `Unknown hero: ${heroId}`);
    }
    const cardIds = Array.isArray(input.cardIds)
      ? input.cardIds.map((id) => String(id))
      : starterDeckFor(heroId);
    const player = { playerId: userId, heroDefinitionId: heroId, deck: cardIds };
    const { manager } = this.services;
    try {
      const engine =
        scenario.sideB.controller === 'AI'
          ? manager.create({
              scenarioId,
              players: [
                { ...player, controller: 'HUMAN' },
                { playerId: AI_PLAYER_ID, controller: 'AI' },
              ],
            })
          : manager.createWithOpenSeat({
              scenarioId,
              creator: { ...player, controller: 'HUMAN' },
            });
      return matchSummary(engine);
    } catch (error) {
      // The engine's deck rules still apply; say which one was broken.
      throw new AccountError(
        'INVALID_DECK',
        error instanceof Error ? error.message : 'That deck cannot be played',
      );
    }
  }

  // --- Registry ------------------------------------------------------------

  /**
   * Every definition the server knows, unreleased included, with live
   * expansion policies: what a panel needs to offer cards, heroes, packs and
   * scenarios to pick from.
   */
  async registry() {
    return {
      cards: Object.values(CARD_DEFINITIONS),
      heroes: Object.values(HERO_DEFINITIONS),
      classes: Object.values(CLASS_DEFINITIONS),
      scenarios: Object.values(SCENARIO_DEFINITIONS),
      packs: Object.values(PACK_DEFINITIONS),
      expansions: await this.services.expansions.allExpansions(),
    };
  }

  // --- Helpers -------------------------------------------------------------

  private async requireUser(userId: string): Promise<User> {
    const user = userId ? await this.prisma.user.findUnique({ where: { id: userId } }) : null;
    if (!user) throw new AccountError('USER_NOT_FOUND', 'No such player', 404);
    return user;
  }

  private requireMatch(matchId: string) {
    const engine = this.services.manager.get(matchId);
    if (!engine) throw new AccountError('MATCH_NOT_FOUND', 'Match not found', 404);
    return engine;
  }

  private matchesFor(userId: string) {
    return this.services.manager.list().filter((engine) => engine.state.sides[userId]);
  }
}

function summarize(user: User, fragments: number): AdminUserSummary {
  return {
    id: user.id,
    email: user.email,
    displayName: user.displayName,
    isAdmin: user.isAdmin,
    createdAt: user.createdAt,
    fragments,
  };
}

function matchSummary(engine: {
  state: {
    matchId: string;
    turn: number;
    phase: string;
    activePlayerId: string;
    playerOrder: string[];
    winnerId?: string;
    sides: Record<string, { hero: { definitionId: string; currentHealth: number } }>;
  };
  setup: { scenario: { id: string } };
}) {
  const { state } = engine;
  return {
    matchId: state.matchId,
    scenarioId: engine.setup.scenario.id,
    turn: state.turn,
    phase: state.phase,
    activePlayerId: state.activePlayerId,
    ...(state.winnerId ? { winnerId: state.winnerId } : {}),
    players: state.playerOrder.map((playerId) => ({
      playerId,
      heroId: state.sides[playerId]!.hero.definitionId,
      health: state.sides[playerId]!.hero.currentHealth,
    })),
  };
}

function requireCard(cardId: string): void {
  if (!CARD_DEFINITIONS[cardId]) {
    throw new AccountError('UNKNOWN_CARD', `Unknown card: ${cardId}`, 404);
  }
}

function requireCount(value: unknown): number {
  const count = Math.trunc(Number(value));
  if (!Number.isFinite(count) || count < 0 || count > MAX_ADMIN_COPIES) {
    throw new AccountError('INVALID_QUANTITY', `Quantity must be 0 to ${MAX_ADMIN_COPIES}`);
  }
  return count;
}

async function ownedIn(tx: Prisma.TransactionClient, userId: string, cardId: string) {
  const row = await tx.collectionEntry.findUnique({
    where: { userId_cardId: { userId, cardId } },
  });
  return row?.quantity ?? 0;
}

async function writeQuantity(
  tx: Prisma.TransactionClient,
  userId: string,
  cardId: string,
  quantity: number,
) {
  if (quantity === 0) {
    await tx.collectionEntry.deleteMany({ where: { userId, cardId } });
    return;
  }
  await tx.collectionEntry.upsert({
    where: { userId_cardId: { userId, cardId } },
    create: { userId, cardId, quantity },
    update: { quantity },
  });
}

/** Writes an admin change to the cards into the ledger. */
async function recordCards(
  tx: Prisma.TransactionClient,
  userId: string,
  adminId: string,
  action: string,
  quantity: number,
  cardId: string | undefined,
  detail: Record<string, unknown>,
) {
  await tx.economyTransaction.create({
    data: {
      userId,
      type: 'ADMIN_GRANT',
      quantity,
      fragmentDelta: 0,
      ...(cardId ? { cardId } : {}),
      metadata: { adminId, action, ...detail } as Prisma.InputJsonValue,
    },
  });
}
