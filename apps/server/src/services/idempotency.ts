import type { Prisma, PrismaClient } from '@prisma/client';
import { AccountError } from './account-service.js';

/**
 * Runs an economy operation at most once per request id.
 *
 * A client that loses a response and asks again must not pay twice. The marker
 * row is written inside the same transaction as the operation's effects, so
 * either both land or neither does: a retry then collides on the primary key
 * and is answered with the stored outcome — the result the player was always
 * going to get — rather than being executed a second time.
 *
 * Shared by crafting, disenchanting and pack opening, because each of them
 * hands out something a duplicate request must not hand out twice, and three
 * copies of this would eventually disagree about what a reused id means.
 */
export async function runOnce<T>(
  prisma: PrismaClient,
  userId: string,
  operation: string,
  requestId: string | undefined,
  work: (tx: Prisma.TransactionClient) => Promise<T>,
): Promise<T> {
  // Without an id there is nothing to recognise a retry by, so the caller has
  // accepted that a repeat is a repeat.
  if (!requestId) {
    return await prisma.$transaction((tx) => work(tx));
  }

  const existing = await prisma.economyRequest.findUnique({ where: { requestId } });
  if (existing) return replayResult<T>(existing, userId, operation);

  try {
    return await prisma.$transaction(async (tx) => {
      const result = await work(tx);
      await tx.economyRequest.create({
        data: {
          requestId,
          userId,
          operation,
          result: result as unknown as Prisma.InputJsonValue,
        },
      });
      return result;
    });
  } catch (error) {
    // Two copies of the same request racing: whichever lost replays the
    // winner's result rather than reporting a conflict the player caused.
    if (isUniqueViolation(error)) {
      const stored = await prisma.economyRequest.findUnique({ where: { requestId } });
      if (stored) return replayResult<T>(stored, userId, operation);
    }
    throw error;
  }
}

function replayResult<T>(
  stored: { userId: string; operation: string; result: unknown },
  userId: string,
  operation: string,
): T {
  // A request id is the caller's to choose, so it must not become a way to
  // read somebody else's outcome, or to replay a craft as a disenchant.
  if (stored.userId !== userId || stored.operation !== operation) {
    throw new AccountError('REQUEST_ID_REUSED', 'That request id has already been used', 409);
  }
  return stored.result as T;
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === 'object' && error !== null && (error as { code?: unknown }).code === 'P2002'
  );
}
