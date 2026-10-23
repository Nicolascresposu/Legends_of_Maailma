import express from 'express';
import { captureCardContent } from '@maailma/card-definitions';
import type { Logger } from '../logger.js';
import type { ContentPublishingService } from '../services/content-publishing-service.js';
import { AccountError } from '../services/account-service.js';
import { requireUser, requireAdmin, respondAccountError } from './auth-routes.js';

export function createContentRouter(
  publishing: ContentPublishingService | undefined,
  logger: Logger,
): express.Router {
  const router = express.Router();
  router.use(requireUser(), requireAdmin());
  const service = () => {
    if (!publishing)
      throw new AccountError(
        'CONTENT_PUBLISHING_DISABLED',
        'This server has no content publishing store configured.',
        403,
      );
    return publishing;
  };
  const handle =
    (action: (request: express.Request) => unknown): express.RequestHandler =>
    (request, response, next) => {
      try {
        response.json(action(request));
      } catch (error) {
        respondAccountError(error, request, response, logger, next);
      }
    };
  router.get(
    '/',
    handle(
      () =>
        publishing?.status() ?? {
          enabled: false,
          currentVersion: captureCardContent().version,
          history: [],
          expansions: [],
        },
    ),
  );
  router.get(
    '/expansions/:id',
    handle((request) => ({ document: service().expansion(String(request.params.id)) })),
  );
  router.post(
    '/preview',
    handle((request) => {
      const review = service().preview(request.body?.document);
      return {
        baseVersion: review.baseVersion,
        candidateVersion: review.candidateVersion,
        changes: review.changes,
      };
    }),
  );
  router.get(
    '/versions/:version/preview',
    handle((request) => {
      const review = service().previewRollback(String(request.params.version));
      return {
        baseVersion: review.baseVersion,
        candidateVersion: review.candidateVersion,
        changes: review.changes,
      };
    }),
  );
  router.post(
    '/publish',
    handle((request) => {
      const result = service().publish(
        request.body?.document,
        request.body?.baseVersion,
        request.body?.candidateVersion,
        request.user!.id,
      );
      logger.info('Content published', {
        adminId: request.user!.id,
        version: result.currentVersion,
        unchanged: result.unchanged,
      });
      return result;
    }),
  );
  router.post(
    '/rollback',
    handle((request) => {
      const result = service().rollback(
        String(request.body?.version ?? ''),
        request.body?.baseVersion,
        request.body?.candidateVersion,
        request.user!.id,
      );
      logger.info('Content rolled back', {
        adminId: request.user!.id,
        version: result.currentVersion,
        unchanged: result.unchanged,
      });
      return result;
    }),
  );
  return router;
}
