export const ROWS = ['FRONT', 'BACK'] as const;
export type BattlefieldRow = (typeof ROWS)[number];

export interface Position {
  row: BattlefieldRow;
  column: number;
}

export interface BattlefieldConfig {
  width: number;
}

export type PlayerId = string;
export type EntityId = string;
export type CardInstanceId = string;

export const KEYWORDS = [
  'ARRIVAL',
  'LAST_BREATH',
  'GUARD',
  'SWIFT',
  'CHARGE',
  'RANGED',
  'WARD',
  'HIDDEN',
  'LIFESTEAL',
] as const;
export type Keyword = (typeof KEYWORDS)[number];

export type CreatureTag =
  | 'HUMAN'
  | 'ELF'
  | 'DWARF'
  | 'GOBLIN'
  | 'BEAST'
  | 'ANIMA'
  | 'UNDEAD'
  | 'CONSTRUCT'
  | 'MECHANIC'
  | 'WARDEN'
  | 'REBEL'
  | 'MAGE'
  | 'ARCHER'
  | 'SOLDIER'
  | (string & {});

/**
 * Whether a Weapon strikes at reach.
 *
 * This is a rules property, not a flavour tag: the engine reads it directly to
 * decide row targeting and retaliation, and never infers it from a card's name,
 * text or `tags`.
 */
export const WEAPON_RANGES = ['MELEE', 'RANGED'] as const;
export type WeaponRange = (typeof WEAPON_RANGES)[number];

/**
 * Weapon taxonomy — what a Weapon *is*, for effects that care ("your Bows
 * cost 1 less"). Deliberately separate from `range`, which is what it *does*.
 */
export type WeaponTag =
  | 'SWORD'
  | 'AXE'
  | 'BOW'
  | 'CROSSBOW'
  | 'DAGGER'
  | 'HAMMER'
  | 'DWARVEN'
  | 'RELIC'
  | 'ANIMA'
  | (string & {});

export type CardSource = 'CORE' | 'CHRONICLE';
export type Rarity = 'COMMON' | 'RARE' | 'EPIC' | 'LEGENDARY';
export type Trigger = 'ARRIVAL' | 'LAST_BREATH' | 'TURN_STARTED' | 'TURN_ENDED';

export type EffectTarget =
  | 'PLAY_TARGET'
  | 'SELF'
  | 'OWNER_HERO'
  | 'ENEMY_HERO'
  | 'RANDOM_ENEMY_CREATURE'
  | 'ALL_ENEMY_CREATURES'
  | 'ADJACENT_FRIENDLY_CREATURES'
  | 'FRIENDLY_WEAPON'
  | 'ENEMY_WEAPON';

export type Effect =
  | { type: 'DEAL_DAMAGE'; amount: number; target: EffectTarget }
  | { type: 'HEAL'; amount: number; target: EffectTarget }
  | { type: 'DRAW_CARD'; amount: number }
  | { type: 'BUFF'; attack: number; health: number; target: EffectTarget }
  | { type: 'APPLY_STATUS'; status: StatusKind; duration?: number; target: EffectTarget }
  | { type: 'SUMMON'; definitionId: string; position?: Position }
  | { type: 'MOVE'; target: EffectTarget; destination: Position }
  | { type: 'DESTROY'; target: EffectTarget }
  | { type: 'GAIN_TAIKA'; amount: number };

export interface EffectDefinition {
  trigger: Trigger;
  effect: Effect;
}

interface CardDefinitionBase {
  id: string;
  name: string;
  cost: number;
  source: CardSource;
  rarity: Rarity;
  collectible: boolean;
  text: string;
}

export interface CreatureDefinition extends CardDefinitionBase {
  type: 'CREATURE';
  attack: number;
  health: number;
  tags: CreatureTag[];
  keywords: Keyword[];
  effects: EffectDefinition[];
}

export interface ActionDefinition extends CardDefinitionBase {
  type: 'ACTION';
  effects: Effect[];
  targetMode: TargetMode;
}

export interface ArtifactDefinition extends CardDefinitionBase {
  type: 'ARTIFACT';
  durability: number;
  effects: EffectDefinition[];
}

export interface WeaponDefinition extends CardDefinitionBase {
  type: 'WEAPON';
  attack: number;
  durability: number;
  range: WeaponRange;
  tags: WeaponTag[];
  effects: EffectDefinition[];
}

export type CardDefinition =
  CreatureDefinition | ActionDefinition | ArtifactDefinition | WeaponDefinition;

export type StatusKind = 'ROOTED' | 'HIDDEN' | 'REVEALED' | 'WARD' | 'ATTACK_MODIFIER';

export interface StatusInstance {
  id: string;
  kind: StatusKind;
  duration?: number;
  value?: number;
}

export interface CreatureInstance {
  instanceId: EntityId;
  definitionId: string;
  ownerId: PlayerId;
  currentAttack: number;
  currentHealth: number;
  maxHealth: number;
  position: Position;
  summonedThisTurn: boolean;
  combatActionUsed: boolean;
  statuses: StatusInstance[];
}

export interface ArtifactInstance {
  instanceId: EntityId;
  definitionId: string;
  ownerId: PlayerId;
  durability: number;
}

/**
 * Why a Weapon left its Hero's slot.
 *
 * Kept distinct because future card text discriminates on it: "when your
 * Weapon breaks, draw a card" must not fire when the owner simply swaps it out.
 */
export type WeaponRemovalReason = 'BROKEN' | 'REPLACED' | 'DESTROYED_BY_EFFECT';

/**
 * A Weapon in play. Definitions stay immutable, so every value an effect might
 * change — Attack, Durability — lives here.
 */
export interface WeaponInstance {
  instanceId: EntityId;
  definitionId: string;
  ownerId: PlayerId;
  currentAttack: number;
  currentDurability: number;
  maxDurability: number;
  statuses: StatusInstance[];
}

export interface HeroPowerDefinition {
  id: string;
  name: string;
  cost: number;
  text: string;
  effect: Effect;
  targetMode: TargetMode;
}

export interface HeroDefinition {
  id: string;
  name: string;
  health: number;
  power: HeroPowerDefinition;
}

export interface HeroInstance {
  definitionId: string;
  currentHealth: number;
  maxHealth: number;
  powerUsedThisTurn: boolean;
  /** The one Weapon slot. A Hero equips at most one Weapon at a time. */
  equippedWeapon: WeaponInstance | null;
  /**
   * Attacks the Hero has made this turn. A count rather than a flag so that
   * "your Hero may attack twice this turn" needs no change to this model, and
   * so swapping Weapons mid-turn cannot hand back a spent attack.
   */
  attacksUsedThisTurn: number;
}

export interface CardInstance {
  instanceId: CardInstanceId;
  definitionId: string;
}

export interface Battlefield {
  config: BattlefieldConfig;
  slots: Record<BattlefieldRow, Array<EntityId | null>>;
}

export interface MatchSide {
  playerId: PlayerId;
  controller: ControllerKind;
  hero: HeroInstance;
  taika: { current: number; maximum: number; cap: number };
  battlefield: Battlefield;
  creatures: Record<EntityId, CreatureInstance>;
  artifacts: ArtifactInstance[];
  deck: string[];
  hand: CardInstance[];
  discard: string[];
  fatigue: number;
  turnsStarted: number;
}

export type ControllerKind = 'HUMAN' | 'AI' | 'SCRIPTED';

export interface ScenarioSideDefinition {
  heroDefinitionId: string;
  heroHealth: number;
  startingTaika: number;
  maxTaika: number;
  startingCards?: string[];
  startingCreatures?: Array<{ definitionId: string; position: Position }>;
  startingArtifacts?: string[];
  /** A Weapon the Hero begins the match holding — for PvE bosses. */
  startingWeapon?: string;
  controller?: ControllerKind;
}

export type ScenarioRule = { type: string; value?: string | number | boolean };
export type VictoryCondition = { type: 'ENEMY_HERO_DEFEATED' | 'CUSTOM'; key?: string };

export interface ScenarioDefinition {
  id: string;
  name: string;
  battlefield: BattlefieldConfig;
  sideA: ScenarioSideDefinition;
  sideB: ScenarioSideDefinition;
  rules?: ScenarioRule[];
  victoryConditions?: VictoryCondition[];
  defeatConditions?: VictoryCondition[];
}

export interface MatchSetup {
  matchId?: string;
  scenario: ScenarioDefinition;
  seed: number | string;
  players: readonly [PlayerSetup, PlayerSetup];
}

export interface PlayerSetup {
  playerId: PlayerId;
  deck: string[];
  heroDefinitionId?: string;
  controller?: ControllerKind;
}

export interface MatchState {
  matchId: string;
  scenarioId: string;
  seed: number;
  rngState: number;
  turn: number;
  activePlayerId: PlayerId;
  playerOrder: [PlayerId, PlayerId];
  sides: Record<PlayerId, MatchSide>;
  phase: 'PLAYING' | 'FINISHED';
  winnerId?: PlayerId;
  nextInstanceId: number;
  nextEventSequence: number;
  actionLog: GameAction[];
}

export type TargetMode =
  | 'NONE'
  | 'FRIENDLY_CHARACTER'
  | 'ENEMY_CHARACTER'
  | 'ANY_CHARACTER'
  | 'FRIENDLY_CREATURE'
  | 'ENEMY_CREATURE';

export interface PlayCardAction {
  type: 'PLAY_CARD';
  actorId: PlayerId;
  cardInstanceId: CardInstanceId;
  position?: Position;
  targetId?: EntityId;
}

export interface AttackAction {
  type: 'ATTACK';
  actorId: PlayerId;
  attackerId: EntityId;
  targetId: EntityId;
}

export interface MoveCreatureAction {
  type: 'MOVE_CREATURE';
  actorId: PlayerId;
  creatureId: EntityId;
  destination: Position;
}

export interface SwapCreaturesAction {
  type: 'SWAP_CREATURES';
  actorId: PlayerId;
  firstCreatureId: EntityId;
  secondCreatureId: EntityId;
}

export interface UseHeroPowerAction {
  type: 'USE_HERO_POWER';
  actorId: PlayerId;
  targetId?: EntityId;
}

/**
 * The Hero swings its equipped Weapon.
 *
 * Deliberately not folded into `ATTACK`: that action names a Creature
 * `attackerId` and carries Creature-only concerns (summoning sickness, the
 * attacker's own tile). A Hero has neither.
 */
export interface HeroAttackAction {
  type: 'HERO_ATTACK';
  actorId: PlayerId;
  targetId: EntityId;
}

export interface EndTurnAction {
  type: 'END_TURN';
  actorId: PlayerId;
}

export type GameAction =
  | PlayCardAction
  | AttackAction
  | HeroAttackAction
  | MoveCreatureAction
  | SwapCreaturesAction
  | UseHeroPowerAction
  | EndTurnAction;

export type GameEventType =
  | 'MATCH_STARTED'
  | 'TURN_STARTED'
  | 'TURN_ENDED'
  | 'CARD_DRAWN'
  | 'CARD_PLAYED'
  | 'CARD_DISCARDED'
  | 'CREATURE_SUMMONED'
  | 'CREATURE_MOVED'
  | 'CREATURE_SWAPPED'
  | 'ATTACK_STARTED'
  | 'DAMAGE_DEALT'
  | 'DAMAGE_PREVENTED'
  | 'HEALING_RECEIVED'
  | 'CREATURE_DIED'
  | 'ARTIFACT_PLAYED'
  | 'ARTIFACT_DAMAGED'
  | 'ARTIFACT_DESTROYED'
  | 'HERO_POWER_USED'
  | 'WEAPON_EQUIPPED'
  | 'WEAPON_REPLACED'
  | 'WEAPON_DURABILITY_CHANGED'
  | 'WEAPON_BROKEN'
  | 'WEAPON_DESTROYED'
  | 'HERO_ATTACK_STARTED'
  | 'HERO_ATTACK_RESOLVED'
  | 'STATUS_APPLIED'
  | 'STATUS_REMOVED'
  | 'TAIKA_CHANGED'
  | 'MATCH_ENDED';

/**
 * How a point of damage was delivered.
 *
 * Damage is never anonymous: future card text distinguishes "whenever your Hero
 * deals Weapon damage" from an Action's burn, and "whenever you take melee
 * combat damage" from a ranged shot. Absent on non-damage events.
 */
export interface DamageContext {
  /** What dealt it. */
  kind: 'CREATURE_COMBAT' | 'HERO_WEAPON' | 'EFFECT' | 'FATIGUE';
  /** True for the defender's half of a melee exchange. */
  retaliation?: boolean;
  /** Reach of the attack, where the distinction is meaningful. */
  range?: WeaponRange;
  /** The Weapon instance responsible, for `HERO_WEAPON` damage. */
  weaponId?: EntityId;
  /** The Weapon's definition, which outlives the instance when it breaks. */
  weaponDefinitionId?: string;
}

export interface GameEvent {
  sequence: number;
  type: GameEventType;
  actorId?: PlayerId;
  sourceId?: EntityId;
  targetId?: EntityId;
  amount?: number;
  cardDefinitionId?: string;
  position?: Position;
  from?: Position;
  to?: Position;
  reason?: string;
  winnerId?: PlayerId;
  /** Present on `DAMAGE_DEALT`/`CREATURE_DIED`, so kills can be attributed. */
  damage?: DamageContext;
}

export interface ActionResult {
  ok: boolean;
  events: GameEvent[];
  error?: { code: string; message: string };
}

export interface ReplayData {
  setup: MatchSetup;
  actions: GameAction[];
}
