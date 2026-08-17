//! `ghoztty-agent` entry point (WP2, §4.1–§4.2/§7.1) — the remote-host daemon.
//!
//! Four transport modes share the SAME session-server core (`server.zig`, real
//! pty-backed children via `pty_child.zig`) and the SAME lane mux (`mux.zig`):
//!
//!   1. **stdio** (`--stdio`, or the default when stdin is not a tty / no listen
//!      addr): read framed protocol from stdin, write to stdout. This is the
//!      `ssh host -- ghoztty-agent` path (§4.1). One stdin/stdout pipe pair, both
//!      logical lanes muxed onto it. Shuts down on stdin EOF (client hung up).
//!
//!   2. **TCP listen daemon** (`--listen <addr:port>`, loopback by default;
//!      non-loopback needs `--insecure-allow-public`): bind, listen, then loop —
//!      accept a connection and serve it on its OWN thread (a `Mux` + `Server`
//!      over the socket, sharing the daemon-scoped session store), so the accept
//!      loop NEVER blocks on one connection's lifecycle. UNAUTHENTICATED — a
//!      local/dev harness only (the authenticated path is `--relay`).
//!
//!   2b. **Unix-socket listen daemon** (`--listen-unix <path>`, POSIX-only): the
//!      SECURE local transport for session persistence (design §5.2). Same
//!      accept→serve→loop core as the TCP path, but bound to a 0600 AF_UNIX
//!      socket (created that way race-free via umask) and gated with a
//!      per-connection `getpeereid` same-uid check — so, unlike a 127.0.0.1 TCP
//!      port that ANY local uid can connect to, only this user can reach the
//!      shell. A stale socket node from a prior run is unlinked only after a
//!      connect-probe confirms nothing live is listening. This is what the macOS
//!      app spawns for local persistent windows (Windows uses 2c below).
//!
//!   2c. **Named-pipe listen daemon** (`--listen-pipe <\\.\pipe\name>`,
//!      Windows-only, T89c): the SECURE local transport on Windows — the same
//!      accept→serve→loop core, bound to a named pipe created with an
//!      owner-only DACL (the stand-in for 2b's same-uid peercred gate) +
//!      PIPE_REJECT_REMOTE_CLIENTS. FILE_FLAG_FIRST_PIPE_INSTANCE makes the
//!      bind double as the stale/live probe (a dead holder's pipe name simply
//!      stops existing). This is what the Windows app spawns for local
//!      persistent windows.
//!
//!   3. **Relay daemon** (`--relay <url>`): the single-binary rendezvous path (no
//!      Go sidecar, no inbound port). Hold an authenticated `wss://` control
//!      WebSocket to the relay; on each `{"type":"open","session":S}` command,
//!      dial a per-session data WebSocket and serve it over the SAME `serveOne`
//!      core (shared store) as an accepted socket. The device token is read from
//!      `GHOSTTY_DEVICE_TOKEN`, falling back to the agent's persisted
//!      `relay.env` (see `enroll.zig`); relay.env is then WATCHED so a
//!      re-enroll's new token is adopted without a restart (`relay_creds.zig`).
//!      With NO credential anywhere, an interactive (non-`--headless`) launch
//!      runs the browser enrollment INLINE on first run and then continues into
//!      the connect loop — the MSI Start-Menu / Run-key launch is exactly
//!      `ghoztty-agent --relay=<base>` (see `decideRelayCred`); `--headless`
//!      keeps the explicit "run --enroll first" error.
//!      Reconnects with backoff on a control
//!      drop (sessions survive). Coexists with — does not replace — `--listen`.
//!
//! Plus one one-shot utility mode: `--enroll --relay <url>` runs the OAuth
//! self-enrollment (`enroll.zig`) — opens the owner's browser to approve the
//! sign-in (Tailscale-style), falling back to the device-code "visit URL,
//! enter code" flow when the relay offers no web client or
//! `--no-browser`/`--headless-enroll` is passed — and persists the issued
//! device credential to `relay.env`, after which `--relay <url>` just works.
//!
//! ### SESSION SURVIVAL (P1, §7.1) — the close-laptop scenario
//! The session table + pty children + output rings live in a DAEMON-scoped
//! `SessionStore` that OUTLIVES any connection. When a client disconnects, its
//! per-connection `Server` is torn down but its sessions are merely DETACHed
//! (output keeps flowing into their rings); they are NEVER terminated on a mere
//! drop. A reconnecting client `ATTACH`es by session id with its last byte offset,
//! and the agent replays the ring gap `(last_byte_offset, S]` — catching the client
//! up to everything the remote produced while it was gone — then resumes live
//! streaming. Orphaned sessions are reaped by a background idle-TTL thread
//! (`session.default_idle_ttl_ms`, 24 h — long enough to survive a closed
//! laptop lid overnight) so abandoned shells don't leak forever.
//!
//! ### SECURITY
//! The `--relay` path is authenticated end to end (per-device bearer token, and
//! the relay enforces account ownership). The `--relay` mode is the ONLY way a
//! customer install brings a machine online (the MSI/installer autostart it with
//! `--relay=<url>`).
//!
//! The TCP `--listen` path is **unauthenticated**: any host that can reach the
//! port can open a shell. It exists for local/dev use only and is guarded:
//!   - a bare invocation (no args) does NOT listen — it prints usage and exits;
//!   - `--listen` may bind loopback (`127.0.0.1`/`::1`) freely;
//!   - binding a NON-loopback interface requires the explicit
//!     `--insecure-allow-public` opt-in and prints a loud warning.
//! So an unauthenticated shell can never be exposed to the network by accident.
//!
//! The `--listen-unix` path is the hardened LOCAL alternative: a filesystem
//! socket is never network-reachable, is created 0600 (no group/other access),
//! AND every accepted connection is admitted only if `getpeereid` reports the
//! peer's uid equals ours (an unreadable credential is rejected — a shell is
//! never served to an unauthenticated peer). This is the transport the app uses
//! for local session persistence.
//!
//! ## Transport over a single byte channel
//! The wire design (§4.3) uses two logical lanes — control + data, each a
//! `server.Stream`. Both modes have only ONE underlying byte channel (a pipe pair
//! or a socket), so `mux.Mux` folds both lanes onto it (DATA → data lane, else →
//! control lane). The `Server`'s two reader threads consume their lanes unchanged.
//!
//! ## Deferred (this increment)
//!   - A real grid-model snapshot on ATTACH (§7.3): `snapshot_at_offset` is the
//!     current outbound offset and resync replays the raw ring from there. Exact-
//!     grid reconstruction (so deep-scrollback eviction is invisible) is future.
//!   - Authentication / TLS on the listener (see SECURITY above).
//!   - Daemonization / detach (§4.1). (Single-instance IS enforced: the daemon
//!     modes `--listen`/`--relay` take a per-USER guard — Global\ named mutex
//!     keyed by SID on Windows, flock on POSIX — and a losing instance exits
//!     with code 183 after verifying the holder is alive via its heartbeat
//!     file; a stuck holder is killed and replaced, and `--force-replace`
//!     (alias `--replace`) replaces even a healthy one. See
//!     `single_instance.zig`. `--stdio` and `--enroll` are exempt.)
//!   - RPC, tunnels, multi-client fan-out to one session (§5.3 steal).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const protocol = @import("../protocol.zig");
const server = @import("server.zig");
const session = @import("session.zig");
const pty_child = @import("pty_child.zig");
const pty_host = @import("pty_host.zig");
const pty_host_spec = @import("pty_host_spec.zig");
const pty_host_smoke = @import("pty_host_smoke.zig");
const holder_adopt = @import("holder_adopt.zig");
const handoff = @import("handoff.zig");
const mux_mod = @import("mux.zig");
const socket_stream = @import("../socket_stream.zig");
const pipe_stream = @import("../pipe_stream.zig");
const ws_client = @import("../ws_client.zig");
const tray = @import("tray.zig");
const tray_account = @import("tray_account.zig");
const enroll = @import("enroll.zig");
const atomic_write = @import("atomic_write.zig");
const keepalive = @import("keepalive.zig");
const link_control = @import("link_control.zig");
const relay_creds = @import("relay_creds.zig");
const sharing = @import("sharing.zig");
const adopt = @import("adopt.zig");
const self_update = @import("self_update.zig");
const single_instance = @import("single_instance.zig");
const agent_lineage = @import("../agent_lineage.zig");

/// The agent's baked build version: `YYYYMMDD-<git short hash>` (commit date),
/// or `"dev"` when git was unavailable at build time. Stamped by
/// `src/build/GhosttyAgent.zig` through the `agent_build_options` module
/// (`-Dagent-version=` overrides). Shown by `--version`, the startup banners,
/// and the tray About line, and compared against the relay's
/// `/dl/version.json` by the self-updater (`self_update.zig`) — dev builds
/// never self-update.
const agent_version: []const u8 = @import("agent_build_options").agent_version;

/// The private handoff pipe a retiring agent named on our command line (T907),
/// in a process-lifetime buffer: `parseArgs` frees `args` before the listen path
/// runs, and this value has to outlive that. Empty ⇒ we are an ordinary launch.
var handoff_pipe_buf: [256]u8 = undefined;
var handoff_pipe_len: usize = 0;

/// The private handoff pipe, or null when this agent was not spawned as a
/// successor (every launch but the one at the end of a handoff).
fn handoffSuccessorPipe() ?[]const u8 {
    return if (handoff_pipe_len == 0) null else handoff_pipe_buf[0..handoff_pipe_len];
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Clear the inherited ignore-Ctrl-C flag (T84 / T89d). The Windows local
    // agent is spawned DETACHED with CREATE_NEW_PROCESS_GROUP, which disables
    // ^C delivery for this process AND every child — so every ConPTY session
    // the agent opens would inherit a shell where ctrl+c never interrupts
    // native children. Re-enable it here, before any session child is spawned,
    // exactly as the GUI does at `App.init`. A NULL handler with Add=FALSE
    // removes the "ignore" entry without disturbing the graceful-stop handler
    // registered later (`startConsoleCtrlWatcher`).
    if (builtin.os.tag == .windows) _ = SetConsoleCtrlHandler(null, std.os.windows.FALSE);

    // The transfer encoding is fixed at construction (the client pins it in HELLO).
    // Default to raw; `GHOZTTY_AGENT_ENCODING` overrides it (deterministic tests).
    const encoding = encodingFromEnv(alloc);

    const mode = try parseArgs(alloc);

    // Ring size (T11): the `--ring-bytes` flag (resolved in parseArgs) wins; else
    // fall back to GHOSTTY_AGENT_RING_BYTES. Resolved once here, read-only after.
    if (!ring_bytes_from_flag) {
        if (std.process.getEnvVarOwned(alloc, "GHOSTTY_AGENT_RING_BYTES")) |v| {
            defer alloc.free(v);
            if (parseRingBytes(v)) |n| configured_ring_bytes = n;
        } else |_| {}
    }

    // Live-session cap (T469), same precedence: flag wins, else the env var.
    // Resolved here, before any `SessionTable` exists, and read-only after.
    if (!max_sessions_from_flag) {
        if (std.process.getEnvVarOwned(alloc, "GHOSTTY_AGENT_MAX_SESSIONS")) |v| {
            defer alloc.free(v);
            if (parseMaxSessions(v)) |n| session.configured_max_sessions = n;
        } else |_| {}
    }

    // Capability suppression (T469 test seam): make this build advertise the
    // HELLO of an OLDER agent, so an acceptance script can watch a capability's
    // fallback happen for real instead of only in a unit test. Copied into the
    // Server's own storage, so the env value need not outlive this scope.
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_AGENT_SUPPRESS_CAPS")) |v| {
        defer alloc.free(v);
        server.Server.suppressCapabilities(v);
        std.log.warn("advertising a REDUCED capability set (suppressed: {s})", .{v});
    } else |_| {}

    switch (mode) {
        .version => {
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "ghoztty-agent {s}\n", .{agent_version}) catch "ghoztty-agent\n";
            std.fs.File.stdout().writeAll(line) catch {};
        },
        .usage => printUsage(),
        .stdio => try runStdio(alloc, encoding),
        .listen => |l| {
            // Keep the GPA exit clean on the (error) paths where runListen returns.
            defer if (l.port_file) |pf| alloc.free(pf);
            defer if (l.sessions_file) |sf| alloc.free(sf);
            // Graceful SIGTERM → ring snapshot (T13b): block SIGTERM on the main
            // thread BEFORE the single-instance heartbeat (or ANY daemon thread)
            // is spawned so they all inherit the block; the watcher that consumes
            // it is started inside runListen once the store exists. POSIX-only.
            blockSigterm();
            // DAEMON mode: enforce single-instance BEFORE anything user-visible
            // (bind, banner, tray icon). Exits the process on conflict.
            // TCP listen keeps the legacy (relay) guard identity — only the
            // local persistence transport (`--listen-pipe`) takes a distinct
            // instance key (T89d1).
            var lock = acquireDaemonLockOrExit(alloc, l.force_replace, daemonInstance(.relay));
            defer lock.release();
            try runListen(alloc, encoding, l.addr, l.headless, l.public, l.port_file, l.sessions_file);
        },
        .listen_unix => |l| {
            defer alloc.free(l.path);
            defer if (l.port_file) |pf| alloc.free(pf);
            defer if (l.sessions_file) |sf| alloc.free(sf);
            // AF_UNIX listen is POSIX-only (Windows persistence is a named
            // pipe, §5.2); listenUnixMode rejects it at parse time, and this
            // comptime gate keeps the UDS code out of Windows analysis
            // (std.net.Address.initUnix does not compile for windows targets).
            if (builtin.os.tag == .windows) unreachable;
            // Graceful SIGTERM → ring snapshot (T13b): block SIGTERM on the main
            // thread BEFORE any daemon thread is spawned (see the `.listen` arm).
            blockSigterm();
            // DAEMON mode: single-instance BEFORE the bind (a losing instance
            // must not clobber the winner's socket node). POSIX `--listen-unix`
            // stays on the legacy guard for now — the analogous local/relay
            // collision is a latent Mac bug flagged for the Mac seat (T89d1);
            // this branch's lane is Windows.
            var lock = acquireDaemonLockOrExit(alloc, l.force_replace, daemonInstance(.relay));
            defer lock.release();
            try runListenUnix(alloc, encoding, l.path, l.headless, l.port_file, l.sessions_file);
        },
        .listen_pipe => |l| {
            defer alloc.free(l.name);
            defer if (l.port_file) |pf| alloc.free(pf);
            defer if (l.sessions_file) |sf| alloc.free(sf);
            // Named-pipe listen is Windows-only (the POSIX local transport is
            // --listen-unix); listenPipeMode rejects it at parse time, and this
            // comptime gate keeps the pipe daemon code out of POSIX analysis.
            if (builtin.os.tag != .windows) unreachable;
            // HANDOFF SUCCESSOR (T907): a running agent spawned us to replace it.
            // Report READY over its private pipe and block until it says GO —
            // which it only does once it has snapshotted its rings and is about
            // to exit. Everything destructive is on the far side of this call:
            // we take no single-instance guard and bind nothing public until it
            // returns, so a predecessor that changes its mind (or a successor
            // that cannot start) leaves the ORIGINAL agent serving untouched.
            if (handoffSuccessorPipe()) |p| {
                handoff.awaitGo(alloc, p) catch |err| {
                    std.debug.print(
                        "ghoztty-agent: handoff: predecessor did not hand over ({s}); exiting without binding anything\n",
                        .{@errorName(err)},
                    );
                    return err;
                };
            }
            // DAEMON mode: single-instance BEFORE the bind (a losing instance
            // must not race the winner for the pipe name). This is THE local
            // session-persistence agent, so it takes the DISTINCT `local[-debug]`
            // guard (T89d1) — it must coexist with a `--relay` agent, which
            // holds the legacy guard.
            var lock = acquireDaemonLockOrExit(alloc, l.force_replace, daemonInstance(local_instance_base));
            defer lock.release();
            try runListenPipe(alloc, encoding, l.name, l.headless, l.port_file, l.sessions_file);
        },
        .relay => |r| {
            // DAEMON mode: single-instance first (before the token lookup, long
            // before the tray could flash an icon — and before a first-run
            // auto-enroll could pop a browser from a doomed duplicate). The
            // relay agent keeps the legacy guard identity (unchanged by T89d1).
            var lock = acquireDaemonLockOrExit(alloc, r.force_replace, daemonInstance(.relay));
            defer lock.release();
            // The device token authenticates the relay WebSockets. Required.
            // Precedence: the GHOSTTY_DEVICE_TOKEN env var wins; otherwise fall
            // back to the agent's own relay.env (written by `--enroll` and by
            // the Windows installer), so enroll → run needs no env plumbing.
            // With NO credential anywhere the policy is `decideRelayCred`'s:
            // interactive launches self-enroll inline, `--headless` errors.
            // The SOURCE travels along: a relay.env sourced token may be hot-
            // reloaded on a re-enroll, an env-sourced one never is (see
            // `relay_creds.zig`).
            const TokenInit = struct { token: []u8, source: relay_creds.Source };
            const env_token: ?[]u8 = std.process.getEnvVarOwned(alloc, "GHOSTTY_DEVICE_TOKEN") catch null;
            const file_token: ?[]u8 = if (env_token == null) enroll.loadDeviceToken(alloc) else null;
            const ti: TokenInit = switch (decideRelayCred(env_token != null, file_token != null, r.headless)) {
                .use_env => .{ .token = env_token.?, .source = .env },
                .use_relay_env => .{ .token = file_token.?, .source = .relay_env },
                .fail => {
                    std.debug.print(
                        "ghoztty-agent: --relay needs a device token: set GHOSTTY_DEVICE_TOKEN " ++
                            "or enroll this machine first with `ghoztty-agent --enroll --relay=<base>`\n",
                        .{},
                    );
                    // This relay-mode path returns (runRelay loops forever),
                    // so free the duped URL to keep the GPA exit clean.
                    alloc.free(r.base_url);
                    return error.MissingDeviceToken;
                },
                .auto_enroll => blk: {
                    const t = autoEnrollForRelay(alloc, r.base_url) catch |err| {
                        alloc.free(r.base_url); // keep the GPA exit clean, as above
                        return err;
                    };
                    break :blk .{ .token = t, .source = .relay_env };
                },
            };
            // Token ownership moves into runRelay's `Creds` (it must stay
            // alive as long as any connection borrows a snapshot of it).
            try runRelay(alloc, encoding, r.base_url, ti.token, ti.source, r.headless);
        },
        .pty_host => |p| {
            // Per-session ConPTY holder (T904): no daemon lock — one holder per
            // session, and its pipe bind (FIRST_PIPE_INSTANCE) is the guard.
            defer {
                alloc.free(p.session_id);
                if (p.pipe) |v| alloc.free(v);
                if (p.cwd) |v| alloc.free(v);
                if (p.command) |v| alloc.free(v);
                if (p.shell) |v| alloc.free(v);
                if (p.spec) |v| alloc.free(v);
            }
            // `--spec` (T905): the agent staged the whole OPEN in a file. Read
            // it — which also DELETES it, so a session's forwarded environment
            // never outlives the spawn it configured — and let it supply every
            // parameter. The parsed arena must outlive `run`, which owns the
            // session for the holder's whole life.
            var parsed_spec: ?pty_host_spec.Parsed = null;
            defer if (parsed_spec) |ps| ps.deinit();
            if (p.spec) |path| {
                parsed_spec = pty_host_spec.readAndDelete(alloc, path) catch |err| {
                    std.debug.print("ghoztty-agent: cannot read --spec '{s}': {s}\n", .{ path, @errorName(err) });
                    return err;
                };
            }
            if (parsed_spec) |ps| {
                const s = ps.value;
                try pty_host.run(alloc, .{
                    .session_id = s.session_id,
                    .pipe_name = s.pipe_name,
                    .replay_bytes = s.replay_bytes,
                    .exit_linger_ms = s.exit_linger_ms,
                    .open = s.open,
                    .stamp = agent_version,
                });
                return;
            }
            try pty_host.run(alloc, .{
                .session_id = p.session_id,
                .pipe_name = p.pipe,
                .rows = p.rows,
                .cols = p.cols,
                .cwd = p.cwd,
                .command = p.command,
                .shell = p.shell,
                .replay_bytes = p.replay_bytes,
                .exit_linger_ms = p.exit_linger_ms,
                .stamp = agent_version,
            });
        },
        .pty_host_smoke => try pty_host_smoke.run(alloc),
        .enroll => |e| {
            // Self-enroll (browser-first, device-code fallback): register this
            // machine (by its hostname) under the owner's account and persist
            // the credential. Unlike relay mode this returns, so the duped URL
            // is freed.
            defer alloc.free(e.base_url);
            var host_buf: [256]u8 = undefined;
            const name = hostName(&host_buf) orelse "unknown-host";
            try enroll.run(alloc, e.base_url, name, .{ .no_browser = e.no_browser });
        },
    }
}

/// The held daemon single-instance state: the guard itself plus the liveness
/// heartbeat a future challenger consults (see `single_instance` §Takeover).
/// `release` matters only on main's error-return paths — production daemons
/// hold both until the process dies.
const DaemonLock = struct {
    guard: ?single_instance.Guard,
    heartbeat: ?*single_instance.Heartbeat,

    fn release(self: *DaemonLock) void {
        if (self.heartbeat) |hb| hb.stopAndFree();
        if (self.guard) |*g| g.release();
        self.* = .{ .guard = null, .heartbeat = null };
    }
};

/// Take the per-user daemon single-instance guard (named mutex on Windows,
/// flock on POSIX — see `single_instance.zig`), running the TAKEOVER protocol
/// on contention: a responsive holder wins (we exit 183), a stuck one — or
/// any holder, under `--force-replace` — is killed and replaced. Outcomes:
///   - acquired (possibly after a takeover) → return the lock; the heartbeat
///     ticker is started so future challengers can tell us from a corpse.
///   - holder alive / not safely replaceable → log + exit with
///     `single_instance.already_running_exit_code` (183). The message +
///     distinct code make a supervisor's respawn-and-exit loop
///     self-explanatory in its captured stderr log.
///   - guard infrastructure failed → log a warning and return an empty lock:
///     the daemon serves anyway (availability beats guard integrity, same
///     policy as tray failures).
/// Called BEFORE any user-visible daemon setup (bind / banner / tray icon), so
/// a losing instance never flashes a tray icon or steals the port.
fn acquireDaemonLockOrExit(alloc: Allocator, force_replace: bool, instance: single_instance.Instance) DaemonLock {
    const guard = single_instance.acquireWithTakeover(alloc, force_replace, instance) catch |err| switch (err) {
        error.AlreadyRunning => {
            // std.debug.print writes stderr, which the supervisors (installer
            // launcher / deploy watcher) redirect to agent.err.log — visible
            // even though the Windows agent is a GUI-subsystem exe.
            std.debug.print("ghoztty-agent: another instance is already running; exiting\n", .{});
            std.process.exit(single_instance.already_running_exit_code);
        },
        error.GuardUnavailable => {
            std.debug.print("ghoztty-agent: warning: single-instance guard unavailable; continuing without it\n", .{});
            return .{ .guard = null, .heartbeat = null };
        },
    };
    // We are THE daemon: announce liveness. A heartbeat failure only costs
    // challenger-side takeover diagnostics, never the daemon. The heartbeat is
    // keyed to the SAME instance as the guard so a future challenger consults
    // the right holder's beat.
    return .{ .guard = guard, .heartbeat = single_instance.Heartbeat.start(alloc, instance) };
}

/// The local session-persistence agent's single-instance identity: distinct
/// from the relay/TCP-listen singleton (T89d1) so `--listen-pipe` (the Windows
/// local agent, spawned by the app's find-or-spawn) coexists with a `--relay`
/// agent. Debug and release lineages are separate instances too (own dir + pipe
/// suffix per T89a decision 2), so the guard splits by `is_debug` as well.
const local_instance_base: single_instance.Instance =
    if (@import("agent_build_options").is_debug)
        single_instance.Instance.local_debug
    else
        single_instance.Instance.local;

/// Backing store for a `GHOZTTY_AGENT_INSTANCE`-suffixed guard key. Process
/// lifetime, because the `Instance` handed to `acquireDaemonLockOrExit` borrows
/// it and the daemon holds its guard + heartbeat until it dies.
var instance_key_buf: [64]u8 = undefined;

/// The guard identity for this daemon: the build's own instance, forked by the
/// `GHOZTTY_AGENT_INSTANCE` suffix when one is set (T167). Unset — every
/// production run — returns `base` unchanged, so no existing agent's guard,
/// lock file or heartbeat name moves. A set suffix is what lets a hermetic test
/// sandbox run its own agent while the box's agent keeps the user's real panes;
/// without it the sandbox's agent exits 183 and the sandbox quietly tests the
/// NON-persistent path.
fn daemonInstance(base: single_instance.Instance) single_instance.Instance {
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    const suffix = agent_lineage.fromEnv(&sfx_buf) orelse return base;
    const forked = single_instance.instanceWithSuffix(&instance_key_buf, base, suffix) catch {
        // Only reachable if the key outgrows the buffer, which `max_len` rules
        // out — but a silent fall back to the SHARED guard is the one outcome
        // this feature must never produce quietly.
        std.debug.print(
            "ghoztty-agent: {s}='{s}' is unusable as a lineage suffix; using the shared '{s}' guard\n",
            .{ agent_lineage.env_var, suffix, base.key },
        );
        return base;
    };
    std.debug.print(
        "ghoztty-agent: single-instance: lineage suffix from {s} -> guard key '{s}'\n",
        .{ agent_lineage.env_var, forked.key },
    );
    return forked;
}

/// How relay-daemon startup obtains its device credential — a PURE decision
/// seam so the policy is unit-testable without env vars or files. Precedence:
/// `GHOSTTY_DEVICE_TOKEN` > relay.env. With NO credential anywhere an
/// INTERACTIVE launch self-enrolls inline (the MSI Start-Menu / Run-key launch
/// is exactly `ghoztty-agent --relay=<base>`, so the first run must bootstrap
/// itself), while `--headless` keeps the explicit error — a headless box has
/// no browser to pop; enroll it deliberately with `--enroll --no-browser`.
const RelayCredDecision = enum { use_env, use_relay_env, auto_enroll, fail };

fn decideRelayCred(has_env_token: bool, has_relay_env_token: bool, headless: bool) RelayCredDecision {
    if (has_env_token) return .use_env;
    if (has_relay_env_token) return .use_relay_env;
    return if (headless) .fail else .auto_enroll;
}

/// FIRST-RUN self-enrollment for interactive relay mode: no credential exists,
/// so run the normal `--enroll` flow inline (browser-first with device-code
/// fallback — `enroll.run`, reused unchanged) and return the freshly persisted
/// relay.env token; the caller then continues straight into the connect loop
/// (no re-exec). On failure (denied / expired / relay unreachable) this logs,
/// surfaces a Windows message box (see `surfaceEnrollFailure`), and errors out
/// so the daemon exits NONZERO: the installer's Run key retries at the next
/// logon — we never loop re-opening browsers.
fn autoEnrollForRelay(alloc: Allocator, base_url: []const u8) ![]u8 {
    std.debug.print("ghoztty-agent: no device credential; starting first-run browser enrollment with {s}\n", .{base_url});
    var host_buf: [256]u8 = undefined;
    const name = hostName(&host_buf) orelse "unknown-host";
    enroll.run(alloc, base_url, name, .{}) catch |err| {
        std.debug.print("ghoztty-agent: first-run enrollment failed ({s}); not starting the relay daemon\n", .{@errorName(err)});
        surfaceEnrollFailure(err);
        return err;
    };
    return enroll.loadDeviceToken(alloc) orelse {
        // Enroll claimed success but relay.env holds no token (racing delete,
        // unwritable dir surfaced late, ...): treat exactly like a failure.
        std.debug.print("ghoztty-agent: enrollment finished but relay.env holds no device token\n", .{});
        surfaceEnrollFailure(error.MissingDeviceToken);
        return error.MissingDeviceToken;
    };
}

/// Windows-only user-visible surface for a first-run enrollment failure: a
/// plain error message box. At this point NO tray icon exists yet (the tray
/// starts with the connect loop, which we never reach) and the GUI-subsystem
/// exe launched from the Start Menu / Run key has no console for stderr, so a
/// box is the only thing the user can see. No-op elsewhere; headless never
/// reaches here (`decideRelayCred` fails headless launches without enrolling).
fn surfaceEnrollFailure(err: anyerror) void {
    if (builtin.os.tag != .windows) return;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "First-run enrollment failed ({s}).\n\nThe agent will retry at the next launch, or enroll manually with:\nghoztty-agent --enroll --relay=<base>",
        .{@errorName(err)},
    ) catch "First-run enrollment failed.";
    tray.showStartupError(msg);
}

fn encodingFromEnv(alloc: Allocator) protocol.TransferEncoding {
    const v = std.process.getEnvVarOwned(alloc, "GHOZTTY_AGENT_ENCODING") catch return .raw;
    defer alloc.free(v);
    if (std.ascii.eqlIgnoreCase(v, "cobs")) return .cobs;
    if (std.ascii.eqlIgnoreCase(v, "base64")) return .base64;
    return .raw;
}

/// Process-wide per-session output-ring size in bytes, resolved once at startup
/// (T11). Defaults to `session.default_ring_bytes` (2 MB); overridden by the
/// `--ring-bytes=<N>` flag (set during `parseArgs`, highest priority) or, if the
/// flag is absent, the `GHOSTTY_AGENT_RING_BYTES` env var. `serveOne` hands it to
/// every per-connection `Server`, which uses it as the ring size for the sessions
/// it opens. Set-once at startup, read-only thereafter → no synchronization.
var configured_ring_bytes: usize = session.default_ring_bytes;

/// True once `--ring-bytes` set `configured_ring_bytes`, so the env fallback in
/// `main` knows the flag already won and skips `GHOSTTY_AGENT_RING_BYTES`.
var ring_bytes_from_flag: bool = false;

/// Floor for a configured ring size — a fat-fingered tiny value must not cripple
/// scrollback/gap-fill. Values below this (or unparseable) are rejected. 64 KiB.
const min_ring_bytes: usize = 64 * 1024;

/// Parse a `--ring-bytes` / `GHOSTTY_AGENT_RING_BYTES` value: a plain byte count.
/// Returns null on anything unparseable or below `min_ring_bytes` (the caller
/// then keeps the default / reports an error). Pure + tested.
fn parseRingBytes(text: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const n = std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (n < min_ring_bytes) return null;
    return n;
}

/// True once `--max-sessions` set `session.configured_max_sessions`, so the env
/// fallback in `main` knows the flag already won.
var max_sessions_from_flag: bool = false;

/// Parse a `--max-sessions` / `GHOSTTY_AGENT_MAX_SESSIONS` value.
///
/// Rejects 0 (an agent that can open nothing is not a configuration, it is a
/// wedge) and anything above the compile-time `session.max_sessions`: this knob
/// exists to make the refusal path reachable, never to RAISE a ceiling that the
/// tombstone bookkeeping and the per-session ring budget were sized against.
/// Pure + tested.
fn parseMaxSessions(text: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const n = std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (n == 0 or n > session.max_sessions) return null;
    return n;
}

const Mode = union(enum) {
    /// `--version`: print the baked build version and exit.
    version,
    /// No recognized mode (bare invocation): print usage and exit cleanly —
    /// deliberately NOT an unauthenticated listener (see the SECURITY note).
    usage,
    stdio,
    listen: Listen,
    listen_unix: ListenUnix,
    listen_pipe: ListenPipe,
    relay: Relay,
    enroll: Enroll,
    pty_host: PtyHost,
    pty_host_smoke,
};

/// Per-session ConPTY holder parameters (`--pty-host`, T904 — increment 1 of
/// the T705 non-destructive agent upgrade). One holder process per persistent
/// session: it owns the ConPTY + shell + kill-on-close job and serves the
/// `pty_host_proto` control pipe. Windows-only (parse-time rejected elsewhere).
/// All string fields are owned (duped from argv so they outlive `argsFree`).
const PtyHost = struct {
    /// `--session-id <id>` (required; pipe-name-safe charset).
    session_id: []const u8,
    /// `--pipe <\\.\pipe\name>`: explicit control-pipe path. Null ⇒ the
    /// build-mode-isolated default (`pty_host.defaultPipeName`).
    pipe: ?[]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    /// `--replay-bytes <n>`: bounded un-acked output ring.
    replay_bytes: usize = 1024 * 1024,
    /// `--exit-linger-ms <n>`: how long an ownerless holder outlives its
    /// exited shell so the agent can still collect the exit code.
    exit_linger_ms: i64 = 10 * 60 * 1000,
    /// `--spec <path>`: a JSON spawn spec (`pty_host_spec.zig`, T905) holding
    /// the WHOLE `OPEN` — argv, forwarded env, term, cwd — plus the session id,
    /// pipe name and holder limits. This is how the AGENT starts a holder; the
    /// individual flags above are the hand-driven path (the smoke). When
    /// present, the spec supplies everything and `--session-id` is not
    /// required. The file is read and DELETED before the shell is spawned.
    spec: ?[]const u8 = null,
};

/// Self-enroll parameters (`--enroll --relay=<base>`). `base_url` is the
/// relay HTTP(S) base to enroll against (owned — duped from argv).
/// `no_browser` (`--no-browser` / `--headless-enroll`) skips the browser flow
/// and uses the device-code flow directly.
const Enroll = struct {
    base_url: []const u8,
    no_browser: bool = false,
};

/// Relay-mode parameters. `base_url` is the relay HTTPS/WSS base (owned — duped
/// from argv so it outlives `argsFree`). `headless` suppresses the Windows tray.
/// `force_replace` (`--force-replace`/`--replace`) kills a live single-instance
/// holder instead of yielding to it.
const Relay = struct {
    base_url: []const u8,
    headless: bool = false,
    force_replace: bool = false,
};

/// TCP listen-daemon parameters. `headless` suppresses the Windows system-tray
/// icon (for CI / non-interactive runs); the default (tray ON) is what the deploy
/// watcher uses so the human running the Windows box gets a visible daemon handle.
const Listen = struct {
    addr: std.net.Address,
    headless: bool = false,
    force_replace: bool = false,
    /// True when `addr` is a non-loopback interface (only reachable via the
    /// explicit `--insecure-allow-public` opt-in) — drives a runtime warning.
    public: bool = false,
    /// `--port-file=<path>`: after the listener binds, atomically write a JSON
    /// file `{"port":N,"pid":P,"startedAt":MS}` so a supervisor that spawned us
    /// with `--listen=127.0.0.1:0` (ephemeral port) can discover the bound
    /// port. Owned (duped from argv).
    port_file: ?[]const u8 = null,
    /// `--sessions-file=<path>`: the reboot-floor metadata store (§5.4, T12).
    /// When set, the daemon keeps this path up to date with the live-session
    /// roster (id/argv/cwd/title/pinned) so sessions can be relaunched after an
    /// agent/machine restart. Owned (duped from argv). Null ⇒ no persistence.
    sessions_file: ?[]const u8 = null,
};

/// Unix-domain-socket listen-daemon parameters (`--listen-unix=<path>`). The
/// SECURE local transport (design §5.2): a 0600 socket node + a per-connection
/// `LOCAL_PEERCRED`/`SO_PEERCRED` same-uid gate means — unlike a 127.0.0.1 TCP
/// port, which ANY local uid can connect to — only this user can reach the
/// shell. POSIX-only (Windows local persistence uses a named pipe later, §5.2).
/// `headless`/`force_replace` mirror `Listen`; there is no public/loopback
/// distinction (a filesystem socket is never network-reachable).
const ListenUnix = struct {
    /// Filesystem path to bind the AF_UNIX stream socket at (owned — duped from
    /// argv so it outlives `argsFree`).
    path: []const u8,
    headless: bool = false,
    force_replace: bool = false,
    /// `--port-file=<path>`: after the socket binds, atomically write a JSON
    /// info file `{"port":0,"pid":P,"socket":"<path>","startedAt":MS}` so the
    /// supervisor that spawned us can pid-liveness-check a pre-existing agent
    /// and learn the socket path to dial (a UDS has no ephemeral port to
    /// publish). Owned (duped from argv).
    port_file: ?[]const u8 = null,
    /// `--sessions-file=<path>`: the reboot-floor metadata store (§5.4, T12) —
    /// see `Listen.sessions_file`. Owned (duped from argv). Null ⇒ no persistence.
    sessions_file: ?[]const u8 = null,
};

/// Windows-named-pipe listen-daemon parameters (`--listen-pipe=<name>`, T89c).
/// The SECURE local transport on Windows (design §5.2) — the named-pipe analog
/// of `--listen-unix`: the pipe is created with an owner-only DACL (only this
/// user can open it; the DACL stands in for the unix listener's peercred gate)
/// and FILE_FLAG_FIRST_PIPE_INSTANCE (binding doubles as the liveness probe —
/// a taken name means a live agent already serves it). Windows-only.
/// `headless`/`force_replace` mirror `Listen`; a named pipe is never
/// network-reachable (PIPE_REJECT_REMOTE_CLIENTS on top).
const ListenPipe = struct {
    /// Full pipe path to bind (`\\.\pipe\ghoztty-agent[-debug]-<user>`; owned —
    /// duped from argv so it outlives `argsFree`).
    name: []const u8,
    headless: bool = false,
    force_replace: bool = false,
    /// `--port-file=<path>`: after the pipe binds, atomically write a JSON
    /// info file `{"port":0,"pid":P,"pipe":"<name>","startedAt":MS}` so the
    /// supervisor that spawned us can pid-liveness-check a pre-existing agent
    /// and learn the pipe name to dial (additive `pipe` field — an old reader
    /// ignores it, per the agent-contract rules). Owned (duped from argv).
    port_file: ?[]const u8 = null,
    /// `--sessions-file=<path>`: the reboot-floor metadata store (§5.4, T12) —
    /// see `Listen.sessions_file`. Owned (duped from argv). Null ⇒ no persistence.
    sessions_file: ?[]const u8 = null,
};

/// Opt-in required to bind `--listen` to a NON-loopback interface. The TCP
/// listener is unauthenticated (see the SECURITY note), so binding it to a
/// routable address exposes a shell to the network; we refuse to do that
/// unless the operator explicitly accepts the risk with this flag.
const allow_public_flag = "--insecure-allow-public";

/// Parse `--version` | `--stdio` | `--listen <addr:port>` | `--relay <url>` |
/// `--enroll --relay <url>` | (no args ⇒ default TCP listen).
/// `--headless` (anywhere on the line) suppresses the tray for listen mode; the
/// stdio path is ALWAYS headless (an ssh-piped agent has no desktop to draw on).
/// `--enroll` (anywhere on the line) turns the `--relay` base into a one-shot
/// enrollment instead of the relay daemon; `--no-browser`/`--headless-enroll`
/// makes that enrollment use the device-code flow instead of the browser.
/// `--force-replace` (alias `--replace`, daemon modes) makes THIS launch win
/// the single-instance guard: the current holder is killed and replaced even
/// if it is alive and responsive (see `single_instance.zig` §Takeover).
fn parseArgs(alloc: Allocator) !Mode {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // Pre-scan for the order-independent flags so they can appear before OR
    // after the mode argument they modify.
    var headless = false;
    var want_enroll = false;
    var no_browser = false;
    var force_replace = false;
    var allow_public = false;
    var port_file_arg: ?[]const u8 = null;
    var sessions_file_arg: ?[]const u8 = null;
    {
        var j: usize = 1;
        while (j < args.len) : (j += 1) {
            const a = args[j];
            if (std.mem.eql(u8, a, "--headless")) headless = true;
            if (std.mem.eql(u8, a, "--enroll")) want_enroll = true;
            if (std.mem.eql(u8, a, "--no-browser") or
                std.mem.eql(u8, a, "--headless-enroll")) no_browser = true;
            if (std.mem.eql(u8, a, "--force-replace") or
                std.mem.eql(u8, a, "--replace")) force_replace = true;
            if (std.mem.eql(u8, a, allow_public_flag)) allow_public = true;
            if (std.mem.eql(u8, a, "--port-file")) {
                j += 1;
                if (j >= args.len) {
                    std.debug.print("ghoztty-agent: --port-file requires <path>\n", .{});
                    return error.InvalidArgs;
                }
                port_file_arg = args[j];
            } else if (std.mem.startsWith(u8, a, "--port-file=")) {
                port_file_arg = a["--port-file=".len..];
            }
            // Sessions file (T12): order-independent config, like --port-file.
            if (std.mem.eql(u8, a, "--sessions-file")) {
                j += 1;
                if (j >= args.len) {
                    std.debug.print("ghoztty-agent: --sessions-file requires <path>\n", .{});
                    return error.InvalidArgs;
                }
                sessions_file_arg = args[j];
            } else if (std.mem.startsWith(u8, a, "--sessions-file=")) {
                sessions_file_arg = a["--sessions-file=".len..];
            }
            // Handoff successor (T907): we were spawned by a RUNNING agent that
            // is about to retire, and this private pipe is how we tell it we are
            // up and how it tells us to take over. Order-independent, and stored
            // in a process-lifetime buffer because `args` is freed on the way out
            // of this function while the value is needed by the listen path.
            if (std.mem.startsWith(u8, a, handoff.successor_flag ++ "=")) {
                const v = a[handoff.successor_flag.len + 1 ..];
                if (v.len == 0 or v.len > handoff_pipe_buf.len) {
                    std.debug.print("ghoztty-agent: invalid {s} value\n", .{handoff.successor_flag});
                    return error.InvalidArgs;
                }
                @memcpy(handoff_pipe_buf[0..v.len], v);
                handoff_pipe_len = v.len;
            }
            // Ring size (T11): order-independent config, like --port-file.
            if (std.mem.eql(u8, a, "--ring-bytes")) {
                j += 1;
                if (j >= args.len) {
                    std.debug.print("ghoztty-agent: --ring-bytes requires <bytes>\n", .{});
                    return error.InvalidArgs;
                }
                if (parseRingBytes(args[j])) |n| {
                    configured_ring_bytes = n;
                    ring_bytes_from_flag = true;
                } else {
                    std.debug.print("ghoztty-agent: invalid --ring-bytes value '{s}' (min {d})\n", .{ args[j], min_ring_bytes });
                    return error.InvalidArgs;
                }
            } else if (std.mem.startsWith(u8, a, "--ring-bytes=")) {
                const v = a["--ring-bytes=".len..];
                if (parseRingBytes(v)) |n| {
                    configured_ring_bytes = n;
                    ring_bytes_from_flag = true;
                } else {
                    std.debug.print("ghoztty-agent: invalid --ring-bytes value '{s}' (min {d})\n", .{ v, min_ring_bytes });
                    return error.InvalidArgs;
                }
            }
            // Live-session cap (T469): same order-independent shape as
            // --ring-bytes. Lowering it is how the refusal path is reached on a
            // box without standing up 256 real shells.
            if (std.mem.eql(u8, a, "--max-sessions")) {
                j += 1;
                if (j >= args.len) {
                    std.debug.print("ghoztty-agent: --max-sessions requires <n>\n", .{});
                    return error.InvalidArgs;
                }
                if (parseMaxSessions(args[j])) |n| {
                    session.configured_max_sessions = n;
                    max_sessions_from_flag = true;
                } else {
                    std.debug.print("ghoztty-agent: invalid --max-sessions value '{s}'\n", .{args[j]});
                    return error.InvalidArgs;
                }
            } else if (std.mem.startsWith(u8, a, "--max-sessions=")) {
                const v = a["--max-sessions=".len..];
                if (parseMaxSessions(v)) |n| {
                    session.configured_max_sessions = n;
                    max_sessions_from_flag = true;
                } else {
                    std.debug.print("ghoztty-agent: invalid --max-sessions value '{s}'\n", .{v});
                    return error.InvalidArgs;
                }
            }
        }
    }

    // Holder modes (T904) parse their OWN flag set (several of which take
    // free-form values like --command), so they divert before the main loop —
    // and before it can trip on a holder flag that precedes `--pty-host`.
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--pty-host")) return parsePtyHostMode(alloc, args);
        if (std.mem.eql(u8, a, "--pty-host-smoke")) {
            if (builtin.os.tag != .windows) {
                std.debug.print("ghoztty-agent: --pty-host-smoke is Windows-only\n", .{});
                return error.InvalidArgs;
            }
            return .pty_host_smoke;
        }
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--headless") or std.mem.eql(u8, a, "--enroll") or
            std.mem.eql(u8, a, "--no-browser") or std.mem.eql(u8, a, "--headless-enroll") or
            std.mem.eql(u8, a, "--force-replace") or std.mem.eql(u8, a, "--replace") or
            std.mem.eql(u8, a, allow_public_flag) or
            std.mem.startsWith(u8, a, "--port-file=") or
            std.mem.startsWith(u8, a, "--sessions-file=") or
            std.mem.startsWith(u8, a, "--ring-bytes=") or
            std.mem.startsWith(u8, a, "--max-sessions=") or
            std.mem.startsWith(u8, a, handoff.successor_flag ++ "="))
        {
            continue; // handled in the pre-scan above
        } else if (std.mem.eql(u8, a, "--port-file") or std.mem.eql(u8, a, "--sessions-file") or
            std.mem.eql(u8, a, "--ring-bytes") or std.mem.eql(u8, a, "--max-sessions"))
        {
            i += 1; // value consumed in the pre-scan above
            continue;
        } else if (std.mem.eql(u8, a, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return .usage;
        } else if (std.mem.eql(u8, a, "--stdio")) {
            return .stdio;
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ghoztty-agent: --listen requires <addr:port>\n", .{});
                return error.InvalidArgs;
            }
            return listenMode(alloc, try parseAddr(args[i]), headless, force_replace, allow_public, port_file_arg, sessions_file_arg);
        } else if (std.mem.startsWith(u8, a, "--listen=")) {
            return listenMode(alloc, try parseAddr(a["--listen=".len..]), headless, force_replace, allow_public, port_file_arg, sessions_file_arg);
        } else if (std.mem.eql(u8, a, "--listen-unix")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ghoztty-agent: --listen-unix requires <path>\n", .{});
                return error.InvalidArgs;
            }
            return listenUnixMode(alloc, args[i], headless, force_replace, port_file_arg, sessions_file_arg);
        } else if (std.mem.startsWith(u8, a, "--listen-unix=")) {
            return listenUnixMode(alloc, a["--listen-unix=".len..], headless, force_replace, port_file_arg, sessions_file_arg);
        } else if (std.mem.eql(u8, a, "--listen-pipe")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ghoztty-agent: --listen-pipe requires <name>\n", .{});
                return error.InvalidArgs;
            }
            return listenPipeMode(alloc, args[i], headless, force_replace, port_file_arg, sessions_file_arg);
        } else if (std.mem.startsWith(u8, a, "--listen-pipe=")) {
            return listenPipeMode(alloc, a["--listen-pipe=".len..], headless, force_replace, port_file_arg, sessions_file_arg);
        } else if (std.mem.eql(u8, a, "--relay")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ghoztty-agent: --relay requires <url>\n", .{});
                return error.InvalidArgs;
            }
            // Dupe the URL: `args` is freed (argsFree) when parseArgs returns, but
            // both relay and enroll modes need it past that.
            const url = try alloc.dupe(u8, args[i]);
            if (want_enroll) return .{ .enroll = .{ .base_url = url, .no_browser = no_browser } };
            return .{ .relay = .{ .base_url = url, .headless = headless, .force_replace = force_replace } };
        } else if (std.mem.startsWith(u8, a, "--relay=")) {
            const url = try alloc.dupe(u8, a["--relay=".len..]);
            if (want_enroll) return .{ .enroll = .{ .base_url = url, .no_browser = no_browser } };
            return .{ .relay = .{ .base_url = url, .headless = headless, .force_replace = force_replace } };
        } else {
            std.debug.print("ghoztty-agent: unknown argument '{s}'\n", .{a});
            return error.InvalidArgs;
        }
    }
    if (want_enroll) {
        std.debug.print("ghoztty-agent: --enroll requires --relay=<base url>\n", .{});
        return error.InvalidArgs;
    }
    // No recognized mode: print usage and exit. A bare invocation deliberately
    // does NOT open a listener — the TCP path is unauthenticated, so defaulting
    // to it would expose a shell to the network (see the SECURITY note).
    return .usage;
}

/// Parse the `--pty-host` flag set (T904). Windows-only; every value flag
/// accepts both `--flag value` and `--flag=value`. Unknown arguments are
/// rejected — a holder is spawned programmatically (by the agent or the
/// smoke), so a typo is a bug, not a user to be lenient with.
fn parsePtyHostMode(alloc: Allocator, args: []const [:0]u8) !Mode {
    if (builtin.os.tag != .windows) {
        std.debug.print("ghoztty-agent: --pty-host is Windows-only\n", .{});
        return error.InvalidArgs;
    }

    var p: PtyHost = .{ .session_id = &.{} };
    var session_id: ?[]const u8 = null;

    // Owned-dupe bookkeeping: on an error return, free what was duped.
    errdefer {
        if (session_id) |v| alloc.free(v);
        if (p.pipe) |v| alloc.free(v);
        if (p.cwd) |v| alloc.free(v);
        if (p.command) |v| alloc.free(v);
        if (p.shell) |v| alloc.free(v);
        if (p.spec) |v| alloc.free(v);
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--pty-host")) continue;

        const str_flags = .{
            .{ "--session-id", &session_id },
            .{ "--pipe", &p.pipe },
            .{ "--cwd", &p.cwd },
            .{ "--command", &p.command },
            .{ "--shell", &p.shell },
            .{ "--spec", &p.spec },
        };
        var matched = false;
        inline for (str_flags) |f| {
            if (!matched) if (try takeValue(args, &i, f[0])) |v| {
                if (f[1].*) |old| alloc.free(old);
                f[1].* = try alloc.dupe(u8, v);
                matched = true;
            };
        }
        if (matched) continue;

        if (try takeValue(args, &i, "--rows")) |v| {
            p.rows = std.fmt.parseInt(u16, v, 10) catch return badPtyHostValue("--rows", v);
        } else if (try takeValue(args, &i, "--cols")) |v| {
            p.cols = std.fmt.parseInt(u16, v, 10) catch return badPtyHostValue("--cols", v);
        } else if (try takeValue(args, &i, "--replay-bytes")) |v| {
            const n = std.fmt.parseInt(usize, v, 10) catch return badPtyHostValue("--replay-bytes", v);
            if (n < 4096) return badPtyHostValue("--replay-bytes", v);
            p.replay_bytes = n;
        } else if (try takeValue(args, &i, "--exit-linger-ms")) |v| {
            p.exit_linger_ms = std.fmt.parseInt(i64, v, 10) catch return badPtyHostValue("--exit-linger-ms", v);
        } else {
            std.debug.print("ghoztty-agent: unknown --pty-host argument '{s}'\n", .{a});
            return error.InvalidArgs;
        }
    }

    // With a `--spec` the session id (and everything else) comes from the file,
    // so it is the one path that does not need `--session-id` on the wire.
    p.session_id = session_id orelse (if (p.spec != null) try alloc.dupe(u8, "") else {
        std.debug.print("ghoztty-agent: --pty-host requires --session-id <id> (or --spec <file>)\n", .{});
        return error.InvalidArgs;
    });
    return .{ .pty_host = p };
}

fn badPtyHostValue(comptime flag: []const u8, v: []const u8) error{InvalidArgs} {
    std.debug.print("ghoztty-agent: invalid " ++ flag ++ " value '{s}'\n", .{v});
    return error.InvalidArgs;
}

/// If `args[i.*]` is `<flag> <value>` or `<flag>=<value>`, return the value
/// (advancing `i` past a separate value argument); else null. Errors when the
/// flag is present but its value is missing.
fn takeValue(args: []const [:0]u8, i: *usize, comptime flag: []const u8) !?[]const u8 {
    const a = args[i.*];
    if (std.mem.eql(u8, a, flag)) {
        i.* += 1;
        if (i.* >= args.len) {
            std.debug.print("ghoztty-agent: " ++ flag ++ " requires a value\n", .{});
            return error.InvalidArgs;
        }
        return args[i.*];
    }
    if (std.mem.startsWith(u8, a, flag ++ "=")) return a[flag.len + 1 ..];
    return null;
}

/// Build a `.listen` mode, enforcing the loopback/public policy: an
/// unauthenticated TCP shell may bind loopback freely (tests, local dev), but a
/// NON-loopback interface requires the explicit `--insecure-allow-public`
/// opt-in. Without it we refuse rather than silently expose a shell.
/// `port_file`/`sessions_file` are duped here (argv is freed when parseArgs returns).
fn listenMode(alloc: Allocator, addr: std.net.Address, headless: bool, force_replace: bool, allow_public: bool, port_file: ?[]const u8, sessions_file: ?[]const u8) !Mode {
    const public = !isLoopbackAddr(addr);
    if (public and !allow_public) {
        std.debug.print(
            "ghoztty-agent: refusing to bind an UNAUTHENTICATED shell listener to a public\n" ++
                "  interface. The --listen TCP path has no authentication.\n" ++
                "  • For secure remote access use: ghoztty-agent --relay=<url>\n" ++
                "  • To bind loopback only: --listen=127.0.0.1:<port>\n" ++
                "  • To accept the risk on a trusted network: add " ++ allow_public_flag ++ "\n",
            .{},
        );
        return error.InsecureListen;
    }
    if (port_file) |pf| if (pf.len == 0) {
        std.debug.print("ghoztty-agent: --port-file requires a non-empty <path>\n", .{});
        return error.InvalidArgs;
    };
    if (sessions_file) |sf| if (sf.len == 0) {
        std.debug.print("ghoztty-agent: --sessions-file requires a non-empty <path>\n", .{});
        return error.InvalidArgs;
    };
    const pf_owned: ?[]const u8 = if (port_file) |pf| try alloc.dupe(u8, pf) else null;
    errdefer if (pf_owned) |p| alloc.free(p);
    const sf_owned: ?[]const u8 = if (sessions_file) |sf| try alloc.dupe(u8, sf) else null;
    return .{ .listen = .{ .addr = addr, .headless = headless, .force_replace = force_replace, .public = public, .port_file = pf_owned, .sessions_file = sf_owned } };
}

/// Build a `.listen_unix` mode. Validates a non-empty path and rejects it on
/// Windows (AF_UNIX local persistence is not this fork's Windows story — that is
/// a named pipe, §5.2). `path` is duped here (argv is freed when parseArgs
/// returns).
fn listenUnixMode(alloc: Allocator, path: []const u8, headless: bool, force_replace: bool, port_file: ?[]const u8, sessions_file: ?[]const u8) !Mode {
    if (path.len == 0) {
        std.debug.print("ghoztty-agent: --listen-unix requires a non-empty <path>\n", .{});
        return error.InvalidArgs;
    }
    if (builtin.os.tag == .windows) {
        std.debug.print("ghoztty-agent: --listen-unix is not supported on Windows (use a named pipe)\n", .{});
        return error.InvalidArgs;
    }
    if (port_file) |pf| if (pf.len == 0) {
        std.debug.print("ghoztty-agent: --port-file requires a non-empty <path>\n", .{});
        return error.InvalidArgs;
    };
    if (sessions_file) |sf| if (sf.len == 0) {
        std.debug.print("ghoztty-agent: --sessions-file requires a non-empty <path>\n", .{});
        return error.InvalidArgs;
    };
    const path_owned = try alloc.dupe(u8, path);
    errdefer alloc.free(path_owned);
    const pf_owned: ?[]const u8 = if (port_file) |pf| try alloc.dupe(u8, pf) else null;
    errdefer if (pf_owned) |p| alloc.free(p);
    const sf_owned: ?[]const u8 = if (sessions_file) |sf| try alloc.dupe(u8, sf) else null;
    return .{ .listen_unix = .{ .path = path_owned, .headless = headless, .force_replace = force_replace, .port_file = pf_owned, .sessions_file = sf_owned } };
}

/// Build a `.listen_pipe` mode (T89c). Validates a non-empty, full
/// `\\.\pipe\...` name and rejects it on non-Windows (the POSIX local
/// transport is `--listen-unix` — the exact mirror of `listenUnixMode`'s
/// Windows rejection). `name` is duped here (argv is freed when parseArgs
/// returns).
fn listenPipeMode(alloc: Allocator, name: []const u8, headless: bool, force_replace: bool, port_file: ?[]const u8, sessions_file: ?[]const u8) !Mode {
    if (name.len == 0) {
        std.debug.print("ghoztty-agent: --listen-pipe requires a non-empty <name>\n", .{});
        return error.InvalidArgs;
    }
    if (builtin.os.tag != .windows) {
        std.debug.print("ghoztty-agent: --listen-pipe is only supported on Windows (use --listen-unix)\n", .{});
        return error.InvalidArgs;
    }
    if (!std.mem.startsWith(u8, name, "\\\\.\\pipe\\")) {
        std.debug.print("ghoztty-agent: --listen-pipe requires a full \\\\.\\pipe\\<name> path, got '{s}'\n", .{name});
        return error.InvalidArgs;
    }
    if (port_file) |pf| if (pf.len == 0) {
        std.debug.print("ghoztty-agent: --port-file requires a non-empty <path>\n", .{});
        return error.InvalidArgs;
    };
    if (sessions_file) |sf| if (sf.len == 0) {
        std.debug.print("ghoztty-agent: --sessions-file requires a non-empty <path>\n", .{});
        return error.InvalidArgs;
    };
    const name_owned = try alloc.dupe(u8, name);
    errdefer alloc.free(name_owned);
    const pf_owned: ?[]const u8 = if (port_file) |pf| try alloc.dupe(u8, pf) else null;
    errdefer if (pf_owned) |p| alloc.free(p);
    const sf_owned: ?[]const u8 = if (sessions_file) |sf| try alloc.dupe(u8, sf) else null;
    return .{ .listen_pipe = .{ .name = name_owned, .headless = headless, .force_replace = force_replace, .port_file = pf_owned, .sessions_file = sf_owned } };
}

/// Whether `addr` is a loopback address (127.0.0.0/8 or ::1) — the only binds
/// that don't expose the unauthenticated listener beyond this machine.
fn isLoopbackAddr(addr: std.net.Address) bool {
    return switch (addr.any.family) {
        posix.AF.INET => std.mem.asBytes(&addr.in.sa.addr)[0] == 127,
        posix.AF.INET6 => blk: {
            const v6 = [_]u8{0} ** 15 ++ [_]u8{1}; // ::1
            break :blk std.mem.eql(u8, &addr.in6.sa.addr, &v6);
        },
        else => false,
    };
}

/// Print usage to stdout (bare invocation / `--help`). Steers users to the
/// authenticated relay path — never to the unauthenticated listener.
fn printUsage() void {
    const text =
        \\ghoztty-agent — Ghoztty remote-machines daemon
        \\
        \\Usage:
        \\  ghoztty-agent --relay=<url>     Connect to your account's relay (authenticated;
        \\                                  the normal way to bring a machine online).
        \\  ghoztty-agent --enroll --relay=<url>
        \\                                  Enroll this machine to your account (browser sign-in).
        \\  ghoztty-agent --version         Print the build version.
        \\
        \\Advanced / development:
        \\  ghoztty-agent --listen-unix=<path>
        \\                                  Local session daemon over a 0600 AF_UNIX socket
        \\                                  with a same-uid peercred gate (the SECURE local
        \\                                  transport — only this user can reach it). Used by
        \\                                  the app's session-persistence local agent.
        \\  ghoztty-agent --listen-pipe=\\.\pipe\<name>
        \\                                  Local session daemon over an owner-only-DACL
        \\                                  named pipe (the SECURE local transport on
        \\                                  Windows — only this user can open it). Used by
        \\                                  the app's session-persistence local agent.
        \\  ghoztty-agent --pty-host --session-id=<id>
        \\                                  Per-session ConPTY holder (Windows): owns one
        \\                                  session's shell + pty so the agent can restart
        \\                                  without killing it. Spawned by the agent, not
        \\                                  by hand. (--pty-host-smoke runs its self-test.)
        \\                                  --port-file publishes {"port":0,"pid":P,
        \\                                  "pipe":"<name>",...} (atomic).
        \\  ghoztty-agent --listen=127.0.0.1:<port>
        \\                                  UNAUTHENTICATED TCP shell, loopback only.
        \\                                  Port 0 binds an ephemeral port; add
        \\                                  --port-file=<path> to publish the bound port
        \\                                  as {"port":N,"pid":P,"startedAt":MS} (atomic).
        \\  ghoztty-agent --listen=<addr:port> --insecure-allow-public
        \\                                  UNAUTHENTICATED TCP shell on a routable interface
        \\                                  (trusted networks only — anyone who reaches it gets a shell).
        \\
        \\Options (any mode):
        \\  --ring-bytes=<N>                Per-session output-ring size in bytes (scrollback /
        \\                                  reconnect gap-fill). Default 2097152 (2 MB), min 65536.
        \\                                  Also settable via GHOSTTY_AGENT_RING_BYTES (flag wins).
        \\  --max-sessions=<N>              Live-session ceiling, 1..256 (default 256). Lowering it
        \\                                  is how the "could not start a shell" refusal path is
        \\                                  exercised without standing up 256 real shells.
        \\                                  Also settable via GHOSTTY_AGENT_MAX_SESSIONS (flag wins).
        \\  --sessions-file=<path>          Reboot-floor metadata store: keep this file's
        \\                                  {"version":1,"sessions":[…]} up to date with the live
        \\                                  session roster (id/argv/cwd/title/pinned) so sessions
        \\                                  can be relaunched after an agent/machine restart (atomic).
        \\
        \\For secure remote access, use --relay. A bare invocation intentionally does
        \\nothing (it will not open an unauthenticated listener).
        \\
    ;
    std.fs.File.stdout().writeAll(text) catch {};
}

/// Parse "host:port" into a `std.net.Address`. Host may be an IPv4/IPv6 literal.
fn parseAddr(spec: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse {
        std.debug.print("ghoztty-agent: bad address '{s}' (want host:port)\n", .{spec});
        return error.InvalidArgs;
    };
    const host = spec[0..colon];
    const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch {
        std.debug.print("ghoztty-agent: bad port in '{s}'\n", .{spec});
        return error.InvalidArgs;
    };
    return std.net.Address.parseIp(host, port) catch {
        std.debug.print("ghoztty-agent: bad host in '{s}'\n", .{spec});
        return error.InvalidArgs;
    };
}

// -----------------------------------------------------------------------------
// stdio mode (ssh transport): one Mux over stdin/stdout, run until stdin EOF.
// -----------------------------------------------------------------------------

fn runStdio(alloc: Allocator, encoding: protocol.TransferEncoding) !void {
    // stdio mode handles exactly ONE connection (the ssh pipe pair), but it still
    // uses the same shared-store core so the lifecycle code is identical. The store
    // is created here, lives for the single connection, and is torn down on EOF.
    const seed = blk: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };
    var rng = std.Random.DefaultPrng.init(seed);

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    var store = session.SessionStore.init(
        alloc,
        rng.random(),
        undefined,
        realNow,
        session.default_idle_ttl_ms,
    );
    defer store.deinit();

    var stdio = mux_mod.StdioStream.init(std.fs.File.stdin(), std.fs.File.stdout());
    try serveOne(alloc, encoding, &store, spawner.spawner(), stdio.stream());
}

// -----------------------------------------------------------------------------
// TCP listen daemon: bind, then accept→serve→loop. Each connection gets a fresh
// Mux + Server + PtySpawner (no session survival this increment).
// -----------------------------------------------------------------------------

fn runListen(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    addr: std.net.Address,
    headless: bool,
    public: bool,
    port_file: ?[]const u8,
    sessions_file: ?[]const u8,
) !void {
    // Loud, unmissable warning when bound to a routable interface: this listener
    // has no authentication, so anyone who can reach the port gets a shell. Only
    // reachable via the explicit --insecure-allow-public opt-in.
    if (public) {
        std.debug.print(
            "ghoztty-agent: WARNING — UNAUTHENTICATED shell listener bound to a PUBLIC\n" ++
                "  interface ({f}). Anyone who can reach this port can run commands on this\n" ++
                "  machine. Use --relay=<url> for authenticated remote access instead.\n",
            .{addr},
        );
    }

    var listener = addr.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("ghoztty-agent: failed to bind {f}: {s}\n", .{ addr, @errorName(err) });
        return err;
    };
    defer listener.deinit();

    // The ADDRESS ACTUALLY BOUND (getsockname). Differs from `addr` when the
    // caller asked for port 0 (ephemeral): this one carries the real port —
    // use it for the banner and the port file below.
    const bound_addr = listener.listen_address;

    // Publish the bound port for the supervisor that spawned us (the whole
    // point of `--listen=127.0.0.1:0 --port-file=...`). Written AFTER the bind
    // succeeds, atomically (tmp+rename), so a reader never sees a torn file or
    // a port we don't actually hold. Failure is fatal: a supervisor waiting on
    // this file would otherwise hang against a silently portless agent.
    if (port_file) |pf| {
        writePortFile(alloc, pf, bound_addr.getPort()) catch |err| {
            std.debug.print("ghoztty-agent: failed to write --port-file {s}: {s}\n", .{ pf, @errorName(err) });
            return err;
        };
    }

    // DAEMON-SCOPED shared session store + spawner (§7.1 survival). These OUTLIVE
    // every connection: a client disconnect tears down its per-connection Server but
    // leaves the sessions, their pty children, and their output rings alive in the
    // store, still streaming, ready for a reconnect to ATTACH and catch up. The
    // store's background reaper evicts sessions left orphaned past the idle-TTL.
    const seed = blk: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };
    var rng = std.Random.DefaultPrng.init(seed);

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    var store = session.SessionStore.init(
        alloc,
        rng.random(),
        undefined,
        realNow,
        session.default_idle_ttl_ms,
    );
    // Reboot-floor metadata store (§5.4, T12): when a supervisor passed
    // --sessions-file, the store atomically rewrites it with the live-session
    // roster on every open/close. Borrowed; `sessions_file` outlives `store`.
    store.meta_path = sessions_file;
    // Reboot scrollback (§5.4, T13): ring disk snapshots live in a `rings/` subdir
    // beside the sessions file. Borrowed; freed after `store.deinit` (LIFO defers).
    const rings_dir = ringsDirFor(alloc, sessions_file);
    defer if (rings_dir) |d| alloc.free(d);
    store.rings_dir = rings_dir;
    // Cross-machine "Resume all" (§5.4, T18): opaque per-window layout blobs live
    // in a `layouts.json` beside the sessions file. Borrowed; freed after
    // `store.deinit` (LIFO defers).
    const layouts_file = layoutsFileFor(alloc, sessions_file);
    defer if (layouts_file) |f| alloc.free(f);
    store.layouts_path = layouts_file;
    defer store.deinit();
    // Reboot-floor materialization (§5.4, T12b): before accepting connections (and
    // before the reaper starts), load the persisted roster and re-create each record
    // as a DEAD, relaunchable tombstone so a viewer's ATTACH finds a session it can
    // RELAUNCH. No-op when --sessions-file was not passed or the file is absent.
    const materialized = store.loadPersisted(configured_ring_bytes);
    // Also load any persisted layout blobs (T18) so a browsing viewer sees this
    // machine's window topology even after an agent restart.
    store.loadLayouts();
    // Self-heal: drop any loaded blob whose sessions did not materialize (truly
    // gone), so a stale layouts.json never advertises unattachable windows.
    if (store.reapLayouts() > 0) store.persistLayouts();
    if (materialized > 0) std.log.info("reboot floor: materialized {d} session(s) from disk", .{materialized});
    // Holder re-adoption (T906): before the listener takes its first
    // connection, dial every recorded `--pty-host` holder and pick the live
    // ones back up. A session whose holder answers is ALIVE again — same shell,
    // same scrollback, no restart divider — and one whose holder is gone falls
    // back to the relaunchable tombstone it was a moment ago.
    _ = holder_adopt.run(alloc, &store);
    // Graceful SIGTERM → flush dirty rings before exit (T13b). Started here (the
    // store now exists); SIGTERM was already blocked process-wide by
    // `blockSigterm()` in main before any thread spawned, so this watcher's
    // `sigwait` is its sole consumer. POSIX-only.
    startSigtermWatcher(&store);
    try store.startReaper();

    const stdout = std.fs.File.stdout();
    // Stdout is line-flushed by the OS for a pipe; print + the newline is enough
    // for an orchestrator polling for readiness. (Even though the Windows agent is
    // built as the GUI subsystem so no console pops up, the deploy watcher
    // redirects stdout to a log file — an inherited handle — so this banner is
    // still captured and the readiness poll still works.)
    stdout.writeAll(std.fmt.allocPrint(alloc, "ghoztty-agent {s}: listening on {f}\n", .{ agent_version, bound_addr }) catch "ghoztty-agent: listening\n") catch {};

    // The accept loop is the whole daemon. WHERE it runs depends on the tray:
    //
    //   • Windows + tray (the default, !headless): the Win32 message loop MUST own
    //     the MAIN thread (it pumps the window that owns the tray icon), so we run
    //     the accept loop on a detached worker thread and hand the main thread to
    //     `tray.run`. When the user picks Exit, `tray.run` returns and we exit the
    //     process. If tray setup fails, we FALL BACK to the main-thread accept loop
    //     below — the daemon must never fail to serve because the UI broke.
    //
    //   • Everything else (headless, or any non-Windows OS): run the accept loop on
    //     the MAIN thread exactly as before — unchanged behavior.
    if (builtin.os.tag == .windows and !headless) {
        const args: AcceptArgs = .{
            .alloc = alloc,
            .encoding = encoding,
            .store = &store,
            .spawner = spawner.spawner(),
            .listener = &listener,
            // TCP listener: no peercred gate (loopback + --insecure-allow-public).
            .enforce_same_uid = false,
        };
        if (std.Thread.spawn(.{}, acceptLoopThread, .{args})) |t| {
            // Hand the MAIN thread to the tray message loop. It returns TRUE only if
            // the tray actually showed and the user picked Exit; FALSE if any tray
            // setup step failed (RegisterClass / CreateWindow / Shell_NotifyIcon).
            // No relay link/account/updater in listen mode → null (no
            // Disconnect/Reconnect, Sign in/out, or self-update items).
            if (tray.run(&store, agent_version, null, null, null)) {
                // User chose Exit: flush any dirty output rings first (the tray
                // Exit is a graceful stop — T89a decision 7, the SIGTERM-watcher
                // analog), then a clean process exit tears down the
                // (still-running) accept loop + reaper daemon threads.
                store.snapshotRings();
                std.process.exit(0);
            }
            // Tray setup FAILED — never kill the daemon just because the UI couldn't
            // start. The accept loop is the whole daemon and is already serving on
            // the worker thread; park the main thread on it so the process lives on.
            t.join();
            return;
        } else |err| {
            // Couldn't spawn the worker thread — fall through to the main-thread
            // accept loop so the daemon still serves (no tray, but functional).
            std.debug.print("ghoztty-agent: tray worker spawn failed ({s}); serving headless\n", .{@errorName(err)});
        }
    }

    // Headless / non-windows / tray-fallback: run the accept loop right here.
    try acceptLoop(alloc, encoding, &store, spawner.spawner(), &listener, false);
}

// -----------------------------------------------------------------------------
// Unix-domain-socket listen daemon (`--listen-unix=<path>`): the SECURE local
// transport (design §5.2). Same accept→serve→loop core as TCP, but bound to a
// 0600 filesystem socket and gated with a per-connection same-uid peercred
// check. POSIX-only (Windows uses a named pipe later); parseArgs already
// rejected this mode on Windows.
// -----------------------------------------------------------------------------

fn runListenUnix(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    path: []const u8,
    headless: bool,
    port_file: ?[]const u8,
    sessions_file: ?[]const u8,
) !void {
    _ = headless; // no Windows tray on the unix path; reserved for symmetry.

    // Stale-socket livecheck: if something ANSWERS at `path`, a live agent owns
    // it — refuse rather than clobber. The single-instance guard normally means
    // we never reach here with a live peer, but be defensive if the guard was
    // unavailable (it degrades to "serve anyway"). If nothing answers, remove
    // any leftover socket node so bind() won't fail with AddressInUse.
    if (probeUnixAlive(path)) {
        std.debug.print("ghoztty-agent: a live agent already listens at {s}; exiting\n", .{path});
        return error.AlreadyListening;
    }
    std.fs.cwd().deleteFile(path) catch {}; // ignore ENOENT / not-a-file

    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};

    const addr = std.net.Address.initUnix(path) catch |err| {
        std.debug.print("ghoztty-agent: bad --listen-unix path '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };

    // Bind under a restrictive umask so the socket node is created 0600 from the
    // start (never briefly world-connectable): a 127.0.0.1 TCP port is reachable
    // by ANY local uid, a 0600 socket is not. This is defense in depth on top of
    // the peercred gate below. umask is process-global but we are single-threaded
    // here (before the accept loop spawns any workers), so the swap is safe.
    const prev_umask = std.c.umask(0o177);
    var listener = addr.listen(.{}) catch |err| {
        _ = std.c.umask(prev_umask);
        std.debug.print("ghoztty-agent: failed to bind {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    _ = std.c.umask(prev_umask);
    defer listener.deinit();
    // NOTE: the umask above is the whole story — the socket node is created 0600
    // atomically (never briefly more permissive). We deliberately do NOT
    // `fchmod` the bound socket fd as belt-and-braces: on macOS fchmod of a
    // socket fd returns EINVAL, which std.posix.fchmod maps to `unreachable`
    // (panic) — the same class of trap that once killed the agent via
    // SO_NOSIGPIPE (see socket_stream.zig). umask is both sufficient and safe.

    // Publish an info file for the supervisor that spawned us. A UDS has no
    // ephemeral port to discover, so the body carries {"port":0,"pid":P,
    // "socket":"<path>","startedAt":MS}: `pid` lets the supervisor liveness-
    // check a pre-existing agent and `socket` tells it what to dial. Written
    // AFTER the bind succeeds, atomically (tmp+rename). Fatal on failure — a
    // supervisor waiting on this file would otherwise hang against a silently
    // socket-less agent.
    if (port_file) |pf| {
        writeSocketFile(alloc, pf, path) catch |err| {
            std.debug.print("ghoztty-agent: failed to write --port-file {s}: {s}\n", .{ pf, @errorName(err) });
            return err;
        };
    }

    // DAEMON-SCOPED shared session store + spawner — identical lifetime rules to
    // the TCP path (sessions outlive each connection; the reaper evicts orphans).
    const seed = blk: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };
    var rng = std.Random.DefaultPrng.init(seed);

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    var store = session.SessionStore.init(
        alloc,
        rng.random(),
        undefined,
        realNow,
        session.default_idle_ttl_ms,
    );
    // Reboot-floor metadata store (§5.4, T12) — borrowed; outlives `store`.
    store.meta_path = sessions_file;
    // Reboot scrollback (§5.4, T13): ring snapshots in a `rings/` subdir beside it.
    const rings_dir = ringsDirFor(alloc, sessions_file);
    defer if (rings_dir) |d| alloc.free(d);
    store.rings_dir = rings_dir;
    // Cross-machine "Resume all" (§5.4, T18): layout blobs in `layouts.json` beside it.
    const layouts_file = layoutsFileFor(alloc, sessions_file);
    defer if (layouts_file) |f| alloc.free(f);
    store.layouts_path = layouts_file;
    defer store.deinit();
    // Reboot-floor materialization (§5.4, T12b): re-create the persisted roster as
    // dead, relaunchable tombstones before accepting connections + starting the reaper.
    const materialized = store.loadPersisted(configured_ring_bytes);
    store.loadLayouts();
    // Self-heal: drop any loaded blob whose sessions did not materialize (truly
    // gone), so a stale layouts.json never advertises unattachable windows.
    if (store.reapLayouts() > 0) store.persistLayouts();
    if (materialized > 0) std.log.info("reboot floor: materialized {d} session(s) from disk", .{materialized});
    // Holder re-adoption (T906): before the listener takes its first
    // connection, dial every recorded `--pty-host` holder and pick the live
    // ones back up. A session whose holder answers is ALIVE again — same shell,
    // same scrollback, no restart divider — and one whose holder is gone falls
    // back to the relaunchable tombstone it was a moment ago.
    _ = holder_adopt.run(alloc, &store);
    // Graceful SIGTERM → flush dirty rings before exit (T13b) — see runListen.
    startSigtermWatcher(&store);
    try store.startReaper();

    const stdout = std.fs.File.stdout();
    stdout.writeAll(std.fmt.allocPrint(alloc, "ghoztty-agent {s}: listening on unix:{s}\n", .{ agent_version, path }) catch "ghoztty-agent: listening\n") catch {};

    // Sharing uplink (T546): if this machine is marked shared, raise the relay
    // control loop IN THIS PROCESS over the same persisted store, so remote
    // devices reach the sessions the user actually cares about. The
    // sessions_file slice is borrowed only for path derivation inside the call.
    maybeStartSharingUplink(alloc, encoding, &store, spawner.spawner(), sessions_file);

    // Same accept core as TCP, but with the same-uid peercred gate enabled.
    try acceptLoop(alloc, encoding, &store, spawner.spawner(), &listener, true);
}

// -----------------------------------------------------------------------------
// Windows-named-pipe listen daemon (`--listen-pipe=<name>`, T89c): the SECURE
// local transport on Windows (design §5.2). Same store/serve semantics as the
// unix path, but bound to an owner-only-DACL named pipe: only this user can
// open the pipe, standing in for the unix listener's same-uid peercred gate.
// Windows-only; parseArgs already rejected this mode elsewhere.
// -----------------------------------------------------------------------------

fn runListenPipe(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    name: []const u8,
    headless: bool,
    port_file: ?[]const u8,
    sessions_file: ?[]const u8,
) !void {
    // The LOCAL agent is a background daemon (the LaunchAgent analog): no tray
    // icon — the relay agent owns the visible tray. Reserved for symmetry.
    _ = headless;

    // Bind claims the name via FILE_FLAG_FIRST_PIPE_INSTANCE, which doubles as
    // the liveness probe (`probeUnixAlive` analog): a taken name means a live
    // agent owns it — refuse rather than fight over instances. A DEAD holder
    // needs no unlink step: a Windows pipe name vanishes with its last handle.
    var listener = bindListener(alloc, name) catch |err| {
        if (err == error.AlreadyListening) {
            std.debug.print("ghoztty-agent: a live agent already listens at {s}; exiting\n", .{name});
            return error.AlreadyListening;
        }
        std.debug.print("ghoztty-agent: failed to bind pipe {s}: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    defer listener.deinit();

    // Publish the info file for the supervisor that spawned us. A pipe has no
    // ephemeral port, so the body carries the ADDITIVE `pipe` field:
    // {"port":0,"pid":P,"pipe":"<name>","startedAt":MS} — an old reader
    // ignores the unknown field (agent-contract rules). Written AFTER the bind
    // succeeds, atomically. Fatal on failure, as on the unix path.
    if (port_file) |pf| {
        writePipeFile(alloc, pf, name) catch |err| {
            std.debug.print("ghoztty-agent: failed to write --port-file {s}: {s}\n", .{ pf, @errorName(err) });
            return err;
        };
    }

    // DAEMON-SCOPED shared session store + spawner — identical lifetime rules to
    // the TCP/unix paths (sessions outlive each connection; the reaper evicts
    // orphans past the idle-TTL).
    const seed = blk: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };
    var rng = std.Random.DefaultPrng.init(seed);

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    var store = session.SessionStore.init(
        alloc,
        rng.random(),
        undefined,
        realNow,
        session.default_idle_ttl_ms,
    );
    // Reboot-floor metadata store (§5.4, T12) — borrowed; outlives `store`.
    store.meta_path = sessions_file;
    // Reboot scrollback (§5.4, T13): ring snapshots in a `rings/` subdir beside it.
    const rings_dir = ringsDirFor(alloc, sessions_file);
    defer if (rings_dir) |d| alloc.free(d);
    store.rings_dir = rings_dir;
    // Cross-machine "Resume all" (§5.4, T18): layout blobs in `layouts.json` beside it.
    const layouts_file = layoutsFileFor(alloc, sessions_file);
    defer if (layouts_file) |f| alloc.free(f);
    store.layouts_path = layouts_file;
    defer store.deinit();
    // Reboot-floor materialization (§5.4, T12b): re-create the persisted roster as
    // dead, relaunchable tombstones before accepting connections + starting the reaper.
    const materialized = store.loadPersisted(configured_ring_bytes);
    store.loadLayouts();
    // Self-heal: drop any loaded blob whose sessions did not materialize (truly
    // gone), so a stale layouts.json never advertises unattachable windows.
    if (store.reapLayouts() > 0) store.persistLayouts();
    if (materialized > 0) std.log.info("reboot floor: materialized {d} session(s) from disk", .{materialized});
    // Holder re-adoption (T906): before the listener takes its first
    // connection, dial every recorded `--pty-host` holder and pick the live
    // ones back up. A session whose holder answers is ALIVE again — same shell,
    // same scrollback, no restart divider — and one whose holder is gone falls
    // back to the relaunchable tombstone it was a moment ago.
    _ = holder_adopt.run(alloc, &store);
    // Graceful stop → flush dirty rings before exit: the console-ctrl handler is
    // the Windows analog of the POSIX SIGTERM watcher (T13b). It covers Ctrl-C/
    // Ctrl-Break from a console, console-window close, and logoff/shutdown
    // (WM_ENDSESSION territory — Windows grants ~5s, and the 2MB-bounded rings
    // fit; §5.4 risk (c)).
    startConsoleCtrlWatcher(&store);
    try store.startReaper();

    const stdout = std.fs.File.stdout();
    stdout.writeAll(std.fmt.allocPrint(alloc, "ghoztty-agent {s}: listening on pipe:{s}\n", .{ agent_version, name }) catch "ghoztty-agent: listening\n") catch {};

    // Sharing uplink (T546): if this machine is marked shared, raise the relay
    // control loop IN THIS PROCESS over the same persisted store, so remote
    // devices reach the sessions the user actually cares about. The
    // sessions_file slice is borrowed only for path derivation inside the call.
    maybeStartSharingUplink(alloc, encoding, &store, spawner.spawner(), sessions_file);

    // Adoption (T549): a box that still carries the standalone 'Ghoztty
    // Agent' MSI gets it adopted and retired in the background — sharing kept
    // on, the relay agent stopped only at zero live sessions, the product
    // uninstalled, the Run key repaired. No-op (and silent) everywhere else.
    adopt.maybeStart(alloc, sessions_file);

    // Non-destructive self-replacement (T907): watch for a newer build laid down
    // beside us and hand every holder-backed session to it, with nobody asked and
    // nothing lost. Started AFTER adoption, so the very first check already sees
    // the true holder/legacy split rather than a roster that has not been
    // reconnected yet. Windows-only, and a no-op wherever holders are not in
    // play, so a box with only legacy sessions behaves exactly as it did.
    handoff.Supervisor.start(alloc, &store, agent_version);

    // Accept loop: same serve-each-connection-on-its-own-thread core as the
    // socket paths, over pipe instances. The DACL already gated admission (only
    // this user can open the pipe), so there is no per-connection uid check.
    while (true) {
        const handle = listener.accept() catch |err| {
            // Transient accept failures (e.g. an instance re-create hiccup)
            // must not kill the daemon; brief backoff and keep serving.
            std.debug.print("ghoztty-agent: pipe accept error: {s}\n", .{@errorName(err)});
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        const worker = PipeConnWorker.create(alloc, encoding, &store, spawner.spawner(), handle) catch |err| {
            std.debug.print("ghoztty-agent: failed to start pipe worker: {s}\n", .{@errorName(err)});
            std.os.windows.CloseHandle(handle);
            continue;
        };
        const t = std.Thread.spawn(.{}, PipeConnWorker.run, .{worker}) catch |err| {
            std.debug.print("ghoztty-agent: failed to spawn pipe worker thread: {s}\n", .{@errorName(err)});
            std.os.windows.CloseHandle(handle);
            worker.destroy();
            continue;
        };
        t.detach();
    }
}

/// How long a handoff SUCCESSOR keeps retrying the public pipe bind (T907).
///
/// A retiring agent sends GO and then exits, and a Windows pipe name only
/// vanishes when its last handle closes — so for the few milliseconds between
/// those two events the name is still taken and `FILE_FLAG_FIRST_PIPE_INSTANCE`
/// fails. Retrying is the whole difference between a handoff that works and one
/// that ends with no agent at all; an ordinary launch does NOT retry, because
/// there `AlreadyListening` means a healthy agent owns the name and the right
/// answer is to exit immediately.
const successor_bind_retry_ms: u64 = 10 * std.time.ms_per_s;

/// Bind the public pipe, with the successor's bounded retry when we are one.
fn bindListener(alloc: Allocator, name: []const u8) !pipe_stream.PipeListener {
    const retry = handoffSuccessorPipe() != null;
    var waited: u64 = 0;
    while (true) {
        return pipe_stream.PipeListener.bind(alloc, name) catch |err| {
            if (!retry or err != error.AlreadyListening or waited >= successor_bind_retry_ms) return err;
            std.Thread.sleep(25 * std.time.ns_per_ms);
            waited += 25;
            continue;
        };
    }
}

/// A per-connection worker over one connected pipe instance: the named-pipe
/// mirror of `ConnWorker` (owns the handle, builds a `Mux` + `Server` sharing
/// the daemon `store`, runs until the pipe EOFs, DETACHes — never terminates —
/// its sessions, frees itself). Heap-allocated for its detached thread.
const PipeConnWorker = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    handle: std.os.windows.HANDLE,

    fn create(
        alloc: Allocator,
        encoding: protocol.TransferEncoding,
        store: *session.SessionStore,
        spawner: server.Spawner,
        handle: std.os.windows.HANDLE,
    ) !*PipeConnWorker {
        const self = try alloc.create(PipeConnWorker);
        self.* = .{
            .alloc = alloc,
            .encoding = encoding,
            .store = store,
            .spawner = spawner,
            .handle = handle,
        };
        return self;
    }

    fn destroy(self: *PipeConnWorker) void {
        self.alloc.destroy(self);
    }

    fn run(self: *PipeConnWorker) void {
        var ps = pipe_stream.PipeStream.init(self.handle);
        serveOne(self.alloc, self.encoding, self.store, self.spawner, ps.serverStream()) catch |err| {
            std.debug.print("ghoztty-agent: pipe connection error: {s}\n", .{@errorName(err)});
        };
        // serveOne's mux closed the pipe handle already (mux.close → ps.close).
        self.destroy();
    }
};

/// The store the Windows console-ctrl handler flushes on a graceful stop. Set
/// once (single-threaded, before the handler registers) and read-only after —
/// the handler runs on a fresh console-control thread in ORDINARY context, so
/// the store mutex + file I/O inside `snapshotRings` are safe there (unlike a
/// POSIX signal handler).
var console_ctrl_store: ?*session.SessionStore = null;

/// Register the Windows graceful-stop hook (the `startSigtermWatcher` analog):
/// Ctrl-C/Ctrl-Break, console-window close, and logoff/shutdown all flush any
/// dirty output rings to disk, then exit cleanly. Windows-only no-op elsewhere.
fn startConsoleCtrlWatcher(store: *session.SessionStore) void {
    if (builtin.os.tag != .windows) return;
    console_ctrl_store = store;
    if (SetConsoleCtrlHandler(consoleCtrlHandler, std.os.windows.TRUE) == 0) {
        std.debug.print("ghoztty-agent: SetConsoleCtrlHandler failed; on-stop ring snapshot disabled\n", .{});
    }
}

const SetConsoleCtrlHandler = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn SetConsoleCtrlHandler(
        HandlerRoutine: ?*const fn (std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
        Add: std.os.windows.BOOL,
    ) callconv(.winapi) std.os.windows.BOOL;
}.SetConsoleCtrlHandler else struct {};

fn consoleCtrlHandler(ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    // Every event (CTRL_C/BREAK/CLOSE/LOGOFF/SHUTDOWN) is a stop for a daemon:
    // snapshot and exit(0) — never return, so the default handler can't
    // TerminateProcess us mid-flush on the events that would.
    _ = ctrl_type;
    if (console_ctrl_store) |s| s.snapshotRings();
    std.process.exit(0);
}

/// Whether a live peer answers at the AF_UNIX `path` (a successful connect ⇒
/// something is listening; ECONNREFUSED / ENOENT / anything else ⇒ not live).
/// Used to decide whether a leftover socket node is safe to unlink+rebind.
fn probeUnixAlive(path: []const u8) bool {
    if (path.len == 0) return false;
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return false;
    defer std.posix.close(fd);
    var uaddr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    if (path.len >= uaddr.path.len) return false;
    @memcpy(uaddr.path[0..path.len], path);
    uaddr.path[path.len] = 0;
    std.posix.connect(fd, @ptrCast(&uaddr), @sizeOf(std.posix.sockaddr.un)) catch return false;
    return true;
}

/// `getpeereid(2)`: the effective uid/gid of the peer on a connected AF_UNIX
/// socket. Cross-platform (macOS/BSD `LOCAL_PEERCRED`, Linux `SO_PEERCRED`); not
/// declared in Zig std, so we bind it directly. Absent on Windows (unreachable —
/// the unix listen mode is POSIX-only).
const getpeereid = if (builtin.os.tag == .windows) struct {} else struct {
    extern "c" fn getpeereid(fd: c_int, euid: *posix.uid_t, egid: *posix.uid_t) c_int;
}.getpeereid;

/// The peer's effective uid on an accepted AF_UNIX socket, or null if it can't
/// be read (a null result is treated as "reject" by `shouldServe`).
fn peerUid(fd: posix.socket_t) ?posix.uid_t {
    if (builtin.os.tag == .windows) return null;
    var euid: posix.uid_t = undefined;
    var egid: posix.uid_t = undefined;
    if (getpeereid(fd, &euid, &egid) != 0) return null;
    return euid;
}

/// The same-uid admission decision — pure, so every branch is unit-testable
/// without a real socket or a second uid. When enforcement is off, always serve
/// (TCP path). When on: serve only a peer whose uid is known AND equals ours; an
/// unknown peer (getpeereid failed) is rejected.
fn shouldServe(enforce_same_uid: bool, peer_uid: ?posix.uid_t, our_uid: posix.uid_t) bool {
    if (!enforce_same_uid) return true;
    const uid = peer_uid orelse return false;
    return uid == our_uid;
}

/// Atomically publish the TCP listener's bound port for a supervisor: write
/// `{"port":N,"pid":P,"startedAt":MS}` to `path`. Thin wrapper over
/// `writeInfoFile` with no socket path (the endpoint is a port).
fn writePortFile(alloc: Allocator, path: []const u8, port: u16) !void {
    return writeInfoFile(alloc, path, port, null, null);
}

/// The ring-snapshot directory for a given `--sessions-file`: a `rings/` subdir
/// beside it (e.g. `<state>/sessions.json` → `<state>/rings`), so reboot
/// scrollback snapshots (§5.4, T13) share the metadata store's state dir. Returns
/// null when no sessions file was given (ring snapshots disabled, like the whole
/// reboot floor). Caller frees. A best-effort join failure also yields null.
fn ringsDirFor(alloc: Allocator, sessions_file: ?[]const u8) ?[]u8 {
    const sf = sessions_file orelse return null;
    const dir = std.fs.path.dirname(sf) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, "rings" }) catch null;
}

/// The layout-blob file for a given `--sessions-file`: a `layouts.json` beside
/// it (e.g. `<state>/sessions.json` → `<state>/layouts.json`), so cross-machine
/// "Resume all" blobs (§5.4, T18) share the metadata store's state dir. Returns
/// null when no sessions file was given (layout persistence disabled, like the
/// whole reboot floor). Caller frees.
fn layoutsFileFor(alloc: Allocator, sessions_file: ?[]const u8) ?[]u8 {
    const sf = sessions_file orelse return null;
    const dir = std.fs.path.dirname(sf) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, "layouts.json" }) catch null;
}

/// Atomically publish the UDS listener's socket path for a supervisor: write
/// `{"port":0,"pid":P,"socket":"<socket>","startedAt":MS}` to `path`. A UDS has
/// no port to advertise, so the supervisor dials the socket path instead; `pid`
/// still lets it liveness-check a pre-existing agent.
fn writeSocketFile(alloc: Allocator, path: []const u8, socket: []const u8) !void {
    return writeInfoFile(alloc, path, 0, socket, null);
}

/// Atomically publish the named-pipe listener's pipe name for a supervisor:
/// write `{"port":0,"pid":P,"pipe":"<name>","startedAt":MS}` to `path` (T89c).
/// The `pipe` field is ADDITIVE next to the unix path's `socket` — an old
/// reader ignores it and sees a portless, socketless record it treats as
/// no-endpoint, degrading gracefully per the agent-contract rules.
fn writePipeFile(alloc: Allocator, path: []const u8, pipe: []const u8) !void {
    return writeInfoFile(alloc, path, 0, null, pipe);
}

/// Atomically write the agent info file to `path` (staging sibling + rename,
/// via `atomic_write` — see T183/T500), creating parent directories as
/// needed. `pid` lets the reader liveness-check the writer; `startedAt`
/// (unix ms) lets it spot a stale file from a previous boot; `socket` (when
/// set) carries the UDS path to dial.
fn writeInfoFile(alloc: Allocator, path: []const u8, port: u16, socket: ?[]const u8, pipe: ?[]const u8) !void {
    const content = try formatInfoFile(alloc, port, currentPid(), std.time.milliTimestamp(), socket, pipe);
    defer alloc.free(content);
    try atomic_write.writeChunks(alloc, path, &.{content}, .{});
}

/// The TCP info-file JSON body (pure — separated from the I/O for tests).
fn formatPortFile(alloc: Allocator, port: u16, pid: i64, started_at_ms: i64) ![]u8 {
    return formatInfoFile(alloc, port, pid, started_at_ms, null, null);
}

/// The info-file JSON body (pure — separated from the I/O for tests). With a
/// `socket` path the body gains a `"socket":"<escaped>"` field (the UDS
/// endpoint); with a `pipe` name it gains `"pipe":"<escaped>"` (the Windows
/// named-pipe endpoint, T89c); without either it is the original TCP
/// `{port,pid,startedAt}` shape. Both fields are additive — old readers
/// ignore the one they don't know.
fn formatInfoFile(alloc: Allocator, port: u16, pid: i64, started_at_ms: i64, socket: ?[]const u8, pipe: ?[]const u8) ![]u8 {
    if (socket) |s| {
        const esc = try jsonEscape(alloc, s);
        defer alloc.free(esc);
        return std.fmt.allocPrint(
            alloc,
            "{{\"port\":{d},\"pid\":{d},\"socket\":\"{s}\",\"startedAt\":{d}}}\n",
            .{ port, pid, esc, started_at_ms },
        );
    }
    if (pipe) |p| {
        const esc = try jsonEscape(alloc, p);
        defer alloc.free(esc);
        return std.fmt.allocPrint(
            alloc,
            "{{\"port\":{d},\"pid\":{d},\"pipe\":\"{s}\",\"startedAt\":{d}}}\n",
            .{ port, pid, esc, started_at_ms },
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "{{\"port\":{d},\"pid\":{d},\"startedAt\":{d}}}\n",
        .{ port, pid, started_at_ms },
    );
}

/// Minimal JSON string-body escaping for a filesystem path: `"` and `\` (the
/// only two bytes that would break the surrounding string literal) plus control
/// characters, which are illegal unescaped in a JSON string. Socket paths are
/// app-controlled and won't normally contain these, but escaping keeps the file
/// well-formed for any path.
fn jsonEscape(alloc: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        0x08 => try out.appendSlice(alloc, "\\b"),
        0x0c => try out.appendSlice(alloc, "\\f"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            var hex: [6]u8 = undefined;
            try out.appendSlice(alloc, std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}) catch unreachable);
        } else {
            try out.append(alloc, c);
        },
    };
    return out.toOwnedSlice(alloc);
}

fn currentPid() i64 {
    return switch (builtin.os.tag) {
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

/// Bundles the accept-loop parameters so they can ride a single `std.Thread.spawn`
/// argument (the Windows tray path runs the loop on a worker thread).
const AcceptArgs = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    listener: *std.net.Server,
    enforce_same_uid: bool,
};

/// Thread entry wrapper: run the accept loop, logging (but never propagating) a
/// fatal accept error — this is a detached daemon thread.
fn acceptLoopThread(args: AcceptArgs) void {
    acceptLoop(args.alloc, args.encoding, args.store, args.spawner, args.listener, args.enforce_same_uid) catch |err| {
        std.debug.print("ghoztty-agent: accept loop error: {s}\n", .{@errorName(err)});
    };
}

/// THE DAEMON: accept connections forever, serving each on its own detached
/// thread. This is the loop that was previously inlined in `runListen`; it was
/// extracted verbatim so it can run on EITHER the main thread (headless / non-
/// windows) or a worker thread (so the Windows tray can own the main thread).
fn acceptLoop(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    listener: *std.net.Server,
    /// When true (the `--listen-unix` path), gate every accepted connection on a
    /// `LOCAL_PEERCRED`/`SO_PEERCRED` same-uid check: only a peer running as
    /// THIS user may reach the shell. The TCP path passes false (it relies on
    /// loopback binding + the `--insecure-allow-public` opt-in instead).
    enforce_same_uid: bool,
) !void {
    while (true) {
        const conn = listener.accept() catch |err| switch (err) {
            // Transient accept errors: keep the daemon alive.
            error.ConnectionAborted, error.ConnectionResetByPeer => continue,
            else => return err,
        };
        // Same-uid gate (unix socket): reject — and immediately close — any peer
        // that is not this user, or whose credentials can't be read. A shell is
        // never served to an unauthenticated peer. POSIX-only: the unix listen
        // path never runs on Windows (enforce_same_uid is always false there),
        // and geteuid/peercred don't exist in Windows libc — comptime-gate so
        // the TCP path still links.
        if (builtin.os.tag != .windows) {
            if (enforce_same_uid and !shouldServe(true, peerUid(conn.stream.handle), std.posix.geteuid())) {
                std.debug.print("ghoztty-agent: rejecting unix connection from a non-matching uid\n", .{});
                std.posix.close(conn.stream.handle);
                continue;
            }
        }
        // Serve each accepted connection on its OWN detached thread so the accept
        // loop NEVER blocks on one connection's lifecycle (a slow/dead/wedging client
        // can no longer starve new connections — the P0 "never wedge" guarantee). The
        // per-connection worker owns the socket fd and frees its own resources.
        const worker = ConnWorker.create(alloc, encoding, store, spawner, conn.stream.handle) catch |err| {
            std.debug.print("ghoztty-agent: failed to start worker: {s}\n", .{@errorName(err)});
            std.posix.close(conn.stream.handle);
            continue;
        };
        const t = std.Thread.spawn(.{}, ConnWorker.run, .{worker}) catch |err| {
            std.debug.print("ghoztty-agent: failed to spawn worker thread: {s}\n", .{@errorName(err)});
            worker.destroy();
            continue;
        };
        t.detach();
    }
}

/// Wall-clock `now` for the `SessionStore` (matches its `nowFn` signature).
fn realNow(_: *anyopaque) i64 {
    return std.time.milliTimestamp();
}

// -----------------------------------------------------------------------------
// Graceful SIGTERM → ring snapshot (T13b, §5.4). A launchd stop / logout / plain
// `kill <pid>` delivers SIGTERM; we catch it to flush any dirty output rings to
// disk before exiting, so output produced AFTER the viewer left (T13 only
// snapshots periodically + on a viewer disconnect — an agent that outlives its
// viewer and is then told to stop would otherwise lose that tail) still reaches
// the reboot floor.
//
// SAFE signal handling: we do NOT do work in an async signal handler —
// `snapshotRings` takes the store mutex and does file I/O, both unsafe from a
// handler interrupting an arbitrary thread. Instead SIGTERM is BLOCKED
// process-wide and consumed synchronously by a dedicated `sigwait` watcher
// thread running in ordinary context, where the mutex + I/O are safe.
//
// POSIX-only: Windows has no real SIGTERM (its graceful stop is the tray Exit
// path). `blockSigterm`/`startSigtermWatcher` are no-ops there.
// -----------------------------------------------------------------------------

/// The signal set containing just SIGTERM. Declared once so `blockSigterm` and
/// the watcher's `sigwait` agree on exactly what is blocked and waited on.
fn sigtermSet() posix.sigset_t {
    var set = posix.sigemptyset();
    posix.sigaddset(&set, posix.SIG.TERM);
    return set;
}

/// Block SIGTERM on the CALLING thread (POSIX-only). MUST run on the main thread
/// BEFORE any daemon thread is spawned (the single-instance heartbeat, the
/// reaper, the ring-snapshot watcher, per-connection workers) so every one
/// INHERITS the block — then a process-directed SIGTERM is delivered to none of
/// their default handlers and instead stays pending for the watcher's `sigwait`.
/// `pthread_sigmask` (not `sigprocmask`): the daemon is multi-threaded.
fn blockSigterm() void {
    if (builtin.os.tag == .windows) return;
    var set = sigtermSet();
    var old: posix.sigset_t = undefined;
    _ = std.c.pthread_sigmask(posix.SIG.BLOCK, &set, &old);
}

/// Start the detached watcher thread that turns a graceful SIGTERM into a ring
/// snapshot + clean exit (POSIX-only). Call AFTER `blockSigterm` ran on the main
/// thread (so this thread inherits the block and `sigwait` is the SOLE consumer
/// of SIGTERM) and once `store` exists. A spawn failure only forfeits the
/// on-stop snapshot — the daemon serves regardless.
fn startSigtermWatcher(store: *session.SessionStore) void {
    if (builtin.os.tag == .windows) return;
    const t = std.Thread.spawn(.{}, sigtermWatcherLoop, .{store}) catch |err| {
        std.debug.print("ghoztty-agent: SIGTERM watcher spawn failed ({s}); on-stop ring snapshot disabled\n", .{@errorName(err)});
        return;
    };
    t.detach();
}

/// The watcher loop: `sigwait` for the (already-blocked) SIGTERM, then flush
/// dirty rings and `exit(0)`. The clean exit means launchd's SIGTERM→SIGKILL
/// escalation is never needed. `sigwait` runs in ORDINARY thread context (not a
/// signal handler), so the mutex + file I/O inside `snapshotRings` are safe here.
fn sigtermWatcherLoop(store: *session.SessionStore) void {
    var set = sigtermSet();
    var signo: c_int = 0;
    // Loop past a spurious nonzero return (e.g. EINTR); we only wait on SIGTERM.
    while (std.c.sigwait(&set, &signo) != 0) {}
    store.snapshotRings();
    std.process.exit(0);
}

/// A per-connection worker: owns the accepted socket fd, builds a `Mux` + `Server`
/// over it (sharing the daemon `store`), runs until the socket EOFs, then tears the
/// connection down (DETACHing — never terminating — its sessions) and frees itself.
/// Heap-allocated so it can run on a detached thread.
const ConnWorker = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    fd: std.posix.socket_t,

    fn create(
        alloc: Allocator,
        encoding: protocol.TransferEncoding,
        store: *session.SessionStore,
        spawner: server.Spawner,
        fd: std.posix.socket_t,
    ) !*ConnWorker {
        const self = try alloc.create(ConnWorker);
        self.* = .{
            .alloc = alloc,
            .encoding = encoding,
            .store = store,
            .spawner = spawner,
            .fd = fd,
        };
        return self;
    }

    fn destroy(self: *ConnWorker) void {
        self.alloc.destroy(self);
    }

    fn run(self: *ConnWorker) void {
        var ss = socket_stream.SocketStream.init(self.fd);
        serveOne(self.alloc, self.encoding, self.store, self.spawner, ss.serverStream()) catch |err| {
            std.debug.print("ghoztty-agent: connection error: {s}\n", .{@errorName(err)});
        };
        // serveOne's mux closed the socket fd already (mux.close → ss.close).
        self.destroy();
    }
};

/// The `proto_version` this agent should advertise, from
/// `GHOZTTY_AGENT_PROTO_VERSION`. **DEBUG BUILDS ONLY**, like the app's
/// `GHOZTTY_AGENT_BUNDLED_VERSION` hook, and for the same reason: an
/// incompatible protocol skew cannot be produced from a single tree — both ends
/// compile the same `protocol.proto_version` — so the mandatory-update path a
/// skew is supposed to trigger (T125) would have no way to be exercised on a
/// real agent. Never honored in a release build: a stray env var must not be
/// able to cut a user's app off from its own sessions.
///
/// Null (absent, empty, or unparseable) leaves the pinned version alone.
fn protoVersionOverride(alloc: Allocator) ?u16 {
    // Same gate as `build_config.is_debug`, spelled out because the agent is its
    // own module and does not link the app's build config.
    if (comptime builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return null;
    const v = std.process.getEnvVarOwned(alloc, "GHOZTTY_AGENT_PROTO_VERSION") catch return null;
    defer alloc.free(v);
    const n = std.fmt.parseInt(u16, std.mem.trim(u8, v, " \t\r\n"), 10) catch return null;
    std.log.warn("advertising proto_version {d} instead of {d} (debug test hook)", .{ n, protocol.proto_version });
    return n;
}

/// The pty flavour to advertise in the HELLO: what this build actually spawns,
/// unless `GHOZTTY_AGENT_PTY_FLAVOR` says otherwise.
///
/// The override is a TEST SEAM (T471) and nothing else. The behaviour it exists
/// to reach — a client whose CHILD runs on the other kind of pty — otherwise
/// needs two machines running two operating systems, so on one box there is no
/// way to prove the client took the flavour off the wire rather than off
/// `builtin.os.tag`. Debug/ReleaseSafe only, so a shipped agent can never
/// misreport what it runs; same gate and same shape as
/// `protoVersionOverride`.
fn ptyFlavorOverride(alloc: Allocator) protocol.PtyFlavor {
    if (comptime builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return .local;
    const v = std.process.getEnvVarOwned(alloc, "GHOZTTY_AGENT_PTY_FLAVOR") catch return .local;
    defer alloc.free(v);
    const f = protocol.PtyFlavor.fromString(std.mem.trim(u8, v, " \t\r\n")) orelse {
        std.log.warn("ignoring unknown GHOZTTY_AGENT_PTY_FLAVOR={s}", .{v});
        return .local;
    };
    std.log.warn("advertising pty_flavor {s} instead of {s} (debug test hook)", .{
        f.toString(),
        protocol.PtyFlavor.local.toString(),
    });
    return f;
}

/// Stand up a `Mux` + `Server` over one transport `server.Stream`, sharing the
/// daemon `store` + `spawner`, run until the transport EOFs, then tear the
/// connection down. Shared by both stdio and TCP modes.
fn serveOne(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    transport: server.Stream,
) !void {
    var mux = try mux_mod.Mux.create(alloc, transport, encoding);
    defer mux.destroy();

    // Advertise this machine's hostname in the HELLO so the client can label
    // the window (pill) with the real machine name. Display-only, best-effort.
    var host_buf: [256]u8 = undefined;
    const hostname = hostName(&host_buf);

    const srv = try server.Server.create(
        alloc,
        mux.controlStream(),
        mux.dataStream(),
        spawner,
        store,
        .{
            .encoding = encoding,
            .hostname = hostname,
            .ring_bytes = configured_ring_bytes,
            .build_version = agent_version,
            .proto_version = protoVersionOverride(alloc),
            .pty_flavor = ptyFlavorOverride(alloc),
        },
    );
    defer srv.destroy(alloc);

    try srv.start();

    // Pump the transport → lane fifos until EOF. Blocks this thread.
    mux.pumpInput();

    // EOF: the client hung up. Tear the per-connection server down — this DETACHes
    // (never terminates) its sessions, so they survive in the store for reconnect.
    srv.shutdown();
}

/// This machine's hostname for HELLO display, or null if unavailable. On Windows
/// we ask for the DNS hostname (preserves case, matches `hostname` output) rather
/// than %COMPUTERNAME% (uppercased NetBIOS name).
fn hostName(out: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        var wbuf: [256]u16 = undefined;
        var size: u32 = wbuf.len;
        // 1 == ComputerNameDnsHostname
        if (win32.GetComputerNameExW(1, &wbuf, &size) == 0) return null;
        const n = std.unicode.utf16LeToUtf8(out, wbuf[0..size]) catch return null;
        return if (n == 0) null else out[0..n];
    } else {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const name = std.posix.gethostname(&buf) catch return null;
        if (name.len == 0 or name.len > out.len) return null;
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
}

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetComputerNameExW(
        NameType: c_int,
        lpBuffer: [*]u16,
        nSize: *u32,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

// -----------------------------------------------------------------------------
// Relay daemon (`--relay <url>`): single binary, no Go sidecar, no localhost
// listener. The agent holds an authenticated `wss://.../v1/agent/control`
// WebSocket; on each `{"type":"open","session":S}` command it dials a data
// WebSocket `.../v1/agent/data?session=S` and serves that session over it
// EXACTLY like an accepted TCP socket (same `serveOne` core, same shared store,
// so sessions survive a control reconnect). The relay bridges these WebSockets
// verbatim to the client, so the client reaches this agent end-to-end with no
// inbound port and no subprocess.
// -----------------------------------------------------------------------------

/// BASE delay before redialing after the control connection drops or fails to
/// establish (matches the Go relay-agent's 3s reconnect cadence). Repeated
/// FAST drops (connection died < 30s after connecting — the dup-device-token
/// fight signature) escalate exponentially from this base to a 40× (120s)
/// cap with ±20% jitter, resetting once a connection survives 30s; see
/// `link_control.ReconnectBackoff` for the schedule and its exemptions
/// (dial failures, credential bounces, user Disconnect).
const relay_backoff_ms = 3000;

fn runRelay(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    base_url: []const u8,
    token: []u8,
    token_source: relay_creds.Source,
    headless: bool,
) !void {
    // Convert the https/wss base to a clean `wss://host` prefix (no trailing
    // slash); the per-endpoint paths are appended by the loop/worker. Owned for
    // the life of the daemon.
    const ws_base = try wssBase(alloc, base_url);
    defer alloc.free(ws_base);
    // Host part (scheme stripped): the tray tooltip label and the
    // self-updater's HTTPS host. wssBase guarantees a scheme prefix.
    const ws_host = ws_base[(std.mem.indexOf(u8, ws_base, "://") orelse unreachable) + "://".len ..];

    // DAEMON-SCOPED shared session store + spawner (§7.1 survival) — identical to
    // `runListen`. These OUTLIVE every data connection AND every control
    // reconnect: sessions, their pty children, and their rings keep streaming
    // across a control-WS drop, ready for a reconnecting client to ATTACH.
    const seed = blk: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };
    var rng = std.Random.DefaultPrng.init(seed);

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    var store = session.SessionStore.init(
        alloc,
        rng.random(),
        undefined,
        realNow,
        session.default_idle_ttl_ms,
    );
    defer store.deinit();
    try store.startReaper();

    const stdout = std.fs.File.stdout();
    stdout.writeAll(std.fmt.allocPrint(alloc, "ghoztty-agent {s}: relay mode, control={s}/v1/agent/control\n", .{ agent_version, ws_base }) catch "ghoztty-agent: relay mode\n") catch {};

    // SELF-UPDATE (relay mode only): clear a previous swap's leftovers
    // (`.old`/stale `.new` next to the exe — best-effort; Windows may still
    // hold the `.old` of the process we just replaced), then start the
    // background updater. It stages new binaries from the relay's
    // /dl/version.json and swap+respawns ONLY when `store` has zero live
    // sessions. No-op for dev builds or under GHOSTTY_AGENT_NO_SELFUPDATE=1.
    self_update.cleanupLeftovers(alloc);
    // The returned handle (null if disabled/dev) lets the tray "Check for
    // updates" trigger an immediate check.
    const updater = self_update.maybeStart(alloc, ws_host, agent_version, &store);

    // Tighten the existing relay.env DACL to owner-only (Windows). Freshly
    // written credentials are hardened in saveRelayEnv; this catches installs
    // whose credential predates that, so a self-update fixes them in place.
    enroll.hardenLocalCredential(alloc);

    // User-controlled relay link state (tray Disconnect/Reconnect). The tray
    // toggles it from its message-pump thread; the control loop obeys it.
    // `host` (scheme stripped) is what the tooltip shows: "Connected to <host>".
    var link = link_control.LinkControl{ .host = ws_host };

    // LIVE relay credentials: every control dial snapshots the current token,
    // so a re-enroll's rotation lands on the next dial. Owns `token` from
    // here on. Referenced by the loop thread and the watcher thread; this
    // frame outlives both (runRelay never returns while they run).
    var creds = relay_creds.Creds.init(alloc, token_source, token);
    defer creds.deinit();

    // Watch relay.env so a re-enroll is adopted WITHOUT an agent restart:
    // on a token change the watcher swaps the credential and bounces the
    // control link (tray Disconnect stays parked — bounce never overrides the
    // user's desired state). Watch failures only cost the hot-reload feature,
    // never the daemon (same availability-first policy as tray failures).
    var creds_watch: relay_creds.Watcher = undefined;
    if (enroll.relayEnvPath(alloc)) |env_path| {
        creds_watch = relay_creds.Watcher.init(alloc, env_path, &creds, &link, ws_base);
        if (std.Thread.spawn(.{}, relay_creds.Watcher.run, .{&creds_watch})) |t| {
            t.detach(); // daemon-lifetime thread; nothing ever joins it
        } else |err| {
            std.debug.print("ghoztty-agent: relay.env watch disabled ({s}); a re-enroll needs an agent restart\n", .{@errorName(err)});
            creds_watch.deinit();
        }
    } else |err| {
        std.debug.print("ghoztty-agent: relay.env path unavailable ({s}); a re-enroll needs an agent restart\n", .{@errorName(err)});
    }

    // Tray account controller (Sign in / Sign out + "Signed in as <email>").
    // Reads the live creds + drives the link; borrows `base_url` (http(s) relay
    // base) for whoami/deEnroll/enroll. Lives on this frame (outlives the tray).
    var acct_host_buf: [256]u8 = undefined;
    const acct_name = hostName(&acct_host_buf) orelse "unknown-host";
    var account = tray_account.TrayAccount.init(alloc, base_url, acct_name, &creds, &link);
    // Populate "Signed in as <email>" in the background so the first menu open
    // shows it (best-effort; a menu opened before it lands just shows "Signed in").
    account.requestRefresh();

    // The relay control loop is the whole daemon. WHERE it runs depends on the
    // tray, exactly mirroring `runListen`'s accept-loop placement.
    if (builtin.os.tag == .windows and !headless) {
        const args: RelayArgs = .{
            .alloc = alloc,
            .encoding = encoding,
            .ws_base = ws_base,
            .creds = &creds,
            .store = &store,
            .spawner = spawner.spawner(),
            .link = &link,
        };
        if (std.Thread.spawn(.{}, relayLoopThread, .{args})) |t| {
            if (tray.run(&store, agent_version, &link, &account, updater)) {
                std.process.exit(0); // user chose Exit (from any link state)
            }
            // Tray setup failed: park the main thread on the (already-serving)
            // control loop so the daemon lives on.
            t.join();
            return;
        } else |err| {
            std.debug.print("ghoztty-agent: tray worker spawn failed ({s}); serving headless\n", .{@errorName(err)});
        }
    }

    // Headless / non-windows / tray-fallback: run the control loop right here.
    relayLoop(alloc, encoding, ws_base, &creds, &store, spawner.spawner(), &link);
}

/// Convert an `https://host[:port]` / `wss://host[:port]` base to a normalized
/// `wss://host[:port]` (trailing slashes trimmed). `http://`/`ws://` bases map
/// to a PLAINTEXT `ws://` — loopback test relays only, the same rule as
/// `ws_client.zig` / `http_client.zig` (production relays are always TLS).
/// Owned by the caller.
fn wssBase(alloc: Allocator, base: []const u8) ![]u8 {
    const schemes = [_]struct { prefix: []const u8, out: []const u8 }{
        .{ .prefix = "https://", .out = "wss" },
        .{ .prefix = "wss://", .out = "wss" },
        .{ .prefix = "http://", .out = "ws" },
        .{ .prefix = "ws://", .out = "ws" },
    };
    for (schemes) |s| {
        if (std.mem.startsWith(u8, base, s.prefix)) {
            const trimmed = std.mem.trimRight(u8, base[s.prefix.len..], "/");
            return std.fmt.allocPrint(alloc, "{s}://{s}", .{ s.out, trimmed });
        }
    }
    std.debug.print("ghoztty-agent: --relay url must start with https:// or wss:// (http:// / ws:// are loopback-test only)\n", .{});
    return error.InvalidArgs;
}

/// Bundles the relay-loop parameters so they can ride a single `std.Thread.spawn`
/// argument (the Windows tray path runs the loop on a worker thread).
const RelayArgs = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    creds: *relay_creds.Creds,
    store: *session.SessionStore,
    spawner: server.Spawner,
    link: *link_control.LinkControl,
};

fn relayLoopThread(args: RelayArgs) void {
    relayLoop(args.alloc, args.encoding, args.ws_base, args.creds, args.store, args.spawner, args.link);
}

/// THE RELAY DAEMON: hold the control WebSocket; on drop, back off and reconnect
/// (reusing the SAME store, so sessions survive). The loop itself lives in
/// `link_control.runLoop` so the user-facing suspend/resume transitions (tray
/// Disconnect/Reconnect via `link`) are unit-testable; this function builds the
/// real-WsClient `Transport` it drives. Runs until the process exits (the tray
/// Exit path) — `link.stopLoop` would return it, but nothing calls that today.
fn relayLoop(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    creds: *relay_creds.Creds,
    store: *session.SessionStore,
    spawner: server.Spawner,
    link: *link_control.LinkControl,
) void {
    const ctrl_url = std.fmt.allocPrint(alloc, "{s}/v1/agent/control", .{ws_base}) catch {
        std.debug.print("ghoztty-agent: relay: out of memory building control url\n", .{});
        return;
    };
    defer alloc.free(ctrl_url);

    // Advertise this machine's hostname on the control dial (same source as
    // the HELLO's hostname, see `serveOne`) so the relay can label the device
    // without waiting for a session. The relay tolerates its absence. Lives
    // on this frame, which outlives the loop (runLoop blocks until exit).
    var host_buf: [256]u8 = undefined;
    const maybe_host = hostName(&host_buf);

    var transport = RelayTransport{
        .alloc = alloc,
        .encoding = encoding,
        .ws_base = ws_base,
        .creds = creds,
        .store = store,
        .spawner = spawner,
        .ctrl_url = ctrl_url,
        .host = maybe_host,
    };
    link_control.runLoop(link, transport.transport(), relay_backoff_ms);
}

// -----------------------------------------------------------------------------
// Sharing uplink (T546): the consolidated local agent's OPTIONAL relay uplink.
// The `--listen-pipe`/`--listen-unix` daemon reads `sharing.json` from its
// state dir (see `sharing.zig` for why it lives there and not on the command
// line) and, when sharing is enabled and relay.env holds a credential, runs
// THE SAME relay control loop as `--relay` mode — over the SAME persisted
// `SessionStore` the local transport serves. That is the whole point of the
// one-installer consolidation: the sessions worth transferring live in the
// local store, so the uplink must serve that store, not a second one.
//
// Deliberately NOT here (design decisions, one-installer doc): no tray, no
// tray account, no self-update — the app owns the binary and the UI; this
// daemon stays headless. The local single-instance guard is untouched.
// -----------------------------------------------------------------------------

/// Owns the uplink's state for the daemon's lifetime. Heap-allocated by
/// `maybeStartSharingUplink`; after the initial synchronous reconcile it is
/// touched only by its own tick thread (LinkControl handles the cross-thread
/// traffic with the relay loop).
const SharingUplink = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    /// sharing.json path. Owned.
    config_path: []const u8,
    /// Desired/live link state shared with the relay loop once raised.
    link: link_control.LinkControl = .{},
    /// Whether the relay loop thread (and creds) have been built. Once true,
    /// enable/disable is a park/reconnect on `link`, never a rebuild.
    raised: bool = false,
    /// Owned after a successful raise (daemon lifetime).
    ws_base: ?[]u8 = null,
    creds: ?*relay_creds.Creds = null,
    creds_watch: ?*relay_creds.Watcher = null,
    /// One "sharing is on but there is no credential" line per config change,
    /// not one per 5s tick.
    said_unavailable: bool = false,
    /// Poll cadence; mirrors relay_creds.Watcher (a human-paced toggle).
    poll_interval_ms: u64 = 5_000,
    /// Set by tests to stop the tick thread; production never stops it.
    stop: std.Thread.ResetEvent = .{},

    /// One reconcile: read the config, compare with what is running, act.
    /// Idempotent — safe to run every tick whether or not anything changed
    /// (an enabled flag with a missing relay.env retries here, so writing
    /// the credential AFTER the flag still converges).
    fn reconcile(self: *SharingUplink) void {
        const cfg = sharing.load(self.alloc, self.config_path);
        if (!cfg.enabled) {
            self.said_unavailable = false;
            // Park only a currently-online link so a parked one is not
            // re-woken every tick.
            if (self.raised and self.link.display() != .offline) {
                std.debug.print("ghoztty-agent: sharing disabled; parking the relay uplink (local sessions unaffected)\n", .{});
                self.link.disconnect();
            }
            return;
        }
        if (self.raised) {
            // Enabled and built: make sure it is not parked (no-op when
            // already online — reconnect only flips offline→online).
            self.link.reconnect();
            return;
        }
        self.tryRaise();
    }

    /// Build the uplink: relay.env → wss base + credential → creds watcher +
    /// relay loop thread over the shared store. Failure leaves `raised` false
    /// and is retried on a later tick (all failure modes are "stay local",
    /// never "kill the daemon").
    fn tryRaise(self: *SharingUplink) void {
        const alloc = self.alloc;
        const env_path = enroll.relayEnvPath(alloc) catch |err| {
            self.sayUnavailable("relay.env path unavailable", @errorName(err));
            return;
        };
        var env_path_owned = true;
        defer if (env_path_owned) alloc.free(env_path);

        var env = enroll.loadRelayEnv(alloc, env_path) catch {
            self.sayUnavailable("no relay.env", "enroll this machine first (Share this machine in the chooser)");
            return;
        };
        defer env.deinit(alloc);
        const relay_base = env.relay_base orelse {
            self.sayUnavailable("relay.env has no RELAY_BASE", "re-enroll this machine");
            return;
        };
        const token = env.device_token orelse {
            self.sayUnavailable("relay.env has no device token", "re-enroll this machine");
            return;
        };

        const ws_base = wssBase(alloc, relay_base) catch return; // wssBase already printed why

        // Owner-only DACL on the credential we are about to serve with (same
        // in-place hardening `--relay` mode does).
        enroll.hardenLocalCredential(alloc);

        const creds = alloc.create(relay_creds.Creds) catch {
            alloc.free(ws_base);
            return;
        };
        // Creds takes ownership of the token; keep env.deinit off it.
        env.device_token = null;
        creds.* = relay_creds.Creds.init(alloc, .relay_env, token);

        self.ws_base = ws_base;
        self.creds = creds;
        // "Connected to <host>" label; borrowed from ws_base (daemon lifetime).
        self.link.host = ws_base[(std.mem.indexOf(u8, ws_base, "://") orelse 0) + "://".len ..];

        // Hot credential reload (re-enroll without an agent restart), same
        // watcher as relay mode. Loss of the watcher only costs hot-reload.
        if (alloc.create(relay_creds.Watcher)) |watch| {
            watch.* = relay_creds.Watcher.init(alloc, env_path, creds, &self.link, ws_base);
            env_path_owned = false; // watcher owns it now
            if (std.Thread.spawn(.{}, relay_creds.Watcher.run, .{watch})) |t| {
                t.detach();
                self.creds_watch = watch;
            } else |err| {
                std.debug.print("ghoztty-agent: sharing: relay.env watch disabled ({s}); a re-enroll needs an agent restart\n", .{@errorName(err)});
                watch.deinit(); // frees env_path
                alloc.destroy(watch);
            }
        } else |_| {}

        const args: RelayArgs = .{
            .alloc = alloc,
            .encoding = self.encoding,
            .ws_base = ws_base,
            .creds = creds,
            .store = self.store,
            .spawner = self.spawner,
            .link = &self.link,
        };
        if (std.Thread.spawn(.{}, relayLoopThread, .{args})) |t| {
            t.detach();
            self.raised = true;
            self.said_unavailable = false;
            std.debug.print("ghoztty-agent: sharing enabled; relay uplink raised (control={s}/v1/agent/control)\n", .{ws_base});
        } else |err| {
            // Keep creds/ws_base for the next tick's retry-free reuse? No:
            // simplest correct state is "not raised, resources parked"; the
            // next tick reuses them via the raised==false path only if we
            // free them now. Free and retry from scratch.
            std.debug.print("ghoztty-agent: sharing: relay loop spawn failed ({s}); staying local-only\n", .{@errorName(err)});
            if (self.creds_watch) |w| {
                w.requestStop();
                self.creds_watch = null;
                // Watcher thread frees nothing on exit; its struct + path leak
                // here by design (it may still be mid-tick) — one-shot, tiny.
            }
            self.creds = null;
            self.ws_base = null;
            creds.deinit();
            alloc.destroy(creds);
            alloc.free(ws_base);
        }
    }

    fn sayUnavailable(self: *SharingUplink, what: []const u8, hint: []const u8) void {
        if (self.said_unavailable) return;
        self.said_unavailable = true;
        std.debug.print("ghoztty-agent: sharing is enabled but the uplink cannot start: {s} ({s}); serving local-only until it is fixed\n", .{ what, hint });
    }

    /// Tick thread: reconcile every `poll_interval_ms` until `stop` (tests).
    fn run(self: *SharingUplink) void {
        const interval_ns = self.poll_interval_ms * std.time.ns_per_ms;
        while (true) {
            if (self.stop.timedWait(interval_ns)) {
                return; // stop requested (tests)
            } else |_| {}
            self.reconcile();
        }
    }
};

/// Start the sharing uplink controller for a local listen daemon: resolve the
/// config path (no persistence dir → no sharing, silently), run ONE
/// synchronous reconcile so an enabled flag raises before the daemon starts
/// accepting, then keep reconciling on a background tick thread. All failure
/// modes degrade to "local-only", never to a dead daemon — same
/// availability-first policy as the tray and the creds watcher.
fn maybeStartSharingUplink(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    sessions_file: ?[]const u8,
) void {
    const config_path = sharing.pathFor(alloc, sessions_file) orelse return;
    const self = alloc.create(SharingUplink) catch {
        alloc.free(config_path);
        return;
    };
    self.* = .{
        .alloc = alloc,
        .encoding = encoding,
        .store = store,
        .spawner = spawner,
        .config_path = config_path,
    };
    self.reconcile();
    if (std.Thread.spawn(.{}, SharingUplink.run, .{self})) |t| {
        t.detach(); // daemon-lifetime thread; nothing ever joins it
    } else |err| {
        // The initial reconcile already ran: a startup-enabled uplink is up,
        // only the hot toggle is lost.
        std.debug.print("ghoztty-agent: sharing.json watch disabled ({s}); toggling sharing needs an agent restart\n", .{@errorName(err)});
    }
}

/// One live relay control connection: the WebSocket plus its keepalive
/// (dead-link detection) thread. Heap-allocated per dial so the keepalive's
/// `*Keepalive` stays stable while its thread runs.
const RelayConn = struct {
    ctrl: *ws_client.WsClient,
    /// The device token this connection authenticated with — a `Creds`
    /// snapshot taken at dial time. Session workers spawned off this control
    /// connection reuse it for their data dials (the relay expects the same
    /// credential on both). Stable for the daemon's lifetime (a reload
    /// RETIRES old tokens, never frees them — see `relay_creds.Creds`).
    token: []const u8,
    ka: keepalive.Keepalive,
    ka_thread: ?std.Thread,
};

/// The production `link_control.Transport`: dial the authenticated control
/// WebSocket (+ spawn its keepalive), serve it with `serveControl`, close it
/// via `WsClient.close` (idempotent; unblocks the blocked control read — the
/// same contract the keepalive and the tray's Disconnect rely on).
const RelayTransport = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    creds: *relay_creds.Creds,
    store: *session.SessionStore,
    spawner: server.Spawner,
    ctrl_url: []const u8,
    /// Hostname advertised on the control dial (X-Ghoztty-Hostname), if any.
    /// Borrowed from `relayLoop`'s frame (which outlives the loop).
    host: ?[]const u8,

    fn transport(self: *RelayTransport) link_control.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: link_control.Transport.VTable = .{
        .dial = dial,
        .serve = serve,
        .close = close,
        .deinit = deinit,
    };

    fn dial(ctx: *anyopaque) ?*anyopaque {
        const self: *RelayTransport = @ptrCast(@alignCast(ctx));

        // Snapshot the CURRENT device token per dial: a relay.env reload
        // (re-enroll) swaps it between dials, and the whole point of the
        // watcher's bounce is that THIS dial authenticates with the fresh
        // one. The snapshot stays valid for the connection's lifetime (Creds
        // retires — never frees — superseded tokens).
        const token = self.creds.current();
        const authz = std.fmt.allocPrint(self.alloc, "Bearer {s}", .{token}) catch return null;
        // Headers are only read during the WS handshake; free right after.
        defer self.alloc.free(authz);

        var headers_buf: [2]ws_client.Header = undefined;
        headers_buf[0] = .{ .name = "Authorization", .value = authz };
        var n_headers: usize = 1;
        if (self.host) |hn| {
            headers_buf[n_headers] = .{ .name = "X-Ghoztty-Hostname", .value = hn };
            n_headers += 1;
        }

        const ctrl = ws_client.WsClient.connectUrl(self.alloc, self.ctrl_url, headers_buf[0..n_headers]) catch |err| {
            std.debug.print("ghoztty-agent: relay control connect failed ({s}); retrying (base {d}ms)\n", .{ @errorName(err), relay_backoff_ms });
            return null;
        };
        std.debug.print("ghoztty-agent: relay control connected\n", .{});

        const conn = self.alloc.create(RelayConn) catch {
            ctrl.deinit();
            return null;
        };
        conn.* = .{ .ctrl = ctrl, .token = token, .ka = .{ .link = keepalive.wsLink(ctrl) }, .ka_thread = null };

        // Dead-link detection (the sleep/wake fix): a side thread pings the
        // relay every `ping_interval_ms` and, when NO inbound frame (relay
        // heartbeat / pong / command) arrives within `stale_after_ms`, closes
        // the WebSocket — which unblocks `serveControl`'s blocked read with
        // EOF so the loop redials. Without it, a connection whose peer died
        // while this machine slept blocks in `readMessage` forever. See
        // `keepalive.zig` for the full design rationale.
        conn.ka_thread = std.Thread.spawn(.{}, keepalive.Keepalive.run, .{&conn.ka}) catch |err| blk: {
            std.debug.print("ghoztty-agent: relay keepalive spawn failed ({s}); dead-link detection disabled for this connection\n", .{@errorName(err)});
            break :blk null;
        };
        return conn;
    }

    fn serve(ctx: *anyopaque, connp: *anyopaque) void {
        const self: *RelayTransport = @ptrCast(@alignCast(ctx));
        const conn: *RelayConn = @ptrCast(@alignCast(connp));
        serveControl(self.alloc, self.encoding, self.ws_base, conn.token, self.store, self.spawner, conn.ctrl);
    }

    /// Thread-safe, idempotent; unblocks `serveControl`'s blocked read with
    /// EOF. This is what the tray's Disconnect ends up calling (via
    /// `LinkControl.closeLive`) — and what the keepalive calls on staleness.
    fn close(_: *anyopaque, connp: *anyopaque) void {
        const conn: *RelayConn = @ptrCast(@alignCast(connp));
        conn.ctrl.close();
    }

    fn deinit(ctx: *anyopaque, connp: *anyopaque) void {
        const self: *RelayTransport = @ptrCast(@alignCast(ctx));
        const conn: *RelayConn = @ptrCast(@alignCast(connp));
        // Stop the keepalive BEFORE deinit (it must not touch a freed client).
        // If it went stale it has already returned; requestStop is idempotent.
        if (conn.ka_thread) |t| {
            conn.ka.requestStop();
            t.join();
        }
        conn.ctrl.deinit();
        self.alloc.destroy(conn);
        std.debug.print("ghoztty-agent: relay control ended\n", .{});
    }
};

/// Read control messages until the control WebSocket closes/errors. For each
/// `{"type":"open","session":S}` command, spawn a detached worker that serves
/// that session over its own data WebSocket. Non-`open` messages are ignored.
fn serveControl(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    token: []const u8,
    store: *session.SessionStore,
    spawner: server.Spawner,
    ctrl: *ws_client.WsClient,
) void {
    // One control command per WS message; 4 KiB is ample for the small JSON.
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = ctrl.readMessage(&buf) catch |err| {
            std.debug.print("ghoztty-agent: relay control read error: {s}\n", .{@errorName(err)});
            return;
        };
        if (n == 0) return; // clean close / EOF

        const Msg = struct { type: []const u8 = "", session: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Msg, alloc, buf[0..n], .{ .ignore_unknown_fields = true }) catch {
            // Malformed JSON — ignore, keep the control connection alive.
            continue;
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.type, "open")) continue;
        if (parsed.value.session.len == 0) continue;

        // Dup the session id for the detached worker (parsed.deinit frees it here).
        const session_id = alloc.dupe(u8, parsed.value.session) catch continue;

        const worker = RelayWorker.create(alloc, encoding, ws_base, token, store, spawner, session_id) catch |err| {
            std.debug.print("ghoztty-agent: relay: failed to start session worker: {s}\n", .{@errorName(err)});
            alloc.free(session_id);
            continue;
        };
        const t = std.Thread.spawn(.{}, RelayWorker.run, .{worker}) catch |err| {
            std.debug.print("ghoztty-agent: relay: failed to spawn session worker: {s}\n", .{@errorName(err)});
            worker.destroy();
            continue;
        };
        t.detach();
    }
}

/// A per-session relay worker: dials the session's data WebSocket and serves it
/// over the SAME `serveOne` core (sharing the daemon `store`/`spawner`) as a TCP
/// connection, then frees itself. `ws_base`/`token` are borrowed (ws_base lives
/// for the daemon's lifetime; token is the control connection's Creds snapshot,
/// which `relay_creds.Creds` keeps alive for the daemon's lifetime even across
/// a reload); `session_id` is owned and freed on teardown.
const RelayWorker = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    token: []const u8,
    store: *session.SessionStore,
    spawner: server.Spawner,
    session_id: []const u8,

    fn create(
        alloc: Allocator,
        encoding: protocol.TransferEncoding,
        ws_base: []const u8,
        token: []const u8,
        store: *session.SessionStore,
        spawner: server.Spawner,
        session_id: []const u8,
    ) !*RelayWorker {
        const self = try alloc.create(RelayWorker);
        self.* = .{
            .alloc = alloc,
            .encoding = encoding,
            .ws_base = ws_base,
            .token = token,
            .store = store,
            .spawner = spawner,
            .session_id = session_id,
        };
        return self;
    }

    fn destroy(self: *RelayWorker) void {
        self.alloc.free(self.session_id);
        self.alloc.destroy(self);
    }

    fn run(self: *RelayWorker) void {
        defer self.destroy();

        const url = std.fmt.allocPrint(self.alloc, "{s}/v1/agent/data?session={s}", .{ self.ws_base, self.session_id }) catch return;
        defer self.alloc.free(url);
        const authz = std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.token}) catch return;
        defer self.alloc.free(authz);
        const headers = [_]ws_client.Header{.{ .name = "Authorization", .value = authz }};

        const dc = ws_client.WsClient.connectUrl(self.alloc, url, &headers) catch |err| {
            std.debug.print("ghoztty-agent: relay data dial (session {s}): {s}\n", .{ self.session_id, @errorName(err) });
            return;
        };
        // serveOne's mux closes the data stream (dc.close) on EOF; `deinit` is the
        // final close + free of the WebSocket.
        serveOne(self.alloc, self.encoding, self.store, self.spawner, dc.serverStream()) catch |err| {
            std.debug.print("ghoztty-agent: relay session {s} error: {s}\n", .{ self.session_id, @errorName(err) });
        };
        dc.deinit();
    }
};

test {
    std.testing.refAllDecls(@This());
    // Not reachable via pub decls, so reference explicitly for test discovery.
    _ = @import("link_control.zig");
    _ = @import("pty_host_proto.zig");
    _ = @import("pty_host_spec.zig");
    _ = @import("pty_holder_child.zig");
    _ = @import("holder_adopt.zig");
    _ = @import("handoff.zig");
    _ = @import("relay_creds.zig");
    _ = @import("sharing.zig");
    _ = @import("adopt.zig");
    _ = @import("self_update.zig");
    _ = @import("single_instance.zig");
    _ = @import("../agent_lineage.zig");
    _ = @import("descendants.zig");
    _ = @import("proc.zig");
}

test "decideRelayCred: env token wins over relay.env" {
    try std.testing.expectEqual(RelayCredDecision.use_env, decideRelayCred(true, true, false));
    try std.testing.expectEqual(RelayCredDecision.use_env, decideRelayCred(true, false, true));
}

test "decideRelayCred: relay.env token when no env token" {
    try std.testing.expectEqual(RelayCredDecision.use_relay_env, decideRelayCred(false, true, false));
    try std.testing.expectEqual(RelayCredDecision.use_relay_env, decideRelayCred(false, true, true));
}

test "decideRelayCred: no cred + headless errors (no surprise browser on servers)" {
    try std.testing.expectEqual(RelayCredDecision.fail, decideRelayCred(false, false, true));
}

test "decideRelayCred: no cred + interactive auto-enrolls (MSI first launch)" {
    try std.testing.expectEqual(RelayCredDecision.auto_enroll, decideRelayCred(false, false, false));
}

test "parseRingBytes: plain byte count, floor, and junk rejection (T11)" {
    // A valid value above the floor parses.
    try std.testing.expectEqual(@as(?usize, 16 * 1024 * 1024), parseRingBytes("16777216"));
    // Surrounding whitespace is trimmed (env values sometimes carry it).
    try std.testing.expectEqual(@as(?usize, 65536), parseRingBytes("  65536\n"));
    // Exactly the floor is accepted; one below is rejected → null (keep default).
    try std.testing.expectEqual(@as(?usize, min_ring_bytes), parseRingBytes("65536"));
    try std.testing.expectEqual(@as(?usize, null), parseRingBytes("65535"));
    // Junk / empty / negative → null.
    try std.testing.expectEqual(@as(?usize, null), parseRingBytes("2MB"));
    try std.testing.expectEqual(@as(?usize, null), parseRingBytes(""));
    try std.testing.expectEqual(@as(?usize, null), parseRingBytes("-1"));
}

test "parseMaxSessions: 1..max_sessions, and never a raised ceiling (T469)" {
    // The useful range — 1 is what an acceptance script sets to make the second
    // pane a refusal.
    try std.testing.expectEqual(@as(?usize, 1), parseMaxSessions("1"));
    try std.testing.expectEqual(@as(?usize, 8), parseMaxSessions(" 8\n"));
    try std.testing.expectEqual(@as(?usize, session.max_sessions), parseMaxSessions("256"));

    // 0 would be an agent that can open nothing — a wedge, not a configuration.
    try std.testing.expectEqual(@as(?usize, null), parseMaxSessions("0"));
    // Above the compile-time cap is refused: this knob exists to make the
    // refusal path reachable, not to raise a ceiling the tombstone bookkeeping
    // and ring budget were sized against.
    try std.testing.expectEqual(@as(?usize, null), parseMaxSessions("257"));
    // Junk / empty / negative → null (keep the default).
    try std.testing.expectEqual(@as(?usize, null), parseMaxSessions("lots"));
    try std.testing.expectEqual(@as(?usize, null), parseMaxSessions(""));
    try std.testing.expectEqual(@as(?usize, null), parseMaxSessions("-1"));
}

test "port file: JSON body carries port/pid/startedAt" {
    const alloc = std.testing.allocator;
    const body = try formatPortFile(alloc, 54321, 987, 1770000000000);
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 54321), parsed.value.object.get("port").?.integer);
    try std.testing.expectEqual(@as(i64, 987), parsed.value.object.get("pid").?.integer);
    try std.testing.expectEqual(@as(i64, 1770000000000), parsed.value.object.get("startedAt").?.integer);
}

test "port file: bind port 0 → write file → read back live port → dial it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Exactly what runListen does for `--listen=127.0.0.1:0 --port-file=...`:
    // bind ephemeral, resolve the real port from listen_address, publish it.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const bound_port = listener.listen_address.getPort();
    try std.testing.expect(bound_port != 0);

    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    // Nested path proves parent-directory creation (the supervisor's config
    // dir may not exist yet on first spawn).
    const path = try std.fs.path.join(alloc, &.{ dir_path, "nested", "port.json" });
    defer alloc.free(path);

    try writePortFile(alloc, path, bound_port);

    // A supervisor's read: parse the file, dial the advertised port.
    const body = try std.fs.cwd().readFileAlloc(alloc, path, 4096);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const file_port: u16 = @intCast(parsed.value.object.get("port").?.integer);
    try std.testing.expectEqual(bound_port, file_port);
    try std.testing.expectEqual(currentPid(), parsed.value.object.get("pid").?.integer);
    try std.testing.expect(parsed.value.object.get("startedAt").?.integer > 0);

    const dial_addr = try std.net.Address.parseIp("127.0.0.1", file_port);
    const conn = try std.net.tcpConnectToAddress(dial_addr);
    conn.close();

    // Rewrite (agent restart reusing the same path) must replace the file.
    try writePortFile(alloc, path, bound_port);

    // No staging leftover of ANY name — the directory holds exactly the
    // published file (T500, the T183 tests' stronger form).
    var pdir = try std.fs.cwd().openDir(std.fs.path.dirname(path).?, .{ .iterate = true });
    defer pdir.close();
    var it = pdir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        count += 1;
        try std.testing.expectEqualStrings("port.json", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

// --- T09: --listen-unix transport + same-uid peercred gate -------------------

test "shouldServe: same-uid admission decision (all branches)" {
    const our: posix.uid_t = 501;
    // Enforcement OFF (the TCP path): always serve, regardless of peer.
    try std.testing.expect(shouldServe(false, null, our));
    try std.testing.expect(shouldServe(false, 999, our));
    // Enforcement ON: serve only a KNOWN peer whose uid equals ours.
    try std.testing.expect(shouldServe(true, our, our));
    // Different uid → reject.
    try std.testing.expect(!shouldServe(true, 999, our));
    // Unknown peer (getpeereid failed → null) → reject, never serve blind.
    try std.testing.expect(!shouldServe(true, null, our));
}

/// A short, unique AF_UNIX path under the system tmp dir (the sun_path field is
/// only ~104 bytes on macOS, so a nested tmpDir realpath can overflow it).
fn testSockPath(buf: []u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/gztt-t09-{s}-{d}.sock", .{ tag, currentPid() });
}

test "listen-unix: peerUid on a real accepted connection is our uid; gate passes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pbuf: [128]u8 = undefined;
    const path = try testSockPath(&pbuf, "peer");
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    const addr = try std.net.Address.initUnix(path);
    var listener = try addr.listen(.{});
    defer listener.deinit();

    // Connect a client (same process ⇒ same uid) and accept the server end.
    const client_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(client_fd);
    var uaddr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    @memcpy(uaddr.path[0..path.len], path);
    uaddr.path[path.len] = 0;
    try std.posix.connect(client_fd, @ptrCast(&uaddr), @sizeOf(std.posix.sockaddr.un));

    const conn = try listener.accept();
    defer std.posix.close(conn.stream.handle);

    // The accept-path credential read: the peer's uid is known and is ours.
    const uid = peerUid(conn.stream.handle);
    try std.testing.expectEqual(std.posix.geteuid(), uid.?);
    // And the gate that acceptLoop applies admits it.
    try std.testing.expect(shouldServe(true, uid, std.posix.geteuid()));
}

test "listen-unix: bind creates a 0600 socket node (umask), probeUnixAlive sees it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pbuf: [128]u8 = undefined;
    const path = try testSockPath(&pbuf, "perm");
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    // Nothing bound yet ⇒ not alive.
    try std.testing.expect(!probeUnixAlive(path));

    // Bind under the same restrictive umask runListenUnix uses.
    const prev = std.c.umask(0o177);
    const addr = try std.net.Address.initUnix(path);
    var listener = try addr.listen(.{});
    _ = std.c.umask(prev);
    defer listener.deinit();

    // The node is 0600 (never group/other-accessible) — the whole point vs a
    // 127.0.0.1 TCP port that any local uid can reach.
    const st = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(@as(u16, 0o600), @as(u16, @intCast(st.mode & 0o777)));

    // A live listener answers the connect-probe used for stale-socket cleanup.
    try std.testing.expect(probeUnixAlive(path));
}

test "socket info file: JSON body carries port:0/pid/socket/startedAt" {
    const alloc = std.testing.allocator;
    const body = try formatInfoFile(alloc, 0, 987, 1770000000000, "/tmp/agent.sock", null);
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    // Port is 0 (a UDS has no port); the supervisor keys off `socket` instead.
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("port").?.integer);
    try std.testing.expectEqual(@as(i64, 987), parsed.value.object.get("pid").?.integer);
    try std.testing.expectEqualStrings("/tmp/agent.sock", parsed.value.object.get("socket").?.string);
    try std.testing.expectEqual(@as(i64, 1770000000000), parsed.value.object.get("startedAt").?.integer);
}

test "socket info file: path with quote/backslash stays well-formed JSON" {
    const alloc = std.testing.allocator;
    // A pathological path (quotes/backslashes are legal in POSIX filenames):
    // the escaper must keep the body parseable and the value byte-exact.
    const weird = "/tmp/a\"b\\c.sock";
    const body = try formatInfoFile(alloc, 0, 1, 2, weird, null);
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(weird, parsed.value.object.get("socket").?.string);
}

test "pipe info file: JSON body carries port:0/pid/pipe/startedAt (T89c)" {
    const alloc = std.testing.allocator;
    const body = try formatInfoFile(alloc, 0, 987, 1770000000000, null, "\\\\.\\pipe\\ghoztty-agent-test");
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    // Port is 0 (a pipe has no port); the supervisor keys off `pipe` instead.
    // The backslashes in the pipe path MUST round-trip through the escaper.
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("port").?.integer);
    try std.testing.expectEqual(@as(i64, 987), parsed.value.object.get("pid").?.integer);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\ghoztty-agent-test", parsed.value.object.get("pipe").?.string);
    try std.testing.expectEqual(@as(i64, 1770000000000), parsed.value.object.get("startedAt").?.integer);
    try std.testing.expect(parsed.value.object.get("socket") == null);
}

test "socket info file: bind unix socket → write file → read back pid+socket" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var pbuf: [128]u8 = undefined;
    const sock = try testSockPath(&pbuf, "info");
    std.fs.cwd().deleteFile(sock) catch {};
    defer std.fs.cwd().deleteFile(sock) catch {};

    // Exactly what runListenUnix does: bind, then publish the socket path.
    const addr = try std.net.Address.initUnix(sock);
    var listener = try addr.listen(.{});
    defer listener.deinit();

    var ibuf: [160]u8 = undefined;
    const info = try std.fmt.bufPrint(&ibuf, "/tmp/gztt-t09c-info-{d}.json", .{currentPid()});
    std.fs.cwd().deleteFile(info) catch {};
    defer std.fs.cwd().deleteFile(info) catch {};

    try writeSocketFile(alloc, info, sock);

    // A supervisor's read: parse the file, learn pid + socket, dial the socket.
    const body = try std.fs.cwd().readFileAlloc(alloc, info, 4096);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(currentPid(), parsed.value.object.get("pid").?.integer);
    try std.testing.expectEqualStrings(sock, parsed.value.object.get("socket").?.string);
    try std.testing.expect(parsed.value.object.get("startedAt").?.integer > 0);

    // The advertised socket actually dials (proves the published path is live).
    try std.testing.expect(probeUnixAlive(sock));

    // No staging leftover of ANY name. The info file lives in the shared /tmp,
    // so instead of exact directory contents: nothing but the file itself may
    // start with its (pid-unique) basename (T500).
    const base = std.fs.path.basename(info);
    var tdir = try std.fs.cwd().openDir("/tmp", .{ .iterate = true });
    defer tdir.close();
    var it = tdir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, base)) continue;
        try std.testing.expectEqualStrings(base, entry.name);
    }
}

test "wssBase: https/wss normalize to wss; http/ws stay plaintext; others refused" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "https://relay.example.com/", .want = "wss://relay.example.com" },
        .{ .in = "wss://relay.example.com", .want = "wss://relay.example.com" },
        .{ .in = "http://127.0.0.1:8080/", .want = "ws://127.0.0.1:8080" },
        .{ .in = "ws://127.0.0.1:8080", .want = "ws://127.0.0.1:8080" },
    };
    for (cases) |c| {
        const got = try wssBase(alloc, c.in);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
    try std.testing.expectError(error.InvalidArgs, wssBase(alloc, "relay.example.com"));
}
