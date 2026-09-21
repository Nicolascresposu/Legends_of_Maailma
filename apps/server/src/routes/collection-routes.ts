import express from 'express';
import type { CollectionService } from '../services/collection-service.js';
import type { Logger } from '../logger.js';
import { requireUser, respondAccountError } from './auth-routes.js';

export function createCollectionRouter(
  collections: CollectionService,
  logger: Logger,
): express.Router {
  const router = express.Router();
  router.use(requireUser());

  /**
   * The whole collectible registry with the player's owned counts attached,
   * so a browser can show what exists but is not yet unlocked.
   */
  router.get('/', (request, response, next) => {
    collections
      .browse(request.user!.id)
      .then((cards) => response.json({ cards }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  /** Checks an arbitrary card list without saving it, for a deck builder. */
  router.post('/assess', (request, response, next) => {
    const body = request.body as { cardIds?: unknown };
    const cardIds = Array.isArray(body?.cardIds) ? body.cardIds.map((id) => String(id)) : [];
    collections
      .assessForUser(request.user!.id, cardIds)
      .then((readiness) => response.json({ readiness }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  return router;
}
