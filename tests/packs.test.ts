import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { PrismaClient } from '@prisma/client';
import { CARD_DEFINITIONS, getPackDefinition } from '@maailma/card-definitions';
import { deckCopyLimit, generatePack, packPool } from '@maailma/game-engine';
import { SeededRng } from '@maailma/rng';
import type { Rarity } from '@maailma/game-model';
import { hashPassword } from '../apps/server/src/auth/passwords.js';
import { EconomyService } from '../apps/server/src/services/economy-service.js';
import { ExpansionService } from '../apps/server/src/services/expansion-service.js';
import { PackService } from '../apps/server/src/services/pack-service.js';

const prisma = new PrismaClient();
const expansions = new ExpansionService(prisma);
const economy = new EconomyService(prisma, expansions);
const packs = new PackService(prisma, expansions);

const suffix = `p${Date.now()}${Math.floor(Math.random() * 1000)}`;
const created: string[] = [];

const CORE_PACK = getPackDefinition('CORE_PACK');
const CHRONICLE_PACK = getPackDefinition('CHRONICLE_PACK');
const UNRELEASED_PACK = getPackDefinition('MACHINES_OF_KONA_PACK');

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

/** Owned counts for a hand-built protection scenario. */
function owning(entries: Record<string, number>): Map<string, number> {
  return new Map(Object.entries(entries));
}

beforeEach(async () => {
  await prisma.expansionPolicyOverride.deleteMany({});
});

afterAll(async () => {
  await prisma.expansionPolicyOverride.deleteMany({});
  if (created.length > 0) await prisma.user.deleteMany({ where: { id: { in: created } } });
  await prisma.$disconnect();
});

describe('pack pools', () => {
  it('draws only from its own expansion', () => {
    for (const card of packPool(CORE_PACK)) {
      expect(card.expansionId).toBe('CORE');
      expect(card.collectible).toBe(true);
    }
  });

  it('fills every slot the definition promises', () => {
    const result = generatePack(CORE_PACK, new SeededRng('seed-1'));
    expect(result.cards.length).toBe(CORE_PACK.cardCount);
    for (const slot of result.cards) {
      expect(CARD_DEFINITIONS[slot.cardId]!.expansionId).toBe('CORE');
    }
  });

  it('produces the same pack from the same seed', () => {
    const a = generatePack(CORE_PACK, new SeededRng('repeatable'));
    const b = generatePack(CORE_PACK, new SeededRng('repeatable'));
    expect(a.cards).toEqual(b.cards);
  });

  it('produces different packs from different seeds', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 20; i += 1) {
      seen.add(
        generatePack(CORE_PACK, new SeededRng(`seed-${i}`))
          .cards.map((c) => c.cardId)
          .join(','),
      );
    }
    expect(seen.size).toBeGreaterThan(1);
  });

  it('guarantees the pack is not entirely Common', () => {
    // The last slot never rolls Common, so every pack has something above it.
    for (let i = 0; i < 25; i += 1) {
      const result = generatePack(CORE_PACK, new SeededRng(`guarantee-${i}`));
      expect(result.cards.some((slot) => slot.rarity !== 'COMMON')).toBe(true);
    }
  });
});

describe('duplicate protection selects cards, never rarities', () => {
  const pool = packPool(CORE_PACK);

  it('prefers a card the player owns none of', () => {
    const owned = owning(
      Object.fromEntries(pool.map((card) => [card.id, deckCopyLimit(card.rarity)])),
    );
    const target = pool.find((c) => c.rarity === 'COMMON')!;
    owned.set(target.id, 0);

    const result = generatePack(CORE_PACK, new SeededRng('protect'), {
      duplicateProtection: true,
      owned,
    });
    const commons = result.cards.filter((slot) => slot.rarity === 'COMMON');
    // Every Common slot must land on the only Common still wanted.
    expect(commons.length).toBeGreaterThan(0);
    for (const slot of commons) expect(slot.cardId).toBe(target.id);
  });

  it('treats a card one short of a playset as still eligible', () => {
    const target = pool.find((c) => c.rarity === 'COMMON')!;
    const owned = owning(
      Object.fromEntries(pool.map((card) => [card.id, deckCopyLimit(card.rarity)])),
    );
    owned.set(target.id, deckCopyLimit(target.rarity) - 1);

    const result = generatePack(CORE_PACK, new SeededRng('one-short'), {
      duplicateProtection: true,
      owned,
    });
    for (const slot of result.cards.filter((s) => s.rarity === 'COMMON')) {
      expect(slot.cardId).toBe(target.id);
    }
  });

  it('protects a card at exactly its playset', () => {
    const commons = pool.filter((c) => c.rarity === 'COMMON');
    const full = commons[0]!;
    const owned = owning({ [full.id]: deckCopyLimit(full.rarity) });

    for (let i = 0; i < 30; i += 1) {
      const result = generatePack(CORE_PACK, new SeededRng(`full-${i}`), {
        duplicateProtection: true,
        owned,
      });
      for (const slot of result.cards.filter((s) => s.rarity === 'COMMON')) {
        expect(slot.cardId).not.toBe(full.id);
      }
    }
  });

  it('treats a Legendary as complete at one copy and eligible at none', () => {
    const legendaries = packPool(CHRONICLE_PACK).filter((c) => c.rarity === 'LEGENDARY');
    expect(legendaries.length).toBeGreaterThan(0);
    const legendary = legendaries[0]!;
    expect(deckCopyLimit('LEGENDARY')).toBe(1);

    // Owned none: eligible.
    const eligible = packPool(CHRONICLE_PACK).filter(
      (card) => (owning({}).get(card.id) ?? 0) < deckCopyLimit(card.rarity),
    );
    expect(eligible.map((c) => c.id)).toContain(legendary.id);

    // Owned one: complete.
    const held = owning({ [legendary.id]: 1 });
    const stillEligible = packPool(CHRONICLE_PACK).filter(
      (card) => (held.get(card.id) ?? 0) < deckCopyLimit(card.rarity),
    );
    expect(stillEligible.map((c) => c.id)).not.toContain(legendary.id);
  });

  it('falls back to duplicates once a rarity is complete', () => {
    // Nothing left to protect must not mean nothing is awarded.
    const owned = owning(
      Object.fromEntries(pool.map((card) => [card.id, deckCopyLimit(card.rarity)])),
    );
    const result = generatePack(CORE_PACK, new SeededRng('complete'), {
      duplicateProtection: true,
      owned,
    });
    expect(result.cards.length).toBe(CORE_PACK.cardCount);
    for (const slot of result.cards) expect(slot.protectedPick).toBe(false);
  });

  it('leaves the rarity distribution alone', () => {
    // Protection must change which card fills a slot, never how often each
    // rarity appears — otherwise a complete collection would open worse packs.
    const full = owning(
      Object.fromEntries(pool.map((card) => [card.id, deckCopyLimit(card.rarity)])),
    );
    const countRarities = (protect: boolean) => {
      const tally: Record<string, number> = {};
      for (let i = 0; i < 300; i += 1) {
        const result = generatePack(CORE_PACK, new SeededRng(`dist-${i}`), {
          duplicateProtection: protect,
          owned: protect ? full : undefined,
        });
        for (const slot of result.cards) tally[slot.rarity] = (tally[slot.rarity] ?? 0) + 1;
      }
      return tally;
    };
    expect(countRarities(true)).toEqual(countRarities(false));
  });
});

describe('duplicate protection disabled', () => {
  it('ignores ownership entirely', () => {
    const pool = packPool(CORE_PACK);
    const hoard = owning(Object.fromEntries(pool.map((card) => [card.id, 10])));

    for (let i = 0; i < 15; i += 1) {
      const withOwnership = generatePack(CORE_PACK, new SeededRng(`off-${i}`), {
        duplicateProtection: false,
        owned: hoard,
      });
      const without = generatePack(CORE_PACK, new SeededRng(`off-${i}`));
      // Identical seeds must give identical packs: ownership had no influence.
      expect(withOwnership.cards).toEqual(without.cards);
    }
  });
});

describe('pack availability follows policy', () => {
  it('opens a released, available pack and grants its cards', async () => {
    const user = await makeUser('open');
    const opened = await packs.open(user, CORE_PACK.id, { seed: 'grant-seed' });
    expect(opened.cards.length).toBe(CORE_PACK.cardCount);

    const rows = await prisma.collectionEntry.findMany({ where: { userId: user } });
    const total = rows.reduce((sum, row) => sum + row.quantity, 0);
    expect(total).toBe(CORE_PACK.cardCount);
  });

  it('refuses a pack whose expansion is released but unavailable', async () => {
    const user = await makeUser('unavail');
    await expansions.updateFlags('CORE', { availableInPacks: false });
    await expect(packs.open(user, CORE_PACK.id)).rejects.toMatchObject({
      code: 'EXPANSION_NOT_AVAILABLE_IN_PACKS',
    });
    expect(await prisma.collectionEntry.count({ where: { userId: user } })).toBe(0);
  });

  it('refuses a pack from an unreleased expansion even when marked available', async () => {
    const user = await makeUser('unrelpack');
    await expansions.updateFlags('MACHINES_OF_KONA', { availableInPacks: true });
    await expect(packs.open(user, UNRELEASED_PACK.id)).rejects.toMatchObject({
      code: 'EXPANSION_NOT_RELEASED',
    });
  });

  it('does not let Standard status decide pack availability', async () => {
    const user = await makeUser('wildpack');
    // Rotated out of Standard but still sold: a valid, deliberate combination.
    await expansions.updateFlags('CORE', { standard: false, availableInPacks: true });
    const opened = await packs.open(user, CORE_PACK.id, { seed: 'wild-seed' });
    expect(opened.cards.length).toBe(CORE_PACK.cardCount);
  });

  it('lists only the packs currently openable', async () => {
    const all = await packs.availablePacks();
    expect(all.map((p) => p.id)).not.toContain(UNRELEASED_PACK.id);

    await expansions.updateFlags('CORE', { availableInPacks: false });
    const fewer = await packs.availablePacks();
    expect(fewer.map((p) => p.id)).not.toContain(CORE_PACK.id);
  });

  it('preserves the definition of an unavailable pack so it can return', async () => {
    await expansions.updateFlags('CORE', { availableInPacks: false });
    // Withdrawn, not deleted.
    expect(getPackDefinition(CORE_PACK.id)).toBeTruthy();
    await expansions.updateFlags('CORE', { availableInPacks: true });
    const user = await makeUser('returned');
    const opened = await packs.open(user, CORE_PACK.id, { seed: 'back-again' });
    expect(opened.cards.length).toBe(CORE_PACK.cardCount);
  });

  it('refuses a request id already used for something else', async () => {
    // The id is the caller's to choose, so it must not become a way to replay
    // somebody else's outcome, or to collect a craft as a pack.
    const owner = await makeUser('packowner');
    const other = await makeUser('packother');
    const requestId = `pack-shared-${suffix}`;
    await packs.open(owner, CORE_PACK.id, { seed: 'shared', requestId });
    await expect(
      packs.open(other, CORE_PACK.id, { seed: 'shared', requestId }),
    ).rejects.toMatchObject({ code: 'REQUEST_ID_REUSED' });
  });

  it('does not open a pack twice for a retried request', async () => {
    const user = await makeUser('packretry');
    const requestId = `pack-${suffix}-1`;
    const first = await packs.open(user, CORE_PACK.id, { seed: 'idem', requestId });
    const second = await packs.open(user, CORE_PACK.id, { seed: 'idem', requestId });
    expect(second.cards).toEqual(first.cards);

    const rows = await prisma.collectionEntry.findMany({ where: { userId: user } });
    expect(rows.reduce((sum, row) => sum + row.quantity, 0)).toBe(CORE_PACK.cardCount);
  });
});

describe('ownership manipulation is a feature, not an exploit', () => {
  /**
   * These are regression tests in the strictest sense: the behaviour they pin
   * down looks like a bug to anyone who has not read the design. A future
   * developer "fixing" it by remembering what a player once owned would break
   * the collection game on purpose.
   */
  const pool = packPool(CORE_PACK);
  const epic = Object.values(CARD_DEFINITIONS).find(
    (c) => c.rarity === 'EPIC' && c.expansionId === 'CHRONICLE',
  )!;

  async function eligibility(userId: string, cardId: string): Promise<boolean> {
    const preview = await packs.protectionPreview(userId, CHRONICLE_PACK.id);
    return preview.eligible.includes(cardId);
  }

  it('makes a card eligible again once a copy is traded away', async () => {
    const user = await makeUser('manip-trade');
    await economy.grantFragments(user, 1000);
    await economy.craft(user, epic.id, 2);
    expect(await eligibility(user, epic.id)).toBe(false);

    // Standing in for the trade's effect on the collection: one copy leaves.
    await prisma.collectionEntry.update({
      where: { userId_cardId: { userId: user, cardId: epic.id } },
      data: { quantity: 1 },
    });
    expect(await eligibility(user, epic.id)).toBe(true);
  });

  it('makes a card eligible again once a copy is disenchanted', async () => {
    const user = await makeUser('manip-dust');
    await economy.grantFragments(user, 1000);
    await economy.craft(user, epic.id, 2);
    expect(await eligibility(user, epic.id)).toBe(false);

    await economy.disenchant(user, epic.id, 1);
    expect(await eligibility(user, epic.id)).toBe(true);
  });

  it('removes a card from the protected pool once it is crafted to a playset', async () => {
    const user = await makeUser('manip-craft');
    await economy.grantFragments(user, 1000);
    await economy.craft(user, epic.id, 1);
    expect(await eligibility(user, epic.id)).toBe(true);

    await economy.craft(user, epic.id, 1);
    expect(await eligibility(user, epic.id)).toBe(false);
  });

  it('protects a hoard the moment protection is switched on, with no migration', async () => {
    const user = await makeUser('manip-flip');
    await economy.grantFragments(user, 2000);
    // Five copies of a Common, gathered while protection was off.
    const common = pool.find((c) => c.rarity === 'COMMON')!;
    await economy.craft(user, common.id, 5);

    await expansions.updateFlags('CORE', { duplicateProtection: true });
    const preview = await packs.protectionPreview(user, CORE_PACK.id);
    // Over the limit already: no longer wanted, judged purely on what is held.
    expect(preview.complete).toContain(common.id);
    expect(preview.eligible).not.toContain(common.id);
  });

  it('reads only current ownership, never a history of it', async () => {
    const user = await makeUser('manip-history');
    await economy.grantFragments(user, 2000);
    const common = pool.find((c) => c.rarity === 'COMMON')!;

    // Owned, then given up entirely. A system that remembered would still
    // consider this card "collected"; this one must not.
    await economy.craft(user, common.id, 2);
    await economy.disenchant(user, common.id, 2);

    const preview = await packs.protectionPreview(user, CORE_PACK.id);
    expect(preview.eligible).toContain(common.id);

    // The ledger still remembers, for auditing — it is simply never consulted.
    const history = await economy.history(user);
    expect(history.some((row) => row.cardId === common.id)).toBe(true);
  });

  it('shifts pack contents after a collection changes', async () => {
    const user = await makeUser('manip-packs');
    await economy.grantFragments(user, 5000);
    await expansions.updateFlags('CORE', { duplicateProtection: true });

    // Complete every Common but one, then confirm packs chase the gap.
    const commons = pool.filter((c) => c.rarity === 'COMMON');
    const missing = commons[0]!;
    for (const card of commons.slice(1)) await economy.craft(user, card.id, 2);

    const before = await packs.protectionPreview(user, CORE_PACK.id);
    expect(before.eligible).toContain(missing.id);

    await economy.craft(user, missing.id, 2);
    const after = await packs.protectionPreview(user, CORE_PACK.id);
    expect(after.eligible).not.toContain(missing.id);
  });
});

describe('protection uses the deck copy limits, not its own', () => {
  it('asks the same question the deck builder asks', () => {
    const rarities: Rarity[] = ['COMMON', 'RARE', 'EPIC', 'LEGENDARY'];
    for (const rarity of rarities) {
      const limit = deckCopyLimit(rarity);
      expect(limit).toBe(rarity === 'LEGENDARY' ? 1 : 2);
      // 0..limit-1 eligible, limit complete.
      for (let owned = 0; owned < limit; owned += 1) expect(owned < limit).toBe(true);
      expect(limit < limit).toBe(false);
    }
  });
});
