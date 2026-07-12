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

- `src/apprt/win32/App.zig` — `performIpc` returns `false` (all CLI verbs
  dead); action stubs `swap_split`/`toggle_hero_mode`/`activity_state`
  return `false` near the end of the action switch; `startUpdateCheck` is
  hard-disabled with `if (true) return;`.
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
| T02 | Keybind gaps: ctrl+p, ctrl+f4 | A | — | todo | — | — |
| T03 | Named-pipe client helper + CLI un-guard | B | — | in-progress (code done; box round-trip pending) | 353d70abf, 4f52e8877, 64f5b6984 | tests+cross-compiles green; +list/+set-state/+close live vs Mac debug instance; box kit staged (share t03/) |
| T04 | Pipe server in win32 App + marshal + DACL | B | T03 | todo | — | — |
| T05 | `+list` | B | T04 | todo | — | — |
| T06 | `+new-window` full flags + auto-launch + 2nd-instance forward | B | T04 | todo | — | — |
| T07 | `+close` | B | T06 | todo | — | — |
| T08 | P1 acceptance script `test/win32/ipc-p1.ps1` green | B | T05,T06,T07 | todo | — | — |
| T09 | `+split` (window/pane targets, registry) | C | T08 | todo | — | — |
| T10 | `+rename` / titleOverride precedence | C | T08 | todo | — | — |
| T11 | `+send-keys` full notation | C | T08 | todo | — | — |
| T12 | P2 acceptance script green | C | T09,T10,T11 | todo | — | — |
| T13 | `+read` | D | T08 | todo | — | — |
| T14 | `+set-state` + OSC 7777 + title suffix | D | T08 | todo | — | — |
| T15 | `+rearrange` | D | T09 | todo | — | — |
| T16 | P3 acceptance script green | D | T13,T14,T15 | todo | — | — |
| T17 | Skill conformance on the box | E | T12,T16 | todo | — | — |
| T18 | `swap_split` on win32 | F | — | todo | — | — |
| T19 | Hero mode on win32 | F | T18 | todo | — | — |
| T20 | `+new-remote-window --host/--port` (direct TCP) | G | T08 | todo | — | — |
| T21 | Relay dial + browser sign-in + DPAPI creds | G | T20 | todo | — | — |
| T22 | Remote GUI: menu item + machine chooser | G | T21 | todo | — | — |
| T23 | MSI fix → uninstall entry works | H | — | todo | — | — |
| T24 | Windows release channel + enable update check | H | T23 | todo | — | — |
| T25 | Full conformance checklist (spec §8) end-to-end | — | T17,T19,T21 | todo | — | — |
| T26 | OS color-scheme sync (colorSchemeCallback) | I | — | todo | — | — |
| T27 | PowerShell shell integration | I | — | todo | — | — |
| T28 | Minor action no-ops cleanup | I | — | todo | — | — |
| T29 | Mac-side: fix action fallthroughs to showChildExited | I | — | todo | — | — |
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

**T19 — Hero mode.** Focused pane full-size left, carousel right
(reference the Mac implementation in
`macos/Sources/Features/Terminal/`). Pure `Window.zig` layout work.
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
