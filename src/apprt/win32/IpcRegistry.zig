//! Named IPC targets for the win32 apprt: `+new-window --target` registers
//! windows, `+split --name` registers panes (spec, "Architecture
//! decisions"). Keys are owned (duped) strings. Entries are removed eagerly
//! from Window/Surface destroy paths (`forget`) and pruned against the live
//! window list on registration, so a recycled allocation can never be
//! reached through a stale name.
const IpcRegistry = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const PaneView = @import("PaneView.zig");
const Window = @import("Window.zig");
const pane_id_mod = @import("pane_id.zig");

targets: std.StringHashMapUnmanaged(Target) = .empty,

/// Counter for auto-generated window names (`window-1`, ...), mirroring the
/// Mac's BaseTerminalController.nextWindowId.
window_counter: u64 = 0,

pub const Target = union(enum) {
    window: *Window,
    /// A split-tree leaf: terminal OR viewer. The PaneView union carries the
    /// kind, so the registry deliberately does NOT grow a third variant
    /// (T90a S3) — one `.pane` case keeps every lookup path kind-agnostic
    /// and each verb narrows where it actually needs a terminal.
    pane: *PaneView,

    pub fn eql(self: Target, other: Target) bool {
        return switch (self) {
            .window => |w| switch (other) {
                .window => |ow| w == ow,
                .pane => false,
            },
            .pane => |p| switch (other) {
                .window => false,
                .pane => |op| p == op,
            },
        };
    }
};

/// What `register` did with the name — the caller's answer to "do I hold
/// this?". A window that records a name it does NOT hold reports a `target`
/// in `+list` that routes somewhere else (T121), so this is not advisory.
pub const RegisterResult = enum {
    /// `name` now resolves to `target` (it already did, or it does now).
    registered,
    /// `name` was already held by a DIFFERENT live target; the incumbent
    /// won and `target` is not reachable under it.
    already_held,
};

/// Register `target` under `name` (key is duped). If the name is already
/// registered to a live target, the existing registration wins — consistent
/// with the CLI's idempotent named-target semantics; callers that need
/// focus-if-exists behavior look the name up first.
pub fn register(
    self: *IpcRegistry,
    alloc: Allocator,
    live_windows: []const *Window,
    name: []const u8,
    target: Target,
) Allocator.Error!RegisterResult {
    self.prune(alloc, live_windows);
    const gop = try self.targets.getOrPut(alloc, name);
    if (gop.found_existing) {
        return if (gop.value_ptr.eql(target)) .registered else .already_held;
    }
    gop.key_ptr.* = alloc.dupe(u8, name) catch |err| {
        // The slot holds the BORROWED key until the dupe lands; drop it
        // rather than leave the map pointing at a caller's buffer.
        self.targets.removeByPtr(gop.key_ptr);
        return err;
    };
    gop.value_ptr.* = target;
    return .registered;
}

/// Look up a live target by name (stale entries are pruned first).
///
/// Explicitly registered names win. On a miss we fall back to the pane's OWN
/// identity (T113), which docs/claude/cli.md promises is "accepted directly by every
/// `--target`/`--name` (case-insensitive), with no prior registration or
/// `+list` needed" — the pane id itself, plus the two legacy surface-id
/// spellings a pane's processes may be holding instead (see
/// `pane_id.parseSurfaceIdAlias`).
pub fn lookup(
    self: *IpcRegistry,
    alloc: Allocator,
    live_windows: []const *Window,
    name: []const u8,
) ?Target {
    self.prune(alloc, live_windows);
    if (self.targets.get(name)) |t| return t;
    return findPaneByIdentity(live_windows, name);
}

/// Resolve a pane by its own identity rather than a registered name. Returns
/// null when `name` is not an identity spelling, or names no live pane.
fn findPaneByIdentity(live_windows: []const *Window, name: []const u8) ?Target {
    const surface_id: ?u64 = if (pane_id_mod.isValid(name))
        null
    else
        pane_id_mod.parseSurfaceIdAlias(name) orelse return null;

    for (live_windows) |win| {
        for (0..win.tab_count) |i| {
            var panes = win.tab_trees[i].iterator();
            while (panes.next()) |v| {
                const pane = v.view;
                if (surface_id) |sid| {
                    // The legacy spellings name a SURFACE, so they can only
                    // ever resolve a terminal pane — and only once its core
                    // surface is up (`core_surface.id` is set by init).
                    const s = pane.surface() orelse continue;
                    if (!s.core_surface_ready) continue;
                    if (s.core_surface.id == sid) return .{ .pane = pane };
                } else if (pane_id_mod.eql(pane.paneId(), name)) {
                    return .{ .pane = pane };
                }
            }
        }
    }
    return null;
}

/// Reverse lookup: the registered name of a target, if any.
pub fn nameOf(self: *IpcRegistry, target: Target) ?[]const u8 {
    var it = self.targets.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.eql(target)) return entry.key_ptr.*;
    }
    return null;
}

/// Drop every registration pointing at `target`. Called from Window and
/// Surface destroy paths so names can never reach a recycled allocation.
pub fn forget(self: *IpcRegistry, alloc: Allocator, target: Target) void {
    var it = self.targets.iterator();
    while (it.next()) |entry| {
        if (!entry.value_ptr.eql(target)) continue;
        const key = entry.key_ptr.*;
        self.targets.removeByPtr(entry.key_ptr);
        alloc.free(key);
        // Hash map iterators are invalidated by removal; restart. The map
        // is tiny (named targets), so the rescan is negligible.
        it = self.targets.iterator();
    }
}

/// Remove registry entries whose target is no longer alive.
fn prune(self: *IpcRegistry, alloc: Allocator, live_windows: []const *Window) void {
    var it = self.targets.iterator();
    while (it.next()) |entry| {
        const alive = switch (entry.value_ptr.*) {
            .window => |w| alive: {
                for (live_windows) |live| {
                    if (live == w) break :alive true;
                }
                break :alive false;
            },
            .pane => |p| alive: {
                for (live_windows) |win| {
                    for (0..win.tab_count) |i| {
                        var panes = win.tab_trees[i].iterator();
                        while (panes.next()) |v| {
                            if (v.view == p) break :alive true;
                        }
                    }
                }
                break :alive false;
            },
        };
        if (alive) continue;
        const key = entry.key_ptr.*;
        self.targets.removeByPtr(entry.key_ptr);
        alloc.free(key);
        it = self.targets.iterator();
    }
}

/// The prefix every auto-generated window name carries.
const auto_prefix = "window-";

/// The N of an auto-generated `window-N` name, or null if `name` is not one.
/// Strict on purpose: only `window-` followed by ASCII digits naming a
/// non-zero number counts, so a user's `+new-window --target=window-pane` or
/// `--target=window-1a` is a plain name that reserves nothing.
fn autoWindowNumber(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, auto_prefix)) return null;
    const digits = name[auto_prefix.len..];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseUnsigned(u64, digits, 10) catch return null;
    return if (n == 0) null else n;
}

/// Reserve a window name that was ADOPTED rather than minted — a persisted
/// session-restore name, or an explicit `+new-window --target=`. If it names
/// an auto `window-N`, advance the allocator past N so a later mint can never
/// repeat it (T121).
///
/// Why this is load-bearing: `window_counter` restarts at zero every app
/// launch, while session restore re-adopts names minted by a PREVIOUS run.
/// Restore a `window-3`, open three fresh windows, and the third mints
/// `window-3` again — two live windows holding one target name, with
/// `+close`/`+split`/`+rename` routed to whichever registered first. Mac
/// fixed the same defect the same way (`565b77a58`).
///
/// Never rewinds: the counter only ever moves forward.
pub fn reserveWindowName(self: *IpcRegistry, name: []const u8) void {
    const n = autoWindowNumber(name) orelse return;
    self.window_counter = @max(self.window_counter, n);
}

/// The next auto-generated window name (`window-N`). Caller owns the slice.
pub fn nextWindowName(self: *IpcRegistry, alloc: Allocator) Allocator.Error![]u8 {
    self.window_counter += 1;
    return std.fmt.allocPrint(alloc, auto_prefix ++ "{d}", .{self.window_counter});
}

/// Free all owned keys and the map itself.
pub fn deinit(self: *IpcRegistry, alloc: Allocator) void {
    var it = self.targets.keyIterator();
    while (it.next()) |key| alloc.free(key.*);
    self.targets.deinit(alloc);
}

const testing = std.testing;

test "auto window names mint monotonically" {
    const alloc = testing.allocator;
    var reg: IpcRegistry = .{};
    defer reg.deinit(alloc);

    for ([_][]const u8{ "window-1", "window-2", "window-3" }) |want| {
        const got = try reg.nextWindowName(alloc);
        defer alloc.free(got);
        try testing.expectEqualStrings(want, got);
    }
}

test "an adopted window-N name reserves its number" {
    const alloc = testing.allocator;
    var reg: IpcRegistry = .{};
    defer reg.deinit(alloc);

    // A session restore re-adopts names minted by a previous run.
    reg.reserveWindowName("window-1");
    reg.reserveWindowName("window-3");

    // The next mint must clear BOTH, not repeat window-3.
    const got = try reg.nextWindowName(alloc);
    defer alloc.free(got);
    try testing.expectEqualStrings("window-4", got);
}

test "reserving never rewinds the allocator" {
    const alloc = testing.allocator;
    var reg: IpcRegistry = .{};
    defer reg.deinit(alloc);

    const first = try reg.nextWindowName(alloc);
    defer alloc.free(first);
    const second = try reg.nextWindowName(alloc);
    defer alloc.free(second);
    try testing.expectEqualStrings("window-2", second);

    // A restored window-1 is behind the allocator; it must not pull it back.
    reg.reserveWindowName("window-1");
    const third = try reg.nextWindowName(alloc);
    defer alloc.free(third);
    try testing.expectEqualStrings("window-3", third);
}

test "non-auto names reserve nothing" {
    const alloc = testing.allocator;
    var reg: IpcRegistry = .{};
    defer reg.deinit(alloc);

    for ([_][]const u8{
        "dev",
        "window-",
        "window-0",
        "window-1a",
        "window-a1",
        "window--1",
        "window-+1",
        "window- 1",
        "window-1_0",
        "Window-9",
        "window-99999999999999999999999", // overflows u64
    }) |name| {
        reg.reserveWindowName(name);
    }

    const got = try reg.nextWindowName(alloc);
    defer alloc.free(got);
    try testing.expectEqualStrings("window-1", got);
}

test "registering a name a different target holds reports already_held" {
    const alloc = testing.allocator;
    var reg: IpcRegistry = .{};
    defer reg.deinit(alloc);

    // Two distinct (never dereferenced) window identities.
    const a: *Window = @ptrFromInt(0x1000);
    const b: *Window = @ptrFromInt(0x2000);
    const live = [_]*Window{ a, b };

    try testing.expectEqual(
        IpcRegistry.RegisterResult.registered,
        try reg.register(alloc, &live, "window-3", .{ .window = a }),
    );
    // Re-registering the SAME target under the same name is idempotent, not
    // a conflict — the caller still holds the name.
    try testing.expectEqual(
        IpcRegistry.RegisterResult.registered,
        try reg.register(alloc, &live, "window-3", .{ .window = a }),
    );
    try testing.expectEqual(
        IpcRegistry.RegisterResult.already_held,
        try reg.register(alloc, &live, "window-3", .{ .window = b }),
    );
    try testing.expect(reg.lookup(alloc, &live, "window-3").?.eql(.{ .window = a }));
}
