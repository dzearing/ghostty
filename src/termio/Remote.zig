//! Remote implements the `termio` backend for a pane whose child process lives
//! on a remote machine, reached over a `RemoteConnection` (`src/remote/`). It is
//! the remote counterpart to `Exec` (the local subprocess+pty backend) and
//! exposes the EXACT same method set `termio/backend.zig` dispatches to, but does
//! NOT own a pty or a subprocess. Instead:
//!
//!   - A shared `connection.Connection` (one per conn-key, supplied by the caller —
//!     the C-API/Surface wiring lands in increment 4b) owns the two SSH channels,
//!     the MPSC writer, and the demux reader.
//!   - This backend OPENs a new session (or ATTACHes an existing one by
//!     `session_id`) on the connection to obtain a `*connection.Pane`. The pane
//!     carries a per-channel inbound ring (`inbound_ring.Channel`, §3.4).
//!   - There is NO per-pane read thread: the connection's single demux thread reads
//!     the data channel and `pushTo`s each frame's bytes into the target pane's
//!     ring, then wakes the pane's IO thread via a `Waker`. This backend backs that
//!     `Waker` with an `xev.Async` registered on the pane's OWN IO thread/loop
//!     (`Thread.zig` / `Termio.ThreadData.loop`); the async callback drains the
//!     ring and calls `Termio.processOutput` ON THIS PANE'S THREAD — the same call
//!     Exec's `ReadThread` makes — restoring per-pane parallelism with no cross-pane
//!     head-of-line blocking.
//!   - Input (`queueWrite`) is MPSC-enqueued as `DATA` via `connection.writeInput`
//!     (the pane owns its outbound byte offset). `resize` sends a `RESIZE` control
//!     frame. Teardown `DETACH`es (keep-alive) by default, NOT `CLOSE`.
//!
//! See design §3.1 (the union seam), §3.3 (the per-method behavior map this
//! mirrors), and §3.4 (thread topology, the inbound-ring mini-spec, and the
//! use-after-free teardown invariant).
//!
//! INCREMENT 4a SCOPE: this makes libghostty COMPILE with a structurally faithful
//! `.remote` arm wired to the already-built connection. The deepest `xev.Async`
//! drain wiring is implemented; a few agent-metadata refinements are marked
//! `// TODO(wp3)` where the protocol surface for them lands in a later increment.
const Remote = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const connection = @import("../remote/connection.zig");
const inbound_ring = @import("../remote/inbound_ring.zig");
const protocol = @import("../remote/protocol.zig");

const log = std.log.scoped(.io_remote);

/// The connection this pane rides on. Owned by the caller (the C-API/Surface
/// layer, increment 4b); shared across panes that target the same conn-key.
/// Never freed by this backend.
conn: *connection.Connection,

/// The agent session to ATTACH to, or null to OPEN a brand-new session. Duped
/// into `arena` so it is stable for this backend's lifetime.
session_id: ?[]const u8,

/// The command to run for an open-new session (null ⇒ the remote default shell).
/// Sent verbatim in the `OPEN` payload (§4.2). Duped into `arena`.
command: ?[]const u8,

/// The working directory hint for an open-new session and the terminal's initial
/// pwd. Duped into `arena`.
working_directory: ?[]const u8,

/// The shell to run for an open-new session (null ⇒ the remote's own default:
/// POSIX `$SHELL`/`/bin/sh`, Windows `%COMSPEC%`/cmd.exe). A path ON THE REMOTE
/// MACHINE, sourced from the per-host settings (never the local config). Sent
/// verbatim in the `OPEN` payload (§4.2). Duped into `arena`.
shell: ?[]const u8,

/// The TERM value advertised in `OPEN` (§4.2). Duped into `arena`.
term: []const u8,

/// Environment variables sent as the `OPEN.env` allowlist (§4.2) for an
/// open-new session. For the LOCAL agent these forward the surface's env
/// overrides (GHOZTTY_WINDOW_NAME/GHOZTTY_PANE_NAME set by the apprt + IPC,
/// plus any user `env` config) so an agent-backed pane reaches env parity with
/// an exec pane (T04a). Empty for a cross-machine remote window (env is
/// agent-side there). Each pair's key/value is duped into `arena`.
env: []const protocol.Open.EnvPair,

/// Explicit shell argv to exec verbatim (§ local shell integration, T04c), or
/// null to let the agent synthesize `<shell> -lic/-li`. Carries the
/// `shell_integration.setup()` argv-rewrite for bash/nushell so those shells
/// activate ghostty integration on the LOCAL agent. Null for cross-machine
/// windows and for env-only shells. Each element is duped into `arena`.
argv: ?[]const []const u8,

/// Pin this session against the agent's idle-TTL reaper (§7.1, T11). True only
/// for a persistent LOCAL-agent pane; sent in `OPEN.pinned`. Ignored on ATTACH.
pinned: bool,

/// True when the connection is the LOCAL agent (see `Config.local`). Gates
/// publishing the agent-reported tty for `getProcessInfo(.tty_name)` (wp3).
local: bool,

/// What to do when an ATTACH finds the session a DEAD-but-relaunchable tombstone
/// (the agent itself restarted and materialized it from disk, §5.4 reboot floor,
/// T12c). `.auto` respawns it in place (`RELAUNCH`) and shows a restarted
/// divider; `.prompt` leaves the pane in its exited state for the user to decide.
/// Only meaningful for the LOCAL-agent ATTACH path; irrelevant on OPEN-new.
relaunch_policy: RelaunchPolicy,

/// Current grid/screen size, seeded by `initTerminal` and updated by `resize`.
/// Sent in `OPEN`/`RESIZE` (rows/cols + pixel geometry, §6.5).
grid_size: renderer.GridSize = .{},
screen_size: renderer.ScreenSize = .{ .width = 1, .height = 1 },

/// Cached exit code from an `EXIT` frame, surfaced by `childExitedAbnormally`.
/// Null until the agent reports the session exited.
exit_code: ?u32 = null,

/// True while a `.prompt`-policy pane is a dead-but-relaunchable tombstone waiting
/// for the user to consent to a respawn (T12c2). Set by `threadEnter` when it brings
/// up a live-but-childless pane (via `prepareRelaunchPane`) and shows an
/// "awaiting relaunch" prompt; the first keystroke in `queueWrite` clears it and
/// fires the deferred `RELAUNCH`. Touched only on the IO thread (threadEnter →
/// queueWrite), so no synchronization is needed.
awaiting_relaunch: bool = false,

/// When true, `threadExit` sends `CLOSE` (terminate the remote child + free the
/// session) instead of the default `DETACH` (keep-alive for re-attach). Set via
/// `Surface.setSessionCloseIntent` when the USER closes the pane/window — an
/// app quit never sets it, so quit keeps sessions alive for restore while an
/// explicit close actually ends the process (no orphaned pinned sessions
/// accumulating in the agent). Atomic: written on the GUI thread (before the
/// surface free joins the IO thread), read on the IO thread in `threadExit`.
close_on_exit: std.atomic.Value(bool) = .init(false),

/// Owns the duped config strings for this backend's lifetime.
arena: std.heap.ArenaAllocator,

/// Cancellation token for this pane's session-establishing RPCs (OPEN/ATTACH).
/// `shutdown` (GUI thread, called by `Surface.deinit` BEFORE joining the IO
/// thread) cancels it so a doomed OPEN/ATTACH parked on a dead link wakes
/// immediately instead of waiting out its full timeout under the join — the
/// remote analogue of Exec signaling its quit pipe before joining its reader.
/// Stable for the backend's lifetime (lives in `Termio.backend`, which is
/// deinitialized only after the IO thread has joined).
canceller: connection.RpcCanceller = .{},

/// The LIVE agent session id, published once `threadEnter` resolves the pane
/// (OPEN-new learns it from the agent's OPENED; ATTACH already knows it). Stored
/// here on the STABLE backend (`Termio.backend.remote`) so the GUI thread can
/// read it cross-thread for an on-demand cwd query (§WP4). It points into the IO
/// thread's `pane.session_id` (stable for the pane's lifetime). Published/cleared
/// with release/acquire ordering; readers must treat the slice as borrowed and
/// only valid while the pane is alive (the GUI reads it synchronously to issue a
/// query right after, well before any teardown).
live_session_id: std.atomic.Value(?[*]const u8) = .init(null),
live_session_id_len: std.atomic.Value(usize) = .init(0),

/// Agent-reported process info for `getProcessInfo` (wp3): the child pid and
/// PTY slave path from `OPENED`/`ATTACHED`/`RELAUNCHED`, published by the IO
/// thread (`threadEnter` / relaunch) and read lock-free from the GUI thread
/// (`ghostty_surface_foreground_pid` / `ghostty_surface_tty_name`, which power
/// the IPC `+list` pid/tty fields). The tty is a single NUL-terminated pointer
/// (its length is derived at read time, so there is no two-atomic tear), duped
/// into `arena` (never freed until backend deinit) so a published pointer stays
/// valid even when a relaunch publishes a replacement. 0/null until the agent
/// reports them (older agent ⇒ never: `getProcessInfo` then returns null, the
/// pre-wp3 behavior).
child_pid: std.atomic.Value(i64) = .init(0),
tty_name_ptr: std.atomic.Value(?[*:0]const u8) = .init(null),

/// The LIVE foreground pid pushed by the agent (`META{foreground_pid}`, wp3):
/// the agent samples `tcgetpgrp` on its pty every second and pushes changes;
/// the control reader signals the pane's ring and the IO thread copies the
/// value here (see `drainRing`) for lock-free GUI reads. 0 = never reported
/// (older agent / Windows ConPTY) — `getProcessInfo` then falls back to
/// `child_pid`, which is also the correct answer for a fresh shell.
fg_pid: std.atomic.Value(i64) = .init(0),

/// Configuration for a remote backend. Mirrors the subset of `Exec.Config` that
/// makes sense for a remote pane: there is no env/shell-integration/resources-dir
/// machinery here (that all lives on the agent side), but the connection handle
/// and the open-vs-attach decision are remote-specific.
///
/// The `conn` handle is supplied by the caller; increment 4b wires the C API /
/// `Surface` construction that actually resolves a connection for a conn-key and
/// populates this. For now nothing constructs a `.remote` Config — the milestone
/// is a complete, compiling union arm.
pub const Config = struct {
    /// The shared connection to ride on (caller-owned). Required.
    conn: *connection.Connection,

    /// Non-null ⇒ ATTACH to this existing agent session; null ⇒ OPEN a new one.
    session_id: ?[]const u8 = null,

    /// Command for an open-new session (null ⇒ remote default shell). Wire `OPEN`.
    command: ?[]const u8 = null,

    /// Working directory hint + the terminal's initial pwd.
    working_directory: ?[]const u8 = null,

    /// Shell for an open-new session (null ⇒ the agent resolves its own
    /// default). A remote-native path (per-host setting), NEVER the local
    /// shell — a local path does not exist on a different remote OS.
    shell: ?[]const u8 = null,

    /// TERM value advertised to the agent. Deliberately NOT `xterm-ghostty`:
    /// the remote machine almost never has ghostty's terminfo installed, and an
    /// unknown TERM breaks curses apps and pagers there (git's less prints
    /// "terminal is not fully functional" on Windows). `xterm-256color` is
    /// understood everywhere and matches our VT emulation closely.
    term: []const u8 = "xterm-256color",

    /// Environment variables for an open-new session (the `OPEN.env` allowlist).
    /// Empty for cross-machine remote windows (env lives agent-side there);
    /// populated for the LOCAL agent to forward GHOZTTY_*/IPC/user vars (T04a).
    /// Borrowed from the caller; `init` dupes each pair into the backend arena.
    env: []const protocol.Open.EnvPair = &.{},

    /// Explicit shell argv to exec verbatim instead of the agent's synthesized
    /// `<shell> -lic/-li` (§ local shell integration, T04c). Set ONLY by the
    /// LOCAL-agent client for a plain interactive bash/nushell pane (the
    /// argv-rewrite `shell_integration.setup()` returns); null everywhere else
    /// (env-only shells, user-command panes, cross-machine windows). Borrowed
    /// from the caller; `init` dupes each element into the backend arena.
    argv: ?[]const []const u8 = null,

    /// Pin this session against the agent's idle-TTL reaper (§7.1, T11). Set true
    /// ONLY by the LOCAL-agent client for a persistent local pane the viewer's
    /// session-layout manifest (T05) references, so it survives the viewer
    /// quitting until a restore re-ATTACHes. False for cross-machine windows
    /// (they keep the idle-TTL). Sent in `OPEN.pinned`; irrelevant on ATTACH
    /// (the session was pinned at its original OPEN).
    pinned: bool = false,

    /// Relaunch policy for a dead-but-relaunchable ATTACH target (T12c). See the
    /// `relaunch_policy` field doc. Defaults to `.auto`.
    relaunch_policy: RelaunchPolicy = .auto,

    /// True when `conn` dials the LOCAL agent (same machine, UDS) — the
    /// session-persistence path. Gates surfacing the agent-reported tty from
    /// `getProcessInfo(.tty_name)` (wp3): a cross-machine agent's tty names a
    /// REMOTE device, and exposing it locally could false-match `+list --tty`
    /// against an unrelated local tty. Set from the same
    /// `local_shell_integration` signal as `pinned`.
    local: bool = false,
};

/// What a restored pane does when its ATTACH target comes back as a
/// dead-but-relaunchable tombstone across an agent restart (§5.4, T12c). Mirrors
/// `config.SessionRelaunch`; kept local so this backend need not import config.
pub const RelaunchPolicy = enum { auto, prompt };

/// A single `OPEN.env` key/value pair. Re-exported so surface-construction code
/// (`Surface.zig`) can build the forwarded env list without importing the wire
/// protocol module directly.
pub const EnvPair = protocol.Open.EnvPair;

/// Initialize the remote backend state. Like `Exec.init`, this does NOT touch the
/// wire — it only records what `threadEnter` will need. It does NOT open/attach a
/// channel (that happens on the IO thread in `threadEnter`).
pub fn init(alloc: Allocator, cfg: Config) !Remote {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const session_id = if (cfg.session_id) |s| try aa.dupe(u8, s) else null;
    const command = if (cfg.command) |c| try aa.dupe(u8, c) else null;
    const working_directory = if (cfg.working_directory) |w| try aa.dupe(u8, w) else null;
    const shell = if (cfg.shell) |s| try aa.dupe(u8, s) else null;
    const term = try aa.dupe(u8, cfg.term);

    // Dupe the forwarded env allowlist (keys and values) into our arena so it
    // is stable for the backend's lifetime (the caller only lends it).
    const env = try aa.alloc(protocol.Open.EnvPair, cfg.env.len);
    for (cfg.env, 0..) |pair, i| env[i] = .{
        .key = try aa.dupe(u8, pair.key),
        .value = try aa.dupe(u8, pair.value),
    };

    // Dupe the explicit shell argv (if any) into our arena, element by element,
    // so it is stable for the backend's lifetime (the caller only lends it).
    const argv: ?[]const []const u8 = if (cfg.argv) |src| argv: {
        const dst = try aa.alloc([]const u8, src.len);
        for (src, 0..) |a, i| dst[i] = try aa.dupe(u8, a);
        break :argv dst;
    } else null;

    return .{
        .conn = cfg.conn,
        .session_id = session_id,
        .command = command,
        .working_directory = working_directory,
        .shell = shell,
        .term = term,
        .env = env,
        .argv = argv,
        .pinned = cfg.pinned,
        .local = cfg.local,
        .relaunch_policy = cfg.relaunch_policy,
        .arena = arena,
    };
}

pub fn deinit(self: *Remote) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Abort any blocking work this backend may be doing on its IO thread so that
/// thread can be joined promptly. Called by `Surface.deinit` on the GUI thread
/// BEFORE it joins the IO thread (mirroring how Exec signals its read thread's
/// quit pipe before the join).
///
/// The one blocking wait a remote pane's IO thread can be parked in is a
/// session-establishing RPC (`threadEnter`'s OPEN/ATTACH). On a link that died
/// silently (e.g. a WSS transport that will never deliver another byte — the
/// readers see no error, so nothing fails the parked slot) that wait runs the
/// full RPC timeout; joining through it beachballs the GUI thread, and during
/// reconnect churn (a fresh doomed ATTACH every cycle) it looks permanent.
/// Cancelling is always safe: the surface is being torn down, so the RPC's
/// result could never be used anyway.
///
/// Thread-safe: only touches the atomic canceller and the connection's
/// rpc-slot table (under its own lock). The connection outlives the surface
/// (the GUI retains it until after `ghostty_surface_free` returns).
pub fn shutdown(self: *Remote) void {
    self.canceller.cancel();
    self.conn.cancelRpcsFor(&self.canceller);
}

/// The LIVE agent session id for this backend, or null if no pane is currently
/// resolved (pre-`threadEnter` or post-`threadExit`). Lock-free; safe to call
/// from any thread. The returned slice borrows the pane's `session_id` and is
/// only valid while the pane is alive — callers use it synchronously (e.g. to
/// issue a cwd query) and must not retain it. (§WP4)
pub fn liveSessionId(self: *const Remote) ?[]const u8 {
    const ptr = self.live_session_id.load(.acquire) orelse return null;
    const len = self.live_session_id_len.load(.acquire);
    if (len == 0) return null;
    return ptr[0..len];
}

/// The command this remote pane was OPENed with, or null if it uses the agent's
/// default shell. Immutable after `init` (duped into `arena` and never mutated),
/// so it is safe to read from any thread. The returned slice borrows the
/// backend's arena and is only valid while the backend is alive — callers use it
/// synchronously (e.g. to seed a new window's command) and must not retain it.
/// Used so a new window/tab/split inherits the parent remote frame's command
/// (§WP4): if the parent ran an explicit command we re-run it; if it used the
/// default shell (null) the new frame also uses the default shell.
pub fn remoteCommand(self: *const Remote) ?[]const u8 {
    const cmd = self.command orelse return null;
    if (cmd.len == 0) return null;
    return cmd;
}

/// Initialize the terminal state for this backend (mirrors `Exec.initTerminal`):
/// set the initial pwd if we have a working-directory hint and seed the grid /
/// screen size from the terminal. The pwd is otherwise resolved lazily from the
/// remote child's OSC 7 (§3.3).
pub fn initTerminal(self: *Remote, t: *terminal.Terminal) void {
    if (self.working_directory) |cwd| t.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };

    // Seed our grid/screen size from the terminal. This can't fail because we
    // haven't opened a channel yet (null `td`), so `resize` only records the
    // sizes; `threadEnter` sends them in `OPEN`.
    self.resize(null, .{
        .columns = t.cols,
        .rows = t.rows,
    }, .{
        .width = t.width_px,
        .height = t.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Remote,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // Set true when the pane below came back via RELAUNCH (a dead-but-relaunchable
    // session respawned across an agent restart) rather than a live attach/open —
    // used after bring-up to print a "session restarted" divider (T12c).
    var did_relaunch = false;
    // Set true when the agent ALREADY replayed pre-restart scrollback + the restart
    // divider from a ring disk snapshot (§5.4, T13) — the client then suppresses its
    // own snapshot-less divider so there is exactly one marker.
    var relaunch_replayed = false;
    // The width/height the replayed scrollback was drawn at (0 = unknown). Used to
    // replay at that width and reflow to the live pane so in-place prompt redraws
    // don't smear (§5.4). Only meaningful with `relaunch_replayed`.
    var replay_cols: u16 = 0;
    var replay_rows: u16 = 0;

    // Open a new session or attach to an existing one to obtain our pane.
    const pane: *connection.Pane = if (self.session_id) |sid| pane: {
        // ATTACH: re-attach to an existing agent session (§3.3 / §7.3).
        const rows: u16 = @intCast(@min(self.grid_size.rows, std.math.maxInt(u16)));
        const cols: u16 = @intCast(@min(self.grid_size.columns, std.math.maxInt(u16)));
        var outcome = try self.conn.attachChannelCancellable(
            sid,
            rows,
            cols,
            // We have no locally-applied byte offset yet (fresh attach from a new
            // GUI process); the agent replays its retained ring from 0 (§7.3).
            0,
            false,
            &self.canceller,
        );
        // `attached_elsewhere` without force (§5.3): the session's bridge still
        // belongs to another connection — for THIS surface that is our own
        // superseded/zombie connection (the WP-D1 reconnect swap re-attaches
        // the same window; WP-D2 restore re-attaches the same user's session
        // after a relaunch), so reclaim it with force=true (the agent evicts
        // the stale bridge and DETACHes the loser). Without the retry the
        // swapped-in surface came up dead (no pane) while the UI said healthy.
        if (outcome.pane == null and
            outcome.status == .alive and
            outcome.attached_elsewhere)
        {
            outcome.deinit();
            log.info("attach: session attached elsewhere; reclaiming with force=true", .{});
            outcome = try self.conn.attachChannelCancellable(sid, rows, cols, 0, true, &self.canceller);
        }
        defer outcome.deinit();
        if (outcome.pane) |p| break :pane p;

        // No live pane. A DEAD-but-relaunchable tombstone means the AGENT itself
        // restarted (a reboot or an agent upgrade) and materialized this session
        // from its on-disk metadata (§5.4 reboot floor, T12b) — the recorded
        // argv/cwd can bring the process back. With the `auto` policy (the
        // default), RELAUNCH it in place on the SAME channel the dead ATTACHED
        // arrived on and stream fresh output; `prompt` falls through to the
        // exited overlay so the user decides.
        if (outcome.status == .dead and outcome.relaunchable and
            self.relaunch_policy == .auto)
        {
            const px_w: u16 = @intCast(@min(self.screen_size.width, std.math.maxInt(u16)));
            const px_h: u16 = @intCast(@min(self.screen_size.height, std.math.maxInt(u16)));
            const r = self.conn.relaunchChannelCancellable(
                sid,
                outcome.channel,
                rows,
                cols,
                px_w,
                px_h,
                // Respawn fidelity (wp3): the agent's on-disk record has no
                // env/TERM/argv, so send our live copies — the respawned shell
                // keeps GHOZTTY_PANE_ID & co. and its shell integration.
                .{ .env = self.env, .term = self.term, .argv = self.argv },
                &self.canceller,
            ) catch |err| {
                log.warn("relaunch of dead session failed err={}", .{err});
                return error.RemoteAttachFailed;
            };
            if (r.pane) |p| {
                log.info(
                    "relaunched dead session pid={} ok={} found={} replayed={}",
                    .{ r.pid, r.ok, r.found, r.replayed },
                );
                did_relaunch = true;
                relaunch_replayed = r.replayed;
                replay_cols = r.replay_cols;
                replay_rows = r.replay_rows;
                break :pane p;
            }
            log.warn(
                "relaunch did not yield a live pane ok={} found={}",
                .{ r.ok, r.found },
            );
            return error.RemoteAttachFailed;
        }

        // Same dead-but-relaunchable tombstone under the `prompt` policy (T12c2):
        // do NOT respawn the process yet — the user must consent. Bring up a
        // live-but-childless pane on the session's channel (ring pre-registered so
        // the eventual respawn's first DATA is not dropped) and mark it awaiting;
        // `threadEnter` prints a prompt below and `queueWrite` fires the deferred
        // `RELAUNCH` on the first keystroke.
        if (outcome.status == .dead and outcome.relaunchable and
            self.relaunch_policy == .prompt)
        {
            const p = self.conn.prepareRelaunchPane(sid, outcome.channel) catch |err| {
                log.warn("prepare relaunch pane failed err={}", .{err});
                return error.RemoteAttachFailed;
            };
            self.awaiting_relaunch = true;
            log.info("dead relaunchable session under prompt policy; awaiting user keystroke to relaunch", .{});
            break :pane p;
        }

        // .dead(!relaunchable) / .not_found / attached_elsewhere(!force): nothing
        // registered. The caller (4b) decides
        // recovery tier (§7.4); for now this is fatal to the pane bring-up.
        // (`defer outcome.deinit()` frees it once.)
        log.warn(
            "attach did not yield a live pane status={} relaunchable={} attached_elsewhere={}",
            .{ outcome.status, outcome.relaunchable, outcome.attached_elsewhere },
        );
        return error.RemoteAttachFailed;
    } else pane: {
        // OPEN-new: start a brand-new remote session (§3.3 open-new).
        const open: protocol.Open = .{
            .command = self.command,
            .cwd = self.working_directory,
            .shell = self.shell,
            .term = self.term,
            .env = self.env,
            .argv = self.argv,
            .pinned = self.pinned,
            .rows = @intCast(@min(self.grid_size.rows, std.math.maxInt(u16))),
            .cols = @intCast(@min(self.grid_size.columns, std.math.maxInt(u16))),
            .px_w = @intCast(@min(self.screen_size.width, std.math.maxInt(u16))),
            .px_h = @intCast(@min(self.screen_size.height, std.math.maxInt(u16))),
        };
        break :pane try self.conn.openChannelCancellable(open, &self.canceller);
    };
    // On any failure after this point we DETACH the pane (keep-alive teardown,
    // §3.3) so the remote session survives for a later re-attach.
    errdefer self.conn.detachChannel(pane);

    // Re-assert the winsize now that the pane is live. ATTACH carries only
    // rows/cols (the agent zeroes the pixel geometry), and a forced-reclaim
    // retry above re-applies the same possibly-stale seed — so send one
    // authoritative RESIZE with the full current geometry. Harmless when it
    // matches what ATTACH/OPEN already applied; it guarantees the agent PTY
    // and the client grid agree at bring-up (WP-D2 restore: "big window,
    // small content").
    self.conn.sendResize(
        pane,
        @intCast(@min(self.grid_size.rows, std.math.maxInt(u16))),
        @intCast(@min(self.grid_size.columns, std.math.maxInt(u16))),
        @intCast(@min(self.screen_size.width, std.math.maxInt(u16))),
        @intCast(@min(self.screen_size.height, std.math.maxInt(u16))),
    ) catch |err| log.warn("post-attach RESIZE re-assert failed err={}", .{err});

    // Publish the resolved live session id on the STABLE backend so the GUI thread
    // can read it for an on-demand cwd query (§WP4). `pane.session_id` is stable
    // for the pane's lifetime; we publish the pointer + len with release ordering
    // (the len last so a reader that sees a non-null ptr also sees the right len).
    const sid = pane.session_id;
    if (sid.len > 0) {
        self.live_session_id.store(sid.ptr, .release);
        self.live_session_id_len.store(sid.len, .release);
    }

    // Publish the agent-reported pid/tty for `getProcessInfo` (wp3). All three
    // bring-up paths land here: OPEN-new (OPENED), re-attach (ATTACHED), and
    // auto-relaunch (RELAUNCHED) — each filled `pane.pid`/`pane.tty`.
    self.publishProcessInfo(pane);

    // The async handle the demux thread notifies to wake THIS pane's IO thread.
    // It is registered on this thread's xev loop; its callback drains the ring.
    var ring_async = try xev.Async.init();
    errdefer ring_async.deinit();

    // Publish our thread-data backend state FIRST so the waker/callback ctx point
    // at the final, stable location (inside `td.backend.remote`).
    td.backend = .{ .remote = .{
        .conn = self.conn,
        .pane = pane,
        .io = io,
        .ring_async = ring_async,
    } };
    const rd = &td.backend.remote;

    // Point the pane's inbound ring at our async so the demux thread's
    // `Channel.push` wakes this thread. The pane (and its ring) were created with
    // a no-op waker by `openChannel`/`attachChannel`; we swap in ours now, before
    // any drain happens. Safe because the demux thread only ever reads the waker
    // under the channel-table lock during a push, and we have not yet begun
    // draining.
    pane.ring.waker = .{ .ctx = rd, .wakeFn = wakeFromDemux };

    // Arm the async wait: every notify drains the ring on this thread.
    rd.ring_async.wait(
        td.loop,
        &rd.ring_async_c,
        termio.Termio.ThreadData,
        td,
        ringReady,
    );

    // A relaunched session (T12c) streams a FRESH shell. When the agent had a ring
    // disk snapshot (T13) it already replayed pre-restart scrollback + the divider
    // ahead of the fresh output (`relaunch_replayed`), so we print nothing — doing
    // so would double the divider AND land it BEFORE the replayed scrollback (our
    // inject is synchronous; the replay drains async from the channel ring). Only
    // when there was NO snapshot (blank relaunch) do we print the divider ourselves,
    // so the restart is visible rather than looking like a spontaneous new prompt.
    if (did_relaunch and !relaunch_replayed) {
        const divider = "\r\n\x1b[2m--- session restarted ---\x1b[0m\r\n";
        @call(.always_inline, termio.Termio.processOutput, .{ io, divider });
    } else if (self.awaiting_relaunch) {
        // Prompt policy (T12c2): the pane is a dead tombstone with no child. Show
        // an interactive affordance — `queueWrite` respawns it on the first key.
        const prompt =
            "\r\n\x1b[1m[ Session ended ]\x1b[0m \x1b[2m— press any key to relaunch\x1b[0m\r\n";
        @call(.always_inline, termio.Termio.processOutput, .{ io, prompt });
    }

    // §5.4 smear fix: replay the reboot-scrollback at the width it was CAPTURED
    // at, then reflow to the live pane. The raw byte stream is full of in-place
    // prompt redraws (`\r` + erase-to-end) that only land cleanly at their
    // original width; drained straight into a narrower grid, each redraw wraps and
    // the erase can't reclaim the row it already pushed to scrollback, so the
    // prompts stack (the visible "spam"). Rendered at the capture width every
    // redraw self-erases to one prompt; the trailing reflow re-wraps that single
    // logical line to the live width. Guarded to the relaunch-replayed case with a
    // known capture width that actually differs from the live grid (0 = an older
    // agent or a legacy GRS1 snapshot → fall back to today's live-width replay).
    const live_cols: u16 = @intCast(@min(self.grid_size.columns, std.math.maxInt(u16)));
    const live_rows: u16 = @intCast(@min(self.grid_size.rows, std.math.maxInt(u16)));
    const reflow_replay = relaunch_replayed and replay_cols != 0 and replay_cols != live_cols;
    if (reflow_replay) io.reflowLocalGrid(replay_cols, live_rows);

    // Drain once immediately in case DATA landed in the ring between registration
    // and arming the wait (the agent may stream a snapshot right after OPENED).
    drainRing(td);

    // Reflow the just-replayed scrollback back to the live width. Leaves the grid
    // at `self.size.grid()` so later real resizes stay consistent. Fresh child
    // output (produced at the live width — the authoritative RESIZE above set the
    // agent pty) then continues to land at the live width.
    if (reflow_replay) io.reflowLocalGrid(live_cols, live_rows);
}

pub fn threadExit(self: *Remote, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .remote);
    const rd = &td.backend.remote;

    // §3.4 teardown order (use-after-free guard): this IS the consumer thread, and
    // by the time `threadExit` runs the xev loop has stopped, so no further
    // `drainRing`/`ringReady` will run — the consumer has stopped draining. We may
    // now DETACH or CLOSE, which deregisters the channel under the connection's
    // table lock (after which no in-flight demux `pushTo` can touch the ring) and
    // frees the ring + pane. DETACH (the default) keeps the remote session alive
    // for a later re-attach; CLOSE (user closed the pane/window — see
    // `close_on_exit`) terminates the child and frees the agent session.
    // Un-publish the live session id BEFORE the pane (and its `session_id`
    // backing) is freed, so the GUI thread never reads a dangling slice. Clear
    // the len first, then the ptr (mirror of the publish order).
    self.live_session_id_len.store(0, .release);
    self.live_session_id.store(null, .release);

    if (self.close_on_exit.load(.acquire)) {
        self.conn.closeChannel(rd.pane);
    } else {
        self.conn.detachChannel(rd.pane);
    }
    rd.pane = undefined;
}

pub fn focusGained(
    self: *Remote,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // §3.3: focus is "forwarded as DATA if enabled". The local terminal already
    // emits the focus-event escape (DECSET 1004) as normal output through
    // `queueWrite` when the remote child enables it, so there is nothing
    // backend-specific to forward here for the common path.
    // TODO(wp3): explicit focus-tracking forwarding if/when the agent opts in.
}

/// Resize the remote pane. Mirrors `Exec.resize`, which forwards the new geometry
/// to the local pty via `TIOCSWINSZ`; here we forward it to the agent's remote pty
/// via a `RESIZE` control frame.
///
/// `td` is null ONLY for the `initTerminal` seed call (before any channel exists):
/// then we just record the size, which `threadEnter` sends in `OPEN`. For every
/// live resize the IO thread passes its `ThreadData` (which owns the pane handle),
/// and we send the wire `RESIZE` so the remote shell is told its new window size
/// and repaints. Without this, a surface that starts at 0x0 (the GUI: the Cocoa
/// SurfaceView lays out AFTER `ghostty_surface_new`) would OPEN a 0x0 remote pty
/// and the resize that follows would never reach the agent — the remote shell
/// stays 0x0 and never paints, so the window renders BLANK (WP4 bug).
pub fn resize(
    self: *Remote,
    td: ?*termio.Termio.ThreadData,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;

    // No channel yet (the `initTerminal` seed): just record; `OPEN` carries it.
    const td_live = td orelse return;
    assert(td_live.backend == .remote);
    const rd = &td_live.backend.remote;
    log.debug("RESIZE send rows={} cols={} ch={x}", .{
        grid_size.rows, grid_size.columns, rd.pane.id,
    });
    rd.conn.sendResize(
        rd.pane,
        @intCast(@min(grid_size.rows, std.math.maxInt(u16))),
        @intCast(@min(grid_size.columns, std.math.maxInt(u16))),
        @intCast(@min(screen_size.width, std.math.maxInt(u16))),
        @intCast(@min(screen_size.height, std.math.maxInt(u16))),
    ) catch |err| log.warn("error sending RESIZE err={}", .{err});
}

pub fn queueWrite(
    self: *Remote,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    assert(td.backend == .remote);
    const rd = &td.backend.remote;

    // If the agent reported the session exited we stop sending input.
    if (rd.exited) return;

    // Prompt policy (T12c2): a dead-but-relaunchable pane is showing the
    // "press any key to relaunch" affordance. The first keystroke consents to the
    // respawn — fire the deferred RELAUNCH and swallow the triggering byte(s) (there
    // is no child yet to receive them). An empty write (e.g. a focus report) is
    // ignored so it does not spuriously relaunch.
    if (self.awaiting_relaunch) {
        if (data.len == 0) return;
        self.performAwaitedRelaunch(td);
        return;
    }

    if (!linefeed) {
        // Fast path: enqueue the bytes as a single DATA frame (§3.4). The pane
        // owns its outbound byte offset; the connection's MPSC writer owns the
        // socket.
        try rd.conn.writeInput(rd.pane, data);
        return;
    }

    // Slow path: translate bare `\r` into `\r\n` (matches Exec's linefeed mode)
    // before framing. We chunk through a small stack buffer to bound the temp.
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < data.len) {
        var buf_i: usize = 0;
        while (i < data.len and buf_i < buf.len - 1) {
            const ch = data[i];
            i += 1;
            if (ch != '\r') {
                buf[buf_i] = ch;
                buf_i += 1;
                continue;
            }
            buf[buf_i] = '\r';
            buf[buf_i + 1] = '\n';
            buf_i += 2;
        }
        try rd.conn.writeInput(rd.pane, buf[0..buf_i]);
    }
}

/// Fire the deferred `RELAUNCH` for a `.prompt`-policy pane once the user consents
/// with a keystroke (T12c2). Runs on the IO thread (from `queueWrite`), which parks
/// on the RPC exactly like `threadEnter`'s `.auto` relaunch — `shutdown` cancels the
/// canceller so a doomed relaunch under teardown wakes immediately. On success the
/// pane's child is live and streaming on its already-armed ring; we print the
/// "restarted" divider above the fresh output. On failure the pane stays childless
/// and we print a note (the pane still tears down cleanly on threadExit).
fn performAwaitedRelaunch(self: *Remote, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .remote);
    const rd = &td.backend.remote;

    // Clear the flag first so a second keystroke racing in cannot double-fire.
    self.awaiting_relaunch = false;

    const rows: u16 = @intCast(@min(self.grid_size.rows, std.math.maxInt(u16)));
    const cols: u16 = @intCast(@min(self.grid_size.columns, std.math.maxInt(u16)));
    const px_w: u16 = @intCast(@min(self.screen_size.width, std.math.maxInt(u16)));
    const px_h: u16 = @intCast(@min(self.screen_size.height, std.math.maxInt(u16)));

    const res = rd.conn.sendRelaunchOnPane(
        rd.pane,
        rows,
        cols,
        px_w,
        px_h,
        // Respawn fidelity (wp3): same live env/TERM/argv as the auto path.
        .{ .env = self.env, .term = self.term, .argv = self.argv },
        &self.canceller,
    ) catch |err| {
        log.warn("awaited relaunch failed err={}", .{err});
        const note = "\r\n\x1b[2m--- relaunch failed ---\x1b[0m\r\n";
        @call(.always_inline, termio.Termio.processOutput, .{ rd.io, note });
        return;
    };
    if (!res.ok) {
        log.warn("awaited relaunch not ok found={}", .{res.found});
        const note = "\r\n\x1b[2m--- relaunch failed (session no longer available) ---\x1b[0m\r\n";
        @call(.always_inline, termio.Termio.processOutput, .{ rd.io, note });
        return;
    }

    log.info("relaunched dead session on keystroke pid={}", .{res.pid});
    // The respawned child has a fresh pid + pty; re-publish for `getProcessInfo`
    // (`sendRelaunchOnPane` updated the pane's pid/tty on ok).
    self.publishProcessInfo(rd.pane);
    const divider = "\r\n\x1b[2m--- session restarted ---\x1b[0m\r\n";
    @call(.always_inline, termio.Termio.processOutput, .{ rd.io, divider });

    // The respawned session's DATA arrives on the ring (armed since threadEnter);
    // drain once immediately in case it landed while we were parked on the RPC (the
    // async notify is coalesced, so ringReady will also run, but this is prompt).
    drainRing(td);
}

pub fn childExitedAbnormally(
    self: *Remote,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    // §3.3: overlay from an `EXIT{code}`. The remote has no local `subprocess.args`
    // to render a command line into the overlay text, so increment 4a logs the
    // exit; the exit-diagnostics overlay text is wired when the agent surfaces the
    // remote command (a later increment).
    // TODO(wp3): render the remote command + a richer overlay from agent metadata.
    log.warn(
        "remote child exited abnormally code={} runtime={}ms",
        .{ exit_code, runtime_ms },
    );
}

pub fn getProcessInfo(self: *Remote, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    // §3.3: cached agent metadata or null (wp3). The metadata is published by
    // the IO thread from `OPENED`/`ATTACHED`/`RELAUNCHED` replies (see
    // `publishProcessInfo`); an older agent never reports it and every caller
    // handles the null. Callable from any thread (the GUI reads it for the IPC
    // `+list` pid/tty fields).
    return switch (info) {
        // Prefer the LIVE foreground pid the agent samples via `tcgetpgrp`
        // (pushed as `META{foreground_pid}` on change — full Exec parity);
        // fall back to the child pid when the agent has not reported one
        // (older agent, Windows ConPTY, or a fresh shell where they are the
        // same process anyway).
        .foreground_pid => pid: {
            const fg = self.fg_pid.load(.acquire);
            if (fg > 0) break :pid @intCast(fg);
            const pid = self.child_pid.load(.acquire);
            if (pid <= 0) break :pid null;
            break :pid @intCast(pid);
        },
        .tty_name => tty: {
            const ptr = self.tty_name_ptr.load(.acquire) orelse break :tty null;
            break :tty std.mem.sliceTo(ptr, 0);
        },
    };
}

/// Publish the pane's agent-reported pid/tty for `getProcessInfo` (wp3). Runs on
/// the IO thread (`threadEnter`, and again after an in-place relaunch replaces
/// the child). The tty is duped into `arena` so previously-published pointers
/// remain valid for racing readers; only LOCAL-agent connections publish it (a
/// cross-machine tty names a remote device and could false-match local
/// `+list --tty` lookups — see `Config.local`).
fn publishProcessInfo(self: *Remote, pane: *const connection.Pane) void {
    if (pane.pid > 0) self.child_pid.store(pane.pid, .release);

    // A (re)published pane means a fresh child or a fresh viewer binding: any
    // previously-cached live foreground pid is stale (the agent re-pushes the
    // current one within a tick of the rebind — `bindLocked` resets its sampler
    // baseline). Until then the child pid above is the correct fallback.
    self.fg_pid.store(0, .release);

    if (!self.local) return;
    const tty = pane.tty orelse return;
    if (tty.len == 0) return;
    const copy = self.arena.allocator().dupeZ(u8, tty) catch return;
    self.tty_name_ptr.store(copy.ptr, .release);
}

// -----------------------------------------------------------------------------
// Inbound ring drain path (the read side, §3.4)
// -----------------------------------------------------------------------------

/// Waker callback invoked by the connection's demux thread after it pushes DATA
/// into this pane's ring (`inbound_ring.Channel.push`). It MUST be cheap and
/// non-blocking — it only notifies our async handle, which schedules `ringReady`
/// to run on THIS pane's IO thread. `ctx` is the `ThreadData.remote` for this
/// pane (a stable pointer for the thread's life).
fn wakeFromDemux(ctx: *anyopaque) void {
    const rd: *ThreadData = @ptrCast(@alignCast(ctx));
    rd.ring_async.notify() catch |err|
        log.warn("error notifying ring async err={}", .{err});
}

/// xev callback: the demux thread woke us because bytes landed in the ring. Drain
/// the whole ring and feed `processOutput` on this thread (the same call Exec's
/// `ReadThread` makes, self-locking the renderer mutex). Re-arm to keep waiting.
fn ringReady(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.warn("error in ring async wait err={}", .{err});
        return .rearm;
    };
    const td = td_ orelse return .rearm;
    drainRing(td);
    return .rearm;
}

/// Drain the pane's inbound ring fully into the terminal. Called on the pane's IO
/// thread (from `ringReady` or once eagerly in `threadEnter`). For each chunk:
///   1. pop from the ring (SPSC consumer side),
///   2. `processOutput` (parses + renders, self-locks the renderer mutex),
///   3. on the paused→flowing low-water edge, emit `FLOW{resume}` so the agent
///      resumes draining that session's PTY (§3.4 consumer-side flow control).
fn drainRing(td: *termio.Termio.ThreadData) void {
    assert(td.backend == .remote);
    const rd = &td.backend.remote;
    const ch = rd.pane.ring;

    // Cap the work per wake instead of draining until empty. processOutput
    // runs ON this IO thread (unlike Exec, whose ReadThread parses while the
    // IO thread drains the termio mailbox), so replies it generates (CPR,
    // DA1, color queries, ...) pile into our own 64-slot mailbox and nothing
    // drains it until we return to the xev loop. An unbounded drain of a big
    // burst (e.g. a re-attach ring replay) can fill it and previously parked
    // this thread on its own queue — producer == consumer, a self-deadlock
    // that also wedged the GUI thread when Surface.deinit joined us. Bail
    // after a bounded number of chunks and re-notify so the loop runs our
    // mailbox drain between bursts.
    var buf: [16 * 1024]u8 = undefined;
    var chunks: usize = 0;
    const max_chunks_per_wake = 32;
    while (chunks < max_chunks_per_wake) : (chunks += 1) {
        const res = ch.pop(&buf);
        if (res.read == 0) break;

        @call(.always_inline, termio.Termio.processOutput, .{ rd.io, buf[0..res.read] });

        if (res.send_resume) rd.conn.sendFlowResume(ch.id) catch |err|
            log.warn("error sending FLOW resume err={}", .{err});
    } else {
        // Hit the cap with the ring possibly non-empty: schedule another
        // wake and return to the loop. EXIT handling below is deferred to
        // the wake that finds the ring empty, preserving "final bytes
        // render before close".
        rd.ring_async.notify() catch |err|
            log.warn("error re-notifying ring async err={}", .{err});
        return;
    }

    // EXIT handling, mirroring local Exec (`Exec.zig` `processExit` →
    // `surface_mailbox.push(.child_exited)` → `Surface.childExited`). The agent
    // frames `EXIT` AFTER the session's final DATA (§6.4), and the control reader
    // turns it into `ch.signalExit` (which also wakes us); we check it only AFTER
    // the drain loop above has emptied the ring for this wake, so the shell's
    // final bytes have already rendered before we ask the surface to close. The
    // `rd.exited` guard makes this fire EXACTLY once even though `ringReady`
    // re-arms and may wake again. This reuses `Surface.childExited`'s existing
    // close / `wait-after-command` logic, so a remote shell `exit` closes the
    // pane just like a local one — no special remote close path.
    // Republish the agent's live foreground pid (wp3): the control reader
    // signaled it on the ring (`signalForegroundPid`, which also woke us);
    // copy it onto the STABLE Remote backend so GUI-thread `getProcessInfo`
    // reads never touch the pane/ring (which die at threadExit).
    const fg = ch.foregroundPid();
    if (fg > 0) rd.io.backend.remote.fg_pid.store(fg, .release);

    if (!rd.exited and ch.isExited()) {
        rd.exited = true;
        // Coerce the agent's i64 exit code to the surface message's u32. A negative
        // code (e.g. a signal encoded as <0 by some agents) saturates to 0 rather
        // than wrapping to a huge value; a normal 0..255 status passes through.
        const code: u32 = if (ch.exit_code < 0)
            0
        else if (ch.exit_code > std.math.maxInt(u32))
            std.math.maxInt(u32)
        else
            @intCast(ch.exit_code);
        // Timed retries on the SHARED app mailbox — never a forever park
        // (the GUI thread is the only consumer; if it's busy or joining us
        // in Surface.deinit, a forever wait here deadlocks the app). If the
        // surface is closing, the exit notification is moot: drop it.
        const msg: apprt.surface.Message = .{ .child_exited = .{
            .exit_code = code,
            .runtime_ms = ch.runtime_ms,
        } };
        while (td.surface_mailbox.push(msg, .{ .ns = 10 * std.time.ns_per_ms }) == 0) {
            if (rd.io.closing.load(.acquire)) break;
        }
    }
}

/// The thread-local data for the remote backend. Lives inside
/// `termio.Termio.ThreadData.backend` (a stable location for the IO thread's
/// life), so the demux waker and the xev callbacks can hold a `*ThreadData`.
pub const ThreadData = struct {
    /// The shared connection (caller-owned; not freed here).
    conn: *connection.Connection,

    /// Our pane handle on the connection. Owned by the connection; freed by
    /// `detachChannel`/`closeChannel` in `threadExit`. Set to `undefined` after
    /// teardown.
    pane: *connection.Pane,

    /// Back-reference to the Termio so the drain path can call `processOutput`.
    io: *termio.Termio,

    /// The async handle the demux thread notifies to wake this thread's drain.
    ring_async: xev.Async,
    ring_async_c: xev.Completion = .{},

    /// Set true once the agent reports the session exited (stops further input).
    exited: bool = false,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;
        // The pane/ring were already torn down by `threadExit` (`detachChannel`).
        // The connection is caller-owned. We only own the async handle here.
        self.ring_async.deinit();
        self.* = undefined;
    }
};

