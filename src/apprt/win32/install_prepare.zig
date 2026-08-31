//! Clear the way for an INSTALLER, so the sessions the install is supposed to
//! preserve survive it (T1207).
//!
//! The problem, in one sentence: `ghoztty-agent.exe` and its per-session
//! `--pty-host` holders own the user's live shells, they have no windows, and
//! the Restart Manager's only move on a windowless process is to TERMINATE it.
//! So a double-clicked MSI over a running Ghoztty would take every restored
//! session with it — the exact thing session persistence exists to prevent.
//!
//! Why T1204 does not already cover it: the app registers for restart and
//! exits politely when asked, which is what makes the app's own file
//! replaceable without a reboot. That mechanism is only offered to processes
//! with a top-level window. `RmShutdown` reaches the agent and the holders with
//! `RmForceShutdown` and nothing else, and there is no handler to register that
//! changes that.
//!
//! Why the in-app updater does not already cover it: `update_install.zig`
//! sidelines the agent image itself before it runs msiexec (`clearInstallDir`),
//! so the holders keep running out of the file they already opened. A
//! double-clicked MSI never goes through that code — msiexec is the parent
//! there, not us.
//!
//! The fix is to give the package the same move the updater makes, at the one
//! moment it still helps: an immediate custom action, scheduled BEFORE
//! `InstallValidate`, which is where Windows Installer asks the Restart Manager
//! which processes are holding the files it is about to write. Renaming the
//! agent's image out of the way first means the holders are holding
//! `ghoztty-agent.exe.old-<stamp>`, the package's own `ghoztty-agent.exe` is
//! unheld, and there is nothing for the Restart Manager to shut down. The
//! holders keep the old code until they are next restarted, which is precisely
//! the situation the app↔agent HELLO handshake already exists to handle.
//!
//! Deliberately NOT here:
//!
//! - **`ghoztty.exe` is never sidelined.** It is the one image the Restart
//!   Manager CAN close gracefully, and T1204 made it do so. Renaming it aside
//!   would take that away — the Restart Manager records the running process's
//!   image path when it decides to restart it — and trade a blink for a
//!   terminal that does not come back.
//! - **Nothing is killed.** A prepare step that terminated the agent would be
//!   the defect with better manners.
//! - **Nothing can fail the install.** Every path here returns 0. The worst
//!   outcome of a failure is the behaviour we had before this existed, and an
//!   installer that refuses to run because its optional politeness step broke
//!   is strictly worse than one that asks for a reboot.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const update_apply = @import("update_apply.zig");

const log = std.log.scoped(.win32_install_prepare);

/// The argv flag that turns a `ghoztty.exe` start into a prepare step. An
/// argument rather than an environment variable (which is how the update
/// applier and the relaunch guard are told what they are) because the caller
/// is msiexec: a Windows Installer custom action controls its child's command
/// line and cannot control its environment.
///
/// Deliberately NOT a `+verb`: `src/cli/ghostty.zig`'s action enum is the
/// user-facing CLI surface and is shared by every apprt, so a verb added for
/// one platform's installer becomes a cross-platform CLI divergence (the T141
/// lesson, recorded in that enum). This is plumbing between our package and our
/// exe, and it is spelled like plumbing.
pub const flag = "--install-prepare";

/// Optional `--install-dir=<path>`: which directory to prepare. Defaults to the
/// directory the running exe lives in, which is what the custom action wants
/// (`[INSTALLDIR]ghoztty.exe --install-prepare`) and what a hand-run invocation
/// means. The flag exists so an acceptance script can point the same code at a
/// throwaway directory instead of a real install.
pub const dir_flag = "--install-dir=";

/// The images this step renames aside, and nothing else.
///
/// One entry, and the single entry is the point. `ghoztty-agent.exe` is the
/// image every windowless long-lived process of ours runs from — the session
/// agent and every `--pty-host` holder — so one rename covers all of them.
/// `ghoztty.exe` is excluded on purpose (see the module header); `ghoztty.com`
/// is a console shim that nothing holds open past a command.
pub const sideline_images = [_][]const u8{"ghoztty-agent.exe"};

/// How many sidelined leftovers one run will delete. A directory with more
/// than this is not in a state an installer step should be papering over, and
/// the cap keeps a pathological directory from turning a custom action into a
/// long one.
const max_sweep = 64;

/// What a command line asked for, or null when it did not ask for this at all.
pub const Request = struct {
    /// The directory to prepare, or null for "the one this exe lives in".
    dir: ?[]const u8,
};

/// Parse a command line. Pure, so the lane checks it: this is the function
/// that decides whether a normal `ghoztty.exe` start is quietly turned into a
/// non-terminal, and getting that wrong in either direction is a bad day.
///
/// `args` is the FULL argv including argv[0], the way the process sees it.
pub fn parse(args: []const []const u8) ?Request {
    var found = false;
    var dir: ?[]const u8 = null;
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, flag)) {
            found = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, dir_flag)) {
            const value = arg[dir_flag.len..];
            if (value.len > 0) dir = value;
            continue;
        }
    }
    if (!found) return null;
    return .{ .dir = dir };
}

/// Was this process started as an installer prepare step? If so, do it and
/// hand `main` an exit code — a prepare step never becomes a terminal.
pub fn runFromArgs(alloc: Allocator) ?u8 {
    if (comptime builtin.os.tag != .windows) return null;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = std.process.argsAlloc(arena) catch return null;
    const req = parse(args) orelse return null;

    const dir = req.dir orelse blk: {
        const self_path = std.fs.selfExePathAlloc(arena) catch |err| {
            log.err("install prepare: cannot resolve own path ({}); nothing prepared", .{err});
            return 0;
        };
        break :blk std.fs.path.dirname(self_path) orelse {
            log.err("install prepare: own path has no directory; nothing prepared", .{});
            return 0;
        };
    };

    prepare(arena, dir);
    return 0;
}

/// Rename every in-use image an installer is about to replace out of its way,
/// then delete what earlier runs left behind. Never fails: see the header.
pub fn prepare(arena: Allocator, dir: []const u8) void {
    const stamp: u64 = @intCast(@max(0, std.time.timestamp()));
    for (sideline_images) |name| {
        const path = std.fmt.allocPrint(arena, "{s}\\{s}", .{ dir, name }) catch continue;
        if (!isLocked(path)) continue;
        var side_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const side = update_apply.sidelineName(&side_buf, path, stamp) catch continue;
        if (std.fs.renameAbsolute(path, side)) |_| {
            log.warn(
                "install prepare: {s} is in use; renamed it aside so the installer can write a fresh one",
                .{name},
            );
        } else |err| {
            log.err(
                "install prepare: {s} is in use and could not be renamed ({}); the install may need a reboot",
                .{ name, err },
            );
        }
    }
    sweep(arena, dir);
}

/// Delete the sidelined leftovers of earlier installs, once nothing is running
/// out of them any more. Best-effort by construction: a leftover that is still
/// held open is simply left for the next install to try again.
fn sweep(arena: Allocator, dir: []const u8) void {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return;
    defer d.close();
    var it = d.iterate();
    var removed: usize = 0;
    while (it.next() catch null) |entry| {
        if (removed >= max_sweep) break;
        if (entry.kind != .file) continue;
        if (!update_apply.isSidelined(entry.name)) continue;
        const path = std.fmt.allocPrint(arena, "{s}\\{s}", .{ dir, entry.name }) catch continue;
        if (isLocked(path)) continue;
        std.fs.deleteFileAbsolute(path) catch continue;
        removed += 1;
    }
}

/// True if the file cannot be opened for writing — which, for a file in an
/// install directory, means a process is running that image. A file that does
/// not exist is not locked; the installer will simply create it.
///
/// The same test `update_install.zig` makes, for the same reason, and it is
/// duplicated rather than shared because that one is private to the applier's
/// choreography and this one runs with no app in the picture at all.
fn isLocked(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    f.close();
    return false;
}

test "parse: absent flag is not a prepare step" {
    const testing = std.testing;
    try testing.expect(parse(&.{"ghoztty.exe"}) == null);
    try testing.expect(parse(&.{ "ghoztty.exe", "--install-dir=C:\\x" }) == null);
    try testing.expect(parse(&.{ "ghoztty.exe", "+new-window" }) == null);
    // argv[0] is never inspected: an exe that happens to be NAMED like the
    // flag does not become a prepare step.
    try testing.expect(parse(&.{"--install-prepare"}) == null);
    try testing.expect(parse(&.{}) == null);
}

test "parse: flag alone means the exe's own directory" {
    const testing = std.testing;
    const req = parse(&.{ "ghoztty.exe", flag }) orelse return error.TestExpectedRequest;
    try testing.expect(req.dir == null);
}

test "parse: an explicit directory is carried through" {
    const testing = std.testing;
    const req = parse(&.{ "ghoztty.exe", flag, "--install-dir=D:\\tmp\\fake install" }) orelse
        return error.TestExpectedRequest;
    try testing.expectEqualStrings("D:\\tmp\\fake install", req.dir.?);

    // Order does not matter — msiexec's ExeCommand is a string we control, but
    // a hand-run invocation is not.
    const flipped = parse(&.{ "ghoztty.exe", "--install-dir=D:\\a", flag }) orelse
        return error.TestExpectedRequest;
    try testing.expectEqualStrings("D:\\a", flipped.dir.?);
}

test "parse: an empty directory value falls back to the exe's own" {
    const testing = std.testing;
    const req = parse(&.{ "ghoztty.exe", flag, "--install-dir=" }) orelse
        return error.TestExpectedRequest;
    try testing.expect(req.dir == null);
}

test "sideline_images: the agent, and never the app" {
    const testing = std.testing;
    var saw_agent = false;
    for (sideline_images) |name| {
        // ghoztty.exe is the Restart Manager's to close gracefully (T1204).
        // Sidelining it would break the restart it is registered for.
        try testing.expect(!std.mem.eql(u8, name, "ghoztty.exe"));
        if (std.mem.eql(u8, name, "ghoztty-agent.exe")) saw_agent = true;
    }
    try testing.expect(saw_agent);
}
