# Client-scoped "What's new": pre-update dialog + What's New menu

## Problem

Ghoztty already surfaces **agent-scoped** release notes in the agent-restart
dialog (offline-bundled, because after an app upgrade the running app *is* the
new version and only the background agent lags). There is no equivalent for
**client/app-scoped** changes (app, UI, viewer, banner features).

Two gaps:

1. **Before updating**, the update chip's popover
   (`UpdatePopoverView` → `UpdateAvailableView`) shows only version / size /
   date plus a single **"View Release Notes"** link that opens GitHub in a
   browser. The user has no in-app basis to judge whether the offered update is
   worth taking.
2. **After updating**, there is no way to revisit "what changed" — the agent
   notes only appear transiently when a restart is required, and client notes
   are not surfaced anywhere.

## Goals

- **Pre-update dialog:** the update chip opens a dialog that shows the offered
  version's **client-scoped** notes **inline**, with **Cancel / Update**
  actions.
- **Post-install "What's New" menu item:** a persistent, user-invokable
  "What's New in Ghoztty…" item in the Ghoztty app menu that shows bundled,
  offline client notes, with a **tab to switch between Client and Agent**
  notes.
- Reuse the existing renderer (`WhatsNewNotesContent`) and store
  (`ReleaseNotesStore`) — this is a reshape, not a rebuild.
- No "Ghostty" (no Z) in any new user-facing string.

## Non-goals

- No post-update **auto-shown** first-launch window. The menu item is
  user-invoked; there is no automatic popup on version bump. (Confirmed with
  user.)
- No change to Sparkle's update mechanics, the agent-restart dialog, or the
  agent notes content.
- No "Skip this version" affordance in the new dialog (confirmed dropped — see
  Design §1).
- The pre-update dialog is **client-only**. Agent notes are not shown there
  (they are not in the appcast, and the agent has its own restart dialog). The
  Client/Agent tabbing exists **only** in the post-install menu window.

## Key architectural constraint (already investigated)

The running (old) app is being offered a **newer** version. The old app's
bundle **cannot** contain the offered version's notes — those ship inside the
new build. So the offered version's client notes **must travel over the
network**, via the Sparkle appcast (the update check is already online):

- **Verified delivery field:** Sparkle's `SUAppcastItem.itemDescription`
  (`String?`, extracted from the appcast item's `<description>` element).
  Sparkle's own header documents this as the supported way to embed release
  notes inline: *"An alternative to using an external release notes link is
  providing an embedded `itemDescription`."* Confirmed in the vendored Sparkle
  2.9 header (`SUAppcastItem.h:158`).
- We embed the offered version's `release-notes/client/<version>.json`
  **verbatim** as that item's `<description>`, then decode it back to
  `VersionNotes` at runtime. The fork's custom update UI does not render
  Sparkle's standard notes view, so repurposing `<description>` as structured
  JSON is safe.

By contrast, the **post-install** menu window shows the *installed* build's own
notes, so it is **fully offline-bundled** (same mechanism as the agent notes).

### Which release path actually generates the appcast

The prompt referenced `dist/macos/update_appcast_tag.py`, but that script
belongs to the **upstream** `release-tag.yml` workflow, which still points at
`ghostty-org` / `ghostty.org` / `release.files.ghostty.org` infrastructure the
fork does not own. It is **not** the fork's live path.

The fork's actual release path is **`.github/workflows/release.yml`** — the
one triggered by `git push origin main --tags` (per `.claude/commands/release.md`
Step 3) and monitored in Step 5. It builds the appcast inline with a Python
heredoc (`release.yml:168-194`) that currently emits **no** `<description>`.
**The client-notes injection lands there.** `release-tag.yml` /
`update_appcast_tag.py` are left untouched (out of scope; already stale).

## Design

### 1. Surface 1 — Pre-update dialog (the chip)

Reshape the `.updateAvailable` case of `UpdatePopoverView` (do not rebuild):

- Keep the **Version / Size / Released** info rows.
- Replace the "View Release Notes" GitHub link with the offered version's
  notes rendered **inline** via
  `WhatsNewNotesContent(newNotes: [offered], installedNotes: [])`, inside a
  **bounded `ScrollView`** so a long notes list scrolls rather than growing the
  popover without limit. Widen this state to ~420pt (other states stay at their
  current 300pt); the notes column is what needs the room.
  - `installedNotes: []` ⇒ `WhatsNewNotesContent` shows a single version block
    with no "already installed" disclosure (existing `if !installedNotes.isEmpty`
    guard).
- **Buttons:** `Cancel` (`.keyboardShortcut(.cancelAction)`) → `reply(.dismiss)`
  (Sparkle "Later" semantics: the update stays on the chip and is re-offered on
  the next check) and `Update` (`.borderedProminent`, `.defaultAction`) →
  `reply(.install)`. **"Skip this version" is removed** (confirmed).
- **Notes source:** decode `update.appcastItem.itemDescription` into
  `VersionNotes` (see §3). If the description is absent, not JSON, or fails to
  decode (e.g. an older appcast item, or the upstream HTML description),
  **render no notes** — the dialog degrades to info + buttons. The decision
  buttons never depend on notes loading.

### 2. Surface 2 — "What's New in Ghoztty…" menu item (post-install)

- **Menu:** add a `What's New in Ghoztty…` item to the **Ghoztty app menu**
  (`MainMenu.xib`, the `systemMenu="apple"` menu), placed right under **About
  Ghoztty** (`id 5kV-Vb-QxS`), wired to a new
  `@IBAction func showWhatsNew(_:)` in `AppDelegate` (mirroring the existing
  `checkForUpdates` / `showAbout` outlets + actions).
- **Window:** the action lazily creates (and reuses) an `NSWindow` hosting an
  `NSHostingView` of a new SwiftUI `WhatsNewWindowView` — the same
  `NSHostingView`-in-AppKit pattern the agent dialog uses. Held by `AppDelegate`
  so re-invoking focuses the existing window rather than stacking copies.
- **Tabs:** `WhatsNewWindowView` is a `TabView` (or segmented `Picker`) with two
  tabs — **Client** and **Agent** — each rendering `WhatsNewNotesContent` over
  the respective bundled notes, partitioned by `WhatsNewTracking` (see §4):
  - **Client tab:** `ReleaseNotesStore(directory: .clientNotesDirectory)`
  - **Agent tab:** `ReleaseNotesStore(directory: .agentNotesDirectory)`
  - Each shows "new since your last version" above the divider and the
    "already installed" disclosure below — identical to the agent dialog's body.

### 3. `ReleaseNotesStore` additions

- Add `static var clientNotesDirectory: URL?` — the sibling of the existing
  `agentNotesDirectory`, pointing at
  `Contents/Resources/ghostty/release-notes/client`.
- Add a pure, testable parse seam for appcast-delivered notes:
  ```swift
  /// Decode a single version's notes from an appcast item's <description>
  /// (JSON). Returns nil for nil/empty/non-JSON input.
  static func versionNotes(fromAppcastDescription description: String?)
      -> VersionNotes?
  ```
  Implementation: `guard let data = description?.data(using: .utf8)` then
  `try? JSONDecoder().decode(VersionNotes.self, from: data)`.

No change to `VersionNotes` / `ReleaseNoteSection` / `ReleaseNote` /
`partitioned(previousSeen:current:)` / `isNewer` — reused as-is.

### 4. Last-seen tracking (reused)

`WhatsNewTracking.snapshotAndAdvance` already runs once at launch
(`AppDelegate.applicationDidFinishLaunching`, ~line 257) and exposes
`previousSeenVersion` (stable for the session) and `currentAppVersion`. The
menu window's Client and Agent tabs both partition with
`partitioned(previousSeen: WhatsNewTracking.previousSeenVersion,
current: WhatsNewTracking.currentAppVersion)`. No new tracking is needed; the
pre-update dialog does not partition (single offered version, no history).

### 5. Bundling

- `src/build/GhosttyResources.zig`: add one `addInstallDirectory` step for
  `release-notes/client` → `ghostty/release-notes/client`, mirroring the
  existing `release-notes/agent` step (~lines 144-151).
- `release-notes/client/<version>.json`: curate client-scoped notes
  (app/UI/viewer/banner), **excluding** agent/session-persistence items (those
  stay under `release-notes/agent/`). Same JSON shape as agent notes. Seed from
  `scripts/backfill-release-notes.py` drafts, split by scope.

### 6. Release pipeline

`.github/workflows/release.yml` (the inline appcast heredoc, ~168-194):

- Before the heredoc, read the client notes file for the release version if it
  exists: `CLIENT_NOTES=$(cat release-notes/client/${VERSION}.json 2>/dev/null || true)`
  and pass it into the Python block.
- In Python, when the notes string is non-empty, add
  `ET.SubElement(item, "description").text = client_notes` (ElementTree
  XML-escapes the value on write; Sparkle unescapes it on read — no manual
  CDATA needed). When empty, emit no `<description>` (unchanged behavior).

Docs:
- `.claude/commands/release.md` Step 2: after approving the friendly notes,
  author/update `release-notes/client/<version>.json` (client-scoped) and commit
  it **before** tagging, alongside the existing agent-notes instruction.
- `release-notes/README.md`: replace the "reserved / not built yet" `client/`
  section with the real format + "ships two ways" note (bundled for the menu
  window; embedded in the appcast for the pre-update dialog).

## Components & boundaries

- **`ReleaseNotesStore`** (extended, pure/testable): gains `clientNotesDirectory`
  and `versionNotes(fromAppcastDescription:)`. No UI, no UserDefaults; directory
  injectable for tests.
- **`WhatsNewNotesContent`** (reused, unchanged): the single renderer for all
  three note views (pre-update dialog, menu Client tab, menu Agent tab).
- **`UpdateAvailableView`** (reshaped, in `UpdatePopoverView.swift`): inline
  notes + Cancel/Update. Depends on `UpdateState.UpdateAvailable.appcastItem`
  and the new parse seam.
- **`WhatsNewWindowView`** (new SwiftUI): the tabbed Client/Agent window body.
  Pure view over two `ReleaseNotesStore` results.
- **`AppDelegate.showWhatsNew`** (new `@IBAction`): owns the menu window's
  lifecycle (create/reuse/focus). Menu item added in `MainMenu.xib`.
- **`UpdateSimulator`** (extended): a case that injects an `.updateAvailable`
  whose `SUAppcastItem` carries a `description`, to exercise the dialog offline.

## Data flow

```
# Pre-update (network)
update check → Sparkle fetches appcast → SUAppcastItem for offered version
  (its <description> = client notes JSON)
chip tapped → UpdateAvailableView
  → ReleaseNotesStore.versionNotes(fromAppcastDescription: item.itemDescription)
  → WhatsNewNotesContent(newNotes: [that], installedNotes: [])
  → Cancel → reply(.dismiss) | Update → reply(.install)

# Post-install (offline, bundled)
launch → WhatsNewTracking.snapshotAndAdvance (prev, current)
menu: What's New in Ghoztty… → AppDelegate.showWhatsNew
  → WhatsNewWindowView (TabView)
       Client tab: ReleaseNotesStore(.clientNotesDirectory)
                     .partitioned(prev, current) → WhatsNewNotesContent
       Agent  tab: ReleaseNotesStore(.agentNotesDirectory)
                     .partitioned(prev, current) → WhatsNewNotesContent
```

## Testing

- **Unit (`ReleaseNotesStore`)**:
  - `versionNotes(fromAppcastDescription:)` decodes valid JSON; returns nil for
    nil, empty, non-JSON, and HTML inputs (graceful degradation).
  - `clientNotesDirectory` loads + partitions bundled fixtures; empty/missing
    dir → empty, not crash. (Mirror existing agent-notes tests.)
- **Manual (debug app, `zig build -Doptimize=Debug` → `zig-out/Ghoztty-Debug.app`)**:
  - Pre-update dialog: via a new `UpdateSimulator` case that builds an
    `SUAppcastItem(dictionary:)` with a `description` (client JSON) + version;
    confirm notes render inline, the popover is bounded/scrolls, and
    Cancel/Update fire `.dismiss`/`.install`.
  - Menu window: "What's New in Ghoztty…" opens the window; Client/Agent tabs
    each render bundled notes; re-invoking focuses the same window; strings say
    "Ghoztty".
  - Degradation: an `.updateAvailable` with `SUAppcastItem.empty()` (nil
    description) shows the dialog with no notes and working buttons.
- **Build/CI:** existing Swift/Zig checks pass; never touch
  `/Applications/Ghoztty.app`.

## Risks / open questions

- **`SUAppcastItem(dictionary:)` is deprecated** (test-only use). Acceptable for
  a simulator seam; if it proves unusable, fall back to a protocol/closure seam
  that supplies the description string to the view for simulation.
- **Appcast size:** client notes are ~1-2 KB each; the appcast keeps a bounded
  number of items, so total growth is negligible.
- **Debug builds report version `1.4.0`** (the `build.zig.zon` default), so the
  "new vs already installed" split in the menu window won't reflect real
  history locally; seed `whatsNewLastSeenVersion` in defaults to exercise it.
- **Old appcast items** (pre-feature, or upstream HTML descriptions) decode to
  nil → dialog shows no notes. Intended.
