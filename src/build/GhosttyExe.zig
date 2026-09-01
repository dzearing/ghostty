const Ghostty = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const setMsvcGuiEntry = @import("win32_entry.zig").setMsvcGuiEntry;

/// The primary Ghostty executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

/// Windows targets only (null otherwise): ghoztty.com, the console-subsystem
/// TWIN of ghoztty.exe (T245). PowerShell keys its wait-and-redirect decision
/// on the PE subsystem field, so `ghoztty +verb > file` against the
/// GUI-subsystem exe writes 0 bytes silently; PATHEXT resolves `.COM` before
/// `.EXE`, so a bare `ghoztty` from PowerShell or cmd finds the twin, which
/// PowerShell waits for like any console program (the devenv.com pattern).
/// It is the SAME binary with one WORD flipped (optional header Subsystem,
/// GUI→console) — a tiny relay shim was Defender-quarantined on sight, see
/// src/cli/com_shim.zig for the whole story. Ships as a required sibling of
/// ghoztty.exe, like ghoztty-agent.exe.
com_install_step: ?*std.Build.Step.InstallFile,

/// Windows win32 targets only (null otherwise): the vendored fallback OpenGL
/// implementation, installed as `bin/gl/opengl32.dll` plus its licence (T1252).
///
/// A SUBDIRECTORY, never beside ghoztty.exe. `opengl32.dll` is not a KnownDLL,
/// so a copy adjacent to the exe would be loaded by the operating system for
/// every launch and would silently move every user with a working GPU onto it.
/// `src/renderer/gl_loader.zig` opens this one by full path, and only after the
/// display driver's own OpenGL has measured below the renderer's floor.
gl_install_steps: []const *std.Build.Step.InstallFile,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Ghostty {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "ghoztty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.strip,
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.1
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    // Set PIE if requested
    if (cfg.pie) exe.pie = true;

    // Add the shared dependencies. When building only lib-vt we skip
    // heavy deps so cross-compilation doesn't pull in GTK, etc.
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);

    // Check for possible issues
    try checkNixShell(exe, cfg);

    // Patch our rpath if that option is specified.
    if (cfg.patch_rpath) |rpath| {
        if (rpath.len > 0) {
            const run = std.Build.Step.Run.create(b, "patchelf rpath");
            run.addArgs(&.{ "patchelf", "--set-rpath", rpath });
            run.addArtifactArg(exe);
            install_step.step.dependOn(&run.step);
        }
    }

    // OS-specific
    var com_install_step: ?*std.Build.Step.InstallFile = null;
    var gl_install_steps: std.ArrayList(*std.Build.Step.InstallFile) = .empty;
    switch (cfg.target.result.os.tag) {
        .windows => {
            // Subsystem selection:
            // - Debug builds always use Console (visible stderr).
            // - Release builds default to Windows (no console window) but
            //   can opt into Console via -Dwindows-console=true to debug
            //   crashes from end-user reports.
            exe.subsystem = if (cfg.optimize == .Debug or cfg.windows_console)
                .Console
            else
                .Windows;
            if (exe.subsystem == .Windows) setMsvcGuiEntry(exe);
            // Release/MSI builds stamp a real per-build FILEVERSION so MSI
            // major upgrades replace the exe (file-versioning rules, T23);
            // dev builds keep the rc's 0.1.0.0 baseline.
            const file_ver = cfg.windows_file_version;
            exe.addWin32ResourceFile(.{
                .file = b.path("dist/windows/ghostty.rc"),
                .flags = &.{
                    "/d", b.fmt("GHOZTTY_FILE_VER={d},{d},{d},{d}", .{
                        file_ver[0], file_ver[1], file_ver[2], file_ver[3],
                    }),
                    "/d", b.fmt("GHOZTTY_FILE_VER_STR=\"{d}.{d}.{d}.{d}\"", .{
                        file_ver[0], file_ver[1], file_ver[2], file_ver[3],
                    }),
                },
            });

            // ghoztty.com (see the field doc above): the exe with its
            // Subsystem WORD flipped to console, produced by a tiny host
            // tool rather than a second multi-minute link of the app.
            const patch_tool = b.addExecutable(.{
                .name = "patch-subsystem",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/build/patch_subsystem_main.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                }),
            });
            const patch_run = b.addRunArtifact(patch_tool);
            patch_run.addArtifactArg(exe);
            patch_run.addArg("console");
            const com_file = patch_run.addOutputFileArg("ghoztty.com");
            com_install_step = b.addInstallBinFile(com_file, "ghoztty.com");

            // The fallback OpenGL implementation (T1252), for the frontend
            // that can actually use it. The `none` runtime builds no renderer
            // at all — the `lib` lane cross-builds the shared core for Windows
            // and would otherwise copy 17 MB it will never open — and only the
            // x86_64 build is vendored, so an arm64 Windows target ships
            // nothing rather than an image that cannot load.
            if (cfg.app_runtime == .win32 and
                cfg.target.result.cpu.arch == .x86_64)
            {
                try gl_install_steps.append(b.allocator, b.addInstallBinFile(
                    b.path("vendor/mesa-gl/x64/opengl32.dll"),
                    "gl/opengl32.dll",
                ));
                // The licence travels with the binary, in the same directory,
                // because that is the condition on redistributing it at all.
                try gl_install_steps.append(b.allocator, b.addInstallBinFile(
                    b.path("vendor/mesa-gl/LICENSE"),
                    "gl/LICENSE-Mesa.txt",
                ));
            }
        },

        else => {},
    }

    return .{
        .exe = exe,
        .install_step = install_step,
        .com_install_step = com_install_step,
        .gl_install_steps = try gl_install_steps.toOwnedSlice(b.allocator),
    };
}

/// Add the ghostty exe to the install target.
pub fn install(self: *const Ghostty) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
    if (self.com_install_step) |com| b.getInstallStep().dependOn(&com.step);
    for (self.gl_install_steps) |gl| b.getInstallStep().dependOn(&gl.step);
}

/// If we're in NixOS but not in the shell environment then we issue
/// a warning because the rpath may not be setup properly. This doesn't modify
/// our build in any way but addresses a common build-from-source issue
/// for a subset of users.
fn checkNixShell(exe: *std.Build.Step.Compile, cfg: *const Config) !void {
    // Non-Linux doesn't have rpath issues.
    if (cfg.target.result.os.tag != .linux) return;

    // When cross-compiling, we don't need to worry about matching our
    // Nix shell rpath since the resulting binary will be run on a
    // separate system.
    if (!cfg.target.query.isNativeCpu()) return;
    if (!cfg.target.query.isNativeOs()) return;

    // Verify we're in NixOS
    std.fs.accessAbsolute("/etc/NIXOS", .{}) catch return;

    // If we're in a nix shell, not a problem
    if (cfg.env.get("IN_NIX_SHELL") != null) return;

    try exe.step.addError(
        "\x1b[" ++ color_map.get("yellow").? ++
            "\x1b[" ++ color_map.get("d").? ++
            \\Detected building on and for NixOS outside of the Nix shell environment.
            \\
            \\The resulting ghostty binary will likely fail on launch because it is
            \\unable to dynamically load the windowing libs (X11, Wayland, etc.).
            \\We highly recommend running only within the Nix build environment
            \\and the resulting binary will be portable across your system.
            \\
            \\To run in the Nix build environment, use the following command.
            \\Append any additional options like (`-Doptimize` flags). The resulting
            \\binary will be in zig-out as usual.
            \\
            \\  nix develop -c zig build
            \\
        ++
            "\x1b[0m",
        .{},
    );
}

/// ANSI escape codes for colored log output
const color_map = std.StaticStringMap([]const u8).initComptime(.{
    &.{ "black", "30m" },
    &.{ "blue", "34m" },
    &.{ "b", "1m" },
    &.{ "d", "2m" },
    &.{ "cyan", "36m" },
    &.{ "green", "32m" },
    &.{ "magenta", "35m" },
    &.{ "red", "31m" },
    &.{ "white", "37m" },
    &.{ "yellow", "33m" },
});
