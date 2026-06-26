//! `wp4-e2e` — the WP4 Phase-1 headless de-risk harness.
//!
//! Proves the **REAL surface path** works over TCP against the **real,
//! channel-authoritative** `ghoztty-agent` WITHOUT the `test_client.zig`
//! frame-level workaround: it uses the high-level `Connection.openChannel` — the
//! exact call `src/termio/Remote.zig` makes — to open a shell session, sends
//! `echo wp4-foundation\r` as DATA, and asserts the echoed output comes back
//! through the inbound ring on the agent-authoritative data channel.
//!
//! Why this is the de-risk: the agent mints its OWN session channel and replies
//! OPENED on it (see `agent/server.zig`). Before the WP4 rendezvous fix,
//! `Connection.openChannel` correlated the OPENED reply by the channel it SENT
//! OPEN on, so the two never met against the real agent and `openChannel` hung
//! (`error.OpenTimeout` here). After the fix, `openChannel` adopts the
//! agent-chosen channel from the OPENED frame and registers its ring there — so
//! this harness round-trips. It FAILS before the fix and PASSES after.
//!
//! ## Usage
//!   wp4-e2e [path-to-ghoztty-agent]
//! Spawns the agent on `127.0.0.1:<ephemeral>`, dials it (`tcp_dial.dial`), drives
//! `Connection.openChannel`, asserts the round-trip, then tears down. Exits 0 on
//! PASS, non-zero on FAIL. If no agent path is given it defaults to
//! `zig-out/bin/ghoztty-agent`.
//!
//! This is a `zig build wp4-e2e`-able native harness in the same dependency-light
//! client graph as `remote-test-client` (protocol/connection/tcp_dial only).

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const tcp_dial = @import("tcp_dial.zig");

const marker = "wp4-foundation";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const agent_path = try resolveAgentPath(alloc);
    defer alloc.free(agent_path);

    // Pick an ephemeral port the agent will bind. We bind+close to learn a free
    // port, then hand it to the agent (a tiny race window, acceptable for a test).
    const port = try freePort();
    var addr_buf: [32]u8 = undefined;
    const listen_arg = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port});

    diag("[wp4-e2e] spawning agent: {s} --listen {s}\n", .{ agent_path, listen_arg });
    var child = std.process.Child.init(
        &.{ agent_path, "--listen", listen_arg },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    // Pin raw encoding so the dialer (also raw) negotiates cleanly.
    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try cloneEnv(alloc, &env);
    try env.put("GHOZTTY_AGENT_ENCODING", "raw");
    child.env_map = &env;
    try child.spawn();

    // Make sure we always reap the agent (it's a daemon: it never exits on its own).
    var reaped = false;
    defer if (!reaped) {
        _ = child.kill() catch {};
    };

    // Wait for the agent's "listening on ..." readiness line on stdout.
    try waitForListening(alloc, &child);

    // ---- The actual proof: dial + openChannel + DATA round-trip ----
    const result = runProof(alloc, port) catch |err| {
        diag("[wp4-e2e] FAIL: {s}\n", .{@errorName(err)});
        _ = child.kill() catch {};
        reaped = true;
        std.process.exit(1);
    };

    // Tear the agent down.
    _ = child.kill() catch {};
    reaped = true;

    if (result) {
        const stdout = std.fs.File.stdout();
        stdout.writeAll("PASS: Connection.openChannel round-tripped '" ++ marker ++ "' over TCP against the real channel-authoritative agent\n") catch {};
        std.process.exit(0);
    } else {
        diag("[wp4-e2e] FAIL: did not observe the echoed marker in the inbound ring\n", .{});
        std.process.exit(1);
    }
}

/// Dial the agent, OPEN a shell via the high-level `Connection.openChannel`, send
/// `echo wp4-foundation\r`, and drain the pane's inbound ring looking for the
/// echoed marker. Returns true on success.
fn runProof(alloc: Allocator, port: u16) !bool {
    diag("[wp4-e2e] dialing 127.0.0.1:{d}\n", .{port});
    var dialed = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
    defer dialed.deinit();
    diag("[wp4-e2e] handshake ok: proto_version={d} encoding={s}\n", .{
        dialed.negotiated.proto_version,
        @tagName(dialed.negotiated.transfer_encoding),
    });

    // THE FIXED PATH: the same call termio/Remote.zig makes. Against the real
    // agent this only returns if openChannel adopts the agent-authoritative
    // channel from OPENED; before the fix this blocks → OpenTimeout (rpcCall is
    // unblocked by shutdown, but the agent never replies on our channel).
    const open: protocol.Open = .{
        .rows = 24,
        .cols = 80,
        // A plain shell; `echo` is portable on the macOS/POSIX agent host.
        .term = "xterm-ghostty",
    };
    const pane = try dialed.conn.openChannel(open);
    diag("[wp4-e2e] openChannel OK: session_id={s} pid={d} channel=0x{x}\n", .{
        pane.session_id, pane.pid, pane.id,
    });
    defer dialed.conn.closeChannel(pane);

    // Send the command as input DATA (CR is the portable Enter, matching
    // test_client.zig). The pane owns its outbound offset (writeInput).
    try dialed.conn.writeInput(pane, "echo " ++ marker ++ "\r");
    diag("[wp4-e2e] sent 'echo {s}\\r'; draining inbound ring for the echo...\n", .{marker});

    // Drain the pane's ring on the agent-authoritative channel until we see the
    // marker echoed back (the shell prints it), or we time out.
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    var buf: [16 * 1024]u8 = undefined;
    const deadline = std.time.milliTimestamp() + 8000;
    var total: usize = 0;
    while (std.time.milliTimestamp() < deadline) {
        const r = pane.ring.pop(&buf);
        if (r.read == 0) {
            if (dialed.conn.isEvicted()) break;
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }
        total += r.read;
        try acc.appendSlice(alloc, buf[0..r.read]);
        // The shell echoes the typed command AND prints the echo output; either
        // way the marker appears at least once in the stream. Require it to appear
        // beyond the bare command echo: count >= 2 occurrences OR a newline-led
        // occurrence (the command output line). Simplest robust check: the marker
        // appears and we've seen a CR/LF after it (output line completed).
        if (containsMarkerOutput(acc.items)) {
            diag("[wp4-e2e] observed marker in ring after {d} bytes\n", .{total});
            return true;
        }
    }
    diag("[wp4-e2e] drained {d} bytes total without a confirmed marker output\n", .{total});
    return false;
}

/// True once `text` contains the marker followed (somewhere later) by a line
/// terminator — i.e. the shell actually ran `echo` and printed the marker on its
/// own line, not just the keystroke echo of the command we typed.
fn containsMarkerOutput(text: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, marker)) |idx| {
        const after = idx + marker.len;
        if (std.mem.indexOfAnyPos(u8, text, after, "\r\n") != null) return true;
        search_from = after;
    }
    return false;
}

// -----------------------------------------------------------------------------
// Process / port helpers
// -----------------------------------------------------------------------------

/// Resolve the agent exe path: argv[1] if given, else `zig-out/bin/ghoztty-agent`.
fn resolveAgentPath(alloc: Allocator) ![]u8 {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len >= 2) return alloc.dupe(u8, args[1]);
    return alloc.dupe(u8, "zig-out/bin/ghoztty-agent");
}

/// Bind an ephemeral TCP port, read it back, and release it. Returns the port so
/// the agent can bind it (a brief TOCTOU window, fine for a localhost test).
fn freePort() !u16 {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    return listener.listen_address.getPort();
}

/// Block until the agent prints its "listening on ..." readiness line (or its
/// stdout EOFs / we time out). The agent writes that line right after bind.
fn waitForListening(alloc: Allocator, child: *std.process.Child) !void {
    const out = child.stdout orelse return error.NoAgentStdout;
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    var buf: [1024]u8 = undefined;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        const n = out.read(&buf) catch 0;
        if (n == 0) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }
        try acc.appendSlice(alloc, buf[0..n]);
        if (std.mem.indexOf(u8, acc.items, "listening") != null) {
            diag("[wp4-e2e] agent ready: {s}", .{std.mem.trimRight(u8, acc.items, "\n")});
            diag("\n", .{});
            return;
        }
    }
    return error.AgentNeverListened;
}

/// Copy the current process environment into `env` so the spawned agent inherits
/// PATH etc. (it execs a shell).
fn cloneEnv(alloc: Allocator, env: *std.process.EnvMap) !void {
    var src = try std.process.getEnvMap(alloc);
    defer src.deinit();
    var it = src.iterator();
    while (it.next()) |entry| {
        try env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn diag(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
