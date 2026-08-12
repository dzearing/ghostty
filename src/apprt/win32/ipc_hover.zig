//! The `capture-hover` IPC action (T282): write a PNG of a window painted
//! WHILE A POINT OF IT IS HOVERED, to a caller-supplied path.
//!
//! ## What it is for
//!
//! Hover fills were unassertable in pixels off the input desktop, because a
//! posted `WM_MOUSEMOVE` cannot survive to the paint it dirties: the OS posts
//! `WM_MOUSELEAVE` within a frame (there is no real cursor for
//! `TrackMouseEvent` to watch) and `WM_PAINT` is the lowest-priority message
//! in the queue, so the leave is drained FIRST and the frame that gets painted
//! is the un-hovered one. `hover_capture.zig`'s header has the full statement
//! and the measurements; the short version is that it is an ordering problem,
//! not a race, so no faster capture wins it.
//!
//! ## The ordering guarantee, stated rather than hoped for
//!
//! Everything below happens on the GUI thread inside ONE handler call:
//!
//!   1. `WM_NCHITTEST` at the point (sent — a direct call to our own window
//!      procedure, since sender and target share a thread),
//!   2. the move — `WM_MOUSEMOVE` with client coordinates, or `WM_NCMOUSEMOVE`
//!      with the hit code and screen coordinates, routed exactly the way
//!      `Send-TestMouse` routes it (T263) — sent, so the hover state and its
//!      `InvalidateRect` happen on this stack,
//!   3. `RedrawWindow(RDW_UPDATENOW)`, which SENDS `WM_PAINT` on this stack,
//!   4. `PrintWindow(PW_RENDERFULLCONTENT)` into a DIB section.
//!
//! A posted message is only ever drained by the message loop, and the message
//! loop is not reached between (2) and (4) — the thread is inside this
//! function the whole time. So the `WM_MOUSELEAVE` that (2) arms cannot land
//! in the middle of the probe, whatever the box is doing. That is the
//! property, and it is about who is on the stack rather than about speed.
//!
//! Nothing is un-done afterwards: the leave arrives on the next pump and
//! clears the hover exactly as it does today. The probe leaves no latched
//! state for the next assertion to trip over, which is why this is a capture
//! rather than a "suppress the leave while a debug flag is set" switch — that
//! one is product code whose failure mode is a hover stuck lit.
//!
//! ## Same gate, same reasons as `capture-pane`
//!
//! Debug/ReleaseSafe builds only, reachable over the IPC endpoint only, and
//! there is deliberately no `ghoztty +capture-hover` CLI verb — see
//! `ipc_capture.zig`'s header for the argument (a verb in
//! `src/cli/ghostty.zig`'s `Action` enum is a cross-platform CLI surface and a
//! Mac obligation, the T141 rule). The harness frames the request itself in
//! `test/win32/lib/HoverCapture.ps1`.
//!
//! ## The wire shape
//!
//! ```
//! {"action":"capture-hover","arguments":[
//!    "--hwnd=<decimal>","--x=<screen px>","--y=<screen px>",
//!    "--path=<file.png>","--client"]}
//! ```
//!
//! → `{"success":true,"data":{"path":…,"width":N,"height":N,"bytes":N,
//!      "hit":N,"nonclient":true|false,"left":N,"top":N}}`
//!
//! `hit`/`nonclient` are reported because a probe that lands on the wrong
//! ROUTE and a probe that lands on an unlit control look identical in pixels —
//! the harness asserts the route it expected the same way `Get-TestMouseRoute`
//! lets a script assert "this point is the minimize button" before clicking.
//! `left`/`top` are the window rect's screen origin, so a migrated probe keeps
//! its screen-coordinate math.
const std = @import("std");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const hover_capture = @import("hover_capture.zig");
const ipc_capture = @import("ipc_capture.zig");
const png_encode = @import("png_encode.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_ipc);

/// True when this build exposes the action at all. Callers dispatch on it so a
/// release build's answer is the ordinary "unknown action", not a special
/// refusal that would advertise the seam's existence and its spelling.
pub const enabled = build_config.is_debug;

/// Handle one `capture-hover` request on the GUI thread. Returns the response
/// JSON (allocated from `alloc`; the listener frees it).
pub fn handle(alloc: Allocator, arguments: ?[]const []const u8) Allocator.Error![]u8 {
    const req = hover_capture.parse(arguments) catch |err| return switch (err) {
        error.BadHwnd => ipc_capture.errorResponse(alloc, "--hwnd must be a nonzero window handle", .{}),
        error.MissingPath => ipc_capture.errorResponse(alloc, "--path is required for capture-hover", .{}),
        error.BadCoord => ipc_capture.errorResponse(alloc, "--x and --y are required screen coordinates", .{}),
    };

    // Every refusal below names a DIFFERENT state, for the reason T181 gave
    // `+read` the same treatment: a harness that cannot tell "that window is
    // gone" from "that window is somebody else's" from "the capture came back
    // empty" reports a product bug for a fixture mistake.
    const hwnd: w32.HWND = @ptrFromInt(req.hwnd);
    if (w32.IsWindow(hwnd) == 0)
        return ipc_capture.errorResponse(alloc, "hwnd {d} is not a window", .{req.hwnd});

    var pid: u32 = 0;
    const tid = w32.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != w32.GetCurrentProcessId())
        return ipc_capture.errorResponse(
            alloc,
            "hwnd {d} belongs to process {d}, not to this app",
            .{ req.hwnd, pid },
        );
    // The ordering guarantee in this file's header is exactly "sender and
    // target share a thread", so a window on some other thread of ours is
    // refused rather than probed with the guarantee quietly gone. Nothing in
    // the app creates windows off the GUI thread today; if something ever
    // does, this says so instead of returning a picture that means nothing.
    if (tid != w32.GetCurrentThreadId())
        return ipc_capture.errorResponse(
            alloc,
            "hwnd {d} is owned by thread {d}, not by the GUI thread — the hover could not be held",
            .{ req.hwnd, tid },
        );

    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) == 0)
        return ipc_capture.errorResponse(alloc, "hwnd {d} has no window rect", .{req.hwnd});
    const size = hover_capture.resolveSize(rect.right - rect.left, rect.bottom - rect.top) orelse
        return ipc_capture.errorResponse(
            alloc,
            "hwnd {d} is {d}x{d}: nothing to capture",
            .{ req.hwnd, rect.right - rect.left, rect.bottom - rect.top },
        );

    // ---- the probe: no message loop is reached from here to `capture` -----
    const hit: i32 = @truncate(w32.SendMessageW(
        hwnd,
        w32.WM_NCHITTEST,
        0,
        hover_capture.packPoint(req.x, req.y),
    ));
    const nonclient = !req.client_only and hover_capture.isNonClient(hit);
    if (nonclient) {
        // The NC messages carry the hit code where the client ones carry the
        // MK_* flags, and their lparam is the SCREEN point.
        _ = w32.SendMessageW(
            hwnd,
            w32.WM_NCMOUSEMOVE,
            @intCast(@as(u32, @bitCast(hit))),
            hover_capture.packPoint(req.x, req.y),
        );
    } else {
        var p: w32.POINT = .{ .x = req.x, .y = req.y };
        _ = w32.ScreenToClient(hwnd, &p);
        _ = w32.SendMessageW(hwnd, w32.WM_MOUSEMOVE, 0, hover_capture.packPoint(p.x, p.y));
    }
    // Invalidate the WHOLE window rather than trusting the hover handler's own
    // partial invalidation: what a probe wants is one consistent frame, and a
    // control that lights something outside the rect it invalidated is a bug
    // this capture should be able to SEE rather than one it hides.
    // Deliberately no RDW_ERASE — erasing with the class brush would flash a
    // background under anything the paint does not cover, and the capture
    // would record the flash.
    _ = w32.RedrawWindow(
        hwnd,
        null,
        null,
        w32.RDW_INVALIDATE | w32.RDW_UPDATENOW | w32.RDW_ALLCHILDREN,
    );

    const png = capture(alloc, hwnd, size) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoDc => return ipc_capture.errorResponse(alloc, "could not make a capture surface for hwnd {d}", .{req.hwnd}),
        error.PrintFailed => return ipc_capture.errorResponse(alloc, "PrintWindow failed for hwnd {d}", .{req.hwnd}),
        error.BadPixels => return ipc_capture.errorResponse(alloc, "capture buffer did not match {d}x{d}", .{ size.w, size.h }),
        error.EncodeFailed => return ipc_capture.errorResponse(alloc, "PNG encode failed for hwnd {d}", .{req.hwnd}),
    };
    defer alloc.free(png);

    ipc_capture.writeFile(req.path, png) catch |err| return ipc_capture.errorResponse(
        alloc,
        "could not write '{s}' ({s})",
        .{ req.path, @errorName(err) },
    );

    log.info("capture-hover hwnd={d} at {d},{d} hit={d} nc={} {d}x{d} -> {s} ({d} bytes)", .{
        req.hwnd, req.x, req.y, hit, nonclient, size.w, size.h, req.path, png.len,
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
        jws.objectField("hit") catch break :write;
        jws.write(hit) catch break :write;
        jws.objectField("nonclient") catch break :write;
        jws.write(nonclient) catch break :write;
        jws.objectField("left") catch break :write;
        jws.write(rect.left) catch break :write;
        jws.objectField("top") catch break :write;
        jws.write(rect.top) catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

const CaptureError = error{ NoDc, PrintFailed, BadPixels, EncodeFailed };

/// `PrintWindow` the window into a top-down 32-bit DIB and encode it.
///
/// `PW_RENDERFULLCONTENT` is the only capture that works on a BACKGROUND
/// desktop — the same call `test/win32/lib/TestDesktop.ps1` makes from outside,
/// so what a script sees through this action and what it sees through
/// `Get-TestWindowPixels` are the same pixels by construction, and only the
/// ORDERING differs. Negative `biHeight` so the rows arrive in the order
/// `png_encode` wants and nothing has to flip.
fn capture(
    alloc: Allocator,
    hwnd: w32.HWND,
    size: hover_capture.Size,
) (Allocator.Error || CaptureError)![]u8 {
    const win_dc = w32.GetDC(hwnd) orelse return error.NoDc;
    defer _ = w32.ReleaseDC(hwnd, win_dc);

    var bits_ptr: ?*anyopaque = null;
    const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = @intCast(size.w),
        .biHeight = -@as(i32, @intCast(size.h)),
        .biBitCount = 32,
    } };
    const section = w32.CreateDIBSection(
        win_dc,
        &bmi,
        w32.DIB_RGB_COLORS,
        &bits_ptr,
        null,
        0,
    ) orelse return error.NoDc;
    defer _ = w32.DeleteObject(section);
    const bits: [*]const u8 = @ptrCast(bits_ptr orelse return error.NoDc);

    const mem_dc = w32.CreateCompatibleDC(win_dc) orelse return error.NoDc;
    defer _ = w32.DeleteDC(mem_dc);
    const old = w32.SelectObject(mem_dc, section);
    defer _ = w32.SelectObject(mem_dc, old);

    if (w32.PrintWindow(hwnd, mem_dc, w32.PW_RENDERFULLCONTENT) == 0)
        return error.PrintFailed;

    const rgb = hover_capture.allocRgb(
        alloc,
        bits[0..hover_capture.dibLen(size)],
        size,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadPixels => return error.BadPixels,
    };
    defer alloc.free(rgb);

    return png_encode.encode(alloc, .{
        .data = rgb,
        .width = size.w,
        .height = size.h,
        .channels = .rgb,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EncodeFailed,
    };
}
