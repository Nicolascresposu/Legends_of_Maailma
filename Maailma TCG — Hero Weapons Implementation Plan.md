# Maailma TCG — Hero Weapons Implementation Plan

Implement a new **Weapon** card type in the existing Maailma TCG codebase.

This is an extension of the current game, not a redesign.

Before making changes, inspect the current repository and identify the existing implementations for:

- card definitions and card instances
- Heroes
- Creatures
- Artifacts
- Actions
- GameAction
- legal-action generation
- attack validation
- Guard
- Ranged Creatures
- front/back-row protection
- damage resolution
- event queue
- deterministic replay/action logs
- AI controller
- network DTOs
- Godot match UI

Adapt this plan to the actual project structure and naming conventions.

Do not unnecessarily replace working abstractions.

---

# 1. Feature goal

Add **Hero-only Weapon cards**.

Weapons:

- are collectible cards
- are played from the player's hand
- cost Taika
- equip directly to the player's Hero
- give the Hero Attack
- have Durability
- allow the Hero to attack once per turn by default
- may be Melee or Ranged
- may later contain triggered/passive effects
- do not occupy Creature battlefield tiles
- are not Creature equipment
- cannot be equipped to Creatures

There must be exactly one Weapon slot per Hero.

Creature equipment is explicitly outside the scope of this feature.

Do not implement:

- Creature weapons
- Creature equipment slots
- Armor
- shields as equipment
- dual wielding
- multiple simultaneously equipped Hero Weapons
- inventory systems

---

# 2. New collectible card type

Extend the existing card-type system with:

```ts
WEAPON
```

The current conceptual card hierarchy becomes:

```text
CardDefinition
├── CreatureDefinition
├── ActionDefinition
├── ArtifactDefinition
└── WeaponDefinition
```

Do not model Weapons as Artifacts.

Artifacts and Weapons are mechanically distinct.

Artifacts are persistent support cards.

Weapons specifically modify Hero combat.

---

# 3. Weapon definition

Create a data-driven Weapon definition.

Use the existing card-definition architecture rather than creating custom classes for individual Weapons.

Conceptually:

```ts
type WeaponRange =
    | "MELEE"
    | "RANGED";

interface WeaponDefinition {
    id: string;
    name: string;

    type: "WEAPON";

    cost: number;

    attack: number;
    durability: number;

    range: WeaponRange;

    tags: string[];

    effects: EffectDefinition[];

    rarity?: CardRarity;
    source?: CardSource;
}
```

Adapt this to the actual codebase.

---

# 4. Weapon range is NOT a generic tag

`MELEE` and `RANGED` are rules properties.

Do not encode them only as:

```ts
tags: ["RANGED"]
```

Use:

```ts
range: "RANGED"
```

instead.

Generic tags can separately describe Weapon taxonomy.

Examples:

```text
SWORD
AXE
BOW
CROSSBOW
DAGGER
HAMMER
DWARVEN
RELIC
ANIMA
```

Example:

```json
{
  "id": "hunting_bow",
  "name": "Hunting Bow",
  "type": "WEAPON",
  "cost": 3,
  "attack": 2,
  "durability": 2,
  "range": "RANGED",
  "tags": ["BOW"],
  "effects": []
}
```

Example melee Weapon:

```json
{
  "id": "iron_sword",
  "name": "Iron Sword",
  "type": "WEAPON",
  "cost": 2,
  "attack": 2,
  "durability": 2,
  "range": "MELEE",
  "tags": ["SWORD"],
  "effects": []
}
```

The rules engine must never infer Weapon range from:

- card name
- card description
- artwork
- tags such as `BOW`

---

# 5. Weapon instance

Definitions remain immutable.

Create runtime state separately.

Conceptually:

```ts
interface WeaponInstance {
    instanceId: string;
    definitionId: string;

    ownerId: string;

    currentAttack: number;

    currentDurability: number;
    maxDurability: number;

    statuses?: StatusInstance[];
}
```

If the existing game has a more generic runtime-card-instance abstraction, integrate with it.

Do not mutate `WeaponDefinition.attack` or `WeaponDefinition.durability`.

---

# 6. Hero Weapon slot

Extend runtime Hero state with one optional equipped Weapon.

Conceptually:

```ts
interface HeroInstance {
    // existing properties...

    equippedWeapon: WeaponInstance | null;

    attacksUsedThisTurn: number;
}
```

If equipment belongs more appropriately on `MatchSide`, use that existing architecture instead.

The important domain rules are:

```text
One Hero
One Weapon slot
Zero or one equipped Weapon
```

---

# 7. Hero attack tracking belongs to the Hero

Do NOT store normal attack availability only on the Weapon.

Use something equivalent to:

```ts
hero.attacksUsedThisTurn
```

The normal Hero attack limit is:

```text
1 attack per turn
```

This prevents:

```text
Attack with Weapon A
→ equip Weapon B
→ attack again
```

from bypassing the Hero's normal attack limit.

Use a number rather than a boolean if practical:

```ts
attacksUsedThisTurn: number
```

This allows future mechanics such as:

```text
Your Hero may attack twice this turn.
```

without redesigning the state model.

If the codebase already has a generalized attack/action counter, reuse it.

---

# 8. Turn reset

At the appropriate turn-start lifecycle point:

```ts
hero.attacksUsedThisTurn = 0;
```

This must be deterministic and included in normal turn processing.

Do not reset Hero attacks when:

- a Weapon is equipped
- a Weapon breaks
- a Weapon is replaced
- a Weapon receives durability

---

# 9. Playing a Weapon

Playing a Weapon from hand should follow the normal server-authoritative card-play pipeline.

Conceptually:

1. Validate the card exists in the player's hand.
2. Validate it is the player's turn.
3. Validate sufficient Taika.
4. Pay Taika.
5. Remove card from hand.
6. Create WeaponInstance.
7. If a Weapon is already equipped, replace it according to the replacement rules.
8. Equip the new Weapon.
9. Generate appropriate events.
10. Resolve effects and triggers.
11. Return stable authoritative state.

Equipping a Weapon does NOT consume the Hero's attack for the turn.

Therefore this is legal:

```text
Play Iron Sword
→ Hero attacks
```

provided the Hero has not already attacked that turn.

---

# 10. Replacing an existing Weapon

A player may equip a new Weapon while another Weapon is equipped.

The previous Weapon is removed.

Do not require the old Weapon to reach zero Durability first.

Example:

```text
Currently equipped:

Rusty Dagger
1 Attack
1 Durability

Player plays Iron Sword.

Result:

Rusty Dagger is removed due to replacement.
Iron Sword becomes equipped.
```

---

# 11. Distinguish Weapon removal reasons

Do not treat every Weapon removal as identical.

Introduce a reason or equivalent context.

Conceptually:

```ts
type WeaponRemovalReason =
    | "BROKEN"
    | "REPLACED"
    | "DESTROYED_BY_EFFECT";
```

Names can be adapted to existing conventions.

Semantics:

### BROKEN

Weapon reached 0 Durability.

### REPLACED

Owner equipped another Weapon.

### DESTROYED_BY_EFFECT

A game effect explicitly destroyed the Weapon.

This distinction matters for future effects such as:

```text
When your Weapon breaks, draw a card.
```

That should not necessarily trigger when the Weapon is voluntarily replaced.

---

# 12. Hero attack GameAction

Add a dedicated Hero attack action.

Prefer:

```ts
type HeroAttackAction = {
    type: "HERO_ATTACK";
    targetId: string;
};
```

over forcing Hero combat awkwardly into Creature `ATTACK` semantics.

The exact action schema may also include:

```ts
sideId
playerId
```

if required by the current protocol.

The engine remains authoritative.

The client sends:

```text
I want my Hero to attack target X.
```

The client does NOT send:

- damage dealt
- retaliation damage
- new Durability
- whether the Weapon broke
- whether the target died

---

# 13. Conditions required for a Hero attack

A Hero attack is legal only if all applicable conditions are true.

At minimum:

```text
It is the Hero owner's turn.

Hero has an equipped Weapon.

Weapon currentAttack > 0 if zero-Attack weapons are not intended to attack.

Weapon currentDurability > 0.

Hero has remaining attack allowance this turn.

The selected target exists.

The selected target is legal according to Weapon range and Guard rules.

The match is not already finished.
```

Use the game's existing target-validation architecture.

Do not duplicate Guard logic unnecessarily.

---

# 14. Hero attack target types

For v1, a Hero Weapon may attack:

```text
Enemy Hero
Enemy Creature
```

Do not implement direct attacks against:

- Artifacts
- cards in hand
- deck
- battlefield tiles

unless such targeting already exists and is intentionally desired.

---

# 15. Enemy Hero targeting

Preserve the existing Maailma rule:

> The enemy Hero is always attackable unless the defending side controls at least one living Creature with Guard.

Therefore:

```text
Enemy board has normal Creatures:
Hero can still be attacked.
```

Example:

```text
BACK     [Elf Archer]
FRONT    [Bear]

Hero     [30 HP]
```

A Hero equipped with a Weapon may attack the enemy Hero.

But:

```text
BACK     [Elf Archer]
FRONT    [Dwarf Defender — Guard]

Hero     [30 HP]
```

The enemy Hero is not a valid attack target.

This rule applies to:

```text
Melee Weapons
Ranged Weapons
Creature attacks
```

unless future card text explicitly overrides Guard.

---

# 16. Guard and Hero Weapons

Hero Weapon attacks obey Guard.

Guard continues to have its existing two purposes:

1. protect orthogonally adjacent friendly Creatures
2. prevent attacks against the defending Hero while any living Guard exists

A Weapon must not introduce a special bypass.

A Ranged Weapon still obeys Guard.

Example:

```text
BACK        [Mage]
               │
FRONT       [Guard]
```

The Mage is protected by the Guard.

A Hunting Bow cannot attack the Mage.

The bow may attack the Guard.

The enemy Hero also cannot be attacked.

---

# 17. Melee Weapon targeting

A Weapon with:

```ts
range: "MELEE"
```

uses melee Creature-style positional targeting.

The Hero itself does not occupy a battlefield tile.

A melee Hero attack may target:

```text
any otherwise-valid enemy FRONT-row Creature
```

across all columns.

Example:

```text
Enemy FRONT

[A][B][C]

      ↑

Hero with Sword
```

The Hero may attack A, B, or C unless Guard protection makes one invalid.

---

# 18. Melee attacks against the back row

A melee Weapon may target a back-row Creature only when that Creature is exposed under the existing battlefield rules.

Normally:

```text
BACK       [Archer]
FRONT      [Bear]
```

The Archer cannot be attacked by a melee Weapon.

If:

```text
BACK       [Archer]
FRONT      [ ]
```

the Archer becomes a valid melee target unless:

- protected by Guard
- Hidden or otherwise untargetable

Use the same existing front-row shielding logic that melee Creatures use.

Avoid implementing a second, divergent version of this rule for Hero attacks.

---

# 19. Ranged Weapon targeting

A Weapon with:

```ts
range: "RANGED"
```

may target enemy Creatures in either row.

Ranged Weapons:

- can target FRONT-row Creatures
- can target BACK-row Creatures
- ignore normal front-row shielding of the back row
- are not tied to battlefield columns
- still obey Guard
- still obey Hidden and other targeting restrictions

Example:

```text
BACK      [Elf Archer]
FRONT     [Bear]
```

A Hunting Bow may target either:

```text
Elf Archer
Bear
```

provided neither is Guard-protected.

---

# 20. Melee combat retaliation

When the Hero uses a MELEE Weapon against an enemy Creature:

```text
Hero deals Weapon Attack damage to Creature.

Creature simultaneously deals its Attack damage to Hero.
```

Use the game's existing simultaneous combat semantics if available.

Example:

```text
Hero:
30 HP
Iron Sword: 3 Attack

Enemy:
Brown Bear: 4 Attack / 5 Health
```

Hero attacks Brown Bear.

Result before secondary effects:

```text
Bear takes 3 damage.
Hero takes 4 damage.
```

Do not treat the Creature's damage as a separate voluntary attack.

It is combat retaliation.

---

# 21. Ranged attacks do NOT cause retaliation

Lock this rule:

> A Hero attacking a Creature with a RANGED Weapon does not receive retaliation damage from that Creature.

Example:

```text
Hero:
Hunting Bow
2 Attack

Enemy:
Bear
4 Attack / 5 Health
```

Hero shoots Bear.

Result:

```text
Bear takes 2 damage.
Hero takes 0 retaliation damage.
```

This is an intentional balance and identity distinction between Weapon types.

Ranged Weapons should generally pay for this advantage through:

- Taika cost
- lower Attack
- lower Durability
- card-specific balance

Do not automatically apply melee retaliation rules to Ranged Weapons.

---

# 22. Hero-vs-Hero attacks

When a Hero attacks the enemy Hero with a Weapon:

```text
Attacking Hero deals Weapon Attack damage.
Defending Hero does not retaliate.
```

This applies to both:

```text
MELEE
RANGED
```

The defending Hero's own equipped Weapon does not automatically deal damage back.

---

# 23. Hero attack usage

After a legal Hero attack is committed/resolved:

```ts
attackingHero.attacksUsedThisTurn += 1;
```

Normal limit:

```text
1
```

This occurs regardless of whether:

- the target survives
- the Weapon breaks
- the attacking Hero takes lethal retaliation
- triggered effects later modify the state

Do not allow an attack to be repeated merely because resolution killed the attacking Hero or replaced the Weapon.

---

# 24. Durability consumption

A successful Weapon attack consumes:

```text
1 Durability
```

This applies when attacking:

```text
Creature
Hero
```

and for:

```text
MELEE
RANGED
```

Example:

```text
Iron Sword

Attack: 2
Durability: 3
```

After one attack:

```text
Durability: 2
```

After three total attacks:

```text
Durability: 0
```

The Weapon breaks.

---

# 25. Invalid attacks do not consume Durability

If a Hero attack fails validation:

```text
do not consume attack allowance
do not consume Durability
do not deal damage
```

Examples:

- trying to attack through Guard
- trying to melee an unexposed back-row Creature
- trying to attack twice in one turn
- trying to attack without a Weapon
- stale/invalid target ID

---

# 26. Weapon breaking

When current Durability becomes:

```text
<= 0
```

the Weapon breaks.

Generate appropriate events and remove it from the Hero's Weapon slot.

Conceptually:

```text
WEAPON_DURABILITY_CHANGED
↓
WEAPON_BROKEN
↓
Weapon removed from Hero
```

Adapt event names to the existing event architecture.

---

# 27. Weapon events

Add events only as needed by the current system, but design them to support future Weapon effects.

Recommended event vocabulary:

```text
WEAPON_EQUIPPED

WEAPON_REPLACED

WEAPON_DURABILITY_CHANGED

WEAPON_BROKEN

WEAPON_DESTROYED

HERO_ATTACK_STARTED

HERO_ATTACK_RESOLVED
```

Potential future trigger concepts:

```text
ON_EQUIP

BEFORE_HERO_ATTACK

AFTER_HERO_ATTACK

AFTER_HERO_ATTACKS_CREATURE

AFTER_HERO_ATTACKS_HERO

AFTER_HERO_KILLS_CREATURE

ON_WEAPON_DURABILITY_LOST

ON_WEAPON_BREAK

ON_WEAPON_DESTROYED
```

Do not necessarily implement all these effect trigger types immediately.

The architecture should make them natural additions.

---

# 28. Breaking must not cancel already-triggered attack effects

Be careful about event ordering.

Consider a Weapon:

```text
1 Durability

After your Hero attacks:
Draw a card.
```

The Weapon attacks.

Its Durability reaches zero.

It breaks.

The attack-triggered draw should still resolve.

Do not accidentally remove the Weapon before collecting/resolving triggers generated by the attack.

A safe conceptual approach:

```text
Validate attack
        ↓
Establish/snapshot attack context
        ↓
HERO_ATTACK_STARTED
        ↓
Resolve combat damage
        ↓
Mark Hero attack used
        ↓
Lose 1 Weapon Durability
        ↓
Queue relevant attack-triggered effects
        ↓
Weapon breaks if Durability <= 0
        ↓
Resolve queued events/triggers deterministically
        ↓
Reach stable state
```

If the current event queue already handles source entities that leave play, use its established semantics rather than inventing a second system.

The required gameplay outcome is:

> A Weapon breaking because of its attack does not retroactively cancel effects triggered by that attack.

---

# 29. Replacement semantics

When equipping a new Weapon over an existing one:

```text
Old Weapon removed with reason REPLACED.
New Weapon becomes equipped.
```

The replacement does not:

- refund Durability
- return the old Weapon to hand
- reset the Hero's used attack
- inherently trigger `BROKEN`

Example:

```text
Hero attacks with Iron Sword.
attacksUsedThisTurn = 1

Hero then plays Hunting Bow.

Hunting Bow equips.

Hero still cannot attack again that turn.
```

This behavior requires automated testing.

---

# 30. Weapon destruction effects

The engine should support destroying an equipped Weapon through a generic effect later.

If the generic effect system can reasonably support it now, add a target/entity concept for:

```text
FRIENDLY_WEAPON
ENEMY_WEAPON
ANY_WEAPON
```

or equivalent.

Do not create unnecessary cards using this immediately.

The important state transition is:

```text
Weapon destroyed
→ removal reason DESTROYED_BY_EFFECT
→ Hero Weapon slot becomes empty
```

---

# 31. Durability modification effects

Structure runtime state so future effects can do things like:

```text
Restore 1 Durability to your Weapon.

Your Weapon gains +1 Durability.

Your Weapon does not lose Durability on its next attack.
```

Do not over-engineer every future modifier now.

But avoid architecture where Durability is immutable.

---

# 32. Weapon Attack modification

Likewise, `currentAttack` should support future effects such as:

```text
Your Weapon gains +1 Attack this turn.

Your Weapon has +2 Attack while you control an Anima.

Set your Weapon's Attack to 5.
```

Use the current buff/modifier architecture where appropriate.

Do not mutate the Weapon definition.

---

# 33. Card text and presentation

Weapons should visually expose:

```text
Taika cost
Attack
Durability
```

For Ranged Weapons, also clearly expose:

```text
Ranged
```

Suggested card presentation:

```text
HUNTING BOW
3 Taika

Weapon — Ranged

2 Attack
2 Durability
```

Melee is the normal/default case.

Therefore ordinary melee Weapon cards do not necessarily need large visible `Melee` text.

For example:

```text
IRON SWORD
2 Taika

Weapon

2 Attack
2 Durability
```

However the runtime/card data must still explicitly contain:

```ts
range: "MELEE"
```

Do not infer the default in game rules from missing data if avoidable.

Validation should reject malformed Weapon definitions.

---

# 34. Ranged tooltip

The client should eventually explain Ranged consistently.

Suggested text:

```text
Ranged

Hero attacks with this Weapon can target Creatures in either row and ignore front-row shielding. Ranged attacks against Creatures do not receive retaliation.
```

Guard still applies.

The tooltip need not repeat every Guard rule.

---

# 35. Hero UI

Update the Godot match UI to show the equipped Weapon near the Hero.

At minimum display:

```text
Weapon name
Attack
Current Durability
Ranged indicator if applicable
```

Example:

```text
Hero ♥ 24

[ Iron Sword ]
  2 ⚔   1 durability
```

or for Ranged:

```text
[ Hunting Bow ]
  Ranged
  2 ⚔   2 durability
```

Use existing visual conventions where possible.

---

# 36. Hero attack interaction in Godot

When a Hero has:

```text
equipped Weapon
remaining Hero attack
```

the Hero should become an available attack source.

Interaction can follow the same UX style used for Creature attacks.

Example:

```text
select Hero
→ valid targets highlight
→ select target
→ send HERO_ATTACK
```

Do not calculate canonical legal targets only in Godot.

Use server-provided legal actions/target information where the project already supports it.

---

# 37. Legal target highlighting

When Hero with MELEE Weapon is selected:

Highlight:

```text
valid front-row enemy Creatures
valid exposed back-row enemy Creatures
enemy Hero if no Guard
```

Do not highlight:

```text
shielded back-row Creatures
Guard-protected Creatures
enemy Hero while any Guard exists
```

When Hero with RANGED Weapon is selected:

Highlight:

```text
valid Creatures in either row
enemy Hero if no Guard
```

Still exclude Guard-protected targets.

---

# 38. Animation guidance

Do not block the core implementation on elaborate animation.

A minimal first version may:

```text
highlight attacker
animate impact
show damage number
decrement Durability
remove Weapon visual if broken
```

Later polish can distinguish:

### Melee

Hero/Weapon lunges toward target.

### Ranged

Projectile animation.

Do not encode gameplay timing into animation timing.

The authoritative server resolves gameplay first.

The client visualizes the resulting event stream.

---

# 39. Protocol changes

Add Weapon state to the authoritative match DTO.

The client must be able to know:

```text
equipped Weapon
Weapon attack
Weapon current Durability
Weapon max Durability
Weapon range
Weapon tags if needed for UI
Hero attacks used / whether Hero may attack
```

Do not expose hidden information unnecessarily.

Equipped Weapons are public board state.

---

# 40. Network action

Add:

```text
HERO_ATTACK
```

to the live match protocol.

Example client request:

```json
{
  "type": "HERO_ATTACK",
  "targetId": "creature_27"
}
```

or equivalent existing action envelope.

Server must:

```text
authenticate actor
validate turn
validate action
resolve through GameEngine
broadcast authoritative events/state
```

---

# 41. Replay compatibility

Hero Weapon interactions must be deterministic and replayable.

The persisted action log needs enough information to reproduce:

```text
playing Weapon
replacing Weapon
Hero attack target selection
```

Do not persist calculated damage as player input.

Replay should derive it again from the engine.

Given:

```text
same initial state
same card definitions/version
same RNG seed
same ordered GameActions
```

the Weapon state and match result must be identical.

---

# 42. AI controller support

Update AI legal-action generation to include Weapon behavior.

The AI must at minimum understand:

```text
playing Weapon cards is legal
Hero attacks are legal actions
Melee and Ranged Weapon targets differ
Guard blocks enemy Hero attacks
Hero has one attack per turn
```

The AI does not initially need sophisticated Weapon strategy.

A simple first implementation may:

```text
if affordable Weapon and useful slot/replacement:
    possibly play Weapon

if Hero can attack:
    choose from legal Hero attack targets
```

The AI must consume the engine's legal actions rather than duplicating targeting rules.

---

# 43. Basic AI replacement behavior

Avoid obviously destructive behavior if simple to implement.

For example, AI should preferably not:

```text
replace a strong fresh Weapon
with a weaker Weapon
for no reason
```

But strategic Weapon evaluation is not a core requirement.

A crude heuristic is sufficient.

Possible heuristic:

```text
weapon value ≈ attack * durability
```

optionally with a small Ranged bonus.

Do not spend significant time optimizing this during initial implementation.

Correct legal behavior matters more.

---

# 44. PvE compatibility

Hero Weapons must work identically in PvP and Adventure Mode.

PvE Heroes/bosses may:

```text
equip Weapons normally
start with a Weapon already equipped
use custom Weapons
have unusual Hero attack limits later
```

Scenario definitions should be able to specify a starting equipped Weapon if doing so fits the existing scenario model.

Do not make this mandatory if it would significantly expand scope.

But do not architect the Weapon slot in a PvP-only location.

---

# 45. Boss compatibility

Future Adventure bosses might use:

```text
massive Weapon Attack
infinite or unusual Durability
special Weapon triggers
multiple Hero attacks
custom Weapon destruction conditions
```

Do not implement these now.

The model should simply avoid assuming all future Weapons are standard collectible player Weapons.

---

# 46. Interaction with Hero Powers

Using a Hero Power and attacking with a Weapon are independent.

Example:

```text
Hero uses Mend for 2 Taika.
Hero may still attack with Weapon.
```

Likewise:

```text
Hero attacks.
Hero may still use Hero Power if Taika permits.
```

Hero Power usage does not consume Hero attack allowance.

Hero attack does not consume Hero Power usage.

---

# 47. Interaction with summoning sickness

Hero Weapons have no summoning sickness.

A Hero may attack on the same turn a Weapon is equipped as long as:

```text
Hero has not exhausted its attack allowance.
```

Do not copy Creature `summonedThisTurn` rules onto Weapons.

---

# 48. Interaction with statuses

If the game already supports statuses affecting Hero attack ability, route Hero attacks through the same generalized checks where appropriate.

For example, future statuses might say:

```text
Hero cannot attack this turn.
```

Do not hard-code the Weapon feature in a way that prevents such statuses later.

No new Hero status system is required solely for Weapons.

---

# 49. Damage source attribution

Weapon damage should have enough context for future effects to distinguish:

```text
damage caused by Hero attack
damage caused by Weapon
damage caused by Action
damage caused by Creature
```

Do not collapse Weapon attacks into anonymous damage.

The damage event/context should be able to identify at least:

```text
attacking Hero
equipped Weapon
target
combat/ranged nature where relevant
```

This will support future text such as:

```text
Whenever your Hero deals Weapon damage...

After your Hero kills a Creature with a Weapon...

Whenever you take melee combat damage...
```

---

# 50. Kill attribution

If Hero Weapon damage reduces a Creature to lethal damage, the engine should be able to attribute the kill to the Hero/Weapon attack.

This matters for future triggers.

Do not necessarily implement a large kill-credit subsystem if one already exists.

Preserve enough attack/event context to support it.

---

# 51. Death during melee retaliation

Important edge case.

Example:

```text
Hero has 2 HP.
Hero attacks 5-Attack Creature with Sword.
```

Both combat damages occur according to existing simultaneous combat semantics.

Possible result:

```text
Creature dies.
Hero dies.
```

The normal match-resolution system decides the outcome.

Do not cancel the Hero's outgoing damage merely because retaliation is lethal.

Do not resolve retaliation before the Hero's attack in a way that prevents simultaneous combat.

---

# 52. Weapon breaking during lethal combat

Another edge case:

```text
Hero attacks using Weapon with 1 Durability.
Hero dies to retaliation.
Weapon also reaches 0 Durability.
```

Event order must remain deterministic.

The match-end system should interact cleanly with pending events.

Follow the existing engine's philosophy for:

```text
lethal damage
queued triggers
match termination
```

Do not invent Weapon-specific exceptions unless necessary.

---

# 53. Recommended initial Weapon cards

Add a small test set.

Balance is provisional.

## Rusty Dagger

```text
Cost: 1 Taika
Attack: 1
Durability: 2
Range: Melee
Tags: Dagger
```

No card text.

Purpose:

```text
cheap basic Weapon
```

---

## Iron Sword

```text
Cost: 2 Taika
Attack: 2
Durability: 2
Range: Melee
Tags: Sword
```

No card text.

Purpose:

```text
baseline melee Weapon
```

---

## War Axe

```text
Cost: 4 Taika
Attack: 4
Durability: 2
Range: Melee
Tags: Axe
```

No card text.

Purpose:

```text
high-damage melee Weapon
retaliation risk
```

---

## Hunting Bow

```text
Cost: 3 Taika
Attack: 2
Durability: 2
Range: Ranged
Tags: Bow
```

Visible keyword:

```text
Ranged
```

Purpose:

```text
basic ranged targeting test
no retaliation
```

---

## Longbow

```text
Cost: 5 Taika
Attack: 3
Durability: 2
Range: Ranged
Tags: Bow
```

Purpose:

```text
higher-cost ranged Weapon
```

Do not over-focus on final balancing yet.

---

# 54. Optional first triggered Weapon

After basic Weapons are fully stable, add one simple triggered Weapon to validate the effect architecture.

Suggested example:

## Duelist's Blade

```text
Cost: 3 Taika
Attack: 2
Durability: 3
Range: Melee
Tags: Sword
```

Possible effect:

```text
After your Hero destroys a Creature with this Weapon,
gain +1 Weapon Attack this turn.
```

Only add this after the basic system works.

If temporary Weapon buffs are not yet supported, skip this card rather than expanding scope prematurely.

---

# 55. Definition validation

Weapon definitions should reject invalid data.

At minimum consider validating:

```text
type must equal WEAPON
cost >= 0
attack >= 0
durability > 0
range must be MELEE or RANGED
tags must follow normal card-tag schema
```

Use the project's existing schema validation if available.

---

# 56. Legal-action generation

Update the engine's legal action discovery.

When the active Hero:

```text
has Weapon
has attack remaining
is otherwise allowed to attack
```

the legal action set should include:

```text
HERO_ATTACK
```

with valid targets determined by:

```text
Weapon range
Guard
front/back protection
Hidden
other target restrictions
```

Do not force the client or AI to recreate these rules.

---

# 57. Prefer shared attack-targeting utilities

Hero melee targeting should share as much existing Creature melee targeting logic as reasonably possible.

Similarly:

```text
Ranged Weapon targeting
```

should reuse generalized ranged target filtering where possible.

Good conceptual helpers might resemble:

```ts
getLegalAttackTargets({
    attackerKind: "HERO",
    attackRange: "MELEE",
    ...
})
```

rather than duplicating:

```ts
getCreatureAttackTargets()
getHeroWeaponAttackTargets()
```

with slightly different logic that can drift over time.

Do not force this abstraction if the current engine architecture makes another design cleaner.

The goal is:

> one source of truth for Guard and positional target legality.

---

# 58. Tests — card lifecycle

Add automated tests for:

```text
Weapon can be played from hand.

Playing Weapon spends Taika.

Playing Weapon removes it from hand.

Playing Weapon equips it.

Weapon state uses runtime instance.

Definition remains unchanged.

Weapon may be equipped when slot empty.
```

---

# 59. Tests — replacement

Test:

```text
Equipping Weapon B replaces Weapon A.

Old Weapon receives REPLACED reason.

New Weapon becomes active.

Replacing does not restore Hero attack.

Replacing does not incorrectly trigger BROKEN.

Replacing before attacking allows attack.

Replacing after attacking does not allow second attack.
```

That last test is critical.

---

# 60. Tests — Hero attack allowance

Test:

```text
Hero cannot attack without Weapon.

Hero with Weapon can attack once.

Hero cannot normally attack twice.

Turn transition resets Hero attack allowance.

Equipping Weapon does not reset Hero attack allowance.

Weapon breaking does not reset Hero attack allowance.

Weapon replacement does not reset Hero attack allowance.
```

---

# 61. Tests — melee targeting

Test against variable board widths where practical.

At minimum:

```text
Melee Weapon can attack enemy front-left Creature.

Melee Weapon can attack enemy front-center Creature.

Melee Weapon can attack enemy front-right Creature.

Melee Weapon is not restricted to matching columns.

Melee Weapon cannot attack protected back-row Creature.

Melee Weapon can attack exposed back-row Creature.
```

Also test on:

```text
width 1
width 2
width 4
```

to make sure Weapon targeting does not accidentally assume Standard PvP width 3.

---

# 62. Tests — ranged targeting

Test:

```text
Ranged Weapon can attack front row.

Ranged Weapon can attack back row.

Ranged Weapon ignores front-row shielding.

Ranged Weapon is not restricted by column.

Ranged Weapon still obeys Guard.
```

---

# 63. Tests — Guard

Test:

```text
Hero attack against enemy Hero succeeds with no Guard.

Enemy normal Creatures do not prevent Hero attack.

Any living enemy Guard prevents attack against enemy Hero.

Removing final Guard immediately makes Hero attack legal.

Guard-protected adjacent Creature cannot be attacked with melee Weapon.

Guard-protected adjacent Creature cannot be attacked with ranged Weapon.

Guard itself remains attackable.

One Guard does not become protected by another Guard if existing rules prohibit that.
```

---

# 64. Tests — retaliation

For MELEE Weapon:

```text
Hero damages Creature.

Creature retaliates against Hero.

Both damage instances use correct values.

Both sides may die from same combat.
```

For RANGED Weapon:

```text
Hero damages Creature.

Creature does NOT retaliate.

Weapon still loses Durability.
```

For Hero target:

```text
enemy Hero never automatically retaliates.
```

---

# 65. Tests — Durability

Test:

```text
Successful attack removes 1 Durability.

Attack against Creature removes 1.

Attack against Hero removes 1.

Melee attack removes 1.

Ranged attack removes 1.

Invalid attack removes 0.

Weapon remains equipped above 0 Durability.

Weapon breaks at 0 Durability.

Weapon slot becomes empty after break.
```

---

# 66. Tests — event ordering

Create tests specifically for:

```text
attack
damage
retaliation
Durability loss
Weapon break
Creature death
Hero death
trigger resolution
```

The test suite must demonstrate deterministic event ordering.

Also test:

```text
attack-triggered Weapon effect still resolves if the Weapon breaks from that same attack
```

when triggered Weapon effects are implemented.

---

# 67. Tests — replay

Add a replay determinism test containing at least:

```text
play Weapon
Hero attacks Creature
Weapon loses Durability
Hero attacks later
Weapon breaks
```

Replay must produce the identical final state.

Also include a Ranged Weapon scenario.

---

# 68. Tests — AI

Ensure AI:

```text
recognizes Weapon card as playable

does not send illegal Hero attacks

obeys Guard

uses Ranged legal targets correctly

cannot attack twice

handles Weapon replacement without corrupting state
```

Strategic quality is not the objective.

---

# 69. Godot testing

Verify manually or through existing client tests:

```text
Weapon appears when equipped.

Weapon stats update after attack.

Weapon disappears when broken.

Replacing Weapon changes displayed card.

Ranged indicator displays.

Hero becomes selectable as attacker.

Valid targets highlight correctly.

Illegal targets are not selectable.

Hero attack animation/event sequence does not desync the match.
```

---

# 70. Persistence/database considerations

If card definitions are persisted in PostgreSQL, update the schema/model to support Weapons.

Prefer fields such as:

```text
attack
durability
weapon_range
```

only where appropriate for the current data model.

If definitions are stored as JSON/data files rather than normalized tables, use the existing pattern.

Do not create unnecessary relational complexity solely for this feature.

---

# 71. Backward compatibility

Existing:

```text
Creature cards
Action cards
Artifact cards
decks
matches
scenarios
replays
```

must continue functioning.

Existing decks without Weapons remain valid.

Weapon support should be additive.

If serialized match state changes, handle development migration/versioning using the project's current strategy.

---

# 72. Deckbuilding

Weapons count as normal collectible deck cards.

Existing deck rules apply unless the current implementation requires explicit type registration.

No new special Weapon limit is required.

For example:

```text
2 copies of normal Weapon
1 copy if Legendary
```

according to existing rarity rules.

---

# 73. Packs and collections

Weapons may appear in normal Core packs.

They use the same collection ownership system as other collectible cards.

Example Core pack contents may include:

```text
Creature
Action
Artifact
Weapon
```

No special Weapon inventory system is required.

Chronicle Weapons may later be campaign rewards.

---

# 74. Non-goals

Explicitly do NOT implement any of the following as part of this task:

```text
Creature Weapons

Creature Equipment

Equipment slots on Creatures

Armor

Hero Armor stat

Off-hand Weapons

Dual wielding

Two simultaneous Hero Weapons

Weapon inventory outside the deck/collection system

Weapon crafting

Weapon upgrades between matches

Weapon repair between matches

Ammo

Quivers

Separate ranged ammunition resources

Weapon positioning on the Creature battlefield

Attackable Weapon entities

Artifact-to-Weapon conversion

Complex Weapon classes

D&D-style proficiency requirements
```

These can be considered separately later.

---

# 75. Implementation order

Implement incrementally.

## Phase 1 — Domain model

Add:

```text
WEAPON card type
WeaponDefinition
WeaponInstance
WeaponRange
Hero equippedWeapon
Hero attacksUsedThisTurn
```

Add definition validation.

Do not implement UI yet.

---

## Phase 2 — Playing/equipping

Implement:

```text
play Weapon
spend Taika
equip Weapon
replace Weapon
Weapon events
```

Write tests.

---

## Phase 3 — Hero melee attack

Implement:

```text
HERO_ATTACK action
Hero attack allowance
melee target validation
Hero target validation
Guard interaction
Creature retaliation
Durability loss
Weapon break
```

Write full tests before proceeding.

---

## Phase 4 — Ranged Weapons

Implement:

```text
RANGED range property
back-row targeting
front-row shielding bypass
no Creature retaliation
Guard still applies
```

Write tests.

---

## Phase 5 — Legal actions and AI

Update:

```text
legal action generator
legal target discovery
AI Controller
```

Validate variable battlefield widths.

---

## Phase 6 — Protocol/server

Expose:

```text
Weapon state
HERO_ATTACK
Weapon events
```

through the current network protocol.

Test with authoritative server.

---

## Phase 7 — Godot UI

Implement:

```text
Weapon card rendering
equipped Weapon display
Hero attack selection
target highlighting
Durability changes
break/removal
Ranged visual indicator
```

Keep animation simple initially.

---

## Phase 8 — Content

Add baseline Weapons:

```text
Rusty Dagger
Iron Sword
War Axe
Hunting Bow
Longbow
```

Use provisional balance.

---

## Phase 9 — End-to-end tests

Verify:

```text
PvP with Weapons

PvE with Weapons

melee Hero attack

ranged Hero attack

Guard

back-row protection

Weapon replacement

Weapon breaking

replay

AI
```

---

# 76. Acceptance criteria

The Weapon feature is complete when all of the following are true:

1. `WEAPON` exists as a first-class collectible card type.

2. Weapons are Hero-only.

3. There is no Creature equipment implementation.

4. A Hero may have at most one Weapon equipped.

5. Playing a Weapon costs Taika and equips it.

6. Playing a second Weapon replaces the first.

7. Weapons have Attack and Durability.

8. Weapons explicitly store `MELEE` or `RANGED`.

9. `RANGED` is not inferred from generic tags.

10. Hero attack allowance belongs to the Hero, preventing Weapon-swap multiattack exploits.

11. A Hero normally attacks once per turn.

12. A newly equipped Weapon can be used immediately if the Hero has not attacked.

13. Melee Weapons can attack any valid front-row Creature across all columns.

14. Melee Weapons can attack exposed back-row Creatures.

15. Melee Weapons cannot attack normally shielded back-row Creatures.

16. Ranged Weapons can target either row.

17. Ranged Weapons ignore normal front-row shielding.

18. Ranged Weapons still obey Guard.

19. Melee attacks against Creatures cause retaliation.

20. Ranged attacks against Creatures do not cause retaliation.

21. Enemy Heroes do not retaliate.

22. Enemy Hero is always attackable unless the defender controls Guard.

23. Guard-protected Creatures cannot be attacked by Weapon attacks.

24. Every successful attack consumes 1 Weapon Durability.

25. Invalid attacks consume no Durability.

26. Weapon reaching 0 Durability breaks and is removed.

27. Broken, replaced, and effect-destroyed Weapons can be distinguished.

28. Existing deterministic replay continues to work.

29. AI can produce legal Hero Weapon attacks.

30. Godot displays and controls Weapons without becoming authoritative.

31. Weapon targeting works on non-standard battlefield widths such as 2×1, 2×2 and 2×4.

32. Existing Creature, Action and Artifact gameplay remains functional.

33. PvP and PvE use the same Weapon rules.

34. Automated tests cover the important edge cases listed above.

---

# 77. Engineering constraints

Preserve the project's existing principles:

### Server authoritative

Clients submit intentions.

The server resolves Weapon behavior.

### Deterministic

No Weapon behavior may introduce nondeterministic state outside the existing seeded RNG system.

### Event driven

Use the existing event queue.

Do not create recursive Weapon-specific state mutation spaghetti.

### Data driven

Weapons are definitions plus reusable effects.

Do not create one TypeScript class per Weapon.

### Client agnostic

Nothing in Weapon game rules may depend on Godot.

A future web client must be able to use the same protocol.

### Variable battlefield width

Do not hard-code 3 columns when implementing Hero Weapon targeting.

### PvP/PvE shared engine

Do not create separate Weapon rules for Adventure Mode.

---

# 78. Final instruction to the coding agent

First inspect the existing codebase and map these requirements onto the architecture that already exists.

Do not blindly create parallel abstractions when equivalent systems are already present.

Before coding, produce a concise implementation map identifying:

```text
existing files/modules that will change
new files/modules required
existing combat utilities that can be reused
existing event types that can be extended
schema/protocol changes
test files that will be added or modified
Godot scenes/scripts that require changes
```

Then implement incrementally in the phase order above.

After every major phase:

```text
run existing tests
run new Weapon tests
fix regressions before continuing
```

Prioritize engine correctness over visual polish.

The finished feature should make Hero Weapons feel like a natural extension of Maailma TCG's existing tactical combat system rather than a separate subsystem bolted onto it.