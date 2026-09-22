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
import { validateCardDescription } from './descriptions.js';
import { isKnownExpansion } from './expansions.js';

export * from './descriptions.js';
export * from './expansions.js';
export * from './economy.js';
export * from './packs.js';

/**
 * A card's printed text. `description` is rules only, with every keyword in
 * **bold**; `flavour` is story and nothing else, so a player never has to
 * guess which words are rules. Markup is documented on `CardDefinition`.
 */
type PrintedText = Pick<CardDefinition, 'description' | 'flavour'>;

const cards: CardDefinition[] = [
  creature(
    'wolf',
    'Wolf',
    { description: 'No special abilities.', flavour: 'The first to find you, and never the last.' },
    1,
    2,
    1,
    ['BEAST'],
  ),
  creature(
    'brown_bear',
    'Brown Bear',
    {
      description: 'No special abilities.',
      flavour: 'It does not want your camp. It wants what is in your camp.',
    },
    3,
    3,
    4,
    ['BEAST'],
  ),
  creature(
    'hawk',
    'Hawk',
    { description: '**Swift**', flavour: 'Seen before it is heard, and gone before either.' },
    2,
    2,
    1,
    ['BEAST'],
    ['SWIFT'],
  ),
  creature(
    'giant_rat',
    'Giant Rat',
    {
      description: '**Last Breath:** Draw a card.',
      flavour: 'Where there is one, there are more in the walls.',
    },
    1,
    1,
    1,
    ['BEAST'],
    ['LAST_BREATH'],
    [{ trigger: 'LAST_BREATH', effect: { type: 'DRAW_CARD', amount: 1 } }],
  ),
  creature(
    'hunting_spider',
    'Hunting Spider',
    { description: '**Hidden**', flavour: 'The web is only a warning. The spider is the trap.' },
    2,
    2,
    2,
    ['BEAST'],
    ['HIDDEN'],
  ),
  creature(
    'elf_archer',
    'Elf Archer',
    { description: '**Ranged**', flavour: 'Elves measure distance in heartbeats, not paces.' },
    3,
    2,
    2,
    ['ELF', 'ARCHER'],
    ['RANGED'],
  ),
  creature(
    'dwarf_defender',
    'Dwarf Defender',
    { description: '**Guard**', flavour: '"Through me, or not at all."' },
    3,
    2,
    4,
    ['DWARF', 'SOLDIER'],
    ['GUARD'],
  ),
  creature(
    'human_mercenary',
    'Human Mercenary',
    {
      description: 'No special abilities.',
      flavour: 'Loyal to the last coin, and not one coin further.',
    },
    2,
    3,
    2,
    ['HUMAN', 'SOLDIER'],
  ),
  creature(
    'field_medic',
    'Field Medic',
    {
      description: '**Arrival:** Restore 3 Health to your Hero.',
      flavour: 'Bandages first. Questions never.',
    },
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
    {
      description: '**Arrival:** Deal 1 damage to an enemy character.',
      flavour: 'The spell works. The aim is still being taught.',
    },
    3,
    2,
    2,
    ['HUMAN', 'MAGE'],
    ['ARRIVAL'],
    [{ trigger: 'ARRIVAL', effect: { type: 'DEAL_DAMAGE', amount: 1, target: 'PLAY_TARGET' } }],
  ),
  creature(
    'maintenance_anima',
    'Maintenance Anima',
    {
      description: '**Ward**',
      flavour: 'Built to keep the old machines running, it keeps itself running too.',
    },
    2,
    1,
    3,
    ['ANIMA', 'CONSTRUCT'],
    ['WARD'],
  ),
  // The Core set's Rare slot. Every rarity has to be represented somewhere a
  // player can actually reach, or the crafting economy has a price band that
  // nothing is ever bought or sold at.
  creature(
    'warden_sentinel',
    'Warden Sentinel',
    {
      description: '**Guard**\n**Arrival:** Give adjacent friendly Creatures +1 Health.',
      flavour: 'The wall is only as strong as the one who stands beside you.',
    },
    4,
    3,
    4,
    ['HUMAN', 'WARDEN'],
    ['GUARD', 'ARRIVAL'],
    [
      {
        trigger: 'ARRIVAL',
        effect: { type: 'BUFF', attack: 0, health: 1, target: 'ADJACENT_FRIENDLY_CREATURES' },
      },
    ],
    'CORE',
    'RARE',
  ),
  creature(
    'mercy_4',
    'Mercy-4',
    {
      description: '**Last Breath:** Restore 2 Health to your Hero.',
      flavour: 'Its final directive is the same as its first.',
    },
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
    {
      description: '**Arrival:** Give adjacent friendly Creatures +1/+1.',
      flavour: '"Give me a wrench and a grudge, and I\'ll build you a revolution."',
    },
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
    {
      description: '**Charge**, **Lifesteal**',
      flavour: 'A Warden who turned the oath against those who wrote it.',
    },
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
    description: 'Restore 4 Health to a friendly character.',
    flavour: 'Tastes of pine tar and regret.',
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
    description: 'Deal 3 damage to an enemy character.',
    flavour: 'Taika drawn in anger burns brightest.',
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
    description: 'At the start of your turn, gain 1 Taika this turn.',
    flavour: 'It hums with what the storm left behind.',
    effects: [{ trigger: 'TURN_STARTED', effect: { type: 'GAIN_TAIKA', amount: 1 } }],
  },
  weapon(
    'rusty_dagger',
    'Rusty Dagger',
    {
      description: 'Your Hero attacks with this Weapon. Creatures it strikes hit back.',
      flavour: 'Its edge is long gone. Its bite is not.',
    },
    1,
    1,
    2,
    'MELEE',
    ['DAGGER'],
  ),
  weapon(
    'iron_sword',
    'Iron Sword',
    {
      description: 'Your Hero attacks with this Weapon. Creatures it strikes hit back.',
      flavour: 'Plain, honest, and sharp enough.',
    },
    2,
    2,
    2,
    'MELEE',
    ['SWORD'],
  ),
  weapon(
    'war_axe',
    'War Axe',
    {
      description: 'Your Hero attacks with this Weapon. Creatures it strikes hit back.',
      flavour: 'Swung once, and remembered by everyone who was there.',
    },
    4,
    4,
    2,
    'MELEE',
    ['AXE'],
  ),
  weapon(
    'hunting_bow',
    'Hunting Bow',
    {
      description: '**Ranged**. Your Hero attacks with this Weapon.',
      flavour: 'Strung with sinew, and with patience.',
    },
    3,
    2,
    2,
    'RANGED',
    ['BOW'],
  ),
  weapon(
    'longbow',
    'Longbow',
    {
      description: '**Ranged**. Your Hero attacks with this Weapon.',
      flavour: 'Taller than its archer, and it carries farther than any shout.',
    },
    5,
    3,
    2,
    'RANGED',
    ['BOW'],
  ),
  weapon(
    'dwarven_maul',
    'Dwarven Maul',
    {
      description: 'Your Hero attacks with this Weapon. Creatures it strikes hit back.',
      flavour: 'Dwarven smiths forge hammers to outlast the hands that swing them.',
    },
    4,
    3,
    3,
    'MELEE',
    ['HAMMER', 'DWARVEN'],
    [],
    'CORE',
    'RARE',
  ),

  // Machines of Kona — unreleased. Defined in full so the set can be played
  // and tested before launch; `released: false` is what keeps it out of
  // players' hands, not its absence from this file.
  creature(
    'kona_scrapwalker',
    'Kona Scrapwalker',
    {
      description: 'No special abilities.',
      flavour: 'Assembled from whatever the last war left lying about.',
    },
    2,
    2,
    2,
    ['CONSTRUCT', 'MECHANIC'],
    [],
    [],
    'CORE',
    'COMMON',
    'MACHINES_OF_KONA',
  ),
  creature(
    'kona_riveter',
    'Kona Riveter',
    { description: '**Arrival:** Gain +1 Attack.', flavour: 'Measure once, rivet twice.' },
    3,
    2,
    3,
    ['DWARF', 'MECHANIC'],
    ['ARRIVAL'],
    [{ trigger: 'ARRIVAL', effect: { type: 'BUFF', attack: 1, health: 0, target: 'SELF' } }],
    'CORE',
    'RARE',
    'MACHINES_OF_KONA',
  ),
  creature(
    'kona_forgeheart',
    'Kona Forgeheart',
    {
      description: '**Guard**, **Ward**',
      flavour: 'The furnace at its core has never once gone out.',
    },
    5,
    4,
    5,
    ['CONSTRUCT', 'ANIMA'],
    ['GUARD', 'WARD'],
    [],
    'CORE',
    'EPIC',
    'MACHINES_OF_KONA',
  ),
  creature(
    'ilvi_kona',
    'Ilvi of Kona',
    {
      description: '**Charge**\n**Arrival:** Give adjacent friendly Creatures +1/+1.',
      flavour: '"Kona was built by rebels. It will be rebuilt by them."',
    },
    6,
    5,
    6,
    ['HUMAN', 'MECHANIC', 'REBEL'],
    ['CHARGE'],
    [
      {
        trigger: 'ARRIVAL',
        effect: { type: 'BUFF', attack: 1, health: 1, target: 'ADJACENT_FRIENDLY_CREATURES' },
      },
    ],
    'CHRONICLE',
    'LEGENDARY',
    'MACHINES_OF_KONA',
  ),
  weapon(
    'kona_piston_hammer',
    'Kona Piston Hammer',
    {
      description: 'Your Hero attacks with this Weapon. Creatures it strikes hit back.',
      flavour: 'Every swing is a small explosion, carefully timed.',
    },
    3,
    3,
    2,
    'MELEE',
    ['HAMMER'],
    [],
    'CORE',
    'COMMON',
    'MACHINES_OF_KONA',
  ),
];

function creature(
  id: string,
  name: string,
  printed: PrintedText,
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
    ...printed,
  };
}

function weapon(
  id: string,
  name: string,
  printed: PrintedText,
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
    ...printed,
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
  ...cards.flatMap(validateCardDescription),
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
