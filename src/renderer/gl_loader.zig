//! Which OpenGL implementation the Win32 build is drawing with, decided at run
//! time rather than at link time (T1251).
//!
//! THE DEFECT this exists for: on a machine reached over Remote Desktop the
//! display driver offers OpenGL 1.1, Ghoztty requires 4.3, and there was
//! nothing else to try — `wglCreateContext` and friends were `extern
//! "opengl32"`, so the process bound to exactly one implementation before
//! `main` ran. T1249 made that refusal honest; this is what gives it a second
//! thing to reach for.
//!
//! WHY RUNTIME RESOLUTION IS THE WHOLE POINT, and not an implementation
//! detail: `opengl32.dll` is not a KnownDLL, so a fallback copy laid down
//! beside `ghoztty.exe` would satisfy the static import for EVERY launch. The
//! machine with a perfectly good GPU would silently be moved onto a software
//! renderer and nobody would ever see a message about it. So the system
//! implementation is opened by explicit System32 search, the fallback is opened
//! by full path out of a subdirectory, and the exe imports neither.
//!
//! THE POLICY IS SEPARATE FROM THE SYSCALLS on purpose: `fallbackRelPath` and
//! `shouldRetry` are pure and tested in both lanes, including the
//! `-Dapp-runtime=none` lane that never touches a Windows API. The half that
//! calls `LoadLibraryExW` is compiled only for Windows.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.gl_loader);

/// Which of the two implementations a loaded `Api` came from. The distinction
/// is user-visible in the log (and, once there is something to say, in About):
/// "your terminal is drawing the slow way" is a fact a user is owed rather than
/// one to leave in a driver.
pub const Kind = enum {
    /// The display driver's own OpenGL, out of System32. What every machine
    /// with working graphics uses.
    system,

    /// A shipped implementation used only when the system one measured below
    /// the renderer's floor. Its files arrive with T1252.
    fallback,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .system => "system",
            .fallback => "fallback",
        };
    }
};

/// Where a shipped fallback lives, relative to the directory holding
/// `ghoztty.exe`. A SUBDIRECTORY rather than beside the exe, for the hijack
/// reason in the module note: an adjacent `opengl32.dll` is loaded by the
/// operating system before anything of ours gets a vote.
pub const fallback_rel_dir = "gl";
pub const fallback_dll = "opengl32.dll";

/// Longest path we will build for the fallback. Deliberately generous: a
/// per-user install nests several directories deep under a profile name we do
/// not control.
pub const max_path = 1024;

/// The path a shipped fallback would occupy, given the directory that holds the
/// executable. Pure — the syscall half calls this with a directory it measured,
/// and the tests call it with a literal.
///
/// A trailing separator on `exe_dir` is tolerated rather than doubled: the
/// callers that produce it (a root install like `D:\`) are real, and a path
/// with `\\` in the middle is one Windows accepts but nobody can read in a log.
pub fn fallbackRelPath(buf: []u8, exe_dir: []const u8) error{NoSpaceLeft}![]const u8 {
    const dir = std.mem.trimRight(u8, exe_dir, "\\/");
    return std.fmt.bufPrint(
        buf,
        "{s}\\" ++ fallback_rel_dir ++ "\\" ++ fallback_dll,
        .{dir},
    );
}

/// Is this startup failure one that a second GL implementation could plausibly
/// fix, given what has already been tried?
///
/// Pure, and takes the state rather than reading it, so the policy is testable
/// without a GL context anywhere in sight. The three answers it has to get
/// right: retry a version refusal once, never retry a failure that has nothing
/// to do with GL, and never retry when the fallback is already what failed —
/// the last one is what stops a machine with no working graphics at all from
/// looping through window creation forever instead of showing the T1249 dialog.
pub fn shouldRetry(err: anyerror, active_kind: Kind, fallback_available: bool) bool {
    if (active_kind != .system) return false;
    if (!fallback_available) return false;
    return switch (err) {
        error.OpenGLOutdated, error.GLInitFailed => true,
        else => false,
    };
}

// -------------------------------------------------------------------------
// The Windows half. Everything below is compiled only for Windows targets;
// the `none` lane sees an empty struct and the policy above.
// -------------------------------------------------------------------------

pub const HDC = ?*anyopaque;
pub const HGLRC = ?*anyopaque;

/// The shape glad wants back from a loader: an opaque function pointer.
pub const Proc = *const fn () callconv(.c) void;

/// The loader signature glad's `gladLoadGLContext` takes. Matching it exactly
/// matters — `pkg/opengl/glad.zig` dispatches on the TYPE, and a mismatch takes
/// the "try as-is" branch with a `@ptrCast` instead of failing to compile.
pub const GladLoadFn = *const fn ([*:0]const u8) callconv(.c) ?Proc;

const win = if (builtin.os.tag == .windows) struct {
    const w = std.os.windows;

    const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x800;
    const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x8;
    const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFF_FFFF;

    extern "kernel32" fn LoadLibraryExW(
        name: [*:0]const u16,
        file: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) ?w.HMODULE;

    extern "kernel32" fn GetProcAddress(
        module: w.HMODULE,
        name: [*:0]const u8,
    ) callconv(.winapi) ?Proc;

    extern "kernel32" fn GetModuleFileNameW(
        module: ?w.HMODULE,
        filename: [*]u16,
        size: u32,
    ) callconv(.winapi) u32;

    extern "kernel32" fn GetFileAttributesW(
        name: [*:0]const u16,
    ) callconv(.winapi) u32;

    // gdi32 IS a KnownDLL, so these may be bound statically without the
    // hijack risk that made `opengl32` dynamic. They serve the system
    // implementation; a standalone fallback brings its own (see `Api.load`).
    extern "gdi32" fn ChoosePixelFormat(hdc: HDC, pfd: *const anyopaque) callconv(.winapi) i32;
    extern "gdi32" fn SetPixelFormat(hdc: HDC, format: i32, pfd: *const anyopaque) callconv(.winapi) i32;
    extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) i32;
} else struct {};

/// One loaded OpenGL implementation and the entry points resolved out of it.
///
/// The WGL entry points come from the module itself. The pixel-format and
/// buffer-swap entry points come from the module too WHEN IT HAS THEM: a
/// standalone implementation (Mesa's `opengl32.dll` is the case in hand)
/// implements the whole WGL surface including `wglChoosePixelFormat` and
/// `wglSwapBuffers`, because GDI knows nothing about its formats. The system
/// implementation exports those names too but they are not what a caller should
/// use for an installable client driver, so `.system` deliberately keeps the
/// gdi32 ones.
pub const Api = struct {
    kind: Kind,
    module: std.os.windows.HMODULE,

    createContext: *const fn (HDC) callconv(.winapi) HGLRC,
    makeCurrent: *const fn (HDC, HGLRC) callconv(.winapi) i32,
    deleteContext: *const fn (HGLRC) callconv(.winapi) i32,
    getCurrentDC: *const fn () callconv(.winapi) HDC,
    getProcAddress: *const fn ([*:0]const u8) callconv(.winapi) ?Proc,

    choosePixelFormat: *const fn (HDC, *const anyopaque) callconv(.winapi) i32,
    setPixelFormat: *const fn (HDC, i32, *const anyopaque) callconv(.winapi) i32,
    swapBuffers: *const fn (HDC) callconv(.winapi) i32,

    /// Resolve a GL entry point the way a WGL client must: ask the context
    /// first (`wglGetProcAddress`, which is the only way to reach anything
    /// past OpenGL 1.1), then the module's export table for the 1.1 core that
    /// `wglGetProcAddress` is specified NOT to return.
    ///
    /// The magic return values are load-bearing: `wglGetProcAddress` answers
    /// 1, 2, 3 and -1 for "no" on some drivers rather than 0, and treating one
    /// of those as a function pointer is a jump to address 1.
    pub fn proc(self: *const Api, name: [*:0]const u8) ?Proc {
        if (self.getProcAddress(name)) |p| {
            const addr = @intFromPtr(p);
            if (addr != 1 and addr != 2 and addr != 3 and
                addr != @as(usize, @bitCast(@as(isize, -1))))
            {
                return p;
            }
        }
        return win.GetProcAddress(self.module, name);
    }

    fn required(module: std.os.windows.HMODULE, name: [*:0]const u8) !Proc {
        return win.GetProcAddress(module, name) orelse {
            log.err("GL implementation is missing {s}", .{name});
            return error.GLLoaderIncomplete;
        };
    }

    fn load(module: std.os.windows.HMODULE, kind: Kind) !Api {
        // Optional, and only consulted for a standalone implementation: the
        // system driver's copies of these are the wrong ones to call.
        const own_choose = win.GetProcAddress(module, "wglChoosePixelFormat");
        const own_set = win.GetProcAddress(module, "wglSetPixelFormat");
        const own_swap = win.GetProcAddress(module, "wglSwapBuffers");
        const standalone = kind == .fallback and
            own_choose != null and own_set != null and own_swap != null;

        return .{
            .kind = kind,
            .module = module,
            .createContext = @ptrCast(try required(module, "wglCreateContext")),
            .makeCurrent = @ptrCast(try required(module, "wglMakeCurrent")),
            .deleteContext = @ptrCast(try required(module, "wglDeleteContext")),
            .getCurrentDC = @ptrCast(try required(module, "wglGetCurrentDC")),
            .getProcAddress = @ptrCast(try required(module, "wglGetProcAddress")),
            .choosePixelFormat = if (standalone)
                @ptrCast(own_choose.?)
            else
                win.ChoosePixelFormat,
            .setPixelFormat = if (standalone)
                @ptrCast(own_set.?)
            else
                win.SetPixelFormat,
            .swapBuffers = if (standalone)
                @ptrCast(own_swap.?)
            else
                win.SwapBuffers,
        };
    }
};

/// The implementation currently in use. Written once at first use and once
/// more if the fallback is taken — both on the UI thread, before any renderer
/// thread exists — and read from every thread thereafter.
var active_api: ?Api = null;
var active_lock: std.Thread.Mutex = .{};

/// The implementation to draw with, loading the system one on first use.
///
/// Both writes happen on the UI thread before any renderer thread exists, so
/// the common case is one unsynchronized read of an optional that has stopped
/// changing by the time a frame is drawn. A failure to load
/// System32's `opengl32.dll` at all is not a recoverable state — there is no
/// terminal without it — so this reports and terminates rather than propagating
/// an error into every call site that draws.
pub fn active() *const Api {
    if (active_api) |*api| return api;

    active_lock.lock();
    defer active_lock.unlock();
    if (active_api) |*api| return api;

    active_api = openSystem() catch |err| {
        log.err("cannot load the system OpenGL implementation: {}", .{err});
        @panic("system opengl32.dll could not be loaded");
    };
    log.info("OpenGL implementation: {s} (System32)", .{active_api.?.kind.label()});
    return &active_api.?;
}

/// Which implementation is active, without forcing a load. Used by the retry
/// decision, which must not itself be what loads GL.
pub fn activeKind() Kind {
    if (active_api) |api| return api.kind;
    return .system;
}

fn openSystem() !Api {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;

    // By EXPLICIT System32 search, never by bare name: bare name would search
    // the application directory first, which is the hijack this whole module
    // exists to make impossible.
    const name = std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll");
    const module = win.LoadLibraryExW(
        name,
        null,
        win.LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse return error.GLLoaderMissing;
    return Api.load(module, .system);
}

/// Where a fallback implementation would be found on this machine, or null when
/// there is none to find. Written into `buf` as UTF-16 because that is what
/// `LoadLibraryExW` takes and the path may contain a profile name that is not
/// representable any other way.
///
/// `GHOZTTY_GL_FALLBACK_DLL` overrides the shipped location in DEBUG BUILDS
/// ONLY. It is the seam that lets an acceptance script drive the fallback path
/// on a box with a perfectly good GPU and no shipped fallback yet — the same
/// reasoning as T1249's `GHOZTTY_GL_FORCE_VERSION`, and the same rule: an
/// environment variable must never be able to move a user's terminal onto a
/// different renderer.
pub fn fallbackPathW(buf: []u16) ?[:0]const u16 {
    if (comptime builtin.os.tag != .windows) return null;
    if (buf.len < 2) return null;

    if (comptime builtin.mode == .Debug) {
        if (std.process.getenvW(
            std.unicode.utf8ToUtf16LeStringLiteral("GHOZTTY_GL_FALLBACK_DLL"),
        )) |override| {
            if (override.len > 0 and override.len < buf.len) {
                @memcpy(buf[0..override.len], override);
                buf[override.len] = 0;
                const path = buf[0..override.len :0];
                return if (exists(path)) path else null;
            }
        }
    }

    // <dir holding ghoztty.exe>\gl\opengl32.dll
    var exe: [max_path]u16 = undefined;
    const n = win.GetModuleFileNameW(null, &exe, exe.len);
    if (n == 0 or n >= exe.len) return null;
    const sep = std.mem.lastIndexOfScalar(u16, exe[0..n], '\\') orelse return null;

    const rel = comptime std.unicode.utf8ToUtf16LeStringLiteral(
        "\\" ++ fallback_rel_dir ++ "\\" ++ fallback_dll,
    );
    const total = sep + rel.len;
    if (total + 1 > buf.len) return null;
    @memcpy(buf[0..sep], exe[0..sep]);
    @memcpy(buf[sep..total], rel);
    buf[total] = 0;

    const path = buf[0..total :0];
    return if (exists(path)) path else null;
}

fn exists(path: [:0]const u16) bool {
    return win.GetFileAttributesW(path) != win.INVALID_FILE_ATTRIBUTES;
}

/// True when a fallback implementation is present on this machine. Cheap enough
/// to ask on a failure path and never asked on a healthy one.
pub fn fallbackAvailable() bool {
    if (comptime builtin.os.tag != .windows) return false;
    var buf: [max_path]u16 = undefined;
    return fallbackPathW(&buf) != null;
}

/// Make the fallback implementation the active one. Returns false when there is
/// nothing to switch to or it will not load, which is the caller's cue to let
/// the original failure stand and put the T1249 dialog up.
///
/// The system module is left loaded rather than freed: a GL implementation
/// takes thread-local state and driver-side registrations with it, and
/// unloading one that just failed to produce a usable context is a way to crash
/// on the way to reporting a crash.
pub fn switchToFallback() bool {
    if (comptime builtin.os.tag != .windows) return false;

    active_lock.lock();
    defer active_lock.unlock();
    if (active_api) |api| if (api.kind == .fallback) return false;

    var buf: [max_path]u16 = undefined;
    const path = fallbackPathW(&buf) orelse return false;

    const module = win.LoadLibraryExW(
        path,
        null,
        win.LOAD_WITH_ALTERED_SEARCH_PATH,
    ) orelse {
        log.warn("fallback OpenGL present but would not load", .{});
        return false;
    };

    const api = Api.load(module, .fallback) catch |err| {
        log.warn("fallback OpenGL is not a usable WGL implementation: {}", .{err});
        return false;
    };

    active_api = api;
    logPath("OpenGL implementation: fallback", path);
    return true;
}

fn logPath(prefix: []const u8, path: [:0]const u16) void {
    var utf8: [max_path]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&utf8, path) catch {
        log.info("{s}", .{prefix});
        return;
    };
    log.info("{s} ({s})", .{ prefix, utf8[0..n] });
}

/// glad's loader, bound to whichever implementation is active. Passed to
/// `gl.glad.load` in place of null, which would send glad to its own built-in
/// `LoadLibraryA("opengl32.dll")` and undo the entire point of this module.
pub fn gladLoad(name: [*:0]const u8) callconv(.c) ?Proc {
    return active().proc(name);
}

// -------------------------------------------------------------------------
// Tests. The policy above is what these cover; the syscall half is covered by
// `test\win32\startup-failure.ps1`, which launches the real exe.
// -------------------------------------------------------------------------

test "fallbackRelPath: a subdirectory of the install, never beside the exe" {
    const testing = std.testing;
    var buf: [max_path]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\Program Files\\Ghoztty\\gl\\opengl32.dll",
        try fallbackRelPath(&buf, "C:\\Program Files\\Ghoztty"),
    );
}

test "fallbackRelPath: a trailing separator does not double" {
    const testing = std.testing;
    var buf: [max_path]u8 = undefined;
    try testing.expectEqualStrings(
        "D:\\gl\\opengl32.dll",
        try fallbackRelPath(&buf, "D:\\"),
    );
}

test "fallbackRelPath: a buffer too small errors instead of truncating" {
    const testing = std.testing;
    var buf: [8]u8 = undefined;
    try testing.expectError(
        error.NoSpaceLeft,
        fallbackRelPath(&buf, "C:\\Program Files\\Ghoztty"),
    );
}

test "shouldRetry: a version refusal with a fallback present is retried once" {
    const testing = std.testing;
    try testing.expect(shouldRetry(error.OpenGLOutdated, .system, true));
    try testing.expect(shouldRetry(error.GLInitFailed, .system, true));
}

test "shouldRetry: never without a fallback to retry with" {
    const testing = std.testing;
    try testing.expect(!shouldRetry(error.OpenGLOutdated, .system, false));
    try testing.expect(!shouldRetry(error.GLInitFailed, .system, false));
}

test "shouldRetry: never a second time - the dialog is the ending" {
    const testing = std.testing;
    try testing.expect(!shouldRetry(error.OpenGLOutdated, .fallback, true));
}

test "shouldRetry: failures that are not about GL are not retried" {
    const testing = std.testing;
    try testing.expect(!shouldRetry(error.Win32Error, .system, true));
    try testing.expect(!shouldRetry(error.OutOfMemory, .system, true));
    try testing.expect(!shouldRetry(error.WGLMakeCurrentFailed, .system, true));
}

test "Kind.label: the log says which one in words" {
    const testing = std.testing;
    try testing.expectEqualStrings("system", Kind.system.label());
    try testing.expectEqualStrings("fallback", Kind.fallback.label());
}
