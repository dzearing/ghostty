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
    // Before anything else, because everything else is what trips it: a global
    // cache on a different Windows drive than the repo makes the build runner
    // PANIC (see src/build/drive_check.zig), and a panic with no `error:` line
    // naming this repo reads as a transient rather than as an environment
    // problem. Refuse with a sentence instead.
    try checkGlobalCacheDrive(b);

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

    // T631 — a filtered run that matches NOTHING exits 0, which is
    // indistinguishable from "matched and passed". One collector per top-level
    // test step gathers that step's test runs; `attach` at the end of build()
    // turns the aggregate count into a verdict. Inert without `-Dtest-filter`.
    var test_filter_guard: buildpkg.TestFilterGuard.Collector =
        .init(b, "test", test_filters);
    var test_agent_filter_guard: buildpkg.TestFilterGuard.Collector =
        .init(b, "test-agent", test_filters);
    var test_lib_vt_filter_guard: buildpkg.TestFilterGuard.Collector =
        .init(b, "test-lib-vt", test_filters);

    // Two diagnostic knobs for the test binaries (T473). The test exes pin
    // their own optimize mode and codegen backend rather than following
    // `-Doptimize`, which is deliberate — but it also means a crash that looks
    // like a codegen bug cannot be rebuilt a different way to rule the
    // toolchain in or out. These let a lane be rebuilt with the self-hosted
    // x86_64 backend or at a release optimize mode WITHOUT editing build.zig.
    // Both default to exactly what the lanes have always built, so `zig build
    // test` / `test-agent` are unchanged.
    const test_optimize = b.option(
        std.builtin.OptimizeMode,
        "test-optimize",
        "Optimize mode for the Zig test binaries. Default Debug (what every lane builds).",
    ) orelse .Debug;
    const test_llvm = b.option(
        bool,
        "test-llvm",
        "Use the LLVM backend for the Zig test binaries. Default true; false selects Zig's self-hosted backend.",
    ) orelse true;

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
    // built via `zig build agent`, and embedded into the macOS app bundle
    // (Contents/MacOS/ghoztty-agent) so the app can spawn its local
    // session-persistence agent.
    const agent = try buildpkg.GhosttyAgent.init(b, &config, &deps);
    {
        agent_step.dependOn(&agent.install_step.step);
        if (agent.ca_dll_install_step) |ca| agent_step.dependOn(&ca.step);

        // `zig build test-agent` runs the agent's tests, including the real-pty
        // child end-to-end tests (which need pty-c + os deps, so they can't run
        // under a pure logic-only test root).
        const agent_test = b.addTest(.{
            .name = "ghoztty-agent-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/agent_main.zig"),
                .target = config.target,
                .optimize = test_optimize,
            }),
            .use_llvm = test_llvm,
        });
        // The agent test roots at `src/agent_main.zig` too, so it reaches
        // main.zig's `@import("agent_build_options")` — reuse the exe's module.
        agent_test.root_module.addImport("agent_build_options", agent.version_module);
        if (!config.emit_lib_vt) _ = try deps.add(agent_test);
        // src/terminal (reached both via pty.zig and, for the grid snapshot, via
        // grid_snapshot.zig) has test blocks verifying enums against the
        // libghostty C header (`lib.checkGhosttyHEnum`), so the agent test binary
        // needs the same `ghostty.h` module the main test build wires.
        agent_test.root_module.addImport(
            "ghostty.h",
            b.addTranslateC(.{
                .root_source_file = b.path("include/ghostty.h"),
                .target = config.baselineTarget(),
                .optimize = .Debug,
            }).createModule(),
        );
        const agent_test_run = b.addRunArtifact(agent_test);
        test_agent_filter_guard.add(agent_test_run);
        test_agent_step.dependOn(&agent_test_run.step);

        // There is exactly ONE test binary in this lane, on purpose (T434).
        // `remote/agent/main.zig` imports server, session, grid_snapshot,
        // session_meta, ring_snapshot, metrics, foreground, descendants,
        // keepalive, socket_stream, socket_rw and pipe_stream, and
        // a zig test binary carries the tests of every file in its import
        // graph — so the `src/remote/agent_test.zig` aggregator that used to be
        // wired here as `ghoztty-agent-core-test` was a strict SUBSET of this
        // one. Measured 2026-09-04: 5443 passed / 78 skipped here against
        // 5335 / 72 there, with no file present in the aggregator's binary and
        // absent from this one. The lane built and ran the same tests twice,
        // concurrently, which is also the shape T430 recorded frozen.
    }

    // Ghoztty remote-machines test client (WP: TCP transport). A headless native
    // CLI that dials a TCP-listening ghoztty-agent and relays a shell session —
    // the orchestrator's tool for cross-machine end-to-end tests. Built on demand
    // via `zig build remote-test-client`.
    {
        const client = try buildpkg.GhosttyRemoteTestClient.init(b, &config, &deps);
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

            // Windows: install ghoztty-agent.exe as a SIBLING of ghoztty.exe.
            // Session persistence (T89d) spawns it by that relative location
            // (LocalAgent.agentBinary), so every install layout — zig-out,
            // the MSI, the portable zip — must carry the pair together
            // (T89h). macOS instead embeds the agent inside the app bundle.
            if (config.target.result.os.tag == .windows) {
                agent.install();

                // T192: an artifact whose destination is currently RUNNING
                // cannot be replaced in place on Windows — the image file is
                // held open for the life of the process, and the agent
                // outliving the app is the point of session persistence. Move
                // a locked destination aside before the install steps run so
                // a leftover agent from an earlier test run cannot fail the
                // build (and, worse, fail it AFTER ghoztty.exe installed).
                const unlock = buildpkg.InstallUnlock.create(b);
                unlock.guardArtifact(exe.install_step);
                if (exe.com_install_step) |com| unlock.guardInstallFile(com);
                // The fallback GL (T1252) is a loaded module for as long as an
                // instance that took it is alive, so it is exactly as
                // unreplaceable as the exe when a test run left one behind.
                for (exe.gl_install_steps) |gl| unlock.guardInstallFile(gl);
                unlock.guardArtifact(agent.install_step);
                if (agent.ca_dll_install_step) |ca| unlock.guardArtifact(ca);
            }
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
                .agent = &agent,
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
                    .agent = &agent,
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
        test_lib_vt_filter_guard.add(mod_vt_test_run);
        test_lib_vt_step.dependOn(&mod_vt_test_run.step);

        const mod_vt_c_test = b.addTest(.{
            .root_module = mod.vt_c,
            .filters = test_filters,
        });
        const mod_vt_c_test_run = b.addRunArtifact(mod_vt_c_test);
        test_lib_vt_filter_guard.add(mod_vt_c_test_run);
        test_lib_vt_step.dependOn(&mod_vt_c_test_run.step);
    }

    // The pure, std-only helpers under src/build/. The main test binary roots
    // at src/main.zig and so reaches none of the build logic, which is how a
    // `test` block next to a build helper used to run in no step at all. Kept
    // outside the emit_lib_vt guard below: it depends on nothing.
    {
        const build_helpers_test = b.addTest(.{
            .name = "ghoztty-build-helpers-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/build/build_test.zig"),
                .target = config.baselineTarget(),
                .optimize = test_optimize,
            }),
            .use_llvm = test_llvm,
        });
        const build_helpers_test_run = b.addRunArtifact(build_helpers_test);
        test_filter_guard.add(build_helpers_test_run);
        test_step.dependOn(&build_helpers_test_run.step);
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
                .optimize = test_optimize,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            // Crash on x86_64 without this
            .use_llvm = test_llvm,
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
        test_filter_guard.add(test_run);
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

    // T631 — last, once every test run above has been registered. Each of
    // these is a no-op unless `-Dtest-filter` was given.
    test_filter_guard.attach(test_step);
    test_agent_filter_guard.attach(test_agent_step);
    test_lib_vt_filter_guard.attach(test_lib_vt_step);
}

/// T243: refuse the build when the global cache sits on a different Windows
/// drive than the repo, instead of letting the build runner panic on an
/// unrelated-looking assert deep in `std.Build.Step.Run`. See
/// `src/build/drive_check.zig` for what goes wrong and why a diagnostic here
/// beats a line in a doc.
fn checkGlobalCacheDrive(b: *std.Build) !void {
    const mismatch = buildpkg.drive_check.check(
        absoluteRootPath(b, b.build_root),
        absoluteRootPath(b, b.graph.global_cache_root),
    ) orelse return;

    var buf: [64]u8 = undefined;
    const suggestion = buildpkg.drive_check.suggestedCacheDir(&buf, mismatch.build_root);
    std.log.err(
        \\the zig global cache is on drive {c}: but this repo is on drive {c}:.
        \\
        \\  Zig 0.15.2's build runner cannot make a path on one drive relative to a
        \\  cwd on another, and asserts instead of reporting it — so this build would
        \\  end in "panic: reached unreachable code" from std/Build/Step/Run.zig with
        \\  nothing pointing at your change. Point the cache at this drive first:
        \\
        \\      $env:ZIG_GLOBAL_CACHE_DIR = '{s}'      # PowerShell
        \\      set ZIG_GLOBAL_CACHE_DIR={s}           # cmd.exe
        \\
        \\  Export it in every build/test shell. Nothing here changes it for you: a
        \\  build script that silently relocates your cache is its own surprise.
    , .{ mismatch.cache_root, mismatch.build_root, suggestion, suggestion });
    return error.GlobalCacheOnDifferentDrive;
}

/// A root directory's path with a drive letter on it when one can be had.
/// `Cache.Directory.path` is null for the cwd and may be relative, neither of
/// which can be compared to another drive — the open handle can still say
/// where it really is.
fn absoluteRootPath(b: *std.Build, dir: std.Build.Cache.Directory) ?[]const u8 {
    if (dir.path) |p| {
        if (buildpkg.drive_check.driveLetter(p) != null) return p;
    }
    return dir.handle.realpathAlloc(b.allocator, ".") catch null;
}
