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

/// Windows targets only (null otherwise): ghoztty-agent-ca.dll, the MSI
/// custom-action DLL (src/remote/agent/msi_ca.zig). Runs in-process inside
/// msiexec so the installer never pops console windows for its kill/cleanup
/// steps; packaged into the MSI by relay/deploy/msi/build-msi.sh.
ca_dll_install_step: ?*std.Build.Step.InstallArtifact,

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
    const stamp = try versionString(b);
    const version_opts = b.addOptions();
    version_opts.addOption([]const u8, "agent_version", stamp);
    const version_module = version_opts.createModule();
    exe.root_module.addImport("agent_build_options", version_module);

    // On Windows the agent shows a system-tray icon in its daemon modes (the
    // MSI/installer autostart it as the always-on `--relay` daemon). Build it as
    // the GUI subsystem so Windows never allocates a console window for it — no
    // stray black box pops up next to the tray. Logging is unaffected: stdout/
    // stderr go to log files via inherited handles regardless of subsystem, so
    // the readiness banner is still captured. This is windows-only;
    // the macOS host + the `test-agent` build are left untouched.
    var ca_dll_install_step: ?*std.Build.Step.InstallArtifact = null;
    if (cfg.target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
        // The MSI custom-action DLL ships alongside the agent exe. Pure Win32,
        // no shared deps — keep it that way so msiexec loads it instantly.
        const ca_dll = b.addLibrary(.{
            .name = "ghoztty-agent-ca",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/remote/agent/msi_ca.zig"),
                .target = cfg.target,
                .optimize = cfg.optimize,
                .strip = cfg.strip,
            }),
            .use_llvm = true,
        });
        ca_dll_install_step = b.addInstallArtifact(ca_dll, .{});
        // The tray pulls in user32/shell32. kernel32 is auto-linked, but these
        // are not, so request them explicitly (windows-target only).
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("shell32");
        // relay.env DACL hardening (enroll.zig) uses the token/security APIs.
        exe.linkSystemLibrary("advapi32");
        // Embed the ghost icon (id 1) so the exe and its tray icon aren't the
        // generic Windows application icon. `tray.zig` loads it by id from this
        // module's own instance handle. The /d defines stamp VERSIONINFO so
        // Explorer's Details tab shows the release semver (matching the DMG
        // tag) and the date-hash self-update stamp; see ghoztty-agent.rc.
        const semver = semverString(b);
        const sv = parseSemver(semver);
        exe.addWin32ResourceFile(.{
            .file = b.path("dist/windows/ghoztty-agent.rc"),
            .flags = &.{
                "/d", b.fmt("AGENT_VER_MAJOR={d}", .{sv.major}),
                "/d", b.fmt("AGENT_VER_MINOR={d}", .{sv.minor}),
                "/d", b.fmt("AGENT_VER_PATCH={d}", .{sv.patch}),
                "/d", b.fmt("AGENT_VERSION_STR=\"{s}\"", .{semver}),
                "/d", b.fmt("AGENT_STAMP_STR=\"{s}\"", .{stamp}),
            },
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
        .ca_dll_install_step = ca_dll_install_step,
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

/// The release semver the agent ships under — the app's git tag, so the
/// Windows artifacts carry the SAME version as the DMG of the same release
/// (e.g. tag v1.11.0 → DMG Ghoztty-1.11.0-arm64.dmg + MSI
/// Ghoztty-Agent-1.11.0-x64.msi). Stamped into the exe's VERSIONINFO; the
/// MSI's ProductVersion is derived from it in relay/deploy/msi/build-msi.sh.
/// Precedence:
///   1. `-Dagent-semver=<X.Y.Z>` (explicit override — publisher builds),
///   2. latest reachable git tag (`git describe --tags --abbrev=0`, `v` strip),
///   3. `"0.0.0"` (git unavailable / no tags).
fn semverString(b: *std.Build) []const u8 {
    if (b.option(
        []const u8,
        "agent-semver",
        "Release semver baked into ghoztty-agent's VERSIONINFO. " ++
            "Defaults to the latest git tag, or \"0.0.0\" without git.",
    )) |v| return v;

    var code: u8 = 0;
    const raw = b.runAllowFail(
        &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "describe", "--tags", "--abbrev=0" },
        &code,
        .Ignore,
    ) catch return "0.0.0";
    const tag = std.mem.trim(u8, raw, "\r\n ");
    if (tag.len == 0) return "0.0.0";
    return if (tag[0] == 'v') tag[1..] else tag;
}

const Semver = struct { major: u32, minor: u32, patch: u32 };

/// Best-effort X.Y.Z split for the numeric FILEVERSION fields; malformed
/// pieces become 0 (VERSIONINFO strings still carry the raw text).
fn parseSemver(s: []const u8) Semver {
    var it = std.mem.splitScalar(u8, s, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    const patch = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// Add the agent exe to the install target.
pub fn install(self: *const Agent) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
