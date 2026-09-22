import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { PrismaClient } from '@prisma/client';
import { CARD_DEFINITIONS } from '@maailma/card-definitions';
import { hashPassword } from '../apps/server/src/auth/passwords.js';
import { EconomyService } from '../apps/server/src/services/economy-service.js';
import { ExpansionService } from '../apps/server/src/services/expansion-service.js';
import { PackService } from '../apps/server/src/services/pack-service.js';
import { TradeService } from '../apps/server/src/services/trade-service.js';

const prisma = new PrismaClient();
const expansions = new ExpansionService(prisma);
const economy = new EconomyService(prisma, expansions);
const packs = new PackService(prisma, expansions);
const trades = new TradeService(prisma, expansions);

const suffix = `t${Date.now()}${Math.floor(Math.random() * 1000)}`;
const created: string[] = [];

const COMMON = Object.values(CARD_DEFINITIONS).find(
  (c) => c.rarity === 'COMMON' && c.expansionId === 'CORE',
)!.id;
const OTHER_COMMON = Object.values(CARD_DEFINITIONS).filter(
  (c) => c.rarity === 'COMMON' && c.expansionId === 'CORE',
)[1]!.id;
const EPIC = Object.values(CARD_DEFINITIONS).find(
  (c) => c.rarity === 'EPIC' && c.expansionId === 'CHRONICLE',
)!.id;
const LEGENDARY = Object.values(CARD_DEFINITIONS).find(
  (c) => c.rarity === 'LEGENDARY' && c.expansionId === 'CHRONICLE',
)!.id;

async function makeUser(tag: string): Promise<string> {
  const user = await prisma.user.create({
    data: {
      email: `${tag}.${suffix}.${Math.random().toString(36).slice(2, 8)}@example.test`,
      displayName: `${tag}${Math.random().toString(36).slice(2, 8)}`.slice(0, 24),
      passwordHash: await hashPassword('a-sufficiently-long-password'),
    },
  });
  created.push(user.id);
  return user.id;
}

/** Puts cards straight into a collection, bypassing the economy. */
async function give(userId: string, cardId: string, quantity: number): Promise<void> {
  await prisma.collectionEntry.upsert({
    where: { userId_cardId: { userId, cardId } },
    create: { userId, cardId, quantity },
    update: { quantity: { increment: quantity } },
  });
}

async function owned(userId: string, cardId: string): Promise<number> {
  const row = await prisma.collectionEntry.findUnique({
    where: { userId_cardId: { userId, cardId } },
  });
  return row?.quantity ?? 0;
}

/** Opens a trade, sets both offers, and returns it ready to accept. */
async function stage(
  a: string,
  b: string,
  offerA: Array<{ cardId: string; quantity: number }>,
  offerB: Array<{ cardId: string; quantity: number }> = [],
) {
  let trade = await trades.create(a, b);
  if (offerA.length > 0) trade = await trades.updateOffer(a, trade.id, offerA);
  if (offerB.length > 0) trade = await trades.updateOffer(b, trade.id, offerB);
  return trade;
}

beforeEach(async () => {
  await prisma.expansionPolicyOverride.deleteMany({});
});

afterAll(async () => {
  await prisma.expansionPolicyOverride.deleteMany({});
  if (created.length > 0) await prisma.user.deleteMany({ where: { id: { in: created } } });
  await prisma.$disconnect();
});

describe('trade execution', () => {
  it('moves cards both ways when both players accept', async () => {
    const [a, b] = [await makeUser('a'), await makeUser('b')];
    await give(a, COMMON, 2);
    await give(b, EPIC, 1);

    let trade = await stage(
      a,
      b,
      [{ cardId: COMMON, quantity: 2 }],
      [{ cardId: EPIC, quantity: 1 }],
    );
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);

    expect(trade.status).toBe('ACCEPTED');
    expect(await owned(a, COMMON)).toBe(0);
    expect(await owned(b, COMMON)).toBe(2);
    expect(await owned(b, EPIC)).toBe(0);
    expect(await owned(a, EPIC)).toBe(1);
  });

  it('completes a one-sided gift', async () => {
    const [a, b] = [await makeUser('gifter'), await makeUser('giftee')];
    await give(a, LEGENDARY, 1);

    let trade = await stage(a, b, [{ cardId: LEGENDARY, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);

    expect(trade.status).toBe('ACCEPTED');
    expect(await owned(a, LEGENDARY)).toBe(0);
    expect(await owned(b, LEGENDARY)).toBe(1);
  });

  it('moves several cards per side at once', async () => {
    const [a, b] = [await makeUser('multi1'), await makeUser('multi2')];
    await give(a, COMMON, 2);
    await give(a, OTHER_COMMON, 1);
    await give(b, EPIC, 1);
    await give(b, LEGENDARY, 1);

    let trade = await stage(
      a,
      b,
      [
        { cardId: COMMON, quantity: 2 },
        { cardId: OTHER_COMMON, quantity: 1 },
      ],
      [
        { cardId: EPIC, quantity: 1 },
        { cardId: LEGENDARY, quantity: 1 },
      ],
    );
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);

    expect(trade.status).toBe('ACCEPTED');
    expect(await owned(b, COMMON)).toBe(2);
    expect(await owned(b, OTHER_COMMON)).toBe(1);
    expect(await owned(a, EPIC)).toBe(1);
    expect(await owned(a, LEGENDARY)).toBe(1);
  });

  it('does not judge whether a trade is fair', async () => {
    // A Legendary for a single Common is a perfectly valid agreement.
    const [a, b] = [await makeUser('rich'), await makeUser('lucky')];
    await give(a, LEGENDARY, 1);
    await give(b, COMMON, 1);

    let trade = await stage(
      a,
      b,
      [{ cardId: LEGENDARY, quantity: 1 }],
      [{ cardId: COMMON, quantity: 1 }],
    );
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('ACCEPTED');
  });

  it('normalizes a card listed twice into one entry', async () => {
    const [a, b] = [await makeUser('dup1'), await makeUser('dup2')];
    await give(a, COMMON, 3);

    const trade = await stage(a, b, [
      { cardId: COMMON, quantity: 1 },
      { cardId: COMMON, quantity: 2 },
    ]);
    const side = trade.offers.find((o) => o.userId === a)!;
    expect(side.cards).toEqual([{ cardId: COMMON, quantity: 3 }]);
  });
});

describe('trade offers', () => {
  it('refuses a card the registry does not define, leaving Fragments no way in', async () => {
    const [a, b] = [await makeUser('nofrag1'), await makeUser('nofrag2')];
    const trade = await trades.create(a, b);
    // There is simply no representation for Fragments in an offer: an offer
    // names cards, and anything that is not a card is refused here.
    await expect(
      trades.updateOffer(a, trade.id, [{ cardId: 'fragments', quantity: 100 }]),
    ).rejects.toThrow();
  });

  it('refuses a quantity of zero or below', async () => {
    const [a, b] = [await makeUser('neg1'), await makeUser('neg2')];
    const trade = await trades.create(a, b);
    await expect(
      trades.updateOffer(a, trade.id, [{ cardId: COMMON, quantity: 0 }]),
    ).rejects.toMatchObject({ code: 'INVALID_QUANTITY' });
    await expect(
      trades.updateOffer(a, trade.id, [{ cardId: COMMON, quantity: -2 }]),
    ).rejects.toMatchObject({ code: 'INVALID_QUANTITY' });
  });

  it('keeps a trade private to its two participants', async () => {
    const [a, b, outsider] = [
      await makeUser('priv1'),
      await makeUser('priv2'),
      await makeUser('nosy'),
    ];
    const trade = await trades.create(a, b);
    await expect(trades.get(outsider, trade.id)).rejects.toMatchObject({
      code: 'TRADE_NOT_FOUND',
      status: 404,
    });
  });

  it('refuses a trade with yourself', async () => {
    const a = await makeUser('solo');
    await expect(trades.create(a, a)).rejects.toMatchObject({ code: 'SELF_TRADE' });
  });
});

describe('confirmation and revisions', () => {
  it('clears both acceptances when either side edits the offer', async () => {
    const [a, b] = [await makeUser('rev1'), await makeUser('rev2')];
    await give(a, COMMON, 2);
    await give(b, EPIC, 1);

    let trade = await stage(
      a,
      b,
      [{ cardId: COMMON, quantity: 1 }],
      [{ cardId: EPIC, quantity: 1 }],
    );
    trade = await trades.accept(a, trade.id, trade.revision);
    expect(trade.offers.find((o) => o.userId === a)!.accepted).toBe(true);

    // B sweetens — or worsens — their side. A's agreement no longer applies.
    const revisionBefore = trade.revision;
    trade = await trades.updateOffer(b, trade.id, []);
    expect(trade.revision).toBe(revisionBefore + 1);
    expect(trade.offers.every((o) => !o.accepted)).toBe(true);
    expect(trade.status).toBe('OPEN');
  });

  it('refuses an acceptance naming a revision that has moved on', async () => {
    const [a, b] = [await makeUser('stale1'), await makeUser('stale2')];
    await give(a, COMMON, 2);

    let trade = await stage(a, b, [{ cardId: COMMON, quantity: 1 }]);
    const staleRevision = trade.revision;
    trade = await trades.updateOffer(a, trade.id, [{ cardId: COMMON, quantity: 2 }]);

    await expect(trades.accept(b, trade.id, staleRevision)).rejects.toMatchObject({
      code: 'TRADE_REVISION_CHANGED',
    });
  });

  it('does not execute when the two acceptances are for different revisions', async () => {
    const [a, b] = [await makeUser('mismatch1'), await makeUser('mismatch2')];
    await give(a, COMMON, 2);

    let trade = await stage(a, b, [{ cardId: COMMON, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    // The offer changes, which wipes A's acceptance; B then accepts alone.
    trade = await trades.updateOffer(a, trade.id, [{ cardId: COMMON, quantity: 2 }]);
    trade = await trades.accept(b, trade.id, trade.revision);

    expect(trade.status).toBe('OPEN');
    expect(await owned(b, COMMON)).toBe(0);
  });

  it('lets a player withdraw an acceptance', async () => {
    const [a, b] = [await makeUser('undo1'), await makeUser('undo2')];
    await give(a, COMMON, 1);

    let trade = await stage(a, b, [{ cardId: COMMON, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.unaccept(a, trade.id);
    expect(trade.offers.find((o) => o.userId === a)!.accepted).toBe(false);

    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('OPEN');
  });
});

describe('policy is re-checked at execution', () => {
  it('refuses a trade whose expansion stopped being tradeable while it sat open', async () => {
    const [a, b] = [await makeUser('pol1'), await makeUser('pol2')];
    await give(a, EPIC, 1);

    let trade = await stage(a, b, [{ cardId: EPIC, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);

    // The set is withdrawn from trading between the two acceptances.
    await expansions.updateFlags('CHRONICLE', { tradeable: false });

    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('FAILED');
    expect(trade.failureCode).toBe('CARD_NOT_TRADEABLE');
    // Nothing moved.
    expect(await owned(a, EPIC)).toBe(1);
    expect(await owned(b, EPIC)).toBe(0);
  });

  it('refuses a trade whose expansion became unreleased', async () => {
    const [a, b] = [await makeUser('unrel1'), await makeUser('unrel2')];
    await give(a, EPIC, 1);

    let trade = await stage(a, b, [{ cardId: EPIC, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    await expansions.updateFlags('CHRONICLE', { released: false });

    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('FAILED');
    expect(await owned(a, EPIC)).toBe(1);
  });

  it('refuses to add a non-tradeable card to an offer in the first place', async () => {
    const [a, b] = [await makeUser('add1'), await makeUser('add2')];
    await expansions.updateFlags('CORE', { tradeable: false });
    const trade = await trades.create(a, b);
    await expect(
      trades.updateOffer(a, trade.id, [{ cardId: COMMON, quantity: 1 }]),
    ).rejects.toMatchObject({ code: 'CARD_NOT_TRADEABLE' });
  });

  it('does not let Standard status affect tradeability', async () => {
    const [a, b] = [await makeUser('wild1'), await makeUser('wild2')];
    await give(a, EPIC, 1);
    // Rotated out of Standard, still tradeable: independent policies.
    await expansions.updateFlags('CHRONICLE', { standard: false, tradeable: true });

    let trade = await stage(a, b, [{ cardId: EPIC, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('ACCEPTED');
  });

  it('does not let pack availability or craftability affect tradeability', async () => {
    const [a, b] = [await makeUser('indep1'), await makeUser('indep2')];
    await give(a, EPIC, 1);
    await expansions.updateFlags('CHRONICLE', {
      availableInPacks: false,
      craftable: false,
      tradeable: true,
    });

    let trade = await stage(a, b, [{ cardId: EPIC, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('ACCEPTED');
  });

  it('leaves a completed trade valid after the policy later changes', async () => {
    const [a, b] = [await makeUser('hist1'), await makeUser('hist2')];
    await give(a, EPIC, 1);

    let trade = await stage(a, b, [{ cardId: EPIC, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('ACCEPTED');

    // The set is withdrawn afterwards. History does not un-happen.
    await expansions.updateFlags('CHRONICLE', { tradeable: false });
    const after = await trades.get(a, trade.id);
    expect(after.status).toBe('ACCEPTED');
    expect(await owned(b, EPIC)).toBe(1);
  });
});

describe('ownership is re-checked at execution', () => {
  it('refuses when a promised card was disenchanted first', async () => {
    const [a, b] = [await makeUser('gone1'), await makeUser('gone2')];
    await give(a, LEGENDARY, 1);

    let trade = await stage(a, b, [{ cardId: LEGENDARY, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);

    // Offered cards are not reserved, so this is allowed to happen.
    await economy.disenchant(a, LEGENDARY, 1);

    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('FAILED');
    expect(trade.failureCode).toBe('INSUFFICIENT_CARD_QUANTITY');
    expect(await owned(b, LEGENDARY)).toBe(0);
  });

  it('lets only one of two trades move the same single copy', async () => {
    const [a, b, c] = [await makeUser('two1'), await makeUser('two2'), await makeUser('two3')];
    await give(a, LEGENDARY, 1);

    const first = await stage(a, b, [{ cardId: LEGENDARY, quantity: 1 }]);
    const second = await stage(a, c, [{ cardId: LEGENDARY, quantity: 1 }]);
    await trades.accept(a, first.id, first.revision);
    await trades.accept(a, second.id, second.revision);

    const results = await Promise.allSettled([
      trades.accept(b, first.id, first.revision),
      trades.accept(c, second.id, second.revision),
    ]);
    const statuses = results.map((r) => (r.status === 'fulfilled' ? r.value.status : 'THREW'));
    expect(statuses.filter((s) => s === 'ACCEPTED').length).toBe(1);

    // The card exists exactly once across all three collections.
    const total =
      (await owned(a, LEGENDARY)) + (await owned(b, LEGENDARY)) + (await owned(c, LEGENDARY));
    expect(total).toBe(1);
  });

  it('is atomic: a failure on the second card moves neither', async () => {
    const [a, b] = [await makeUser('atom1'), await makeUser('atom2')];
    await give(a, COMMON, 2);
    await give(a, EPIC, 1);

    let trade = await stage(a, b, [
      { cardId: COMMON, quantity: 2 },
      { cardId: EPIC, quantity: 1 },
    ]);
    trade = await trades.accept(a, trade.id, trade.revision);
    // The Epic goes away; the Commons are still there.
    await economy.disenchant(a, EPIC, 1);

    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('FAILED');
    // The Commons must not have moved either.
    expect(await owned(a, COMMON)).toBe(2);
    expect(await owned(b, COMMON)).toBe(0);
  });
});

describe('cancellation', () => {
  it('moves nothing and cannot later execute', async () => {
    const [a, b] = [await makeUser('cancel1'), await makeUser('cancel2')];
    await give(a, COMMON, 1);

    let trade = await stage(a, b, [{ cardId: COMMON, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.cancel(b, trade.id);

    expect(trade.status).toBe('CANCELLED');
    expect(await owned(a, COMMON)).toBe(1);
    await expect(trades.accept(b, trade.id, trade.revision)).rejects.toMatchObject({
      code: 'TRADE_NOT_OPEN',
    });
  });
});

describe('trade history', () => {
  it('records who gave what to whom, frozen against later policy changes', async () => {
    const [a, b] = [await makeUser('rec1'), await makeUser('rec2')];
    await give(a, EPIC, 1);
    await give(b, COMMON, 2);

    let trade = await stage(
      a,
      b,
      [{ cardId: EPIC, quantity: 1 }],
      [{ cardId: COMMON, quantity: 2 }],
    );
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);

    const history = await trades.history(a);
    const sent = history.find((row) => row.cardId === EPIC)!;
    expect(sent.fromUserId).toBe(a);
    expect(sent.toUserId).toBe(b);
    expect(sent.quantity).toBe(1);
    expect(sent.tradeId).toBe(trade.id);
    expect(sent.revision).toBe(trade.revision);
    // The policy that permitted it, kept so history never needs re-judging.
    expect((sent.context as { expansionId: string }).expansionId).toBe('CHRONICLE');

    await expansions.updateFlags('CHRONICLE', { tradeable: false });
    const later = await trades.history(a);
    expect(later.find((row) => row.cardId === EPIC)).toBeTruthy();
  });
});

describe('trading feeds back into duplicate protection', () => {
  it('makes a card wanted again once a copy is traded away', async () => {
    const [a, b] = [await makeUser('dp1'), await makeUser('dp2')];
    await expansions.updateFlags('CHRONICLE', { duplicateProtection: true });
    await give(a, EPIC, 2);

    const before = await packs.protectionPreview(a, 'CHRONICLE_PACK');
    expect(before.eligible).not.toContain(EPIC);

    let trade = await stage(a, b, [{ cardId: EPIC, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);
    expect(trade.status).toBe('ACCEPTED');

    const after = await packs.protectionPreview(a, 'CHRONICLE_PACK');
    expect(after.eligible).toContain(EPIC);

    // And the receiving player, now holding one, is likewise still short.
    const recipient = await packs.protectionPreview(b, 'CHRONICLE_PACK');
    expect(recipient.eligible).toContain(EPIC);
  });

  it('stops preferring a card once a trade completes the playset', async () => {
    const [a, b] = [await makeUser('dp3'), await makeUser('dp4')];
    await expansions.updateFlags('CHRONICLE', { duplicateProtection: true });
    await give(a, EPIC, 1);
    await give(b, EPIC, 1);

    expect((await packs.protectionPreview(b, 'CHRONICLE_PACK')).eligible).toContain(EPIC);

    let trade = await stage(a, b, [{ cardId: EPIC, quantity: 1 }]);
    trade = await trades.accept(a, trade.id, trade.revision);
    trade = await trades.accept(b, trade.id, trade.revision);
    // Asserted, so that a silently failed trade cannot pass this test by
    // leaving the collection untouched for the wrong reason.
    expect(trade.status).toBe('ACCEPTED');

    expect((await packs.protectionPreview(b, 'CHRONICLE_PACK')).eligible).not.toContain(EPIC);
  });
});
