/**
 * Development accounts.
 *
 * Creates a small cast that covers the states worth exercising by hand:
 * a player with everything, one still missing legendaries, one with an
 * unfinished deck, and a pending friend request and challenge.
 *
 *   npm run seed              # create or refresh the accounts
 *   npm run seed -- --reset   # delete them first
 *   npm run seed -- --clean   # also remove accounts left by client test runs
 *
 * Every account uses the same password, printed at the end. This is a
 * development convenience and has no place in a deployed database.
 */
import { PrismaClient } from '@prisma/client';
import { CARD_DEFINITIONS, STARTER_DECK } from '@maailma/card-definitions';
import { hashPassword } from '../apps/server/src/auth/passwords.js';
import { CollectionService } from '../apps/server/src/services/collection-service.js';

const prisma = new PrismaClient();
const collections = new CollectionService(prisma);

const PASSWORD = 'maailma-dev-password';
/** Marks seeded rows so `--reset` never touches a real account. */
const EMAIL_DOMAIN = '@maailma.dev';

interface SeedPlan {
  handle: string;
  displayName: string;
  /** Extra cards beyond the starter grant. */
  grants?: string[];
  decks: Array<{ name: string; heroId: string; cardIds: string[]; active?: boolean }>;
}

/** Cards outside the starter grant — the things a player must unlock. */
const BEYOND_STARTER = Object.values(CARD_DEFINITIONS)
  .filter((card) => card.collectible && !STARTER_DECK.includes(card.id))
  .map((card) => card.id);

/** A legal 30-card deck using only starter cards. */
const STARTER_30 = [...STARTER_DECK];

/**
 * A deck that is legal by the rules but uses a card the player may not own,
 * so the readiness marker has something to report.
 */
function deckWithLegendary(legendaryId: string): string[] {
  return [...STARTER_DECK.slice(0, 29), legendaryId];
}

const PLANS: SeedPlan[] = [
  {
    handle: 'alice',
    displayName: 'Alice',
    // Every collectible card, so nothing is ever blocked on ownership.
    grants: BEYOND_STARTER,
    decks: [
      { name: 'Starter', heroId: 'healer', cardIds: STARTER_30, active: true },
      ...(BEYOND_STARTER[0]
        ? [{ name: 'Legendary', heroId: 'striker', cardIds: deckWithLegendary(BEYOND_STARTER[0]) }]
        : []),
    ],
  },
  {
    handle: 'bob',
    displayName: 'Bob',
    // Starter cards only: his legendary deck is deliberately not playable.
    decks: [
      { name: 'Starter', heroId: 'striker', cardIds: STARTER_30, active: true },
      ...(BEYOND_STARTER[0]
        ? [{ name: 'Wishlist', heroId: 'healer', cardIds: deckWithLegendary(BEYOND_STARTER[0]) }]
        : []),
    ],
  },
  {
    handle: 'carol',
    displayName: 'Carol',
    // An unfinished deck, to exercise the "not 30 cards" branch.
    decks: [{ name: 'Half Built', heroId: 'healer', cardIds: STARTER_DECK.slice(0, 12) }],
  },
];

async function main(): Promise<void> {
  const reset = process.argv.includes('--reset');
  if (reset) {
    const removed = await prisma.user.deleteMany({
      where: { email: { endsWith: EMAIL_DOMAIN } },
    });
    console.log(`Removed ${removed.count} seeded account(s).`);
  }

  // The Godot client tests register through the real API and cannot delete
  // themselves afterwards, so their accounts accumulate. They all use
  // `@example.test`, which nothing else does.
  if (process.argv.includes('--clean')) {
    const removed = await prisma.user.deleteMany({
      where: { email: { endsWith: '@example.test' } },
    });
    console.log(`Removed ${removed.count} account(s) left by test runs.`);
  }

  const passwordHash = await hashPassword(PASSWORD);
  const byHandle = new Map<string, string>();

  for (const plan of PLANS) {
    const email = `${plan.handle}${EMAIL_DOMAIN}`;
    // Re-running must not duplicate: an existing seeded account is reused.
    const existing = await prisma.user.findUnique({ where: { email } });
    const user =
      existing ??
      (await prisma.user.create({
        data: { email, displayName: plan.displayName, passwordHash },
      }));
    byHandle.set(plan.handle, user.id);

    await collections.grantStarter(user.id);
    for (const cardId of plan.grants ?? []) {
      await collections.grant(user.id, cardId, 2);
    }

    for (const deck of plan.decks) {
      const saved = await prisma.deck.upsert({
        where: { userId_name: { userId: user.id, name: deck.name } },
        create: {
          userId: user.id,
          name: deck.name,
          heroId: deck.heroId,
          cardIds: deck.cardIds,
          isActive: deck.active ?? false,
        },
        update: { heroId: deck.heroId, cardIds: deck.cardIds },
      });
      if (deck.active) {
        await prisma.deck.updateMany({
          where: { userId: user.id, isActive: true, id: { not: saved.id } },
          data: { isActive: false },
        });
        await prisma.deck.update({ where: { id: saved.id }, data: { isActive: true } });
      }
    }
  }

  const alice = byHandle.get('alice');
  const bob = byHandle.get('bob');
  const carol = byHandle.get('carol');

  // Alice and Bob are friends, so a challenge can be sent immediately.
  if (alice && bob) await friendship(alice, bob, 'ACCEPTED');
  // Carol's request to Alice is left pending, to exercise the inbox.
  if (carol && alice) await friendship(carol, alice, 'PENDING');

  console.log('\nSeeded accounts (password for all: %s)', PASSWORD);
  for (const plan of PLANS) {
    const id = byHandle.get(plan.handle)!;
    const readiness = await Promise.all(
      (await prisma.deck.findMany({ where: { userId: id }, orderBy: { name: 'asc' } })).map(
        async (deck) => {
          const state = await collections.assessForUser(id, deck.cardIds);
          return `${deck.name}${deck.isActive ? '*' : ''} ${state.playable ? 'ready' : 'not ready'}`;
        },
      ),
    );
    console.log(
      `  ${plan.handle}${EMAIL_DOMAIN}  (${plan.displayName})  decks: ${readiness.join(', ')}`,
    );
  }
  console.log('\n  alice and bob are friends; carol has a pending request to alice.');
  console.log('  * marks the active deck.');
}

/** Creates a friendship in either direction without duplicating the pair. */
async function friendship(
  requesterId: string,
  addresseeId: string,
  status: 'PENDING' | 'ACCEPTED',
): Promise<void> {
  const existing = await prisma.friendship.findFirst({
    where: {
      OR: [
        { requesterId, addresseeId },
        { requesterId: addresseeId, addresseeId: requesterId },
      ],
    },
  });
  if (existing) {
    await prisma.friendship.update({ where: { id: existing.id }, data: { status } });
    return;
  }
  await prisma.friendship.create({
    data: {
      requesterId,
      addresseeId,
      status,
      ...(status === 'ACCEPTED' ? { respondedAt: new Date() } : {}),
    },
  });
}

main()
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => void prisma.$disconnect());
