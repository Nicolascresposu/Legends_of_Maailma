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
} from '@maailma/game-model';

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
    rarity: 'EPIC',
    collectible: true,
    text: 'At the start of your turn, gain 1 Taika this turn.',
    effects: [{ trigger: 'TURN_STARTED', effect: { type: 'GAIN_TAIKA', amount: 1 } }],
  },
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
    rarity,
    collectible: true,
    text: effects.length ? keywords.join(', ') : keywords.join(', ') || `${attack}/${health}`,
  };
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
