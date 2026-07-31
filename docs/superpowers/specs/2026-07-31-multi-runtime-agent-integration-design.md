# Multi-runtime agent integration (Copilot alongside Claude)

## Problem

Ghoztty can register itself with an AI coding agent so the agent learns to drive
its windows/panes and keeps a live per-pane status banner. Today this is
**Claude-only** in two ways:

1. **The macOS app** (`macos/Sources/Features/Setup/ClaudeCodeIntegration.swift`,
   `AppDelegate+Setup.swift`) shells out to `claude plugin marketplace add …`
   / `claude plugin install …`, and the first-launch dialog offers a single
   "Also set up Claude Code integration" checkbox gated on `claude` being found.
2. **The plugin content** (external repo `dzearing/ghoztty-claude-plugin`) is
   Claude-shaped: `.claude-plugin/` manifests, Claude hook event names
   (`SessionStart` / `UserPromptSubmit` / `Stop`), `${CLAUDE_PLUGIN_ROOT}`, and a
   banner script that writes state under `$HOME/.claude/…` and parses Claude's
   hook stdin payload.

GitHub Copilot CLI (and other runtimes) can also drive Ghoztty. Its skills
system reads the same `SKILL.md` format, but its hooks use different event names
(`sessionStart`, `userPromptSubmitted`, `preToolUse`, `postToolUse`,
`agentStop`, `sessionEnd`, `notification`), a different file (`~/.copilot/hooks/
*.json`), and a different stdin payload shape. So the skills are portable but the
banner automation is not, and there is no app-side path to register with any
runtime other than Claude.

We want the app to register Ghoztty with **Copilot as well as Claude**, behind a
small runtime abstraction that additional runtimes can slot into later.

## Goals

- Add a runtime abstraction in the macOS app that installs the Ghoztty
  integration into a coding agent's config directory, wired for **Claude Code**
  and **Copilot CLI** now.
- Install two components per runtime: **skills** (portable `SKILL.md` files) and
  the **banner-hook automation** (a runtime-shaped hooks file driving a shared
  `ghoztty-banner.sh`).
- Bundle the skill markdown + banner script in the Ghoztty app as the source of
  truth; write them directly to disk (no dependency on any CLI's `plugin
  install` subcommand and no network/git at setup time).
- Keep install idempotent, upgrade-aware (drift detection), safe (ownership
  marker, install gate), and atomic (rollback on partial failure).
- Generalize the first-launch dialog and menu action to cover every detected
  runtime.

## Non-goals

- **No changes to the external `dzearing/ghoztty-claude-plugin` repo.** It stays
  as-is for users who install via the `claude`/`copilot` plugin marketplace. This
  work is entirely in the Ghoztty macOS app.
- **No plugin-marketplace install path.** We deliberately do not shell out to any
  CLI's `plugin install` (Copilot's is not a confirmed non-interactive command);
  the app writes files directly.
- No runtimes beyond Claude and Copilot are wired in this pass (the abstraction
  is built to accept more, but only these two ship).
- No changes to the `ghoztty` IPC commands (`+set-banner`, `+split`, …) the
  skills/hooks invoke — those are already agent-agnostic.
- No new "process-feedback" behavior; the existing skill is installed as-is.

## Where this lives

All new code is in the macOS app:

```
macos/Sources/Features/Setup/
├─ RuntimeAgent.swift              # enum .claude/.copilot: configDirectoryName, displayName
├─ RuntimeIntegration.swift        # [Component]; install()/uninstall()/state() with rollback
├─ RuntimeIntegrationFactory.swift # builds per-agent [skills, hooks] component lists
├─ SkillInstaller.swift            # writes bundled SKILL.md → ~/<cfg>/skills/<name>/ (shared)
├─ HookInstaller.swift             # protocol + shared file-write/ownership/drift helpers
├─ ClaudeHookSettings.swift        # PascalCase events → ~/.claude hooks file
├─ CopilotHookSettings.swift       # camelCase events → ~/.copilot/hooks/ghoztty.json
├─ ClaudeCodeIntegration.swift     # (removed/absorbed into the abstraction)
└─ AppDelegate+Setup.swift         # first-launch dialog + menu action (generalized)

macos/Resources/Ghoztty/           # bundled source-of-truth assets
├─ skills/ghoztty/SKILL.md
├─ skills/process-feedback/SKILL.md
└─ hooks/ghoztty-banner.sh         # de-Claude-ified: neutral state dir + normalized payload
```

## Architecture

Modeled on Supacode's multi-runtime integration (`AgentIntegration` /
`AgentIntegrationFactory` / per-runtime `*HookSettings` + installers), which
supports ~11 runtimes from one codebase using exactly this shape.

### `RuntimeAgent` (the registry)

A `CaseIterable` enum, one case per supported runtime, that encodes the only
things that vary structurally between runtimes:

- `configDirectoryName` — home-relative config dir. `.claude` → `.claude`,
  `.copilot` → `.copilot`.
- `displayName` — user-facing, e.g. "Claude Code", "Copilot CLI".

### `RuntimeIntegration` + `Component`

A `RuntimeIntegration` is a runtime plus an ordered list of `Component`s. Each
`Component` is a `{ kind, state(), install(), uninstall() }` triple where
`kind ∈ {skills, hooks}`. The source of truth is always the on-disk files the
installers edit, so a user hand-removing a file is reflected the next time
`state()` is called.

- `install()` runs components front-to-back; on partial failure it rolls back
  the ones that succeeded (reverse order), so we never leave a half-installed
  state.
- `uninstall()` runs components reverse order; failures are collected, logged,
  and the first is rethrown after the sweep so one stuck artifact never blocks
  removing the rest.
- `state()` aggregates component states → `notInstalled | installed | outdated`.

### `RuntimeIntegrationFactory`

The single construction site. `make(for:homeDirectoryURL:fileManager:)` returns
the `RuntimeIntegration` for an agent, composing `[skillsComponent,
hooksComponent]`. It wires the **install gate** here as a construction-time
invariant: the integration carries a `requiredDirectory =
home/<configDirectoryName>` that `install()` checks exists before doing anything
— a proxy for "the CLI is installed," so Ghoztty never bootstraps a harness the
user has not set up. (Ghoztty's own subdirectories under it — `skills/`,
`hooks/` — are still created.)

### `SkillInstaller` (shared, portable)

Writes the bundled `SKILL.md` files (`ghoztty`, `process-feedback`) to
`~/<configDirectoryName>/skills/<name>/SKILL.md`. Identical logic for every
runtime — only `configDirectoryName` differs. `state()` byte-compares each
on-disk file against the bundled content: all-missing → `notInstalled`, all
present-and-equal → `installed`, otherwise `outdated`. Install renders all
files up front (so a missing bundled resource fails before any write) and rolls
back written files on error.

### Hook installers (per-runtime — the only place runtimes truly diverge)

`ClaudeHookSettings` and `CopilotHookSettings` each produce a deterministic
runtime-shaped hooks file and know that runtime's path:

- **Claude:** its settings/hooks file using PascalCase events `SessionStart`
  (matcher `startup|clear`), `UserPromptSubmit`, `Stop`.
- **Copilot:** `~/.copilot/hooks/ghoztty.json` — Copilot auto-loads every JSON
  in that dir, so Ghoztty owns its own file. Shape `{ "version": 1, "hooks":
  { <event>: [ { "type": "command", "bash": <cmd>, "timeoutSec": N } ] } }`
  with camelCase events. Mapping:

  | Purpose                     | Claude event              | Copilot event         |
  | --------------------------- | ------------------------- | --------------------- |
  | wipe/clear on new session   | `SessionStart` (startup\|clear) | `sessionStart`  |
  | mark working, seed "Prompt" | `UserPromptSubmit`        | `userPromptSubmitted` |
  | mark idle                   | `Stop`                    | `agentStop`           |

A shared `HookInstaller` provides the common file operations: create the hooks
dir, write atomically, and the ownership/drift logic below. Each hook `bash`
command is emitted by its `*HookSettings` and is responsible for **normalizing
that runtime's stdin payload** into the shape the shared script expects (see
Banner script), then invoking `ghoztty-banner.sh`.

### Ownership marker, drift detection, idempotency

Every file Ghoztty writes carries an ownership-marker sentinel (a comment for
the shell/JSON hooks, a stable marker for skills):

- **install** refuses to overwrite an existing file at our path that lacks the
  marker (never clobber a user's own `ghoztty.json`), creates the dir, writes
  atomically.
- **state**: no file → `notInstalled`; file present, marker present, content ==
  freshly-generated → `installed`; marker present, content differs → `outdated`
  (older Ghoztty version installed; re-install upgrades it); marker absent →
  `notInstalled` (so auto-update never overwrites a user file sharing the name).
- **uninstall** removes only marker-bearing files.

### Banner script (`ghoztty-banner.sh`) changes

The bundled script is the current Claude script with two runtime-neutralizing
edits — its banner rendering, tty/pane resolution, and state-merge logic are
unchanged:

1. **State dir** `$HOME/.claude/ghoztty-banner` → `$HOME/.config/ghoztty/
   banner-state` (Ghoztty already owns `~/.config/ghoztty`). Runtime-neutral, a
   single location regardless of which agent drives it.
2. **Payload:** the script's `prompt-hook`/`session-start-hook` currently read
   Claude's stdin JSON (`.prompt`, `.session_id`). Per the approved design
   (Option A), the script keeps reading a **single normalized shape**
   (`{prompt, session_id}`) and each runtime's hook command does the
   normalization before piping in. Adding a future runtime therefore never edits
   this shared script — only that runtime's `*HookSettings`.

The script still no-ops unless `TERM_PROGRAM=ghostty`, still resolves the target
pane via `$GHOZTTY_PANE_ID` (falling back to tty), and still surfaces a
"jq not installed" banner rather than exiting silently.

## Registration UX

`AppDelegate+Setup.swift`:

- **First-launch dialog:** after the existing "Set Up the ghoztty Command?"
  prompt, show **one checkbox per detected runtime** ("Also set up Claude Code
  integration", "Also set up Copilot CLI integration"), each on by default. A
  runtime whose config dir is absent is not offered. On accept, install into the
  checked runtimes off the main thread; success stays silent (first launch stays
  quiet), failures show a per-runtime warning.
- **Menu / command palette:** replace the single `setupClaudeCodeIntegration`
  action with **"Set Up Agent Integrations…"**, which installs into every
  detected runtime and shows a per-runtime summary alert (e.g. "Claude Code:
  installed · Copilot CLI: already up to date"). Self-adjusting as runtimes are
  added; no per-runtime menu items to maintain.
- **Outcomes** reported per runtime, derived from integration `state()` +
  install result: `installed`, `already up to date`, `upgraded` (was
  `outdated`), `not found` (config dir absent when explicitly targeted),
  `failed(detail)`.

## Error handling

- **Install gate:** a runtime whose config dir is absent is "not available" —
  skipped silently in the bulk action; a clear "\<name\> isn't installed yet.
  Install it, then run again." if explicitly targeted.
- **Ownership marker:** install/uninstall throw `fileNotManaged` rather than
  touch a same-named file that lacks the sentinel.
- **Atomic + rollback:** `RuntimeIntegration.install()` rolls back succeeded
  components on partial failure; `SkillInstaller`/`HookInstaller` restore prior
  file contents (or delete) on a mid-write error.
- **Encoding/bundle errors:** hook source generation and skill rendering throw
  (never write a marker-less "valid-looking" file), failing before any write.

## Testing

Follows Supacode's testability model: every installer takes an injected
`homeDirectoryURL` and `FileManager`, so tests run against a temp home with no
real config dirs touched. Swift unit tests (run via `macos/build.nu --action
test`):

- **Skills:** install writes both `SKILL.md` files at the expected per-runtime
  paths with the bundled content; idempotent (second install is a no-op /
  `installed`); editing a file → `outdated`; uninstall removes them.
- **Hooks (Claude + Copilot):** install writes the expected file at the expected
  path with the marker; the Copilot JSON has the camelCase event keys and
  `version: 1`; idempotent; content drift → `outdated`; **a same-named file
  without the marker is neither overwritten nor removed** (`fileNotManaged`);
  uninstall removes only marked files.
- **Install gate:** with the runtime's config dir absent, `install()` throws
  `notInstalled(agent)` and writes nothing.
- **Integration rollback:** a component that fails to install rolls back the
  earlier component so no partial state remains.
- **Banner script:** a focused check that the bundled script references the
  neutral state dir and no longer hardcodes `$HOME/.claude`.

## Open questions / follow-ups

- Exact Copilot `userPromptSubmitted` payload field for the user's prompt text
  — confirmed at implementation time against a live Copilot hook; the normalizer
  in `CopilotHookSettings` targets that field, and the shared script is unchanged
  regardless.
- Whether to later regenerate/publish the external plugin repo from these
  bundled assets (Section-1 option C) is deferred; out of scope here.
