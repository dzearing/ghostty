//! Wiring for the `install-unlock` host tool (T192) — the guard that lets
//! `zig build` install over an artifact a RUNNING process is holding open.
//!
//! On Windows an executable's image file stays open for the life of the
//! process, and `ghoztty-agent.exe` outliving the app is deliberate (session
//! persistence). So a plain dev-loop `zig build` on a box where an earlier
//! test run left a repo-lineage agent alive failed with AccessDenied — after
//! `ghoztty.exe` had already installed, which is the part that misleads: exit
//! 1 over a binary that really did change.
//!
//! One tool run is inserted ahead of the install steps it guards. It moves a
//! locked destination aside (`<name>.old-<n>`) so the install's atomic rename
//! lands on an empty path; see `install_unlock_main.zig` for why renaming
//! rather than killing. It never fails the build.

const InstallUnlock = @This();

const std = @import("std");

/// The single run of the tool. Every guarded (source, destination) pair is
/// appended to its argv, and every guarded install step depends on it.
run: *std.Build.Step.Run,

pub fn create(b: *std.Build) *InstallUnlock {
    const self = b.allocator.create(InstallUnlock) catch @panic("OOM");

    const tool = b.addExecutable(.{
        .name = "install-unlock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/install_unlock_main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run = b.addRunArtifact(tool);
    // Its entire job is a side effect on the install prefix, which is not an
    // input the run cache can see. Caching it would skip exactly the run that
    // matters — the second build against a still-running process.
    run.has_side_effects = true;

    self.* = .{ .run = run };
    return self;
}

/// Guard one destination path, and make `step` wait for the sweep.
pub fn guardFile(
    self: *InstallUnlock,
    src: std.Build.LazyPath,
    dest: []const u8,
    step: *std.Build.Step,
) void {
    self.run.addFileArg(src);
    self.run.addArg(dest);
    step.dependOn(&self.run.step);
}

/// Guard an install-artifact's main output (the exe or dll itself). The
/// side outputs (pdb, implib) are left alone: a running process holds its
/// image file open, not its debug info.
pub fn guardArtifact(
    self: *InstallUnlock,
    install: *std.Build.Step.InstallArtifact,
) void {
    const b = self.run.step.owner;
    const dir = install.dest_dir orelse return;
    const bin = install.emitted_bin orelse return;
    self.guardFile(
        bin,
        b.getInstallPath(dir, install.dest_sub_path),
        &install.step,
    );
}

/// Guard a plain installed file (e.g. the `ghoztty.com` twin).
pub fn guardInstallFile(
    self: *InstallUnlock,
    install: *std.Build.Step.InstallFile,
) void {
    const b = self.run.step.owner;
    self.guardFile(
        install.source,
        b.getInstallPath(install.dir, install.dest_rel_path),
        &install.step,
    );
}
