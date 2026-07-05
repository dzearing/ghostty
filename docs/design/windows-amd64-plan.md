# Ghoztty on Windows amd64 — port plan

Status: **in progress** (this doc is updated as milestones land)
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
- **M1 — win32 apprt compiles: exe skeleton**
  Vendor `src/apprt/win32/` + `dist/windows` resources (rebrand to Ghoztty),
  add `.win32` to `src/apprt/runtime.zig` + `src/apprt.zig`, build wiring
  (SharedDeps win32 libs, GhosttyExe subsystem + .rc), OpenGL.zig WGL arms,
  small shared hunks (action/structs/surface/os.windows/Binding/mouse/modes/
  face). Adapt to our fork's apprt action set. Exit: `zig build
  -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu` emits `ghoztty.exe`.
- **M2 — smoke artifact on the share**
  Debug-console build staged to `/Volumes/share/ghoztty-windows/` for a first
  manual launch check (window + shell + typing). Iterate on crash reports from
  the box if needed.
- **M3 — beta hardening**
  Windows console subsystem off for release, icon/version resources, config
  paths (%APPDATA%), default shell decision (cmd.exe default; pwsh if
  detected), clipboard, resize, scrollback sanity. Cut lines below apply.
- **M4 — installer**
  Per-user **MSI built with wixl (GNOME msitools)** — the repo already has a
  proven macOS-built MSI pipeline for the agent
  (`relay/deploy/msi/build-msi.sh` + `.wxs`); model
  `dist/windows-installer/ghoztty.wxs` on it: per-user (no elevation),
  Start Menu shortcut, Apps & Features entry, stable UpgradeCode so newer
  ProductVersions auto-upgrade (`yy.m.dNN` scheme). Upgrade path: same MSI
  major-upgrade mechanism; future: winget manifest and/or in-app updater.
  Fallback if MSI hits a wall: zip + README.
  Exit: exactly ONE artifact on the share, stale builds deleted.
- **M5 — regression + docs**
  Native macOS `zig build -Doptimize=Debug` still green. This doc updated
  with outcomes, cut lines, manual-verification checklist. Incremental
  commits throughout (already the practice).

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

Filled in at M4 staging time; expected items:
1. MSI installs per-user without elevation; Ghoztty appears in Start Menu.
2. Launch → window opens, shell prompt renders, typing works.
3. Resize, scrollback (wheel), copy/paste round-trip.
4. `exit` closes the surface/window cleanly.
5. Uninstall from Apps & Features removes it.

## Decision log

- 2026-07-05: Chose win32-apprt vendoring (see Strategy). Chose wixl MSI
  (existing in-repo pipeline, tooling already installed) over NSIS/Inno
  (extra toolchain) and zip (no Apps & Features/upgrade story).
- 2026-07-05: Renderer = OpenGL/WGL (only option the shared core supports on
  Windows today); font = `.freetype_windows` (in-tree default for Windows).
- 2026-07-05: Default shell on Windows = existing core behavior (`cmd.exe`,
  per `termio/Exec.zig`); revisit pwsh detection post-beta.
