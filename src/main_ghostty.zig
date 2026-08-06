//! The main entrypoint for the `ghoztty` application. This also serves
//! as the process initialization code for the `libghostty` library.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const build_config = @import("build_config.zig");
// The macos module is only present in the build graph on Darwin targets;
// the logging block below comptime-breaks before touching it elsewhere.
const macos = if (builtin.target.os.tag.isDarwin()) @import("macos") else undefined;
const cli = @import("cli.zig");
const renderer = @import("renderer.zig");
const apprt = @import("apprt.zig");

const App = @import("App.zig");
const Ghostty = @import("main_c.zig").Ghostty;
const state = &@import("global.zig").state;

/// The return type for main() depends on the build artifact. The lib build
/// also calls "main" in order to run the CLI actions, but it calls it as
/// an API and not an entrypoint.
const MainReturn = switch (build_config.artifact) {
    .lib => noreturn,
    else => void,
};

pub fn main() !MainReturn {
    // We first start by initializing our global state. This will setup
    // process-level state we need to run the terminal. The reason we use
    // a global is because the C API needs to be able to access this state;
    // no other Zig code should EVER access the global state.
    state.init() catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buffer);
        const stderr = &stderr_writer.interface;
        defer posix.exit(1);
        const ErrSet = @TypeOf(err) || error{Unknown};
        switch (@as(ErrSet, @errorCast(err))) {
            error.MultipleActions => try stderr.print(
                "Error: multiple CLI actions specified. You must specify only one\n" ++
                    "action starting with the `+` character.\n",
                .{},
            ),

            error.InvalidAction => try stderr.print(
                "Error: unknown CLI action specified. CLI actions are specified with\n" ++
                    "the '+' character.\n\n" ++
                    "All valid CLI actions can be listed with `ghoztty +help`\n",
                .{},
            ),

            else => try stderr.print("invalid CLI invocation err={}\n", .{err}),
        }
        try stderr.flush();
    };
    defer state.deinit();
    const alloc = state.alloc;

    // T421: this process may be a relaunch guard rather than a terminal — a
    // detached watcher armed by the app for the seconds it spends restarting
    // the local agent. Asked FIRST, before any window, IPC endpoint or
    // single-instance guard exists, because a guard must never look like a
    // second instance of the app it is watching.
    //
    // Gated on there being no `+action`: the app sets the variable on ITSELF for
    // the instant it takes to spawn the guard (that is how the child inherits
    // it), so a pane started in exactly that window would carry it too — and a
    // `ghoztty +list` from that pane must stay a `+list`, not become a watcher.
    if (@hasDecl(apprt.App, "runRelaunchGuard") and state.action == null) {
        if (apprt.App.runRelaunchGuard(alloc)) |code| {
            posix.exit(code);
            return;
        }
    }

    // T245: this process may be `ghoztty.com`, the console-subsystem twin of
    // ghoztty.exe that exists so PowerShell waits for (and wires redirection
    // to) CLI verbs. A GUI launch through the twin respawns the sibling
    // ghoztty.exe detached and exits — the caller's shell is waiting on a
    // console-subsystem child, and it must never block on the terminal it
    // just launched. CLI actions fall through: they run right here, in the
    // console process, which is the whole point of the twin.
    if (@hasDecl(apprt.App, "runComShimGuiRespawn") and state.action == null) {
        if (apprt.App.runComShimGuiRespawn(alloc)) {
            posix.exit(0);
            return;
        }
    }

    if (comptime builtin.mode == .Debug) {
        std.log.warn("This is a debug build. Performance will be very poor.", .{});
        std.log.warn("You should only use a debug build for developing Ghostty.", .{});
        std.log.warn("Otherwise, please rebuild in a release mode.", .{});
    }

    // Execute our action if we have one
    if (state.action) |action| {
        std.log.info("executing CLI action={}", .{action});
        const exit_code = action.run(alloc) catch |err| err: {
            std.log.err("CLI action failed error={}", .{err});
            break :err 1;
        };
        if (exit_code == 200) {
            state.action = null;
            state.skip_cli_args = true;
            std.log.info("no running instance, becoming master process", .{});
        } else {
            posix.exit(exit_code);
            return;
        }
    }

    if (comptime build_config.app_runtime == .none) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Usage: ghoztty +<action> [flags]\n\n", .{});
        try stdout.print(
            \\This is the Ghoztty helper CLI that accompanies the graphical Ghoztty app.
            \\To launch the terminal directly, please launch the graphical app
            \\(i.e. Ghoztty.app on macOS). This CLI can be used to perform various
            \\actions such as inspecting the version, listing fonts, etc.
            \\
            \\On macOS, the terminal can also be launched using `open -na Ghoztty.app`,
            \\or `open -na Ghoztty.app --args --foo=bar --baz=qux` to pass arguments.
            \\
            \\We don't have proper help output yet, sorry! Please refer to the
            \\source code or Discord community for help for now. We'll fix this in time.
            \\
        ,
            .{},
        );

        posix.exit(0);
    }

    // Create our app state
    const app: *App = try App.create(alloc);
    defer app.destroy();

    // Create our runtime app
    var app_runtime: apprt.App = undefined;
    try app_runtime.init(app, .{});
    defer app_runtime.terminate();

    // Since - by definition - there are no surfaces when first started, the
    // quit timer may need to be started. The start timer will get cancelled if/
    // when the first surface is created.
    if (@hasDecl(apprt.App, "startQuitTimer")) app_runtime.startQuitTimer();

    // Run the GUI event loop
    try app_runtime.run();
}

/// Open `name` in `dir` for ATOMIC APPEND, creating it if absent (Windows).
///
/// `ghoztty.log` is a SHARED sink: the GUI app, the agent and every one-shot
/// `ghoztty +…` CLI invocation append to the same file concurrently, and on this
/// box there are often several a second. `createFile` + `seekFromEnd(0)` +
/// `write` is not an append — two writers that both resolve end-of-file to N
/// both write AT N, and the later one silently overwrites the earlier one's
/// line. That is not theoretical: it is why T229's primary evidence ("the app
/// logged nothing after the confirm") could not be trusted, and it would defeat
/// every diagnostic line added for it.
///
/// `FILE_APPEND_DATA` *without* `FILE_WRITE_DATA` is the fix Windows documents:
/// the file pointer is ignored and each write is placed at the current end of
/// file as one operation, so concurrent writers interleave whole lines instead
/// of clobbering bytes.
fn openAppendW(dir: std.fs.Dir, name_w: []const u16) !std.fs.File {
    const w = std.os.windows;
    return .{ .handle = try w.OpenFile(name_w, .{
        .dir = dir.fd,
        .access_mask = w.SYNCHRONIZE | w.FILE_APPEND_DATA,
        .creation = w.FILE_OPEN_IF,
    }) };
}

// The function std.log will call.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // On Mac, we use unified logging. To view this:
    //
    //   sudo log stream --level debug --predicate 'subsystem=="com.dzearing.ghoztty"'
    //
    // macOS logging is thread safe so no need for locks/mutexes
    macos: {
        if (comptime !builtin.target.os.tag.isDarwin()) break :macos;
        if (!state.logging.macos) break :macos;

        const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";

        // Convert our levels to Mac levels
        const mac_level: macos.os.LogType = switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .err,
            .err => .fault,
        };

        // Initialize a logger. This is slow to do on every operation
        // but we shouldn't be logging too much.
        const logger = macos.os.Log.create(build_config.bundle_id, @tagName(scope));
        defer logger.release();
        logger.log(std.heap.c_allocator, mac_level, prefix ++ format, args);
    }

    // On Windows release builds the exe uses the GUI subsystem, so stderr
    // goes nowhere. Append to %LOCALAPPDATA%\ghoztty\ghoztty.log instead so
    // beta crashes/failures are diagnosable. (Debug builds use the Console
    // subsystem and log to stderr like every other platform.)
    windows_file: {
        if (comptime !(builtin.os.tag == .windows and builtin.mode != .Debug)) break :windows_file;
        if (level == .debug) break :windows_file;

        const localappdata_w = std.process.getenvW(
            std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"),
        ) orelse break :windows_file;

        var base_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.unicode.wtf16LeToWtf8(&base_buf, localappdata_w);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = std.fmt.bufPrint(
            &path_buf,
            "{s}\\ghoztty",
            .{base_buf[0..n]},
        ) catch break :windows_file;

        var dir = std.fs.cwd().makeOpenPath(dir_path, .{}) catch break :windows_file;
        defer dir.close();
        const file = openAppendW(dir, std.unicode.utf8ToUtf16LeStringLiteral("ghoztty.log")) catch
            break :windows_file;
        defer file.close();

        var msg_buf: [2048]u8 = undefined;
        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        const msg = std.fmt.bufPrint(
            &msg_buf,
            level_txt ++ prefix ++ format ++ "\n",
            args,
        ) catch break :windows_file;
        _ = file.write(msg) catch {};
    }

    stderr: {
        // don't log debug messages to stderr unless we are a debug build
        if (comptime builtin.mode != .Debug and level == .debug) break :stderr;

        // skip if we are not logging to stderr
        if (!state.logging.stderr) break :stderr;

        // Lock so we are thread-safe
        var buf: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buf);
        defer std.debug.unlockStderrWriter();

        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        nosuspend stderr.print(level_txt ++ prefix ++ format ++ "\n", args) catch break :stderr;
        nosuspend stderr.flush() catch break :stderr;
    }
}

pub const std_options: std.Options = .{
    // Our log level is always at least info in every build mode.
    //
    // Note, we don't lower this to debug even with conditional logging
    // via GHOSTTY_LOG because our debug logs are very expensive to
    // calculate and we want to make sure they're optimized out in
    // builds.
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },

    .logFn = logFn,
};

test {
    _ = @import("pty.zig");
    _ = @import("Command.zig");
    _ = @import("CommandCore.zig");
    _ = @import("font/main.zig");
    _ = @import("apprt.zig");
    _ = @import("renderer.zig");
    _ = @import("termio.zig");
    _ = @import("input.zig");
    _ = @import("cli.zig");
    _ = @import("surface_mouse.zig");

    // Libraries
    _ = @import("tripwire.zig");
    _ = @import("benchmark/main.zig");
    _ = @import("crash/main.zig");
    _ = @import("datastruct/main.zig");
    _ = @import("inspector/main.zig");
    _ = @import("lib/main.zig");
    _ = @import("terminal/main.zig");
    _ = @import("terminfo/main.zig");
    _ = @import("simd/main.zig");
    _ = @import("synthetic/main.zig");
    _ = @import("unicode/main.zig");
    _ = @import("unicode/props_uucode.zig");
    _ = @import("unicode/symbols_uucode.zig");

    // Extra
    _ = @import("extra/bash.zig");
    _ = @import("extra/fish.zig");
    _ = @import("extra/sublime.zig");
    _ = @import("extra/vim.zig");
    _ = @import("extra/zsh.zig");

    // Relay client account (T21a/T93/T141): pure OAuth/PKCE logic, the brokered
    // session-client parse layer, the DPAPI account-store round-trip, and the
    // sign-in/sign-out flow the win32 chooser drives. Reached only through the
    // win32 apprt otherwise, so pull them in explicitly to run their unit tests
    // in BOTH the `none` and `win32` lanes.
    _ = @import("remote/google_oauth.zig");
    _ = @import("remote/relay_account.zig");
    _ = @import("remote/relay_directory.zig");
    _ = @import("remote/relay_session.zig");
    _ = @import("remote/relay_signin.zig");

    // Socket Reader/Writer with panic-free close-race error mappings (T81):
    // the ws transport teardown depends on these staying error-returning.
    _ = @import("remote/socket_rw.zig");
}
