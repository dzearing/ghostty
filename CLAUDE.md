# Ghoztty

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds CLI-driven window management for AI agents and automation.

Ghoztty ships on **macOS and Windows**, and the two are kept symmetric. Read
the platform-symmetry section below before you add anything.

## How to use these docs (progressive disclosure)

This file holds only the always-loaded core: the standing rules, the
non-negotiables, and a routing table. Everything else is partitioned by
scenario under `docs/claude/` — load the file for the work at hand rather than
all of them, and when you spawn a subagent (a test runner, a debugger, an
implementer), name the file(s) its task needs in its prompt so it loads only
its partition.

| If the task involves… | Read first |
|---|---|
| Driving ghoztty from a script or agent; any CLI verb, `+send-keys` semantics, targeting/naming, pane ids, IPC endpoints and timeouts, the `ghoztty://` scheme, links in terminal output | `docs/claude/cli.md` |
| Viewer panes (markdown/HTML/website/diff), navigation chrome, feedback capture, quoting, screenshots | `docs/claude/viewers.md` |
| Session persistence, `ghoztty-agent`, restore/re-attach/relaunch, the machine chooser, ANY app↔agent protocol change | `docs/claude/sessions.md` |
| Remote machines: `+new-remote-window`, per-host defaults, the connection pill, relay sign-in | `docs/claude/remote.md` |
| Building either platform, launch/debug, crash diagnostics, delivery | `docs/claude/build.md` |
| Writing or running ANY test or acceptance script; the harness audit rules | `docs/claude/testing.md` |
| Any pixel of win32 chrome | `docs/design/win32-design-system.md` + `docs/claude/win32-ui.md` |

The Windows session protocol lives in `go.md`; parity work is tracked in
`docs/design/windows-parity-tasks/` (one file per task) with
`docs/design/windows-parity-tasks.md` as the narrative index.

## Platform symmetry is a standing rule

**Every new feature must land in BOTH the macOS and the Windows build.** (User
directive, 2026-07-13.) A feature that exists on one platform and not the other
is an unfinished feature, not a platform-specific one — the divergence is the
defect, the same way an off-scale spacing value is a defect in the win32 design
system even when it looks fine in isolation.

What that means in practice:

- **Translate the feature, not the implementation.** Where a concept has no
  native counterpart, build the Windows-native equivalent rather than skipping
  it or emulating the Mac mechanism: AF_UNIX socket → owner-only-DACL **named
  pipe**, LaunchAgent → **HKCU Run** entry, Keychain → **DPAPI** store,
  `+list --tty` → `+list --pid`, `-lic` shell invocation → per-flavor
  (`pwsh -NoExit -Command`, `cmd /K`, `wsl --`). Every one of those pairs is
  documented in the sections below; follow the pattern instead of inventing a
  new one.
- **The CLI surface is identical on both platforms.** A verb, flag, or default
  that exists on one CLI and not the other is the divergence this project
  explicitly does not ship — Windows briefly had `+relay-login`/`+relay-logout`
  with no Mac analog and they were **removed** (T141), not kept. If a capability
  needs a GUI affordance on one platform, give it that affordance on both.
- **Land both, or file the other half.** If you genuinely cannot implement the
  second platform in the same change (no box to validate on, a dependency that
  is not ready), the change is not done until a task exists for the other
  seat — on Windows that is
  `powershell -NoProfile -File scripts\parity-tasks.ps1 new -Title "…"`, with
  `seat: mac` for work that only the Mac seat can validate. Never leave the
  gap undocumented.
- **Both seats work the same branch**, so pull before starting and push at
  every task boundary.


## Non-negotiables (in force for every task, however small)

- **Never touch the user's installed Ghoztty** — not `/Applications/Ghoztty.app`
  on macOS, not `%LOCALAPPDATA%\Programs\Ghoztty` or a portable copy on
  Windows. The installed app is the user's primary terminal. Always build and
  test against the `zig-out` debug build.
- **Windows builds need two flags to be safe**: `$env:ZIG_GLOBAL_CACHE_DIR`
  must sit on the repo's drive, and `-Doptimize=Debug` is mandatory — a
  release-mode dev build derives the SAME IPC/agent endpoints as the user's
  installed release and silently drives their terminal. `docs/claude/build.md`
  has the full story (T243, T350).
- **Stop repo agents by `ExecutablePath`, never by process name** — the
  installed release runs its own `ghoztty-agent.exe` that owns the user's live
  sessions. Recipe in `docs/claude/build.md`.
- **The app↔agent wire protocol is a compatibility boundary.** A running agent
  is routinely a different build than the app talking to it. Evolve additively,
  detect capability at runtime via the HELLO handshake, and route any breaking
  change through the mandatory update process — full contract in
  `docs/claude/sessions.md`.
- **Ghoztty is a permanent hard fork of Ghostty, and `origin` is the only
  remote.** Nothing is ever merged, cherry-picked, or rebased from
  ghostty-org/ghostty, and nothing is ever pushed anywhere but
  `github.com/dzearing/ghoztty`. The `upstream` remote was removed on
  2026-08-22; do not re-add it, do not fetch it by URL, and do not file or
  accept a task that depends on absorbing upstream. This is settled (D80,
  reversed by user directive) - it is not a question a future turn may re-open.
- **Everything gets tests**: pure logic → unit tests in the `none` lane;
  behavior → an on-box acceptance script in `test/win32/`. The harness rules in
  `docs/claude/testing.md` are enforced by sweeps and are not optional.

## Build & test quickstart

macOS:

```bash
zig build -Doptimize=Debug      # -> zig-out/Ghoztty-Debug.app (xcodebuild)
open -na zig-out/Ghoztty-Debug.app
```

Windows:

```powershell
$env:ZIG_GLOBAL_CACHE_DIR = 'D:\zig-global-cache'   # MUST be on the repo's drive
zig build -Dapp-runtime=win32 -Doptimize=Debug      # -> zig-out\bin\ghoztty.exe
```

The floor for any change — all green on the platform you changed, run through
the watchdog on Windows (details, filters, and the crash tooling are in
`docs/claude/build.md` and `docs/claude/testing.md`):

```powershell
powershell -NoProfile -File scripts\floor-lane.ps1 -Lane all   # lib + none + win32 + agent lanes
powershell -NoProfile -File test\win32\ipc-p1.ps1   # then ipc-p2.ps1, ipc-p3.ps1
```

## CLI at a glance

```
ghoztty +new-window | +split | +close | +rearrange | +read | +list | +sessions
        +send-keys | +set-state | +set-banner | +reload | +new-remote-window
```

All verbs are idempotent — named targets that already exist are focused, not
recreated — and every one answers or explains rather than blocking forever.
The semantics are subtle where it matters most (bracketed-paste framing and
trailing-newline rules in `+send-keys`, `--keys-file` for generated text, pane
identity and instance addressability, timeout policy): read
`docs/claude/cli.md` before scripting against them.

## Architecture

- **Zig core** (`src/`): terminal emulation, input handling, CLI commands, IPC client — shared by both platforms
- **Swift macOS app** (`macos/`): SwiftUI frontend, IPC server, split tree layout
- **Zig win32 app** (`src/apprt/win32/`): native Win32 frontend, IPC server (`IpcServer`/`IpcHandlers`/`IpcRegistry`), split tree layout, tab strip and chrome. Selected by `-Dapp-runtime=win32`, which is the default on Windows
- **`ghoztty-agent`** (`src/remote/agent/`): the session-persistence / remote-machines daemon, built by `zig build agent` and tested by `zig build test-agent`. One codebase, PTYs on macOS and ConPTYs on Windows
- Split panes use a binary tree (`SplitTree`) with a ratio (0.0–1.0) per split node, on both frontends
- IPC uses the same JSON messages on both platforms over a different local transport: a Unix domain socket at `$TMPDIR/ghostty[-debug]-<uid>.sock` on macOS, the named pipe `\\.\pipe\ghoztty[-debug]-<USERNAME>` on Windows. Both are overridden per pane by `$GHOZTTY_IPC_SOCKET` (see Instance addressability). The client side resolves in exactly one place on both platforms — `apprt.ipc.socketPath()` (`src/apprt/ipc.zig`), which delegates the pipe name to `ipc_client.endpointPath()` (`src/os/ipc_client.zig`) on Windows — so the derivation cannot drift
