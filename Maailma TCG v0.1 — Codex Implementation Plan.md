# Maailma TCG v0.1

Build a digital tactical collectible card game based on the user's D&D campaign, Maailma.

The game takes inspiration from Hearthstone's accessibility and turn/resource structure, but it must NOT simply reproduce Hearthstone. Its primary distinguishing mechanic is a positional 2-row battlefield with variable width.

The long-term architecture must support:

- Godot desktop/mobile client
- Future web client
- PvP
- PvE / Adventure encounters
- AI-controlled opponents
- Scripted encounters and bosses
- Collectible cards and decks
- Campaign-specific unlocks
- Generic card packs
- Replay/debugging support
- Future scenario-specific battlefield sizes

The server must be authoritative and client-agnostic.

---

# 1. Technology architecture

Use a monorepo.

Recommended structure:

```text
maailma-tcg/
│
├── apps/
│   ├── server/
│   │   └── Node.js + TypeScript authoritative server
│   │
│   ├── godot-client/
│   │   └── Godot + GDScript
│   │
│   └── admin-web/
│       └── React + TypeScript
│           Future card/scenario/collection editor
│
├── packages/
│   ├── game-engine/
│   │   └── Pure deterministic TypeScript rules engine
│   │
│   ├── game-model/
│   │   └── Shared domain types
│   │
│   ├── card-definitions/
│   │   └── Data-driven card definitions
│   │
│   ├── protocol/
│   │   └── Client/server protocol and DTOs
│   │
│   └── rng/
│       └── Deterministic seeded RNG
│
├── tests/
│   ├── engine/
│   ├── cards/
│   ├── scenarios/
│   └── integration/
│
└── docs/
```

The game engine must NOT depend on:

- Godot
- React
- HTTP
- WebSockets
- PostgreSQL
- UI concepts

It must be possible to instantiate and simulate a complete match entirely from TypeScript tests.

---

# 2. Authoritative-server model

Clients send intentions.

Example:

```json
{
  "type": "ATTACK",
  "attackerId": "creature_17",
  "targetId": "creature_22"
}
```

Clients must never tell the server:

- how much damage was dealt
- whether something died
- how much Taika remains
- whether an effect triggered
- what cards were drawn
- whether an attack was legal

The game engine validates the action and produces events.

Example:

```json
[
  {
    "type": "ATTACK_STARTED",
    "attacker": "creature_17",
    "target": "creature_22"
  },
  {
    "type": "DAMAGE_DEALT",
    "source": "creature_17",
    "target": "creature_22",
    "amount": 3
  },
  {
    "type": "CREATURE_DIED",
    "entity": "creature_22"
  }
]
```

Godot consumes these events and visualizes them.

A future web client must be able to consume the same protocol.

---

# 3. Match fundamentals

Standard PvP:

```text
Players:              2
Hero health:          30
Deck size:            30
Starting Taika:        1
Maximum Taika:        10
Standard board width:  3
Board depth:           2
```

Taika works as follows:

At the beginning of each turn:

```text
maximum Taika += 1
maximum Taika cannot exceed 10
current Taika = maximum Taika
```

Cards cost Taika.

The name of the resource is always:

> Taika

Do not call it mana or essence in domain code.

---

# 4. Heroes

Heroes represent characters rather than factions or Immortals.

Do not implement Hero classes/factions for v0.1.

Create two placeholder Heroes for testing.

## Hero A

30 Health.

Hero Power:

```text
Mend
Cost: 2 Taika
Restore 2 Health to your Hero.
```

## Hero B

30 Health.

Hero Power:

```text
Strike
Cost: 2 Taika
Deal 1 damage to the enemy Hero.
```

Hero Powers can normally be used once per turn.

The architecture should support additional Heroes later.

Eventually the player's D&D party members will become playable Heroes.

---

# 5. Card types

v0.1 has exactly three normal collectible card types:

```text
Creature
Action
Artifact
```

Do NOT implement Locations yet.

## Creature

Persistent combat entities placed on battlefield tiles.

Typical properties:

```ts
interface CreatureDefinition {
    id: string;
    name: string;

    cost: number;

    attack: number;
    health: number;

    tags: string[];
    keywords: Keyword[];

    effects: EffectDefinition[];
}
```

Creature instances must track runtime state separately from their definition.

Example:

```ts
interface CreatureInstance {
    instanceId: string;
    definitionId: string;

    ownerId: string;

    currentAttack: number;
    currentHealth: number;
    maxHealth: number;

    position: Position;

    summonedThisTurn: boolean;
    combatActionUsed: boolean;

    statuses: StatusInstance[];
}
```

Never mutate card definitions during a match.

---

# 6. Creature tags

Creature tags are data, not keywords.

Examples:

```text
Human
Elf
Dwarf
Goblin

Beast
Anima
Undead
Construct

Mechanic
Warden
Rebel
Mage
Archer
Soldier
```

A Creature can have multiple tags.

Example:

```text
Lio Varga

Dwarf
Mechanic
Rebel
```

Card effects must be able to query tags generically.

---

# 7. Battlefield architecture

This requirement is extremely important.

The battlefield is always:

```text
2 rows deep
N columns wide
```

The depth of 2 is fixed.

Width must NOT be hard-coded.

Use approximately:

```ts
interface BattlefieldConfig {
    width: number;
}
```

Positions:

```ts
type BattlefieldRow = "FRONT" | "BACK";

interface Position {
    row: BattlefieldRow;
    column: number;
}
```

Standard PvP:

```ts
{
    width: 3
}
```

But the same engine must support:

```text
2 × 1
2 × 2
2 × 3
2 × 4
```

and potentially larger widths later.

Examples:

```text
Tight alley
width = 1

BACK     [ ]
FRONT    [ ]


Small room
width = 2

BACK     [ ][ ]
FRONT    [ ][ ]


Standard PvP
width = 3

BACK     [ ][ ][ ]
FRONT    [ ][ ][ ]


Open battlefield
width = 4

BACK     [ ][ ][ ][ ]
FRONT    [ ][ ][ ][ ]
```

Never write logic such as:

```ts
for (let i = 0; i < 6; i++)
```

to represent battlefield slots.

All tile iteration must derive from the Battlefield configuration.

The Godot UI must likewise render the battlefield dynamically from its width.

---

# 8. Battlefield ownership

Each side has its own battlefield.

Conceptually:

```text
             OPPONENT

BACK     [ ][ ][ ]
FRONT    [ ][ ][ ]

------------------

FRONT    [ ][ ][ ]
BACK     [ ][ ][ ]

               YOU
```

Each tile can hold either:

```text
CreatureInstance
null
```

Artifacts do NOT occupy battlefield Creature tiles.

---

# 9. Summoning

When playing a Creature:

1. Pay Taika.
2. Select an empty battlefield tile.
3. Create the Creature instance.
4. Place it on the selected tile.
5. Mark it as summoned this turn.
6. Resolve Arrival effects.
7. Process resulting triggers/events.

Normally a Creature cannot:

- Attack
- Move
- Swap

on the turn it was summoned.

Keywords may override this.

---

# 10. Combat action economy

Each Creature receives one combat action per turn.

A combat action can be consumed by:

```text
Attack
OR
Move
OR
Swap
```

After any of these, that Creature has:

```ts
combatActionUsed = true
```

Do not model Movement separately from attack readiness.

Both use the same action resource.

---

# 11. Melee combat

Normal melee Creatures:

- must be in the FRONT row to attack
- can attack valid enemy Creatures across ALL columns
- are NOT restricted to attacking their opposite lane
- cannot normally attack from the BACK row

Example:

```text
Enemy front:

[A][B][C]
 ↑  ↑  ↑
  \ | /
   [X]

Your front
```

Creature X may attack A, B, or C if they are otherwise valid targets.

---

# 12. Back-row protection

A back-row Creature normally cannot be attacked by a melee Creature if the battlefield tile directly in front of it contains a Creature.

Example:

```text
BACK     [Archer]
             ↑ protected

FRONT    [Bear]
```

If Bear leaves or dies:

```text
BACK     [Archer]

FRONT    [ ]
```

the Archer becomes attackable by melee Creatures.

This protection is based on the same column.

Ranged attacks behave differently.

---

# 13. Ranged

Keyword:

```text
Ranged
```

A Ranged Creature:

- can attack from the FRONT row
- can attack from the BACK row
- can target valid enemy Creatures in either row
- ignores normal front-row shielding of back-row Creatures
- still obeys Guard

---

# 14. Movement

Movement consumes the Creature's combat action.

A normal move:

```text
one orthogonally adjacent tile
```

Allowed:

```text
up
down
left
right
```

Not allowed:

```text
diagonal
```

The destination must be empty.

Movement must be calculated dynamically from board width.

---

# 15. Swapping

Two orthogonally adjacent friendly Creatures may swap positions.

Requirements:

- both Creatures are eligible to move
- neither has consumed its combat action
- neither is prevented from moving by a status
- neither was summoned this turn unless an ability permits immediate movement

After the swap:

```text
both Creatures consume their combat action
```

Swapping must be implemented as a first-class GameAction.

Do not simulate it as two normal movement commands.

---

# 16. Guard

Guard is positional.

Keyword:

```text
Guard
```

Guard has TWO behaviors.

## Creature protection

A Creature with Guard prevents friendly Creatures occupying orthogonally adjacent tiles from being attacked.

Example:

```text
       [A]
        │
[B] [GUARD] [C]
        │
       [D]
```

A, B, C and D are protected if those tiles exist and contain friendly Creatures.

Diagonal Creatures are not protected.

## Hero protection

If the defending side controls ANY living Creature with Guard:

```text
the defending Hero cannot be attacked by Creatures
```

Hero attacks are otherwise always legal.

This is important:

The player does NOT need to clear the enemy board before attacking the Hero.

Without Guard:

```text
Creature → enemy Hero
```

is always a legal attack if the attacker itself is allowed to attack.

With any enemy Guard:

```text
Creature → enemy Hero
```

is illegal.

## Guard interaction

Guard Creatures themselves must remain attackable.

Do not allow adjacent Guards to create circular untargetability.

A Guard Creature does not receive Guard protection from another Guard Creature.

---

# 17. Hero attacks

Lock this rule:

> The enemy Hero is always a valid attack target unless the defending side currently controls at least one living Creature with Guard.

Normal enemy Creatures do not prevent attacking the Hero.

Example:

```text
Enemy:

BACK      [Archer]
FRONT     [Bear]

Hero      [30 HP]
```

The attacking player may still attack the Hero directly.

If:

```text
Enemy:

BACK      [Archer]
FRONT     [GUARD]

Hero      [30 HP]
```

the Hero cannot be attacked.

---

# 18. Initial keywords

Implement the keyword architecture so that additional keywords can be added without rewriting card logic.

Initial planned keywords:

```text
Arrival
Last Breath
Guard
Swift
Charge
Ranged
Ward
Hidden
Lifesteal
```

Definitions:

## Arrival

Triggers when played from hand.

## Last Breath

Triggers when the Creature dies.

## Guard

Uses the rules defined above.

## Swift

May attack Creatures immediately after being summoned.

Do not allow Swift alone to attack Heroes on the summon turn.

## Charge

May immediately perform its normal combat action after being summoned, including attacking a Hero.

## Ranged

Uses ranged targeting rules.

## Ward

Negates the next applicable source of damage, then disappears.

## Hidden

Cannot normally be directly targeted until its rules reveal it.

Exact Hidden behavior may remain minimal in the first prototype if necessary.

## Lifesteal

Damage dealt restores that much health to the owner's Hero.

---

# 19. Actions

Action cards resolve once and then leave play.

Examples:

```text
Deal damage
Heal
Draw cards
Buff Creature
Destroy Creature
Apply status
Move Creature
Summon Creature
```

Effects must use the generic effect engine rather than custom card-specific code wherever possible.

---

# 20. Artifacts

Artifacts are persistent cards outside the Creature battlefield.

They may have:

```text
Durability
passive effects
triggered effects
activated effects
```

Example:

```text
Arcane Battery
```

Artifact storage should support multiple Artifacts later.

Do not assume there can only ever be one.

---

# 21. Data-driven cards

Do not create one TypeScript class for every card.

Avoid:

```ts
class Mercy7 extends Creature {}
```

Prefer declarative definitions.

Example:

```json
{
  "id": "giant_rat",
  "name": "Giant Rat",
  "type": "CREATURE",
  "cost": 1,
  "attack": 1,
  "health": 1,
  "tags": ["BEAST"],
  "effects": [
    {
      "trigger": "LAST_BREATH",
      "effect": {
        "type": "DRAW_CARD",
        "amount": 1
      }
    }
  ]
}
```

The effect system should support composition.

Custom scripted effects may eventually exist for unusual Legendary cards or bosses, but they should be the exception.

---

# 22. Event-resolution engine

Use a deterministic event queue.

Do NOT allow card effects to recursively mutate state without structured resolution.

Conceptual flow:

```text
Receive GameAction
        ↓
Validate
        ↓
Apply primary action
        ↓
Generate GameEvent
        ↓
Resolve event
        ↓
Discover triggers
        ↓
Queue triggered effects
        ↓
Resolve next effect
        ↓
Check deaths/state changes
        ↓
Generate additional events
        ↓
Continue until queue empty
        ↓
Match state becomes stable
```

Example events:

```text
TURN_STARTED
TURN_ENDED

CARD_DRAWN
CARD_PLAYED
CARD_DISCARDED

CREATURE_SUMMONED
CREATURE_MOVED
CREATURE_SWAPPED

ATTACK_STARTED
DAMAGE_DEALT
HEALING_RECEIVED

CREATURE_DIED

ARTIFACT_PLAYED
ARTIFACT_DAMAGED
ARTIFACT_DESTROYED

HERO_POWER_USED

STATUS_APPLIED
STATUS_REMOVED
```

Event resolution order must be deterministic.

---

# 23. Deterministic RNG

Every match receives an RNG seed.

Never call `Math.random()` directly from game rules.

Provide a deterministic RNG abstraction.

The following must use it:

- deck shuffling
- random targeting
- random card generation
- random card effects
- AI decisions where deterministic replay matters

Persist:

```text
seed
initial match configuration
player actions
```

This allows exact match reproduction.

---

# 24. Game actions

Use:

```ts
GameAction
```

not:

```ts
PlayerAction
```

because actions may come from humans, AI or scripts.

At minimum:

```ts
type GameAction =
    | PlayCardAction
    | AttackAction
    | MoveCreatureAction
    | SwapCreaturesAction
    | UseHeroPowerAction
    | EndTurnAction;
```

Later:

```text
Concede
Artifact activation
Choose-card decisions
Adventure interactions
```

may be added.

---

# 25. Controllers

The engine must not care who selected an action.

Represent match-side control conceptually as:

```text
HumanController
AIController
ScriptedController
```

The server obtains a legal GameAction from the appropriate controller.

Human controllers receive commands over the network.

AI controllers calculate actions.

Scripted controllers execute scenario logic.

PvP and PvE must use the same core engine.

---

# 26. PvE and Adventure Mode

Adventure Mode is a first-class architectural requirement.

Do not build the engine around an assumption that every match is symmetric PvP.

PvE scenarios may customize:

```text
Hero HP
enemy HP
starting Taika
maximum Taika
battlefield width
starting cards
starting Creatures
starting Artifacts
deck composition
special rules
AI behavior
scripted events
victory conditions
loss conditions
```

Example scenarios:

```text
Tight alley
2 × 1

Small skirmish
2 × 2

Standard duel
2 × 3

Open battlefield
2 × 4
```

Battlefield width should normally remain constant during a match in v0.1.

Dynamic battlefield resizing may be supported later.

Do not implement it yet.

---

# 27. Scenario definitions

Create a data-driven Scenario model.

Approximate concept:

```ts
interface ScenarioDefinition {
    id: string;
    name: string;

    battlefield: {
        width: number;
    };

    sideA: ScenarioSideDefinition;
    sideB: ScenarioSideDefinition;

    rules?: ScenarioRule[];

    victoryConditions?: VictoryCondition[];
    defeatConditions?: VictoryCondition[];
}
```

Standard PvP should itself be represented by a normal scenario definition.

Example:

```text
STANDARD_PVP
battlefield.width = 3
heroHealth = 30
startingTaika = 1
maxTaika = 10
```

Avoid scattering "normal PvP" constants throughout the engine.

---

# 28. Adventure bosses

The architecture should eventually support boss encounters with:

```text
unusual health totals
custom starting boards
custom Artifacts
scripted phases
special actions
special victory conditions
generated Creatures
nonstandard decks
```

Example future scenario:

```text
Mercy-7 — Relay Chamber
```

Potential setup:

```text
BACK     [Relay][Mara][Relay]
FRONT    [    ][Mercy-7][   ]
```

Boss phases may react to:

```text
TURN_STARTED
TURN_NUMBER_REACHED
BOSS_HEALTH_BELOW
CREATURE_DIED
ARTIFACT_DESTROYED
POSITION_EMPTY
CUSTOM_SCENARIO_FLAG
```

Do not implement Mercy-7's full boss fight during the initial core-engine milestone.

Just make sure the scenario and event architecture does not prevent it.

---

# 29. Collections

Two conceptual sources of collectible cards will eventually exist.

## Core cards

Generic inhabitants/items of Maailma.

Examples:

```text
Wolf
Bear
Hawk
Giant Rat
Hunting Spider

Elf Archer
Dwarf Defender
Human Mercenary
Field Medic
Apprentice Mage
```

These may appear in freely distributed card packs.

## Chronicle cards

Cards tied to actual campaign history.

Examples:

```text
Lio Varga
Darek Voln
Mercy-7
Mara Vale
Arcane Battery
Destroy the Relay
```

Chronicle cards will normally be unlocked through campaign events instead of normal packs.

Do not build the complete collection/progression system in the first engine milestone, but represent card metadata so this distinction can be added cleanly.

Suggested metadata:

```ts
source: "CORE" | "CHRONICLE"
rarity: "COMMON" | "RARE" | "EPIC" | "LEGENDARY"
```

---

# 30. Deckbuilding

Planned initial deck rules:

```text
Deck size: 30

Common:    maximum 2 copies
Rare:      maximum 2 copies
Epic:      maximum 2 copies
Legendary: maximum 1 copy
```

No Hero/class card restrictions in v0.1.

Any Hero may initially use any collectible card.

Do not implement factions/classes unless required later by actual playtesting.

---

# 31. Initial prototype cards

Use a deliberately small test pool before building a larger set.

Candidate cards:

```text
CREATURES

Wolf
Brown Bear
Hawk
Giant Rat
Hunting Spider

Elf Archer
Dwarf Defender
Human Mercenary
Field Medic
Apprentice Mage

Maintenance Anima
Mercy-4

Lio Varga
Darek Voln


ACTIONS

Healing Potion
Firebolt


ARTIFACTS

Arcane Battery
```

These values and effects are NOT necessarily final balance.

The purpose of this first set is to exercise:

- vanilla Creatures
- Ranged
- Guard
- Arrival
- Last Breath
- movement
- healing
- damage
- artifacts
- Creature tags
- positional effects

---

# 32. Godot client responsibilities

Godot is primarily:

```text
presentation
input
animation
audio
local prediction only when safe
```

It is NOT authoritative.

Godot should:

- render battlefield width dynamically
- render two rows
- show valid movement destinations
- show valid attack targets
- show Guard protection
- show Taika
- show Hero HP
- show hand
- animate Creature movement
- animate swaps
- animate attacks
- animate damage/healing
- animate death
- animate card play
- consume server event sequences

Do not duplicate rules in GDScript unnecessarily.

Whenever possible, ask the server for:

```text
legal actions
legal targets
current authoritative state
```

The client may locally highlight possible interactions based on server-provided information.

---

# 33. Future web client

The architecture must intentionally permit a future browser client.

Do not create a protocol that depends on Godot-specific concepts.

Use JSON-compatible DTOs.

Conceptually:

```text
Godot
   │
   ├─────────┐
   │         │
Web Client   │
   │         │
   └────┬────┘
        │
    Game Server
        │
    Game Engine
```

Both clients should be interchangeable from the server's perspective.

---

# 34. Networking

Use HTTP for:

```text
authentication
collection retrieval
deck management
card database
match creation
scenario retrieval
```

Use WebSockets for live matches.

Suggested communication:

```text
Client -> Server

JOIN_MATCH
PLAY_CARD
ATTACK
MOVE_CREATURE
SWAP_CREATURES
USE_HERO_POWER
END_TURN
```

Server -> Client:

```text
MATCH_STATE
LEGAL_ACTIONS
GAME_EVENTS
TURN_CHANGED
MATCH_ENDED
ERROR
```

Never rely on the client to maintain canonical match state.

---

# 35. Persistence

Use PostgreSQL for long-term persistence.

Potential tables later:

```text
users
heroes
card_definitions
collections
decks
deck_cards

matches
match_participants
match_actions

scenario_definitions
campaign_unlocks
```

Do not persist every intermediate runtime mutation synchronously unless necessary.

Active matches may initially live in server memory.

The persistence boundary should allow Redis or another state store later if needed.

---

# 36. Testing strategy

The game engine requires extensive automated tests.

Unit tests must cover at minimum:

## Battlefield

- width 1 works
- width 2 works
- width 3 works
- width 4 works
- adjacency at edges
- adjacency in center
- front/back relationships

## Movement

- orthogonal movement
- diagonal movement rejected
- occupied destination rejected
- movement consumes combat action
- summoned Creature cannot move

## Swapping

- valid adjacent swap
- nonadjacent swap rejected
- swap consumes both actions
- exhausted Creature prevents swap
- summoned Creature prevents swap

## Melee

- front Creature can attack all enemy front columns
- back Creature cannot normally attack
- shielded back Creature cannot be attacked by melee
- exposed back Creature can be attacked

## Ranged

- attacks from back row
- attacks front row
- attacks back row
- ignores front-row shielding
- obeys Guard

## Guard

- protects orthogonal friendly Creatures
- does not protect diagonally
- does not protect other Guards
- prevents Hero attacks
- removing last Guard makes Hero immediately attackable

## Hero

- Hero target allowed while enemy Creatures exist
- Hero target blocked when enemy Guard exists

## Taika

- increments each turn
- caps at 10
- refills
- costs are deducted
- illegal plays rejected

## Events

- trigger ordering deterministic
- Last Breath chains
- Arrival chains
- death detection
- simultaneous deaths
- effect queues terminate correctly

## RNG

- same seed + same actions = identical match
- different seeds may produce different shuffled decks

---

# 37. Development phases

Implement in this order.

## Phase 0 — Repository and domain skeleton

Create:

```text
monorepo
TypeScript configuration
testing framework
linting
formatting
package boundaries
```

No UI.

---

## Phase 1 — Pure battlefield model

Implement:

```text
ScenarioDefinition
BattlefieldConfig
Battlefield
Position
MatchSide
HeroInstance
CreatureInstance
```

Support arbitrary board widths with fixed depth 2.

Write tests for:

```text
width 1
width 2
width 3
width 4
```

---

## Phase 2 — Turn and Taika system

Implement:

```text
turn ownership
start turn
end turn
Taika progression
Hero health
Hero Powers
```

Use the two placeholder Heroes.

No networking.

---

## Phase 3 — Creature placement and combat actions

Implement:

```text
summoning
movement
swapping
attack eligibility
combat action consumption
summoning sickness
```

Test extensively.

---

## Phase 4 — Positional targeting

Implement:

```text
melee targeting
back-row protection
Ranged
Guard
Hero targeting
```

This phase is critical.

Do not proceed until the targeting test suite is reliable.

---

## Phase 5 — Damage/death/event engine

Implement:

```text
event queue
damage
healing
death
Arrival
Last Breath
trigger processing
```

The event resolver should be one of the best-tested components.

---

## Phase 6 — Data-driven card engine

Implement reusable effects such as:

```text
DEAL_DAMAGE
HEAL
DRAW_CARD
BUFF
APPLY_STATUS
SUMMON
MOVE
DESTROY
```

Create the first prototype cards as data.

---

## Phase 7 — Deterministic RNG and replay

Implement:

```text
seeded RNG
deterministic deck shuffle
action log
match replay
```

Provide a developer command/test utility that can replay a complete match from:

```text
scenario
seed
decks
action history
```

---

## Phase 8 — PvE controller foundation

Implement:

```text
HumanController abstraction
AIController abstraction
ScriptedController abstraction
```

Create a very basic AI.

It does not need to be intelligent.

It merely needs to produce legal actions.

For example:

```text
play affordable card
attack random legal target
move randomly if useful/required
use Hero Power if possible
end turn
```

The goal is validating PvE architecture.

---

## Phase 9 — Server

Wrap the existing engine in a Node server.

Add:

```text
match creation
match joining
WebSocket connection
action submission
state synchronization
event broadcast
```

The server should host authoritative GameEngine instances.

---

## Phase 10 — Minimal Godot client

Create a deliberately ugly functional UI.

Use simple rectangles/cards first.

Implement:

```text
connect to server
join match
dynamic battlefield rendering
hand
Taika
Hero HP
play card
select tile
attack
move
swap
Hero Power
end turn
```

Do NOT spend significant time on art or animation yet.

---

## Phase 11 — First end-to-end match

Two Godot clients must be able to:

```text
connect
select Hero
use decks
play a complete match
win/lose
disconnect safely
```

At this point Maailma TCG v0.1 becomes genuinely playable.

---

## Phase 12 — Basic Adventure encounter

Create one simple PvE scenario.

Do NOT begin with a complex campaign boss.

Example:

```text
Bandit Ambush

battlefield.width = 2

Player:
normal deck
30 HP

AI:
simple deck
20 HP
```

This proves:

```text
scenario configuration
variable board width
AIController
PvE match lifecycle
```

---

## Phase 13 — Polish

Only after gameplay works:

```text
card art
animations
VFX
audio
hover effects
drag-and-drop
movement animations
combat animations
pack opening
collection UI
deck builder
```

---

# 38. Things explicitly NOT to do yet

Do not implement:

```text
Locations
dynamic battlefield resizing
complex boss scripting
ranked matchmaking
monetization
trading
crafting
mobile push notifications
tournaments
guilds
spectator mode
large-scale infrastructure
advanced anti-cheat
dozens of Heroes
hundreds of cards
```

Design so some of these can be added later, but do not spend implementation time on them now.

---

# 39. Engineering principles

Follow these throughout the project.

### 1. Server authoritative

Clients request actions.

Server decides results.

### 2. Pure deterministic engine

Identical state + action + RNG seed must produce identical results.

### 3. Rules are independent from presentation

The engine must not know Godot exists.

### 4. Battlefield width is configuration

Never assume width 3.

### 5. PvE and PvP share the same engine

Do not fork the rules implementation.

### 6. Cards are data-first

Avoid one custom class per card.

### 7. Definitions and instances are separate

Never mutate static definitions.

### 8. Event-driven effects

Avoid recursive spaghetti between card effects.

### 9. Tests before content scale

Do not create dozens of cards until combat is stable.

### 10. Build ugly before beautiful

Gameplay first.

---

# 40. Definition of v0.1 success

Maailma TCG v0.1 is complete when:

1. Two players can connect using Godot clients.
2. Each chooses one of the two placeholder Heroes.
3. Both use 30-card decks.
4. Taika progresses from 1 to 10.
5. Creatures can be summoned onto a 2×3 battlefield.
6. Battlefield width is configurable and tested from 1 through 4.
7. Creatures can Attack, Move and Swap correctly.
8. Melee and Ranged targeting work.
9. Guard protects adjacent Creatures and blocks attacks against the Hero.
10. Heroes remain directly attackable whenever no Guard exists.
11. Actions and Artifacts work.
12. Arrival and Last Breath work through the event engine.
13. Matches are deterministic from their seed/action log.
14. One simple AI can play legal turns.
15. At least one PvE scenario uses a non-3-wide battlefield.
16. One complete PvP match and one complete PvE encounter can be played from start to finish.
17. The architecture permits a future browser client without changing the core game engine.