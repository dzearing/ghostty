//! Viewer-side session-layout manifest — the win32 port of the macOS
//! `SessionLayoutManifest` (`macos/Sources/Features/Remote/
//! SessionLayoutManifest.swift`). This is the LOCAL, same-host restore file
//! the GUI writes so that after a quit / logoff / reboot the next launch can
//! rebuild its windows/tabs/splits and re-ATTACH each pane to the session the
//! local `ghoztty-agent` kept alive (T89d/T89e). It is the app's OWN copy;
//! the agent's crash-durable `layout_meta.zig` blob store is the separate
//! cross-machine path (§5.4/T18) and is not involved here.
//!
//! Layering: like `layout_meta.zig`/`session_meta.zig`/`tab_color.zig`, this
//! module depends on nothing but `std` (+ `builtin` for the debug-file split),
//! so it compiles and unit-tests in every app-runtime lane. The topology WALK
//! that reads live `Window`/`Surface` state lives in `App.zig`
//! (`syncSessionLayout`); this module owns the schema and the bytes on disk.
//! The RESTORE reader (probe → rebuild → ATTACH) is T89f2.
//!
//! ## On-disk shape
//!
//!   {"version":1,"windows":[
//!     {"id":"win-0","uuid":"<uuid>","frame":{"x":..,"y":..,"w":..,"h":..},
//!      "maximized":false,
//!      "title_override":..?,"ipc_name":..?,"active_tab":0,
//!      "tabs":[{"nodes":[{"split":{"layout":"horizontal","ratio":0.5,
//!                                  "left":1,"right":2}},
//!                        {"leaf":{"session_id":"<32hex>","pane_id":"<uuid>",
//!                                 "title":..?}},
//!                        {"leaf":{"session_id":"<32hex>"}}],
//!               "color":"blue"?,"hero_ratio":..?,"title":..?,"active":true}]}]}
//!
//! Keys are the Zig field names verbatim (snake_case). This file is the win32
//! app's private local-restore state and is never decoded by the macOS app
//! (which keeps its own Application Support manifest), so there is no
//! cross-lineage key-compatibility constraint — only the additive within-win32
//! one below.
//!
//! The split tree is stored FLAT (a `nodes` array, index 0 = root) with child
//! `left`/`right` as indices into that same array — this mirrors the internal
//! `SplitTree(V).nodes` representation exactly, so capture is a 1:1 index copy
//! and restore a 1:1 rebuild, and it sidesteps recursive-pointer JSON. A `Node`
//! is a plain object with two mutually-exclusive optional members (`leaf` /
//! `split`) rather than a tagged union, so the JSON needs no union-tag handling.
//!
//! ## Crash safety
//!
//! `writeAtomic` uses the same tmp-in-the-same-dir + fsync + rename recipe as
//! `layout_meta.writeAtomic`. Every field an older/newer build doesn't know is
//! ignored on read (`ignore_unknown_fields`), and absent optionals fall back —
//! the additive-evolution contract the whole app↔agent boundary follows.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// On-disk schema version. Bumped only on an INCOMPATIBLE change; additive
/// fields (readers tolerate unknown + absent) need no bump.
pub const format_version: u32 = 1;

/// A hard ceiling on the file we will read back. A layout is a handful of
/// windows, each a small split tree of session ids + titles; 8 MiB comfortably
/// holds the agent's 256-session cap worth and rejects an implausibly large
/// file as corrupt rather than reading it into memory.
pub const max_file_bytes: usize = 8 * 1024 * 1024;

/// Per-pane ceiling on an encoded WP-D3 screen snapshot (T109). A 600-row VT
/// repaint of an ordinary pane is a few tens of KiB; a pane full of per-cell SGR
/// at a huge width can be much more. Anything past this is dropped for that pane
/// (it falls back to the full-ring replay) rather than allowed to dominate the file.
pub const screen_snapshot_max_pane_bytes: usize = 256 * 1024;

/// Whole-file ceiling on encoded snapshots, well under `max_file_bytes` so the
/// TOPOLOGY always fits. This is the load-bearing half of the budget: the
/// snapshot is an optimization, but a manifest that grew past `max_file_bytes`
/// would fail to load at all and cost the user every window. Snapshots are
/// therefore taken first-come (tree order) until the budget runs out; the panes
/// that miss out restore exactly as they did before T109.
pub const screen_snapshot_total_bytes: usize = 3 * 1024 * 1024;

/// Tracks encoded-snapshot bytes across ONE capture pass. Pure arithmetic so the
/// none-runtime lane can assert the two ceilings without a live surface.
pub const SnapshotBudget = struct {
    used: usize = 0,

    /// Claim `encoded_len` bytes for one pane's snapshot. True ⇒ the caller may
    /// record it (and the bytes are now spent); false ⇒ the pane is over the
    /// per-pane ceiling or the file budget is exhausted, so it records nothing.
    /// A rejected claim spends nothing, so a single huge pane cannot starve the
    /// smaller ones behind it.
    pub fn take(self: *SnapshotBudget, encoded_len: usize) bool {
        if (encoded_len == 0) return false;
        if (encoded_len > screen_snapshot_max_pane_bytes) return false;
        if (encoded_len > screen_snapshot_total_bytes - self.used) return false;
        self.used += encoded_len;
        return true;
    }
};

/// Outer window rectangle in screen pixels (matches the Mac `Frame`). For a
/// maximized window this is the restored ("normal") rect; `maximized` records
/// that it should come back maximized (T85 parity).
pub const Frame = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// One split-tree leaf: a terminal or a viewer pane.
/// `session_id` is the agent session to re-ATTACH to on restore (null when the
/// pane was not agent-backed — it restores as an exited pane, tree shape
/// preserved, matching the Mac null-sessionID behavior).
///
/// The four `kind`/`viewer_*` fields describe a VIEWER leaf (T90h, design P12);
/// a terminal leaf leaves all four null, so an ABSENT `kind` means terminal and
/// a manifest written before viewers existed keeps loading unchanged. They are
/// what a viewer restores from — it has no agent session to attach to, so
/// re-opening its location IS its restore:
///
///   * `viewer_location` — where the pane currently IS (it may have navigated
///     away from where it was opened).
///   * `viewer_home_location` — where it was OPENED, the Home button's target.
///     Persisted separately because restore navigates to `viewer_location` and
///     would otherwise silently re-home the pane to wherever it had wandered.
///   * `viewer_origin_directory` — the directory the pane was opened FROM
///     (`--working-directory`, which `+split --view=`/`+new-window --view=`
///     seed with the caller's cwd). This is the worktree-provenance fallback
///     for a pane whose location names no directory of its own — a website or a
///     blank page — so it cannot be re-derived from the location on restore.
///
/// `screen_snapshot` + `screen_snapshot_offset` are the WP-D3 fast re-attach
/// pair (T109): the pane's own structured VT repaint of its screen (base64) and
/// the absolute agent-stream byte offset that repaint reflects. On restore the
/// pane paints the snapshot for an instant, correctly-sized frame and ATTACHes
/// at the offset, so the agent gap-fills only `(offset, S]` instead of replaying
/// its whole retained ring. The ring is a CONCATENATION of segments drawn at
/// different geometries (every attach resize makes conhost append a fresh paint
/// at the new size), so a full-ring replay parsed at any single geometry is
/// faithful only to its own segments — which is the loss this pair removes.
/// Additive and optional in the usual way: a pre-T109 manifest, a viewer leaf, a
/// pane that never produced output, or a snapshot the budget below dropped all
/// decode as null and fall back to the full-ring replay.
///
/// `pane_id` is the pane's stable ghoztty-owned identity (T113) — the value
/// baked into its shell as `$GHOZTTY_PANE_ID`. It MUST round-trip: the
/// re-attached (or agent-RELAUNCHed) process keeps the env it was spawned
/// with, so a restore that generated a fresh id would leave the pane unable to
/// address itself. Additive and optional — a manifest written by a pre-T113
/// build simply has none and its restored panes get fresh ids.
pub const Leaf = struct {
    session_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    ipc_name: ?[]const u8 = null,
    pane_id: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    viewer_location: ?[]const u8 = null,
    viewer_home_location: ?[]const u8 = null,
    viewer_origin_directory: ?[]const u8 = null,
    screen_snapshot: ?[]const u8 = null,
    screen_snapshot_offset: ?u64 = null,

    /// Whether this leaf describes a VIEWER pane. Absent `kind` ⇒ terminal, so
    /// this is also the compatibility rule for a pre-viewer manifest. One
    /// reader for it, rather than an `eql` at every restore site that would
    /// each have to remember which spelling is the viewer one.
    pub fn isViewer(self: Leaf) bool {
        const k = self.kind orelse return false;
        return std.mem.eql(u8, k, kind_viewer);
    }
};

/// The `Leaf.kind` value for a viewer pane. Written by capture, matched by
/// restore; the terminal kind has no spelling at all (absent means terminal).
pub const kind_viewer = "viewer";

/// One split-tree internal node. `layout` is `"horizontal"` / `"vertical"`
/// (the `SplitTree.Split.Layout` tag name); `ratio` is the left/top child's
/// share (the `f16` tree ratio widened to `f32` for JSON); `left`/`right` are
/// indices into the owning `Tab.nodes` array.
pub const Split = struct {
    layout: []const u8,
    ratio: f32,
    left: u16,
    right: u16,
};

/// A flat split-tree node: EXACTLY one of `leaf`/`split` is non-null (capture
/// always sets one). Kept as two optionals rather than a tagged union so the
/// on-disk JSON is a plain object and needs no union-tag handling on read.
pub const Node = struct {
    leaf: ?Leaf = null,
    split: ?Split = null,

    pub fn isLeaf(self: Node) bool {
        return self.leaf != null;
    }
};

/// One tab: its split tree (flat, `nodes[0]` = root; a single-pane tab is one
/// leaf), plus per-tab presentation state (color T72, hero carousel ratio T59,
/// a pinned tab title T92). `active` marks the tab that was frontmost.
pub const Tab = struct {
    nodes: []const Node = &.{},
    color: ?[]const u8 = null,
    hero_ratio: ?f32 = null,
    title: ?[]const u8 = null,
    active: bool = false,
};

/// One window: outer placement, the window-level title pin (T92), its IPC name
/// (`+new-window --target`), the active tab index, and its tabs in order.
///
/// `id` identifies the window WITHIN one file: the IPC name when it has one,
/// else `win-{index}`. It is deliberately NOT stable across app runs — the
/// auto IPC name (`window-N`) and the index both restart per process — so it
/// may only ever be used to tell this file's windows apart.
///
/// `uuid` is the window's stable identity ACROSS runs (T338): generated once
/// when the window is created and re-adopted by every restore, so a key derived
/// from it still names the same window after a quit, a crash, or a rebuild.
/// That is what the agent-side layout blob is keyed on — with `id` as the key,
/// the relaunched app's blank startup window took the dead run's key and
/// silently overwrote the topology "Restore All" exists to read. Additive and
/// optional: a manifest written by a pre-T338 build has none, and the reader
/// falls back to `id` exactly as before.
pub const Window = struct {
    id: []const u8,
    uuid: ?[]const u8 = null,
    frame: ?Frame = null,
    maximized: bool = false,
    title_override: ?[]const u8 = null,
    ipc_name: ?[]const u8 = null,
    active_tab: u32 = 0,
    tabs: []const Tab = &.{},
};

/// The whole file. `windows` is a present (possibly empty) array so a reader
/// distinguishes "no windows to restore" from a corrupt/absent file.
pub const File = struct {
    version: u32 = format_version,
    windows: []const Window = &.{},
};

/// A parsed file whose backing memory (including every string) is owned by the
/// embedded arena; `deinit()` frees it all.
pub const Parsed = std.json.Parsed(File);

/// Drop absent optionals from the output so the file stays small and an older
/// build never sees a `null` where it expects a value — the additive-evolution
/// contract (readers tolerate both unknown and absent fields).
const stringify_opts: std.json.Stringify.Options = .{
    .emit_null_optional_fields = false,
};

/// Serialize `file` into the on-disk JSON body. Caller frees.
pub fn serialize(alloc: Allocator, file: File) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, file, stringify_opts);
}

/// Parse an on-disk body. The returned `Parsed` owns its strings; caller
/// `deinit`s it. Unknown fields are ignored (newer/older interop). Strings are
/// copied into the arena (`alloc_always`) so the file buffer can be freed
/// immediately.
pub fn parse(alloc: Allocator, bytes: []const u8) !Parsed {
    return std.json.parseFromSlice(File, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Atomically write `bytes` to `path` via a same-directory tmp + fsync +
/// rename (creating parent directories as needed). Mirrors
/// `layout_meta.writeAtomic`.
pub fn writeAtomic(alloc: Allocator, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    {
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
    try std.fs.cwd().rename(tmp_path, path);
}

/// Load + parse the file at `path`. Returns null when ABSENT (normal — a first
/// start, or persistence was off). Any other I/O or parse failure propagates.
/// Caller `deinit`s a non-null result.
pub fn load(alloc: Allocator, path: []const u8) !?Parsed {
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(bytes);
    return try parse(alloc, bytes);
}

/// Resolve `%LOCALAPPDATA%\ghoztty\session-layout[-debug].json`. Caller frees.
/// Null when `%LOCALAPPDATA%` is unset (never on a real Windows session) or the
/// join fails. Debug builds get their own file — the same coexistence pattern
/// as the debug IPC pipe and `window_memory` — so test/dev never clobbers the
/// release app's restore state.
pub fn layoutPath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const name = if (builtin.mode == .Debug)
        "session-layout-debug.json"
    else
        "session-layout.json";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// Best-effort persist of `file` to the default path. Failures are swallowed —
/// the manifest is a convenience, never worth an error dialog (window_memory
/// parity). An empty window set deletes the file rather than leaving a stale
/// one that would restore nothing (Mac `saveLocked` parity).
pub fn write(alloc: Allocator, file: File) void {
    const path = layoutPath(alloc) orelse return;
    defer alloc.free(path);
    if (file.windows.len == 0) {
        std.fs.cwd().deleteFile(path) catch {};
        return;
    }
    const body = serialize(alloc, file) catch return;
    defer alloc.free(body);
    writeAtomic(alloc, path, body) catch {};
}

/// Delete the manifest (persistence turned off, or nothing to restore).
/// Best-effort; a missing file is success.
pub fn clear(alloc: Allocator) void {
    const path = layoutPath(alloc) orelse return;
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "serialize + parse round-trip preserves windows, tabs, tree, order" {
    const alloc = testing.allocator;

    // A two-tab window: tab 0 is a horizontal split of two leaves, tab 1 is a
    // single leaf. Plus a second single-pane window.
    const tab0_nodes = [_]Node{
        .{ .split = .{ .layout = "horizontal", .ratio = 0.5, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session_id = "0123456789abcdef0123456789abcdef", .title = "left" } },
        .{ .leaf = .{ .session_id = "fedcba9876543210fedcba9876543210", .ipc_name = "logs" } },
    };
    const tab1_nodes = [_]Node{
        .{ .leaf = .{ .session_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } },
    };
    const w0_tabs = [_]Tab{
        .{ .nodes = &tab0_nodes, .color = "blue", .hero_ratio = 0.3, .active = true },
        .{ .nodes = &tab1_nodes, .title = "pinned" },
    };
    const w1_nodes = [_]Node{
        .{ .leaf = .{ .session_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" } },
    };
    const w1_tabs = [_]Tab{.{ .nodes = &w1_nodes, .active = true }};
    const windows = [_]Window{
        .{
            .id = "win-0",
            .frame = .{ .x = 10, .y = 20, .w = 800, .h = 600 },
            .maximized = false,
            .title_override = "My Window",
            .ipc_name = "dev",
            .active_tab = 0,
            .tabs = &w0_tabs,
        },
        .{
            .id = "win-1",
            .frame = .{ .x = -5, .y = 0, .w = 1024, .h = 768 },
            .maximized = true,
            .active_tab = 0,
            .tabs = &w1_tabs,
        },
    };
    const file: File = .{ .windows = &windows };

    const body = try serialize(alloc, file);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"version\":1") != null);
    // emit_null_optional_fields=false: absent optionals are dropped.
    try testing.expect(std.mem.indexOf(u8, body, "\"viewer_location\"") == null);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const v = parsed.value;
    try testing.expectEqual(@as(u32, 1), v.version);
    try testing.expectEqual(@as(usize, 2), v.windows.len);

    const w0 = v.windows[0];
    try testing.expectEqualStrings("win-0", w0.id);
    try testing.expect(w0.frame != null);
    try testing.expectEqual(@as(i32, 10), w0.frame.?.x);
    try testing.expectEqual(@as(i32, 600), w0.frame.?.h);
    try testing.expect(!w0.maximized);
    try testing.expectEqualStrings("My Window", w0.title_override.?);
    try testing.expectEqualStrings("dev", w0.ipc_name.?);
    try testing.expectEqual(@as(usize, 2), w0.tabs.len);

    const t0 = w0.tabs[0];
    try testing.expect(t0.active);
    try testing.expectEqualStrings("blue", t0.color.?);
    try testing.expectApproxEqAbs(@as(f32, 0.3), t0.hero_ratio.?, 0.001);
    try testing.expectEqual(@as(usize, 3), t0.nodes.len);
    // Root is the split.
    try testing.expect(!t0.nodes[0].isLeaf());
    const sp = t0.nodes[0].split.?;
    try testing.expectEqualStrings("horizontal", sp.layout);
    try testing.expectApproxEqAbs(@as(f32, 0.5), sp.ratio, 0.001);
    try testing.expectEqual(@as(u16, 1), sp.left);
    try testing.expectEqual(@as(u16, 2), sp.right);
    // Children are leaves with their session ids preserved in order.
    try testing.expect(t0.nodes[1].isLeaf());
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", t0.nodes[1].leaf.?.session_id.?);
    try testing.expectEqualStrings("left", t0.nodes[1].leaf.?.title.?);
    try testing.expectEqualStrings("logs", t0.nodes[2].leaf.?.ipc_name.?);

    const t1 = w0.tabs[1];
    try testing.expect(!t1.active);
    try testing.expectEqualStrings("pinned", t1.title.?);
    try testing.expectEqual(@as(usize, 1), t1.nodes.len);
    try testing.expect(t1.nodes[0].isLeaf());

    const w1 = v.windows[1];
    try testing.expectEqualStrings("win-1", w1.id);
    try testing.expect(w1.maximized);
    try testing.expect(w1.title_override == null);
}

test "T109: screen snapshot + offset round-trip, and are absent when unset" {
    const alloc = testing.allocator;

    const nodes = [_]Node{
        .{ .leaf = .{
            .session_id = "0123456789abcdef0123456789abcdef",
            .screen_snapshot = "G1tIG1tKaGVsbG8=",
            .screen_snapshot_offset = 4_294_967_296, // > u32, so u64 is load-bearing
        } },
        .{ .leaf = .{ .session_id = "fedcba9876543210fedcba9876543210" } },
    };
    const tabs = [_]Tab{.{ .nodes = &nodes, .active = true }};
    const windows = [_]Window{.{ .id = "win-0", .tabs = &tabs }};

    const body = try serialize(alloc, .{ .windows = &windows });
    defer alloc.free(body);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const leaves = parsed.value.windows[0].tabs[0].nodes;
    try testing.expectEqualStrings("G1tIG1tKaGVsbG8=", leaves[0].leaf.?.screen_snapshot.?);
    try testing.expectEqual(@as(u64, 4_294_967_296), leaves[0].leaf.?.screen_snapshot_offset.?);
    // A leaf that recorded none stays null — that is the full-ring fallback.
    try testing.expect(leaves[1].leaf.?.screen_snapshot == null);
    try testing.expect(leaves[1].leaf.?.screen_snapshot_offset == null);
}

test "T109: a pre-snapshot manifest still loads, with null snapshot fields" {
    const alloc = testing.allocator;
    const body =
        \\{"version":1,"windows":[{"id":"win-0","active_tab":0,
        \\"tabs":[{"nodes":[{"leaf":{"session_id":"aaaa","pane_id":"p"}}],"active":true}]}]}
    ;
    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const leaf = parsed.value.windows[0].tabs[0].nodes[0].leaf.?;
    try testing.expectEqualStrings("aaaa", leaf.session_id.?);
    try testing.expect(leaf.screen_snapshot == null);
    try testing.expect(leaf.screen_snapshot_offset == null);
}

test "T109: snapshot budget rejects an oversized pane and stops at the file ceiling" {
    var budget: SnapshotBudget = .{};

    // Nothing to record is not a claim.
    try testing.expect(!budget.take(0));
    try testing.expectEqual(@as(usize, 0), budget.used);

    // Over the per-pane ceiling ⇒ refused, and it spends nothing, so the panes
    // behind it are unaffected.
    try testing.expect(!budget.take(screen_snapshot_max_pane_bytes + 1));
    try testing.expectEqual(@as(usize, 0), budget.used);
    try testing.expect(budget.take(screen_snapshot_max_pane_bytes));
    try testing.expectEqual(screen_snapshot_max_pane_bytes, budget.used);

    // Fill the file budget exactly, then refuse the next byte.
    var full: SnapshotBudget = .{};
    var taken: usize = 0;
    while (taken + screen_snapshot_max_pane_bytes <= screen_snapshot_total_bytes) : (taken += screen_snapshot_max_pane_bytes) {
        try testing.expect(full.take(screen_snapshot_max_pane_bytes));
    }
    try testing.expectEqual(screen_snapshot_total_bytes, full.used);
    try testing.expect(!full.take(1));

    // The ceiling leaves room for the topology itself.
    try testing.expect(screen_snapshot_total_bytes < max_file_bytes);
}

test "serialize an empty window set is a present empty array" {
    const alloc = testing.allocator;
    const body = try serialize(alloc, .{});
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"windows\":[]") != null);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.windows.len);
}

test "writeAtomic + load round-trip; no .tmp leftover; missing file loads null" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "state", "session-layout.json" });
    defer alloc.free(path);

    try testing.expect((try load(alloc, path)) == null);

    const nodes = [_]Node{.{ .leaf = .{ .session_id = "abcabcabcabcabcabcabcabcabcabcab" } }};
    const tabs = [_]Tab{.{ .nodes = &nodes, .active = true }};
    const windows = [_]Window{.{ .id = "w1", .tabs = &tabs, .frame = .{ .x = 1, .y = 2, .w = 3, .h = 4 } }};
    const body = try serialize(alloc, .{ .windows = &windows });
    defer alloc.free(body);
    try writeAtomic(alloc, path, body);

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(tmp_path));

    var loaded = (try load(alloc, path)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.value.windows.len);
    try testing.expectEqualStrings("w1", loaded.value.windows[0].id);
    try testing.expectEqualStrings(
        "abcabcabcabcabcabcabcabcabcabcab",
        loaded.value.windows[0].tabs[0].nodes[0].leaf.?.session_id.?,
    );
}

test "viewer leaf round-trips all four fields; a terminal leaf emits none of them" {
    const alloc = testing.allocator;

    // A mixed tab: a terminal leaf beside a viewer leaf that has navigated away
    // from where it was opened (location != home) and carries an origin
    // directory its location could never be re-derived from.
    const nodes = [_]Node{
        .{ .split = .{ .layout = "vertical", .ratio = 0.6, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session_id = "abcabcabcabcabcabcabcabcabcabcab", .pane_id = "t-1" } },
        .{ .leaf = .{
            .pane_id = "v-1",
            .ipc_name = "doc",
            .kind = kind_viewer,
            .viewer_location = "https://example.com/",
            .viewer_home_location = "D:\\git\\ghoztty\\README.md",
            .viewer_origin_directory = "D:\\git\\ghoztty",
        } },
    };
    const tabs = [_]Tab{.{ .nodes = &nodes, .active = true }};
    const windows = [_]Window{.{ .id = "w1", .tabs = &tabs }};

    const body = try serialize(alloc, .{ .windows = &windows });
    defer alloc.free(body);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const out = parsed.value.windows[0].tabs[0].nodes;

    // The terminal leaf keeps its session and stays kind-less — that ABSENCE is
    // the compatibility rule (absent kind ⇒ terminal), so it is asserted on the
    // bytes and not just on the parsed value.
    const term = out[1].leaf.?;
    try testing.expect(!term.isViewer());
    try testing.expect(term.kind == null);
    try testing.expect(term.viewer_home_location == null);
    try testing.expect(term.viewer_origin_directory == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"pane_id\":\"t-1\",\"kind\"") == null);

    const view = out[2].leaf.?;
    try testing.expect(view.isViewer());
    try testing.expect(view.session_id == null);
    try testing.expectEqualStrings("doc", view.ipc_name.?);
    try testing.expectEqualStrings("v-1", view.pane_id.?);
    try testing.expectEqualStrings("https://example.com/", view.viewer_location.?);
    try testing.expectEqualStrings("D:\\git\\ghoztty\\README.md", view.viewer_home_location.?);
    try testing.expectEqualStrings("D:\\git\\ghoztty", view.viewer_origin_directory.?);
}

test "a pre-viewer manifest still loads: absent kind reads as a terminal leaf" {
    const alloc = testing.allocator;

    // Bytes as a build that predates viewer panes wrote them — no `kind`, and
    // an unknown future field beside it to prove `ignore_unknown_fields` still
    // covers the other direction of the same contract.
    const body =
        \\{"version":1,"windows":[{"id":"w1","tabs":[{"nodes":[
        \\{"leaf":{"session_id":"abcabcabcabcabcabcabcabcabcabcab","future_field":7}}
        \\],"active":true}]}]}
    ;
    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const leaf = parsed.value.windows[0].tabs[0].nodes[0].leaf.?;
    try testing.expect(!leaf.isViewer());
    try testing.expectEqualStrings("abcabcabcabcabcabcabcabcabcabcab", leaf.session_id.?);
}

test "an unrecognized kind is not a viewer, so a newer kind degrades to terminal" {
    // The additive-evolution rule applied to `kind` itself: a manifest from a
    // build that grows a third leaf kind must not have its leaves silently
    // treated as viewers here (which would try to navigate a null location).
    const leaf: Leaf = .{ .kind = "hologram", .session_id = null };
    try testing.expect(!leaf.isViewer());
}

test "window uuid round-trips, is dropped when absent, and falls back to id" {
    const alloc = testing.allocator;

    const nodes = [_]Node{.{ .leaf = .{ .session_id = "abcabcabcabcabcabcabcabcabcabcab" } }};
    const tabs = [_]Tab{.{ .nodes = &nodes, .active = true }};
    const windows = [_]Window{
        .{ .id = "window-1", .uuid = "1AC1F1F0-0000-4000-8000-000000000001", .tabs = &tabs },
        .{ .id = "win-1", .tabs = &tabs },
    };
    const body = try serialize(alloc, .{ .windows = &windows });
    defer alloc.free(body);
    // Present on the window that has one; dropped entirely on the one that
    // doesn't (emit_null_optional_fields=false), so a pre-T338 reader sees the
    // same bytes it always did.
    try testing.expect(std.mem.indexOf(u8, body, "\"uuid\":\"1AC1F1F0") != null);
    try testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, body, "\"id\":\"win-1\",\"uuid\""),
    );

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "1AC1F1F0-0000-4000-8000-000000000001",
        parsed.value.windows[0].uuid.?,
    );
    try testing.expect(parsed.value.windows[1].uuid == null);

    // A manifest from a pre-T338 build parses with a null uuid, which is what
    // makes `uuid orelse id` the correct key derivation for both.
    const legacy =
        \\{"version":1,"windows":[{"id":"win-0","tabs":[{"nodes":[{"leaf":{}}]}]}]}
    ;
    var old = try parse(alloc, legacy);
    defer old.deinit();
    try testing.expect(old.value.windows[0].uuid == null);
    try testing.expectEqualStrings("win-0", old.value.windows[0].uuid orelse old.value.windows[0].id);
}

test "parse tolerates unknown fields and missing optionals (additive interop)" {
    const alloc = testing.allocator;
    // A future build added a per-window field and a per-leaf field we don't
    // know; a leaf omits every optional. Both must parse cleanly.
    const body =
        \\{"version":1,"future_top":true,"windows":[
        \\  {"id":"w","futureWin":42,"tabs":[
        \\    {"nodes":[{"leaf":{"futureLeaf":"x"}}]}
        \\  ]}
        \\]}
    ;
    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.windows.len);
    const w = parsed.value.windows[0];
    try testing.expectEqualStrings("w", w.id);
    try testing.expect(w.frame == null);
    try testing.expectEqual(@as(usize, 1), w.tabs.len);
    const leaf = w.tabs[0].nodes[0].leaf.?;
    try testing.expect(leaf.session_id == null);
    try testing.expect(leaf.title == null);
}
