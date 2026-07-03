//! `ghoztty-agent` entry point (WP2, §4.1–§4.2/§7.1) — the remote-host daemon.
//!
//! Three transport modes share the SAME session-server core (`server.zig`, real
//! pty-backed children via `pty_child.zig`) and the SAME lane mux (`mux.zig`):
//!
//!   1. **stdio** (`--stdio`, or the default when stdin is not a tty / no listen
//!      addr): read framed protocol from stdin, write to stdout. This is the
//!      `ssh host -- ghoztty-agent` path (§4.1). One stdin/stdout pipe pair, both
//!      logical lanes muxed onto it. Shuts down on stdin EOF (client hung up).
//!
//!   2. **TCP listen daemon** (`--listen <addr:port>`, default `0.0.0.0:7777` when
//!      run with NO args): bind, listen, then loop — accept a connection and serve
//!      it on its OWN thread (a `Mux` + `Server` over the socket, sharing the
//!      daemon-scoped session store), so the accept loop NEVER blocks on one
//!      connection's lifecycle. The real-network backbone for cross-machine tests
//!      (Mac ↔ Windows over Tailscale).
//!
//!   3. **Relay daemon** (`--relay <url>`): the single-binary rendezvous path (no
//!      Go sidecar, no inbound port). Hold an authenticated `wss://` control
//!      WebSocket to the relay; on each `{"type":"open","session":S}` command,
//!      dial a per-session data WebSocket and serve it over the SAME `serveOne`
//!      core (shared store) as an accepted socket. The device token is read from
//!      `GHOSTTY_DEVICE_TOKEN`, falling back to the agent's persisted
//!      `relay.env` (see `enroll.zig`); relay.env is then WATCHED so a
//!      re-enroll's new token is adopted without a restart (`relay_creds.zig`).
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
//! (`session.default_idle_ttl_ms`, 10 min) so abandoned shells don't leak.
//!
//! ### SECURITY (this increment)
//! The TCP listener is **unauthenticated**: any host that can reach the port can
//! open a shell session on this machine. It relies entirely on network trust
//! (Tailscale / a trusted LAN / `127.0.0.1`). Do NOT expose it on an untrusted
//! network. Auth (a shared token / mTLS) is a later increment.
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
//!     modes `--listen`/`--relay` take a per-user-session guard — named mutex
//!     on Windows, flock on POSIX — and a losing instance exits with code 183;
//!     see `single_instance.zig`. `--stdio` and `--enroll` are exempt.)
//!   - RPC, tunnels, multi-client fan-out to one session (§5.3 steal).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const protocol = @import("../protocol.zig");
const server = @import("server.zig");
const session = @import("session.zig");
const pty_child = @import("pty_child.zig");
const mux_mod = @import("mux.zig");
const socket_stream = @import("../socket_stream.zig");
const ws_client = @import("../ws_client.zig");
const tray = @import("tray.zig");
const enroll = @import("enroll.zig");
const keepalive = @import("keepalive.zig");
const link_control = @import("link_control.zig");
const relay_creds = @import("relay_creds.zig");
const single_instance = @import("single_instance.zig");

const default_listen = "0.0.0.0:7777";

/// Short build identifier shown in the Windows tray About line. No build/version
/// constant is wired into the agent's standalone module graph (it roots at `src/`
/// without `build_config`), so a literal placeholder is used; `// TODO(version)`
/// thread the real version through if/when the agent module gains build_config.
const build_hash = "dev";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // The transfer encoding is fixed at construction (the client pins it in HELLO).
    // Default to raw; `GHOZTTY_AGENT_ENCODING` overrides it (deterministic tests).
    const encoding = encodingFromEnv(alloc);

    const mode = try parseArgs(alloc);
    switch (mode) {
        .stdio => try runStdio(alloc, encoding),
        .listen => |l| {
            // DAEMON mode: enforce single-instance BEFORE anything user-visible
            // (bind, banner, tray icon). Exits the process on conflict.
            var guard = acquireDaemonLockOrExit(alloc);
            defer if (guard) |*g| g.release();
            try runListen(alloc, encoding, l.addr, l.headless);
        },
        .relay => |r| {
            // DAEMON mode: single-instance first (before the token lookup and
            // long before the tray could flash an icon).
            var guard = acquireDaemonLockOrExit(alloc);
            defer if (guard) |*g| g.release();
            // The device token authenticates the relay WebSockets. Required.
            // Precedence: the GHOSTTY_DEVICE_TOKEN env var wins; otherwise fall
            // back to the agent's own relay.env (written by `--enroll` and by
            // the Windows installer), so enroll → run needs no env plumbing.
            // The SOURCE travels along: a relay.env sourced token may be hot-
            // reloaded on a re-enroll, an env-sourced one never is (see
            // `relay_creds.zig`).
            const TokenInit = struct { token: []u8, source: relay_creds.Source };
            const ti: TokenInit = blk: {
                if (std.process.getEnvVarOwned(alloc, "GHOSTTY_DEVICE_TOKEN")) |t| break :blk .{ .token = t, .source = .env } else |_| {}
                if (enroll.loadDeviceToken(alloc)) |t| break :blk .{ .token = t, .source = .relay_env };
                std.debug.print(
                    "ghoztty-agent: --relay needs a device token: set GHOSTTY_DEVICE_TOKEN " ++
                        "or enroll this machine first with `ghoztty-agent --enroll --relay=<base>`\n",
                    .{},
                );
                // This is the only relay-mode path that returns (runRelay loops
                // forever), so free the duped URL to keep the GPA exit clean.
                alloc.free(r.base_url);
                return error.MissingDeviceToken;
            };
            // Token ownership moves into runRelay's `Creds` (it must stay
            // alive as long as any connection borrows a snapshot of it).
            try runRelay(alloc, encoding, r.base_url, ti.token, ti.source, r.headless);
        },
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

/// Take the per-user-session daemon single-instance guard (named mutex on
/// Windows, flock on POSIX — see `single_instance.zig`). Three outcomes:
///   - acquired → return the guard; hold it for the daemon's lifetime (the OS
///     releases it on exit OR crash, so no cleanup ordering matters).
///   - already running → log + exit with `single_instance.already_running_exit_code`
///     (183). The message + distinct code make a supervisor's respawn-and-exit
///     loop self-explanatory in its captured stderr log.
///   - guard infrastructure failed → log a warning and return null: the daemon
///     serves anyway (availability beats guard integrity, same policy as tray
///     failures).
/// Called BEFORE any user-visible daemon setup (bind / banner / tray icon), so
/// a losing instance never flashes a tray icon or steals the port.
fn acquireDaemonLockOrExit(alloc: Allocator) ?single_instance.Guard {
    return single_instance.acquire(alloc) catch |err| switch (err) {
        error.AlreadyRunning => {
            // std.debug.print writes stderr, which the supervisors (installer
            // launcher / deploy watcher) redirect to agent.err.log — visible
            // even though the Windows agent is a GUI-subsystem exe.
            std.debug.print("ghoztty-agent: another instance is already running; exiting\n", .{});
            std.process.exit(single_instance.already_running_exit_code);
        },
        error.GuardUnavailable => {
            std.debug.print("ghoztty-agent: warning: single-instance guard unavailable; continuing without it\n", .{});
            return null;
        },
    };
}

fn encodingFromEnv(alloc: Allocator) protocol.TransferEncoding {
    const v = std.process.getEnvVarOwned(alloc, "GHOZTTY_AGENT_ENCODING") catch return .raw;
    defer alloc.free(v);
    if (std.ascii.eqlIgnoreCase(v, "cobs")) return .cobs;
    if (std.ascii.eqlIgnoreCase(v, "base64")) return .base64;
    return .raw;
}

const Mode = union(enum) {
    stdio,
    listen: Listen,
    relay: Relay,
    enroll: Enroll,
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
const Relay = struct {
    base_url: []const u8,
    headless: bool = false,
};

/// TCP listen-daemon parameters. `headless` suppresses the Windows system-tray
/// icon (for CI / non-interactive runs); the default (tray ON) is what the deploy
/// watcher uses so the human running the Windows box gets a visible daemon handle.
const Listen = struct {
    addr: std.net.Address,
    headless: bool = false,
};

/// Parse `--stdio` | `--listen <addr:port>` | `--relay <url>` |
/// `--enroll --relay <url>` | (no args ⇒ default TCP listen).
/// `--headless` (anywhere on the line) suppresses the tray for listen mode; the
/// stdio path is ALWAYS headless (an ssh-piped agent has no desktop to draw on).
/// `--enroll` (anywhere on the line) turns the `--relay` base into a one-shot
/// enrollment instead of the relay daemon; `--no-browser`/`--headless-enroll`
/// makes that enrollment use the device-code flow instead of the browser.
fn parseArgs(alloc: Allocator) !Mode {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // Pre-scan for the order-independent flags so they can appear before OR
    // after the mode argument they modify.
    var headless = false;
    var want_enroll = false;
    var no_browser = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--headless")) headless = true;
        if (std.mem.eql(u8, a, "--enroll")) want_enroll = true;
        if (std.mem.eql(u8, a, "--no-browser") or
            std.mem.eql(u8, a, "--headless-enroll")) no_browser = true;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--headless") or std.mem.eql(u8, a, "--enroll") or
            std.mem.eql(u8, a, "--no-browser") or std.mem.eql(u8, a, "--headless-enroll"))
        {
            continue; // handled in the pre-scan above
        } else if (std.mem.eql(u8, a, "--stdio")) {
            return .stdio;
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ghoztty-agent: --listen requires <addr:port>\n", .{});
                return error.InvalidArgs;
            }
            return .{ .listen = .{ .addr = try parseAddr(args[i]), .headless = headless } };
        } else if (std.mem.startsWith(u8, a, "--listen=")) {
            return .{ .listen = .{ .addr = try parseAddr(a["--listen=".len..]), .headless = headless } };
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
            return .{ .relay = .{ .base_url = url, .headless = headless } };
        } else if (std.mem.startsWith(u8, a, "--relay=")) {
            const url = try alloc.dupe(u8, a["--relay=".len..]);
            if (want_enroll) return .{ .enroll = .{ .base_url = url, .no_browser = no_browser } };
            return .{ .relay = .{ .base_url = url, .headless = headless } };
        } else {
            std.debug.print("ghoztty-agent: unknown argument '{s}'\n", .{a});
            return error.InvalidArgs;
        }
    }
    if (want_enroll) {
        std.debug.print("ghoztty-agent: --enroll requires --relay=<base url>\n", .{});
        return error.InvalidArgs;
    }
    // No args: default to the TCP listen daemon so a bare invocation "just works".
    return .{ .listen = .{ .addr = try parseAddr(default_listen), .headless = headless } };
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
) !void {
    var listener = addr.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("ghoztty-agent: failed to bind {f}: {s}\n", .{ addr, @errorName(err) });
        return err;
    };
    defer listener.deinit();

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
    defer store.deinit();
    try store.startReaper();

    const stdout = std.fs.File.stdout();
    // Stdout is line-flushed by the OS for a pipe; print + the newline is enough
    // for an orchestrator polling for readiness. (Even though the Windows agent is
    // built as the GUI subsystem so no console pops up, the deploy watcher
    // redirects stdout to a log file — an inherited handle — so this banner is
    // still captured and the readiness poll still works.)
    stdout.writeAll(std.fmt.allocPrint(alloc, "ghoztty-agent: listening on {f}\n", .{addr}) catch "ghoztty-agent: listening\n") catch {};

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
        };
        if (std.Thread.spawn(.{}, acceptLoopThread, .{args})) |t| {
            // Hand the MAIN thread to the tray message loop. It returns TRUE only if
            // the tray actually showed and the user picked Exit; FALSE if any tray
            // setup step failed (RegisterClass / CreateWindow / Shell_NotifyIcon).
            // No relay link in listen mode → null (no Disconnect/Reconnect items).
            if (tray.run(&store, build_hash, null)) {
                // User chose Exit: a clean process exit tears down the (still-running)
                // accept loop + reaper daemon threads.
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
    try acceptLoop(alloc, encoding, &store, spawner.spawner(), &listener);
}

/// Bundles the accept-loop parameters so they can ride a single `std.Thread.spawn`
/// argument (the Windows tray path runs the loop on a worker thread).
const AcceptArgs = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    listener: *std.net.Server,
};

/// Thread entry wrapper: run the accept loop, logging (but never propagating) a
/// fatal accept error — this is a detached daemon thread.
fn acceptLoopThread(args: AcceptArgs) void {
    acceptLoop(args.alloc, args.encoding, args.store, args.spawner, args.listener) catch |err| {
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
) !void {
    while (true) {
        const conn = listener.accept() catch |err| switch (err) {
            // Transient accept errors: keep the daemon alive.
            error.ConnectionAborted, error.ConnectionResetByPeer => continue,
            else => return err,
        };
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
        .{ .encoding = encoding, .hostname = hostname },
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

/// How long to back off before retrying after the control connection drops or
/// fails to establish (matches the Go relay-agent's 3s reconnect cadence).
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
    stdout.writeAll(std.fmt.allocPrint(alloc, "ghoztty-agent: relay mode, control={s}/v1/agent/control\n", .{ws_base}) catch "ghoztty-agent: relay mode\n") catch {};

    // User-controlled relay link state (tray Disconnect/Reconnect). The tray
    // toggles it from its message-pump thread; the control loop obeys it.
    // `host` (scheme stripped) is what the tooltip shows: "Connected to <host>".
    var link = link_control.LinkControl{ .host = ws_base["wss://".len..] };

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
            if (tray.run(&store, build_hash, &link)) {
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
/// `wss://host[:port]` (trailing slashes trimmed). Owned by the caller.
fn wssBase(alloc: Allocator, base: []const u8) ![]u8 {
    const host_part = if (std.mem.startsWith(u8, base, "https://"))
        base["https://".len..]
    else if (std.mem.startsWith(u8, base, "wss://"))
        base["wss://".len..]
    else {
        std.debug.print("ghoztty-agent: --relay url must start with https:// or wss://\n", .{});
        return error.InvalidArgs;
    };
    const trimmed = std.mem.trimRight(u8, host_part, "/");
    return std.fmt.allocPrint(alloc, "wss://{s}", .{trimmed});
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
            std.debug.print("ghoztty-agent: relay control connect failed ({s}); retry in {d}ms\n", .{ @errorName(err), relay_backoff_ms });
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

        const Msg = struct { @"type": []const u8 = "", session: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Msg, alloc, buf[0..n], .{ .ignore_unknown_fields = true }) catch {
            // Malformed JSON — ignore, keep the control connection alive.
            continue;
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.@"type", "open")) continue;
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
    _ = @import("relay_creds.zig");
    _ = @import("single_instance.zig");
}
