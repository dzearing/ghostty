//! Windows process ancestry, used by `+list --pid=<pid>`: a CLI process
//! deep inside a pane's shell (e.g. a Claude Code session) can find its own
//! pane by asking "which pane's shell is an ancestor of this pid?". The
//! snapshot comes from Toolhelp32; the walk itself is pure and unit tested.
const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const TH32CS_SNAPPROCESS: windows.DWORD = 0x00000002;

const PROCESSENTRY32W = extern struct {
    dwSize: windows.DWORD,
    cntUsage: windows.DWORD,
    th32ProcessID: windows.DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: windows.DWORD,
    cntThreads: windows.DWORD,
    th32ParentProcessID: windows.DWORD,
    pcPriClassBase: i32,
    dwFlags: windows.DWORD,
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(
    dwFlags: windows.DWORD,
    th32ProcessID: windows.DWORD,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn Process32FirstW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn Process32NextW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;

pub const PidMap = std.AutoHashMapUnmanaged(u32, u32);

/// Snapshot the system's pid → parent-pid table. Caller deinits the map.
pub fn snapshot(alloc: Allocator) Allocator.Error!PidMap {
    var map: PidMap = .empty;
    errdefer map.deinit(alloc);

    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == windows.INVALID_HANDLE_VALUE) return map;
    defer windows.CloseHandle(snap);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) == 0) return map;
    while (true) {
        try map.put(alloc, entry.th32ProcessID, entry.th32ParentProcessID);
        if (Process32NextW(snap, &entry) == 0) break;
    }
    return map;
}

/// Whether `ancestor` appears in `descendant`'s parent chain (inclusive:
/// a pid is its own ancestor). Depth-capped: Windows recycles pids, so a
/// stale parent link can form a cycle in the snapshot.
pub fn isAncestor(map: *const PidMap, ancestor: u32, descendant: u32) bool {
    var current = descendant;
    var depth: usize = 0;
    while (depth < 128) : (depth += 1) {
        if (current == ancestor) return true;
        const parent = map.get(current) orelse return false;
        // The idle process is its own parent; other roots report 0.
        if (parent == current or parent == 0) return false;
        current = parent;
    }
    return false;
}

// -----------------------------------------------------------------------------

const testing = std.testing;

fn testMap(alloc: Allocator, pairs: []const [2]u32) !PidMap {
    var map: PidMap = .empty;
    for (pairs) |pair| try map.put(alloc, pair[0], pair[1]);
    return map;
}

test "isAncestor: direct chain" {
    const alloc = testing.allocator;
    // 100 -> 200 -> 300 (parent links point up)
    var map = try testMap(alloc, &.{ .{ 300, 200 }, .{ 200, 100 }, .{ 100, 0 } });
    defer map.deinit(alloc);
    try testing.expect(isAncestor(&map, 100, 300));
    try testing.expect(isAncestor(&map, 200, 300));
    try testing.expect(isAncestor(&map, 300, 300)); // inclusive
    try testing.expect(!isAncestor(&map, 300, 100)); // wrong direction
    try testing.expect(!isAncestor(&map, 999, 300)); // unrelated
}

test "isAncestor: missing pid" {
    const alloc = testing.allocator;
    var map = try testMap(alloc, &.{.{ 100, 0 }});
    defer map.deinit(alloc);
    try testing.expect(!isAncestor(&map, 100, 555));
}

test "isAncestor: cycle in stale snapshot terminates" {
    const alloc = testing.allocator;
    // 10 <-> 20 cycle (recycled pids)
    var map = try testMap(alloc, &.{ .{ 10, 20 }, .{ 20, 10 } });
    defer map.deinit(alloc);
    try testing.expect(!isAncestor(&map, 99, 10));
    try testing.expect(isAncestor(&map, 20, 10));
}

test "isAncestor: self-parent root terminates" {
    const alloc = testing.allocator;
    var map = try testMap(alloc, &.{ .{ 4, 4 }, .{ 30, 4 } });
    defer map.deinit(alloc);
    try testing.expect(!isAncestor(&map, 99, 30));
    try testing.expect(isAncestor(&map, 4, 30));
}
