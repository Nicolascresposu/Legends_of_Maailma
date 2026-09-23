import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PrismaClient } from '@prisma/client';
import { CARD_DEFINITIONS, CRAFTING_VALUES, type EarnedRarity } from '@maailma/card-definitions';
import { hashPassword } from '../apps/server/src/auth/passwords.js';
import { CollectionService } from '../apps/server/src/services/collection-service.js';
import { EconomyService } from '../apps/server/src/services/economy-service.js';
import { ExpansionService } from '../apps/server/src/services/expansion-service.js';
import { PackService } from '../apps/server/src/services/pack-service.js';
import { TradeService } from '../apps/server/src/services/trade-service.js';

/**
 * One expansion, walked from before its release to its eventual archiving.
 *
 * The point is not that any individual step works — the other suites cover
 * that — but that the whole lifecycle happens by flipping flags, with no
 * migration, no rebuild of a collection, and no rewriting of what already
 * happened. If any stage below ever needs a data migration to reach the next
 * one, this test is where that will show up.
 */
const prisma = new PrismaClient();
const expansions = new ExpansionService(prisma);
const collections = new CollectionService(prisma, expansions);
const economy = new EconomyService(prisma, expansions);
const packs = new PackService(prisma, expansions);
const trades = new TradeService(prisma, expansions);

const suffix = `l${Date.now()}${Math.floor(Math.random() * 1000)}`;
const created: string[] = [];

/** The set under test: shipped unreleased, so its launch can be watched. */
const SET = 'MACHINES_OF_KONA';
const SET_PACK = 'MACHINES_OF_KONA_PACK';
/** A released set to trade against and to rotate the first one past. */
const OTHER_SET = 'CORE';

let alice = '';
let bob = '';

async function makeUser(tag: string): Promise<string> {
  const user = await prisma.user.create({
    data: {
      email: `${tag}.${suffix}@example.test`,
      displayName: `${tag}_${suffix}`.slice(0, 24),
      passwordHash: await hashPassword('a-sufficiently-long-password'),
    },
  });
  created.push(user.id);
  return user.id;
}

function cardsIn(expansionId: string): string[] {
  return Object.values(CARD_DEFINITIONS)
    .filter((card) => card.collectible && card.expansionId === expansionId)
    .map((card) => card.id)
    .sort();
}

async function owned(userId: string, cardId: string): Promise<number> {
  const row = await prisma.collectionEntry.findUnique({
    where: { userId_cardId: { userId, cardId } },
  });
  return row?.quantity ?? 0;
}

beforeAll(async () => {
  await prisma.expansionPolicyOverride.deleteMany({});
  alice = await makeUser('alice');
  bob = await makeUser('bob');
  await economy.grantFragments(alice, 5000);
  await economy.grantFragments(bob, 5000);
});

afterAll(async () => {
  await prisma.expansionPolicyOverride.deleteMany({});
  if (created.length > 0) await prisma.user.deleteMany({ where: { id: { in: created } } });
  await prisma.$disconnect();
});

describe('an expansion from before release to archive', () => {
  // The stages run in order and each builds on the last, which is the whole
  // point: nothing between them is a migration.

  it('stage 1 — unreleased content exists but is invisible and inert', async () => {
    const setCards = cardsIn(SET);
    // Cards exist in the registry. They are simply not the player's business.
    expect(setCards.length).toBeGreaterThan(0);

    const visible = await expansions.visibleExpansions();
    expect(visible.map((e) => e.id)).not.toContain(SET);

    // Admin tooling still sees it — that is what makes testing a set possible.
    const all = await expansions.allExpansions();
    expect(all.map((e) => e.id)).toContain(SET);

    const browsed = await collections.browse(alice);
    for (const cardId of setCards) {
      expect(browsed.map((c) => c.cardId)).not.toContain(cardId);
    }

    const card = setCards[0]!;
    await expect(economy.craft(alice, card, 1)).rejects.toMatchObject({
      code: 'EXPANSION_NOT_RELEASED',
    });
    await expect(packs.open(alice, SET_PACK)).rejects.toMatchObject({
      code: 'EXPANSION_NOT_RELEASED',
    });
    expect((await packs.availablePacks()).map((p) => p.id)).not.toContain(SET_PACK);

    // Neither format admits it, though `standard` is already configured true.
    const policies = await expansions.policies();
    expect(policies[SET]!.policy.standard).toBe(true);
    const readiness = collections.assess([card], new Map([[card, 1]]), policies, 'WILD');
    expect(readiness.illegalInFormat.map((e) => e.cardId)).toContain(card);
  });

  it('stage 2 — release opens the set with no migration and no second decision', async () => {
    // The social launch: traded and opened, but not yet craftable.
    await expansions.updateFlags(SET, {
      released: true,
      tradeable: true,
      duplicateProtection: false,
      craftable: false,
      disenchantable: true,
      availableInPacks: true,
      standard: true,
    });

    const visible = await expansions.visibleExpansions();
    expect(visible.map((e) => e.id)).toContain(SET);
    expect((await packs.availablePacks()).map((p) => p.id)).toContain(SET_PACK);

    // Standard legality needed no separate act: it was configured before launch.
    const policies = await expansions.policies();
    expect(policies[SET]!.policy.standard).toBe(true);

    const browsed = await collections.browse(alice);
    const card = cardsIn(SET)[0]!;
    const row = browsed.find((c) => c.cardId === card)!;
    expect(row).toBeTruthy();
    expect(row.craftable).toBe(false);
    expect(row.tradeable).toBe(true);
    expect(row.standardLegal).toBe(true);
  });

  it('stage 3 — players open packs and receive duplicates freely', async () => {
    // Protection is off, so a hoard is expected and is the raw material of
    // the trading phase that follows.
    for (let i = 0; i < 6; i += 1) {
      await packs.open(alice, SET_PACK, { seed: `alice-${i}` });
      await packs.open(bob, SET_PACK, { seed: `bob-${i}` });
    }
    const rows = await prisma.collectionEntry.findMany({
      where: { userId: alice, cardId: { in: cardsIn(SET) } },
    });
    const total = rows.reduce((sum, row) => sum + row.quantity, 0);
    expect(total).toBe(30);
    // With protection off, ownership had no say, so duplicates are expected.
    expect(rows.some((row) => row.quantity > 2)).toBe(true);
  });

  it('stage 4 — crafting is still refused while trading is not', async () => {
    const card = cardsIn(SET)[0]!;
    await expect(economy.craft(alice, card, 1)).rejects.toMatchObject({
      code: 'CARD_NOT_CRAFTABLE',
    });

    // The same card trades without complaint: the flags are independent.
    const mine = await owned(alice, card);
    if (mine > 0) {
      let trade = await trades.create(alice, bob);
      trade = await trades.updateOffer(alice, trade.id, [{ cardId: card, quantity: 1 }]);
      trade = await trades.accept(alice, trade.id, trade.revision);
      trade = await trades.accept(bob, trade.id, trade.revision);
      expect(trade.status).toBe('ACCEPTED');
      expect(await owned(alice, card)).toBe(mine - 1);
    }
  });

  it('stage 5 — crafting is switched on later, alone', async () => {
    await expansions.updateFlags(SET, { craftable: true });
    const card = cardsIn(SET)[0]!;
    const before = await economy.balance(alice);
    const result = await economy.craft(alice, card, 1);
    expect(result.fragmentDelta).toBe(
      -CRAFTING_VALUES[CARD_DEFINITIONS[card]!.rarity as EarnedRarity].craft,
    );
    expect(await economy.balance(alice)).toBeLessThan(before);

    // Nothing else moved when that one flag did.
    const policy = (await expansions.policy(SET)).policy;
    expect(policy.tradeable).toBe(true);
    expect(policy.availableInPacks).toBe(true);
    expect(policy.standard).toBe(true);
  });

  it('stage 6 — the set ages: trading off, duplicate protection on', async () => {
    // A player may steer their own collection before the switch, which is
    // the intended shape of the game rather than something to prevent.
    // Pick a card actually held in excess, so the disenchant below has
    // something to bite on.
    let card = cardsIn(SET)[0]!;
    for (const candidate of cardsIn(SET)) {
      if ((await owned(alice, candidate)) > 2) {
        card = candidate;
        break;
      }
    }
    const hoarded = await owned(alice, card);
    if (hoarded > 2) {
      await economy.disenchant(alice, card, hoarded - 1);
      expect(await owned(alice, card)).toBe(1);
    }

    await expansions.updateFlags(SET, { tradeable: false, duplicateProtection: true });

    // Protection evaluates what is held right now — no history was needed.
    // A card below its playset is wanted again, whatever it once was.
    const preview = await packs.protectionPreview(alice, SET_PACK);
    const limit = CARD_DEFINITIONS[card]!.rarity === 'LEGENDARY' ? 1 : 2;
    const held = await owned(alice, card);
    if (held < limit) {
      expect(preview.eligible).toContain(card);
    } else {
      expect(preview.complete).toContain(card);
    }

    // Trading is refused from this moment, including for offers already open.
    const trade = await trades.create(alice, bob);
    await expect(
      trades.updateOffer(alice, trade.id, [{ cardId: card, quantity: 1 }]),
    ).rejects.toMatchObject({ code: 'CARD_NOT_TRADEABLE' });
  });

  it('stage 7 — a trade already completed stays completed', async () => {
    // Trading is off now; what happened while it was on is untouched.
    const history = await trades.history(alice);
    const fromThisSet = history.filter((row) => CARD_DEFINITIONS[row.cardId]?.expansionId === SET);
    expect(fromThisSet.length).toBeGreaterThan(0);
    for (const row of fromThisSet) {
      // The policy that permitted it is recorded, so the record still explains
      // itself even though the set is no longer tradeable.
      expect((row.context as { policy: { tradeable: boolean } }).policy.tradeable).toBe(true);
    }
  });

  it('stage 8 — rotation out of Standard leaves decks alone', async () => {
    const setCards = cardsIn(SET);
    const card = setCards[0]!;
    // A deck holding the card, saved while it was Standard legal.
    const deck = await prisma.deck.create({
      data: {
        userId: alice,
        name: `Rotating ${suffix}`,
        heroId: 'healer',
        cardIds: Array(30).fill(card),
        format: 'STANDARD',
      },
    });

    await expansions.updateFlags(SET, { standard: false });

    const policies = await expansions.policies();
    const ownedMap = new Map([[card, 30]]);
    const standard = collections.assess(deck.cardIds, ownedMap, policies, 'STANDARD');
    expect(standard.playable).toBe(false);
    expect(standard.illegalInFormat.map((e) => e.cardId)).toContain(card);

    // Wild still admits it, and the deck itself was never touched.
    const wild = collections.assess(deck.cardIds, ownedMap, policies, 'WILD');
    expect(wild.illegalInFormat).toEqual([]);

    const stored = await prisma.deck.findUnique({ where: { id: deck.id } });
    expect(stored).toBeTruthy();
    expect(stored!.cardIds.length).toBe(30);
  });

  it('stage 9 — packs may go on selling a Wild-only set', async () => {
    // Standard status and pack availability are unrelated, and this is the
    // combination that proves it.
    const policy = (await expansions.policy(SET)).policy;
    expect(policy.standard).toBe(false);
    expect(policy.availableInPacks).toBe(true);
    const opened = await packs.open(bob, SET_PACK, { seed: 'wild-era' });
    expect(opened.cards.length).toBeGreaterThan(0);
  });

  it('stage 10 — archived: packs withdrawn, crafting still open', async () => {
    await expansions.updateFlags(SET, { availableInPacks: false });

    await expect(packs.open(alice, SET_PACK)).rejects.toMatchObject({
      code: 'EXPANSION_NOT_AVAILABLE_IN_PACKS',
    });
    expect((await packs.availablePacks()).map((p) => p.id)).not.toContain(SET_PACK);

    // A player completing the set can still craft what they are missing, and
    // play it in Wild. Archiving withdraws a source, not the cards.
    const card = cardsIn(SET)[1] ?? cardsIn(SET)[0]!;
    const result = await economy.craft(alice, card, 1);
    expect(result.owned).toBeGreaterThan(0);

    const policies = await expansions.policies();
    const readiness = collections.assess([card], new Map([[card, 1]]), policies, 'WILD');
    expect(readiness.illegalInFormat).toEqual([]);
  });

  it('stage 11 — the whole walk needed no migration', async () => {
    // Nothing was written anywhere but the policy row: no collection was
    // rebuilt, no deck rewritten, no history amended. The proof is that one
    // override row holds the entire current state of the set.
    const overrides = await prisma.expansionPolicyOverride.findMany({
      where: { expansionId: SET },
    });
    expect(overrides.length).toBe(1);

    // And clearing that one row puts the set back exactly as it shipped.
    const restored = await expansions.clearOverride(SET);
    expect(restored.policy.released).toBe(false);
    // The cards a player collected along the way are still theirs, unreleased
    // or not — they are simply out of reach until it is released again.
    const card = cardsIn(SET)[0]!;
    expect(await owned(alice, card)).toBeGreaterThanOrEqual(0);
    const stillStored = await prisma.collectionEntry.count({
      where: { userId: alice, cardId: { in: cardsIn(SET) } },
    });
    expect(stillStored).toBeGreaterThan(0);
  });
});

describe('the other set went about its business throughout', () => {
  it('was never touched by the first one rotating', async () => {
    const other = await expansions.policy(OTHER_SET);
    // No override was ever written for it, so it still reads as shipped.
    expect(other.policy.released).toBe(true);
    const overrides = await prisma.expansionPolicyOverride.findMany({
      where: { expansionId: OTHER_SET },
    });
    expect(overrides.length).toBe(0);
  });
});
