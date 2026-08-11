//! T243 — the wrong-drive zig cache guard.
//!
//! On Windows, zig 0.15.2's build runner does not report a diagnostic when the
//! global cache lives on a different drive than the build root — it *panics*:
//!
//! ```
//! thread NNNNN panic: reached unreachable code
//!   std/Build/Step/Run.zig:662  assert(!std.fs.path.isAbsolute(child_cwd_rel));
//! error: unable to read results of configure phase from '.zig-cache\tmp\...'
//! ```
//!
//! `Run.convertPathArg` makes an argument relative to the child's cwd with
//! `std.fs.path.relative`, and across two Windows drives there IS no relative
//! path — `relative` hands back an absolute one, and the assert on the next
//! line fires. A dependency that sets a cwd (uucode's `setCwd(b.path(""))`)
//! is enough to reach it. The repo lives on `D:` here and the default global
//! cache is under `C:\Users\<user>\AppData\Local\zig`, so a shell that has not
//! exported `ZIG_GLOBAL_CACHE_DIR` hits this on its first real build.
//!
//! The cost of that shape is not the failure, it is the *misattribution*: a
//! stack trace with no `error:` line naming anything in this repo reads as a
//! transient, earns a verbatim retry, and panics identically. It has been paid
//! at least four times in separate turns (T242, T257/T262, T225). A diagnostic
//! that fires at the moment of the panic cannot be missed the way a note in a
//! doc can — this module is the decision behind that diagnostic, kept pure so
//! it is asserted in the test lane rather than only in a build that happens to
//! be run on a two-drive box.
//!
//! Deliberately advisory about ONE thing only: it names the variable to export
//! and refuses the build. It never *sets* the cache location itself — silently
//! relocating a user's global cache from inside `build.zig` is a surprise, and
//! a surprise is what this whole module exists to remove.

const std = @import("std");

/// A build root and a global cache root that sit on different Windows drives.
/// Both letters are uppercased, so `d:\repo` and `D:\repo` are one drive.
pub const Mismatch = struct {
    /// Drive letter of the build root (the repo).
    build_root: u8,
    /// Drive letter of the resolved global cache directory.
    cache_root: u8,
};

/// The uppercased drive letter a Windows path begins with, or null when the
/// path does not name one: a POSIX path, a UNC share (`\\server\share`), a
/// drive-relative or root-relative path, or an empty one.
///
/// A `\\?\` verbatim prefix is stripped first, because that is the shape a
/// path resolved through `realpath` can arrive in, and `\\?\D:\git\ghoztty`
/// names drive D as surely as `D:\git\ghoztty` does. `\\?\UNC\...` keeps its
/// UNC answer of "no drive".
///
/// Null is always the *quiet* answer — every caller here treats "cannot tell"
/// as "no mismatch", because a guard that guesses is worse than no guard.
pub fn driveLetter(raw: []const u8) ?u8 {
    const verbatim = "\\\\?\\";
    const path = if (std.mem.startsWith(u8, raw, verbatim)) raw[verbatim.len..] else raw;
    if (path.len < 2) return null;
    if (path[1] != ':') return null;
    const c = path[0];
    return switch (c) {
        'a'...'z' => c - ('a' - 'A'),
        'A'...'Z' => c,
        else => null,
    };
}

/// Whether the two roots are on drives that cannot be made relative to each
/// other. Null means "no problem I can prove" — same drive, or a path whose
/// drive is unknowable (which includes every POSIX host, so this is inherently
/// a no-op on the Mac seat and on Linux rather than something gated off).
pub fn check(build_root: ?[]const u8, cache_root: ?[]const u8) ?Mismatch {
    const build_drive = driveLetter(build_root orelse return null) orelse return null;
    const cache_drive = driveLetter(cache_root orelse return null) orelse return null;
    if (build_drive == cache_drive) return null;
    return .{ .build_root = build_drive, .cache_root = cache_drive };
}

/// The value to export, written into `buf` — the cache directory this guard
/// tells the user to use, on the build root's own drive. Naming a concrete
/// path is the point: "put it on the same drive" is a diagnosis, and what a
/// stuck shell needs is a line it can paste.
pub fn suggestedCacheDir(buf: []u8, build_root_drive: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{c}:\\zig-global-cache", .{build_root_drive}) catch
        // The format is 20 bytes for any single letter; a caller who passes a
        // smaller buffer gets the diagnosis without the paste-able line rather
        // than a failed build on top of a failed build.
        "";
}

test "driveLetter reads and uppercases a leading Windows drive" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u8, 'D'), driveLetter("D:\\git\\ghoztty"));
    try testing.expectEqual(@as(?u8, 'D'), driveLetter("d:\\git\\ghoztty"));
    try testing.expectEqual(@as(?u8, 'C'), driveLetter("C:/Users/David"));
    try testing.expectEqual(@as(?u8, 'C'), driveLetter("C:"));
}

test "driveLetter sees through a verbatim prefix but not through UNC" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u8, 'D'), driveLetter("\\\\?\\D:\\git\\ghoztty"));
    try testing.expectEqual(@as(?u8, 'D'), driveLetter("\\\\?\\d:\\git\\ghoztty"));
    try testing.expectEqual(@as(?u8, null), driveLetter("\\\\?\\UNC\\homeassistant\\share"));
    try testing.expectEqual(@as(?u8, null), driveLetter("\\\\?\\"));
}

test "driveLetter is quiet about paths that name no drive" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u8, null), driveLetter(""));
    try testing.expectEqual(@as(?u8, null), driveLetter("D"));
    try testing.expectEqual(@as(?u8, null), driveLetter("/home/david/git/ghoztty"));
    try testing.expectEqual(@as(?u8, null), driveLetter("\\\\homeassistant\\share\\ghoztty"));
    try testing.expectEqual(@as(?u8, null), driveLetter("src/build"));
    try testing.expectEqual(@as(?u8, null), driveLetter("\\zig-global-cache"));
    // A digit in the drive position is not a drive.
    try testing.expectEqual(@as(?u8, null), driveLetter("1:\\nope"));
}

test "check reports a cross-drive cache" {
    const testing = std.testing;
    const m = check("D:\\git\\ghoztty", "C:\\Users\\David\\AppData\\Local\\zig").?;
    try testing.expectEqual(@as(u8, 'D'), m.build_root);
    try testing.expectEqual(@as(u8, 'C'), m.cache_root);
}

test "check is silent when the drives match, whatever their case" {
    const testing = std.testing;
    try testing.expectEqual(
        @as(?Mismatch, null),
        check("D:\\git\\ghoztty", "D:\\zig-global-cache"),
    );
    try testing.expectEqual(
        @as(?Mismatch, null),
        check("d:\\git\\ghoztty", "D:\\zig-global-cache"),
    );
}

test "check is silent when either drive is unknowable" {
    const testing = std.testing;
    // The POSIX seats: no drive letters anywhere, so no build can be refused.
    try testing.expectEqual(
        @as(?Mismatch, null),
        check("/Users/david/git/ghoztty", "/Users/david/.cache/zig"),
    );
    // A UNC build root has no drive to compare against.
    try testing.expectEqual(
        @as(?Mismatch, null),
        check("\\\\homeassistant\\share\\ghoztty", "C:\\Users\\David\\AppData\\Local\\zig"),
    );
    // A cache root on a UNC share is likewise unprovable, not a mismatch.
    try testing.expectEqual(
        @as(?Mismatch, null),
        check("D:\\git\\ghoztty", "\\\\nas\\zig-cache"),
    );
    // Zig reports a directory with no path when it is the cwd handle only.
    try testing.expectEqual(@as(?Mismatch, null), check(null, "C:\\zig"));
    try testing.expectEqual(@as(?Mismatch, null), check("D:\\git\\ghoztty", null));
}

test "suggestedCacheDir names a path on the build root's drive" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("D:\\zig-global-cache", suggestedCacheDir(&buf, 'D'));
    try testing.expectEqualStrings("E:\\zig-global-cache", suggestedCacheDir(&buf, 'E'));
}

test "suggestedCacheDir degrades to empty rather than failing the caller" {
    const testing = std.testing;
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("", suggestedCacheDir(&small, 'D'));
}
