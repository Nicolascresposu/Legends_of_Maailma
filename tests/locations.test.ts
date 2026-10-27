import { describe, expect, it } from 'vitest';
import {
  CARD_DEFINITIONS,
  getCardDefinition,
  validateLocationDefinition,
} from '@maailma/card-definitions';
import { BasicAIController, heroEntityId, type GameEngine } from '@maailma/game-engine';
import type { GameAction, LocationDefinition, Position } from '@maailma/game-model';
import { creatureId, makeEngine } from './helpers.js';

function giveCard(engine: GameEngine, playerId: 'a' | 'b', definitionId: string): string {
  const side = engine.state.sides[playerId]!;
  const instanceId = `given_${definitionId}_${side.hand.length}`;
  side.hand.push({ instanceId, definitionId });
  return instanceId;
}

/** Plays a Location from `playerId`'s hand onto `position` and returns its instance id. */
function place(
  engine: GameEngine,
  playerId: 'a' | 'b',
  definitionId: string,
  position: Position,
): string {
  const cardInstanceId = giveCard(engine, playerId, definitionId);
  const result = engine.dispatch({
    type: 'PLAY_CARD',
    actorId: playerId,
    cardInstanceId,
    position,
  });
  expect(result.ok, `${definitionId} should be playable: ${result.error?.message}`).toBe(true);
  return Object.values(engine.state.sides[playerId]!.locations).find(
    (location) => location.definitionId === definitionId,
  )!.instanceId;
}

const location = (engine: GameEngine, playerId: 'a' | 'b', id: string) =>
  engine.state.sides[playerId]!.locations[id];

/** Ends a's turn and then b's, so it is a's turn again. */
function passRound(engine: GameEngine): void {
  expect(engine.dispatch({ type: 'END_TURN', actorId: 'a' }).ok).toBe(true);
  expect(engine.dispatch({ type: 'END_TURN', actorId: 'b' }).ok).toBe(true);
}

const activate = (engine: GameEngine, locationId: string, targetId?: string) =>
  engine.dispatch({
    type: 'ACTIVATE_LOCATION',
    actorId: 'a',
    locationId,
    ...(targetId ? { targetId } : {}),
  });

/** Enough to draw from every turn, so no Hero takes fatigue damage. */
const WOLVES = Array<string>(20).fill('wolf');

const FRONT_0: Position = { row: 'FRONT', column: 0 };
const FRONT_1: Position = { row: 'FRONT', column: 1 };
const BACK_1: Position = { row: 'BACK', column: 1 };

describe('Location definitions', () => {
  it('accepts every shipped Location', () => {
    const shipped = Object.values(CARD_DEFINITIONS).filter((card) => card.type === 'LOCATION');
    expect(shipped.map((card) => card.id).sort()).toEqual([
      'border_watchtower',
      'healing_spring',
      'war_camp',
    ]);
    for (const card of shipped) {
      expect(validateLocationDefinition(card as LocationDefinition)).toEqual([]);
    }
  });

  it('rejects Locations whose measures disagree with what they do', () => {
    const tower = getCardDefinition('border_watchtower') as LocationDefinition;
    const spring = getCardDefinition('healing_spring') as LocationDefinition;
    const bare = { ...tower };
    delete bare.durability;
    delete bare.activation;
    expect(validateLocationDefinition(bare)).toHaveLength(1);
    expect(validateLocationDefinition({ ...tower, activation: undefined })).toHaveLength(1);
    expect(validateLocationDefinition({ ...spring, activation: tower.activation })).toHaveLength(1);
    expect(validateLocationDefinition({ ...tower, durability: 0 })).toHaveLength(1);
    expect(validateLocationDefinition({ ...spring, duration: 0 })).toHaveLength(1);
    expect(
      validateLocationDefinition({
        ...tower,
        activation: { ...tower.activation!, targetMode: 'NONE' },
      }),
    ).toHaveLength(1);
    expect(
      validateLocationDefinition({
        ...spring,
        effects: [{ trigger: 'ARRIVAL', effect: { type: 'DRAW_CARD', amount: 1 } }],
      }),
    ).toHaveLength(1);
  });
});

describe('Placing a Location', () => {
  it('takes a tile, spends Taika and announces itself', () => {
    const engine = makeEngine({ taika: 5 });
    const cardInstanceId = giveCard(engine, 'a', 'border_watchtower');
    const result = engine.dispatch({
      type: 'PLAY_CARD',
      actorId: 'a',
      cardInstanceId,
      position: FRONT_0,
    });
    expect(result.ok).toBe(true);
    const side = engine.state.sides.a!;
    const [placed] = Object.values(side.locations);
    expect(placed).toMatchObject({
      definitionId: 'border_watchtower',
      position: FRONT_0,
      currentDurability: 3,
      maxDurability: 3,
      closed: false,
    });
    expect(placed!.turnsRemaining).toBeUndefined();
    expect(side.battlefield.slots.FRONT[0]).toBe(placed!.instanceId);
    expect(side.taika.current).toBe(3);
    expect(side.hand.some((card) => card.instanceId === cardInstanceId)).toBe(false);
    const placedEvent = result.events.find((event) => event.type === 'LOCATION_PLACED');
    expect(placedEvent).toMatchObject({ sourceId: placed!.instanceId, position: FRONT_0 });
  });

  it('needs an empty tile of its own, and fills it', () => {
    const engine = makeEngine({ a: [{ definitionId: 'wolf', position: FRONT_0 }] });
    const cardInstanceId = giveCard(engine, 'a', 'war_camp');
    const without = engine.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId });
    expect(without.error?.code).toBe('POSITION_REQUIRED');
    const occupied = engine.dispatch({
      type: 'PLAY_CARD',
      actorId: 'a',
      cardInstanceId,
      position: FRONT_0,
    });
    expect(occupied.error?.code).toBe('TILE_OCCUPIED');
    const offered = engine
      .getLegalActions('a')
      .filter((action) => action.type === 'PLAY_CARD' && action.cardInstanceId === cardInstanceId);
    expect(offered).toHaveLength(5);

    place(engine, 'a', 'border_watchtower', FRONT_1);
    const rat = giveCard(engine, 'a', 'giant_rat');
    const blocked = engine.dispatch({
      type: 'PLAY_CARD',
      actorId: 'a',
      cardInstanceId: rat,
      position: FRONT_1,
    });
    expect(blocked.error?.code).toBe('TILE_OCCUPIED');
  });

  it('starts a duration-only Location with its hourglass full and nothing to activate', () => {
    const engine = makeEngine();
    const id = place(engine, 'a', 'healing_spring', FRONT_0);
    expect(location(engine, 'a', id)).toMatchObject({ turnsRemaining: 3, closed: false });
    expect(location(engine, 'a', id)!.currentDurability).toBeUndefined();
    expect(engine.getLegalActions('a').some((action) => action.type === 'ACTIVATE_LOCATION')).toBe(
      false,
    );
    expect(activate(engine, id).error?.code).toBe('NOT_ACTIVATABLE');
  });
});

describe('Activating a Location', () => {
  it('resolves its activation, spends Durability and closes', () => {
    const engine = makeEngine();
    const id = place(engine, 'a', 'border_watchtower', FRONT_0);
    const enemyHero = heroEntityId('b');
    const offered = engine
      .getLegalActions('a')
      .filter((action) => action.type === 'ACTIVATE_LOCATION');
    expect(offered).toContainEqual({
      type: 'ACTIVATE_LOCATION',
      actorId: 'a',
      locationId: id,
      targetId: enemyHero,
    });

    const result = activate(engine, id, enemyHero);
    expect(result.ok).toBe(true);
    expect(engine.state.sides.b!.hero.currentHealth).toBe(29);
    expect(location(engine, 'a', id)).toMatchObject({ currentDurability: 2, closed: true });
    expect(result.events.map((event) => event.type)).toEqual([
      'LOCATION_ACTIVATED',
      'LOCATION_DURABILITY_CHANGED',
      'DAMAGE_DEALT',
    ]);
    expect(result.events[2]).toMatchObject({ sourceId: id, targetId: enemyHero });
  });

  it('stays closed through the opponent turn and opens on its owner next turn', () => {
    const engine = makeEngine();
    const id = place(engine, 'a', 'border_watchtower', FRONT_0);
    expect(activate(engine, id, heroEntityId('b')).ok).toBe(true);

    expect(activate(engine, id, heroEntityId('b')).error?.code).toBe('LOCATION_CLOSED');
    expect(engine.getLegalActions('a').some((action) => action.type === 'ACTIVATE_LOCATION')).toBe(
      false,
    );

    expect(engine.dispatch({ type: 'END_TURN', actorId: 'a' }).ok).toBe(true);
    expect(location(engine, 'a', id)!.closed).toBe(true);
    expect(engine.dispatch({ type: 'END_TURN', actorId: 'b' }).ok).toBe(true);
    expect(location(engine, 'a', id)!.closed).toBe(false);
    expect(activate(engine, id, heroEntityId('b')).ok).toBe(true);
  });

  it('cannot be activated by the opponent', () => {
    const engine = makeEngine();
    const id = place(engine, 'a', 'border_watchtower', FRONT_0);
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    const result = engine.dispatch({
      type: 'ACTIVATE_LOCATION',
      actorId: 'b',
      locationId: id,
      targetId: heroEntityId('a'),
    });
    expect(result.error?.code).toBe('LOCATION_NOT_CONTROLLED');
  });

  it('checks the activation target the way an Action checks its own', () => {
    const engine = makeEngine({ a: [{ definitionId: 'wolf', position: FRONT_1 }] });
    const id = place(engine, 'a', 'border_watchtower', FRONT_0);
    expect(activate(engine, id).error?.code).toBe('TARGET_REQUIRED');
    expect(activate(engine, id, creatureId(engine, 'a', 'wolf')).error?.code).toBe(
      'INVALID_TARGET',
    );
    expect(location(engine, 'a', id)).toMatchObject({ currentDurability: 3, closed: false });
  });

  it('crumbles once its last point of Durability is spent, freeing its tile', () => {
    const engine = makeEngine({ deckA: WOLVES, deckB: WOLVES });
    const id = place(engine, 'a', 'border_watchtower', FRONT_0);
    expect(activate(engine, id, heroEntityId('b')).ok).toBe(true);
    passRound(engine);
    expect(activate(engine, id, heroEntityId('b')).ok).toBe(true);
    passRound(engine);
    const last = activate(engine, id, heroEntityId('b'));
    expect(last.ok).toBe(true);
    expect(engine.state.sides.b!.hero.currentHealth).toBe(27);
    // The shot lands before the tower falls.
    expect(last.events.map((event) => event.type)).toEqual([
      'LOCATION_ACTIVATED',
      'LOCATION_DURABILITY_CHANGED',
      'DAMAGE_DEALT',
      'LOCATION_REMOVED',
    ]);
    expect(last.events[3]).toMatchObject({ sourceId: id, reason: 'SPENT', position: FRONT_0 });
    const side = engine.state.sides.a!;
    expect(side.locations[id]).toBeUndefined();
    expect(side.battlefield.slots.FRONT[0]).toBeNull();
    expect(side.discard).toContain('border_watchtower');
  });

  it('reaches adjacent friendly Creatures from its tile, and only Creatures', () => {
    const engine = makeEngine({
      a: [
        { definitionId: 'wolf', position: FRONT_0 },
        { definitionId: 'giant_rat', position: BACK_1 },
      ],
    });
    const camp = place(engine, 'a', 'war_camp', FRONT_1);
    place(engine, 'a', 'border_watchtower', { row: 'FRONT', column: 2 });
    expect(activate(engine, camp).ok).toBe(true);
    const creatures = engine.state.sides.a!.creatures;
    expect(creatures[creatureId(engine, 'a', 'wolf')]).toMatchObject({
      currentAttack: 3,
      currentHealth: 2,
    });
    expect(creatures[creatureId(engine, 'a', 'giant_rat')]).toMatchObject({
      currentAttack: 2,
      currentHealth: 2,
    });
  });
});

describe('A Location duration', () => {
  it('counts down at the start of its owner turns, and expires before acting', () => {
    const engine = makeEngine({ deckA: WOLVES, deckB: WOLVES });
    const id = place(engine, 'a', 'healing_spring', FRONT_0);
    engine.state.sides.a!.hero.currentHealth = 20;

    // The opponent's turn does not run the hourglass down.
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    expect(location(engine, 'a', id)!.turnsRemaining).toBe(3);

    const second = engine.dispatch({ type: 'END_TURN', actorId: 'b' });
    expect(location(engine, 'a', id)!.turnsRemaining).toBe(2);
    expect(second.events.some((event) => event.type === 'LOCATION_DURATION_CHANGED')).toBe(true);
    expect(engine.state.sides.a!.hero.currentHealth).toBe(22);

    passRound(engine);
    expect(location(engine, 'a', id)!.turnsRemaining).toBe(1);
    expect(engine.state.sides.a!.hero.currentHealth).toBe(24);

    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    const expiring = engine.dispatch({ type: 'END_TURN', actorId: 'b' });
    expect(location(engine, 'a', id)).toBeUndefined();
    expect(engine.state.sides.a!.battlefield.slots.FRONT[0]).toBeNull();
    expect(expiring.events.find((event) => event.type === 'LOCATION_REMOVED')).toMatchObject({
      sourceId: id,
      reason: 'EXPIRED',
    });
    // Gone before the turn started, so it heals no more.
    expect(engine.state.sides.a!.hero.currentHealth).toBe(24);
  });

  it('expires a Location with both measures even with Durability to spare', () => {
    const engine = makeEngine();
    const id = place(engine, 'a', 'war_camp', FRONT_0);
    passRound(engine);
    passRound(engine);
    expect(location(engine, 'a', id)).toMatchObject({ turnsRemaining: 1, currentDurability: 2 });
    passRound(engine);
    expect(location(engine, 'a', id)).toBeUndefined();
  });
});

describe('A Location in the battlefield', () => {
  it('cannot be attacked or targeted', () => {
    const engine = makeEngine({ b: [{ definitionId: 'wolf', position: FRONT_0 }] });
    const id = place(engine, 'a', 'border_watchtower', FRONT_0);
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    const wolf = creatureId(engine, 'b', 'wolf');
    const attack = engine.dispatch({
      type: 'ATTACK',
      actorId: 'b',
      attackerId: wolf,
      targetId: id,
    });
    expect(attack.error?.code).toBe('INVALID_TARGET');
    const firebolt = giveCard(engine, 'b', 'firebolt');
    const spell = engine.dispatch({
      type: 'PLAY_CARD',
      actorId: 'b',
      cardInstanceId: firebolt,
      targetId: id,
    });
    expect(spell.error?.code).toBe('INVALID_TARGET');
    const legal = engine.getLegalActions('b');
    expect(legal.some((action) => 'targetId' in action && action.targetId === id)).toBe(false);
  });

  it('does not shield the Creature behind it from melee', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'giant_rat', position: { row: 'BACK', column: 0 } }],
      b: [{ definitionId: 'wolf', position: FRONT_0 }],
    });
    place(engine, 'a', 'border_watchtower', FRONT_0);
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    const attack = engine.dispatch({
      type: 'ATTACK',
      actorId: 'b',
      attackerId: creatureId(engine, 'b', 'wolf'),
      targetId: creatureId(engine, 'a', 'giant_rat'),
    });
    expect(attack.ok, attack.error?.message).toBe(true);
  });

  it('replays to the same state', () => {
    const engine = makeEngine({ seed: 'locations', deckA: ['wolf'], deckB: ['wolf'] });
    const id = place(engine, 'a', 'war_camp', FRONT_0);
    expect(activate(engine, id).ok).toBe(true);
    passRound(engine);
    expect(activate(engine, id).ok).toBe(true);

    const replayed = makeEngine({ seed: 'locations', deckA: ['wolf'], deckB: ['wolf'] });
    // Hand cards given by the test are not actions, so give them again.
    giveCard(replayed, 'a', 'war_camp');
    for (const action of engine.state.actionLog) {
      expect(replayed.dispatch(action as GameAction).ok).toBe(true);
    }
    expect(replayed.state.sides).toEqual(engine.state.sides);
  });

  it('is activated by the basic AI', () => {
    const engine = makeEngine();
    place(engine, 'a', 'border_watchtower', FRONT_0);
    engine.state.sides.a!.hand = [];
    const choice = new BasicAIController().chooseAction(engine, 'a');
    expect(choice?.type).toBe('ACTIVATE_LOCATION');
  });
});
