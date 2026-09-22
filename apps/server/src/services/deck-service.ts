import type { Deck, PrismaClient } from '@prisma/client';
import { getCardDefinition, getHeroDefinition } from '@maailma/card-definitions';
import type { DeckFormat } from '@maailma/game-model';
import { DECK_FORMATS } from '@maailma/game-model';
import { AccountError } from './account-service.js';
import type { CollectionService, DeckReadiness } from './collection-service.js';

export interface DeckInput {
  name: string;
  heroId: string;
  cardIds: string[];
  /** The format the deck is built for. Defaults to Standard. */
  format?: DeckFormat;
}

/** A stored deck with its current readiness attached. */
export type DeckWithReadiness = Deck & { readiness: DeckReadiness };

/** Generous upper bound, so a runaway client cannot store an unbounded deck. */
const MAX_DECK_CARDS = 200;

/**
 * Saved decks are deliberately permissive: a player may store an unfinished
 * deck, or one built toward cards they have not unlocked yet. Only the name,
 * the hero and the existence of each card are enforced on save.
 *
 * Whether a deck may actually be played is a separate question, answered by
 * `CollectionService` and reported as `readiness` on every deck the API
 * returns, so a client can show precisely why a deck is not ready.
 */
export class DeckService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly collections?: CollectionService,
  ) {}

  async list(userId: string): Promise<Deck[]> {
    return await this.prisma.deck.findMany({
      where: { userId },
      orderBy: [{ isActive: 'desc' }, { updatedAt: 'desc' }],
    });
  }

  /** Decks with readiness attached, computed from one collection read. */
  async listWithReadiness(userId: string): Promise<DeckWithReadiness[]> {
    const decks = await this.list(userId);
    if (!this.collections) {
      return decks.map((deck) => ({ ...deck, readiness: emptyReadiness(deck.format) }));
    }
    // One collection read and one policy read serve the whole list: readiness
    // for every deck is judged against the same instant, so two decks sharing
    // a card can never disagree about whether it is legal.
    const [owned, policies] = await Promise.all([
      this.collections.ownedCounts(userId),
      this.collections.policiesSnapshot(),
    ]);
    return decks.map((deck) => ({
      ...deck,
      readiness: this.collections!.assess(deck.cardIds, owned, policies, deck.format),
    }));
  }

  async getWithReadiness(userId: string, deckId: string): Promise<DeckWithReadiness> {
    const deck = await this.get(userId, deckId);
    if (!this.collections) return { ...deck, readiness: emptyReadiness(deck.format) };
    return {
      ...deck,
      readiness: await this.collections.assessForUser(userId, deck.cardIds, deck.format),
    };
  }

  async get(userId: string, deckId: string): Promise<Deck> {
    const deck = await this.prisma.deck.findUnique({ where: { id: deckId } });
    // Report another user's deck as missing rather than forbidden, so deck ids
    // cannot be probed for existence.
    if (!deck || deck.userId !== userId) {
      throw new AccountError('DECK_NOT_FOUND', 'Deck not found', 404);
    }
    return deck;
  }

  async create(userId: string, input: DeckInput): Promise<Deck> {
    const clean = this.validate(input);
    try {
      const deck = await this.prisma.deck.create({
        data: {
          userId,
          name: clean.name,
          heroId: clean.heroId,
          cardIds: clean.cardIds,
          format: clean.format!,
        },
      });
      // A player's first deck becomes their active one.
      const count = await this.prisma.deck.count({ where: { userId } });
      if (count === 1) return await this.setActive(userId, deck.id);
      return deck;
    } catch (error) {
      if (isUniqueViolation(error)) {
        throw new AccountError('DECK_NAME_TAKEN', 'You already have a deck with that name', 409);
      }
      throw error;
    }
  }

  async update(userId: string, deckId: string, input: DeckInput): Promise<Deck> {
    await this.get(userId, deckId);
    const clean = this.validate(input);
    try {
      return await this.prisma.deck.update({
        where: { id: deckId },
        data: {
          name: clean.name,
          heroId: clean.heroId,
          cardIds: clean.cardIds,
          format: clean.format!,
        },
      });
    } catch (error) {
      if (isUniqueViolation(error)) {
        throw new AccountError('DECK_NAME_TAKEN', 'You already have a deck with that name', 409);
      }
      throw error;
    }
  }

  async remove(userId: string, deckId: string): Promise<void> {
    await this.get(userId, deckId);
    await this.prisma.deck.delete({ where: { id: deckId } });
  }

  /** Marks one deck active and clears the flag from the rest, atomically. */
  async setActive(userId: string, deckId: string): Promise<Deck> {
    await this.get(userId, deckId);
    const [, deck] = await this.prisma.$transaction([
      this.prisma.deck.updateMany({
        where: { userId, isActive: true },
        data: { isActive: false },
      }),
      this.prisma.deck.update({ where: { id: deckId }, data: { isActive: true } }),
    ]);
    return deck;
  }

  async activeDeck(userId: string): Promise<Deck | undefined> {
    const deck = await this.prisma.deck.findFirst({ where: { userId, isActive: true } });
    return deck ?? undefined;
  }

  private validate(input: DeckInput): DeckInput {
    const name = String(input?.name ?? '').trim();
    if (name.length < 1 || name.length > 40) {
      throw new AccountError('INVALID_DECK_NAME', 'Deck name must be 1-40 characters');
    }
    const heroId = String(input?.heroId ?? '').trim();
    try {
      getHeroDefinition(heroId);
    } catch {
      throw new AccountError('INVALID_HERO', `Unknown hero: ${heroId || '(none)'}`);
    }
    const cardIds = Array.isArray(input?.cardIds) ? input.cardIds.map((id) => String(id)) : [];
    // Deck legality is deliberately not enforced here: a player may save a
    // work-in-progress deck, or one built toward cards they have yet to
    // unlock. Readiness travels with the deck instead, and playability is
    // enforced when a match starts.
    if (cardIds.length > MAX_DECK_CARDS) {
      throw new AccountError('DECK_TOO_LARGE', `A deck may hold at most ${MAX_DECK_CARDS} cards`);
    }
    const format = (input?.format ?? 'STANDARD') as DeckFormat;
    if (!DECK_FORMATS.includes(format)) {
      throw new AccountError('INVALID_FORMAT', `Unknown deck format: ${String(input?.format)}`);
    }
    for (const cardId of cardIds) {
      try {
        getCardDefinition(cardId);
      } catch {
        throw new AccountError('UNKNOWN_CARD', `Unknown card: ${cardId}`);
      }
    }
    return { name, heroId, cardIds, format };
  }
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === 'object' && error !== null && (error as { code?: unknown }).code === 'P2002'
  );
}

/** Readiness when collections are not configured: rules unknown, not blocked. */
function emptyReadiness(format: DeckFormat = 'STANDARD'): DeckReadiness {
  return { playable: true, ruleErrors: [], missing: [], format, illegalInFormat: [] };
}
