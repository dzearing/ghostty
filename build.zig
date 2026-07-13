const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const buildpkg = @import("src/build/main.zig");

/// App version from build.zig.zon.
const app_zon_version = @import("build.zig.zon").version;

/// Libghostty version. We use a separate version from the app.
const lib_version = "0.1.0-dev";

/// Minimum required zig version.
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;

comptime {
    buildpkg.requireZig(minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    // This defines all the available build options (e.g. `-D`). If you
    // want to know what options are available, you can run `--help` or
    // you can read `src/build/Config.zig`.

    // If we have a VERSION file (present in source tarballs) then we
    // use that as the version source of truth. Otherwise we fall back
    // to what is in the build.zig.zon.
    const file_version: ?[]const u8 = if (b.build_root.handle.readFileAlloc(
        b.allocator,
        "VERSION",
        128,
    )) |content| std.mem.trim(
        u8,
        content,
        &std.ascii.whitespace,
    ) else |_| null;

    const config = try buildpkg.Config.init(
        b,
        file_version orelse app_zon_version,
        lib_version,
    );
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};

    // Ghostty dependencies used by many artifacts.
    const deps = try buildpkg.SharedDeps.init(b, &config);

    // The modules exported for Zig consumers of libghostty. If you're
    // writing a Zig program that uses libghostty, read this file.
    const mod = try buildpkg.GhosttyZig.init(
        b,
        &config,
        &deps,
    );

    // All our steps which we'll hook up later. The steps are shown
    // up here just so that they are more self-documenting.
    const run_step = b.step("run", "Run the app");
    const run_valgrind_step = b.step(
        "run-valgrind",
        "Run the app under valgrind",
    );
    const test_step = b.step("test", "Run tests");
    const agent_step = b.step("agent", "Build the ghoztty-agent (remote-machines daemon)");
    const test_agent_step = b.step("test-agent", "Run the ghoztty-agent tests (incl. real-pty)");
    const conpty_smoke_step = b.step("conpty-smoke", "Build the ConPTY runtime smoke exe (Windows, cross-compile)");
    const remote_test_client_step = b.step("remote-test-client", "Build the remote-test-client (drives a TCP ghoztty-agent)");
    const wp4_e2e_step = b.step("wp4-e2e", "Build the WP4 headless e2e harness (Connection.openChannel over TCP vs the real agent)");
    const remote_backend_e2e_step = b.step("remote-backend-e2e", "Build the WP4 headless RENDER harness (real Termio/.remote backend grid render vs the real agent)");
    const test_lib_vt_step = b.step(
        "test-lib-vt",
        "Run libghostty-vt tests",
    );
    const test_valgrind_step = b.step(
        "test-valgrind",
        "Run tests under valgrind",
    );
    const translations_step = b.step(
        "update-translations",
        "Update translation files",
    );

    // Ghostty resources like terminfo, shell integration, themes, etc.
    const resources = try buildpkg.GhosttyResources.init(b, &config, &deps);
    const i18n = if (config.i18n) try buildpkg.GhosttyI18n.init(b, &config) else null;

    // Ghostty executable, the actual runnable Ghostty program.
    const exe = try buildpkg.GhosttyExe.init(b, &config, &deps);

    // Ghoztty remote-machines agent (WP2). A standalone, GUI-free daemon exe
    // built on demand via `zig build agent`. It is not part of the default
    // install graph this increment (daemonization/packaging is deferred).
    {
        const agent = try buildpkg.GhosttyAgent.init(b, &config, &deps);
        agent_step.dependOn(&agent.install_step.step);
        if (agent.ca_dll_install_step) |ca| agent_step.dependOn(&ca.step);

        // `zig build test-agent` runs the agent's tests, including the real-pty
        // child end-to-end tests (which need pty-c + os deps, so they can't run
        // under the pure `agent_test.zig` standalone command).
        const agent_test = b.addTest(.{
            .name = "ghoztty-agent-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/agent_main.zig"),
                .target = config.target,
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        // The agent test roots at `src/agent_main.zig` too, so it reaches
        // main.zig's `@import("agent_build_options")` — reuse the exe's module.
        agent_test.root_module.addImport("agent_build_options", agent.version_module);
        if (!config.emit_lib_vt) _ = try deps.add(agent_test);
        const agent_test_run = b.addRunArtifact(agent_test);
        test_agent_step.dependOn(&agent_test_run.step);

        // The agent-core aggregator (`src/remote/agent_test.zig`: server,
        // session store, metrics, keepalive, socket stream). Previously only
        // runnable by hand via `zig test -Mroot=src/remote/agent_test.zig`,
        // so its ~140 tests ran in NO build step; wire it into `test-agent`.
        const agent_core_test = b.addTest(.{
            .name = "ghoztty-agent-core-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/remote/agent_test.zig"),
                .target = config.target,
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        const agent_core_test_run = b.addRunArtifact(agent_core_test);
        test_agent_step.dependOn(&agent_core_test_run.step);
    }

    // Ghoztty remote-machines test client (WP: TCP transport). A headless native
    // CLI that dials a TCP-listening ghoztty-agent and relays a shell session —
    // the orchestrator's tool for cross-machine end-to-end tests. Built on demand
    // via `zig build remote-test-client`.
    {
        const client = try buildpkg.GhosttyRemoteTestClient.init(b, &config);
        remote_test_client_step.dependOn(&client.install_step.step);
    }

    // Ghoztty WP4 Phase-1 headless e2e de-risk harness. Spawns the real
    // ghoztty-agent on a localhost TCP port and drives the high-level
    // `Connection.openChannel` (the same call termio/Remote.zig makes) to prove the
    // client/agent channel rendezvous round-trips against the real,
    // channel-authoritative agent. Built on demand via `zig build wp4-e2e`.
    {
        const harness = try buildpkg.GhosttyWp4E2e.init(b, &config);
        wp4_e2e_step.dependOn(&harness.install_step.step);
    }

    // Ghoztty WP4 headless RENDER de-risk harness. Stands up a REAL Termio with a
    // `.remote` backend on a REAL IO thread (the exact GUI lifecycle) against the
    // real agent over TCP, and asserts the terminal GRID renders remote output —
    // the render assertion the GUI lacks. Reproduces the "blank window" bug
    // headlessly. Built on demand via `zig build remote-backend-e2e`.
    {
        const harness = try buildpkg.GhosttyRemoteBackendE2e.init(b, &config, &deps);
        remote_backend_e2e_step.dependOn(&harness.install_step.step);
    }

    // Ghoztty ConPTY runtime smoke exe (WP2, §13). A tiny standalone Windows .exe
    // that proves the in-tree ConPTY machinery works on real hardware. Built on
    // demand via `zig build conpty-smoke -Dtarget=<arch>-windows`. The artifact is
    // named per-arch (ghoztty-conpty-smoke-<arch>.exe) so both arches coexist.
    {
        const smoke = try buildpkg.GhosttyConptySmoke.init(b, &config, &deps);
        conpty_smoke_step.dependOn(&smoke.install_step.step);
    }

    // Ghostty docs
    const docs = try buildpkg.GhosttyDocs.init(b, &deps);
    if (config.emit_docs) {
        docs.install();
    } else if (config.target.result.os.tag.isDarwin()) {
        // If we aren't emitting docs we need to emit a placeholder so
        // our macOS xcodeproject builds since it expects the `share/man`
        // directory to exist to copy into the app bundle.
        docs.installDummy(b.getInstallStep());
    }

    // Ghostty webdata
    const webdata = try buildpkg.GhosttyWebdata.init(b, &deps);
    if (config.emit_webdata) webdata.install();

    // Ghostty bench tools
    const bench = try buildpkg.GhosttyBench.init(b, &deps);
    if (config.emit_bench) bench.install();

    // Ghostty dist tarball
    const dist = try buildpkg.GhosttyDist.init(b, &config);
    {
        const step = b.step("dist", "Build the dist tarball");
        step.dependOn(dist.install_step);
        const check_step = b.step("distcheck", "Install and validate the dist tarball");
        check_step.dependOn(dist.check_step);
        check_step.dependOn(dist.install_step);
    }

    // libghostty-vt
    const libghostty_vt_shared = shared: {
        if (config.target.result.cpu.arch.isWasm()) {
            break :shared try buildpkg.GhosttyLibVt.initWasm(
                b,
                &mod,
            );
        }

        break :shared try buildpkg.GhosttyLibVt.initShared(
            b,
            &mod,
        );
    };
    libghostty_vt_shared.install(b.getInstallStep());

    // libghostty-vt static lib
    const libghostty_vt_static = try buildpkg.GhosttyLibVt.initStatic(
        b,
        &mod,
    );
    if (config.is_dep) {
        // If we're a dependency, we need to install everything as-is
        // so that dep.artifact("ghostty-vt-static") works.
        libghostty_vt_static.install(b.getInstallStep());
    } else {
        // If we're not a dependency, we rename the static lib to
        // be idiomatic. On Windows, we use a distinct name to avoid
        // colliding with the DLL import library (ghostty-vt.lib).
        const static_lib_name = if (config.target.result.os.tag == .windows)
            "ghostty-vt-static.lib"
        else
            "libghostty-vt.a";
        b.getInstallStep().dependOn(&b.addInstallLibFile(
            libghostty_vt_static.output,
            static_lib_name,
        ).step);
    }

    // libghostty-vt xcframework (Apple only, universal binary).
    // Only when building on macOS (not cross-compiling) since
    // xcodebuild is required.
    if (config.emit_lib_vt and
        config.emit_xcframework and
        builtin.os.tag.isDarwin() and
        config.target.result.os.tag.isDarwin())
    {
        const apple_libs = try buildpkg.GhosttyLibVt.initStaticAppleUniversal(
            b,
            &config,
            &deps,
            &mod,
        );
        const xcframework = buildpkg.GhosttyLibVt.xcframework(&apple_libs, b);
        b.getInstallStep().dependOn(xcframework.step);
    }

    // Helpgen
    if (config.emit_helpgen) deps.help_strings.install();

    // Runtime "none" is libghostty, anything else is an executable.
    if (config.app_runtime != .none) {
        if (config.emit_exe) {
            exe.install();
            resources.install();
            if (i18n) |v| v.install();
        }
    } else if (!config.emit_lib_vt) {
        // The macOS Ghostty Library
        //
        // This is NOT libghostty (even though its named that for historical
        // reasons). It is just the glue between Ghostty GUI on macOS and
        // the full Ghostty GUI core.
        const lib_shared = try buildpkg.GhosttyLib.initShared(b, &deps);
        const lib_static = try buildpkg.GhosttyLib.initStatic(b, &deps);

        // We shouldn't have this guard but we don't currently
        // build on macOS this way ironically so we need to fix that.
        if (!config.target.result.os.tag.isDarwin()) {
            lib_shared.installHeader(); // Only need one header
            if (config.target.result.os.tag == .windows) {
                lib_shared.install("ghostty-internal.dll");
                lib_static.install("ghostty-internal-static.lib");
            } else {
                lib_shared.install("ghostty-internal.so");
                lib_static.install("ghostty-internal.a");
            }
        }
    }

    // macOS only artifacts. These will error if they're initialized for
    // other targets. In lib-vt mode emit_xcframework controls the lib-vt
    // xcframework above, not this one.
    if (!config.emit_lib_vt and config.target.result.os.tag.isDarwin() and
        (config.emit_xcframework or config.emit_macos_app))
    {
        // Ghostty xcframework
        const xcframework = try buildpkg.GhosttyXCFramework.init(
            b,
            &deps,
            config.xcframework_target,
        );
        if (config.emit_xcframework) {
            xcframework.install();

            // The xcframework build always installs resources because our
            // macOS xcode project contains references to them.
            resources.install();
            if (i18n) |v| v.install();
        }

        // Ghostty macOS app
        const macos_app = try buildpkg.GhosttyXcodebuild.init(
            b,
            &config,
            .{
                .xcframework = &xcframework,
                .docs = &docs,
                .i18n = if (i18n) |v| &v else null,
                .resources = &resources,
            },
        );
        if (config.emit_macos_app) {
            macos_app.install();
        }
    }

    // Run step
    run: {
        if (config.app_runtime != .none) {
            const run_cmd = b.addRunArtifact(exe.exe);
            if (b.args) |args| run_cmd.addArgs(args);

            // Set the proper resources dir so things like shell integration
            // work correctly. If we're running `zig build run` in Ghostty,
            // this also ensures it overwrites the release one with our debug
            // build.
            run_cmd.setEnvironmentVariable(
                "GHOSTTY_RESOURCES_DIR",
                b.getInstallPath(.prefix, "share/ghostty"),
            );

            run_step.dependOn(&run_cmd.step);
            break :run;
        }

        assert(config.app_runtime == .none);

        // On macOS we can run the macOS app. For "run" we always force
        // a native-only build so that we can run as quickly as possible.
        if (!config.emit_lib_vt and
            config.target.result.os.tag.isDarwin() and
            (config.emit_xcframework or config.emit_macos_app))
        {
            const xcframework_native = try buildpkg.GhosttyXCFramework.init(
                b,
                &deps,
                .native,
            );
            const macos_app_native_only = try buildpkg.GhosttyXcodebuild.init(
                b,
                &config,
                .{
                    .xcframework = &xcframework_native,
                    .docs = &docs,
                    .i18n = if (i18n) |v| &v else null,
                    .resources = &resources,
                },
            );

            // Run uses the native macOS app
            run_step.dependOn(&macos_app_native_only.open.step);

            // If we have no test filters, install the tests too
            if (test_filters.len == 0) {
                macos_app_native_only.addTestStepDependencies(test_step);
            }
        }
    }

    // Valgrind
    if (config.app_runtime != .none) {
        // We need to rebuild Ghostty with a baseline CPU target.
        const valgrind_exe = exe: {
            var valgrind_config = config;
            valgrind_config.target = valgrind_config.baselineTarget();
            break :exe try buildpkg.GhosttyExe.init(
                b,
                &valgrind_config,
                &deps,
            );
        };

        const run_cmd = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--num-callers=50",
            b.fmt("--suppressions={s}", .{b.pathFromRoot("valgrind.supp")}),
            "--gen-suppressions=all",
        });
        run_cmd.addArtifactArg(valgrind_exe.exe);
        if (b.args) |args| run_cmd.addArgs(args);
        run_valgrind_step.dependOn(&run_cmd.step);
    }

    // Zig module tests
    {
        const mod_vt_test = b.addTest(.{
            .root_module = mod.vt,
            .filters = test_filters,
        });
        const mod_vt_test_run = b.addRunArtifact(mod_vt_test);
        test_lib_vt_step.dependOn(&mod_vt_test_run.step);

        const mod_vt_c_test = b.addTest(.{
            .root_module = mod.vt_c,
            .filters = test_filters,
        });
        const mod_vt_c_test_run = b.addRunArtifact(mod_vt_c_test);
        test_lib_vt_step.dependOn(&mod_vt_c_test_run.step);
    }

    // Tests (skip when building libghostty-vt)
    if (!config.emit_lib_vt) {
        // Full unit tests
        const test_exe = b.addTest(.{
            .name = "ghostty-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = config.baselineTarget(),
                .optimize = .Debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            // Crash on x86_64 without this
            .use_llvm = true,
        });
        if (config.emit_test_exe) b.installArtifact(test_exe);
        _ = try deps.add(test_exe);

        // Verify our internal libghostty header.
        const ghostty_h = b.addTranslateC(.{
            .root_source_file = b.path("include/ghostty.h"),
            .target = config.baselineTarget(),
            .optimize = .Debug,
        });
        test_exe.root_module.addImport("ghostty.h", ghostty_h.createModule());

        // Normal test running
        const test_run = b.addRunArtifact(test_exe);
        test_step.dependOn(&test_run.step);

        // Normal tests always test our libghostty modules
        //test_step.dependOn(test_lib_vt_step);

        // Valgrind test running
        const valgrind_run = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--num-callers=50",
            b.fmt("--suppressions={s}", .{b.pathFromRoot("valgrind.supp")}),
            "--gen-suppressions=all",
        });
        valgrind_run.addArtifactArg(test_exe);
        test_valgrind_step.dependOn(&valgrind_run.step);
    }

    // update-translations does what it sounds like and updates the "pot"
    // files. These should be committed to the repo.
    if (i18n) |v| {
        translations_step.dependOn(v.update_step);
    } else {
        try translations_step.addError("cannot update translations when i18n is disabled", .{});
    }
}
