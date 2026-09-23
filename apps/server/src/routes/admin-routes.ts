import express from 'express';
import type { Logger } from '../logger.js';
import type { AdminService } from '../services/admin-service.js';
import { requireAdmin, requireUser, respondAccountError } from './auth-routes.js';

/**
 * The admin debug API: inspect any account and put it into whatever state a
 * test needs.
 *
 * Every route sits behind the admin guard, which answers everyone else with a
 * 404 so the API cannot be discovered by probing it. Every change is logged
 * with the admin who made it and the account it touched; changes to cards and
 * Fragments are also written to that account's economy ledger.
 */
export function createAdminRouter(admin: AdminService, logger: Logger): express.Router {
  const router = express.Router();
  router.use(requireUser(), requireAdmin());

  type Handler = (request: express.Request) => Promise<unknown> | unknown;

  /** A read: no log line, just the answer. */
  const read =
    (handler: Handler): express.RequestHandler =>
    (request, response, next) => {
      Promise.resolve()
        .then(() => handler(request))
        .then((payload) => response.json(payload))
        .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
    };

  /** A change: answered like a read, and logged as the admin's action. */
  const change =
    (action: string, handler: Handler, status = 200): express.RequestHandler =>
    (request, response, next) => {
      Promise.resolve()
        .then(() => handler(request))
        .then((payload) => {
          logger.info('Admin action', {
            requestId: request.requestId,
            adminId: request.user!.id,
            action,
            ...(request.params.userId ? { targetUserId: request.params.userId } : {}),
            ...(request.params.matchId ? { matchId: request.params.matchId } : {}),
            ...(request.params.cardId ? { cardId: request.params.cardId } : {}),
          });
          if (payload === undefined) response.status(204).end();
          else response.status(status).json(payload);
        })
        .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
    };

  const adminId = (request: express.Request) => request.user!.id;
  const userId = (request: express.Request) => String(request.params.userId);
  const body = (request: express.Request) => (request.body ?? {}) as Record<string, unknown>;

  /** Lets a panel confirm it is talking to the server as an admin. */
  router.get(
    '/',
    read((request) => ({ ok: true, admin: request.user })),
  );
  router.get(
    '/registry',
    read(() => admin.registry()),
  );

  // --- Accounts ------------------------------------------------------------

  router.get(
    '/users',
    read((request) =>
      admin
        .searchUsers(String(request.query.search ?? ''), Number(request.query.limit ?? 50))
        .then((users) => ({ users })),
    ),
  );
  router.get(
    '/users/:userId',
    read((request) => admin.overview(userId(request))),
  );
  router.patch(
    '/users/:userId',
    change('SET_ADMIN', (request) =>
      admin.setAdmin(adminId(request), userId(request), body(request).isAdmin === true),
    ),
  );
  router.post(
    '/users/:userId/sessions',
    change('IMPERSONATE', (request) => admin.impersonate(userId(request)), 201),
  );
  router.delete(
    '/users/:userId/sessions',
    change('REVOKE_SESSIONS', (request) => admin.revokeSessions(userId(request))),
  );

  // --- Collection ----------------------------------------------------------

  router.get(
    '/users/:userId/collection',
    read((request) => admin.collection(userId(request))),
  );
  router.put(
    '/users/:userId/collection/:cardId',
    change('SET_CARD', (request) =>
      admin.setCardQuantity(
        adminId(request),
        userId(request),
        String(request.params.cardId),
        body(request).quantity,
      ),
    ),
  );
  router.post(
    '/users/:userId/collection/grant-all',
    change('GRANT_ALL', (request) =>
      admin.grantAll(adminId(request), userId(request), {
        copies: body(request).copies,
        includeUnreleased: body(request).includeUnreleased,
      }),
    ),
  );
  router.post(
    '/users/:userId/collection/reset',
    change('RESET_COLLECTION', (request) =>
      admin.resetCollection(adminId(request), userId(request)),
    ),
  );

  // --- Fragments -----------------------------------------------------------

  router.post(
    '/users/:userId/fragments',
    change('ADJUST_FRAGMENTS', (request) =>
      admin.adjustFragments(adminId(request), userId(request), body(request).amount),
    ),
  );
  router.put(
    '/users/:userId/fragments',
    change('SET_FRAGMENTS', (request) =>
      admin.setFragments(adminId(request), userId(request), body(request).balance),
    ),
  );
  router.get(
    '/users/:userId/ledger',
    read((request) =>
      admin.ledger(userId(request), request.query.limit).then((transactions) => ({ transactions })),
    ),
  );

  // --- Decks and packs -----------------------------------------------------

  router.get(
    '/users/:userId/decks',
    read((request) => admin.decks(userId(request)).then((decks) => ({ decks }))),
  );
  router.post(
    '/users/:userId/decks/starter',
    change(
      'CREATE_STARTER_DECK',
      (request) =>
        admin
          .createStarterDeck(userId(request), body(request).heroId, body(request).name)
          .then((deck) => ({ deck })),
      201,
    ),
  );
  router.delete(
    '/users/:userId/decks/:deckId',
    change('DELETE_DECK', (request) =>
      admin.deleteDeck(userId(request), String(request.params.deckId)),
    ),
  );
  router.post(
    '/users/:userId/packs/:packId/open',
    change('OPEN_PACK', (request) =>
      admin
        .openPack(userId(request), String(request.params.packId), body(request).seed)
        .then((pack) => ({ pack })),
    ),
  );

  // --- Social and trades ---------------------------------------------------

  router.post(
    '/friendships',
    change(
      'BEFRIEND',
      (request) =>
        admin
          .befriend(String(body(request).userA ?? ''), String(body(request).userB ?? ''))
          .then((friendship) => ({ friendship })),
      201,
    ),
  );
  router.get(
    '/users/:userId/trades',
    read((request) => admin.trades(userId(request)).then((trades) => ({ trades }))),
  );
  router.post(
    '/trades/:tradeId/cancel',
    change('CANCEL_TRADE', (request) =>
      admin.cancelTrade(String(request.params.tradeId)).then((trade) => ({ trade })),
    ),
  );

  // --- Matches -------------------------------------------------------------

  router.get(
    '/matches',
    read(() => ({ matches: admin.listMatches() })),
  );
  router.post(
    '/matches',
    change(
      'START_DEBUG_MATCH',
      (request) =>
        admin
          .startDebugMatch({
            userId: body(request).userId,
            scenarioId: body(request).scenarioId,
            heroId: body(request).heroId,
            cardIds: body(request).cardIds,
          })
          .then((match) => ({ match })),
      201,
    ),
  );
  router.get(
    '/matches/:matchId',
    read((request) => admin.match(String(request.params.matchId))),
  );
  router.post(
    '/matches/:matchId/hand',
    change('ADD_CARD_TO_HAND', (request) =>
      admin.addCardToHand(
        String(request.params.matchId),
        body(request).playerId,
        body(request).cardId,
      ),
    ),
  );
  router.post(
    '/matches/:matchId/stats',
    change('SET_STATS', (request) =>
      admin.setStats(
        String(request.params.matchId),
        body(request).entityId,
        body(request).attack,
        body(request).health,
      ),
    ),
  );
  router.delete(
    '/matches/:matchId',
    change('END_MATCH', (request) => admin.endMatch(String(request.params.matchId))),
  );

  return router;
}
