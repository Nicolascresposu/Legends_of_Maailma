import express from 'express';
import type { PackService } from '../services/pack-service.js';
import type { Logger } from '../logger.js';
import { requireUser, respondAccountError } from './auth-routes.js';

/**
 * Packs.
 *
 * The listing shows only packs whose expansion is currently released and
 * available, and opening re-checks both — a client holding a stale list cannot
 * open a pack from a set that has since been withdrawn.
 */
export function createPackRouter(packs: PackService, logger: Logger): express.Router {
  const router = express.Router();
  router.use(requireUser());

  router.get('/', (request, response, next) => {
    packs
      .availablePacks()
      .then((available) => response.json({ packs: available }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/:packId/open', (request, response, next) => {
    const body = (request.body ?? {}) as { requestId?: unknown; seed?: unknown };
    const options: { requestId?: string; seed?: string } = {};
    const requestId = typeof body.requestId === 'string' ? body.requestId.trim() : '';
    if (requestId) options.requestId = requestId.slice(0, 128);
    packs
      .open(request.user!.id, String(request.params.packId), options)
      .then((opened) => {
        logger.info('Pack opened', {
          requestId: request.requestId,
          userId: request.user!.id,
          packId: opened.packId,
          cards: opened.cards.length,
        });
        response.json({ pack: opened });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  /** What a duplicate-protected pack would currently favour. Changes nothing. */
  router.get('/:packId/protection', (request, response, next) => {
    packs
      .protectionPreview(request.user!.id, String(request.params.packId))
      .then((preview) => response.json({ preview }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  return router;
}
