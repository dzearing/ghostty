# Windows parity — session log

History only. **Do not read this file as part of normal resume** —
`windows-parity-tasks.md` (state table + task sections) is the hot doc.
Open a single entry here only when you need the backstory for a specific
task (why a decision was made, what a past validation actually proved).


Append newest-first: `YYYY-MM-DD — <tasks touched> — <what happened, what's
next, any surprises>`.

- 2026-07-14 (on-box) — T45/T46 — The 2026-07-13 reset-context failed:
  helper #1's `/clear` was MSYS-mangled into a user message; helper #2
  fired mid-turn because `--when-idle` scrapes for "esc to interrupt",
  which Claude Code v2.1.207 no longer renders — queued keys died with
  the /clear. Mechanism itself proven correct (new ipc-when-idle.ps1,
  T45). Fix (T46): busy = marker OR tail changing between 500ms polls;
  idle = neither across 3 polls. Skill cache gotcha: the 0.6.0 MSYS fix
  was dead on arrival — plugin cache had moved to 0.8.1; patch source
  repo + ACTIVE cache version. New scripts/upgrade-ghoztty-windows.ps1
  does detached kill/swap/relaunch/`claude --continue`; first live run
  upgraded ae71b19b4→7510d2cd2 and resumed the session cleanly (wart:
  cold relaunch also opens a stray default window). Release refreshed
  again with the T46 fix via the same script.
- 2026-07-13 (on-box, +1) — T40–T44 filed from live user reports on the
  installed release; rename-anchor fix + [DEBUG] title marker committed
  but the rename fix CRASHES on real input (T44, marked NEXT). User is
  AFK and wants autonomous progress: pick tasks per go.md, validate
  everything without user interaction (debug exe run from a console gives
  panic traces; synthetic keybd_event chords do NOT fire keybinds — see
  T44 notes before attempting GUI key injection). Session ended via
  /reset-context — its first successful use on Windows would close out
  T36's remaining checkbox (this very reset is the test).
- 2026-07-13 (on-box) — T36 (new, user-directed) — Frontloaded a locally
  installed RELEASE build so ghoztty IPC (and `/reset-context`) powers
  on-box sessions. Merged origin/main (62 commits: `+list --tty`,
  `+send-keys`/`+read --when-idle`, sticky pane banner, remote/relay
  fixes). Conflicts: none.zig (kept our unified ipc_client helper; main's
  set_banner case moved into `wireName()`, which auto-merge had left
  non-exhaustive) and list.zig (kept BOTH `--pid` and `--tty`). New
  `pane_banner`/`prompt_banner` actions ack'd as no-ops → T35 tracks the
  real win32 banner. Gotcha for release builds: native msvc + GUI
  subsystem fails to link (`undefined symbol: WinMain`) — release must be
  `-Dtarget=x86_64-windows-gnu`. Install: `%LOCALAPPDATA%\Programs\
  Ghoztty\{ghoztty.exe, share\}` + user PATH (that dir previously held a
  share\ with NO exe — the T23 MSI upgrade bug's droppings, live
  evidence). reset-context skill Step 1 now branches on
  `/proc/self/winpid` → `+list --pid` (fixed in marketplace repo + plugin
  cache). Both test lanes + P1–P3 ALL PASS post-merge. T28 remains
  in-progress (readonly/key_sequence/pwd/notification chunks untouched
  this session).
  integration (pwsh 7 + Windows PowerShell 5.1): a new
  `src/shell-integration/powershell/ghostty.ps1` chains onto the user's
  prompt (never replaces it) and emits OSC 133 A/B/C/D marks, OSC 7 cwd,
  OSC 2 title, all feature-gated and wrapped so it can never break the
  user's shell. Injected as `-NoExit -Command . '<script>'` (PowerShell has
  no ENV/rcfile hook); non-interactive invocations (-Command/-File/-c/
  -EncodedCommand) bail out untouched. **The task's premise understated the
  problem: OSC 7 was dead on Windows in the CORE** — `reportPwd` began with
  `if (windows) { log.warn("unimplemented"); return; }`, so NO shell could
  report cwd on Windows, ever. Implemented it, including URI→native path
  normalization (`/D:/git/x` → `D:\git\x`). Bug caught in my own fix:
  `stackFallback.get()` must be called exactly once — calling it twice
  panics (reached unreachable code). Validated live: a PowerShell pane's
  reported cwd now tracks `cd` (D:\git\ghoztty → C:\Windows → C:\Users).
  cmd.exe still cannot be integrated (no prompt hook) — inherent.
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
