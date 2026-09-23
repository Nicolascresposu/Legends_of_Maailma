import express from 'express';
import { getScenarioDefinition, starterDeckFor } from '@maailma/card-definitions';
import type { Logger } from '../logger.js';
import { AccountError } from '../services/account-service.js';
import type { DeckService } from '../services/deck-service.js';
import type { CollectionService } from '../services/collection-service.js';
import { DeckNotPlayableError } from '../services/collection-service.js';
import type { SocialService } from '../services/social-service.js';
import type { MatchManager } from '../match-manager.js';
import type { LobbyHub } from '../lobby.js';
import { requireUser, respondAccountError } from './auth-routes.js';

/**
 * Friends and challenges.
 *
 * Accepting a challenge is the one place the social layer touches the match
 * layer: it creates the match both players will join, then tells each client
 * which match id to open.
 */
export function createSocialRouter(
  social: SocialService,
  decks: DeckService,
  collections: CollectionService,
  manager: MatchManager,
  lobby: LobbyHub,
  logger: Logger,
): express.Router {
  const router = express.Router();
  router.use(requireUser());

  // --- Friends -------------------------------------------------------------

  router.get('/friends', (request, response, next) => {
    social
      .listFriends(request.user!.id)
      .then((friends) => response.json({ friends }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.get('/friends/requests', (request, response, next) => {
    social
      .listPendingRequests(request.user!.id)
      .then((requests) => response.json({ requests }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/friends/requests', (request, response, next) => {
    const body = request.body as { displayName?: string };
    social
      .requestFriend(request.user!.id, String(body?.displayName ?? ''))
      .then((friendship) => {
        lobby.notifyUser(friendship.addresseeId, {
          type: 'FRIEND_REQUEST',
          friendshipId: friendship.id,
          fromDisplayName: request.user!.displayName,
        });
        response.status(201).json({ friendship });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/friends/requests/:friendshipId/respond', (request, response, next) => {
    const body = request.body as { accept?: boolean };
    social
      .respondToFriendRequest(request.user!.id, request.params.friendshipId, body?.accept === true)
      .then((friendship) => {
        lobby.notifyUser(friendship.requesterId, {
          type: 'FRIEND_RESPONSE',
          friendshipId: friendship.id,
          status: friendship.status,
          fromDisplayName: request.user!.displayName,
        });
        response.json({ friendship });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.delete('/friends/:userId', (request, response, next) => {
    social
      .removeFriend(request.user!.id, request.params.userId)
      .then(() => response.status(204).end())
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  // --- Challenges ----------------------------------------------------------

  router.get('/challenges', (request, response, next) => {
    Promise.all([social.listIncoming(request.user!.id), social.listOutgoing(request.user!.id)])
      .then(([incoming, outgoing]) => response.json({ incoming, outgoing }))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/challenges', (request, response, next) => {
    const body = request.body as { opponentId?: string; scenarioId?: string; deckId?: string };
    social
      .createChallenge({
        challengerId: request.user!.id,
        opponentId: String(body?.opponentId ?? ''),
        scenarioId: String(body?.scenarioId ?? 'STANDARD_PVP'),
        ...(body?.deckId ? { deckId: body.deckId } : {}),
      })
      .then((challenge) => {
        logger.info('Challenge sent', {
          requestId: request.requestId,
          challengeId: challenge.id,
          from: request.user!.id,
          to: challenge.opponentId,
        });
        // Push to the opponent if they are connected; the REST list covers
        // the case where they are not.
        lobby.notifyUser(challenge.opponentId, {
          type: 'CHALLENGE_RECEIVED',
          challengeId: challenge.id,
          fromDisplayName: request.user!.displayName,
          scenarioId: challenge.scenarioId,
          expiresAt: challenge.expiresAt.toISOString(),
        });
        response.status(201).json({ challenge });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/challenges/:challengeId/accept', (request, response, next) => {
    acceptChallenge(request, social, decks, collections, manager, lobby, logger)
      .then((payload) => response.json(payload))
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/challenges/:challengeId/decline', (request, response, next) => {
    social
      .declineChallenge(request.user!.id, request.params.challengeId)
      .then((challenge) => {
        lobby.notifyUser(challenge.challengerId, {
          type: 'CHALLENGE_DECLINED',
          challengeId: challenge.id,
          byDisplayName: request.user!.displayName,
        });
        response.json({ challenge });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  router.post('/challenges/:challengeId/cancel', (request, response, next) => {
    social
      .cancelChallenge(request.user!.id, request.params.challengeId)
      .then((challenge) => {
        lobby.notifyUser(challenge.opponentId, {
          type: 'CHALLENGE_CANCELLED',
          challengeId: challenge.id,
        });
        response.json({ challenge });
      })
      .catch((error: unknown) => respondAccountError(error, request, response, logger, next));
  });

  return router;
}

/**
 * Creates the match for an accepted challenge.
 *
 * Each player brings their own active deck; a player without one falls back to
 * their class's starter deck so a challenge is never blocked on deck building.
 */
async function acceptChallenge(
  request: express.Request,
  social: SocialService,
  decks: DeckService,
  collections: CollectionService,
  manager: MatchManager,
  lobby: LobbyHub,
  logger: Logger,
): Promise<unknown> {
  const opponentId = request.user!.id;
  const challenge = await social.loadAnswerable(opponentId, String(request.params.challengeId));

  const challengerDeck = await decks.activeDeck(challenge.challengerId);
  const opponentDeck = await decks.activeDeck(opponentId);

  // Ownership and format are both enforced here rather than at save time: a
  // deck may be built toward cards a player has not unlocked, but it cannot be
  // played until every copy it uses is owned and every card is legal in the
  // format the deck was built for. A deck holding a rotated card is refused
  // here rather than quietly played, and a deck referencing an unreleased card
  // — one an admin tool may have put there — is refused in either format.
  // A player without a deck plays the scenario's hero for their side, with
  // that hero's class starter deck — which the starter grant makes playable.
  const scenario = getScenarioDefinition(challenge.scenarioId);
  const challengerHero = challengerDeck?.heroId ?? scenario.sideA.heroDefinitionId;
  const opponentHero = opponentDeck?.heroId ?? scenario.sideB.heroDefinitionId;
  const challengerCards = challengerDeck?.cardIds ?? starterDeckFor(challengerHero);
  const opponentCards = opponentDeck?.cardIds ?? starterDeckFor(opponentHero);
  const challengerFormat = challengerDeck?.format ?? 'STANDARD';
  const opponentFormat = opponentDeck?.format ?? 'STANDARD';
  try {
    await collections.assertPlayable(
      challenge.challengerId,
      challengerCards,
      challengerFormat,
      challengerHero,
    );
  } catch (error) {
    if (error instanceof DeckNotPlayableError) {
      throw new AccountError(
        'CHALLENGER_DECK_NOT_PLAYABLE',
        `Your opponent's deck is not ready: ${error.reasons.join('; ')}`,
        409,
      );
    }
    throw error;
  }
  await collections.assertPlayable(opponentId, opponentCards, opponentFormat, opponentHero);

  const engine = manager.create({
    scenarioId: challenge.scenarioId,
    players: [
      {
        playerId: challenge.challengerId,
        deck: challengerCards,
        heroDefinitionId: challengerHero,
        controller: 'HUMAN',
      },
      {
        playerId: opponentId,
        deck: opponentCards,
        heroDefinitionId: opponentHero,
        controller: 'HUMAN',
      },
    ],
  });

  const updated = await social.markAccepted(challenge.id, engine.state.matchId);
  logger.info('Challenge accepted', {
    requestId: request.requestId,
    challengeId: challenge.id,
    matchId: engine.state.matchId,
  });

  // Both sides need the match id: the challenger may not have been watching.
  const announcement = {
    type: 'CHALLENGE_ACCEPTED' as const,
    challengeId: challenge.id,
    matchId: engine.state.matchId,
    scenarioId: challenge.scenarioId,
  };
  lobby.notifyUser(challenge.challengerId, {
    ...announcement,
    opponentDisplayName: request.user!.displayName,
    yourPlayerId: challenge.challengerId,
  });
  lobby.notifyUser(opponentId, { ...announcement, yourPlayerId: opponentId });

  return { challenge: updated, matchId: engine.state.matchId, state: engine.state };
}

/** Shared by routes that need a challenge the caller may act on. */
export function assertOwnership(condition: boolean, message: string): void {
  if (!condition) throw new AccountError('FORBIDDEN', message, 403);
}
