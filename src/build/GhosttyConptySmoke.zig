//! The `ghoztty-conpty-smoke` executable — a tiny standalone Windows .exe that
//! proves the in-tree ConPTY machinery (`src/pty.zig` `WindowsPty` +
//! `src/CommandCore.zig` `startWindows`) works at runtime on a real Windows box
//! (WP2, §13). It is a cross-compile-only runtime probe; not part of the default
//! install graph.
//!
//! Like the agent (`GhosttyAgent.zig`) it deliberately does NOT pull the
//! apprt/config/global GUI graph — its root module (`src/conpty_smoke_main.zig`)
//! reaches only `pty.zig`/`CommandCore.zig`/`os/main.zig` (wired by
//! `SharedDeps.add`). The output exe name carries the target arch so both
//! aarch64 and x86_64 binaries can coexist in `zig-out/bin`.

const Smoke = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The smoke exe.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Smoke {
    // Name the artifact per-arch so x86_64 + aarch64 builds don't clobber each
    // other in zig-out/bin (e.g. ghoztty-conpty-smoke-x86_64.exe).
    const arch = @tagName(cfg.target.result.cpu.arch);
    const name = try std.fmt.allocPrint(b.allocator, "ghoztty-conpty-smoke-{s}", .{arch});

    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/conpty_smoke_main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.strip,
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.x; mirror GhosttyExe/GhosttyAgent.
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    if (cfg.pie) exe.pie = true;

    // Wire the shared deps so `pty.zig`/`CommandCore.zig` get pty-c + os C libs.
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);

    return .{
        .exe = exe,
        .install_step = install_step,
    };
}

/// Add the smoke exe to the install target.
pub fn install(self: *const Smoke) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
