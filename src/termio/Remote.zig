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
const session_notice = @import("session_notice.zig");
const open_failed_notice = @import("open_failed_notice.zig");
const attach_failed_notice = @import("attach_failed_notice.zig");
const restore_park = @import("restore_park.zig");

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
/// `shell_integration.setup()` argv-rewrite for bash/nushell/powershell so
/// those shells activate ghostty integration on the LOCAL agent. Null for cross-machine
/// windows and for env-only shells. Each element is duped into `arena`.
argv: ?[]const []const u8,

/// The FULL shell invocation that runs `command`, exec'd verbatim by the agent
/// instead of its own `<shell> [/c|-lic] <cmd>` synthesis (T468). Set only by a
/// LOCAL-agent apprt whose platform spells the keep-alive convention in ARGV
/// (Windows: `cmd /K`, `pwsh -NoExit -Command`) rather than inside the command
/// string (POSIX: `<cmd>; exec <shell> -li`), which is why it cannot simply ride
/// `command`. Coexists with `command`, which stays the session's label.
///
/// Used on the OPEN and on the two paths that deliberately RE-RUN the recorded
/// command (`auto` / `prompt` relaunch) — never on the `notify` fresh-shell
/// open, whose whole purpose is to not re-run it (T230). Each element is duped
/// into `arena`. Null everywhere else, leaving `argv` in charge.
command_argv: ?[]const []const u8,

/// Pin this session against the agent's idle-TTL reaper (§7.1, T11). True only
/// for a persistent LOCAL-agent pane; sent in `OPEN.pinned`. Ignored on ATTACH.
pinned: bool,

/// True when the connection is the LOCAL agent (see `Config.local`). Gates
/// publishing the agent-reported tty for `getProcessInfo(.tty_name)` (wp3).
local: bool,

/// What to do when an ATTACH finds the session a DEAD-but-relaunchable tombstone
/// (the agent itself restarted and materialized it from disk, §5.4 reboot floor,
/// T12c). `.notify` (the default) refuses to re-run it and opens a fresh shell
/// with a notice instead (T230); `.auto` respawns it in place (`RELAUNCH`) and
/// shows a restarted divider; `.prompt` leaves the pane in its exited state for
/// the user to decide. Only meaningful for the LOCAL-agent ATTACH path;
/// irrelevant on OPEN-new.
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

/// Whether anything is running under this session's shell, as the agent last
/// reported it (`META{has_descendants}`, T356): the agent samples its own
/// process table once a second and pushes changes; the control reader signals
/// the pane's ring and the IO thread copies the value here (see `drainRing`) for
/// lock-free GUI reads. This is what lets the close confirmation be skipped for
/// an idle CROSS-MACHINE pane, whose shell is in no process table the app can
/// walk. `.unknown` until the agent reports (older agent, or nothing sampled
/// yet), which callers must read as "ask the user" — never as idle.
busy_state: std.atomic.Value(u8) = .init(@intFromEnum(inbound_ring.Channel.BusyState.unknown)),

/// WP-D3 fast, visually-correct re-attach. `restore_snapshot` is the app's OWN
/// structured VT repaint of the pane's screen (palette + modes + styles +
/// cursor + bounded scrollback) captured when the session was last persisted,
/// and `attach_offset` is the absolute agent-stream byte offset that snapshot
/// reflects. On ATTACH we (a) paint the snapshot directly for an instant,
/// correctly-sized frame and (b) pass `attach_offset` as the ATTACH
/// `last_byte_offset` so the agent replays ONLY the small gap produced while we
/// were detached, instead of re-parsing its whole ~2MB retained ring (the slow,
/// smeary path). Both null/0 for a normal OPEN or a legacy restore, which falls
/// back to the full-ring replay. `restore_snapshot` is duped into `arena`.
restore_snapshot: ?[]const u8 = null,

/// The absolute agent-stream byte offset the terminal has applied. Seeded from
/// the restore offset in `init`; advanced by `drainRing` (via
/// `Termio.processOutputTracked`) as replayed/live bytes are fed to the parser.
/// `appliedOffset()` = `attach_offset + applied_bytes`. Persisted on quit as the
/// next restore's `last_byte_offset`.
attach_offset: u64 = 0,
applied_bytes: std.atomic.Value(u64) = .init(0),

/// T422: the app restored this pane's own sticky banner before bring-up, so the
/// session-interrupted notice keeps only its in-stream copy. See
/// `Config.pane_banner_restored`.
pane_banner_restored: bool = false,

/// The message to paint into the pane when bring-up failed for a reason we
/// actually know — a refused OPEN (T469, `open_failed_notice`) or an ATTACH
/// that yielded no pane (T657, `attach_failed_notice`). Empty ⇒ nothing better
/// than the generic text.
///
/// It lives HERE, on the stable backend (`Termio.backend.remote`), because of
/// who reads it: `termio.Thread.threadMain`'s failure paint runs after
/// `threadEnter` has already returned an error and its `ThreadData` is gone, so
/// the only surviving handle is the `*Termio` — and the backend hangs off that.
/// A fixed buffer rather than an allocation: this is written on the way out of a
/// failing path, which is the worst possible place to add something else that
/// can fail or leak.
///
/// ONE buffer for both, because a bring-up fails once: a pane either never
/// opened or never re-attached, and the paint shows exactly one message.
///
/// Single-threaded by construction — written by the pane's IO thread inside
/// `threadEnter`, read by that same thread in the paint that follows it.
bring_up_notice_buf: [@max(open_failed_notice.max_len, attach_failed_notice.max_len)]u8 = undefined,
bring_up_notice_len: usize = 0,

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
    /// LOCAL-agent client for a plain interactive bash/nushell/powershell pane
    /// (the argv-rewrite `shell_integration.setup()` returns); null everywhere else
    /// (env-only shells, user-command panes, cross-machine windows). Borrowed
    /// from the caller; `init` dupes each element into the backend arena.
    argv: ?[]const []const u8 = null,

    /// The keep-alive invocation of an explicit `--command` for a LOCAL-agent
    /// pane whose platform spells that convention in argv (T468). Unlike `argv`
    /// it coexists with `command`. Null everywhere else. Borrowed from the
    /// caller; `init` dupes each element into the backend arena.
    command_argv: ?[]const []const u8 = null,

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

    /// WP-D3: the persisted structured VT screen snapshot to paint on ATTACH,
    /// and the absolute byte offset it reflects (used as the ATTACH
    /// `last_byte_offset`). Default null/0 → full-ring replay (pre-WP-D3
    /// behavior). `restore_snapshot` is borrowed; `init` dupes it into the arena.
    restore_snapshot: ?[]const u8 = null,
    restore_offset: u64 = 0,

    /// True ⇒ the app already put this pane's own sticky banner back from its
    /// session-layout manifest (T422), so the banner slot is SPOKEN FOR. The
    /// session-interrupted notice then writes only its in-stream copy and does
    /// not emit the OSC 7778 second carrier, which would otherwise replace a
    /// banner carrying that pane's own live state with a sentence identical in
    /// every restored pane — the reported loss.
    ///
    /// False is the safe default and covers everything else: a fresh OPEN, a
    /// re-attach to a live session, and a restored pane that had no banner. In
    /// that last case the slot really is empty, so the notice may use it and
    /// stays visible without the user scrolling back for it.
    pane_banner_restored: bool = false,
};

/// Which working directory an OPEN should carry (T144).
///
/// `explicit` is the REMOTE-native cwd the apprt resolved for this surface —
/// the parent pane's live cwd for a tab/split, or an IPC/menu-supplied path.
/// It always wins.
///
/// `local` is the surface config's already-resolved `working-directory`, i.e.
/// what the EXEC backend would chdir into: the focused surface's pwd when
/// `window-inherit-working-directory` applies, else the platform default
/// (`$HOME` / `%HOMEDRIVE%%HOMEPATH%` for a GUI launch). It is only usable
/// when the agent runs on THIS machine.
///
/// The distinction is the whole point: a CROSS-MACHINE agent may run a
/// different OS, where a local path does not exist — forwarding one makes the
/// agent's spawn fail and never reply OPENED (a blank, wedged pane). The LOCAL
/// session-persistence agent is this same machine, so refusing to forward it
/// buys nothing and costs everything: the OPEN carries no cwd, the agent
/// spawns the child in the AGENT's own inherited cwd, and an agent started by
/// the HKCU `Run` autostart entry inherits `C:\WINDOWS\system32` — measured on
/// the box, and exactly the user-reported symptom. Mac already forwards it
/// (`TerminalController.swift`, "the agent runs on THIS machine"); this is the
/// shared-core home for that rule so both apprts get it.
pub fn openWorkingDirectory(
    explicit: ?[]const u8,
    local: ?[]const u8,
    is_local_agent: bool,
) ?[]const u8 {
    if (explicit) |e| return e;
    return if (is_local_agent) local else null;
}

/// What a restored pane does when its ATTACH target comes back as a
/// dead-but-relaunchable tombstone across an agent restart (§5.4, T12c). Mirrors
/// `config.SessionRelaunch`; kept local so this backend need not import config.
///
/// `notify` is the default (T230) and is the only one of the three that never
/// puts a recorded command back on a CPU: it opens a brand-new session on a
/// fresh shell in the dead session's working directory and prints
/// `session_notice` above it. `auto` respawns the recorded command; `prompt`
/// respawns it on the first keystroke.
pub const RelaunchPolicy = enum { notify, auto, prompt };

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
    const restore_snapshot = if (cfg.restore_snapshot) |s| try aa.dupe(u8, s) else null;

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

    // Same for the command's keep-alive invocation (T468).
    const command_argv: ?[]const []const u8 = if (cfg.command_argv) |src| argv: {
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
        .command_argv = command_argv,
        .pinned = cfg.pinned,
        .local = cfg.local,
        .relaunch_policy = cfg.relaunch_policy,
        .restore_snapshot = restore_snapshot,
        // The offset is only meaningful WITH a snapshot: attaching at offset>0
        // without painting the prior content would leave the screen blank above
        // the gap-fill. No snapshot ⇒ offset 0 ⇒ full-ring replay.
        .attach_offset = if (restore_snapshot != null) cfg.restore_offset else 0,
        .pane_banner_restored = cfg.pane_banner_restored,
        .arena = arena,
    };
}

/// The absolute agent-stream byte offset applied to the terminal so far (WP-D3):
/// the offset we attached at plus everything drained since. Persisted on quit
/// so the next re-attach replays only the gap. Lock-free.
pub fn appliedOffset(self: *const Remote) u64 {
    return self.attach_offset + self.applied_bytes.load(.monotonic);
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

/// Render and keep the pane message for an OPEN the agent refused (T469), so
/// `termio.Thread`'s failure paint can show the reason instead of the generic
/// "exhausting a system resource" text. Called on the IO thread, on the way out
/// of a failing `threadEnter`.
fn recordOpenRefusal(self: *Remote, refusal: protocol.RefusalCopy) void {
    const msg = open_failed_notice.format(
        &self.bring_up_notice_buf,
        refusal.reason(),
        refusal.detail(),
    );
    self.bring_up_notice_len = msg.len;
    log.warn(
        "OPEN refused by the agent reason={s} detail={?s}",
        .{ refusal.reason(), refusal.detail() },
    );
}

/// The same, for an `ATTACH_FAILED` the agent sent (T657) — the refusals no
/// `ATTACHED` payload could describe.
fn recordAttachRefusal(self: *Remote, refusal: protocol.RefusalCopy) void {
    const msg = attach_failed_notice.format(
        &self.bring_up_notice_buf,
        refusal.reason(),
        refusal.detail(),
    );
    self.bring_up_notice_len = msg.len;
    log.warn(
        "ATTACH refused by the agent reason={s} detail={?s}",
        .{ refusal.reason(), refusal.detail() },
    );
}

/// ...and for an ATTACH the agent DID answer, with a status that yields no pane
/// (T657). This is the common case by far — a session the agent no longer has,
/// one whose process ended for good, one another window is already showing —
/// and it needs no capability at all, because the status has ridden `ATTACHED`
/// since long before there was a frame to refuse on. Before this the answer
/// reached the pane as a bare `error.RemoteAttachFailed` and the generic paint
/// blamed the system for "exhausting a system resource".
fn recordAttachFailure(self: *Remote, outcome: *const connection.AttachOutcome) void {
    const r = attach_failed_notice.reasonForStatus(
        @tagName(outcome.status),
        outcome.attached_elsewhere,
    );
    // The detail names the machine-readable state behind the sentence, so a bug
    // report carries what the log line would have.
    var detail_buf: [attach_failed_notice.max_detail_len]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "status={s} relaunchable={} attached_elsewhere={}", .{
        @tagName(outcome.status),
        outcome.relaunchable,
        outcome.attached_elsewhere,
    }) catch null;
    const msg = attach_failed_notice.format(&self.bring_up_notice_buf, r, detail);
    self.bring_up_notice_len = msg.len;
}

/// The message to paint instead of the generic IO-thread failure text, or null
/// when this pane's bring-up failed for a reason we have nothing better to say
/// about (a timeout, a dead link, an agent too old to answer a refusal).
pub fn bringUpNotice(self: *const Remote) ?[]const u8 {
    if (self.bring_up_notice_len == 0) return null;
    return self.bring_up_notice_buf[0..self.bring_up_notice_len];
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
    // Set true when the pane below came back via RELAUNCH (a dead-but-relaunchable
    // session respawned across an agent restart) rather than a live attach/open —
    // used after bring-up to print a "session restarted" divider (T12c).
    var did_relaunch = false;
    // Set when the pane's persisted session was a dead tombstone and the
    // `.notify` policy (T230) opened a FRESH session instead of respawning the
    // recorded command. Holds the command we refused to re-run (arena-owned, so
    // it outlives the ATTACH outcome), or null when the agent recorded none /
    // is too old to report one. Drives the notice printed after bring-up.
    var notice_command: ?[]const u8 = null;
    var did_notify = false;
    // Set true when the agent ALREADY replayed pre-restart scrollback + the restart
    // divider from a ring disk snapshot (§5.4, T13) — the client then suppresses its
    // own snapshot-less divider so there is exactly one marker.
    var relaunch_replayed = false;
    // The width/height the replayed scrollback was drawn at (0 = unknown). Used to
    // replay at that width and reflow to the live pane so in-place prompt redraws
    // don't smear (§5.4). Only meaningful with `relaunch_replayed`.
    var replay_cols: u16 = 0;
    var replay_rows: u16 = 0;
    // Set on a live ATTACH from the agent-reported pre-attach geometry + ring
    // head (T106): the raw ring replay is geometry-bound VT, so we replay at
    // the geometry it was drawn at and reflow to the live grid once the drain
    // has applied everything up to `attach_snapshot_at`. 0 = unknown/older
    // agent → keep today's live-width replay.
    var attach_replay_rows: u16 = 0;
    var attach_replay_cols: u16 = 0;
    var attach_snapshot_at: u64 = 0;
    // The session's REAL working directory as the AGENT reports it (T166).
    // `initTerminal` could only seed the pwd from what the app already knew —
    // on a restore that is the config-resolved default (e.g. $HOME), not where
    // the re-attached session actually lives — so `+list --json` answered the
    // default for every restored pane while `+sessions --json` had the truth.
    // Every attach-family reply carries the recorded cwd (ATTACHED alive,
    // ATTACHED dead → notify/auto/prompt); null means an older agent, and the
    // seeded value stands (degrade, don't fail). Arena-owned.
    var attach_cwd: ?[]const u8 = null;

    // Open a new session or attach to an existing one to obtain our pane.
    const pane: *connection.Pane = if (self.session_id) |sid| pane: {
        // ATTACH: re-attach to an existing agent session (§3.3 / §7.3).
        const rows: u16 = @intCast(@min(self.grid_size.rows, std.math.maxInt(u16)));
        const cols: u16 = @intCast(@min(self.grid_size.columns, std.math.maxInt(u16)));
        // WHICH re-attach this is, at info: the two paths look identical from
        // outside and behave very differently (a delta attach paints our own
        // snapshot and asks for a small gap; a full-ring attach re-parses the
        // agent's whole geometry-bound ring). Without this line the only way to
        // tell them apart on box is to eyeball the pane. `snapshot=` is the
        // decoded VT byte count, so a manifest whose snapshot was dropped or
        // failed to decode reads as `offset=0 snapshot=0`.
        log.info("attach: session={s} offset={d} snapshot={d}", .{
            sid,
            self.attach_offset,
            if (self.restore_snapshot) |s| s.len else 0,
        });
        var attach_refusal: protocol.RefusalCopy = .{};
        var outcome = self.conn.attachChannelRefusable(
            sid,
            rows,
            cols,
            // WP-D3: attach at the byte offset our persisted screen snapshot
            // reflects (0 on a legacy/fresh attach) so the agent gap-fills ONLY
            // the bytes produced while we were detached (§7.3) instead of
            // re-parsing its whole retained ring. The snapshot painted below in
            // `threadEnter` supplies everything at/below this offset.
            self.attach_offset,
            false,
            &self.canceller,
            &attach_refusal,
        ) catch |err| {
            // The agent told us it could not answer, and why (T657). Keep the
            // sentence for the failure paint — the error itself carries no
            // payload, and without this the pane would come up blank and blame
            // a timeout for a refusal that took milliseconds.
            if (err == error.AttachRefused) self.recordAttachRefusal(attach_refusal);
            return err;
        };
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
            outcome = self.conn.attachChannelRefusable(
                sid,
                rows,
                cols,
                self.attach_offset,
                true,
                &self.canceller,
                &attach_refusal,
            ) catch |err| {
                if (err == error.AttachRefused) self.recordAttachRefusal(attach_refusal);
                return err;
            };
        }
        defer outcome.deinit();
        if (outcome.pane) |p| {
            // T739: the two numbers whose disagreement is the whole defect —
            // what we asked to resume from, and where the agent's stream
            // actually ends. For a pane that produced nothing since the manifest
            // was written they must be EQUAL; a `requested` above `head` means
            // we recorded a position the session never reached (which the clamp
            // below then pulls back, skipping whatever sat in between). Logged
            // unconditionally because there is no way to read either number from
            // outside the app, and the pane looks identical whichever way it went.
            log.info("attach: requested={d} head={d} resumed_at={d} repaints={} labeled={}", .{
                self.attach_offset,
                outcome.snapshot_at_offset,
                outcome.resume_offset,
                self.conn.peerRepaintsOnAttach(),
                self.conn.peerLabelsRepaints(),
            });
            attach_replay_rows = outcome.replay_rows;
            attach_replay_cols = outcome.replay_cols;
            attach_snapshot_at = outcome.snapshot_at_offset;
            // T532: the connection clamps a resume point that sits ABOVE the
            // agent's stream head (a session id whose byte stream restarted
            // under it — an agent restart, or a manifest written before one).
            // Rebase our absolute base onto what was actually honored, or every
            // later `appliedOffset()` and the manifest entry written from it
            // stay in that phantom future and the NEXT restore freezes too.
            if (outcome.resume_offset != self.attach_offset) {
                log.warn(
                    "attach: recorded offset {d} is ahead of the agent's stream head {d}; " ++
                        "resuming from the head (the session's stream restarted under this id)",
                    .{ self.attach_offset, outcome.resume_offset },
                );
                self.attach_offset = outcome.resume_offset;
            }
            // Copy out of `outcome` before its `defer deinit()` frees it.
            if (outcome.cwd) |c|
                attach_cwd = self.arena.allocator().dupe(u8, c) catch null;
            break :pane p;
        }

        // No live pane. A DEAD-but-relaunchable tombstone means the AGENT itself
        // restarted (a reboot or an agent upgrade) and materialized this session
        // from its on-disk metadata (§5.4 reboot floor, T12b) — the recorded
        // argv/cwd COULD bring the process back.
        //
        // T230: by default we refuse to. Re-executing a recorded command is
        // unsafe as a default — it was recorded in a world that no longer
        // exists, it may be a build/migration/agent loop that must not run
        // twice, and the user never asked for it again ("We should not ever
        // re-execute the commands which were previously ran"). So `notify` (the
        // default) opens a BRAND-NEW session on a fresh shell, placed in the
        // dead session's recorded working directory — a cwd is not a command; it
        // re-creates no side effects — and prints a notice naming the command it
        // did not run. `auto` and `prompt` keep the old respawning behavior for
        // anyone who opts back in.
        if (outcome.status == .dead and outcome.relaunchable and
            self.relaunch_policy == .notify)
        {
            // Copy out of `outcome` before its `defer deinit()` frees it. The
            // arena lives as long as this backend, which outlives the notice.
            //
            // Prefer the agent's sampled FOREGROUND command (T429): for a plain
            // shell pane `argv` is null (nobody passed --command), and what the
            // user thinks of as "the previous command" is the program they ran
            // INSIDE the shell — `claude`, not `cmd.exe`. `argv` remains the
            // fallback for panes opened with an explicit command, and an older
            // agent that reports neither keeps today's behavior (no line).
            const aa = self.arena.allocator();
            const label: ?[]const u8 = outcome.fg_cmd orelse outcome.argv;
            notice_command = if (label) |v| aa.dupe(u8, v) catch null else null;
            const cwd: ?[]const u8 = if (outcome.cwd) |c|
                (aa.dupe(u8, c) catch self.working_directory)
            else
                self.working_directory;
            // The fresh shell opens THERE, so that is also the pwd to report
            // (T166) — the initTerminal seed was the restore-path default.
            attach_cwd = cwd;

            // Retire the tombstone. It is pinned against the idle reaper (every
            // persistent local pane is), the manifest is about to point at the
            // NEW session id, and nothing will ever attach to it again — so
            // without this it would sit in the agent's `sessions.json` forever
            // and be re-offered on every subsequent restart.
            //
            // Fire-and-forget on purpose: we are on the pane's IO thread with a
            // user waiting for a prompt, and the answer changes nothing. The
            // bounded-RPC version of this cost 1.5 s per pane on box (measured,
            // and it timed out) for a result we would only have logged. An agent
            // too old to advertise CLOSE_SESSION just keeps the tombstone.
            self.conn.closeSessionNoWait(sid) catch |err| {
                log.info("notify policy: could not retire dead session err={} (harmless)", .{err});
            };

            const open: protocol.Open = .{
                // The whole point: NO command. A fresh interactive shell.
                .command = null,
                .cwd = cwd,
                .shell = self.shell,
                .term = self.term,
                .env = self.env,
                .argv = self.argv,
                .pinned = self.pinned,
                .rows = rows,
                .cols = cols,
                .px_w = @intCast(@min(self.screen_size.width, std.math.maxInt(u16))),
                .px_h = @intCast(@min(self.screen_size.height, std.math.maxInt(u16))),
            };
            var refusal: protocol.RefusalCopy = .{};
            const p = self.conn.openChannelRefusable(open, &self.canceller, &refusal) catch |err| {
                log.warn("notify policy: fresh session open failed err={}", .{err});
                if (err == error.OpenRefused) self.recordOpenRefusal(refusal);
                return error.RemoteAttachFailed;
            };
            did_notify = true;
            log.info(
                "dead relaunchable session NOT re-run (notify policy); opened a fresh shell instead",
                .{},
            );
            break :pane p;
        }

        // `auto`: RELAUNCH it in place on the SAME channel the dead ATTACHED
        // arrived on and stream fresh output.
        if (outcome.status == .dead and outcome.relaunchable and
            self.relaunch_policy == .auto)
        {
            // The respawn runs in the RECORDED cwd (the agent's on-disk floor),
            // so report that rather than the restore-path seed (T166).
            if (outcome.cwd) |c|
                attach_cwd = self.arena.allocator().dupe(u8, c) catch null;
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
                // keeps GHOZTTY_PANE_ID & co. and its shell integration. A
                // command pane sends its keep-alive invocation (T468): `auto`
                // exists to re-run the recorded command, so it should come back
                // the way it was opened, keep-alive included.
                .{
                    .env = self.env,
                    .term = self.term,
                    .argv = self.command_argv orelse self.argv,
                },
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
            // The eventual keystroke-relaunch runs in the recorded cwd (T166).
            if (outcome.cwd) |c|
                attach_cwd = self.arena.allocator().dupe(u8, c) catch null;
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
        // ...and SAY it in the pane (T657). The agent answered — it named the
        // state in `ATTACHED.status`, immediately, and has done so on every
        // agent that has ever shipped — but that answer stopped here, at a log
        // line, and the user got the generic "exhausting a system resource"
        // paint. This is the resume path: a reboot, an app upgrade, a session
        // picked from the chooser. It should say which of those went wrong.
        self.recordAttachFailure(&outcome);
        return error.RemoteAttachFailed;
    } else pane: {
        // OPEN-new: start a brand-new remote session (§3.3 open-new).
        const open: protocol.Open = .{
            .command = self.command,
            .cwd = self.working_directory,
            .shell = self.shell,
            .term = self.term,
            .env = self.env,
            // T468: the apprt's keep-alive invocation when it built one, else
            // the shell-integration rewrite. Never both — a `command` pane gets
            // no integration rewrite (see `Surface.forwarded_argv`).
            .argv = self.command_argv orelse self.argv,
            .pinned = self.pinned,
            .rows = @intCast(@min(self.grid_size.rows, std.math.maxInt(u16))),
            .cols = @intCast(@min(self.grid_size.columns, std.math.maxInt(u16))),
            .px_w = @intCast(@min(self.screen_size.width, std.math.maxInt(u16))),
            .px_h = @intCast(@min(self.screen_size.height, std.math.maxInt(u16))),
        };
        var refusal: protocol.RefusalCopy = .{};
        break :pane self.conn.openChannelRefusable(open, &self.canceller, &refusal) catch |err| {
            // The agent told us WHY it will not open this pane (T469). Keep the
            // sentence for the failure paint below — the error itself carries no
            // payload, and without this the pane would come up blank and then
            // blame `error.Timeout` for a refusal that took milliseconds.
            if (err == error.OpenRefused) self.recordOpenRefusal(refusal);
            return err;
        };
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

    // Apply the agent-reported working directory (T166): set the terminal's
    // pwd (what `core_surface.pwd()` answers) and tell the surface (what keeps
    // the apprt's cached copy — the one `+list --json` actually reports —
    // from staying frozen on the initTerminal seed). Same two-step shape as
    // the OSC 7 path in `stream_handler.zig`.
    if (attach_cwd) |cwd| {
        log.info("attach: applying agent-reported cwd={s}", .{cwd});
        {
            io.renderer_state.mutex.lock();
            defer io.renderer_state.mutex.unlock();
            io.terminal.setPwd(cwd) catch |err| {
                log.warn("attach: error setting terminal pwd err={}", .{err});
            };
        }
        if (apprt.surface.Message.WriteReq.init(alloc, cwd)) |req| {
            const msg: apprt.surface.Message = .{ .pwd_change = req };
            if (io.surface_mailbox.push(msg, .{ .instant = {} }) == 0) {
                // The surface mailbox is the SHARED app mailbox, drained only
                // by the GUI thread — which during a restore rebuild is busy
                // building the other windows, so at bring-up it is routinely
                // full (measured: 2 of 3 restored panes dropped here). Timed
                // retries until it lands — unless this surface is being torn
                // down (`shutdown` cancels before deinit joins this thread),
                // in which case nobody cares, drop it. Mirrors
                // `stream_handler.surfaceMessageWriter`.
                while (io.surface_mailbox.push(msg, .{ .ns = 10 * std.time.ns_per_ms }) == 0) {
                    if (self.canceller.isCancelled()) {
                        req.deinit();
                        break;
                    }
                }
            }
        } else |err| {
            log.warn("attach: error creating pwd_change req err={}", .{err});
        }
    }

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
    if (did_notify) {
        // T230: this pane's session is gone and we deliberately did not put its
        // command back on a CPU. Say so, name what it was, and leave the user on
        // the fresh prompt below to decide.
        //
        // The in-stream text is written here and folded into the scrollback by
        // the drain, on the last tick before the child's first bytes are parsed
        // (T423). Not here, because bring-up is not finished: the fresh shell is
        // about to hand us conhost's whole screen buffer as absolutely-positioned
        // VT and erase anything left on the active screen (cmd.exe's
        // `ESC[H ESC[2J`, measured), and this pane may still be narrowed by the
        // creation of a split's sibling. Above the viewport is the one region
        // that repaint never reaches — and it is where the user asked for the
        // notice to be: inline, above the shell content, in the console logging.
        // `Termio.holdNoticeAboveLocked` is what keeps it there afterwards.
        var notice_buf: [session_notice.max_len]u8 = undefined;
        const notice = session_notice.format(&notice_buf, notice_command);
        @call(.always_inline, termio.Termio.processOutput, .{ io, notice });
        io.armNoticeFold();

        // The second carrier: on screen without the user having to scroll for
        // it — but ONLY into a banner slot nobody else owns (T422). The user's
        // own banner carries that pane's live state (goal, status, PR links);
        // this sentence is identical in every restored pane, so replacing N
        // distinct banners with N copies of it is strictly negative. When the
        // restore brought a banner back, the notice settles for the scrollback
        // copy T423 made durable.
        if (!self.pane_banner_restored) {
            var banner_buf: [session_notice.max_len]u8 = undefined;
            const banner = session_notice.formatBanner(&banner_buf, notice_command);
            @call(.always_inline, termio.Termio.processOutput, .{ io, banner });
        }
    } else if (did_relaunch and !relaunch_replayed) {
        const divider = "\r\n\x1b[2m--- session restarted ---\x1b[0m\r\n";
        @call(.always_inline, termio.Termio.processOutput, .{ io, divider });
    } else if (self.awaiting_relaunch) {
        // Prompt policy (T12c2): the pane is a dead tombstone with no child. Show
        // an interactive affordance — `queueWrite` respawns it on the first key.
        //
        // Same `Label:` shape as the notice next door, and for the same reason
        // (T424): the user asked for a colon rather than an em dash, and this is
        // the same voice on a sibling path. Keep the two in step.
        const prompt =
            "\r\n\x1b[1mSession ended:\x1b[0m \x1b[2mpress any key to relaunch\x1b[0m\r\n";
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

    // T106: geometry-faithful ATTACH replay. On a full-ring re-attach
    // (`attach_offset == 0` — the win32 restore path, no persisted snapshot)
    // the agent's raw ring bytes are geometry-bound VT: conhost paints with
    // `ESC[H` re-homes and bottom-row line feeds whose scroll (and thus
    // scrollback) semantics only hold at the geometry they were emitted at.
    // Parsed into a grid with MORE rows, the recorded scrolls never trigger, the
    // replayed content stays on the visible screen, and conhost's post-attach
    // fresh-paint (`ESC[H ESC[2J` + viewport redraw) erases all of it — total
    // scrollback loss (the visible-relaunch bug). So: reflow the local grid to
    // the agent-reported capture geometry first, and have the drain reflow back
    // to the live grid exactly when the replay is fully applied (`applied_bytes`
    // reaches the ring head S carried by ATTACHED). An older agent omits the
    // capture geometry (0) → keep today's live-width replay.
    //
    // T666: this applies to the SNAPSHOT attach path (`attach_offset > 0`) too,
    // and it used to be gated away from it. The gap-fill there is the same raw,
    // geometry-bound ConPTY bytes — only shorter — so at a different live width
    // its in-place redraws overwrite the wrong columns and the pane comes back
    // holding shredded text ("…>SPMKal or external command,MK…C1' is not"). That
    // went unnoticed for as long as the repaint erased it a frame later; parking
    // the screen into scrollback keeps it, so it has to be replayed correctly
    // rather than thrown away. The persisted snapshot is painted AFTER this
    // reflow on purpose: the agent's `replay_*` geometry is the geometry the
    // session had when the app last saved it, which is the geometry that
    // snapshot was captured at, and the reflow back at the boundary re-wraps the
    // restored history and the gap-fill together, in one pass, to the live grid.
    if (!did_relaunch and !did_notify and !self.awaiting_relaunch and
        attach_snapshot_at > 0 and
        attach_replay_cols != 0 and attach_replay_rows != 0 and
        (attach_replay_cols != live_cols or attach_replay_rows != live_rows))
    {
        io.reflowLocalGrid(attach_replay_cols, attach_replay_rows);
        rd.attach_reflow_target = attach_snapshot_at;
    }

    // WP-D3: paint the persisted structured snapshot for an instant, correctly
    // sized frame BEFORE the agent's delta replay lands on top. Applied only on
    // the normal live re-attach path (not a relaunch / awaiting-relaunch, which
    // stream a fresh shell and print their own divider) and only when we
    // attached at a real offset (`attach_offset > 0`), so the snapshot and the
    // agent's `(attach_offset, S]` gap-fill meet exactly with no double-paint.
    // This is our OWN clean VT repaint (palette+modes+styles+cursor+bounded
    // scrollback), NOT the agent's raw in-place-redraw ring, so it reflows to
    // the live width without smearing and parses in well under a frame.
    //
    // `did_notify` (T230) is excluded for the same reason as a relaunch: the
    // pane is running a BRAND-NEW session that shares no byte stream with the
    // snapshot, so painting the old screen under it would be a lie about what
    // the pane is, and the offset bookkeeping the gap-fill depends on does not
    // apply.
    if (!did_relaunch and !did_notify and !self.awaiting_relaunch and self.attach_offset > 0) {
        if (self.restore_snapshot) |snap| {
            if (snap.len > 0) {
                @call(.always_inline, termio.Termio.processOutput, .{ io, snap });

                // T666: the paint we just made sits on the VISIBLE SCREEN, and
                // the next thing the agent sends is a repaint of the session's
                // current viewport that homes to row 1 and erases as it goes
                // (`agent/grid_snapshot.zig`, then ConPTY's own fresh paint
                // behind it). Left where it is, every row of restored history is
                // overwritten — which is why a re-attached pane used to come back
                // holding one screen and nothing above it. Park it into
                // scrollback instead, at the exact offset the repaint starts at
                // so the replay that CONTINUES this screen still lands on it
                // first. Gated on the peer promising that repaint: without one
                // there is nothing coming to fill the viewport we would blank.
                if (rd.conn.peerRepaintsOnAttach()) rd.park_target = attach_snapshot_at;
            }
        }
    }

    // T532, the WRITER half. A relaunch, a notify-policy fresh shell, and a
    // prompt-deferred relaunch all begin a NEW byte stream at 0 — `Connection`
    // arms their panes with `discard_below = 0` for exactly that reason. Our
    // absolute base has to follow, or `appliedOffset()` keeps counting from the
    // DEAD stream's offset and the manifest written from it records a resume
    // point into a stream that no longer exists. That is how a 43 MB offset
    // against a minutes-old agent came to be recorded on 2026-08-06; the clamp
    // in `attachChannel` is the reader's defence against such a record, and
    // this is what stops one being written. Placed after the three blocks above
    // that read `attach_offset` (each already excludes these paths) and before
    // the first drain, which is the first thing to advance `applied_bytes`.
    if (did_relaunch or did_notify or self.awaiting_relaunch) self.attach_offset = 0;

    // A post-attach boundary can be satisfied before a single byte arrives: when
    // the resume point was clamped to the agent's head there is no gap to fill,
    // so the repaint is ALL that is coming. Settle it here rather than leaving
    // the park (and any reflow) waiting on a chunk with nothing below the
    // boundary in it — the drain's own check only runs once it has bytes.
    if (rd.attach_reflow_target > 0 or rd.park_target > 0) {
        if (self.appliedOffset() >= @max(rd.attach_reflow_target, rd.park_target)) {
            finishAttachBoundary(rd);
        }
    }

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
        .{
            .env = self.env,
            .term = self.term,
            .argv = self.command_argv orelse self.argv,
        },
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

/// Whether anything is running under this pane's shell, as the owning agent last
/// reported it (T356) — the cross-machine answer to the question
/// `ProcessTree.hasDescendants` answers locally.
///
/// Null means UNKNOWN and callers must treat it as "cannot skip the
/// confirmation": the agent is older than `capability.session_busy`, or has not
/// sampled this session yet, or — the case worth naming — the LINK IS NOT UP. A
/// value pushed before a disconnect describes a machine we have since stopped
/// hearing from, and its staleness is unbounded; a job could have started on the
/// far side at any point since. So a connection that is not connected reports
/// null rather than its last-known answer.
///
/// Callable from any thread (the GUI reads it in the close path).
pub fn shellHasDescendants(self: *Remote) ?bool {
    if (self.conn.state() != .connected) return null;
    return switch (@as(
        inbound_ring.Channel.BusyState,
        @enumFromInt(self.busy_state.load(.acquire)),
    )) {
        .unknown => null,
        .idle => false,
        .busy => true,
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
    // Likewise the busy answer (T356): a fresh child or a fresh viewer binding
    // makes the previous answer meaningless, and `bindLocked` clears the agent's
    // own record so the current one is re-pushed within a tick. Until then the
    // pane is UNKNOWN, i.e. its close confirms — the safe direction.
    self.busy_state.store(
        @intFromEnum(inbound_ring.Channel.BusyState.unknown),
        .release,
    );

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

/// Everything that happens at the post-attach boundary, in the order it has to
/// happen in: reflow back to the live grid FIRST, so the park then scrolls the
/// restored history at the geometry the user is actually looking at rather than
/// at the replay geometry it was reconstructed under. Either half may be
/// inactive; both clear themselves.
fn finishAttachBoundary(rd: *ThreadData) void {
    if (rd.attach_reflow_target > 0) finishAttachReflow(rd);
    if (rd.park_target > 0) {
        parkRestoredScreen(rd.io);
        rd.park_target = 0;
    }
}

/// T106: the attach replay is fully applied — reflow the local grid from the
/// capture geometry back to the CURRENT live grid (read fresh from the backend,
/// so a user resize that raced the replay wins) and disarm. The authoritative
/// post-attach RESIZE already re-asserted the pty geometry in `threadEnter`, so
/// conhost's repaint of the final viewport follows in the stream and now parses
/// at the matching grid.
fn finishAttachReflow(rd: *ThreadData) void {
    rd.attach_reflow_target = 0;
    const remote = &rd.io.backend.remote;
    const cols: u16 = @intCast(@min(remote.grid_size.columns, std.math.maxInt(u16)));
    const rows: u16 = @intCast(@min(remote.grid_size.rows, std.math.maxInt(u16)));
    rd.io.reflowLocalGrid(cols, rows);
}

/// The most bytes handed to the parser in ONE `processOutputTracked` call, and
/// therefore the most work done in one hold of the pane's renderer mutex (T111).
///
/// The GUI thread takes that same mutex for ordinary interactive work — reading
/// a pane's pwd/title for `+list`, input, focus, resize — so the mutex hold time
/// here IS the GUI's worst-case stall. Local Exec never had to think about this:
/// its reader parses whatever one ConPTY `ReadFile` returned, which the OS hands
/// out in ~4 KiB pieces, so its holds are naturally short. The agent path
/// interposes a 256 KiB inbound ring that COALESCES the stream, so an unsliced
/// drain fed the parser 16 KiB at a time — 4x Exec's granularity, measured at
/// ~330 ms of held-lock parsing per chunk under a storm, which stalled `+list`
/// for 0.3–3.3 s (vs 0.1–0.6 s on Exec under the identical storm).
///
/// Slicing at Exec's natural granularity restores parity: same total parse work,
/// same byte order, just released and re-taken often enough that a GUI waiter
/// gets in. Note this is the OPPOSITE of T62, which BATCHED Exec's tiny writes
/// up to this size — both fixes converge on "one lock cycle per ~4 KiB", from
/// opposite directions.
const max_parse_slice = 4 * 1024;

/// Feed `bytes` to the terminal in `max_parse_slice` pieces, so no single
/// renderer-mutex hold covers more than that. The parser is a streaming state
/// machine and `applied_bytes` advances per slice under the same lock, so the
/// split is invisible to both the terminal and any snapshot reader (WP-D3):
/// slicing only makes the (grid, offset) pair advance in finer steps.
fn feedSliced(rd: *ThreadData, bytes: []const u8) void {
    var it: SliceIter = .{ .rest = bytes };
    while (it.next()) |slice| {
        @call(.always_inline, termio.Termio.processOutputTracked, .{
            rd.io, slice, &rd.io.backend.remote.applied_bytes,
        });
        // T111b/T114/T115: bounding the HOLD (above) is not enough on its own,
        // because nothing bounds how often we re-take it. `processOutputTracked`
        // self-locks and unlocks, and the next iteration re-locks after
        // nothing but a slice-pointer bump — so a GUI thread parked on this
        // same mutex loses race after race rather than one long race. Zig's
        // Mutex is a futex and promises no fairness; Exec never hit this
        // because it has PeekNamedPipe/ReadFile syscalls between its unlock
        // and next lock, which IS the window a parked waiter needs.
        //
        // T111b tried a bare `std.Thread.yield()` here and it was not enough:
        // `SwitchToThread` only yields to a thread already runnable on the
        // SAME processor, so it is a hint, not a handoff — a `+read` still
        // spiked to ~11.9 s and the RENDERER thread (which takes this same
        // mutex once per frame, and is where it notices a stop request) was
        // measured waiting 65392 ms, blocking `+close` for 33 s in its join.
        // So the waiter now announces itself (`lockPriority`) and we keep the
        // mutex UNLOCKED until it is in — a real handoff, bounded so a stream
        // of waiters cannot starve the drain in turn.
        if (it.rest.len > 0) rd.io.renderer_state.yieldToPriorityWaiters();
    }
}

/// The pure half of `feedSliced`: hands out the input in `max_parse_slice`
/// pieces, in order, covering every byte exactly once. Split out so the
/// boundary arithmetic — which must not drop, duplicate, or reorder a byte of
/// terminal output — is unit tested without a live pane.
const SliceIter = struct {
    rest: []const u8,

    fn next(self: *SliceIter) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const n = @min(self.rest.len, max_parse_slice);
        defer self.rest = self.rest[n..];
        return self.rest[0..n];
    }
};

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

/// T666: push the pane's current screen into SCROLLBACK, leaving a blank
/// viewport for the repaint that is about to land on it.
///
/// Called on the pane's IO thread with a restored WP-D3 screen (plus whatever
/// replay continued it) sitting on the visible rows. See `restore_park.zig` for
/// why a repaint would otherwise destroy all of it.
///
/// Two things are deliberately NOT parked. The ALTERNATE screen has no
/// scrollback at all, so line feeds there discard rows instead of saving them —
/// and an alt-screen session's repaint re-enters alt and redraws the whole frame
/// anyway, so there is nothing to protect. And a screen whose geometry reads as
/// zero rows is left alone rather than guessed at.
fn parkRestoredScreen(io: *termio.Termio) void {
    var cup_buf: [restore_park.cup_max_len]u8 = undefined;

    // Read the geometry the paint actually produced. One short hold, on the same
    // mutex `processOutput` takes, so nothing else is mid-parse underneath us.
    io.renderer_state.mutex.lock();
    const on_primary = io.terminal.screens.active_key == .primary;
    const rows = io.terminal.rows;
    const cursor_y = io.terminal.screens.active.cursor.y;
    io.renderer_state.mutex.unlock();

    if (!on_primary) return;
    const p = restore_park.plan(&cup_buf, rows, cursor_y) orelse return;

    @call(.always_inline, termio.Termio.processOutput, .{ io, p.cup });

    // One line feed per occupied row, streamed from a fixed buffer: the count is
    // bounded only by the pane's height, which is not a size to put on the stack.
    var feeds: [64]u8 = @splat('\n');
    var left: usize = p.newlines;
    while (left > 0) {
        const n = @min(left, feeds.len);
        @call(.always_inline, termio.Termio.processOutput, .{ io, feeds[0..n] });
        left -= n;
    }
}

/// `GHOZTTY_RESUME_COUNT_BYTES=1` puts the pre-T739 accounting back: the applied
/// offset is once again "every byte we fed the parser", repaints included.
///
/// A seam rather than a comment because T739's whole claim is the ABSENCE of
/// something — no offset past the agent's head, no clamp warning — and an
/// absence is evidence only when the same harness can be made to see it present.
/// Nothing else changes, so a red arm names this rule and not the weather.
/// Unset in every real launch; read once per pane on its IO thread.
fn countBytesSeam() bool {
    // Atomic tri-state (0 unknown / 1 on / 2 off): every pane has its own IO
    // thread, and they all compute the same answer, but "the same answer" is
    // still a data race if it goes through a plain global.
    const S = struct {
        var cached: std.atomic.Value(u8) = .init(0);
    };
    switch (S.cached.load(.monotonic)) {
        1 => return true,
        2 => return false,
        else => {},
    }
    var buf: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const on = if (std.process.getEnvVarOwned(fba.allocator(), "GHOZTTY_RESUME_COUNT_BYTES")) |v|
        v.len > 0 and !std.mem.eql(u8, v, "0")
    else |err|
        // A value longer than the buffer is still a value: anything but "not
        // set" means the seam is on, so an over-long "1 " cannot read as off.
        err == error.OutOfMemory;
    if (on) log.warn("T739 seam: GHOZTTY_RESUME_COUNT_BYTES — counting repaint bytes as stream position", .{});
    S.cached.store(if (on) 1 else 2, .monotonic);
    return on;
}

/// T739: take the connection's absolute stream position as OUR applied position,
/// having just proved (an empty pop after reading it) that every byte behind it
/// is parsed.
///
/// This is what keeps the persisted resume point off the end of the agent's
/// stream. `applied_bytes` counts every byte fed to the parser, and two of the
/// things the agent sends on ATTACH are not stream bytes at all — its
/// scrollback-lost marker and its grid-snapshot repaint — so counting them put
/// the recorded offset past the agent's head by exactly the repaint's size on
/// EVERY re-attach. The next attach was then clamped back to the head (T532) and
/// whatever real output sat between the two was never replayed. The connection
/// derives its position from the frames' own anchors and the `data_repaint`
/// framing, so it is right where counting cannot be.
///
/// A position BELOW our base is not this stream's (a relaunch resets
/// `attach_offset` to 0 while a stale value could still be in flight), and is
/// ignored rather than rebased onto — the offset must never walk backwards into
/// history the pane has already shown.
///
/// Taken under the renderer mutex so a WP-D3 snapshot reader keeps seeing a
/// consistent (grid, offset) pair, exactly as `processOutputTracked` does.
fn adoptStreamPos(rd: *ThreadData, pos: u64) void {
    if (countBytesSeam()) return;
    const remote = &rd.io.backend.remote;
    if (pos < remote.attach_offset) return;
    // Rare and interesting: the only thing that makes these differ is bytes we
    // were fed that are not the session's stream, so a line here names the
    // repaint the agent injected and the size of the error it would have been.
    const before = remote.appliedOffset();
    if (before != pos) log.info(
        "resume offset corrected: counted={d} stream={d} (delta {d})",
        .{ before, pos, @as(i64, @intCast(before)) - @as(i64, @intCast(pos)) },
    );
    rd.io.renderer_state.mutex.lock();
    defer rd.io.renderer_state.mutex.unlock();
    remote.applied_bytes.store(pos - remote.attach_offset, .monotonic);
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
        // T115: the surface is being torn down and the GUI thread is already
        // blocked in `io_thr.join()` waiting for us to return to the loop and
        // see the stop. Parsing the rest of a flooded ring into a terminal
        // that is about to be freed buys the user nothing and costs them a
        // frozen window: a full wake is up to 32 x 16 KiB of held-lock parse
        // (~7.7 s in the debug build), which is most of T63's 10 s close
        // bound. Bail immediately instead — same precedent as the EXIT
        // notification below, which is likewise dropped once `closing` is set.
        if (rd.io.closing.load(.acquire)) return;

        // T739: the connection's authoritative stream position, read BEFORE the
        // pop. If that pop comes up empty, everything the connection had handed
        // to the ring at the moment of this read has already been applied — so
        // adopting the position is exact, with no window in which we could claim
        // bytes we have not parsed. Read after the pop instead and a push landing
        // in between would be claimed unapplied.
        const stream_pos = rd.pane.streamPos();
        const res = ch.pop(&buf);
        if (res.read == 0) {
            adoptStreamPos(rd, stream_pos);
            break;
        }

        // T423: the child's first bytes are in hand and nothing else can run on
        // this thread before we parse them, so this is the last — and the only
        // guaranteed — moment to put the session-interrupted notice above the
        // viewport. No-op unless a notice is pending.
        rd.io.settleNotice();

        // WP-D3: feed via the tracked path so `applied_bytes` advances under the
        // renderer mutex in lockstep with the parse — a snapshot reader then sees
        // a consistent (grid, offset) pair. This counts every byte fed to the
        // terminal (the agent's `(attach_offset, S]` gap-fill and then live DATA),
        // so `appliedOffset()` tracks the true absolute stream position.
        //
        // T106: while an attach-replay reflow is pending, everything at/below
        // `attach_reflow_target` must parse at the capture geometry and
        // everything above it (conhost's post-attach repaint + live output) at
        // the live grid — so a chunk that straddles the boundary is split and
        // the reflow-back runs exactly at the boundary.
        var chunk: []const u8 = buf[0..res.read];

        // The post-attach boundary: the absolute offset where our replay of the
        // stream the pane ALREADY had ends and the agent's repaint of the
        // session's CURRENT screen begins. Two things fire there — the T106
        // reflow back to the live grid, and the T666 park of the restored screen
        // into scrollback — and both are anchored at the same offset, so they
        // share one split of a straddling chunk. A chunk can hold both sides of
        // it (the boundary is a byte offset, not a frame), and feeding the head
        // twice would double-paint it.
        const boundary = @max(rd.attach_reflow_target, rd.park_target);
        if (boundary > 0) {
            const applied = rd.io.backend.remote.appliedOffset();
            if (applied >= boundary) {
                finishAttachBoundary(rd);
            } else if (applied + chunk.len > boundary) {
                const head: usize = @intCast(boundary - applied);
                feedSliced(rd, chunk[0..head]);
                finishAttachBoundary(rd);
                chunk = chunk[head..];
            }
        }
        if (chunk.len > 0) feedSliced(rd, chunk);

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

    // Same republish for the agent's "is anything running under this shell?"
    // answer (T356), signalled on the ring by the control reader. `.unknown` is
    // never republished: it only means the agent has not told us, and stamping
    // it would erase a real answer we already hold.
    const busy = ch.busyState();
    if (busy != .unknown) {
        rd.io.backend.remote.busy_state.store(@intFromEnum(busy), .release);
    }

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

    /// T106 geometry-faithful attach replay: nonzero while the local grid is
    /// reflowed to the agent-reported capture geometry so the raw ring replay
    /// lands correctly. Holds the absolute stream offset of the replay's end
    /// (ATTACHED's `snapshot_at_offset`); once `applied_bytes` reaches it the
    /// drain reflows back to the live grid and clears this. Set on BOTH attach
    /// paths since T666 — the snapshot path's gap-fill is the same geometry-bound
    /// ConPTY bytes as the full ring's — so it is compared against
    /// `appliedOffset()` (absolute), never against `applied_bytes`, which is only
    /// the same number when `attach_offset` is 0. Touched only on the pane's IO
    /// thread.
    attach_reflow_target: u64 = 0,

    /// T666: nonzero while a restored WP-D3 screen is still waiting to be parked
    /// into scrollback. Holds the absolute stream offset the agent will repaint
    /// at (ATTACHED's `snapshot_at_offset`) — the boundary between the replay
    /// that continues our restored screen and the repaint that would overwrite
    /// it. When the drain reaches that offset it emits the park and clears this.
    /// Only ever set on the snapshot attach path (`attach_offset > 0`) with a
    /// peer that promises the repaint. Touched only on the pane's IO thread.
    park_target: u64 = 0,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;
        // The pane/ring were already torn down by `threadExit` (`detachChannel`).
        // The connection is caller-owned. We only own the async handle here.
        self.ring_async.deinit();
        self.* = undefined;
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "T111 slice iter: covers the input exactly, in order, bounded pieces" {
    const testing = std.testing;

    // Deliberately not a multiple of the slice size: the tail piece is the
    // easiest one to get wrong.
    var buf: [max_parse_slice * 2 + 7]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i);

    var it: SliceIter = .{ .rest = &buf };
    var seen: usize = 0;
    var pieces: usize = 0;
    while (it.next()) |slice| {
        try testing.expect(slice.len > 0);
        try testing.expect(slice.len <= max_parse_slice);
        // Same bytes, same order, at the expected offset.
        try testing.expectEqualSlices(u8, buf[seen..][0..slice.len], slice);
        seen += slice.len;
        pieces += 1;
    }
    try testing.expectEqual(buf.len, seen);
    try testing.expectEqual(@as(usize, 3), pieces);
}

test "T111 slice iter: sub-slice input is one piece, empty input is none" {
    const testing = std.testing;

    var one: SliceIter = .{ .rest = "hello" };
    try testing.expectEqualStrings("hello", one.next().?);
    try testing.expectEqual(@as(?[]const u8, null), one.next());

    var none: SliceIter = .{ .rest = "" };
    try testing.expectEqual(@as(?[]const u8, null), none.next());
}

test "T111 slice iter: exact multiple yields no empty trailing piece" {
    const testing = std.testing;

    var buf: [max_parse_slice * 2]u8 = undefined;
    @memset(&buf, 'z');
    var it: SliceIter = .{ .rest = &buf };
    var pieces: usize = 0;
    while (it.next()) |slice| {
        try testing.expectEqual(max_parse_slice, slice.len);
        pieces += 1;
    }
    try testing.expectEqual(@as(usize, 2), pieces);
}

test "T111 slice bound stays at or under the drain buffer it slices" {
    // drainRing pops into a 16 KiB buffer; a slice larger than that would be
    // dead code and would silently re-widen the mutex hold this bounds.
    try std.testing.expect(max_parse_slice <= 16 * 1024);
    try std.testing.expect(max_parse_slice > 0);
}

test "T144 openWorkingDirectory: local agent falls back to the local resolved cwd" {
    const testing = std.testing;

    // A fresh local-agent window: no explicit remote cwd, but the surface
    // config resolved one (home, or the focused pane's pwd). It must be
    // forwarded — otherwise the agent spawns the child in its OWN cwd, which
    // on the win32 autostart path is C:\WINDOWS\system32.
    try testing.expectEqualStrings(
        "C:\\Users\\dave",
        openWorkingDirectory(null, "C:\\Users\\dave", true).?,
    );
}

test "T144 openWorkingDirectory: cross-machine never forwards a local path" {
    const testing = std.testing;

    // The local path may not exist on the remote OS; forwarding it wedges the
    // OPEN. Null means "the agent picks its own default".
    try testing.expect(openWorkingDirectory(null, "C:\\Users\\dave", false) == null);
}

test "T144 openWorkingDirectory: an explicit remote cwd always wins" {
    const testing = std.testing;

    // Tab/split inheritance (the parent pane's live cwd) and IPC
    // --working-directory both arrive as `explicit`, on either agent flavor.
    try testing.expectEqualStrings(
        "/work/ghoztty",
        openWorkingDirectory("/work/ghoztty", "C:\\Users\\dave", true).?,
    );
    try testing.expectEqualStrings(
        "/work/ghoztty",
        openWorkingDirectory("/work/ghoztty", "C:\\Users\\dave", false).?,
    );
}

test "T144 openWorkingDirectory: nothing to forward stays null" {
    const testing = std.testing;

    // `working-directory = inherit` resolves to null; the agent's default is
    // then the only answer either flavor can give.
    try testing.expect(openWorkingDirectory(null, null, true) == null);
    try testing.expect(openWorkingDirectory(null, null, false) == null);
}

test "T657 every ATTACHED status that yields no pane maps to its own sentence" {
    const testing = std.testing;

    // The coupling this pins: `attach_failed_notice` is deliberately free of
    // the protocol import and matches STATUS TAG NAMES as strings, so a rename
    // of `AttachStatus` would not break the build — it would silently degrade
    // every restore failure to the generic "does not recognize the reason"
    // sentence. This is the one place both sides are in scope, so it is where
    // that has to be caught.
    const S = protocol.Attached.AttachStatus;
    const reason = attach_failed_notice.reason;
    try testing.expectEqualStrings(
        reason.session_not_found,
        attach_failed_notice.reasonForStatus(@tagName(S.not_found), false),
    );
    try testing.expectEqualStrings(
        reason.session_ended,
        attach_failed_notice.reasonForStatus(@tagName(S.dead), false),
    );
    // A steal reply carries `.alive`, so the elsewhere flag has to win.
    try testing.expectEqualStrings(
        reason.attached_elsewhere,
        attach_failed_notice.reasonForStatus(@tagName(S.alive), true),
    );

    // ...and each of those renders a DIFFERENT message, or the status carries
    // no information to the person reading the pane.
    var a: [attach_failed_notice.max_len]u8 = undefined;
    var b: [attach_failed_notice.max_len]u8 = undefined;
    const missing = attach_failed_notice.format(&a, reason.session_not_found, null);
    const ended = attach_failed_notice.format(&b, reason.session_ended, null);
    try testing.expect(!std.mem.eql(u8, missing, ended));
}
