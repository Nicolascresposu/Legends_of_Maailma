import type { CardDefinition, ScenarioDefinition, WeaponDefinition } from '@maailma/game-model';
import { WEAPON_RANGES } from '@maailma/game-model';
import { isKnownClass } from './classes.js';
import { validateCardDescription } from './descriptions.js';
import { isKnownExpansion } from './expansions.js';
import { CONTENT } from './content.js';
import { heroClassId } from './heroes.js';
import { CARD_DEFINITIONS, SCENARIO_DEFINITIONS, STARTER_DECKS } from './registry.js';

export * from './classes.js';
export * from './descriptions.js';
export * from './expansions.js';
export * from './economy.js';
export * from './heroes.js';
export * from './locations.js';
export * from './packs.js';
export * from './registry.js';
export * from './starters.js';
export * from './tags.js';
export {
  OPTIONAL_FILES,
  loadContent,
  parseContentDocuments,
  validateExpansionDocument,
  contentDocuments,
  type ContentCatalog,
  type ExpansionDocument,
} from './content.js';

const cards = CONTENT.cards;

/**
 * Rejects malformed Weapon data at load.
 *
 * Weapons carry rules properties the engine trusts without re-deriving — a
 * missing `range` or a zero-Durability Weapon would misbehave quietly deep in
 * combat rather than loudly here.
 */
export function validateWeaponDefinition(definition: WeaponDefinition): string[] {
  const errors: string[] = [];
  const where = definition.id || '(unnamed weapon)';
  if (definition.type !== 'WEAPON') errors.push(`${where}: type must be WEAPON`);
  if (!Number.isInteger(definition.cost) || definition.cost < 0)
    errors.push(`${where}: cost must be a non-negative integer`);
  if (!Number.isInteger(definition.attack) || definition.attack < 0)
    errors.push(`${where}: attack must be a non-negative integer`);
  if (!Number.isInteger(definition.durability) || definition.durability <= 0)
    errors.push(`${where}: durability must be a positive integer`);
  if (!WEAPON_RANGES.includes(definition.range))
    errors.push(`${where}: range must be one of ${WEAPON_RANGES.join(' or ')}`);
  if (!Array.isArray(definition.tags) || definition.tags.some((tag) => typeof tag !== 'string'))
    errors.push(`${where}: tags must be an array of strings`);
  return errors;
}

/**
 * Rejects a card that names an expansion nothing defines.
 *
 * Every economy and legality question about a card is answered by its
 * expansion's policy, so a card pointing at a missing one has no answer at
 * all — it would be uncraftable, untradeable and format-illegal for reasons
 * no message could explain. Better to fail here than to ship it.
 */
function validateCardExpansion(card: CardDefinition): string[] {
  const where = card.id || '(unnamed card)';
  if (typeof card.expansionId !== 'string' || card.expansionId.trim() === '') {
    return [`${where}: expansionId must be a non-empty string`];
  }
  if (!isKnownExpansion(card.expansionId)) {
    return [`${where}: unknown expansion "${card.expansionId}"`];
  }
  return [];
}

/**
 * Rejects a class card whose class nothing defines.
 *
 * A card naming an unknown class could never be put in any deck — no hero
 * belongs to that class — so it would be dead weight in every collection.
 */
function validateCardClass(card: CardDefinition): string[] {
  if (card.classId === undefined) return [];
  const where = card.id || '(unnamed card)';
  return isKnownClass(card.classId) ? [] : [`${where}: unknown class "${card.classId}"`];
}

// A malformed registry is a programming error, so it fails at import rather
// than midway through somebody's match.
const definitionErrors = [
  ...cards
    .filter((card): card is WeaponDefinition => card.type === 'WEAPON')
    .flatMap(validateWeaponDefinition),
  ...cards.flatMap(validateCardExpansion),
  ...cards.flatMap(validateCardDescription),
  ...cards.flatMap(validateCardClass),
];
if (definitionErrors.length > 0) {
  throw new Error(`Invalid card definitions: ${definitionErrors.join('; ')}`);
}

/** The starter deck for a hero's class. */
export function starterDeckFor(heroId: string): string[] {
  return [...STARTER_DECKS[heroClassId(heroId)]!];
}

export function getCardDefinition(id: string): CardDefinition {
  const definition = CARD_DEFINITIONS[id];
  if (!definition) throw new Error(`Unknown card definition: ${id}`);
  return definition;
}

export function getScenarioDefinition(id: string): ScenarioDefinition {
  const definition = SCENARIO_DEFINITIONS[id];
  if (!definition) throw new Error(`Unknown scenario definition: ${id}`);
  return definition;
}
