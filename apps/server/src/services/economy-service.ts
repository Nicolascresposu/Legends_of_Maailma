import type { Prisma, PrismaClient } from '@prisma/client';
import {
  CARD_DEFINITIONS,
  craftCost,
  disenchantValue,
  getCardDefinition,
} from '@maailma/card-definitions';
import { cardCopyLimit } from '@maailma/game-engine';
import { AccountError } from './account-service.js';
import {
  ECONOMY_ERRORS,
  EconomyError,
  assertCraftable,
  assertDisenchantable,
  type ExpansionService,
} from './expansion-service.js';

/** What a craft or disenchant did, and what the player is left holding. */
export interface EconomyResult {
  cardId: string;
  quantity: number;
  /** Fragments spent (negative) or gained (positive). */
  fragmentDelta: number;
  fragmentBalance: number;
  owned: number;
}

export interface DisenchantExtrasPlan {
  /** Cards held above their playable copy limit, and by how many. */
  extras: Array<{ cardId: string; owned: number; copyLimit: number; extra: number; value: number }>;
  /** Total Fragments the plan would return. */
  fragments: number;
  /**
   * Cards held in excess that this plan will not touch, because their
   * expansion is not currently disenchantable. Reported rather than silently
   * omitted, so a player is not left wondering why a spare was skipped.
   */
  skipped: Array<{ cardId: string; extra: number; reason: string }>;
}

export interface DisenchantExtrasResult {
  disenchanted: Array<{ cardId: string; quantity: number }>;
  fragmentDelta: number;
  fragmentBalance: number;
  skipped: DisenchantExtrasPlan['skipped'];
}

/** A quantity a player could plausibly mean, bounded so a typo cannot spend a collection. */
const MAX_QUANTITY_PER_REQUEST = 100;

/**
 * Fragments, crafting and disenchanting.
 *
 * Two rules shape everything here. First, nothing partially happens: Fragments
 * and cards move inside one database transaction, so a failure anywhere leaves
 * a player neither poorer nor richer. Second, the policy that governs a card is
 * read at the moment of the action rather than remembered from when the client
 * drew its screen — a set that stopped being craftable between the click and
 * the request must refuse the craft.
 *
 * Retries are treated as ordinary: a client that loses a response and asks
 * again gets the original outcome replayed rather than a second Legendary and a
 * second bill for it.
 */
export class EconomyService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly expansions: ExpansionService,
  ) {}

  /** A player's Fragment balance, created empty on first read. */
  async balance(userId: string): Promise<number> {
    const row = await this.prisma.userEconomy.findUnique({ where: { userId } });
    return row?.fragmentBalance ?? 0;
  }

  /**
   * Adds Fragments outside the normal economy: a reward, or an admin grant.
   * Recorded in the ledger like everything else, so a balance can always be
   * accounted for.
   */
  async grantFragments(
    userId: string,
    amount: number,
    type: 'REWARD' | 'ADMIN_GRANT' = 'ADMIN_GRANT',
    metadata?: Prisma.InputJsonValue,
  ): Promise<number> {
    const quantity = Math.trunc(amount);
    if (!Number.isFinite(quantity) || quantity === 0) {
      throw new EconomyError(ECONOMY_ERRORS.INVALID_QUANTITY, 'Grant must be a non-zero integer');
    }
    return await this.prisma.$transaction(async (tx) => {
      const economy = await creditFragments(tx, userId, quantity);
      await tx.economyTransaction.create({
        data: {
          userId,
          type,
          fragmentDelta: quantity,
          ...(metadata === undefined ? {} : { metadata }),
        },
      });
      return economy.fragmentBalance;
    });
  }

  /**
   * Spends Fragments to create copies of a card.
   *
   * Crafting above the deck copy limit is allowed on purpose: a spare is worth
   * something in a trade or as Fragments again, and the deck builder already
   * refuses to play more copies than the rules permit. Restricting it here
   * would only make the collection less useful without making any deck legal
   * that is not legal already.
   */
  async craft(
    userId: string,
    cardId: string,
    quantity = 1,
    requestId?: string,
  ): Promise<EconomyResult> {
    const count = normalizeQuantity(quantity);
    const policies = await this.expansions.policies();
    assertCraftable(policies, cardId);

    const card = getCardDefinition(cardId);
    const unitCost = craftCost(card.rarity, cardId);
    const cost = unitCost * count;

    return await this.runOnce(userId, 'CRAFT', requestId, async (tx) => {
      // Re-read the balance inside the transaction and update it
      // conditionally, so two simultaneous crafts cannot both see enough
      // Fragments and both succeed.
      const economy = await ensureEconomy(tx, userId);
      if (economy.fragmentBalance < cost) {
        throw new EconomyError(
          ECONOMY_ERRORS.INSUFFICIENT_FRAGMENTS,
          `Crafting ${count} × ${card.name} costs ${cost} Fragments; you have ${economy.fragmentBalance}`,
        );
      }
      const debited = await tx.userEconomy.updateMany({
        where: { userId, fragmentBalance: { gte: cost } },
        data: { fragmentBalance: { decrement: cost }, version: { increment: 1 } },
      });
      if (debited.count !== 1) {
        // Another request spent the Fragments between the read and the write.
        throw new EconomyError(
          ECONOMY_ERRORS.INSUFFICIENT_FRAGMENTS,
          'Your Fragment balance changed; try again',
        );
      }

      const entry = await addCopies(tx, userId, cardId, count);
      const balance = economy.fragmentBalance - cost;
      await tx.economyTransaction.create({
        data: {
          userId,
          type: 'CRAFT',
          cardId,
          quantity: count,
          fragmentDelta: -cost,
          ...(requestId ? { requestId } : {}),
          metadata: { rarity: card.rarity, unitCost, expansionId: card.expansionId },
        },
      });
      return {
        cardId,
        quantity: count,
        fragmentDelta: -cost,
        fragmentBalance: balance,
        owned: entry.quantity,
      };
    });
  }

  /** Converts owned copies back into Fragments. */
  async disenchant(
    userId: string,
    cardId: string,
    quantity = 1,
    requestId?: string,
  ): Promise<EconomyResult> {
    const count = normalizeQuantity(quantity);
    const policies = await this.expansions.policies();
    assertDisenchantable(policies, cardId);

    const card = getCardDefinition(cardId);
    const unitValue = disenchantValue(card.rarity, cardId);
    const gain = unitValue * count;

    return await this.runOnce(userId, 'DISENCHANT', requestId, async (tx) => {
      // The conditional delete is the lock: a copy can only be removed by
      // whichever request gets there first, so two disenchants of the same
      // single copy cannot both pay out.
      const removed = await tx.collectionEntry.updateMany({
        where: { userId, cardId, quantity: { gte: count } },
        data: { quantity: { decrement: count } },
      });
      if (removed.count !== 1) {
        const owned = await tx.collectionEntry.findUnique({
          where: { userId_cardId: { userId, cardId } },
        });
        throw new EconomyError(
          ECONOMY_ERRORS.INSUFFICIENT_CARD_QUANTITY,
          `You own ${owned?.quantity ?? 0} × ${card.name}, not ${count}`,
        );
      }
      const entry = await tx.collectionEntry.findUnique({
        where: { userId_cardId: { userId, cardId } },
      });
      const economy = await creditFragments(tx, userId, gain);
      await tx.economyTransaction.create({
        data: {
          userId,
          type: 'DISENCHANT',
          cardId,
          quantity: count,
          fragmentDelta: gain,
          ...(requestId ? { requestId } : {}),
          metadata: { rarity: card.rarity, unitValue, expansionId: card.expansionId },
        },
      });
      return {
        cardId,
        quantity: count,
        fragmentDelta: gain,
        fragmentBalance: economy.fragmentBalance,
        owned: entry?.quantity ?? 0,
      };
    });
  }

  /**
   * What disenchanting every spare copy would yield.
   *
   * Offered as a plan first and never performed on its own initiative: a spare
   * is only a spare by the deck rules, and a player may be holding it for a
   * trade. Copies whose expansion is not currently disenchantable are listed
   * as skipped rather than quietly dropped from the total.
   */
  async planDisenchantExtras(userId: string): Promise<DisenchantExtrasPlan> {
    const [entries, policies] = await Promise.all([
      this.prisma.collectionEntry.findMany({ where: { userId }, orderBy: { cardId: 'asc' } }),
      this.expansions.policies(),
    ]);

    const extras: DisenchantExtrasPlan['extras'] = [];
    const skipped: DisenchantExtrasPlan['skipped'] = [];
    let fragments = 0;

    for (const entry of entries) {
      const card = CARD_DEFINITIONS[entry.cardId];
      if (!card) continue;
      const limit = cardCopyLimit(entry.cardId);
      const extra = entry.quantity - limit;
      if (extra <= 0) continue;

      try {
        assertDisenchantable(policies, entry.cardId);
      } catch (error) {
        skipped.push({
          cardId: entry.cardId,
          extra,
          reason: error instanceof AccountError ? error.code : 'UNAVAILABLE',
        });
        continue;
      }

      const value = disenchantValue(card.rarity, card.id) * extra;
      fragments += value;
      extras.push({ cardId: entry.cardId, owned: entry.quantity, copyLimit: limit, extra, value });
    }

    return { extras, fragments, skipped };
  }

  /**
   * Disenchants every spare copy the plan covers, in one transaction.
   *
   * The plan is recomputed inside the transaction rather than trusted from the
   * client: what counted as a spare when the screen was drawn may since have
   * been traded away.
   */
  async disenchantExtras(userId: string, requestId?: string): Promise<DisenchantExtrasResult> {
    const plan = await this.planDisenchantExtras(userId);
    if (plan.extras.length === 0) {
      return {
        disenchanted: [],
        fragmentDelta: 0,
        fragmentBalance: await this.balance(userId),
        skipped: plan.skipped,
      };
    }

    return await this.runOnce(userId, 'DISENCHANT_EXTRAS', requestId, async (tx) => {
      const disenchanted: DisenchantExtrasResult['disenchanted'] = [];
      let fragmentDelta = 0;

      for (const item of plan.extras) {
        // Guarded on the full count the plan saw, not just on the spares:
        // if any copy has moved since, this card is left alone entirely
        // rather than cutting into the playset.
        const removed = await tx.collectionEntry.updateMany({
          where: { userId, cardId: item.cardId, quantity: { gte: item.owned } },
          data: { quantity: { decrement: item.extra } },
        });
        // A copy traded away since the plan was drawn simply drops out; the
        // rest of the batch is still worth doing.
        if (removed.count !== 1) continue;
        disenchanted.push({ cardId: item.cardId, quantity: item.extra });
        fragmentDelta += item.value;
        await tx.economyTransaction.create({
          data: {
            userId,
            type: 'DISENCHANT',
            cardId: item.cardId,
            quantity: item.extra,
            fragmentDelta: item.value,
            ...(requestId ? { requestId } : {}),
            metadata: { reason: 'DISENCHANT_EXTRAS', copyLimit: item.copyLimit },
          },
        });
      }

      const economy =
        fragmentDelta > 0
          ? await creditFragments(tx, userId, fragmentDelta)
          : await ensureEconomy(tx, userId);
      return {
        disenchanted,
        fragmentDelta,
        fragmentBalance: economy.fragmentBalance,
        skipped: plan.skipped,
      };
    });
  }

  /** A player's own economy history, newest first. */
  async history(userId: string, limit = 50) {
    return await this.prisma.economyTransaction.findMany({
      where: { userId },
      orderBy: { createdAt: 'desc' },
      take: Math.min(Math.max(1, Math.trunc(limit)), 200),
    });
  }

  /**
   * Runs an operation at most once per request id.
   *
   * The marker row is written inside the same transaction as the effects, so
   * either both land or neither does. A retry collides on the primary key and
   * is answered with the stored result — the player sees the outcome they were
   * always going to get, rather than paying twice for a lost response.
   */
  private async runOnce<T>(
    userId: string,
    operation: string,
    requestId: string | undefined,
    work: (tx: Prisma.TransactionClient) => Promise<T>,
  ): Promise<T> {
    if (!requestId) {
      return await this.prisma.$transaction((tx) => work(tx));
    }

    const existing = await this.prisma.economyRequest.findUnique({ where: { requestId } });
    if (existing) return replayResult<T>(existing, userId, operation);

    try {
      return await this.prisma.$transaction(async (tx) => {
        const result = await work(tx);
        await tx.economyRequest.create({
          data: {
            requestId,
            userId,
            operation,
            result: result as unknown as Prisma.InputJsonValue,
          },
        });
        return result;
      });
    } catch (error) {
      // Two copies of the same request racing: whichever lost replays the
      // winner's result rather than reporting a conflict the player caused.
      if (isUniqueViolation(error)) {
        const stored = await this.prisma.economyRequest.findUnique({ where: { requestId } });
        if (stored) return replayResult<T>(stored, userId, operation);
      }
      throw error;
    }
  }
}

function replayResult<T>(
  stored: { userId: string; operation: string; result: unknown },
  userId: string,
  operation: string,
): T {
  // A request id is the caller's to choose, so it must not become a way to
  // read somebody else's outcome or to replay a craft as a disenchant.
  if (stored.userId !== userId || stored.operation !== operation) {
    throw new AccountError('REQUEST_ID_REUSED', 'That request id has already been used', 409);
  }
  return stored.result as T;
}

/** Reads the economy row, creating it the first time a player needs one. */
async function ensureEconomy(tx: Prisma.TransactionClient, userId: string) {
  return await tx.userEconomy.upsert({
    where: { userId },
    create: { userId, fragmentBalance: 0 },
    update: {},
  });
}

async function creditFragments(tx: Prisma.TransactionClient, userId: string, amount: number) {
  await ensureEconomy(tx, userId);
  return await tx.userEconomy.update({
    where: { userId },
    data: { fragmentBalance: { increment: amount }, version: { increment: 1 } },
  });
}

/**
 * Adds copies to a collection.
 *
 * Deliberately uncapped, unlike the starter grant: crafting and trading may
 * take a player past the deck copy limit, because spares are the raw material
 * of both trading and disenchanting.
 */
async function addCopies(
  tx: Prisma.TransactionClient,
  userId: string,
  cardId: string,
  quantity: number,
) {
  return await tx.collectionEntry.upsert({
    where: { userId_cardId: { userId, cardId } },
    create: { userId, cardId, quantity },
    update: { quantity: { increment: quantity } },
  });
}

function normalizeQuantity(quantity: number): number {
  const count = Math.trunc(Number(quantity));
  if (!Number.isFinite(count) || count < 1) {
    throw new EconomyError(ECONOMY_ERRORS.INVALID_QUANTITY, 'Quantity must be at least 1', 400);
  }
  if (count > MAX_QUANTITY_PER_REQUEST) {
    throw new EconomyError(
      ECONOMY_ERRORS.INVALID_QUANTITY,
      `Quantity must be at most ${MAX_QUANTITY_PER_REQUEST}`,
      400,
    );
  }
  return count;
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === 'object' && error !== null && (error as { code?: unknown }).code === 'P2002'
  );
}
