import express from 'express';
import { bearerToken } from '../auth/tokens.js';
import {
  AccountError,
  type AccountService,
  type AuthenticatedUser,
} from '../services/account-service.js';
import { errorFields, type Logger } from '../logger.js';

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      user?: AuthenticatedUser;
      sessionToken?: string;
    }
  }
}

/**
 * Attaches the signed-in user to the request when a valid bearer token is
 * present. It never rejects: routes decide whether they need a user, so that
 * public endpoints can still see who is calling.
 */
export function attachUser(accounts: AccountService): express.RequestHandler {
  return (request, _response, next) => {
    const token = bearerToken(request.header('authorization'));
    if (!token) return next();
    accounts
      .authenticate(token)
      .then((user) => {
        if (user) {
          request.user = user;
          request.sessionToken = token;
        }
        next();
      })
      .catch(next);
  };
}

/** Rejects the request unless it carries a valid session. */
export function requireUser(): express.RequestHandler {
  return (request, response, next) => {
    if (!request.user) {
      response.status(401).json({ code: 'UNAUTHENTICATED', message: 'Sign in to continue' });
      return;
    }
    next();
  };
}

export function createAuthRouter(accounts: AccountService, logger: Logger): express.Router {
  const router = express.Router();

  router.post('/register', (request, response, next) => {
    const body = request.body as { email?: string; displayName?: string; password?: string };
    accounts
      .register({
        email: String(body?.email ?? ''),
        displayName: String(body?.displayName ?? ''),
        password: String(body?.password ?? ''),
      })
      .then((session) => {
        logger.info('Account registered', {
          requestId: request.requestId,
          userId: session.user.id,
          displayName: session.user.displayName,
        });
        response.status(201).json(session);
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/login', (request, response, next) => {
    const body = request.body as { email?: string; password?: string };
    accounts
      .login({ email: String(body?.email ?? ''), password: String(body?.password ?? '') })
      .then((session) => {
        logger.info('Sign-in succeeded', {
          requestId: request.requestId,
          userId: session.user.id,
        });
        response.json(session);
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/logout', (request, response, next) => {
    accounts
      .logout(request.sessionToken)
      .then(() => response.status(204).end())
      .catch(next);
  });

  router.get('/me', requireUser(), (request, response) => {
    response.json({ user: request.user });
  });

  return router;
}

/**
 * Turns an `AccountError` into its declared status, and lets anything else
 * reach the error handler so genuine faults are still logged as 500s.
 */
export function respondAccountError(
  error: unknown,
  request: express.Request,
  response: express.Response,
  logger: Logger,
  next: express.NextFunction,
): void {
  if (error instanceof AccountError) {
    // Expected refusals are not server faults; log them at info.
    logger.info('Request refused', {
      requestId: request.requestId,
      code: error.code,
      reason: error.message,
    });
    response.status(error.status).json({ code: error.code, message: error.message });
    return;
  }
  logger.error('Unexpected account error', {
    requestId: request.requestId,
    ...errorFields(error),
  });
  next(error);
}
