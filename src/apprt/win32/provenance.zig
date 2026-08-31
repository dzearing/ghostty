//! Build provenance of the running instance (T52): which executable is
//! this process, built from what commit, in which mode. One collection
//! point shared by the IPC `version` verb, the `+list --json` build
//! metadata, and the command-palette About box, so every surface answers
//! "which build is this window running?" identically.
const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const build_config = @import("../../build_config.zig");
const image_freshness = @import("image_freshness.zig");
const install_location = @import("install_location.zig");

/// Comptime provenance: baked into the binary by build.zig/GitVersion.
pub const version: []const u8 = build_config.version_string;
pub const commit: []const u8 = build_config.version.build orelse "unknown";
pub const mode: []const u8 = mode: {
    // mode_string is ".Debug"/".ReleaseFast"; drop the leading dot.
    const m = build_config.mode_string;
    break :mode if (m.len > 0 and m[0] == '.') m[1..] else m;
};
pub const runtime: []const u8 = @tagName(build_config.app_runtime);

/// Whether this build checks the win-v update channel (T24): true for MSI
/// release-pipeline builds (-Dwindows-update-check).
///
/// **Not the whole answer since T1217** — a non-Debug build running from the
/// installed-release folder checks too, however it got there. `collect()`
/// fills the runtime field from `install_location.autoUpdateCheckEnabled`;
/// this constant is only the build half, kept for callers that have no
/// allocator.
pub const update_check_build_flag: bool = build_config.windows_update_check;

pub const Provenance = struct {
    version: []const u8 = version,
    commit: []const u8 = commit,
    mode: []const u8 = mode,
    runtime: []const u8 = runtime,
    /// Whether this instance runs the automatic update check. Computed at
    /// runtime (T1217): the build flag OR the installed-release location.
    update_check: bool = update_check_build_flag,
    /// Absolute path of the running executable.
    exe: []const u8,
    /// Last-write time of the executable ("YYYY-MM-DD HH:MM:SS UTC") —
    /// the runtime stand-in for a build/install date. "unknown" if the
    /// exe cannot be statted.
    ///
    /// **This describes the FILE, not this process** (T1205). When
    /// `newer_build_installed` is true the two are different builds, and
    /// anything shown to a person must say which is which — a stale window
    /// showing today's date beside yesterday's version is the exact defect
    /// this field caused.
    exe_modified: []const u8,
    /// When THIS process started ("YYYY-MM-DD HH:MM:SS UTC"), or "unknown".
    /// The honest answer to "how old is the build I am looking at".
    started: []const u8,
    /// True when the executable on disk was written after this process
    /// started: a newer build is installed and this window is still running
    /// the old one. Restarting is what picks it up.
    newer_build_installed: bool = false,
    pid: u32,
};

/// Collect runtime provenance. All strings are allocated from `alloc`
/// (arena-friendly; nothing needs individual freeing).
pub fn collect(alloc: Allocator) Allocator.Error!Provenance {
    const exe: []const u8 = std.fs.selfExePathAlloc(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try alloc.dupe(u8, "unknown"),
    };
    const on_disk_ns: i128 = on_disk: {
        const f = std.fs.openFileAbsolute(exe, .{}) catch break :on_disk 0;
        defer f.close();
        const st = f.stat() catch break :on_disk 0;
        break :on_disk st.mtime;
    };
    const started_ns = processStartNs();
    return .{
        .exe = exe,
        .update_check = install_location.autoUpdateCheckEnabled(alloc),
        .exe_modified = if (on_disk_ns > 0)
            try formatUtc(alloc, on_disk_ns)
        else
            try alloc.dupe(u8, "unknown"),
        .started = if (started_ns > 0)
            try formatUtc(alloc, started_ns)
        else
            try alloc.dupe(u8, "unknown"),
        .newer_build_installed = image_freshness.isStale(on_disk_ns, started_ns),
        .pid = windows.GetCurrentProcessId(),
    };
}

/// When this process started, in nanoseconds since the Unix epoch; 0 when
/// Windows will not say. Deliberately the process's OWN creation time rather
/// than an app-startup `std.time.nanoTimestamp()`: the question is how old
/// the running IMAGE is, and a value captured by app code is one more thing
/// that can be captured in the wrong place.
pub fn processStartNs() i128 {
    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (GetProcessTimes(windows.GetCurrentProcess(), &creation, &exit, &kernel, &user) == 0) return 0;
    const ticks = (@as(u64, creation.dwHighDateTime) << 32) | @as(u64, creation.dwLowDateTime);
    if (ticks == 0) return 0;
    return image_freshness.filetimeToUnixNs(ticks);
}

extern "kernel32" fn GetProcessTimes(
    hProcess: windows.HANDLE,
    lpCreationTime: *windows.FILETIME,
    lpExitTime: *windows.FILETIME,
    lpKernelTime: *windows.FILETIME,
    lpUserTime: *windows.FILETIME,
) callconv(.winapi) windows.BOOL;

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
