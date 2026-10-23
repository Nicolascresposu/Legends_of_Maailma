import { createHash } from 'node:crypto';
import type { CardDefinition, CardContentSnapshot, ExpansionDefinition } from '@maailma/game-model';
import { CONTENT, type ContentCatalog } from './content.js';
import type { PackDefinition } from './packs.js';

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

function index<T extends { id: string }>(entries: readonly T[]): Readonly<Record<string, T>> {
  return Object.freeze(Object.fromEntries(entries.map((entry) => [entry.id, entry])));
}

/** Install an already validated catalogue synchronously; existing snapshots survive. */
export function activateContent(catalog: ContentCatalog): string {
  const next = freezeContent(structuredClone(catalog));
  const nextVersion = contentVersion(next);
  const cards = index(next.cards);
  const expansions = index(next.expansions);
  const packs = index(next.packs);
  active = next;
  version = nextVersion;
  CARD_DEFINITIONS = cards;
  EXPANSION_DEFINITIONS = expansions;
  PACK_DEFINITIONS = packs;
  return version;
}

export function currentContent(): ContentCatalog {
  return structuredClone(active);
}

export function captureCardContent(): CardContentSnapshot {
  return { version, cards: CARD_DEFINITIONS };
}
