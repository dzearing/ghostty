//! The feedback composer's page: the document it loads, the messages that
//! cross the boundary in both directions, and nothing that needs a browser
//! (T934).
//!
//! Everything here is pure, so the whole protocol is unit-testable in the
//! `none` lane without a WebView2 anywhere near it — which matters more for
//! this control than for most, because the browser half only exists on a box
//! with a runtime installed and the acceptance script cannot read a rendered
//! caret.
//!
//! ## Why a page at all
//!
//! D43 was answered with "a second WebView2 controller hosting a
//! contenteditable" rather than the recommended RichEdit, and T830 recorded
//! the design: the pill's TEXT RECT becomes web content while the pill, its
//! accent, the carousel and the send row stay native. This module is the
//! contract between those halves.
//!
//! ## The one rule about numbers
//!
//! No size, no color and no font is written in the stylesheet. They arrive as
//! CSS custom properties in a `vars` message, computed from
//! `viewer_feedback_layout.zig` and `type_ramp.zig` — the modules that already
//! own the design system and already assert at 1.0/1.25/1.5/2.0. That is D43's
//! own mitigation ("one shared source for the design numbers"), and the reason
//! `Vars` carries CSS pixels rather than physical ones: the controller
//! rasterizes at the pane's scale, so a CSS pixel IS a DIP and the conversion
//! happens once, here, instead of in a stylesheet nobody can test.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The stylesheet and the script, embedded rather than served: the composer's
/// page is loaded with `NavigateToString` into an opaque origin, so there is no
/// scheme for it to fetch a sibling file over.
pub const css = @embedFile("../../viewer/composer.css");
pub const js = @embedFile("../../viewer/composer.js");

/// The editable box's element id. Shared with both assets, so it is stated once
/// and asserted in the tests below rather than typed three times.
pub const box_id = "c";

/// The design-system numbers the page is dressed with, in CSS pixels and CSS
/// color syntax. Built by the host from a `viewer_feedback_layout.Layout` and
/// the bar's own theme; see `Vars.json`.
pub const Vars = struct {
    /// `type_ramp.face`.
    face: []const u8,
    /// The body size, in CSS pixels.
    font_px: f32,
    /// One line box, in CSS pixels — the number the wrapped line count is
    /// measured against, so it has to be the SAME line box the layout module
    /// sized the text rect with.
    line_px: f32,
    /// Foreground, background (the pill's fill), placeholder and selection, as
    /// `#rrggbb`.
    fg: []const u8,
    bg: []const u8,
    placeholder: []const u8,
    selection: []const u8,
    /// The cue an empty composer shows.
    placeholder_text: []const u8,

    /// The `vars` message, ready for `PostWebMessageAsJson`. Caller owns it.
    pub fn json(self: Vars, alloc: Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(alloc, .{
            .t = "vars",
            .face = self.face,
            .fontPx = self.font_px,
            .linePx = self.line_px,
            .fg = self.fg,
            .bg = self.bg,
            .placeholder = self.placeholder,
            .sel = self.selection,
            .text = self.placeholder_text,
        }, .{});
    }
};

/// The `seed` message: replace the document's whole content and put the caret
/// at `caret` UTF-16 code units in (negative means "at the end"). Caller owns
/// the result.
///
/// Every native-side edit goes through this — opening the composer, inserting
/// a quote, emptying it behind a filed report. There is no incremental write
/// path on purpose: the pane's buffer is the truth, so "make the page equal the
/// buffer" is the only operation that cannot drift from it.
///
/// `gen` is what makes that safe across a boundary with latency. The page
/// echoes it in every snapshot, so a snapshot that was already in flight when a
/// seed went down is recognisable as older than the buffer and dropped — which
/// is the difference between a native write and a keystroke racing to the same
/// millisecond, and a report that silently reverts to what it said before.
pub fn seedJson(alloc: Allocator, text: []const u8, caret: i64, gen: u32) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .t = "seed",
        .text = text,
        .caret = caret,
        .gen = gen,
    }, .{});
}

/// The `focus` message: put the caret in the box.
pub const focus_json = "{\"t\":\"focus\"}";

/// What the page pushes up. Anything else — malformed JSON, a non-object, an
/// unknown `t` — parses to null and is dropped, the same rule
/// `viewer_bridge.parse` follows: this is a message channel, and a channel that
/// crashes on a payload it did not expect is a channel that crashes.
pub const Message = union(enum) {
    /// The document exists. The host answers with `vars` + `seed`, which is
    /// what makes a page that reloaded itself heal rather than blank the
    /// report.
    ready,
    /// The snapshot, after every edit.
    state: State,
    /// The box gained (`true`) or lost the caret.
    focus: bool,
};

/// One snapshot of the live document. `text` points into the parse arena.
pub const State = struct {
    text: []const u8,
    /// WRAPPED lines, unclamped — the layout module does the clamping, and a
    /// number that arrived already clamped could not tell "exactly six" from
    /// "sixty".
    lines: u32,
    /// The caret in UTF-16 code units into `text`, or null when the page could
    /// not resolve one (no selection, or a selection outside the box).
    caret: ?u32,
    /// The `gen` of the last seed the page had applied when it measured this.
    /// A snapshot whose generation is not the current one describes a document
    /// that has since been replaced. Zero for a page that has not been seeded.
    gen: u32,
};

pub const Parsed = struct {
    arena: *std.heap.ArenaAllocator,
    message: Message,

    pub fn deinit(self: Parsed) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// Parse one `get_WebMessageAsJson` payload from the composer's page.
pub fn parse(alloc: Allocator, json_text: []const u8) ?Parsed {
    const arena = alloc.create(std.heap.ArenaAllocator) catch return null;
    arena.* = .init(alloc);
    const message = parseMessage(arena.allocator(), json_text) orelse {
        arena.deinit();
        alloc.destroy(arena);
        return null;
    };
    return .{ .arena = arena, .message = message };
}

fn parseMessage(aa: Allocator, json_text: []const u8) ?Message {
    // `alloc_always`: the JSON arrives as a COM-heap string the caller frees
    // the moment this returns, so nothing may point back into it.
    const doc = std.json.parseFromSliceLeaky(std.json.Value, aa, json_text, .{
        .allocate = .alloc_always,
    }) catch return null;

    const obj = switch (doc) {
        .object => |o| o,
        else => return null,
    };
    const kind = switch (obj.get("t") orelse return null) {
        .string => |s| s,
        else => return null,
    };

    if (std.mem.eql(u8, kind, "ready")) return .ready;
    if (std.mem.eql(u8, kind, "focus")) {
        return .{ .focus = switch (obj.get("on") orelse return null) {
            .bool => |b| b,
            else => return null,
        } };
    }
    if (std.mem.eql(u8, kind, "state")) {
        const text = switch (obj.get("text") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        const lines = intField(obj, "lines") orelse return null;
        const caret = intField(obj, "caret");
        const gen = intField(obj, "gen") orelse 0;
        return .{ .state = .{
            .text = text,
            .gen = if (gen > 0) @intCast(@min(gen, std.math.maxInt(u32))) else 0,
            .lines = if (lines > 0) @intCast(@min(lines, std.math.maxInt(u32))) else 1,
            // The page sends -1 for "no caret I can name", which is not the
            // same as 0 — treating it as 0 would jump a carousel selection to
            // the front of the report every time focus left the box.
            .caret = if (caret) |c| (if (c >= 0) @as(u32, @intCast(@min(c, std.math.maxInt(u32)))) else null) else null,
        } };
    }
    return null;
}

fn intField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (obj.get(name) orelse return null) {
        .integer => |i| i,
        // A measured line count arrives as a float on a fractional scale.
        .float => |f| @intFromFloat(@round(f)),
        else => null,
    };
}

/// The whole document, as one `NavigateToString` string. Caller owns it.
///
/// Composed rather than embedded whole so the two assets stay separately
/// readable (and separately linted) files, and so the skeleton's few
/// attributes — `plaintext-only`, the ARIA role, the box id — live next to the
/// prose explaining them.
pub fn documentAlloc(alloc: Allocator) ![]u8 {
    return std.mem.concat(alloc, u8, &.{
        // `plaintext-only` is the whole reason this is a viable text control:
        // it gives the engine's caret, selection, word wrap, undo, clipboard,
        // drag-drop and IME composition over a document that stays FLAT text,
        // instead of the rich HTML a bare `contenteditable` accumulates from
        // every paste. Rich content is what T935 and T936 add back
        // deliberately, as our own nodes.
        //
        // `role="textbox"` + `aria-multiline`: a screen reader reads this as
        // the multi-line field it is. That accessibility is the engine's, and
        // getting it for free is one of the things D43 was answered for.
        \\<!DOCTYPE html><html><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<style>
        ,
        css,
        \\</style></head><body>
        \\<div id="
        ,
        box_id,
        \\" contenteditable="plaintext-only" spellcheck="true" role="textbox"
        \\ aria-multiline="true" data-placeholder=""></div>
        \\<script>
        ,
        js,
        \\</script></body></html>
        ,
    });
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "the document carries both assets and the editable box" {
    const html = try documentAlloc(testing.allocator);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "<!DOCTYPE html>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "contenteditable=\"plaintext-only\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"" ++ box_id ++ "\"") != null);
    // The assets are INLINE: the page has an opaque origin and can fetch
    // nothing, so a document that merely linked them would render bare.
    try testing.expect(std.mem.indexOf(u8, html, "white-space: pre-wrap") != null);
    try testing.expect(std.mem.indexOf(u8, html, "chrome.webview") != null);
    // Nothing may close the script early.
    try testing.expect(std.mem.indexOf(u8, js, "</script>") == null);
    try testing.expect(std.mem.indexOf(u8, css, "</style>") == null);
}

test "both assets agree with box_id" {
    try testing.expect(std.mem.indexOf(u8, css, "#" ++ box_id ++ " {") != null);
    try testing.expect(std.mem.indexOf(u8, js, "getElementById(\"" ++ box_id ++ "\")") != null);
}

test "the stylesheet states no size or color of its own outside a fallback" {
    // Every design number arrives in a `vars` message. A literal that is not a
    // `var(--x, fallback)` default is the divergence D43's mitigation exists to
    // prevent, so the properties that carry design numbers are checked to be
    // driven by custom properties.
    for ([_][]const u8{ "font-size:", "line-height:", "color:", "background:" }) |prop| {
        var it = std.mem.splitScalar(u8, css, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, t, prop)) continue;
            try testing.expect(std.mem.indexOf(u8, t, "var(--") != null);
        }
    }
}

test "vars serialize to the property names the script reads" {
    const v: Vars = .{
        .face = "Segoe UI",
        .font_px = 14,
        .line_px = 18,
        .fg = "#ffffff",
        .bg = "#1a1a1a",
        .placeholder = "#aaaaaa",
        .selection = "#0078d4",
        .placeholder_text = "What's wrong?",
    };
    const out = try v.json(testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"t\":\"vars\"") != null);
    for ([_][]const u8{ "fontPx", "linePx", "fg", "bg", "placeholder", "sel", "face", "text" }) |key| {
        // In the message...
        const quoted = try std.fmt.allocPrint(testing.allocator, "\"{s}\":", .{key});
        defer testing.allocator.free(quoted);
        try testing.expect(std.mem.indexOf(u8, out, quoted) != null);
        // ...and read by the script. This pair is the whole contract, and it
        // is the kind that fails silently: a renamed field simply stops
        // arriving, and the composer keeps its fallback sizes forever.
        const read = try std.fmt.allocPrint(testing.allocator, "v.{s}", .{key});
        defer testing.allocator.free(read);
        try testing.expect(std.mem.indexOf(u8, js, read) != null);
    }
}

test "seed carries the text verbatim and escapes what JSON must" {
    const out = try seedJson(testing.allocator, "line\n\"quoted\"\ttab", -1, 3);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"t\":\"seed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\\"quoted\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"caret\":-1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"gen\":3") != null);
    // The page has to echo it back, or the guard it exists for never fires.
    try testing.expect(std.mem.indexOf(u8, js, "gen") != null);
}

test "a snapshot carries the generation it was measured under" {
    const p = parse(testing.allocator, "{\"t\":\"state\",\"text\":\"a\",\"lines\":1,\"caret\":1,\"gen\":4}") orelse
        return error.NotParsed;
    defer p.deinit();
    try testing.expectEqual(@as(u32, 4), p.message.state.gen);
}

test "a snapshot from a page that has never been seeded is generation zero" {
    const p = parse(testing.allocator, "{\"t\":\"state\",\"text\":\"a\",\"lines\":1,\"caret\":1}") orelse
        return error.NotParsed;
    defer p.deinit();
    try testing.expectEqual(@as(u32, 0), p.message.state.gen);
}

test "a state snapshot round-trips" {
    const p = parse(testing.allocator, "{\"t\":\"state\",\"text\":\"héllo\\nthere\",\"lines\":2,\"caret\":7}") orelse
        return error.NotParsed;
    defer p.deinit();
    switch (p.message) {
        .state => |s| {
            try testing.expectEqualStrings("héllo\nthere", s.text);
            try testing.expectEqual(@as(u32, 2), s.lines);
            try testing.expectEqual(@as(?u32, 7), s.caret);
        },
        else => return error.WrongMessage,
    }
}

test "a caret the page could not resolve is null, not zero" {
    const p = parse(testing.allocator, "{\"t\":\"state\",\"text\":\"abc\",\"lines\":1,\"caret\":-1}") orelse
        return error.NotParsed;
    defer p.deinit();
    try testing.expectEqual(@as(?u32, null), p.message.state.caret);
}

test "a zero or missing line count still reads as one line" {
    const p = parse(testing.allocator, "{\"t\":\"state\",\"text\":\"\",\"lines\":0,\"caret\":0}") orelse
        return error.NotParsed;
    defer p.deinit();
    try testing.expectEqual(@as(u32, 1), p.message.state.lines);
}

test "ready and focus parse" {
    {
        const p = parse(testing.allocator, "{\"t\":\"ready\"}") orelse return error.NotParsed;
        defer p.deinit();
        try testing.expectEqual(Message.ready, p.message);
    }
    {
        const p = parse(testing.allocator, "{\"t\":\"focus\",\"on\":true}") orelse return error.NotParsed;
        defer p.deinit();
        try testing.expect(p.message.focus);
    }
}

test "anything the channel did not expect is dropped, not fatal" {
    for ([_][]const u8{
        "",
        "not json",
        "[]",
        "{}",
        "{\"t\":\"nope\"}",
        "{\"t\":\"state\"}",
        "{\"t\":\"state\",\"text\":5,\"lines\":1}",
        "{\"t\":\"focus\"}",
        "{\"t\":42}",
    }) |bad| {
        try testing.expect(parse(testing.allocator, bad) == null);
    }
}
