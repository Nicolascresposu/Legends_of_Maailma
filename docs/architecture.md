# Architecture

## Authority and package direction

Clients submit `GameAction` intentions. Only `GameEngine` validates legality, spends Taika,
changes health or positions, draws cards, and decides the winner. The engine has no dependency on
Godot, HTTP, WebSockets, databases, or UI concepts.

Dependency direction is one-way:

```text
game-model <- rng
     ^          ^
     |          |
card-definitions
     ^
     |
game-engine <- protocol <- server / clients
```

Each content version has immutable definitions. Publication synchronously swaps the current
registry bindings; every engine captures a fixed snapshot at creation. Runtime instances contain
damage, statuses, position, summoning sickness and combat-action exhaustion; no match mutates a
definition.

Expansions, cards and packs are loaded from `packages/card-definitions/content/<expansion>/`
JSON files. The Node loader discovers folders in sorted order and validates their shapes against
`content.schema.json`, then checks IDs, references, printed text and pack slot totals before
exposing the existing registry exports. Paths are relative to the package, independent of the
working directory. Source JSON initializes the registry; a persisted publication then restores
the active version. Admin-reviewed publication replaces it without a restart.
Heroes, classes, scenarios, starter decks, crafting prices and all mechanics remain TypeScript.
See [Creating expansion content](content.md) for the authoring workflow.

The Godot admin panel's local expansion creator edits those JSON files through draft forms and a
private preview library. Its bundled schema is generated from the same canonical JSON Schema
during the build. Local validation checks sibling IDs and references before saving; staged file
replacement detects stale reads and rolls back write failures. A separate publishing panel sends
drafts for server validation, previews exact changes and confirms version-checked publication or
rollback. Save and Publish have separate local-file and server-store responsibilities. The client
keeps its current collection catalogue separate from pinned match presentation data.

Published snapshots are addressed by a canonical SHA-256 hash. The file-backed activation log
records actor, time and previous/new versions. A single server process owns the store, which
persists across restarts. Snapshot files are written before the active pointer is atomically
replaced. Engines, AI, waiting-seat rebuilds and replay exports use pinned card definitions.
Match sockets expose only used definitions and transitive summons, keeping unused unreleased
content out of ordinary match payloads. Heroes and engine code remain code deployments.
See [Publishing](publishing.md) for the workflow and configuration.

## Glossary

The terms the code, the docs and the card text use, and use only in these senses:

- **Class** — a faction with its own heroes and its own class cards. There are two: Wizard and
  Priest.
- **Hero** — the character a player plays as. Every hero belongs to one class and has its own
  health and hero power. The Striker is a Wizard hero; The Mender is a Priest hero.
- **Class card** — a card that belongs to a class (`classId` on its definition).
- **Neutral card** — a card with no class. Any deck may hold one.
- **Deck class** — the class of the deck's hero. A deck may hold its class's cards and neutral
  cards, never another class's cards. The class is not stored separately: it is always read from
  the hero, so the two cannot disagree.
- **Basic** — a rarity for cards every player is given for free. Basic cards are never crafted,
  disenchanted, traded or found in packs, and print no rarity gem. Every other rarity — Common, Rare,
  Epic, Legendary — is earned, prints a rarity gem, and is priced by the economy.
- **Starter deck** — one per class, made of neutral cards and that class's cards. A new account is
  given enough copies to build every one. It is not a fallback: a player still builds and picks a
  deck of their own to play. Only the anonymous development endpoint deals it to a player sent
  without a deck.
- **Deck picking** — every match is entered with one of the player's own ready decks, chosen at
  the moment of entering, and the player plays as that deck's hero.
- **Card type** — Creature, Action, Artifact, Weapon or Location.
- **Location** — a card that takes one of its owner's battlefield tiles and never fights. Its
  **Durability** (the shield) is how many times it can be activated; its **duration** (the
  hourglass) is how many of its owner's turns it stands. It has either or both.

## Battlefield and combat

Each side owns a battlefield whose rows are always `FRONT` and `BACK`. Its column count comes only
from `ScenarioDefinition.battlefield.width`. Geometry helpers enumerate slots and adjacency, so
widths 1 through 4—and larger positive widths—use the same rules.

Attack, move, and swap all consume the same per-Creature combat action. Melee attacks originate in
the front row; Ranged ignores that restriction and same-column front shielding. Both obey
orthogonal Guard protection. Any living Guard blocks Creature attacks against its Hero, while
ordinary Creatures never do.

A Location occupies a tile as a Creature does, so nothing can be summoned or moved onto it, but it
cannot attack, move, be attacked or be targeted, and it shields nothing: a melee attack reaches
the back-row Creature behind it. `ACTIVATE_LOCATION` uses one: it spends a point of Durability,
resolves the Location's activation (aimed by its `targetMode`, as an Action is), and closes it
until the start of its owner's next turn. It crumbles (`LOCATION_REMOVED`, reason `SPENT`) once
its last point is spent, after everything the activation set off has resolved. A Location's
duration counts down at the start of each of its owner's turns, before anything else that turn;
at 0 it expires (reason `EXPIRED`) and its turn-start effects do not fire. Its triggered effects
answer `TURN_STARTED` and `TURN_ENDED`, and "adjacent" effects reach out from its tile.

## Deterministic resolution

`dispatch` first validates an action without mutation, applies its primary change, and drains a
FIFO work queue of public events and generic effects. Death sweeps remove all lethal Creatures in a
stable instance-ID order before their Last Breath events resolve. A 10,000-item safety limit turns
an accidental non-terminating effect chain into a rules error.

All random operations use `SeededRng`. Match state stores the normalized seed, current RNG state,
initial setup is retained by the engine, and accepted actions are appended to `actionLog`. Replaying
the setup and actions reconstructs the match exactly.

## Scenarios and controllers

Standard PvP is data, not a collection of engine constants. `BANDIT_AMBUSH` demonstrates an
asymmetric 2-column scenario with a 20-health AI opponent and a starting Creature. Human, basic AI,
and scripted controllers all produce the same `GameAction` union.

The scenario schema already carries special rules and victory-condition declarations. v0.1
resolves the implemented `ENEMY_HERO_DEFEATED` condition; custom phase scripts and custom victory
evaluators can be added at this boundary without forking combat rules.

## Persistence boundary

The server's active matches are accessed through `MatchRepository`. v0.1 uses
`InMemoryMatchRepository`; persistence can move to Redis without changing routes or rules.

PostgreSQL owns users, collections, deck lists, Fragment balances, trades and the economy ledger —
never synchronous writes for every internal effect. The division holds because nothing in a match
touches a collection: what a player owns is settled before the match starts and cannot change
during it.

Expansion policies sit deliberately on the database side even though expansion _definitions_ are
versioned JSON alongside the cards. Rotating a set out of Standard or withdrawing it from packs is an
operational act rather than a release, and a policy that required a redeploy to change would make
the lifecycle a deployment problem instead of a decision.

The economy ledger is an audit log and nothing more. Collection state is the quantity table, never
a fold over the ledger, and pack generation must never read it: duplicate protection answers to
what a player owns right now, not to what they have ever owned.
