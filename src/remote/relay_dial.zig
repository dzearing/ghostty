//! Client relay dialer (rendezvous relay transport) — the reusable client entry
//! point that stands up a real networked `RemoteConnection` against a remote
//! `ghoztty-agent` reached THROUGH a rendezvous relay instead of a direct dial.
//!
//! It is the relay analogue of `tcp_dial.zig`: where that connects a TCP socket
//! and wraps it as a `socket_stream.SocketStream`, this spawns the
//! `relay-connect` byte-pipe helper and wraps its `(stdout, stdin)` pipe pair as
//! an `ssh_transport.ChildStream`. The helper opens an authenticated WebSocket to
//! the relay and splices it to its own stdin/stdout, so writing framed bytes to
//! the child's stdin and reading framed bytes from its stdout is a transparent
//! byte pipe to the remote agent. The rest is identical to the single-channel
//! TCP path: ONE transport stream → `ClientMux` (folds the two logical lanes) →
//! `Connection.create(control, data, hello)` → start the pump + the connection
//! threads → handshake.
//!
//! ## Lifetime / teardown
//! `Dialed` owns the helper child, its env map, the child stream, the mux, and
//! the connection. `deinit` performs the strict teardown order:
//!   1. `conn.shutdown()` — closes the two lane streams (→ mux closes the
//!      transport `ChildStream`, closing the child's pipes and unblocking the
//!      pump's blocked `read`) and joins the connection's writer/reader/
//!      heartbeat threads.
//!   2. `mux.joinPump()` — joins the inbound demux thread (already unblocked).
//!   3. free `conn`, `mux`; reap the helper child; free the env map and the
//!      child-stream wrapper.
//! The child's pipe fds are owned by the `ChildStream` (closed by the mux's
//! `close` during `shutdown`), so the `Child`'s own stdin/stdout are nulled out
//! after spawn to avoid a double close.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const EnvMap = std.process.EnvMap;

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const client_mux = @import("client_mux.zig");
const ssh_transport = @import("ssh_transport.zig");

/// A fully stood-up, handshaked client connection over a relay byte pipe. The
/// caller drives `conn` (openChannel / writeInput / attachChannel / ...) and
/// tears it all down with `deinit`.
pub const Dialed = struct {
    alloc: Allocator,
    /// The `relay-connect` helper subprocess, retained so we can reap it on
    /// teardown. Its `stdin`/`stdout` Files are nulled after spawn — the fds are
    /// owned by `stream_impl` — so its own teardown won't double-close them.
    child: std.process.Child,
    /// The environment handed to the child (parent env + GHOSTTY_RELAY_TOKEN),
    /// owned here so it can be freed on teardown.
    env_map: EnvMap,
    /// The `connection.Stream` over the helper's (stdout, stdin) pipe pair.
    stream_impl: *ssh_transport.ChildStream,
    mux: *client_mux.ClientMux,
    conn: *connection.Connection,
    /// The negotiated parameters from the HELLO handshake.
    negotiated: protocol.Negotiated,

    /// Tear everything down in the strict order (see the module doc). Idempotent
    /// on the connection (its `shutdown` is). Safe to call once.
    pub fn deinit(self: *Dialed) void {
        self.conn.shutdown();
        self.mux.joinPump();
        self.conn.destroy(self.alloc);
        self.mux.destroy();
        // The child's stdin/stdout fds were owned by `stream_impl` and closed by
        // the mux/conn shutdown above (the helper observes EOF on stdin and
        // exits). Reap the helper so we don't leak a zombie (SIGTERM is a
        // belt-and-suspenders nudge; stdin/stdout are null so `kill` won't
        // double-close).
        _ = self.child.kill() catch {};
        self.env_map.deinit();
        self.alloc.destroy(self.stream_impl);
        self.* = undefined;
    }
};

/// The HELLO handshake failed (version/encoding mismatch or a dropped stream).
pub const HandshakeFailed = error{HandshakeFailed};

/// Spawn the `relay-connect` helper, wrap its stdio as the single transport,
/// fold the two lanes through a `ClientMux`, create + start a `Connection`, and
/// block until the HELLO handshake completes. On success returns a `Dialed` the
/// caller owns; on any failure all partial resources are cleaned up (including
/// killing/reaping the helper child) and the error is returned.
///
/// The error set is inferred (it spans child spawn, allocation, thread spawn,
/// and `error.HandshakeFailed`).
///
/// `encoding` is the pinned transfer encoding (must match what the agent runs
/// with; `.raw` for a clean pipe, exactly like the direct TCP case).
pub fn dial(
    alloc: Allocator,
    relay_base: []const u8,
    device_id: []const u8,
    token: []const u8,
    connect_helper_path: []const u8,
    encoding: protocol.TransferEncoding,
) !Dialed {
    // 1. Build the child's environment: a copy of the parent's, plus the relay
    //    auth token (the helper reads GHOSTTY_RELAY_TOKEN to authenticate the
    //    WebSocket). Owned here; freed on any error and on `deinit`.
    var env_map = try std.process.getEnvMap(alloc);
    errdefer env_map.deinit();
    try env_map.put("GHOSTTY_RELAY_TOKEN", token);

    // 1b. Spawn the helper: `relay-connect -base <https-url> -device <device-id>`.
    //     stdin/stdout are pipes (the byte pipe); stderr is inherited so the
    //     helper's diagnostics surface in the GUI process log.
    const argv = [_][]const u8{ connect_helper_path, "-base", relay_base, "-device", device_id };
    var child = std.process.Child.init(&argv, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.env_map = &env_map;
    try child.spawn();
    // From here, on any error we must kill + reap the child. Registered before we
    // null stdin/stdout so the deferred `kill` (which calls cleanupStreams) does
    // not double-close the fds the `ChildStream` now owns.
    errdefer _ = child.kill() catch {};

    // 2. Take the pipe fds and hand them to a `ChildStream`. Null the `Child`'s
    //    own copies so its teardown (`kill`/`wait`) won't double-close them.
    const read_fd = child.stdout.?.handle; // parent reads the helper's stdout
    const write_fd = child.stdin.?.handle; // parent writes the helper's stdin
    child.stdout = null;
    child.stdin = null;

    const stream_impl = alloc.create(ssh_transport.ChildStream) catch |e| {
        posix.close(read_fd);
        posix.close(write_fd);
        return e;
    };
    stream_impl.* = ssh_transport.ChildStream.init(read_fd, write_fd);
    errdefer {
        stream_impl.stream().close(); // closes the pipe fds (idempotent)
        alloc.destroy(stream_impl);
    }

    // 3. Fold the two logical lanes onto the single child stream via the mux.
    const mux = client_mux.ClientMux.create(alloc, stream_impl.stream(), encoding) catch |e| {
        return e;
    };
    errdefer mux.destroy();

    // 4. Create the connection over the mux's two lanes with our HELLO.
    const hello: protocol.Hello = .{ .transfer_encoding = encoding };
    const conn = connection.Connection.create(alloc, mux.streams().control, mux.streams().data, hello) catch |e| {
        return e;
    };
    errdefer conn.destroy(alloc);

    // 5. Spawn the inbound demux pump, then start the connection threads.
    _ = mux.startPump() catch |e| return e;
    errdefer {
        // If start fails after the pump is running, close the transport so the
        // pump exits, then join it.
        conn.shutdown(); // safe even if start partially ran
        mux.joinPump();
    }
    conn.start() catch |e| return e;

    // 6. Block until the HELLO handshake completes (or fails).
    const negotiated = conn.waitHandshake() catch {
        // Handshake failed: tear down (shutdown joins everything; pump joined too).
        conn.shutdown();
        mux.joinPump();
        return error.HandshakeFailed;
    };

    return .{
        .alloc = alloc,
        .child = child,
        .env_map = env_map,
        .stream_impl = stream_impl,
        .mux = mux,
        .conn = conn,
        .negotiated = negotiated,
    };
}

// =============================================================================
// Tests
// =============================================================================
//
// A full round-trip needs a live relay + a remote agent, so we don't attempt
// one here. Instead we verify the child-spawn + ChildStream wiring compiles and
// that `dial` cleanly returns an error (and leaks nothing) when the helper path
// is bogus so the spawn fails before any transport is stood up.

const testing = std.testing;

test "dial: bogus helper path cleanly returns an error (no leak)" {
    const alloc = testing.allocator;
    // A nonexistent helper either fails to spawn synchronously (error.FileNotFound)
    // or — on platforms where posix_spawn defers exec failure — spawns a phantom
    // child that produces no HELLO, so the handshake fails (error.HandshakeFailed).
    // Either way `dial` must return an error and free every partial resource; the
    // testing allocator asserts no leak on teardown.
    if (dial(
        alloc,
        "https://relay.example",
        "device-1",
        "tok",
        "/nonexistent/relay-connect-binary-xyzzy",
        .raw,
    )) |d| {
        var dialed = d;
        dialed.deinit();
        return error.UnexpectedSuccess;
    } else |_| {
        // Expected: any error, with all resources reclaimed.
    }
}

test {
    testing.refAllDecls(@This());
}
