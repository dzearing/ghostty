//! Pure row model for the win32 Activity Monitor's process table (T285): what a
//! row IS, which rows the filter keeps, how the sort orders them, and the text
//! every cell renders. No OS imports and no GDI, so it runs in every
//! app-runtime test lane — the same split that keeps `chooser_rows.zig` testable
//! while `MachineChooser.zig` owns the HWNDs.
//!
//! The Mac original is `RemoteActivityMonitorView.swift`: the filter composition
//! at :715-729, the count label at :966-981, `memString` at :1112-1117 and
//! `normalized` at :1088-1093. Every derivation here cites the line it mirrors,
//! because a parity claim that is not anchored to a Mac source line is a guess
//! (the T240 lesson).

const std = @import("std");
const text_search = @import("text_search.zig");

/// One process-table row, already marshaled out of `remote.protocol.Proc` (the
/// strings are borrowed from the snapshot that owns them).
pub const Row = struct {
    pid: i64,
    ppid: i64 = 0,
    /// PER-CORE CPU% exactly as `remote/agent/proc.zig` reports it: a fully busy
    /// single thread reads ~100 and a multithreaded process may exceed it.
    /// `normalizedCpu` divides by the core count for display, matching Mac's
    /// `normalized(_:)` (:1088).
    cpu_pct: f32 = 0,
    mem_bytes: u64 = 0,
    name: []const u8 = "",
    /// Full executable path (`protocol.Proc.cmd`). May be empty.
    cmd: []const u8 = "",
};

/// Which column the table is ordered by. The values line up with
/// `activity_layout.Column` so a header click maps straight across.
pub const SortKey = enum { pid, name, cpu, mem, path };

pub const Sort = struct {
    key: SortKey,
    ascending: bool,
};

/// Mac opens on `.init(\.cpuPctPerCore, order: .reverse)` (:666-668) — the busy
/// processes are the reason the panel was opened.
pub const default_sort: Sort = .{ .key = .cpu, .ascending = false };

/// A header click. The same column flips direction; a different column takes
/// over ASCENDING, which is what SwiftUI's `Table` does with a fresh
/// `KeyPathComparator` (its default order is `.forward`). Deliberately not
/// "numeric columns start descending": that would be a divergence invented here
/// rather than ported, and the panel already OPENS on cpu-descending.
pub fn toggleSort(cur: Sort, key: SortKey) Sort {
    if (cur.key == key) return .{ .key = key, .ascending = !cur.ascending };
    return .{ .key = key, .ascending = true };
}

/// Case-insensitive ASCII substring test — one implementation for every win32
/// filter box, in `text_search.zig` (T288). The machine chooser's filter folds
/// with the same function, and the ASCII limit is documented and revisited
/// there rather than in each caller.
pub const containsIgnoreCase = text_search.containsIgnoreCase;

/// Trim the ASCII whitespace Mac trims before testing an empty query (:721).
pub fn trim(needle: []const u8) []const u8 {
    return std.mem.trim(u8, needle, " \t\r\n");
}

/// Does `row` survive the search box? Name substring OR pid substring, exactly
/// as Mac composes them (:723-726).
pub fn matches(row: Row, needle: []const u8) bool {
    const q = trim(needle);
    if (q.len == 0) return true;
    if (containsIgnoreCase(row.name, q)) return true;
    var buf: [24]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}", .{row.pid}) catch return false;
    return std.mem.indexOf(u8, pid_str, q) != null;
}

/// What the panel is currently narrowing the table by.
pub const Filter = struct {
    needle: []const u8 = "",
    /// The "Show all" checkbox. When false the table shows only the
    /// ghoztty-spawned tree.
    show_all: bool = false,
    /// Root of the ghoztty-spawned tree (this process, locally). `0` ⇒ the
    /// source could not report one, and Mac then shows everything regardless of
    /// the toggle (:680-686) rather than implying an empty list.
    root_pid: i64 = 0,
};

/// Whether the spawned-only restriction is actually in force (Mac's
/// `spawnedOnlyActive`, :686).
pub fn spawnedOnlyActive(f: Filter) bool {
    return f.root_pid != 0 and !f.show_all;
}

/// Mark `out[i]` for every row that is `root` or a transitive descendant of it
/// (Mac's `spawnedPIDs` BFS, :692-710). `out.len` must be >= `rows.len`.
///
/// Fixed-point marking rather than a hash map: this module allocates nothing, and
/// the row count is bounded by the sampler's `default_limit` (512). Cycle-safe —
/// a row is marked at most once, so a pid whose ppid chain loops cannot spin.
pub fn markSpawned(rows: []const Row, root: i64, out: []bool) void {
    for (out[0..rows.len]) |*b| b.* = false;
    if (root == 0) return;

    var changed = true;
    while (changed) {
        changed = false;
        for (rows, 0..) |r, i| {
            if (out[i]) continue;
            if (r.pid == root or r.ppid == root) {
                out[i] = true;
                changed = true;
                continue;
            }
            for (rows, 0..) |p, j| {
                if (out[j] and p.pid == r.ppid) {
                    out[i] = true;
                    changed = true;
                    break;
                }
            }
        }
    }
}

/// Fill `out` with the INDICES INTO `rows` that the current filter keeps, in
/// `rows` order. `spawned` comes from `markSpawned` and is only consulted when
/// `spawnedOnlyActive(f)`. Returns the count written (capped at `out.len`).
///
/// Indices rather than copies so the caller keeps one array of rows and one
/// array of selection state, both keyed the same way.
pub fn filterInto(rows: []const Row, f: Filter, spawned: []const bool, out: []u32) usize {
    const restrict = spawnedOnlyActive(f);
    var n: usize = 0;
    for (rows, 0..) |r, i| {
        if (n == out.len) break;
        if (restrict and !spawned[i]) continue;
        if (!matches(r, f.needle)) continue;
        out[n] = @intCast(i);
        n += 1;
    }
    return n;
}

/// Order two rows under `sort`. Ties break on pid ascending so the table does
/// not shuffle rows that compare equal from one 1.5s poll to the next — a
/// process table that reorders under a stationary cursor is unusable.
pub fn less(sort: Sort, a: Row, b: Row) bool {
    const ord: std.math.Order = switch (sort.key) {
        .pid => std.math.order(a.pid, b.pid),
        .cpu => std.math.order(a.cpu_pct, b.cpu_pct),
        .mem => std.math.order(a.mem_bytes, b.mem_bytes),
        .name => orderStr(a.name, b.name),
        .path => orderStr(a.cmd, b.cmd),
    };
    return switch (ord) {
        .lt => sort.ascending,
        .gt => !sort.ascending,
        .eq => a.pid < b.pid,
    };
}

/// Case-insensitive ASCII string order, so "Code.exe" and "code.exe" do not
/// land in two different halves of the Name column.
fn orderStr(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ca, cb| {
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return if (la < lb) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

// ---------------------------------------------------------------------
// Cell + label text
// ---------------------------------------------------------------------

/// Per-core CPU% normalized to a 0..100 machine total (Mac's `normalized`,
/// :1088-1093). A zero core count leaves the reading alone rather than dividing
/// by zero.
pub fn normalizedCpu(cpu_pct: f32, ncpu: u32) f32 {
    if (ncpu == 0) return cpu_pct;
    return cpu_pct / @as(f32, @floatFromInt(ncpu));
}

/// Mac's `memString` (:1112-1117): GB with one decimal at 1 GiB and up, else
/// whole MB. The units are binary (GiB/MiB) and labeled "GB"/"MB", which is what
/// the Mac panel does and what Task Manager shows.
pub fn formatMemory(buf: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    const gb = b / 1_073_741_824.0;
    if (gb >= 1) return std.fmt.bufPrint(buf, "{d:.1} GB", .{gb}) catch "";
    const mb = b / 1_048_576.0;
    return std.fmt.bufPrint(buf, "{d:.0} MB", .{mb}) catch "";
}

/// A table cell's CPU reading: one decimal, matching Mac's `"%.1f"` (:1001).
pub fn formatCpu(buf: []u8, cpu_pct: f32, ncpu: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.1}", .{normalizedCpu(cpu_pct, ncpu)}) catch "";
}

/// The gauge's headline CPU number: whole percent, matching Mac's `"%.0f%%"`
/// (:866). Clamped like Mac's `normalizedHostCPU` (:1084).
pub fn formatHostCpu(buf: []u8, cpu_pct: f32) []const u8 {
    const v = std.math.clamp(cpu_pct, 0, 100);
    return std.fmt.bufPrint(buf, "{d:.0}%", .{v}) catch "";
}

/// The control bar's count label (Mac's `countLabel`, :966-981): "N of M" while
/// the spawned-only restriction is in force AND the search box is empty (so the
/// user is told more processes exist), else "N processes".
pub fn formatCount(buf: []u8, f: Filter, shown: usize, total: usize) []const u8 {
    if (spawnedOnlyActive(f) and trim(f.needle).len == 0) {
        return std.fmt.bufPrint(buf, "{d} of {d}", .{ shown, total }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d} processes", .{shown}) catch "";
}

/// Mac's `subline` uptime (:1095-1104): days+hours, else hours+minutes, else
/// minutes. Empty when the source reports no uptime.
pub fn formatUptime(buf: []u8, seconds: u64) []const u8 {
    if (seconds == 0) return "";
    const days = seconds / 86_400;
    const hours = (seconds % 86_400) / 3_600;
    const mins = (seconds % 3_600) / 60;
    if (days > 0) return std.fmt.bufPrint(buf, "up {d}d {d}h", .{ days, hours }) catch "";
    if (hours > 0) return std.fmt.bufPrint(buf, "up {d}h {d}m", .{ hours, mins }) catch "";
    return std.fmt.bufPrint(buf, "up {d}m", .{mins}) catch "";
}

/// The em dash Mac substitutes for an empty Name / Path cell (:993, :1018).
pub const empty_cell = "—";

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn mkRow(pid: i64, ppid: i64, name: []const u8, cpu: f32, mem: u64, cmd: []const u8) Row {
    return .{ .pid = pid, .ppid = ppid, .name = name, .cpu_pct = cpu, .mem_bytes = mem, .cmd = cmd };
}

test "matches: name substring is case-insensitive" {
    const row = mkRow(42, 1, "Code.exe", 0, 0, "C:\\x\\Code.exe");
    try testing.expect(matches(row, "code"));
    try testing.expect(matches(row, "CODE"));
    try testing.expect(matches(row, "de.e"));
    try testing.expect(!matches(row, "notepad"));
}

test "matches: pid substring, and an empty/blank needle keeps everything" {
    const row = mkRow(1234, 1, "zig.exe", 0, 0, "");
    try testing.expect(matches(row, "1234"));
    try testing.expect(matches(row, "23"));
    try testing.expect(!matches(row, "9999"));
    try testing.expect(matches(row, ""));
    try testing.expect(matches(row, "   "));
    // A needle is trimmed before it is applied (Mac trims the query).
    try testing.expect(matches(row, "  zig "));
}

test "markSpawned: the root, its children and its grandchildren, nothing else" {
    const rows = [_]Row{
        mkRow(1, 0, "system", 0, 0, ""),
        mkRow(100, 1, "ghoztty", 0, 0, ""),
        mkRow(200, 100, "pwsh", 0, 0, ""),
        mkRow(300, 200, "zig", 0, 0, ""),
        mkRow(400, 1, "notepad", 0, 0, ""),
    };
    var mark: [rows.len]bool = undefined;
    markSpawned(&rows, 100, &mark);
    try testing.expect(!mark[0]);
    try testing.expect(mark[1]); // the root itself
    try testing.expect(mark[2]);
    try testing.expect(mark[3]); // transitive
    try testing.expect(!mark[4]);
}

test "markSpawned: a ppid cycle terminates and marks nothing spurious" {
    // 500 -> 600 -> 500 is impossible on a real OS; a torn snapshot can still
    // produce it, and the panel must not hang on the GUI thread if it does.
    const rows = [_]Row{
        mkRow(100, 1, "root", 0, 0, ""),
        mkRow(500, 600, "a", 0, 0, ""),
        mkRow(600, 500, "b", 0, 0, ""),
    };
    var mark: [rows.len]bool = undefined;
    markSpawned(&rows, 100, &mark);
    try testing.expect(mark[0]);
    try testing.expect(!mark[1]);
    try testing.expect(!mark[2]);
}

test "markSpawned: no known root marks nothing" {
    const rows = [_]Row{ mkRow(1, 0, "a", 0, 0, ""), mkRow(2, 1, "b", 0, 0, "") };
    var mark: [rows.len]bool = undefined;
    markSpawned(&rows, 0, &mark);
    try testing.expect(!mark[0]);
    try testing.expect(!mark[1]);
}

test "filterInto: spawned-only and the search box compose" {
    const rows = [_]Row{
        mkRow(1, 0, "system", 0, 0, ""),
        mkRow(100, 1, "ghoztty", 0, 0, ""),
        mkRow(200, 100, "pwsh", 0, 0, ""),
        mkRow(400, 1, "pwsh", 0, 0, ""), // same name, outside the tree
    };
    var mark: [rows.len]bool = undefined;
    markSpawned(&rows, 100, &mark);
    var out: [8]u32 = undefined;

    // Spawned-only, no needle: the tree.
    var n = filterInto(&rows, .{ .root_pid = 100 }, &mark, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 1), out[0]);
    try testing.expectEqual(@as(u32, 2), out[1]);

    // Spawned-only + needle: the intersection, NOT the union.
    n = filterInto(&rows, .{ .root_pid = 100, .needle = "pwsh" }, &mark, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 2), out[0]);

    // Show all + the same needle reaches the row outside the tree.
    n = filterInto(&rows, .{ .root_pid = 100, .show_all = true, .needle = "pwsh" }, &mark, &out);
    try testing.expectEqual(@as(usize, 2), n);

    // An unknown root shows everything even with the toggle off (:680-686).
    n = filterInto(&rows, .{ .root_pid = 0 }, &mark, &out);
    try testing.expectEqual(@as(usize, 4), n);
}

test "filterInto: never writes past the caller's buffer" {
    const rows = [_]Row{
        mkRow(1, 0, "a", 0, 0, ""), mkRow(2, 0, "b", 0, 0, ""),
        mkRow(3, 0, "c", 0, 0, ""), mkRow(4, 0, "d", 0, 0, ""),
    };
    var mark: [rows.len]bool = undefined;
    markSpawned(&rows, 0, &mark);
    var out: [2]u32 = undefined;
    try testing.expectEqual(@as(usize, 2), filterInto(&rows, .{}, &mark, &out));
}

test "less: every key orders, and ties fall back to pid" {
    const a = mkRow(10, 0, "alpha", 5.0, 100, "/b/x");
    const b = mkRow(20, 0, "beta", 1.0, 900, "/a/y");

    try testing.expect(less(.{ .key = .pid, .ascending = true }, a, b));
    try testing.expect(!less(.{ .key = .pid, .ascending = false }, a, b));
    try testing.expect(less(.{ .key = .name, .ascending = true }, a, b));
    try testing.expect(less(.{ .key = .cpu, .ascending = false }, a, b)); // 5.0 first
    try testing.expect(less(.{ .key = .mem, .ascending = false }, b, a)); // 900 first
    try testing.expect(less(.{ .key = .path, .ascending = true }, b, a)); // /a before /b

    // Equal on the key ⇒ pid ascending in BOTH directions, so a re-poll never
    // reshuffles equal rows.
    const c = mkRow(30, 0, "same", 0, 0, "");
    const d = mkRow(40, 0, "same", 0, 0, "");
    try testing.expect(less(.{ .key = .name, .ascending = true }, c, d));
    try testing.expect(less(.{ .key = .name, .ascending = false }, c, d));
}

test "less: name order ignores case" {
    const a = mkRow(1, 0, "Code.exe", 0, 0, "");
    const b = mkRow(2, 0, "beta.exe", 0, 0, "");
    // Byte order would put 'C' (0x43) before 'b' (0x62); case-folded, beta wins.
    try testing.expect(less(.{ .key = .name, .ascending = true }, b, a));
}

test "toggleSort: same column flips, a new column starts ascending" {
    const start = default_sort;
    try testing.expectEqual(SortKey.cpu, start.key);
    try testing.expect(!start.ascending);

    const flipped = toggleSort(start, .cpu);
    try testing.expect(flipped.ascending);

    const moved = toggleSort(flipped, .name);
    try testing.expectEqual(SortKey.name, moved.key);
    try testing.expect(moved.ascending);
}

test "formatMemory: GB with a decimal from 1 GiB, whole MB below it" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("2.0 GB", formatMemory(&buf, 2 * 1024 * 1024 * 1024));
    try testing.expectEqualStrings("1.5 GB", formatMemory(&buf, 1536 * 1024 * 1024));
    try testing.expectEqualStrings("512 MB", formatMemory(&buf, 512 * 1024 * 1024));
    try testing.expectEqualStrings("0 MB", formatMemory(&buf, 0));
    // The boundary belongs to GB, not MB.
    try testing.expectEqualStrings("1.0 GB", formatMemory(&buf, 1024 * 1024 * 1024));
}

test "formatCpu: per-core reading is divided by the core count" {
    var buf: [32]u8 = undefined;
    // 800% per-core on 8 cores is 100% of the machine.
    try testing.expectEqualStrings("100.0", formatCpu(&buf, 800, 8));
    try testing.expectEqualStrings("12.5", formatCpu(&buf, 100, 8));
    // An unknown core count leaves the reading alone rather than dividing by 0.
    try testing.expectEqualStrings("100.0", formatCpu(&buf, 100, 0));
}

test "formatHostCpu: whole percent, clamped" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("37%", formatHostCpu(&buf, 37.4));
    try testing.expectEqualStrings("100%", formatHostCpu(&buf, 140));
    try testing.expectEqualStrings("0%", formatHostCpu(&buf, -3));
}

test "formatCount: 'N of M' only while spawned-only is on and the box is empty" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "7 of 312",
        formatCount(&buf, .{ .root_pid = 100 }, 7, 312),
    );
    // A search is running ⇒ the plain form (the "of M" would be misleading).
    try testing.expectEqualStrings(
        "3 processes",
        formatCount(&buf, .{ .root_pid = 100, .needle = "zig" }, 3, 312),
    );
    // Show all ⇒ the plain form.
    try testing.expectEqualStrings(
        "312 processes",
        formatCount(&buf, .{ .root_pid = 100, .show_all = true }, 312, 312),
    );
    // No known root ⇒ the plain form, since nothing is being hidden.
    try testing.expectEqualStrings(
        "312 processes",
        formatCount(&buf, .{ .root_pid = 0 }, 312, 312),
    );
}

test "formatUptime: days, then hours, then minutes; empty when unknown" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("up 2d 3h", formatUptime(&buf, 2 * 86_400 + 3 * 3_600));
    try testing.expectEqualStrings("up 5h 6m", formatUptime(&buf, 5 * 3_600 + 6 * 60));
    try testing.expectEqualStrings("up 9m", formatUptime(&buf, 9 * 60));
    try testing.expectEqualStrings("", formatUptime(&buf, 0));
}

// `containsIgnoreCase`'s own tests moved to `text_search.zig` with the
// function (T288). What stays here is `matches`, which is this module's
// composition of it with the pid search.
