import { it, expect } from 'vitest';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { PrismaClient } from '@prisma/client';
import { WebSocket } from 'ws';

/** Exercises the real entry point, auth, HTTP upload limit and match sockets. */
it('publishes from the creator API and immediately tests new cards while old matches stay pinned', async () => {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, '127.0.0.1', resolve));
  const address = probe.address();
  if (!address || typeof address === 'string') throw new Error('Missing port');
  const port = address.port;
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  const directory = mkdtempSync(join(tmpdir(), 'maailma-live-content-'));
  if (!directory.startsWith(join(tmpdir(), 'maailma-live-content-'))) {
    throw new Error('Unexpected cleanup path');
  }
  const prisma = new PrismaClient();
  const child = spawn(process.execPath, ['--import', 'tsx', 'apps/server/src/index.ts'], {
    cwd: process.cwd(),
    windowsHide: true,
    env: {
      ...process.env,
      PORT: String(port),
      CONTENT_STORE_DIR: directory,
      CONTENT_PUBLISHING: 'true',
      LOG_LEVEL: 'error',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const exited = once(child, 'exit');
  let logs = '';
  child.stdout.on('data', (chunk: Buffer) => {
    logs += chunk.toString();
  });
  child.stderr.on('data', (chunk: Buffer) => {
    logs += chunk.toString();
  });
  const base = `http://127.0.0.1:${port}`;
  let userId = '';
  let token = '';
  const sockets: WebSocket[] = [];
  try {
    let ready = false;
    for (let attempt = 0; attempt < 150; attempt++) {
      if (child.exitCode !== null) throw new Error(`Server exited: ${logs}`);
      try {
        ready = (await fetch(`${base}/health`)).ok;
      } catch {
        /* Still starting. */
      }
      if (ready) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    expect(ready, logs).toBe(true);
    const registration = await fetch(`${base}/api/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        email: `publish-live-${port}-${Date.now()}@example.test`,
        displayName: `Publisher_${port}`,
        password: 'a-sufficiently-long-password',
      }),
    });
    expect(registration.status).toBe(201);
    const account = await registration.json();
    userId = account.user.id;
    token = account.token;
    const request = (path: string, body?: unknown) =>
      fetch(base + path, {
        method: body === undefined ? 'GET' : 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
    expect((await request('/api/admin/content')).status).toBe(404);
    await prisma.user.update({ where: { id: userId }, data: { isAdmin: true } });
    const status = await (await request('/api/admin/content')).json();
    expect(status.enabled).toBe(true);
    const baseline = status.currentVersion;
    const draft = (await (await request('/api/admin/content/expansions/CORE')).json()).document;
    const createMatch = async () => {
      const response = await request('/api/matches', {
        scenarioId: 'STANDARD_PVP',
        players: [{ playerId: 'a' }, { playerId: 'b' }],
      });
      expect(response.status).toBe(201);
      return response.json();
    };
    const old = await createMatch();
    draft.cards.find((card: { id: string }) => card.id === 'chicken').name =
      'Live Development Wolf';
    draft.cards.push({
      ...structuredClone(draft.cards[0]),
      id: 'live_dev_card',
      name: 'New Development Card',
    });
    const reviewResponse = await request('/api/admin/content/preview', { document: draft });
    expect(reviewResponse.status).toBe(200);
    const review = await reviewResponse.json();
    expect(
      (await (await request('/api/cards')).json()).find(
        (card: { id: string }) => card.id === 'chicken',
      ).name,
    ).toBe('Chicken');
    const publishedResponse = await request('/api/admin/content/publish', {
      document: draft,
      baseVersion: review.baseVersion,
      candidateVersion: review.candidateVersion,
    });
    expect(publishedResponse.status).toBe(200);
    const published = await publishedResponse.json();
    expect(published.history[0].actorId).toBe(userId);
    expect(
      (await (await request('/api/cards')).json()).find(
        (card: { id: string }) => card.id === 'chicken',
      ).name,
    ).toBe('Live Development Wolf');

    async function joinMatch(matchId: string, playerId: string) {
      const socket = new WebSocket(base.replace('http:', 'ws:') + '/matches');
      sockets.push(socket);
      const messages: any[] = [];
      socket.on('message', (raw) => messages.push(JSON.parse(raw.toString())));
      await once(socket, 'open');
      socket.send(JSON.stringify({ type: 'JOIN_MATCH', matchId, playerId }));
      await until(() => messages.some((message) => message.type === 'MATCH_CONTENT'));
      return { socket, messages };
    }
    const oldSocket = await joinMatch(old.matchId, 'a');
    const pinned = oldSocket.messages.find((message) => message.type === 'MATCH_CONTENT');
    expect(pinned.version).toBe(baseline);
    expect(pinned.cards.find((card: { id: string }) => card.id === 'chicken').name).toBe('Chicken');
    expect(pinned.cards.some((card: { id: string }) => card.id === 'kona_scrapwalker')).toBe(false);

    const debugResponse = await request('/api/admin/matches', {
      userId,
      heroId: 'healer',
      scenarioId: 'BANDIT_AMBUSH',
    });
    expect(debugResponse.status).toBe(201);
    const debug = (await debugResponse.json()).match;
    const devSocket = await joinMatch(debug.matchId, userId);
    const add = await request(`/api/admin/matches/${debug.matchId}/hand`, {
      playerId: userId,
      cardId: 'live_dev_card',
    });
    expect(add.status).toBe(200);
    await until(() =>
      devSocket.messages.some(
        (message) =>
          message.type === 'MATCH_CONTENT' &&
          message.cards.some((card: { id: string }) => card.id === 'live_dev_card'),
      ),
    );
    expect(
      devSocket.messages.filter((message) => message.type === 'MATCH_CONTENT').at(-1).version,
    ).toBe(published.currentVersion);
    expect((await request(`/api/matches/${debug.matchId}/replay`)).status).toBe(409);

    const big = structuredClone(draft);
    for (let index = 0; index < 90; index++)
      big.cards.push({
        ...structuredClone(big.cards[0]),
        id: `large_preview_${index}`,
        flavour: 'Snow '.repeat(200),
      });
    expect(JSON.stringify(big).length).toBeGreaterThan(64 * 1024);
    expect((await request('/api/admin/content/preview', { document: big })).status).toBe(200);

    const rollback = await (
      await request(`/api/admin/content/versions/${baseline}/preview`)
    ).json();
    const rolledBack = await request('/api/admin/content/rollback', {
      version: baseline,
      baseVersion: rollback.baseVersion,
      candidateVersion: rollback.candidateVersion,
    });
    expect(rolledBack.status).toBe(200);
    expect(
      (await (await request('/api/cards')).json()).find(
        (card: { id: string }) => card.id === 'chicken',
      ).name,
    ).toBe('Chicken');
    const afterRollback = await joinMatch(debug.matchId, userId);
    expect(afterRollback.messages.find((message) => message.type === 'MATCH_CONTENT').version).toBe(
      published.currentVersion,
    );
    const replay = await (await request(`/api/matches/${old.matchId}/replay`)).json();
    expect(replay.setup.content.cards.chicken.name).toBe('Chicken');
    expect(replay.setup.content.cards).not.toHaveProperty('kona_scrapwalker');
  } finally {
    for (const socket of sockets) socket.terminate();
    child.kill();
    await exited;
    if (userId) await prisma.user.deleteMany({ where: { id: userId } });
    await prisma.$disconnect();
    rmSync(directory, { recursive: true, force: true });
  }
}, 30000);

async function until(condition: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error('Timed out waiting for match socket content');
}
