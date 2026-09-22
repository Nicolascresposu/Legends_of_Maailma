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

Definitions are immutable registry data. Runtime instances contain damage, statuses, position,
summoning sickness, and combat-action exhaustion; no match mutates a definition.

## Battlefield and combat

Each side owns a battlefield whose rows are always `FRONT` and `BACK`. Its column count comes only
from `ScenarioDefinition.battlefield.width`. Geometry helpers enumerate slots and adjacency, so
widths 1 through 4—and larger positive widths—use the same rules.

Attack, move, and swap all consume the same per-Creature combat action. Melee attacks originate in
the front row; Ranged ignores that restriction and same-column front shielding. Both obey
orthogonal Guard protection. Any living Guard blocks Creature attacks against its Hero, while
ordinary Creatures never do.

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
code-owned alongside the cards. Rotating a set out of Standard or withdrawing it from packs is an
operational act rather than a release, and a policy that required a redeploy to change would make
the lifecycle a deployment problem instead of a decision.

The economy ledger is an audit log and nothing more. Collection state is the quantity table, never
a fold over the ledger, and pack generation must never read it: duplicate protection answers to
what a player owns right now, not to what they have ever owned.
