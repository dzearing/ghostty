# Agent Integrations Manage Panel — Design

Date: 2026-08-02
Status: Approved (design)
Depends on: `2026-07-31-multi-runtime-agent-integration-design.md`

## Problem

The multi-runtime agent-integration work (branch
`users/zekearanylucas/multi-runtime-agent-integration`) shipped the plumbing to
install/uninstall Ghoztty's per-agent integration components (banner script,
skills, hooks) for each supported coding-agent runtime (Claude Code, Copilot
CLI), plus per-agent install-state tracking. But the surfaced UI is two
`NSAlert`s:

- **First-launch prompt** (`AppDelegate+Setup.presentSetupDialog`): per-agent
  checkboxes, all defaulted **on**, with **no indication of current state**.
- **Menu action** (`setupAgentIntegrations`): blindly (re)installs **every**
  detected agent and shows a text summary. No per-agent state, no choice, no
  uninstall.

There is no way for a user to see what is already set up, update an outdated
integration, or remove one. The underlying capability already exists
(`RuntimeIntegration.state()` and `RuntimeIntegration.uninstall()`); it is
simply not surfaced.

## Goals

- Show, per supported agent type, whether Ghoztty's integration is **not
  detected**, **not set up**, **installed**, or **update available**.
- Let the user **set up**, **update**, and **uninstall** each agent's
  integration individually, with clear per-row actions.
- Present all of this in a proper manage surface rather than an `NSAlert`
  accessory view.

## Non-Goals

- The `ghoztty` CLI tool setup (`~/.local/bin` link) stays a **separate**
  concern with its own menu item and alert flow. This panel is **agents only**.
- No change to the first-launch prompt behavior.
- No new agent runtimes.

## Design

### A. Service layer (`AgentIntegrationService`)

Add a single source of truth the UI can render from, over the existing
`RuntimeIntegrationFactory` / `RuntimeIntegration`.

```swift
struct AgentStatus: Equatable {
    let agent: RuntimeAgent
    let detected: Bool                  // config dir (~/.claude, ~/.copilot) exists
    let state: RuntimeIntegrationState  // .notInstalled / .installed / .outdated
    let pluginManaged: Bool             // Claude external plugin owns hooks
}
```

New members:

- `allAgentStatuses(homeDirectoryURL:fileManager:) -> [AgentStatus]` — one entry
  for **every** `RuntimeAgent.allCases` (detected or not), in a stable order.
  For an undetected agent, `state == .notInstalled` and `detected == false`.
  `pluginManaged` reuses `ClaudeHookSpec().isExternalPluginInstalled(...)`.
- `uninstall(agent:homeDirectoryURL:fileManager:) -> IntegrationOutcome` — wraps
  `RuntimeIntegration.uninstall()`. Returns a new `.uninstalled` outcome on
  success, `.failed(_)` on error. (Add `.uninstalled` to `IntegrationOutcome`.)

`install(agent:)`, `availableAgents()`, `summary(_:)`, and `jqAvailable` are
unchanged. `availableAgents()` stays (first-launch prompt still uses it).

### B. UI

A **code-only** `NSWindowController` — `AgentIntegrationsController` — modeled on
`AboutController` but **without a XIB**: it builds a plain titled `NSWindow` and
sets its `contentView` to an `NSHostingView(rootView: AgentIntegrationsView)`.
`static let shared` singleton; `show()` centers and orders front. Escape/close
behavior mirrors `AboutController`.

`AgentIntegrationsView` (SwiftUI) renders from an `ObservableObject` view model,
`AgentIntegrationsViewModel`, that holds **all logic** (so it is unit-testable
without the window):

- `@Published var rows: [AgentRow]` where `AgentRow` wraps an `AgentStatus` plus
  a transient `busy: Bool` and optional `errorText: String?`.
- `refresh()` — recomputes rows from `AgentIntegrationService.allAgentStatuses`.
- `setUp(_:)`, `update(_:)`, `uninstall(_:)` — set the row `busy`, run the
  service call **off the main thread**, then refresh that row's state (and clear
  or set `errorText`) back on the main thread.
- `jqMissing: Bool` — drives the footer hint.

Per-row rendering (one row per agent type):

| Status | Label | Buttons |
| --- | --- | --- |
| Not detected | "Not detected" (dimmed); subtitle "Install *Claude Code* to enable" | — |
| Not set up (detected, `.notInstalled`) | "Not set up" | **Set Up** |
| Installed (`.installed`) | ✓ "Installed" | Uninstall (destructive role) |
| Update available (`.outdated`) | "Update available" | **Update** · Uninstall |

- A Claude row with `pluginManaged == true` shows an informational note "Hooks
  managed by Claude plugin" (skills + banner are still managed by Ghoztty, so
  Set Up/Uninstall still apply to those components).
- While a row is `busy`, its buttons are replaced by a small spinner.
- `errorText`, when set, renders inline under the row in the error color.

Footer: the jq-missing hint ("The status banner needs jq — install it with
`brew install jq`") shown only when `jqMissing`, and a **Done** button that
closes the window.

### C. Wiring

- `AppDelegate.setupAgentIntegrations(_:)` changes from blind-install to
  `AgentIntegrationsController.shared.show()` (on the main thread).
- The menu item / command-palette entry keeps its existing title and selector;
  only the action's behavior changes.
- First-launch `presentSetupDialog` is **unchanged**.

### D. Uninstall confirmation

Before running an uninstall, present a confirmation `NSAlert`:

> **Remove Ghoztty integration from Claude Code?**
> This removes the banner script, skills, and hooks Ghoztty installed. Your
> Claude Code configuration is otherwise untouched.
>
> [Remove] [Cancel]

Only on confirm does the view model call `uninstall(_:)`. `Remove` uses the
destructive button styling. The underlying `RuntimeIntegration.uninstall()`
already reverses only Ghoztty-marked `ManagedFile` writes and hook fragments, so
user content is preserved.

### E. Testing

- **View-model tests** (`AgentIntegrationsViewModelTests`): with injected
  `homeDirectoryURL` + `fileManager` fixtures, assert the row list maps each
  `AgentStatus` to the right label/button set (not detected / not set up /
  installed / outdated / plugin-managed), and that `setUp`/`uninstall` drive the
  expected state transition and clear `busy`.
- **Service tests** (extend `AgentIntegrationServiceTests`): `allAgentStatuses`
  returns an entry per `RuntimeAgent.allCases` with correct `detected`/`state`/
  `pluginManaged`; `uninstall(agent:)` returns `.uninstalled` on success and
  `.failed` on error.
- The existing `RuntimeIntegrationTests` uninstall/rollback coverage already
  exercises the plumbing and is unchanged.
- Controller/window wiring is not unit-tested (thin, matches `AboutController`);
  all logic lives in the view model.

## Files

New:
- `macos/Sources/Features/Setup/AgentIntegrationsController.swift`
- `macos/Sources/Features/Setup/AgentIntegrationsView.swift`
- `macos/Sources/Features/Setup/AgentIntegrationsViewModel.swift`
- `macos/Tests/Ghostty/AgentIntegrationsViewModelTests.swift`

Changed:
- `macos/Sources/Features/Setup/AgentIntegrationService.swift`
  (`AgentStatus`, `allAgentStatuses`, `uninstall(agent:)`, and add
  `IntegrationOutcome.uninstalled` — `IntegrationOutcome` is defined in this
  file)
- `macos/Sources/Features/Setup/AppDelegate+Setup.swift`
  (`setupAgentIntegrations` opens the panel)
- `macos/Tests/Ghostty/AgentIntegrationServiceTests.swift`
- `macos/Ghostty.xcodeproj/project.pbxproj` (register new files)
