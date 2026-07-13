# Windows parity — task tracker

**This is the canonical resume doc for the Windows parity effort.**
Architecture decisions, reference implementations, and phase rationale live in
`windows-parity-spec.md` (same directory) — read its "Architecture decisions
(pinned)" section before implementing any IPC task. This doc tracks the
*work*: discrete tasks, their validation, and current state.

## Resume protocol (fresh session starts here)

1. Read this doc top to bottom. The **state table** below is ground truth.
2. Pick the first task that is `todo` whose dependencies are `done`.
3. Set it `in-progress` (edit the table, commit the doc change or fold it
   into the task's first commit).
4. Implement methodically. Small commits on `users/dzearing/windows-amd64`.
5. Run the task's **Validation** section. Do not mark `done` on a clean
   build alone — validation must actually pass, on the box when it says so.
6. Update the state table: status, commit hash(es), one-line validation
   evidence. Append a dated entry to the **Session log** at the bottom.
7. Push. If context is nearly spent, stop at a task boundary — the next
   session resumes at step 1.

New tasks: add rows/sections as discovered (bugs found during validation
become tasks here, not loose threads). Never delete a task — mark
`skipped(<reason>)` instead so decisions stay visible.

## On-box session bootstrap (Windows / MaximusHome)

Development moved to the Windows box 2026-07-12 — an on-box Claude Code
session owns Phases B–E; Mac sessions own Mac-side tasks (T29, T30) and the
pre-merge macOS regression build. Both sync via
`origin/users/dzearing/windows-amd64`; pull before starting, push at every
task boundary.

One-time setup (PowerShell, admin where needed):

```powershell
winget install Git.Git
winget install zig.zig --version 0.15.2   # exact version; repo requireZig's it
winget install Anthropic.ClaudeCode       # or: irm https://claude.ai/install.ps1 | iex
git clone https://github.com/dzearing/ghoztty
cd ghoztty
git checkout users/dzearing/windows-amd64
```

First actions for a fresh on-box session (this is P0's acceptance, then the
T03 leftover, then onward):

1. `zig build -Dapp-runtime=win32 -Doptimize=Debug` (native; Console
   subsystem → stderr visible). Launch `zig-out\bin\ghoztty.exe`, type in it.
2. `zig build test -Dapp-runtime=none` — upstream keeps this green on
   Windows; deviations are our bugs. `zig build test -Dapp-runtime=win32`
   also runs natively and covers win32-tagged units (T33); run both
   before pushing code that touches win32 files.
3. T03 round-trip: run `test\win32\ipc-fake-server.ps1 -DebugPipe` in one
   shell, `zig-out\bin\ghoztty.exe +list` in another (a Debug exe speaks
   the `ghoztty-debug-<username>` pipe). Expect the server to print the
   `{"action":"list"}` request and the CLI to print `No windows open.`
   Record the evidence in the T03 row, flip it to `done`.
4. Resume protocol below (next task: T04).

On-box notes: config file lives at `%LOCALAPPDATA%\ghostty\config.ghostty`
(note the `ghostty` spelling); app log at `%LOCALAPPDATA%\ghoztty\ghoztty.log`;
the share is `\\homeassistant\share\ghoztty-windows` for staging artifacts
back to the Mac side. The "Environment facts" below are the MAC seat's —
still authoritative for staging/ZIP layout and merge rules.

## Environment facts (verified 2026-07-12)

- Worktree: `~/git/ghoztty-windows-amd64`, branch `users/dzearing/windows-amd64`.
- Cross-compile from the Mac works with stock zig 0.15.2, no toolchain
  exports needed:
  `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast`
  → `zig-out/bin/ghoztty.exe` (~28 MB). Debug build (`-Doptimize=Debug`) is
  Console-subsystem → stderr visible.
- Core tests: `zig build test -Dapp-runtime=none` (upstream keeps this green
  on Windows; deviations are our bugs).
- **macOS regression build** (`zig build -Doptimize=Debug`, native) needs the
  macOS-26 toolchain workaround (SDK exports — see the
  `ghoztty-macos26-zig-toolchain` memory note). Run it before any merge to
  main; day-to-day Windows work doesn't need it.
- Staging to the box: mount `smb://dzearing@homeassistant/share` (password in
  the Mac keychain, `security find-internet-password -s homeassistant -a
  dzearing -w`), artifact dir `ghoztty-windows/`. ZIP layout:
  `Ghoztty/{ghoztty.exe, READ-ME-FIRST.txt, share/}` → zip as
  `Ghoztty-portable-x64.zip`. Keep a dated `.bak` of what you replace.
- Fresh ZIP built from `8c22dd370` staged 2026-07-12 (first build that
  provably contains the ctrl keybind mirrors). Prior Jul-6 zip kept as
  `Ghoztty-portable-x64-jul6.zip.bak`; its provenance was unverifiable
  (builds are not bit-reproducible).
- On-box execution options, in order of preference:
  a. Claude Code session on the Windows box (spec's assumption; best).
  b. Remote window from Mac Ghoztty to the box's `ghoztty-agent` via relay,
     driven with the ghoztty skill. Caveat: `+split --name` on remote panes
     doesn't register (async) — plan around it.
  c. Manual: user runs a checklist / PowerShell script and reports output.
- **Never modify `/Applications/Ghoztty.app`.** Never use `com.mitchellh.*`
  identifiers (fork namespace is `com.dzearing.ghoztty.*`).

## Key code landmarks

- `src/apprt/win32/` IPC (as of 2026-07-12): IpcServer.zig (pipe
  transport), IpcHandlers.zig (verbs), IpcRegistry.zig (named targets),
  ProcessTree.zig (`--pid` ancestry); pure logic in `src/apprt/ipc/`
  (args.zig, list.zig — unit tested in both lanes). No action stubs remain
  (T19 landed the last one). `startUpdateCheck` still hard-disabled (T24).
- `src/apprt/none.zig` `sendIpc` — Mac client wire protocol (4-byte BE length
  + JSON), reuse `src/apprt/ipc.zig` `parseResponse`.
- `macos/Sources/Features/IPC/IPCServer.swift` — reference server semantics
  (registry, idempotency, send-keys notation, list format, rearrange).
- `macos/Sources/Features/Terminal/BaseTerminalController.swift` — activity
  title suffix + titleOverride precedence.
- `src/remote/` — shared Zig remote core (ws_client, relay_dial, client_mux,
  ssh_transport); termio `.remote` backend. Swift supplies only UI + creds.
- `src/config/Config.zig` ~line 6880 — the Windows ctrl-mirror keybind block.
- Windows keyboard path: `src/apprt/win32/Surface.zig` `handleKeyEvent`.

## State table

| ID | Task | Phase | Deps | Status | Commits | Validation evidence |
|----|------|-------|------|--------|---------|---------------------|
| T01 | Verify fresh ZIP keybinds on box | A | — | todo | — | — |
| T02 | Keybind gaps: ctrl+p, ctrl+f4 | A | — | done | 82e096f4b | on-box 2026-07-12: ctrl+p opens palette (popup window appears, verified twice; Esc closes), ctrl+f4 closes tab (2→1 via +list), ctrl+t sanity green; core tests green. ctrl+, already worked (audit). Nuance: ctrl+p from INSIDE the palette edit doesn't toggle-close (pre-existing popup-edit bubbling behavior) |
| T03 | Named-pipe client helper + CLI un-guard | B | — | done | 353d70abf, 4f52e8877, 64f5b6984 | box round-trip 2026-07-12: fake server logged `{"action":"list"}` (17 B framed), CLI printed `No windows open.` exit 0; native win32 Debug build green; native `zig build test -Dapp-runtime=none` green (after 2 fork compile fixes, see log) |
| T04 | Pipe server in win32 App + marshal + DACL | B | T03 | done | 1a44125de | on-box 2026-07-12: `+list` answered by in-app server (`No windows open.`, exit 0); 2nd GUI launch forwarded new-window (master windows 1→2, second exited 0); pipe DACL = single ACE `MAXIMUSHOME\David` FullControl; clean app exit after IPC use (no join deadlock) |
| T05 | `+list` | B | T04 | done | da9d56d0d | golden shape tests in apprt/ipc.zig green; on-box 2026-07-12: 2-tab + h-split layout (built via ctrl+t/ctrl+d SendInput) rendered correctly in human + `--json` forms — `[target: window-1]`, per-pane `[name: <id>]`, focus/selected markers, pwd populated |
| T06 | `+new-window` full flags + auto-launch + 2nd-instance forward | B | T04 | done | e80e32d39 | on-box 2026-07-12: cold auto-launch (detached CreateProcessW) + create with --target/--title/--command; repeat --target focused (no dup); --split=down + --split-command + --name registered pane; --working-directory honored; -e exec window created; `[target: <name>]` canonical (Mac windowName semantics) |
| T07 | `+close` | B | T06 | done | e80e32d39 | on-box 2026-07-12: close named pane (window survives), close window, close missing → all exit 0; registry pruned via ipcForget in destroy paths |
| T08 | P1 acceptance script `test/win32/ipc-p1.ps1` green | B | T05,T06,T07 | done | e80e32d39 | on-box 2026-07-12: ALL PASS (22 assertions — auto-launch, create/focus/close, idempotency, close-missing, inline split, -e, json shape, 2nd-instance forward) from fresh start |
| T09 | `+split` (window/pane targets, registry) | C | T08 | done | 72943724a | on-box 2026-07-12: three-pane CLAUDE.md layout by name; idempotent --name; --pane exact-surface split with --percent (ratio 0.70); missing-target error; teardown — ALL PASS (15) |
| T10 | `+rename` / titleOverride precedence | C | T08 | done | (this commit) | on-box 2026-07-12: rename sets window title; shell `title` changes update the TAB label but the window title keeps the override; missing target errors |
| T11 | `+send-keys` full notation | C | T08 | done | (this commit) | on-box 2026-07-12: `"title X" Enter` executed (observable via +list tab title), `\n` escape executes after LF→CR ConPTY normalization, C-c accepted, window-target routes to active pane, missing target errors |
| T12 | P2 acceptance script green | C | T09,T10,T11 | done | (this commit) | on-box 2026-07-12: `test/win32/ipc-p2.ps1` ALL PASS (21 assertions) from fresh start |
| T13 | `+read` | D | T08 | done | 1aac69e91 | on-box 2026-07-12: echoed marker read back byte-accurate (--lines=5 + default 50); window target reads active pane; missing pane errors |
| T14 | `+set-state` + OSC 7777 + title suffix | D | T08 | done | fee87d441 | on-box 2026-07-12: all 3 states via CLI, aggregation needs_input>busy>idle across 2 panes, suffix set/cleared; OSC 7777 busy/idle round-trip from inside the pane (pwsh `[console]::Write`); invalid state errors |
| T15 | `+rearrange` | D | T09 | done | (this commit) | on-box 2026-07-12: 4-pane tab rearranged to horizontal(pa\|vertical(pb,pc)) ratio 0.3 — unnamed pane closed, tree+human list agree; duplicate/unknown-pane/bad-JSON error paths — ALL PASS (15) |
| T16 | P3 acceptance script green | D | T13,T14,T15 | done | (this commit) | on-box 2026-07-12: `test/win32/ipc-p3.ps1` ALL PASS (17 assertions — read byte-accurate, state aggregation + suffix, OSC 7777 round-trip, rearrange + error paths) from fresh start |
| T17 | Skill conformance on the box | E | T12,T16 | done | (doc only) | on-box 2026-07-12: full skill-driven session from Claude Code with ZERO skill modifications — three-pane CLAUDE.md example verbatim (auto-launch from cold; `tail -f` genuinely ran via git-bash PATH), +read, +send-keys (echo round-trip read back), C-c, set-state loop, +rename, +rearrange (70/30 + pane removal), auto-name targeting (`window-1`), idempotent re-close/teardown. Env note: `jq` not installed on box, that discover pattern untestable as-is |
| T18 | `swap_split` on win32 | F | — | done | (this commit) | on-box 2026-07-12: ctrl+shift+up swapped stacked panes (JSON tree order flipped, focus followed), ctrl+shift+down restored; screenshot archived (temp t18-swap-after.png); IPC-driven swap covered by the +rearrange swap pattern (T15). Fixed two binding shadows that had made ctrl+shift+arrows dead for swap on Windows (see log) |
| T19a | Hero mode design (win32) | F | T18 | done | (this commit) | design decided and recorded in the T19a section: per-tab state, 0.25 carousel, layoutSplits branch, goto interception, focus-follows, tree-change clamping, +list unaffected |
| T19 | Hero mode on win32 (implement per T19a) | F | T19a | done | f37bd1e3c | on-box 2026-07-12: geometry oracle on a 3-pane layout — tree (3x310px) → hero (465x442 left + two 156px stacked right at x=502) → ctrl+alt+down moves the hero → toggle-off restores the exact tree layout; screenshot archived; both test lanes + P1–P3 acceptance green. LAST `return false` action stub is gone |
| T20 | `+new-remote-window --host/--port` (direct TCP) | G | T08 | todo | — | — |
| T21 | Relay dial + browser sign-in + DPAPI creds | G | T20 | todo | — | — |
| T22 | Remote GUI: menu item + machine chooser | G | T21 | todo | — | — |
| T23 | MSI fix → uninstall entry works | H | — | todo | — | — |
| T24 | Windows release channel + enable update check | H | T23 | todo | — | — |
| T25 | Full conformance checklist (spec §8) end-to-end | — | T17,T19,T21 | todo | — | — |
| T26 | OS color-scheme sync (colorSchemeCallback) | I | — | done | (this commit) | on-box 2026-07-12: `theme = light:Adwaita,dark:GitHub Dark` config + screenshot pixel oracle — pane renders #101216 when the OS is dark, flips LIVE to #ffffff on a light flip, and back, no restart. Found+fixed the real bug the task implies: WM_SETTINGCHANGE broadcasts reach TOP-LEVEL windows only, so the handler had to live in Window.windowWndProc, not the surface proc |
| T27 | PowerShell shell integration | I | — | todo | — | — |
| T28 | Minor action no-ops cleanup | I | — | todo | — | — |
| T29 | Mac-side: fix action fallthroughs to showChildExited | I | — | todo | — | — |
| T31 | `+list --pid` filter + real pid leaf data on Windows | I | T05 | done | (this commit) | on-box 2026-07-12: +list leaves report the real shell pid (verified live cmd.exe); `+list --pid=<any descendant>` resolves the owning pane by Toolhelp32 ancestry (self + grandchild + unknown-pid-error all green); ProcessTree walk unit-tested (cycle/self-parent guards) in the win32 lane. tty stays "" (no ConPTY tty name) and exit_code stays null (note). /reset-context's Windows probe: `ghoztty +list --pid=<winpid>` — the skill (user plugin) needs its Step 1 updated to use it |
| T32 | Refactor: split IpcServer.zig into modules; extract pure logic + unit tests | J | — | done | 640457b0d, cb53bb728, 31393ce38, 4cbc3d3e3 | IPC now 5 focused modules (transport 385 lines / handlers / registry / pure args / list model); 8 unit-test blocks in the none-runtime suite; P1–P3 ALL PASS after every step. App.zig −330 lines (rest is the vendored action switch — assessed, deferred) |
| T33 | Native win32 test lane (`zig build test` on the box covers win32 units) | J | T32 | done | (this commit) | `zig build test -Dapp-runtime=win32` runs green natively on the box (verified 2026-07-12); pure IPC logic also covered by the cross-platform none-runtime lane; both documented in the bootstrap section |
| T34 | Windows shell types: first-class pwsh/powershell/cmd/git-bash/WSL/nushell support | J | — | done | (this commit) | wrap table extended (wsl `--`, nu `-e`) + Mac-parity keep-alive for posix flavors (`; exec "shell" -li` — git-bash panes used to die after the command); every branch unit-tested; on-box: cmd/powershell/git-bash markers read back + panes alive; wsl created but box only has the locked-down docker-desktop distro (`/bin/sh: Permission denied` — informational); pwsh7/nu not installed. CLAUDE.md documents the Windows flavors |
| T30 | Mac-side: IPC dial must not modal-block the app/IPC server | I | — | todo | — | — |

Status values: `todo` / `in-progress` / `done` / `blocked(<on what>)` /
`skipped(<reason>)`.

## Tasks

### Phase A — keybind verification & gaps (Mac-buildable, box-verified)

**T01 — Verify fresh ZIP keybinds on box.**
The 2026-07-12 ZIP is the first artifact guaranteed to contain the ctrl
mirrors. On the box: extract fresh, then check `ctrl+n` (new window),
`ctrl+t` (new tab), `ctrl+d` (split right), `ctrl+shift+d` (split down),
`ctrl+w` (close pane), `ctrl+shift+p` (palette), `ctrl+1..9` (tabs),
`ctrl+c` copy-with-selection / SIGINT-without, `ctrl+v` paste.
*Validation:* each binding observed working on the box; record any failure
as a new task with repro notes (which shell, which layout).
If failures persist in this build, the bug is in the win32 key path
(`handleKeyEvent`) — capture `%LOCALAPPDATA%\ghoztty\ghoztty.log`.

**T02 — Keybind gaps.**
Add to the Windows mirror block in `Config.zig`: `ctrl+p` →
`toggle_command_palette` (user muscle memory; accepts shadowing readline
previous-history), `ctrl+f4` → `close_tab` (Windows convention). Consider
`ctrl+,` → `open_config` if trivially portable.
*Validation:* `zig build test -Dapp-runtime=none` green; on-box check of
both bindings; update CLAUDE.md/README notes if they document shortcuts.

### Phase B — IPC foundation (spec P1)

**T03 — Named-pipe client helper + CLI un-guard.**
New `src/os/ipc_pipe.zig` (or similar): connect to
`\\.\pipe\ghoztty-<username>` (release) / `ghoztty-debug-<username>`
(debug), write 4-byte BE length + JSON request, read same-framed response.
Branch the per-OS connect layer inside the existing CLI command files;
remove the `os.tag == .windows` comptime guards that disable
`+list`/`+read`/`+rearrange`/etc. All commands go through the ONE helper.
*Validation:* cross-compiled `ghoztty.exe +list` against a fake pipe server
(PowerShell test harness or the T04 server) round-trips a request; core
tests green; macOS build unaffected (no code path changes for darwin).

**T04 — Pipe server in win32 App.**
Listener thread owning the pipe (owner-only DACL), short-lived
request/response connections, requests marshaled to the GUI thread via the
existing message-only window (`WM_APP_*` + event for the response). Wire
`performIpc` to dispatch instead of returning `false`. Single-instance:
second GUI launch detects busy pipe → forwards `new-window` → exits.
*Validation:* on box, `ghoztty +list` returns a response (even if empty
tree); second `ghoztty.exe` launch focuses/creates in the first instance;
pipe rejects a different user (spawn under another account or verify DACL
with `Get-Acl`).

**T05 — `+list`.**
Registry (`StringHashMap(TargetEntry)`, liveness-pruned) + tree rendering
that byte-matches the Mac format (window → tabs → panes, `[target: …]`,
`[name: …]`, focused markers). Golden-file the Mac output shape in a test.
*Validation:* golden test green; on box, `+list` over a manually built
window/tab/split layout renders correctly.

**T06 — `+new-window`.**
All flags: `--target` (idempotent focus-if-exists), `--working-directory`,
`--command`, `--shell` (pwsh/powershell → `-NoExit -Command`; cmd → `/K`;
else `-lic`), `--title`, `--split`+`--split-command`, `--no-activate`,
`-e`. Auto-launch: no pipe → spawn `ghoztty.exe` detached, retry connect
with backoff.
*Validation:* on box — create named window running a command; re-run
focuses (no duplicate); auto-launch from cold works; `--title` shows;
`--no-activate` doesn't steal focus.

**T07 — `+close`.**
Close named window or pane; missing target exits 0 silently; registry
pruned.
*Validation:* on box — close each target kind; close nonexistent → exit 0.

**T08 — P1 acceptance script.**
`test/win32/ipc-p1.ps1`, non-interactive, covering T05–T07 (create/focus/
close, idempotency, close-missing, auto-launch, list golden shape).
*Validation:* script passes on the box from a fresh app start; output
captured into the session log.

### Phase C — panes (spec P2)

**T09 — `+split`.** `--direction`, `--target` (window OR pane), `--name`
(pane registry), `--command`, `--shell`, `--working-directory`, `-e`.
*Validation:* 3-pane CLAUDE.md example layout builds by name on the box.

**T10 — `+rename`.** titleOverride semantics — override beats
terminal-set titles until cleared, matching
`BaseTerminalController.titleOverride`.
*Validation:* rename a window whose shell also sets titles; override wins;
`+list` reflects it.

**T11 — `+send-keys`.** Full notation from `IPCServer.swift`
handleSendKeys: `C-<x>` ctrl bytes, `Enter`/`Tab`/`Escape`/`Space`/
`Backspace`, escapes `\n \t \r \\ \e`; concatenated, written to target
pane's PTY (ConPTY input side).
*Validation:* `"echo hi" Enter` executes; `C-c` interrupts a running loop;
`"a\tb\n"` expands. Watch for ConPTY translation surprises — validate
against both cmd and pwsh.

**T12 — P2 acceptance script** `test/win32/ipc-p2.ps1`. *Validation:*
passes on box.

### Phase D — read/state/rearrange (spec P3)

**T13 — `+read`.** Last N lines of screen+scrollback via the core's
plain-text dump (same machinery as `write_screen_file`), renderer mutex
held; text in `data`.
*Validation:* echo known strings into a pane, `+read --lines=5` returns
them byte-accurate.

**T14 — `+set-state` + OSC 7777.** Implement the `activity_state` action
(replace the stub): per-pane state, window aggregation
`needs_input > busy > idle`, title suffix ` (busy)`/` (needs_input)`,
cleared on idle. OSC `\e]7777;<state>\a` feeds the same path (core side
already parses it).
*Validation:* `+set-state` all three states → title bar changes observed;
two panes with different states aggregate correctly; `printf`-style OSC
round-trip from inside a pane.

**T15 — `+rearrange`.** Port `handleRearrange` semantics from the Swift
server onto the win32 `SplitTree`.
*Validation:* rearrange a 3-pane layout; `+list` and visual layout agree.

**T16 — P3 acceptance script** `test/win32/ipc-p3.ps1`. *Validation:*
passes on box.

### Phase E — skill conformance (spec P4) — **the original ask**

**T17 — ghoztty skill runs unmodified.**
From Claude Code on the box: the CLAUDE.md three-pane example verbatim,
plus the skill's list/read/send-keys/set-state loops. Every divergence
becomes a fix + a regression line in the P1–P3 scripts.
*Validation:* a full skill-driven session (create layout → read → send-keys
→ set-state → teardown) with zero skill modifications.

### Phase F — GUI parity (spec P5)

**T18 — `swap_split`.** Core `SplitTree.swap` exists; add the win32 action
arm + re-layout.
*Validation:* keybind- and IPC-driven swap on a 3-pane layout; screenshot
archived.

**T19a — Hero mode design.** Write the win32 design (a short section in
this doc or a sibling doc) before implementing. Scouting notes from
2026-07-12 (reference sources already located):

- Mac model lives in `macos/Sources/Features/HeroMode/` —
  `HeroModeState.swift` is tiny: `isActive`, `selectedIndex`,
  `carouselRatio` (default 0.25, clamped 0.1–0.6), `scrollOffset`;
  activate requires >1 leaf and seeds selection from the focused leaf;
  select/prev/next clamp to leaf count. Views: `HeroModeView` (hero pane
  fills `1-ratio` of width, carousel column right), `HeroCarouselView`,
  `HeroPaneView`.
- Interception points on Mac (`BaseTerminalController.swift`): goto_split
  prev/next while active moves the carousel selection (~line 989); tree
  changes clamp/deactivate (~line 635); hero nav keybinds are
  super+shift+up/down (now explicitly super — see T18 log — so Windows
  needs its own nav story, e.g. intercept goto_split up/down =
  ctrl+alt+arrows, or all goto variants → prev/next while active).
- win32 integration point: `Window.layoutSplits` (Window.zig ~700) —
  the `tree.zoomed` branch is the precedent for a non-tree layout mode
  (position/show/hide each leaf directly). Hero layout = leaves[i]
  full-height left at `(1-ratio)·w`; remaining leaves stacked in the
  right column. `layoutNode`/`paintDividers` stay untouched.
- Design decisions to settle: per-TAB hero state (parallel arrays like
  `tab_trees`) vs per-window; interaction with `tree.zoomed`; carousel
  click-to-select and divider drag (stretch); deactivate on leaf count
  dropping to 1; +list representation (Mac +list ignores hero mode —
  confirm).
*Validation:* design section reviewed/committed; open questions resolved.

**T19a — DESIGN (decided 2026-07-12, on-box session):**

- **State is per-tab** (Mac = per-controller = per-tab): parallel arrays on
  Window beside `tab_trees`: `tab_hero_active: [MAX_TABS]bool`,
  `tab_hero_index: [MAX_TABS]u16`. Carousel ratio fixed at 0.25 for v1
  (Mac default; clamp 0.1–0.6 constants kept for the future drag).
- **Layout**: new branch at the TOP of `layoutSplits` (before the
  `tree.zoomed` branch): leaves in tree-iteration order; leaf[index] gets
  the left `(1-ratio)·w` full height; the remaining leaves stack equally
  in the right column. `paintDividers` early-returns while active.
- **Toggle** (`toggle_hero_mode` action, ctrl+shift+space on Windows):
  requires >1 leaf; activation seeds index from the focused leaf and
  clears `tree.zoomed` (zoom and hero are mutually exclusive; toggling
  zoom while hero active deactivates hero first).
- **Navigation while active**: intercept in `Window.gotoSplit` —
  previous/next AND spatial up/down move the selection (clamped, Mac
  clamps too); selection change = SetFocus(selected) + relayout. Spatial
  left/right pass through (hero pane vs carousel is horizontal).
- **Focus-follows**: clicking any carousel pane focuses it; the
  WM_SETFOCUS path that updates `tab_active_surface` also sets
  `tab_hero_index` to that leaf while active.
- **Tree changes** (split/close/rearrange) while active: clamp index;
  deactivate when leaves ≤ 1. One `heroOnTreeChanged(tab)` helper called
  from newSplitAt/closeSplitSurface/closeTab/rearrange swap sites.
- **+list is unaffected** — hero is pure presentation; the tree does not
  change (matches Mac).

**T19 — Hero mode implementation.** Per T19a above. Pure `Window.zig`
layout work plus the `toggle_hero_mode` action arm (the last
`return false` stub in win32 `performAction`).
*Validation:* toggle on/off on a 3-pane layout; focus-follows behavior
matches Mac; screenshot archived.

### Phase G — remote machines (spec P6)

**T20 — `+new-remote-window --host/--port` (direct TCP).**
Un-guard the CLI; dial with `src/remote` (tcp_dial/connection) + termio
`.remote` backend; open window (same call shape as the Swift flow).
*Validation:* from the box, connect to a test agent (`--listen`, use
`GHOSTTY_AGENT_LOCK` override per memory) — type/read works.

**T21 — Relay + sign-in + creds.**
`--relay/--device` via relay_dial; browser OAuth (open default browser,
loopback redirect listener — `src/remote/agent/enroll.zig` web-enroll is
the reference); creds under `%LOCALAPPDATA%\ghoztty\` with DPAPI or
owner-DACL file.
*Validation:* from the box, open a remote window to the Mac (or second
agent) via the production relay with Google sign-in; survive an agent
restart with reconnect or clean error (no hang/crash).

**T22 — Remote GUI.** Menu item + machine chooser dialog. Reconnect/restore
manifests = stretch.
*Validation:* chooser lists enrolled machines; opening one works.

### Phase H — distribution (user-priority; parallel-safe with B–G)

**T23 — MSI fix.**
Root cause known: `RemoveExistingProducts` + versionless keyfiles deletes
the exe on major upgrade ("same component with higher versioned keyfile"
skip). Fix: real per-build file versions on the exe resource AND/OR
sequence RExP after InstallFiles; distinct component GUID strategy per
`windows-amd64-plan.md` postmortem. Pipeline:
`dist/windows-installer/build-msi.sh` (UpgradeCode
`5EB02044-7F06-498B-B7A9-7EFD65486CFB` is permanent; version scheme
`yy.m.dNN`).
*Validation:* on box — install MSI vN, then vN+1 over it: exe present and
launches after upgrade; "Ghoztty" appears in Apps & Features; uninstall
removes it cleanly.

**T24 — Release channel + auto-update.**
Publish Windows builds as GitHub releases tagged `win-vX.Y.Z`; remove the
`if (true) return;` in `startUpdateCheck`; on newer tag → notify with a
link (portable) or download+launch MSI (once T23 lands). Decide notify-only
vs auto-install and record here.
*Validation:* box on older version + newer tag published → update prompt
appears within the check interval; following it lands the new version.

### Phase I — audit-derived gaps (from the 2026-07-12 full audit; see appendix)

**T26 — OS color-scheme sync.**
win32 never calls `core_surface.colorSchemeCallback` (zero call sites), so
OSC 10/11 light/dark queries and `light:`/`dark:` conditional config never
react to the Windows theme. Implement: read the OS apps-light/dark setting
at surface init, report via colorSchemeCallback, and re-report on
`WM_SETTINGCHANGE` (the handler exists but only re-reads scrollbar theme).
Chrome (`window-theme=system`) already reacts; this is the *terminal-side*
signal.
*Validation:* on box, flip Windows dark↔light with the app open — a
`theme = light:…,dark:…` config switches live; an app querying OSC 11 sees
the change.

**T27 — PowerShell shell integration.**
`src/shell-integration/` has bash/zsh/fish/elvish/nushell only — nothing
for pwsh, and cmd can't support it. So prompt marks, cwd reporting, and
title reporting are dead under the default Windows shells. Write a pwsh
integration script (Windows Terminal's shell-integration docs and the
existing scripts are references), wire it into the shell-integration
detection/injection for `pwsh.exe`/`powershell.exe`.
*Validation:* on box with pwsh — cwd reporting works
(`window-inherit-working-directory` honors it), prompt-mark scroll
(`ctrl+shift+up`-style jump) works, no visible prompt corruption.

**T28 — Minor action no-ops cleanup.**
Bundle of small `return true`-but-do-nothing gaps, each cheap: `readonly`
(visual indicator, e.g. tab-title glyph), `key_sequence`/`key_table`
(pending-sequence indicator, e.g. status bubble reuse), `pwd` (append to
window title or tooltip), `color_change` (handle fg/cursor, not just bg),
`close_all_windows` (close each window with confirm, distinct from quit),
notification click→focus round-trip (verify it works; fix if not).
*Validation:* per-item spot checks on box; note each in the table row.

**T29 — Mac-side: fix fork-merge fallthrough bug.**
Audit found `toggle_window_decorations`, `size_limit`, `quit_timer`, and
`toggle_tab_overview` in the Mac app's action dispatch falling through to
`showChildExited` (apparent bad merge in `Ghostty.App.swift` switch).
Verify against the Mac source; if real, fix the switch. Win32 is
unaffected (it implements these properly).
*Validation:* Mac build: toggling window decorations via keybind works;
`quit-after-last-window-closed` delay still honored. Run the Mac
regression build.

**T30 — Mac-side: IPC dial must not modal-block the app/IPC server.**
Found live 2026-07-12: `ghoztty +new-remote-window --relay --device` against
the release app, dial failed (box agent presumed down), and
`AppDelegate.openRemoteWindow` popped `NSAlert runModal` ON THE MAIN THREAD
from the IPC path (`IPCServer.handleNewRemoteWindow` waits on a semaphore →
serial IPC queue wedged). With the screen locked nobody can dismiss → ALL
CLI IPC to the app is dead until the user unlocks and clicks the alert.
The handler already routes the signed-out case through the IPC response
("no GUI alert from the IPC path") — dial-failure must do the same: when
the dial was IPC-initiated, return the error in the IPC response and never
`runModal`. Menu-initiated dials may keep the alert.
*Validation:* Mac regression build; `+new-remote-window` to a dead device
returns a CLI error promptly (no alert, no wedge); a second `+list` during
and after the failed dial responds normally.

### Phase J — reliability, structure, tests (standing user directive 2026-07-12)

Standing directive from the user (applies to ALL future on-box work):
keep going autonomously; reach parity with every feature that translates;
build Windows-native equivalents where the Mac concept doesn't translate
(e.g. shell types); keep the code well structured — **no mega files**;
**everything gets tests**.

**T32 — Refactor IpcServer.zig + testable pure logic.**
IpcServer.zig has grown past 1100 lines (transport + marshal + 9 verb
handlers + arg parsing + SDDL). Split: `ipc/Server.zig` (pipe transport,
marshal, shutdown), `ipc/verbs.zig` or per-verb files (handlers),
`ipc/args.zig` (parseVerbArgs/dropPrefix/wrapCommandArgv — PURE, no
win32 imports, so it compiles in the none-runtime test build like
apprt/ipc.zig does), plus unit tests for: verb arg parsing, shell argv
wrapping (pwsh/-Command vs cmd//K vs -lic), send-keys LF/CRLF→CR
normalization, rearrange layout validation (shape/direction/dupes), and
the List golden tests (already exist). App.zig (2600+) and Window.zig
(2000+): move the IPC registry into its own file; assess further splits.
*Validation:* `zig build test -Dapp-runtime=none` runs the new units;
win32 build green; P1–P3 acceptance scripts still ALL PASS.

**T33 — Native win32 test lane.**
Pure-logic tests land in none-runtime files (T32) and run everywhere.
For win32-tagged units, add/verify a `zig build test -Dapp-runtime=win32`
lane on the box and fold it into the acceptance flow docs.
*Validation:* the lane runs green on the box and is documented in this
file's bootstrap section.

**T34 — Windows shell types, first-class.**
The Mac wraps commands in `$SHELL -lic`. The Windows translation is a
shell-flavor table (today: pwsh/powershell → `-NoExit -Command`, cmd →
`/K`, else `-lic`). Make it first-class: add `wsl`/`wsl.exe`
(`wsl.exe -- <cmd>`, and bare `--shell=wsl` opens the default distro),
`nu`/`nushell` (`-e <cmd>`? verify), `bash`/git-bash (works via `-lic`
today — verify login-shell profile loads), and document `command-shell`
values for Windows in CLAUDE.md/README. Unit-test the wrap table (T32
makes it pure). Consider `+list` showing the shell flavor per pane.
*Validation:* on box — `--command` runs correctly under pwsh, cmd,
git-bash, and WSL (if installed); unit tests cover every flavor branch.

**T31 — `+list --tty` + pid/tty leaf data on Windows.**
Found 2026-07-12 trying to run the user's `/reset-context` skill on the
box: it identifies the calling session's pane via
`ghoztty +list --tty="$(ps -o tty= -p $PPID)"`, but on Windows (a) the
CLI ignores `--tty` (prints the full list), (b) every leaf reports
`tty:""`/`pid:0` (ConPTY backend doesn't surface them — T05 note), and
(c) MSYS `ps` lacks `-o`, so the skill's tty probe itself needs a
Windows-appropriate identity (e.g. match by pane's shell PID ancestry or
an env var like GHOZTTY_SURFACE_ID, which IS already injected). Design
the Windows equivalent (likely: `+list --pid=<pid>` walking the ConPTY
child process tree, or match on GHOZTTY_SURFACE_ID) and implement the
filter + real pid data. This blocks `/reset-context`, `/wt`, and other
pane-aware workflow skills on Windows.
*Validation:* from a Claude Code session inside a debug-ghoztty pane, the
skill's Step-1 probe (or its documented Windows replacement) returns
exactly that pane's name.

### Final gate

**T25 — Conformance checklist.** Run spec §8 items 1–10 end-to-end on the
box from a fresh start, including the CLAUDE.md three-pane example
verbatim. Update spec §9 status table. Then: macOS regression build green,
merge to main per the working agreements.

## Backlog (tracked, deliberately not in the parity pass)

Promote to a task row when prioritized; don't work these ad hoc.

- **Session/window save-restore** — no equivalent of `TerminalRestorable*`;
  `window-save-state` ignored. Medium effort (persist layout manifest,
  reopen on launch).
- **Terminal inspector** — `inspector`/`render_inspector` are no-ops; the
  Mac has a real inspector window. Dev tool, not user-critical.
- **Tab tear-out & surface drag-out** — tab drag only reorders in-window;
  no drag-out-to-new-window, no `SurfaceDragSource` equivalent.
- **Tab overview** — no-op on win32 (and effectively no-op on Mac too).
- **Settings UI / About window / config-errors window** — Windows is
  file-only config (works: `ctrl+,` opens it, reload via
  `ctrl+shift+,`/palette; file at `%LOCALAPPDATA%\ghostty\config.ghostty`).
- **Selection/primary clipboard** — `supportsClipboard` only `.standard`;
  no paste-from-selection.
- **In-surface visual bell** — bell is MessageBeep + taskbar flash only.
- **UI Automation / screen-reader accessibility** — no UIA surface (Mac AX
  was already out of scope; a Windows screen-reader pass is its own
  effort).
- **Child-exited inline bar** — win32 uses a modal MessageBox vs the Mac's
  in-window bar.
- **IME/CJK deep verification, log rotation, perf/GL driver matrix** —
  carried from the spec backlog.

Out of scope (platform N/A, decided): secure input
(`EnableSecureEventInput` has no Windows equivalent), undo/redo
(NSUndoManager-based), Dock/Services/AppleScript/App Intents, Spaces
behavior, Quick Look, macOS titlebar-tab styles, Sparkle (T24 covers the
Windows-appropriate update path), AX attributes (`AXWindowActivityState` —
ztabby is a Mac consumer).

## Appendix — full audit findings (2026-07-12)

Three-way audit (action matrix, GUI features, config coverage) of win32 vs
Mac. Condensed; re-audit only if the win32 apprt changes wholesale.

**Action coverage:** the win32 `performAction` switch
(`src/apprt/win32/App.zig:462`) is exhaustive (no else arm). Only three
actions return `false`: `swap_split`, `toggle_hero_mode`, `activity_state`
(→ T14/T18/T19). Silent no-ops (`return true`, nothing happens):
`inspector`, `render_inspector`, `readonly`, `key_sequence`, `key_table`,
`pwd`, `cell_size`, `goto_window`, `toggle_tab_overview`, `secure_input`,
`undo`, `redo` (→ T28 + backlog). Everything else is genuinely
implemented, including: search overlay, command palette (~45 entries +
user entries), quick terminal (full position/size/screen/autohide/
animation), global hotkeys (`global:` keybinds via RegisterHotKey),
desktop notifications (tray balloons), taskbar progress (OSC 9;4),
clipboard confirmation flows (paste protection + OSC 52), IME/preedit,
file drag-drop, DPI changes, resize overlay, background opacity + blur,
DWM dark/light chrome, float-on-top, split management incl. zoom/equalize/
divider drag, custom tab bar with drag-reorder + context menu + inline
rename, config open/reload (soft+hard, rewires theme/hotkeys/QT live).

**Config coverage:** honored — background-opacity/blur (blur radius knob
N/A on DWM), window-theme, window-position, window-new-tab-position,
window-show-tab-bar, padding, resize-overlay, fullscreen/maximize,
quick-terminal-*, mouse-hide-while-typing, cursor-*, unfocused-split-*,
split-divider-color, confirm-close-surface (window granularity),
clipboard-*, desktop-notifications, notify-on-command-finish*,
progress-style, title, global keybinds, quit-after-last-window-closed(+
delay), command-palette-entry, custom-shader (shared GL renderer).
Ignored/missing — window-save-state (backlog), `class`/x11 (N/A),
macos-*/gtk-* (N/A), shell-integration under pwsh/cmd (→ T27), OS
light↔dark reactivity for terminal-side conditional config (→ T26),
auto-update disabled (→ T24). Config file on Windows:
`%LOCALAPPDATA%\ghostty\config.ghostty` (XDG fallback rules; note the
`ghostty` dir name, only the updater throttle uses `ghoztty`).

**Mac-side oddity:** `toggle_window_decorations`, `size_limit`,
`quit_timer`, `toggle_tab_overview` appear to fall through to
`showChildExited` in the Mac dispatch — suspected bad fork merge (→ T29).

## Session log

Append newest-first: `YYYY-MM-DD — <tasks touched> — <what happened, what's
next, any surprises>`.

- 2026-07-12 (on-box, late night, +5) — T26 done — OS light/dark now
  reaches the TERMINAL side (not just the DWM chrome): initial
  colorSchemeCallback at surface init + re-report on WM_SETTINGCHANGE.
  The interesting bug: WM_SETTINGCHANGE broadcasts are delivered to
  TOP-LEVEL windows only, so a handler in the surface (child) wndproc
  never fires — the report lives in Window.windowWndProc, which also
  re-applies the DWM chrome for `window-theme = system`. Validated with a
  `theme = light:Adwaita,dark:GitHub Dark` config and a screenshot-pixel
  oracle across dark→light→dark flips (the OSC 11 response goes to the
  shell's stdin, so `+read` is NOT a usable oracle for it — pixels are).
  Test restores the user's theme + config.
- 2026-07-12 (on-box, late night, +4) — T31, T19a, T19 done — `+list --pid`
  lands the Windows answer to the Mac's tty-based pane identity: leaves now
  carry the shell's real pid (GetProcessId on the ConPTY child handle) and
  `--pid=<any descendant>` resolves the owning pane via a Toolhelp32
  ancestry walk (unit-tested with cycle/self-parent guards). This unblocks
  pane-aware workflow skills on Windows (/reset-context's probe becomes
  `ghoztty +list --pid=<winpid>`; the SKILL itself still needs its Step 1
  updated — it's a user plugin, not in this repo). Then hero mode (T19a
  design → T19 implementation): per-tab state, layout branch above zoom,
  goto interception, focus-follows, tree-change clamping. **Every apprt
  action on win32 is now implemented or a deliberate no-op — no
  `return false` stubs remain.** Validation lesson worth keeping: for
  keybind-driven GUI tests, build the layout in the AUTO-LAUNCHED window
  (its MainWindowHandle owns keyboard focus) — cross-process
  SetForegroundWindow does NOT move focus into another window's child
  pane, which silently sent my first hero runs to the wrong window.
- 2026-07-12 (on-box, late night, +3) — T32 done, T34 done — Phase J
  underway per the standing directive. IPC code restructured into five
  focused modules with the pure logic (arg parsing, shell wrap table,
  LF→CR, layout validation) unit-tested in the none-runtime suite; P1–P3
  acceptance re-run green after EVERY step. Shell-flavor work found a
  real parity bug: posix-flavor `--command` panes (git-bash) exited with
  the command because the Mac's `; exec shell -li` keep-alive wasn't
  ported — fixed, all flavors keep the shell alive now. On-box flavor
  validation: cmd/powershell/git-bash green via +read markers; wsl
  blocked by the box having only the docker-desktop utility distro.
- 2026-07-12 (on-box, late night, +2) — T18 done — win32 swap_split:
  Window.swapSplit (goto to resolve the neighbor, SplitTree.swap for the
  tree, focus follows the moved pane) + action arm replacing the stub.
  TWO keybind shadows found while validating (the fork's ctrl+shift+arrow
  swap bindings were dead on Windows all along): (1) hero-mode nav bound
  goto_split prev/next at ctrlOrSuper+shift+up/down — now explicitly
  super+shift (Mac unchanged, Windows freed); (2) upstream's
  jump_to_prompt ctrl+shift+up/down came AFTER the fork's swap block in
  the non-Mac defaults — swap block moved after it so the fork binding
  wins (prompt jumping needs shell integration, dead on Windows until
  T27). Validated: swap up/down via keybind with JSON tree order + focus
  as oracle, screenshot archived. Debugging tip that cracked it: launch
  the debug exe with stderr to a file and grep 'key event binding' to see
  exactly which action a chord resolves to.
- 2026-07-12 (on-box, late night, +1) — T02 done — ctrl+p →
  toggle_command_palette and ctrl+f4 → close_tab added to the Windows
  mirror block (Config.zig). Validated with verified-focus SendKeys:
  palette popup appears on ctrl+p, tab count 2→1 on ctrl+f4 (+list as the
  oracle). Testing note: window-COUNT assertions are noisy — the themed
  scrollbar overlay is a transient top-level popup that auto-hides; assert
  deltas on the specific window, not absolute counts. T01 left for the
  user: it verifies the STAGED RELEASE ZIP artifact, and a release exe
  here would collide with the user's three live release instances.
- 2026-07-12 (on-box, late night, later) — T17 done — **PHASE E / P4 COMPLETE:
  THE ORIGINAL ASK IS CLOSED.** Ran the ghoztty skill from this on-box
  Claude Code session against the debug exe (PATH prepended; zero skill
  edits): three-pane example verbatim (incl. cold auto-launch), +read,
  +send-keys round-trip verified via +read, C-c, set-state loop, +rename,
  +rearrange with pane removal, auto-name (`window-1`) targeting,
  idempotent teardown. Zero functional divergences. Env note: box lacks
  `jq` (skill's jq discover pattern untested; PS ConvertFrom-Json is the
  local equivalent). Phases B–E all green: P1 (22), P2 (21), P3 (17)
  acceptance scripts checked in and passing from fresh starts. Remaining
  on-box work: T01/T02 (Phase A keybinds), T18/T19 (GUI parity),
  T20–T22 (remote), T23/T24 (distribution), T26–T28 (audit gaps).
- 2026-07-12 (on-box, late night) — T13–T15 done — `+read`: dumpTextLocked
  under the renderer mutex with a full-SCREEN selection
  (pages.getTopLeft/BottomRight(.screen)), trailing N lines in data.text;
  byte-accurate on the box. `+set-state`/OSC 7777: per-pane activity_state
  on win32 Surface, window aggregation → " (busy)"/" (needs_input)" title
  suffix; the activity_state action arm replaces the stub so the OSC path
  (validated with a pwsh `[console]::Write(ESC ]7777;busy BEL)` from inside
  the pane) and the verb share one code path. `+rearrange`: builds a
  replacement SplitTree directly (preorder nodes array, root=0, own arena),
  refs kept surfaces before dropping the old tree (unref destroys panes not
  in the layout), ratio arrives as percent clamped 0.1–0.9, Mac error
  strings. PowerShell gotchas recorded: PS 5.1 reads .ps1 as ANSI — keep
  test scripts pure ASCII (an em-dash broke parsing); PS native-arg passing
  eats embedded quotes — escape as `\"` when passing JSON (`--layout`).
  T16 ipc-p3.ps1: ALL PASS (17) — Phase D (P3) complete. Next: T17 (skill conformance).
- 2026-07-12 (on-box, night) — T09–T12 done, Phase C (P2) complete —
  `+split`: Window.newSplitAt (arbitrary surface, explicit ratio,
  background-tab panes stay hidden), --pane/--target/foreground-default
  resolution, --percent→ratio. `+rename`: window titleOverride (window
  title shows override; tab labels keep tracking the shell). `+send-keys`:
  server writes raw --keys bytes to the pane PTY via
  termio.Message.WriteReq/queueMessage; KEY FINDING — ConPTY shells do not
  execute on LF, only CR, so the server normalizes LF/CRLF→CR (the CLI's
  `\n` notation means Enter; validated `title X\n` runs in cmd).
  Validation trick worth keeping: use the shell `title` command +
  `+list`'s tab title to prove send-keys executed without needing +read.
  `test/win32/ipc-p2.ps1` ALL PASS (21). Next: T13 (+read — dumpTextLocked
  full-screen selection; parse fields already staged), then T14/T15.
- 2026-07-12 (on-box, evening) — T06+T07 done — `+new-window` full flags:
  parseVerbArgs ports the Mac prefix table; per-surface config overrides
  (command/cwd/env) flow via a Window `pending_surface_overrides` baton into
  the Surface.init config copy, using the config Command `.direct` argv form
  (the Windows `.shell` path whitespace-splits with NO quoting — never wrap
  commands as one string). Shell table per spec (pwsh `-NoExit -Command` /
  cmd `/K` / else `-lic`); GHOZTTY_WINDOW_NAME/PANE_NAME env injected;
  window titleOverride (`--title`, reused by T10); canonical window
  ipc_name = --target else `window-N` (Mac windowName semantics — reverse
  hash lookup showed arbitrary names first). Auto-launch: raw CreateProcessW
  with bInheritHandles=FALSE + DETACHED_PROCESS — std.process.Child inherits
  the CLI's redirected stdout/stderr, which kept callers' pipes open and
  HUNG any script capturing `+new-window` output (first validation run
  deadlocked on this). `+close`: pane→closeSplitSurface, window→close(),
  missing→success; found+fixed a dangling-registry bug: Window.onDestroy
  frees the Window WITHOUT deinit(), so ipcForget/name frees had to be added
  there too. T08 `test/win32/ipc-p1.ps1`: ALL PASS (22 assertions) from a
  fresh start — Phase B (P1) complete. Known cosmetic gaps: --no-activate is
  best-effort (window still created focused within the app);
  --color/--percent accepted-and-ignored.
- 2026-07-12 (on-box, later still) — T05 done — `+list` is real: shared
  list-JSON data model + serializer in `src/apprt/ipc.zig` (golden tests pin
  the Mac wire shape — keep in sync with IPCMessage.swift), win32 registry
  (`App.ipc_targets`: StringHashMap of window/pane unions, eager ipcForget
  from Window/Surface deinit + prune-on-register so stale pointers are
  unreachable), auto window names `window-N` (Mac parity), pane fallback
  names = core surface id (Mac uses uuid), per-pane title storage on win32
  Surface (fixes the getTitle TODO; leaf titles now real). Known gaps left
  in the leaf data, all cosmetic for the skill: pid=0, tty="",
  exit_code=null (ConPTY backend doesn't surface them yet) — carried as
  notes, not tasks. Validation: keybind-driven 2-tab + split layout listed
  correctly (human + json); SendKeys only after VERIFYING foreground window
  (first attempt silently missed focus — don't trust AppActivate).
  PowerShell tool note: interleaved native stdout can swallow lines — pipe
  CLI output to files via `cmd /c ... >` when asserting. Next: T06
  (+new-window flags + auto-launch).
- 2026-07-12 (on-box, later) — T04 done — New `src/apprt/win32/IpcServer.zig`:
  named-pipe listener thread (single instance, byte mode,
  PIPE_REJECT_REMOTE_CLIENTS), owner-only DACL via SDDL
  `D:P(A;;GA;;;<user-sid>)`, requests marshaled to the GUI thread via
  message-only window (`WM_APP_IPC` + ResetEvent), framing/error strings
  byte-match the Mac server. FILE_FLAG_FIRST_PIPE_INSTANCE doubles as the
  single-instance lock: second GUI launch gets AlreadyRunning → forwards
  `new-window` as a client → exits. Shutdown drains in-flight WM_APP_IPC
  from deinit (GUI no longer pumping) before joining the listener — verified
  no deadlock via clean exit after IPC use. Dispatch implements `new-window`
  (plain, flags land with T06) and `list` (empty tree, real rendering is
  T05); other verbs answer `unimplemented action on Windows: <verb>`.
  Found while testing: the box had 3 windowless RELEASE ghoztty leftovers
  running (quit-after-last-window-closed=false default keeps the process
  alive headless — macOS parity, maybe surprising on Windows; noting for the
  user, left them running). Next: T05 (+list registry + Mac-format render).
- 2026-07-12 (on-box) — bootstrap + T03 done — First on-box session
  (MaximusHome, D:\git\ghoztty). Toolchain verified (zig 0.15.2 via winget,
  `ZIG_GLOBAL_CACHE_DIR=D:\zig-global-cache` required — cross-drive cache
  panics the build runner). Native win32 Debug build green; exe launches and
  stays up (cmd.exe shell window). T03 round-trip green: `ipc-fake-server.ps1
  -DebugPipe` logged the framed `{"action":"list"}` request, CLI printed
  `No windows open.` exit 0. `zig build test -Dapp-runtime=none` was RED
  natively with 3 fork compile errors, fixed this session: (1)+(2)
  `connection.zig` LifecycleAgent used `std.atomic.Value(u128)` for
  `seen_channel` — x86_64 has no 128-bit atomics (worked on aarch64 Mac);
  now mutex-guarded. (3) `ssh_transport.zig controlPath` called
  `posix.getenv` (comptime error on Windows); now branches per-OS
  (`TEMP` via getEnvVarOwned on Windows). After fixes: full suite green
  natively. Next: T04 (pipe server in win32 App).

- 2026-07-12 (later) — T03 code COMPLETE (353d70abf): new shared
  `src/os/ipc_client.zig` (posix socket + Windows named pipe, framed
  exchange, sendAction), all five client copies collapsed onto it, Windows
  guards removed, win32 `performIpc` is a real pipe client,
  `Action.Key.wireName()` added. Bonus fix 64f5b6984: xtversion test had
  been red since the ghoztty rename. Validated on Mac: core tests green,
  win32 Debug+ReleaseFast cross-compiles green, native macOS build green,
  `+list`/`+set-state`/`+close` live against the debug instance. Box
  round-trip NOT yet run: kit staged at share `ghoztty-windows/t03/`
  (`ghoztty-t03-debug.exe` = Debug build → debug pipe, `ipc-fake-server.ps1`,
  `run-t03.ps1` writes `t03-result.txt`) — run `run-t03.ps1` on the box, or
  fold into T04/T08 validation. Attempted remote-window validation wedged
  the RELEASE app: dial failure → modal alert on locked screen → IPC dead
  until user dismisses (→ new task T30; user must click the alert away).
  Note: `zig build -Dapp-runtime=none -Dtarget=x86_64-windows-gnu` was
  already broken pre-T03 (ssh_transport posix calls, hit via main_c/lib) —
  untouched, tracked nowhere yet; only matters if we ever ship a Windows
  none-runtime lib.
- 2026-07-12 — doc created + full three-way audit run (action matrix, GUI
  features, config coverage — see appendix). Audit added T26–T29 and the
  backlog section; win32 baseline is stronger than assumed (search,
  palette, quick terminal, IME, notifications, global hotkeys all
  present). Fresh ZIP (from 8c22dd370) staged to share; Jul-6 zip backed
  up. Findings that seeded T01/T02: old zip provenance unverifiable;
  ctrl+p/ctrl+f4 never bound anywhere. Next: T01 (needs the box) or T03
  (pure Mac-side) are both unblocked.
