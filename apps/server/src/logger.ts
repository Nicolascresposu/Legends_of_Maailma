/**
 * Logging boundary. The v0.1 server writes structured JSON to stdout; a hosted
 * log shipper can replace the sink without changing call sites.
 */
export const LOG_LEVELS = ['debug', 'info', 'warn', 'error', 'silent'] as const;

export type LogLevel = (typeof LOG_LEVELS)[number];

/** Structured detail attached to a log line. Must stay JSON-compatible. */
export type LogFields = Record<string, unknown>;

export interface Logger {
  debug(message: string, fields?: LogFields): void;
  info(message: string, fields?: LogFields): void;
  warn(message: string, fields?: LogFields): void;
  error(message: string, fields?: LogFields): void;
  /** Returns a logger that merges `fields` into every line it writes. */
  child(fields: LogFields): Logger;
}

export interface LogRecord {
  time: string;
  level: Exclude<LogLevel, 'silent'>;
  message: string;
  fields: LogFields;
}

export interface LoggerOptions {
  level?: LogLevel;
  /** `json` for one object per line, `pretty` for a readable dev line. */
  format?: 'json' | 'pretty';
  /** Receives every formatted line. Defaults to stdout. */
  sink?: (line: string, record: LogRecord) => void;
  /** Merged into every line; `child` extends it. */
  base?: LogFields;
  now?: () => Date;
}

const LEVEL_RANK: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
  silent: 100,
};

const PRETTY_LABEL: Record<Exclude<LogLevel, 'silent'>, string> = {
  debug: 'DEBUG',
  info: 'INFO ',
  warn: 'WARN ',
  error: 'ERROR',
};

export function isLogLevel(value: unknown): value is LogLevel {
  return typeof value === 'string' && (LOG_LEVELS as readonly string[]).includes(value);
}

export function createLogger(options: LoggerOptions = {}): Logger {
  const level = options.level ?? 'info';
  const format = options.format ?? 'json';
  const now = options.now ?? (() => new Date());
  const base = options.base ?? {};
  const sink = options.sink ?? ((line) => process.stdout.write(`${line}\n`));
  const threshold = LEVEL_RANK[level];

  function write(recordLevel: Exclude<LogLevel, 'silent'>, message: string, fields?: LogFields) {
    if (LEVEL_RANK[recordLevel] < threshold) return;
    const record: LogRecord = {
      time: now().toISOString(),
      level: recordLevel,
      message,
      fields: { ...base, ...fields },
    };
    sink(format === 'pretty' ? formatPretty(record) : formatJson(record), record);
  }

  return {
    debug: (message, fields) => write('debug', message, fields),
    info: (message, fields) => write('info', message, fields),
    warn: (message, fields) => write('warn', message, fields),
    error: (message, fields) => write('error', message, fields),
    child: (fields) => createLogger({ ...options, base: { ...base, ...fields } }),
  };
}

/** Reads `LOG_LEVEL` and `LOG_FORMAT`, defaulting to pretty output on a TTY. */
export function createLoggerFromEnv(env: NodeJS.ProcessEnv = process.env): Logger {
  const rawLevel = env.LOG_LEVEL?.toLowerCase();
  const level: LogLevel = isLogLevel(rawLevel) ? rawLevel : 'info';
  const rawFormat = env.LOG_FORMAT?.toLowerCase();
  const format =
    rawFormat === 'pretty' || rawFormat === 'json'
      ? rawFormat
      : process.stdout.isTTY
        ? 'pretty'
        : 'json';
  const logger = createLogger({ level, format });
  if (rawLevel !== undefined && !isLogLevel(rawLevel))
    logger.warn('Ignoring unknown LOG_LEVEL', { value: rawLevel, using: level });
  return logger;
}

/** A logger that discards everything, for tests and embedded use. */
export const silentLogger: Logger = createLogger({ level: 'silent' });

/** Flattens an unknown throwable into JSON-compatible log fields. */
export function errorFields(error: unknown): LogFields {
  if (error instanceof Error) {
    return {
      error: {
        name: error.name,
        message: error.message,
        ...(error.stack ? { stack: error.stack } : {}),
      },
    };
  }
  return { error: { name: 'NonError', message: String(error) } };
}

function formatJson(record: LogRecord): string {
  return safeStringify({
    time: record.time,
    level: record.level,
    message: record.message,
    ...record.fields,
  });
}

function formatPretty(record: LogRecord): string {
  const head = `${record.time} ${PRETTY_LABEL[record.level]} ${record.message}`;
  const entries = Object.entries(record.fields);
  if (entries.length === 0) return head;
  const detail = entries
    .map(([key, value]) => `${key}=${typeof value === 'string' ? value : safeStringify(value)}`)
    .join(' ');
  return `${head} ${detail}`;
}

/** Serializes defensively: a log line must never throw or leak a cycle. */
function safeStringify(value: unknown): string {
  const seen = new WeakSet<object>();
  try {
    return (
      JSON.stringify(value, (_key, candidate: unknown) => {
        if (typeof candidate === 'bigint') return candidate.toString();
        if (typeof candidate === 'object' && candidate !== null) {
          if (seen.has(candidate)) return '[Circular]';
          seen.add(candidate);
        }
        return candidate;
      }) ?? String(value)
    );
  } catch {
    return String(value);
  }
}
