# Multi-runtime Agent Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Ghoztty macOS app register Ghoztty with Claude Code and GitHub Copilot CLI by writing skills + a status-banner hook directly into each agent's config directory, behind a runtime abstraction that accepts more runtimes later.

**Architecture:** A `RuntimeAgent` enum drives a `RuntimeIntegration` (an ordered list of `IntegrationComponent`s: skills + hooks) built by a factory. Skills and the banner script are bundled in the app and written verbatim; per-runtime hook data lives in `*HookSpec` values consumed by a shared `HookComponent` with two ownership strategies (dedicated-file for Copilot, merged-fragment for Claude). All writes are marker-guarded, drift-detected, atomic, and rolled back on failure.

**Tech Stack:** Swift (macOS app target `Ghostty`), Swift Testing (`import Testing`, `@Test`, `#expect`), Foundation `FileManager`, Darwin `open(2)` for hardened writes, `OSLog`. Build/test via `macos/build.nu`.

## Global Constraints

- Build the macOS app with `macos/build.nu` (NOT `zig build`). Build: `macos/build.nu --scheme Ghostty --configuration Debug --action build`. Test: `macos/build.nu --action test`.
- Never modify, replace, or touch `/Applications/Ghoztty.app`. Test only against the debug build.
- Swift formatting/lint: `swiftlint lint --strict --fix`.
- Every installer type takes an injected `homeDirectoryURL: URL` and `fileManager: FileManager` so tests run against a temp home. No test may touch the real `~/.claude`, `~/.copilot`, or `~/.config`.
- The shared `ghoztty-banner.sh` is NEVER edited to add a runtime. Per-runtime divergence lives only in `RuntimeAgent` cases + `*HookSpec` + factory wiring + strategy choice.
- Hook payload normalization uses `awk`/parameter-expansion, never `jq`.
- Agent-controlled `prompt` text is passed via argv/stdin, never interpolated into a shell command string; truncated and stripped of C0/C1/ESC bytes before reaching `+set-banner`.
- The generated hook references the banner script at the stable path `~/.config/ghoztty/hooks/ghoztty-banner.sh` — never a path inside `Ghoztty.app`.
- Logger: `Logger(subsystem: Bundle.loggerSubsystem, category: "AgentIntegration")`.
- Do NOT create issues or PRs (repo AGENTS.md rule).

---

## File Structure

New code under `macos/Sources/Features/Setup/`:

- `RuntimeAgent.swift` — enum `.claude`/`.copilot`; `configDirectoryName`, `displayName`, `configDirectoryURL(homeDirectoryURL:)`.
- `ComponentInstallState.swift` — `ComponentInstallState` + `RuntimeIntegrationState` enums.
- `ManagedFile.swift` — hardened marker-guarded atomic write / drift / remove helpers (shared).
- `SkillComponent.swift` — writes bundled `SKILL.md` files per runtime.
- `BannerScriptInstaller.swift` — copies bundled `ghoztty-banner.sh` to `~/.config/ghoztty/hooks/`.
- `HookSpec.swift` — `HookSpec` protocol + `NormalizedPayload` contract + `HookEventCommands`.
- `CopilotHookSpec.swift` — dedicated-file spec (`~/.copilot/hooks/ghoztty.json`).
- `ClaudeHookSpec.swift` — merged-fragment spec (`~/.claude/settings.json`) + external-plugin detection.
- `HookComponent.swift` — consumes a `HookSpec`, applies the ownership strategy.
- `RuntimeIntegration.swift` — `IntegrationComponent` + `RuntimeIntegration` (aggregate state, install/rollback, uninstall).
- `RuntimeIntegrationFactory.swift` — composes `[skills, hooks]` per agent + install gate.
- `AppDelegate+Setup.swift` — MODIFY: generalize dialog + menu action; remove `ClaudeCodeIntegration.swift`.

New bundled assets under `macos/Resources/Ghoztty/` (folder reference in `project.pbxproj`):
- `skills/ghoztty/SKILL.md`, `skills/process-feedback/SKILL.md`, `hooks/ghoztty-banner.sh`.

Tests under `macos/Tests/Ghostty/`: one file per component (Swift Testing).

Docs: `HACKING.md` (or `CLAUDE.md`) gets a Setup-subsystem paragraph.

---

### Task 1: Bundle assets + resource wiring

**Files:**
- Create: `macos/Resources/Ghoztty/skills/ghoztty/SKILL.md` (copied from the external plugin repo, verbatim)
- Create: `macos/Resources/Ghoztty/skills/process-feedback/SKILL.md` (copied verbatim)
- Create: `macos/Resources/Ghoztty/hooks/ghoztty-banner.sh` (copied, then de-Claude-ified in Task 5's dependency — here copied verbatim first)
- Create: `macos/Sources/Features/Setup/GhosttyAssets.swift`
- Modify: `macos/Ghostty.xcodeproj/project.pbxproj` (add `Ghoztty` folder reference to Copy Bundle Resources)
- Test: `macos/Tests/Ghostty/GhosttyAssetsTests.swift`

**Interfaces:**
- Produces: `enum GhosttyAssets { static var rootURL: URL { get throws }; static func skillMarkdown(_ name: String) throws -> String; static func bannerScript() throws -> String }` where `name ∈ {"ghoztty","process-feedback"}`. Throws `GhosttyAssetsError.missing(String)`.

- [ ] **Step 1: Copy the three asset files into the repo**

```bash
cd /Users/zaranylucas/src/zal/ghoztty/macos
mkdir -p Resources/Ghoztty/skills/ghoztty Resources/Ghoztty/skills/process-feedback Resources/Ghoztty/hooks
gh api repos/dzearing/ghoztty-claude-plugin/contents/skills/ghoztty/SKILL.md --jq .content | base64 -d > Resources/Ghoztty/skills/ghoztty/SKILL.md
gh api repos/dzearing/ghoztty-claude-plugin/contents/skills/process-feedback/SKILL.md --jq .content | base64 -d > Resources/Ghoztty/skills/process-feedback/SKILL.md
gh api repos/dzearing/ghoztty-claude-plugin/contents/hooks/ghoztty-banner.sh --jq .content | base64 -d > Resources/Ghoztty/hooks/ghoztty-banner.sh
chmod +x Resources/Ghoztty/hooks/ghoztty-banner.sh
```

- [ ] **Step 2: Write the failing test**

```swift
// macos/Tests/Ghostty/GhosttyAssetsTests.swift
import Foundation
import Testing
@testable import Ghostty

struct GhosttyAssetsTests {
    @Test func bundlesSkillsAndBannerScript() throws {
        #expect(try GhosttyAssets.skillMarkdown("ghoztty").contains("Ghoztty"))
        #expect(try GhosttyAssets.skillMarkdown("process-feedback").contains("feedback"))
        let script = try GhosttyAssets.bannerScript()
        #expect(script.hasPrefix("#!/bin/bash"))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `macos/build.nu --action test`
Expected: FAIL — `GhosttyAssets` is undefined.

- [ ] **Step 4: Implement `GhosttyAssets`**

```swift
// macos/Sources/Features/Setup/GhosttyAssets.swift
import Foundation

enum GhosttyAssetsError: Error, LocalizedError {
    case missing(String)
    var errorDescription: String? {
        switch self {
        case .missing(let what): "Bundled Ghoztty asset missing: \(what)"
        }
    }
}

/// Reads the skill markdown + banner script bundled under `Ghoztty/` in the app
/// bundle's Resources. The bundle is the source of truth for the app-install path.
enum GhosttyAssets {
    static var rootURL: URL {
        get throws {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("Ghoztty", isDirectory: true),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw GhosttyAssetsError.missing("Ghoztty resources root")
            }
            return url
        }
    }

    static func skillMarkdown(_ name: String) throws -> String {
        let url = try rootURL
            .appendingPathComponent("skills/\(name)/SKILL.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw GhosttyAssetsError.missing("skill \(name)")
        }
        return text
    }

    static func bannerScript() throws -> String {
        let url = try rootURL.appendingPathComponent("hooks/ghoztty-banner.sh")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw GhosttyAssetsError.missing("banner script")
        }
        return text
    }
}
```

- [ ] **Step 5: Wire the resource folder into the Xcode project**

Add a blue **folder reference** for `Resources/Ghoztty` to the app target's Copy Bundle Resources phase, so it lands at `Ghoztty/` in the bundle. In `macos/Ghostty.xcodeproj/project.pbxproj`, mirror the existing `terminfo` folder-reference pattern:
- Add a `PBXFileReference` with `lastKnownFileType = folder; name = Ghoztty; path = Resources/Ghoztty; sourceTree = "<group>";`
- Add a matching `PBXBuildFile` and list it in the app target's `Resources` `PBXResourcesBuildPhase` `files` array.
(If editing pbxproj by hand is unreliable, open the project in Xcode and drag `Resources/Ghoztty` in as a folder reference.)

- [ ] **Step 6: Run test to verify it passes**

Run: `macos/build.nu --action test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add macos/Resources/Ghoztty macos/Sources/Features/Setup/GhosttyAssets.swift macos/Tests/Ghostty/GhosttyAssetsTests.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "macos: bundle Ghoztty agent-integration assets (skills + banner script)"
```

---

### Task 2: `RuntimeAgent` + state enums

**Files:**
- Create: `macos/Sources/Features/Setup/RuntimeAgent.swift`
- Create: `macos/Sources/Features/Setup/ComponentInstallState.swift`
- Test: `macos/Tests/Ghostty/RuntimeAgentTests.swift`

**Interfaces:**
- Produces: `enum RuntimeAgent: String, CaseIterable, Sendable { case claude, copilot }` with `var configDirectoryName: String`, `var displayName: String`, `func configDirectoryURL(homeDirectoryURL: URL) -> URL`.
- Produces: `enum ComponentInstallState: Equatable, Sendable { case notInstalled, installed, outdated }` and `enum RuntimeIntegrationState: Equatable, Sendable { case notInstalled, installed, outdated }`.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Ghostty/RuntimeAgentTests.swift
import Foundation
import Testing
@testable import Ghostty

struct RuntimeAgentTests {
    @Test func configDirsAndNames() {
        #expect(RuntimeAgent.claude.configDirectoryName == ".claude")
        #expect(RuntimeAgent.copilot.configDirectoryName == ".copilot")
        #expect(RuntimeAgent.copilot.displayName == "Copilot CLI")
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(RuntimeAgent.claude.configDirectoryURL(homeDirectoryURL: home).path == "/tmp/home/.claude")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `macos/build.nu --action test`
Expected: FAIL — `RuntimeAgent` undefined.

- [ ] **Step 3: Implement the enums**

```swift
// macos/Sources/Features/Setup/ComponentInstallState.swift
import Foundation

enum ComponentInstallState: Equatable, Sendable {
    case notInstalled
    case installed
    case outdated
}

enum RuntimeIntegrationState: Equatable, Sendable {
    case notInstalled
    case installed
    case outdated
}
```

```swift
// macos/Sources/Features/Setup/RuntimeAgent.swift
import Foundation

/// A coding-agent runtime Ghoztty can register with. One case per supported CLI.
enum RuntimeAgent: String, CaseIterable, Sendable {
    case claude
    case copilot

    /// Home-relative config directory the runtime owns.
    var configDirectoryName: String {
        switch self {
        case .claude: ".claude"
        case .copilot: ".copilot"
        }
    }

    /// User-facing name for dialogs and summaries.
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .copilot: "Copilot CLI"
        }
    }

    func configDirectoryURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(configDirectoryName, isDirectory: true)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `macos/build.nu --action test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Setup/RuntimeAgent.swift macos/Sources/Features/Setup/ComponentInstallState.swift macos/Tests/Ghostty/RuntimeAgentTests.swift
git commit -m "macos: add RuntimeAgent registry and install-state enums"
```

---

### Task 3: `ManagedFile` — hardened marker-guarded atomic write

**Files:**
- Create: `macos/Sources/Features/Setup/ManagedFile.swift`
- Test: `macos/Tests/Ghostty/ManagedFileTests.swift`

**Interfaces:**
- Produces:
  - `enum ManagedFileError: Error, Equatable { case notManaged(URL); case symlinkRefused(URL) }`
  - `enum ManagedFile { static func state(at:URL, expected:String, marker:String) -> ComponentInstallState; static func write(_ contents:String, to:URL, marker:String, mode:mode_t, fileManager:FileManager) throws; static func removeIfManaged(at:URL, marker:String, fileManager:FileManager) throws }`
- Contract: `write` refuses (throws `.notManaged`) if a file already exists at `to` and does NOT contain `marker`; refuses (throws `.symlinkRefused`) if the final path is a symlink; writes via a same-directory `O_CREAT|O_EXCL|O_NOFOLLOW` temp file at `mode`, then `rename(2)`. `state` returns `.installed` iff file exists, contains `marker`, and equals `expected`; `.outdated` if it contains `marker` but differs; `.notInstalled` if absent or lacks `marker`.

- [ ] **Step 1: Write the failing tests**

```swift
// macos/Tests/Ghostty/ManagedFileTests.swift
import Foundation
import Testing
@testable import Ghostty

struct ManagedFileTests {
    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesThenReportsInstalled() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ghoztty.json")
        let body = "{}\n// ghoztty-managed"
        try ManagedFile.write(body, to: url, marker: "ghoztty-managed", mode: 0o600, fileManager: .default)
        #expect(ManagedFile.state(at: url, expected: body, marker: "ghoztty-managed") == .installed)
    }

    @Test func driftReportsOutdated() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ghoztty.json")
        try ManagedFile.write("old // ghoztty-managed", to: url, marker: "ghoztty-managed", mode: 0o600, fileManager: .default)
        #expect(ManagedFile.state(at: url, expected: "new // ghoztty-managed", marker: "ghoztty-managed") == .outdated)
    }

    @Test func refusesUnmanagedOverwrite() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ghoztty.json")
        try "user's own file".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ManagedFileError.self) {
            try ManagedFile.write("x // ghoztty-managed", to: url, marker: "ghoztty-managed", mode: 0o600, fileManager: .default)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "user's own file")
    }

    @Test func removeOnlyManaged() throws {
        let dir = try tempDir()
        let managed = dir.appendingPathComponent("a")
        let foreign = dir.appendingPathComponent("b")
        try ManagedFile.write("m // ghoztty-managed", to: managed, marker: "ghoztty-managed", mode: 0o600, fileManager: .default)
        try "foreign".write(to: foreign, atomically: true, encoding: .utf8)
        try ManagedFile.removeIfManaged(at: managed, marker: "ghoztty-managed", fileManager: .default)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(throws: ManagedFileError.self) {
            try ManagedFile.removeIfManaged(at: foreign, marker: "ghoztty-managed", fileManager: .default)
        }
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `macos/build.nu --action test`
Expected: FAIL — `ManagedFile` undefined.

- [ ] **Step 3: Implement `ManagedFile`**

```swift
// macos/Sources/Features/Setup/ManagedFile.swift
import Foundation

enum ManagedFileError: Error, Equatable {
    case notManaged(URL)
    case symlinkRefused(URL)
    case writeFailed(String)
}

/// Marker-guarded, symlink-refusing, atomic file writer for Ghoztty-managed
/// artifacts in shared config dirs. Only ever overwrites/removes files that
/// carry `marker`, so a user's own same-named file is never touched.
enum ManagedFile {
    static func state(at url: URL, expected: String, marker: String) -> ComponentInstallState {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return .notInstalled
        }
        guard contents.contains(marker) else { return .notInstalled }
        return contents == expected ? .installed : .outdated
    }

    static func write(_ contents: String, to url: URL, marker: String, mode: mode_t, fileManager: FileManager) throws {
        // Refuse to clobber a same-named file that isn't ours.
        if fileManager.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8)
            guard existing.contains(marker) else { throw ManagedFileError.notManaged(url) }
        }
        // Refuse a symlink at the final path (dotfiles hazard).
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw ManagedFileError.symlinkRefused(url)
        }

        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".ghoztty-\(UUID().uuidString).tmp")

        let fd = tmp.path.withCString { cpath in
            open(cpath, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        }
        guard fd >= 0 else { throw ManagedFileError.writeFailed("open temp failed: \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        let data = Array(contents.utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else {
            try? fileManager.removeItem(at: tmp)
            throw ManagedFileError.writeFailed("short write")
        }
        // Ensure mode isn't loosened by umask.
        _ = tmp.path.withCString { chmod($0, mode) }

        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
    }

    static func removeIfManaged(at url: URL, marker: String, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard contents.contains(marker) else { throw ManagedFileError.notManaged(url) }
        try fileManager.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `macos/build.nu --action test`
Expected: PASS (all four `ManagedFileTests`).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Setup/ManagedFile.swift macos/Tests/Ghostty/ManagedFileTests.swift
git commit -m "macos: add ManagedFile marker-guarded atomic writer"
```

---

### Task 4: `SkillComponent`

**Files:**
- Create: `macos/Sources/Features/Setup/SkillComponent.swift`
- Test: `macos/Tests/Ghostty/SkillComponentTests.swift`

**Interfaces:**
- Consumes: `RuntimeAgent`, `GhosttyAssets`, `ManagedFile`, `ComponentInstallState`.
- Produces: `struct SkillComponent { init(agent:RuntimeAgent, homeDirectoryURL:URL, fileManager:FileManager); func state() -> ComponentInstallState; func install() throws; func uninstall() throws }`. Writes `~/<cfg>/skills/ghoztty/SKILL.md` and `~/<cfg>/skills/process-feedback/SKILL.md`. Skill files carry an HTML-comment marker `<!-- ghoztty-managed -->` appended to the bundled markdown so `ManagedFile` can recognize them.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Ghostty/SkillComponentTests.swift
import Foundation
import Testing
@testable import Ghostty

struct SkillComponentTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installsBothSkillsIdempotentlyAndDetectsDrift() throws {
        let home = try tempHome()
        let c = SkillComponent(agent: .copilot, homeDirectoryURL: home, fileManager: .default)
        #expect(c.state() == .notInstalled)
        try c.install()
        #expect(c.state() == .installed)
        let ghz = home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md")
        let pf = home.appendingPathComponent(".copilot/skills/process-feedback/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: ghz.path))
        #expect(FileManager.default.fileExists(atPath: pf.path))
        try c.install() // idempotent
        #expect(c.state() == .installed)
        try "tampered <!-- ghoztty-managed -->".write(to: ghz, atomically: true, encoding: .utf8)
        #expect(c.state() == .outdated)
        try c.uninstall()
        #expect(c.state() == .notInstalled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `macos/build.nu --action test`
Expected: FAIL — `SkillComponent` undefined.

- [ ] **Step 3: Implement `SkillComponent`**

```swift
// macos/Sources/Features/Setup/SkillComponent.swift
import Foundation

/// Installs the bundled `ghoztty` and `process-feedback` skills into a runtime's
/// `skills/` directory. Portable: only the config dir differs per runtime.
struct SkillComponent {
    static let marker = "<!-- ghoztty-managed -->"
    static let skillNames = ["ghoztty", "process-feedback"]

    let agent: RuntimeAgent
    let homeDirectoryURL: URL
    let fileManager: FileManager

    private func skillURL(_ name: String) -> URL {
        agent.configDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent("skills/\(name)/SKILL.md")
    }

    private func expected(_ name: String) throws -> String {
        try GhosttyAssets.skillMarkdown(name) + "\n\(Self.marker)\n"
    }

    func state() -> ComponentInstallState {
        let states = Self.skillNames.map { name -> ComponentInstallState in
            guard let want = try? expected(name) else { return .outdated }
            return ManagedFile.state(at: skillURL(name), expected: want, marker: Self.marker)
        }
        if states.allSatisfy({ $0 == .installed }) { return .installed }
        if states.allSatisfy({ $0 == .notInstalled }) { return .notInstalled }
        return .outdated
    }

    func install() throws {
        // Render all up front so a missing bundled asset fails before any write.
        let rendered = try Self.skillNames.map { (url: skillURL($0), body: try expected($0)) }
        var written: [URL] = []
        do {
            for file in rendered {
                try ManagedFile.write(file.body, to: file.url, marker: Self.marker, mode: 0o600, fileManager: fileManager)
                written.append(file.url)
            }
        } catch {
            for url in written.reversed() {
                try? ManagedFile.removeIfManaged(at: url, marker: Self.marker, fileManager: fileManager)
            }
            throw error
        }
    }

    func uninstall() throws {
        for name in Self.skillNames {
            try ManagedFile.removeIfManaged(at: skillURL(name), marker: Self.marker, fileManager: fileManager)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `macos/build.nu --action test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Setup/SkillComponent.swift macos/Tests/Ghostty/SkillComponentTests.swift
git commit -m "macos: add SkillComponent (installs bundled skills per runtime)"
```

---

### Task 5: De-Claude-ify the banner script + `BannerScriptInstaller`

**Files:**
- Modify: `macos/Resources/Ghoztty/hooks/ghoztty-banner.sh` (state dir → neutral; accept normalized payload)
- Create: `macos/Sources/Features/Setup/BannerScriptInstaller.swift`
- Test: `macos/Tests/Ghostty/BannerScriptInstallerTests.swift`

**Interfaces:**
- Consumes: `GhosttyAssets`, `ManagedFile`.
- Produces: `struct BannerScriptInstaller { init(homeDirectoryURL:URL, fileManager:FileManager); static func scriptURL(homeDirectoryURL:URL) -> URL; func state() -> ComponentInstallState; func install() throws; func uninstall() throws }`. Installs to `~/.config/ghoztty/hooks/ghoztty-banner.sh`, mode `0o700`. The bundled script already contains the marker line `# ghoztty-managed`.

- [ ] **Step 1: De-Claude-ify the bundled script**

Edit `macos/Resources/Ghoztty/hooks/ghoztty-banner.sh`:
- Change the state dir line `STATE_DIR="$HOME/.claude/ghoztty-banner"` → `STATE_DIR="$HOME/.config/ghoztty/banner-state"`.
- Change the no-jq flag dir reference likewise (it derives from `$STATE_DIR`, so no extra change).
- In the `prompt-hook)` and `session-start-hook)` branches, the script already reads `.prompt` / `.session_id` from stdin JSON via `jq`. Replace those two `jq` reads with `awk`-based extraction so the script no longer needs `jq` to read the (already-normalized) `{prompt, session_id}` payload:

```bash
# helper near the top of the script (after STATE_DIR setup):
# Extract a top-level string field from a flat one-line JSON object WITHOUT jq.
json_str_field() { # field  (reads stdin)
    LC_ALL=C awk -v k="$1" '
      { s = s $0 }
      END {
        p = "\"" k "\""; i = index(s, p); if (!i) { exit }
        i += length(p); n = length(s)
        while (i <= n && substr(s,i,1) ~ /[ \t\r\n]/) i++
        if (substr(s,i,1) != ":") exit; i++
        while (i <= n && substr(s,i,1) ~ /[ \t\r\n]/) i++
        if (substr(s,i,1) != "\"") exit; i++
        o = ""; e = 0
        while (i <= n) { c = substr(s,i,1)
          if (e) { o = o c; e = 0; i++; continue }
          if (c == "\\") { o = o c; e = 1; i++; continue }
          if (c == "\"") break
          o = o c; i++ }
        printf "%s", o
      }'
}
```

Then in `prompt-hook)`:
```bash
    input=$(cat)
    asked=$(printf '%s' "$input" | json_str_field prompt | head -n1)
    ...
    session=$(printf '%s' "$input" | json_str_field session_id)
```
and the same `json_str_field session_id` substitution in `session-start-hook)`.
- Add a marker comment line near the top (after the shebang): `# ghoztty-managed`.
- Add a length cap + control-byte strip when `asked` is used (defense-in-depth; the hook command also sanitizes): `asked=$(printf '%s' "$asked" | LC_ALL=C tr -d '\000-\037\177' | cut -c1-500)`.

Keep the `jq`-based **state-merge** (`read_field`/`write_field`) and the "jq not installed" banner exactly as-is — those stay behind the existing guard.

- [ ] **Step 2: Write the failing test**

```swift
// macos/Tests/Ghostty/BannerScriptInstallerTests.swift
import Foundation
import Testing
@testable import Ghostty

struct BannerScriptInstallerTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installsToStablePathWithNeutralStateDir() throws {
        let home = try tempHome()
        let i = BannerScriptInstaller(homeDirectoryURL: home, fileManager: .default)
        #expect(i.state() == .notInstalled)
        try i.install()
        #expect(i.state() == .installed)
        let url = home.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh")
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains(".config/ghoztty/banner-state"))
        #expect(!body.contains(".claude/ghoztty-banner"))
        // executable bit
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(mode == 0o700)
    }

    @Test func bundledScriptHasNoClaudeStateDir() throws {
        #expect(try GhosttyAssets.bannerScript().contains(".config/ghoztty/banner-state"))
        #expect(try !GhosttyAssets.bannerScript().contains(".claude/ghoztty-banner"))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `macos/build.nu --action test`
Expected: FAIL — `BannerScriptInstaller` undefined.

- [ ] **Step 4: Implement `BannerScriptInstaller`**

```swift
// macos/Sources/Features/Setup/BannerScriptInstaller.swift
import Foundation

/// Copies the bundled banner script to a STABLE owned path so generated hooks
/// never reference a volatile `Ghoztty.app` bundle path.
struct BannerScriptInstaller {
    static let marker = "# ghoztty-managed"

    let homeDirectoryURL: URL
    let fileManager: FileManager

    static func scriptURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh")
    }

    private var url: URL { Self.scriptURL(homeDirectoryURL: homeDirectoryURL) }
    private func expected() throws -> String { try GhosttyAssets.bannerScript() }

    func state() -> ComponentInstallState {
        guard let want = try? expected() else { return .outdated }
        return ManagedFile.state(at: url, expected: want, marker: Self.marker)
    }

    func install() throws {
        try ManagedFile.write(try expected(), to: url, marker: Self.marker, mode: 0o700, fileManager: fileManager)
    }

    func uninstall() throws {
        try ManagedFile.removeIfManaged(at: url, marker: Self.marker, fileManager: fileManager)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `macos/build.nu --action test`
Expected: PASS. (If `bundledScriptHasNoClaudeStateDir` fails, the Step-1 script edit is incomplete.)

- [ ] **Step 6: Commit**

```bash
git add macos/Resources/Ghoztty/hooks/ghoztty-banner.sh macos/Sources/Features/Setup/BannerScriptInstaller.swift macos/Tests/Ghostty/BannerScriptInstallerTests.swift
git commit -m "macos: de-Claude-ify banner script + install to stable path"
```

---

### Task 6: `HookSpec` protocol + `CopilotHookSpec` (dedicated-file)

**Files:**
- Create: `macos/Sources/Features/Setup/HookSpec.swift`
- Create: `macos/Sources/Features/Setup/CopilotHookSpec.swift`
- Test: `macos/Tests/Ghostty/CopilotHookSpecTests.swift`

**Interfaces:**
- Produces:
  - `enum HookOwnership { case dedicatedFile; case mergedFragment }`
  - `protocol HookSpec { var ownership: HookOwnership { get }; func hookFileURL(homeDirectoryURL: URL) -> URL; func renderedFile(bannerScriptPath: String) -> String; var marker: String { get } }`
  - Shared command builder `enum HookCommand { static func perEvent(purpose: HookPurpose, bannerScriptPath: String) -> String }` producing the sanitizing, jq-free, argv-passing `bash` string. `enum HookPurpose { case sessionStart, promptSubmit, stop }`.
  - `struct CopilotHookSpec: HookSpec` with `ownership == .dedicatedFile`, `hookFileURL == ~/.copilot/hooks/ghoztty.json`, `marker == "ghoztty-managed"`, `renderedFile` = the `{version:1,hooks:{...}}` JSON with camelCase event keys `sessionStart`/`userPromptSubmitted`/`agentStop`.
- Consumes: `BannerScriptInstaller.scriptURL` for the stable path.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Ghostty/CopilotHookSpecTests.swift
import Foundation
import Testing
@testable import Ghostty

struct CopilotHookSpecTests {
    @Test func rendersCamelCaseEventsAndStablePathNoBundle() {
        let spec = CopilotHookSpec()
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(spec.hookFileURL(homeDirectoryURL: home).path == "/tmp/home/.copilot/hooks/ghoztty.json")
        let file = spec.renderedFile(bannerScriptPath: "/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh")
        #expect(file.contains("\"sessionStart\""))
        #expect(file.contains("\"userPromptSubmitted\""))
        #expect(file.contains("\"agentStop\""))
        #expect(file.contains("\"version\""))
        #expect(file.contains(spec.marker))
        #expect(!file.contains(".app/Contents"))
        // No jq in the hook command; prompt passed via stdin, control bytes stripped.
        #expect(!file.contains("jq "))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `macos/build.nu --action test`
Expected: FAIL — `CopilotHookSpec` undefined.

- [ ] **Step 3: Implement `HookSpec` + command builder**

```swift
// macos/Sources/Features/Setup/HookSpec.swift
import Foundation

enum HookOwnership { case dedicatedFile, mergedFragment }
enum HookPurpose { case sessionStart, promptSubmit, stop }

protocol HookSpec {
    var ownership: HookOwnership { get }
    var marker: String { get }
    func hookFileURL(homeDirectoryURL: URL) -> URL
    func renderedFile(bannerScriptPath: String) -> String
}

/// Builds the per-event `bash` command. Reads stdin, normalizes the runtime
/// payload to `{prompt, session_id}` with awk (NO jq), passes `prompt` to the
/// banner script on stdin (never interpolated into the command), and strips
/// control bytes. `SCRIPT` is the stable banner-script path.
enum HookCommand {
    static func perEvent(purpose: HookPurpose, bannerScriptPath: String) -> String {
        let s = shellQuote(bannerScriptPath)
        switch purpose {
        case .sessionStart:
            return "bash \(s) session-start-hook"
        case .stop:
            return "bash \(s) stop-hook"
        case .promptSubmit:
            // The banner script reads stdin itself (input=$(cat)) and does the
            // jq-free extraction + sanitization. No shell interpolation of
            // prompt text happens here.
            return "bash \(s) prompt-hook"
        }
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

```swift
// macos/Sources/Features/Setup/CopilotHookSpec.swift
import Foundation

/// Copilot auto-loads every JSON in ~/.copilot/hooks/, so Ghoztty owns a
/// dedicated file. camelCase event names; version 1 envelope.
struct CopilotHookSpec: HookSpec {
    let ownership: HookOwnership = .dedicatedFile
    let marker = "ghoztty-managed"

    func hookFileURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".copilot/hooks/ghoztty.json")
    }

    func renderedFile(bannerScriptPath: String) -> String {
        func hook(_ cmd: String, _ timeout: Int) -> String {
            "[ { \"type\": \"command\", \"bash\": \(jsonString(cmd)), \"timeoutSec\": \(timeout) } ]"
        }
        let start = HookCommand.perEvent(purpose: .sessionStart, bannerScriptPath: bannerScriptPath)
        let prompt = HookCommand.perEvent(purpose: .promptSubmit, bannerScriptPath: bannerScriptPath)
        let stop = HookCommand.perEvent(purpose: .stop, bannerScriptPath: bannerScriptPath)
        return """
        {
          "version": 1,
          "_comment": "\(marker)",
          "hooks": {
            "sessionStart": \(hook(start, 10)),
            "userPromptSubmitted": \(hook(prompt, 10)),
            "agentStop": \(hook(stop, 10))
          }
        }
        """
    }

    private func jsonString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `macos/build.nu --action test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Setup/HookSpec.swift macos/Sources/Features/Setup/CopilotHookSpec.swift macos/Tests/Ghostty/CopilotHookSpecTests.swift
git commit -m "macos: add HookSpec + CopilotHookSpec (dedicated-file hooks)"
```

---

### Task 7: `ClaudeHookSpec` (merged-fragment) + external-plugin detection

**Files:**
- Create: `macos/Sources/Features/Setup/ClaudeHookSpec.swift`
- Test: `macos/Tests/Ghostty/ClaudeHookSpecTests.swift`

**Interfaces:**
- Produces: `struct ClaudeHookSpec: HookSpec` with `ownership == .mergedFragment`, `hookFileURL == ~/.claude/settings.json`, `marker == "ghoztty-managed"`.
  - Merge helpers (used by `HookComponent` for the mergedFragment strategy): `static func merge(into json: [String: Any], bannerScriptPath: String) -> [String: Any]`, `static func fragmentState(in json: [String: Any], bannerScriptPath: String) -> ComponentInstallState`, `static func removeFragment(from json: [String: Any]) -> [String: Any]`. Ownership is tracked by the presence of the banner-script invocation signature inside the `hooks` subtree.
  - `func isExternalPluginInstalled(homeDirectoryURL: URL, fileManager: FileManager) -> Bool` — true if `~/.claude/plugins/installed_plugins.json` references `ghoztty`.
- Consumes: `HookCommand`, `BannerScriptInstaller.scriptURL`.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Ghostty/ClaudeHookSpecTests.swift
import Foundation
import Testing
@testable import Ghostty

struct ClaudeHookSpecTests {
    private let scriptPath = "/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh"

    @Test func mergePreservesUnrelatedKeysAndIsDetectable() {
        let existing: [String: Any] = ["theme": "dark", "model": "opus"]
        let merged = ClaudeHookSpec.merge(into: existing, bannerScriptPath: scriptPath)
        #expect(merged["theme"] as? String == "dark")
        #expect(merged["model"] as? String == "opus")
        #expect(ClaudeHookSpec.fragmentState(in: merged, bannerScriptPath: scriptPath) == .installed)
    }

    @Test func removeFragmentLeavesRest() {
        var json = ClaudeHookSpec.merge(into: ["theme": "dark"], bannerScriptPath: scriptPath)
        json = ClaudeHookSpec.removeFragment(from: json)
        #expect(json["theme"] as? String == "dark")
        #expect(ClaudeHookSpec.fragmentState(in: json, bannerScriptPath: scriptPath) == .notInstalled)
    }

    @Test func detectsExternalPlugin() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let pluginsDir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try #"{"plugins":[{"name":"ghoztty"}]}"#.write(to: pluginsDir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)
        #expect(ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: home, fileManager: .default))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `macos/build.nu --action test`
Expected: FAIL — `ClaudeHookSpec` undefined.

- [ ] **Step 3: Implement `ClaudeHookSpec`**

```swift
// macos/Sources/Features/Setup/ClaudeHookSpec.swift
import Foundation

/// Claude stores hooks in the SHARED ~/.claude/settings.json (no auto-loaded
/// hooks dir), so Ghoztty merges a fragment under the `hooks` key and tracks
/// ownership by the banner-script invocation signature.
struct ClaudeHookSpec: HookSpec {
    let ownership: HookOwnership = .mergedFragment
    let marker = "ghoztty-managed"

    func hookFileURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".claude/settings.json")
    }

    // renderedFile is unused for mergedFragment; the component uses the merge
    // helpers instead. Provide the whole-file form for protocol conformance/tests.
    func renderedFile(bannerScriptPath: String) -> String {
        let json = Self.merge(into: [:], bannerScriptPath: bannerScriptPath)
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    /// Ownership signature: any hook command that invokes our banner script.
    static func signature(_ bannerScriptPath: String) -> String { bannerScriptPath }

    static func hooksBlock(bannerScriptPath: String) -> [String: Any] {
        func entry(_ purpose: HookPurpose) -> [String: Any] {
            ["hooks": [["type": "command",
                        "command": HookCommand.perEvent(purpose: purpose, bannerScriptPath: bannerScriptPath)]]]
        }
        return [
            "SessionStart": [["matcher": "startup|clear", "hooks": [["type": "command", "command": HookCommand.perEvent(purpose: .sessionStart, bannerScriptPath: bannerScriptPath)]]]],
            "UserPromptSubmit": [entry(.promptSubmit)],
            "Stop": [entry(.stop)],
        ]
    }

    static func merge(into json: [String: Any], bannerScriptPath: String) -> [String: Any] {
        var out = json
        out["hooks"] = hooksBlock(bannerScriptPath: bannerScriptPath)
        return out
    }

    static func removeFragment(from json: [String: Any]) -> [String: Any] {
        var out = json
        out.removeValue(forKey: "hooks")
        return out
    }

    static func fragmentState(in json: [String: Any], bannerScriptPath: String) -> ComponentInstallState {
        guard let data = try? JSONSerialization.data(withJSONObject: json["hooks"] ?? [:]),
              let text = String(data: data, encoding: .utf8),
              text.contains(signature(bannerScriptPath)) else {
            return .notInstalled
        }
        let want = hooksBlock(bannerScriptPath: bannerScriptPath)
        let wantData = try? JSONSerialization.data(withJSONObject: want, options: [.sortedKeys])
        let haveData = try? JSONSerialization.data(withJSONObject: json["hooks"] ?? [:], options: [.sortedKeys])
        return wantData == haveData ? .installed : .outdated
    }

    func isExternalPluginInstalled(homeDirectoryURL: URL, fileManager: FileManager) -> Bool {
        let url = homeDirectoryURL.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("ghoztty")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `macos/build.nu --action test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Setup/ClaudeHookSpec.swift macos/Tests/Ghostty/ClaudeHookSpecTests.swift
git commit -m "macos: add ClaudeHookSpec (merged-fragment) + external-plugin detection"
```

---

### Task 8: `HookComponent` (applies the ownership strategy)

**Files:**
- Create: `macos/Sources/Features/Setup/HookComponent.swift`
- Test: `macos/Tests/Ghostty/HookComponentTests.swift`

**Interfaces:**
- Consumes: `HookSpec`, `CopilotHookSpec`, `ClaudeHookSpec`, `ManagedFile`, `BannerScriptInstaller.scriptURL`.
- Produces: `struct HookComponent { init(spec: HookSpec, homeDirectoryURL: URL, fileManager: FileManager); func state() -> ComponentInstallState; func install() throws; func uninstall() throws }`. For `.dedicatedFile` it delegates to `ManagedFile`. For `.mergedFragment` it read-modify-writes the shared JSON via `ClaudeHookSpec` merge helpers, preserving unknown keys.

- [ ] **Step 1: Write the failing tests**

```swift
// macos/Tests/Ghostty/HookComponentTests.swift
import Foundation
import Testing
@testable import Ghostty

struct HookComponentTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func copilotDedicatedFileLifecycle() throws {
        let home = try tempHome()
        let c = HookComponent(spec: CopilotHookSpec(), homeDirectoryURL: home, fileManager: .default)
        #expect(c.state() == .notInstalled)
        try c.install()
        #expect(c.state() == .installed)
        let url = home.appendingPathComponent(".copilot/hooks/ghoztty.json")
        #expect(FileManager.default.fileExists(atPath: url.path))
        try c.uninstall()
        #expect(c.state() == .notInstalled)
    }

    @Test func claudeMergedFragmentPreservesUserKeys() throws {
        let home = try tempHome()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"theme":"dark"}"#.write(to: settings, atomically: true, encoding: .utf8)
        let c = HookComponent(spec: ClaudeHookSpec(), homeDirectoryURL: home, fileManager: .default)
        try c.install()
        #expect(c.state() == .installed)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect(json["theme"] as? String == "dark")
        #expect(json["hooks"] != nil)
        try c.uninstall()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect(after["theme"] as? String == "dark")
        #expect(after["hooks"] == nil)
        #expect(c.state() == .notInstalled)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `macos/build.nu --action test`
Expected: FAIL — `HookComponent` undefined.

- [ ] **Step 3: Implement `HookComponent`**

```swift
// macos/Sources/Features/Setup/HookComponent.swift
import Foundation

struct HookComponent {
    let spec: HookSpec
    let homeDirectoryURL: URL
    let fileManager: FileManager

    private var bannerScriptPath: String {
        BannerScriptInstaller.scriptURL(homeDirectoryURL: homeDirectoryURL).path
    }
    private var fileURL: URL { spec.hookFileURL(homeDirectoryURL: homeDirectoryURL) }

    func state() -> ComponentInstallState {
        switch spec.ownership {
        case .dedicatedFile:
            return ManagedFile.state(at: fileURL, expected: spec.renderedFile(bannerScriptPath: bannerScriptPath), marker: spec.marker)
        case .mergedFragment:
            let json = readJSON()
            return ClaudeHookSpec.fragmentState(in: json, bannerScriptPath: bannerScriptPath)
        }
    }

    func install() throws {
        switch spec.ownership {
        case .dedicatedFile:
            try ManagedFile.write(spec.renderedFile(bannerScriptPath: bannerScriptPath),
                                  to: fileURL, marker: spec.marker, mode: 0o600, fileManager: fileManager)
        case .mergedFragment:
            let merged = ClaudeHookSpec.merge(into: readJSON(), bannerScriptPath: bannerScriptPath)
            try writeJSON(merged)
        }
    }

    func uninstall() throws {
        switch spec.ownership {
        case .dedicatedFile:
            try ManagedFile.removeIfManaged(at: fileURL, marker: spec.marker, fileManager: fileManager)
        case .mergedFragment:
            let json = readJSON()
            guard ClaudeHookSpec.fragmentState(in: json, bannerScriptPath: bannerScriptPath) != .notInstalled else { return }
            try writeJSON(ClaudeHookSpec.removeFragment(from: json))
        }
    }

    private func readJSON() -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func writeJSON(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `macos/build.nu --action test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Setup/HookComponent.swift macos/Tests/Ghostty/HookComponentTests.swift
git commit -m "macos: add HookComponent with dedicated-file + merged-fragment strategies"
```

---

### Task 9: `RuntimeIntegration` + `IntegrationComponent`

**Files:**
- Create: `macos/Sources/Features/Setup/RuntimeIntegration.swift`
- Test: `macos/Tests/Ghostty/RuntimeIntegrationTests.swift`

**Interfaces:**
- Produces:
  - `struct IntegrationComponent { let name: String; let state: () -> ComponentInstallState; let install: () throws -> Void; let uninstall: () throws -> Void }`
  - `enum AgentIntegrationError: Error, Equatable { case notInstalled(RuntimeAgent) }`
  - `struct RuntimeIntegration { let agent: RuntimeAgent; let components: [IntegrationComponent]; let requiredDirectory: URL?; let fileManager: FileManager; func state() -> RuntimeIntegrationState; func install() throws; func uninstall() throws }`
- Aggregation rule (total): any `.notInstalled` → `.notInstalled`; else any `.outdated` → `.outdated`; else `.installed`.
- `install()`: throws `.notInstalled(agent)` if `requiredDirectory` is set and absent; else installs front-to-back, rolling back succeeded components (reverse) on failure.

- [ ] **Step 1: Write the failing tests**

```swift
// macos/Tests/Ghostty/RuntimeIntegrationTests.swift
import Foundation
import Testing
@testable import Ghostty

struct RuntimeIntegrationTests {
    private func comp(_ name: String, _ s: ComponentInstallState, install: @escaping () throws -> Void = {}, uninstall: @escaping () throws -> Void = {}) -> IntegrationComponent {
        IntegrationComponent(name: name, state: { s }, install: install, uninstall: uninstall)
    }

    @Test func aggregationRule() {
        func integ(_ states: [ComponentInstallState]) -> RuntimeIntegration {
            RuntimeIntegration(agent: .copilot, components: states.enumerated().map { comp("\($0.0)", $0.1) }, requiredDirectory: nil, fileManager: .default)
        }
        #expect(integ([.installed, .installed]).state() == .installed)
        #expect(integ([.installed, .notInstalled]).state() == .notInstalled)
        #expect(integ([.installed, .outdated]).state() == .outdated)
    }

    @Test func gateThrowsWhenDirAbsent() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID().uuidString)")
        let integ = RuntimeIntegration(agent: .copilot, components: [comp("x", .notInstalled)], requiredDirectory: missing, fileManager: .default)
        #expect(throws: AgentIntegrationError.self) { try integ.install() }
    }

    @Test func rollbackOnPartialFailure() throws {
        var firstInstalled = false
        var firstRolledBack = false
        struct Boom: Error {}
        let integ = RuntimeIntegration(
            agent: .copilot,
            components: [
                comp("first", .notInstalled, install: { firstInstalled = true }, uninstall: { firstRolledBack = true }),
                comp("second", .notInstalled, install: { throw Boom() }),
            ],
            requiredDirectory: nil, fileManager: .default)
        #expect(throws: Boom.self) { try integ.install() }
        #expect(firstInstalled)
        #expect(firstRolledBack)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `macos/build.nu --action test`
Expected: FAIL — `RuntimeIntegration` undefined.

- [ ] **Step 3: Implement `RuntimeIntegration`**

```swift
// macos/Sources/Features/Setup/RuntimeIntegration.swift
import Foundation
import OSLog

private let integrationLogger = Logger(subsystem: Bundle.loggerSubsystem, category: "AgentIntegration")

struct IntegrationComponent {
    let name: String
    let state: () -> ComponentInstallState
    let install: () throws -> Void
    let uninstall: () throws -> Void
}

enum AgentIntegrationError: Error, Equatable {
    case notInstalled(RuntimeAgent)
}

struct RuntimeIntegration {
    let agent: RuntimeAgent
    let components: [IntegrationComponent]
    let requiredDirectory: URL?
    let fileManager: FileManager

    func state() -> RuntimeIntegrationState {
        let states = components.map { $0.state() }
        if states.contains(.notInstalled) { return .notInstalled }
        if states.contains(.outdated) { return .outdated }
        return .installed
    }

    func install() throws {
        if let dir = requiredDirectory {
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: dir.path, isDirectory: &isDir)
            guard exists, isDir.boolValue else { throw AgentIntegrationError.notInstalled(agent) }
        }
        var done: [IntegrationComponent] = []
        do {
            for c in components {
                try c.install()
                done.append(c)
            }
        } catch {
            for c in done.reversed() {
                do { try c.uninstall() }
                catch { integrationLogger.error("rollback of \(agent.rawValue)/\(c.name) failed: \(String(describing: error))") }
            }
            throw error
        }
    }

    func uninstall() throws {
        var firstError: Error?
        for c in components.reversed() {
            do { try c.uninstall() }
            catch {
                integrationLogger.error("uninstall of \(agent.rawValue)/\(c.name) failed: \(String(describing: error))")
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `macos/build.nu --action test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Setup/RuntimeIntegration.swift macos/Tests/Ghostty/RuntimeIntegrationTests.swift
git commit -m "macos: add RuntimeIntegration (aggregate state, gated install, rollback)"
```

---

### Task 10: `RuntimeIntegrationFactory`

**Files:**
- Create: `macos/Sources/Features/Setup/RuntimeIntegrationFactory.swift`
- Test: `macos/Tests/Ghostty/RuntimeIntegrationFactoryTests.swift`

**Interfaces:**
- Consumes: all component types + specs.
- Produces: `enum RuntimeIntegrationFactory { static func make(for: RuntimeAgent, homeDirectoryURL: URL, fileManager: FileManager) -> RuntimeIntegration; static func availableAgents(homeDirectoryURL: URL, fileManager: FileManager) -> [RuntimeAgent] }`.
- Each integration's components = `[bannerScript, skills, hooks]`. `requiredDirectory` = the agent's config dir (checked before any subdir is created — the ordering invariant). For Claude, if the external plugin is detected the hooks component's install is a no-op reporting via a sentinel outcome (surfaced in Task 11), and here the hooks component is simply omitted so no duplicate is written.
- `availableAgents` = agents whose config dir exists.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Ghostty/RuntimeIntegrationFactoryTests.swift
import Foundation
import Testing
@testable import Ghostty

struct RuntimeIntegrationFactoryTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func availabilityFollowsConfigDir() throws {
        let home = try tempHome()
        #expect(RuntimeIntegrationFactory.availableAgents(homeDirectoryURL: home, fileManager: .default).isEmpty)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(RuntimeIntegrationFactory.availableAgents(homeDirectoryURL: home, fileManager: .default) == [.copilot])
    }

    @Test func endToEndCopilotInstall() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let integ = RuntimeIntegrationFactory.make(for: .copilot, homeDirectoryURL: home, fileManager: .default)
        try integ.install()
        #expect(integ.state() == .installed)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/hooks/ghoztty.json").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh").path))
    }

    @Test func gateBlocksWhenCopilotMissing() throws {
        let home = try tempHome() // no ~/.copilot
        let integ = RuntimeIntegrationFactory.make(for: .copilot, homeDirectoryURL: home, fileManager: .default)
        #expect(throws: AgentIntegrationError.self) { try integ.install() }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/skills").path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `macos/build.nu --action test`
Expected: FAIL — `RuntimeIntegrationFactory` undefined.

- [ ] **Step 3: Implement the factory**

```swift
// macos/Sources/Features/Setup/RuntimeIntegrationFactory.swift
import Foundation

enum RuntimeIntegrationFactory {
    static func availableAgents(homeDirectoryURL: URL, fileManager: FileManager) -> [RuntimeAgent] {
        RuntimeAgent.allCases.filter {
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: $0.configDirectoryURL(homeDirectoryURL: homeDirectoryURL).path, isDirectory: &isDir)
            return exists && isDir.boolValue
        }
    }

    static func make(for agent: RuntimeAgent, homeDirectoryURL: URL, fileManager: FileManager) -> RuntimeIntegration {
        let banner = BannerScriptInstaller(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        let skills = SkillComponent(agent: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)

        var components: [IntegrationComponent] = [
            IntegrationComponent(name: "banner-script", state: banner.state, install: banner.install, uninstall: banner.uninstall),
            IntegrationComponent(name: "skills", state: skills.state, install: skills.install, uninstall: skills.uninstall),
        ]

        // Hooks — skip Claude hooks entirely if the external plugin already owns them.
        let spec: HookSpec = agent == .claude ? ClaudeHookSpec() : CopilotHookSpec()
        let skipHooks = agent == .claude &&
            ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        if !skipHooks {
            let hooks = HookComponent(spec: spec, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            components.append(IntegrationComponent(name: "hooks", state: hooks.state, install: hooks.install, uninstall: hooks.uninstall))
        }

        return RuntimeIntegration(
            agent: agent,
            components: components,
            requiredDirectory: agent.configDirectoryURL(homeDirectoryURL: homeDirectoryURL),
            fileManager: fileManager)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `macos/build.nu --action test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Setup/RuntimeIntegrationFactory.swift macos/Tests/Ghostty/RuntimeIntegrationFactoryTests.swift
git commit -m "macos: add RuntimeIntegrationFactory (compose components + gate + coexistence)"
```

---

### Task 11: Orchestration service + `AppDelegate+Setup` generalization

**Files:**
- Create: `macos/Sources/Features/Setup/AgentIntegrationService.swift`
- Modify: `macos/Sources/Features/Setup/AppDelegate+Setup.swift` (dialog checkboxes per runtime; menu action installs all available runtimes; remove Claude-only paths)
- Delete: `macos/Sources/Features/Setup/ClaudeCodeIntegration.swift`
- Test: `macos/Tests/Ghostty/AgentIntegrationServiceTests.swift`

**Interfaces:**
- Consumes: `RuntimeIntegrationFactory`, `RuntimeAgent`, `LoginShell`.
- Produces:
  - `enum IntegrationOutcome: Equatable { case installed, upToDate, upgraded, notFound, pluginPresent, failed(String) }`
  - `enum AgentIntegrationService { static func install(agent: RuntimeAgent, homeDirectoryURL: URL, fileManager: FileManager) -> IntegrationOutcome; static func availableAgents(homeDirectoryURL: URL, fileManager: FileManager) -> [RuntimeAgent]; static func summary(_ results: [(RuntimeAgent, IntegrationOutcome)]) -> String; static var jqAvailable: Bool { get } }`
- Outcome mapping: prior `state()` → install → new `state()`. `installed` if prior was `notInstalled` and now `installed`; `upgraded` if prior was `outdated` and now `installed`; `upToDate` if prior already `installed`; `notFound` if install throws `AgentIntegrationError.notInstalled`; `pluginPresent` (Claude only) if the external plugin was detected; `failed(msg)` on any other throw.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Ghostty/AgentIntegrationServiceTests.swift
import Foundation
import Testing
@testable import Ghostty

struct AgentIntegrationServiceTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installThenUpToDate() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .upToDate)
    }

    @Test func notFoundWhenRuntimeAbsent() throws {
        let home = try tempHome()
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .notFound)
    }

    @Test func summaryJoinsPerRuntime() {
        let text = AgentIntegrationService.summary([(.claude, .installed), (.copilot, .upToDate)])
        #expect(text.contains("Claude Code: installed"))
        #expect(text.contains("Copilot CLI: already up to date"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `macos/build.nu --action test`
Expected: FAIL — `AgentIntegrationService` undefined.

- [ ] **Step 3: Implement `AgentIntegrationService`**

```swift
// macos/Sources/Features/Setup/AgentIntegrationService.swift
import Foundation

enum IntegrationOutcome: Equatable {
    case installed, upToDate, upgraded, notFound, pluginPresent, failed(String)

    var label: String {
        switch self {
        case .installed: "installed"
        case .upToDate: "already up to date"
        case .upgraded: "upgraded"
        case .notFound: "not found"
        case .pluginPresent: "plugin already present"
        case .failed(let d): "failed — \(d)"
        }
    }
}

enum AgentIntegrationService {
    static func availableAgents(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                                fileManager: FileManager = .default) -> [RuntimeAgent] {
        RuntimeIntegrationFactory.availableAgents(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    }

    static var jqAvailable: Bool {
        (LoginShell.run("command -v jq")?.exitCode ?? 1) == 0
    }

    static func install(agent: RuntimeAgent,
                        homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                        fileManager: FileManager = .default) -> IntegrationOutcome {
        let integ = RuntimeIntegrationFactory.make(for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        let prior = integ.state()
        do {
            try integ.install()
        } catch AgentIntegrationError.notInstalled {
            return .notFound
        } catch {
            return .failed(error.localizedDescription)
        }
        let now = integ.state()
        if agent == .claude,
           ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager) {
            return .pluginPresent
        }
        switch (prior, now) {
        case (.installed, .installed): return .upToDate
        case (.outdated, .installed): return .upgraded
        case (_, .installed): return .installed
        default: return .failed("post-install state \(now)")
        }
    }

    static func summary(_ results: [(RuntimeAgent, IntegrationOutcome)]) -> String {
        results.map { "\($0.0.displayName): \($0.1.label)" }.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `macos/build.nu --action test`
Expected: PASS.

- [ ] **Step 5: Generalize the first-launch dialog**

In `AppDelegate+Setup.swift`, replace the Claude-only checkbox with one per available runtime. Change `checkCommandLineToolOnLaunch()` (around line 42) from:

```swift
            let claudeAvailable = ClaudeCodeIntegration.findClaude() != nil
            DispatchQueue.main.async {
                self.presentSetupDialog(probe: probe, claudeAvailable: claudeAvailable)
            }
```
to:
```swift
            let agents = AgentIntegrationService.availableAgents()
            DispatchQueue.main.async {
                self.presentSetupDialog(probe: probe, agents: agents)
            }
```

Replace `presentSetupDialog(probe:claudeAvailable:)` (lines 49–114) so it builds a vertical stack of checkboxes (one per agent, all `.on`) as the accessory view, and on accept installs each checked agent via `AgentIntegrationService.install(agent:)`:

```swift
    private func presentSetupDialog(probe: CommandLineInstaller.Probe, agents: [RuntimeAgent]) {
        let defaults = UserDefaults.ghostty
        defaults.set(true, forKey: SetupDefaults.promptAnswered)

        let alert = NSAlert()
        alert.messageText = "Set Up the ghoztty Command?"
        alert.informativeText = "Ghoztty can add the ghoztty command so terminals and tools can control it. This creates a link in ~/.local/bin. No admin access is needed."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Not Now")

        var checkboxes: [(RuntimeAgent, NSButton)] = []
        if !agents.isEmpty {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            for agent in agents {
                let box = NSButton(checkboxWithTitle: "Also set up \(agent.displayName) integration", target: nil, action: nil)
                box.state = .on
                checkboxes.append((agent, box))
                stack.addArrangedSubview(box)
            }
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(agents.count) * 22)
            alert.accessoryView = stack
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        defaults.set(true, forKey: SetupDefaults.installAccepted)
        let chosen = checkboxes.filter { $0.1.state == .on }.map { $0.0 }

        DispatchQueue.global(qos: .userInitiated).async {
            var cliFailure: String?
            do {
                try CommandLineInstaller.install(pathContainsUserBin: probe.pathContainsUserBin, allowAdminPrompt: true)
            } catch { cliFailure = error.localizedDescription }

            var results: [(RuntimeAgent, IntegrationOutcome)] = []
            if cliFailure == nil {
                for agent in chosen { results.append((agent, AgentIntegrationService.install(agent: agent))) }
            }
            let jqMissing = !chosen.isEmpty && !AgentIntegrationService.jqAvailable

            DispatchQueue.main.async {
                if let cliFailure {
                    Self.showSetupAlert(title: "Command Setup Failed",
                        message: "\(cliFailure) You can try again from the Ghoztty menu.", style: .warning)
                } else if results.contains(where: { if case .failed = $0.1 { return true } else { return false } }) {
                    Self.showSetupAlert(title: "Some Integrations Failed",
                        message: AgentIntegrationService.summary(results) + ". Re-run Set Up Agent Integrations… to try again.", style: .warning)
                } else if jqMissing {
                    Self.showSetupAlert(title: "Almost Done",
                        message: "Integrations installed. The status banner needs jq — install it with: brew install jq")
                }
                // Otherwise success stays silent.
            }
        }
    }
```

- [ ] **Step 6: Replace the menu action**

Replace `setupClaudeCodeIntegration(_:)` (lines 170–195) with a runtime-agnostic action installing every available runtime:

```swift
    @IBAction func setupAgentIntegrations(_ sender: Any?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let agents = AgentIntegrationService.availableAgents()
            guard !agents.isEmpty else {
                DispatchQueue.main.async {
                    Self.showSetupAlert(title: "No Agents Found",
                        message: "No supported coding-agent CLI (Claude Code, Copilot CLI) was found. Install one, then run this again.")
                }
                return
            }
            let results = agents.map { ($0, AgentIntegrationService.install(agent: $0)) }
            let jqMissing = !AgentIntegrationService.jqAvailable
            DispatchQueue.main.async {
                var msg = AgentIntegrationService.summary(results)
                if jqMissing { msg += "\n\nThe status banner needs jq — install it with: brew install jq" }
                Self.showSetupAlert(title: "Agent Integrations", message: msg)
            }
        }
    }
```

Update the menu item / command-palette wiring that referenced `setupClaudeCodeIntegration:` to call `setupAgentIntegrations:` with the title "Set Up Agent Integrations…". Search `macos/Sources/App/macOS/MainMenu.xib` and `TerminalCommandPalette.swift` for the old selector and rename.

- [ ] **Step 7: Delete `ClaudeCodeIntegration.swift`**

```bash
git rm macos/Sources/Features/Setup/ClaudeCodeIntegration.swift
```
Fix any remaining references (build will flag them): the only callers were `checkCommandLineToolOnLaunch` and the old menu action, both replaced above.

- [ ] **Step 8: Build, test, lint**

Run: `macos/build.nu --action build && macos/build.nu --action test && swiftlint lint --strict --fix macos/Sources/Features/Setup`
Expected: build succeeds, all tests pass, lint clean.

- [ ] **Step 9: Commit**

```bash
git add -A macos/Sources macos/Tests
git commit -m "macos: generalize agent-integration setup to all runtimes; remove ClaudeCodeIntegration"
```

---

### Task 12: Contributor docs

**Files:**
- Modify: `HACKING.md` (or `macos/AGENTS.md`)

**Interfaces:** none (docs only).

- [ ] **Step 1: Add a Setup-subsystem section**

Add a short section documenting: the `macos/Sources/Features/Setup/` runtime abstraction (`RuntimeAgent` → `RuntimeIntegrationFactory` → `RuntimeIntegration` of `[bannerScript, skills, hooks]`), the bundled assets at `macos/Resources/Ghoztty/`, and a pointer to the spec's "Adding a runtime" checklist. Keep it to one paragraph plus the checklist link.

- [ ] **Step 2: Commit**

```bash
git add HACKING.md
git commit -m "docs: document the agent-integration Setup subsystem"
```

---

## Self-Review

Completed after drafting (see below); issues fixed inline.

**1. Spec coverage** — every spec section maps to a task:
- Bundled assets + resource wiring → Task 1
- `RuntimeAgent` registry + state enums → Task 2
- Write-safety (O_EXCL/O_NOFOLLOW/modes/marker) → Task 3
- Skills component → Task 4
- Banner script de-Claude-ification + stable path (#1) → Task 5
- Payload contract, awk/no-jq (#5), sanitization (#4), event mapping → Tasks 5–6
- Two ownership strategies (#2), Copilot dedicated-file → Tasks 6, 8
- Claude merged-fragment + external-plugin coexistence (#3) → Tasks 7, 10
- `state()` aggregation rule (#6), rollback, gate + ordering → Tasks 9–10
- Registration UX (dialog/menu/outcomes/jq prereq/messaging #17) → Task 11
- Contributor docs (#16) + verification guidance (#11) → Task 12

**2. Placeholder scan** — none found.

**3. Type consistency** — verified: `ComponentInstallState`, `IntegrationComponent`, `HookSpec` (`ownership`/`marker`/`hookFileURL`/`renderedFile`), `ClaudeHookSpec` merge helpers, `BannerScriptInstaller.scriptURL`, `HookCommand.perEvent`, `AgentIntegrationError`, and `AgentIntegrationService` signatures match across defining and consuming tasks. Fixed one inconsistency: the `.promptSubmit` hook command dropped a redundant `cat |` so all three events are uniform (`bash SCRIPT <sub>`; the script reads its own stdin).

**Deliberate deviation from the spec's file map:** the spec listed `isAvailable` on `RuntimeAgent`. The plan instead locates availability in `RuntimeIntegrationFactory.availableAgents` (config-dir existence, evaluated before any subdirectory is created — the ordering invariant), which is directly testable with an injected `FileManager`. This keeps `RuntimeAgent` a pure value type and satisfies the same gate semantics. If a stronger binary-probe signal is wanted later for Claude, it slots into `availableAgents` without touching the enum.

## Notes for the implementer

- **jq is only used by the banner script's state-merge**, behind its existing "jq not installed" guard/banner. Hook payload normalization must stay jq-free (`json_str_field` awk helper in Task 5). Do not reintroduce `jq` into the hook command.
- **Never let a generated hook reference a path inside `Ghoztty.app`.** Task 6's test asserts this; keep it.
- **The `mergedFragment` strategy must preserve unknown keys** in `settings.json`. Task 8's test asserts `theme` survives install and uninstall.
- When editing `project.pbxproj` by hand is unreliable, add the `Resources/Ghoztty` folder reference through Xcode's UI instead (folder reference, added to the app target's Copy Bundle Resources).
- Run the full `macos/build.nu --action test` after Tasks 3, 8, 10, and 11 (the integration points); targeted runs are fine in between.
