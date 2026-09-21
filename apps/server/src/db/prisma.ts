import { PrismaClient } from '@prisma/client';

/**
 * The shared Prisma client.
 *
 * Kept on `globalThis` so repeated imports — and watch-mode reloads in
 * development — reuse one connection pool instead of opening a new one each
 * time, which exhausts Postgres connections quickly.
 */
const globalForPrisma = globalThis as unknown as { maailmaPrisma?: PrismaClient };

export const prisma: PrismaClient =
  globalForPrisma.maailmaPrisma ??
  new PrismaClient({
    log: process.env.PRISMA_LOG === 'query' ? ['query', 'warn', 'error'] : ['warn', 'error'],
  });

if (process.env.NODE_ENV !== 'production') globalForPrisma.maailmaPrisma = prisma;

/** True when the database answers. Used by the health endpoint. */
export async function databaseReachable(client: PrismaClient = prisma): Promise<boolean> {
  try {
    await client.$queryRaw`SELECT 1`;
    return true;
  } catch {
    return false;
  }
}

export async function disconnectPrisma(client: PrismaClient = prisma): Promise<void> {
  await client.$disconnect();
}
