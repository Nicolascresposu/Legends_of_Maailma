# Creating expansion content

Expansion metadata, cards, packs, starter decks and scenarios live in JSON under
`packages/card-definitions/content/`:

```text
content/
  core/
    expansion.json
    cards.json
    packs.json
    starterDecks.json
    scenarios.json
  chronicle/
    expansion.json
    cards.json
    packs.json
  machines-of-kona/
    expansion.json
    cards.json
    packs.json
```

Every immediate, non-hidden directory is an expansion. Add a directory with these three files;
there is no TypeScript import list or manifest to update. Folder names are organizational, while
the IDs inside the files identify content. IDs must be unique across all expansions. Keep a card
and its pack definitions in the folder whose `expansion.json` has their `expansionId`.

`cards.json` and `packs.json` are arrays. Either can be `[]` for unfinished content or a set that
has no packs. JSON requires double quotes and does not support comments or trailing commas.

`starterDecks.json` and `scenarios.json` are optional arrays; a folder without them has none. Core
ships both. Every class needs exactly one starter deck across all expansions: it is what a new
account is given and what a side plays when it brings no deck. Each lists cards by ID with a
number of copies, and every card must exist, be collectible and fit the deck's class. A scenario
names a Hero for each side and the cards that side starts with, each of which must exist and be of
the right type. Heroes and classes are still defined in TypeScript.

## Godot expansion creator

Sign in as an admin, enable **Admin UI**, open the admin panel from the collection screen, and
select **Expansions**. The creator edits local files on the machine running Godot.

1. Choose **Open content folder…** and select `packages/card-definitions/content`, or enter its
   absolute path and click **Load path**. In a repository checkout this is the default; the last
   opened location is remembered. Desktop builds can select an external content folder.
2. Select an existing expansion or click **New expansion**. The **Expansion** tab edits its stable
   ID, display name and default policy flags. New expansions start unreleased. The folder field
   chooses the destination for a new expansion; existing expansion folders keep their names.
3. Use **Cards** to add, duplicate or remove cards. The type picker supports Creatures, Actions,
   Artifacts, Weapons and Locations. Edit stats, rarity, class, keywords, descriptions and effects through
   the form. The preview uses the same frames and artwork as the game, with its own draft library.
   **Choose art…** under the preview picks an image (PNG, WebP, JPEG or SVG) as the card's art and
   **Remove art** clears it. The change shows in the preview at once and is written on **Save**,
   which copies the image to `apps/godot-client/art/cards/<expansion_folder>/<card_id>.<ext>`
   (for example `art/cards/core/chicken.png`). Drag the art in the preview to choose which part of
   it shows, and scroll or use **Zoom** to zoom in; **Reset** fits the whole picture again. The
   framing is saved beside the image as `<card_id>.crop.json`, leaving the image itself whole, so
   it can be reframed later. Renaming a card's ID moves its art and framing to the new ID on Save,
   and **Duplicate** gives the copy the same picture and framing.
   Expansion assignments follow the expansion ID automatically. Leave Class ID off for neutral
   cards, and use **Add entry** to add tags, keywords or effects.
4. Use **Packs** to edit pack IDs, sizes, slot counts and rarity weights. Optional checkboxes turn
   individual weighted rarities on or off. Effects and pack rules have structured nested forms;
   no JSON syntax is needed in the UI. **Starter decks** and **Scenarios** edit those files the
   same way; most expansions leave them empty.
5. Click **Validate**, then **Save**. Validation checks the draft against the other expansion
   folders, including duplicate IDs and cross-expansion summon references. Select a validation
   issue to open its card or pack. Save writes the expansion's JSON files in the selected
   content root. Unchanged files retain their bytes, so editing metadata does not reformat cards.

Changing a card's ID renames the card. On Save the creator finds everything that refers to the old
ID in every expansion folder: SUMMON effects, starter decks, and what scenarios start with. It
lists them and asks before saving, then rewrites them all to the new ID. Everything is validated
before anything is written. Saved decks and collections already on a server still use the old
ID; see [When cards change](../README.md#when-cards-change).

Edits stay in memory until Save. Changing expansions, opening another root, importing a draft or
using the admin panel's Back button prompts before discarding unsaved work. Discard restores the
saved draft. If files have changed outside the creator, Save refuses the stale write: reopen
the expansion (or use Load path) to read those changes first.

**Import expansion…** reads a folder containing `expansion.json`, `cards.json` and `packs.json`
as an unsaved draft. It does not copy files into the content root until Save. If the chosen
destination already contains expansion files, an explicit replacement dialog names that folder.
The creator also checks for external edits between that dialog and the confirmed write.

**Export expansion…** writes those same three files into the expansion folder you choose. You
can create a destination folder in the directory picker. Existing expansion files require
confirmation before replacement. Exporting elsewhere keeps changes to the original source
marked unsaved. Exporting inside the active content root checks for ID collisions there too.

Writes stage changed files before replacing originals, retain backups through the operation,
and roll back earlier replacements if a later replacement fails. No expansion folders or
unrelated assets are deleted. Saved JSON appears in Git for normal review and deployment.

Saving changes local JSON. Use **Preview publish… → Publish version** to apply a reviewed draft
to the running server, then start a new match to test it. See [Publishing](publishing.md) for the
fast development workflow, rollback and persistence. Live database policy overrides still apply.
Artwork remains a client asset in `art/cards/`: Save writes it there, but publishing does not
upload it, so commit new art files alongside the JSON.

The forms and validation use a generated copy of the server's content schema and class IDs in
`apps/godot-client/src/content_schema.gd`. It is regenerated by `npm run build`, or explicitly by
`npm run sync:content-schema` after changing the canonical schema. The generated GDScript travels
with desktop exports. Once the admin panel is open, local editing and validation run entirely
in Godot. The separate publishing panel uses the connected server's authenticated admin API.

The authoring test runs without a server and writes only to a temporary user-data directory:

```sh
godot --headless --path apps/godot-client --script src/expansion_creator_test.gd
```

Run without `--headless` and add `-- --screenshot-dir=<existing-directory>` for visual previews.

## Expansion metadata

For example, create `content/frozen-frontier/expansion.json`:

```json
{
  "schemaVersion": 1,
  "id": "FROZEN_FRONTIER",
  "name": "Frozen Frontier",
  "policy": {
    "released": false,
    "tradeable": true,
    "duplicateProtection": false,
    "craftable": true,
    "disenchantable": true,
    "availableInPacks": true,
    "standard": true
  }
}
```

All seven policy flags must be explicit booleans. `released: false` hides the expansion from
players and gates the other flags. `standard: false` rotates a released set out of Standard while
leaving it playable in Wild. The version is the content format version, currently `1`.

These policies are shipped defaults. Existing database overrides still take precedence; changing
JSON will not replace an override. Admin endpoints can change flags or clear the override.

## Cards

Create `cards.json`, for example:

```json
[
  {
    "id": "frost_wolf",
    "name": "Frost Wolf",
    "type": "CREATURE",
    "cost": 2,
    "attack": 3,
    "health": 2,
    "tags": ["BEAST"],
    "keywords": [],
    "effects": [],
    "source": "CORE",
    "expansionId": "FROZEN_FRONTIER",
    "rarity": "COMMON",
    "collectible": true,
    "description": "No special abilities.",
    "flavour": "Its tracks disappear beneath the snow.",
    "artist": "Aino Virtanen"
  }
]
```

Copy an existing card of the desired type to get its full structure. Supported types are
`CREATURE`, `ACTION`, `ARTIFACT`, `WEAPON` and `LOCATION`. Fields such as `keywords`, `tags` and `effects`
must be present when required by the card type, even when empty. Omit `classId` for a neutral
card; existing class IDs are `PRIEST` and `WIZARD`. `flavour` is optional, and so is `artist`,
plain text crediting whoever made the card's art, shown as "Art: …" under the flavour.

`source` is the existing category (`CORE` or `CHRONICLE`), separate from `expansionId`.
Adding an expansion does not require adding a source category. Rarities are `BASIC`, `COMMON`,
`RARE`, `EPIC` and `LEGENDARY`. Basic cards are outside the crafting/trading/pack economy.

Descriptions are presentation text, not executable rules. Keywords must be printed in `**bold**`;
a card with no keywords and no rules text may leave its description blank (`""`).
Encode mechanics in the relevant fields as well. Creatures, Artifacts and Weapons use triggered
effects, for example:

```json
{
  "trigger": "ARRIVAL",
  "effect": { "type": "HEAL", "amount": 3, "target": "OWNER_HERO" }
}
```

Actions instead use effects directly, without the trigger wrapper, and require `targetMode`.

A Location has a `durability`, a `duration`, or both. `durability` is how many times it can be
activated, and requires an `activation` — what one use does, written like an Action: a
`targetMode` and a list of `effects`. `duration` is how many of its owner's turns it stands.
A Location's own `effects` may only trigger on `TURN_STARTED`, `TURN_ENDED`,
`FRIENDLY_CREATURE_SUMMONED` or `FRIENDLY_CREATURE_DIED`. For example:

```json
{
  "id": "war_camp",
  "type": "LOCATION",
  "durability": 2,
  "duration": 3,
  "activation": {
    "targetMode": "NONE",
    "effects": [
      { "type": "BUFF", "attack": 1, "health": 1, "target": "ADJACENT_FRIENDLY_CREATURES" }
    ]
  },
  "effects": []
}
```

The description says what an activation does; the hourglass and shield print the two measures.
Supported effects are `DEAL_DAMAGE`, `HEAL`, `DRAW_CARD`, `BUFF`, `APPLY_STATUS`, `SUMMON`,
`SUMMON_RANDOM`, `MOVE`, `DESTROY` and `GAIN_TAIKA`. A `SUMMON` must reference an existing
Creature, including one in another expansion. New mechanics require an engine implementation and
schema update.

### Tags in rules (tribes)

A Creature's `tags` are free-form — kin (`BEAST`, `ELF`), trade (`MECHANIC`), allegiance
(`REBEL`) — and rules can ask for them by a `tag` field, matched exactly. Weapons carry tags too,
so a cost aura can name `BOW`. Validation rejects a `tag` that no card in any expansion carries,
which is nearly always a typo.

| Pattern                                    | How to write it                                                                                                      |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| "Give your Beasts +1/+1"                   | `{ "type": "BUFF", "attack": 1, "health": 1, "target": "ALL_FRIENDLY_CREATURES", "tag": "BEAST" }`                   |
| "Give a friendly Beast +2/+2" (Action)     | `"targetMode": "FRIENDLY_CREATURE", "targetTag": "BEAST"` and an effect aimed at `PLAY_TARGET`                       |
| "**Arrival:** Give a friendly Beast +2/+2" | An `ARRIVAL` effect aimed at `PLAY_TARGET` with `"tag": "BEAST"`                                                     |
| "Summon a random Beast"                    | `{ "type": "SUMMON_RANDOM", "tag": "BEAST" }`                                                                        |
| "If you control another Beast, …"          | `"condition": { "type": "CONTROLS_CREATURE", "tag": "BEAST" }` on any effect                                         |
| "If you're holding a Dragon, …"            | `"condition": { "type": "HOLDS_CARD", "tag": "DRAGON" }`                                                             |
| "Whenever you summon a Beast, give it +1"  | trigger `FRIENDLY_CREATURE_SUMMONED`, `"tag": "BEAST"`, target `TRIGGERING_CREATURE`                                 |
| "Whenever a friendly Beast dies, …"        | trigger `FRIENDLY_CREATURE_DIED`, `"tag": "BEAST"`                                                                   |
| "Your other Beasts have +1/+1"             | `"auras": [{ "type": "STAT_AURA", "attack": 1, "health": 1, "target": "OTHER_FRIENDLY_CREATURES", "tag": "BEAST" }]` |
| "Your Beasts cost 1 less"                  | `"auras": [{ "type": "COST_AURA", "amount": -1, "tag": "BEAST" }]`                                                   |

A `tag` on an effect narrows whatever its `target` reaches to Creatures carrying the tag; a
random target picks only among those. New targets `ALL_FRIENDLY_CREATURES`,
`OTHER_FRIENDLY_CREATURES` and `RANDOM_OTHER_FRIENDLY_CREATURE` work with or without a tag.
A targeted Arrival with no legal target still lets the Creature be played; a targeted Action with
none stays in hand. Conditions are checked as the effect resolves and never count the effect's
own source. Arrival fires only when the Creature is played from hand, never when a `SUMMON` or
`SUMMON_RANDOM` puts it on the battlefield. The `FRIENDLY_CREATURE_*` triggers answer other
Creatures on the same side, however they arrived, after that Creature's own Arrival or Last Breath.

`auras` (Creatures, Artifacts, Locations) hold only while their source is on the battlefield.
Losing a Health aura lowers maximum Health but never kills. A `COST_AURA` changes cards in its
owner's hand, never below 0, and may also name a `cardType`.

`SUMMON_RANDOM` draws from the collectible Creatures in the match's random pool, which the server
fixes when the match is created: the cards of released expansions, by live policy. An unreleased
set's cards are never drawn in a player's match, so a random summon cannot reveal them. Admin
debug matches draw from every expansion, so an unreleased set's random effects can be tried
before launch.

A card's tags print along the bottom of its text box, one line, so players can see what each
card counts as. Weapons print no tags, and single tags can be left off every card too, through
`UNPRINTED_TAG_TYPES` and `UNPRINTED_TAGS` in `apps/godot-client/src/card_library.gd`. Unprinted
tags still count for rules, and the hover reveal still lists them.

Artwork is a separate Godot asset: `apps/godot-client/art/cards/<expansion_folder>/<card_id>.png`
(WebP, JPEG and SVG are also supported; art directly in `art/cards/` is still found). Content files do not bundle or upload artwork; the creator's **Choose art…**
copies an image into place for you. An optional `<card_id>.crop.json` beside it,
`{"crop": [x, y, width, height]}` as fractions of the image, is the part of the picture the game
shows wherever the card is drawn.

## Packs

Create `packs.json`, for example:

```json
[
  {
    "id": "FROZEN_FRONTIER_PACK",
    "name": "Frozen Frontier Pack",
    "expansionId": "FROZEN_FRONTIER",
    "cardCount": 5,
    "rarityRules": {
      "slots": [
        { "count": 4, "weights": { "COMMON": 70, "RARE": 23, "EPIC": 6, "LEGENDARY": 1 } },
        { "count": 1, "weights": { "RARE": 80, "EPIC": 17, "LEGENDARY": 3 } }
      ]
    }
  }
]
```

Slot counts must total `cardCount`; counts and weights must be positive. Weights are relative,
not percentages, and cannot include Basic cards. The pool is automatically the expansion's
collectible, non-Basic cards. Rarities absent from the pool are skipped; if none of a slot's
weighted rarities exist, the existing generator falls back to available rarities. A pack needs
at least one eligible card to open successfully. A guaranteed non-Common slot therefore also
requires non-Common cards in the set.

## Validate and apply

From the repository root, run:

```sh
npm run validate:content
npm run build
npm test
```

The standalone validation command needs no database. It checks file shapes, supported enums and
effects, required fields, numeric constraints, duplicate IDs, expansion/class/summon references,
description markup and pack totals. Errors identify the file and relevant field or card ID.
The machine-readable format is defined by `packages/card-definitions/content.schema.json`.
`npm run build` also validates content, so invalid JSON cannot pass the normal build.
The full test suite requires the project's PostgreSQL database.

Use **Preview publish… → Publish version** for the fast development loop. Source JSON is also
loaded at startup when no publication store is active; restarting the server and reconnecting
applies source edits in that configuration. A persisted published version takes precedence over
source JSON on restart; see [Publishing](publishing.md#persistence-and-configuration).
Docker images include the JSON and schema alongside compiled code. Commit the content with the
rest of the project and deploy it through the usual workflow. No database migration or content
seeding is needed for a new expansion.

Prefer keeping card IDs stable: collections and decks on a server store those IDs, and a rename
in the creator updates content only. Never reuse an old ID for a different card. Heroes, classes
and crafting prices remain in the TypeScript modules in `packages/card-definitions/src/`.
