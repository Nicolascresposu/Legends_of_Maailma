import type { WebSocket } from 'ws';
import type { Logger } from './logger.js';

/**
 * Presence and push for signed-in players outside a match.
 *
 * The lobby is deliberately in-memory and best-effort: it delivers to whoever
 * happens to be connected, and every event it pushes is also readable over
 * REST. A player who was offline when a challenge arrived finds it in their
 * list; nothing depends on a socket having been open.
 */
export interface LobbyMessage {
  type: string;
  [key: string]: unknown;
}

export class LobbyHub {
  /** One user may be signed in from several clients. */
  private readonly byUser = new Map<string, Set<WebSocket>>();
  private readonly bySocket = new Map<WebSocket, string>();

  constructor(private readonly logger: Logger) {}

  register(userId: string, socket: WebSocket): void {
    const sockets = this.byUser.get(userId) ?? new Set<WebSocket>();
    sockets.add(socket);
    this.byUser.set(userId, sockets);
    this.bySocket.set(socket, userId);
    this.logger.debug('Lobby connection registered', { userId, connections: sockets.size });
  }

  unregister(socket: WebSocket): void {
    const userId = this.bySocket.get(socket);
    if (!userId) return;
    this.bySocket.delete(socket);
    const sockets = this.byUser.get(userId);
    if (!sockets) return;
    sockets.delete(socket);
    if (sockets.size === 0) this.byUser.delete(userId);
  }

  userFor(socket: WebSocket): string | undefined {
    return this.bySocket.get(socket);
  }

  isOnline(userId: string): boolean {
    return (this.byUser.get(userId)?.size ?? 0) > 0;
  }

  onlineUsers(): string[] {
    return [...this.byUser.keys()];
  }

  /** Delivers to every connection for a user. Returns how many got it. */
  notifyUser(userId: string, message: LobbyMessage): number {
    const sockets = this.byUser.get(userId);
    if (!sockets || sockets.size === 0) {
      this.logger.debug('Lobby notify skipped: user offline', {
        userId,
        messageType: message.type,
      });
      return 0;
    }
    const payload = JSON.stringify(message);
    let delivered = 0;
    for (const socket of sockets) {
      // 1 === WebSocket.OPEN. Compared numerically so this module needs no
      // value import from `ws`.
      if (socket.readyState === 1) {
        socket.send(payload);
        delivered += 1;
      }
    }
    this.logger.debug('Lobby notify sent', {
      userId,
      messageType: message.type,
      delivered,
    });
    return delivered;
  }
}
