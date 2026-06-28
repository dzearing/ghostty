//! `ghoztty-agent` entry point (WP2, §4.1–§4.2/§7.1) — the remote-host daemon.
//!
//! Two transport modes share the SAME session-server core (`server.zig`, real
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
//!   - Daemonization / single-instance / detach (§4.1).
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
const tray = @import("tray.zig");

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
        .listen => |l| try runListen(alloc, encoding, l.addr, l.headless),
    }
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
};

/// TCP listen-daemon parameters. `headless` suppresses the Windows system-tray
/// icon (for CI / non-interactive runs); the default (tray ON) is what the deploy
/// watcher uses so the human running the Windows box gets a visible daemon handle.
const Listen = struct {
    addr: std.net.Address,
    headless: bool = false,
};

/// Parse `--stdio` | `--listen <addr:port>` | (no args ⇒ default TCP listen).
/// `--headless` (anywhere on the line) suppresses the tray for listen mode; the
/// stdio path is ALWAYS headless (an ssh-piped agent has no desktop to draw on).
fn parseArgs(alloc: Allocator) !Mode {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // Pre-scan for --headless so it can appear before OR after --listen.
    var headless = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--headless")) headless = true;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--headless")) {
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
        } else {
            std.debug.print("ghoztty-agent: unknown argument '{s}'\n", .{a});
            return error.InvalidArgs;
        }
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
            if (tray.run(&store, build_hash)) {
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

    const srv = try server.Server.create(
        alloc,
        mux.controlStream(),
        mux.dataStream(),
        spawner,
        store,
        .{ .encoding = encoding },
    );
    defer srv.destroy(alloc);

    try srv.start();

    // Pump the transport → lane fifos until EOF. Blocks this thread.
    mux.pumpInput();

    // EOF: the client hung up. Tear the per-connection server down — this DETACHes
    // (never terminates) its sessions, so they survive in the store for reconnect.
    srv.shutdown();
}

test {
    std.testing.refAllDecls(@This());
}
