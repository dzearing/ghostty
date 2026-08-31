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
- **A bare `error: Unexpected` from zig means the drive is full, not that the
  code is red** (T1054). Zig never evicts its build cache: every distinct build
  hash keeps its whole output under `.zig-cache\o\<hash>\`, and a debug
  `ghoztty.exe` is 48 MB with a 100 MB `.pdb` beside it, so this repo produces
  roughly 40 GB a day that nothing removes. On 2026-08-21 that reached exactly 0
  bytes free on `D:` — 31,359 entries, 1,235 GB — and every floor lane then died
  in five seconds with that one line, naming no file, no line and no disk.

  Two mechanisms now stand in front of it, and both live outside `build.zig`
  because a build that cannot start cannot diagnose itself:

  - `scripts\go-loop-exec.ps1 claim` runs `scripts\build-cache.ps1 sweep` once a
    turn. It asks the cheap questions only — free space on the cache drives
    (O(1)) and one non-recursive count of `.zig-cache\o` — and when either is
    over its limit it deletes the caches **whole** and prints what it reclaimed.
    Whole, not by age: pruning `o\` alone leaves the manifests in `h\` naming
    outputs that no longer exist, and the next build fails with `failed to spawn
    build runner ... FileNotFound`, which is a worse message than the one being
    fixed. `build-cache.ps1 check` reports without deleting; `clear -Force` is
    the manual hatch.
  - `scripts\floor-lane.ps1` refuses to launch a lane below 10 GB free and says
    `FLOOR PREFLIGHT FAIL: less than N GB free - the build cache needs pruning`,
    with the command to run. Same class of fix as `GlobalCacheOnDifferentDrive`
    above: when the ENVIRONMENT is at fault, say so rather than relaying a
    message about something else.

  Acceptance: `test\win32\build-cache.ps1`. Stale `zig-out-*` staging copies and
  `.dumps` are **reported and never deleted** — they sit outside a cache, so
  "entirely regenerable" is an assumption rather than a fact.
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


## What is installed on this box, and how to clear it

`scripts\ghoztty-cleanup.ps1` (T1188) is the inventory. Run it before any claim
that this machine is "clean", and read its verdict rather than a memory of which
folders somebody deleted:

```powershell
powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 inventory   # read-only
powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 clean       # proposes, per item
powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 verdict     # exit 0 = accounted for
```

It enumerates every artifact class with its provenance: the four install
locations above, every `zig-out*` prefix in the repo, Apps & Features
registrations, HKCU Run values, the settings key, the user PATH entry, Start
Menu and Startup drops, scheduled tasks, the state directory
(`%LOCALAPPDATA%\ghoztty`, which holds `relay.env` and the DPAPI account store),
live named pipes and running processes.

Three things about it are load-bearing:

- **It never offers `msiexec /x` on a protected product code.** The registered
  "Ghoztty 26.7.502" `{A10466B5-D625-4A80-95D2-8AA648F5086C}` is a ghost whose
  uninstall would delete the LIVE install's files. Protected entries are
  reported with the refusal and never with a command string.
- **Nothing is removed without a per-item yes.** There is no `-Force` and no
  "remove all"; unanswered means keep. `-Answer id=y,id2=n` is the scripted form
  the harness uses.
- **The verdict is about accounting, not emptiness.** An item is accounted for
  when it is gone, permanently protected, or explicitly kept with
  `keep <id> -Reason "<why>"` (recorded in `temp\ghoztty-cleanup-keep.json`, so
  it survives the pane it was printed in). An unaccounted removable artifact is
  the only thing that makes the box dirty. That verdict is the evidence T1179
  records for "no prior Ghoztty".

Acceptance: `test\win32\ghoztty-cleanup.ps1` (guard `ghoztty-cleanup`);
`-NegativeControl` drops the ghost from the protected list and proves it then IS
offered, which is the demonstration that the refusal is real.

## "Which Ghoztty am I running?" — the four version surfaces (T1205)

A Windows upgrade cannot replace a running image, so after an install the FILE
on disk and the PROCESS in front of the user are routinely different builds.
That is normal; the defect was that nothing said so, and four surfaces gave
four different answers. They now mean four distinct things, and each says which
it is:

| Surface | Answers | Where it comes from |
|---|---|---|
| `ghoztty +version` "Running Instance", and the About box | the build THIS window is running | `provenance.collect` over the running process |
| `ghoztty --version` (no instance) | the build of the exe you just invoked | `build_config.version_string` |
| Apps & Features | the release the user downloaded (`1.35.0`) | the MSI's `ARPDISPLAYVERSION` |
| MSI `ProductVersion` (`26.8.3108`) | upgrade sequencing only, never shown | `build-msi.sh`'s `yy.m.dNN` |

Rules that keep them from drifting back together into one lie:

- **Nothing in About may be sourced from a build other than the running one.**
  The original box printed the running process's version beside the ON-DISK
  file's mtime, so a window from yesterday read as freshly updated — the user
  opened About specifically to confirm an install and it told them the
  opposite. The file's date now appears only inside the stale-build paragraph,
  labelled as the other build's.
- **Staleness is two runtime facts, not two version strings**
  (`image_freshness.zig`): the process's creation time versus the exe's
  last-write time. An equal version string does not mean an equal build — this
  branch ships many builds per version — and a version resource is stamped by
  the packaging pipeline rather than by whatever replaced the file.
- **The app volunteers it.** A one-minute timer asks the question and a tray
  balloon says it once per build that appears on disk; clicking it spawns the
  new exe (escaping the job object) and quits this one. Nobody opens About
  unless they already suspect something, so a surface that only answers when
  asked does not close the gap.
- **`ARPDISPLAYVERSION` is what Apps & Features shows; `ProductVersion` is
  what the installer sequences on.** Never make the second one readable by
  changing it — the date-derived number is what guarantees a newer package
  compares greater.

Acceptance: `test\win32\ipc-version.ps1` section 2b moves the on-disk exe's
timestamp past the running process's start and asserts the notice appears, then
restores it and asserts the notice goes away (its own negative control).
Sections A20–A22 of `test\win32\release-artifacts.ps1` hold the ARP wiring
statically; the live proof is the package read-back inside `build-msi.sh`,
which needs Docker.
