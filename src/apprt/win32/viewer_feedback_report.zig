//! One feedback report, from the composer's text to a folder on disk (T636,
//! the win32 half of Mac's `ViewerFeedbackReport`).
//!
//! The FORMAT is shared with macOS — the queue is drained by one external
//! watcher that must not care which viewer produced a report — so every JSON
//! key below is spelled the way Mac's `JSONEncoder` spells it, camelCase and
//! all, rather than the snake_case this codebase uses for its own on-disk
//! files. That is why the payload structs are a separate layer from `Context`:
//! the wire names are a contract, and a rename that looked like a tidy-up
//! would quietly fork the format.
//!
//! Everything here is pure logic plus plain `std.fs`, so it is unit tested in
//! the `-Dapp-runtime=none` lane like the rest of `apprt/win32`'s pure modules.
//! `ViewerPane.sendFeedback` is the only caller.
//!
//! ## Layout on disk — one self-contained folder per report
//!
//! ```
//! <worktree>/temp/feedback/new/20260809T004912Z-a3f9c2/
//!     report.json
//!     images/image-1.png        (T637; the array is empty until then)
//! ```
//!
//! Everything for a submission lives together, so a report can be moved,
//! archived, or handed to an agent as one unit — `move new\<stem>
//! in-progress\<stem>` is a single rename, and the report's image paths are
//! folder-relative so they survive it.
//!
//! ## Atomicity is the load-bearing property
//!
//! The whole folder is built under `temp/feedback/.staging/<stem>` and moved
//! into `new/` with a SINGLE rename, so a watcher scanning `new/` sees either
//! nothing or a complete report. Staging under `temp/feedback/` rather than
//! `%TEMP%` is what keeps it on the same volume: `std.fs.renameAbsolute` is
//! `MoveFileExW` WITHOUT `MOVEFILE_COPY_ALLOWED`, so a cross-volume attempt
//! fails loudly instead of silently degrading into a non-atomic copy loop —
//! which is exactly the failure a watcher would see as a half-written report.
//!
//! ## JSON, not markdown-with-frontmatter
//!
//! The body is free-form multi-line prose. A body containing a `---` line, or
//! a line that looks like `key: value`, breaks naive frontmatter splitting;
//! JSON escapes newlines inside a string and has exactly one parse path in
//! every language. The body VALUE is still markdown, so a watcher that prints
//! `report["body"]` gets a readable document with working image links.
const std = @import("std");
const Allocator = std.mem.Allocator;

const doc = @import("viewer_feedback_doc.zig");

/// Schema version of the emitted JSON, matching Mac's. Bumped there to 2 when
/// reports moved into per-report folders and gained the full context; win32
/// has only ever written that shape.
pub const schema_version = 2;

/// `temp/` is gitignored here and in most repos; a bare `.feedback/` was not,
/// so filed reports dirtied `git status`.
pub const temp_dir_name = "temp";
pub const queue_dir_name = "feedback";
pub const new_dir_name = "new";
pub const staging_dir_name = ".staging";
pub const report_file_name = "report.json";
pub const images_dir_name = "images";

/// Worktree-relative path of the queue reports land in, for display. Written
/// with `/` because it is shown to a human and read by the shared watcher.
pub const queue_relative_path = temp_dir_name ++ "/" ++ queue_dir_name ++ "/" ++ new_dir_name;

pub const WriteError = error{
    /// Nothing to file: the composer trimmed away to nothing.
    Empty,
};

// -----------------------------------------------------------------------------
// Naming
// -----------------------------------------------------------------------------

/// Bytes a stem needs: `yyyymmddTHHMMSSZ` + `-` + six hex.
pub const stem_len = 16 + 1 + 6;

/// A sortable, collision-free folder name: UTC timestamp to the second plus a
/// short random suffix. Lexicographic order equals chronological order, which
/// is what lets a watcher drain the queue oldest-first with a plain directory
/// sort.
///
/// The `:`-free timestamp spelling is not cosmetic on this platform: NTFS
/// reserves `:` for alternate data streams, so an ISO-8601-with-colons stem —
/// which is what a naive port of Mac's format would produce — cannot be a
/// directory name here at all. `stemIsFilenameSafe` asserts the whole
/// reserved set rather than just that one character.
pub fn makeStem(buf: *[stem_len]u8, epoch_secs: u64, suffix: u24) []const u8 {
    var ts: [16]u8 = undefined;
    _ = formatStamp(&ts, epoch_secs);
    return std.fmt.bufPrint(buf, "{s}-{x:0>6}", .{ ts, suffix }) catch unreachable;
}

/// `yyyymmddTHHMMSSZ` — the stem's time half.
fn formatStamp(buf: *[16]u8, epoch_secs: u64) []const u8 {
    const c = civil(epoch_secs);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        c.year, c.month, c.day, c.hour, c.minute, c.second,
    }) catch unreachable;
}

/// `yyyy-mm-ddThh:mm:ssZ` — the report's `created`, Mac's
/// `ISO8601DateFormatter` with `.withInternetDateTime` in UTC.
pub fn formatCreated(buf: *[20]u8, epoch_secs: u64) []const u8 {
    const c = civil(epoch_secs);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        c.year, c.month, c.day, c.hour, c.minute, c.second,
    }) catch unreachable;
}

const Civil = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn civil(epoch_secs: u64) Civil {
    const es: std.time.epoch.EpochSeconds = .{ .secs = epoch_secs };
    const day = es.getEpochDay();
    const time = es.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = time.getHoursIntoDay(),
        .minute = time.getMinutesIntoHour(),
        .second = time.getSecondsIntoMinute(),
    };
}

/// Whether `stem` can be a directory name on this filesystem. Every character
/// Windows reserves, not only the `:` that a timestamp would introduce — the
/// point is that the ANSWER is checkable rather than that one known hazard is
/// dodged.
pub fn stemIsFilenameSafe(stem: []const u8) bool {
    if (stem.len == 0) return false;
    for (stem) |c| {
        if (c < 0x20) return false;
        switch (c) {
            '<', '>', ':', '"', '/', '\\', '|', '?', '*' => return false,
            else => {},
        }
    }
    // A trailing dot or space is legal to create through some APIs and
    // unopenable afterwards.
    return stem[stem.len - 1] != '.' and stem[stem.len - 1] != ' ';
}

/// An image's path relative to the report folder — `/`-separated, because the
/// consumer is shared and a `\` in a markdown link is an escape, not a
/// separator (T637 writes the files these name).
pub fn imageRelativePath(buf: []u8, number: u32) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/image-{d}.png", .{ images_dir_name, number }) catch null;
}

// -----------------------------------------------------------------------------
// Body
// -----------------------------------------------------------------------------

/// The composer's text as the report's markdown body: every live quote block
/// becomes a real markdown blockquote, everything else is what the user typed.
///
/// The composer stores a passage WITHOUT its `> ` prefixes (that is what makes
/// `Registry.live` able to find it again by text), so the prefixes are added
/// exactly here, once, on the way out. `spans` is what `live` returned, so a
/// block the user deleted is simply not in it.
pub fn renderBody(alloc: Allocator, text: []const u8, spans: []const doc.Span) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var at: usize = 0;
    for (spans) |s| {
        if (s.start < at or s.end > text.len or s.end < s.start) continue;
        try out.appendSlice(alloc, text[at..s.start]);
        try appendQuoted(alloc, &out, text[s.start..s.end]);
        at = s.end;
    }
    try out.appendSlice(alloc, text[at..]);

    // A report that ends in the blank line the composer parks the caret on
    // reads as unfinished; the leading side is trimmed for the same reason.
    const body = std.mem.trim(u8, out.items, " \t\r\n");
    const owned = try alloc.dupe(u8, body);
    out.deinit(alloc);
    return owned;
}

fn appendQuoted(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), passage: []const u8) !void {
    var it = std.mem.splitScalar(u8, passage, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(alloc, '\n');
        first = false;
        // A blank line inside a quote keeps its marker, or the block splits
        // into two blockquotes when it is rendered.
        try out.appendSlice(alloc, "> ");
        try out.appendSlice(alloc, line);
    }
}

// -----------------------------------------------------------------------------
// Source line
// -----------------------------------------------------------------------------

/// The 1-based line of `source` where a quoted passage appears, or null.
///
/// The quote comes from RENDERED text, so it rarely matches the source
/// byte-for-byte (markdown syntax, wrapped lines, collapsed whitespace).
/// Mac's ladder, ported: try the passage's first non-blank line verbatim, then
/// a whitespace-normalized, case-folded comparison — and give up honestly
/// rather than report a line that might be wrong. Mapping the rendered DOM
/// back to markdown source is unreliable; searching the file is not.
///
/// Null on allocation failure too: a missing line number is a degraded report,
/// a wrong one is a misleading one.
pub fn sourceLine(alloc: Allocator, source: []const u8, passage: []const u8) ?u32 {
    const needle = std.mem.trim(u8, passage, " \t\r\n");
    if (needle.len == 0) return null;

    // Wrapped rendering means only the first line is likely contiguous in the
    // source, so that is what is searched for.
    const first_line = blk: {
        var it = std.mem.splitScalar(u8, needle, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len != 0) break :blk t;
        }
        break :blk needle;
    };

    {
        var it = std.mem.splitScalar(u8, source, '\n');
        var n: u32 = 0;
        while (it.next()) |line| {
            n += 1;
            if (std.mem.indexOf(u8, line, first_line) != null) return n;
        }
    }

    const target = collapse(alloc, first_line) catch return null;
    defer alloc.free(target);
    if (target.len == 0) return null;

    var it = std.mem.splitScalar(u8, source, '\n');
    var n: u32 = 0;
    while (it.next()) |line| {
        n += 1;
        const flat = collapse(alloc, line) catch return null;
        defer alloc.free(flat);
        if (std.mem.indexOf(u8, flat, target) != null) return n;
    }
    return null;
}

/// Runs of whitespace to one space, ASCII case folded, ends trimmed. Caller
/// frees.
fn collapse(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var space = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            space = out.items.len != 0;
            continue;
        }
        if (space) try out.append(alloc, ' ');
        space = false;
        try out.append(alloc, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(alloc);
}

// -----------------------------------------------------------------------------
// Paths
// -----------------------------------------------------------------------------

/// `file_path` expressed relative to `root`, `/`-separated — the form a coding
/// agent actually wants (`src/apprt/win32/ViewerPane.zig`, not
/// `D:\git\ghoztty\src\…`). Null when the file is not under the root at all.
///
/// The comparison is case- and separator-insensitive because both halves come
/// from different places: git prints forward slashes and whatever case the
/// repo was cloned with, while the pane's location came from the shell.
pub fn relativePath(buf: []u8, file_path: []const u8, root_in: []const u8) ?[]const u8 {
    const root = std.mem.trimRight(u8, root_in, "\\/");
    if (root.len == 0 or file_path.len <= root.len + 1) return null;
    for (root, 0..) |c, i| {
        if (!sameChar(c, file_path[i])) return null;
    }
    const sep = file_path[root.len];
    if (sep != '\\' and sep != '/') return null;

    const rest = file_path[root.len + 1 ..];
    if (rest.len == 0 or rest.len > buf.len) return null;
    for (rest, 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    return buf[0..rest.len];
}

fn sameChar(a: u8, b: u8) bool {
    const na = if (a == '/') '\\' else std.ascii.toLower(a);
    const nb = if (b == '/') '\\' else std.ascii.toLower(b);
    return na == nb;
}

// -----------------------------------------------------------------------------
// Payload
// -----------------------------------------------------------------------------

/// One quoted passage plus the references that let a reader locate it — the
/// composer's registry entry with `sourceLine` resolved.
pub const Quote = struct {
    number: u32,
    text: []const u8,
    heading_id: ?[]const u8 = null,
    heading_text: ?[]const u8 = null,
    block_selector: ?[]const u8 = null,
    block_text: ?[]const u8 = null,
    offset_in_block: ?u32 = null,
    document_offset: ?u32 = null,
    source_line: ?u32 = null,
};

/// Everything known about WHAT the feedback is about. The point of a report is
/// that a downstream agent can act on it without asking follow-up questions,
/// so this is deliberately generous: where the user was, what they had
/// selected, and which revision they were looking at.
pub const Context = struct {
    /// The location as displayed (URL or absolute file path).
    location: []const u8,
    /// `"file"` or `"web"` — lets a reader branch without parsing `location`.
    kind: []const u8,
    /// Absolute path of the viewed file, when file-backed.
    file_path: ?[]const u8 = null,
    /// `file_path` relative to the worktree root, `/`-separated.
    relative_path: ?[]const u8 = null,
    /// The page's own title (web) or the file name.
    page_title: ?[]const u8 = null,
    /// Text the user had SELECTED in the page — what they were pointing at.
    selection: ?[]const u8 = null,
    /// The viewer pane's stable ghoztty id.
    pane_id: ?[]const u8 = null,
    /// Pane size in DIPs, e.g. "820x540" — tells a reader whether a layout
    /// complaint was at a narrow width.
    viewport: ?[]const u8 = null,
    /// The worktree the report is filed into.
    worktree_path: []const u8,
    worktree_name: []const u8,
    /// Branch and commit of that worktree, so a report can be replayed against
    /// the exact revision the user saw. Null on a detached HEAD / an unborn
    /// repo, which is a real state and not a guess.
    branch: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    app_version: ?[]const u8 = null,
};

// The four structs below ARE the wire format. Their field names are the JSON
// keys, spelled exactly as Mac emits them — including `paneID`'s capital D and
// `headingId`'s lowercase one, which disagree with each other and are kept
// anyway, because the watcher reading them is shared.

const PayloadSource = struct {
    location: []const u8,
    kind: []const u8,
    filePath: ?[]const u8 = null,
    relativePath: ?[]const u8 = null,
    pageTitle: ?[]const u8 = null,
    selection: ?[]const u8 = null,
    paneID: ?[]const u8 = null,
    viewport: ?[]const u8 = null,
};

const PayloadWorktree = struct {
    path: []const u8,
    name: []const u8,
    branch: ?[]const u8 = null,
    commit: ?[]const u8 = null,
};

const PayloadQuote = struct {
    number: u32,
    text: []const u8,
    headingId: ?[]const u8 = null,
    headingText: ?[]const u8 = null,
    blockSelector: ?[]const u8 = null,
    blockText: ?[]const u8 = null,
    offsetInBlock: ?u32 = null,
    documentOffset: ?u32 = null,
    sourceLine: ?u32 = null,
};

const PayloadApp = struct {
    name: []const u8 = "Ghoztty",
    version: ?[]const u8 = null,
};

const PayloadImage = struct {
    number: u32,
    path: []const u8,
    pixelWidth: ?u32 = null,
    pixelHeight: ?u32 = null,
    bytes: u64,
};

const Payload = struct {
    version: u32 = schema_version,
    id: []const u8,
    created: []const u8,
    body: []const u8,
    source: PayloadSource,
    worktree: PayloadWorktree,
    app: PayloadApp,
    quotes: []const PayloadQuote,
    /// Always present, empty until T637 pastes images into the composer. A
    /// present-but-empty array is what tells a reader "no images" apart from
    /// "written by something that did not know about images".
    images: []const PayloadImage = &.{},
};

/// Serialize one report. Caller frees.
///
/// Absent optionals are DROPPED rather than emitted as `null`, which is what
/// Swift's `JSONEncoder` does with a nil property — so a report written here
/// and one written on a Mac have the same key set for the same content.
pub fn serialize(
    alloc: Allocator,
    stem: []const u8,
    created: []const u8,
    body: []const u8,
    ctx: Context,
    quotes: []const Quote,
) ![]u8 {
    var payload_quotes = try alloc.alloc(PayloadQuote, quotes.len);
    defer alloc.free(payload_quotes);
    for (quotes, 0..) |q, i| payload_quotes[i] = .{
        .number = q.number,
        .text = q.text,
        .headingId = q.heading_id,
        .headingText = q.heading_text,
        .blockSelector = q.block_selector,
        .blockText = q.block_text,
        .offsetInBlock = q.offset_in_block,
        .documentOffset = q.document_offset,
        .sourceLine = q.source_line,
    };

    const payload: Payload = .{
        .id = stem,
        .created = created,
        .body = body,
        .source = .{
            .location = ctx.location,
            .kind = ctx.kind,
            .filePath = ctx.file_path,
            .relativePath = ctx.relative_path,
            .pageTitle = ctx.page_title,
            .selection = ctx.selection,
            .paneID = ctx.pane_id,
            .viewport = ctx.viewport,
        },
        .worktree = .{
            .path = ctx.worktree_path,
            .name = ctx.worktree_name,
            .branch = ctx.branch,
            .commit = ctx.commit,
        },
        .app = .{ .version = ctx.app_version },
        .quotes = payload_quotes,
    };

    return std.json.Stringify.valueAlloc(alloc, payload, .{
        .emit_null_optional_fields = false,
        .whitespace = .indent_2,
    });
}

// -----------------------------------------------------------------------------
// Writing
// -----------------------------------------------------------------------------

/// What landed on disk. Owned by the caller.
pub const Written = struct {
    /// The published folder, absolute.
    folder: []u8,
    /// Its name — the sortable stem, which is also the report's `id`.
    stem: []u8,

    pub fn deinit(self: Written, alloc: Allocator) void {
        alloc.free(self.folder);
        alloc.free(self.stem);
    }
};

/// Build the report folder under `.staging/` and publish it into `new/` with a
/// single rename. See the header for why the two directories are siblings.
///
/// `epoch_secs` and `suffix` are injected rather than read here so a test can
/// assert an exact folder name; `ViewerPane` passes the wall clock and a
/// random 24-bit suffix.
pub fn write(
    alloc: Allocator,
    ctx: Context,
    body: []const u8,
    quotes: []const Quote,
    epoch_secs: u64,
    suffix: u24,
) !Written {
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return WriteError.Empty;

    var stem_buf: [stem_len]u8 = undefined;
    const stem = makeStem(&stem_buf, epoch_secs, suffix);
    std.debug.assert(stemIsFilenameSafe(stem));

    var created_buf: [20]u8 = undefined;
    const created = formatCreated(&created_buf, epoch_secs);

    const json = try serialize(alloc, stem, created, body, ctx, quotes);
    defer alloc.free(json);

    const feedback_dir = try std.fs.path.join(alloc, &.{
        ctx.worktree_path, temp_dir_name, queue_dir_name,
    });
    defer alloc.free(feedback_dir);
    const staging = try std.fs.path.join(alloc, &.{ feedback_dir, staging_dir_name, stem });
    defer alloc.free(staging);
    const queue = try std.fs.path.join(alloc, &.{ feedback_dir, new_dir_name });
    defer alloc.free(queue);
    const final = try std.fs.path.join(alloc, &.{ queue, stem });
    errdefer alloc.free(final);

    // The queue directory has to exist BEFORE the rename, or the publish fails
    // with the report already assembled.
    try std.fs.cwd().makePath(queue);
    try std.fs.cwd().makePath(staging);
    // A staging folder left behind by a failed write would be swept up by the
    // next one only by luck, so this write owns its own cleanup.
    errdefer std.fs.cwd().deleteTree(staging) catch {};

    {
        const report_path = try std.fs.path.join(alloc, &.{ staging, report_file_name });
        defer alloc.free(report_path);
        var file = try std.fs.cwd().createFile(report_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
    }

    try std.fs.cwd().rename(staging, final);

    return .{ .folder = final, .stem = try alloc.dupe(u8, stem) };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

/// 2026-08-09T00:49:12Z, the moment this module was written.
const sample_epoch: u64 = 1786236552;

test "makeStem: sortable, and a legal directory name on NTFS" {
    var buf: [stem_len]u8 = undefined;
    const stem = makeStem(&buf, sample_epoch, 0xa3f9c2);
    try testing.expectEqualStrings("20260809T004912Z-a3f9c2", stem);
    try testing.expectEqual(stem_len, stem.len);

    // The whole point of the compact spelling: Mac's `ISO8601` stem carries
    // colons, and a colon cannot be in an NTFS directory name at all.
    try testing.expect(stemIsFilenameSafe(stem));
    try testing.expect(std.mem.indexOfScalar(u8, stem, ':') == null);

    // Lexicographic order is chronological order — what lets a watcher drain
    // the queue oldest-first with a plain directory sort.
    var later: [stem_len]u8 = undefined;
    const later_stem = makeStem(&later, sample_epoch + 1, 0x000001);
    try testing.expect(std.mem.order(u8, stem, later_stem) == .lt);

    // The suffix is what breaks a tie inside one second.
    var same: [stem_len]u8 = undefined;
    const same_second = makeStem(&same, sample_epoch, 0x000001);
    try testing.expect(!std.mem.eql(u8, stem, same_second));
    try testing.expectEqualStrings(stem[0..16], same_second[0..16]);
}

test "stemIsFilenameSafe: every character Windows reserves" {
    try testing.expect(stemIsFilenameSafe("20260809T004912Z-a3f9c2"));
    const bad = [_][]const u8{
        "", "a:b", "a/b", "a\\b", "a<b", "a>b", "a\"b", "a|b", "a?b", "a*b",
        "a\tb", "trailing.", "trailing ",
    };
    for (bad) |s| {
        if (stemIsFilenameSafe(s)) {
            std.debug.print("expected unsafe: '{s}'\n", .{s});
            return error.ShouldBeUnsafe;
        }
    }
}

test "formatCreated: the internet date-time Mac writes" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings(
        "2026-08-09T00:49:12Z",
        formatCreated(&buf, sample_epoch),
    );
    // The epoch itself, so a bad civil-date conversion cannot hide behind one
    // hand-computed constant.
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", formatCreated(&buf, 0));
    // A leap day, which is where a naive month table goes wrong.
    try testing.expectEqualStrings("2024-02-29T12:00:00Z", formatCreated(&buf, 1709208000));
}

test "renderBody: a live quote becomes a real markdown blockquote" {
    const alloc = testing.allocator;
    // What the composer holds after Quote + a sentence: the passage on lines
    // of its own, WITHOUT the `> ` prefixes.
    const text = "this is wrong:\n\nthe passage\n\nbecause of X\n\n";
    const spans = [_]doc.Span{.{ .start = 16, .end = 27, .index = 0 }};
    const body = try renderBody(alloc, text, &spans);
    defer alloc.free(body);
    try testing.expectEqualStrings(
        "this is wrong:\n\n> the passage\n\nbecause of X",
        body,
    );
}

test "renderBody: no quotes is the text, trimmed" {
    const alloc = testing.allocator;
    const body = try renderBody(alloc, "\n  just my own words\n\n", &.{});
    defer alloc.free(body);
    try testing.expectEqualStrings("just my own words", body);
}

test "renderBody: a multi-line quote keeps a marker on every line" {
    const alloc = testing.allocator;
    // A blank line inside the block matters: without its own marker the quote
    // renders as two separate blockquotes.
    const passage = "line one\n\nline three";
    const text = passage ++ "\n\nmy comment\n";
    const spans = [_]doc.Span{.{ .start = 0, .end = passage.len, .index = 0 }};
    const body = try renderBody(alloc, text, &spans);
    defer alloc.free(body);
    try testing.expectEqualStrings(
        "> line one\n> \n> line three\n\nmy comment",
        body,
    );
}

test "renderBody: two quotes, and the text between them is untouched" {
    const alloc = testing.allocator;
    const text = "a\n\nfirst\n\nb\n\nsecond\n\nc";
    const spans = [_]doc.Span{
        .{ .start = 3, .end = 8, .index = 0 },
        .{ .start = 13, .end = 19, .index = 1 },
    };
    const body = try renderBody(alloc, text, &spans);
    defer alloc.free(body);
    try testing.expectEqualStrings("a\n\n> first\n\nb\n\n> second\n\nc", body);
}

test "sourceLine: a passage is found, and one that is not there is null" {
    const alloc = testing.allocator;
    const source =
        \\# Alpha
        \\
        \\a paragraph under the first heading
        \\
        \\## Beta
        \\
        \\ghoztty quoted this passage
        \\
    ;
    try testing.expectEqual(
        @as(?u32, 7),
        sourceLine(alloc, source, "ghoztty quoted this passage"),
    );
    try testing.expectEqual(@as(?u32, 1), sourceLine(alloc, source, "Alpha"));
    // Honest silence rather than a confident guess — the whole rule.
    try testing.expectEqual(
        @as(?u32, null),
        sourceLine(alloc, source, "a sentence that is nowhere in the file"),
    );
    try testing.expectEqual(@as(?u32, null), sourceLine(alloc, source, "   \n "));
}

test "sourceLine: rendered text that lost the source's whitespace still lands" {
    const alloc = testing.allocator;
    // Markdown wraps and collapses runs of spaces; the rendered passage the
    // user quoted therefore rarely matches the source byte-for-byte.
    const source = "intro\n\nthe   quick     brown fox\n";
    try testing.expectEqual(
        @as(?u32, 3),
        sourceLine(alloc, source, "The quick brown fox"),
    );
}

test "sourceLine: a multi-line quote is located by its first line" {
    const alloc = testing.allocator;
    const source = "one\ntwo\nthree\n";
    // A passage spanning several lines is located by its first — the rest may
    // have been re-wrapped by the renderer.
    try testing.expectEqual(@as(?u32, 2), sourceLine(alloc, source, "\ntwo\nthree"));

    // And when the RENDERER is what joined two source lines, no single source
    // line contains the passage and the answer is an honest null. Reporting
    // the line the passage merely starts on would be a guess, and the rule is
    // that a wrong line is worse than no line.
    try testing.expectEqual(@as(?u32, null), sourceLine(alloc, source, "two three"));
}

test "relativePath: repo-relative and forward-slashed" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "src/apprt/win32/ViewerPane.zig",
        relativePath(
            &buf,
            "D:\\git\\ghoztty\\src\\apprt\\win32\\ViewerPane.zig",
            "D:\\git\\ghoztty",
        ).?,
    );
    // git prints forward slashes and whatever case the clone has; the pane's
    // location came from a shell. Neither difference may lose the path.
    try testing.expectEqualStrings(
        "src/main.zig",
        relativePath(&buf, "d:/GIT/Ghoztty/src/main.zig", "D:\\git\\ghoztty\\").?,
    );
    // Not under the root at all.
    try testing.expect(relativePath(&buf, "C:\\other\\x.md", "D:\\git\\ghoztty") == null);
    // A near-miss that a plain prefix compare would accept.
    try testing.expect(relativePath(&buf, "D:\\git\\ghoztty2\\x.md", "D:\\git\\ghoztty") == null);
    // The root itself is not a relative path.
    try testing.expect(relativePath(&buf, "D:\\git\\ghoztty", "D:\\git\\ghoztty") == null);
}

test "imageRelativePath: folder-relative, so the folder can be moved" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("images/image-3.png", imageRelativePath(&buf, 3).?);
}

/// The context a test files with, pointed at `root`.
fn sampleContext(root: []const u8) Context {
    return .{
        .location = "D:\\repo\\docs\\design.md",
        .kind = "file",
        .file_path = "D:\\repo\\docs\\design.md",
        .relative_path = "docs/design.md",
        .page_title = "design.md",
        .selection = "the sentence they were pointing at",
        .pane_id = "F08888B0-A73E-4554-86DB-5A11F6BCEFDB",
        .viewport = "820x540",
        .worktree_path = root,
        .worktree_name = "repo",
        .branch = "users/dzearing/windows-amd64",
        .commit = "426db6e83c1f0a2b3c4d5e6f708192a3b4c5d6e7",
        .app_version = "1.2.3",
    };
}

test "serialize: every context block round-trips, and absent optionals are absent" {
    const alloc = testing.allocator;
    const quotes = [_]Quote{.{
        .number = 1,
        .text = "the passage",
        .heading_id = "beta",
        .heading_text = "Beta",
        .block_selector = "article > p:nth-of-type(2)",
        .block_text = "the whole paragraph",
        .offset_in_block = 12,
        .document_offset = 345,
        .source_line = 7,
    }};
    const json = try serialize(
        alloc,
        "20260809T004912Z-a3f9c2",
        "2026-08-09T00:49:12Z",
        "this is wrong\n\n> the passage",
        sampleContext("D:\\repo"),
        &quotes,
    );
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try testing.expectEqual(@as(i64, schema_version), root.get("version").?.integer);
    try testing.expectEqualStrings("20260809T004912Z-a3f9c2", root.get("id").?.string);
    try testing.expectEqualStrings("2026-08-09T00:49:12Z", root.get("created").?.string);
    try testing.expectEqualStrings("this is wrong\n\n> the passage", root.get("body").?.string);

    const source = root.get("source").?.object;
    try testing.expectEqualStrings("D:\\repo\\docs\\design.md", source.get("location").?.string);
    try testing.expectEqualStrings("file", source.get("kind").?.string);
    try testing.expectEqualStrings("D:\\repo\\docs\\design.md", source.get("filePath").?.string);
    try testing.expectEqualStrings("docs/design.md", source.get("relativePath").?.string);
    try testing.expectEqualStrings("design.md", source.get("pageTitle").?.string);
    try testing.expectEqualStrings(
        "the sentence they were pointing at",
        source.get("selection").?.string,
    );
    // Mac spells this one with a capital D and the quote fields with a small
    // one. Both spellings are the contract.
    try testing.expectEqualStrings(
        "F08888B0-A73E-4554-86DB-5A11F6BCEFDB",
        source.get("paneID").?.string,
    );
    try testing.expectEqualStrings("820x540", source.get("viewport").?.string);

    const worktree = root.get("worktree").?.object;
    try testing.expectEqualStrings("D:\\repo", worktree.get("path").?.string);
    try testing.expectEqualStrings("repo", worktree.get("name").?.string);
    try testing.expectEqualStrings(
        "users/dzearing/windows-amd64",
        worktree.get("branch").?.string,
    );
    try testing.expectEqualStrings(
        "426db6e83c1f0a2b3c4d5e6f708192a3b4c5d6e7",
        worktree.get("commit").?.string,
    );

    const app = root.get("app").?.object;
    try testing.expectEqualStrings("Ghoztty", app.get("name").?.string);
    try testing.expectEqualStrings("1.2.3", app.get("version").?.string);

    const q = root.get("quotes").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 1), q.get("number").?.integer);
    try testing.expectEqualStrings("the passage", q.get("text").?.string);
    try testing.expectEqualStrings("beta", q.get("headingId").?.string);
    try testing.expectEqualStrings("Beta", q.get("headingText").?.string);
    try testing.expectEqualStrings(
        "article > p:nth-of-type(2)",
        q.get("blockSelector").?.string,
    );
    try testing.expectEqualStrings("the whole paragraph", q.get("blockText").?.string);
    try testing.expectEqual(@as(i64, 12), q.get("offsetInBlock").?.integer);
    try testing.expectEqual(@as(i64, 345), q.get("documentOffset").?.integer);
    try testing.expectEqual(@as(i64, 7), q.get("sourceLine").?.integer);

    // Present but empty until T637 — which is how a reader tells "no images"
    // apart from "written by a build that had none".
    try testing.expectEqual(@as(usize, 0), root.get("images").?.array.items.len);
}

test "serialize: an absent optional is dropped, not written as null" {
    const alloc = testing.allocator;
    // A web pane on a detached HEAD: no file, no branch, no quotes.
    const ctx: Context = .{
        .location = "https://example.com/",
        .kind = "web",
        .worktree_path = "D:\\repo",
        .worktree_name = "repo",
    };
    const json = try serialize(alloc, "stem", "2026-08-09T00:49:12Z", "b", ctx, &.{});
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const source = parsed.value.object.get("source").?.object;
    try testing.expect(source.get("filePath") == null);
    try testing.expect(source.get("selection") == null);
    const worktree = parsed.value.object.get("worktree").?.object;
    try testing.expect(worktree.get("branch") == null);
    try testing.expect(worktree.get("commit") == null);
    // ...while the required halves are still there.
    try testing.expectEqualStrings("web", source.get("kind").?.string);
    try testing.expectEqualStrings("D:\\repo", worktree.get("path").?.string);
}

test "write: one complete folder appears, and nothing is left staged" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const written = try write(
        alloc,
        sampleContext(root),
        "the report body",
        &.{},
        sample_epoch,
        0xa3f9c2,
    );
    defer written.deinit(alloc);
    try testing.expectEqualStrings("20260809T004912Z-a3f9c2", written.stem);

    // The report is in the queue, complete...
    const body = try tmp.dir.readFileAlloc(
        alloc,
        "temp/feedback/new/20260809T004912Z-a3f9c2/report.json",
        64 * 1024,
    );
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("the report body", parsed.value.object.get("body").?.string);

    // ...and the staging folder it was built in is gone, because it WAS the
    // published folder. A staging folder that survived would mean the publish
    // was a copy, which is the non-atomic failure this design exists to avoid.
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access("temp/feedback/.staging/20260809T004912Z-a3f9c2", .{}),
    );
}

test "write: a second report in the same second gets its own folder" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const a = try write(alloc, sampleContext(root), "first", &.{}, sample_epoch, 0x000001);
    defer a.deinit(alloc);
    const b = try write(alloc, sampleContext(root), "second", &.{}, sample_epoch, 0x000002);
    defer b.deinit(alloc);
    try testing.expect(!std.mem.eql(u8, a.stem, b.stem));

    var queue = try tmp.dir.openDir("temp/feedback/new", .{ .iterate = true });
    defer queue.close();
    var n: usize = 0;
    var it = queue.iterate();
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 2), n);
}

test "write: an empty composer files nothing at all" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    try testing.expectError(
        WriteError.Empty,
        write(alloc, sampleContext(root), "   \n\t ", &.{}, sample_epoch, 0x000001),
    );
    // Not even the queue directory: a refused send must leave no trace for a
    // watcher to poll.
    try testing.expectError(error.FileNotFound, tmp.dir.access("temp/feedback", .{}));
}
