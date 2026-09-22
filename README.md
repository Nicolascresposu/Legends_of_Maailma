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

### Pointing the client at another server

The server takes `PORT`, and the client resolves its address from, in order:

```bash
PORT=3100 npm run dev                                   # move the server

godot --path apps/godot-client -- --server=127.0.0.1:3100   # 1. command line
MAAILMA_SERVER=127.0.0.1:3100 godot --path apps/godot-client # 2. environment
```

3. `user://client.cfg`, written whenever the address is changed in the UI
4. `http://127.0.0.1:3000`

A command-line or environment address applies to that run only and is not saved, so `--server=`
never changes the stored default. Changing the address in the UI does save it, and both the
sign-in screen and the match bar accept it. `localhost:3100`, `127.0.0.1:3100` and
`http://127.0.0.1:3100/` are all accepted and normalized to the same value. The resolved address
and where it came from are printed at startup.

A saved session records the server that issued it, so pointing the client somewhere else does not
try to reuse a token from the previous one.

### Staying signed in

Signing in saves the session token to Godot's per-user data directory
(`user://session.cfg`), and the next launch resumes it: the screen shows that it is signing you
back in, checks the token against `GET /api/auth/me`, and lands on the collection when the server
confirms it. Tokens last 14 days.

Nothing is trusted until the server agrees. A token that is expired, revoked or simply rejected is
discarded and the sign-in form appears with a short explanation, rather than a half-working
collection. A token already past its expiry is dropped without a request at all. Signing out
deletes the saved session, so it will not resume.

The token is stored in plain text. Anything running as that user could read it, which is the same
trust level as most desktop game launchers; encrypting it with a key shipped inside the client
would be obfuscation rather than protection.

### Card art

Art is a client asset, looked up by convention from the card id the server already sends:

```text
apps/godot-client/art/cards/<card_id>.png
```

`wolf.png` is the art for the card `wolf`. Nothing references art in the shared model or the
engine, which the architecture keeps free of UI concepts, and no server change is involved.
`.webp`, `.jpg` and `.svg` are also accepted, tried in that order after PNG.

A card with no art file renders exactly as it did before art existed — title and stats only — so
art can be added one card at a time. Images are cropped to fill their banner rather than
stretched, so authoring them wider than tall (roughly 2:1) gives the best result.

Art appears on hand cards and on creatures and artifacts in play, laid out as title, art banner,
then stats. The collection browser shows the same art as a row thumbnail.

### Hover reveal

A board panel is too small for a card's full text, so resting the pointer on a creature or
artifact in play blows it up beside the board, Hearthstone style: large art, the printed cost and
type, live stats, and the rules text in full.

Keywords are spelled out rather than listed. The server sends them as bare identifiers — `GUARD`,
`WARD` — because the rules are the engine's; what they mean to a player is presentation, so the
glossary lives in `card_library.gd`. A keyword with no entry falls back to its name, and the
client's own test fails if one is missing, so a keyword added server-side is not quietly dropped.

The reveal waits out a short dwell, so sweeping the pointer across the board does not flash a card
at every slot it crosses, and it hides while a drag is in flight rather than covering the targets
being aimed at. Rules text that only repeats the stat line or a keyword already shown is dropped,
which is how the simpler cards are stored.

Client scripts:

- `src/main.gd` — presentation, pointer interaction, and rendering.
- `src/collection_screen.gd` — sign-in, collection browsing and deck building.
- `src/account_client.gd` — REST transport for accounts, collections and decks.
- `src/match_client.gd` — REST + WebSocket transport, connection state, reconnection.
- `src/targeting.gd` — derives valid drop targets from the server's legal actions.
- `src/targeting_arrow.gd` — the dotted targeting arrow.
- `src/card_reveal.gd` — the hover reveal for cards in play.
- `src/card_library.gd` — client-side cache of server card definitions.
- `src/card_art.gd` — looks up card art by id, with a text fallback.
- `src/session_store.gd` — remembers a signed-in session between runs.
- `src/client_config.gd` — resolves the server address from the command line, environment or disk.
- `src/action_formatter.gd` — readable labels for actions and events.
- `src/smoke_test.gd` — headless check of the transport and formatting layers.
- `src/drag_test.gd` — drives the real scene with synthetic mouse input.
- `src/reveal_test.gd` — checks the hover reveal's dwell, content and placement.
- `src/collection_test.gd` — registers an account and builds a deck end to end.
- `src/economy_test.gd` — reads a balance, opens a pack, crafts, disenchants, and checks that a
  refusal is explained rather than merely relayed.
- `src/session_test.gd` — signs in, restarts the scene, and checks the session resumes.
- `src/config_test.gd` — checks address parsing and override precedence.

With the server running, the client's own tests can be run from the command line:

```bash
godot --headless --path apps/godot-client --script src/smoke_test.gd
godot --path apps/godot-client --script src/drag_test.gd
godot --path apps/godot-client --script src/reveal_test.gd
godot --path apps/godot-client --script src/collection_test.gd
godot --path apps/godot-client --script src/economy_test.gd
godot --headless --path apps/godot-client --script src/session_test.gd
godot --headless --path apps/godot-client --script src/config_test.gd
```

`drag_test.gd` and `reveal_test.gd` need a real (non-headless) run, because hit-testing depends on
laid-out rects.

## Workspace map

- `packages/game-model` — JSON-compatible domain types, actions, events, state, and scenarios.
- `packages/rng` — serializable seeded random number generator.
- `packages/card-definitions` — immutable card, Hero, expansion, pack, starter deck, and
  scenario data, plus the crafting price table.
- `packages/game-engine` — battlefield rules, event/effect queue, controllers, decks, pack
  generation, and replay.
- `packages/protocol` — transport-neutral client/server messages.
- `apps/server` — authoritative in-memory match host with a replaceable persistence boundary.
- `apps/godot-client` — dynamic-width Godot presentation client.
- `tests` — rules, determinism, PvE, controller, and server integration coverage.

## Database

Accounts, decks, collections, Fragments, trades and the economy ledger live in PostgreSQL behind
Prisma. Active matches deliberately do not: they stay in memory behind `MatchRepository`, so a
match in progress never waits on a database round trip.

Expansion _definitions_ are code-owned alongside the cards, but their _policies_ are not: a stored
override shadows the shipped defaults, so a set can be rotated or withdrawn without a redeploy.

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

GET  /api/collection           every released card, with your counts and what you may do
POST /api/collection/assess    check a card list without saving it, in a named format

GET  /api/expansions           released expansions and the policies in force
GET    /api/expansions/admin               every expansion, unreleased included (admin)
PATCH  /api/expansions/admin/:id           change policy flags (admin)
DELETE /api/expansions/admin/:id/override  restore the shipped policy (admin)

GET  /api/economy              your Fragment balance
GET  /api/economy/history      your economy ledger
POST /api/economy/craft        spend Fragments to make copies
POST /api/economy/disenchant   turn copies back into Fragments
GET  /api/economy/extras       what disenchanting every spare would yield
POST /api/economy/extras       do it — always an explicit request

GET  /api/packs                packs you may currently open
POST /api/packs/:id/open       open one, and receive its cards
GET  /api/packs/:id/protection which cards a protected pack currently favours

GET  /api/trades               your trades
GET  /api/trades/history       what completed trades moved
POST /api/trades               open a trade with another player
GET  /api/trades/:id           one trade
PUT  /api/trades/:id/offer     replace your own side of the offer
POST /api/trades/:id/accept    accept one specific revision
POST /api/trades/:id/unaccept  withdraw your acceptance
POST /api/trades/:id/cancel    cancel; nothing moves

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

### When cards change

Card ids are plain strings with no foreign key: `@maailma/card-definitions` is the only source of
truth for which cards exist. Removing or renaming a card therefore needs no migration, and nothing
crashes — but rows referencing the old id survive, invisible to the collection browser.

The server warns about them at startup, and the seed script reports them in detail:

```bash
npm run seed -- --audit   # list stored card ids the registry no longer defines
npm run seed -- --prune   # audit, then delete the orphaned collection rows
```

Decks are only ever reported, never rewritten: stripping unknown ids would silently alter what a
player built, and such a deck already explains itself through its `readiness` marker. Repair those
in the deck builder.

Prefer retiring a card by setting `collectible: false` over deleting it. That hides it from the
collection browser while keeping existing decks intelligible, and it avoids the one genuinely
dangerous case — reusing an id for a different card later, which would silently hand the new card
to everyone who owned the old one.

### Development accounts

`npm run seed` creates a small cast to sign in as, all with the password
`maailma-dev-password`:

```text
alice@maailma.dev   owns every card; two ready decks
bob@maailma.dev     starter cards only; his "Wishlist" deck needs a legendary he lacks
carol@maailma.dev   one unfinished 12-card deck
```

Alice and Bob are already friends, so a challenge can be sent straight away, and Carol has a
pending request to Alice. Re-running the script is safe; `--reset` removes the seeded accounts
first, and `--clean` also clears accounts left behind by client test runs.

These exist only for local development and are created by a script that is never run against a
deployed database.

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

## The collection economy

Every collectible card belongs to an expansion, and each expansion carries seven independent
policies: `released`, `tradeable`, `duplicateProtection`, `craftable`, `disenchantable`,
`availableInPacks` and `standard`. Nothing infers one from another, and nothing infers any of them
from a name, a date or the order sets were added — the familiar arc of a set going from current to
rotated to archived is a pattern an operator applies to these flags, never a state the code knows
about. `released` is the one exception: it gates the other six, so unfinished content can be fully
defined and still invisible.

Fragments are the single crafting currency, held as an integer on the account:

| Rarity    | Craft | Disenchant |
| --------- | ----: | ---------: |
| Common    |     5 |          1 |
| Rare      |    20 |          5 |
| Epic      |   100 |         20 |
| Legendary |   300 |        100 |

Duplicate protection reads **current ownership and nothing else**. There is no record of what a
player has ever owned, and deliberately never will be: a card traded away or disenchanted becomes
wanted again, and one crafted to a playset stops being. Players steering their own pack odds this
way is the collection game working as intended, and `tests/packs.test.ts` pins that down explicitly
so it is not later "fixed".

Standard and Wild draw on the same collection — a card is never owned _in_ a format. Rotating a set
out of Standard invalidates decks without deleting or editing them; they stay stored, editable, and
playable in Wild, and the client says which cards rotated rather than implying the deck was built
wrong.

Trades move cards, never Fragments. Offered cards are not reserved, so a card in an open trade may
still be disenchanted or promised elsewhere; it is the trade that fails at execution rather than
the other actions that are blocked. Both players confirm the same revision, editing either side
clears both acceptances, and execution revalidates policy and ownership inside the committing
transaction. What a completed trade moved is frozen with the policy that permitted it, so
withdrawing a set from trading never makes yesterday's exchange look illegal.

Every economy mutation accepts a client-chosen `requestId`, so a retry after a lost response
replays the original outcome instead of spending twice.

## v0.1 boundaries

Accounts, decks, collections, Fragments and trades are PostgreSQL-backed. Active matches still use
`MatchRepository`, implemented in memory so a Redis-backed store can replace it later. Expansion
policies are editable through an admin API but have no admin web app yet. Progression, complex boss
scripting, dynamic battlefield resizing, Locations, and production matchmaking remain outside this
milestone, as do an auction house, real-money purchases and Fragment transfers between players.

See [docs/architecture.md](docs/architecture.md) and [docs/protocol.md](docs/protocol.md) for the
core invariants and API details.
