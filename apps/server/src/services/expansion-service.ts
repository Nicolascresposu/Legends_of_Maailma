import type { PrismaClient } from '@prisma/client';
import {
  CARD_DEFINITIONS,
  EXPANSION_DEFINITIONS,
  canCraftExpansion,
  canDisenchantExpansion,
  canOpenExpansionPacks,
  canTradeExpansion,
  getCardDefinition,
  hasDuplicateProtection,
  isBasicRarity,
  isExpansionStandardLegal,
  isExpansionWildLegal,
  validateExpansionPolicy,
} from '@maailma/card-definitions';
import type {
  CardDefinition,
  DeckFormat,
  ExpansionDefinition,
  ExpansionPolicy,
} from '@maailma/game-model';
import { EXPANSION_POLICY_FLAGS } from '@maailma/game-model';
import { AccountError } from './account-service.js';

/**
 * The structured reasons an economy request can be refused.
 *
 * Named rather than free text because the Godot client — and any client after
 * it — has to explain the refusal in its own words, and "Machines of Kona
 * cards are no longer tradeable" is a better message than a relayed English
 * sentence from the server.
 */
export const ECONOMY_ERRORS = {
  UNKNOWN_CARD: 'UNKNOWN_CARD',
  UNKNOWN_EXPANSION: 'UNKNOWN_EXPANSION',
  EXPANSION_NOT_RELEASED: 'EXPANSION_NOT_RELEASED',
  CARD_NOT_COLLECTIBLE: 'CARD_NOT_COLLECTIBLE',
  CARD_NOT_CRAFTABLE: 'CARD_NOT_CRAFTABLE',
  CARD_NOT_DISENCHANTABLE: 'CARD_NOT_DISENCHANTABLE',
  CARD_NOT_TRADEABLE: 'CARD_NOT_TRADEABLE',
  /** Basic cards are free to everyone, so they are never crafted, disenchanted or traded. */
  BASIC_CARD: 'BASIC_CARD',
  EXPANSION_NOT_AVAILABLE_IN_PACKS: 'EXPANSION_NOT_AVAILABLE_IN_PACKS',
  INSUFFICIENT_FRAGMENTS: 'INSUFFICIENT_FRAGMENTS',
  INSUFFICIENT_CARD_QUANTITY: 'INSUFFICIENT_CARD_QUANTITY',
  INVALID_QUANTITY: 'INVALID_QUANTITY',
  TRADE_REVISION_CHANGED: 'TRADE_REVISION_CHANGED',
  TRADE_POLICY_CHANGED: 'TRADE_POLICY_CHANGED',
  DECK_NOT_STANDARD_LEGAL: 'DECK_NOT_STANDARD_LEGAL',
} as const;

export type EconomyErrorCode = (typeof ECONOMY_ERRORS)[keyof typeof ECONOMY_ERRORS];

/** A refusal a client can act on: a code it can translate, plus a fallback. */
export class EconomyError extends AccountError {
  constructor(code: EconomyErrorCode, message: string, status = 409) {
    super(code, message, status);
    this.name = 'EconomyError';
  }
}

/** Every expansion, with whichever policy is currently in force. */
export type LivePolicies = Readonly<Record<string, ExpansionDefinition>>;

/**
 * Live expansion policy.
 *
 * Policies are read through this service and nowhere else, because they are
 * mutable at runtime: a stored override shadows the values shipped with the
 * card definitions, so an operator can rotate a set or switch on duplicate
 * protection between one request and the next. Every check a caller makes is
 * against a snapshot taken for that request, which keeps a single operation
 * internally consistent while still letting the next one see a change.
 */
export class ExpansionService {
  constructor(private readonly prisma: PrismaClient) {}

  /**
   * Every expansion with its effective policy.
   *
   * Taken as one read per operation rather than cached: a policy change has to
   * take effect immediately, and an expansion list is a handful of rows.
   */
  async policies(): Promise<LivePolicies> {
    const overrides = await this.prisma.expansionPolicyOverride.findMany();
    const byId = new Map(overrides.map((row) => [row.expansionId, row]));
    const entries = Object.values(EXPANSION_DEFINITIONS).map((definition) => {
      const override = byId.get(definition.id);
      const policy: ExpansionPolicy = override
        ? {
            released: override.released,
            tradeable: override.tradeable,
            duplicateProtection: override.duplicateProtection,
            craftable: override.craftable,
            disenchantable: override.disenchantable,
            availableInPacks: override.availableInPacks,
            standard: override.standard,
          }
        : { ...definition.policy };
      return [definition.id, { ...definition, policy }] as const;
    });
    return Object.freeze(Object.fromEntries(entries));
  }

  /** One expansion's live policy, or a refusal naming the missing id. */
  async policy(expansionId: string): Promise<ExpansionDefinition> {
    const all = await this.policies();
    const expansion = all[expansionId];
    if (!expansion) {
      throw new EconomyError(
        ECONOMY_ERRORS.UNKNOWN_EXPANSION,
        `Unknown expansion: ${expansionId}`,
        404,
      );
    }
    return expansion;
  }

  /** What a player may see: released expansions only. */
  async visibleExpansions(): Promise<ExpansionDefinition[]> {
    const all = await this.policies();
    return Object.values(all)
      .filter((expansion) => expansion.policy.released)
      .sort((a, b) => a.id.localeCompare(b.id));
  }

  /** Every expansion including unreleased ones. For admin and dev tools only. */
  async allExpansions(): Promise<ExpansionDefinition[]> {
    const all = await this.policies();
    return Object.values(all).sort((a, b) => a.id.localeCompare(b.id));
  }

  /**
   * Replaces an expansion's policy.
   *
   * Every flag must be supplied: a partial update would let an operator change
   * one flag while silently reasserting stale values for the rest, and
   * `released` is not a flag to reassert by accident.
   */
  async setPolicy(
    expansionId: string,
    policy: ExpansionPolicy,
    updatedBy?: string,
  ): Promise<ExpansionDefinition> {
    if (!EXPANSION_DEFINITIONS[expansionId]) {
      throw new EconomyError(
        ECONOMY_ERRORS.UNKNOWN_EXPANSION,
        `Unknown expansion: ${expansionId}`,
        404,
      );
    }
    const errors = validateExpansionPolicy(policy, expansionId);
    if (errors.length > 0) {
      throw new AccountError('INVALID_POLICY', errors.join('; '), 400);
    }
    const data = {
      released: policy.released,
      tradeable: policy.tradeable,
      duplicateProtection: policy.duplicateProtection,
      craftable: policy.craftable,
      disenchantable: policy.disenchantable,
      availableInPacks: policy.availableInPacks,
      standard: policy.standard,
      updatedBy: updatedBy ?? null,
    };
    await this.prisma.expansionPolicyOverride.upsert({
      where: { expansionId },
      create: { expansionId, ...data },
      update: data,
    });
    return await this.policy(expansionId);
  }

  /** Changes named flags, leaving the rest of the live policy as it stands. */
  async updateFlags(
    expansionId: string,
    changes: Partial<ExpansionPolicy>,
    updatedBy?: string,
  ): Promise<ExpansionDefinition> {
    const current = await this.policy(expansionId);
    const next: ExpansionPolicy = { ...current.policy };
    for (const flag of EXPANSION_POLICY_FLAGS) {
      const value = changes[flag];
      if (value === undefined) continue;
      if (typeof value !== 'boolean') {
        throw new AccountError('INVALID_POLICY', `${flag} must be a boolean`, 400);
      }
      next[flag] = value;
    }
    return await this.setPolicy(expansionId, next, updatedBy);
  }

  /** Drops the override, restoring the values shipped with the definitions. */
  async clearOverride(expansionId: string): Promise<ExpansionDefinition> {
    await this.prisma.expansionPolicyOverride.deleteMany({ where: { expansionId } });
    return await this.policy(expansionId);
  }
}

// Card-level questions. Each takes an already-loaded snapshot so that one
// operation asks about several cards without re-reading policy between them —
// a trade must judge every card it moves against the same instant.

export function expansionOf(policies: LivePolicies, cardId: string): ExpansionDefinition {
  const card = CARD_DEFINITIONS[cardId];
  if (!card) {
    throw new EconomyError(ECONOMY_ERRORS.UNKNOWN_CARD, `Unknown card: ${cardId}`, 404);
  }
  const expansion = policies[card.expansionId];
  if (!expansion) {
    throw new EconomyError(
      ECONOMY_ERRORS.UNKNOWN_EXPANSION,
      `Card ${cardId} belongs to unknown expansion ${card.expansionId}`,
      500,
    );
  }
  return expansion;
}

export function isCardVisible(policies: LivePolicies, cardId: string): boolean {
  const card = CARD_DEFINITIONS[cardId];
  if (!card) return false;
  const expansion = policies[card.expansionId];
  return Boolean(expansion?.policy.released);
}

/** The cards a player may be shown or handed: released expansions only. */
export function visibleCards(policies: LivePolicies): CardDefinition[] {
  return Object.values(CARD_DEFINITIONS).filter((card) => isCardVisible(policies, card.id));
}

/**
 * What a player's match may draw at random: the collectible cards of
 * released expansions. A random summon shows the card it brings, so drawing
 * from an unreleased set would leak it.
 */
export function matchRandomPool(policies: LivePolicies): string[] {
  return visibleCards(policies)
    .filter((card) => card.collectible)
    .map((card) => card.id)
    .sort();
}

export function isCardLegalIn(policies: LivePolicies, cardId: string, format: DeckFormat): boolean {
  const card = CARD_DEFINITIONS[cardId];
  if (!card) return false;
  const expansion = policies[card.expansionId];
  if (!expansion) return false;
  return format === 'STANDARD'
    ? isExpansionStandardLegal(expansion)
    : isExpansionWildLegal(expansion);
}

/** Throws unless the card may be crafted right now. */
export function assertCraftable(policies: LivePolicies, cardId: string): void {
  const expansion = expansionOf(policies, cardId);
  assertReleased(expansion, cardId);
  // A rule of the card, not of its expansion: no policy makes a Basic card
  // craftable, so it has its own code rather than borrowing the policy one —
  // "not available for this expansion right now" would be untrue.
  assertNotBasic(cardId, 'crafted');
  if (!canCraftExpansion(expansion)) {
    throw new EconomyError(
      ECONOMY_ERRORS.CARD_NOT_CRAFTABLE,
      `${expansion.name} cards cannot currently be crafted`,
    );
  }
  assertCollectible(cardId);
}

export function assertDisenchantable(policies: LivePolicies, cardId: string): void {
  const expansion = expansionOf(policies, cardId);
  assertReleased(expansion, cardId);
  assertNotBasic(cardId, 'disenchanted');
  if (!canDisenchantExpansion(expansion)) {
    throw new EconomyError(
      ECONOMY_ERRORS.CARD_NOT_DISENCHANTABLE,
      `${expansion.name} cards cannot currently be disenchanted`,
    );
  }
}

export function assertTradeable(policies: LivePolicies, cardId: string): void {
  const expansion = expansionOf(policies, cardId);
  assertReleased(expansion, cardId);
  // Everyone already has every Basic card, so trading one gives nobody
  // anything — and checked on execution as well as on offer, like the policy.
  assertNotBasic(cardId, 'traded');
  if (!canTradeExpansion(expansion)) {
    throw new EconomyError(
      ECONOMY_ERRORS.CARD_NOT_TRADEABLE,
      `${expansion.name} cards cannot currently be traded`,
    );
  }
}

export function assertPacksOpenable(expansion: ExpansionDefinition): void {
  if (!expansion.policy.released) {
    throw new EconomyError(
      ECONOMY_ERRORS.EXPANSION_NOT_RELEASED,
      `${expansion.name} is not available`,
      404,
    );
  }
  if (!canOpenExpansionPacks(expansion)) {
    throw new EconomyError(
      ECONOMY_ERRORS.EXPANSION_NOT_AVAILABLE_IN_PACKS,
      `${expansion.name} packs are not currently available`,
    );
  }
}

/**
 * Whether packs from this expansion should steer toward cards the player is
 * short of. Re-exported through this module so callers need one import for
 * every policy question.
 */
export function packsProtectDuplicates(expansion: ExpansionDefinition): boolean {
  return hasDuplicateProtection(expansion);
}

function assertReleased(expansion: ExpansionDefinition, cardId: string): void {
  if (expansion.policy.released) return;
  // Reported as "not found" so that an unreleased card's existence cannot be
  // probed through the error it produces.
  throw new EconomyError(ECONOMY_ERRORS.EXPANSION_NOT_RELEASED, `Unknown card: ${cardId}`, 404);
}

/** Basic cards are free to everyone, so the economy never prices them. */
function assertNotBasic(cardId: string, verb: string): void {
  const card = getCardDefinition(cardId);
  if (isBasicRarity(card.rarity)) {
    throw new EconomyError(
      ECONOMY_ERRORS.BASIC_CARD,
      `${card.name} is a Basic card and cannot be ${verb}`,
    );
  }
}

function assertCollectible(cardId: string): void {
  const card = getCardDefinition(cardId);
  if (!card.collectible) {
    throw new EconomyError(
      ECONOMY_ERRORS.CARD_NOT_COLLECTIBLE,
      `${card.name} is not a collectible card`,
    );
  }
}
