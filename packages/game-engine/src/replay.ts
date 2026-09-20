import type { GameAction, MatchSetup, ReplayData } from '@maailma/game-model';
import { GameEngine } from './engine.js';

export function createReplay(setup: MatchSetup, actions: readonly GameAction[]): ReplayData {
  return { setup: structuredClone(setup), actions: Array.from(structuredClone(actions)) };
}

export function replayMatch(replay: ReplayData): GameEngine {
  return GameEngine.replay(replay);
}

export function stableStateJson(engine: GameEngine): string {
  return JSON.stringify(engine.state);
}
