//! Agent-owned layout blobs — the win32 half of cross-machine "Restore All"
//! (§5.4/T18, T334). Two conversions, both pure, so they unit-test in every
//! app-runtime lane:
//!
//!   * **out** — one live `session_layout.Window` becomes the opaque `blob`
//!     plus the `session_ids` it references, which is exactly what
//!     `SET_LAYOUT{key, blob, session_ids}` carries.
//!   * **in** — a raw `LAYOUTS{layouts:[{key, blob}]}` reply payload becomes a
//!     list of `session_layout.Window`s the existing rebuild
//!     (`App.restoreWindow`) can replay.
//!
//! The agent stores the blob VERBATIM and never looks inside it
//! (`remote/agent/layout_meta.zig:9` — "the agent is DELIBERATELY
//! topology-agnostic"); it reads `session_ids` only to reap a blob once none of
//! its sessions exist any more. So the blob's schema is a contract between two
//! VIEWERS, not with the agent.
//!
//! ## The blob is a `session_layout.Window`
//!
//! win32 pushes its OWN manifest window struct — snake_case keys, a flat
//! `nodes` array with `left`/`right` indices — because that is the shape its
//! restore already reads, and reusing it means "Restore All" and launch-time
//! restore share one rebuild instead of two. macOS pushes a camelCase
//! `SessionLayoutManifest.Entry`, so a blob does not cross lineages: a Mac
//! viewer pointed at a Windows machine decodes nothing and shows "nothing to
//! restore". That gap is real, deliberate for now, and tracked as **T337**.
//!
//! ## Why a malformed blob is skipped rather than fatal
//!
//! The blobs in a store were written by however many app builds have run on
//! that machine, and one of them being unreadable (an older schema, a truncated
//! write, another lineage's shape) must not cost the user the other five
//! windows. Every decode failure is counted, not raised.

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("../../remote/protocol.zig");
const session_layout = @import("session_layout.zig");

/// Serialize one window into its opaque blob. Absent optionals are dropped, the
/// same additive-evolution contract the manifest file itself uses — a reader
/// that doesn't know a field ignores it, and a reader that expects one it can't
/// find falls back. Caller frees.
///
/// The WP-D3 screen snapshots (T109) are STRIPPED on the way out. A blob is a
/// TOPOLOGY record: it is re-serialized and pushed to the agent on every layout
/// mutation, and `blobHash` skipping the unchanged ones is what keeps that
/// mirror cheap. A per-pane VT screen dump would both multiply a blob's size by
/// a hundred and change its bytes on every single push, so every window would
/// re-upload forever. Restore-from-blob therefore uses the pre-WP-D3 full-ring
/// replay; the local manifest — which is not pushed anywhere — carries the
/// snapshots for the same-machine re-attach they were built for.
pub fn serializeWindow(alloc: Allocator, win: session_layout.Window) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const stripped = try stripSnapshots(arena_state.allocator(), win);
    return std.json.Stringify.valueAlloc(alloc, stripped, .{
        .emit_null_optional_fields = false,
    });
}

/// A copy of `win` whose every leaf has its WP-D3 snapshot fields cleared.
/// Everything else — including every string — is BORROWED from `win`; only the
/// tab/node spines are rebuilt, which is all that is needed to change a value
/// field on a leaf. Allocated in `arena`, so the caller frees the lot at once.
fn stripSnapshots(arena: Allocator, win: session_layout.Window) !session_layout.Window {
    var out = win;
    const tabs = try arena.alloc(session_layout.Tab, win.tabs.len);
    for (win.tabs, 0..) |tab, ti| {
        const nodes = try arena.alloc(session_layout.Node, tab.nodes.len);
        for (tab.nodes, 0..) |node, ni| {
            nodes[ni] = node;
            if (nodes[ni].leaf) |*leaf| {
                leaf.screen_snapshot = null;
                leaf.screen_snapshot_offset = null;
            }
        }
        tabs[ti] = tab;
        tabs[ti].nodes = nodes;
    }
    out.tabs = tabs;
    return out;
}

/// Every agent session id `win` references, in tree order, deduped. The slices
/// are BORROWED from `win`; only the outer array is allocated (caller frees it).
///
/// Deduped because the agent uses this list to decide when a blob is dead (none
/// of its sessions exist), and a duplicate id would make that arithmetic read as
/// if the window referenced more sessions than it does. Leaves with no session
/// (a pane that was never agent-backed) contribute nothing — they restore as a
/// fresh pane and hold no claim on the blob's lifetime.
pub fn sessionIds(alloc: Allocator, win: session_layout.Window) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (win.tabs) |tab| {
        for (tab.nodes) |node| {
            const leaf = node.leaf orelse continue;
            const sid = leaf.session_id orelse continue;
            if (sid.len == 0) continue;
            var dup = false;
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen, sid)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try out.append(alloc, sid);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// A cheap content fingerprint of a serialized blob, so a caller that re-pushes
/// on every layout mutation can skip the windows that did not actually change.
/// Not a security property — only "are these the same bytes".
pub fn blobHash(blob: []const u8) u64 {
    return std.hash.Wyhash.hash(0, blob);
}

/// The decoded `LAYOUTS` reply. Every window (and every string inside it) lives
/// in the embedded arena; `deinit` frees the lot. `skipped` counts blobs that
/// were present but unusable — surfaced so a caller can say "3 of 5 windows"
/// rather than silently restoring fewer than the machine has.
pub const Decoded = struct {
    arena: *std.heap.ArenaAllocator,
    windows: []const session_layout.Window,
    skipped: usize,

    pub fn deinit(self: Decoded) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

/// Decode a raw `LAYOUTS{layouts:[{key, blob}]}` payload — what
/// `Connection.requestLayouts` hands back — into replayable windows.
///
/// A malformed OUTER payload is an error (the reply itself is broken, so there
/// is nothing to be partial about); a malformed INNER blob is skipped. A blob
/// that parses but carries no tabs is skipped too: it would rebuild as a window
/// with nothing in it, which is worse than not rebuilding it.
pub fn decodeLayouts(alloc: Allocator, payload: []const u8) !Decoded {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const reply = try std.json.parseFromSliceLeaky(protocol.Layouts, a, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    var out: std.ArrayList(session_layout.Window) = .empty;
    var skipped: usize = 0;
    for (reply.layouts) |rec| {
        const win = std.json.parseFromSliceLeaky(session_layout.Window, a, rec.blob, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            skipped += 1;
            continue;
        };
        if (win.tabs.len == 0) {
            skipped += 1;
            continue;
        }
        try out.append(a, win);
    }

    return .{
        .arena = arena,
        .windows = try out.toOwnedSlice(a),
        .skipped = skipped,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// A two-pane window: one split node over two leaves, both agent-backed.
fn twoPaneWindow() session_layout.Window {
    const S = struct {
        const nodes = [_]session_layout.Node{
            .{ .split = .{ .layout = "horizontal", .ratio = 0.5, .left = 1, .right = 2 } },
            .{ .leaf = .{ .session_id = "aaaa", .pane_id = "pane-a", .title = "left" } },
            .{ .leaf = .{ .session_id = "bbbb", .pane_id = "pane-b" } },
        };
        const tabs = [_]session_layout.Tab{.{ .nodes = &nodes, .active = true }};
    };
    return .{
        .id = "win-0",
        .frame = .{ .x = 10, .y = 20, .w = 800, .h = 600 },
        .active_tab = 0,
        .tabs = &S.tabs,
    };
}

test "T109: serializeWindow strips screen snapshots but keeps everything else" {
    const alloc = testing.allocator;
    const nodes = [_]session_layout.Node{
        .{ .split = .{ .layout = "horizontal", .ratio = 0.5, .left = 1, .right = 2 } },
        .{ .leaf = .{
            .session_id = "aaaa",
            .pane_id = "pane-a",
            .title = "left",
            .screen_snapshot = "SU5WSVNJQkxF",
            .screen_snapshot_offset = 9001,
        } },
        .{ .leaf = .{ .session_id = "bbbb", .pane_id = "pane-b" } },
    };
    const tabs = [_]session_layout.Tab{.{ .nodes = &nodes, .active = true }};
    const win: session_layout.Window = .{ .id = "win-0", .active_tab = 0, .tabs = &tabs };

    const blob = try serializeWindow(alloc, win);
    defer alloc.free(blob);
    try testing.expect(std.mem.indexOf(u8, blob, "screen_snapshot") == null);
    try testing.expect(std.mem.indexOf(u8, blob, "SU5WSVNJQkxF") == null);
    try testing.expect(std.mem.indexOf(u8, blob, "9001") == null);
    // The topology is untouched: same tree, same ids, same titles.
    try testing.expect(std.mem.indexOf(u8, blob, "\"pane-a\"") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "\"bbbb\"") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "\"left\"") != null);

    // ...and the caller's window is NOT mutated — the strip works on a copy.
    try testing.expectEqualStrings("SU5WSVNJQkxF", win.tabs[0].nodes[1].leaf.?.screen_snapshot.?);

    // Two panes' worth of snapshot churn must not move the hash: that is what
    // keeps the per-mutation mirror from re-uploading every window forever.
    var quiet = nodes;
    quiet[1].leaf.?.screen_snapshot = "RElGRkVSRU5U";
    quiet[1].leaf.?.screen_snapshot_offset = 424242;
    const quiet_tabs = [_]session_layout.Tab{.{ .nodes = &quiet, .active = true }};
    const blob2 = try serializeWindow(alloc, .{ .id = "win-0", .active_tab = 0, .tabs = &quiet_tabs });
    defer alloc.free(blob2);
    try testing.expectEqual(blobHash(blob), blobHash(blob2));
}

test "serializeWindow round-trips through the manifest parser" {
    const alloc = testing.allocator;
    const blob = try serializeWindow(alloc, twoPaneWindow());
    defer alloc.free(blob);

    // Absent optionals are dropped, not emitted as null.
    try testing.expect(std.mem.indexOf(u8, blob, "null") == null);

    const parsed = try std.json.parseFromSlice(session_layout.Window, alloc, blob, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const w = parsed.value;
    try testing.expectEqualStrings("win-0", w.id);
    try testing.expectEqual(@as(i32, 800), w.frame.?.w);
    try testing.expectEqual(@as(usize, 1), w.tabs.len);
    try testing.expectEqual(@as(usize, 3), w.tabs[0].nodes.len);
    try testing.expectEqualStrings("aaaa", w.tabs[0].nodes[1].leaf.?.session_id.?);
    try testing.expectEqualStrings("pane-b", w.tabs[0].nodes[2].leaf.?.pane_id.?);
    try testing.expectEqualStrings("horizontal", w.tabs[0].nodes[0].split.?.layout);
}

test "sessionIds: tree order, split nodes skipped, id-less leaves skipped" {
    const alloc = testing.allocator;
    const ids = try sessionIds(alloc, twoPaneWindow());
    defer alloc.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("aaaa", ids[0]);
    try testing.expectEqualStrings("bbbb", ids[1]);
}

test "sessionIds: deduped, and empty when nothing is agent-backed" {
    const alloc = testing.allocator;

    const dup_nodes = [_]session_layout.Node{
        .{ .leaf = .{ .session_id = "same" } },
        .{ .leaf = .{ .session_id = "same" } },
        .{ .leaf = .{ .session_id = "other" } },
    };
    const dup_tabs = [_]session_layout.Tab{.{ .nodes = &dup_nodes }};
    const deduped = try sessionIds(alloc, .{ .id = "w", .tabs = &dup_tabs });
    defer alloc.free(deduped);
    try testing.expectEqual(@as(usize, 2), deduped.len);
    try testing.expectEqualStrings("same", deduped[0]);
    try testing.expectEqualStrings("other", deduped[1]);

    // A window of never-agent-backed panes claims no sessions at all: the agent
    // must be free to reap its blob rather than hold it forever.
    const bare_nodes = [_]session_layout.Node{
        .{ .leaf = .{ .pane_id = "p" } },
        .{ .leaf = .{ .session_id = "" } },
    };
    const bare_tabs = [_]session_layout.Tab{.{ .nodes = &bare_nodes }};
    const none = try sessionIds(alloc, .{ .id = "w", .tabs = &bare_tabs });
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "sessionIds: spans every tab, not just the active one" {
    const alloc = testing.allocator;
    const t0 = [_]session_layout.Node{.{ .leaf = .{ .session_id = "one" } }};
    const t1 = [_]session_layout.Node{.{ .leaf = .{ .session_id = "two" } }};
    const tabs = [_]session_layout.Tab{
        .{ .nodes = &t0, .active = true },
        .{ .nodes = &t1 },
    };
    const ids = try sessionIds(alloc, .{ .id = "w", .tabs = &tabs });
    defer alloc.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("two", ids[1]);
}

test "blobHash: same bytes agree, one changed field does not" {
    const alloc = testing.allocator;
    const a = try serializeWindow(alloc, twoPaneWindow());
    defer alloc.free(a);
    const b = try serializeWindow(alloc, twoPaneWindow());
    defer alloc.free(b);
    try testing.expectEqual(blobHash(a), blobHash(b));

    var moved = twoPaneWindow();
    moved.frame = .{ .x = 11, .y = 20, .w = 800, .h = 600 };
    const c = try serializeWindow(alloc, moved);
    defer alloc.free(c);
    try testing.expect(blobHash(a) != blobHash(c));
}

/// Build a `LAYOUTS` reply payload out of `blobs` (the wire shape the agent
/// answers `GET_LAYOUTS` with).
fn layoutsReply(alloc: Allocator, blobs: []const protocol.LayoutBlob) ![]u8 {
    return protocol.encodeJson(alloc, protocol.Layouts{ .layouts = blobs });
}

test "decodeLayouts: two good blobs decode in reply order" {
    const alloc = testing.allocator;
    const blob = try serializeWindow(alloc, twoPaneWindow());
    defer alloc.free(blob);
    var second = twoPaneWindow();
    second.id = "win-1";
    const blob2 = try serializeWindow(alloc, second);
    defer alloc.free(blob2);

    const payload = try layoutsReply(alloc, &.{
        .{ .key = "win-0", .blob = blob },
        .{ .key = "win-1", .blob = blob2 },
    });
    defer alloc.free(payload);

    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 2), decoded.windows.len);
    try testing.expectEqual(@as(usize, 0), decoded.skipped);
    try testing.expectEqualStrings("win-0", decoded.windows[0].id);
    try testing.expectEqualStrings("win-1", decoded.windows[1].id);
    try testing.expectEqualStrings("aaaa", decoded.windows[0].tabs[0].nodes[1].leaf.?.session_id.?);
}

test "decodeLayouts: one malformed blob is skipped, the good one survives" {
    const alloc = testing.allocator;
    const blob = try serializeWindow(alloc, twoPaneWindow());
    defer alloc.free(blob);

    const payload = try layoutsReply(alloc, &.{
        .{ .key = "broken", .blob = "{not json" },
        .{ .key = "win-0", .blob = blob },
        // Another lineage's shape (macOS pushes camelCase with a nested tree):
        // it parses as JSON but has no `tabs`, so it is unusable here (T337).
        .{ .key = "macos", .blob = "{\"windowID\":\"x\",\"tree\":{\"leaf\":{\"sessionID\":\"z\"}}}" },
    });
    defer alloc.free(payload);

    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.windows.len);
    try testing.expectEqual(@as(usize, 2), decoded.skipped);
    try testing.expectEqualStrings("win-0", decoded.windows[0].id);
}

test "decodeLayouts: an empty layouts array is a valid, empty answer" {
    const alloc = testing.allocator;
    const payload = try layoutsReply(alloc, &.{});
    defer alloc.free(payload);

    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 0), decoded.windows.len);
    try testing.expectEqual(@as(usize, 0), decoded.skipped);
}

test "decodeLayouts: a blob with zero tabs is skipped, not rebuilt empty" {
    const alloc = testing.allocator;
    const empty_win = try serializeWindow(alloc, .{ .id = "hollow" });
    defer alloc.free(empty_win);

    const payload = try layoutsReply(alloc, &.{.{ .key = "hollow", .blob = empty_win }});
    defer alloc.free(payload);

    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 0), decoded.windows.len);
    try testing.expectEqual(@as(usize, 1), decoded.skipped);
}

test "decodeLayouts: a malformed OUTER payload is an error, not an empty set" {
    const alloc = testing.allocator;
    // Truncated mid-object (a short read) and outright garbage: both must
    // FAIL rather than answer "this machine has no windows", which would send
    // the caller down the "nothing to restore" path over a transport fault.
    try testing.expectError(error.UnexpectedEndOfInput, decodeLayouts(alloc, "{\"layouts\":"));
    try testing.expectError(error.SyntaxError, decodeLayouts(alloc, "not json at all"));
}

test "decodeLayouts: unknown fields in the reply and in a blob are tolerated" {
    const alloc = testing.allocator;
    // A newer agent adds a field to the record; a newer app adds one to the
    // window. Both must read on this build (additive-evolution contract).
    const payload =
        "{\"layouts\":[{\"key\":\"w\",\"stored_at\":123," ++
        "\"blob\":\"{\\\"id\\\":\\\"w\\\",\\\"future\\\":7," ++
        "\\\"tabs\\\":[{\\\"nodes\\\":[{\\\"leaf\\\":{\\\"session_id\\\":\\\"s\\\"}}]}]}\"}]}";

    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.windows.len);
    try testing.expectEqual(@as(usize, 0), decoded.skipped);
    try testing.expectEqualStrings("s", decoded.windows[0].tabs[0].nodes[0].leaf.?.session_id.?);
}
