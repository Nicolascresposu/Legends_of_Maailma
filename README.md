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

Selecting one of your creatures or a card filters the action list to that entity, and reachable
board slots become clickable so a move or summon can be confirmed on the board. Click the same
creature or card again to clear the selection. Card names, costs, keywords and rules text are
fetched once from `/api/cards`, so the board shows real names rather than definition ids. The
match log narrates the server's events, and the client reconnects automatically if the socket
drops.

Client scripts:

- `src/main.gd` — presentation, selection, and rendering.
- `src/match_client.gd` — REST + WebSocket transport, connection state, reconnection.
- `src/card_library.gd` — client-side cache of server card definitions.
- `src/action_formatter.gd` — readable labels for actions and events.
- `src/smoke_test.gd` — headless check of the transport and formatting layers.

With the server running, the client's own tests can be run headlessly:

```bash
godot --headless --path apps/godot-client --script src/smoke_test.gd
```

## Workspace map

- `packages/game-model` — JSON-compatible domain types, actions, events, state, and scenarios.
- `packages/rng` — serializable seeded random number generator.
- `packages/card-definitions` — immutable card, Hero, starter deck, and scenario data.
- `packages/game-engine` — battlefield rules, event/effect queue, controllers, decks, and replay.
- `packages/protocol` — transport-neutral client/server messages.
- `apps/server` — authoritative in-memory match host with a replaceable persistence boundary.
- `apps/godot-client` — dynamic-width Godot presentation client.
- `tests` — rules, determinism, PvE, controller, and server integration coverage.

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

PostgreSQL-backed accounts, collections and decks are intentionally deferred. Active matches use
`MatchRepository`, currently implemented in memory so a Redis-backed store can replace it later.
The admin web app, progression, complex boss scripting, dynamic battlefield resizing, Locations,
and production matchmaking are likewise outside this milestone.

See [docs/architecture.md](docs/architecture.md) and [docs/protocol.md](docs/protocol.md) for the
core invariants and API details.
