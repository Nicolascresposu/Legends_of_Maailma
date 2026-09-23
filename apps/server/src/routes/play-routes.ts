import express from 'express';
import { getScenarioDefinition } from '@maailma/card-definitions';
import type { Logger } from '../logger.js';
import type { MatchManager } from '../match-manager.js';
import { AccountError } from '../services/account-service.js';
import type { DeckService } from '../services/deck-service.js';
import { requireUser, respondAccountError } from './auth-routes.js';

/** The seat an AI opponent plays from in a player-versus-environment match. */
export const AI_PLAYER_ID = 'ai';

/**
 * Starting and joining matches as a signed-in player.
 *
 * Every entry takes a `deckId`: a player picks one of their own decks, and it
 * must be playable — owned, legal in its format, and of its hero's class —
 * or there is no match. The player plays as that deck's hero, so the deck and
 * the hero can never disagree.
 *
 * A scenario whose second side is AI-controlled starts at once against the
 * AI. Any other starts with its second seat open, and waits there until
 * another player takes it with a deck of their own.
 */
export function createPlayRouter(
  decks: DeckService,
  manager: MatchManager,
  logger: Logger,
): express.Router {
  const router = express.Router();
  router.use(requireUser());

  router.post('/', (request, response, next) => {
    start(request, decks, manager, logger)
      .then((payload) => response.status(201).json(payload))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/:matchId/join', (request, response, next) => {
    join(request, decks, manager, logger)
      .then((payload) => response.json(payload))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  return router;
}

async function start(
  request: express.Request,
  decks: DeckService,
  manager: MatchManager,
  logger: Logger,
) {
  const body = request.body as { scenarioId?: unknown; deckId?: unknown };
  const scenarioId = String(body?.scenarioId ?? '');
  let scenario;
  try {
    scenario = getScenarioDefinition(scenarioId);
  } catch {
    throw new AccountError('UNKNOWN_SCENARIO', `Unknown scenario: ${scenarioId || '(none)'}`);
  }
  const userId = request.user!.id;
  const deck = await decks.requirePlayable(userId, body?.deckId);
  const creator = {
    playerId: userId,
    heroDefinitionId: deck.heroId,
    deck: deck.cardIds,
    controller: 'HUMAN' as const,
  };

  const againstAi = scenario.sideB.controller === 'AI';
  const engine = againstAi
    ? manager.create({
        scenarioId,
        players: [creator, { playerId: AI_PLAYER_ID, controller: 'AI' }],
      })
    : manager.createWithOpenSeat({ scenarioId, creator });
  const matchId = engine.state.matchId;
  logger.info('Match started', {
    requestId: request.requestId,
    matchId,
    scenarioId,
    userId,
    deckId: deck.id,
    waitingForOpponent: !againstAi,
  });
  return { matchId, playerId: userId, waitingForOpponent: !againstAi };
}

async function join(
  request: express.Request,
  decks: DeckService,
  manager: MatchManager,
  logger: Logger,
) {
  const matchId = String(request.params.matchId);
  const userId = request.user!.id;
  const engine = manager.get(matchId);
  if (!engine) throw new AccountError('MATCH_NOT_FOUND', 'Match not found', 404);
  if (engine.state.sides[userId]) {
    // Already seated — the creator re-joining, say. Nothing to claim.
    return { matchId, playerId: userId, waitingForOpponent: manager.hasOpenSeat(matchId) };
  }
  if (!manager.hasOpenSeat(matchId)) {
    throw new AccountError('SEAT_TAKEN', 'That match has no open seat', 409);
  }
  const body = request.body as { deckId?: unknown };
  const deck = await decks.requirePlayable(userId, body?.deckId);
  manager.claimSeat(matchId, {
    playerId: userId,
    heroDefinitionId: deck.heroId,
    deck: deck.cardIds,
    controller: 'HUMAN',
  });
  logger.info('Open seat taken', {
    requestId: request.requestId,
    matchId,
    userId,
    deckId: deck.id,
  });
  return { matchId, playerId: userId, waitingForOpponent: false };
}
