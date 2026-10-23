import { captureCardContent } from '@maailma/card-definitions';
import type { GameAction, MatchSetup, ReplayData } from '@maailma/game-model';
import { GameEngine } from './engine.js';

export function createReplay(setup: MatchSetup, actions: readonly GameAction[]): ReplayData {
  const pinned = setup.content ?? captureCardContent();
  const used = new GameEngine({ ...setup, content: pinned }).presentationCards();
  return {
    setup: structuredClone({
      ...setup,
      content: {
        version: pinned.version,
        cards: Object.fromEntries(used.map((card) => [card.id, card])),
      },
    }),
    actions: Array.from(structuredClone(actions)),
  };
}

export function replayMatch(replay: ReplayData): GameEngine {
  return GameEngine.replay(replay);
}

export function stableStateJson(engine: GameEngine): string {
  return JSON.stringify(engine.state);
}
