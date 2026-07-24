# Agent-Update Dialog: Copy + Bundled "What's New" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reframe the agent-restart confirmation dialog's copy around the user's mental model, and add an offline "What's new" section (release notes bundled in the app, split into "since your last version" vs. a collapsed "already installed" list) so the user can judge whether the update is worth resetting live sessions.

**Architecture:** Release notes are bundled per-version as `release-notes/<semver>.json` (backfilled from GitHub Releases), installed into the app bundle via the existing `share/ghostty` folder reference. A pure `ReleaseNotesStore` loads/partitions them; `WhatsNewTracking` snapshots the last-seen app version in `UserDefaults` at launch; a small SwiftUI `WhatsNewNotesView` renders the two groups inside the existing `NSAlert` as an `accessoryView`. The `NSAlert` control flow and destructive-refresh gating are untouched.

**Tech Stack:** Swift (AppKit `NSAlert` + SwiftUI `NSHostingView`), Swift Testing (`import Testing`), Zig build (`src/build/GhosttyResources.zig`), Python 3 + `gh` (one-time backfill).

## Global Constraints

- Fork is **Ghoztty** (with a Z). No "Ghostty" spelling in any new user-visible string.
- Never weaken "never silently reset live sessions": the confirmation stays mandatory, the idle path stays silent, buttons still gate `forceRefreshLocalAgent(reconnect: true)`.
- No "What's new" UI on the idle silent-upgrade path (out of scope).
- Notes render **fully offline** (no network, no WKWebView, no markdown parser).
- Build **debug only**: `zig build -Doptimize=Debug`, test via `zig-out/Ghoztty-Debug.app`. **Never touch `/Applications/Ghoztty.app`.**
- Notes are keyed by bare semver matching `CFBundleShortVersionString` (e.g. `1.26.0`, no leading `v`).
- New Swift files under `macos/Sources/` and `macos/Tests/` auto-compile (synchronized Xcode groups) — no `project.pbxproj` edits.
- No AI attribution in commits/PRs.
- Swift tests: from `macos/`, `xcodebuild test -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' -only-testing:GhosttyTests/<SuiteName>`. Filtering works at SUITE level only. Use `build-for-testing` + `test-without-building` to avoid stale binaries.

---

### Task 1: Backfill script + generated `release-notes/*.json`

Produces the notes data (and the `release-notes/` directory) that the bundling step and manual verification depend on.

**Files:**
- Create: `scripts/backfill-release-notes.py`
- Create (generated): `release-notes/<semver>.json` (v1.4.0 → latest)

**Interfaces:**
- Produces: a `release-notes/` directory of files shaped
  `{ "version": String, "sections": [ { "title": String, "items": [ { "title"?: String, "text": String } ] } ] }`.

- [ ] **Step 1: Write the backfill script**

Create `scripts/backfill-release-notes.py`:

```python
#!/usr/bin/env python3
"""Backfill bundled release-notes JSON from GitHub Releases.

One-time / occasionally-run helper. Fetches each GitHub release body for the
Ghoztty macOS app, strips the install boilerplate, parses `### Section` +
`- **Title** — text` bullets, and writes release-notes/<semver>.json keyed by
the app's CFBundleShortVersionString (bare semver, no leading 'v').

Usage: python3 scripts/backfill-release-notes.py   (run from repo root)
Requires: authenticated `gh`.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = "dzearing/ghoztty"
OUT = Path("release-notes")
MIN = (1, 4, 0)  # skip pre-1.4 -dz dev tags (predate session persistence)

BULLET = re.compile(r"^\s*[-*]\s+(.*)$")
BOLD_LEAD = re.compile(r"^\*\*(.+?)\*\*\s*[—–-]\s*(.*)$")
HEADING = re.compile(r"^###\s+(.*)$")


def sh(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def semver_tuple(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", v)
    return tuple(int(x) for x in m.groups()) if m else None


def list_versions():
    out = sh("gh", "release", "list", "--repo", REPO, "--limit", "200",
             "--json", "tagName", "-q", ".[].tagName")
    vs = []
    for tag in out.splitlines():
        tag = tag.strip()
        if not tag.startswith("v"):
            continue
        t = semver_tuple(tag[1:])
        if t and t >= MIN:
            vs.append(tag[1:])
    return sorted(set(vs), key=semver_tuple)


def parse_body(body):
    sections = []
    current = None
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("## "):  # top "What's new in …" title — skip
            continue
        if s == "---" or re.match(r"^###\s+(Installation|Requirements)\b", s):
            break  # install/requirements boilerplate begins
        h = HEADING.match(s)
        if h:
            current = {"title": h.group(1).strip(), "items": []}
            sections.append(current)
            continue
        b = BULLET.match(line)
        if b and current is not None:
            content = b.group(1).strip()
            m = BOLD_LEAD.match(content)
            if m:
                current["items"].append(
                    {"title": m.group(1).strip(), "text": m.group(2).strip()})
            else:
                current["items"].append({"text": content.replace("**", "")})
    return [sec for sec in sections if sec["items"]]


def main():
    OUT.mkdir(exist_ok=True)
    for v in list_versions():
        body = sh("gh", "release", "view", f"v{v}", "--repo", REPO,
                  "--json", "body", "-q", ".body")
        sections = parse_body(body)
        if not sections:
            print(f"skip {v}: no parseable sections", file=sys.stderr)
            continue
        doc = {"version": v, "sections": sections}
        (OUT / f"{v}.json").write_text(
            json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
        n = sum(len(sec["items"]) for sec in sections)
        print(f"wrote release-notes/{v}.json ({n} items)")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the backfill**

Run: `python3 scripts/backfill-release-notes.py`
Expected: a series of `wrote release-notes/<v>.json (...)` lines for 1.4.0 … latest; `release-notes/` now contains the JSON files.

- [ ] **Step 3: Spot-check the output**

Run: `cat release-notes/1.26.0.json` and one older file (e.g. `release-notes/1.4.0.json`).
Expected: valid JSON with `version` matching the filename, non-empty `sections`, items split into `title` + `text` where the source bullet had a `**Bold** — …` lead. Manually fix any file where parsing produced empty/garbled sections (best-effort source parse).

- [ ] **Step 4: Commit**

```bash
git add scripts/backfill-release-notes.py release-notes/
git commit -m "feat: backfill bundled release-notes JSON from GitHub Releases"
```

---

### Task 2: `ReleaseNotesStore` model + partition logic

Pure, testable loader + splitter. No UI, no UserDefaults.

**Files:**
- Create: `macos/Sources/Features/Update/ReleaseNotesStore.swift`
- Test: `macos/Tests/Update/ReleaseNotesStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct ReleaseNote: Decodable, Equatable { let title: String?; let text: String }`
  - `struct ReleaseNoteSection: Decodable, Equatable { let title: String; let items: [ReleaseNote] }`
  - `struct VersionNotes: Decodable, Equatable { let version: String; let sections: [ReleaseNoteSection] }`
  - `struct ReleaseNotesStore { init(all: [VersionNotes]); init(directory: URL?); static var bundledDirectory: URL?; static func isNewer(_ a: String, than b: String) -> Bool; func partitioned(previousSeen: String?, current: String) -> (new: [VersionNotes], installed: [VersionNotes]) }`

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/Update/ReleaseNotesStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Ghostty

struct ReleaseNotesStoreVersionCompareTests {
    @Test func numericOrderingBeatsLexicographic() {
        #expect(ReleaseNotesStore.isNewer("1.10.0", than: "1.9.0"))
        #expect(!ReleaseNotesStore.isNewer("1.9.0", than: "1.10.0"))
    }

    @Test func equalIsNotNewer() {
        #expect(!ReleaseNotesStore.isNewer("1.4.0", than: "1.4.0"))
    }

    @Test func patchAndMinorBumps() {
        #expect(ReleaseNotesStore.isNewer("1.4.1", than: "1.4.0"))
        #expect(ReleaseNotesStore.isNewer("2.0.0", than: "1.99.99"))
    }
}

struct ReleaseNotesStorePartitionTests {
    private func note(_ v: String) -> VersionNotes {
        VersionNotes(version: v, sections: [
            ReleaseNoteSection(title: "Fork Changes",
                               items: [ReleaseNote(title: "Feature \(v)", text: "did \(v)")])
        ])
    }

    private var store: ReleaseNotesStore {
        ReleaseNotesStore(all: ["1.3.0", "1.4.0", "1.5.0", "1.6.0"].map(note))
    }

    @Test func newIsAboveSeenAndCappedAtCurrent() {
        let (new, installed) = store.partitioned(previousSeen: "1.4.0", current: "1.6.0")
        #expect(new.map(\.version) == ["1.6.0", "1.5.0"])       // newest first, ≤ current
        #expect(installed.map(\.version) == ["1.4.0", "1.3.0"]) // ≤ seen, newest first
    }

    @Test func versionsNewerThanCurrentAreDropped() {
        // Dev case: bundle carries notes newer than the running build.
        let (new, _) = store.partitioned(previousSeen: "1.3.0", current: "1.4.0")
        #expect(new.map(\.version) == ["1.4.0"])                // 1.5/1.6 dropped (> current)
    }

    @Test func nilPreviousMeansEverythingUpToCurrentIsNew() {
        let (new, installed) = store.partitioned(previousSeen: nil, current: "1.5.0")
        #expect(new.map(\.version) == ["1.5.0", "1.4.0", "1.3.0"])
        #expect(installed.isEmpty)
    }

    @Test func repromptOnSameVersionHasNoNewNotes() {
        let (new, installed) = store.partitioned(previousSeen: "1.6.0", current: "1.6.0")
        #expect(new.isEmpty)
        #expect(installed.map(\.version) == ["1.6.0", "1.5.0", "1.4.0", "1.3.0"])
    }
}

struct ReleaseNotesStoreLoadTests {
    @Test func nilDirectoryLoadsNothing() {
        #expect(ReleaseNotesStore(directory: nil).all.isEmpty)
    }

    @Test func loadsAndSkipsGarbageFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"version":"1.4.0","sections":[{"title":"X","items":[{"text":"hi"}]}]}"#
            .write(to: dir.appendingPathComponent("1.4.0.json"), atomically: true, encoding: .utf8)
        try "not json".write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        let store = ReleaseNotesStore(directory: dir)
        #expect(store.all.map(\.version) == ["1.4.0"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `macos/`): `xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'`
Expected: FAIL to build — `cannot find 'ReleaseNotesStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos/Sources/Features/Update/ReleaseNotesStore.swift`:

```swift
import Foundation

/// One bullet in a release-notes section. `title` is the bold lead of a
/// `- **Title** — text` bullet; a plain bullet stores the whole line as `text`.
struct ReleaseNote: Decodable, Equatable {
    let title: String?
    let text: String
}

/// A titled group of notes within a version (e.g. "Fork Changes").
struct ReleaseNoteSection: Decodable, Equatable {
    let title: String
    let items: [ReleaseNote]
}

/// The release notes for one app version, as bundled in
/// `Contents/Resources/ghostty/release-notes/<version>.json`.
struct VersionNotes: Decodable, Equatable {
    let version: String
    let sections: [ReleaseNoteSection]
}

/// Loads bundled per-version release notes and splits them, relative to the
/// version the user last ran, into "new since your last version" and
/// "already installed". Pure and offline — no network, no UserDefaults.
struct ReleaseNotesStore {
    let all: [VersionNotes]

    /// Test seam.
    init(all: [VersionNotes]) { self.all = all }

    /// Decode every `*.json` in `directory`, skipping unreadable/garbage files.
    init(directory: URL?) {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { self.all = []; return }
        let decoder = JSONDecoder()
        self.all = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(VersionNotes.self, from: data)
            }
    }

    /// The bundled notes directory inside the app Resources, or nil if absent.
    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("release-notes", isDirectory: true)
    }

    /// True iff dotted-numeric version `a` is strictly newer than `b`
    /// (`.numeric` handles `1.10.0` > `1.9.0`).
    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// Split notes relative to `previousSeen`, capping "new" at `current` so a
    /// bundle carrying notes newer than the running build never shows them.
    /// Both groups are newest-first.
    func partitioned(previousSeen: String?, current: String)
        -> (new: [VersionNotes], installed: [VersionNotes])
    {
        var newer: [VersionNotes] = []
        var installed: [VersionNotes] = []
        for n in all {
            let atOrBelowCurrent = !Self.isNewer(n.version, than: current)
            let aboveSeen = previousSeen.map { Self.isNewer(n.version, than: $0) } ?? true
            if aboveSeen {
                if atOrBelowCurrent { newer.append(n) }  // else: > current → drop
            } else {
                installed.append(n)
            }
        }
        let byVersionDesc: (VersionNotes, VersionNotes) -> Bool = {
            Self.isNewer($0.version, than: $1.version)
        }
        return (newer.sorted(by: byVersionDesc), installed.sorted(by: byVersionDesc))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `macos/`):
```
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'
xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' -only-testing:GhosttyTests/ReleaseNotesStoreVersionCompareTests -only-testing:GhosttyTests/ReleaseNotesStorePartitionTests -only-testing:GhosttyTests/ReleaseNotesStoreLoadTests
```
Expected: PASS (all suites).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Update/ReleaseNotesStore.swift macos/Tests/Update/ReleaseNotesStoreTests.swift
git commit -m "feat: ReleaseNotesStore — load + partition bundled release notes"
```

---

### Task 3: `WhatsNewTracking` last-seen version snapshot

**Files:**
- Create: `macos/Sources/Features/Update/WhatsNewTracking.swift`
- Test: `macos/Tests/Update/WhatsNewTrackingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum WhatsNewTracking { static let defaultsKey: String; static var currentAppVersion: String; private(set) static var previousSeenVersion: String?; @discardableResult static func snapshotAndAdvance(current: String, defaults: UserDefaults = .standard) -> String? }`

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/Update/WhatsNewTrackingTests.swift`:

```swift
import Foundation
import Testing
@testable import Ghostty

struct WhatsNewTrackingTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "whatsnew-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func firstRunReturnsNilThenStoresCurrent() {
        let (defaults, suite) = freshDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let prev = WhatsNewTracking.snapshotAndAdvance(current: "1.4.0", defaults: defaults)
        #expect(prev == nil)
        #expect(defaults.string(forKey: WhatsNewTracking.defaultsKey) == "1.4.0")
    }

    @Test func secondRunReturnsPreviousThenAdvances() {
        let (defaults, suite) = freshDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        _ = WhatsNewTracking.snapshotAndAdvance(current: "1.4.0", defaults: defaults)
        let prev = WhatsNewTracking.snapshotAndAdvance(current: "1.6.0", defaults: defaults)
        #expect(prev == "1.4.0")
        #expect(defaults.string(forKey: WhatsNewTracking.defaultsKey) == "1.6.0")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `macos/`): `xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'`
Expected: FAIL to build — `cannot find 'WhatsNewTracking' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos/Sources/Features/Update/WhatsNewTracking.swift`:

```swift
import Foundation

/// Tracks the app version the user last ran, so the agent-update dialog can
/// show only the notes that accrued since then. Snapshotted once at launch
/// (before session restore can fire the dialog) and read later by the dialog.
enum WhatsNewTracking {
    static let defaultsKey = "whatsNewLastSeenVersion"

    /// The version stored BEFORE this launch advanced it — the anchor the
    /// dialog splits on. nil on the very first instrumented run.
    private(set) static var previousSeenVersion: String?

    /// This build's marketing version (`CFBundleShortVersionString`).
    static var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Read the stored last-seen version into `previousSeenVersion`, then store
    /// `current`. Idempotent within a launch; call once early in launch.
    @discardableResult
    static func snapshotAndAdvance(current: String, defaults: UserDefaults = .standard) -> String? {
        let prev = defaults.string(forKey: defaultsKey)
        defaults.set(current, forKey: defaultsKey)
        previousSeenVersion = prev
        return prev
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `macos/`):
```
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'
xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' -only-testing:GhosttyTests/WhatsNewTrackingTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Update/WhatsNewTracking.swift macos/Tests/Update/WhatsNewTrackingTests.swift
git commit -m "feat: WhatsNewTracking — snapshot last-seen app version at launch"
```

---

### Task 4: `WhatsNewNotesView` (SwiftUI)

Renders the two note groups + collapsed toggle inside a fixed-size scroll area.

**Files:**
- Create: `macos/Sources/Features/Update/WhatsNewNotesView.swift`

**Interfaces:**
- Consumes: `VersionNotes`, `ReleaseNoteSection`, `ReleaseNote` (Task 2).
- Produces: `struct WhatsNewNotesView: View { init(newNotes: [VersionNotes], installedNotes: [VersionNotes]) }` and `static let preferredSize: NSSize`.

- [ ] **Step 1: Write the implementation**

Create `macos/Sources/Features/Update/WhatsNewNotesView.swift`:

```swift
import SwiftUI

/// The "What's new" area shown as the agent-update dialog's accessory view.
/// Notes newer than the user's last version are always visible; older
/// ("already installed") notes hide behind a collapsed disclosure. The fixed
/// frame + internal ScrollView means expanding the disclosure never resizes
/// the host NSAlert. Fully offline — rendered from bundled JSON.
struct WhatsNewNotesView: View {
    let newNotes: [VersionNotes]
    let installedNotes: [VersionNotes]

    @State private var showInstalled = false

    /// The size the host NSHostingView is pinned to.
    static let preferredSize = NSSize(width: 420, height: 240)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What’s new")
                    .font(.headline)

                if newNotes.isEmpty {
                    Text("No new release notes since your last update.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(newNotes, id: \.version) { versionBlock($0) }
                }

                if !installedNotes.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showInstalled) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(installedNotes, id: \.version) { versionBlock($0) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Show changes already installed")
                            .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
    }

    @ViewBuilder
    private func versionBlock(_ v: VersionNotes) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(v.version)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(v.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        itemRow(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ReleaseNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let title = item.title {
                    Text(title).font(.body.weight(.semibold))
                    Text(item.text).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(item.text).font(.body)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run (from `macos/`): `xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/Update/WhatsNewNotesView.swift
git commit -m "feat: WhatsNewNotesView — offline SwiftUI render of bundled notes"
```

---

### Task 5: Bundle `release-notes/` into the app

**Files:**
- Modify: `src/build/GhosttyResources.zig` (after the `src/viewer` install block, ~141)

**Interfaces:**
- Consumes: the `release-notes/` directory (Task 1).
- Produces: `Contents/Resources/ghostty/release-notes/*.json` in the built app (via the `share/ghostty` folder reference), readable at `ReleaseNotesStore.bundledDirectory`.

- [ ] **Step 1: Add the install step**

In `src/build/GhosttyResources.zig`, immediately after the viewer install block (the one ending at the `try steps.append(...)` around line 140), add:

```zig
    // Release notes: bundled per-version "What's new" JSON, keyed by app
    // version, rendered offline in the agent-update dialog. Rides the
    // `share/ghostty` folder reference into the macOS bundle Resources.
    {
        const install_step = b.addInstallDirectory(.{
            .source_dir = b.path("release-notes"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = b.pathJoin(&.{ "ghostty", "release-notes" }),
        });
        try steps.append(b.allocator, &install_step.step);
    }
```

- [ ] **Step 2: Build and verify the notes land in the bundle**

Run (from repo root):
```
zig build -Doptimize=Debug
ls zig-out/share/ghostty/release-notes/ | head
ls zig-out/Ghoztty-Debug.app/Contents/Resources/ghostty/release-notes/ | head
```
Expected: both list the `*.json` files (the second confirms the folder reference copied them into the app bundle).

- [ ] **Step 3: Commit**

```bash
git add src/build/GhosttyResources.zig
git commit -m "build(macos): bundle release-notes JSON into the app Resources"
```

---

### Task 6: New copy + accessory wiring in the dialog, launch snapshot

**Files:**
- Modify: `macos/Sources/Features/Remote/LocalAgentManager.swift` (`promptAndRefreshLocalAgent`, ~784; add `import SwiftUI`; add `makeUpgradeAlert` factory)
- Modify: `macos/Sources/App/macOS/AppDelegate.swift` (`applicationDidFinishLaunching`, ~244)
- Test: `macos/Tests/Remote/UpgradeAlertTests.swift`

**Interfaces:**
- Consumes: `ReleaseNotesStore`, `WhatsNewTracking`, `WhatsNewNotesView`.
- Produces: `@MainActor static func LocalAgentManager.makeUpgradeAlert(liveSessionCount: Int, previousSeen: String?, current: String, store: ReleaseNotesStore) -> NSAlert`.

- [ ] **Step 1: Write the failing test**

Create `macos/Tests/Remote/UpgradeAlertTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct UpgradeAlertTests {
    private func sampleStore() -> ReleaseNotesStore {
        ReleaseNotesStore(all: [
            VersionNotes(version: "1.5.0", sections: [
                ReleaseNoteSection(title: "Fork Changes",
                                   items: [ReleaseNote(title: "New thing", text: "does X")])
            ])
        ])
    }

    @Test func copyIsPluralAndBrandedGhoztty() {
        let alert = LocalAgentManager.makeUpgradeAlert(
            liveSessionCount: 3, previousSeen: "1.4.0", current: "1.5.0", store: sampleStore())
        #expect(alert.messageText == "Restart to finish updating Ghoztty?")
        #expect(alert.informativeText.contains("3 open terminal sessions"))
        #expect(!alert.informativeText.lowercased().contains("ghostty ")) // no Z-less leak
        #expect(alert.buttons.map(\.title) == ["Update Now", "Later"])
        #expect(alert.alertStyle == .warning)
    }

    @Test func singularSessionText() {
        let alert = LocalAgentManager.makeUpgradeAlert(
            liveSessionCount: 1, previousSeen: "1.4.0", current: "1.5.0", store: sampleStore())
        #expect(alert.informativeText.contains("1 open terminal session —"))
    }

    @Test func accessoryPresentWhenNotesExistAbsentWhenEmpty() {
        let withNotes = LocalAgentManager.makeUpgradeAlert(
            liveSessionCount: 2, previousSeen: "1.4.0", current: "1.5.0", store: sampleStore())
        #expect(withNotes.accessoryView != nil)

        let noNotes = LocalAgentManager.makeUpgradeAlert(
            liveSessionCount: 2, previousSeen: "1.4.0", current: "1.5.0",
            store: ReleaseNotesStore(all: []))
        #expect(noNotes.accessoryView == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `macos/`): `xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'`
Expected: FAIL to build — `type 'LocalAgentManager' has no member 'makeUpgradeAlert'`.

- [ ] **Step 3: Add `import SwiftUI` and the alert factory; rewire `promptAndRefreshLocalAgent`**

In `macos/Sources/Features/Remote/LocalAgentManager.swift`, ensure `import SwiftUI` is present near the other imports (add it if missing).

Replace the body of `promptAndRefreshLocalAgent` (currently building the `NSAlert` inline, ~784-798) with a call to a new factory. The final code:

```swift
    /// Build the mandatory agent-restart confirmation, including the offline
    /// "What's new" accessory when bundled notes are available. Pure w.r.t.
    /// side effects (no runModal) so it is unit-testable.
    @MainActor
    static func makeUpgradeAlert(
        liveSessionCount n: Int,
        previousSeen: String?,
        current: String,
        store: ReleaseNotesStore
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Restart to finish updating Ghoztty?"
        let sessions = "\(n) open terminal session\(n == 1 ? "" : "s")"
        alert.informativeText = "Ghoztty keeps your terminal sessions running in the background. Finishing this update restarts that background process, which will close your \(sessions) — they can’t be carried across the update. You can keep working instead: Ghoztty updates automatically the next time no sessions are open."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .warning

        let split = store.partitioned(previousSeen: previousSeen, current: current)
        if !split.new.isEmpty || !split.installed.isEmpty {
            let host = NSHostingView(
                rootView: WhatsNewNotesView(newNotes: split.new, installedNotes: split.installed))
            host.frame = NSRect(origin: .zero, size: WhatsNewNotesView.preferredSize)
            alert.accessoryView = host
        }
        return alert
    }

    /// The mandatory confirmation before a destructive agent restart while
    /// sessions are live. On confirm → refresh (live windows recover/relaunch);
    /// on defer → nothing (the agent refreshes automatically once idle).
    @MainActor
    private func promptAndRefreshLocalAgent(liveSessionCount n: Int, running: String?, bundled: String) {
        let alert = Self.makeUpgradeAlert(
            liveSessionCount: n,
            previousSeen: WhatsNewTracking.previousSeenVersion,
            current: WhatsNewTracking.currentAppVersion,
            store: ReleaseNotesStore(directory: ReleaseNotesStore.bundledDirectory))
        guard alert.runModal() == .alertFirstButtonReturn else {
            Self.logger.info("user deferred destructive agent refresh (\(n) live session(s))")
            return
        }
        Self.logger.info("user confirmed destructive agent refresh (running \(running ?? "<pre-versioned>", privacy: .public) → bundled \(bundled, privacy: .public), \(n) live session(s))")
        forceRefreshLocalAgent(reconnect: true)
    }
```

(Keep the surrounding methods — `refreshLocalAgentIfStale`, `forceRefreshLocalAgent`, `postAgentRefreshNotice` — unchanged.)

- [ ] **Step 4: Snapshot the last-seen version at launch**

In `macos/Sources/App/macOS/AppDelegate.swift`, inside `applicationDidFinishLaunching(_:)`, add early in the method (after `super`/existing first lines, before window/restore work):

```swift
        // Record the app version the user last ran, before session restore can
        // surface the agent-update dialog, so "What's new" shows only the notes
        // accrued since then.
        WhatsNewTracking.snapshotAndAdvance(current: WhatsNewTracking.currentAppVersion)
```

- [ ] **Step 5: Run tests to verify they pass**

Run (from `macos/`):
```
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'
xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' -only-testing:GhosttyTests/UpgradeAlertTests
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Features/Remote/LocalAgentManager.swift macos/Sources/App/macOS/AppDelegate.swift macos/Tests/Remote/UpgradeAlertTests.swift
git commit -m "feat: reframe agent-update dialog copy + attach What's new accessory"
```

---

### Task 7: Release process + docs

Keep the bundled notes current on every future release, and document the format.

**Files:**
- Create: `release-notes/README.md`
- Modify: `.claude/commands/release.md` (Step 2, ~36-56; Step 6, ~103-123)

**Interfaces:** none (docs only).

- [ ] **Step 1: Document the notes format**

Create `release-notes/README.md`:

```markdown
# Bundled release notes

Each `<version>.json` here is the offline "What's new" shown in Ghoztty's
agent-restart update dialog. Files are keyed by the app's
`CFBundleShortVersionString` (bare semver, no leading `v`) and bundled into the
app via `src/build/GhosttyResources.zig` → `Contents/Resources/ghostty/release-notes/`.

Shape:

```json
{
  "version": "1.26.0",
  "sections": [
    { "title": "Fork Changes",
      "items": [
        { "title": "Feature name", "text": "What the user can now do." },
        { "text": "A plain note with no bold lead." }
      ] }
  ]
}
```

- `title` on an item is the bold lead of a `- **Title** — text` bullet; omit it
  for a plain bullet.
- Add a new `<version>.json` as part of each release (see
  `.claude/commands/release.md`, Step 2) BEFORE tagging, so it ships in the build.
- Historical files were generated by `scripts/backfill-release-notes.py` from
  GitHub Releases; re-run it to regenerate past files.
```

- [ ] **Step 2: Update the release command**

In `.claude/commands/release.md`, at the end of **Step 2 (Generate Release Notes)** (after the "Present the notes and ask the user to approve" line), add:

```markdown

**Also author the bundled notes.** From the same approved notes, write
`release-notes/<version>.json` (the offline "What's new" for the update
dialog — schema in `release-notes/README.md`). Commit it with the release
commit **before** tagging (Step 3) so it ships in the app bundle. The JSON and
the GitHub release body (Step 6) are the same content in two shapes — keep them
in sync. Example:

```json
{
  "version": "1.4.1",
  "sections": [
    { "title": "Fork Changes",
      "items": [ { "title": "Feature", "text": "What the user can now do." } ] }
  ]
}
```
```

In **Step 6 (Publish Release)**, add a one-line note after the `gh release edit` block:

```markdown
The bundled `release-notes/<version>.json` (authored in Step 2) already carries
these notes for the in-app dialog; this GitHub body is the same content as
markdown.
```

- [ ] **Step 3: Commit**

```bash
git add release-notes/README.md .claude/commands/release.md
git commit -m "docs: document bundled release-notes format + release step"
```

---

### Task 8: Full build + manual verification in the debug app

**Files:** none (verification only).

- [ ] **Step 1: Clean build**

Run (from repo root): `zig build -Doptimize=Debug`
Expected: BUILD SUCCEEDED; `zig-out/Ghoztty-Debug.app` updated.

- [ ] **Step 2: Run the full new test suites**

Run (from `macos/`):
```
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'
xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' \
  -only-testing:GhosttyTests/ReleaseNotesStoreVersionCompareTests \
  -only-testing:GhosttyTests/ReleaseNotesStorePartitionTests \
  -only-testing:GhosttyTests/ReleaseNotesStoreLoadTests \
  -only-testing:GhosttyTests/WhatsNewTrackingTests \
  -only-testing:GhosttyTests/UpgradeAlertTests
```
Expected: all PASS.

- [ ] **Step 3: Confirm notes are in the bundle**

Run: `ls zig-out/Ghoztty-Debug.app/Contents/Resources/ghostty/release-notes/`
Expected: the `*.json` files are present.

- [ ] **Step 4: Visually exercise the real dialog**

The dialog only fires on genuine agent staleness + live sessions, which is hard to force same-day (staleness compares agent build-stamp DATE prefixes). To see the real dialog with real bundled notes, temporarily (do NOT commit) add a debug menu action that calls the factory and runs it, then revert:

1. In `macos/Sources/App/macOS/AppDelegate.swift`, temporarily seed a prior version and open the alert once after launch:
   ```swift
   // TEMP — verification only, revert before commit.
   UserDefaults.standard.set("1.23.0", forKey: WhatsNewTracking.defaultsKey)
   ```
   and build with a real release version so notes above/below the divider both appear:
   ```
   zig build -Doptimize=Debug -Dversion-string=1.26.0
   ```
2. Add a TEMP call (e.g. behind a menu item or a one-shot `DispatchQueue.main.asyncAfter`) that runs:
   ```swift
   let store = ReleaseNotesStore(directory: ReleaseNotesStore.bundledDirectory)
   _ = LocalAgentManager.makeUpgradeAlert(
       liveSessionCount: 3, previousSeen: "1.23.0", current: "1.26.0", store: store).runModal()
   ```
3. Launch `zig-out/Ghoztty-Debug.app`, confirm by eye:
   - Title/subtext read correctly, "Ghoztty" spelled with a Z, plural "3 open terminal sessions".
   - "What's new" lists 1.24.0–1.26.0 newest-first above the divider.
   - "Show changes already installed" is collapsed; expanding it scrolls older versions INSIDE the box (the alert does not resize).
   - Buttons are "Update Now" / "Later".
4. **Revert** all TEMP edits and rebuild `zig build -Doptimize=Debug`.

- [ ] **Step 5: Final commit (only if any non-TEMP fix was needed)**

If Step 4 surfaced a real issue and you fixed it (in committed code, not the TEMP scaffold), commit that fix with a descriptive message. Otherwise nothing to commit here.

---

## Self-Review

**Spec coverage:**
- Copy reframe → Task 6 (factory + copy, tested for plural/brand). ✓
- Bundled JSON format + location → Tasks 1, 5; documented Task 7. ✓
- Backfill → Task 1. ✓
- "Since last update" tracking → Task 3; partition/cap → Task 2. ✓
- Divider + "already installed" toggle → Task 4. ✓
- Render via NSAlert accessory, offline, no web view → Tasks 4, 6. ✓
- Preserve gating / idle silent path → Task 6 (surrounding methods untouched). ✓
- Release-process step → Task 7. ✓
- Verify in debug app → Task 8. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code. The only "TEMP" content is the explicitly-reverted verification scaffold in Task 8. ✓

**Type consistency:** `ReleaseNotesStore`, `VersionNotes`, `ReleaseNoteSection`, `ReleaseNote`, `partitioned(previousSeen:current:)`, `isNewer(_:than:)`, `bundledDirectory`, `WhatsNewTracking.snapshotAndAdvance(current:defaults:)`, `previousSeenVersion`, `currentAppVersion`, `WhatsNewNotesView(newNotes:installedNotes:)`, `preferredSize`, `makeUpgradeAlert(liveSessionCount:previousSeen:current:store:)` — names/signatures match across Tasks 2/3/4/6/8. ✓
