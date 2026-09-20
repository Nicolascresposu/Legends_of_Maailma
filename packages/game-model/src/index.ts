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
  | 'ADJACENT_FRIENDLY_CREATURES';

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

export type CardDefinition = CreatureDefinition | ActionDefinition | ArtifactDefinition;

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

export interface EndTurnAction {
  type: 'END_TURN';
  actorId: PlayerId;
}

export type GameAction =
  | PlayCardAction
  | AttackAction
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
  | 'STATUS_APPLIED'
  | 'STATUS_REMOVED'
  | 'TAIKA_CHANGED'
  | 'MATCH_ENDED';

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
