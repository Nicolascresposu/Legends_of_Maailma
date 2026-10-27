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

/**
 * A crude standing for a Weapon, used only to avoid the obviously bad play of
 * throwing away a better Weapon for a worse one. Strategic Weapon evaluation is
 * explicitly not a goal here.
 */
function weaponValue(attack: number, durability: number, ranged: boolean): number {
  // Ranged trades damage for safety, so it is worth a little more than its
  // raw numbers suggest.
  return attack * durability + (ranged ? 1 : 0);
}

/** Stable priority order makes AI games exactly replayable from their emitted action log. */
export class BasicAIController implements MatchController {
  readonly kind = 'AI' as const;

  chooseAction(engine: GameEngine, playerId: PlayerId): GameAction | undefined {
    const legal = engine.getLegalActions(playerId);
    return (
      legal.find((action) => this.wantsToPlay(engine, playerId, action)) ??
      legal.find((action) => action.type === 'ATTACK') ??
      legal.find((action) => action.type === 'HERO_ATTACK') ??
      legal.find((action) => action.type === 'ACTIVATE_LOCATION') ??
      legal.find((action) => action.type === 'USE_HERO_POWER') ??
      legal.find((action) => action.type === 'MOVE_CREATURE') ??
      legal.find((action) => action.type === 'SWAP_CREATURES') ??
      legal.find((action) => action.type === 'END_TURN')
    );
  }

  /**
   * Whether to play a card from hand. Everything is worth playing except a
   * Weapon that would replace a better one still in good repair.
   */
  private wantsToPlay(engine: GameEngine, playerId: PlayerId, action: GameAction): boolean {
    if (action.type !== 'PLAY_CARD') return false;
    const side = engine.state.sides[playerId];
    const card = side?.hand.find((entry) => entry.instanceId === action.cardInstanceId);
    if (!card) return false;
    const definition = engine.getCardDefinition(card.definitionId);
    if (definition.type !== 'WEAPON') return true;
    const equipped = side!.hero.equippedWeapon;
    if (!equipped) return true;
    const current = engine.getCardDefinition(equipped.definitionId);
    if (current.type !== 'WEAPON') return true;
    return (
      weaponValue(definition.attack, definition.durability, definition.range === 'RANGED') >
      weaponValue(equipped.currentAttack, equipped.currentDurability, current.range === 'RANGED')
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
