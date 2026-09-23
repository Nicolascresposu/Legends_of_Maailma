import { describe, expect, it } from 'vitest';
import {
  BasicAIController,
  GameEngine,
  createReplay,
  replayMatch,
  validateDeck,
} from '@maailma/game-engine';
import { SCENARIO_DEFINITIONS, starterDeckFor } from '@maailma/card-definitions';

// Side A is The Mender (Priest) and side B The Striker (Wizard) in every
// scenario used here, so each side plays its own class's starter deck.
const PRIEST_STARTER = starterDeckFor('healer');
const WIZARD_STARTER = starterDeckFor('striker');
import type { MatchSetup } from '@maailma/game-model';

function setup(seed: number | string): MatchSetup {
  return {
    scenario: structuredClone(SCENARIO_DEFINITIONS.STANDARD_PVP!),
    seed,
    players: [
      { playerId: 'a', deck: [...PRIEST_STARTER] },
      { playerId: 'b', deck: [...WIZARD_STARTER] },
    ],
  };
}

describe('determinism and replay', () => {
  it('produces identical shuffled state and results for the same seed and actions', () => {
    const first = new GameEngine(setup('same-seed'));
    const second = new GameEngine(setup('same-seed'));
    for (const action of [
      { type: 'END_TURN', actorId: 'a' } as const,
      { type: 'END_TURN', actorId: 'b' } as const,
    ]) {
      expect(first.dispatch(action)).toEqual(second.dispatch(action));
    }
    expect(first.state).toEqual(second.state);
  });

  it('different seeds produce different deck ordering', () => {
    const first = new GameEngine(setup(1));
    const second = new GameEngine(setup(2));
    expect(first.state.sides.a!.deck).not.toEqual(second.state.sides.a!.deck);
  });

  it('reconstructs a match exactly from setup and action history', () => {
    const originalSetup = setup(42);
    const engine = new GameEngine(originalSetup);
    const actions = [
      { type: 'END_TURN', actorId: 'a' } as const,
      { type: 'END_TURN', actorId: 'b' } as const,
      { type: 'END_TURN', actorId: 'a' } as const,
    ];
    for (const action of actions) expect(engine.dispatch(action).ok).toBe(true);
    const replayed = replayMatch(createReplay(originalSetup, actions));
    expect(replayed.state).toEqual(engine.state);
  });
});

describe('deck and controller foundations', () => {
  it('accepts the 30-card starter deck and enforces Legendary copy limits', () => {
    expect(validateDeck(PRIEST_STARTER).valid).toBe(true);
    const invalid = [...PRIEST_STARTER];
    invalid[0] = 'lio_varga';
    invalid[1] = 'lio_varga';
    expect(validateDeck(invalid).errors.some((error) => error.includes('1-copy'))).toBe(true);
  });

  it('basic AI always emits an action from the legal action set', () => {
    const engine = new GameEngine({
      ...setup(7),
      scenario: structuredClone(SCENARIO_DEFINITIONS.BANDIT_AMBUSH!),
      players: [
        { playerId: 'human', deck: [...PRIEST_STARTER], controller: 'HUMAN' },
        { playerId: 'ai', deck: [...WIZARD_STARTER], controller: 'AI' },
      ],
    });
    engine.dispatch({ type: 'END_TURN', actorId: 'human' });
    const ai = new BasicAIController();
    const action = ai.chooseAction(engine, 'ai');
    expect(action).toBeDefined();
    expect(engine.getLegalActions('ai')).toContainEqual(action);
  });

  it('Bandit Ambush proves nonstandard width and asymmetric PvE setup', () => {
    const engine = new GameEngine({
      ...setup(9),
      scenario: structuredClone(SCENARIO_DEFINITIONS.BANDIT_AMBUSH!),
      players: [
        { playerId: 'human', deck: [...PRIEST_STARTER] },
        { playerId: 'bandits', deck: [...WIZARD_STARTER], controller: 'AI' },
      ],
    });
    expect(engine.state.sides.human!.battlefield.config.width).toBe(2);
    expect(engine.state.sides.bandits!.hero.maxHealth).toBe(20);
    expect(Object.keys(engine.state.sides.bandits!.creatures)).toHaveLength(1);
  });
});
