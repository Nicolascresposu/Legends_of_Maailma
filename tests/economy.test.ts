import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { PrismaClient } from '@prisma/client';
import { CARD_DEFINITIONS, CRAFTING_VALUES } from '@maailma/card-definitions';
import type { Rarity } from '@maailma/game-model';
import { hashPassword } from '../apps/server/src/auth/passwords.js';
import { EconomyService } from '../apps/server/src/services/economy-service.js';
import { ExpansionService } from '../apps/server/src/services/expansion-service.js';

/**
 * Crafting and disenchanting against a real database, because the properties
 * worth testing here — atomicity, concurrency, idempotency — only exist at the
 * database. An in-memory double would pass while the real thing double-spent.
 */
const prisma = new PrismaClient();
const expansions = new ExpansionService(prisma);
const economy = new EconomyService(prisma, expansions);

const suffix = `e${Date.now()}${Math.floor(Math.random() * 1000)}`;
const created: string[] = [];

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

/** A released, fully-enabled expansion is the baseline every test starts from. */
async function resetPolicies(): Promise<void> {
  await prisma.expansionPolicyOverride.deleteMany({});
}

/**
 * A collectible card of a given rarity, optionally from a named expansion.
 *
 * Looked up rather than hard-coded so that the registry can gain and lose
 * cards without these tests going stale — what matters here is the price of a
 * rarity, not which card happens to carry it.
 */
function cardOfRarity(rarity: Rarity, expansionId?: string): string {
  const card = Object.values(CARD_DEFINITIONS).find(
    (c) => c.rarity === rarity && c.collectible && (!expansionId || c.expansionId === expansionId),
  );
  if (!card) throw new Error(`No ${rarity} card${expansionId ? ` in ${expansionId}` : ''}`);
  return card.id;
}

const COMMON = cardOfRarity('COMMON');
const LEGENDARY = cardOfRarity('LEGENDARY', 'CHRONICLE');
const EPIC = cardOfRarity('EPIC', 'CHRONICLE');

beforeEach(async () => {
  await resetPolicies();
});

afterAll(async () => {
  await resetPolicies();
  if (created.length > 0) await prisma.user.deleteMany({ where: { id: { in: created } } });
  await prisma.$disconnect();
});

describe('crafting costs', () => {
  it('charges the published cost for every rarity', async () => {
    const user = await makeUser('cost');
    await economy.grantFragments(user, 1000);

    const expected: Array<[Rarity, string]> = [
      ['COMMON', cardOfRarity('COMMON')],
      ['RARE', cardOfRarity('RARE')],
      ['EPIC', EPIC],
      ['LEGENDARY', LEGENDARY],
    ];
    for (const [rarity, cardId] of expected) {
      const before = await economy.balance(user);
      const result = await economy.craft(user, cardId, 1);
      expect(result.fragmentDelta, rarity).toBe(-CRAFTING_VALUES[rarity].craft);
      expect(result.fragmentBalance).toBe(before - CRAFTING_VALUES[rarity].craft);
    }
  });

  it('multiplies the cost by the quantity crafted', async () => {
    const user = await makeUser('bulk');
    await economy.grantFragments(user, 100);
    const result = await economy.craft(user, COMMON, 4);
    expect(result.fragmentDelta).toBe(-CRAFTING_VALUES.COMMON.craft * 4);
    expect(result.owned).toBe(4);
  });

  it('grants the copies it charged for', async () => {
    const user = await makeUser('grant');
    await economy.grantFragments(user, 100);
    await economy.craft(user, COMMON, 1);
    const result = await economy.craft(user, COMMON, 1);
    expect(result.owned).toBe(2);
  });

  it('allows crafting past the deck copy limit, because spares have uses', async () => {
    const user = await makeUser('spare');
    await economy.grantFragments(user, 1000);
    const result = await economy.craft(user, COMMON, 5);
    expect(result.owned).toBe(5);
  });
});

describe('crafting refusals', () => {
  it('refuses when the balance falls short, and changes nothing', async () => {
    const user = await makeUser('poor');
    await economy.grantFragments(user, 4);
    await expect(economy.craft(user, COMMON, 1)).rejects.toMatchObject({
      code: 'INSUFFICIENT_FRAGMENTS',
    });
    expect(await economy.balance(user)).toBe(4);
    const owned = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: COMMON } },
    });
    expect(owned).toBeNull();
  });

  it('refuses a non-craftable expansion while still allowing its other uses', async () => {
    const user = await makeUser('nocraft');
    await economy.grantFragments(user, 500);
    await expansions.updateFlags('CORE', { craftable: false });
    await expect(economy.craft(user, COMMON, 1)).rejects.toMatchObject({
      code: 'CARD_NOT_CRAFTABLE',
    });
    expect(await economy.balance(user)).toBe(500);
  });

  it('refuses an unreleased expansion without confirming the card exists', async () => {
    const user = await makeUser('unrel');
    await economy.grantFragments(user, 500);
    await expansions.updateFlags('CORE', { released: false, craftable: true });
    await expect(economy.craft(user, COMMON, 1)).rejects.toMatchObject({
      code: 'EXPANSION_NOT_RELEASED',
      status: 404,
    });
  });

  it('refuses a card the registry does not define', async () => {
    const user = await makeUser('ghost');
    await expect(economy.craft(user, 'no_such_card', 1)).rejects.toMatchObject({
      code: 'UNKNOWN_CARD',
    });
  });

  it('refuses a quantity below one', async () => {
    const user = await makeUser('zero');
    await economy.grantFragments(user, 100);
    await expect(economy.craft(user, COMMON, 0)).rejects.toMatchObject({
      code: 'INVALID_QUANTITY',
    });
    await expect(economy.craft(user, COMMON, -3)).rejects.toMatchObject({
      code: 'INVALID_QUANTITY',
    });
  });
});

describe('disenchanting', () => {
  it('returns the published value for every rarity', async () => {
    const user = await makeUser('dust');
    await economy.grantFragments(user, 2000);
    const cases: Array<[Rarity, string]> = [
      ['COMMON', cardOfRarity('COMMON')],
      ['RARE', cardOfRarity('RARE')],
      ['EPIC', EPIC],
      ['LEGENDARY', LEGENDARY],
    ];
    for (const [rarity, cardId] of cases) {
      await economy.craft(user, cardId, 1);
      const before = await economy.balance(user);
      const result = await economy.disenchant(user, cardId, 1);
      expect(result.fragmentDelta, rarity).toBe(CRAFTING_VALUES[rarity].disenchant);
      expect(result.fragmentBalance).toBe(before + CRAFTING_VALUES[rarity].disenchant);
    }
  });

  it('decreases the owned quantity', async () => {
    const user = await makeUser('down');
    await economy.grantFragments(user, 100);
    await economy.craft(user, COMMON, 3);
    const result = await economy.disenchant(user, COMMON, 2);
    expect(result.owned).toBe(1);
  });

  it('refuses to disenchant more copies than are owned, atomically', async () => {
    const user = await makeUser('over');
    await economy.grantFragments(user, 100);
    await economy.craft(user, COMMON, 1);
    const balance = await economy.balance(user);
    await expect(economy.disenchant(user, COMMON, 2)).rejects.toMatchObject({
      code: 'INSUFFICIENT_CARD_QUANTITY',
    });
    expect(await economy.balance(user)).toBe(balance);
    const entry = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: COMMON } },
    });
    expect(entry?.quantity).toBe(1);
  });

  it('refuses a non-disenchantable expansion', async () => {
    const user = await makeUser('nodust');
    await economy.grantFragments(user, 100);
    await economy.craft(user, COMMON, 1);
    await expansions.updateFlags('CORE', { disenchantable: false });
    await expect(economy.disenchant(user, COMMON, 1)).rejects.toMatchObject({
      code: 'CARD_NOT_DISENCHANTABLE',
    });
  });

  it('refuses an unreleased expansion', async () => {
    const user = await makeUser('dustunrel');
    await economy.grantFragments(user, 100);
    await economy.craft(user, COMMON, 1);
    await expansions.updateFlags('CORE', { released: false });
    await expect(economy.disenchant(user, COMMON, 1)).rejects.toMatchObject({
      code: 'EXPANSION_NOT_RELEASED',
    });
  });

  it('allows disenchanting where crafting is forbidden', async () => {
    // The two flags are independent; neither implies the other.
    const user = await makeUser('dustonly');
    await economy.grantFragments(user, 100);
    await economy.craft(user, COMMON, 1);
    await expansions.updateFlags('CORE', { craftable: false, disenchantable: true });
    await expect(economy.craft(user, COMMON, 1)).rejects.toMatchObject({
      code: 'CARD_NOT_CRAFTABLE',
    });
    const result = await economy.disenchant(user, COMMON, 1);
    expect(result.fragmentDelta).toBe(CRAFTING_VALUES.COMMON.disenchant);
  });

  it('allows crafting where disenchanting is forbidden', async () => {
    const user = await makeUser('craftonly');
    await economy.grantFragments(user, 100);
    await expansions.updateFlags('CORE', { craftable: true, disenchantable: false });
    const result = await economy.craft(user, COMMON, 1);
    expect(result.owned).toBe(1);
    await expect(economy.disenchant(user, COMMON, 1)).rejects.toMatchObject({
      code: 'CARD_NOT_DISENCHANTABLE',
    });
  });
});

describe('concurrency', () => {
  it('lets only one of two simultaneous crafts spend the same Fragments', async () => {
    const user = await makeUser('race');
    const cost = CRAFTING_VALUES.LEGENDARY.craft;
    await economy.grantFragments(user, cost);

    const attempts = await Promise.allSettled([
      economy.craft(user, LEGENDARY, 1),
      economy.craft(user, LEGENDARY, 1),
    ]);
    const succeeded = attempts.filter((a) => a.status === 'fulfilled');
    expect(succeeded.length).toBe(1);
    expect(await economy.balance(user)).toBe(0);

    const entry = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: LEGENDARY } },
    });
    expect(entry?.quantity).toBe(1);
  });

  it('lets only one of two simultaneous disenchants consume the same copy', async () => {
    const user = await makeUser('dustrace');
    await economy.grantFragments(user, 500);
    await economy.craft(user, EPIC, 1);
    const before = await economy.balance(user);

    const attempts = await Promise.allSettled([
      economy.disenchant(user, EPIC, 1),
      economy.disenchant(user, EPIC, 1),
    ]);
    expect(attempts.filter((a) => a.status === 'fulfilled').length).toBe(1);
    expect(await economy.balance(user)).toBe(before + CRAFTING_VALUES.EPIC.disenchant);
    const entry = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: EPIC } },
    });
    expect(entry?.quantity).toBe(0);
  });
});

describe('idempotency', () => {
  it('does not craft twice when a request is retried', async () => {
    const user = await makeUser('retry');
    await economy.grantFragments(user, 1000);
    const requestId = `craft-${suffix}-1`;

    const first = await economy.craft(user, LEGENDARY, 1, requestId);
    const second = await economy.craft(user, LEGENDARY, 1, requestId);

    expect(second).toEqual(first);
    expect(await economy.balance(user)).toBe(1000 - CRAFTING_VALUES.LEGENDARY.craft);
    const entry = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: LEGENDARY } },
    });
    expect(entry?.quantity).toBe(1);
  });

  it('collapses two concurrent copies of the same request into one craft', async () => {
    const user = await makeUser('retryrace');
    await economy.grantFragments(user, 1000);
    const requestId = `craft-${suffix}-concurrent`;

    await Promise.allSettled([
      economy.craft(user, EPIC, 1, requestId),
      economy.craft(user, EPIC, 1, requestId),
    ]);
    const entry = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: EPIC } },
    });
    expect(entry?.quantity).toBe(1);
    expect(await economy.balance(user)).toBe(1000 - CRAFTING_VALUES.EPIC.craft);
  });

  it('does not disenchant twice when a request is retried', async () => {
    const user = await makeUser('dustretry');
    await economy.grantFragments(user, 500);
    await economy.craft(user, COMMON, 2);
    const requestId = `dust-${suffix}-1`;

    const first = await economy.disenchant(user, COMMON, 1, requestId);
    const second = await economy.disenchant(user, COMMON, 1, requestId);
    expect(second).toEqual(first);

    const entry = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: COMMON } },
    });
    expect(entry?.quantity).toBe(1);
  });

  it('refuses a request id already used by somebody else', async () => {
    const owner = await makeUser('idowner');
    const other = await makeUser('idother');
    await economy.grantFragments(owner, 100);
    await economy.grantFragments(other, 100);
    const requestId = `shared-${suffix}`;

    await economy.craft(owner, COMMON, 1, requestId);
    await expect(economy.craft(other, COMMON, 1, requestId)).rejects.toMatchObject({
      code: 'REQUEST_ID_REUSED',
    });
  });
});

describe('disenchant extras', () => {
  it('counts only the copies above the playable limit', async () => {
    const user = await makeUser('extras');
    await economy.grantFragments(user, 1000);
    await economy.craft(user, COMMON, 5);

    const plan = await economy.planDisenchantExtras(user);
    const entry = plan.extras.find((e) => e.cardId === COMMON);
    expect(entry).toMatchObject({ owned: 5, copyLimit: 2, extra: 3 });
    expect(entry!.value).toBe(CRAFTING_VALUES.COMMON.disenchant * 3);
  });

  it('treats a Legendary playset as one copy', async () => {
    const user = await makeUser('extraleg');
    await economy.grantFragments(user, 1000);
    await economy.craft(user, LEGENDARY, 3);
    const plan = await economy.planDisenchantExtras(user);
    expect(plan.extras.find((e) => e.cardId === LEGENDARY)).toMatchObject({
      copyLimit: 1,
      extra: 2,
    });
  });

  it('leaves the playset behind when performed', async () => {
    const user = await makeUser('extrado');
    await economy.grantFragments(user, 1000);
    await economy.craft(user, COMMON, 5);

    const result = await economy.disenchantExtras(user);
    expect(result.disenchanted).toContainEqual({ cardId: COMMON, quantity: 3 });
    const entry = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: COMMON } },
    });
    expect(entry?.quantity).toBe(2);
  });

  it('never runs on its own: the plan alone changes nothing', async () => {
    const user = await makeUser('extraplan');
    await economy.grantFragments(user, 1000);
    await economy.craft(user, COMMON, 5);
    const balance = await economy.balance(user);

    await economy.planDisenchantExtras(user);
    expect(await economy.balance(user)).toBe(balance);
    const entry = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: COMMON } },
    });
    expect(entry?.quantity).toBe(5);
  });

  it('leaves spares from a non-disenchantable expansion alone, and says so', async () => {
    const user = await makeUser('extraskip');
    await economy.grantFragments(user, 2000);
    await economy.craft(user, COMMON, 5);
    await economy.craft(user, EPIC, 4);
    await expansions.updateFlags('CHRONICLE', { disenchantable: false });

    const result = await economy.disenchantExtras(user);
    expect(result.disenchanted.map((d) => d.cardId)).toEqual([COMMON]);
    expect(result.skipped).toContainEqual(
      expect.objectContaining({ cardId: EPIC, reason: 'CARD_NOT_DISENCHANTABLE' }),
    );
    const epic = await prisma.collectionEntry.findUnique({
      where: { userId_cardId: { userId: user, cardId: EPIC } },
    });
    expect(epic?.quantity).toBe(4);
  });
});

describe('audit ledger', () => {
  it('records every movement with enough context to explain a balance', async () => {
    const user = await makeUser('ledger');
    await economy.grantFragments(user, 500);
    await economy.craft(user, COMMON, 2);
    await economy.disenchant(user, COMMON, 1);

    const history = await economy.history(user);
    const types = history.map((row) => row.type);
    expect(types).toContain('CRAFT');
    expect(types).toContain('DISENCHANT');
    expect(types).toContain('ADMIN_GRANT');

    // The ledger accounts for the balance exactly.
    const sum = history.reduce((total, row) => total + row.fragmentDelta, 0);
    expect(sum).toBe(await economy.balance(user));
  });
});
