# Agent Integrations Manage Panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated "Agent Integrations" window that shows, per supported coding-agent runtime, whether Ghoztty's integration is not-detected / not-set-up / installed / update-available, and lets the user set up, update, or uninstall each one.

**Architecture:** Surface the already-shipped `RuntimeIntegration` plumbing (`state()` + `uninstall()`) through a thin service layer (`AgentStatus`, `allAgentStatuses`, `uninstall(agent:)`), a testable `@MainActor` view model, and a code-only `NSWindowController` hosting a SwiftUI view. The existing "Set Up Agent Integrations…" menu action opens the window instead of blind-installing.

**Tech Stack:** Swift, AppKit (`NSWindowController`, `NSHostingView`), SwiftUI, swift-testing (`import Testing`).

Design spec: `docs/superpowers/specs/2026-08-02-agent-integrations-manage-panel-design.md`

## Global Constraints

- **Scope is agents only.** Do NOT touch the `ghoztty` CLI setup flow (`installCommandLineTool`) or the first-launch prompt (`presentSetupDialog`). Copy these verbatim from the spec: "agents only", "first-launch prompt is unchanged".
- **Build the macOS app with `macos/build.nu`**, NOT `zig build`. Build: `macos/build.nu --configuration Debug --action build`. Test: `macos/build.nu --action test`. (Per `macos/AGENTS.md`.)
- **Lint with** `swiftlint lint --strict --fix` inside `macos/`.
- **Tests use swift-testing:** `import Testing` + `@testable import Ghostty`, `@Test`, `#expect`. Temp-home pattern: create a unique dir under `NSTemporaryDirectory()`, create `.claude`/`.copilot` subdirs as needed. Existing tests always pass `fileManager: .default` and vary only the home dir — follow that.
- **New `.swift` files under `macos/Sources/` and `macos/Tests/` are auto-included** via Xcode `PBXFileSystemSynchronizedRootGroup`. Do NOT edit `Ghostty.xcodeproj/project.pbxproj`.
- **NEVER modify `/Applications/Ghoztty.app`.** Test only with the debug build under `macos/build/Debug/`.
- **Existing public API used by this plan (do not change signatures):**
  - `RuntimeAgent`: `enum RuntimeAgent: String, CaseIterable, Sendable { case claude, copilot }`, `.displayName`, `.configDirectoryURL(homeDirectoryURL:) -> URL`.
  - `RuntimeIntegrationState`: `enum { case notInstalled, installed, outdated }` (Equatable, Sendable).
  - `RuntimeIntegrationFactory.make(for:homeDirectoryURL:fileManager:) -> RuntimeIntegration`.
  - `RuntimeIntegration.state() -> RuntimeIntegrationState`, `RuntimeIntegration.uninstall() throws`.
  - `ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL:fileManager:) -> Bool`.
  - `AgentIntegrationService.install(agent:homeDirectoryURL:fileManager:) -> IntegrationOutcome`, `.availableAgents(...)`, `.jqAvailable`, `.summary(_:)`.
  - `IntegrationOutcome` (in `AgentIntegrationService.swift`): `enum { case installed, upToDate, upgraded, notFound, pluginPresent, failed(String) }` with `var label: String`.
  - `LoginShell.homePath: String`.

---

### Task 1: Service — `IntegrationOutcome.uninstalled` + `AgentIntegrationService.uninstall(agent:)`

**Files:**
- Modify: `macos/Sources/Features/Setup/AgentIntegrationService.swift`
- Test: `macos/Tests/Ghostty/AgentIntegrationServiceTests.swift`

**Interfaces:**
- Consumes: `RuntimeIntegrationFactory.make(...)`, `RuntimeIntegration.uninstall()`.
- Produces:
  - `IntegrationOutcome.uninstalled` (label `"removed"`).
  - `static func AgentIntegrationService.uninstall(agent: RuntimeAgent, homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath), fileManager: FileManager = .default) -> IntegrationOutcome` — returns `.uninstalled` on success, `.failed(_)` on error.

- [ ] **Step 1: Write the failing tests**

Add to `macos/Tests/Ghostty/AgentIntegrationServiceTests.swift` (inside the `struct`):

```swift
    @Test func uninstallRemovesInstalledIntegration() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        #expect(AgentIntegrationService.uninstall(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .uninstalled)
        // After uninstall the skills file Ghoztty wrote is gone.
        let skill = home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md")
        #expect(!FileManager.default.fileExists(atPath: skill.path))
    }

    @Test func uninstalledOutcomeLabel() {
        #expect(IntegrationOutcome.uninstalled.label == "removed")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && ./build.nu --action test`
Expected: FAIL — `uninstalled` is not a member of `IntegrationOutcome`; `uninstall(agent:...)` does not exist (compile errors).

- [ ] **Step 3: Add the `.uninstalled` case + label**

In `macos/Sources/Features/Setup/AgentIntegrationService.swift`, extend the enum and its `label`:

```swift
enum IntegrationOutcome: Equatable {
    case installed, upToDate, upgraded, notFound, pluginPresent, uninstalled, failed(String)

    var label: String {
        switch self {
        case .installed: "installed"
        case .upToDate: "already up to date"
        case .upgraded: "upgraded"
        case .notFound: "not found"
        case .pluginPresent: "plugin already present"
        case .uninstalled: "removed"
        case .failed(let d): "failed — \(d)"
        }
    }
}
```

- [ ] **Step 4: Add the `uninstall(agent:)` method**

In the same file, add inside `enum AgentIntegrationService`:

```swift
    static func uninstall(agent: RuntimeAgent,
                          homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                          fileManager: FileManager = .default) -> IntegrationOutcome {
        let integ = RuntimeIntegrationFactory.make(for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        do {
            try integ.uninstall()
        } catch {
            return .failed(error.localizedDescription)
        }
        return .uninstalled
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd macos && ./build.nu --action test`
Expected: PASS (both new tests, plus the existing `AgentIntegrationServiceTests`).

- [ ] **Step 6: Lint**

Run: `cd macos && swiftlint lint --strict --fix Sources/Features/Setup/AgentIntegrationService.swift`
Expected: no violations.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Features/Setup/AgentIntegrationService.swift macos/Tests/Ghostty/AgentIntegrationServiceTests.swift
git commit -m "macos: add AgentIntegrationService.uninstall(agent:) + .uninstalled outcome"
```

---

### Task 2: Service — `AgentStatus` + `allAgentStatuses()`

**Files:**
- Modify: `macos/Sources/Features/Setup/AgentIntegrationService.swift`
- Test: `macos/Tests/Ghostty/AgentIntegrationServiceTests.swift`

**Interfaces:**
- Consumes: `RuntimeAgent.allCases`, `.configDirectoryURL(...)`, `RuntimeIntegrationFactory.make(...)`, `RuntimeIntegration.state()`, `ClaudeHookSpec().isExternalPluginInstalled(...)`.
- Produces:
  - `struct AgentStatus: Equatable, Sendable { let agent: RuntimeAgent; let detected: Bool; let state: RuntimeIntegrationState; let pluginManaged: Bool }`
  - `static func AgentIntegrationService.allAgentStatuses(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath), fileManager: FileManager = .default) -> [AgentStatus]` — one entry per `RuntimeAgent.allCases`, in `allCases` order.

- [ ] **Step 1: Write the failing tests**

Add to `macos/Tests/Ghostty/AgentIntegrationServiceTests.swift`:

```swift
    @Test func allAgentStatusesCoversEveryRuntime() throws {
        let home = try tempHome()
        let statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        #expect(statuses.map(\.agent) == RuntimeAgent.allCases)
    }

    @Test func undetectedAgentIsNotDetectedAndNotInstalled() throws {
        let home = try tempHome() // no .copilot / .claude dirs
        let statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        let copilot = try #require(statuses.first { $0.agent == .copilot })
        #expect(copilot.detected == false)
        #expect(copilot.state == .notInstalled)
        #expect(copilot.pluginManaged == false)
    }

    @Test func detectedInstalledAgentReportsInstalled() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        let statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        let copilot = try #require(statuses.first { $0.agent == .copilot })
        #expect(copilot.detected == true)
        #expect(copilot.state == .installed)
    }

    @Test func claudePluginPresenceReportsPluginManaged() throws {
        let home = try tempHome()
        let pluginsDir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try #"{"plugins":[{"name":"ghoztty"}]}"#
            .write(to: pluginsDir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)
        let statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        let claude = try #require(statuses.first { $0.agent == .claude })
        #expect(claude.pluginManaged == true)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && ./build.nu --action test`
Expected: FAIL — `AgentStatus` and `allAgentStatuses` do not exist (compile errors).

- [ ] **Step 3: Add `AgentStatus`**

In `macos/Sources/Features/Setup/AgentIntegrationService.swift`, above `enum AgentIntegrationService`:

```swift
/// A UI-facing snapshot of one runtime's Ghoztty-integration state.
struct AgentStatus: Equatable, Sendable {
    let agent: RuntimeAgent
    /// The runtime's config dir (~/.claude, ~/.copilot) exists on disk.
    let detected: Bool
    let state: RuntimeIntegrationState
    /// Claude only: an external `ghoztty` plugin already owns the hooks.
    let pluginManaged: Bool
}
```

- [ ] **Step 4: Add `allAgentStatuses()`**

Inside `enum AgentIntegrationService`:

```swift
    static func allAgentStatuses(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                                 fileManager: FileManager = .default) -> [AgentStatus] {
        RuntimeAgent.allCases.map { agent in
            let dir = agent.configDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            var isDir: ObjCBool = false
            let detected = fileManager.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
            let integ = RuntimeIntegrationFactory.make(for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            let pluginManaged = agent == .claude
                && ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            return AgentStatus(agent: agent, detected: detected, state: integ.state(), pluginManaged: pluginManaged)
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd macos && ./build.nu --action test`
Expected: PASS.

- [ ] **Step 6: Lint**

Run: `cd macos && swiftlint lint --strict --fix Sources/Features/Setup/AgentIntegrationService.swift`
Expected: no violations.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Features/Setup/AgentIntegrationService.swift macos/Tests/Ghostty/AgentIntegrationServiceTests.swift
git commit -m "macos: add AgentStatus + allAgentStatuses() for the manage panel"
```

---

### Task 3: `AgentIntegrationsViewModel`

**Files:**
- Create: `macos/Sources/Features/Setup/AgentIntegrationsViewModel.swift`
- Test: `macos/Tests/Ghostty/AgentIntegrationsViewModelTests.swift`

**Interfaces:**
- Consumes: `AgentIntegrationService.allAgentStatuses(...)`, `.install(...)`, `.uninstall(...)`, `.jqAvailable`, `AgentStatus`, `RuntimeAgent`.
- Produces:
  - `@MainActor final class AgentIntegrationsViewModel: ObservableObject`
  - `struct AgentIntegrationsViewModel.Row: Identifiable, Equatable { let agent: RuntimeAgent; var status: AgentStatus; var busy: Bool; var errorText: String?; var id: String }`
  - `@Published private(set) var rows: [Row]`
  - `@Published private(set) var jqMissing: Bool`
  - `init(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath))`
  - `func refresh()`
  - `func setUp(_ agent: RuntimeAgent) async`
  - `func update(_ agent: RuntimeAgent) async` (reinstall)
  - `func uninstall(_ agent: RuntimeAgent) async`

The view model always uses `FileManager.default` internally (matching every existing test, which varies only the home dir). This keeps the off-main-thread `Task.detached` closure capturing only `Sendable` values (a `URL` and a `RuntimeAgent`).

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/Ghostty/AgentIntegrationsViewModelTests.swift`:

```swift
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AgentIntegrationsViewModelTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func rowsCoverAllAgentTypes() throws {
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: try tempHome())
        #expect(vm.rows.map(\.agent) == RuntimeAgent.allCases)
    }

    @Test func undetectedAgentRowIsNotDetected() throws {
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: try tempHome())
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.detected == false)
        #expect(copilot.status.state == .notInstalled)
        #expect(copilot.busy == false)
        #expect(copilot.errorText == nil)
    }

    @Test func setUpInstallsAndUpdatesRow() async throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: home)
        await vm.setUp(.copilot)
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.state == .installed)
        #expect(copilot.busy == false)
        #expect(copilot.errorText == nil)
    }

    @Test func uninstallRemovesAndUpdatesRow() async throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: home)
        await vm.setUp(.copilot)
        await vm.uninstall(.copilot)
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.state == .notInstalled)
        #expect(copilot.errorText == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && ./build.nu --action test`
Expected: FAIL — `AgentIntegrationsViewModel` does not exist (compile errors).

- [ ] **Step 3: Implement the view model**

Create `macos/Sources/Features/Setup/AgentIntegrationsViewModel.swift`:

```swift
// macos/Sources/Features/Setup/AgentIntegrationsViewModel.swift
import Foundation

/// Drives the Agent Integrations window. Holds all logic so the view stays
/// declarative and the behavior is unit-testable without an NSWindow.
@MainActor
final class AgentIntegrationsViewModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let agent: RuntimeAgent
        var status: AgentStatus
        var busy: Bool = false
        var errorText: String?
        var id: String { agent.rawValue }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var jqMissing: Bool = false

    private let homeDirectoryURL: URL

    init(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath)) {
        self.homeDirectoryURL = homeDirectoryURL
        refresh()
    }

    /// Re-read every agent's state from disk, preserving any inline error text.
    func refresh() {
        let priorErrors = Dictionary(rows.map { ($0.agent, $0.errorText) }, uniquingKeysWith: { a, _ in a })
        rows = AgentIntegrationService
            .allAgentStatuses(homeDirectoryURL: homeDirectoryURL)
            .map { Row(agent: $0.agent, status: $0, busy: false, errorText: priorErrors[$0.agent] ?? nil) }
        jqMissing = !AgentIntegrationService.jqAvailable
    }

    func setUp(_ agent: RuntimeAgent) async {
        await run(agent) { home in
            AgentIntegrationService.install(agent: agent, homeDirectoryURL: home, fileManager: .default)
        }
    }

    func update(_ agent: RuntimeAgent) async { await setUp(agent) }

    func uninstall(_ agent: RuntimeAgent) async {
        await run(agent) { home in
            AgentIntegrationService.uninstall(agent: agent, homeDirectoryURL: home, fileManager: .default)
        }
    }

    private func run(_ agent: RuntimeAgent,
                     _ work: @escaping @Sendable (URL) -> IntegrationOutcome) async {
        setBusy(agent, true)
        let home = homeDirectoryURL
        let outcome = await Task.detached { work(home) }.value
        setBusy(agent, false)
        if case .failed(let message) = outcome {
            setError(agent, message)
        } else {
            setError(agent, nil)
        }
        refresh()
    }

    private func setBusy(_ agent: RuntimeAgent, _ value: Bool) {
        guard let i = rows.firstIndex(where: { $0.agent == agent }) else { return }
        rows[i].busy = value
    }

    private func setError(_ agent: RuntimeAgent, _ text: String?) {
        guard let i = rows.firstIndex(where: { $0.agent == agent }) else { return }
        rows[i].errorText = text
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos && ./build.nu --action test`
Expected: PASS (all four view-model tests).

- [ ] **Step 5: Lint**

Run: `cd macos && swiftlint lint --strict --fix Sources/Features/Setup/AgentIntegrationsViewModel.swift`
Expected: no violations.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Features/Setup/AgentIntegrationsViewModel.swift macos/Tests/Ghostty/AgentIntegrationsViewModelTests.swift
git commit -m "macos: add AgentIntegrationsViewModel (testable install/update/uninstall)"
```

---

### Task 4: SwiftUI view + window controller + menu wiring

This task has no new unit tests (SwiftUI rendering + AppKit window glue). Its deliverable is verified with a real build and a manual smoke test. It is one reviewable unit: a reviewer accepts or rejects "the panel opens from the menu and works".

**Files:**
- Create: `macos/Sources/Features/Setup/AgentIntegrationsView.swift`
- Create: `macos/Sources/Features/Setup/AgentIntegrationsController.swift`
- Modify: `macos/Sources/Features/Setup/AppDelegate+Setup.swift` (`setupAgentIntegrations` body only)

**Interfaces:**
- Consumes: `AgentIntegrationsViewModel` and its `Row`, `RuntimeAgent.displayName`, `RuntimeIntegrationState`.
- Produces:
  - `struct AgentIntegrationsView: View` (init `init(viewModel: AgentIntegrationsViewModel)`).
  - `@MainActor final class AgentIntegrationsController: NSWindowController` with `static let shared` and `func show()`.

- [ ] **Step 1: Create the SwiftUI view**

Create `macos/Sources/Features/Setup/AgentIntegrationsView.swift`:

```swift
// macos/Sources/Features/Setup/AgentIntegrationsView.swift
import SwiftUI

struct AgentIntegrationsView: View {
    @ObservedObject var viewModel: AgentIntegrationsViewModel
    @State private var confirmingUninstall: RuntimeAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Integrations").font(.headline)
                Text("Add Ghoztty's status banner, skills, and hooks to your coding agents.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    AgentIntegrationRow(
                        row: row,
                        onSetUp: { Task { await viewModel.setUp(row.agent) } },
                        onUpdate: { Task { await viewModel.update(row.agent) } },
                        onUninstall: { confirmingUninstall = row.agent })
                }
            }

            if viewModel.jqMissing {
                Label("The status banner needs jq — install it with: brew install jq",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(
            confirmingUninstall.map { "Remove Ghoztty integration from \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { confirmingUninstall != nil },
                set: { if !$0 { confirmingUninstall = nil } }),
            presenting: confirmingUninstall
        ) { agent in
            Button("Remove", role: .destructive) {
                confirmingUninstall = nil
                Task { await viewModel.uninstall(agent) }
            }
            Button("Cancel", role: .cancel) { confirmingUninstall = nil }
        } message: { _ in
            Text("This removes the banner script, skills, and hooks Ghoztty installed. Your configuration is otherwise untouched.")
        }
    }
}

private struct AgentIntegrationRow: View {
    let row: AgentIntegrationsViewModel.Row
    let onSetUp: () -> Void
    let onUpdate: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.agent.displayName)
                    .foregroundStyle(row.status.detected ? .primary : .secondary)
                Text(statusLabel).font(.footnote).foregroundStyle(.secondary)
                if row.status.pluginManaged {
                    Text("Hooks managed by Claude plugin").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = row.errorText {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Spacer()
            if row.busy {
                ProgressView().controlSize(.small)
            } else {
                actions
            }
        }
        .padding(.vertical, 10)
    }

    private var statusLabel: String {
        guard row.status.detected else { return "Not detected — install \(row.agent.displayName) to enable" }
        switch row.status.state {
        case .notInstalled: return "Not set up"
        case .installed: return "Installed"
        case .outdated: return "Update available"
        }
    }

    @ViewBuilder private var actions: some View {
        if row.status.detected {
            switch row.status.state {
            case .notInstalled:
                Button("Set Up", action: onSetUp)
            case .installed:
                Button("Uninstall", role: .destructive, action: onUninstall)
            case .outdated:
                Button("Update", action: onUpdate)
                Button("Uninstall", role: .destructive, action: onUninstall)
            }
        }
    }
}
```

- [ ] **Step 2: Create the window controller**

Create `macos/Sources/Features/Setup/AgentIntegrationsController.swift`:

```swift
// macos/Sources/Features/Setup/AgentIntegrationsController.swift
import Cocoa
import SwiftUI

/// Code-only window that hosts the Agent Integrations management view.
@MainActor
final class AgentIntegrationsController: NSWindowController {
    static let shared = AgentIntegrationsController()

    private let viewModel = AgentIntegrationsViewModel()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Agent Integrations"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        self.init(window: window)
        window.contentView = NSHostingView(rootView: AgentIntegrationsView(viewModel: viewModel))
        window.center()
    }

    func show() {
        viewModel.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 3: Wire the menu action to open the window**

In `macos/Sources/Features/Setup/AppDelegate+Setup.swift`, replace the entire body of `setupAgentIntegrations(_:)` (the method currently spanning the `DispatchQueue.global` block that lists agents, installs them, and shows a summary alert) with:

```swift
    @IBAction func setupAgentIntegrations(_ sender: Any?) {
        AgentIntegrationsController.shared.show()
    }
```

Leave `checkCommandLineToolOnLaunch`, `presentSetupDialog`, `installCommandLineTool`, and `showSetupAlert` unchanged. Confirm `AgentIntegrationService.availableAgents`, `.install`, `.summary`, and `.jqAvailable` are still referenced (they are — by `presentSetupDialog`), so no dead-code warnings arise.

- [ ] **Step 4: Build the app**

Run: `cd macos && ./build.nu --configuration Debug --action build`
Expected: build succeeds with no errors.

- [ ] **Step 5: Run the full test suite (guard against regressions)**

Run: `cd macos && ./build.nu --action test`
Expected: PASS (all existing + new tests).

- [ ] **Step 6: Lint the new/changed files**

Run: `cd macos && swiftlint lint --strict --fix Sources/Features/Setup/AgentIntegrationsView.swift Sources/Features/Setup/AgentIntegrationsController.swift Sources/Features/Setup/AppDelegate+Setup.swift`
Expected: no violations.

- [ ] **Step 7: Manual smoke test**

Launch the debug build:
`open -n macos/build/Debug/Ghoztty.app`
Then in the menu bar choose the **Ghoztty ▸ Set Up Agent Integrations…** item (also reachable via the command palette entry "Set Up Agent Integrations…"). Verify:
- A window titled "Agent Integrations" opens with one row per agent type.
- An agent with no config dir shows "Not detected …" and no buttons.
- An agent with a config dir shows a **Set Up** button; after clicking it, the row flips to "Installed" with an **Uninstall** button (a spinner shows briefly).
- **Uninstall** prompts a confirmation; confirming flips the row back to "Not set up".
- **Done** closes the window.

Quit the debug app when finished (do NOT touch `/Applications/Ghoztty.app`).

- [ ] **Step 8: Commit**

```bash
git add macos/Sources/Features/Setup/AgentIntegrationsView.swift macos/Sources/Features/Setup/AgentIntegrationsController.swift macos/Sources/Features/Setup/AppDelegate+Setup.swift
git commit -m "macos: Agent Integrations manage panel (show state, set up / update / uninstall)"
```

---

## Self-Review

**1. Spec coverage**
- Service `AgentStatus` + `allAgentStatuses` + `uninstall(agent:)` + `.uninstalled` → Tasks 1–2. ✓
- Code-only `NSWindowController` + `NSHostingView`, logic in testable view model → Tasks 3–4. ✓
- Per-row states (not detected / not set up / installed / update available) + buttons → Task 4 (`AgentIntegrationRow.statusLabel` / `actions`). ✓
- Claude plugin-managed note → Task 4 (`row.status.pluginManaged`). ✓
- Off-main-thread actions with spinner + inline error → Task 3 (`run`) + Task 4 (`ProgressView`, `errorText`). ✓
- jq-missing footer hint → Task 4 (`viewModel.jqMissing`). ✓
- Menu action opens panel; first-launch prompt unchanged → Task 4 Step 3. ✓
- Uninstall confirmation → Task 4 (`confirmationDialog`). ✓
- Testing (view-model + service tests) → Tasks 1–3. ✓

**2. Placeholder scan** — no "TBD"/"handle edge cases"/"write tests for the above"; every code step is complete. ✓

**3. Type consistency** — `AgentStatus`(agent/detected/state/pluginManaged) is produced in Task 2 and consumed identically in Tasks 3–4. `IntegrationOutcome.uninstalled` (Task 1) is matched in Task 3's `run` via the `.failed` case only (all non-failed outcomes clear the error). `AgentIntegrationsViewModel.Row`(agent/status/busy/errorText/id) defined in Task 3, consumed in Task 4. `setUp`/`update`/`uninstall` async signatures match between Tasks 3 and 4. `allAgentStatuses` / `install` / `uninstall` service signatures match their definitions. ✓
