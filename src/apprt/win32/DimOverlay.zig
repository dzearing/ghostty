//! Unfocused-split dim overlay (T74). Implements the Mac/GTK
//! `unfocused-split-opacity` / `unfocused-split-fill` behavior: unfocused
//! panes of a split get a uniform semi-transparent rectangle over them so
//! the focused pane stands out.
//!
//! Like Scrollbar.zig, each overlay is a WS_EX_LAYERED popup owned by its
//! surface HWND — DWM composites it above the surface's OpenGL content,
//! which a plain child window cannot reliably do. WS_EX_TRANSPARENT makes
//! it click-through: a click on a dimmed pane lands on the pane itself,
//! which focuses it (and Window.updateDimOverlays then hides the overlay).
//! Uniform dimming needs no per-pixel alpha, so this uses the simpler
//! SetLayeredWindowAttributes(LWA_ALPHA) + solid-brush paint instead of
//! the scrollbar's UpdateLayeredWindow DIB path. Pure decision/alpha
//! logic is in dim_math.zig (unit tested in every lane).

const std = @import("std");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_dim_overlay);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyDimOverlay");

pub const DimOverlay = struct {
    alloc: std.mem.Allocator,
    /// The surface HWND this overlay covers (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// Cached fill brush + its COLORREF, recreated when the config color
    /// changes. The WndProc paints with it.
    brush: ?w32.HBRUSH = null,
    color: u32 = 0,
    /// Last alpha applied via SetLayeredWindowAttributes. 0 = never
    /// applied (show() never runs with alpha 0 — shouldDim requires > 0),
    /// so the first show() always sets the layered attributes.
    alpha: u8 = 0,

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*DimOverlay {
        try registerClassOnce(hinstance);

        const self = try alloc.create(DimOverlay);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .owner = owner,
            .hwnd = undefined,
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL, uniform alpha.
        // WS_EX_TRANSPARENT — click-through to the pane underneath.
        // WS_EX_NOACTIVATE — never steals focus.
        // WS_EX_TOOLWINDOW — out of the taskbar / Alt-Tab list.
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
            1, // placeholder rect — show() glues to the owner
            owner, // owner (popup, not parent)
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;

        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *DimOverlay) void {
        _ = w32.DestroyWindow(self.hwnd);
        if (self.brush) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.alloc.destroy(self);
    }

    /// Show the overlay glued over the owner surface at the given fill
    /// color (COLORREF) and alpha. Idempotent — also serves as the
    /// reposition call when the window moves or the layout changes.
    pub fn show(self: *DimOverlay, color: u32, alpha: u8) void {
        if (self.brush == null or color != self.color) {
            if (self.brush) |b| _ = w32.DeleteObject(@ptrCast(b));
            self.brush = w32.CreateSolidBrush(color);
            self.color = color;
            _ = w32.InvalidateRect(self.hwnd, null, 1);
        }
        if (alpha != self.alpha) {
            _ = w32.SetLayeredWindowAttributes(self.hwnd, 0, alpha, w32.LWA_ALPHA);
            self.alpha = alpha;
        }

        // GetWindowRect on the (child) surface HWND is already in screen
        // coordinates, which is what a popup's SetWindowPos takes.
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &rect) == 0) return;
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            rect.left,
            rect.top,
            @max(rect.right - rect.left, 1),
            @max(rect.bottom - rect.top, 1),
            w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
        );
        // Every reposition re-checks the z-order instead of leaving it to
        // whatever last touched it (T142).
        w32.healOverlayZOrder(self.hwnd, self.owner);
    }

    pub fn hide(self: *DimOverlay) void {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = dimWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // painted in WM_ERASEBKGND with the cached brush
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn dimWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*DimOverlay = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_ERASEBKGND => {
            const brush = self.brush orelse return 0;
            if (wparam == 0) return 0;
            const hdc: w32.HDC = @ptrFromInt(wparam);
            var rect: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &rect) != 0) {
                _ = w32.FillRect(hdc, &rect, brush);
            }
            return 1;
        },

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            if (self.brush) |brush| {
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc, &rect, brush);
                }
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
