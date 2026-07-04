//! The `remote-test-client` executable — a headless Mac CLI that drives a
//! TCP-listening `ghoztty-agent` (WP: TCP transport). It dials the agent, OPENs a
//! shell session, and relays bytes both ways (interactive raw-TTY mode or a scripted
//! `--exec` round-trip). This is the tool an orchestrator uses to test a remote
//! (e.g. Windows) agent end-to-end.
//!
//! Unlike `ghoztty-agent`, the client side is a pure protocol/transport graph — it
//! imports only `src/remote/{protocol,connection,inbound_ring,client_mux,
//! socket_stream,tcp_dial}.zig`, none of which pull the apprt/config/pty/GUI graph.
//! So its module is rooted directly at `src/remote/test_client.zig` with NO shared
//! C deps wired (no `SharedDeps.add`), keeping it a fast, dependency-light native
//! build.

const RemoteTestClient = @This();

const std = @import("std");
const Config = @import("Config.zig");

exe: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config) !RemoteTestClient {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "remote-test-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/remote/test_client.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
        }),
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});
    if (cfg.pie) exe.pie = true;
    return .{ .exe = exe, .install_step = install_step };
}
