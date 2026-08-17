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
//! `SessionLayoutManifest.Entry` — one blob per TAB, with a nested `tree`.
//!
//! Two lineages, two shapes, and no tag to tell them apart: the blobs already
//! sitting in live agents were written before any tag could exist, and an agent
//! outlives the app that wrote them by design. So the READER decides by shape
//! (T337) — a macOS entry has a `tree` and no `tabs` — and translates
//! (`mac_layout_blob.zig`), which is what makes "Restore All" pointed at a Mac
//! machine rebuild that Mac's windows here instead of reporting "nothing to
//! restore". The mirror direction (a Mac viewer reading these blobs) is the Mac
//! seat's half, filed as T622.
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
const mac_layout_blob = @import("mac_layout_blob.zig");
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
/// re-upload forever. Restore-from-blob therefore attaches at offset 0 and takes
/// the ring replay; the local manifest — which is not pushed anywhere — carries
/// the snapshots for the same-machine re-attach they were built for.
///
/// **T413 settled this deliberately, not by omission.** The asymmetry looks like
/// a gap ("a blob-sourced pane takes the lossy pre-T109 path"), and it is worth
/// writing down why putting a snapshot back is the wrong shape:
///
///   * **The pane is not lossy on screen any more.** Two later changes already
///     cover what WP-D3 was built to cover on this path. T106 reflows the client
///     grid to the agent-reported CAPTURE geometry for the replay and back to the
///     live grid when it is fully applied (`termio/Remote.zig`, `attach_offset ==
///     0` branch), and FIX 2 has the agent append its OWN grid snapshot after the
///     gap-fill — a self-contained VT repaint of the visible screen, generated
///     at the geometry the attaching client just asked for (`agent/server.zig`
///     `want_snapshot`; `agent/session.zig gridSnapshotAlloc`). What is left is
///     the replay's wire cost and imperfect scrollback for ring segments drawn at
///     older geometries, not a blank or smeared pane.
///   * **A stored snapshot cannot beat the agent's.** Ours would be whatever
///     viewer last pushed the blob, at THAT viewer's geometry, at whatever offset
///     it last captured — stale by construction for a machine still in use, and
///     a stale offset makes the agent emit its "bytes of scrollback lost" marker
///     for bytes it still holds. The agent's is fresh, correctly sized and costs
///     no storage. The only thing it lacks is scrollback, because its emulator
///     runs `max_scrollback = 0`.
///   * **So the remaining gap belongs in the agent**, which is filed as its own
///     task rather than smuggled into the topology mirror. Giving that emulator
///     bounded scrollback lets the raw ring replay be skipped outright, and fixes
///     every snapshot-less attach — a cross-machine Resume-one of a single
///     session has no local manifest entry either, and no blob change could ever
///     have helped it.
///
/// The strip is therefore load-bearing in both directions, and
/// `decodeLayouts` is asserted to hand back leaves with no WP-D3 pair.
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
///
/// A **macOS-lineage** blob is neither: it is recognized by shape and translated
/// (T337). Mac stores one blob per TAB, so its entries are collected across the
/// whole reply and grouped into windows at the end — which is why translated
/// windows follow the win32 ones rather than holding their reply position.
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
    var mac_entries: std.ArrayList(mac_layout_blob.Entry) = .empty;
    var skipped: usize = 0;
    for (reply.layouts) |rec| {
        // One generic parse serves both lineages: the shape test needs a tree of
        // values anyway, and re-parsing the bytes per candidate schema would let
        // the two readers disagree about what the blob even is.
        const value = std.json.parseFromSliceLeaky(std.json.Value, a, rec.blob, .{
            .allocate = .alloc_always,
        }) catch {
            skipped += 1;
            continue;
        };

        if (mac_layout_blob.looksLikeEntry(value)) {
            const entry = mac_layout_blob.parseEntry(a, value) catch {
                skipped += 1;
                continue;
            };
            // An entry whose tree held nothing is the Mac equivalent of a
            // zero-tab window: skipped rather than rebuilt empty.
            if (entry.nodes.len == 0) {
                skipped += 1;
                continue;
            }
            try mac_entries.append(a, entry);
            continue;
        }

        const win = std.json.parseFromValueLeaky(session_layout.Window, a, value, .{
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

    if (mac_entries.items.len > 0) {
        const translated = try mac_layout_blob.groupIntoWindows(a, mac_entries.items);
        try out.appendSlice(a, translated);
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
        .primary_screen_height = 1440,
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

test "T413: a blob-sourced leaf carries no WP-D3 pair, so restore attaches at offset 0" {
    // The out-side strip is asserted above on the blob's BYTES; this closes the
    // loop on the IN side, which is what a restore actually reads. A leaf whose
    // pair survived here would have `restoreAttachOverride` paint one viewer's
    // screen into another's pane and attach at that viewer's stale offset — the
    // failure mode the strip exists to make unreachable.
    const alloc = testing.allocator;
    const nodes = [_]session_layout.Node{.{ .leaf = .{
        .session_id = "aaaa",
        .pane_id = "pane-a",
        .screen_snapshot = "SU5WSVNJQkxF",
        .screen_snapshot_offset = 9001,
    } }};
    const tabs = [_]session_layout.Tab{.{ .nodes = &nodes, .active = true }};
    const blob = try serializeWindow(alloc, .{ .id = "win-0", .tabs = &tabs });
    defer alloc.free(blob);

    const payload = try layoutsReply(alloc, &.{.{ .key = "win-0", .blob = blob }});
    defer alloc.free(payload);
    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();

    try testing.expectEqual(@as(usize, 1), decoded.windows.len);
    const leaf = decoded.windows[0].tabs[0].nodes[0].leaf.?;
    // The session is still there to attach to — only the snapshot is gone.
    try testing.expectEqualStrings("aaaa", leaf.session_id.?);
    try testing.expectEqualStrings("pane-a", leaf.pane_id.?);
    try testing.expect(leaf.screen_snapshot == null);
    try testing.expect(leaf.screen_snapshot_offset == null);
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
    // The cross-lineage flip constant (T623) rides the blob out and back: it is
    // what a Mac reader converts our top-down origin with.
    try testing.expectEqual(@as(i32, 1440), w.primary_screen_height.?);
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
        // A shape that is neither lineage: valid JSON, no `tabs` to rebuild and
        // no `tree` to translate.
        .{ .key = "alien", .blob = "{\"windowID\":\"x\"}" },
    });
    defer alloc.free(payload);

    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.windows.len);
    try testing.expectEqual(@as(usize, 2), decoded.skipped);
    try testing.expectEqualStrings("win-0", decoded.windows[0].id);
}

test "T337: a macOS blob restores as a window instead of being dropped" {
    const alloc = testing.allocator;
    // The shape a Mac viewer actually pushes: camelCase, a nested `tree` whose
    // enum cases carry a `_0` payload, and — because Mac stores one entry per
    // TAB — two blobs that belong to ONE window.
    const tab_a =
        \\{"id":"1D0A0B0C-0000-4000-8000-000000000001",
        \\ "tabGroupID":"GGGGGGGG-0000-4000-8000-000000000009","tabIndex":0,
        \\ "ipcName":"dev","titleOverride":"editor",
        \\ "frame":{"x":120,"y":300,"width":1440,"height":900},
        \\ "tree":{"split":{"_0":{"direction":"vertical","ratio":0.25,
        \\   "left":{"leaf":{"_0":{"sessionID":"aaaa","surfaceID":"pane-a"}}},
        \\   "right":{"leaf":{"_0":{"sessionID":"bbbb"}}}}}}}
    ;
    const tab_b =
        \\{"id":"1D0A0B0C-0000-4000-8000-000000000002",
        \\ "tabGroupID":"GGGGGGGG-0000-4000-8000-000000000009","tabIndex":1,
        \\ "titleOverride":"logs",
        \\ "tree":{"leaf":{"_0":{"sessionID":"cccc"}}}}
    ;

    const payload = try layoutsReply(alloc, &.{
        .{ .key = "mac-a", .blob = tab_a },
        .{ .key = "mac-b", .blob = tab_b },
    });
    defer alloc.free(payload);

    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 0), decoded.skipped);
    // ONE window with two tabs — not two windows, and not nothing.
    try testing.expectEqual(@as(usize, 1), decoded.windows.len);
    const w = decoded.windows[0];
    try testing.expectEqualStrings("dev", w.id);
    try testing.expectEqual(@as(usize, 2), w.tabs.len);
    try testing.expectEqual(@as(i32, 1440), w.frame.?.w);
    // The split tree arrived as win32's flat indexed nodes.
    try testing.expectEqual(@as(usize, 3), w.tabs[0].nodes.len);
    try testing.expectEqualStrings("vertical", w.tabs[0].nodes[0].split.?.layout);
    try testing.expectEqual(@as(u16, 2), w.tabs[0].nodes[0].split.?.right);
    try testing.expectEqualStrings("aaaa", w.tabs[0].nodes[1].leaf.?.session_id.?);
    try testing.expectEqualStrings("pane-a", w.tabs[0].nodes[1].leaf.?.pane_id.?);
    try testing.expectEqualStrings("cccc", w.tabs[1].nodes[0].leaf.?.session_id.?);

    // ...and the sessions it references are exactly the three the Mac holds —
    // across BOTH tabs — so the attach probe and the double-attach guard see
    // every pane, not just the frontmost tab's.
    const ids = try sessionIds(alloc, w);
    defer alloc.free(ids);
    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqualStrings("aaaa", ids[0]);
    try testing.expectEqualStrings("bbbb", ids[1]);
    try testing.expectEqualStrings("cccc", ids[2]);
}

test "T337: a mixed store decodes both lineages, and a broken Mac blob is skipped" {
    const alloc = testing.allocator;
    const win_blob = try serializeWindow(alloc, twoPaneWindow());
    defer alloc.free(win_blob);

    const payload = try layoutsReply(alloc, &.{
        .{ .key = "mac-bad", .blob = "{\"id\":\"e\",\"tree\":{\"branch\":{\"_0\":{}}}}" },
        .{ .key = "win-0", .blob = win_blob },
        .{ .key = "mac-ok", .blob = "{\"id\":\"e2\",\"tree\":{\"leaf\":{\"_0\":{\"sessionID\":\"z\"}}}}" },
    });
    defer alloc.free(payload);

    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.skipped);
    try testing.expectEqual(@as(usize, 2), decoded.windows.len);
    // win32 windows keep their reply order; translated ones follow.
    try testing.expectEqualStrings("win-0", decoded.windows[0].id);
    try testing.expectEqualStrings("e2", decoded.windows[1].id);
    try testing.expectEqualStrings("z", decoded.windows[1].tabs[0].nodes[0].leaf.?.session_id.?);
}

test "T337: a Mac blob's screen snapshot never reaches a restored leaf" {
    // The IN-side twin of the T413 assertion above. Mac's `layoutBlob` does NOT
    // strip snapshots the way win32's `serializeWindow` does, so the only thing
    // standing between another viewer's stale screen and this pane is the
    // translator.
    const alloc = testing.allocator;
    const payload = try layoutsReply(alloc, &.{.{
        .key = "mac",
        .blob = "{\"id\":\"e\",\"tree\":{\"leaf\":{\"_0\":{\"sessionID\":\"a\"," ++
            "\"screenSnapshot\":\"SU5WSVNJQkxF\",\"screenSnapshotOffset\":9001}}}}",
    }});
    defer alloc.free(payload);

    const decoded = try decodeLayouts(alloc, payload);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.windows.len);
    const leaf = decoded.windows[0].tabs[0].nodes[0].leaf.?;
    try testing.expectEqualStrings("a", leaf.session_id.?);
    try testing.expect(leaf.screen_snapshot == null);
    try testing.expect(leaf.screen_snapshot_offset == null);
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
