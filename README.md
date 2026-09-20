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

The client intentionally renders simple panels and exposes the server-provided legal actions as
buttons. It does not reproduce game rules: every command is validated and resolved by the server.

## Workspace map

- `packages/game-model` — JSON-compatible domain types, actions, events, state, and scenarios.
- `packages/rng` — serializable seeded random number generator.
- `packages/card-definitions` — immutable card, Hero, starter deck, and scenario data.
- `packages/game-engine` — battlefield rules, event/effect queue, controllers, decks, and replay.
- `packages/protocol` — transport-neutral client/server messages.
- `apps/server` — authoritative in-memory match host with a replaceable persistence boundary.
- `apps/godot-client` — dynamic-width Godot presentation client.
- `tests` — rules, determinism, PvE, controller, and server integration coverage.

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
