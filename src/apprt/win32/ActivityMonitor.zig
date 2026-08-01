//! The win32 Activity Monitor panel (T285) — the port of Mac's
//! `RemoteActivityMonitor.swift` + `RemoteActivityMonitorView.swift`. Windows had
//! ZERO of this surface before T226 split into T284..T287; this is the window
//! itself, fed by the LOCAL source.
//!
//! ## The split
//! All arithmetic lives in pure modules that run in every test lane:
//! `activity_layout.zig` (regions + column widths, T284), `trend_gauge.zig`
//! (chart geometry, T284) and `activity_rows.zig` (filter / sort / cell text,
//! T285). This file owns the HWND, the GDI calls and the sampling thread — the
//! same division that keeps `chooser_layout.zig` testable while
//! `MachineChooser.zig` keeps the win32 surface.
//!
//! ## Registry
//! One panel per SOURCE (`.local` today; `.remote` arrives with T287). A second
//! open focuses the existing panel instead of duplicating it, mirroring
//! `RemoteActivityMonitor.focusExisting` (RemoteActivityMonitor.swift:146-150).
//! The slot arithmetic is pure and unit-tested at the bottom of this file.
//!
//! ## Threading
//! `proc.ProcSampler.sample` enumerates every process on the box and opens each
//! one — far too much to run on the GUI thread every 1.5 s, and Mac runs the
//! equivalent on a background queue (RemoteActivityMonitorView.swift:99-101). So
//! the timer kicks a worker thread that samples into an arena-backed `Snapshot`,
//! parks it under a mutex and posts `WM_APP_ACTIVITY_SAMPLE`; the GUI thread
//! adopts it. Exactly one sample is ever in flight (`sampling`), so the two
//! samplers are only ever touched by that worker, and `close` JOINS it before
//! freeing anything it could still be writing to.
//!
//! ## What is NOT here
//! Process control (Kill / New Process) is T286, and the machine carousel plus
//! remote sources are T287. The layout module already reserves both, so the
//! "New Process…" button is created DISABLED rather than omitted: the control
//! bar then has the geometry the layout module describes from day one (which the
//! acceptance script measures), and a disabled control is an honest state
//! (design system §2.2) where a live button that does nothing is not.

const ActivityMonitor = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const layout_mod = @import("activity_layout.zig");
const rows_mod = @import("activity_rows.zig");
const gauge = @import("trend_gauge.zig");
const icon_button = @import("icon_button.zig");
const Scrollbar = @import("Scrollbar.zig");
const remote_proc = @import("../../remote/agent/proc.zig");
const remote_metrics = @import("../../remote/agent/metrics.zig");
const remote_protocol = @import("../../remote/protocol.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyActivityMonitor");

const FILTER_ID: u16 = 100;
const SHOW_ALL_ID: u16 = 101;
const NEW_PROC_ID: u16 = 102;

/// The poll timer. `trend_gauge.sample_interval_ms` is the interval the ring was
/// sized for, so the ring really does hold ~90 s.
const SAMPLE_TIMER_ID: usize = 1;

/// A worker thread finished a sample and parked it in `pending`. WM_APP+1..+12
/// are taken (see App.zig / Window.zig / ClaudeIntegration.zig / RelayAccountRow.zig).
pub const WM_APP_ACTIVITY_SAMPLE: u32 = w32.WM_APP + 13;

/// Hard cap on rows carried into the view, matching the sampler's own
/// `default_limit`. Fixed-size state (order/selection/spawned) is sized to it, so
/// the panel allocates nothing per poll beyond its snapshot arena.
const max_rows: usize = remote_proc.default_limit;

// ---------------------------------------------------------------------
// Palette — the RenameDialog / MachineChooser dark palette, so every dialog
// in the app reads as one family.
// ---------------------------------------------------------------------

const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_FIELD_BG = w32.RGB(30, 30, 30);
const COLOR_TEXT = w32.RGB(230, 230, 230);
const COLOR_LABEL = w32.RGB(200, 200, 200);
/// Secondary text: Mac's `.secondary` foreground. 200 -> 150 keeps it above the
/// 4.5:1 floor on the 32,32,32 surface (design system §2.3).
const COLOR_SECONDARY = w32.RGB(150, 150, 150);
const COLOR_DIVIDER = w32.RGB(60, 60, 60);
/// The table header band and the selection fill. Selection uses the system
/// accent-ish blue the chooser rows already use.
const COLOR_HEADER_BG = w32.RGB(40, 40, 40);
const COLOR_SELECT = w32.RGB(38, 79, 120);
const COLOR_HOVER = w32.RGB(45, 45, 45);
/// The chart plot area, one notch below the panel so the gauge reads as a well.
const COLOR_CHART_BG = w32.RGB(26, 26, 26);
const COLOR_GRID = w32.RGB(52, 52, 52);
/// Mac's gauge tints (`tint: .blue` / `.green`, RemoteActivityMonitorView.swift:868, :878).
const COLOR_CPU = w32.RGB(80, 160, 235);
const COLOR_CPU_FILL = w32.RGB(38, 66, 94);
const COLOR_MEM = w32.RGB(90, 190, 120);
const COLOR_MEM_FILL = w32.RGB(40, 78, 52);
/// The "List truncated" badge — Mac's `.secondary` label with a warning glyph.
const COLOR_WARN = w32.RGB(220, 165, 90);
/// The overlay scroll thumb, at rest and while grabbed.
const COLOR_THUMB = w32.RGB(90, 90, 90);
const COLOR_THUMB_ACTIVE = w32.RGB(130, 130, 130);

var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;
var field_brush: ?w32.HBRUSH = null;

// ---------------------------------------------------------------------
// Source + registry
// ---------------------------------------------------------------------

/// What a panel is showing. `.remote` carries the machine id and arrives with
/// T287; it exists now so the registry is keyed correctly from the start rather
/// than being retrofitted onto a `.local`-only assumption.
pub const Source = union(enum) {
    local,
    remote: []const u8,

    pub fn eql(a: Source, b: Source) bool {
        return switch (a) {
            .local => b == .local,
            .remote => |ida| switch (b) {
                .local => false,
                .remote => |idb| std.mem.eql(u8, ida, idb),
            },
        };
    }

    /// The window title's subject — Mac titles the window "Activity — <label>"
    /// (RemoteActivityMonitor.swift:41, :54).
    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .local => "Local",
            .remote => |id| id,
        };
    }
};

/// A panel per source, capped. Mac uses a dictionary; a handful of fixed slots
/// is the same thing at this scale and needs no allocator.
const max_monitors: usize = 8;
var open_keys: [max_monitors]?Source = @splat(null);
var open_wins: [max_monitors]?*ActivityMonitor = @splat(null);

/// The slot already showing `src`, if any. Pure — unit-tested.
pub fn slotFor(keys: []const ?Source, src: Source) ?usize {
    for (keys, 0..) |k, i| {
        if (k) |key| if (key.eql(src)) return i;
    }
    return null;
}

/// The first free slot, or null when every slot is taken. Pure — unit-tested.
pub fn freeSlot(keys: []const ?Source) ?usize {
    for (keys, 0..) |k, i| {
        if (k == null) return i;
    }
    return null;
}

// ---------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------

/// One poll's worth of data, built entirely on the worker thread. Everything the
/// rows point at lives in `arena`, so adopting a snapshot is a pointer swap and
/// retiring one is a single `deinit` — no per-string frees to get wrong.
const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    rows: []rows_mod.Row,
    host: remote_protocol.HostMetrics,
    truncated: bool,
    /// This process, the root of the ghoztty-spawned tree for a local source
    /// (`ghostty_local_proc_list` uses the same rule, embedded.zig:3214-3224).
    root_pid: i64,

    fn destroy(self: *Snapshot, alloc: Allocator) void {
        self.arena.deinit();
        alloc.destroy(self);
    }
};

// ---------------------------------------------------------------------
// Instance state
// ---------------------------------------------------------------------

app: *App,
source: Source,
slot: usize,

hwnd: w32.HWND,
filter: w32.HWND,
show_all_btn: w32.HWND,
new_proc_btn: w32.HWND,

/// DPI scale of the panel's own monitor, refreshed on WM_DPICHANGED.
scale: f32 = 1.0,

font: ?*anyopaque = null,
/// Tabular digits for the numeric columns and the gauge readouts. Segoe UI's
/// proportional figures make a 1.5 s-refreshed number jitter sideways; Consolas
/// is the Windows-native answer to Mac's `.monospacedDigit()`.
num_font: ?*anyopaque = null,
title_font: ?*anyopaque = null,
caption_font: ?*anyopaque = null,

/// The adopted snapshot the view renders. Null until the first poll lands.
snap: ?*Snapshot = null,
/// True until the first snapshot arrives (Mac's `isLoading`, :125).
loading: bool = true,

/// Persistent samplers. Touched ONLY by the worker thread (see the header).
proc_sampler: ?remote_proc.ProcSampler = null,
host_sampler: remote_metrics.Sampler = remote_metrics.Sampler.init(),

/// Worker handoff. `pending` is written by the worker and taken by the GUI
/// thread; `sampling` gates a second worker from starting.
pending_mutex: std.Thread.Mutex = .{},
pending: ?*Snapshot = null,
worker: ?std.Thread = null,
sampling: bool = false,

/// Trend rings, oldest -> newest, both 0..100.
cpu_ring: [gauge.ring_capacity]f32 = @splat(0),
mem_ring: [gauge.ring_capacity]f32 = @splat(0),
ring_len: usize = 0,

/// Current view state.
sort: rows_mod.Sort = rows_mod.default_sort,
show_all: bool = false,
needle_buf: [128]u8 = @splat(0),
needle_len: usize = 0,

/// `order[0..order_len]` are indices into `snap.rows`, filtered and sorted.
order: [max_rows]u32 = @splat(0),
order_len: usize = 0,
/// Scratch for `markSpawned`, rebuilt per snapshot.
spawned: [max_rows]bool = @splat(false),

/// Selection keyed by PID, not row index — a row that moves under a re-sort or
/// a re-poll must stay selected (Mac keys its `Set` on `ProcRow.id`, :663-665).
sel_pids: [max_rows]i64 = @splat(0),
sel_len: usize = 0,

/// First visible row, in rows.
scroll: i32 = 0,
/// Row under the pointer, or -1.
hover_row: i32 = -1,
/// True while a WM_MOUSELEAVE request is armed.
tracking_leave: bool = false,
/// Thumb drag: the grab offset inside the thumb, or -1 when not dragging.
thumb_drag_dy: i32 = -1,

/// Set while `close` is unwinding, so a WM_CLOSE arriving from DestroyWindow
/// cannot re-enter it.
closing: bool = false,

// ---------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------

/// Open (or focus) the panel for the LOCAL source. The command-palette entry
/// point, mirroring `RemoteActivityMonitor.openFromPalette` (:132-141), minus
/// the remote-window branch that T287 adds.
pub fn openLocal(window: *Window) void {
    open(window, .local);
}

/// Open (or focus) a panel for `src`.
pub fn open(window: *Window, src: Source) void {
    if (slotFor(&open_keys, src)) |i| {
        if (open_wins[i]) |existing| {
            log.info("activity monitor: focusing existing panel source={s}", .{src.label()});
            _ = w32.ShowWindow(existing.hwnd, w32.SW_SHOW);
            _ = w32.SetForegroundWindow(existing.hwnd);
            _ = w32.SetFocus(existing.filter);
            return;
        }
    }
    const slot = freeSlot(&open_keys) orelse {
        log.warn("activity monitor: no free panel slot", .{});
        return;
    };

    const app = window.app;
    registerClass(app) orelse return;

    const alloc = app.core_app.alloc;
    const self = alloc.create(ActivityMonitor) catch |err| {
        log.warn("activity monitor alloc failed err={}", .{err});
        return;
    };
    self.* = .{
        .app = app,
        .source = src,
        .slot = slot,
        .hwnd = undefined,
        .filter = undefined,
        .show_all_btn = undefined,
        .new_proc_btn = undefined,
        .scale = window.scale,
    };

    // The panel is its own top-level window, not an owned dialog: Mac's is a
    // plain resizable NSWindow the user can put anywhere and leave open behind
    // the terminal (RemoteActivityMonitor.swift:161-165). An owned window could
    // never go behind its owner.
    const style: u32 = w32.WS_OVERLAPPEDWINDOW;
    const d = layout_mod.defaultClient(self.scale);
    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = d.w, .bottom = d.h };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, 0);
    const outer_w = frame.right - frame.left;
    const outer_h = frame.bottom - frame.top;

    var x: i32 = w32.CW_USEDEFAULT;
    var y: i32 = w32.CW_USEDEFAULT;
    if (window.hwnd) |owner| {
        var orect: w32.RECT = undefined;
        if (w32.GetWindowRect(owner, &orect) != 0) {
            x = orect.left + @divTrunc((orect.right - orect.left) - outer_w, 2);
            y = orect.top + @divTrunc((orect.bottom - orect.top) - outer_h, 2);
        }
    }

    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Activity — {s}", .{src.label()}) catch "Activity";
    var wtitle: [160]u16 = undefined;
    const tlen = std.unicode.utf8ToUtf16Le(&wtitle, title) catch 0;
    wtitle[tlen] = 0;

    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        @ptrCast(&wtitle),
        style,
        x,
        y,
        outer_w,
        outer_h,
        null,
        null,
        app.hinstance,
        null,
    ) orelse {
        alloc.destroy(self);
        return;
    };
    self.hwnd = hwnd;

    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    const l = self.layout();

    self.filter = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        l.filter.left,
        l.filter.top,
        l.filter.width(),
        l.filter.height(),
        hwnd,
        @ptrFromInt(@as(usize, FILTER_ID)),
        app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        alloc.destroy(self);
        return;
    };
    _ = w32.SetWindowTheme(self.filter, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    _ = w32.SendMessageW(
        self.filter,
        w32.EM_SETCUEBANNER,
        1,
        @bitCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral("Filter by name or PID"))),
    );

    self.show_all_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("Show all"),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.BS_AUTOCHECKBOX,
        l.show_all.left,
        l.show_all.top,
        l.show_all.width(),
        l.show_all.height(),
        hwnd,
        @ptrFromInt(@as(usize, SHOW_ALL_ID)),
        app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        alloc.destroy(self);
        return;
    };
    _ = w32.SetWindowTheme(self.show_all_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

    self.new_proc_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("New Process…"),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE,
        l.new_proc_btn.left,
        l.new_proc_btn.top,
        l.new_proc_btn.width(),
        l.new_proc_btn.height(),
        hwnd,
        @ptrFromInt(@as(usize, NEW_PROC_ID)),
        app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        alloc.destroy(self);
        return;
    };
    _ = w32.SetWindowTheme(self.new_proc_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    // Enabled by T286, which is the task that gives it something to do.
    _ = w32.EnableWindow(self.new_proc_btn, 0);

    self.createFonts(l);

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    open_keys[slot] = src;
    open_wins[slot] = self;

    log.info("activity monitor: opening source={s} slot={d}", .{ src.label(), slot });

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(self.filter);

    // First poll immediately, then on the interval — a panel that shows nothing
    // for a second and a half reads as broken.
    self.kickSample();
    _ = w32.SetTimer(hwnd, SAMPLE_TIMER_ID, @intCast(gauge.sample_interval_ms), null);
}

/// Tear down: stop the timer, JOIN any in-flight sample (it is writing into
/// memory we are about to free), leave the registry, destroy the window.
pub fn close(self: *ActivityMonitor) void {
    if (self.closing) return;
    self.closing = true;

    _ = w32.KillTimer(self.hwnd, SAMPLE_TIMER_ID);
    if (self.worker) |t| {
        t.join();
        self.worker = null;
    }

    open_keys[self.slot] = null;
    open_wins[self.slot] = null;

    const alloc = self.app.core_app.alloc;
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);

    for ([_]?*anyopaque{ self.font, self.num_font, self.title_font, self.caption_font }) |f| {
        if (f) |h| _ = w32.DeleteObject(h);
    }

    if (self.pending) |p| p.destroy(alloc);
    if (self.snap) |s| s.destroy(alloc);
    if (self.proc_sampler) |*p| p.deinit();

    log.info("activity monitor: closed source={s}", .{self.source.label()});
    alloc.destroy(self);
}

/// Close every open panel. Called on app shutdown so a live sampling thread
/// never outlives the allocator it is writing into.
pub fn closeAll() void {
    for (open_wins) |maybe| {
        if (maybe) |m| m.close();
    }
}

/// The panel owning `hwnd` (itself or one of its controls), for the message
/// loop's key routing.
pub fn owning(hwnd: w32.HWND) ?*ActivityMonitor {
    for (open_wins) |maybe| {
        if (maybe) |m| {
            if (m.ownsHwnd(hwnd)) return m;
        }
    }
    return null;
}

pub fn ownsHwnd(self: *const ActivityMonitor, hwnd: w32.HWND) bool {
    return hwnd == self.hwnd or hwnd == self.filter or
        hwnd == self.show_all_btn or hwnd == self.new_proc_btn;
}

fn createFonts(self: *ActivityMonitor, l: layout_mod.Layout) void {
    self.font = makeFont(l.font_h, 400, "Segoe UI");
    self.num_font = makeFont(l.font_h, 400, "Consolas");
    self.title_font = makeFont(l.title_font_h, 600, "Segoe UI");
    self.caption_font = makeFont(l.caption_font_h, 400, "Segoe UI");
    if (self.font) |f| {
        for ([_]w32.HWND{ self.filter, self.show_all_btn, self.new_proc_btn }) |c| {
            _ = w32.SendMessageW(c, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }
}

fn makeFont(height: i32, weight: i32, comptime face: []const u8) ?*anyopaque {
    return w32.CreateFontW(
        -height,
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(face),
    );
}

fn registerClass(app: *App) ?void {
    if (class_registered) return;
    bg_brush = w32.CreateSolidBrush(COLOR_BG);
    field_brush = w32.CreateSolidBrush(COLOR_FIELD_BG);
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
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
        log.warn("activity monitor class registration failed", .{});
        return null;
    }
    class_registered = true;
}

// ---------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------

/// Start a background sample unless one is already running. Dropping a tick
/// rather than queueing one is deliberate: a machine slow enough to miss a tick
/// must not accumulate a backlog of enumerations.
fn kickSample(self: *ActivityMonitor) void {
    if (self.sampling) return;
    if (self.worker) |t| {
        t.join();
        self.worker = null;
    }
    self.sampling = true;
    self.worker = std.Thread.spawn(.{}, sampleWorker, .{self}) catch |err| {
        log.warn("activity monitor: sample thread spawn failed err={}", .{err});
        self.sampling = false;
        return;
    };
}

fn sampleWorker(self: *ActivityMonitor) void {
    const alloc = self.app.core_app.alloc;
    const snap = self.buildSnapshot(alloc) catch |err| {
        log.warn("activity monitor: sample failed err={}", .{err});
        _ = w32.PostMessageW(self.hwnd, WM_APP_ACTIVITY_SAMPLE, 0, 0);
        return;
    };

    self.pending_mutex.lock();
    if (self.pending) |old| old.destroy(alloc);
    self.pending = snap;
    self.pending_mutex.unlock();

    _ = w32.PostMessageW(self.hwnd, WM_APP_ACTIVITY_SAMPLE, 0, 0);
}

fn buildSnapshot(self: *ActivityMonitor, alloc: Allocator) !*Snapshot {
    const snap = try alloc.create(Snapshot);
    errdefer alloc.destroy(snap);
    snap.* = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .rows = &.{},
        .host = .{},
        .truncated = false,
        .root_pid = selfPid(),
    };
    errdefer snap.arena.deinit();
    const arena = snap.arena.allocator();

    snap.host = self.host_sampler.sample();

    if (self.proc_sampler == null) self.proc_sampler = remote_proc.ProcSampler.init(alloc);
    var procs: std.ArrayListUnmanaged(remote_protocol.Proc) = .empty;
    // The strings come from the arena, so there is nothing to free row by row —
    // retiring the snapshot retires them.
    snap.truncated = try self.proc_sampler.?.sample(arena, &procs, max_rows);

    const rows = try arena.alloc(rows_mod.Row, procs.items.len);
    for (procs.items, 0..) |p, i| {
        rows[i] = .{
            .pid = p.pid,
            .ppid = p.ppid,
            .cpu_pct = p.cpu_pct,
            .mem_bytes = p.mem_bytes,
            .name = p.name,
            .cmd = p.cmd orelse "",
        };
    }
    snap.rows = rows;
    return snap;
}

fn selfPid() i64 {
    if (builtin.os.tag == .windows) {
        const k32 = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
        };
        return @intCast(k32.GetCurrentProcessId());
    }
    return 0;
}

/// GUI thread: adopt whatever the worker parked.
fn adoptPending(self: *ActivityMonitor) void {
    self.sampling = false;

    self.pending_mutex.lock();
    const taken = self.pending;
    self.pending = null;
    self.pending_mutex.unlock();

    const snap = taken orelse return;
    const alloc = self.app.core_app.alloc;
    if (self.snap) |old| old.destroy(alloc);
    self.snap = snap;
    self.loading = false;

    self.pushSample(snap.host);
    self.rebuild();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// Append one point to both trend rings, dropping the oldest when full.
fn pushSample(self: *ActivityMonitor, host: remote_protocol.HostMetrics) void {
    const cpu = std.math.clamp(host.cpu_pct, 0, 100);
    const mem = gauge.memoryPercent(host.mem_used, host.mem_total);
    if (self.ring_len == gauge.ring_capacity) {
        std.mem.copyForwards(f32, self.cpu_ring[0 .. gauge.ring_capacity - 1], self.cpu_ring[1..]);
        std.mem.copyForwards(f32, self.mem_ring[0 .. gauge.ring_capacity - 1], self.mem_ring[1..]);
        self.cpu_ring[gauge.ring_capacity - 1] = cpu;
        self.mem_ring[gauge.ring_capacity - 1] = mem;
        return;
    }
    self.cpu_ring[self.ring_len] = cpu;
    self.mem_ring[self.ring_len] = mem;
    self.ring_len += 1;
}

// ---------------------------------------------------------------------
// View state
// ---------------------------------------------------------------------

fn needle(self: *const ActivityMonitor) []const u8 {
    return self.needle_buf[0..self.needle_len];
}

fn filterSpec(self: *const ActivityMonitor) rows_mod.Filter {
    return .{
        .needle = self.needle(),
        .show_all = self.show_all,
        .root_pid = if (self.snap) |s| s.root_pid else 0,
    };
}

/// Re-derive `order` from the current snapshot, filter and sort, then clamp the
/// scroll. Every input change funnels through here, and it logs the result —
/// that log line is the acceptance script's oracle for what the table shows,
/// since a GDI-painted table has no text to read back.
fn rebuild(self: *ActivityMonitor) void {
    const snap = self.snap orelse {
        self.order_len = 0;
        return;
    };
    const f = self.filterSpec();
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

    self.clampScroll();

    log.info(
        "activity monitor: source={s} total={d} shown={d} needle=\"{s}\" show_all={} sort={s}/{s} selected={d}",
        .{
            self.source.label(),
            snap.rows.len,
            self.order_len,
            self.needle(),
            self.show_all,
            @tagName(self.sort.key),
            if (self.sort.ascending) "asc" else "desc",
            self.sel_len,
        },
    );
}

fn clampScroll(self: *ActivityMonitor) void {
    const l = self.layout();
    const visible = layout_mod.visibleRows(l);
    const max_scroll = @max(0, @as(i32, @intCast(self.order_len)) - visible);
    self.scroll = std.math.clamp(self.scroll, 0, max_scroll);
}

fn isSelected(self: *const ActivityMonitor, pid: i64) bool {
    for (self.sel_pids[0..self.sel_len]) |p| {
        if (p == pid) return true;
    }
    return false;
}

fn clearSelection(self: *ActivityMonitor) void {
    self.sel_len = 0;
}

fn toggleSelection(self: *ActivityMonitor, pid: i64) void {
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

fn selectOnly(self: *ActivityMonitor, pid: i64) void {
    self.sel_len = 1;
    self.sel_pids[0] = pid;
}

/// The row's pid for a display index, or null when the index is out of range.
fn pidAt(self: *const ActivityMonitor, display_index: i32) ?i64 {
    if (display_index < 0) return null;
    const i: usize = @intCast(display_index);
    if (i >= self.order_len) return null;
    const snap = self.snap orelse return null;
    return snap.rows[self.order[i]].pid;
}

// ---------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------

fn layout(self: *const ActivityMonitor) layout_mod.Layout {
    var rc: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &rc) == 0) {
        const d = layout_mod.defaultClient(self.scale);
        return layout_mod.layout(self.scale, d.w, d.h, self.options());
    }
    return layout_mod.layout(self.scale, rc.right - rc.left, rc.bottom - rc.top, self.options());
}

fn options(self: *const ActivityMonitor) layout_mod.Options {
    _ = self; // every band is unconditional until T286/T287 make them state-driven
    return .{
        // One source until T287 adds the switcher, and chrome that controls
        // nothing does not appear (design system §6).
        .has_carousel = false,
        .has_banner = false,
        // The Kill button is T286's; it only exists while rows are selected.
        .has_kill = false,
    };
}

/// Re-place the native controls after a resize or a DPI change.
fn applyLayout(self: *ActivityMonitor) void {
    const l = self.layout();
    _ = w32.MoveWindow(self.filter, l.filter.left, l.filter.top, l.filter.width(), l.filter.height(), 1);
    _ = w32.MoveWindow(self.show_all_btn, l.show_all.left, l.show_all.top, l.show_all.width(), l.show_all.height(), 1);
    _ = w32.MoveWindow(self.new_proc_btn, l.new_proc_btn.left, l.new_proc_btn.top, l.new_proc_btn.width(), l.new_proc_btn.height(), 1);
    self.clampScroll();
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

// ---------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------

fn rect(r: layout_mod.Rect) w32.RECT {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

fn fill(hdc: w32.HDC, r: w32.RECT, color: u32) void {
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(brush);
    var rr = r;
    _ = w32.FillRect(hdc, &rr, brush);
}

fn drawText(hdc: w32.HDC, text: []const u8, r: layout_mod.Rect, flags: u32) void {
    var wbuf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return;
    if (n == 0) return;
    var rr = rect(r);
    _ = w32.DrawTextW(hdc, &wbuf, @intCast(n), &rr, flags | w32.DT_NOPREFIX);
}

const text_flags: u32 = w32.DT_SINGLELINE | w32.DT_VCENTER;

fn paint(self: *ActivityMonitor, hdc: w32.HDC) void {
    const l = self.layout();

    // Double-buffered: the table repaints on every 1.5 s poll, and a direct
    // paint of that many rows flickers.
    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const bmp = w32.CreateCompatibleBitmap(hdc, l.client_w, l.client_h) orelse return;
    defer _ = w32.DeleteObject(bmp);
    const old_bmp = w32.SelectObject(mem_dc, bmp);
    defer _ = w32.SelectObject(mem_dc, old_bmp);

    fill(mem_dc, .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h }, COLOR_BG);
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    self.paintGauges(mem_dc, l);
    self.paintControlBar(mem_dc, l);
    self.paintTable(mem_dc, l);

    // Dividers last so nothing paints over them.
    for ([_]i32{ l.header_divider_y, l.control_divider_y }) |y| {
        fill(mem_dc, .{ .left = 0, .top = y, .right = l.client_w, .bottom = y + 1 }, COLOR_DIVIDER);
    }

    _ = w32.BitBlt(hdc, 0, 0, l.client_w, l.client_h, mem_dc, 0, 0, w32.SRCCOPY);
}

fn paintGauges(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    const host: remote_protocol.HostMetrics = if (self.snap) |s| s.host else .{};

    var vbuf: [48]u8 = undefined;
    var dbuf: [64]u8 = undefined;
    var mbuf: [32]u8 = undefined;

    const cpu_value = rows_mod.formatHostCpu(&vbuf, host.cpu_pct);
    const cpu_detail = std.fmt.bufPrint(&dbuf, "{d} cores", .{host.ncpu}) catch "";
    self.paintGauge(hdc, l, l.gauge_cpu, "CPU", cpu_value, cpu_detail, COLOR_CPU, COLOR_CPU_FILL, self.cpu_ring[0..self.ring_len]);

    var vbuf2: [48]u8 = undefined;
    var dbuf2: [64]u8 = undefined;
    const mem_value = rows_mod.formatMemory(&vbuf2, host.mem_used);
    const mem_detail = std.fmt.bufPrint(&dbuf2, "of {s}", .{rows_mod.formatMemory(&mbuf, host.mem_total)}) catch "";
    self.paintGauge(hdc, l, l.gauge_mem, "Memory", mem_value, mem_detail, COLOR_MEM, COLOR_MEM_FILL, self.mem_ring[0..self.ring_len]);
}

fn paintGauge(
    self: *ActivityMonitor,
    hdc: w32.HDC,
    l: layout_mod.Layout,
    box: layout_mod.Rect,
    title: []const u8,
    value: []const u8,
    detail: []const u8,
    tint: u32,
    fill_tint: u32,
    samples: []const f32,
) void {
    const title_band: layout_mod.Rect = .{
        .left = box.left,
        .top = box.top,
        .right = box.right,
        .bottom = box.top + l.gauge_chart_dy,
    };

    _ = w32.SelectObject(hdc, self.caption_font);
    _ = w32.SetTextColor(hdc, COLOR_SECONDARY);
    drawText(hdc, title, title_band, text_flags | w32.DT_LEFT);
    drawText(hdc, detail, title_band, text_flags | w32.DT_RIGHT);

    // The headline number sits between them, so the eye lands on it first.
    _ = w32.SelectObject(hdc, self.title_font);
    _ = w32.SetTextColor(hdc, COLOR_TEXT);
    drawText(hdc, value, title_band, text_flags | w32.DT_CENTER);

    const chart: layout_mod.Rect = .{
        .left = box.left,
        .top = box.top + l.gauge_chart_dy,
        .right = box.right,
        .bottom = box.bottom,
    };
    fill(hdc, rect(chart), COLOR_CHART_BG);

    var grid: [gauge.gridline_values.len]i32 = undefined;
    gauge.gridlines(chart, &grid);
    for (grid) |y| {
        fill(hdc, .{ .left = chart.left, .top = y, .right = chart.right, .bottom = y + 1 }, COLOR_GRID);
    }

    if (samples.len == 0) return;

    var pts: [gauge.ring_capacity]gauge.Point = undefined;
    const line = gauge.polyline(chart, samples, &pts);
    if (line.len == 0) return;

    // The filled area under the curve, then the curve itself on top of it.
    if (gauge.fillClose(chart, line)) |closers| {
        var poly: [gauge.ring_capacity + 2]w32.POINT = undefined;
        for (line, 0..) |p, i| poly[i] = .{ .x = p.x, .y = p.y };
        poly[line.len] = .{ .x = closers[0].x, .y = closers[0].y };
        poly[line.len + 1] = .{ .x = closers[1].x, .y = closers[1].y };

        const brush = w32.CreateSolidBrush(fill_tint);
        const pen = w32.CreatePen(w32.PS_SOLID, 1, fill_tint);
        if (brush != null and pen != null) {
            const ob = w32.SelectObject(hdc, brush);
            const op = w32.SelectObject(hdc, pen);
            _ = w32.Polygon(hdc, &poly, @intCast(line.len + 2));
            _ = w32.SelectObject(hdc, ob);
            _ = w32.SelectObject(hdc, op);
        }
        if (brush) |b| _ = w32.DeleteObject(b);
        if (pen) |p| _ = w32.DeleteObject(p);
    }

    var wide: [gauge.ring_capacity]w32.POINT = undefined;
    for (line, 0..) |p, i| wide[i] = .{ .x = p.x, .y = p.y };
    const pen = w32.CreatePen(w32.PS_SOLID, @max(1, @as(i32, @intFromFloat(@round(self.scale)))), tint) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old = w32.SelectObject(hdc, pen);
    _ = w32.Polyline(hdc, &wide, @intCast(line.len));
    _ = w32.SelectObject(hdc, old);
}

fn paintControlBar(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    _ = w32.SelectObject(hdc, self.caption_font);

    if (self.snap) |s| {
        if (s.truncated and l.badge.width() > 0) {
            _ = w32.SetTextColor(hdc, COLOR_WARN);
            drawText(hdc, "⚠ List truncated", l.badge, text_flags | w32.DT_LEFT | w32.DT_END_ELLIPSIS);
        }
    }

    var buf: [64]u8 = undefined;
    const total = if (self.snap) |s| s.rows.len else 0;
    const count = rows_mod.formatCount(&buf, self.filterSpec(), self.order_len, total);
    _ = w32.SetTextColor(hdc, COLOR_SECONDARY);
    drawText(hdc, count, l.count, text_flags | w32.DT_RIGHT);
}

fn paintTable(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    const widths = layout_mod.columnWidths(self.scale, l.table.width());

    // Header band.
    fill(hdc, rect(l.table_header), COLOR_HEADER_BG);
    _ = w32.SelectObject(hdc, self.font);
    _ = w32.SetTextColor(hdc, COLOR_LABEL);
    for (layout_mod.column_specs, 0..) |spec, i| {
        const col: layout_mod.Column = @enumFromInt(i);
        const cell = layout_mod.cellRect(l.table_header, widths, col, self.scale);
        const active = @intFromEnum(self.sortKeyColumn()) == i;

        // The sort indicator gets its OWN reserved slot at the cell's trailing
        // edge and the title ellipsizes inside what is left. Appending it to
        // the title string instead put it inside the ellipsis: "% CPU" plus an
        // arrow does not fit the 60-90 DIP CPU column, so DT_END_ELLIPSIS ate
        // the arrow and the panel showed "% CPU…" with no indicator on the very
        // column it was sorted by. Caught in a capture before this shipped.
        const arrow_w: i32 = if (active) sortArrowWidth(self.scale) else 0;
        var title_cell = cell;
        title_cell.right = @max(title_cell.left, title_cell.right - arrow_w);

        const align_flag: u32 = if (spec.right_align) w32.DT_RIGHT else w32.DT_LEFT;
        drawText(hdc, spec.title, title_cell, text_flags | align_flag | w32.DT_END_ELLIPSIS);
        if (active) {
            paintSortArrow(hdc, .{
                .left = cell.right - arrow_w,
                .top = cell.top,
                .right = cell.right,
                .bottom = cell.bottom,
            }, self.sort.ascending, self.scale);
        }
    }
    fill(
        hdc,
        .{ .left = l.table.left, .top = l.table_header.bottom - 1, .right = l.table.right, .bottom = l.table_header.bottom },
        COLOR_DIVIDER,
    );

    const snap = self.snap orelse {
        self.paintEmptyState(hdc, l);
        return;
    };
    if (self.order_len == 0) {
        self.paintEmptyState(hdc, l);
        return;
    }

    const visible = layout_mod.visibleRows(l);
    var i: i32 = 0;
    while (i < visible) : (i += 1) {
        const idx = self.scroll + i;
        if (idx < 0 or @as(usize, @intCast(idx)) >= self.order_len) break;
        const row = snap.rows[self.order[@intCast(idx)]];
        const row_rect: layout_mod.Rect = .{
            .left = l.table.left,
            .top = l.table_rows.top + i * l.row_h,
            .right = l.table.right,
            .bottom = l.table_rows.top + (i + 1) * l.row_h,
        };

        const selected = self.isSelected(row.pid);
        if (selected) {
            fill(hdc, rect(row_rect), COLOR_SELECT);
        } else if (self.hover_row == idx) {
            fill(hdc, rect(row_rect), COLOR_HOVER);
        }

        self.paintRow(hdc, row_rect, widths, row, snap.host.ncpu, selected);
    }

    self.paintScrollThumb(hdc, l, visible);
}

/// The slot the sort indicator reserves at a header cell's trailing edge: the
/// mark plus one `sm` of clearance from the title (§0.1 — nothing touches
/// anything).
fn sortArrowWidth(scale: f32) i32 {
    return @max(8, @as(i32, @intFromFloat(@round(12 * scale))));
}

/// The sort indicator: a FILLED triangle, not a text glyph (§4 — glyphs are
/// filled shapes). Points down for descending, up for ascending, centered in
/// its slot.
fn paintSortArrow(hdc: w32.HDC, box: layout_mod.Rect, ascending: bool, scale: f32) void {
    const half_w = @max(3, @as(i32, @intFromFloat(@round(3.5 * scale))));
    const half_h = @max(2, @as(i32, @intFromFloat(@round(2.0 * scale))));
    const cx = @divTrunc(box.left + box.right, 2);
    const cy = @divTrunc(box.top + box.bottom, 2);
    const tip_y = if (ascending) cy - half_h else cy + half_h;
    const base_y = if (ascending) cy + half_h else cy - half_h;
    var pts = [_]w32.POINT{
        .{ .x = cx - half_w, .y = base_y },
        .{ .x = cx + half_w, .y = base_y },
        .{ .x = cx, .y = tip_y },
    };

    const brush = w32.CreateSolidBrush(COLOR_LABEL) orelse return;
    defer _ = w32.DeleteObject(brush);
    const pen = w32.CreatePen(w32.PS_SOLID, 1, COLOR_LABEL) orelse return;
    defer _ = w32.DeleteObject(pen);
    const ob = w32.SelectObject(hdc, brush);
    const op = w32.SelectObject(hdc, pen);
    _ = w32.Polygon(hdc, &pts, pts.len);
    _ = w32.SelectObject(hdc, ob);
    _ = w32.SelectObject(hdc, op);
}

fn paintRow(
    self: *ActivityMonitor,
    hdc: w32.HDC,
    row_rect: layout_mod.Rect,
    widths: [layout_mod.column_count]i32,
    row: rows_mod.Row,
    ncpu: u32,
    selected: bool,
) void {
    var buf: [32]u8 = undefined;

    _ = w32.SelectObject(hdc, self.num_font);
    _ = w32.SetTextColor(hdc, COLOR_TEXT);
    const pid_text = std.fmt.bufPrint(&buf, "{d}", .{row.pid}) catch "";
    drawText(hdc, pid_text, layout_mod.cellRect(row_rect, widths, .pid, self.scale), text_flags | w32.DT_LEFT);

    var cbuf: [32]u8 = undefined;
    drawText(
        hdc,
        rows_mod.formatCpu(&cbuf, row.cpu_pct, ncpu),
        layout_mod.cellRect(row_rect, widths, .cpu, self.scale),
        text_flags | w32.DT_RIGHT,
    );
    var mbuf: [32]u8 = undefined;
    drawText(
        hdc,
        rows_mod.formatMemory(&mbuf, row.mem_bytes),
        layout_mod.cellRect(row_rect, widths, .mem, self.scale),
        text_flags | w32.DT_RIGHT,
    );

    _ = w32.SelectObject(hdc, self.font);
    drawText(
        hdc,
        if (row.name.len == 0) rows_mod.empty_cell else row.name,
        layout_mod.cellRect(row_rect, widths, .name, self.scale),
        text_flags | w32.DT_LEFT | w32.DT_END_ELLIPSIS,
    );

    // The path is secondary text and ellipsizes in the MIDDLE, so the leaf
    // filename survives (Mac's `.truncationMode(.head)`, :1020).
    //
    // On a SELECTED row it takes the primary color instead: secondary gray on
    // the selection fill is 2.8:1, below §2.3's 4.5:1 text floor. The floor has
    // to be re-checked against the fill a row actually sits on, not against the
    // panel background.
    _ = w32.SetTextColor(hdc, if (selected) COLOR_TEXT else COLOR_SECONDARY);
    drawText(
        hdc,
        if (row.cmd.len == 0) rows_mod.empty_cell else row.cmd,
        layout_mod.cellRect(row_rect, widths, .path, self.scale),
        text_flags | w32.DT_LEFT | w32.DT_PATH_ELLIPSIS,
    );
}

fn paintEmptyState(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    _ = w32.SelectObject(hdc, self.font);
    _ = w32.SetTextColor(hdc, COLOR_SECONDARY);
    const text = if (self.loading) "Loading…" else "No processes match";
    drawText(hdc, text, l.table_rows, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER);
}

/// An overlay thumb on the table's trailing edge — the app's own scrollbar
/// idiom (`Scrollbar.zig`, overlay mode), reusing its pure thumb arithmetic so
/// the panel and the terminal cannot disagree about where a thumb goes.
fn paintScrollThumb(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout, visible: i32) void {
    if (visible <= 0) return;
    if (self.order_len <= @as(usize, @intCast(visible))) return;

    const track_h = l.table_rows.height();
    const t = Scrollbar.thumbRect(
        self.order_len,
        @intCast(self.scroll),
        @intCast(visible),
        track_h,
        thumbMin(self.scale),
    );
    const w = thumbWidth(self.scale);
    fill(hdc, .{
        .left = l.table_rows.right - w,
        .top = l.table_rows.top + t.y,
        .right = l.table_rows.right,
        .bottom = l.table_rows.top + t.y + t.h,
    }, if (self.thumb_drag_dy >= 0) COLOR_THUMB_ACTIVE else COLOR_THUMB);
}

fn thumbWidth(scale: f32) i32 {
    return @max(4, @as(i32, @intFromFloat(@round(8 * scale))));
}

fn thumbMin(scale: f32) i32 {
    return @max(8, @as(i32, @intFromFloat(@round(20 * scale))));
}

/// The layout column the current sort key maps to.
fn sortKeyColumn(self: *const ActivityMonitor) layout_mod.Column {
    return switch (self.sort.key) {
        .pid => .pid,
        .name => .name,
        .cpu => .cpu,
        .mem => .mem,
        .path => .path,
    };
}

/// The sort key a table column maps to. The inverse of `sortKeyColumn`.
pub fn columnSortKey(col: layout_mod.Column) rows_mod.SortKey {
    return switch (col) {
        .pid => .pid,
        .name => .name,
        .cpu => .cpu,
        .mem => .mem,
        .path => .path,
    };
}

/// Which header column contains `x`, given the column widths. Pure —
/// unit-tested.
pub fn columnAt(table: layout_mod.Rect, widths: [layout_mod.column_count]i32, x: i32) ?layout_mod.Column {
    if (x < table.left) return null;
    var left = table.left;
    for (widths, 0..) |w, i| {
        if (x >= left and x < left + w) return @enumFromInt(i);
        left += w;
    }
    return null;
}

// ---------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------

fn onLeftDown(self: *ActivityMonitor, x: i32, y: i32, mods: usize) void {
    const l = self.layout();
    const widths = layout_mod.columnWidths(self.scale, l.table.width());

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
            self.onThumbDrag(y);
            return;
        }
    }

    // Row click: plain replaces the selection, Ctrl toggles, Shift extends from
    // the last selected row (the standard Windows list idiom, and Mac's Table
    // does the same with Cmd/Shift).
    const idx = layout_mod.rowIndexAt(l, y, self.scroll) orelse return;
    const pid = self.pidAt(idx) orelse {
        self.clearSelection();
        _ = w32.InvalidateRect(self.hwnd, null, 0);
        return;
    };
    if (mods & w32.MK_CONTROL != 0) {
        self.toggleSelection(pid);
    } else if (mods & w32.MK_SHIFT != 0 and self.sel_len > 0) {
        self.extendSelectionTo(idx);
    } else {
        self.selectOnly(pid);
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// Shift-click: select every display row between the anchor (the last row added
/// to the selection) and `idx`.
fn extendSelectionTo(self: *ActivityMonitor, idx: i32) void {
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

fn onThumbDrag(self: *ActivityMonitor, y: i32) void {
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

fn onMouseMove(self: *ActivityMonitor, x: i32, y: i32) void {
    if (self.thumb_drag_dy >= 0) {
        self.onThumbDrag(y);
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
    const in_table = x >= l.table.left and x < l.table.right;
    const hovered: i32 = if (in_table)
        (layout_mod.rowIndexAt(l, y, self.scroll) orelse -1)
    else
        -1;
    const clamped: i32 = if (hovered >= 0 and @as(usize, @intCast(hovered)) < self.order_len) hovered else -1;
    if (clamped == self.hover_row) return;
    self.hover_row = clamped;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn onWheel(self: *ActivityMonitor, delta: i16) void {
    const lines: i32 = @divTrunc(@as(i32, delta), @as(i32, w32.WHEEL_DELTA)) * 3;
    self.scroll -= lines;
    self.clampScroll();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// Keyboard, routed from the app's message loop. Returns true when consumed.
///
/// Escape always closes. The table's navigation keys are consumed ONLY when the
/// caret is not in the filter field: Home/End/arrows inside a text box belong to
/// the text box, and eating them there would break the filter's editing for the
/// sake of a table the user is not looking at. (T289 owns the focus RING; this
/// is the routing half, which cannot wait for it without shipping a filter
/// whose Home key does nothing.)
pub fn handleKey(self: *ActivityMonitor, vk: u16) bool {
    if (vk == w32.VK_ESCAPE) {
        self.close();
        return true;
    }
    if (w32.GetFocus()) |focus| {
        if (focus == @as(?w32.HWND, self.filter)) return false;
    }

    const l = self.layout();
    const page: i32 = @max(1, layout_mod.visibleRows(l) - 1);
    switch (vk) {
        w32.VK_UP => {
            self.moveSelection(-1);
            return true;
        },
        w32.VK_DOWN => {
            self.moveSelection(1);
            return true;
        },
        w32.VK_PRIOR => {
            self.moveSelection(-page);
            return true;
        },
        w32.VK_NEXT => {
            self.moveSelection(page);
            return true;
        },
        w32.VK_HOME => {
            self.moveSelectionTo(0);
            return true;
        },
        w32.VK_END => {
            self.moveSelectionTo(@as(i32, @intCast(self.order_len)) - 1);
            return true;
        },
        else => return false,
    }
}

fn moveSelection(self: *ActivityMonitor, delta: i32) void {
    if (self.order_len == 0) return;
    var cur: i32 = -1;
    if (self.sel_len > 0) {
        const pid = self.sel_pids[self.sel_len - 1];
        var i: usize = 0;
        while (i < self.order_len) : (i += 1) {
            if (self.pidAt(@intCast(i)) == pid) {
                cur = @intCast(i);
                break;
            }
        }
    }
    self.moveSelectionTo(if (cur < 0) 0 else cur + delta);
}

fn moveSelectionTo(self: *ActivityMonitor, index: i32) void {
    if (self.order_len == 0) return;
    const clamped = std.math.clamp(index, 0, @as(i32, @intCast(self.order_len)) - 1);
    const pid = self.pidAt(clamped) orelse return;
    self.selectOnly(pid);
    self.scrollIntoView(clamped);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn scrollIntoView(self: *ActivityMonitor, index: i32) void {
    const l = self.layout();
    const visible = layout_mod.visibleRows(l);
    if (visible <= 0) return;
    if (index < self.scroll) self.scroll = index;
    if (index >= self.scroll + visible) self.scroll = index - visible + 1;
    self.clampScroll();
}

fn onFilterChanged(self: *ActivityMonitor) void {
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(self.filter, &wbuf, wbuf.len));
    const n = std.unicode.utf16LeToUtf8(&self.needle_buf, wbuf[0..wlen]) catch 0;
    self.needle_len = @min(n, self.needle_buf.len);
    self.scroll = 0;
    self.rebuild();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

// ---------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *ActivityMonitor = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_ERASEBKGND => return 1, // WM_PAINT covers the whole client
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            self.paint(hdc);
            _ = w32.EndPaint(hwnd, &ps);
            return 0;
        },
        w32.WM_SIZE => {
            self.applyLayout();
            return 0;
        },
        w32.WM_GETMINMAXINFO => {
            const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const min = layout_mod.minClient(self.scale);
            var frame: w32.RECT = .{ .left = 0, .top = 0, .right = min.w, .bottom = min.h };
            _ = w32.AdjustWindowRectEx(&frame, w32.WS_OVERLAPPEDWINDOW, 0, 0);
            mmi.ptMinTrackSize = .{ .x = frame.right - frame.left, .y = frame.bottom - frame.top };
            return 0;
        },
        w32.WM_DPICHANGED => {
            self.scale = @as(f32, @floatFromInt(@as(u16, @intCast(wparam & 0xFFFF)))) / 96.0;
            const suggested: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = w32.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
            );
            for ([_]?*anyopaque{ self.font, self.num_font, self.title_font, self.caption_font }) |f| {
                if (f) |h| _ = w32.DeleteObject(h);
            }
            self.createFonts(self.layout());
            self.applyLayout();
            return 0;
        },
        w32.WM_TIMER => {
            if (wparam == SAMPLE_TIMER_ID) {
                self.kickSample();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_APP_ACTIVITY_SAMPLE => {
            self.adoptPending();
            return 0;
        },
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (control_id == FILTER_ID and notification == w32.EN_CHANGE) {
                self.onFilterChanged();
                return 0;
            }
            if (control_id == SHOW_ALL_ID and notification == w32.BN_CLICKED) {
                self.show_all = w32.SendMessageW(self.show_all_btn, w32.BM_GETCHECK, 0, 0) == @as(isize, @intCast(w32.BST_CHECKED));
                self.scroll = 0;
                self.rebuild();
                _ = w32.InvalidateRect(hwnd, null, 0);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_LBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            self.onLeftDown(loWordSigned(lparam), hiWordSigned(lparam), wparam);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (self.thumb_drag_dy >= 0) {
                self.thumb_drag_dy = -1;
                _ = w32.ReleaseCapture();
                _ = w32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            self.onMouseMove(loWordSigned(lparam), hiWordSigned(lparam));
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            if (self.hover_row != -1) {
                self.hover_row = -1;
                _ = w32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            self.onWheel(@bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF))));
            return 0;
        },
        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_FIELD_BG);
            if (field_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_LABEL);
            _ = w32.SetBkColor(hdc, COLOR_BG);
            if (bg_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            self.close();
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn loWordSigned(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF))));
}

fn hiWordSigned(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
}

// ---------------------------------------------------------------------
// Tests (pure logic only)
// ---------------------------------------------------------------------

const testing = std.testing;

test "Source.eql: local matches local, remotes match by id" {
    try testing.expect(Source.eql(.local, .local));
    try testing.expect(!Source.eql(.local, .{ .remote = "winbox" }));
    try testing.expect(Source.eql(.{ .remote = "winbox" }, .{ .remote = "winbox" }));
    try testing.expect(!Source.eql(.{ .remote = "winbox" }, .{ .remote = "laptop" }));
}

test "slotFor: a second open of the same source finds the open panel" {
    var keys = [_]?Source{ null, null, null };
    try testing.expect(slotFor(&keys, .local) == null);

    keys[0] = .local;
    try testing.expectEqual(@as(?usize, 0), slotFor(&keys, .local));
    // A different source is NOT the same panel — that is the whole point of
    // keying the registry rather than keeping one global window.
    try testing.expect(slotFor(&keys, .{ .remote = "winbox" }) == null);

    keys[1] = .{ .remote = "winbox" };
    try testing.expectEqual(@as(?usize, 1), slotFor(&keys, .{ .remote = "winbox" }));
}

test "freeSlot: the first hole, and null when full" {
    var keys = [_]?Source{ .local, null, .{ .remote = "a" } };
    try testing.expectEqual(@as(?usize, 1), freeSlot(&keys));

    keys[1] = .{ .remote = "b" };
    try testing.expect(freeSlot(&keys) == null);

    // A closed panel frees its slot for reuse.
    keys[0] = null;
    try testing.expectEqual(@as(?usize, 0), freeSlot(&keys));
}

test "columnAt: every column hits, and the gutters outside the table miss" {
    const table: layout_mod.Rect = .{ .left = 10, .top = 0, .right = 210, .bottom = 100 };
    const widths = [layout_mod.column_count]i32{ 20, 40, 30, 50, 60 };

    try testing.expect(columnAt(table, widths, 5) == null); // left of the table
    try testing.expectEqual(layout_mod.Column.pid, columnAt(table, widths, 10).?);
    try testing.expectEqual(layout_mod.Column.pid, columnAt(table, widths, 29).?);
    try testing.expectEqual(layout_mod.Column.name, columnAt(table, widths, 30).?);
    try testing.expectEqual(layout_mod.Column.cpu, columnAt(table, widths, 70).?);
    try testing.expectEqual(layout_mod.Column.mem, columnAt(table, widths, 100).?);
    try testing.expectEqual(layout_mod.Column.path, columnAt(table, widths, 150).?);
    try testing.expectEqual(layout_mod.Column.path, columnAt(table, widths, 209).?);
    try testing.expect(columnAt(table, widths, 210) == null); // past the last column
}

test "columnSortKey round-trips every column" {
    // A header click maps a column to a sort key; the arrow maps it back. The
    // two must agree, or the arrow lands on a different column than the one the
    // table is ordered by.
    for (0..layout_mod.column_count) |i| {
        const col: layout_mod.Column = @enumFromInt(i);
        const key = columnSortKey(col);
        const back: layout_mod.Column = switch (key) {
            .pid => .pid,
            .name => .name,
            .cpu => .cpu,
            .mem => .mem,
            .path => .path,
        };
        try testing.expectEqual(col, back);
    }
}
