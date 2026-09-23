import express from 'express';
import type { Logger } from '../logger.js';
import { AccountError } from '../services/account-service.js';
import type { DeckService } from '../services/deck-service.js';
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
    const body = request.body as { opponentId?: string; scenarioId?: string; deckId?: unknown };
    // A challenge names the deck its sender will play, and only a playable
    // deck may be named: sending a challenge you could not play is refused
    // here, not discovered by your friend when they accept.
    decks
      .requirePlayable(request.user!.id, body?.deckId)
      .then((deck) =>
        social.createChallenge({
          challengerId: request.user!.id,
          opponentId: String(body?.opponentId ?? ''),
          scenarioId: String(body?.scenarioId ?? 'STANDARD_PVP'),
          deckId: deck.id,
        }),
      )
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
    acceptChallenge(request, social, decks, manager, lobby, logger)
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
 * Each player brings a deck of their own choosing — the challenger's named when
 * the challenge was sent, the accepting player's named on accepting — and both
 * must be playable, or the match is not created.
 */
async function acceptChallenge(
  request: express.Request,
  social: SocialService,
  decks: DeckService,
  manager: MatchManager,
  lobby: LobbyHub,
  logger: Logger,
): Promise<unknown> {
  const opponentId = request.user!.id;
  const challenge = await social.loadAnswerable(opponentId, String(request.params.challengeId));

  // Each side plays a deck it chose: the challenger named theirs when sending,
  // and the accepting player names theirs now. Both are judged again here —
  // ownership, format and class can all have changed since the challenge was
  // sent — and there is no fallback deck: a player with no playable deck
  // cannot accept.
  const body = request.body as { deckId?: unknown };
  const opponentDeck = await decks.requirePlayable(opponentId, body?.deckId);
  let challengerDeck;
  try {
    challengerDeck = await decks.requirePlayable(challenge.challengerId, challenge.deckId);
  } catch (error) {
    // Worded for the player accepting: it is their opponent's deck at fault,
    // and nothing they can change.
    if (error instanceof DeckNotPlayableError || error instanceof AccountError) {
      const reasons =
        error instanceof DeckNotPlayableError ? error.reasons.join('; ') : error.message;
      throw new AccountError(
        'CHALLENGER_DECK_NOT_PLAYABLE',
        `Your opponent's deck is not ready: ${reasons}`,
        409,
      );
    }
    throw error;
  }

  const engine = manager.create({
    scenarioId: challenge.scenarioId,
    players: [
      {
        playerId: challenge.challengerId,
        deck: challengerDeck.cardIds,
        heroDefinitionId: challengerDeck.heroId,
        controller: 'HUMAN',
      },
      {
        playerId: opponentId,
        deck: opponentDeck.cardIds,
        heroDefinitionId: opponentDeck.heroId,
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
