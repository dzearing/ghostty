//! Build provenance of the running instance (T52): which executable is
//! this process, built from what commit, in which mode. One collection
//! point shared by the IPC `version` verb, the `+list --json` build
//! metadata, and the command-palette About box, so every surface answers
//! "which build is this window running?" identically.
const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const build_config = @import("../../build_config.zig");

/// Comptime provenance: baked into the binary by build.zig/GitVersion.
pub const version: []const u8 = build_config.version_string;
pub const commit: []const u8 = build_config.version.build orelse "unknown";
pub const mode: []const u8 = mode: {
    // mode_string is ".Debug"/".ReleaseFast"; drop the leading dot.
    const m = build_config.mode_string;
    break :mode if (m.len > 0 and m[0] == '.') m[1..] else m;
};
pub const runtime: []const u8 = @tagName(build_config.app_runtime);

pub const Provenance = struct {
    version: []const u8 = version,
    commit: []const u8 = commit,
    mode: []const u8 = mode,
    runtime: []const u8 = runtime,
    /// Absolute path of the running executable.
    exe: []const u8,
    /// Last-write time of the executable ("YYYY-MM-DD HH:MM:SS UTC") —
    /// the runtime stand-in for a build/install date. "unknown" if the
    /// exe cannot be statted.
    exe_modified: []const u8,
    pid: u32,
};

/// Collect runtime provenance. All strings are allocated from `alloc`
/// (arena-friendly; nothing needs individual freeing).
pub fn collect(alloc: Allocator) Allocator.Error!Provenance {
    const exe: []const u8 = std.fs.selfExePathAlloc(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try alloc.dupe(u8, "unknown"),
    };
    const modified: []const u8 = modified: {
        const f = std.fs.openFileAbsolute(exe, .{}) catch
            break :modified try alloc.dupe(u8, "unknown");
        defer f.close();
        const st = f.stat() catch break :modified try alloc.dupe(u8, "unknown");
        break :modified try formatUtc(alloc, st.mtime);
    };
    return .{
        .exe = exe,
        .exe_modified = modified,
        .pid = windows.GetCurrentProcessId(),
    };
}

/// Format nanoseconds-since-epoch as "YYYY-MM-DD HH:MM:SS UTC".
fn formatUtc(alloc: Allocator, ns: i128) Allocator.Error![]const u8 {
    const secs = @divFloor(ns, std.time.ns_per_s);
    if (secs < 0 or secs > std.math.maxInt(u64)) return try alloc.dupe(u8, "unknown");
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    return std.fmt.allocPrint(
        alloc,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        },
    );
}

test "formatUtc: known instant" {
    const testing = std.testing;
    // 2026-07-17 09:31:40 UTC == 1784280700 seconds since epoch.
    const s = try formatUtc(testing.allocator, 1_784_280_700 * std.time.ns_per_s);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("2026-07-17 09:31:40 UTC", s);
}

test "formatUtc: negative time is unknown" {
    const testing = std.testing;
    const s = try formatUtc(testing.allocator, -1);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("unknown", s);
}
