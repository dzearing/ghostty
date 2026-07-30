# Ghoztty Windows parity spec — "a replica of the Mac version"

Status: **spec — ready for execution on the Windows box**
Branch: `users/dzearing/windows-amd64`
Written: 2026-07-06 · Supersedes the beta cut lines in `windows-amd64-plan.md`
(that doc remains the port history; this doc is the forward plan).

## Mission

Bring the Windows build to functional parity with the macOS Ghoztty fork.
Parity means, concretely:

1. **IPC window management** — the full CLI surface documented in `CLAUDE.md`
   (`+new-window`, `+split`, `+close`, `+read`, `+send-keys`, `+set-state`,
   `+rename`, `+rearrange`, `+list`) works against the Windows app with the
   same semantics.
2. **Skill compatibility** — the `ghoztty` skill (which drives that CLI) works
   unmodified when Claude Code runs on the Windows box.
3. **Activity monitoring** — `+set-state` / OSC 7777 with per-window
   aggregation and the ` (busy)` / ` (needs_input)` title suffix.
4. **Window title naming** — `--title`, `+rename`, title-override precedence.
5. **Hero mode + swap_split** — the fork's GUI split features.
6. **Remote machines** — open terminals on other machines from the Windows
   app via agent/relay (`+new-remote-window`), sign-in included.

**Definition of done:** the conformance checklist (§8) passes end-to-end on
the Windows box, executed by Claude Code running there, including the
three-pane example from `CLAUDE.md` verbatim.

## Current state (2026-07-06)

Works on Windows (portable zip on the share, commits `e0118f682..83b293932`):
window+tabs+splits GUI, ConPTY shell, WGL/OpenGL rendering, freetype_windows
fonts, clipboard, ctrl-based default keybinds mirroring the Mac cmd set,
release file-log at `%LOCALAPPDATA%\ghoztty\ghoztty.log`.

Not implemented (this spec): everything in the Mission list. Today
`performIpc` in `src/apprt/win32/App.zig` returns `false` (all IPC CLI
commands print "+<cmd> failed."), and `+list`/`+read`/`+rearrange`/
`+new-remote-window` are comptime-guarded off. The win32 App returns `false`
for the fork actions `swap_split`, `toggle_hero_mode`, `activity_state`.

## Reference implementations (the contract)

- **CLI semantics:** `CLAUDE.md` (repo root) — commands, flags, idempotency
  rules, key notation, the three-pane example.
- **IPC server:** `macos/Sources/Features/IPC/IPCServer.swift` (~1.7k lines)
  — action dispatch (`new-window`, `split`, `close`, `rename`, `rearrange`,
  `list`, `read`, `send-keys`, `set-state`, `new-remote-window`), the
  `targetRegistry` (name → window/pane weak refs, stale pruning), focus
  behavior, `--no-activate`, response shapes.
- **Wire protocol:** `src/apprt/none.zig` `sendIpc` (client side) — 4-byte
  big-endian length + JSON `{action, arguments:[…]}` request; same framing
  back with JSON `{success: bool, error?: string, data?: …}`. Reuse
  `apprt/ipc.zig` `parseResponse`.
- **Activity state:** `BaseTerminalController.swift:1296` — when aggregated
  state ≠ idle, title gets ` (busy)` / ` (needs_input)` appended.
  Aggregation across panes: `needs_input > busy > idle`
  (`IPCServer.swift` handleSetState). OSC `\e]7777;<state>\a` feeds the same
  path via the core's `activity_state` apprt action.
- **Title precedence:** user/IPC `titleOverride` beats terminal-set titles
  (`BaseTerminalController.titleOverride`).
- **Remote client core is Zig, not Swift:** `src/remote/` (ws_client,
  relay_dial, client_mux, connection, ssh_transport) and the termio
  `.remote` backend are shared core. The Swift app supplies only sign-in UI,
  machine chooser, creds storage, and window plumbing — that's what the
  win32 apprt must replicate for P6.
- Mac-only, explicitly **out of scope**: AX accessibility attributes
  (`AXWindowActivityState`, `AXGhosttyMachine` — ztabby is a Mac consumer),
  titlebar machine pill visual parity (a text suffix is acceptable on
  Windows), Sparkle updates.

## Architecture decisions (pinned)

- **Transport: named pipe** `\\.\pipe\ghoztty-<username>` (release) /
  `\\.\pipe\ghoztty-debug-<username>` (debug), mirroring the Mac socket
  suffix rule. Named pipes over AF_UNIX-on-Windows: native, ACL-able
  (owner-only DACL, like the agent's relay.env hardening), and Zig std
  support for AF_UNIX on Windows is unreliable.
- **Same wire protocol** as Mac (length-prefixed JSON). The CLI client code
  in each `src/cli/*.zig` stays; only the connect/write/read layer branches
  per-OS. Implement the Windows client in ONE shared helper
  (`src/os/ipc_pipe.zig` or similar) so all commands use it.
- **Server lives in the win32 App**: a listener thread owning the pipe;
  requests marshaled to the main thread via the existing message-only window
  (`WM_APP_*` + response event), because all registry/window operations must
  run on the GUI thread. Connections are short-lived request/response —
  thread-per-connection blocking IO is fine.
- **Single instance:** first process binds the pipe and is the master. A
  second GUI launch detects the busy pipe, forwards a `new-window` request,
  and exits (Mac single-app behavior). `+new-window` with no instance spawns
  `ghoztty.exe` detached and retries the connect with backoff (parity with
  the Mac sentinel/retry flow in `apprt/none.zig`).
- **Registry:** `std.StringHashMap(TargetEntry)` in win32 App;
  `TargetEntry = union { window: HWND, pane: *Surface }` with liveness
  checks + stale pruning on every lookup (mirror `pruneStaleTargets`).
  Idempotency: registering an existing live name focuses it instead of
  creating (CLAUDE.md rule); `+close` on a missing target returns success.
- **Shell invocation** for `--command`/`--split-command`/`--shell`
  (`command-shell` config → `--shell` flag → default). On Windows:
  - `pwsh.exe` / `powershell.exe` → `-NoExit -Command "<cmd>"`
  - `cmd.exe` (default when nothing configured) → `/K "<cmd>"`
  - anything else (e.g. git-bash `bash.exe`) → `-lic "<cmd>"` (Mac behavior)
- **send-keys notation** ported verbatim from `IPCServer.swift`
  handleSendKeys: `C-<x>` → ctrl byte, named keys `Enter`/`Tab`/`Escape`/
  `Space`/`Backspace`, escapes `\n \t \r \\ \e`; concatenated and written
  to the target pane's PTY.
- **`+read`**: dump last N lines of the target pane's screen+scrollback via
  the core's plain-text screen dump (same machinery as `write_screen_file`),
  taking the renderer mutex; response carries the text in `data`.
- **`+list`**: output text format must match the Mac rendering (window →
  tabs → panes tree with `[target: …]`, `[name: …]`, focused markers) —
  the skill parses this. Golden-file the Mac output shape in a test.

## Phases

Each phase = one milestone commit series on this branch, built AND tested on
the Windows box before moving on. Acceptance = the listed script/checks pass.

### P0 — dev bootstrap on the Windows box
- Install: git, zig **0.15.2** (exact; `winget install zig.zig --version
  0.15.2` or ziglang.org binary), Claude Code for Windows.
- Clone the repo, checkout `users/dzearing/windows-amd64`.
- `zig build -Dapp-runtime=win32 -Doptimize=Debug` **natively** (target
  defaults to win32 on Windows per `apprt/runtime.zig`). Debug = Console
  subsystem → stderr logs visible.
- Acceptance: debug ghoztty.exe launches from a native build; typing works;
  `zig build test -Dapp-runtime=none` passes (upstream keeps this green on
  Windows CI — deviations are OUR bugs).

### P1 — IPC transport + first verbs
- Pipe server thread + main-thread marshal + owner-only DACL.
- Client helper + un-guard the CLI paths behind `os.tag == .windows`.
- Verbs: `list` (registry rendering), `new-window` (all flags: `--target`,
  `--working-directory`, `--command`, `--shell`, `--title`, `--split`,
  `--split-command`, `--no-activate`, `-e`), `close`, auto-launch, second-
  instance forwarding.
- Acceptance (PowerShell script, checked into `test/win32/ipc-p1.ps1`):
  create/focus/close named windows, idempotent re-create, close-missing
  succeeds, auto-launch from cold, `+list` shape matches Mac golden file.

### P2 — panes: `split`, `+rename`, `send-keys`
- `+split` with `--direction`, `--target` (window OR pane), `--name`,
  `--command`, `--shell`, `--working-directory`, `-e`; pane registry.
- `+rename` → titleOverride semantics (wins over terminal titles).
- `+send-keys` full notation table.
- Acceptance: `test/win32/ipc-p2.ps1` — build a 3-pane layout by name, send
  `"ls -la" Enter` and `C-c`, rename a window and verify the title bar.

### P3 — `+read`, `+set-state`, OSC 7777, `+rearrange`
- `+read --name --lines` returns trailing screen+scrollback lines.
- `+set-state` + OSC 7777 → per-pane state, window aggregation
  (`needs_input > busy > idle`), title suffix ` (busy)`/` (needs_input)`,
  cleared on `idle`. Implement the `activity_state` apprt action in win32
  App (replace the `return false` stub).
- `+rearrange` layout ops (reference `handleRearrange` in the Swift server).
- Acceptance: `test/win32/ipc-p3.ps1` — echo into a pane and `+read` it
  back; set busy/needs_input/idle and assert title changes; OSC round-trip
  via `printf '\e]7777;busy\a'`.

### P4 — skill conformance
- Run the `ghoztty` skill's flows from Claude Code **on the box**: the
  CLAUDE.md three-pane example verbatim, plus the skill's list/read/
  send-keys/set-state loops.
- Fix every divergence; add regressions to the P1–P3 scripts.
- Acceptance: a Claude Code session on Windows can manage windows/panes via
  the skill with zero modified skill code. **This closes the original ask.**

### P5 — hero mode + swap_split (GUI parity)
- `swap_split` — core `SplitTree.swap` exists (fork feature); win32 App
  needs the action arm + re-layout (currently `return false`).
- `toggle_hero_mode` — focused pane full-size left, carousel right
  (reference the Mac implementation in `macos/Sources/Features/Terminal/`).
  This is pure win32 layout work in `Window.zig`.
- Acceptance: keybind + IPC-driven swap/hero on a 3-pane layout, visually
  verified + screenshot archived.

### P6 — remote machines on Windows
The transport/mux core is already-shared Zig; the work is client plumbing:
- **CLI-first:** `+new-remote-window --host/--port` (direct TCP), then
  `--relay/--device`. Un-guard the CLI, implement the dial in win32 App
  using `src/remote` (tcp_dial/relay_dial/connection) + termio `.remote`
  backend — same call shape as the Swift flow (dial → build remote surface
  config → open window).
- **Sign-in:** browser OAuth (open default browser to the relay auth URL,
  loopback redirect listener — the agent's web-enroll flow in
  `src/remote/agent/enroll.zig` is the reference), creds under
  `%LOCALAPPDATA%\ghoztty\` protected with DPAPI (or owner-DACL file, like
  the agent's relay.env).
- **GUI:** machine chooser can come last; menu item + chooser dialog.
  Reconnect/restore manifests (WP-D2 parity) explicitly a stretch goal.
- Acceptance: from the Windows box, open a remote window to the Mac (or a
  second agent) via relay; type/read; survive an agent restart
  (reconnect or clean error, no hang/crash).

### Backlog (post-parity, tracked but not in this pass)
- MSI fix (known bug: RemoveExistingProducts + versionless files deletes
  the exe on reinstall — fix = version the exe resource per-build or
  sequence RExP after InstallFiles) → then signing, winget, in-app updates.
- IME/CJK verification, screen-reader pass, log rotation for
  `ghoztty.log`, `ctrl+[`-class keybind requests, perf/GL driver matrix.

## Working agreements

- **Incremental commits** on this branch, one logical step each; phase
  boundaries get a `docs:` commit updating this spec's status table (§9).
- **Never regress macOS:** all new code comptime-gated (`os.tag == .windows`
  or `.win32` runtime arms). The Mac regression build
  (`zig build -Doptimize=Debug` with the Mac toolchain exports) runs on the
  Mac before any merge to main — flag it in the phase-done note if it
  hasn't been run.
- **Test on the box, from the box.** Acceptance scripts live in
  `test/win32/` and must be runnable non-interactively.
- The Mac remains the source of truth for `/Applications/Ghoztty.app` —
  never touched by this work.

## §8 Conformance checklist (the definition of "replica")

Run on the Windows box, debug build, from a fresh app start:

1. `ghoztty +new-window --target=ide --command="nvim ."` → window opens
   running nvim; re-run → focuses, does not duplicate.
2. `ghoztty +split --target=ide --name=term --direction=down --command=<shell>`
   and `--name=logs --direction=right --command="<tail equivalent>"` →
   3-pane layout matches CLAUDE.md example.
3. `ghoztty +read --name=logs --lines=5` → last 5 lines, byte-accurate vs
   what's on screen.
4. `ghoztty +send-keys --target=term "echo hi" Enter` → executes;
   `C-c` interrupts; `"a\tb\n"` expands.
5. `ghoztty +set-state --target=ide --state=busy` → title gains ` (busy)`;
   `needs_input` beats `busy` from another pane; `idle` clears.
   `printf '\e]7777;needs_input\a'` inside a pane does the same.
6. `ghoztty +rename`, `+rearrange`, `+list` behave per CLAUDE.md; `+close`
   of each target tears down; closing a missing target exits 0.
7. `+new-window` with no running instance auto-launches; a second GUI
   launch forwards to the first instance.
8. Hero mode + swap_split via keybinds and IPC.
9. Remote: `+new-remote-window --relay=… --device=<mac>` opens a live
   remote shell (P6).
10. The ghoztty **skill** executes its flows unmodified (P4 gate).

## §9 Status table (update as phases land)

| Phase | Status | Commit(s) | Acceptance run |
|---|---|---|---|
| P0 bootstrap | done | env only (details doc "Bootstrap & environment") | native Debug build green on box |
| P1 transport + verbs | done (T03–T08) | 353d70abf..e80e32d39 | ipc-p1.ps1 ALL PASS (re-run at HEAD 2026-07-19) |
| P2 panes | done (T09–T12) | 72943724a.. | ipc-p2.ps1 ALL PASS (re-run at HEAD 2026-07-19) |
| P3 read/state/rearrange | done (T13–T16) | 1aac69e91, fee87d441.. | ipc-p3.ps1 ALL PASS (re-run at HEAD 2026-07-19) |
| P4 skill conformance | done (T17, 2026-07-12) | doc only | full skill-driven session, zero skill modifications |
| P5 hero/swap | done (T18/T19; TRUE port T58/T59a/T59b/T61) | a859c9976, 5a10762ed.. | hero-mode.ps1 ALL PASS (60) 2026-07-19 |
| P6 remote | done on-box (T20/T21a/T21b/T22a–c) | 2ed989866, 64c4329c2, 89e31b7fb, 7ec2c7119, 4e7edfc9b | ipc-relay.ps1 + relay-account.ps1 (was ipc-relay-login.ps1, renamed by T141) + ipc-machine-chooser.ps1 ALL PASS; live Mac-device dial = Mac-seat step (T87); reconnect T56 / remote env T42 open |

**§8 conformance run (T25, 2026-07-19):** `test/win32/conformance.ps1`
executes items 1–7 end-to-end from a cold start — including the CLAUDE.md
three-pane example (Windows equivalents: git-bash `vim`/`tail`,
`powershell` for `zsh`) — ALL PASS ×3 at HEAD. Item 8 via hero-mode.ps1
(60 assertions), item 9 via the fake-relay E2E (live Mac dial pending the
Mac seat), item 10 per T17 plus the same skill flows re-executed by items
1–6. Both unit-test lanes green the same day. Remaining before merge to
main: the macOS regression build on the Mac seat (T87), per the working
agreements above.
