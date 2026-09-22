import { describe, expect, it } from 'vitest';
import {
  CARD_DEFINITIONS,
  EXPANSION_DEFINITIONS,
  canCraftExpansion,
  canDisenchantExpansion,
  canOpenExpansionPacks,
  canTradeExpansion,
  getExpansionDefinition,
  hasDuplicateProtection,
  isExpansionReleased,
  isExpansionStandardLegal,
  isExpansionWildLegal,
  isKnownExpansion,
  validateExpansionPolicy,
} from '@maailma/card-definitions';
import type { ExpansionPolicy } from '@maailma/game-model';
import { EXPANSION_POLICY_FLAGS } from '@maailma/game-model';

/** A policy with everything off, so each test turns on only what it is about. */
function policy(overrides: Partial<ExpansionPolicy> = {}): { policy: ExpansionPolicy } {
  return {
    policy: {
      released: false,
      tradeable: false,
      duplicateProtection: false,
      craftable: false,
      disenchantable: false,
      availableInPacks: false,
      standard: false,
      ...overrides,
    },
  };
}

describe('expansion definitions', () => {
  it('gives every collectible card an expansion that exists', () => {
    const cards = Object.values(CARD_DEFINITIONS);
    expect(cards.length).toBeGreaterThan(0);
    for (const card of cards) {
      expect(card.expansionId, `${card.id} has no expansion`).toBeTypeOf('string');
      expect(isKnownExpansion(card.expansionId), `${card.id} -> ${card.expansionId}`).toBe(true);
    }
  });

  it('states every policy flag outright on every shipped expansion', () => {
    for (const expansion of Object.values(EXPANSION_DEFINITIONS)) {
      expect(validateExpansionPolicy(expansion.policy, expansion.id)).toEqual([]);
      for (const flag of EXPANSION_POLICY_FLAGS) {
        expect(expansion.policy[flag], `${expansion.id}.${flag}`).toBeTypeOf('boolean');
      }
    }
  });

  it('rejects a policy with a flag left unstated', () => {
    const partial = { released: true, tradeable: true };
    const errors = validateExpansionPolicy(partial, 'PARTIAL');
    expect(errors.length).toBe(EXPANSION_POLICY_FLAGS.length - 2);
    expect(errors.join(' ')).toContain('craftable');
  });

  it('refuses an unknown expansion by name', () => {
    expect(() => getExpansionDefinition('NOT_A_SET')).toThrow(/Unknown expansion/);
    expect(isKnownExpansion('NOT_A_SET')).toBe(false);
  });

  it('ships an unreleased expansion so future content can exist before launch', () => {
    const unreleased = Object.values(EXPANSION_DEFINITIONS).filter((e) => !e.policy.released);
    expect(unreleased.length).toBeGreaterThan(0);
  });
});

describe('released gates every other policy', () => {
  const everythingOn = policy({
    released: false,
    tradeable: true,
    duplicateProtection: true,
    craftable: true,
    disenchantable: true,
    availableInPacks: true,
    standard: true,
  });

  it('withholds every player-facing capability while unreleased', () => {
    expect(isExpansionReleased(everythingOn)).toBe(false);
    expect(canTradeExpansion(everythingOn)).toBe(false);
    expect(canCraftExpansion(everythingOn)).toBe(false);
    expect(canDisenchantExpansion(everythingOn)).toBe(false);
    expect(canOpenExpansionPacks(everythingOn)).toBe(false);
    expect(hasDuplicateProtection(everythingOn)).toBe(false);
  });

  it('keeps an unreleased expansion out of both formats', () => {
    expect(isExpansionStandardLegal(everythingOn)).toBe(false);
    expect(isExpansionWildLegal(everythingOn)).toBe(false);
  });

  it('grants each capability the moment release is flipped on', () => {
    const released = policy({ ...everythingOn.policy, released: true });
    expect(canTradeExpansion(released)).toBe(true);
    expect(canCraftExpansion(released)).toBe(true);
    expect(canDisenchantExpansion(released)).toBe(true);
    expect(canOpenExpansionPacks(released)).toBe(true);
    expect(hasDuplicateProtection(released)).toBe(true);
    expect(isExpansionStandardLegal(released)).toBe(true);
    expect(isExpansionWildLegal(released)).toBe(true);
  });
});

describe('policy flags are independent', () => {
  it('reads each flag only through its own helper', () => {
    const cases: Array<[keyof ExpansionPolicy, (e: { policy: ExpansionPolicy }) => boolean]> = [
      ['tradeable', canTradeExpansion],
      ['craftable', canCraftExpansion],
      ['disenchantable', canDisenchantExpansion],
      ['availableInPacks', canOpenExpansionPacks],
      ['duplicateProtection', hasDuplicateProtection],
      ['standard', isExpansionStandardLegal],
    ];
    for (const [flag, helper] of cases) {
      // Only this flag on: the helper says yes.
      expect(helper(policy({ released: true, [flag]: true })), `${flag} alone`).toBe(true);
      // Every other flag on, this one off: the helper says no.
      const others: Partial<ExpansionPolicy> = { released: true };
      for (const other of EXPANSION_POLICY_FLAGS) others[other] = other !== flag;
      expect(helper(policy(others)), `${flag} withheld`).toBe(false);
    }
  });

  it('allows a tradeable but non-craftable expansion', () => {
    const set = policy({ released: true, tradeable: true, craftable: false });
    expect(canTradeExpansion(set)).toBe(true);
    expect(canCraftExpansion(set)).toBe(false);
  });

  it('allows a craftable expansion that has left packs behind', () => {
    const set = policy({ released: true, craftable: true, availableInPacks: false });
    expect(canCraftExpansion(set)).toBe(true);
    expect(canOpenExpansionPacks(set)).toBe(false);
  });

  it('allows a Wild-only expansion to stay available in packs', () => {
    const set = policy({ released: true, standard: false, availableInPacks: true });
    expect(isExpansionStandardLegal(set)).toBe(false);
    expect(isExpansionWildLegal(set)).toBe(true);
    expect(canOpenExpansionPacks(set)).toBe(true);
  });

  it('allows duplicate protection alongside trading', () => {
    const set = policy({ released: true, duplicateProtection: true, tradeable: true });
    expect(hasDuplicateProtection(set)).toBe(true);
    expect(canTradeExpansion(set)).toBe(true);
  });

  it('allows crafting without disenchanting, and the reverse', () => {
    const craftOnly = policy({ released: true, craftable: true, disenchantable: false });
    expect(canCraftExpansion(craftOnly)).toBe(true);
    expect(canDisenchantExpansion(craftOnly)).toBe(false);

    const dustOnly = policy({ released: true, craftable: false, disenchantable: true });
    expect(canCraftExpansion(dustOnly)).toBe(false);
    expect(canDisenchantExpansion(dustOnly)).toBe(true);
  });

  it('allows a Standard expansion that cannot be found in packs', () => {
    const set = policy({ released: true, standard: true, availableInPacks: false });
    expect(isExpansionStandardLegal(set)).toBe(true);
    expect(canOpenExpansionPacks(set)).toBe(false);
  });
});

describe('format legality', () => {
  it('requires release and standard for Standard, release alone for Wild', () => {
    const both = policy({ released: true, standard: true });
    expect(isExpansionStandardLegal(both)).toBe(true);
    expect(isExpansionWildLegal(both)).toBe(true);

    const rotated = policy({ released: true, standard: false });
    expect(isExpansionStandardLegal(rotated)).toBe(false);
    expect(isExpansionWildLegal(rotated)).toBe(true);

    const upcoming = policy({ released: false, standard: true });
    expect(isExpansionStandardLegal(upcoming)).toBe(false);
    expect(isExpansionWildLegal(upcoming)).toBe(false);
  });
});
