# Remote Machines

> Status: design draft **v4** (research-complete; revised after THREE rounds of multi-
> perspective adversarial review — distributed-systems, security, codebase-feasibility,
> Windows-native, CLI/UX — converged to a "start-building" verdict). §18 decomposes the
> work into worktree-fannable packages with interface contracts.
>
> **v4 changelog (round-3 convergence):** versioned `HELLO` handshake (§4.2/WP1);
> inbound-ring mini-spec + gated benchmark (§3.4/§17/WP3); interactive SSH auth +
> first-contact host-key UX (§4.1/WP3); purged stale "capability/RPC token" wording in
> favor of kernel peer-cred identity (diagram, frame table, §16/WP2/WP8); honest
> control-channel framing (§4.3); manifest `version:1`.
>
> **v2 changelog:** sequence-anchored resync (§7.3); separate SSH control channel
> (§4.3); single-attach steal (§5.3); connection key `(host,user,port,jump)` (§3);
> Windows daemon out-of-band not breakaway (§4.1/§13); CR/LF-immune Windows framing
> (§4.2); surface-backend plumbing named (§3/§18); in-pane RPC scoping (§9.5);
> attribution (§9.6); canonical JSON model (§9.7); UPDATE verbs + error UX (§10).
>
> **v3 changelog (round-2 fixes — corrected overstated claims):** thread topology now
> uses per-channel inbound rings drained by each pane's own IO thread, eliminating
> cross-pane HOL (§3.4); control "exempt" honestly bounded by TCP HOL (§4.3); supply
> chain states the real boundary (remote-account-compromise = full compromise; no
> false attestation, §4.1/§15 C1); in-pane RPC identity is **kernel peer-cred +
> containment membership**, NOT an env bearer token (§9.5/§15 C2); `--dest` deny-by-
> default with dial-time resolved-IP check (§9.5); hostile-remote escape-injection
> policy / trusted chrome client-derived (§9.8); concrete revocation via
> `authorized_keys` re-read + concrete caps (§7.1/§15 M4); sensitive forwards over a
> peer-cred Unix socket (§15 M5); pipe `FIRST_PIPE_INSTANCE` + launch-race fix
> (§4.1/§13); OSC 9;9 prompt-injection-safe (§9.4); TERM/terminfo + clipboard + input
> transparency + scrollback + px/IME fidelity (§6.5); local-pane attribution (§9.6);
> `+remote signal`/`logs`/`kill-daemon`, forward edit-as-rebind, `--host` vs
> `--target` (§10).

## 1. Goal

Let a Ghoztty window represent a **remote machine** so panes, shells, splits, and new
windows spawned from it run *on that machine* while rendering locally —
indistinguishable from local panes.

- **Good path:** window bound to a remote; splits/new-windows inherit the connection;
  `+read`/`+send-keys`/`+set-state` work unchanged; title `machine: title`.
- **Disconnects & reconnection:** survive drops, sleep, and *local GUI crashes*;
  reattach to still-running remote processes and rebuild the layout.
- **Latency:** native feel on LAN/regional links; graceful degradation otherwise.
- **Port tunneling:** remote dev servers reachable locally without breaking URLs,
  cookies, CORS, OAuth, or HMR; easy to configure.
- **Process management:** the user *and an AI agent in a pane* can see what they
  spawned on a remote and kill it reliably, with correct attribution.
- **CRUD CLI:** full create/read/update/delete for connections, windows, panes,
  processes, and forwards — the automation-first surface, one canonical JSON model.
- **UI:** first-class macOS UI for connecting to and managing remote machines.
- **Native Windows remotes** (no WSL), plus Linux/macOS.

### Non-goals (v1)
Predictive local echo (v2, §6); HTTPS-fixed-cert remotes (§8.8); file sync/SFTP;
UDP roaming (v2); moving a pane between connections or local↔remote (§10.4).

## 2. Why this is tractable (grounded in current code)

1. **Backend is already a tagged union.** `src/termio/backend.zig` (`Kind = enum
   { exec }`, three parallel unions). Adding `remote` is the structural seam (§3).
2. **Windows PTY path exists.** `src/pty.zig:325` `WindowsPty` (ConPTY/`HPCON`);
   `src/Command.zig:260` `startWindows` (`CreateProcessW`+`PROC_THREAD_ATTRIBUTE_
   PSEUDOCONSOLE`). The agent reuses these — but see the §18 WP2 `Command.zig`
   dependency refactor (it currently drags `config.zig`/`global.zig`/`apprt`).
3. **Transport security solved by SSH** — bootstrap over `ssh`, inherit
   `~/.ssh/config`/keys/agent/`ProxyJump`/`known_hosts`. No public listener, CA, or
   new credential store.
4. **SSH-adjacent substrate to extend:** `src/cli/ssh_cache.zig` +
   `ssh-cache/DiskCache.zig` (terminfo push) — the agent bootstrap, conductor
   metadata, and OSC-9;9 prompt injection extend this.
5. **Uniform CLI+IPC:** every command is an `Action` (`src/cli/ghostty.zig`) shipping
   `IPCRequest{action, arguments}` → `IPCServer.swift` → `IPCResponse`. Remote verbs
   are additive; the UI is another renderer of the same JSON (§9.7).

---

## 3. The local-vs-remote pane seam

### 3.1 The union (the structural seam)
`src/termio/backend.zig` today:
```zig
pub const Kind = enum { exec };
pub const Config     = union(Kind) { exec: termio.Exec.Config };
pub const Backend    = union(Kind) { exec: termio.Exec };
pub const ThreadData = union(Kind) { exec: termio.Exec.ThreadData };
```
Add `remote` across all three. `termio.Remote` is a **fresh struct** (NOT a reshaped
`Exec` — it reuses none of Exec's xev-stream/termios-timer machinery), with its own
`Remote.ThreadData`. The 11 switch arms in `backend.zig` are compiler-forced (safe).

### 3.2 Required edits OUTSIDE backend.zig (named, per feasibility review)
The doc previously claimed window mgmt "barely changes." Concretely the implementer
must also touch:
- **`src/Surface.zig:682`** — the *only* backend construction site, hardcoded
  `.{ .exec = io_exec }`. Add a branch: if a remote connection handle is present in
  surface config, build `.{ .remote = ... }`. **This is the highest mechanical risk
  and the load-bearing change.**
- **`src/Surface.zig:1340`** — `childExitedAbnormally` does
  `switch (self.io.backend) { .exec => ... exec.subprocess.args }` for the exit
  overlay's command text. Add a `.remote` arm (remote has no `subprocess.args` →
  use agent-reported `foreground_cmd` or `null`).
- **`ghostty_surface_config_s`** (`include/ghostty.h` ~460-480 / `apprt/embedded.zig`
  Options ~595-633) — add `ghostty_remote_connection_t connection` + `const char*
  session_id`, plumb through `embedded.zig` config application into `Surface.zig`.
  Header + sync-test update. Today Swift literally cannot request a remote backend.
- **`+list` metadata:** `TerminalData.pid`/`tty` come from the local pty
  (`tcgetpgrp`/`ptsname_r`, `pty.zig` ~270/290) → **empty for remote**; must be
  sourced from agent per-session metadata (§9.3). `working_directory` comes from
  **OSC 7** (`stream_handler.zig`) → works for remote if the shell emits it (OSC 9;9
  on Windows, §13). Split these: cwd works, pid/tty must come from the agent.

### 3.3 Contract `termio.Remote` mirrors `Exec`
| Method | Exec (local) | Remote |
|---|---|---|
| `init(alloc, cfg)` | builds `Subprocess` | resolves/acquires the shared `RemoteConnection` for `cfg.conn_key`; records `cfg.session_id` (nil ⇒ open-new) |
| `initTerminal(t)` | pwd, grid size | same; pwd lazily from OSC 7/9;9 |
| `threadEnter(alloc, io, td)` | `Subprocess.start()`→fds; per-pane `ReadThread`; `write_stream` | **registers `(channel_id → io)`** with the connection; sends `OPEN`/`ATTACH`; sets `td.backend=.{.remote=...}`. No per-pane read thread. |
| `queueWrite(...)` | xev pty write (`Exec.zig:424`) | **MPSC-enqueue** a `DATA{channel,bytes}` onto the connection writer (§3.4) |
| `resize(...)` | TIOCSWINSZ/ConPTY | `RESIZE{channel,...}` |
| `focusGained` | local | forwarded as `DATA` if enabled |
| `childExitedAbnormally` | overlay | overlay from `EXIT{channel,code}` |
| `getProcessInfo` | local pty | cached agent metadata or `null` |
| `deinit`/`threadExit` | stop subprocess, join thread | **deregister channel (refcount drain, §3.4); send `DETACH` (keep-alive) — NOT `CLOSE`** unless `+close` |

### 3.4 Thread topology & lifetime (per distributed-systems + feasibility review)
Each Termio keeps its **own IO thread + xev loop** (`Thread.zig:261`) for writes/
resize/mailbox; only its *read* side is bypassed. So per remote window the real
thread count is: **N pane IO threads + 1 connection reader + 1 connection writer/mux
thread**. Key constraints the implementation MUST honor:

- **Read path: demux thread enqueues, per-pane thread parses.** `Termio.processOutput`
  (`Termio.zig:643`) self-locks the *per-surface* `renderer_state.mutex`
  (`Surface.zig:610`) and is already called from a foreign thread (Exec's
  `ReadThread`). **The codebase has NO inbound ring today** — Exec's `ReadThread`
  calls `processOutput` *synchronously inline* (`Exec.zig:1358/1410`), and the only
  mailbox (`mailbox.zig`) is the write-side SPSC queue that *blocks* when full. So a
  naive shared reader calling `processOutput(io_a)` then `processOutput(io_b)` inline
  would head-of-line-block panes. **The fix reuses infrastructure that already
  exists:** each remote pane keeps its own IO thread (its read side is otherwise
  idle), so we add a **new bounded per-channel inbound ring**; the connection's demux
  thread does a **non-blocking push** of each frame's bytes into the target channel's
  ring (drop-to-backpressure via `FLOW{pause}` when full, §4.4) and wakes that pane's
  IO thread via its `xev.Async`; the **pane's own IO thread drains its ring and calls
  `processOutput`**. This restores per-pane parallelism (no cross-pane HOL — each pane
  parses on its own thread), keeps the demux thread non-blocking, and makes channel
  teardown **joinable per-pane** exactly like Exec's `ReadThread` (the use-after-free
  guard below). This per-channel inbound ring + non-blocking push is **new code WP3
  must build** — it is not assumed to exist.
- **Writer is MPSC.** N pane IO threads concurrently `queueWrite` → one connection
  writer queue. Specify it as a lock-protected/MPSC queue with a wakeup of the mux
  thread. Preserve `Termio.queueWrite`'s "mailbox-thread-only" invariant
  (`Termio.zig:406`): the enqueue happens on each pane's IO thread; the mux thread
  owns the socket.
- **Channel lifetime (use-after-free guard).** Because the per-pane IO thread owns
  the *parse* side (above), teardown joins exactly like Exec: on `threadExit` the
  pane stops draining and is joined, *then* the channel is deregistered from the
  connection's table under a connection lock; the demux thread only ever holds a
  channel ref while pushing under that lock, so it never pushes into a freed ring. The
  ring is owned by the pane (freed after its thread joins), not by the demux thread.
- **Local connection object is disposable.** It lives in the GUI process; a GUI
  crash kills it. Persistence comes ONLY from `session_id` + the remote daemon
  (§7). The C-API ownership ("owned in Zig core") must not be read as "survives a
  crash."

**Inbound-ring mini-spec (the one novel concurrency primitive — gated spike before WP3
fan-out).** This is new hot-path code touching rendering, so it gets its own spec +
benchmark gate (§17), not just a WP3 bullet:
- *Structure:* one SPSC ring per channel — demux thread is the single producer, the
  pane's IO thread the single consumer. Size 256 KB (≥ the 64 KB data-channel window so
  a full window fits without blocking the producer).
- *Producer (demux):* `try_push(bytes)`; on would-block (ring full) it does NOT block —
  it sends `FLOW{pause}` for that channel (agent stops draining that session's PTY,
  §4.3) and retries after the consumer signals low-water; sends `FLOW{resume}` at the
  16 KB low-water mark.
- *Wake:* after a successful push the producer signals the pane's existing `xev.Async`;
  the consumer drains the ring and calls `processOutput` on its own thread (the same
  call Exec's `ReadThread` already makes — self-locks the renderer mutex).
- *Lock ordering (use-after-free invariant):* the connection table lock is acquired
  *outside* any push; teardown order is **stop consumer → join pane IO thread →
  deregister channel under the table lock → free ring**. The producer holds the table
  lock for the duration of a lookup+push, so it can never push into a ring being freed.
  No other lock is taken while the renderer mutex is held (avoids inversion).
- *Gate:* benchmark a 4-pane remote window with one pane running `yes` vs the same
  layout local — the three quiet panes must show no added input-latency regression.

### 3.5 Connection identity & sharing
A connection is keyed by the **tuple `(host, user, port, jump-chain)`**, not host
alone (so `deploy@h` and `me@h` are distinct muxes). One SSH connection per key,
multiplexed into N channels; N windows can share one connection. Owned in the Zig
core, spawns `ssh` via `Command.zig`, exposes a C API to Swift.

```
   Swift (per surface)             Zig core (libghostty)                Remote host
 ┌────────────────────┐  ┌──────────────────────────────────┐ ┌──────────────────────────┐
 │ SurfaceView        │  │ RemoteConnection (per conn-key)   │ │ ghoztty-agent DAEMON      │
 │  └ Termio          │◄─┤  ├ ssh subprocess (Command.zig)   │◄┤  (launched out-of-band;   │
 │     backend=.remote│  │  ├ ctrl SSH channel (sep. lane)   │ │   survives SSH teardown)  │
 │     channel_id ────┼─►│  ├ data SSH channel (mux, flow)   │─►│  grid model + ring/pane;  │
 │ Connection Mgr UI  │◄─┤  ├ MPSC writer + demux reader     │ │  containment group/pane;  │
 │ (renders §9.7 JSON)│  │  └ channel table {uuid→io}+refcnt │ │  conductor metadata + RPC │
 └────────────────────┘  │  C API: connect/open/attach/...   │ └──────────────────────────┘
                         └──────────────────────────────────┘
```

---

## 4. Transport & protocol

### 4.1 Bootstrap & daemonization
- `ssh <host> ghoztty-agent attach [--session=<uuid>]`. The agent owns the pty, not
  SSH. **Two SSH channels** (§4.3): one for control, one for data — either two exec
  invocations multiplexed by one `ControlMaster`, or one connection with an internal
  priority scheduler (§4.3 decides). Use `ControlMaster`/`ControlPersist` to share
  the underlying TCP.
- The first attach **starts or connects to a persistent daemon**; attach is a
  *transport bridge* to it. Daemon endpoint local-only:
  - POSIX: Unix socket `$XDG_RUNTIME_DIR/ghoztty-agent.sock` (0600).
  - Windows: named pipe with an **explicit owner-only DACL** + `PIPE_REJECT_REMOTE_
    CLIENTS` + **`FILE_FLAG_FIRST_PIPE_INSTANCE`** (fail-closed if the name already
    exists → defeats name-squatting; the `<sid>` in the name is obfuscation, NOT
    access control — §15 M6).
- **Daemon survival across SSH teardown:**
  - POSIX: `setsid` + double-fork.
  - **Windows: launch OUT-OF-BAND — NOT `CREATE_BREAKAWAY_FROM_JOB`.** sshd runs the
    command under `ssh-shellhost.exe` in a job that does **not** set
    `JOB_OBJECT_LIMIT_BREAKAWAY_OK`, so breakaway fails with ACCESS_DENIED
    (Win32-OpenSSH#1032). The bridge instead registers/starts the daemon via a
    **per-user Scheduled Task** (`schtasks /create` if absent, then `/run`) or an
    opt-in **Windows Service**; Task Scheduler launches it in its own job decoupled
    from sshd. (`DETACHED_PROCESS` only detaches the console, not the job.)
    **Startup race + single-instance (round-2 fix):** `schtasks /run` is async (returns
    on trigger, not on listen). The bridge MUST then `WaitNamedPipe` with bounded
    backoff (≤ exit-code-13 timeout) before `CreateFile`, since the pipe won't exist
    immediately. The daemon guarantees a single instance via a **named mutex** and
    `FILE_FLAG_FIRST_PIPE_INSTANCE` on the pipe (fail-closed if it already exists →
    a name-squat by another local user is rejected, §15 M6); concurrent bridges
    (two windows attaching at once) thus converge on one daemon. POSIX uses an
    analogous `flock`'d lock file next to the Unix socket.
- **Agent provenance (supply chain, §15) — honest trust boundary:** the agent ships
  **inside the signed Mac app bundle** (the ONLY source; never network-fetched, never
  "newer side wins"). The client **pushes its own bytes on every connect** to a
  **client-controlled absolute path** under a dir it creates `0700` owned by the SSH
  user (`~/.local/share/ghoztty/agent-<ver>/ghoztty-agent`), and invokes by absolute
  path (never bare `$PATH`, which PATH-shadowing defeats). **What we do NOT claim:**
  remote integrity attestation. A read-back hash or the agent's self-reported build
  hash are both produced by the (possibly compromised) host and are therefore
  circular — they cannot prove the executing bytes are ours. The real, stated
  boundary: **a compromised remote account = full compromise of that host's sessions,
  undetectable from the client.** The one enforceable client-side property is
  *downgrade protection*: the client refuses to replace an already-deployed
  newer-or-equal agent version (compares its bundle version to the on-disk path's
  version dir, which only the client's key can write). Auto-redeploy on version
  mismatch is **gated** so a routine client upgrade doesn't silently kill live
  sessions (§7.5).
- **Interactive auth & first-contact (day-1, must-have for P1):** `ssh` is not always
  non-interactive. The bootstrap must surface, in the GUI, **key passphrase prompts,
  password / `keyboard-interactive` (2FA) prompts, and first-contact host-key
  acceptance** — distinct from the host-key-*mismatch* dialog (§11.7). Mechanism: run
  `ssh` with `-o BatchMode=no` and a controlled `SSH_ASKPASS` (+ `SSH_ASKPASS_REQUIRE=
  force`) that round-trips prompts to a Ghoztty sheet; first-contact host keys use
  `accept-new` **surfaced as an explicit user confirmation** showing the fingerprint
  (never silent, never `StrictHostKeyChecking=no`, §15 m8). Connecting through the
  command palette/sheet must show a **progress affordance** for the cold-connect chain
  (ControlMaster → agent push → terminfo push → daemon spawn), which can take several
  seconds on a fresh host.

### 4.2 Wire format
Length-prefixed binary frames:
```
┌────────────┬─────────┬──────────────┬───────────┬──────────────────────┐
│ len u32 BE │ type u8 │ channel u128 │ seq u64   │ payload [len-29]      │
└────────────┴─────────┴──────────────┴───────────┴──────────────────────┘
```
- **Two sequence spaces (per m2):** a **per-(SSH)connection frame seq** (loss/RTT
  detection, §6.4) AND, on `DATA`, a **per-channel byte offset** carried in the
  payload header (resync anchoring, §7.3). The byte offset counts **raw decoded
  child-output bytes** (post-transfer-decoding, pre-terminal-parse) so it is stable
  across reconnects where the transfer encoding may differ per hop. The agent
  persists it across reconnects; the connection frame seq resets per SSH connection.
- **Windows transfer encoding:** because `ssh-shellhost.exe` may mangle CR/LF
  regardless of `_setmode(_O_BINARY)` (Win32-OpenSSH#1256), the wire bytes on a
  Windows hop are wrapped in a **CR/LF-immune encoding (COBS or base64)**. The
  encoding is **pinned at handshake** (a frame in the wrong encoding is a protocol
  error → drop); the transfer decoder enforces the **same hard max on the DECODED
  length** (so a tiny COBS/base64 frame can't expand into an allocation bomb), and
  the fuzz corpus (§18 WP1) includes malformed COBS/base64. POSIX hops use raw
  framing. (WP2 spike validates whether raw is ever safe on Windows; default encoded.)

Frame types (control channel `0`; control rides the **separate control SSH channel**):
| type | dir | name | payload |
|---|---|---|---|
| 0x01 | C→A | `OPEN` | `{cwd, command, shell, term, env(allowlist incl TERM/LANG/LC_*), rows, cols, px_w, px_h, name}` |
| 0x02 | A→C | `OPENED` | `{session_id, pid}` |
| 0x03 | C→A | `ATTACH` | `{session_id, rows, cols, last_byte_offset}` |
| 0x04 | A→C | `ATTACHED` | `{status: alive\|dead\|not_found, rows, cols, cwd, title, snapshot_at_offset, exit_code?}` |
| 0x05 | A→C | `DETACHED` | server-initiated eviction notice (steal, §5.3) |
| 0x10 | both | `DATA` | `{byte_offset, bytes}` for `channel` |
| 0x11 | C→A | `RESIZE` | `{rows, cols, px_w, px_h}` |
| 0x12 | C→A | `SIGNAL` | `{name}` (INT/TERM/KILL…) |
| 0x13 | C→A | `DETACH` | stop streaming; keep session alive |
| 0x14 | C→A | `CLOSE` | terminate the session's container, free it |
| 0x20 | A→C | `EXIT` | `{code, runtime_ms}` (ordered after final `DATA`) |
| 0x21 | A→C | `META` | `{cwd?, title?, listening_ports?, foreground_cmd?}` |
| 0x00 | both | `HELLO` | handshake: `{proto_version, transfer_encoding, capabilities[]}` — version/encoding negotiated before any other frame; mismatch → drop |
| 0x30 | C→A | `RPC` | JSON-RPC 2.0 request (§9.5); caller identity is kernel-derived (peer-cred), not carried in-band |
| 0x31 | A→C | `RPC_RESULT` | JSON-RPC 2.0 response / subscription notification |
| 0x40 | C→A | `TUNNEL` | `{op, type:L\|R\|D, listen, dest, autostart}` |
| 0x50 | both | `PING`/`PONG` | heartbeat + RTT (control channel only) |
| 0x60 | both | `FLOW` | `{channel, op:pause\|resume\|credit, n}` |

**Client treats all frames as untrusted** (§15 M3): bound-check `len` against a hard
max; validate snapshot `rows×cols`; **verify inbound `channel`/`session_id` belongs
to a session this client opened** before routing into a Termio (prevents cross-pane
injection from a hostile host). Fuzz the *client* demux + snapshot applier.

### 4.3 Flow control — control on a separate, prioritized channel (TCP-HOL-bounded)
A single ordered SSH byte stream **cannot** preempt queued data with an in-band
"exempt" flag (TCP is in-order; a `^C` behind a 32 KB data frame waits for it). So:
- **Run control frames over a SEPARATE SSH channel** (`PING`/`PONG`, `SIGNAL`,
  `FLOW`, `RPC`, lifecycle). This gives control its own SSH-level flow-control window,
  so it has an **independent application-level lane** — never queued behind a 32 KB
  `DATA` frame in the app writer. **Honest limit:** both channels still ride one TCP
  connection (shared `ControlMaster`), so a saturated data channel that fills the
  kernel TCP send buffer can still delay control bytes via TCP head-of-line blocking.
  We bound that by keeping `DATA` chunks small so the socket buffer stays shallow
  (next bullet). So `^C`-under-flood (§14.9) is **fast under cooperative peers**, not
  hard-guaranteed against an adversarial flooder. **True isolation** (if ever needed)
  requires a SEPARATE TCP connection for control (a second `ssh` not sharing
  `ControlMaster`) — noted as the hard-guarantee option, deferred.
- **Data channel flow control:** per-channel ring 64 KB; agent **pauses** the
  session PTY read at 48 KB high-water, **resumes** at 16 KB low-water; mux
  **round-robin drains** channels, ≤~32 KB/channel/cycle. Keep DATA chunks small
  enough that the kernel socket buffer stays shallow (so even within the data
  channel, scheduling is responsive).
- **v2 (WAN):** per-channel credit windows, initial 256 KB, auto-tune ~2× BDP, cap
  4 MB; control stays on its own channel.

### 4.4 Coalescing
`TCP_NODELAY` everywhere. App-layer per-channel output coalescing: flush on ~8 ms
timer or ~32 KB, whichever first. Biggest perceived-latency lever after `TCP_NODELAY`.

---

## 5. Connection lifecycle & reconnection

### 5.1 State machine
```
        heartbeats OK (ctrl channel)
   ┌──────────────────────────────────┐
   ▼                                   │
 CONNECTED ──2 missed(~6s)──► DEGRADED ┘   DEGRADED ──any authentic pkt──► CONNECTED
   ▲                            │
   │ resync done                │ 3–5 missed(~10–15s) / transport error
   │                            ▼
 REATTACHING ◄─token accepted─ RECONNECTING ──backoff cap / session gone──► DEAD
```
- **CONNECTED:** `PING`/`PONG` every 3 s interactive (→15 s idle) on the control
  channel; live `DATA` applied.
- **DEGRADED:** ~2 missed (~6 s): non-destructive "Last contact Ns ago" banner; no
  teardown. (False positives prevented by control on its own channel, §4.3.)
- **RECONNECTING:** full-jitter backoff (base 500 ms, cap 30 s, reset on success);
  re-`ssh … attach --session=<uuid>`.
- **REATTACHING:** apply sequence-anchored snapshot (§7.3), re-establish autostart
  forwards (§8.6), resume.
- **DEAD:** token rejected / grace expired → surface clearly, offer fresh session.

### 5.2 Disconnect detection
Never rely on TCP keepalive. Use the control-channel heartbeat above + SSH
`ServerAliveInterval`/`ServerAliveCountMax 3` + `ExitOnForwardFailure yes`.

### 5.3 Single-attach with steal semantics (split-brain prevention)
A session has **at most one attached bridge**, identified by a monotonically
increasing **attach-epoch** the agent stamps at each successful attach. `ATTACH` to an
already-attached session returns `ATTACHED{status:alive, attached_elsewhere:true}`;
the client may retry with `--force` to **steal**. The agent then, atomically under the
session lock: (1) **fences the old bridge** — bumps the epoch; any C→A frame
(`DATA`/input, `SIGNAL`, `RESIZE`) carrying a stale epoch is **dropped**, so an
in-flight keystroke from the evicted bridge can never reach the PTY after the steal;
(2) sends the old bridge `DETACHED` (0x05); (3) captures the snapshot at offset `S`
*after* the fence (so the new bridge's redraw reflects exactly the last accepted
input) and serves the new bridge per §7.3. **Consent/audit (security):** a steal is
authorized only by SSH access to the host, so it is a session-hijack primitive on a
shared/forwarded key — every steal is **logged/audited** by the daemon and surfaced
prominently to the evicted side; sensitive deployments can require a confirmation
token. This prevents dual keystroke streams and `RESIZE` thrash from a second Mac or a
stale bridge.

### 5.4 Resize during disconnect
The GUI may resize while DEGRADED/RECONNECTING. On REATTACHING: send `ATTACH` with
the *new* size; the client **ignores DATA until the snapshot arrives**; the agent
resizes the pty/ConPTY once, captures the snapshot at the new size, sends it; client
clears+redraws. (On Windows this also dodges ConPTY resize-repaint, §13.1.)

---

## 6. Latency & responsiveness

- **v1 (no predictive echo):** `TCP_NODELAY` + §4.4 coalescing + render-side
  decoupling (PTY parse off paint, repaint ~1 refresh). Feels native ≤~20 ms.
- **Defer predictive echo** (the area even VS Code keeps breaking). v2 upgrade path:
  server-side screen model first (also needed for §7.3 v2), client overlay, epoch
  predictions with **behavioral** safety (predict only on a row where a prior
  prediction was confirmed without intervening control chars — *not* password
  string-matching), RTT-gated (on >30 ms / off <20 ms SRTT), underline flag
  (on >80 / off <50 ms), glitch repair ~250 ms, exclude-list (vim/nano/tmux) backstop.
- **RTT/health from day one:** control frames carry dwell-adjusted
  `timestamp`/`timestamp_reply` + frame seq; SRTT/RTTVAR per RFC 6298 (α=1/8, β=1/4,
  K=4); loss = frame-seq gaps. Green <~80 ms / yellow / red+loss badge; banner ~6.5 s.

### 6.5 Terminal fidelity ("indistinguishable from local")
The byte-transparent `DATA` path makes most of this fall out, but it must be stated:
- **TERM / terminfo (P1, the classic footgun):** the agent spawns the child with
  `TERM` from the `OPEN` payload. Policy: the client requests `xterm-ghostty`; at
  first connect the agent ensures Ghoztty's terminfo is present on the remote (push
  via the `ssh-cache` mechanism) and **falls back to `xterm-256color`** if it can't be
  installed. `TERM`/`LANG`/`LC_*` are in the env allowlist (§4.2). E2E must run `vim`
  remotely (§14).
- **Input is byte-transparent (upstream `DATA`):** keys, **mouse reporting** (SGR
  1006), **bracketed paste**, **focus** events, and true-color are passed through
  `queueWrite` unmodified — no client-side interpretation or filtering.
- **IME / dead keys** are composed **locally** by the macOS app; only committed bytes
  transit. Same for kill-ring/line-editing (remote shell owns them).
- **Clipboard (OSC 52)** transits over `DATA` and is subject to the local
  clipboard-confirmation policy; reads are never answered to a remote (§9.8).
- **Scrollback & search:** the client accumulates its **own** scrollback from live
  `DATA` into the normal Ghoztty buffer (search/scroll work locally); only
  *cross-reattach* history is bounded by the agent ring (§7.3 — "(N lines lost)" if
  exceeded). Steady-state scrollback is full and local.
- **Pixel geometry (sixel/kitty graphics):** `px_w/px_h` are computed **locally** from
  the active display's DPI + font and sent verbatim in `OPEN`/`RESIZE`; a window
  moving between Retina/non-Retina displays triggers a `RESIZE`. Remote apps see local
  pixel geometry.
- **Nested `ssh -A` from a remote pane** (onward SSH with the local agent) is a
  **non-goal v1** — agent-forwarding for the *bootstrap* jump-chain (§3.5) is covered;
  in-pane onward agent forwarding is not.

---

## 7. Session persistence & resumability

### 7.1 Remote side (daemon)
Each session: **cryptographically-random UUID, NEVER reused**; child handle; size;
**a real terminal-grid model** (parse the pty/ConPTY stream into cells — mandatory,
not just a byte ring; see §7.3 and Windows §13.1); a bounded **raw-output ring**
(default 2 MB) for recent scrollback context; cwd/title/state; containment group
(§9). Sessions outlive any client. `DETACH`/drop keeps them; only `CLOSE` or child
exit frees them. The daemon **`waitpid`/`waitForJob`-reaps** to capture exit codes.

**Resource caps & TTL (concrete defaults, §15 M4):** ≤ **64 sessions/daemon**;
≤ **256 MB** total ring memory (evict oldest scrollback first); detached-and-alive
**idle TTL 24 h** (no reattach → reaped); detached-and-**exited** → **tombstones**
(exit code + final snapshot) with a **10 min** TTL so reattach can show "exited
(code N)" before GC. The daemon runs itself under its own cgroup/job with these limits
and **disables core dumps** (`PR_SET_DUMPABLE 0` / `RLIMIT_CORE 0` / Windows
equivalent) so the in-RAM rings (which may hold tokens/passwords) don't hit disk.

**Revocation that survives key rotation (§15 M4):** the daemon cannot re-check SSH
auth on the live channel, but it **re-reads the user's `authorized_keys` on an
interval (and on each new attach) and self-terminates any session whose creating SSH
principal's key is no longer present.** This makes offboarding/key-rotation actually
stop work (the thief-with-revoked-key case), rather than merely documenting that it
doesn't. `+remote kill-daemon` is the explicit teardown for when the user still has
access.

### 7.2 Local side (workspace manifest)
On-change to app-support (0600). Captures the layout the daemon doesn't know:
```jsonc
{ "version": 1,
  "connections": [{ "id":"deploy@devbox:22", "host":"devbox","user":"deploy","port":22,
                    "jump":["bastion"], "loopback":"127.0.0.2","name":"devbox.test" }],
  "windows": [{ "title":"devbox","connection":"deploy@devbox:22",
                "splitTree": { /* leaves → { session_id, name, cwd, recorded_cmd } */ } }] }
```
On launch: read manifest → connect per connection-key → per leaf `ATTACH` → rebuild
the `SplitTree` via existing `inserting()`/`replaceSurfaceTree`
(`BaseTerminalController.swift:553`).

### 7.3 Resync — sequence-anchored (fixes the corruption/loss class)
The child never stops writing, so snapshot↔live must be byte-anchored:
- On `ATTACH{last_byte_offset = L}`, the agent (under the same lock its pty reader
  uses) atomically: captures the grid snapshot, records its byte offset `S`, and
  replies `ATTACHED{snapshot_at_offset = S}`.
- The agent then sends: **gap-fill** = ring-buffer bytes in `(L, S]` if available
  (else a "scrollback truncated" marker), then the **snapshot** (clear+redraw), then
  **live `DATA` strictly from byte_offset > S**. The client **discards any `DATA`
  with byte_offset ≤ S**. No double-apply, no gap, no interleave.
- **v1 honesty:** if the disconnect outlived the ring (output in `(L,S]` partly
  evicted), that scrollback is lost — surfaced as a one-line "(N lines lost during
  disconnect)" marker. The **visible grid is always exact** (from the snapshot).
  This replaces the earlier, contradictory "diffs resume / scrollback survives"
  claim: **viewport is gap-free; scrollback beyond the ring may be truncated.**
- **v2:** mosh-style idempotent state-diff sync from the canonical grid model (also
  unlocks predictive echo).

### 7.4 Recovery tiers — per-session, not per-daemon (fixes divergence matrix)
`ATTACHED.status` drives recovery for *each pane independently*:
- `alive` → reattach (tier 1).
- `dead` (known UUID, child exited while detached; tombstone) → show "exited (code
  N)" then the re-run gate.
- `not_found` (unknown UUID: daemon rebooted, GC'd, or manifest stale) → **fresh
  shell at recorded cwd**, pane flagged "restarted", with a **"Press Enter to re-run
  `<recorded_cmd>`" gate** (never silently re-exec a possibly-destructive command).
Because UUIDs are random and never reused, `ATTACH` can never hit the *wrong* child.

### 7.5 Honest limits (no overclaim)
A PTY/child is owned by the daemon process; **if the daemon restarts (crash, OOM,
upgrade), all children die** — identical to a reboot from the child's view. Disk
serialization preserves *metadata only* (layout, cwd, last command) → tier "fresh
shells". There is no live-child survival across a daemon restart without fd-passing
handoff (out of scope). Therefore **agent auto-redeploy is gated**: prompt/defer when
live sessions exist; never silently nuke them on a routine client upgrade.

---

## 8. Port tunneling

> **Reality (verified live):** `bind(127.0.0.2)` on macOS → `EADDRNOTAVAIL`; needs
> `sudo ifconfig lo0 alias`, non-persistent. Linux binds 127/8 freely; Windows binds
> only 127.0.0.1.

### 8.1 The problem
URL **origin = (scheme, host, port)**. Remapping the port breaks same-origin policy,
Web Storage/IndexedDB, `postMessage`, **CORS**, **OAuth `redirect_uri`** (exact
match), printed/absolute-redirect URLs, **HMR WebSockets**. **Cookies survive** (port-
agnostic) — masking the breakage. **HSTS is host-wide across all ports** (a once-
pinned `localhost` force-upgrades every port to https). Goal: **preserve the port;
if anything differs, change the host, not the port.**

### 8.2 Per-machine identity (host, not port)
Each machine gets a stable **`.test`** hostname → per-machine loopback addr; forward
the **same port** there. `devbox`→`127.0.0.2`/`devbox.test`. Same port ⇒ no URL
rewriting; distinct host ⇒ CORS/storage/OAuth scope per machine; remotes coexist on
`:3000`. **TLD: `.test`** (RFC 6761). **Never `.local`** (mDNS: ~5 s delays) or
**`.dev`** (HSTS-preload gTLD → forces https).

### 8.3 Platform provisioning
- **macOS:** a per-user **LaunchDaemon** runs `ifconfig lo0 alias 127.0.0.N up` per
  machine at boot (one-time sudo, guided first-run, §11.0). Without it only
  127.0.0.1 binds.
- **Linux:** nothing needed.
- **Windows remotes:** can't do per-IP locally → fall back to same-port-on-127.0.0.1
  when free, else remap + rely on `.test` host alias + origin-aware dev-server config
  (§8.7). (This concerns the *local macOS* listener; the Windows box is the forward
  *destination*, which is fine.)

### 8.4 Name resolution
Default `/etc/hosts` (`127.0.0.2 devbox.test`; sudo; no wildcards). Power option
(macOS) `/etc/resolver/test` → local **dnsmasq** for wildcard subdomains. **Tailscale
MagicDNS** (`*.ts.net`) is a ready alternative naming/transport layer when present
(may not even need SSH-tunneled forwards) — offer it, but any non-SSH transport needs
its own mutual-auth story (§15 m8).

### 8.5 Auto-forwarding (copy VS Code)
Detection **process-based** (VS Code's default): agent reads `/proc/net/tcp(6)`
(Linux) / `GetExtendedTcpTable` for **both** AF_INET and AF_INET6 (Windows), maps
socket→PID→cmdline, emits `META.listening_ports`, removes the forward when the
process exits. Output-scan fallback where procfs is absent. **Preserve the port when
free.** Toast: "devbox:3000 available → Open / Always forward / Ignore."

### 8.6 Lifecycle on reconnect / user-created forwards
On reattach (§5.1 REATTACHING): forwards with `autostart:true` are re-established;
others move to `status:stopped` (need `+forward start`). **Auto-created** forwards
are removed on process exit; **user-created** forwards persist with `status:error`
until removed. Each forward has a **stable `id`** (since `listen` is mutable, §10).

### 8.7 Config schema (per-machine + per-port, mirrors VS Code `portsAttributes`)
```yaml
machines: { devbox: { host: devbox.example.com, loopback: 127.0.0.2, name: devbox.test } }
ports:
  "3000": { onAutoForward: openBrowser, label: web, protocol: http }
  "5432": { onAutoForward: silent }       # sensitive → never auto-expose
  default: { onAutoForward: notify }
```
Sidecar `~/.config/ghoztty/connections.json` (0600; **never** stores secrets; never
rewrites `~/.ssh/config` except an explicit, validated append path).

### 8.8 HTTPS/cert (deferred)
Local reverse proxy terminating TLS with the fixed hostname + **mkcert** local CA.
Port doesn't affect cert validation; hostname + HSTS are the hard parts. Out of v1.

---

## 9. Remote process management & visibility

### 9.1 Tracking — containment groups (pgid/ppid is leaky)
`setsid()` escapees + daemon double-fork orphans escape `kill(-pgid)`/ppid-walks.
Robust track-and-kill needs containment (inherited on fork, unaffected by `setsid`):
- **Linux:** each session in a **systemd scope** (cgroup v2); `cgroup.procs`
  enumerates, **`cgroup.kill`** (≥5.14) kills the subtree race-safely;
  `cpu.stat`/`memory.current` for accounting.
- **Windows:** **Job Objects.** Topology (per §13.4): the daemon (out-of-band, owns a
  job with `JOB_OBJECT_LIMIT_BREAKAWAY_OK`) `CreateProcess` the ConPTY child with
  `CREATE_BREAKAWAY_FROM_JOB` + `CREATE_NEW_PROCESS_GROUP`, then
  `AssignProcessToJobObject` into a **per-session containment job** (fall back to a
  nested job if the ConPTY child can't be reassigned). `TerminateJobObject` kills all;
  `QueryInformationJobObject` for accounting.
- **macOS:** no cgroups/jobs → `killpg` + recursive ppid tree-walk via
  `libproc`/`sysctl(KERN_PROC_ALL)`; CPU/RSS by summing `proc_pidinfo` (approximate —
  accept for the monitor view).

### 9.2 Kill / signal semantics
`+remote kill --target=<pane>` defaults to **kill the containment group**. `--pid=<n>`
targets one process; `--signal=TERM|KILL` with **TERM→KILL escalation after timeout**.
**Interactive interrupt** (`+send-keys C-c` / `SIGNAL{INT}`) is NOT a kill — on
Windows escalate: write `0x03` to ConPTY input (handles console-read case) →
`GenerateConsoleCtrlEvent(CTRL_C_EVENT, pgid)` (child in its own group) →
`TerminateJobObject` only for actual kill. POSIX: deliver the signal to the
foreground process group.

### 9.3 Per-session metadata (powers the activity view)
session/pane id, owning client, name; per process — pid/pgid/sid/ppid, foreground
flag (`tpgid`), state, start time, cmdline, cwd, CPU%/RSS, exit code, and **listening
ports owned by the session** (socket inode → `/proc/<pid>/fd`, or Windows
`GetExtendedTcpTable` scoped to the session's job PIDs). Pushed as `RPC_RESULT`
subscription notifications on an interval, not busy-polled.

### 9.4 cwd reporting
POSIX shells emit OSC 7. **Windows: the agent injects an OSC-9;9-emitting prompt** at
`OPEN` (mirrors the `ssh-cache` terminfo push) as the primary source — pwsh/cmd don't
emit it by default. **Injection safety (§15 NEW-2):** the injected prompt fragment is
a **fixed constant** that emits only `OSC 9;9;<$PWD>` where `$PWD` is expanded *by the
shell itself*, never by Ghoztty — no `+split --name`/host/cwd value is ever
interpolated into prompt code (a name like `$(rm -rf ~)` must be inert). Tested with
hostile names. PEB fallback (`NtQueryInformationProcess`, WOW64-aware, dynamically
loaded) is best-effort. Ghoztty's parser must learn **OSC 9;9** — and treat it, like
all remote OSC, as untrusted chrome input (§9.8).

### 9.5 Programmatic control + caller identity (security-critical)
JSON-RPC 2.0 over the `RPC` control frame (and the local daemon socket for in-pane
callers): `remote.list/tree/ps/stat/whoami/kill/signal`, `tunnel.*`, plus a
**subscribe** stream. A Unix socket at 0600 authenticates the *user*, not the *pane* —
and the threat here is **same-user** (the agent and the human share a UID), so an env
bearer token does NOT work: `GHOZTTY_RPC_TOKEN` in env is readable by any same-user
process via `/proc/<pid>/environ`, `ps eww`, etc., letting pane B impersonate pane A.
Instead:
- **Caller identity is kernel-derived, not a bearer secret.** The daemon reads the
  socket peer's PID via `SO_PEERCRED`/`LOCAL_PEERPID` (POSIX) /
  `GetNamedPipeClientProcessId` (Windows), then maps **PID → session via containment
  membership** the daemon itself controls (`/proc/<pid>/cgroup` / job membership) —
  unforgeable by the caller. **Re-validated at call time** (not connect time) to
  defeat PID reuse. (`GHOZTTY_PANE`/`GHOZTTY_CONNECTION` env, §9.6, remain for
  *self-identification* convenience, never for authorization.)
- **Default scope = the caller's own containment group** (observe + kill own
  subtree). `--pid`, cross-session targeting, or `--scope` beyond `pane` require an
  explicitly-granted capability (config and/or GUI confirmation).
- **`tunnel.*` gated separately** ("control" vs "observe"). **In-pane RPC may NOT
  create `-R` (remote) or `-D` (dynamic/SOCKS) forwards** (pivot/SSRF primitives) —
  those need explicit human action in the GUI/top-level CLI.
- **`tunnel --dest` is deny-by-default with a resolved-IP check at dial time:** resolve
  the name, canonicalize (handle decimal/hex IPs and IPv4-mapped IPv6 like
  `::ffff:169.254.169.254`), and **reject** if the result is in `127/8`, `::1`,
  `169.254/16`, `fe80::/10`, `fc00::/7`, known cloud-metadata v4/v6 (incl. IMDSv6), or
  `0.0.0.0`/`::`; **re-resolve-and-recheck on every reconnect** (DNS-rebinding
  defense). Name-based dests from in-pane callers are blocked unless the resolved IP
  passes. (`localhost`-on-remote services like a kube-apiserver are thus protected.)

### 9.6 AI-agent attribution (the headline use case) — local AND remote
So "Claude in a pane sees/kills what *it* spawned" works the same whether the pane is
local or remote (else the feature only works remotely, contradicting "indistinguishable
from local"):
- Each session's env carries `GHOZTTY_PANE=<session_uuid>` + `GHOZTTY_CONNECTION`
  (self-identification only, never authorization, §9.5). **Local panes get the same
  vars** injected by the GUI at spawn; their attribution/kill routes through the
  existing local IPC path (the GUI already owns the pane and its child pgid), so
  `whoami`/`ps --scope=pane`/`kill --scope=pane` are implemented for local panes too.
- `whoami` → `{pane, connection|null, host|"local"}` bootstraps an in-pane caller.
- `ps`/`+remote ps` take `--scope=pane|window|connection|host` (**default `pane` for
  the in-pane caller**, `host` for the GUI). Each `Process` carries `spawned_by_pane`
  (from the containment-group→session map). **`ps` never returns env** and redacts any
  `GHOZTTY_*` if env is ever surfaced (§15 NEW-1) — combined with §9.5's kernel-derived
  identity, there is no env-token to leak.
- `kill --scope=pane` (default for in-pane callers) kills only this pane's subtree —
  the safe self-cleanup an agent needs. `+remote signal --pid --signal=STOP|CONT|HUP`
  is the suspend/resume/reload (Process "UPDATE", §10).

### 9.7 Canonical JSON model (one model, every `--json` verb + the UI bind to it)
Normative. The Connection Manager sidebar is a live render of `remote.list`.
```jsonc
Connection { id, host, user, port, jump, name, color, group,
  status: "connected|degraded|reconnecting|reattaching|dead|saved",
  latency_ms, loopback, test_hostname, source: "config|sidecar|adhoc",
  windows: [Window], forwards: [Forward] }
Window  { id, title, connection_id, panes: [Pane] }          // flattened SplitTree leaves
Pane    { id, name, session_id, cwd, title, state: "idle|busy|needs_input",
  alive, foreground_cmd, owner_client, listening_ports: [int] }
Process { pid, pgid, sid, ppid, tpgid, foreground, state, cmdline, cwd,
  cpu_pct, rss, start_time, exit_code, listening_ports, spawned_by_pane }
Forward { id, type:"L|R|D", listen_addr, listen_port, dest, label, protocol,
  autostart, status:"active|stopped|error", process_pid, auto_created }
```
Every verb returns a subtree of this; the manifest (§7.2) and sidecar (§8.7) are
*persistence* shapes that hydrate it. **Nullability:** a `saved` connection (config,
not connected) has `windows:[]`, `forwards:[]`, `latency_ms:null`. A `dead` connection
keeps its last `windows` (panes flagged not-`alive`). **Ports relationship:**
`Process.listening_ports` is the source of truth (a process owns sockets);
`Pane.listening_ports` is the union over that pane's processes; a `Forward` may
*reference* one such port as its `dest`. `color` is any hex (`#rrggbb`) or a named
color from Ghoztty's existing palette.

### 9.8 Hostile-remote escape-injection policy (trusted chrome)
A compromised remote legitimately owns its `DATA` bytes, which flow into the **local**
VT parser — a trust boundary that crosses back to the user's machine. Therefore:
- **Trusted chrome is client-derived, never remote-derived.** The `machine:` title,
  the §11.3 status pill hostname, and the connection identity come from the **client's
  connection key**, NOT from remote OSC 7/OSC 9;9/title sequences. A remote-supplied
  title renders only in a clearly-delimited *untrusted* sub-field (so a prod box can't
  paint itself as a dev box).
- **OSC 52 clipboard write** from a remote is subject to the existing
  `ClipboardConfirmation` path (§11.6); **OSC 52 clipboard *read* is never answered**
  to a remote (no local-clipboard exfiltration).
- OSC/DCS/APC string lengths are capped; the hostile-remote escape corpus
  (OSC 52, title/cwd spoof, OSC 8 hyperlink spoof, oversized strings) is part of the
  §18 WP1 fuzz set, not just the framing decoder.

---

## 10. CLI command surface (CRUD)

New `Action` variants (`src/cli/ghostty.zig`) following the `Options` +
`parseManuallyHook` idiom (`src/cli/new_window.zig`). Because `+connect` registers a
`--target`/`--name` like `+new-window`/`+split`, **existing verbs (`+read`,
`+send-keys`, `+set-state`, `+split`, `+close`) work unchanged on remote panes.**

```bash
# --- Connections: CREATE / READ / UPDATE / DELETE ---
ghoztty +connect    --host=devbox --target=dev [--new-window] [--working-directory=~/p]
ghoztty +connect    --host=10.0.4.12 --user=deploy --port=22 --jump=bastion --name=prod --color=red
ghoztty +disconnect --target=dev            # detach ALL windows on the connection; sessions survive
ghoztty +reconnect  --target=dev
ghoztty +remote add    --host=gpu --user=me --addr=gpu.lab:2222 --group=Lab [--save-config]
ghoztty +remote edit   --host=gpu [--name=] [--user=] [--port=] [--jump=] [--color=] [--group=]  # UPDATE
ghoztty +remote list   [--json]             # global tree (all conns→windows→panes→forwards), §9.7
ghoztty +remote status --host=dev [--json]  # one Connection subtree
ghoztty +remote remove --host=gpu
ghoztty +remote import-ssh-config           # idempotent hydrate from ~/.ssh/config

# --- Remote windows/panes (reuse existing verbs; host-qualified names disambiguate) ---
ghoztty +split    --target=dev --name=server --command='npm run dev'
ghoztty +read     --name=dev/server --lines=20         # host-qualified form (§10.1)
ghoztty +send-keys --target=server "rs" Enter
ghoztty +rename   --target=dev --title='build box'     # window/pane UPDATE (existing verb)
ghoztty +close    --target=server           # CLOSE (frees the remote session)

# --- Remote processes (attribution-aware; works for local panes too, §9.6) ---
ghoztty +remote whoami  [--json]            # {pane, connection, host} for an in-pane caller
ghoztty +remote ps     --target=dev [--scope=pane|window|connection|host] [--json]
ghoztty +remote tree   --target=dev
ghoztty +remote signal --target=dev --pid=N --signal=STOP|CONT|HUP   # process UPDATE (suspend/resume/reload)
ghoztty +remote kill   --target=dev [--pid=N] [--signal=TERM] [--scope=pane]
ghoztty +remote logs   --host=dev           # agent/bootstrap diagnostics (deploy/version failures)
ghoztty +remote kill-daemon --host=dev      # explicit teardown / offboarding

# --- Port forwarding (stable --id; full CRUD) ---
ghoztty +forward add   --target=dev --type=local --listen=3000 --dest=localhost:3000 --autostart
ghoztty +forward list  --target=dev [--json]
ghoztty +forward edit  --target=dev --id=<id> [--listen=] [--dest=] [--label=] [--autostart=]  # UPDATE
ghoztty +forward start|stop --target=dev --id=<id>
ghoztty +forward remove --target=dev --id=<id>
ghoztty +forward open   --target=dev --id=<id>         # open in browser
```

### 10.1 Naming & flag conventions
Flat registry stays (idempotent focus-not-recreate). Optional **host-qualified form**
`--target=devbox/server` disambiguates when a local and remote pane share a name;
`+remote list` shows fully-qualified names; registration rejects ambiguous duplicates.
**`--host` vs `--target`:** `--host` addresses a **connection by its config identity**
(the `(host,user,port,jump)` key — used by `add`/`edit`/`status`/`remove`/`logs`/
`kill-daemon`); `--target` addresses a **live registered window/pane name** (used by
`connect`/`disconnect`/`reconnect`/`split`/`ps`/`kill`/`forward`). `+disconnect
--target` and `+reconnect --target` both resolve to and act on the whole connection
key (all its windows).

### 10.2 Error UX & exit codes
`0` ok · `2` usage · `10` connection-failed · `11` auth-failed · `12`
**host-key-mismatch** · `13` agent-deploy/version-failed · `14` port-conflict · `15`
target-not-connected · `16` capability-denied (in-pane RPC). The CLI prints a
one-line cause + hint. UI mapping in §11.7.

### 10.3 Forward edit semantics
A forward has a **stable `id`** (set at create, never changes). `+forward edit` of
mutable display fields (`label`, `protocol`, `autostart`) applies in place. Editing
`listen`/`dest` is a **rebind** (destroy+recreate the socket under the same `id`),
allowed only when the forward is `stopped`, or it transactionally tears down and
re-binds: on failure (port-conflict, exit 14) the **old binding is retained** and the
forward reports `status:error` — never left in an undefined state. Changing the host
part of `listen` may require provisioning a new loopback alias (§8.3). Lifecycle on
reconnect / auto- vs user-created: see §8.6.

### 10.4 Non-goals: moving a pane between connections / local↔remote (different
shell/cwd semantics) — future.

---

## 11. UI/UX

One `@Observable` Swift model (the §9.7 graph), mutated by IPC, rendered by UI and
CLI alike. **The Connection Manager is a live render of `+remote list --json`.**

### 11.0 First-run & empty states
Empty sidebar → CTA ("Connect to a machine…" + "Import from ~/.ssh/config"). The
first forward that needs a loopback alias triggers a **one-time guided install** that
explains the sudo prompt (§8.3). Primary discovery: a `Shell` menu item.

### 11.1 Connect flow — three entry points, one `.sheet`
Command palette (`⌘K`, fuzzy-match `~/.ssh/config`; `↵` new tab, `⌘↵` new window),
`Shell ▸ New Remote Connection…` (⇧⌘K), manager `+`. Sheet: searchable recents/config
+ manual fields (host/user/port/jump/key/name/color/group/working-dir/forwards), a
**live `ssh …` preview**, **☑ Save to ~/.ssh/config** / **☑ Auto-install terminfo**.

### 11.2 Connection Manager — docked sidebar (`⌘⇧E`)
`NavigationSplitView` + `OutlineGroup`. Tree **Group → Connection → {sessions, Ports}**
+ a "Saved (~/.ssh/config)" section. Row: status dot + live latency; `⋯` menu (Connect
in New Window / Disconnect / Reconnect / Edit / Manage Ports / Reveal in ssh config /
Remove).
```
┌─ REMOTE ─────────────────────┐  ● connected  ◌ reconnecting(pulse)  ○ disconnected  ⊗ error
│ ⌕ filter…               +    │  ⊟ session/pane   ↳ Ports
│ ▾ ● Production               │
│   ▾ ● prod-web-01   12ms ⋯  │
│       ⊟ deploy ~/app  pid…  │
│      ↳ Ports  3000→:3000 ●  │
│   ▸ ◌ gpu-box reconnecting  │
│ ── SAVED (~/.ssh/config) ── │
│   ○ ci-runner-3             │
└──────────────────────────────┘
```

### 11.3 In-window chrome
Title `machine: title`; connection color tints the tab/titlebar. **Status pill**
(titlebar accessory): `● prod-web-01 12ms ▾` → quick menu (Manage Ports / Reconnect /
Disconnect / Info). RECONNECTING: pill pulses amber; surface dims with a **non-modal**
"Reconnecting… (attempt N)" overlay (viewport restored exactly per §7.3; pre-attach
scrollback beyond the ring may show "(N lines lost)").

### 11.4 Ports panel — VS Code table + Termius live toggle
SwiftUI `Table`: Type / Listen / Destination / Process / State / Action, with
double-click or ▶/⏸ **live toggle without reconnecting**, open-in-browser + copy on
hover, **Auto-forward** toggle, per-forward **autostart**. Edits map to `+forward edit`.

### 11.5 Remote activity/kill view — the differentiator
Top: Ghoztty-owned **sessions** (closeable). Bottom: arbitrary **remote processes**
with CPU/MEM + **kill** (calls §9.2), with a `--scope` filter so the user can see
"this pane" vs "whole host". Ties into `+set-state` aggregation.

### 11.6 Implementation notes
Connect=`.sheet`; manager=docked sidebar `@Observable`; ports/activity=inline nodes +
`.sheet` `Table`; pill=`NSTitlebarAccessoryViewController`; reconnect overlay=non-modal
`ZStack`; latency on a background actor published ~1 Hz. New files under
`macos/Sources/Features/RemoteConnection/` (ClipboardConfirmation controller+view
pattern); status bar follows `ChildExitedMessageBar.swift`; `Settings/SettingsView`
(stub) gains a Remote section.

### 11.7 Error states (UI)
host-key-mismatch → **blocking diff dialog**, never auto-accept; auth-failed →
in-sheet retry with key picker; connection-failed → inline with retry; port-conflict →
inline field error + "use next free port"; agent-deploy-failed → diagnostic with
`+remote logs` hint; loopback-alias-missing → the §11.0 guided install.

---

## 12. Skill update

Extend `~/.claude/plugins/marketplaces/dzearing-claude-skills/skills/ghoztty/SKILL.md`
with a "Remote machines" section (all verbs + flags), and these **concrete patterns
(required)**:
- **Clean up after yourself (agent):** `remote.whoami` → `+remote ps --scope=pane` →
  `+remote kill --scope=pane`. The attribution path is mandatory or the agent use
  case fails.
- Full remote dev layout end-to-end (connect → split → split → forward → open).
- "Is my dev server up?": parse `+forward list --json` + `+remote ps --json`.
- `+close` (frees) vs `+disconnect` (detaches), worked example.
- A JSON-RPC snippet hitting the local daemon socket from inside a pane (identity is
  kernel-derived from the socket peer; the caller just connects and calls).
- The §10.2 exit-code table so scripts branch on `target-not-connected` (15).
- "Naming" note: `--target` resolves remote transparently; `host/name` disambiguates.
- "Common mistakes": `.local`/`.dev` pitfalls; killing by pane vs pid; capability
  scope for in-pane RPC.

---

## 13. Native Windows remote — setup & testing

### 13.1 ConPTY reattach (daemon owns HPCON forever; bridge is a pure relay)
You **cannot rebind a running child to a new ConPTY**; the HPCON + pipes belong to the
process that called `CreatePseudoConsole`. So the **daemon owns the HPCON permanently**
and the SSH bridge only shuttles framed bytes over the local named pipe (no ConPTY
handle migration; bytes are copied twice on Windows — acceptable). The agent maintains
a **grid model** (parse ConPTY output into cells) so reattach uses the §7.3
sequence-anchored snapshot, NOT raw ConPTY replay (ConPTY repaints on resize —
microsoft/terminal#15976/#7019; the snapshot path dodges it). DA/DSR/CPR replies
during a detached window are **agent-synthesized from the grid model**, never lost.

### 13.2 Install OpenSSH Server (elevated PowerShell)
```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd; Set-Service -Name sshd -StartupType Automatic
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 }
```

### 13.3 Key auth + non-admin requirement
```bash
scp ~/.ssh/id_ed25519.pub user@winbox:C:/Users/user/.ssh/authorized_keys
ssh -T user@winbox "echo ok"
```
> Non-admin users: `C:\Users\<user>\.ssh\authorized_keys`. Admin accounts use
> `C:\ProgramData\ssh\administrators_authorized_keys` (SYSTEM+Admins ACL). **Run the
> agent as a standard (non-admin) user — the agent refuses to run elevated** (§15 M6):
> elevation magnifies kill-any-process and privileged-port binding.

### 13.4 Job topology (containment + survival)
The daemon (launched out-of-band via Scheduled Task, §4.1) owns a job with
`JOB_OBJECT_LIMIT_BREAKAWAY_OK`. Per session: `CreateProcessW` the ConPTY child with
`CREATE_BREAKAWAY_FROM_JOB | CREATE_NEW_PROCESS_GROUP`, then `AssignProcessToJobObject`
into a per-session containment job (or nested job if reassignment is refused). This is
the *only* place breakaway is valid — because the daemon controls its own
BREAKAWAY_OK job, unlike sshd's.

### 13.5 Deploy & smoke test
```bash
zig build agent -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast   # also aarch64-windows-gnu
scp zig-out/bin/ghoztty-agent.exe user@winbox:C:/Users/user/ghoztty-agent.exe
ssh -T user@winbox "C:/Users/user/ghoztty-agent.exe attach --once --command=pwsh"  # binary/encoded stdio
```

### 13.6 Resumability check (daemon launched out-of-band survives sshd teardown)
```bash
ghoztty +connect --host=winbox --target=winbox --command='pwsh -NoExit'
ghoztty +send-keys --target=winbox "1..5 | %{ Start-Sleep 1; \$_ }" Enter
killall -9 Ghoztty-Debug 2>/dev/null
# relaunch debug app → winbox reattaches, counter running, snapshot redraw → confirms
# the daemon (Scheduled Task, NOT breakaway-from-sshd) survived teardown.
```

---

## 14. End-to-end test plan

Against `ssh localhost`, a Linux remote, and a Windows remote. Always
`zig-out/Ghoztty-Debug.app` (**never touch `/Applications/Ghoztty.app`**).
1. Spawn → `H: <title>`, `hostname` confirms. 2. Split inheritance (parent cwd).
3. New-window inheritance. 4. `+send-keys`/`+read`/`+set-state` parity.
5. Tunnel same-port → `curl http://H.test:3000`; click `localhost:3000` → `H.test`.
6. Two-remote coexistence on `:3000`. 7. **Reattach (daemon alive)**: `kill -9` GUI →
relaunch → panes reattach, viewport exact, "(N lines lost)" only if past ring.
8. **Recovery per-session**: kill one session while detached → that pane shows
"exited (N)"/re-run gate while siblings reattach. 9. **`^C` under flood**: run `yes`
in one pane → `^C` in another stays fast (control channel + shallow buffer); stress a
deep TCP buffer too. 10. Drop/reconnect (`pkill ssh`) → backoff → resume.
11. **Steal**: attach same session from a 2nd client → `--force` → first gets
`DETACHED`, a stale keystroke from it never reaches the PTY (epoch fence). 12.
**Latency** (Network Link Conditioner) → badge yellow/red, typing usable, no echo
artifacts. 13. **Process mgmt**: spawn a `setsid` daemon → `+remote ps` lists it →
`+remote kill --target=pane` (container) reaps it. 14. **Attribution (local + remote)**:
from inside a pane, `remote.whoami` + `+remote ps --scope=pane` shows only this pane's
children on BOTH a local and a remote pane; `--scope=host` requires capability.
15. **Capability**: in-pane `tunnel.add --type=R`/`--type=D` denied (16); `--dest` to a
metadata IP denied; another same-user pane cannot kill this pane's children.
16. **Teardown**: `+close` frees; GUI quit only detaches. 17. **Fidelity**: run `vim`
remotely (TERM/terminfo); mouse-report + bracketed paste work; OSC 52 copy from remote
prompts confirmation; a hostile `printf` of an OSC-7/title escape does NOT change the
trusted `machine:` chrome. 18. **Revocation**: remove the key from remote
`authorized_keys` → daemon reaps that principal's sessions within the interval.
19. **Windows-specific**: binary/encoded stdio fidelity (all 256 bytes); daemon
survives sshd teardown; pipe `FIRST_PIPE_INSTANCE` rejects a squatter; OSC 9;9 cwd;
Job-Object kill.

---

## 15. Security model (enforced invariants, not assertions)

- **Transport:** all over SSH; no public listener/CA/credential store. Daemon
  endpoints local-only (Unix 0600 / named-pipe owner-only DACL + reject-remote).
  Agent runs as the user (non-admin on Windows; refuses elevation).
- **Supply chain (C1) — stated boundary, not a false claim:** agent ships in the
  signed app bundle (only source; **no network fetch / "newer-wins"**); client pushes
  its own bytes every connect to a client-controlled `0700` path; absolute-path
  invoke. **We do NOT claim remote integrity attestation** — a read-back or
  self-reported hash is produced by the (possibly hostile) host and is circular. The
  real boundary: **remote-account compromise = full compromise of that host's
  sessions, undetectable from the client.** Enforceable client-side property =
  *downgrade protection* (refuse to replace a newer-or-equal deployed agent). Gated
  auto-redeploy (§7.5).
- **In-pane RPC (C2) — kernel identity, not a bearer token:** an env token is
  readable by any same-user process (`/proc/<pid>/environ`), so caller identity is
  **kernel-derived** — socket peer PID (`SO_PEERCRED`/`GetNamedPipeClientProcessId`)
  → containment-membership → session, **re-validated at call time** (PID-reuse).
  Default scope = caller's own container; `--pid`/cross-session/`--scope>pane` need
  explicit capability; **`tunnel.*` gated; `-R`/`-D` forbidden from in-pane RPC**;
  `--dest` **deny-by-default with resolved-IP check at dial time** (canonicalize
  encoded IPs + v4-mapped-v6; block loopback/link-local/`fc00::/7`/metadata incl.
  IMDSv6; re-resolve per reconnect for DNS-rebinding). `ps` never returns env;
  `GHOZTTY_*` redacted (NEW-1).
- **Untrusted frames (M3):** client bounds-checks `len` (incl. **decoded** length for
  COBS/base64, NEW-3), validates snapshot dims, verifies channel/session ownership.
  **Escape injection (M3+):** trusted chrome (`machine:`, status pill, cwd) is
  client-derived not remote-OSC-derived; OSC 52 write gated, read never answered;
  OSC/DCS capped; fuzz the hostile-remote escape corpus (§9.8).
- **Persistence/revocation (M4) — a real mechanism:** the daemon **re-reads
  `authorized_keys` on an interval + each attach and self-terminates sessions whose
  creating principal's key was removed** (offboarding/rotation actually stops work).
  Concrete caps: 64 sessions, 256 MB rings, 24 h idle TTL, 10 min tombstone; daemon
  under its own cgroup/job; **core dumps disabled**. Prefer `setsid` over an installed
  service (EDR-flagged persistence — service is opt-in + easily removable).
  `+remote kill-daemon` for explicit teardown.
- **Loopback is NOT per-user on macOS (M5):** any local UID can reach `127.0.0.x`
  forwards. **Sensitive forwards default to a `SO_PEERCRED`-checked Unix-domain socket
  in a `0700` dir** (not a raw TCP loopback port); sensitive ports (5432…) default
  `onAutoForward: silent`; SOCKS (`-D`) off by default, explicit-confirm, never via
  in-pane RPC.
- **Secrets at rest (m7):** `OPEN.env` allowlist; rings **memory-only by default**
  (and daemon core-dumps disabled, since rings hold raw output); `+read` over a ring
  is subject to §9.5 scoping; sidecar stores no secrets.
- **Host verification (m8):** no host-key bypass anywhere — every `ProxyJump` hop,
  agent redeploy, terminfo push. Never inject `StrictHostKeyChecking=no`/`accept-new`,
  **`UserKnownHostsFile=/dev/null`, or `CheckHostIP=no`**. Non-SSH transports
  (Tailscale) need their own mutual auth.
- **Injection (m9):** manifest 0600; re-run gate uses **`execv` (argv), never
  `sh -c`**; strict structured validation before any `~/.ssh/config` append and at the
  CLI layer (reject newlines and `-`-prefixed values that could become ssh flags).
- **Steal is SSH-account-scoped (NEW-4):** `--force` steal is a session-hijack
  primitive on a shared key; every steal is audited/surfaced; sensitive deployments
  can require a confirmation token (§5.3).

---

## 16. Phasing
- **P1 — core remote panes:** WP1–WP4 (protocol, agent MVP w/ grid model +
  out-of-band daemon, client+backend+C API, Swift connection context). Good path +
  basic reattach over `ssh localhost`/Linux. **Includes TERM/terminfo (§6.5)** — P1's
  "good path" demo must run `vim` remotely, so it can't be deferred.
- **P2 — resilience + tunneling + process mgmt:** WP5/WP6/WP8 (sequence-anchored
  resync + recovery tiers, tunneling, containment-group process mgmt + attribution +
  kernel peer-cred identity + capability grants, §9.5).
- **P3 — UI + Windows + polish:** WP7/WP9 (manager, ports/activity UI), WP2-Windows
  hardening, WP10 (skill/docs/CI/e2e). v2 items (predictive echo, state-diff resync,
  UDP roaming, HTTPS proxy) follow.

## 17. Risks & open questions (post-review)
- **Windows binary stdio (blocker):** validate raw vs encoded framing through
  `ssh-shellhost` in the WP2 spike *first*; default to COBS/base64 if raw is unsafe.
- **Windows daemon survival (resolved → verify):** Scheduled Task / Service, NOT
  breakaway-from-sshd; confirm in the spike.
- **Job topology (verify):** daemon-owned BREAKAWAY_OK job + ConPTY-child reassign /
  nested job — verify in the spike.
- **`Command.zig` headless refactor:** extract a lean `CommandCore` (drop
  `config.zig`/`global.zig`/`apprt` deps; pass `ResourceLimits` in) so the agent
  doesn't pull the renderer/font graph. ~2–4 h, WP2 prep.
- **macOS loopback alias** needs sudo + LaunchDaemon (guided first-run); Tailscale as
  alternative.
- **Snapshot scrollback bound** — decide ring size / acceptable truncation message.
- **Cross-pane HOL — resolved by design** via per-channel inbound rings drained on each
  pane's own IO thread (§3.4 mini-spec). This is the **most novel concurrency code and
  is gated by its own spike + benchmark** (4-pane window, one flooding pane, no
  input-latency regression on the quiet panes) BEFORE WP3 fans out — rank it with the
  Windows spikes, not as a closing bullet.
- **Interactive SSH auth / first-contact host keys (§4.1)** is a day-1 user wall —
  passphrase/2FA prompts and first-contact fingerprint confirmation must surface in the
  GUI via `SSH_ASKPASS`. Specify/validate before WP4.
- **Versioned wire handshake (`HELLO`, §4.2)** is the shared contract across WP1/WP2/
  WP3 — pin proto-version + transfer-encoding + capabilities in WP1 before fan-out.
- **Control responsiveness under flood** is bounded by shallow socket buffers, not
  hard-guaranteed (shared TCP, §4.3). If `^C`-under-adversarial-flood must be
  guaranteed, add a separate TCP connection for control (deferred).
- **macOS process accounting** without cgroups is approximate — acceptable for the
  monitor view? Decide.
- **Predictive echo deferred** — ensure v1 transport doesn't preclude the v2
  server-side grid model (it doesn't — the agent already keeps one per §7.1).

---

## 18. Work packages (worktree-fannable)

Order: **WP1 → {WP2, WP3} → WP4 → {WP5, WP6, WP8} → {WP7, WP9} → WP10.**

- **WP1 — Protocol lib (Zig, pure).** `src/remote/protocol.zig`: the **`HELLO`
  version/encoding/capability handshake** (the shared contract — pin first), frames
  (§4.2), dual seq spaces, COBS/base64 transfer encoding (decoded-length bound),
  JSON-RPC envelope (§9.5), flow primitives. Round-trip + fuzz (incl. hostile-agent +
  malformed-encoding + escape-injection corpora for the client decoder).
- **WP2 — Agent daemon (Zig; Linux + Windows).** `src/remote/agent/` →
  `ghoztty-agent`. **Prep:** `Command.zig`→`CommandCore` refactor (§17). Out-of-band
  daemonize (setsid/double-fork | Scheduled Task), local endpoint (0600 / DACL'd
  pipe), binary/encoded stdio, session table (random UUIDs, **grid model**, ring,
  tombstones, TTL/caps), OPEN/ATTACH(seq-anchored snapshot)/DATA/RESIZE/SIGNAL/DETACH/
  CLOSE/EXIT/META, containment groups (cgroup/job/pgid), OSC 9;9 prompt injection,
  port scan, TUNNEL dial, JSON-RPC + peer-cred identity / containment-membership map +
  capability grants + attribution env.
  **De-risk first:** Windows stdio-fidelity + out-of-band-survival + job-topology
  spike.
- **WP3 — Client connection + `termio.Remote` + C API.** `src/remote/connection.zig`
  (ssh spawn w/ `SSH_ASKPASS` interactive-auth + first-contact host-key flow §4.1,
  **two channels**, MPSC writer, demux reader, **per-channel inbound ring per the §3.4
  mini-spec — GATED by its own spike+benchmark first**, heartbeat/RTT, reconnect SM,
  steal w/ epoch fence) + `src/termio/Remote.zig`; extend `backend.zig`; **plumb new
  `ghostty_surface_config_s` fields + branch `Surface.zig:682` + `:1340`**; C API
  `ghostty_remote_*`. Headless test over `ssh localhost`.
- **WP4 — Swift connection context.** connection-key model, `machine:` title,
  `+connect/+disconnect/+reconnect`, `+rename`, split/new-window inheritance,
  host-qualified names; verify `+send-keys`/`+read`/`+set-state` unchanged; `+list`
  carries `connection` (cwd via OSC 7/9;9). **pid/tty are null until WP8** supplies
  agent metadata — don't block WP4 on it.
- **WP5 — Manifest + resumability.** manifest (v1), restore-on-launch, ATTACH-by-UUID,
  sequence-anchored snapshot redraw, per-session recovery tiers + re-run gate;
  `+close`⇒CLOSE vs quit⇒DETACH; gated auto-redeploy.
- **WP6 — Tunneling.** loopback provisioning (macOS LaunchDaemon / Linux noop /
  Windows fallback), `.test` resolution, same-port forwarding, process-based
  auto-discovery + toast, connection-aware URL rewrite, config schema, `+forward`
  CRUD (stable ids), lifecycle-on-reconnect.
- **WP7 — Connection Manager UI.** sidebar, connect sheet, status pill, reconnect
  overlay, latency badge, first-run/empty states, error states (§11.7).
- **WP8 — Process mgmt + RPC.** containment-group kill, `+remote ps/tree/kill/whoami`,
  `--scope`, attribution (`GHOZTTY_PANE`/`spawned_by_pane`), metadata collection,
  capability grants (kernel peer-cred, §9.5), subscribe stream.
- **WP9 — Ports + Activity UI.** ports table (live toggle), activity/kill view w/
  scope filter.
- **WP10 — Skill, docs, CI, Windows harness, e2e.** SKILL.md (§12), cross-compile
  targets, §14 e2e wired to CI, validated on a real Windows host.
```
