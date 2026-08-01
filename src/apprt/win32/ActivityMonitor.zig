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
//! ## Process control (T286)
//! Kill and New Process run against `remote/agent/proc_control.zig` and
//! `proc_spawn.zig` — the same two functions the agent's remote provider calls,
//! so a local panel and a remote one cannot drift. Both are destructive or
//! creative enough to be MODAL: `ConfirmDialog` / `NewProcessDialog` run a
//! nested pump, and `modal` blocks snapshot adoption for its duration, so a poll
//! landing mid-dialog cannot free the snapshot whose row names the confirmation
//! is quoting. All wording, the failure aggregation, the empty state and the
//! selection pruning are pure in `activity_actions.zig`.
//!
//! ## Remote sources (T295)
//! A `.remote` panel samples through a `remote.Connection`, and who OWNS that
//! connection is the whole design (Mac's `RemoteActivityMonitor.swift:8-16`):
//!
//! - **Dialed** (the chooser's Activity button) — the panel dials a fresh relay
//!   connection and owns it, so `close` frees it.
//! - **Reused** (the palette on a remote window) — the panel borrows the
//!   WINDOW's connection and must never free it; closing the panel cannot be
//!   allowed to take that window's session down with it.
//!
//! The dial blocks through a handshake, so it runs on a detached thread and
//! lands via `WM_APP_ACTIVITY_DIALED` on the APP's message-only window, not on
//! the panel's. That is the difference between a result that always arrives and
//! one that Windows silently discards: `DestroyWindow` drops a window's queued
//! messages, so a dial posted to a panel that closes first would leak the
//! connection it just opened. The app's window outlives every panel, and the
//! `(slot, serial)` pair tells it whether the panel that asked is still there.
//!
//! Host CPU% comes from the pushed `metrics` stream, NOT from the snapshot: the
//! agent builds `PROC_SNAPSHOT.host` from a fresh sampler with no prior tick and
//! says so at `agent/server.zig:1607`. Reading that as CPU% would paint a
//! confident flat zero.
//!
//! ## The machine carousel (T296)
//! Once open, the panel moves to any other source in ONE click, without opening
//! a second window (Mac's `RemoteActivityMonitorModel.switchTo`,
//! RemoteActivityMonitorView.swift:307). Three parts:
//!
//! - **The list.** Mac reads a local `MachineRegistry`; Windows' machine list is
//!   the relay directory, and `relay_directory.listDevices` is a synchronous
//!   authenticated HTTPS GET. The chooser can afford that on the GUI thread
//!   because it is a modal dialog with a spinner; a non-modal panel cannot, so
//!   the fetch runs on a detached thread and lands as
//!   `WM_APP_ACTIVITY_MACHINES` on the APP's message-only window — the same
//!   outlives-the-panel reasoning as the dial.
//! - **The cards.** `activity_cards.zig` owns the ordering (Local first), the
//!   three lines of text, the status dot and the focus arithmetic. The ACTIVE
//!   source always gets a card even when the directory does not list it (a
//!   borrowed connection, a signed-out account, a machine deleted while the
//!   panel is open) — a carousel that cannot show you where you are is lying.
//! - **The switch.** `switchTo` tears the current source down, resets every
//!   view field so one machine's trend history can never bleed into another's,
//!   and starts the new one. It BUMPS `serial`, which is what makes an
//!   in-flight dial for the abandoned source land on `onDialed`'s
//!   panel-is-gone path and free itself instead of being adopted under the new
//!   machine's name.
//!
//! A sample worker started for the previous source is dropped by GENERATION
//! (`source_gen`), not by joining: joining a worker parked on a BORROWED
//! connection would freeze the GUI for up to `rpc_timeout_ns`, and a borrowed
//! connection cannot be `shutdown` to cut it short — it is a live window's
//! shell.
//!
//! ## What is NOT here
//! Live per-card metrics for INACTIVE machines (Mac's `MachineMetricsProbe`,
//! :153-155) — that dials every registered machine and holds a metrics
//! subscription on each, which is its own connection-budget design. Inactive
//! remote cards report the relay directory's online flag and say so; they do
//! not invent a reading.

const ActivityMonitor = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const layout_mod = @import("activity_layout.zig");
const rows_mod = @import("activity_rows.zig");
const cards_mod = @import("activity_cards.zig");
const actions = @import("activity_actions.zig");
const gauge = @import("trend_gauge.zig");
const icon_button = @import("icon_button.zig");
const icon_button_paint = @import("icon_button_paint.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const NewProcessDialog = @import("NewProcessDialog.zig");
const Scrollbar = @import("Scrollbar.zig");
const remote_proc = @import("../../remote/agent/proc.zig");
const remote_metrics = @import("../../remote/agent/metrics.zig");
const remote_protocol = @import("../../remote/protocol.zig");
const proc_control = @import("../../remote/agent/proc_control.zig");
const proc_spawn = @import("../../remote/agent/proc_spawn.zig");
const remote_connection = @import("../../remote/connection.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const IpcHandlers = @import("IpcHandlers.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyActivityMonitor");

const FILTER_ID: u16 = 100;
const SHOW_ALL_ID: u16 = 101;
const NEW_PROC_ID: u16 = 102;
const KILL_ID: u16 = 103;

/// The poll timer. `trend_gauge.sample_interval_ms` is the interval the ring was
/// sized for, so the ring really does hold ~90 s.
const SAMPLE_TIMER_ID: usize = 1;

/// A worker thread finished a sample and parked it in `pending`. WM_APP+1..+12
/// are taken (see App.zig / Window.zig / ClaudeIntegration.zig / RelayAccountRow.zig).
pub const WM_APP_ACTIVITY_SAMPLE: u32 = w32.WM_APP + 13;

/// A dial thread finished. Posted to the APP's message-only window (see the
/// header), `wparam` = a heap `*DialResult` the handler owns.
pub const WM_APP_ACTIVITY_DIALED: u32 = w32.WM_APP + 14;

/// A machine-list fetch finished. Same landing rules as the dial: the APP's
/// window, `wparam` = a heap `*MachineListResult` the handler owns.
pub const WM_APP_ACTIVITY_MACHINES: u32 = w32.WM_APP + 15;

/// Bound on every remote RPC the panel makes. A machine slow enough to miss
/// this is a machine the panel should report as unreachable rather than freeze
/// its worker on.
const rpc_timeout_ns: u64 = 5 * std.time.ns_per_s;

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
/// The action-error banner's fill: Mac's `.orange.opacity(0.12)`
/// (RemoteActivityMonitorView.swift:1077) composited onto `COLOR_BG` — GDI has
/// no alpha here, so the blend is precomputed. Warning text on it reads 6.1:1
/// and the message text 10.6:1, both past design system §2.3's floors.
const COLOR_BANNER_BG = w32.RGB(56, 47, 35);
/// The overlay scroll thumb, at rest and while grabbed.
const COLOR_THUMB = w32.RGB(90, 90, 90);
const COLOR_THUMB_ACTIVE = w32.RGB(130, 130, 130);

// --- Machine cards (T296) --------------------------------------------
// Every number here is checked against design system §2.3's non-text floor
// (3:1 for a boundary that carries meaning, 4.5:1 for text), on BOTH the rest
// fill and the selected fill — a card is a control, and its border is what
// tells the user where the click target is.
/// Card fill at rest / under the pointer.
const COLOR_CARD_BG = w32.RGB(44, 44, 44);
const COLOR_CARD_HOVER = w32.RGB(56, 56, 56);
/// The resting border: 3.6:1 on the card fill and 4.2:1 on the panel.
const COLOR_CARD_BORDER = w32.RGB(130, 130, 130);
/// The active card: Mac's accent fill + accent border. The border reads 3.1:1
/// against its own fill and 5.9:1 against the panel.
const COLOR_CARD_SELECT_BG = COLOR_SELECT;
const COLOR_ACCENT = w32.RGB(80, 160, 235);
/// Secondary text has to brighten on the accent fill: `COLOR_SECONDARY` is
/// 4.7:1 on the resting card but only 2.9:1 on the selected one, which is under
/// the 4.5:1 floor. Same role, two surfaces, two values.
const COLOR_CARD_SECONDARY = COLOR_SECONDARY;
const COLOR_CARD_SECONDARY_SEL = w32.RGB(190, 205, 225);
/// Status dots. Green/amber/red are the same three states Mac paints, plus a
/// neutral for "the directory says offline and we have not dialed it".
const COLOR_DOT_GOOD = w32.RGB(90, 200, 120);
const COLOR_DOT_PENDING = w32.RGB(225, 180, 80);
const COLOR_DOT_BAD = w32.RGB(230, 100, 100);
const COLOR_DOT_UNKNOWN = COLOR_SECONDARY;

var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;
var field_brush: ?w32.HBRUSH = null;

// ---------------------------------------------------------------------
// Source + registry
// ---------------------------------------------------------------------

/// A machine a panel can be pointed at: identity for the registry, display name
/// for the chrome. Mac keys its window dictionary on the `Machine` and titles
/// the window from `machine.name` (RemoteActivityMonitor.swift:41), which is the
/// same split — a rename must not open a second panel on the same machine.
pub const Remote = struct {
    id: []const u8,
    name: []const u8 = "",
};

/// Longest machine id / display name a panel copies in. Both are held in the
/// instance (see `id_buf`), because the caller's copy is usually borrowed from a
/// chooser arena that is freed before the panel opens.
pub const max_source_id: usize = 128;
pub const max_source_label: usize = 128;

/// What a panel is showing. The remote source's DATA plane is T287; what exists
/// here is the identity, so the registry is keyed correctly rather than being
/// retrofitted onto a `.local`-only assumption.
pub const Source = union(enum) {
    local,
    remote: Remote,

    pub fn eql(a: Source, b: Source) bool {
        return switch (a) {
            .local => b == .local,
            .remote => |ra| switch (b) {
                .local => false,
                .remote => |rb| std.mem.eql(u8, ra.id, rb.id),
            },
        };
    }

    /// The window title's subject — Mac titles the window "Activity — <label>"
    /// (RemoteActivityMonitor.swift:41, :54). The id is the fallback: a machine
    /// with no name still has to be namable on screen.
    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .local => "Local",
            .remote => |r| if (r.name.len > 0) r.name else r.id,
        };
    }
};

/// A panel per source, capped. Mac uses a dictionary; a handful of fixed slots
/// is the same thing at this scale and needs no allocator.
const max_monitors: usize = 8;
var open_keys: [max_monitors]?Source = @splat(null);
var open_wins: [max_monitors]?*ActivityMonitor = @splat(null);

/// Handed to each panel at open so an in-flight dial can tell "my panel is
/// still there" from "a DIFFERENT panel took my slot after mine closed". A slot
/// index alone cannot: slots are reused the moment they are freed.
var next_serial: u64 = 1;

/// The panel occupying `slot` iff it is still the one that owns `serial`. Pure —
/// unit-tested against the slot-reuse case that motivates the serial.
pub fn panelMatches(serials: []const ?u64, slot: usize, serial: u64) bool {
    if (slot >= serials.len) return false;
    const s = serials[slot] orelse return false;
    return s == serial;
}

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
// Remote connection
// ---------------------------------------------------------------------

/// The connection a remote panel samples through, and who owns it.
///
/// `dialed != null` ⇒ this panel dialed it and MUST tear it down on close.
/// `dialed == null` ⇒ borrowed from a remote window (Mac's `ownsConnection:
/// false`), and closing the panel must leave that window's session untouched.
const RemoteConn = struct {
    conn: *remote_connection.Connection,
    dialed: ?*relay_dial.Dialed = null,

    fn owned(self: RemoteConn) bool {
        return self.dialed != null;
    }
};

/// A finished dial, in flight to the GUI thread as `WM_APP_ACTIVITY_DIALED`'s
/// `wparam`. Owned by the handler, which frees it.
pub const DialResult = struct {
    alloc: Allocator,
    /// Which panel asked, and which incarnation of that slot.
    slot: usize,
    serial: u64,
    /// The dialed transport, or null when the dial failed.
    dialed: ?*relay_dial.Dialed,

    /// Free the result AND anything it still owns. Called when the panel that
    /// asked is gone — otherwise the panel adopts `dialed` first.
    fn destroy(self: *DialResult) void {
        const alloc = self.alloc;
        if (self.dialed) |d| {
            d.deinit();
            alloc.destroy(d);
        }
        alloc.destroy(self);
    }
};

/// Everything the dial thread needs, heap-owned so it outlives the call that
/// spawned it. The thread frees it.
const DialRequest = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    slot: usize,
    serial: u64,
    base: []u8,
    device: []u8,
    token: []u8,

    fn destroy(self: *DialRequest) void {
        const alloc = self.alloc;
        alloc.free(self.base);
        alloc.free(self.device);
        alloc.free(self.token);
        alloc.destroy(self);
    }
};

// ---------------------------------------------------------------------
// Machine list (the carousel's sources)
// ---------------------------------------------------------------------

/// Machines the carousel offers besides Local. `activity_cards.max_cards`
/// counts Local, so this is one fewer.
pub const max_machines: usize = cards_mod.max_cards - 1;

/// One machine, held BY VALUE. The relay's parsed device list lives in an arena
/// that is freed the moment the fetch returns, and the panel outlives every
/// fetch — so nothing here may be a slice into somebody else's memory. Fixed
/// buffers also make the whole result one flat heap object to hand between
/// threads, with no arena to keep alive and no per-string free to get wrong.
pub const MachineEntry = struct {
    id: [max_source_id]u8 = @splat(0),
    id_len: usize = 0,
    name: [max_source_label]u8 = @splat(0),
    name_len: usize = 0,
    /// The directory's own liveness flag — what an INACTIVE card reports,
    /// because the panel has not dialed that machine and will not pretend it
    /// has.
    online: bool = false,

    fn idSlice(self: *const MachineEntry) []const u8 {
        return self.id[0..self.id_len];
    }

    fn nameSlice(self: *const MachineEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Copy one device in, truncating rather than refusing: a machine with an
    /// absurd id is still switchable, and the id is only ever compared against
    /// another copy of itself.
    fn set(self: *MachineEntry, id: []const u8, name: []const u8, online: bool) void {
        self.id_len = @min(id.len, self.id.len);
        @memcpy(self.id[0..self.id_len], id[0..self.id_len]);
        self.name_len = @min(name.len, self.name.len);
        @memcpy(self.name[0..self.name_len], name[0..self.name_len]);
        self.online = online;
    }
};

/// A finished machine-list fetch, in flight to the GUI thread. Owned by the
/// handler, which frees it.
pub const MachineListResult = struct {
    alloc: Allocator,
    slot: usize,
    serial: u64,
    count: usize = 0,
    entries: [max_machines]MachineEntry = @splat(.{}),

    fn destroy(self: *MachineListResult) void {
        self.alloc.destroy(self);
    }
};

/// Everything the list thread needs, heap-owned so it outlives the call that
/// spawned it. The thread frees it.
const MachineListRequest = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    slot: usize,
    serial: u64,
    base: []u8,
    token: []u8,

    fn destroy(self: *MachineListRequest) void {
        const alloc = self.alloc;
        alloc.free(self.base);
        alloc.free(self.token);
        alloc.destroy(self);
    }
};

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
/// What this panel is showing. For a remote source its strings point into
/// `id_buf`/`name_buf` below, never at the caller's memory: the chooser that
/// opens the panel frees its device list on the way out (T177).
source: Source,
id_buf: [max_source_id]u8 = undefined,
name_buf: [max_source_label]u8 = undefined,
slot: usize,
/// This panel's identity within `slot`, for a dial landing after it closed.
serial: u64,

hwnd: w32.HWND,
filter: w32.HWND,
show_all_btn: w32.HWND,
new_proc_btn: w32.HWND,
/// Shown only while rows are selected (Mac's `if !selectedRows.isEmpty`), which
/// is also what `Options.has_kill` drives — so the button and the geometry that
/// makes room for it can never disagree.
kill_btn: w32.HWND,

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

/// Persistent samplers for the LOCAL source. Touched ONLY by the worker thread
/// (see the header).
proc_sampler: ?remote_proc.ProcSampler = null,
host_sampler: remote_metrics.Sampler = remote_metrics.Sampler.init(),

/// The connection a `.remote` panel samples through, null until a dial lands
/// (and forever, if it fails). Set and cleared on the GUI thread only, while no
/// sample worker is running — `dialing` keeps the timer from starting one.
remote_conn: ?RemoteConn = null,
/// A dial is in flight. Suspends sampling (there is nothing to sample yet) and
/// makes the overlay say "Connecting…" rather than "Couldn't connect".
dialing: bool = false,
/// The newest pushed host-metrics reading, or null before the first one.
/// Written by the connection's control-reader thread, read by the sample
/// worker — hence its own mutex.
metrics_mutex: std.Thread.Mutex = .{},
last_metrics: ?remote_protocol.HostMetrics = null,

/// The machines the carousel can switch to, and the cards derived from them.
/// `cards` slices point into `machines` (stable for the panel's life) or into
/// `id_buf`/`name_buf` for the active source — never at a fetch's arena.
machines: [max_machines]MachineEntry = @splat(.{}),
machine_count: usize = 0,
cards: [cards_mod.max_cards]cards_mod.Card = @splat(.{ .local = true, .label = "Local" }),
card_count: usize = 0,
/// The keyboard focus ring. Arrowing moves this and NOTHING else — a carousel
/// that dialed on focus would open a connection per keystroke.
card_focus: i32 = 0,
carousel_scroll: i32 = 0,
/// Card under the pointer, or -1.
card_hover: i32 = -1,

/// Bumped on every source switch. A sample worker started for the previous
/// source tags its result with the generation it began under, and a result from
/// an older generation is dropped rather than adopted under the new machine's
/// name.
source_gen: u32 = 0,

/// Worker handoff. `pending` is written by the worker and taken by the GUI
/// thread; `sampling` gates a second worker from starting.
pending_mutex: std.Thread.Mutex = .{},
pending: ?*Snapshot = null,
/// The generation the parked sample was taken under. Read with `pending`.
pending_gen: u32 = 0,
/// The worker's verdict on the sample it just posted, taken with `pending`. A
/// failed sample posts with no snapshot, so this is the only way the GUI thread
/// learns the difference between "nothing new" and "the source is unreachable".
pending_failed: bool = false,
worker: ?std.Thread = null,
sampling: bool = false,

/// The last sample failed (Mac's `lastRefreshFailed`). Drives the "Refresh
/// failed" badge over a stale table and the "Couldn't connect" overlay over an
/// empty one.
refresh_failed: bool = false,

/// A modal dialog owned by this panel is pumping. Snapshot adoption is
/// SUSPENDED for its duration: the confirmation quotes row names borrowed from
/// `snap`, and adopting a new snapshot mid-dialog would free them under it. The
/// deferred sample is adopted the moment the dialog returns.
modal: bool = false,

/// The action-error banner's text (Mac's `actionError`), empty when absent.
err_buf: [256]u8 = @splat(0),
err_len: usize = 0,

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

/// Whether a sample failure has already been logged for this panel. Worker
/// thread only.
logged_sample_error: bool = false,

// ---------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------

/// Open (or focus) the panel for the LOCAL source
/// (`RemoteActivityMonitor.presentLocal`).
pub fn openLocal(window: *Window) void {
    open(window, .local);
}

/// Open (or focus) a panel for `src`, DIALING its own connection if `src` is
/// remote (`RemoteActivityMonitor.presentDialing`). The panel owns what it
/// dials and frees it on close.
pub fn open(window: *Window, src: Source) void {
    openInner(window, src, null);
}

/// Open (or focus) a panel for `src` on an EXISTING connection this panel does
/// NOT own (`RemoteActivityMonitor.presentReusing`). `conn` belongs to the
/// remote window the user invoked this from; closing the panel must leave that
/// window's session running, so the panel borrows and never frees it.
pub fn openReusing(window: *Window, src: Source, conn: *remote_connection.Connection) void {
    openInner(window, src, conn);
}

fn openInner(window: *Window, src: Source, borrow: ?*remote_connection.Connection) void {
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
        .serial = next_serial,
        .hwnd = undefined,
        .filter = undefined,
        .show_all_btn = undefined,
        .new_proc_btn = undefined,
        .kill_btn = undefined,
        .scale = window.scale,
    };
    next_serial += 1;
    // Take ownership of a remote source's strings: the caller's copies belong to
    // a chooser that is already closing (T177). Over-long ids are truncated
    // rather than refused — the panel still opens, and the id is only ever
    // compared against another copy of itself.
    if (src == .remote) {
        const id_len = @min(src.remote.id.len, self.id_buf.len);
        const name_len = @min(src.remote.name.len, self.name_buf.len);
        @memcpy(self.id_buf[0..id_len], src.remote.id[0..id_len]);
        @memcpy(self.name_buf[0..name_len], src.remote.name[0..name_len]);
        self.source = .{ .remote = .{
            .id = self.id_buf[0..id_len],
            .name = self.name_buf[0..name_len],
        } };
    }

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

    var title_buf: [192]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Activity — {s}", .{self.source.label()}) catch "Activity";
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

    // Kill: created HIDDEN, since nothing is selected yet. Mac omits the button
    // entirely while the selection is empty; a win32 child is created once and
    // shown/hidden, which is the same thing to the user and keeps the control
    // out of the tab order while it is not actionable.
    self.kill_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("Kill"),
        w32.WS_CHILD,
        l.kill_btn.left,
        l.kill_btn.top,
        l.kill_btn.width(),
        l.kill_btn.height(),
        hwnd,
        @ptrFromInt(@as(usize, KILL_ID)),
        app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        alloc.destroy(self);
        return;
    };
    _ = w32.SetWindowTheme(self.kill_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

    self.createFonts(l);

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // The registry key points at the INSTANCE's copy, so it stays valid for as
    // long as the slot is taken.
    open_keys[slot] = self.source;
    open_wins[slot] = self;

    log.info("activity monitor: opening source={s} slot={d}", .{ self.source.label(), slot });

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(self.filter);

    // Wire the source's data plane BEFORE the first poll: a remote panel that
    // samples before its connection exists just burns a tick reporting failure.
    if (src == .remote) {
        if (borrow) |conn| {
            self.remote_conn = .{ .conn = conn, .dialed = null };
            self.beginMetrics();
            log.info("activity monitor: reusing caller's connection source={s}", .{self.source.label()});
        } else {
            self.startDial();
        }
    }

    // The carousel starts with what we know for free — Local, plus the active
    // source when it is a machine — so a remote panel can always get home even
    // if the directory fetch never answers. The fetch then fills in the rest.
    self.rebuildCards();
    self.startMachineList();

    // First poll immediately, then on the interval — a panel that shows nothing
    // for a second and a half reads as broken. `kickSample` is a no-op while a
    // dial is in flight.
    self.kickSample();
    _ = w32.SetTimer(hwnd, SAMPLE_TIMER_ID, @intCast(gauge.sample_interval_ms), null);
}

// ---------------------------------------------------------------------
// Dialing
// ---------------------------------------------------------------------

/// Kick off a relay dial for this panel's remote source on a detached thread.
/// The credentials are resolved HERE, on the GUI thread, because that is where
/// the account store lives; the blocking part (TCP + TLS + WebSocket upgrade +
/// HELLO) is all the thread does.
fn startDial(self: *ActivityMonitor) void {
    const alloc = self.app.core_app.alloc;
    const msg_hwnd = self.app.msg_hwnd orelse {
        log.warn("activity monitor: no message window, cannot dial", .{});
        self.refresh_failed = true;
        self.loading = false;
        return;
    };

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token = IpcHandlers.resolveToken(arena) orelse {
        // Mac's WP-B2 rule: signed out is not an error dialog here, it is a
        // source that cannot be reached.
        log.warn("activity monitor: no relay credential (signed out) source={s}", .{self.source.label()});
        self.refresh_failed = true;
        self.loading = false;
        return;
    };
    const base = relay_directory.resolveBase(arena) catch {
        self.refresh_failed = true;
        self.loading = false;
        return;
    };

    const req = alloc.create(DialRequest) catch return;
    req.* = .{
        .alloc = alloc,
        .hwnd = msg_hwnd,
        .slot = self.slot,
        .serial = self.serial,
        .base = alloc.dupe(u8, base) catch {
            alloc.destroy(req);
            return;
        },
        .device = undefined,
        .token = undefined,
    };
    req.device = alloc.dupe(u8, self.source.remote.id) catch {
        alloc.free(req.base);
        alloc.destroy(req);
        return;
    };
    req.token = alloc.dupe(u8, token) catch {
        alloc.free(req.base);
        alloc.free(req.device);
        alloc.destroy(req);
        return;
    };

    const thread = std.Thread.spawn(.{}, dialWorker, .{req}) catch |err| {
        log.warn("activity monitor: dial thread spawn failed err={}", .{err});
        req.destroy();
        self.refresh_failed = true;
        self.loading = false;
        return;
    };
    thread.detach();

    self.dialing = true;
    log.info("activity monitor: dialing source={s} slot={d}", .{ self.source.label(), self.slot });
}

/// The detached dial. Owns `req`; hands its outcome to the GUI thread as a
/// `*DialResult`, which the handler owns from that moment on.
fn dialWorker(req: *DialRequest) void {
    defer req.destroy();
    const alloc = req.alloc;

    var dialed: ?*relay_dial.Dialed = null;
    if (alloc.create(relay_dial.Dialed)) |d| {
        if (relay_dial.dial(alloc, req.base, req.device, req.token, .raw)) |ok| {
            d.* = ok;
            dialed = d;
        } else |err| {
            log.warn("activity monitor: dial failed device={s} err={}", .{ req.device, err });
            alloc.destroy(d);
        }
    } else |_| {}

    const res = alloc.create(DialResult) catch {
        if (dialed) |d| {
            d.deinit();
            alloc.destroy(d);
        }
        return;
    };
    res.* = .{
        .alloc = alloc,
        .slot = req.slot,
        .serial = req.serial,
        .dialed = dialed,
    };
    if (w32.PostMessageW(req.hwnd, WM_APP_ACTIVITY_DIALED, @intFromPtr(res), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        res.destroy();
    }
}

/// GUI thread (App.msgWndProc): a dial finished. Takes ownership of `res`.
pub fn onDialed(res: *DialResult) void {
    var serials: [max_monitors]?u64 = @splat(null);
    for (open_wins, 0..) |maybe, i| {
        if (maybe) |p| {
            if (!p.closing) serials[i] = p.serial;
        }
    }

    if (panelMatches(&serials, res.slot, res.serial)) {
        open_wins[res.slot].?.adoptDial(res.dialed);
        res.dialed = null; // adopted (or mourned) by the panel
        res.destroy();
        return;
    }

    // The panel that asked is gone. Freeing here is the whole reason this
    // lands on the app's window instead of the panel's.
    log.info("activity monitor: dial landed after its panel closed slot={d}", .{res.slot});
    res.destroy();
}

/// Adopt (or mourn) a finished dial. GUI thread.
fn adoptDial(self: *ActivityMonitor, dialed: ?*relay_dial.Dialed) void {
    self.dialing = false;
    const d = dialed orelse {
        // A dial failure is an ANSWER, same as a failed sample: stop loading so
        // the overlay can say "Couldn't connect" instead of sitting on a
        // spinner forever.
        self.refresh_failed = true;
        self.loading = false;
        self.rebuildCards();
        _ = w32.InvalidateRect(self.hwnd, null, 0);
        log.warn("activity monitor: dial failed source={s}", .{self.source.label()});
        return;
    };
    self.remote_conn = .{ .conn = d.conn, .dialed = d };
    self.beginMetrics();
    log.info("activity monitor: connected source={s}", .{self.source.label()});
    self.rebuildCards();
    self.kickSample();
}

/// Subscribe to the source's pushed host-metrics stream. Host CPU% is only
/// truthful from this stream (see the header); everything else the snapshot
/// already carries.
fn beginMetrics(self: *ActivityMonitor) void {
    const rc = self.remote_conn orelse return;
    rc.conn.subscribeMetrics(
        @intCast(gauge.sample_interval_ms),
        self,
        onMetrics,
    ) catch |err| {
        // Not fatal: the table still refreshes, the host CPU gauge just stays
        // at whatever the snapshot reports.
        log.warn("activity monitor: metrics subscribe failed err={}", .{err});
    };
}

/// Control-reader thread: park the newest reading for the sample worker. It
/// does NOT touch view state — see `Connection.MetricsHandler`'s threading
/// contract.
fn onMetrics(ctx: *anyopaque, host: remote_protocol.HostMetrics) void {
    const self: *ActivityMonitor = @ptrCast(@alignCast(ctx));
    self.metrics_mutex.lock();
    defer self.metrics_mutex.unlock();
    self.last_metrics = host;
}

// ---------------------------------------------------------------------
// Machine list + carousel
// ---------------------------------------------------------------------

/// Kick off the relay device-list fetch on a detached thread. Credentials are
/// resolved HERE, on the GUI thread, for the same reason the dial does it: the
/// account store lives on this side.
///
/// Signed out is not an error — it is a panel with one source, which paints no
/// carousel at all (design system §6).
fn startMachineList(self: *ActivityMonitor) void {
    const alloc = self.app.core_app.alloc;
    const msg_hwnd = self.app.msg_hwnd orelse return;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token = IpcHandlers.resolveToken(arena) orelse {
        log.info("activity monitor: no relay credential, carousel shows local sources only", .{});
        return;
    };
    const base = relay_directory.resolveBase(arena) catch return;

    const req = alloc.create(MachineListRequest) catch return;
    req.* = .{
        .alloc = alloc,
        .hwnd = msg_hwnd,
        .slot = self.slot,
        .serial = self.serial,
        .base = alloc.dupe(u8, base) catch {
            alloc.destroy(req);
            return;
        },
        .token = undefined,
    };
    req.token = alloc.dupe(u8, token) catch {
        alloc.free(req.base);
        alloc.destroy(req);
        return;
    };

    const thread = std.Thread.spawn(.{}, machineListWorker, .{req}) catch |err| {
        log.warn("activity monitor: machine-list thread spawn failed err={}", .{err});
        req.destroy();
        return;
    };
    thread.detach();
}

/// The detached fetch. Owns `req`; copies every device out of the parsed arena
/// BEFORE that arena dies, and hands the GUI thread one flat result.
fn machineListWorker(req: *MachineListRequest) void {
    defer req.destroy();
    const alloc = req.alloc;

    const res = alloc.create(MachineListResult) catch return;
    res.* = .{ .alloc = alloc, .slot = req.slot, .serial = req.serial };

    if (relay_directory.listDevices(alloc, req.base, req.token)) |parsed| {
        defer parsed.deinit();
        for (parsed.value.devices) |dev| {
            if (res.count == res.entries.len) {
                log.warn("activity monitor: more than {d} machines, carousel shows the first {d}", .{
                    parsed.value.devices.len,
                    res.entries.len,
                });
                break;
            }
            res.entries[res.count].set(dev.id, dev.name, dev.online);
            res.count += 1;
        }
    } else |err| {
        // A directory we cannot reach is a carousel with fewer cards, not a
        // broken panel: the active source and Local are always switchable.
        log.warn("activity monitor: machine list failed err={}", .{err});
    }

    if (w32.PostMessageW(req.hwnd, WM_APP_ACTIVITY_MACHINES, @intFromPtr(res), 0) == 0) {
        res.destroy();
    }
}

/// GUI thread (App.msgWndProc): a machine list arrived. Takes ownership of
/// `res`.
pub fn onMachines(res: *MachineListResult) void {
    defer res.destroy();

    var serials: [max_monitors]?u64 = @splat(null);
    for (open_wins, 0..) |maybe, i| {
        if (maybe) |p| {
            if (!p.closing) serials[i] = p.serial;
        }
    }
    if (!panelMatches(&serials, res.slot, res.serial)) {
        log.info("activity monitor: machine list landed after its panel closed slot={d}", .{res.slot});
        return;
    }

    const self = open_wins[res.slot].?;
    self.machine_count = @min(res.count, self.machines.len);
    for (self.machines[0..self.machine_count], res.entries[0..self.machine_count]) |*dst, src| {
        dst.* = src;
    }
    self.rebuildCards();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// The summary a card paints. The ACTIVE card prefers what the panel actually
/// knows (Mac's `summary(for:)`, :266); every other card reports the directory's
/// flag, because nothing has dialed it.
fn cardSummary(self: *const ActivityMonitor, local: bool, id: []const u8, online: bool) cards_mod.Summary {
    const active = switch (self.source) {
        .local => local,
        .remote => |r| !local and std.mem.eql(u8, r.id, id),
    };
    if (!active) return .{ .state = .idle, .online = if (local) true else online };

    if (self.dialing) return .{ .state = .connecting };
    const snap = self.snap orelse return .{
        .state = if (self.refresh_failed) .failed else .connecting,
    };
    if (self.refresh_failed and self.order_len == 0) return .{ .state = .failed };
    return .{
        .state = .live,
        .online = true,
        // An agent that does not report uptime leaves it null, and the card's
        // second line falls back to "—" rather than claiming "up 0m".
        .uptime_s = snap.host.uptime_s orelse 0,
        .cpu_pct = snap.host.cpu_pct,
        .mem_used = snap.host.mem_used,
        .mem_total = snap.host.mem_total,
    };
}

/// Re-derive the card list from the machine list and the active source, then
/// re-place the chrome if the carousel appeared or disappeared.
///
/// Cheap and idempotent: called at open, when the machine list lands, on every
/// adopted snapshot (the active card's numbers are live) and after a switch.
fn rebuildCards(self: *ActivityMonitor) void {
    const had = cards_mod.hasCarousel(self.card_count);
    const first = self.card_count == 0;

    var n: usize = 0;
    self.cards[n] = .{
        .local = true,
        .label = "Local",
        .summary = self.cardSummary(true, "", true),
    };
    n += 1;

    for (self.machines[0..self.machine_count]) |*m| {
        if (n == self.cards.len) break;
        const id = m.idSlice();
        self.cards[n] = .{
            .local = false,
            .id = id,
            .label = if (m.name_len > 0) m.nameSlice() else id,
            .summary = self.cardSummary(false, id, m.online),
        };
        n += 1;
    }

    // The active source ALWAYS has a card. It can be missing from the directory
    // for reasons that are all normal: the panel borrowed a remote window's
    // connection, the account is signed out, the fetch failed, or the machine
    // was removed while the panel sat open.
    if (self.source == .remote and n < self.cards.len) {
        const id = self.source.remote.id;
        if (cards_mod.indexOf(self.cards[0..n], false, id) == null) {
            self.cards[n] = .{
                .local = false,
                .id = id,
                .label = self.source.label(),
                .summary = self.cardSummary(false, id, true),
            };
            n += 1;
        }
    }
    self.card_count = n;

    // The ring STARTS on the active card (Mac seeds it in `onAppear`, :838-841)
    // and stays where the user left it afterwards — a list that grew under the
    // ring must not yank it back and make the next arrow key go somewhere the
    // user did not ask for. `moveFocus(…, 0, …)` is the clamp that keeps it on
    // a card that still exists.
    if (first) {
        if (self.activeCardIndex()) |i| self.card_focus = @intCast(i);
    }
    self.card_focus = cards_mod.moveFocus(self.card_focus, 0, n);

    if (cards_mod.hasCarousel(n) != had) self.applyLayout();
    self.clampCarousel();
    self.logCarousel();
}

/// The card index of the panel's current source, or null (which can only happen
/// with no cards at all).
fn activeCardIndex(self: *const ActivityMonitor) ?usize {
    return switch (self.source) {
        .local => cards_mod.indexOf(self.cards[0..self.card_count], true, ""),
        .remote => |r| cards_mod.indexOf(self.cards[0..self.card_count], false, r.id),
    };
}

fn clampCarousel(self: *ActivityMonitor) void {
    const l = self.layout();
    if (!cards_mod.hasCarousel(self.card_count)) {
        self.carousel_scroll = 0;
        return;
    }
    self.carousel_scroll = cards_mod.clampScroll(
        self.carousel_scroll,
        layout_mod.carouselContentWidth(@intCast(self.card_count), self.scale),
        l.carousel.width(),
    );
}

/// Scroll the focused card fully into view.
fn scrollCardIntoView(self: *ActivityMonitor) void {
    if (!cards_mod.hasCarousel(self.card_count)) return;
    const l = self.layout();
    // `cardRect` at scroll 0 is the card in CONTENT coordinates, which is what
    // `scrollToShow` wants.
    const r = layout_mod.cardRect(l, self.card_focus, 0, self.scale);
    self.carousel_scroll = cards_mod.scrollToShow(
        self.carousel_scroll,
        r.left,
        r.right,
        l.carousel.width(),
        layout_mod.cardMargin(self.scale),
    );
    self.clampCarousel();
}

/// The carousel's state, logged because a GDI-painted card has no text to read
/// back. The RECTS are the painter's own arithmetic — an acceptance script
/// clicks what this reports rather than re-deriving a layout it would then be
/// asserting against itself (the T257 lesson).
fn logCarousel(self: *ActivityMonitor) void {
    var buf: [512]u8 = undefined;
    var used: usize = 0;
    if (cards_mod.hasCarousel(self.card_count)) {
        const l = self.layout();
        for (0..self.card_count) |i| {
            const r = layout_mod.cardRect(l, @intCast(i), self.carousel_scroll, self.scale);
            const part = std.fmt.bufPrint(buf[used..], "{s}{d},{d},{d},{d}", .{
                @as([]const u8, if (used == 0) "" else ";"),
                r.left,
                r.top,
                r.right,
                r.bottom,
            }) catch break;
            used += part.len;
        }
    }
    log.info("activity monitor: carousel cards={d} focus={d} active={d} scroll={d} rects={s}", .{
        self.card_count,
        self.card_focus,
        if (self.activeCardIndex()) |i| @as(i64, @intCast(i)) else -1,
        self.carousel_scroll,
        buf[0..used],
    });
}

// ---------------------------------------------------------------------
// Source switching
// ---------------------------------------------------------------------

/// Switch the panel to the card at `index` (Mac's `switchTo`, :307). One click,
/// no second window.
fn switchToCard(self: *ActivityMonitor, index: i32) void {
    if (index < 0 or index >= @as(i32, @intCast(self.card_count))) return;
    const card = self.cards[@intCast(index)];

    // Everything below rewrites `id_buf`/`name_buf`, and the ACTIVE card's
    // slices point straight at them. Copy first, then decide.
    var id_copy: [max_source_id]u8 = undefined;
    var name_copy: [max_source_label]u8 = undefined;
    const id_len = @min(card.id.len, id_copy.len);
    const name_len = @min(card.label.len, name_copy.len);
    @memcpy(id_copy[0..id_len], card.id[0..id_len]);
    @memcpy(name_copy[0..name_len], card.label[0..name_len]);

    const target: Source = if (card.local)
        .local
    else
        .{ .remote = .{ .id = id_copy[0..id_len], .name = name_copy[0..name_len] } };

    if (self.source.eql(target)) return;

    // One panel per source is the registry's whole promise (`openInner`), and a
    // switch has to keep it: if another panel is already showing this machine,
    // focusing it is the honest answer — two panels keyed alike would leave one
    // of them unreachable by `open` forever.
    if (slotFor(&open_keys, target)) |other| {
        if (other != self.slot) {
            if (open_wins[other]) |existing| {
                log.info("activity monitor: {s} is already open, focusing it", .{target.label()});
                _ = w32.ShowWindow(existing.hwnd, w32.SW_SHOW);
                _ = w32.SetForegroundWindow(existing.hwnd);
                return;
            }
        }
    }

    log.info("activity monitor: switching {s} -> {s}", .{ self.source.label(), target.label() });

    self.teardownSource();

    // A dial or a machine-list fetch already in flight for the OLD source must
    // not be adopted under the new one. Bumping the serial routes both onto
    // their panel-is-gone path, which frees whatever they were carrying.
    self.serial = next_serial;
    next_serial += 1;

    // Adopt the new identity into OUR buffers: `id_copy` dies with this frame.
    self.source = target;
    if (!card.local) {
        @memcpy(self.id_buf[0..id_len], id_copy[0..id_len]);
        @memcpy(self.name_buf[0..name_len], name_copy[0..name_len]);
        self.source = .{ .remote = .{
            .id = self.id_buf[0..id_len],
            .name = self.name_buf[0..name_len],
        } };
    }
    open_keys[self.slot] = self.source;
    self.setTitle();

    self.resetForNewSource();

    if (self.source == .remote) {
        // Always a FRESH, OWNED dial. A borrowed connection belongs to a window
        // and was dropped by `teardownSource`; re-borrowing it would tie this
        // panel's lifetime back to a window it can no longer see.
        self.startDial();
    }
    self.rebuildCards();
    self.kickSample();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// Stop everything the current source owns, leaving the panel ready to begin a
/// new one. Reusable by `switchTo` — unlike `close`, this leaves the window,
/// the timer and the panel itself alive.
fn teardownSource(self: *ActivityMonitor) void {
    // Any sample still running belongs to the old source. Retiring the
    // generation is what makes its result droppable instead of adoptable.
    self.source_gen +%= 1;

    const rc = self.remote_conn orelse {
        self.dialing = false;
        return;
    };
    // Unsubscribe FIRST: `unsubscribeMetrics` returning is the guarantee that no
    // further callback can fire (`connection.zig:1148-1162`).
    rc.conn.unsubscribeMetrics();

    if (rc.owned()) {
        // Cut the transport before the join so a worker parked on an
        // unresponsive agent returns at once. Then JOIN — the worker holds this
        // connection and we are about to free it.
        rc.conn.shutdown();
        if (self.worker) |t| {
            t.join();
            self.worker = null;
            self.sampling = false;
        }
        if (rc.dialed) |d| {
            d.deinit();
            self.app.core_app.alloc.destroy(d);
        }
    }
    // Borrowed: nothing to free and nothing to join. The worker may still be
    // mid-RPC on a connection that belongs to a live window, which is safe —
    // and joining it could block the GUI for the whole `rpc_timeout_ns`, which
    // is not.

    self.remote_conn = null;
    self.dialing = false;
    self.metrics_mutex.lock();
    self.last_metrics = null;
    self.metrics_mutex.unlock();
}

/// Clear every view field the old source filled in. Trend history is the one
/// that MUST be cleared (Mac clears `samples` for exactly this reason,
/// :312-323): a chart that carried one machine's history under another's name
/// would be a fabricated reading.
fn resetForNewSource(self: *ActivityMonitor) void {
    const alloc = self.app.core_app.alloc;
    if (self.snap) |s| {
        s.destroy(alloc);
        self.snap = null;
    }
    // The parked sample belongs to the previous generation; drop it now rather
    // than leaving it to be dropped later.
    self.pending_mutex.lock();
    if (self.pending) |p| {
        p.destroy(alloc);
        self.pending = null;
    }
    self.pending_failed = false;
    self.pending_mutex.unlock();

    // The local sampler's CPU deltas are differences against its previous tick.
    // Keeping it across a trip to another machine would make the first sample
    // home a delta over however long the detour took.
    if (self.proc_sampler) |*p| {
        p.deinit();
        self.proc_sampler = null;
    }
    self.host_sampler = remote_metrics.Sampler.init();

    self.ring_len = 0;
    self.order_len = 0;
    self.sel_len = 0;
    self.scroll = 0;
    self.hover_row = -1;
    self.loading = true;
    self.refresh_failed = false;
    self.logged_sample_error = false;
    self.err_len = 0;
    self.refreshChrome();
}

/// Retitle the window for the current source — Mac retitles on every switch
/// (`RemoteActivityMonitor.swift:41`, :54).
fn setTitle(self: *ActivityMonitor) void {
    var title_buf: [192]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Activity — {s}", .{self.source.label()}) catch "Activity";
    var wtitle: [160]u16 = undefined;
    const tlen = std.unicode.utf8ToUtf16Le(&wtitle, title) catch 0;
    wtitle[tlen] = 0;
    _ = w32.SetWindowTextW(self.hwnd, @ptrCast(&wtitle));
}

/// Tear down: stop the timer, JOIN any in-flight sample (it is writing into
/// memory we are about to free), leave the registry, destroy the window.
pub fn close(self: *ActivityMonitor) void {
    if (self.closing) return;
    self.closing = true;

    _ = w32.KillTimer(self.hwnd, SAMPLE_TIMER_ID);

    // Ownership order, and it is load-bearing:
    //   1. UNSUBSCRIBE first — the metrics handler captures `self`, and
    //      `unsubscribeMetrics` returning is the guarantee that no further
    //      callback can fire (`connection.zig:1148-1162`).
    //   2. JOIN the sample worker — it may be mid-RPC on this connection.
    //   3. Only then free the transport, and only if we own it: a BORROWED
    //      connection belongs to a remote window whose session must survive
    //      this panel closing.
    if (self.remote_conn) |rc| {
        rc.conn.unsubscribeMetrics();
        // Owned: cut the transport BEFORE the join. `shutdown` runs
        // `failPendingRpcs`, so a worker parked on an unresponsive agent
        // returns at once instead of holding the GUI for the whole
        // `rpc_timeout_ns`. It is idempotent, so `Dialed.deinit` below is
        // unaffected. Borrowed: never — that stream is a window's shell.
        if (rc.owned()) rc.conn.shutdown();
    }
    if (self.worker) |t| {
        t.join();
        self.worker = null;
    }
    if (self.remote_conn) |rc| {
        if (rc.dialed) |d| {
            d.deinit();
            self.app.core_app.alloc.destroy(d);
        }
        self.remote_conn = null;
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
        hwnd == self.show_all_btn or hwnd == self.new_proc_btn or
        hwnd == self.kill_btn;
}

fn createFonts(self: *ActivityMonitor, l: layout_mod.Layout) void {
    self.font = makeFont(l.font_h, 400, "Segoe UI");
    self.num_font = makeFont(l.font_h, 400, "Consolas");
    self.title_font = makeFont(l.title_font_h, 600, "Segoe UI");
    self.caption_font = makeFont(l.caption_font_h, 400, "Segoe UI");
    if (self.font) |f| {
        for ([_]w32.HWND{ self.filter, self.show_all_btn, self.new_proc_btn, self.kill_btn }) |c| {
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
    // A modal dialog is quoting the current snapshot; do not start work whose
    // result cannot be adopted anyway.
    if (self.modal) return;
    // Mid-dial there is nothing to sample, and keeping the worker out of the
    // way is what lets `adoptDial` publish `remote_conn` without a lock.
    if (self.dialing) return;
    if (self.worker) |t| {
        t.join();
        self.worker = null;
    }
    self.sampling = true;
    // The generation is captured HERE, on the GUI thread, so a switch that
    // happens while this worker runs can retire its result without racing it.
    self.worker = std.Thread.spawn(.{}, sampleWorker, .{ self, self.source_gen }) catch |err| {
        log.warn("activity monitor: sample thread spawn failed err={}", .{err});
        self.sampling = false;
        return;
    };
}

fn sampleWorker(self: *ActivityMonitor, gen: u32) void {
    const alloc = self.app.core_app.alloc;
    const snap = self.buildSnapshot(alloc) catch |err| {
        // A source that is not connected fails EVERY tick, and a panel can sit
        // open for hours — say it once. Only the worker touches this flag, and
        // the previous worker is joined before the next one starts.
        const spammy = err == error.RemoteSourceNotConnected;
        if (!spammy or !self.logged_sample_error) {
            log.warn("activity monitor: sample failed source={s} err={}", .{ self.source.label(), err });
        }
        // Only the always-fails case is silenced; a real sampling error stays
        // loud every time it happens.
        if (spammy) self.logged_sample_error = true;
        self.pending_mutex.lock();
        self.pending_failed = true;
        self.pending_gen = gen;
        self.pending_mutex.unlock();
        _ = w32.PostMessageW(self.hwnd, WM_APP_ACTIVITY_SAMPLE, 0, 0);
        return;
    };

    self.pending_mutex.lock();
    if (self.pending) |old| old.destroy(alloc);
    self.pending = snap;
    self.pending_failed = false;
    self.pending_gen = gen;
    self.pending_mutex.unlock();

    _ = w32.PostMessageW(self.hwnd, WM_APP_ACTIVITY_SAMPLE, 0, 0);
}

fn buildSnapshot(self: *ActivityMonitor, alloc: Allocator) !*Snapshot {
    if (self.source == .remote) {
        // No connection means the dial failed (or we are signed out). Sampling
        // THIS machine and captioning it with another machine's name would be a
        // lie the user has no way to catch, so the panel reports what is true:
        // it cannot reach that source (`paintEmptyState`'s "Couldn't connect").
        const rc = self.remote_conn orelse return error.RemoteSourceNotConnected;
        return self.buildRemoteSnapshot(alloc, rc.conn);
    }

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

/// One poll against a REMOTE source, on the worker thread. Same shape as the
/// local path — one arena, strings copied into it — so adoption, retirement and
/// every consumer downstream cannot tell the two apart.
fn buildRemoteSnapshot(
    self: *ActivityMonitor,
    alloc: Allocator,
    conn: *remote_connection.Connection,
) !*Snapshot {
    var remote = try conn.requestProcSnapshot(null, max_rows, rpc_timeout_ns);
    defer remote.deinit();

    const snap = try alloc.create(Snapshot);
    errdefer alloc.destroy(snap);
    snap.* = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .rows = &.{},
        .host = remote.host,
        .truncated = remote.truncated,
        // The agent's own pid roots the "ghoztty-spawned" tree on THAT machine
        // (`PROC_SNAPSHOT.agent_pid`); ours is meaningless there. 0 from an
        // agent that predates the field, which the Show-all rule already
        // treats as "unknown".
        .root_pid = remote.agent_pid,
    };
    errdefer snap.arena.deinit();
    const arena = snap.arena.allocator();

    // Host CPU% comes from the pushed stream — the snapshot's is a one-shot
    // read with no baseline (see the header). Everything else in `host` is
    // instantaneous and already right.
    {
        self.metrics_mutex.lock();
        defer self.metrics_mutex.unlock();
        if (self.last_metrics) |m| snap.host.cpu_pct = m.cpu_pct;
    }

    const rows = try arena.alloc(rows_mod.Row, remote.procs.len);
    for (remote.procs, 0..) |p, i| {
        rows[i] = .{
            .pid = p.pid,
            .ppid = p.ppid,
            .cpu_pct = p.cpu_pct,
            .mem_bytes = p.mem_bytes,
            .name = try arena.dupe(u8, p.name),
            .cmd = if (p.cmd) |c| try arena.dupe(u8, c) else "",
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
///
/// A no-op while a dialog is up — see `modal`. The dialog calls this itself on
/// the way out, so a sample that landed mid-dialog is adopted immediately after
/// rather than waiting for the next tick.
fn adoptPending(self: *ActivityMonitor) void {
    if (self.modal) return;
    self.sampling = false;

    self.pending_mutex.lock();
    const taken = self.pending;
    self.pending = null;
    const failed = self.pending_failed;
    self.pending_failed = false;
    const gen = self.pending_gen;
    self.pending_mutex.unlock();

    // A sample of the machine we just switched AWAY from. Adopting it would
    // paint one machine's processes under another's name — the same lie the
    // remote path refuses to tell when a dial has not landed.
    if (gen != self.source_gen) {
        if (taken) |s| s.destroy(self.app.core_app.alloc);
        return;
    }

    const snap = taken orelse {
        if (!failed) return;
        // A failure is an ANSWER: leaving `loading` set would sit on "Loading…"
        // forever while the overlay has "Couldn't connect" to say instead.
        self.refresh_failed = true;
        self.loading = false;
        _ = w32.InvalidateRect(self.hwnd, null, 0);
        return;
    };
    const alloc = self.app.core_app.alloc;
    if (self.snap) |old| old.destroy(alloc);
    self.snap = snap;
    self.loading = false;
    self.refresh_failed = false;

    // Prune before rebuilding: a selected process that exited must stop counting
    // toward the Kill button and its confirmation (Mac prunes on every `procs`
    // change, :1050-1056), and `rebuild` logs the count this produces.
    const before = self.sel_len;
    self.sel_len = actions.pruneSelection(&self.sel_pids, self.sel_len, snap.rows);

    self.pushSample(snap.host);
    self.rebuild();
    // The ACTIVE card's readout is this snapshot's host metrics, so the cards
    // are re-derived from the same data on the same tick.
    self.rebuildCards();
    if (self.sel_len != before) self.refreshChrome();
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
        // `root` is the snapshot's own root pid — this process for a local
        // sample, the AGENT's for a remote one. It is the field that tells the
        // two apart from outside, which is what the T295 acceptance needs: a
        // loopback agent enumerates the same box, so a row count cannot.
        "activity monitor: source={s} total={d} shown={d} needle=\"{s}\" show_all={} sort={s}/{s} selected={d} root={d}",
        .{
            self.source.label(),
            snap.rows.len,
            self.order_len,
            self.needle(),
            self.show_all,
            @tagName(self.sort.key),
            if (self.sort.ascending) "asc" else "desc",
            self.sel_len,
            snap.root_pid,
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
fn applyLayout(self: *ActivityMonitor) void {
    const l = self.layout();
    _ = w32.MoveWindow(self.filter, l.filter.left, l.filter.top, l.filter.width(), l.filter.height(), 1);
    _ = w32.MoveWindow(self.show_all_btn, l.show_all.left, l.show_all.top, l.show_all.width(), l.show_all.height(), 1);
    _ = w32.MoveWindow(self.new_proc_btn, l.new_proc_btn.left, l.new_proc_btn.top, l.new_proc_btn.width(), l.new_proc_btn.height(), 1);
    _ = w32.MoveWindow(self.kill_btn, l.kill_btn.left, l.kill_btn.top, l.kill_btn.width(), l.kill_btn.height(), 1);
    self.clampScroll();
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// Bring the Kill button in line with the selection: its caption counts the
/// rows, and it is only visible while there are any. Every selection mutation
/// funnels through here, so "the button says Kill 3" and "three rows are
/// selected" are the same fact.
fn refreshChrome(self: *ActivityMonitor) void {
    var buf: [32]u8 = undefined;
    var wbuf: [32]u16 = undefined;
    const label = actions.killButtonLabel(&buf, self.sel_len);
    const n = std.unicode.utf8ToUtf16Le(&wbuf, label) catch 0;
    wbuf[n] = 0;
    _ = w32.SetWindowTextW(self.kill_btn, @ptrCast(&wbuf));
    _ = w32.ShowWindow(self.kill_btn, if (self.sel_len > 0) w32.SW_SHOW else w32.SW_HIDE);
    self.applyLayout();
}

/// Raise the action-error banner. Truncates rather than failing: a banner that
/// says most of what went wrong beats none at all.
fn setError(self: *ActivityMonitor, text: []const u8) void {
    const n = @min(text.len, self.err_buf.len);
    @memcpy(self.err_buf[0..n], text[0..n]);
    self.err_len = n;
    log.warn("activity monitor: action error: {s}", .{self.err_buf[0..n]});
    // The banner steals height from the table, so the layout has to run.
    self.applyLayout();
}

fn clearError(self: *ActivityMonitor) void {
    if (self.err_len == 0) return;
    self.err_len = 0;
    self.applyLayout();
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

    self.paintCarousel(mem_dc, l);
    self.paintGauges(mem_dc, l);
    self.paintControlBar(mem_dc, l);
    self.paintTable(mem_dc, l);
    self.paintBanner(mem_dc, l);

    // Dividers last so nothing paints over them. A hidden band reports its rule
    // at -1 and must not paint a line across the top of the window.
    for ([_]i32{ l.carousel_divider_y, l.header_divider_y, l.control_divider_y }) |y| {
        if (y < 0) continue;
        fill(mem_dc, .{ .left = 0, .top = y, .right = l.client_w, .bottom = y + 1 }, COLOR_DIVIDER);
    }

    _ = w32.BitBlt(hdc, 0, 0, l.client_w, l.client_h, mem_dc, 0, 0, w32.SRCCOPY);
}

/// The machine-card carousel (T296). Cards are clipped to the band so a
/// scrolled strip cannot paint over the gauges below it.
fn paintCarousel(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    if (!cards_mod.hasCarousel(self.card_count)) return;

    // Save/restore rather than `SelectClipRgn(dc, null)`: clearing the clip
    // outright would un-clip whatever the caller had set, not just what we add.
    const saved = w32.SaveDC(hdc);
    defer {
        if (saved != 0) _ = w32.RestoreDC(hdc, saved);
    }
    _ = w32.IntersectClipRect(
        hdc,
        l.carousel.left,
        l.carousel.top,
        l.carousel.right,
        l.carousel.bottom,
    );

    const active = self.activeCardIndex();
    for (self.cards[0..self.card_count], 0..) |card, i| {
        const idx: i32 = @intCast(i);
        const r = layout_mod.cardRect(l, idx, self.carousel_scroll, self.scale);
        if (r.right <= l.carousel.left or r.left >= l.carousel.right) continue;
        const is_active = active != null and active.? == i;
        self.paintCard(hdc, r, card, is_active, idx == self.card_focus, idx == self.card_hover);
    }
}

fn paintCard(
    self: *ActivityMonitor,
    hdc: w32.HDC,
    r: layout_mod.Rect,
    card: cards_mod.Card,
    is_active: bool,
    is_focused: bool,
    is_hover: bool,
) void {
    const radius = px(8, self.scale);
    const fill_color: u32 = if (is_active)
        COLOR_CARD_SELECT_BG
    else if (is_hover)
        COLOR_CARD_HOVER
    else
        COLOR_CARD_BG;
    const border_color: u32 = if (is_active) COLOR_ACCENT else COLOR_CARD_BORDER;
    const border_w: i32 = if (is_active) @max(2, px(2, self.scale)) else @max(1, px(1, self.scale));

    roundRect(hdc, r, radius, fill_color, border_color, border_w);

    // The focus ring lives OUTSIDE the card and only when focus is NOT already
    // on the active card — otherwise the accent border and the ring stack into
    // a double border that reads as a rendering bug (Mac makes the same call,
    // :1481-1488).
    if (is_focused and !is_active) {
        const pad = @max(2, px(2, self.scale));
        const ring: layout_mod.Rect = .{
            .left = r.left - pad,
            .top = r.top - pad,
            .right = r.right + pad,
            .bottom = r.bottom + pad,
        };
        strokeRoundRect(hdc, ring, radius + pad, COLOR_ACCENT, @max(2, px(2, self.scale)));
    }

    const c = layout_mod.cardContent(r, self.scale);
    const switching = is_active and self.dialing;

    // Status dot.
    const dot_color: u32 = switch (cards_mod.dot(card.summary, switching)) {
        .good => COLOR_DOT_GOOD,
        .pending => COLOR_DOT_PENDING,
        .bad => COLOR_DOT_BAD,
        .unknown => COLOR_DOT_UNKNOWN,
    };
    ellipse(hdc, c.dot, dot_color);

    const secondary: u32 = if (is_active) COLOR_CARD_SECONDARY_SEL else COLOR_CARD_SECONDARY;
    const flags: u32 = text_flags | w32.DT_END_ELLIPSIS;

    const old_font = if (self.font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, COLOR_TEXT);
    drawText(hdc, card.label, c.label, flags);

    if (self.caption_font) |f| _ = w32.SelectObject(hdc, f);
    _ = w32.SetTextColor(hdc, secondary);
    var sbuf: [48]u8 = undefined;
    drawText(hdc, cards_mod.summaryLine(&sbuf, card.summary, switching), c.summary, flags);

    // The metric line is tabular — a number that jitters sideways every 1.5 s
    // is the reason `num_font` exists.
    if (self.num_font) |f| _ = w32.SelectObject(hdc, f);
    var mbuf: [64]u8 = undefined;
    const metric = cards_mod.metricLine(&mbuf, card.summary);
    if (metric.len > 0) drawText(hdc, metric, c.metric, flags);

    if (old_font) |f| _ = w32.SelectObject(hdc, f);
}

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// A filled rounded rect with a border, in the GDI idiom the banner overlay
/// already uses (`BannerOverlay.zig:524-529`).
fn roundRect(
    hdc: w32.HDC,
    r: layout_mod.Rect,
    radius: i32,
    fill_color: u32,
    border_color: u32,
    border_w: i32,
) void {
    const brush = w32.CreateSolidBrush(fill_color) orelse return;
    defer _ = w32.DeleteObject(brush);
    const pen = w32.CreatePen(0, border_w, border_color) orelse return; // PS_SOLID
    defer _ = w32.DeleteObject(pen);
    const old_brush = w32.SelectObject(hdc, @ptrCast(brush));
    defer _ = w32.SelectObject(hdc, old_brush);
    const old_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, old_pen);
    _ = w32.RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
}

/// The same shape, stroked only — the focus ring must not paint over whatever
/// is behind the card's corners.
fn strokeRoundRect(hdc: w32.HDC, r: layout_mod.Rect, radius: i32, color: u32, width: i32) void {
    const pen = w32.CreatePen(0, width, color) orelse return;
    defer _ = w32.DeleteObject(pen);
    const hollow = w32.GetStockObject(w32.NULL_BRUSH);
    const old_brush = w32.SelectObject(hdc, hollow);
    defer _ = w32.SelectObject(hdc, old_brush);
    const old_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, old_pen);
    _ = w32.RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
}

fn ellipse(hdc: w32.HDC, r: layout_mod.Rect, color: u32) void {
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(brush);
    const pen = w32.CreatePen(0, 1, color) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old_brush = w32.SelectObject(hdc, @ptrCast(brush));
    defer _ = w32.SelectObject(hdc, old_brush);
    const old_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, old_pen);
    _ = w32.Ellipse(hdc, r.left, r.top, r.right, r.bottom);
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

    const total = if (self.snap) |s| s.rows.len else 0;
    const truncated = if (self.snap) |s| s.truncated else false;
    if (l.badge.width() > 0) {
        if (actions.badgeText(self.refresh_failed, truncated, total)) |badge| {
            _ = w32.SetTextColor(hdc, COLOR_WARN);
            drawText(hdc, badge, l.badge, text_flags | w32.DT_LEFT | w32.DT_END_ELLIPSIS);
        }
    }

    var buf: [64]u8 = undefined;
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
    const total = if (self.snap) |s| s.rows.len else 0;
    const state = actions.emptyState(self.dialing, self.loading, self.refresh_failed, total);
    if (state != .unreachable_source) {
        _ = w32.SelectObject(hdc, self.font);
        _ = w32.SetTextColor(hdc, COLOR_SECONDARY);
        const text = switch (state) {
            .connecting => "Connecting\u{2026}",
            .loading => "Loading\u{2026}",
            else => "No processes match",
        };
        drawText(hdc, text, l.table_rows, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER);
        return;
    }

    // Mac's two-line "Couldn't connect" block (:1034-1045): a headline the eye
    // lands on and a subtitle naming the source that is unreachable.
    const mid = @divTrunc(l.table_rows.top + l.table_rows.bottom, 2);
    const line_h = l.row_h;
    _ = w32.SelectObject(hdc, self.font);
    _ = w32.SetTextColor(hdc, COLOR_TEXT);
    drawText(hdc, "Couldn't connect", .{
        .left = l.table_rows.left,
        .top = mid - line_h,
        .right = l.table_rows.right,
        .bottom = mid,
    }, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER);

    var buf: [96]u8 = undefined;
    const sub = std.fmt.bufPrint(
        &buf,
        "The {s} source is unreachable.",
        .{self.source.label()},
    ) catch "The source is unreachable.";
    _ = w32.SelectObject(hdc, self.caption_font);
    _ = w32.SetTextColor(hdc, COLOR_SECONDARY);
    drawText(hdc, sub, .{
        .left = l.table_rows.left,
        .top = mid,
        .right = l.table_rows.right,
        .bottom = mid + line_h,
    }, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER);
}

/// The dismissable action-error banner under the table (Mac's `errorBanner`,
/// :1059-1080): a warning glyph, the message, and an ✕ at the trailing edge.
///
/// Painted, not a native control: it is one band that appears and disappears
/// with `Options.has_banner`, and a child window would have to be moved and
/// shown/hidden in lockstep with a rect the layout module already computes.
fn paintBanner(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    if (self.err_len == 0) return;

    fill(hdc, rect(l.banner), COLOR_BANNER_BG);
    // A rule along its top edge, so the banner reads as a band and not as the
    // table's last row painted a different color.
    fill(hdc, .{
        .left = l.banner.left,
        .top = l.banner.top,
        .right = l.banner.right,
        .bottom = l.banner.top + 1,
    }, COLOR_DIVIDER);

    const m = icon_button.Metrics.init(self.scale);
    const glyph_box = icon_button.targetBox(m, .{
        .left = l.banner_close.left,
        .top = l.banner_close.top,
        .right = l.banner_close.right,
        .bottom = l.banner_close.bottom,
    });
    icon_button_paint.glyph(hdc, m, glyph_box, .close, COLOR_SECONDARY);

    // The band's own margin, TAKEN from the layout module rather than
    // re-derived from `pad_x` here: the ✕ sits one margin in from the trailing
    // edge, so `client_w - banner_close.right` IS the margin (the T257 lesson —
    // a second copy of a number is a second chance to be wrong).
    const margin = l.client_w - l.banner_close.right;
    const icon_w = margin;
    const gap = @divTrunc(margin, 2);

    _ = w32.SelectObject(hdc, self.caption_font);
    _ = w32.SetTextColor(hdc, COLOR_WARN);
    drawText(hdc, "\u{26A0}", .{
        .left = l.banner.left + margin,
        .top = l.banner.top,
        .right = l.banner.left + margin + icon_w,
        .bottom = l.banner.bottom,
    }, text_flags | w32.DT_CENTER);

    const text_left = l.banner.left + margin + icon_w + gap;
    _ = w32.SetTextColor(hdc, COLOR_TEXT);
    drawText(hdc, self.err_buf[0..self.err_len], .{
        .left = text_left,
        .top = l.banner.top,
        // Clear of the ✕ by one gap — nothing touches anything (§0.1).
        .right = @max(text_left, l.banner_close.left - gap),
        .bottom = l.banner.bottom,
    }, text_flags | w32.DT_LEFT | w32.DT_END_ELLIPSIS);
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

    // The carousel owns the top band. A click inside it switches source in ONE
    // click (Mac's card `onSelect`, :828-831); a click in the band's padding
    // just moves nothing, and never falls through to the table below.
    if (cards_mod.hasCarousel(self.card_count) and y < l.carousel.bottom) {
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
        self.refreshChrome();
        return;
    };
    if (mods & w32.MK_CONTROL != 0) {
        self.toggleSelection(pid);
    } else if (mods & w32.MK_SHIFT != 0 and self.sel_len > 0) {
        self.extendSelectionTo(idx);
    } else {
        self.selectOnly(pid);
    }
    self.refreshChrome();
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
fn onWheel(self: *ActivityMonitor, delta: i16, screen_x: i32, screen_y: i32) void {
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

    // The carousel's keys, and ONLY while the panel itself holds focus: Space
    // and Enter belong to whichever button has focus otherwise, and a switcher
    // that stole them would make the Kill button unpressable from the keyboard.
    //
    // Arrowing moves the ring and repaints. It never dials — committing is a
    // separate keystroke precisely so that walking the list cannot open a
    // connection per card (Mac makes the same split, :796-799).
    if (cards_mod.hasCarousel(self.card_count) and w32.GetFocus() == @as(?w32.HWND, self.hwnd)) {
        switch (vk) {
            w32.VK_LEFT, w32.VK_RIGHT => {
                const delta: i32 = if (vk == w32.VK_LEFT) -1 else 1;
                const moved = cards_mod.moveFocus(self.card_focus, delta, self.card_count);
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
            else => {},
        }
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
    self.refreshChrome();
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
// Process control (Kill / New Process)
// ---------------------------------------------------------------------

/// UTF-8 → NUL-terminated UTF-16 in `buf`, or null when it does not fit.
fn utf16z(buf: []u16, text: []const u8) ?[:0]const u16 {
    if (text.len + 1 > buf.len) return null;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return null;
    buf[n] = 0;
    return buf[0..n :0];
}

/// Kill every selected row, behind a mandatory confirmation
/// (`RemoteActivityMonitorView.swift:940-952` + :762-780).
///
/// The kills run inline on the GUI thread rather than on a worker, unlike Mac's
/// background hop: `killProc` is `OpenProcess` + `TerminateProcess`, two
/// syscalls that do not block, and hopping threads would mean copying the
/// targets to keep them alive across the hop for no gain. What DOES need care is
/// the snapshot: `targets` borrows its names from `snap`, so `modal` holds off
/// adoption for the dialog's whole nested pump.
fn onKill(self: *ActivityMonitor) void {
    if (self.sel_len == 0) return;
    const snap = self.snap orelse return;

    var target_buf: [max_rows]actions.Target = undefined;
    const targets = actions.targetsFor(self.sel_pids[0..self.sel_len], snap.rows, &target_buf);
    if (targets.len == 0) return;

    var title_utf8: [192]u8 = undefined;
    var title_w: [224]u16 = undefined;
    const title = utf16z(&title_w, actions.killConfirmTitle(&title_utf8, targets)) orelse
        std.unicode.utf8ToUtf16LeStringLiteral("Kill process?");

    var body_w: [256]u16 = undefined;
    const body = utf16z(&body_w, actions.killConfirmBody(targets.len)) orelse
        std.unicode.utf8ToUtf16LeStringLiteral("This terminates the process immediately.");

    var label_utf8: [32]u8 = undefined;
    var label_w: [40]u16 = undefined;
    const ok_label = utf16z(&label_w, actions.killButtonLabel(&label_utf8, targets.len)) orelse
        std.unicode.utf8ToUtf16LeStringLiteral("Kill");

    self.modal = true;
    const choice = ConfirmDialog.show(self.app, self.hwnd, self.scale, self.filter, .{
        .title = title.ptr,
        .text = body,
        .style = .ok_cancel,
        .icon = .warning,
        // MB_DEFBUTTON2: an accidental Enter must never kill anything.
        .default_cancel = true,
        .ok_label = ok_label,
    });
    self.modal = false;

    log.info("activity monitor: kill dialog n={d} choice={s}", .{
        targets.len,
        if (choice == .ok) "ok" else "cancel",
    });
    if (choice != .ok) {
        // Nothing was touched, but a sample may have landed behind the dialog.
        self.adoptPending();
        return;
    }

    var failed_buf: [max_rows]actions.Target = undefined;
    var nfail: usize = 0;
    for (targets) |t| {
        if (!self.killOne(t.pid)) {
            failed_buf[nfail] = t;
            nfail += 1;
        }
    }
    log.info("activity monitor: kill result total={d} killed={d} failed={d}", .{
        targets.len,
        targets.len - nfail,
        nfail,
    });

    var err_utf8: [256]u8 = undefined;
    if (actions.killFailureText(&err_utf8, targets.len, failed_buf[0..nfail])) |text| {
        self.setError(text);
    } else {
        // Mac clears the selection only on a clean sweep (:592-594): rows that
        // survived are still there, and still the ones the user meant.
        self.clearSelection();
        self.clearError();
    }

    // Adopt anything the dialog held off, then force a fresh sample so the
    // casualties leave the table without waiting out the poll interval.
    self.adoptPending();
    self.refreshChrome();
    self.kickSample();
}

/// Terminate one pid on THIS panel's source, returning whether it died. The
/// local and remote calls are the same request to two transports — the agent
/// answers `PROC_KILL` with the very `proc_control.killProc` the local branch
/// calls in-process — so a local panel and a remote one cannot drift.
fn killOne(self: *ActivityMonitor, pid: i64) bool {
    if (self.remote_conn) |rc| {
        var out = rc.conn.killProc(pid, "TERM", rpc_timeout_ns) catch |err| {
            log.warn("activity monitor: remote kill pid={d} err={}", .{ pid, err });
            return false;
        };
        defer out.deinit();
        if (!out.ok) {
            log.warn("activity monitor: remote kill pid={d} failed err={s}", .{
                pid,
                out.error_msg orelse "unknown",
            });
        }
        return out.ok;
    }

    const r = proc_control.killProc(pid, "TERM");
    if (!r.ok) {
        log.warn("activity monitor: kill pid={d} failed err={s}", .{
            pid,
            r.@"error" orelse "unknown",
        });
    }
    return r.ok;
}

/// Start a process on this panel's source (Mac's `NewProcessSheet` +
/// `spawn(cmd:cwd:)`, :781-786 and :603-630).
fn onNewProcess(self: *ActivityMonitor) void {
    var cmd_buf: [NewProcessDialog.MAX_VALUE_LEN]u8 = undefined;
    var cwd_buf: [NewProcessDialog.MAX_VALUE_LEN]u8 = undefined;

    self.modal = true;
    const res = NewProcessDialog.prompt(
        self.app,
        self.hwnd,
        self.scale,
        self.filter,
        self.source.label(),
        &cmd_buf,
        &cwd_buf,
    );
    self.modal = false;

    const r = res orelse {
        log.info("activity monitor: spawn dialog choice=cancel", .{});
        self.adoptPending();
        return;
    };
    // The dialog reports its fields verbatim (the `ConfirmDialog.prompt`
    // contract); trimming is ours.
    const cmd = rows_mod.trim(r.command);
    const cwd = rows_mod.trim(r.working_directory);
    if (cmd.len == 0) {
        self.adoptPending();
        return;
    }
    log.info("activity monitor: spawn dialog choice=start cmd=\"{s}\"", .{cmd});

    if (self.spawnOne(cmd, if (cwd.len == 0) null else cwd)) {
        self.clearError();
    } else {
        var err_utf8: [256]u8 = undefined;
        self.setError(actions.spawnFailureText(&err_utf8, cmd));
    }

    self.adoptPending();
    self.kickSample();
}

/// Start `cmd` on THIS panel's source, returning whether it started. Remote
/// goes through `PROC_SPAWN`, whose agent-side handler is the same
/// `proc_spawn.spawnDetached` the local branch calls.
fn spawnOne(self: *ActivityMonitor, cmd: []const u8, cwd: ?[]const u8) bool {
    const alloc = self.app.core_app.alloc;

    if (self.remote_conn) |rc| {
        var out = rc.conn.spawnProc(cmd, cwd, rpc_timeout_ns) catch |err| {
            log.warn("activity monitor: remote spawn err={}", .{err});
            return false;
        };
        defer out.deinit();
        if (out.ok) {
            log.info("activity monitor: remote spawn ok=true pid={?d}", .{out.pid});
        } else {
            log.warn("activity monitor: remote spawn ok=false err={s}", .{out.error_msg orelse "unknown"});
        }
        return out.ok;
    }

    const out = proc_spawn.spawnDetached(alloc, cmd, cwd);
    // The Windows branch may hand back an ALLOCATED diagnostic note even on
    // success (`SpawnOutcome.free_error`), so this is not a failure-only free.
    defer if (out.free_error) {
        if (out.@"error") |e| alloc.free(e);
    };
    if (out.ok) {
        log.info("activity monitor: spawn result ok=true pid={?d} note={s}", .{
            out.pid,
            out.@"error" orelse "",
        });
    } else {
        log.warn("activity monitor: spawn result ok=false err={s}", .{out.@"error" orelse "unknown"});
    }
    return out.ok;
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
            if (control_id == KILL_ID and notification == w32.BN_CLICKED) {
                self.onKill();
                return 0;
            }
            if (control_id == NEW_PROC_ID and notification == w32.BN_CLICKED) {
                self.onNewProcess();
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
            self.onWheel(
                @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF))),
                loWordSigned(lparam),
                hiWordSigned(lparam),
            );
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

fn remoteSource(id: []const u8, name: []const u8) Source {
    return .{ .remote = .{ .id = id, .name = name } };
}

test "Source.eql: local matches local, remotes match by id" {
    try testing.expect(Source.eql(.local, .local));
    try testing.expect(!Source.eql(.local, remoteSource("winbox", "Winbox")));
    try testing.expect(Source.eql(remoteSource("winbox", "Winbox"), remoteSource("winbox", "Winbox")));
    try testing.expect(!Source.eql(remoteSource("winbox", "Winbox"), remoteSource("laptop", "Laptop")));
    // Identity is the id, not the label: renaming a machine must focus the panel
    // that is already open on it rather than opening a second one.
    try testing.expect(Source.eql(remoteSource("winbox", "Winbox"), remoteSource("winbox", "Front desk")));
}

test "Source.label: the display name, falling back to the id" {
    try testing.expectEqualStrings("Local", Source.label(.local));
    try testing.expectEqualStrings("Winbox", Source.label(remoteSource("dev-1", "Winbox")));
    try testing.expectEqualStrings("dev-1", Source.label(remoteSource("dev-1", "")));
}

test "slotFor: a second open of the same source finds the open panel" {
    var keys = [_]?Source{ null, null, null };
    try testing.expect(slotFor(&keys, .local) == null);

    keys[0] = .local;
    try testing.expectEqual(@as(?usize, 0), slotFor(&keys, .local));
    // A different source is NOT the same panel — that is the whole point of
    // keying the registry rather than keeping one global window.
    try testing.expect(slotFor(&keys, remoteSource("winbox", "Winbox")) == null);

    keys[1] = remoteSource("winbox", "Winbox");
    try testing.expectEqual(@as(?usize, 1), slotFor(&keys, remoteSource("winbox", "Winbox")));
}

test "freeSlot: the first hole, and null when full" {
    var keys = [_]?Source{ .local, null, remoteSource("a", "A") };
    try testing.expectEqual(@as(?usize, 1), freeSlot(&keys));

    keys[1] = remoteSource("b", "B");
    try testing.expect(freeSlot(&keys) == null);

    // A closed panel frees its slot for reuse.
    keys[0] = null;
    try testing.expectEqual(@as(?usize, 0), freeSlot(&keys));
}

test "panelMatches: a dial landing on a REUSED slot is not adopted by the new panel" {
    // The failure this exists to prevent: panel A (serial 7) dials, closes, and
    // panel B opens into the very same slot. A slot-only check would hand B a
    // connection to A's machine and caption it with B's name.
    var serials = [_]?u64{ 7, null, 12 };
    try testing.expect(panelMatches(&serials, 0, 7));
    try testing.expect(!panelMatches(&serials, 0, 6));
    try testing.expect(!panelMatches(&serials, 1, 7)); // slot empty
    try testing.expect(!panelMatches(&serials, 9, 7)); // slot out of range

    serials[0] = 13; // A closed, B took the slot
    try testing.expect(!panelMatches(&serials, 0, 7));
    try testing.expect(panelMatches(&serials, 0, 13));
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
