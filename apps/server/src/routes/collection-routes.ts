import express from 'express';
import type { DeckFormat } from '@maailma/game-model';
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

  /**
   * Checks an arbitrary card list without saving it, for a deck builder.
   *
   * The format is part of the question, not a property of the list: the same
   * thirty cards are a legal Wild deck and an illegal Standard one once a set
   * rotates, and a builder needs to ask about either. So is the hero, which
   * decides which class's cards the list may hold.
   */
  router.post('/assess', (request, response, next) => {
    const body = request.body as { cardIds?: unknown; format?: unknown; heroId?: unknown };
    const cardIds = Array.isArray(body?.cardIds) ? body.cardIds.map((id) => String(id)) : [];
    const format: DeckFormat = body?.format === 'WILD' ? 'WILD' : 'STANDARD';
    // The hero decides the deck's class. Optional, so a list can still be
    // checked before a hero is picked — class is then simply not judged.
    const heroId = typeof body?.heroId === 'string' && body.heroId !== '' ? body.heroId : undefined;
    collections
      .assessForUser(request.user!.id, cardIds, format, heroId)
      .then((readiness) => response.json({ readiness }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  return router;
}
