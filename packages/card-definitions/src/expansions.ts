import type {
  ExpansionDefinition,
  ExpansionPolicy,
  ExpansionPolicyFlag,
} from '@maailma/game-model';
import { EXPANSION_POLICY_FLAGS } from '@maailma/game-model';
import { CONTENT } from './content.js';
import { EXPANSION_DEFINITIONS } from './registry.js';
export { EXPANSION_DEFINITIONS } from './registry.js';

/** Shipped JSON policies are defaults; stored server overrides take precedence. */
const expansions = CONTENT.expansions;

/**
 * Rejects a malformed policy at load.
 *
 * Every flag must be stated outright. An absent flag would otherwise default
 * to something, and the something a missing `released` defaults to decides
 * whether unfinished content is public — too consequential to leave implicit.
 */
export function validateExpansionPolicy(policy: unknown, where = '(policy)'): string[] {
  const errors: string[] = [];
  if (typeof policy !== 'object' || policy === null) {
    return [`${where}: policy must be an object`];
  }
  const record = policy as Record<string, unknown>;
  for (const flag of EXPANSION_POLICY_FLAGS) {
    if (typeof record[flag] !== 'boolean') {
      errors.push(`${where}: ${flag} must be stated as a boolean`);
    }
  }
  return errors;
}

export function validateExpansionDefinition(definition: ExpansionDefinition): string[] {
  const where = definition?.id || '(unnamed expansion)';
  const errors: string[] = [];
  if (typeof definition?.id !== 'string' || definition.id.trim() === '') {
    errors.push('(unnamed expansion): id must be a non-empty string');
  }
  if (typeof definition?.name !== 'string' || definition.name.trim() === '') {
    errors.push(`${where}: name must be a non-empty string`);
  }
  errors.push(...validateExpansionPolicy(definition?.policy, where));
  return errors;
}

// A malformed registry is a programming error, so it fails at import rather
// than the first time somebody tries to open a pack.
const definitionErrors = expansions.flatMap(validateExpansionDefinition);
if (definitionErrors.length > 0) {
  throw new Error(`Invalid expansion definitions: ${definitionErrors.join('; ')}`);
}

export function getExpansionDefinition(id: string): ExpansionDefinition {
  const definition = EXPANSION_DEFINITIONS[id];
  if (!definition) throw new Error(`Unknown expansion definition: ${id}`);
  return definition;
}

/** Whether an id names an expansion at all, without throwing to find out. */
export function isKnownExpansion(id: string): boolean {
  return Object.hasOwn(EXPANSION_DEFINITIONS, id);
}

/** A copy of the shipped defaults, for a caller that means to modify one. */
export function defaultPolicy(expansionId: string): ExpansionPolicy {
  return { ...getExpansionDefinition(expansionId).policy };
}

/**
 * Something with a policy. Every helper below takes this shape rather than an
 * `ExpansionDefinition`, so a policy loaded from the database and one read
 * from this file are interchangeable at every call site.
 */
export interface PolicyBearer {
  policy: ExpansionPolicy;
}

// The policy questions the rest of the server asks. They exist so that
// `released &&` is written once per question instead of at every call site,
// where one forgotten conjunct would quietly publish unreleased content.

/** The public gate. Everything else is subject to it. */
export function isExpansionReleased(expansion: PolicyBearer): boolean {
  return expansion.policy.released;
}

export function canTradeExpansion(expansion: PolicyBearer): boolean {
  return expansion.policy.released && expansion.policy.tradeable;
}

export function canCraftExpansion(expansion: PolicyBearer): boolean {
  return expansion.policy.released && expansion.policy.craftable;
}

export function canDisenchantExpansion(expansion: PolicyBearer): boolean {
  return expansion.policy.released && expansion.policy.disenchantable;
}

export function canOpenExpansionPacks(expansion: PolicyBearer): boolean {
  return expansion.policy.released && expansion.policy.availableInPacks;
}

/**
 * Whether packs from this expansion steer away from cards the player already
 * has a playset of. Gated on `released` like the rest, so an unreleased
 * expansion never reports a live economy behaviour.
 */
export function hasDuplicateProtection(expansion: PolicyBearer): boolean {
  return expansion.policy.released && expansion.policy.duplicateProtection;
}

export function isExpansionStandardLegal(expansion: PolicyBearer): boolean {
  return expansion.policy.released && expansion.policy.standard;
}

/** Wild asks only that the expansion be public. */
export function isExpansionWildLegal(expansion: PolicyBearer): boolean {
  return expansion.policy.released;
}

/** The flag names, for an admin surface that edits them generically. */
export const POLICY_FLAGS: readonly ExpansionPolicyFlag[] = EXPANSION_POLICY_FLAGS;
