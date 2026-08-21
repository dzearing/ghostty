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
  as-is for users who install via the `claude`/`copilot` plugin marketplace. The
  code for this work is entirely in the Ghoztty macOS app (plus a contributor-doc
  update; see Deliverables).
- **No plugin-marketplace install path.** We deliberately do not shell out to any
  CLI's `plugin install` (Copilot's is not a confirmed non-interactive command);
  the app writes files directly.
- No runtimes beyond Claude and Copilot are wired in this pass (the abstraction
  is built to accept more, but only these two ship).
- No changes to the `ghoztty` IPC commands (`+set-banner`, `+split`, …) the
  skills/hooks invoke — those are already agent-agnostic.
- No new "process-feedback" behavior; the existing skill is installed as-is.
- **Banner logic stays in the shell script** for this pass. Unifying it into a
  `ghoztty` CLI subcommand (so the script, the hooks, and the agent share one
  implementation) is an appealing follow-up but is out of scope: it drags in the
  Zig CLI core and the external plugin repo, and re-implements 391 lines of
  hard-won edge-case handling for no user-visible gain now. Recorded as a
  roadmap item (see Follow-ups).

## Review resolutions (2026-07-31)

A zodiac-team design review (Aquarius/Libra/Scorpio/Cancer) raised 17 findings;
the review file lives at
`.local/issues/2026-07-31__zodiac-fast-review-multi-runtime-integration.md`. The
five blocking (P1) findings are resolved in this spec as follows, and the
sections below reflect these decisions:

1. **Stable hook-script path (was: in-bundle path).** The generated hook must
   never reference a path inside `Ghoztty.app` — that path is versioned/
   translocated and moves on every update, which would make drift-detection
   report `outdated` forever and leave the installed hook pointing at a gone
   location. Install copies the script to a **stable owned path**
   `~/.config/ghoztty/hooks/ghoztty-banner.sh` and the hook references that.
2. **Claude uses merge semantics, Copilot uses whole-file.** Fact-checked:
   Claude Code stores user hooks in the **shared** `~/.claude/settings.json`
   (there is no auto-loaded `~/.claude/hooks/` dir; the external plugin registers
   through Claude's plugin system instead). Copilot auto-loads every file in
   `~/.copilot/hooks/`, so Ghoztty owns a dedicated file there. The ownership
   model is therefore an explicit axis with two strategies (below).
3. **External-plugin coexistence.** If the user already installed the external
   `ghoztty-claude-plugin`, its hooks also drive the banner; two writers would
   race. The Claude installer detects an existing plugin registration and skips
   (reporting "plugin already present") rather than installing a duplicate.
4. **Prompt sanitization.** `prompt` is agent-controlled free text rendered into
   a terminal banner; it is treated as opaque data end-to-end (argv/stdin, never
   interpolated into a shell string), truncated, and stripped of C0/C1/ESC bytes
   before reaching `+set-banner`.
5. **jq-free hook normalization.** Payload reshaping in the hook command uses
   `awk`/parameter-expansion (no `jq`), so a missing `jq` cannot break
   normalization before the shared script runs — the script's existing
   "jq not installed" banner (its state-merge is the only `jq` user) still fires.

## Where this lives

All new code is in the macOS app:

```
macos/Sources/Features/Setup/
├─ RuntimeAgent.swift              # enum .claude/.copilot: configDirectoryName, displayName, isAvailable
├─ RuntimeIntegration.swift        # [Component]; install()/uninstall()/state() with rollback
├─ RuntimeIntegrationFactory.swift # builds per-agent [skills, hooks] component lists
├─ SkillComponent.swift            # writes bundled SKILL.md → ~/<cfg>/skills/<name>/ (shared)
├─ HookComponent.swift             # shared file-write/ownership/drift + the two strategies
├─ ClaudeHookSpec.swift            # mergedFragment: events + payload normalizer → ~/.claude/settings.json
├─ CopilotHookSpec.swift           # dedicatedFile: events + payload normalizer → ~/.copilot/hooks/ghoztty.json
├─ BannerScriptInstaller.swift     # copies ghoztty-banner.sh → ~/.config/ghoztty/hooks/ (shared)
└─ AppDelegate+Setup.swift         # first-launch dialog + menu action (generalized)

macos/Resources/Ghoztty/           # bundled source-of-truth assets (new dir; registered as a bundle resource)
├─ skills/ghoztty/SKILL.md
├─ skills/process-feedback/SKILL.md
└─ hooks/ghoztty-banner.sh         # de-Claude-ified: neutral state dir + normalized payload
```

`ClaudeCodeIntegration.swift` is removed; its behavior is absorbed into the
abstraction above. Naming convention: a `*Component` type owns a `Component`'s
install/uninstall/state behavior; a `*HookSpec` is runtime-specific data (event
map + payload normalizer + file path/strategy) that the shared `HookComponent`
consumes — so the shared-vs-per-runtime seam is legible from the type names.

**Asset provenance.** The three bundled files originate as a one-time copy from
the external `dzearing/ghoztty-claude-plugin` repo, but from now on the **app
bundle is the source of truth for the app-install path** and the two copies
**diverge intentionally**: the bundled `ghoztty-banner.sh` is de-Claude-ified
(neutral state dir, normalized payload) and is not kept byte-identical to the
plugin's. The external repo remains the source of truth only for users who
install via `claude plugin`. There is no automated sync; the divergence is
deliberate and documented here.

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
- `isAvailable` — whether the runtime is present, used to gate offering/install.
  This is a **detection** signal, kept separate from the config dir Ghoztty
  *writes into* (see the gate-ordering note under the factory), so that Ghoztty
  leaving `skills/`/`hooks/` artifacts behind never makes a removed CLI look
  installed. Claude reuses the existing `findClaude()`-style binary probe.

### `RuntimeIntegration` + `Component`

A `RuntimeIntegration` is a runtime plus an ordered list of `Component`s, where a
`Component` is a behavioral unit exposing `{ state(), install(), uninstall() }`
plus a free-form `name` for logging/reporting. The source of truth is always the
on-disk files the components edit, so a user hand-removing a file is reflected
the next time `state()` is called.

- `install()` runs components front-to-back; on partial failure it rolls back
  the ones that succeeded (reverse order), so we never leave a half-installed
  state.
- `uninstall()` runs components reverse order; failures are collected, logged,
  and the first is rethrown after the sweep so one stuck artifact never blocks
  removing the rest.
- `state()` aggregates component states with this explicit total rule: **any
  component `notInstalled` → `notInstalled`; else any component `outdated` →
  `outdated`; else `installed`.** So skills-installed-but-hooks-missing reports
  `notInstalled` (the integration isn't wholly present) and skills-installed-
  plus-hooks-outdated reports `outdated` (re-install upgrades). This is the value
  the Registration-UX outcome mapping consumes, so it must be total.

**Design rationale (structure vs. a data table).** For two runtimes the
divergence is small enough that per-runtime `*HookSpec` values + a shared
`HookComponent` are clear and testable. The `Component` list is deliberately kept
open (not collapsed to a fixed `(skills, hooks)` pair) because a concrete third
component — an MCP-server config or an agent-instructions file — is a plausible
near-term addition, which is what earns the ordered-list + rollback machinery. If
the **runtime** count grows toward Supacode's ~11, the right refactor is to
collapse the `*HookSpec` types into one data-driven `RuntimeDescriptor` value
(configDir, displayName, hookPath, strategy, eventMap, normalizer) consumed by a
single generic component — noted here as the scaling path so a future
contributor doesn't add an 11th bespoke class by rote.

### `RuntimeIntegrationFactory`

The single construction site. `make(for:homeDirectoryURL:fileManager:)` returns
the `RuntimeIntegration` for an agent, composing `[skillsComponent,
hooksComponent]`. It wires the **install gate** here as a construction-time
invariant: `install()` first checks the runtime `isAvailable` (a signal Ghoztty
does not itself create) before doing anything — a proxy for "the CLI is
installed," so Ghoztty never bootstraps a harness the user has not set up.
**Ordering invariant:** availability is evaluated *before* Ghoztty creates any
subdirectories under the config dir; Ghoztty's own `skills/`/`hooks/`
subdirectories are created only after the gate passes, so provisioning never
contaminates the detection signal.

### `SkillComponent` (shared, portable)

Writes the bundled `SKILL.md` files (`ghoztty`, `process-feedback`) to
`~/<configDirectoryName>/skills/<name>/SKILL.md`. Identical logic for every
runtime — only `configDirectoryName` differs. `state()` byte-compares each
on-disk file against the bundled content: all-missing → `notInstalled`, all
present-and-equal → `installed`, otherwise `outdated`. Install renders all
files up front (so a missing bundled resource fails before any write) and rolls
back written files on error.

### Hook components (per-runtime data behind a shared component)

Adding a runtime touches four coordinated sites — a `RuntimeAgent` case (with
`configDirectoryName`/`displayName`/`isAvailable`), a `*HookSpec`, its wiring in
`RuntimeIntegrationFactory`, and the choice of ownership strategy. **The one
thing that never changes is the shared banner script.** Each `*HookSpec` supplies
that runtime's event map, payload normalizer, hooks-file path, and ownership
strategy; the shared `HookComponent` consumes a spec and performs the file
operations.

**Event mapping:**

| Purpose                     | Claude event              | Copilot event         |
| --------------------------- | ------------------------- | --------------------- |
| wipe/clear on new session   | `SessionStart` (startup\|clear) | `sessionStart`  |
| mark working, seed "Prompt" | `UserPromptSubmit`        | `userPromptSubmitted` |
| mark idle                   | `Stop`                    | `agentStop`           |

**Two ownership strategies** (an explicit axis, because the runtimes store hooks
differently):

- **`dedicatedFile` (Copilot).** Copilot auto-loads every file in
  `~/.copilot/hooks/`, so Ghoztty owns a standalone `~/.copilot/hooks/
  ghoztty.json`, shape `{ "version": 1, "hooks": { <event>: [ { "type":
  "command", "bash": <cmd>, "timeoutSec": N } ] } }`. Whole-file marker,
  byte-compare, delete-on-uninstall.
- **`mergedFragment` (Claude).** Claude has **no** auto-loaded hooks dir; user
  hooks live in the **shared** `~/.claude/settings.json` alongside unrelated user
  settings. A whole-file marker/compare/delete would be wrong (a JSON file can't
  hold a comment marker, and deleting it would destroy the user's Claude config).
  Instead Ghoztty inserts/updates/removes a **namespaced fragment** under the
  `hooks` key, tracking ownership by a stable, recognizable hook-command
  signature (the invocation of our banner script). `state()` compares only
  Ghoztty's fragment; uninstall removes only that fragment, leaving the rest of
  `settings.json` untouched. Writes go through a read-modify-write that preserves
  unknown keys.

**Normalized payload contract** (the seam that lets the shared script stay
runtime-agnostic). Each `*HookSpec`'s hook command reshapes its runtime's stdin
into a single shape before piping into `ghoztty-banner.sh`, using
`awk`/parameter-expansion — **never `jq`** (so a missing `jq` can't break
normalization; the script's own `jq` use for state-merge stays behind its
existing "jq not installed" banner):

| Field        | Type   | Required for              | Script behavior if absent          |
| ------------ | ------ | ------------------------- | ---------------------------------- |
| `prompt`     | string | prompt-submit hook only   | treated as empty; no "Prompt" seed |
| `session_id` | string | session-start & prompt    | treated as empty; no session wipe  |

The session-start and stop hooks carry neither a meaningful `prompt` nor require
one; the script tolerates missing/empty fields. The shape is versioned by an
implicit `v1` (the two fields above); a future field is additive.

**Prompt sanitization.** `prompt` is agent-controlled free text that ends up
rendered into a terminal banner, so it is treated as opaque data end-to-end: it
is passed via argv/stdin and **never interpolated into a shell command string**,
truncated to a fixed length, and stripped of C0/C1 and ESC control bytes before
it reaches `+set-banner` (and likewise on the OSC-7778 tty-fallback path). This
closes both the subshell-execution and the escape-sequence-spoofing vectors.

### Ownership marker, drift detection, idempotency

Ghoztty marks every artifact it writes so install/upgrade/uninstall only ever
touch Ghoztty-managed content, never a user's own file:

- **`dedicatedFile`** (Copilot hooks; skills; the banner script): a whole-file
  ownership sentinel (a comment for shell/JSON, a stable marker line for skills).
  **install** refuses to overwrite an existing file at our path that lacks the
  marker, then writes atomically; **state**: no file → `notInstalled`; marker +
  content == freshly-generated → `installed`; marker + content differs →
  `outdated` (older Ghoztty; re-install upgrades); marker absent → `notInstalled`
  (never overwrite a same-named user file); **uninstall** removes only
  marker-bearing files.
- **`mergedFragment`** (Claude hooks): the same three states but scoped to
  Ghoztty's fragment within the shared JSON — present-and-current → `installed`,
  present-but-different → `outdated`, absent → `notInstalled` — and uninstall
  removes only that fragment.

**Write safety.** Because one written artifact (`ghoztty-banner.sh`) is an
executable run on every hook event, writes are hardened against symlinked
dotfiles and check-then-write races: the temp file is created in the **target's
own directory** with `O_CREAT|O_EXCL` and mode `0700` (script) / `0600` (hook
JSON / skills), the final path is opened `O_NOFOLLOW` (refuse to write through a
symlink), and the ownership marker is re-verified on the final inode as part of
the atomic rename so a file appearing in the check→rename window can't be
clobbered.

### Banner script (`ghoztty-banner.sh`) install + changes

The script is **copied out of the app bundle to a stable owned path**,
`~/.config/ghoztty/hooks/ghoztty-banner.sh`, and the generated hooks reference
that absolute path — **never** a path inside `Ghoztty.app` (which is versioned/
translocated and would break the hook and permanently trip drift detection on
every update). The script is itself a `dedicatedFile`-managed artifact (marker,
drift, atomic write) so an app upgrade re-lays it down when its content changes.

The bundled script is the current Claude script with two runtime-neutralizing
edits — its banner rendering, tty/pane resolution, and state-merge logic are
unchanged:

1. **State dir** `$HOME/.claude/ghoztty-banner` → `$HOME/.config/ghoztty/
   banner-state` (Ghoztty already owns `~/.config/ghoztty`). Runtime-neutral, a
   single location regardless of which agent drives it.
2. **Payload:** the script reads a **single normalized shape** (`{prompt,
   session_id}`, per the contract above); each runtime's hook command does the
   `awk`-based normalization before piping in. Adding a future runtime therefore
   never edits this shared script — only that runtime's `*HookSpec`.

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
  `outdated`), `not found` (runtime not available when explicitly targeted),
  `plugin already present` (external `ghoztty-claude-plugin` detected — see
  below), `failed(detail)`.
- **User-visible copy.** The summary alert joins per-runtime outcomes, e.g.
  "Claude Code: installed · Copilot CLI: already up to date". A failure line
  reads "Copilot CLI: failed — \<detail\>. Re-run Set Up Agent Integrations… to
  try again." — always naming the retry path. Success on first launch stays
  silent.
- **`jq` prerequisite.** The banner needs `jq` at runtime. Install checks for
  `jq` up front and, if absent, still installs but appends a note to the summary
  ("Banner needs `jq` — install with `brew install jq`"), so the dependency is
  surfaced in the setup mindset rather than only later as a mid-session banner.

### External-plugin coexistence

Before installing anything into Claude's config dir, the factory checks whether
the external `ghoztty-claude-plugin` is registered (via
`installed_plugins.json`). If it is, its hooks already drive the banner, so
Ghoztty **skips both** its Claude hook install and its Claude skill install, and
reports `plugin already present` rather than installing a second, racing writer.

Skills are gated too, revised from an earlier "skills don't race, install them
anyway". They do race, just one level up: the app's skill and the plugin's copy
of the same skill differ, and the app's directs the agent at
`~/.config/ghoztty/hooks/ghoztty-banner.sh` while the plugin's hooks keep state
under `~/.claude/ghoztty-banner/`. Whichever the agent happens to load decides
which state directory the session writes — the same split-state failure the hook
gate exists to prevent, reached through the skill instead. One gate
(`RuntimeIntegrationFactory.isPluginManaged`) now covers both components.

Detection **parses** the manifest and matches the plugin name (the part before
`@`), rather than substring-matching the file. The manifest records each
install's `installPath` and, at project scope, its `projectPath`, so
`contains("ghoztty")` reports true for any *unrelated* plugin the user installed
from a ghoztty checkout — and Ghoztty would then decline to install, believing
its own plugin owned the runtime. The marketplace half of the key is
deliberately excluded from the match: the same plugin is registered through more
than one marketplace in practice. Both shapes of the manifest (`"version": 2`'s
keyed object and the older array) are accepted; an unrecognized shape reports
absent, since a false positive silently disables the integration while a false
negative merely duplicates a skill. These cases are documented and tested.

### Adding a runtime (extension checklist)

1. Add a `RuntimeAgent` case with `configDirectoryName`, `displayName`, and an
   `isAvailable` probe that does **not** depend on a dir Ghoztty writes into.
2. Add a `<Name>HookSpec`: its event map, its `awk`-based payload normalizer, its
   hooks-file path, and its ownership strategy (`dedicatedFile` or
   `mergedFragment`).
3. Wire the spec into `RuntimeIntegrationFactory` for the new case.
4. Add tests: skills install/idempotency/drift, hook install/idempotency/drift/
   marker-safety, install gate, and (if `mergedFragment`) fragment-scoped
   uninstall.

The shared `ghoztty-banner.sh` is **not** edited.

## Error handling

- **Install gate:** a runtime that is not available is skipped silently in the
  bulk action; a clear "\<name\> isn't installed yet. Install it, then run
  again." if explicitly targeted.
- **Ownership marker:** install/uninstall throw `fileNotManaged` rather than
  touch a same-named file (or, for Claude, a fragment) that lacks the sentinel.
- **Atomic + rollback:** `RuntimeIntegration.install()` rolls back succeeded
  components on partial failure; each component restores prior file contents (or
  deletes / restores the prior JSON) on a mid-write error.
- **Encoding/bundle errors:** hook source generation and skill rendering throw
  (never write a marker-less "valid-looking" file), failing before any write.

### Verifying / troubleshooting an install

A successful install produces, per runtime: `~/<cfg>/skills/ghoztty/SKILL.md` and
`~/<cfg>/skills/process-feedback/SKILL.md`; the runtime's hook artifact
(`~/.copilot/hooks/ghoztty.json` for Copilot, a `hooks` fragment in
`~/.claude/settings.json` for Claude); and the shared
`~/.config/ghoztty/hooks/ghoztty-banner.sh`. Install results are logged via the
app's `Logger` (subsystem `ClaudeCodeIntegration` → renamed to the new setup
category). **Dark-banner checklist** when hooks are installed but no banner
shows: confirm `TERM_PROGRAM=ghostty`, `jq` present, `$GHOZTTY_PANE_ID` set in
the pane, and the hook artifact still carries the Ghoztty marker.

## Testing

Follows Supacode's testability model: every installer takes an injected
`homeDirectoryURL` and `FileManager`, so tests run against a temp home with no
real config dirs touched. Swift unit tests (run via `macos/build.nu --action
test`):

- **Skills:** install writes both `SKILL.md` files at the expected per-runtime
  paths with the bundled content; idempotent (second install is a no-op /
  `installed`); editing a file → `outdated`; uninstall removes them.
- **Copilot hooks (`dedicatedFile`):** install writes `~/.copilot/hooks/
  ghoztty.json` with the marker, camelCase event keys, and `version: 1`;
  idempotent; content drift → `outdated`; **a same-named file without the marker
  is neither overwritten nor removed** (`fileNotManaged`); uninstall removes only
  the marked file.
- **Claude hooks (`mergedFragment`):** install inserts a `hooks` fragment into a
  pre-populated `settings.json` **without disturbing unrelated keys**; drift on
  the fragment → `outdated`; uninstall removes only the fragment and leaves the
  rest intact; a settings.json whose fragment lacks the signature is not touched.
- **Coexistence:** with the external plugin marked installed, the Claude hook
  install is skipped and reports `plugin already present` (skills still install).
- **Banner script:** installed to `~/.config/ghoztty/hooks/ghoztty-banner.sh`;
  the generated hooks contain that stable path and **no `.app` bundle path**; the
  bundled script references the neutral state dir and no longer hardcodes
  `$HOME/.claude`.
- **Sanitization:** a `prompt` containing `$(...)`, backticks, and `\e]0;` is
  neither executed nor passed through as raw escapes to `+set-banner`.
- **jq-free normalization:** the hook command run with `jq` absent still yields a
  correctly normalized payload (and the script's own "jq not installed" banner
  path is exercised separately).
- **Install gate:** with the runtime not available, `install()` throws
  `notInstalled(agent)` and writes nothing (including no subdirectories).
- **Integration rollback:** a component that fails to install rolls back the
  earlier component so no partial state remains.

## Deliverables

Besides the code + bundled assets above, this change updates contributor docs:
a one-paragraph map of the Setup subsystem and the bundled-asset location in
`HACKING.md` (or `CLAUDE.md`), cross-linking the "Adding a runtime" checklist,
so the new subsystem is discoverable rather than tribal knowledge.

## Open questions / follow-ups

- Exact Copilot `userPromptSubmitted` payload field for the user's prompt text
  — confirmed at implementation time against a live Copilot hook; the `awk`
  normalizer in `CopilotHookSpec` targets that field, and the shared script is
  unchanged regardless.
- **Unify banner logic into a `ghoztty` CLI subcommand** (roadmap). Moving the
  391-line script's logic into a `ghoztty +banner-*` command would let the
  script, the hooks, and the agent share one implementation and would collapse
  the sanitization and jq concerns into a single Swift/Zig site. Deferred: it
  reaches into the Zig CLI core and requires migrating the external plugin repo,
  so it is a deliberate later project, not part of this pass.
- Whether to later regenerate/publish the external plugin repo from these
  bundled assets is deferred; out of scope here.
