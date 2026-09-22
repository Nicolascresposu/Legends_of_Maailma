import express from 'express';
import type { EconomyService } from '../services/economy-service.js';
import type { Logger } from '../logger.js';
import { requireUser, respondAccountError } from './auth-routes.js';

/**
 * Fragments, crafting and disenchanting.
 *
 * Every mutation accepts an optional `requestId` the client chooses, so a
 * retried request after a lost response replays the original outcome rather
 * than spending Fragments twice. Nothing here trusts the client for anything
 * else: costs, policy and ownership are all decided server-side.
 */
export function createEconomyRouter(economy: EconomyService, logger: Logger): express.Router {
  const router = express.Router();
  router.use(requireUser());

  router.get('/', (request, response, next) => {
    economy
      .balance(request.user!.id)
      .then((fragments) => response.json({ fragments }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.get('/history', (request, response, next) => {
    const limit = Number(request.query.limit ?? 50);
    economy
      .history(request.user!.id, Number.isFinite(limit) ? limit : 50)
      .then((transactions) => response.json({ transactions }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/craft', (request, response, next) => {
    const body = (request.body ?? {}) as {
      cardId?: unknown;
      quantity?: unknown;
      requestId?: unknown;
    };
    economy
      .craft(
        request.user!.id,
        String(body.cardId ?? ''),
        Number(body.quantity ?? 1),
        optionalId(body.requestId),
      )
      .then((result) => {
        logger.info('Card crafted', {
          requestId: request.requestId,
          userId: request.user!.id,
          cardId: result.cardId,
          quantity: result.quantity,
          fragmentDelta: result.fragmentDelta,
        });
        response.json({ result });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/disenchant', (request, response, next) => {
    const body = (request.body ?? {}) as {
      cardId?: unknown;
      quantity?: unknown;
      requestId?: unknown;
    };
    economy
      .disenchant(
        request.user!.id,
        String(body.cardId ?? ''),
        Number(body.quantity ?? 1),
        optionalId(body.requestId),
      )
      .then((result) => {
        logger.info('Card disenchanted', {
          requestId: request.requestId,
          userId: request.user!.id,
          cardId: result.cardId,
          quantity: result.quantity,
          fragmentDelta: result.fragmentDelta,
        });
        response.json({ result });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  /** What disenchanting every spare would yield. Changes nothing. */
  router.get('/extras', (request, response, next) => {
    economy
      .planDisenchantExtras(request.user!.id)
      .then((plan) => response.json({ plan }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  /**
   * Performs that plan. A separate, explicit request: spares are never
   * disenchanted because the server noticed them.
   */
  router.post('/extras', (request, response, next) => {
    const body = (request.body ?? {}) as { requestId?: unknown };
    economy
      .disenchantExtras(request.user!.id, optionalId(body.requestId))
      .then((result) => {
        logger.info('Extras disenchanted', {
          requestId: request.requestId,
          userId: request.user!.id,
          cards: result.disenchanted.length,
          fragmentDelta: result.fragmentDelta,
        });
        response.json({ result });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  return router;
}

function optionalId(value: unknown): string | undefined {
  const id = typeof value === 'string' ? value.trim() : '';
  return id === '' ? undefined : id.slice(0, 128);
}
