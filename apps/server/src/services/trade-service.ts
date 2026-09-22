import type { PrismaClient, Trade, TradeItem } from '@prisma/client';
import { getCardDefinition } from '@maailma/card-definitions';
import { AccountError } from './account-service.js';
import {
  ECONOMY_ERRORS,
  EconomyError,
  assertTradeable,
  expansionOf,
  type ExpansionService,
} from './expansion-service.js';

/** One card stack on one side of an offer. */
export interface TradeCardQuantity {
  cardId: string;
  quantity: number;
}

export interface TradeOfferView {
  userId: string;
  displayName?: string;
  cards: TradeCardQuantity[];
  /** Whether this participant has accepted the revision currently on offer. */
  accepted: boolean;
}

export interface TradeView {
  id: string;
  status: Trade['status'];
  revision: number;
  offers: [TradeOfferView, TradeOfferView];
  createdAt: Date;
  updatedAt: Date;
  completedAt: Date | null;
  failureCode: string | null;
  failureMessage: string | null;
}

/** Most distinct cards one side may offer, so an offer cannot grow unbounded. */
const MAX_OFFER_ENTRIES = 40;
const MAX_CARD_QUANTITY = 99;

/**
 * Player-to-player card trading.
 *
 * Three decisions shape this service.
 *
 * Offered cards are not reserved. A card sitting in an open trade may still be
 * disenchanted, or offered in a second trade, or given away elsewhere; it is
 * the trade that fails at execution rather than the other actions that are
 * blocked. Reservations would mean tracking committed-but-unspent copies across
 * every open trade, and for a small friends-focused game that machinery costs
 * more than it saves.
 *
 * Both players confirm the same revision. Editing either side's offer clears
 * both acceptances and advances the revision, so a player cannot accept a
 * generous offer and have it execute after the other side has quietly swapped
 * it for a worse one.
 *
 * Everything is re-checked at execution. Policy, ownership and participation
 * are all read again inside the committing transaction — never trusted from
 * when a card was first added to the offer, because an expansion may have
 * stopped being tradeable in between.
 */
export class TradeService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly expansions: ExpansionService,
  ) {}

  /** Opens an empty trade between two players. */
  async create(userId: string, otherUserId: string): Promise<TradeView> {
    if (userId === otherUserId) {
      throw new AccountError('SELF_TRADE', 'You cannot trade with yourself');
    }
    const other = await this.prisma.user.findUnique({ where: { id: otherUserId } });
    if (!other) throw new AccountError('USER_NOT_FOUND', 'No such player', 404);

    const trade = await this.prisma.trade.create({
      data: { participantAId: userId, participantBId: otherUserId },
      include: { items: true },
    });
    return await this.view(trade, trade.items);
  }

  async get(userId: string, tradeId: string): Promise<TradeView> {
    const trade = await this.load(userId, tradeId);
    return await this.view(trade, trade.items);
  }

  /** Every trade this player is part of, newest first. */
  async list(userId: string, status?: Trade['status']): Promise<TradeView[]> {
    const trades = await this.prisma.trade.findMany({
      where: {
        OR: [{ participantAId: userId }, { participantBId: userId }],
        ...(status ? { status } : {}),
      },
      include: { items: true },
      orderBy: { updatedAt: 'desc' },
      take: 50,
    });
    return await Promise.all(trades.map((trade) => this.view(trade, trade.items)));
  }

  /**
   * Replaces one player's side of the offer.
   *
   * Either participant may only edit their own side. Both acceptances are
   * cleared regardless of whose side changed: an acceptance means "I agree to
   * this exact exchange", and any change makes a previous agreement stale.
   */
  async updateOffer(
    userId: string,
    tradeId: string,
    cards: readonly TradeCardQuantity[],
  ): Promise<TradeView> {
    const trade = await this.load(userId, tradeId);
    assertOpen(trade);

    const normalized = normalizeOffer(cards);
    // Cards are checked against policy as they are added too, so a player is
    // told immediately rather than at execution. This is a courtesy, not the
    // safeguard: execution re-checks everything.
    const policies = await this.expansions.policies();
    for (const entry of normalized) assertTradeable(policies, entry.cardId);

    const updated = await this.prisma.$transaction(async (tx) => {
      await tx.tradeItem.deleteMany({ where: { tradeId, offeringUserId: userId } });
      if (normalized.length > 0) {
        await tx.tradeItem.createMany({
          data: normalized.map((entry) => ({
            tradeId,
            offeringUserId: userId,
            cardId: entry.cardId,
            quantity: entry.quantity,
          })),
        });
      }
      return await tx.trade.update({
        where: { id: tradeId },
        data: {
          revision: { increment: 1 },
          acceptedARev: null,
          acceptedBRev: null,
          failureCode: null,
          failureMessage: null,
        },
        include: { items: true },
      });
    });
    return await this.view(updated, updated.items);
  }

  /**
   * Accepts the revision currently on offer.
   *
   * The revision the client saw is required, so an acceptance can never attach
   * itself to an offer that changed while the player was reading it. When the
   * second acceptance lands, the trade executes.
   */
  async accept(userId: string, tradeId: string, revision: number): Promise<TradeView> {
    const trade = await this.load(userId, tradeId);
    assertOpen(trade);
    if (trade.revision !== revision) {
      throw new EconomyError(
        ECONOMY_ERRORS.TRADE_REVISION_CHANGED,
        'The offer changed; review it and accept again',
      );
    }

    const isA = trade.participantAId === userId;
    // Guarded on the revision so an acceptance cannot land on an offer edited
    // between the check above and this write.
    const marked = await this.prisma.trade.updateMany({
      where: { id: tradeId, status: 'OPEN', revision },
      data: isA ? { acceptedARev: revision } : { acceptedBRev: revision },
    });
    if (marked.count !== 1) {
      throw new EconomyError(
        ECONOMY_ERRORS.TRADE_REVISION_CHANGED,
        'The offer changed; review it and accept again',
      );
    }

    const current = await this.prisma.trade.findUnique({
      where: { id: tradeId },
      include: { items: true },
    });
    if (!current) throw new AccountError('TRADE_NOT_FOUND', 'Trade not found', 404);

    const bothAccepted =
      current.acceptedARev === current.revision && current.acceptedBRev === current.revision;
    if (!bothAccepted) return await this.view(current, current.items);

    return await this.execute(tradeId, current.revision);
  }

  /** Withdraws an acceptance while the trade is still open. */
  async unaccept(userId: string, tradeId: string): Promise<TradeView> {
    const trade = await this.load(userId, tradeId);
    assertOpen(trade);
    const isA = trade.participantAId === userId;
    const updated = await this.prisma.trade.update({
      where: { id: tradeId },
      data: isA ? { acceptedARev: null } : { acceptedBRev: null },
      include: { items: true },
    });
    return await this.view(updated, updated.items);
  }

  /**
   * Cancels an open trade. Either participant may do it, and nothing moves:
   * no cards, no Fragments, no partial transfer.
   */
  async cancel(userId: string, tradeId: string): Promise<TradeView> {
    const trade = await this.load(userId, tradeId);
    assertOpen(trade);
    const cancelled = await this.prisma.trade.update({
      where: { id: tradeId },
      data: { status: 'CANCELLED' },
      include: { items: true },
    });
    return await this.view(cancelled, cancelled.items);
  }

  /**
   * What a completed trade moved, for either participant.
   *
   * Read from the frozen history rather than from the trade's items, so it
   * goes on reading true after the expansions involved stop being tradeable.
   */
  async history(userId: string, limit = 50) {
    return await this.prisma.tradeHistoryEntry.findMany({
      where: { OR: [{ fromUserId: userId }, { toUserId: userId }] },
      orderBy: { completedAt: 'desc' },
      take: Math.min(Math.max(1, Math.trunc(limit)), 200),
    });
  }

  /**
   * Moves the cards, in one transaction.
   *
   * Everything is revalidated here even though it was checked when the offer
   * was built: policies change, and a player may have disenchanted a card they
   * offered an hour ago. A failure marks the trade FAILED with a reason the UI
   * can explain, rather than leaving it open to fail again the same way.
   */
  private async execute(tradeId: string, revision: number): Promise<TradeView> {
    const policies = await this.expansions.policies();

    try {
      const committed = await this.prisma.$transaction(async (tx) => {
        const trade = await tx.trade.findUnique({
          where: { id: tradeId },
          include: { items: true },
        });
        if (!trade) throw new AccountError('TRADE_NOT_FOUND', 'Trade not found', 404);
        if (trade.status !== 'OPEN') {
          throw new EconomyError(ECONOMY_ERRORS.TRADE_REVISION_CHANGED, 'Trade is no longer open');
        }
        if (trade.revision !== revision) {
          throw new EconomyError(
            ECONOMY_ERRORS.TRADE_REVISION_CHANGED,
            'The offer changed before it could be completed',
          );
        }
        if (trade.acceptedARev !== revision || trade.acceptedBRev !== revision) {
          throw new EconomyError(
            ECONOMY_ERRORS.TRADE_REVISION_CHANGED,
            'Both players must accept the same offer',
          );
        }

        // Both accounts must still exist: a deleted one cascades its rows away
        // and would leave a transfer with nowhere to go.
        const participants = await tx.user.findMany({
          where: { id: { in: [trade.participantAId, trade.participantBId] } },
          select: { id: true },
        });
        if (participants.length !== 2) {
          throw new AccountError('USER_NOT_FOUND', 'A participant no longer exists', 404);
        }

        // Policy, re-read now. An expansion that stopped being tradeable while
        // the offer sat open refuses the whole trade.
        for (const item of trade.items) assertTradeable(policies, item.cardId);

        // Ownership, re-read now, and decremented conditionally so that a copy
        // promised to two trades at once can only actually leave once.
        for (const item of trade.items) {
          const moved = await tx.collectionEntry.updateMany({
            where: {
              userId: item.offeringUserId,
              cardId: item.cardId,
              quantity: { gte: item.quantity },
            },
            data: { quantity: { decrement: item.quantity } },
          });
          if (moved.count !== 1) {
            const card = getCardDefinition(item.cardId);
            throw new EconomyError(
              ECONOMY_ERRORS.INSUFFICIENT_CARD_QUANTITY,
              `A player no longer owns ${item.quantity} × ${card.name}`,
            );
          }
        }

        for (const item of trade.items) {
          const recipient =
            item.offeringUserId === trade.participantAId
              ? trade.participantBId
              : trade.participantAId;
          await tx.collectionEntry.upsert({
            where: { userId_cardId: { userId: recipient, cardId: item.cardId } },
            create: { userId: recipient, cardId: item.cardId, quantity: item.quantity },
            update: { quantity: { increment: item.quantity } },
          });

          // Frozen at the moment of commit, including the policy context that
          // permitted it, so history never has to be re-judged later.
          const expansion = expansionOf(policies, item.cardId);
          await tx.tradeHistoryEntry.create({
            data: {
              tradeId,
              revision,
              fromUserId: item.offeringUserId,
              toUserId: recipient,
              cardId: item.cardId,
              quantity: item.quantity,
              context: {
                expansionId: expansion.id,
                expansionName: expansion.name,
                policy: { ...expansion.policy },
              },
            },
          });
          await tx.economyTransaction.create({
            data: {
              userId: item.offeringUserId,
              type: 'TRADE',
              cardId: item.cardId,
              quantity: -item.quantity,
              fragmentDelta: 0,
              tradeId,
              metadata: { direction: 'SENT', counterpartyId: recipient },
            },
          });
          await tx.economyTransaction.create({
            data: {
              userId: recipient,
              type: 'TRADE',
              cardId: item.cardId,
              quantity: item.quantity,
              fragmentDelta: 0,
              tradeId,
              metadata: { direction: 'RECEIVED', counterpartyId: item.offeringUserId },
            },
          });
        }

        return await tx.trade.update({
          where: { id: tradeId },
          data: { status: 'ACCEPTED', completedAt: new Date() },
          include: { items: true },
        });
      });

      return await this.view(committed, committed.items);
    } catch (error) {
      // Nothing moved — the transaction rolled back. Record why, so the trade
      // does not simply look open and inexplicably unfinishable.
      if (error instanceof AccountError) {
        const failed = await this.prisma.trade.update({
          where: { id: tradeId },
          data: {
            status: 'FAILED',
            failureCode: error.code,
            failureMessage: error.message,
            acceptedARev: null,
            acceptedBRev: null,
          },
          include: { items: true },
        });
        return await this.view(failed, failed.items);
      }
      throw error;
    }
  }

  private async load(userId: string, tradeId: string) {
    const trade = await this.prisma.trade.findUnique({
      where: { id: tradeId },
      include: { items: true },
    });
    // Another player's trade is reported missing rather than forbidden, so
    // trade ids cannot be probed for existence.
    if (!trade || (trade.participantAId !== userId && trade.participantBId !== userId)) {
      throw new AccountError('TRADE_NOT_FOUND', 'Trade not found', 404);
    }
    return trade;
  }

  private async view(trade: Trade, items: TradeItem[]): Promise<TradeView> {
    const names = await this.prisma.user.findMany({
      where: { id: { in: [trade.participantAId, trade.participantBId] } },
      select: { id: true, displayName: true },
    });
    const nameOf = new Map(names.map((row) => [row.id, row.displayName]));

    const side = (userId: string): TradeOfferView => {
      const displayName = nameOf.get(userId);
      return {
        userId,
        ...(displayName ? { displayName } : {}),
        cards: items
          .filter((item) => item.offeringUserId === userId)
          .map((item) => ({ cardId: item.cardId, quantity: item.quantity }))
          .sort((a, b) => a.cardId.localeCompare(b.cardId)),
        accepted:
          (userId === trade.participantAId ? trade.acceptedARev : trade.acceptedBRev) ===
          trade.revision,
      };
    };

    return {
      id: trade.id,
      status: trade.status,
      revision: trade.revision,
      offers: [side(trade.participantAId), side(trade.participantBId)],
      createdAt: trade.createdAt,
      updatedAt: trade.updatedAt,
      completedAt: trade.completedAt,
      failureCode: trade.failureCode,
      failureMessage: trade.failureMessage,
    };
  }
}

function assertOpen(trade: Trade): void {
  if (trade.status === 'OPEN') return;
  throw new AccountError('TRADE_NOT_OPEN', `This trade is ${trade.status.toLowerCase()}`, 409);
}

/**
 * Collapses an offer into one entry per card.
 *
 * A card listed twice is summed rather than stored twice, so the offer a
 * player confirms is unambiguous and the unique constraint on the table
 * matches what the domain already requires.
 */
function normalizeOffer(cards: readonly TradeCardQuantity[]): TradeCardQuantity[] {
  if (!Array.isArray(cards)) {
    throw new AccountError('INVALID_OFFER', 'An offer must be a list of cards');
  }
  const totals = new Map<string, number>();
  for (const entry of cards) {
    const cardId = String(entry?.cardId ?? '');
    const quantity = Math.trunc(Number(entry?.quantity ?? 0));
    if (cardId === '') throw new AccountError('INVALID_OFFER', 'Every offered card needs an id');
    // Fragments are not cards and have no place in this structure; there is
    // simply nowhere here for them to be named.
    getCardDefinition(cardId);
    if (!Number.isFinite(quantity) || quantity <= 0) {
      throw new EconomyError(
        ECONOMY_ERRORS.INVALID_QUANTITY,
        `Offered quantity for ${cardId} must be at least 1`,
        400,
      );
    }
    totals.set(cardId, (totals.get(cardId) ?? 0) + quantity);
  }
  const normalized = [...totals]
    .map(([cardId, quantity]) => ({ cardId, quantity }))
    .sort((a, b) => a.cardId.localeCompare(b.cardId));

  if (normalized.length > MAX_OFFER_ENTRIES) {
    throw new AccountError('INVALID_OFFER', `An offer may name at most ${MAX_OFFER_ENTRIES} cards`);
  }
  for (const entry of normalized) {
    if (entry.quantity > MAX_CARD_QUANTITY) {
      throw new EconomyError(
        ECONOMY_ERRORS.INVALID_QUANTITY,
        `Offered quantity for ${entry.cardId} may be at most ${MAX_CARD_QUANTITY}`,
        400,
      );
    }
  }
  return normalized;
}
