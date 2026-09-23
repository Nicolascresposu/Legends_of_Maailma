import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PrismaClient } from '@prisma/client';
import { CARD_DEFINITIONS, EXPANSION_DEFINITIONS, starterDeckFor } from '@maailma/card-definitions';
import { validateDeck } from '@maailma/game-engine';
import type { DeckFormat, ExpansionDefinition } from '@maailma/game-model';
import { CollectionService } from '../apps/server/src/services/collection-service.js';
import { ExpansionService } from '../apps/server/src/services/expansion-service.js';
import { isCardLegalIn, type LivePolicies } from '../apps/server/src/services/expansion-service.js';

const prisma = new PrismaClient();
const expansions = new ExpansionService(prisma);
const collections = new CollectionService(prisma, expansions);

/** A policy snapshot built by hand, so tests never depend on stored rows. */
function snapshot(overrides: Record<string, Partial<ExpansionDefinition['policy']>>): LivePolicies {
  const entries = Object.values(EXPANSION_DEFINITIONS).map((expansion) => [
    expansion.id,
    { ...expansion, policy: { ...expansion.policy, ...(overrides[expansion.id] ?? {}) } },
  ]);
  return Object.fromEntries(entries) as LivePolicies;
}

/** A starter deck, whose cards all belong to released expansions. */
const STARTER_30 = starterDeckFor('healer');

function ownAll(cardIds: readonly string[]): Map<string, number> {
  const owned = new Map<string, number>();
  for (const cardId of cardIds) owned.set(cardId, (owned.get(cardId) ?? 0) + 1);
  return owned;
}

afterAll(async () => {
  await prisma.$disconnect();
});

describe('format legality per card', () => {
  const coreCard = Object.values(CARD_DEFINITIONS).find((c) => c.expansionId === 'CORE')!;
  const chronicleCard = Object.values(CARD_DEFINITIONS).find((c) => c.expansionId === 'CHRONICLE')!;

  it('admits a released Standard expansion into both formats', () => {
    const policies = snapshot({ CORE: { released: true, standard: true } });
    expect(isCardLegalIn(policies, coreCard.id, 'STANDARD')).toBe(true);
    expect(isCardLegalIn(policies, coreCard.id, 'WILD')).toBe(true);
  });

  it('keeps a rotated expansion in Wild only', () => {
    const policies = snapshot({ CHRONICLE: { released: true, standard: false } });
    expect(isCardLegalIn(policies, chronicleCard.id, 'STANDARD')).toBe(false);
    expect(isCardLegalIn(policies, chronicleCard.id, 'WILD')).toBe(true);
  });

  it('keeps an unreleased expansion out of both formats even when marked Standard', () => {
    const policies = snapshot({ CORE: { released: false, standard: true } });
    expect(isCardLegalIn(policies, coreCard.id, 'STANDARD')).toBe(false);
    expect(isCardLegalIn(policies, coreCard.id, 'WILD')).toBe(false);
  });

  it('reports an unknown card as legal in nothing', () => {
    const policies = snapshot({});
    expect(isCardLegalIn(policies, 'no_such_card', 'WILD')).toBe(false);
  });
});

describe('deck validation by format', () => {
  it('passes a full deck of released Standard cards', () => {
    const policies = snapshot({});
    const result = validateDeck(STARTER_30, {
      format: 'STANDARD',
      isLegalInFormat: (cardId, format) => isCardLegalIn(policies, cardId, format),
    });
    expect(result.errors).toEqual([]);
    expect(result.valid).toBe(true);
  });

  it('names each rotated card rather than failing the deck anonymously', () => {
    const policies = snapshot({ CHRONICLE: { released: true, standard: false } });
    const chronicleIds = new Set(
      Object.values(CARD_DEFINITIONS)
        .filter((card) => card.expansionId === 'CHRONICLE')
        .map((card) => card.id),
    );
    const rotatedInDeck = [...new Set(STARTER_30.filter((id) => chronicleIds.has(id)))];
    expect(rotatedInDeck.length).toBeGreaterThan(0);

    const result = validateDeck(STARTER_30, {
      format: 'STANDARD',
      isLegalInFormat: (cardId, format) => isCardLegalIn(policies, cardId, format),
    });
    expect(result.valid).toBe(false);
    for (const cardId of rotatedInDeck) {
      const name = CARD_DEFINITIONS[cardId]!.name;
      expect(result.errors.some((e) => e.includes(name))).toBe(true);
    }
  });

  it('accepts that same deck in Wild', () => {
    const policies = snapshot({ CHRONICLE: { released: true, standard: false } });
    const result = validateDeck(STARTER_30, {
      format: 'WILD',
      isLegalInFormat: (cardId, format) => isCardLegalIn(policies, cardId, format),
    });
    expect(result.valid).toBe(true);
  });

  it('skips format checks entirely when no legality source is supplied', () => {
    // The engine's own tests and replays have no policy to consult, and must
    // still be able to validate a deck by size and copy limits alone.
    expect(validateDeck(STARTER_30).valid).toBe(true);
    expect(validateDeck(STARTER_30, { format: 'STANDARD' }).valid).toBe(true);
  });

  it('still enforces size and copy limits alongside format', () => {
    const policies = snapshot({});
    const tooSmall = validateDeck(STARTER_30.slice(0, 10), {
      format: 'STANDARD',
      isLegalInFormat: (cardId, format) => isCardLegalIn(policies, cardId, format),
    });
    expect(tooSmall.errors.some((e) => e.includes('exactly 30'))).toBe(true);
  });
});

describe('deck readiness reports rotation without destroying the deck', () => {
  it('marks a rotated deck unplayable in Standard while owning every card', () => {
    const policies = snapshot({ CHRONICLE: { released: true, standard: false } });
    const readiness = collections.assess(STARTER_30, ownAll(STARTER_30), policies, 'STANDARD');

    expect(readiness.playable).toBe(false);
    expect(readiness.format).toBe('STANDARD');
    // Nothing is missing: this is a rotation problem, not an ownership one,
    // and the two are reported apart so the client can say which it is.
    expect(readiness.missing).toEqual([]);
    expect(readiness.illegalInFormat.length).toBeGreaterThan(0);
  });

  it('reports the same deck playable in Wild', () => {
    const policies = snapshot({ CHRONICLE: { released: true, standard: false } });
    const readiness = collections.assess(STARTER_30, ownAll(STARTER_30), policies, 'WILD');
    expect(readiness.playable).toBe(true);
    expect(readiness.illegalInFormat).toEqual([]);
  });

  it('counts the copies of each illegal card, so the UI can say how many', () => {
    const policies = snapshot({ CHRONICLE: { released: true, standard: false } });
    const readiness = collections.assess(STARTER_30, ownAll(STARTER_30), policies, 'STANDARD');
    for (const entry of readiness.illegalInFormat) {
      const actual = STARTER_30.filter((id) => id === entry.cardId).length;
      expect(entry.copies).toBe(actual);
    }
  });

  it('rejects a deck holding an unreleased card even though it is owned', () => {
    // An old dev-built deck may reference a card from an unreleased set.
    // Owning it is not enough: matchmaking must still refuse the deck.
    const policies = snapshot({ CORE: { released: false } });
    const readiness = collections.assess(STARTER_30, ownAll(STARTER_30), policies, 'WILD');
    expect(readiness.playable).toBe(false);
    expect(readiness.illegalInFormat.length).toBeGreaterThan(0);
  });

  it('separates ownership problems from format problems', () => {
    const policies = snapshot({});
    const owned = ownAll(STARTER_30);
    owned.delete(STARTER_30[0]!);
    const readiness = collections.assess(STARTER_30, owned, policies, 'STANDARD');
    expect(readiness.missing.length).toBe(1);
    expect(readiness.illegalInFormat).toEqual([]);
    expect(readiness.playable).toBe(false);
  });
});

describe('live policy overrides', () => {
  const EXPANSION = 'CHRONICLE';
  let original: ExpansionDefinition['policy'];

  beforeAll(async () => {
    original = (await expansions.policy(EXPANSION)).policy;
  });

  afterAll(async () => {
    await expansions.clearOverride(EXPANSION);
  });

  it('starts from the policy shipped with the definitions', async () => {
    await expansions.clearOverride(EXPANSION);
    const live = await expansions.policy(EXPANSION);
    expect(live.policy).toEqual(EXPANSION_DEFINITIONS[EXPANSION]!.policy);
  });

  it('applies a flag change to the very next read, with no migration', async () => {
    await expansions.updateFlags(EXPANSION, { standard: false });
    const rotated = await expansions.policy(EXPANSION);
    expect(rotated.policy.standard).toBe(false);
    // Everything else is left exactly as it was.
    expect(rotated.policy.released).toBe(original.released);
    expect(rotated.policy.tradeable).toBe(original.tradeable);
  });

  it('restores the shipped policy when the override is cleared', async () => {
    await expansions.updateFlags(EXPANSION, { standard: false, tradeable: false });
    await expansions.clearOverride(EXPANSION);
    const live = await expansions.policy(EXPANSION);
    expect(live.policy).toEqual(EXPANSION_DEFINITIONS[EXPANSION]!.policy);
  });

  it('refuses a non-boolean flag', async () => {
    await expect(
      expansions.updateFlags(EXPANSION, { standard: 'yes' as unknown as boolean }),
    ).rejects.toMatchObject({ code: 'INVALID_POLICY' });
  });

  it('refuses an expansion nothing defines', async () => {
    await expect(expansions.updateFlags('NOT_A_SET', { standard: true })).rejects.toMatchObject({
      code: 'UNKNOWN_EXPANSION',
    });
  });

  it('hides unreleased expansions from the player-facing list', async () => {
    const visible = await expansions.visibleExpansions();
    const all = await expansions.allExpansions();
    expect(all.length).toBeGreaterThan(visible.length);
    for (const expansion of visible) expect(expansion.policy.released).toBe(true);
    expect(all.some((e) => !e.policy.released)).toBe(true);
  });
});

describe('deck format round trip', () => {
  it('judges the same list differently per format from one collection', async () => {
    // The point of formats: one collection, two verdicts. Never two copies of
    // a card, one "for Standard" and one "for Wild".
    const policies = snapshot({ CHRONICLE: { released: true, standard: false } });
    const owned = ownAll(STARTER_30);
    const formats: DeckFormat[] = ['STANDARD', 'WILD'];
    const verdicts = formats.map((format) =>
      collections.assess(STARTER_30, owned, policies, format),
    );
    expect(verdicts[0]!.playable).toBe(false);
    expect(verdicts[1]!.playable).toBe(true);
  });
});

describe('matchmaking enforces format, not just ownership', () => {
  const CORE_CARD = Object.values(CARD_DEFINITIONS).find(
    (card) => card.expansionId === 'CORE' && card.collectible,
  )!.id;
  const UNRELEASED_CARD = Object.values(CARD_DEFINITIONS).find(
    (card) => card.expansionId === 'MACHINES_OF_KONA' && card.collectible,
  )!.id;

  const suffix = `m${Date.now()}${Math.floor(Math.random() * 1000)}`;
  const made: string[] = [];

  async function player(tag: string): Promise<string> {
    const user = await prisma.user.create({
      data: {
        email: `${tag}.${suffix}@example.test`,
        displayName: `${tag}_${suffix}`.slice(0, 24),
        passwordHash: 'scrypt$16384$8$1$AAAA$AAAA',
      },
    });
    made.push(user.id);
    return user.id;
  }

  afterAll(async () => {
    await expansions.clearOverride('CORE');
    if (made.length > 0) await prisma.user.deleteMany({ where: { id: { in: made } } });
  });

  it('refuses a deck holding an unreleased card, however it got there', async () => {
    // Dev tooling can put an unreleased card in a deck and even grant it.
    // Owning it is not enough: matchmaking still has to say no, in both
    // formats, or an unreleased set leaks into play through an old deck.
    const user = await player('unrel');
    await prisma.collectionEntry.create({
      data: { userId: user, cardId: UNRELEASED_CARD, quantity: 30 },
    });
    const deck = Array(30).fill(UNRELEASED_CARD);

    await expect(collections.assertPlayable(user, deck, 'STANDARD')).rejects.toMatchObject({
      code: 'DECK_NOT_PLAYABLE',
    });
    await expect(collections.assertPlayable(user, deck, 'WILD')).rejects.toMatchObject({
      code: 'DECK_NOT_PLAYABLE',
    });
  });

  it('refuses a rotated deck in Standard and admits it in Wild', async () => {
    const user = await player('rot');
    await prisma.collectionEntry.create({
      data: { userId: user, cardId: CORE_CARD, quantity: 30 },
    });
    const deck = Array(30).fill(CORE_CARD);

    // Legal while the set is Standard — but a Common may only appear twice, so
    // this deck is refused on copy limits either way. What matters is that the
    // reason changes when the set rotates.
    await expansions.updateFlags('CORE', { standard: false });
    const rotated = await collections.assessForUser(user, deck, 'STANDARD');
    expect(rotated.illegalInFormat.map((e) => e.cardId)).toContain(CORE_CARD);

    const wild = await collections.assessForUser(user, deck, 'WILD');
    expect(wild.illegalInFormat).toEqual([]);
  });
});
