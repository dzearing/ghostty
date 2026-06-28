# Remote Machine Activity Monitor — design / plan

> Status: **IN PROGRESS.** Branch base: `feature/remote-machines`.
>
> **Increment 1 ✅ DONE** (`eb292348b`): metrics/proc opcode block `0x70–0x78` +
> JSON payload structs in `protocol.zig` (NOTE: the table below's suggested `0x30+`
> COLLIDES with the existing `rpc`/`rpc_result` 0x30/0x31 — we used `0x70+` instead);
> cross-platform host-metrics `Sampler` (`src/remote/agent/metrics.zig`, macOS/Linux/
> Windows behind `builtin.os.tag`); agent `metrics_sub`/`metrics`/`metrics_unsub` with
> a per-connection push pump joined under `shutdown()` before `destroy()` (UAF
> discipline); `remote-test-client --metrics[=N]`. Metrics pushed on `control_channel`.
> Verified: protocol 23 tests, agent 51 tests, native + `x86_64-windows-gnu` builds;
> **live metrics push proven against the native macOS agent.** ⏳ Windows sampler is
> compile-only until the agent is redeployed (needs the SMB share mounted).
>
> **Increment 2 ✅ CODE-COMPLETE, builds green** (2a `e72817c77`, 2b `23d3938e8`).
> 2a: client `Connection.subscribeMetrics(interval,ctx,handler)`/`unsubscribeMetrics`
> (dedicated handler slot fired from `handleControlInternal` on `.metrics`; pushes ride
> the EXISTING control-reader thread — no new client thread to join); C API
> `ghostty_host_metrics_s` + `ghostty_remote_connection_metrics_subscribe/_unsubscribe`
> (callback fires on the reader thread → Swift hops to main; unsubscribe clears the slot
> under lock before free → no UAF). Live-verified via `remote-test-client --metrics=3`
> against the native agent (real CPU deltas). 2b: the Cmd-Shift-N picker now dials each
> machine on open (`MachineMetricsProbe`), subscribes, and shows live **CPU% · used/total
> GB** IN PLACE OF the IP:port ("Connecting…"/"Unreachable"/live); probes torn down on
> dismiss. Closes progress-doc item #4. `zig build -Doptimize=Debug` green (connection 72
> tests, full app links).
> ⏳ **LIVE GUI VERIFY PENDING:** the picker is GUI (orchestrator can't drive Cmd-Shift-N)
> AND maximushome still runs the pre-metrics agent → rows sit at "Connecting…" until the
> metrics-capable agent is redeployed (needs the SMB share mounted, then
> `./scripts/deploy-windows-agent.sh`). Then the user opens Cmd-Shift-N to confirm live
> CPU/mem vs Task Manager.

> Original plan below (the increment-1 frame opcodes are the only deviation).

> Status (orig): **PLANNED, not started.** Branch base: `feature/remote-machines`.
> Author handoff for a fresh session. Builds directly on the existing remote stack
> (`src/remote/*`, the agent, the C API, and WP4 macOS UI). Read
> `docs/design/remote-machines.md` and `…-progress.md` first.

## Goal

Make the titlebar **machine pill** (`MachinePillView`, set per remote window) a
**clickable entry point** to a per-machine **Activity Monitor** — a panel that shows,
for the remote machine that window is connected to:

- Host-level **CPU / memory** usage (and ideally load, uptime, core count).
- A live **process list**: name, PID, parent PID, CPU%, memory, user, maybe start time.
- Actions:
  - **Kill** a process (graceful signal, then force).
  - **Start** a remote process (spawn a command on the machine, detached from any pane).
  - (Stretch) Sort/filter/search; per-process tree; open a pane attached to a process's tty.

It must work for **any remote machine** with a live connection — not just the focused
window. The panel is keyed by connection/machine, reusing the shared `RemoteConnection`.

This **subsumes progress-doc item #4** ("per-machine CPU/mem in the picker"): the same
agent metrics feed powers both the picker rows and this panel. It also provides the
process-introspection the **idle-shell close-confirm** feature wants (foreground child
detection) — see `needsConfirmQuit` discussion in the session notes.

## Why this fits the existing architecture

Everything needed is a **straight extension of the `GET_CWD`/`CWD` on-demand RPC** that
already exists end to end (protocol → agent → connection → C API → Swift). We mirror it
for: a one-shot **process snapshot**, a **streaming metrics subscription**, and two
**command** RPCs (kill, spawn). The agent already does host/proc introspection for cwd
(`proc_pidinfo` on POSIX, PEB/Toolhelp on Windows), so the OS-specific sampling has a
home and precedent.

## Wire protocol additions (`src/remote/protocol.zig`)

Mirror the `GetCwd`/`Cwd` pattern (see §"GET_CWD (0x22)/CWD (0x23)"). Reserve a new
frame-type block (control channel, JSON payloads). Suggested:

| Frame | Dir | Payload (struct) | Notes |
|-------|-----|------------------|-------|
| `proc_list` (0x30) | C→A | `{ session_id?, sort?, limit? }` | one-shot request for a process snapshot. `session_id` optional (machine-wide, not pane-scoped). |
| `proc_snapshot` (0x31) | A→C | `{ ok, host: {cpu_pct, mem_used, mem_total, ncpu, uptime_s?}, procs: [Proc] }` | reply. `Proc = { pid, ppid, name, cpu_pct, mem_bytes, user?, cmd? }`. |
| `metrics_sub` (0x32) | C→A | `{ interval_ms }` | start/refresh a host-metrics subscription on this connection. |
| `metrics` (0x33) | A→C | `{ host: {...} }` | pushed every `interval_ms` until `metrics_unsub`. Reuse for picker CPU/mem too. |
| `metrics_unsub` (0x34) | C→A | `{}` | stop the push. |
| `proc_kill` (0x35) | C→A | `{ pid, signal? }` | signal default TERM; agent escalates to KILL/TerminateProcess on a deadline. |
| `proc_kill_result` (0x36) | A→C | `{ pid, ok, error? }` | |
| `proc_spawn` (0x37) | C→A | `{ cmd, cwd?, env?, detached? }` | start a process on the machine (NOT a pane — no pty needed; capture nothing or a ring). |
| `proc_spawn_result` (0x38) | A→C | `{ ok, pid?, error? }` | |

Correlate replies by `Frame.channel` (same-channel RPC), exactly like `GET_CWD`. Keep
all payloads JSON for forward-compat; cap `procs` length and document truncation in a
`truncated: bool`.

**Security:** kill/spawn are powerful. The connection is already an authenticated session
to the agent (the agent trusts whoever connected — same trust as opening a remote shell),
so no *new* trust boundary, but: (a) gate spawn/kill behind the same agent-side auth the
shell path uses; (b) consider a config flag `remote-allow-process-control` (default on for
machines you added) and surface destructive actions with a confirm in the UI; (c) never
let `-R`/`-D`-style tunnels or arbitrary privilege escalation ride in via `proc_spawn`.

## Agent side (`src/remote/agent/`)

Add a `metrics.zig` / `proc.zig` module with a cross-platform interface and per-OS impls,
mirroring how `pty_child.zig` splits POSIX vs Windows:

- **Host metrics**: CPU% (sample deltas over interval), mem used/total, ncpu, uptime.
  - macOS/Linux POSIX: `host_processor_info`/`/proc/stat`, `sysctl`/`sysinfo`, `getloadavg`.
  - Windows: PDH counters or `GetSystemTimes` + `GlobalMemoryStatusEx`.
- **Process list**:
  - POSIX: `sysctl(KERN_PROC)` (macOS) / iterate `/proc` (Linux); per-proc CPU via deltas.
  - Windows: `CreateToolhelp32Snapshot`/`Process32Next`, CPU via `GetProcessTimes` deltas,
    mem via `GetProcessMemoryInfo`. (Toolhelp child-enumeration also answers the
    idle-shell question for `needsConfirmQuit`.)
- **Kill**: POSIX `kill(pid, SIGTERM)` then `SIGKILL` after a deadline; Windows
  `OpenProcess` + `TerminateProcess` (and `GenerateConsoleCtrlEvent` for console trees).
- **Spawn**: reuse `CommandCore` (the GUI-free spawn core, `src/Command*`); for a detached
  process we do NOT allocate a pty — just start it, return the pid.
- A small **subscription registry** per connection so `metrics` pushes are torn down on
  disconnect (reuse the connection's existing teardown hooks — mind the §3.4 use-after-free
  ordering; this just-fixed teardown UAF in `connection.zig`/`Ghostty.Surface` is the
  cautionary tale — any new per-connection thread must be joined before `Connection.destroy`).

Sampling cadence: agent samples lazily (only while a subscription/recent request exists) so
idle machines cost nothing. CPU% needs two samples → first reply may be approximate.

## Client connection (`src/remote/connection.zig`)

Mirror `query_cwd` plumbing:

- `requestProcSnapshot(timeout) -> ProcSnapshot` (one-shot `rpcCall(.proc_list, .proc_snapshot)`).
- `subscribeMetrics(interval, handler)` / `unsubscribeMetrics()` — a control-handler
  callback pushed to a registered closure (see `setControlHandler`).
- `killProc(pid, signal, timeout) -> bool`.
- `spawnProc(cmd, cwd?, env?, timeout) -> { ok, pid }`.

All are connection-scoped (not pane-scoped). Keep them off the main thread (these are
blocking RPCs / streams), like `queryRemoteCwd`.

## C API (`src/apprt/embedded.zig`)

Expose, mirroring `ghostty_remote_connection_query_cwd*`:

- `ghostty_remote_connection_proc_list(conn, timeout_ms) -> ghostty_proc_list_t` (+ a
  `_free`). Return a flat C array of `{ pid, ppid, cpu_pct, mem_bytes, name, user, cmd }`
  plus a host-metrics struct.
- `ghostty_remote_connection_metrics_subscribe(conn, interval_ms, callback, userdata)` /
  `_unsubscribe`. Callback marshals a `ghostty_host_metrics_s` to Swift.
- `ghostty_remote_connection_proc_kill(conn, pid, signal, timeout_ms) -> bool`.
- `ghostty_remote_connection_proc_spawn(conn, cmd, cwd, timeout_ms) -> int64 pid` (-1 err).

Free helpers + AllocatedString conventions as elsewhere. All marshaling synchronous from a
background queue on the Swift side.

## macOS UI (`macos/Sources/Features/Remote/`)

- **Make the pill clickable.** `MachinePillView` → wrap the capsule in a `Button`/tap
  gesture (it currently lives in an `NSTitlebarAccessoryViewController`; ensure hit-testing
  works — `NonDraggableHostingView` already disables window drag). On click, open the panel
  for `remoteMachine` + the window's `RemoteConnection`.
- **Panel**: a new SwiftUI window or popover `RemoteActivityMonitorView(connection:, machine:)`.
  - Header: machine name, host CPU/mem gauges (live via `metrics_subscribe`).
  - Table: `Table`/`List` of processes (PID, name, CPU%, mem, user). Sortable, searchable.
  - Toolbar: refresh, "New Process…" (sheet: command + cwd), kill (with confirm).
  - Auto-refresh process list on an interval while open; tear down subscription on close.
- **Reuse for the picker (#4):** the Cmd-Shift-N machine picker rows subscribe to the same
  `metrics` feed to show per-machine CPU/mem. Factor the metrics client so both consume it.
- Open from anywhere: a top-level "Remote Activity Monitor" menu/command that lists all live
  `RemoteConnection`s (the app already tracks them per controller; consider a registry) so
  it works for *any* machine, not just the focused window's.

## Suggested increments (each its own worktree subagent + commit)

1. **Protocol + agent host metrics** (`metrics`/`metrics_sub`): land frames, agent sampling
   (POSIX + Windows), `zig test`. No UI yet; drive via `remote-test-client`.
2. **Client + C API for metrics**; wire the **picker** CPU/mem (closes #4) as the first
   consumer — small, visible, proves the path.
3. **Process snapshot** (`proc_list`/`proc_snapshot`) end to end; show a read-only process
   table in the panel opened from the pill click.
4. **Kill** (`proc_kill`) with UI confirm + escalation.
5. **Spawn** (`proc_spawn`) with the "New Process…" sheet.
6. **Polish**: search/sort/tree, all-machines registry + menu, security flag + confirms.

## Test / verify

- Agent unit tests for metrics deltas and proc enumeration (fake `/proc` or injected
  sampler), like the existing agent tests.
- `remote-test-client` subcommands (`--metrics`, `--ps`, `--kill`, `--spawn`) to drive the
  Windows box (maximushome = 100.110.48.108:7777) headlessly, mirroring `--query-cwd`.
- Manual: open the panel from the pill against the live Windows agent; confirm CPU/mem track
  Task Manager, kill a notepad, spawn `calc`.
- **Teardown discipline:** verify closing the panel / window / quitting never UAFs the new
  per-connection subscription thread (join before `Connection.destroy`; see the teardown fix
  in `Ghostty.Surface.deinit` connectionKeepAlive + `connection.zig` for the pattern).

## Open questions

- Windows per-process CPU% accuracy/cost (PDH vs GetProcessTimes deltas over N procs).
- Should spawn optionally allocate a pty and surface as a new remote pane? (Bridges to the
  existing OPEN path — maybe a "open as pane" action instead of a separate spawn frame.)
- Permissioning model if we ever connect to machines we don't own.
