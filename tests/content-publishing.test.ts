import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer, type Server } from 'node:http';
import express from 'express';
import {
  activateContent,
  captureCardContent,
  contentDocuments,
  currentContent,
  contentVersion,
  getCardDefinition,
  getExpansionDefinition,
  getPackDefinition,
  getScenarioDefinition,
  starterDeckFor,
  STARTER_COLLECTION,
} from '@maailma/card-definitions';
import { createReplay, replayMatch, stableStateJson } from '@maailma/game-engine';
import { ContentPublishingService } from '../apps/server/src/services/content-publishing-service.js';
import { createContentRouter } from '../apps/server/src/routes/content-routes.js';
import { silentLogger } from '../apps/server/src/logger.js';
import { MatchManager } from '../apps/server/src/match-manager.js';
import { createApp } from '../apps/server/src/app.js';
import { makeEngine } from './helpers.js';

const original = currentContent();
let directory: string;
let service: ContentPublishingService;
let server: Server | undefined;

beforeEach(() => {
  activateContent(original);
  directory = mkdtempSync(join(tmpdir(), 'maailma-publishing-'));
  service = new ContentPublishingService(directory);
});

afterEach(async () => {
  if (server)
    await new Promise<void>((resolve, reject) =>
      server!.close((error) => (error ? reject(error) : resolve())),
    );
  server = undefined;
  activateContent(original);
  if (!directory.startsWith(join(tmpdir(), 'maailma-publishing-')))
    throw new Error('Unexpected cleanup path');
  rmSync(directory, { recursive: true, force: true });
});

function document() {
  return structuredClone(
    contentDocuments(original).find((entry) => entry.expansion.id === 'CORE')!,
  );
}

function publish(name = 'Published Wolf') {
  const draft = document();
  draft.cards.find((card) => card.id === 'chicken')!.name = name;
  const review = service.preview(draft);
  return service.publish(draft, review.baseVersion, review.candidateVersion, 'admin');
}

describe('server content publishing', () => {
  it('previews an exact change without changing definitions or writing history', () => {
    const draft = document();
    draft.cards[0]!.name = 'Snow Wolf';
    const review = service.preview(draft);
    expect(review.changes).toHaveLength(1);
    expect(review.changes[0]).toMatchObject({
      kind: 'cards',
      id: 'chicken',
      change: 'changed',
      before: { name: 'Chicken' },
      after: { name: 'Snow Wolf' },
    });
    expect(getCardDefinition('chicken').name).toBe('Chicken');
    expect(service.status().history).toHaveLength(1);
  });

  it('publishes cards, expansion defaults and packs through the existing live exports', () => {
    const draft = document();
    draft.cards[0]!.name = 'Snow Wolf';
    draft.expansion.name = 'Edited Core';
    draft.packs[0]!.name = 'Edited Pack';
    const review = service.preview(draft);
    service.publish(draft, review.baseVersion, review.candidateVersion, 'admin');
    expect(getCardDefinition('chicken').name).toBe('Snow Wolf');
    expect(getExpansionDefinition('CORE').name).toBe('Edited Core');
    expect(getPackDefinition('CORE_PACK').name).toBe('Edited Pack');
    expect(service.status().history[0]).toMatchObject({
      action: 'publish',
      actorId: 'admin',
      expansionId: 'CORE',
    });
  });

  it('persists publication and restores it after a restart', () => {
    const result = publish();
    activateContent(original);
    const restarted = new ContentPublishingService(directory);
    expect(restarted.status().currentVersion).toBe(result.currentVersion);
    expect(getCardDefinition('chicken').name).toBe('Published Wolf');
    expect(restarted.status().history).toHaveLength(2);
  });

  it('rolls back to a reviewed version and records a new activation', () => {
    const baseline = captureCardContent().version;
    publish();
    const review = service.previewRollback(baseline);
    service.rollback(baseline, review.baseVersion, review.candidateVersion, 'another-admin');
    expect(getCardDefinition('chicken').name).toBe('Chicken');
    expect(service.status().history).toHaveLength(3);
    expect(service.status().history[0]).toMatchObject({
      action: 'rollback',
      version: baseline,
      actorId: 'another-admin',
    });
    expect(new ContentPublishingService(directory).status().currentVersion).toBe(baseline);
  });

  it('rejects stale or altered previews', () => {
    const draft = document();
    draft.cards[0]!.name = 'First preview';
    const review = service.preview(draft);
    draft.cards[0]!.name = 'Changed since preview';
    expect(() =>
      service.publish(draft, review.baseVersion, review.candidateVersion, 'admin'),
    ).toThrow(/differs from the preview/);
    publish('Another publication');
    expect(() =>
      service.publish(draft, review.baseVersion, review.candidateVersion, 'admin'),
    ).toThrow(/Server content changed/);
  });

  it('does not create a publication for unchanged content', () => {
    const review = service.preview(document());
    const result = service.publish(
      document(),
      review.baseVersion,
      review.candidateVersion,
      'admin',
    );
    expect(result.unchanged).toBe(true);
    expect(result.history).toHaveLength(1);
  });

  it('rejects malformed cards, cross-expansion collisions and broken summons', () => {
    const malformed = document() as any;
    malformed.cards[0].cost = 'two';
    expect(() => service.preview(malformed)).toThrow(/cost/);
    const duplicate = document();
    duplicate.cards[0]!.id = 'lio_varga';
    expect(() => service.preview(duplicate)).toThrow(/duplicate id/);
    const broken = document();
    const creature = broken.cards.find((card) => card.type === 'CREATURE')!;
    creature.effects = [
      { trigger: 'ARRIVAL', effect: { type: 'SUMMON', definitionId: 'missing' } },
    ];
    expect(() => service.preview(broken)).toThrow(/SUMMON/);
    expect(getCardDefinition('chicken').name).toBe('Chicken');
  });

  it('keeps starter decks and scenarios pointing at cards that exist', () => {
    const removed = document();
    removed.cards = removed.cards.filter((card) => card.id !== 'chicken');
    expect(() => service.preview(removed)).toThrow(/PRIEST_STARTER: unknown card "chicken"/);
    const changed = document();
    changed.cards.find((card) => card.id === 'chicken')!.rarity = 'LEGENDARY';
    expect(() => service.preview(changed)).toThrow(/chicken is Legendary/);
    const scenario = document();
    scenario.cards = scenario.cards.filter((card) => card.id !== 'rusty_dagger');
    expect(() => service.preview(scenario)).toThrow(
      /BANDIT_AMBUSH\.sideB: unknown card "rusty_dagger"/,
    );
    const misplaced = document();
    misplaced.scenarios[1]!.sideB.startingWeapon = 'chicken';
    expect(() => service.preview(misplaced)).toThrow(/chicken must be a Weapon/);
  });

  it('publishes starter decks and scenarios with the rest of the expansion', () => {
    const draft = document();
    draft.starterDecks
      .find((deck) => deck.classId === 'PRIEST')!
      .cards.push({
        cardId: 'war_axe',
        copies: 1,
      });
    draft.scenarios.find((scenario) => scenario.id === 'BANDIT_AMBUSH')!.sideB.heroHealth = 25;
    const review = service.preview(draft);
    expect(review.changes.map((change) => `${change.kind}:${change.id}`)).toEqual([
      'starterDecks:PRIEST_STARTER',
      'scenarios:BANDIT_AMBUSH',
    ]);
    service.publish(draft, review.baseVersion, review.candidateVersion, 'admin');
    expect(starterDeckFor('healer').filter((id) => id === 'war_axe')).toHaveLength(1);
    expect(STARTER_COLLECTION.get('war_axe')).toBe(1);
    expect(getScenarioDefinition('BANDIT_AMBUSH').sideB.heroHealth).toBe(25);
    expect(getScenarioDefinition('BANDIT_AMBUSH')).not.toHaveProperty('expansionId');
  });

  it('adds a new expansion without changing code', () => {
    const draft = document();
    draft.expansion.id = 'NEW_SET';
    draft.expansion.name = 'New set';
    draft.cards = [{ ...draft.cards[0]!, id: 'new_wolf', expansionId: 'NEW_SET' }];
    draft.packs = [{ ...draft.packs[0]!, id: 'NEW_PACK', expansionId: 'NEW_SET' }];
    // Core keeps the starter decks and scenarios; a set may ship none.
    draft.starterDecks = [];
    draft.scenarios = [];
    const review = service.preview(draft);
    service.publish(draft, review.baseVersion, review.candidateVersion, 'admin');
    expect(getCardDefinition('new_wolf').expansionId).toBe('NEW_SET');
    expect(getPackDefinition('NEW_PACK').expansionId).toBe('NEW_SET');
  });

  it('leaves active content intact if persistence fails', () => {
    const blocked = join(directory, 'blocked');
    writeFileSync(blocked, 'not a directory');
    const failing = new ContentPublishingService(blocked);
    const draft = document();
    draft.cards[0]!.name = 'Cannot persist';
    const review = failing.preview(draft);
    expect(() =>
      failing.publish(draft, review.baseVersion, review.candidateVersion, 'admin'),
    ).toThrow();
    expect(getCardDefinition('chicken').name).toBe('Chicken');
  });

  it('detects snapshot corruption instead of silently starting with different content', () => {
    const result = publish();
    const path = join(directory, 'versions', result.currentVersion + '.json');
    const snapshot = JSON.parse(readFileSync(path, 'utf8'));
    snapshot.documents[0].expansion.name = 'Tampered';
    writeFileSync(path, JSON.stringify(snapshot));
    expect(() => new ContentPublishingService(directory)).toThrow(/integrity/);
  });

  it('rejects unsafe and unknown rollback identifiers', () => {
    expect(() => service.previewRollback('../state')).toThrow(/Unknown published/);
    expect(() => service.previewRollback('a'.repeat(64))).toThrow(/Unknown published/);
  });

  it('can disable publishing while retaining a previously published version', () => {
    publish();
    const disabled = new ContentPublishingService(directory, false);
    expect(disabled.status().enabled).toBe(false);
    expect(getCardDefinition('chicken').name).toBe('Published Wolf');
    expect(() => disabled.preview(document())).toThrow(/disabled/);
  });

  it('does not rewrite source JSON files', () => {
    const path = new URL('../packages/card-definitions/content/core/cards.json', import.meta.url);
    const before = readFileSync(path, 'utf8');
    publish();
    expect(readFileSync(path, 'utf8')).toBe(before);
  });

  it('keeps catalogue version identity independent of object and top-level entry ordering', () => {
    const next = structuredClone(original);
    next.cards.reverse();
    next.cards[0] = Object.fromEntries(
      Object.entries(next.cards[0]!).reverse(),
    ) as (typeof next.cards)[number];
    expect(contentVersion(next)).toBe(contentVersion(original));
  });
});

describe('pinned matches and replays', () => {
  it('keeps an old match and its replay unchanged while new matches use the published stats', () => {
    const old = makeEngine({ deckA: ['chicken'] });
    const oldVersion = old.content.version;
    const draft = document();
    const wolf = draft.cards.find((card) => card.id === 'chicken')!;
    wolf.cost = 9;
    if (wolf.type === 'CREATURE') wolf.attack = 99;
    const review = service.preview(draft);
    service.publish(draft, review.baseVersion, review.candidateVersion, 'admin');
    const next = makeEngine({ deckA: ['chicken'] });
    const play = (engine: typeof old) =>
      engine.dispatch({
        type: 'PLAY_CARD',
        actorId: 'a',
        cardInstanceId: engine.state.sides.a!.hand[0]!.instanceId,
        position: { row: 'FRONT', column: 0 },
      });
    expect(play(old).ok).toBe(true);
    expect(play(next).ok).toBe(true);
    expect(Object.values(old.state.sides.a!.creatures)[0]!.currentAttack).toBe(2);
    expect(Object.values(next.state.sides.a!.creatures)[0]!.currentAttack).toBe(99);
    expect(old.content.version).toBe(oldVersion);
    const replay = createReplay(old.setup, old.state.actionLog);
    expect(replay.setup.content!.cards).not.toHaveProperty('kona_scrapwalker');
    expect(stableStateJson(replayMatch(JSON.parse(JSON.stringify(replay))))).toBe(
      stableStateJson(old),
    );
    expect(old.presentationCards().find((card) => card.id === 'chicken')!.cost).toBe(1);
  });

  it('preserves the original version when an open seat is claimed after publishing', () => {
    const manager = new MatchManager();
    const waiting = manager.createWithOpenSeat({
      scenarioId: 'STANDARD_PVP',
      creator: { playerId: 'a' },
    });
    publish();
    const joined = manager.claimSeat(waiting.state.matchId, { playerId: 'b' });
    expect(joined.content.version).toBe(waiting.content.version);
    expect(joined.getCardDefinition('chicken').name).toBe('Chicken');
    expect(
      manager
        .create({ scenarioId: 'STANDARD_PVP', players: [{ playerId: 'c' }, { playerId: 'd' }] })
        .getCardDefinition('chicken').name,
    ).toBe('Published Wolf');
  });

  it('exports pinned replay data through HTTP', async () => {
    const manager = new MatchManager();
    const engine = manager.create({
      scenarioId: 'STANDARD_PVP',
      players: [{ playerId: 'a', deck: starterDeckFor('healer') }, { playerId: 'b' }],
    });
    publish();
    const base = await listen(createApp(manager));
    const response = await fetch(`${base}/api/matches/${engine.state.matchId}/replay`);
    expect(response.status).toBe(200);
    const replay = await response.json();
    expect(replay.setup.content.cards.chicken.name).toBe('Chicken');
    expect(replay.setup.content.cards).not.toHaveProperty('kona_scrapwalker');
  });
});

async function listen(app: ReturnType<typeof express>): Promise<string> {
  server = createServer(app);
  await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Missing port');
  return `http://127.0.0.1:${address.port}`;
}

describe('publishing HTTP authorization and review', () => {
  it('requires an admin and a current preview before activating content', async () => {
    const app = express();
    app.use(express.json());
    app.use((request, _response, next) => {
      const token = request.headers.authorization;
      if (token)
        request.user = {
          id: token,
          email: 'test@example.test',
          displayName: 'Test',
          isAdmin: token === 'admin',
        };
      next();
    });
    app.use('/api/admin/content', createContentRouter(service, silentLogger));
    const base = await listen(app);
    expect((await fetch(`${base}/api/admin/content`)).status).toBe(401);
    expect(
      (await fetch(`${base}/api/admin/content`, { headers: { authorization: 'player' } })).status,
    ).toBe(404);
    const draft = document();
    draft.cards[0]!.name = 'From HTTP';
    const call = (path: string, body: unknown) =>
      fetch(`${base}/api/admin/content/${path}`, {
        method: 'POST',
        headers: { authorization: 'admin', 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
    const preview = await call('preview', { document: draft });
    expect(preview.status).toBe(200);
    const review = await preview.json();
    expect(review).not.toHaveProperty('catalog');
    expect(getCardDefinition('chicken').name).toBe('Chicken');
    expect((await call('publish', { document: draft })).status).toBe(409);
    expect(
      (
        await call('publish', {
          document: draft,
          baseVersion: review.baseVersion,
          candidateVersion: review.candidateVersion,
        })
      ).status,
    ).toBe(200);
    expect(getCardDefinition('chicken').name).toBe('From HTTP');
  });
});
