import { afterEach, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { createApp } from '../apps/server/src/app.js';
import { MatchManager } from '../apps/server/src/match-manager.js';
import {
  CARD_DEFINITIONS,
  SCENARIO_DEFINITIONS,
  starterDeckFor,
  getCardDefinition,
  validateWeaponDefinition,
} from '@maailma/card-definitions';
import {
  BasicAIController,
  GameEngine,
  createReplay,
  heroEntityId,
  replayMatch,
  stableStateJson,
  validateDeck,
} from '@maailma/game-engine';
import type { GameAction, MatchSetup, WeaponDefinition } from '@maailma/game-model';
import { creatureId, makeEngine } from './helpers.js';

/** Puts `definitionId` in a's hand and returns its card instance id. */
function giveCard(engine: GameEngine, playerId: 'a' | 'b', definitionId: string): string {
  const side = engine.state.sides[playerId]!;
  const instanceId = `given_${definitionId}_${side.hand.length}`;
  side.hand.push({ instanceId, definitionId });
  return instanceId;
}

/** Plays a Weapon from hand, asserting it was accepted. */
function equip(engine: GameEngine, playerId: 'a' | 'b', definitionId: string): void {
  const cardInstanceId = giveCard(engine, playerId, definitionId);
  const result = engine.dispatch({ type: 'PLAY_CARD', actorId: playerId, cardInstanceId });
  expect(result.ok, `${definitionId} should be playable: ${result.error?.message}`).toBe(true);
}

const weapon = (engine: GameEngine, playerId: 'a' | 'b') =>
  engine.state.sides[playerId]!.hero.equippedWeapon;

const eventTypes = (events: { type: string }[]) => events.map((event) => event.type);

describe('Weapon definitions', () => {
  it('registers the baseline Weapons as first-class collectible cards', () => {
    for (const id of ['rusty_dagger', 'iron_sword', 'war_axe', 'hunting_bow', 'longbow']) {
      const definition = getCardDefinition(id);
      expect(definition.type).toBe('WEAPON');
      expect(definition.collectible).toBe(true);
    }
  });

  it('stores range explicitly rather than inferring it from tags', () => {
    const bow = getCardDefinition('hunting_bow') as WeaponDefinition;
    expect(bow.range).toBe('RANGED');
    expect(bow.tags).toContain('BOW');
    // The taxonomy tag is not the rules property.
    expect(bow.tags).not.toContain('RANGED');
    expect((getCardDefinition('iron_sword') as WeaponDefinition).range).toBe('MELEE');
  });

  it('accepts every shipped Weapon and rejects malformed data', () => {
    const shipped = Object.values(CARD_DEFINITIONS).filter((card) => card.type === 'WEAPON');
    expect(shipped.length).toBeGreaterThan(0);
    for (const definition of shipped) {
      expect(validateWeaponDefinition(definition as WeaponDefinition)).toEqual([]);
    }

    const base = getCardDefinition('iron_sword') as WeaponDefinition;
    expect(validateWeaponDefinition({ ...base, durability: 0 })).toHaveLength(1);
    expect(validateWeaponDefinition({ ...base, cost: -1 })).toHaveLength(1);
    expect(validateWeaponDefinition({ ...base, attack: -1 })).toHaveLength(1);
    expect(
      validateWeaponDefinition({ ...base, range: 'THROWN' as WeaponDefinition['range'] }),
    ).toHaveLength(1);
  });
});

describe('Weapon card lifecycle', () => {
  it('plays from hand, spends Taika, leaves hand and equips', () => {
    const engine = makeEngine({ taika: 5 });
    const cardInstanceId = giveCard(engine, 'a', 'iron_sword');
    const before = engine.state.sides.a!.taika.current;
    const handBefore = engine.state.sides.a!.hand.length;

    const result = engine.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId });

    expect(result.ok).toBe(true);
    expect(engine.state.sides.a!.taika.current).toBe(before - 2);
    expect(engine.state.sides.a!.hand).toHaveLength(handBefore - 1);
    expect(weapon(engine, 'a')?.definitionId).toBe('iron_sword');
    expect(eventTypes(result.events)).toContain('WEAPON_EQUIPPED');
  });

  it('refuses a Weapon the side cannot afford', () => {
    const engine = makeEngine({ taika: 1 });
    const cardInstanceId = giveCard(engine, 'a', 'war_axe');
    expect(engine.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId }).error?.code).toBe(
      'INSUFFICIENT_TAIKA',
    );
    expect(weapon(engine, 'a')).toBeNull();
  });

  it('tracks state on the instance and leaves the definition untouched', () => {
    const engine = makeEngine({
      taika: 5,
      b: [{ definitionId: 'chicken', position: { row: 'FRONT', column: 0 } }],
    });
    equip(engine, 'a', 'iron_sword');
    const equipped = weapon(engine, 'a')!;
    expect(equipped.currentAttack).toBe(2);
    expect(equipped.currentDurability).toBe(2);
    expect(equipped.maxDurability).toBe(2);
    expect(equipped.ownerId).toBe('a');

    engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });

    expect(weapon(engine, 'a')!.currentDurability).toBe(1);
    const definition = getCardDefinition('iron_sword') as WeaponDefinition;
    expect(definition.durability).toBe(2);
    expect(definition.attack).toBe(2);
  });

  it('does not take a battlefield tile', () => {
    const engine = makeEngine({ taika: 5 });
    const cardInstanceId = giveCard(engine, 'a', 'iron_sword');
    expect(
      engine.dispatch({
        type: 'PLAY_CARD',
        actorId: 'a',
        cardInstanceId,
        position: { row: 'FRONT', column: 0 },
      }).error?.code,
    ).toBe('UNEXPECTED_POSITION');
  });
});

describe('Weapon replacement', () => {
  it('replaces the equipped Weapon and reports REPLACED, not BROKEN', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'rusty_dagger');
    const first = weapon(engine, 'a')!.instanceId;

    const cardInstanceId = giveCard(engine, 'a', 'iron_sword');
    const result = engine.dispatch({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId });

    expect(result.ok).toBe(true);
    const replaced = result.events.find((event) => event.type === 'WEAPON_REPLACED');
    expect(replaced?.sourceId).toBe(first);
    expect(replaced?.reason).toBe('REPLACED');
    expect(eventTypes(result.events)).not.toContain('WEAPON_BROKEN');
    expect(weapon(engine, 'a')!.definitionId).toBe('iron_sword');
    expect(weapon(engine, 'a')!.currentDurability).toBe(2);
  });

  it('allows an attack when the Hero has not yet attacked', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'rusty_dagger');
    equip(engine, 'a', 'iron_sword');
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(true);
  });

  it('does not hand back a spent attack — the swap exploit stays closed', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'iron_sword');
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(true);
    expect(engine.state.sides.a!.hero.attacksUsedThisTurn).toBe(1);

    equip(engine, 'a', 'hunting_bow');

    expect(engine.state.sides.a!.hero.attacksUsedThisTurn).toBe(1);
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).error
        ?.code,
    ).toBe('HERO_ATTACK_USED');
    // The fresh Weapon is untouched by the rejected attack.
    expect(weapon(engine, 'a')!.currentDurability).toBe(2);
  });
});

describe('Hero attack allowance', () => {
  it('rejects an attack with no Weapon', () => {
    const engine = makeEngine({ taika: 10 });
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).error
        ?.code,
    ).toBe('NO_WEAPON');
  });

  it('allows exactly one attack per turn', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'war_axe');
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(true);
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).error
        ?.code,
    ).toBe('HERO_ATTACK_USED');
  });

  it('resets the allowance when the turn comes round again', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'war_axe');
    engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    engine.dispatch({ type: 'END_TURN', actorId: 'b' });

    expect(engine.state.sides.a!.hero.attacksUsedThisTurn).toBe(0);
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(true);
  });

  it('is independent of the Hero Power', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'iron_sword');
    expect(engine.dispatch({ type: 'USE_HERO_POWER', actorId: 'a' }).ok).toBe(true);
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(true);
    // And the reverse: attacking has not spent the power on a fresh turn.
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    engine.dispatch({ type: 'END_TURN', actorId: 'b' });
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(true);
    expect(engine.dispatch({ type: 'USE_HERO_POWER', actorId: 'a' }).ok).toBe(true);
  });

  it('has no summoning sickness — a Weapon may be used the turn it lands', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'iron_sword');
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(true);
  });

  it('neither breaking nor replacing restores the attack', () => {
    const broken = makeEngine({ taika: 10 });
    equip(broken, 'a', 'rusty_dagger');
    broken.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });
    broken.dispatch({ type: 'END_TURN', actorId: 'a' });
    broken.dispatch({ type: 'END_TURN', actorId: 'b' });
    // Second swing breaks it (2 Durability), and the allowance is still spent.
    broken.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });
    expect(weapon(broken, 'a')).toBeNull();
    expect(broken.state.sides.a!.hero.attacksUsedThisTurn).toBe(1);
    equip(broken, 'a', 'iron_sword');
    expect(
      broken.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).error
        ?.code,
    ).toBe('HERO_ATTACK_USED');
  });
});

describe('melee Weapon targeting', () => {
  for (const width of [1, 2, 3, 4]) {
    it(`reaches every enemy front column on a width-${width} battlefield`, () => {
      for (let column = 0; column < width; column += 1) {
        const engine = makeEngine({
          width,
          taika: 10,
          b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column } }],
        });
        equip(engine, 'a', 'iron_sword');
        expect(
          engine.dispatch({
            type: 'HERO_ATTACK',
            actorId: 'a',
            targetId: creatureId(engine, 'b', 'brown_bear'),
          }).ok,
          `width ${width}, column ${column}`,
        ).toBe(true);
      }
    });
  }

  it('cannot reach a shielded back-row Creature but can reach an exposed one', () => {
    const shielded = makeEngine({
      taika: 10,
      b: [
        { definitionId: 'hawk', position: { row: 'BACK', column: 2 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 2 } },
      ],
    });
    equip(shielded, 'a', 'iron_sword');
    expect(
      shielded.dispatch({
        type: 'HERO_ATTACK',
        actorId: 'a',
        targetId: creatureId(shielded, 'b', 'hawk'),
      }).error?.code,
    ).toBe('BACK_ROW_PROTECTED');

    const exposed = makeEngine({
      taika: 10,
      b: [{ definitionId: 'hawk', position: { row: 'BACK', column: 2 } }],
    });
    equip(exposed, 'a', 'iron_sword');
    expect(
      exposed.dispatch({
        type: 'HERO_ATTACK',
        actorId: 'a',
        targetId: creatureId(exposed, 'b', 'hawk'),
      }).ok,
    ).toBe(true);
  });

  it('shields only the matching column, not the whole row', () => {
    const engine = makeEngine({
      taika: 10,
      b: [
        { definitionId: 'hawk', position: { row: 'BACK', column: 0 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 2 } },
      ],
    });
    equip(engine, 'a', 'iron_sword');
    expect(
      engine.dispatch({
        type: 'HERO_ATTACK',
        actorId: 'a',
        targetId: creatureId(engine, 'b', 'hawk'),
      }).ok,
    ).toBe(true);
  });
});

describe('ranged Weapon targeting', () => {
  it('reaches both rows and ignores front-row shielding', () => {
    for (const row of ['FRONT', 'BACK'] as const) {
      const engine = makeEngine({
        taika: 10,
        b: [
          { definitionId: 'hawk', position: { row: 'BACK', column: 2 } },
          { definitionId: 'brown_bear', position: { row: 'FRONT', column: 2 } },
        ],
      });
      equip(engine, 'a', 'hunting_bow');
      const targetId =
        row === 'BACK' ? creatureId(engine, 'b', 'hawk') : creatureId(engine, 'b', 'brown_bear');
      expect(engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId }).ok).toBe(true);
    }
  });

  it('is not tied to a column on a wide battlefield', () => {
    const engine = makeEngine({
      width: 4,
      taika: 10,
      b: [{ definitionId: 'hawk', position: { row: 'BACK', column: 3 } }],
    });
    equip(engine, 'a', 'longbow');
    expect(
      engine.dispatch({
        type: 'HERO_ATTACK',
        actorId: 'a',
        targetId: creatureId(engine, 'b', 'hawk'),
      }).ok,
    ).toBe(true);
  });
});

describe('Guard and Hero Weapons', () => {
  it('lets the Hero be attacked while only ordinary Creatures defend', () => {
    const engine = makeEngine({
      taika: 10,
      b: [
        { definitionId: 'elf_archer', position: { row: 'BACK', column: 0 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } },
      ],
    });
    equip(engine, 'a', 'iron_sword');
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(true);
    expect(engine.state.sides.b!.hero.currentHealth).toBe(28);
  });

  it('seals the Hero off while any Guard lives, at melee and at reach', () => {
    for (const weaponId of ['iron_sword', 'hunting_bow']) {
      const engine = makeEngine({
        taika: 10,
        b: [{ definitionId: 'dwarf_defender', position: { row: 'FRONT', column: 1 } }],
      });
      equip(engine, 'a', weaponId);
      expect(
        engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).error
          ?.code,
        weaponId,
      ).toBe('HERO_GUARDED');
    }
  });

  it('protects adjacent Creatures from both Weapon kinds, but the Guard stays attackable', () => {
    for (const weaponId of ['iron_sword', 'hunting_bow']) {
      const engine = makeEngine({
        taika: 10,
        b: [
          { definitionId: 'dwarf_defender', position: { row: 'FRONT', column: 1 } },
          { definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } },
        ],
      });
      equip(engine, 'a', weaponId);
      expect(
        engine.dispatch({
          type: 'HERO_ATTACK',
          actorId: 'a',
          targetId: creatureId(engine, 'b', 'brown_bear'),
        }).error?.code,
        weaponId,
      ).toBe('TARGET_GUARDED');
      expect(
        engine.dispatch({
          type: 'HERO_ATTACK',
          actorId: 'a',
          targetId: creatureId(engine, 'b', 'dwarf_defender'),
        }).ok,
        weaponId,
      ).toBe(true);
    }
  });

  it('opens the Hero the moment the last Guard dies', () => {
    const engine = makeEngine({
      taika: 10,
      a: [{ definitionId: 'darek_voln', position: { row: 'FRONT', column: 0 } }],
      b: [{ definitionId: 'dwarf_defender', position: { row: 'FRONT', column: 0 } }],
    });
    equip(engine, 'a', 'iron_sword');
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).error
        ?.code,
    ).toBe('HERO_GUARDED');

    // Darek Voln (5 attack) kills the 2/4 Defender outright.
    engine.dispatch({
      type: 'ATTACK',
      actorId: 'a',
      attackerId: creatureId(engine, 'a', 'darek_voln'),
      targetId: creatureId(engine, 'b', 'dwarf_defender'),
    });

    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(true);
  });

  it('refuses a Hidden Creature as a target', () => {
    const engine = makeEngine({
      taika: 10,
      b: [{ definitionId: 'hunting_spider', position: { row: 'FRONT', column: 0 } }],
    });
    equip(engine, 'a', 'iron_sword');
    expect(
      engine.dispatch({
        type: 'HERO_ATTACK',
        actorId: 'a',
        targetId: creatureId(engine, 'b', 'hunting_spider'),
      }).error?.code,
    ).toBe('TARGET_HIDDEN');
  });

  it('refuses a friendly target and a stale id', () => {
    const engine = makeEngine({
      taika: 10,
      a: [{ definitionId: 'chicken', position: { row: 'FRONT', column: 0 } }],
    });
    equip(engine, 'a', 'iron_sword');
    expect(
      engine.dispatch({
        type: 'HERO_ATTACK',
        actorId: 'a',
        targetId: creatureId(engine, 'a', 'chicken'),
      }).error?.code,
    ).toBe('FRIENDLY_FIRE');
    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: 'creature_999' }).error?.code,
    ).toBe('INVALID_TARGET');
  });
});

describe('retaliation', () => {
  it('trades blows on a melee attack against a Creature', () => {
    const engine = makeEngine({
      taika: 10,
      b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
    });
    equip(engine, 'a', 'war_axe'); // 4 attack
    const bearId = creatureId(engine, 'b', 'brown_bear'); // 3/4
    const heroBefore = engine.state.sides.a!.hero.currentHealth;

    const result = engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: bearId });

    expect(result.ok).toBe(true);
    // The Bear takes 4 and dies; the Hero takes its 3 back.
    expect(engine.state.sides.b!.creatures[bearId]).toBeUndefined();
    expect(engine.state.sides.a!.hero.currentHealth).toBe(heroBefore - 3);
  });

  it('takes no retaliation from a ranged attack, but still spends Durability', () => {
    const engine = makeEngine({
      taika: 10,
      b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
    });
    equip(engine, 'a', 'hunting_bow'); // 2 attack
    const bearId = creatureId(engine, 'b', 'brown_bear');
    const heroBefore = engine.state.sides.a!.hero.currentHealth;

    engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: bearId });

    expect(engine.state.sides.b!.creatures[bearId]!.currentHealth).toBe(2);
    expect(engine.state.sides.a!.hero.currentHealth).toBe(heroBefore);
    expect(weapon(engine, 'a')!.currentDurability).toBe(1);
  });

  it('never retaliates when the target is the enemy Hero', () => {
    for (const weaponId of ['iron_sword', 'hunting_bow']) {
      const engine = makeEngine({ taika: 10 });
      equip(engine, 'a', weaponId);
      const before = engine.state.sides.a!.hero.currentHealth;
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });
      expect(engine.state.sides.a!.hero.currentHealth, weaponId).toBe(before);
    }
  });

  it('lets both the Hero and the Creature die in one exchange', () => {
    const engine = makeEngine({
      taika: 10,
      b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
    });
    engine.state.sides.a!.hero.currentHealth = 2;
    equip(engine, 'a', 'war_axe');
    const bearId = creatureId(engine, 'b', 'brown_bear');

    const result = engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: bearId });

    expect(result.ok).toBe(true);
    // The Hero's outgoing damage is not cancelled by lethal retaliation.
    expect(engine.state.sides.b!.creatures[bearId]).toBeUndefined();
    expect(engine.state.sides.a!.hero.currentHealth).toBeLessThanOrEqual(0);
    expect(engine.state.phase).toBe('FINISHED');
    expect(engine.state.winnerId).toBe('b');
  });
});

describe('Durability', () => {
  it('spends exactly one per successful attack, whatever the target or range', () => {
    const cases: Array<{ weaponId: string; target: 'HERO' | 'CREATURE' }> = [
      { weaponId: 'iron_sword', target: 'HERO' },
      { weaponId: 'iron_sword', target: 'CREATURE' },
      { weaponId: 'hunting_bow', target: 'HERO' },
      { weaponId: 'hunting_bow', target: 'CREATURE' },
    ];
    for (const { weaponId, target } of cases) {
      const engine = makeEngine({
        taika: 10,
        b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
      });
      equip(engine, 'a', weaponId);
      const targetId =
        target === 'HERO' ? heroEntityId('b') : creatureId(engine, 'b', 'brown_bear');
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId });
      expect(weapon(engine, 'a')!.currentDurability, `${weaponId} → ${target}`).toBe(1);
    }
  });

  it('spends nothing when the attack is rejected', () => {
    const engine = makeEngine({
      taika: 10,
      b: [{ definitionId: 'dwarf_defender', position: { row: 'FRONT', column: 0 } }],
    });
    equip(engine, 'a', 'iron_sword');
    const before = weapon(engine, 'a')!.currentDurability;
    const heroHealth = engine.state.sides.b!.hero.currentHealth;

    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).ok,
    ).toBe(false);

    expect(weapon(engine, 'a')!.currentDurability).toBe(before);
    expect(engine.state.sides.a!.hero.attacksUsedThisTurn).toBe(0);
    expect(engine.state.sides.b!.hero.currentHealth).toBe(heroHealth);
  });

  it('breaks at zero and empties the slot', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'rusty_dagger'); // 2 Durability

    engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });
    expect(weapon(engine, 'a')!.currentDurability).toBe(1);

    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    engine.dispatch({ type: 'END_TURN', actorId: 'b' });
    const result = engine.dispatch({
      type: 'HERO_ATTACK',
      actorId: 'a',
      targetId: heroEntityId('b'),
    });

    expect(eventTypes(result.events)).toContain('WEAPON_BROKEN');
    expect(weapon(engine, 'a')).toBeNull();
    // Both 1-damage swings landed before it broke. The extra point is b's
    // fatigue: its deck is empty in this fixture, so its own draw hurts it.
    const fatigue = engine.state.sides.b!.fatigue;
    expect(engine.state.sides.b!.hero.currentHealth).toBe(30 - 2 - fatigue);
  });

  it('refuses to attack once the Weapon is gone', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'rusty_dagger');
    engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    engine.dispatch({ type: 'END_TURN', actorId: 'b' });
    engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    engine.dispatch({ type: 'END_TURN', actorId: 'b' });

    expect(
      engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }).error
        ?.code,
    ).toBe('NO_WEAPON');
  });
});

describe('event ordering and attribution', () => {
  it('orders a breaking attack: start, damage, durability, break, resolved', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'rusty_dagger');
    engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    engine.dispatch({ type: 'END_TURN', actorId: 'b' });

    const events = engine.dispatch({
      type: 'HERO_ATTACK',
      actorId: 'a',
      targetId: heroEntityId('b'),
    }).events;
    const order = eventTypes(events);

    expect(order.indexOf('HERO_ATTACK_STARTED')).toBeLessThan(order.indexOf('DAMAGE_DEALT'));
    expect(order.indexOf('DAMAGE_DEALT')).toBeLessThan(order.indexOf('WEAPON_DURABILITY_CHANGED'));
    // The break is the last thing the attack does, after its triggers are queued.
    expect(order.indexOf('WEAPON_DURABILITY_CHANGED')).toBeLessThan(order.indexOf('WEAPON_BROKEN'));
    expect(order.indexOf('HERO_ATTACK_RESOLVED')).toBeLessThan(order.indexOf('WEAPON_BROKEN'));
    // Sequence numbers are strictly increasing.
    const sequences = events.map((event) => event.sequence);
    expect(sequences).toEqual([...sequences].sort((x, y) => x - y));
  });

  it('attributes Weapon damage and the kills it causes', () => {
    const engine = makeEngine({
      taika: 10,
      b: [{ definitionId: 'chicken', position: { row: 'FRONT', column: 0 } }],
    });
    equip(engine, 'a', 'hunting_bow');
    const result = engine.dispatch({
      type: 'HERO_ATTACK',
      actorId: 'a',
      targetId: creatureId(engine, 'b', 'chicken'),
    });

    const damage = result.events.find((event) => event.type === 'DAMAGE_DEALT');
    expect(damage?.damage).toMatchObject({
      kind: 'HERO_WEAPON',
      range: 'RANGED',
      weaponDefinitionId: 'hunting_bow',
    });
    const death = result.events.find((event) => event.type === 'CREATURE_DIED');
    expect(death?.damage?.kind).toBe('HERO_WEAPON');
    expect(death?.damage?.weaponDefinitionId).toBe('hunting_bow');
  });

  it('marks melee retaliation distinctly from the Hero swing', () => {
    const engine = makeEngine({
      taika: 10,
      b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
    });
    equip(engine, 'a', 'iron_sword');
    const result = engine.dispatch({
      type: 'HERO_ATTACK',
      actorId: 'a',
      targetId: creatureId(engine, 'b', 'brown_bear'),
    });
    const damages = result.events.filter((event) => event.type === 'DAMAGE_DEALT');
    expect(damages[0]!.damage).toMatchObject({ kind: 'HERO_WEAPON', range: 'MELEE' });
    expect(damages[1]!.damage).toMatchObject({ kind: 'CREATURE_COMBAT', retaliation: true });
  });
});

describe('legal actions', () => {
  it('offers no Hero attack without a Weapon, and legal ones with', () => {
    const engine = makeEngine({
      taika: 10,
      b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
    });
    expect(engine.getLegalActions('a').some((action) => action.type === 'HERO_ATTACK')).toBe(false);

    equip(engine, 'a', 'iron_sword');
    const heroAttacks = engine
      .getLegalActions('a')
      .filter((action) => action.type === 'HERO_ATTACK');
    expect(heroAttacks).toHaveLength(2); // the Bear and the enemy Hero
    for (const action of heroAttacks) {
      expect(engine.dispatch(structuredClone(action)).ok).toBe(true);
      break; // one is enough; the rest are covered by targeting tests
    }
  });

  it('omits Guard-protected targets and the sealed Hero', () => {
    const engine = makeEngine({
      taika: 10,
      b: [
        { definitionId: 'dwarf_defender', position: { row: 'FRONT', column: 1 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } },
      ],
    });
    equip(engine, 'a', 'hunting_bow');
    const targets = engine
      .getLegalActions('a')
      .filter((action) => action.type === 'HERO_ATTACK')
      .map((action) => (action as Extract<GameAction, { type: 'HERO_ATTACK' }>).targetId);

    expect(targets).toEqual([creatureId(engine, 'b', 'dwarf_defender')]);
  });

  it('offers no Hero attack once the allowance is spent', () => {
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'iron_sword');
    engine.dispatch({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') });
    expect(engine.getLegalActions('a').some((action) => action.type === 'HERO_ATTACK')).toBe(false);
  });

  it('offers Weapon cards as playable', () => {
    const engine = makeEngine({ taika: 10 });
    const cardInstanceId = giveCard(engine, 'a', 'longbow');
    const play = engine
      .getLegalActions('a')
      .filter((action) => action.type === 'PLAY_CARD')
      .filter(
        (action) =>
          (action as Extract<GameAction, { type: 'PLAY_CARD' }>).cardInstanceId === cardInstanceId,
      );
    expect(play).toHaveLength(1);
    expect(play[0]).not.toHaveProperty('position');
  });
});

describe('effects and scenarios', () => {
  it('destroys an equipped Weapon through the generic DESTROY effect', () => {
    const engine = makeEngine({ taika: 10 });
    // Weapons are played on their owner's turn, so hand the turn to b first.
    engine.dispatch({ type: 'END_TURN', actorId: 'a' });
    equip(engine, 'b', 'iron_sword');
    expect(weapon(engine, 'b')).not.toBeNull();

    // Exactly what a "destroy your opponent's Weapon" card would queue, routed
    // through the ordinary effect resolver rather than a Weapon-only path.
    const events = engine.resolveEffect({ type: 'DESTROY', target: 'ENEMY_WEAPON' }, 'a');

    expect(weapon(engine, 'b')).toBeNull();
    const destroyed = events.find((event) => event.type === 'WEAPON_DESTROYED');
    expect(destroyed?.reason).toBe('DESTROYED_BY_EFFECT');
    // The Hero keeps its allowance; only the Weapon is gone.
    expect(engine.state.sides.b!.hero.attacksUsedThisTurn).toBe(0);
  });

  it('arms a PvE Hero from the scenario definition', () => {
    const engine = makeEngine({ taika: 10, startingWeaponB: 'war_axe' });
    expect(engine.state.sides.b!.hero.equippedWeapon?.definitionId).toBe('war_axe');
    expect(engine.state.sides.b!.hero.equippedWeapon?.currentDurability).toBe(2);
  });
});

describe('replay determinism', () => {
  /** A setup whose starting hand is part of the replayable setup itself. */
  function weaponSetup(startingCards: string[]): MatchSetup {
    const standard = SCENARIO_DEFINITIONS.STANDARD_PVP!;
    return {
      scenario: {
        ...structuredClone(standard),
        id: 'WEAPON_REPLAY',
        battlefield: { width: 3 },
        sideA: {
          ...structuredClone(standard.sideA),
          startingTaika: 10,
          maxTaika: 10,
          startingCards,
        },
        sideB: {
          ...structuredClone(standard.sideB),
          startingTaika: 10,
          maxTaika: 10,
          startingCreatures: [
            { definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } },
          ],
        },
      },
      seed: 'weapons-replay',
      players: [
        { playerId: 'a', deck: ['chicken', 'hawk', 'chicken', 'hawk', 'chicken', 'hawk'] },
        { playerId: 'b', deck: ['chicken', 'hawk', 'chicken', 'hawk', 'chicken', 'hawk'] },
      ],
    };
  }

  const handCard = (engine: GameEngine, definitionId: string) =>
    engine.state.sides.a!.hand.find((card) => card.definitionId === definitionId)!.instanceId;

  it('reproduces equipping, attacking, breaking and replacing exactly', () => {
    const setup = weaponSetup(['iron_sword', 'hunting_bow']);
    const engine = new GameEngine(setup);
    const bear = Object.keys(engine.state.sides.b!.creatures)[0]!;

    const actions: GameAction[] = [
      { type: 'PLAY_CARD', actorId: 'a', cardInstanceId: handCard(engine, 'iron_sword') },
      { type: 'HERO_ATTACK', actorId: 'a', targetId: bear },
      { type: 'END_TURN', actorId: 'a' },
      { type: 'END_TURN', actorId: 'b' },
      // The sword's second swing spends its last Durability and breaks it.
      { type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') },
      { type: 'PLAY_CARD', actorId: 'a', cardInstanceId: handCard(engine, 'hunting_bow') },
      { type: 'END_TURN', actorId: 'a' },
      { type: 'END_TURN', actorId: 'b' },
      // And a ranged swing with the replacement.
      { type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') },
    ];
    for (const action of actions) {
      const result = engine.dispatch(action);
      expect(result.ok, `${action.type}: ${result.error?.message}`).toBe(true);
    }

    expect(weapon(engine, 'a')).toMatchObject({
      definitionId: 'hunting_bow',
      currentDurability: 1,
    });

    // Replay derives damage and Durability again from the engine; only the
    // ordered actions are persisted.
    const replayed = replayMatch(createReplay(setup, engine.state.actionLog));
    expect(stableStateJson(replayed)).toEqual(stableStateJson(engine));
  });

  it('reproduces a ranged-only match exactly', () => {
    const setup = weaponSetup(['longbow']);
    const engine = new GameEngine(setup);
    const bear = Object.keys(engine.state.sides.b!.creatures)[0]!;
    const actions: GameAction[] = [
      { type: 'PLAY_CARD', actorId: 'a', cardInstanceId: handCard(engine, 'longbow') },
      { type: 'HERO_ATTACK', actorId: 'a', targetId: bear },
      { type: 'END_TURN', actorId: 'a' },
      { type: 'END_TURN', actorId: 'b' },
      { type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') },
    ];
    for (const action of actions) expect(engine.dispatch(action).ok).toBe(true);

    const replayed = replayMatch(createReplay(setup, engine.state.actionLog));
    expect(stableStateJson(replayed)).toEqual(stableStateJson(engine));
    // The Hero took no retaliation from the ranged exchange.
    expect(engine.state.sides.a!.hero.currentHealth).toBe(30);
  });
});

describe('AI with Weapons', () => {
  it('plays Weapons and attacks legally without corrupting state', () => {
    const ai = new BasicAIController();
    const engine = makeEngine({
      taika: 10,
      b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
    });
    giveCard(engine, 'a', 'iron_sword');
    giveCard(engine, 'a', 'hunting_bow');

    // Drive a's whole turn through the AI; every action must be legal.
    for (let step = 0; step < 20; step += 1) {
      if (engine.state.activePlayerId !== 'a' || engine.state.phase !== 'PLAYING') break;
      const action = ai.chooseAction(engine, 'a');
      if (!action) break;
      const result = engine.dispatch(action);
      expect(result.ok, `AI produced an illegal ${action.type}`).toBe(true);
      if (action.type === 'END_TURN') break;
    }

    const hero = engine.state.sides.a!.hero;
    expect(hero.attacksUsedThisTurn).toBeLessThanOrEqual(1);
    if (hero.equippedWeapon) {
      expect(hero.equippedWeapon.currentDurability).toBeGreaterThan(0);
    }
  });

  it('does not throw away a strong Weapon for a weaker one', () => {
    const ai = new BasicAIController();
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'war_axe'); // value 8
    giveCard(engine, 'a', 'rusty_dagger'); // value 2

    const chosen = ai.chooseAction(engine, 'a');
    expect(chosen?.type).not.toBe('PLAY_CARD');
    expect(weapon(engine, 'a')!.definitionId).toBe('war_axe');
  });

  it('does upgrade to a better Weapon', () => {
    const ai = new BasicAIController();
    const engine = makeEngine({ taika: 10 });
    equip(engine, 'a', 'rusty_dagger');
    giveCard(engine, 'a', 'war_axe');

    const chosen = ai.chooseAction(engine, 'a');
    expect(chosen?.type).toBe('PLAY_CARD');
  });
});

describe('deck and collection integration', () => {
  it('accepts Weapons as ordinary deck cards under the usual copy limits', () => {
    // The starter deck already carries two copies of a common Weapon.
    const deck = starterDeckFor('healer');
    expect(deck.filter((id) => id === 'iron_sword')).toHaveLength(2);
    expect(validateDeck(deck)).toEqual({ valid: true, errors: [] });

    // Trading both Wolves for a third Iron Sword and a Wolf keeps 30 cards
    // but breaks the copy limit.
    const tooMany = [...deck.filter((id) => id !== 'chicken'), 'iron_sword', 'chicken'];
    expect(tooMany).toHaveLength(30);
    expect(validateDeck(tooMany).valid).toBe(false);
  });

  it('leaves existing Creature, Action and Artifact decks valid', () => {
    expect(validateDeck(starterDeckFor('healer'))).toEqual({ valid: true, errors: [] });
    expect(validateDeck(starterDeckFor('striker'))).toEqual({ valid: true, errors: [] });
  });
});

describe('authoritative server protocol', () => {
  let server: Server | undefined;

  afterEach(async () => {
    if (server)
      await new Promise<void>((resolve, reject) =>
        server!.close((error) => (error ? reject(error) : resolve())),
      );
    server = undefined;
  });

  it('carries HERO_ATTACK end to end and keeps the client out of the rules', async () => {
    const manager = new MatchManager();
    server = createServer(createApp(manager));
    await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Missing test port');
    const base = `http://127.0.0.1:${address.port}`;

    const created = await fetch(`${base}/api/matches`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        scenarioId: 'STANDARD_PVP',
        seed: 7,
        players: [
          { playerId: 'a', deck: starterDeckFor('healer') },
          { playerId: 'b', deck: starterDeckFor('striker') },
        ],
      }),
    });
    expect(created.status).toBe(201);
    const { matchId } = (await created.json()) as { matchId: string };

    // Arm a's Hero through the engine the manager owns, then drive the rest
    // over HTTP exactly as a client would.
    const engine = manager.get(matchId)!;
    engine.state.sides.a!.taika.current = 10;
    const cardInstanceId = giveCard(engine, 'a', 'hunting_bow');
    const played = await fetch(`${base}/api/matches/${matchId}/actions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'PLAY_CARD', actorId: 'a', cardInstanceId }),
    });
    expect(played.status).toBe(200);

    // Equipped Weapons are public board state, and the DTO carries what a
    // client needs to draw them.
    const stateResponse = await fetch(`${base}/api/matches/${matchId}`);
    const { state } = (await stateResponse.json()) as {
      state: {
        sides: Record<
          string,
          { hero: { equippedWeapon: Record<string, unknown> | null; attacksUsedThisTurn: number } }
        >;
      };
    };
    const equipped = state.sides.a!.hero.equippedWeapon!;
    expect(equipped).toMatchObject({
      definitionId: 'hunting_bow',
      currentAttack: 2,
      currentDurability: 2,
      maxDurability: 2,
    });
    expect(state.sides.a!.hero.attacksUsedThisTurn).toBe(0);

    // The server offers the Hero attack rather than the client deducing it.
    const legal = await fetch(`${base}/api/matches/${matchId}/legal-actions/a`);
    const { actions } = (await legal.json()) as { actions: Array<Record<string, unknown>> };
    const heroAttack = actions.find((action) => action.type === 'HERO_ATTACK');
    expect(heroAttack).toBeDefined();

    const resolved = await fetch(`${base}/api/matches/${matchId}/actions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(heroAttack),
    });
    expect(resolved.status).toBe(200);
    const payload = (await resolved.json()) as {
      events: Array<{ type: string }>;
      state: { sides: Record<string, { hero: { currentHealth: number } }> };
    };
    // The client sent only an intention; the server decided the consequences.
    expect(payload.events.map((event) => event.type)).toContain('WEAPON_DURABILITY_CHANGED');
    expect(payload.state.sides.b!.hero.currentHealth).toBe(28);
    expect(manager.get(matchId)!.state.sides.a!.hero.equippedWeapon!.currentDurability).toBe(1);
  });

  it('rejects an illegal Hero attack without changing state', async () => {
    const manager = new MatchManager();
    server = createServer(createApp(manager));
    await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Missing test port');
    const base = `http://127.0.0.1:${address.port}`;

    const created = await fetch(`${base}/api/matches`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        scenarioId: 'STANDARD_PVP',
        seed: 7,
        players: [
          { playerId: 'a', deck: starterDeckFor('healer') },
          { playerId: 'b', deck: starterDeckFor('striker') },
        ],
      }),
    });
    const { matchId } = (await created.json()) as { matchId: string };

    // No Weapon equipped, so a forged request must bounce.
    const response = await fetch(`${base}/api/matches/${matchId}/actions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'HERO_ATTACK', actorId: 'a', targetId: heroEntityId('b') }),
    });
    const body = (await response.json()) as { ok: boolean; error?: { code: string } };
    expect(body.ok).toBe(false);
    expect(body.error?.code).toBe('NO_WEAPON');
    expect(manager.get(matchId)!.state.sides.b!.hero.currentHealth).toBe(30);
  });
});

describe('PvE parity', () => {
  it('runs an armed AI boss under the same rules, without illegal actions', () => {
    const manager = new MatchManager();
    const engine = manager.create({
      scenarioId: 'BANDIT_AMBUSH',
      seed: 4242,
      players: [
        { playerId: 'hero', deck: starterDeckFor('healer'), controller: 'HUMAN' },
        { playerId: 'boss', deck: starterDeckFor('striker'), controller: 'AI' },
      ],
    });

    // The scenario arms the ambusher before the first turn.
    expect(engine.state.sides.boss!.hero.equippedWeapon?.definitionId).toBe('rusty_dagger');

    // Ending the turn hands control to the AI, which plays until it passes
    // back. `act` throws on an illegal AI action, so reaching the assertions
    // is itself the check that the AI stayed legal with a Weapon in hand.
    for (let round = 0; round < 6; round += 1) {
      if (engine.state.phase !== 'PLAYING') break;
      const result = manager.act(engine.state.matchId, {
        type: 'END_TURN',
        actorId: 'hero',
      });
      expect(result.ok).toBe(true);
    }

    const boss = engine.state.sides.boss!.hero;
    expect(boss.attacksUsedThisTurn).toBeLessThanOrEqual(1);
    if (boss.equippedWeapon) expect(boss.equippedWeapon.currentDurability).toBeGreaterThan(0);
    // The armed AI actually used its Weapon rather than ignoring it.
    expect(engine.state.sides.hero!.hero.currentHealth).toBeLessThan(30);
  });
});
