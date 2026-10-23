import type { Rarity } from '@maailma/game-model';
import { RARITIES } from '@maailma/game-model';
import { isBasicRarity } from './economy.js';
import { isKnownExpansion } from './expansions.js';
import { CONTENT } from './content.js';

/**
 * How likely each rarity is in one pack slot.
 *
 * Weights rather than percentages, so adding a rarity later does not mean
 * rebalancing every other number to keep a total of 100.
 */
export type RarityWeights = Readonly<Partial<Record<Rarity, number>>>;

export interface PackSlotRule {
  /** How many slots in the pack use this rule. */
  count: number;
  weights: RarityWeights;
}

export interface PackRarityRules {
  slots: readonly PackSlotRule[];
}

/**
 * A pack belongs to exactly one expansion.
 *
 * Deliberately not a universal pool over every card in the game: a player
 * buying into a set should be opening that set, and a shared pool would make
 * every new expansion dilute every old one. It also gives the expansion
 * policies something concrete to govern — `availableInPacks` is a property of
 * a set, and a pack that spanned sets could not honour it.
 */
export interface PackDefinition {
  id: string;
  name: string;
  expansionId: string;
  cardCount: number;
  rarityRules: PackRarityRules;
}

const packs = CONTENT.packs;

export function validatePackDefinition(definition: PackDefinition): string[] {
  const where = definition?.id || '(unnamed pack)';
  const errors: string[] = [];
  if (!isKnownExpansion(definition?.expansionId)) {
    errors.push(`${where}: unknown expansion "${definition?.expansionId}"`);
  }
  if (!Number.isInteger(definition?.cardCount) || definition.cardCount <= 0) {
    errors.push(`${where}: cardCount must be a positive integer`);
  }
  const slots = definition?.rarityRules?.slots ?? [];
  const slotTotal = slots.reduce((total, slot) => total + slot.count, 0);
  if (slotTotal !== definition?.cardCount) {
    errors.push(
      `${where}: slot rules cover ${slotTotal} cards but the pack holds ${definition?.cardCount}`,
    );
  }
  for (const [index, slot] of slots.entries()) {
    const weights = Object.entries(slot.weights) as Array<[Rarity, number]>;
    if (weights.length === 0) errors.push(`${where}: slot ${index} has no rarity weights`);
    for (const [rarity, weight] of weights) {
      if (!RARITIES.includes(rarity))
        errors.push(`${where}: slot ${index} names unknown rarity ${rarity}`);
      else if (isBasicRarity(rarity))
        errors.push(`${where}: slot ${index} names ${rarity}, and Basic cards never come in packs`);
      if (!Number.isFinite(weight) || weight <= 0) {
        errors.push(`${where}: slot ${index} weight for ${rarity} must be positive`);
      }
    }
  }
  return errors;
}

const packErrors = packs.flatMap(validatePackDefinition);
if (packErrors.length > 0) {
  throw new Error(`Invalid pack definitions: ${packErrors.join('; ')}`);
}

export const PACK_DEFINITIONS: Readonly<Record<string, PackDefinition>> = Object.freeze(
  Object.fromEntries(packs.map((pack) => [pack.id, Object.freeze(pack)])),
);

export function getPackDefinition(id: string): PackDefinition {
  const definition = PACK_DEFINITIONS[id];
  if (!definition) throw new Error(`Unknown pack definition: ${id}`);
  return definition;
}

/** The packs belonging to one expansion. */
export function packsForExpansion(expansionId: string): PackDefinition[] {
  return Object.values(PACK_DEFINITIONS).filter((pack) => pack.expansionId === expansionId);
}
