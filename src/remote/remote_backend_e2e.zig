//! `remote-backend-e2e` — the WP4 headless RENDER de-risk harness.
//!
//! `wp4-e2e` proves the *Connection* level: `openChannel` round-trips DATA into a
//! pane's inbound ring. But the GUI bug is one layer UP: the window opens, the
//! title is right, yet the terminal grid stays BLANK — remote output never lands
//! on the `terminal.Terminal`. The missing link is the backend's drain path
//! (`termio.Remote`): the demux thread pushes DATA into `pane.ring` and pings an
//! `xev.Async`; the pane's IO thread must drain that ring → `Termio.processOutput`
//! → terminal. `wp4-e2e` reads the ring directly and so cannot see whether the
//! grid ever renders.
//!
//! THIS harness drives the EXACT GUI lifecycle headlessly (no Cocoa, no renderer
//! thread): it builds a real `terminal.Terminal`, a real `termio.Termio` with a
//! `.remote` backend pointed at a real `Connection` (dialed over TCP to the real
//! `ghoztty-agent`), spins up a real `termio.Thread` (real `xev` loop) the same
//! way `Surface` does, and crucially reproduces the GUI's SIZE sequence:
//!
//!   - The surface is created at **0x0** — exactly the GUI, where
//!     `ghostty_surface_new` runs BEFORE the Cocoa SurfaceView lays out, so
//!     `getSize()` is 0x0 and the OPEN goes out at 0 rows/cols.
//!   - The real window size arrives later as a **resize** (0x0 → 80x24), the same
//!     `.resize` mailbox message the apprt posts post-layout.
//!
//! Then it asserts, in two phases:
//!   PHASE A — with NO keystrokes, the remote shell's own prompt renders on the
//!             GRID (a fresh remote window must show its prompt). If it stays
//!             blank, that IS the GUI's blank window, reproduced with zero input.
//!   PHASE B — `echo render-check\r` is sent via the mailbox and the marker is
//!             asserted to render on the GRID.
//!
//! The bug: the `.remote` backend RECORDED resizes but never forwarded a RESIZE
//! to the agent (`resize` was a no-op past recording; the real sender was dead
//! code). So the remote pty stayed 0x0 and the shell never painted → BLANK. The
//! grid assertion here is the thing the GUI lacks. FAILS before the fix (0-byte
//! grid), PASSES after.
//!
//! ## Usage
//!   remote-backend-e2e [path-to-ghoztty-agent]
//! Exits 0 on PASS (grid rendered the marker), non-zero on FAIL (blank grid).

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const tcp_dial = @import("tcp_dial.zig");

const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const terminalpkg = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");

const marker = "render-check";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const agent_path = try resolveAgentPath(alloc);
    defer alloc.free(agent_path);

    const port = try freePort();
    var addr_buf: [32]u8 = undefined;
    const listen_arg = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port});

    diag("[remote-backend-e2e] spawning agent: {s} --listen {s}\n", .{ agent_path, listen_arg });
    var child = std.process.Child.init(
        &.{ agent_path, "--listen", listen_arg },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try cloneEnv(alloc, &env);
    try env.put("GHOZTTY_AGENT_ENCODING", "raw");
    child.env_map = &env;
    try child.spawn();

    var reaped = false;
    defer if (!reaped) {
        _ = child.kill() catch {};
    };

    try waitForListening(alloc, &child);

    const rendered = runProof(alloc, port) catch |err| {
        diag("[remote-backend-e2e] FAIL: {s}\n", .{@errorName(err)});
        _ = child.kill() catch {};
        reaped = true;
        std.process.exit(1);
    };

    _ = child.kill() catch {};
    reaped = true;

    if (rendered) {
        const stdout = std.fs.File.stdout();
        stdout.writeAll("PASS: terminal grid rendered '" ++ marker ++ "' from the remote backend (drain path works)\n") catch {};
        std.process.exit(0);
    } else {
        diag("[remote-backend-e2e] FAIL: terminal grid never rendered the marker (BLANK — drain path broken)\n", .{});
        std.process.exit(1);
    }
}

/// The full GUI-faithful drive: dial the agent, stand up a real `Termio` with a
/// `.remote` backend on a real IO thread, send the echo command, and scrape the
/// terminal grid for the marker. Returns true iff the GRID rendered it.
fn runProof(alloc: Allocator, port: u16) !bool {
    // --- 1. Dial the real agent over TCP (the caller-owned Connection). --------
    diag("[remote-backend-e2e] dialing 127.0.0.1:{d}\n", .{port});
    var dialed = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
    defer dialed.deinit();
    diag("[remote-backend-e2e] handshake ok: proto_version={d} encoding={s}\n", .{
        dialed.negotiated.proto_version,
        @tagName(dialed.negotiated.transfer_encoding),
    });

    // --- 2. A minimal-but-real config. The INITIAL surface size is 0x0 — exactly
    //        the GUI: `ghostty_surface_new` runs before the Cocoa SurfaceView has
    //        laid out, so `rt_surface.getSize()` is 0x0 and the surface (and its
    //        OPEN) start at 0 rows/cols. The real window size only arrives later
    //        as a `resize` (step 6b below). A correct `.remote` backend must
    //        forward that resize to the agent so the remote PTY is sized and the
    //        shell paints its prompt; the bug is that it does not. ---------------
    var config = try configpkg.Config.default(alloc);
    defer config.deinit();

    const cell: renderer.CellSize = .{ .width = 10, .height = 20 };
    const size: renderer.Size = .{
        .screen = .{ .width = 0, .height = 0 }, // GUI: pre-layout, 0x0
        .cell = cell,
        .padding = .{ .top = 0, .bottom = 0, .left = 0, .right = 0 },
    };
    // The size the window settles at once Cocoa lays the SurfaceView out.
    const real_size: renderer.Size = .{
        .screen = .{ .width = 80 * 10, .height = 24 * 20 },
        .cell = cell,
        .padding = .{ .top = 0, .bottom = 0, .left = 0, .right = 0 },
    };

    // --- 3. The .remote backend — exactly what Surface builds (Surface.zig). ---
    const io_remote = try termio.Remote.init(alloc, .{
        .conn = dialed.conn,
        .session_id = null, // OPEN-new
        .command = null, // remote default shell
        .working_directory = null,
        .term = config.term,
    });
    var backend: termio.Backend = .{ .remote = io_remote };
    errdefer backend.deinit();

    // --- 4. The render plumbing the Termio needs. We have no real renderer
    //        thread or Cocoa surface, so we supply: a standalone renderer.State
    //        (its own mutex + the Termio's terminal), an xev.Async render wakeup
    //        (notified but never waited), and BlockingQueue mailboxes. The
    //        surface mailbox carries a dummy surface pointer that the output path
    //        never dereferences (it only copies the pointer into a queued msg).
    var render_mutex: std.Thread.Mutex = .{};
    var renderer_state: renderer.State = .{
        .mutex = &render_mutex,
        .terminal = undefined, // set to &io.terminal after Termio.init
    };

    var renderer_wakeup = try xev.Async.init();
    defer renderer_wakeup.deinit();

    const renderer_mailbox = try renderer.Thread.Mailbox.create(alloc);
    defer alloc.destroy(renderer_mailbox);

    const app_queue = try App.Mailbox.Queue.create(alloc);
    defer alloc.destroy(app_queue);

    // The apprt.App and core Surface are only referenced as opaque pointers copied
    // into queued surface messages; the harness's output/render path never
    // dereferences them (no app loop, no Cocoa surface), so dummy pointers suffice.
    const dummy_rt_app: *apprt.App = @ptrFromInt(@alignOf(apprt.App));
    const dummy_surface: *Surface = @ptrFromInt(@alignOf(Surface));
    const surface_mailbox: apprt.surface.Mailbox = .{
        .surface = dummy_surface,
        .app = .{ .rt_app = dummy_rt_app, .mailbox = app_queue },
    };

    var io_mailbox = try termio.Mailbox.initSPSC(alloc);
    errdefer io_mailbox.deinit(alloc);

    // --- 5. Build the real Termio (this creates io.terminal). ------------------
    var io: termio.Termio = undefined;
    try termio.Termio.init(&io, alloc, .{
        .size = size,
        .full_config = &config,
        .config = try termio.Termio.DerivedConfig.init(alloc, &config),
        .backend = backend,
        .mailbox = io_mailbox,
        .renderer_state = &renderer_state,
        .renderer_wakeup = &renderer_wakeup,
        .renderer_mailbox = renderer_mailbox,
        .surface_mailbox = surface_mailbox,
    });
    defer io.deinit();
    // Point the render state's terminal at the Termio's terminal (Surface does
    // this via its own field; here the Termio owns it).
    renderer_state.terminal = &io.terminal;

    // --- 6. Start the real IO thread (real xev loop) — the GUI's path. ---------
    var io_thread = try termio.Thread.init(alloc);
    defer io_thread.deinit();

    const thr = try std.Thread.spawn(.{}, termio.Thread.threadMain, .{ &io_thread, &io });

    // Ensure we always stop + join the IO thread before tearing down.
    defer {
        io_thread.stop.notify() catch {};
        thr.join();
    }

    // --- 6b. The resize the GUI delivers once the SurfaceView lays out: 0x0 →
    //         80x24. We send it the SAME way the apprt does — a `.resize` mailbox
    //         message processed on the IO thread (→ Termio.resize → backend
    //         resize). A correct remote backend forwards this to the agent so the
    //         remote PTY is sized and the shell paints. This is the load-bearing
    //         step the GUI performs and the bug drops on the floor. -------------
    io.queueMessage(.{ .resize = real_size }, .unlocked);
    diag("[remote-backend-e2e] delivered 0x0 -> 80x24 resize (the GUI's post-layout resize)\n", .{});

    // --- 7. PHASE A — the EXACT GUI no-keystroke scenario. Send NO input and
    //        wait for the remote shell's own startup output (its prompt) to land
    //        on the grid. This is what a freshly-opened remote window must show.
    //        If THIS stays blank, we've reproduced the GUI's "blank window" with
    //        zero keystrokes. -------------------------------------------------
    diag("[remote-backend-e2e] PHASE A: no input sent; waiting for the remote shell prompt to render...\n", .{});
    const prompted = waitForNonEmptyGrid(alloc, &io, &render_mutex, dialed.conn, 8000);
    if (!prompted) {
        diag("[remote-backend-e2e] PHASE A FAIL: grid stayed BLANK with no keystrokes (reproduces the GUI bug)\n", .{});
        dumpGrid(alloc, &io, &render_mutex);
        return false;
    }
    diag("[remote-backend-e2e] PHASE A ok: shell prompt rendered without any input\n", .{});

    // --- 8. PHASE B — drive input the same way a keystroke would: via the IO
    //        mailbox (write_stable) → IO thread → backend queueWrite →
    //        Connection.writeInput — and assert the echoed marker renders. ----
    const cmd = "echo " ++ marker ++ "\r";
    io.queueMessage(.{ .write_stable = cmd }, .unlocked);
    diag("[remote-backend-e2e] PHASE B: sent '{s}' via mailbox; scraping the GRID for the marker...\n", .{"echo " ++ marker ++ "\\r"});

    // Poll the terminal GRID (NOT the ring). This is the render assertion the GUI
    // lacks: if the backend drain never feeds processOutput, the grid never shows
    // the marker and this trips.
    const deadline = std.time.milliTimestamp() + 8000;
    while (std.time.milliTimestamp() < deadline) {
        if (gridContains(alloc, &io, &render_mutex)) {
            diag("[remote-backend-e2e] PHASE B ok: marker FOUND on the terminal grid — render path works\n", .{});
            return true;
        }
        if (dialed.conn.isEvicted()) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    diag("[remote-backend-e2e] PHASE B FAIL: marker never rendered\n", .{});
    dumpGrid(alloc, &io, &render_mutex);
    return false;
}

/// Wait until the terminal grid has ANY non-whitespace content (the remote
/// shell's own startup output / prompt), with NO input sent — the no-keystroke
/// GUI scenario. Returns false if it stays blank until the deadline.
fn waitForNonEmptyGrid(
    alloc: Allocator,
    io: *termio.Termio,
    mutex: *std.Thread.Mutex,
    conn: *connection.Connection,
    timeout_ms: i64,
) bool {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        if (gridNonEmpty(alloc, io, mutex)) return true;
        if (conn.isEvicted()) return false;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return false;
}

/// True if the active screen has any non-whitespace glyph.
fn gridNonEmpty(alloc: Allocator, io: *termio.Termio, mutex: *std.Thread.Mutex) bool {
    mutex.lock();
    defer mutex.unlock();
    const text = io.terminal.plainString(alloc) catch return false;
    defer alloc.free(text);
    for (text) |c| {
        if (!std.ascii.isWhitespace(c)) return true;
    }
    return false;
}

/// Scrape the active terminal screen (the rendered grid) and report whether the
/// marker text is present. Takes the render mutex like the renderer would.
fn gridContains(alloc: Allocator, io: *termio.Termio, mutex: *std.Thread.Mutex) bool {
    mutex.lock();
    defer mutex.unlock();
    const text = io.terminal.plainString(alloc) catch return false;
    defer alloc.free(text);
    return std.mem.indexOf(u8, text, marker) != null;
}

fn dumpGrid(alloc: Allocator, io: *termio.Termio, mutex: *std.Thread.Mutex) void {
    mutex.lock();
    defer mutex.unlock();
    const text = io.terminal.plainString(alloc) catch return;
    defer alloc.free(text);
    diag("[remote-backend-e2e] final grid ({d} bytes):\n----8<----\n{s}\n---->8----\n", .{ text.len, text });
}

// -----------------------------------------------------------------------------
// Process / port helpers (mirrors wp4_e2e.zig)
// -----------------------------------------------------------------------------

fn resolveAgentPath(alloc: Allocator) ![]u8 {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len >= 2) return alloc.dupe(u8, args[1]);
    return alloc.dupe(u8, "zig-out/bin/ghoztty-agent");
}

fn freePort() !u16 {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    return listener.listen_address.getPort();
}

fn waitForListening(alloc: Allocator, child: *std.process.Child) !void {
    const out = child.stdout orelse return error.NoAgentStdout;
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    var buf: [1024]u8 = undefined;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        const n = out.read(&buf) catch 0;
        if (n == 0) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }
        try acc.appendSlice(alloc, buf[0..n]);
        if (std.mem.indexOf(u8, acc.items, "listening") != null) {
            diag("[remote-backend-e2e] agent ready: {s}\n", .{std.mem.trimRight(u8, acc.items, "\n")});
            return;
        }
    }
    return error.AgentNeverListened;
}

fn cloneEnv(alloc: Allocator, env: *std.process.EnvMap) !void {
    var src = try std.process.getEnvMap(alloc);
    defer src.deinit();
    var it = src.iterator();
    while (it.next()) |entry| {
        try env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn diag(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
