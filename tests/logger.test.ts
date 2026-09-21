import { describe, expect, it } from 'vitest';
import {
  createLogger,
  createLoggerFromEnv,
  errorFields,
  isLogLevel,
  silentLogger,
  type LogRecord,
} from '../apps/server/src/logger.js';

function collector() {
  const lines: string[] = [];
  const records: LogRecord[] = [];
  return {
    lines,
    records,
    sink: (line: string, record: LogRecord) => {
      lines.push(line);
      records.push(record);
    },
  };
}

const now = () => new Date('2026-09-20T12:00:00.000Z');

describe('logger', () => {
  it('writes one JSON object per line with merged fields', () => {
    const { lines, sink } = collector();
    const logger = createLogger({ level: 'debug', sink, now });

    logger.info('Match created', { matchId: 'm-1' });

    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0]!)).toEqual({
      time: '2026-09-20T12:00:00.000Z',
      level: 'info',
      message: 'Match created',
      matchId: 'm-1',
    });
  });

  it('suppresses records below the configured level', () => {
    const { records, sink } = collector();
    const logger = createLogger({ level: 'warn', sink, now });

    logger.debug('a');
    logger.info('b');
    logger.warn('c');
    logger.error('d');

    expect(records.map((record) => record.level)).toEqual(['warn', 'error']);
  });

  it('silences everything at the silent level', () => {
    const { records, sink } = collector();
    const logger = createLogger({ level: 'silent', sink, now });

    logger.error('boom');

    expect(records).toHaveLength(0);
    expect(() => silentLogger.error('boom')).not.toThrow();
  });

  it('merges child fields and lets the call site override them', () => {
    const { records, sink } = collector();
    const logger = createLogger({ level: 'debug', sink, now, base: { service: 'maailma' } });

    logger.child({ matchId: 'm-1' }).child({ playerId: 'a' }).info('joined', { playerId: 'b' });

    expect(records[0]!.fields).toEqual({
      service: 'maailma',
      matchId: 'm-1',
      playerId: 'b',
    });
  });

  it('formats pretty lines as text with key=value detail', () => {
    const { lines, sink } = collector();
    const logger = createLogger({ level: 'debug', format: 'pretty', sink, now });

    logger.warn('Action rejected', { code: 'NOT_YOUR_TURN', events: 2 });

    expect(lines[0]).toBe(
      '2026-09-20T12:00:00.000Z WARN  Action rejected code=NOT_YOUR_TURN events=2',
    );
  });

  it('survives circular and bigint fields instead of throwing', () => {
    const { lines, sink } = collector();
    const logger = createLogger({ level: 'debug', sink, now });
    const cyclic: Record<string, unknown> = { name: 'loop' };
    cyclic.self = cyclic;

    expect(() => logger.info('cycle', { cyclic, big: 10n })).not.toThrow();
    const parsed = JSON.parse(lines[0]!) as { cyclic: { self: string }; big: string };
    expect(parsed.cyclic.self).toBe('[Circular]');
    expect(parsed.big).toBe('10');
  });

  it('flattens Errors and non-Errors into log fields', () => {
    const fields = errorFields(new Error('illegal action')) as {
      error: { name: string; message: string; stack?: string };
    };
    expect(fields.error.name).toBe('Error');
    expect(fields.error.message).toBe('illegal action');
    expect(fields.error.stack).toBeTypeOf('string');

    expect(errorFields('plain string')).toEqual({
      error: { name: 'NonError', message: 'plain string' },
    });
  });

  it('recognizes valid levels', () => {
    expect(isLogLevel('debug')).toBe(true);
    expect(isLogLevel('verbose')).toBe(false);
    expect(isLogLevel(3)).toBe(false);
  });

  it('reads the level from the environment and warns on an unknown value', () => {
    const debugLogger = createLoggerFromEnv({ LOG_LEVEL: 'debug', LOG_FORMAT: 'json' });
    expect(debugLogger).toBeDefined();

    const written: string[] = [];
    const original = process.stdout.write.bind(process.stdout);
    process.stdout.write = ((chunk: string) => {
      written.push(String(chunk));
      return true;
    }) as typeof process.stdout.write;
    try {
      createLoggerFromEnv({ LOG_LEVEL: 'chatty', LOG_FORMAT: 'json' });
    } finally {
      process.stdout.write = original;
    }

    const parsed = JSON.parse(written[0]!) as { message: string; value: string; using: string };
    expect(parsed.message).toBe('Ignoring unknown LOG_LEVEL');
    expect(parsed.value).toBe('chatty');
    expect(parsed.using).toBe('info');
  });
});
