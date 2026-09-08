//! The `whats-new` IPC action (T624): open the What's New window, drive its
//! tabs, and read back the model it is showing — the seam
//! `test/win32/whats-new.ps1` is built on.
//!
//! ## Same gate, same reasons as `capture-pane` and `agent-integration`
//!
//! There is no `ghoztty +whats-new` CLI verb and there is not going to be
//! one: `src/cli/ghostty.zig`'s action enum is a cross-platform CLI surface
//! (the T141 rule), and this is instrumentation with one consumer. It exists
//! only over the IPC endpoint and only where `build_config.is_debug` holds.
//!
//! ## Why the harness needs it
//!
//! What the window is FOR is a decision — which bundled versions count as
//! new — and that decision is invisible in pixels: a screenshot of a notes
//! list cannot tell you whether the release above the running build was
//! correctly dropped, or whether the anchor was the version the user was
//! running before this launch rather than the one they are running now. The
//! `model` op answers exactly that, from the same `release_notes.Store` the
//! window paints, so the harness asserts the semantics; `open`/`select`
//! prove the window and its tabs exist and respond.
//!
//! ## The wire shape
//!
//! ```
//! {"action":"whats-new","arguments":["--op=model"]}
//!   -> {"success":true,"data":{"current":"1.36.0","previous_seen":"1.34.0",
//!        "tabs":{"client":{"new":["1.36.0"],"installed":["1.34.0",…]},
//!                "agent":{…}}}}
//! {"action":"whats-new","arguments":["--op=open"]}
//!   -> {"success":true,"data":{"open":true,"selected":"client"}}
//! {"action":"whats-new","arguments":["--op=select","--tab=agent"]}
//! {"action":"whats-new","arguments":["--op=state"]}
//!   -> {"success":true,"data":{"open":true,"selected":"agent",
//!        "content_height":2140,"new_count":3,"installed_count":9}}
//! {"action":"whats-new","arguments":["--op=close"]}
//! ```
const std = @import("std");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const App = @import("App.zig");
const bundle = @import("release_notes_bundle.zig");
const ipc_capture = @import("ipc_capture.zig");
const layout = @import("whats_new_layout.zig");
const release_notes = @import("release_notes.zig");
const WhatsNewWindow = @import("WhatsNewWindow.zig");

const log = std.log.scoped(.win32_ipc);

const errorResponse = ipc_capture.errorResponse;

/// True when this build exposes the action at all (see module doc).
pub const enabled = build_config.is_debug;

pub const Op = enum { open, close, select, state, model };

pub const Request = struct {
    op: Op,
    /// Required for `select`; optional elsewhere.
    tab: ?layout.Tab,
};

pub const ParseError = error{ MissingOp, BadOp, MissingTab, BadTab };

/// Parse the argument vector. Pure, so the wire grammar is unit-tested in
/// the win32 lane without an app or a pipe.
pub fn parse(arguments: ?[]const []const u8) ParseError!Request {
    var op: ?Op = null;
    var tab: ?layout.Tab = null;

    if (arguments) |args| for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) {
            op = std.meta.stringToEnum(Op, arg["--op=".len..]) orelse return error.BadOp;
        } else if (std.mem.startsWith(u8, arg, "--tab=")) {
            tab = std.meta.stringToEnum(layout.Tab, arg["--tab=".len..]) orelse return error.BadTab;
        }
    };

    const the_op = op orelse return error.MissingOp;
    if (the_op == .select and tab == null) return error.MissingTab;
    return .{ .op = the_op, .tab = tab };
}

/// Handle one `whats-new` request. Runs on the GUI thread (IpcServer has
/// already marshaled it there), so touching the window is safe.
pub fn handle(
    app: *App,
    alloc: Allocator,
    arguments: ?[]const []const u8,
) Allocator.Error![]u8 {
    const req = parse(arguments) catch |err| return switch (err) {
        error.MissingOp => errorResponse(alloc, "--op=open|close|select|state|model is required", .{}),
        error.BadOp => errorResponse(alloc, "--op must be open, close, select, state or model", .{}),
        error.MissingTab => errorResponse(alloc, "--tab=client|agent is required for --op=select", .{}),
        error.BadTab => errorResponse(alloc, "--tab must be client or agent", .{}),
    };

    switch (req.op) {
        .model => return try modelResponse(alloc),
        .open => {
            // Centre on a terminal window when there is one, exactly as the
            // menu entry does; a headless app opens it at the default spot.
            const owner: ?*@import("Window.zig") = if (app.windows.items.len > 0)
                app.windows.items[0]
            else
                null;
            if (owner) |win| {
                WhatsNewWindow.openFor(app, win.hwnd, win.scale);
            } else {
                WhatsNewWindow.openFor(app, null, 1.0);
            }
            if (req.tab) |t| {
                if (WhatsNewWindow.current()) |w| w.selectTab(t);
            }
        },
        .close => WhatsNewWindow.closeAll(),
        .select => {
            const w = WhatsNewWindow.current() orelse
                return errorResponse(alloc, "the What's New window is not open", .{});
            w.selectTab(req.tab.?);
        },
        .state => {},
    }

    return try stateResponse(alloc);
}

fn stateResponse(alloc: Allocator) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        if (WhatsNewWindow.current()) |w| {
            const split = w.splitFor(w.selectedTab());
            jws.objectField("open") catch break :write;
            jws.write(true) catch break :write;
            jws.objectField("selected") catch break :write;
            jws.write(@tagName(w.selectedTab())) catch break :write;
            jws.objectField("new_count") catch break :write;
            jws.write(split.fresh.len) catch break :write;
            jws.objectField("installed_count") catch break :write;
            jws.write(split.installed.len) catch break :write;
        } else {
            jws.objectField("open") catch break :write;
            jws.write(false) catch break :write;
        }
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

/// The split both tabs would show, computed from the SAME store and anchor
/// the window paints — so an assertion here is an assertion about the window.
fn modelResponse(alloc: Allocator) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("current") catch break :write;
        jws.write(WhatsNewWindow.currentVersion()) catch break :write;
        jws.objectField("previous_seen") catch break :write;
        if (WhatsNewWindow.previousSeen()) |v| {
            jws.write(v) catch break :write;
        } else {
            jws.write(null) catch break :write;
        }
        jws.objectField("tabs") catch break :write;
        jws.beginObject() catch break :write;
        for ([_]struct { name: []const u8, entries: []const release_notes.Entry }{
            .{ .name = "client", .entries = bundle.client },
            .{ .name = "agent", .entries = bundle.agent },
        }) |scope| {
            jws.objectField(scope.name) catch break :write;
            jws.beginObject() catch break :write;

            var store = release_notes.Store.parse(alloc, scope.entries) catch break :write;
            defer store.deinit();
            var split = store.partition(
                alloc,
                WhatsNewWindow.previousSeen(),
                WhatsNewWindow.currentVersion(),
            ) catch break :write;
            defer split.deinit(alloc);

            jws.objectField("bundled") catch break :write;
            jws.write(store.all.len) catch break :write;
            jws.objectField("new") catch break :write;
            jws.beginArray() catch break :write;
            for (split.fresh) |n| jws.write(n.version) catch break :write;
            jws.endArray() catch break :write;
            jws.objectField("installed") catch break :write;
            jws.beginArray() catch break :write;
            for (split.installed) |n| jws.write(n.version) catch break :write;
            jws.endArray() catch break :write;

            jws.endObject() catch break :write;
        }
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "parse: the ops and the tab" {
    try testing.expectEqual(Op.model, (try parse(&.{"--op=model"})).op);
    try testing.expectEqual(Op.open, (try parse(&.{"--op=open"})).op);
    const sel = try parse(&.{ "--op=select", "--tab=agent" });
    try testing.expectEqual(Op.select, sel.op);
    try testing.expectEqual(layout.Tab.agent, sel.tab.?);
}

test "parse: typed refusals, never a silent default" {
    try testing.expectError(error.MissingOp, parse(null));
    try testing.expectError(error.MissingOp, parse(&.{"--tab=client"}));
    try testing.expectError(error.BadOp, parse(&.{"--op=explode"}));
    try testing.expectError(error.BadTab, parse(&.{ "--op=select", "--tab=both" }));
    // A select with no tab is the one op that cannot pick for itself.
    try testing.expectError(error.MissingTab, parse(&.{"--op=select"}));
}
