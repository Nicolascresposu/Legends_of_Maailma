import type {
  Battlefield,
  BattlefieldConfig,
  BattlefieldRow,
  EntityId,
  Position,
} from '@maailma/game-model';
import { ROWS } from '@maailma/game-model';

export function createBattlefield(config: BattlefieldConfig): Battlefield {
  if (!Number.isInteger(config.width) || config.width < 1) {
    throw new Error('Battlefield width must be a positive integer');
  }
  return {
    config: { width: config.width },
    slots: {
      FRONT: Array<EntityId | null>(config.width).fill(null),
      BACK: Array<EntityId | null>(config.width).fill(null),
    },
  };
}

export function isPositionValid(board: Battlefield, position: Position): boolean {
  return (
    ROWS.includes(position.row) && position.column >= 0 && position.column < board.config.width
  );
}

export function entityAt(board: Battlefield, position: Position): EntityId | null {
  if (!isPositionValid(board, position)) return null;
  return board.slots[position.row][position.column] ?? null;
}

export function setEntityAt(
  board: Battlefield,
  position: Position,
  entityId: EntityId | null,
): void {
  if (!isPositionValid(board, position)) throw new Error('Position is outside the battlefield');
  board.slots[position.row][position.column] = entityId;
}

export function allPositions(board: Battlefield): Position[] {
  return ROWS.flatMap((row) =>
    Array.from({ length: board.config.width }, (_, column) => ({ row, column })),
  );
}

export function emptyPositions(board: Battlefield): Position[] {
  return allPositions(board).filter((position) => entityAt(board, position) === null);
}

export function areOrthogonallyAdjacent(first: Position, second: Position): boolean {
  const rowDistance = first.row === second.row ? 0 : 1;
  const columnDistance = Math.abs(first.column - second.column);
  return rowDistance + columnDistance === 1;
}

export function adjacentPositions(board: Battlefield, origin: Position): Position[] {
  const candidates: Position[] = [
    { row: origin.row, column: origin.column - 1 },
    { row: origin.row, column: origin.column + 1 },
    { row: oppositeRow(origin.row), column: origin.column },
  ];
  return candidates.filter((position) => isPositionValid(board, position));
}

export function oppositeRow(row: BattlefieldRow): BattlefieldRow {
  return row === 'FRONT' ? 'BACK' : 'FRONT';
}

export function clonePosition(position: Position): Position {
  return { row: position.row, column: position.column };
}
