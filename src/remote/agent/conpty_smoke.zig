//! ConPTY runtime smoke probe (WP2, §13) — a standalone Windows .exe that proves
//! the in-tree ConPTY machinery (`src/pty.zig` `WindowsPty` + `src/CommandCore.zig`
//! `startWindows`) actually works on a real Windows box. It is intentionally tiny:
//! a runtime de-risking probe, NOT production code.
//!
//! What it does (and nothing more):
//!   1. Opens a `Pty` (the `WindowsPty` variant) at 80x25 → `CreatePseudoConsole`.
//!   2. Spawns `cmd.exe` (resolved from `%COMSPEC%`, fallback
//!      `C:\Windows\System32\cmd.exe`) as a ConPTY child via
//!      `CommandCore.DefaultCommand`, wiring `pseudo_console` + null stdio EXACTLY
//!      like the canonical terminal path (`src/termio/Exec.zig:1027`).
//!   3. Writes `echo hello-from-ghoztty-conpty\r\nexit\r\n` to the ConPTY input
//!      (`pty.in_pipe`) — cmd.exe needs CR, so `\r\n`.
//!   4. Runs a reader thread that pumps ConPTY output (`pty.out_pipe`) via
//!      `ReadFile` straight to the process's real stdout (so the user sees the
//!      cmd banner + the echoed line).
//!   5. Reaps the child (`cmd.wait(true)`) and prints the exit marker line.
//!
//! Build (cross-compiled from macOS, see `build.zig` `conpty-smoke` step):
//!   zig build conpty-smoke -Dtarget=x86_64-windows  → ...-x86_64.exe
//!   zig build conpty-smoke -Dtarget=aarch64-windows → ...-aarch64.exe
//! GNU ABI is used to match the WP2 spike (MinGW import libs).

const std = @import("std");
const builtin = @import("builtin");

const Pty = @import("../../pty.zig").Pty;
const winsize = @import("../../pty.zig").winsize;
const CommandCore = @import("../../CommandCore.zig");
const windows = @import("../../os/main.zig").windows;
// The shared `os/windows.zig` wrapper re-exports HANDLE/DWORD/INVALID_HANDLE_VALUE,
// but not the std-handle constants or the raw ReadFile/WriteFile/GetStdHandle
// stdio calls — those come straight from `std.os.windows` (same kernel32 the
// spike used in `src/remote/agent/spike/main.zig`).
const w = std.os.windows;

comptime {
    if (builtin.os.tag != .windows)
        @compileError("conpty_smoke is Windows-only; build with -Dtarget=x86_64-windows or aarch64-windows");
}

/// GUI-free command type — the exact same one the production agent + ssh
/// transport use to spawn ConPTY children.
const Command = CommandCore.DefaultCommand;

/// The line we expect to see echoed back through the ConPTY, proving bytes flow
/// child → out_pipe → our stdout.
const conpty_input = "echo hello-from-ghoztty-conpty\r\nexit\r\n";

/// Shared state handed to the reader thread.
const Reader = struct {
    /// ConPTY output handle (read side, owned by the parent).
    out_pipe: windows.HANDLE,
    /// The process's real stdout handle (where we mirror child bytes).
    stdout: windows.HANDLE,

    fn run(self: *Reader) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            var read: windows.DWORD = 0;
            // ReadFile on the ConPTY out_pipe blocks until bytes are available;
            // returns 0 (with BROKEN_PIPE) once the ConPTY tears down after the
            // child exits, which is our EOF.
            if (w.kernel32.ReadFile(self.out_pipe, &buf, buf.len, &read, null) == 0)
                return;
            if (read == 0) return;

            // Mirror raw bytes straight to our real stdout — no translation, so
            // the user sees the cmd banner + the echoed line verbatim.
            var off: usize = 0;
            while (off < read) {
                var written: windows.DWORD = 0;
                if (w.kernel32.WriteFile(
                    self.stdout,
                    buf[off..read].ptr,
                    @intCast(read - off),
                    &written,
                    null,
                ) == 0) return;
                off += written;
            }
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Clear the inherited ignore-^C flag (set by CREATE_NEW_PROCESS_GROUP
    // anywhere up the ancestor chain and inherited by every descendant).
    // Without this, ConPTY children spawned below inherit ^C-disabled and
    // every interrupt probe false-negatives (T84 root cause).
    _ = SetConsoleCtrlHandler(null, w.FALSE);

    // Scenario select (T84 diagnostics ride along in the same exe so no new
    // build step is needed):
    //   (no args)      → original echo smoke
    //   --ctrlc        → spawn cmd, run `ping -t`, write raw 0x03, verify signal
    //   --ctrlc-win32  → same but the interrupt is win32-input-mode encoded
    var args_iter = try std.process.argsWithAllocator(alloc);
    defer args_iter.deinit();
    _ = args_iter.next(); // exe name
    var mode: enum { smoke, ctrlc_raw, ctrlc_win32, ctrlc_anon, ctrlc_mode, ctrlc_host, ctrlc_self, report_mode, report_ctrlc } = .smoke;
    var host_path: ?[]const u8 = null;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ctrlc")) mode = .ctrlc_raw;
        if (std.mem.eql(u8, arg, "--ctrlc-win32")) mode = .ctrlc_win32;
        if (std.mem.eql(u8, arg, "--ctrlc-anon")) mode = .ctrlc_anon;
        if (std.mem.eql(u8, arg, "--ctrlc-mode")) mode = .ctrlc_mode;
        if (std.mem.eql(u8, arg, "--ctrlc-self")) mode = .ctrlc_self;
        if (std.mem.eql(u8, arg, "--report-mode")) mode = .report_mode;
        if (std.mem.eql(u8, arg, "--report-ctrlc")) mode = .report_ctrlc;
        if (std.mem.eql(u8, arg, "--ctrlc-host")) {
            mode = .ctrlc_host;
            host_path = args_iter.next();
        }
    }
    switch (mode) {
        .smoke => try runSmoke(alloc),
        .ctrlc_raw => try runCtrlc(alloc, false),
        .ctrlc_win32 => try runCtrlc(alloc, true),
        .ctrlc_anon => try runCtrlcAnon(alloc),
        .ctrlc_mode => try runModeDump(alloc),
        .ctrlc_host => try runCtrlcHost(alloc, host_path orelse return error.MissingHostPath),
        .ctrlc_self => try runCtrlcSelf(alloc),
        .report_mode => try runReportMode(),
        .report_ctrlc => try runReportCtrlc(),
    }
}

fn runSmoke(alloc: std.mem.Allocator) !void {
    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;

    // 1. Open the ConPTY at 80x25.
    //
    // NOTE: no `defer pty.deinit()` here. The reader thread blocks in
    // ReadFile(out_pipe), which only hits EOF once the pseudoconsole is closed
    // (ClosePseudoConsole, inside deinit). If deinit were deferred to end-of-main
    // it would run AFTER `thread.join()` → classic ConPTY teardown deadlock. So we
    // call deinit explicitly below, BEFORE the join, to unblock the reader.
    var pty = try Pty.open(.{
        .ws_row = 25,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    });

    // Resolve cmd.exe from %COMSPEC%, falling back to the well-known path.
    // `cmd.path`/`cmd.args` need null-terminated strings; getEnvVarOwned returns
    // a plain []u8, so dupe it with a sentinel.
    const comspec_owned: ?[]u8 = std.process.getEnvVarOwned(alloc, "COMSPEC") catch null;
    defer if (comspec_owned) |c| alloc.free(c);
    const cmd_path: [:0]const u8 = if (comspec_owned) |c|
        try alloc.dupeZ(u8, c)
    else
        "C:\\Windows\\System32\\cmd.exe";
    defer if (comspec_owned != null) alloc.free(cmd_path);

    // 2. Spawn cmd.exe as a ConPTY child. This mirrors the canonical terminal
    //    wiring in `src/termio/Exec.zig:1027` EXACTLY for the Windows branch:
    //    stdin/stdout/stderr are null (the ConPTY owns the child's std handles via
    //    the PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE attribute), and `pseudo_console`
    //    carries `pty.pseudo_console`. `CommandCore.startWindows` reads that field
    //    and wires it via UpdateProcThreadAttribute (CommandCore.zig:306).
    var cmd: Command = .{
        .path = cmd_path,
        .args = &.{cmd_path},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .pseudo_console = pty.pseudo_console,
    };
    try cmd.start(alloc);

    // 4. Start the reader thread BEFORE writing input, so we never miss the
    //    banner/echo (the ConPTY can emit before our input is consumed).
    var reader: Reader = .{ .out_pipe = pty.out_pipe, .stdout = stdout };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});

    // 3. Write the command to the ConPTY input. cmd.exe needs CR (\r\n).
    {
        var off: usize = 0;
        while (off < conpty_input.len) {
            var written: windows.DWORD = 0;
            if (w.kernel32.WriteFile(
                pty.in_pipe,
                conpty_input[off..].ptr,
                @intCast(conpty_input.len - off),
                &written,
                null,
            ) == 0) return error.WriteInputFailed;
            off += written;
        }
    }

    // 5. Reap the child, then tear down the ConPTY BEFORE joining the reader.
    //    Closing the pseudoconsole (inside pty.deinit) is what gives the reader's
    //    blocked ReadFile(out_pipe) its EOF; do it first or join() deadlocks.
    const exit = try cmd.wait(true);
    pty.deinit();
    thread.join();

    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "\r\n=== ghoztty-conpty-smoke: child exited, code={d} ===\r\n",
        .{exit.Exited},
    ) catch "\r\n=== ghoztty-conpty-smoke: child exited ===\r\n";
    var written: windows.DWORD = 0;
    _ = w.kernel32.WriteFile(stdout, line.ptr, @intCast(line.len), &written, null);
}

// ---------------------------------------------------------------------------
// T84 ctrl+c probe
// ---------------------------------------------------------------------------

extern "kernel32" fn GetProcessId(Process: w.HANDLE) callconv(.winapi) w.DWORD;

/// Reader thread that mirrors ConPTY output to stdout AND keeps a capture
/// buffer so the probe can count `Reply from` lines around the interrupt.
const CaptureReader = struct {
    out_pipe: windows.HANDLE,
    stdout: windows.HANDLE,
    mutex: std.Thread.Mutex = .{},
    buf: [1 << 18]u8 = undefined,
    len: usize = 0,

    fn run(self: *CaptureReader) void {
        var tmp: [4096]u8 = undefined;
        while (true) {
            var read: windows.DWORD = 0;
            if (w.kernel32.ReadFile(self.out_pipe, &tmp, tmp.len, &read, null) == 0)
                return;
            if (read == 0) return;

            self.mutex.lock();
            const n = @min(@as(usize, read), self.buf.len - self.len);
            @memcpy(self.buf[self.len..][0..n], tmp[0..n]);
            self.len += n;
            self.mutex.unlock();

            writeAll(self.stdout, tmp[0..read]) catch return;
        }
    }

    fn count(self: *CaptureReader, needle: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return std.mem.count(u8, self.buf[0..self.len], needle);
    }
};

fn writeAll(handle: windows.HANDLE, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        var written: windows.DWORD = 0;
        if (w.kernel32.WriteFile(
            handle,
            bytes[off..].ptr,
            @intCast(bytes.len - off),
            &written,
            null,
        ) == 0) return error.WriteFailed;
        off += written;
    }
}

fn sleepMs(ms: u64) void {
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

/// The T84 repro, minimal: ghoztty's own Pty + CommandCore spawn cmd.exe,
/// `ping -t` runs, we write an interrupt (raw 0x03 or the win32-input-mode
/// encoding of ctrl+c) followed by `exit`. If the interrupt cooked into a
/// CTRL_C_EVENT, ping dies, cmd reads `exit`, and the child handle signals;
/// if not, the wait times out and we tree-kill the child.
fn runCtrlc(alloc: std.mem.Allocator, win32_encoding: bool) !void {
    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;

    var pty = try Pty.open(.{
        .ws_row = 25,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    });

    const comspec_owned: ?[]u8 = std.process.getEnvVarOwned(alloc, "COMSPEC") catch null;
    const cmd_path: [:0]const u8 = if (comspec_owned) |c|
        try alloc.dupeZ(u8, c)
    else
        "C:\\Windows\\System32\\cmd.exe";
    defer if (comspec_owned) |c| {
        alloc.free(c);
        alloc.free(cmd_path);
    };

    var cmd: Command = .{
        .path = cmd_path,
        .args = &.{cmd_path},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .pseudo_console = pty.pseudo_console,
    };
    try cmd.start(alloc);
    const child_pid = GetProcessId(cmd.pid.?);

    const reader = try alloc.create(CaptureReader);
    defer alloc.destroy(reader);
    reader.* = .{ .out_pipe = pty.out_pipe, .stdout = stdout };
    const thread = try std.Thread.spawn(.{}, CaptureReader.run, .{reader});

    // Let cmd print its banner + prompt, then start the runaway child.
    sleepMs(1500);
    try writeAll(pty.in_pipe, "ping -t 127.0.0.1\r\n");
    sleepMs(3000);
    const replies_before = reader.count("Reply from");

    // The interrupt under test.
    if (win32_encoding) {
        // win32-input-mode (CSI Vk;Sc;Uc;Kd;Cs;Rc _): ctrl down, C down
        // (uChar=0x03, LEFT_CTRL_PRESSED), C up, ctrl up.
        try writeAll(pty.in_pipe, "\x1b[17;29;0;1;8;1_" ++
            "\x1b[67;46;3;1;8;1_" ++
            "\x1b[67;46;3;0;8;1_" ++
            "\x1b[17;29;0;0;0;1_");
    } else {
        try writeAll(pty.in_pipe, "\x03");
    }
    sleepMs(3000);
    const replies_after = reader.count("Reply from");

    // If ^C worked, cmd is back at the prompt and will read this.
    try writeAll(pty.in_pipe, "exit\r\n");
    const wait_res = w.kernel32.WaitForSingleObject(cmd.pid.?, 5000);
    const interrupted = wait_res == w.WAIT_OBJECT_0;

    if (!interrupted) {
        // Tree-kill (cmd + ping) so the probe never leaks a runaway ping.
        const pid_str = std.fmt.allocPrint(alloc, "{d}", .{child_pid}) catch "0";
        defer if (!std.mem.eql(u8, pid_str, "0")) alloc.free(pid_str);
        var kill = std.process.Child.init(&.{ "taskkill", "/T", "/F", "/PID", pid_str }, alloc);
        kill.stdout_behavior = .Ignore;
        kill.stderr_behavior = .Ignore;
        _ = kill.spawnAndWait() catch {};
    }

    pty.deinit();
    thread.join();

    var line_buf: [256]u8 = undefined;
    const verdict = std.fmt.bufPrint(
        &line_buf,
        "\r\n=== ctrlc-probe({s}): {s} — replies before={d} after(+3s)={d} ===\r\n",
        .{
            if (win32_encoding) @as([]const u8, "win32") else "raw",
            if (interrupted) @as([]const u8, "INTERRUPT OK") else "INTERRUPT FAILED (child never read 'exit')",
            replies_before,
            replies_after,
        },
    ) catch "\r\n=== ctrlc-probe: verdict format failed ===\r\n";
    try writeAll(stdout, verdict);
}

/// Same interrupt scenario as `runCtrlc(raw)`, but the ConPTY is built here
/// from two anonymous CreatePipe pairs — no ghoztty named pipe, no overlapped
/// flag. Discriminates "ghoztty's pipe topology breaks ^C" from "conhost
/// itself never cooks ETX in this environment".
fn runCtrlcAnon(alloc: std.mem.Allocator) !void {
    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;

    var in_read: windows.HANDLE = undefined; // conhost reads input here
    var in_write: windows.HANDLE = undefined; // we write input here
    var out_read: windows.HANDLE = undefined; // we read output here
    var out_write: windows.HANDLE = undefined; // conhost writes output here
    if (windows.exp.kernel32.CreatePipe(&in_read, &in_write, null, 0) == 0)
        return error.Unexpected;
    if (windows.exp.kernel32.CreatePipe(&out_read, &out_write, null, 0) == 0)
        return error.Unexpected;

    var hpc: windows.exp.HPCON = undefined;
    if (windows.exp.kernel32.CreatePseudoConsole(
        .{ .X = 80, .Y = 25 },
        in_read,
        out_write,
        0,
        &hpc,
    ) != windows.S_OK) return error.Unexpected;

    const comspec_owned: ?[]u8 = std.process.getEnvVarOwned(alloc, "COMSPEC") catch null;
    const cmd_path: [:0]const u8 = if (comspec_owned) |c|
        try alloc.dupeZ(u8, c)
    else
        "C:\\Windows\\System32\\cmd.exe";
    defer if (comspec_owned) |c| {
        alloc.free(c);
        alloc.free(cmd_path);
    };

    var cmd: Command = .{
        .path = cmd_path,
        .args = &.{cmd_path},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .pseudo_console = hpc,
    };
    try cmd.start(alloc);
    const child_pid = GetProcessId(cmd.pid.?);

    const reader = try alloc.create(CaptureReader);
    defer alloc.destroy(reader);
    reader.* = .{ .out_pipe = out_read, .stdout = stdout };
    const thread = try std.Thread.spawn(.{}, CaptureReader.run, .{reader});

    sleepMs(1500);
    try writeAll(in_write, "ping -t 127.0.0.1\r\n");
    sleepMs(3000);
    const replies_before = reader.count("Reply from");
    try writeAll(in_write, "\x03");
    sleepMs(3000);
    const replies_after = reader.count("Reply from");
    try writeAll(in_write, "exit\r\n");
    const wait_res = w.kernel32.WaitForSingleObject(cmd.pid.?, 5000);
    const interrupted = wait_res == w.WAIT_OBJECT_0;

    if (!interrupted) {
        const pid_str = std.fmt.allocPrint(alloc, "{d}", .{child_pid}) catch "0";
        defer if (!std.mem.eql(u8, pid_str, "0")) alloc.free(pid_str);
        var kill = std.process.Child.init(&.{ "taskkill", "/T", "/F", "/PID", pid_str }, alloc);
        kill.stdout_behavior = .Ignore;
        kill.stderr_behavior = .Ignore;
        _ = kill.spawnAndWait() catch {};
    }

    // Teardown before join so the reader's blocked ReadFile gets its EOF.
    _ = windows.CloseHandle(in_read);
    _ = windows.CloseHandle(in_write);
    _ = windows.CloseHandle(out_write);
    windows.exp.kernel32.ClosePseudoConsole(hpc);
    _ = windows.CloseHandle(out_read);
    thread.join();

    var line_buf: [256]u8 = undefined;
    const verdict = std.fmt.bufPrint(
        &line_buf,
        "\r\n=== ctrlc-probe(anon): {s} — replies before={d} after(+3s)={d} ===\r\n",
        .{
            if (interrupted) @as([]const u8, "INTERRUPT OK") else "INTERRUPT FAILED (child never read 'exit')",
            replies_before,
            replies_after,
        },
    ) catch "\r\n=== ctrlc-probe: verdict format failed ===\r\n";
    try writeAll(stdout, verdict);
}

/// Spawns cmd in the ghoztty ConPTY and runs `<self> --report-mode` inside it,
/// surfacing the console input/output modes the child actually sees (is
/// ENABLE_PROCESSED_INPUT even on?).
fn runModeDump(alloc: std.mem.Allocator) !void {
    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;

    var pty = try Pty.open(.{
        .ws_row = 25,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    });

    const comspec_owned: ?[]u8 = std.process.getEnvVarOwned(alloc, "COMSPEC") catch null;
    const cmd_path: [:0]const u8 = if (comspec_owned) |c|
        try alloc.dupeZ(u8, c)
    else
        "C:\\Windows\\System32\\cmd.exe";
    defer if (comspec_owned) |c| {
        alloc.free(c);
        alloc.free(cmd_path);
    };

    var cmd: Command = .{
        .path = cmd_path,
        .args = &.{cmd_path},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .pseudo_console = pty.pseudo_console,
    };
    try cmd.start(alloc);

    const reader = try alloc.create(CaptureReader);
    defer alloc.destroy(reader);
    reader.* = .{ .out_pipe = pty.out_pipe, .stdout = stdout };
    const thread = try std.Thread.spawn(.{}, CaptureReader.run, .{reader});

    const self_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(self_path);
    const report_cmd = try std.fmt.allocPrint(
        alloc,
        "\"{s}\" --report-mode\r\n",
        .{self_path},
    );
    defer alloc.free(report_cmd);

    sleepMs(1500);
    try writeAll(pty.in_pipe, report_cmd);
    sleepMs(2500);
    try writeAll(pty.in_pipe, "exit\r\n");
    _ = w.kernel32.WaitForSingleObject(cmd.pid.?, 5000);

    pty.deinit();
    thread.join();

    try writeAll(stdout, "\r\n=== ctrlc-probe(mode): see CONSOLE_MODES line above ===\r\n");
}

/// Same raw-0x03 interrupt scenario, but instead of CreatePseudoConsole the
/// console host exe is launched manually in classic headless mode
/// (`<host> --headless --width 80 --height 25 -- cmd.exe`, VT pipes = the
/// host's std handles). This lets us A/B the inbox conhost.exe against
/// Windows Terminal's OpenConsole.exe with an otherwise identical driver.
fn runCtrlcHost(alloc: std.mem.Allocator, host_path: []const u8) !void {
    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;

    var sa = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .bInheritHandle = windows.TRUE,
        .lpSecurityDescriptor = null,
    };
    var in_read: windows.HANDLE = undefined;
    var in_write: windows.HANDLE = undefined;
    var out_read: windows.HANDLE = undefined;
    var out_write: windows.HANDLE = undefined;
    if (windows.exp.kernel32.CreatePipe(&in_read, &in_write, &sa, 0) == 0)
        return error.Unexpected;
    if (windows.exp.kernel32.CreatePipe(&out_read, &out_write, &sa, 0) == 0)
        return error.Unexpected;
    // Only the host-side ends may be inherited.
    try windows.SetHandleInformation(in_write, windows.HANDLE_FLAG_INHERIT, 0);
    try windows.SetHandleInformation(out_read, windows.HANDLE_FLAG_INHERIT, 0);

    const cmdline = try std.fmt.allocPrint(
        alloc,
        "\"{s}\" --headless --width 80 --height 25 -- cmd.exe",
        .{host_path},
    );
    defer alloc.free(cmdline);
    const cmdline_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, cmdline);
    defer alloc.free(cmdline_w);

    var si = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    si.dwFlags = 0x100; // STARTF_USESTDHANDLES
    si.hStdInput = in_read;
    si.hStdOutput = out_write;
    si.hStdError = out_write;

    var pi: w.PROCESS_INFORMATION = undefined;
    if (windows.exp.kernel32.CreateProcessW(
        null,
        cmdline_w.ptr,
        null,
        null,
        windows.TRUE,
        windows.exp.CREATE_UNICODE_ENVIRONMENT | 0x08000000, // CREATE_NO_WINDOW
        null,
        null,
        @ptrCast(&si),
        &pi,
    ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());
    _ = windows.CloseHandle(pi.hThread);
    // Parent must drop the host-side ends or the reader never sees EOF.
    _ = windows.CloseHandle(in_read);
    _ = windows.CloseHandle(out_write);

    const reader = try alloc.create(CaptureReader);
    defer alloc.destroy(reader);
    reader.* = .{ .out_pipe = out_read, .stdout = stdout };
    const thread = try std.Thread.spawn(.{}, CaptureReader.run, .{reader});

    sleepMs(1500);
    try writeAll(in_write, "ping -t 127.0.0.1\r\n");
    sleepMs(3000);
    const replies_before = reader.count("Reply from");
    try writeAll(in_write, "\x03");
    sleepMs(3000);
    const replies_after = reader.count("Reply from");
    try writeAll(in_write, "exit\r\n");
    const wait_res = w.kernel32.WaitForSingleObject(pi.hProcess, 5000);
    const interrupted = wait_res == w.WAIT_OBJECT_0;

    if (!interrupted) {
        const pid_str = std.fmt.allocPrint(alloc, "{d}", .{GetProcessId(pi.hProcess)}) catch "0";
        defer if (!std.mem.eql(u8, pid_str, "0")) alloc.free(pid_str);
        var kill = std.process.Child.init(&.{ "taskkill", "/T", "/F", "/PID", pid_str }, alloc);
        kill.stdout_behavior = .Ignore;
        kill.stderr_behavior = .Ignore;
        _ = kill.spawnAndWait() catch {};
    }

    _ = windows.CloseHandle(in_write);
    thread.join();
    _ = windows.CloseHandle(out_read);
    _ = windows.CloseHandle(pi.hProcess);

    var line_buf: [512]u8 = undefined;
    const verdict = std.fmt.bufPrint(
        &line_buf,
        "\r\n=== ctrlc-probe(host {s}): {s} — replies before={d} after(+3s)={d} ===\r\n",
        .{
            host_path,
            if (interrupted) @as([]const u8, "INTERRUPT OK") else "INTERRUPT FAILED (child never read 'exit')",
            replies_before,
            replies_after,
        },
    ) catch "\r\n=== ctrlc-probe: verdict format failed ===\r\n";
    try writeAll(stdout, verdict);
}

/// Spawns cmd in the ghoztty ConPTY, runs `<self> --report-ctrlc` inside it,
/// then writes raw 0x03. Unlike the ping oracle this observes DIRECTLY whether
/// conhost ever raises a console ctrl event in the child: the reporter prints
/// CTRL_EVENT_RECEIVED from its handler. Discriminates "event raised but ping
/// mishandles it" from "event never delivered".
fn runCtrlcSelf(alloc: std.mem.Allocator) !void {
    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;

    var pty = try Pty.open(.{
        .ws_row = 25,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    });

    const comspec_owned: ?[]u8 = std.process.getEnvVarOwned(alloc, "COMSPEC") catch null;
    const cmd_path: [:0]const u8 = if (comspec_owned) |c|
        try alloc.dupeZ(u8, c)
    else
        "C:\\Windows\\System32\\cmd.exe";
    defer if (comspec_owned) |c| {
        alloc.free(c);
        alloc.free(cmd_path);
    };

    var cmd: Command = .{
        .path = cmd_path,
        .args = &.{cmd_path},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .pseudo_console = pty.pseudo_console,
    };
    try cmd.start(alloc);
    const child_pid = GetProcessId(cmd.pid.?);

    const reader = try alloc.create(CaptureReader);
    defer alloc.destroy(reader);
    reader.* = .{ .out_pipe = pty.out_pipe, .stdout = stdout };
    const thread = try std.Thread.spawn(.{}, CaptureReader.run, .{reader});

    const self_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(self_path);
    const report_cmd = try std.fmt.allocPrint(
        alloc,
        "\"{s}\" --report-ctrlc\r\n",
        .{self_path},
    );
    defer alloc.free(report_cmd);

    sleepMs(1500);
    try writeAll(pty.in_pipe, report_cmd);
    sleepMs(2000); // reporter arms its handler and prints REPORTER_ARMED
    const armed = reader.count("REPORTER_ARMED") > 0;
    try writeAll(pty.in_pipe, "\x03");
    sleepMs(3000);
    const received = reader.count("CTRL_EVENT_RECEIVED");

    // Reporter exits on the event or its own 15s timeout; then cmd reads exit.
    try writeAll(pty.in_pipe, "exit\r\n");
    const wait_res = w.kernel32.WaitForSingleObject(cmd.pid.?, 20000);
    if (wait_res != w.WAIT_OBJECT_0) {
        const pid_str = std.fmt.allocPrint(alloc, "{d}", .{child_pid}) catch "0";
        defer if (!std.mem.eql(u8, pid_str, "0")) alloc.free(pid_str);
        var kill = std.process.Child.init(&.{ "taskkill", "/T", "/F", "/PID", pid_str }, alloc);
        kill.stdout_behavior = .Ignore;
        kill.stderr_behavior = .Ignore;
        _ = kill.spawnAndWait() catch {};
    }

    pty.deinit();
    thread.join();

    var line_buf: [256]u8 = undefined;
    const verdict = std.fmt.bufPrint(
        &line_buf,
        "\r\n=== ctrlc-probe(self): armed={} ctrl_events_received={d} — {s} ===\r\n",
        .{
            armed,
            received,
            if (!armed) @as([]const u8, "REPORTER NEVER RAN (inconclusive)") else if (received > 0) "EVENT DELIVERED" else "EVENT NEVER DELIVERED",
        },
    ) catch "\r\n=== ctrlc-probe: verdict format failed ===\r\n";
    try writeAll(stdout, verdict);
}

extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?*const fn (w.DWORD) callconv(.winapi) w.BOOL,
    Add: w.BOOL,
) callconv(.winapi) w.BOOL;

var ctrl_event_seen = std.atomic.Value(bool).init(false);

fn reportCtrlHandler(ctrl_type: w.DWORD) callconv(.winapi) w.BOOL {
    // Handler runs on its own thread; WriteFile to the console is fine here.
    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        return w.TRUE;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "CTRL_EVENT_RECEIVED type={d}\r\n",
        .{ctrl_type},
    ) catch return w.TRUE;
    writeAll(stdout, line) catch {};
    ctrl_event_seen.store(true, .seq_cst);
    return w.TRUE; // handled — don't let the default handler kill us
}

/// Child-side ctrl reporter: arm a console ctrl handler, then wait up to 15s
/// for any console ctrl event, printing CTRL_EVENT_RECEIVED when one lands.
fn runReportCtrlc() !void {
    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;
    if (SetConsoleCtrlHandler(reportCtrlHandler, w.TRUE) == 0) {
        try writeAll(stdout, "REPORTER_ARM_FAILED\r\n");
        return;
    }
    try writeAll(stdout, "REPORTER_ARMED\r\n");
    var waited_ms: u64 = 0;
    while (waited_ms < 15_000) {
        if (ctrl_event_seen.load(.seq_cst)) {
            sleepMs(200); // let the handler's write flush through conhost
            return;
        }
        sleepMs(100);
        waited_ms += 100;
    }
    try writeAll(stdout, "NO_CTRL_EVENT within 15s\r\n");
}

/// Child-side reporter: run inside a console, print the console modes.
fn runReportMode() !void {
    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;
    const stdin = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;

    var in_mode: windows.DWORD = 0;
    var out_mode: windows.DWORD = 0;
    const in_ok = w.kernel32.GetConsoleMode(stdin, &in_mode) != 0;
    const out_ok = w.kernel32.GetConsoleMode(stdout, &out_mode) != 0;

    var line_buf: [192]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "CONSOLE_MODES input_ok={} input=0x{x} (processed={}) output_ok={} output=0x{x}\r\n",
        .{
            in_ok,
            in_mode,
            (in_mode & 0x1) != 0,
            out_ok,
            out_mode,
        },
    ) catch return;
    try writeAll(stdout, line);
}
