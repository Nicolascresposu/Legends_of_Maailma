import {
  CARD_DEFINITIONS,
  type PackDefinition,
  type RarityWeights,
} from '@maailma/card-definitions';
import type { CardDefinition, Rarity } from '@maailma/game-model';
import type { SeededRng } from '@maailma/rng';
import { deckCopyLimit } from './deck.js';

/** How many copies of each card the player currently owns. */
export type OwnedCounts = ReadonlyMap<string, number>;

export interface PackGenerationOptions {
  /**
   * Whether to steer toward cards the player is still short of.
   *
   * Passed in rather than read from the pack's expansion, because whether
   * protection is live is a policy question the server answers; the generator
   * only needs the answer.
   */
  duplicateProtection?: boolean;
  /** Current ownership, and nothing else. See the note below. */
  owned?: OwnedCounts;
  /** The pool to draw from. Defaults to every card in the pack's expansion. */
  pool?: readonly CardDefinition[];
}

export interface PackSlotResult {
  rarity: Rarity;
  cardId: string;
  /** True when this card came from the duplicate-protected sub-pool. */
  protectedPick: boolean;
}

export interface PackResult {
  packId: string;
  expansionId: string;
  cards: PackSlotResult[];
}

/**
 * The cards a pack may contain.
 *
 * `standard` is deliberately not consulted: a Wild-only expansion may go on
 * being sold, and tying pack contents to format legality would quietly retire
 * sets the moment they rotated.
 */
export function packPool(
  pack: PackDefinition,
  cards: readonly CardDefinition[] = Object.values(CARD_DEFINITIONS),
): CardDefinition[] {
  return cards.filter((card) => card.collectible && card.expansionId === pack.expansionId);
}

/**
 * Generates one pack.
 *
 * Rarity is chosen first and card second, and the two never mix: duplicate
 * protection changes *which* card fills a Rare slot, never how often a Rare
 * slot occurs. Implementing protection by nudging rarity weights would make a
 * player with a full collection open measurably worse packs, which is not what
 * protection is for.
 *
 * Every draw comes from the seeded RNG, so a pack is reproducible from its
 * seed — the same property the match engine relies on, and what makes an
 * opened pack auditable after the fact.
 */
export function generatePack(
  pack: PackDefinition,
  rng: SeededRng,
  options: PackGenerationOptions = {},
): PackResult {
  const pool = options.pool ?? packPool(pack);
  const byRarity = new Map<Rarity, CardDefinition[]>();
  for (const card of pool) {
    const bucket = byRarity.get(card.rarity) ?? [];
    bucket.push(card);
    byRarity.set(card.rarity, bucket);
  }
  // Sorted so that generation depends only on the seed, never on the order the
  // registry happened to enumerate its cards.
  for (const bucket of byRarity.values()) bucket.sort((a, b) => a.id.localeCompare(b.id));

  if (pool.length === 0) {
    throw new Error(`Pack ${pack.id} has no eligible cards`);
  }

  const cards: PackSlotResult[] = [];
  for (const slot of pack.rarityRules.slots) {
    for (let index = 0; index < slot.count; index += 1) {
      const rarity = pickRarity(slot.weights, byRarity, rng);
      const rarityPool = byRarity.get(rarity)!;
      const picked = pickCard(rarityPool, rng, options);
      cards.push({ rarity, cardId: picked.card.id, protectedPick: picked.protectedPick });
    }
  }
  return { packId: pack.id, expansionId: pack.expansionId, cards };
}

/**
 * Chooses a rarity by weight, skipping rarities the pool cannot supply.
 *
 * A set with no Legendary yet should not produce an empty slot, so an
 * unrepresented rarity is dropped from the draw rather than selected and then
 * failed.
 */
function pickRarity(
  weights: RarityWeights,
  byRarity: ReadonlyMap<Rarity, CardDefinition[]>,
  rng: SeededRng,
): Rarity {
  const available = (Object.entries(weights) as Array<[Rarity, number]>)
    .filter(([rarity]) => (byRarity.get(rarity)?.length ?? 0) > 0)
    .sort(([a], [b]) => a.localeCompare(b));
  if (available.length === 0) {
    // Nothing the slot asked for exists in this set; fall back to whatever does.
    const present = [...byRarity.keys()].sort();
    const fallback = present[rng.int(present.length)];
    if (!fallback) throw new Error('Pack pool is empty');
    return fallback;
  }
  const total = available.reduce((sum, [, weight]) => sum + weight, 0);
  // One draw, scaled: `next()` is the engine's only entropy source, so packs
  // stay reproducible alongside matches.
  let roll = rng.next() * total;
  for (const [rarity, weight] of available) {
    roll -= weight;
    if (roll < 0) return rarity;
  }
  return available[available.length - 1]![0];
}

/**
 * Chooses a card within a rarity, preferring what the player still needs.
 *
 * "Needs" means only what they hold right now. Nothing here consults what a
 * player has ever owned, opened or seen — a card traded away or disenchanted
 * becomes eligible again, and one crafted stops being. That players can steer
 * their own odds this way is the intended shape of the collection game, not a
 * hole in it.
 */
function pickCard(
  rarityPool: readonly CardDefinition[],
  rng: SeededRng,
  options: PackGenerationOptions,
): { card: CardDefinition; protectedPick: boolean } {
  if (!options.duplicateProtection) {
    return { card: rng.pick(rarityPool), protectedPick: false };
  }
  const owned = options.owned ?? new Map<string, number>();
  const incomplete = rarityPool.filter(
    (card) => (owned.get(card.id) ?? 0) < deckCopyLimit(card.rarity),
  );
  // With a complete set at this rarity there is nothing left to protect, so
  // the pack goes on producing duplicates rather than producing nothing.
  if (incomplete.length === 0) {
    return { card: rng.pick(rarityPool), protectedPick: false };
  }
  return { card: rng.pick(incomplete), protectedPick: true };
}
