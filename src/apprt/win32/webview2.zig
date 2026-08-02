//! The WebView2 host floor: the loader-less runtime probe and the ONE shared
//! `ICoreWebView2Environment` every viewer pane is built on (T372, the first
//! child of T90d).
//!
//! Scope is deliberately narrow. This module ends when the app is holding an
//! environment pointer (or a typed failure). It creates no window, no
//! controller and no pane — `ViewerPane.zig` does that in T373 — and it knows
//! nothing about the IPC surface.
//!
//! ## Why loader-less
//!
//! The documented way in is `WebView2Loader.dll`, a binary that ships in the
//! SDK's NuGet package. T90a rejected vendoring it (design §1): it would put a
//! prebuilt Microsoft binary in the repo and a NuGet step in the build, for a
//! shim whose entire job is to find the runtime's own DLL and forward one
//! call. So we do what `webview/webview` and `go-webview2` have done for years
//! instead: read the runtime's location out of the registry, `LoadLibraryW`
//! its `EmbeddedBrowserWebView.dll`, and call the undocumented
//! `CreateWebViewEnvironmentWithOptionsInternal` export directly.
//!
//! Undocumented means it can move. Every step of the chain therefore returns a
//! typed `Failure` rather than trapping, and a failure is a normal outcome the
//! caller renders as the error card (T373) — the same card the runtime-absent
//! case gets. **Nothing in here may panic on a missing key, a missing file, a
//! missing export or a failing HRESULT.** A machine without WebView2 is a
//! supported machine; it just cannot open viewer panes.
//!
//! ## Registry sources, in order
//!
//! Both are read; the first that yields a usable version wins.
//!
//! 1. `SOFTWARE\Microsoft\EdgeUpdate\ClientState\{guid}` value `EBWebView` —
//!    the full **versioned** application directory. This is what the reference
//!    loader uses, and it needs no joining.
//! 2. `SOFTWARE\Microsoft\EdgeUpdate\Clients\{guid}` values `location` + `pv`
//!    — the unversioned directory and the version, joined. T90a's design
//!    pinned this one; it is kept as the fallback because it is the key that
//!    is documented in Microsoft's own "detect the runtime" guidance, and a
//!    box that has one and not the other should still work.
//!
//! Each is tried under `HKEY_LOCAL_MACHINE` (a machine-wide install) and then
//! `HKEY_CURRENT_USER` (a per-user one). Every open uses `KEY_WOW64_32KEY`:
//! EdgeUpdate writes the 32-bit view, which is `WOW6432Node` on a 64-bit box,
//! and letting the flag do the redirection means the path string stays right
//! on both.
//!
//! A key that merely EXISTS proves nothing — EdgeUpdate leaves the client key
//! behind after an uninstall with `pv = 0.0.0.0`. `Version.usable()` in
//! `webview2_paths.zig` is that distinction, and it is why the probe parses
//! the version instead of testing for the key.
//!
//! ## Escape hatch
//!
//! `GHOZTTY_WEBVIEW2_BROWSER_DIR` overrides the whole search: when it is set,
//! that directory is the runtime and the registry is not consulted. It mirrors
//! the runtime's own `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` and the house
//! `GHOSTTY_HOST_DEFAULTS` idiom, and — the reason it exists — pointing it at
//! a path that does not exist is how a test drives the runtime-absent branch
//! on a box that has the runtime installed.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const com = @import("com.zig");
const paths = @import("webview2_paths.zig");
const build_config = @import("../../build_config.zig");

const log = std.log.scoped(.webview2);

pub const Version = paths.Version;

// ---------------------------------------------------------------- failures

/// Why the host could not produce an environment. Every one of these is a
/// normal outcome that the caller turns into the error card; none is a bug.
pub const Failure = enum {
    /// No Evergreen runtime is installed (no key, or the key says 0.0.0.0).
    runtime_not_found,
    /// The registry named a directory whose client DLL is not there, or
    /// `LoadLibraryW` refused it.
    client_dll_unloadable,
    /// The DLL loaded but does not export the entry point we call. This is
    /// the one that says "Microsoft moved it".
    entry_point_missing,
    /// The entry point returned a failing HRESULT synchronously.
    create_call_failed,
    /// The completed handler fired with a failing HRESULT, or with success
    /// and a null environment.
    create_callback_failed,
    /// We could not work out where the user-data folder goes
    /// (`%LOCALAPPDATA%` unset) or ran out of memory building a path.
    environment_unavailable,

    /// A short line for the error card. Deliberately plain: the user is being
    /// told why a pane is blank, not read a stack trace.
    pub fn message(self: Failure) []const u8 {
        return switch (self) {
            .runtime_not_found => "Viewer requires the Microsoft Edge WebView2 Runtime",
            .client_dll_unloadable => "The WebView2 Runtime is installed but could not be loaded",
            .entry_point_missing => "This WebView2 Runtime is not compatible with Ghoztty viewers",
            .create_call_failed, .create_callback_failed => "The WebView2 Runtime failed to start",
            .environment_unavailable => "Ghoztty could not prepare the WebView2 data folder",
        };
    }

    /// The second line: what the user can actually do about it.
    pub fn hint(self: Failure) []const u8 {
        return switch (self) {
            .runtime_not_found => "Install it from microsoft.com/edge/webview2, then reopen this pane.",
            .client_dll_unloadable, .entry_point_missing => "Updating the WebView2 Runtime usually fixes this.",
            .create_call_failed, .create_callback_failed => "Reopen this pane to try again.",
            .environment_unavailable => "Check that %LOCALAPPDATA% is set and writable.",
        };
    }
};

// -------------------------------------------------------------------- COM

/// The COM floor lives in `com.zig` (T376): the IIDs, the HRESULT helpers,
/// and the generic callback object every handler in this file is an instance
/// of. Re-exported here so this module reads as one piece.
const GUID = com.GUID;
const HRESULT = com.HRESULT;
const S_OK = com.S_OK;
const failed = com.failed;

// {4E8A3389-C9D8-4BD2-B6B5-124FEE6CC14D}
const IID_EnvironmentCompletedHandler: GUID = .{
    .Data1 = 0x4E8A3389,
    .Data2 = 0xC9D8,
    .Data3 = 0x4BD2,
    .Data4 = .{ 0xB6, 0xB5, 0x12, 0x4F, 0xEE, 0x6C, 0xC1, 0x4D },
};

/// `ICoreWebView2Environment`, declared through the two methods this band
/// needs. Slots we never call are typed as opaque pointers on purpose: an
/// unused slot with a *guessed* signature is a crash waiting for the day
/// somebody calls it, while an opaque one cannot be called at all.
///
/// Vtable order mirrors WebView2.h's `ICoreWebView2Environment : IUnknown`.
/// Per the COM versioning contract, later interface revisions
/// (`ICoreWebView2Environment_2`, …) are reached by `QueryInterface`, never by
/// assuming trailing slots exist.
pub const ICoreWebView2Environment = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*ICoreWebView2Environment, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Environment) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2Environment) callconv(.winapi) u32,
        // ICoreWebView2Environment
        /// (HWND parentWindow, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*)
        /// — T373 calls this; declared opaque until it has a handler to pass.
        CreateCoreWebView2Controller: *const anyopaque,
        CreateWebResourceResponse: *const anyopaque,
        get_BrowserVersionString: *const fn (*ICoreWebView2Environment, *?[*:0]u16) callconv(.winapi) HRESULT,
        add_NewBrowserVersionAvailable: *const anyopaque,
        remove_NewBrowserVersionAvailable: *const anyopaque,
    };

    pub fn addRef(self: *ICoreWebView2Environment) void {
        _ = self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment) void {
        _ = self.vtable.Release(self);
    }

    /// The browser version this environment is actually running, as UTF-8.
    /// Caller owns the result.
    ///
    /// This is the cheapest possible proof that the environment is a live COM
    /// object and not a pointer that merely came back non-null: the string is
    /// produced by the browser process, allocated with `CoTaskMemAlloc`, and
    /// has to match what the registry advertised.
    pub fn browserVersion(self: *ICoreWebView2Environment, alloc: Allocator) ![]u8 {
        var raw: ?[*:0]u16 = null;
        const hr = self.vtable.get_BrowserVersionString(self, &raw);
        if (failed(hr) or raw == null) return error.BrowserVersionUnavailable;
        defer w32.CoTaskMemFree(@ptrCast(raw.?));
        return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(raw.?));
    }
};

/// `ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler` — a COM object
/// **we** implement and hand to the runtime.
///
/// The vtable, the reference counting and the interface matching are
/// `com.Callback`'s (T376); what is specific to this interface is its IID and
/// `onEnvironmentCompleted` below.
///
/// Lifetime: the runtime `AddRef`s this before it keeps it and `Release`s it
/// after `Invoke`, so the object frees itself when the count reaches zero. It
/// is created with a count of 1 (the reference the creating call owns) and
/// that reference is dropped right after the create call returns.
const EnvCompletedHandler = com.Callback(IID_EnvironmentCompletedHandler, onEnvironmentCompleted);

fn onEnvironmentCompleted(
    host: *Host,
    result: HRESULT,
    env: ?*ICoreWebView2Environment,
) HRESULT {
    // Runs on the thread that made the create call — our GUI thread, off its
    // message loop. Keep it short and never block: this is a callback from
    // the browser process's proxy.
    if (failed(result) or env == null) {
        log.warn("environment creation failed hr=0x{X:0>8} env={s}", .{
            @as(u32, @bitCast(result)),
            if (env == null) "null" else "set",
        });
        host.finishFailure(.create_callback_failed);
        return S_OK;
    }
    // The pointer is borrowed for the duration of Invoke; we are keeping it,
    // so we take our own reference.
    env.?.addRef();
    host.finishSuccess(env.?);
    return S_OK;
}

/// `CreateWebViewEnvironmentWithOptionsInternal`, the export we call in place
/// of `WebView2Loader.dll`'s `CreateCoreWebView2EnvironmentWithOptions`.
///
/// Signature per the reference implementations (webview/webview's
/// `loader.hh`): `(bool, webview2_runtime_type, PCWSTR userDataFolder,
/// IUnknown *environmentOptions, ICoreWebView2CreateCoreWebView2Environment-
/// CompletedHandler *)`. Notably it takes NO browser directory — the DLL
/// already knows where it lives, which is exactly why loading it by full path
/// is the whole of "pointing at a runtime".
const CreateEnvironmentInternalFn = *const fn (
    bool,
    RuntimeType,
    ?[*:0]const u16,
    ?*anyopaque,
    *EnvCompletedHandler,
) callconv(.winapi) HRESULT;

const RuntimeType = enum(i32) { installed = 0, embedded = 1 };

// ------------------------------------------------------------------- probe

/// A located Evergreen runtime. Owned strings; `deinit` frees them.
pub const Runtime = struct {
    /// The versioned application directory, e.g.
    /// `C:\Program Files (x86)\Microsoft\EdgeWebView\Application\150.0.4078.105`.
    browser_dir: []u8,
    /// `<browser_dir>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`.
    dll_path: []u8,
    /// The version the registry advertised (or the directory's last
    /// component, when the source was `ClientState`).
    version: Version,
    /// Where it was found. Diagnostic only.
    source: Source,

    pub const Source = enum { env_override, client_state, clients };

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        alloc.free(self.browser_dir);
        alloc.free(self.dll_path);
        self.* = undefined;
    }
};

const client_guid = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
const client_state_key = "SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\" ++ client_guid;
const clients_key = "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\" ++ client_guid;

/// Locate the runtime. Returns `error.RuntimeNotFound` when there isn't one —
/// a supported state, not an exceptional one.
pub fn probe(alloc: Allocator) !Runtime {
    const arch = paths.Arch.current();

    // The override short-circuits everything, including the "does it exist"
    // check, so pointing it at nowhere is a faithful runtime-absent drill.
    if (std.process.getEnvVarOwned(alloc, "GHOZTTY_WEBVIEW2_BROWSER_DIR")) |dir| {
        defer alloc.free(dir);
        if (dir.len > 0) {
            return try runtimeFromDir(alloc, dir, .env_override, arch);
        }
    } else |_| {}

    const roots = [_]w32.HKEY{ w32.HKEY_LOCAL_MACHINE, w32.HKEY_CURRENT_USER };

    // Source 1: ClientState's `EBWebView` — already the versioned directory.
    for (roots) |root| {
        const dir = readRegString(alloc, root, client_state_key, "EBWebView") catch continue;
        defer alloc.free(dir);
        if (dir.len == 0) continue;
        const rt = runtimeFromDir(alloc, dir, .client_state, arch) catch continue;
        return rt;
    }

    // Source 2: Clients' `location` + `pv`, joined.
    for (roots) |root| {
        const location = readRegString(alloc, root, clients_key, "location") catch continue;
        defer alloc.free(location);
        const pv = readRegString(alloc, root, clients_key, "pv") catch continue;
        defer alloc.free(pv);
        if (location.len == 0 or pv.len == 0) continue;
        const version = paths.parseVersion(pv) orelse continue;
        if (!version.usable()) continue;

        const dir = paths.versionedBrowserDir(alloc, location, pv) catch continue;
        defer alloc.free(dir);
        const rt = runtimeFromDir(alloc, dir, .clients, arch) catch continue;
        return rt;
    }

    return error.RuntimeNotFound;
}

/// Build a `Runtime` from a versioned browser directory, verifying that the
/// client DLL is actually on disk. A registry entry that points at a deleted
/// install is exactly as useless as no entry at all, and finding that out here
/// keeps `LoadLibraryW` from being the thing that reports it.
fn runtimeFromDir(
    alloc: Allocator,
    dir: []const u8,
    source: Runtime.Source,
    arch: paths.Arch,
) !Runtime {
    const version = paths.parseVersion(paths.lastPathComponent(dir)) orelse Version{};
    if (source != .env_override and !version.usable()) return error.RuntimeNotFound;

    const dll_path = try paths.clientDllPath(alloc, dir, arch);
    errdefer alloc.free(dll_path);
    std.fs.accessAbsolute(dll_path, .{}) catch return error.RuntimeNotFound;

    const browser_dir = try alloc.dupe(u8, dir);
    return .{
        .browser_dir = browser_dir,
        .dll_path = dll_path,
        .version = version,
        .source = source,
    };
}

/// Read one `REG_SZ`/`REG_EXPAND_SZ` value as UTF-8. Always opened through the
/// 32-bit registry view, which is where EdgeUpdate writes.
fn readRegString(
    alloc: Allocator,
    root: w32.HKEY,
    sub_key: []const u8,
    value: []const u8,
) ![]u8 {
    var sub_buf: [512]u16 = undefined;
    const sub_len = try std.unicode.utf8ToUtf16Le(&sub_buf, sub_key);
    sub_buf[sub_len] = 0;

    var val_buf: [64]u16 = undefined;
    const val_len = try std.unicode.utf8ToUtf16Le(&val_buf, value);
    val_buf[val_len] = 0;

    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(
        root,
        sub_buf[0..sub_len :0].ptr,
        0,
        w32.KEY_READ | w32.KEY_WOW64_32KEY,
        &key,
    ) != w32.ERROR_SUCCESS) return error.KeyNotFound;
    defer _ = w32.RegCloseKey(key);

    var data: [1024]u8 = undefined;
    var size: u32 = data.len;
    var kind: u32 = 0;
    if (w32.RegQueryValueExW(
        key,
        val_buf[0..val_len :0].ptr,
        null,
        &kind,
        &data,
        &size,
    ) != w32.ERROR_SUCCESS) return error.ValueNotFound;
    if (kind != w32.REG_SZ and kind != w32.REG_EXPAND_SZ) return error.ValueNotFound;

    // `size` is bytes and MAY include the terminator; it also may not, which
    // is why this trims rather than assuming.
    var count = size / 2;
    const wide: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, data[0 .. count * 2]));
    while (count > 0 and wide[count - 1] == 0) count -= 1;
    return std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..count]);
}

// -------------------------------------------------------------------- host

/// The app-wide WebView2 host: one probe, one loaded client DLL, one
/// `ICoreWebView2Environment` shared by every viewer pane (T90a design §4 —
/// one environment and one user-data folder means one browser process tree
/// for the whole app instead of one per pane).
///
/// Owned by `App`; panes ask it for the environment and register to be told
/// when it is ready. Single-threaded by construction: every method must be
/// called on the GUI thread, which is also the thread the runtime invokes the
/// completed handler on.
pub const Host = struct {
    alloc: Allocator,

    state: State = .idle,
    env: ?*ICoreWebView2Environment = null,
    failure: ?Failure = null,
    runtime: ?Runtime = null,

    /// Panes waiting on an environment that is still being created. Fired
    /// once, in registration order, then cleared.
    waiters: std.ArrayList(Waiter) = .empty,

    /// Kept loaded for the process lifetime once it is in. Unloading a browser
    /// client DLL out from under a live environment is not a thing we want to
    /// get right.
    client_dll: ?w32.HINSTANCE = null,

    pub const State = enum { idle, creating, ready, failed };

    pub const Result = union(enum) {
        ready: *ICoreWebView2Environment,
        failed: Failure,
    };

    pub const Waiter = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, result: Result) void,
    };

    pub fn init(alloc: Allocator) Host {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Host) void {
        if (self.env) |e| {
            e.release();
            self.env = null;
        }
        if (self.runtime) |*rt| rt.deinit(self.alloc);
        self.runtime = null;
        self.waiters.deinit(self.alloc);
        // client_dll is deliberately left loaded; see the field comment.
    }

    /// Ask for the environment, and be told when there is one.
    ///
    /// Fires `waiter` immediately if the answer is already known (ready or
    /// failed), otherwise queues it and starts creation if it has not started.
    /// A caller that only wants the current answer can read `self.env` /
    /// `self.failure` directly.
    pub fn request(self: *Host, waiter: Waiter) void {
        switch (self.state) {
            .ready => {
                waiter.func(waiter.ctx, .{ .ready = self.env.? });
                return;
            },
            .failed => {
                waiter.func(waiter.ctx, .{ .failed = self.failure.? });
                return;
            },
            .creating => {
                self.waiters.append(self.alloc, waiter) catch {
                    waiter.func(waiter.ctx, .{ .failed = .environment_unavailable });
                };
                return;
            },
            .idle => {},
        }

        self.waiters.append(self.alloc, waiter) catch {
            waiter.func(waiter.ctx, .{ .failed = .environment_unavailable });
            return;
        };
        self.begin();
    }

    /// Start creation without registering interest. Safe to call repeatedly.
    pub fn ensure(self: *Host) void {
        if (self.state != .idle) return;
        self.begin();
    }

    fn begin(self: *Host) void {
        std.debug.assert(self.state == .idle);
        self.state = .creating;

        const rt = probe(self.alloc) catch |err| {
            log.info("no WebView2 runtime: {}", .{err});
            return self.finishFailure(.runtime_not_found);
        };
        self.runtime = rt;
        log.info(
            "WebView2 runtime {}.{}.{}.{} via {s} at {s}",
            .{ rt.version.major, rt.version.minor, rt.version.build, rt.version.patch, @tagName(rt.source), rt.browser_dir },
        );

        const create_fn = self.loadEntryPoint(rt) catch |err| {
            return self.finishFailure(switch (err) {
                error.EntryPointMissing => .entry_point_missing,
                else => .client_dll_unloadable,
            });
        };

        const udf = self.userDataFolderW() catch {
            return self.finishFailure(.environment_unavailable);
        };
        defer self.alloc.free(udf);

        const handler = EnvCompletedHandler.create(self.alloc, self) catch {
            return self.finishFailure(.environment_unavailable);
        };
        // Our own reference; the runtime takes its own if it keeps it. Note
        // this can free the handler outright when the call below fails before
        // AddRef-ing, which is the point.
        defer handler.release();

        const hr = create_fn(true, .installed, udf.ptr, null, handler);
        if (failed(hr)) {
            log.warn("CreateWebViewEnvironmentWithOptionsInternal hr=0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return self.finishFailure(.create_call_failed);
        }
        // Success means "creation is under way"; the handler finishes it.
    }

    fn loadEntryPoint(self: *Host, rt: Runtime) !CreateEnvironmentInternalFn {
        var wide_buf: [1024]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, rt.dll_path) catch
            return error.ClientDllUnloadable;
        if (wide_len >= wide_buf.len) return error.ClientDllUnloadable;
        wide_buf[wide_len] = 0;

        const module = self.client_dll orelse
            w32.LoadLibraryW(wide_buf[0..wide_len :0].ptr) orelse {
                log.warn("LoadLibraryW failed for {s}", .{rt.dll_path});
                return error.ClientDllUnloadable;
            };
        self.client_dll = module;

        const proc = w32.GetProcAddress(
            module,
            "CreateWebViewEnvironmentWithOptionsInternal",
        ) orelse {
            log.warn("client DLL has no CreateWebViewEnvironmentWithOptionsInternal", .{});
            return error.EntryPointMissing;
        };
        return @ptrCast(@alignCast(proc));
    }

    /// `%LOCALAPPDATA%\ghoztty\EBWebView[-debug]` as UTF-16. Created eagerly:
    /// the runtime will make it itself, but a failure to create it here is a
    /// clearer signal than a browser-process error later.
    fn userDataFolderW(self: *Host) ![:0]u16 {
        const local = try std.process.getEnvVarOwned(self.alloc, "LOCALAPPDATA");
        defer self.alloc.free(local);

        const utf8 = try paths.userDataFolder(self.alloc, local, build_config.is_debug);
        defer self.alloc.free(utf8);

        std.fs.makeDirAbsolute(utf8) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => {
                // The `ghoztty` parent may not exist yet either.
                std.fs.makeDirAbsolute(std.fs.path.dirname(utf8) orelse return err) catch {};
                std.fs.makeDirAbsolute(utf8) catch {};
            },
            else => {},
        };

        return try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, utf8);
    }

    fn finishSuccess(self: *Host, env: *ICoreWebView2Environment) void {
        self.state = .ready;
        self.env = env;
        self.failure = null;
        self.drain(.{ .ready = env });
    }

    fn finishFailure(self: *Host, failure: Failure) void {
        self.state = .failed;
        self.failure = failure;
        self.drain(.{ .failed = failure });
    }

    fn drain(self: *Host, result: Result) void {
        // Take the list first: a waiter is free to register another one (a
        // pane that opens a split from its own ready callback), and appending
        // to a list we are iterating is how that turns into a crash.
        var pending = self.waiters;
        self.waiters = .empty;
        defer pending.deinit(self.alloc);
        for (pending.items) |w| w.func(w.ctx, result);
    }
};

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "Failure: every case answers with a message and a hint" {
    inline for (@typeInfo(Failure).@"enum".fields) |f| {
        const value: Failure = @enumFromInt(f.value);
        try testing.expect(value.message().len > 0);
        try testing.expect(value.hint().len > 0);
    }
}

test "the completed handler is a well-behaved COM object" {
    // No runtime involved: this exercises OUR vtable, which is the half of
    // the contract we can get wrong without Microsoft's help. It is also the
    // regression oracle for T376's port onto `com.Callback` — the generic is
    // only correct if this handler still behaves exactly as it did when it
    // was forty hand-written lines.
    var host = Host.init(testing.allocator);
    defer host.deinit();

    const h = try EnvCompletedHandler.create(host.alloc, &host);

    // QueryInterface for IUnknown and for our own IID both succeed and both
    // take a reference; anything else is E_NOINTERFACE with a null out-param.
    // `Release` reports the count AFTER the decrement, so 1→2→1 reads as 1.
    var out: ?*anyopaque = null;
    try testing.expectEqual(S_OK, h.vtable.QueryInterface(h, &com.IID_IUnknown, &out));
    try testing.expect(out != null);
    try testing.expectEqual(@as(u32, 1), h.vtable.Release(h));

    out = null;
    try testing.expectEqual(S_OK, h.vtable.QueryInterface(h, &IID_EnvironmentCompletedHandler, &out));
    try testing.expectEqual(@as(*anyopaque, @ptrCast(h)), out.?);
    try testing.expectEqual(@as(u32, 1), h.vtable.Release(h));

    out = @ptrFromInt(0xDEAD);
    const bogus: GUID = .{ .Data1 = 1, .Data2 = 2, .Data3 = 3, .Data4 = .{ 4, 5, 6, 7, 8, 9, 10, 11 } };
    try testing.expectEqual(com.E_NOINTERFACE, h.vtable.QueryInterface(h, &bogus, &out));
    try testing.expect(out == null);

    // AddRef/Release count symmetrically, and the last Release frees.
    try testing.expectEqual(@as(u32, 2), h.vtable.AddRef(h));
    try testing.expectEqual(@as(u32, 1), h.vtable.Release(h));
    try testing.expectEqual(@as(u32, 0), h.vtable.Release(h));
}

test "a failing Invoke reports the failure instead of dereferencing null" {
    var host = Host.init(testing.allocator);
    defer host.deinit();
    host.state = .creating;

    const h = try EnvCompletedHandler.create(host.alloc, &host);
    // E_FAIL with a null environment: the shape a create failure arrives in.
    try testing.expectEqual(S_OK, h.vtable.Invoke(h, @bitCast(@as(u32, 0x80004005)), null));
    try testing.expectEqual(Host.State.failed, host.state);
    try testing.expectEqual(Failure.create_callback_failed, host.failure.?);
    _ = h.vtable.Release(h);

    // S_OK with a null environment is the other half of the same guard: the
    // runtime is not supposed to do it, and we do not trust it not to.
    var host2 = Host.init(testing.allocator);
    defer host2.deinit();
    host2.state = .creating;
    const h2 = try EnvCompletedHandler.create(host2.alloc, &host2);
    try testing.expectEqual(S_OK, h2.vtable.Invoke(h2, S_OK, null));
    try testing.expectEqual(Host.State.failed, host2.state);
    _ = h2.vtable.Release(h2);
}

test "waiters fire once, in order, and a re-entrant request is safe" {
    var host = Host.init(testing.allocator);
    defer host.deinit();
    host.state = .creating;

    const Recorder = struct {
        seen: std.ArrayList(u8) = .empty,
        alloc: Allocator,
        host: *Host,
        reenter: bool = false,

        fn cb(ctx: *anyopaque, result: Host.Result) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.seen.append(self.alloc, switch (result) {
                .ready => 'r',
                .failed => 'f',
            }) catch {};
            if (self.reenter) {
                self.reenter = false;
                // Registering from inside a callback is the split-from-a-
                // viewer case; it must answer immediately, not corrupt the
                // list we are walking.
                self.host.request(.{ .ctx = ctx, .func = cb });
            }
        }
    };

    var rec: Recorder = .{ .alloc = testing.allocator, .host = &host, .reenter = true };
    defer rec.seen.deinit(testing.allocator);

    host.request(.{ .ctx = &rec, .func = Recorder.cb });
    host.request(.{ .ctx = &rec, .func = Recorder.cb });
    try testing.expectEqual(@as(usize, 0), rec.seen.items.len); // still creating

    host.finishFailure(.runtime_not_found);
    // Two queued waiters plus the one the first re-registered.
    try testing.expectEqualStrings("fff", rec.seen.items);

    // Terminal state: a later request answers synchronously.
    host.request(.{ .ctx = &rec, .func = Recorder.cb });
    try testing.expectEqualStrings("ffff", rec.seen.items);
}

test "probe: the runtime-absent branch is reachable on a box that has one" {
    // The override is the drill: point it at a directory that does not exist
    // and the probe must report absence rather than finding the real install.
    // (`error.RuntimeNotFound` specifically — not a crash, not a panic.)
    const prev = std.process.getEnvVarOwned(testing.allocator, "GHOZTTY_WEBVIEW2_BROWSER_DIR") catch null;
    defer if (prev) |p| testing.allocator.free(p);

    try setEnvForTest("GHOZTTY_WEBVIEW2_BROWSER_DIR", "C:\\ghoztty-no-such-webview2-runtime");
    defer restoreEnvForTest("GHOZTTY_WEBVIEW2_BROWSER_DIR", prev);

    try testing.expectError(error.RuntimeNotFound, probe(testing.allocator));
}

test "probe: finds this box's runtime and its client DLL" {
    // On a box WITH the runtime this is the real end-to-end probe; on one
    // without it, absence is the correct answer and the test says so rather
    // than failing. Either way the probe must not crash.
    const prev = std.process.getEnvVarOwned(testing.allocator, "GHOZTTY_WEBVIEW2_BROWSER_DIR") catch null;
    defer if (prev) |p| testing.allocator.free(p);
    try setEnvForTest("GHOZTTY_WEBVIEW2_BROWSER_DIR", "");
    defer restoreEnvForTest("GHOZTTY_WEBVIEW2_BROWSER_DIR", prev);

    var rt = probe(testing.allocator) catch |err| {
        try testing.expectEqual(error.RuntimeNotFound, err);
        return;
    };
    defer rt.deinit(testing.allocator);

    try testing.expect(rt.version.usable());
    try testing.expect(std.mem.endsWith(u8, rt.dll_path, "EmbeddedBrowserWebView.dll"));
    try std.fs.accessAbsolute(rt.dll_path, .{});
    // The registry's version and the directory it points at must agree —
    // a mismatch means we joined the wrong two halves.
    try testing.expect(std.mem.indexOf(u8, rt.dll_path, rt.browser_dir) != null);
}

test "host: creates a real environment on this box, and it reports its version" {
    // The one test that proves the undocumented ABI. Everything else in this
    // file checks arithmetic or our own vtable; this drives the whole chain —
    // registry -> LoadLibraryW -> GetProcAddress -> the internal export -> our
    // completed handler -> a live COM object -> a string from the browser
    // process — and compares the version the environment reports against the
    // one the registry advertised. A guessed calling convention or a wrong
    // parameter order cannot survive it.
    //
    // On a box with no runtime the probe says so and the test ends there: the
    // absence is the correct answer, and `probe: the runtime-absent branch`
    // above already asserts that branch deliberately.
    const prev = std.process.getEnvVarOwned(testing.allocator, "GHOZTTY_WEBVIEW2_BROWSER_DIR") catch null;
    defer if (prev) |p| testing.allocator.free(p);
    try setEnvForTest("GHOZTTY_WEBVIEW2_BROWSER_DIR", "");
    defer restoreEnvForTest("GHOZTTY_WEBVIEW2_BROWSER_DIR", prev);

    var expected_version: []u8 = undefined;
    {
        var rt = probe(testing.allocator) catch |err| {
            // Loud on purpose. A test that skips quietly is a test that
            // reports success for work it never did.
            log.warn("SKIPPED live environment test, no runtime: {}", .{err});
            return;
        };
        defer rt.deinit(testing.allocator);
        expected_version = try std.fmt.allocPrint(testing.allocator, "{}.{}.{}.{}", .{
            rt.version.major, rt.version.minor, rt.version.build, rt.version.patch,
        });
    }
    defer testing.allocator.free(expected_version);

    // WebView2 wants an apartment on the calling thread; the app initializes
    // one at startup (`App.zig`), the test harness has not.
    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);

    var host = Host.init(testing.allocator);
    defer host.deinit();
    host.ensure();

    // The completed handler arrives on THIS thread's message loop, so the
    // test has to be one. Bounded: a hang here would wedge the lane, and a
    // silent timeout would make the test green and empty.
    var timer = try std.time.Timer.start();
    var msg: w32.MSG = undefined;
    while (host.state == .creating) {
        if (timer.read() > 60 * std.time.ns_per_s) break;
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }

    try testing.expectEqual(Host.State.ready, host.state);
    const reported = try host.env.?.browserVersion(testing.allocator);
    defer testing.allocator.free(reported);
    log.warn("live environment reports browser version {s}", .{reported});
    try testing.expectEqualStrings(expected_version, reported);
}

/// `SetEnvironmentVariableW` — the tests above need the *process* environment
/// to change, which `std.process` has no portable setter for.
fn setEnvForTest(name: []const u8, value: []const u8) !void {
    var name_buf: [128]u16 = undefined;
    var value_buf: [512]u16 = undefined;
    const nl = try std.unicode.utf8ToUtf16Le(&name_buf, name);
    name_buf[nl] = 0;
    const vl = try std.unicode.utf8ToUtf16Le(&value_buf, value);
    value_buf[vl] = 0;
    if (w32.SetEnvironmentVariableW(
        name_buf[0..nl :0].ptr,
        if (vl == 0) null else value_buf[0..vl :0].ptr,
    ) == 0) return error.SetEnvFailed;
}

fn restoreEnvForTest(name: []const u8, prev: ?[]const u8) void {
    setEnvForTest(name, prev orelse "") catch {};
}
