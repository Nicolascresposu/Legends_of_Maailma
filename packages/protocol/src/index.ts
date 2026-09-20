import type {
  ActionResult,
  GameAction,
  GameEvent,
  MatchState,
  PlayerId,
} from '@maailma/game-model';

export type ClientMessage =
  | { type: 'JOIN_MATCH'; matchId: string; playerId: PlayerId }
  | { type: 'SELECT_HERO'; matchId: string; playerId: PlayerId; heroDefinitionId: string }
  | { type: 'SUBMIT_ACTION'; matchId: string; action: GameAction };

export type ServerMessage =
  | { type: 'MATCH_STATE'; state: MatchState }
  | { type: 'LEGAL_ACTIONS'; playerId: PlayerId; actions: GameAction[] }
  | { type: 'GAME_EVENTS'; events: GameEvent[] }
  | { type: 'TURN_CHANGED'; activePlayerId: PlayerId; turn: number }
  | { type: 'MATCH_ENDED'; winnerId?: PlayerId }
  | { type: 'ERROR'; code: string; message: string };

export interface CreateMatchRequest {
  scenarioId: string;
  seed?: number | string;
  players: readonly [
    { playerId: string; heroDefinitionId?: string; deck: string[]; controller?: 'HUMAN' | 'AI' },
    { playerId: string; heroDefinitionId?: string; deck: string[]; controller?: 'HUMAN' | 'AI' },
  ];
}

export interface CreateMatchResponse {
  matchId: string;
  state: MatchState;
}

export interface SubmitActionResponse extends ActionResult {
  state: MatchState;
}

export function isClientMessage(value: unknown): value is ClientMessage {
  if (!value || typeof value !== 'object' || !('type' in value)) return false;
  const type = (value as { type: unknown }).type;
  return type === 'JOIN_MATCH' || type === 'SELECT_HERO' || type === 'SUBMIT_ACTION';
}
