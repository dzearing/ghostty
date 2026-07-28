//! Named IPC targets for the win32 apprt: `+new-window --target` registers
//! windows, `+split --name` registers panes (spec, "Architecture
//! decisions"). Keys are owned (duped) strings. Entries are removed eagerly
//! from Window/Surface destroy paths (`forget`) and pruned against the live
//! window list on registration, so a recycled allocation can never be
//! reached through a stale name.
const IpcRegistry = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const pane_id_mod = @import("pane_id.zig");

targets: std.StringHashMapUnmanaged(Target) = .empty,

/// Counter for auto-generated window names (`window-1`, ...), mirroring the
/// Mac's BaseTerminalController.nextWindowId.
window_counter: u64 = 0,

pub const Target = union(enum) {
    window: *Window,
    pane: *Surface,

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
) Allocator.Error!void {
    self.prune(alloc, live_windows);
    const gop = try self.targets.getOrPut(alloc, name);
    if (gop.found_existing) return;
    gop.key_ptr.* = try alloc.dupe(u8, name);
    gop.value_ptr.* = target;
}

/// Look up a live target by name (stale entries are pruned first).
///
/// Explicitly registered names win. On a miss we fall back to the pane's OWN
/// identity (T113), which CLAUDE.md promises is "accepted directly by every
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
            var surfaces = win.tab_trees[i].iterator();
            while (surfaces.next()) |v| {
                const s = v.view;
                if (surface_id) |sid| {
                    // A legacy spelling names a surface only once its core
                    // surface is up (`core_surface.id` is set by init).
                    if (!s.core_surface_ready) continue;
                    if (s.core_surface.id == sid) return .{ .pane = s };
                } else if (pane_id_mod.eql(s.paneId(), name)) {
                    return .{ .pane = s };
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
            .pane => |s| alive: {
                for (live_windows) |win| {
                    for (0..win.tab_count) |i| {
                        var surfaces = win.tab_trees[i].iterator();
                        while (surfaces.next()) |v| {
                            if (v.view == s) break :alive true;
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

/// The next auto-generated window name (`window-N`). Caller owns the slice.
pub fn nextWindowName(self: *IpcRegistry, alloc: Allocator) Allocator.Error![]u8 {
    self.window_counter += 1;
    return std.fmt.allocPrint(alloc, "window-{d}", .{self.window_counter});
}

/// Free all owned keys and the map itself.
pub fn deinit(self: *IpcRegistry, alloc: Allocator) void {
    var it = self.targets.keyIterator();
    while (it.next()) |key| alloc.free(key.*);
    self.targets.deinit(alloc);
}
