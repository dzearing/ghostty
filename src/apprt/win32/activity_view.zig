//! Activity monitor view state: the filter, the selection, the scroll, and the
//! layout/chrome that follows from them.
//!
//! Split out of `ActivityMonitor.zig` (T299). This is the layer between the
//! snapshot the sampler produced and the pixels the painter draws: `rebuild`
//! turns the snapshot's rows into the ordered, filtered display list, and
//! everything else here keeps the selection, the caret and the scroll offset
//! consistent with that list as it changes underneath them.
//!
//! `layout`/`options` are the panel's only call into `activity_layout.zig`,
//! which is pure arithmetic and unit-tested; `applyLayout` is what moves the
//! real HWNDs to match it.

const std = @import("std");

const ActivityMonitor = @import("ActivityMonitor.zig");
const input_mod = @import("activity_input.zig");
const actions = @import("activity_actions.zig");
const cards_mod = @import("activity_cards.zig");
const layout_mod = @import("activity_layout.zig");
const rows_mod = @import("activity_rows.zig");
const w32 = @import("win32.zig");

const log = ActivityMonitor.log;
const caretIndex = input_mod.caretIndex;
const ensureCaret = input_mod.ensureCaret;
const moveFocus = input_mod.moveFocus;
const noteFocus = input_mod.noteFocus;

// ---------------------------------------------------------------------
// View state
// ---------------------------------------------------------------------

pub fn needle(self: *const ActivityMonitor) []const u8 {
    return self.needle_buf[0..self.needle_len];
}

pub fn filterSpec(self: *const ActivityMonitor) rows_mod.Filter {
    return .{
        .needle = needle(self),
        .show_all = self.show_all,
        .root_pid = if (self.snap) |s| s.root_pid else 0,
    };
}

/// Re-derive `order` from the current snapshot, filter and sort, then clamp the
/// scroll. Every input change funnels through here, and it logs the result —
/// that log line is the acceptance script's oracle for what the table shows,
/// since a GDI-painted table has no text to read back.
pub fn rebuild(self: *ActivityMonitor) void {
    const snap = self.snap orelse {
        self.order_len = 0;
        return;
    };
    const f = filterSpec(self);
    rows_mod.markSpawned(snap.rows, if (rows_mod.spawnedOnlyActive(f)) f.root_pid else 0, &self.spawned);
    self.order_len = rows_mod.filterInto(snap.rows, f, &self.spawned, &self.order);

    const Ctx = struct {
        rows: []const rows_mod.Row,
        sort: rows_mod.Sort,
        fn less(ctx: @This(), a: u32, b: u32) bool {
            return rows_mod.less(ctx.sort, ctx.rows[a], ctx.rows[b]);
        }
    };
    std.sort.pdq(u32, self.order[0..self.order_len], Ctx{ .rows = snap.rows, .sort = self.sort }, Ctx.less);

    clampScroll(self);

    // A caret whose row was filtered out, sorted away or has exited is no
    // caret. Re-established at the first visible row while the table holds
    // focus, so narrowing the filter never leaves the ring nowhere.
    if (self.caretIndex() == null) {
        self.caret_pid = 0;
        if (self.panel_focused and self.focus == .table) self.ensureCaret();
    }

    log.info(
        // `root` is the snapshot's own root pid — this process for a local
        // sample, the AGENT's for a remote one. It is the field that tells the
        // two apart from outside, which is what the T295 acceptance needs: a
        // loopback agent enumerates the same box, so a row count cannot.
        "activity monitor: source={s} total={d} shown={d} needle=\"{s}\" show_all={} sort={s}/{s} selected={d} root={d}",
        .{
            self.source.label(),
            snap.rows.len,
            self.order_len,
            needle(self),
            self.show_all,
            @tagName(self.sort.key),
            if (self.sort.ascending) "asc" else "desc",
            self.sel_len,
            snap.root_pid,
        },
    );
}

pub fn clampScroll(self: *ActivityMonitor) void {
    const l = layout(self);
    const visible = layout_mod.visibleRows(l);
    const max_scroll = @max(0, @as(i32, @intCast(self.order_len)) - visible);
    self.scroll = std.math.clamp(self.scroll, 0, max_scroll);
}

pub fn isSelected(self: *const ActivityMonitor, pid: i64) bool {
    for (self.sel_pids[0..self.sel_len]) |p| {
        if (p == pid) return true;
    }
    return false;
}

pub fn clearSelection(self: *ActivityMonitor) void {
    self.sel_len = 0;
}

pub fn toggleSelection(self: *ActivityMonitor, pid: i64) void {
    for (self.sel_pids[0..self.sel_len], 0..) |p, i| {
        if (p != pid) continue;
        self.sel_pids[i] = self.sel_pids[self.sel_len - 1];
        self.sel_len -= 1;
        return;
    }
    if (self.sel_len == self.sel_pids.len) return;
    self.sel_pids[self.sel_len] = pid;
    self.sel_len += 1;
}

pub fn selectOnly(self: *ActivityMonitor, pid: i64) void {
    self.sel_len = 1;
    self.sel_pids[0] = pid;
}

/// The row's pid for a display index, or null when the index is out of range.
pub fn pidAt(self: *const ActivityMonitor, display_index: i32) ?i64 {
    if (display_index < 0) return null;
    const i: usize = @intCast(display_index);
    if (i >= self.order_len) return null;
    const snap = self.snap orelse return null;
    return snap.rows[self.order[i]].pid;
}

// ---------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------

pub fn layout(self: *const ActivityMonitor) layout_mod.Layout {
    var rc: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &rc) == 0) {
        const d = layout_mod.defaultClient(self.scale);
        return layout_mod.layout(self.scale, d.w, d.h, options(self));
    }
    return layout_mod.layout(self.scale, rc.right - rc.left, rc.bottom - rc.top, options(self));
}

pub fn options(self: *const ActivityMonitor) layout_mod.Options {
    return .{
        // One source paints no switcher: chrome that controls nothing does not
        // appear (design system §6).
        .has_carousel = cards_mod.hasCarousel(self.card_count),
        .has_banner = self.err_len > 0,
        // Mac shows Kill only while rows are selected (:940). Reading the
        // selection here — rather than tracking a second flag — is what stops
        // the button and the room made for it from disagreeing.
        .has_kill = self.sel_len > 0,
    };
}

/// Re-place the native controls after a resize, a DPI change, or anything that
/// changes which bands exist (a selection appearing makes room for Kill; a
/// banner appearing shortens the table).
pub fn applyLayout(self: *ActivityMonitor) void {
    const l = layout(self);
    _ = w32.MoveWindow(self.filter, l.filter.left, l.filter.top, l.filter.width(), l.filter.height(), 1);
    _ = w32.MoveWindow(self.show_all_btn, l.show_all.left, l.show_all.top, l.show_all.width(), l.show_all.height(), 1);
    _ = w32.MoveWindow(self.new_proc_btn, l.new_proc_btn.left, l.new_proc_btn.top, l.new_proc_btn.width(), l.new_proc_btn.height(), 1);
    _ = w32.MoveWindow(self.kill_btn, l.kill_btn.left, l.kill_btn.top, l.kill_btn.width(), l.kill_btn.height(), 1);
    clampScroll(self);
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// Bring the Kill button in line with the selection: its caption counts the
/// rows, and it is only visible while there are any. Every selection mutation
/// funnels through here, so "the button says Kill 3" and "three rows are
/// selected" are the same fact.
pub fn refreshChrome(self: *ActivityMonitor) void {
    var buf: [32]u8 = undefined;
    var wbuf: [32]u16 = undefined;
    const label = actions.killButtonLabel(&buf, self.sel_len);
    const n = std.unicode.utf8ToUtf16Le(&wbuf, label) catch 0;
    wbuf[n] = 0;
    _ = w32.SetWindowTextW(self.kill_btn, @ptrCast(&wbuf));
    // Hand focus off BEFORE hiding the control that has it. Windows drops the
    // thread's keyboard focus entirely when the focused window is hidden, and
    // with no focus window WM_KEYDOWN arrives with a null hwnd and the panel
    // goes deaf — the same trap `MachineChooser.refreshActions` documents.
    //
    // Only when the button REALLY holds the keyboard, though. Since T292 this
    // can run behind an open Kill confirmation — the selection is pruned when
    // the target exits on its own — and `SetFocus` there would take the
    // keyboard off the dialog the user is answering. `GetFocus` answers for
    // this thread's queue, so a dialog's control is exactly what it reports
    // while one is up. The ring's own bookkeeping still moves: the button is
    // about to be hidden either way, and `.kill` must not stay the focused
    // slot.
    if (self.sel_len == 0 and self.focus == .kill) {
        if (w32.GetFocus() == self.kill_btn) {
            self.moveFocus(.new_proc);
        } else {
            self.noteFocus(.new_proc);
        }
    }
    _ = w32.ShowWindow(self.kill_btn, if (self.sel_len > 0) w32.SW_SHOW else w32.SW_HIDE);
    applyLayout(self);
}

/// Raise the action-error banner. Truncates rather than failing: a banner that
/// says most of what went wrong beats none at all.
pub fn setError(self: *ActivityMonitor, text: []const u8) void {
    const n = @min(text.len, self.err_buf.len);
    @memcpy(self.err_buf[0..n], text[0..n]);
    self.err_len = n;
    log.warn("activity monitor: action error: {s}", .{self.err_buf[0..n]});
    // The banner steals height from the table, so the layout has to run.
    applyLayout(self);
}

pub fn clearError(self: *ActivityMonitor) void {
    if (self.err_len == 0) return;
    self.err_len = 0;
    applyLayout(self);
}
