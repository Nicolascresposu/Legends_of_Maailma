# Server protocol

The default server address is `http://localhost:3000`; live matches use
`ws://localhost:3000/matches`.

## HTTP

- `GET /health`
- `GET /api/cards` — the card registry, filtered to released expansions. Each card carries a
  `description` (rules only) and an optional `flavour` (story only), both in a light markup:
  `**bold**`, `*italic*`, `\*` for a literal asterisk, and newlines as line breaks. Every keyword
  a card has is printed in bold in its description. A class card also carries its `classId`; a
  neutral card has none.
- `GET /api/scenarios`
- `POST /api/matches` — development and test endpoint: create an authoritative engine from a
  scenario, seed, and two players, without accounts. Each player's hero defaults to the scenario's
  for their side, and each deck is judged as that hero's class. A player sent without a `deck`
  plays the starter deck of their hero's class. Players use `/api/play` instead.
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

Hero selection is accepted until the first action, and only for a hero whose class may play the
player's deck:

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
client can word the refusal itself rather than relaying a sentence composed on the server. A
Basic card refused a craft, a disenchant or a place in a trade says `BASIC_CARD`, not the policy
codes: no expansion policy is involved, and none could change the answer.

`POST /api/collection/assess` takes an optional `heroId` alongside `cardIds` and `format`. With
one, the list is judged as that hero's class and any card of another class is named in
`ruleErrors`; the verdict's `classId` says which class it was judged as. Every collection entry
carries its card's `classId`, `null` for a neutral card.

Players enter matches through `POST /api/play` (`{ scenarioId, deckId }`) and
`POST /api/play/:matchId/join` (`{ deckId }`), always with one of their own decks, which must be
ready; they play as that deck's hero. A scenario whose second side is AI-controlled starts at once.
Any other starts with its second seat open: until a player takes it, the match reports no legal
actions and refuses every action with `WAITING_FOR_OPPONENT`. Taking the seat rebuilds the match
from its seed with the real deck, and the join is broadcast so the waiting creator sees it.
Joining without a `deckId` is how a client asks first: a player already seated is let back in,
and one who needs a deck is told `DECK_REQUIRED`. Challenges work the same way — the sender names
a `deckId` when sending and the recipient when accepting, with no fallback deck.

Every economy mutation accepts an optional client-chosen `requestId`. A retry after a lost response
replays the original outcome instead of executing a second time.
