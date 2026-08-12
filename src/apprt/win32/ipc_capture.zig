//! The `capture-pane` IPC action (T275): write a PNG of a named terminal
//! pane's RENDERED content to a caller-supplied path.
//!
//! ## This is a test seam, not a product verb, and that is deliberate
//!
//! There is no `ghoztty +capture-pane` CLI command and there is not going to
//! be one. `src/cli/ghostty.zig`'s `Action` enum is shared by every apprt, so
//! a verb added there is a CROSS-PLATFORM CLI surface — the exact divergence
//! CLAUDE.md rules out and the reason `+relay-login` was removed in T141. What
//! this feature is FOR is an acceptance harness proving that the OpenGL glass
//! is showing what it should, off the background desktop where no composite
//! exists; the value of pixels to a user of an agent-driven terminal is far
//! below the value of `+read`'s text, and a screenshot verb shipped for the
//! suite's convenience is a surface we would then have to keep forever on both
//! platforms.
//!
//! So the action is reachable only over the IPC endpoint, only from a build
//! where `build_config.is_debug` holds (Debug/ReleaseSafe), and the harness
//! frames the request itself (`test/win32/lib/PaneCapture.ps1`). A shipped
//! ReleaseFast build answers `unknown action: capture-pane`, exactly as it does
//! for a verb it has never heard of. That gate costs the suite nothing: T350
//! already requires every acceptance script to run against a Debug build,
//! because the IPC endpoint, the agent pipe and the state directory are all
//! derived from the build mode.
//!
//! ## The wire shape
//!
//! ```
//! {"action":"capture-pane","arguments":[
//!    "--target=<pane|window|pane-id>","--path=<file.png>",
//!    "--width=<px>","--height=<px>"]}
//! ```
//!
//! → `{"success":true,"data":{"path":…,"width":N,"height":N,"bytes":N}}`
//!
//! `--target` goes through the same resolver every other verb uses, so a
//! registered pane name, a window name (its focused pane), or a `$GHOZTTY_PANE_ID`
//! all work. Sizes default to the pane's own client size.
const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const build_config = @import("../../build_config.zig");
const pane_capture = @import("pane_capture.zig");
const png_encode = @import("png_encode.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_ipc);

/// True when this build exposes the action at all. Callers dispatch on it so a
/// release build's answer is the ordinary "unknown action", not a special
/// refusal that would advertise the seam's existence and its spelling.
pub const enabled = build_config.is_debug;

/// How long the GUI thread waits for the pane's renderer thread to deliver the
/// capture. Generous on purpose: an IDLE pane produces no new frame until its
/// next wakeup, and the request has to travel to the renderer, wake it, blit,
/// read back and store. Hero mode's own thumbnails arrive within a couple of
/// frames; five seconds is "the renderer is wedged", not "the box is busy".
const capture_timeout_ms: u64 = 5_000;

/// Handle one `capture-pane` request on the GUI thread. Returns the response
/// JSON (allocated from `alloc`; the listener frees it).
pub fn handle(
    app: *App,
    alloc: Allocator,
    arguments: ?[]const []const u8,
) Allocator.Error![]u8 {
    const req = pane_capture.parse(arguments) catch |err| return switch (err) {
        error.MissingTarget => errorResponse(alloc, "--target is required for capture-pane", .{}),
        error.MissingPath => errorResponse(alloc, "--path is required for capture-pane", .{}),
        error.BadDimension => errorResponse(
            alloc,
            "--width/--height must be 1..{d}",
            .{pane_capture.max_dimension},
        ),
    };

    // Every failure below names a DIFFERENT state, for the reason T181 gave
    // `+read` the same treatment: a caller that cannot tell "no such pane"
    // from "that pane has no glass" from "the renderer never answered" cannot
    // react to any of them, and a harness that cannot tell them apart reports
    // a product bug for a fixture mistake.
    const entry = app.ipcLookup(req.target) orelse
        return errorResponse(alloc, "pane '{s}' not found in registry", .{req.target});
    const pane = switch (entry) {
        .pane => |p| p,
        .window => |win| if (win.tab_count == 0)
            return errorResponse(alloc, "pane '{s}' is no longer alive", .{req.target})
        else
            win.tab_active_pane[win.active_tab],
    };
    const surface = pane.surface() orelse
        return errorResponse(alloc, "{s} is a viewer pane, not a terminal", .{req.target});
    if (!surface.core_surface_ready)
        return errorResponse(alloc, "pane '{s}' is not capturable: its terminal never finished starting up", .{req.target});

    const client = clientSize(surface);
    const size = pane_capture.resolveSize(client.w, client.h, req) orelse
        return errorResponse(alloc, "pane '{s}' has no content area to capture", .{req.target});

    const readback = try alloc.alloc(u8, pane_capture.readbackLen(size));
    defer alloc.free(readback);
    surface.captureContent(size.w, size.h, readback, capture_timeout_ms) catch |err| return switch (err) {
        error.NotReady => errorResponse(alloc, "pane '{s}' is no longer alive", .{req.target}),
        error.WrongSize => errorResponse(alloc, "capture size {d}x{d} was refused", .{ size.w, size.h }),
        // The renderer never delivered: no frame has EVER presented for this
        // pane (nothing to read back), or its thread is wedged. Both are the
        // caller's cue to look at the pane, not to retry forever.
        error.Timeout => errorResponse(
            alloc,
            "pane '{s}' produced no frame to capture within {d}ms",
            .{ req.target, capture_timeout_ms },
        ),
    };

    const rgb = pane_capture.allocRgbTopDown(alloc, readback, size) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadPixels => return errorResponse(alloc, "capture buffer did not match {d}x{d}", .{ size.w, size.h }),
    };
    defer alloc.free(rgb);

    const png = png_encode.encode(alloc, .{
        .data = rgb,
        .width = size.w,
        .height = size.h,
        .channels = .rgb,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(alloc, "PNG encode failed ({s})", .{@errorName(err)}),
    };
    defer alloc.free(png);

    writeFile(req.path, png) catch |err| return errorResponse(
        alloc,
        "could not write '{s}' ({s})",
        .{ req.path, @errorName(err) },
    );

    log.info("capture-pane target={s} {d}x{d} -> {s} ({d} bytes)", .{
        req.target, size.w, size.h, req.path, png.len,
    });

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("path") catch break :write;
        jws.write(req.path) catch break :write;
        jws.objectField("width") catch break :write;
        jws.write(size.w) catch break :write;
        jws.objectField("height") catch break :write;
        jws.write(size.h) catch break :write;
        jws.objectField("bytes") catch break :write;
        jws.write(png.len) catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

const ClientSize = struct { w: i32, h: i32 };

/// The pane's terminal window in PIXELS. Zero when the pane has no window yet,
/// which `resolveSize` turns into an explicit refusal.
fn clientSize(surface: *Surface) ClientSize {
    const hwnd = surface.hwnd orelse return .{ .w = 0, .h = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return .{ .w = 0, .h = 0 };
    return .{ .w = rect.right - rect.left, .h = rect.bottom - rect.top };
}

/// Write the PNG, creating/truncating. Deliberately NOT atomic-renamed the way
/// a feedback report is: the reader here is an acceptance script that asked for
/// this exact path a moment ago, and a temp sibling would just be one more file
/// for it to clean up.
fn writeFile(path: []const u8, bytes: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn errorResponse(
    alloc: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error![]u8 {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(false) catch break :write;
        jws.objectField("error") catch break :write;
        jws.write(msg) catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}
