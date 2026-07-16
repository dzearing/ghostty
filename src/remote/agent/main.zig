//! `ghoztty-agent` entry point (WP2, §4.1–§4.2/§7.1) — the remote-host daemon.
//!
//! Four transport modes share the SAME session-server core (`server.zig`, real
//! pty-backed children via `pty_child.zig`) and the SAME lane mux (`mux.zig`):
//!
//!   1. **stdio** (`--stdio`, or the default when stdin is not a tty / no listen
//!      addr): read framed protocol from stdin, write to stdout. This is the
//!      `ssh host -- ghoztty-agent` path (§4.1). One stdin/stdout pipe pair, both
//!      logical lanes muxed onto it. Shuts down on stdin EOF (client hung up).
//!
//!   2. **TCP listen daemon** (`--listen <addr:port>`, loopback by default;
//!      non-loopback needs `--insecure-allow-public`): bind, listen, then loop —
//!      accept a connection and serve it on its OWN thread (a `Mux` + `Server`
//!      over the socket, sharing the daemon-scoped session store), so the accept
//!      loop NEVER blocks on one connection's lifecycle. UNAUTHENTICATED — a
//!      local/dev harness only (the authenticated path is `--relay`).
//!
//!   2b. **Unix-socket listen daemon** (`--listen-unix <path>`, POSIX-only): the
//!      SECURE local transport for session persistence (design §5.2). Same
//!      accept→serve→loop core as the TCP path, but bound to a 0600 AF_UNIX
//!      socket (created that way race-free via umask) and gated with a
//!      per-connection `getpeereid` same-uid check — so, unlike a 127.0.0.1 TCP
//!      port that ANY local uid can connect to, only this user can reach the
//!      shell. A stale socket node from a prior run is unlinked only after a
//!      connect-probe confirms nothing live is listening. This is what the macOS
//!      app spawns for local persistent windows (Windows uses a named pipe).
//!
//!   3. **Relay daemon** (`--relay <url>`): the single-binary rendezvous path (no
//!      Go sidecar, no inbound port). Hold an authenticated `wss://` control
//!      WebSocket to the relay; on each `{"type":"open","session":S}` command,
//!      dial a per-session data WebSocket and serve it over the SAME `serveOne`
//!      core (shared store) as an accepted socket. The device token is read from
//!      `GHOSTTY_DEVICE_TOKEN`, falling back to the agent's persisted
//!      `relay.env` (see `enroll.zig`); relay.env is then WATCHED so a
//!      re-enroll's new token is adopted without a restart (`relay_creds.zig`).
//!      With NO credential anywhere, an interactive (non-`--headless`) launch
//!      runs the browser enrollment INLINE on first run and then continues into
//!      the connect loop — the MSI Start-Menu / Run-key launch is exactly
//!      `ghoztty-agent --relay=<base>` (see `decideRelayCred`); `--headless`
//!      keeps the explicit "run --enroll first" error.
//!      Reconnects with backoff on a control
//!      drop (sessions survive). Coexists with — does not replace — `--listen`.
//!
//! Plus one one-shot utility mode: `--enroll --relay <url>` runs the OAuth
//! self-enrollment (`enroll.zig`) — opens the owner's browser to approve the
//! sign-in (Tailscale-style), falling back to the device-code "visit URL,
//! enter code" flow when the relay offers no web client or
//! `--no-browser`/`--headless-enroll` is passed — and persists the issued
//! device credential to `relay.env`, after which `--relay <url>` just works.
//!
//! ### SESSION SURVIVAL (P1, §7.1) — the close-laptop scenario
//! The session table + pty children + output rings live in a DAEMON-scoped
//! `SessionStore` that OUTLIVES any connection. When a client disconnects, its
//! per-connection `Server` is torn down but its sessions are merely DETACHed
//! (output keeps flowing into their rings); they are NEVER terminated on a mere
//! drop. A reconnecting client `ATTACH`es by session id with its last byte offset,
//! and the agent replays the ring gap `(last_byte_offset, S]` — catching the client
//! up to everything the remote produced while it was gone — then resumes live
//! streaming. Orphaned sessions are reaped by a background idle-TTL thread
//! (`session.default_idle_ttl_ms`, 24 h — long enough to survive a closed
//! laptop lid overnight) so abandoned shells don't leak forever.
//!
//! ### SECURITY
//! The `--relay` path is authenticated end to end (per-device bearer token, and
//! the relay enforces account ownership). The `--relay` mode is the ONLY way a
//! customer install brings a machine online (the MSI/installer autostart it with
//! `--relay=<url>`).
//!
//! The TCP `--listen` path is **unauthenticated**: any host that can reach the
//! port can open a shell. It exists for local/dev use only and is guarded:
//!   - a bare invocation (no args) does NOT listen — it prints usage and exits;
//!   - `--listen` may bind loopback (`127.0.0.1`/`::1`) freely;
//!   - binding a NON-loopback interface requires the explicit
//!     `--insecure-allow-public` opt-in and prints a loud warning.
//! So an unauthenticated shell can never be exposed to the network by accident.
//!
//! The `--listen-unix` path is the hardened LOCAL alternative: a filesystem
//! socket is never network-reachable, is created 0600 (no group/other access),
//! AND every accepted connection is admitted only if `getpeereid` reports the
//! peer's uid equals ours (an unreadable credential is rejected — a shell is
//! never served to an unauthenticated peer). This is the transport the app uses
//! for local session persistence.
//!
//! ## Transport over a single byte channel
//! The wire design (§4.3) uses two logical lanes — control + data, each a
//! `server.Stream`. Both modes have only ONE underlying byte channel (a pipe pair
//! or a socket), so `mux.Mux` folds both lanes onto it (DATA → data lane, else →
//! control lane). The `Server`'s two reader threads consume their lanes unchanged.
//!
//! ## Deferred (this increment)
//!   - A real grid-model snapshot on ATTACH (§7.3): `snapshot_at_offset` is the
//!     current outbound offset and resync replays the raw ring from there. Exact-
//!     grid reconstruction (so deep-scrollback eviction is invisible) is future.
//!   - Authentication / TLS on the listener (see SECURITY above).
//!   - Daemonization / detach (§4.1). (Single-instance IS enforced: the daemon
//!     modes `--listen`/`--relay` take a per-USER guard — Global\ named mutex
//!     keyed by SID on Windows, flock on POSIX — and a losing instance exits
//!     with code 183 after verifying the holder is alive via its heartbeat
//!     file; a stuck holder is killed and replaced, and `--force-replace`
//!     (alias `--replace`) replaces even a healthy one. See
//!     `single_instance.zig`. `--stdio` and `--enroll` are exempt.)
//!   - RPC, tunnels, multi-client fan-out to one session (§5.3 steal).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const protocol = @import("../protocol.zig");
const server = @import("server.zig");
const session = @import("session.zig");
const pty_child = @import("pty_child.zig");
const mux_mod = @import("mux.zig");
const socket_stream = @import("../socket_stream.zig");
const ws_client = @import("../ws_client.zig");
const tray = @import("tray.zig");
const tray_account = @import("tray_account.zig");
const enroll = @import("enroll.zig");
const keepalive = @import("keepalive.zig");
const link_control = @import("link_control.zig");
const relay_creds = @import("relay_creds.zig");
const self_update = @import("self_update.zig");
const single_instance = @import("single_instance.zig");

/// The agent's baked build version: `YYYYMMDD-<git short hash>` (commit date),
/// or `"dev"` when git was unavailable at build time. Stamped by
/// `src/build/GhosttyAgent.zig` through the `agent_build_options` module
/// (`-Dagent-version=` overrides). Shown by `--version`, the startup banners,
/// and the tray About line, and compared against the relay's
/// `/dl/version.json` by the self-updater (`self_update.zig`) — dev builds
/// never self-update.
const agent_version: []const u8 = @import("agent_build_options").agent_version;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // The transfer encoding is fixed at construction (the client pins it in HELLO).
    // Default to raw; `GHOZTTY_AGENT_ENCODING` overrides it (deterministic tests).
    const encoding = encodingFromEnv(alloc);

    const mode = try parseArgs(alloc);
    switch (mode) {
        .version => {
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "ghoztty-agent {s}\n", .{agent_version}) catch "ghoztty-agent\n";
            std.fs.File.stdout().writeAll(line) catch {};
        },
        .usage => printUsage(),
        .stdio => try runStdio(alloc, encoding),
        .listen => |l| {
            // Keep the GPA exit clean on the (error) paths where runListen returns.
            defer if (l.port_file) |pf| alloc.free(pf);
            // DAEMON mode: enforce single-instance BEFORE anything user-visible
            // (bind, banner, tray icon). Exits the process on conflict.
            var lock = acquireDaemonLockOrExit(alloc, l.force_replace);
            defer lock.release();
            try runListen(alloc, encoding, l.addr, l.headless, l.public, l.port_file);
        },
        .listen_unix => |l| {
            defer alloc.free(l.path);
            // DAEMON mode: single-instance BEFORE the bind (a losing instance
            // must not clobber the winner's socket node).
            var lock = acquireDaemonLockOrExit(alloc, l.force_replace);
            defer lock.release();
            try runListenUnix(alloc, encoding, l.path, l.headless);
        },
        .relay => |r| {
            // DAEMON mode: single-instance first (before the token lookup, long
            // before the tray could flash an icon — and before a first-run
            // auto-enroll could pop a browser from a doomed duplicate).
            var lock = acquireDaemonLockOrExit(alloc, r.force_replace);
            defer lock.release();
            // The device token authenticates the relay WebSockets. Required.
            // Precedence: the GHOSTTY_DEVICE_TOKEN env var wins; otherwise fall
            // back to the agent's own relay.env (written by `--enroll` and by
            // the Windows installer), so enroll → run needs no env plumbing.
            // With NO credential anywhere the policy is `decideRelayCred`'s:
            // interactive launches self-enroll inline, `--headless` errors.
            // The SOURCE travels along: a relay.env sourced token may be hot-
            // reloaded on a re-enroll, an env-sourced one never is (see
            // `relay_creds.zig`).
            const TokenInit = struct { token: []u8, source: relay_creds.Source };
            const env_token: ?[]u8 = std.process.getEnvVarOwned(alloc, "GHOSTTY_DEVICE_TOKEN") catch null;
            const file_token: ?[]u8 = if (env_token == null) enroll.loadDeviceToken(alloc) else null;
            const ti: TokenInit = switch (decideRelayCred(env_token != null, file_token != null, r.headless)) {
                .use_env => .{ .token = env_token.?, .source = .env },
                .use_relay_env => .{ .token = file_token.?, .source = .relay_env },
                .fail => {
                    std.debug.print(
                        "ghoztty-agent: --relay needs a device token: set GHOSTTY_DEVICE_TOKEN " ++
                            "or enroll this machine first with `ghoztty-agent --enroll --relay=<base>`\n",
                        .{},
                    );
                    // This relay-mode path returns (runRelay loops forever),
                    // so free the duped URL to keep the GPA exit clean.
                    alloc.free(r.base_url);
                    return error.MissingDeviceToken;
                },
                .auto_enroll => blk: {
                    const t = autoEnrollForRelay(alloc, r.base_url) catch |err| {
                        alloc.free(r.base_url); // keep the GPA exit clean, as above
                        return err;
                    };
                    break :blk .{ .token = t, .source = .relay_env };
                },
            };
            // Token ownership moves into runRelay's `Creds` (it must stay
            // alive as long as any connection borrows a snapshot of it).
            try runRelay(alloc, encoding, r.base_url, ti.token, ti.source, r.headless);
        },
        .enroll => |e| {
            // Self-enroll (browser-first, device-code fallback): register this
            // machine (by its hostname) under the owner's account and persist
            // the credential. Unlike relay mode this returns, so the duped URL
            // is freed.
            defer alloc.free(e.base_url);
            var host_buf: [256]u8 = undefined;
            const name = hostName(&host_buf) orelse "unknown-host";
            try enroll.run(alloc, e.base_url, name, .{ .no_browser = e.no_browser });
        },
    }
}

/// The held daemon single-instance state: the guard itself plus the liveness
/// heartbeat a future challenger consults (see `single_instance` §Takeover).
/// `release` matters only on main's error-return paths — production daemons
/// hold both until the process dies.
const DaemonLock = struct {
    guard: ?single_instance.Guard,
    heartbeat: ?*single_instance.Heartbeat,

    fn release(self: *DaemonLock) void {
        if (self.heartbeat) |hb| hb.stopAndFree();
        if (self.guard) |*g| g.release();
        self.* = .{ .guard = null, .heartbeat = null };
    }
};

/// Take the per-user daemon single-instance guard (named mutex on Windows,
/// flock on POSIX — see `single_instance.zig`), running the TAKEOVER protocol
/// on contention: a responsive holder wins (we exit 183), a stuck one — or
/// any holder, under `--force-replace` — is killed and replaced. Outcomes:
///   - acquired (possibly after a takeover) → return the lock; the heartbeat
///     ticker is started so future challengers can tell us from a corpse.
///   - holder alive / not safely replaceable → log + exit with
///     `single_instance.already_running_exit_code` (183). The message +
///     distinct code make a supervisor's respawn-and-exit loop
///     self-explanatory in its captured stderr log.
///   - guard infrastructure failed → log a warning and return an empty lock:
///     the daemon serves anyway (availability beats guard integrity, same
///     policy as tray failures).
/// Called BEFORE any user-visible daemon setup (bind / banner / tray icon), so
/// a losing instance never flashes a tray icon or steals the port.
fn acquireDaemonLockOrExit(alloc: Allocator, force_replace: bool) DaemonLock {
    const guard = single_instance.acquireWithTakeover(alloc, force_replace) catch |err| switch (err) {
        error.AlreadyRunning => {
            // std.debug.print writes stderr, which the supervisors (installer
            // launcher / deploy watcher) redirect to agent.err.log — visible
            // even though the Windows agent is a GUI-subsystem exe.
            std.debug.print("ghoztty-agent: another instance is already running; exiting\n", .{});
            std.process.exit(single_instance.already_running_exit_code);
        },
        error.GuardUnavailable => {
            std.debug.print("ghoztty-agent: warning: single-instance guard unavailable; continuing without it\n", .{});
            return .{ .guard = null, .heartbeat = null };
        },
    };
    // We are THE daemon: announce liveness. A heartbeat failure only costs
    // challenger-side takeover diagnostics, never the daemon.
    return .{ .guard = guard, .heartbeat = single_instance.Heartbeat.start(alloc) };
}

/// How relay-daemon startup obtains its device credential — a PURE decision
/// seam so the policy is unit-testable without env vars or files. Precedence:
/// `GHOSTTY_DEVICE_TOKEN` > relay.env. With NO credential anywhere an
/// INTERACTIVE launch self-enrolls inline (the MSI Start-Menu / Run-key launch
/// is exactly `ghoztty-agent --relay=<base>`, so the first run must bootstrap
/// itself), while `--headless` keeps the explicit error — a headless box has
/// no browser to pop; enroll it deliberately with `--enroll --no-browser`.
const RelayCredDecision = enum { use_env, use_relay_env, auto_enroll, fail };

fn decideRelayCred(has_env_token: bool, has_relay_env_token: bool, headless: bool) RelayCredDecision {
    if (has_env_token) return .use_env;
    if (has_relay_env_token) return .use_relay_env;
    return if (headless) .fail else .auto_enroll;
}

/// FIRST-RUN self-enrollment for interactive relay mode: no credential exists,
/// so run the normal `--enroll` flow inline (browser-first with device-code
/// fallback — `enroll.run`, reused unchanged) and return the freshly persisted
/// relay.env token; the caller then continues straight into the connect loop
/// (no re-exec). On failure (denied / expired / relay unreachable) this logs,
/// surfaces a Windows message box (see `surfaceEnrollFailure`), and errors out
/// so the daemon exits NONZERO: the installer's Run key retries at the next
/// logon — we never loop re-opening browsers.
fn autoEnrollForRelay(alloc: Allocator, base_url: []const u8) ![]u8 {
    std.debug.print("ghoztty-agent: no device credential; starting first-run browser enrollment with {s}\n", .{base_url});
    var host_buf: [256]u8 = undefined;
    const name = hostName(&host_buf) orelse "unknown-host";
    enroll.run(alloc, base_url, name, .{}) catch |err| {
        std.debug.print("ghoztty-agent: first-run enrollment failed ({s}); not starting the relay daemon\n", .{@errorName(err)});
        surfaceEnrollFailure(err);
        return err;
    };
    return enroll.loadDeviceToken(alloc) orelse {
        // Enroll claimed success but relay.env holds no token (racing delete,
        // unwritable dir surfaced late, ...): treat exactly like a failure.
        std.debug.print("ghoztty-agent: enrollment finished but relay.env holds no device token\n", .{});
        surfaceEnrollFailure(error.MissingDeviceToken);
        return error.MissingDeviceToken;
    };
}

/// Windows-only user-visible surface for a first-run enrollment failure: a
/// plain error message box. At this point NO tray icon exists yet (the tray
/// starts with the connect loop, which we never reach) and the GUI-subsystem
/// exe launched from the Start Menu / Run key has no console for stderr, so a
/// box is the only thing the user can see. No-op elsewhere; headless never
/// reaches here (`decideRelayCred` fails headless launches without enrolling).
fn surfaceEnrollFailure(err: anyerror) void {
    if (builtin.os.tag != .windows) return;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "First-run enrollment failed ({s}).\n\nThe agent will retry at the next launch, or enroll manually with:\nghoztty-agent --enroll --relay=<base>",
        .{@errorName(err)},
    ) catch "First-run enrollment failed.";
    tray.showStartupError(msg);
}

fn encodingFromEnv(alloc: Allocator) protocol.TransferEncoding {
    const v = std.process.getEnvVarOwned(alloc, "GHOZTTY_AGENT_ENCODING") catch return .raw;
    defer alloc.free(v);
    if (std.ascii.eqlIgnoreCase(v, "cobs")) return .cobs;
    if (std.ascii.eqlIgnoreCase(v, "base64")) return .base64;
    return .raw;
}

const Mode = union(enum) {
    /// `--version`: print the baked build version and exit.
    version,
    /// No recognized mode (bare invocation): print usage and exit cleanly —
    /// deliberately NOT an unauthenticated listener (see the SECURITY note).
    usage,
    stdio,
    listen: Listen,
    listen_unix: ListenUnix,
    relay: Relay,
    enroll: Enroll,
};

/// Self-enroll parameters (`--enroll --relay=<base>`). `base_url` is the
/// relay HTTP(S) base to enroll against (owned — duped from argv).
/// `no_browser` (`--no-browser` / `--headless-enroll`) skips the browser flow
/// and uses the device-code flow directly.
const Enroll = struct {
    base_url: []const u8,
    no_browser: bool = false,
};

/// Relay-mode parameters. `base_url` is the relay HTTPS/WSS base (owned — duped
/// from argv so it outlives `argsFree`). `headless` suppresses the Windows tray.
/// `force_replace` (`--force-replace`/`--replace`) kills a live single-instance
/// holder instead of yielding to it.
const Relay = struct {
    base_url: []const u8,
    headless: bool = false,
    force_replace: bool = false,
};

/// TCP listen-daemon parameters. `headless` suppresses the Windows system-tray
/// icon (for CI / non-interactive runs); the default (tray ON) is what the deploy
/// watcher uses so the human running the Windows box gets a visible daemon handle.
const Listen = struct {
    addr: std.net.Address,
    headless: bool = false,
    force_replace: bool = false,
    /// True when `addr` is a non-loopback interface (only reachable via the
    /// explicit `--insecure-allow-public` opt-in) — drives a runtime warning.
    public: bool = false,
    /// `--port-file=<path>`: after the listener binds, atomically write a JSON
    /// file `{"port":N,"pid":P,"startedAt":MS}` so a supervisor that spawned us
    /// with `--listen=127.0.0.1:0` (ephemeral port) can discover the bound
    /// port. Owned (duped from argv).
    port_file: ?[]const u8 = null,
};

/// Unix-domain-socket listen-daemon parameters (`--listen-unix=<path>`). The
/// SECURE local transport (design §5.2): a 0600 socket node + a per-connection
/// `LOCAL_PEERCRED`/`SO_PEERCRED` same-uid gate means — unlike a 127.0.0.1 TCP
/// port, which ANY local uid can connect to — only this user can reach the
/// shell. POSIX-only (Windows local persistence uses a named pipe later, §5.2).
/// `headless`/`force_replace` mirror `Listen`; there is no public/loopback
/// distinction (a filesystem socket is never network-reachable).
const ListenUnix = struct {
    /// Filesystem path to bind the AF_UNIX stream socket at (owned — duped from
    /// argv so it outlives `argsFree`).
    path: []const u8,
    headless: bool = false,
    force_replace: bool = false,
};

/// Opt-in required to bind `--listen` to a NON-loopback interface. The TCP
/// listener is unauthenticated (see the SECURITY note), so binding it to a
/// routable address exposes a shell to the network; we refuse to do that
/// unless the operator explicitly accepts the risk with this flag.
const allow_public_flag = "--insecure-allow-public";

/// Parse `--version` | `--stdio` | `--listen <addr:port>` | `--relay <url>` |
/// `--enroll --relay <url>` | (no args ⇒ default TCP listen).
/// `--headless` (anywhere on the line) suppresses the tray for listen mode; the
/// stdio path is ALWAYS headless (an ssh-piped agent has no desktop to draw on).
/// `--enroll` (anywhere on the line) turns the `--relay` base into a one-shot
/// enrollment instead of the relay daemon; `--no-browser`/`--headless-enroll`
/// makes that enrollment use the device-code flow instead of the browser.
/// `--force-replace` (alias `--replace`, daemon modes) makes THIS launch win
/// the single-instance guard: the current holder is killed and replaced even
/// if it is alive and responsive (see `single_instance.zig` §Takeover).
fn parseArgs(alloc: Allocator) !Mode {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // Pre-scan for the order-independent flags so they can appear before OR
    // after the mode argument they modify.
    var headless = false;
    var want_enroll = false;
    var no_browser = false;
    var force_replace = false;
    var allow_public = false;
    var port_file_arg: ?[]const u8 = null;
    {
        var j: usize = 1;
        while (j < args.len) : (j += 1) {
            const a = args[j];
            if (std.mem.eql(u8, a, "--headless")) headless = true;
            if (std.mem.eql(u8, a, "--enroll")) want_enroll = true;
            if (std.mem.eql(u8, a, "--no-browser") or
                std.mem.eql(u8, a, "--headless-enroll")) no_browser = true;
            if (std.mem.eql(u8, a, "--force-replace") or
                std.mem.eql(u8, a, "--replace")) force_replace = true;
            if (std.mem.eql(u8, a, allow_public_flag)) allow_public = true;
            if (std.mem.eql(u8, a, "--port-file")) {
                j += 1;
                if (j >= args.len) {
                    std.debug.print("ghoztty-agent: --port-file requires <path>\n", .{});
                    return error.InvalidArgs;
                }
                port_file_arg = args[j];
            } else if (std.mem.startsWith(u8, a, "--port-file=")) {
                port_file_arg = a["--port-file=".len..];
            }
        }
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--headless") or std.mem.eql(u8, a, "--enroll") or
            std.mem.eql(u8, a, "--no-browser") or std.mem.eql(u8, a, "--headless-enroll") or
            std.mem.eql(u8, a, "--force-replace") or std.mem.eql(u8, a, "--replace") or
            std.mem.eql(u8, a, allow_public_flag) or
            std.mem.startsWith(u8, a, "--port-file="))
        {
            continue; // handled in the pre-scan above
        } else if (std.mem.eql(u8, a, "--port-file")) {
            i += 1; // value consumed in the pre-scan above
            continue;
        } else if (std.mem.eql(u8, a, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return .usage;
        } else if (std.mem.eql(u8, a, "--stdio")) {
            return .stdio;
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ghoztty-agent: --listen requires <addr:port>\n", .{});
                return error.InvalidArgs;
            }
            return listenMode(alloc, try parseAddr(args[i]), headless, force_replace, allow_public, port_file_arg);
        } else if (std.mem.startsWith(u8, a, "--listen=")) {
            return listenMode(alloc, try parseAddr(a["--listen=".len..]), headless, force_replace, allow_public, port_file_arg);
        } else if (std.mem.eql(u8, a, "--listen-unix")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ghoztty-agent: --listen-unix requires <path>\n", .{});
                return error.InvalidArgs;
            }
            return listenUnixMode(alloc, args[i], headless, force_replace);
        } else if (std.mem.startsWith(u8, a, "--listen-unix=")) {
            return listenUnixMode(alloc, a["--listen-unix=".len..], headless, force_replace);
        } else if (std.mem.eql(u8, a, "--relay")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ghoztty-agent: --relay requires <url>\n", .{});
                return error.InvalidArgs;
            }
            // Dupe the URL: `args` is freed (argsFree) when parseArgs returns, but
            // both relay and enroll modes need it past that.
            const url = try alloc.dupe(u8, args[i]);
            if (want_enroll) return .{ .enroll = .{ .base_url = url, .no_browser = no_browser } };
            return .{ .relay = .{ .base_url = url, .headless = headless, .force_replace = force_replace } };
        } else if (std.mem.startsWith(u8, a, "--relay=")) {
            const url = try alloc.dupe(u8, a["--relay=".len..]);
            if (want_enroll) return .{ .enroll = .{ .base_url = url, .no_browser = no_browser } };
            return .{ .relay = .{ .base_url = url, .headless = headless, .force_replace = force_replace } };
        } else {
            std.debug.print("ghoztty-agent: unknown argument '{s}'\n", .{a});
            return error.InvalidArgs;
        }
    }
    if (want_enroll) {
        std.debug.print("ghoztty-agent: --enroll requires --relay=<base url>\n", .{});
        return error.InvalidArgs;
    }
    // No recognized mode: print usage and exit. A bare invocation deliberately
    // does NOT open a listener — the TCP path is unauthenticated, so defaulting
    // to it would expose a shell to the network (see the SECURITY note).
    return .usage;
}

/// Build a `.listen` mode, enforcing the loopback/public policy: an
/// unauthenticated TCP shell may bind loopback freely (tests, local dev), but a
/// NON-loopback interface requires the explicit `--insecure-allow-public`
/// opt-in. Without it we refuse rather than silently expose a shell.
/// `port_file` is duped here (argv is freed when parseArgs returns).
fn listenMode(alloc: Allocator, addr: std.net.Address, headless: bool, force_replace: bool, allow_public: bool, port_file: ?[]const u8) !Mode {
    const public = !isLoopbackAddr(addr);
    if (public and !allow_public) {
        std.debug.print(
            "ghoztty-agent: refusing to bind an UNAUTHENTICATED shell listener to a public\n" ++
                "  interface. The --listen TCP path has no authentication.\n" ++
                "  • For secure remote access use: ghoztty-agent --relay=<url>\n" ++
                "  • To bind loopback only: --listen=127.0.0.1:<port>\n" ++
                "  • To accept the risk on a trusted network: add " ++ allow_public_flag ++ "\n",
            .{},
        );
        return error.InsecureListen;
    }
    if (port_file) |pf| if (pf.len == 0) {
        std.debug.print("ghoztty-agent: --port-file requires a non-empty <path>\n", .{});
        return error.InvalidArgs;
    };
    const pf_owned: ?[]const u8 = if (port_file) |pf| try alloc.dupe(u8, pf) else null;
    return .{ .listen = .{ .addr = addr, .headless = headless, .force_replace = force_replace, .public = public, .port_file = pf_owned } };
}

/// Build a `.listen_unix` mode. Validates a non-empty path and rejects it on
/// Windows (AF_UNIX local persistence is not this fork's Windows story — that is
/// a named pipe, §5.2). `path` is duped here (argv is freed when parseArgs
/// returns).
fn listenUnixMode(alloc: Allocator, path: []const u8, headless: bool, force_replace: bool) !Mode {
    if (path.len == 0) {
        std.debug.print("ghoztty-agent: --listen-unix requires a non-empty <path>\n", .{});
        return error.InvalidArgs;
    }
    if (builtin.os.tag == .windows) {
        std.debug.print("ghoztty-agent: --listen-unix is not supported on Windows (use a named pipe)\n", .{});
        return error.InvalidArgs;
    }
    const path_owned = try alloc.dupe(u8, path);
    return .{ .listen_unix = .{ .path = path_owned, .headless = headless, .force_replace = force_replace } };
}

/// Whether `addr` is a loopback address (127.0.0.0/8 or ::1) — the only binds
/// that don't expose the unauthenticated listener beyond this machine.
fn isLoopbackAddr(addr: std.net.Address) bool {
    return switch (addr.any.family) {
        posix.AF.INET => std.mem.asBytes(&addr.in.sa.addr)[0] == 127,
        posix.AF.INET6 => blk: {
            const v6 = [_]u8{0} ** 15 ++ [_]u8{1}; // ::1
            break :blk std.mem.eql(u8, &addr.in6.sa.addr, &v6);
        },
        else => false,
    };
}

/// Print usage to stdout (bare invocation / `--help`). Steers users to the
/// authenticated relay path — never to the unauthenticated listener.
fn printUsage() void {
    const text =
        \\ghoztty-agent — Ghoztty remote-machines daemon
        \\
        \\Usage:
        \\  ghoztty-agent --relay=<url>     Connect to your account's relay (authenticated;
        \\                                  the normal way to bring a machine online).
        \\  ghoztty-agent --enroll --relay=<url>
        \\                                  Enroll this machine to your account (browser sign-in).
        \\  ghoztty-agent --version         Print the build version.
        \\
        \\Advanced / development:
        \\  ghoztty-agent --listen-unix=<path>
        \\                                  Local session daemon over a 0600 AF_UNIX socket
        \\                                  with a same-uid peercred gate (the SECURE local
        \\                                  transport — only this user can reach it). Used by
        \\                                  the app's session-persistence local agent.
        \\  ghoztty-agent --listen=127.0.0.1:<port>
        \\                                  UNAUTHENTICATED TCP shell, loopback only.
        \\                                  Port 0 binds an ephemeral port; add
        \\                                  --port-file=<path> to publish the bound port
        \\                                  as {"port":N,"pid":P,"startedAt":MS} (atomic).
        \\  ghoztty-agent --listen=<addr:port> --insecure-allow-public
        \\                                  UNAUTHENTICATED TCP shell on a routable interface
        \\                                  (trusted networks only — anyone who reaches it gets a shell).
        \\
        \\For secure remote access, use --relay. A bare invocation intentionally does
        \\nothing (it will not open an unauthenticated listener).
        \\
    ;
    std.fs.File.stdout().writeAll(text) catch {};
}

/// Parse "host:port" into a `std.net.Address`. Host may be an IPv4/IPv6 literal.
fn parseAddr(spec: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse {
        std.debug.print("ghoztty-agent: bad address '{s}' (want host:port)\n", .{spec});
        return error.InvalidArgs;
    };
    const host = spec[0..colon];
    const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch {
        std.debug.print("ghoztty-agent: bad port in '{s}'\n", .{spec});
        return error.InvalidArgs;
    };
    return std.net.Address.parseIp(host, port) catch {
        std.debug.print("ghoztty-agent: bad host in '{s}'\n", .{spec});
        return error.InvalidArgs;
    };
}

// -----------------------------------------------------------------------------
// stdio mode (ssh transport): one Mux over stdin/stdout, run until stdin EOF.
// -----------------------------------------------------------------------------

fn runStdio(alloc: Allocator, encoding: protocol.TransferEncoding) !void {
    // stdio mode handles exactly ONE connection (the ssh pipe pair), but it still
    // uses the same shared-store core so the lifecycle code is identical. The store
    // is created here, lives for the single connection, and is torn down on EOF.
    const seed = blk: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };
    var rng = std.Random.DefaultPrng.init(seed);

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    var store = session.SessionStore.init(
        alloc,
        rng.random(),
        undefined,
        realNow,
        session.default_idle_ttl_ms,
    );
    defer store.deinit();

    var stdio = mux_mod.StdioStream.init(std.fs.File.stdin(), std.fs.File.stdout());
    try serveOne(alloc, encoding, &store, spawner.spawner(), stdio.stream());
}

// -----------------------------------------------------------------------------
// TCP listen daemon: bind, then accept→serve→loop. Each connection gets a fresh
// Mux + Server + PtySpawner (no session survival this increment).
// -----------------------------------------------------------------------------

fn runListen(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    addr: std.net.Address,
    headless: bool,
    public: bool,
    port_file: ?[]const u8,
) !void {
    // Loud, unmissable warning when bound to a routable interface: this listener
    // has no authentication, so anyone who can reach the port gets a shell. Only
    // reachable via the explicit --insecure-allow-public opt-in.
    if (public) {
        std.debug.print(
            "ghoztty-agent: WARNING — UNAUTHENTICATED shell listener bound to a PUBLIC\n" ++
                "  interface ({f}). Anyone who can reach this port can run commands on this\n" ++
                "  machine. Use --relay=<url> for authenticated remote access instead.\n",
            .{addr},
        );
    }

    var listener = addr.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("ghoztty-agent: failed to bind {f}: {s}\n", .{ addr, @errorName(err) });
        return err;
    };
    defer listener.deinit();

    // The ADDRESS ACTUALLY BOUND (getsockname). Differs from `addr` when the
    // caller asked for port 0 (ephemeral): this one carries the real port —
    // use it for the banner and the port file below.
    const bound_addr = listener.listen_address;

    // Publish the bound port for the supervisor that spawned us (the whole
    // point of `--listen=127.0.0.1:0 --port-file=...`). Written AFTER the bind
    // succeeds, atomically (tmp+rename), so a reader never sees a torn file or
    // a port we don't actually hold. Failure is fatal: a supervisor waiting on
    // this file would otherwise hang against a silently portless agent.
    if (port_file) |pf| {
        writePortFile(alloc, pf, bound_addr.getPort()) catch |err| {
            std.debug.print("ghoztty-agent: failed to write --port-file {s}: {s}\n", .{ pf, @errorName(err) });
            return err;
        };
    }

    // DAEMON-SCOPED shared session store + spawner (§7.1 survival). These OUTLIVE
    // every connection: a client disconnect tears down its per-connection Server but
    // leaves the sessions, their pty children, and their output rings alive in the
    // store, still streaming, ready for a reconnect to ATTACH and catch up. The
    // store's background reaper evicts sessions left orphaned past the idle-TTL.
    const seed = blk: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };
    var rng = std.Random.DefaultPrng.init(seed);

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    var store = session.SessionStore.init(
        alloc,
        rng.random(),
        undefined,
        realNow,
        session.default_idle_ttl_ms,
    );
    defer store.deinit();
    try store.startReaper();

    const stdout = std.fs.File.stdout();
    // Stdout is line-flushed by the OS for a pipe; print + the newline is enough
    // for an orchestrator polling for readiness. (Even though the Windows agent is
    // built as the GUI subsystem so no console pops up, the deploy watcher
    // redirects stdout to a log file — an inherited handle — so this banner is
    // still captured and the readiness poll still works.)
    stdout.writeAll(std.fmt.allocPrint(alloc, "ghoztty-agent {s}: listening on {f}\n", .{ agent_version, bound_addr }) catch "ghoztty-agent: listening\n") catch {};

    // The accept loop is the whole daemon. WHERE it runs depends on the tray:
    //
    //   • Windows + tray (the default, !headless): the Win32 message loop MUST own
    //     the MAIN thread (it pumps the window that owns the tray icon), so we run
    //     the accept loop on a detached worker thread and hand the main thread to
    //     `tray.run`. When the user picks Exit, `tray.run` returns and we exit the
    //     process. If tray setup fails, we FALL BACK to the main-thread accept loop
    //     below — the daemon must never fail to serve because the UI broke.
    //
    //   • Everything else (headless, or any non-Windows OS): run the accept loop on
    //     the MAIN thread exactly as before — unchanged behavior.
    if (builtin.os.tag == .windows and !headless) {
        const args: AcceptArgs = .{
            .alloc = alloc,
            .encoding = encoding,
            .store = &store,
            .spawner = spawner.spawner(),
            .listener = &listener,
            // TCP listener: no peercred gate (loopback + --insecure-allow-public).
            .enforce_same_uid = false,
        };
        if (std.Thread.spawn(.{}, acceptLoopThread, .{args})) |t| {
            // Hand the MAIN thread to the tray message loop. It returns TRUE only if
            // the tray actually showed and the user picked Exit; FALSE if any tray
            // setup step failed (RegisterClass / CreateWindow / Shell_NotifyIcon).
            // No relay link/account/updater in listen mode → null (no
            // Disconnect/Reconnect, Sign in/out, or self-update items).
            if (tray.run(&store, agent_version, null, null, null)) {
                // User chose Exit: a clean process exit tears down the (still-running)
                // accept loop + reaper daemon threads.
                std.process.exit(0);
            }
            // Tray setup FAILED — never kill the daemon just because the UI couldn't
            // start. The accept loop is the whole daemon and is already serving on
            // the worker thread; park the main thread on it so the process lives on.
            t.join();
            return;
        } else |err| {
            // Couldn't spawn the worker thread — fall through to the main-thread
            // accept loop so the daemon still serves (no tray, but functional).
            std.debug.print("ghoztty-agent: tray worker spawn failed ({s}); serving headless\n", .{@errorName(err)});
        }
    }

    // Headless / non-windows / tray-fallback: run the accept loop right here.
    try acceptLoop(alloc, encoding, &store, spawner.spawner(), &listener, false);
}

// -----------------------------------------------------------------------------
// Unix-domain-socket listen daemon (`--listen-unix=<path>`): the SECURE local
// transport (design §5.2). Same accept→serve→loop core as TCP, but bound to a
// 0600 filesystem socket and gated with a per-connection same-uid peercred
// check. POSIX-only (Windows uses a named pipe later); parseArgs already
// rejected this mode on Windows.
// -----------------------------------------------------------------------------

fn runListenUnix(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    path: []const u8,
    headless: bool,
) !void {
    _ = headless; // no Windows tray on the unix path; reserved for symmetry.

    // Stale-socket livecheck: if something ANSWERS at `path`, a live agent owns
    // it — refuse rather than clobber. The single-instance guard normally means
    // we never reach here with a live peer, but be defensive if the guard was
    // unavailable (it degrades to "serve anyway"). If nothing answers, remove
    // any leftover socket node so bind() won't fail with AddressInUse.
    if (probeUnixAlive(path)) {
        std.debug.print("ghoztty-agent: a live agent already listens at {s}; exiting\n", .{path});
        return error.AlreadyListening;
    }
    std.fs.cwd().deleteFile(path) catch {}; // ignore ENOENT / not-a-file

    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};

    const addr = std.net.Address.initUnix(path) catch |err| {
        std.debug.print("ghoztty-agent: bad --listen-unix path '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };

    // Bind under a restrictive umask so the socket node is created 0600 from the
    // start (never briefly world-connectable): a 127.0.0.1 TCP port is reachable
    // by ANY local uid, a 0600 socket is not. This is defense in depth on top of
    // the peercred gate below. umask is process-global but we are single-threaded
    // here (before the accept loop spawns any workers), so the swap is safe.
    const prev_umask = std.c.umask(0o177);
    var listener = addr.listen(.{}) catch |err| {
        _ = std.c.umask(prev_umask);
        std.debug.print("ghoztty-agent: failed to bind {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    _ = std.c.umask(prev_umask);
    defer listener.deinit();
    // NOTE: the umask above is the whole story — the socket node is created 0600
    // atomically (never briefly more permissive). We deliberately do NOT
    // `fchmod` the bound socket fd as belt-and-braces: on macOS fchmod of a
    // socket fd returns EINVAL, which std.posix.fchmod maps to `unreachable`
    // (panic) — the same class of trap that once killed the agent via
    // SO_NOSIGPIPE (see socket_stream.zig). umask is both sufficient and safe.

    // DAEMON-SCOPED shared session store + spawner — identical lifetime rules to
    // the TCP path (sessions outlive each connection; the reaper evicts orphans).
    const seed = blk: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };
    var rng = std.Random.DefaultPrng.init(seed);

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    var store = session.SessionStore.init(
        alloc,
        rng.random(),
        undefined,
        realNow,
        session.default_idle_ttl_ms,
    );
    defer store.deinit();
    try store.startReaper();

    const stdout = std.fs.File.stdout();
    stdout.writeAll(std.fmt.allocPrint(alloc, "ghoztty-agent {s}: listening on unix:{s}\n", .{ agent_version, path }) catch "ghoztty-agent: listening\n") catch {};

    // Same accept core as TCP, but with the same-uid peercred gate enabled.
    try acceptLoop(alloc, encoding, &store, spawner.spawner(), &listener, true);
}

/// Whether a live peer answers at the AF_UNIX `path` (a successful connect ⇒
/// something is listening; ECONNREFUSED / ENOENT / anything else ⇒ not live).
/// Used to decide whether a leftover socket node is safe to unlink+rebind.
fn probeUnixAlive(path: []const u8) bool {
    if (path.len == 0) return false;
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return false;
    defer std.posix.close(fd);
    var uaddr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    if (path.len >= uaddr.path.len) return false;
    @memcpy(uaddr.path[0..path.len], path);
    uaddr.path[path.len] = 0;
    std.posix.connect(fd, @ptrCast(&uaddr), @sizeOf(std.posix.sockaddr.un)) catch return false;
    return true;
}

/// `getpeereid(2)`: the effective uid/gid of the peer on a connected AF_UNIX
/// socket. Cross-platform (macOS/BSD `LOCAL_PEERCRED`, Linux `SO_PEERCRED`); not
/// declared in Zig std, so we bind it directly. Absent on Windows (unreachable —
/// the unix listen mode is POSIX-only).
const getpeereid = if (builtin.os.tag == .windows) struct {} else struct {
    extern "c" fn getpeereid(fd: c_int, euid: *posix.uid_t, egid: *posix.uid_t) c_int;
}.getpeereid;

/// The peer's effective uid on an accepted AF_UNIX socket, or null if it can't
/// be read (a null result is treated as "reject" by `shouldServe`).
fn peerUid(fd: posix.socket_t) ?posix.uid_t {
    if (builtin.os.tag == .windows) return null;
    var euid: posix.uid_t = undefined;
    var egid: posix.uid_t = undefined;
    if (getpeereid(fd, &euid, &egid) != 0) return null;
    return euid;
}

/// The same-uid admission decision — pure, so every branch is unit-testable
/// without a real socket or a second uid. When enforcement is off, always serve
/// (TCP path). When on: serve only a peer whose uid is known AND equals ours; an
/// unknown peer (getpeereid failed) is rejected.
fn shouldServe(enforce_same_uid: bool, peer_uid: ?posix.uid_t, our_uid: posix.uid_t) bool {
    if (!enforce_same_uid) return true;
    const uid = peer_uid orelse return false;
    return uid == our_uid;
}

/// Atomically publish the listener's bound port for a supervisor: write
/// `{"port":N,"pid":P,"startedAt":MS}` to `path` via the same-directory
/// tmp+rename pattern (see `enroll.saveRelayEnv`), creating parent directories
/// as needed. `pid` lets the reader liveness-check the writer; `startedAt`
/// (unix ms) lets it spot a stale file from a previous boot.
fn writePortFile(alloc: Allocator, path: []const u8, port: u16) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const content = try formatPortFile(alloc, port, currentPid(), std.time.milliTimestamp());
    defer alloc.free(content);

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    {
        // Declared before the create/close pair so on error (LIFO) the file
        // closes BEFORE the delete — Windows can't delete an open file.
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
        // Durable before the rename publishes it: a reader must never parse a
        // partially-flushed port.
        try file.sync();
    }
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
    try std.fs.cwd().rename(tmp_path, path);
}

/// The port-file JSON body (pure — separated from the I/O for tests).
fn formatPortFile(alloc: Allocator, port: u16, pid: i64, started_at_ms: i64) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"port\":{d},\"pid\":{d},\"startedAt\":{d}}}\n",
        .{ port, pid, started_at_ms },
    );
}

fn currentPid() i64 {
    return switch (builtin.os.tag) {
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

/// Bundles the accept-loop parameters so they can ride a single `std.Thread.spawn`
/// argument (the Windows tray path runs the loop on a worker thread).
const AcceptArgs = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    listener: *std.net.Server,
    enforce_same_uid: bool,
};

/// Thread entry wrapper: run the accept loop, logging (but never propagating) a
/// fatal accept error — this is a detached daemon thread.
fn acceptLoopThread(args: AcceptArgs) void {
    acceptLoop(args.alloc, args.encoding, args.store, args.spawner, args.listener, args.enforce_same_uid) catch |err| {
        std.debug.print("ghoztty-agent: accept loop error: {s}\n", .{@errorName(err)});
    };
}

/// THE DAEMON: accept connections forever, serving each on its own detached
/// thread. This is the loop that was previously inlined in `runListen`; it was
/// extracted verbatim so it can run on EITHER the main thread (headless / non-
/// windows) or a worker thread (so the Windows tray can own the main thread).
fn acceptLoop(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    listener: *std.net.Server,
    /// When true (the `--listen-unix` path), gate every accepted connection on a
    /// `LOCAL_PEERCRED`/`SO_PEERCRED` same-uid check: only a peer running as
    /// THIS user may reach the shell. The TCP path passes false (it relies on
    /// loopback binding + the `--insecure-allow-public` opt-in instead).
    enforce_same_uid: bool,
) !void {
    while (true) {
        const conn = listener.accept() catch |err| switch (err) {
            // Transient accept errors: keep the daemon alive.
            error.ConnectionAborted, error.ConnectionResetByPeer => continue,
            else => return err,
        };
        // Same-uid gate (unix socket): reject — and immediately close — any peer
        // that is not this user, or whose credentials can't be read. A shell is
        // never served to an unauthenticated peer.
        if (enforce_same_uid and !shouldServe(true, peerUid(conn.stream.handle), std.posix.geteuid())) {
            std.debug.print("ghoztty-agent: rejecting unix connection from a non-matching uid\n", .{});
            std.posix.close(conn.stream.handle);
            continue;
        }
        // Serve each accepted connection on its OWN detached thread so the accept
        // loop NEVER blocks on one connection's lifecycle (a slow/dead/wedging client
        // can no longer starve new connections — the P0 "never wedge" guarantee). The
        // per-connection worker owns the socket fd and frees its own resources.
        const worker = ConnWorker.create(alloc, encoding, store, spawner, conn.stream.handle) catch |err| {
            std.debug.print("ghoztty-agent: failed to start worker: {s}\n", .{@errorName(err)});
            std.posix.close(conn.stream.handle);
            continue;
        };
        const t = std.Thread.spawn(.{}, ConnWorker.run, .{worker}) catch |err| {
            std.debug.print("ghoztty-agent: failed to spawn worker thread: {s}\n", .{@errorName(err)});
            worker.destroy();
            continue;
        };
        t.detach();
    }
}

/// Wall-clock `now` for the `SessionStore` (matches its `nowFn` signature).
fn realNow(_: *anyopaque) i64 {
    return std.time.milliTimestamp();
}

/// A per-connection worker: owns the accepted socket fd, builds a `Mux` + `Server`
/// over it (sharing the daemon `store`), runs until the socket EOFs, then tears the
/// connection down (DETACHing — never terminating — its sessions) and frees itself.
/// Heap-allocated so it can run on a detached thread.
const ConnWorker = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    fd: std.posix.socket_t,

    fn create(
        alloc: Allocator,
        encoding: protocol.TransferEncoding,
        store: *session.SessionStore,
        spawner: server.Spawner,
        fd: std.posix.socket_t,
    ) !*ConnWorker {
        const self = try alloc.create(ConnWorker);
        self.* = .{
            .alloc = alloc,
            .encoding = encoding,
            .store = store,
            .spawner = spawner,
            .fd = fd,
        };
        return self;
    }

    fn destroy(self: *ConnWorker) void {
        self.alloc.destroy(self);
    }

    fn run(self: *ConnWorker) void {
        var ss = socket_stream.SocketStream.init(self.fd);
        serveOne(self.alloc, self.encoding, self.store, self.spawner, ss.serverStream()) catch |err| {
            std.debug.print("ghoztty-agent: connection error: {s}\n", .{@errorName(err)});
        };
        // serveOne's mux closed the socket fd already (mux.close → ss.close).
        self.destroy();
    }
};

/// Stand up a `Mux` + `Server` over one transport `server.Stream`, sharing the
/// daemon `store` + `spawner`, run until the transport EOFs, then tear the
/// connection down. Shared by both stdio and TCP modes.
fn serveOne(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    store: *session.SessionStore,
    spawner: server.Spawner,
    transport: server.Stream,
) !void {
    var mux = try mux_mod.Mux.create(alloc, transport, encoding);
    defer mux.destroy();

    // Advertise this machine's hostname in the HELLO so the client can label
    // the window (pill) with the real machine name. Display-only, best-effort.
    var host_buf: [256]u8 = undefined;
    const hostname = hostName(&host_buf);

    const srv = try server.Server.create(
        alloc,
        mux.controlStream(),
        mux.dataStream(),
        spawner,
        store,
        .{ .encoding = encoding, .hostname = hostname },
    );
    defer srv.destroy(alloc);

    try srv.start();

    // Pump the transport → lane fifos until EOF. Blocks this thread.
    mux.pumpInput();

    // EOF: the client hung up. Tear the per-connection server down — this DETACHes
    // (never terminates) its sessions, so they survive in the store for reconnect.
    srv.shutdown();
}

/// This machine's hostname for HELLO display, or null if unavailable. On Windows
/// we ask for the DNS hostname (preserves case, matches `hostname` output) rather
/// than %COMPUTERNAME% (uppercased NetBIOS name).
fn hostName(out: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        var wbuf: [256]u16 = undefined;
        var size: u32 = wbuf.len;
        // 1 == ComputerNameDnsHostname
        if (win32.GetComputerNameExW(1, &wbuf, &size) == 0) return null;
        const n = std.unicode.utf16LeToUtf8(out, wbuf[0..size]) catch return null;
        return if (n == 0) null else out[0..n];
    } else {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const name = std.posix.gethostname(&buf) catch return null;
        if (name.len == 0 or name.len > out.len) return null;
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
}

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetComputerNameExW(
        NameType: c_int,
        lpBuffer: [*]u16,
        nSize: *u32,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

// -----------------------------------------------------------------------------
// Relay daemon (`--relay <url>`): single binary, no Go sidecar, no localhost
// listener. The agent holds an authenticated `wss://.../v1/agent/control`
// WebSocket; on each `{"type":"open","session":S}` command it dials a data
// WebSocket `.../v1/agent/data?session=S` and serves that session over it
// EXACTLY like an accepted TCP socket (same `serveOne` core, same shared store,
// so sessions survive a control reconnect). The relay bridges these WebSockets
// verbatim to the client, so the client reaches this agent end-to-end with no
// inbound port and no subprocess.
// -----------------------------------------------------------------------------

/// BASE delay before redialing after the control connection drops or fails to
/// establish (matches the Go relay-agent's 3s reconnect cadence). Repeated
/// FAST drops (connection died < 30s after connecting — the dup-device-token
/// fight signature) escalate exponentially from this base to a 40× (120s)
/// cap with ±20% jitter, resetting once a connection survives 30s; see
/// `link_control.ReconnectBackoff` for the schedule and its exemptions
/// (dial failures, credential bounces, user Disconnect).
const relay_backoff_ms = 3000;

fn runRelay(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    base_url: []const u8,
    token: []u8,
    token_source: relay_creds.Source,
    headless: bool,
) !void {
    // Convert the https/wss base to a clean `wss://host` prefix (no trailing
    // slash); the per-endpoint paths are appended by the loop/worker. Owned for
    // the life of the daemon.
    const ws_base = try wssBase(alloc, base_url);
    defer alloc.free(ws_base);
    // Host part (scheme stripped): the tray tooltip label and the
    // self-updater's HTTPS host. wssBase guarantees a scheme prefix.
    const ws_host = ws_base[(std.mem.indexOf(u8, ws_base, "://") orelse unreachable) + "://".len ..];

    // DAEMON-SCOPED shared session store + spawner (§7.1 survival) — identical to
    // `runListen`. These OUTLIVE every data connection AND every control
    // reconnect: sessions, their pty children, and their rings keep streaming
    // across a control-WS drop, ready for a reconnecting client to ATTACH.
    const seed = blk: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };
    var rng = std.Random.DefaultPrng.init(seed);

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    var store = session.SessionStore.init(
        alloc,
        rng.random(),
        undefined,
        realNow,
        session.default_idle_ttl_ms,
    );
    defer store.deinit();
    try store.startReaper();

    const stdout = std.fs.File.stdout();
    stdout.writeAll(std.fmt.allocPrint(alloc, "ghoztty-agent {s}: relay mode, control={s}/v1/agent/control\n", .{ agent_version, ws_base }) catch "ghoztty-agent: relay mode\n") catch {};

    // SELF-UPDATE (relay mode only): clear a previous swap's leftovers
    // (`.old`/stale `.new` next to the exe — best-effort; Windows may still
    // hold the `.old` of the process we just replaced), then start the
    // background updater. It stages new binaries from the relay's
    // /dl/version.json and swap+respawns ONLY when `store` has zero live
    // sessions. No-op for dev builds or under GHOSTTY_AGENT_NO_SELFUPDATE=1.
    self_update.cleanupLeftovers(alloc);
    // The returned handle (null if disabled/dev) lets the tray "Check for
    // updates" trigger an immediate check.
    const updater = self_update.maybeStart(alloc, ws_host, agent_version, &store);

    // Tighten the existing relay.env DACL to owner-only (Windows). Freshly
    // written credentials are hardened in saveRelayEnv; this catches installs
    // whose credential predates that, so a self-update fixes them in place.
    enroll.hardenLocalCredential(alloc);

    // User-controlled relay link state (tray Disconnect/Reconnect). The tray
    // toggles it from its message-pump thread; the control loop obeys it.
    // `host` (scheme stripped) is what the tooltip shows: "Connected to <host>".
    var link = link_control.LinkControl{ .host = ws_host };

    // LIVE relay credentials: every control dial snapshots the current token,
    // so a re-enroll's rotation lands on the next dial. Owns `token` from
    // here on. Referenced by the loop thread and the watcher thread; this
    // frame outlives both (runRelay never returns while they run).
    var creds = relay_creds.Creds.init(alloc, token_source, token);
    defer creds.deinit();

    // Watch relay.env so a re-enroll is adopted WITHOUT an agent restart:
    // on a token change the watcher swaps the credential and bounces the
    // control link (tray Disconnect stays parked — bounce never overrides the
    // user's desired state). Watch failures only cost the hot-reload feature,
    // never the daemon (same availability-first policy as tray failures).
    var creds_watch: relay_creds.Watcher = undefined;
    if (enroll.relayEnvPath(alloc)) |env_path| {
        creds_watch = relay_creds.Watcher.init(alloc, env_path, &creds, &link, ws_base);
        if (std.Thread.spawn(.{}, relay_creds.Watcher.run, .{&creds_watch})) |t| {
            t.detach(); // daemon-lifetime thread; nothing ever joins it
        } else |err| {
            std.debug.print("ghoztty-agent: relay.env watch disabled ({s}); a re-enroll needs an agent restart\n", .{@errorName(err)});
            creds_watch.deinit();
        }
    } else |err| {
        std.debug.print("ghoztty-agent: relay.env path unavailable ({s}); a re-enroll needs an agent restart\n", .{@errorName(err)});
    }

    // Tray account controller (Sign in / Sign out + "Signed in as <email>").
    // Reads the live creds + drives the link; borrows `base_url` (http(s) relay
    // base) for whoami/deEnroll/enroll. Lives on this frame (outlives the tray).
    var acct_host_buf: [256]u8 = undefined;
    const acct_name = hostName(&acct_host_buf) orelse "unknown-host";
    var account = tray_account.TrayAccount.init(alloc, base_url, acct_name, &creds, &link);
    // Populate "Signed in as <email>" in the background so the first menu open
    // shows it (best-effort; a menu opened before it lands just shows "Signed in").
    account.requestRefresh();

    // The relay control loop is the whole daemon. WHERE it runs depends on the
    // tray, exactly mirroring `runListen`'s accept-loop placement.
    if (builtin.os.tag == .windows and !headless) {
        const args: RelayArgs = .{
            .alloc = alloc,
            .encoding = encoding,
            .ws_base = ws_base,
            .creds = &creds,
            .store = &store,
            .spawner = spawner.spawner(),
            .link = &link,
        };
        if (std.Thread.spawn(.{}, relayLoopThread, .{args})) |t| {
            if (tray.run(&store, agent_version, &link, &account, updater)) {
                std.process.exit(0); // user chose Exit (from any link state)
            }
            // Tray setup failed: park the main thread on the (already-serving)
            // control loop so the daemon lives on.
            t.join();
            return;
        } else |err| {
            std.debug.print("ghoztty-agent: tray worker spawn failed ({s}); serving headless\n", .{@errorName(err)});
        }
    }

    // Headless / non-windows / tray-fallback: run the control loop right here.
    relayLoop(alloc, encoding, ws_base, &creds, &store, spawner.spawner(), &link);
}

/// Convert an `https://host[:port]` / `wss://host[:port]` base to a normalized
/// `wss://host[:port]` (trailing slashes trimmed). `http://`/`ws://` bases map
/// to a PLAINTEXT `ws://` — loopback test relays only, the same rule as
/// `ws_client.zig` / `http_client.zig` (production relays are always TLS).
/// Owned by the caller.
fn wssBase(alloc: Allocator, base: []const u8) ![]u8 {
    const schemes = [_]struct { prefix: []const u8, out: []const u8 }{
        .{ .prefix = "https://", .out = "wss" },
        .{ .prefix = "wss://", .out = "wss" },
        .{ .prefix = "http://", .out = "ws" },
        .{ .prefix = "ws://", .out = "ws" },
    };
    for (schemes) |s| {
        if (std.mem.startsWith(u8, base, s.prefix)) {
            const trimmed = std.mem.trimRight(u8, base[s.prefix.len..], "/");
            return std.fmt.allocPrint(alloc, "{s}://{s}", .{ s.out, trimmed });
        }
    }
    std.debug.print("ghoztty-agent: --relay url must start with https:// or wss:// (http:// / ws:// are loopback-test only)\n", .{});
    return error.InvalidArgs;
}

/// Bundles the relay-loop parameters so they can ride a single `std.Thread.spawn`
/// argument (the Windows tray path runs the loop on a worker thread).
const RelayArgs = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    creds: *relay_creds.Creds,
    store: *session.SessionStore,
    spawner: server.Spawner,
    link: *link_control.LinkControl,
};

fn relayLoopThread(args: RelayArgs) void {
    relayLoop(args.alloc, args.encoding, args.ws_base, args.creds, args.store, args.spawner, args.link);
}

/// THE RELAY DAEMON: hold the control WebSocket; on drop, back off and reconnect
/// (reusing the SAME store, so sessions survive). The loop itself lives in
/// `link_control.runLoop` so the user-facing suspend/resume transitions (tray
/// Disconnect/Reconnect via `link`) are unit-testable; this function builds the
/// real-WsClient `Transport` it drives. Runs until the process exits (the tray
/// Exit path) — `link.stopLoop` would return it, but nothing calls that today.
fn relayLoop(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    creds: *relay_creds.Creds,
    store: *session.SessionStore,
    spawner: server.Spawner,
    link: *link_control.LinkControl,
) void {
    const ctrl_url = std.fmt.allocPrint(alloc, "{s}/v1/agent/control", .{ws_base}) catch {
        std.debug.print("ghoztty-agent: relay: out of memory building control url\n", .{});
        return;
    };
    defer alloc.free(ctrl_url);

    // Advertise this machine's hostname on the control dial (same source as
    // the HELLO's hostname, see `serveOne`) so the relay can label the device
    // without waiting for a session. The relay tolerates its absence. Lives
    // on this frame, which outlives the loop (runLoop blocks until exit).
    var host_buf: [256]u8 = undefined;
    const maybe_host = hostName(&host_buf);

    var transport = RelayTransport{
        .alloc = alloc,
        .encoding = encoding,
        .ws_base = ws_base,
        .creds = creds,
        .store = store,
        .spawner = spawner,
        .ctrl_url = ctrl_url,
        .host = maybe_host,
    };
    link_control.runLoop(link, transport.transport(), relay_backoff_ms);
}

/// One live relay control connection: the WebSocket plus its keepalive
/// (dead-link detection) thread. Heap-allocated per dial so the keepalive's
/// `*Keepalive` stays stable while its thread runs.
const RelayConn = struct {
    ctrl: *ws_client.WsClient,
    /// The device token this connection authenticated with — a `Creds`
    /// snapshot taken at dial time. Session workers spawned off this control
    /// connection reuse it for their data dials (the relay expects the same
    /// credential on both). Stable for the daemon's lifetime (a reload
    /// RETIRES old tokens, never frees them — see `relay_creds.Creds`).
    token: []const u8,
    ka: keepalive.Keepalive,
    ka_thread: ?std.Thread,
};

/// The production `link_control.Transport`: dial the authenticated control
/// WebSocket (+ spawn its keepalive), serve it with `serveControl`, close it
/// via `WsClient.close` (idempotent; unblocks the blocked control read — the
/// same contract the keepalive and the tray's Disconnect rely on).
const RelayTransport = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    creds: *relay_creds.Creds,
    store: *session.SessionStore,
    spawner: server.Spawner,
    ctrl_url: []const u8,
    /// Hostname advertised on the control dial (X-Ghoztty-Hostname), if any.
    /// Borrowed from `relayLoop`'s frame (which outlives the loop).
    host: ?[]const u8,

    fn transport(self: *RelayTransport) link_control.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: link_control.Transport.VTable = .{
        .dial = dial,
        .serve = serve,
        .close = close,
        .deinit = deinit,
    };

    fn dial(ctx: *anyopaque) ?*anyopaque {
        const self: *RelayTransport = @ptrCast(@alignCast(ctx));

        // Snapshot the CURRENT device token per dial: a relay.env reload
        // (re-enroll) swaps it between dials, and the whole point of the
        // watcher's bounce is that THIS dial authenticates with the fresh
        // one. The snapshot stays valid for the connection's lifetime (Creds
        // retires — never frees — superseded tokens).
        const token = self.creds.current();
        const authz = std.fmt.allocPrint(self.alloc, "Bearer {s}", .{token}) catch return null;
        // Headers are only read during the WS handshake; free right after.
        defer self.alloc.free(authz);

        var headers_buf: [2]ws_client.Header = undefined;
        headers_buf[0] = .{ .name = "Authorization", .value = authz };
        var n_headers: usize = 1;
        if (self.host) |hn| {
            headers_buf[n_headers] = .{ .name = "X-Ghoztty-Hostname", .value = hn };
            n_headers += 1;
        }

        const ctrl = ws_client.WsClient.connectUrl(self.alloc, self.ctrl_url, headers_buf[0..n_headers]) catch |err| {
            std.debug.print("ghoztty-agent: relay control connect failed ({s}); retrying (base {d}ms)\n", .{ @errorName(err), relay_backoff_ms });
            return null;
        };
        std.debug.print("ghoztty-agent: relay control connected\n", .{});

        const conn = self.alloc.create(RelayConn) catch {
            ctrl.deinit();
            return null;
        };
        conn.* = .{ .ctrl = ctrl, .token = token, .ka = .{ .link = keepalive.wsLink(ctrl) }, .ka_thread = null };

        // Dead-link detection (the sleep/wake fix): a side thread pings the
        // relay every `ping_interval_ms` and, when NO inbound frame (relay
        // heartbeat / pong / command) arrives within `stale_after_ms`, closes
        // the WebSocket — which unblocks `serveControl`'s blocked read with
        // EOF so the loop redials. Without it, a connection whose peer died
        // while this machine slept blocks in `readMessage` forever. See
        // `keepalive.zig` for the full design rationale.
        conn.ka_thread = std.Thread.spawn(.{}, keepalive.Keepalive.run, .{&conn.ka}) catch |err| blk: {
            std.debug.print("ghoztty-agent: relay keepalive spawn failed ({s}); dead-link detection disabled for this connection\n", .{@errorName(err)});
            break :blk null;
        };
        return conn;
    }

    fn serve(ctx: *anyopaque, connp: *anyopaque) void {
        const self: *RelayTransport = @ptrCast(@alignCast(ctx));
        const conn: *RelayConn = @ptrCast(@alignCast(connp));
        serveControl(self.alloc, self.encoding, self.ws_base, conn.token, self.store, self.spawner, conn.ctrl);
    }

    /// Thread-safe, idempotent; unblocks `serveControl`'s blocked read with
    /// EOF. This is what the tray's Disconnect ends up calling (via
    /// `LinkControl.closeLive`) — and what the keepalive calls on staleness.
    fn close(_: *anyopaque, connp: *anyopaque) void {
        const conn: *RelayConn = @ptrCast(@alignCast(connp));
        conn.ctrl.close();
    }

    fn deinit(ctx: *anyopaque, connp: *anyopaque) void {
        const self: *RelayTransport = @ptrCast(@alignCast(ctx));
        const conn: *RelayConn = @ptrCast(@alignCast(connp));
        // Stop the keepalive BEFORE deinit (it must not touch a freed client).
        // If it went stale it has already returned; requestStop is idempotent.
        if (conn.ka_thread) |t| {
            conn.ka.requestStop();
            t.join();
        }
        conn.ctrl.deinit();
        self.alloc.destroy(conn);
        std.debug.print("ghoztty-agent: relay control ended\n", .{});
    }
};

/// Read control messages until the control WebSocket closes/errors. For each
/// `{"type":"open","session":S}` command, spawn a detached worker that serves
/// that session over its own data WebSocket. Non-`open` messages are ignored.
fn serveControl(
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    token: []const u8,
    store: *session.SessionStore,
    spawner: server.Spawner,
    ctrl: *ws_client.WsClient,
) void {
    // One control command per WS message; 4 KiB is ample for the small JSON.
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = ctrl.readMessage(&buf) catch |err| {
            std.debug.print("ghoztty-agent: relay control read error: {s}\n", .{@errorName(err)});
            return;
        };
        if (n == 0) return; // clean close / EOF

        const Msg = struct { type: []const u8 = "", session: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Msg, alloc, buf[0..n], .{ .ignore_unknown_fields = true }) catch {
            // Malformed JSON — ignore, keep the control connection alive.
            continue;
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.type, "open")) continue;
        if (parsed.value.session.len == 0) continue;

        // Dup the session id for the detached worker (parsed.deinit frees it here).
        const session_id = alloc.dupe(u8, parsed.value.session) catch continue;

        const worker = RelayWorker.create(alloc, encoding, ws_base, token, store, spawner, session_id) catch |err| {
            std.debug.print("ghoztty-agent: relay: failed to start session worker: {s}\n", .{@errorName(err)});
            alloc.free(session_id);
            continue;
        };
        const t = std.Thread.spawn(.{}, RelayWorker.run, .{worker}) catch |err| {
            std.debug.print("ghoztty-agent: relay: failed to spawn session worker: {s}\n", .{@errorName(err)});
            worker.destroy();
            continue;
        };
        t.detach();
    }
}

/// A per-session relay worker: dials the session's data WebSocket and serves it
/// over the SAME `serveOne` core (sharing the daemon `store`/`spawner`) as a TCP
/// connection, then frees itself. `ws_base`/`token` are borrowed (ws_base lives
/// for the daemon's lifetime; token is the control connection's Creds snapshot,
/// which `relay_creds.Creds` keeps alive for the daemon's lifetime even across
/// a reload); `session_id` is owned and freed on teardown.
const RelayWorker = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    ws_base: []const u8,
    token: []const u8,
    store: *session.SessionStore,
    spawner: server.Spawner,
    session_id: []const u8,

    fn create(
        alloc: Allocator,
        encoding: protocol.TransferEncoding,
        ws_base: []const u8,
        token: []const u8,
        store: *session.SessionStore,
        spawner: server.Spawner,
        session_id: []const u8,
    ) !*RelayWorker {
        const self = try alloc.create(RelayWorker);
        self.* = .{
            .alloc = alloc,
            .encoding = encoding,
            .ws_base = ws_base,
            .token = token,
            .store = store,
            .spawner = spawner,
            .session_id = session_id,
        };
        return self;
    }

    fn destroy(self: *RelayWorker) void {
        self.alloc.free(self.session_id);
        self.alloc.destroy(self);
    }

    fn run(self: *RelayWorker) void {
        defer self.destroy();

        const url = std.fmt.allocPrint(self.alloc, "{s}/v1/agent/data?session={s}", .{ self.ws_base, self.session_id }) catch return;
        defer self.alloc.free(url);
        const authz = std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.token}) catch return;
        defer self.alloc.free(authz);
        const headers = [_]ws_client.Header{.{ .name = "Authorization", .value = authz }};

        const dc = ws_client.WsClient.connectUrl(self.alloc, url, &headers) catch |err| {
            std.debug.print("ghoztty-agent: relay data dial (session {s}): {s}\n", .{ self.session_id, @errorName(err) });
            return;
        };
        // serveOne's mux closes the data stream (dc.close) on EOF; `deinit` is the
        // final close + free of the WebSocket.
        serveOne(self.alloc, self.encoding, self.store, self.spawner, dc.serverStream()) catch |err| {
            std.debug.print("ghoztty-agent: relay session {s} error: {s}\n", .{ self.session_id, @errorName(err) });
        };
        dc.deinit();
    }
};

test {
    std.testing.refAllDecls(@This());
    // Not reachable via pub decls, so reference explicitly for test discovery.
    _ = @import("link_control.zig");
    _ = @import("relay_creds.zig");
    _ = @import("self_update.zig");
    _ = @import("single_instance.zig");
}

test "decideRelayCred: env token wins over relay.env" {
    try std.testing.expectEqual(RelayCredDecision.use_env, decideRelayCred(true, true, false));
    try std.testing.expectEqual(RelayCredDecision.use_env, decideRelayCred(true, false, true));
}

test "decideRelayCred: relay.env token when no env token" {
    try std.testing.expectEqual(RelayCredDecision.use_relay_env, decideRelayCred(false, true, false));
    try std.testing.expectEqual(RelayCredDecision.use_relay_env, decideRelayCred(false, true, true));
}

test "decideRelayCred: no cred + headless errors (no surprise browser on servers)" {
    try std.testing.expectEqual(RelayCredDecision.fail, decideRelayCred(false, false, true));
}

test "decideRelayCred: no cred + interactive auto-enrolls (MSI first launch)" {
    try std.testing.expectEqual(RelayCredDecision.auto_enroll, decideRelayCred(false, false, false));
}

test "port file: JSON body carries port/pid/startedAt" {
    const alloc = std.testing.allocator;
    const body = try formatPortFile(alloc, 54321, 987, 1770000000000);
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 54321), parsed.value.object.get("port").?.integer);
    try std.testing.expectEqual(@as(i64, 987), parsed.value.object.get("pid").?.integer);
    try std.testing.expectEqual(@as(i64, 1770000000000), parsed.value.object.get("startedAt").?.integer);
}

test "port file: bind port 0 → write file → read back live port → dial it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Exactly what runListen does for `--listen=127.0.0.1:0 --port-file=...`:
    // bind ephemeral, resolve the real port from listen_address, publish it.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const bound_port = listener.listen_address.getPort();
    try std.testing.expect(bound_port != 0);

    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    // Nested path proves parent-directory creation (the supervisor's config
    // dir may not exist yet on first spawn).
    const path = try std.fs.path.join(alloc, &.{ dir_path, "nested", "port.json" });
    defer alloc.free(path);

    try writePortFile(alloc, path, bound_port);

    // A supervisor's read: parse the file, dial the advertised port.
    const body = try std.fs.cwd().readFileAlloc(alloc, path, 4096);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const file_port: u16 = @intCast(parsed.value.object.get("port").?.integer);
    try std.testing.expectEqual(bound_port, file_port);
    try std.testing.expectEqual(currentPid(), parsed.value.object.get("pid").?.integer);
    try std.testing.expect(parsed.value.object.get("startedAt").?.integer > 0);

    const dial_addr = try std.net.Address.parseIp("127.0.0.1", file_port);
    const conn = try std.net.tcpConnectToAddress(dial_addr);
    conn.close();

    // The staging file is consumed by the rename, never left behind.
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(tmp_path));

    // Rewrite (agent restart reusing the same path) must replace the file.
    try writePortFile(alloc, path, bound_port);
}

// --- T09: --listen-unix transport + same-uid peercred gate -------------------

test "shouldServe: same-uid admission decision (all branches)" {
    const our: posix.uid_t = 501;
    // Enforcement OFF (the TCP path): always serve, regardless of peer.
    try std.testing.expect(shouldServe(false, null, our));
    try std.testing.expect(shouldServe(false, 999, our));
    // Enforcement ON: serve only a KNOWN peer whose uid equals ours.
    try std.testing.expect(shouldServe(true, our, our));
    // Different uid → reject.
    try std.testing.expect(!shouldServe(true, 999, our));
    // Unknown peer (getpeereid failed → null) → reject, never serve blind.
    try std.testing.expect(!shouldServe(true, null, our));
}

/// A short, unique AF_UNIX path under the system tmp dir (the sun_path field is
/// only ~104 bytes on macOS, so a nested tmpDir realpath can overflow it).
fn testSockPath(buf: []u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/gztt-t09-{s}-{d}.sock", .{ tag, currentPid() });
}

test "listen-unix: peerUid on a real accepted connection is our uid; gate passes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pbuf: [128]u8 = undefined;
    const path = try testSockPath(&pbuf, "peer");
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    const addr = try std.net.Address.initUnix(path);
    var listener = try addr.listen(.{});
    defer listener.deinit();

    // Connect a client (same process ⇒ same uid) and accept the server end.
    const client_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(client_fd);
    var uaddr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    @memcpy(uaddr.path[0..path.len], path);
    uaddr.path[path.len] = 0;
    try std.posix.connect(client_fd, @ptrCast(&uaddr), @sizeOf(std.posix.sockaddr.un));

    const conn = try listener.accept();
    defer std.posix.close(conn.stream.handle);

    // The accept-path credential read: the peer's uid is known and is ours.
    const uid = peerUid(conn.stream.handle);
    try std.testing.expectEqual(std.posix.geteuid(), uid.?);
    // And the gate that acceptLoop applies admits it.
    try std.testing.expect(shouldServe(true, uid, std.posix.geteuid()));
}

test "listen-unix: bind creates a 0600 socket node (umask), probeUnixAlive sees it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pbuf: [128]u8 = undefined;
    const path = try testSockPath(&pbuf, "perm");
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    // Nothing bound yet ⇒ not alive.
    try std.testing.expect(!probeUnixAlive(path));

    // Bind under the same restrictive umask runListenUnix uses.
    const prev = std.c.umask(0o177);
    const addr = try std.net.Address.initUnix(path);
    var listener = try addr.listen(.{});
    _ = std.c.umask(prev);
    defer listener.deinit();

    // The node is 0600 (never group/other-accessible) — the whole point vs a
    // 127.0.0.1 TCP port that any local uid can reach.
    const st = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(@as(u16, 0o600), @as(u16, @intCast(st.mode & 0o777)));

    // A live listener answers the connect-probe used for stale-socket cleanup.
    try std.testing.expect(probeUnixAlive(path));
}

test "wssBase: https/wss normalize to wss; http/ws stay plaintext; others refused" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "https://relay.example.com/", .want = "wss://relay.example.com" },
        .{ .in = "wss://relay.example.com", .want = "wss://relay.example.com" },
        .{ .in = "http://127.0.0.1:8080/", .want = "ws://127.0.0.1:8080" },
        .{ .in = "ws://127.0.0.1:8080", .want = "ws://127.0.0.1:8080" },
    };
    for (cases) |c| {
        const got = try wssBase(alloc, c.in);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
    try std.testing.expectError(error.InvalidArgs, wssBase(alloc, "relay.example.com"));
}
