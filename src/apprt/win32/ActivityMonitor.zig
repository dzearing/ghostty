//! The win32 Activity Monitor panel (T285) — the port of Mac's
//! `RemoteActivityMonitor.swift` + `RemoteActivityMonitorView.swift`. Windows had
//! ZERO of this surface before T226 split into T284..T287.
//!
//! ## The split
//! All arithmetic lives in pure modules that run in every test lane:
//! `activity_layout.zig` (regions + column widths, T284), `trend_gauge.zig`
//! (chart geometry, T284), `activity_rows.zig` (filter / sort / cell text,
//! T285), `activity_actions.zig` (kill/spawn wording and pruning, T286),
//! `activity_cards.zig` (carousel ordering, T296), `activity_borrow.zig`
//! (which window's connection to reuse, T295) and `activity_probe.zig` (probe
//! policy, T298) — the same division that keeps `chooser_layout.zig` testable
//! while `MachineChooser.zig` keeps the win32 surface.
//!
//! The win32 surface was itself one 4,900-line file until T299 split it along
//! the seams that were already section banners inside it. Each plane below owns
//! its own rules AND the commentary that explains them, so a rule is read where
//! it is enforced:
//!
//! | File | Owns |
//! |---|---|
//! | `ActivityMonitor.zig` (this file) | the window: state, open/close, the registry, the wndProc |
//! | `activity_dial.zig` | the connection plane — dialing, borrowing, teardown (T295) |
//! | `activity_machines.zig` | the machine list and the carousel (T296) |
//! | `activity_probe_conn.zig` | the per-card metrics probes' connections (T298) |
//! | `activity_sample.zig` | the poll loop, the gate, and the snapshot |
//! | `activity_view.zig` | filter / selection / scroll, layout and chrome |
//! | `activity_paint.zig` | every pixel |
//! | `activity_input.zig` | mouse, and the keyboard focus ring (T289) |
//! | `activity_procs.zig` | Kill and New Process (T286) |
//!
//! Those files call back into the panel by METHOD, so the aliases under
//! "Split modules" below are the panel's namespace: a function the window
//! calls is a function a plane promised, and the list is where those promises
//! are readable in one place.
//!
//! ## Registry
//! One panel per SOURCE. A second open focuses the existing panel instead of
//! duplicating it, mirroring `RemoteActivityMonitor.focusExisting`
//! (RemoteActivityMonitor.swift:146-150). The slot arithmetic is pure and
//! unit-tested at the bottom of this file.
//!
//! Two of its pieces are load-bearing far from here, so they are worth naming
//! up front. A slot can be REUSED by a different panel between the moment a
//! worker starts and the moment its result lands, which is what `serial` and
//! `panelMatches` exist to catch. And every result that carries a live
//! connection — a dial, a probe dial, a machine list — is posted to the APP's
//! message-only window rather than to the panel's: `DestroyWindow` drops a
//! window's queued messages, so a result posted to a panel that closes first
//! would be discarded with an open connection inside it.

const ActivityMonitor = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
// Test-only (T467): the class-level resize/redraw probe. Imported at file
// scope so its own positive and negative controls are queued into the win32
// test lane along with the class test below.
const class_redraw = @import("class_redraw.zig");
const layout_mod = @import("activity_layout.zig");
const rows_mod = @import("activity_rows.zig");
const cards_mod = @import("activity_cards.zig");
const borrow_mod = @import("activity_borrow.zig");
const probe_mod = @import("activity_probe.zig");
const actions = @import("activity_actions.zig");
const gauge = @import("trend_gauge.zig");
const sample_gate = @import("sample_gate.zig");
const utf16_text = @import("utf16_text.zig");
const icon_button = @import("icon_button.zig");
const icon_button_paint = @import("icon_button_paint.zig");
const chrome_theme = @import("chrome_theme.zig");
const type_ramp = @import("type_ramp.zig");
const panel_theme = @import("panel_theme.zig");
/// What a selected row looks like in a win32 list (T828, generalized by T1008).
/// The process table is a list, so it takes the platform's answer — a neutral
/// wash at two weights plus one accent capsule — from the same module the
/// machine chooser's rows do, rather than tinting the row toward the accent.
const list_selection = @import("list_selection.zig");
const brush_cache = @import("brush_cache.zig");
const system_colors = @import("system_colors.zig");
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
const tcp_dial = @import("../../remote/tcp_dial.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const IpcHandlers = @import("IpcHandlers.zig");

// ---------------------------------------------------------------------
// Split modules (T299)
// ---------------------------------------------------------------------
//
// This file owns the WINDOW: its state, its creation and teardown, its
// registry, and its wndProc. Everything below is a plane that used to live
// inline here and now lives in its own file, imported back as method-call
// aliases so the call sites read the same as they always did.
//
// The aliases are the public surface of each plane, and the reason they are
// listed rather than inlined: a function the window calls is a function the
// plane promised, and a plane's promises should be readable in one place.

const procs_mod = @import("activity_procs.zig");
const input_mod = @import("activity_input.zig");
const paint_mod = @import("activity_paint.zig");
const sample_mod = @import("activity_sample.zig");
const view_mod = @import("activity_view.zig");
const probe_conn = @import("activity_probe_conn.zig");
const dial_mod = @import("activity_dial.zig");
const machines_mod = @import("activity_machines.zig");

pub const RemoteConn = dial_mod.RemoteConn;
pub const DialResult = dial_mod.DialResult;
pub const onDialed = dial_mod.onDialed;
pub const startDial = dial_mod.startDial;
pub const beginMetrics = dial_mod.beginMetrics;
pub const borrowFromWindow = dial_mod.borrowFromWindow;
pub const releaseBorrowed = dial_mod.releaseBorrowed;
pub const teardownSource = dial_mod.teardownSource;
pub const resetForNewSource = dial_mod.resetForNewSource;

pub const MachineEntry = machines_mod.MachineEntry;
pub const MachineListResult = machines_mod.MachineListResult;
pub const max_machines = machines_mod.max_machines;
pub const onMachines = machines_mod.onMachines;
pub const startMachineList = machines_mod.startMachineList;
pub const rebuildCards = machines_mod.rebuildCards;
pub const switchToCard = machines_mod.switchToCard;
pub const activeCardIndex = machines_mod.activeCardIndex;
pub const clampCarousel = machines_mod.clampCarousel;
pub const scrollCardIntoView = machines_mod.scrollCardIntoView;
pub const logCarousel = machines_mod.logCarousel;

pub const Probe = probe_conn.Probe;
pub const ProbeResult = probe_conn.ProbeResult;
pub const onProbeDialed = probe_conn.onProbeDialed;
pub const syncProbes = probe_conn.syncProbes;
pub const stopProbes = probe_conn.stopProbes;
pub const probeCount = probe_conn.probeCount;
pub const probeSummary = probe_conn.probeSummary;

pub const layout = view_mod.layout;
pub const rebuild = view_mod.rebuild;
pub const refreshChrome = view_mod.refreshChrome;
pub const clampScroll = view_mod.clampScroll;
pub const clearSelection = view_mod.clearSelection;
pub const selectOnly = view_mod.selectOnly;
pub const toggleSelection = view_mod.toggleSelection;
pub const isSelected = view_mod.isSelected;
pub const pidAt = view_mod.pidAt;
pub const filterSpec = view_mod.filterSpec;
pub const setError = view_mod.setError;
pub const clearError = view_mod.clearError;
pub const applyLayout = view_mod.applyLayout;

pub const kickSample = sample_mod.kickSample;
pub const adoptPending = sample_mod.adoptPending;
pub const gateHidden = sample_mod.gateHidden;
pub const gateShown = sample_mod.gateShown;
pub const gateTick = sample_mod.gateTick;
pub const pushSample = sample_mod.pushSample;

pub const paint = paint_mod.paint;
pub const columnAt = paint_mod.columnAt;
pub const columnSortKey = paint_mod.columnSortKey;
pub const thumbMin = paint_mod.thumbMin;
pub const thumbWidth = paint_mod.thumbWidth;

pub const onKill = procs_mod.onKill;
pub const onNewProcess = procs_mod.onNewProcess;

pub const Focusable = input_mod.Focusable;
pub const focus_count = input_mod.focus_count;
pub const nextFocus = input_mod.nextFocus;
pub const nextVisibleFocus = input_mod.nextVisibleFocus;
pub const handleKey = input_mod.handleKey;
pub const caretIndex = input_mod.caretIndex;
pub const ensureCaret = input_mod.ensureCaret;
pub const moveFocus = input_mod.moveFocus;
pub const noteFocus = input_mod.noteFocus;
pub const syncFocus = input_mod.syncFocus;
pub const onFilterChanged = input_mod.onFilterChanged;
pub const onLeftDown = input_mod.onLeftDown;
pub const onMouseMove = input_mod.onMouseMove;
pub const onThumbDrag = input_mod.onThumbDrag;
pub const onWheel = input_mod.onWheel;

pub const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyActivityMonitor");

const FILTER_ID: u16 = 100;
const SHOW_ALL_ID: u16 = 101;
const NEW_PROC_ID: u16 = 102;
const KILL_ID: u16 = 103;

/// The poll timer. `trend_gauge.sample_interval_ms` is the interval the ring was
/// sized for, so the ring really does hold ~90 s.
const SAMPLE_TIMER_ID: usize = 1;

/// A worker thread finished a sample and parked it in `pending`. WM_APP+1..+12
/// are taken (see App.zig / Window.zig / AgentIntegration.zig / RelayAccountRow.zig).
pub const WM_APP_ACTIVITY_SAMPLE: u32 = w32.WM_APP + 13;

/// A dial thread finished. Posted to the APP's message-only window (see the
/// header), `wparam` = a heap `*DialResult` the handler owns.
pub const WM_APP_ACTIVITY_DIALED: u32 = w32.WM_APP + 14;

/// A machine-list fetch finished. Same landing rules as the dial: the APP's
/// window, `wparam` = a heap `*MachineListResult` the handler owns.
pub const WM_APP_ACTIVITY_MACHINES: u32 = w32.WM_APP + 15;

/// A per-card metrics PROBE finished its dial (T298). Same landing rules again
/// — the APP's window, `wparam` = a heap `*ProbeResult` the handler owns — and
/// for the same reason: a probe dial that landed on a destroyed panel would be
/// discarded with a live connection inside it. WM_APP+16..+22 are taken (see
/// SessionRoster / RemoteReconnect / RestoreAllRelay / ViewerPane).
pub const WM_APP_ACTIVITY_PROBE: u32 = w32.WM_APP + 23;

/// Bound on every remote RPC the panel makes. A machine slow enough to miss
/// this is a machine the panel should report as unreachable rather than freeze
/// its worker on.
pub const rpc_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// Hard cap on rows carried into the view, matching the sampler's own
/// `default_limit`. Fixed-size state (order/selection/spawned) is sized to it, so
/// the panel allocates nothing per poll beyond its snapshot arena.
pub const max_rows: usize = remote_proc.default_limit;

/// UTF-16 units read out of the filter EDIT in one go, NUL included — so at
/// most `filter_wide_cap - 1` characters of the field take part in the filter.
/// `needle_buf` is derived from this rather than chosen next to it, because the
/// two sizes drifting apart is exactly what T989 was.
pub const filter_wide_cap: usize = 256;

// ---------------------------------------------------------------------
// Palette (T308)
//
// Every color below used to be a `w32.RGB(...)` constant here - about thirty of
// them, each hand-picked against the one surface anybody ever checked, the
// `RGB(32,32,32)` "RenameDialog dark palette". On a light system theme the
// panel opened dark with light text on it while the window behind it was light.
//
// They are derived now, from the same two inputs `Window.chromePalette`
// resolves the chrome from: the surface `window-theme` puts the app on, and the
// accent the user picked. `panel_theme` owns the derivation and its floors;
// this file only converts to COLORREF.
// ---------------------------------------------------------------------

/// The panel palette, as COLORREFs are needed. A method rather than a `const`
/// because the value is a live theme read and container-level consts are
/// comptime; `system_colors.panelPalette` memoizes it on its inputs, so the
/// per-painted-row calls below are a struct copy.
pub fn pal(self: *const ActivityMonitor) panel_theme.Panel {
    return palFor(self.app);
}

fn palFor(app: *App) panel_theme.Panel {
    const bg = app.config.background;
    return system_colors.panelPalette(
        app.config.@"window-theme",
        .{ .r = bg.r, .g = bg.g, .b = bg.b },
    );
}

/// A `panel_theme` color as the COLORREF every GDI call here wants.
pub fn cr(c: panel_theme.Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

var class_registered: bool = false;
/// The panel surface and the filter field. Keyed on the color they were made
/// for (T308): a GDI brush is immutable, so a theme flip has to mean a new
/// object rather than a stale handle painting the old palette forever.
var bg_brush: brush_cache.CachedBrush = .{};
var field_brush: brush_cache.CachedBrush = .{};

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
pub const max_monitors: usize = 8;
pub var open_keys: [max_monitors]?Source = @splat(null);
pub var open_wins: [max_monitors]?*ActivityMonitor = @splat(null);

/// Handed to each panel at open so an in-flight dial can tell "my panel is
/// still there" from "a DIFFERENT panel took my slot after mine closed". A slot
/// index alone cannot: slots are reused the moment they are freed.
pub var next_serial: u64 = 1;

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
// Snapshot
// ---------------------------------------------------------------------

/// One poll's worth of data, built entirely on the worker thread. Everything the
/// rows point at lives in `arena`, so adopting a snapshot is a pointer swap and
/// retiring one is a single `deinit` — no per-string frees to get wrong.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    rows: []rows_mod.Row,
    host: remote_protocol.HostMetrics,
    truncated: bool,
    /// This process, the root of the ghoztty-spawned tree for a local source
    /// (`ghostty_local_proc_list` uses the same rule, embedded.zig:3214-3224).
    root_pid: i64,

    pub fn destroy(self: *Snapshot, alloc: Allocator) void {
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
/// The machines a live WINDOW is connected to, re-derived on every
/// `rebuildCards` (T301). Held separately from `machines` so a directory fetch
/// landing cannot wipe them and they cannot leak into one: the directory is
/// what the ACCOUNT can reach, this is what this app is already talking to, and
/// the two answer different questions.
win_machines: [max_machines]MachineEntry = @splat(.{}),
win_machine_count: usize = 0,

/// The per-card metrics probes (T298), one per INACTIVE machine. `probes[i]`
/// keeps a stable address for the panel's whole life because it is the metrics
/// callback's context.
probes: [probe_mod.max_probes]Probe = @splat(.{}),
/// Bumped every time the probe set is torn down wholesale. A dial that lands
/// carrying an older generation frees its connection instead of adopting it —
/// the same rule `source_gen` applies to sample workers.
probe_gen: u32 = 0,
/// Guards every probe's `host`/`last_ms`: written by control-reader threads,
/// read by the GUI thread when it rebuilds the cards.
probe_mutex: std.Thread.Mutex = .{},

/// The LOCAL card's reading while some OTHER machine is the active source
/// (Mac's `localCardTimer`, RemoteActivityMonitorView.swift:193-194). It needs
/// no connection — the box is right here — but it does need its own sampler:
/// `host_sampler` belongs to the ACTIVE source's worker thread, and folding a
/// second caller's ticks into its baseline would corrupt the CPU% the panel's
/// own gauge draws.
local_card_sampler: remote_metrics.Sampler = remote_metrics.Sampler.init(),
/// Null until the sampler has a baseline to difference against — the first
/// reading's CPU% is always 0 by construction, and a card printing `CPU 0%`
/// for a busy box is exactly the invented number this design refuses.
local_card: ?remote_protocol.HostMetrics = null,
local_card_samples: u32 = 0,
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

/// The action-error banner's text (Mac's `actionError`), empty when absent.
err_buf: [256]u8 = @splat(0),
err_len: usize = 0,

/// Trend rings, oldest -> newest, both 0..100.
cpu_ring: [gauge.ring_capacity]f32 = @splat(0),
mem_ring: [gauge.ring_capacity]f32 = @splat(0),
ring_len: usize = 0,

/// Whether a poll tick should enumerate at all (T290). A full process
/// enumeration every 1.5 s is the right cost for a panel someone is looking at
/// and pure waste for one that is minimized, hidden or on another virtual
/// desktop — which is where a panel left open for hours actually spends most of
/// its life. The two-state machine is in `sample_gate.zig`; this side supplies
/// the OS answers and carries out the action.
gate: sample_gate.Gate = .{},

/// Current view state.
sort: rows_mod.Sort = rows_mod.default_sort,
show_all: bool = false,
/// The filter box's text, UTF-8. Sized for what the SOURCE can hold rather
/// than for what a filter is expected to be (T989): `onFilterChanged` reads
/// `filter_wide_cap` UTF-16 units and UTF-8 needs up to three bytes per unit,
/// so anything smaller is a length at which typing crashes the app. It was
/// 128 bytes, and about 130 typed characters took the terminal down.
needle_buf: [(filter_wide_cap - 1) * 3]u8 = @splat(0),
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

/// Which stop keyboard focus sits on (T289). The four native children carry
/// real Win32 focus and this field only mirrors them; the carousel and the
/// table are OWNER-DRAWN regions of the panel's own window, so for those two
/// Win32 knows only "the panel" and this field is the only thing that says
/// which. §2.2 requires focus to be VISIBLE, which first requires it to be
/// KNOWN.
focus: Focusable = .filter,
/// Whether the panel's own window holds the keyboard focus. Maintained from
/// WM_SETFOCUS/WM_KILLFOCUS rather than read from `GetFocus` at paint time:
/// the ring must disappear when the panel is deactivated, and a painter that
/// asked `GetFocus` would be asking about whichever window is active instead.
panel_focused: bool = false,
/// The table's CARET — the row the arrow keys move from, and the row the focus
/// ring goes on. Distinct from the selection (T289): Windows list views draw
/// focus on the caret row separately from the selection fill, so tabbing into
/// an unselected table can show where the keyboard is without selecting
/// anything. Keyed by pid for the same reason the selection is — a re-sort or
/// a re-poll moves rows under it. 0 means "no caret".
caret_pid: i64 = 0,

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
            existing.moveFocus(.filter);
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

    // The caption follows the same surface the body does (T563).
    system_colors.applyPanelChrome(hwnd, self.pal());

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
    self.moveFocus(.filter);

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
    // Probe whatever we already know about (T298) — a live window's machine is
    // knowable with no directory at all. The fetch below adds the rest.
    self.syncProbes();
    self.startMachineList();

    // First poll immediately, then on the interval — a panel that shows nothing
    // for a second and a half reads as broken. `kickSample` is a no-op while a
    // dial is in flight.
    self.kickSample();
    _ = w32.SetTimer(hwnd, SAMPLE_TIMER_ID, @intCast(gauge.sample_interval_ms), null);
}

// ---------------------------------------------------------------------
// Source switching
// ---------------------------------------------------------------------

/// Retitle the window for the current source — Mac retitles on every switch
/// (`RemoteActivityMonitor.swift:41`, :54).
pub fn setTitle(self: *ActivityMonitor) void {
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

    // The probes first (T298), and by the same rule as everything below:
    // unsubscribe before freeing, so no control-reader thread can be inside a
    // callback holding a `*Probe` that lives in the struct we are about to
    // destroy. A dial still in flight is handled by the generation bump —
    // it lands on `onProbeDialed`'s panel-is-gone path and frees itself.
    self.stopProbes();

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
    // Sizes and weights both come from the layout, which gets them from
    // `type_ramp` (T313) — a literal 600 here is how a weight drifts from the
    // ramp while the size still agrees with it. `num_font` is the one
    // deliberate exception: same ramp height, Consolas face, because the
    // numeric columns are tabular (see the note above `drawTable`).
    self.font = makeFont(l.font_h, type_ramp.weight_normal, type_ramp.face);
    self.num_font = makeFont(l.font_h, type_ramp.weight_normal, "Consolas");
    self.title_font = makeFont(l.title_font_h, l.title_font_weight, type_ramp.face);
    self.caption_font = makeFont(l.caption_font_h, type_ramp.weight_normal, type_ramp.face);
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
    // Warm the palette memo so the first paint does not resolve on the critical
    // path; the brushes are created on demand, keyed on their color.
    _ = palFor(app);
    return registerClassWith(app.hinstance);
}

/// The registration itself, taking only what the class needs. Split out so the
/// class-level redraw test (T467) can register it without standing up an `App`
/// — the palette warm-up above is the only part that needs one.
fn registerClassWith(hinstance: ?w32.HINSTANCE) ?void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (T467): every pixel this window paints is
        // derived from the CURRENT client size - `layout()` feeds
        // `GetClientRect` straight into `layout_mod.layout`, and the gauges,
        // the control bar, the table columns and the dividers are all measured
        // against `l.client_w`/`l.client_h`. This is a user-resizable
        // `WS_OVERLAPPEDWINDOW` panel, and `WM_SIZE` only re-places the child
        // controls, so without this a drag repaints the newly exposed strip
        // and leaves the table drawn at the width it used to have. Paired with
        // the `WM_ERASEBKGND => 1` below, the stale pixels are not even erased.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        // Null: a class background brush is captured at registration, which
        // happens once per process, so it cannot follow a theme flip. Nothing
        // is lost - `WM_ERASEBKGND` already returns 1 here because the paint
        // covers the whole client.
        .hbrBackground = null,
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
            // Coming back from another virtual desktop produces no message of
            // its own — but it does produce a paint. `gateShown` is a no-op
            // unless the gate is suspended, so this costs a branch per paint
            // and buys a fresh table on the frame the panel reappears.
            self.gateShown();
            return 0;
        },
        // The same panel into a caller's DC, so a pixel probe can photograph it
        // synchronously rather than through DWM's asynchronous copy of the
        // composited surface, which tears mid-row (T835/T940). This panel's
        // probes read TABLE COLUMNS, and a torn frame stops mid-text at a glyph
        // boundary — which is why the readings it produces look like stable
        // layout values rather than noise, and why they sent one investigation
        // into the column-share math for nothing.
        //
        // No `gateShown` here: this is a photograph, not the panel coming back
        // into view, and refreshing the table underneath a capture would change
        // the thing being measured.
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            self.paint(@ptrFromInt(wparam));
            return 0;
        },
        w32.WM_SIZE => {
            self.applyLayout();
            if (wparam == w32.SIZE_MINIMIZED) self.gateHidden() else self.gateShown();
            return 0;
        },
        w32.WM_SHOWWINDOW => {
            if (wparam == 0) self.gateHidden() else self.gateShown();
            // Observed, not consumed: DefWindowProc owns what this message
            // means for the window itself.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
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
                // The gate — not `kickSample` — decides whether this tick
                // enumerates. A tick is also the ONLY thing that can notice a
                // virtual-desktop switch, which has no message.
                self.gateTick();
                // The tick is also the probes' clock (T298): it is what re-dials
                // one whose backoff expired and what notices one that has gone
                // quiet. Cheap by construction — a short loop plus two OS calls
                // for the Local card — and a no-op while the gate is suspended.
                self.syncProbes();
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
            // Win32 focus is now on the panel, which cannot say WHICH of its
            // two owner-drawn regions the user meant. The table is the default
            // because it owns everything below the carousel band; `onLeftDown`
            // overrides it for a click inside that band.
            self.noteFocus(.table);
            self.onLeftDown(loWordSigned(lparam), hiWordSigned(lparam), wparam);
            return 0;
        },
        // §2.2's ring is only honest while the panel really holds the
        // keyboard. Tracked from the messages rather than asked of `GetFocus`
        // at paint time: `GetFocus` answers for whichever window is active,
        // so a deactivated panel would keep painting a ring over nothing.
        w32.WM_SETFOCUS => {
            self.panel_focused = true;
            if (self.focus == .table) self.ensureCaret();
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_KILLFOCUS => {
            self.panel_focused = false;
            _ = w32.InvalidateRect(hwnd, null, 0);
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
        // A light/dark flip or an accent change reaches TOP-LEVEL windows, and
        // a panel is one (T308). Drop the cached accent and repaint: the
        // palette is derived per paint, so the repaint IS the re-theme.
        //
        // Through the shared helper since T307, which redraws the CHILDREN too.
        // This panel's EDIT and STATIC controls take their colors from a
        // `WM_CTLCOLOR*` reply, and that message is only sent when the child
        // itself repaints — an `InvalidateRect` on the panel alone left every
        // field painted in the old palette.
        w32.WM_SETTINGCHANGE, w32.WM_DWMCOLORIZATIONCOLORCHANGED => {
            if (msg != w32.WM_SETTINGCHANGE or system_colors.isColorSettingChange(lparam)) {
                system_colors.repaintForColorChange(hwnd);
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const p = self.pal();
            _ = w32.SetTextColor(hdc, cr(p.text));
            _ = w32.SetBkColor(hdc, cr(p.field));
            if (field_brush.get(cr(p.field))) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const p = self.pal();
            _ = w32.SetTextColor(hdc, cr(p.label));
            _ = w32.SetBkColor(hdc, cr(p.bg));
            if (bg_brush.get(cr(p.bg))) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
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

// T467: this is the one panel on Windows the USER resizes by dragging its
// frame, and every pixel of it — the gauges, the control bar, the table's
// columns, the dividers — is measured against the client rect that `layout()`
// reads back. `WM_SIZE` only re-places the child controls, so the owner-painted
// table's repaint is entirely the class's job.
test "activity monitor class: a resize invalidates the whole panel" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClassWith(hinst) orelse return error.SkipZigTest;
    try class_redraw.expectResizeInvalidatesWholeClient(CLASS_NAME);
}
