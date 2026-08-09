//! The images a feedback report carries: what the composer stores, how a
//! picture becomes an `[Image #N]` chip in the text, and which chips are still
//! in the report when it is sent (T637, the win32 half of Mac's
//! `NSTextAttachment` chips).
//!
//! Pure — bytes in, bytes out, no OS surface — so it is unit tested in the
//! `-Dapp-runtime=none` lane like its siblings. `ViewerFeedbackBar` drives the
//! RichEdit from what this decides, `ViewerPane` owns the `Store`, and
//! `viewer_feedback_report.zig` writes the files.
//!
//! ## The number is the identity, and it is in the TEXT
//!
//! Mac makes a chip one atomic `NSTextAttachment` — a single `U+FFFC` — and
//! hangs the image off it, so deleting the character deletes the picture from
//! the report. RichEdit has no such field (the same hole `viewer_feedback_doc`
//! works around for quotes), so a chip here is literally the characters
//! `[Image #3]` and the NUMBER is what ties it to a stored image.
//!
//! That makes the two rules Mac states fall out rather than have to be
//! maintained:
//!
//! - **Numbers are stable, never positional.** `next_number` only ever counts
//!   up, so deleting `[Image #2]` leaves 1 and 3 — the sequence has a hole in
//!   it, which is the point. A number always names the same picture.
//! - **What is in the report is DERIVED from the text.** `live` scans the
//!   composer's text for chips and answers with the entries they name, so a
//!   chip the user deleted takes its image out of the report with it and
//!   nothing has to be told about the deletion.
//!
//! A chip the store does not know (`[Image #9]` typed by hand) is left alone —
//! plain text, no link, no entry. And an entry is live at most ONCE: copying a
//! chip does not attach the picture twice, because there is only one picture.
//!
//! ## Atomicity without an attachment character
//!
//! `chipAt` is what makes a chip behave like one unit: Backspace next to
//! `[Image #3]` selects the whole chip rather than eating the `]` and leaving
//! `[Image #3` behind — which would be a chip that no longer parses, i.e. an
//! image silently dropped from the report by a single keystroke.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The chip's fixed halves. Spelled the way Mac spells its attachment label,
/// because the two show up side by side in one shared feedback queue.
pub const chip_prefix = "[Image #";
pub const chip_suffix = "]";

/// `[Image #4294967295]` — the widest a chip can be.
pub const chip_max_len = chip_prefix.len + 10 + chip_suffix.len;

/// A single image is capped so one absurd paste cannot take the pane's memory
/// with it; the total is capped so a hundred reasonable ones cannot either. Both
/// are refusals with a message, never a truncation — half an image is not a
/// smaller image.
pub const max_image_bytes: usize = 32 * 1024 * 1024;
pub const max_total_bytes: usize = 64 * 1024 * 1024;

pub const AddError = error{
    /// Not a PNG. Everything reaching the store has already been encoded, so
    /// this is a bug guard rather than a user-facing state.
    NotPng,
    /// This image alone is over `max_image_bytes`.
    TooLarge,
    /// It would put the composer over `max_total_bytes`.
    Full,
};

/// One image held by an open composer. The PNG bytes live here until the report
/// is written — in memory rather than in a temp file, because a composer is
/// short-lived and a temp file is a cleanup path that can be got wrong (a pane
/// closed without sending would leak one every time).
pub const Entry = struct {
    /// Stable for the composer's life and never reused. This is the `N` in the
    /// chip, in `images/image-N.png`, and in the report's `images` array.
    number: u32,
    /// Owned; freed by `Store.deinit`.
    png: []const u8,
    /// From the PNG's own IHDR, so it describes the file that will be written
    /// rather than whatever produced it.
    pixel_width: ?u32 = null,
    pixel_height: ?u32 = null,
};

/// Where a live chip sits in the composer text. `index` is into the store's
/// `entries`.
pub const Span = struct {
    start: usize,
    end: usize,
    index: usize,
};

/// A chip found in text, whether or not the store knows its number.
pub const Chip = struct {
    start: usize,
    end: usize,
    number: u32,
};

pub const Store = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    next_number: u32 = 1,
    total_bytes: usize = 0,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        for (self.entries.items) |e| alloc.free(e.png);
        self.entries.deinit(alloc);
        self.* = .{};
    }

    /// Copy one encoded PNG into the store and return the number its chip will
    /// carry. Dimensions come from the bytes themselves, so a caller cannot
    /// report a size the file does not have.
    pub fn add(self: *Store, alloc: Allocator, png: []const u8) !u32 {
        const size = pngSize(png) orelse return AddError.NotPng;
        if (png.len > max_image_bytes) return AddError.TooLarge;
        if (self.total_bytes + png.len > max_total_bytes) return AddError.Full;

        const owned = try alloc.dupe(u8, png);
        errdefer alloc.free(owned);
        try self.entries.append(alloc, .{
            .number = self.next_number,
            .png = owned,
            .pixel_width = size.width,
            .pixel_height = size.height,
        });
        self.next_number += 1;
        self.total_bytes += png.len;
        return self.entries.items[self.entries.items.len - 1].number;
    }

    /// The entry carrying `number`, or null.
    pub fn find(self: *const Store, number: u32) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.number == number) return i;
        }
        return null;
    }

    /// The images still in `text`, in document order — what the report's
    /// `images` array and the body's links are built from.
    ///
    /// An entry appears at most once even when its chip does: there is one
    /// picture, so a duplicated chip is a second REFERENCE to it, and the
    /// second reference simply stays plain text.
    pub fn live(self: *const Store, alloc: Allocator, text: []const u8) ![]Span {
        var out: std.ArrayListUnmanaged(Span) = .empty;
        errdefer out.deinit(alloc);

        var seen: std.ArrayListUnmanaged(u32) = .empty;
        defer seen.deinit(alloc);

        var at: usize = 0;
        while (nextChip(text, at)) |c| {
            at = c.end;
            const idx = self.find(c.number) orelse continue;
            if (std.mem.indexOfScalar(u32, seen.items, c.number) != null) continue;
            try seen.append(alloc, c.number);
            try out.append(alloc, .{ .start = c.start, .end = c.end, .index = idx });
        }
        return out.toOwnedSlice(alloc);
    }
};

// -----------------------------------------------------------------------------
// Chips
// -----------------------------------------------------------------------------

/// `[Image #3]`.
pub fn chipText(buf: *[chip_max_len]u8, number: u32) []const u8 {
    return std.fmt.bufPrint(buf, chip_prefix ++ "{d}" ++ chip_suffix, .{number}) catch unreachable;
}

/// The first chip at or after `from`, or null.
///
/// Deliberately strict: `[Image #]`, `[Image #1a]` and `[image #1]` are not
/// chips. A loose parser would turn prose that happens to mention an image into
/// a link to a file that is not in the report.
pub fn nextChip(text: []const u8, from: usize) ?Chip {
    var at = @min(from, text.len);
    while (std.mem.indexOfPos(u8, text, at, chip_prefix)) |start| {
        at = start + chip_prefix.len;
        var end = at;
        while (end < text.len and text[end] >= '0' and text[end] <= '9') end += 1;
        // A run of digits, then the closing bracket, and nothing else.
        if (end == at or end >= text.len or text[end] != chip_suffix[0]) continue;
        const number = std.fmt.parseInt(u32, text[at..end], 10) catch continue;
        return .{ .start = start, .end = end + chip_suffix.len, .number = number };
    }
    return null;
}

/// The chip that `at` falls INSIDE — strictly between its ends, so a caret
/// parked against a chip's outer edge is next to it, not in it.
pub fn chipAt(text: []const u8, at: usize) ?Chip {
    var from: usize = 0;
    while (nextChip(text, from)) |c| {
        if (c.start >= at) return null; // chips are found in order
        if (at < c.end) return c;
        from = c.end;
    }
    return null;
}

/// What a Backspace at `at` should swallow whole: the chip ending there, or —
/// if the caret was walked into the middle of one with the arrow keys — the
/// chip it is inside. Either way the answer is the WHOLE chip, which is the
/// property that makes it behave like Mac's single attachment character.
pub fn chipEndingAt(text: []const u8, at: usize) ?Chip {
    if (at == 0) return null;
    return chipAt(text, at - 1);
}

/// The chip starting exactly at `at` — what Delete should swallow whole.
pub fn chipStartingAt(text: []const u8, at: usize) ?Chip {
    var from: usize = 0;
    while (nextChip(text, from)) |c| {
        if (c.start == at) return c;
        if (c.start > at) return null;
        from = c.end;
    }
    return null;
}

/// Where a new chip goes and what to insert there.
pub const Insertion = struct {
    at: usize,
    /// Owned by the caller; freed with `deinit`.
    insert: []const u8,
    caret_after: usize,

    pub fn deinit(self: Insertion, alloc: Allocator) void {
        alloc.free(self.insert);
    }
};

/// A chip at the caret, with the one space on each side that keeps it from
/// fusing to the words around it. The spaces are added only where there is not
/// one already, so pasting three images in a row does not accumulate gaps.
pub fn insertion(alloc: Allocator, text: []const u8, caret: usize, number: u32) !Insertion {
    const at = @min(caret, text.len);

    var buf: [chip_max_len]u8 = undefined;
    const chip = chipText(&buf, number);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    if (at > 0 and !isBreak(text[at - 1])) try out.append(alloc, ' ');
    try out.appendSlice(alloc, chip);
    if (at >= text.len or !isBreak(text[at])) try out.append(alloc, ' ');

    const insert = try out.toOwnedSlice(alloc);
    return .{ .at = at, .insert = insert, .caret_after = at + insert.len };
}

fn isBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// -----------------------------------------------------------------------------
// Body
// -----------------------------------------------------------------------------

/// Rewrite every LIVE chip in `body` as a markdown image reference —
/// `![Image #3](images/image-3.png)` — leaving unknown chips as plain text.
///
/// Run over the rendered body rather than the composer's raw text on purpose:
/// `renderBody` has already added `> ` to quoted lines and trimmed the ends, so
/// the offsets `live` computed no longer hold there. Chips are found again
/// here, which needs no offsets at all.
///
/// `numbers` is the live set, in any order. Caller frees the result.
pub fn renderLinks(alloc: Allocator, body: []const u8, numbers: []const u32) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var at: usize = 0;
    while (nextChip(body, at)) |c| {
        try out.appendSlice(alloc, body[at..c.start]);
        if (std.mem.indexOfScalar(u32, numbers, c.number) != null) {
            try out.append(alloc, '!');
            try out.appendSlice(alloc, body[c.start..c.end]);
            try out.print(alloc, "(images/image-{d}.png)", .{c.number});
        } else {
            try out.appendSlice(alloc, body[c.start..c.end]);
        }
        at = c.end;
    }
    try out.appendSlice(alloc, body[at..]);
    return out.toOwnedSlice(alloc);
}

// -----------------------------------------------------------------------------
// PNG
// -----------------------------------------------------------------------------

pub const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

pub const Size = struct { width: u32, height: u32 };

/// The pixel size out of a PNG's own IHDR, or null when the bytes are not a
/// PNG. Read from the file rather than carried alongside it, so the numbers in
/// the report always describe the file that was written.
pub fn pngSize(bytes: []const u8) ?Size {
    // 8 signature + 4 length + 4 "IHDR" + 4 width + 4 height.
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], &signature)) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    // A zero dimension is not a picture; the PNG spec forbids it outright.
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

pub fn isPng(bytes: []const u8) bool {
    return pngSize(bytes) != null;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

/// A byte-valid PNG header of the given size, followed by junk. Enough for
/// everything here, which never decodes pixels.
fn fakePng(alloc: Allocator, w: u32, h: u32, pad: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &signature);
    try out.appendSlice(alloc, &[_]u8{ 0, 0, 0, 13 });
    try out.appendSlice(alloc, "IHDR");
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, w, .big);
    try out.appendSlice(alloc, &be);
    std.mem.writeInt(u32, &be, h, .big);
    try out.appendSlice(alloc, &be);
    try out.appendNTimes(alloc, 0, pad);
    return out.toOwnedSlice(alloc);
}

test "pngSize reads the IHDR, and refuses everything that is not a PNG" {
    const alloc = testing.allocator;
    const png = try fakePng(alloc, 1920, 1080, 0);
    defer alloc.free(png);
    const size = pngSize(png).?;
    try testing.expectEqual(@as(u32, 1920), size.width);
    try testing.expectEqual(@as(u32, 1080), size.height);
    try testing.expect(isPng(png));

    try testing.expect(pngSize("") == null);
    try testing.expect(pngSize("not a png at all, but long enough") == null);
    // A JPEG, which is the realistic near miss on a clipboard.
    try testing.expect(pngSize(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 } ** 8) == null);
    // The right signature with the wrong chunk is still not readable.
    var wrong = try fakePng(alloc, 4, 4, 0);
    defer alloc.free(wrong);
    @memcpy(wrong[12..16], "IDAT");
    try testing.expect(pngSize(wrong) == null);
    // A zero dimension is not a picture.
    const flat = try fakePng(alloc, 0, 10, 0);
    defer alloc.free(flat);
    try testing.expect(pngSize(flat) == null);
}

test "chip numbers are stable across deletions, never positional" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    const png = try fakePng(alloc, 10, 20, 4);
    defer alloc.free(png);
    try testing.expectEqual(@as(u32, 1), try store.add(alloc, png));
    try testing.expectEqual(@as(u32, 2), try store.add(alloc, png));
    try testing.expectEqual(@as(u32, 3), try store.add(alloc, png));

    // All three chips present: 1, 2, 3 in document order.
    {
        const spans = try store.live(alloc, "a [Image #1] b [Image #2] c [Image #3] d");
        defer alloc.free(spans);
        try testing.expectEqual(@as(usize, 3), spans.len);
        for (spans, 0..) |s, i| {
            try testing.expectEqual(@as(u32, @intCast(i + 1)), store.entries.items[s.index].number);
        }
    }

    // The user deletes the middle chip. The sequence keeps its HOLE — a
    // renumbering here is exactly what would make "Image #3" mean two
    // different pictures at two moments.
    {
        const spans = try store.live(alloc, "a [Image #1] b  c [Image #3] d");
        defer alloc.free(spans);
        try testing.expectEqual(@as(usize, 2), spans.len);
        try testing.expectEqual(@as(u32, 1), store.entries.items[spans[0].index].number);
        try testing.expectEqual(@as(u32, 3), store.entries.items[spans[1].index].number);
    }

    // And the next paste is 4, not the freed 2.
    try testing.expectEqual(@as(u32, 4), try store.add(alloc, png));
}

test "live: unknown chips are plain text and a duplicate attaches once" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const png = try fakePng(alloc, 2, 2, 0);
    defer alloc.free(png);
    _ = try store.add(alloc, png); // #1

    // A number nobody stored — typed by hand, or pasted in from elsewhere.
    const spans = try store.live(alloc, "[Image #9] and [Image #1] and [Image #1] again");
    defer alloc.free(spans);
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqual(@as(u32, 1), store.entries.items[spans[0].index].number);
    // ...and it is the FIRST occurrence that carries the picture.
    try testing.expectEqual(@as(usize, 15), spans[0].start);
}

test "live: chips out of insertion order still report in document order" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const png = try fakePng(alloc, 2, 2, 0);
    defer alloc.free(png);
    _ = try store.add(alloc, png);
    _ = try store.add(alloc, png);

    // The user moved #2 above #1. The report should read the way the text does.
    const spans = try store.live(alloc, "[Image #2]\n[Image #1]");
    defer alloc.free(spans);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqual(@as(u32, 2), store.entries.items[spans[0].index].number);
    try testing.expectEqual(@as(u32, 1), store.entries.items[spans[1].index].number);
}

test "an empty composer has no images, and neither does one with no chips" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const png = try fakePng(alloc, 2, 2, 0);
    defer alloc.free(png);
    _ = try store.add(alloc, png);

    for ([_][]const u8{ "", "just words", "[Image #]", "[Image #1a]", "[image #1]" }) |text| {
        const spans = try store.live(alloc, text);
        defer alloc.free(spans);
        if (spans.len != 0) {
            std.debug.print("expected no chips in '{s}'\n", .{text});
            return error.UnexpectedChip;
        }
    }
}

test "the store refuses what it cannot hold, and holds nothing on refusal" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    try testing.expectError(AddError.NotPng, store.add(alloc, "hello"));
    try testing.expectEqual(@as(usize, 0), store.entries.items.len);
    // The number is not burned by a refusal — a rejected paste must not leave
    // a hole in the sequence that no picture ever fills.
    try testing.expectEqual(@as(u32, 1), store.next_number);

    const big = try fakePng(alloc, 4, 4, max_image_bytes);
    defer alloc.free(big);
    try testing.expectError(AddError.TooLarge, store.add(alloc, big));
    try testing.expectEqual(@as(usize, 0), store.entries.items.len);
}

test "chipAt: a caret inside a chip finds the whole thing, outside finds none" {
    const text = "ab [Image #12] cd";
    const start: usize = 3;
    const end: usize = 14;
    try testing.expectEqualStrings("[Image #12]", text[start..end]);

    // Strictly inside — every interior position, including just past the `[`.
    var i = start + 1;
    while (i < end) : (i += 1) {
        const c = chipAt(text, i).?;
        try testing.expectEqual(start, c.start);
        try testing.expectEqual(end, c.end);
        try testing.expectEqual(@as(u32, 12), c.number);
    }
    // The ends themselves are NEXT to the chip, not in it.
    try testing.expect(chipAt(text, start) == null);
    try testing.expect(chipAt(text, end) == null);
    try testing.expect(chipAt(text, 0) == null);
    try testing.expect(chipAt(text, text.len) == null);
}

test "chipEndingAt/chipStartingAt: Backspace and Delete swallow a chip whole" {
    const text = "x [Image #1][Image #2] y";
    // Backspace with the caret against the `]` of #1 takes all of #1.
    const before = chipEndingAt(text, 12).?;
    try testing.expectEqual(@as(u32, 1), before.number);
    try testing.expectEqual(@as(usize, 2), before.start);
    try testing.expectEqual(@as(usize, 12), before.end);

    // Delete with the caret at the same spot takes all of #2, which starts
    // there — the two chips are adjacent, which is the case that would
    // otherwise leave `[Image #2` behind.
    const after = chipStartingAt(text, 12).?;
    try testing.expectEqual(@as(u32, 2), after.number);
    try testing.expectEqual(@as(usize, 22), after.end);

    // Nothing at the document ends, and nothing in the middle of plain text.
    try testing.expect(chipEndingAt(text, 0) == null);
    try testing.expect(chipStartingAt(text, text.len) == null);
    try testing.expect(chipEndingAt(text, 1) == null);
    try testing.expect(chipStartingAt(text, 1) == null);
}

test "insertion: a chip lands spaced from its neighbours, without stacking gaps" {
    const alloc = testing.allocator;

    // Into an empty composer: nothing before, so no leading space.
    {
        const ins = try insertion(alloc, "", 0, 1);
        defer ins.deinit(alloc);
        try testing.expectEqualStrings("[Image #1] ", ins.insert);
        try testing.expectEqual(@as(usize, 0), ins.at);
        try testing.expectEqual(ins.insert.len, ins.caret_after);
    }
    // After a word: separated on both sides.
    {
        const ins = try insertion(alloc, "look", 4, 2);
        defer ins.deinit(alloc);
        try testing.expectEqualStrings(" [Image #2] ", ins.insert);
    }
    // Straight after a previous chip's trailing space: no second space.
    {
        const text = "[Image #1] ";
        const ins = try insertion(alloc, text, text.len, 2);
        defer ins.deinit(alloc);
        try testing.expectEqualStrings("[Image #2] ", ins.insert);
    }
    // Before existing text: the trailing space is not doubled either.
    {
        const ins = try insertion(alloc, "a rest", 2, 3);
        defer ins.deinit(alloc);
        try testing.expectEqualStrings("[Image #3] ", ins.insert);
        try testing.expectEqual(@as(usize, 2), ins.at);
    }
    // A caret past the end is clamped rather than trusted.
    {
        const ins = try insertion(alloc, "ab", 99, 4);
        defer ins.deinit(alloc);
        try testing.expectEqual(@as(usize, 2), ins.at);
    }
}

test "renderLinks: live chips become image references, unknown ones do not" {
    const alloc = testing.allocator;
    const body = "before [Image #1] middle [Image #7] after";
    const out = try renderLinks(alloc, body, &.{1});
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "before ![Image #1](images/image-1.png) middle [Image #7] after",
        out,
    );
}

test "renderLinks: two images, and a body with none is returned unchanged" {
    const alloc = testing.allocator;
    {
        const out = try renderLinks(alloc, "[Image #2]\n[Image #3]", &.{ 3, 2 });
        defer alloc.free(out);
        try testing.expectEqualStrings(
            "![Image #2](images/image-2.png)\n![Image #3](images/image-3.png)",
            out,
        );
    }
    {
        const out = try renderLinks(alloc, "> a quote\n\nmy words", &.{1});
        defer alloc.free(out);
        try testing.expectEqualStrings("> a quote\n\nmy words", out);
    }
}

test "renderLinks: a chip inside a quoted line is still linked" {
    // `renderBody` has already put `> ` in front, which is exactly why the
    // links are resolved by re-finding the chips rather than by offset.
    const alloc = testing.allocator;
    const out = try renderLinks(alloc, "> see [Image #1]\n\nfix it", &.{1});
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "> see ![Image #1](images/image-1.png)\n\nfix it",
        out,
    );
}
