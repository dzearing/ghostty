# Remote-machines — CONTINUATION PROMPT (resume here)

> Written 2026-06-26 to hand off a long session. Branch `feature/remote-machines`.
> Read this, then `docs/design/remote-machines-progress.md` (tracker) + `…-wp4-macos-ui.md` (UI blueprint).

## 🔴 ACTIVE BUG — fix first

**Cmd-Shift-D (split DOWN) inside a REMOTE window crashes** with a Zig panic
`reached unreachable code`. Crash dump summary in `/tmp/crash_dump.txt` (and below).

- Main thread, via AppKit keypress → libdispatch → ghoztty (Zig core). Stack is
  **deeply recursive** (a Swift `SplitTree` walk, with `libswiftCore` closure frames)
  that calls into libghostty and hits an `unreachable`.
- **Cmd-D (split RIGHT) via `ghoztty +split --from-focused --direction=right` does NOT
  crash** (verified 5×). So the differentiator is the **direction (down)** and/or the
  **keyboard `new_split` action path** (which may differ from `newSplit`-from-focused).
- This is DIFFERENT from the already-fixed concurrent-OPEN crash (`f3e5ec070`).

### How to get a SYMBOLICATED stack (the only reliable way — see learnings)
The orchestrator CANNOT read Ghoztty crash dumps. Have the user (or a terminal) do:
```
# quit any running Ghoztty-Debug first, then:
/Users/dzearing/git/ghoztty-remote/zig-out/Ghoztty-Debug.app/Contents/MacOS/ghoztty
# in the app: Cmd-Shift-N → maximushome (remote window), then Cmd-Shift-D → panic prints to the terminal
```
The printed trace is unsymbolicated (`0x… in ??? (ghoztty)`). To symbolicate, `atos -o
zig-out/Ghoztty-Debug.app/Contents/MacOS/ghoztty -l <loadaddr> <addr…>`, or build with
better debug info, or bisect by reading the keyboard split-DOWN path. Start at the
**keyboard `new_split` action** (NOT just `BaseTerminalController.newSplit`) — find what
the Cmd-Shift-D keybind dispatches to and how it differs from `+split --from-focused`.

## ⚠️ HARD-WON LEARNINGS (do not repeat these mistakes)

1. **IPC repros ≠ keyboard path.** `+split` / `+new-window` over IPC bypass the
   inheriting keyboard path. We added `+new-window --from-focused` and `+split
   --from-focused` to mirror it — but Cmd-Shift-D STILL crashed when `+split
   --from-focused --direction=right` didn't. The ONLY reliable repro is the user's
   keyboard with the **debug binary launched from a terminal** (panic → stderr).
2. **Ghoztty crash dumps are unreadable to us.** `+crash-report` only lists; sentry
   files under `~/Library/Caches/com.mitchellh.ghostty*/sentry` aren't parseable;
   often no macOS `.ips`; nothing in `log show`. → terminal-launch-reproduce or
   Console.app for the stack.
3. **macOS blocks us from the GUI:** no synthesized keystrokes, no AX attribute reads
   (Accessibility not granted to our shell). So we can't trigger Cmd-* or screenshot/
   read windows autonomously. Headless drive = the `ghoztty +…` IPC commands and the
   `--from-focused` variants.
4. **Isolation principle (USER DEMAND, honor it):** the remote path must be ADDITIVE
   and guarded (`if remoteConnection` / `if config.connection`); LOCAL paths
   byte-for-byte unchanged. After ANY fix, verify BOTH: local splits/windows still
   work AND the remote thing works, BEFORE telling the user "done." User is (rightly)
   sensitive to regressions in pane creation + their separate "hero mode" (which lives
   in the `ghoztty-hero-reflow` worktree, NOT this branch).
5. **Agent session pile-up:** the agent keeps sessions alive (idle TTL now 5 min,
   `session.zig:592`) → heavy testing clogs the Windows box → fresh OPEN returns
   `OpenTimeout` / "exhausting a system resource". Fix: redeploy the agent
   (`./scripts/deploy-windows-agent.sh`) → the watcher kills+swaps it → cleared.
6. **Delegate to worktree subagents** to keep orchestrator context lean (user
   preference). Give each a precise brief incl. the repro + isolation constraint;
   cherry-pick the reported SHA back; verify the combined build + BOTH local/remote.

## ✅ WHAT'S DONE (all on `feature/remote-machines`, builds green)

Core remote terminal — **PROVEN LIVE: Mac drives a real Windows cmd.exe over Tailscale**:
- WP1 protocol, inbound ring, agent daemon (real PTY: POSIX + Windows ConPTY), TCP
  transport, client mux, CommandCore, ssh transport (parked), reconnect/catch-up.
- **M2 catch-up PROVEN LIVE** (close laptop → reconnect → caught up). `44220cd0c`.
- WP4 macOS UI: Cmd-Shift-N machine chooser (native, centered, arrow/Enter — `5945f7e13`),
  remote windows, **hostname pill** + **`AXGhosttyMachine`** AX attr (= machine name or
  "Local"; ztabby reads this) `29ee2c71e`, Cmd-N inherits host+command `5236bb863`,
  on-demand **cwd inheritance** (agent reads child cwd via macOS proc_pidinfo / Windows
  PEB) `75c4b301d`, RESIZE-forward render fix `fd198da81`, channel-rendezvous + TCP C API
  `bd87b8a45`, **concurrent-split-OPEN crash fixed** `f3e5ec070`.
- Windows agent **auto-deploys**: `scripts/deploy-windows-agent.sh` drops a build on
  `/Volumes/share/ghoztty-windows/ghoztty-agent.exe`; the Windows watcher
  (`scripts/ghoztty-agent-watcher.ps1`, user runs it once) hot-swaps it. Single x86_64
  binary only ([[ghoztty-windows-artifacts-share]]).
- Headless drive/verify tools: `ghoztty +new-remote-window`, `+new-window
  --from-focused`, `+split --from-focused`; `remote-test-client` (`--exec`,
  `--query-cwd`, `--catchup-demo`); `zig build remote-backend-e2e` / `wp4-e2e`.
- Seeded machine: **maximushome = 100.110.48.108:7777** (user's Windows box, on the
  Home-Assistant subnet, reached via Tailscale).

## ⏳ REMAINING (after the crash)

- **ztabby group-by-machine** — its OWN Claude session runs in
  `/Users/dzearing/git/ztabby-group-by-machine` (branch `users/dzearing/group-by-machine`,
  worktree window open). It reads `AXGhosttyMachine` to render one card per machine
  (machine name vertical on the left edge; up-arrow glide-recenter). Independent.
- **#4 Per-machine CPU/mem in the picker** — NOT started. Needs a new agent metrics API
  (agent samples host CPU/mem) + a client subscription + show it in the picker rows.
  Mirror the cwd-query request/response, but streaming/subscription.

## BUILD / TOOLCHAIN (every shell)
```sh
export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# zig 0.15.2. App: zig build -Doptimize=Debug → zig-out/Ghoztty-Debug.app
# NEVER touch /Applications/Ghoztty.app (user's primary terminal). Debug build only.
```

## RAW CRASH DUMP (Cmd-Shift-D, split-down, remote window)
```
thread 30602323 panic: reached unreachable code
0x10393d43f, 0x103a7153f, 0x103fe6fe7, 0x103fe7fe3, 0x103fe828f, 0x103fe8387,
0x10273157b, 0x1027315ab, 0x1026f9a4f, 0x10271bf37, 0x1027e47df, 0x1027e4843,
<libswiftCore 0x198d4fbe3>, 0x1027e46ff, 0x1026f99ab, 0x10271befb, 0x1027e4747,
0x1026f982f, 0x10271be93, 0x1026f9b87, 0x1026f952b, 0x10271bdbb, 0x1027d805b,
0x1027d82e3, 0x1027d837f, <libswiftCore>, 0x1027d812f, 0x1027d7f2b, 0x1026f917b,
0x10271bd77, … (RECURSIVE: 0x1027d805b/82e3/837f + 0x1026f9xxx + 0x10271bxxx repeat) …
0x102730457, 0x10272edaf, 0x102610d77, 0x10261026f, 0x10262c393, 0x10261247b,
0x102424c17, <libdispatch>, <CoreFoundation>, <HIToolbox>, <AppKit>, 0x1024422cf
```
Recursive Swift `SplitTree` walk → libghostty → `unreachable`. Direction-specific (down).
