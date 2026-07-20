//! The `remote-test-client` executable — a headless Mac CLI that drives a
//! TCP-listening `ghoztty-agent` (WP: TCP transport). It dials the agent, OPENs a
//! shell session, and relays bytes both ways (interactive raw-TTY mode or a scripted
//! `--exec` round-trip). This is the tool an orchestrator uses to test a remote
//! (e.g. Windows) agent end-to-end.
//!
//! The client side is a protocol/transport graph — `src/remote/{protocol,
//! connection,inbound_ring,client_mux,socket_stream,pipe_stream,tcp_dial}.zig`.
//! It is rooted at `src/` (via the `src/remote_test_client_main.zig` shim, the
//! same trick `src/agent_main.zig` uses for the agent) rather than
//! `src/remote/test_client.zig`: `socket_stream.zig`/`pipe_stream.zig` import
//! `agent/server.zig`, whose transitive graph reaches `src/terminal/*` via
//! `../../terminal`, which escapes a `src/remote/`-rooted module (the reason the
//! client never built for Windows). Rooting at `src/` keeps it inside, at the
//! cost of wiring the shared C deps (pty-c + os libs) the same way the agent does.

const RemoteTestClient = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

exe: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !RemoteTestClient {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "remote-test-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/remote_test_client_main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
        }),
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});
    if (cfg.pie) exe.pie = true;

    // Rooted at `src/`, the client's transport graph reaches `src/pty.zig` /
    // `src/CommandCore.zig` / `src/terminal/*` (via `agent/server.zig`), so it
    // needs the same shared C deps (pty-c + os libs) as the agent exe. Skipped
    // when only building lib-vt, matching GhosttyExe/GhosttyAgent.
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);

    return .{ .exe = exe, .install_step = install_step };
}
