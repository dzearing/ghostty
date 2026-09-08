//! Primary terminal IO ("termio") state. This maintains the terminal state,
//! pty, subprocess, etc. This is flexible enough to be used in environments
//! that don't have a pty and simply provides the input/output using raw
//! bytes.
pub const Termio = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.EnvMap;
const posix = std.posix;
const termio = @import("../termio.zig");
const StreamHandler = @import("stream_handler.zig").StreamHandler;
const terminalpkg = @import("../terminal/main.zig");
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const windows = internal_os.windows;
const configpkg = @import("../config.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const session_notice = @import("session_notice.zig");
const history_guard = @import("history_guard.zig");

const log = std.log.scoped(.io_exec);

/// Mutex state argument for queueMessage.
pub const MutexState = enum { locked, unlocked };

/// Allocator
alloc: Allocator,

/// This is the implementation responsible for io.
backend: termio.Backend,

/// The derived configuration for this termio implementation.
config: DerivedConfig,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminalpkg.Terminal,

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that
/// a repaint should happen. Must remain a pointer — see Options.zig
/// (IOCP xev.Async copies lose notifications).
renderer_wakeup: *xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// The cached size info
size: renderer.Size,

/// The mailbox implementation to use.
mailbox: termio.Mailbox,

/// The stream parser. This parses the stream of escape codes and so on
/// from the child process and calls callbacks in the stream handler.
terminal_stream: StreamHandler.Stream,

/// Last time the cursor was reset. This is used to prevent message
/// flooding with cursor resets.
last_cursor_reset: ?std.time.Instant = null,

/// State we have for thread enter. This may be null if we don't need
/// to keep track of any state or if its already been freed.
thread_enter_state: ?*ThreadEnterState = null,

/// Set by `shutdown` (GUI thread, right before it joins the IO thread).
/// Producers that push to the SHARED app/surface mailbox check this in
/// their retry loops: that queue can't be closed (other surfaces still
/// use it), so a pusher that can't make progress needs this flag to know
/// the surface is dying and the message should be dropped instead of
/// waiting forever (a forever wait there deadlocks the joining GUI
/// thread if it's the only consumer).
closing: std.atomic.Value(bool) = .init(false),

/// Latest-wins resize slot. RESIZE is control state where only the FINAL
/// geometry matters, so — unlike write DATA — it must never be dropped by the
/// bounded `mailbox`. A session re-attach floods that mailbox with replayed
/// output; a `.resize` pushed during the flood used to be dropped (see
/// mailbox.zig's 50ms give-up), leaving the pty at a stale width so re-attached
/// panes rendered narrow/blank until a manual resize. `queueMessage` now stashes
/// the newest geometry here instead of enqueueing it, and the IO thread applies
/// it on every drain, so a full data queue can never crowd it out. Guarded by
/// `pending_resize_mutex`; null = nothing pending.
pending_resize: ?renderer.Size = null,
pending_resize_mutex: std.Thread.Mutex = .{},

/// T423: a session-interrupted notice has been written to this pane's terminal
/// and has not been folded above the viewport yet. Armed by the backend right
/// after the notice is written, consumed by `settleNotice` on the last tick
/// before the child's first bytes reach the parser — which is the only moment
/// no resize can interleave. Keeping it there afterwards is `notice_guard`'s
/// job, not this flag's. Touched only on the IO thread.
notice_fold_armed: bool = false,

/// T423: tracks the row just BELOW a settled session-interrupted notice, for
/// the pane's whole life. A tracked pin is the only handle that survives a
/// reflow, which is exactly the event that drags the notice back into the
/// active area where the child's repaint erases it. Null when this pane never
/// showed a notice, which is the overwhelming majority of panes.
notice_guard: ?*terminalpkg.Pin = null,

/// The state we need to keep around only until we enter the IO
/// thread. Then we can throw it all away.
const ThreadEnterState = struct {
    arena: ArenaAllocator,

    /// Initial input to send to the subprocess after starting. This
    /// memory is freed once the subprocess start is attempted, even
    /// if it fails, because Exec only starts once.
    input: configpkg.io.RepeatableReadableIO,

    pub fn create(
        alloc: Allocator,
        config: *const configpkg.Config,
    ) !?*ThreadEnterState {
        // If we have no input then we have no thread enter state
        if (config.input.list.items.len == 0) return null;

        // Create our arena allocator
        var arena = ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        // Allocate our ThreadEnterState
        const ptr = try arena_alloc.create(ThreadEnterState);

        // Copy the input from the config
        const input = try config.input.cloneParsed(arena_alloc);

        // Return the initialized state
        ptr.* = .{
            .arena = arena,
            .input = input,
        };
        return ptr;
    }

    pub fn destroy(self: *ThreadEnterState) void {
        self.arena.deinit();
    }

    /// Prepare the inputs for use. Allocations happen on the arena.
    pub fn prepareInput(
        self: *ThreadEnterState,
    ) (Allocator.Error || error{InputNotFound})![]const Input {
        const alloc = self.arena.allocator();

        var input = try alloc.alloc(
            Input,
            self.input.list.items.len,
        );
        for (self.input.list.items, 0..) |item, i| {
            input[i] = switch (item) {
                .raw => |v| .{ .string = try alloc.dupe(u8, v) },
                .path => |path| file: {
                    const f = std.fs.cwd().openFile(
                        path,
                        .{},
                    ) catch |err| {
                        log.warn("failed to open input file={s} err={}", .{
                            path,
                            err,
                        });
                        return error.InputNotFound;
                    };

                    break :file .{ .file = f };
                },
            };
        }

        return input;
    }

    const Input = union(enum) {
        string: []const u8,
        file: std.fs.File,
    };
};

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    palette: terminalpkg.color.Palette,
    image_storage_limit: usize,
    cursor_style: terminalpkg.CursorStyle,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.TerminalColor,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    clipboard_write: configpkg.ClipboardAccess,
    enquiry_response: []const u8,
    conditional_state: configpkg.ConditionalState,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const palette: terminalpkg.color.Palette = palette: {
            if (config.@"palette-generate") generate: {
                if (config.palette.mask.findFirstSet() == null) {
                    // If the user didn't set any values manually, then
                    // we're using the default palette and we don't need
                    // to apply the generation code to it.
                    break :generate;
                }

                break :palette terminalpkg.color.generate256Color(config.palette.value, config.palette.mask, config.background.toTerminalRGB(), config.foreground.toTerminalRGB(), config.@"palette-harmonious");
            }

            break :palette config.palette.value;
        };

        return .{
            .palette = palette,
            .image_storage_limit = config.@"image-storage-limit",
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .clipboard_write = config.@"clipboard-write",
            .enquiry_response = try alloc.dupe(u8, config.@"enquiry-response"),
            .conditional_state = config._conditional_state,

            // This has to be last so that we copy AFTER the arena allocations
            // above happen (Zig assigns in order).
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// Initialize the termio state.
///
/// This will also start the child process if the termio is configured
/// to run a child process.
pub fn init(self: *Termio, alloc: Allocator, opts: termio.Options) !void {
    // The default terminal modes based on our config.
    const default_modes: terminalpkg.ModePacked = modes: {
        var modes: terminalpkg.ModePacked = .{};

        // Setup our initial grapheme cluster support if enabled. We use a
        // switch to ensure we get a compiler error if more cases are added.
        switch (opts.full_config.@"grapheme-width-method") {
            .unicode => modes.grapheme_cluster = true,
            .legacy => {},
        }

        // Set default cursor blink settings
        modes.cursor_blinking = opts.config.cursor_blink orelse true;

        break :modes modes;
    };

    // Create our terminal
    var term = try terminalpkg.Terminal.init(alloc, opts: {
        const grid_size = opts.size.grid();
        break :opts .{
            .cols = grid_size.columns,
            .rows = grid_size.rows,
            .max_scrollback = opts.full_config.@"scrollback-limit",
            .default_modes = default_modes,
            .colors = .{
                .background = .init(opts.config.background.toTerminalRGB()),
                .foreground = .init(opts.config.foreground.toTerminalRGB()),
                .cursor = cursor: {
                    const color = opts.config.cursor_color orelse break :cursor .unset;
                    const rgb = color.toTerminalRGB() orelse break :cursor .unset;
                    break :cursor .init(rgb);
                },
                .palette = .init(opts.config.palette),
            },
            .kitty_image_storage_limit = opts.config.image_storage_limit,
            .kitty_image_loading_limits = .all,
        };
    });
    errdefer term.deinit(alloc);

    // Set our default cursor style
    term.screens.active.cursor.cursor_style = opts.config.cursor_style;

    // Setup our terminal size in pixels for certain requests.
    term.width_px = term.cols * opts.size.cell.width;
    term.height_px = term.rows * opts.size.cell.height;

    // Setup our backend.
    var backend = opts.backend;
    backend.initTerminal(&term);

    // Create our stream handler. This points to memory in self so it
    // isn't safe to use until self.* is set.
    const handler: StreamHandler = .{
        .alloc = alloc,
        .closing = &self.closing,
        .termio_mailbox = &self.mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .size = &self.size,
        .terminal = &self.terminal,
        .osc_color_report_format = opts.config.osc_color_report_format,
        .clipboard_write = opts.config.clipboard_write,
        .enquiry_response = opts.config.enquiry_response,
        .default_cursor_style = opts.config.cursor_style,
        .default_cursor_blink = opts.config.cursor_blink,
    };

    const thread_enter_state = try ThreadEnterState.create(
        alloc,
        opts.full_config,
    );

    self.* = .{
        .alloc = alloc,
        .terminal = term,
        .config = opts.config,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .size = opts.size,
        .backend = backend,
        .mailbox = opts.mailbox,
        .terminal_stream = .initAlloc(alloc, handler),
        .thread_enter_state = thread_enter_state,
    };
}

pub fn deinit(self: *Termio) void {
    self.backend.deinit();
    // Before the terminal, which owns the pin's storage (T423).
    if (self.notice_guard) |p| {
        self.terminal.screens.active.pages.untrackPin(p);
        self.notice_guard = null;
    }
    self.terminal.deinit(self.alloc);
    self.config.deinit();
    self.mailbox.deinit(self.alloc);

    // Clear any StreamHandler state
    self.terminal_stream.deinit();

    // Clear any initial state if we have it
    if (self.thread_enter_state) |v| v.destroy();
}

pub fn threadEnter(
    self: *Termio,
    thread: *termio.Thread,
    data: *ThreadData,
) !void {
    // Always free our thread enter state when we're done.
    defer if (self.thread_enter_state) |v| {
        v.destroy();
        self.thread_enter_state = null;
    };

    // If we have thread enter state then we're going to validate
    // and set that all up now so that we can error before we actually
    // start the command and pty.
    const inputs: ?[]const ThreadEnterState.Input = if (self.thread_enter_state) |v|
        try v.prepareInput()
    else
        null;

    data.* = .{
        .alloc = self.alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .mailbox = &self.mailbox,
        .backend = undefined, // Backend must replace this on threadEnter
    };

    // Setup our backend
    try self.backend.threadEnter(self.alloc, self, data);
    errdefer self.backend.threadExit(data);

    // If we have inputs, then queue them all up.
    for (inputs orelse &.{}) |input| switch (input) {
        .string => |v| self.queueWrite(data, v, false) catch |err| {
            log.warn("failed to queue input string err={}", .{err});
            return error.InputFailed;
        },
        .file => |f| self.queueWrite(
            data,
            f.readToEndAlloc(
                self.alloc,
                10 * 1024 * 1024, // 10 MiB max
            ) catch |err| {
                log.warn("failed to read input file err={}", .{err});
                return error.InputFailed;
            },
            false,
        ) catch |err| {
            log.warn("failed to queue input file err={}", .{err});
            return error.InputFailed;
        },
    };
}

pub fn threadExit(self: *Termio, data: *ThreadData) void {
    self.backend.threadExit(data);
}

/// Mark whether backend teardown should CLOSE the remote session (terminate
/// the agent-side child and free the session) instead of the default DETACH
/// (keep-alive for a later re-attach). Set when the user explicitly closes a
/// pane/window; never set on app quit. No-op for the exec backend, whose child
/// dies with the surface anyway. Safe to call from the GUI thread: the write
/// is atomic and strictly precedes the surface free that joins the IO thread.
pub fn setSessionCloseIntent(self: *Termio, close_on_exit: bool) void {
    switch (self.backend) {
        .remote => |*remote| remote.close_on_exit.store(close_on_exit, .release),
        else => {},
    }
}

/// Signal the IO backend to abort any blocking work so the IO thread can be
/// joined promptly. Safe to call from another thread (the GUI thread calls it
/// from `Surface.deinit` right before joining the IO thread). See
/// `termio.Backend.shutdown`.
///
/// Beyond the backend's own cancellation (e.g. Remote's RPC canceller),
/// this poisons every blocking-queue wait the IO thread could be parked
/// in, because after this call nothing will ever drain those queues
/// again: the closing flag unblocks pushes to the shared app/surface
/// mailbox, and closing our own mailbox wakes a producer parked in
/// `Mailbox.send`. Without this, joining the IO thread can deadlock the
/// GUI thread permanently (observed: post-wake remote reconnect swaps).
pub fn shutdown(self: *Termio) void {
    self.closing.store(true, .release);
    self.mailbox.close();
    self.backend.shutdown();
}

/// Send a message to the mailbox. Depending on the mailbox type in use
/// this may process now or it may just enqueue and process later.
///
/// This will also notify the mailbox thread to process the message. If
/// you're sending a lot of messages, it may be more efficient to use
/// the mailbox directly and then call notify separately.
pub fn queueMessage(
    self: *Termio,
    msg: termio.Message,
    mutex: MutexState,
) void {
    // RESIZE bypasses the bounded data mailbox: it is latest-wins control
    // state that MUST survive a full queue (a re-attach replay flood otherwise
    // drops it → stale pty winsize → narrow/blank re-attached panes). Stash the
    // newest geometry in a dedicated slot and wake the writer to apply it; the
    // write DATA in the queue can never crowd it out, and we never block, so the
    // teardown deadlock the mailbox drop guards against can't happen here.
    switch (msg) {
        .resize => |size| {
            self.pending_resize_mutex.lock();
            self.pending_resize = size;
            self.pending_resize_mutex.unlock();
            self.mailbox.notify();
            return;
        },
        else => {},
    }

    self.mailbox.send(msg, switch (mutex) {
        .locked => self.renderer_state.mutex,
        .unlocked => null,
    });
    self.mailbox.notify();
}

/// Atomically take and clear the latest pending resize (see `pending_resize`).
/// Called by the IO thread on each mailbox drain so a coalesced RESIZE is
/// applied even when the bounded data mailbox is saturated. Null = nothing
/// pending.
pub fn takePendingResize(self: *Termio) ?renderer.Size {
    self.pending_resize_mutex.lock();
    defer self.pending_resize_mutex.unlock();
    const v = self.pending_resize;
    self.pending_resize = null;
    return v;
}

/// Queue a write directly to the pty.
///
/// If you're using termio.Thread, this must ONLY be called from the
/// mailbox thread. If you're not on the thread, use queueMessage with
/// mailbox messages instead.
///
/// If you're not using termio.Thread, this is not threadsafe.
pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);
}

/// Update the configuration.
pub fn changeConfig(self: *Termio, td: *ThreadData, config: *DerivedConfig) !void {
    // The remainder of this function is modifying terminal state or
    // the read thread data, all of which requires holding the renderer
    // state lock.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // Deinit our old config. We do this in the lock because the
    // stream handler may be referencing the old config (i.e. enquiry resp)
    self.config.deinit();
    self.config = config.*;

    // Update our stream handler. The stream handler uses the same
    // renderer mutex so this is safe to do despite being executed
    // from another thread.
    self.terminal_stream.handler.changeConfig(&self.config);
    td.backend.changeConfig(&self.config);

    // Update the configuration that we know about.
    //
    // Specific things we don't update:
    //   - command, working-directory: we never restart the underlying
    //   process so we don't care or need to know about these.

    // Update the default palette.
    self.terminal.colors.palette.changeDefault(config.palette);
    self.terminal.flags.dirty.palette = true;

    // Update all our other colors
    self.terminal.colors.background.default = config.background.toTerminalRGB();
    self.terminal.colors.foreground.default = config.foreground.toTerminalRGB();
    self.terminal.colors.cursor.default = cursor: {
        const color = config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };

    // Set the image limits
    try self.terminal.setKittyGraphicsSizeLimit(self.alloc, config.image_storage_limit);
    self.terminal.setKittyGraphicsLoadingLimits(.all);
}

/// Resize the terminal.
pub fn resize(
    self: *Termio,
    td: *ThreadData,
    size: renderer.Size,
) !void {
    self.size = size;
    const grid_size = size.grid();

    // Update the size of our pty (local) or forward a RESIZE to the agent
    // (remote). The remote backend needs `td` to address its pane.
    try self.backend.resize(td, grid_size, size.terminal());

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // T431: a resize can drag SCROLLBACK down into the active area, where
        // a ConPTY child's post-resize repaint erases it — and the drag is a
        // move, so it is gone from history too. Pin the boundary across the
        // resize and push back anything that crossed it.
        const boundary = self.armHistoryGuardLocked();
        defer if (boundary) |p| history_guard.disarm(&self.terminal, p);

        // Update the size of our terminal state
        try self.terminal.resize(
            self.alloc,
            grid_size.columns,
            grid_size.rows,
        );

        if (boundary) |p| history_guard.hold(&self.terminal, p);

        // Update our pixel sizes
        self.terminal.width_px = grid_size.columns * self.size.cell.width;
        self.terminal.height_px = grid_size.rows * self.size.cell.height;

        // Disable synchronized output mode so that we show changes
        // immediately for a resize. This is allowed by the spec.
        self.terminal.modes.set(.synchronized_output, false);

        // T423: the reflow above may have dragged a session-interrupted notice
        // back out of the scrollback and into the active area.
        self.holdNoticeAboveLocked();

        // If we have size reporting enabled we need to send a report.
        if (self.terminal.modes.get(.in_band_size_reports)) {
            try self.sizeReportLocked(td, .mode_2048);
        }
    }

    // Mail the renderer so that it can update the GPU and re-render
    _ = self.renderer_mailbox.push(.{ .resize = size }, .{ .forever = {} });
    self.renderer_wakeup.notify() catch {};
}

/// Reflow ONLY the local terminal grid to `cols`x`rows` — no pty/agent RESIZE and
/// no change to `self.size`. Used to replay reboot-scrollback (§5.4) at the width
/// it was captured at and then reflow to the live pane width: a raw byte stream
/// full of in-place prompt redraws (`\r` + erase-to-end) only lands cleanly at its
/// original width, so we render it there, then reflow. Caller MUST leave the grid
/// back at the live size (== `self.size.grid()`) when done, so a later real resize
/// stays consistent. Same locking as `resize`; notifies the renderer.
pub fn reflowLocalGrid(self: *Termio, cols: u16, rows: u16) void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        const boundary = self.armHistoryGuardLocked();
        defer if (boundary) |p| history_guard.disarm(&self.terminal, p);
        self.terminal.resize(self.alloc, cols, rows) catch |err| {
            log.warn("reflowLocalGrid resize failed err={}", .{err});
            return;
        };
        if (boundary) |p| history_guard.hold(&self.terminal, p);
        self.terminal.modes.set(.synchronized_output, false);
        self.holdNoticeAboveLocked();
    }
    _ = self.renderer_mailbox.push(.{ .resize = self.size }, .{ .forever = {} });
    self.renderer_wakeup.notify() catch {};
}

/// Arm the notice guard. Call immediately after writing the notice.
pub fn armNoticeFold(self: *Termio) void {
    self.notice_fold_armed = true;
}

/// Fold the notice above the viewport and start holding it there. The caller
/// must be about to parse the child's first bytes ON THIS THREAD, with no
/// chance for a resize to interleave. No-op unless a notice is armed.
pub fn settleNotice(self: *Termio) void {
    if (!self.notice_fold_armed) return;
    self.notice_fold_armed = false;
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    session_notice.foldIntoScrollback(&self.terminal);
    self.notice_guard = session_notice.trackFold(&self.terminal);
}

/// Pin the active-area boundary before a resize, for a pane whose CHILD repaints
/// the viewport afterwards. See `history_guard`. Null for every other pane, so
/// both call sites cost one comparison and nothing else.
///
/// The flavour comes from the backend rather than `builtin.os.tag` because a
/// remote pane's child runs on the agent's machine, which need not be this one
/// (T471). Read on the IO thread, which is also the only thread that resizes.
fn armHistoryGuardLocked(self: *Termio) ?*terminalpkg.Pin {
    if (!history_guard.enabledFor(self.backend.childPtyFlavor())) return null;
    return history_guard.arm(&self.terminal);
}

/// Put a settled notice back above the viewport if a reflow dragged it down
/// into the active area. Called with the renderer mutex already held, from
/// every path that resizes the terminal. See `session_notice.holdAbove`.
fn holdNoticeAboveLocked(self: *Termio) void {
    const guard = self.notice_guard orelse return;
    session_notice.holdAbove(&self.terminal, guard);
}

/// Make a size report.
pub fn sizeReport(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    try self.sizeReportLocked(td, style);
}

fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    const grid_size = self.size.grid();
    const report_size: terminalpkg.size_report.Size = .{
        .rows = grid_size.rows,
        .columns = grid_size.columns,
        .cell_width = self.size.cell.width,
        .cell_height = self.size.cell.height,
    };

    // 1024 bytes should be enough for size report since report
    // in columns and pixels.
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.size_report.encode(
        &writer,
        style,
        report_size,
    );

    try self.queueWrite(td, writer.buffered(), false);
}

/// Reset the synchronized output mode. This is usually called by timer
/// expiration from the termio thread.
pub fn resetSynchronizedOutput(self: *Termio) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_wakeup.notify() catch {};
}

/// Clear the screen.
pub fn clearScreen(self: *Termio, td: *ThreadData, history: bool) !void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // If we're on the alternate screen, we do not clear. Since this is an
        // emulator-level screen clear, this messes up the running programs
        // knowledge of where the cursor is and causes rendering issues. So,
        // for alt screen, we do nothing.
        if (self.terminal.screens.active_key == .alternate) return;

        // Clear our selection
        self.terminal.screens.active.clearSelection();

        // Clear our scrollback
        if (history) self.terminal.eraseDisplay(.scrollback, false);

        // If we're not at a prompt, we just delete above the cursor.
        if (!self.terminal.cursorIsAtPrompt()) {
            if (self.terminal.screens.active.cursor.y > 0) {
                self.terminal.screens.active.eraseActive(
                    self.terminal.screens.active.cursor.y - 1,
                );
            }

            // Clear all Kitty graphics state for this screen. This copies
            // Kitty's behavior when Cmd+K deletes all Kitty graphics. I
            // didn't spend time researching whether it only deletes Kitty
            // graphics that are placed above the cursor or if it deletes
            // all of them. We delete all of them for now but if this behavior
            // isn't fully correct we should fix this later.
            self.terminal.screens.active.kitty_images.delete(
                self.terminal.screens.active.alloc,
                &self.terminal,
                .{ .all = true },
            );

            return;
        }

        // At a prompt, we want to first fully clear the screen, and then after
        // send a FF (0x0C) to the shell so that it can repaint the screen.
        // Mark the current row as a not a prompt so we can properly
        // clear the full screen in the next eraseDisplay call.
        // TODO: fix this
        // self.terminal.markSemanticPrompt(.command);
        // assert(!self.terminal.cursorIsAtPrompt());
        self.terminal.eraseDisplay(.complete, false);
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    try self.queueWrite(td, &[_]u8{0x0C}, false);
}

/// Scroll the viewport
pub fn scrollViewport(
    self: *Termio,
    scroll: terminalpkg.Terminal.ScrollViewport,
) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.terminal.scrollViewport(scroll);
}

/// Jump the viewport to the prompt.
pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        self.terminal.screens.active.scroll(.{ .delta_prompt = delta });
    }

    try self.renderer_wakeup.notify();
}

/// Called when focus is gained or lost (when focus events are enabled)
pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {
    self.renderer_state.mutex.lock();
    const focus_event = self.renderer_state.terminal.modes.get(.focus_event);
    self.renderer_state.mutex.unlock();

    // If we have focus events enabled, we send the focus event.
    if (focus_event) {
        var buf: [terminalpkg.focus.max_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        terminalpkg.focus.encode(&writer, if (focused) .gained else .lost) catch |err| {
            log.err("error encoding focus event err={}", .{err});
            return;
        };
        try self.queueWrite(td, writer.buffered(), false);
    }

    // We always notify our backend of focus changes.
    try self.backend.focusGained(td, focused);
}

/// Process output from the pty. This is the manual API that users can
/// call with pty data but it is also called by the read thread when using
/// an exec subprocess.
pub fn processOutput(self: *Termio, buf: []const u8) void {
    // We are modifying terminal state from here on out and we need
    // the lock to grab our read data.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.processOutputLocked(buf);
}

/// Like `processOutput` but also advances `applied` by `buf.len` while still
/// holding the renderer mutex. Used by the remote drain path (WP-D3) so a
/// concurrent snapshot reader — which holds the SAME mutex to serialize the
/// grid — always observes the applied byte count and the grid it produced as
/// one consistent pair. Without this the offset could be read a chunk ahead of
/// or behind the grid, seaming the snapshot against the agent's delta replay.
pub fn processOutputTracked(
    self: *Termio,
    buf: []const u8,
    applied: *std.atomic.Value(u64),
) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.processOutputLocked(buf);
    _ = applied.fetchAdd(buf.len, .monotonic);
}

/// The two halves of one `processOutputTracked` call (T1460), in nanoseconds:
/// `lock_ns` is time spent WAITING for the renderer mutex, `work_ns` is time
/// spent parsing with it held. A caller accumulates across many calls and
/// reports both, because either one alone is unreadable — the sum is what a
/// bracket around the whole call already measures, and the question is always
/// which half it is.
pub const TrackedTiming = struct {
    lock_ns: u64 = 0,
    work_ns: u64 = 0,
};

/// Like `processOutputTracked`, but attributes the call to lock wait vs work
/// under the lock (T1460).
///
/// This exists as a TWIN rather than an optional out-parameter on
/// `processOutputTracked` because that function is the hottest thing on the
/// remote drain path, and a measurement that perturbs what it measures is
/// worse than none: three prior tasks (T111b, T114, T115) are about starvation
/// on exactly this mutex. Callers select the twin only when their telemetry is
/// on, so the ordinary path keeps the original's instruction stream, lock
/// order and hold duration untouched.
///
/// A clock that will not read is not an error worth failing a drain over — the
/// timings simply do not advance for that call, which shows up as a slightly
/// low total rather than a lost byte.
pub fn processOutputTrackedTimed(
    self: *Termio,
    buf: []const u8,
    applied: *std.atomic.Value(u64),
    timing: *TrackedTiming,
) void {
    const t_enter: ?std.time.Instant = std.time.Instant.now() catch null;
    self.renderer_state.mutex.lock();
    const t_locked: ?std.time.Instant = std.time.Instant.now() catch null;
    {
        defer self.renderer_state.mutex.unlock();
        self.processOutputLocked(buf);
        _ = applied.fetchAdd(buf.len, .monotonic);
    }
    const t_done: ?std.time.Instant = std.time.Instant.now() catch null;

    const enter = t_enter orelse return;
    const locked = t_locked orelse return;
    timing.lock_ns += locked.since(enter);
    const done = t_done orelse return;
    timing.work_ns += done.since(locked);
}

/// The absolute agent-stream byte offset this pane has applied to its terminal
/// so far (WP-D3), or null for a non-remote backend. Read under the renderer
/// mutex alongside a grid dump to persist a consistent (screen, offset) pair
/// for a fast delta re-attach. See `Remote.appliedOffset`.
pub fn remoteAppliedOffset(self: *const Termio) ?u64 {
    return switch (self.backend) {
        .remote => |*r| r.appliedOffset(),
        else => null,
    };
}

/// Process output from readdata but the lock is already held.
fn processOutputLocked(self: *Termio, buf: []const u8) void {
    // Schedule a render. We can call this first because we have the lock.
    self.terminal_stream.handler.queueRender() catch unreachable;

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    if (std.time.Instant.now()) |now| cursor_reset: {
        if (self.last_cursor_reset) |last| {
            if (now.since(last) <= (500 * std.time.ns_per_ms)) {
                break :cursor_reset;
            }
        }

        self.last_cursor_reset = now;
        _ = self.renderer_mailbox.push(.{
            .reset_cursor_blink = {},
        }, .{ .instant = {} });
    } else |err| {
        log.warn("failed to get current time err={}", .{err});
    }

    // If we have an inspector, we enter SLOW MODE because we need to
    // process a byte at a time alternating between the inspector handler
    // and the termio handler. This is very slow compared to our optimizations
    // below but at least users only pay for it if they're using the inspector.
    if (self.renderer_state.inspector) |insp| {
        for (buf, 0..) |byte, i| {
            insp.recordPtyRead(
                self.alloc,
                &self.terminal,
                buf[i .. i + 1],
            ) catch |err| {
                log.err("error recording pty read in inspector err={}", .{err});
            };

            self.terminal_stream.next(byte);
        }
    } else {
        self.terminal_stream.nextSlice(buf);
    }

    // If our stream handling caused messages to be sent to the mailbox
    // thread, then we need to wake it up so that it processes them.
    if (self.terminal_stream.handler.termio_messaged) {
        self.terminal_stream.handler.termio_messaged = false;
        self.mailbox.notify();
    }
}

/// Sends a DSR response for the current color scheme to the pty.
pub fn colorSchemeReport(self: *Termio, td: *ThreadData, force: bool) !void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    try self.colorSchemeReportLocked(td, force);
}

pub fn colorSchemeReportLocked(self: *Termio, td: *ThreadData, force: bool) !void {
    if (!force and !self.renderer_state.terminal.modes.get(.report_color_scheme)) {
        return;
    }
    const output = switch (self.config.conditional_state.theme) {
        .light => "\x1B[?997;2n",
        .dark => "\x1B[?997;1n",
    };
    try self.queueWrite(td, output, false);
}

/// ThreadData is the data created and stored in the termio thread
/// when the thread is started and destroyed when the thread is
/// stopped.
///
/// All of the fields in this struct should only be read/written by
/// the termio thread. As such, a lock is not necessary.
pub const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The event loop associated with this thread. This is owned by
    /// the Thread but we have a pointer so we can queue new work to it.
    loop: *xev.Loop,

    /// The shared render state
    renderer_state: *renderer.State,

    /// Mailboxes for different threads
    surface_mailbox: apprt.surface.Mailbox,

    /// Data associated with the backend implementation (i.e. pty/exec state)
    backend: termio.backend.ThreadData,
    mailbox: *termio.Mailbox,

    pub fn deinit(self: *ThreadData) void {
        self.backend.deinit(self.alloc);
        self.* = undefined;
    }
};

/// Get information about the process(es) attached to the backend. Returns
/// `null` if there was an error getting the information or the information is
/// not available on a particular platform.
pub fn getProcessInfo(self: *Termio, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.backend.getProcessInfo(info);
}
