# Maailma TCG v0.1

Maailma is a deterministic, server-authoritative tactical card game with a two-row,
variable-width battlefield. This repository contains the playable v0.1 foundation: a pure
TypeScript rules engine, data-driven cards and scenarios, replay support, a basic AI, an
HTTP/WebSocket server, and a deliberately simple Godot 4 client.

## Quick start

Requirements: Node.js 22+ and, for the desktop client, Godot 4.x.

```bash
npm install
npm test
npm run build
npm run dev
```

The server listens on `http://localhost:3000`. Open `apps/godot-client/project.godot` in Godot,
run it, then choose either **Create PvP** or **Create Bandit Ambush**. For PvP, copy the shown
match ID into a second client and join as `player-b`.

The client does not reproduce game rules: every command is validated and resolved by the server,
and the client only ever offers actions the server has already declared legal.

Targeting works as it does in Hearthstone. Press a card in your hand, or one of your creatures,
and drag: every destination that selection can legally reach lights up, a dotted arrow follows the
cursor, and releasing over a lit destination commits the action. The arrow turns green over a
legal target and red over an illegal one. Heroes are targetable in their own right — both hero
strips accept a drop whenever the server allows it, which covers attacks on the enemy Hero and
healing aimed at your own.

Dragging is not required: a plain click selects, and a second click on a lit destination commits,
so the whole game is playable without holding the mouse button. Clicking the same card or creature
again clears the selection, as does right-click or Escape. The action list on the right mirrors
whatever the current selection offers and remains usable as a fallback.

The client opens on the collection screen: sign in or create an account, browse every collectible
card with the copies you own, and build decks. Cards you do not own stay visible but dimmed, and
the deck panel shows the server's verdict live — card count, and any card you lack copies of.
A deck that is not ready can still be saved; it simply cannot be made active. Matches then use
your active deck rather than a hardcoded starter list.

Card names, costs, keywords and rules text are fetched once from `/api/cards`, so the board shows
real names rather than definition ids. The match log narrates the server's events, and the client
reconnects automatically if the socket drops.

Client scripts:

- `src/main.gd` — presentation, pointer interaction, and rendering.
- `src/collection_screen.gd` — sign-in, collection browsing and deck building.
- `src/account_client.gd` — REST transport for accounts, collections and decks.
- `src/match_client.gd` — REST + WebSocket transport, connection state, reconnection.
- `src/targeting.gd` — derives valid drop targets from the server's legal actions.
- `src/targeting_arrow.gd` — the dotted targeting arrow.
- `src/card_library.gd` — client-side cache of server card definitions.
- `src/action_formatter.gd` — readable labels for actions and events.
- `src/smoke_test.gd` — headless check of the transport and formatting layers.
- `src/drag_test.gd` — drives the real scene with synthetic mouse input.
- `src/collection_test.gd` — registers an account and builds a deck end to end.

With the server running, the client's own tests can be run from the command line:

```bash
godot --headless --path apps/godot-client --script src/smoke_test.gd
godot --path apps/godot-client --script src/drag_test.gd
godot --path apps/godot-client --script src/collection_test.gd
```

`drag_test.gd` needs a real (non-headless) run, because hit-testing depends on laid-out rects.

## Workspace map

- `packages/game-model` — JSON-compatible domain types, actions, events, state, and scenarios.
- `packages/rng` — serializable seeded random number generator.
- `packages/card-definitions` — immutable card, Hero, starter deck, and scenario data.
- `packages/game-engine` — battlefield rules, event/effect queue, controllers, decks, and replay.
- `packages/protocol` — transport-neutral client/server messages.
- `apps/server` — authoritative in-memory match host with a replaceable persistence boundary.
- `apps/godot-client` — dynamic-width Godot presentation client.
- `tests` — rules, determinism, PvE, controller, and server integration coverage.

## Database

Accounts, decks, friendships and challenges live in PostgreSQL behind Prisma. Active matches
deliberately do not: they stay in memory behind `MatchRepository`, so a match in progress never
waits on a database round trip.

Set `DATABASE_URL` in `.env` (git-ignored), then apply the schema:

```bash
npx prisma migrate dev     # create/apply migrations
npx prisma generate        # regenerate the client after schema edits
npx prisma studio          # browse the data
```

Endpoints:

```text
POST /api/auth/register        create an account, returns a session token
POST /api/auth/login           exchange credentials for a session token
POST /api/auth/logout          revoke the current token
GET  /api/auth/me              the signed-in player

GET  /api/collection           every collectible card with your owned counts
POST /api/collection/assess    check a card list without saving it

GET    /api/decks              list your decks, each with its readiness
POST   /api/decks              save a deck (legality reported, not enforced)
GET    /api/decks/:id          one deck
PUT    /api/decks/:id          replace a deck
DELETE /api/decks/:id          remove a deck
POST   /api/decks/:id/active   choose the deck matches use

GET  /api/social/friends                            accepted friends
GET  /api/social/friends/requests                   requests awaiting you
POST /api/social/friends/requests                   ask by display name
POST /api/social/friends/requests/:id/respond       accept or decline
GET  /api/social/challenges                         incoming and outgoing
POST /api/social/challenges                         challenge a friend
POST /api/social/challenges/:id/accept              creates the match
POST /api/social/challenges/:id/decline
POST /api/social/challenges/:id/cancel
```

Each account starts with the starter cards. Ownership is a count per card, because deck legality
is already expressed in copies: two of a common, one of a legendary.

Saving a deck is deliberately permissive — a player may store an unfinished deck, or one built
toward cards they have not unlocked — so only the name, the hero and the existence of each card
are enforced on save. Every deck the API returns carries a `readiness` marker instead:

```json
{
  "playable": false,
  "ruleErrors": ["Deck must contain exactly 30 cards"],
  "missing": [{ "cardId": "darek_voln", "required": 1, "owned": 0 }]
}
```

Rule problems and ownership problems are reported separately, so a client can say precisely why a
deck is not ready. Ownership is enforced when a match starts: accepting a challenge with an
unplayable deck is refused with `DECK_NOT_PLAYABLE` and the reasons.

Authenticated requests carry `Authorization: Bearer <token>`. Tokens are opaque: only a SHA-256
digest is stored, so a database leak yields no usable sessions, and logging out revokes instantly.
Passwords use scrypt with per-password salts and the cost parameters recorded in the stored string.

Clients may also open `ws://localhost:3000/lobby?token=<token>` to receive friend and challenge
events live — `CHALLENGE_RECEIVED`, `CHALLENGE_ACCEPTED` (which carries the `matchId` both players
should join), `CHALLENGE_DECLINED`, `CHALLENGE_CANCELLED`, `FRIEND_REQUEST` and `FRIEND_RESPONSE`.
The lobby is best-effort: every event it pushes is also readable over REST, so nothing depends on
a socket having been open.

## Logging

The server writes structured logs to stdout. Two environment variables control them:

```bash
LOG_LEVEL=debug npm run dev    # debug | info (default) | warn | error | silent
LOG_FORMAT=json npm run dev    # json | pretty (defaults to pretty on a TTY, json otherwise)
```

`info` records match creation, joins, leaves, hero selection, completed requests, and match
endings. `debug` adds every received message and applied action with its event count, turn, and
phase. Rejections are logged at `warn`, and only unexpected server faults reach `error`.

Every HTTP request gets an id, returned as the `x-request-id` response header and attached to each
line it produces, so a rejection can be traced back to its request. WebSocket lines carry a
`connectionId`, plus `matchId` and `playerId` once the client has joined.

`createApp` and `createLogger` take a logger and a sink respectively, so tests capture log records
instead of writing to stdout; `apps/server/src/logger.ts` is the seam to swap in a hosted log
shipper.

## Useful commands

```bash
npm test                 # run all tests
npm run build            # compile all TypeScript project references
npm run lint             # static checks
npm run format           # apply repository formatting
npm run replay -- game.json
```

A replay JSON document has this shape:

```json
{
  "setup": {
    "scenario": {},
    "seed": "example-seed",
    "players": [
      { "playerId": "a", "deck": [] },
      { "playerId": "b", "deck": [] }
    ]
  },
  "actions": [{ "type": "END_TURN", "actorId": "a" }]
}
```

The scenario and decks must contain their complete definitions/IDs as represented by the shared
model. The CLI prints the reconstructed final state and fails at the first illegal action.

## v0.1 boundaries

Accounts, decks, friendships and challenges are now PostgreSQL-backed; card collections and
ownership are not, so every player may build from the full card registry. Active matches still use
`MatchRepository`, implemented in memory so a Redis-backed store can replace it later. The admin
web app, progression, complex boss scripting, dynamic battlefield resizing, Locations, and
production matchmaking remain outside this milestone.

See [docs/architecture.md](docs/architecture.md) and [docs/protocol.md](docs/protocol.md) for the
core invariants and API details.
