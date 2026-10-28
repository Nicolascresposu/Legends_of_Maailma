import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Ajv, type SchemaObject, type ValidateFunction } from 'ajv';
import type { CardDefinition, ExpansionDefinition } from '@maailma/game-model';
import { cardEffects, referencedTags } from '@maailma/game-model';
import { isKnownClass } from './classes.js';
import { validateCardDescription } from './descriptions.js';
import { validateLocationDefinition } from './locations.js';
import { validateTagRules } from './tags.js';
import type { PackDefinition } from './packs.js';
import {
  validateScenarios,
  validateStarterDecks,
  type ScenarioContent,
  type StarterDeckDefinition,
} from './starters.js';

export interface ContentCatalog {
  expansions: ExpansionDefinition[];
  cards: CardDefinition[];
  packs: PackDefinition[];
  starterDecks: StarterDeckDefinition[];
  scenarios: ScenarioContent[];
}

/**
 * Files an expansion folder may leave out; a missing one holds nothing.
 * Most expansions ship no starter decks or scenarios of their own.
 */
export const OPTIONAL_FILES = ['starterDecks', 'scenarios'] as const;

export interface ExpansionFile extends ExpansionDefinition {
  schemaVersion: 1;
}

function readJson(path: string): unknown {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    throw new Error(`${path}: ${error instanceof Error ? error.message : String(error)}`, {
      cause: error,
    });
  }
}

const schema = readJson(fileURLToPath(new URL('../content.schema.json', import.meta.url)));
const ajv = new Ajv({ allErrors: true, discriminator: true });
ajv.addSchema(schema as SchemaObject);
const schemaId = 'https://maailma.local/content.schema.json';
const expansionValidator = ajv.compile<ExpansionFile>({
  $ref: `${schemaId}#/definitions/expansion`,
});
const cardsValidator = ajv.compile<CardDefinition[]>({ $ref: `${schemaId}#/definitions/cards` });
const packsValidator = ajv.compile<PackDefinition[]>({ $ref: `${schemaId}#/definitions/packs` });
const starterDecksValidator = ajv.compile<StarterDeckDefinition[]>({
  $ref: `${schemaId}#/definitions/starterDecks`,
});
const scenariosValidator = ajv.compile<ScenarioContent[]>({
  $ref: `${schemaId}#/definitions/scenarios`,
});

export interface ExpansionDocument {
  expansion: ExpansionFile;
  cards: CardDefinition[];
  packs: PackDefinition[];
  starterDecks: StarterDeckDefinition[];
  scenarios: ScenarioContent[];
}

function validateValue<T>(data: unknown, path: string, validate: ValidateFunction<T>): T {
  if (!validate(data)) {
    const errors = validate.errors?.map((error) => {
      const detail =
        error.keyword === 'additionalProperties'
          ? ` (${String(error.params.additionalProperty)})`
          : '';
      return `${path}${error.instancePath}: ${error.message}${detail}`;
    });
    throw new Error(`Invalid content:\n${errors?.join('\n')}`);
  }
  return data;
}

/** The same boundary validates disk content and untrusted creator uploads. */
export function validateExpansionDocument(value: unknown, where = 'draft'): ExpansionDocument {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${where}: expected an expansion document`);
  }
  const data = value as Record<string, unknown>;
  return {
    expansion: validateValue(data.expansion, join(where, 'expansion.json'), expansionValidator),
    cards: validateValue(data.cards, join(where, 'cards.json'), cardsValidator),
    packs: validateValue(data.packs, join(where, 'packs.json'), packsValidator),
    // Optional, so a document from before they existed is still accepted.
    starterDecks: validateValue(
      data.starterDecks ?? [],
      join(where, 'starterDecks.json'),
      starterDecksValidator,
    ),
    scenarios: validateValue(
      data.scenarios ?? [],
      join(where, 'scenarios.json'),
      scenariosValidator,
    ),
  };
}

/** Load every expansion folder before exposing any registry to the engine. */
export function loadContent(
  root: string | URL = new URL('../content/', import.meta.url),
): ContentCatalog {
  const directory = root instanceof URL ? fileURLToPath(root) : resolve(root);
  const folders = readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.'))
    .map((entry) => entry.name)
    .sort();
  if (folders.length === 0) throw new Error(`${directory}: no expansion folders found`);
  return parseContentDocuments(
    folders.map((folder) => {
      const path = join(directory, folder);
      return {
        folder: path,
        data: {
          expansion: readJson(join(path, 'expansion.json')),
          cards: readJson(join(path, 'cards.json')),
          packs: readJson(join(path, 'packs.json')),
          ...Object.fromEntries(
            OPTIONAL_FILES.filter((key) => existsSync(join(path, `${key}.json`))).map((key) => [
              key,
              readJson(join(path, `${key}.json`)),
            ]),
          ),
        },
      };
    }),
  );
}

export function parseContentDocuments(
  documents: readonly { folder: string; data: unknown }[],
): ContentCatalog {
  const catalog: ContentCatalog = {
    expansions: [],
    cards: [],
    packs: [],
    starterDecks: [],
    scenarios: [],
  };
  const seen = {
    expansions: new Map<string, string>(),
    cards: new Map<string, string>(),
    packs: new Map<string, string>(),
    starterDecks: new Map<string, string>(),
    scenarios: new Map<string, string>(),
  };
  const locations = new Map<{ id: string }, string>();
  const errors: string[] = [];

  function register<T extends { id: string }>(
    items: T[],
    target: T[],
    ids: Map<string, string>,
    path: string,
  ): void {
    for (const item of items) {
      const previous = ids.get(item.id);
      if (previous) errors.push(`${path}: duplicate id "${item.id}" (already in ${previous})`);
      else ids.set(item.id, path);
      target.push(item);
    }
  }

  for (const document of documents) {
    const path = document.folder;
    const data = validateExpansionDocument(document.data, path);
    const expansionPath = join(path, 'expansion.json');
    const { id, name, policy } = data.expansion;
    const expansion: ExpansionDefinition = { id, name, policy };
    register([expansion], catalog.expansions, seen.expansions, expansionPath);
    const cardsPath = join(path, 'cards.json');
    const cards = data.cards;
    register(cards, catalog.cards, seen.cards, cardsPath);
    const packsPath = join(path, 'packs.json');
    const packs = data.packs;
    register(packs, catalog.packs, seen.packs, packsPath);
    const decksPath = join(path, 'starterDecks.json');
    register(data.starterDecks, catalog.starterDecks, seen.starterDecks, decksPath);
    const scenariosPath = join(path, 'scenarios.json');
    register(data.scenarios, catalog.scenarios, seen.scenarios, scenariosPath);
    for (const [items, itemPath] of [
      [cards, cardsPath],
      [packs, packsPath],
      [data.starterDecks, decksPath],
      [data.scenarios, scenariosPath],
    ] as const) {
      for (const item of items) {
        locations.set(item, itemPath);
        if (item.expansionId !== expansion.id) {
          errors.push(
            `${itemPath}: ${item.id}: expansionId must be "${expansion.id}", got "${item.expansionId}"`,
          );
        }
      }
    }
  }

  const byId = new Map(catalog.cards.map((card) => [card.id, card]));
  // Tags are free-form, so a rule naming one nothing carries is almost
  // certainly a typo, and would otherwise match nothing in silence.
  const carried = new Set(
    catalog.cards.flatMap((card) =>
      card.type === 'CREATURE' || card.type === 'WEAPON' ? card.tags : [],
    ),
  );
  for (const card of catalog.cards) {
    const path = locations.get(card)!;
    if (card.classId !== undefined && !isKnownClass(card.classId)) {
      errors.push(`${path}: ${card.id}: unknown class "${card.classId}"`);
    }
    errors.push(...validateCardDescription(card).map((error) => `${path}: ${error}`));
    if (card.type === 'LOCATION') {
      errors.push(...validateLocationDefinition(card).map((error) => `${path}: ${error}`));
    }
    errors.push(...validateTagRules(card).map((error) => `${path}: ${error}`));
    for (const tag of referencedTags(card)) {
      if (!carried.has(tag)) errors.push(`${path}: ${card.id}: no card carries tag "${tag}"`);
    }
    for (const effect of cardEffects(card)) {
      if (effect.type === 'SUMMON' && byId.get(effect.definitionId)?.type !== 'CREATURE') {
        errors.push(
          `${path}: ${card.id}: SUMMON must reference an existing Creature, got "${effect.definitionId}"`,
        );
      }
    }
  }
  for (const pack of catalog.packs) {
    const count = pack.rarityRules.slots.reduce((sum, slot) => sum + slot.count, 0);
    if (count !== pack.cardCount) {
      errors.push(
        `${locations.get(pack)}: ${pack.id}: slot rules cover ${count} cards but the pack holds ${pack.cardCount}`,
      );
    }
  }
  const locate = (item: { id: string }) => locations.get(item)!;
  errors.push(...validateStarterDecks(catalog.starterDecks, byId, locate));
  errors.push(...validateScenarios(catalog.scenarios, byId, locate));
  if (errors.length > 0) throw new Error(`Invalid content:\n${errors.join('\n')}`);
  return catalog;
}

/** Convert a validated catalogue to the creator's portable per-expansion documents. */
export function contentDocuments(catalog: ContentCatalog): ExpansionDocument[] {
  return catalog.expansions.map((expansion) => ({
    expansion: { schemaVersion: 1, ...expansion },
    cards: catalog.cards.filter((card) => card.expansionId === expansion.id),
    packs: catalog.packs.filter((pack) => pack.expansionId === expansion.id),
    starterDecks: catalog.starterDecks.filter((deck) => deck.expansionId === expansion.id),
    scenarios: catalog.scenarios.filter((scenario) => scenario.expansionId === expansion.id),
  }));
}

// Paths are relative to this module, so source, compiled code, CLI and Docker agree.
export const CONTENT = loadContent();
