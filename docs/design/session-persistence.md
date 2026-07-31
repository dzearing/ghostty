# Session Persistence

> Status: **implemented** (local single-machine persistence shipped on
> `users/dzearing/session-persistence`, 2026-07-16). AC1/AC2 (upgrade + crash
> survival), AC3/AC4 (reboot & agent-crash relaunch floor, both app-relaunch
> and in-place), and AC7 (CLI parity) are built and E2E-verified — see §2
> *Measured results*. AC5 (latency micro-benchmark) is not yet measured; AC6
> (cross-machine session move) is scoped but not built (tasks T16–T18). The
> opt-in `session-persistence` config flag defaults `off`.
>
> Deliverable of the 2026-07-13 design task: terminal processes must survive
> Ghoztty app updates and crashes, recover as much as possible across reboots,
> and any machine's Ghoztty UX must be able to attach to, detach from, and
> *move* a terminal between machines.

## 1. Goal

The user runs many Ghoztty windows, each hosting a long-running process (dev
servers, Claude Code sessions). Today a Sparkle update, an app crash, or a
reboot kills every window and every child process. This design makes the
terminal *processes* independent of the *viewer* (the GUI app):

1. **App update (Sparkle relaunch)** — every child process keeps running
   (same PID); every window re-attaches afterward with correct layout, split
   ratios, sizes, titles, and scrollback.
2. **App crash** — same as update: next launch re-attaches to the still-running
   processes.
3. **Reboot / OS crash / agent crash** — no design can keep a local process
   alive across a reboot; the honest contract is **"session state restores,
   process relaunches."** Layout, cwd, command, and title come back; the
   process is restarted and visibly marked as such; scrollback restores up to
   the last persisted snapshot (best-effort).
4. **Portability** — a process runs in exactly one place. Any machine's
   Ghoztty can list the terminals running on any enrolled machine (local or
   remote), attach to one, detach, and re-attach from somewhere else —
   "moving" a window between machines. Single viewer at a time is sufficient.

Non-goals (v1): simultaneous multi-viewer attach; process survival across
reboot (impossible); collaborative sharing; predictive local echo.

## 2. Acceptance criteria

"Works extremely well" made concrete. These become the exit tests of the
phases in §8.

| # | Scenario | Criteria |
|---|---|---|
| AC1 | Sparkle update with 10 windows / 25 panes running `sleep`-style markers + a TUI (vim) + a scrolling logger | After relaunch: **all 25 child PIDs unchanged**; all windows re-created with identical split topology and ratios (±1%), window/tab titles (incl. user-set titles), working directories; scrollback present up to the retention limit; total interruption (quit → all panes interactive) **< 10 s**; zero bytes of output produced *during* the gap lost (replayed on attach). |
| AC2 | `kill -9` the GUI app with the same layout | Next launch: same result as AC1. Processes never received SIGHUP. |
| AC3 | Reboot with 10 windows | After login + app launch: all windows restored with layout/titles/cwds; each pane **relaunched** with its original command and cwd and visibly marked "restarted after reboot"; scrollback restored from the last on-disk snapshot (best-effort, may trail by ≤ 30 s of output). |
| AC4 | Agent crash (`kill -9 ghoztty-agent`) | Children die (POSIX PTY semantics — documented, not hidden). Agent restarts via launchd ≤ 5 s; sessions relaunch from persisted metadata as in AC3. Covered both ways: **app relaunched** (reboot-equivalent, T12d) *and* **app stays up** (in-place, T12e) — the live app detects the dropped shared connection, re-dials the restarted agent, and rebuilds each open window's full split topology in place with the `--- session restarted ---` banner (the local machine pill stays hidden). |
| AC5 | Latency / throughput | Added keypress→echo latency of the agent hop vs today's in-process PTY: **p50 < 1 ms** measured end-to-end. `cat` of a 100 MB file into a pane: wall time within **25%** of a direct local PTY. No visible degradation at 120 Hz scrolling. |
| AC6 | Move window between machines | From Mac B: chooser lists Mac A's sessions ≤ 2 s; attach steals the session ≤ 3 s with full ring replay; Mac A's viewer (if open) shows "attached elsewhere" and offers re-steal. Round-trip A→B→A preserves the process. |
| AC7 | CLI parity | `+list` shows agent-backed panes with correct pid/tty/cwd; `+send-keys`/`+read`/`+set-banner`/`+set-state` work unchanged on persistent panes. |

### Measured results (E2E, `scripts/e2e/session-persistence.py`)

Scenario used: 2 windows / 5 panes, nested topology with distinct ratios
(Window A `P0 | (P1/P2)` ratios 0.30/0.70; Window B `P3 | P4` ratio 0.40), each
pane running a never-exiting `PANE=n PID=$$` + tick marker. 3 consecutive cycles
per mode, 0 s relaunch gap. Debug build on macOS 26.4.

| AC | Mode | Result | Recovery gap | Notes |
|----|------|--------|-------------|-------|
| AC2 | `kill -9`, relaunch same binary (T07) | ✅ 3/3 | ~6–8 s | all 5 PIDs unchanged & alive; ticks monotonic across gap; topology exact (±0.01); pre-gap scrollback replayed; agent PID unchanged |
| AC1 | `kill -9` + **bundle swapped on disk**, relaunch (T08) | ✅ 3/3 | ~8 s | as above; main-exec inode replaced each cycle (proof of on-disk swap); agent PID unchanged across the swap |
| AC1 | **graceful quit** + bundle swap, relaunch (T08) | ✅ 3/3 | ~3 s | as above; `isQuitting` manifest path exercised. (An earlier ~45 s "graceful-quit hang" reported against T08 was a **misdiagnosis** — a test-harness zombie-reaping artifact, not an app hang; there is no graceful-quit regression. Fixed harness-side in T08a.) |
| AC3 / AC4 | **reboot-equivalent**: `kill -9` app **and** agent; launchd restarts the agent; relaunch app (T12d, `--agent-restart`) | ✅ 3/3 | ~1.9–3.9 s | launchd (`RunAtLoad`+`KeepAlive`) restarts the agent in **≤ 2 s** (0.0–2.0 s measured); the new agent materializes sessions from `sessions.json` as relaunchable tombstones; app relaunch re-attaches → auto-RELAUNCH spawns each pane fresh (**new child PID, marker re-ran, `--- session restarted ---` banner**); topology rebuilt from the manifest. Honest contract: children die + ring RAM is lost (POSIX), so scrollback restarts — no pre-kill replay until the ring disk snapshot (T13). |
| AC4 (in-place) | **agent crash, app stays up**: `kill -9` agent ONLY (T12e, `--agent-only`) | ✅ 2/2 | ~2.5–3.7 s | the **app process is never relaunched** (asserted); launchd restarts the agent (≤ 2 s), the live app detects the dropped shared connection, re-dials, and rebuilds each open window in place → auto-RELAUNCH (**new child PID, marker re-ran, restart banner**); topology rebuilt from the manifest; local machine pill never shown. Same honest contract as AC3/AC4 (children + ring RAM lost). |

The `--agent-restart` cycle settles each live agent past launchd's 10 s respawn
`ThrottleInterval` before killing it, so the measured restart is the real
single-crash latency of a long-lived agent, not a throttle artifact of rapid
E2E cycling. The debug lineage installs a distinct LaunchAgent label
(`com.dzearing.ghoztty.debug.agent`) so it never collides with the release job;
the harness boots it out on reset so no KeepAlive job lingers after a run.

The swapped bundle is byte-identical (ad-hoc signing binds keychain auth to the
exact code hash; a recompiled binary would prompt on every launch). This is
immaterial to the AC — the restore path reads the layout manifest + surviving
agent, never app-bundle bytes; the full FS-swap → relaunch → re-attach path is
exercised. See `scripts/e2e/README.md`.

## 3. What exists today (inventory)

The fork already contains ~80% of the machinery, built for remote machines.
Everything below was verified in code on branch `users/dzearing/session-persistence`.

### 3.1 `ghoztty-agent` — a session daemon that already outlives viewers

`src/remote/` is ~27.6k lines of Zig; the agent core (`src/remote/agent/`)
~13.3k. The parts that matter here:

- **One daemon owns many PTY sessions.** `SessionStore`/`SessionTable`
  (`src/remote/agent/session.zig:611`, `:438`) maps crypto-random 128-bit
  session ids → live PTY children (`pty_child.zig`, POSIX PTY + Windows
  ConPTY behind one vtable). Max 64 sessions/daemon (`session.zig:49`).
- **Detach ≠ terminate.** Client disconnect only unbinds the session
  (`server.zig:393` `detachAll`); the child keeps running and its output keeps
  flowing into a per-session **2 MB byte ring** (`session.zig:176`,
  `default_ring_bytes` at `:54`).
- **Re-attach replays the gap byte-exactly.** `ATTACH{session_id,
  last_byte_offset}` → the agent replays the ring range the client missed
  (`server.zig:784-816`), with a visible `[ghoztty: N bytes of scrollback
  lost]` marker if the ring overran.
- **24 h idle TTL** enforced by a reaper thread (`session.zig:681-724`);
  attached or output-producing sessions never expire.
- **Transports:** `--stdio` (SSH), `--listen` (TCP, loopback-only unless
  overridden, unauthenticated), `--relay` (authenticated WSS to the Azure
  relay). All feed one versioned, muxed frame protocol
  (`src/remote/protocol.zig`, `proto_version = 1`, HELLO-negotiated).
- **Single-instance guard** (flock + heartbeat + takeover,
  `single_instance.zig`), **self-update** (idle-gated binary swap,
  `self_update.zig`), cross-platform POSIX/Windows.

**Gaps (each becomes a work item in §7):** no session enumeration on the wire
(no LIST frame — a client can only attach to an id it already knows); the
`META` frame + `Session.title/cwd/state` fields exist but are never populated;
**nothing is persisted to disk** — an agent restart loses everything; no
Unix-socket/named-pipe transport; no daemonization (launchd/systemd) — external
supervision is assumed.

### 3.2 The macOS app already renders "a terminal whose PTY lives elsewhere"

- **Emulation and GPU rendering are local for remote surfaces.** A remote
  surface is a normal libghostty `CoreSurface` whose termio backend is
  `.remote` instead of `.exec` (`src/apprt/embedded.zig:1460`
  `remoteBackend()`; `src/termio/Remote.zig`). Only raw PTY bytes cross the
  wire; VT parsing, the grid, scrollback, and Metal rendering all happen in
  the app (`Remote.zig:543` `drainRing()` → `termio.Termio.processOutput`,
  "the same call Exec's ReadThread makes"). **Local render fidelity and GPU
  acceleration are unaffected by where the PTY lives.**
- **Loopback already works.** `ghostty_remote_connection_new_tcp` dials
  localhost; `Machine.isLocalMachine`/`isLoopback`
  (`macos/Sources/Features/Remote/Machine.swift:85-112`) already suppress
  remote-only UI for this-Mac connections. Loopback agents are the standing
  test rig (freeze/thaw reconnect tests were run against them).
- **Reconnect machinery is production-hardened:** per-window state machine
  with backoff ladder, dial+probe, NWPathMonitor and wake kicks, poisoned-
  session circuit breaker, forever background re-dial
  (`BaseTerminalController.swift:1861-2517`), pill UI (`MachinePillView.swift`).
- **`RemoteSessionManifest` already round-trips windows across Sparkle
  relaunch and quit** (`RemoteSessionManifest.swift`): UserDefaults JSON of
  `{relayBase, deviceID, sessionID, name, windowTitle, namePinned, ipcName}`,
  preserved on quit (`AppDelegate.isQuitting`), replayed by
  `restoreRemoteWindows()` at launch — re-ATTACH by session UUID, **process
  not restarted, replayed scrollback included**. This is the exact shape of
  the update-survival story, already shipping for relay windows. Crucially the
  Sparkle quit path (`applicationShouldTerminate` +
  `UpdateDelegate.willInstallUpdateOnQuit`) already flows through the
  manifest-preserving branch.
- **A second, separate restoration system** exists for local windows: AppKit
  `NSWindowRestoration` (`TerminalRestorable.swift`, config
  `window-save-state`) serializes the `SplitTree` (Codable, versioned) with
  per-pane `{pwd, uuid, title}` — but **not the command**, and it re-spawns
  shells rather than re-attaching.

### 3.3 IPC + layout model

- `+list --json` already emits the full window/tab/split tree with per-split
  `direction` + `ratio`, per-leaf title/cwd/pid/tty/name
  (`IPCServer.swift:1406-1560`).
- `SplitTree<SurfaceView>` is fully `Codable` (`SplitTree.swift:371-413`).
- `+rearrange --layout=<JSON>` can impose an exact tree shape + ratios on
  existing panes; `+new-window`/`+split` create panes with cwd/command/env.
- Local PTYs: the **GUI app process owns the PTY master fd**
  (`src/termio/Exec.zig:904-1105`); app death ⇒ master closes ⇒ SIGHUP kills
  the children. No fd passing (`SCM_RIGHTS`) or launchd socket activation
  exists anywhere in the tree.

### 3.4 Relay

The relay (`relay/`, Go + SQLite) already models **account → devices**: stable
device UUIDs, display names, hostnames, hashed credentials, `ListByOwner*`,
and live online state (`relay/store.go`, `directory.go`). "Which machines
exist for this account, which are online, how to dial them" is solved.

## 4. Approaches evaluated

### 4.1 Approach 1 — Local agent as PTY host (generalize `ghoztty-agent`)

Run `ghoztty-agent` on localhost as a per-user daemon. Local windows opt into
persistence by becoming `.remote` surfaces attached to the local agent —
exactly what remote windows are today, minus the network.

- **Update/crash:** the app is a stateless viewer. Sparkle relaunch or
  `kill -9` does not touch the agent or its children. Re-attach by session id
  replays the ring. This is *shipping behavior* for relay windows today
  (§3.2); the work is extending it to local windows.
- **Reboot:** the agent persists per-session metadata (argv, cwd, title, env
  subset) to disk; launchd (`RunAtLoad` + `KeepAlive`) restarts the agent at
  login; sessions come back as "dead — relaunchable" and are restarted with
  their original command/cwd on attach, visibly marked. Approach 4 semantics,
  but owned by the same component, so one code path.
- **Portability:** falls out. A local session and a remote session are the
  same object; the Mac is already enrollable as a relay device. Moving a
  window = ATTACH from elsewhere (the protocol already has
  `attached_elsewhere` + `force` steal semantics, `protocol.zig:429,447`).
- **Performance:** emulation and rendering stay in-app (§3.2). The added cost
  per byte is one local socket traversal plus a demux-thread → per-pane-ring →
  async-wake handoff that the remote path already implements. Measured on
  this machine (macOS 26.4, Python echo benchmark — a conservative ceiling;
  the Zig path will be faster): loopback TCP RTT **p50 15 µs / p99 57 µs**,
  Unix socket RTT **p50 7.6 µs / p99 12 µs**; one-way streaming
  **1.6–17.9 GB/s**. That is ~500–1000× below a 120 Hz frame budget
  (8.3 ms) per keystroke round-trip, and ~3 orders of magnitude more
  bandwidth than the fastest terminal output bursts. The in-app hop already
  exists for relay windows and is imperceptible on a ~30 ms WAN link;
  loopback removes the only meaningful term. AC5 verifies end-to-end anyway.
- **Complexity:** the agent core is well-factored (~5.8k lines relevant);
  every gap in §3.1 is an additive frame or module. The genuinely new
  problems: agent updates while sessions are live (§6.6), and the daemon
  becoming a dependency of every persistent terminal (§6.7).

### 4.2 Approach 2 — tmux/screen as the persistence layer

Wrap sessions in tmux, integrate via control mode (iTerm2-style).

- **Pros:** battle-tested process survival for free; no daemon to write.
- **Cons, honestly fatal for this fork:**
  - Control-mode integration is an enormous *ongoing* surface (iTerm2's is
    years of maintenance): layout mapping tmux-tree ↔ `SplitTree`, scrollback
    paging through tmux's own buffer model, escape-sequence translation, tmux
    version skew.
  - **Fidelity:** tmux owns scrollback with its own limits and re-renders
    through its own terminal model — Ghoztty's grid/scrollback (Kitty
    graphics, OSC extensions like 7777/7778 banners/state) would be filtered
    through tmux's passthrough rules. The fork's own OSC features would need
    tmux-passthrough shims.
  - **Windows:** no tmux. The fork has a live Windows port effort and a
    cross-platform agent; tmux forks the persistence story per-OS.
  - **Portability/move:** requires tmux on every remote + a second remoting
    mechanism competing with the existing agent/relay stack.
  - Duplicates what §3.1 shows is already ~built: `ghoztty-agent` *is* a
    detach-surviving session daemon with byte replay, minus a LIST frame.
- **Verdict: rejected.** The fork already owns a better-fitting daemon;
  adopting tmux adds a foreign dependency without covering reboot or Windows.

### 4.3 Approach 3 — PTY fd handoff to the successor app (no daemon)

Pass PTY master fds from the dying app instance to the new one
(`SCM_RIGHTS` over the IPC socket, or launchd fd stashing).

- Solves **update only**: there is no successor process during a crash, and
  nothing survives reboot. Two of the three scenarios remain unsolved.
- Sparkle's relaunch has **no overlap window** where old and new instances
  run concurrently — the old app quits before the new one launches
  (`Autoupdate` replaces the bundle in between). fds would have to be parked
  in a third process that outlives both… which is a daemon, i.e. approach 1
  with extra steps. (launchd can hold *listening sockets* for activation, but
  not arbitrary stashed PTY fds for a future process.)
- The scrollback/grid state lives in the app's memory, so a handoff also
  needs full terminal-state serialization — the hardest part of approach 4 —
  on top of fd gymnastics inside the GUI (fork-unsafe AppKit territory).
- **Verdict: rejected** as a primary. The one place fd-preservation *is*
  attractive is inside the headless agent for its own self-update (§6.6),
  where a single-threaded exec-in-place is tractable.

### 4.4 Approach 4 — Session serialization + relaunch only

Extend `TerminalRestorable`/manifest to persist layout + cwd + command (+
optionally scrollback text) and restart everything on launch.

- Simple, no daemon; upstream Ghostty discusses this as "window restoration".
- **Fails the hard requirement:** processes are killed on every update. A
  restarted `npm run dev` is not the same as one that never died; a restarted
  Claude Code session loses its in-memory context.
- **Verdict: not sufficient alone — but it is the required *fallback layer***
  for reboot, agent crash, and TTL-reaped sessions. Approach 1 subsumes it by
  putting the serialized metadata in the agent + an app-side layout manifest.

### 4.5 Approach 5 (recommended) — Hybrid: local agent + serialized manifest

Approach 1 for process survival (update/crash, and cross-machine attach), with
approach 4's serialization as the recovery floor (reboot, agent death), both
hanging off components that already exist (`ghoztty-agent`,
`RemoteSessionManifest`, `SplitTree` Codable). Detailed in §5.

### 4.6 Comparison

| Criterion | 1 Local agent | 2 tmux | 3 fd handoff | 4 serialize+relaunch | **5 hybrid (1+4)** |
|---|---|---|---|---|---|
| Survives app update | ✅ process alive | ✅ process alive | ✅ (fragile) | ❌ restarted | ✅ process alive |
| Survives app crash | ✅ | ✅ | ❌ | ❌ restarted | ✅ |
| Reboot recovery | ⚠️ metadata only | ❌ (tmux dies too) | ❌ | ✅ (its whole point) | ✅ relaunch + layout + snapshot |
| Layout/ratio/title fidelity | ✅ app-side manifest | ⚠️ tmux-tree mapping | ✅ | ✅ | ✅ |
| Scrollback fidelity | ✅ ring replay (configurable depth) | ⚠️ tmux buffer model | ⚠️ needs state serialization | ⚠️ text snapshot only | ✅ ring + disk snapshot |
| Remote parity / window move | ✅ same mechanism | ❌ second mechanism | ❌ | ❌ | ✅ |
| Windows story | ✅ agent is x-plat | ❌ | ❌ | ⚠️ | ✅ |
| Sparkle ergonomics | ✅ already flows through manifest path | ⚠️ | ⚠️ needs overlap hack | ✅ | ✅ |
| Local render latency | ✅ imperceptible (measured, §4.1) | ⚠️ extra emulation layer | ✅ | ✅ | ✅ |
| New complexity in fork | ⚠️ moderate, additive | 🔴 large, foreign | 🔴 high, narrow payoff | 🟡 low | ⚠️ moderate |
| Single point of failure | agent daemon (small, stable) | tmux server | — | — | agent daemon, with §4.4 as floor |

## 5. Recommended architecture

**One sentence:** every persistent terminal is a `ghoztty-agent` session —
the local agent is just the nearest agent — and the app keeps a durable
manifest of *layout + session ids* so any viewer can rebuild its windows and
re-attach; the agent keeps durable *session metadata* so even it can rebuild
processes after a reboot.

```
                    ┌────────────────────────────── viewer (Ghoztty.app) ──┐
                    │  SplitTree + grid + scrollback + Metal renderer      │
                    │  SessionLayoutManifest v2 (layout + session ids)     │
                    └───────┬───────────────────────────────┬──────────────┘
              unix socket / │ loopback                      │ relay WSS / TCP
                    ┌───────▼────────────┐          ┌───────▼────────────┐
                    │ ghoztty-agent      │          │ ghoztty-agent      │
                    │ (this Mac, launchd)│          │ (other machine)    │
                    │ SessionStore + ring│          │ SessionStore + ring│
                    │ sessions.json ─────┼─ disk    │ sessions.json      │
                    └───────┬────────────┘          └───────┬────────────┘
                        PTY children                    PTY children
```

### 5.1 Ownership of state

| State | Owner | Persisted where | Restored how |
|---|---|---|---|
| Child process + PTY | agent | — (kernel) | survives viewer death; relaunched after reboot |
| Output ring (recent bytes) | agent | RAM; snapshot to disk on shutdown + periodic (§5.4) | replayed on ATTACH |
| Session metadata (argv, cwd, title, env subset, created-at) | agent | `~/.config/ghoztty/sessions.json` (atomic tmp+rename) | agent relaunch offers "dead — relaunchable" |
| Window/tab/split layout, ratios, user titles, IPC names, session ids | viewer | `SessionLayoutManifest` v2 (UserDefaults or JSON file) | replayed at app launch → windows rebuilt → ATTACH per leaf |
| Grid/scrollback (parsed) | viewer | not persisted (derived) | re-derived from ring replay |
| Which machines exist / are online | relay | SQLite | machine chooser + LIST |

### 5.2 The local agent

- **Transport:** new Unix-domain-socket listener
  (`~/.config/ghoztty/agent.sock`, mode 0600, `LOCAL_PEERCRED` uid check) —
  `socket_stream.zig` is the template; all transports already share one
  `Stream` vtable. Loopback TCP (`--listen`) stays as the dev/test path but is
  **not** the default: a 127.0.0.1 port is connectable by any local user,
  a 0600 unix socket is not. (Windows later: named pipe with per-user ACL,
  matching the fork's Windows effort.)
- **Lifecycle:** installed as a per-user LaunchAgent
  `com.dzearing.ghoztty.agent` (`RunAtLoad` + `KeepAlive`; the app writes the
  plist on first use, same pattern as the Sparkle helper). The app also
  spawns it on-demand if the socket is dead (dial → fail → spawn → retry),
  so persistence works even before login-item approval. Single-instance
  guard already handles the race.
- **New protocol surface** (additive, HELLO-versioned):
  - `LIST_SESSIONS` / `SESSIONS` — enumerate `{id, state(alive|dead),
    title, cwd, argv, attached, created_at, exit_code?}`. The store is
    already internally enumerable (the Windows tray does it).
  - `META` actually populated: agent-side OSC 0/2 (title) + OSC 7 (cwd)
    *sniffing* is *not* needed — titles/cwd parse client-side today; instead
    the client reports title/cwd back via a small `SET_META` so a headless
    session still lists usefully, and `queryCwd` (already implemented per-OS)
    fills cwd on demand.
  - `RELAUNCH{session_id}` — restart a dead session from persisted metadata,
    returning a fresh attachable session that inherits the old id's manifest
    slot.
- **Policy changes for local persistence:**
  - TTL: sessions referenced by a viewer manifest are **pinned** (no 24 h
    reap); pin is an ATTACH-time flag persisted in session metadata. Unpinned
    (ad-hoc remote) sessions keep today's TTL.
  - Session cap raised from 64 → 256 (user runs many windows); ring memory
    capped globally (e.g. 512 MB budget) with per-session degradation.
  - Ring size configurable (`persistent-scrollback-bytes`, default 16 MB per
    session): at libghostty parse throughput (>100 MB/s) a full 16 MB replay
    costs <200 ms on attach, satisfying AC1's 10 s budget with room to spare.

### 5.3 The viewer

- **Config:** `session-persistence = off | on` (per-window override via
  `+new-window --persist=...`). When on, local window creation routes through
  `remoteBackend()` with a connection to the local agent instead of `.exec`.
  `Machine.isLocalMachine` already suppresses the remote pill; extend it to
  show reconnect states only when something is actually wrong.
- **Manifest v2** (`SessionLayoutManifest`, superseding
  `RemoteSessionManifest` and coexisting with AppKit restoration): per window
  `{machineRef (local|deviceID|host:port), tabColor, frame, titleOverride,
  ipcName, layout: SplitTreeCodable, leaves: [{sessionID, title, ipcName}]}`.
  `SplitTree` is already Codable; the delta is recording a session id per
  leaf instead of respawn config. Same mark-don't-drain crash safety and
  `isQuitting` preservation semantics as today.
- **Restore at launch:** for each manifest window → dial machine → for the
  root leaf reuse the existing `presentRemoteWindow(sessionID:)` path; for
  additional leaves, rebuild the tree (`SplitTree` node-by-node, each leaf a
  `.remote` surface with its `sessionID`) — a native, exact-ratio version of
  what `+split` + `+rearrange --layout` can already approximate over IPC.
  Dead sessions render with a "process exited / restarted after reboot"
  banner (the sticky-banner feature is a natural fit) and follow
  `session-relaunch = notify | auto | prompt`.

  **The default is `notify` (T230, 2026-07-31), and it does NOT respawn.**
  A recorded command is never re-executed on the user's behalf: it was
  captured in a world that no longer exists, it may be a build, a migration
  or an agent loop that must not run twice, and it was never asked for a
  second time. Under `notify` the pane comes up on a fresh shell in the
  recorded working directory, with a notice naming the old command so it can
  be copied and re-issued deliberately (`src/termio/session_notice.zig`,
  emitted both as terminal text and as an OSC-7778 sticky banner, because a
  ConPTY shell's startup repaint erases the former). `auto` keeps the old
  `RELAUNCH`-with-divider behavior, `prompt` waits for a keystroke; both are
  opt-ins now.

  A recorded working directory that no longer EXISTS falls back to the user's
  home rather than failing the spawn (`PtySpawner.resolveSpawnCwd`) — a
  deleted worktree used to leave every restored pane dead.
- **Sparkle:** no new hook strictly needed — the update path already sets
  `isQuitting` and preserves the manifest (§3.2). Add belt-and-braces: on
  `willInstallUpdateOnQuit`, flush the manifest and send explicit `DETACH`s
  so the agent marks a clean checkpoint (and snapshots rings to disk).

### 5.4 Scrollback strategy (fidelity, honestly)

- **Update/crash:** the viewer's parsed scrollback dies with the viewer; the
  restored window's scrollback is the ring replayed from byte 0 — i.e. the
  last `persistent-scrollback-bytes` of raw output, byte-exact, including
  colors/attributes since it re-parses the original bytes. Beyond the ring, a
  visible truncation marker (already implemented). 16 MB ≈ tens of thousands
  of lines — in practice "full scrollback" for the AC1 workloads; genuinely
  unbounded history is out of scope v1 (future: ring spill-to-disk).
- **Reboot:** the agent snapshots each ring to disk on graceful shutdown
  (SIGTERM from launchd at logout/shutdown) and every 30 s (dirty sessions
  only, atomic writes). After reboot the relaunched pane replays the snapshot
  *then* a `--- session restarted after reboot ---` divider, then live
  output. Best-effort by design (kernel panic loses ≤ 30 s of tail).
- **Alternate-screen apps** (vim, htop): byte replay re-enters the alternate
  screen naturally; a post-attach `RESIZE` (rows±0 trick or SIGWINCH) nudges
  TUIs to repaint — same trick the reconnect path uses today.
- **Future upgrade (not v1):** a true grid snapshot frame
  (`snapshot_at_offset` is an acknowledged stub, `session.zig:27-31`) for
  instant attach without replay cost and eviction-invisible scrollback.

### 5.5 Portability / moving windows

- The Mac enrolls as a relay device (already supported; this Mac has a device
  id). The machine chooser gains a per-machine session list: dial → 
  `LIST_SESSIONS` → "Terminals on MaximusHome (3)" with title/cwd/liveness.
- **Move = re-attach elsewhere.** ATTACH from machine B with `force` steals
  the single-viewer slot; the protocol's `attached_elsewhere` already models
  this. The losing viewer (if alive) gets a `DETACHED{reason=stolen}` frame
  and shows a placeholder pane: "Attached on Mac B — [Take back]". Its
  manifest entry stays, so "take back" is one click and reboot-restore on A
  doesn't resurrect a window B now owns without saying so (it restores as the
  placeholder).
- Local→remote viewing needs the *local* agent reachable from B: that is the
  relay path (Mac agent runs `--relay` in addition to the unix socket — one
  daemon, two listeners; multi-transport is already how `--listen`+relay
  coexist structurally).

### 5.6 CLI surface (automation parity)

- `ghoztty +sessions [--machine=<name>] [--json]` — LIST_SESSIONS.
- `ghoztty +attach --session=<id> [--window=<name>]` — attach/steal into a
  new or existing window.
- `+new-window --persist=on|off`, `+list` gains `session_id` +
  `persistent: true` per leaf.
- `+detach --target=<name>` — detach a window (leave processes running,
  drop the manifest entry ⇒ intentional "background this").

## 6. Risks, costs, and honest failure modes

1. **The agent becomes a single point of failure.** Agent crash = SIGHUP to
   every persistent child (PTY master closes; on Windows the job object kills
   by design). Mitigations: the agent is small (~13 kLOC), headless, changes
   rarely, and already soak-tested by relay dogfooding; launchd `KeepAlive`
   restarts it; §5.4 snapshots + §5.1 metadata make the recovery floor equal
   to approach 4 (relaunch with layout + scrollback tail), not zero. This is
   a strict improvement over today, where the SPOF is the huge, weekly-
   changing GUI app.
2. **Agent updates vs live sessions.** Today's self-update is idle-gated and
   would never fire once sessions are long-lived. v1 policy: the local agent
   does **not** self-update; it's versioned with the app bundle, and the app
   only bumps it when the protocol version changes (HELLO negotiation keeps
   old-agent/new-app pairs working — additive frames only). The real fix,
   phase 5: **exec-in-place fd preservation** — serialize the session table,
   clear `FD_CLOEXEC` on PTY masters, `execve` the new binary with
   `--resume-state`; children never notice. Tractable precisely because the
   agent is a small single-purpose process (unlike approach 3's GUI variant).
3. **Latency regression risk on huge output bursts.** The per-wake drain cap
   (32 chunks, `Remote.zig:558-577`) and flow control were tuned for WAN;
   loopback can deliver much faster. AC5's `cat 100MB` test gates this;
   knobs exist (chunk size, cap) if needed.
4. **Environment semantics change.** Children of a LaunchAgent daemon don't
   inherit the GUI app's environment (e.g. env vars from a shell that
   launched Ghoztty). Shells still get full login-shell treatment (`-lic`
   convention already implemented per-shell). Documented behavior change
   gated behind the config flag.
5. **Two restoration systems during migration.** AppKit `TerminalRestorable`
   (non-persistent windows) and Manifest v2 (persistent ones) coexist;
   a window is in exactly one system, keyed off its backend kind — same
   pattern as today's local/remote split, but it's real complexity.
6. **Debug ergonomics.** Every persistent terminal now involves two
   processes. Investment required: `ghoztty +agent-status`, agent log at
   `~/.config/ghoztty/agent.log` (exists), and the debug app using a separate
   agent socket + LaunchAgent label (`…debug`), mirroring the existing
   debug-socket separation.
7. **Memory.** 256 sessions × 16 MB ring worst-case = 4 GB — hence the global
   ring budget with per-session degradation (§5.2), and rings only allocate
   as they fill.

## 7. Gaps to build (delta list)

Agent (`src/remote/agent/`): unix-socket transport; LIST_SESSIONS/SET_META/
RELAUNCH frames; pinned-session TTL policy; session metadata persistence
(sessions.json); ring disk snapshot + restore; launchd plist install/health;
session cap + ring budget; (phase 5) exec-in-place resume.

Viewer (macos/): `session-persistence` config; local-machine connection
bootstrap (spawn-on-demand); Manifest v2 with SplitTree layout + per-leaf
session ids; multi-leaf restore path; dead-session banner + relaunch UX;
stolen-session placeholder; chooser session lists; pill behavior for local
agent.

CLI (`src/cli/`): `+sessions`, `+attach`, `+detach`, `--persist`, `+list`
additions.

Relay: none required for v1 (device model suffices); later maybe session-count
in device list.

## 8. Phased plan

Each phase is independently shippable and useful.

> **Status (2026-07-16):** Phases 1–3 are **complete and E2E-verified**
> (Phase 1 groundwork: T09/T09b/T09c UDS + peercred, T10 `+sessions`, T11
> pinning/caps, T12d launchd; Phase 2 headline: T04/T05/T06/T07/T08; Phase 3
> reboot floor: T12/T12b/T12c/T12e relaunch + T13/T13b ring snapshots). Phase 0
> was folded into the T04–T08 build (AC5's latency micro-benchmark was **not**
> separately measured — the loopback path proved fast enough in practice but
> has no recorded p50). **Phase 4 (cross-machine move, AC6) is not built** —
> tracked as T16–T18. Phase 5 is future work.

- **Phase 0 — Spike & gate (≈1 day).** Wire a debug-app local window through
  a loopback `--listen` agent by hand (no new code beyond a config hack).
  Measure AC5 end-to-end: keypress→echo latency (local `.exec` vs loopback
  `.remote`), `cat 100MB`, 120 Hz scroll. Kill the app, relaunch, re-attach
  by session id (manifest already does this for relay windows — point it at
  loopback). **Gate: AC5 numbers hold.** Transport-level RTT already
  measured (§4.1); this validates the full path.
- **Phase 1 — Agent groundwork.** Unix-socket transport + peercred; LIST/
  SET_META/RELAUNCH; pinning; caps/budgets; launchd packaging;
  `+sessions`/`+attach` CLI against it. Exit: AC7 pieces for enumeration;
  agent survives `launchctl kickstart -k` with sessions relaunching from
  metadata.
- **Phase 2 — Persistent local windows (the headline).** Config flag; local
  windows dial the local agent; Manifest v2 with layout + session ids;
  multi-leaf restore. Exit: **AC1 (Sparkle update) and AC2 (kill -9) pass
  with 10 windows / 25 panes.**
- **Phase 3 — Reboot recovery.** sessions.json relaunch flow; ring disk
  snapshots; restart banners; `session-relaunch` policy. Exit: **AC3, AC4.**
- **Phase 4 — Cross-machine attach & move.** Chooser session lists; steal +
  placeholder + take-back; local agent optionally on the relay. Exit: **AC6.**
- **Phase 5 — Fidelity & polish.** Agent exec-in-place update; grid
  snapshots; ring spill-to-disk (unbounded scrollback); Windows named-pipe
  local persistence aligned with the Windows port.

## 9. Open questions (for the user)

1. Default-on or opt-in? Recommendation: opt-in (`session-persistence = on`)
   for a release, then default-on once AC1–AC4 soak.
2. Scrollback retention default: 16 MB/session ring OK, or is disk-spill
   (unbounded) wanted sooner than phase 5?
3. Reboot relaunch policy default: auto-relaunch every command, or prompt
   per pane? (Auto matches "dev servers just come back"; prompt is safer for
   destructive commands.)
4. Should *non*-persistent local windows keep existing AppKit restoration, or
   is Manifest v2 worth unifying on eventually?
