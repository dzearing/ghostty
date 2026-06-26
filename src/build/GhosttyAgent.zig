//! The `ghoztty-agent` executable — the remote-host session-server daemon
//! (WP2, §4.1–§4.2/§7.1). It is spawned by the client over
//! `ssh host -- ghoztty-agent`: it reads framed protocol from stdin, spawns real
//! pty-backed children, and streams their output to stdout.
//!
//! It deliberately does NOT pull the apprt/config/global GUI graph — its root
//! module (`src/remote/agent/main.zig`) imports only the pure `protocol` module,
//! the session-server, and `pty.zig`/`CommandCore.zig` (which need the pty-c
//! translate-C + `os/main.zig`, wired by `SharedDeps.add`).

const Agent = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The agent executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Agent {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "ghoztty-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent_main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.strip,
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.x; mirror GhosttyExe.
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    if (cfg.pie) exe.pie = true;

    // The agent module is rooted at `src/` (via `src/agent_main.zig`), so its
    // files import `protocol.zig`, `pty.zig`, and `CommandCore.zig` by relative
    // path — exactly like the rest of the app. No named `protocol` module is
    // wired (that would duplicate `protocol.zig`, which the apprt graph pulled in
    // by `os/main.zig` already reaches relatively → "file in two modules").

    // Wire the shared deps so `pty.zig`/`CommandCore.zig` get pty-c + os C libs.
    // (Skipped when only building lib-vt, matching GhosttyExe.)
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);

    return .{
        .exe = exe,
        .install_step = install_step,
    };
}

/// Add the agent exe to the install target.
pub fn install(self: *const Agent) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
