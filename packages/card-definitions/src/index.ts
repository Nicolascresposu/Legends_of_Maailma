import type {
  CardDefinition,
  HeroDefinition,
  ScenarioDefinition,
  WeaponDefinition,
} from '@maailma/game-model';
import { WEAPON_RANGES } from '@maailma/game-model';
import { CLASS_DEFINITIONS, cardFitsClass, isKnownClass } from './classes.js';
import { validateCardDescription } from './descriptions.js';
import { isKnownExpansion } from './expansions.js';
import { CONTENT } from './content.js';

export * from './classes.js';
export * from './descriptions.js';
export * from './expansions.js';
export * from './economy.js';
export * from './packs.js';

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

export const CARD_DEFINITIONS: Readonly<Record<string, CardDefinition>> = Object.freeze(
  Object.fromEntries(cards.map((card) => [card.id, Object.freeze(card)])),
);

export const HERO_DEFINITIONS: Readonly<Record<string, HeroDefinition>> = Object.freeze({
  healer: {
    id: 'healer',
    name: 'The Mender',
    classId: 'PRIEST',
    health: 30,
    power: {
      id: 'mend',
      name: 'Mend',
      cost: 2,
      text: 'Restore 2 Health to your Hero.',
      targetMode: 'NONE',
      effect: { type: 'HEAL', amount: 2, target: 'OWNER_HERO' },
    },
  },
  striker: {
    id: 'striker',
    name: 'The Striker',
    classId: 'WIZARD',
    health: 30,
    power: {
      id: 'strike',
      name: 'Strike',
      cost: 2,
      text: 'Deal 1 damage to the enemy Hero.',
      targetMode: 'NONE',
      effect: { type: 'DEAL_DAMAGE', amount: 1, target: 'ENEMY_HERO' },
    },
  },
});

const standardSide = (heroDefinitionId: string) => ({
  heroDefinitionId,
  heroHealth: 30,
  startingTaika: 1,
  maxTaika: 10,
  controller: 'HUMAN' as const,
});

export const SCENARIO_DEFINITIONS: Readonly<Record<string, ScenarioDefinition>> = Object.freeze({
  STANDARD_PVP: {
    id: 'STANDARD_PVP',
    name: 'Standard Duel',
    battlefield: { width: 3 },
    sideA: standardSide('healer'),
    sideB: standardSide('striker'),
    victoryConditions: [{ type: 'ENEMY_HERO_DEFEATED' }],
  },
  BANDIT_AMBUSH: {
    id: 'BANDIT_AMBUSH',
    name: 'Bandit Ambush',
    battlefield: { width: 2 },
    sideA: standardSide('healer'),
    sideB: {
      heroDefinitionId: 'striker',
      heroHealth: 20,
      startingTaika: 1,
      maxTaika: 10,
      controller: 'AI',
      startingCreatures: [
        { definitionId: 'human_mercenary', position: { row: 'FRONT', column: 0 } },
      ],
      // The ambusher opens armed, which is the PvE case Weapons must support.
      startingWeapon: 'rusty_dagger',
    },
    victoryConditions: [{ type: 'ENEMY_HERO_DEFEATED' }],
  },
});

/** Two of each, which is how every starter deck is built. */
const pairs = (...cardIds: string[]): string[] => cardIds.flatMap((cardId) => [cardId, cardId]);

/** The neutral core every class's starter deck shares: 26 cards. */
const STARTER_NEUTRALS = pairs(
  'wolf',
  'brown_bear',
  'hawk',
  'giant_rat',
  'hunting_spider',
  'elf_archer',
  'dwarf_defender',
  'human_mercenary',
  'maintenance_anima',
  'mercy_4',
  'arcane_battery',
  'iron_sword',
  'hunting_bow',
);

/**
 * One starter deck per class, keyed by class id: the shared neutrals plus
 * that class's own cards.
 *
 * Per class because a single deck cannot serve both: a deck may hold only its
 * own class's cards, so a deck with Firebolt and Healing Potion in it would be
 * legal for no hero at all.
 */
export const STARTER_DECKS: Readonly<Record<string, readonly string[]>> = Object.freeze({
  WIZARD: Object.freeze([...STARTER_NEUTRALS, ...pairs('apprentice_mage', 'firebolt')]),
  PRIEST: Object.freeze([...STARTER_NEUTRALS, ...pairs('field_medic', 'healing_potion')]),
});

/**
 * Every card a new account is given: enough copies to build any class's
 * starter deck, so each is playable from the first login.
 */
export const STARTER_COLLECTION: ReadonlyMap<string, number> = (() => {
  const counts = new Map<string, number>();
  for (const deck of Object.values(STARTER_DECKS)) {
    const inDeck = new Map<string, number>();
    for (const cardId of deck) inDeck.set(cardId, (inDeck.get(cardId) ?? 0) + 1);
    for (const [cardId, copies] of inDeck) {
      counts.set(cardId, Math.max(counts.get(cardId) ?? 0, copies));
    }
  }
  return counts;
})();

// Heroes, classes and starter decks refer to one another by id, so a typo in
// any of them is caught here rather than when someone picks that hero.
const classErrors = [
  ...Object.values(HERO_DEFINITIONS)
    .filter((hero) => !isKnownClass(hero.classId))
    .map((hero) => `hero ${hero.id}: unknown class "${hero.classId}"`),
  ...Object.keys(CLASS_DEFINITIONS)
    .filter((classId) => !STARTER_DECKS[classId])
    .map((classId) => `class ${classId}: has no starter deck`),
  ...Object.entries(STARTER_DECKS).flatMap(([classId, deck]) =>
    deck
      .filter((cardId) => {
        const card = CARD_DEFINITIONS[cardId];
        return !card || !cardFitsClass(card, classId);
      })
      .map((cardId) => `${classId} starter deck: ${cardId} cannot be played in this class`),
  ),
];
if (classErrors.length > 0) {
  throw new Error(`Invalid class definitions: ${classErrors.join('; ')}`);
}

/** The class a hero belongs to, and so the class of any deck built for it. */
export function heroClassId(heroId: string): string {
  return getHeroDefinition(heroId).classId;
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

export function getHeroDefinition(id: string): HeroDefinition {
  const definition = HERO_DEFINITIONS[id];
  if (!definition) throw new Error(`Unknown hero definition: ${id}`);
  return definition;
}

export function getScenarioDefinition(id: string): ScenarioDefinition {
  const definition = SCENARIO_DEFINITIONS[id];
  if (!definition) throw new Error(`Unknown scenario definition: ${id}`);
  return definition;
}
