# Remote Machines — implementation progress

> **Resume point.** After a context reset, read this file first ("go to progress").
> It is the durable tracker for building the remote-machines feature; the design
> spec is `docs/design/remote-machines.md` (§18 = work packages, the source of
> truth for scope and order). Keep this file updated as packages land.

_Last updated: 2026-06-24. Branch: `feature/remote-machines` (integration branch;
merges to `main` once green as a whole)._

## Status at a glance

Order (§18): **WP1 → {WP2, WP3} → WP4 → {WP5, WP6, WP8} → {WP7, WP9} → WP10.**

| WP | Scope (short) | Status | Commit |
|----|---------------|--------|--------|
| WP1 | Protocol lib (`src/remote/protocol.zig`) | ✅ **Done** — 21 tests green | `81275a9d4` |
| WP3-spike | Inbound ring + ChannelTable (`src/remote/inbound_ring.zig`) | ✅ **Spike done, gate passed** — 6 tests green | `7210e230e` |
| WP2-spike | Windows agent risks (`src/remote/agent/spike/`) | ✅ **Spike done** — cross-compiles x86_64+aarch64 windows | `7168891fb` |
| WP3-full | Client connection + `termio.Remote` + C API | ⛔ **Not started** (next on critical path) | — |
| WP2-full | Agent daemon (Linux + Windows) | ⛔ **Not started** | — |
| WP4 | Swift connection context (`+connect` etc.) | ⛔ Blocked on WP3-full C API | — |
| WP5 | Manifest + resumability | ⛔ Not started (P2) | — |
| WP6 | Tunneling | ⛔ Not started (P2) | — |
| WP7 | Connection Manager UI | ⛔ Not started (P3) | — |
| WP8 | Process mgmt + RPC | ⛔ Not started (P2) | — |
| WP9 | Ports + Activity UI | ⛔ Not started (P3) | — |
| WP10 | Skill, docs, CI, Windows harness, e2e | ⛔ Not started (P3) | — |

**Phase (§16):** P1 (core remote panes) in progress. WP1 + the two gating spikes
are complete; the full WP2/WP3 and then WP4 remain to finish P1.

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

## Recommended next actions (in order)

1. **WP3-full** — `src/remote/connection.zig` (ssh spawn with `SSH_ASKPASS`
   interactive-auth + first-contact host-key flow §4.1; two SSH channels; MPSC
   writer; demux reader feeding the WP3 inbound rings; heartbeat/RTT; reconnect
   state machine; steal w/ epoch fence) + `src/termio/Remote.zig`; extend
   `src/termio/backend.zig` (add the `remote` arm to all 3 unions + 11 switches);
   **plumb the new `ghostty_surface_config_s` fields and branch
   `src/Surface.zig:682` (backend construction) + `:1340` (childExitedAbnormally)**;
   expose the `ghostty_remote_*` C API. Headless test over `ssh localhost`.
   *Do the `Surface.zig:682` change carefully — the design calls it the
   highest-mechanical-risk, load-bearing edit (§3.2).*
2. **WP2-full** — `src/remote/agent/` → `ghoztty-agent`. Prep: the
   `Command.zig`→`CommandCore` extraction (assessment in FINDINGS.md: ~2–4 h, 3
   thin couplings). Then daemonize, session table w/ grid model + ring +
   tombstones, OPEN/ATTACH/DATA/RESIZE/SIGNAL/DETACH/CLOSE/EXIT/META, containment
   groups. Reuse `win32.zig` from the spike (fold into `src/os/windows.zig` `exp`).
3. **WP4** — Swift connection context once WP3-full's C API exists.

WP3-full and WP2-full can proceed in parallel (separate worktrees) since they only
share the WP1 wire contract, which is frozen. WP4 waits on WP3-full's C API.

## Build & test in THIS environment (important quirk)

There is **no system `zig`**. A zig 0.15.2 toolchain was used from another
session's scratchpad. The bigger gotcha: **zig 0.15.2 cannot link the native
macOS-26 SDK** (even hello-world fails with undefined libSystem symbols). Work
around it by down-targeting:

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
