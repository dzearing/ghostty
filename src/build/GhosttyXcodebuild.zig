const Ghostty = @This();

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const Agent = @import("GhosttyAgent.zig");
const Config = @import("Config.zig");
const Docs = @import("GhosttyDocs.zig");
const I18n = @import("GhosttyI18n.zig");
const Resources = @import("GhosttyResources.zig");
const XCFramework = @import("GhosttyXCFramework.zig");

build: *std.Build.Step.Run,
open: *std.Build.Step.Run,
copy: *std.Build.Step.Run,
sign: *std.Build.Step.Run,
xctest: *std.Build.Step.Run,

pub const Deps = struct {
    xcframework: *const XCFramework,
    docs: *const Docs,
    i18n: ?*const I18n,
    resources: *const Resources,

    /// When set, the ghoztty-agent daemon is embedded into the installed
    /// bundle at Contents/MacOS/ghoztty-agent so the app can spawn its local
    /// session-persistence agent (LocalAgentManager) without a separate
    /// install.
    agent: ?*const Agent = null,
};

pub fn init(
    b: *std.Build,
    config: *const Config,
    deps: Deps,
) !Ghostty {
    const xc_config = switch (config.optimize) {
        .Debug => "Debug",
        .ReleaseSafe,
        .ReleaseSmall,
        .ReleaseFast,
        => "ReleaseLocal",
    };

    const xc_arch: ?[]const u8 = switch (deps.xcframework.target) {
        // Universal is our default target, so we don't have to
        // add anything.
        .universal => null,

        // Native we need to override the architecture in the Xcode
        // project with the -arch flag.
        .native => switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS arch"),
        },
    };

    const env = try std.process.getEnvMap(b.allocator);
    const app_name = if (config.optimize == .Debug) "Ghoztty-Debug" else "Ghoztty";
    const app_path = b.fmt("macos/build/{s}/{s}.app", .{ xc_config, app_name });

    // Our step to build the Ghostty macOS app.
    const build = build: {
        // External environment variables can mess up xcodebuild, so
        // we create a new empty environment.
        const env_map = try b.allocator.create(std.process.EnvMap);
        env_map.* = .init(b.allocator);
        if (env.get("PATH")) |v| try env_map.put("PATH", v);

        const step = RunStep.create(b, "xcodebuild");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.env_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "-target",
            "Ghostty",
            "-configuration",
            xc_config,
        });

        // If we have a specific architecture, we need to pass it
        // to xcodebuild.
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });

        // Pass the version to xcodebuild so it lands in the app's Info.plist.
        var version_buf: [64]u8 = undefined;
        const marketing_version = std.fmt.bufPrint(&version_buf, "{d}.{d}.{d}", .{
            config.version.major,
            config.version.minor,
            config.version.patch,
        }) catch "0.0.0";
        step.addArgs(&.{
            b.fmt("MARKETING_VERSION={s}", .{marketing_version}),
            b.fmt("CURRENT_PROJECT_VERSION={s}", .{marketing_version}),
        });

        // Pass the Google OAuth client id so it lands in the app's Info.plist
        // (GhosttyGoogleClientID). Public value; the confidential secret lives
        // only on the relay. Empty in a build with neither -Dgoogle-client-id
        // nor macos/google-client-id.txt.
        step.addArgs(&.{
            b.fmt("GHOSTTY_GOOGLE_CLIENT_ID={s}", .{config.google_client_id}),
        });

        // We need the xcframework
        deps.xcframework.addStepDependencies(&step.step);

        // We also need all these resources because the xcode project
        // references them via symlinks.
        deps.resources.addStepDependencies(&step.step);
        if (deps.i18n) |v| v.addStepDependencies(&step.step);
        deps.docs.installDummy(&step.step);

        // Expect success
        step.expectExitCode(0);

        break :build step;
    };

    const xctest = xctest: {
        const env_map = try b.allocator.create(std.process.EnvMap);
        env_map.* = .init(b.allocator);
        if (env.get("PATH")) |v| try env_map.put("PATH", v);

        const step = RunStep.create(b, "xcodebuild test");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.env_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "test",
            "-scheme",
            "Ghostty",
            "-skip-testing",
            "GhosttyUITests",
        });
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });
        step.addArgs(&.{
            b.fmt("GHOSTTY_GOOGLE_CLIENT_ID={s}", .{config.google_client_id}),
        });

        // We need the xcframework
        deps.xcframework.addStepDependencies(&step.step);

        // We also need all these resources because the xcode project
        // references them via symlinks.
        deps.resources.addStepDependencies(&step.step);
        if (deps.i18n) |v| v.addStepDependencies(&step.step);
        deps.docs.installDummy(&step.step);

        // Expect success
        step.expectExitCode(0);

        break :xctest step;
    };

    // Our step to open the resulting Ghostty app.
    const open = open: {
        const disable_save_state = RunStep.create(b, "disable save state");
        disable_save_state.has_side_effects = true;
        disable_save_state.addArgs(&.{
            "/usr/libexec/PlistBuddy",
            "-c",
            // We'll have to change this to `Set` if we ever put this
            // into our Info.plist.
            "Add :NSQuitAlwaysKeepsWindows bool false",
            b.fmt("{s}/Contents/Info.plist", .{app_path}),
        });
        disable_save_state.expectExitCode(0);
        disable_save_state.step.dependOn(&build.step);

        const open = RunStep.create(b, "run Ghostty app");
        open.has_side_effects = true;
        open.cwd = b.path("");
        open.addArgs(&.{b.fmt(
            "{s}/Contents/MacOS/ghostty",
            .{app_path},
        )});

        // Open depends on the app
        open.step.dependOn(&build.step);
        open.step.dependOn(&disable_save_state.step);

        // This overrides our default behavior and forces logs to show
        // up on stderr (in addition to the centralized macOS log).
        open.setEnvironmentVariable("GHOSTTY_LOG", "stderr,macos");

        // Configure how we're launching
        open.setEnvironmentVariable("GHOSTTY_MAC_LAUNCH_SOURCE", "zig_run");

        if (b.args) |args| {
            open.addArgs(args);
        }

        break :open open;
    };

    // Our step to copy the app bundle to the install path.
    // We have to use `cp -R` because there are symlinks in the
    // bundle.
    const copy = copy: {
        const step = RunStep.create(b, "copy app bundle");
        step.addArgs(&.{ "cp", "-R" });
        step.addFileArg(b.path(app_path));
        step.addArg(b.fmt("{s}", .{b.install_path}));
        step.step.dependOn(&build.step);
        break :copy step;
    };

    // Embed the ghoztty-agent daemon into the installed bundle. Only the
    // zig-out copy gets it (not the xcodebuild output under macos/build), so
    // it must land after the cp -R and before the re-sign so the nested
    // binary is covered by the bundle seal (`codesign --deep` below).
    const embed_agent: ?*RunStep = if (deps.agent) |agent| embed: {
        const step = RunStep.create(b, "embed ghoztty-agent");
        step.has_side_effects = true;
        step.addArgs(&.{ "cp", "-f" });
        step.addFileArg(agent.exe.getEmittedBin());
        step.addArg(b.fmt(
            "{s}/{s}.app/Contents/MacOS/ghoztty-agent",
            .{ b.install_path, app_name },
        ));
        step.expectExitCode(0);
        step.step.dependOn(&copy.step);
        break :embed step;
    } else null;

    // Re-sign the copied bundle. `cp -R` above breaks the code-signature
    // seal (the on-disk pages no longer match the sealed hashes), which makes
    // the hardened-runtime binary fail page validation and get SIGKILL'd with
    // "Code Signature Invalid" when the inner Mach-O is exec'd directly (e.g.
    // running `.../MacOS/ghostty +new-window` as a CLI). A fresh sign of
    // the installed copy re-seals it so it launches cleanly.
    //
    // Identity: `GHOSTTY_CODESIGN_IDENTITY` if set, else a stable local
    // self-signed identity when present, else ad-hoc ("-"). A STABLE identity
    // (vs ad-hoc) keeps the Keychain ACL's designated requirement constant
    // across rebuilds, so "Always Allow" on the relay-account Keychain item
    // survives — ad-hoc signatures read as a brand-new app every build and
    // re-prompt for the login-keychain password after each rebuild.
    const sign = sign: {
        const identity = std.process.getEnvVarOwned(
            b.allocator,
            "GHOSTTY_CODESIGN_IDENTITY",
        ) catch identity: {
            // No `-v`: a local self-signed identity is untrusted by the system
            // PKI, so it never appears under "valid identities only" — but
            // codesign signs with it fine, and that is all a stable local
            // designated requirement needs. Create one once with:
            //   Keychain Access ▸ Certificate Assistant ▸ Create a Certificate
            //   (name "Ghoztty Debug Signing", type Code Signing), or import a
            //   self-signed code-signing cert named the same.
            const probe = std.process.Child.run(.{
                .allocator = b.allocator,
                .argv = &.{ "security", "find-identity", "-p", "codesigning" },
            }) catch break :identity b.dupe("-");
            if (std.mem.indexOf(u8, probe.stdout, "Ghoztty Debug Signing") != null)
                break :identity b.dupe("Ghoztty Debug Signing");
            break :identity b.dupe("-");
        };
        const step = RunStep.create(b, "codesign app bundle");
        step.has_side_effects = true;
        step.addArgs(&.{ "codesign", "--force", "--deep", "--sign", identity });
        step.addArg(b.fmt("{s}/{s}.app", .{ b.install_path, app_name }));
        step.expectExitCode(0);
        step.step.dependOn(&copy.step);
        if (embed_agent) |embed| step.step.dependOn(&embed.step);
        break :sign step;
    };

    return .{
        .build = build,
        .open = open,
        .copy = copy,
        .sign = sign,
        .xctest = xctest,
    };
}

pub fn install(self: *const Ghostty) void {
    const b = self.copy.step.owner;
    // Depend on the re-sign step, which itself depends on the copy — so the
    // installed bundle is always re-sealed after the signature-breaking cp -R.
    b.getInstallStep().dependOn(&self.sign.step);
}

pub fn installXcframework(self: *const Ghostty) void {
    const b = self.build.step.owner;
    b.getInstallStep().dependOn(&self.build.step);
}

pub fn addTestStepDependencies(
    self: *const Ghostty,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(&self.xctest.step);
}
