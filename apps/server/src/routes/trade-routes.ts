import express from 'express';
import type { TradeCardQuantity, TradeService } from '../services/trade-service.js';
import type { Logger } from '../logger.js';
import { requireUser, respondAccountError } from './auth-routes.js';

/**
 * Trading.
 *
 * The server owns every decision: which cards may move, whether both players
 * agreed to the same offer, and whether either still owns what they promised.
 * A client builds offers and displays them, and nothing more.
 */
export function createTradeRouter(trades: TradeService, logger: Logger): express.Router {
  const router = express.Router();
  router.use(requireUser());

  router.get('/', (request, response, next) => {
    const status = typeof request.query.status === 'string' ? request.query.status : undefined;
    trades
      .list(request.user!.id, status as never)
      .then((list) => response.json({ trades: list }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.get('/history', (request, response, next) => {
    const limit = Number(request.query.limit ?? 50);
    trades
      .history(request.user!.id, Number.isFinite(limit) ? limit : 50)
      .then((entries) => response.json({ history: entries }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/', (request, response, next) => {
    const body = (request.body ?? {}) as { opponentId?: unknown };
    trades
      .create(request.user!.id, String(body.opponentId ?? ''))
      .then((trade) => {
        logger.info('Trade opened', {
          requestId: request.requestId,
          userId: request.user!.id,
          tradeId: trade.id,
        });
        response.status(201).json({ trade });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.get('/:tradeId', (request, response, next) => {
    trades
      .get(request.user!.id, String(request.params.tradeId))
      .then((trade) => response.json({ trade }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  /** Replaces the caller's own side of the offer. */
  router.put('/:tradeId/offer', (request, response, next) => {
    const body = (request.body ?? {}) as { cards?: unknown };
    const cards = Array.isArray(body.cards) ? (body.cards as TradeCardQuantity[]) : [];
    trades
      .updateOffer(request.user!.id, String(request.params.tradeId), cards)
      .then((trade) => response.json({ trade }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  /**
   * Accepts a specific revision. Sending the revision is what stops an
   * acceptance from attaching itself to an offer that changed in the meantime.
   */
  router.post('/:tradeId/accept', (request, response, next) => {
    const body = (request.body ?? {}) as { revision?: unknown };
    trades
      .accept(request.user!.id, String(request.params.tradeId), Number(body.revision ?? -1))
      .then((trade) => {
        logger.info('Trade acceptance recorded', {
          requestId: request.requestId,
          userId: request.user!.id,
          tradeId: trade.id,
          revision: trade.revision,
          status: trade.status,
        });
        response.json({ trade });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/:tradeId/unaccept', (request, response, next) => {
    trades
      .unaccept(request.user!.id, String(request.params.tradeId))
      .then((trade) => response.json({ trade }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/:tradeId/cancel', (request, response, next) => {
    trades
      .cancel(request.user!.id, String(request.params.tradeId))
      .then((trade) => response.json({ trade }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  return router;
}
