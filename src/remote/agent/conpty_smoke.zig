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

    const stdout = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;

    // 1. Open the ConPTY at 80x25.
    var pty = try Pty.open(.{
        .ws_row = 25,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    });
    defer pty.deinit();

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

    // 5. Reap the child, then join the reader (the ConPTY out_pipe hits EOF once
    //    the console tears down after the child exits).
    const exit = try cmd.wait(true);
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
