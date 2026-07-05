# Ghoztty on Windows amd64 — port plan

Status: **beta staged** — `Ghoztty-26.7.501-x64.msi` is on
`/Volumes/share/ghoztty-windows/`, awaiting manual verification on the
Windows box (checklist at the bottom). All milestones except manual
on-box verification are complete.
Branch: `users/dzearing/windows-amd64`
Date started: 2026-07-05

## Goal

A **beta** Ghoztty terminal for Windows amd64 (x86_64): launches, renders a real
shell (ConPTY), handles keyboard/mouse input, and installs via a normal Windows
installer. Built and packaged entirely from this Mac (cross-compilation); manual
runtime verification happens on the user's Windows test box via
`/Volumes/share/ghoztty-windows/`.

## Findings that shaped the plan (M0 recon)

1. **The core already targets Windows.** Upstream Ghostty keeps the
   non-GUI tree compiling and *tested* on Windows CI
   (`zig build -Dapp-runtime=none test` runs on a Windows runner;
   `build-libghostty-windows-gnu` builds with `-Dtarget=native-native-gnu`).
   In-tree and proven:
   - `src/pty.zig` — complete ConPTY `WindowsPty` (CreatePseudoConsole,
     named pipes, resize).
   - `src/CommandCore.zig` — `startWindows()` spawns via `CreateProcessW` +
     `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.
   - `src/termio/Exec.zig` — fully `os.tag == .windows`-branched
     (Windows read thread, `cmd.exe` default shell, ConPTY spawn/kill).
   - `src/terminal/*` — portable (VirtualAlloc page allocator on Windows).
   - `src/font/discovery.zig` — `.freetype_windows` backend: FreeType +
     a Windows font-directory scanner (`C:\Windows\Fonts` + per-user), the
     Windows default per `src/font/backend.zig`.
   - This fork additionally ships `ghoztty-agent.exe` for Windows (ConPTY,
     tray UI, Win32 message loop) — the toolchain path is proven.
2. **Verified locally (M0):** `zig build -Dtarget=x86_64-windows-gnu
   -Dapp-runtime=none` cross-compiles cleanly from this Mac
   (zig 0.15.2 Homebrew bottle).
3. **What's missing is exactly one layer:** an apprt runtime for Windows —
   window, WGL/OpenGL context, input translation, clipboard.
4. **Upstream direction** (ghostty-org/ghostty discussion #2563): native
   Win32 frontend (no GTK/Qt port), D3D renderer eventually; OpenGL-over-WGL
   is how every functioning community port ships today.
5. **Reference implementation:** [InsipidPoint/ghostty-windows]
   (https://github.com/InsipidPoint/ghostty-windows) (MIT, same license as
   upstream) adds `src/apprt/win32/` (~10k lines: App/Window/Surface/
   Scrollbar/QuickTerminal/win32 bindings), OpenGL 4.x over WGL reusing the
   shared renderer, ConPTY, tabs/splits, and cross-compiles with
   `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`. Its win32
   hunks in *shared* files are small (runtime enum, apprt dispatch, OpenGL
   context arms, build wiring); the large diffs vs our tree are unrelated
   upstream drift (their base is ~July upstream, ours ~April + fork features).

## Strategy decision

**Adopt the win32-apprt approach; vendor and adapt the MIT-licensed
`src/apprt/win32/` runtime from InsipidPoint/ghostty-windows** (with license
attribution in file headers) rather than writing a new runtime or embedding
libghostty:

- (a) *win32 apprt* — reuses our entire core (App/Surface/termio/renderer/
  config/input) unchanged; the only new platform code is presentation-layer.
  Upstream-blessed shape. **Chosen.**
- (b) *standalone exe on src/terminal + ConPTY* — fastest demo, but discards
  Surface/App/config/keybindings and diverges permanently. Rejected.
- (c) *libghostty + separate frontend* — the embedded runtime's surface
  bring-up is Darwin-only (objc/Metal); strictly more work. Rejected.

Vendoring vs rewriting: the vendored runtime is proven against real Windows
(v1.2.0 released 2026-07-02), MIT-licensed, and structured exactly the way
upstream wants. Adapting it to our fork (older upstream base + our custom
apprt actions like `set_state`/`send_keys`/`rearrange`) is compiler-driven
work; writing 10k lines fresh is strictly slower and riskier.

## Naming / identity

- App name: **Ghoztty** (never "Ghostty for Windows" — upstream forbids that
  branding for unofficial builds, and this fork is Ghoztty anyway).
- Namespace: `com.dzearing.ghoztty.*` (hard rule; never `com.mitchellh.*`).
- Exe: `ghoztty.exe`. Installer: `Ghoztty-<version>-x64.msi`.

## Milestones

- **M0 — recon + baseline** ✅
  Cross-compile of core with `-Dapp-runtime=none` for `x86_64-windows-gnu`
  verified on this Mac. Recon complete (this doc).
- **M1 — win32 apprt compiles: exe skeleton** ✅ (commit `e0118f682`)
  Vendored `src/apprt/win32/` (~10.2k lines, 6 files), rebranded to Ghoztty,
  auto-update check disabled. Wiring: `.win32` runtime enum member (default
  for Windows targets), apprt dispatch, 11 `app_runtime` switch sites,
  OpenGL.zig WGL arms, SharedDeps win32 system libs, GhosttyExe subsystem
  logic, `-Dwindows-console` option, win32_input mode 9001 + core encoder
  gate, `.rc` version resources + UTF-8/PerMonitorV2/long-path manifest.
  Fork adaptations: Windows `Exit` union gained `Signal`/`Stopped`/`Unknown`
  + `init()`; win32 Surface `remoteBackend()` stub; win32 App arms for
  `swap_split`/`toggle_hero_mode`/`activity_state` (report unimplemented);
  `+list`/`+read`/`+rearrange`/`+new-remote-window` CLI guarded off on
  Windows (Unix-socket IPC). Total: 5 targeted fixes after vendoring —
  the vendored runtime compiled against our core almost cleanly.
  `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu` emits
  `ghoztty.exe` (PE32+ console, Debug).
- **M2 — release build** ✅
  ReleaseFast build → 27MB PE32+ **GUI**-subsystem exe. Added
  `%LOCALAPPDATA%\ghoztty\ghoztty.log` file logging for release builds
  (GUI subsystem has no stderr; without it a beta crash is silent).
- **M3 — input/ConPTY/rendering** ✅ (via the vendored runtime)
  Keyboard (incl. Win32 Input Mode 9001), mouse, clipboard, WGL/OpenGL
  rendering, ConPTY shell (`cmd.exe` default) all come from the proven
  vendored runtime + upstream's Windows-branched termio. Compile-verified
  only on this Mac — interactive behavior needs the on-box checklist below.
- **M4 — installer** ✅ (`dist/windows-installer/build-msi.sh`)
  Per-user MSI via wixl (GNOME msitools), modeled on the agent MSI:
  `%LOCALAPPDATA%\Programs\Ghoztty\`, Start Menu shortcut, Apps & Features
  entry with build stamp, taskkill custom action, permanent UpgradeCode
  `5EB02044-7F06-498B-B7A9-7EFD65486CFB`, ProductVersion `yy.m.dNN` so
  newer builds always major-upgrade older ones. Packages the exe + `share/`
  tree (terminfo sentinel for `resourcesDir()`, 503 themes,
  shell-integration) as 527 components with deterministic uuid5 GUIDs.
  Layout verified by `msiextract`. Upgrade path: install newer MSI
  (auto-removes old); future: winget manifest and/or in-app updater.
  **Staged: `Ghoztty-26.7.501-x64.msi` on `/Volumes/share/ghoztty-windows/`**
  (sha256 verified after copy). The agent files in that folder
  (`ghoztty-agent.exe`, watcher, logs) are the live remote-agent deployment,
  not stale builds — left in place.
- **M5 — regression + docs** ✅
  Native macOS `zig build -Doptimize=Debug` still green after all changes.
  All Windows-specific code is comptime-gated (`builtin.os.tag == .windows`
  / `.win32` runtime arms), so other platforms are structurally unaffected.

## Cut lines (explicitly out of scope for the beta)

- **No D3D renderer** — OpenGL over WGL (requires functional GL drivers;
  fine for beta on real hardware).
- **No IPC/CLI window management on Windows** (`+new-window`, `+split`, …):
  the IPC server is the macOS app; Windows apprt stubs `performIpc`.
- **No remote-machines integration in the Windows GUI** (the agent already
  covers Windows remoting; the Windows GUI is a plain local terminal).
- **No code signing** — beta installs will show SmartScreen warnings; the
  README/checklist tells the user to expect that.
- **No auto-updater** — upgrades are "install newer MSI".
- Quick-terminal, accessibility, IME/CJK, ligature edge cases: whatever the
  vendored runtime provides is what ships; not hardened in this pass.
- arm64 Windows: out (box is x86_64; target is `x86_64-windows-gnu` only).

## Risks / unknowns

- Vendored runtime assumes newer upstream APIs in places (e.g. font
  `RenderOptions` moved out of `face.zig` upstream) — resolved during M1
  compile loop, taking our tree's API as truth.
- Our fork's extra apprt actions must gain arms in the win32 App's
  `performAction` switch (Zig exhaustive switches make these loud).
- GL driver quality on the test box unknown; if the window is black,
  fallback plan is `-Dwindows-console=true` debug build + GL error logging.
- `zig build` from macOS with `.rc` resources: zig's bundled resinator
  handles cross-compiling resources; verified during M1.

## Manual verification checklist (Windows box)

Artifact: `\\share\ghoztty-windows\Ghoztty-26.7.501-x64.msi`
(sha256 `598abb0d2e183f9f7fefce81bd82d297fe95fc0c86abc37a4aaf7a8e10387e1a`)

1. Double-click the MSI. Expect **no elevation prompt** (per-user install)
   and possibly a SmartScreen warning (unsigned beta — "More info → Run
   anyway"). Installs to `%LOCALAPPDATA%\Programs\Ghoztty\`.
2. Start Menu → "Ghoztty" → window opens with a `cmd.exe` prompt rendering
   in JetBrains Mono.
3. Type commands; verify echo, colors (`dir`, `type` a file), Enter/Backspace/
   arrows/Tab behave. Try `powershell` inside it.
4. Resize the window (grid reflows), mouse-wheel scrollback, select text +
   Ctrl+Shift+C / Ctrl+Shift+V round-trip.
5. Tabs/splits: Ctrl+Shift+T (new tab), Ctrl+Shift+O / Ctrl+Shift+E (splits).
6. `exit` closes the pane/tab/window cleanly; last window quits the app.
7. Re-run the MSI → repair/no-op without errors. Apps & Features shows
   "Ghoztty" with build stamp in Comments; uninstall removes Start Menu
   entry and install dir.
8. If anything crashes or the window is black: check
   `%LOCALAPPDATA%\ghoztty\ghoztty.log` and report its tail. A black window
   most likely means WGL/driver issues — rebuild with
   `-Dwindows-console=true` for a console-visible release build, or use a
   Debug build (always Console) for stderr.

## Install-failure postmortem (2026-07-05, build 26.7.501)

First staged MSI failed on the box: a console window flashed and nothing
installed (no Start Menu entry). Diagnosed from MSI forensics (`msidump`),
since the box could not be reached live (SSH port closed, agent TCP port
listen-hardened, relay GUI dial hung).

**Two defects, both from deriving MSI identifiers from the full install
path** in `build-msi.sh`:
1. **s72 overflow (fatal).** `share/ghostty/shell-integration/fish/
   vendor_conf.d/ghostty-shell-integration.fish` produced an 83-char
   Component/File identifier; MSI limits those key columns to `s72`
   (72 chars). Windows Installer rejects the package at validation and
   silently rolls back a per-user install → nothing lands.
2. **Identifier collisions.** Non-alphanumerics were mapped to `_`, so
   `conf.d` and a hypothetical `conf_d` collapsed to the same id — merging
   distinct directories/files. The old MSI shipped only 527 of 561 files.

The blank console window was the `taskkill` custom action (type-50 EXE)
running before validation aborted.

**Fix:** identifiers are now `c`/`f`/`d` + a 20-hex SHA-1 of the install
path — always ≤21 chars, collision-free, stable across builds (GUIDs still
`uuid5(path)`). Verified post-fix: every key column ≤24 chars, 561/561
files present, tree extracts faithfully. Also **dropped the taskkill custom
action** for the beta (source of the alarming console flash; a fresh install
never needs it — document "close Ghoztty before upgrading" instead).

Re-staged as **`Ghoztty-26.7.502-x64.msi`** plus `INSTALL-ghoztty.cmd`
(runs msiexec with `/l*v` verbose logging to `ghoztty-install.log` on the
share). If it still fails, that log is the ground truth to read next.
**Not yet reproduced as a successful install on the box** — the fix is
forensically confirmed but awaits the next on-box run.

## Decision log

- 2026-07-05: Chose win32-apprt vendoring (see Strategy). Chose wixl MSI
  (existing in-repo pipeline, tooling already installed) over NSIS/Inno
  (extra toolchain) and zip (no Apps & Features/upgrade story).
- 2026-07-05: Renderer = OpenGL/WGL (only option the shared core supports on
  Windows today); font = `.freetype_windows` (in-tree default for Windows).
- 2026-07-05: Default shell on Windows = existing core behavior (`cmd.exe`,
  per `termio/Exec.zig`); revisit pwsh detection post-beta.
