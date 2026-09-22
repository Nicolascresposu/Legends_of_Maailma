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
 *   npm run seed -- --audit   # report stored cards the registry no longer defines
 *   npm run seed -- --prune   # audit, then delete orphaned collection rows
 *
 * Every account uses the same password, printed at the end. This is a
 * development convenience and has no place in a deployed database.
 */
import { PrismaClient } from '@prisma/client';
import { CARD_DEFINITIONS, EXPANSION_DEFINITIONS, STARTER_DECK } from '@maailma/card-definitions';
import { hashPassword } from '../apps/server/src/auth/passwords.js';
import { CollectionService } from '../apps/server/src/services/collection-service.js';
import { EconomyService } from '../apps/server/src/services/economy-service.js';
import { ExpansionService } from '../apps/server/src/services/expansion-service.js';

const prisma = new PrismaClient();
const expansions = new ExpansionService(prisma);
const collections = new CollectionService(prisma, expansions);
const economy = new EconomyService(prisma, expansions);

const PASSWORD = 'maailma-dev-password';
/** Marks seeded rows so `--reset` never touches a real account. */
const EMAIL_DOMAIN = '@maailma.dev';

interface SeedPlan {
  handle: string;
  displayName: string;
  /** Extra cards beyond the starter grant. */
  grants?: string[];
  /** Starting Fragments, so crafting can be tried without opening packs first. */
  fragments?: number;
  /** Whether this account may change expansion policies. */
  admin?: boolean;
  decks: Array<{
    name: string;
    heroId: string;
    cardIds: string[];
    active?: boolean;
    format?: 'STANDARD' | 'WILD';
  }>;
}

/**
 * Cards outside the starter grant — the things a player must unlock.
 *
 * Released sets only. Handing a development account an unreleased card would
 * put it in a deck the server then refuses, which is a confusing way to learn
 * that the set has not launched.
 */
const BEYOND_STARTER = Object.values(CARD_DEFINITIONS)
  .filter(
    (card) =>
      card.collectible &&
      !STARTER_DECK.includes(card.id) &&
      EXPANSION_DEFINITIONS[card.expansionId]?.policy.released === true,
  )
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
    // Enough to craft anything, and the rights to rotate a set by hand.
    fragments: 5000,
    admin: true,
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
    // A modest balance, so the "not enough Fragments" path has a subject.
    fragments: 120,
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
  // The audit is read-only and answers a different question from seeding, so
  // it runs alone rather than alongside account creation.
  if (process.argv.includes('--audit') || process.argv.includes('--prune')) {
    await auditOrphans(process.argv.includes('--prune'));
    return;
  }

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

    if (plan.admin && !user.isAdmin) {
      await prisma.user.update({ where: { id: user.id }, data: { isAdmin: true } });
    }

    await collections.grantStarter(user.id);
    for (const cardId of plan.grants ?? []) {
      await collections.grant(user.id, cardId, 2);
    }

    // Set rather than added, so re-running does not keep topping a balance up.
    if (plan.fragments !== undefined) {
      await prisma.userEconomy.upsert({
        where: { userId: user.id },
        create: { userId: user.id, fragmentBalance: plan.fragments },
        update: { fragmentBalance: plan.fragments },
      });
    }

    for (const deck of plan.decks) {
      const saved = await prisma.deck.upsert({
        where: { userId_name: { userId: user.id, name: deck.name } },
        create: {
          userId: user.id,
          name: deck.name,
          heroId: deck.heroId,
          cardIds: deck.cardIds,
          format: deck.format ?? 'STANDARD',
          isActive: deck.active ?? false,
        },
        update: {
          heroId: deck.heroId,
          cardIds: deck.cardIds,
          format: deck.format ?? 'STANDARD',
        },
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
          const state = await collections.assessForUser(id, deck.cardIds, deck.format);
          return `${deck.name}${deck.isActive ? '*' : ''} ${state.playable ? 'ready' : 'not ready'}`;
        },
      ),
    );
    const fragments = await economy.balance(id);
    const role = plan.admin ? '  [admin]' : '';
    console.log(
      `  ${plan.handle}${EMAIL_DOMAIN}  (${plan.displayName})${role}  ` +
        `${fragments} Fragments  decks: ${readiness.join(', ')}`,
    );
  }
  console.log('\n  alice and bob are friends; carol has a pending request to alice.');
  console.log('  * marks the active deck.');

  // The policies in force, so a development run shows at a glance which sets
  // are open for what — and which are defined but not yet released.
  console.log('\n  Expansions:');
  for (const expansion of await expansions.allExpansions()) {
    const enabled = Object.entries(expansion.policy)
      .filter(([, on]) => on)
      .map(([flag]) => flag)
      .join(', ');
    console.log(`    ${expansion.id.padEnd(18)} ${enabled || '(nothing enabled)'}`);
  }
}

/**
 * Reports card ids stored in the database that the registry no longer defines,
 * and optionally deletes the orphaned collection rows.
 *
 * Decks are only ever reported. Stripping unknown ids from a saved deck would
 * silently rewrite what a player built, and an unplayable deck already explains
 * itself through its readiness marker.
 */
async function auditOrphans(prune: boolean): Promise<void> {
  const report = await collections.findOrphans();
  console.log(`Registry defines ${report.knownCardCount} card(s).`);

  if (report.collection.length === 0) {
    console.log('No orphaned collection rows.');
  } else {
    const rows = report.collection.reduce((sum, entry) => sum + entry.rows, 0);
    console.log(`
Orphaned collection rows (${rows} row(s) across ${report.collection.length} card id(s)):`);
    for (const entry of report.collection) {
      console.log(`  ${entry.cardId}  ${entry.rows} row(s)`);
    }
  }

  if (report.decks.length === 0) {
    console.log('No decks reference a missing card.');
  } else {
    console.log(`
Decks referencing missing cards (${report.decks.length}):`);
    for (const deck of report.decks) {
      console.log(`  "${deck.name}"  owner ${deck.userId}  ->  ${deck.unknown.join(', ')}`);
    }
    console.log('  These are left untouched; each is already reported unplayable.');
  }

  if (!prune) {
    if (report.collection.length > 0) {
      console.log('\nRe-run with --prune to delete the orphaned collection rows.');
    }
    return;
  }

  const result = await collections.pruneOrphans();
  console.log(`
Deleted ${result.deleted} orphaned collection row(s).`);
  if (report.decks.length > 0) {
    console.log('Decks were left as they are; repair them in the deck builder.');
  }
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
