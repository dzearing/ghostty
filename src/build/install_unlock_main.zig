//! Build-time host tool (T192): clear the way for an install whose
//! DESTINATION is held open by a running process.
//!
//! Usage: install-unlock <source> <destination> [<source> <destination>...]
//!
//! Windows holds an executable's image file open for the life of the process,
//! and `ghoztty-agent.exe` outliving the app is the whole point of session
//! persistence — so a `zig build` on a box where an earlier test run left a
//! repo-lineage agent alive died with
//!
//!     error: unable to update file from '.zig-cache\o\<hash>\ghoztty-agent.exe'
//!            to 'zig-out\bin\ghoztty-agent.exe': AccessDenied
//!
//! The trap is not the failure, it is its SHAPE: `ghoztty.exe` had already
//! installed by then, so the build reported exit 1 over a binary that really
//! had changed, and a session that trusts the exit code concludes "my change
//! did not build" — or writes off a real test result as a stale-binary
//! artifact.
//!
//! The fix is the one every Windows updater uses: a running image cannot be
//! written or deleted, but it CAN be renamed. So the destination is moved
//! aside to `<name>.old-<n>` and the install's own atomic rename then lands on
//! an empty path. The moved-aside file is deleted by a later build, once the
//! process holding it has exited.
//!
//! Deliberately NOT "kill whatever is running": a build that terminates
//! processes would take a concurrently-running acceptance suite's agent — and
//! its live sessions — with it. Renaming costs a stale file for a few minutes;
//! killing costs someone else's work.
//!
//! Nothing here ever fails the build. When the move cannot be made, the tool
//! says which artifact is stuck and why, and lets the install step report its
//! own error — which is strictly more than the build used to say.
//!
//! `GHOZTTY_INSTALL_UNLOCK=0` turns the guard off, which is how the acceptance
//! script reproduces the original failure from this same tree.

const std = @import("std");
const builtin = @import("builtin");

/// Suffix given to a destination that had to be moved out of the way. The
/// trailing number keeps a second build from colliding with the first one's
/// leftovers while the same process is still running.
const aside_suffix = ".old-";

/// How many `.old-<n>` names to try, and the cap on how many leftovers one
/// sweep will remove. A box that reaches either is not in a state a build
/// step should be papering over.
const max_aside = 64;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test seam: turn the guard off and the build reproduces the pre-T192
    // AccessDenied exactly, from the same tree. A failure mode nobody can
    // reproduce on demand is one nobody notices coming back.
    if (std.process.getEnvVarOwned(alloc, "GHOZTTY_INSTALL_UNLOCK")) |v| {
        if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "off")) {
            std.log.warn("GHOZTTY_INSTALL_UNLOCK={s}: leaving locked destinations alone", .{v});
            return;
        }
    } else |_| {}

    const args = try std.process.argsAlloc(alloc);
    if (args.len < 3 or (args.len - 1) % 2 != 0) {
        std.log.err(
            "usage: install-unlock <source> <destination> [<source> <destination>...]",
            .{},
        );
        return error.BadUsage;
    }

    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) unlock(alloc, args[i], args[i + 1]);
}

/// Best-effort: make `dest` installable over. Never returns an error — the
/// install step downstream is the one allowed to fail the build.
fn unlock(alloc: std.mem.Allocator, src: []const u8, dest: []const u8) void {
    const cwd = std.fs.cwd();

    // Sweep first, so this run's own move-aside is never eaten by it.
    sweep(alloc, dest);

    // Nothing installed there yet ⇒ nothing is in anyone's way.
    const dest_stat = statPath(cwd, dest) orelse return;

    // `std.fs.Dir.updateFile` — what the install step calls — skips the copy
    // when size and mtime already match, so a lock on an ALREADY-CURRENT file
    // never blocks anything and must not cost a rename every build.
    if (statPath(cwd, src)) |src_stat| {
        if (src_stat.size == dest_stat.size and
            src_stat.mtime == dest_stat.mtime) return;
    }

    // If we can open it for writing, so can the install.
    if (cwd.openFile(dest, .{ .mode = .write_only })) |f| {
        f.close();
        return;
    } else |_| {}

    const aside = freeAsideName(alloc, cwd, dest) orelse {
        warnStuck(dest);
        return;
    };
    moveAside(dest, aside) catch {
        warnStuck(dest);
        return;
    };
    std.log.warn(
        "'{s}' is held open by a running process; moved it aside as '{s}' so the new one could be installed. " ++
            "A later build deletes it once that process exits.",
        .{ std.fs.path.basename(dest), std.fs.path.basename(aside) },
    );
}

/// Rename `dest` to `aside`.
///
/// On Windows this must NOT go through `std.fs.Dir.rename`, which opens the
/// source with `GENERIC_WRITE | DELETE` — a running image denies write sharing,
/// so that call returns AccessDenied on exactly the file this tool exists for.
/// `MoveFileExW` asks only for DELETE, which the loader's share mode
/// (`FILE_SHARE_READ | FILE_SHARE_DELETE`) permits. That difference is the
/// whole reason renaming a running executable works at all, and it is what
/// every Windows updater relies on.
fn moveAside(dest: []const u8, aside: []const u8) !void {
    if (builtin.os.tag == .windows) {
        // No REPLACE_EXISTING: `freeAsideName` already picked a free name, and
        // replacing would mean deleting whatever is there — possibly another
        // still-running leftover.
        return std.os.windows.MoveFileEx(dest, aside, 0);
    }
    return std.fs.cwd().rename(dest, aside);
}

fn warnStuck(dest: []const u8) void {
    std.log.warn(
        "'{s}' is held open by a running process and could not be moved aside, so installing it is about to fail with AccessDenied. " ++
            "Stop the process running from that exact path and build again.",
        .{dest},
    );
}

fn statPath(dir: std.fs.Dir, path: []const u8) ?std.fs.File.Stat {
    const f = dir.openFile(path, .{}) catch return null;
    defer f.close();
    return f.stat() catch null;
}

/// The first `<dest>.old-<n>` that does not already exist.
fn freeAsideName(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    dest: []const u8,
) ?[]const u8 {
    var n: u32 = 1;
    while (n <= max_aside) : (n += 1) {
        const candidate = std.fmt.allocPrint(
            alloc,
            "{s}{s}{d}",
            .{ dest, aside_suffix, n },
        ) catch return null;
        dir.access(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => return candidate,
            else => continue,
        };
    }
    return null;
}

/// Delete leftover `<dest>.old-*` siblings. One that is still held open
/// simply survives to the next build; that is not an error.
fn sweep(alloc: std.mem.Allocator, dest: []const u8) void {
    const dir_path = std.fs.path.dirname(dest) orelse return;
    const prefix = std.fmt.allocPrint(
        alloc,
        "{s}{s}",
        .{ std.fs.path.basename(dest), aside_suffix },
    ) catch return;

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    // Collect before deleting: mutating a directory mid-iteration is not
    // something either platform's readdir promises to survive.
    var names: [max_aside][]const u8 = undefined;
    var count: usize = 0;
    var it = dir.iterate();
    while (count < names.len) {
        const entry = (it.next() catch break) orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        names[count] = alloc.dupe(u8, entry.name) catch break;
        count += 1;
    }

    for (names[0..count]) |name| dir.deleteFile(name) catch continue;
}
