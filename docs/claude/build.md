# Build, run & debug

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load this when building
> either platform, launching a dev build, chasing a build failure or crash
> (crash diagnostics, minidumps, cdb), or staging a release/delivery. Test
> lanes and harness rules live in `docs/claude/testing.md`.

## Build, run & debug

Both platforms build from the same `zig build`; what differs is the app runtime
(`-Dapp-runtime`, which defaults to `none` on macOS and `win32` on Windows) and
what comes out the other end. **The installed app is the user's primary
terminal on both platforms — never test against it.**

### macOS

```bash
zig build -Doptimize=Debug      # -> zig-out/Ghoztty-Debug.app (xcodebuild)
open -na zig-out/Ghoztty-Debug.app
```

- **NEVER modify, replace, copy over, or touch `/Applications/Ghoztty.app` in
  any way.** Always test with the debug build at `zig-out/Ghoztty-Debug.app`.
  The debug build uses a separate socket (`ghostty-debug-<uid>.sock`) and a
  separate bundle identifier, so it runs alongside the release app.
- IPC endpoint: `$TMPDIR/ghostty[-debug]-<uid>.sock`.
- Logs: `sudo log stream --level debug --predicate
  'subsystem=="com.dzearing.ghoztty"'`.
- Swift frontend sources live in `macos/`; `zig build` drives `xcodebuild` for
  them (`src/build/GhosttyXcodebuild.zig`).

### Windows

```powershell
$env:ZIG_GLOBAL_CACHE_DIR = 'D:\zig-global-cache'   # MUST be on the repo's drive
zig build -Dapp-runtime=win32 -Doptimize=Debug      # -> zig-out\bin\ghoztty.exe
.\zig-out\bin\ghoztty.exe
```

- **`ZIG_GLOBAL_CACHE_DIR` must sit on the same drive as the repo.** Across
  drives, `std.fs.path.relative` returns an absolute path and zig 0.15.2's build
  runner panics in `convertPathArg` (`assert(!isAbsolute(child_cwd_rel))` in std
  `Run.zig`) — it aborts the run before any test executes, which reads like a
  test failure and is not one.

  **`build.zig` now refuses that shell before the panic can happen** (T243): the
  first thing `build()` does is compare the build root's drive letter against the
  resolved global cache's, and a mismatch is `error:
  GlobalCacheOnDifferentDrive` with the `$env:`/`set` line to paste. A doc note
  was not enough — this trap was paid at least four separate times (T242,
  T257/T262, T225), and one of those turns re-ran the identical command on the
  assumption of a transient, because a panic with no `error:` line naming this
  repo is exactly the shape of a flake. It never *sets* the variable for you: a
  build script that silently relocates a user's cache is its own surprise.
  Decision logic is pure (`src/build/drive_check.zig`, asserted by `zig build
  test` via the `src/build/build_test.zig` aggregator — the main test binary
  roots at `src/main.zig` and reaches no build logic at all); "cannot tell" is
  always answered as "no mismatch", so a POSIX seat, a UNC checkout, or a
  same-drive CI box is untouched.
- **`-Doptimize=Debug` is not optional**, and the reason is not speed — it is
  **endpoint isolation** (T350). The IPC pipe, the local agent's pipe and the
  state directory are all derived from the build mode: `is_debug` (Debug or
  ReleaseSafe) gets the `-debug` names, anything else gets *the same names the
  user's installed Ghoztty is already using*. So a `zig build
  -Dapp-runtime=win32` without the flag leaves a release build in `zig-out`, and
  from that moment `+new-window` opens windows in the user's terminal, the
  path-filtered kills match nothing, and the acceptance suite reports passes
  about a binary nobody here built. A private `GHOZTTY_PIPE_SUFFIX` does not fix
  it: the agent pipe has no env override. `test\win32\lib\BuildMode.ps1` now
  refuses such a run before anything is launched (acceptance:
  `test\win32\build-mode-guard.ps1`); `GHOZTTY_TEST_ALLOW_RELEASE=1` is the
  opt-in for a script whose subject really is the release build.
- **And build it BEFORE you run an acceptance script, not after** (T1028). The
  same pre-flight now also refuses a `zig-out` exe that is OLDER than the sources
  it would measure: a stale exe that still passes exits 0, and exiting 0 stamps
  the harness guard as having seen code it never saw. See the freshness rule in
  `docs/claude/testing.md` (acceptance: `test\win32\build-fresh-guard.ps1`).
- **Never run or overwrite an installed Ghoztty** — not the installed release
  under `%LOCALAPPDATA%\Programs\Ghoztty`, not an extracted portable copy. This
  is the on-box analog of the `/Applications/Ghoztty.app` rule. Always run the
  freshly built `zig-out\bin\ghoztty.exe`.
- **A debug build announces itself** (T43): its whole caption/tab band is
  tinted warning amber and its title carries `" [DEBUG]"`, so a dev instance is
  never mistaken for the user's installed release. Gated on `Debug`/
  `ReleaseSafe` (the Mac banner's own gate). `GHOZTTY_DEBUG_MARKER=0` turns the
  tint off — the GUI acceptance harness sets it, because those scripts measure
  debug chrome as the proxy for what ships (see
  `docs/design/win32-design-system.md` §2.5).
- **Debug builds link the Console subsystem**, so `std.log` output goes to
  stderr in the shell you launched from, like every other platform. Release
  builds use the GUI subsystem (no console) and append `info` and above to
  `%LOCALAPPDATA%\ghoztty\ghoztty.log`; add `-Dwindows-console=true` to give a
  release build a console when you need to debug one live.
- IPC endpoint: the named pipe `\\.\pipe\ghoztty[-debug]-<USERNAME>` — the
  `-debug` suffix is what lets a debug build run alongside the installed
  release. `GHOZTTY_PIPE_SUFFIX` overrides the suffix; `GHOZTTY_IPC_SOCKET`
  (baked into every pane) overrides the whole endpoint, see Instance
  addressability in `docs/claude/cli.md`.
- **A leftover agent no longer fails the build** (T192). The agent outlives the
  app on purpose, so a `ghoztty-agent.exe` left running from `zig-out\bin` by an
  earlier test run holds its own image file open — and Windows will not let
  anything replace a running image, so the install step used to die with
  `unable to update file … AccessDenied` **after `ghoztty.exe` had already
  installed**. That shape is the expensive part: exit 1 over a binary that
  really did change, which reads as "my change did not build" and turns a real
  test result into a suspected stale-binary artifact.

  A build-time host tool (`src/build/install_unlock_main.zig`, wired by
  `InstallUnlock.zig`) now runs ahead of every Windows install step and moves a
  locked destination aside as `<name>.old-<n>`, so the install's own atomic
  rename lands on an empty path; the leftover is deleted by a later build once
  the process holding it exits. Renaming, not killing: a build that terminated
  processes would take a concurrently-running acceptance suite's agent, and its
  live sessions, with it. The move must go through `MoveFileExW` — Zig's
  `std.fs.Dir.rename` opens the source with `GENERIC_WRITE | DELETE`, which a
  running image's share mode denies, so it fails on exactly the file this
  exists for. A still-running process keeps the `ExecutablePath` it was created
  with, so the path-filtered kills below still find it after the move.

  `GHOZTTY_INSTALL_UNLOCK=0` turns the guard off and reproduces the original
  failure from the same tree; acceptance:
  `test\win32\build-locked-artifact.ps1`.

  To stop a repo agent by hand, match on `ExecutablePath`, never on name — the
  installed release runs its own agent from `%LOCALAPPDATA%\Programs\Ghoztty`
  and owns the user's live sessions:

  ```powershell
  Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
      Where-Object { $_.ExecutablePath -eq 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  ```
- **`ghoztty.com` is the CLI entry point from PowerShell/cmd** (T245).
  PowerShell keys its wait-and-redirect decision on the PE subsystem field, so
  `ghoztty +verb > file` against the GUI-subsystem `ghoztty.exe` writes 0 bytes
  silently (`$LASTEXITCODE` stays empty). The build therefore installs
  `ghoztty.com` — the SAME binary with the optional-header Subsystem WORD
  flipped to console (`src/build/patch_subsystem_main.zig`) — as a required
  sibling; PATHEXT resolves `.COM` before `.EXE`, so bare `ghoztty` from
  PowerShell or cmd gets working redirection, pipes, and exit codes (the
  devenv.com pattern). A GUI launch through the twin respawns `ghoztty.exe`
  detached (`runComShimGuiRespawn`), so a shell never blocks on the terminal it
  launched. Do NOT reintroduce a small relay shim: Defender's ML quarantined
  that shape on sight (`src/cli/com_shim.zig` has the story). Scripts calling
  `ghoztty.exe` by explicit path still need pipe capture, or should call the
  `.com`. Acceptance: `test/win32/cli-shim-redirect.ps1`.
- The session-persistence agent builds alongside the app as
  `zig-out\bin\ghoztty-agent.exe` (a required sibling of `ghoztty.exe`); its
  state lives under `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\` and it is
  dialed over `\\.\pipe\ghoztty-agent[-debug]-<USERNAME>`. A stale agent from an
  earlier build keeps running by design — see Agent contract & upgrade
  compatibility.
- Release/delivery build (what ships, and what the delivery scripts stage):

  ```powershell
  zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast `
      -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release
  ```

  `-Dstrip=false` is load-bearing: a stripped release build produces
  undebuggable crash dumps. Delivery to the user's install locations goes
  through `scripts/launch-upgrade.ps1` (never a hand-rolled `Start-Process`);
  `go.md` has the full protocol and the staleness gates.

