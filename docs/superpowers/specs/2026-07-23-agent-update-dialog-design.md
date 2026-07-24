# Agent-restart upgrade dialog: clearer copy + bundled "What's new"

## Problem

After an app upgrade, a newer `ghoztty-agent` is bundled than the one still
running (which holds live terminal PTYs). When there are live sessions, the app
shows a mandatory confirmation before the destructive agent restart
(`LocalAgentManager.promptAndRefreshLocalAgent`). Two shortcomings:

1. **The copy is jargon.** It talks about "the background terminal agent," which
   does not map to the user's mental model or tell them why they'd care.
2. **No context to decide.** The user is asked to reset live sessions with no
   information about what the update actually gives them, so there is no basis to
   choose "Update Now" over "Later."

This is part of the mandatory agent-update UX (CLAUDE.md, "Agent contract &
upgrade compatibility"). The change must **not** weaken the "never silently
reset live sessions" guarantee: the confirmation stays mandatory, the idle path
stays silent, and buttons still gate the destructive refresh.

## Goals

- Reframe the dialog copy around the user's mental model, accurately.
- Add a "What's new" section listing release notes accrued since the version the
  user last ran, so they can judge whether the update is worth resetting
  sessions — rendered **fully offline** from notes **bundled in the app**.
- Backfill the bundled notes from existing releases so the feature has real
  content on first ship.

## Non-goals

- No "What's new" UI on the **idle silent-upgrade** path (nothing to decide
  there; it stays a log-only notice). Out of scope, confirmed.
- No change to the staleness detection, the HELLO handshake, the reconnect/
  relaunch mechanics, or the button gating semantics.
- No networked notes fetch. Notes are bundled and rendered offline.

## Where this lives

- Dialog: `macos/Sources/Features/Remote/LocalAgentManager.swift`,
  `promptAndRefreshLocalAgent(liveSessionCount:running:bundled:)` (~784).
- Trigger: `refreshLocalAgentIfStale` (~736); call sites
  `SessionLayoutRestore.swift:138` and `BaseTerminalController.swift:2145`.
- App version at runtime: `CFBundleShortVersionString`
  (`Bundle.main.infoDictionary`). Confirmed valid for release builds — the
  release workflow passes `-Dversion-string="$VERSION"` (from the git tag),
  which overrides the `build.zig.zon` default (`1.4.0`) and flows through
  `MARKETING_VERSION`. Local/dev builds report the `1.4.0` default, which is fine
  for testing.
- Resource bundling: `src/build/GhosttyResources.zig` (mirror the `src/viewer`
  `addInstallDirectory` step).

## Design

### 1. Copy (reframed)

- **Title (`messageText`):** `Restart to finish updating Ghoztty?`
- **Subtext (`informativeText`):**
  `Ghoztty keeps your terminal sessions running in the background. Finishing
  this update restarts that background process, which will close your N open
  terminal session(s) — they can't be carried across the update. You can keep
  working instead: Ghoztty updates automatically the next time no sessions are
  open.`
  - `N` uses the existing singular/plural handling.
- **Buttons:** unchanged — `Update Now` (default) / `Later`, style `.warning`.
- No "Ghostty" (no Z) spelling in any new user-visible string.

### 2. Bundled notes: format & location

- **Location:** `release-notes/<version>.json` at repo root, one file per
  release (e.g. `release-notes/1.26.0.json`). Discrete files → trivial
  enumeration, no runtime range-parsing.
- **Shape:**
  ```json
  {
    "version": "1.26.0",
    "sections": [
      {
        "title": "Fork Changes",
        "items": [
          { "title": "Viewer popups open as real windows", "text": "Links that open in a new window now open as their own proper window…" },
          { "text": "A plain bullet with no bold prefix is stored as text only." }
        ]
      }
    ]
  }
  ```
  - Each item is `{ "title"?: String, "text": String }`. `title` is the bold
    lead of a `- **Title** — text` bullet; a bullet without that pattern stores
    the whole line as `text`. This means **no inline-markdown parsing at render
    time**.
- **Bundling:** add one `addInstallDirectory` step in
  `src/build/GhosttyResources.zig` pointing at `release-notes/`, installed under
  the bundle Resources. Read at runtime via `Bundle.main.url(forResource:…)` /
  the resource directory.
- **Version-string keys:** JSON `version` and filenames use the bare semver
  (`1.26.0`), matching `CFBundleShortVersionString` (no `v` prefix).

### 3. Backfill (one-time)

- A one-time script committed under `scripts/` (`backfill-release-notes.py`,
  matching the Python precedent of `dist/macos/update_appcast_tag.py`)
  enumerates releases via `gh release list`, fetches each body with
  `gh release view vX.Y.Z --json body`, then:
  1. Drops the `## What's new …` title line.
  2. Cuts everything from the first `---` **or** `### Installation` (whichever
     comes first) — the install/requirements boilerplate.
  3. Parses `### <Section>` headers and `- **Title** — text` / `- text` bullets
     into `sections`/`items`.
  4. Writes `release-notes/<semver>.json` (strip the leading `v`).
- Backfill range: **v1.4.0 → current** (skip pre-1.4 `-dz.x` dev tags — they
  predate session persistence, so the agent-restart dialog never applied then).
- Best-effort: the committed JSON is the source of truth after backfill; the
  script is spot-checked, not a runtime dependency.

### 4. "Since the last update" tracking

- Persist `whatsNewLastSeenVersion` in `UserDefaults.standard`.
- **At launch** (early, before restore can fire the dialog): read the stored
  value into an in-memory snapshot `previousSeenVersion`, then immediately store
  the current `CFBundleShortVersionString`. The dialog uses the in-memory
  snapshot, so it is stable for the whole session and advances exactly once per
  new binary.
- Version ordering uses `String.compare(_:options:.numeric)` — correct for
  dotted numerics (`"1.10.0" > "1.9.0"`); no new comparator.
- **First run** (nil stored): `previousSeenVersion` is nil → the "new" set is
  every bundled version up to current. In practice this only happens the first
  time an instrumented build runs; acceptable (history is short and scrollable).

### 5. "What's new" rendering

- Keep the `NSAlert`; set
  `alert.accessoryView = NSHostingView(rootView: WhatsNewNotesView(...))`
  (precedent: `alert.accessoryView = …` and `NSHostingView` are both used in the
  codebase).
- `WhatsNewNotesView` is a small SwiftUI view:
  - Fixed frame (~420×240) with an internal `ScrollView`. The toggle expands
    content **inside** the scroll view, so the `NSAlert` never needs to resize.
  - **Above the divider (always shown):** notes for versions **newer than**
    `previousSeenVersion`, newest first. If empty (re-prompt on same version):
    a quiet "No new release notes since your last update." line.
  - **Divider + toggle (collapsed by default):** `▸ Show changes already
    installed` reveals notes for versions **≤** `previousSeenVersion`.
  - Rendered natively from the JSON: section header (secondary, small caps or
    semibold), then bulleted items with a bold `title` line + regular `text`.
    Fully offline; no WKWebView, no markdown parser.
- If **no** notes files load at all (e.g. a build without the resource, or a
  parse failure), the accessory view is simply omitted — the dialog degrades to
  today's behavior (copy-only). The decision buttons never depend on notes.

### 6. Release process changes

- `.claude/commands/release.md`:
  - **Step 2** ("Generate Release Notes"): after approving the friendly notes,
    author/update `release-notes/<version>.json` (single source of truth) and
    commit it with the release. Derive the GitHub-release markdown (Step 6) from
    the same content so the two never drift.
  - **Step 6**: note that the bundled JSON already carries the notes; the
    GitHub release body is the same content rendered as markdown.
- Update `docs/` and the release skill accordingly so the JSON step is not
  forgotten on future releases.

## Data flow

```
launch → read whatsNewLastSeenVersion (snapshot prev) → store current
restore finished / last window closed
  → refreshLocalAgentIfStale(liveSessionCount, reason)
    → agentIsStale? no  → return
                   yes → liveSessionCount == 0 → silent refresh (unchanged)
                         liveSessionCount  > 0 → promptAndRefreshLocalAgent
                            → load bundled release-notes/*.json
                            → split by previousSeenVersion (new vs installed)
                            → NSAlert + WhatsNewNotesView accessory
                            → Update Now → forceRefreshLocalAgent(reconnect:true)
                              Later      → defer (unchanged)
```

## Components & boundaries

- **`ReleaseNotesStore`** (new, testable, pure): loads and decodes the bundled
  `release-notes/*.json`, exposes `notes(newerThan:)` and `notes(atOrOlderThan:)`
  using numeric version comparison. No UI, no UserDefaults. Depends only on a
  resource-directory URL (injectable for tests).
- **`WhatsNewNotesView`** (new SwiftUI): renders the two note groups + toggle
  from a `ReleaseNotesStore` result. No I/O.
- **Last-seen tracking**: a tiny helper (in `LocalAgentManager` or an
  `AppDelegate` hook) that snapshots/advances `whatsNewLastSeenVersion`.
- **`promptAndRefreshLocalAgent`**: unchanged control flow; gains the accessory
  view assembly. Buttons/gating untouched.

## Testing

- **Unit (`ReleaseNotesStore`)**: decode fixtures; `notes(newerThan:)` /
  `notes(atOrOlderThan:)` split correctly incl. `1.9.0`/`1.10.0` ordering;
  missing/garbage files degrade to empty, not crash; nil `previousSeenVersion`
  → everything "new".
- **Unit (last-seen)**: launch snapshots old value then advances; second launch
  on same version → empty "new" set.
- **Manual (debug app)**: trigger the prompt path with a live session + a stale
  agent (e.g. run the app, then point `GHOSTTY_LOCAL_AGENT_BIN` at a
  newer-stamped agent, or otherwise force `agentIsStale`), confirm: copy reads
  correctly, "What's new" shows the right versions, toggle reveals history, alert
  does not resize on toggle, `Update Now`/`Later` behave as before.
- Existing Swift/Zig checks/tests pass; build via
  `zig build -Doptimize=Debug`, test `zig-out/Ghoztty-Debug.app`. Never touch
  `/Applications/Ghoztty.app`.

## Risks / open questions

- `NSHostingView` sizing inside `NSAlert` accessory views can be finicky; the
  fixed-frame + internal-`ScrollView` approach avoids alert-resize churn.
- Backfill parsing is best-effort against ~20 historical bodies; the committed
  JSON is spot-checked and hand-fixable.
- Debug builds report version `1.4.0`; to exercise the "since" split in dev,
  pass `-Dversion-string=` or seed `whatsNewLastSeenVersion` in defaults.
