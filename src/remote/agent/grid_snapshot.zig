//! Headless per-session terminal emulator for the **re-attach grid snapshot**
//! (session-persistence FIX 2).
//!
//! ## Why this exists
//!
//! The agent keeps only a bounded **raw byte ring** per session (`session.zig`),
//! and on re-attach it replays the ring tail (design §7.3). When deep scrollback
//! overran the ring, the exact resume point is evicted: the client showed a
//! `... bytes of scrollback lost ...` marker and — critically — often a **blank
//! pane**. The worst case is a full-screen (alt-screen) app such as Claude Code
//! or vim whose `\x1b[?1049h` (enter-alt) sequence scrolled out of the ring long
//! ago: replaying only the ring tail paints alt-screen writes onto the client's
//! *primary* screen (the mode switch is gone), leaving the real screen blank.
//!
//! Raw-ring replay can never reconstruct state written before the ring window.
//! The only thing that can is a component that watched the output **as it
//! happened**. So each session drives one of these tiny, side-effect-free
//! emulators continuously (fed the same bytes the ring records). On attach the
//! agent serializes the current visible screen as a self-contained VT repaint —
//! the "grid snapshot" the design always anticipated ("the forthcoming grid
//! snapshot makes the visible grid exact", `server.zig` handleAttach) — so the
//! pane repaints exactly and is **never blank**, even when the paint predates the
//! ring.
//!
//! ## Cost
//!
//! One `terminal.Terminal` per session with a bounded `max_scrollback`
//! (`max_scrollback_bytes`, below), plus VT parsing of
//! each output chunk — the same work the GUI already does per pane, done once in
//! the daemon instead. Idle sessions cost nothing. The emulator is `readonly`
//! (the `stream_terminal` handler ignores clipboard/DA/DSR/etc.), so it never
//! writes back to the pty or has any side effect beyond updating its own grid.
//!
//! ## Threading
//!
//! Not internally synchronized. The `Server` only ever touches a session's
//! emulator under `store.mutex` — `feed`/`resize` from `onChildOutput` and
//! `snapshotAlloc` from `handleAttach` both hold it — so access is single
//! threaded by the store lock, exactly like the ring.
//!
//! ## Skew safety
//!
//! Emitting the snapshot is gated on the negotiated `grid_snapshot` HELLO
//! capability (`protocol.zig`): a peer that doesn't advertise it (an older app,
//! or an older agent that never sends one) falls back to today's ring-only
//! replay. The snapshot itself is plain VT that any client's emulator renders, so
//! there is no new opcode and no unknown-frame hazard across the skew.

const std = @import("std");
const Allocator = std.mem.Allocator;
// Relative imports of src/terminal — the same way `src/pty.zig` (already in the
// agent's module graph via pty_child.zig) reaches it, so terminal stays a single
// module. The agent-core test aggregator roots at `src/` (via
// `src/agent_core_test.zig`) precisely so this `../../` stays inside its module
// path.
const terminal = @import("../../terminal/main.zig");
const Selection = @import("../../terminal/Selection.zig");
const stream_terminal = @import("../../terminal/stream_terminal.zig");
const formatter = @import("../../terminal/formatter.zig");

const log = std.log.scoped(.grid_snapshot);

/// A pty geometry can legitimately be 0 before the first resize; the emulator
/// needs at least a 1x1 grid, and we cap the upper bound so a bogus dimension
/// can't request a giant allocation.
fn clampDim(v: u16) u16 {
    return std.math.clamp(v, 1, 1000);
}

/// The emulator's per-session scrollback ceiling, in BYTES — the same unit
/// `terminal.Terminal.Options.max_scrollback` takes, so this IS the allocation
/// bound rather than a row count that implies one.
///
/// Deliberately chosen, not defaulted (the terminal's own default is 10 MB): the
/// agent already carries a 2 MB raw ring per session (`session.zig`), and this is
/// a SECOND per-session allocation living in the same daemon. 1 MiB of grid is
/// several hundred rows at ordinary widths — enough that a re-attached pane comes
/// back with usable history above the fold — and puts the agent's per-session
/// ceiling at ~3 MB, which is the number to quote when the budget is questioned.
///
/// It is also what makes `T621`'s replay saving real: a snapshot-less ATTACH can
/// skip the whole raw ring precisely because this scrollback is reflowed to the
/// ATTACHING client's geometry, which the ring (a concatenation of segments drawn
/// at different sizes) can never be.
pub const max_scrollback_bytes: usize = 1024 * 1024;

/// What a snapshot should cover.
pub const SnapshotOptions = struct {
    /// Include the retained scrollback ABOVE the visible screen.
    ///
    /// Off by default, and that default is load-bearing: on a DELTA re-attach the
    /// client already holds this history (it was streamed to it before the
    /// disconnect, and the ring gap-fill covers the rest), so repainting it would
    /// duplicate it. Only a snapshot-less attach — a pane this viewer has never
    /// had open, or one rebuilt from a layout blob — wants it.
    scrollback: bool = false,
};

pub const GridEmulator = struct {
    alloc: Allocator,
    term: terminal.Terminal,
    stream: stream_terminal.Stream,

    /// Create a heap-pinned emulator. It MUST be heap-allocated (not moved)
    /// because the internal `stream` holds a `*Terminal` into `self.term`.
    pub fn create(alloc: Allocator, rows: u16, cols: u16) Allocator.Error!*GridEmulator {
        const self = try alloc.create(GridEmulator);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.term = try terminal.Terminal.init(alloc, .{
            .rows = clampDim(rows),
            .cols = clampDim(cols),
            // Bounded scrollback so a snapshot can carry history the attaching
            // client has never seen, reflowed to ITS geometry (T621). See
            // `max_scrollback_bytes` for why this number.
            .max_scrollback = max_scrollback_bytes,
        });
        errdefer self.term.deinit(alloc);
        // initAlloc so OSC parsing (e.g. OSC 7 pwd, hyperlinks) can allocate; the
        // readonly handler still ignores side-effecting sequences.
        self.stream = stream_terminal.Stream.initAlloc(
            alloc,
            stream_terminal.Handler.init(&self.term),
        );
        return self;
    }

    pub fn destroy(self: *GridEmulator) void {
        self.stream.deinit();
        self.term.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Feed a chunk of child output. VT parse/apply errors are swallowed (logged
    /// by the handler) so this matches `Session.recordOutput`'s non-failing
    /// contract — a transient allocation failure degrades the snapshot's fidelity
    /// but never propagates.
    pub fn feed(self: *GridEmulator, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    /// Track the session's live geometry so the serialized screen matches the
    /// pty the child actually sees. No-op when already at the requested size
    /// (`Terminal.resize` short-circuits too, but we avoid the clamp/call). Best
    /// effort; a failure leaves the prior size.
    pub fn ensureSize(self: *GridEmulator, rows: u16, cols: u16) void {
        const c = clampDim(cols);
        const r = clampDim(rows);
        if (self.term.cols == c and self.term.rows == r) return;
        self.term.resize(self.alloc, c, r) catch |err| {
            log.warn("grid emulator resize failed: {}", .{err});
        };
    }

    /// True when the child is currently on the alternate screen (a full-screen
    /// app such as vim / Claude Code). The Server uses this to decide whether the
    /// raw ring tail is safe to replay: alt-screen paint written after an evicted
    /// `?1049h` must NOT be replayed onto the client's primary screen.
    pub fn onAlternateScreen(self: *const GridEmulator) bool {
        return self.term.screens.active_key == .alternate;
    }

    /// The pagelist range the snapshot covers.
    ///
    /// The formatter's own default (`.{ .selection = null }`) is the WHOLE
    /// pagelist, which with the emulator's bounded scrollback now means history
    /// too — so the no-scrollback case has to say "active area only" explicitly,
    /// and that is what keeps a delta re-attach byte-for-byte what it was before
    /// T621 gave the emulator any history to hold.
    fn contentSelection(
        self: *const GridEmulator,
        opts: SnapshotOptions,
    ) formatter.ScreenFormatter.Content {
        // Whole pagelist: history (if any) then the visible screen.
        if (opts.scrollback) return .{ .selection = null };

        const pages = &self.term.screens.active.pages;
        const tl = pages.getTopLeft(.active);
        const br = pages.getBottomRight(.screen) orelse return .{ .selection = null };
        // Everything ever written is ABOVE the active area (a screen scrolled
        // fully into history and left blank). There is no visible content to
        // emit, and emitting the reversed range would dump the history the
        // caller just said it did not want.
        if (br.before(tl)) return .none;
        return .{ .selection = Selection.init(tl, br, false) };
    }

    /// True when the emulator is holding scrollback above the visible screen —
    /// i.e. a `.{ .scrollback = true }` snapshot would carry more than the screen.
    /// False on the alternate screen, which has no history by construction.
    pub fn hasScrollback(self: *const GridEmulator) bool {
        if (self.term.screens.active_key == .alternate) return false;
        const pages = &self.term.screens.active.pages;
        return pages.getTopLeft(.screen).node != pages.getTopLeft(.active).node or
            pages.getTopLeft(.screen).y != pages.getTopLeft(.active).y;
    }

    /// Serialize the current screen as a self-contained VT repaint owned by `gpa`
    /// (caller frees). The client feeds these bytes straight into its terminal,
    /// repainting the exact on-screen grid — plus, when `opts.scrollback` is set,
    /// the retained history above it.
    ///
    /// The repaint re-establishes terminal state (modes incl. alt-screen, cursor,
    /// SGR, scrolling region, tabstops, pwd, hyperlinks) but NOT the palette:
    /// VT `emit` renders indexed colors as palette *indices*, which the client
    /// resolves against its OWN configured palette — emitting the emulator's
    /// (default) palette would clobber the user's theme on reconnect.
    pub fn snapshotAlloc(
        self: *GridEmulator,
        gpa: Allocator,
        opts: SnapshotOptions,
    ) Allocator.Error![]u8 {
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        const w = &buf.writer;

        // On the PRIMARY screen the repaint must start from a clean viewport, so
        // prefix home + erase-screen (ED2). ED2 erases the visible screen only —
        // scrollback history is preserved — then the screen is repainted over it.
        // On the ALTERNATE screen the `\x1b[?1049h` the formatter emits (via
        // `.modes`) itself switches to and clears the alt screen, so a manual
        // clear would be redundant (and would wrongly wipe the client's primary).
        if (self.term.screens.active_key != .alternate) {
            w.writeAll("\x1b[H\x1b[2J") catch return error.OutOfMemory;
        }

        var tf = formatter.TerminalFormatter.init(&self.term, .{ .emit = .vt });
        tf.content = self.contentSelection(opts);
        tf.extra = .{
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = true,
            .keyboard = true,
            .screen = .all,
        };
        tf.format(w) catch return error.OutOfMemory;

        return buf.toOwnedSlice();
    }
};

const testing = std.testing;

test "GridEmulator: primary-screen snapshot clears then repaints the visible text" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 24, 80);
    defer emu.destroy();

    emu.feed("hello world");
    try testing.expect(!emu.onAlternateScreen());

    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);

    // Primary screen: prefixed with home + erase-screen so the repaint lands
    // cleanly, then the visible text; no alt-screen enter.
    try testing.expect(std.mem.startsWith(u8, snap, "\x1b[H\x1b[2J"));
    try testing.expect(std.mem.indexOf(u8, snap, "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "?1049h") == null);
}

test "GridEmulator: alt-screen snapshot re-enters alt and repaints its content" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 24, 80);
    defer emu.destroy();

    // Enter the alternate screen, then paint — the shape of a full-screen app.
    emu.feed("\x1b[?1049h");
    emu.feed("ALTCONTENT");
    try testing.expect(emu.onAlternateScreen());

    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);

    // The snapshot must re-enter the alt screen (so the client switches to it)
    // and repaint the content. It must NOT prefix the primary home+erase (that
    // would wrongly clear the client's primary screen); `?1049h` clears alt.
    try testing.expect(std.mem.indexOf(u8, snap, "?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "ALTCONTENT") != null);
    try testing.expect(!std.mem.startsWith(u8, snap, "\x1b[H\x1b[2J"));
}

test "GridEmulator: reproduces the CURRENT screen when an old alt-enter would be evicted" {
    // The real re-attach bug: a full-screen app entered the alt screen long ago
    // (that `?1049h` would have scrolled out of the 2 MB ring) then repainted
    // many times. A continuous emulator still knows it's on the alt screen and
    // reproduces the LAST paint exactly — which ring-tail replay alone cannot.
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 10, 40);
    defer emu.destroy();

    emu.feed("\x1b[?1049h\x1b[2J");
    var i: usize = 0;
    while (i < 200) : (i += 1) emu.feed("\x1b[H\x1b[2Jframe-old");
    emu.feed("\x1b[H\x1b[2JFRAME-FINAL");

    try testing.expect(emu.onAlternateScreen());
    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);

    try testing.expect(std.mem.indexOf(u8, snap, "?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "FRAME-FINAL") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "frame-old") == null);
}

test "GridEmulator: ensureSize reflows to the attach geometry" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 24, 80);
    defer emu.destroy();
    emu.feed("resize me");
    emu.ensureSize(30, 100);
    try testing.expectEqual(@as(u16, 100), emu.term.cols);
    try testing.expectEqual(@as(u16, 30), emu.term.rows);
    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "resize me") != null);
}

test "GridEmulator: retains scrollback and serializes it only when asked" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 5, 40);
    defer emu.destroy();

    // Twenty lines through a five-row screen: the first fifteen are scrollback,
    // the last five are the visible screen.
    var i: usize = 1;
    while (i <= 20) : (i += 1) {
        var buf: [32]u8 = undefined;
        emu.feed(std.fmt.bufPrint(&buf, "line-{d}\r\n", .{i}) catch unreachable);
    }
    try testing.expect(emu.hasScrollback());

    // Default (a DELTA re-attach): the visible screen only. `line-1` scrolled
    // off long ago and must not come back — the client already has it.
    const screen_only = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(screen_only);
    try testing.expect(std.mem.indexOf(u8, screen_only, "line-1\r\n") == null);
    try testing.expect(std.mem.indexOf(u8, screen_only, "line-20") != null);

    // Scrollback (a snapshot-less ATTACH): the history rides along, in order,
    // ahead of the visible rows.
    const with_history = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(with_history);
    const first = std.mem.indexOf(u8, with_history, "line-1\r\n") orelse
        return error.MissingScrollback;
    const last = std.mem.indexOf(u8, with_history, "line-20") orelse
        return error.MissingScreen;
    try testing.expect(first < last);
    try testing.expect(with_history.len > screen_only.len);
}

test "GridEmulator: a scrollback snapshot reflows to the ATTACH geometry" {
    // The property a stored, app-side snapshot cannot have: the history is
    // serialized at the size the attaching client just asked for, not the size it
    // happened to be drawn at.
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 4, 20);
    defer emu.destroy();

    var i: usize = 1;
    while (i <= 12) : (i += 1) {
        var buf: [32]u8 = undefined;
        emu.feed(std.fmt.bufPrint(&buf, "row-{d}\r\n", .{i}) catch unreachable);
    }

    emu.ensureSize(10, 60);
    try testing.expectEqual(@as(u16, 60), emu.term.cols);

    const snap = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "row-1\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "row-12") != null);
}

test "GridEmulator: the alt screen has no scrollback to carry" {
    // Asking for scrollback on a full-screen app is not an error and does not
    // change the payload: the alternate screen keeps no history by construction.
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 6, 30);
    defer emu.destroy();

    emu.feed("\x1b[?1049h");
    emu.feed("ALTCONTENT");
    try testing.expect(emu.onAlternateScreen());
    try testing.expect(!emu.hasScrollback());

    const a = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(a);
    const b = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(b);
    try testing.expectEqualStrings(a, b);
}

test "GridEmulator: a screen scrolled entirely into history emits no content" {
    // The guard in `contentSelection`: everything ever written is ABOVE the active
    // area, so the no-scrollback range would be reversed. Emitting it backwards
    // would dump the very history the caller said it did not want.
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 3, 20);
    defer emu.destroy();

    emu.feed("alpha\r\nbravo\r\ncharlie\r\n\r\n\r\n\r\n");

    const screen_only = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(screen_only);
    try testing.expect(std.mem.indexOf(u8, screen_only, "alpha") == null);

    const with_history = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(with_history);
    try testing.expect(std.mem.indexOf(u8, with_history, "alpha") != null);
}
