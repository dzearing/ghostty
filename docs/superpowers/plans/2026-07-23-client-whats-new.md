# Client-scoped "What's New" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface client/app-scoped release notes in two places — inline in the pre-update dialog on the update chip (offered version, delivered via the Sparkle appcast), and in a persistent "What's New in Ghoztty…" menu item with Client/Agent tabs (installed build, bundled offline).

**Architecture:** Both surfaces reuse the existing `WhatsNewNotesContent` renderer and `ReleaseNotesStore`. Offered-version notes ride the appcast item's `<description>` (`SUAppcastItem.itemDescription`), parsed to `VersionNotes` once at the `UpdateDriver` boundary and carried as a stored field on `UpdateState.UpdateAvailable`. The menu window reads bundled `release-notes/client` and `release-notes/agent`, partitioned by `WhatsNewTracking`.

**Tech Stack:** Swift / SwiftUI / AppKit (macOS), Sparkle 2.9, Zig build (`GhosttyResources.zig`), Python (appcast heredoc in `release.yml`), Swift Testing (`GhosttyTests`).

## Global Constraints

- Fork is **Ghoztty (with a Z)** — no "Ghostty" in any new user-facing string.
- Build debug only: `zig build -Doptimize=Debug`; verify in `zig-out/Ghoztty-Debug.app`. **Never touch `/Applications/Ghoztty.app`.**
- No AI attribution in commits or PRs (no `Co-Authored-By`, no "Generated with" footers).
- Pre-update dialog is **client-only** (no agent notes). Client/Agent tabbing exists **only** in the menu window.
- Dialog buttons are **Cancel** (`reply(.dismiss)`) / **Update** (`reply(.install)`). No "Skip this version".
- Swift tests run from `macos/`: `xcodebuild test -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' -only-testing:GhosttyTests/<SuiteName>`. For reliable before/after use `build-for-testing` then `test-without-building`. `-only-testing` matches at the SUITE (struct) level only.
- Additive appcast/notes changes only: absent/garbage notes must degrade to "no notes shown", never crash.

---

### Task 1: `ReleaseNotesStore` — client directory + appcast-description parse seam

**Files:**
- Modify: `macos/Sources/Features/Update/ReleaseNotesStore.swift`
- Test: `macos/Tests/Update/ReleaseNotesStoreTests.swift`

**Interfaces:**
- Produces: `ReleaseNotesStore.clientNotesDirectory: URL?` and `static func versionNotes(fromAppcastDescription description: String?) -> VersionNotes?` — used by Task 3 (dialog), Task 5 (menu window), Task 4 (driver).

- [ ] **Step 1: Write the failing tests**

Append to `macos/Tests/Update/ReleaseNotesStoreTests.swift`:

```swift
struct ReleaseNotesStoreAppcastDescriptionTests {
    @Test func decodesValidJSON() {
        let json = #"{"version":"1.24.0","sections":[{"title":"Fork Changes","items":[{"title":"Viewer","text":"open a website in a side pane"}]}]}"#
        let notes = ReleaseNotesStore.versionNotes(fromAppcastDescription: json)
        #expect(notes?.version == "1.24.0")
        #expect(notes?.sections.first?.items.first?.title == "Viewer")
    }

    @Test func nilForNilEmptyOrNonJSON() {
        #expect(ReleaseNotesStore.versionNotes(fromAppcastDescription: nil) == nil)
        #expect(ReleaseNotesStore.versionNotes(fromAppcastDescription: "") == nil)
        #expect(ReleaseNotesStore.versionNotes(fromAppcastDescription: "not json") == nil)
        #expect(ReleaseNotesStore.versionNotes(fromAppcastDescription: "<h1>HTML release notes</h1>") == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `macos/`):
```bash
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'
```
Expected: BUILD FAILS — `versionNotes(fromAppcastDescription:)` is not a member of `ReleaseNotesStore`.

- [ ] **Step 3: Implement the store additions**

In `macos/Sources/Features/Update/ReleaseNotesStore.swift`, add inside `struct ReleaseNotesStore`, right after `agentNotesDirectory`:

```swift
    /// The bundled CLIENT release-notes directory inside the app Resources, or
    /// nil if absent. Scoped to app/UI/viewer/banner changes (NOT the
    /// session-persistence/agent items under `agentNotesDirectory`).
    static var clientNotesDirectory: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("release-notes", isDirectory: true)
            .appendingPathComponent("client", isDirectory: true)
    }

    /// Decode a single version's notes from an appcast item's `<description>`
    /// (embedded JSON, delivered over the network). Returns nil for nil, empty,
    /// or non-JSON input (e.g. an HTML description) so callers degrade to
    /// showing no notes rather than failing.
    static func versionNotes(fromAppcastDescription description: String?) -> VersionNotes? {
        guard let description,
              let data = description.data(using: .utf8),
              let notes = try? JSONDecoder().decode(VersionNotes.self, from: data)
        else { return nil }
        return notes
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (from `macos/`):
```bash
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'
xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' -only-testing:GhosttyTests/ReleaseNotesStoreAppcastDescriptionTests
```
Expected: PASS (both `decodesValidJSON` and `nilForNilEmptyOrNonJSON`).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Update/ReleaseNotesStore.swift macos/Tests/Update/ReleaseNotesStoreTests.swift
git commit -m "feat(update): ReleaseNotesStore client dir + appcast-description parse"
```

---

### Task 2: Bundle `release-notes/client` + seed content

**Files:**
- Modify: `src/build/GhosttyResources.zig:143-153` (add a client block after the agent block)
- Create: `release-notes/client/<version>.json` (at least one real, curated file)

**Interfaces:**
- Produces: bundled `Contents/Resources/ghostty/release-notes/client/*.json`, loaded by `ReleaseNotesStore(directory: .clientNotesDirectory)` in Task 5.

- [ ] **Step 1: Add the Zig install-directory block**

In `src/build/GhosttyResources.zig`, immediately after the existing `release-notes/agent` block (the `{ ... source_dir = b.path("release-notes/agent") ... }` that ends at ~line 153), add:

```zig
    // Client-scoped "What's new": bundled per-version JSON for the app/UI/
    // viewer/banner changes, rendered offline in the "What's New" menu window
    // (Client tab). Mirrors the agent block above.
    {
        const install_step = b.addInstallDirectory(.{
            .source_dir = b.path("release-notes/client"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = b.pathJoin(&.{ "ghostty", "release-notes", "client" }),
        });
        try steps.append(b.allocator, &install_step.step);
    }
```

- [ ] **Step 2: Seed at least one curated client-notes file**

Generate drafts to curate from, then write the file(s). Run from repo root:
```bash
python3 scripts/backfill-release-notes.py release-notes/.drafts
```
Then, for each shipped version that had **client** changes (app/UI/viewer/banner — NOT session-persistence/agent), create `release-notes/client/<version>.json`. Curate from the drafts; keep only client-scoped items. Minimum to ship: create `release-notes/client/1.23.0.json` with real content, e.g.:

```json
{
  "version": "1.23.0",
  "sections": [
    {
      "title": "Fork Changes",
      "items": [
        { "title": "Viewer feedback capture", "text": "Send feedback (with screenshots and quoted selections) straight from a viewer pane into your worktree." },
        { "title": "Banner polish", "text": "Pane banners now render lists, checkboxes, tables, and thematic breaks." }
      ]
    }
  ]
}
```
(Replace with content that matches the actual release; the JSON shape is `{version, sections:[{title, items:[{title?, text}]}]}` — same as `release-notes/agent/`.)

- [ ] **Step 3: Build to verify bundling**

Run from repo root:
```bash
zig build -Doptimize=Debug
ls zig-out/Ghoztty-Debug.app/Contents/Resources/ghostty/release-notes/client/
```
Expected: build succeeds; the `client/` directory lists the seeded `*.json` file(s).

- [ ] **Step 4: Commit**

```bash
git add src/build/GhosttyResources.zig release-notes/client/
git commit -m "feat(update): bundle release-notes/client into app Resources"
```

---

### Task 3: Carry parsed client notes on `UpdateAvailable` + wire the driver

**Files:**
- Modify: `macos/Sources/Features/Update/UpdateViewModel.swift:275-283` (`UpdateAvailable` struct)
- Modify: `macos/Sources/Features/Update/UpdateDriver.swift:59-66` (`showUpdateFound`)

**Interfaces:**
- Produces: `UpdateState.UpdateAvailable.clientNotes: VersionNotes?` (stored, default `nil`) — consumed by Task 4 (view) and Task 4's simulator case.
- Consumes: `ReleaseNotesStore.versionNotes(fromAppcastDescription:)` (Task 1).

- [ ] **Step 1: Add the stored field + explicit initializer**

In `macos/Sources/Features/Update/UpdateViewModel.swift`, replace the `struct UpdateAvailable { ... }` opening (the `let appcastItem` / `let reply` lines) so it reads:

```swift
    struct UpdateAvailable {
        let appcastItem: SUAppcastItem
        let reply: @Sendable (SPUUserUpdateChoice) -> Void

        /// Client-scoped notes for the OFFERED version, parsed from the appcast
        /// item's embedded `<description>`. nil when the appcast carries none.
        let clientNotes: VersionNotes?

        init(appcastItem: SUAppcastItem,
             reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void,
             clientNotes: VersionNotes? = nil) {
            self.appcastItem = appcastItem
            self.reply = reply
            self.clientNotes = clientNotes
        }

        var releaseNotes: ReleaseNotes? {
            let currentCommit = Bundle.main.infoDictionary?["GhosttyCommit"] as? String
            return ReleaseNotes(displayVersionString: appcastItem.displayVersionString, currentCommit: currentCommit)
        }
    }
```
(The `releaseNotes` computed property is unchanged — keep it; only the stored field + init are new. The default `clientNotes: nil` keeps existing `.init(appcastItem:reply:)` call sites compiling.)

- [ ] **Step 2: Parse notes at the driver boundary**

In `macos/Sources/Features/Update/UpdateDriver.swift`, in `showUpdateFound(with:state:reply:)`, replace:

```swift
        viewModel.state = .updateAvailable(.init(appcastItem: appcastItem, reply: reply))
```
with:
```swift
        viewModel.state = .updateAvailable(.init(
            appcastItem: appcastItem,
            reply: reply,
            clientNotes: ReleaseNotesStore.versionNotes(
                fromAppcastDescription: appcastItem.itemDescription)))
```

- [ ] **Step 3: Build to verify it compiles (existing tests unaffected)**

Run from repo root:
```bash
zig build -Doptimize=Debug
```
Expected: build succeeds. `UpdateStateTests` / `UpdateViewModelTests` still compile (they call `.init(appcastItem:reply:)`, which the default arg preserves).

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Update/UpdateViewModel.swift macos/Sources/Features/Update/UpdateDriver.swift
git commit -m "feat(update): parse offered-version client notes from appcast item"
```

---

### Task 4: Reshape the pre-update dialog (inline notes + Cancel/Update) + simulator seam

**Files:**
- Modify: `macos/Sources/Features/Update/UpdatePopoverView.swift` (`UpdatePopoverView.body` width; `UpdateAvailableView`)
- Modify: `macos/Sources/Features/Update/UpdateSimulator.swift` (new case for manual verification)

**Interfaces:**
- Consumes: `UpdateState.UpdateAvailable.clientNotes` (Task 3), `WhatsNewNotesContent` (existing).

- [ ] **Step 1: Widen the popover for the update-available state**

In `macos/Sources/Features/Update/UpdatePopoverView.swift`, change `UpdatePopoverView`'s body `.frame(width: 300)` to `.frame(width: popoverWidth)` and add this computed property to `UpdatePopoverView`:

```swift
    /// The update-available dialog is wider to fit inline release notes; other
    /// states keep the compact width. When no notes are present it stays compact.
    private var popoverWidth: CGFloat {
        if case .updateAvailable(let update) = model.state, update.clientNotes != nil {
            return 420
        }
        return 300
    }
```

- [ ] **Step 2: Replace the release-notes link + buttons in `UpdateAvailableView`**

In `UpdateAvailableView.body`, replace the button `HStack` (the `Skip` / `Later` / `Install and Relaunch` block, ~lines 168-191) with:

```swift
                HStack(spacing: 8) {
                    Button("Cancel") {
                        update.reply(.dismiss)
                        dismiss()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Update") {
                        update.reply(.install)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
```

Then replace the trailing `if let notes = update.releaseNotes { Divider(); Link(...) ... }` block (~lines 195-215) with inline notes:

```swift
            if let notes = update.clientNotes {
                Divider()

                ScrollView {
                    WhatsNewNotesContent(newNotes: [notes], installedNotes: [])
                        .padding(14)
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 260)
            }
```
(Leave the `.padding(16)` on the info `VStack` as-is. The `update.releaseNotes` GitHub-link computed property stays defined in the model but is no longer used by this view — that is intentional and out of scope to remove.)

- [ ] **Step 3: Add a simulator case that injects sample client notes**

In `macos/Sources/Features/Update/UpdateSimulator.swift`, add a case to the enum:
```swift
    /// Update available WITH inline client release notes, for verifying the
    /// pre-update dialog's notes rendering offline.
    case updateAvailableWithNotes
```
Add it to the `simulate(with:)` switch:
```swift
        case .updateAvailableWithNotes:
            simulateUpdateAvailableWithNotes(viewModel)
```
And add the method:
```swift
    private func simulateUpdateAvailableWithNotes(_ viewModel: UpdateViewModel) {
        let notes = VersionNotes(version: "1.24.0", sections: [
            ReleaseNoteSection(title: "Fork Changes", items: [
                ReleaseNote(title: "Viewer panes", text: "Open a rendered **markdown** file, a code file, or a website in a side pane."),
                ReleaseNote(title: "Pane banners", text: "Pin a sticky status banner — lists, tables, and links — above any pane."),
                ReleaseNote(title: nil, text: "Assorted UI polish across the app."),
            ]),
        ])
        viewModel.state = .updateAvailable(.init(
            appcastItem: SUAppcastItem.empty(),
            reply: { _ in viewModel.state = .idle },
            clientNotes: notes))
    }
```

- [ ] **Step 4: Build**

Run from repo root:
```bash
zig build -Doptimize=Debug
```
Expected: build succeeds.

- [ ] **Step 5: Manual verification in the debug app**

Temporarily wire the simulator (do NOT commit this edit): in `macos/Sources/App/macOS/AppDelegate.swift` `checkForUpdates(_:)`, replace the body with `UpdateSimulator.updateAvailableWithNotes.simulate(with: updateController.viewModel)`, rebuild, and launch:
```bash
zig build -Doptimize=Debug
open zig-out/Ghoztty-Debug.app
```
Then trigger **Ghoztty ▸ Check for Updates…** and click the update chip. Confirm:
- The dialog widens (~420pt) and shows the version rows, then a divider, then the "What's new" notes (bold titles, `•` bullets, rendered `**markdown**`), scrolling if long.
- Buttons read **Cancel** and **Update**; Cancel dismisses (idle), Update dismisses.
- All strings say "Ghoztty".
Revert the temporary `checkForUpdates` edit before committing.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Features/Update/UpdatePopoverView.swift macos/Sources/Features/Update/UpdateSimulator.swift
git commit -m "feat(update): inline client notes + Cancel/Update in pre-update dialog"
```

---

### Task 5: "What's New in Ghoztty…" menu window (Client/Agent tabs)

**Files:**
- Create: `macos/Sources/Features/Update/WhatsNewWindowView.swift`
- Modify: `macos/Sources/App/macOS/AppDelegate.swift` (add `whatsNewWindow` property + `showWhatsNew(_:)`)
- Modify: `macos/Sources/App/macOS/MainMenu.xib` (add menu item under "About Ghoztty")

**Interfaces:**
- Consumes: `WhatsNewNotesContent` (existing), `ReleaseNotesStore(directory:)` + `clientNotesDirectory`/`agentNotesDirectory` + `partitioned` (Task 1 / existing), `WhatsNewTracking` (existing).

- [ ] **Step 1: Create the tabbed window view**

Create `macos/Sources/Features/Update/WhatsNewWindowView.swift`:

```swift
import SwiftUI

/// The post-install "What's New" window body. Tabs between client/app notes and
/// agent/session notes — both bundled offline and partitioned by the version
/// the user last ran. Reuses `WhatsNewNotesContent` for each tab.
struct WhatsNewWindowView: View {
    let clientNew: [VersionNotes]
    let clientInstalled: [VersionNotes]
    let agentNew: [VersionNotes]
    let agentInstalled: [VersionNotes]

    var body: some View {
        TabView {
            tab(new: clientNew, installed: clientInstalled)
                .tabItem { Text("Client") }
            tab(new: agentNew, installed: agentInstalled)
                .tabItem { Text("Agent") }
        }
        .padding(12)
        .frame(width: 460, height: 380)
    }

    @ViewBuilder
    private func tab(new: [VersionNotes], installed: [VersionNotes]) -> some View {
        ScrollView {
            WhatsNewNotesContent(newNotes: new, installedNotes: installed)
                .padding(16)
        }
    }
}
```

- [ ] **Step 2: Add the menu action + reusable window in AppDelegate**

In `macos/Sources/App/macOS/AppDelegate.swift`, add a stored property near the other window/state properties (e.g. just below `let updateController = UpdateController()`):
```swift
    /// The reusable "What's New" window (created lazily, kept for reuse).
    private var whatsNewWindow: NSWindow?
```
Add the action next to `checkForUpdates(_:)` (~line 1166):
```swift
    @IBAction func showWhatsNew(_ sender: Any?) {
        if let win = whatsNewWindow {
            win.makeKeyAndOrderFront(sender)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let previousSeen = WhatsNewTracking.previousSeenVersion
        let current = WhatsNewTracking.currentAppVersion
        let client = ReleaseNotesStore(directory: ReleaseNotesStore.clientNotesDirectory)
            .partitioned(previousSeen: previousSeen, current: current)
        let agent = ReleaseNotesStore(directory: ReleaseNotesStore.agentNotesDirectory)
            .partitioned(previousSeen: previousSeen, current: current)

        let view = WhatsNewWindowView(
            clientNew: client.new, clientInstalled: client.installed,
            agentNew: agent.new, agentInstalled: agent.installed)

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "What’s New in Ghoztty"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        whatsNewWindow = window
        window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 3: Add the menu item in MainMenu.xib**

In `macos/Sources/App/macOS/MainMenu.xib`, in the Ghoztty app menu, immediately AFTER the `About Ghoztty` menuItem (`id="5kV-Vb-QxS"`, closes with `</menuItem>`) and BEFORE `Check for Updates...` (`id="GEA-5y-yzH"`), insert:

```xml
                            <menuItem title="What’s New in Ghoztty…" id="WhN-01-itm">
                                <modifierMask key="keyEquivalentModifierMask"/>
                                <connections>
                                    <action selector="showWhatsNew:" target="bbz-4X-AYv" id="WhN-01-act"/>
                                </connections>
                            </menuItem>
```
(`bbz-4X-AYv` is the AppDelegate object; the two `id`s must be unique in the file — `WhN-01-itm` / `WhN-01-act` are unused.)

- [ ] **Step 4: Build**

Run from repo root:
```bash
zig build -Doptimize=Debug
```
Expected: build succeeds.

- [ ] **Step 5: Manual verification in the debug app**

Because a debug build reports version `1.4.0`, `partitioned` caps "new" at `1.4.0` and drops higher-versioned bundled notes from the "new" group. To see the seeded notes render, seed a high last-seen version so they land in the "already installed" disclosure:
```bash
defaults write com.mitchellh.ghostty.debug whatsNewLastSeenVersion "2.0.0"
open zig-out/Ghoztty-Debug.app
```
(If that bundle id differs, get it from `zig-out/Ghoztty-Debug.app/Contents/Info.plist` `CFBundleIdentifier`.) Then **Ghoztty ▸ What's New in Ghoztty…**. Confirm:
- The window opens, titled "What's New in Ghoztty", with **Client** and **Agent** tabs.
- Each tab renders `WhatsNewNotesContent`; expanding "Show changes already installed" reveals the bundled notes for that scope.
- Re-invoking the menu item focuses the SAME window (no duplicate).
- All strings say "Ghoztty".
Clean up: `defaults delete com.mitchellh.ghostty.debug whatsNewLastSeenVersion`.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Features/Update/WhatsNewWindowView.swift macos/Sources/App/macOS/AppDelegate.swift macos/Sources/App/macOS/MainMenu.xib
git commit -m "feat(update): What's New menu window with Client/Agent tabs"
```

---

### Task 6: Embed client notes in the appcast at release time

**Files:**
- Modify: `.github/workflows/release.yml:155-194` (the "Update appcast and deploy to GitHub Pages" step / inline Python heredoc)

**Interfaces:**
- Consumes: `release-notes/client/<version>.json` from the repo checkout (`$GITHUB_WORKSPACE`).
- Produces: the appcast item's `<description>` = that JSON, read at runtime via `SUAppcastItem.itemDescription` (Task 3).

- [ ] **Step 1: Capture the client-notes path and pass it to Python**

In `.github/workflows/release.yml`, in the appcast step, before the `python3 - ...` invocation (the notes file lives in the repo checkout, not `/tmp/gh-pages`), add near the other shell vars (before `cd /tmp/gh-pages`):
```bash
          CLIENT_NOTES="$GITHUB_WORKSPACE/release-notes/client/${VERSION}.json"
```
Then change the heredoc invocation line from:
```bash
          python3 - "$VERSION" "$DOWNLOAD_URL" "$ED_SIGNATURE" "$DMG_LENGTH" "$PUB_DATE" <<'PYEOF'
```
to:
```bash
          python3 - "$VERSION" "$DOWNLOAD_URL" "$ED_SIGNATURE" "$DMG_LENGTH" "$PUB_DATE" "$CLIENT_NOTES" <<'PYEOF'
```

- [ ] **Step 2: Emit the `<description>` when the file exists**

Inside the heredoc, change the argv unpack line from:
```python
          version, url, sig, length, pub_date = sys.argv[1:6]
```
to:
```python
          import os
          version, url, sig, length, pub_date, client_notes_path = sys.argv[1:7]
```
Then, after the `ET.SubElement(item, "pubDate").text = pub_date` line and before the `enclosure = ...` line, add:
```python
          if client_notes_path and os.path.isfile(client_notes_path):
              with open(client_notes_path, "r", encoding="utf-8") as f:
                  ET.SubElement(item, "description").text = f.read()
```
(ElementTree XML-escapes the JSON on write; Sparkle unescapes it into `itemDescription`. When the file is absent, no `<description>` is emitted — unchanged behavior.)

- [ ] **Step 3: Validate the heredoc logic locally**

The workflow can't run here, but validate the Python branch with a stand-in:
```bash
cd /tmp && cat > /tmp/wf_test.py <<'PYEOF'
import os, xml.etree.ElementTree as ET
client_notes_path = os.environ["CN"]
channel = ET.Element("channel"); item = ET.SubElement(channel, "item")
if client_notes_path and os.path.isfile(client_notes_path):
    with open(client_notes_path, encoding="utf-8") as f:
        ET.SubElement(item, "description").text = f.read()
ET.indent(channel); print(ET.tostring(channel, encoding="unicode"))
PYEOF
CN="$(pwd)/release-notes/client/1.23.0.json" python3 /tmp/wf_test.py 2>/dev/null; true
CN=/nonexistent python3 /tmp/wf_test.py
rm -f /tmp/wf_test.py
```
Expected: with a real file, `<description>` contains the escaped JSON; with a missing file, `<item />` has no `<description>`. (Run the first from the repo root so the relative path resolves.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci(release): embed client release-notes JSON in appcast description"
```

---

### Task 7: Document the client-notes release step

**Files:**
- Modify: `.claude/commands/release.md` (Step 2)
- Modify: `release-notes/README.md` (the `client/` section)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `release.md` Step 2**

In `.claude/commands/release.md`, in Step 2, after the agent-notes paragraph ("**If the agent changed, author the bundled agent notes.** …"), add:

```markdown
**Author the bundled client notes.** For every release that changes the app/UI
(viewer, banners, terminal UI, menus — anything a user sees that is NOT
session-persistence/agent), write `release-notes/client/<version>.json` with
**only** the client-scoped items (schema in `release-notes/README.md`; same
shape as the agent notes). Commit it with the release commit **before** tagging
(Step 3) so it both ships in the app bundle (the "What's New" menu window) and
is embedded into the Sparkle appcast `<description>` by `release.yml` (the
pre-update dialog on the update chip reads it from the appcast). Exclude the
agent/session items already captured under `release-notes/agent/`.
```

- [ ] **Step 2: Update `release-notes/README.md`**

Replace the `## client/ — reserved for the app "What's new"` section (the "Not built yet." paragraph) with:

```markdown
## `client/` — the app "What's new"

`client/<version>.json` is the client/app-scoped "What's new" (app, UI, viewer,
banner changes — everything a user sees that is NOT session-persistence/agent).
Same JSON shape as `agent/`. It ships **two ways**:

1. **Bundled offline** into the app (`src/build/GhosttyResources.zig` →
   `Contents/Resources/ghostty/release-notes/client/`) and shown in the
   **"What's New in Ghoztty…"** menu window (Client tab).
2. **Embedded in the Sparkle appcast** `<description>` by `.github/workflows/release.yml`
   at release time, so the **pre-update dialog** on the update chip can render
   the OFFERED version's notes before the user updates (the running old app
   can't have the new version's notes bundled — they travel over the network).

Author `client/<version>.json` before tagging a release (see
`.claude/commands/release.md`, Step 2). Exclude agent/session items — those
live under `agent/`.
```

- [ ] **Step 3: Commit**

```bash
git add .claude/commands/release.md release-notes/README.md
git commit -m "docs(release): document client release-notes authoring + delivery"
```

---

### Task 8: Final full build + test sweep

**Files:** none (verification).

- [ ] **Step 1: Full debug build**

```bash
zig build -Doptimize=Debug
```
Expected: success.

- [ ] **Step 2: Run the affected Swift test suites**

From `macos/`:
```bash
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'
xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' \
  -only-testing:GhosttyTests/ReleaseNotesStoreAppcastDescriptionTests \
  -only-testing:GhosttyTests/ReleaseNotesStorePartitionTests \
  -only-testing:GhosttyTests/ReleaseNotesStoreLoadTests \
  -only-testing:GhosttyTests/UpdateStateTests
```
Expected: all PASS.

- [ ] **Step 3: Confirm no "Ghostty" (no Z) in new user-facing strings**

```bash
git diff main..HEAD -- macos/Sources release-notes | grep -n "Ghostty" | grep -vi "ghostty-org\|com.mitchellh.ghostty\|Resources/ghostty\|infoDictionary" || echo "clean"
```
Expected: `clean` (any hits are code paths/identifiers, not user copy — review each).

- [ ] **Step 4: Final manual smoke (both surfaces)**

Repeat Task 4 Step 5 (dialog) and Task 5 Step 5 (menu window) once more on the final build to confirm nothing regressed.

---

## Self-Review

**Spec coverage:**
- Pre-update dialog inline notes + Cancel/Update → Tasks 3, 4. ✅
- Offered notes via appcast `itemDescription` → Tasks 1, 3, 6. ✅
- "What's New" menu item, Client/Agent tabs, bundled offline → Tasks 2, 5. ✅
- `ReleaseNotesStore` client dir + parse seam → Task 1. ✅
- Bundling via GhosttyResources.zig → Task 2. ✅
- `release.yml` appcast (not the stale `update_appcast_tag.py`) → Task 6. ✅
- Release docs → Task 7. ✅
- Testing (unit + manual) → Tasks 1, 4, 5, 8. ✅
- Degradation (no notes → dialog still works) → Task 4 (`if let update.clientNotes`), Task 1 tests. ✅

**Type consistency:** `versionNotes(fromAppcastDescription:)` returns `VersionNotes?` and is used identically in Task 3 (driver) and Task 1 (tests); `clientNotes: VersionNotes?` field name matches across Tasks 3/4; `clientNotesDirectory`/`agentNotesDirectory` + `partitioned(previousSeen:current:)` match existing signatures used in Task 5; `WhatsNewNotesContent(newNotes:installedNotes:)` matches the existing initializer.

**Placeholders:** none — every code/test/command step carries concrete content. The one content-curation judgement (which historical versions get client notes) is bounded in Task 2 Step 2 with a concrete minimum file and the exact JSON schema.
