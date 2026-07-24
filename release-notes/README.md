# Bundled release notes

## `agent/` — the agent-restart dialog

`agent/<version>.json` is the offline "What's new" shown in Ghoztty's
agent-restart dialog ("Restart the Ghoztty background terminal process?"). That
dialog asks the user to reset their live terminal sessions, so its notes must be
**scoped to session-persistence / background-agent changes only** — the reasons
a user would actually restart the agent. Do **not** put viewer, banner, or other
client/UI features here (those are already live regardless of the restart).

Files are keyed by the app's `CFBundleShortVersionString` (bare semver, no
leading `v`) and bundled into the app via `src/build/GhosttyResources.zig` →
`Contents/Resources/ghostty/release-notes/agent/`. Only versions whose agent
actually changed need a file — the dialog only appears when the agent is stale,
so there is normally a matching file.

Shape:

```json
{
  "version": "1.17.0",
  "sections": [
    { "title": "Session persistence",
      "items": [
        { "title": "Seamless agent upgrades", "text": "What the user gains, in plain language." },
        { "text": "A plain note with no bold lead." }
      ] }
  ]
}
```

- `title` on an item is the bold lead of a `- **Title** — text` bullet; omit it
  for a plain bullet. `text` may contain inline markdown (bold, italic,
  `` `code` ``, links) — it is rendered natively.
- Add a new `agent/<version>.json` as part of a release that changes the agent
  (see `.claude/commands/release.md`, Step 2), **before** tagging, so it ships in
  the build.

## `client/` — the app "What's new"

`client/<version>.json` is the client/app-scoped "What's new" (app, UI, viewer,
banner changes — everything a user sees that is NOT session-persistence/agent).
Same JSON shape as `agent/`. It ships **two ways**:

1. **Bundled offline** into the app (`src/build/GhosttyResources.zig` →
   `Contents/Resources/ghostty/release-notes/client/`) and shown in the
   **"What's New in Ghoztty…"** menu window (Client tab).
2. **Embedded in the Sparkle appcast** `<description>` by
   `.github/workflows/release.yml` at release time, so the **pre-update dialog**
   on the update chip can render the OFFERED version's notes before the user
   updates (the running old app can't have the new version's notes bundled —
   they travel over the network).

Author `client/<version>.json` before tagging a release (see
`.claude/commands/release.md`, Step 2). Exclude agent/session items — those live
under `agent/`.

## `scripts/backfill-release-notes.py`

Fetches historical GitHub release bodies as **general drafts** to curate from —
it does not itself know the agent/client split, so review each draft and keep
only the relevant items for the target scope before committing.
