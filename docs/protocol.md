# Server protocol

The default server address is `http://localhost:3000`; live matches use
`ws://localhost:3000/matches`.

## HTTP

- `GET /health`
- `GET /api/cards` — the card registry, filtered to released expansions. Each card carries a
  `description` (rules only) and an optional `flavour` (story only), both in a light markup:
  `**bold**`, `*italic*`, `\*` for a literal asterisk, and newlines as line breaks. Every keyword
  a card has is printed in bold in its description.
- `GET /api/scenarios`
- `POST /api/matches` — create an authoritative engine from a scenario, seed, and two 30-card decks.
- `GET /api/matches/:matchId` — current authoritative state (development endpoint).
- `GET /api/matches/:matchId/legal-actions/:playerId` — legal intentions for one side.
- `POST /api/matches/:matchId/actions` — submit an intention (development/test endpoint).

Example creation body:

```json
{
  "scenarioId": "STANDARD_PVP",
  "seed": "match-seed",
  "players": [
    { "playerId": "a", "heroDefinitionId": "healer", "deck": ["...30 IDs..."] },
    { "playerId": "b", "heroDefinitionId": "striker", "deck": ["...30 IDs..."] }
  ]
}
```

## WebSocket

Join before submitting actions:

```json
{ "type": "JOIN_MATCH", "matchId": "...", "playerId": "a" }
```

Hero selection is accepted until the first action:

```json
{
  "type": "SELECT_HERO",
  "matchId": "...",
  "playerId": "a",
  "heroDefinitionId": "healer"
}
```

Submit a game intention without calculated results:

```json
{
  "type": "SUBMIT_ACTION",
  "matchId": "...",
  "action": { "type": "ATTACK", "actorId": "a", "attackerId": "creature_17", "targetId": "b:hero" }
}
```

The connection is bound to its joined player and rejects actions claiming another actor. The
server responds with `MATCH_STATE`, player-specific `LEGAL_ACTIONS`, `GAME_EVENTS`, `TURN_CHANGED`,
`MATCH_ENDED`, or `ERROR`. Messages and shared state are plain JSON and contain no Godot-specific
types.

## Authenticated routes

Accounts, collections, decks, expansions, the Fragment economy, packs, trading and the social
features all sit behind a bearer token and are listed in the README. They carry no Godot-specific
types either: the same endpoints would serve a web client unchanged.

Economy failures return a structured `code` alongside their message — `CARD_NOT_CRAFTABLE`,
`EXPANSION_NOT_RELEASED`, `INSUFFICIENT_FRAGMENTS`, `TRADE_REVISION_CHANGED` and so on — so a
client can word the refusal itself rather than relaying a sentence composed on the server.

Every economy mutation accepts an optional client-chosen `requestId`. A retry after a lost response
replays the original outcome instead of executing a second time.
