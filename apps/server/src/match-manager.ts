import { randomUUID } from 'node:crypto';
import {
  getHeroDefinition,
  captureCardContent,
  getScenarioDefinition,
  starterDeckFor,
} from '@maailma/card-definitions';
import { BasicAIController, GameEngine, validateDeck } from '@maailma/game-engine';
import type {
  CardContentSnapshot,
  DebugEdit,
  GameAction,
  GameEvent,
  MatchSetup,
} from '@maailma/game-model';
import type { CreateMatchPlayer, CreateMatchRequest } from '@maailma/protocol';
import { InMemoryMatchRepository, type MatchRepository } from './match-repository.js';

export interface ManagedActionResult {
  ok: boolean;
  events: GameEvent[];
  error?: { code: string; message: string };
}

/**
 * The player id that holds a PvP match's second seat until someone takes it.
 *
 * A placeholder rather than an absent side, because the engine is built with
 * both sides present; it is never joinable and never gets to act.
 */
export const OPEN_SEAT_ID = 'open-seat';

/** The seat an AI opponent plays from in a player-versus-environment match. */
export const AI_PLAYER_ID = 'ai';

/** Told when a match changes other than through a player's own action. */
export type MatchChangeListener = (matchId: string, events: GameEvent[]) => void;

export class MatchManager {
  private readonly ai = new BasicAIController();
  /** Matches still waiting for an opponent, by match id. */
  private readonly openSeats = new Set<string>();
  private readonly listeners: MatchChangeListener[] = [];

  constructor(private readonly matches: MatchRepository = new InMemoryMatchRepository()) {}

  create(request: CreateMatchRequest): GameEngine {
    const engine = this.build(request.scenarioId, request.seed ?? randomUUID(), request.players);
    this.matches.save(engine);
    return engine;
  }

  /**
   * Creates a PvP match whose second seat is left open for whoever takes it.
   *
   * The creator brings their own deck; the opponent brings theirs when they
   * take the seat, through `claimSeat`. Until then nobody may act, so the
   * creator cannot get a turn in before an opponent has even arrived.
   */
  createWithOpenSeat(request: {
    scenarioId: string;
    seed?: number | string;
    creator: CreateMatchPlayer;
  }): GameEngine {
    const engine = this.create({
      scenarioId: request.scenarioId,
      ...(request.seed === undefined ? {} : { seed: request.seed }),
      players: [request.creator, { playerId: OPEN_SEAT_ID, controller: 'HUMAN' }],
    });
    this.openSeats.add(engine.state.matchId);
    return engine;
  }

  /** Whether a match is still waiting for someone to take its open seat. */
  hasOpenSeat(matchId: string): boolean {
    return this.openSeats.has(matchId);
  }

  /**
   * Seats a player, with their own deck, in a match's open seat.
   *
   * The match is rebuilt from its setup rather than patched: the open seat's
   * placeholder deck was already shuffled and dealt, and a fresh engine from
   * the same seed is the one way to deal the real deck as fairly as the first.
   * Nothing has happened yet — no one could act while the seat was open — so
   * there is nothing a rebuild could lose.
   */
  claimSeat(matchId: string, player: CreateMatchPlayer): GameEngine {
    const engine = this.matches.get(matchId);
    if (!engine) throw new Error('Match not found');
    if (!this.openSeats.has(matchId)) throw new Error('That match has no open seat');
    if (engine.state.sides[player.playerId]) throw new Error('You are already in this match');
    const players = engine.setup.players.map((existing) =>
      existing.playerId === OPEN_SEAT_ID ? player : existing,
    ) as unknown as CreateMatchRequest['players'];
    const rebuilt = this.build(
      engine.setup.scenario.id,
      engine.setup.seed,
      players,
      matchId,
      engine.content,
    );
    this.matches.save(rebuilt);
    this.openSeats.delete(matchId);
    return rebuilt;
  }

  /**
   * What a player may do now: nothing at all while the match waits for an
   * opponent, since the match has not really begun.
   */
  legalActions(matchId: string, playerId: string): GameAction[] {
    const engine = this.matches.get(matchId);
    if (!engine || this.openSeats.has(matchId)) return [];
    return engine.getLegalActions(playerId);
  }

  get(matchId: string): GameEngine | undefined {
    return this.matches.get(matchId);
  }

  /**
   * Registers for changes nobody in the match asked for — an admin edit — so
   * the transport can tell connected players, who would otherwise never learn
   * of them.
   */
  onChange(listener: MatchChangeListener): void {
    this.listeners.push(listener);
  }

  /**
   * Applies an admin edit to a live match and tells whoever is watching.
   * Throws on a refusal, with the engine's code, so callers can relay it.
   */
  debugEdit(matchId: string, edit: DebugEdit): GameEvent[] {
    const engine = this.matches.get(matchId);
    if (!engine) throw new MatchEditError('MATCH_NOT_FOUND', 'Match not found', 404);
    const result = engine.applyDebugEdit(edit);
    if (!result.ok) {
      throw new MatchEditError(result.error!.code, result.error!.message);
    }
    for (const listener of this.listeners) listener(matchId, result.events);
    return result.events;
  }

  /** Every live match. For operator tooling; players reach matches by id. */
  list(): GameEngine[] {
    return this.matches.list();
  }

  /**
   * Removes a match outright. Anyone still connected finds it gone on their
   * next message, exactly as if the server had restarted.
   */
  remove(matchId: string): boolean {
    this.openSeats.delete(matchId);
    return this.matches.delete(matchId);
  }

  private build(
    scenarioId: string,
    seed: number | string,
    requested: CreateMatchRequest['players'],
    matchId: string = randomUUID(),
    content: CardContentSnapshot = captureCardContent(),
  ): GameEngine {
    const scenario = getScenarioDefinition(scenarioId);
    const sides = [scenario.sideA, scenario.sideB] as const;
    // Each player's hero is the one they chose, or else the scenario's for
    // their side. A deck is always judged as that hero's class, and a player
    // who brought no deck plays the starter deck of that class.
    const players = requested.map((player, index) => {
      const heroId = player.heroDefinitionId ?? sides[index]!.heroDefinitionId;
      const classId = getHeroDefinition(heroId).classId;
      const deck = player.deck ? [...player.deck] : starterDeckFor(heroId);
      const validation = validateDeck(deck, {
        classId,
        getCardDefinition: (id) => {
          const card = content.cards[id];
          if (!card) throw new Error(`Unknown card: ${id}`);
          return card;
        },
      });
      if (!validation.valid) throw new Error(validation.errors.join('; '));
      return { ...structuredClone(player), deck };
    }) as unknown as MatchSetup['players'];
    const setup: MatchSetup = {
      matchId,
      content,
      scenario: structuredClone(scenario),
      seed,
      players,
    };
    return new GameEngine(setup);
  }

  selectHero(matchId: string, playerId: string, heroDefinitionId: string): void {
    const engine = this.matches.get(matchId);
    if (!engine) throw new Error('Match not found');
    const side = engine.state.sides[playerId];
    if (!side) throw new Error('Player is not part of the match');
    if (engine.state.actionLog.length > 0)
      throw new Error('Heroes cannot change after play begins');
    const hero = getHeroDefinition(heroDefinitionId);
    const setupDeck = engine.setup.players.find((player) => player.playerId === playerId)?.deck;
    // The deck was judged as the old hero's class when the match was made; a
    // new hero must be one that could legally play it too, or switching hero
    // would be a way round the class rule.
    if (setupDeck) {
      const validation = validateDeck(setupDeck, {
        classId: hero.classId,
        getCardDefinition: (id) => engine.getCardDefinition(id),
      });
      if (!validation.valid) {
        throw new Error(`${hero.name} cannot play this deck: ${validation.errors.join('; ')}`);
      }
    }
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
    if (this.openSeats.has(matchId))
      return {
        ok: false,
        events: [],
        error: {
          code: 'WAITING_FOR_OPPONENT',
          message: 'The match begins once an opponent takes the open seat',
        },
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

/** An admin edit the engine refused, with its code. */
export class MatchEditError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status = 409,
  ) {
    super(message);
    this.name = 'MatchEditError';
  }
}
