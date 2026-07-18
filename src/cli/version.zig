const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");

const gtk_version = @import("../apprt/gtk/gtk_version.zig");
const adw_version = @import("../apprt/gtk/adw_version.zig");
const ipc_client = @import("../os/ipc_client.zig");

pub const Options = struct {};

/// The `version` command is used to display information about Ghostty. Recognized as
/// either `+version` or `--version`.
pub fn run(alloc: Allocator) !u8 {
    var buffer: [1024]u8 = undefined;
    const stdout_file: std.fs.File = .stdout();
    var stdout_writer = stdout_file.writer(&buffer);

    const stdout = &stdout_writer.interface;
    const tty = stdout_file.isTty();

    if (tty) if (build_config.version.build) |commit_hash| {
        try stdout.print(
            "\x1b]8;;https://github.com/ghostty-org/ghostty/commit/{s}\x1b\\",
            .{commit_hash},
        );
    };
    try stdout.print("Ghostty {s}\n\n", .{build_config.version_string});
    if (tty) try stdout.print("\x1b]8;;\x1b\\", .{});

    try stdout.print("Version\n", .{});
    try stdout.print("  - version: {s}\n", .{build_config.version_string});
    try stdout.print("  - channel: {t}\n", .{build_config.release_channel});

    try stdout.print("Build Config\n", .{});
    try stdout.print("  - Zig version   : {s}\n", .{builtin.zig_version_string});
    try stdout.print("  - build mode    : {}\n", .{builtin.mode});
    try stdout.print("  - app runtime   : {}\n", .{build_config.app_runtime});
    try stdout.print("  - font engine   : {}\n", .{build_config.font_backend});
    try stdout.print("  - renderer      : {}\n", .{renderer.Renderer});
    try stdout.print("  - libxev        : {t}\n", .{xev.backend});
    if (comptime build_config.app_runtime == .gtk) {
        if (comptime builtin.os.tag == .linux) {
            const kernel_info = internal_os.getKernelInfo(alloc);
            defer if (kernel_info) |k| alloc.free(k);
            try stdout.print("  - kernel version: {s}\n", .{kernel_info orelse "Kernel information unavailable"});
        }
        try stdout.print("  - desktop env   : {t}\n", .{internal_os.desktopEnvironment()});
        try stdout.print("  - GTK version   :\n", .{});
        try stdout.print("    build         : {f}\n", .{gtk_version.comptime_version});
        try stdout.print("    runtime       : {f}\n", .{gtk_version.getRuntimeVersion()});
        try stdout.print("  - libadwaita    : enabled\n", .{});
        try stdout.print("    build         : {f}\n", .{adw_version.comptime_version});
        try stdout.print("    runtime       : {f}\n", .{adw_version.getRuntimeVersion()});
        if (comptime build_options.x11) {
            try stdout.print("  - libX11        : enabled\n", .{});
        } else {
            try stdout.print("  - libX11        : disabled\n", .{});
        }

        // We say `libwayland` since it is possible to build Ghostty without
        // Wayland integration but with Wayland-enabled GTK
        if (comptime build_options.wayland) {
            try stdout.print("  - libwayland    : enabled\n", .{});
        } else {
            try stdout.print("  - libwayland    : disabled\n", .{});
        }
    }

    // Build provenance of the RUNNING instance, not this CLI exe (T52):
    // the two can differ (stale installed exe vs fresh zig-out), which is
    // exactly the confusion this section exists to catch.
    printRunningInstance(alloc, stdout) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };

    // Don't forget to flush!
    try stdout.flush();
    return 0;
}

/// Query the running instance (if any) for its build provenance over IPC
/// and print it as a "Running Instance" section. Absence of an instance —
/// or a server without the `version` verb (e.g. the Mac Swift server
/// today) — prints a one-line note instead of failing `+version`.
fn printRunningInstance(alloc: Allocator, stdout: *std.Io.Writer) !void {
    try stdout.print("Running Instance\n", .{});

    const conn = ipc_client.connect(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try stdout.print("  - none detected\n", .{});
            return;
        },
    };
    defer conn.close();

    const req = try ipc_client.buildRequest(alloc, "version", null);
    defer alloc.free(req);

    var err_buf: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&err_buf);
    const resp = ipc_client.exchange(alloc, conn, req, .{}, &stderr_writer.interface) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try stdout.print("  - query failed\n", .{});
            return;
        },
    };
    defer alloc.free(resp);

    const parsed = std.json.parseFromSlice(
        struct {
            success: bool = false,
            data: ?struct {
                version: []const u8 = "",
                commit: []const u8 = "",
                mode: []const u8 = "",
                runtime: []const u8 = "",
                exe: []const u8 = "",
                exe_modified: []const u8 = "",
                pid: i64 = 0,
            } = null,
        },
        alloc,
        resp,
        .{ .ignore_unknown_fields = true },
    ) catch {
        try stdout.print("  - unrecognized response\n", .{});
        return;
    };
    defer parsed.deinit();

    if (!parsed.value.success or parsed.value.data == null) {
        try stdout.print("  - running, but no version support\n", .{});
        return;
    }
    const data = parsed.value.data.?;

    try stdout.print("  - version : {s}\n", .{data.version});
    try stdout.print("  - commit  : {s}\n", .{data.commit});
    try stdout.print("  - mode    : {s}\n", .{data.mode});
    try stdout.print("  - runtime : {s}\n", .{data.runtime});
    try stdout.print("  - exe     : {s}\n", .{data.exe});
    try stdout.print("  - modified: {s}\n", .{data.exe_modified});
    try stdout.print("  - pid     : {d}\n", .{data.pid});
}
