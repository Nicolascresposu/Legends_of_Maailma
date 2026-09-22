import type { Rarity } from '@maailma/game-model';
import { RARITIES } from '@maailma/game-model';

/**
 * What a card costs to make and what it is worth to break down.
 *
 * One table, in one place. These numbers decide what a collection is worth and
 * what a nerf owes a player, so a second copy of them somewhere in a service or
 * a UI would eventually disagree with this one and quietly cheat somebody.
 *
 * The spread between the two directions is deliberate and uneven — roughly a
 * fifth returned on a Common, a third on a Legendary — so that breaking down
 * spares is a real cost at the low end and a real option at the top.
 */
export interface RarityEconomy {
  craft: number;
  disenchant: number;
}

export const CRAFTING_VALUES: Readonly<Record<Rarity, RarityEconomy>> = Object.freeze({
  COMMON: Object.freeze({ craft: 5, disenchant: 1 }),
  RARE: Object.freeze({ craft: 20, disenchant: 5 }),
  EPIC: Object.freeze({ craft: 100, disenchant: 20 }),
  LEGENDARY: Object.freeze({ craft: 300, disenchant: 100 }),
});

/**
 * A temporary revaluation of one card.
 *
 * Exists so that a nerfed card can be refunded at what it cost rather than at
 * what a card of its rarity is normally worth. Nothing schedules these yet;
 * the shape is here so that adding one later is a row and a lookup rather than
 * a redesign of every call site that prices a disenchant.
 */
export interface CardEconomyOverride {
  cardId: string;
  disenchantValue?: number;
  craftCost?: number;
  /** When the override lapses. Absent means it stands until removed. */
  expiresAt?: Date;
}

/** Overrides in force at a given moment, keyed by card id. */
export type EconomyOverrides = ReadonlyMap<string, CardEconomyOverride>;

function activeOverride(
  overrides: EconomyOverrides | undefined,
  cardId: string,
  now: Date,
): CardEconomyOverride | undefined {
  const override = overrides?.get(cardId);
  if (!override) return undefined;
  if (override.expiresAt && override.expiresAt.getTime() <= now.getTime()) return undefined;
  return override;
}

export function craftCost(
  rarity: Rarity,
  cardId?: string,
  overrides?: EconomyOverrides,
  now: Date = new Date(),
): number {
  const override = cardId ? activeOverride(overrides, cardId, now) : undefined;
  return override?.craftCost ?? CRAFTING_VALUES[rarity].craft;
}

export function disenchantValue(
  rarity: Rarity,
  cardId?: string,
  overrides?: EconomyOverrides,
  now: Date = new Date(),
): number {
  const override = cardId ? activeOverride(overrides, cardId, now) : undefined;
  return override?.disenchantValue ?? CRAFTING_VALUES[rarity].disenchant;
}

// Prices are paid in whole Fragments and compared for equality against a
// balance, so a fractional or negative one would be a slow-burning accounting
// bug. Caught at import instead.
const valueErrors = RARITIES.flatMap((rarity) => {
  const values = CRAFTING_VALUES[rarity];
  const errors: string[] = [];
  if (!Number.isInteger(values.craft) || values.craft <= 0) {
    errors.push(`${rarity}: craft cost must be a positive integer`);
  }
  if (!Number.isInteger(values.disenchant) || values.disenchant <= 0) {
    errors.push(`${rarity}: disenchant value must be a positive integer`);
  }
  if (values.disenchant > values.craft) {
    errors.push(`${rarity}: disenchanting must not return more than crafting costs`);
  }
  return errors;
});
if (valueErrors.length > 0) {
  throw new Error(`Invalid crafting values: ${valueErrors.join('; ')}`);
}
