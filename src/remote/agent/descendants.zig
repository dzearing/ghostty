//! "Is anything running under this session's shell?" — the pure half (T356).
//!
//! The agent samples each bound session's process subtree and pushes
//! `META{has_descendants}` when the answer changes, so the app can decide the
//! CLOSE CONFIRMATION for a cross-machine pane. That pane's shell lives on
//! another machine's process table, so the app cannot walk it; the machine that
//! owns the process is the only one that can answer.
//!
//! This module holds the parent map and the walk. It is deliberately OS-free so
//! the rule itself is unit-testable in the `-Dapp-runtime=none` lane; the
//! per-OS table snapshot lives next to the platform externs it needs, in
//! `proc.zig` (`snapshotParents`).
//!
//! The rule is the SAME question the local path asks
//! (`apprt/win32/ProcessTree.hasDescendants`), on purpose: a remote pane and a
//! local one should decide the confirmation by one rule, not by two that merely
//! look alike. Both are inclusive-free (a pid is not its own descendant),
//! depth-capped, and cycle-safe — a recycled pid can leave a stale parent link
//! that forms a loop in a snapshot, and a hang here would stall the agent's
//! sampling tick.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// pid → parent pid for every process in one snapshot. i64 to match the wire's
/// pid type (`protocol.Proc.pid`) and macOS/Linux signed pids alike.
pub const ParentMap = std.AutoHashMapUnmanaged(i64, i64);

/// Cap on how far a parent chain is followed before giving up. A snapshot taken
/// while pids are being recycled can contain a cycle; without a cap the walk
/// would spin forever inside the agent's sampling tick.
const max_depth: usize = 128;

/// Whether `ancestor` appears in `pid`'s parent chain. Inclusive: a pid is its
/// own ancestor (mirrors `ProcessTree.isAncestor`).
pub fn isAncestor(map: *const ParentMap, ancestor: i64, pid: i64) bool {
    var current = pid;
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        if (current == ancestor) return true;
        const parent = map.get(current) orelse return false;
        // A root reports 0 (or itself, as the idle process does on Windows).
        if (parent == current or parent <= 0) return false;
        current = parent;
    }
    return false;
}

/// Whether any process in the snapshot descends from `root`. `root` itself does
/// NOT count, so a shell sitting at an idle prompt answers false.
///
/// Conservative by construction, in the direction that matters: a recycled pid
/// whose stale parent link points at `root` reports a descendant that is not
/// one, which shows a confirmation that was not needed rather than skipping one
/// that was.
pub fn hasDescendants(map: *const ParentMap, root: i64) bool {
    if (root <= 0) return false;
    var it = map.iterator();
    while (it.next()) |entry| {
        const candidate = entry.key_ptr.*;
        if (candidate == root) continue;
        if (isAncestor(map, root, candidate)) return true;
    }
    return false;
}

/// Whether `pid` appears in the snapshot at all. Callers use this to tell "the
/// snapshot says nothing runs under this shell" from "there is no snapshot": a
/// failed or empty enumeration would otherwise answer `hasDescendants` with a
/// confident, wrong false — and a wrong false here skips a confirmation and
/// kills a running job.
pub fn contains(map: *const ParentMap, pid: i64) bool {
    return map.contains(pid);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn testMap(alloc: Allocator, pairs: []const [2]i64) !ParentMap {
    var map: ParentMap = .empty;
    for (pairs) |pair| try map.put(alloc, pair[0], pair[1]);
    return map;
}

test "hasDescendants: an idle shell has none" {
    const alloc = testing.allocator;
    // 100 is the shell; 300 hangs off an unrelated tree.
    var map = try testMap(alloc, &.{ .{ 100, 1 }, .{ 300, 200 }, .{ 200, 1 } });
    defer map.deinit(alloc);
    try testing.expect(!hasDescendants(&map, 100));
    try testing.expect(contains(&map, 100));
}

test "hasDescendants: a direct child counts, and so does a grandchild" {
    const alloc = testing.allocator;
    var direct = try testMap(alloc, &.{ .{ 100, 1 }, .{ 200, 100 } });
    defer direct.deinit(alloc);
    try testing.expect(hasDescendants(&direct, 100));

    // The grandchild case is why this is a WALK and not a direct-child scan: a
    // shell whose immediate child already exited but whose grandchild is still
    // working is busy, and closing it would kill real work.
    var deep = try testMap(alloc, &.{ .{ 100, 1 }, .{ 200, 100 }, .{ 300, 200 } });
    defer deep.deinit(alloc);
    try testing.expect(hasDescendants(&deep, 100));
    try testing.expect(hasDescendants(&deep, 200));
    try testing.expect(!hasDescendants(&deep, 300));
}

test "hasDescendants: a cycle in the snapshot terminates" {
    const alloc = testing.allocator;
    // 200 -> 300 -> 200: a pid-recycling artifact. The walk must end.
    var map = try testMap(alloc, &.{ .{ 100, 1 }, .{ 200, 300 }, .{ 300, 200 } });
    defer map.deinit(alloc);
    try testing.expect(!hasDescendants(&map, 100));
}

test "hasDescendants: a self-parented root is not its own descendant" {
    const alloc = testing.allocator;
    var map = try testMap(alloc, &.{.{ 100, 100 }});
    defer map.deinit(alloc);
    try testing.expect(!hasDescendants(&map, 100));
}

test "hasDescendants: an empty snapshot answers false and contains() says why" {
    const alloc = testing.allocator;
    var map: ParentMap = .empty;
    defer map.deinit(alloc);
    // The false here is meaningless — the caller must gate on `contains`, which
    // is the whole reason it exists.
    try testing.expect(!hasDescendants(&map, 100));
    try testing.expect(!contains(&map, 100));
}

test "hasDescendants: a nonsense root is never busy" {
    const alloc = testing.allocator;
    var map = try testMap(alloc, &.{ .{ 100, 1 }, .{ 200, 100 } });
    defer map.deinit(alloc);
    try testing.expect(!hasDescendants(&map, 0));
    try testing.expect(!hasDescendants(&map, -5));
}

test "isAncestor: inclusive at the root, and bounded on a long chain" {
    const alloc = testing.allocator;
    var map: ParentMap = .empty;
    defer map.deinit(alloc);
    // A chain far longer than the depth cap: 1 <- 2 <- 3 ... <- 400.
    var i: i64 = 2;
    while (i <= 400) : (i += 1) try map.put(alloc, i, i - 1);
    try map.put(alloc, 1, 0);

    try testing.expect(isAncestor(&map, 5, 5));
    try testing.expect(isAncestor(&map, 5, 50));
    // Beyond `max_depth` the walk gives up and reports false — conservative in
    // the safe direction (an unnecessary confirmation, never a skipped one).
    try testing.expect(!isAncestor(&map, 1, 400));
}
