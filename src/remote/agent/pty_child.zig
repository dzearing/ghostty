//! Real, POSIX-pty-backed `session.Child` (WP2, §4.1–§4.2/§7.1) — the production
//! replacement for the fake buffer-backed child. It is the agent's bridge between
//! a spawned shell/command and the session-server's frame routing:
//!
//!   - `open` opens a pty (`src/pty.zig`), spawns the user's shell on its SLAVE
//!     fds via the GUI-free `CommandCore.DefaultCommand`, and keeps the MASTER fd.
//!   - A reader thread pumps the MASTER fd → the session ring via the `Server`'s
//!     output sink (`onChildOutput`), so child output flows as DATA frames.
//!   - `write` (client keystrokes / inbound DATA) writes to the MASTER fd.
//!   - `resize` drives `TIOCSWINSZ` via `pty.setSize`.
//!   - `signal` maps a POSIX signal name to `kill(2)` on the child's process group.
//!   - `tryWait` is a non-blocking `waitpid(WNOHANG)` → exit code (drives the
//!     existing EXIT/tombstone path); `terminate` SIGKILLs + reaps + joins.
//!
//! Threading: exactly one reader thread per child calls the sink. The `Server`'s
//! `sess_mutex` serializes sink delivery with frame handling (the sink IS
//! `Server.onChildOutput`, which takes that lock). The child is heap-owned by the
//! `PtySpawner` and freed on `terminate`.
//!
//! Deferred (later increments): daemonization, idle-TTL GC, Job/containment caps,
//! a real grid-model snapshot (§7.3). Windows ConPTY is out of scope here (the
//! POSIX path only) — the spike (`spike/main.zig`) covers the Windows risks.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Pty = @import("../../pty.zig").Pty;
const CommandCore = @import("../../CommandCore.zig");
const protocol = @import("../protocol.zig");
const session = @import("session.zig");
const server = @import("server.zig");

const log = std.log.scoped(.agent_pty);

/// The GUI-free command type used to fork+exec the shell on the pty slave.
const Command = CommandCore.DefaultCommand;

/// Scratch read size for the master-fd reader loop.
const read_buf_size: usize = 64 * 1024;

/// A pty-backed child process. Heap-allocated and owned by the `PtySpawner`; freed
/// in `terminate` (idempotent). Implements the `session.Child` vtable.
pub const PtyChild = struct {
    alloc: Allocator,

    pty: Pty,
    cmd: Command,
    pid: posix.pid_t,

    /// The owning data channel + output sink, published by `attach` after the
    /// session is registered (the reader thread waits on this before delivering).
    sink_ctx: ?*anyopaque = null,
    sink: ?*const fn (sink_ctx: *anyopaque, channel: u128, bytes: []const u8) void = null,
    channel: u128 = 0,
    attached: std.Thread.ResetEvent = .{},

    /// The master-fd reader thread.
    reader: ?std.Thread = null,

    /// Lifecycle flags, guarded by `mutex`.
    mutex: std.Thread.Mutex = .{},
    reaped: bool = false,
    exit_code: ?i64 = null,
    /// Set once `terminate` has run; makes it idempotent and tells the reader to
    /// stop (it also unblocks on master EOF when the slave side is gone).
    closed: bool = false,

    /// Build a `session.Child` handle over this struct.
    pub fn child(self: *PtyChild) session.Child {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: session.Child.VTable = .{
        .attach = attachFn,
        .write = writeFn,
        .resize = resizeFn,
        .signal = signalFn,
        .tryWait = tryWaitFn,
        .terminate = terminateFn,
    };

    // --- attach: publish channel + sink, start the reader ---------------------

    fn attachFn(
        ctx: *anyopaque,
        sink_ctx: *anyopaque,
        sink: *const fn (sink_ctx: *anyopaque, channel: u128, bytes: []const u8) void,
        channel: u128,
    ) void {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        self.sink_ctx = sink_ctx;
        self.sink = sink;
        self.channel = channel;
        self.mutex.unlock();
        // Unblock (or, on first call, allow) the reader to deliver output.
        self.attached.set();
        // Start the reader exactly once.
        if (self.reader == null) {
            self.reader = std.Thread.spawn(.{}, readerLoop, .{self}) catch |err| blk: {
                log.warn("failed to spawn pty reader thread: {}", .{err});
                break :blk null;
            };
        }
    }

    /// Pump MASTER → sink until EOF (slave closed: child exited / pty torn down).
    fn readerLoop(self: *PtyChild) void {
        // Wait until the channel/sink are published so we never route output to a
        // zero channel. (attach() always fires before any output is meaningful.)
        self.attached.wait();
        var buf: [read_buf_size]u8 = undefined;
        while (true) {
            const n = posix.read(self.pty.master, &buf) catch |err| switch (err) {
                // On Linux a pty master read after the slave hangs up yields EIO;
                // treat it as EOF rather than an error.
                error.InputOutput => 0,
                error.WouldBlock => continue,
                else => 0,
            };
            if (n == 0) break; // EOF: child gone
            self.mutex.lock();
            const sink = self.sink;
            const sink_ctx = self.sink_ctx;
            const channel = self.channel;
            self.mutex.unlock();
            if (sink) |f| f(sink_ctx.?, channel, buf[0..n]);
        }
        // After EOF the child has (almost certainly) exited; surface it so the next
        // tryWait reaps and the EXIT/tombstone path fires. A final zero-length sink
        // call nudges the server to reap-check.
        self.mutex.lock();
        const sink = self.sink;
        const sink_ctx = self.sink_ctx;
        const channel = self.channel;
        self.mutex.unlock();
        if (sink) |f| f(sink_ctx.?, channel, &.{});
    }

    // --- write: client keystrokes → master ------------------------------------

    fn writeFn(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        return posix.write(self.pty.master, bytes);
    }

    // --- resize: TIOCSWINSZ ----------------------------------------------------

    fn resizeFn(ctx: *anyopaque, rows: u16, cols: u16, px_w: u16, px_h: u16) anyerror!void {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        try self.pty.setSize(.{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = px_w,
            .ws_ypixel = px_h,
        });
    }

    // --- signal: kill the child's process group --------------------------------

    fn signalFn(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        const sig = sigFromName(name) orelse return;
        // The child is its own session/process-group leader (pty.childPreExec calls
        // setsid), so its pgid == pid. Signal the whole group with kill(-pid). If
        // the group lookup fails (e.g. the child hasn't finished setsid yet, or the
        // group is already gone), fall back to signaling the pid directly so an
        // interactive ^C / kill is never silently dropped.
        posix.kill(-self.pid, sig) catch {
            posix.kill(self.pid, sig) catch |err| {
                log.warn("kill({d}, {d}) failed: {}", .{ self.pid, sig, err });
            };
        };
    }

    // --- tryWait: non-blocking reap -------------------------------------------

    fn tryWaitFn(ctx: *anyopaque) ?i64 {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.reaped) return self.exit_code;

        // A genuinely non-blocking reap: `waitpid(WNOHANG)` returns pid 0 when the
        // child has no status yet (we must NOT use `CommandCore.wait(false)` here —
        // it busy-LOOPS until a status is available, which would block this poll).
        const res = posix.waitpid(self.pid, std.c.W.NOHANG);
        if (res.pid == 0) return null; // still running
        const exit = CommandCore.Exit.init(res.status);
        const code: i64 = switch (exit) {
            .Exited => |c| @intCast(c),
            .Signal => |s| @intCast(128 + @as(i64, s)),
            .Stopped => |s| @intCast(128 + @as(i64, s)),
            .Unknown => |s| @intCast(s),
        };
        self.reaped = true;
        self.exit_code = code;
        return code;
    }

    // --- terminate: SIGKILL + reap + join + free -------------------------------

    fn terminateFn(ctx: *anyopaque) void {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            return;
        }
        self.closed = true;
        const already_reaped = self.reaped;
        self.mutex.unlock();

        // Hard kill the process group if it hasn't already exited.
        if (!already_reaped) {
            posix.kill(-self.pid, posix.SIG.KILL) catch {};
        }

        // Close the master fd: this hangs up the slave and EOFs the reader's read.
        // (Pty.deinit closes the master.)
        self.pty.deinit();

        // Join the reader (now unblocked by EOF). Ensure it was at least allowed to
        // run (attach may never have fired for an instantly-failed session).
        self.attached.set();
        if (self.reader) |t| {
            t.join();
            self.reader = null;
        }

        // Reap the child to avoid a zombie (best-effort; ignore if already reaped).
        self.mutex.lock();
        const need_reap = !self.reaped;
        self.mutex.unlock();
        if (need_reap) _ = self.cmd.wait(true) catch {};

        self.alloc.destroy(self);
    }
};

/// Map a POSIX signal NAME (no "SIG" prefix, e.g. "INT", "TERM") to its number.
/// Unknown names → null (ignored, never a crash — untrusted input, §15 M3).
fn sigFromName(name: []const u8) ?u8 {
    const S = posix.SIG;
    const table = .{
        .{ "HUP", S.HUP },   .{ "INT", S.INT },   .{ "QUIT", S.QUIT },
        .{ "KILL", S.KILL }, .{ "TERM", S.TERM }, .{ "USR1", S.USR1 },
        .{ "USR2", S.USR2 }, .{ "STOP", S.STOP }, .{ "CONT", S.CONT },
        .{ "TSTP", S.TSTP }, .{ "WINCH", S.WINCH },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return @intCast(entry[1]);
    }
    return null;
}

// -----------------------------------------------------------------------------
// PtySpawner — turns an OPEN into a pty-backed child (the real `server.Spawner`)
// -----------------------------------------------------------------------------

/// Spawns a real pty-backed child per OPEN. The default shell is `$SHELL` (falling
/// back to `/bin/sh`), invoked login+interactive (`-lic <command>`) when the OPEN
/// carries a `command`, else just login+interactive (`-li`) for a plain shell —
/// mirroring the local CLI's shell convention.
pub const PtySpawner = struct {
    alloc: Allocator,
    /// Owns an EnvMap so child env (TERM + inherited) outlives the fork's arena.
    /// Kept for the spawner's lifetime; each child's `cmd.env` borrows it.
    env: *std.process.EnvMap,

    pub fn init(alloc: Allocator) !*PtySpawner {
        const self = try alloc.create(PtySpawner);
        errdefer alloc.destroy(self);
        const env = try alloc.create(std.process.EnvMap);
        errdefer alloc.destroy(env);
        env.* = std.process.getEnvMap(alloc) catch std.process.EnvMap.init(alloc);
        self.* = .{ .alloc = alloc, .env = env };
        return self;
    }

    pub fn deinit(self: *PtySpawner) void {
        self.env.deinit();
        self.alloc.destroy(self.env);
        self.alloc.destroy(self);
    }

    /// A `server.Spawner` handle over this spawner — plug straight into
    /// `Server.create`.
    pub fn spawner(self: *PtySpawner) server.Spawner {
        return .{ .ctx = self, .spawnFn = spawnFn };
    }

    /// Matches `server.Spawner.spawnFn`: turn an OPEN into a `Child` + pid.
    fn spawnFn(ctx: *anyopaque, open: protocol.Open) anyerror!server.Spawner.Result {
        const self: *PtySpawner = @ptrCast(@alignCast(ctx));
        const pc = try self.spawnChild(open);
        return .{ .child = pc.child(), .pid = @intCast(pc.pid) };
    }

    /// Open a pty, fork+exec the shell on its slave, return the owned `*PtyChild`.
    pub fn spawnChild(self: *PtySpawner, open: protocol.Open) !*PtyChild {
        const rows: u16 = if (open.rows == 0) 24 else open.rows;
        const cols: u16 = if (open.cols == 0) 80 else open.cols;

        var pty = try Pty.open(.{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = open.px_w,
            .ws_ypixel = open.px_h,
        });
        errdefer pty.deinit();

        // Set TERM for the child.
        try self.env.put("TERM", open.term);

        const pc = try self.alloc.create(PtyChild);
        errdefer self.alloc.destroy(pc);

        // Resolve the shell: OPEN.shell → $SHELL → /bin/sh.
        const shell_path = blk: {
            if (open.shell) |s| if (s.len > 0) break :blk s;
            if (self.env.get("SHELL")) |s| if (s.len > 0) break :blk s;
            break :blk "/bin/sh";
        };

        // Build argv. With a command: `<shell> -lic <command>`. Without: `<shell>
        // -li` (login interactive). `startCommand` copies these into its own fork
        // arena before exec, so in the PARENT they are dead after `start()` returns
        // — we free them right after (see below).
        const shell_z = try self.alloc.dupeZ(u8, shell_path);
        defer self.alloc.free(shell_z);

        var args_list: std.ArrayList([:0]const u8) = .empty;
        defer {
            for (args_list.items) |a| self.alloc.free(a);
            args_list.deinit(self.alloc);
        }
        // argv[0] is the shell path (a fresh dupe so freeing the list frees it).
        try args_list.append(self.alloc, try self.alloc.dupeZ(u8, shell_path));
        if (open.command) |cmd| {
            if (cmd.len > 0) {
                try args_list.append(self.alloc, try self.alloc.dupeZ(u8, "-lic"));
                try args_list.append(self.alloc, try self.alloc.dupeZ(u8, cmd));
            } else {
                try args_list.append(self.alloc, try self.alloc.dupeZ(u8, "-li"));
            }
        } else {
            try args_list.append(self.alloc, try self.alloc.dupeZ(u8, "-li"));
        }
        const args = args_list.items;

        // The slave fd is handed to the child as stdin/stdout/stderr; the pty's
        // childPreExec (setsid + TIOCSCTTY) runs via os_pre_exec so the child gets
        // a controlling terminal and its own process group.
        const slave_file: std.fs.File = .{ .handle = pty.slave };

        pc.* = .{
            .alloc = self.alloc,
            .pty = pty,
            .cmd = .{
                .path = shell_z,
                .args = args,
                .env = self.env,
                .cwd = open.cwd,
                .stdin = slave_file,
                .stdout = slave_file,
                .stderr = slave_file,
                .os_pre_exec = ptyPreExec,
                .data = pc, // so the pre_exec hook can reach the pty
            },
            .pid = 0,
        };

        try pc.cmd.start(self.alloc);
        pc.pid = pc.cmd.pid.?;

        // The parent no longer needs the slave fd (the child has it as its tty).
        posix.close(pty.slave);

        return pc;
    }
};

/// Runs in the forked child before exec: set up the controlling terminal via the
/// pty (`setsid` + `TIOCSCTTY`, then close the master/slave pair). Returns null on
/// success (continue to exec); a non-null exit code aborts the child.
fn ptyPreExec(cmd: *Command) ?u8 {
    const pc = cmd.getData(PtyChild) orelse return null;
    pc.pty.childPreExec() catch return 1;
    return null;
}

// =============================================================================
// Tests — drive a REAL pty-backed child end-to-end (spawn → input → output →
// exit/tombstone). These need `pty-c` + `os/main.zig`, so they only run inside
// the agent module graph (`zig build test-agent`), not the pure agent_test.zig.
// =============================================================================

const testing = std.testing;

/// A thread-safe sink that captures the pty child's output bytes (it stands in
/// for `Server.onChildOutput` → the session ring). The reader thread calls it.
const CaptureSink = struct {
    mutex: std.Thread.Mutex = .{},
    buf: std.ArrayList(u8) = .empty,
    alloc: Allocator,

    fn sink(ctx: *anyopaque, channel: u128, bytes: []const u8) void {
        _ = channel;
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.buf.appendSlice(self.alloc, bytes) catch {};
    }
    fn contains(self: *CaptureSink, needle: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return std.mem.indexOf(u8, self.buf.items, needle) != null;
    }
    fn deinit(self: *CaptureSink) void {
        self.buf.deinit(self.alloc);
    }
};

test "PtyChild: real pty spawn → input echoes back → exit/tombstone" {
    const alloc = testing.allocator;

    var spawner = try PtySpawner.init(alloc);
    defer spawner.deinit();

    // Spawn `sh -lic 'cat; exit 7'`-equivalent: a plain interactive shell. We feed
    // a command and observe its echo, then exit.
    const pc = try spawner.spawnChild(.{ .rows = 24, .cols = 80, .command = "cat" });
    var terminated = false;
    defer if (!terminated) pc.child().terminate();

    var capture: CaptureSink = .{ .alloc = alloc };
    defer capture.deinit();

    // Attach the sink (this also starts the reader thread).
    pc.child().attach(&capture, CaptureSink.sink, 0xABCD);

    // Write a line; `cat` echoes it straight back to the pty.
    try pc.child().writeAll("hello-pty-roundtrip\n");

    // Spin until the echoed bytes reach the sink (the reader thread is async).
    var spins: usize = 0;
    while (spins < 20_000) : (spins += 1) {
        if (capture.contains("hello-pty-roundtrip")) break;
        std.Thread.yield() catch {};
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    try testing.expect(capture.contains("hello-pty-roundtrip"));

    // Send EOF to `cat` so it exits cleanly (Ctrl-D), then reap.
    try pc.child().writeAll(&.{0x04});
    var reaped: ?i64 = null;
    spins = 0;
    while (spins < 20_000) : (spins += 1) {
        if (pc.child().tryWait()) |code| {
            reaped = code;
            break;
        }
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    try testing.expect(reaped != null);
    try testing.expectEqual(@as(i64, 0), reaped.?); // cat exits 0 on EOF

    // terminate is idempotent + frees the child (and joins the reader).
    pc.child().terminate();
    terminated = true;
}

test "PtyChild: SIGNAL terminates the child via its process group" {
    const alloc = testing.allocator;

    var spawner = try PtySpawner.init(alloc);
    defer spawner.deinit();

    // `sleep 30` so it stays alive until we signal it.
    const pc = try spawner.spawnChild(.{ .rows = 24, .cols = 80, .command = "sleep 30" });
    // Free the child even if an assertion below fails (no leak under the test
    // allocator). terminate() is idempotent with a later explicit call.
    var terminated = false;
    defer if (!terminated) pc.child().terminate();

    var capture: CaptureSink = .{ .alloc = alloc };
    defer capture.deinit();
    pc.child().attach(&capture, CaptureSink.sink, 1);

    // Give the child a beat to complete `setsid` (its pre_exec) so it is the leader
    // of its own process group before we signal the group. We send KILL: it cannot
    // be caught/ignored (an interactive `-i` shell may trap TERM/INT), so it
    // deterministically proves our `signal()` reaches the child's process group.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try pc.child().signal("KILL");

    var reaped: ?i64 = null;
    var spins: usize = 0;
    while (spins < 100_000) : (spins += 1) {
        if (pc.child().tryWait()) |code| {
            reaped = code;
            break;
        }
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    try testing.expect(reaped != null);
    // Killed by SIGKILL → 128 + SIGKILL(9) = 137 (our shell-convention mapping).
    try testing.expectEqual(@as(i64, 128 + 9), reaped.?);

    pc.child().terminate();
    terminated = true;
}
