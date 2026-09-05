//! The KEY-STATE PILL (T446): a small card at the bottom of a pane naming the
//! key tables you are inside and the keys of a multi-key sequence you have
//! pressed so far. The Windows port of Mac's
//! `Ghostty.SurfaceView.KeyStateIndicator`.
//!
//! Both states were invisible here: `.key_sequence` and `.key_table` fell
//! through to a bare `return true` in `App.zig`, so a pane waiting for the
//! second half of a chord looked exactly like a pane that had ignored the
//! first half, and a key table entered by accident silently reinterpreted
//! every subsequent key with nothing on screen to say so.
//!
//! Like DimOverlay/BannerOverlay/ReadonlyBadge it is a `WS_EX_LAYERED` popup
//! owned by its surface HWND, which is what puts it above the pane's OpenGL
//! content, and it takes the read-only badge's `UpdateLayeredWindow`
//! per-pixel-alpha path because it floats over live terminal content rather
//! than over a reserved band whose backdrop it knows. Unlike the badge it IS
//! `WS_EX_TRANSPARENT`: the pill is pure information with nothing to click,
//! and a chip sitting over the middle-bottom of the terminal must never eat a
//! selection drag.
//!
//! The waiting dots animate off a `WM_TIMER`, alive only while a sequence is
//! actually pending — which is a fraction of a second at a time. A static mark
//! could not distinguish "waiting for your next key" from "wedged", which is
//! the exact ambiguity this feature exists to remove.
//!
//! The model is `key_state.zig`; the geometry, colors and card pixels are
//! `key_state_pill.zig` (no OS imports, asserted at 1.0/1.25/1.5/2.0 in every
//! lane). This file owns the window, the GDI text and the timer.

const std = @import("std");
const w32 = @import("win32.zig");
const chrome_fanout = @import("chrome_fanout.zig");
const pill = @import("key_state_pill.zig");
const key_state = @import("key_state.zig");
const icon_paint = @import("icon_button_paint.zig");
const color_math = @import("color_math.zig");

const log = std.log.scoped(.win32_key_state);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyKeyState");

/// Fluent/MDL2 `KeyboardClassic` — what Mac's `keyboard.badge.ellipsis`
/// stands for. As with the read-only badge's eye there is no drawn fallback:
/// a keyboard is not expressible in the quad vocabulary `icon_button` uses,
/// and the table NAME beside it carries the meaning.
const KEYBOARD: u16 = 0xE144;

/// Fluent/MDL2 `ChevronRight` — the separator between nested table names,
/// matching the chevrons Mac draws between the same entries.
const CHEVRON: u16 = 0xE76C;

/// Drawn in the chevron's box when the machine has no icon face. Unlike the
/// keyboard, this one HAS a faithful ASCII stand-in, and without it two nested
/// table names would run together into one meaningless word.
const CHEVRON_FALLBACK = std.unicode.utf8ToUtf16LeStringLiteral(">");

/// Appended as one more table row when the stack is deeper than the model
/// retains, so the pill never implies the innermost table is the last one.
const OVERFLOW_MARK = std.unicode.utf8ToUtf16LeStringLiteral("\u{2026}");

const ui_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");

/// Animation tick and period. 10 fps over 1.2 s is enough for the dots to read
/// as a travelling wave without repainting a layered window any harder than it
/// has to be — and the whole animation is alive for about as long as it takes
/// to press the second key of a chord.
const TIMER_ID: usize = 1;
const TIMER_MS: u32 = 100;
const PERIOD_FRAMES: u32 = 12;

/// One measured, UTF-16 label. Capacity matches the model's byte cap: UTF-8
/// never encodes a codepoint in fewer bytes than UTF-16 uses code units, so a
/// name that fits the model's buffer always fits this one.
const Label = struct {
    buf: [key_state.NAME_CAP]u16 = undefined,
    len: usize = 0,

    fn set(self: *Label, utf8: []const u8) void {
        self.len = std.unicode.utf8ToUtf16Le(&self.buf, utf8) catch 0;
    }

    fn slice(self: *const Label) []const u16 {
        return self.buf[0..self.len];
    }
};

/// Everything measured from one model, ready for `pill.layout`.
const Measured = struct {
    tables: [pill.MAX_ITEMS]Label = @splat(.{}),
    table_w: [pill.MAX_ITEMS]i32 = @splat(0),
    table_count: usize = 0,
    keys: [pill.MAX_KEYS]Label = @splat(.{}),
    key_w: [pill.MAX_KEYS]i32 = @splat(0),
    key_count: usize = 0,
    text_h: i32 = 0,
};

pub const KeyStateIndicator = struct {
    alloc: std.mem.Allocator,
    /// The surface HWND this pill sits on top of (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// Cached label font, rebuilt when the DPI scale changes.
    font: ?*anyopaque = null,
    scale: f32 = 0,
    visible: bool = false,

    /// What was measured and placed last, so an unchanged pane on an
    /// unchanged pass repaints nothing. `update` runs on every layout, focus
    /// and tab-switch pass.
    measured: Measured = .{},
    signature: u64 = 0,
    pane_bg: ?color_math.Rgb = null,
    placed: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

    /// Cached for the animation tick, which has no model to re-derive from.
    metrics: pill.Metrics = pill.Metrics.init(1.0),
    layout: pill.Layout = .{},
    frame: u32 = 0,
    animating: bool = false,

    /// Scratch surfaces for the layered paint, grown on demand.
    bgr: []u32 = &.{},
    mask: []u8 = &.{},

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*KeyStateIndicator {
        try registerClassOnce(hinstance);

        const self = try alloc.create(KeyStateIndicator);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .owner = owner,
            .hwnd = undefined,
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL content, per-pixel alpha.
        // WS_EX_TRANSPARENT — click-through; the pill has nothing to click and
        //   sits where a selection drag ends.
        // WS_EX_NOACTIVATE / WS_EX_TOOLWINDOW — never takes activation, never
        //   appears in the taskbar or Alt-Tab.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_TRANSPARENT |
            w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;

        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP,
            0,
            0,
            1,
            1, // placeholder — update() glues it to the owner
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;

        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *KeyStateIndicator) void {
        self.stopAnimation();
        _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(self.hwnd);
        if (self.font) |f| _ = w32.DeleteObject(f);
        if (self.bgr.len > 0) self.alloc.free(self.bgr);
        if (self.mask.len > 0) self.alloc.free(self.mask);
        self.alloc.destroy(self);
    }

    /// Place and paint the pill over its owner pane for `model`. Idempotent —
    /// this IS the reposition call, so it must stay cheap when nothing moved.
    pub fn update(
        self: *KeyStateIndicator,
        scale: f32,
        pane_bg: color_math.Rgb,
        model: *const key_state.Model,
    ) void {
        if (model.isEmpty() or w32.IsWindowVisible_(self.owner) == 0) {
            self.hide();
            return;
        }

        var owner_rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &owner_rect) == 0) return;
        const pane_w = owner_rect.right - owner_rect.left;
        const pane_h = owner_rect.bottom - owner_rect.top;

        const m = pill.Metrics.init(scale);
        if (scale != self.scale) {
            self.scale = scale;
            if (self.font) |f| _ = w32.DeleteObject(f);
            self.font = w32.CreateFontW(
                -m.font_px,
                0,
                0,
                0,
                600, // medium — Mac's names and key caps are both `.medium`
                0,
                0,
                0,
                w32.DEFAULT_CHARSET,
                0,
                0,
                w32.ANTIALIASED_QUALITY,
                0,
                ui_face,
            );
            // Force a re-measure and repaint: the cache was built with the
            // old font.
            self.signature = 0;
            self.placed = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        }

        const sig = signatureOf(model, scale);
        if (sig != self.signature) {
            self.signature = sig;
            self.measure(model);
        }

        const l = pill.layout(m, pane_w, pane_h, .{
            .tables = self.measured.table_w[0..self.measured.table_count],
            .keys = self.measured.key_w[0..self.measured.key_count],
            .text_h = self.measured.text_h,
        });
        if (l.hidden) {
            self.hide();
            return;
        }

        const rect = w32.RECT{
            .left = owner_rect.left + l.win.left,
            .top = owner_rect.top + l.win.top,
            .right = owner_rect.left + l.win.right,
            .bottom = owner_rect.top + l.win.bottom,
        };
        const bg_changed = self.pane_bg == null or !std.meta.eql(self.pane_bg.?, pane_bg);
        const moved = !std.meta.eql(self.placed, rect);
        const relaid = !std.meta.eql(self.layout, l);
        self.pane_bg = pane_bg;
        self.placed = rect;
        self.metrics = m;
        self.layout = l;

        const was_shown = self.visible;
        chrome_fanout.noteMove(.key_state);
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            rect.left,
            rect.top,
            @max(rect.right - rect.left, 1),
            @max(rect.bottom - rect.top, 1),
            w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
        );
        self.visible = true;

        if (moved or bg_changed or relaid) self.repaint();

        // A pending sequence is what the dots are FOR; a bare key table is a
        // steady state with nothing to animate.
        if (model.visibleKeys() > 0) self.startAnimation() else self.stopAnimation();

        // Every reposition re-checks the z-order rather than leaving it to
        // whatever last touched it (T142, `overlay_zorder.zig`) — except
        // inside a live layout pass, where an already-shown popup cannot have
        // moved in the z-order and the walk is the fan-out's biggest per-pane
        // cost (T1345).
        w32.healOverlayZOrderAfterMove(self.hwnd, self.owner, was_shown);
    }

    pub fn hide(self: *KeyStateIndicator) void {
        self.stopAnimation();
        if (!self.visible) return;
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.visible = false;
    }

    fn startAnimation(self: *KeyStateIndicator) void {
        if (self.animating) return;
        if (w32.SetTimer(self.hwnd, TIMER_ID, TIMER_MS, null) == 0) return;
        self.animating = true;
    }

    fn stopAnimation(self: *KeyStateIndicator) void {
        if (!self.animating) return;
        _ = w32.KillTimer(self.hwnd, TIMER_ID);
        self.animating = false;
        self.frame = 0;
    }

    fn tick(self: *KeyStateIndicator) void {
        if (!self.visible or self.layout.hidden) return;
        self.frame = (self.frame + 1) % PERIOD_FRAMES;
        self.repaint();
    }

    fn phase(self: *const KeyStateIndicator) f32 {
        return @as(f32, @floatFromInt(self.frame)) /
            @as(f32, @floatFromInt(PERIOD_FRAMES));
    }

    /// A cheap fingerprint of everything that changes what the pill SAYS. The
    /// scale rides along because it decides the font the labels are measured
    /// with, and a re-measure at a new DPI has to happen even when the words
    /// did not change.
    fn signatureOf(model: *const key_state.Model, scale: f32) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&@as(u32, @bitCast(scale))));
        h.update(std.mem.asBytes(&model.depth));
        h.update(std.mem.asBytes(&model.key_count));
        for (0..model.visibleTables()) |i| {
            h.update(model.tableName(i));
            h.update("\x00");
        }
        for (0..model.visibleKeys()) |i| {
            h.update(model.keyLabel(i));
            h.update("\x00");
        }
        // A hash of zero would read as "never measured", and the cache's
        // sentinel has to stay distinguishable from a real value.
        return h.final() | 1;
    }

    /// Convert the model's labels to UTF-16 and measure them with GDI.
    fn measure(self: *KeyStateIndicator, model: *const key_state.Model) void {
        var out: Measured = .{};

        const n_tables = model.visibleTables();
        for (0..n_tables) |i| out.tables[i].set(model.tableName(i));
        out.table_count = n_tables;
        if (model.tablesOverflow() and n_tables < pill.MAX_ITEMS) {
            const t = &out.tables[n_tables];
            @memcpy(t.buf[0..OVERFLOW_MARK.len], OVERFLOW_MARK);
            t.len = OVERFLOW_MARK.len;
            out.table_count = n_tables + 1;
        }

        const n_keys = model.visibleKeys();
        for (0..n_keys) |i| out.keys[i].set(model.keyLabel(i));
        out.key_count = n_keys;

        measureLabels(self.font, &out);
        self.measured = out;
    }

    /// GDI extents for every label, in one device context. Zero everywhere
    /// when there is no font — the layout then draws bare boxes, which is a
    /// degenerate pill rather than a crash.
    fn measureLabels(font: ?*anyopaque, out: *Measured) void {
        const f = font orelse return;
        const dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, dc);
        const old = w32.SelectObject(dc, f) orelse return;
        defer _ = w32.SelectObject(dc, old);

        var size = w32.SIZE{ .cx = 0, .cy = 0 };
        // Height from a fixed sample, not from the labels: a run of key names
        // with no descenders would otherwise give a shorter line box than a
        // table name with one, and the two would not line up.
        const sample = std.unicode.utf8ToUtf16LeStringLiteral("Wgy");
        _ = w32.GetTextExtentPoint32W(dc, sample.ptr, @intCast(sample.len), &size);
        out.text_h = size.cy;

        for (0..out.table_count) |i| {
            const s = out.tables[i].slice();
            _ = w32.GetTextExtentPoint32W(dc, s.ptr, @intCast(s.len), &size);
            out.table_w[i] = size.cx;
        }
        for (0..out.key_count) |i| {
            const s = out.keys[i].slice();
            _ = w32.GetTextExtentPoint32W(dc, s.ptr, @intCast(s.len), &size);
            out.key_w[i] = size.cx;
        }
    }

    /// Render the pill into a DIB and blit it with per-pixel alpha.
    ///
    /// Order matters and is the whole trick: the pure renderer writes the card,
    /// the key caps, the divider and the dots in STRAIGHT color plus a
    /// separate coverage mask; GDI then draws the keyboard glyph, the chevrons
    /// and the labels straight into the same pixels (GDI text has no alpha —
    /// `DrawTextW` writes zero into the byte, which would punch the text back
    /// out of a layered window); and only then does one pass re-apply the mask
    /// and premultiply.
    fn repaint(self: *KeyStateIndicator) void {
        const rect = self.placed;
        const l = self.layout;
        const m = self.metrics;
        const pane_bg = self.pane_bg orelse return;
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (w <= 0 or h <= 0 or l.hidden) return;
        const n: usize = @intCast(w * h);
        if (!self.ensureSurfaces(n)) return;

        pill.render(self.bgr[0..n], self.mask[0..n], m, l, pane_bg, self.phase());

        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);
        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);

        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = w,
                // Negative for a top-down DIB, so row 0 is the top row and the
                // pure renderer's row order is the one that lands.
                .biHeight = -h,
            },
        };
        const bitmap = w32.CreateDIBSection(
            mem_dc,
            &bmi,
            w32.DIB_RGB_COLORS,
            &bits,
            null,
            0,
        ) orelse return;
        defer _ = w32.DeleteObject(bitmap);
        const old_bmp = w32.SelectObject(mem_dc, bitmap) orelse return;
        defer _ = w32.SelectObject(mem_dc, old_bmp);

        const px: [*]u32 = @ptrCast(@alignCast(bits.?));
        @memcpy(px[0..n], self.bgr[0..n]);

        self.drawText(mem_dc, m, l, pane_bg);

        // Re-apply the coverage mask and premultiply, now that every pixel GDI
        // was going to touch has been touched.
        for (px[0..n], self.mask[0..n]) |*p, a| {
            if (a == 0) {
                p.* = 0;
                continue;
            }
            const af: u32 = a;
            const r = (((p.* >> 16) & 0xFF) * af + 127) / 255;
            const g = (((p.* >> 8) & 0xFF) * af + 127) / 255;
            const b = ((p.* & 0xFF) * af + 127) / 255;
            p.* = (af << 24) | (r << 16) | (g << 8) | b;
        }

        const dst_pt = w32.POINT{ .x = rect.left, .y = rect.top };
        const dst_size = w32.SIZE{ .cx = w, .cy = h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 };
        _ = w32.UpdateLayeredWindow(
            self.hwnd,
            screen_dc,
            &dst_pt,
            &dst_size,
            mem_dc,
            &src_pt,
            0,
            &blend,
            w32.ULW_ALPHA,
        );
    }

    /// The glyph, the chevrons and every label, at their contrast floors.
    fn drawText(
        self: *KeyStateIndicator,
        dc: w32.HDC,
        m: pill.Metrics,
        l: pill.Layout,
        pane_bg: color_math.Rgb,
    ) void {
        const fill = pill.fillColor(pane_bg);
        const cap_fill = pill.capFillColor(fill);
        const chrome = pill.glyphColor(fill);
        const chrome_ref = w32.RGB(chrome.r, chrome.g, chrome.b);
        const name_rgb = pill.labelColor(fill);
        const cap_rgb = pill.labelColor(cap_fill);

        if (!l.glyph.isEmpty()) {
            _ = icon_paint.fontCodepoint(dc, m.scale, l.glyph, KEYBOARD, pill.GLYPH, chrome_ref);
        }

        const font = self.font orelse return;
        const old_font = w32.SelectObject(dc, font);
        defer if (old_font) |f| {
            _ = w32.SelectObject(dc, f);
        };
        const old_bk = w32.SetBkMode(dc, w32.TRANSPARENT);
        defer _ = w32.SetBkMode(dc, old_bk);
        const old_color = w32.SetTextColor(dc, chrome_ref);
        defer _ = w32.SetTextColor(dc, old_color);

        // Chevrons: the icon face when present, a ">" in the label font when
        // not — without it, nested names would run together.
        //
        // `1..count` is written as an explicit while on purpose: a for-range
        // is lowered to a counted loop over `end - start`, so `for (1..0)` —
        // which is exactly a pending sequence with no key table — underflows
        // and panics with "integer overflow".
        var ci: usize = 1;
        while (ci < l.table_count) : (ci += 1) {
            const i = ci;
            const box = l.chevrons[i];
            if (box.isEmpty()) continue;
            if (icon_paint.fontCodepoint(dc, m.scale, box, CHEVRON, pill.CHEVRON, chrome_ref)) continue;
            var r = toRect(box);
            _ = w32.DrawTextW(
                dc,
                CHEVRON_FALLBACK.ptr,
                @intCast(CHEVRON_FALLBACK.len),
                &r,
                w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        // Table names, left-aligned and tail-ellipsized: a narrow pane shrinks
        // these boxes, and an elided name still names the table.
        _ = w32.SetTextColor(dc, w32.RGB(name_rgb.r, name_rgb.g, name_rgb.b));
        for (0..l.table_count) |i| {
            const box = l.tables[i];
            if (box.isEmpty()) continue;
            const s = self.measured.tables[i].slice();
            if (s.len == 0) continue;
            var r = toRect(box);
            _ = w32.DrawTextW(
                dc,
                s.ptr,
                @intCast(s.len),
                &r,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE |
                    w32.DT_NOPREFIX | w32.DT_END_ELLIPSIS,
            );
        }

        // Key-cap labels, centered in their caps and measured against the CAP
        // fill rather than the card's — the cap is what they sit on.
        _ = w32.SetTextColor(dc, w32.RGB(cap_rgb.r, cap_rgb.g, cap_rgb.b));
        for (0..l.key_count) |i| {
            const box = l.caps[i];
            if (box.isEmpty()) continue;
            const s = self.measured.keys[i].slice();
            if (s.len == 0) continue;
            var r = toRect(box);
            _ = w32.DrawTextW(
                dc,
                s.ptr,
                @intCast(s.len),
                &r,
                w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }
    }

    fn ensureSurfaces(self: *KeyStateIndicator, n: usize) bool {
        if (self.bgr.len >= n and self.mask.len >= n) return true;
        if (self.bgr.len > 0) self.alloc.free(self.bgr);
        if (self.mask.len > 0) self.alloc.free(self.mask);
        self.bgr = self.alloc.alloc(u32, n) catch {
            self.bgr = &.{};
            self.mask = &.{};
            return false;
        };
        self.mask = self.alloc.alloc(u8, n) catch {
            self.alloc.free(self.bgr);
            self.bgr = &.{};
            self.mask = &.{};
            return false;
        };
        return true;
    }
};

fn toRect(r: pill.Rect) w32.RECT {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        // Click-through, so the cursor is whatever the pane underneath says.
        .hCursor = null,
        .hbrBackground = null, // painted via UpdateLayeredWindow
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*KeyStateIndicator = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        // Never take activation from the pane underneath.
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_TIMER => {
            if (wparam == TIMER_ID) {
                self.tick();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
