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
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const Action = @import("ghostty.zig").Action;
const Config = @import("../config.zig").Config;

pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// `--version` is itself how this action gets invoked, so the flag has
    /// to parse as valid rather than be reported as unknown.
    version: bool = false,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `version` command is used to display information about Ghostty. Recognized as
/// either `+version` or `--version`.
pub fn run(alloc: Allocator) !u8 {
    // `+version --bogus-flag` used to print the version with the flag
    // silently dropped (T489). Config keys stay tolerated so the
    // documented "--version wins no matter what other args exist"
    // behavior keeps holding for `ghoztty --font-size=12 --version`.
    {
        var opts: Options = .{};
        defer opts.deinit();
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
        if (args.reportCliDiagnosticsStderr(Options, &opts, "+version", Config)) return 1;
    }

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
    if (comptime build_config.app_runtime == .win32) {
        // Whether THIS exe checks the win-v update channel (T24): on for
        // MSI release-pipeline builds, off for dev/portable builds.
        try stdout.print("  - update check: {s}\n", .{
            if (build_config.windows_update_check) "on (win-v channel)" else "off (dev build)",
        });
    }

    try stdout.print("Build Config\n", .{});
    try stdout.print("  - Zig version   : {s}\n", .{builtin.zig_version_string});
    try stdout.print("  - build mode    : {}\n", .{builtin.mode});
    try stdout.print("  - app runtime   : {}\n", .{build_config.app_runtime});
    try stdout.print("  - font engine   : {}\n", .{build_config.font_backend});
    try stdout.print("  - renderer      : {}\n", .{renderer.Renderer});
    try stdout.print("  - libxev        : {t}\n", .{xev.backend});

    // Whether THESE BYTES can start a relay sign-in at all (T795). A build
    // carrying no Google OAuth client id can only ever answer
    // `relay_signin.Error.NoClientId`, which is why both frontends' machine
    // choosers say sign-in is unavailable rather than offering a dead button
    // (T747) — but until this line existed that state was observable only by
    // opening the chooser, so a DELIVERED build's sign-in capability could not
    // be verified by the delivery that shipped it. Every published Windows
    // artifact was in fact shipping without one, because the release pipeline
    // passed no `-Dgoogle-client-id` while the macOS one did.
    //
    // The id itself is printed because it is public — it appears in the browser
    // authorize URL, and the macOS app ships it readable in its Info.plist —
    // so printing it makes "did the right id land?" answerable of a binary,
    // not just of the tree it was built from. The confidential client secret
    // lives only on the relay and never anywhere near this.
    //
    // The BAKE is what is reported, deliberately, not what
    // `relay_signin.resolveClientId` would resolve: `GHOSTTY_GOOGLE_CLIENT_ID`
    // can furnish an id at runtime, and a line under `Build Config` that
    // changed with the environment would answer a different question than the
    // one a delivery asks.
    if (comptime build_config.google_client_id.len > 0) {
        try stdout.print("  - relay sign-in : configured ({s})\n", .{
            build_config.google_client_id,
        });
    } else {
        try stdout.print("  - relay sign-in : not configured (no google client id baked in)\n", .{});
    }

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
    const resp = ipc_client.exchange(alloc, conn, req, .{
        .action = "+version",
    }, &stderr_writer.interface) catch |err| switch (err) {
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
                update_check: ?bool = null,
                exe: []const u8 = "",
                exe_modified: []const u8 = "",
                started: []const u8 = "",
                newer_build_installed: bool = false,
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
    if (data.update_check) |uc| {
        try stdout.print("  - update check: {s}\n", .{if (uc) "on (win-v channel)" else "off (dev build)"});
    }
    try stdout.print("  - exe     : {s}\n", .{data.exe});
    // T1205: `exe modified` is a fact about the FILE. Labelled as such, and
    // followed by when the process itself started, so the two can never be
    // read as one date describing one build. When they disagree the section
    // says so outright — that sentence is the answer to "did my update take?"
    if (data.started.len > 0) {
        try stdout.print("  - started : {s}\n", .{data.started});
    }
    try stdout.print("  - exe on disk modified: {s}\n", .{data.exe_modified});
    try stdout.print("  - pid     : {d}\n", .{data.pid});
    if (data.newer_build_installed) {
        try stdout.print(
            "  - NOTE    : a newer build is installed on disk; this instance is still running the older one. Restart Ghoztty to use it.\n",
            .{},
        );
    }
}
