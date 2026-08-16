//! The `agent-integration` IPC action (T872): drive one agent-integration
//! install/uninstall, or read every agent's status, through the REAL app
//! process — the seam the end-to-end acceptance harness
//! (`test/win32/agent-integrations.ps1`) is built on.
//!
//! ## Same gate, same reasons as `capture-pane`
//!
//! There is no `ghoztty +agent-integration` CLI verb and there is not going
//! to be one: `src/cli/ghostty.zig`'s action enum is a cross-platform CLI
//! surface (the T141 rule), and this is instrumentation with one consumer.
//! The action exists only over the IPC endpoint, only in a build where
//! `build_config.is_debug` holds; a shipped ReleaseFast build answers
//! `unknown action`, exactly as for a verb it never heard of.
//!
//! ## Why the harness needs it at all
//!
//! The GUI offers exactly one action per state (Set Up / Update /
//! Uninstall), so half of the T872 scenario floor is unreachable through it:
//! a second install onto a healthy tree (idempotence must REPORT
//! `up_to_date`), an install onto a poisoned tree (typed refusals,
//! rollback), and the two-agent banner-refcount walk. This action invokes
//! the SAME service entry points the dialog's workers call
//! (`agent_integration_service`), with the home and probe resolved through
//! `AgentIntegration.openAgentHome`/`probeFor` — so the `GHOZTTY_AGENT_HOME`
//! sandbox override governs here exactly as it governs every GUI entry
//! point, and a sandboxed harness can walk every outcome deterministically.
//!
//! ## The wire shape
//!
//! ```
//! {"action":"agent-integration","arguments":["--op=install","--agent=claude"]}
//!   -> {"success":true,"data":{"agent":"claude","outcome":"installed"}}
//!      (a failed outcome carries the typed error: "outcome":"failed",
//!       "detail":"NotManaged")
//! {"action":"agent-integration","arguments":["--op=status"]}
//!   -> {"success":true,"data":{"agents":[{"agent":"claude","detected":true,
//!       "state":"installed","plugin_managed":false,"banner_shared":false},…]}}
//! ```
//!
//! Outcomes and states are the union/enum TAG names (`up_to_date`, not the
//! UI's "already up to date"): the consumer is a harness, and UI copy moves
//! for reasons a wire contract must not.
const std = @import("std");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const AgentIntegration = @import("AgentIntegration.zig");
const service = @import("agent_integration_service.zig");
const ipc_capture = @import("ipc_capture.zig");

const log = std.log.scoped(.win32_ipc);

const errorResponse = ipc_capture.errorResponse;

/// True when this build exposes the action at all (see module doc).
pub const enabled = build_config.is_debug;

pub const Op = enum { install, uninstall, status };

pub const Request = struct {
    op: Op,
    /// Required for install/uninstall; ignored for status.
    agent: ?service.RuntimeAgent,
};

pub const ParseError = error{
    MissingOp,
    BadOp,
    MissingAgent,
    BadAgent,
};

/// Parse the argument vector. Pure, so the wire grammar is unit-tested in
/// the win32 lane without an app or a pipe.
pub fn parse(arguments: ?[]const []const u8) ParseError!Request {
    var op: ?Op = null;
    var agent: ?service.RuntimeAgent = null;

    if (arguments) |args| for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) {
            const v = arg["--op=".len..];
            op = std.meta.stringToEnum(Op, v) orelse return error.BadOp;
        } else if (std.mem.startsWith(u8, arg, "--agent=")) {
            const v = arg["--agent=".len..];
            agent = std.meta.stringToEnum(service.RuntimeAgent, v) orelse
                return error.BadAgent;
        }
    };

    const the_op = op orelse return error.MissingOp;
    if (the_op != .status and agent == null) return error.MissingAgent;
    return .{ .op = the_op, .agent = agent };
}

/// Handle one `agent-integration` request. Returns the response JSON
/// (allocated from `alloc`; the listener frees it). The service walk is
/// plain filesystem work against the (sandboxed) home — no child process is
/// ever spawned here, so it is safe on the handling thread.
pub fn handle(
    alloc: Allocator,
    arguments: ?[]const []const u8,
) Allocator.Error![]u8 {
    const req = parse(arguments) catch |err| return switch (err) {
        error.MissingOp => errorResponse(alloc, "--op=install|uninstall|status is required", .{}),
        error.BadOp => errorResponse(alloc, "--op must be install, uninstall or status", .{}),
        error.MissingAgent => errorResponse(alloc, "--agent=claude|copilot is required for this op", .{}),
        error.BadAgent => errorResponse(alloc, "--agent must be claude or copilot", .{}),
    };

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The same resolution every GUI entry point makes, so the sandbox
    // override governs here too (see module doc).
    const home = AgentIntegration.openAgentHome(arena) orelse
        return errorResponse(alloc, "the agent home directory could not be opened", .{});
    var home_dir = home.dir;
    defer home_dir.close();
    const probe = AgentIntegration.probeFor(arena);

    switch (req.op) {
        .status => {
            const statuses = service.allAgentStatuses(arena, home_dir, home.path, probe) catch
                return error.OutOfMemory;

            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            var jws: std.json.Stringify = .{ .writer = &out.writer };
            write: {
                jws.beginObject() catch break :write;
                jws.objectField("success") catch break :write;
                jws.write(true) catch break :write;
                jws.objectField("data") catch break :write;
                jws.beginObject() catch break :write;
                jws.objectField("agents") catch break :write;
                jws.beginArray() catch break :write;
                for (statuses) |s| {
                    jws.beginObject() catch break :write;
                    jws.objectField("agent") catch break :write;
                    jws.write(@tagName(s.agent)) catch break :write;
                    jws.objectField("detected") catch break :write;
                    jws.write(s.detected) catch break :write;
                    jws.objectField("state") catch break :write;
                    jws.write(@tagName(s.state)) catch break :write;
                    jws.objectField("plugin_managed") catch break :write;
                    jws.write(s.plugin_managed) catch break :write;
                    jws.objectField("banner_shared") catch break :write;
                    jws.write(s.banner_shared_with_other) catch break :write;
                    jws.endObject() catch break :write;
                }
                jws.endArray() catch break :write;
                jws.endObject() catch break :write;
                jws.endObject() catch break :write;
                return try out.toOwnedSlice();
            }
            return error.OutOfMemory;
        },
        .install, .uninstall => {
            const agent = req.agent.?;
            const outcome = switch (req.op) {
                .install => try service.install(arena, agent, home_dir, home.path, probe),
                .uninstall => try service.uninstall(arena, agent, home_dir, home.path, probe),
                .status => unreachable,
            };
            log.info("agent-integration {s} {s}: {s}", .{
                @tagName(req.op), @tagName(agent), outcome.label(),
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
                jws.objectField("agent") catch break :write;
                jws.write(@tagName(agent)) catch break :write;
                jws.objectField("outcome") catch break :write;
                jws.write(@tagName(outcome)) catch break :write;
                if (outcome == .failed) {
                    jws.objectField("detail") catch break :write;
                    jws.write(outcome.failed) catch break :write;
                }
                jws.endObject() catch break :write;
                jws.endObject() catch break :write;
                return try out.toOwnedSlice();
            }
            return error.OutOfMemory;
        },
    }
}

// -----------------------------------------------------------------------------
// Tests — the wire grammar.
// -----------------------------------------------------------------------------

const testing = std.testing;

test "parse: install and uninstall need an agent, status does not" {
    const r = try parse(&.{ "--op=install", "--agent=claude" });
    try testing.expectEqual(Op.install, r.op);
    try testing.expectEqual(service.RuntimeAgent.claude, r.agent.?);

    const u = try parse(&.{ "--op=uninstall", "--agent=copilot" });
    try testing.expectEqual(Op.uninstall, u.op);
    try testing.expectEqual(service.RuntimeAgent.copilot, u.agent.?);

    const s = try parse(&.{"--op=status"});
    try testing.expectEqual(Op.status, s.op);
    try testing.expectEqual(@as(?service.RuntimeAgent, null), s.agent);

    try testing.expectError(error.MissingAgent, parse(&.{"--op=install"}));
    try testing.expectError(error.MissingAgent, parse(&.{"--op=uninstall"}));
}

test "parse: every malformed shape is a TYPED refusal" {
    try testing.expectError(error.MissingOp, parse(null));
    try testing.expectError(error.MissingOp, parse(&.{"--agent=claude"}));
    try testing.expectError(error.BadOp, parse(&.{"--op=explode"}));
    try testing.expectError(error.BadAgent, parse(&.{ "--op=install", "--agent=cortana" }));
}

test "parse: unknown flags are ignored, last value wins" {
    const r = try parse(&.{ "--op=status", "--verbose", "--op=install", "--agent=claude" });
    try testing.expectEqual(Op.install, r.op);
}
