import type { PrismaClient, User } from '@prisma/client';
import { hashPassword, needsRehash, verifyPassword } from '../auth/passwords.js';
import { hashToken, issueToken, SESSION_TTL_MS } from '../auth/tokens.js';

export class AccountError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status = 400,
  ) {
    super(message);
    this.name = 'AccountError';
  }
}

export interface AuthenticatedUser {
  id: string;
  email: string;
  displayName: string;
  /** Whether this account may change expansion policies. */
  isAdmin: boolean;
}

export interface SignedInSession {
  user: AuthenticatedUser;
  token: string;
  expiresAt: Date;
}

const DISPLAY_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 _-]{1,23}$/;
/** Deliberately permissive: the address is only used to sign in. */
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export class AccountService {
  constructor(private readonly prisma: PrismaClient) {}

  async register(input: {
    email: string;
    displayName: string;
    password: string;
  }): Promise<SignedInSession> {
    const email = normalizeEmail(input.email);
    const displayName = String(input.displayName ?? '').trim();
    if (!EMAIL_PATTERN.test(email)) throw new AccountError('INVALID_EMAIL', 'Enter a valid email');
    if (!DISPLAY_NAME_PATTERN.test(displayName)) {
      throw new AccountError(
        'INVALID_DISPLAY_NAME',
        'Display name must be 2-24 characters: letters, digits, spaces, hyphens or underscores',
      );
    }
    let passwordHash: string;
    try {
      passwordHash = await hashPassword(input.password);
    } catch (error) {
      throw new AccountError('WEAK_PASSWORD', errorMessage(error));
    }

    try {
      const user = await this.prisma.user.create({
        data: { email, displayName, passwordHash },
      });
      return await this.startSession(user);
    } catch (error) {
      // Unique violation: the address or name is taken. Reported the same way
      // for both, so registration does not confirm which emails exist.
      if (isUniqueViolation(error)) {
        throw new AccountError(
          'ACCOUNT_EXISTS',
          'That email or display name is already taken',
          409,
        );
      }
      throw error;
    }
  }

  async login(input: { email: string; password: string }): Promise<SignedInSession> {
    const email = normalizeEmail(input.email);
    const user = await this.prisma.user.findUnique({ where: { email } });
    // Hash even when the user is absent, so a missing account and a wrong
    // password take comparable time.
    const storedHash = user?.passwordHash ?? PLACEHOLDER_HASH;
    const ok = await verifyPassword(String(input.password ?? ''), storedHash);
    if (!user || !ok) {
      throw new AccountError('INVALID_CREDENTIALS', 'Email or password is incorrect', 401);
    }
    if (needsRehash(user.passwordHash)) {
      const upgraded = await hashPassword(input.password);
      await this.prisma.user.update({ where: { id: user.id }, data: { passwordHash: upgraded } });
    }
    return await this.startSession(user);
  }

  /** Resolves a bearer token to its user, or undefined when not usable. */
  async authenticate(token: string | undefined): Promise<AuthenticatedUser | undefined> {
    if (!token) return undefined;
    const session = await this.prisma.session.findUnique({
      where: { tokenHash: hashToken(token) },
      include: { user: true },
    });
    if (!session || session.revokedAt) return undefined;
    if (session.expiresAt.getTime() <= Date.now()) return undefined;
    // Touch sparingly: a write on every request would double the cost of
    // authenticating a busy client.
    if (Date.now() - session.lastSeenAt.getTime() > 60_000) {
      await this.prisma.session.update({
        where: { id: session.id },
        data: { lastSeenAt: new Date() },
      });
    }
    return publicUser(session.user);
  }

  async logout(token: string | undefined): Promise<void> {
    if (!token) return;
    await this.prisma.session.updateMany({
      where: { tokenHash: hashToken(token), revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }

  /** Removes expired and revoked sessions. Safe to call on a schedule. */
  async pruneSessions(now: Date = new Date()): Promise<number> {
    const result = await this.prisma.session.deleteMany({
      where: { OR: [{ expiresAt: { lte: now } }, { revokedAt: { not: null } }] },
    });
    return result.count;
  }

  /**
   * A session for a user, issued without their password.
   *
   * For administrator tooling only — signing in as a player to see what they
   * see. It is an ordinary session in every other respect: it expires on the
   * usual schedule and `revokeSessions` ends it.
   */
  async issueSessionFor(userId: string): Promise<SignedInSession> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw new AccountError('USER_NOT_FOUND', 'No such player', 404);
    return await this.startSession(user);
  }

  /** Ends every live session a user has, signing them out everywhere. */
  async revokeSessions(userId: string): Promise<number> {
    const result = await this.prisma.session.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    return result.count;
  }

  private async startSession(user: User): Promise<SignedInSession> {
    const issued = issueToken(new Date(), SESSION_TTL_MS);
    await this.prisma.session.create({
      data: { tokenHash: issued.tokenHash, userId: user.id, expiresAt: issued.expiresAt },
    });
    return { user: publicUser(user), token: issued.token, expiresAt: issued.expiresAt };
  }
}

/**
 * A structurally valid hash that no password matches, used to keep login
 * timing similar whether or not the account exists.
 */
const PLACEHOLDER_HASH =
  'scrypt$16384$8$1$AAAAAAAAAAAAAAAAAAAAAA==$' + Buffer.alloc(64).toString('base64');

function publicUser(user: User): AuthenticatedUser {
  return {
    id: user.id,
    email: user.email,
    displayName: user.displayName,
    isAdmin: user.isAdmin,
  };
}

function normalizeEmail(value: unknown): string {
  return String(value ?? '')
    .trim()
    .toLowerCase();
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === 'object' && error !== null && (error as { code?: unknown }).code === 'P2002'
  );
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'Invalid password';
}
