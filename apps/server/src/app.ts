import { randomUUID } from 'node:crypto';
import cors from 'cors';
import express from 'express';
import { EXPANSION_DEFINITIONS, SCENARIO_DEFINITIONS } from '@maailma/card-definitions';
import type { GameAction } from '@maailma/game-model';
import type { CreateMatchRequest } from '@maailma/protocol';
import { errorFields, silentLogger, type Logger } from './logger.js';
import type { MatchManager } from './match-manager.js';
import type { LobbyHub } from './lobby.js';
import type { AccountService } from './services/account-service.js';
import type { DeckService } from './services/deck-service.js';
import type { SocialService } from './services/social-service.js';
import type { CollectionService } from './services/collection-service.js';
import type { ExpansionService } from './services/expansion-service.js';
import type { EconomyService } from './services/economy-service.js';
import type { PackService } from './services/pack-service.js';
import { visibleCards } from './services/expansion-service.js';
import { attachUser, createAuthRouter } from './routes/auth-routes.js';
import { createDeckRouter } from './routes/deck-routes.js';
import { createCollectionRouter } from './routes/collection-routes.js';
import { createExpansionRouter } from './routes/expansion-routes.js';
import { createEconomyRouter } from './routes/economy-routes.js';
import { createPackRouter } from './routes/pack-routes.js';
import { createSocialRouter } from './routes/social-routes.js';

/**
 * Database-backed features. Omitted, the server runs exactly as it did before
 * accounts existed: matches are still created and played anonymously, which
 * keeps the engine tests independent of Postgres.
 */
export interface AppServices {
  accounts: AccountService;
  decks: DeckService;
  social: SocialService;
  collections: CollectionService;
  expansions: ExpansionService;
  economy: EconomyService;
  packs: PackService;
  lobby: LobbyHub;
  databaseReachable?: () => Promise<boolean>;
}

export function createApp(
  manager: MatchManager,
  logger: Logger = silentLogger,
  services?: AppServices,
) {
  const app = express();
  app.use(cors());
  app.use(express.json({ limit: '64kb' }));
  app.use(requestLogger(logger));

  app.get('/health', (_request, response) => {
    if (!services?.databaseReachable) {
      response.json({ ok: true, service: 'maailma-tcg' });
      return;
    }
    services
      .databaseReachable()
      .then((database) =>
        response.status(database ? 200 : 503).json({
          ok: database,
          service: 'maailma-tcg',
          database: database ? 'up' : 'down',
        }),
      )
      .catch(() => response.status(503).json({ ok: false, service: 'maailma-tcg' }));
  });
  /**
   * The card registry.
   *
   * Filtered by live policy when the database is configured, so an unreleased
   * expansion's names, art and rarities never leave the server. Without a
   * database — the anonymous match configuration the engine tests use — there
   * are no stored policies to consult, so the shipped defaults apply, which
   * hide unreleased sets just the same.
   */
  app.get('/api/cards', (_request, response) => {
    const source = services?.expansions;
    if (!source) {
      response.json(visibleCards(EXPANSION_DEFINITIONS));
      return;
    }
    source
      .policies()
      .then((policies) => response.json(visibleCards(policies)))
      .catch(() => response.json(visibleCards(EXPANSION_DEFINITIONS)));
  });
  app.get('/api/scenarios', (_request, response) =>
    response.json(Object.values(SCENARIO_DEFINITIONS)),
  );

  app.post('/api/matches', (request, response) => {
    try {
      const engine = manager.create(request.body as CreateMatchRequest);
      logger.info('Match created', {
        requestId: request.requestId,
        matchId: engine.state.matchId,
        scenarioId: engine.setup.scenario.id,
        players: engine.state.playerOrder,
      });
      response.status(201).json({ matchId: engine.state.matchId, state: engine.state });
    } catch (error) {
      logger.warn('Match creation rejected', {
        requestId: request.requestId,
        ...errorFields(error),
      });
      response.status(400).json({ code: 'INVALID_MATCH_SETUP', message: errorMessage(error) });
    }
  });

  app.get('/api/matches/:matchId', (request, response) => {
    const engine = manager.get(request.params.matchId);
    if (!engine)
      return response.status(404).json({ code: 'MATCH_NOT_FOUND', message: 'Match not found' });
    return response.json({ state: engine.state });
  });

  app.get('/api/matches/:matchId/legal-actions/:playerId', (request, response) => {
    const engine = manager.get(request.params.matchId);
    if (!engine)
      return response.status(404).json({ code: 'MATCH_NOT_FOUND', message: 'Match not found' });
    return response.json({ actions: engine.getLegalActions(request.params.playerId) });
  });

  app.post('/api/matches/:matchId/actions', (request, response) => {
    const action = request.body as GameAction;
    const result = manager.act(request.params.matchId, action);
    const engine = manager.get(request.params.matchId);
    if (!result.ok) {
      logger.info('Action rejected', {
        requestId: request.requestId,
        matchId: request.params.matchId,
        actionType: action?.type,
        actorId: action?.actorId,
        code: result.error?.code,
        reason: result.error?.message,
      });
      return response.status(result.error?.code === 'MATCH_NOT_FOUND' ? 404 : 409).json(result);
    }
    logger.debug('Action applied', {
      requestId: request.requestId,
      matchId: request.params.matchId,
      actionType: action?.type,
      actorId: action?.actorId,
      events: result.events.length,
      turn: engine!.state.turn,
      phase: engine!.state.phase,
    });
    return response.json({ ...result, state: engine!.state });
  });

  if (services) {
    // Identify the caller before any authenticated route runs.
    app.use(attachUser(services.accounts));
    app.use(
      '/api/auth',
      createAuthRouter(services.accounts, logger, (userId) =>
        services.collections.grantStarter(userId),
      ),
    );
    app.use('/api/decks', createDeckRouter(services.decks, logger));
    app.use('/api/collection', createCollectionRouter(services.collections, logger));
    app.use('/api/expansions', createExpansionRouter(services.expansions, logger));
    app.use('/api/economy', createEconomyRouter(services.economy, logger));
    app.use('/api/packs', createPackRouter(services.packs, logger));
    app.use(
      '/api/social',
      createSocialRouter(
        services.social,
        services.decks,
        services.collections,
        manager,
        services.lobby,
        logger,
      ),
    );
  }

  app.use(errorHandler(logger));

  return app;
}

/** Assigns a request id, logs completion, and exposes the id to route handlers. */
function requestLogger(logger: Logger): express.RequestHandler {
  return (request, response, next) => {
    const requestId = randomUUID();
    request.requestId = requestId;
    response.setHeader('x-request-id', requestId);
    const startedAt = process.hrtime.bigint();
    response.once('finish', () => {
      const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
      const fields = {
        requestId,
        method: request.method,
        path: request.originalUrl,
        status: response.statusCode,
        durationMs: Math.round(durationMs * 1000) / 1000,
      };
      if (response.statusCode >= 500) logger.error('Request failed', fields);
      else if (response.statusCode >= 400) logger.warn('Request rejected', fields);
      else logger.info('Request completed', fields);
    });
    next();
  };
}

/**
 * Last-resort handler so an unexpected throw is recorded instead of vanishing.
 * Express only treats a handler as an error handler when it declares four
 * parameters, so `next` stays in the signature even though it is unused.
 */
function errorHandler(logger: Logger): express.ErrorRequestHandler {
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  return (error, request, response, next) => {
    logger.error('Unhandled request error', {
      requestId: request.requestId,
      method: request.method,
      path: request.originalUrl,
      ...errorFields(error),
    });
    if (response.headersSent) return;
    response.status(500).json({ code: 'INTERNAL_ERROR', message: 'Internal server error' });
  };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'Unknown error';
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      requestId?: string;
    }
  }
}
