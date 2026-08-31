//! The win32 half of the `ghoztty://` URL scheme (T695) — the Windows
//! counterpart of Mac's `GhozttyURLScheme.swift`. Three jobs, and nothing else:
//!
//!  1. **Registration.** Windows has no `Info.plist`, so the app writes its own
//!     `HKCU\Software\Classes\<scheme>` entry on launch (idempotent, off the
//!     GUI thread) — the per-user hive, never `HKLM`, because Ghoztty installs
//!     per user and a machine-wide association would need elevation.
//!  2. **Activation.** The shell launches the registered command with the URL
//!     as `argv[1]`. That process is not a terminal: it decodes the link,
//!     forwards a `focus` to the running instance over the IPC pipe, reports
//!     anything that went wrong, and exits.
//!  3. **In-app links.** A `ghoztty://` link clicked INSIDE Ghoztty — a pane
//!     banner, a viewer page — is handled in process and never round-trips
//!     through the shell, so it always means "this app" rather than "whichever
//!     build registered the scheme".
//!
//! The grammar, the one-verb threat model and the failure wording live in
//! `apprt/ipc/url_scheme.zig`, shared with the platform-neutral tests.
//!
//! ## Which build registers what
//!
//! A debug build registers `ghoztty-debug://` and a release build registers
//! `ghoztty://`, mirroring the IPC pipe's `-debug` split. That is what keeps a
//! dev build from stealing the user's links: the two schemes are different
//! names, so the shell never has to choose between them. Both spellings still
//! PARSE in both builds — see the shared module.
//!
//! The build-mode split is not enough on its own (T1124). The staging release
//! we build to package a delivery lives at `zig-out-release\bin` INSIDE the
//! checkout, and it is a release build, so launching it once pointed the user's
//! `ghoztty://` links at a scratch directory that ordinary development rebuilds,
//! moves and deletes. So the release scheme carries a LOCATION gate as well: a
//! build whose exe sits under a source checkout (an ancestor directory holding
//! `build.zig`) never claims it. A portable unpack and the installed release are
//! both outside a checkout and register exactly as before — the gate excludes
//! build output, not unusual install locations. Same shape as
//! `PathInstaller`'s canonical-install gate, and the same `force` escape hatch.
//!
//! ## Who shows the failure
//!
//! Whichever process noticed it, because they have different tools. The
//! activation process has no `App`, no theme and no window to own a dialog, so
//! it uses the system `MessageBoxW` and coalesces across processes with a named
//! mutex (a page can fire a burst of links, and each one is its own process
//! here — the Mac's single `application(_:open:)` array has no analog). An
//! in-app click has the app, so it gets the themed `ConfirmDialog` every other
//! Ghoztty prompt uses, coalesced with a flag.

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const build_config = @import("../../build_config.zig");
const apprt = @import("../../apprt.zig");
const internal_os = @import("../../os/main.zig");
const App = @import("App.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const source_checkout = @import("source_checkout.zig");

/// The shared grammar: `handles`, `parse`, and the failure wording.
pub const grammar = apprt.ipc.url_scheme;

const log = std.log.scoped(.win32_url_scheme);

/// A target longer than this is not a name anyone registered; refusing it is
/// how a link cannot hand an unbounded string to the resolver.
const max_target = 512;

/// Exit codes the activation process reports. A clicked link never shows them
/// to anyone, but an acceptance script (and `start /wait`) can read them, which
/// is what makes the failure paths testable without reading a dialog.
pub const exit_focused: u8 = 0;
pub const exit_not_found: u8 = 1;
pub const exit_unsupported: u8 = 2;

/// The scheme THIS build registers with the shell.
pub fn registeredScheme() []const u8 {
    return if (build_config.is_debug) grammar.debug_scheme else grammar.scheme;
}

/// `Software\Classes\<scheme>` — where a per-user protocol handler lives.
pub fn classKeyPath(buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "Software\\Classes\\{s}",
        .{registeredScheme()},
    ) catch null;
}

/// The `shell\open\command` value: this exe, quoted, plus the `"%1"` the shell
/// substitutes the clicked URL into. Quoted because an install path contains
/// spaces (`%LOCALAPPDATA%\Programs\Ghoztty` does not, but a portable unpack on
/// the Desktop does) and because an unquoted `%1` would split a URL containing
/// one.
pub fn commandValue(exe_path: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "\"{s}\" \"%1\"", .{exe_path}) catch null;
}

/// The `(Default)` value of the class key. The `URL:` prefix is the convention
/// the shell reads as "this class is a protocol", and the text after it is what
/// Explorer shows in its "how do you want to open this" surfaces.
pub fn classDescription(buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "URL:Ghoztty Protocol{s}",
        .{if (build_config.is_debug) " (debug)" else ""},
    ) catch null;
}

// ---------------------------------------------------------------------
// 1. Registration
// ---------------------------------------------------------------------

/// Register the scheme on a detached background thread. Registry writes are
/// fast but they are still I/O, and this runs during launch.
pub fn registerAsync() void {
    const thread = std.Thread.spawn(.{}, registerThread, .{}) catch |err| {
        log.warn("url scheme: thread spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

fn registerThread() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    register(arena_state.allocator()) catch |err| {
        log.warn("url scheme: registration failed: {}", .{err});
    };
}

/// Write (or refresh) the per-user protocol handler. Idempotent: the values are
/// unconditionally rewritten rather than compared, because the exe path moves
/// (an upgrade, a portable copy) and the last launch is the one that should
/// answer links.
fn register(arena: std.mem.Allocator) !void {
    const mode = envMode(arena);
    if (mode == .off) {
        log.info("url scheme: registration disabled by GHOZTTY_URL_SCHEME", .{});
        return;
    }

    const exe = try std.fs.selfExePathAlloc(arena);

    // Location gate (T1124). A release build is the one that answers the user's
    // links, so a release build that is really build OUTPUT — `zig-out-release`
    // in this very checkout is one — must not claim them. `force` is the escape
    // hatch; `gate` applies the same rule to a debug build, which is how the
    // acceptance script exercises this path without a release build in hand.
    if (mode != .force and (!build_config.is_debug or mode == .gate)) {
        const exe_dir = std.fs.path.dirname(exe) orelse exe;
        if (inSourceCheckout(arena, exe_dir)) {
            log.info(
                "url scheme: {s}:// not registered from a source checkout ({s})",
                .{ registeredScheme(), exe_dir },
            );
            return;
        }
    }

    var key_buf: [128]u8 = undefined;
    const class_path = classKeyPath(&key_buf) orelse return error.NameTooLong;

    var class_key: w32.HKEY = undefined;
    try createKey(arena, class_path, &class_key);
    defer _ = w32.RegCloseKey(class_key);

    var desc_buf: [64]u8 = undefined;
    const desc = classDescription(&desc_buf) orelse return error.NameTooLong;
    try setString(arena, class_key, "", desc);
    // The value the shell actually gates on. Its data is empty by convention;
    // its PRESENCE is what says "this class names a protocol".
    try setString(arena, class_key, "URL Protocol", "");

    var cmd_path_buf: [160]u8 = undefined;
    const cmd_path = std.fmt.bufPrint(
        &cmd_path_buf,
        "{s}\\shell\\open\\command",
        .{class_path},
    ) catch return error.NameTooLong;

    var cmd_key: w32.HKEY = undefined;
    try createKey(arena, cmd_path, &cmd_key);
    defer _ = w32.RegCloseKey(cmd_key);

    const cmd = try std.fmt.allocPrint(arena, "\"{s}\" \"%1\"", .{exe});
    try setString(arena, cmd_key, "", cmd);

    log.info("url scheme: {s}:// -> {s}", .{ registeredScheme(), exe });
}

/// What `GHOZTTY_URL_SCHEME` asks of the registration.
///
///  * `0` / `off` — register nothing. The escape hatch for a box where the user
///    wants their links to keep landing in a different build, and the way an
///    acceptance script proves registration is a deliberate act rather than a
///    side effect of launching.
///  * `force` — register regardless of where this exe lives (the location gate
///    below is skipped). Mirrors `GHOZTTY_PATH_SELFHEAL=force`.
///  * `gate` — apply the location gate even to a debug build. The seam the
///    acceptance script needs: it can prove a build inside a checkout registers
///    nothing without asking anyone to launch a release build at the user's
///    endpoints (T350).
pub const Mode = enum { default, off, force, gate };

pub fn parseMode(v: []const u8) Mode {
    if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(v, "force")) return .force;
    if (std.ascii.eqlIgnoreCase(v, "gate")) return .gate;
    return .default;
}

fn envMode(arena: std.mem.Allocator) Mode {
    const v = std.process.getEnvVarOwned(arena, "GHOZTTY_URL_SCHEME") catch return .default;
    return parseMode(v);
}

/// Does this exe sit inside a source checkout? Shared with the agent autostart
/// gate (T1146), which asks the identical question about the identical hazard —
/// see `source_checkout.zig`.
pub const inSourceCheckout = source_checkout.inSourceCheckout;

fn createKey(arena: std.mem.Allocator, path: []const u8, out: *w32.HKEY) !void {
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, path);
    var disposition: u32 = 0;
    if (w32.RegCreateKeyExW(
        w32.HKEY_CURRENT_USER,
        path_w.ptr,
        0,
        null,
        0,
        w32.KEY_SET_VALUE,
        null,
        out,
        &disposition,
    ) != w32.ERROR_SUCCESS) return error.RegCreateFailed;
}

fn setString(
    arena: std.mem.Allocator,
    key: w32.HKEY,
    name: []const u8,
    value: []const u8,
) !void {
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, name);
    const value_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, value);
    if (w32.RegSetValueExW(
        key,
        name_w.ptr,
        0,
        w32.REG_SZ,
        @ptrCast(value_w.ptr),
        @intCast((value_w.len + 1) * 2),
    ) != w32.ERROR_SUCCESS) return error.RegSetFailed;
}

// ---------------------------------------------------------------------
// 2. Activation (this process was launched BY a link)
// ---------------------------------------------------------------------

/// Is this process a URL activation? Returns the exit code to leave with, or
/// null when no argument is a `ghoztty://` URL and this is an ordinary launch.
///
/// Asked before the app builds anything — before the single-instance bind,
/// before a window, before config parsing — because an activation must never
/// look like a second instance of the app (which would forward a `new-window`
/// and open a terminal nobody asked for).
pub fn runActivation(alloc: std.mem.Allocator) ?u8 {
    const args = std.process.argsAlloc(alloc) catch return null;
    defer std.process.argsFree(alloc, args);
    const url = urlArg(args) orelse return null;
    return handleActivation(alloc, url);
}

/// The `ghoztty://` URL in a command line, or null when there is none.
///
/// The scan STOPS at `-e` (and at a bare `--`), because everything after it is
/// the child's argv and belongs to the command being run — `ghoztty -e echo
/// ghoztty://focus/x` asks to print a string, not to focus a window, and
/// hijacking it would make an ordinary launch disappear into an activation.
pub fn urlArg(args: []const []const u8) ?[]const u8 {
    if (args.len < 2) return null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--")) return null;
        if (grammar.handles(arg)) return arg;
    }
    return null;
}

fn handleActivation(alloc: std.mem.Allocator, url: []const u8) u8 {
    var target_buf: [max_target]u8 = undefined;
    const cmd = grammar.parse(url, &target_buf) orelse {
        log.info("url scheme: unsupported link {s}", .{url});
        present(.{ .unsupported_link = url });
        return exit_unsupported;
    };

    switch (cmd) {
        .focus => |target| {
            const arg = std.fmt.allocPrintSentinel(
                alloc,
                "--target={s}",
                .{target},
                0,
            ) catch return exit_not_found;
            defer alloc.free(arg);

            const ok = internal_os.ipc_client.sendAction(
                alloc,
                "focus",
                &.{arg},
            ) catch |err| miss: {
                // No running instance is the cold-click case, and the honest
                // answer is the same as any other miss: nothing is open by
                // that name. Launching the app would be window creation from
                // the one scheme that must never create anything.
                log.info("url scheme: focus '{s}' failed: {}", .{ target, err });
                break :miss false;
            };
            if (!ok) {
                present(.{ .target_not_found = target });
                return exit_not_found;
            }
            log.info("url scheme: focused '{s}'", .{target});
            return exit_focused;
        },
    }
}

// ---------------------------------------------------------------------
// 3. In-app links
// ---------------------------------------------------------------------

/// Handle a `ghoztty://` link clicked inside Ghoztty. Returns whether the focus
/// landed; a miss is reported to the user here rather than by a second process.
///
/// `owner` is the window the click came from, so the warning reads as "that
/// link failed" rather than as an app-wide problem — Mac attaches its sheet to
/// the key window for the same reason.
pub fn handleInApp(app: *App, owner: ?w32.HWND, scale: f32, url: []const u8) bool {
    var target_buf: [max_target]u8 = undefined;
    const cmd = grammar.parse(url, &target_buf) orelse {
        log.info("url scheme: unsupported in-app link {s}", .{url});
        presentInApp(app, owner, scale, .{ .unsupported_link = url });
        return false;
    };

    switch (cmd) {
        .focus => |target| {
            const entry = app.ipcLookup(target) orelse {
                log.info("url scheme: in-app focus '{s}' not found", .{target});
                presentInApp(app, owner, scale, .{ .target_not_found = target });
                return false;
            };
            IpcHandlers.focusTarget(entry);
            // The one observable of the in-app path: it never touches IPC, so
            // `IPC: focused` (the activation path's oracle) is not emitted here
            // and an acceptance script would otherwise have nothing to read.
            log.info("url scheme: in-app focus '{s}'", .{target});
            return true;
        },
    }
}

/// True while a failure dialog is up, so a burst of in-app links produces ONE
/// dialog instead of one per link. A page in a viewer pane can fire the scheme
/// as fast as it likes.
var presenting_in_app: bool = false;

fn presentInApp(app: *App, owner: ?w32.HWND, scale: f32, failure: grammar.Failure) void {
    if (presenting_in_app) return;
    if (quiet()) {
        logFailure(failure);
        return;
    }
    presenting_in_app = true;
    defer presenting_in_app = false;

    var title_buf: [max_target + 64]u8 = undefined;
    var body_buf: [max_target + 256]u8 = undefined;
    var title_w: [max_target + 64:0]u16 = undefined;
    var body_w: [max_target + 256:0]u16 = undefined;

    const title = toWide(failure.title(&title_buf), &title_w) orelse return;
    const body = toWide(failure.body(&body_buf), &body_w) orelse return;

    _ = ConfirmDialog.show(app, owner, scale, null, .{
        .title = title.ptr,
        .text = body,
        .style = .ok_only,
        .icon = .warning,
    });
}

// ---------------------------------------------------------------------
// Failure presentation (activation process)
// ---------------------------------------------------------------------

/// `GHOZTTY_URL_SCHEME_QUIET=1` logs the failure instead of showing it. The
/// dialog is modal and this process exits only once it is dismissed, so an
/// acceptance script asserting "a bad link does NOTHING" would otherwise hang
/// on the proof that it said so.
fn quiet() bool {
    var buf: [16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const v = std.process.getEnvVarOwned(fba.allocator(), "GHOZTTY_URL_SCHEME_QUIET") catch return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

fn logFailure(failure: grammar.Failure) void {
    var title_buf: [max_target + 64]u8 = undefined;
    var body_buf: [max_target + 256]u8 = undefined;
    log.warn("url scheme: {s} - {s}", .{
        failure.title(&title_buf),
        failure.body(&body_buf),
    });
}

/// Tell the user why the link did nothing.
///
/// Coalesced across PROCESSES: every click is its own activation here, so the
/// flag the Mac uses cannot see the burst. A named mutex can — whoever holds it
/// owns the dialog, and everyone else exits quietly with the same code.
fn present(failure: grammar.Failure) void {
    if (quiet()) {
        logFailure(failure);
        return;
    }

    const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral(
        "Local\\GhozttyUrlSchemeWarning",
    );
    const mutex = w32.CreateMutexW(null, 0, mutex_name);
    if (mutex != null and w32.GetLastError() == ERROR_ALREADY_EXISTS) {
        logFailure(failure);
        return;
    }
    defer if (mutex) |m| {
        _ = w32.CloseHandle(m);
    };

    var title_buf: [max_target + 64]u8 = undefined;
    var body_buf: [max_target + 256]u8 = undefined;
    var title_w: [max_target + 64:0]u16 = undefined;
    var body_w: [max_target + 256:0]u16 = undefined;

    const title = toWide(failure.title(&title_buf), &title_w) orelse return;
    const body = toWide(failure.body(&body_buf), &body_w) orelse return;

    _ = w32.MessageBoxW(null, body.ptr, title.ptr, w32.MB_OK | w32.MB_ICONWARNING);
}

const ERROR_ALREADY_EXISTS: u32 = 183;

fn toWide(s: []const u8, buf: anytype) ?[:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(buf[0..], s) catch return null;
    if (n >= buf.len) return null;
    buf[n] = 0;
    return buf[0..n :0];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "the registered scheme follows the build's endpoint split" {
    // Same rule as the IPC pipe's `-debug` suffix: a dev build must never be
    // the thing the user's links land in.
    const s = registeredScheme();
    if (build_config.is_debug) {
        try testing.expectEqualStrings(grammar.debug_scheme, s);
    } else {
        try testing.expectEqualStrings(grammar.scheme, s);
    }
    // Whichever it is, the parser answers to it.
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}://focus/dev", .{s});
    try testing.expect(grammar.handles(url));
}

test "the class key is per-user and names the registered scheme" {
    var buf: [128]u8 = undefined;
    const path = classKeyPath(&buf).?;
    try testing.expect(std.mem.startsWith(u8, path, "Software\\Classes\\"));
    try testing.expect(std.mem.endsWith(u8, path, registeredScheme()));
    // HKLM would need elevation and would answer for every user on the box.
    try testing.expect(std.mem.indexOf(u8, path, "HKEY") == null);
}

test "the command quotes both the exe and the substituted URL" {
    var buf: [256]u8 = undefined;
    const cmd = commandValue("C:\\Program Files\\Ghoztty\\ghoztty.exe", &buf).?;
    try testing.expectEqualStrings(
        "\"C:\\Program Files\\Ghoztty\\ghoztty.exe\" \"%1\"",
        cmd,
    );
    // An unquoted %1 would split a URL on its first space.
    try testing.expect(std.mem.indexOf(u8, cmd, "\"%1\"") != null);
}

test "the class description carries the URL: prefix the shell gates on" {
    var buf: [64]u8 = undefined;
    const desc = classDescription(&buf).?;
    try testing.expect(std.mem.startsWith(u8, desc, "URL:"));
    // A debug build says so, so the two entries are told apart in regedit.
    try testing.expectEqual(
        build_config.is_debug,
        std.mem.indexOf(u8, desc, "(debug)") != null,
    );
}

test "the URL is found among ordinary arguments, and not past -e" {
    const exe = "ghoztty.exe";
    // The shape the shell launches: `"<exe>" "<url>"`.
    try testing.expectEqualStrings(
        "ghoztty://focus/dev",
        urlArg(&.{ exe, "ghoztty://focus/dev" }).?,
    );
    // An ordinary launch is not an activation.
    try testing.expect(urlArg(&.{exe}) == null);
    try testing.expect(urlArg(&.{ exe, "--session-persistence=false" }) == null);
    // A flag whose VALUE merely contains the scheme is not the URL.
    try testing.expect(urlArg(&.{ exe, "--title=ghoztty://focus/dev" }) == null);
    // Everything after `-e` is the child's argv: `ghoztty -e echo <url>` asks
    // to print a string, and turning that into a focus would make the launch
    // vanish.
    try testing.expect(urlArg(&.{ exe, "-e", "echo", "ghoztty://focus/dev" }) == null);
    try testing.expect(urlArg(&.{ exe, "--", "ghoztty://focus/dev" }) == null);
    // ...but a URL BEFORE it still counts (nothing sane produces this; the
    // rule is "stop at -e", not "give up if -e appears").
    try testing.expectEqualStrings(
        "ghoztty://focus/dev",
        urlArg(&.{ exe, "ghoztty://focus/dev", "-e", "echo", "hi" }).?,
    );
}

test "GHOZTTY_URL_SCHEME spells out off, force and gate" {
    try testing.expectEqual(Mode.off, parseMode("0"));
    try testing.expectEqual(Mode.off, parseMode("off"));
    try testing.expectEqual(Mode.off, parseMode("OFF"));
    try testing.expectEqual(Mode.force, parseMode("force"));
    try testing.expectEqual(Mode.gate, parseMode("gate"));
    // Anything else is the ordinary launch, not an error: an unrecognised value
    // must never turn registration off by accident.
    try testing.expectEqual(Mode.default, parseMode(""));
    try testing.expectEqual(Mode.default, parseMode("1"));
    try testing.expectEqual(Mode.default, parseMode("yes please"));
}

test "exit codes tell the two failures apart" {
    try testing.expect(exit_focused != exit_not_found);
    try testing.expect(exit_not_found != exit_unsupported);
    try testing.expectEqual(@as(u8, 0), exit_focused);
}
