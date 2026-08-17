//! On-box end-to-end smoke for the per-session ConPTY holder (T904):
//! `ghoztty-agent --pty-host-smoke` spawns REAL `--pty-host` holder processes
//! of its own binary and drives them over the real named pipe, proving on the
//! box what the unit lane cannot: ConPTY output flows, RESIZE reaches the
//! shell, an owner disconnect + reconnect replays the gap without losing a
//! byte, EXIT carries the shell's code, an ownerless holder is torn down by
//! its Job Object when killed, and an owner dying never touches the shell.
//!
//! Output contract (consumed by `test\win32\pty-host.ps1`): one `ok - ...` /
//! `FAIL - ...` line per check on STDOUT, and a final verdict line
//! `PTY-HOST SMOKE: ALL PASS` | `PTY-HOST SMOKE: <n> FAILURE(S)`. Exit code 0
//! only on ALL PASS. A hung step is ended by the global watchdog (exit 2).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const proto = @import("pty_host_proto.zig");
const pty_host = @import("pty_host.zig");
const pipe_stream = @import("../pipe_stream.zig");
const server = @import("server.zig");

const is_windows = builtin.os.tag == .windows;
const log = std.log.scoped(.pty_host_smoke);

pub const run = if (is_windows) win.run else stub.run;

const stub = struct {
    fn run(_: Allocator) !void {
        return error.PtyHostUnsupported; // Windows-only (parse-time gated)
    }
};

const win = struct {
    const windows = std.os.windows;

    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn OpenProcess(
        dwDesiredAccess: windows.DWORD,
        bInheritHandle: windows.BOOL,
        dwProcessId: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;

    const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;
    const STILL_ACTIVE: windows.DWORD = 259;

    /// Global check tally. The smoke is single-threaded (plus the watchdog),
    /// so plain vars are fine.
    var failures: usize = 0;

    fn say(comptime fmt: []const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        std.fs.File.stdout().writeAll(line) catch {};
    }

    fn check(cond: bool, comptime what: []const u8, args: anytype) void {
        if (cond) {
            say("ok - " ++ what, args);
        } else {
            failures += 1;
            say("FAIL - " ++ what, args);
        }
    }

    fn watchdog() void {
        std.Thread.sleep(180 * std.time.ns_per_s);
        say("FAIL - smoke watchdog fired (a step hung > 180s)", .{});
        say("PTY-HOST SMOKE: TIMED OUT", .{});
        std.process.exit(2);
    }

    // -------------------------------------------------------------------------
    // Owner-side test client (smoke-local; the production owner is T905's)
    // -------------------------------------------------------------------------

    const Owner = struct {
        alloc: Allocator,
        pstream: *pipe_stream.PipeStream,
        stream: server.Stream,
        accum: proto.Accum,
        /// Next output offset expected (continuity-checked on every frame).
        received: u64,
        /// Every output byte seen on THIS connection, in order.
        collected: std.ArrayList(u8) = .empty,
        /// Set when an EXIT frame arrives.
        exit_code: ?i64 = null,
        /// Owned copies of the HELLO fields.
        hello_stamp: []u8 = &.{},
        hello_sid: []u8 = &.{},
        hello: proto.Hello = undefined,
        /// Offset of the FIRST output frame after ATTACH (for replay checks).
        first_offset: ?u64 = null,
        contiguous: bool = true,

        /// Dial the holder pipe (retrying while the holder starts up), read
        /// HELLO, send ATTACH with `ack`.
        fn connect(alloc: Allocator, pipe_name: []const u8, ack: u64) !Owner {
            var attempt: usize = 0;
            const pipe_handle = while (true) : (attempt += 1) {
                if (pipe_stream.dialHandle(alloc, pipe_name)) |h| break h else |err| {
                    if (attempt > 100) return err;
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                }
            };
            const pstream = try pipe_stream.PipeStream.create(alloc, pipe_handle);
            var self: Owner = .{
                .alloc = alloc,
                .pstream = pstream,
                .stream = pstream.serverStream(),
                .accum = proto.Accum.init(alloc),
                .received = ack,
            };
            errdefer self.deinit();

            // First frame must be HELLO.
            const f = (try self.nextFrame()) orelse return error.NoHello;
            if (f.type != .hello) return error.NoHello;
            const h = try proto.Hello.decode(f.payload);
            self.hello_stamp = try alloc.dupe(u8, h.stamp);
            self.hello_sid = try alloc.dupe(u8, h.session_id);
            self.hello = h;
            self.hello.stamp = self.hello_stamp;
            self.hello.session_id = self.hello_sid;

            var abuf: [10]u8 = undefined;
            const payload = proto.Attach.encode(.{ .version = proto.proto_version, .ack = ack }, &abuf);
            try self.sendFrame(.attach, payload);
            return self;
        }

        fn deinit(self: *Owner) void {
            self.stream.close();
            self.pstream.destroy(self.alloc);
            self.accum.deinit();
            self.collected.deinit(self.alloc);
            if (self.hello_stamp.len > 0) self.alloc.free(self.hello_stamp);
            if (self.hello_sid.len > 0) self.alloc.free(self.hello_sid);
        }

        fn sendFrame(self: *Owner, t: proto.FrameType, payload: []const u8) !void {
            var hdr: [proto.header_len]u8 = undefined;
            proto.frameHeader(t, @intCast(payload.len), &hdr);
            try self.stream.writeAll(&hdr);
            if (payload.len > 0) try self.stream.writeAll(payload);
        }

        fn sendInput(self: *Owner, bytes: []const u8) !void {
            try self.sendFrame(.input, bytes);
        }

        fn sendAck(self: *Owner, offset: u64) !void {
            var buf: [8]u8 = undefined;
            try self.sendFrame(.ack, proto.Ack.encode(.{ .offset = offset }, &buf));
        }

        fn sendResize(self: *Owner, rows: u16, cols: u16) !void {
            var buf: [8]u8 = undefined;
            try self.sendFrame(.resize, proto.Resize.encode(.{ .rows = rows, .cols = cols }, &buf));
        }

        /// Read one whole frame (blocking; the watchdog bounds a hang).
        /// Null ⇒ the holder closed the pipe.
        fn nextFrame(self: *Owner) !?proto.Frame {
            var buf: [64 * 1024]u8 = undefined;
            while (true) {
                if (try self.accum.next()) |f| return f;
                const n = self.stream.read(&buf) catch 0;
                if (n == 0) return null;
                try self.accum.push(buf[0..n]);
            }
        }

        /// Pump frames until `needle` appears in this connection's collected
        /// output (true), or the stream ends / EXIT arrives first (false).
        fn pumpUntil(self: *Owner, needle: []const u8) !bool {
            while (true) {
                if (std.mem.indexOf(u8, self.collected.items, needle) != null) return true;
                const f = (try self.nextFrame()) orelse return false;
                try self.handle(f);
                if (self.exit_code != null and
                    std.mem.indexOf(u8, self.collected.items, needle) == null) return false;
            }
        }

        /// Pump frames until EXIT (true) or stream end (false).
        fn pumpUntilExit(self: *Owner) !bool {
            while (self.exit_code == null) {
                const f = (try self.nextFrame()) orelse return false;
                try self.handle(f);
            }
            return true;
        }

        fn handle(self: *Owner, f: proto.Frame) !void {
            switch (f.type) {
                .output => {
                    const o = try proto.Output.decode(f.payload);
                    if (self.first_offset == null) self.first_offset = o.offset;
                    if (o.offset != self.received and self.first_offset.? != o.offset)
                        self.contiguous = false;
                    self.received = o.offset + o.bytes.len;
                    try self.collected.appendSlice(self.alloc, o.bytes);
                },
                .exit => {
                    const e = try proto.Exit.decode(f.payload);
                    self.exit_code = e.code;
                },
                else => {},
            }
        }
    };

    // -------------------------------------------------------------------------
    // Holder process management
    // -------------------------------------------------------------------------

    fn spawnHolder(alloc: Allocator, self_exe: []const u8, sid: []const u8) !std.process.Child {
        var child = std.process.Child.init(
            &.{ self_exe, "--pty-host", "--session-id", sid },
            alloc,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        return child;
    }

    fn pidAlive(pid: u32) bool {
        const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, windows.FALSE, pid) orelse return false;
        defer windows.CloseHandle(h);
        var code: windows.DWORD = 0;
        if (windows.kernel32.GetExitCodeProcess(h, &code) == 0) return false;
        return code == STILL_ACTIVE;
    }

    /// Poll until `pid` is gone; false if still alive after `ms`.
    fn waitPidGone(pid: u32, ms: u64) bool {
        var waited: u64 = 0;
        while (waited < ms) : (waited += 100) {
            if (!pidAlive(pid)) return true;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        return !pidAlive(pid);
    }

    /// Poll until the holder child exits; false if still running after `ms`.
    fn waitHolderExit(child: *std.process.Child, ms: u64) bool {
        var waited: u64 = 0;
        while (waited < ms) : (waited += 100) {
            var code: windows.DWORD = 0;
            if (windows.kernel32.GetExitCodeProcess(child.id, &code) == 0) return true;
            if (code != STILL_ACTIVE) return true;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // The scenarios
    // -------------------------------------------------------------------------

    fn run(alloc: Allocator) !void {
        const wd = try std.Thread.spawn(.{}, watchdog, .{});
        wd.detach();

        const self_exe = try std.fs.selfExePathAlloc(alloc);
        defer alloc.free(self_exe);

        try scenarioLifecycle(alloc, self_exe);
        try scenarioJobKill(alloc, self_exe);

        if (failures == 0) {
            say("PTY-HOST SMOKE: ALL PASS", .{});
        } else {
            say("PTY-HOST SMOKE: {d} FAILURE(S)", .{failures});
            std.process.exit(1);
        }
    }

    /// Echo → resize → disconnect (shell survives) → reconnect (gap replays)
    /// → exit (code travels, holder finishes).
    fn scenarioLifecycle(alloc: Allocator, self_exe: []const u8) !void {
        var sid_buf: [64]u8 = undefined;
        const sid = try std.fmt.bufPrint(&sid_buf, "smoke-{d}-a", .{GetCurrentProcessId()});
        const pipe_name = try pty_host.defaultPipeName(alloc, sid);
        defer alloc.free(pipe_name);

        var holder = try spawnHolder(alloc, self_exe, sid);
        var holder_done = false;
        defer if (!holder_done) {
            _ = holder.kill() catch {};
        };

        // --- connection 1: hello + echo + resize -----------------------------
        var own = try Owner.connect(alloc, pipe_name, 0);
        check(own.hello.version == proto.proto_version, "hello: protocol v{d}", .{own.hello.version});
        check(std.mem.eql(u8, own.hello.session_id, sid), "hello: session id round-trips", .{});
        check(own.hello.stamp.len > 0, "hello: holder build stamp present ({s})", .{own.hello.stamp});
        check(own.hello.shell_pid != 0, "hello: shell pid published ({d})", .{own.hello.shell_pid});
        check(!own.hello.exited, "hello: shell running", .{});
        const shell_pid = own.hello.shell_pid;

        try own.sendInput("echo AAA-1717\r\n");
        check(try own.pumpUntil("AAA-1717"), "output flows: echoed marker arrived", .{});

        // Resize, then have the shell REPORT its size: `mode con` prints the
        // console dimensions as the shell sees them — 113 columns only shows
        // up if ResizePseudoConsole actually reached the ConPTY.
        try own.sendResize(41, 113);
        std.Thread.sleep(300 * std.time.ns_per_ms);
        try own.sendInput("mode con\r\n");
        check(try own.pumpUntil("113"), "resize: shell reports the new width (113 cols)", .{});

        // Ack what we have, provoke output we will NOT read on this
        // connection, and vanish without ceremony (an owner crash).
        try own.sendAck(own.received);
        const ack1 = own.received;
        try own.sendInput("echo BBB-2828\r\n");
        std.Thread.sleep(500 * std.time.ns_per_ms);
        own.deinit();

        check(pidAlive(shell_pid), "owner death leaves the shell alive (pid {d})", .{shell_pid});

        // --- connection 2: replay the gap ------------------------------------
        var own2 = try Owner.connect(alloc, pipe_name, ack1);
        check(own2.hello.end > ack1, "reconnect: holder buffered output while ownerless", .{});
        check(try own2.pumpUntil("BBB-2828"), "reconnect: gap replayed (marker typed while detached)", .{});
        const expect_start = proto.replayStart(ack1, own2.hello.start, own2.hello.end);
        check(
            own2.first_offset != null and own2.first_offset.? == expect_start,
            "reconnect: replay starts at the negotiated offset ({d})",
            .{expect_start},
        );
        check(own2.contiguous, "reconnect: output offsets are contiguous (no bytes lost)", .{});

        // --- exit: code travels, holder finishes ------------------------------
        try own2.sendInput("exit 42\r\n");
        check(try own2.pumpUntilExit(), "exit: EXIT frame delivered", .{});
        check(
            own2.exit_code != null and own2.exit_code.? == 42,
            "exit: shell exit code carried (want 42, got {?d})",
            .{own2.exit_code},
        );
        own2.deinit();

        check(waitHolderExit(&holder, 10_000), "holder exits after delivering EXIT", .{});
        holder_done = true;
        _ = holder.wait() catch {};
        check(waitPidGone(shell_pid, 5_000), "shell fully gone after exit", .{});
    }

    /// Kill the holder outright: its kill-on-close Job Object must take the
    /// shell subtree with it (no orphaned conhost/cmd).
    fn scenarioJobKill(alloc: Allocator, self_exe: []const u8) !void {
        var sid_buf: [64]u8 = undefined;
        const sid = try std.fmt.bufPrint(&sid_buf, "smoke-{d}-b", .{GetCurrentProcessId()});
        const pipe_name = try pty_host.defaultPipeName(alloc, sid);
        defer alloc.free(pipe_name);

        var holder = try spawnHolder(alloc, self_exe, sid);
        var own = try Owner.connect(alloc, pipe_name, 0);
        const shell_pid = own.hello.shell_pid;
        check(shell_pid != 0 and pidAlive(shell_pid), "job-kill: shell running (pid {d})", .{shell_pid});
        own.deinit();

        _ = holder.kill() catch {};
        _ = holder.wait() catch {};
        check(
            waitPidGone(shell_pid, 10_000),
            "job-kill: killing the holder terminates the shell subtree",
            .{},
        );
    }
};
