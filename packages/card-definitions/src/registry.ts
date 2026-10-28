import { createHash } from 'node:crypto';
import type {
  CardDefinition,
  CardContentSnapshot,
  ExpansionDefinition,
  ScenarioDefinition,
} from '@maailma/game-model';
import { CONTENT, type ContentCatalog } from './content.js';
import type { PackDefinition } from './packs.js';
import { scenarioDefinition, starterDeckCards } from './starters.js';

export function freezeContent<T>(value: T): T {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) freezeContent(child);
    Object.freeze(value);
  }
  return value;
}

const compare = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** Object property and catalogue entry order do not change a version's identity. */
export function contentVersion(catalog: ContentCatalog): string {
  const canonical = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(canonical);
    if (value && typeof value === 'object') {
      return Object.fromEntries(
        Object.entries(value)
          .sort(([a], [b]) => compare(a, b))
          .map(([key, child]) => [key, canonical(child)]),
      );
    }
    return value;
  };
  const ordered = Object.fromEntries(
    Object.entries(catalog).map(([key, entries]) => [
      key,
      [...entries].sort((a, b) => compare(a.id, b.id)),
    ]),
  );
  return createHash('sha256')
    .update(JSON.stringify(canonical(ordered)))
    .digest('hex');
}

let active = freezeContent(structuredClone(CONTENT));
let version = contentVersion(active);
export let CARD_DEFINITIONS: Readonly<Record<string, CardDefinition>> = index(active.cards);
export let EXPANSION_DEFINITIONS: Readonly<Record<string, ExpansionDefinition>> = index(
  active.expansions,
);
export let PACK_DEFINITIONS: Readonly<Record<string, PackDefinition>> = index(active.packs);
/** Each class's starter deck, keyed by class id, as the card ids a deck is saved with. */
export let STARTER_DECKS: Readonly<Record<string, readonly string[]>> = starterDecks(active);
/**
 * Every card a new account is given: enough copies to build any class's
 * starter deck, so each is playable from the first login.
 */
export let STARTER_COLLECTION: ReadonlyMap<string, number> = starterCollection(STARTER_DECKS);
export let SCENARIO_DEFINITIONS: Readonly<Record<string, ScenarioDefinition>> = scenarios(active);

function index<T extends { id: string }>(entries: readonly T[]): Readonly<Record<string, T>> {
  return Object.freeze(Object.fromEntries(entries.map((entry) => [entry.id, entry])));
}

function starterDecks(catalog: ContentCatalog): Readonly<Record<string, readonly string[]>> {
  return Object.freeze(
    Object.fromEntries(
      catalog.starterDecks.map((deck) => [deck.classId, Object.freeze(starterDeckCards(deck))]),
    ),
  );
}

function starterCollection(
  decks: Readonly<Record<string, readonly string[]>>,
): ReadonlyMap<string, number> {
  const counts = new Map<string, number>();
  for (const deck of Object.values(decks)) {
    const inDeck = new Map<string, number>();
    for (const cardId of deck) inDeck.set(cardId, (inDeck.get(cardId) ?? 0) + 1);
    for (const [cardId, copies] of inDeck) {
      counts.set(cardId, Math.max(counts.get(cardId) ?? 0, copies));
    }
  }
  return counts;
}

function scenarios(catalog: ContentCatalog): Readonly<Record<string, ScenarioDefinition>> {
  return freezeContent(
    Object.fromEntries(
      catalog.scenarios.map((scenario) => [scenario.id, scenarioDefinition(scenario)]),
    ),
  );
}

/** Install an already validated catalogue synchronously; existing snapshots survive. */
export function activateContent(catalog: ContentCatalog): string {
  const next = freezeContent(structuredClone(catalog));
  const nextVersion = contentVersion(next);
  const cards = index(next.cards);
  const expansions = index(next.expansions);
  const packs = index(next.packs);
  const decks = starterDecks(next);
  active = next;
  version = nextVersion;
  CARD_DEFINITIONS = cards;
  EXPANSION_DEFINITIONS = expansions;
  PACK_DEFINITIONS = packs;
  STARTER_DECKS = decks;
  STARTER_COLLECTION = starterCollection(decks);
  SCENARIO_DEFINITIONS = scenarios(next);
  return version;
}

export function currentContent(): ContentCatalog {
  return structuredClone(active);
}

export function captureCardContent(): CardContentSnapshot {
  return { version, cards: CARD_DEFINITIONS };
}
