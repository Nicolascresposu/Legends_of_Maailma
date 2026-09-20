import { readFile } from 'node:fs/promises';
import type { ReplayData } from '@maailma/game-model';
import { replayMatch } from './replay.js';

const filename = process.argv[2];
if (!filename) {
  console.error('Usage: npm run replay -- path/to/replay.json');
  process.exitCode = 1;
} else {
  const replay = JSON.parse(await readFile(filename, 'utf8')) as ReplayData;
  const engine = replayMatch(replay);
  console.log(JSON.stringify(engine.state, null, 2));
}
