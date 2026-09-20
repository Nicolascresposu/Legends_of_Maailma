import { afterEach, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { STARTER_DECK } from '@maailma/card-definitions';
import { createApp } from '../apps/server/src/app.js';
import { MatchManager } from '../apps/server/src/match-manager.js';

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
          { playerId: 'a', deck: STARTER_DECK },
          { playerId: 'b', deck: STARTER_DECK },
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
