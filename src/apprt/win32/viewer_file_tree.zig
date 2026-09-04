//! The file tree a diff viewer pane's side panel renders (T464).
//!
//! The Windows port of Mac's `ViewerDiffTree.swift`: a pure transform from
//! git's flat list of changed paths into the rows on screen, kept out of the
//! window so the two behaviors that are easy to get subtly wrong — collapsing
//! a chain of single-child directories, and what a shut folder hides — are
//! asserted in the `none` lane without a card, a DC or a font.
//!
//! `ViewerTOCPanel.zig` paints these rows on the SAME card it paints a table
//! of contents on; the pane owns which of the two it is showing. That is the
//! factoring Mac arrived at (the diff tree landed in the same commit that cut
//! 217 lines out of `ViewerTOC.swift`), and it is why nothing here knows about
//! painting.
//!
//! ## Ownership
//!
//! A `Tree` owns every string it hands back — a row's id and its label are
//! duplicated out of the caller's file list rather than borrowed from it. The
//! pane rebuilds the tree from a fresh listing every poll, and a borrow would
//! be a use-after-free the first time a two-second working-tree poll dropped a
//! file whose row was still on screen.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const chrome_theme = @import("chrome_theme.zig");
const diff = @import("viewer_diff.zig");

/// The origins, in the order git status reads in — which is the order the
/// sections appear in the panel.
pub const section_order = [_]diff.Origin{ .committed, .staged, .unstaged, .untracked };

pub const Kind = enum {
    /// A working-tree section header ("Staged", "Changes", …). Only a
    /// `git-status:` diff ever has more than one; a commit or a range has
    /// none.
    section,
    /// A directory. Its title is the JOINED path of a collapsed chain
    /// (`src/apprt/win32`), which is why it is not just a name.
    folder,
    file,
};

pub const Row = struct {
    kind: Kind,
    /// Stable identity, owned. Sections: `section:<origin>`. Folders: the
    /// folder key, `<origin>:<path>`, which is what `collapsed` holds.
    /// Files: the file's path, which is what the pane's `diff_file` holds.
    id: []const u8,
    /// The label, owned. A file row's label is the BASENAME — the tree above
    /// it carries the rest.
    title: []const u8,
    depth: u8,
    /// For a `.file` row: the index into the `files` slice `build` was given.
    /// Kept for callers that want to reach back into their own list (the
    /// next/previous-file walk); nothing here needs it.
    file: usize = 0,
    /// For a `.file` row: everything the card draws beside the name, COPIED
    /// rather than borrowed. The probe rebuilds its entry list on a poll and
    /// frees the old paths with it, so a row holding a pointer into that list
    /// would be a use-after-free the first time a poll found nothing to
    /// redraw and the tree therefore was not rebuilt.
    status: diff.Status = .unknown,
    additions: u32 = 0,
    deletions: u32 = 0,
    binary: bool = false,
    /// For a `.folder` row: whether the user has clicked it shut.
    collapsed: bool = false,
};

pub const Tree = struct {
    rows: []Row = &.{},
    alloc: Allocator,

    pub fn deinit(self: *Tree) void {
        for (self.rows) |r| {
            self.alloc.free(r.id);
            self.alloc.free(r.title);
        }
        if (self.rows.len > 0) self.alloc.free(self.rows);
        self.rows = &.{};
    }

    /// How many `.file` rows the tree is showing. What the pane's
    /// gutter/overlay policy counts, and what tells "one file, no tree worth
    /// drawing" from a diff worth navigating.
    pub fn fileRows(self: *const Tree) usize {
        var n: usize = 0;
        for (self.rows) |r| {
            if (r.kind == .file) n += 1;
        }
        return n;
    }
};

/// Build the rows for a file list.
///
/// `collapsed` is the set of folder keys the user has clicked shut; a key that
/// no longer names a folder is simply never consulted, so a stale entry left
/// behind by a poll that dropped a directory is harmless.
pub fn build(
    alloc: Allocator,
    files: []const diff.File,
    collapsed: []const []const u8,
) Allocator.Error!Tree {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |r| {
            alloc.free(r.id);
            alloc.free(r.title);
        }
        rows.deinit(alloc);
    }

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (section_order) |origin| {
        // The indices of this section's files, in the order git listed them.
        var section: std.ArrayList(usize) = .empty;
        for (files, 0..) |f, i| {
            if (f.origin == origin) try section.append(arena, i);
        }
        if (section.items.len == 0) continue;

        var depth: u8 = 0;
        if (origin.sectionTitle()) |title| {
            const id = try std.fmt.allocPrint(alloc, "section:{s}", .{origin.name()});
            errdefer alloc.free(id);
            const label = try std.fmt.allocPrint(
                alloc,
                "{s} \u{00b7} {d}",
                .{ title, section.items.len },
            );
            errdefer alloc.free(label);
            try rows.append(alloc, .{
                .kind = .section,
                .id = id,
                .title = label,
                .depth = 0,
            });
            depth = 1;
        }

        const root = try Node.create(arena);
        for (section.items) |i| try root.insert(arena, files[i].path, i);
        try flatten(alloc, arena, &rows, files, root, "", origin, depth, collapsed);
    }

    return .{ .rows = try rows.toOwnedSlice(alloc), .alloc = alloc };
}

// -------------------------------------------------------------------------
// Hierarchy
// -------------------------------------------------------------------------

/// A directory being built. Children keep insertion order; they are sorted at
/// flatten time, so the order git happened to list files in never leaks into
/// the display.
const Node = struct {
    names: std.ArrayList([]const u8) = .empty,
    kids: std.ArrayList(*Node) = .empty,
    files: std.ArrayList(usize) = .empty,

    fn create(arena: Allocator) Allocator.Error!*Node {
        const n = try arena.create(Node);
        n.* = .{};
        return n;
    }

    fn child(self: *Node, arena: Allocator, name: []const u8) Allocator.Error!*Node {
        for (self.names.items, self.kids.items) |existing, node| {
            if (std.mem.eql(u8, existing, name)) return node;
        }
        const node = try Node.create(arena);
        try self.names.append(arena, name);
        try self.kids.append(arena, node);
        return node;
    }

    fn insert(self: *Node, arena: Allocator, path: []const u8, index: usize) Allocator.Error!void {
        var node = self;
        var it = std.mem.splitScalar(u8, path, '/');
        var pending: ?[]const u8 = it.next();
        while (pending) |component| {
            const next = it.next();
            if (next == null) break; // the last component is the file itself
            if (component.len > 0) node = try node.child(arena, component);
            pending = next;
        }
        try node.files.append(arena, index);
    }
};

fn flatten(
    alloc: Allocator,
    arena: Allocator,
    rows: *std.ArrayList(Row),
    files: []const diff.File,
    node: *Node,
    prefix: []const u8,
    origin: diff.Origin,
    depth: u8,
    collapsed: []const []const u8,
) Allocator.Error!void {
    // Folders before files, each alphabetized the way a file browser would.
    const order = try arena.alloc(usize, node.names.items.len);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, node.names.items, struct {
        fn less(names: [][]const u8, a: usize, b: usize) bool {
            return naturalLess(names[a], names[b]);
        }
    }.less);

    for (order) |i| {
        // Collapse a chain of single-child directories into one row —
        // `src/apprt/win32` rather than three rows of indentation carrying no
        // information.
        var title = node.names.items[i];
        var path = if (prefix.len == 0)
            title
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, title });
        var current = node.kids.items[i];
        while (current.files.items.len == 0 and current.kids.items.len == 1) {
            const name = current.names.items[0];
            title = try std.fmt.allocPrint(arena, "{s}/{s}", .{ title, name });
            path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, name });
            current = current.kids.items[0];
        }

        const key = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ origin.name(), path });
        errdefer alloc.free(key);
        const label = try alloc.dupe(u8, title);
        errdefer alloc.free(label);
        const shut = contains(collapsed, key);
        try rows.append(alloc, .{
            .kind = .folder,
            .id = key,
            .title = label,
            .depth = depth,
            .collapsed = shut,
        });
        if (shut) continue;
        try flatten(alloc, arena, rows, files, current, path, origin, depth + 1, collapsed);
    }

    const file_order = try arena.alloc(usize, node.files.items.len);
    for (file_order, 0..) |*slot, i| slot.* = i;
    const Ctx = struct {
        files: []const diff.File,
        indices: []const usize,
        fn less(self: @This(), a: usize, b: usize) bool {
            return naturalLess(
                baseName(self.files[self.indices[a]].path),
                baseName(self.files[self.indices[b]].path),
            );
        }
    };
    std.mem.sort(
        usize,
        file_order,
        Ctx{ .files = files, .indices = node.files.items },
        Ctx.less,
    );

    for (file_order) |i| {
        const index = node.files.items[i];
        const id = try alloc.dupe(u8, files[index].path);
        errdefer alloc.free(id);
        const label = try alloc.dupe(u8, baseName(files[index].path));
        errdefer alloc.free(label);
        try rows.append(alloc, .{
            .kind = .file,
            .id = id,
            .title = label,
            .depth = depth,
            .file = index,
            .status = files[index].status,
            .additions = files[index].additions,
            .deletions = files[index].deletions,
            .binary = files[index].binary,
        });
    }
}

fn contains(set: []const []const u8, key: []const u8) bool {
    for (set) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// The last path component. `git` speaks forward slashes on every platform, so
/// this reads the same for a Windows repository as for a POSIX one.
pub fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// The directory part of a path, or null at the repository root. What a
/// flattened (filtered) row would show under the name; also what a tooltip
/// wants.
pub fn parentPath(path: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return path[0..i];
}

/// What a file's git status MEANS on the badge beside its name. A tone, never
/// a color: the card resolves it against its own fill (`chrome_theme.toneInk`
/// / `toneFill`), so the same meaning clears the same contrast floor on a
/// light page and a dark one.
///
/// Mac paints the same four groups (`ViewerDiffPanel.color(for:)`) — green for
/// an addition, red for a deletion, blue for a rename or copy, amber for a
/// modification — and anything git could not classify stays neutral rather
/// than borrowing a meaning it has not got.
pub fn statusTone(status: diff.Status) chrome_theme.Tone {
    return switch (status) {
        .added => .good,
        .deleted => .danger,
        .renamed, .copied => .info,
        .modified, .type_changed => .warn,
        .unmerged, .unknown => .neutral,
    };
}

/// Case-insensitive, digit-runs-compare-numerically ordering — the readable
/// half of Mac's `localizedStandardCompare`, which is what puts `T9.md` before
/// `T10.md` in a tracker directory instead of after it.
pub fn naturalLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = a[i];
        const cb = b[j];
        if (std.ascii.isDigit(ca) and std.ascii.isDigit(cb)) {
            var ei = i;
            while (ei < a.len and std.ascii.isDigit(a[ei])) ei += 1;
            var ej = j;
            while (ej < b.len and std.ascii.isDigit(b[ej])) ej += 1;
            const na = std.mem.trimLeft(u8, a[i..ei], "0");
            const nb = std.mem.trimLeft(u8, b[j..ej], "0");
            if (na.len != nb.len) return na.len < nb.len;
            if (!std.mem.eql(u8, na, nb)) return std.mem.lessThan(u8, na, nb);
            i = ei;
            j = ej;
            continue;
        }
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return la < lb;
        i += 1;
        j += 1;
    }
    if (a.len != b.len) return a.len < b.len;
    // Equal but for case: a stable, total order still has to pick one.
    return std.mem.lessThan(u8, a, b);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn file(path: []const u8, origin: diff.Origin) diff.File {
    return .{ .path = path, .status = .modified, .origin = origin };
}

fn expectRow(row: Row, kind: Kind, title: []const u8, depth: u8) !void {
    try testing.expectEqual(kind, row.kind);
    try testing.expectEqualStrings(title, row.title);
    try testing.expectEqual(depth, row.depth);
}

test "flat listing: files sorted, no folder rows" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("go.md", .committed),
        file("build.zig", .committed),
        file("CLAUDE.md", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 3), tree.rows.len);
    try expectRow(tree.rows[0], .file, "build.zig", 0);
    try expectRow(tree.rows[1], .file, "CLAUDE.md", 0);
    try expectRow(tree.rows[2], .file, "go.md", 0);
    try testing.expectEqual(@as(usize, 3), tree.fileRows());
}

test "folders come before files, and nest" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("README.md", .committed),
        file("src/main.zig", .committed),
        file("src/apprt.zig", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 4), tree.rows.len);
    try expectRow(tree.rows[0], .folder, "src", 0);
    try expectRow(tree.rows[1], .file, "apprt.zig", 1);
    try expectRow(tree.rows[2], .file, "main.zig", 1);
    try expectRow(tree.rows[3], .file, "README.md", 0);
}

test "a single-child directory chain collapses into one row" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/apprt/win32/ViewerPane.zig", .committed),
        file("src/apprt/win32/ViewerTOCPanel.zig", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 3), tree.rows.len);
    try expectRow(tree.rows[0], .folder, "src/apprt/win32", 0);
    try testing.expectEqualStrings("committed:src/apprt/win32", tree.rows[0].id);
    try expectRow(tree.rows[1], .file, "ViewerPane.zig", 1);
    try expectRow(tree.rows[2], .file, "ViewerTOCPanel.zig", 1);
}

test "a chain stops collapsing where the tree branches" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/apprt/win32/App.zig", .committed),
        file("src/apprt/gtk/App.zig", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try expectRow(tree.rows[0], .folder, "src/apprt", 0);
    try expectRow(tree.rows[1], .folder, "gtk", 1);
    try expectRow(tree.rows[2], .file, "App.zig", 2);
    try expectRow(tree.rows[3], .folder, "win32", 1);
    try expectRow(tree.rows[4], .file, "App.zig", 2);
}

test "a chain stops where a directory holds a file of its own" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("docs/design/notes.md", .committed),
        file("docs/README.md", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try expectRow(tree.rows[0], .folder, "docs", 0);
    try expectRow(tree.rows[1], .folder, "design", 1);
    try expectRow(tree.rows[2], .file, "notes.md", 2);
    try expectRow(tree.rows[3], .file, "README.md", 1);
}

test "a shut folder hides its whole subtree, and says it is shut" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/apprt/win32/App.zig", .committed),
        file("go.md", .committed),
    };
    const collapsed = [_][]const u8{"committed:src/apprt/win32"};
    var tree = try build(alloc, &files, &collapsed);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 2), tree.rows.len);
    try expectRow(tree.rows[0], .folder, "src/apprt/win32", 0);
    try testing.expect(tree.rows[0].collapsed);
    try expectRow(tree.rows[1], .file, "go.md", 0);
    // The hidden file is not a file row, so next/previous never steps onto
    // something the reader cannot see.
    try testing.expectEqual(@as(usize, 1), tree.fileRows());
}

test "a collapsed key that names nothing is ignored" {
    const alloc = testing.allocator;
    const files = [_]diff.File{file("src/main.zig", .committed)};
    const collapsed = [_][]const u8{"committed:docs/design"};
    var tree = try build(alloc, &files, &collapsed);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 2), tree.rows.len);
    try testing.expect(!tree.rows[0].collapsed);
}

test "working-tree sections, in git status order, with counts" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("c.txt", .untracked),
        file("a.txt", .unstaged),
        file("b.txt", .staged),
        file("d.txt", .staged),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try expectRow(tree.rows[0], .section, "Staged \u{00b7} 2", 0);
    try expectRow(tree.rows[1], .file, "b.txt", 1);
    try expectRow(tree.rows[2], .file, "d.txt", 1);
    try expectRow(tree.rows[3], .section, "Changes \u{00b7} 1", 0);
    try expectRow(tree.rows[4], .file, "a.txt", 1);
    try expectRow(tree.rows[5], .section, "Untracked \u{00b7} 1", 0);
    try expectRow(tree.rows[6], .file, "c.txt", 1);
    try testing.expectEqualStrings("section:staged", tree.rows[0].id);
}

test "a commit's diff has no section header at all" {
    const alloc = testing.allocator;
    const files = [_]diff.File{file("a.txt", .committed)};
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 1), tree.rows.len);
    try expectRow(tree.rows[0], .file, "a.txt", 0);
}

test "the same folder name in two sections gets two keys" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/a.zig", .staged),
        file("src/b.zig", .unstaged),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqualStrings("staged:src", tree.rows[1].id);
    try testing.expectEqualStrings("unstaged:src", tree.rows[4].id);
    // Shutting one leaves the other open — the key carries the origin for
    // exactly this reason.
    const collapsed = [_][]const u8{"staged:src"};
    var shut = try build(alloc, &files, &collapsed);
    defer shut.deinit();
    try testing.expectEqual(@as(usize, 1), shut.fileRows());
}

test "a file row's index reaches back into the caller's list" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("z.txt", .committed),
        file("a.txt", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 1), tree.rows[0].file);
    try testing.expectEqual(@as(usize, 0), tree.rows[1].file);
    try testing.expectEqualStrings("a.txt", files[tree.rows[0].file].path);
}

test "an empty listing is an empty tree, not a crash" {
    const alloc = testing.allocator;
    var tree = try build(alloc, &.{}, &.{});
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.rows.len);
    try testing.expectEqual(@as(usize, 0), tree.fileRows());
}

test "natural order: numbers compare as numbers, case is ignored" {
    try testing.expect(naturalLess("T9.md", "T10.md"));
    try testing.expect(!naturalLess("T10.md", "T9.md"));
    try testing.expect(naturalLess("apprt.zig", "Build.zig"));
    try testing.expect(naturalLess("T007.md", "T8.md"));
    try testing.expect(!naturalLess("a", "a"));
    // A total order: two spellings that differ only in case still order.
    try testing.expect(naturalLess("README.md", "readme.md"));
}

test "basename and parent" {
    try testing.expectEqualStrings("App.zig", baseName("src/apprt/App.zig"));
    try testing.expectEqualStrings("go.md", baseName("go.md"));
    try testing.expectEqualStrings("src/apprt", parentPath("src/apprt/App.zig").?);
    try testing.expect(parentPath("go.md") == null);
}

test "status tones: every git letter carries one meaning" {
    try testing.expectEqual(chrome_theme.Tone.good, statusTone(.added));
    try testing.expectEqual(chrome_theme.Tone.danger, statusTone(.deleted));
    try testing.expectEqual(chrome_theme.Tone.info, statusTone(.renamed));
    try testing.expectEqual(chrome_theme.Tone.info, statusTone(.copied));
    try testing.expectEqual(chrome_theme.Tone.warn, statusTone(.modified));
    try testing.expectEqual(chrome_theme.Tone.warn, statusTone(.type_changed));
    try testing.expectEqual(chrome_theme.Tone.neutral, statusTone(.unmerged));
    try testing.expectEqual(chrome_theme.Tone.neutral, statusTone(.unknown));
}

test "a status tone reads on the card, in both themes" {
    // The badge is drawn as ink over its own tint; both have to clear the
    // chrome floor against the card fill, which is what `toneInk` guarantees
    // and what a hand-picked RGB would not.
    const light = chrome_theme.Rgb{ .r = 0xF2, .g = 0xF2, .b = 0xF2 };
    const dark = chrome_theme.Rgb{ .r = 0x1C, .g = 0x1F, .b = 0x25 };
    for ([_]chrome_theme.Rgb{ light, dark }) |card| {
        for ([_]diff.Status{ .added, .deleted, .renamed, .modified, .unknown }) |st| {
            const ink = chrome_theme.toneInk(card, statusTone(st));
            const ratio = @import("color_math.zig").wcagContrastRatio(
                @import("color_math.zig").wcagLuminance(ink),
                @import("color_math.zig").wcagLuminance(card),
            );
            try testing.expect(ratio >= chrome_theme.ui_contrast_target - 0.01);
        }
    }
}

test "a file row copies the facts the card draws, rather than pointing at them" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        .{ .path = "a.txt", .status = .added, .origin = .committed, .additions = 12, .deletions = 3 },
        .{ .path = "b.bin", .status = .modified, .origin = .committed, .binary = true },
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(diff.Status.added, tree.rows[0].status);
    try testing.expectEqual(@as(u32, 12), tree.rows[0].additions);
    try testing.expectEqual(@as(u32, 3), tree.rows[0].deletions);
    try testing.expect(!tree.rows[0].binary);
    try testing.expect(tree.rows[1].binary);
}
