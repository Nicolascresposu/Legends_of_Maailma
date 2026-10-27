import { randomUUID } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import {
  activateContent,
  captureCardContent,
  contentDocuments,
  contentVersion,
  currentContent,
  parseContentDocuments,
  validateExpansionDocument,
  STARTER_DECKS,
  HERO_DEFINITIONS,
  SCENARIO_DEFINITIONS,
  cardFitsClass,
  type ContentCatalog,
  type ExpansionDocument,
} from '@maailma/card-definitions';
import { AccountError } from './account-service.js';

export interface ContentActivation {
  id: string;
  version: string;
  previousVersion: string | null;
  action: 'baseline' | 'publish' | 'rollback';
  actorId: string | null;
  createdAt: string;
  expansionId: string | null;
}

interface PublishedState {
  schemaVersion: 1;
  activeVersion: string;
  history: ContentActivation[];
}

export interface ContentChange {
  kind: 'expansions' | 'cards' | 'packs';
  id: string;
  change: 'added' | 'changed' | 'removed';
  before: unknown;
  after: unknown;
}

/** One server process owns this store. Source JSON remains the authoring source. */
export class ContentPublishingService {
  private state: PublishedState;

  constructor(
    readonly directory: string,
    readonly enabled = true,
  ) {
    const version = captureCardContent().version;
    this.state = {
      schemaVersion: 1,
      activeVersion: version,
      history: [this.event('baseline', version, null, null, null)],
    };
    if (existsSync(join(directory, 'state.json'))) {
      const state = JSON.parse(
        readFileSync(join(directory, 'state.json'), 'utf8'),
      ) as PublishedState;
      if (state.schemaVersion !== 1 || !Array.isArray(state.history) || !state.history.length) {
        throw new Error('Invalid published content state');
      }
      const catalog = this.readVersion(state.activeVersion, false);
      activateContent(catalog);
      this.state = state;
    }
  }

  status() {
    return {
      enabled: this.enabled,
      currentVersion: captureCardContent().version,
      history: [...this.state.history].reverse(),
      expansions: currentContent().expansions.map((expansion) => ({
        id: expansion.id,
        name: expansion.name,
      })),
    };
  }

  expansion(id: string): ExpansionDocument {
    const document = contentDocuments(currentContent()).find((entry) => entry.expansion.id === id);
    if (!document) throw new AccountError('UNKNOWN_EXPANSION', `Unknown expansion: ${id}`, 404);
    return document;
  }

  preview(document: unknown) {
    this.requireEnabled();
    const parsed = this.parseDocument(document);
    const documents = contentDocuments(currentContent()).filter(
      (entry) => entry.expansion.id !== parsed.expansion.id,
    );
    documents.push(parsed);
    const catalog = this.parseDocuments(documents);
    return this.review(catalog);
  }

  previewRollback(version: string) {
    this.requireEnabled();
    if (version === captureCardContent().version) return this.review(currentContent());
    return this.review(this.readVersion(version));
  }

  publish(document: unknown, baseVersion: unknown, candidateVersion: unknown, actorId: string) {
    const parsed = this.parseDocument(document);
    const review = this.preview(parsed);
    this.checkReview(review, baseVersion, candidateVersion);
    return this.commit(review.catalog, 'publish', actorId, parsed.expansion.id);
  }

  rollback(version: string, baseVersion: unknown, candidateVersion: unknown, actorId: string) {
    const review = this.previewRollback(version);
    this.checkReview(review, baseVersion, candidateVersion);
    return this.commit(review.catalog, 'rollback', actorId, null);
  }

  private parseDocument(value: unknown): ExpansionDocument {
    try {
      return validateExpansionDocument(value);
    } catch (error) {
      throw new AccountError('INVALID_CONTENT', String((error as Error).message), 422);
    }
  }

  private parseDocuments(documents: ExpansionDocument[]): ContentCatalog {
    try {
      const catalog = parseContentDocuments(
        documents.map((data) => ({ folder: data.expansion.id, data })),
      );
      // Code-owned starters and scenarios must remain usable after a publication.
      const cards = new Map(catalog.cards.map((card) => [card.id, card]));
      const errors: string[] = [];
      for (const [classId, deck] of Object.entries(STARTER_DECKS)) {
        for (const id of deck) {
          const card = cards.get(id);
          if (!card || !card.collectible || !cardFitsClass(card, classId)) {
            errors.push(`${id}: required by the ${classId} starter deck`);
          }
          if (card?.rarity === 'LEGENDARY' && deck.filter((entry) => entry === id).length > 1) {
            errors.push(`${id}: Legendary copy limit would break the ${classId} starter deck`);
          }
        }
      }
      for (const scenario of Object.values(SCENARIO_DEFINITIONS)) {
        for (const side of [scenario.sideA, scenario.sideB]) {
          if (!HERO_DEFINITIONS[side.heroDefinitionId])
            errors.push(`Unknown scenario Hero ${side.heroDefinitionId}`);
          for (const creature of side.startingCreatures ?? []) {
            if (cards.get(creature.definitionId)?.type !== 'CREATURE')
              errors.push(`${creature.definitionId}: scenario requires a Creature`);
          }
          for (const location of side.startingLocations ?? []) {
            if (cards.get(location.definitionId)?.type !== 'LOCATION')
              errors.push(`${location.definitionId}: scenario requires a Location`);
          }
          for (const id of side.startingArtifacts ?? []) {
            if (cards.get(id)?.type !== 'ARTIFACT')
              errors.push(`${id}: scenario requires an Artifact`);
          }
          if (side.startingWeapon && cards.get(side.startingWeapon)?.type !== 'WEAPON')
            errors.push(`${side.startingWeapon}: scenario requires a Weapon`);
          for (const id of side.startingCards ?? [])
            if (!cards.has(id)) errors.push(`${id}: required by scenario`);
        }
      }
      if (errors.length) throw new Error([...new Set(errors)].join('\n'));
      return catalog;
    } catch (error) {
      throw new AccountError('INVALID_CONTENT', String((error as Error).message), 422);
    }
  }

  private review(catalog: ContentCatalog) {
    const before = currentContent();
    const changes: ContentChange[] = [];
    for (const kind of ['expansions', 'cards', 'packs'] as const) {
      const old = new Map<string, unknown>(before[kind].map((entry) => [entry.id, entry]));
      const next = new Map<string, unknown>(catalog[kind].map((entry) => [entry.id, entry]));
      for (const id of [...new Set([...old.keys(), ...next.keys()])].sort()) {
        const left = old.get(id);
        const right = next.get(id);
        if (canonical(left) === canonical(right)) continue;
        changes.push({
          kind,
          id,
          change: left === undefined ? 'added' : right === undefined ? 'removed' : 'changed',
          before: left ?? null,
          after: right ?? null,
        });
      }
    }
    return {
      baseVersion: captureCardContent().version,
      candidateVersion: contentVersion(catalog),
      changes,
      catalog,
    };
  }

  private checkReview(
    review: { baseVersion: string; candidateVersion: string },
    base: unknown,
    candidate: unknown,
  ): void {
    if (base !== review.baseVersion)
      throw new AccountError(
        'CONTENT_CONFLICT',
        'Server content changed. Preview again before publishing.',
        409,
      );
    if (candidate !== review.candidateVersion)
      throw new AccountError(
        'CONTENT_PREVIEW_CHANGED',
        'The proposed content differs from the preview. Preview again.',
        409,
      );
  }

  private commit(
    catalog: ContentCatalog,
    action: 'publish' | 'rollback',
    actorId: string,
    expansionId: string | null,
  ) {
    this.requireEnabled();
    const version = contentVersion(catalog);
    if (version === captureCardContent().version) return { ...this.status(), unchanged: true };
    this.writeVersion(currentContent());
    this.writeVersion(catalog);
    const event = this.event(action, version, captureCardContent().version, actorId, expansionId);
    const next: PublishedState = {
      schemaVersion: 1,
      activeVersion: version,
      history: [...this.state.history, event],
    };
    this.atomicWrite(join(this.directory, 'state.json'), next);
    activateContent(catalog);
    this.state = next;
    return { ...this.status(), unchanged: false };
  }

  private event(
    action: ContentActivation['action'],
    version: string,
    previousVersion: string | null,
    actorId: string | null,
    expansionId: string | null,
  ): ContentActivation {
    return {
      id: randomUUID(),
      version,
      previousVersion,
      action,
      actorId,
      expansionId,
      createdAt: new Date().toISOString(),
    };
  }

  private readVersion(version: string, requireHistory = true): ContentCatalog {
    if (
      !/^[a-f0-9]{64}$/.test(version) ||
      (requireHistory && !this.state.history.some((entry) => entry.version === version))
    ) {
      throw new AccountError('CONTENT_VERSION_NOT_FOUND', 'Unknown published content version', 404);
    }
    const path = join(this.directory, 'versions', `${version}.json`);
    if (!existsSync(path))
      throw new AccountError('CONTENT_VERSION_NOT_FOUND', 'Content snapshot is missing', 404);
    const file = JSON.parse(readFileSync(path, 'utf8')) as {
      schemaVersion: number;
      documents: ExpansionDocument[];
    };
    if (file.schemaVersion !== 1 || !Array.isArray(file.documents))
      throw new Error('Invalid content snapshot');
    const catalog = this.parseDocuments(file.documents);
    if (contentVersion(catalog) !== version)
      throw new Error('Content snapshot failed its integrity check');
    return catalog;
  }

  private writeVersion(catalog: ContentCatalog): void {
    const version = contentVersion(catalog);
    const path = join(this.directory, 'versions', `${version}.json`);
    if (existsSync(path)) {
      this.readVersion(version, false);
      return;
    }
    this.atomicWrite(path, { schemaVersion: 1, documents: contentDocuments(catalog) });
  }

  private atomicWrite(path: string, value: unknown): void {
    mkdirSync(join(this.directory, 'versions'), { recursive: true });
    const temporary = `${path}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporary, JSON.stringify(value, null, 2) + '\n', { flag: 'wx' });
      renameSync(temporary, path);
    } finally {
      if (existsSync(temporary)) unlinkSync(temporary);
    }
  }

  private requireEnabled(): void {
    if (!this.enabled)
      throw new AccountError(
        'CONTENT_PUBLISHING_DISABLED',
        'Content publishing is disabled on this server.',
        403,
      );
  }
}

function canonical(value: unknown): string | undefined {
  return JSON.stringify(value, (_key, child: unknown) =>
    child && typeof child === 'object' && !Array.isArray(child)
      ? Object.fromEntries(Object.entries(child).sort(([a], [b]) => a.localeCompare(b)))
      : child,
  );
}
