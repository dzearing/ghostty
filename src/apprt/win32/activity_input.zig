//! Activity monitor input: the mouse, and the keyboard focus ring.
//!
//! Split out of `ActivityMonitor.zig` (T299). Everything here turns a raw
//! win32 input message into an intent on the panel's view state — which row
//! is selected, which card is showing, where the table is scrolled, which
//! control has focus — and then asks for a repaint. Nothing here owns a
//! connection or frees anything, which is exactly why it can live away from
//! the connection plane.
//!
//! The focus ring (T289) is the fiddly half. Windows gives real HWND focus to
//! the filter EDIT and the three buttons, and there is no HWND for the table
//! or the carousel, so the panel keeps its own `focus` cursor and syncs it to
//! the real focus in `syncFocus`. `nextFocus`/`nextVisibleFocus` are pure and
//! unit-tested; the rest is the plumbing that keeps the two in step.

const std = @import("std");

const ActivityMonitor = @import("ActivityMonitor.zig");
const Scrollbar = @import("Scrollbar.zig");
const cards_mod = @import("activity_cards.zig");
const icon_button = @import("icon_button.zig");
const layout_mod = @import("activity_layout.zig");
const rows_mod = @import("activity_rows.zig");
const utf16_text = @import("utf16_text.zig");
const w32 = @import("win32.zig");

const log = ActivityMonitor.log;
const filter_wide_cap = ActivityMonitor.filter_wide_cap;
const columnAt = ActivityMonitor.columnAt;
const columnSortKey = ActivityMonitor.columnSortKey;
const sortKeyColumn = ActivityMonitor.sortKeyColumn;
const thumbMin = ActivityMonitor.thumbMin;
const thumbWidth = ActivityMonitor.thumbWidth;

// ---------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------

pub fn onLeftDown(self: *ActivityMonitor, x: i32, y: i32, mods: usize) void {
    const l = self.layout();
    const widths = layout_mod.columnWidths(self.scale, l.table.width());

    // The carousel owns the top band. A click inside it switches source in ONE
    // click (Mac's card `onSelect`, :828-831); a click in the band's padding
    // just moves nothing, and never falls through to the table below.
    if (cards_mod.hasCarousel(self.card_count) and y < l.carousel.bottom) {
        // The band owns the click whether or not it landed on a card, so it
        // owns the focus too — the arrow keys must not be handed to the table
        // by a click in the carousel's padding.
        noteFocus(self, .carousel);
        if (layout_mod.cardIndexAt(
            l,
            @intCast(self.card_count),
            x,
            y,
            self.carousel_scroll,
            self.scale,
        )) |idx| {
            self.card_focus = idx;
            self.switchToCard(idx);
            _ = w32.InvalidateRect(self.hwnd, null, 0);
        }
        return;
    }

    // The banner owns the bottom band while it is up; its ✕ dismisses it and
    // the rest of the band swallows the click (it is not table).
    if (self.err_len > 0 and y >= l.banner.top) {
        const m = icon_button.Metrics.init(self.scale);
        const hit = icon_button.hitBox(m, icon_button.targetBox(m, .{
            .left = l.banner_close.left,
            .top = l.banner_close.top,
            .right = l.banner_close.right,
            .bottom = l.banner_close.bottom,
        }));
        if (x >= hit.left and x < hit.right and y >= hit.top and y < hit.bottom) {
            self.clearError();
        }
        return;
    }

    // Header click: sort.
    if (y >= l.table_header.top and y < l.table_header.bottom) {
        if (columnAt(l.table, widths, x)) |col| {
            self.sort = rows_mod.toggleSort(self.sort, columnSortKey(col));
            self.rebuild();
            _ = w32.InvalidateRect(self.hwnd, null, 0);
        }
        return;
    }

    // Scroll thumb.
    const visible = layout_mod.visibleRows(l);
    if (visible > 0 and self.order_len > @as(usize, @intCast(visible))) {
        const tw = thumbWidth(self.scale);
        if (x >= l.table_rows.right - tw and x < l.table_rows.right and
            y >= l.table_rows.top and y < l.table_rows.bottom)
        {
            const t = Scrollbar.thumbRect(
                self.order_len,
                @intCast(self.scroll),
                @intCast(visible),
                l.table_rows.height(),
                thumbMin(self.scale),
            );
            const local_y = y - l.table_rows.top;
            self.thumb_drag_dy = if (local_y >= t.y and local_y < t.y + t.h) local_y - t.y else @divTrunc(t.h, 2);
            _ = w32.SetCapture(self.hwnd);
            onThumbDrag(self, y);
            return;
        }
    }

    // Row click: plain replaces the selection, Ctrl toggles, Shift extends from
    // the last selected row (the standard Windows list idiom, and Mac's Table
    // does the same with Cmd/Shift).
    const idx = layout_mod.rowIndexAt(l, y, self.scroll) orelse return;
    const pid = self.pidAt(idx) orelse {
        self.clearSelection();
        self.caret_pid = 0;
        self.refreshChrome();
        return;
    };
    // A click puts the caret where it landed, whichever selection gesture it
    // was — the ring and the next arrow key both follow the mouse.
    self.caret_pid = pid;
    if (mods & w32.MK_CONTROL != 0) {
        self.toggleSelection(pid);
    } else if (mods & w32.MK_SHIFT != 0 and self.sel_len > 0) {
        extendSelectionTo(self, idx);
    } else {
        self.selectOnly(pid);
    }
    self.refreshChrome();
}

/// Shift-click: select every display row between the anchor (the last row added
/// to the selection) and `idx`.
pub fn extendSelectionTo(self: *ActivityMonitor, idx: i32) void {
    const anchor_pid = self.sel_pids[self.sel_len - 1];
    var anchor: i32 = -1;
    var i: usize = 0;
    while (i < self.order_len) : (i += 1) {
        if (self.pidAt(@intCast(i)) == anchor_pid) {
            anchor = @intCast(i);
            break;
        }
    }
    if (anchor < 0) {
        if (self.pidAt(idx)) |p| self.selectOnly(p);
        return;
    }
    const lo = @min(anchor, idx);
    const hi = @max(anchor, idx);
    self.sel_len = 0;
    var j = lo;
    while (j <= hi) : (j += 1) {
        if (self.pidAt(j)) |p| {
            if (self.sel_len == self.sel_pids.len) break;
            self.sel_pids[self.sel_len] = p;
            self.sel_len += 1;
        }
    }
}

pub fn onThumbDrag(self: *ActivityMonitor, y: i32) void {
    const l = self.layout();
    const visible = layout_mod.visibleRows(l);
    if (visible <= 0) return;
    const t = Scrollbar.thumbRect(
        self.order_len,
        @intCast(self.scroll),
        @intCast(visible),
        l.table_rows.height(),
        thumbMin(self.scale),
    );
    const off = Scrollbar.dragOffset(
        y - l.table_rows.top,
        self.thumb_drag_dy,
        l.table_rows.height(),
        t.h,
        self.order_len,
        @intCast(visible),
    ) orelse return;
    self.scroll = @intCast(off);
    self.clampScroll();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

pub fn onMouseMove(self: *ActivityMonitor, x: i32, y: i32) void {
    if (self.thumb_drag_dy >= 0) {
        onThumbDrag(self, y);
        return;
    }
    if (!self.tracking_leave) {
        var tme: w32.TRACKMOUSEEVENT = .{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd,
            .dwHoverTime = 0,
        };
        if (w32.TrackMouseEvent(&tme) != 0) self.tracking_leave = true;
    }

    const l = self.layout();

    const card: i32 = if (cards_mod.hasCarousel(self.card_count))
        (layout_mod.cardIndexAt(
            l,
            @intCast(self.card_count),
            x,
            y,
            self.carousel_scroll,
            self.scale,
        ) orelse -1)
    else
        -1;

    const in_table = x >= l.table.left and x < l.table.right;
    const hovered: i32 = if (in_table)
        (layout_mod.rowIndexAt(l, y, self.scroll) orelse -1)
    else
        -1;
    const clamped: i32 = if (hovered >= 0 and @as(usize, @intCast(hovered)) < self.order_len) hovered else -1;
    if (clamped == self.hover_row and card == self.card_hover) return;
    self.hover_row = clamped;
    self.card_hover = card;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// `screen_y` is in SCREEN coordinates — WM_MOUSEWHEEL is the one pointer
/// message that does not carry client coordinates, and reading its lParam as
/// client would scroll the carousel from the middle of the table.
pub fn onWheel(self: *ActivityMonitor, delta: i16, screen_x: i32, screen_y: i32) void {
    const notches: i32 = @divTrunc(@as(i32, delta), @as(i32, w32.WHEEL_DELTA));

    if (cards_mod.hasCarousel(self.card_count)) {
        var pt: w32.POINT = .{ .x = screen_x, .y = screen_y };
        if (w32.ScreenToClient(self.hwnd, &pt) != 0) {
            const l = self.layout();
            if (pt.y >= l.carousel.top and pt.y < l.carousel.bottom) {
                // One notch moves one card, so the wheel and the arrow keys
                // agree about what a step is.
                const step = layout_mod.cardRect(l, 1, 0, self.scale).left -
                    layout_mod.cardRect(l, 0, 0, self.scale).left;
                self.carousel_scroll -= notches * step;
                self.clampCarousel();
                _ = w32.InvalidateRect(self.hwnd, null, 0);
                return;
            }
        }
    }

    self.scroll -= notches * 3;
    self.clampScroll();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

// ---------------------------------------------------------------------
// Keyboard focus (T289)
// ---------------------------------------------------------------------

/// Keyboard focus stops, in Tab order — top to bottom down the panel, then
/// left to right along the control bar, so Tab walks the panel the way the eye
/// reads it. `carousel` and `table` are owner-drawn REGIONS of the panel's own
/// window rather than child controls; everything else is a native control that
/// draws the theme's own ring.
pub const Focusable = enum { carousel, filter, show_all, kill, new_proc, table };

pub const focus_count = @typeInfo(Focusable).@"enum".fields.len;

/// Pure Tab-order cycle. Unit-tested.
pub fn nextFocus(cur: Focusable, backwards: bool) Focusable {
    return if (backwards) switch (cur) {
        .carousel => .table,
        .filter => .carousel,
        .show_all => .filter,
        .kill => .show_all,
        .new_proc => .kill,
        .table => .new_proc,
    } else switch (cur) {
        .carousel => .filter,
        .filter => .show_all,
        .show_all => .kill,
        .kill => .new_proc,
        .new_proc => .table,
        .table => .carousel,
    };
}

/// The Tab step that lands on a stop the user can actually see, `visible`
/// indexed by `@intFromEnum`. The carousel is absent with a single source and
/// Kill only exists while rows are selected, so Tab has to step OVER them
/// rather than park focus on something that is not on screen. Bounded by the
/// cycle length; `filter` and `table` are always visible, so the fallback of
/// staying put is unreachable in the running panel. Pure — unit-tested.
pub fn nextVisibleFocus(cur: Focusable, backwards: bool, visible: [focus_count]bool) Focusable {
    var from = cur;
    for (0..focus_count) |_| {
        const next = nextFocus(from, backwards);
        if (visible[@intFromEnum(next)]) return next;
        from = next;
    }
    return cur;
}

/// Which stops exist right now.
pub fn focusVisibility(self: *const ActivityMonitor) [focus_count]bool {
    var v: [focus_count]bool = @splat(true);
    v[@intFromEnum(Focusable.carousel)] = cards_mod.hasCarousel(self.card_count);
    v[@intFromEnum(Focusable.kill)] = self.sel_len > 0;
    return v;
}

/// The window behind a focus stop. Both owner-drawn regions live on the
/// panel's own window, which is why `focus` and not `GetFocus` is what tells
/// them apart.
pub fn focusHwnd(self: *const ActivityMonitor, f: Focusable) w32.HWND {
    return switch (f) {
        .carousel, .table => self.hwnd,
        .filter => self.filter,
        .show_all => self.show_all_btn,
        .kill => self.kill_btn,
        .new_proc => self.new_proc_btn,
    };
}

/// Adopt a focus change the mouse made behind our back. A click on a native
/// child moves Win32 focus without routing through `moveFocus`, and a key
/// handler that trusted a stale `focus` would send Down to the table while the
/// caret sat in the filter. `GetFocus` naming the panel itself leaves the field
/// alone on purpose: it cannot tell the carousel from the table, and the click
/// handler already recorded which one was hit.
pub fn syncFocus(self: *ActivityMonitor) void {
    const f = w32.GetFocus() orelse return;
    const stop: Focusable = if (f == @as(?w32.HWND, self.filter))
        .filter
    else if (f == @as(?w32.HWND, self.show_all_btn))
        .show_all
    else if (f == @as(?w32.HWND, self.kill_btn))
        .kill
    else if (f == @as(?w32.HWND, self.new_proc_btn))
        .new_proc
    else
        return;
    // Only when it actually moved: this runs on every keystroke, and a line
    // per key would drown the log it exists to make readable.
    if (stop != self.focus) noteFocus(self, stop);
}

/// Record the focus stop, and say so.
///
/// Logged because the stop is otherwise unobservable from outside the process
/// (T300): `carousel` and `table` are both owner-drawn regions of the panel's
/// own window, so `GetFocus` answers `self.hwnd` for either and cannot say
/// which one has the keys. Without this line an acceptance script can only
/// infer the stop from a side effect — and "Tab reached the carousel" is
/// exactly the claim with no side effect until a second keystroke lands.
///
/// The mouse paths use this directly: a click has already put Win32 focus on
/// the panel, and only the click knows which of the two regions it landed in.
pub fn noteFocus(self: *ActivityMonitor, f: Focusable) void {
    log.info("activity monitor: focus {s} -> {s}", .{ @tagName(self.focus), @tagName(f) });
    self.focus = f;
    // The header's cursor belongs to the table's focus stop, so leaving the
    // stop puts it away: coming back should start on the rows, the way opening
    // the panel does, rather than on a heading the user walked to minutes ago.
    if (f != .table and self.header_cursor != null) {
        self.header_cursor = null;
        logHeaderCursor(self);
    }
}

/// Say where the header's keyboard cursor is (T567).
///
/// Logged for the same reason `noteFocus` is (T300): moving the cursor has no
/// other observable effect until Space commits it, so without this line an
/// acceptance script could only infer "Right moved the cursor" from the sort it
/// produces two keystrokes later — which is a test of the commit, not of the
/// walk.
pub fn logHeaderCursor(self: *const ActivityMonitor) void {
    log.info("activity monitor: header cursor {s}", .{
        if (self.header_cursor) |c| @tagName(c) else "none",
    });
}

/// Move keyboard focus to `f` and repaint, so the ring follows it.
pub fn moveFocus(self: *ActivityMonitor, f: Focusable) void {
    noteFocus(self, f);
    if (f == .table) ensureCaret(self);
    _ = w32.SetFocus(focusHwnd(self, f));
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// The caret's display index, or null when the row it named is gone (exited,
/// filtered out) or there is no caret yet.
pub fn caretIndex(self: *const ActivityMonitor) ?i32 {
    if (self.caret_pid == 0) return null;
    var i: usize = 0;
    while (i < self.order_len) : (i += 1) {
        if (self.pidAt(@intCast(i)) == self.caret_pid) return @intCast(i);
    }
    return null;
}

/// Give the table a caret if it has none, so focus landing on it is visible.
/// The first VISIBLE row, not row 0 — the ring must appear where the user is
/// looking. Selection is deliberately untouched: tabbing into a table is not a
/// selection gesture, and making it one would pop the Kill button on a Tab.
pub fn ensureCaret(self: *ActivityMonitor) void {
    if (caretIndex(self) != null) return;
    self.caret_pid = self.pidAt(self.scroll) orelse 0;
}

/// Keyboard, routed from the app's message loop. Returns true when consumed.
///
/// Escape always closes. Everything else is routed by the focus stop (T289):
/// the table's navigation keys reach the table only while the TABLE holds
/// focus, the carousel's only while the CAROUSEL does, and a focused button or
/// the filter field keeps every key it can use. Before the panel had a visible
/// focus ring, the row keys applied unconditionally — which is what made a
/// missing indicator confusing rather than merely plain: Down moved a
/// selection somewhere off screen while the caret sat in the filter box.
pub fn handleKey(self: *ActivityMonitor, vk: u16) bool {
    if (vk == w32.VK_ESCAPE) {
        self.close();
        return true;
    }

    // Adopt whatever the mouse did to Win32 focus before reading it.
    syncFocus(self);

    if (vk == w32.VK_TAB) {
        const backwards = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
        moveFocus(self, nextVisibleFocus(self.focus, backwards, focusVisibility(self)));
        return true;
    }

    switch (self.focus) {
        // Typing, and the caret keys inside a text box, belong to the EDIT.
        .filter => return false,

        // The carousel's keys. Arrowing — and Home/End, which jump to the ends
        // of a strip too wide to see (T300) — moves the ring and repaints; it
        // never dials. Committing is a separate keystroke precisely so that
        // walking the list cannot open a connection per card (Mac makes the
        // same split, :796-799).
        .carousel => {
            if (!cards_mod.hasCarousel(self.card_count)) return false;
            switch (vk) {
                w32.VK_LEFT, w32.VK_RIGHT, w32.VK_HOME, w32.VK_END => {
                    const key: cards_mod.FocusKey = switch (vk) {
                        w32.VK_LEFT => .left,
                        w32.VK_RIGHT => .right,
                        w32.VK_HOME => .home,
                        else => .end,
                    };
                    const moved = cards_mod.focusFor(key, self.card_focus, self.card_count);
                    if (moved != self.card_focus) {
                        self.card_focus = moved;
                        self.scrollCardIntoView();
                        self.logCarousel();
                        _ = w32.InvalidateRect(self.hwnd, null, 0);
                    }
                    return true;
                },
                w32.VK_RETURN, w32.VK_SPACE => {
                    self.switchToCard(self.card_focus);
                    _ = w32.InvalidateRect(self.hwnd, null, 0);
                    return true;
                },
                else => return false,
            }
        },

        .table => {
            const l = self.layout();
            const page: i32 = @max(1, layout_mod.visibleRows(l) - 1);

            // The HEADER band's keys (T567). The table is one focus stop and it
            // covers two bands: Left/Right walk the column headings, Space or
            // Enter re-sorts by the one under the cursor, and any vertical key
            // drops back to the rows. Before this the headings were mouse-only
            // — `onLeftDown` was the single path into `toggleSort` — so a
            // keyboard user was stuck with whatever sort the panel opened on.
            switch (vk) {
                w32.VK_LEFT, w32.VK_RIGHT => {
                    self.header_cursor = layout_mod.headerCursorMove(
                        self.header_cursor,
                        sortKeyColumn(self),
                        vk == w32.VK_RIGHT,
                    );
                    logHeaderCursor(self);
                    _ = w32.InvalidateRect(self.hwnd, null, 0);
                    return true;
                },
                w32.VK_RETURN, w32.VK_SPACE => {
                    const col = self.header_cursor orelse return false;
                    self.sort = rows_mod.toggleSort(self.sort, columnSortKey(col));
                    self.rebuild();
                    _ = w32.InvalidateRect(self.hwnd, null, 0);
                    return true;
                },
                else => {},
            }
            if (self.header_cursor != null) switch (vk) {
                // A vertical key means "back to the rows" — and then does what
                // it always did, so returning from the header costs no extra
                // keystroke. A key this panel does not use leaves the cursor
                // where it is rather than silently dropping it.
                w32.VK_UP, w32.VK_DOWN, w32.VK_PRIOR, w32.VK_NEXT, w32.VK_HOME, w32.VK_END => {
                    self.header_cursor = null;
                    logHeaderCursor(self);
                    _ = w32.InvalidateRect(self.hwnd, null, 0);
                },
                else => {},
            };

            switch (vk) {
                w32.VK_UP => {
                    moveSelection(self, -1);
                    return true;
                },
                w32.VK_DOWN => {
                    moveSelection(self, 1);
                    return true;
                },
                w32.VK_PRIOR => {
                    moveSelection(self, -page);
                    return true;
                },
                w32.VK_NEXT => {
                    moveSelection(self, page);
                    return true;
                },
                w32.VK_HOME => {
                    moveSelectionTo(self, 0);
                    return true;
                },
                w32.VK_END => {
                    moveSelectionTo(self, @as(i32, @intCast(self.order_len)) - 1);
                    return true;
                },
                else => return false,
            }
        },

        // A focused button owns Space and Enter, and nothing else here is ours.
        .show_all, .kill, .new_proc => return false,
    }
}

pub fn moveSelection(self: *ActivityMonitor, delta: i32) void {
    if (self.order_len == 0) return;
    // From the caret when there is one — that is the row the ring is on, and
    // moving from anywhere else would make the indicator a lie. It falls back
    // to the anchor of a mouse-made selection, and then to "before the first
    // row" so a first arrow key lands on row 0.
    var cur: i32 = -1;
    if (caretIndex(self)) |idx| {
        cur = idx;
    } else if (self.sel_len > 0) {
        const pid = self.sel_pids[self.sel_len - 1];
        var i: usize = 0;
        while (i < self.order_len) : (i += 1) {
            if (self.pidAt(@intCast(i)) == pid) {
                cur = @intCast(i);
                break;
            }
        }
    }
    moveSelectionTo(self, if (cur < 0) 0 else cur + delta);
}

pub fn moveSelectionTo(self: *ActivityMonitor, index: i32) void {
    if (self.order_len == 0) return;
    const clamped = std.math.clamp(index, 0, @as(i32, @intCast(self.order_len)) - 1);
    const pid = self.pidAt(clamped) orelse return;
    // Caret and selection move together for a plain arrow key: this panel has
    // no gesture that decouples them (no Ctrl+Arrow), so a caret that stayed
    // behind would signal a distinction the panel does not have.
    self.caret_pid = pid;
    self.selectOnly(pid);
    scrollIntoView(self, clamped);
    self.refreshChrome();
}

pub fn scrollIntoView(self: *ActivityMonitor, index: i32) void {
    const l = self.layout();
    const visible = layout_mod.visibleRows(l);
    if (visible <= 0) return;
    if (index < self.scroll) self.scroll = index;
    if (index >= self.scroll + visible) self.scroll = index - visible + 1;
    self.clampScroll();
}

pub fn onFilterChanged(self: *ActivityMonitor) void {
    var wbuf: [filter_wide_cap]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(self.filter, &wbuf, wbuf.len));
    // `utf16_text.toUtf8Truncating`, never `std.unicode.utf16LeToUtf8` (T989):
    // the latter does not bounds-check its destination, so a filter longer
    // than the needle buffer panicked here rather than returning an error the
    // `catch` could see. `needle_buf` is sized so nothing `wbuf` can hold is
    // truncated; the truncating call is the guarantee that a future edit to
    // either size cannot bring the crash back.
    self.needle_len = utf16_text.toUtf8Truncating(&self.needle_buf, wbuf[0..wlen]);
    self.scroll = 0;
    self.rebuild();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

// ---------------------------------------------------------------------
// Tests (pure logic only)
// ---------------------------------------------------------------------

const testing = std.testing;

test "nextFocus: the cycle is a ring, and backwards undoes forwards" {
    for (0..focus_count) |i| {
        const f: Focusable = @enumFromInt(i);
        try testing.expectEqual(f, nextFocus(nextFocus(f, false), true));
        try testing.expectEqual(f, nextFocus(nextFocus(f, true), false));
    }

    // Every stop is reached exactly once before coming back — a cycle that
    // skipped one would leave a control unreachable by keyboard, which is the
    // whole defect (§2.2).
    var seen: [focus_count]bool = @splat(false);
    var cur: Focusable = .filter;
    for (0..focus_count) |_| {
        try testing.expect(!seen[@intFromEnum(cur)]);
        seen[@intFromEnum(cur)] = true;
        cur = nextFocus(cur, false);
    }
    try testing.expectEqual(Focusable.filter, cur);
    for (seen) |s| try testing.expect(s);
}

test "nextFocus: Tab order reads top to bottom, then left to right" {
    // The carousel is the top band, the control bar runs filter -> show all ->
    // kill -> new process (`activity_layout`'s own order), and the table is
    // everything below it.
    const order = [_]Focusable{ .carousel, .filter, .show_all, .kill, .new_proc, .table };
    for (order, 0..) |f, i| {
        try testing.expectEqual(order[(i + 1) % order.len], nextFocus(f, false));
    }
}

test "nextVisibleFocus: steps OVER a stop that is not on screen" {
    var v: [focus_count]bool = @splat(true);

    // A single-source panel has no carousel: Tab from the table wraps straight
    // past it to the filter.
    v[@intFromEnum(Focusable.carousel)] = false;
    try testing.expectEqual(Focusable.filter, nextVisibleFocus(.table, false, v));
    try testing.expectEqual(Focusable.table, nextVisibleFocus(.filter, true, v));

    // Kill exists only while rows are selected.
    v[@intFromEnum(Focusable.kill)] = false;
    try testing.expectEqual(Focusable.new_proc, nextVisibleFocus(.show_all, false, v));
    try testing.expectEqual(Focusable.show_all, nextVisibleFocus(.new_proc, true, v));

    // With both back, neither is skipped.
    v = @splat(true);
    try testing.expectEqual(Focusable.carousel, nextVisibleFocus(.table, false, v));
    try testing.expectEqual(Focusable.kill, nextVisibleFocus(.show_all, false, v));
}

test "nextVisibleFocus: nothing visible leaves focus where it is" {
    // Unreachable in the running panel (the filter and the table are always
    // there), but a loop that could not terminate would hang the message pump.
    const v: [focus_count]bool = @splat(false);
    try testing.expectEqual(Focusable.filter, nextVisibleFocus(.filter, false, v));
    try testing.expectEqual(Focusable.table, nextVisibleFocus(.table, true, v));
}
