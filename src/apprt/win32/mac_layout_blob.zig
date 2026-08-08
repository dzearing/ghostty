//! Reading a **macOS-lineage** layout blob on Windows (T337).
//!
//! Cross-machine "Restore All" pulls a machine's window topology out of its
//! agent as opaque `GET_LAYOUTS` blobs. The agent never looks inside one
//! (`remote/agent/layout_meta.zig` — "the agent is DELIBERATELY
//! topology-agnostic"), so the blob's schema is a contract between two VIEWERS
//! — and the two viewers never shared one:
//!
//!   * **win32** pushes a `session_layout.Window`: snake_case keys, one blob per
//!     WINDOW, a FLAT `nodes` array whose splits carry `left`/`right` indices.
//!   * **macOS** pushes a `SessionLayoutManifest.Entry`: camelCase keys, one blob
//!     per TAB (tabs of one window share a `tabGroupID` and order themselves by
//!     `tabIndex`), and a NESTED `tree`.
//!
//! Until this module, a Windows viewer pointed at a Mac machine decoded nothing
//! and reported "nothing to restore" — the feature looked present and was not.
//! This module closes that direction by TRANSLATING on read.
//!
//! ## Why translate rather than agree on one schema
//!
//! An envelope or a shared schema only describes blobs written AFTER both
//! lineages ship it. The blobs already sitting in live agents carry no tag and
//! never will — an agent outlives the app that wrote them by design (see
//! CLAUDE.md, "Agent contract & upgrade compatibility"). A reader that tolerates
//! the other lineage's shape is therefore required either way, so it is the
//! whole fix rather than half of one. Detection needs no tag: a macOS entry has
//! a `tree` object and no `tabs`, a win32 window has `tabs` and no `tree`.
//!
//! Nothing here writes anything: the win32 out-side blob is unchanged, the wire
//! protocol is unchanged, and the agent is untouched. The mirror direction (a
//! Mac viewer reading a win32 blob) is the Mac seat's half.
//!
//! ## Two deliberate losses
//!
//!   * **WP-D3 screen snapshots are dropped.** Mac's `layoutBlob` encodes the
//!     whole entry, snapshots included; win32's `serializeWindow` strips its own
//!     (see `layout_blobs.zig`, T413). A snapshot from another viewer would paint
//!     that viewer's screen into this pane and ATTACH at that viewer's stale
//!     offset, so the leaves this module produces never carry the pair.
//!   * **The window ORIGIN is a different coordinate system.** Cocoa measures
//!     y UP from the bottom-left of the primary screen; win32 measures it DOWN
//!     from the top-left, and the blob does not record the source screen's
//!     height, so the flip cannot be undone from the data. The origin is passed
//!     through verbatim, which lands the window vertically mirrored but on
//!     screen — and `restore_frame.reanchor` re-centers any window that lands
//!     on no monitor at all. Centering them all instead would stack every
//!     restored window on one spot, which is worse for the multi-window case
//!     this feature exists for. Size (width/height) translates exactly.
//!     Follow-up: T623.

const std = @import("std");
const Allocator = std.mem.Allocator;

const session_layout = @import("session_layout.zig");

/// Ceiling on the nodes one entry's tree may flatten to. `Split.left`/`right`
/// are `u16` indices, so this must stay well under 65535; a real window is a
/// handful of panes, and anything past this is a corrupt or hostile blob.
pub const max_nodes: usize = 4096;

/// Ceiling on tree recursion depth, so a pathologically nested blob costs an
/// error rather than the stack.
pub const max_depth: usize = 64;

/// One macOS manifest entry, already translated into win32 vocabulary: a single
/// TAB's flattened split tree plus the window-level fields the entry carries.
/// Grouped into windows by `groupIntoWindows`.
pub const Entry = struct {
    /// The entry's own UUID (`Entry.id`) — a manifest identity, NOT a session id.
    id: []const u8 = "",
    frame: ?session_layout.Frame = null,
    /// Shared by every entry of one native tab group; null for a standalone
    /// window.
    tab_group_id: ?[]const u8 = null,
    tab_index: i64 = 0,
    /// `Entry.titleOverride` — the user-set title of THIS tab.
    tab_title: ?[]const u8 = null,
    /// `Entry.windowTitleOverride` — the window-level pin, held by exactly one
    /// entry of a tab group.
    window_title: ?[]const u8 = null,
    ipc_name: ?[]const u8 = null,
    /// The tree, flattened to win32's `nodes[0] = root` representation.
    nodes: []const session_layout.Node = &.{},
};

/// Whether `v` is a macOS-lineage layout blob. Shape alone decides it — see the
/// header on why no tag is available: an entry has a `tree` OBJECT and never a
/// `tabs` array, which is exactly the inverse of a win32 window.
pub fn looksLikeEntry(v: std.json.Value) bool {
    const obj = switch (v) {
        .object => |o| o,
        else => return false,
    };
    if (obj.get("tabs") != null) return false;
    const tree = obj.get("tree") orelse return false;
    return switch (tree) {
        .object => true,
        else => false,
    };
}

/// Translate one macOS entry. Every allocation lands in `arena`; every string is
/// BORROWED from `v` (whose own strings the caller already owns), so the result
/// lives exactly as long as the parsed value does.
///
/// Fails only on a tree that cannot be walked (not an object, a node that is
/// neither leaf nor split, a missing split child, or one past the size/depth
/// ceilings). A missing or unreadable scalar field falls back rather than
/// failing: the additive-evolution contract cuts both ways, and half a title is
/// not worth losing a window over.
pub fn parseEntry(arena: Allocator, v: std.json.Value) !Entry {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.NotAnEntry,
    };
    const tree = obj.get("tree") orelse return error.NotAnEntry;

    var nodes: std.ArrayList(session_layout.Node) = .empty;
    errdefer nodes.deinit(arena);
    _ = try flatten(arena, tree, &nodes, 0);

    return .{
        .id = str(obj.get("id")) orelse "",
        .frame = frameFrom(obj.get("frame")),
        .tab_group_id = str(obj.get("tabGroupID")),
        .tab_index = int(obj.get("tabIndex")) orelse 0,
        .tab_title = str(obj.get("titleOverride")),
        .window_title = str(obj.get("windowTitleOverride")),
        .ipc_name = str(obj.get("ipcName")),
        .nodes = try nodes.toOwnedSlice(arena),
    };
}

/// Group translated entries into windows the win32 restore can replay: entries
/// sharing a `tabGroupID` come back as tabs of ONE window in `tabIndex` order,
/// and an entry with no group is a standalone single-tab window. This mirrors
/// Mac's own rebuild (`SessionLayoutRestore.presentRestoredSessionWindows`),
/// which is what makes a Mac topology come back here shaped the way its owner
/// left it rather than as N loose windows.
///
/// Groups keep the order their FIRST entry appeared in, so the reply's order
/// survives. Entries whose tree flattened to nothing are dropped by the caller
/// before they get here.
pub fn groupIntoWindows(arena: Allocator, entries: []const Entry) ![]session_layout.Window {
    var groups: std.ArrayList(std.ArrayList(Entry)) = .empty;
    defer {
        for (groups.items) |*g| g.deinit(arena);
        groups.deinit(arena);
    }

    for (entries) |entry| {
        var placed = false;
        if (entry.tab_group_id) |gid| {
            for (groups.items) |*g| {
                const first = g.items[0];
                const other = first.tab_group_id orelse continue;
                if (std.mem.eql(u8, other, gid)) {
                    try g.append(arena, entry);
                    placed = true;
                    break;
                }
            }
        }
        if (placed) continue;
        var fresh: std.ArrayList(Entry) = .empty;
        try fresh.append(arena, entry);
        try groups.append(arena, fresh);
    }

    var out: std.ArrayList(session_layout.Window) = .empty;
    errdefer out.deinit(arena);
    for (groups.items, 0..) |*g, gi| {
        // Stable, so entries that share a tabIndex (or a blob written before the
        // field existed) keep the reply's order rather than shuffling.
        std.sort.insertion(Entry, g.items, {}, lessByTabIndex);

        const tabs = try arena.alloc(session_layout.Tab, g.items.len);
        var frame: ?session_layout.Frame = null;
        var window_title: ?[]const u8 = null;
        var ipc_name: ?[]const u8 = null;
        for (g.items, 0..) |entry, ti| {
            tabs[ti] = .{
                .nodes = entry.nodes,
                .title = entry.tab_title,
                .active = ti == 0,
            };
            // A tab sibling inherits the group's frame, so the first entry that
            // has one wins (Mac stores it on the group's window, not per tab).
            if (frame == null) frame = entry.frame;
            if (window_title == null) window_title = entry.window_title;
            if (ipc_name == null) ipc_name = entry.ipc_name;
        }

        try out.append(arena, .{
            .id = try windowId(arena, ipc_name, g.items[0].id, gi),
            // `uuid` is deliberately left null: it keys the agent's blob store,
            // and adopting the Mac window's identity here would let this rebuilt
            // copy overwrite the original's blob on the next push.
            .frame = frame,
            .title_override = window_title,
            .ipc_name = ipc_name,
            .active_tab = 0,
            .tabs = tabs,
        });
    }
    return out.toOwnedSlice(arena);
}

fn lessByTabIndex(_: void, a: Entry, b: Entry) bool {
    return a.tab_index < b.tab_index;
}

/// The window's within-reply name: its IPC name when it has one, else the
/// entry's own uuid, else a positional fallback — the same precedence
/// `session_layout.Window.id` documents for the win32 side.
fn windowId(arena: Allocator, ipc_name: ?[]const u8, entry_id: []const u8, index: usize) ![]const u8 {
    if (ipc_name) |n| if (n.len > 0) return n;
    if (entry_id.len > 0) return entry_id;
    return std.fmt.allocPrint(arena, "mac-window-{d}", .{index});
}

// =============================================================================
// Tree walking
// =============================================================================

/// Append `v`'s subtree to `out` and return the index it took. Splits reserve
/// their own slot BEFORE recursing, so `nodes[0]` is the root and a child index
/// is always greater than its parent's — the invariant the win32 rebuild reads.
fn flatten(
    arena: Allocator,
    v: std.json.Value,
    out: *std.ArrayList(session_layout.Node),
    depth: usize,
) !u16 {
    if (depth > max_depth) return error.TreeTooDeep;
    const obj = switch (v) {
        .object => |o| o,
        else => return error.MalformedTree,
    };

    if (unwrapCase(obj.get("leaf"))) |leaf_val| {
        const idx = try reserve(arena, out);
        out.items[idx].leaf = leafFrom(leaf_val);
        return idx;
    }

    if (unwrapCase(obj.get("split"))) |split_val| {
        const sobj = switch (split_val) {
            .object => |o| o,
            else => return error.MalformedTree,
        };
        const idx = try reserve(arena, out);
        const left = try flatten(arena, sobj.get("left") orelse return error.MalformedTree, out, depth + 1);
        const right = try flatten(arena, sobj.get("right") orelse return error.MalformedTree, out, depth + 1);
        out.items[idx].split = .{
            .layout = layoutName(str(sobj.get("direction"))),
            .ratio = ratioFrom(sobj.get("ratio")),
            .left = left,
            .right = right,
        };
        return idx;
    }

    return error.MalformedTree;
}

fn reserve(arena: Allocator, out: *std.ArrayList(session_layout.Node)) !u16 {
    if (out.items.len >= max_nodes) return error.TreeTooLarge;
    const idx: u16 = @intCast(out.items.len);
    try out.append(arena, .{});
    return idx;
}

/// Unwrap Swift's synthesized enum payload. `JSONEncoder` writes a case with one
/// unlabeled associated value as `{"leaf":{"_0":{…}}}` (SE-0295), so the real
/// object is one level down — but the plain `{"leaf":{…}}` spelling is accepted
/// too, exactly as the E2E harness's reader does
/// (`scripts/e2e/session-persistence.py`), so a hand-written or future-shaped
/// blob still reads.
fn unwrapCase(v: ?std.json.Value) ?std.json.Value {
    const val = v orelse return null;
    const obj = switch (val) {
        .null => return null,
        .object => |o| o,
        else => return val,
    };
    if (obj.get("_0")) |inner| return inner;
    return val;
}

/// One pane. The WP-D3 pair (`screenSnapshot`/`screenSnapshotOffset`) is
/// deliberately NOT mapped — see the header.
fn leafFrom(v: std.json.Value) session_layout.Leaf {
    const obj = switch (v) {
        .object => |o| o,
        else => return .{},
    };
    return .{
        .session_id = str(obj.get("sessionID")),
        .title = str(obj.get("title")),
        .ipc_name = str(obj.get("ipcName")),
        // Mac's surface uuid IS the pane's stable ghoztty-owned id — the value
        // baked into the still-running shell as `$GHOZTTY_PANE_ID`. It has to
        // round-trip or the re-attached pane cannot address itself.
        .pane_id = str(obj.get("surfaceID")),
        .banner = str(obj.get("banner")),
        .kind = str(obj.get("kind")),
        .viewer_location = str(obj.get("viewerLocation")),
        .viewer_home_location = str(obj.get("viewerHomeLocation")),
        .viewer_origin_directory = str(obj.get("viewerOriginDirectory")),
    };
}

// =============================================================================
// Scalars
// =============================================================================

/// A present, non-empty string, else null. Empty is folded into absent on
/// purpose: an empty `sessionID` is not something to attach to, and an empty
/// title is not a title.
fn str(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

fn int(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(std.math.clamp(f, -1e15, 1e15)) else null,
        else => null,
    };
}

fn num(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Mac's `{x, y, width, height}` doubles as a win32 `Frame`. A frame with no
/// usable SIZE is dropped outright — a zero-extent window restores invisible and
/// reports success — while the ORIGIN is passed through unconverted (header).
fn frameFrom(v: ?std.json.Value) ?session_layout.Frame {
    const obj = switch (v orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const w = num(obj.get("width")) orelse return null;
    const h = num(obj.get("height")) orelse return null;
    if (w <= 0 or h <= 0) return null;
    return .{
        .x = toI32(num(obj.get("x")) orelse 0),
        .y = toI32(num(obj.get("y")) orelse 0),
        .w = toI32(w),
        .h = toI32(h),
    };
}

/// Saturating f64 → i32. A blob is not a trusted input, and `@intFromFloat` on
/// an out-of-range value is illegal behavior, not a wrap.
fn toI32(v: f64) i32 {
    if (!std.math.isFinite(v)) return 0;
    const limit = 1_000_000.0;
    return @intFromFloat(@round(std.math.clamp(v, -limit, limit)));
}

/// `"vertical"` stays vertical; anything else — including an absent or garbled
/// direction — is horizontal, which is the core `SplitTree.Split.Layout` default
/// spelling both lineages write. Returned as a static string, so it outlives any
/// arena.
fn layoutName(direction: ?[]const u8) []const u8 {
    const d = direction orelse return "horizontal";
    return if (std.mem.eql(u8, d, "vertical")) "vertical" else "horizontal";
}

/// The left/top child's share. Out-of-range or absent falls back to an even
/// split rather than a degenerate pane the user cannot see or grab.
fn ratioFrom(v: ?std.json.Value) f32 {
    const r = num(v) orelse return 0.5;
    if (!(r > 0.0 and r < 1.0)) return 0.5;
    return @floatCast(r);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Parse `bytes` and translate it, asserting it was recognized as a Mac entry.
fn translate(arena: Allocator, bytes: []const u8) !Entry {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{
        .allocate = .alloc_always,
    });
    try testing.expect(looksLikeEntry(v));
    return parseEntry(arena, v);
}

/// A real-shaped two-pane Mac blob: one horizontal split over two terminal
/// leaves, encoded the way `JSONEncoder` writes the indirect enum.
const two_pane_blob =
    \\{"id":"1D0A0B0C-0000-4000-8000-000000000001",
    \\ "frame":{"x":120,"y":300,"width":1440,"height":900},
    \\ "titleOverride":"editor","ipcName":"dev","tabIndex":0,
    \\ "tree":{"split":{"_0":{"direction":"vertical","ratio":0.25,
    \\   "left":{"leaf":{"_0":{"sessionID":"aaaa","title":"left","surfaceID":"pane-a"}}},
    \\   "right":{"leaf":{"_0":{"sessionID":"bbbb","ipcName":"logs"}}}}}}}
;

test "T337: a macOS blob is recognized by shape and a win32 one is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mac = try std.json.parseFromSliceLeaky(std.json.Value, arena, two_pane_blob, .{});
    try testing.expect(looksLikeEntry(mac));

    // The win32 shape: `tabs`, never `tree`.
    const win = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"id":"win-0","tabs":[{"nodes":[{"leaf":{"session_id":"a"}}]}]}
    , .{});
    try testing.expect(!looksLikeEntry(win));

    // Neither shape: a scalar, an array, an empty object, a `tree` that is not
    // an object. All must be left for the win32 decoder to reject.
    for ([_][]const u8{ "7", "\"x\"", "[]", "{}", "{\"tree\":null}", "{\"tree\":3}" }) |bytes| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
        try testing.expect(!looksLikeEntry(v));
    }

    // A blob carrying BOTH is a win32 window: `tabs` is what its rebuild reads.
    const both = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"tabs":[],"tree":{"leaf":{"_0":{}}}}
    , .{});
    try testing.expect(!looksLikeEntry(both));
}

test "T337: a nested Mac tree flattens to win32's indexed nodes array" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = try translate(arena, two_pane_blob);
    try testing.expectEqualStrings("1D0A0B0C-0000-4000-8000-000000000001", entry.id);
    try testing.expectEqualStrings("dev", entry.ipc_name.?);
    try testing.expectEqualStrings("editor", entry.tab_title.?);
    try testing.expect(entry.window_title == null);
    try testing.expect(entry.tab_group_id == null);

    // Size translates exactly; the origin rides through unconverted.
    try testing.expectEqual(@as(i32, 1440), entry.frame.?.w);
    try testing.expectEqual(@as(i32, 900), entry.frame.?.h);
    try testing.expectEqual(@as(i32, 120), entry.frame.?.x);
    try testing.expectEqual(@as(i32, 300), entry.frame.?.y);

    // root, left, right — root first, children after it.
    try testing.expectEqual(@as(usize, 3), entry.nodes.len);
    const root = entry.nodes[0].split.?;
    try testing.expectEqualStrings("vertical", root.layout);
    try testing.expectApproxEqAbs(@as(f32, 0.25), root.ratio, 0.0001);
    try testing.expectEqual(@as(u16, 1), root.left);
    try testing.expectEqual(@as(u16, 2), root.right);
    try testing.expect(entry.nodes[0].leaf == null);

    const left = entry.nodes[1].leaf.?;
    try testing.expectEqualStrings("aaaa", left.session_id.?);
    try testing.expectEqualStrings("left", left.title.?);
    try testing.expectEqualStrings("pane-a", left.pane_id.?);
    const right = entry.nodes[2].leaf.?;
    try testing.expectEqualStrings("bbbb", right.session_id.?);
    try testing.expectEqualStrings("logs", right.ipc_name.?);
    try testing.expect(right.title == null);
}

test "T337: a deeper tree keeps every child index above its parent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // split( split(a, b), c ) — the left subtree is walked whole before `c`.
    const entry = try translate(arena,
        \\{"id":"e","tree":{"split":{"_0":{"direction":"horizontal","ratio":0.6,
        \\ "left":{"split":{"_0":{"direction":"vertical","ratio":0.5,
        \\   "left":{"leaf":{"_0":{"sessionID":"a"}}},
        \\   "right":{"leaf":{"_0":{"sessionID":"b"}}}}}},
        \\ "right":{"leaf":{"_0":{"sessionID":"c"}}}}}}}
    );

    try testing.expectEqual(@as(usize, 5), entry.nodes.len);
    const root = entry.nodes[0].split.?;
    try testing.expectEqual(@as(u16, 1), root.left);
    try testing.expectEqual(@as(u16, 4), root.right);
    const inner = entry.nodes[1].split.?;
    try testing.expectEqual(@as(u16, 2), inner.left);
    try testing.expectEqual(@as(u16, 3), inner.right);
    try testing.expectEqualStrings("a", entry.nodes[2].leaf.?.session_id.?);
    try testing.expectEqualStrings("b", entry.nodes[3].leaf.?.session_id.?);
    try testing.expectEqualStrings("c", entry.nodes[4].leaf.?.session_id.?);

    for (entry.nodes) |node| {
        const s = node.split orelse continue;
        try testing.expect(s.left > 0 and s.right > 0);
    }
}

test "T337: a single-leaf tree is one node, with or without the _0 wrapper" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wrapped = try translate(arena,
        \\{"id":"e","tree":{"leaf":{"_0":{"sessionID":"solo"}}}}
    );
    try testing.expectEqual(@as(usize, 1), wrapped.nodes.len);
    try testing.expectEqualStrings("solo", wrapped.nodes[0].leaf.?.session_id.?);

    // The unwrapped spelling the E2E harness also accepts.
    const bare = try translate(arena,
        \\{"id":"e","tree":{"leaf":{"sessionID":"solo"}}}
    );
    try testing.expectEqual(@as(usize, 1), bare.nodes.len);
    try testing.expectEqualStrings("solo", bare.nodes[0].leaf.?.session_id.?);
}

test "T337: a viewer leaf keeps every field its restore re-opens from" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = try translate(arena,
        \\{"id":"e","tree":{"leaf":{"_0":{"kind":"viewer",
        \\ "viewerLocation":"https://example.com/now",
        \\ "viewerHomeLocation":"https://example.com",
        \\ "viewerOriginDirectory":"/Users/x/repo","surfaceID":"pane-v"}}}}
    );
    const leaf = entry.nodes[0].leaf.?;
    try testing.expect(leaf.isViewer());
    try testing.expectEqualStrings("https://example.com/now", leaf.viewer_location.?);
    try testing.expectEqualStrings("https://example.com", leaf.viewer_home_location.?);
    try testing.expectEqualStrings("/Users/x/repo", leaf.viewer_origin_directory.?);
    try testing.expectEqualStrings("pane-v", leaf.pane_id.?);
    try testing.expect(leaf.session_id == null);
}

test "T337: the WP-D3 snapshot pair is dropped, and a banner is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Mac's `layoutBlob` encodes the whole entry, snapshots included — unlike
    // win32's `serializeWindow`, which strips its own. Painting another viewer's
    // screen into this pane, and attaching at that viewer's stale offset, is the
    // failure T413 made unreachable on the win32 side; it must stay unreachable
    // when the blob came from a Mac.
    const entry = try translate(arena,
        \\{"id":"e","tree":{"leaf":{"_0":{"sessionID":"a","banner":"**build** ok",
        \\ "screenSnapshot":"SU5WSVNJQkxF","screenSnapshotOffset":9001}}}}
    );
    const leaf = entry.nodes[0].leaf.?;
    try testing.expect(leaf.screen_snapshot == null);
    try testing.expect(leaf.screen_snapshot_offset == null);
    try testing.expectEqualStrings("**build** ok", leaf.banner.?);
}

test "T337: a malformed tree fails the entry rather than half-building it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_][]const u8{
        // A node that is neither leaf nor split.
        \\{"id":"e","tree":{"branch":{"_0":{}}}}
        ,
        // A split missing a child.
        \\{"id":"e","tree":{"split":{"_0":{"direction":"horizontal","ratio":0.5,
        \\ "left":{"leaf":{"_0":{}}}}}}}
        ,
        // A child that is not an object.
        \\{"id":"e","tree":{"split":{"_0":{"direction":"horizontal","ratio":0.5,
        \\ "left":7,"right":{"leaf":{"_0":{}}}}}}}
        ,
        // A leaf whose payload is a scalar still yields a (bare) leaf, but a
        // split whose payload is a scalar cannot be walked.
        \\{"id":"e","tree":{"split":{"_0":7}}}
        ,
    };
    for (cases) |bytes| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
        try testing.expect(looksLikeEntry(v));
        try testing.expectError(error.MalformedTree, parseEntry(arena, v));
    }
}

test "T337: a pathologically deep tree is refused, not recursed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    const depth = max_depth + 8;
    try body.appendSlice(testing.allocator, "{\"id\":\"e\",\"tree\":");
    for (0..depth) |_| {
        try body.appendSlice(testing.allocator,
            \\{"split":{"_0":{"direction":"horizontal","ratio":0.5,"left":
        );
    }
    try body.appendSlice(testing.allocator,
        \\{"leaf":{"_0":{}}}
    );
    for (0..depth) |_| {
        try body.appendSlice(testing.allocator,
            \\,"right":{"leaf":{"_0":{}}}}}}
        );
    }
    try body.appendSlice(testing.allocator, "}");

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body.items, .{});
    try testing.expectError(error.TreeTooDeep, parseEntry(arena, v));
}

test "T337: bad scalars fall back instead of failing the window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = try translate(arena,
        \\{"tree":{"split":{"_0":{"direction":"sideways","ratio":9.5,
        \\ "left":{"leaf":{"_0":{"sessionID":""}}},
        \\ "right":{"leaf":{"_0":{"sessionID":"b"}}}}}},
        \\ "frame":{"x":0,"y":0,"width":0,"height":600},
        \\ "titleOverride":"","tabIndex":"nope"}
    );
    // An unknown direction is horizontal, an impossible ratio is an even split.
    try testing.expectEqualStrings("horizontal", entry.nodes[0].split.?.layout);
    try testing.expectApproxEqAbs(@as(f32, 0.5), entry.nodes[0].split.?.ratio, 0.0001);
    // A zero-extent frame is dropped rather than restored invisible.
    try testing.expect(entry.frame == null);
    // Empty strings are absent, not empty values.
    try testing.expect(entry.nodes[1].leaf.?.session_id == null);
    try testing.expect(entry.tab_title == null);
    try testing.expectEqual(@as(i64, 0), entry.tab_index);
    try testing.expectEqualStrings("", entry.id);
}

test "T337: tab siblings become one window in tabIndex order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const gid = "GGGGGGGG-0000-4000-8000-000000000001";
    const second = try translate(arena,
        \\{"id":"e2","tabGroupID":"GGGGGGGG-0000-4000-8000-000000000001",
        \\ "tabIndex":1,"titleOverride":"second",
        \\ "tree":{"leaf":{"_0":{"sessionID":"bbbb"}}}}
    );
    const first = try translate(arena,
        \\{"id":"e1","tabGroupID":"GGGGGGGG-0000-4000-8000-000000000001",
        \\ "tabIndex":0,"titleOverride":"first","ipcName":"dev",
        \\ "windowTitleOverride":"pinned",
        \\ "frame":{"x":10,"y":20,"width":800,"height":600},
        \\ "tree":{"leaf":{"_0":{"sessionID":"aaaa"}}}}
    );
    const standalone = try translate(arena,
        \\{"id":"e3","tree":{"leaf":{"_0":{"sessionID":"cccc"}}}}
    );
    try testing.expectEqualStrings(gid, first.tab_group_id.?);

    // Reply order puts the SECOND tab first; the group still sorts by tabIndex
    // and still takes the position its first-seen entry had.
    const windows = try groupIntoWindows(arena, &.{ second, first, standalone });
    try testing.expectEqual(@as(usize, 2), windows.len);

    const grouped = windows[0];
    try testing.expectEqualStrings("dev", grouped.id);
    try testing.expectEqualStrings("dev", grouped.ipc_name.?);
    try testing.expectEqualStrings("pinned", grouped.title_override.?);
    try testing.expectEqual(@as(i32, 800), grouped.frame.?.w);
    try testing.expectEqual(@as(usize, 2), grouped.tabs.len);
    try testing.expectEqualStrings("first", grouped.tabs[0].title.?);
    try testing.expectEqualStrings("second", grouped.tabs[1].title.?);
    try testing.expect(grouped.tabs[0].active);
    try testing.expect(!grouped.tabs[1].active);
    try testing.expectEqual(@as(u32, 0), grouped.active_tab);
    try testing.expectEqualStrings("aaaa", grouped.tabs[0].nodes[0].leaf.?.session_id.?);
    try testing.expectEqualStrings("bbbb", grouped.tabs[1].nodes[0].leaf.?.session_id.?);
    // Never adopt the Mac window's key — this copy must not overwrite it.
    try testing.expect(grouped.uuid == null);

    const alone = windows[1];
    try testing.expectEqualStrings("e3", alone.id);
    try testing.expectEqual(@as(usize, 1), alone.tabs.len);
}

test "T337: two standalone entries never merge, and an id-less one still names itself" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No tabGroupID on either: they are separate windows, not one two-tab window.
    const a = try translate(arena,
        \\{"id":"e1","tree":{"leaf":{"_0":{"sessionID":"a"}}}}
    );
    const b = try translate(arena,
        \\{"tree":{"leaf":{"_0":{"sessionID":"b"}}}}
    );
    const windows = try groupIntoWindows(arena, &.{ a, b });
    try testing.expectEqual(@as(usize, 2), windows.len);
    try testing.expectEqualStrings("e1", windows[0].id);
    try testing.expectEqualStrings("mac-window-1", windows[1].id);
}

test "T337: grouping an empty set is an empty set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const windows = try groupIntoWindows(arena, &.{});
    try testing.expectEqual(@as(usize, 0), windows.len);
}
