import type { CollectionEntry, PrismaClient } from '@prisma/client';
import { CARD_DEFINITIONS, STARTER_DECK, getCardDefinition } from '@maailma/card-definitions';
import { validateDeck } from '@maailma/game-engine';

/** How many copies of one card a deck may hold, by rarity. */
export function copyLimit(cardId: string): number {
  try {
    return getCardDefinition(cardId).rarity === 'LEGENDARY' ? 1 : 2;
  } catch {
    return 0;
  }
}

export interface CollectionCard {
  cardId: string;
  owned: number;
  /** Most copies a deck may use, so a client can cap its controls. */
  copyLimit: number;
}

/** Card ids present in stored data but absent from the registry. */
export interface OrphanReport {
  collection: Array<{ cardId: string; rows: number }>;
  decks: Array<{ deckId: string; name: string; userId: string; unknown: string[] }>;
  /** Size of the registry the report was made against, for sanity checks. */
  knownCardCount: number;
}

/**
 * A registry smaller than this is treated as a load failure rather than a
 * deliberate cull, so a broken import cannot trigger a mass delete.
 */
const MINIMUM_PLAUSIBLE_REGISTRY = 5;

export interface DeckReadiness {
  /** True when this deck may start a match. */
  playable: boolean;
  /** Size, copy-limit and unknown-card problems from the engine. */
  ruleErrors: string[];
  /** Cards the deck uses more copies of than the player owns. */
  missing: Array<{ cardId: string; required: number; owned: number }>;
}

/**
 * What each player may put in a deck.
 *
 * Ownership is tracked as a count per card, because deck legality already
 * depends on copies rather than a yes/no. Collections do not restrict saving a
 * deck — a player may build toward cards they have not unlocked — but a deck
 * is only playable once every copy it uses is owned.
 */
export class CollectionService {
  constructor(private readonly prisma: PrismaClient) {}

  /** The cards granted to a new account, derived from the starter deck. */
  static starterGrant(): Map<string, number> {
    const counts = new Map<string, number>();
    for (const cardId of STARTER_DECK) counts.set(cardId, (counts.get(cardId) ?? 0) + 1);
    return counts;
  }

  /** Gives a new player their starting cards. Safe to call more than once. */
  async grantStarter(userId: string): Promise<void> {
    const grant = CollectionService.starterGrant();
    await this.prisma.collectionEntry.createMany({
      data: [...grant].map(([cardId, quantity]) => ({ userId, cardId, quantity })),
      skipDuplicates: true,
    });
  }

  async entries(userId: string): Promise<CollectionEntry[]> {
    return await this.prisma.collectionEntry.findMany({
      where: { userId },
      orderBy: { cardId: 'asc' },
    });
  }

  /**
   * Stored card ids the registry no longer defines.
   *
   * Card ids are plain strings with no foreign key, so removing or renaming a
   * card in `@maailma/card-definitions` leaves rows behind that nothing
   * validates. They are harmless — a deck holding one is already reported
   * unplayable — but they are invisible, and an id that is later reused for a
   * different card would be silently inherited by whoever owned the old one.
   */
  async findOrphans(): Promise<OrphanReport> {
    const known = new Set(Object.keys(CARD_DEFINITIONS));

    const grouped = await this.prisma.collectionEntry.groupBy({
      by: ['cardId'],
      _count: { _all: true },
    });
    const collection = grouped
      .filter((row) => !known.has(row.cardId))
      .map((row) => ({ cardId: row.cardId, rows: row._count._all }))
      .sort((a, b) => a.cardId.localeCompare(b.cardId));

    const storedDecks = await this.prisma.deck.findMany({
      select: { id: true, name: true, userId: true, cardIds: true },
    });
    const decks: OrphanReport['decks'] = [];
    for (const deck of storedDecks) {
      const unknown = [...new Set(deck.cardIds.filter((cardId) => !known.has(cardId)))].sort();
      if (unknown.length > 0) {
        decks.push({ deckId: deck.id, name: deck.name, userId: deck.userId, unknown });
      }
    }

    return { collection, decks, knownCardCount: known.size };
  }

  /**
   * Deletes orphaned collection rows. Decks are never touched: rewriting one
   * would silently alter what a player built, and the readiness marker already
   * explains why it cannot be played.
   *
   * Refuses to run when the registry looks empty or implausibly small, because
   * a failed import would otherwise make every card look orphaned and wipe
   * every collection.
   */
  async pruneOrphans(): Promise<{ deleted: number; cardIds: string[] }> {
    const report = await this.findOrphans();
    if (report.knownCardCount < MINIMUM_PLAUSIBLE_REGISTRY) {
      throw new Error(
        `Refusing to prune: the card registry reports only ${report.knownCardCount} cards, ` +
          'which suggests it failed to load rather than that every card was removed.',
      );
    }
    const cardIds = report.collection.map((entry) => entry.cardId);
    if (cardIds.length === 0) return { deleted: 0, cardIds: [] };
    const result = await this.prisma.collectionEntry.deleteMany({
      where: { cardId: { in: cardIds } },
    });
    return { deleted: result.count, cardIds };
  }

  /** Owned counts keyed by card id. */
  async ownedCounts(userId: string): Promise<Map<string, number>> {
    const rows = await this.entries(userId);
    return new Map(rows.map((row) => [row.cardId, row.quantity]));
  }

  /**
   * The whole registry with the player's counts attached, so a collection
   * browser can show unowned cards too rather than hiding what exists.
   */
  async browse(userId: string): Promise<CollectionCard[]> {
    const owned = await this.ownedCounts(userId);
    return Object.values(CARD_DEFINITIONS)
      .filter((card) => card.collectible)
      .map((card) => ({
        cardId: card.id,
        owned: owned.get(card.id) ?? 0,
        copyLimit: copyLimit(card.id),
      }))
      .sort((a, b) => a.cardId.localeCompare(b.cardId));
  }

  /** Adds copies, capped at the deck copy limit so grants cannot overfill. */
  async grant(userId: string, cardId: string, quantity = 1): Promise<CollectionEntry> {
    const limit = copyLimit(cardId);
    if (limit === 0) throw new Error(`Unknown card: ${cardId}`);
    const existing = await this.prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId, cardId } },
    });
    const next = Math.min(limit, (existing?.quantity ?? 0) + Math.max(1, quantity));
    return await this.prisma.collectionEntry.upsert({
      where: { userId_cardId: { userId, cardId } },
      create: { userId, cardId, quantity: next },
      update: { quantity: next },
    });
  }

  /**
   * Whether a deck can start a match, and why not.
   *
   * Two independent problems are reported together so a client can explain
   * both at once: the engine's own rules (30 cards, copy limits, unknown
   * cards) and cards the player does not own enough copies of.
   */
  assess(cardIds: readonly string[], owned: Map<string, number>): DeckReadiness {
    const rules = validateDeck(cardIds);
    const required = new Map<string, number>();
    for (const cardId of cardIds) required.set(cardId, (required.get(cardId) ?? 0) + 1);

    const missing: DeckReadiness['missing'] = [];
    for (const [cardId, count] of required) {
      const have = owned.get(cardId) ?? 0;
      if (have < count) missing.push({ cardId, required: count, owned: have });
    }
    missing.sort((a, b) => a.cardId.localeCompare(b.cardId));

    return {
      playable: rules.valid && missing.length === 0,
      ruleErrors: rules.errors,
      missing,
    };
  }

  async assessForUser(userId: string, cardIds: readonly string[]): Promise<DeckReadiness> {
    return this.assess(cardIds, await this.ownedCounts(userId));
  }

  /** Throws when a deck may not be played, with a reason worth showing. */
  async assertPlayable(userId: string, cardIds: readonly string[]): Promise<void> {
    const readiness = await this.assessForUser(userId, cardIds);
    if (readiness.playable) return;
    const reasons = [...readiness.ruleErrors];
    for (const entry of readiness.missing) {
      reasons.push(`${cardName(entry.cardId)}: needs ${entry.required}, owns ${entry.owned}`);
    }
    throw new DeckNotPlayableError(reasons);
  }
}

export class DeckNotPlayableError extends Error {
  readonly code = 'DECK_NOT_PLAYABLE';
  readonly status = 409;

  constructor(readonly reasons: string[]) {
    super(`Deck cannot be played: ${reasons.join('; ')}`);
    this.name = 'DeckNotPlayableError';
  }
}

function cardName(cardId: string): string {
  try {
    return getCardDefinition(cardId).name;
  } catch {
    return cardId;
  }
}
