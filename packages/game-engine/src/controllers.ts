import type { GameAction, MatchState, PlayerId } from '@maailma/game-model';
import type { GameEngine } from './engine.js';

export interface MatchController {
  readonly kind: 'HUMAN' | 'AI' | 'SCRIPTED';
  chooseAction(engine: GameEngine, playerId: PlayerId): GameAction | undefined;
}

export class HumanController implements MatchController {
  readonly kind = 'HUMAN' as const;

  chooseAction(): undefined {
    return undefined;
  }
}

/** Stable priority order makes AI games exactly replayable from their emitted action log. */
export class BasicAIController implements MatchController {
  readonly kind = 'AI' as const;

  chooseAction(engine: GameEngine, playerId: PlayerId): GameAction | undefined {
    const legal = engine.getLegalActions(playerId);
    return (
      legal.find((action) => action.type === 'PLAY_CARD') ??
      legal.find((action) => action.type === 'ATTACK') ??
      legal.find((action) => action.type === 'USE_HERO_POWER') ??
      legal.find((action) => action.type === 'MOVE_CREATURE') ??
      legal.find((action) => action.type === 'SWAP_CREATURES') ??
      legal.find((action) => action.type === 'END_TURN')
    );
  }
}

export class ScriptedController implements MatchController {
  readonly kind = 'SCRIPTED' as const;
  private readonly actions: GameAction[];

  constructor(actions: readonly GameAction[]) {
    this.actions = Array.from(structuredClone(actions));
  }

  chooseAction(engine: GameEngine, playerId: PlayerId): GameAction | undefined {
    const next = this.actions[0];
    if (!next || next.actorId !== playerId) return undefined;
    const legal = engine.getLegalActions(playerId);
    if (!legal.some((action) => JSON.stringify(action) === JSON.stringify(next))) return undefined;
    return this.actions.shift();
  }
}

export function isControllerTurn(state: MatchState, kind: MatchController['kind']): boolean {
  return state.sides[state.activePlayerId]?.controller === kind;
}
