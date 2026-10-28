import { describe, expect, it } from 'vitest';
import { creatureId, makeEngine } from './helpers.js';

describe('movement and swapping', () => {
  it('moves one orthogonal tile and consumes the combat action', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'chicken', position: { row: 'FRONT', column: 0 } }],
    });
    const id = creatureId(engine, 'a', 'chicken');
    const result = engine.dispatch({
      type: 'MOVE_CREATURE',
      actorId: 'a',
      creatureId: id,
      destination: { row: 'BACK', column: 0 },
    });
    expect(result.ok).toBe(true);
    expect(engine.state.sides.a!.creatures[id]!.position).toEqual({ row: 'BACK', column: 0 });
    expect(engine.state.sides.a!.creatures[id]!.combatActionUsed).toBe(true);
  });

  it('rejects diagonal movement and occupied destinations', () => {
    const engine = makeEngine({
      a: [
        { definitionId: 'chicken', position: { row: 'FRONT', column: 0 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 1 } },
      ],
    });
    const wolf = creatureId(engine, 'a', 'chicken');
    expect(
      engine.dispatch({
        type: 'MOVE_CREATURE',
        actorId: 'a',
        creatureId: wolf,
        destination: { row: 'BACK', column: 1 },
      }).error?.code,
    ).toBe('NOT_ADJACENT');
    expect(
      engine.dispatch({
        type: 'MOVE_CREATURE',
        actorId: 'a',
        creatureId: wolf,
        destination: { row: 'FRONT', column: 1 },
      }).error?.code,
    ).toBe('TILE_OCCUPIED');
  });

  it('prevents a freshly summoned normal Creature from moving', () => {
    const engine = makeEngine({ deckA: Array(6).fill('chicken') });
    const card = engine.state.sides.a!.hand[0]!;
    expect(
      engine.dispatch({
        type: 'PLAY_CARD',
        actorId: 'a',
        cardInstanceId: card.instanceId,
        position: { row: 'FRONT', column: 0 },
      }).ok,
    ).toBe(true);
    const wolf = creatureId(engine, 'a', 'chicken');
    expect(
      engine.dispatch({
        type: 'MOVE_CREATURE',
        actorId: 'a',
        creatureId: wolf,
        destination: { row: 'BACK', column: 0 },
      }).error?.code,
    ).toBe('SUMMONING_SICKNESS');
  });

  it('swaps adjacent Creatures and exhausts both', () => {
    const engine = makeEngine({
      a: [
        { definitionId: 'chicken', position: { row: 'FRONT', column: 0 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 1 } },
      ],
    });
    const wolf = creatureId(engine, 'a', 'chicken');
    const bear = creatureId(engine, 'a', 'brown_bear');
    const result = engine.dispatch({
      type: 'SWAP_CREATURES',
      actorId: 'a',
      firstCreatureId: wolf,
      secondCreatureId: bear,
    });
    expect(result.ok).toBe(true);
    expect(engine.state.sides.a!.creatures[wolf]!.position.column).toBe(1);
    expect(engine.state.sides.a!.creatures[bear]!.position.column).toBe(0);
    expect(engine.state.sides.a!.creatures[wolf]!.combatActionUsed).toBe(true);
    expect(engine.state.sides.a!.creatures[bear]!.combatActionUsed).toBe(true);
  });

  it('rejects nonadjacent, exhausted, and newly summoned swap participants', () => {
    const nonadjacent = makeEngine({
      a: [
        { definitionId: 'chicken', position: { row: 'FRONT', column: 0 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 2 } },
      ],
    });
    expect(
      nonadjacent.dispatch({
        type: 'SWAP_CREATURES',
        actorId: 'a',
        firstCreatureId: creatureId(nonadjacent, 'a', 'chicken'),
        secondCreatureId: creatureId(nonadjacent, 'a', 'brown_bear'),
      }).error?.code,
    ).toBe('NOT_ADJACENT');

    const exhausted = makeEngine({
      a: [
        { definitionId: 'chicken', position: { row: 'FRONT', column: 0 } },
        { definitionId: 'brown_bear', position: { row: 'BACK', column: 0 } },
      ],
    });
    const wolf = creatureId(exhausted, 'a', 'chicken');
    const bear = creatureId(exhausted, 'a', 'brown_bear');
    exhausted.state.sides.a!.creatures[wolf]!.combatActionUsed = true;
    expect(
      exhausted.dispatch({
        type: 'SWAP_CREATURES',
        actorId: 'a',
        firstCreatureId: wolf,
        secondCreatureId: bear,
      }).error?.code,
    ).toBe('ACTION_USED');
    exhausted.state.sides.a!.creatures[wolf]!.combatActionUsed = false;
    exhausted.state.sides.a!.creatures[bear]!.summonedThisTurn = true;
    expect(
      exhausted.dispatch({
        type: 'SWAP_CREATURES',
        actorId: 'a',
        firstCreatureId: wolf,
        secondCreatureId: bear,
      }).error?.code,
    ).toBe('SUMMONING_SICKNESS');
  });
});
