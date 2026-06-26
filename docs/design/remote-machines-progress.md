# Remote Machines — implementation progress

> **Resume point.** This is the durable tracker for the remote-machines feature.
> The design spec is `docs/design/remote-machines.md` (§18 = work packages).

## ▶ ON RESUME — when the user says "go" (or "go to progress")

A fresh session should, in order:
1. Read THIS file end-to-end, then skim the design doc §3, §4, §18.
2. Set up the build env (no system zig — see "Toolchain status" below):
   ```sh
   export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   ```
3. Sanity-check: `git log --oneline -8`, `zig test src/remote/connection.zig`
   (expect "All N tests passed"), and that the working tree is clean
   (`rm -rf zig-pkg` if a stray pkg-cache dir appears).
4. Continue from **"Recommended next actions"** below. **Delegate implementation
   to subagents** (the user wants the orchestrator's context kept lean): give each
   a self-contained brief, have it implement + `zig test`/`zig build`-verify +
   commit on `feature/remote-machines` with the `Co-Authored-By: Claude Opus 4.8
   (1M context)` trailer, then report back concisely. The orchestrator keeps THIS
   file + the memory updated after each increment lands.

_Last updated: 2026-06-26. Branch: `feature/remote-machines` (integration branch;
merges to `main` once green as a whole). HEAD at/after `8a9f7bc14` (CommandCore +
ssh Transport + agent real-PTY landed; Windows-exe e2e push in flight)._

## Status at a glance

Order (§18): **WP1 → {WP2, WP3} → WP4 → {WP5, WP6, WP8} → {WP7, WP9} → WP10.**

| WP | Scope (short) | Status | Commit |
|----|---------------|--------|--------|
| WP1 | Protocol lib (`src/remote/protocol.zig`) | ✅ **Done** — 21 tests green | `81275a9d4` |
| WP3-spike | Inbound ring + ChannelTable (`src/remote/inbound_ring.zig`) | ✅ **Spike done, gate passed** — 6 tests green | `7210e230e` |
| WP2-spike | Windows agent risks (`src/remote/agent/spike/`) | ✅ **Spike done** — cross-compiles x86_64+aarch64 windows | `7168891fb` |
| WP3-full | Client connection + `termio.Remote` + C API | ✅ **inc.1–4b done**; inc.3b (ssh+reconnect) next | see below |
| ↳ inc.1 | `connection.zig` transport core (Stream, handshake, MPSC writer, demux→rings) | ✅ Done — 33 tests | `ca02e266b` |
| ↳ inc.2 | health: `RttEstimator`, `LinkState` FSM, heartbeat, PONG/DETACHED handling | ✅ Done — 40 tests | `07ca686d8` |
| ↳ inc.3 | channel/session lifecycle (OPEN/ATTACH/CLOSE/DETACH), resync §7.3, steal §5.3, FLOW-pause | ✅ Done — 50 tests | `176d85ad4` |
| ↳ inc.4a | `termio.Remote` (Backend contract) + `backend.zig` `.remote` arm — **libghostty compiles with remote backend** | ✅ Done | `d6b463753` |
| ↳ inc.4b | `Surface.zig:682` construct `.remote` + `ghostty_surface_config_s` + `ghostty_remote_*` C API | ✅ Done — Zig build green | `de230b6de` |
| ↳ CommandCore | `Command.zig`→`CommandCore` extraction (DI of rlimits/pre_exec/post_fork; §17) — GUI-free spawn core; unblocks ssh Transport + agent PTY | ✅ Done — full debug build green | `ed98b22fe` |
| ↳ ssh Transport | `connection.Stream` over ssh subprocess: two-channel ControlMaster (§4.3), `ChildStream` over pipes, SSH_ASKPASS/host-key, C-API `_start` now dials | ✅ Done — 60 tests + full build | `1766a783a` |
| ↳ client mux | client-side lane mux: two logical streams over ONE transport stream (mirrors agent `StdioMux`) — reconciles framing mismatch (see frontier) | 🔨 IN PROGRESS | — |
| **WP2** | Agent daemon | 🔨 **agent inc.1 + real-PTY done**; Windows ConPTY next | see below |
| ↳ agent inc.1 | `src/remote/agent/` session-server core (HELLO/OPEN/DATA/ATTACH/RESIZE/SIGNAL/DETACH/CLOSE/EXIT, session table, ring, tombstones) over abstract transport + fake child | ✅ Done — 18 tests | `c4b09c774`→`26af4f78a` |
| ↳ agent real PTY | real POSIX pty child (`pty_child.zig`), `zig build agent`→`ghoztty-agent`, single-stdio `StdioMux`, smoke round-trips `echo` through pty/ring/DATA | ✅ Done — 40 tests + binary smoke | `8a9f7bc14` |
| ↳ ConPTY smoke | **NEW (Windows pivot):** minimal cross-compiled `ghoztty-conpty-smoke.exe` to runtime-prove ConPTY on the user's real Windows box (reuses in-tree `pty.zig` WindowsPty + `CommandCore.startWindows`) | 🔨 IN PROGRESS | — |
| ↳ Windows ConPTY arm | `pty_child.zig` cross-platform: Windows ConPTY (ReadFile/WriteFile/0x03-interrupt/TerminateProcess/close-before-join); POSIX identical (75 tests); cross-compiles to .exe | ✅ Done | `e2e72045d` |
| ↳ TCP + daemon + client | socket Stream, agent TCP listen (loop-accept daemon, default 0.0.0.0:7777), client TCP dialer, Mac `remote-test-client` exe; **Mac-localhost e2e drives a real shell over TCP** | ✅ Done — e2e green | `85faeb456` |
| ↳ **M1 networked agent.exe** | `ghoztty-agent.exe` (TCP listen + ConPTY); **PROVEN LIVE** — Mac drove real `cmd.exe` on the Windows box over Tailscale | ✅ Done | — |
| ↳ auto-deploy | Windows `ghoztty-agent-watcher.ps1` hot-swaps a new .exe dropped on the share; Mac `scripts/deploy-windows-agent.sh` builds+drops. Removes user from test loop | ✅ Done | `98b936c65`,`20740030e` |
| ↳ **M2 catch-up** | daemon never wedges (per-conn threads + two-phase teardown) + session-survival (`SessionStore`, detach-not-terminate, idle-TTL, ATTACH ring-replay). **PROVEN LIVE on Windows** (PowerShell session survived disconnect, caught up no-gap) | ✅ Done — 123 agent tests | `44220cd0c`,`dd6d4b46c` |
| ↳ channel rendezvous | client `Connection.openChannel` vs server-authoritative channel mismatch; test_client works around it at frame level — **must reconcile for WP4 Surface/.remote path** | ⛔ WP4 prereq | — |
| ↳ WP4 render fix | `Remote.resize` dropped the post-layout 0×0→real resize so the remote pty stayed 0×0 (blank surface); now forwards live RESIZE. Headless harness (`remote-backend-e2e`) proves the grid renders | ✅ Done | `fd198da81` |
| **WP4** | macOS UI: machine chooser (Cmd-Shift-N) + remote windows + inheritance | ⛔ Next — blueprint in `remote-machines-wp4-macos-ui.md` | — |
| WP4 | Swift connection context (`+connect` etc.) | ⛔ Blocked on WP3 C API | — |
| WP5 | Manifest + resumability | ⛔ Not started (P2) | — |
| WP6 | Tunneling | ⛔ Not started (P2) | — |
| WP7 | Connection Manager UI | ⛔ Not started (P3) | — |
| WP8 | Process mgmt + RPC | ⛔ Not started (P2) | — |
| WP9 | Ports + Activity UI | ⛔ Not started (P3) | — |
| WP10 | Skill, docs, CI, Windows harness, e2e | ⛔ Not started (P3) | — |

**Phase (§16):** P1 (core remote panes) in progress — WP1 + both gating spikes
done; WP3 client transport DONE through inc.4b; WP2 agent core (inc.1) done.
**Toolchain ✅ fully solved** — `zig build -Doptimize=Debug` produces a runnable
`zig-out/Ghoztty-Debug.app` (see "Toolchain status"). P1 still needs the ssh
Transport + the agent's real PTY, then WP4 (Swift).

### Current frontier — Windows e2e pivot + the framing mismatch (read before continuing)

**Target chosen 2026-06-26:** the user has a **real Windows machine** (regular
Windows, NOT WSL) on the same network (+ Tailscale available). The first real
end-to-end test is **Mac client → Windows `ghoztty-agent.exe`** driving a real
Windows shell. `ssh localhost` is OFF on this Mac (Remote Login disabled), so we
go cross-machine to Windows instead. Plan: **TCP transport over Tailscale** (agent
listens; Mac dials) — simplest first hop; ssh-on-Windows + the two-channel
ControlMaster path come later. Good news: **Windows ConPTY support already exists
in-tree** (`src/pty.zig` `WindowsPty` + `CommandCore.startWindows` ConPTY spawn) —
only `pty_child.zig` is POSIX-specific. The spike's deferred "does ConPTY work at
runtime" validation is unlocked by this Windows box.

**⚠ Cross-track FRAMING MISMATCH being reconciled (client mux, in progress):** the
ssh-transport track dials **two** ssh channels (→ two agent processes); the agent
is a **single** process muxing both lanes on one stdio (`StdioMux`, ignores argv).
The two-channel design (§4.3 control/data isolation) needs agent **daemonization**
(deferred) to rendezvous two channel-processes. Interim fix = a **client-side mux**
(symmetric to the agent's `StdioMux`): the client's two logical `Connection`
streams ride ONE transport stream (ssh-single-subprocess OR TCP). Routing rule both
ends share: `frame.type == .data` → data lane, else → control lane. This is what
makes any single-stream e2e (incl. the Windows TCP path) work now.

Both halves exist and pass tests in isolation, sharing the frozen WP1 protocol —
but **they have not talked to each other yet**, so nothing connects end-to-end:

- **Client** — libghostty compiles with a `.remote` backend + the C API the Swift
  app binds to (commit `de230b6de`): `ghostty_surface_config_s` gained
  `ghostty_remote_connection_t connection` (opaque `void*`; non-NULL ⇒ `.remote`) +
  `const char* session_id`. Functions: `ghostty_remote_connection_new(const
  ghostty_remote_config_s*)` (host/user/port/jump), `_start`, `_wait_handshake`,
  `_latency_ms` (→ -1 unknown), `_free`. **`_start` returns false today (TODO)** —
  the `ssh`-backed `connection.Stream` doesn't exist yet, so `remoteBackend()`
  falls back to local. That ssh Transport is the one missing piece before a real
  connection can be dialed.
- **Agent** (`src/remote/agent/{session,server}.zig`, 18 tests) — full frame
  routing, session table (crypto UUIDs, ring, tombstones, gap-fill), MPSC writer.
  **Stubs:** fake buffer-backed child (no real PTY — `// TODO(pty)` for
  `Command.zig`→`CommandCore`), `snapshot_at_offset` = current byte offset (no grid
  model yet), no daemonization, not in any build target. Test it with:
  `zig test --dep protocol -Mroot=src/remote/agent/server.zig -Mprotocol=src/remote/protocol.zig`

## What "spike done" means here

The first round (this session) built the three §18 items that **must precede
fan-out**: WP1 (the shared wire contract) and the two **gated spikes** the design
demanded before WP2/WP3 expand (§17):

- **WP3 inbound-ring gate (§3.4/§17):** the SPSC ring + ChannelTable primitive is
  built and its stress harness proves no cross-pane HOL structurally (4 channels,
  one firehose, quiet panes complete before the firehose drains). ✅ The
  *remaining* part of the gate is the **integration benchmark** (a real 4-pane
  remote window vs the same local layout, no input-latency regression) — that
  belongs to WP3-full because it needs the wired client.
- **WP2 Windows spike (§13/§17):** every Windows API path compiles and links for
  Windows targets (build-time proof). ✅ The **runtime** validations (binary-stdio
  fidelity through `ssh-shellhost`, daemon survival across sshd teardown, job
  reassignment) require a real Windows host — see
  `src/remote/agent/spike/FINDINGS.md` §"On-Windows test procedure".

## Recommended next actions (in order) — Windows e2e push

CommandCore, the ssh Transport, and the agent real-PTY are DONE. The goal now is a
**first real cross-machine pane: Mac client → Windows `ghoztty-agent.exe`** over
TCP/Tailscale. Delegate each to a worktree subagent (keep the orchestrator lean).

1. **ConPTY runtime smoke** (in progress) — minimal cross-compiled
   `ghoztty-conpty-smoke.exe` the user runs on their Windows box to prove (a) a
   zig-cross-compiled exe runs on regular Windows and (b) ConPTY spawns a shell at
   runtime. Reuses in-tree `pty.zig` WindowsPty + `CommandCore.startWindows`.
2. **Client-side lane mux** (in progress) — two logical `Connection` streams over
   ONE transport stream (mirrors agent `StdioMux`; rule: `.data`→data, else→control).
   Unblocks every single-stream e2e path (TCP + single-ssh).
3. **Windows agent exe** (blocked on 1+2) — make `pty_child.zig` cross-platform
   (ConPTY handles, `ReadFile`/`WriteFile`, `GenerateConsoleCtrlEvent` for signals);
   add a **TCP transport** (agent listens on a Tailscale-reachable port, both lanes
   muxed over one socket via the client mux ↔ a server-side equivalent; client dials
   TCP); `zig build` cross-target → `ghoztty-agent.exe`. Then the real e2e: user runs
   the exe, Mac client OPENs a session + drives a Windows shell, prove round-trip.
4. **Then**: real reconnect driver (WP3 inc.3b), Swift connection context (WP4,
   binds `ghostty_remote_*`), §6.5 vim-over-ssh fidelity, §3.4 4-pane benchmark.

Later: real grid-model snapshot (§7.3/§13.1), agent daemonization to enable the
two-channel ssh path (§4.1/§4.3), then P2 (WP5/6/8) and P3 (WP7/9/10).

**Parallel-work protocol (when running tracks concurrently):** give each subagent
`isolation: "worktree"`; it commits in its worktree; the orchestrator cherry-picks
the reported SHA back onto `feature/remote-machines` and re-verifies the combined
build (the worktree may branch off a stale base — subagents should `git reset --hard
feature/remote-machines` first, as the inc.4b/agent runs did). Prefer disjoint file
sets across parallel tracks so cherry-picks don't conflict.

## Toolchain status — ✅ FULLY SOLVED (the runnable `.app` builds)

**Resolved 2026-06-25 with NO Apple download.** Homebrew ships a `zig@0.15`
bottle built FOR macOS 26 (`arm64_tahoe`) that already includes the #31673 linker
fix. Setup (one-time, all done):

```sh
brew install zig@0.15 gettext        # zig@0.15 = 0.15.2, keg-only
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer   # DONE
```

Every shell that builds/tests must export:
```sh
export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

VERIFIED end-to-end:
- `zig test src/remote/<module>.zig` — native target, no `-target` needed.
- `zig build -Doptimize=Debug` → **`zig-out/Ghoztty-Debug.app`** (complete,
  code-signed; bundle id `com.mitchellh.ghostty.debug`; 142 MB `ghoztty` binary).
  Full pipeline works: zig core + xcodebuild (Xcode 26.4) + Metal toolchain +
  Swift + signing. **NEVER touch `/Applications/Ghoztty.app`** (user's primary
  terminal) — debug build only.

(Historical: before the `xcode-select` switch, the build stopped at the final
xcodebuild step — that gate is now cleared.)

Everything below is the prior investigation, kept for reference.

<details><summary>Original investigation (root cause, dead ends)</summary>

### Root cause is a known, FIXED zig bug
not a fundamental limitation** (ziglang/zig issue #31658, fix PR #31673,
backported to 0.15.2): the **macOS 26.4 SDK** (shipped with Xcode/CLT **26.4**)
changed its `.tbd` stub files so zig's MachO linker fails to match `aarch64-macos`
against `arm64e-macos` entries → every libSystem symbol (`_abort`, `_bzero`,
`__availability_version_check`, …) goes unresolved. It blocks `zig build` entirely
because the build *runner* is compiled for the native host (min macOS 26.4) before
build.zig's own macOS-13 down-targeting applies. Confirmed: the same code links
fine at an older min-version / older SDK. **Users on macOS 26.4 but the 26.2/26.3
SDK build fine** — it is the 26.4 SDK specifically.

Confirmed dead ends (don't re-try): `MACOSX_DEPLOYMENT_TARGET`/`SDKROOT` env
(zig calls `xcrun --show-sdk-path`, ignores them; reads host version from the
SIP-protected SystemVersion.plist); `-flld` (LLD unsupported for macho in 0.15.2);
patching the bundled std macos.zig (doesn't change the compiler's baked-in
detection); zig 0.16.0 (links 26.4 fine but the repo `requireZig`s exactly 0.15.2
and 0.16 breaks the 0.15-era build.zig/codebase).

**This machine's state (2026-06-25):** macOS 26.4; **full `/Applications/Xcode.app`
is installed but it is 26.4** (broken SDK); `xcode-select` points at CLT (also
26.4). An older **`MacOSX15.4.sdk` exists on disk** but zig won't use it (uses
xcrun's default). Important: **Nix cannot build Ghostty's macOS app at all** (no
Swift 6 / xcodebuild support) — `nix develop` only provides the dev shell; the
`.app` is built with **zig + full Xcode** directly (ghostty.org/docs/install/build).

### The fix (requires a ≤26.3 SDK active — a user download from Apple)

To run `zig build` (and build the `.app`), get a **macOS 26.3 (or 26.2) SDK** as
the active developer dir. Two routes:

- **Recommended (also unblocks the `.app`): Xcode 26.3.** Download Xcode 26.3 from
  developer.apple.com, install side-by-side as `/Applications/Xcode_26.3.app`,
  then:
  ```sh
  sudo xcode-select --switch /Applications/Xcode_26.3.app/Contents/Developer
  rm -rf ~/.cache/zig ~/git/ghoztty-remote/.zig-cache
  # build the debug app (NEVER touch /Applications/Ghoztty.app):
  cd ~/git/ghoztty-remote && zig build -Doptimize=Debug   # → zig-out/Ghoztty-Debug.app
  ```
  Xcode 26.3 gives BOTH the working 26.3 SDK AND the Swift 6/xcodebuild/Metal
  toolchain the `.app` requires.
- **Lighter interim (unblocks `zig build` of libghostty/CLI/tests, NOT the `.app`):
  Command Line Tools for Xcode 26.3** (~1 GB vs Xcode's ~10 GB), then
  `sudo xcode-select --switch /Library/Developer/CommandLineTools` + clear caches.
- **No-download alternative:** a zig 0.15.2 binary with PR #31673 backported (the
  nix `brew."0.15.2"` zig-overlay variant may already include it; unverified).

### What works locally TODAY without any of that (use for WP3-full Zig dev)

- Per-module unit tests: `zig test -target aarch64-macos.13.0.0 src/remote/<m>.zig`
- Explicit-target compiles/cross-compiles: `zig build-exe/-lib/-obj -target …`
  (e.g. the WP2 Windows spike). Only `zig build` and `.app` runs are blocked.

### Down-target commands (host module tests)

- **Host unit tests** (WP1, WP3, future host modules):
  `zig test -target aarch64-macos.13.0.0 src/remote/<module>.zig`
- **Windows spike cross-compile** (build-time proof):
  ```sh
  zig build-exe -target x86_64-windows-gnu -femit-bin=/tmp/spike.exe \
    --dep protocol -Mroot=src/remote/agent/spike/main.zig \
    -Mprotocol=src/remote/protocol.zig
  ```
- The full app build (`zig build -Doptimize=Debug`) and the Swift app need a
  working native toolchain — get a zig whose linker supports the host SDK (or a
  newer zig) before WP4. The `src/remote/*` modules are **not yet wired into
  build.zig**, so they don't affect the main build yet; wire them in WP3-full.
- **Never touch `/Applications/Ghoztty.app`** (user's primary terminal). Debug
  build only: `zig-out/Ghoztty-Debug.app`.

</details>

## Conventions

- One commit per package on `feature/remote-machines`; cite the design §sections.
- Trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Match surrounding Zig idiom/comment density (`src/termio/*.zig`, `src/pty.zig`).
- **Update this file** when a package lands: flip the status, add the commit hash,
  and adjust "next actions".

## Open gates / things to verify before declaring P1 done

- [ ] WP3 integration benchmark: 4-pane remote vs local, no quiet-pane latency
      regression (§3.4 gate, runtime).
- [ ] WP2 on-Windows runtime procedure (FINDINGS.md): binary stdio fidelity,
      daemon survival, job topology, squatter rejection, Ctrl-C escalation.
- [ ] TERM/terminfo: `vim` runs remotely over `ssh localhost`/Linux (P1 demo, §6.5).
- [ ] Interactive SSH auth + first-contact host-key UX surfaced via `SSH_ASKPASS`
      (§4.1, day-1 wall — validate before/with WP4).
- [ ] TSan the inbound ring on a host where libtsan builds
      (`zig test -fsanitize-thread src/remote/inbound_ring.zig`).
