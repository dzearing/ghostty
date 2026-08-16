//! The "Agent Integrations" management window (T871): one row per coding
//! agent runtime showing whether its CLI is detected and whether Ghoztty's
//! integration is current, with Set Up / Update / Uninstall actions — the
//! win32 counterpart of Mac's `AgentIntegrationsView` + `ViewModel` +
//! `Controller` on the T869 service layer.
//!
//! Structurally this is the ConfirmDialog / HostSettingsDialog shape: a
//! dark owner-centered modal that disables its owner and runs a nested pump
//! (the T48-safe form MessageBoxW itself uses, so the renderer and the IPC
//! server stay live). Modal-vs-Mac's-modeless is a recorded call (D76).
//!
//! Threading: every probe and action touches disk and PATH, so none of it
//! runs on the GUI thread (the Mac freezes were inline probes — same trap
//! here). Workers run detached and post one WM_APP_AGENTS_UPDATE to the
//! app's message-only window; `App.msgWndProc` routes it to `onUpdate`,
//! which talks to the ACTIVE dialog through a module global. Posting to the
//! persistent msg_hwnd rather than the dialog's own hwnd is what makes a
//! worker outliving the dialog safe: a stale update meets `active == null`
//! and is freed, and no message can ever land on a recycled HWND.
//!
//! Row presentation (labels, action gating, honest uninstall copy) is the
//! pure `agent_integrations_vm.zig`, unit-tested in every lane; the layout
//! math is pure and tested at the bottom of this file.

const AgentIntegrationsDialog = @This();

const std = @import("std");
const App = @import("App.zig");
const AgentIntegration = @import("AgentIntegration.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const service = @import("agent_integration_service.zig");
const vm = @import("agent_integrations_vm.zig");
const type_ramp = @import("type_ramp.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyAgentIntegrations");
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const RuntimeAgent = service.RuntimeAgent;
const agent_count = service.agent_count;
const agent_tags = std.meta.tags(RuntimeAgent);

/// Posted to `App.msg_hwnd` by a worker when a refresh or action finished.
/// wparam is a heap `*Update` owned by the handler (`onUpdate`).
pub const WM_APP_AGENTS_UPDATE: u32 = w32.WM_APP + 32;

pub const Update = struct {
    statuses: [agent_count]service.AgentStatus,
    /// The action this update concludes; null for a pure refresh. Outcomes
    /// carry only static detail strings, so this owns no memory.
    action: ?service.AgentResult,
};

/// Dialog colors — the shared dark dialog palette (ConfirmDialog /
/// HostSettingsDialog / the machine chooser).
const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_TEXT = w32.RGB(230, 230, 230);
const COLOR_LABEL = w32.RGB(200, 200, 200);
/// Inline error text: ~6.2:1 on the dialog surface (§2.3 floor is 4.5:1).
const COLOR_ERROR = w32.RGB(240, 120, 120);

var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;

/// The open dialog, if any. GUI thread only: set/cleared inside `open`,
/// read by `onUpdate` — both run on the one thread that pumps messages.
var active: ?*AgentIntegrationsDialog = null;

/// Mac's window subtitle, word for word.
const SUBTITLE_TEXT = blk: {
    @setEvalBranchQuota(4000);
    break :blk L("Add Ghoztty's status banner, skills, and hooks to your coding agents.");
};

const DONE_LABEL = L("Done");
const SET_UP_LABEL = L("Set Up");
const UPDATE_LABEL = L("Update");
const UNINSTALL_LABEL = L("Uninstall");

const ID_DONE: u16 = 1;
/// Row action ids: primary (Set Up / Update) is 100+row, uninstall 200+row.
/// Stable and public-by-convention — the acceptance harness drives the rows
/// by posting WM_COMMAND with these ids.
const ID_PRIMARY_BASE: u16 = 100;
const ID_UNINSTALL_BASE: u16 = 200;

// ---------------------------------------------------------------------
// Layout (pure)
// ---------------------------------------------------------------------

pub const RowLayout = struct {
    name: w32.RECT,
    status: w32.RECT,
    detail: w32.RECT,
    /// The left of the two trailing button slots (Update when paired).
    btn_primary: w32.RECT,
    /// The right slot, flush to the trailing margin (Uninstall; a row's
    /// single button also sits here so lone actions stay trailing-aligned).
    btn_uninstall: w32.RECT,
};

pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    subtitle: w32.RECT,
    rows: [agent_count]RowLayout,
    done: w32.RECT,
    body_font_h: i32,
    caption_font_h: i32,
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Geometry in physical pixels. `sub_w`/`sub_h` are the measured extent of
/// the wrapped subtitle, `text_w` the widest row line (name in body, status
/// and notes in caption), `btn_w` the (already padded) action-button width.
pub fn layoutFor(
    scale: f32,
    sub_w: i32,
    sub_h: i32,
    text_w: i32,
    btn_w: i32,
) Layout {
    const margin = px(16, scale); // xl: dialog content inset
    const sub_gap = px(16, scale);
    const line_gap = px(2, scale); // xs: between a row's text lines
    const row_gap = px(12, scale); // lg: between agent rows
    const text_btn_gap = px(12, scale);
    const btns_gap = px(8, scale); // md: between the two action buttons
    const done_gap = px(16, scale);
    const btn_h = px(28, scale);
    const min_text_w = px(240, scale);
    // Mac's fixed frame width; the floor, not the actual.
    const min_client_w = px(460, scale);

    const btns_w = 2 * btn_w + btns_gap;
    const row_text_w = @max(text_w, min_text_w);

    var client_w = @max(min_client_w, margin + sub_w + margin);
    client_w = @max(client_w, margin + row_text_w + text_btn_gap + btns_w + margin);

    const name_box = type_ramp.lineBox(type_ramp.body(scale), scale);
    const cap_box = type_ramp.lineBox(type_ramp.caption(scale), scale);
    const row_h = name_box + line_gap + cap_box + line_gap + cap_box;

    const btn_left = client_w - margin - btns_w;
    const text_right = btn_left - text_btn_gap;

    const rows_top = margin + sub_h + sub_gap;
    var rows: [agent_count]RowLayout = undefined;
    for (0..agent_count) |i| {
        const top = rows_top + @as(i32, @intCast(i)) * (row_h + row_gap);
        const btn_top = top + @divTrunc(row_h - btn_h, 2);
        rows[i] = .{
            .name = .{
                .left = margin,
                .top = top,
                .right = text_right,
                .bottom = top + name_box,
            },
            .status = .{
                .left = margin,
                .top = top + name_box + line_gap,
                .right = text_right,
                .bottom = top + name_box + line_gap + cap_box,
            },
            .detail = .{
                .left = margin,
                .top = top + name_box + line_gap + cap_box + line_gap,
                .right = text_right,
                .bottom = top + row_h,
            },
            .btn_primary = .{
                .left = btn_left,
                .top = btn_top,
                .right = btn_left + btn_w,
                .bottom = btn_top + btn_h,
            },
            .btn_uninstall = .{
                .left = btn_left + btn_w + btns_gap,
                .top = btn_top,
                .right = client_w - margin,
                .bottom = btn_top + btn_h,
            },
        };
    }

    const n_rows: i32 = @intCast(agent_count);
    const done_top = rows_top + n_rows * row_h +
        (n_rows - 1) * row_gap + done_gap;
    const done_left = client_w - margin - btn_w;

    return .{
        .client_w = client_w,
        .client_h = done_top + btn_h + margin,
        .subtitle = .{
            .left = margin,
            .top = margin,
            .right = client_w - margin,
            .bottom = margin + sub_h,
        },
        .rows = rows,
        .done = .{
            .left = done_left,
            .top = done_top,
            .right = done_left + btn_w,
            .bottom = done_top + btn_h,
        },
        .body_font_h = type_ramp.body(scale).height,
        .caption_font_h = type_ramp.caption(scale).height,
    };
}

// ---------------------------------------------------------------------
// Dialog state
// ---------------------------------------------------------------------

const RowCtl = struct {
    name: w32.HWND,
    status: w32.HWND,
    detail: w32.HWND,
    primary: w32.HWND,
    uninstall: w32.HWND,
};

hwnd: w32.HWND,
app: *App,
scale: f32,
subtitle: ?w32.HWND = null,
rows: [agent_count]RowCtl,
done_btn: w32.HWND,
layout: Layout,
/// null until the first probe answers — rows show "Checking…".
statuses: ?[agent_count]service.AgentStatus = null,
/// The agent an action is running for; every row's actions disable while
/// one is in flight (installs share the banner scripts, so actions are
/// serialized — same rule as `AgentIntegration.install_running`).
busy_agent: ?RuntimeAgent = null,
err_bufs: [agent_count][192]u8 = undefined,
err_lens: [agent_count]usize = @splat(0),
/// Per-row paint state for WM_CTLCOLORSTATIC.
name_secondary: [agent_count]bool = @splat(false),
detail_is_error: [agent_count]bool = @splat(false),
closed: bool = false,

// ---------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------

/// Open the dialog over `owner` and run it to completion. Reentry (already
/// open) just refocuses — unreachable while modal, but harmless.
pub fn open(app: *App, owner: ?w32.HWND, scale: f32, refocus: ?w32.HWND) void {
    if (active) |d| {
        _ = w32.SetForegroundWindow(d.hwnd);
        return;
    }
    registerClass(app) orelse return;

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;

    const body_font = createRampFont(type_ramp.body(scale));
    defer if (body_font) |f| {
        _ = w32.DeleteObject(f);
    };
    const caption_font = createRampFont(type_ramp.caption(scale));
    defer if (caption_font) |f| {
        _ = w32.DeleteObject(f);
    };

    // Measure the wrapped subtitle, the widest row line in its own font,
    // and the widest button caption.
    var sub_rect: w32.RECT = .{ .left = 0, .top = 0, .right = px(428, scale), .bottom = 0 };
    var text_w: i32 = 0;
    var btn_label_w: i32 = 0;
    {
        const hdc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, hdc);
        const prev = if (body_font) |f| w32.SelectObject(hdc, f) else null;
        defer if (prev) |p| {
            _ = w32.SelectObject(hdc, p);
        };
        _ = w32.DrawTextW(
            hdc,
            SUBTITLE_TEXT.ptr,
            @intCast(SUBTITLE_TEXT.len),
            &sub_rect,
            w32.DT_CALCRECT | w32.DT_WORDBREAK | w32.DT_NOPREFIX,
        );
        // Row names are body; measure them under the body font.
        inline for (agent_tags) |agent| {
            text_w = @max(text_w, measureUtf8(hdc, agent.displayName()));
        }
        for ([_][:0]const u16{ SET_UP_LABEL, UPDATE_LABEL, UNINSTALL_LABEL, DONE_LABEL }) |s| {
            btn_label_w = @max(btn_label_w, measure(hdc, s));
        }
        // Status and note lines are caption; the "Not detected" hints are
        // the longest strings a row ever shows.
        if (caption_font) |f| {
            const prev_cap = w32.SelectObject(hdc, f);
            defer if (prev_cap) |p| {
                _ = w32.SelectObject(hdc, p);
            };
            inline for (agent_tags) |agent| {
                const s = service.AgentStatus{
                    .agent = agent,
                    .detected = false,
                    .state = .not_installed,
                    .plugin_managed = false,
                    .banner_shared_with_other = false,
                };
                text_w = @max(text_w, measureUtf8(hdc, vm.derive(s, false, false).status_label));
            }
            text_w = @max(text_w, measureUtf8(hdc, vm.plugin_note_text));
        }
    }

    const l = layoutFor(
        scale,
        sub_rect.right - sub_rect.left,
        sub_rect.bottom - sub_rect.top,
        text_w,
        buttonWidth(scale, btn_label_w),
    );

    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const outer_w = frame.right - frame.left;
    const outer_h = frame.bottom - frame.top;
    var center: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = w32.GetSystemMetrics(0), // SM_CXSCREEN
        .bottom = w32.GetSystemMetrics(1), // SM_CYSCREEN
    };
    if (owner) |o| _ = w32.GetWindowRect(o, &center);
    const x = center.left + @divTrunc((center.right - center.left) - outer_w, 2);
    const y = center.top + @divTrunc((center.bottom - center.top) - outer_h, 2);

    // The dialog lives on this stack frame: `open` does not return until
    // the nested loop is done, so nothing needs to be allocated.
    var self: AgentIntegrationsDialog = .{
        .hwnd = undefined,
        .app = app,
        .scale = scale,
        .rows = undefined,
        .done_btn = undefined,
        .layout = l,
    };

    const hwnd = w32.CreateWindowExW(
        ex_style,
        CLASS_NAME,
        L("Agent Integrations"),
        style,
        x,
        y,
        outer_w,
        outer_h,
        owner,
        null,
        app.hinstance,
        null,
    ) orelse return;
    self.hwnd = hwnd;

    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    self.subtitle = createStatic(app, hwnd, SUBTITLE_TEXT, l.subtitle, true);
    var created = true;
    inline for (agent_tags, 0..) |agent, i| {
        var name_buf: [64]u16 = undefined;
        const name = utf16z(&name_buf, agent.displayName()) orelse L("?");
        const row = &self.rows[i];
        row.name = createStatic(app, hwnd, name, l.rows[i].name, true) orelse blk: {
            created = false;
            break :blk undefined;
        };
        row.status = createStatic(app, hwnd, L(""), l.rows[i].status, true) orelse blk: {
            created = false;
            break :blk undefined;
        };
        row.detail = createStatic(app, hwnd, L(""), l.rows[i].detail, true) orelse blk: {
            created = false;
            break :blk undefined;
        };
        // Action buttons are created hidden; `updateRows` shows what the
        // derived state offers.
        row.primary = createButton(
            app,
            hwnd,
            SET_UP_LABEL,
            l.rows[i].btn_primary,
            ID_PRIMARY_BASE + @as(u16, @intCast(i)),
            false,
            false,
            body_font,
        ) orelse blk: {
            created = false;
            break :blk undefined;
        };
        row.uninstall = createButton(
            app,
            hwnd,
            UNINSTALL_LABEL,
            l.rows[i].btn_uninstall,
            ID_UNINSTALL_BASE + @as(u16, @intCast(i)),
            false,
            false,
            body_font,
        ) orelse blk: {
            created = false;
            break :blk undefined;
        };
    }
    self.done_btn = w32.CreateWindowExW(
        0,
        L("BUTTON"),
        DONE_LABEL.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.BS_DEFPUSHBUTTON,
        l.done.left,
        l.done.top,
        l.done.right - l.done.left,
        l.done.bottom - l.done.top,
        hwnd,
        @ptrFromInt(@as(usize, ID_DONE)),
        app.hinstance,
        null,
    ) orelse {
        created = false;
        return destroyEarly(hwnd);
    };
    if (!created) return destroyEarly(hwnd);
    _ = w32.SetWindowTheme(self.done_btn, L("DarkMode_Explorer"), null);

    if (body_font) |f| {
        if (self.subtitle) |h| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        for (self.rows) |row| {
            _ = w32.SendMessageW(row.name, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
        _ = w32.SendMessageW(self.done_btn, w32.WM_SETFONT, @intFromPtr(f), 1);
    }
    if (caption_font) |f| {
        for (self.rows) |row| {
            _ = w32.SendMessageW(row.status, w32.WM_SETFONT, @intFromPtr(f), 1);
            _ = w32.SendMessageW(row.detail, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&self)));

    active = &self;
    self.updateRows();

    if (owner) |o| _ = w32.EnableWindow(o, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(self.done_btn);

    // The window is up and painted "Checking…"; fill it in off-thread
    // (Mac's fire-and-forget refresh).
    spawnWork(app, null);

    self.runModal();
    active = null;

    // The owner MUST be re-enabled before the dialog is destroyed, else
    // Windows may activate another app's window.
    if (owner) |o| _ = w32.EnableWindow(o, 1);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(hwnd);
    if (owner) |o| _ = w32.SetForegroundWindow(o);
    if (refocus) |h| App.deferSetFocus(h); // T48
}

fn destroyEarly(hwnd: w32.HWND) void {
    log.warn("agent integrations dialog: control creation failed", .{});
    _ = w32.DestroyWindow(hwnd);
}

/// GUI thread (`App.msgWndProc`): a worker's refresh/action result. Owns
/// `up`. A result arriving after the dialog closed is dropped.
pub fn onUpdate(app: *App, up: *Update) void {
    defer app.core_app.alloc.destroy(up);
    const self = active orelse return;

    if (up.action) |ar| {
        self.busy_agent = null;
        const idx = indexOf(ar.agent);
        switch (ar.outcome) {
            .failed => |detail| {
                const text = std.fmt.bufPrint(
                    &self.err_bufs[idx],
                    "failed — {s}",
                    .{detail},
                ) catch blk: {
                    // A detail too long for the buffer keeps the fixed half.
                    const fallback = "failed";
                    @memcpy(self.err_bufs[idx][0..fallback.len], fallback);
                    break :blk self.err_bufs[idx][0..fallback.len];
                };
                self.err_lens[idx] = text.len;
            },
            else => self.err_lens[idx] = 0,
        }
    }
    self.statuses = up.statuses;
    self.updateRows();
}

fn indexOf(agent: RuntimeAgent) usize {
    return @intFromEnum(agent);
}

// ---------------------------------------------------------------------
// Row presentation
// ---------------------------------------------------------------------

/// Re-derive every row's texts, colors and buttons from current state.
fn updateRows(self: *AgentIntegrationsDialog) void {
    inline for (agent_tags, 0..) |agent, i| {
        const row = &self.rows[i];
        const rl = &self.layout.rows[i];
        if (self.statuses) |statuses| {
            const busy = self.busy_agent != null and self.busy_agent.? == agent;
            const derived = vm.derive(statuses[i], busy, self.err_lens[i] > 0);
            self.name_secondary[i] = derived.name_secondary;
            self.detail_is_error[i] = derived.detail == .error_text;
            setText(row.status, derived.status_label);
            setText(row.detail, switch (derived.detail) {
                .none => "",
                .plugin_note => vm.plugin_note_text,
                .error_text => self.err_bufs[i][0..self.err_lens[i]],
            });

            // A lone action sits in the trailing slot so single-button rows
            // stay flush with the margin; the pair uses both slots.
            const enable: i32 = if (self.busy_agent == null) 1 else 0;
            switch (derived.actions) {
                .none => {
                    _ = w32.ShowWindow(row.primary, w32.SW_HIDE);
                    _ = w32.ShowWindow(row.uninstall, w32.SW_HIDE);
                },
                .set_up => {
                    _ = w32.SetWindowTextW(row.primary, SET_UP_LABEL.ptr);
                    moveTo(row.primary, rl.btn_uninstall);
                    _ = w32.ShowWindow(row.primary, w32.SW_SHOW);
                    _ = w32.EnableWindow(row.primary, enable);
                    _ = w32.ShowWindow(row.uninstall, w32.SW_HIDE);
                },
                .uninstall => {
                    _ = w32.ShowWindow(row.primary, w32.SW_HIDE);
                    _ = w32.ShowWindow(row.uninstall, w32.SW_SHOW);
                    _ = w32.EnableWindow(row.uninstall, enable);
                },
                .update_and_uninstall => {
                    _ = w32.SetWindowTextW(row.primary, UPDATE_LABEL.ptr);
                    moveTo(row.primary, rl.btn_primary);
                    _ = w32.ShowWindow(row.primary, w32.SW_SHOW);
                    _ = w32.EnableWindow(row.primary, enable);
                    _ = w32.ShowWindow(row.uninstall, w32.SW_SHOW);
                    _ = w32.EnableWindow(row.uninstall, enable);
                },
            }
        } else {
            self.name_secondary[i] = false;
            self.detail_is_error[i] = false;
            setText(row.status, vm.checking_label);
            setText(row.detail, "");
            _ = w32.ShowWindow(row.primary, w32.SW_HIDE);
            _ = w32.ShowWindow(row.uninstall, w32.SW_HIDE);
        }
        // Colors changed with state; statics repaint through WM_PAINT.
        _ = w32.InvalidateRect(row.name, null, 1);
    }
}

fn moveTo(hwnd: w32.HWND, r: w32.RECT) void {
    _ = w32.MoveWindow(hwnd, r.left, r.top, r.right - r.left, r.bottom - r.top, 1);
}

fn setText(hwnd: w32.HWND, text: []const u8) void {
    var buf: [256]u16 = undefined;
    const w = utf16z(&buf, text) orelse return;
    _ = w32.SetWindowTextW(hwnd, w.ptr);
}

// ---------------------------------------------------------------------
// Actions (GUI thread)
// ---------------------------------------------------------------------

fn onPrimary(self: *AgentIntegrationsDialog, i: usize) void {
    if (self.busy_agent != null) return;
    const statuses = self.statuses orelse return;
    if (i >= agent_count) return;
    const status = statuses[i];
    const kind: WorkKind = switch (status.state) {
        .not_installed, .outdated => .install,
        .installed => return, // no primary action while installed
    };
    self.startAction(status.agent, kind);
}

fn onUninstall(self: *AgentIntegrationsDialog, i: usize) void {
    if (self.busy_agent != null) return;
    const statuses = self.statuses orelse return;
    if (i >= agent_count) return;
    const status = statuses[i];

    // The honest confirm copy (Mac's confirmationDialog, word for word).
    var arena_state = std.heap.ArenaAllocator.init(self.app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const title = std.unicode.utf8ToUtf16LeAllocZ(
        arena,
        vm.confirmTitle(status.agent),
    ) catch return;
    const text = std.unicode.utf8ToUtf16LeAllocZ(
        arena,
        vm.uninstallMessage(status.agent, vm.uninstallVariant(status)),
    ) catch return;

    const result = ConfirmDialog.show(
        self.app,
        self.hwnd,
        self.scale,
        null,
        .{
            .title = title.ptr,
            .text = text,
            .icon = .warning,
            .ok_label = L("Remove"),
            // default_cancel stays true: Enter never removes by accident.
        },
    );
    if (result != .ok) return;
    self.startAction(status.agent, .uninstall);
}

fn startAction(self: *AgentIntegrationsDialog, agent: RuntimeAgent, kind: WorkKind) void {
    self.busy_agent = agent;
    self.err_lens[indexOf(agent)] = 0;
    self.updateRows();
    spawnWork(self.app, .{ .agent = agent, .kind = kind });
}

// ---------------------------------------------------------------------
// Workers (detached threads)
// ---------------------------------------------------------------------

const WorkKind = enum { install, uninstall };
const Work = struct { agent: RuntimeAgent, kind: WorkKind };

fn spawnWork(app: *App, work: ?Work) void {
    const thread = std.Thread.spawn(.{}, workThread, .{ app, work }) catch |err| {
        log.warn("agent integrations: worker spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

/// Everything that touches disk or PATH: run the action (if any), then
/// re-probe every agent, then hand the result to the GUI thread.
fn workThread(app: *App, work: ?Work) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const alloc = app.core_app.alloc;
    const up = alloc.create(Update) catch return;
    up.* = .{ .statuses = fallbackStatuses(), .action = null };

    if (AgentIntegration.openAgentHome(arena)) |home| {
        var home_dir = home.dir;
        defer home_dir.close();
        const probe = AgentIntegration.probeFor(arena);
        if (work) |wk| {
            const attempted = switch (wk.kind) {
                .install => service.install(arena, wk.agent, home_dir, home.path, probe),
                .uninstall => service.uninstall(arena, wk.agent, home_dir, home.path, probe),
            };
            const outcome = attempted catch
                service.IntegrationOutcome{ .failed = "out of memory" };
            up.action = .{ .agent = wk.agent, .outcome = outcome };
            log.info("agent integrations: {s} {s}: {s}", .{
                @tagName(wk.kind),
                @tagName(wk.agent),
                outcome.label(),
            });
        }
        up.statuses = service.allAgentStatuses(arena, home_dir, home.path, probe) catch
            fallbackStatuses();
    } else if (work) |wk| {
        up.action = .{ .agent = wk.agent, .outcome = .{ .failed = "HomeUnavailable" } };
    }

    const hwnd = app.msg_hwnd orelse {
        alloc.destroy(up);
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_AGENTS_UPDATE, @intFromPtr(up), 0) == 0) {
        alloc.destroy(up);
    }
}

/// When the home cannot even be opened, every row reads undetected — the
/// honest floor, and the same thing the service would report from an empty
/// home.
fn fallbackStatuses() [agent_count]service.AgentStatus {
    var out: [agent_count]service.AgentStatus = undefined;
    inline for (agent_tags, 0..) |agent, i| {
        out[i] = .{
            .agent = agent,
            .detected = false,
            .state = .not_installed,
            .plugin_managed = false,
            .banner_shared_with_other = false,
        };
    }
    return out;
}

// ---------------------------------------------------------------------
// Control helpers
// ---------------------------------------------------------------------

fn createRampFont(font: type_ramp.Font) ?*anyopaque {
    return w32.CreateFontW(
        -font.height,
        0,
        0,
        0,
        font.weight,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        L(type_ramp.face),
    );
}

fn measure(hdc: w32.HDC, s: [:0]const u16) i32 {
    var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.DrawTextW(hdc, s.ptr, @intCast(s.len), &r, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
    return r.right - r.left;
}

fn measureUtf8(hdc: w32.HDC, s: []const u8) i32 {
    var buf: [256]u16 = undefined;
    const w = utf16z(&buf, s) orelse return 0;
    return measure(hdc, w);
}

/// Button width: the standard 88 DIP, widened when a caption needs it (the
/// ConfirmDialog rule).
pub fn buttonWidth(scale: f32, max_label_w: i32) i32 {
    return @max(px(88, scale), max_label_w + px(24, scale));
}

fn createStatic(
    app: *App,
    parent: w32.HWND,
    text: [:0]const u16,
    r: w32.RECT,
    visible: bool,
) ?w32.HWND {
    return w32.CreateWindowExW(
        0,
        L("STATIC"),
        text.ptr,
        w32.WS_CHILD | (if (visible) w32.WS_VISIBLE_STYLE else 0) | w32.SS_NOPREFIX,
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        parent,
        null,
        app.hinstance,
        null,
    );
}

fn createButton(
    app: *App,
    parent: w32.HWND,
    label: [:0]const u16,
    r: w32.RECT,
    id: u16,
    default: bool,
    visible: bool,
    font: ?*anyopaque,
) ?w32.HWND {
    const h = w32.CreateWindowExW(
        0,
        L("BUTTON"),
        label.ptr,
        w32.WS_CHILD | (if (visible) w32.WS_VISIBLE_STYLE else 0) |
            (if (default) w32.BS_DEFPUSHBUTTON else 0),
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        parent,
        @ptrFromInt(@as(usize, id)),
        app.hinstance,
        null,
    ) orelse return null;
    _ = w32.SetWindowTheme(h, L("DarkMode_Explorer"), null);
    if (font) |f| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
    return h;
}

/// UTF-8 → NUL-terminated UTF-16 in `buf`, or null when it does not fit.
fn utf16z(buf: []u16, text: []const u8) ?[:0]const u16 {
    if (text.len + 1 > buf.len) return null;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return null;
    buf[n] = 0;
    return buf[0..n :0];
}

// ---------------------------------------------------------------------
// Modal loop + key routing
// ---------------------------------------------------------------------

/// Reuse the shared focus-cycle rule (HostSettingsDialog's, unit-tested
/// there).
const nextFocusIndex = @import("HostSettingsDialog.zig").nextFocusIndex;

/// Nested modal pump — the ConfirmDialog shape: WM_APP_SETFOCUS (T48
/// deferred focus) is performed here rather than dispatched; everything
/// else flows through Translate/Dispatch so the renderer, the IPC server
/// and our own WM_APP updates stay live.
fn runModal(self: *AgentIntegrationsDialog) void {
    var msg: w32.MSG = undefined;
    while (!self.closed) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT: repost for the outer loop.
            w32.PostQuitMessage(@intCast(msg.wParam));
            return;
        }
        if (result < 0) return;
        if (msg.message == App.WM_APP_SETFOCUS) {
            if (msg.hwnd) |h| App.performDeferredFocus(h);
            continue;
        }
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null and self.ownsHwnd(msg.hwnd.?)) {
            const vk: u16 = @intCast(msg.wParam & 0xFFFF);
            if (self.handleKey(vk)) continue;
        }
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

fn ownsHwnd(self: *const AgentIntegrationsDialog, hwnd: w32.HWND) bool {
    if (hwnd == self.hwnd or hwnd == self.done_btn) return true;
    for (self.rows) |row| {
        if (hwnd == row.primary or hwnd == row.uninstall) return true;
    }
    return false;
}

/// The tabbable controls right now: each row's visible-and-enabled action
/// buttons in reading order, then Done.
fn focusStops(self: *const AgentIntegrationsDialog, out: *[2 * agent_count + 1]w32.HWND) usize {
    var n: usize = 0;
    for (self.rows) |row| {
        for ([_]w32.HWND{ row.primary, row.uninstall }) |h| {
            if (w32.IsWindowVisible(h) != 0 and self.busy_agent == null) {
                out[n] = h;
                n += 1;
            }
        }
    }
    out[n] = self.done_btn;
    n += 1;
    return n;
}

fn finish(self: *AgentIntegrationsDialog) void {
    self.closed = true;
}

/// Handle a dialog key out of the nested pump. Returns true when consumed.
fn handleKey(self: *AgentIntegrationsDialog, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            self.finish();
            return true;
        },
        w32.VK_RETURN => {
            // Enter activates the focused action button; anywhere else it
            // is Done (the Mac default).
            const focus = w32.GetFocus();
            inline for (0..agent_count) |i| {
                if (focus == @as(?w32.HWND, self.rows[i].primary)) {
                    self.onPrimary(i);
                    return true;
                }
                if (focus == @as(?w32.HWND, self.rows[i].uninstall)) {
                    self.onUninstall(i);
                    return true;
                }
            }
            self.finish();
            return true;
        },
        w32.VK_TAB => {
            var stops: [2 * agent_count + 1]w32.HWND = undefined;
            const n = self.focusStops(&stops);
            const focus = w32.GetFocus();
            var cur: usize = n - 1; // default: Done
            for (stops[0..n], 0..) |h, i| {
                if (focus == @as(?w32.HWND, h)) cur = i;
            }
            const backwards = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            _ = w32.SetFocus(stops[nextFocusIndex(cur, n, backwards)]);
            return true;
        },
        else => return false,
    }
}

fn registerClass(app: *App) ?void {
    if (class_registered) return;
    bg_brush = w32.CreateSolidBrush(COLOR_BG);
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &dialogWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = app.hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("agent integrations dialog class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *AgentIntegrationsDialog = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (notification == w32.BN_CLICKED) {
                if (control_id == ID_DONE) {
                    self.finish();
                    return 0;
                }
                if (control_id >= ID_PRIMARY_BASE and control_id < ID_PRIMARY_BASE + agent_count) {
                    self.onPrimary(control_id - ID_PRIMARY_BASE);
                    return 0;
                }
                if (control_id >= ID_UNINSTALL_BASE and control_id < ID_UNINSTALL_BASE + agent_count) {
                    self.onUninstall(control_id - ID_UNINSTALL_BASE);
                    return 0;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            // ✕ dismisses, like Done — there is nothing to cancel.
            self.finish();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const state: u16 = @intCast(wparam & 0xFFFF);
            if (state != w32.WA_INACTIVE) {
                const focus = w32.GetFocus();
                const owned = focus != null and self.ownsHwnd(focus.?);
                if (!owned) _ = w32.SetFocus(self.done_btn);
            }
            return 0;
        },
        w32.WM_CTLCOLORSTATIC => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const ctl: ?w32.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            var color = COLOR_LABEL;
            for (self.rows, 0..) |row, i| {
                if (ctl == @as(?w32.HWND, row.name)) {
                    color = if (self.name_secondary[i]) COLOR_LABEL else COLOR_TEXT;
                } else if (ctl == @as(?w32.HWND, row.detail)) {
                    color = if (self.detail_is_error[i]) COLOR_ERROR else COLOR_LABEL;
                }
            }
            _ = w32.SetTextColor(hdc, color);
            _ = w32.SetBkColor(hdc, COLOR_BG);
            if (bg_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_BG);
            if (bg_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------
// Tests (pure layout logic)
// ---------------------------------------------------------------------

const testing = std.testing;

fn allRects(l: *const Layout, out: *[5 * agent_count + 2]w32.RECT) void {
    out[0] = l.subtitle;
    out[1] = l.done;
    for (l.rows, 0..) |r, i| {
        out[2 + i * 5 + 0] = r.name;
        out[2 + i * 5 + 1] = r.status;
        out[2 + i * 5 + 2] = r.detail;
        out[2 + i * 5 + 3] = r.btn_primary;
        out[2 + i * 5 + 4] = r.btn_uninstall;
    }
}

test "layoutFor: every control nests inside the client area" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layoutFor(scale, 400, 40, 280, 88);
        try testing.expect(l.client_w > 0 and l.client_h > 0);
        var rects: [5 * agent_count + 2]w32.RECT = undefined;
        allRects(&l, &rects);
        for (rects) |r| {
            try testing.expect(r.left >= 0 and r.top >= 0);
            try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
            try testing.expect(r.right > r.left and r.bottom > r.top);
        }
    }
}

test "layoutFor: rows stack without overlap, text left of buttons" {
    const l = layoutFor(1.0, 400, 40, 280, 88);
    try testing.expect(l.subtitle.bottom <= l.rows[0].name.top);
    for (l.rows) |r| {
        // The three text lines stack inside the row.
        try testing.expect(r.name.bottom <= r.status.top);
        try testing.expect(r.status.bottom <= r.detail.top);
        // Text never reaches the button slots (12 px group gap at 1.0).
        try testing.expect(r.name.right + 12 <= r.btn_primary.left);
        // The pair keeps its md gap and ends on the trailing margin.
        try testing.expect(r.btn_primary.right + 8 == r.btn_uninstall.left);
        try testing.expectEqual(l.client_w - 16, r.btn_uninstall.right);
        // Buttons sit inside the row's vertical band.
        try testing.expect(r.btn_primary.top >= r.name.top);
        try testing.expect(r.btn_primary.bottom <= r.detail.bottom);
    }
    try testing.expect(l.rows[0].detail.bottom <= l.rows[1].name.top);
    try testing.expect(l.rows[1].detail.bottom <= l.done.top);
}

test "layoutFor: Done is trailing-aligned on the bottom margin" {
    const l = layoutFor(1.0, 400, 40, 280, 88);
    try testing.expectEqual(l.client_w - 16, l.done.right);
    try testing.expectEqual(l.client_h - 16, l.done.bottom);
}

test "layoutFor: never narrower than the Mac floor, subtitle, or a full row" {
    // A tiny subtitle still leaves the 460 DIP Mac floor.
    const narrow = layoutFor(1.0, 10, 20, 10, 88);
    try testing.expect(narrow.client_w >= 460);
    // Long row text pushes the dialog out rather than clipping.
    const wide = layoutFor(1.0, 10, 20, 600, 88);
    try testing.expect(wide.client_w >= 16 + 600 + 12 + 88 * 2 + 8 + 16);
    // A wide subtitle grows the dialog too.
    const wide_sub = layoutFor(1.0, 900, 60, 10, 88);
    try testing.expect(wide_sub.client_w >= 900 + 32);
}

test "layoutFor: scaling is proportional, not clipped" {
    const a = layoutFor(1.0, 400, 40, 280, 88);
    const b = layoutFor(2.0, 800, 80, 560, 176);
    try testing.expectEqual(a.client_w * 2, b.client_w);
    try testing.expectEqual(a.client_h * 2, b.client_h);
}

test "layoutFor: both fonts come from the ramp (T313)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layoutFor(scale, 400, 40, 280, 88);
        try testing.expectEqual(type_ramp.body(scale).height, l.body_font_h);
        try testing.expectEqual(type_ramp.caption(scale).height, l.caption_font_h);
    }
}

test {
    testing.refAllDecls(@This());
}

test "buttonWidth: standard 88 DIP, widened for a long caption" {
    try testing.expectEqual(@as(i32, 88), buttonWidth(1.0, 40));
    try testing.expectEqual(@as(i32, 176), buttonWidth(2.0, 40));
    try testing.expectEqual(@as(i32, 224), buttonWidth(1.0, 200));
}
