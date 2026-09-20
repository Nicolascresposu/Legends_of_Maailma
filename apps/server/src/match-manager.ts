import { randomUUID } from 'node:crypto';
import { getHeroDefinition, getScenarioDefinition } from '@maailma/card-definitions';
import { BasicAIController, GameEngine, validateDeck } from '@maailma/game-engine';
import type { GameAction, GameEvent, MatchSetup } from '@maailma/game-model';
import type { CreateMatchRequest } from '@maailma/protocol';
import { InMemoryMatchRepository, type MatchRepository } from './match-repository.js';

export interface ManagedActionResult {
  ok: boolean;
  events: GameEvent[];
  error?: { code: string; message: string };
}

export class MatchManager {
  private readonly ai = new BasicAIController();

  constructor(private readonly matches: MatchRepository = new InMemoryMatchRepository()) {}

  create(request: CreateMatchRequest): GameEngine {
    const scenario = getScenarioDefinition(request.scenarioId);
    for (const player of request.players) {
      const validation = validateDeck(player.deck);
      if (!validation.valid) throw new Error(validation.errors.join('; '));
    }
    const matchId = randomUUID();
    const setup: MatchSetup = {
      matchId,
      scenario: structuredClone(scenario),
      seed: request.seed ?? randomUUID(),
      players: structuredClone(request.players),
    };
    const engine = new GameEngine(setup);
    this.matches.save(engine);
    return engine;
  }

  get(matchId: string): GameEngine | undefined {
    return this.matches.get(matchId);
  }

  selectHero(matchId: string, playerId: string, heroDefinitionId: string): void {
    const engine = this.matches.get(matchId);
    if (!engine) throw new Error('Match not found');
    const side = engine.state.sides[playerId];
    if (!side) throw new Error('Player is not part of the match');
    if (engine.state.actionLog.length > 0)
      throw new Error('Heroes cannot change after play begins');
    getHeroDefinition(heroDefinitionId);
    side.hero.definitionId = heroDefinitionId;
    side.hero.currentHealth = side.hero.maxHealth;
    side.hero.powerUsedThisTurn = false;
    const setupPlayer = engine.setup.players.find((player) => player.playerId === playerId);
    if (setupPlayer) setupPlayer.heroDefinitionId = heroDefinitionId;
  }

  act(matchId: string, action: GameAction): ManagedActionResult {
    const engine = this.matches.get(matchId);
    if (!engine)
      return {
        ok: false,
        events: [],
        error: { code: 'MATCH_NOT_FOUND', message: 'Match not found' },
      };
    const result = engine.dispatch(action);
    if (!result.ok) return result;
    const events = [...result.events];
    let safety = 0;
    while (
      engine.state.phase === 'PLAYING' &&
      engine.state.sides[engine.state.activePlayerId]?.controller === 'AI'
    ) {
      safety += 1;
      if (safety > 100) throw new Error('AI turn exceeded action safety limit');
      const aiAction = this.ai.chooseAction(engine, engine.state.activePlayerId);
      if (!aiAction) break;
      const aiResult = engine.dispatch(aiAction);
      if (!aiResult.ok)
        throw new Error(`AI produced an illegal action: ${aiResult.error?.message}`);
      events.push(...aiResult.events);
    }
    return { ok: true, events };
  }
}
