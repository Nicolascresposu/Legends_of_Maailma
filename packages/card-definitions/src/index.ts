import type {
  CardDefinition,
  CardSource,
  CreatureDefinition,
  CreatureTag,
  EffectDefinition,
  HeroDefinition,
  Keyword,
  Rarity,
  ScenarioDefinition,
  WeaponDefinition,
  WeaponRange,
  WeaponTag,
} from '@maailma/game-model';
import { WEAPON_RANGES } from '@maailma/game-model';
import { isKnownExpansion } from './expansions.js';

export * from './expansions.js';

const cards: CardDefinition[] = [
  creature('wolf', 'Wolf', 1, 2, 1, ['BEAST']),
  creature('brown_bear', 'Brown Bear', 3, 3, 4, ['BEAST']),
  creature('hawk', 'Hawk', 2, 2, 1, ['BEAST'], ['SWIFT']),
  creature(
    'giant_rat',
    'Giant Rat',
    1,
    1,
    1,
    ['BEAST'],
    ['LAST_BREATH'],
    [{ trigger: 'LAST_BREATH', effect: { type: 'DRAW_CARD', amount: 1 } }],
  ),
  creature('hunting_spider', 'Hunting Spider', 2, 2, 2, ['BEAST'], ['HIDDEN']),
  creature('elf_archer', 'Elf Archer', 3, 2, 2, ['ELF', 'ARCHER'], ['RANGED']),
  creature('dwarf_defender', 'Dwarf Defender', 3, 2, 4, ['DWARF', 'SOLDIER'], ['GUARD']),
  creature('human_mercenary', 'Human Mercenary', 2, 3, 2, ['HUMAN', 'SOLDIER']),
  creature(
    'field_medic',
    'Field Medic',
    3,
    2,
    3,
    ['HUMAN'],
    ['ARRIVAL'],
    [{ trigger: 'ARRIVAL', effect: { type: 'HEAL', amount: 3, target: 'OWNER_HERO' } }],
  ),
  creature(
    'apprentice_mage',
    'Apprentice Mage',
    3,
    2,
    2,
    ['HUMAN', 'MAGE'],
    ['ARRIVAL'],
    [{ trigger: 'ARRIVAL', effect: { type: 'DEAL_DAMAGE', amount: 1, target: 'PLAY_TARGET' } }],
  ),
  creature('maintenance_anima', 'Maintenance Anima', 2, 1, 3, ['ANIMA', 'CONSTRUCT'], ['WARD']),
  creature(
    'mercy_4',
    'Mercy-4',
    4,
    3,
    4,
    ['ANIMA', 'CONSTRUCT'],
    ['LAST_BREATH'],
    [{ trigger: 'LAST_BREATH', effect: { type: 'HEAL', amount: 2, target: 'OWNER_HERO' } }],
  ),
  creature(
    'lio_varga',
    'Lio Varga',
    5,
    4,
    5,
    ['DWARF', 'MECHANIC', 'REBEL'],
    ['ARRIVAL'],
    [
      {
        trigger: 'ARRIVAL',
        effect: {
          type: 'BUFF',
          attack: 1,
          health: 1,
          target: 'ADJACENT_FRIENDLY_CREATURES',
        },
      },
    ],
    'CHRONICLE',
    'LEGENDARY',
  ),
  creature(
    'darek_voln',
    'Darek Voln',
    6,
    5,
    5,
    ['HUMAN', 'WARDEN', 'REBEL'],
    ['CHARGE', 'LIFESTEAL'],
    [],
    'CHRONICLE',
    'LEGENDARY',
  ),
  {
    id: 'healing_potion',
    name: 'Healing Potion',
    type: 'ACTION',
    cost: 1,
    source: 'CORE',
    expansionId: 'CORE',
    rarity: 'COMMON',
    collectible: true,
    text: 'Restore 4 Health to a friendly character.',
    targetMode: 'FRIENDLY_CHARACTER',
    effects: [{ type: 'HEAL', amount: 4, target: 'PLAY_TARGET' }],
  },
  {
    id: 'firebolt',
    name: 'Firebolt',
    type: 'ACTION',
    cost: 2,
    source: 'CORE',
    expansionId: 'CORE',
    rarity: 'COMMON',
    collectible: true,
    text: 'Deal 3 damage to an enemy character.',
    targetMode: 'ENEMY_CHARACTER',
    effects: [{ type: 'DEAL_DAMAGE', amount: 3, target: 'PLAY_TARGET' }],
  },
  {
    id: 'arcane_battery',
    name: 'Arcane Battery',
    type: 'ARTIFACT',
    cost: 3,
    durability: 3,
    source: 'CHRONICLE',
    expansionId: 'CHRONICLE',
    rarity: 'EPIC',
    collectible: true,
    text: 'At the start of your turn, gain 1 Taika this turn.',
    effects: [{ trigger: 'TURN_STARTED', effect: { type: 'GAIN_TAIKA', amount: 1 } }],
  },
  weapon('rusty_dagger', 'Rusty Dagger', 1, 1, 2, 'MELEE', ['DAGGER']),
  weapon('iron_sword', 'Iron Sword', 2, 2, 2, 'MELEE', ['SWORD']),
  weapon('war_axe', 'War Axe', 4, 4, 2, 'MELEE', ['AXE']),
  weapon('hunting_bow', 'Hunting Bow', 3, 2, 2, 'RANGED', ['BOW']),
  weapon('longbow', 'Longbow', 5, 3, 2, 'RANGED', ['BOW']),
];

function creature(
  id: string,
  name: string,
  cost: number,
  attack: number,
  health: number,
  tags: CreatureTag[],
  keywords: Keyword[] = [],
  effects: EffectDefinition[] = [],
  source: CardSource = 'CORE',
  rarity: Rarity = 'COMMON',
  expansionId: string = source,
): CreatureDefinition {
  return {
    id,
    name,
    type: 'CREATURE',
    cost,
    attack,
    health,
    tags,
    keywords,
    effects,
    source,
    expansionId,
    rarity,
    collectible: true,
    text: effects.length ? keywords.join(', ') : keywords.join(', ') || `${attack}/${health}`,
  };
}

function weapon(
  id: string,
  name: string,
  cost: number,
  attack: number,
  durability: number,
  range: WeaponRange,
  tags: WeaponTag[],
  effects: EffectDefinition[] = [],
  source: CardSource = 'CORE',
  rarity: Rarity = 'COMMON',
  expansionId: string = source,
): WeaponDefinition {
  return {
    id,
    name,
    type: 'WEAPON',
    cost,
    attack,
    durability,
    range,
    tags,
    effects,
    source,
    expansionId,
    rarity,
    collectible: true,
    // Melee is the default case and goes unsaid; Ranged changes how the card
    // plays, so it is named on the card itself.
    text: range === 'RANGED' ? 'Ranged' : '',
  };
}

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

// A malformed registry is a programming error, so it fails at import rather
// than midway through somebody's match.
const definitionErrors = [
  ...cards
    .filter((card): card is WeaponDefinition => card.type === 'WEAPON')
    .flatMap(validateWeaponDefinition),
  ...cards.flatMap(validateCardExpansion),
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

export const STARTER_DECK: string[] = [
  ...Array(2).fill('wolf'),
  ...Array(2).fill('brown_bear'),
  ...Array(2).fill('hawk'),
  ...Array(2).fill('giant_rat'),
  ...Array(2).fill('hunting_spider'),
  ...Array(2).fill('elf_archer'),
  ...Array(2).fill('dwarf_defender'),
  ...Array(2).fill('human_mercenary'),
  ...Array(2).fill('field_medic'),
  ...Array(2).fill('apprentice_mage'),
  ...Array(2).fill('maintenance_anima'),
  ...Array(2).fill('mercy_4'),
  ...Array(2).fill('healing_potion'),
  ...Array(2).fill('firebolt'),
  ...Array(2).fill('arcane_battery'),
];

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
