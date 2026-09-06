//! Find-in-page for viewer panes, the pure half (T1184).
//!
//! The SEARCH is not here and never will be: it lives in the shared
//! `src/viewer/find.js`, which indexes the document, matches, paints with the
//! CSS Custom Highlight API and counts. Both platforms drive that one engine,
//! so a fix to (say) a match that straddled a paragraph lands for Mac and
//! Windows at once. What this module owns is everything around it that a
//! window would otherwise hide: how the count READS, what Escape and Return
//! mean when a pane has more than one text field alive, the exact JavaScript
//! the pane evaluates, and where the card's controls sit at one DPI scale.
//!
//! No OS imports, so it asserts in the `none` lane at every scale — the same
//! arrangement `viewer_nav_layout.zig` and `viewer_accel.zig` use, and for the
//! same reason: the defects here are invisible at 1.0 and obvious at 1.25.

const std = @import("std");
const icon_button = @import("icon_button.zig");
const banner_card = @import("banner_card.zig");

pub const Rect = icon_button.Rect;

// -------------------------------------------------------------------------
// What the page reported
// -------------------------------------------------------------------------

/// The page's answer for the current query (`find.js` → `post`).
///
/// A plain value rather than state smeared across the bar, because the
/// interesting behavior is all in how it READS: a count is a lie once the
/// query has been emptied, and a capped count is a lie if it is printed like
/// an exact one.
pub const Result = struct {
    /// Matches on the page, capped by `find.js`'s own MAX_MATCHES.
    total: u32 = 0,
    /// 1-based position of the current match; 0 when there is none.
    index: u32 = 0,
    /// The scan stopped at the cap, so `total` is a floor.
    truncated: bool = false,

    pub const none: Result = .{};

    /// Longest string `label` can produce: "4294967295/4294967295+".
    pub const label_cap: usize = 22;

    /// The browser-style count — "3/17" — or null when there is nothing to
    /// say.
    ///
    /// `has_query` is the FIELD's state, not this value's: a count left over
    /// from the query the user just deleted has to disappear with it, and the
    /// page's clearing report may not have arrived yet.
    pub fn label(self: Result, buf: *[label_cap]u8, has_query: bool) ?[]const u8 {
        if (!has_query) return null;
        if (self.total == 0) return "No results";
        // A capped scan knows only that there are AT LEAST this many; printing
        // "12/5000" would read as an exact count of a page nobody counted.
        return std.fmt.bufPrint(buf, "{d}/{d}{s}", .{
            self.index,
            self.total,
            if (self.truncated) "+" else "",
        }) catch null;
    }
};

// -------------------------------------------------------------------------
// Escape / Return across the pane's text fields
// -------------------------------------------------------------------------

/// What Escape or Return means to a viewer pane's transient fields.
pub const FieldKeyAction = enum {
    /// Throw away a half-typed address and show the pane's real location.
    revert_address,
    /// Put the whole file list back in a diff pane's side panel.
    clear_diff_filter,
    /// Close the find card and clear its highlights.
    close_find,
    /// Step to the next / previous match.
    find_next,
    find_previous,
};

/// Which of the pane's transient fields currently holds the caret, plus
/// whether the find card is up at all. A struct rather than four positional
/// bools so a caller cannot silently swap two of them.
pub const Focus = struct {
    address: bool = false,
    /// A diff pane's file filter. Win32 has no such field YET — the side panel
    /// is list-only here — so this is always false today. It is a parameter
    /// rather than an omission because the PRECEDENCE is what this function
    /// exists to pin down, and a filter added later must slot into the order
    /// Mac already established rather than be re-argued then.
    diff_filter: bool = false,
    find: bool = false,
    /// The card is mounted (whether or not its field has the caret).
    find_open: bool = false,
};

/// Decide what Escape/Return means given which field has the caret — Mac's
/// `ViewerView.fieldKeyAction`, and pure for the same reason: a viewer pane
/// can have an address field, a diff file filter and a find field alive at
/// once, and every one of them wants Escape.
///
/// Escape belongs to whichever field is being EDITED before it belongs to
/// find: an abandoned address edit left sitting in the bar is a lie about
/// where the pane is, and closing find would not fix it. With no field
/// focused, Escape closes find from the PAGE — which is what a browser does,
/// and where the highlights are.
///
/// Modifiers reject the chord outright. A ctrl+Return in a viewer belongs to
/// the app keybind table, and alt+Escape is the system's.
pub fn fieldKeyAction(vk: u16, mods: Mods, focus: Focus) ?FieldKeyAction {
    if (mods.ctrl or mods.alt or mods.super) return null;
    return switch (vk) {
        vk_escape => blk: {
            if (mods.shift) break :blk null;
            if (focus.address) break :blk .revert_address;
            if (focus.diff_filter) break :blk .clear_diff_filter;
            if (focus.find_open) break :blk .close_find;
            break :blk null;
        },
        vk_return => blk: {
            // Only the find field: Return in a filter opens the top file and
            // in the address bar navigates, both through their own handlers.
            if (!focus.find) break :blk null;
            break :blk if (mods.shift) .find_previous else .find_next;
        },
        else => null,
    };
}

/// `input.Mods`' four flags, restated so this module needs no import from the
/// core. `viewer_accel.zig` converts.
pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
};

const vk_return: u16 = 0x0D;
const vk_escape: u16 = 0x1B;

// -------------------------------------------------------------------------
// The JavaScript the pane evaluates
// -------------------------------------------------------------------------

/// Longest query the card pushes into the page. A find bar is for a word or a
/// phrase; past this the string is truncated rather than refused, because a
/// paste of a whole paragraph should still search its opening rather than do
/// nothing at all.
pub const max_query: usize = 512;

/// Buffer bound for `searchCall`: the wrapper, plus every byte of the query
/// escaped to its worst case (`\u00XX`, six bytes per byte).
pub const search_call_cap: usize = 64 + max_query * 6;

/// `window.__ghozttyFind.clear()`, wrapped like every other call below.
pub const clear_call = guard("window.__ghozttyFind.clear()");
pub const step_next_call = guard("window.__ghozttyFind.step(1)");
pub const step_previous_call = guard("window.__ghozttyFind.step(-1)");

/// Every call the pane makes is guarded on the script being there. A page can
/// be mid-load, or be a document the runtime renders without running our
/// script at all (a PDF); a find that cannot reach the page reports nothing
/// rather than throwing into the console on every keystroke. Mac's
/// `evaluateFind` wraps the same way.
fn guard(comptime call: []const u8) []const u8 {
    return "if (window.__ghozttyFind) { " ++ call ++ "; }";
}

/// `window.__ghozttyFind.search(<query>)` with the query as a JSON string
/// literal, written into `buf`.
///
/// JSON, not "quote it and escape the quotes": the query is the user's text
/// and goes into a JavaScript source string, so a lone backslash, a newline
/// pasted out of a document, or a `</script>`-shaped fragment has to arrive as
/// data. Anything past `max_query` is truncated on a UTF-8 boundary — a
/// half-encoded codepoint would make the whole call unparseable, which fails
/// far worse than a shortened search.
pub fn searchCall(buf: *[search_call_cap]u8, query: []const u8) []const u8 {
    var w: Writer = .{ .buf = buf };
    w.put("if (window.__ghozttyFind) { window.__ghozttyFind.search(");
    w.putJsonString(truncateUtf8(query, max_query));
    w.put("); }");
    return w.written();
}

/// The longest prefix of `text` that is at most `limit` bytes and does not
/// split a UTF-8 sequence.
pub fn truncateUtf8(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    // Continuation bytes are 0b10xxxxxx; back off until the byte at `end`
    // starts a sequence (or we run out, which only an invalid string can do).
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// A bounded writer that silently stops at the end of its buffer. Truncation
/// cannot happen here — `search_call_cap` is sized for the worst case — but a
/// find bar is not a place to fail hard, and `writeAll`'s error union at every
/// call site would be noise.
const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn put(self: *Writer, text: []const u8) void {
        const room = self.buf.len - self.len;
        const n = @min(room, text.len);
        @memcpy(self.buf[self.len..][0..n], text[0..n]);
        self.len += n;
    }

    fn putByte(self: *Writer, b: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = b;
            self.len += 1;
        }
    }

    /// `text` as a JSON string literal, quotes included. Escapes the two
    /// characters JSON requires plus every C0 control, which is what keeps a
    /// pasted newline from ending the JavaScript statement.
    fn putJsonString(self: *Writer, text: []const u8) void {
        self.putByte('"');
        for (text) |c| switch (c) {
            '"' => self.put("\\\""),
            '\\' => self.put("\\\\"),
            '\n' => self.put("\\n"),
            '\r' => self.put("\\r"),
            '\t' => self.put("\\t"),
            // U+2028/U+2029 are line terminators in JavaScript but not in
            // JSON; they arrive here as their UTF-8 bytes, which are >= 0x80
            // and therefore pass through as literal bytes inside the quoted
            // string — where they are data, not statement ends, because the
            // string is a JSON literal rather than a bare source fragment.
            else => if (c < 0x20) {
                var hex: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}) catch unreachable;
                self.put(&hex);
            } else self.putByte(c),
        };
        self.putByte('"');
    }

    fn written(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};

// -------------------------------------------------------------------------
// The card's geometry
// -------------------------------------------------------------------------

/// The card's controls, in row order after the field.
pub const Button = enum { previous, next, close };
pub const button_count = std.enums.values(Button).len;

/// Widest the card is allowed to get, in DIP — Mac's `findBarMaxWidth`, minus
/// the outer margin it counts inside its own constraint. Wide enough for a
/// real phrase plus the count and three buttons; capped so it never spans a
/// wide pane like a toolbar, which is exactly what the card is not.
pub const card_max_dip: f32 = 384.0;

/// Gap between the card and the content's top and trailing edges.
pub const margin_dip: f32 = 8.0;

/// The card's own padding, and the gap between things inside its row.
pub const pad_h_dip: f32 = 8.0;
pub const pad_v_dip: f32 = 6.0;
pub const gap_dip: f32 = 4.0;

/// The leading magnifier's box. Not an icon BUTTON — it answers no click — so
/// it gets the mark's own extent rather than a 28 DIP target square.
pub const glyph_dip: f32 = 16.0;

/// The field's designed minimum, the same rule the nav bar's address field
/// follows: a find field is either wide enough to read a word in or the card
/// does not open at all. There is deliberately no shrinking middle ground.
pub const field_min_dip: f32 = 96.0;

/// The honesty note's line height (`find.js` → `scopeNote`), in DIP.
pub const note_line_dip: f32 = 14.0;

/// Everything the card paints, in physical pixels, relative to the card's own
/// client area — except `card`, which is where that area sits inside the
/// pane's CONTENT rect (below the nav bar's band when one is showing).
pub const Layout = struct {
    /// The card's frame inside the content rect. EMPTY when this pane is too
    /// narrow to hold a legible card — see `fits`.
    card: Rect,
    /// The search field (a real EDIT fills this).
    field: Rect,
    /// Where the "3/17" is drawn, right-aligned in its box. EMPTY when there
    /// is no count to show.
    count: Rect,
    /// The leading magnifier.
    glyph: Rect,
    buttons: [button_count]Rect,
    /// The honesty note's line, under the row. EMPTY when there is no note.
    note: Rect,

    pub fn button(self: *const Layout, b: Button) Rect {
        return self.buttons[@intFromEnum(b)];
    }

    /// Whether this pane can hold the card at all.
    pub fn fits(self: *const Layout) bool {
        return self.card.width() > 0;
    }

    /// Which control `(x, y)` — in the card's client coordinates — is over,
    /// or null. The hit box is the painted square grown by the icon system's
    /// own hit padding, exactly like the nav bar's.
    pub fn hitButton(self: *const Layout, scale: f32, x: i32, y: i32) ?Button {
        const m = icon_button.Metrics.init(scale);
        for (std.enums.values(Button)) |b| {
            const box = self.buttons[@intFromEnum(b)];
            if (box.width() <= 0) continue;
            if (x >= box.left - m.hit_pad and x < box.right + m.hit_pad and
                y >= box.top - m.hit_pad and y < box.bottom + m.hit_pad)
            {
                return b;
            }
        }
        return null;
    }
};

/// Lay the card out for one scale, one content width, one measured count
/// width, and whether the page gave us a note to show.
///
/// `count_w` is MEASURED by the bar (`GetTextExtentPoint32W`) and passed in
/// rather than estimated from a character count: "No results" and "3/17" are
/// different widths in the same font, and a card that reserved the wider of
/// them always would have a visible hole in it most of the time.
pub fn layout(scale: f32, content_w: i32, count_w: i32, has_note: bool) Layout {
    const m = icon_button.Metrics.init(scale);
    const margin = px(margin_dip, scale);
    const pad_h = px(pad_h_dip, scale);
    const pad_v = px(pad_v_dip, scale);
    const gap = px(gap_dip, scale);
    const glyph_w = px(glyph_dip, scale);
    const field_min = px(field_min_dip, scale);
    const note_h = if (has_note) px(note_line_dip, scale) else 0;

    var empty: Layout = .{
        .card = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .field = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .count = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .glyph = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .buttons = undefined,
        .note = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };
    for (&empty.buttons) |*b| b.* = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

    // Everything in the row except the field, which takes what is left.
    const fixed = glyph_w + gap +
        (if (count_w > 0) count_w + gap else 0) +
        @as(i32, button_count) * (m.target + gap) - gap;
    const min_card = pad_h * 2 + fixed + gap + field_min;
    const max_card = px(card_max_dip, scale);

    const avail = content_w - margin * 2;
    if (avail < min_card) return empty;

    const card_w = @min(max_card, avail);
    const row_h = @max(m.target, glyph_w);
    const card_h = pad_v * 2 + row_h + note_h;

    // Top-TRAILING, the corner Chrome trained people to look at, and the one
    // a left-to-right document's text is least often against.
    const left = content_w - margin - card_w;
    var out: Layout = .{
        .card = .{
            .left = left,
            .top = margin,
            .right = left + card_w,
            .bottom = margin + card_h,
        },
        .field = undefined,
        .count = undefined,
        .glyph = undefined,
        .buttons = undefined,
        .note = undefined,
    };

    const row_top = pad_v;
    out.glyph = centeredIn(pad_h, row_top, glyph_w, glyph_w, row_h);

    // The trailing cluster is placed from the card's right edge inward, so the
    // field absorbs every pixel of a width change and the buttons never move
    // under a cursor that is already on one.
    var x = card_w - pad_h;
    var i: usize = button_count;
    var buttons: [button_count]Rect = undefined;
    while (i > 0) {
        i -= 1;
        const b: Button = @enumFromInt(i);
        buttons[@intFromEnum(b)] = centeredIn(x - m.target, row_top, m.target, m.target, row_h);
        x -= m.target + gap;
    }
    out.buttons = buttons;
    x += gap; // the gap after the last button placed is the field's, not a button's

    if (count_w > 0) {
        out.count = centeredIn(x - count_w, row_top, count_w, row_h, row_h);
        x -= count_w + gap;
    } else {
        out.count = .{ .left = x, .top = row_top, .right = x, .bottom = row_top };
    }

    const field_left = pad_h + glyph_w + gap;
    out.field = .{
        .left = field_left,
        .top = row_top,
        .right = @max(x, field_left),
        .bottom = row_top + row_h,
    };

    out.note = if (has_note) .{
        .left = pad_h,
        .top = row_top + row_h,
        .right = card_w - pad_h,
        .bottom = row_top + row_h + note_h,
    } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

    return out;
}

/// A `w`-by-`h` box at `x`, centered vertically in a `row_h` band at `top`.
fn centeredIn(x: i32, top: i32, w: i32, h: i32, row_h: i32) Rect {
    const y = top + @divTrunc(row_h - h, 2);
    return .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
}

/// The rounded silhouette the CARD WINDOW is clipped to (T1391).
///
/// The card is painted by compositing onto a backdrop of the pane's
/// background, which means the four corners carry that ASSUMED colour rather
/// than the pixels actually behind them. Clipping the window to this shape is
/// what makes the corners genuinely not-there: they are never painted, so any
/// content shows through unchanged. The radius is `banner_card.RADIUS` — the
/// number the card surface itself is drawn with — so the clip cannot drift
/// away from the paint.
pub const CornerRegion = struct {
    /// `CreateRoundRectRgn` takes an EXCLUSIVE right/bottom, so these are the
    /// card's size plus one, not its size.
    right: i32,
    bottom: i32,
    /// And ELLIPSE DIAMETERS, not a radius — hence twice the corner radius,
    /// never more than the card's shortest side.
    ellipse: i32,
};

/// The clip for a card of `w` x `h` physical pixels at `scale`.
pub fn cornerRegion(w: i32, h: i32, scale: f32) CornerRegion {
    const shortest = @max(@min(w, h), 0);
    return .{
        .right = w + 1,
        .bottom = h + 1,
        .ellipse = @min(2 * px(banner_card.RADIUS, scale), shortest),
    };
}

fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the card's clip rounds at the radius the card is drawn with" {
    // 1.0 and 1.5 scale: the ellipse is twice the scaled card radius, and the
    // region's edges are exclusive, so they sit one past the card.
    const one = cornerRegion(300, 44, 1.0);
    try testing.expectEqual(@as(i32, 301), one.right);
    try testing.expectEqual(@as(i32, 45), one.bottom);
    try testing.expectEqual(@as(i32, 28), one.ellipse);

    const hidpi = cornerRegion(450, 66, 1.5);
    try testing.expectEqual(@as(i32, 451), hidpi.right);
    try testing.expectEqual(@as(i32, 67), hidpi.bottom);
    try testing.expectEqual(@as(i32, 42), hidpi.ellipse);
}

test "a card shorter than the corner never rounds past its own edge" {
    // GDI would clamp for us, but then the clip and the paint would disagree
    // about the shape silently. A card this small cannot happen today; the
    // point is that it degrades to a stadium rather than to nonsense.
    const tiny = cornerRegion(200, 10, 1.0);
    try testing.expectEqual(@as(i32, 10), tiny.ellipse);
}

test "the clip's radius is the card's radius, at any scale" {
    // The one property worth stating outright: no second copy of the number.
    var scale: f32 = 1.0;
    while (scale <= 3.0) : (scale += 0.25) {
        // Tall enough that the shortest-side clamp never enters into it.
        const r = cornerRegion(600, 200, scale);
        try testing.expectEqual(2 * px(banner_card.RADIUS, scale), r.ellipse);
    }
}

test "the count reads the way a browser's does" {
    var buf: [Result.label_cap]u8 = undefined;
    const r: Result = .{ .total = 17, .index = 3 };
    try testing.expectEqualStrings("3/17", r.label(&buf, true).?);
}

test "an emptied query takes its count with it" {
    // The page's clearing report may not have arrived yet, and a stale "3/17"
    // over an empty field is a claim about a search nobody is running.
    var buf: [Result.label_cap]u8 = undefined;
    const r: Result = .{ .total = 17, .index = 3 };
    try testing.expect(r.label(&buf, false) == null);
}

test "a query with no matches says so rather than showing 0/0" {
    var buf: [Result.label_cap]u8 = undefined;
    try testing.expectEqualStrings("No results", Result.none.label(&buf, true).?);
}

test "a capped scan is never printed as an exact count" {
    var buf: [Result.label_cap]u8 = undefined;
    const r: Result = .{ .total = 5000, .index = 12, .truncated = true };
    try testing.expectEqualStrings("12/5000+", r.label(&buf, true).?);
}

test "Escape belongs to the field being edited before it belongs to find" {
    // An abandoned address edit left sitting in the bar is a lie about where
    // the pane is, and closing find would not fix it.
    try testing.expectEqual(
        FieldKeyAction.revert_address,
        fieldKeyAction(vk_escape, .{}, .{ .address = true, .find_open = true }).?,
    );
    try testing.expectEqual(
        FieldKeyAction.clear_diff_filter,
        fieldKeyAction(vk_escape, .{}, .{ .diff_filter = true, .find_open = true }).?,
    );
    // Address outranks the filter, which outranks find — one order, asserted
    // whole rather than pairwise.
    try testing.expectEqual(
        FieldKeyAction.revert_address,
        fieldKeyAction(vk_escape, .{}, .{
            .address = true,
            .diff_filter = true,
            .find = true,
            .find_open = true,
        }).?,
    );
}

test "Escape closes find from the page, not only from the field" {
    // The highlights are the PAGE's state; a browser's Escape clears them from
    // wherever the caret is.
    try testing.expectEqual(
        FieldKeyAction.close_find,
        fieldKeyAction(vk_escape, .{}, .{ .find_open = true }).?,
    );
    // With no card up it is nobody's — the page keeps its own Escape.
    try testing.expect(fieldKeyAction(vk_escape, .{}, .{}) == null);
}

test "Return steps only from the find field" {
    try testing.expectEqual(
        FieldKeyAction.find_next,
        fieldKeyAction(vk_return, .{}, .{ .find = true, .find_open = true }).?,
    );
    try testing.expectEqual(
        FieldKeyAction.find_previous,
        fieldKeyAction(vk_return, .{ .shift = true }, .{ .find = true, .find_open = true }).?,
    );
    // Return in the address bar navigates and in a filter opens a file; both
    // have their own handlers, and find must not intercept either.
    try testing.expect(
        fieldKeyAction(vk_return, .{}, .{ .address = true, .find_open = true }) == null,
    );
    // An open card whose field does NOT have the caret does not claim Return:
    // the page's own forms still work under a search.
    try testing.expect(fieldKeyAction(vk_return, .{}, .{ .find_open = true }) == null);
}

test "a modified Escape or Return is not ours" {
    // ctrl+Return belongs to the app keybind table and alt+Escape to Windows.
    try testing.expect(
        fieldKeyAction(vk_return, .{ .ctrl = true }, .{ .find = true, .find_open = true }) == null,
    );
    try testing.expect(
        fieldKeyAction(vk_escape, .{ .alt = true }, .{ .find_open = true }) == null,
    );
    try testing.expect(
        fieldKeyAction(vk_escape, .{ .shift = true }, .{ .find_open = true }) == null,
    );
}

test "the search call carries the query as data, not as source" {
    var buf: [search_call_cap]u8 = undefined;
    const call = searchCall(&buf, "a\"b\\c");
    try testing.expect(std.mem.indexOf(u8, call, "window.__ghozttyFind.search(") != null);
    try testing.expect(std.mem.indexOf(u8, call, "\"a\\\"b\\\\c\"") != null);
    // Guarded, so a page that never ran the script reports nothing rather than
    // throwing on every keystroke.
    try testing.expect(std.mem.startsWith(u8, call, "if (window.__ghozttyFind)"));
}

test "a pasted newline cannot end the statement" {
    // The one escape that is a SECURITY property rather than a cosmetic one: a
    // raw newline inside a JavaScript string literal is a syntax error, and a
    // string that closes early is a fragment the page would execute.
    var buf: [search_call_cap]u8 = undefined;
    const call = searchCall(&buf, "one\ntwo\x01");
    try testing.expect(std.mem.indexOf(u8, call, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, call, "\\u0001") != null);
    try testing.expect(std.mem.indexOf(u8, call, "\n") == null);
}

test "an over-long query is truncated on a codepoint boundary" {
    // Half a UTF-8 sequence would make the whole call unparseable, which fails
    // far worse than a shortened search.
    const alloc = testing.allocator;
    const long = try alloc.alloc(u8, max_query + 10);
    defer alloc.free(long);
    var i: usize = 0;
    while (i + 1 < long.len) : (i += 2) {
        long[i] = 0xC3; // "é"
        long[i + 1] = 0xA9;
    }
    if (i < long.len) long[i] = 'a';
    const kept = truncateUtf8(long, max_query);
    try testing.expect(kept.len <= max_query);
    try testing.expect(std.unicode.utf8ValidateSlice(kept));
}

test "the card sits at the content's top-trailing corner at every scale" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layout(scale, px(900.0, scale), px(40.0, scale), false);
        try testing.expect(l.fits());
        const margin = px(margin_dip, scale);
        try testing.expectEqual(margin, l.card.top);
        try testing.expectEqual(px(900.0, scale) - margin, l.card.right);
        // Capped: a wide pane must not grow the card into a toolbar.
        try testing.expectEqual(px(card_max_dip, scale), l.card.width());
    }
}

test "the field absorbs a width change; the buttons stay put" {
    // The trailing cluster is placed from the right edge inward, so a card
    // that narrows never moves a button under a cursor already on it.
    // 600 is wide enough that the card is at its cap; 380 is not, so the card
    // itself is narrower and something inside it has to give.
    const wide = layout(1.0, 600, 40, false);
    const narrow = layout(1.0, 380, 40, false);
    try testing.expect(narrow.card.width() < wide.card.width());
    try testing.expect(wide.fits() and narrow.fits());
    for (std.enums.values(Button)) |b| {
        try testing.expectEqual(
            wide.card.width() - wide.button(b).left,
            narrow.card.width() - narrow.button(b).left,
        );
    }
    try testing.expect(narrow.field.width() < wide.field.width());
}

test "a pane too narrow for a legible field gets no card at all" {
    // The nav bar's rule, for the same reason: a two-pixel EDIT with a caret
    // in it looks like a rendering fault, not a compact mode.
    const l = layout(1.0, 180, 40, false);
    try testing.expect(!l.fits());
    try testing.expectEqual(@as(i32, 0), l.field.width());
}

test "the honesty note gets its own line under the row" {
    const without = layout(1.0, 600, 40, false);
    const with = layout(1.0, 600, 40, true);
    try testing.expect(with.card.height() > without.card.height());
    try testing.expectEqual(@as(i32, 0), without.note.width());
    try testing.expect(with.note.top >= with.field.bottom);
    // The note is as wide as the card's content, so a long phrase has the
    // whole line rather than the field's share of it.
    try testing.expectEqual(with.card.width() - px(pad_h_dip, 1.0) * 2, with.note.width());
}

test "no count means no hole where one would be" {
    const with = layout(1.0, 600, 40, false);
    const without = layout(1.0, 600, 0, false);
    try testing.expect(without.field.width() > with.field.width());
    try testing.expectEqual(@as(i32, 0), without.count.width());
}

test "every control is inside the card, and none of them overlap" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layout(scale, px(700.0, scale), px(44.0, scale), true);
        try testing.expect(l.fits());
        const w = l.card.width();
        const h = l.card.height();
        const boxes = [_]Rect{ l.glyph, l.field, l.count, l.note } ++ l.buttons;
        for (boxes) |b| {
            if (b.width() <= 0) continue;
            try testing.expect(b.left >= 0 and b.right <= w);
            try testing.expect(b.top >= 0 and b.bottom <= h);
        }
        // Row order, left to right, with nothing sitting on top of anything.
        try testing.expect(l.glyph.right <= l.field.left);
        try testing.expect(l.field.right <= l.count.left);
        try testing.expect(l.count.right <= l.button(.previous).left);
        try testing.expect(l.button(.previous).right <= l.button(.next).left);
        try testing.expect(l.button(.next).right <= l.button(.close).left);
    }
}

test "a click lands on the control it looks like it landed on" {
    const l = layout(1.0, 600, 40, false);
    const next = l.button(.next);
    const cx = next.left + @divTrunc(next.width(), 2);
    const cy = next.top + @divTrunc(next.height(), 2);
    try testing.expectEqual(Button.next, l.hitButton(1.0, cx, cy).?);
    // The field is nobody's button.
    try testing.expect(l.hitButton(1.0, l.field.left + 4, cy) == null);
}
