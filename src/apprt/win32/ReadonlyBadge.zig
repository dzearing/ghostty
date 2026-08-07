//! The READ-ONLY pane badge (T445): a small card in a pane's top-right
//! corner that appears while the pane is read-only, and goes away when it is
//! not. The Windows port of Mac's `Ghostty.SurfaceView.ReadonlyBadge`.
//!
//! Read-only silently drops every keystroke, so an unmarked read-only pane
//! and a wedged pane look exactly alike. On win32 the `.readonly` apprt
//! action was an acknowledged no-op, which left the context menu's checkmark
//! as the only way to tell them apart — a menu you have to already suspect
//! the answer to open.
//!
//! Like DimOverlay/BannerOverlay/Scrollbar it is a `WS_EX_LAYERED` popup
//! owned by its surface HWND, which is what puts it above the pane's OpenGL
//! content. Two differences from the banner, both forced by where it sits:
//!
//! - It uses the SCROLLBAR's `UpdateLayeredWindow` per-pixel-alpha path, not
//!   the banner's `LWA_ALPHA` + opaque paint. The banner owns a reserved
//!   band whose backdrop it knows; the badge floats over live terminal
//!   content, so anything outside its rounded card — the drop shade, the
//!   antialiased edge — has to be genuinely translucent instead of painting
//!   a rectangle of pane background over whatever was there.
//! - It is NOT `WS_EX_TRANSPARENT`: clicking the badge leaves read-only,
//!   which is the way back out of the mode that the mark itself provides.
//!
//! Geometry, colors and the card's pixels are in `readonly_badge.zig` (no OS
//! imports, asserted at 1.0/1.25/1.5/2.0 in every lane). This file owns the
//! window, the GDI text, and the click.

const std = @import("std");
const w32 = @import("win32.zig");
const badge = @import("readonly_badge.zig");
const icon_paint = @import("icon_button_paint.zig");
const icon_button = @import("icon_button.zig");
const color_math = @import("color_math.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_readonly_badge);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyReadonlyBadge");

/// Fluent/MDL2 `RedEye` — the same eye Mac's `eye.fill` stands for. There is
/// no drawn fallback: a lens-and-pupil is not expressible in the quad
/// vocabulary `icon_button` uses, and the label carries the meaning anyway,
/// so a machine with neither icon face gets the card and the words.
const EYE: u16 = 0xE7B3;

const LABEL = std.unicode.utf8ToUtf16LeStringLiteral("Read-only");

const ui_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");

pub const ReadonlyBadge = struct {
    alloc: std.mem.Allocator,
    /// The pane this badge belongs to; supplies the click's target. The
    /// Surface owns the badge and destroys it in its own deinit, so the
    /// pointer cannot outlive the pane. Optional so the class-behavior tests
    /// can drive a bare badge over a plain owner window.
    surface: ?*Surface,
    /// The surface HWND this badge sits on top of (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// Cached label font, rebuilt when the DPI scale changes.
    font: ?*anyopaque = null,
    scale: f32 = 0,
    /// Last painted pane background, so an unchanged pane repaints nothing.
    pane_bg: ?color_math.Rgb = null,
    /// Last placed window rect (screen), same reason.
    placed: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    visible: bool = false,

    /// Scratch surfaces for the layered paint, grown on demand.
    bgr: []u32 = &.{},
    mask: []u8 = &.{},

    pub fn create(
        alloc: std.mem.Allocator,
        surface: ?*Surface,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*ReadonlyBadge {
        try registerClassOnce(hinstance);

        const self = try alloc.create(ReadonlyBadge);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .surface = surface,
            .owner = owner,
            .hwnd = undefined,
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL content, per-pixel alpha.
        // WS_EX_NOACTIVATE — a click never moves activation to the popup.
        // WS_EX_TOOLWINDOW — out of the taskbar / Alt-Tab list.
        // Deliberately not WS_EX_TRANSPARENT: the badge is clickable.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE |
            w32.WS_EX_TOOLWINDOW;

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

    pub fn destroy(self: *ReadonlyBadge) void {
        _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(self.hwnd);
        if (self.font) |f| _ = w32.DeleteObject(f);
        if (self.bgr.len > 0) self.alloc.free(self.bgr);
        if (self.mask.len > 0) self.alloc.free(self.mask);
        self.alloc.destroy(self);
    }

    /// Place and paint the badge over its owner pane. Idempotent — this IS
    /// the reposition call, and it runs on every layout/focus/tab-switch
    /// pass, so it must stay cheap when nothing moved.
    pub fn update(self: *ReadonlyBadge, scale: f32, pane_bg: color_math.Rgb) void {
        if (w32.IsWindowVisible_(self.owner) == 0) {
            self.hide();
            return;
        }

        var owner_rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &owner_rect) == 0) return;
        const pane_w = owner_rect.right - owner_rect.left;
        const pane_h = owner_rect.bottom - owner_rect.top;

        const m = badge.Metrics.init(scale);
        if (scale != self.scale) {
            self.scale = scale;
            if (self.font) |f| _ = w32.DeleteObject(f);
            self.font = w32.CreateFontW(
                -m.font_px,
                0,
                0,
                0,
                600, // medium — Mac's badge label is `.medium`
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
            // Force a repaint: the cached placement was measured with the
            // old font.
            self.placed = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        }

        const text = self.measureLabel();
        const l = badge.layout(m, pane_w, pane_h, text.cx, text.cy);
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
        self.pane_bg = pane_bg;
        self.placed = rect;

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

        if (moved or bg_changed) self.repaint(m, l, pane_bg, rect);

        // Every reposition re-checks the z-order rather than leaving it to
        // whatever last touched it (T142, `overlay_zorder.zig`).
        w32.healOverlayZOrder(self.hwnd, self.owner);
    }

    pub fn hide(self: *ReadonlyBadge) void {
        if (!self.visible) return;
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.visible = false;
    }

    /// GDI extent of the label at the current font. Zero when there is no
    /// font (the card then shrinks to its glyph, per `cardSize`).
    fn measureLabel(self: *ReadonlyBadge) w32.SIZE {
        var size = w32.SIZE{ .cx = 0, .cy = 0 };
        const font = self.font orelse return size;
        const dc = w32.GetDC(null) orelse return size;
        defer _ = w32.ReleaseDC(null, dc);
        const old = w32.SelectObject(dc, font) orelse return size;
        defer _ = w32.SelectObject(dc, old);
        _ = w32.GetTextExtentPoint32W(dc, LABEL.ptr, @intCast(LABEL.len), &size);
        return size;
    }

    /// Render the card into a DIB and blit it with per-pixel alpha.
    ///
    /// Order matters and is the whole trick: the pure renderer writes the
    /// card in STRAIGHT color plus a separate coverage mask, GDI then draws
    /// the eye and the label straight into the same pixels (GDI text has no
    /// alpha — `DrawTextW` writes zero into the byte, which would punch the
    /// text back out of a layered window), and only then does one pass
    /// re-apply the mask and premultiply. Trying to protect an alpha channel
    /// from `DrawTextW` is the version of this that does not work.
    fn repaint(
        self: *ReadonlyBadge,
        m: badge.Metrics,
        l: badge.Layout,
        pane_bg: color_math.Rgb,
        rect: w32.RECT,
    ) void {
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (w <= 0 or h <= 0) return;
        const n: usize = @intCast(w * h);
        if (!self.ensureSurfaces(n)) return;

        badge.render(self.bgr[0..n], self.mask[0..n], m, l, pane_bg);

        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);
        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);

        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = w,
                // Negative for a top-down DIB, so row 0 is the top row and
                // the pure renderer's row order is the one that lands.
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

        // The glyph and the label, in the accent at its floors.
        const fill = badge.fillColor(pane_bg);
        const label_rgb = badge.labelColor(fill);
        const text_color = w32.RGB(label_rgb.r, label_rgb.g, label_rgb.b);

        _ = icon_paint.fontCodepoint(
            mem_dc,
            m.scale,
            .{
                .left = l.glyph.left,
                .top = l.glyph.top,
                .right = l.glyph.right,
                .bottom = l.glyph.bottom,
            },
            EYE,
            badge.GLYPH,
            text_color,
        );

        if (self.font) |font| {
            const old_font = w32.SelectObject(mem_dc, font);
            defer if (old_font) |f| {
                _ = w32.SelectObject(mem_dc, f);
            };
            const old_bk = w32.SetBkMode(mem_dc, w32.TRANSPARENT);
            defer _ = w32.SetBkMode(mem_dc, old_bk);
            const old_color = w32.SetTextColor(mem_dc, text_color);
            defer _ = w32.SetTextColor(mem_dc, old_color);
            var tr = w32.RECT{
                .left = l.text.left,
                .top = l.text.top,
                .right = l.text.right,
                .bottom = l.text.bottom,
            };
            _ = w32.DrawTextW(
                mem_dc,
                LABEL.ptr,
                @intCast(LABEL.len),
                &tr,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE |
                    w32.DT_NOPREFIX | w32.DT_END_ELLIPSIS,
            );
        }

        // Re-apply the coverage mask and premultiply, now that every pixel
        // GDI was going to touch has been touched.
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

    fn ensureSurfaces(self: *ReadonlyBadge, n: usize) bool {
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

    /// A click on the badge leaves read-only — the mark IS the way out.
    /// Mac opens a popover with a single "Disable" button; a chip this small
    /// with one possible action does not need the extra step.
    fn click(self: *ReadonlyBadge) void {
        const surface = self.surface orelse return;
        _ = surface.core_surface.performBindingAction(.toggle_readonly) catch |err| {
            log.err("read-only badge toggle failed err={}", .{err});
        };
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = badgeWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        // The badge is one big click target, so the hand is set for the
        // whole window rather than per-region in WM_SETCURSOR.
        .hCursor = w32.LoadCursorW(null, w32.IDC_HAND),
        .hbrBackground = null, // painted via UpdateLayeredWindow
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn badgeWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*ReadonlyBadge = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        // Never take activation from the pane underneath — but DO deliver
        // the click, which MA_NOACTIVATE (rather than MA_NOACTIVATEANDEAT)
        // is what buys.
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_LBUTTONUP => {
            self.click();
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
