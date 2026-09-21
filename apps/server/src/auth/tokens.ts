import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

/**
 * Opaque session tokens.
 *
 * The raw token is handed to the client once and never stored; the database
 * keeps only its SHA-256 digest. A leaked database therefore yields no usable
 * sessions, and revoking one is a single row update.
 *
 * SHA-256 is right here where it would be wrong for passwords: a token is 256
 * bits of entropy from a CSPRNG, so there is nothing to brute force.
 */
const TOKEN_BYTES = 32;

export const SESSION_TTL_MS = 1000 * 60 * 60 * 24 * 14;

export interface IssuedToken {
  /** Returned to the client exactly once. */
  token: string;
  /** Stored server-side. */
  tokenHash: string;
  expiresAt: Date;
}

export function issueToken(now: Date = new Date(), ttlMs: number = SESSION_TTL_MS): IssuedToken {
  const token = randomBytes(TOKEN_BYTES).toString('base64url');
  return {
    token,
    tokenHash: hashToken(token),
    expiresAt: new Date(now.getTime() + ttlMs),
  };
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

/** Constant-time comparison of two token digests. */
export function tokenHashesMatch(a: string, b: string): boolean {
  const left = Buffer.from(a, 'utf8');
  const right = Buffer.from(b, 'utf8');
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

/**
 * Extracts a bearer token from an Authorization header.
 * Returns undefined for anything that is not exactly one bearer credential.
 */
export function bearerToken(header: string | undefined): string | undefined {
  if (!header) return undefined;
  const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
  return match?.[1];
}
