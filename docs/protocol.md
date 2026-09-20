# Server protocol

The default server address is `http://localhost:3000`; live matches use
`ws://localhost:3000/matches`.

## HTTP

- `GET /health`
- `GET /api/cards`
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
