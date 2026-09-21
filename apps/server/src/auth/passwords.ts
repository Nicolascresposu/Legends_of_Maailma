import { randomBytes, scrypt, timingSafeEqual, type ScryptOptions } from 'node:crypto';

/**
 * `promisify` resolves to scrypt's three-argument overload, which drops the
 * cost parameters, so the options-taking form is wrapped explicitly.
 */
function scryptAsync(
  password: string,
  salt: Buffer,
  keyLength: number,
  options: ScryptOptions,
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, keyLength, options, (error, derived) => {
      if (error) reject(error);
      else resolve(derived);
    });
  });
}

/**
 * Password hashing built on Node's scrypt, so the server gains no native
 * dependency. The stored format is self-describing:
 *
 *   scrypt$N$r$p$<salt base64>$<hash base64>
 *
 * Keeping the parameters in the string means the cost can be raised later
 * without invalidating existing hashes.
 */
const CURRENT = { N: 16384, r: 8, p: 1, keyLength: 64 } as const;
const SALT_BYTES = 16;

export async function hashPassword(password: string): Promise<string> {
  assertUsablePassword(password);
  const salt = randomBytes(SALT_BYTES);
  const derived = await scryptAsync(password.normalize('NFKC'), salt, CURRENT.keyLength, {
    N: CURRENT.N,
    r: CURRENT.r,
    p: CURRENT.p,
  });
  return [
    'scrypt',
    CURRENT.N,
    CURRENT.r,
    CURRENT.p,
    salt.toString('base64'),
    derived.toString('base64'),
  ].join('$');
}

/**
 * Verifies a password against a stored hash. Returns false rather than
 * throwing on a malformed hash, so one corrupt row cannot break sign-in for
 * everyone, and compares in constant time.
 */
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parsed = parseHash(stored);
  if (!parsed) return false;
  const derived = await scryptAsync(password.normalize('NFKC'), parsed.salt, parsed.hash.length, {
    N: parsed.N,
    r: parsed.r,
    p: parsed.p,
  });
  return derived.length === parsed.hash.length && timingSafeEqual(derived, parsed.hash);
}

/** True when a stored hash was made with parameters weaker than current. */
export function needsRehash(stored: string): boolean {
  const parsed = parseHash(stored);
  if (!parsed) return true;
  return parsed.N < CURRENT.N || parsed.r < CURRENT.r || parsed.p < CURRENT.p;
}

export const PASSWORD_MIN_LENGTH = 10;
export const PASSWORD_MAX_LENGTH = 200;

/**
 * Rejects passwords that cannot be stored safely. The maximum matters: scrypt
 * runs over the whole input, so an unbounded password is a denial-of-service
 * vector.
 */
export function assertUsablePassword(password: string): void {
  if (typeof password !== 'string' || password.length < PASSWORD_MIN_LENGTH) {
    throw new Error(`Password must be at least ${PASSWORD_MIN_LENGTH} characters`);
  }
  if (password.length > PASSWORD_MAX_LENGTH) {
    throw new Error(`Password must be at most ${PASSWORD_MAX_LENGTH} characters`);
  }
}

interface ParsedHash {
  N: number;
  r: number;
  p: number;
  salt: Buffer;
  hash: Buffer;
}

function parseHash(stored: string): ParsedHash | undefined {
  if (typeof stored !== 'string') return undefined;
  const parts = stored.split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') return undefined;
  const N = Number(parts[1]);
  const r = Number(parts[2]);
  const p = Number(parts[3]);
  if (!Number.isInteger(N) || !Number.isInteger(r) || !Number.isInteger(p)) return undefined;
  if (N <= 1 || r <= 0 || p <= 0) return undefined;
  try {
    const salt = Buffer.from(parts[4]!, 'base64');
    const hash = Buffer.from(parts[5]!, 'base64');
    if (salt.length === 0 || hash.length === 0) return undefined;
    return { N, r, p, salt, hash };
  } catch {
    return undefined;
  }
}
