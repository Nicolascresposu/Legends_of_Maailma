import { randomUUID } from 'node:crypto';
import type { Prisma, PrismaClient } from '@prisma/client';
import {
  PACK_DEFINITIONS,
  getPackDefinition,
  type PackDefinition,
} from '@maailma/card-definitions';
import {
  deckCopyLimit,
  generatePack,
  packPool,
  type OwnedCounts,
  type PackResult,
} from '@maailma/game-engine';
import { SeededRng } from '@maailma/rng';
import {
  ECONOMY_ERRORS,
  EconomyError,
  assertPacksOpenable,
  packsProtectDuplicates,
  type ExpansionService,
} from './expansion-service.js';
import { runOnce } from './idempotency.js';

export interface OpenedPack extends PackResult {
  /** The seed the pack was generated from, so a result can be re-derived. */
  seed: string;
  /** What the player now owns of each card the pack contained. */
  owned: Array<{ cardId: string; quantity: number }>;
}

/**
 * Opening packs.
 *
 * A pack belongs to one expansion, and opening one asks that expansion two
 * questions at the moment of opening: is it released, and is it currently
 * available in packs. Both are read live, so a set withdrawn between a client
 * drawing its shop and a player clicking refuses the open rather than paying
 * out from a set that is no longer meant to be opened.
 *
 * Duplicate protection is applied here too, and it looks at exactly one thing:
 * how many copies the player holds right now. There is no record of what they
 * have ever owned, and there deliberately never will be — trading a card away
 * to make it eligible again is a move the collection game is meant to offer.
 */
export class PackService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly expansions: ExpansionService,
  ) {}

  /** The packs a player may currently open. */
  async availablePacks(): Promise<PackDefinition[]> {
    const policies = await this.expansions.policies();
    return Object.values(PACK_DEFINITIONS)
      .filter((pack) => {
        const expansion = policies[pack.expansionId];
        return (
          Boolean(expansion) && expansion!.policy.released && expansion!.policy.availableInPacks
        );
      })
      .sort((a, b) => a.id.localeCompare(b.id));
  }

  /**
   * Opens one pack and grants its cards.
   *
   * The seed may be supplied so a caller can reproduce a specific pack — the
   * engine's determinism extends here, which is what makes a disputed pack
   * auditable. Left out, a fresh random seed is drawn per pack.
   */
  async open(
    userId: string,
    packId: string,
    options: { seed?: string; requestId?: string } = {},
  ): Promise<OpenedPack> {
    const pack = getPackDefinition(packId);
    const policies = await this.expansions.policies();
    const expansion = policies[pack.expansionId];
    if (!expansion) {
      throw new EconomyError(
        ECONOMY_ERRORS.UNKNOWN_EXPANSION,
        `Pack ${packId} belongs to an expansion that no longer exists`,
        500,
      );
    }
    assertPacksOpenable(expansion);

    const protectDuplicates = packsProtectDuplicates(expansion);
    const seed = options.seed ?? randomUUID();

    // Opening a pack hands out cards, so a retried request must replay its
    // original result rather than paying out a second time.
    return await runOnce(this.prisma, userId, 'PACK_OPEN', options.requestId, async (tx) => {
      // Ownership is read inside the transaction, so protection reflects the
      // collection as it stands at the moment of opening rather than as it
      // stood when the request was received.
      const owned = protectDuplicates ? await ownedForExpansion(tx, userId, pack) : undefined;

      const result = generatePack(pack, new SeededRng(seed), {
        duplicateProtection: protectDuplicates,
        ...(owned ? { owned } : {}),
      });

      const granted = new Map<string, number>();
      for (const slot of result.cards) {
        granted.set(slot.cardId, (granted.get(slot.cardId) ?? 0) + 1);
      }

      const ownedAfter: OpenedPack['owned'] = [];
      for (const [cardId, quantity] of [...granted].sort(([a], [b]) => a.localeCompare(b))) {
        const entry = await tx.collectionEntry.upsert({
          where: { userId_cardId: { userId, cardId } },
          create: { userId, cardId, quantity },
          update: { quantity: { increment: quantity } },
        });
        ownedAfter.push({ cardId, quantity: entry.quantity });
      }

      await tx.economyTransaction.create({
        data: {
          userId,
          type: 'PACK_OPEN',
          quantity: result.cards.length,
          fragmentDelta: 0,
          ...(options.requestId ? { requestId: options.requestId } : {}),
          metadata: {
            packId: pack.id,
            expansionId: pack.expansionId,
            seed,
            duplicateProtection: protectDuplicates,
            cards: result.cards.map((slot) => ({ cardId: slot.cardId, rarity: slot.rarity })),
          },
        },
      });

      return { ...result, seed, owned: ownedAfter };
    });
  }

  /**
   * Which cards a duplicate-protected pack would currently favour.
   *
   * Exposed for the collection UI and for tests: the answer changes as the
   * player trades and crafts, which is the point.
   */
  async protectionPreview(
    userId: string,
    packId: string,
  ): Promise<{ eligible: string[]; complete: string[] }> {
    const pack = getPackDefinition(packId);
    const owned = await ownedForExpansion(this.prisma, userId, pack);
    const eligible: string[] = [];
    const complete: string[] = [];
    for (const card of packPool(pack)) {
      const limit = deckCopyLimit(card.rarity);
      ((owned.get(card.id) ?? 0) < limit ? eligible : complete).push(card.id);
    }
    return { eligible: eligible.sort(), complete: complete.sort() };
  }
}

/** Current ownership of the cards in one pack's expansion. */
async function ownedForExpansion(
  client: Prisma.TransactionClient | PrismaClient,
  userId: string,
  pack: PackDefinition,
): Promise<OwnedCounts> {
  const cardIds = packPool(pack).map((card) => card.id);
  const rows = await client.collectionEntry.findMany({
    where: { userId, cardId: { in: cardIds } },
  });
  return new Map(rows.map((row) => [row.cardId, row.quantity]));
}
