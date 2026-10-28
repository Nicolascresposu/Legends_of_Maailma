import { describe, expect, it } from 'vitest';
import { heroEntityId } from '@maailma/game-engine';
import { creatureId, makeEngine } from './helpers.js';

describe('turns, Taika, and Hero Powers', () => {
  it('increments, refills, and caps Taika at ten', () => {
    const engine = makeEngine({
      taika: 9,
      deckA: Array(12).fill('chicken'),
      deckB: Array(12).fill('chicken'),
    });
    engine.state.sides.a!.taika.current = 0;
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    expect(engine.state.sides.b!.taika).toMatchObject({ current: 9, maximum: 9 });
    engine.dispatch({ type: 'END_TURN', actorId: 'b' });
    expect(engine.state.sides.a!.taika).toMatchObject({ current: 10, maximum: 10 });
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    expect(engine.state.sides.b!.taika.maximum).toBe(10);
  });

  it('deducts card costs and rejects unaffordable plays', () => {
    const engine = makeEngine({ taika: 1, deckA: Array(6).fill('brown_bear') });
    const card = engine.state.sides.a!.hand[0]!;
    expect(
      engine.dispatch({
        type: 'PLAY_CARD',
        actorId: 'a',
        cardInstanceId: card.instanceId,
        position: { row: 'FRONT', column: 0 },
      }).error?.code,
    ).toBe('INSUFFICIENT_TAIKA');
    engine.state.sides.a!.taika.current = 3;
    expect(
      engine.dispatch({
        type: 'PLAY_CARD',
        actorId: 'a',
        cardInstanceId: card.instanceId,
        position: { row: 'FRONT', column: 0 },
      }).ok,
    ).toBe(true);
    expect(engine.state.sides.a!.taika.current).toBe(0);
  });

  it('allows Swift to attack Creatures but not Heroes on the summon turn', () => {
    const engine = makeEngine({
      deckA: Array(6).fill('hawk'),
      b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
    });
    const card = engine.state.sides.a!.hand[0]!;
    engine.dispatch({
      type: 'PLAY_CARD',
      actorId: 'a',
      cardInstanceId: card.instanceId,
      position: { row: 'FRONT', column: 0 },
    });
    const hawk = creatureId(engine, 'a', 'hawk');
    expect(
      engine.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: hawk,
        targetId: heroEntityId('b'),
      }).error?.code,
    ).toBe('SUMMONING_SICKNESS');
    expect(
      engine.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: hawk,
        targetId: creatureId(engine, 'b', 'brown_bear'),
      }).ok,
    ).toBe(true);
  });

  it('allows Charge to use a normal combat action immediately', () => {
    const engine = makeEngine({ deckA: Array(6).fill('darek_voln') });
    const card = engine.state.sides.a!.hand[0]!;
    engine.dispatch({
      type: 'PLAY_CARD',
      actorId: 'a',
      cardInstanceId: card.instanceId,
      position: { row: 'FRONT', column: 0 },
    });
    expect(
      engine.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: creatureId(engine, 'a', 'darek_voln'),
        targetId: heroEntityId('b'),
      }).ok,
    ).toBe(true);
  });

  it('uses each placeholder Hero Power once per turn', () => {
    const engine = makeEngine();
    engine.state.sides.a!.hero.currentHealth = 20;
    expect(engine.dispatch({ type: 'USE_HERO_POWER', actorId: 'a' }).ok).toBe(true);
    expect(engine.state.sides.a!.hero.currentHealth).toBe(22);
    expect(engine.dispatch({ type: 'USE_HERO_POWER', actorId: 'a' }).error?.code).toBe(
      'POWER_USED',
    );
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    expect(engine.dispatch({ type: 'USE_HERO_POWER', actorId: 'b' }).ok).toBe(true);
    expect(engine.state.sides.a!.hero.currentHealth).toBe(21);
  });
});

describe('event and effect resolution', () => {
  it('resolves Arrival healing through the event queue', () => {
    const engine = makeEngine({ deckA: Array(6).fill('field_medic') });
    engine.state.sides.a!.hero.currentHealth = 20;
    const card = engine.state.sides.a!.hand[0]!;
    const result = engine.dispatch({
      type: 'PLAY_CARD',
      actorId: 'a',
      cardInstanceId: card.instanceId,
      position: { row: 'FRONT', column: 0 },
    });
    expect(engine.state.sides.a!.hero.currentHealth).toBe(23);
    expect(result.events.map((event) => event.type)).toEqual([
      'TAIKA_CHANGED',
      'CARD_PLAYED',
      'CREATURE_SUMMONED',
      'HEALING_RECEIVED',
    ]);
  });

  it('resolves Last Breath, damage, and death in deterministic order', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
      b: [{ definitionId: 'giant_rat', position: { row: 'FRONT', column: 0 } }],
      deckB: Array(5).fill('chicken'),
    });
    const before = engine.state.sides.b!.hand.length;
    const result = engine.dispatch({
      type: 'ATTACK',
      actorId: 'a',
      attackerId: creatureId(engine, 'a', 'brown_bear'),
      targetId: creatureId(engine, 'b', 'giant_rat'),
    });
    expect(result.events.map((event) => event.type)).toEqual([
      'ATTACK_STARTED',
      'DAMAGE_DEALT',
      'DAMAGE_DEALT',
      'CREATURE_DIED',
      'CARD_DRAWN',
    ]);
    expect(engine.state.sides.b!.hand.length).toBe(before + 1);
  });

  it('removes simultaneous combat deaths before Last Breath effects resolve', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'giant_rat', position: { row: 'FRONT', column: 0 } }],
      b: [{ definitionId: 'giant_rat', position: { row: 'FRONT', column: 0 } }],
      deckA: Array(4).fill('chicken'),
      deckB: Array(4).fill('chicken'),
    });
    const result = engine.dispatch({
      type: 'ATTACK',
      actorId: 'a',
      attackerId: creatureId(engine, 'a', 'giant_rat'),
      targetId: creatureId(engine, 'b', 'giant_rat'),
    });
    expect(result.events.filter((event) => event.type === 'CREATURE_DIED')).toHaveLength(2);
    expect(Object.keys(engine.state.sides.a!.creatures)).toHaveLength(0);
    expect(Object.keys(engine.state.sides.b!.creatures)).toHaveLength(0);
  });

  it('Ward negates one damage source and then disappears', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'chicken', position: { row: 'FRONT', column: 0 } }],
      b: [{ definitionId: 'maintenance_anima', position: { row: 'FRONT', column: 0 } }],
    });
    const attacker = creatureId(engine, 'a', 'chicken');
    const warded = creatureId(engine, 'b', 'maintenance_anima');
    const result = engine.dispatch({
      type: 'ATTACK',
      actorId: 'a',
      attackerId: attacker,
      targetId: warded,
    });
    expect(result.events.some((event) => event.type === 'DAMAGE_PREVENTED')).toBe(true);
    expect(engine.state.sides.b!.creatures[warded]!.currentHealth).toBe(3);
    expect(engine.state.sides.b!.creatures[warded]!.statuses).toHaveLength(0);
  });

  it('resolves targeted Action cards and moves them to discard', () => {
    const engine = makeEngine({ deckA: Array(6).fill('firebolt') });
    const card = engine.state.sides.a!.hand[0]!;
    const result = engine.dispatch({
      type: 'PLAY_CARD',
      actorId: 'a',
      cardInstanceId: card.instanceId,
      targetId: heroEntityId('b'),
    });
    expect(result.ok).toBe(true);
    expect(engine.state.sides.b!.hero.currentHealth).toBe(27);
    expect(engine.state.sides.a!.discard).toContain('firebolt');
  });

  it('keeps multiple Artifacts outside Creature tiles and resolves their triggers', () => {
    const engine = makeEngine({
      taika: 6,
      deckA: Array(6).fill('arcane_battery'),
      deckB: Array(6).fill('chicken'),
    });
    for (const card of [...engine.state.sides.a!.hand].slice(0, 2)) {
      expect(
        engine.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId: card.instanceId }).ok,
      ).toBe(true);
    }
    expect(engine.state.sides.a!.artifacts).toHaveLength(2);
    expect(Object.keys(engine.state.sides.a!.creatures)).toHaveLength(0);
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    engine.dispatch({ type: 'END_TURN', actorId: 'b' });
    expect(engine.state.sides.a!.taika.current).toBe(9);
  });

  it('Lifesteal restores the owner Hero by damage actually dealt', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'darek_voln', position: { row: 'FRONT', column: 0 } }],
    });
    engine.state.sides.a!.hero.currentHealth = 20;
    engine.state.sides.b!.hero.currentHealth = 3;
    engine.dispatch({
      type: 'ATTACK',
      actorId: 'a',
      attackerId: creatureId(engine, 'a', 'darek_voln'),
      targetId: heroEntityId('b'),
    });
    expect(engine.state.sides.a!.hero.currentHealth).toBe(23);
    expect(engine.state.phase).toBe('FINISHED');
    expect(engine.state.winnerId).toBe('a');
  });
});
