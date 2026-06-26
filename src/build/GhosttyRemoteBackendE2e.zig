//! The `remote-backend-e2e` executable — the WP4 headless RENDER de-risk harness.
//! It stands up a REAL `termio.Termio` with a `.remote` backend on a REAL
//! `termio.Thread` (real xev loop) — the exact GUI lifecycle — dials the real
//! `ghoztty-agent` over TCP, and asserts the `terminal.Terminal` GRID actually
//! renders the remote shell's output. This reproduces the "blank window" bug
//! headlessly and proves the backend drain path once fixed.
//!
//! Unlike `wp4-e2e` (a pure protocol/transport graph), this harness pulls the
//! full app graph (renderer/termio/terminal/apprt/config), so it is rooted at
//! `src/remote_backend_e2e_main.zig` and wired with `SharedDeps` like the agent
//! and the main exe.

const RemoteBackendE2e = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

exe: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !RemoteBackendE2e {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "remote-backend-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/remote_backend_e2e_main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
        }),
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});
    if (cfg.pie) exe.pie = true;

    // Pull the full app graph (renderer/termio/terminal/apprt/config + C libs).
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);

    return .{ .exe = exe, .install_step = install_step };
}
