import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { PrismaClient } from '@prisma/client';
import {
  CLASS_DEFINITIONS,
  HERO_DEFINITIONS,
  STARTER_COLLECTION,
  STARTER_DECKS,
  craftCost,
  disenchantValue,
  getCardDefinition,
  getPackDefinition,
  heroClassId,
  starterDeckFor,
  validatePackDefinition,
} from '@maailma/card-definitions';
import { generatePack, packPool, validateDeck } from '@maailma/game-engine';
import { SeededRng } from '@maailma/rng';
import { hashPassword } from '../apps/server/src/auth/passwords.js';
import { MatchManager } from '../apps/server/src/match-manager.js';
import { CollectionService } from '../apps/server/src/services/collection-service.js';
import { EconomyService } from '../apps/server/src/services/economy-service.js';
import { TradeService } from '../apps/server/src/services/trade-service.js';
import { ExpansionService } from '../apps/server/src/services/expansion-service.js';

const BASIC_CARD = 'brown_bear';

describe('classes', () => {
  it('gives every hero a known class', () => {
    expect(heroClassId('striker')).toBe('WIZARD');
    expect(heroClassId('healer')).toBe('PRIEST');
    for (const hero of Object.values(HERO_DEFINITIONS)) {
      expect(CLASS_DEFINITIONS[hero.classId], hero.id).toBeDefined();
    }
  });

  it('splits the first class cards between Wizard and Priest', () => {
    expect(getCardDefinition('firebolt').classId).toBe('WIZARD');
    expect(getCardDefinition('apprentice_mage').classId).toBe('WIZARD');
    expect(getCardDefinition('healing_potion').classId).toBe('PRIEST');
    expect(getCardDefinition('field_medic').classId).toBe('PRIEST');
    // Everything else is neutral.
    expect(getCardDefinition('wolf').classId).toBeUndefined();
  });

  it('accepts neutral and own-class cards in a deck of that class', () => {
    for (const [classId, deck] of Object.entries(STARTER_DECKS)) {
      expect(validateDeck(deck, { classId }), classId).toEqual({ valid: true, errors: [] });
    }
  });

  it('names each card of another class that a deck holds', () => {
    const priest = starterDeckFor('healer');
    // Swap the Priest's Healing Potions for the Wizard's Firebolts.
    const mixed = [...priest.filter((id) => id !== 'healing_potion'), 'firebolt', 'firebolt'];
    const result = validateDeck(mixed, { classId: 'PRIEST' });
    expect(result.valid).toBe(false);
    expect(result.errors).toEqual([
      'Firebolt is a Wizard card and cannot be played in a Priest deck',
    ]);
  });

  it('does not judge class when no class is given', () => {
    const mixed = [
      ...starterDeckFor('healer').filter((id) => id !== 'healing_potion'),
      'firebolt',
      'firebolt',
    ];
    expect(validateDeck(mixed).valid).toBe(true);
  });

  it('grants enough of every card for each class starter deck', () => {
    for (const deck of Object.values(STARTER_DECKS)) {
      const counts = new Map<string, number>();
      for (const cardId of deck) counts.set(cardId, (counts.get(cardId) ?? 0) + 1);
      for (const [cardId, copies] of counts) {
        expect(STARTER_COLLECTION.get(cardId) ?? 0, cardId).toBeGreaterThanOrEqual(copies);
      }
    }
  });
});

describe('match creation by class', () => {
  it("refuses a deck holding another class's card", () => {
    const manager = new MatchManager();
    const priest = starterDeckFor('healer');
    const mixed = [...priest.filter((id) => id !== 'healing_potion'), 'firebolt', 'firebolt'];
    expect(() =>
      manager.create({
        scenarioId: 'STANDARD_PVP',
        players: [
          { playerId: 'a', heroDefinitionId: 'healer', deck: mixed },
          { playerId: 'b', heroDefinitionId: 'striker', deck: starterDeckFor('striker') },
        ],
      }),
    ).toThrow('Firebolt is a Wizard card and cannot be played in a Priest deck');
  });

  it("judges a side without a chosen hero as the scenario's hero", () => {
    const manager = new MatchManager();
    // Side B of the Standard Duel is The Striker, a Wizard.
    expect(() =>
      manager.create({
        scenarioId: 'STANDARD_PVP',
        players: [
          { playerId: 'a', deck: starterDeckFor('healer') },
          { playerId: 'b', deck: starterDeckFor('healer') },
        ],
      }),
    ).toThrow('cannot be played in a Wizard deck');
  });

  it('refuses a hero switch to a class that cannot play the deck', () => {
    const manager = new MatchManager();
    const engine = manager.create({
      scenarioId: 'STANDARD_PVP',
      players: [
        { playerId: 'a', heroDefinitionId: 'healer' },
        { playerId: 'b', heroDefinitionId: 'striker' },
      ],
    });
    const matchId = engine.state.matchId;
    // A's Priest starter deck holds Priest cards, which a Wizard may not play.
    expect(() => manager.selectHero(matchId, 'a', 'striker')).toThrow(
      'The Striker cannot play this deck',
    );
    expect(engine.state.sides.a!.hero.definitionId).toBe('healer');
    // Re-selecting a hero of the same class is still fine.
    expect(() => manager.selectHero(matchId, 'a', 'healer')).not.toThrow();
  });

  it('allows a hero switch across classes when the deck is all neutral', () => {
    const manager = new MatchManager();
    const neutral = [
      ...starterDeckFor('healer').filter(
        (id) => getCardDefinition(id).classId === undefined && id !== 'wolf',
      ),
    ];
    // 26 neutral cards less the two Wolves, topped up with neutral spares.
    const deck = [
      ...neutral,
      'warden_sentinel',
      'warden_sentinel',
      'longbow',
      'longbow',
      'wolf',
      'wolf',
    ];
    expect(deck).toHaveLength(30);
    const engine = manager.create({
      scenarioId: 'STANDARD_PVP',
      players: [
        { playerId: 'a', heroDefinitionId: 'healer', deck },
        { playerId: 'b', heroDefinitionId: 'striker' },
      ],
    });
    manager.selectHero(engine.state.matchId, 'a', 'striker');
    expect(engine.state.sides.a!.hero.definitionId).toBe('striker');
  });

  it("gives a side with no deck its hero's class starter deck", () => {
    const manager = new MatchManager();
    const engine = manager.create({
      scenarioId: 'STANDARD_PVP',
      seed: 11,
      players: [
        { playerId: 'a', heroDefinitionId: 'striker' },
        { playerId: 'b', heroDefinitionId: 'healer' },
      ],
    });
    const deckOf = (playerId: 'a' | 'b') =>
      engine.setup.players.find((player) => player.playerId === playerId)!.deck;
    expect([...deckOf('a')].sort()).toEqual(starterDeckFor('striker').sort());
    expect([...deckOf('b')].sort()).toEqual(starterDeckFor('healer').sort());
  });
});

describe('Basic cards outside the economy', () => {
  it('makes the Brown Bear Basic', () => {
    expect(getCardDefinition(BASIC_CARD).rarity).toBe('BASIC');
  });

  it('prices a Basic card at nothing in either direction', () => {
    expect(craftCost('BASIC', BASIC_CARD)).toBe(0);
    expect(disenchantValue('BASIC', BASIC_CARD)).toBe(0);
  });

  it('leaves Basic cards out of every pack pool', () => {
    const pack = getPackDefinition('CORE_PACK');
    expect(packPool(pack).map((card) => card.id)).not.toContain(BASIC_CARD);
    // And so out of every pack actually opened.
    for (let seed = 0; seed < 200; seed += 1) {
      const opened = generatePack(pack, new SeededRng(`basic-${seed}`));
      expect(opened.cards.map((slot) => slot.cardId)).not.toContain(BASIC_CARD);
    }
  });

  it('refuses a pack rule that would roll a Basic slot', () => {
    const pack = getPackDefinition('CORE_PACK');
    const errors = validatePackDefinition({
      ...pack,
      rarityRules: { slots: [{ count: pack.cardCount, weights: { BASIC: 1, COMMON: 9 } }] },
    });
    expect(errors.join(' ')).toContain('Basic cards never come in packs');
  });

  it('keeps the usual copy limit for a Basic card', () => {
    const deck = starterDeckFor('healer');
    expect(deck.filter((id) => id === BASIC_CARD)).toHaveLength(2);
    expect(validateDeck(deck).valid).toBe(true);
  });
});

/**
 * The same rule where it is enforced, against a real database: the server must
 * refuse, not merely have the client grey out a button.
 */
describe('Basic cards in the live economy', () => {
  const prisma = new PrismaClient();
  const expansions = new ExpansionService(prisma);
  const economy = new EconomyService(prisma, expansions);
  const collections = new CollectionService(prisma, expansions);
  const suffix = `cb${Date.now()}${Math.floor(Math.random() * 1000)}`;
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

  beforeEach(async () => {
    await prisma.expansionPolicyOverride.deleteMany({});
  });

  afterAll(async () => {
    if (created.length > 0) await prisma.user.deleteMany({ where: { id: { in: created } } });
    await prisma.$disconnect();
  });

  it('refuses to craft a Basic card, however many Fragments are on hand', async () => {
    const user = await makeUser('bcraft');
    await economy.grantFragments(user, 1000);
    await expect(economy.craft(user, BASIC_CARD, 1)).rejects.toMatchObject({
      code: 'BASIC_CARD',
      message: 'Brown Bear is a Basic card and cannot be crafted',
    });
    expect(await economy.balance(user)).toBe(1000);
  });

  it('refuses to disenchant a Basic card the player owns', async () => {
    const user = await makeUser('bdust');
    await collections.grantStarter(user);
    await expect(economy.disenchant(user, BASIC_CARD, 1)).rejects.toMatchObject({
      code: 'BASIC_CARD',
      message: 'Brown Bear is a Basic card and cannot be disenchanted',
    });
    const owned = await collections.ownedCounts(user);
    expect(owned.get(BASIC_CARD)).toBe(2);
  });

  it('lists a Basic card as neither craftable nor disenchantable', async () => {
    const user = await makeUser('blist');
    const cards = await collections.browse(user);
    const bear = cards.find((card) => card.cardId === BASIC_CARD)!;
    expect(bear).toMatchObject({
      rarity: 'BASIC',
      classId: null,
      craftable: false,
      disenchantable: false,
    });
    // An ordinary card from the same expansion still is both.
    const wolf = cards.find((card) => card.cardId === 'wolf')!;
    expect(wolf).toMatchObject({ craftable: true, disenchantable: true });
    expect(cards.find((card) => card.cardId === 'firebolt')!.classId).toBe('WIZARD');
  });

  it('skips spare Basic copies when disenchanting extras', async () => {
    const user = await makeUser('bextra');
    await prisma.collectionEntry.create({
      data: { userId: user, cardId: BASIC_CARD, quantity: 3 },
    });
    const plan = await economy.planDisenchantExtras(user);
    expect(plan.extras.map((entry) => entry.cardId)).not.toContain(BASIC_CARD);
    expect(plan.skipped).toContainEqual({
      cardId: BASIC_CARD,
      extra: 1,
      reason: 'BASIC_CARD',
    });
  });

  it('refuses a Basic card in a trade offer', async () => {
    const trades = new TradeService(prisma, expansions);
    const a = await makeUser('btradea');
    const b = await makeUser('btradeb');
    await collections.grantStarter(a);
    const trade = await trades.create(a, b);
    await expect(
      trades.updateOffer(a, trade.id, [{ cardId: BASIC_CARD, quantity: 1 }]),
    ).rejects.toMatchObject({
      code: 'BASIC_CARD',
      message: 'Brown Bear is a Basic card and cannot be traded',
    });
    // An ordinary card from the same expansion can still be offered.
    const offered = await trades.updateOffer(a, trade.id, [{ cardId: 'wolf', quantity: 1 }]);
    expect(offered.revision).toBeGreaterThan(trade.revision);
    const listed = await collections.browse(a);
    expect(listed.find((card) => card.cardId === BASIC_CARD)!.tradeable).toBe(false);
    expect(listed.find((card) => card.cardId === 'wolf')!.tradeable).toBe(true);
  });

  it("reports another class's cards in a deck's readiness", async () => {
    const user = await makeUser('bclass');
    await collections.grantStarter(user);
    const mixed = [
      ...starterDeckFor('healer').filter((id) => id !== 'healing_potion'),
      'firebolt',
      'firebolt',
    ];
    const readiness = await collections.assessForUser(user, mixed, 'STANDARD', 'healer');
    expect(readiness.playable).toBe(false);
    expect(readiness.classId).toBe('PRIEST');
    expect(readiness.ruleErrors).toContain(
      'Firebolt is a Wizard card and cannot be played in a Priest deck',
    );
    // The same cards, judged as a Wizard deck, trip over the Priest's cards instead.
    const asWizard = await collections.assessForUser(user, mixed, 'STANDARD', 'striker');
    expect(asWizard.ruleErrors.join(' ')).toContain('Field Medic is a Priest card');
  });
});
