//! The `wp4-e2e` executable — the WP4 Phase-1 headless de-risk harness. It spawns
//! the real `ghoztty-agent` on a localhost TCP port and drives the high-level
//! `Connection.openChannel` (the exact call `src/termio/Remote.zig` makes) to prove
//! the client/agent channel rendezvous works end-to-end over TCP.
//!
//! Like `remote-test-client`, this is a pure protocol/transport graph rooted at
//! `src/remote/wp4_e2e.zig` — it imports only `src/remote/{protocol,connection,
//! inbound_ring,client_mux,socket_stream,tcp_dial}.zig`, none of which pull the
//! apprt/config/pty/GUI graph, so no shared C deps are wired.

const Wp4E2e = @This();

const std = @import("std");
const Config = @import("Config.zig");

exe: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config) !Wp4E2e {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "wp4-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/remote/wp4_e2e.zig"),
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
