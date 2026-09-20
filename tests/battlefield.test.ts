import { describe, expect, it } from 'vitest';
import {
  adjacentPositions,
  allPositions,
  areOrthogonallyAdjacent,
  createBattlefield,
  entityAt,
  setEntityAt,
} from '@maailma/game-engine';

describe('battlefield geometry', () => {
  for (const width of [1, 2, 3, 4]) {
    it(`creates a two-row battlefield with width ${width}`, () => {
      const board = createBattlefield({ width });
      expect(allPositions(board)).toHaveLength(width * 2);
      expect(board.slots.FRONT).toHaveLength(width);
      expect(board.slots.BACK).toHaveLength(width);
    });
  }

  it('finds edge and center adjacency dynamically', () => {
    const board = createBattlefield({ width: 4 });
    expect(adjacentPositions(board, { row: 'FRONT', column: 0 })).toEqual([
      { row: 'FRONT', column: 1 },
      { row: 'BACK', column: 0 },
    ]);
    expect(adjacentPositions(board, { row: 'BACK', column: 2 })).toHaveLength(3);
  });

  it('recognizes only orthogonal adjacency', () => {
    expect(areOrthogonallyAdjacent({ row: 'FRONT', column: 1 }, { row: 'BACK', column: 1 })).toBe(
      true,
    );
    expect(areOrthogonallyAdjacent({ row: 'FRONT', column: 1 }, { row: 'FRONT', column: 2 })).toBe(
      true,
    );
    expect(areOrthogonallyAdjacent({ row: 'FRONT', column: 1 }, { row: 'BACK', column: 2 })).toBe(
      false,
    );
  });

  it('places and reads entities', () => {
    const board = createBattlefield({ width: 2 });
    setEntityAt(board, { row: 'BACK', column: 1 }, 'creature');
    expect(entityAt(board, { row: 'BACK', column: 1 })).toBe('creature');
  });
});
