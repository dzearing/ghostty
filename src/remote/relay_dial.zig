//! Client relay dialer (rendezvous relay transport) — the reusable client entry
//! point that stands up a real networked `RemoteConnection` against a remote
//! `ghoztty-agent` reached THROUGH a rendezvous relay instead of a direct dial.
//!
//! It is the relay analogue of `tcp_dial.zig`: where that connects a TCP socket
//! and wraps it as a `socket_stream.SocketStream`, this opens a native
//! `wss://` WebSocket to the relay (`ws_client.WsClient`) and wraps its
//! connection-side `Stream` as the single transport. The relay bridges those
//! bytes verbatim to the target device, so the WebSocket is a transparent byte
//! pipe to the remote agent — there is NO subprocess (the old Go `relay-connect`
//! sidecar is gone). The rest is identical to the single-channel TCP path: ONE
//! transport stream → `ClientMux` (folds the two logical lanes) →
//! `Connection.create(control, data, hello)` → start the pump + the connection
//! threads → handshake.
//!
//! ## Lifetime / teardown
//! `Dialed` owns the WebSocket client, the mux, and the connection. `deinit`
//! performs the strict teardown order:
//!   1. `conn.shutdown()` — closes the two lane streams (→ mux closes the
//!      transport WebSocket, which `shutdown`s the socket and unblocks the pump's
//!      blocked `read`) and joins the connection's writer/reader/heartbeat
//!      threads.
//!   2. `mux.joinPump()` — joins the inbound demux thread (already unblocked).
//!   3. free `conn`, `mux`; `ws.deinit()` (best-effort close frame, close the
//!      socket, free all WebSocket-owned memory).

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const client_mux = @import("client_mux.zig");
const tcp_dial = @import("tcp_dial.zig");
const ws_client = @import("ws_client.zig");

/// A fully stood-up, handshaked client connection over a relay WebSocket byte
/// pipe. The caller drives `conn` (openChannel / writeInput / attachChannel /
/// ...) and tears it all down with `deinit`.
pub const Dialed = struct {
    alloc: Allocator,
    /// The native `wss://` WebSocket to the relay. Its `connectionStream()` is the
    /// single transport the mux folds both lanes onto; owned here, freed on
    /// teardown.
    ws: *ws_client.WsClient,
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
        // The transport WebSocket was already closed by the mux/conn shutdown
        // above (mux.close → ws.close); `deinit` is the final close + free.
        self.ws.deinit();
        self.* = undefined;
    }
};

/// The HELLO handshake failed (version/encoding mismatch or a dropped stream).
pub const HandshakeFailed = error{HandshakeFailed};

/// Open a native `wss://` WebSocket to the relay for `device_id`, wrap it as the
/// single transport, fold the two lanes through a `ClientMux`, create + start a
/// `Connection`, and block until the HELLO handshake completes. On success
/// returns a `Dialed` the caller owns; on any failure all partial resources are
/// cleaned up (including the WebSocket) and the error is returned.
///
/// `relay_base` is the relay HTTPS base (e.g. `https://relay.example.com`); it is
/// converted to `wss://` and the client-connect path is appended. `token` is the
/// device bearer token sent as `Authorization: Bearer <token>`.
///
/// The error set is inferred (it spans the WebSocket dial/upgrade, allocation,
/// thread spawn, and `error.HandshakeFailed`).
///
/// `encoding` is the pinned transfer encoding (must match what the agent runs
/// with; `.raw` for a clean pipe, exactly like the direct TCP case).
pub fn dial(
    alloc: Allocator,
    relay_base: []const u8,
    device_id: []const u8,
    token: []const u8,
    encoding: protocol.TransferEncoding,
) !Dialed {
    // 1. Build the wss URL: convert the https base to wss and append the
    //    client-connect path with the device query. Both strings are scratch and
    //    freed before we return.
    const host_part = if (std.mem.startsWith(u8, relay_base, "https://"))
        relay_base["https://".len..]
    else if (std.mem.startsWith(u8, relay_base, "wss://"))
        relay_base["wss://".len..]
    else
        return error.InvalidRelayBase;
    const host_trimmed = std.mem.trimRight(u8, host_part, "/");

    const url = try std.fmt.allocPrint(
        alloc,
        "wss://{s}/v1/client/connect?device={s}",
        .{ host_trimmed, device_id },
    );
    defer alloc.free(url);

    // 2. Build the bearer auth header value.
    const authz = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer alloc.free(authz);
    const headers = [_]ws_client.Header{.{ .name = "Authorization", .value = authz }};

    // 3. Dial + TLS + WebSocket upgrade. From here, on any error we must free the
    //    WebSocket.
    const ws = try ws_client.WsClient.connectUrl(alloc, url, &headers);
    errdefer ws.deinit();

    // 4. Fold the two logical lanes onto the WebSocket's connection-side stream.
    const mux = try client_mux.ClientMux.create(alloc, ws.connectionStream(), encoding);
    errdefer mux.destroy();

    // 5. Create the connection over the mux's two lanes with our HELLO.
    const hello: protocol.Hello = .{ .transfer_encoding = encoding };
    const conn = try connection.Connection.create(alloc, mux.streams().control, mux.streams().data, hello);
    errdefer conn.destroy(alloc);

    // 6. Spawn the inbound demux pump, then start the connection threads.
    _ = try mux.startPump();
    errdefer {
        // If start fails after the pump is running, close the transport so the
        // pump exits, then join it.
        conn.shutdown(); // safe even if start partially ran
        mux.joinPump();
    }
    try conn.start();

    // 7. Block until the HELLO handshake completes (or fails), bounded by the
    //    same deadline as the TCP dialer (WP-D1): an agent that upgraded the
    //    WebSocket but never answers HELLO (frozen process; the relay happily
    //    pipes nothing) must fail the dial instead of parking the reconnect
    //    loop forever.
    const negotiated = conn.waitHandshakeTimeout(
        tcp_dial.default_handshake_timeout_ns,
    ) catch |err| {
        // Handshake failed: tear down (shutdown joins everything; pump joined too).
        conn.shutdown();
        mux.joinPump();
        return switch (err) {
            error.HandshakeTimeout => error.HandshakeTimeout,
            else => error.HandshakeFailed,
        };
    };

    return .{
        .alloc = alloc,
        .ws = ws,
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
// one here. Instead we verify that `dial` cleanly returns an error (and leaks
// nothing) when the relay is unreachable, so the WebSocket dial fails before any
// transport/mux/connection is stood up.

const testing = std.testing;

test "dial: unreachable relay cleanly returns an error (no leak)" {
    const alloc = testing.allocator;
    // 127.0.0.1:1 reliably refuses (nothing listens on port 1), so the WebSocket
    // TCP connect fails fast. `dial` must return an error and free every partial
    // resource; the testing allocator asserts no leak on teardown.
    if (dial(
        alloc,
        "https://127.0.0.1:1",
        "device-1",
        "tok",
        .raw,
    )) |d| {
        var dialed = d;
        dialed.deinit();
        return error.UnexpectedSuccess;
    } else |_| {
        // Expected: any error, with all resources reclaimed.
    }
}

test "dial: non-TLS relay base is rejected" {
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidRelayBase, dial(
        alloc,
        "http://relay.example",
        "device-1",
        "tok",
        .raw,
    ));
}

test {
    testing.refAllDecls(@This());
}
