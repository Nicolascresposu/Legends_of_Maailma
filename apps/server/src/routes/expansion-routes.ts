import express from 'express';
import type { ExpansionPolicy } from '@maailma/game-model';
import { EXPANSION_POLICY_FLAGS } from '@maailma/game-model';
import type { ExpansionService } from '../services/expansion-service.js';
import type { Logger } from '../logger.js';
import { requireAdmin, requireUser, respondAccountError } from './auth-routes.js';

/**
 * Expansions and the policies governing them.
 *
 * Two audiences, deliberately separated. Players see released expansions and
 * what they may currently do with them. Administrators see everything,
 * including sets that have not launched, and may change any flag — which takes
 * effect on the next request, with no redeploy and no migration.
 */
export function createExpansionRouter(
  expansions: ExpansionService,
  logger: Logger,
): express.Router {
  const router = express.Router();
  router.use(requireUser());

  /** Released expansions with their live policies, for the collection UI. */
  router.get('/', (request, response, next) => {
    expansions
      .visibleExpansions()
      .then((list) => response.json({ expansions: list }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  /** Everything, unreleased included. Behind the admin guard. */
  router.get('/admin', requireAdmin(), (request, response, next) => {
    expansions
      .allExpansions()
      .then((list) => response.json({ expansions: list }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  /**
   * Changes policy flags.
   *
   * Accepts a partial body so that rotating one flag does not require restating
   * the other six — restating them is exactly how a stale client would undo
   * somebody else's change. Whatever is omitted keeps the value currently in
   * force.
   */
  router.patch('/admin/:expansionId', requireAdmin(), (request, response, next) => {
    const body = (request.body ?? {}) as Record<string, unknown>;
    const changes: Partial<ExpansionPolicy> = {};
    for (const flag of EXPANSION_POLICY_FLAGS) {
      if (flag in body) changes[flag] = body[flag] as boolean;
    }
    expansions
      .updateFlags(String(request.params.expansionId), changes, request.user!.id)
      .then((expansion) => {
        logger.info('Expansion policy changed', {
          requestId: request.requestId,
          userId: request.user!.id,
          expansionId: expansion.id,
          policy: expansion.policy,
        });
        response.json({ expansion });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  /** Restores the policy shipped with the card definitions. */
  router.delete('/admin/:expansionId/override', requireAdmin(), (request, response, next) => {
    expansions
      .clearOverride(String(request.params.expansionId))
      .then((expansion) => {
        logger.info('Expansion policy reset to shipped defaults', {
          requestId: request.requestId,
          userId: request.user!.id,
          expansionId: expansion.id,
        });
        response.json({ expansion });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  return router;
}
