import type { GameEngine } from '@maailma/game-engine';

/**
 * Active-match persistence boundary. The v0.1 server uses memory; a Redis-backed
 * implementation can replace it without changing HTTP, WebSocket, or engine code.
 */
export interface MatchRepository {
  get(matchId: string): GameEngine | undefined;
  save(engine: GameEngine): void;
  delete(matchId: string): boolean;
  /** Every live match, for operator tooling. */
  list(): GameEngine[];
}

export class InMemoryMatchRepository implements MatchRepository {
  private readonly matches = new Map<string, GameEngine>();

  get(matchId: string): GameEngine | undefined {
    return this.matches.get(matchId);
  }

  save(engine: GameEngine): void {
    this.matches.set(engine.state.matchId, engine);
  }

  delete(matchId: string): boolean {
    return this.matches.delete(matchId);
  }

  list(): GameEngine[] {
    return [...this.matches.values()];
  }
}
