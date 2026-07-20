//! Sticky pane-banner overlay (T35). Windows analog of the Mac
//! `SurfacePaneBanner`: a strip rendered above the terminal content of a
//! pane that persists (survives scrolling, screen clears, content updates)
//! until changed or cleared.
//!
//! Like DimOverlay/Scrollbar, the strip is a WS_EX_LAYERED popup owned by
//! its surface HWND — DWM composites it above the surface's OpenGL
//! content, which a plain child window cannot reliably do. Unlike the dim
//! overlay it is NOT click-through: `[text](url)` links are clickable
//! (hand cursor + ShellExecuteW), and a click anywhere else focuses the
//! pane underneath. Text styling comes from the pure banner_markdown
//! parser (unit tested in every lane); this file only owns the windowing
//! and GDI painting.

const std = @import("std");
const w32 = @import("win32.zig");
const App = @import("App.zig");
const markdown = @import("banner_markdown.zig");
const color_math = @import("color_math.zig");

const log = std.log.scoped(.win32_banner);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyBannerOverlay");

/// Strip translucency (LWA_ALPHA): mostly opaque so text stays crisp, a
/// hint of the terminal beneath (Mac uses ultraThinMaterial).
const STRIP_ALPHA: u8 = 242;

/// Unscaled layout metrics (Mac: 10/5 padding, 12pt font, 6-line cap).
const PAD_H: f32 = 10.0;
const PAD_V: f32 = 5.0;
const FONT_H: f32 = 15.0;
const LINE_H: f32 = 20.0;

pub const BannerOverlay = struct {
    alloc: std.mem.Allocator,
    /// The surface HWND this banner sits on top of (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,
    /// Arena holding the parsed runs and their text (reset per setText).
    arena: std.heap.ArenaAllocator,
    runs: []const markdown.Run = &.{},
    line_count: usize = 1,

    scale: f32 = 1.0,
    bg: u32 = 0, // COLORREF strip fill
    fg: u32 = 0xFFFFFF,
    link_fg: u32 = 0xFF9C4F, // COLORREF is 0x00BBGGRR
    divider: u32 = 0,
    bg_brush: ?w32.HBRUSH = null,
    alpha_set: bool = false,

    /// Lazy font cache indexed by style bits (bold|italic<<1|ul<<2|code<<3).
    fonts: [16]?*anyopaque = @splat(null),

    /// Link hit rects, rebuilt on every paint (client coordinates).
    links: std.ArrayList(LinkRect) = .empty,

    const LinkRect = struct {
        rect: w32.RECT,
        /// Arena-owned (lives until the next setText).
        url: []const u8,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*BannerOverlay {
        try registerClassOnce(hinstance);

        const self = try alloc.create(BannerOverlay);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .owner = owner,
            .hwnd = undefined,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL content.
        // WS_EX_NOACTIVATE — clicks never move activation to the popup.
        // WS_EX_TOOLWINDOW — out of the taskbar / Alt-Tab list.
        // Deliberately not WS_EX_TRANSPARENT: links are clickable.
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
            1, // placeholder — updatePosition glues to the owner
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;

        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *BannerOverlay) void {
        _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(self.hwnd);
        for (self.fonts) |f| if (f) |font| {
            _ = w32.DeleteObject(font);
        };
        if (self.bg_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.links.deinit(self.alloc);
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    /// Replace the banner source text (raw markdown) and repaint. The
    /// caller keeps ownership of `text`; empty text is the caller's cue to
    /// destroy/hide instead — here it just paints an empty strip.
    pub fn setText(self: *BannerOverlay, text: []const u8) void {
        _ = self.arena.reset(.retain_capacity);
        self.links.clearRetainingCapacity();
        self.runs = markdown.parse(self.arena.allocator(), text) catch &.{};
        self.line_count = @min(markdown.lineCount(self.runs), markdown.max_lines);
        _ = w32.InvalidateRect(self.hwnd, null, 1);
    }

    /// Refresh strip colors from the pane's effective background (per-pane
    /// tint or config background) and the config foreground.
    pub fn setColors(self: *BannerOverlay, pane_bg: color_math.Rgb, fg: color_math.Rgb) void {
        const light = color_math.isLight(pane_bg);
        const strip = if (light)
            color_math.darken(pane_bg, 0.07)
        else
            color_math.lighten(pane_bg, 0.09);
        const div = if (light)
            color_math.darken(pane_bg, 0.25)
        else
            color_math.lighten(pane_bg, 0.25);
        const bg_ref = w32.RGB(strip.r, strip.g, strip.b);
        const fg_ref = w32.RGB(fg.r, fg.g, fg.b);
        const link_ref: u32 = if (light) w32.RGB(0, 102, 204) else w32.RGB(90, 160, 255);
        const div_ref = w32.RGB(div.r, div.g, div.b);
        if (bg_ref == self.bg and fg_ref == self.fg and
            link_ref == self.link_fg and div_ref == self.divider and
            self.bg_brush != null) return;
        self.bg = bg_ref;
        self.fg = fg_ref;
        self.link_fg = link_ref;
        self.divider = div_ref;
        if (self.bg_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.bg_brush = w32.CreateSolidBrush(bg_ref);
        _ = w32.InvalidateRect(self.hwnd, null, 1);
    }

    /// Glue the strip to the top of the owner pane (screen coordinates).
    /// Hides when the owner is not visible (hidden split, other tab, hero
    /// carousel). Idempotent — doubles as the reposition call.
    pub fn updatePosition(self: *BannerOverlay, scale: f32) void {
        if (w32.IsWindowVisible_(self.owner) == 0) {
            self.hide();
            return;
        }
        if (scale != self.scale) {
            self.scale = scale;
            self.clearFonts();
            _ = w32.InvalidateRect(self.hwnd, null, 1);
        }
        if (!self.alpha_set) {
            _ = w32.SetLayeredWindowAttributes(self.hwnd, 0, STRIP_ALPHA, w32.LWA_ALPHA);
            self.alpha_set = true;
        }
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &rect) == 0) return;
        const height = self.stripHeight();
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            rect.left,
            rect.top,
            @max(rect.right - rect.left, 1),
            height,
            w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
        );
    }

    pub fn hide(self: *BannerOverlay) void {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
    }

    fn stripHeight(self: *const BannerOverlay) i32 {
        const lines: f32 = @floatFromInt(self.line_count);
        return px(PAD_V * 2 + LINE_H * lines, self.scale) + 1; // +1 divider
    }

    fn px(v: f32, scale: f32) i32 {
        return @intFromFloat(@round(v * scale));
    }

    fn clearFonts(self: *BannerOverlay) void {
        for (&self.fonts) |*f| {
            if (f.*) |font| _ = w32.DeleteObject(font);
            f.* = null;
        }
    }

    fn fontFor(self: *BannerOverlay, style: markdown.Style) ?*anyopaque {
        const idx: usize = @as(usize, @intFromBool(style.bold)) |
            (@as(usize, @intFromBool(style.italic)) << 1) |
            (@as(usize, @intFromBool(style.underline)) << 2) |
            (@as(usize, @intFromBool(style.code)) << 3);
        if (self.fonts[idx]) |f| return f;
        const face = if (style.code)
            std.unicode.utf8ToUtf16LeStringLiteral("Consolas")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
        self.fonts[idx] = w32.CreateFontW(
            -px(FONT_H, self.scale),
            0,
            0,
            0,
            if (style.bold) 700 else 400,
            @intFromBool(style.italic),
            @intFromBool(style.underline),
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

    /// Paint the strip: background, styled runs line by line, bottom
    /// divider. Rebuilds the link hit rects as a side effect.
    fn paint(self: *BannerOverlay, hdc: w32.HDC) void {
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &client) == 0) return;

        if (self.bg_brush) |brush| _ = w32.FillRect(hdc, &client, brush);

        self.links.clearRetainingCapacity();
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

        const pad_h = px(PAD_H, self.scale);
        const pad_v = px(PAD_V, self.scale);
        const line_h = px(LINE_H, self.scale);

        var line: usize = 0;
        var run_idx: usize = 0;
        while (line < self.line_count) : (line += 1) {
            var x: i32 = pad_h;
            const y: i32 = pad_v + line_h * @as(i32, @intCast(line));
            while (run_idx < self.runs.len and self.runs[run_idx].line == line) : (run_idx += 1) {
                const run = self.runs[run_idx];
                if (run.text.len == 0) continue;
                if (x >= client.right) continue; // clipped; keep consuming runs

                var wbuf: [1024]u16 = undefined;
                const wlen = std.unicode.utf8ToUtf16Le(&wbuf, run.text) catch continue;
                if (wlen == 0) continue;

                const font = self.fontFor(run.style);
                const prev = w32.SelectObject(hdc, font);
                defer _ = w32.SelectObject(hdc, prev);

                _ = w32.SetTextColor(hdc, if (run.link != null) self.link_fg else self.fg);
                _ = w32.TextOutW(hdc, x, y, &wbuf, @intCast(wlen));

                var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
                _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);

                if (run.link) |url| {
                    self.links.append(self.alloc, .{
                        .rect = .{
                            .left = x,
                            .top = y,
                            .right = x + size.cx,
                            .bottom = y + line_h,
                        },
                        .url = url,
                    }) catch {};
                }
                x += size.cx;
            }
            // Drop any runs the line cap cut off.
            while (run_idx < self.runs.len and self.runs[run_idx].line < line + 1) run_idx += 1;
        }

        // Bottom divider (Mac: Divider under the strip).
        const pen = w32.CreatePen(0, 1, self.divider); // PS_SOLID
        if (pen) |p| {
            const prev_pen = w32.SelectObject(hdc, p);
            _ = w32.MoveToEx(hdc, client.left, client.bottom - 1, null);
            _ = w32.LineTo(hdc, client.right, client.bottom - 1);
            _ = w32.SelectObject(hdc, prev_pen);
            _ = w32.DeleteObject(p);
        }
    }

    fn linkAt(self: *const BannerOverlay, x: i32, y: i32) ?[]const u8 {
        for (self.links.items) |l| {
            if (x >= l.rect.left and x < l.rect.right and
                y >= l.rect.top and y < l.rect.bottom) return l.url;
        }
        return null;
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = bannerWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // painted in WM_PAINT with the cached brush
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn bannerWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*BannerOverlay = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_ERASEBKGND => return 1, // WM_PAINT covers everything

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.paint(hdc);
            return 0;
        },

        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                _ = w32.ScreenToClient(hwnd, &pt);
                const cursor = if (self.linkAt(pt.x, pt.y) != null)
                    w32.LoadCursorW(null, w32.IDC_HAND)
                else
                    w32.LoadCursorW(null, w32.IDC_ARROW);
                _ = w32.SetCursor(cursor);
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_LBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
            if (self.linkAt(x, y)) |url| {
                var wurl: [2048:0]u16 = undefined;
                const wlen = std.unicode.utf8ToUtf16Le(&wurl, url) catch return 0;
                if (wlen < wurl.len) {
                    wurl[wlen] = 0;
                    _ = w32.ShellExecuteW(
                        null,
                        std.unicode.utf8ToUtf16LeStringLiteral("open"),
                        @ptrCast(&wurl),
                        null,
                        null,
                        w32.SW_SHOW,
                    );
                }
            } else {
                // A click on the strip focuses the pane underneath, like a
                // click on the pane itself (T48: never SetFocus in a WndProc).
                App.deferSetFocus(self.owner);
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
