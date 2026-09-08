//! Bundled release notes: parsing and the new-since-your-last-version split
//! (T624) — the Windows counterpart of Mac's `ReleaseNotesStore.swift`.
//!
//! Pure and offline: no OS imports, no network, no filesystem. The JSON text
//! arrives from `release_notes_bundle.zig` (embedded at build time by
//! `src/build/GhosttyReleaseNotes.zig`) or, in tests, as string literals, so
//! this file's unit tests run in every app-runtime lane.
//!
//! What "new" means, mirroring Mac exactly:
//!
//!   - A version ABOVE the one the user last ran is new…
//!   - …unless it is above the version they are RUNNING, in which case it is
//!     dropped entirely. A build can carry notes for a release it is not (the
//!     repo's `release-notes/` is shared, and a dev build sits behind the tip),
//!     and announcing a release the user does not have is worse than silence.
//!   - Everything at or below the last-seen version is "already installed".
//!   - Both groups are newest-first.
//!
//! Version comparison is on the MAJOR.MINOR.PATCH triple only: the notes are
//! keyed by that triple (`1.34.0.json`), while the running build's version
//! string carries a pre-release and build stamp on dev and release builds
//! alike (`1.36.0-dev+abc1234`). Ordering those by full semver precedence
//! would rank a dev build BELOW the release it is built from and silently drop
//! that release's own notes — which is the one build where a developer is most
//! likely to open the window.

const std = @import("std");

/// One bullet. `title` is the bold lead of a `- **Title** — text` bullet;
/// a plain bullet leaves it null and carries the whole line in `text`.
pub const Note = struct {
    title: ?[]const u8 = null,
    text: []const u8,
};

/// A titled group of notes within a version (e.g. "Session persistence").
pub const Section = struct {
    title: []const u8,
    items: []const Note,
};

/// The notes for one version, as bundled in `release-notes/<scope>/<v>.json`.
pub const VersionNotes = struct {
    version: []const u8,
    sections: []const Section,
};

/// One bundled file as the generated module hands it over.
pub const Entry = struct {
    version: []const u8,
    json: []const u8,
};

/// The MAJOR.MINOR.PATCH triple of a version string, ignoring any
/// pre-release or build metadata. Null when the leading numbers are missing
/// or unparseable — a version nobody can order is never "newer" than
/// anything, so garbage in a bundle degrades to "already installed" rather
/// than to a crash or a bogus announcement.
pub fn triple(text: []const u8) ?[3]u32 {
    var out: [3]u32 = .{ 0, 0, 0 };
    var rest = text;
    // Stop at the first pre-release or build separator.
    if (std.mem.indexOfAny(u8, rest, "-+")) |cut| rest = rest[0..cut];

    var it = std.mem.splitScalar(u8, rest, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 3) break;
        if (part.len == 0) return null;
        out[i] = std.fmt.parseUnsigned(u32, part, 10) catch return null;
    }
    // A bare "1" or "1.2" is fine (missing components read as 0); nothing at
    // all is not.
    if (i == 0) return null;
    return out;
}

/// True iff `a` is strictly newer than `b`. An unorderable version on either
/// side answers false, so a malformed file can never be announced as news.
pub fn isNewer(a: []const u8, b: []const u8) bool {
    const ta = triple(a) orelse return false;
    const tb = triple(b) orelse return false;
    return std.mem.order(u32, &ta, &tb) == .gt;
}

/// Every bundled version's notes for one scope, decoded once.
///
/// Unreadable or malformed files are SKIPPED, not fatal (Mac's `compactMap`):
/// one bad file in the bundle must not cost the user the rest of the notes.
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    all: []const VersionNotes,

    /// Decode `entries`. The returned store owns everything it hands out;
    /// the entries' JSON text is only read, never retained.
    pub fn parse(gpa: std.mem.Allocator, entries: []const Entry) !Store {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var list: std.ArrayList(VersionNotes) = .empty;
        for (entries) |entry| {
            const parsed = std.json.parseFromSliceLeaky(
                VersionNotes,
                alloc,
                entry.json,
                .{ .ignore_unknown_fields = true },
            ) catch continue;
            try list.append(alloc, parsed);
        }

        return .{ .arena = arena, .all = try list.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    /// Split relative to `previous_seen` (null on a first run: everything at
    /// or below `current` is new), capping "new" at `current`. Both groups
    /// are newest-first and borrow from this store, so they must not outlive
    /// it. The caller frees the two slices with `Partitioned.deinit`.
    pub fn partition(
        self: *const Store,
        gpa: std.mem.Allocator,
        previous_seen: ?[]const u8,
        current: []const u8,
    ) !Partitioned {
        var fresh: std.ArrayList(VersionNotes) = .empty;
        errdefer fresh.deinit(gpa);
        var installed: std.ArrayList(VersionNotes) = .empty;
        errdefer installed.deinit(gpa);

        for (self.all) |notes| {
            const above_seen = if (previous_seen) |seen|
                isNewer(notes.version, seen)
            else
                true;
            if (above_seen) {
                // Above the running build: the bundle knows about a release
                // this app is not. Drop it rather than announce it.
                if (!isNewer(notes.version, current)) try fresh.append(gpa, notes);
            } else {
                try installed.append(gpa, notes);
            }
        }

        std.mem.sort(VersionNotes, fresh.items, {}, newestFirst);
        std.mem.sort(VersionNotes, installed.items, {}, newestFirst);
        return .{
            .fresh = try fresh.toOwnedSlice(gpa),
            .installed = try installed.toOwnedSlice(gpa),
        };
    }
};

fn newestFirst(_: void, a: VersionNotes, b: VersionNotes) bool {
    return isNewer(a.version, b.version);
}

/// The two groups a `Store` splits into. `fresh` is Mac's `new` (a Zig
/// keyword-adjacent name that reads badly on a struct field).
pub const Partitioned = struct {
    fresh: []const VersionNotes,
    installed: []const VersionNotes,

    pub fn deinit(self: *Partitioned, gpa: std.mem.Allocator) void {
        gpa.free(self.fresh);
        gpa.free(self.installed);
    }
};

/// Whether a release's section titles carry information, matching Mac's
/// `WhatsNewNotesContent.showsSectionTitles`: a lone section's title only
/// restates the tab it sits under ("Session persistence" under Agent), so it
/// is noise until a release splits into several.
pub fn showsSectionTitles(notes: VersionNotes) bool {
    return notes.sections.len > 1;
}

/// Introduces the releases the user is already running.
pub const installed_divider_label = "Changes already installed";

/// Shown in place of the new-notes list when there are none.
pub const no_new_notes_label = "No new release notes since your last update.";

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "triple: parses, tolerates short forms, ignores pre-release and build" {
    try testing.expectEqual([3]u32{ 1, 34, 0 }, triple("1.34.0").?);
    try testing.expectEqual([3]u32{ 1, 36, 0 }, triple("1.36.0-dev+abc1234").?);
    try testing.expectEqual([3]u32{ 1, 36, 2 }, triple("1.36.2+deadbee").?);
    try testing.expectEqual([3]u32{ 1, 0, 0 }, triple("1").?);
    try testing.expectEqual([3]u32{ 1, 5, 0 }, triple("1.5").?);
    try testing.expect(triple("") == null);
    try testing.expect(triple("banana") == null);
    try testing.expect(triple("1..0") == null);
}

test "isNewer: numeric, not lexicographic" {
    // The whole reason Mac passes `.numeric` to `compare`.
    try testing.expect(isNewer("1.10.0", "1.9.0"));
    try testing.expect(!isNewer("1.9.0", "1.10.0"));
    try testing.expect(isNewer("2.0.0", "1.99.99"));
    try testing.expect(!isNewer("1.34.0", "1.34.0"));
    try testing.expect(!isNewer("garbage", "1.0.0"));
    try testing.expect(!isNewer("1.0.0", "garbage"));
}

test "isNewer: a dev build is NOT older than the release it is built from" {
    // Full semver precedence would rank 1.36.0-dev below 1.36.0 and drop the
    // running release's own notes on every dev build.
    try testing.expect(!isNewer("1.36.0", "1.36.0-dev+abc1234"));
    try testing.expect(isNewer("1.36.1", "1.36.0-dev+abc1234"));
}

fn testEntry(comptime version: []const u8, comptime body: []const u8) Entry {
    return .{ .version = version, .json = body };
}

const sample = [_]Entry{
    testEntry("1.32.0",
        \\{"version":"1.32.0","sections":[{"title":"Old","items":[{"text":"old thing"}]}]}
    ),
    testEntry("1.33.0",
        \\{"version":"1.33.0","sections":[{"title":"Viewer panes","items":[
        \\{"title":"Links","text":"they open in your browser"},{"text":"plain bullet"}]}]}
    ),
    testEntry("1.34.0",
        \\{"version":"1.34.0","sections":[{"title":"A","items":[{"text":"a"}]},
        \\{"title":"B","items":[{"text":"b"}]}]}
    ),
    testEntry("1.35.0",
        \\{"version":"1.35.0","sections":[{"title":"Future","items":[{"text":"unreleased"}]}]}
    ),
};

test "Store.parse: decodes titles, plain bullets and multiple sections" {
    var store = try Store.parse(testing.allocator, &sample);
    defer store.deinit();
    try testing.expectEqual(@as(usize, 4), store.all.len);

    const v133 = store.all[1];
    try testing.expectEqualStrings("1.33.0", v133.version);
    try testing.expectEqual(@as(usize, 1), v133.sections.len);
    try testing.expectEqualStrings("Viewer panes", v133.sections[0].title);
    try testing.expectEqualStrings("Links", v133.sections[0].items[0].title.?);
    try testing.expectEqualStrings("they open in your browser", v133.sections[0].items[0].text);
    try testing.expect(v133.sections[0].items[1].title == null);
    try testing.expect(!showsSectionTitles(v133));
    try testing.expect(showsSectionTitles(store.all[2]));
}

test "Store.parse: a malformed file costs only itself" {
    const entries = [_]Entry{
        testEntry("1.33.0",
            \\{"version":"1.33.0","sections":[]}
        ),
        testEntry("1.33.1", "{ this is not json"),
        testEntry("1.33.2",
            \\{"sections":[]}
        ), // missing required "version"
        testEntry("1.34.0",
            \\{"version":"1.34.0","sections":[]}
        ),
    };
    var store = try Store.parse(testing.allocator, &entries);
    defer store.deinit();
    try testing.expectEqual(@as(usize, 2), store.all.len);
    try testing.expectEqualStrings("1.33.0", store.all[0].version);
    try testing.expectEqualStrings("1.34.0", store.all[1].version);
}

test "partition: new since last seen, capped at the running version" {
    var store = try Store.parse(testing.allocator, &sample);
    defer store.deinit();

    var split = try store.partition(testing.allocator, "1.32.0", "1.34.0");
    defer split.deinit(testing.allocator);

    // Newest-first, 1.35.0 dropped for being above the running build.
    try testing.expectEqual(@as(usize, 2), split.fresh.len);
    try testing.expectEqualStrings("1.34.0", split.fresh[0].version);
    try testing.expectEqualStrings("1.33.0", split.fresh[1].version);
    try testing.expectEqual(@as(usize, 1), split.installed.len);
    try testing.expectEqualStrings("1.32.0", split.installed[0].version);
}

test "partition: first run has no anchor, so everything installed is new" {
    var store = try Store.parse(testing.allocator, &sample);
    defer store.deinit();

    var split = try store.partition(testing.allocator, null, "1.34.0");
    defer split.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), split.fresh.len);
    try testing.expectEqualStrings("1.34.0", split.fresh[0].version);
    try testing.expectEqualStrings("1.32.0", split.fresh[2].version);
    try testing.expectEqual(@as(usize, 0), split.installed.len);
}

test "partition: nothing new when the user has already seen the running build" {
    var store = try Store.parse(testing.allocator, &sample);
    defer store.deinit();

    var split = try store.partition(testing.allocator, "1.34.0", "1.34.0");
    defer split.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), split.fresh.len);
    // 1.35.0 is above current AND above seen, so it is dropped rather than
    // filed under "already installed" — the user does not have it either.
    try testing.expectEqual(@as(usize, 3), split.installed.len);
    try testing.expectEqualStrings("1.34.0", split.installed[0].version);
}

test "partition: newest-first ordering is numeric" {
    const entries = [_]Entry{
        testEntry("1.9.0",
            \\{"version":"1.9.0","sections":[]}
        ),
        testEntry("1.10.0",
            \\{"version":"1.10.0","sections":[]}
        ),
    };
    var store = try Store.parse(testing.allocator, &entries);
    defer store.deinit();

    var split = try store.partition(testing.allocator, null, "1.10.0");
    defer split.deinit(testing.allocator);
    try testing.expectEqualStrings("1.10.0", split.fresh[0].version);
    try testing.expectEqualStrings("1.9.0", split.fresh[1].version);
}
