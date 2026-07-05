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
const GitVersion = @import("GitVersion.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The agent executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

/// The `agent_build_options` module (currently just `agent_version`). Exposed
/// so build.zig can wire the SAME options onto the agent test build (which
/// roots at `src/agent_main.zig` too and therefore reaches `main.zig`'s
/// `@import("agent_build_options")`).
version_module: *std.Build.Module,

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

    // Bake the agent's self-update identity ("YYYYMMDD-<git short hash>", or
    // "dev" when git is unavailable) into the binary via a tiny dedicated
    // options module. Deliberately NOT part of the shared `build_options`
    // (that would rebuild the whole app graph on every commit-hash change).
    const version_opts = b.addOptions();
    version_opts.addOption([]const u8, "agent_version", try versionString(b));
    const version_module = version_opts.createModule();
    exe.root_module.addImport("agent_build_options", version_module);

    // On Windows the agent shows a system-tray icon in listen-daemon mode (the
    // deploy watcher launches it as the always-on daemon). Build it as the GUI
    // subsystem so Windows never allocates a console window for it — no stray
    // black box pops up next to the tray. Logging is unaffected: the watcher
    // redirects stdout/stderr to log files (inherited handles work regardless of
    // subsystem), so the readiness banner is still captured. This is windows-only;
    // the macOS host + the `test-agent` build are left untouched.
    if (cfg.target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
        // The tray pulls in user32/shell32. kernel32 is auto-linked, but these
        // are not, so request them explicitly (windows-target only).
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("shell32");
        // relay.env DACL hardening (enroll.zig) uses the token/security APIs.
        exe.linkSystemLibrary("advapi32");
        // Embed the ghost icon (id 1) so the exe and its tray icon aren't the
        // generic Windows application icon. `tray.zig` loads it by id from this
        // module's own instance handle.
        exe.addWin32ResourceFile(.{
            .file = b.path("dist/windows/ghoztty-agent.rc"),
        });
    }

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
        .version_module = version_module,
    };
}

/// The agent's build-time version string, in the FIXED format the relay's
/// `/dl/version.json` manifest publisher stamps: `YYYYMMDD-<git short hash>`
/// (commit date, so rebuilds of the same commit agree). Precedence:
///   1. `-Dagent-version=<str>` (explicit override — deterministic publisher
///      builds and tests),
///   2. git detection (commit date + short hash),
///   3. `"dev"` (git unavailable / not a repo). Dev builds never self-update.
fn versionString(b: *std.Build) ![]const u8 {
    if (b.option(
        []const u8,
        "agent-version",
        "Version string baked into ghoztty-agent (self-update identity). " ++
            "Defaults to YYYYMMDD-<git short hash>, or \"dev\" without git.",
    )) |v| return v;

    const git = GitVersion.detect(b) catch return "dev";

    // Commit date as YYYY-MM-DD (`%cs`), compacted to YYYYMMDD.
    var code: u8 = 0;
    const date_raw = b.runAllowFail(
        &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "log", "-1", "--pretty=format:%cs" },
        &code,
        .Ignore,
    ) catch return "dev";
    const date = std.mem.trim(u8, date_raw, "\r\n ");
    if (date.len < 10) return "dev";
    return b.fmt("{s}{s}{s}-{s}", .{ date[0..4], date[5..7], date[8..10], git.short_hash });
}

/// Add the agent exe to the install target.
pub fn install(self: *const Agent) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
