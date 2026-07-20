# Windows parity — session log

History only. **Do not read this file as part of normal resume** —
`windows-parity-tasks.md` (state table + task sections) is the hot doc.
Open a single entry here only when you need the backstory for a specific
task (why a decision was made, what a past validation actually proved).


Append newest-first: `YYYY-MM-DD — <tasks touched> — <what happened, what's
next, any surprises>`.

- 2026-07-20 (on-box, 35) — T89d SPLIT + T89d1 DONE. T89d ("open under the
  local agent") was too big for one context (new LocalAgent find-or-spawn +
  App/Surface wiring + a ~250-line session-open.ps1 + several slow Windows
  builds), so I carved out the folded-in T89c note — the mode-independent
  single-instance guard — as **T89d1** and did it while single_instance.zig
  was already loaded. Fix: a `single_instance.Instance` key threaded through
  acquire/takeover/heartbeat/lock-path; `--listen-pipe` (THE Windows local
  persistence agent) now takes a distinct `local[-debug]` guard (mutex
  `Global\GhozttyAgentDaemon-local[-debug]-<sid>` + `agent-local[-debug]`
  lock/heartbeat) so it coexists with a legacy-keyed `--relay` agent;
  `.listen`/`.listen-unix`/`.relay` unchanged (empty key = byte-identical
  legacy names — zero risk to a shipped relay agent). `is_debug` added to
  agent_build_options. Pure composers unit-tested. **Surprise:** `zig build
  test-agent` is red on the box — but from 4 pre-existing upstream
  `ssh-cache.DiskCache` renameatW/AtomicFile failures (proven identical on the
  git-stashed baseline; came in via the T88 merge). Filed **T97** — a
  validation-bar blocker that gates test-agent for every future task (both app
  lanes are green; my change touches only agent+build files). Flagged to the
  Mac seat: the POSIX `--listen-unix` vs `--relay` flock collision is the same
  latent bug, left unkeyed here. Next on-box: T89d (find-or-spawn + wiring),
  then T97 to restore the agent floor.
- 2026-07-20 (on-box, 34) — T89c DONE: agent `--listen-pipe` + `+sessions`
  pipe dial. New `pipe_stream.zig` (overlapped named-pipe PipeStream/
  PipeListener/dialHandle; owner-only DACL = the peercred-gate analog;
  CancelIoEx-on-close so a blocked read unblocks — dodges the T89b
  synchronous-CloseHandle deadlock). Agent grew the `--listen-pipe`
  daemon (2c beside --listen-unix) + a console-ctrl graceful-stop
  snapshot; port.json gained the additive `pipe` field; `tcp_dial.dialPipe`
  + `cli/sessions.zig` dial it (LOCALAPPDATA state dir). Surprise 1: the
  GUI-subsystem agent exe only links native-gnu, not native-msvc
  (undefined WinMain — the T36 log note), and the RTC/wp4-e2e harnesses
  NEVER built on Windows (rooted at src/remote/, but socket_stream→
  agent/server→…→../../terminal escapes that module path). Fixed the RTC
  by re-rooting at src/ via a shim + shared deps (mirrors the agent), then
  added `--pipe`/`--hold`/`--close-session` for a real scratch client.
  Surprise 2: `close_session` RPC times out ~10s over BOTH pipe and TCP —
  the agent unlinks the session then hangs in the production `Pty.deinit`
  tearing down the ConPTY (T89b fixed only the TEST teardown) → RESULT
  never sent. Session IS removed; only one serving thread wedges. Filed
  T96. Also noted: the per-user single-instance mutex is mode-independent,
  so local-pipe + relay agents can't coexist yet → folded into T89d.
  `agent-pipe.ps1` ALL PASS (25) ×3; both lanes + test-agent ×3 + P1–P3
  green. Next: T89d.
- 2026-07-19 (on-box, 33) — T89b DONE: `zig build test-agent` green ×3
  (first time ever on Windows), added to the standing validation set.
  Five root causes: harness loopback servers read via std Stream.read =
  ReadFile-on-overlapped-socket → err 87 (→ new socket_rw.readStream/
  writeAllStream); the SAME bug in production http_client (http AND
  under-TLS reads — agent enroll/self-update never worked natively on
  Windows); a PtyChild terminate deadlock (Pty.deinit closes out_pipe
  before ClosePseudoConsole; CloseHandle blocks on the reader's in-
  flight sync ReadFile → new two-phase closeConsole/deinitAfterReader,
  GUI deinit untouched); pty tests had a defer-order sink UAF (= T82's
  "segfault"), POSIX-only commands (per-OS cmd.exe variants now), and
  100µs spin waits that are 15.6ms ticks on Windows (~8 min per miss →
  wall-clock deadlines); link_control test raced display()'s desired-
  based .offline vs the loop's stale `connected` + leaked its runLoop
  thread on failure. Surprise: two early bg runs died on the
  ZIG_GLOBAL_CACHE_DIR cross-drive assert — env var required in every
  shell. Lanes + GUI + P1–P3 green. T82 closed. Next: T89c.
- 2026-07-19 (on-box, 32) — T90a DONE: viewer-panes Windows design via 3
  parallel surveys (Mac viewer impl, win32 structure, WebView2 external
  research). Pinned: loader-less WebView2 (registry probe +
  EmbeddedBrowserWebView.dll internal export, error-card degrade — no
  binary vendored), PaneView `{terminal,viewer}` retype (cheaper than
  Mac's: win32 split ops are already pure Zig, no per-action bypass),
  WebResourceRequested 3-tier resolver for the already-shipped viewer
  assets, Mac-parity IPC error strings + additive list `type`/`url`
  (CLI renderer already done), interim explicit `--view` error (today it
  silently opens a terminal), v1 gaps pinned (FFM + T94 band over
  Chromium children, hero excludes viewers). Found a CLI bug for T90b:
  resolveViewArgument's absolute check is POSIX-only. T90 split →
  T90b–T90h; T89f must reserve manifest `kind`/`viewer_location`.
  Doc-only, no code. Next: T89b.
- 2026-07-19 (on-box, 31) — T89a DONE: session-persistence Windows design
  via 3 parallel scouts (Mac design doc, agent core, win32 app). Big
  finding: the agent already owns ConPTYs cross-platform (pty_child.zig
  via shared CommandCore) and the win32 `.remote` backend already has the
  session_id ATTACH path (hardcoded null today) — the port is local
  wiring: `--listen-pipe` transport, LocalAgent find-or-spawn, close-vs-
  quit CLOSE semantics, and a viewer-side layout manifest (the largest
  new piece). T89 split → T89b–T89i (T82 folds into T89b); doc-only, no
  code. T95 probe at session start: still wedged (SendInput swallowed,
  rel+abs moves all no-op, session unelevated) — row moved to blocked;
  needs elevated GameInputSvc restart or reboot. Next: T90a.
- 2026-07-19 (on-box, 30) — T93 DONE: relay sign-in ported to the Mac's
  brokered (BFF) OAuth. New relay_session.zig (exchange/renew/signout wire
  client), account.dat now stores the relay session token + expiry +
  relay_base (no Google token/client secret on the machine), GUI account
  tier renews + persists rotation, `--client-secret` removed, client id
  bakeable via -Dgoogle-client-id → build_config, logout revokes at the
  relay. Legacy stores force one clear re-login (brokered relay rejects
  raw Google ID tokens anyway). ipc-relay-login.ps1 rewritten (31 asserts,
  incl. renew-rotation + legacy + live account-tier E2E) ALL PASS ×3;
  P1–P3 + both lanes + GUI build green. T95 probe at session start: box
  still wedged (fg=GameInputServiceWindow, SendInput dead); an old
  watcher saw it clear at 21:34 — it flaps, re-probe next session.
- 2026-07-19 (on-box, 29) — T86 DONE: GrabForeground (already-fg guard +
  attach-to-fg-thread + Alt tap, retried) in all 20 remaining kb-injection
  scripts + guard retrofitted to hero-mode/window-title/split-divider.
  Surprise 1: the unguarded Alt tap self-latches menu mode when the target
  is already fg — broke chooser-Escape/About-box/copy until guarded.
  Surprise 2: keybinds-t01's copy assert fails since T85 (tall windows put
  the center click below the X block) — fixed w/ row-probe loop, filed
  T95 for its ×3. Surprise 3 (box, not code): GameInputSvc wedged the
  input stack mid-session (unbeatable fg lock + SendInput swallowed);
  unelevated fix impossible — needs elevated `Restart-Service
  GameInputSvc`. 19/20 scripts validated ALL PASS vs live foreign fg.
  Next: T95 (if box recovered) → T93.
- 2026-07-19 (on-box, 28) — T94 DONE: divider grab band ±3→±4.5 DIP (~9
  DIP, Mac parity) — real fix was WM_NCHITTEST/HTTRANSPARENT fall-through
  on surface children (pane HWNDs clipped the old band to the ~5 DIP
  gap). split-divider.ps1 +6 asserts (SIZENS across band, ±4 DIP
  real-input drags) ALL PASS (15) ×3; P1–P3 + both lanes green. Its
  foreground grab hardened to the T86 pattern en route (plain grab
  ABORTed with a browser focused — 1 of the ~20 scripts done). Next: T86.

- 2026-07-19 (on-box, 27) — T92 DONE: three-level title model (window pin
  → tab pin → pane title, Mac parity). Surface user pane title w/
  remembered-terminal-title restore; per-tab pin (inline rename now pins,
  empty clears); RenameDialog generalized to 3 levels w/ Mac captions;
  .prompt_title branches on payload; +rename --title="" clears; palette
  gains the 3 "Change … Title" entries. New window-title.ps1 ALL PASS
  (46) ×3; P1–P3 + hero-mode (60) + both lanes green. Surprise:
  kb-actions.ps1 skipped itself entirely (un-hardened foreground grab,
  0 assertions) — more weight behind T86. Next: T94.

- 2026-07-19 (on-box, 26) — T91 DONE: banner markdown parity with the Mac.
  banner_markdown.zig rewritten to the Mac's block model (headings, rules,
  marker-gutter lists, GFM+headerless tables, native checkboxes, 10-line
  cap, pure wrapTokens); BannerOverlay.zig rewritten as one measure/draw
  walker (bold-width capped columns w/ cell wrap, green RoundRect
  checkboxes, chevron collapse + AlphaBlend fade, 12dip padding).
  pane-banner.ps1 30→37 asserts ALL PASS ×3; both lanes + P1–P3 green.
  Next: T92 (window-level titles).

- 2026-07-19 (on-box, 25) — T88 DONE: merged origin/main 8bb5d9845 (154
  commits — session persistence, viewer panes, banner markdown upgrades,
  brokered OAuth, window-level titles) as 74322cf05; 3 trivial conflicts.
  Post-merge fixes (362d1d4bc): .powershell arm in the new
  shell-integration switch, u128 atomic → mutex in connection.zig's test
  agent, Hello.encode null-elision (that test is RED ON MAIN — flag for
  the Mac seat via T87). Both lanes + Debug GUI + P1–P3 ALL PASS. Parity
  gaps filed: T89a/T89 (session persistence port), T90a/T90 (viewer
  panes port), T91 (banner markdown), T92 (window-level titles), T93
  (brokered OAuth), T94 (divider hit target). Surprise: ctrl+shift+r was
  rebound upstream to prompt_window_title, but win32 ignores the
  PromptTitle payload so the T50 dialog still opens — no regression.
  Next: T91.
- 2026-07-19 (on-box, 24) — T35 DONE (sticky pane banner, full Mac
  parity per-pane): pure banner_markdown.zig (14 tests) + BannerOverlay
  layered strip (clickable links) + BannerDialog editor (ctrl+shift+b,
  Ctrl+Enter saves) + IPC `set-banner` + additive `+list` banner field;
  pane-banner.ps1 ALL PASS (30) ×3, P1–P3 + both lanes green.
  Surprises (harness, not product): point-sampling the 39px strip needs
  a DPI-aware probe process, CopyFromScreen-with-topmost-window (raw
  GetPixel skips layered windows), and GetDC on an SLWA window knocks it
  out of the DWM composite until repaint. Filed T88 (user directive):
  rebase on latest main, analyze all incoming changes, file parity
  tasks. Next: T88, then T86.
- 2026-07-19 (on-box, 23) — T25 DONE (the spec §8 conformance gate). New
  `test/win32/conformance.ps1`: items 1–7 E2E from cold, CLAUDE.md
  three-pane example with git-bash vim/tail + powershell, ALL PASS ×3;
  hero-mode.ps1 (60) + fake-relay E2E + T17 skill evidence cover 8–10;
  P1–P3 + both lanes green at HEAD; spec §9 table finally filled in.
  Surprises: msys `tail -f`'s handle denies PowerShell `Add-Content` (use
  `cmd >>`); a foregrounded browser silently vetoes `SetForegroundWindow`
  from the harness — fixed in hero-mode.ps1 (attach-to-fg-thread + Alt
  tap); the same weakness in ~20 other scripts is filed as new T86. T87 filed for the Mac-seat
  tail (regression build + merge to main). Next on-box: T35 or T86.

- 2026-07-19 (on-box, 22) — T85 DONE (67b0f24a5). New windows now
  remember the last user-chosen size: placement memory (outer size +
  maximized) written only on interactive resize (WM_EXITSIZEMOVE) and
  max/restore transitions; creation precedence config > memory
  (work-area-clamped) > 800×600; `maximize` config newly honored on
  win32; reset_window_size untouched-by-design (escape hatch). Debug
  builds use a `-debug` file so tests never pollute the release memory.
  Surprise: SendInput chord harnesses ABORT while the user holds
  foreground — rewrote reset-window-size.ps1 (and built the new
  window-size-memory.ps1) on focus-free PostMessage'd bare-F-key
  bindings; validated the approach with an IsZoomed positive control.
  DELIVERED (user-complaint fix): ReleaseFast gnu `-Dstrip=false` staged
  to zig-out-release (`+14468054b`); Desktop portable + share refreshed
  (exe+pdb, share\ mirrored, `.bak-20260719`); installed release swapped
  via the detached upgrade script (resume = the go.md loop, doubling as
  the context reset). Pre-swap windows run old code until relaunched.
  Next: priority queue empty again — first todo in table.
- 2026-07-19 (on-box, 21) — T24 DONE. Windows release channel is live:
  win-vX.Y.Z GitHub releases beside the Mac ones (--latest=false; first
  release win-v1.4.1 with the T23-fixed MSI, exe stamped 1.4.1+hash via
  `build-msi.sh --semver`). In-app check enabled but gated to
  -Dwindows-update-check channel builds (dev/portable/T36 builds never
  nag — the daily driver runs ahead of the channel), notify-only (no
  taskkill in the MSI → no auto-install), balloon → release page; manual
  check gets up-to-date/failed balloons. Pure scan/compare in
  update_check.zig; GHOZTTY_UPDATE_URL (+file://) test hook;
  `publish-windows-release.ps1` for future releases. update-check.ps1
  ALL PASS (12) ×3; P1–P3, ipc-version, both lanes green. Provenance
  gained `update_check` everywhere. Surprise: WinINet rejects file://
  (read directly); PS5.1 NativeCommandError on gh/docker stderr probes.
  Mid-task the user flagged tiny new windows → filed T85 (window-size
  memory), marked next.
- 2026-07-19 (on-box, 20) — T23 DONE. The 26.7.502 vanishing-exe root
  cause was wixl leaving File.Version EMPTY (packaged exe read as
  UNVERSIONED → costing skips the copy, early RExP deletes the old one);
  RExP placement was never the bug. Fix set (build pipeline only):
  per-build FILEVERSION `-Dwindows-file-version` → rc /d defines, PE
  version mirrored into the File table post-compile, MsiFileHash
  emptied (hash-skips = deletions for unchanged share files), wixl -a
  x64 (was an x86 package registering under WOW6432Node), and a
  `--test-identity` throwaway-product mode for safe on-box E2E. New
  `test/win32/msi-upgrade.ps1` ALL PASS (33) ×3: install → major
  upgrade (exe + all 526 files survive) → uninstall clean → ghost
  recovery. Surprise: the broken 26.7.502 product is still REGISTERED
  on the box; left in place deliberately (manual /x would delete live
  files) — the first real fixed-MSI install majors over it, which is
  exactly the validated ghost scenario. Next: T24 blocks on this.

- 2026-07-19 (on-box, 19) — T84 DONE. Root cause: inherited ignore-^C
  flag (CREATE_NEW_PROCESS_GROUP up the launcher chain), NOT
  ConPTY/conhost — the cooking worked all along. Probe ladder
  (conpty_smoke `--ctrlc*`): ghoztty Pty, anon-pipe ConPTY, classic
  conhost --headless, and WT OpenConsole ALL failed identically;
  `--report-ctrlc` handler-observer proved the event was never
  delivered; GenerateConsoleCtrlEvent failed too (visible + hidden
  consoles) — which pointed away from cooking to delivery; clearing
  the flag in the spawner flipped everything green. Fix: clear the
  flag at App.init. `+send-keys C-c` now stops `ping -t`;
  keybinds-t01.ps1 ALL PASS 23/23 (SIGINT assert green). Surprise
  worth remembering: automation-spawned interrupt tests false-negative
  unless they clear the flag first — the T84 "bug" was 90% this trap,
  but the fix is real (auto-launched GUIs from flagged chains had ^C
  dead in every pane).

- 2026-07-18 (on-box, 18) — T01 DONE (+T83 found+fixed, T84 filed).
  Built a real chord-injection acceptance for the ctrl-mirror keybinds
  (`keybinds-t01.ps1`: kb-actions mechanics + mouse double-click
  word-select + typing/focus positive controls; 23 assertions). Verified
  on HEAD Debug: ctrl+t/d/shift+d/w/f4/shift+p/n, ctrl+1/2/9, copy with
  selection, paste. Bug 1 (T83, fixed): win32 `selectTab` treated the
  1-indexed goto_tab payload as 0-based — ctrl+1 went to tab 2, ctrl+2
  no-oped; now Mac-parity incl. out-of-range→last. Bug 2 (T84, todo,
  jumps the queue): ^C never interrupts a running ConPTY child — repros
  with `+send-keys C-c` vs `ping -t`, so NOT a keybind bug; binding
  fallthrough verified correct, no CREATE_NEW_PROCESS_GROUP, ConPTY
  flags=0; next step is a standalone conpty probe. Script is 22/23 (the
  SIGINT assert is T84's regression oracle). Both lanes + P1–P3 green.

- 2026-07-18 (on-box, 17) — T78 DONE. `window-title-font-family` now
  drives the owner-drawn tab bar font (and the resize overlay, which
  shares the HFONT). Scoping call: the DWM caption font of a
  standard-frame window is not app-controllable (Windows convention —
  full parity would need a custom-draw titlebar), so the config applies
  to the surfaces the app draws titles on; the audit's "design-level
  backlog" tag only holds for the caption text itself. Face resolution
  is pure title_font.zig (fallback/UTF-16/LF_FACESIZE truncation, unit
  tests both lanes); config reload recreates the font live and re-pushes
  WM_SETFONT so the overlay never holds a deleted HFONT. title-font.ps1
  ALL PASS (9) ×3 — per-column raster signature: font change diff 430,
  same-font diff exactly 0 (owner-drawn mem-DC rendering is fully
  deterministic), live-reload path verified. P1–P3 + both lanes green.
  The 2026-07-15 priority queue is now EXHAUSTED — next session falls
  back to first-todo-in-table.

- 2026-07-18 (on-box, 16) — T72 DONE. Tab accent colors (Mac
  TerminalTabColor parity): "Tab Color" submenu in the tab context menu
  (10 colors, anti-aliased DIB swatches via new pure tab_color.zig,
  checkmark on current) + a top accent stripe in the owner-drawn tab
  paint; per-tab color rides addTab/close/moveTab/drag shuffles.
  Adjacent fix: moveTab never swapped the hero-state arrays (latent
  since T59a) — now it does. tab-color.ps1 ALL PASS (11) ×3; P1–P3,
  hero-mode (60), both lanes green. SURPRISE: SendInput arrow-key nav
  inside a TrackPopupMenuEx modal loop is unreliable (End/Right
  silently dropped while Down worked); menu first-letter matching
  ('T', then 'R'/'N') is the robust way to script menus. Next: T78.

- 2026-07-18 (on-box, 15) — T66 DONE. `reset_window_size` now returns to
  the stored `initial_size` (window-width/height × cell size; 800×600
  only when unset) via new `Window.setClientSize` +
  `default_client_size`; `initial_size` re-sends are store-only (Mac/GTK
  parity — a font zoom no longer live-resizes the window, but reset
  tracks the recomputed default). Palette gained "Reset Window Size".
  reset-window-size.ps1 ALL PASS (10) ×3; P1–P3 + both lanes green.
  SURPRISE: ctrl+alt+m is a system-global hotkey on this box (another
  app's RegisterHotKey — keydown never reaches any ghoztty queue;
  proven by message-loop tracing), so the script uses ctrl+alt+j/f9.
  Next: T72 (tab accent colors).

- 2026-07-18 (on-box, 14) — T71 DONE. Claude Code integration setup at
  Mac parity: `ClaudeIntegration.zig` (detect claude → one-time
  first-run offer via ConfirmDialog, canonical-install-gated; answer
  file remembers declining) + "Install Claude Code Integration"
  palette entry; both run marketplace-add + plugin-install on a
  background thread, outcomes via WM_APP → Mac-parity dialogs. Pure
  logic in `claude_setup.zig` (both lanes). claude-integration.ps1
  ALL PASS (26) ×3 with a stub claude.cmd; P1–P3 green. No surprises.
  Next: T66 (reset_window_size parity).

- 2026-07-18 (on-box, 13) — T70 DONE. `ghoztty` now self-installs on the
  user PATH: new `PathInstaller.zig` (background thread at App.init,
  gated to %LOCALAPPDATA%\Programs\Ghoztty; `GHOZTTY_PATH_SELFHEAL`
  0/off/force knob) + pure `path_env.zig` (normalize/contains/append,
  unit-tested both lanes); detects existing entries in any spelling
  (case, quotes, trailing `\`, unexpanded %VAR%). MSI now writes a user
  PATH Environment entry too. path-selfheal.ps1 ALL PASS (13) ×3; MSI
  install/uninstall E2E-verified on-box via a throwaway
  GhozttyPathTest MSI (msitools in Docker). SURPRISE: wixl ignores
  Environment/@Permanent="no" (emits `=PATH`, entry survives
  uninstall) — build-msi.sh now patches the table to `=-PATH`
  post-compile (verified: uninstall removes the entry). Also made
  build-msi.sh sed portable (BSD `-i ''` → redirect+mv) so it runs on
  Linux/Docker as well as Mac. Next: T71.

- 2026-07-18 (on-box, 12) — T67 DONE (5bf9a65d6). Background tint at
  Mac parity: `--color`/`--split-color`/`random` set terminal bg +
  contrast fg + WCAG-4.5-adjusted ANSI palette (pure `color_math.zig`,
  unit-tested both lanes); plain splits now inherit the parent pane's
  bg shifted 5% (visible depth, Mac newSplit behavior); context-menu
  "Background Color…" opens ChooseColorW (comdlg32 newly linked);
  `+list` panes gained additive `background_tint`. window-color.ps1
  ALL PASS (14) ×3 incl. a pixel probe and menu→dialog automation
  (`B` mnemonic executes the item). SURPRISES: the shared CLI already
  validates `--color` (invalid hex exits nonzero, never reaches the
  server — test expects rejection, not silent ignore); the shipping
  Mac shift is 0.05, not window-color.md's 0.15 example. Next: T70.

- 2026-07-18 (on-box, 11) — T81 DONE. The "GUI unresponsive after
  agent death" was a process-killing PANIC: ws teardown sent the WS
  close frame AFTER `shutdown(.both)`; Windows returns `WSAESHUTDOWN`,
  which std's socket writer maps to `unreachable`. Fixed with new
  `socket_rw.zig` (panic-free socket send/recv + Io.Reader/Writer,
  shared with SocketStream; ws_client now uses it) and by dropping the
  undeliverable post-shutdown close frame. Bug 2: `Window.onDestroy`
  leaked `remote_dialed` on every `+close` (why clean closes never hit
  the panic) — now torn down like `deinit()`. ipc-relay.ps1 ALL PASS
  ×3 (was 3 FAILURES); P1–P3 + remote-inherit + both lanes green.
  SURPRISE: `zig build test-agent` was never green on Windows (5
  pre-existing integration failures, harness ReadFile-on-socket
  GetLastError(87); proven identical at baseline 52e1fd73b) → filed
  T82. Delivered aeb856ebe ReleaseFast (gnu, -Dstrip=false) to all 3
  install locations: Desktop portable + share extracted copy
  (rename-then-copy, dated .baks), share zip refreshed
  (jul12 .bak kept), share ghoztty-agent.exe refreshed (agent shares
  the ws fix; jul3 .bak kept), installed release via
  upgrade-ghoztty-windows.ps1 at this boundary. Next: T67.
- 2026-07-18 (on-box, 10) — T68 DONE (c8f1da16e). Remote inheritance:
  `--from-focused` on +new-window/+split; plain tabs/splits (ctrl+t/
  ctrl+d + IPC) in a remote window reuse the connection and inherit the
  parent pane's command + live cwd (GET_CWD, 1.5s bound); +split
  --target on a remote window is remote-native (was a local ConPTY
  pane); ctrl+n re-dials the recorded machine (Window.remote_machine),
  failure ⇒ T80 dialog. New `remote-inherit.ps1` ALL PASS ×3 (live-cwd
  oracle, ctrl+t chord, netstat second-connection assert). SURPRISE:
  ipc-relay.ps1 ==6/==7 (agent death under a live relay window) fails 3
  assertions — reproduced identically at pre-T68 a22134f44, so
  pre-existing → filed T81, queued FIRST (user-visible hang). P1–P3 +
  ipc-remote + both lanes green. Next: T81.
- 2026-07-18 (on-box, 9) — T69 DONE. Config-error UI: startup + hard
  reload_config now show parse diagnostics in a dark ConfirmDialog
  ("Open Config" opens the editor via the extracted openConfigFile
  helper; "Ignore" continues). ConfirmDialog gained custom button
  captions + measured button width (unit-tested buttonWidth). New
  `test/win32/config-errors.ps1` ALL PASS (10) ×3 (XDG_CONFIG_HOME
  isolation; rename-dialog chord as positive control); P1–P3 +
  confirm-dialogs (20) + both lanes green. Next per T51 order: T68.

- 2026-07-18 (on-box, 8) — T75 DONE. `focus-follows-mouse` honored:
  handleMouseMove now defers focus (T48 path) to the hovered unfocused
  pane, gated on real SCREEN-coord motion (app-level last-pos guard, the
  GTK "is_cursor_still" analog — a pane appearing under a stationary
  cursor can't steal focus) and on the pane's window being the ACTIVE
  window (no hover-raise, no stealing from palette/dialog popups). New
  `test/win32/focus-follows-mouse.ps1` ALL PASS (10) ×3 (real
  SetCursorPos glide B→A→B switches focus with no click; default-off run
  proves no switch + click control); P1–P3 + both lanes green. Next per
  T51 order: T69.

- 2026-07-18 (on-box, 7) — T76 DONE. `window-inherit-font-size` honored:
  win32 Surface init captures the focused surface's live font points
  pre-init, applies post-init via setFontSize (embedded.zig parity —
  reset_font_size still returns to the config default). New
  `test/win32/font-inherit.ps1` ALL PASS (21) ×3 (mode-con-columns
  oracle, split + new-window paths, both config values); P1–P3 + both
  lanes green. Next per T51 order: T75.

- 2026-07-18 (on-box, 6) — T73 DONE. `split-divider-color` honored:
  paintDividers computes the pen color from config (0x808080 fallback)
  and passes it down; onConfigChange repaints dividers (GetDC path) so
  reload re-colors live. New `test/win32/split-divider.ps1` ALL PASS
  (9) ×3 (red via config file, live reload → blue, gray fallback);
  P1–P3 + split-dim + both lanes green. Surprise: the harness needed
  PER_MONITOR_AWARE_V2 — virtualized GetPixel can't see a 1-2 px line
  on this DPI-scaled box. Next per T51 order: T76.

- 2026-07-18 (on-box, 5) — T74 DONE. `unfocused-split-opacity`/`-fill`
  now honored: new DimOverlay.zig — a Scrollbar-pattern WS_EX_LAYERED +
  WS_EX_TRANSPARENT popup per pane (lazy), filled with the fill color at
  (1-opacity)*255 alpha (Mac parity); pure decision/alpha logic in
  dim_math.zig (unit tests, both lanes). Window.updateDimOverlays drives
  it from layoutSplits (defer, all paths), WM_SETFOCUS, WM_MOVE, and
  config reload; hidden under zoom/hero/inactive tabs. New
  `test/win32/split-dim.ps1` ALL PASS (23) ×3 — alpha 77/128 read back
  via GetLayeredWindowAttributes, focus flip moves the overlay, zoom
  hides it, opacity=1 disables, and a screen-pixel blend check reads
  exactly r=128,0,0 for red fill @0.5 over black. P1–P3 + zoom-nav (16)
  + hero-mode (60) + both lanes green. Harness gotcha: PS 5.1 unrolls a
  1-element function return AND pscustomobject has no intrinsic .Count —
  wrap call sites in @(). Next per T51 order: T73.
- 2026-07-18 (on-box, 4) — T80 DONE. Dark message boxes: new
  `ConfirmDialog.zig` — a T50-pattern dark dialog with a *synchronous*
  API (owner disabled + own nested message pump, the MessageBoxW shape
  the T48 analysis blessed; WM_APP_SETFOCUS handling replicated) so all
  four MessageBoxW sites kept their control flow: window/surface close
  confirms, clipboard paste confirm, About box (OK-only + info icon).
  MB_DEFBUTTON2 parity preserved (Enter on default = Cancel). New
  `test/win32/confirm-dialogs.ps1` ALL PASS (20) ×3 — real ctrl+w /
  WM_CLOSE / palette-"about" open it, interiors sample dark (39–45),
  Escape + Enter-default cancel, Tab+Enter approves. P1–P3 +
  ipc-child-exited + both lanes green. Next per T51 order: T74.
- 2026-07-18 (on-box, 3) — T79 DONE. Dark context menus: new
  DarkMode.zig applies the undocumented uxtheme ordinals (#135
  SetPreferredAppMode, #136 FlushMenuThemes, #138 probed for the 1809
  signature split) at init/config-reload/WM_SETTINGCHANGE, mode derived
  like applyChromeTheme so menus match the title bar. New
  `test/win32/dark-menus.ps1` ALL PASS (6): real right-click opens
  surface + tab-bar menus, screenshot-averages the #32768 menu window —
  dark 52/49, light 240/244. Both lanes + P1–P3 green. Surprise: a
  hand-rolled x64 INPUT struct without the 8-aligned dwExtraInfo made
  Marshal.SizeOf report 36 (not 40) and SendInput silently no-op. Next
  per T51 order: T80 (dark message boxes).
- 2026-07-18 (on-box, 2) — T77 DONE. gotoSplit now handles `tree.zoomed`
  exactly like GTK: navigating away clears the zoom by default or carries
  it to the target under `split-preserve-zoom = navigation`; also added
  the GTK same-target early-out. New `test/win32/split-zoom-nav.ps1`
  (2 GUI launches — default + `--split-preserve-zoom=navigation` CLI
  config arg; GetGUIThreadInfo reads real keyboard focus, no thread
  attach) ALL PASS (16): pre-fix bug asserted dead — focused pane is
  always visible after nav-out-of-zoom in both modes. Both test lanes +
  P1–P3 green. Session start note: upgrade-log resume args were partially
  dropped again ("read" instead of "read go.md and go") — the session
  still resumed fine; refreshed install verified answering +list.
- 2026-07-18 (on-box) — T65 DONE. Child-exited UI fixed end-to-end:
  removed the modal-and-return-true show_child_exited handler so the
  core's in-terminal UI shows (press-any-key notice on clean exits, rich
  diagnostic on abnormal). Validation surfaced three adjacent bugs, all
  fixed: (1) ConPTY renders its final frame AFTER process exit, erasing
  the core-written message — the child-exited notify now waits for pty
  quiescence (Exec.zig 50ms-poll timer, 1s cap); (2) the run-loop
  popup-edit key intercept cast the top-level Window's GWLP_USERDATA to
  *Surface on EVERY surface keystroke — out-of-bounds garbage reads that
  randomly ate keys and gave a reproducible AV (new surfaceParentOf
  class-checks TERMINAL_CLASS_NAME first); (3) Win32 Input Mode (DEC
  9001, ConPTY always enables it) makes encodeKey return null, so
  close-on-keypress never fired for exited panes — keyCallback now
  closes an exited surface on any non-modifier press (Windows-gated).
  Plus queueRender after the exit messages (win32 renderer is
  wakeup-driven; text sat unpainted). New test/win32/ipc-child-exited.ps1
  (18 asserts, real SendInput key — +send-keys writes to the PTY and
  cannot exercise close-on-key) ALL PASS x3; both lanes, P1–P3,
  kb-actions (28), ipc-under-load (7), hero-mode (60) all green.
  Release delivered to install locations. Next: T77.
- 2026-07-18 (on-box) — T51 DONE. Full parity re-audit via 4 parallel
  code sweeps (actions, IPC/GUI features, config, look-and-feel) + on-box
  verification (P1–P3, hero-mode 60, ipc-version ALL PASS; both test
  lanes green at HEAD). 16 findings filed as T65–T80; two 2026-07-12
  audit claims corrected (split-divider-color, unfocused-split-* NOT
  implemented). Standouts: show_child_exited swallows the core exit
  fallback (T65), gotoSplit-while-zoomed focuses a hidden pane (T77),
  light context menus/message boxes on dark chrome (T79/T80). Priority
  queue now exhausted — next work follows the suggested order in the
  tracker (T65 first). Surprise: a PS5.1 whole-file rewrite mojibake'd
  the details doc mid-session (Get-Content -Raw reads BOM-less UTF-8 as
  ANSI); restored from git, re-applied via Edit tool — never rewrite
  these docs with PowerShell.
- 2026-07-18 (on-box) — T52 DONE. Build provenance in-app: new win32
  provenance.zig feeds an IPC `version` verb, a "Running Instance"
  section in `+version` (works from any pane; "none detected" when no
  server), `+list --json` data.build (additive, Mac golden shape kept),
  and a palette "About Ghoztty" MessageBox. ipc-version.ps1 ALL PASS
  (22) x3; P1–P3 + both lanes green. Session also root-caused why the
  loop sat idle 1.5 days: the 07-17 02:31 upgrade relaunch was invoked
  with -ResumeCommand 'claude' (no --continue) — the script now
  substitutes the loop-resuming default unless -AllowPlainResume
  (34c515735), and go.md pins the rule. Next: T51 (full parity
  re-audit).
- 2026-07-17 (on-box, night) — T53b DONE (T53 complete) + T64 found+fixed.
  The detached 180-min soak finished ALL PASS (11): zero leak growth,
  responsive at all 720 samples, echo median 248ms, median fps 59; only
  WARN = the known T62 stall (pre-fix binary). New profile-latency.ps1
  (ALL PASS 14): keyboard latency 65→81ms at 0→150k lines, GUI-thread
  RTT 0ms through seek bursts even while the same pane storms; T62/T63
  bounds re-verified on ReleaseFast. Its unicode-typing probe exposed
  T64: SendInput KEYEVENTF_UNICODE (screen readers, OSK, automation)
  typed NOTHING — the TranslateMessage skip starved VK_PACKET of its
  WM_CHAR, the stale produced-text flag ate the char, and win32-input
  mode dropped all WM_CHAR; fixed all three layers (3cb802605),
  kb-actions grew a two-mode T64 section (ALL PASS 28). Delivered HEAD
  release to all 3 install locations at the boundary (deferred from the
  T62 session). Surprise for posterity: `ps -W` in Git Bash does NOT
  list Windows-native PIDs in column 1 — liveness checks must use
  tasklist/Get-Process (a Monitor false-fired on this). Next: T52.
- 2026-07-17 (on-box) — T62 DONE + T63 found+fixed. Arrived 3 min after
  the detached 180-min soak launched, so worked T62 instead of the T53b
  harvest. Fix: threadMainWindows batches pty output (64KB buffer +
  PeekNamedPipe top-up) so the renderer mutex is taken once per BATCH,
  not once per tiny write — echo-storm +read went 16–19s → 80–127ms.
  Validation immediately exposed T63: +close of the storm window hung
  the GUI thread 9+ min in read_thread.join() — threadExit's one-shot
  CancelIoEx misses whenever the reader is parsing (pre-existing race;
  batching widened it). Fixed: quit-byte check before every blocking
  read + retrying cancel with 20ms thread-handle waits. ipc-under-load
  grew echo-storm +read (<2s) and timed +close (<10s; 277ms) asserts —
  ALL PASS (7); both lanes green; P1–P3 ALL PASS. Also hardened
  p1/p2/p3 + ipc-under-load kill sweeps to exact-exe match: the old
  `*zig-out*` pattern would have killed the running zig-out-release
  soak (it survived). Delivery to install locations deferred to the
  T53b boundary (soak locks zig-out-release; user-facing fix, deliver
  then). Next: T53b harvest (~02:25+ report), profiling, then T52.
- 2026-07-16 (on-box, late) — T53a DONE, T62 filed. Built the soak harness
  (`soak.ps1`, IPC-only so it can run beside real work) and its first smoke
  immediately caught a P0: App.wakeup() had NO coalescing, so a tiny-write
  storm (cmd echo loop, 600k lines <10s) filled the GUI thread's 10k
  posted-message quota and EVERY PostMessageW failed — all IPC answered
  "server not ready" (40/40 +list failures), deferred SetFocus + hero
  snaps drop on the same quota. Fixed with a wakeup_pending atomic
  (xev.Async contract); `ipc-under-load.ps1` is the regression guard
  (ALL PASS post-fix; 0/40 pre-fix). Soak smoke 11/11 after. T62 filed:
  +read stalled 16.1s against the tiny-write storm (renderer-mutex
  starvation, T48 candidate 2 made real; byte-heavy `type` storms do NOT
  trigger it). Surprises: cmd echoes 600k lines through ConPTY in
  seconds (bounded echo loops are useless as sustained storms — use
  endless `type` loops); idle panes make `perf max_gap_ms` meaningless
  as a stall bound; one test instance exited silently ONCE (no WER, no
  watchdog) — unreproduced, long soak watches for it. Boundary: 3-hour
  detached soak launched (report in %TEMP%\ghoztty-soak\<stamp>\, T53b
  harvests it) + release refresh launched to deliver the wakeup fix.
- 2026-07-16 (on-box) — T61 DONE (mid-turn user bug reports, took priority
  over queued T53): in hero mode ctrl+shift+up/down (bound to swap_split
  on Windows) spatially SWAPPED panes in the hidden tree — the selection
  chased the swapped pane ("index 1 up went to 2") and toggle-off restored
  a mutated layout. Window.swapSplit now intercepts under hero: up/down =
  heroSelect prev/next (Windows mirror of the Mac cmd+shift hero-nav
  chord), left/right no-op. hero-mode.ps1 step 3b added; ALL PASS (60);
  both lanes + P1–P3 green. Delivered to all install locations. Next: T53.
- 2026-07-16 (on-box) — T59b DONE: hero-mode TRUE port complete. Wheel
  scroll (parent WM_MOUSEWHEEL + surface fallback for wheel-follows-focus),
  divider drag with 80ms-throttled leaf resize + double-click ratio reset,
  hover chrome, snapshot-slide (0.35s) + carousel re-center (0.3s) on one
  16ms timer with SPI_GETCLIENTAREAANIMATION honored. Perf pass clean
  (thumbnail heartbeat ≈7fps/renderer while hero on, max gap 174ms, no
  spike during animated swaps). hero-mode.ps1 grew a phase 3 — the
  mid-slide oracle (poll for a 0-visible-panes state right after a
  selecting click) proved the owner-painted slide on the real box; ALL
  PASS (58). Harness lesson: PS 5.1 parses 32-bit-filling hex literals
  (0xFF880000) as NEGATIVE Int32 — a [uint64] cast throws; use decimal.
  Also: a hero-mode.ps1 crash mid-run leaves the outer pipeline hung
  because the spawned GUI inherits the stdout handle — kill the zig-out
  ghoztty to unblock. DELIVERED to all install locations (user explicitly
  corrected the hero port on 2026-07-16): ReleaseFast gnu -Dstrip=false
  staged to zig-out-release; Desktop portable + \\homeassistant\share
  refreshed; installed release swapped via the detached upgrade script,
  relaunched as a fresh session re-entering go.md (doubles as the context
  reset, T48 precedent). Next: T53.

- 2026-07-16 (on-box) — T59a DONE: hero-mode TRUE port first half — renderer
  snapshot pipeline (captureThumb blits the OFFSCREEN render target, so the
  T58 hidden-window spike risk evaporated: hidden panes capture cleanly, no
  fallback needed), SW_HIDE + renderer-awake hero layout with all leaves
  hero-sized, owner-painted HeroCarousel.zig + unit-tested hero_math.zig,
  click-a-tile-to-select, 150ms refresh timer (paused while minimized).
  hero-mode.ps1 rewritten to the T58 oracle. Two HARNESS lessons burned a
  lot of the session: (1) pixel scripts must be per-monitor-DPI-aware or
  PrintWindow silently clips at 125% DPI; (2) the carousel strip is in
  TREE ITERATION ORDER and prev/next clamp at the ends (Mac parity) — the
  focused pane is not necessarily first, so a nav test pressing only
  "down" can hit a correct no-op (heroSelect logged req=3 clamped=2
  cur=2; the test now tries down then up). Also: chord tests can't run
  while the user is actively using the box (SetForegroundWindow denied) —
  the final validation ran via a wait-for-input-idle runner. Next: T59b
  (wheel scroll, divider drag, hover chrome, slide/re-center animations).

- 2026-07-16 (on-box) — T58 DONE (design, doc-only): resolved all five
  win32 design questions from code study (Window/Surface/generic/OpenGL/
  Thread.zig). Headline decisions: thumbnails come from the RENDERER
  (FBO-downscaled BGRA readback in a pre-SwapBuffers hook in generic.zig
  drawFrame; HWND capture rejected — WS_CHILD GL windows have no DWM
  redirection surface and hidden windows aren't composited); non-hero
  panes SW_HIDE but renderer kept awake, ALL panes kept hero-sized so
  selection swap needs no reflow (Mac slot model); carousel is
  owner-painted in a new HeroCarousel.zig + hero_math.zig (no per-tile
  HWNDs, no mega-file growth); hero swap animates as a snapshot-slide
  (no live-GL SetWindowPos per tick); divider drag → per-tab ratio.
  Known risk (hidden-window back-buffer rendering) gets a de-risk spike
  as T59a step 1 with a documented fallback. T59 split → T59a (pipeline
  + static carousel) / T59b (interactions + motion), each with ordered
  steps and validation. Next: T59a.

- 2026-07-16 (on-box) — T58/T59 FILED from a mid-session user correction:
  the T19 hero-mode port missed the actual Mac design (maximized hero +
  right-side vertical carousel of pane THUMBNAILS with animations, drag
  divider, selection chrome — T19 shipped a static live-pane stand-in).
  Read all four Swift HeroMode sources and recorded a full behavioral
  spec + win32 design questions in the T58 details section, so T58 need
  not re-read Swift. T19 row/section got a CORRECTION note (keybind/
  toggle/focus plumbing stays valid). T58→T59 inserted at the head of the
  priority queue (before T53). Also fixed a tracker bug: two rows were
  both numbered T56 — the title-jitter task (2026-07-16) renumbered to
  T60; T56 stays the remote-reconnect task. No code changes.

- 2026-07-15 (on-box) — T48 DONE (e35ef81fd): implemented the deferral fix
  for the release GUI deadlock T48a root-caused. `App.deferSetFocus(hwnd)`
  posts a private WM_APP_SETFOCUS (WM_APP+5); the run loop intercepts it
  before Translate/Dispatch and calls the real SetFocus there — at the top of
  the message loop, never nested inside a WndProc — so SetFocus's inline
  IME/CTF cascade (the WM_IME_SETCONTEXT re-entry that wedged the GUI thread
  on a Condition.wait) runs on a shallow, pumpable stack. Principled boundary
  that kept the diff honest: defer ONLY terminal-surface focus targets (the
  OpenGL windows that drive the nvoglv64/IME hook path); EDIT controls and
  dialog Tab-navigation keep synchronous focus so typing/key-routing stay
  immediate. 23 sites converted; tab_active_surface is set directly by the tab
  ops so deferring the actual SetFocus doesn't leave bookkeeping stale.
  Belt-and-suspenders half (no GUI-thread Condition.wait inside dispatch)
  still open pending a *matching* symbolized `+0x1ffa0e` dump — watchdog is
  `-Dstrip=false` now, so the next hang is symbolizable. New
  `test/win32/focus-defer.ps1` (ALL PASS, 9) drives the exact fixed path:
  PostMessage real WM_LBUTTONDOWN into each surface HWND (no foreground
  needed) → asserts deferred SetFocus actually lands real GUI focus on the
  clicked pane (cross-thread GetGUIThreadInfo().hwndFocus), and that a
  1500-focus-change click storm during heavy `for /L … echo` output leaves the
  GUI thread responsive (SendMessageTimeout SMTO_ABORTIFHUNG + live +list +
  focus still moves). Harness note: an IPC +close teardown *waits* on the
  flooded GUI-thread listener, so teardown direct-kills instead. Both test
  lanes green, GUI build clean, kb-actions/ipc-p1/p2/p3 unaffected. DELIVERED
  to all install locations (this fix matters — it's the release freeze):
  ReleaseFast gnu build (`-Dstrip=false`) staged to zig-out-release
  (`+version` = `+312ff857d`); Desktop portable + `\\homeassistant\share`
  refreshed (exe+pdb, share mirrored, dated `.bak-20260715c`); installed
  release swapped via the detached upgrade script and relaunched as a FRESH
  clean Claude session (no `--continue`) re-entering go.md — so this delivery
  doubles as the context reset. Next: T53 (long-context reliability/perf soak
  — the natural home for confirming no recurrence under a real release soak
  with the now-symbolized watchdog).

- 2026-07-15 (on-box) — T48a DONE (root-caused the release GUI deadlock);
  split T48 into T48a (investigate, done) + T48 (implement fix, todo). Loaded
  the existing 744MB dump in the store WinDbg's cdb with MS public symbols —
  no ghoztty pdb needed, system frames resolve. Two access gotchas worth
  remembering: the watchdog wrote the dump elevated so its DACL denied read to
  the owner (fix: `icacls <dump> /grant $USER:R` — owner has implicit
  WRITE_DAC), and the store cdb runs in an app container that can't read D:\
  (fix: invoke the underlying exe, and the dump lives in a user-profile path
  so it reads once the DACL is fixed). Verdict: NOT a lock cycle (`!locks`
  finds nothing owned; all non-GUI threads idle; no EventPairLow — the old
  note's "EventPairLow ×2" was WER noise). The GUI thread calls `SetFocus`
  inside its WindowProc → IME/CTF (`ImeSystemHandler`→`CtfImeSetActiveContext`)
  does a synchronous SendMessage (WM_IME_SETCONTEXT) that re-enters the
  WindowProc, where ghoztty `std.Thread.Condition.wait()`s (→
  `SleepConditionVariableSRW`, INFINITE) forever on a non-pumping stack.
  Same re-entrancy class as the already-fixed WM_GETOBJECT/oleacc hang
  (App.zig:2485, present in the dump build) but reached through the uncovered
  IME/CTF path. All three old ranked candidates refuted. Full evidence +
  reproduce steps + fix direction: `t48-deadlock-dump-analysis.md`. Next:
  T48 — defer SetFocus out of WindowProc (PostMessage WM_APP_SETFOCUS, call
  it at the top of the loop) so the cascade runs where the thread can pump;
  repro under the now-symbolized watchdog build to pin `+0x1ffa0e`.
- 2026-07-15 (on-box) — T22c DONE (code 4e7edfc9b; docs this commit): the
  win32 "New Remote Window" machine chooser. ctrl+shift+n (intercepted locally
  in `Surface.handleKeyEvent` — no core action exists, so it shadows the
  cross-platform ctrl+shift+n → new_window default on Windows only; ctrl+n
  still makes a plain window) and a "New Remote Window" command-palette entry
  open `MachineChooser.zig`, a RenameDialog-style modal (native EDIT filter +
  LISTBOX, keys routed via `App.machineChooserOwning`/`handleKey`). It fetches
  the account's devices once via `relay_directory.listDevices`; no token / a
  fetch error → Local-only list + footer hint, no crash. Selecting a device
  dials+opens via the NEW `App.openRelayWindow` — the single relay-open path,
  factored out of `handleNewRemoteWindow` so the IPC verb and the chooser
  share it (IPC error strings still byte-match; ipc-relay* stayed ALL PASS).
  Refactor surprise avoided: kept the tcp/relay error-string mapping in the
  handler and pushed only dial+create into the App helpers. Both test lanes
  green; new `test/win32/ipc-machine-chooser.ps1` ALL PASS on-box (real chord →
  chooser opens → `GET /v1/client/devices` from a loopback fake dir → Escape,
  no crash — the fake-dir GET is the positive control the keybind harness
  demands). Also fixed a foreground-steal papercut: opening a device window
  now skips the owner-refocus in `close()` so the new remote window stays on
  top. T22 remote-window series complete. Next priority: T48 (deadlock).
- 2026-07-15 (on-box) — T22b DONE (7ec2c7119): `src/remote/relay_directory.zig`
  — pure Zig client for `GET /v1/client/devices` mirroring the macOS
  `RelayDirectoryClient`. `Device{id,name,hostname?,online}` parse (`.alloc_always`
  so it outlives a freed body), trailing-slash-tolerant `joinUrl`,
  `classifyStatus` 401→unauthorized / 404→not_found / other→`{http}`, and
  `listDevices` = thin compose over `http_client.getAuth`. 11 unit tests, run in
  BOTH lanes via the `main_ghostty.zig` test aggregate; none + win32 lanes green.
  Live GET deferred to T22c (needs the account or a fake `GHOSTTY_RELAY_BASE`).
  Next: T22c (win32 chooser dialog + ctrl+shift+n + palette entry).
- 2026-07-15 (on-box) — T22a DONE (design only): split T22 into T22a
  (design) → T22b (Zig `/v1/client/devices` directory client) → T22c (win32
  chooser dialog + ctrl+shift+n + palette entry); T51 dep bumped to T22c.
  Investigated the Mac reference (`MachineChooserView` / `MachineRegistry` /
  `RelayDirectoryClient`) and the win32 landscape: `http_client.getAuth`
  already does bearer GETs (T22b is a thin wrapper), win32 has NO menu bar
  (so "menu item" = command-palette entry), there is NO core binding action
  for remote (Mac uses an AppKit menu, not a keybind) → ctrl+shift+n gets
  wired win32-native in the keyboard path (RenameDialog/ctrl+shift+r pattern,
  minus the core action). Dialog models on `RenameDialog.zig` (T50). Design +
  per-subtask validation pinned in the details `## T22a` section. No code.
  Next: T22b (pure data layer, none-lane unit-tested).
- 2026-07-15 (on-box, night 3) — T21a DONE (64c4329c2): Windows relay
  account sign-in. Zig port of macOS RelayAccount/GoogleOAuth —
  `google_oauth.zig` (PKCE S256, auth URL, JWT claims, token
  exchange/refresh over http_client's new form-POST, loopback receiver),
  `relay_account.zig` (DPAPI `account.dat` + owner-only DACL, resolveIdToken
  = GUI account tier), `win_acl.zig` (DACL helper extracted from
  enroll.zig), `+relay-login`/`+relay-logout` CLI (no IPC). IpcHandlers
  token tiers now --token → account → env. Three surprises, all fixed
  in-flight: (1) the loopback receiver's `std.net.Stream.read/write` fails
  ERROR_INVALID_PARAMETER(87) on the overlapped Windows socket — switched to
  raw `ws2_32.recv/send` like socket_stream.zig; (2) `json.parseFromSlice`
  borrows into the source slice by default → dangling after the decoded
  buffer frees → needed `.allocate = .alloc_always`; (3) `Start-Process
  -RedirectStandardOutput` leaves `$p.ExitCode` null — the E2E runs
  `+relay-login` via a cmd redirect (like Run-Cli) instead. New
  `ipc-relay-login.ps1` ALL PASS (fake-issuer login + logout + error path +
  account-tier window open, DEV_CLIENT_TOKEN set to the minted JWT so the
  dev relay accepts the account bearer). Existing relay/remote/P1-P3 still
  ALL PASS. Next: T22 (menu item + machine chooser).

- 2026-07-15 (on-box, night 2) — T21 split (sizing rule) into T21a
  (sign-in + DPAPI creds + `+relay-login`) / T21b (relay dial in the
  GUI); T21b DONE (89e31b7fb): `--relay/--device/--token` dial via the
  shared relay_dial (which now maps `http://`→plaintext `ws://` for
  loopback test relays, agent/ws_client rule); Window.remote_dialed is a
  tcp|relay union; token tiers --token → GHOSTTY_RELAY_TOKEN (account
  tier = T21a). New `ipc-relay.ps1` runs a REAL local relay (go build,
  DEV_AUTH) + relay-mode agent: full loop ALL PASS first run, incl.
  agent-kill-under-live-window (no GUI hang). No surprises. Next: T21a.

- 2026-07-15 (on-box, night) — T20 DONE: `+new-remote-window` direct TCP
  (2ed989866); new `test/win32/ipc-remote.ps1` ALL PASS vs a loopback
  agent. Surprises, both fixed in-flight: (1) Winsock — src/remote's
  SocketStream error-checked recv/send via posix.errno (never set on
  Windows) → intCast panic at first peer close (a27cb90a1); (2) a
  surface-scoped soft reload_config re-derived ALL surfaces from the app
  config, wiping per-surface overrides — remote `--command` windows
  closed on command exit; fixed by honoring the surface target + seeding
  app conditional state from the OS theme at startup. Filed T55:
  hero-mode.ps1 fails on a CLEAN HEAD too (hero chords don't dispatch;
  injection control passes) — predates T20, evidence in its section.
  Next: T21 (relay dial + sign-in + DPAPI creds).

- 2026-07-15 (on-box, evening) — T54 DONE: resume-doc diet. The tracker's
  state table shrank to one-line rows (status + commit); all per-task
  spec/validation/evidence narrative moved to new
  `windows-parity-details.md` (`## T<id>` sections, plus Bootstrap &
  environment and the backlog). Resume protocol now reads only go.md + the
  hot doc + the one task's details section (Grep `^## T<id> ` for the
  slice). Hot doc 65KB → 10KB; resume read ≈6–8k tokens (target <15k).
  All 55 table IDs cross-checked against details sections (55/55). go.md
  updated to name the details doc. Next priority: T20.

- 2026-07-15 (on-box, afternoon) — T50 DONE: real "Rename Window" dialog.
  New `src/apprt/win32/RenameDialog.zig` — owner-centered WS_POPUP+WS_CAPTION
  dialog (dark title bar/controls), "Window title:" label, prefilled edit,
  OK/Cancel. Owner disabled while open (modal) but the app msg loop keeps
  turning, so renderer + IPC stay live — no NSAlert-style wedge. Tab cycles
  focus, Enter commits (default = OK), Escape cancels; all three are routed
  from App.run's WM_KEYDOWN intercept (new `renameDialogOwning` — checked
  first + exclusive so dialog children never hit the Surface-cast popup
  intercepts). Commit path = `setTitleOverride` (the +rename/T10 path);
  empty text clears the override → reverts to the shell title. `prompt_title`
  (ctrl+shift+r) now opens this; tab double-click keeps the inline edit.
  Pure `layout()`/`nextFocus()` unit-tested in the win32 lane. kb-actions.ps1
  gained 20 T50 asserts; ALL PASS (25 total w/ T47), P1–P3 ALL PASS, both
  lanes green. HARNESS TRAP: FindWindowExW(dlg,_,'EDIT',$null) from
  PowerShell fails — $null title marshals to "" and only matches
  empty-titled windows, but the edit is prefilled; C# `null` (old T44 path)
  is a true null. Added a class-only ChildByClass(GW_CHILD/GW_HWNDNEXT
  walk) helper. NEXT: T54 (resume-doc diet).
- 2026-07-15 (on-box, midday) — T49 pixel verification (user: "look at its
  pixels, get a screenshot"). hero-mode.ps1 grew a pixel layer: PrintWindow
  full-window PNGs + per-pane distinct-color floors + carousel-ratio~25%
  assert; 16 asserts ALL PASS 3/3 on the release build; screenshots
  human-reviewed (hero content, carousel reflow, nav promotion correct).
  HARNESS TRAP for future pixel oracles: CopyFromScreen captures occluding
  windows — first runs produced convincing-but-false "carousel blank /
  misrendered strip" evidence; PrintWindow(PW_RENDERFULLCONTENT) on the
  target HWND is occlusion-immune and deterministic. Filed T54 (resume-doc
  diet, user-sanctioned). NEXT: T50.
- 2026-07-15 (on-box, morning) — T49 RESOLVED (stale binaries) + user
  reset of goals/priorities. User reported hero mode missing (no palette
  entry, no ctrl+shift+space) — root cause: they were typing in a JULY 5
  portable exe; the box ran FOUR coexisting builds (installed release,
  Desktop portable Jul 5, second portable instance, \\homeassistant\share
  Jul 12). All refreshed to HEAD (dated .baks); windows opened pre-refresh
  still run old code until relaunched. Fixed upgrade-script resume idling
  (--continue now gets the "read go.md and go" prompt — this is why the
  resumed session "stopped working" overnight). Filed T51 (re-audit, at
  end), T52 (build provenance in-app), T53 (long-context soak/tuning);
  reprioritized: T50 → T20/T21/T22 (remote + auth, user needs
  ctrl+shift+n) → T48 → T53 → T52 → T51. Goal + autonomy directives
  recorded in go.md quality bar and the tracker header. NEXT: T50.
- 2026-07-16 (on-box, early morning) — T57 (palette gap = real T49 cause),
  T55 (test bug, fixed), T56 filed. User re-repro'd "no hero mode": they were
  searching the COMMAND PALETTE, which on win32 is a hardcoded list
  (Surface.zig palette_entries) missing every fork action — keybind worked
  all along. Added Toggle Hero Mode + Swap Split x4 + Rename Window to the
  palette; hero-mode.ps1 now drives the palette end-to-end (ctrl+shift+p,
  type "hero", Enter → geometry; 23 asserts ALL PASS). T55's "chords not
  dispatched" was the script's own ctrl+shift+r positive control leaving the
  T50 modal rename dialog open — it DISABLES the owner (RenameDialog.zig),
  eating all later chords; control is now ctrl+k. Full board green: both
  unit lanes, kb-actions (25), P1–P3, hero-mode (23). Also: user reported
  the busy-window title jittering px-wise on a timer → T56 filed (suspect
  fallback-font braille spinner re-centering). The overnight window loss had
  NO ghoztty crash signature (process up since 7/15 23:49, no dumps, no WER)
  — likely the claude CLI/shell died; unexplained, watch for recurrence.
  Release refresh with the palette fix launched detached at turn end.
- 2026-07-14 (on-box, late night) — T49 investigated, NO repro on HEAD;
  release refresh launched. New `test/win32/hero-mode.ps1` (geometry oracle,
  real chords, reuses the kb-actions recipe + a positive-control chord):
  ALL PASS on Debug AND on a fresh ReleaseFast gnu build — toggle, focus
  seeding, ctrl+alt+down nav, exact tree restore. No shadow anywhere
  (binding dispatch log-verified; user config has no keybinds). Theory for
  the user report: installed 2bb4c802d has T19 but not the T40 wakeup fix,
  so live TUI panes render frozen → hero looks broken. Surprises: (1) an
  old zig-out-release exe (pre-suffix-hook) IGNORED GHOZTTY_PIPE_SUFFIX and
  my first two test launches forwarded new-window INTO the installed
  instance (strays closed) — always verify the staging exe is fresh before
  suffix-isolated runs; (2) `zig build` in git-bash without
  ZIG_GLOBAL_CACHE_DIR=D:\zig-global-cache fails ("configure phase"
  FileNotFound) — the memory note applies to Bash too, and a grep pipe can
  eat the nonzero exit; (3) in a multi-pane window the rename EDIT dies to
  focus churn too fast for out-of-process polling — assert on the Debug
  stderr binding-dispatch line instead (hero-mode.ps1 does). T49 is now
  blocked(user re-test); upgrade script launched detached at turn end with
  staging = this HEAD (exe+pdb+share), resuming via claude --continue.
- 2026-07-14 (on-box, night) — T40 DONE: renderer wakeups were 100% lost on
  Windows — termio held a by-value COPY of the renderer thread's xev.Async,
  and the IOCP Async is pure userspace state (waiter=null forever on the
  copy), so heavy output repainted only on the 600ms blink timer (~1.6fps).
  Fix = renderer_wakeup as *xev.Async everywhere. Release build measured
  before/after: fps 1→120, max frame gap 610ms→10ms during an 80MB visible
  stream. Surprises worth knowing: (1) `Measure-Command { cmd /c type … }`
  CAPTURES the output — first perf runs measured an idle screen; (2) wheel
  scrolling was NOT the bug — config discrete default already = 3
  lines/notch (Windows convention); stacking SPI_GETWHEELSCROLLLINES gives
  9/notch (wheel-scroll.ps1 now guards 3); (3) P2/P3 had been silently red
  since the " [DEBUG]" title marker landed — assertions now tolerate it;
  (4) new tooling: GHOZTTY_PERF=1 telemetry (fps/wakeups/pty-reads/slow-
  mutex), GHOZTTY_PIPE_SUFFIX for side-by-side release testing. Debug-lane
  note for T48: under Debug parse load the renderer waited up to ~1s on
  renderer_state.mutex (candidate-2 starvation is real but Debug-amplified;
  release shows none at 3MB/s). NEXT: release refresh (T36, -Dstrip=false)
  to actually deliver the fix to the installed app.
- 2026-07-14 (on-box, evening) — T48 recurrence + safeguards; T49/T50 filed —
  Release GUI froze white again 21:05 (WER AppHangB1; Windows closed it, no
  dump). The 18:35 T48 dump is unsymbolizable: ReleaseFast defaults
  strip=true (src/build/Config.zig:345) — release builds MUST use
  `-Dstrip=false` from now on. Safeguards: new
  scripts/watchdog-ghoztty-windows.ps1 (3s poll, 15s hang → full minidump
  to .dumps\ + kill + relaunch/--continue; MiniDumpWriteDump P/Invoke
  test-verified), staging rebuilt with pdb, upgrade script copies pdb
  beside the exe. Static candidate causes ranked in the T48 row (top:
  GUI-thread reentrant win32k self-block, same class as the fixed
  WM_GETOBJECT hang at App.zig:2294). Gotcha: Store WinDbgX cannot be
  scripted headlessly (-c ignored); get console cdb before attempting dump
  analysis. User directive: priority order now T40 (Claude Code scrolling
  perf) → T49 (hero mode broken) → T50 (rename dialog) → T48 root-cause;
  goal = highly reliable, highly performant client.
- 2026-07-14 (on-box) — T45/T46 — The 2026-07-13 reset-context failed:
  helper #1's `/clear` was MSYS-mangled into a user message; helper #2
  fired mid-turn because `--when-idle` scrapes for "esc to interrupt",
  which Claude Code v2.1.207 no longer renders — queued keys died with
  the /clear. Mechanism itself proven correct (new ipc-when-idle.ps1,
  T45). Fix (T46): busy = marker OR tail changing between 500ms polls;
  idle = neither across 3 polls. Skill cache gotcha: the 0.6.0 MSYS fix
  was dead on arrival — plugin cache had moved to 0.8.1; patch source
  repo + ACTIVE cache version. New scripts/upgrade-ghoztty-windows.ps1
  does detached kill/swap/relaunch/`claude --continue`; first live run
  upgraded ae71b19b4→7510d2cd2 and resumed the session cleanly (wart:
  cold relaunch also opens a stray default window). Release refreshed
  again with the T46 fix via the same script.
- 2026-07-13 (on-box, +1) — T40–T44 filed from live user reports on the
  installed release; rename-anchor fix + [DEBUG] title marker committed
  but the rename fix CRASHES on real input (T44, marked NEXT). User is
  AFK and wants autonomous progress: pick tasks per go.md, validate
  everything without user interaction (debug exe run from a console gives
  panic traces; synthetic keybd_event chords do NOT fire keybinds — see
  T44 notes before attempting GUI key injection). Session ended via
  /reset-context — its first successful use on Windows would close out
  T36's remaining checkbox (this very reset is the test).
- 2026-07-13 (on-box) — T36 (new, user-directed) — Frontloaded a locally
  installed RELEASE build so ghoztty IPC (and `/reset-context`) powers
  on-box sessions. Merged origin/main (62 commits: `+list --tty`,
  `+send-keys`/`+read --when-idle`, sticky pane banner, remote/relay
  fixes). Conflicts: none.zig (kept our unified ipc_client helper; main's
  set_banner case moved into `wireName()`, which auto-merge had left
  non-exhaustive) and list.zig (kept BOTH `--pid` and `--tty`). New
  `pane_banner`/`prompt_banner` actions ack'd as no-ops → T35 tracks the
  real win32 banner. Gotcha for release builds: native msvc + GUI
  subsystem fails to link (`undefined symbol: WinMain`) — release must be
  `-Dtarget=x86_64-windows-gnu`. Install: `%LOCALAPPDATA%\Programs\
  Ghoztty\{ghoztty.exe, share\}` + user PATH (that dir previously held a
  share\ with NO exe — the T23 MSI upgrade bug's droppings, live
  evidence). reset-context skill Step 1 now branches on
  `/proc/self/winpid` → `+list --pid` (fixed in marketplace repo + plugin
  cache). Both test lanes + P1–P3 ALL PASS post-merge. T28 remains
  in-progress (readonly/key_sequence/pwd/notification chunks untouched
  this session).
  integration (pwsh 7 + Windows PowerShell 5.1): a new
  `src/shell-integration/powershell/ghostty.ps1` chains onto the user's
  prompt (never replaces it) and emits OSC 133 A/B/C/D marks, OSC 7 cwd,
  OSC 2 title, all feature-gated and wrapped so it can never break the
  user's shell. Injected as `-NoExit -Command . '<script>'` (PowerShell has
  no ENV/rcfile hook); non-interactive invocations (-Command/-File/-c/
  -EncodedCommand) bail out untouched. **The task's premise understated the
  problem: OSC 7 was dead on Windows in the CORE** — `reportPwd` began with
  `if (windows) { log.warn("unimplemented"); return; }`, so NO shell could
  report cwd on Windows, ever. Implemented it, including URI→native path
  normalization (`/D:/git/x` → `D:\git\x`). Bug caught in my own fix:
  `stackFallback.get()` must be called exactly once — calling it twice
  panics (reached unreachable code). Validated live: a PowerShell pane's
  reported cwd now tracks `cd` (D:\git\ghoztty → C:\Windows → C:\Users).
  cmd.exe still cannot be integrated (no prompt hook) — inherent.
- 2026-07-12 (on-box, late night, +5) — T26 done — OS light/dark now
  reaches the TERMINAL side (not just the DWM chrome): initial
  colorSchemeCallback at surface init + re-report on WM_SETTINGCHANGE.
  The interesting bug: WM_SETTINGCHANGE broadcasts are delivered to
  TOP-LEVEL windows only, so a handler in the surface (child) wndproc
  never fires — the report lives in Window.windowWndProc, which also
  re-applies the DWM chrome for `window-theme = system`. Validated with a
  `theme = light:Adwaita,dark:GitHub Dark` config and a screenshot-pixel
  oracle across dark→light→dark flips (the OSC 11 response goes to the
  shell's stdin, so `+read` is NOT a usable oracle for it — pixels are).
  Test restores the user's theme + config.
- 2026-07-12 (on-box, late night, +4) — T31, T19a, T19 done — `+list --pid`
  lands the Windows answer to the Mac's tty-based pane identity: leaves now
  carry the shell's real pid (GetProcessId on the ConPTY child handle) and
  `--pid=<any descendant>` resolves the owning pane via a Toolhelp32
  ancestry walk (unit-tested with cycle/self-parent guards). This unblocks
  pane-aware workflow skills on Windows (/reset-context's probe becomes
  `ghoztty +list --pid=<winpid>`; the SKILL itself still needs its Step 1
  updated — it's a user plugin, not in this repo). Then hero mode (T19a
  design → T19 implementation): per-tab state, layout branch above zoom,
  goto interception, focus-follows, tree-change clamping. **Every apprt
  action on win32 is now implemented or a deliberate no-op — no
  `return false` stubs remain.** Validation lesson worth keeping: for
  keybind-driven GUI tests, build the layout in the AUTO-LAUNCHED window
  (its MainWindowHandle owns keyboard focus) — cross-process
  SetForegroundWindow does NOT move focus into another window's child
  pane, which silently sent my first hero runs to the wrong window.
- 2026-07-12 (on-box, late night, +3) — T32 done, T34 done — Phase J
  underway per the standing directive. IPC code restructured into five
  focused modules with the pure logic (arg parsing, shell wrap table,
  LF→CR, layout validation) unit-tested in the none-runtime suite; P1–P3
  acceptance re-run green after EVERY step. Shell-flavor work found a
  real parity bug: posix-flavor `--command` panes (git-bash) exited with
  the command because the Mac's `; exec shell -li` keep-alive wasn't
  ported — fixed, all flavors keep the shell alive now. On-box flavor
  validation: cmd/powershell/git-bash green via +read markers; wsl
  blocked by the box having only the docker-desktop utility distro.
- 2026-07-12 (on-box, late night, +2) — T18 done — win32 swap_split:
  Window.swapSplit (goto to resolve the neighbor, SplitTree.swap for the
  tree, focus follows the moved pane) + action arm replacing the stub.
  TWO keybind shadows found while validating (the fork's ctrl+shift+arrow
  swap bindings were dead on Windows all along): (1) hero-mode nav bound
  goto_split prev/next at ctrlOrSuper+shift+up/down — now explicitly
  super+shift (Mac unchanged, Windows freed); (2) upstream's
  jump_to_prompt ctrl+shift+up/down came AFTER the fork's swap block in
  the non-Mac defaults — swap block moved after it so the fork binding
  wins (prompt jumping needs shell integration, dead on Windows until
  T27). Validated: swap up/down via keybind with JSON tree order + focus
  as oracle, screenshot archived. Debugging tip that cracked it: launch
  the debug exe with stderr to a file and grep 'key event binding' to see
  exactly which action a chord resolves to.
- 2026-07-12 (on-box, late night, +1) — T02 done — ctrl+p →
  toggle_command_palette and ctrl+f4 → close_tab added to the Windows
  mirror block (Config.zig). Validated with verified-focus SendKeys:
  palette popup appears on ctrl+p, tab count 2→1 on ctrl+f4 (+list as the
  oracle). Testing note: window-COUNT assertions are noisy — the themed
  scrollbar overlay is a transient top-level popup that auto-hides; assert
  deltas on the specific window, not absolute counts. T01 left for the
  user: it verifies the STAGED RELEASE ZIP artifact, and a release exe
  here would collide with the user's three live release instances.
- 2026-07-12 (on-box, late night, later) — T17 done — **PHASE E / P4 COMPLETE:
  THE ORIGINAL ASK IS CLOSED.** Ran the ghoztty skill from this on-box
  Claude Code session against the debug exe (PATH prepended; zero skill
  edits): three-pane example verbatim (incl. cold auto-launch), +read,
  +send-keys round-trip verified via +read, C-c, set-state loop, +rename,
  +rearrange with pane removal, auto-name (`window-1`) targeting,
  idempotent teardown. Zero functional divergences. Env note: box lacks
  `jq` (skill's jq discover pattern untested; PS ConvertFrom-Json is the
  local equivalent). Phases B–E all green: P1 (22), P2 (21), P3 (17)
  acceptance scripts checked in and passing from fresh starts. Remaining
  on-box work: T01/T02 (Phase A keybinds), T18/T19 (GUI parity),
  T20–T22 (remote), T23/T24 (distribution), T26–T28 (audit gaps).
- 2026-07-12 (on-box, late night) — T13–T15 done — `+read`: dumpTextLocked
  under the renderer mutex with a full-SCREEN selection
  (pages.getTopLeft/BottomRight(.screen)), trailing N lines in data.text;
  byte-accurate on the box. `+set-state`/OSC 7777: per-pane activity_state
  on win32 Surface, window aggregation → " (busy)"/" (needs_input)" title
  suffix; the activity_state action arm replaces the stub so the OSC path
  (validated with a pwsh `[console]::Write(ESC ]7777;busy BEL)` from inside
  the pane) and the verb share one code path. `+rearrange`: builds a
  replacement SplitTree directly (preorder nodes array, root=0, own arena),
  refs kept surfaces before dropping the old tree (unref destroys panes not
  in the layout), ratio arrives as percent clamped 0.1–0.9, Mac error
  strings. PowerShell gotchas recorded: PS 5.1 reads .ps1 as ANSI — keep
  test scripts pure ASCII (an em-dash broke parsing); PS native-arg passing
  eats embedded quotes — escape as `\"` when passing JSON (`--layout`).
  T16 ipc-p3.ps1: ALL PASS (17) — Phase D (P3) complete. Next: T17 (skill conformance).
- 2026-07-12 (on-box, night) — T09–T12 done, Phase C (P2) complete —
  `+split`: Window.newSplitAt (arbitrary surface, explicit ratio,
  background-tab panes stay hidden), --pane/--target/foreground-default
  resolution, --percent→ratio. `+rename`: window titleOverride (window
  title shows override; tab labels keep tracking the shell). `+send-keys`:
  server writes raw --keys bytes to the pane PTY via
  termio.Message.WriteReq/queueMessage; KEY FINDING — ConPTY shells do not
  execute on LF, only CR, so the server normalizes LF/CRLF→CR (the CLI's
  `\n` notation means Enter; validated `title X\n` runs in cmd).
  Validation trick worth keeping: use the shell `title` command +
  `+list`'s tab title to prove send-keys executed without needing +read.
  `test/win32/ipc-p2.ps1` ALL PASS (21). Next: T13 (+read — dumpTextLocked
  full-screen selection; parse fields already staged), then T14/T15.
- 2026-07-12 (on-box, evening) — T06+T07 done — `+new-window` full flags:
  parseVerbArgs ports the Mac prefix table; per-surface config overrides
  (command/cwd/env) flow via a Window `pending_surface_overrides` baton into
  the Surface.init config copy, using the config Command `.direct` argv form
  (the Windows `.shell` path whitespace-splits with NO quoting — never wrap
  commands as one string). Shell table per spec (pwsh `-NoExit -Command` /
  cmd `/K` / else `-lic`); GHOZTTY_WINDOW_NAME/PANE_NAME env injected;
  window titleOverride (`--title`, reused by T10); canonical window
  ipc_name = --target else `window-N` (Mac windowName semantics — reverse
  hash lookup showed arbitrary names first). Auto-launch: raw CreateProcessW
  with bInheritHandles=FALSE + DETACHED_PROCESS — std.process.Child inherits
  the CLI's redirected stdout/stderr, which kept callers' pipes open and
  HUNG any script capturing `+new-window` output (first validation run
  deadlocked on this). `+close`: pane→closeSplitSurface, window→close(),
  missing→success; found+fixed a dangling-registry bug: Window.onDestroy
  frees the Window WITHOUT deinit(), so ipcForget/name frees had to be added
  there too. T08 `test/win32/ipc-p1.ps1`: ALL PASS (22 assertions) from a
  fresh start — Phase B (P1) complete. Known cosmetic gaps: --no-activate is
  best-effort (window still created focused within the app);
  --color/--percent accepted-and-ignored.
- 2026-07-12 (on-box, later still) — T05 done — `+list` is real: shared
  list-JSON data model + serializer in `src/apprt/ipc.zig` (golden tests pin
  the Mac wire shape — keep in sync with IPCMessage.swift), win32 registry
  (`App.ipc_targets`: StringHashMap of window/pane unions, eager ipcForget
  from Window/Surface deinit + prune-on-register so stale pointers are
  unreachable), auto window names `window-N` (Mac parity), pane fallback
  names = core surface id (Mac uses uuid), per-pane title storage on win32
  Surface (fixes the getTitle TODO; leaf titles now real). Known gaps left
  in the leaf data, all cosmetic for the skill: pid=0, tty="",
  exit_code=null (ConPTY backend doesn't surface them yet) — carried as
  notes, not tasks. Validation: keybind-driven 2-tab + split layout listed
  correctly (human + json); SendKeys only after VERIFYING foreground window
  (first attempt silently missed focus — don't trust AppActivate).
  PowerShell tool note: interleaved native stdout can swallow lines — pipe
  CLI output to files via `cmd /c ... >` when asserting. Next: T06
  (+new-window flags + auto-launch).
- 2026-07-12 (on-box, later) — T04 done — New `src/apprt/win32/IpcServer.zig`:
  named-pipe listener thread (single instance, byte mode,
  PIPE_REJECT_REMOTE_CLIENTS), owner-only DACL via SDDL
  `D:P(A;;GA;;;<user-sid>)`, requests marshaled to the GUI thread via
  message-only window (`WM_APP_IPC` + ResetEvent), framing/error strings
  byte-match the Mac server. FILE_FLAG_FIRST_PIPE_INSTANCE doubles as the
  single-instance lock: second GUI launch gets AlreadyRunning → forwards
  `new-window` as a client → exits. Shutdown drains in-flight WM_APP_IPC
  from deinit (GUI no longer pumping) before joining the listener — verified
  no deadlock via clean exit after IPC use. Dispatch implements `new-window`
  (plain, flags land with T06) and `list` (empty tree, real rendering is
  T05); other verbs answer `unimplemented action on Windows: <verb>`.
  Found while testing: the box had 3 windowless RELEASE ghoztty leftovers
  running (quit-after-last-window-closed=false default keeps the process
  alive headless — macOS parity, maybe surprising on Windows; noting for the
  user, left them running). Next: T05 (+list registry + Mac-format render).
- 2026-07-12 (on-box) — bootstrap + T03 done — First on-box session
  (MaximusHome, D:\git\ghoztty). Toolchain verified (zig 0.15.2 via winget,
  `ZIG_GLOBAL_CACHE_DIR=D:\zig-global-cache` required — cross-drive cache
  panics the build runner). Native win32 Debug build green; exe launches and
  stays up (cmd.exe shell window). T03 round-trip green: `ipc-fake-server.ps1
  -DebugPipe` logged the framed `{"action":"list"}` request, CLI printed
  `No windows open.` exit 0. `zig build test -Dapp-runtime=none` was RED
  natively with 3 fork compile errors, fixed this session: (1)+(2)
  `connection.zig` LifecycleAgent used `std.atomic.Value(u128)` for
  `seen_channel` — x86_64 has no 128-bit atomics (worked on aarch64 Mac);
  now mutex-guarded. (3) `ssh_transport.zig controlPath` called
  `posix.getenv` (comptime error on Windows); now branches per-OS
  (`TEMP` via getEnvVarOwned on Windows). After fixes: full suite green
  natively. Next: T04 (pipe server in win32 App).

- 2026-07-12 (later) — T03 code COMPLETE (353d70abf): new shared
  `src/os/ipc_client.zig` (posix socket + Windows named pipe, framed
  exchange, sendAction), all five client copies collapsed onto it, Windows
  guards removed, win32 `performIpc` is a real pipe client,
  `Action.Key.wireName()` added. Bonus fix 64f5b6984: xtversion test had
  been red since the ghoztty rename. Validated on Mac: core tests green,
  win32 Debug+ReleaseFast cross-compiles green, native macOS build green,
  `+list`/`+set-state`/`+close` live against the debug instance. Box
  round-trip NOT yet run: kit staged at share `ghoztty-windows/t03/`
  (`ghoztty-t03-debug.exe` = Debug build → debug pipe, `ipc-fake-server.ps1`,
  `run-t03.ps1` writes `t03-result.txt`) — run `run-t03.ps1` on the box, or
  fold into T04/T08 validation. Attempted remote-window validation wedged
  the RELEASE app: dial failure → modal alert on locked screen → IPC dead
  until user dismisses (→ new task T30; user must click the alert away).
  Note: `zig build -Dapp-runtime=none -Dtarget=x86_64-windows-gnu` was
  already broken pre-T03 (ssh_transport posix calls, hit via main_c/lib) —
  untouched, tracked nowhere yet; only matters if we ever ship a Windows
  none-runtime lib.
- 2026-07-12 — doc created + full three-way audit run (action matrix, GUI
  features, config coverage — see appendix). Audit added T26–T29 and the
  backlog section; win32 baseline is stronger than assumed (search,
  palette, quick terminal, IME, notifications, global hotkeys all
  present). Fresh ZIP (from 8c22dd370) staged to share; Jul-6 zip backed
  up. Findings that seeded T01/T02: old zip provenance unverifiable;
  ctrl+p/ctrl+f4 never bound anywhere. Next: T01 (needs the box) or T03
  (pure Mac-side) are both unblocked.
