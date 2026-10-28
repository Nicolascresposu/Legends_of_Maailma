# Publish and test cards without restarting

Local development servers enable publishing by default. Start or restart `npm run dev` once after
installing this feature, then open **Admin → Expansions** in Godot.

1. Edit an expansion. **Save** keeps its JSON in the repository for Git review; a draft can also
   be published before saving.
2. Click **Preview publish…**. The server validates the proposed catalogue, checks IDs and
   references, and checks that starter decks and scenarios name cards that exist. The review names the target
   server and old/new version IDs. Every added, changed or removed definition has before/after
   data. Preview does not activate anything.
3. Confirm **Publish version**. The server persists a snapshot and activates it immediately.
   If the server or draft changed since preview, preview again. The publishing client's
   collection, packs and admin card pickers refresh automatically.
4. Start a **new** match to test the new rules. For quick card development, start a fresh
   Bandit Ambush debug match from the admin Accounts tab, then add the card to your hand with
   the match's admin tools. This also works with unreleased cards, without crafting or ownership.

Existing matches, including waiting PvP matches, retain their original definitions. Their AI,
card previews and rules continue using that version after publication or rollback. Replays
exported through `GET /api/matches/:id/replay` embed used card definitions and the version ID.
Admin-edited matches cannot be replayed from their action logs alone.

**Server versions…** shows activation history with the acting admin and timestamp. Select a
version, click **Preview rollback…**, review the changes and confirm **Roll back server**. A
rollback restores that whole catalogue snapshot and records a new activation. Existing matches
keep their versions. The same window can **Open server draft** for an expansion, loading the
active server document as an unsaved local draft.

Save/import/export operate on local JSON files; publishing and rollback operate on the server.
Publishing leaves source JSON unchanged. Expansion IDs identify replacement targets, so keep
existing IDs stable. Starter decks and scenarios publish with their expansion, so a new starter
deck applies to accounts created afterwards. New effect mechanics, heroes and classes remain code
changes. Live database policy overrides still take precedence over default flags.

## Persistence and configuration

The development store defaults to `.maailma-content/` at the repository root (git-ignored):

```text
.maailma-content/
  state.json             # active version and activation history
  versions/<hash>.json   # immutable, validated catalogue snapshots
```

A server restart restores the active published version. Source JSON initializes the registry
when no publication state exists. Once a publication exists, changing source JSON and restarting
does not replace the published version: publish that saved draft through the creator. To return
to source JSON during development, stop the server, move the store aside as a backup and restart.
Snapshots published before starter decks and scenarios became content have neither, so a server
refuses to start from one; move that store aside the same way.

`CONTENT_STORE_DIR` selects a writable store. `CONTENT_PUBLISHING=false` disables edits while
retaining a previously published version. Outside production publishing defaults on; with
`NODE_ENV=production`, explicitly set `CONTENT_PUBLISHING=true` to enable it. Docker Compose
defaults to false and persists snapshots in `content-data`, owned by the server's `node` user.
One server process owns a publication store.

Each publication stores immutable snapshots before atomically replacing the activation pointer.
A failed write leaves active content unchanged. Stored snapshots are validated and checked
against their hashes when restored. These snapshots version card content; engine code is deployed
normally. All operations require an authenticated admin; server/account switches invalidate
pending reviews.

## API and verification

All paths below are relative to `/api/admin/content` and require bearer-token admin access.
Non-admins receive 404. A document is `{ expansion, cards, packs, starterDecks, scenarios }`,
matching the local files; the last two may be omitted.

| Method | Path                         | Purpose                                                                   |
| ------ | ---------------------------- | ------------------------------------------------------------------------- |
| GET    | `/`                          | Enabled state, current version, activation history and expansion list     |
| GET    | `/expansions/:id`            | Active expansion document with default policies                           |
| POST   | `/preview`                   | Validate `{ document }`; return base/candidate versions and exact changes |
| POST   | `/publish`                   | Activate `{ document, baseVersion, candidateVersion }`                    |
| GET    | `/versions/:version/preview` | Preview a whole-catalogue rollback                                        |
| POST   | `/rollback`                  | Activate `{ version, baseVersion, candidateVersion }`                     |

Content uploads accept up to 2 MB; other HTTP routes retain the 64 KB limit. Invalid content
returns `422 INVALID_CONTENT`; stale/altered reviews return `409 CONTENT_CONFLICT` or
`CONTENT_PREVIEW_CHANGED`. Disabled publication returns `403 CONTENT_PUBLISHING_DISABLED`.

```sh
npx vitest run tests/content-publishing.test.ts tests/content-publishing-live.test.ts
godot --headless --path apps/godot-client --script src/content_publisher_test.gd
```

The live test uses a temporary local server, store and test admin. The Godot publisher test uses
a fake transport and makes no requests to a real server.
