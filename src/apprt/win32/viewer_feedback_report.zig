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
//!     images/image-1.png
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

/// Worktree-relative path of the staging area a draft is assembled in, for the
/// composer's footer link (T645). Same `/` spelling and same reason.
pub const staging_relative_path = temp_dir_name ++ "/" ++ queue_dir_name ++ "/" ++ staging_dir_name;

/// How long a staging folder may sit untouched before a later draft sweeps it.
/// A day is long enough that a draft somebody walked away from over lunch is
/// still there, and short enough that abandoned drafts do not accumulate.
pub const stale_staging_secs: i64 = 24 * 60 * 60;

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
/// separator.
pub fn imageRelativePath(buf: []u8, number: u32) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/image-{d}.png", .{ images_dir_name, number }) catch null;
}

/// Bytes a `images/image-N.png` needs, at the widest `N` there is.
pub const image_path_max = images_dir_name.len + "/image-".len + 10 + ".png".len;

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

/// One image the report carries, on its way to `images/image-N.png` inside the
/// folder. The bytes are already PNG-encoded — this module never looks at
/// pixels, it only files what it is handed.
pub const Image = struct {
    /// The chip's stable number. It names the file too, so the markdown link
    /// in `body` and the entry in `images` cannot drift apart.
    number: u32,
    png: []const u8,
    pixel_width: ?u32 = null,
    pixel_height: ?u32 = null,
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
    /// Always present, empty when the composer held no images. A
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
    images: []const Image,
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

    // Each path is formatted into a buffer that outlives the stringify below,
    // which is why they are allocated together rather than on a per-image
    // stack slot.
    const path_buf = try alloc.alloc(u8, images.len * image_path_max);
    defer alloc.free(path_buf);
    var payload_images = try alloc.alloc(PayloadImage, images.len);
    defer alloc.free(payload_images);
    for (images, 0..) |img, i| {
        const slot = path_buf[i * image_path_max ..][0..image_path_max];
        payload_images[i] = .{
            .number = img.number,
            .path = imageRelativePath(slot, img.number) orelse unreachable,
            .pixelWidth = img.pixel_width,
            .pixelHeight = img.pixel_height,
            .bytes = img.png.len,
        };
    }

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
        .images = payload_images,
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

/// Absolute path of the folder a draft with this stem is assembled in. Caller
/// frees. The stem is stable for the draft's whole life, so the footer link,
/// the files the user drops into the folder, and the eventual atomic publish
/// all name one folder (T645, Mac's `stagingDirectory`).
pub fn stagingDir(alloc: Allocator, worktree_path: []const u8, stem: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{
        worktree_path, temp_dir_name, queue_dir_name, staging_dir_name, stem,
    });
}

/// Create or refresh a draft's staging folder IN PLACE: (over)write
/// `report.json` and the draft's own `images/`, leaving every other file in the
/// folder untouched. That last clause is the whole point — a log, a crash dump
/// or a recording the user dropped into the folder through the footer link has
/// to still be there when the folder is published.
///
/// Unlike `write` this tolerates an empty draft: a work-in-progress folder
/// legitimately has nothing typed in it yet. Returns the staging directory,
/// which the caller frees.
pub fn stage(
    alloc: Allocator,
    ctx: Context,
    body: []const u8,
    quotes: []const Quote,
    images: []const Image,
    stem: []const u8,
    epoch_secs: u64,
) ![]u8 {
    std.debug.assert(stemIsFilenameSafe(stem));

    const staging = try stagingDir(alloc, ctx.worktree_path, stem);
    errdefer alloc.free(staging);
    try std.fs.cwd().makePath(staging);

    // Drafts composed but never sent would otherwise leave their folders here
    // forever, and nothing else ever looks at this directory. Sweeping on each
    // write is what makes the staging area self-limiting without a timer.
    _ = pruneStaleStaging(alloc, ctx.worktree_path, stem, epoch_secs, stale_staging_secs);

    var created_buf: [20]u8 = undefined;
    const created = formatCreated(&created_buf, epoch_secs);
    const json = try serialize(alloc, stem, created, body, ctx, quotes, images);
    defer alloc.free(json);

    {
        const report_path = try std.fs.path.join(alloc, &.{ staging, report_file_name });
        defer alloc.free(report_path);
        var file = try std.fs.cwd().createFile(report_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
    }

    // Inside the staging folder, so the single rename in `write` publishes the
    // report and every one of its images at once. A watcher can never see a
    // report whose pictures have not arrived yet.
    if (images.len != 0) {
        const dir = try std.fs.path.join(alloc, &.{ staging, images_dir_name });
        defer alloc.free(dir);
        try std.fs.cwd().makePath(dir);
        for (images) |img| {
            // The bare file name, not the `/`-separated relative path: that
            // one is for the JSON, and a path separator belongs to
            // `path.join` on this platform.
            var name_buf: [image_path_max]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "image-{d}.png", .{img.number}) catch continue;
            const path = try std.fs.path.join(alloc, &.{ dir, name });
            defer alloc.free(path);
            var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(img.png);
        }
    }

    return staging;
}

/// Remove staging folders left by drafts that were never sent. Only folders
/// whose last modification is older than `older_than_secs` go, and never
/// `keep_stem` — so the draft being composed right now, in this pane or
/// another, is safe, and so is one another pane started minutes ago. Returns
/// how many were removed.
///
/// `now_secs` and `older_than_secs` are injected so a test can age a folder
/// without waiting a day. A directory that cannot be opened, statted or deleted
/// is skipped rather than failing the write that called this: a sweep is
/// housekeeping, and housekeeping must never cost the user their report.
pub fn pruneStaleStaging(
    alloc: Allocator,
    worktree_path: []const u8,
    keep_stem: []const u8,
    now_secs: u64,
    older_than_secs: i64,
) usize {
    const root = std.fs.path.join(alloc, &.{
        worktree_path, temp_dir_name, queue_dir_name, staging_dir_name,
    }) catch return 0;
    defer alloc.free(root);

    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var removed: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, keep_stem)) continue;

        var sub = dir.openDir(entry.name, .{}) catch continue;
        const st = sub.stat() catch {
            sub.close();
            continue;
        };
        sub.close();

        // `mtime` is nanoseconds since the epoch and can legitimately sit in
        // the FUTURE (a clock that stepped back, a file copied off another
        // box), which on a subtraction of unsigned seconds would wrap into
        // "unimaginably old" and delete a live draft.
        const mtime_secs: i128 = @divFloor(st.mtime, std.time.ns_per_s);
        const age: i128 = @as(i128, now_secs) - mtime_secs;
        if (age <= older_than_secs) continue;

        dir.deleteTree(entry.name) catch continue;
        removed += 1;
    }
    return removed;
}

/// Build the report folder under `.staging/` and publish it into `new/` with a
/// single rename. See the header for why the two directories are siblings.
///
/// `epoch_secs` and `suffix` are injected rather than read here so a test can
/// assert an exact folder name; `ViewerPane` passes the wall clock and a
/// random 24-bit suffix.
///
/// `draft_stem` is the composer's own draft folder (T645). When it is given,
/// THAT folder is refreshed and published, so anything the user dropped into it
/// while composing rides along into the report; when it is null a fresh stem is
/// minted from `epoch_secs`/`suffix`, which is what a caller with no composer
/// behind it — a test, a future scripted filer — wants.
pub fn write(
    alloc: Allocator,
    ctx: Context,
    body: []const u8,
    quotes: []const Quote,
    images: []const Image,
    epoch_secs: u64,
    suffix: u24,
    draft_stem: ?[]const u8,
) !Written {
    // A report whose whole content is a picture is a real report, so an empty
    // BODY is only empty when there are no images either.
    if (images.len == 0 and std.mem.trim(u8, body, " \t\r\n").len == 0) {
        return WriteError.Empty;
    }

    var stem_buf: [stem_len]u8 = undefined;
    const minted = makeStem(&stem_buf, epoch_secs, suffix);
    const stem = if (draft_stem) |s| s else minted;
    std.debug.assert(stemIsFilenameSafe(stem));

    const queue = try std.fs.path.join(alloc, &.{
        ctx.worktree_path, temp_dir_name, queue_dir_name, new_dir_name,
    });
    defer alloc.free(queue);
    const final = try std.fs.path.join(alloc, &.{ queue, stem });
    errdefer alloc.free(final);

    // The queue directory has to exist BEFORE the rename, or the publish fails
    // with the report already assembled.
    try std.fs.cwd().makePath(queue);

    const staging = try stage(alloc, ctx, body, quotes, images, stem, epoch_secs);
    defer alloc.free(staging);

    // Deliberately NOT cleaned up on a failed rename: the folder may hold files
    // the user dragged in, and a publish that failed is one the next press
    // retries into the same stem. An orphan is swept by `pruneStaleStaging` a
    // day later, which is the cost of never deleting somebody's attachment.
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
        &.{},
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

    // Present but empty — which is how a reader tells "no images" apart from
    // "written by a build that did not know about them".
    try testing.expectEqual(@as(usize, 0), root.get("images").?.array.items.len);
}

test "serialize: an image's entry names the file the folder will hold" {
    const alloc = testing.allocator;
    const images = [_]Image{
        .{ .number = 1, .png = "0123456789", .pixel_width = 1920, .pixel_height = 1080 },
        // A hole in the numbering: #2 was deleted from the composer, and the
        // report says so by not mentioning it.
        .{ .number = 3, .png = "abc" },
    };
    const json = try serialize(
        alloc,
        "stem",
        "2026-08-09T00:49:12Z",
        "see ![Image #1](images/image-1.png)",
        sampleContext("D:\\repo"),
        &.{},
        &images,
    );
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("images").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);

    const first = arr[0].object;
    try testing.expectEqual(@as(i64, 1), first.get("number").?.integer);
    // Folder-relative and `/`-separated, so it survives the move into
    // `in-progress/` and works as a markdown link.
    try testing.expectEqualStrings("images/image-1.png", first.get("path").?.string);
    try testing.expectEqual(@as(i64, 1920), first.get("pixelWidth").?.integer);
    try testing.expectEqual(@as(i64, 1080), first.get("pixelHeight").?.integer);
    try testing.expectEqual(@as(i64, 10), first.get("bytes").?.integer);

    const second = arr[1].object;
    try testing.expectEqual(@as(i64, 3), second.get("number").?.integer);
    try testing.expectEqualStrings("images/image-3.png", second.get("path").?.string);
    // Unknown dimensions are dropped rather than written as null, like every
    // other absent optional.
    try testing.expect(second.get("pixelWidth") == null);
    try testing.expectEqual(@as(i64, 3), second.get("bytes").?.integer);
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
    const json = try serialize(alloc, "stem", "2026-08-09T00:49:12Z", "b", ctx, &.{}, &.{});
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
        &.{},
        sample_epoch,
        0xa3f9c2,
        null,
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

    const a = try write(alloc, sampleContext(root), "first", &.{}, &.{}, sample_epoch, 0x000001, null);
    defer a.deinit(alloc);
    const b = try write(alloc, sampleContext(root), "second", &.{}, &.{}, sample_epoch, 0x000002, null);
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
        write(alloc, sampleContext(root), "   \n\t ", &.{}, &.{}, sample_epoch, 0x000001, null),
    );
    // Not even the queue directory: a refused send must leave no trace for a
    // watcher to poll.
    try testing.expectError(error.FileNotFound, tmp.dir.access("temp/feedback", .{}));
}

test "write: the images land in the folder, published by the same one rename" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const images = [_]Image{
        .{ .number = 1, .png = "first-png-bytes", .pixel_width = 8, .pixel_height = 4 },
        .{ .number = 3, .png = "third-png-bytes" },
    };
    const written = try write(
        alloc,
        sampleContext(root),
        "see ![Image #1](images/image-1.png) and ![Image #3](images/image-3.png)",
        &.{},
        &images,
        sample_epoch,
        0xa3f9c2,
        null,
    );
    defer written.deinit(alloc);

    // Both files are there under the numbers the body links to — the property
    // that makes the report movable as one unit.
    for ([_][]const u8{
        "temp/feedback/new/20260809T004912Z-a3f9c2/images/image-1.png",
        "temp/feedback/new/20260809T004912Z-a3f9c2/images/image-3.png",
    }, [_][]const u8{ "first-png-bytes", "third-png-bytes" }) |path, want| {
        const got = try tmp.dir.readFileAlloc(alloc, path, 4096);
        defer alloc.free(got);
        try testing.expectEqualStrings(want, got);
    }

    // ...and nothing survives in staging, so the publish was still one rename.
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access("temp/feedback/.staging/20260809T004912Z-a3f9c2", .{}),
    );
}

test "stage: the draft's folder appears, holding a report nothing has published" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    // A draft with nothing typed into it yet is a real state — the folder has
    // to exist before there is anything to say, or the footer link would open
    // nothing on a fresh composer.
    const staging = try stage(alloc, sampleContext(root), "", &.{}, &.{}, "20260809T004912Z-a3f9c2", sample_epoch);
    defer alloc.free(staging);

    const body = try tmp.dir.readFileAlloc(
        alloc,
        "temp/feedback/.staging/20260809T004912Z-a3f9c2/report.json",
        64 * 1024,
    );
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("20260809T004912Z-a3f9c2", parsed.value.object.get("id").?.string);

    // ...and the queue is untouched: staging a draft is not filing a report,
    // which is the whole distinction a watcher polling `new/` depends on.
    try testing.expectError(error.FileNotFound, tmp.dir.access("temp/feedback/new", .{}));
}

test "stage: a file the user dropped in survives every refresh, and rides along to the queue" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const stem = "20260809T004912Z-a3f9c2";
    const first = try stage(alloc, sampleContext(root), "half a thought", &.{}, &.{}, stem, sample_epoch);
    alloc.free(first);

    // What the footer link is FOR: the user opens the folder and drops a log
    // into it.
    try tmp.dir.writeFile(.{
        .sub_path = "temp/feedback/.staging/20260809T004912Z-a3f9c2/crash.log",
        .data = "the log they dragged in",
    });

    // They keep typing, so the draft is staged again over the same folder.
    const second = try stage(alloc, sampleContext(root), "the whole thought", &.{}, &.{}, stem, sample_epoch + 30);
    alloc.free(second);
    try tmp.dir.access("temp/feedback/.staging/20260809T004912Z-a3f9c2/crash.log", .{});

    // And then they send. The publish is still ONE rename, and it takes the
    // dropped file with it — the property this whole draft folder exists for.
    const written = try write(
        alloc,
        sampleContext(root),
        "the whole thought",
        &.{},
        &.{},
        sample_epoch + 60,
        0x000009,
        stem,
    );
    defer written.deinit(alloc);
    try testing.expectEqualStrings(stem, written.stem);

    const dropped = try tmp.dir.readFileAlloc(
        alloc,
        "temp/feedback/new/20260809T004912Z-a3f9c2/crash.log",
        4096,
    );
    defer alloc.free(dropped);
    try testing.expectEqualStrings("the log they dragged in", dropped);

    // The published report is the LAST staged one, not the first: the folder
    // is refreshed in place, so a stale `report.json` cannot be what ships.
    const body = try tmp.dir.readFileAlloc(
        alloc,
        "temp/feedback/new/20260809T004912Z-a3f9c2/report.json",
        64 * 1024,
    );
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("the whole thought", parsed.value.object.get("body").?.string);

    // ...and the draft folder is gone, because it BECAME the published folder.
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access("temp/feedback/.staging/20260809T004912Z-a3f9c2", .{}),
    );
}

test "pruneStaleStaging: an abandoned draft is swept; the live one never is" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    // Three folders, all created NOW: one being composed into, one somebody
    // else started a minute ago, one abandoned yesterday. The clock is what
    // separates them, which is why it is injected.
    for ([_][]const u8{ "mine", "another-pane", "abandoned" }) |name| {
        const dir = try std.fs.path.join(alloc, &.{ root, "temp", "feedback", ".staging", name });
        defer alloc.free(dir);
        try std.fs.cwd().makePath(dir);
    }
    const now: u64 = @intCast(@max(std.time.timestamp(), 0));

    // Nothing is a day old yet, so a sweep right now removes nothing at all —
    // the case that matters most, because getting it wrong deletes a report
    // somebody is in the middle of writing.
    try testing.expectEqual(
        @as(usize, 0),
        pruneStaleStaging(alloc, root, "mine", now, stale_staging_secs),
    );
    try tmp.dir.access("temp/feedback/.staging/another-pane", .{});

    // A day later they are all stale by the clock — and `mine` is still not
    // swept, because the draft being composed is exempt however old it is.
    try testing.expectEqual(
        @as(usize, 2),
        pruneStaleStaging(alloc, root, "mine", now + 25 * 60 * 60, stale_staging_secs),
    );
    try tmp.dir.access("temp/feedback/.staging/mine", .{});
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access("temp/feedback/.staging/abandoned", .{}),
    );

    // A staging area that is not there at all is not an error: the first draft
    // on a fresh worktree sweeps before anything has ever been staged.
    var empty = testing.tmpDir(.{});
    defer empty.cleanup();
    const empty_root = try empty.dir.realpathAlloc(alloc, ".");
    defer alloc.free(empty_root);
    try testing.expectEqual(
        @as(usize, 0),
        pruneStaleStaging(alloc, empty_root, "mine", now, stale_staging_secs),
    );
}

test "stage: staging a draft sweeps the drafts nobody came back to" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const old = try std.fs.path.join(alloc, &.{ root, "temp", "feedback", ".staging", "left-behind" });
    defer alloc.free(old);
    try std.fs.cwd().makePath(old);

    // The sweep rides on the draft's own write, so it needs no timer and no
    // startup pass — and the clock it judges by is the one the caller staged
    // with, here a day after the folder above was made.
    const now: u64 = @intCast(@max(std.time.timestamp(), 0));
    const staging = try stage(
        alloc,
        sampleContext(root),
        "a new draft",
        &.{},
        &.{},
        "20260809T004912Z-a3f9c2",
        now + 25 * 60 * 60,
    );
    defer alloc.free(staging);

    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access("temp/feedback/.staging/left-behind", .{}),
    );
    try tmp.dir.access("temp/feedback/.staging/20260809T004912Z-a3f9c2/report.json", .{});
}

test "write: a draft stem publishes under the draft's own name, not a fresh one" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    // The stem the composer minted when it opened — deliberately NOT what
    // `epoch_secs`/`suffix` would produce, so a publish that quietly minted its
    // own name would show up here rather than in a user's missing attachment.
    const written = try write(
        alloc,
        sampleContext(root),
        "filed from a draft",
        &.{},
        &.{},
        sample_epoch,
        0xa3f9c2,
        "20260808T120000Z-000abc",
    );
    defer written.deinit(alloc);
    try testing.expectEqualStrings("20260808T120000Z-000abc", written.stem);
    try tmp.dir.access("temp/feedback/new/20260808T120000Z-000abc/report.json", .{});
}

test "write: a report that is only a picture is not an empty report" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    // Nothing typed but an image pasted: the body renders to the link alone,
    // and "here, look at this" is a complete piece of feedback.
    const images = [_]Image{.{ .number = 1, .png = "bytes" }};
    const written = try write(
        alloc,
        sampleContext(root),
        "",
        &.{},
        &images,
        sample_epoch,
        0x000001,
        null,
    );
    defer written.deinit(alloc);
    try tmp.dir.access("temp/feedback/new/20260809T004912Z-000001/images/image-1.png", .{});
}
