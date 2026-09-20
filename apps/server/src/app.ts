import cors from 'cors';
import express from 'express';
import { CARD_DEFINITIONS, SCENARIO_DEFINITIONS } from '@maailma/card-definitions';
import type { GameAction } from '@maailma/game-model';
import type { CreateMatchRequest } from '@maailma/protocol';
import type { MatchManager } from './match-manager.js';

export function createApp(manager: MatchManager) {
  const app = express();
  app.use(cors());
  app.use(express.json({ limit: '64kb' }));

  app.get('/health', (_request, response) => response.json({ ok: true, service: 'maailma-tcg' }));
  app.get('/api/cards', (_request, response) => response.json(Object.values(CARD_DEFINITIONS)));
  app.get('/api/scenarios', (_request, response) =>
    response.json(Object.values(SCENARIO_DEFINITIONS)),
  );

  app.post('/api/matches', (request, response) => {
    try {
      const engine = manager.create(request.body as CreateMatchRequest);
      response.status(201).json({ matchId: engine.state.matchId, state: engine.state });
    } catch (error) {
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
    if (!result.ok)
      return response.status(result.error?.code === 'MATCH_NOT_FOUND' ? 404 : 409).json(result);
    return response.json({ ...result, state: engine!.state });
  });

  return app;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'Unknown error';
}
