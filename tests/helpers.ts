import { SCENARIO_DEFINITIONS } from '@maailma/card-definitions';
import { GameEngine } from '@maailma/game-engine';
import type { Position, ScenarioDefinition } from '@maailma/game-model';

interface CreaturePlacement {
  definitionId: string;
  position: Position;
}

export function makeEngine(
  options: {
    width?: number;
    a?: CreaturePlacement[];
    b?: CreaturePlacement[];
    taika?: number;
    deckA?: string[];
    deckB?: string[];
    seed?: number | string;
  } = {},
): GameEngine {
  const width = options.width ?? 3;
  const taika = options.taika ?? 10;
  const scenario: ScenarioDefinition = {
    ...structuredClone(SCENARIO_DEFINITIONS.STANDARD_PVP),
    id: `TEST_${width}`,
    battlefield: { width },
    sideA: {
      ...structuredClone(SCENARIO_DEFINITIONS.STANDARD_PVP!.sideA),
      startingTaika: taika,
      maxTaika: 10,
      startingCreatures: options.a ?? [],
    },
    sideB: {
      ...structuredClone(SCENARIO_DEFINITIONS.STANDARD_PVP!.sideB),
      startingTaika: taika,
      maxTaika: 10,
      startingCreatures: options.b ?? [],
    },
  };
  return new GameEngine({
    scenario,
    seed: options.seed ?? 123,
    players: [
      { playerId: 'a', deck: options.deckA ?? [] },
      { playerId: 'b', deck: options.deckB ?? [] },
    ],
  });
}

export function creatureId(engine: GameEngine, playerId: 'a' | 'b', definitionId: string): string {
  const creature = Object.values(engine.state.sides[playerId]!.creatures).find(
    (candidate) => candidate.definitionId === definitionId,
  );
  if (!creature) throw new Error(`Missing ${definitionId} for ${playerId}`);
  return creature.instanceId;
}
