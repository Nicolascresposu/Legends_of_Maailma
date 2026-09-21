import type { Deck, PrismaClient } from '@prisma/client';
import { getHeroDefinition } from '@maailma/card-definitions';
import { validateDeck } from '@maailma/game-engine';
import { AccountError } from './account-service.js';

export interface DeckInput {
  name: string;
  heroId: string;
  cardIds: string[];
}

/**
 * Stored decks are validated with the engine's own `validateDeck`, so a deck
 * that saves is always one a match will accept. There is exactly one source of
 * deck legality, and it is the engine.
 */
export class DeckService {
  constructor(private readonly prisma: PrismaClient) {}

  async list(userId: string): Promise<Deck[]> {
    return await this.prisma.deck.findMany({
      where: { userId },
      orderBy: [{ isActive: 'desc' }, { updatedAt: 'desc' }],
    });
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
        data: { userId, name: clean.name, heroId: clean.heroId, cardIds: clean.cardIds },
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
        data: { name: clean.name, heroId: clean.heroId, cardIds: clean.cardIds },
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
    const result = validateDeck(cardIds);
    if (!result.valid) {
      throw new AccountError('INVALID_DECK', result.errors.join('; '));
    }
    return { name, heroId, cardIds };
  }
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === 'object' && error !== null && (error as { code?: unknown }).code === 'P2002'
  );
}
