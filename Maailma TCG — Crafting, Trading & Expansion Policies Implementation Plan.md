# Maailma TCG — Crafting, Trading & Expansion Policies

Implement the collection economy for the existing Maailma TCG codebase.

This feature adds:

- Fragments
- crafting
- disenchanting
- player-to-player card trading
- expansion-level collection policies
- duplicate protection
- expansion pack availability
- unreleased expansions
- Standard/Wild legality

This is an extension of the existing game.

Before changing code, inspect the current implementations for:

- card definitions
- rarities
- expansions/sets, if already present
- collections
- decks
- pack generation/opening
- users/accounts
- persistence
- API conventions
- authorization
- deterministic RNG
- admin tooling
- Godot collection/deck interfaces, if present

Reuse existing abstractions wherever practical.

---

# 1. Core design principles

The economy should remain simple, social, and suitable for a small friends-focused CCG.

Important principles:

1. Cards are owned as quantities, not unique serialized physical objects.
2. Fragments are the only crafting currency.
3. Fragments cannot be traded.
4. Cards may be traded when their expansion currently permits trading.
5. Duplicate protection depends only on **current ownership**.
6. Do not track whether a player has historically seen or owned a card for duplicate protection.
7. Expansion policies are live rules.
8. Expansion policy changes affect future actions immediately.
9. Completed historical transactions remain valid.
10. Standard/Wild legality must be independent from ownership.
11. Server-side validation is authoritative.
12. Economy mutations must be transactional.
13. No policy should be inferred from dates, names, or expansion order.
14. The policies must be independently configurable.

---

# 2. Expansion model

Every collectible card must belong to an expansion.

If cards currently exist without an expansion, migrate them into an appropriate existing expansion or create something equivalent to:

```ts
CORE
```

Do not use nullable `expansionId` for normal collectible cards unless the current architecture strongly requires it.

Conceptually:

```ts
interface ExpansionDefinition {
    id: string;
    name: string;

    policy: ExpansionPolicy;
}
```

---

# 3. Expansion policies

Add the following expansion-level policies:

```ts
interface ExpansionPolicy {
    released: boolean;

    tradeable: boolean;
    duplicateProtection: boolean;

    craftable: boolean;
    disenchantable: boolean;

    availableInPacks: boolean;

    standard: boolean;
}
```

These are deliberately independent.

Do not create a hard-coded enum such as:

```ts
CURRENT
LEGACY
ARCHIVED
```

that determines all behavior.

Those concepts may exist as UI labels later, but actual behavior must come from the individual flags.

---

# 4. `released`

`released` determines whether an expansion is publicly available to players.

If:

```ts
released: false
```

cards belonging to the expansion must not normally be:

- shown in ordinary player collection browsing
- included in public card search
- placed into decks
- crafted
- disenchanted through normal player UI
- traded
- generated from packs
- used in Standard
- used in Wild
- surfaced as available content

This allows future expansions to exist in code/database before launch.

Internal development/admin tools may explicitly bypass this restriction where appropriate.

Do not delete unreleased card definitions.

Do not rely on hiding UI alone.

Server-side gameplay/economy APIs must validate `released`.

---

# 5. Releasing an expansion

Changing:

```ts
released: false
```

to:

```ts
released: true
```

makes the expansion eligible for whichever other policies are currently enabled.

Example:

```ts
{
    released: true,
    tradeable: true,
    duplicateProtection: false,
    craftable: false,
    disenchantable: true,
    availableInPacks: true,
    standard: true
}
```

means:

- expansion is visible
- packs are available
- cards may be traded
- cards cannot yet be crafted
- owned cards may be disenchanted
- duplicate protection is off
- cards are Standard legal

No secondary migration should be necessary when flipping `released`.

---

# 6. `tradeable`

If:

```ts
tradeable: true
```

cards belonging to the expansion may participate in player-to-player trades.

If:

```ts
tradeable: false
```

they cannot be included in newly executed trades.

This policy is checked when the trade is finalized.

Do not only check it when a card is first added to an offer.

Therefore:

```text
Expansion tradeable = true

Player A creates trade offer.

Before completion:
Expansion tradeable becomes false.

Players attempt to complete trade.

Result:
Trade rejected.
```

Completed historical trades are never reversed because a policy later changes.

---

# 7. `duplicateProtection`

If:

```ts
duplicateProtection: true
```

pack generation should prefer cards for which the player currently owns fewer copies than the normal playable copy limit.

Duplicate protection uses:

```text
CURRENT OWNERSHIP
```

only.

Do NOT track:

```text
ever collected
ever opened
seen before
highest count ever owned
historical collection completion
```

for duplicate-protection purposes.

This is intentional.

Players are allowed to manipulate duplicate protection by:

- trading cards away
- disenchanting cards
- crafting cards
- receiving cards in trades

This is considered part of the collection strategy.

---

# 8. Duplicate-protection copy limits

Use the existing deck-copy rules.

Current planned rules:

```text
Common      2
Rare        2
Epic        2
Legendary   1
```

If the deck-copy rules already exist centrally, duplicate protection must query them rather than duplicating constants.

Example:

```text
Elf Archer
Rare

Current ownership: 0
Protection target: 2

Eligible for protected Rare slot: YES
```

```text
Elf Archer
Current ownership: 1

Eligible: YES
```

```text
Elf Archer
Current ownership: 2

Eligible: NO
```

Legendary:

```text
Mercy-7

Current ownership: 0
Eligible: YES

Current ownership: 1
Eligible: NO
```

---

# 9. Duplicate-protection algorithm

When generating a specific rarity slot for an expansion with duplicate protection enabled:

1. Determine all cards of that rarity that are valid members of the pack pool.
2. Determine the player's current owned quantity for each card.
3. Determine each card's playable copy limit.
4. Build an `incomplete` pool containing cards where:

```ts
ownedQuantity < playableCopyLimit
```

5. If `incomplete` is non-empty, randomly select from it.
6. Otherwise, randomly select from the complete rarity pool.

Conceptually:

```ts
const incompleteCards = rarityPool.filter(card =>
    ownedQuantity(card.id) < getDeckCopyLimit(card)
);

const selectionPool =
    incompleteCards.length > 0
        ? incompleteCards
        : rarityPool;
```

Use the existing deterministic seeded RNG.

Do not use `Math.random()` directly.

---

# 10. Duplicate protection disabled

When:

```ts
duplicateProtection: false
```

ownership quantities must not influence card selection.

A player can freely receive:

```text
Wolf #3
Wolf #4
Wolf #5
```

even though only two may be used in a normal deck.

These excess cards remain useful for:

- trading
- disenchanting
- future systems

---

# 11. Policy changes and duplicate protection

If an expansion changes from:

```text
duplicateProtection: false
```

to:

```text
duplicateProtection: true
```

no migration of collection history is needed.

Protection immediately evaluates current ownership.

Example:

```text
Player owns:

Wolf ×5
Bear ×2
Elf Archer ×1
Field Medic ×0
```

After duplicate protection activates:

```text
Wolf:
already over copy limit

Bear:
complete

Elf Archer:
still eligible

Field Medic:
eligible
```

If the player later trades away Wolves until:

```text
Wolf ×1
```

Wolf becomes protected-pack eligible again.

This behavior is intentional.

---

# 12. `craftable`

If:

```ts
craftable: true
```

players may spend Fragments to create cards from the expansion.

If:

```ts
craftable: false
```

normal player crafting must be rejected.

This is independent from:

- `tradeable`
- `disenchantable`
- `availableInPacks`
- `duplicateProtection`
- `standard`

Example valid configuration:

```ts
{
    tradeable: true,
    duplicateProtection: false,
    craftable: false,
    disenchantable: true,
    availableInPacks: true
}
```

This creates a release period where cards must primarily come from packs or trades.

---

# 13. `disenchantable`

If:

```ts
disenchantable: true
```

owned cards belonging to the expansion may be converted into Fragments.

If:

```ts
disenchantable: false
```

normal player disenchant actions must be rejected.

This is independent from `craftable`.

Therefore this is valid:

```text
Craftable:       NO
Disenchantable:  YES
```

as is:

```text
Craftable:       YES
Disenchantable:  NO
```

Do not assume one implies the other.

---

# 14. `availableInPacks`

If:

```ts
availableInPacks: true
```

cards from the expansion may be generated through normal player-facing packs belonging to that expansion.

If:

```ts
availableInPacks: false
```

normal pack generation/opening must not award cards from that expansion.

Prefer expansion-specific packs such as:

```text
Core Pack

Machines of Kona Pack

Rebellion of Nacre Pack
```

rather than a universal pool containing every expansion.

If unopened packs are represented as persistent inventory items, preserve them when availability is turned off, but prevent normal opening while the expansion is unavailable.

They may become openable again if the expansion is re-enabled.

Do not silently delete unopened packs.

If the existing implementation grants pack results immediately rather than storing unopened packs, adapt accordingly.

---

# 15. `standard`

`standard` determines whether cards from the expansion are legal in the Standard format.

If:

```ts
standard: true
```

and:

```ts
released: true
```

cards from that expansion are Standard eligible.

If:

```ts
standard: false
```

they are not legal in Standard.

Wild should permit cards from all:

```text
released expansions
```

regardless of their `standard` value.

Thus:

```text
Standard legality:

released == true
AND
standard == true
```

Wild legality:

```text
released == true
```

---

# 16. Standard and Wild deck formats

Introduce or extend a deck format concept.

Conceptually:

```ts
type DeckFormat =
    | "STANDARD"
    | "WILD";
```

Deck validation should depend on format.

For Standard:

```ts
card.expansion.policy.released === true
&&
card.expansion.policy.standard === true
```

For Wild:

```ts
card.expansion.policy.released === true
```

Do not implement separate copies of cards for Standard and Wild.

The same collection is used for both.

---

# 17. Rotation behavior

When an expansion changes:

```ts
standard: true
```

to:

```ts
standard: false
```

existing Standard decks containing those cards should not be deleted or automatically edited.

Instead:

```text
Deck becomes invalid for Standard.
```

The deck may remain:

- visible
- editable
- usable in Wild if otherwise valid

The UI should explain why the deck is invalid.

Example:

```text
⚠ This deck contains 6 cards that are no longer Standard legal.
```

---

# 18. Unreleased cards and existing decks

If development/admin tooling previously placed an unreleased card in a player deck, normal matchmaking validation must reject the deck.

Do not expose unreleased cards merely because an old deck references them.

---

# 19. Recommended default expansion lifecycle

Policies are independent, but the expected normal lifecycle may be:

## New/current expansion

```ts
{
    released: true,

    tradeable: true,
    duplicateProtection: false,

    craftable: true,
    disenchantable: true,

    availableInPacks: true,

    standard: true
}
```

This is the social/trading phase.

Players open duplicates and trade with one another.

---

## Older expansion

After a later expansion launches:

```ts
{
    released: true,

    tradeable: false,
    duplicateProtection: true,

    craftable: true,
    disenchantable: true,

    availableInPacks: true,

    standard: true
}
```

The set becomes easier to complete through packs.

---

## Rotated expansion

Later:

```ts
{
    released: true,

    tradeable: false,
    duplicateProtection: true,

    craftable: true,
    disenchantable: true,

    availableInPacks: true,

    standard: false
}
```

Cards remain available in Wild.

---

## Archived expansion

Eventually:

```ts
{
    released: true,

    tradeable: false,
    duplicateProtection: true,

    craftable: true,
    disenchantable: true,

    availableInPacks: false,

    standard: false
}
```

Players can still craft missing cards.

This lifecycle is a recommendation only.

Do not hard-code it.

---

# 20. Pre-release expansion example

Future content may exist as:

```ts
{
    released: false,

    tradeable: false,
    duplicateProtection: false,

    craftable: false,
    disenchantable: false,

    availableInPacks: false,

    standard: true
}
```

The `standard` value may already be configured before release.

However, `released: false` overrides public legality.

---

# 21. Crafting currency

Use one universal crafting currency:

```text
Fragments
```

Do not create:

```text
Common Fragments
Rare Fragments
Epic Fragments
Legendary Fragments
```

Fragments belong to the player account.

Conceptually:

```ts
fragmentBalance: number
```

Prefer an integer database type.

Never use floating point.

---

# 22. Crafting economy

Use the following values:

| Rarity | Craft Cost | Disenchant Value |
|---|---:|---:|
| Common | 5 | 1 |
| Rare | 20 | 5 |
| Epic | 100 | 20 |
| Legendary | 300 | 100 |

Equivalent ratios:

```text
Common       1 / 5
Rare         1 / 4
Epic         1 / 5
Legendary    1 / 3
```

Keep this configuration centralized.

Conceptually:

```ts
const CRAFTING_VALUES = {
    COMMON: {
        craft: 5,
        disenchant: 1
    },

    RARE: {
        craft: 20,
        disenchant: 5
    },

    EPIC: {
        craft: 100,
        disenchant: 20
    },

    LEGENDARY: {
        craft: 300,
        disenchant: 100
    }
};
```

Do not scatter these numbers through services/UI.

---

# 23. Crafting action

Create an authoritative server action/service similar to:

```ts
craftCard(userId, cardId, quantity)
```

A craft request must validate:

1. Card exists.
2. Expansion exists.
3. Expansion is released.
4. Expansion is craftable.
5. Card is collectible.
6. Requested quantity is valid.
7. User has enough Fragments.
8. Resulting ownership state is allowed.

Do not necessarily prohibit crafting above deck-copy limits unless the current design wants that restriction.

Because excess copies are useful for trading/disenchanting, allowing crafting beyond playable limits is acceptable.

However, default UI should usually craft one copy at a time.

---

# 24. Crafting transaction

Crafting must be atomic.

Conceptually:

```text
BEGIN TRANSACTION

lock/read fragment balance

validate current expansion policy

validate balance

subtract fragments

increment owned card quantity

write economy transaction record

COMMIT
```

If any part fails:

```text
ROLLBACK
```

Never subtract Fragments without granting the card.

Never grant a card without subtracting Fragments.

---

# 25. Disenchant action

Create something equivalent to:

```ts
disenchantCard(userId, cardId, quantity)
```

Validate:

1. Card exists.
2. Expansion is released.
3. Expansion is disenchantable.
4. Player currently owns sufficient copies.
5. Quantity is positive.
6. Card is normally disenchantable.

Then:

```text
owned quantity -= quantity
fragment balance += value × quantity
```

in one transaction.

---

# 26. Cards used in decks

Do not block trading or disenchanting merely because a card currently appears in one or more decks.

Instead:

```text
collection changes
↓
affected deck may become invalid
```

Example:

```text
Deck contains:
2 × Hunting Bow

Player trades one away.

Player now owns:
1 × Hunting Bow

Deck still references 2.
```

Result:

```text
Deck marked/validated as invalid.
```

The player must fix the deck before using it.

Do not silently remove cards from the deck unless the current deck architecture already intentionally behaves that way.

---

# 27. Disenchant Extras

Add an eventual convenience action:

```text
DISENCHANT_EXTRAS
```

It should identify owned copies above the player's playable copy limit.

Example:

```text
Wolf ×5
Playable limit: 2
Extras: 3
```

If Common:

```text
3 Fragments
```

Do not automatically disenchant extras.

Player must explicitly request it.

Respect the expansion's current:

```ts
disenchantable
```

policy.

If some extras belong to non-disenchantable expansions, leave them untouched.

---

# 28. Balance-change full refunds

Design the system so a temporary disenchant override can be supported later.

Example:

```ts
interface CardEconomyOverride {
    disenchantValue?: number;
    expiresAt?: timestamp;
}
```

or equivalent.

This supports:

```text
Card nerfed
↓
Temporary disenchant value = full crafting cost
```

Example Legendary:

```text
Normal disenchant: 100
Temporary full refund: 300
```

This does not need extensive admin UI in the first implementation, but avoid an architecture that makes it difficult.

---

# 29. Player collection model

Prefer quantity-based ownership:

```ts
interface CollectionEntry {
    userId: string;
    cardId: string;
    quantity: number;
}
```

Do not assign unique IDs to ordinary individual copies.

Example:

```text
Wolf ×4
Mercy-7 ×1
Hunting Bow ×3
```

is sufficient.

Trading and disenchanting modify quantities.

---

# 30. No historical ownership required

Do not add any field like:

```text
hasEverOwned
everCollected
highestOwned
seen
```

for duplicate protection.

Current ownership is the source of truth.

Historical economy records may still exist for auditing, but pack logic must not use them.

---

# 31. Trading overview

Players may trade cards directly with one another when the cards' expansions permit trading.

Fragments cannot participate in trades.

Initial trade contents may contain:

```text
0..N cards from Player A
0..N cards from Player B
```

One-sided trades are allowed.

Therefore gifting is legal.

Example:

```text
Player A gives:
1 × Mercy-4

Player B gives:
nothing
```

This is valid if Mercy-4's expansion is tradeable.

---

# 32. Trade lifecycle

Recommended state machine:

```ts
type TradeStatus =
    | "OPEN"
    | "ACCEPTED"
    | "CANCELLED"
    | "FAILED";
```

If useful, add:

```text
EXPIRED
```

later.

Each trade contains two participants and two offers.

Conceptually:

```ts
interface Trade {
    id: string;

    participantAId: string;
    participantBId: string;

    offerA: TradeOffer;
    offerB: TradeOffer;

    acceptedByA: boolean;
    acceptedByB: boolean;

    revision: number;

    status: TradeStatus;
}
```

---

# 33. Trade offers

Conceptually:

```ts
interface TradeOffer {
    cards: TradeCardQuantity[];
}

interface TradeCardQuantity {
    cardId: string;
    quantity: number;
}
```

Fragments must not appear in this structure.

Do not support negative quantities.

Do not allow the same card to appear multiple times inside the same offer; normalize quantities.

---

# 34. Trade confirmation

Both players must explicitly confirm the same final version of the trade.

If either player modifies either side's offer:

```text
acceptedByA = false
acceptedByB = false
revision += 1
```

This prevents:

```text
Player A accepts
Player B changes offer
trade immediately executes
```

The UI should clearly indicate when an offer changed.

---

# 35. Trade execution

A trade executes only after both participants have accepted the current revision.

Before committing, the server must revalidate:

- both users still exist
- both are actual trade participants
- trade is still OPEN
- revision is current
- both confirmations apply to that revision
- every card exists
- every involved expansion is released
- every involved expansion is currently tradeable
- each sender currently owns the offered quantity

Do not rely on validation performed when the card was first added.

---

# 36. Trade atomicity

Trade execution must use one database transaction.

Conceptually:

```text
BEGIN

revalidate policies

lock required collection entries

revalidate quantities

subtract Player A offered cards
subtract Player B offered cards

add A's cards to Player B
add B's cards to Player A

record immutable completed trade
mark trade completed

COMMIT
```

Any failure:

```text
ROLLBACK
```

A partial trade must be impossible.

---

# 37. Do not reserve offered cards

For the first version, adding a card to a pending trade should not lock or reserve it.

A player may:

- disenchant it
- use it in another trade
- give it away elsewhere

before the current trade finishes.

If ownership changes, final trade validation may fail.

Example:

```text
Player offers:
2 × Wolf

Before completion:
Player disenchants one.

Current quantity:
1

Trade finalization:
FAILED
```

This is simpler than maintaining reservations.

Multiple open trades may therefore temporarily reference the same copies.

Only successfully committed transactions matter.

---

# 38. Trading and duplicate protection

Receiving a card changes current ownership normally.

Therefore it immediately affects duplicate protection.

Example:

Before trade:

```text
Elf Archer
Owned: 1
Copy limit: 2
```

Eligible in duplicate-protected packs.

After receiving another via trade:

```text
Owned: 2
```

No longer preferred.

If the player later trades one away:

```text
Owned: 1
```

it becomes eligible again.

This is intentional.

---

# 39. Trading and crafting manipulation

Players are allowed to manipulate pack probabilities through the economy.

Examples:

```text
Trade away second copy
→ card becomes duplicate-protection eligible
```

```text
Disenchant second copy
→ card becomes eligible
```

```text
Craft second copy
→ card becomes protected
```

Do not add anti-manipulation tracking.

This is considered gameplay.

---

# 40. Trading and Standard/Wild

`standard` does not affect tradeability.

A Wild-only card may still be traded if:

```ts
tradeable === true
```

Likewise, a Standard card may be non-tradeable.

These policies are independent.

---

# 41. Trading and pack availability

`availableInPacks` does not affect trading.

A card no longer obtainable from packs may still be tradeable if:

```ts
tradeable === true
```

This supports collector-focused special sets later.

---

# 42. Trading and crafting

`craftable` does not affect trading.

A non-craftable card may still be traded if allowed.

This creates potential expansion states where:

```text
Pack or trade are the only acquisition methods.
```

---

# 43. Trading and disenchanting

`disenchantable` also does not control trading.

A non-disenchantable card may still be tradeable.

A tradeable card may still be non-disenchantable.

All expansion policies remain independent.

---

# 44. Trade history

Completed trades must be recorded immutably.

Store enough information to answer:

```text
Who traded?

When?

Which cards?

Which quantities?

What was the expansion/policy context if useful?

What trade ID/revision completed?
```

Example UI/history entry:

```text
September 28, 2026

Nicolás → Matías
1 × Longbow

Matías → Nicolás
1 × Lio Varga
2 × Giant Rat
```

Historical records must not change when current expansion policies later change.

---

# 45. Trade cancellation

Either participant may cancel an OPEN trade.

Cancellation:

```text
does not modify collections
does not modify Fragments
does not perform partial transfers
```

Cancelled trades cannot later execute.

---

# 46. Trade failure

If execution validation fails because of:

- insufficient ownership
- policy change
- unreleased expansion
- concurrency conflict

mark the attempt appropriately or return the trade to an editable state according to existing application conventions.

Prefer preserving enough information for the UI to explain the failure.

Example:

```text
Trade could not be completed:
Machines of Kona cards are no longer tradeable.
```

---

# 47. Collection mutation and deck validity

After:

```text
trade
disenchant
```

affected decks may no longer be usable.

Do not manually attempt to predict every affected deck inside the economy transaction if the current deck validator can evaluate them dynamically.

At minimum, matchmaking/deck-selection validation must compare required counts with current owned quantities.

---

# 48. Pack definitions

Prefer a pack definition tied to one expansion.

Conceptually:

```ts
interface PackDefinition {
    id: string;
    name: string;

    expansionId: string;

    cardCount: number;

    rarityRules: PackRarityRules;
}
```

Suggested normal pack:

```text
5 cards
```

Exact rarity probabilities can remain in the existing pack system or be defined separately.

---

# 49. Expansion pack validation

Before opening an expansion-specific pack, validate:

```ts
expansion.policy.released === true
```

and:

```ts
expansion.policy.availableInPacks === true
```

Otherwise reject normal player opening.

Pack generation must only consider cards from the pack's configured expansion unless the pack definition explicitly supports a mixed pool.

---

# 50. Pack rarity generation

Separate:

```text
rarity selection
```

from:

```text
card selection inside that rarity
```

Example:

```text
Pack slot says Rare.
↓
Get eligible Rare cards.
↓
Apply duplicate protection if expansion has it.
↓
Select using seeded RNG.
```

Do not implement duplicate protection by changing rarity probabilities.

---

# 51. Pack eligibility

A card may enter a normal pack pool only if:

- its expansion matches the pack definition
- expansion is released
- expansion is available in packs
- card is collectible
- card is allowed in packs by any existing card-level rule

Do not use `standard` as a pack eligibility requirement.

Wild-only expansions may remain available in packs.

---

# 52. Expansion visibility

Player-facing expansion lists should normally include only:

```ts
released === true
```

Admin/dev tools may include unreleased expansions.

The same principle applies to card browsing.

Do not leak unreleased:

- card names
- artwork
- descriptions
- rarity
- counts

through normal APIs.

---

# 53. Expansion UI

Expose the active policies clearly.

Example:

```text
MACHINES OF KONA

Released                  ✓
Available in Packs        ✓
Trading                   ✓
Crafting                  ✗
Disenchanting             ✓
Duplicate Protection      ✗
Standard                   ✓
```

For normal players, `Released` does not necessarily need to appear because unreleased expansions are hidden.

Admin UI should show all flags.

---

# 54. Collection UI

Cards should surface relevant current actions.

Examples:

## Craftable missing card

```text
HUNTING BOW

Owned: 0 / 2

Craft:
20 Fragments

[ CRAFT ]
```

## Non-craftable card

```text
Crafting currently unavailable for this expansion.
```

## Disenchantable owned card

```text
Owned: 3

Disenchant:
+5 Fragments

[ DISENCHANT ]
```

## Non-disenchantable card

Hide or disable the action and explain why.

---

# 55. Trading UI

A trade screen should show:

```text
Your offer

Their offer
```

Each side may contain multiple cards.

Show:

- card name
- rarity
- quantity
- optional disenchant value as information

Do not prevent unequal-value trades.

Do not assign a server-side fairness score.

Do not require same-rarity exchanges.

---

# 56. Gifts

One-sided trades are explicitly supported.

Example:

```text
Player A:
1 × Hunting Bow

Player B:
nothing
```

Both players must still confirm.

This is useful for the small social nature of Maailma TCG.

---

# 57. No Fragment trading

Do not permit Fragments in:

- direct trades
- gifts
- trade offers

There is no:

```text
transferFragments(userA, userB)
```

player-facing feature.

Players may indirectly transfer crafting value by trading cards and disenchanting them.

That is acceptable.

---

# 58. Economy transaction log

Create or extend an immutable economy ledger.

Useful transaction types:

```ts
type EconomyTransactionType =
    | "CRAFT"
    | "DISENCHANT"
    | "TRADE"
    | "PACK_OPEN"
    | "REWARD"
    | "ADMIN_GRANT";
```

The exact model may differ.

Record enough context for debugging:

```text
user
card
quantity
fragment delta
source
timestamp
related trade/pack ID
```

Do not make the ledger the primary collection-state calculation unless the existing architecture is event-sourced.

A quantity table plus audit log is sufficient.

---

# 59. Idempotency

Economy mutations should protect against duplicate network requests.

Especially:

```text
craft
disenchant
trade acceptance/execution
pack opening
```

should not double-execute because of a retry.

Use the application's existing idempotency/request mechanism if present.

If none exists, consider adding an operation/request ID to mutation commands.

Example:

```text
Client sends CRAFT_CARD request.

Response is lost.

Client retries.

Player must not spend another 300 Fragments and receive a second Legendary accidentally.
```

---

# 60. Concurrency

Protect against two simultaneous operations spending the same resources.

Examples:

```text
User has 300 Fragments.

Two 300-fragment craft requests arrive simultaneously.
```

Only one may succeed.

Likewise:

```text
User owns 1 Legendary.

Two trades simultaneously attempt to transfer it.
```

Only one may succeed.

Use:

- database transactions
- row locking
- optimistic concurrency/versioning

according to the current persistence architecture.

Do not rely on in-memory checks alone.

---

# 61. Suggested persistence model

Adapt names to the existing database.

Conceptually:

```text
expansions
-----------
id
name
released
tradeable
duplicate_protection
craftable
disenchantable
available_in_packs
standard
```

```text
collection_entries
------------------
user_id
card_id
quantity
```

```text
user_economy
------------
user_id
fragment_balance
version
```

```text
trades
------
id
participant_a_id
participant_b_id
status
revision
accepted_by_a
accepted_by_b
created_at
updated_at
completed_at
```

```text
trade_items
-----------
trade_id
offering_user_id
card_id
quantity
```

```text
economy_transactions
--------------------
id
user_id
type
fragment_delta
metadata
created_at
```

Use existing tables if equivalent ones already exist.

---

# 62. Admin policy management

Provide an administrative mechanism to update expansion policies.

This can initially be:

- database-backed admin endpoint
- existing admin panel
- development configuration

depending on the current project.

The server should not require a redeploy simply to rotate:

```text
Tradeable ON → OFF

Duplicate Protection OFF → ON

Standard ON → OFF
```

if expansion definitions are already persisted.

If card/expansion definitions currently live in static data files, keeping policies there initially is acceptable.

Do not force a major persistence redesign only for this feature.

---

# 63. Policy validation

Expansion definitions should be schema validated.

At minimum:

```text
released: boolean
tradeable: boolean
duplicateProtection: boolean
craftable: boolean
disenchantable: boolean
availableInPacks: boolean
standard: boolean
```

Avoid implicit defaults for production data when practical.

Explicit policy values reduce accidental releases.

---

# 64. Policy evaluation helper

Centralize expansion-policy checks.

Avoid scattered logic such as:

```ts
if (expansion.tradeable && expansion.released)
```

across dozens of services.

Prefer helpers along the lines of:

```ts
canTradeExpansion(expansion)
canCraftExpansion(expansion)
canDisenchantExpansion(expansion)
canOpenExpansionPacks(expansion)
isExpansionStandardLegal(expansion)
isExpansionWildLegal(expansion)
```

These helpers remain small and deterministic.

Example:

```ts
canTradeExpansion(expansion) =
    expansion.policy.released
    && expansion.policy.tradeable;
```

Standard:

```ts
isExpansionStandardLegal(expansion) =
    expansion.policy.released
    && expansion.policy.standard;
```

Wild:

```ts
isExpansionWildLegal(expansion) =
    expansion.policy.released;
```

---

# 65. Policy precedence

`released` acts as the public master gate.

Thus:

```text
released = false
tradeable = true
```

does NOT make cards publicly tradeable.

Likewise:

```text
released = false
standard = true
```

does NOT make cards Standard legal.

Other policies retain their configured values so they are ready when release occurs.

---

# 66. Do not couple Standard with packs

An expansion may be:

```text
Standard: NO
Available in Packs: YES
```

This is valid.

Players may continue opening Wild-only expansions.

Likewise:

```text
Standard: YES
Available in Packs: NO
```

is valid.

Perhaps the expansion is Standard legal but obtainable only through crafting/rewards.

Do not prohibit unusual policy combinations.

---

# 67. Do not couple Released with deletion

Unreleased content remains fully defined internally.

`released: false` means:

```text
not player-facing
```

not:

```text
does not exist
```

This allows testing future sets.

---

# 68. Deck validator changes

Deck validation should include:

```text
ownership
copy limits
deck size
format legality
released state
```

For each card:

```text
STANDARD:
released && standard

WILD:
released
```

A deck may be stored while invalid.

It simply cannot enter a match requiring that format.

---

# 69. Match creation

PvP match creation should specify a format where applicable.

Conceptually:

```ts
interface MatchRules {
    deckFormat: "STANDARD" | "WILD";
}
```

Adventure/PvE scenarios may ignore normal Standard/Wild restrictions if intentionally configured.

Do not unnecessarily prevent scenario-specific decks from containing Wild content.

---

# 70. Collection browsing by format

The client may offer filters:

```text
Standard
Wild
Expansion
Rarity
Owned
Missing
```

Standard filter:

```text
released && standard
```

Wild:

```text
released
```

This is presentation only.

Server deck validation remains authoritative.

---

# 71. Initial Core expansion

If existing generic cards currently behave like a permanent basic/core set, create a clear policy.

Example:

```ts
{
    released: true,

    tradeable: true,
    duplicateProtection: true,

    craftable: true,
    disenchantable: true,

    availableInPacks: true,

    standard: true
}
```

Actual values may be adjusted later.

Do not hard-code Core as special unless necessary.

Treat it like an expansion wherever possible.

---

# 72. Chronicle/campaign rewards

Do not redesign Chronicle cards as part of this task unless needed for compatibility.

If Chronicle cards already have campaign unlock restrictions, those rules may coexist with expansion policies.

Conceptually, both requirements may need to pass.

Example crafting rule:

```text
Expansion is craftable
AND
card-specific campaign requirement is satisfied
```

Do not remove existing campaign gating.

Expansion policy should be one layer, not necessarily the only eligibility system.

---

# 73. Tests — expansion policies

Test every policy independently.

At minimum:

```text
unreleased expansion is hidden

unreleased cards cannot be crafted

unreleased cards cannot be traded

unreleased cards cannot appear in packs

unreleased cards are not Standard legal

unreleased cards are not Wild legal
```

Then test released expansions with each individual flag toggled.

---

# 74. Tests — unusual policy combinations

Explicitly test combinations such as:

```text
tradeable YES
craftable NO
```

```text
availableInPacks NO
craftable YES
```

```text
standard NO
availableInPacks YES
```

```text
duplicateProtection YES
tradeable YES
```

```text
craftable YES
disenchantable NO
```

The engine must not assume common lifecycle combinations.

---

# 75. Tests — crafting

Test:

```text
Common costs 5

Rare costs 20

Epic costs 100

Legendary costs 300

craft deducts Fragments

craft grants correct quantity

insufficient balance rejects

non-craftable expansion rejects

unreleased expansion rejects

failed craft changes nothing

simultaneous overspending cannot occur

retry/idempotency does not double craft
```

---

# 76. Tests — disenchanting

Test:

```text
Common gives 1

Rare gives 5

Epic gives 20

Legendary gives 100

owned quantity decreases

Fragments increase

cannot disenchant more than owned

non-disenchantable expansion rejects

unreleased expansion rejects

failure is atomic

disenchanting deck card may make deck invalid
```

---

# 77. Tests — duplicate protection

Test separately for every rarity.

Examples:

```text
0/2 card is eligible

1/2 card is eligible

2/2 card is protected
```

Legendary:

```text
0/1 eligible
1/1 protected
```

Test fallback:

```text
All cards complete
→ duplicates become possible again
```

---

# 78. Tests — ownership manipulation

This behavior is intentional and needs explicit regression tests.

Example:

```text
Own Epic A ×2.
Epic A is protected.

Trade one away.

Own Epic A ×1.
Epic A becomes eligible.
```

Also:

```text
Own Epic A ×2.

Disenchant one.

Epic A becomes eligible.
```

And:

```text
Own Epic A ×1.

Craft second copy.

Epic A becomes protected.
```

Do not allow future developers to "fix" this behavior accidentally.

---

# 79. Tests — duplicate protection disabled

If protection is false:

```text
Own Wolf ×10
```

Wolf remains fully eligible in pack generation.

Ownership must not alter selection weights merely because of copy count.

---

# 80. Tests — pack availability

Test:

```text
released + availableInPacks
→ pack opens
```

```text
released + unavailable
→ rejected
```

```text
unreleased + availableInPacks
→ rejected
```

Also test that Standard status does not influence pack eligibility.

---

# 81. Tests — trading

Test:

```text
two-sided trade succeeds

one-sided gift succeeds

multiple-card trade succeeds

Fragments cannot be offered

tradeable expansion succeeds

non-tradeable expansion rejects

unreleased expansion rejects

unequal rarity/value trade succeeds
```

No fairness restrictions.

---

# 82. Tests — trade confirmation

Test:

```text
A confirms
B confirms
→ trade executes
```

```text
A confirms
offer changes
→ A confirmation resets
```

```text
both confirmed old revision
new revision exists
→ trade does not execute
```

---

# 83. Tests — policy changes during trade

Test:

```text
Create valid trade.

Both cards initially tradeable.

Before final execution:
set expansion.tradeable = false.

Execution rejected.
```

No cards move.

---

# 84. Tests — ownership changes during trade

Test:

```text
Player offers Legendary.

Before completion:
disenchants Legendary.

Trade finalization rejects.
```

And:

```text
Two simultaneous trades offer same Legendary.

Only one may commit successfully.
```

---

# 85. Tests — Standard/Wild

Test:

```text
released + standard
→ Standard legal
→ Wild legal
```

```text
released + !standard
→ Standard illegal
→ Wild legal
```

```text
!released + standard
→ Standard illegal
→ Wild illegal
```

Rotation:

```text
standard true → false
```

should invalidate relevant Standard decks without deleting them.

---

# 86. Tests — trade effects on duplicate protection

Test end-to-end:

```text
Player owns 2/2 copies.
Protection excludes card.

Player trades one away.

Collection becomes 1/2.

Next protected pack may contain card.
```

This is a core intended mechanic.

---

# 87. Tests — crafting effects on duplicate protection

Test:

```text
Player owns 1/2.

Card is eligible.

Player crafts second.

Card becomes protected.
```

---

# 88. Tests — disenchant effects on duplicate protection

Test:

```text
Player owns 2/2.

Card protected.

Player disenchants one.

Card becomes eligible.
```

---

# 89. API / command layer

Exact names should follow current conventions, but expected operations include equivalents to:

```text
GET_EXPANSIONS

GET_COLLECTION

CRAFT_CARD

DISENCHANT_CARD

DISENCHANT_EXTRAS

OPEN_PACK

CREATE_TRADE

UPDATE_TRADE_OFFER

ACCEPT_TRADE

CANCEL_TRADE

GET_TRADE_HISTORY
```

All mutating operations must be server authoritative.

---

# 90. Protocol/API responses

For economy failures, return structured reasons when practical.

Examples:

```text
EXPANSION_NOT_RELEASED

CARD_NOT_CRAFTABLE

CARD_NOT_DISENCHANTABLE

CARD_NOT_TRADEABLE

EXPANSION_NOT_AVAILABLE_IN_PACKS

INSUFFICIENT_FRAGMENTS

INSUFFICIENT_CARD_QUANTITY

TRADE_REVISION_CHANGED

TRADE_POLICY_CHANGED

DECK_NOT_STANDARD_LEGAL
```

This makes Godot/web UI explanations straightforward.

---

# 91. Godot/client responsibilities

The client may:

- display balances
- display policies
- send crafting requests
- send disenchant requests
- construct trade offers
- display pack results
- show deck legality
- filter Standard/Wild

The client must not authoritatively decide:

- whether crafting is allowed
- whether a card is tradeable
- whether duplicate protection applies
- what card a pack generates
- whether a deck is legal
- whether trade execution succeeds

Server is authoritative.

---

# 92. Future web-client compatibility

All economy APIs and DTOs must remain client-agnostic.

Do not expose Godot-specific types.

A future React client should be able to use the same:

```text
collection
crafting
trading
packs
expansions
```

APIs.

---

# 93. Implementation phases

## Phase 1 — Inspect current systems

Before coding, map:

- card rarity model
- expansion/set model
- collection persistence
- deck ownership validation
- pack implementation
- user economy
- API layer
- admin system

Produce a concise change map.

---

## Phase 2 — Expansion policies

Add:

```text
released
tradeable
duplicateProtection
craftable
disenchantable
availableInPacks
standard
```

Add centralized policy helpers.

Add tests.

Do not build crafting/trading until policy evaluation is stable.

---

## Phase 3 — Standard/Wild

Implement:

```text
DeckFormat
Standard validation
Wild validation
rotation behavior
```

Update deck APIs/UI as necessary.

---

## Phase 4 — Fragment economy

Add:

```text
fragment balance
central rarity values
economy transactions
```

Implement transactional balance modifications.

---

## Phase 5 — Crafting

Implement:

```text
CRAFT_CARD
policy validation
fragment deduction
collection increment
audit logging
idempotency
```

Add tests.

---

## Phase 6 — Disenchanting

Implement:

```text
DISENCHANT_CARD
DISENCHANT_EXTRAS
collection decrement
Fragment reward
policy validation
```

Add tests.

---

## Phase 7 — Pack policy integration

Update pack generation for:

```text
released
availableInPacks
duplicateProtection
```

Duplicate protection must use current ownership only.

Add manipulation tests.

---

## Phase 8 — Trading persistence

Create:

```text
Trade
TradeOffer
TradeItems
TradeStatus
revision/confirmation model
trade history
```

No client polish yet.

---

## Phase 9 — Trading execution

Implement:

```text
create
edit
accept
cancel
atomic execution
current policy revalidation
ownership revalidation
concurrency safety
```

Add full tests.

---

## Phase 10 — Client interfaces

Update Godot/current client for:

```text
Fragments
craft
disenchant
expansion policies
Standard/Wild
trade creation
trade acceptance
trade history
pack policy messaging
```

Keep presentation functional before polishing.

---

## Phase 11 — Admin controls

Allow authorized admin/DM control of expansion policies.

At minimum support changing:

```text
released
tradeable
duplicateProtection
craftable
disenchantable
availableInPacks
standard
```

Ensure policy changes immediately affect subsequent server validation.

---

## Phase 12 — End-to-end validation

Test realistic lifecycle:

```text
Create unreleased expansion.

Add cards.

Release expansion.

Trading ON.
Duplicate protection OFF.
Crafting OFF.
Packs ON.
Standard ON.

Players open packs and trade.

Enable crafting.

Release next expansion.

Turn old expansion:
Trading OFF.
Duplicate protection ON.

Players manipulate collection by trading/disenchanting before policy switch where applicable.

Rotate old expansion:
Standard OFF.

Later archive:
Packs OFF.

Cards remain usable in Wild and craftable.
```

Verify every stage without data migration.

---

# 94. Non-goals

Do not implement as part of this task:

```text
auction house

player marketplace

real-money trading

Fragment trading

gold/coins

pack purchasing with real money

trade value enforcement

trade taxes

card lending

temporary trades

unique serial numbers for cards

foil card economy

cosmetic card trading

blockchain/NFT ownership

automatic expansion rotation dates

scheduled releases

ranked rewards

battle passes
```

These may be considered separately later.

---

# 95. Acceptance criteria

This feature is complete when:

1. Every collectible card belongs to an expansion.

2. Expansions expose:

```text
Released
Tradeable
Duplicate Protection
Craftable
Disenchantable
Available in Packs
Standard
```

3. `released = false` hides and disables normal player use of the expansion.

4. Policy flags operate independently.

5. Fragments exist as a single integer crafting currency.

6. Craft costs are:

```text
Common       5
Rare         20
Epic         100
Legendary    300
```

7. Disenchant values are:

```text
Common       1
Rare         5
Epic         20
Legendary    100
```

8. Crafting respects `released` and `craftable`.

9. Disenchanting respects `released` and `disenchantable`.

10. Packs respect `released` and `availableInPacks`.

11. Duplicate protection respects the expansion flag.

12. Duplicate protection considers only current ownership.

13. Trading/disenchanting cards can intentionally make them eligible again.

14. Crafting cards can intentionally remove them from the protected pool.

15. No historical collection state is used for duplicate protection.

16. Cards can be traded only while their expansion is currently tradeable.

17. Trades support multiple cards per side.

18. One-sided gifts are legal.

19. Fragments cannot be traded.

20. Both players must confirm the same exact trade revision.

21. Offer modification resets confirmation.

22. Trade execution revalidates current policies.

23. Trade execution revalidates current ownership.

24. Trades execute atomically.

25. Concurrent trades cannot duplicate cards.

26. Completed trades remain valid after later policy changes.

27. Standard allows only cards from released Standard expansions.

28. Wild allows cards from all released expansions.

29. Rotating an expansion out of Standard does not delete decks.

30. Such decks become invalid for Standard but remain usable/editable for Wild.

31. Standard status does not determine pack availability.

32. Pack availability does not determine crafting.

33. Craftability does not determine tradeability.

34. Disenchantability does not determine crafting.

35. Unusual policy combinations work correctly.

36. Economy operations are idempotent or otherwise safe against request retries.

37. All balance/card transfers are transactional.

38. Economy actions have sufficient audit history for debugging.

39. Godot/current clients remain non-authoritative.

40. The APIs remain usable by a future web client.

---

# 96. Final instruction to the coding agent

Treat this as an addition to the current Maailma TCG architecture, not a greenfield rewrite.

First inspect the repository.

Before implementation, produce a concise map of:

```text
existing modules to modify
new domain types
database migrations
pack-generation changes
deck-validator changes
API commands/routes
trade persistence
economy transaction handling
client scenes/scripts
tests to add
```

Then implement in the phase order above.

After each major phase:

```text
run existing tests
run new tests
fix regressions
continue
```

Do not introduce historical “seen card” tracking for duplicate protection.

The intended behavior is explicitly:

```text
What I own RIGHT NOW determines duplicate protection.
```

Players being able to manipulate those odds through crafting, disenchanting, and trading is a feature, not an exploit.