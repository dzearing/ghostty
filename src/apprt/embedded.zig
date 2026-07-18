//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreApp = @import("../App.zig");
const CoreInspector = @import("../inspector/main.zig").Inspector;
const CoreSurface = @import("../Surface.zig");
const remote_connection = @import("../remote/connection.zig");
const remote_protocol = @import("../remote/protocol.zig");
const ssh_transport = @import("../remote/ssh_transport.zig");
const tcp_dial = @import("../remote/tcp_dial.zig");
const relay_dial = @import("../remote/relay_dial.zig");
const remote_proc = @import("../remote/agent/proc.zig");
const remote_metrics = @import("../remote/agent/metrics.zig");
const remote_proc_control = @import("../remote/agent/proc_control.zig");
const remote_proc_spawn = @import("../remote/agent/proc_spawn.zig");
const CommandCore = @import("../CommandCore.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const String = @import("../main_c.zig").String;

const log = std.log.scoped(.embedded_window);

pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// These are just aliases to make the function signatures below
        /// more obvious what values will be sent.
        const AppUD = ?*anyopaque;
        const SurfaceUD = ?*anyopaque;

        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// True if the selection clipboard is supported.
        supports_selection_clipboard: bool = false,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (AppUD) callconv(.c) void,

        /// Callback called to handle an action.
        action: *const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.c) bool,

        /// Read the clipboard value. Returns true if the clipboard request
        /// was started and complete_clipboard_request may be called with the
        /// given state pointer. Returns false if the clipboard request couldn't
        /// be started (such as when no text is available for a paste request).
        read_clipboard: *const fn (SurfaceUD, c_int, *apprt.ClipboardRequest) callconv(.c) bool,

        /// This may be called after a read clipboard call to request
        /// confirmation that the clipboard value is safe to read. The embedder
        /// must call complete_clipboard_request with the given request.
        confirm_read_clipboard: *const fn (
            SurfaceUD,
            [*:0]const u8,
            *apprt.ClipboardRequest,
            apprt.ClipboardRequestType,
        ) callconv(.c) void,

        /// Write the clipboard value.
        write_clipboard: *const fn (
            SurfaceUD,
            c_int,
            [*]const CAPI.ClipboardContent,
            usize,
            bool,
        ) callconv(.c) void,

        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,
    };

    /// This is the key event sent for ghostty_surface_key and
    /// ghostty_app_key.
    pub const KeyEvent = struct {
        action: input.Action,
        mods: input.Mods,
        consumed_mods: input.Mods,
        keycode: u32,
        text: ?[:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert a libghostty key event into a core key event.
        fn core(self: KeyEvent) ?input.KeyEvent {
            const text: []const u8 = if (self.text) |v| v else "";
            const unshifted_codepoint: u21 = std.math.cast(
                u21,
                self.unshifted_codepoint,
            ) orelse 0;

            // We want to get the physical unmapped key to process keybinds.
            const physical_key = keycode: for (input.keycodes.entries) |entry| {
                if (entry.native == self.keycode) break :keycode entry.key;
            } else .unidentified;

            // Build our final key event
            return .{
                .action = self.action,
                .key = physical_key,
                .mods = self.mods,
                .consumed_mods = self.consumed_mods,
                .composing = self.composing,
                .utf8 = text,
                .unshifted_codepoint = unshifted_codepoint,
            };
        }
    };

    core_app: *CoreApp,
    opts: Options,
    keymap: input.Keymap,

    /// The configuration for the app. This is owned by this structure.
    config: Config,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        config: *const Config,
        opts: Options,
    ) !void {
        // We have to clone the config.
        const alloc = core_app.alloc;
        var config_clone = try config.clone(alloc);
        errdefer config_clone.deinit();

        var keymap = try input.Keymap.init();
        errdefer keymap.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config_clone,
            .opts = opts,
            .keymap = keymap,
        };
    }

    pub fn terminate(self: *App) void {
        self.keymap.deinit();
        self.config.deinit();
    }

    /// Returns true if there are any global keybinds in the configuration.
    pub fn hasGlobalKeybinds(self: *const App) bool {
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .leader => {},
                inline .leaf, .leaf_chained => |leaf| if (leaf.flags.global) return true,
            }
        }

        return false;
    }

    /// The target of a key event. This is used to determine some subtly
    /// different behavior between app and surface key events.
    pub const KeyTarget = union(enum) {
        app,
        surface: *Surface,
    };

    /// See CoreApp.focusEvent
    pub fn focusEvent(self: *App, focused: bool) void {
        self.core_app.focusEvent(focused);
    }

    /// See CoreApp.keyEvent.
    pub fn keyEvent(
        self: *App,
        target: KeyTarget,
        event: KeyEvent,
    ) !bool {
        // Convert our C key event into a Zig one.
        const input_event: input.KeyEvent = event.core() orelse
            return false;

        // Invoke the core Ghostty logic to handle this input.
        const effect: CoreSurface.InputEffect = switch (target) {
            .app => if (self.core_app.keyEvent(
                self,
                input_event,
            )) .consumed else .ignored,

            .surface => |surface| try surface.core_surface.keyCallback(
                input_event,
            ),
        };

        return switch (effect) {
            .closed => true,
            .ignored => false,
            .consumed => true,
        };
    }

    /// This should be called whenever the keyboard layout was changed.
    pub fn reloadKeymap(self: *App) !void {
        // Reload the keymap
        try self.keymap.reload();
    }

    /// Loads the keyboard layout.
    ///
    /// Kind of expensive so this should be avoided if possible. When I say
    /// "kind of expensive" I mean that its not something you probably want
    /// to run on every keypress.
    pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
        // We only support keyboard layout detection on macOS.
        if (comptime builtin.os.tag != .macos) return .unknown;

        // Any layout larger than this is not something we can handle.
        var buf: [256]u8 = undefined;
        const id = self.keymap.sourceId(&buf) catch |err| {
            comptime assert(@TypeOf(err) == error{OutOfMemory});
            return .unknown;
        };

        return input.KeyboardLayout.mapAppleId(id) orelse .unknown;
    }

    pub fn wakeup(self: *const App) void {
        self.opts.wakeup(self.opts.userdata);
    }

    pub fn wait(self: *const App) !void {
        _ = self;
    }

    /// Create a new surface for the app.
    fn newSurface(self: *App, opts: Surface.Options) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        // Create the surface
        try surface.init(self, opts);
        errdefer surface.deinit();

        return surface;
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        surface.deinit();
        self.core_app.alloc.destroy(surface);
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        surface.queueInspectorRender();
    }

    /// Perform a given action. Returns `true` if the action was able to be
    /// performed, `false` otherwise.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        // Special case certain actions before they are sent to the
        // embedded apprt.
        self.performPreAction(target, action, value);

        log.debug("dispatching action target={t} action={} value={any}", .{
            target,
            action,
            value,
        });
        return self.opts.action(
            self,
            target.cval(),
            @unionInit(apprt.Action, @tagName(action), value).cval(),
        );
    }

    fn performPreAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) void {
        // Special case certain actions before they are sent to the embedder
        switch (action) {
            .set_title => switch (target) {
                .app => {},
                .surface => |surface| {
                    // Dupe the title so that we can store it. If we get an allocation
                    // error we just ignore it, since this only breaks a few minor things.
                    const alloc = self.core_app.alloc;
                    if (surface.rt_surface.title) |v| alloc.free(v);
                    surface.rt_surface.title = alloc.dupeZ(u8, value.title) catch null;
                },
            },

            .config_change => switch (target) {
                .surface => {},

                // For app updates, we update our core config. We need to
                // clone it because the caller owns the param.
                .app => if (value.config.clone(self.core_app.alloc)) |config| {
                    self.config.deinit();
                    self.config = config;
                } else |err| {
                    log.err("error updating app config err={}", .{err});
                },
            },

            else => {},
        }
    }

    /// Send the given IPC to a running Ghostty. Returns `true` if the action was
    /// able to be performed, `false` otherwise.
    ///
    /// Note that this is a static function. Since this is called from a CLI app (or
    /// some other process that is not Ghostty) there is no full-featured apprt App
    /// to use.
    pub fn performIpc(
        alloc: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        value: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
        const action_name = switch (action) {
            .new_window => "new-window",
            .split => "split",
            .close => "close",
            .rename => "rename",
            .rearrange => "rearrange",
            .send_keys => "send-keys",
            .set_state => "set-state",
            .set_banner => "set-banner",
        };

        return sendIpc(alloc, action_name, value.arguments);
    }

    fn sendIpc(
        alloc: Allocator,
        action_name: []const u8,
        arguments: ?[][:0]const u8,
    ) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
        var buf: [256]u8 = undefined;
        // Streaming (not positional) writer: the CLI command that called us
        // has its own buffered stderr writer, and mixing a positional writer
        // with it corrupts/reorders output when stderr is a file or pipe.
        var stderr_writer = std.fs.File.stderr().writerStreaming(&buf);
        const stderr = &stderr_writer.interface;

        const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
        const uid = std.c.getuid();
        const build_config = @import("../build_config.zig");
        const suffix = if (build_config.is_debug) "-debug" else "";
        const sock_path = std.fmt.allocPrintSentinel(alloc, "{s}ghostty{s}-{d}.sock", .{
            tmpdir, suffix, uid,
        }, 0) catch |err| {
            stderr.print("Failed to build socket path: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer alloc.free(sock_path);

        const fd = connectUnixSocket(sock_path) catch blk: {
            // Connection failed. Drop a sentinel file to signal the main
            // process to rebind its socket, then retry with backoff.
            const sentinel_path = std.fmt.allocPrintSentinel(alloc, "{s}.reset", .{sock_path}, 0) catch {
                stderr.print("Could not connect to running Ghoztty instance.\n", .{}) catch {};
                stderr.flush() catch {};
                return error.IPCFailed;
            };
            defer alloc.free(sentinel_path);

            if (std.fs.cwd().createFile(sentinel_path, .{})) |f| {
                f.close();
            } else |_| {}

            const max_retries = 8;
            var attempt: usize = 0;
            while (attempt < max_retries) : (attempt += 1) {
                std.Thread.sleep(300 * std.time.ns_per_ms);
                if (connectUnixSocket(sock_path)) |connected_fd| {
                    std.fs.cwd().deleteFile(sentinel_path) catch {};
                    break :blk connected_fd;
                } else |_| {}

                // If the sentinel file still exists after several attempts,
                // no server is watching for it — bail early.
                if (attempt >= 2) {
                    if (std.fs.accessAbsolute(sentinel_path, .{})) |_| {
                        break;
                    } else |_| {}
                }
            }

            std.fs.cwd().deleteFile(sentinel_path) catch {};
            return error.NoRunningInstance;
        };
        defer std.posix.close(fd);

        var json_buf: std.Io.Writer.Allocating = .init(alloc);
        defer json_buf.deinit();
        var jws: std.json.Stringify = .{ .writer = &json_buf.writer };

        jws.beginObject() catch return error.IPCFailed;
        jws.objectField("action") catch return error.IPCFailed;
        jws.write(action_name) catch return error.IPCFailed;

        if (arguments) |args| {
            jws.objectField("arguments") catch return error.IPCFailed;
            jws.beginArray() catch return error.IPCFailed;
            for (args) |arg| {
                jws.write(arg) catch return error.IPCFailed;
            }
            jws.endArray() catch return error.IPCFailed;
        }

        jws.endObject() catch return error.IPCFailed;

        const json_bytes = json_buf.written();

        const len: u32 = @intCast(json_bytes.len);
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, len));
        _ = std.posix.write(fd, &len_bytes) catch |err| {
            stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        _ = std.posix.write(fd, json_bytes) catch |err| {
            stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };

        var resp_len_bytes: [4]u8 = undefined;
        readFull(fd, &resp_len_bytes) catch {
            stderr.print("Failed to read IPC response length\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };

        const resp_len = std.mem.bigToNative(u32, std.mem.bytesAsValue(u32, &resp_len_bytes).*);
        if (resp_len == 0 or resp_len > 1048576) {
            stderr.print("IPC response has invalid length: {d}\n", .{resp_len}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        }

        const resp_buf = alloc.alloc(u8, resp_len) catch {
            stderr.print("Out of memory reading IPC response\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer alloc.free(resp_buf);

        readFull(fd, resp_buf) catch {
            stderr.print("Failed to read IPC response\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };

        const parsed = apprt.ipc.parseResponse(alloc, resp_buf) catch {
            stderr.print("IPC response is not valid JSON\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer parsed.deinit();

        // On failure the server includes a human-readable reason (e.g.
        // "pane 'd1' not found in registry"). Print it here so EVERY CLI
        // action surfaces the real cause instead of a generic fallback.
        if (!parsed.value.success) {
            if (parsed.value.@"error") |msg| {
                stderr.print("{s}\n", .{msg}) catch {};
                stderr.flush() catch {};
            }
            return false;
        }

        return true;
    }

    fn connectUnixSocket(path: [:0]const u8) !std.posix.fd_t {
        const fd = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM,
            0,
        );
        errdefer std.posix.close(fd);

        var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;

        try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        return fd;
    }

    fn readFull(fd: std.posix.fd_t, buffer: []u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = std.posix.read(fd, buffer[total..]) catch |err| return err;
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }
};

/// Platform-specific configuration for libghostty.
pub const Platform = union(PlatformTag) {
    macos: MacOS,
    ios: IOS,

    // If our build target for libghostty is not darwin then we do
    // not include macos support at all.
    pub const MacOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        nsview: objc.Object,
    } else void;

    pub const IOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        uiview: objc.Object,
    } else void;

    // The C ABI compatible version of this union. The tag is expected
    // to be stored elsewhere.
    pub const C = extern union {
        macos: extern struct {
            nsview: ?*anyopaque,
        },

        ios: extern struct {
            uiview: ?*anyopaque,
        },
    };

    /// Initialize a Platform a tag and configuration from the C ABI.
    pub fn init(tag_int: c_int, c_platform: C) !Platform {
        const tag = try std.meta.intToEnum(PlatformTag, tag_int);
        return switch (tag) {
            .macos => if (MacOS != void) macos: {
                const config = c_platform.macos;
                const nsview = objc.Object.fromId(config.nsview orelse
                    break :macos error.NSViewMustBeSet);
                break :macos .{ .macos = .{ .nsview = nsview } };
            } else error.UnsupportedPlatform,

            .ios => if (IOS != void) ios: {
                const config = c_platform.ios;
                const uiview = objc.Object.fromId(config.uiview orelse
                    break :ios error.UIViewMustBeSet);
                break :ios .{ .ios = .{ .uiview = uiview } };
            } else error.UnsupportedPlatform,
        };
    }
};

pub const PlatformTag = enum(c_int) {
    // "0" is reserved for invalid so we can detect unset values
    // from the C API.

    macos = 1,
    ios = 2,
};

pub const EnvVar = extern struct {
    /// The name of the environment variable.
    key: [*:0]const u8,

    /// The value of the environment variable.
    value: [*:0]const u8,
};

/// C-ABI host metrics snapshot (remote-machines activity monitor, §9.3). Mirrors
/// `protocol.HostMetrics`; the optional `uptime_s`/`load1` use sentinel values
/// when the remote OS doesn't expose them (`uptime_s = 0` ⇒ unknown is fine since
/// a real uptime is always > 0; `load1 = -1` ⇒ unknown, e.g. Windows has no load
/// average).
const ghostty_host_metrics_s = extern struct {
    cpu_pct: f32,
    mem_used: u64,
    mem_total: u64,
    ncpu: u32,
    uptime_s: u64, // 0 if unknown
    load1: f32, // -1 if unknown
};

/// Callback invoked for each pushed host-metrics sample. NOTE: it fires on the
/// connection's control-reader thread (NOT the GUI main thread) — the Swift side
/// must hop to the main queue before touching UI. The `ghostty_host_metrics_s`
/// pointer borrows stack storage valid only for the duration of the call; copy
/// the fields out. `userdata` is the opaque pointer passed to `_metrics_subscribe`.
const GhosttyMetricsCallback = *const fn (?*const ghostty_host_metrics_s, ?*anyopaque) callconv(.c) void;

/// Callback invoked on every connection link-state transition (§5.1 FSM;
/// WP-D1 connection-status surface). `state` is a `GHOSTTY_REMOTE_CONN_*`
/// value (the integer mirror of `connection.LinkState.State`). NOTE: it fires
/// on a connection-internal thread (reader/heartbeat) while the connection's
/// state lock is held — the callee must NOT call back into any
/// `ghostty_remote_connection_*` API from the callback; copy what it needs
/// and return promptly (the Swift side hops to the main queue).
const GhosttyRemoteStateCallback = *const fn (i32, ?*anyopaque) callconv(.c) void;

/// One process-table row (activity monitor, §9.3 process view). Mirrors the wire
/// `Proc`. `name`/`user`/`cmd` are always non-null NUL-terminated C strings — an
/// empty string means "unavailable" (the agent left `user`/`cmd` null), NEVER a
/// NULL pointer (so the Swift side can read them unconditionally). `cpu_pct` is
/// per-core: a fully-busy single thread reads ~100; a multithreaded process can
/// exceed 100. Normalize by `ghostty_host_metrics_s.ncpu` for a 0..100 total.
const ghostty_proc_s = extern struct {
    pid: i64,
    ppid: i64,
    cpu_pct: f32,
    mem_bytes: u64,
    name: [*:0]const u8,
    user: [*:0]const u8,
    cmd: [*:0]const u8,
};

/// A snapshot of the remote host's process table returned by
/// `ghostty_remote_connection_proc_list`. `ok == false` ⇒ the call failed (no
/// connection / agent error / timeout) and `procs_len == 0`. Free with
/// `ghostty_remote_connection_proc_list_free`.
const ghostty_proc_list_s = extern struct {
    ok: bool,
    truncated: bool,
    host: ghostty_host_metrics_s,
    procs: [*]ghostty_proc_s,
    procs_len: usize,
    /// The root pid of the "ghoztty-spawned" process tree (remote: the agent's own
    /// pid; local: this app's own pid). 0 = unknown (old agent that did not report
    /// it). The UI defaults to showing only descendants of this pid.
    agent_pid: i64,
};

/// A stable, never-freed empty array so a failed/empty `ghostty_proc_list_s` has a
/// valid (non-dangling) `procs` pointer — `_proc_list_free` short-circuits on
/// `procs_len == 0` and never touches it.
var empty_procs_sentinel: [0]ghostty_proc_s = .{};

/// The Zig object behind an opaque `ghostty_remote_connection_t`
/// (remote-machines design §3.5). A connection is keyed by
/// (host, user, port, jump-chain) and multiplexes N remote panes/sessions. It
/// is owned by the caller (the Swift app) and lives in the GUI process — a GUI
/// crash disposes it; remote-side persistence is by `session_id`.
///
/// WP3 status: this records the dial parameters AND, once `_start` succeeds,
/// owns a live `ssh_transport.Transport` (the two `ssh` subprocesses + the
/// `Connection` byte-pump). The transport is built with the GUI-free
/// `CommandCore.DefaultCommand` spawn core so no apprt/config graph is pulled
/// into the agent-launch path (§17).
pub const RemoteConnectionHandle = struct {
    /// Trampoline state for an active host-metrics subscription: the C callback +
    /// the caller's opaque `userdata`. Stored inline (no heap free). See `metrics_cb`.
    pub const MetricsTrampoline = struct {
        cb: GhosttyMetricsCallback,
        userdata: ?*anyopaque,
    };

    /// Trampoline state for the link-state callback (WP-D1): the C callback +
    /// the caller's opaque `userdata`. Stored inline on the handle (stable for
    /// the handle's life) so its address can serve as the Zig `StateHandler`
    /// ctx. See `state_cb` / `stateTrampoline`.
    pub const StateTrampoline = struct {
        cb: GhosttyRemoteStateCallback,
        userdata: ?*anyopaque,
    };

    alloc: Allocator,

    /// Dial parameters (duped into `alloc`, owned by this handle).
    host: [:0]const u8,
    user: ?[:0]const u8,
    port: u16,
    jump: ?[:0]const u8,

    /// The live ssh transport, or null until `_start` dials successfully. When
    /// non-null it owns the two ssh subprocesses + the `Connection` and is torn
    /// down in `destroy`.
    transport: ?*Transport = null,

    /// Trampoline state for an active host-metrics subscription (§9.3), or null
    /// when not subscribed. The Zig `MetricsHandler` registered with the
    /// `Connection` receives `protocol.HostMetrics`; this struct carries the C
    /// callback + the caller's `userdata` so the handler can marshal the snapshot
    /// into a `ghostty_host_metrics_s` and invoke `cb(&hm, userdata)`. It lives
    /// inline on the handle (no heap free needed); `subscribeMetrics` passes
    /// `&self.metrics_cb.?` as the handler ctx, so it must stay pinned for the
    /// life of the subscription (the handle is heap-allocated and stable).
    metrics_cb: ?MetricsTrampoline = null,

    /// Trampoline state for the link-state observer (WP-D1), or null when not
    /// registered. Same pinning discipline as `metrics_cb`: lives inline on the
    /// heap-allocated handle so `&self.state_cb.?` stays valid for the life of
    /// the registration; cleared (with the connection's `clearStateHandler`,
    /// which synchronizes against an in-flight invocation) before teardown.
    state_cb: ?StateTrampoline = null,

    /// The live TCP transport, or null. Populated by
    /// `ghostty_remote_connection_new_tcp` (WP4): a direct TCP dial to a
    /// listening `ghoztty-agent` (e.g. over Tailscale / localhost), which
    /// completes the HELLO handshake before returning. Mutually exclusive with
    /// `transport` (an `_new_tcp` handle never goes through the SSH `_start`
    /// path). Owns the socket + mux + `Connection`; torn down in `destroy`.
    tcp: ?*tcp_dial.Dialed = null,

    /// The live relay transport, or null. Populated by
    /// `ghostty_remote_connection_new_relay`: dials a remote `ghoztty-agent`
    /// THROUGH a rendezvous relay (a native `wss://` WebSocket tunnels a framed
    /// connection over an authenticated link), completing the HELLO handshake
    /// before returning. Mutually exclusive with `transport`/`tcp`. Owns the
    /// WebSocket client + mux + `Connection`; torn down in `destroy`.
    relay: ?*relay_dial.Dialed = null,

    /// The transport is parameterized by the GUI-free spawn core so the
    /// agent-launch subprocess uses no-op rlimits / empty pre_exec hooks.
    pub const Transport = ssh_transport.Transport(CommandCore.DefaultCommand);

    /// The live `Connection` for this handle, from whichever transport (SSH or
    /// TCP) is established, or null if neither has dialed yet. The single seam
    /// every downstream reader (`remoteBackend`, `_wait_handshake`,
    /// `_latency_ms`) goes through so the two transports are interchangeable.
    pub fn conn(self: *const RemoteConnectionHandle) ?*remote_connection.Connection {
        if (self.transport) |t| return t.conn;
        if (self.tcp) |d| return d.conn;
        if (self.relay) |d| return d.conn;
        return null;
    }

    /// Create a handle from dial parameters. Dupes all strings.
    pub fn create(
        alloc: Allocator,
        host: []const u8,
        user: ?[]const u8,
        port: u16,
        jump: ?[]const u8,
    ) !*RemoteConnectionHandle {
        const self = try alloc.create(RemoteConnectionHandle);
        errdefer alloc.destroy(self);

        const host_dup = try alloc.dupeZ(u8, host);
        errdefer alloc.free(host_dup);
        const user_dup = if (user) |u| try alloc.dupeZ(u8, u) else null;
        errdefer if (user_dup) |u| alloc.free(u);
        const jump_dup = if (jump) |j| try alloc.dupeZ(u8, j) else null;
        errdefer if (jump_dup) |j| alloc.free(j);

        self.* = .{
            .alloc = alloc,
            .host = host_dup,
            .user = user_dup,
            .port = port,
            .jump = jump_dup,
        };
        return self;
    }

    /// Shut down the live transport (if any) and free the handle. The caller
    /// must ensure no surface still references this handle.
    pub fn destroy(self: *RemoteConnectionHandle) void {
        const alloc = self.alloc;
        // Defensively clear any lingering metrics subscription BEFORE the transport
        // teardown so no metrics callback can fire mid-teardown (clearing the
        // handler slot under the connection's write mutex). The subsequent
        // shutdown joins the control reader, after which no callback can fire.
        if (self.metrics_cb != null) {
            if (self.conn()) |c| c.unsubscribeMetrics();
            self.metrics_cb = null;
        }
        // Same for the link-state observer (WP-D1): the transport shutdown below
        // drives reader-EOF transitions, which must NOT fire into a caller that
        // is in the middle of freeing us. `clearStateHandler` takes the state
        // lock, so any in-flight callback has returned when it does.
        if (self.state_cb != null) {
            if (self.conn()) |c| c.clearStateHandler();
            self.state_cb = null;
        }
        // `Transport.deinit` shuts the connection down, closes the streams (the
        // ssh children observe EOF on stdin and exit), reaps both children, and
        // frees the connection + control-path.
        if (self.transport) |t| t.deinit();
        // `Dialed.deinit` performs the strict TCP teardown (conn.shutdown →
        // mux.joinPump → free conn/mux/socket), closing the socket fd.
        if (self.tcp) |d| {
            d.deinit();
            alloc.destroy(d);
        }
        // `relay_dial.Dialed.deinit` performs the strict relay teardown
        // (conn.shutdown → mux.joinPump → free conn/mux → reap the helper child →
        // free the env map + child stream).
        if (self.relay) |d| {
            d.deinit();
            alloc.destroy(d);
        }
        alloc.free(self.host);
        if (self.user) |u| alloc.free(u);
        if (self.jump) |j| alloc.free(j);
        alloc.destroy(self);
    }
};

pub const Surface = struct {
    app: *App,
    platform: Platform,
    userdata: ?*anyopaque = null,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    inspector: ?*Inspector = null,

    /// The current title of the surface. The embedded apprt saves this so
    /// that getTitle works without the implementer needing to save it.
    title: ?[:0]const u8 = null,

    /// Remote-machine backend for this surface, if any (remote-machines design
    /// §3.2). Copied from `Options.connection`/`.session_id` at init and read
    /// by `CoreSurface.init` via `remoteBackend()` to construct the `.remote`
    /// termio backend. The handle is borrowed (caller-owned). `session_id`
    /// is borrowed for the duration of `CoreSurface.init` only (the remote
    /// backend dupes it), so we only retain the raw C pointer here.
    remote_connection: ?*RemoteConnectionHandle = null,
    remote_session_id: ?[*:0]const u8 = null,

    /// Explicit REMOTE working directory for an OPEN-new remote session (§WP4),
    /// copied from `Options.remote_working_directory`. Borrowed for the duration
    /// of `CoreSurface.init` only (the remote backend dupes it). Distinct from
    /// the LOCAL `config.@"working-directory"` so the stall-fix invariant holds:
    /// a fresh remote window (no parent, no explicit remote cwd) forwards NO cwd.
    remote_working_directory: ?[*:0]const u8 = null,

    /// The REMOTE shell for an OPEN-new remote session, copied from
    /// `Options.remote_shell`. Borrowed for the duration of `CoreSurface.init`
    /// only (the remote backend dupes it). A remote-native path (per-host
    /// setting or explicit `--shell`), NEVER the local shell config — same
    /// invariant as `remote_working_directory`.
    remote_shell: ?[*:0]const u8 = null,

    /// True ⇒ the remote connection is the LOCAL agent (same machine + bundle),
    /// so `remoteBackend()` requests ghostty shell integration + the per-pane
    /// GHOSTTY_* env for the pane (T04b). Copied from
    /// `Options.remote_local_shell_integration`. Ignored when `connection` is
    /// null. NEVER true for a cross-machine window.
    remote_local_shell_integration: bool = false,

    /// Surface initialization options.
    pub const Options = extern struct {
        /// The platform that this surface is being initialized for and
        /// the associated platform-specific configuration.
        platform_tag: c_int = 0,
        platform: Platform.C = undefined,

        /// Userdata passed to some of the callbacks.
        userdata: ?*anyopaque = null,

        /// The scale factor of the screen.
        scale_factor: f64 = 1,

        /// The font size to inherit. If 0, default font size will be used.
        font_size: f32 = 0,

        /// The working directory to load into.
        working_directory: ?[*:0]const u8 = null,

        /// The command to run in the new surface. If this is set then
        /// the "wait-after-command" option is also automatically set to true,
        /// since this is used for scripting.
        ///
        /// This command always run in a shell (e.g. via `/bin/sh -c`),
        /// despite Ghostty allowing directly executed commands via config.
        /// This is a legacy thing and we should probably change it in the
        /// future once we have a concrete use case.
        command: ?[*:0]const u8 = null,

        /// Extra environment variables to set for the surface.
        env_vars: ?[*]EnvVar = null,
        env_var_count: usize = 0,

        /// Input to send to the command after it is started.
        initial_input: ?[*:0]const u8 = null,

        /// Wait after the command exits
        wait_after_command: bool = false,

        /// Context for the new surface
        context: apprt.surface.NewSurfaceContext = .window,

        /// Remote-machine backend (remote-machines design §3.2). When non-null,
        /// the surface is constructed with the `.remote` termio backend riding
        /// on this caller-owned connection instead of the local exec/pty
        /// backend. The connection must already be started and
        /// handshake-complete. It is NOT freed when the surface is freed.
        ///
        /// C type: `ghostty_remote_connection_t` (opaque `void*`), as returned
        /// by `ghostty_remote_connection_new`.
        connection: ?*RemoteConnectionHandle = null,

        /// The agent session to ATTACH to (re-attach to an existing remote
        /// session); null ⇒ OPEN a brand-new session. Ignored when `connection`
        /// is null.
        ///
        /// C type: `const char*`.
        session_id: ?[*:0]const u8 = null,

        /// Explicit REMOTE working directory for an OPEN-new remote session
        /// (§WP4): the cwd ON THE REMOTE MACHINE, set by the split/tab path from
        /// an on-demand cwd query of the parent pane. Forwarded verbatim to the
        /// agent's OPEN. DISTINCT from `working_directory` (a local path that
        /// must never reach a remote agent). Null ⇒ no remote cwd hint.
        ///
        /// C type: `const char*`.
        remote_working_directory: ?[*:0]const u8 = null,

        /// The shell to run for an OPEN-new remote session (per-host default
        /// or an explicit `--shell`): a path ON THE REMOTE MACHINE (e.g.
        /// `powershell.exe`, `wsl.exe`, `/bin/zsh`), forwarded verbatim in the
        /// agent's OPEN. Null ⇒ the agent resolves its own default shell.
        /// Ignored when `connection` is null.
        ///
        /// C type: `const char*`.
        remote_shell: ?[*:0]const u8 = null,

        /// True ⇒ the connection is the LOCAL agent (same machine + same Ghostty
        /// bundle as this viewer), so it is safe to inject ghostty shell
        /// integration and the per-pane GHOSTTY_* env for the pane (T04b). The
        /// apprt sets this from `Machine.isLocalMachine`. Ignored when
        /// `connection` is null; NEVER set for a cross-machine window (a macOS
        /// resources path / ZDOTDIR is meaningless on a different-OS agent).
        ///
        /// C type: `bool`.
        remote_local_shell_integration: bool = false,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        self.* = .{
            .app = app,
            .platform = try .init(opts.platform_tag, opts.platform),
            .userdata = opts.userdata,
            .core_surface = undefined,
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = -1, .y = -1 },
            // Remote backend handle (remote-machines design §3.2). Recorded
            // before `core_surface.init` so `remoteBackend()` can branch the
            // backend construction (Surface.zig).
            .remote_connection = opts.connection,
            .remote_session_id = opts.session_id,
            .remote_working_directory = opts.remote_working_directory,
            .remote_shell = opts.remote_shell,
            .remote_local_shell_integration = opts.remote_local_shell_integration,
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
        defer config.deinit();

        // If we have a working directory from the options then we set it.
        if (opts.working_directory) |c_wd| {
            const wd = std.mem.sliceTo(c_wd, 0);
            if (wd.len > 0) wd: {
                // `openDirAbsolute` ASSERTS the path is absolute (an `unreachable`
                // panic, NOT a catchable error) before it opens anything. A
                // non-absolute path here — e.g. a remote pane's `C:\…` cwd that
                // leaked into the local working_directory — would crash the whole
                // app instead of logging. Skip any non-absolute path defensively
                // so a bad cwd can never bring down the process.
                if (!std.fs.path.isAbsolute(wd)) {
                    log.warn(
                        "requested working directory is not absolute on this platform; ignoring dir={s}",
                        .{wd},
                    );
                    break :wd;
                }
                var dir = std.fs.openDirAbsolute(wd, .{}) catch |err| {
                    log.warn(
                        "error opening requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };
                defer dir.close();

                const stat = dir.stat() catch |err| {
                    log.warn(
                        "failed to stat requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };

                if (stat.kind != .directory) {
                    log.warn(
                        "requested working directory is not a directory dir={s}",
                        .{wd},
                    );
                    break :wd;
                }

                var wd_val: configpkg.WorkingDirectory = .{ .path = wd };
                if (wd_val.finalize(config.arenaAlloc())) |_| {
                    config.@"working-directory" = wd_val;
                } else |err| {
                    log.warn(
                        "error finalizing working directory config dir={s} err={}",
                        .{ wd_val.path, err },
                    );
                }
            }
        }

        // If we have a command from the options then we set it.
        if (opts.command) |c_command| {
            const cmd = std.mem.sliceTo(c_command, 0);
            if (cmd.len > 0) {
                config.command = .{ .shell = cmd };
                config.@"wait-after-command" = true;
            }
        }

        // Apply any environment variables that were requested.
        if (opts.env_var_count > 0) {
            const alloc = config.arenaAlloc();
            for (opts.env_vars.?[0..opts.env_var_count]) |env_var| {
                const key = std.mem.sliceTo(env_var.key, 0);
                const value = std.mem.sliceTo(env_var.value, 0);
                try config.env.map.put(
                    alloc,
                    try alloc.dupeZ(u8, key),
                    try alloc.dupeZ(u8, value),
                );
            }
        }

        // If we have an initial input then we set it.
        if (opts.initial_input) |c_input| {
            const alloc = config.arenaAlloc();

            // We need to escape the string because the "raw" field
            // expects a Zig string.
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            try std.zig.stringEscape(
                std.mem.sliceTo(c_input, 0),
                &buf.writer,
            );

            config.input.list.clearRetainingCapacity();
            try config.input.list.append(
                alloc,
                .{ .raw = try buf.toOwnedSliceSentinel(0) },
            );
        }

        // Wait after command
        if (opts.wait_after_command) {
            config.@"wait-after-command" = true;
        }

        // Initialize our surface right away. We're given a view that is
        // ready to use.
        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();

        // If our options requested a specific font-size, set that.
        if (opts.font_size != 0) {
            var font_size = self.core_surface.font_size;
            font_size.points = opts.font_size;
            try self.core_surface.setFontSize(font_size);
        }
    }

    pub fn deinit(self: *Surface) void {
        // Shut down our inspector
        self.freeInspector();

        // Free our title
        if (self.title) |v| self.app.core_app.alloc.free(v);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
    }

    /// Initialize the inspector instance. A surface can only have one
    /// inspector at any given time, so this will return the previous inspector
    /// if it was already initialized.
    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| return v;

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }

    pub fn freeInspector(self: *Surface) void {
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_alive: bool) void {
        const func = self.app.opts.close_surface orelse {
            log.info("runtime embedder does not support closing a surface", .{});
            return;
        };

        func(self.userdata, process_alive);
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        return switch (clipboard_type) {
            .standard => true,
            .selection, .primary => self.app.opts.supports_selection_clipboard,
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        // We need to allocate to get a pointer to store our clipboard request
        // so that it is stable until the read_clipboard callback and call
        // complete_clipboard_request. This sucks but clipboard requests aren't
        // high throughput so it's probably fine.
        const alloc = self.app.core_app.alloc;
        const state_ptr = try alloc.create(apprt.ClipboardRequest);
        errdefer alloc.destroy(state_ptr);
        state_ptr.* = state;

        const started = self.app.opts.read_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            state_ptr,
        );
        if (!started) {
            alloc.destroy(state_ptr);
            return false;
        }

        return true;
    }

    fn completeClipboardRequest(
        self: *Surface,
        str: [:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        const alloc = self.app.core_app.alloc;

        // Attempt to complete the request, but we may request
        // confirmation.
        self.core_surface.completeClipboardRequest(
            state.*,
            str,
            confirmed,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                self.app.opts.confirm_read_clipboard(
                    self.userdata,
                    str.ptr,
                    state,
                    state.*,
                );

                return;
            },

            else => log.err("error completing clipboard request err={}", .{err}),
        };

        // We don't defer this because the clipboard confirmation route
        // preserves the clipboard request.
        alloc.destroy(state);
    }

    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        const alloc = self.app.core_app.alloc;
        const array = try alloc.alloc(CAPI.ClipboardContent, contents.len);
        defer alloc.free(array);
        for (contents, 0..) |content, i| {
            array[i] = .{
                .mime = content.mime,
                .data = content.data,
            };
        }

        self.app.opts.write_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            array.ptr,
            array.len,
            confirm,
        );
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn draw(self: *Surface) void {
        self.core_surface.draw() catch |err| {
            log.err("error in draw err={}", .{err});
            return;
        };
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        // We are an embedded API so the caller can send us all sorts of
        // garbage. We want to make sure that the float values are valid
        // and we don't want to support fractional scaling below 1.
        const x_scaled = @max(1, if (std.math.isNan(x)) 1 else x);
        const y_scaled = @max(1, if (std.math.isNan(y)) 1 else y);

        self.content_scale = .{
            .x = @floatCast(x_scaled),
            .y = @floatCast(y_scaled),
        };

        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.err("error in content scale callback err={}", .{err});
            return;
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        // Runtimes sometimes generate superfluous resize events even
        // if the size did not actually change (SwiftUI). We check
        // that the size actually changed from what we last recorded
        // since resizes are expensive.
        if (self.size.width == width and self.size.height == height) return;

        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) void {
        self.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) bool {
        return self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return false;
        };
    }

    pub fn mousePressureCallback(
        self: *Surface,
        stage: input.MousePressureStage,
        pressure: f64,
    ) void {
        self.core_surface.mousePressureCallback(stage, pressure) catch |err| {
            log.err("error in mouse pressure callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(
        self: *Surface,
        x: f64,
        y: f64,
        mods: input.Mods,
    ) void {
        // Convert our unscaled x/y to scaled.
        const pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        // There are cases where the platform reports a mouse motion event
        // without the cursor actually moving. For example, on macOS, updating
        // the window title can trigger a phantom mouse-move event at the same
        // coordinates. This can cause the mouse to incorrectly unhide when
        // mouse-hide-while-typing is enabled (commonly seen with TUI apps
        // like Zellij that frequently update the title). To prevent incorrect
        // behavior, we only continue with callback logic if the cursor has
        // actually moved.
        if (@abs(self.cursor_pos.x - pos.x) < 1 and
            @abs(self.cursor_pos.y - pos.y) < 1) return;

        self.cursor_pos = pos;

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) void {
        _ = self.core_surface.preeditCallback(preedit_) catch |err| {
            log.err("error in preedit callback err={}", .{err});
            return;
        };
    }

    pub fn textCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textCallback(text) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    pub fn occlusionCallback(self: *Surface, visible: bool) void {
        self.core_surface.occlusionCallback(visible) catch |err| {
            log.err("error in occlusion callback err={}", .{err});
            return;
        };
    }

    fn queueInspectorRender(self: *Surface) void {
        _ = self.app.performAction(
            .{ .surface = &self.core_surface },
            .render_inspector,
            {},
        ) catch |err| {
            log.err("error rendering the inspector err={}", .{err});
            return;
        };
    }

    pub fn newSurfaceOptions(self: *const Surface, context: apprt.surface.NewSurfaceContext) apprt.Surface.Options {
        const font_size: f32 = font_size: {
            if (!self.app.config.@"window-inherit-font-size") break :font_size 0;
            break :font_size self.core_surface.font_size.points;
        };

        const working_directory: ?[*:0]const u8 = wd: {
            if (!apprt.surface.shouldInheritWorkingDirectory(context, &self.app.config)) break :wd null;
            // A remote pane's pwd is a path ON THE REMOTE MACHINE (e.g. a Windows
            // `C:\…` path). It is meaningless — and may not even be absolute — on
            // the LOCAL filesystem, so it must NEVER be lowered into the local
            // `working_directory` (which `Surface.init` feeds to `openDirAbsolute`,
            // a hard `isAbsolute` assert). Remote cwd inheritance is carried
            // separately via `remote_working_directory`, resolved by an on-demand
            // agent cwd query in the apprt (§WP4). Local panes are unaffected.
            if (self.remote_connection != null) break :wd null;
            const cwd = self.core_surface.pwd(self.app.core_app.alloc) catch null orelse break :wd null;
            defer self.app.core_app.alloc.free(cwd);
            break :wd self.app.core_app.alloc.dupeZ(u8, cwd) catch null;
        };

        return .{
            .font_size = font_size,
            .working_directory = working_directory,
            .context = context,
        };
    }

    /// Returns the remote-machine backend for this surface, or null for a local
    /// surface (remote-machines design §3.2). `CoreSurface.init` calls this at
    /// the single backend-construction site to decide between the `.remote` and
    /// `.exec` backends. The connection is borrowed (caller-owned); `session_id`
    /// is borrowed for the duration of the construction call only.
    pub fn remoteBackend(self: *const Surface) ?CoreSurface.RemoteBackend {
        const handle = self.remote_connection orelse return null;

        // The handle exists but the live transport (SSH or TCP) has not been
        // established yet (the caller must `_start` / `_new_tcp` it before
        // building a remote surface). Without a live connection we cannot build
        // the `.remote` backend; fall back to local rather than crashing.
        const conn = handle.conn() orelse {
            log.warn(
                "remote surface requested but connection not established; " ++
                    "falling back to local backend (call _start / _new_tcp first)",
                .{},
            );
            return null;
        };

        return .{
            .connection = conn,
            .session_id = if (self.remote_session_id) |s|
                std.mem.sliceTo(s, 0)
            else
                null,
            // The EXPLICIT remote cwd (split/tab inheritance, §WP4). Empty ⇒ null
            // so a stray empty string never forwards a cwd.
            .working_directory = if (self.remote_working_directory) |w| wd: {
                const s = std.mem.sliceTo(w, 0);
                break :wd if (s.len > 0) s else null;
            } else null,
            // The REMOTE shell (per-host default / explicit --shell). Empty ⇒
            // null so a stray empty string never forwards a shell.
            .shell = if (self.remote_shell) |sh| sh: {
                const s = std.mem.sliceTo(sh, 0);
                break :sh if (s.len > 0) s else null;
            } else null,
            // Only the LOCAL agent gets ghostty shell integration injected (T04b).
            .local_shell_integration = self.remote_local_shell_integration,
        };
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
        const alloc = self.app.core_app.alloc;
        var env = try internal_os.getEnvMap(alloc);
        errdefer env.deinit();

        if (comptime builtin.target.os.tag.isDarwin()) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                env.remove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                env.remove("__XPC_DYLD_LIBRARY_PATH");
                env.remove("DYLD_FRAMEWORK_PATH");
                env.remove("DYLD_INSERT_LIBRARIES");
                env.remove("DYLD_LIBRARY_PATH");
                env.remove("LD_LIBRARY_PATH");
                env.remove("SECURITYSESSIONID");
                env.remove("XPC_SERVICE_NAME");
            }

            // Remove this so that running `ghoztty` within Ghoztty works.
            env.remove("GHOSTTY_MAC_LAUNCH_SOURCE");

            // If we were launched from the desktop then we want to
            // remove the LANGUAGE env var so that we don't inherit
            // our translation settings for Ghostty. If we aren't from
            // the desktop then we didn't set our LANGUAGE var so we
            // don't need to remove it.
            if (internal_os.launchedFromDesktop()) env.remove("LANGUAGE");
        }

        return env;
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};

/// Inspector is the state required for the terminal inspector. A terminal
/// inspector is 1:1 with a Surface.
pub const Inspector = struct {
    const cimgui = @import("dcimgui");

    surface: *Surface,
    ig_ctx: *cimgui.c.ImGuiContext,
    backend: ?Backend = null,
    content_scale: f64 = 1,

    /// Our previous instant used to calculate delta time for animations.
    instant: ?std.time.Instant = null,

    const Backend = enum {
        metal,

        pub fn deinit(self: Backend) void {
            switch (self) {
                .metal => if (builtin.target.os.tag.isDarwin()) cimgui.ImGui_ImplMetal_Shutdown(),
            }
        }
    };

    pub fn init(surface: *Surface) !Inspector {
        const ig_ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
        errdefer cimgui.c.ImGui_DestroyContext(ig_ctx);
        cimgui.c.ImGui_SetCurrentContext(ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.BackendPlatformName = "ghostty_embedded";

        // Setup our core inspector
        CoreInspector.setup();
        surface.core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector err={}", .{err});
        };

        return .{
            .surface = surface,
            .ig_ctx = ig_ctx,
        };
    }

    pub fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        if (self.backend) |v| v.deinit();
        cimgui.c.ImGui_DestroyContext(self.ig_ctx);
    }

    /// Queue a render for the next frame.
    pub fn queueRender(self: *Inspector) void {
        self.surface.queueInspectorRender();
    }

    /// Initialize the inspector for a metal backend.
    pub fn initMetal(self: *Inspector, device: objc.Object) bool {
        defer device.msgSend(void, objc.sel("release"), .{});
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        if (self.backend) |v| {
            v.deinit();
            self.backend = null;
        }

        if (!cimgui.ImGui_ImplMetal_Init(device.value)) {
            log.warn("failed to initialize metal backend", .{});
            return false;
        }
        self.backend = .metal;

        log.debug("initialized metal backend", .{});
        return true;
    }

    pub fn renderMetal(
        self: *Inspector,
        command_buffer: objc.Object,
        desc: objc.Object,
    ) !void {
        defer {
            command_buffer.msgSend(void, objc.sel("release"), .{});
            desc.msgSend(void, objc.sel("release"), .{});
        }
        assert(self.backend == .metal);
        //log.debug("render", .{});

        // Setup our imgui frame. We need to render multiple frames to ensure
        // ImGui completes all its state processing. I don't know how to fix
        // this.
        for (0..2) |_| {
            cimgui.ImGui_ImplMetal_NewFrame(desc.value);
            try self.newFrame();
            cimgui.c.ImGui_NewFrame();

            // Build our UI
            render: {
                const surface = &self.surface.core_surface;
                const inspector = surface.inspector orelse break :render;
                inspector.render(surface);
            }

            // Render
            cimgui.c.ImGui_Render();
        }

        // MTLRenderCommandEncoder
        const encoder = command_buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});
        cimgui.ImGui_ImplMetal_RenderDrawData(
            cimgui.c.ImGui_GetDrawData(),
            command_buffer.value,
            encoder.value,
        );
    }

    pub fn updateContentScale(self: *Inspector, x: f64, y: f64) void {
        _ = y;
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        // Cache our scale because we use it for cursor position calculations.
        self.content_scale = x;

        // Setup a new style and scale it appropriately. We must use the
        // ImGuiStyle constructor to get proper default values (e.g.,
        // CurveTessellationTol) rather than zero-initialized values.
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, @floatCast(x));
        const active_style = cimgui.c.ImGui_GetStyle();
        active_style.* = style;
    }

    pub fn updateSize(self: *Inspector, width: u32, height: u32) void {
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
    }

    pub fn mouseButtonCallback(
        self: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        _ = mods;

        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        const imgui_button = switch (button) {
            .left => cimgui.c.ImGuiMouseButton_Left,
            .middle => cimgui.c.ImGuiMouseButton_Middle,
            .right => cimgui.c.ImGuiMouseButton_Right,
            else => return, // unsupported
        };

        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, imgui_button, action == .press);
    }

    pub fn scrollCallback(
        self: *Inspector,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // For precision scrolling (trackpads), the values are in pixels which
        // scroll way too fast. Scale them down to approximate discrete wheel
        // notches. imgui expects 1.0 to scroll ~5 lines of text.
        const scale: f64 = if (mods.precision) 0.1 else 1.0;
        cimgui.c.ImGuiIO_AddMouseWheelEvent(
            io,
            @floatCast(xoff * scale),
            @floatCast(yoff * scale),
        );
    }

    pub fn cursorPosCallback(self: *Inspector, x: f64, y: f64) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddMousePosEvent(
            io,
            @floatCast(x * self.content_scale),
            @floatCast(y * self.content_scale),
        );
    }

    pub fn focusCallback(self: *Inspector, focused: bool) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, focused);
    }

    pub fn textCallback(self: *Inspector, text: [:0]const u8) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, text.ptr);
    }

    pub fn keyCallback(
        self: *Inspector,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) !void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Update all our modifiers
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, mods.shift);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, mods.ctrl);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, mods.alt);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, mods.super);

        // Send our keypress
        if (key.imguiKey()) |imgui_key| {
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                imgui_key,
                action == .press or action == .repeat,
            );
        }
    }

    fn newFrame(self: *Inspector) !void {
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Determine our delta time
        const now = try std.time.Instant.now();
        io.DeltaTime = if (self.instant) |prev| delta: {
            const since_ns: f64 = @floatFromInt(now.since(prev));
            const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
            const since_s: f32 = @floatCast(since_ns / ns_per_s);
            break :delta @max(0.00001, since_s);
        } else (1.0 / 60.0);
        self.instant = now;
    }
};

// C API
pub const CAPI = struct {
    const global = &@import("../global.zig").state;

    /// This is the same as Surface.KeyEvent but this is the raw C API version.
    const KeyEvent = extern struct {
        action: input.Action,
        mods: c_int,
        consumed_mods: c_int,
        keycode: u32,
        text: ?[*:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert to Zig key event.
        fn keyEvent(self: KeyEvent) App.KeyEvent {
            return .{
                .action = self.action,
                .mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.mods))),
                )),
                .consumed_mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.consumed_mods))),
                )),
                .keycode = self.keycode,
                .text = if (self.text) |ptr| std.mem.sliceTo(ptr, 0) else null,
                .unshifted_codepoint = self.unshifted_codepoint,
                .composing = self.composing,
            };
        }
    };

    const SurfaceSize = extern struct {
        columns: u16,
        rows: u16,
        width_px: u32,
        height_px: u32,
        cell_width_px: u32,
        cell_height_px: u32,
    };

    // ghostty_clipboard_content_s
    const ClipboardContent = extern struct {
        mime: [*:0]const u8,
        data: [*:0]const u8,
    };

    // ghostty_text_s
    const Text = extern struct {
        tl_px_x: f64,
        tl_px_y: f64,
        offset_start: u32,
        offset_len: u32,
        text: ?[*:0]const u8,
        text_len: usize,

        pub fn deinit(self: *Text) void {
            if (self.text) |ptr| {
                global.alloc.free(ptr[0..self.text_len :0]);
            }
        }
    };

    // ghostty_point_s
    const Point = extern struct {
        tag: Tag,
        coord_tag: CoordTag,
        x: u32,
        y: u32,

        const Tag = enum(c_int) {
            active = 0,
            viewport = 1,
            screen = 2,
            history = 3,
        };

        const CoordTag = enum(c_int) {
            exact = 0,
            top_left = 1,
            bottom_right = 2,
        };

        fn pin(
            self: Point,
            screen: *const terminal.Screen,
        ) ?terminal.Pin {
            // The core point tag.
            const tag: terminal.point.Tag = switch (self.tag) {
                inline else => |tag| @field(
                    terminal.point.Tag,
                    @tagName(tag),
                ),
            };

            // Clamp our point to the screen bounds.
            const clamped_x = @min(self.x, screen.pages.cols -| 1);
            const clamped_y = @min(self.y, screen.pages.rows -| 1);

            return switch (self.coord_tag) {
                // Exact coordinates require a specific pin.
                .exact => exact: {
                    const pt_x = std.math.cast(
                        terminal.size.CellCountInt,
                        clamped_x,
                    ) orelse std.math.maxInt(terminal.size.CellCountInt);

                    const pt: terminal.Point = switch (tag) {
                        inline else => |v| @unionInit(
                            terminal.Point,
                            @tagName(v),
                            .{ .x = pt_x, .y = clamped_y },
                        ),
                    };

                    break :exact screen.pages.pin(pt) orelse null;
                },

                .top_left => screen.pages.getTopLeft(tag),

                .bottom_right => screen.pages.getBottomRight(tag),
            };
        }
    };

    // ghostty_selection_s
    const Selection = extern struct {
        tl: Point,
        br: Point,
        rectangle: bool,

        fn core(
            self: Selection,
            screen: *const terminal.Screen,
        ) ?terminal.Selection {
            return .{
                .bounds = .{ .untracked = .{
                    .start = self.tl.pin(screen) orelse return null,
                    .end = self.br.pin(screen) orelse return null,
                } },
                .rectangle = self.rectangle,
            };
        }
    };

    // Reference the conditional exports based on target platform
    // so they're included in the C API.
    comptime {
        if (builtin.target.os.tag.isDarwin()) {
            _ = Darwin;
        }
    }

    /// Create a new app.
    export fn ghostty_app_new(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) ?*App {
        return app_new_(opts, config) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) !*App {
        const core_app = try CoreApp.create(global.alloc);
        errdefer core_app.destroy();

        // Create our runtime app
        var app = try global.alloc.create(App);
        errdefer global.alloc.destroy(app);
        try app.init(core_app, config, opts.*);
        errdefer app.terminate();

        return app;
    }

    /// Tick the event loop. This should be called whenever the "wakeup"
    /// callback is invoked for the runtime.
    export fn ghostty_app_tick(v: *App) void {
        v.core_app.tick(v) catch |err| {
            log.err("error app tick err={}", .{err});
        };
    }

    /// Return the userdata associated with the app.
    export fn ghostty_app_userdata(v: *App) ?*anyopaque {
        return v.opts.userdata;
    }

    export fn ghostty_app_free(v: *App) void {
        const core_app = v.core_app;
        v.terminate();
        global.alloc.destroy(v);
        core_app.destroy();
    }

    /// Update the focused state of the app.
    export fn ghostty_app_set_focus(
        app: *App,
        focused: bool,
    ) void {
        app.focusEvent(focused);
    }

    /// Notify the app of a global keypress capture. This will return
    /// true if the key was captured by the app, in which case the caller
    /// should not process the key.
    export fn ghostty_app_key(
        app: *App,
        event: KeyEvent,
    ) bool {
        return app.keyEvent(.app, event.keyEvent()) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_config_key_is_binding(
        config: *Config,
        event: KeyEvent,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        return config.keyEventIsBinding(core_event);
    }

    /// Notify the app that the keyboard was changed. This causes the
    /// keyboard layout to be reloaded from the OS.
    export fn ghostty_app_keyboard_changed(v: *App) void {
        v.reloadKeymap() catch |err| {
            log.err("error reloading keyboard map err={}", .{err});
            return;
        };
    }

    /// Open the configuration.
    export fn ghostty_app_open_config(v: *App) void {
        _ = v.performAction(.app, .open_config, {}) catch |err| {
            log.err("error reloading config err={}", .{err});
            return;
        };
    }

    /// Update the configuration to the provided config. This will propagate
    /// to all surfaces as well.
    export fn ghostty_app_update_config(
        v: *App,
        config: *const Config,
    ) void {
        v.core_app.updateConfig(v, config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the app needs to confirm quitting.
    export fn ghostty_app_needs_confirm_quit(v: *App) bool {
        return v.core_app.needsConfirmQuit();
    }

    /// Returns true if the app has global keybinds.
    export fn ghostty_app_has_global_keybinds(v: *App) bool {
        return v.hasGlobalKeybinds();
    }

    /// Update the color scheme of the app.
    export fn ghostty_app_set_color_scheme(v: *App, scheme_raw: c_int) void {
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_surface_set_color_scheme value={}",
                .{scheme_raw},
            );
            return;
        };

        v.core_app.colorSchemeEvent(v, scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    /// Returns initial surface options.
    export fn ghostty_surface_config_new() apprt.Surface.Options {
        return .{};
    }

    /// Create a new surface as part of an app.
    export fn ghostty_surface_new(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) ?*Surface {
        return surface_new_(app, opts) catch |err| {
            log.err("error initializing surface err={}", .{err});
            // Log the error-return trace addresses (T06b diagnostics): a live
            // incident produced a persistent, unexplained error.OutOfMemory
            // from this path; if it recurs these addresses attribute the
            // failing `try` (symbolicate offline with atos against this
            // binary). Debug builds only (release strips the trace).
            if (@errorReturnTrace()) |trace| {
                const n = @min(trace.index, trace.instruction_addresses.len);
                for (trace.instruction_addresses[0..n], 0..) |addr, i| {
                    log.err("surface init error trace[{d}] addr=0x{x}", .{ i, addr });
                }
            }
            return null;
        };
    }

    fn surface_new_(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) !*Surface {
        return try app.newSurface(opts.*);
    }

    export fn ghostty_surface_free(ptr: *Surface) void {
        ptr.app.closeSurface(ptr);
    }

    /// Returns the userdata associated with the surface.
    export fn ghostty_surface_userdata(surface: *Surface) ?*anyopaque {
        return surface.userdata;
    }

    /// Sets (or, with null, clears) the userdata associated with the surface.
    /// The apprt clears it when the host view backing the surface is torn down
    /// but the surface's own free is deferred: a callback (e.g. SET_TITLE)
    /// delivered on the host's run loop during that window would otherwise
    /// resurrect the freed host object via a stale `userdata` back-pointer.
    export fn ghostty_surface_set_userdata(surface: *Surface, ud: ?*anyopaque) void {
        surface.userdata = ud;
    }

    /// Returns the app associated with a surface.
    export fn ghostty_surface_app(surface: *Surface) *App {
        return surface.app;
    }

    /// Returns the config to use for surfaces that inherit from this one.
    export fn ghostty_surface_inherited_config(
        surface: *Surface,
        source: apprt.surface.NewSurfaceContext,
    ) Surface.Options {
        return surface.newSurfaceOptions(source);
    }

    /// Update the configuration to the provided config for only this surface.
    export fn ghostty_surface_update_config(
        surface: *Surface,
        config: *const Config,
    ) void {
        surface.core_surface.updateConfig(config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the surface needs to confirm quitting.
    export fn ghostty_surface_needs_confirm_quit(surface: *Surface) bool {
        return surface.core_surface.needsConfirmQuit();
    }

    /// Mark whether freeing this surface should CLOSE its remote/agent session
    /// (terminate the child + free it agent-side) instead of the default DETACH
    /// (keep-alive for re-attach). Set on user-initiated close; never on quit.
    /// No-op for local exec surfaces.
    export fn ghostty_surface_set_session_close_intent(
        surface: *Surface,
        close_on_exit: bool,
    ) void {
        surface.core_surface.setSessionCloseIntent(close_on_exit);
    }

    /// Returns true if the surface process has exited.
    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }

    /// Returns true if the surface has a selection.
    export fn ghostty_surface_has_selection(surface: *Surface) bool {
        return surface.core_surface.hasSelection();
    }

    /// Same as ghostty_surface_read_text but reads from the user selection,
    /// if any.
    export fn ghostty_surface_read_selection(
        surface: *Surface,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        // If we don't have a selection, do nothing.
        const core_sel = core_surface.io.terminal.screens.active.selection orelse return false;

        // Read the text from the selection.
        return readTextLocked(surface, core_sel, result);
    }

    /// Read some arbitrary text from the surface.
    ///
    /// This is an expensive operation so it shouldn't be called too
    /// often. We recommend that callers cache the result and throttle
    /// calls to this function.
    export fn ghostty_surface_read_text(
        surface: *Surface,
        sel: Selection,
        result: *Text,
    ) bool {
        surface.core_surface.renderer_state.mutex.lock();
        defer surface.core_surface.renderer_state.mutex.unlock();

        const core_sel = sel.core(
            surface.core_surface.renderer_state.terminal.screens.active,
        ) orelse return false;

        return readTextLocked(surface, core_sel, result);
    }

    fn readTextLocked(
        surface: *Surface,
        core_sel: terminal.Selection,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;

        // Get our text directly from the core surface.
        const text = core_surface.dumpTextLocked(
            global.alloc,
            core_sel,
        ) catch |err| {
            log.warn("error reading text err={}", .{err});
            return false;
        };

        const vp: CoreSurface.Text.Viewport = text.viewport orelse .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
        };

        result.* = .{
            .tl_px_x = vp.tl_px_x,
            .tl_px_y = vp.tl_px_y,
            .offset_start = vp.offset_start,
            .offset_len = vp.offset_len,
            .text = text.text.ptr,
            .text_len = text.text.len,
        };

        return true;
    }

    export fn ghostty_surface_free_text(_: *Surface, ptr: *Text) void {
        ptr.deinit();
    }

    // -------------------------------------------------------------------------
    // Remote machines (remote-machines design §3.5/§3.2). The C ABI the Swift
    // app binds to for the remote-connection lifecycle. WP3: the live SSH dial
    // is not implemented yet — `_start` returns false ("not yet implemented");
    // the rest of the ABI is real-shaped so the Swift binding is stable.
    // -------------------------------------------------------------------------

    /// C type: `ghostty_remote_config_s`. Dial parameters for a remote
    /// connection key (host, user, port, jump-chain).
    const RemoteConfigC = extern struct {
        host: ?[*:0]const u8 = null,
        user: ?[*:0]const u8 = null,
        port: u16 = 0,
        jump: ?[*:0]const u8 = null,
    };

    /// Create a remote connection handle from dial parameters. Returns null on
    /// allocation failure or invalid parameters (e.g. a null/empty host). The
    /// handle is NOT connected yet; call `ghostty_remote_connection_start`.
    export fn ghostty_remote_connection_new(
        cfg: *const RemoteConfigC,
    ) ?*RemoteConnectionHandle {
        const host_c = cfg.host orelse {
            log.warn("ghostty_remote_connection_new: host is required", .{});
            return null;
        };
        const host = std.mem.sliceTo(host_c, 0);
        if (host.len == 0) {
            log.warn("ghostty_remote_connection_new: host is empty", .{});
            return null;
        }
        const user = if (cfg.user) |u| std.mem.sliceTo(u, 0) else null;
        const jump = if (cfg.jump) |j| std.mem.sliceTo(j, 0) else null;

        return RemoteConnectionHandle.create(
            global.alloc,
            host,
            user,
            cfg.port,
            jump,
        ) catch |err| {
            log.err("ghostty_remote_connection_new failed err={}", .{err});
            return null;
        };
    }

    /// Start the connection: dial SSH (two `ssh` subprocesses sharing one
    /// ControlMaster — control + data channels, §4.3), spawn the reader/writer
    /// threads, and send the client HELLO. Returns true on success.
    ///
    /// Idempotent: calling it again on an already-started handle is a no-op that
    /// returns true. The handshake itself is awaited separately via
    /// `_wait_handshake` (this only confirms the dial + thread spawn succeeded).
    export fn ghostty_remote_connection_start(
        handle: *RemoteConnectionHandle,
    ) bool {
        if (handle.transport != null) return true; // already dialed (ssh)
        // A TCP handle (`_new_tcp`) is already fully established (dial completed
        // the handshake), so `_start` is a no-op for it.
        if (handle.tcp != null) return true;

        const cfg: ssh_transport.DialConfig = .{
            .host = std.mem.sliceTo(handle.host, 0),
            .user = if (handle.user) |u| std.mem.sliceTo(u, 0) else null,
            .port = handle.port,
            .jump = if (handle.jump) |j| std.mem.sliceTo(j, 0) else null,
            // agent_path / askpass_path / session_id are wired in later
            // increments (agent push path + GUI askpass helper); the defaults
            // dial a bare `ghoztty-agent` with key-only auth, sufficient to
            // bring up the transport end-to-end against a deployed agent.
        };

        const transport = RemoteConnectionHandle.Transport.dial(handle.alloc, cfg) catch |err| {
            log.err("ghostty_remote_connection_start: ssh dial failed err={}", .{err});
            return false;
        };
        handle.transport = transport;
        return true;
    }

    /// Create a remote connection by dialing a TCP-listening `ghoztty-agent`
    /// directly at `host:port` (WP4). Unlike the SSH path, `tcp_dial.dial`
    /// connects the socket, folds the two logical lanes through a `ClientMux`,
    /// stands up the `Connection`, AND blocks through the HELLO handshake before
    /// returning — so the returned handle is FULLY ESTABLISHED. A subsequent
    /// `ghostty_remote_connection_start` is therefore a no-op (it returns true
    /// because `conn()` is already live); `_wait_handshake` will return true
    /// immediately. The handle stores the `Dialed` transport where `conn()`
    /// (and thus `remoteBackend`/`_wait_handshake`/`_latency_ms`/`_free`) reads
    /// it, exactly mirroring the SSH path.
    ///
    /// Returns null on a null/empty host or any dial/handshake failure. The
    /// encoding is pinned to `.raw` (a clean TCP/Tailscale hop, matching the
    /// agent's default).
    export fn ghostty_remote_connection_new_tcp(
        host: [*:0]const u8,
        port: u16,
    ) ?*RemoteConnectionHandle {
        const host_slice = std.mem.sliceTo(host, 0);
        if (host_slice.len == 0) {
            log.warn("ghostty_remote_connection_new_tcp: host is empty", .{});
            return null;
        }

        const alloc = global.alloc;

        // Record the dial parameters on the handle (host/port; no user/jump for
        // the direct TCP path) so the handle is uniform with the SSH one.
        const handle = RemoteConnectionHandle.create(
            alloc,
            host_slice,
            null,
            port,
            null,
        ) catch |err| {
            log.err("ghostty_remote_connection_new_tcp: handle alloc failed err={}", .{err});
            return null;
        };
        errdefer handle.destroy();

        // Dial: connect + mux + Connection + HELLO handshake (blocks). On any
        // failure the handle is destroyed (no transport was attached).
        const dialed = alloc.create(tcp_dial.Dialed) catch |err| {
            log.err("ghostty_remote_connection_new_tcp: Dialed alloc failed err={}", .{err});
            return null;
        };
        errdefer alloc.destroy(dialed);
        dialed.* = tcp_dial.dial(alloc, host_slice, port, .raw) catch |err| {
            log.err("ghostty_remote_connection_new_tcp: tcp dial failed err={}", .{err});
            return null;
        };

        handle.tcp = dialed;
        return handle;
    }

    /// Create a remote connection by dialing a `ghoztty-agent` listening on a
    /// local AF_UNIX stream socket at `path` (session-persistence hardening
    /// §5.2 / T09b). The unix analogue of `_new_tcp`: `tcp_dial.dialUnix`
    /// connects the 0600 socket, folds the two lanes through a `ClientMux`,
    /// stands up the `Connection`, AND blocks through the HELLO handshake before
    /// returning — so the returned handle is FULLY ESTABLISHED (a subsequent
    /// `_start` is a no-op; `_wait_handshake` returns true immediately). The
    /// established transport is stored in the SAME `handle.tcp` `Dialed` slot
    /// (it is transport-agnostic — a `Dialed` over an AF_UNIX socket behaves
    /// identically), so `conn()`/`remoteBackend`/`_wait_handshake`/`_latency_ms`/
    /// `_free` all read it with no other changes.
    ///
    /// The agent enforces a same-uid peercred gate on the unix socket (T09), so
    /// this only succeeds for the current user's own agent. Returns null on a
    /// null/empty `path` or any connect/handshake failure. The encoding is
    /// pinned to `.raw` (a clean local pipe, matching the agent's default).
    export fn ghostty_remote_connection_new_unix(
        path: [*:0]const u8,
    ) ?*RemoteConnectionHandle {
        const path_slice = std.mem.sliceTo(path, 0);
        if (path_slice.len == 0) {
            log.warn("ghostty_remote_connection_new_unix: path is empty", .{});
            return null;
        }

        const alloc = global.alloc;

        // Record the socket path in the handle's `host` slot (the dial-parameter
        // string) with port 0 so the handle is uniform with the TCP/SSH ones.
        // No user/jump for a local unix dial.
        const handle = RemoteConnectionHandle.create(
            alloc,
            path_slice,
            null,
            0,
            null,
        ) catch |err| {
            log.err("ghostty_remote_connection_new_unix: handle alloc failed err={}", .{err});
            return null;
        };
        errdefer handle.destroy();

        // Dial: connect + mux + Connection + HELLO handshake (blocks). On any
        // failure the handle is destroyed (no transport was attached).
        const dialed = alloc.create(tcp_dial.Dialed) catch |err| {
            log.err("ghostty_remote_connection_new_unix: Dialed alloc failed err={}", .{err});
            return null;
        };
        errdefer alloc.destroy(dialed);
        dialed.* = tcp_dial.dialUnix(alloc, path_slice, .raw) catch |err| {
            log.err("ghostty_remote_connection_new_unix: unix dial failed err={}", .{err});
            return null;
        };

        handle.tcp = dialed;
        return handle;
    }

    /// Create a remote connection by dialing a remote `ghoztty-agent` THROUGH a
    /// rendezvous relay. A native `wss://` WebSocket (`relay_dial`/`ws_client`)
    /// opens an authenticated connection to the relay (`base`) for `device`,
    /// giving a transparent framed byte pipe to the agent (no subprocess). Like
    /// the TCP path, this stands up the `ClientMux` + `Connection` AND blocks
    /// through the HELLO handshake before returning, so the returned handle is
    /// FULLY ESTABLISHED (a subsequent `_start` is a no-op; `_wait_handshake`
    /// returns true immediately). The handle stores the relay transport where
    /// `conn()` (and thus `remoteBackend`/`_wait_handshake`/`_latency_ms`/`_free`)
    /// reads it, exactly mirroring the TCP path.
    ///
    /// The relay auth token (`token`) is sent as `Authorization: Bearer <token>`.
    ///
    /// Returns null on a null/empty `base`/`device` or any dial/handshake
    /// failure. The encoding is pinned to `.raw` (a clean pipe, like TCP).
    export fn ghostty_remote_connection_new_relay(
        base: [*:0]const u8,
        device: [*:0]const u8,
        token: [*:0]const u8,
    ) ?*RemoteConnectionHandle {
        const base_slice = std.mem.sliceTo(base, 0);
        const device_slice = std.mem.sliceTo(device, 0);
        const token_slice = std.mem.sliceTo(token, 0);
        if (base_slice.len == 0) {
            log.warn("ghostty_remote_connection_new_relay: base is empty", .{});
            return null;
        }
        if (device_slice.len == 0) {
            log.warn("ghostty_remote_connection_new_relay: device is empty", .{});
            return null;
        }

        const alloc = global.alloc;

        // Record the dial parameters on the handle (device as the display host,
        // port 0; no user/jump for the relay path) so the handle is uniform.
        const handle = RemoteConnectionHandle.create(
            alloc,
            device_slice,
            null,
            0,
            null,
        ) catch |err| {
            log.err("ghostty_remote_connection_new_relay: handle alloc failed err={}", .{err});
            return null;
        };
        errdefer handle.destroy();

        // Dial: WebSocket + mux + Connection + HELLO handshake (blocks). On any
        // failure the handle is destroyed (no transport was attached).
        const dialed = alloc.create(relay_dial.Dialed) catch |err| {
            log.err("ghostty_remote_connection_new_relay: Dialed alloc failed err={}", .{err});
            return null;
        };
        errdefer alloc.destroy(dialed);
        dialed.* = relay_dial.dial(alloc, base_slice, device_slice, token_slice, .raw) catch |err| {
            log.err("ghostty_remote_connection_new_relay: relay dial failed err={}", .{err});
            return null;
        };

        handle.relay = dialed;
        return handle;
    }

    /// Block until the protocol handshake completes (or fails). Returns true if
    /// the handshake negotiated successfully. Only meaningful after a
    /// successful `_start`.
    export fn ghostty_remote_connection_wait_handshake(
        handle: *RemoteConnectionHandle,
    ) bool {
        const conn = handle.conn() orelse return false;
        _ = conn.waitHandshake() catch |err| {
            log.warn("remote connection handshake failed err={}", .{err});
            return false;
        };
        return true;
    }

    /// Current smoothed latency in milliseconds, or -1 if not yet measured or
    /// the connection isn't established.
    export fn ghostty_remote_connection_latency_ms(
        handle: *RemoteConnectionHandle,
    ) i32 {
        const conn = handle.conn() orelse return -1;
        const ms = conn.latencyMs() orelse return -1;
        return std.math.cast(i32, ms) orelse std.math.maxInt(i32);
    }

    /// Integer mirror of `connection.LinkState.State` for the C ABI (WP-D1).
    /// Kept in one place so `_state` and the state callback agree.
    fn linkStateToC(s: remote_connection.LinkState.State) i32 {
        return switch (s) {
            .connected => 0, // GHOSTTY_REMOTE_CONN_CONNECTED
            .degraded => 1, // GHOSTTY_REMOTE_CONN_DEGRADED
            .reconnecting => 2, // GHOSTTY_REMOTE_CONN_RECONNECTING
            .reattaching => 3, // GHOSTTY_REMOTE_CONN_REATTACHING
            .dead => 4, // GHOSTTY_REMOTE_CONN_DEAD
        };
    }

    /// Current link state of the connection (§5.1 FSM) as a
    /// `GHOSTTY_REMOTE_CONN_*` value, or -1 if the connection isn't established.
    export fn ghostty_remote_connection_state(
        handle: *RemoteConnectionHandle,
    ) i32 {
        const conn = handle.conn() orelse return -1;
        return linkStateToC(conn.state());
    }

    /// Zig-side `StateHandler` trampoline: map the FSM state to its C value and
    /// invoke the stored C callback. Fires under the connection's state lock on
    /// an internal thread — see `GhosttyRemoteStateCallback`.
    fn stateTrampoline(
        ctx: *anyopaque,
        _: *remote_connection.Connection,
        _: remote_connection.LinkState.State,
        new: remote_connection.LinkState.State,
    ) void {
        const tramp: *const RemoteConnectionHandle.StateTrampoline = @ptrCast(@alignCast(ctx));
        tramp.cb(linkStateToC(new), tramp.userdata);
    }

    /// Register (or, with a NULL callback, clear) an observer for connection
    /// link-state transitions (WP-D1). The callback fires on a connection
    /// thread with the state lock held — it must not call back into any
    /// `ghostty_remote_connection_*` API; hop to another queue. Clearing
    /// synchronizes with an in-flight invocation: once this returns with NULL,
    /// no further callback fires and `userdata` may be freed. A second register
    /// replaces the callback.
    export fn ghostty_remote_connection_set_state_callback(
        handle: *RemoteConnectionHandle,
        callback: ?GhosttyRemoteStateCallback,
        userdata: ?*anyopaque,
    ) void {
        const conn = handle.conn() orelse return;
        const cb = callback orelse {
            conn.clearStateHandler();
            handle.state_cb = null;
            return;
        };
        handle.state_cb = .{ .cb = cb, .userdata = userdata };
        conn.setStateHandler(&handle.state_cb.?, stateTrampoline);
    }

    /// The agent's self-reported hostname from its HELLO, or null if the peer
    /// didn't send one (older agent) or the handshake hasn't completed. The
    /// returned pointer is owned by the connection and valid until
    /// `ghostty_remote_connection_free`; callers should copy it immediately.
    export fn ghostty_remote_connection_hostname(
        handle: *RemoteConnectionHandle,
    ) ?[*:0]const u8 {
        const conn = handle.conn() orelse return null;
        const name = conn.peerHostname() orelse return null;
        return name.ptr;
    }

    /// Shut down and free the connection handle. Detaches all panes (remote
    /// sessions survive for later re-attach by session_id). The caller must
    /// ensure no surface still references this handle.
    export fn ghostty_remote_connection_free(handle: *RemoteConnectionHandle) void {
        handle.destroy();
    }

    /// On-demand query for a remote session's child working directory (§WP4).
    /// Sends `GET_CWD{session_id}` over the connection and blocks (bounded
    /// timeout) for the `CWD` reply. Returns a caller-owned UTF-8 `String` on
    /// success (free with `ghostty_string_free`), or an empty String if the
    /// connection isn't established, the session is unknown, the agent's cwd
    /// query failed, or the RPC timed out. Used by the Swift split/tab path so a
    /// new remote pane inherits the parent's cwd.
    export fn ghostty_remote_connection_query_cwd(
        handle: *RemoteConnectionHandle,
        session_id: [*:0]const u8,
    ) String {
        return queryCwdImpl(handle, session_id, null);
    }

    /// Like `ghostty_remote_connection_query_cwd` but with an explicit timeout in
    /// MILLISECONDS (0 ⇒ use the default 10s bound). The Swift GUI runs this on a
    /// BACKGROUND queue with a tight bound so a new remote frame's cwd inheritance
    /// never blocks the main thread and never waits long on a slow/wedged agent.
    export fn ghostty_remote_connection_query_cwd_timeout(
        handle: *RemoteConnectionHandle,
        session_id: [*:0]const u8,
        timeout_ms: u32,
    ) String {
        const ns: ?u64 = if (timeout_ms == 0)
            null
        else
            @as(u64, timeout_ms) * std.time.ns_per_ms;
        return queryCwdImpl(handle, session_id, ns);
    }

    /// Probe whether the agent still knows `session_id` (T06b session-restore
    /// liveness). Same GET_CWD RPC as `_query_cwd_timeout`, different contract:
    /// the result is TRI-STATE so the caller can apply a conservative drop
    /// policy. Returns:
    ///   -  1 ⇒ alive (the agent has the session; it is attachable)
    ///   -  0 ⇒ POSITIVELY dead (the agent replied and does not have it)
    ///   - -1 ⇒ inconclusive (timeout/transport failure, connection not
    ///          established, or an agent too old to disambiguate)
    /// Callers must only forget persisted state on 0 — never on -1.
    /// `timeout_ms == 0` ⇒ the default RPC bound. Blocking; call off the main
    /// thread.
    export fn ghostty_remote_connection_probe_session(
        handle: *RemoteConnectionHandle,
        session_id: [*:0]const u8,
        timeout_ms: u32,
    ) c_int {
        const conn = handle.conn() orelse return -1;
        const sid = std.mem.sliceTo(session_id, 0);
        if (sid.len == 0) return -1;

        const timeout_ns: u64 = if (timeout_ms == 0)
            10 * std.time.ns_per_s
        else
            @as(u64, timeout_ms) * std.time.ns_per_ms;

        return switch (conn.probeSessionTimeout(sid, timeout_ns)) {
            .alive => 1,
            .dead => 0,
            .unknown => -1,
        };
    }

    fn queryCwdImpl(
        handle: *RemoteConnectionHandle,
        session_id: [*:0]const u8,
        timeout_ns: ?u64,
    ) String {
        const conn = handle.conn() orelse return .empty;
        const sid = std.mem.sliceTo(session_id, 0);
        if (sid.len == 0) return .empty;

        const path = (if (timeout_ns) |ns|
            conn.queryCwdTimeout(sid, ns)
        else
            conn.queryCwd(sid)) catch |err| {
            log.debug("remote query_cwd failed err={}", .{err});
            return .empty;
        };
        defer handle.alloc.free(path);
        // Re-dupe into the C-API allocator (matching `ghostty_string_free`).
        const copy = handle.alloc.dupeZ(u8, path) catch return .empty;
        return .fromSlice(copy);
    }

    /// Enumerate every session the connected agent owns (T16 cross-machine
    /// session browse). Runs the same LIST_SESSIONS RPC the `+sessions` CLI
    /// uses, but against ANY dialed connection — local agent OR a relay
    /// machine — because the transport is resolved through `handle.conn()`.
    /// Returns a JSON array string (each element:
    /// `{id, alive, exit_code, attached, activity, pid, cwd, argv, title,
    /// created_at, last_activity, pinned}`), freed with `ghostty_string_free`.
    /// Returns `.empty` on any failure (no connection, timeout, malformed
    /// reply). `timeout_ms == 0` ⇒ the 5s default. BLOCKING; call off the main
    /// thread (mirror the `_proc_list` / `_query_cwd_timeout` usage).
    export fn ghostty_remote_connection_list_sessions(
        handle: *RemoteConnectionHandle,
        timeout_ms: u32,
    ) String {
        const conn = handle.conn() orelse return .empty;
        const timeout_ns: u64 = if (timeout_ms == 0)
            5 * std.time.ns_per_s
        else
            @as(u64, timeout_ms) * std.time.ns_per_ms;

        var roster = conn.requestSessions(timeout_ns) catch |err| {
            log.debug("remote list_sessions failed err={}", .{err});
            return .empty;
        };
        defer roster.deinit();

        // Serialize into a stable JSON shape (every key emitted, matching the
        // `+sessions --json` row) so the Swift side has a predictable decode.
        const SessionJsonRow = struct {
            id: []const u8,
            alive: bool,
            exit_code: ?i64,
            attached: bool,
            activity: []const u8,
            pid: i64,
            cwd: ?[]const u8,
            argv: ?[]const u8,
            title: ?[]const u8,
            created_at: i64,
            last_activity: i64,
            pinned: bool,
        };

        const rows = handle.alloc.alloc(SessionJsonRow, roster.sessions.len) catch return .empty;
        defer handle.alloc.free(rows);
        for (roster.sessions, 0..) |s, i| {
            rows[i] = .{
                .id = s.id,
                .alive = s.alive,
                .exit_code = s.exit_code,
                .attached = s.attached,
                .activity = s.activity,
                .pid = s.pid,
                .cwd = s.cwd,
                .argv = s.argv,
                .title = s.title,
                .created_at = s.created_at,
                .last_activity = s.last_activity,
                .pinned = s.pinned,
            };
        }

        const json = std.json.Stringify.valueAlloc(handle.alloc, rows, .{}) catch return .empty;
        defer handle.alloc.free(json);
        const copy = handle.alloc.dupeZ(u8, json) catch return .empty;
        return .fromSlice(copy);
    }

    /// Push (or, with `delete == true`, remove) an OPAQUE per-window layout blob
    /// to the connected agent (§5.4 cross-machine "Resume all", T18). `key` is the
    /// owning viewer's manifest-entry id; `blob` is the opaque layout JSON (empty
    /// / ignored when deleting); `session_ids` is a NEWLINE-separated list of the
    /// 32-hex session ids the blob references (used by the agent only to reap the
    /// blob once its sessions are gone). Returns 1 on success, 0 on any failure
    /// (no connection, RPC timeout, agent reported not-ok). `timeout_ms == 0` ⇒
    /// the 5s default. BLOCKING; call off the main thread.
    export fn ghostty_remote_connection_set_layout(
        handle: *RemoteConnectionHandle,
        key: [*:0]const u8,
        blob: [*:0]const u8,
        session_ids: [*:0]const u8,
        delete: bool,
        timeout_ms: u32,
    ) c_int {
        const conn = handle.conn() orelse return 0;
        const key_slice = std.mem.sliceTo(key, 0);
        if (key_slice.len == 0) return 0;
        const blob_slice = std.mem.sliceTo(blob, 0);
        const ids_raw = std.mem.sliceTo(session_ids, 0);

        const timeout_ns: u64 = if (timeout_ms == 0)
            5 * std.time.ns_per_s
        else
            @as(u64, timeout_ms) * std.time.ns_per_ms;

        // Split the newline-separated id list into a slice of slices (skipping
        // empty tokens). Bounded scratch owned by the C-API allocator.
        var ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ids.deinit(handle.alloc);
        if (!delete and ids_raw.len > 0) {
            var it = std.mem.splitScalar(u8, ids_raw, '\n');
            while (it.next()) |tok| {
                if (tok.len == 0) continue;
                ids.append(handle.alloc, tok) catch return 0;
            }
        }

        const blob_arg: ?[]const u8 = if (delete) null else blob_slice;
        conn.setLayout(key_slice, blob_arg, ids.items, delete, timeout_ns) catch |err| {
            log.debug("remote set_layout failed err={}", .{err});
            return 0;
        };
        return 1;
    }

    /// Fetch every stored layout blob from the connected agent (§5.4 "Resume
    /// all", T18) as a JSON object string `{"layouts":[{"key":...,"blob":...}]}`,
    /// freed with `ghostty_string_free`. The Swift resumer decodes it and the
    /// opaque blobs (each a `SessionLayoutManifest.Entry` JSON). Returns `.empty`
    /// on any failure. `timeout_ms == 0` ⇒ the 5s default. BLOCKING; call off the
    /// main thread.
    export fn ghostty_remote_connection_get_layouts(
        handle: *RemoteConnectionHandle,
        timeout_ms: u32,
    ) String {
        const conn = handle.conn() orelse return .empty;
        const timeout_ns: u64 = if (timeout_ms == 0)
            5 * std.time.ns_per_s
        else
            @as(u64, timeout_ms) * std.time.ns_per_ms;

        const payload = conn.requestLayouts(timeout_ns) catch |err| {
            log.debug("remote get_layouts failed err={}", .{err});
            return .empty;
        };
        defer conn.alloc.free(payload);
        // Re-dupe into the C-API allocator (matching `ghostty_string_free`).
        const copy = handle.alloc.dupeZ(u8, payload) catch return .empty;
        return .fromSlice(copy);
    }

    /// Zig-side `MetricsHandler` trampoline: marshal `protocol.HostMetrics` into a
    /// stack `ghostty_host_metrics_s` (optionals → sentinels) and invoke the stored
    /// C callback with the caller's `userdata`. `ctx` is the handle's
    /// `&metrics_cb.?` trampoline (pinned for the subscription's life). Fires on the
    /// connection's control-reader thread.
    fn metricsTrampoline(ctx: *anyopaque, host: remote_protocol.HostMetrics) void {
        const tramp: *const RemoteConnectionHandle.MetricsTrampoline = @ptrCast(@alignCast(ctx));
        const hm: ghostty_host_metrics_s = .{
            .cpu_pct = host.cpu_pct,
            .mem_used = host.mem_used,
            .mem_total = host.mem_total,
            .ncpu = host.ncpu,
            .uptime_s = host.uptime_s orelse 0,
            .load1 = host.load1 orelse -1,
        };
        tramp.cb(&hm, tramp.userdata);
    }

    /// Subscribe to the remote host's pushed metrics stream (§9.3). The agent then
    /// pushes a sample every `interval_ms`; each is delivered to `callback` (on the
    /// control-reader thread — see `GhosttyMetricsCallback`). Returns false if the
    /// connection isn't established. The caller MUST call
    /// `ghostty_remote_connection_metrics_unsubscribe` (or `_free`) before freeing
    /// anything `userdata` points at. A second subscribe replaces the callback.
    export fn ghostty_remote_connection_metrics_subscribe(
        handle: *RemoteConnectionHandle,
        interval_ms: u32,
        callback: GhosttyMetricsCallback,
        userdata: ?*anyopaque,
    ) bool {
        const conn = handle.conn() orelse return false;
        // Store the trampoline inline on the handle (pinned: the handle is stable),
        // then hand its address to `subscribeMetrics` as the Zig handler ctx.
        handle.metrics_cb = .{ .cb = callback, .userdata = userdata };
        conn.subscribeMetrics(interval_ms, &handle.metrics_cb.?, metricsTrampoline) catch {
            handle.metrics_cb = null;
            return false;
        };
        return true;
    }

    /// Stop the pushed metrics stream and clear the callback. After this returns no
    /// further metrics callback fires (the connection clears the handler slot under
    /// its write mutex). Safe to call when not subscribed (no-op).
    export fn ghostty_remote_connection_metrics_unsubscribe(
        handle: *RemoteConnectionHandle,
    ) void {
        if (handle.conn()) |conn| conn.unsubscribeMetrics();
        handle.metrics_cb = null;
    }

    /// A one-shot snapshot of the remote host's process table (§9.3). Mirrors a wire
    /// `PROC_SNAPSHOT`. The marshaling here is SYNCHRONOUS (the call blocks on the RPC
    /// reply up to `timeout_ms`); the Swift caller should run it OFF the main thread.
    /// `cpu_pct` is per-core (>100 is possible for a multithreaded process); divide by
    /// `host.ncpu` for a Task-Manager-style 0..100 total. `name`/`user`/`cmd` are
    /// always non-null C strings (empty string ⇒ unavailable, never NULL).
    export fn ghostty_remote_connection_proc_list(
        handle: *RemoteConnectionHandle,
        timeout_ms: u32,
    ) ghostty_proc_list_s {
        const empty: ghostty_proc_list_s = .{
            .ok = false,
            .truncated = false,
            .host = .{ .cpu_pct = 0, .mem_used = 0, .mem_total = 0, .ncpu = 0, .uptime_s = 0, .load1 = -1 },
            .procs = empty_procs_sentinel[0..].ptr,
            .procs_len = 0,
            .agent_pid = 0,
        };

        const conn = handle.conn() orelse return empty;
        const ns: u64 = if (timeout_ms == 0)
            10 * std.time.ns_per_s
        else
            @as(u64, timeout_ms) * std.time.ns_per_ms;

        var snap = conn.requestProcSnapshot(null, 0, ns) catch |err| {
            log.debug("remote proc_list failed err={}", .{err});
            return empty;
        };
        defer snap.deinit();

        const a = handle.alloc;
        // Single heap allocation for the proc array; each string is its own dupeZ.
        // On any partial failure free what we've built and return the empty sentinel
        // (so `_free` is always safe — it sees procs_len == 0).
        const arr = a.alloc(ghostty_proc_s, snap.procs.len) catch return empty;
        var filled: usize = 0;
        for (snap.procs, 0..) |p, i| {
            const name = a.dupeZ(u8, p.name) catch break;
            const user = a.dupeZ(u8, p.user orelse "") catch {
                a.free(name);
                break;
            };
            const cmd = a.dupeZ(u8, p.cmd orelse "") catch {
                a.free(name);
                a.free(user);
                break;
            };
            arr[i] = .{
                .pid = p.pid,
                .ppid = p.ppid,
                .cpu_pct = p.cpu_pct,
                .mem_bytes = p.mem_bytes,
                .name = name.ptr,
                .user = user.ptr,
                .cmd = cmd.ptr,
            };
            filled = i + 1;
        }
        if (filled != snap.procs.len) {
            // A string dup failed mid-way: free the rows we did build + the array.
            for (arr[0..filled]) |r| {
                a.free(std.mem.sliceTo(r.name, 0));
                a.free(std.mem.sliceTo(r.user, 0));
                a.free(std.mem.sliceTo(r.cmd, 0));
            }
            a.free(arr);
            return empty;
        }

        return .{
            .ok = true,
            .truncated = snap.truncated,
            .host = .{
                .cpu_pct = snap.host.cpu_pct,
                .mem_used = snap.host.mem_used,
                .mem_total = snap.host.mem_total,
                .ncpu = snap.host.ncpu,
                .uptime_s = snap.host.uptime_s orelse 0,
                .load1 = snap.host.load1 orelse -1,
            },
            .procs = arr.ptr,
            .procs_len = arr.len,
            .agent_pid = snap.agent_pid,
        };
    }

    /// Free a `ghostty_proc_list_s` returned by `_proc_list`. Frees every row's
    /// strings then the row array. Always safe: a failed/empty list has
    /// `procs_len == 0` and `procs` pointing at a static sentinel (never freed).
    export fn ghostty_remote_connection_proc_list_free(
        handle: *RemoteConnectionHandle,
        list: ghostty_proc_list_s,
    ) void {
        if (list.procs_len == 0) return;
        const a = handle.alloc;
        const rows = list.procs[0..list.procs_len];
        for (rows) |r| {
            a.free(std.mem.sliceTo(r.name, 0));
            a.free(std.mem.sliceTo(r.user, 0));
            a.free(std.mem.sliceTo(r.cmd, 0));
        }
        a.free(rows);
    }

    /// Kill a process on the REMOTE host by pid (§9.3 process control, inc 4).
    /// SYNCHRONOUS: blocks on the RPC reply up to `timeout_ms` (0 ⇒ default 5s), so
    /// run it OFF the main thread. `signal` is a NUL-terminated C string; an empty
    /// string ⇒ the agent's default terminate ("TERM"). On POSIX "TERM"/"KILL"
    /// select the signal; on Windows both map to TerminateProcess. Returns true iff
    /// the agent reported the kill succeeded; false on no connection / agent error /
    /// timeout.
    export fn ghostty_remote_connection_proc_kill(
        handle: *RemoteConnectionHandle,
        pid: i64,
        signal: [*:0]const u8,
        timeout_ms: u32,
    ) bool {
        const conn = handle.conn() orelse return false;
        const sig_slice = std.mem.sliceTo(signal, 0);
        const sig: ?[]const u8 = if (sig_slice.len == 0) null else sig_slice;
        const ns: u64 = if (timeout_ms == 0)
            5 * std.time.ns_per_s
        else
            @as(u64, timeout_ms) * std.time.ns_per_ms;

        var out = conn.killProc(pid, sig, ns) catch |err| {
            log.debug("remote proc_kill failed err={}", .{err});
            return false;
        };
        defer out.deinit();
        return out.ok;
    }

    /// Close (end) a session on the agent BY SESSION ID (the session-scoped
    /// equivalent of the pane CLOSE). SYNCHRONOUS: blocks on the RPC reply up to
    /// `timeout_ms` (0 => default 5s); run OFF the main thread. Returns true iff the
    /// agent confirmed the session was closed. Returns false when the peer agent
    /// does not advertise the `close_session` capability (older agent), on no
    /// connection, timeout, agent error, or an unknown session id.
    export fn ghostty_remote_connection_close_session(
        handle: *RemoteConnectionHandle,
        session_id: [*:0]const u8,
        timeout_ms: u32,
    ) bool {
        const conn = handle.conn() orelse return false;
        const id = std.mem.sliceTo(session_id, 0);
        const ns: u64 = if (timeout_ms == 0)
            5 * std.time.ns_per_s
        else
            @as(u64, timeout_ms) * std.time.ns_per_ms;

        const ok = conn.closeSession(id, ns) catch |err| {
            log.debug("remote close_session failed err={}", .{err});
            return false;
        };
        return ok;
    }

    /// Spawn a DETACHED process on the REMOTE host (§9.3 process control, inc 5).
    /// SYNCHRONOUS: blocks on the RPC reply up to `timeout_ms` (0 ⇒ default 5s); run
    /// OFF the main thread. `cmd` is run through the remote platform shell. `cwd` is
    /// a NUL-terminated C string; an empty string ⇒ the agent's default cwd. Returns
    /// the spawned pid (> 0), or -1 on failure (no connection / agent error /
    /// timeout). On Windows the "pid" is the integer value of the child's process
    /// HANDLE (matching the process-list ids).
    export fn ghostty_remote_connection_proc_spawn(
        handle: *RemoteConnectionHandle,
        cmd: [*:0]const u8,
        cwd: [*:0]const u8,
        timeout_ms: u32,
    ) i64 {
        const conn = handle.conn() orelse return -1;
        const cmd_slice = std.mem.sliceTo(cmd, 0);
        if (cmd_slice.len == 0) return -1;
        const cwd_slice = std.mem.sliceTo(cwd, 0);
        const cwd_opt: ?[]const u8 = if (cwd_slice.len == 0) null else cwd_slice;
        const ns: u64 = if (timeout_ms == 0)
            5 * std.time.ns_per_s
        else
            @as(u64, timeout_ms) * std.time.ns_per_ms;

        var out = conn.spawnProc(cmd_slice, cwd_opt, ns) catch |err| {
            log.debug("remote proc_spawn failed err={}", .{err});
            return -1;
        };
        defer out.deinit();
        if (!out.ok) return -1;
        return out.pid orelse -1;
    }

    // -------------------------------------------------------------------------
    // LOCAL (in-process) activity-monitor provider — the "Local" machine in the
    // panel's switcher. Unlike the remote `_remote_connection_*` calls, these take
    // NO connection handle: they sample / kill / spawn IN THIS PROCESS using the
    // SAME `proc.ProcSampler` / `metrics.Sampler` / `proc_control` code the agent
    // uses. A mutex-guarded global holds PERSISTENT samplers so local per-process
    // and host CPU% deltas work across polls (the first poll reads 0%). The panel
    // polls from a background queue, so every entry point locks `local_mutex`.
    //
    // `ghostty_local_proc_list` reuses the SAME `ghostty_proc_list_s` struct as the
    // remote path, but `ghostty_local_proc_list_free` frees via the app/global
    // allocator (`global.alloc`) — there is NO handle whose `.alloc` to use — so it
    // is a DISTINCT free function from `ghostty_remote_connection_proc_list_free`.
    // -------------------------------------------------------------------------

    /// Persistent local samplers + their guard. Created lazily on first use so a
    /// build that never opens the Local machine pays nothing. The samplers keep
    /// prev-tick baselines so repeated `_local_proc_list` polls yield real CPU%.
    const LocalSamplers = struct {
        var mutex: std.Thread.Mutex = .{};
        var proc_sampler: ?remote_proc.ProcSampler = null;
        var host_sampler: remote_metrics.Sampler = remote_metrics.Sampler.init();

        /// Caller must hold `mutex`. Returns the lazily-created proc sampler.
        fn procSamplerLocked(alloc: Allocator) *remote_proc.ProcSampler {
            if (proc_sampler == null) proc_sampler = remote_proc.ProcSampler.init(alloc);
            return &proc_sampler.?;
        }
    };

    /// A one-shot snapshot of THIS machine's process table (§9.3, the "Local"
    /// machine). SYNCHRONOUS but cheap (a local OS enumeration). The host metrics
    /// come from a persistent local `Sampler`, so host CPU% is a real delta after
    /// the first poll. `timeout_ms` is accepted for API symmetry with the remote
    /// call but unused (there is no RPC). Free with `ghostty_local_proc_list_free`.
    export fn ghostty_local_proc_list(timeout_ms: u32) ghostty_proc_list_s {
        _ = timeout_ms;
        const a = global.alloc;

        // Local "ghoztty-spawned" root = this running app's own pid; the UI shows
        // its descendants by default.
        const self_pid: i64 = pid: {
            if (builtin.os.tag == .windows) {
                const k32 = struct {
                    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
                };
                break :pid @intCast(k32.GetCurrentProcessId());
            }
            break :pid @intCast(std.c.getpid());
        };

        const empty: ghostty_proc_list_s = .{
            .ok = false,
            .truncated = false,
            .host = .{ .cpu_pct = 0, .mem_used = 0, .mem_total = 0, .ncpu = 0, .uptime_s = 0, .load1 = -1 },
            .procs = empty_procs_sentinel[0..].ptr,
            .procs_len = 0,
            .agent_pid = self_pid,
        };

        LocalSamplers.mutex.lock();
        defer LocalSamplers.mutex.unlock();

        const host = LocalSamplers.host_sampler.sample();
        const sampler = LocalSamplers.procSamplerLocked(a);

        var procs: std.ArrayListUnmanaged(remote_protocol.Proc) = .empty;
        defer {
            for (procs.items) |p| {
                a.free(@constCast(p.name));
                if (p.user) |u| a.free(@constCast(u));
                if (p.cmd) |c| a.free(@constCast(c));
            }
            procs.deinit(a);
        }
        const truncated = sampler.sample(a, &procs, 0) catch return empty;

        // Marshal into the SAME C struct as the remote path (dup strings, empty-
        // string sentinels for null user/cmd, safe partial-failure cleanup).
        const arr = a.alloc(ghostty_proc_s, procs.items.len) catch return empty;
        var filled: usize = 0;
        for (procs.items, 0..) |p, i| {
            const name = a.dupeZ(u8, p.name) catch break;
            const user = a.dupeZ(u8, p.user orelse "") catch {
                a.free(name);
                break;
            };
            const cmd = a.dupeZ(u8, p.cmd orelse "") catch {
                a.free(name);
                a.free(user);
                break;
            };
            arr[i] = .{
                .pid = p.pid,
                .ppid = p.ppid,
                .cpu_pct = p.cpu_pct,
                .mem_bytes = p.mem_bytes,
                .name = name.ptr,
                .user = user.ptr,
                .cmd = cmd.ptr,
            };
            filled = i + 1;
        }
        if (filled != procs.items.len) {
            for (arr[0..filled]) |r| {
                a.free(std.mem.sliceTo(r.name, 0));
                a.free(std.mem.sliceTo(r.user, 0));
                a.free(std.mem.sliceTo(r.cmd, 0));
            }
            a.free(arr);
            return empty;
        }

        return .{
            .ok = true,
            .truncated = truncated,
            .host = .{
                .cpu_pct = host.cpu_pct,
                .mem_used = host.mem_used,
                .mem_total = host.mem_total,
                .ncpu = host.ncpu,
                .uptime_s = host.uptime_s orelse 0,
                .load1 = host.load1 orelse -1,
            },
            .procs = arr.ptr,
            .procs_len = arr.len,
            .agent_pid = self_pid,
        };
    }

    /// Free a `ghostty_proc_list_s` returned by `ghostty_local_proc_list`. Unlike
    /// `ghostty_remote_connection_proc_list_free` (which uses the handle's
    /// allocator), this frees via the app/global allocator — local lists carry no
    /// handle. Always safe (a failed/empty list has `procs_len == 0`).
    export fn ghostty_local_proc_list_free(list: ghostty_proc_list_s) void {
        if (list.procs_len == 0) return;
        const a = global.alloc;
        const rows = list.procs[0..list.procs_len];
        for (rows) |r| {
            a.free(std.mem.sliceTo(r.name, 0));
            a.free(std.mem.sliceTo(r.user, 0));
            a.free(std.mem.sliceTo(r.cmd, 0));
        }
        a.free(rows);
    }

    /// Kill a process on THIS machine by pid (§9.3, the "Local" machine). `signal`
    /// is a NUL-terminated C string; empty ⇒ default terminate ("TERM"). Returns
    /// true iff the kill succeeded. In-process (no RPC), guarded by `local_mutex`
    /// only for symmetry — `killProc` itself is a stateless OS call.
    export fn ghostty_local_proc_kill(pid: i64, signal: [*:0]const u8) bool {
        const sig_slice = std.mem.sliceTo(signal, 0);
        const sig: ?[]const u8 = if (sig_slice.len == 0) null else sig_slice;
        const out = remote_proc_control.killProc(pid, sig);
        return out.ok;
    }

    /// Spawn a DETACHED process on THIS machine (§9.3, the "Local" machine). `cmd`
    /// is run through the local platform shell. `cwd` is a NUL-terminated C string;
    /// empty ⇒ the current working directory. Returns the spawned pid (> 0), or -1
    /// on failure. In-process (no RPC).
    export fn ghostty_local_proc_spawn(cmd: [*:0]const u8, cwd: [*:0]const u8) i64 {
        const a = global.alloc;
        const cmd_slice = std.mem.sliceTo(cmd, 0);
        if (cmd_slice.len == 0) return -1;
        const cwd_slice = std.mem.sliceTo(cwd, 0);
        const cwd_opt: ?[]const u8 = if (cwd_slice.len == 0) null else cwd_slice;
        const out = remote_proc_spawn.spawnDetached(a, cmd_slice, cwd_opt);
        // The Windows path may return an allocated diagnostic note we don't surface
        // through this i64-only C API — free it so it doesn't leak.
        if (out.free_error) {
            if (out.@"error") |m| a.free(@constCast(m));
        }
        if (!out.ok) return -1;
        return out.pid orelse -1;
    }

    /// The LIVE remote agent session id for `surface`, or an empty String if it
    /// is a local surface or its remote pane is not yet resolved. Returns a
    /// caller-owned UTF-8 `String` (free with `ghostty_string_free`). (§WP4)
    export fn ghostty_surface_remote_session_id(surface: *Surface) String {
        const sid = surface.core_surface.remoteSessionId() orelse return .empty;
        if (sid.len == 0) return .empty;
        const copy = surface.app.core_app.alloc.dupeZ(u8, sid) catch return .empty;
        return .fromSlice(copy);
    }

    /// The command `surface`'s remote pane was OPENed with, or an empty String if
    /// it is a local surface or its remote pane uses the agent's default shell.
    /// Returns a caller-owned UTF-8 `String` (free with `ghostty_string_free`).
    /// Used by the Swift new-window/tab/split path so a new remote frame inherits
    /// the parent frame's command (§WP4). The result is a snapshot; it does not
    /// borrow the backend.
    export fn ghostty_surface_remote_command(surface: *Surface) String {
        const cmd = surface.core_surface.remoteCommand() orelse return .empty;
        if (cmd.len == 0) return .empty;
        const copy = surface.app.core_app.alloc.dupeZ(u8, cmd) catch return .empty;
        return .fromSlice(copy);
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_refresh(surface: *Surface) void {
        surface.refresh();
    }

    /// Tell the surface that it needs to schedule a render
    /// call as soon as possible (NOW if possible).
    export fn ghostty_surface_draw(surface: *Surface) void {
        surface.draw();
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn ghostty_surface_set_size(surface: *Surface, w: u32, h: u32) void {
        surface.updateSize(w, h);
    }

    /// Return the size information a surface has.
    export fn ghostty_surface_size(surface: *Surface) SurfaceSize {
        const grid_size = surface.core_surface.size.grid();
        return .{
            .columns = grid_size.columns,
            .rows = grid_size.rows,
            .width_px = surface.core_surface.size.screen.width,
            .height_px = surface.core_surface.size.screen.height,
            .cell_width_px = surface.core_surface.size.cell.width,
            .cell_height_px = surface.core_surface.size.cell.height,
        };
    }

    /// Returns the PID of the foreground process for the surface PTY.
    export fn ghostty_surface_foreground_pid(surface: *Surface) u64 {
        return surface.core_surface.getProcessInfo(.foreground_pid) orelse 0;
    }

    /// Returns the PTY name for the surface. The returned string must be
    /// freed by the caller via ghostty_string_free.
    export fn ghostty_surface_tty_name(surface: *Surface) String {
        const tty_name = surface.core_surface.getProcessInfo(.tty_name) orelse return .empty;
        const copy = surface.app.core_app.alloc.dupeZ(u8, tty_name) catch |err| {
            log.err("error allocating tty name err={}", .{err});
            return .empty;
        };

        return .fromSlice(copy);
    }

    /// Update the color scheme of the surface.
    export fn ghostty_surface_set_color_scheme(surface: *Surface, scheme_raw: c_int) void {
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_surface_set_color_scheme value={}",
                .{scheme_raw},
            );
            return;
        };

        surface.colorSchemeCallback(scheme);
    }

    /// Set a color on the surface's terminal. kind: 0=palette, 1=foreground, 2=background.
    /// For palette colors, index selects which of the 256 entries. For fg/bg, index is ignored.
    export fn ghostty_surface_set_color(
        surface: *Surface,
        kind: c_int,
        index: u8,
        r: u8,
        g: u8,
        b: u8,
    ) void {
        const color: terminal.color.RGB = .{ .r = r, .g = g, .b = b };
        var t = &surface.core_surface.io.terminal;
        switch (kind) {
            0 => {
                t.colors.palette.set(index, color);
                t.flags.dirty.palette = true;
            },
            1 => t.colors.foreground.set(color),
            2 => t.colors.background.set(color),
            else => return,
        }
    }

    /// Reset all dynamic colors on the surface back to their defaults.
    export fn ghostty_surface_reset_colors(surface: *Surface) void {
        var t = &surface.core_surface.io.terminal;
        t.colors.palette.resetAll();
        t.colors.foreground.reset();
        t.colors.background.reset();
        t.flags.dirty.palette = true;
    }

    /// Update the content scale of the surface.
    export fn ghostty_surface_set_content_scale(surface: *Surface, x: f64, y: f64) void {
        surface.updateContentScale(x, y);
    }

    /// Update the focused state of a surface.
    export fn ghostty_surface_set_focus(surface: *Surface, focused: bool) void {
        surface.focusCallback(focused);
    }

    /// Update the occlusion state of a surface.
    export fn ghostty_surface_set_occlusion(surface: *Surface, visible: bool) void {
        surface.occlusionCallback(visible);
    }

    /// Filter the mods if necessary. This handles settings such as
    /// `macos-option-as-alt`. The filtered mods should be used for
    /// key translation but should NOT be sent back via the `_key`
    /// function -- the original mods should be used for that.
    export fn ghostty_surface_key_translation_mods(
        surface: *Surface,
        mods_raw: c_int,
    ) c_int {
        const mods: input.Mods = @bitCast(@as(
            input.Mods.Backing,
            @truncate(@as(c_uint, @bitCast(mods_raw))),
        ));
        const result = mods.translation(
            surface.core_surface.config.macos_option_as_alt orelse
                surface.app.keyboardLayout().detectOptionAsAlt(),
        );
        return @intCast(@as(input.Mods.Backing, @bitCast(result)));
    }

    /// Send this for raw keypresses (i.e. the keyDown event on macOS).
    /// This will handle the keymap translation and send the appropriate
    /// key and char events.
    export fn ghostty_surface_key(
        surface: *Surface,
        event: KeyEvent,
    ) bool {
        return surface.app.keyEvent(
            .{ .surface = surface },
            event.keyEvent(),
        ) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_surface_key_is_binding(
        surface: *Surface,
        event: KeyEvent,
        c_flags: ?*input.Binding.Flags.C,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        const flags = surface.core_surface.keyEventIsBinding(
            core_event,
        ) orelse return false;
        if (c_flags) |ptr| ptr.* = flags.cval();
        return true;
    }

    /// Send raw text to the terminal. This is treated like a paste
    /// so this isn't useful for sending escape sequences. For that,
    /// individual key input should be used.
    export fn ghostty_surface_write_pty(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.core_surface.writePtyRaw(ptr[0..len]) catch |err| {
            log.warn("failed to write to pty: {}", .{err});
        };
    }

    export fn ghostty_surface_text(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textCallback(ptr[0..len]);
    }

    /// Set the preedit text for the surface. This is used for IME
    /// composition. If the length is 0, then the preedit text is cleared.
    export fn ghostty_surface_preedit(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.preeditCallback(if (len == 0) null else ptr[0..len]);
    }

    /// Returns true if the surface currently has mouse capturing
    /// enabled.
    export fn ghostty_surface_mouse_captured(surface: *Surface) bool {
        return surface.core_surface.mouseCaptured();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_mouse_button(
        surface: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) bool {
        return surface.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    /// Update the mouse position within the view.
    export fn ghostty_surface_mouse_pos(
        surface: *Surface,
        x: f64,
        y: f64,
        mods: c_int,
    ) void {
        surface.cursorPosCallback(
            x,
            y,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_surface_mouse_scroll(
        surface: *Surface,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        surface.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_surface_mouse_pressure(
        surface: *Surface,
        stage_raw: u32,
        pressure: f64,
    ) void {
        const stage = std.meta.intToEnum(
            input.MousePressureStage,
            stage_raw,
        ) catch {
            log.warn(
                "invalid mouse pressure stage value={}",
                .{stage_raw},
            );
            return;
        };

        surface.mousePressureCallback(stage, pressure);
    }

    export fn ghostty_surface_ime_point(
        surface: *Surface,
        x: *f64,
        y: *f64,
        width: *f64,
        height: *f64,
    ) void {
        const pos = surface.core_surface.imePoint();
        x.* = pos.x;
        y.* = pos.y;
        width.* = pos.width;
        height.* = pos.height;
    }

    /// Request that the surface become closed. This will go through the
    /// normal trigger process that a close surface input binding would.
    export fn ghostty_surface_request_close(ptr: *Surface) void {
        ptr.core_surface.close();
    }

    /// Request that the surface split in the given direction.
    export fn ghostty_surface_split(ptr: *Surface, direction: apprt.action.SplitDirection) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .new_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Focus on the next split (if any).
    export fn ghostty_surface_split_focus(
        ptr: *Surface,
        direction: apprt.action.GotoSplit,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .goto_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Swap the focused split with the neighbor in the given direction.
    export fn ghostty_surface_split_swap(
        ptr: *Surface,
        direction: apprt.action.GotoSplit,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .swap_split,
            direction,
        ) catch |err| {
            log.err("error swapping split err={}", .{err});
            return;
        };
    }

    /// Resize the current split by moving the split divider in the given
    /// direction. `direction` specifies which direction the split divider will
    /// move relative to the focused split. `amount` is a fractional value
    /// between 0 and 1 that specifies by how much the divider will move.
    export fn ghostty_surface_split_resize(
        ptr: *Surface,
        direction: apprt.action.ResizeSplit.Direction,
        amount: u16,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .resize_split,
            .{ .direction = direction, .amount = amount },
        ) catch |err| {
            log.err("error resizing split err={}", .{err});
            return;
        };
    }

    /// Equalize the size of all splits in the current window.
    export fn ghostty_surface_split_equalize(ptr: *Surface) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .equalize_splits,
            {},
        ) catch |err| {
            log.err("error equalizing splits err={}", .{err});
            return;
        };
    }

    /// Invoke an action on the surface.
    export fn ghostty_surface_binding_action(
        ptr: *Surface,
        action_ptr: [*]const u8,
        action_len: usize,
    ) bool {
        const action_str = action_ptr[0..action_len];
        const action = input.Binding.Action.parse(action_str) catch |err| {
            log.err("error parsing binding action action={s} err={}", .{ action_str, err });
            return false;
        };

        return ptr.core_surface.performBindingAction(action) catch |err| {
            log.err("error performing binding action action={f} err={}", .{ action, err });
            return false;
        };
    }

    /// Complete a clipboard read request started via the read callback.
    /// This can only be called once for a given request. Once it is called
    /// with a request the request pointer will be invalidated.
    export fn ghostty_surface_complete_clipboard_request(
        ptr: *Surface,
        str: [*:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        ptr.completeClipboardRequest(
            std.mem.sliceTo(str, 0),
            state,
            confirmed,
        );
    }

    export fn ghostty_surface_inspector(ptr: *Surface) ?*Inspector {
        return ptr.initInspector() catch |err| {
            log.err("error initializing inspector err={}", .{err});
            return null;
        };
    }

    export fn ghostty_inspector_free(ptr: *Surface) void {
        ptr.freeInspector();
    }

    export fn ghostty_inspector_set_size(ptr: *Inspector, w: u32, h: u32) void {
        ptr.updateSize(w, h);
    }

    export fn ghostty_inspector_set_content_scale(ptr: *Inspector, x: f64, y: f64) void {
        ptr.updateContentScale(x, y);
    }

    export fn ghostty_inspector_mouse_button(
        ptr: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) void {
        ptr.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_inspector_mouse_pos(ptr: *Inspector, x: f64, y: f64) void {
        ptr.cursorPosCallback(x, y);
    }

    export fn ghostty_inspector_mouse_scroll(
        ptr: *Inspector,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        ptr.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_inspector_key(
        ptr: *Inspector,
        action: input.Action,
        key: input.Key,
        c_mods: c_int,
    ) void {
        ptr.keyCallback(
            action,
            key,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(c_mods))),
            )),
        ) catch |err| {
            log.err("error processing key event err={}", .{err});
            return;
        };
    }

    export fn ghostty_inspector_text(
        ptr: *Inspector,
        str: [*:0]const u8,
    ) void {
        ptr.textCallback(std.mem.sliceTo(str, 0));
    }

    export fn ghostty_inspector_set_focus(ptr: *Inspector, focused: bool) void {
        ptr.focusCallback(focused);
    }

    /// Sets the window background blur on macOS to the desired value.
    /// I do this in Zig as an extern function because I don't know how to
    /// call these functions in Swift.
    ///
    /// This uses an undocumented, non-public API because this is what
    /// every terminal appears to use, including Terminal.app.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@"background-opacity" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel("windowNumber"), .{}),
            @intCast(config.@"background-blur".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;

    // Darwin-only C APIs.
    const Darwin = struct {
        export fn ghostty_surface_set_display_id(ptr: *Surface, display_id: u32) void {
            const surface = &ptr.core_surface;
            _ = surface.renderer_thread.mailbox.push(
                .{ .macos_display_id = display_id },
                .{ .forever = {} },
            );
            surface.renderer_thread.wakeup.notify() catch {};
        }

        /// This returns a CTFontRef that should be used for quicklook
        /// highlighted text. This is always the primary font in use
        /// regardless of the selected text. If coretext is not in use
        /// then this will return nothing.
        export fn ghostty_surface_quicklook_font(ptr: *Surface) ?*anyopaque {
            // For non-CoreText we just return null.
            if (comptime font.options.backend != .coretext) {
                return null;
            }

            // We'll need content scale so fail early if we can't get it.
            const content_scale = ptr.getContentScale() catch return null;

            // Get the shared font grid. We acquire a read lock to
            // read the font face. It should not be deferred since
            // we're loading the primary face.
            const grid = ptr.core_surface.renderer.font_grid;
            grid.lock.lockShared();
            defer grid.lock.unlockShared();

            const collection = &grid.resolver.collection;
            const face = collection.getFace(.{}) catch return null;

            // We need to unscale the content scale. We apply the
            // content scale to our font stack because we are rendering
            // at 1x but callers of this should be using scaled or apply
            // scale themselves.
            const size: f32 = size: {
                const num = face.font.copyAttribute(.size) orelse
                    break :size 12;
                defer num.release();
                var v: f32 = 12;
                _ = num.getValue(.float, &v);
                break :size v;
            };

            const copy = face.font.copyWithAttributes(
                size / content_scale.y,
                null,
                null,
            ) catch return null;

            return copy;
        }

        /// This returns the selected word for quicklook. This will populate
        /// the buffer with the word under the cursor and the selection
        /// info so that quicklook can be rendered.
        ///
        /// This does not modify the selection active on the surface (if any).
        export fn ghostty_surface_quicklook_word(
            ptr: *Surface,
            result: *Text,
        ) bool {
            const surface = &ptr.core_surface;
            surface.renderer_state.mutex.lock();
            defer surface.renderer_state.mutex.unlock();

            // Get our word selection
            const sel = sel: {
                const screen: *terminal.Screen = surface.renderer_state.terminal.screens.active;
                const pos = try ptr.getCursorPos();
                const pt_viewport = surface.posToViewport(pos.x, pos.y);
                const pin = screen.pages.pin(.{
                    .viewport = .{
                        .x = pt_viewport.x,
                        .y = pt_viewport.y,
                    },
                }) orelse {
                    if (comptime std.debug.runtime_safety) unreachable;
                    return false;
                };
                break :sel surface.io.terminal.screens.active.selectWord(
                    pin,
                    surface.config.selection_word_chars,
                ) orelse return false;
            };

            // Read the selection
            return readTextLocked(ptr, sel, result);
        }

        export fn ghostty_inspector_metal_init(ptr: *Inspector, device: objc.c.id) bool {
            return ptr.initMetal(.fromId(device));
        }

        export fn ghostty_inspector_metal_render(
            ptr: *Inspector,
            command_buffer: objc.c.id,
            descriptor: objc.c.id,
        ) void {
            return ptr.renderMetal(
                .fromId(command_buffer),
                .fromId(descriptor),
            ) catch |err| {
                log.err("error rendering inspector err={}", .{err});
                return;
            };
        }

        export fn ghostty_inspector_metal_shutdown(ptr: *Inspector) void {
            if (ptr.backend) |v| {
                v.deinit();
                ptr.backend = null;
            }
        }
    };
};
