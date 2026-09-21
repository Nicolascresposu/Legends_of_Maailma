import express from 'express';
import type { DeckService } from '../services/deck-service.js';
import type { Logger } from '../logger.js';
import { requireUser, respondAccountError } from './auth-routes.js';

export function createDeckRouter(decks: DeckService, logger: Logger): express.Router {
  const router = express.Router();
  router.use(requireUser());

  router.get('/', (request, response, next) => {
    decks
      .list(request.user!.id)
      .then((list) => response.json({ decks: list }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/', (request, response, next) => {
    decks
      .create(request.user!.id, request.body as never)
      .then((deck) => {
        logger.info('Deck saved', {
          requestId: request.requestId,
          userId: request.user!.id,
          deckId: deck.id,
        });
        response.status(201).json({ deck });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.get('/:deckId', (request, response, next) => {
    decks
      .get(request.user!.id, request.params.deckId)
      .then((deck) => response.json({ deck }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.put('/:deckId', (request, response, next) => {
    decks
      .update(request.user!.id, request.params.deckId, request.body as never)
      .then((deck) => response.json({ deck }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.delete('/:deckId', (request, response, next) => {
    decks
      .remove(request.user!.id, request.params.deckId)
      .then(() => response.status(204).end())
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/:deckId/active', (request, response, next) => {
    decks
      .setActive(request.user!.id, request.params.deckId)
      .then((deck) => response.json({ deck }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  return router;
}
