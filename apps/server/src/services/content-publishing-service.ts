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
  kind: (typeof CHANGE_KINDS)[number];
  id: string;
  change: 'added' | 'changed' | 'removed';
  before: unknown;
  after: unknown;
}

/** Every kind of definition a review compares, in the order it lists them. */
const CHANGE_KINDS = ['expansions', 'cards', 'packs', 'starterDecks', 'scenarios'] as const;

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
      // Starter decks and scenarios are content too, so the catalogue's own
      // checks keep them pointing at cards that still exist.
      const catalog = parseContentDocuments(
        documents.map((data) => ({ folder: data.expansion.id, data })),
      );
      return catalog;
    } catch (error) {
      throw new AccountError('INVALID_CONTENT', String((error as Error).message), 422);
    }
  }

  private review(catalog: ContentCatalog) {
    const before = currentContent();
    const changes: ContentChange[] = [];
    for (const kind of CHANGE_KINDS) {
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
