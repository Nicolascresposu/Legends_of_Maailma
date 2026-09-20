import { describe, expect, it } from 'vitest';
import { heroEntityId } from '@maailma/game-engine';
import { creatureId, makeEngine } from './helpers.js';

describe('melee and ranged targeting', () => {
  it('lets a front-row melee Creature attack any enemy front column', () => {
    for (const column of [0, 1, 2]) {
      const engine = makeEngine({
        a: [{ definitionId: 'wolf', position: { row: 'FRONT', column: 1 } }],
        b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column } }],
      });
      expect(
        engine.dispatch({
          type: 'ATTACK',
          actorId: 'a',
          attackerId: creatureId(engine, 'a', 'wolf'),
          targetId: creatureId(engine, 'b', 'brown_bear'),
        }).ok,
      ).toBe(true);
    }
  });

  it('rejects a normal back-row attacker', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'wolf', position: { row: 'BACK', column: 0 } }],
      b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
    });
    expect(
      engine.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: creatureId(engine, 'a', 'wolf'),
        targetId: creatureId(engine, 'b', 'brown_bear'),
      }).error?.code,
    ).toBe('BACK_ROW_MELEE');
  });

  it('protects a back-row target only when its same-column front tile is occupied', () => {
    const shielded = makeEngine({
      a: [{ definitionId: 'wolf', position: { row: 'FRONT', column: 0 } }],
      b: [
        { definitionId: 'hawk', position: { row: 'BACK', column: 2 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 2 } },
      ],
    });
    expect(
      shielded.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: creatureId(shielded, 'a', 'wolf'),
        targetId: creatureId(shielded, 'b', 'hawk'),
      }).error?.code,
    ).toBe('BACK_ROW_PROTECTED');

    const exposed = makeEngine({
      a: [{ definitionId: 'wolf', position: { row: 'FRONT', column: 0 } }],
      b: [{ definitionId: 'hawk', position: { row: 'BACK', column: 2 } }],
    });
    expect(
      exposed.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: creatureId(exposed, 'a', 'wolf'),
        targetId: creatureId(exposed, 'b', 'hawk'),
      }).ok,
    ).toBe(true);
  });

  it('allows Ranged attacks from either row and ignores front shielding', () => {
    for (const attackerRow of ['FRONT', 'BACK'] as const) {
      const engine = makeEngine({
        a: [{ definitionId: 'elf_archer', position: { row: attackerRow, column: 0 } }],
        b: [
          { definitionId: 'hawk', position: { row: 'BACK', column: 2 } },
          { definitionId: 'brown_bear', position: { row: 'FRONT', column: 2 } },
        ],
      });
      expect(
        engine.dispatch({
          type: 'ATTACK',
          actorId: 'a',
          attackerId: creatureId(engine, 'a', 'elf_archer'),
          targetId: creatureId(engine, 'b', 'hawk'),
        }).ok,
      ).toBe(true);
    }
  });

  it('allows attacks on the enemy Hero while ordinary enemy Creatures remain', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'wolf', position: { row: 'FRONT', column: 0 } }],
      b: [{ definitionId: 'brown_bear', position: { row: 'FRONT', column: 0 } }],
    });
    expect(
      engine.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: creatureId(engine, 'a', 'wolf'),
        targetId: heroEntityId('b'),
      }).ok,
    ).toBe(true);
    expect(engine.state.sides.b!.hero.currentHealth).toBe(28);
  });
});

describe('Guard', () => {
  it('protects orthogonal allies but not diagonal allies or other Guards', () => {
    const orthogonal = makeEngine({
      a: [{ definitionId: 'elf_archer', position: { row: 'FRONT', column: 0 } }],
      b: [
        { definitionId: 'dwarf_defender', position: { row: 'BACK', column: 1 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 1 } },
      ],
    });
    expect(
      orthogonal.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: creatureId(orthogonal, 'a', 'elf_archer'),
        targetId: creatureId(orthogonal, 'b', 'brown_bear'),
      }).error?.code,
    ).toBe('TARGET_GUARDED');

    const diagonal = makeEngine({
      a: [{ definitionId: 'elf_archer', position: { row: 'FRONT', column: 0 } }],
      b: [
        { definitionId: 'dwarf_defender', position: { row: 'BACK', column: 0 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 1 } },
      ],
    });
    expect(
      diagonal.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: creatureId(diagonal, 'a', 'elf_archer'),
        targetId: creatureId(diagonal, 'b', 'brown_bear'),
      }).ok,
    ).toBe(true);

    const guards = makeEngine({
      a: [{ definitionId: 'elf_archer', position: { row: 'FRONT', column: 0 } }],
      b: [
        { definitionId: 'dwarf_defender', position: { row: 'FRONT', column: 0 } },
        { definitionId: 'dwarf_defender', position: { row: 'FRONT', column: 1 } },
      ],
    });
    const target = Object.values(guards.state.sides.b!.creatures).find(
      (c) => c.position.column === 0,
    )!;
    expect(
      guards.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: creatureId(guards, 'a', 'elf_archer'),
        targetId: target.instanceId,
      }).ok,
    ).toBe(true);
  });

  it('blocks Hero attacks until the final Guard dies', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'darek_voln', position: { row: 'FRONT', column: 0 } }],
      b: [{ definitionId: 'dwarf_defender', position: { row: 'FRONT', column: 0 } }],
    });
    const attacker = creatureId(engine, 'a', 'darek_voln');
    expect(
      engine.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: attacker,
        targetId: heroEntityId('b'),
      }).error?.code,
    ).toBe('HERO_GUARDED');
    expect(
      engine.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: attacker,
        targetId: creatureId(engine, 'b', 'dwarf_defender'),
      }).ok,
    ).toBe(true);
    expect(Object.keys(engine.state.sides.b!.creatures)).toHaveLength(0);
    engine.state.sides.a!.creatures[attacker]!.combatActionUsed = false;
    expect(
      engine.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: attacker,
        targetId: heroEntityId('b'),
      }).ok,
    ).toBe(true);
  });

  it('Ranged still obeys Guard protection', () => {
    const engine = makeEngine({
      a: [{ definitionId: 'elf_archer', position: { row: 'BACK', column: 0 } }],
      b: [
        { definitionId: 'dwarf_defender', position: { row: 'FRONT', column: 1 } },
        { definitionId: 'brown_bear', position: { row: 'FRONT', column: 2 } },
      ],
    });
    expect(
      engine.dispatch({
        type: 'ATTACK',
        actorId: 'a',
        attackerId: creatureId(engine, 'a', 'elf_archer'),
        targetId: creatureId(engine, 'b', 'brown_bear'),
      }).error?.code,
    ).toBe('TARGET_GUARDED');
  });
});
