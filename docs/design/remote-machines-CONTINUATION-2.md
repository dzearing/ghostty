# Remote-machines — CONTINUATION PROMPT #2 (resume here after /clear)

> Written 2026-06-28 to hand off a long session. Branch `feature/remote-machines`.
> Read this first, then skim `remote-activity-monitor.md` (the now-mostly-built spec)
> and `remote-machines-CONTINUATION.md` (#1, older) + `remote-machines-progress.md`.

## ▶ ON RESUME — top priorities (the user's words, in order)

1. **Remote terminal WEDGING (this is the real bug; "exit doesn't work" is a symptom).**
   The exit-close fix (`19bad3fd5`) is CORRECT and PROVEN on a healthy connection (see
   below). The user's `exit` "doesn't work" because their remote window **wedges** —
   input stops flowing, so `cmd.exe` never receives `exit`, never exits, no EXIT frame,
   so nothing closes. **Fix the wedging and exit works for free.** This is the #1
   usability blocker for remote panes.
2. **Make the agent a SYSTRAY app (Windows).** Today `ghoztty-agent.exe` is a headless
   console daemon. The user wants a real Windows system-tray app: see it running, an
   **About** box, **Check for updates**, **Exit**, a list of **all sessions the agent is
   controlling** (the SessionStore already tracks these — surface them), and maybe a
   **Settings pane** (port, bind addr, auth, idle-TTL, etc.).
3. **Port tunneling** — so the user can "see the inner loop for remote sessions easily"
   (e.g. forward a remote port to localhost to inspect a dev server / the agent's own
   state). The protocol already reserves `tunnel = 0x40` (`src/remote/protocol.zig`
   `Tunnel{op,type,listen,dest,autostart}`, types L/R/D; `-R`/`-D` are gated). WP6 in the
   design doc. Nothing is implemented yet end-to-end.

## 🔴 THE EXIT BUG — precise truth (do NOT re-chase the exit logic)

- The agent already sends `EXIT{code,runtime_ms}` on the **control lane** for the
  session's channel when the child reaps (`server.zig` `bridgeExit` → `session.zig:666`,
  `runtime = now_ms - created_ms`).
- The client fix (`19bad3fd5`) wires it: `connection.zig` `handleControlInternal` `.exit`
  arm → `channels.withChannel(frame.channel, signalExit)` → `inbound_ring.Channel`
  gains `exited`/`exit_code`/`runtime_ms` + a `signalExit` that wakes the pane → `Remote.zig`
  `drainRing` (after draining) emits `td.surface_mailbox.push(.child_exited{...})`, the
  SAME path local `Exec.zig:309` uses → `Surface.childExited` (`Surface.zig:1358`) closes
  the pane (honoring `wait-after-command`; on Darwin a `runtime <= abnormal-command-exit-
  runtime` (250ms) exit shows "Process exited. Press any key" instead of closing).
- **PROVEN working** via temporary DIAG logging (since removed): on a healthy connection,
  `exit` produced `DIAG EXIT frame ... found=true` + `DIAG drain emitting child_exited`
  and the window closed (verified 3× by window-count 1→0). To re-prove: re-add the two
  `warn("DIAG ...")` lines (one in the `.exit` arm of `connection.zig`, one before the
  `surface_mailbox.push` in `Remote.zig`), launch the debug binary from a terminal so
  stderr is captured (`nohup macos/build/Debug/Ghoztty-Debug.app/Contents/MacOS/ghoztty
  > /tmp/ghoztty-diag.log 2>&1 &`), reproduce, `grep DIAG /tmp/ghoztty-diag.log`.
- When the user's window FAILS to exit, the log shows **no** DIAG EXIT (the keystroke
  never reached the remote) plus things like `remote proc_list failed err=error.Timeout`
  → the **connection is wedged**, not the exit code. So: chase the wedge.

## 🐛 THE WEDGE — what we know (start here for priority #1)

Symptom: a remote window connects + shows the prompt, then **input stops flowing**
(typing isn't echoed, `exit` does nothing, RPCs like proc_list time out). The window
"sits there not responding." Fresh windows on a freshly-redeployed agent work; older
ones / ones opened during agent instability wedge.

Leading hypotheses (unverified — investigate):
- **Agent overload / resource exhaustion from too many concurrent connections.** Each
  remote TERMINAL window is one connection; the **Activity Monitor adds MORE** (a metrics
  subscription per open panel + a proc_list poll every 1.5s + the **carousel's
  `MachineMetricsProbe` dials a separate connection per registered machine** + the
  ⌘⇧N picker probes). So opening the AM while terminals are open multiplies agent
  connections. The agent handles each in per-conn threads; under load + session pile-up it
  wedges. **Strongly suspect this.** Consider: cap/coalesce AM connections (reuse one),
  back off proc polling, and load-test the agent with N concurrent connections.
- **Orphaned-shell / session pile-up** starves the Windows box (see below).
- Possible flow-control bug (FLOW pause without resume) or heartbeat/link-FSM issue on a
  degraded link. Add link-state + flow logging and watch a wedge happen.

How to reproduce-ish: open a remote window, open the Activity Monitor, leave it a while
with churn; or just hammer many opens. The agent's `--exec` round-trip still works when a
GUI window is wedged, so it's likely per-connection, not whole-agent.

## 🗑 ORPHANED SHELLS / SESSION PILE-UP (related to the wedge)

Each remote session spawns `cmd.exe` (+ `conhost.exe`) via ConPTY. They pile up because:
- **Session survival (§7.1):** a shell deliberately stays alive ~5 min (idle-TTL,
  `session.zig`) after a CLIENT disconnects, for reconnect. Self-cleans.
- **Redeploy orphans (the big one during dev):** the watcher
  (`scripts/ghoztty-agent-watcher.ps1:60`) stops the old agent with `$proc.Kill()` — NOT a
  tree kill — so on every `deploy-windows-agent.sh` the old agent's `cmd.exe`/`conhost.exe`
  ORPHAN and survive forever. A dozen redeploys = a dozen orphan shells → box clutter +
  resource pressure → wedging. **THE SIMPLE FIX (do this):** change the watcher's
  `$proc.Kill()` to a tree kill, e.g. `Start-Process taskkill -ArgumentList '/F','/T','/PID',$proc.Id -Wait`
  (kills the agent AND its descendant tree). Drop the new watcher on the share; the user
  re-runs it once. (Only matters for redeploys, so low priority for the USER, but it kills
  the dev-churn orphan source that's been confusing everything.)
- **FAILED approach (don't repeat):** a kill-on-close Windows **Job Object** on the agent
  for its PTY children (`9969c06c2`, `pty_child.zig` `PtyJob`). Live test PROVED it does
  NOT work here — `AssignProcessToJobObject` is blocked by the agent's existing job
  environment, so children survive the agent's death. The code is harmless (best-effort,
  logs + falls back) but ineffective. Consider reverting it, or fixing via the watcher
  tree-kill instead. NOTE: `proc_spawn.zig` (Activity-Monitor "New Process") intentionally
  uses `CREATE_BREAKAWAY_FROM_JOB` so those DO survive the agent — keep that.

To clean the box manually: `remote-test-client … --kill=<pid>` each stray, or use the
Activity Monitor's new **multi-select + Kill N**.

## ✅ WHAT THIS SESSION BUILT (all on `feature/remote-machines`, builds green)

The **Remote Machine Activity Monitor** — full vertical slice, mostly DONE + verified
live against the Windows box (maximushome = 100.110.48.108:7777). 26 commits
(`eb292348b`..`9969c06c2`). Highlights:
- Protocol metrics/proc frames (`0x70`–`0x78`; the design doc's `0x30` suggestion COLLIDED
  with `rpc` — we used `0x70+`). Agent host-metrics `Sampler` + process enumeration
  (Windows Toolhelp + `QueryFullProcessImageNameW` full paths; macOS libproc) +
  per-process CPU deltas. Client `subscribeMetrics`/`requestProcSnapshot`/`killProc`/
  `spawnProc` + C API + a LOCAL in-process provider (`ghostty_local_*`).
- **kill** (real pid, perm-denied surfaced) and **spawn** — both LIVE-VERIFIED on Windows.
  Spawn persists via `CREATE_NEW_CONSOLE|CREATE_NEW_PROCESS_GROUP|CREATE_BREAKAWAY_FROM_JOB`
  (the null-`\Device\Null` stdio in `CommandCore.startWindows` was killing console apps).
- **Panel** (`RemoteActivityMonitorView.swift`): machine-card **carousel** (Local + remotes,
  1-click + keyboard arrows/Enter, per-card uptime via the picker probe), 50/50 **trend
  charts** (Swift Charts, soft 0/25/50/75/100 gridlines, hover tooltip), filter on top, no
  manual refresh (1.5s poll), **Path** column (replaced User), row selection + **Kill** +
  **multi-select bulk kill**, **New Process** spawn sheet, **ghoztty-spawned filter**
  (default: agent + descendants via `agent_pid`; "Show all" toggle; shows "N of M").
- **3 entry points:** clickable titlebar pill, ⌘⇧P command-palette "Activity Monitor"
  (opens the panel DIRECTLY now — was wrongly opening the New Window chooser as a broken
  nested modal), and the ⌘⇧N picker's chart-button.
- **⌘⇧N picker fixes:** centered (size-to-fit before centering), single-click selection
  (rebuilt rows as Buttons — `List`/`onTapGesture` didn't register clicks), keyboard
  arrows + Escape.
- **Exit-closes fix** (`19bad3fd5`) — correct, see above.

## ⚠️ HARD-WON LEARNINGS (do NOT repeat — these cost hours)

1. **ALWAYS kill+relaunch the debug app yourself after a build** ([[ghoztty-debug-relaunch-after-build]]).
   A NEW WINDOW in a running app does NOT reload code. The user repeatedly tested STALE
   instances and a fix "looked broken." After every `zig build -Doptimize=Debug`:
   `pkill -9 -f "Ghoztty-Debug.app/Contents/MacOS/ghoztty"; sleep 3; open macos/build/Debug/Ghoztty-Debug.app`.
   Tell the user "relaunched — test in THIS one." NEVER churn silently.
2. **GUI driving is now possible but FLAKY** ([[ghoztty-gui-driving-now-possible]]).
   Accessibility + Screen Recording are granted to `/Applications/Ghoztty.app` (the
   release app that hosts the Claude session). You can `osascript` keystrokes + `screencapture`.
   BUT focus constantly bounces back to the release app (your own session) between Bash
   calls, so synthetic `keystroke`/`click at` aborts ~half the time. ALWAYS confirm
   `frontmost == debug pid` immediately before any keystroke (the safety guard saved the
   user's session from stray input). `open <app>` (LaunchServices activate) is more reliable
   than System-Events `set frontmost`. `keystroke` triggers Buttons but NOT SwiftUI
   `.onTapGesture`. PREFER: verify build + backend yourself, then ASK THE USER for the
   final visual confirm — don't burn cycles fighting focus.
3. **VERIFY RIGOROUSLY, never claim off a proxy.** A title-grep "the window closed" was a
   FALSE POSITIVE (the window stayed open, retitled). Count actual windows; use DIAG logs;
   reproduce the USER's exact path. The user (rightly) called out hand-wavy claims twice.
4. **The debug app is Gatekeeper-`rejected` (ad-hoc signed)** → the USER gets "permission
   denied" launching it (and must use `open <app>`, NEVER the inner binary path which can
   SIGKILL). Manage the instance FOR them. Two same-bundle-id copies exist (`zig-out/...`
   and `macos/build/Debug/...`) → transient `launchd spawn failed (162)`; just retry `open`.
   A debug instance QUITS when its last window closes (`quit-after-last-window-closed=false`
   is set but `open`-launched instances with no other windows can still go away) — keep one
   default window around.
5. **Agent session/orphan pile-up wedges the box** — redeploy clears it
   (`./scripts/deploy-windows-agent.sh`); be disciplined about not leaving stray sessions.
6. **Delegate to worktree subagents; cherry-pick the reported SHA back; rebuild + relaunch.**
   Disjoint file sets (agent Zig vs Swift UI) cherry-pick cleanly. Remove `.git/index.lock`
   if a stray appears (concurrent worktree git ops).

## BUILD / DEPLOY / TEST (every shell)
```sh
export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# zig 0.15.2. App: zig build -Doptimize=Debug → zig-out/ AND macos/build/Debug/Ghoztty-Debug.app
# Agent (Windows): zig build agent -Dtarget=x86_64-windows-gnu ; deploy: ./scripts/deploy-windows-agent.sh
#   (watcher hot-swaps within ~5-10s; redeploy clears all sessions)
# Headless drive: ./zig-out/bin/remote-test-client 100.110.48.108 7777 --metrics=N | --ps[=N] | --exec "<cmd>" | --kill=<pid> | --spawn="<cmd>"
#   (rebuild it after any change: zig build remote-test-client)
# NEVER touch /Applications/Ghoztty.app (user's primary terminal). Debug build only.
# SMB share for Windows artifacts: smb://homeassistant/share (homeassistant=192.168.1.21) → /Volumes/share/ghoztty-windows
```

## SUGGESTED NEXT-SESSION PLAN
1. **Wedge first.** Add link-state + flow + per-connection logging; reproduce by opening
   the AM alongside terminals; check whether AM/probe connections are the load. Likely
   wins: make the AM reuse ONE connection per machine (not per-panel + per-card-probe),
   throttle proc polling, and/or fix a flow-control resume bug. Re-verify `exit` after.
2. **Watcher tree-kill** (quick) to stop dev-churn orphans.
3. **Agent systray app** (Windows): wrap `ghoztty-agent.exe` (or a sibling tray exe) with a
   Shell_NotifyIcon tray + menu (About / Check updates / Exit / Sessions / Settings). The
   `SessionStore` already enumerates live sessions — expose them. Keep the headless daemon
   mode for CI. Cross-compile via zig `-Dtarget=x86_64-windows-gnu`; Win32 tray APIs via
   `extern "user32"`/`"shell32"` (same pattern as the metrics/proc externs).
4. **Port tunneling** (WP6): implement `tunnel = 0x40` end to end (client request → agent
   opens/forwards a socket → bytes piped over a data channel), L first (local forward), gate
   R/D. Lets the user forward a remote port to localhost to inspect remote sessions.
