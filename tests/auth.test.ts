import { describe, expect, it } from 'vitest';
import {
  assertUsablePassword,
  hashPassword,
  needsRehash,
  verifyPassword,
} from '../apps/server/src/auth/passwords.js';
import {
  bearerToken,
  hashToken,
  issueToken,
  tokenHashesMatch,
} from '../apps/server/src/auth/tokens.js';

describe('password hashing', () => {
  it('verifies a correct password and rejects a wrong one', async () => {
    const stored = await hashPassword('correct horse battery');
    expect(await verifyPassword('correct horse battery', stored)).toBe(true);
    expect(await verifyPassword('Correct horse battery', stored)).toBe(false);
    expect(await verifyPassword('', stored)).toBe(false);
  });

  it('salts each hash, so equal passwords store differently', async () => {
    const a = await hashPassword('the same password');
    const b = await hashPassword('the same password');
    expect(a).not.toBe(b);
    expect(await verifyPassword('the same password', a)).toBe(true);
    expect(await verifyPassword('the same password', b)).toBe(true);
  });

  it('records its parameters in the stored string', async () => {
    const stored = await hashPassword('a password to store');
    const [scheme, n, r, p] = stored.split('$');
    expect(scheme).toBe('scrypt');
    expect(Number(n)).toBe(16384);
    expect(Number(r)).toBe(8);
    expect(Number(p)).toBe(1);
    expect(needsRehash(stored)).toBe(false);
  });

  it('treats a malformed hash as unusable instead of throwing', async () => {
    for (const bad of [
      '',
      'nonsense',
      'scrypt$1$1$1$$',
      'bcrypt$1$2$3$aa$bb',
      'scrypt$x$8$1$aa$bb',
    ]) {
      expect(await verifyPassword('whatever', bad)).toBe(false);
      expect(needsRehash(bad)).toBe(true);
    }
  });

  it('flags weaker stored parameters for rehashing', async () => {
    expect(needsRehash('scrypt$1024$8$1$YWJj$ZGVm')).toBe(true);
  });

  it('normalizes unicode so equivalent inputs match', async () => {
    // "é" composed vs decomposed.
    const stored = await hashPassword('passwérd-long');
    expect(await verifyPassword('passwérd-long', stored)).toBe(true);
  });

  it('rejects passwords that are too short or too long', () => {
    expect(() => assertUsablePassword('short')).toThrow();
    expect(() => assertUsablePassword('x'.repeat(201))).toThrow();
    expect(() => assertUsablePassword('just long enough')).not.toThrow();
  });
});

describe('session tokens', () => {
  it('issues a token whose hash is stored, not the token', () => {
    const issued = issueToken();
    expect(issued.token.length).toBeGreaterThan(30);
    expect(issued.tokenHash).toBe(hashToken(issued.token));
    expect(issued.tokenHash).not.toBe(issued.token);
    expect(issued.expiresAt.getTime()).toBeGreaterThan(Date.now());
  });

  it('issues distinct tokens', () => {
    const seen = new Set(Array.from({ length: 50 }, () => issueToken().token));
    expect(seen.size).toBe(50);
  });

  it('honours a custom expiry', () => {
    const now = new Date('2026-01-01T00:00:00.000Z');
    const issued = issueToken(now, 1000);
    expect(issued.expiresAt.toISOString()).toBe('2026-01-01T00:00:01.000Z');
  });

  it('compares hashes safely', () => {
    const a = hashToken('one');
    expect(tokenHashesMatch(a, hashToken('one'))).toBe(true);
    expect(tokenHashesMatch(a, hashToken('two'))).toBe(false);
    expect(tokenHashesMatch(a, 'short')).toBe(false);
  });

  it('parses only well-formed bearer headers', () => {
    expect(bearerToken('Bearer abc123')).toBe('abc123');
    expect(bearerToken('bearer abc123')).toBe('abc123');
    expect(bearerToken('  Bearer   abc123  ')).toBe('abc123');
    expect(bearerToken('Basic abc123')).toBeUndefined();
    expect(bearerToken('Bearer')).toBeUndefined();
    expect(bearerToken('Bearer a b')).toBeUndefined();
    expect(bearerToken(undefined)).toBeUndefined();
  });
});
