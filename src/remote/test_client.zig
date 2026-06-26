//! `remote-test-client` (WP: TCP transport) — a headless Mac CLI that DRIVES a
//! TCP-listening `ghoztty-agent`. This is the tool an orchestrator runs to test a
//! remote agent (e.g. the Windows agent over Tailscale) end-to-end: it dials the
//! agent, OPENs a real shell session, and relays bytes both ways.
//!
//! ## Usage
//!   remote-test-client <host> <port>
//!       Interactive: dial, OPEN a shell, put the local TTY in raw mode, and relay
//!       your stdin → session DATA and session output → your stdout. A real remote
//!       terminal inside your terminal. Press Ctrl-] (0x1d) to quit.
//!
//!   remote-test-client <host> <port> --exec "<cmd>" [--timeout <secs>]
//!       Scripted: dial, OPEN a shell, send "<cmd>\n" as DATA, print all session
//!       output to stdout until <timeout> seconds (default 3) of idle OR the session
//!       exits, then quit 0. This is the automated round-trip assertion path.
//!
//! Diagnostics (connecting / handshake / session id / bytes rx) go to **stderr** so
//! stdout carries only the session's raw output (clean for assertions/piping).
//!
//! ## Why this drives the connection at the FRAME level (not `Connection.openChannel`)
//! The agent (`server.zig`) is **server-authoritative for the data channel**: on
//! OPEN it mints its OWN crypto-random session channel and replies OPENED on THAT
//! channel (carrying the `session_id`). The client's high-level
//! `Connection.openChannel` instead correlates the OPENED reply by the channel IT
//! sent OPEN on — so the two never rendezvous against the real agent. Rather than
//! change either core module, this client drives the `Connection` transport
//! primitives directly: it sends OPEN, catches OPENED via a control handler to learn
//! the agent-chosen channel, registers an inbound ring on that channel, then streams
//! input DATA / drains output DATA on it. (The Swift app will adopt the same
//! "agent-authoritative channel" rule, or the cores will be reconciled — flagged in
//! the report.)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const ring = @import("inbound_ring.zig");
const tcp_dial = @import("tcp_dial.zig");

const quit_byte: u8 = 0x1d; // Ctrl-]

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const opts = parseArgs(alloc) catch |err| {
        if (err == error.Usage) {
            usage();
            std.process.exit(2);
        }
        return err;
    };
    defer alloc.free(opts.host);
    defer if (opts.exec) |c| alloc.free(c);

    const encoding = encodingFromEnv(alloc);

    diag("connecting to {s}:{d} (encoding={s}) ...\n", .{ opts.host, opts.port, @tagName(encoding) });
    var dialed = tcp_dial.dial(alloc, opts.host, opts.port, encoding) catch |err| {
        diag("dial failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer dialed.deinit();
    diag("handshake ok: proto_version={d} encoding={s}\n", .{
        dialed.negotiated.proto_version,
        @tagName(dialed.negotiated.transfer_encoding),
    });

    // OPEN a shell session and learn the agent-chosen data channel + session id.
    const dims = ttyDims();
    var sess = Session.open(alloc, dialed.conn, dims.rows, dims.cols) catch |err| {
        diag("open failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer sess.deinit(dialed.conn);
    diag("session opened: id={s} channel=0x{x} pid={d}\n", .{ sess.session_id, sess.channel, sess.pid });

    if (opts.exec) |cmd| {
        try runExec(dialed.conn, &sess, cmd, opts.timeout_secs);
    } else {
        try runInteractive(dialed.conn, &sess);
    }
}

// -----------------------------------------------------------------------------
// Session — drives OPEN/OPENED + an inbound ring at the frame level
// -----------------------------------------------------------------------------

/// A client-side remote shell session driven directly over the `Connection`
/// transport primitives (see the module doc for why). Owns an inbound ring
/// registered on the agent-chosen data channel.
const Session = struct {
    alloc: Allocator,
    channel: u128,
    session_id: []u8,
    pid: i64,
    ch: *ring.Channel,
    /// Outbound byte offset for client→agent input DATA (§4.2).
    out_offset: protocol.ByteOffset = .{},

    /// Correlation state filled by the control handler when OPENED arrives.
    const Pending = struct {
        done: std.Thread.ResetEvent = .{},
        channel: u128 = 0,
        session_id_buf: [64]u8 = undefined,
        session_id_len: usize = 0,
        pid: i64 = 0,
        ok: bool = false,
    };

    var pending: Pending = .{};

    /// Send OPEN, wait for OPENED (on the agent's channel), register a ring there.
    fn open(alloc: Allocator, conn: *connection.Connection, rows: u16, cols: u16) !Session {
        pending = .{};
        conn.setControlHandler(undefined, onControl);

        const open_payload: protocol.Open = .{ .rows = rows, .cols = cols };
        const json = try protocol.encodeJson(alloc, open_payload);
        defer alloc.free(json);
        // The agent ignores the OPEN frame's channel and mints its own; we send on
        // the control channel and learn the real one from OPENED.
        try conn.writeControl(.open, protocol.control_channel, json);

        // Wait (bounded) for OPENED.
        pending.done.timedWait(10 * std.time.ns_per_s) catch return error.OpenTimeout;
        if (!pending.ok) return error.OpenFailed;

        const channel = pending.channel;
        const sid = try alloc.dupe(u8, pending.session_id_buf[0..pending.session_id_len]);
        errdefer alloc.free(sid);

        // Register an inbound ring on the agent's data channel so output DATA lands.
        const ch = try alloc.create(ring.Channel);
        errdefer alloc.destroy(ch);
        ch.* = try ring.Channel.init(alloc, channel, .{});
        errdefer ch.deinit(alloc);
        try conn.registerChannel(ch);

        return .{
            .alloc = alloc,
            .channel = channel,
            .session_id = sid,
            .pid = pending.pid,
            .ch = ch,
        };
    }

    /// The control-frame handler: catch OPENED and publish the agent's channel.
    fn onControl(_: *anyopaque, _: *connection.Connection, frame: protocol.Frame) void {
        if (frame.type != .opened) return;
        if (pending.done.isSet()) return;
        var parsed = protocol.parseJson(protocol.Opened, std.heap.page_allocator, frame.payload) catch {
            pending.ok = false;
            pending.done.set();
            return;
        };
        defer parsed.deinit();
        const sid = parsed.value.session_id;
        pending.channel = frame.channel;
        pending.session_id_len = @min(sid.len, pending.session_id_buf.len);
        @memcpy(pending.session_id_buf[0..pending.session_id_len], sid[0..pending.session_id_len]);
        pending.pid = parsed.value.pid;
        pending.ok = true;
        pending.done.set();
    }

    /// Send input bytes to the session's child (client→agent DATA on the channel).
    fn writeInput(self: *Session, conn: *connection.Connection, bytes: []const u8) !void {
        const off = self.out_offset.advance(bytes.len);
        try conn.writeData(self.channel, off, bytes);
    }

    fn deinit(self: *Session, conn: *connection.Connection) void {
        // Best-effort CLOSE so the agent terminates the child, then deregister +
        // free the ring. (The connection's data reader is still running; deregister
        // under the table lock makes the ring safe to free — the §3.4 invariant.)
        conn.writeControl(.close, self.channel, "") catch {};
        conn.deregisterChannel(self.channel);
        self.ch.deinit(self.alloc);
        self.alloc.destroy(self.ch);
        self.alloc.free(self.session_id);
        self.* = undefined;
    }
};

// -----------------------------------------------------------------------------
// Scripted --exec mode
// -----------------------------------------------------------------------------

fn runExec(
    conn: *connection.Connection,
    sess: *Session,
    cmd: []const u8,
    timeout_secs: u64,
) !void {
    const stdout = std.fs.File.stdout();

    // Send "<cmd>\r" as input. The line terminator is CR (\r), NOT LF: cmd.exe
    // only treats CR as Enter, and POSIX ptys map CR→NL on input (ICRNL), so CR
    // is the portable "Enter" across both remote OSes.
    var line: [4096]u8 = undefined;
    if (cmd.len + 1 > line.len) return error.CommandTooLong;
    @memcpy(line[0..cmd.len], cmd);
    line[cmd.len] = '\r';
    try sess.writeInput(conn, line[0 .. cmd.len + 1]);
    diag("sent {d} bytes of input; draining output (idle timeout {d}s) ...\n", .{ cmd.len + 1, timeout_secs });

    // Drain the ring until `timeout_secs` of idle (no new bytes), printing to
    // stdout. A HARD absolute cap (idle*4, min 15s) guarantees we always exit
    // cleanly even if the remote streams continuously (e.g. a ConPTY that
    // repaints on a timer) — so the client never has to be killed mid-stream,
    // which would leave the agent's writer blocked on a dead socket.
    const idle_ns: i128 = @as(i128, @intCast(timeout_secs)) * std.time.ns_per_s;
    const hard_cap_ms: i64 = @max(@as(i64, @intCast(timeout_secs)) * 4 * std.time.ms_per_s, 15 * std.time.ms_per_s);
    var buf: [16 * 1024]u8 = undefined;
    var total_rx: usize = 0;
    const start_ms = std.time.milliTimestamp();
    var last_byte_ms = start_ms;
    while (true) {
        const r = sess.ch.pop(&buf);
        if (r.read > 0) {
            stdout.writeAll(buf[0..r.read]) catch {};
            total_rx += r.read;
            last_byte_ms = std.time.milliTimestamp();
            continue;
        }
        if (conn.isEvicted()) {
            diag("\nsession evicted; stopping\n", .{});
            break;
        }
        const now = std.time.milliTimestamp();
        const idle = @as(i128, now - last_byte_ms) * std.time.ns_per_ms;
        if (idle >= idle_ns) break;
        if (now - start_ms >= hard_cap_ms) {
            diag("\nhard cap reached ({d}ms); stopping\n", .{hard_cap_ms});
            break;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    diag("done: received {d} bytes total\n", .{total_rx});
}

// -----------------------------------------------------------------------------
// Interactive mode — raw local TTY relay
// -----------------------------------------------------------------------------

fn runInteractive(conn: *connection.Connection, sess: *Session) !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var raw = RawMode.enable(stdin.handle) catch null;
    defer if (raw) |*r| r.disable();
    diag("interactive mode: press Ctrl-] to quit\n", .{});

    const OutPump = struct {
        sess: *Session,
        conn: *connection.Connection,
        stop: std.atomic.Value(bool) = .{ .raw = false },
        out: std.fs.File,
        fn run(self: *@This()) void {
            var buf: [16 * 1024]u8 = undefined;
            while (!self.stop.load(.monotonic)) {
                const r = self.sess.ch.pop(&buf);
                if (r.read > 0) {
                    self.out.writeAll(buf[0..r.read]) catch {};
                } else {
                    if (self.conn.isEvicted()) break;
                    std.Thread.sleep(3 * std.time.ns_per_ms);
                }
            }
        }
    };
    var pump = OutPump{ .sess = sess, .conn = conn, .out = stdout };
    const pump_thread = try std.Thread.spawn(.{}, OutPump.run, .{&pump});
    defer {
        pump.stop.store(true, .monotonic);
        pump_thread.join();
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stdin.read(&buf) catch break;
        if (n == 0) break;
        if (std.mem.indexOfScalar(u8, buf[0..n], quit_byte)) |idx| {
            if (idx > 0) sess.writeInput(conn, buf[0..idx]) catch {};
            diag("\nquit (Ctrl-])\n", .{});
            break;
        }
        sess.writeInput(conn, buf[0..n]) catch break;
        if (conn.isEvicted()) break;
    }
}

// -----------------------------------------------------------------------------
// Raw terminal mode (POSIX termios)
// -----------------------------------------------------------------------------

const RawMode = struct {
    fd: posix.fd_t,
    orig: posix.termios,

    fn enable(fd: posix.fd_t) !RawMode {
        const orig = try posix.tcgetattr(fd);
        var raw = orig;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cflag.CSIZE = .CS8;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .fd = fd, .orig = orig };
    }

    fn disable(self: *RawMode) void {
        posix.tcsetattr(self.fd, .FLUSH, self.orig) catch {};
    }
};

// -----------------------------------------------------------------------------
// Args / helpers
// -----------------------------------------------------------------------------

const Opts = struct {
    host: []u8,
    port: u16,
    exec: ?[]u8 = null,
    timeout_secs: u64 = 3,
};

fn parseArgs(alloc: Allocator) !Opts {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 3) return error.Usage;

    const host = try alloc.dupe(u8, args[1]);
    errdefer alloc.free(host);
    const port = std.fmt.parseInt(u16, args[2], 10) catch return error.Usage;

    var opts: Opts = .{ .host = host, .port = port };
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--exec")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            opts.exec = try alloc.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "--timeout")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            opts.timeout_secs = std.fmt.parseInt(u64, args[i], 10) catch return error.Usage;
        } else {
            return error.Usage;
        }
    }
    return opts;
}

fn usage() void {
    diag(
        \\usage:
        \\  remote-test-client <host> <port>                      interactive (Ctrl-] to quit)
        \\  remote-test-client <host> <port> --exec "<cmd>" [--timeout <secs>]
        \\
    , .{});
}

fn encodingFromEnv(alloc: Allocator) protocol.TransferEncoding {
    const v = std.process.getEnvVarOwned(alloc, "GHOZTTY_AGENT_ENCODING") catch return .raw;
    defer alloc.free(v);
    if (std.ascii.eqlIgnoreCase(v, "cobs")) return .cobs;
    if (std.ascii.eqlIgnoreCase(v, "base64")) return .base64;
    return .raw;
}

const Dims = struct { rows: u16, cols: u16 };

/// Query the local stdout TTY window size; fall back to 24x80 if not a tty.
fn ttyDims() Dims {
    var ws: posix.winsize = undefined;
    const fd = std.fs.File.stdout().handle;
    const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) == .SUCCESS and ws.row > 0 and ws.col > 0) {
        return .{ .rows = ws.row, .cols = ws.col };
    }
    return .{ .rows = 24, .cols = 80 };
}

/// Print a diagnostic line to stderr (stdout stays clean for session output).
fn diag(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
