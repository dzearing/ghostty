const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = b.path("src/uucode_config.zig"),
    });

    const t = b.addTest(.{
        .name = "repro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
        .use_llvm = false,
    });
    t.root_module.addImport("uucode", uucode.module("uucode"));

    const step = b.step("repro", "compile the test binary with the self-hosted backend");
    step.dependOn(&b.addInstallArtifact(t, .{}).step);
    b.default_step.dependOn(step);
}


