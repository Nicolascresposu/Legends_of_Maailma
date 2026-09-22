import { getCardDefinition, getHeroDefinition } from '@maailma/card-definitions';
import type {
  ActionResult,
  CardDefinition,
  CreatureDefinition,
  CreatureInstance,
  DamageContext,
  Effect,
  EffectTarget,
  EntityId,
  GameAction,
  GameEvent,
  MatchSetup,
  MatchSide,
  MatchState,
  PlayerId,
  Position,
  ReplayData,
  TargetMode,
  WeaponDefinition,
  WeaponInstance,
  WeaponRange,
  WeaponRemovalReason,
} from '@maailma/game-model';
import { SeededRng, normalizeSeed } from '@maailma/rng';
import {
  adjacentPositions,
  areOrthogonallyAdjacent,
  clonePosition,
  createBattlefield,
  emptyPositions,
  entityAt,
  isPositionValid,
  setEntityAt,
} from './battlefield.js';
import { GameRuleError, rule } from './errors.js';

type EventDraft = Omit<GameEvent, 'sequence'>;
type WorkItem =
  | { kind: 'EVENT'; event: EventDraft }
  | {
      kind: 'EFFECT';
      effect: Effect;
      ownerId: PlayerId;
      sourceId?: EntityId;
      playTargetId?: EntityId;
    };

export const heroEntityId = (playerId: PlayerId): EntityId => `${playerId}:hero`;

/**
 * What an attacker is, reduced to the properties that decide target legality.
 *
 * Creature attacks and Hero Weapon attacks differ in who may swing and what it
 * costs, but not in what may be hit. Both funnel through
 * `validateAttackTarget`, so Guard, front-row shielding and Hidden have exactly
 * one implementation and cannot drift apart.
 */
interface AttackProfile {
  /** `RANGED` reaches the back row and ignores front-row shielding. */
  range: WeaponRange;
  /** The side swinging. */
  attackerId: PlayerId;
}

export class GameEngine {
  readonly setup: MatchSetup;
  readonly state!: MatchState;
  private rng: SeededRng;
  private queue: WorkItem[] = [];
  private currentEvents: GameEvent[] = [];
  /** What dealt lethal damage to an entity, read once by its death event. */
  private lethalContext = new Map<EntityId, DamageContext>();

  constructor(setup: MatchSetup) {
    validateSetup(setup);
    this.setup = structuredClone(setup);
    this.rng = new SeededRng(setup.seed);
    this.createInitialState(setup);
  }

  static replay(replay: ReplayData): GameEngine {
    const engine = new GameEngine(replay.setup);
    for (const action of replay.actions) {
      const result = engine.dispatch(action);
      if (!result.ok) {
        throw new Error(`Replay rejected action ${action.type}: ${result.error?.message}`);
      }
    }
    return engine;
  }

  dispatch(action: GameAction): ActionResult {
    this.currentEvents = [];
    this.queue = [];
    this.lethalContext.clear();
    try {
      this.validateAction(action);
      this.applyAction(action);
      this.drainQueue();
      this.state.actionLog.push(structuredClone(action));
      this.state.rngState = this.rng.state;
      return { ok: true, events: this.currentEvents };
    } catch (error) {
      if (error instanceof GameRuleError) {
        return { ok: false, events: [], error: { code: error.code, message: error.message } };
      }
      throw error;
    }
  }

  getLegalActions(playerId: PlayerId): GameAction[] {
    if (this.state.phase !== 'PLAYING' || this.state.activePlayerId !== playerId) return [];
    const side = this.side(playerId);
    const actions: GameAction[] = [];

    for (const card of side.hand) {
      const definition = getCardDefinition(card.definitionId);
      if (definition.cost > side.taika.current) continue;
      const positions =
        definition.type === 'CREATURE' ? emptyPositions(side.battlefield) : [undefined];
      const targetMode = cardTargetMode(definition);
      const targets =
        targetMode === 'NONE' ? [undefined] : this.targetsForMode(playerId, targetMode);
      for (const position of positions) {
        for (const targetId of targets) {
          const action: GameAction = {
            type: 'PLAY_CARD',
            actorId: playerId,
            cardInstanceId: card.instanceId,
            ...(position ? { position } : {}),
            ...(targetId ? { targetId } : {}),
          };
          if (this.isLegal(action)) actions.push(action);
        }
      }
    }

    for (const creature of Object.values(side.creatures).sort(byInstanceId)) {
      for (const enemy of Object.values(this.opponentSide(playerId).creatures).sort(byInstanceId)) {
        const action: GameAction = {
          type: 'ATTACK',
          actorId: playerId,
          attackerId: creature.instanceId,
          targetId: enemy.instanceId,
        };
        if (this.isLegal(action)) actions.push(action);
      }
      const heroAttack: GameAction = {
        type: 'ATTACK',
        actorId: playerId,
        attackerId: creature.instanceId,
        targetId: heroEntityId(this.opponentId(playerId)),
      };
      if (this.isLegal(heroAttack)) actions.push(heroAttack);

      for (const destination of emptyPositions(side.battlefield)) {
        const action: GameAction = {
          type: 'MOVE_CREATURE',
          actorId: playerId,
          creatureId: creature.instanceId,
          destination,
        };
        if (this.isLegal(action)) actions.push(action);
      }
    }

    const creatures = Object.values(side.creatures).sort(byInstanceId);
    for (let first = 0; first < creatures.length; first += 1) {
      for (let second = first + 1; second < creatures.length; second += 1) {
        const action: GameAction = {
          type: 'SWAP_CREATURES',
          actorId: playerId,
          firstCreatureId: creatures[first]!.instanceId,
          secondCreatureId: creatures[second]!.instanceId,
        };
        if (this.isLegal(action)) actions.push(action);
      }
    }

    // Hero Weapon attacks. Targets come from the same legality check the
    // engine enforces, so a client or AI never has to recreate Guard rules.
    if (side.hero.equippedWeapon) {
      const enemy = this.opponentSide(playerId);
      const candidates: EntityId[] = [
        ...Object.values(enemy.creatures)
          .sort(byInstanceId)
          .map((creature) => creature.instanceId),
        heroEntityId(enemy.playerId),
      ];
      for (const targetId of candidates) {
        const action: GameAction = { type: 'HERO_ATTACK', actorId: playerId, targetId };
        if (this.isLegal(action)) actions.push(action);
      }
    }

    const power = getHeroDefinition(side.hero.definitionId).power;
    const powerTargets =
      power.targetMode === 'NONE' ? [undefined] : this.targetsForMode(playerId, power.targetMode);
    for (const targetId of powerTargets) {
      const action: GameAction = {
        type: 'USE_HERO_POWER',
        actorId: playerId,
        ...(targetId ? { targetId } : {}),
      };
      if (this.isLegal(action)) actions.push(action);
    }
    actions.push({ type: 'END_TURN', actorId: playerId });
    return actions;
  }

  /**
   * Resolves one effect outside a card play and returns the events it produced.
   *
   * Scenario scripting and tests need to apply an effect directly — "the boss
   * shatters your Weapon" — without inventing a card for it. It runs through
   * the ordinary queue, so ordering and triggers behave exactly as they would
   * from a card.
   */
  resolveEffect(effect: Effect, ownerId: PlayerId, sourceId?: EntityId): GameEvent[] {
    this.currentEvents = [];
    this.queue = [];
    this.lethalContext.clear();
    this.enqueueEffect(effect, ownerId, sourceId);
    this.drainQueue();
    this.state.rngState = this.rng.state;
    return this.currentEvents;
  }

  private isLegal(action: GameAction): boolean {
    try {
      this.validateAction(action);
      return true;
    } catch (error) {
      if (error instanceof GameRuleError) return false;
      throw error;
    }
  }

  private createInitialState(setup: MatchSetup): void {
    const [firstPlayer, secondPlayer] = setup.players;
    const playerOrder: [PlayerId, PlayerId] = [firstPlayer.playerId, secondPlayer.playerId];
    const state: MatchState = {
      matchId: setup.matchId ?? `match-${normalizeSeed(setup.seed).toString(16)}`,
      scenarioId: setup.scenario.id,
      seed: normalizeSeed(setup.seed),
      rngState: this.rng.state,
      turn: 1,
      activePlayerId: firstPlayer.playerId,
      playerOrder,
      sides: {},
      phase: 'PLAYING',
      nextInstanceId: 1,
      nextEventSequence: 1,
      actionLog: [],
    };
    this.assignStateTemporarily(state);
    state.sides[firstPlayer.playerId] = this.createSide(firstPlayer, setup.scenario.sideA);
    state.sides[secondPlayer.playerId] = this.createSide(secondPlayer, setup.scenario.sideB);
    for (const playerId of playerOrder) {
      const side = state.sides[playerId]!;
      const scenarioSide =
        playerId === firstPlayer.playerId ? setup.scenario.sideA : setup.scenario.sideB;
      for (const definitionId of scenarioSide.startingCards ?? [])
        this.addCardToHand(side, definitionId);
      const openingDraws = Math.min(3, side.deck.length);
      for (let count = 0; count < openingDraws; count += 1) this.drawCard(side, false);
      for (const initial of scenarioSide.startingCreatures ?? []) {
        this.summonCreature(side, initial.definitionId, initial.position, false);
      }
      for (const definitionId of scenarioSide.startingArtifacts ?? []) {
        this.createArtifact(side, definitionId);
      }
      // PvE Heroes may open the match already armed.
      if (scenarioSide.startingWeapon) this.equipWeapon(side, scenarioSide.startingWeapon);
    }
    state.rngState = this.rng.state;
  }

  // Used only while construction is in progress; state is a readonly property after construction.
  private assignStateTemporarily(state: MatchState): void {
    Object.defineProperty(this, 'state', { value: state, writable: false, configurable: true });
  }

  private createSide(
    player: MatchSetup['players'][number],
    scenarioSide: MatchSetup['scenario']['sideA'],
  ): MatchSide {
    const heroId = player.heroDefinitionId ?? scenarioSide.heroDefinitionId;
    const hero = getHeroDefinition(heroId);
    const deck = this.rng.shuffle(player.deck);
    return {
      playerId: player.playerId,
      controller: player.controller ?? scenarioSide.controller ?? 'HUMAN',
      hero: {
        definitionId: heroId,
        currentHealth: scenarioSide.heroHealth ?? hero.health,
        maxHealth: scenarioSide.heroHealth ?? hero.health,
        powerUsedThisTurn: false,
        equippedWeapon: null,
        attacksUsedThisTurn: 0,
      },
      taika: {
        current: scenarioSide.startingTaika,
        maximum: scenarioSide.startingTaika,
        cap: scenarioSide.maxTaika,
      },
      battlefield: createBattlefield(this.setup.scenario.battlefield),
      creatures: {},
      artifacts: [],
      deck,
      hand: [],
      discard: [],
      fatigue: 0,
      turnsStarted: player.playerId === this.setup.players[0].playerId ? 1 : 0,
    };
  }

  private validateAction(action: GameAction): void {
    rule(this.state.phase === 'PLAYING', 'MATCH_FINISHED', 'The match has already ended');
    rule(this.state.sides[action.actorId], 'UNKNOWN_ACTOR', 'Actor is not part of this match');
    rule(
      this.state.activePlayerId === action.actorId,
      'NOT_YOUR_TURN',
      'Only the active side may act',
    );
    switch (action.type) {
      case 'PLAY_CARD':
        return this.validatePlayCard(action);
      case 'ATTACK':
        return this.validateAttack(action);
      case 'HERO_ATTACK':
        return this.validateHeroAttack(action);
      case 'MOVE_CREATURE':
        return this.validateMove(action);
      case 'SWAP_CREATURES':
        return this.validateSwap(action);
      case 'USE_HERO_POWER':
        return this.validateHeroPower(action.actorId, action.targetId);
      case 'END_TURN':
        return;
    }
  }

  private validatePlayCard(action: Extract<GameAction, { type: 'PLAY_CARD' }>): void {
    const side = this.side(action.actorId);
    const card = side.hand.find((candidate) => candidate.instanceId === action.cardInstanceId);
    rule(card, 'CARD_NOT_IN_HAND', 'The selected card is not in hand');
    const definition = getCardDefinition(card.definitionId);
    rule(side.taika.current >= definition.cost, 'INSUFFICIENT_TAIKA', 'Not enough Taika');
    if (definition.type === 'CREATURE') {
      rule(action.position, 'POSITION_REQUIRED', 'A Creature requires a destination tile');
      rule(
        isPositionValid(side.battlefield, action.position),
        'INVALID_POSITION',
        'Tile is outside the battlefield',
      );
      rule(
        entityAt(side.battlefield, action.position) === null,
        'TILE_OCCUPIED',
        'Tile is occupied',
      );
    } else {
      rule(!action.position, 'UNEXPECTED_POSITION', 'This card does not occupy a battlefield tile');
    }
    this.validateTargetMode(action.actorId, cardTargetMode(definition), action.targetId);
  }

  private validateAttack(action: Extract<GameAction, { type: 'ATTACK' }>): void {
    const attacker = this.requireOwnedCreature(action.actorId, action.attackerId);
    const definition = this.creatureDefinition(attacker);
    const ranged = definition.keywords.includes('RANGED');
    rule(!attacker.combatActionUsed, 'ACTION_USED', 'Creature already used its combat action');
    const isHero = action.targetId === heroEntityId(this.opponentId(action.actorId));
    if (attacker.summonedThisTurn) {
      rule(
        definition.keywords.includes('CHARGE') ||
          (definition.keywords.includes('SWIFT') && !isHero),
        'SUMMONING_SICKNESS',
        'Creature cannot attack this target on its summon turn',
      );
    }
    // A Creature swings from where it stands; a Hero stands nowhere, which is
    // the one targeting rule the two attackers do not share.
    rule(
      ranged || attacker.position.row === 'FRONT',
      'BACK_ROW_MELEE',
      'A melee Creature must attack from the front row',
    );
    this.validateAttackTarget(
      { range: ranged ? 'RANGED' : 'MELEE', attackerId: action.actorId },
      action.targetId,
    );
  }

  private validateHeroAttack(action: Extract<GameAction, { type: 'HERO_ATTACK' }>): void {
    const side = this.side(action.actorId);
    const weapon = side.hero.equippedWeapon;
    rule(weapon, 'NO_WEAPON', 'The Hero has no Weapon equipped');
    rule(weapon.currentDurability > 0, 'WEAPON_BROKEN', 'The Weapon has no Durability left');
    rule(weapon.currentAttack > 0, 'NO_ATTACK', 'The Weapon has no Attack');
    rule(
      side.hero.attacksUsedThisTurn < this.heroAttackAllowance(),
      'HERO_ATTACK_USED',
      'The Hero has already attacked this turn',
    );
    this.validateAttackTarget(
      { range: this.weaponDefinition(weapon).range, attackerId: action.actorId },
      action.targetId,
    );
  }

  /**
   * How many attacks this Hero has in a turn.
   *
   * One, always, for now. It is a method rather than a literal so that
   * "your Hero may attack twice this turn" or a boss with a different limit
   * lands here instead of in combat resolution. It deliberately does not reuse
   * `ATTACK_MODIFIER`, which is about how hard an attack hits, not how many
   * there are — a future allowance status wants a kind of its own.
   */
  private heroAttackAllowance(): number {
    return 1;
  }

  /**
   * Whether an attack may legally land on `targetId`.
   *
   * The single source of truth for Guard and positional legality, shared by
   * Creature attacks and Hero Weapon attacks. Nothing here asks *what* is
   * attacking beyond its reach, so the two can never diverge.
   */
  private validateAttackTarget(profile: AttackProfile, targetId: EntityId): void {
    const defenderId = this.opponentId(profile.attackerId);
    if (targetId === heroEntityId(defenderId)) {
      // A Guard anywhere on the defending board seals the Hero off, at any reach.
      rule(
        !this.hasLivingGuard(this.side(defenderId)),
        'HERO_GUARDED',
        'A Guard protects the Hero',
      );
      return;
    }
    const target = this.findCreature(targetId);
    rule(target, 'INVALID_TARGET', 'Attack target must be an enemy Creature or Hero');
    rule(target.ownerId !== profile.attackerId, 'FRIENDLY_FIRE', 'Attacks cannot hit allies');
    rule(!this.isHidden(target), 'TARGET_HIDDEN', 'Hidden Creatures cannot be directly targeted');
    if (!this.creatureDefinition(target).keywords.includes('GUARD')) {
      rule(
        !this.isGuardProtected(target),
        'TARGET_GUARDED',
        'An adjacent Guard protects this Creature',
      );
    }
    // Ranged reaches past the front line; melee must wait for it to clear.
    if (profile.range === 'MELEE' && target.position.row === 'BACK') {
      const defender = this.side(target.ownerId);
      rule(
        entityAt(defender.battlefield, { row: 'FRONT', column: target.position.column }) === null,
        'BACK_ROW_PROTECTED',
        'The Creature in front shields this back-row Creature',
      );
    }
  }

  private validateMove(action: Extract<GameAction, { type: 'MOVE_CREATURE' }>): void {
    const creature = this.requireOwnedCreature(action.actorId, action.creatureId);
    this.validateMovementEligibility(creature);
    const side = this.side(action.actorId);
    rule(
      isPositionValid(side.battlefield, action.destination),
      'INVALID_POSITION',
      'Destination is outside the battlefield',
    );
    rule(
      entityAt(side.battlefield, action.destination) === null,
      'TILE_OCCUPIED',
      'Destination is occupied',
    );
    rule(
      areOrthogonallyAdjacent(creature.position, action.destination),
      'NOT_ADJACENT',
      'Movement must be orthogonal and adjacent',
    );
  }

  private validateSwap(action: Extract<GameAction, { type: 'SWAP_CREATURES' }>): void {
    rule(
      action.firstCreatureId !== action.secondCreatureId,
      'SAME_CREATURE',
      'A Creature cannot swap with itself',
    );
    const first = this.requireOwnedCreature(action.actorId, action.firstCreatureId);
    const second = this.requireOwnedCreature(action.actorId, action.secondCreatureId);
    this.validateMovementEligibility(first);
    this.validateMovementEligibility(second);
    rule(
      areOrthogonallyAdjacent(first.position, second.position),
      'NOT_ADJACENT',
      'Creatures must be orthogonally adjacent',
    );
  }

  private validateMovementEligibility(creature: CreatureInstance): void {
    rule(!creature.combatActionUsed, 'ACTION_USED', 'Creature already used its combat action');
    rule(
      !creature.statuses.some((status) => status.kind === 'ROOTED'),
      'ROOTED',
      'Creature cannot move',
    );
    if (creature.summonedThisTurn) {
      rule(
        this.creatureDefinition(creature).keywords.includes('CHARGE'),
        'SUMMONING_SICKNESS',
        'Creature cannot move on its summon turn',
      );
    }
  }

  private validateHeroPower(actorId: PlayerId, targetId?: EntityId): void {
    const side = this.side(actorId);
    const power = getHeroDefinition(side.hero.definitionId).power;
    rule(!side.hero.powerUsedThisTurn, 'POWER_USED', 'Hero Power was already used this turn');
    rule(side.taika.current >= power.cost, 'INSUFFICIENT_TAIKA', 'Not enough Taika');
    this.validateTargetMode(actorId, power.targetMode, targetId);
  }

  private validateTargetMode(actorId: PlayerId, mode: TargetMode, targetId?: EntityId): void {
    if (mode === 'NONE') {
      rule(!targetId, 'UNEXPECTED_TARGET', 'This action does not take a target');
      return;
    }
    rule(targetId, 'TARGET_REQUIRED', 'A target is required');
    const targetOwner = this.ownerOf(targetId);
    rule(targetOwner, 'INVALID_TARGET', 'Target does not exist');
    const isCreature = !targetId.endsWith(':hero');
    if (isCreature) {
      const creature = this.findCreature(targetId)!;
      rule(
        !this.isHidden(creature),
        'TARGET_HIDDEN',
        'Hidden Creatures cannot be directly targeted',
      );
    }
    if (mode.includes('FRIENDLY'))
      rule(targetOwner === actorId, 'INVALID_TARGET', 'Target must be friendly');
    if (mode.includes('ENEMY'))
      rule(targetOwner !== actorId, 'INVALID_TARGET', 'Target must be an enemy');
    if (mode.endsWith('CREATURE')) rule(isCreature, 'INVALID_TARGET', 'Target must be a Creature');
  }

  private applyAction(action: GameAction): void {
    switch (action.type) {
      case 'PLAY_CARD':
        this.playCard(action);
        break;
      case 'ATTACK':
        this.attack(action);
        break;
      case 'HERO_ATTACK':
        this.heroAttack(action);
        break;
      case 'MOVE_CREATURE':
        this.moveCreature(action);
        break;
      case 'SWAP_CREATURES':
        this.swapCreatures(action);
        break;
      case 'USE_HERO_POWER':
        this.useHeroPower(action);
        break;
      case 'END_TURN':
        this.endTurn(action.actorId);
        break;
    }
  }

  private playCard(action: Extract<GameAction, { type: 'PLAY_CARD' }>): void {
    const side = this.side(action.actorId);
    const index = side.hand.findIndex((card) => card.instanceId === action.cardInstanceId);
    const card = side.hand[index]!;
    const definition = getCardDefinition(card.definitionId);
    side.hand.splice(index, 1);
    side.taika.current -= definition.cost;
    this.enqueueEvent({ type: 'TAIKA_CHANGED', actorId: side.playerId, amount: -definition.cost });
    this.enqueueEvent({
      type: 'CARD_PLAYED',
      actorId: side.playerId,
      sourceId: card.instanceId,
      cardDefinitionId: definition.id,
    });

    if (definition.type === 'CREATURE') {
      const creature = this.summonCreature(side, definition.id, action.position!, true);
      this.enqueueEvent({
        type: 'CREATURE_SUMMONED',
        actorId: side.playerId,
        sourceId: creature.instanceId,
        ...(action.targetId ? { targetId: action.targetId } : {}),
        cardDefinitionId: definition.id,
        position: clonePosition(creature.position),
      });
    } else if (definition.type === 'ACTION') {
      side.discard.push(definition.id);
      for (const effect of definition.effects) {
        this.enqueueEffect(effect, side.playerId, card.instanceId, action.targetId);
      }
    } else if (definition.type === 'WEAPON') {
      this.equipWeapon(side, definition.id);
    } else {
      const artifact = this.createArtifact(side, definition.id);
      this.enqueueEvent({
        type: 'ARTIFACT_PLAYED',
        actorId: side.playerId,
        sourceId: artifact.instanceId,
        cardDefinitionId: definition.id,
      });
    }
  }

  private attack(action: Extract<GameAction, { type: 'ATTACK' }>): void {
    const attacker = this.requireOwnedCreature(action.actorId, action.attackerId);
    attacker.combatActionUsed = true;
    this.reveal(attacker);
    this.enqueueEvent({
      type: 'ATTACK_STARTED',
      actorId: action.actorId,
      sourceId: attacker.instanceId,
      targetId: action.targetId,
    });
    const combat: DamageContext = { kind: 'CREATURE_COMBAT' };
    const target = this.findCreature(action.targetId);
    if (target) {
      this.applyDamage(target.instanceId, attacker.currentAttack, attacker.instanceId, combat);
      this.applyDamage(attacker.instanceId, target.currentAttack, target.instanceId, {
        ...combat,
        retaliation: true,
      });
      this.checkDeaths();
    } else {
      this.applyDamage(action.targetId, attacker.currentAttack, attacker.instanceId, combat);
      this.checkMatchEnd();
    }
  }

  /**
   * The Hero swings its Weapon.
   *
   * Ordering matters and is fixed: damage resolves, the attack is marked spent,
   * Durability is consumed, and only then may the Weapon break. Effects
   * triggered by the attack are queued before the break, so a Weapon that
   * breaks on its own final swing does not retroactively cancel what that swing
   * set off (§28).
   */
  private heroAttack(action: Extract<GameAction, { type: 'HERO_ATTACK' }>): void {
    const side = this.side(action.actorId);
    const weapon = side.hero.equippedWeapon!;
    const definition = this.weaponDefinition(weapon);
    const heroId = heroEntityId(action.actorId);
    // Snapshot the attack before resolution: the Weapon may be gone by the end
    // of it, but the damage it dealt still belongs to it.
    const context: DamageContext = {
      kind: 'HERO_WEAPON',
      range: definition.range,
      weaponId: weapon.instanceId,
      weaponDefinitionId: weapon.definitionId,
    };
    const damage = weapon.currentAttack;

    this.enqueueEvent({
      type: 'HERO_ATTACK_STARTED',
      actorId: action.actorId,
      sourceId: heroId,
      targetId: action.targetId,
      amount: damage,
      cardDefinitionId: weapon.definitionId,
    });

    const target = this.findCreature(action.targetId);
    this.applyDamage(action.targetId, damage, heroId, context);
    // Melee trades blows; reach does not. The defender's damage is retaliation,
    // not an attack of its own, so it costs the Creature nothing.
    if (target && definition.range === 'MELEE') {
      this.applyDamage(heroId, target.currentAttack, target.instanceId, {
        kind: 'CREATURE_COMBAT',
        retaliation: true,
        range: 'MELEE',
      });
    }

    side.hero.attacksUsedThisTurn += 1;
    this.spendDurability(side, 1);
    this.enqueueEvent({
      type: 'HERO_ATTACK_RESOLVED',
      actorId: action.actorId,
      sourceId: heroId,
      targetId: action.targetId,
      cardDefinitionId: weapon.definitionId,
    });
    // Breaking is the last thing the attack does, after its triggers are queued.
    this.breakWeaponIfSpent(side);
    this.checkDeaths();
    this.checkMatchEnd();
  }

  private moveCreature(action: Extract<GameAction, { type: 'MOVE_CREATURE' }>): void {
    const creature = this.requireOwnedCreature(action.actorId, action.creatureId);
    const side = this.side(action.actorId);
    const from = clonePosition(creature.position);
    setEntityAt(side.battlefield, from, null);
    setEntityAt(side.battlefield, action.destination, creature.instanceId);
    creature.position = clonePosition(action.destination);
    creature.combatActionUsed = true;
    this.enqueueEvent({
      type: 'CREATURE_MOVED',
      actorId: action.actorId,
      sourceId: creature.instanceId,
      from,
      to: clonePosition(action.destination),
    });
  }

  private swapCreatures(action: Extract<GameAction, { type: 'SWAP_CREATURES' }>): void {
    const first = this.requireOwnedCreature(action.actorId, action.firstCreatureId);
    const second = this.requireOwnedCreature(action.actorId, action.secondCreatureId);
    const firstPosition = clonePosition(first.position);
    const secondPosition = clonePosition(second.position);
    first.position = secondPosition;
    second.position = firstPosition;
    first.combatActionUsed = true;
    second.combatActionUsed = true;
    const board = this.side(action.actorId).battlefield;
    setEntityAt(board, first.position, first.instanceId);
    setEntityAt(board, second.position, second.instanceId);
    this.enqueueEvent({
      type: 'CREATURE_SWAPPED',
      actorId: action.actorId,
      sourceId: first.instanceId,
      targetId: second.instanceId,
      from: firstPosition,
      to: secondPosition,
    });
  }

  private useHeroPower(action: Extract<GameAction, { type: 'USE_HERO_POWER' }>): void {
    const side = this.side(action.actorId);
    const power = getHeroDefinition(side.hero.definitionId).power;
    side.taika.current -= power.cost;
    side.hero.powerUsedThisTurn = true;
    this.enqueueEvent({ type: 'TAIKA_CHANGED', actorId: side.playerId, amount: -power.cost });
    this.enqueueEvent({
      type: 'HERO_POWER_USED',
      actorId: side.playerId,
      sourceId: heroEntityId(side.playerId),
      ...(action.targetId ? { targetId: action.targetId } : {}),
    });
    this.enqueueEffect(power.effect, side.playerId, heroEntityId(side.playerId), action.targetId);
  }

  private endTurn(actorId: PlayerId): void {
    this.enqueueEvent({ type: 'TURN_ENDED', actorId });
    const nextId = this.opponentId(actorId);
    this.state.activePlayerId = nextId;
    this.state.turn += 1;
    const next = this.side(nextId);
    if (next.turnsStarted > 0) {
      next.taika.maximum = Math.min(next.taika.cap, next.taika.maximum + 1);
    }
    next.turnsStarted += 1;
    next.taika.current = next.taika.maximum;
    next.hero.powerUsedThisTurn = false;
    next.hero.attacksUsedThisTurn = 0;
    for (const creature of Object.values(next.creatures)) {
      creature.combatActionUsed = false;
      creature.summonedThisTurn = false;
      for (const status of creature.statuses) {
        if (status.duration !== undefined) status.duration -= 1;
      }
      creature.statuses = creature.statuses.filter(
        (status) => status.duration === undefined || status.duration > 0,
      );
    }
    this.drawCard(next, true);
    this.enqueueEvent({ type: 'TAIKA_CHANGED', actorId: nextId, amount: next.taika.current });
    this.enqueueEvent({ type: 'TURN_STARTED', actorId: nextId, amount: this.state.turn });
  }

  private drainQueue(): void {
    let resolutions = 0;
    while (this.queue.length > 0) {
      resolutions += 1;
      rule(resolutions <= 10_000, 'RESOLUTION_LIMIT', 'Effect queue exceeded its safety limit');
      const work = this.queue.shift()!;
      if (work.kind === 'EVENT') {
        const event: GameEvent = { ...work.event, sequence: this.state.nextEventSequence++ };
        this.currentEvents.push(event);
        this.discoverTriggers(event);
      } else {
        this.applyEffect(work.effect, work.ownerId, work.sourceId, work.playTargetId);
        this.checkDeaths();
        this.checkMatchEnd();
      }
    }
  }

  private discoverTriggers(event: GameEvent): void {
    const trigger =
      event.type === 'CREATURE_SUMMONED'
        ? 'ARRIVAL'
        : event.type === 'CREATURE_DIED'
          ? 'LAST_BREATH'
          : event.type === 'TURN_STARTED'
            ? 'TURN_STARTED'
            : event.type === 'TURN_ENDED'
              ? 'TURN_ENDED'
              : undefined;
    if (!trigger) return;

    if (
      (trigger === 'ARRIVAL' || trigger === 'LAST_BREATH') &&
      event.cardDefinitionId &&
      event.actorId
    ) {
      const definition = getCardDefinition(event.cardDefinitionId);
      if (definition.type === 'CREATURE') {
        for (const effect of definition.effects.filter(
          (candidate) => candidate.trigger === trigger,
        )) {
          this.enqueueEffect(effect.effect, event.actorId, event.sourceId, event.targetId);
        }
      }
      return;
    }

    if (event.actorId) {
      const side = this.side(event.actorId);
      const sources = [
        ...Object.values(side.creatures).map((creature) => ({
          id: creature.instanceId,
          definition: getCardDefinition(creature.definitionId),
        })),
        ...side.artifacts.map((artifact) => ({
          id: artifact.instanceId,
          definition: getCardDefinition(artifact.definitionId),
        })),
      ].sort((a, b) => a.id.localeCompare(b.id));
      for (const source of sources) {
        if (source.definition.type === 'ACTION') continue;
        for (const effect of source.definition.effects.filter(
          (candidate) => candidate.trigger === trigger,
        )) {
          this.enqueueEffect(effect.effect, side.playerId, source.id);
        }
      }
    }
  }

  private applyEffect(
    effect: Effect,
    ownerId: PlayerId,
    sourceId?: EntityId,
    playTargetId?: EntityId,
  ): void {
    switch (effect.type) {
      case 'DRAW_CARD':
        for (let count = 0; count < effect.amount; count += 1)
          this.drawCard(this.side(ownerId), true);
        return;
      case 'GAIN_TAIKA': {
        const side = this.side(ownerId);
        const before = side.taika.current;
        side.taika.current = Math.min(side.taika.cap, side.taika.current + effect.amount);
        this.enqueueEvent({
          type: 'TAIKA_CHANGED',
          actorId: ownerId,
          amount: side.taika.current - before,
        });
        return;
      }
      case 'SUMMON': {
        const side = this.side(ownerId);
        const position = effect.position ?? emptyPositions(side.battlefield)[0];
        if (!position || entityAt(side.battlefield, position)) return;
        const creature = this.summonCreature(side, effect.definitionId, position, true);
        this.enqueueEvent({
          type: 'CREATURE_SUMMONED',
          actorId: ownerId,
          sourceId: creature.instanceId,
          cardDefinitionId: effect.definitionId,
          position: clonePosition(position),
        });
        return;
      }
      default:
        break;
    }

    const targets = this.resolveTargets(effect.target, ownerId, sourceId, playTargetId);
    for (const targetId of targets) {
      switch (effect.type) {
        case 'DEAL_DAMAGE':
          this.applyDamage(targetId, effect.amount, sourceId, { kind: 'EFFECT' });
          break;
        case 'HEAL':
          this.applyHealing(targetId, effect.amount, sourceId);
          break;
        case 'BUFF': {
          const creature = this.findCreature(targetId);
          if (!creature) break;
          creature.currentAttack += effect.attack;
          creature.currentHealth += effect.health;
          creature.maxHealth += effect.health;
          break;
        }
        case 'APPLY_STATUS': {
          const creature = this.findCreature(targetId);
          if (!creature) break;
          const status = {
            id: this.nextId('status'),
            kind: effect.status,
            ...(effect.duration === undefined ? {} : { duration: effect.duration }),
          };
          creature.statuses.push(status);
          this.enqueueEvent({
            type: 'STATUS_APPLIED',
            actorId: ownerId,
            ...(sourceId ? { sourceId } : {}),
            targetId,
            reason: effect.status,
          });
          break;
        }
        case 'DESTROY': {
          const creature = this.findCreature(targetId);
          if (creature) {
            creature.currentHealth = 0;
            break;
          }
          // A Weapon may be named directly, so "destroy a Weapon" needs no
          // second effect type once such a card exists.
          const armed = this.state.playerOrder
            .map((id) => this.side(id))
            .find((candidate) => candidate.hero.equippedWeapon?.instanceId === targetId);
          if (armed) this.removeWeapon(armed, 'DESTROYED_BY_EFFECT');
          break;
        }
        case 'MOVE': {
          const creature = this.findCreature(targetId);
          if (!creature) break;
          const side = this.side(creature.ownerId);
          if (
            !isPositionValid(side.battlefield, effect.destination) ||
            entityAt(side.battlefield, effect.destination)
          )
            break;
          const from = clonePosition(creature.position);
          setEntityAt(side.battlefield, from, null);
          setEntityAt(side.battlefield, effect.destination, creature.instanceId);
          creature.position = clonePosition(effect.destination);
          this.enqueueEvent({
            type: 'CREATURE_MOVED',
            actorId: creature.ownerId,
            sourceId: creature.instanceId,
            from,
            to: clonePosition(effect.destination),
          });
          break;
        }
        default:
          break;
      }
    }
  }

  private resolveTargets(
    target: EffectTarget,
    ownerId: PlayerId,
    sourceId?: EntityId,
    playTargetId?: EntityId,
  ): EntityId[] {
    switch (target) {
      case 'PLAY_TARGET':
        return playTargetId ? [playTargetId] : [];
      case 'SELF':
        return sourceId ? [sourceId] : [];
      case 'OWNER_HERO':
        return [heroEntityId(ownerId)];
      case 'ENEMY_HERO':
        return [heroEntityId(this.opponentId(ownerId))];
      case 'RANDOM_ENEMY_CREATURE': {
        const creatures = Object.values(this.opponentSide(ownerId).creatures).sort(byInstanceId);
        return creatures.length ? [this.rng.pick(creatures).instanceId] : [];
      }
      case 'ALL_ENEMY_CREATURES':
        return Object.values(this.opponentSide(ownerId).creatures)
          .sort(byInstanceId)
          .map((creature) => creature.instanceId);
      case 'FRIENDLY_WEAPON': {
        const equipped = this.side(ownerId).hero.equippedWeapon;
        return equipped ? [equipped.instanceId] : [];
      }
      case 'ENEMY_WEAPON': {
        const equipped = this.opponentSide(ownerId).hero.equippedWeapon;
        return equipped ? [equipped.instanceId] : [];
      }
      case 'ADJACENT_FRIENDLY_CREATURES': {
        const source = sourceId ? this.findCreature(sourceId) : undefined;
        if (!source) return [];
        const side = this.side(ownerId);
        return adjacentPositions(side.battlefield, source.position)
          .map((position) => entityAt(side.battlefield, position))
          .filter((id): id is string => id !== null);
      }
    }
  }

  private applyDamage(
    targetId: EntityId,
    amount: number,
    sourceId?: EntityId,
    context?: DamageContext,
  ): void {
    if (amount <= 0) return;
    const creature = this.findCreature(targetId);
    if (creature) {
      const wardIndex = creature.statuses.findIndex((status) => status.kind === 'WARD');
      if (wardIndex >= 0) {
        creature.statuses.splice(wardIndex, 1);
        this.enqueueEvent({
          type: 'DAMAGE_PREVENTED',
          ...(sourceId ? { sourceId } : {}),
          targetId,
          amount,
          reason: 'WARD',
          ...(context ? { damage: context } : {}),
        });
        this.enqueueEvent({ type: 'STATUS_REMOVED', targetId, reason: 'WARD' });
        return;
      }
      const dealt = Math.min(amount, Math.max(0, creature.currentHealth));
      creature.currentHealth -= amount;
      this.enqueueEvent({
        type: 'DAMAGE_DEALT',
        ...(sourceId ? { sourceId } : {}),
        targetId,
        amount: dealt,
        ...(context ? { damage: context } : {}),
      });
      // Remember what struck the killing blow, so the death event can say so.
      if (creature.currentHealth <= 0 && context) this.lethalContext.set(targetId, context);
      this.applyLifesteal(sourceId, dealt);
      return;
    }
    const owner = this.ownerOf(targetId);
    if (!owner || targetId !== heroEntityId(owner)) return;
    const hero = this.side(owner).hero;
    const dealt = Math.min(amount, Math.max(0, hero.currentHealth));
    hero.currentHealth -= amount;
    this.enqueueEvent({
      type: 'DAMAGE_DEALT',
      ...(sourceId ? { sourceId } : {}),
      targetId,
      amount: dealt,
      ...(context ? { damage: context } : {}),
    });
    this.applyLifesteal(sourceId, dealt);
  }

  private applyLifesteal(sourceId: EntityId | undefined, amount: number): void {
    if (!sourceId || amount <= 0) return;
    const source = this.findCreature(sourceId);
    if (source && this.creatureDefinition(source).keywords.includes('LIFESTEAL')) {
      this.applyHealing(heroEntityId(source.ownerId), amount, sourceId);
    }
  }

  private applyHealing(targetId: EntityId, amount: number, sourceId?: EntityId): void {
    if (amount <= 0) return;
    const creature = this.findCreature(targetId);
    if (creature) {
      const restored = Math.min(amount, creature.maxHealth - creature.currentHealth);
      creature.currentHealth += restored;
      this.enqueueEvent({
        type: 'HEALING_RECEIVED',
        ...(sourceId ? { sourceId } : {}),
        targetId,
        amount: restored,
      });
      return;
    }
    const owner = this.ownerOf(targetId);
    if (!owner || targetId !== heroEntityId(owner)) return;
    const hero = this.side(owner).hero;
    const restored = Math.min(amount, hero.maxHealth - hero.currentHealth);
    hero.currentHealth += restored;
    this.enqueueEvent({
      type: 'HEALING_RECEIVED',
      ...(sourceId ? { sourceId } : {}),
      targetId,
      amount: restored,
    });
  }

  private checkDeaths(): void {
    const dead = this.state.playerOrder
      .flatMap((playerId) => Object.values(this.side(playerId).creatures))
      .filter((creature) => creature.currentHealth <= 0)
      .sort(byInstanceId);
    for (const creature of dead) {
      const side = this.side(creature.ownerId);
      if (!side.creatures[creature.instanceId]) continue;
      setEntityAt(side.battlefield, creature.position, null);
      delete side.creatures[creature.instanceId];
      side.discard.push(creature.definitionId);
      const killedBy = this.lethalContext.get(creature.instanceId);
      this.lethalContext.delete(creature.instanceId);
      this.enqueueEvent({
        type: 'CREATURE_DIED',
        actorId: creature.ownerId,
        sourceId: creature.instanceId,
        cardDefinitionId: creature.definitionId,
        position: clonePosition(creature.position),
        ...(killedBy ? { damage: killedBy } : {}),
      });
    }
  }

  private checkMatchEnd(): void {
    if (this.state.phase === 'FINISHED') return;
    const defeated = this.state.playerOrder.filter((id) => this.side(id).hero.currentHealth <= 0);
    if (!defeated.length) return;
    const winner = this.state.playerOrder.find((id) => !defeated.includes(id));
    this.state.phase = 'FINISHED';
    if (winner) this.state.winnerId = winner;
    this.enqueueEvent({
      type: 'MATCH_ENDED',
      ...(winner ? { winnerId: winner } : {}),
      reason: winner ? 'HERO_DEFEATED' : 'DRAW',
    });
  }

  private drawCard(side: MatchSide, emit: boolean): void {
    const definitionId = side.deck.shift();
    if (!definitionId) {
      side.fatigue += 1;
      this.applyDamage(heroEntityId(side.playerId), side.fatigue, undefined, { kind: 'FATIGUE' });
      this.checkMatchEnd();
      return;
    }
    if (side.hand.length >= 10) {
      side.discard.push(definitionId);
      if (emit)
        this.enqueueEvent({
          type: 'CARD_DISCARDED',
          actorId: side.playerId,
          cardDefinitionId: definitionId,
          reason: 'HAND_FULL',
        });
      return;
    }
    const card = { instanceId: this.nextId('card'), definitionId };
    side.hand.push(card);
    if (emit)
      this.enqueueEvent({
        type: 'CARD_DRAWN',
        actorId: side.playerId,
        sourceId: card.instanceId,
        cardDefinitionId: definitionId,
      });
  }

  private addCardToHand(side: MatchSide, definitionId: string): void {
    getCardDefinition(definitionId);
    side.hand.push({ instanceId: this.nextId('card'), definitionId });
  }

  private summonCreature(
    side: MatchSide,
    definitionId: string,
    position: Position,
    summonedThisTurn: boolean,
  ): CreatureInstance {
    const definition = getCardDefinition(definitionId);
    if (definition.type !== 'CREATURE') throw new Error(`${definitionId} is not a Creature`);
    if (!isPositionValid(side.battlefield, position) || entityAt(side.battlefield, position)) {
      throw new Error('Invalid initial Creature position');
    }
    const creature: CreatureInstance = {
      instanceId: this.nextId('creature'),
      definitionId,
      ownerId: side.playerId,
      currentAttack: definition.attack,
      currentHealth: definition.health,
      maxHealth: definition.health,
      position: clonePosition(position),
      summonedThisTurn,
      combatActionUsed: false,
      statuses: definition.keywords.includes('WARD')
        ? [{ id: this.nextId('status'), kind: 'WARD' }]
        : [],
    };
    side.creatures[creature.instanceId] = creature;
    setEntityAt(side.battlefield, position, creature.instanceId);
    return creature;
  }

  /**
   * Puts a Weapon in the Hero's one slot, displacing whatever was there.
   *
   * Equipping never touches the Hero's attack allowance: a Weapon swapped in
   * after the Hero has swung does not buy a second swing, and one equipped
   * before still allows the first (§7, §29, §47).
   */
  private equipWeapon(side: MatchSide, definitionId: string): WeaponInstance {
    const definition = this.weaponDefinitionById(definitionId);
    const previous = side.hero.equippedWeapon;
    if (previous) this.removeWeapon(side, 'REPLACED');
    const weapon: WeaponInstance = {
      instanceId: this.nextId('weapon'),
      definitionId,
      ownerId: side.playerId,
      currentAttack: definition.attack,
      currentDurability: definition.durability,
      maxDurability: definition.durability,
      statuses: [],
    };
    side.hero.equippedWeapon = weapon;
    this.enqueueEvent({
      type: 'WEAPON_EQUIPPED',
      actorId: side.playerId,
      sourceId: weapon.instanceId,
      cardDefinitionId: definitionId,
    });
    return weapon;
  }

  /** Takes the Weapon off the Hero, recording why it left. */
  private removeWeapon(side: MatchSide, reason: WeaponRemovalReason): void {
    const weapon = side.hero.equippedWeapon;
    if (!weapon) return;
    side.hero.equippedWeapon = null;
    side.discard.push(weapon.definitionId);
    const type =
      reason === 'BROKEN'
        ? 'WEAPON_BROKEN'
        : reason === 'REPLACED'
          ? 'WEAPON_REPLACED'
          : 'WEAPON_DESTROYED';
    this.enqueueEvent({
      type,
      actorId: side.playerId,
      sourceId: weapon.instanceId,
      cardDefinitionId: weapon.definitionId,
      reason,
    });
  }

  /** Spends Durability. Breaking is deliberately a separate, later step. */
  private spendDurability(side: MatchSide, amount: number): void {
    const weapon = side.hero.equippedWeapon;
    if (!weapon || amount === 0) return;
    weapon.currentDurability -= amount;
    this.enqueueEvent({
      type: 'WEAPON_DURABILITY_CHANGED',
      actorId: side.playerId,
      sourceId: weapon.instanceId,
      cardDefinitionId: weapon.definitionId,
      amount: -amount,
    });
  }

  private breakWeaponIfSpent(side: MatchSide): void {
    const weapon = side.hero.equippedWeapon;
    if (weapon && weapon.currentDurability <= 0) this.removeWeapon(side, 'BROKEN');
  }

  private weaponDefinitionById(definitionId: string): WeaponDefinition {
    const definition = getCardDefinition(definitionId);
    if (definition.type !== 'WEAPON') throw new Error(`${definitionId} is not a Weapon`);
    return definition;
  }

  private weaponDefinition(weapon: WeaponInstance): WeaponDefinition {
    return this.weaponDefinitionById(weapon.definitionId);
  }

  private createArtifact(side: MatchSide, definitionId: string) {
    const definition = getCardDefinition(definitionId);
    if (definition.type !== 'ARTIFACT') throw new Error(`${definitionId} is not an Artifact`);
    const artifact = {
      instanceId: this.nextId('artifact'),
      definitionId,
      ownerId: side.playerId,
      durability: definition.durability,
    };
    side.artifacts.push(artifact);
    return artifact;
  }

  private isGuardProtected(target: CreatureInstance): boolean {
    const side = this.side(target.ownerId);
    return adjacentPositions(side.battlefield, target.position).some((position) => {
      const id = entityAt(side.battlefield, position);
      if (!id) return false;
      const creature = side.creatures[id];
      return creature && this.creatureDefinition(creature).keywords.includes('GUARD');
    });
  }

  private hasLivingGuard(side: MatchSide): boolean {
    return Object.values(side.creatures).some(
      (creature) =>
        creature.currentHealth > 0 && this.creatureDefinition(creature).keywords.includes('GUARD'),
    );
  }

  private isHidden(creature: CreatureInstance): boolean {
    const explicitlyHidden = creature.statuses.some((status) => status.kind === 'HIDDEN');
    const revealed = creature.statuses.some((status) => status.kind === 'REVEALED');
    return (
      explicitlyHidden ||
      (this.creatureDefinition(creature).keywords.includes('HIDDEN') && !revealed)
    );
  }

  private reveal(creature: CreatureInstance): void {
    const definition = this.creatureDefinition(creature);
    if (
      !definition.keywords.includes('HIDDEN') &&
      !creature.statuses.some((status) => status.kind === 'HIDDEN')
    )
      return;
    // Definition keywords are immutable. An explicit runtime marker suppresses static Hidden after reveal.
    creature.statuses = creature.statuses.filter((status) => status.kind !== 'HIDDEN');
    creature.statuses.push({ id: this.nextId('status'), kind: 'REVEALED' });
  }

  private targetsForMode(actorId: PlayerId, mode: TargetMode): EntityId[] {
    if (mode === 'NONE') return [];
    const friendly = this.side(actorId);
    const enemy = this.opponentSide(actorId);
    const creatureIds = (side: MatchSide) =>
      Object.values(side.creatures)
        .filter((creature) => !this.isHidden(creature))
        .sort(byInstanceId)
        .map((creature) => creature.instanceId);
    if (mode === 'FRIENDLY_CHARACTER') return [heroEntityId(actorId), ...creatureIds(friendly)];
    if (mode === 'ENEMY_CHARACTER') return [heroEntityId(enemy.playerId), ...creatureIds(enemy)];
    if (mode === 'ANY_CHARACTER')
      return [
        heroEntityId(actorId),
        ...creatureIds(friendly),
        heroEntityId(enemy.playerId),
        ...creatureIds(enemy),
      ];
    if (mode === 'FRIENDLY_CREATURE') return creatureIds(friendly);
    return creatureIds(enemy);
  }

  private side(playerId: PlayerId): MatchSide {
    return this.state.sides[playerId]!;
  }

  private opponentId(playerId: PlayerId): PlayerId {
    return this.state.playerOrder[0] === playerId
      ? this.state.playerOrder[1]
      : this.state.playerOrder[0];
  }

  private opponentSide(playerId: PlayerId): MatchSide {
    return this.side(this.opponentId(playerId));
  }

  private ownerOf(entityId: EntityId): PlayerId | undefined {
    const heroOwner = this.state.playerOrder.find((id) => heroEntityId(id) === entityId);
    if (heroOwner) return heroOwner;
    return this.findCreature(entityId)?.ownerId;
  }

  private findCreature(entityId: EntityId): CreatureInstance | undefined {
    for (const playerId of this.state.playerOrder) {
      const creature = this.side(playerId).creatures[entityId];
      if (creature) return creature;
    }
    return undefined;
  }

  private requireOwnedCreature(playerId: PlayerId, entityId: EntityId): CreatureInstance {
    const creature = this.side(playerId).creatures[entityId];
    rule(creature, 'CREATURE_NOT_CONTROLLED', 'Creature is not controlled by the acting side');
    return creature;
  }

  private creatureDefinition(creature: CreatureInstance): CreatureDefinition {
    const definition = getCardDefinition(creature.definitionId);
    if (definition.type !== 'CREATURE')
      throw new Error('Creature instance references a non-Creature definition');
    return definition;
  }

  private enqueueEvent(event: EventDraft): void {
    this.queue.push({ kind: 'EVENT', event });
  }

  private enqueueEffect(
    effect: Effect,
    ownerId: PlayerId,
    sourceId?: EntityId,
    playTargetId?: EntityId,
  ): void {
    this.queue.push({
      kind: 'EFFECT',
      effect,
      ownerId,
      ...(sourceId ? { sourceId } : {}),
      ...(playTargetId ? { playTargetId } : {}),
    });
  }

  private nextId(prefix: string): string {
    return `${prefix}_${this.state.nextInstanceId++}`;
  }
}

function cardTargetMode(definition: CardDefinition): TargetMode {
  if (definition.type === 'ACTION') return definition.targetMode;
  if (definition.type === 'CREATURE') {
    const targeted = definition.effects.find(
      (entry) =>
        entry.trigger === 'ARRIVAL' &&
        entry.effect.type !== 'DRAW_CARD' &&
        'target' in entry.effect &&
        entry.effect.target === 'PLAY_TARGET',
    );
    if (!targeted || !('target' in targeted.effect)) return 'NONE';
    if (targeted.effect.type === 'HEAL' || targeted.effect.type === 'BUFF')
      return 'FRIENDLY_CHARACTER';
    return 'ENEMY_CHARACTER';
  }
  return 'NONE';
}

function validateSetup(setup: MatchSetup): void {
  if (setup.players.length !== 2) throw new Error('A match currently requires exactly two sides');
  if (setup.players[0].playerId === setup.players[1].playerId)
    throw new Error('Player IDs must be unique');
  if (!Number.isInteger(setup.scenario.battlefield.width) || setup.scenario.battlefield.width < 1) {
    throw new Error('Scenario battlefield width must be a positive integer');
  }
  for (const player of setup.players) {
    for (const cardId of player.deck) getCardDefinition(cardId);
  }
}

function byInstanceId(first: CreatureInstance, second: CreatureInstance): number {
  return first.instanceId.localeCompare(second.instanceId, undefined, { numeric: true });
}
