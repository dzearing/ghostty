//! The release-notes RENDERER (T625) — one walker that measures and paints a
//! `release_notes.Partitioned`, shared by everything that shows notes.
//!
//! Mac keeps `WhatsNewNotesContent` as one view used by the What's New window,
//! the update popover and the agent-restart alert's accessory, with a
//! `Density` knob between them. T624 built the Windows half of that renderer
//! inside `WhatsNewWindow.zig`, where only the window could reach it; T625
//! needs the SAME pixels inside a `ConfirmDialog`. Lifting it here rather than
//! copying it is the whole point: two renderers drift, and the thing they
//! would drift about — what a release note looks like — is the only thing the
//! user sees.
//!
//! What lives here: the size classes, the GDI font cache, inline-markdown
//! measurement/wrapping/drawing, the link table a click is resolved against,
//! and the release/section/bullet walk. What does NOT: window chrome, tabs,
//! scrollbars, hit-testing outside the text — those belong to whoever hosts
//! the renderer, because a window and a dialog accessory host them
//! differently.
//!
//! `draw = false` measures and `draw = true` paints, through the same code, so
//! a scroll extent and the pixels under it cannot disagree.

const std = @import("std");
const Allocator = std.mem.Allocator;

const brush_cache = @import("brush_cache.zig");
const markdown = @import("banner_markdown.zig");
const layout = @import("whats_new_layout.zig");
const panel_theme = @import("panel_theme.zig");
const release_notes = @import("release_notes.zig");
const type_ramp = @import("type_ramp.zig");
const w32 = @import("win32.zig");

/// Text size classes, in the order `fontFor` indexes them.
pub const SizeClass = enum(usize) {
    /// A release's version banner: the ramp's subtitle.
    version = 0,
    /// A section heading and a bullet's bold lead.
    strong = 1,
    /// Body copy.
    body = 2,
    /// The divider label and other de-emphasized text.
    caption = 3,
};

const size_class_count = 4;
const font_slots = size_class_count * 8;

/// A drawn link and the rectangle it occupies, in the host's client
/// coordinates. Recorded on every paint, so a click resolves against what is
/// actually on screen rather than against a stale layout.
pub const Link = struct {
    rect: w32.RECT,
    url: []const u8,
};

/// Shared fill helper — the hosts paint their own chrome with it too, so there
/// is one brush cache rather than one per window class.
var fill_brush: brush_cache.CachedBrush = .{};

pub fn fillRect(hdc: w32.HDC, r: layout.Rect, color: u32) void {
    var rc: w32.RECT = .{
        .left = r.x,
        .top = r.y,
        .right = r.x + r.w,
        .bottom = r.y + r.h,
    };
    if (fill_brush.get(color)) |b| _ = w32.FillRect(hdc, &rc, b);
}

pub fn cr(c: panel_theme.Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

pub const Renderer = struct {
    alloc: Allocator,
    scale: f32,
    density: layout.Density,
    /// Refreshed by the host before each paint: the theme can flip under a
    /// live window, and a GDI color is a value, not a subscription.
    palette: panel_theme.Panel,
    /// Show only the "new since your last version" half. The window shows
    /// both halves under a labelled rule; a dialog accessory has room for one
    /// question only — "what does this update buy me?" — so it takes the
    /// fresh half and stops.
    fresh_only: bool = false,
    fonts: [font_slots]?*anyopaque = @splat(null),
    links: std.ArrayList(Link) = .empty,
    /// Owns the URL text in `links`. The markdown is re-parsed into a
    /// throwaway arena on every paint, so a recorded link cannot borrow from
    /// it: the click that follows the link happens long after that arena is
    /// gone. Reset by `beginPaint`, which is also when `links` is cleared.
    link_text: std.heap.ArenaAllocator,

    pub fn init(
        alloc: Allocator,
        scale: f32,
        density: layout.Density,
        palette: panel_theme.Panel,
    ) Renderer {
        return .{
            .alloc = alloc,
            .scale = scale,
            .density = density,
            .palette = palette,
            .link_text = .init(alloc),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.clearFonts();
        self.links.deinit(self.alloc);
        self.link_text.deinit();
    }

    pub fn clearFonts(self: *Renderer) void {
        for (&self.fonts) |*f| {
            if (f.*) |h| _ = w32.DeleteObject(h);
            f.* = null;
        }
    }

    /// A DPI change means every cached font is the wrong size.
    pub fn setScale(self: *Renderer, scale: f32) void {
        if (scale == self.scale) return;
        self.scale = scale;
        self.clearFonts();
    }

    /// Drop the link table recorded by the previous paint. Call before every
    /// `render(..., draw = true)`; a measure pass records nothing.
    pub fn beginPaint(self: *Renderer) void {
        self.links.clearRetainingCapacity();
        _ = self.link_text.reset(.retain_capacity);
    }

    pub fn metrics(self: *const Renderer) layout.Metrics {
        return layout.metricsFor(self.scale, self.density);
    }

    /// The URL under a point, if any — the click and hover answer both hosts
    /// ask after a paint.
    pub fn linkAt(self: *const Renderer, x: i32, y: i32) ?[]const u8 {
        for (self.links.items) |l| {
            if (x >= l.rect.left and x < l.rect.right and
                y >= l.rect.top and y < l.rect.bottom) return l.url;
        }
        return null;
    }

    // -----------------------------------------------------------------
    // Fonts
    // -----------------------------------------------------------------

    pub fn rampFor(self: *const Renderer, class: SizeClass) type_ramp.Font {
        return switch (class) {
            .version => type_ramp.subtitle(self.scale),
            .strong => type_ramp.bodyStrong(self.scale),
            .body => type_ramp.body(self.scale),
            .caption => type_ramp.caption(self.scale),
        };
    }

    pub fn lineHeight(self: *const Renderer, class: SizeClass) i32 {
        return type_ramp.lineBox(self.rampFor(class), self.scale);
    }

    /// The GDI font for a style at a size class, cached for the renderer's
    /// life.
    fn fontFor(self: *Renderer, style: markdown.Style, class: SizeClass) ?*anyopaque {
        const ramp = self.rampFor(class);
        const bold = style.bold or class == .version or class == .strong;
        const bits: usize = @as(usize, @intFromBool(bold)) |
            (@as(usize, @intFromBool(style.italic)) << 1) |
            (@as(usize, @intFromBool(style.code)) << 2);
        const idx = @intFromEnum(class) * 8 + bits;
        if (self.fonts[idx]) |f| return f;
        const face = if (style.code)
            std.unicode.utf8ToUtf16LeStringLiteral("Consolas")
        else
            std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face);
        self.fonts[idx] = w32.CreateFontW(
            -ramp.height,
            0,
            0,
            0,
            if (bold) type_ramp.weight_semibold else ramp.weight,
            @intFromBool(style.italic),
            0,
            0,
            w32.DEFAULT_CHARSET,
            0,
            0,
            0,
            0,
            face,
        );
        return self.fonts[idx];
    }

    // -----------------------------------------------------------------
    // Text: measure, wrap, draw
    // -----------------------------------------------------------------

    pub fn measure(
        self: *Renderer,
        hdc: w32.HDC,
        text: []const u8,
        style: markdown.Style,
        class: SizeClass,
    ) w32.SIZE {
        var wbuf: [512]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return .{ .cx = 0, .cy = 0 };
        if (wlen == 0) return .{ .cx = 0, .cy = 0 };
        const font = self.fontFor(style, class);
        const prev = w32.SelectObject(hdc, font);
        defer _ = w32.SelectObject(hdc, prev);
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
        return size;
    }

    /// Draw one run at (x, y); returns its width. Never wraps.
    pub fn drawText(
        self: *Renderer,
        hdc: w32.HDC,
        x: i32,
        y: i32,
        text: []const u8,
        style: markdown.Style,
        class: SizeClass,
        color: u32,
        draw: bool,
    ) i32 {
        var wbuf: [512]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
        if (wlen == 0) return 0;
        const font = self.fontFor(style, class);
        const prev = w32.SelectObject(hdc, font);
        defer _ = w32.SelectObject(hdc, prev);
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
        if (draw) {
            _ = w32.SetTextColor(hdc, color);
            _ = w32.TextOutW(hdc, x, y, &wbuf, @intCast(wlen));
        }
        return size.cx;
    }

    /// One measured word (or run of whitespace) of a styled inline run.
    const Token = struct {
        text: []const u8,
        style: markdown.Style,
        link: ?[]const u8,
        width: i32,
        is_space: bool,
    };

    /// Parse `source` as inline markdown, wrap it to `width`, and draw it (or
    /// just measure it). Returns the height consumed.
    ///
    /// `base` is the style every run inherits — a bullet's bold lead is bold
    /// markdown or not, and either way it renders bold.
    pub fn drawWrapped(
        self: *Renderer,
        hdc: w32.HDC,
        x: i32,
        y: i32,
        width: i32,
        source: []const u8,
        base: markdown.Style,
        class: SizeClass,
        color: u32,
        draw: bool,
    ) i32 {
        const line_h = self.lineHeight(class);
        var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const segs = markdown.parseSegs(arena, .{}, source, false) catch {
            // Out of memory mid-parse: fall back to the raw string rather than
            // dropping the note entirely.
            if (draw) _ = self.drawText(hdc, x, y, source, base, class, color, true);
            return line_h;
        };

        var tokens: std.ArrayList(Token) = .empty;
        for (segs) |item| {
            const seg: markdown.Seg = switch (item) {
                .seg => |s| s,
                // The banner draws these natively; a release note is prose, so
                // the glyph fallback is right here.
                .checkbox => |on| .{ .text = if (on) "\u{2611}" else "\u{2610}" },
            };
            var style = seg.style;
            if (base.bold) style.bold = true;
            if (base.italic) style.italic = true;
            // A link's rule is drawn by its color; GDI's own underline is only
            // ever solid and would read as permanently hovered.
            style.underline = false;
            self.tokenize(hdc, arena, &tokens, seg.text, style, seg.link, class) catch break;
        }
        if (tokens.items.len == 0) return line_h;

        var widths: std.ArrayList(f32) = .empty;
        var spaces: std.ArrayList(bool) = .empty;
        for (tokens.items) |t| {
            widths.append(arena, @floatFromInt(t.width)) catch break;
            spaces.append(arena, t.is_space) catch break;
        }
        if (widths.items.len != tokens.items.len) return line_h;

        const lines = markdown.wrapTokens(
            arena,
            widths.items,
            spaces.items,
            @floatFromInt(@max(1, width)),
        ) catch return line_h;

        var ly = y;
        for (lines) |line| {
            var lx = x;
            for (tokens.items[line.start..line.end]) |t| {
                const c = if (t.link != null) cr(self.palette.accent) else color;
                const w = self.drawText(hdc, lx, ly, t.text, t.style, class, c, draw);
                if (draw and t.link != null and !t.is_space) {
                    // Copied, not borrowed: `t.link` lives in this call's arena.
                    if (self.link_text.allocator().dupe(u8, t.link.?)) |url| {
                        self.links.append(self.alloc, .{
                            .rect = .{
                                .left = lx,
                                .top = ly,
                                .right = lx + w,
                                .bottom = ly + line_h,
                            },
                            .url = url,
                        }) catch {};
                    } else |_| {}
                }
                lx += w;
            }
            ly += line_h;
        }
        return ly - y;
    }

    /// Split `text` into words and whitespace runs, measuring each. The link
    /// and style ride along so a wrapped line can re-select the right font.
    fn tokenize(
        self: *Renderer,
        hdc: w32.HDC,
        arena: Allocator,
        out: *std.ArrayList(Token),
        text: []const u8,
        style: markdown.Style,
        link: ?[]const u8,
        class: SizeClass,
    ) !void {
        var i: usize = 0;
        while (i < text.len) {
            const space = text[i] == ' ' or text[i] == '\t' or text[i] == '\n';
            var j = i + 1;
            while (j < text.len) : (j += 1) {
                const s = text[j] == ' ' or text[j] == '\t' or text[j] == '\n';
                if (s != space) break;
            }
            const slice = text[i..j];
            try out.append(arena, .{
                .text = slice,
                .style = style,
                .link = link,
                .width = self.measure(hdc, slice, style, class).cx,
                .is_space = space,
            });
            i = j;
        }
    }

    // -----------------------------------------------------------------
    // The walk
    // -----------------------------------------------------------------

    /// The one walker: `draw = false` measures, `draw = true` paints. Height
    /// and pixels come from the same code, so they cannot disagree.
    pub fn render(
        self: *Renderer,
        hdc: w32.HDC,
        x: i32,
        top: i32,
        width: i32,
        split: release_notes.Partitioned,
        draw: bool,
    ) i32 {
        const p = self.palette;
        const m = self.metrics();

        var y = top + m.margin;
        if (split.fresh.len == 0) {
            y += self.drawWrapped(
                hdc,
                x,
                y,
                width,
                release_notes.no_new_notes_label,
                .{},
                .body,
                cr(p.secondary),
                draw,
            );
        } else {
            for (split.fresh, 0..) |notes, i| {
                if (i > 0) y += m.release_gap;
                y += self.renderVersion(hdc, x, y, width, notes, draw);
            }
        }

        if (!self.fresh_only and split.installed.len > 0) {
            y += m.rule_gap;
            y += self.renderLabelledRule(hdc, x, y, width, draw);
            y += m.rule_gap;
            for (split.installed, 0..) |notes, i| {
                if (i > 0) y += m.release_gap;
                y += self.renderVersion(hdc, x, y, width, notes, draw);
            }
        }

        y += m.margin;
        return y - top;
    }

    /// Mac's `labelledRule`: a hairline, the label, a hairline.
    fn renderLabelledRule(
        self: *Renderer,
        hdc: w32.HDC,
        x: i32,
        y: i32,
        width: i32,
        draw: bool,
    ) i32 {
        const p = self.palette;
        const m = self.metrics();
        const label = release_notes.installed_divider_label;
        const line_h = self.lineHeight(.caption);
        const text_w = self.measure(hdc, label, .{}, .caption).cx;
        const side = @max(0, @divTrunc(width - text_w - 2 * m.item_gap, 2));
        if (draw) {
            const mid = y + @divTrunc(line_h, 2);
            fillRect(hdc, .{ .x = x, .y = mid, .w = side, .h = m.rule_h }, cr(p.divider));
            fillRect(hdc, .{
                .x = x + width - side,
                .y = mid,
                .w = side,
                .h = m.rule_h,
            }, cr(p.divider));
            _ = self.drawText(
                hdc,
                x + side + m.item_gap,
                y,
                label,
                .{},
                .caption,
                cr(p.secondary),
                true,
            );
        }
        return line_h;
    }

    fn renderVersion(
        self: *Renderer,
        hdc: w32.HDC,
        x: i32,
        y0: i32,
        width: i32,
        notes: release_notes.VersionNotes,
        draw: bool,
    ) i32 {
        const p = self.palette;
        const m = self.metrics();
        var y = y0;

        // The version banners its release block, not a footnote to it.
        if (draw) {
            _ = self.drawText(hdc, x, y, notes.version, .{}, .version, cr(p.text), true);
        }
        y += self.lineHeight(.version);
        y += m.section_gap;

        const titles = release_notes.showsSectionTitles(notes);
        for (notes.sections, 0..) |section, si| {
            if (si > 0) y += m.section_gap;
            if (titles) {
                if (draw) {
                    _ = self.drawText(hdc, x, y, section.title, .{}, .strong, cr(p.text), true);
                }
                y += self.lineHeight(.strong) + m.item_gap;
            }
            for (section.items, 0..) |item, ii| {
                if (ii > 0) y += m.item_gap;
                y += self.renderItem(hdc, x, y, width, item, draw);
            }
        }
        return y - y0;
    }

    fn renderItem(
        self: *Renderer,
        hdc: w32.HDC,
        x: i32,
        y0: i32,
        width: i32,
        item: release_notes.Note,
        draw: bool,
    ) i32 {
        const p = self.palette;
        const m = self.metrics();
        const text_x = x + m.bullet_indent;
        const text_w = @max(1, width - m.bullet_indent);
        var y = y0;

        // The bullet sits in the gutter, so wrapped lines align under the first.
        if (draw) {
            _ = self.drawText(hdc, x, y, "\u{2022}", .{}, .body, cr(p.secondary), true);
        }

        if (item.title) |title| {
            y += self.drawWrapped(hdc, text_x, y, text_w, title, .{ .bold = true }, .strong, cr(p.text), draw);
            y += m.item_line_gap;
            y += self.drawWrapped(hdc, text_x, y, text_w, item.text, .{}, .body, cr(p.secondary), draw);
        } else {
            y += self.drawWrapped(hdc, text_x, y, text_w, item.text, .{}, .body, cr(p.text), draw);
        }
        return y - y0;
    }
};

// ---------------------------------------------------------------------
// Tests
//
// The drawing needs a device context, so what a lane can assert here is the
// wiring: that the density knob a host picks is the one the walk spaces with,
// and that a renderer with no fonts realised yet tears down cleanly (the
// accessory is created and destroyed once per dialog, so that path runs far
// more often than the window's).
// ---------------------------------------------------------------------

const testing = std.testing;

/// A palette to build test renderers from. The values are irrelevant — no
/// test here draws a pixel — but `Panel` has no defaults, so it is resolved
/// exactly the way the app resolves one.
fn testPalette() panel_theme.Panel {
    return panel_theme.resolve(
        .{ .r = 32, .g = 32, .b = 32 },
        .{ .r = 0, .g = 120, .b = 212 },
    );
}

test "Renderer: the density it was built with is the density it spaces with" {
    const p = testPalette();
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        var spacious: Renderer = .init(testing.allocator, s, .spacious, p);
        defer spacious.deinit();
        var compact: Renderer = .init(testing.allocator, s, .compact, p);
        defer compact.deinit();

        try testing.expectEqual(layout.metricsFor(s, .spacious), spacious.metrics());
        try testing.expectEqual(layout.metricsFor(s, .compact), compact.metrics());
        try testing.expect(compact.metrics().release_gap < spacious.metrics().release_gap);

        // Both halves by default: only a host that asks gets the fresh-only
        // cut, so the window cannot lose its "already installed" section to a
        // default that changed underneath it.
        try testing.expect(!spacious.fresh_only);
    }
}

test "Renderer: a DPI change invalidates the font cache, an identical one does not" {
    var r: Renderer = .init(testing.allocator, 1.0, .spacious, testPalette());
    defer r.deinit();
    // Stand in for realised fonts: the handles are never dereferenced by
    // setScale, which only has to drop them.
    r.fonts[0] = @ptrFromInt(@as(usize, 0x1000));
    r.setScale(1.0);
    try testing.expect(r.fonts[0] != null); // same scale: nothing to redo
    r.fonts[0] = null;
    r.setScale(2.0);
    try testing.expectEqual(@as(f32, 2.0), r.scale);
    try testing.expect(r.fonts[0] == null);
}

test "Renderer: linkAt answers only inside a recorded rectangle" {
    var r: Renderer = .init(testing.allocator, 1.0, .compact, testPalette());
    defer r.deinit();
    try r.links.append(r.alloc, .{
        .rect = .{ .left = 10, .top = 20, .right = 60, .bottom = 36 },
        .url = "https://example.invalid/",
    });
    try testing.expect(r.linkAt(11, 21) != null);
    try testing.expect(r.linkAt(60, 21) == null); // right edge is exclusive
    try testing.expect(r.linkAt(11, 36) == null); // and so is the bottom
    try testing.expect(r.linkAt(0, 0) == null);

    // A new paint drops the previous paint's table, so a click after a
    // re-layout cannot follow a link that has moved.
    r.beginPaint();
    try testing.expect(r.linkAt(11, 21) == null);
}
