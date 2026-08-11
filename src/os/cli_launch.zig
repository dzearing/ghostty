//! Was this process launched FROM A COMMAND LINE? (T506)
//!
//! `Config.probableCliEnvironment` needs an answer on Windows and had none:
//! upstream hardcodes `false` there with a comment calling Windows "not a real
//! supported target". This fork ships win32 as a first-class runtime, so that
//! constant is a user-visible divergence — the `working-directory` default
//! resolves to `home` for EVERY Windows launch, and typing `ghoztty` in a
//! project directory opens a window somewhere else, while the same keystrokes
//! on macOS and Linux open it where you are standing.
//!
//! Detection is genuinely awkward here, and the awkwardness is why the
//! signals below are three rather than one:
//!
//! - A **GUI-subsystem** binary (what a release `ghoztty.exe` is) never
//!   inherits its caller's console, so `GetConsoleWindow()` is null even when
//!   a human typed its name into PowerShell.
//! - A **console-subsystem** binary (what a Debug `ghoztty.exe` is, and what
//!   `ghoztty.com` always is) is handed a console by Windows no matter who
//!   started it, so merely HAVING one says nothing.
//!
//! What separates the two worlds is whether the console we hold is somebody
//! else's. A console created for us — `CREATE_NEW_CONSOLE`, `CREATE_NO_WINDOW`
//! (what `Start-Process` and the acceptance harness's `CreateProcessW` use), an
//! Explorer double-click — has exactly ONE process attached: us. A console we
//! were launched INTO has at least two: the shell and us.
//!
//! And one path cannot be probed at all, so it is told rather than guessed.
//! PATHEXT resolves a bare `ghoztty` to `ghoztty.com` (T245), whose whole job
//! on a GUI launch is to respawn `ghoztty.exe` DETACHED — no console, and a
//! parent that is already exiting. That is the single most common real launch,
//! so the twin sets `GHOZTTY_CLI_LAUNCH=1` on the child it spawns instead of
//! leaving it to a race. It is the same "one environment variable, no new CLI
//! surface" hand-off `relaunch_guard` uses.
//!
//! The decision itself is pure and lives in `decide`; the syscalls that fill
//! its inputs live in `probeWindows`.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.cli_launch);

/// Set by `ghoztty.com` on the detached `ghoztty.exe` it respawns for a GUI
/// launch. Read once, then removed from our own environment so no pane's
/// shell, and nothing the app spawns, inherits an internal marker.
pub const env_var = "GHOZTTY_CLI_LAUNCH";

/// The observable facts `decide` reasons over. Kept as data so the rule can be
/// asserted without a console, a parent, or a Windows box.
pub const Signals = struct {
    /// `GHOZTTY_CLI_LAUNCH` was set on us by our own CLI twin.
    marked: bool = false,

    /// How many processes are attached to our console. 0 = we have none.
    /// 1 = the console was created FOR us (nobody else is in it). >= 2 = we
    /// were launched into somebody else's console.
    console_procs: usize = 0,

    /// We have no console of our own, but the process that created us owns
    /// one. Only meaningful (and only probed) when `console_procs == 0`.
    parent_owns_console: bool = false,
};

/// True when `s` describes a launch from a command line.
pub fn decide(s: Signals) bool {
    // Our own machinery said so. No heuristic can beat being told.
    if (s.marked) return true;

    // No console: a GUI-subsystem exe. It was typed at a shell iff the thing
    // that started it has a console of its own.
    if (s.console_procs == 0) return s.parent_owns_console;

    // A console with nobody else in it was created for us — a double-click, a
    // `Start-Process`, a `CREATE_NO_WINDOW` spawn. Not a command line.
    return s.console_procs > 1;
}

test "decide: the marker always wins" {
    try std.testing.expect(decide(.{ .marked = true }));
    try std.testing.expect(decide(.{ .marked = true, .console_procs = 1 }));
    try std.testing.expect(decide(.{
        .marked = true,
        .console_procs = 0,
        .parent_owns_console = false,
    }));
}

test "decide: a console we share is a command line" {
    // Launched into a shell's console: the shell and us.
    try std.testing.expect(decide(.{ .console_procs = 2 }));
    // A pane's ConPTY with a shell and a couple of children in it.
    try std.testing.expect(decide(.{ .console_procs = 4 }));
}

test "decide: a console created for us is not" {
    // CREATE_NEW_CONSOLE / CREATE_NO_WINDOW / Explorer double-click of a
    // console-subsystem build: we are the only process in it.
    try std.testing.expect(!decide(.{ .console_procs = 1 }));
    // ...and the parent's console is irrelevant once we have our own, which is
    // what keeps a harness launch (hidden new console, from PowerShell) out.
    try std.testing.expect(!decide(.{
        .console_procs = 1,
        .parent_owns_console = true,
    }));
}

test "decide: no console falls back to the parent" {
    // A release GUI-subsystem exe typed at a shell.
    try std.testing.expect(decide(.{ .parent_owns_console = true }));
    // Explorer double-click, a scheduled task, a service.
    try std.testing.expect(!decide(.{ .parent_owns_console = false }));
}

// -- Windows probe -----------------------------------------------------------

extern "kernel32" fn GetConsoleProcessList(
    lpdwProcessList: [*]std.os.windows.DWORD,
    dwProcessCount: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.DWORD;

extern "kernel32" fn AttachConsole(
    dwProcessId: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn FreeConsole() callconv(.winapi) std.os.windows.BOOL;

const ATTACH_PARENT_PROCESS: std.os.windows.DWORD = 0xFFFFFFFF;

/// Cached because the answer is a property of how we were LAUNCHED and can
/// never change, while its inputs can: the marker is consumed on the first
/// read, and `Config.finalize` runs again on every config reload. Without this
/// a reload would silently flip the `working-directory` default to `home`.
var cached: ?bool = null;

/// The Windows answer for `Config.probableCliEnvironment`. Safe to call
/// repeatedly; only the first call touches the OS.
pub fn probeWindows() bool {
    if (comptime builtin.os.tag != .windows) return false;
    // A unit-test binary has a console and a parent like anything else, and
    // `Config.finalize` runs inside dozens of tests. Answering `false` there
    // keeps the config defaults deterministic and matches what every one of
    // those tests asserted before this existed.
    if (comptime builtin.is_test) return false;
    if (cached) |v| return v;

    const s: Signals = .{
        .marked = takeMarker(),
        .console_procs = consoleProcessCount(),
        .parent_owns_console = parentOwnsConsole(),
    };
    const answer = decide(s);
    log.debug(
        "cli launch probe marked={} console_procs={d} parent_console={} => {}",
        .{ s.marked, s.console_procs, s.parent_owns_console, answer },
    );
    cached = answer;
    return answer;
}

/// Read the marker and immediately clear it from our environment, so the
/// panes we spawn (and the local agent, and anything they start in turn) do
/// not inherit an internal variable that would make THEM read as CLI.
fn takeMarker() bool {
    var buf: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const raw = std.process.getEnvVarOwned(fba.allocator(), env_var) catch |err| switch (err) {
        // A value longer than the buffer is still a value: nobody but us sets
        // this, so anything present at all means "the twin launched us".
        error.OutOfMemory => {
            clearMarker();
            return true;
        },
        else => return false,
    };
    clearMarker();
    return raw.len > 0;
}

fn clearMarker() void {
    _ = std.os.windows.kernel32.SetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral(env_var),
        null,
    );
}

/// Processes attached to our console, or 0 when we have none.
fn consoleProcessCount() usize {
    // The call needs a buffer even when we only want the count: with a buffer
    // too small it returns the REQUIRED size, which is the number we want.
    var pids: [4]std.os.windows.DWORD = undefined;
    return @intCast(GetConsoleProcessList(&pids, pids.len));
}

/// Does the process that created us own a console? There is no way to ask
/// about another process's console without joining it, so this attaches and
/// detaches again immediately. Only called when we have no console of our own,
/// so it can never steal one, and the window in which we are a member of the
/// caller's console (and would receive its Ctrl-C) is microseconds wide with
/// nothing in it.
fn parentOwnsConsole() bool {
    if (consoleProcessCount() != 0) return false;
    if (AttachConsole(ATTACH_PARENT_PROCESS) == 0) return false;
    _ = FreeConsole();
    return true;
}
