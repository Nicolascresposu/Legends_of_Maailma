import type { Challenge, Friendship, PrismaClient } from '@prisma/client';
import { getScenarioDefinition } from '@maailma/card-definitions';
import { AccountError } from './account-service.js';

export interface FriendSummary {
  userId: string;
  displayName: string;
  friendshipId: string;
}

export interface PendingRequest {
  friendshipId: string;
  fromUserId: string;
  fromDisplayName: string;
  createdAt: Date;
}

export const CHALLENGE_TTL_MS = 1000 * 60 * 10;

/**
 * Friendships and challenges.
 *
 * A friendship is stored once per pair, keyed by who asked. Accepting makes it
 * symmetric, so every read has to look at both directions.
 */
export class SocialService {
  constructor(private readonly prisma: PrismaClient) {}

  async requestFriend(requesterId: string, displayName: string): Promise<Friendship> {
    const target = await this.prisma.user.findUnique({
      where: { displayName: String(displayName ?? '').trim() },
    });
    if (!target) throw new AccountError('USER_NOT_FOUND', 'No player with that name', 404);
    if (target.id === requesterId) {
      throw new AccountError('SELF_FRIENDSHIP', 'You cannot add yourself');
    }

    const existing = await this.findBetween(requesterId, target.id);
    if (existing) {
      if (existing.status === 'ACCEPTED') {
        throw new AccountError('ALREADY_FRIENDS', 'You are already friends', 409);
      }
      if (existing.status === 'BLOCKED') {
        // Do not reveal a block; report it as an ordinary failure.
        throw new AccountError('REQUEST_REJECTED', 'That request could not be sent', 409);
      }
      // They already asked us: accept rather than creating a mirrored row.
      if (existing.addresseeId === requesterId) {
        return await this.respondToFriendRequest(requesterId, existing.id, true);
      }
      if (existing.status === 'PENDING') {
        throw new AccountError('REQUEST_PENDING', 'That request is already pending', 409);
      }
      // A previously declined request may be renewed.
      return await this.prisma.friendship.update({
        where: { id: existing.id },
        data: { status: 'PENDING', requesterId, addresseeId: target.id, respondedAt: null },
      });
    }

    return await this.prisma.friendship.create({
      data: { requesterId, addresseeId: target.id, status: 'PENDING' },
    });
  }

  async respondToFriendRequest(
    userId: string,
    friendshipId: string,
    accept: boolean,
  ): Promise<Friendship> {
    const friendship = await this.prisma.friendship.findUnique({ where: { id: friendshipId } });
    if (!friendship || friendship.addresseeId !== userId) {
      throw new AccountError('REQUEST_NOT_FOUND', 'Friend request not found', 404);
    }
    if (friendship.status !== 'PENDING') {
      throw new AccountError('REQUEST_SETTLED', 'That request has already been answered', 409);
    }
    return await this.prisma.friendship.update({
      where: { id: friendshipId },
      data: { status: accept ? 'ACCEPTED' : 'DECLINED', respondedAt: new Date() },
    });
  }

  async removeFriend(userId: string, friendUserId: string): Promise<void> {
    const friendship = await this.findBetween(userId, friendUserId);
    if (!friendship) throw new AccountError('NOT_FRIENDS', 'You are not friends', 404);
    await this.prisma.friendship.delete({ where: { id: friendship.id } });
  }

  async listFriends(userId: string): Promise<FriendSummary[]> {
    const rows = await this.prisma.friendship.findMany({
      where: {
        status: 'ACCEPTED',
        OR: [{ requesterId: userId }, { addresseeId: userId }],
      },
      include: { requester: true, addressee: true },
    });
    return rows.map((row) => {
      const other = row.requesterId === userId ? row.addressee : row.requester;
      return { userId: other.id, displayName: other.displayName, friendshipId: row.id };
    });
  }

  async listPendingRequests(userId: string): Promise<PendingRequest[]> {
    const rows = await this.prisma.friendship.findMany({
      where: { addresseeId: userId, status: 'PENDING' },
      include: { requester: true },
      orderBy: { createdAt: 'desc' },
    });
    return rows.map((row) => ({
      friendshipId: row.id,
      fromUserId: row.requesterId,
      fromDisplayName: row.requester.displayName,
      createdAt: row.createdAt,
    }));
  }

  async areFriends(a: string, b: string): Promise<boolean> {
    const friendship = await this.findBetween(a, b);
    return friendship?.status === 'ACCEPTED';
  }

  // --- Challenges ----------------------------------------------------------

  async createChallenge(input: {
    challengerId: string;
    opponentId: string;
    scenarioId: string;
    deckId?: string;
  }): Promise<Challenge> {
    if (input.challengerId === input.opponentId) {
      throw new AccountError('SELF_CHALLENGE', 'You cannot challenge yourself');
    }
    if (!(await this.areFriends(input.challengerId, input.opponentId))) {
      throw new AccountError('NOT_FRIENDS', 'You can only challenge friends', 403);
    }
    try {
      getScenarioDefinition(input.scenarioId);
    } catch {
      throw new AccountError('UNKNOWN_SCENARIO', `Unknown scenario: ${input.scenarioId}`);
    }

    // One live challenge per direction keeps the opponent's list meaningful.
    const open = await this.prisma.challenge.findFirst({
      where: {
        challengerId: input.challengerId,
        opponentId: input.opponentId,
        status: 'PENDING',
        expiresAt: { gt: new Date() },
      },
    });
    if (open) throw new AccountError('CHALLENGE_PENDING', 'You already challenged them', 409);

    return await this.prisma.challenge.create({
      data: {
        challengerId: input.challengerId,
        opponentId: input.opponentId,
        scenarioId: input.scenarioId,
        ...(input.deckId ? { deckId: input.deckId } : {}),
        expiresAt: new Date(Date.now() + CHALLENGE_TTL_MS),
      },
    });
  }

  /** A challenge the given user may still answer, or an explanatory error. */
  async loadAnswerable(userId: string, challengeId: string): Promise<Challenge> {
    const challenge = await this.prisma.challenge.findUnique({ where: { id: challengeId } });
    if (!challenge || challenge.opponentId !== userId) {
      throw new AccountError('CHALLENGE_NOT_FOUND', 'Challenge not found', 404);
    }
    if (challenge.status !== 'PENDING') {
      throw new AccountError('CHALLENGE_SETTLED', 'That challenge was already answered', 409);
    }
    if (challenge.expiresAt.getTime() <= Date.now()) {
      await this.prisma.challenge.update({
        where: { id: challengeId },
        data: { status: 'EXPIRED', respondedAt: new Date() },
      });
      throw new AccountError('CHALLENGE_EXPIRED', 'That challenge has expired', 409);
    }
    return challenge;
  }

  async markAccepted(challengeId: string, matchId: string): Promise<Challenge> {
    return await this.prisma.challenge.update({
      where: { id: challengeId },
      data: { status: 'ACCEPTED', matchId, respondedAt: new Date() },
    });
  }

  async declineChallenge(userId: string, challengeId: string): Promise<Challenge> {
    await this.loadAnswerable(userId, challengeId);
    return await this.prisma.challenge.update({
      where: { id: challengeId },
      data: { status: 'DECLINED', respondedAt: new Date() },
    });
  }

  async cancelChallenge(userId: string, challengeId: string): Promise<Challenge> {
    const challenge = await this.prisma.challenge.findUnique({ where: { id: challengeId } });
    if (!challenge || challenge.challengerId !== userId) {
      throw new AccountError('CHALLENGE_NOT_FOUND', 'Challenge not found', 404);
    }
    if (challenge.status !== 'PENDING') {
      throw new AccountError('CHALLENGE_SETTLED', 'That challenge was already answered', 409);
    }
    return await this.prisma.challenge.update({
      where: { id: challengeId },
      data: { status: 'CANCELLED', respondedAt: new Date() },
    });
  }

  /** Live challenges aimed at this user, newest first. */
  async listIncoming(userId: string): Promise<Challenge[]> {
    return await this.prisma.challenge.findMany({
      where: { opponentId: userId, status: 'PENDING', expiresAt: { gt: new Date() } },
      orderBy: { createdAt: 'desc' },
    });
  }

  async listOutgoing(userId: string): Promise<Challenge[]> {
    return await this.prisma.challenge.findMany({
      where: { challengerId: userId, status: 'PENDING', expiresAt: { gt: new Date() } },
      orderBy: { createdAt: 'desc' },
    });
  }

  /** Marks lapsed challenges expired. Safe to call on a schedule. */
  async expireStale(now: Date = new Date()): Promise<number> {
    const result = await this.prisma.challenge.updateMany({
      where: { status: 'PENDING', expiresAt: { lte: now } },
      data: { status: 'EXPIRED', respondedAt: now },
    });
    return result.count;
  }

  private async findBetween(a: string, b: string): Promise<Friendship | null> {
    return await this.prisma.friendship.findFirst({
      where: {
        OR: [
          { requesterId: a, addresseeId: b },
          { requesterId: b, addresseeId: a },
        ],
      },
    });
  }
}
