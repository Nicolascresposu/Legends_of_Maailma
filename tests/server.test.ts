import { afterEach, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { starterDeckFor } from '@maailma/card-definitions';
import { createApp } from '../apps/server/src/app.js';
import { MatchManager } from '../apps/server/src/match-manager.js';
import { createLogger, type LogRecord } from '../apps/server/src/logger.js';

let server: Server | undefined;

afterEach(async () => {
  if (server)
    await new Promise<void>((resolve, reject) =>
      server!.close((error) => (error ? reject(error) : resolve())),
    );
  server = undefined;
});

describe('authoritative HTTP server', () => {
  it('creates a match, returns state, legal actions, and applies an intention', async () => {
    const manager = new MatchManager();
    server = createServer(createApp(manager));
    await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Missing test port');
    const base = `http://127.0.0.1:${address.port}`;

    const created = await fetch(`${base}/api/matches`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        scenarioId: 'STANDARD_PVP',
        seed: 99,
        players: [
          { playerId: 'a', deck: starterDeckFor('healer') },
          { playerId: 'b', deck: starterDeckFor('striker') },
        ],
      }),
    });
    expect(created.status).toBe(201);
    const payload = (await created.json()) as { matchId: string };

    const legal = await fetch(`${base}/api/matches/${payload.matchId}/legal-actions/a`);
    const legalPayload = (await legal.json()) as { actions: Array<{ type: string }> };
    expect(legalPayload.actions.some((action) => action.type === 'END_TURN')).toBe(true);

    const actionResponse = await fetch(`${base}/api/matches/${payload.matchId}/actions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'END_TURN', actorId: 'a' }),
    });
    expect(actionResponse.status).toBe(200);
    const actionPayload = (await actionResponse.json()) as { state: { activePlayerId: string } };
    expect(actionPayload.state.activePlayerId).toBe('b');
  });
});

describe('request logging', () => {
  it('logs completed and rejected requests with a shared request id', async () => {
    const records: LogRecord[] = [];
    const logger = createLogger({ level: 'debug', sink: (_line, record) => records.push(record) });
    const manager = new MatchManager();
    server = createServer(createApp(manager, logger));
    await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Missing test port');
    const base = `http://127.0.0.1:${address.port}`;

    const health = await fetch(`${base}/health`);
    expect(health.headers.get('x-request-id')).toBeTruthy();

    const completed = records.find((record) => record.message === 'Request completed');
    expect(completed?.fields).toMatchObject({ method: 'GET', path: '/health', status: 200 });
    expect(completed?.fields.durationMs).toBeTypeOf('number');

    const missing = await fetch(`${base}/api/matches/does-not-exist`);
    expect(missing.status).toBe(404);
    expect(records.some((record) => record.message === 'Request rejected')).toBe(true);

    const bad = await fetch(`${base}/api/matches`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ scenarioId: 'NOPE', players: [] }),
    });
    expect(bad.status).toBe(400);
    const rejected = records.find((record) => record.message === 'Match creation rejected');
    expect(rejected?.level).toBe('warn');
    expect(rejected?.fields.requestId).toBeTypeOf('string');
  });
});
