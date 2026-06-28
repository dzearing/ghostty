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
    defer if (opts.query_cwd_dir) |c| alloc.free(c);
    defer if (opts.open_command) |c| alloc.free(c);
    defer if (opts.open_cwd) |c| alloc.free(c);

    const encoding = encodingFromEnv(alloc);

    if (opts.catchup_demo) {
        runCatchupDemo(alloc, opts.host, opts.port, encoding) catch |err| {
            diag("catchup-demo error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }

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

    // `--metrics` is machine-wide and needs no session OPEN: subscribe, print the
    // first N pushed metrics frames, unsubscribe, and exit.
    if (opts.metrics) {
        try runMetrics(alloc, dialed.conn, opts.metrics_count);
        return;
    }

    // OPEN a shell session and learn the agent-chosen data channel + session id.
    // When `--open-command` is set, the command rides in the OPEN payload (the
    // GUI inheritance path), otherwise the agent opens its default shell.
    const dims = ttyDims();
    var sess = Session.openFull(alloc, dialed.conn, dims.rows, dims.cols, opts.open_command, opts.open_cwd) catch |err| {
        diag("open failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer sess.deinit(dialed.conn);
    diag("session opened: id={s} channel=0x{x} pid={d}\n", .{ sess.session_id, sess.channel, sess.pid });

    if (opts.open_command != null or opts.open_cwd != null) {
        // Drain the OPEN command's output to prove it ran on the remote.
        diag("open-command: draining output (idle timeout {d}s)...\n", .{opts.timeout_secs});
        try drainOutput(dialed.conn, &sess, opts.timeout_secs);
    } else if (opts.query_cwd_dir) |dir| {
        try runQueryCwd(alloc, dialed.conn, &sess, dir);
    } else if (opts.exec) |cmd| {
        try runExec(dialed.conn, &sess, cmd, opts.timeout_secs);
    } else {
        try runInteractive(dialed.conn, &sess);
    }
}

/// `--query-cwd=<dir>`: cd the remote shell to <dir>, then ask the agent for the
/// session's cwd via the on-demand query and print it. Proves the agent reads the
/// child's REAL working directory (the Windows PEB path for cmd.exe).
fn runQueryCwd(
    alloc: Allocator,
    conn: *connection.Connection,
    sess: *Session,
    dir: []const u8,
) !void {
    // cd the remote shell. CR is the portable Enter (cmd.exe needs it; POSIX maps it).
    var line: [1024]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&line, "cd {s}\r", .{dir});
    try sess.writeInput(conn, cmd);
    diag("query-cwd: sent 'cd {s}', waiting for the shell to settle...\n", .{dir});
    std.Thread.sleep(1500 * std.time.ns_per_ms);

    const cwd = conn.queryCwd(sess.session_id) catch |err| {
        diag("query-cwd: FAILED err={s} (agent build may predate GET_CWD, or query timed out)\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer alloc.free(cwd);
    // stdout carries only the answer (clean for assertions); diagnostics on stderr.
    const stdout = std.fs.File.stdout();
    stdout.writeAll(cwd) catch {};
    stdout.writeAll("\n") catch {};
    diag("query-cwd: OK — agent reported cwd = '{s}'\n", .{cwd});
}

// -----------------------------------------------------------------------------
// --metrics: drive the inc-1 host-metrics push stream headlessly
// -----------------------------------------------------------------------------

/// A thread-safe sink that the control handler funnels pushed `metrics` frames into.
/// The handler runs on the connection's control reader thread, so the count + the
/// "done" event are shared with `main`'s thread under a mutex / ResetEvent.
const MetricsSink = struct {
    mutex: std.Thread.Mutex = .{},
    received: u32 = 0,
    want: u32 = 0,
    done: std.Thread.ResetEvent = .{},

    var instance: MetricsSink = .{};

    /// Control-frame handler: decode + print each `metrics` frame's HostMetrics to
    /// stderr (diag), and signal `done` once `want` frames have arrived.
    fn onControl(_: *anyopaque, _: *connection.Connection, frame: protocol.Frame) void {
        if (frame.type != .metrics) return;
        var parsed = protocol.parseJson(protocol.Metrics, std.heap.page_allocator, frame.payload) catch return;
        defer parsed.deinit();
        const host = parsed.value.host;

        instance.mutex.lock();
        instance.received += 1;
        const n = instance.received;
        const reached = n >= instance.want;
        instance.mutex.unlock();

        diag(
            "[metrics #{d}] cpu={d:.1}% mem_used={d} mem_total={d} ncpu={d} uptime_s={?d} load1={?d:.2}\n",
            .{ n, host.cpu_pct, host.mem_used, host.mem_total, host.ncpu, host.uptime_s, host.load1 },
        );
        if (reached) instance.done.set();
    }
};

/// `--metrics[=N]`: subscribe to the agent's host-metrics push stream, print the
/// first N frames (default 3) to stderr, then unsubscribe and return. Uses the
/// `Connection` transport primitives directly (`setControlHandler` + `writeControl`)
/// — no inc-2 `subscribeMetrics` helper needed. Metrics ride the CONTROL channel.
fn runMetrics(alloc: Allocator, conn: *connection.Connection, count: u32) !void {
    MetricsSink.instance = .{ .want = @max(count, 1) };
    conn.setControlHandler(undefined, MetricsSink.onControl);

    // Subscribe (push every ~500ms so a few frames arrive quickly).
    const sub: protocol.MetricsSub = .{ .interval_ms = 500 };
    const sub_json = try protocol.encodeJson(alloc, sub);
    defer alloc.free(sub_json);
    try conn.writeControl(.metrics_sub, protocol.control_channel, sub_json);
    diag("metrics: subscribed (interval=500ms), waiting for {d} frame(s)...\n", .{MetricsSink.instance.want});

    // Wait (bounded) for the requested number of pushes.
    const timeout_ns = @as(u64, MetricsSink.instance.want + 5) * std.time.ns_per_s;
    MetricsSink.instance.done.timedWait(timeout_ns) catch {
        diag("metrics: TIMED OUT waiting for pushes (got {d}/{d})\n", .{
            MetricsSink.instance.received, MetricsSink.instance.want,
        });
    };

    // Unsubscribe so the agent's pump stops, then give the frame a moment to flush.
    const unsub_json = try protocol.encodeJson(alloc, protocol.MetricsUnsub{});
    defer alloc.free(unsub_json);
    conn.writeControl(.metrics_unsub, protocol.control_channel, unsub_json) catch {};
    std.Thread.sleep(100 * std.time.ns_per_ms);
    diag("metrics: done (received {d} frame(s))\n", .{MetricsSink.instance.received});
}

// -----------------------------------------------------------------------------
// --catchup-demo: prove close-laptop survival + reconnect catch-up end-to-end
// -----------------------------------------------------------------------------

/// The headline P1 demo (§5/§7.3). End to end, over a REAL TCP socket + REAL pty:
///
///   1. Dial, OPEN a session running `sh -c 'i=0; while ...; echo line $i; sleep 1'`.
///   2. Read a few "line N" lines, remembering the highest N and the byte offset.
///   3. DROP the socket WITHOUT closing the session (simulate the laptop closing) —
///      the remote shell keeps counting into its ring while we're gone.
///   4. Sleep ~4s, then RECONNECT a brand-new socket and ATTACH the same session_id
///      with the last byte offset we saw.
///   5. Assert the lines emitted DURING the disconnect arrive (the ring is replayed)
///      with NO gap, and that streaming continues live. Print PASS/FAIL with the
///      observed line numbers.
fn runCatchupDemo(alloc: Allocator, host: []const u8, port: u16, encoding: protocol.TransferEncoding) !void {
    // The counter command is overridable via GHOZTTY_CATCHUP_CMD so the same demo
    // can drive a Windows shell (e.g. a PowerShell counter) — it just has to emit
    // "line N" lines for countLines() to track. Default is a POSIX sh loop.
    const counter_cmd = std.process.getEnvVarOwned(alloc, "GHOZTTY_CATCHUP_CMD") catch
        try alloc.dupe(u8, "i=0; while true; do echo line $i; i=$((i+1)); sleep 1; done");
    defer alloc.free(counter_cmd);

    // --- Phase 1: dial + OPEN the counter session ----------------------------
    diag("[catchup] phase 1: dialing {s}:{d} and opening counter session\n", .{ host, port });
    var d1 = try tcp_dial.dial(alloc, host, port, encoding);
    var sess = try Session.open(alloc, d1.conn, 24, 80);
    var session_id_buf: [64]u8 = undefined;
    @memcpy(session_id_buf[0..sess.session_id.len], sess.session_id);
    const session_id = session_id_buf[0..sess.session_id.len];
    // The data channel is stable across reconnects — capture it for the re-ATTACH.
    const data_channel = sess.channel;
    diag("[catchup] session id={s} channel=0x{x}\n", .{ session_id, data_channel });

    // Kick off the counter loop as the session command (sent as input).
    {
        var line: [1024]u8 = undefined;
        if (counter_cmd.len + 1 > line.len) return error.CounterCmdTooLong;
        @memcpy(line[0..counter_cmd.len], counter_cmd);
        line[counter_cmd.len] = '\r';
        try sess.writeInput(d1.conn, line[0 .. counter_cmd.len + 1]);
    }

    // --- Phase 2: read a few lines, track offset + highest line number -------
    var before_max: i64 = -1;
    var offset: u64 = 0;
    {
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(alloc);
        var buf: [8192]u8 = undefined;
        const deadline = std.time.milliTimestamp() + 6000;
        // Read until we've seen at least 3 distinct "line N" values.
        var seen: usize = 0;
        while (std.time.milliTimestamp() < deadline and seen < 3) {
            const r = sess.ch.pop(&buf);
            if (r.read == 0) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            offset += r.read;
            try acc.appendSlice(alloc, buf[0..r.read]);
            seen = countLines(acc.items, &before_max);
        }
        diag("[catchup] before disconnect: saw up to 'line {d}', byte offset={d}\n", .{ before_max, offset });
        if (before_max < 0) {
            diag("[catchup] FAIL: never saw any counter output before disconnect\n", .{});
            d1.deinit();
            return error.CatchupFailed;
        }
    }

    // --- Phase 3: DROP the socket WITHOUT closing the session ----------------
    // `deinit` would send CLOSE (terminating the remote child). We must NOT do that
    // — we simulate a laptop closing: just tear down the local transport (close the
    // fd, join our threads). The remote session keeps running + ringing.
    diag("[catchup] phase 3: DROPPING socket (laptop close) — session stays alive remotely\n", .{});
    sess.dropLocal(d1.conn);
    d1.deinit();

    // --- Phase 4: stay gone while the remote keeps counting ------------------
    diag("[catchup] phase 4: disconnected for ~4s while remote keeps counting...\n", .{});
    std.Thread.sleep(4 * std.time.ns_per_s);

    // --- Phase 5: RECONNECT a fresh socket + ATTACH the same session ---------
    diag("[catchup] phase 5: reconnecting + ATTACH session={s} last_byte_offset={d}\n", .{ session_id, offset });
    var d2 = try tcp_dial.dial(alloc, host, port, encoding);
    defer d2.deinit();

    var att = try Attach.run(alloc, d2.conn, session_id, data_channel, offset, 24, 80);
    defer att.deinit(alloc, d2.conn);
    if (att.status != .alive) {
        diag("[catchup] FAIL: ATTACH returned status={s} (expected alive)\n", .{@tagName(att.status)});
        return error.CatchupFailed;
    }
    diag("[catchup] attached: status=alive snapshot_at_offset={d}\n", .{att.snapshot_at_offset});

    // Drain the replay + live stream; assert continuity (no gap from before_max).
    var after_min: i64 = std.math.maxInt(i64);
    var after_max: i64 = -1;
    {
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(alloc);
        var buf: [8192]u8 = undefined;
        const deadline = std.time.milliTimestamp() + 6000;
        while (std.time.milliTimestamp() < deadline and after_max < before_max + 3) {
            const r = att.ch.pop(&buf);
            if (r.read == 0) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            try acc.appendSlice(alloc, buf[0..r.read]);
            scanLineRange(acc.items, &after_min, &after_max);
        }
    }
    diag("[catchup] after reconnect: received lines {d}..{d}\n", .{ after_min, after_max });

    // Continuity check: the FIRST line we got after reconnect must be the NEXT line
    // after the last we saw before (no gap), and we must have advanced past it.
    const stdout = std.fs.File.stdout();
    const continuous = after_min >= 0 and after_min <= before_max + 1 and after_max > before_max;
    if (continuous) {
        var msg: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&msg, "PASS: caught up with no gap (saw <=line {d} before disconnect; after reconnect received line {d}..{d}, continuous)\n", .{ before_max, after_min, after_max }) catch "PASS\n";
        stdout.writeAll(s) catch {};
    } else {
        diag("[catchup] FAIL: gap detected (before<=line {d}; after reconnect first=line {d}, last=line {d})\n", .{ before_max, after_min, after_max });
        // Best-effort CLOSE so we don't leak the remote session on failure.
        d2.conn.writeControl(.close, att.channel, "") catch {};
        return error.CatchupFailed;
    }

    // Clean up the remote session (CLOSE) so the demo leaves nothing running.
    d2.conn.writeControl(.close, att.channel, "") catch {};
    std.Thread.sleep(100 * std.time.ns_per_ms);
}

/// Count distinct "line N" occurrences in `text`, updating `*max` to the highest N
/// seen. Returns the number of lines parsed (used as a "have I seen enough" gate).
fn countLines(text: []const u8, max: *i64) usize {
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        const num = parseLineNum(raw) orelse continue;
        if (num > max.*) max.* = num;
        n += 1;
    }
    return n;
}

/// Scan `text` for "line N" tokens, updating min/max of the numbers seen.
fn scanLineRange(text: []const u8, min: *i64, max: *i64) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const num = parseLineNum(raw) orelse continue;
        if (num < min.*) min.* = num;
        if (num > max.*) max.* = num;
    }
}

/// Parse the N out of a line containing "line N" (ignoring shell echo / prompts).
/// Returns null if the line has no such token.
fn parseLineNum(raw: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, raw, "line ") orelse return null;
    const rest = raw[idx + "line ".len ..];
    // Trim trailing CR / spaces.
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch null;
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
        return openWithCommand(alloc, conn, rows, cols, null);
    }

    /// Like `open` but with an explicit OPEN `command` — the EXACT path the GUI's
    /// new window/tab/split uses to inherit the parent frame's command (the
    /// command rides in the OPEN payload, not as input). null ⇒ agent default shell.
    fn openWithCommand(
        alloc: Allocator,
        conn: *connection.Connection,
        rows: u16,
        cols: u16,
        command: ?[]const u8,
    ) !Session {
        return openFull(alloc, conn, rows, cols, command, null);
    }

    fn openFull(
        alloc: Allocator,
        conn: *connection.Connection,
        rows: u16,
        cols: u16,
        command: ?[]const u8,
        cwd: ?[]const u8,
    ) !Session {
        pending = .{};
        conn.setControlHandler(undefined, onControl);

        const open_payload: protocol.Open = .{ .rows = rows, .cols = cols, .command = command, .cwd = cwd };
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

    /// Tear down the LOCAL ring/state WITHOUT sending CLOSE — the close-laptop path.
    /// The remote session keeps running; we just forget it locally so the
    /// connection can be dropped. The caller still owns the `session_id` copy it
    /// needs for the later ATTACH (we free our own here).
    fn dropLocal(self: *Session, conn: *connection.Connection) void {
        conn.deregisterChannel(self.channel);
        self.ch.deinit(self.alloc);
        self.alloc.destroy(self.ch);
        self.alloc.free(self.session_id);
        self.* = undefined;
    }
};

// -----------------------------------------------------------------------------
// Attach — drives a frame-level ATTACH on a fresh connection (reconnect path)
// -----------------------------------------------------------------------------

/// Resumes an existing remote session over a NEW connection: sends ATTACH, catches
/// ATTACHED (on the session's data channel), and registers an inbound ring there so
/// the replayed + live DATA lands. Mirrors `Session.open`'s frame-level approach
/// (the agent is data-channel-authoritative — see this module's header).
const Attach = struct {
    channel: u128,
    status: protocol.Attached.AttachStatus,
    snapshot_at_offset: u64,
    ch: *ring.Channel,

    const Pending = struct {
        done: std.Thread.ResetEvent = .{},
        channel: u128 = 0,
        status: protocol.Attached.AttachStatus = .not_found,
        snapshot_at_offset: u64 = 0,
        ok: bool = false,
    };
    var pending: Pending = .{};

    fn run(
        alloc: Allocator,
        conn: *connection.Connection,
        session_id: []const u8,
        channel: u128,
        last_byte_offset: u64,
        rows: u16,
        cols: u16,
    ) !Attach {
        pending = .{};
        conn.setControlHandler(undefined, onControl);

        // Register the inbound ring on the session's data channel BEFORE sending
        // ATTACH. The data channel is server-authoritative but STABLE across
        // reconnects (same session ⇒ same channel learned at OPEN), so we know it
        // up front. Registering first closes the race where the agent's gap-fill
        // replay DATA (sent immediately after ATTACHED) would arrive on the data
        // lane before the ring exists and be dropped — which would lose exactly the
        // bytes produced during the disconnect (the whole point of catch-up).
        const ch = try alloc.create(ring.Channel);
        errdefer alloc.destroy(ch);
        ch.* = try ring.Channel.init(alloc, channel, .{});
        errdefer ch.deinit(alloc);
        try conn.registerChannel(ch);
        errdefer conn.deregisterChannel(channel);

        const att_payload: protocol.Attach = .{
            .session_id = session_id,
            .rows = rows,
            .cols = cols,
            .last_byte_offset = last_byte_offset,
        };
        const json = try protocol.encodeJson(alloc, att_payload);
        defer alloc.free(json);
        try conn.writeControl(.attach, protocol.control_channel, json);

        pending.done.timedWait(10 * std.time.ns_per_s) catch return error.AttachTimeout;
        if (!pending.ok) return error.AttachFailed;

        return .{
            .channel = channel,
            .status = pending.status,
            .snapshot_at_offset = pending.snapshot_at_offset,
            .ch = ch,
        };
    }

    fn onControl(_: *anyopaque, _: *connection.Connection, frame: protocol.Frame) void {
        if (frame.type != .attached) return;
        if (pending.done.isSet()) return;
        var parsed = protocol.parseJson(protocol.Attached, std.heap.page_allocator, frame.payload) catch {
            pending.ok = false;
            pending.done.set();
            return;
        };
        defer parsed.deinit();
        pending.channel = frame.channel;
        pending.status = parsed.value.status;
        pending.snapshot_at_offset = parsed.value.snapshot_at_offset;
        pending.ok = true;
        pending.done.set();
    }

    fn deinit(self: *Attach, alloc: Allocator, conn: *connection.Connection) void {
        conn.deregisterChannel(self.channel);
        self.ch.deinit(alloc);
        alloc.destroy(self.ch);
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
    // Send "<cmd>\r" as input. The line terminator is CR (\r), NOT LF: cmd.exe
    // only treats CR as Enter, and POSIX ptys map CR→NL on input (ICRNL), so CR
    // is the portable "Enter" across both remote OSes.
    var line: [4096]u8 = undefined;
    if (cmd.len + 1 > line.len) return error.CommandTooLong;
    @memcpy(line[0..cmd.len], cmd);
    line[cmd.len] = '\r';
    try sess.writeInput(conn, line[0 .. cmd.len + 1]);
    diag("sent {d} bytes of input; draining output (idle timeout {d}s) ...\n", .{ cmd.len + 1, timeout_secs });
    try drainOutput(conn, sess, timeout_secs);
}

/// Drain the session's output ring to stdout until `timeout_secs` of idle (or a
/// hard cap). Shared by `--exec` (post-input) and `--open-command` (post-OPEN).
fn drainOutput(
    conn: *connection.Connection,
    sess: *Session,
    timeout_secs: u64,
) !void {
    const stdout = std.fs.File.stdout();
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
    catchup_demo: bool = false,
    /// `--query-cwd=<dir>`: open a session, `cd <dir>`, then call the agent's
    /// on-demand cwd query and print the result. Proves the agent reads the
    /// child's real working directory (incl. the Windows PEB path for cmd.exe).
    query_cwd_dir: ?[]u8 = null,
    /// `--open-command=<cmd>`: put <cmd> in the OPEN payload (NOT as input) and
    /// drain its output. This is the exact path the GUI's new window/tab/split
    /// uses to inherit the parent frame's command — proves the OPEN `command`
    /// field runs on the remote.
    open_command: ?[]u8 = null,
    /// `--open-cwd=<dir>`: the OPEN payload's cwd (the GUI forwards the parent
    /// pane's queried cwd here so the new frame starts in the same directory).
    open_cwd: ?[]u8 = null,
    /// `--metrics[=N]`: subscribe to the agent's pushed host-metrics stream, print
    /// the first N (default 3) `metrics` frames to stderr, then unsubscribe + exit.
    /// Machine-wide — needs no session OPEN. Drives the inc-1 metrics path headlessly
    /// against the live (Windows) agent.
    metrics: bool = false,
    metrics_count: u32 = 3,
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
        } else if (std.mem.eql(u8, a, "--catchup-demo")) {
            opts.catchup_demo = true;
        } else if (std.mem.startsWith(u8, a, "--query-cwd=")) {
            opts.query_cwd_dir = try alloc.dupe(u8, a["--query-cwd=".len..]);
        } else if (std.mem.startsWith(u8, a, "--open-command=")) {
            opts.open_command = try alloc.dupe(u8, a["--open-command=".len..]);
        } else if (std.mem.startsWith(u8, a, "--open-cwd=")) {
            opts.open_cwd = try alloc.dupe(u8, a["--open-cwd=".len..]);
        } else if (std.mem.eql(u8, a, "--metrics")) {
            opts.metrics = true;
        } else if (std.mem.startsWith(u8, a, "--metrics=")) {
            opts.metrics = true;
            opts.metrics_count = std.fmt.parseInt(u32, a["--metrics=".len..], 10) catch return error.Usage;
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
        \\  remote-test-client <host> <port> --open-command=<cmd>  run <cmd> via the OPEN payload (GUI inherit path)
        \\  remote-test-client <host> <port> --metrics[=N]        print the first N host-metrics pushes (default 3)
        \\  remote-test-client <host> <port> --catchup-demo       close-laptop catch-up demo (PASS/FAIL)
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
