# Windows parity — per-task details

Companion to `windows-parity-tasks.md` (the hot resume doc). One `## T<id>`
section per task: spec, validation plan, and evidence/notes. **Read only the
section for the task you are working on** — Grep `^## T<id> ` for its
location and Read that slice. Never read this file wholesale.

Status lives ONLY in the hot doc's state table; sections here carry no
status so they can't go stale.

## Bootstrap & environment (on-box, Windows / MaximusHome)

Development moved to the Windows box 2026-07-12 — an on-box Claude Code
session owns Phases B–E; Mac sessions own Mac-side tasks (T29, T30) and the
pre-merge macOS regression build. Both sync via
`origin/users/dzearing/windows-amd64`; pull before starting, push at every
task boundary.

One-time setup (PowerShell, admin where needed):

```powershell
winget install Git.Git
winget install zig.zig --version 0.15.2   # exact version; repo requireZig's it
winget install Anthropic.ClaudeCode       # or: irm https://claude.ai/install.ps1 | iex
git clone https://github.com/dzearing/ghoztty
cd ghoztty
git checkout users/dzearing/windows-amd64
```

Build/test lanes on the box:

1. `zig build -Dapp-runtime=win32 -Doptimize=Debug` (native; Console
   subsystem → stderr visible). Launch `zig-out\bin\ghoztty.exe`.
2. `zig build test -Dapp-runtime=none` — upstream keeps this green on
   Windows; deviations are our bugs. `zig build test -Dapp-runtime=win32`
   also runs natively and covers win32-tagged units (T33); run both
   before pushing code that touches win32 files.
3. Acceptance scripts `test/win32/ipc-p1.ps1` / `ipc-p2.ps1` / `ipc-p3.ps1`
   must stay ALL PASS. A Debug exe speaks the `ghoztty-debug-<username>`
   pipe; release exes speak `ghoztty-<username>`, so both run side by side.

On-box notes: config file lives at `%LOCALAPPDATA%\ghostty\config.ghostty`
(note the `ghostty` spelling); app log at `%LOCALAPPDATA%\ghoztty\ghoztty.log`;
the share is `\\homeassistant\share\ghoztty-windows` for staging artifacts
back to the Mac side.

Environment facts (verified 2026-07-12; the Mac seat's — still authoritative
for staging/ZIP layout and merge rules):

- Worktree: `~/git/ghoztty-windows-amd64`, branch `users/dzearing/windows-amd64`.
- Cross-compile from the Mac works with stock zig 0.15.2, no toolchain
  exports needed:
  `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast`
  → `zig-out/bin/ghoztty.exe` (~28 MB). Debug build (`-Doptimize=Debug`) is
  Console-subsystem → stderr visible.
- Core tests: `zig build test -Dapp-runtime=none` (upstream keeps this green
  on Windows; deviations are our bugs).
- **macOS regression build** (`zig build -Doptimize=Debug`, native) needs the
  macOS-26 toolchain workaround (SDK exports — see the
  `ghoztty-macos26-zig-toolchain` memory note). Run it before any merge to
  main; day-to-day Windows work doesn't need it.
- Staging to the box: mount `smb://dzearing@homeassistant/share` (password in
  the Mac keychain, `security find-internet-password -s homeassistant -a
  dzearing -w`), artifact dir `ghoztty-windows/`. ZIP layout:
  `Ghoztty/{ghoztty.exe, READ-ME-FIRST.txt, share/}` → zip as
  `Ghoztty-portable-x64.zip`. Keep a dated `.bak` of what you replace.
- Fresh ZIP built from `8c22dd370` staged 2026-07-12 (first build that
  provably contains the ctrl keybind mirrors). Prior Jul-6 zip kept as
  `Ghoztty-portable-x64-jul6.zip.bak`; its provenance was unverifiable
  (builds are not bit-reproducible).
- On-box execution options, in order of preference:
  a. Claude Code session on the Windows box (spec's assumption; best).
  b. Remote window from Mac Ghoztty to the box's `ghoztty-agent` via relay,
     driven with the ghoztty skill. Caveat: `+split --name` on remote panes
     doesn't register (async) — plan around it.
  c. Manual: user runs a checklist / PowerShell script and reports output.
- **Never modify `/Applications/Ghoztty.app`.** Never use `com.mitchellh.*`
  identifiers (fork namespace is `com.dzearing.ghoztty.*`).

## T01 — Verify fresh ZIP keybinds on box (Phase A)

The 2026-07-12 ZIP is the first artifact guaranteed to contain the ctrl
mirrors. On the box: extract fresh, then check `ctrl+n` (new window),
`ctrl+t` (new tab), `ctrl+d` (split right), `ctrl+shift+d` (split down),
`ctrl+w` (close pane), `ctrl+shift+p` (palette), `ctrl+1..9` (tabs),
`ctrl+c` copy-with-selection / SIGINT-without, `ctrl+v` paste.

*Validation:* each binding observed working on the box; record any failure
as a new task with repro notes (which shell, which layout).
If failures persist in this build, the bug is in the win32 key path
(`handleKeyEvent`) — capture `%LOCALAPPDATA%\ghoztty\ghoztty.log`.

*Evidence (done 2026-07-18):* verified on the box against a HEAD Debug
build (not the July-12 ZIP — every install location already runs newer
code, see T53b) with a new chord-injection acceptance script
`test/win32/keybinds-t01.ps1` (kb-actions.ps1 mechanics + mouse
double-click word-select; positive controls for typing and focus).
Observed working: ctrl+t, ctrl+2/9 (+ctrl+1 after the T83 fix), ctrl+f4,
ctrl+d, ctrl+shift+d, ctrl+w (close-confirm dialog approved by the
harness), ctrl+shift+p (+Escape close), ctrl+c WITH selection (copy —
clipboard verified), ctrl+v paste, ctrl+n. Two real bugs found and
filed: **T83** goto_tab off-by-one (ctrl+1 selected tab 2; fixed same
session) and **T84** ctrl+c without selection never interrupts a running
console child (NOT a keybind bug — repros with `+send-keys C-c`; the
script's SIGINT assert stays a known FAIL until T84 lands).

## T02 — Keybind gaps: ctrl+p, ctrl+f4 (Phase A)

Add to the Windows mirror block in `Config.zig`: `ctrl+p` →
`toggle_command_palette` (user muscle memory; accepts shadowing readline
previous-history), `ctrl+f4` → `close_tab` (Windows convention). Consider
`ctrl+,` → `open_config` if trivially portable.

*Validation:* `zig build test -Dapp-runtime=none` green; on-box check of
both bindings; update CLAUDE.md/README notes if they document shortcuts.

*Evidence (done, 82e096f4b):* on-box 2026-07-12: ctrl+p opens palette
(popup window appears, verified twice; Esc closes), ctrl+f4 closes tab
(2→1 via +list), ctrl+t sanity green; core tests green. ctrl+, already
worked (audit). Nuance: ctrl+p from INSIDE the palette edit doesn't
toggle-close (pre-existing popup-edit bubbling behavior).

## T03 — Named-pipe client helper + CLI un-guard (Phase B)

New `src/os/ipc_pipe.zig` (or similar): connect to
`\\.\pipe\ghoztty-<username>` (release) / `ghoztty-debug-<username>`
(debug), write 4-byte BE length + JSON request, read same-framed response.
Branch the per-OS connect layer inside the existing CLI command files;
remove the `os.tag == .windows` comptime guards that disable
`+list`/`+read`/`+rearrange`/etc. All commands go through the ONE helper.

*Validation:* cross-compiled `ghoztty.exe +list` against a fake pipe server
(PowerShell test harness or the T04 server) round-trips a request; core
tests green; macOS build unaffected (no code path changes for darwin).

*Evidence (done, 353d70abf, 4f52e8877, 64f5b6984):* box round-trip
2026-07-12: fake server logged `{"action":"list"}` (17 B framed), CLI
printed `No windows open.` exit 0; native win32 Debug build green; native
`zig build test -Dapp-runtime=none` green (after 2 fork compile fixes, see
log).

## T04 — Pipe server in win32 App + marshal + DACL (Phase B)

Listener thread owning the pipe (owner-only DACL), short-lived
request/response connections, requests marshaled to the GUI thread via the
existing message-only window (`WM_APP_*` + event for the response). Wire
`performIpc` to dispatch instead of returning `false`. Single-instance:
second GUI launch detects busy pipe → forwards `new-window` → exits.

*Validation:* on box, `ghoztty +list` returns a response (even if empty
tree); second `ghoztty.exe` launch focuses/creates in the first instance;
pipe rejects a different user (spawn under another account or verify DACL
with `Get-Acl`).

*Evidence (done, 1a44125de):* on-box 2026-07-12: `+list` answered by
in-app server (`No windows open.`, exit 0); 2nd GUI launch forwarded
new-window (master windows 1→2, second exited 0); pipe DACL = single ACE
`MAXIMUSHOME\David` FullControl; clean app exit after IPC use (no join
deadlock).

## T05 — `+list` (Phase B)

Registry (`StringHashMap(TargetEntry)`, liveness-pruned) + tree rendering
that byte-matches the Mac format (window → tabs → panes, `[target: …]`,
`[name: …]`, focused markers). Golden-file the Mac output shape in a test.

*Validation:* golden test green; on box, `+list` over a manually built
window/tab/split layout renders correctly.

*Evidence (done, da9d56d0d):* golden shape tests in apprt/ipc.zig green;
on-box 2026-07-12: 2-tab + h-split layout (built via ctrl+t/ctrl+d
SendInput) rendered correctly in human + `--json` forms — `[target:
window-1]`, per-pane `[name: <id>]`, focus/selected markers, pwd populated.

## T06 — `+new-window` full flags + auto-launch + 2nd-instance forward (Phase B)

All flags: `--target` (idempotent focus-if-exists), `--working-directory`,
`--command`, `--shell` (pwsh/powershell → `-NoExit -Command`; cmd → `/K`;
else `-lic`), `--title`, `--split`+`--split-command`, `--no-activate`,
`-e`. Auto-launch: no pipe → spawn `ghoztty.exe` detached, retry connect
with backoff.

*Validation:* on box — create named window running a command; re-run
focuses (no duplicate); auto-launch from cold works; `--title` shows;
`--no-activate` doesn't steal focus.

*Evidence (done, e80e32d39):* on-box 2026-07-12: cold auto-launch
(detached CreateProcessW) + create with --target/--title/--command; repeat
--target focused (no dup); --split=down + --split-command + --name
registered pane; --working-directory honored; -e exec window created;
`[target: <name>]` canonical (Mac windowName semantics).

## T07 — `+close` (Phase B)

Close named window or pane; missing target exits 0 silently; registry
pruned.

*Validation:* on box — close each target kind; close nonexistent → exit 0.

*Evidence (done, e80e32d39):* on-box 2026-07-12: close named pane (window
survives), close window, close missing → all exit 0; registry pruned via
ipcForget in destroy paths.

## T08 — P1 acceptance script (Phase B)

`test/win32/ipc-p1.ps1`, non-interactive, covering T05–T07 (create/focus/
close, idempotency, close-missing, auto-launch, list golden shape).

*Validation:* script passes on the box from a fresh app start; output
captured into the session log.

*Evidence (done, e80e32d39):* on-box 2026-07-12: ALL PASS (22 assertions —
auto-launch, create/focus/close, idempotency, close-missing, inline split,
-e, json shape, 2nd-instance forward) from fresh start.

## T09 — `+split` (Phase C)

`--direction`, `--target` (window OR pane), `--name` (pane registry),
`--command`, `--shell`, `--working-directory`, `-e`.

*Validation:* 3-pane CLAUDE.md example layout builds by name on the box.

*Evidence (done, 72943724a):* on-box 2026-07-12: three-pane CLAUDE.md
layout by name; idempotent --name; --pane exact-surface split with
--percent (ratio 0.70); missing-target error; teardown — ALL PASS (15).

## T10 — `+rename` / titleOverride precedence (Phase C)

titleOverride semantics — override beats terminal-set titles until
cleared, matching `BaseTerminalController.titleOverride`.

*Validation:* rename a window whose shell also sets titles; override wins;
`+list` reflects it.

*Evidence (done):* on-box 2026-07-12: rename sets window title; shell
`title` changes update the TAB label but the window title keeps the
override; missing target errors.

## T11 — `+send-keys` full notation (Phase C)

Full notation from `IPCServer.swift` handleSendKeys: `C-<x>` ctrl bytes,
`Enter`/`Tab`/`Escape`/`Space`/`Backspace`, escapes `\n \t \r \\ \e`;
concatenated, written to target pane's PTY (ConPTY input side).

*Validation:* `"echo hi" Enter` executes; `C-c` interrupts a running loop;
`"a\tb\n"` expands. Watch for ConPTY translation surprises — validate
against both cmd and pwsh.

*Evidence (done):* on-box 2026-07-12: `"title X" Enter` executed
(observable via +list tab title), `\n` escape executes after LF→CR ConPTY
normalization, C-c accepted, window-target routes to active pane, missing
target errors.

## T12 — P2 acceptance script (Phase C)

`test/win32/ipc-p2.ps1`. *Validation:* passes on box.

*Evidence (done):* on-box 2026-07-12: ALL PASS (21 assertions) from fresh
start.

## T13 — `+read` (Phase D)

Last N lines of screen+scrollback via the core's plain-text dump (same
machinery as `write_screen_file`), renderer mutex held; text in `data`.

*Validation:* echo known strings into a pane, `+read --lines=5` returns
them byte-accurate.

*Evidence (done, 1aac69e91):* on-box 2026-07-12: echoed marker read back
byte-accurate (--lines=5 + default 50); window target reads active pane;
missing pane errors.

## T14 — `+set-state` + OSC 7777 + title suffix (Phase D)

Implement the `activity_state` action (replace the stub): per-pane state,
window aggregation `needs_input > busy > idle`, title suffix ` (busy)`/
` (needs_input)`, cleared on idle. OSC `\e]7777;<state>\a` feeds the same
path (core side already parses it).

*Validation:* `+set-state` all three states → title bar changes observed;
two panes with different states aggregate correctly; `printf`-style OSC
round-trip from inside a pane.

*Evidence (done, fee87d441):* on-box 2026-07-12: all 3 states via CLI,
aggregation needs_input>busy>idle across 2 panes, suffix set/cleared; OSC
7777 busy/idle round-trip from inside the pane (pwsh `[console]::Write`);
invalid state errors.

## T15 — `+rearrange` (Phase D)

Port `handleRearrange` semantics from the Swift server onto the win32
`SplitTree`.

*Validation:* rearrange a 3-pane layout; `+list` and visual layout agree.

*Evidence (done):* on-box 2026-07-12: 4-pane tab rearranged to
horizontal(pa|vertical(pb,pc)) ratio 0.3 — unnamed pane closed, tree+human
list agree; duplicate/unknown-pane/bad-JSON error paths — ALL PASS (15).

## T16 — P3 acceptance script (Phase D)

`test/win32/ipc-p3.ps1`. *Validation:* passes on box.

*Evidence (done):* on-box 2026-07-12: ALL PASS (17 assertions — read
byte-accurate, state aggregation + suffix, OSC 7777 round-trip, rearrange
+ error paths) from fresh start.

## T17 — Skill conformance on the box (Phase E — the original ask)

From Claude Code on the box: the CLAUDE.md three-pane example verbatim,
plus the skill's list/read/send-keys/set-state loops. Every divergence
becomes a fix + a regression line in the P1–P3 scripts.

*Validation:* a full skill-driven session (create layout → read →
send-keys → set-state → teardown) with zero skill modifications.

*Evidence (done, doc only):* on-box 2026-07-12: full skill-driven session
from Claude Code with ZERO skill modifications — three-pane CLAUDE.md
example verbatim (auto-launch from cold; `tail -f` genuinely ran via
git-bash PATH), +read, +send-keys (echo round-trip read back), C-c,
set-state loop, +rename, +rearrange (70/30 + pane removal), auto-name
targeting (`window-1`), idempotent re-close/teardown. Env note: `jq` not
installed on box, that discover pattern untestable as-is.

## T18 — `swap_split` on win32 (Phase F)

Core `SplitTree.swap` exists; add the win32 action arm + re-layout.

*Validation:* keybind- and IPC-driven swap on a 3-pane layout; screenshot
archived.

*Evidence (done):* on-box 2026-07-12: ctrl+shift+up swapped stacked panes
(JSON tree order flipped, focus followed), ctrl+shift+down restored;
screenshot archived (temp t18-swap-after.png); IPC-driven swap covered by
the +rearrange swap pattern (T15). Fixed two binding shadows that had made
ctrl+shift+arrows dead for swap on Windows (see log).

## T19a — Hero mode design (Phase F)

Scouting notes from 2026-07-12 (reference sources located):

- Mac model lives in `macos/Sources/Features/HeroMode/` —
  `HeroModeState.swift` is tiny: `isActive`, `selectedIndex`,
  `carouselRatio` (default 0.25, clamped 0.1–0.6), `scrollOffset`;
  activate requires >1 leaf and seeds selection from the focused leaf;
  select/prev/next clamp to leaf count. Views: `HeroModeView` (hero pane
  fills `1-ratio` of width, carousel column right), `HeroCarouselView`,
  `HeroPaneView`.
- Interception points on Mac (`BaseTerminalController.swift`): goto_split
  prev/next while active moves the carousel selection (~line 989); tree
  changes clamp/deactivate (~line 635); hero nav keybinds are
  super+shift+up/down (now explicitly super — see T18 log — so Windows
  needs its own nav story, e.g. intercept goto_split up/down =
  ctrl+alt+arrows, or all goto variants → prev/next while active).
- win32 integration point: `Window.layoutSplits` (Window.zig ~700) —
  the `tree.zoomed` branch is the precedent for a non-tree layout mode
  (position/show/hide each leaf directly). Hero layout = leaves[i]
  full-height left at `(1-ratio)·w`; remaining leaves stacked in the
  right column. `layoutNode`/`paintDividers` stay untouched.

**DESIGN (decided 2026-07-12, on-box session):**

- **State is per-tab** (Mac = per-controller = per-tab): parallel arrays on
  Window beside `tab_trees`: `tab_hero_active: [MAX_TABS]bool`,
  `tab_hero_index: [MAX_TABS]u16`. Carousel ratio fixed at 0.25 for v1
  (Mac default; clamp 0.1–0.6 constants kept for the future drag).
- **Layout**: new branch at the TOP of `layoutSplits` (before the
  `tree.zoomed` branch): leaves in tree-iteration order; leaf[index] gets
  the left `(1-ratio)·w` full height; the remaining leaves stack equally
  in the right column. `paintDividers` early-returns while active.
- **Toggle** (`toggle_hero_mode` action, ctrl+shift+space on Windows):
  requires >1 leaf; activation seeds index from the focused leaf and
  clears `tree.zoomed` (zoom and hero are mutually exclusive; toggling
  zoom while hero active deactivates hero first).
- **Navigation while active**: intercept in `Window.gotoSplit` —
  previous/next AND spatial up/down move the selection (clamped, Mac
  clamps too); selection change = SetFocus(selected) + relayout. Spatial
  left/right pass through (hero pane vs carousel is horizontal).
- **Focus-follows**: clicking any carousel pane focuses it; the
  WM_SETFOCUS path that updates `tab_active_surface` also sets
  `tab_hero_index` to that leaf while active.
- **Tree changes** (split/close/rearrange) while active: clamp index;
  deactivate when leaves ≤ 1. One `heroOnTreeChanged(tab)` helper called
  from newSplitAt/closeSplitSurface/closeTab/rearrange swap sites.
- **+list is unaffected** — hero is pure presentation; the tree does not
  change (matches Mac).

## T19 — Hero mode on win32, implement per T19a (Phase F)

Pure `Window.zig` layout work plus the `toggle_hero_mode` action arm (the
last `return false` stub in win32 `performAction`).

*Validation:* toggle on/off on a 3-pane layout; focus-follows behavior
matches Mac; screenshot archived.

*Evidence (done, f37bd1e3c):* on-box 2026-07-12: geometry oracle on a
3-pane layout — tree (3x310px) → hero (465x442 left + two 156px stacked
right at x=502) → ctrl+alt+down moves the hero → toggle-off restores the
exact tree layout; screenshot archived; both test lanes + P1–P3 acceptance
green. LAST `return false` action stub is gone.

**CORRECTION (user, 2026-07-16):** this port missed the actual Mac design.
The T19a scouting notes reduced hero mode to its geometry (hero left,
"carousel" right) and both the design and the implementation shipped a
static layout that stacks the *live* panes in the right column. The real
Mac hero mode is a maximized hero pane with a right-side vertical carousel
of *thumbnail snapshots* you swap between, with animations, selection
chrome, a draggable divider, and scroll — none of which was ported. The
keybind/toggle/focus/tree-change plumbing from T19 is still valid and
reusable. See T58 (re-design) / T59 (implement); full behavioral spec of
the Mac implementation is recorded in the T58 section.

## T20 — `+new-remote-window --host/--port` direct TCP (Phase G)

Un-guard the CLI; dial with `src/remote` (tcp_dial/connection) + termio
`.remote` backend; open window (same call shape as the Swift flow).

*Validation:* from the box, connect to a test agent (`--listen`, use
`GHOSTTY_AGENT_LOCK` override per memory) — type/read works.

*Evidence (done 2026-07-15, 2ed989866 + a27cb90a1):* new
`test/win32/ipc-remote.ps1` ALL PASS on the box vs a loopback
`ghoztty-agent --listen` (agent needs `-Dtarget=x86_64-windows-gnu`):
dial+open, send-keys→read round-trip THROUGH the agent, `--command`
output visible, dial-failure error byte-matches the Mac
("failed to reach h:p: the agent is not running or not reachable"),
relay args refused (T21), `+close` teardown clean. Both test lanes +
P1–P3 + when-idle stayed ALL PASS. Design: handler dials on the GUI
thread (Mac parity), `Window.remote_dialed` owns the `tcp_dial.Dialed`
(torn down after `cleanupAllSurfaces`), `Surface.Overrides.remote`
carries conn + REMOTE-native cwd/shell/command into `remoteBackend()`.
Found+fixed two latent bugs: (1) Winsock — `posixRecv/Send` checked
`posix.errno`, which Winsock never sets → `@intCast(-1)` panic on the
pump thread at first peer close; now SOCKET_ERROR/WSAGetLastError +
`closesocket` (a27cb90a1). (2) config wipe — surface-scoped soft
`reload_config` re-derived EVERY surface from the app config, wiping
per-surface overrides (`wait-after-command` → remote `--command`
window closed itself); handler now honors the surface target and App
seeds `config_conditional_state` from the OS theme at startup so
surface-birth color reports are no-ops (2ed989866). Splits/tabs in a
remote window still spawn LOCAL shells (remote split inheritance is
part of T22-era work). Session restore (ATTACH) not in scope.

## T21a — Browser sign-in + DPAPI creds + `+relay-login` CLI (Phase G)

Split from T21 2026-07-15 (sizing rule; T21b is the other half). The
sign-in machinery, Mac `RelayAccount`/`GoogleOAuth` parity in Zig:

- `src/remote/google_oauth.zig`: PKCE (S256), authorization URL, loopback
  code receiver, token exchange/refresh (needs a form-POST helper in
  `http_client.zig`), ID-token claims parse (email/exp/picture). The Mac
  reference is `macos/Sources/Features/Remote/GoogleOAuth.swift`; the
  agent's `enroll.zig` browser-open helper is reusable.
- Client account store: `{client_id, client_secret?, refresh_token,
  email}` DPAPI-encrypted (CryptProtectData, per-user) at
  `%LOCALAPPDATA%\ghoztty\account.dat`, atomic write (tmp+rename, like
  `saveRelayEnv`). Client id/secret come from
  `GHOSTTY_GOOGLE_CLIENT_ID`/`GHOSTTY_GOOGLE_CLIENT_SECRET` env or
  `--client-id=`/`--client-secret=` flags at login and are PERSISTED with
  the creds so GUI-side refreshes need no env.
- CLI verbs `+relay-login` / `+relay-logout` (run fully in the CLI
  process — no IPC; the GUI only READS the store). Login: PKCE + open
  default browser + loopback redirect + code exchange → save.
- Token-resolution seam in the win32 GUI grows the account tier:
  explicit `--token` → account ID token (refresh grant) →
  `GHOSTTY_RELAY_TOKEN` env (T21b shipped the two outer tiers).

*Validation:* unit tests (PKCE/URL/claims/store round-trip) in both
lanes; on-box fake-issuer E2E driving `+relay-login --no-browser` end to
end (PowerShell HttpListener as Google); then a relay window opened with
NO --token (account tier). Production Google sign-in needs the user's
Desktop OAuth client id (password manager) — leave the exact command in
the log for the user if not available on the box.

*Evidence (done, 64c4329c2):* on-box 2026-07-15. Both unit lanes green
(`-Dapp-runtime=none` and `-Dapp-runtime=win32`) — PKCE S256 (RFC 7636
Appendix B vector), auth-URL params, form-encode escaping, JWT claims
decode, expiry math, redirect-target parse, and the DPAPI account-store
round-trip (with/without client secret, SignedOut on missing file,
idempotent delete). New `test/win32/ipc-relay-login.ps1` ALL PASS: a raw
TCP fake-Google token endpoint (`GHOSTTY_OAUTH_TOKEN_ENDPOINT` injection)
+ simulated browser drives `+relay-login --no-browser` through PKCE +
loopback redirect + code exchange to a written, non-plaintext
`account.dat` ("Signed in as e2e@example.com"); `+relay-logout` removes it;
a dead token endpoint makes login exit nonzero with "Token exchange
failed" and no account written; and — with a live local relay+agent whose
`DEV_CLIENT_TOKEN` is the minted JWT — `+new-remote-window --relay/--device`
with NO `--token` opens and registers a window via the account tier. The
existing `ipc-relay.ps1`, `ipc-remote.ps1`, `ipc-p1/p2/p3.ps1` all still
ALL PASS. Key implementation notes: the loopback receiver must use raw
`ws2_32.recv/send` (like `socket_stream.zig`) — `std.net.Stream.read/write`
does `ReadFile`/`WriteFile` on the WSA_FLAG_OVERLAPPED socket and fails
with ERROR_INVALID_PARAMETER (87); `json.parseFromSlice` needs
`.allocate = .alloc_always` where the parsed value outlives its source
buffer (claims payload, token response body); `advapi32` + `crypt32` are
linked whenever the target is Windows because the store is reached from
both the win32 GUI and the CLI/`none` graphs. Production Google sign-in
(real client id from the user's password manager):
`ghoztty +relay-login --client-id=<id> --client-secret=<secret>`.

## T21b — Relay dial path in win32 GUI (Phase G)

Split from T21 2026-07-15. `+new-remote-window --relay=<base>
--device=<id> [--token=<tok>]` dials through the rendezvous relay via the
shared `src/remote/relay_dial.zig` (same call shape as the Mac
`ghostty_remote_connection_new_relay`), synchronous on the GUI thread like
T20. Token tiers for now: explicit `--token` → `GHOSTTY_RELAY_TOKEN` (the
CLI already forwards its env as `--token`); account tier lands with T21a.
`relay_dial` gains the `http://`/`ws://` → plaintext-`ws://`
loopback-test-only mapping (same rule as agent `--relay` + `ws_client`).
Window owns the dialed transport as a union (tcp | relay).

*Validation:* `test/win32/ipc-relay.ps1` — build+run a LOCAL relay
(`go build ./relay`, DEV_AUTH=true), enroll a device via
`POST /v1/client/devices`, run a loopback agent `--relay=http://…`, then:
open (happy path), round-trip (send-keys→read), --command, bad token ⇒
clean error, tokenless ⇒ "not signed in", agent killed under a live
window ⇒ no GUI hang (`+list` still answers). Update `ipc-remote.ps1` §5
(relay-refusal is gone). Both unit lanes green.

*Evidence (done, 89e31b7fb):* on-box 2026-07-15: `ipc-relay.ps1` ALL PASS
on the FIRST full run — relay dial, agent OPEN, echo round-trip via
+send-keys/+read, --command through the remote shell, tokenless refusal,
bad-token clean error, agent killed under a live window (GUI kept
answering `+list` and `+close` completed within timeout, no hang/crash).
`ipc-remote.ps1`, `ipc-p1/p2/p3.ps1` ALL PASS; both unit lanes green.
The E2E runs every CLI call through a hard-timeout runner so a hung GUI
fails the script instead of hanging it. Note: `zig build` needs
`ZIG_GLOBAL_CACHE_DIR=D:\zig-global-cache` on this box (cross-drive
Run-step assert in zig 0.15.2 otherwise).

## T22a — Machine chooser design (win32) (Phase G)

The GUI counterpart to `+new-remote-window`: a native picker (ctrl+shift+n)
that lists the signed-in account's enrolled machines and opens the selected
one, so the remote flow is reachable without the CLI. T22 was too big for one
context (new Zig HTTP directory client + a native list dialog + keybind/menu
wiring + the open flow), so it is split: **T22a** (this design) → **T22b**
(the Zig device-directory client) → **T22c** (the win32 dialog + trigger +
open). Reconnect/restore manifests (WP-D2) stay a stretch goal, out of all
three.

### Reference (Mac)

Cmd-Shift-N opens `MachineChooserView` (`macos/Sources/Features/Remote/`),
a filterable list over `MachineRegistry.machines`. The registry's machines are
the account's relay devices, fetched live from `GET /v1/client/devices`
(`RelayDirectoryClient`, response `{"devices":[{id,name,hostname,online}]}`)
whenever the chooser opens and re-polled while open, plus a persisted
names/hostnames cache seeded at launch, plus any direct-TCP entries. Selecting
a row dials that machine (relay: `--relay`/`--device`; TCP: `host:port`) and
opens a window — the same dial + `createWindow` the IPC `handleNewRemoteWindow`
already does on win32. The Mac view also carries a metrics probe, activity
monitor, rename/delete, and restore — all **out of scope** here.

### Decisions (pinned for T22b/T22c)

1. **Enrolled-machines source = the relay device directory.** "Enrolled" =
   the signed-in account's relay devices, so T22b implements a Zig client for
   `GET {base}/v1/client/devices`. Base from `GHOSTTY_RELAY_BASE`
   (default `https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com`, matching
   `RelayDirectoryClient.defaultBase`). Bearer via the SAME tiered resolution
   the remote dial already uses in `IpcHandlers.zig`
   (`resolveAccountToken` → `resolveEnvToken`); no token ⇒ the chooser shows an
   empty list with a "sign in with +relay-login" footer, never an error.
   Transport reuses `src/remote/http_client.zig` `getAuth` (already does
   `Authorization: Bearer`), so T22b is a thin wrapper: build URL, GET, parse,
   map 401/404/other onto typed errors (mirror `DirectoryError`).

2. **T22b is a pure data layer, unit-tested in the none lane.** The parse
   (JSON → `[]Device{id,name,hostname:?,online}`), URL join (base + path, with
   or without a trailing slash on base), and status→error mapping are pure and
   get none-lane unit tests. The live HTTP GET itself is exercised on-box in
   T22c against the account (or a fake `GHOSTTY_RELAY_BASE` endpoint, the same
   fake-issuer trick `ipc-relay-login.ps1` uses). Keep it in
   `src/remote/relay_directory.zig` next to `relay_account.zig`/`relay_dial.zig`.

3. **Trigger = ctrl+shift+n, wired win32-native (NOT a new core binding).**
   There is no `input.Binding.Action` for "new remote window" (Mac drives it
   from an AppKit menu, not a keybind), and adding a core action variant is a
   cross-platform change out of scope for a Windows parity task. So intercept
   ctrl+shift+n in the win32 keyboard path and call a `Window`/`App` method that
   opens the chooser — the same shape as ctrl+shift+r, except ctrl+shift+r rides
   the existing `prompt_title` core action while this one is handled locally.
   Confirm the chosen chord doesn't collide with an existing win32 binding
   before wiring (grep the ctrl-mirror block in `Config.zig` ~6880).

4. **"Menu item" = command-palette entry (Windows has no menu bar).** win32
   Ghoztty exposes actions through the command palette (`palette_entries` in
   `Surface.zig`) and context menus, not a Mac-style menu bar. Add a "New Remote
   Window" command-palette entry as the discoverable/"menu" affordance. Because
   palette entries dispatch `input.Binding.Action`s and there is no remote
   action (decision 3), the palette entry can't be a plain `.action` row; T22c
   picks the mechanism — either a small palette special-case that calls the same
   open-chooser method, or the minimal viable path is keybind-only for the first
   cut with the palette entry folded in if it's cheap. Keybind is the must-have
   (the user's explicit ask); the palette entry is the nice-to-have.

5. **Dialog = native win32, modeled on `RenameDialog.zig` (the T50
   pattern-setter).** A modal owned popup with a filter edit + an owner-drawn
   list (or a `LISTBOX`/`SysListView32`) of rows: a "Local" row first, then one
   row per device showing name + a subline (hostname / online dot). Keyboard:
   type to filter, Up/Down move selection, Enter opens the highlighted row,
   Escape cancels — the RenameDialog key-routing backreference pattern
   (`Window.rename_dialog`) generalizes to a `Window.machine_chooser`. Live
   re-poll while open is a nicety; the first cut may fetch once on open.

6. **Open = reuse the existing dial path.** Selecting a device runs the same
   relay dial + `createWindow(.{ .surface_overrides = &.{ .remote = … } })`
   that `handleNewRemoteWindow` already performs for `--relay`/`--device`;
   factor that dial+open into a shared helper both the IPC handler and the
   chooser call, so there is ONE remote-open path. Local row → ordinary
   `createWindow` (the `.new_window` path).

### T22b validation (when implemented)

`zig build test -Dapp-runtime=none` green with new unit tests: URL join for
base with/without trailing slash; parse of a well-formed `{"devices":[…]}`
(incl. a device with no `hostname`); parse of an empty list; 401→unauthorized,
404→notFound, 500→http(500) mapping; a garbage body → badResponse.

*Evidence (T22b DONE 2026-07-15, 7ec2c7119):* implemented as
`src/remote/relay_directory.zig` — a pure data layer per the T22a decisions.
Public surface: `Device{id,name,hostname:?,online}`, `ListResponse`,
`classifyStatus(u16) ?DirectoryError` (`.unauthorized`/`.not_found`/`.{http}`),
`joinUrl` (trailing-slash-tolerant), `parseDevices` (`.alloc_always` so the
parse outlives a freed body — the lifetime `listDevices` relies on),
`listDevices` (the live GET wrapper composing `joinUrl` + `http_client.getAuth`
+ `classifyStatus` + `parseDevices`; exercised on-box in T22c), and
`resolveBase`/`default_base` mirroring `RelayDirectoryClient.defaultBase`.
Registered in `main_ghostty.zig`'s test aggregate so its 11 unit tests run in
BOTH lanes; `zig build test -Dapp-runtime=none` AND `-Dapp-runtime=win32` both
green (exit 0). No runtime change ⇒ P1–P3 + `ipc-relay*.ps1` unaffected. The
live GET itself lands in T22c (needs the account or a fake `GHOSTTY_RELAY_BASE`).

### T22c validation (when implemented)

On-box: ctrl+shift+n opens the chooser; with an account signed in (or a fake
`GHOSTTY_RELAY_BASE` serving a canned device list) it lists the enrolled
machines; selecting one opens a working remote window (echo round-trips via
`+send-keys`/`+read`, as in `ipc-relay.ps1`); Escape cancels cleanly; no
account ⇒ empty list + sign-in hint, no crash. Both unit lanes green; P1–P3 +
`ipc-relay*.ps1` stay ALL PASS. Add a `test/win32/` check where scriptable
(the dialog itself is GUI, so at minimum assert the palette/keybind path
reaches the open helper, e.g. via a debug log line the script greps).

*Evidence (T22c DONE 2026-07-15, 4e7edfc9b):* implemented per the T22a
decisions. `src/apprt/win32/MachineChooser.zig` is a modal owned popup modeled
on `RenameDialog` (dark chrome, native filter `EDIT` + `LISTBOX` + Open/Cancel,
DPI-scaled layout): type to filter, Up/Down navigate, Enter opens, Escape
cancels — keys routed from the main loop via `App.machineChooserOwning` +
`handleKey`, exactly like the rename dialog (decision 5). The device list is
fetched once on open via `relay_directory.listDevices` (synchronous GET on the
GUI thread); no credential or a fetch error degrades to a Local-only list plus
a footer hint, never a crash (decision 1). Selecting a device dials + opens
through the new `App.openRelayWindow` — the ONE relay-open path (decision 6),
factored out of `handleNewRemoteWindow` so the IPC verb (TCP + relay) and the
chooser share it; the IPC error strings still byte-match. Trigger is
ctrl+shift+n intercepted locally in `Surface.handleKeyEvent` (decision 3 — no
core action exists for "new remote window"; shadows the cross-platform
ctrl+shift+n → new_window default on Windows only, ctrl+n still opens a plain
local window, Linux untouched), plus a "New Remote Window" command-palette
entry special-cased in `executePaletteSelection` (decision 4).
`IpcHandlers.resolveToken` was exposed for the chooser to reuse the account →
env token resolution the dial uses.

*Validation:* pure logic (`filterRows`, `clampSelection`, `nextFocus`,
`layout`, `containsIgnoreCase`) unit-tested in both lanes (registered in
`src/apprt/win32.zig`); `zig build test -Dapp-runtime=none` AND
`-Dapp-runtime=win32` green; the win32 debug GUI links clean. On-box
`test/win32/ipc-machine-chooser.ps1` ALL PASS — drives the REAL ctrl+shift+n
chord into the surface, asserts the `GhozttyMachineChooser` window opens with
caption "New Remote Window", that it performed `GET /v1/client/devices`
against a loopback fake directory (the deterministic positive control — only
happens if the chooser actually opened and ran its fetch), and that Escape
closes it with no crash. P1–P3 + `ipc-relay*.ps1` stay ALL PASS (the shared
open-path refactor did not regress the `+new-remote-window` verb). The live
`listDevices` GET the T22b evidence deferred is now exercised here.

*Validation (T22a, design):* the split is recorded in the tracker (T22a/b/c
rows, T51 dep updated) and this section pins the data source, trigger, dialog
model, and open path for the implementer. No code.

## T23 — MSI fix → uninstall entry works (Phase H)

Root cause known: `RemoveExistingProducts` + versionless keyfiles deletes
the exe on major upgrade ("same component with higher versioned keyfile"
skip). Fix: real per-build file versions on the exe resource AND/OR
sequence RExP after InstallFiles; distinct component GUID strategy per
`windows-amd64-plan.md` postmortem. Pipeline:
`dist/windows-installer/build-msi.sh` (UpgradeCode
`5EB02044-7F06-498B-B7A9-7EFD65486CFB` is permanent; version scheme
`yy.m.dNN`).

*Validation:* on box — install MSI vN, then vN+1 over it: exe present and
launches after upgrade; "Ghoztty" appears in Apps & Features; uninstall
removes it cleanly.

**DONE 2026-07-19.** Diagnosed by dumping the actual MSI tables (Docker
`debian:stable` + msitools, the T70 recipe): **wixl leaves `File.Version`
EMPTY** (it cannot read PE resources), so Windows Installer treated the
packaged exe as UNVERSIONED vs the versioned installed exe (static
0.1.0.0 rc), refused the overwrite at costing, and the early RExP then
deleted the old copy — the 26.7.502 vanishing exe. RExP placement was
never the bug (After="InstallValidate" since day one); costing simply runs
before RExP removes files, so ANY skip becomes a deletion. Fixes, all in
the build pipeline (no runtime code):

- `-Dwindows-file-version=a.b.c.d` (Config.zig → GhosttyExe.zig → rc `/d`
  defines in `dist/windows/ghostty.rc`) stamps a real per-build
  FILEVERSION (`yy.m.d.NN`, strictly increasing); dev builds keep 0.1.0.0.
- `build-msi.sh` reads the exe's ACTUAL PE version (VS_FIXEDFILEINFO
  signature scan — authoritative even under `--skip-build`) and patches it
  into the MSI File table post-compile (msiinfo export → edit → msibuild).
- MsiFileHash table emptied: hash-match skips on unchanged unversioned
  share/ files would also become deletions; without hashes the
  created/modified-date rule always recopies MSI-installed files.
- `wixl -a x64` (was an x86 "Intel" package → WOW6432Node registration).
- New `--test-identity <Name>` builds a throwaway product (own name, dir,
  UpgradeCode, registry key, component-GUID namespace) so on-box E2E never
  touches the real product. Real-identity GUIDs unchanged.

*Evidence:* `test/win32/msi-upgrade.ps1` ALL PASS (33) ×3 on-box
2026-07-19 — v1 install (exe versioned, 526 files, ARP entry, PATH entry,
`+version` runs), v2 major upgrade (exe PRESENT + version bumped, all 526
files survive, zero "Disallowing installation" lines in the verbose log,
single ARP entry with new ProductCode), clean uninstall (dir + ARP + PATH
all gone), and a **ghost-recovery cycle** (registered product with files
deleted behind the installer → v2 upgrade lays every file down fresh).
Recipe: `zig build -Dapp-runtime=win32 -Doptimize=Debug
-Dwindows-file-version=26.7.19.1` → `build-msi.sh --skip-build
--test-identity GhozttyT23Test --build-num 1 --version t23v1 --out
zig-out/t23-v1.msi` (Docker `msitools wixl python3 git` image), same with
`.2`/`--build-num 2`; then `msi-upgrade.ps1`. Real-identity MSI verified
x64 + versioned + hash-free. Both test lanes + P1–P3 green.

**Box note:** the broken 26.7.502 "Ghoztty" product is still REGISTERED
on this box (HKLM WOW6432Node ARP entry, files long gone). Do NOT
`msiexec /x` it manually — its RemoveFiles would delete same-path files
out of the live script-delivered `%LOCALAPPDATA%\Programs\Ghoztty`
install. The first real fixed-MSI install (higher ProductVersion, same
UpgradeCode) majors-upgrades over it and cleans it — exactly the
validated ghost-recovery scenario. That rollout belongs to T24/T38.

## T24 — Windows release channel + enable update check (Phase H)

Publish Windows builds as GitHub releases tagged `win-vX.Y.Z`; remove the
`if (true) return;` in `startUpdateCheck`; on newer tag → notify with a
link (portable) or download+launch MSI (once T23 lands). Decide notify-only
vs auto-install and record here.

*Validation:* box on older version + newer tag published → update prompt
appears within the check interval; following it lands the new version.

**Decisions (recorded 2026-07-19):**

- **Channel:** GitHub releases on `dzearing/ghoztty` tagged `win-vX.Y.Z`,
  created `--latest=false` so the Mac `releases/latest` flow is untouched;
  asset `Ghoztty-X.Y.Z-x64.msi`. The check fetches the releases LIST
  (newest-first) and scans for the first `win-v` tag — `/latest` points at
  the Mac channel. Windows semver line starts at win-v1.4.1 (seeded from
  the zon base 1.4.0); T38 may re-align with the Mac channel when the
  release processes merge.
- **Notify-only, no auto-install:** the MSI deliberately has no taskkill
  action (T23), so installing over a running terminal hits files-in-use;
  the balloon links to the specific release page instead. Manual
  `check_for_updates` reports up-to-date/failed in a balloon too.
- **Gating:** automatic checks run ONLY in builds stamped
  `-Dwindows-update-check` (set by `build-msi.sh --semver`, i.e. MSI
  channel builds). Dev/portable/T36-script-refreshed builds never phone
  home or nag — the daily-driver install on this box runs ahead of the
  channel and must not balloon hourly. `auto-update = off` disables auto
  checks (`download` treated as `check`: notify-only); manual checks
  bypass all gates. 1h throttle unchanged
  (%LOCALAPPDATA%/ghoztty/update_check_at).
- **Version identity:** release exes are stamped
  `-Dversion-string=X.Y.Z+<short-hash>` so exe semver == tag semver
  (compare is exact; build metadata ignored by semver order, and the hash
  keeps `+version` provenance). MSI ProductVersion stays date-based
  (`yy.m.dNN`, T23) — Windows-Installer upgrade ordering is independent
  of the channel semver.
- **Test hook:** `GHOZTTY_UPDATE_URL` overrides the feed URL, force-
  enables the check in non-channel builds, and bypasses the throttle;
  `file://` values are read directly (WinINet rejects file URLs).
  Publishing: `scripts/publish-windows-release.ps1 -Version X.Y.Z`
  (native ReleaseFast build → Docker msitools-local MSI → gh release).

*Evidence (done 2026-07-19):* `win-v1.4.1` published live
(https://github.com/dzearing/ghoztty/releases/tag/win-v1.4.1, asset
`Ghoztty-1.4.1-x64.msi` 17.5MB, exe stamped `1.4.1+3b0c3bbde`, v1.17.0
still holds the GitHub "Latest" flag). `test/win32/update-check.ps1`
ALL PASS (12) ×3 on the Debug build: canned-feed newer→"update
available"+balloon / mac-only→"no win-v release" / older→"up to date",
dev-build gate (no override → silence), live-channel smoke (real API
finds win-v1.4.1). The channel-build branch of the no-override scenario
was additionally proven against the published ReleaseFast exe (auto check
→ "up to date (current=1.4.1+3b0c3bbde latest=win-v1.4.1)"). Provenance
grew an `update_check` field (version verb, `+list` data.build [golden
updated], `+version` both sections) so any pane can ask "will this
install notify me?" — ipc-version.ps1, P1–P3, and both test lanes green.
The pre-fix bug that `fetchLatestVersion` compared against `/latest`
(the MAC channel) is gone: the scan is win-v-prefix-only. Box note: the
26.7.502 ghost ARP entry stays until the user installs a real channel
MSI (ghost-recovery validated in T23); the T36 script flow is untouched.

## T85 — FIX: new windows don't remember size (Phase I)

User, 2026-07-19 (mid-T24, watching test windows open): "every windo you
are opening is tiny. why aren't you remembering the size of new windows,
they're all this silly small size." Root context: win32 sizes new windows
from `window-width`/`window-height` config, else a hardcoded default —
NOTHING persists the last user-chosen size. macOS gets frame memory from
the OS (autosave); GTK persists via window-save-state. Implement the
Windows-native equivalent:

- Persist the outer window size (and per Windows convention likely the
  maximized flag; decide on position) when the user finishes an
  interactive resize/move (WM_EXITSIZEMOVE) — storage: same
  UserDefaults-style area the win32 apprt already uses (registry or
  %LOCALAPPDATA% file; follow the T66 initial_size pattern).
- New windows use: explicit `window-width/height` config > remembered
  size > current default. `reset_window_size` (T66) keeps resetting to
  the CONFIG/default size, not the remembered one (it's the escape
  hatch); decide + record.
- Respect multi-monitor sanity (clamp to the target monitor's work
  area).

*Validation:* on box — resize a window, close it, open a new window
(ctrl+shift+n / `+new-window` / app relaunch): new window matches the
remembered size; explicit config wins; reset_window_size still resets;
acceptance script with 3 runs.

*Evidence (done 2026-07-19):* New pure module
`src/apprt/win32/window_memory.zig` (parse/format/clamp, unit tests in
both lanes) + storage at `%LOCALAPPDATA%\ghoztty\window_placement`
(`…-debug` for Debug builds — same coexistence pattern as the debug IPC
pipe, so test/dev runs never pollute the release memory). Format:
`<outer-w> <outer-h> <maximized 0|1>`. Persistence is
user-interaction-only: `WM_EXITSIZEMOVE` (drag resize/move, reads
GetWindowRect; aero-snap-to-maximize handled via IsZoomed) and
maximize/restore TRANSITIONS in `WM_SIZE` (maximized stores the RESTORED
size from `WINDOWPLACEMENT.rcNormalPosition`); programmatic resizes
(`initial_size`, `reset_window_size`) never write it. Creation
precedence: `window-width/height` config > memory (clamped to the
primary work area, SPI_GETWORKAREA) > 800×600; first show honors the
remembered maximized flag, and the `maximize` config is now honored on
win32 too (SW_MAXIMIZE at first show). Decisions: position NOT
persisted (cascade + `window-position-x/y` govern it);
`reset_window_size` resets the current window only and leaves the
memory untouched (escape hatch, T66 semantics intact). Validated:
`test/win32/window-size-memory.ps1` ALL PASS (20) ×3 — fresh-default,
drag-persist, relaunch-at-remembered, maximize persistence + restored
size, open-maximized-from-memory, config-beats-memory, work-area clamp,
corrupt-file fallback, reset-escape-hatch; `reset-window-size.ps1` ALL
PASS (10; converted to focus-free posted-F-key injection because
SendInput chords abort while the user holds foreground — PostMessage
WM_KEYDOWN to the surface HWND dispatches bare-key bindings without
focus, positive control retained); P1–P3 + both unit lanes green.

## T25 — Full conformance checklist, spec §8 end-to-end (final gate)

Run spec §8 items 1–10 end-to-end on the box from a fresh start, including
the CLAUDE.md three-pane example verbatim. Update spec §9 status table.
Then: macOS regression build green, merge to main per the working
agreements.

*Evidence (done, on-box scope, 2026-07-19):* new
`test/win32/conformance.ps1` runs §8 items 1–7 end-to-end from a cold
start: auto-launch + idempotent `ide` window really running the editor
(netrw asserted via `+read`), the CLAUDE.md three-pane layout (Windows
equivalents documented in the script: git-bash `vim`/`tail`, `powershell`
for `zsh`; git usr\bin prepended to PATH so the commands run verbatim),
`+read --lines=5` byte-accurate against a live `tail -f` (appender must be
`cmd >>` — msys tail's handle denies PowerShell `Add-Content`), send-keys
echo + C-c interrupt (post-T84) + `a\tb\n` expansion proven by a
`[Console]::In.ReadLine()` comparer pane, set-state aggregation + OSC 7777
round-trip, rename override, rearrange to 30/70 named-pane layout,
second-GUI-launch forwarding, per-target teardown + silent missing-target
close. **ALL PASS ×3.** Item 8: `hero-mode.ps1` ALL PASS (60) — after
fixing the harness foreground grab (attach-to-foreground-thread + Alt tap;
unattended box had a browser foreground; same weakness filed for the other
scripts as T86). Item 9: `ipc-relay.ps1` ALL PASS (fake-relay E2E; a live
Mac-device dial needs the Mac seat). Item 10: T17's zero-modification
skill session stands, and items 1–6 re-execute those same skill flows
verbatim. P1–P3 ALL PASS and both test lanes green at HEAD the same day.
Spec §9 table filled in. Remaining tail (Mac seat, filed as T87): macOS
regression build green, then merge to main per the working agreements.

## T26 — OS color-scheme sync (Phase I)

win32 never calls `core_surface.colorSchemeCallback` (zero call sites), so
OSC 10/11 light/dark queries and `light:`/`dark:` conditional config never
react to the Windows theme. Implement: read the OS apps-light/dark setting
at surface init, report via colorSchemeCallback, and re-report on
`WM_SETTINGCHANGE` (the handler exists but only re-reads scrollbar theme).
Chrome (`window-theme=system`) already reacts; this is the *terminal-side*
signal.

*Validation:* on box, flip Windows dark↔light with the app open — a
`theme = light:…,dark:…` config switches live; an app querying OSC 11 sees
the change.

*Evidence (done):* on-box 2026-07-12: `theme = light:Adwaita,dark:GitHub
Dark` config + screenshot pixel oracle — pane renders #101216 when the OS
is dark, flips LIVE to #ffffff on a light flip, and back, no restart.
Found+fixed the real bug the task implies: WM_SETTINGCHANGE broadcasts
reach TOP-LEVEL windows only, so the handler had to live in
Window.windowWndProc, not the surface proc.

## T27 — PowerShell shell integration (Phase I)

`src/shell-integration/` has bash/zsh/fish/elvish/nushell only — nothing
for pwsh, and cmd can't support it. So prompt marks, cwd reporting, and
title reporting are dead under the default Windows shells. Write a pwsh
integration script (Windows Terminal's shell-integration docs and the
existing scripts are references), wire it into the shell-integration
detection/injection for `pwsh.exe`/`powershell.exe`.

*Validation:* on box with pwsh — cwd reporting works
(`window-inherit-working-directory` honors it), prompt-mark scroll works,
no visible prompt corruption.

*Evidence (done):* on-box 2026-07-12: new
`src/shell-integration/powershell/ghostty.ps1` (OSC 133 marks, OSC 7 cwd,
OSC 2 title) dot-sourced via `-NoExit -Command . '<script>'`; detection
for pwsh/powershell(.exe); unit tests for detection + injection +
non-interactive bail-out. **Found the real blocker: `reportPwd` was
hard-disabled on Windows in the CORE** (`log.warn("reportPwd unimplemented
on windows"); return;`) — no shell could EVER report cwd. Implemented it +
native path normalization (`/D:/x` → `D:\x`). Validated: pane cwd tracks
`cd` live (D:\git\ghoztty → C:\Windows → C:\Users).

## T28 — Minor action no-ops cleanup (Phase I)

Bundle of small `return true`-but-do-nothing gaps, each cheap: `readonly`
(visual indicator, e.g. tab-title glyph), `key_sequence`/`key_table`
(pending-sequence indicator, e.g. status bubble reuse), `pwd` (append to
window title or tooltip), `color_change` (handle fg/cursor, not just bg),
`close_all_windows` (close each window with confirm, distinct from quit),
notification click→focus round-trip (verify it works; fix if not).

*Validation:* per-item spot checks on box; note each here.

*Progress (in-progress):* DONE so far: close_all_windows now closes each
window honoring confirm (was: quit the whole app - a real bug);
color_change now retints the scrollbar on foreground/cursor (was:
background only). NOT yet done (each is a small next chunk): readonly
indicator, key_sequence/key_table pending indicator, pwd action (now that
OSC 7 works on Windows via T27), notification click-to-focus round-trip
verification.

## T29 — Mac-side: fix action fallthroughs to showChildExited (Phase I)

Audit found `toggle_window_decorations`, `size_limit`, `quit_timer`, and
`toggle_tab_overview` in the Mac app's action dispatch falling through to
`showChildExited` (apparent bad merge in `Ghostty.App.swift` switch).
Verify against the Mac source; if real, fix the switch. Win32 is
unaffected (it implements these properly).

*Validation:* Mac build: toggling window decorations via keybind works;
`quit-after-last-window-closed` delay still honored. Run the Mac
regression build.

## T30 — Mac-side: IPC dial must not modal-block the app/IPC server (Phase I)

Found live 2026-07-12: `ghoztty +new-remote-window --relay --device` against
the release app, dial failed (box agent presumed down), and
`AppDelegate.openRemoteWindow` popped `NSAlert runModal` ON THE MAIN THREAD
from the IPC path (`IPCServer.handleNewRemoteWindow` waits on a semaphore →
serial IPC queue wedged). With the screen locked nobody can dismiss → ALL
CLI IPC to the app is dead until the user unlocks and clicks the alert.
The handler already routes the signed-out case through the IPC response
("no GUI alert from the IPC path") — dial-failure must do the same: when
the dial was IPC-initiated, return the error in the IPC response and never
`runModal`. Menu-initiated dials may keep the alert.

*Validation:* Mac regression build; `+new-remote-window` to a dead device
returns a CLI error promptly (no alert, no wedge); a second `+list` during
and after the failed dial responds normally.

## T31 — `+list --pid` filter + real pid leaf data on Windows (Phase I)

Found 2026-07-12 trying to run the user's `/reset-context` skill on the
box: it identifies the calling session's pane via
`ghoztty +list --tty="$(ps -o tty= -p $PPID)"`, but on Windows (a) the
CLI ignores `--tty` (prints the full list), (b) every leaf reports
`tty:""`/`pid:0` (ConPTY backend doesn't surface them — T05 note), and
(c) MSYS `ps` lacks `-o`, so the skill's tty probe itself needs a
Windows-appropriate identity. Design the Windows equivalent (likely:
`+list --pid=<pid>` walking the ConPTY child process tree, or match on
GHOZTTY_SURFACE_ID) and implement the filter + real pid data. This blocks
`/reset-context`, `/wt`, and other pane-aware workflow skills on Windows.

*Validation:* from a Claude Code session inside a debug-ghoztty pane, the
skill's Step-1 probe (or its documented Windows replacement) returns
exactly that pane's name.

*Evidence (done):* on-box 2026-07-12: +list leaves report the real shell
pid (verified live cmd.exe); `+list --pid=<any descendant>` resolves the
owning pane by Toolhelp32 ancestry (self + grandchild + unknown-pid-error
all green); ProcessTree walk unit-tested (cycle/self-parent guards) in the
win32 lane. tty stays "" (no ConPTY tty name) and exit_code stays null
(note). /reset-context's Windows probe: `ghoztty +list --pid=<winpid>` —
the skill (user plugin) needs its Step 1 updated to use it.

## T32 — Refactor: split IpcServer.zig; extract pure logic + unit tests (Phase J)

IpcServer.zig has grown past 1100 lines (transport + marshal + 9 verb
handlers + arg parsing + SDDL). Split: `ipc/Server.zig` (pipe transport,
marshal, shutdown), `ipc/verbs.zig` or per-verb files (handlers),
`ipc/args.zig` (parseVerbArgs/dropPrefix/wrapCommandArgv — PURE, no
win32 imports, so it compiles in the none-runtime test build like
apprt/ipc.zig does), plus unit tests for: verb arg parsing, shell argv
wrapping (pwsh/-Command vs cmd//K vs -lic), send-keys LF/CRLF→CR
normalization, rearrange layout validation (shape/direction/dupes), and
the List golden tests (already exist). App.zig (2600+) and Window.zig
(2000+): move the IPC registry into its own file; assess further splits.

*Validation:* `zig build test -Dapp-runtime=none` runs the new units;
win32 build green; P1–P3 acceptance scripts still ALL PASS.

*Evidence (done, 640457b0d, cb53bb728, 31393ce38, 4cbc3d3e3):* IPC now 5
focused modules (transport 385 lines / handlers / registry / pure args /
list model); 8 unit-test blocks in the none-runtime suite; P1–P3 ALL PASS
after every step. App.zig −330 lines (rest is the vendored action switch —
assessed, deferred).

## T33 — Native win32 test lane (Phase J)

Pure-logic tests land in none-runtime files (T32) and run everywhere.
For win32-tagged units, add/verify a `zig build test -Dapp-runtime=win32`
lane on the box and fold it into the acceptance flow docs.

*Validation:* the lane runs green on the box and is documented in the
bootstrap section.

*Evidence (done):* `zig build test -Dapp-runtime=win32` runs green
natively on the box (verified 2026-07-12); pure IPC logic also covered by
the cross-platform none-runtime lane; both documented in the bootstrap
section.

## T34 — Windows shell types, first-class (Phase J)

The Mac wraps commands in `$SHELL -lic`. The Windows translation is a
shell-flavor table (today: pwsh/powershell → `-NoExit -Command`, cmd →
`/K`, else `-lic`). Make it first-class: add `wsl`/`wsl.exe`
(`wsl.exe -- <cmd>`, and bare `--shell=wsl` opens the default distro),
`nu`/`nushell` (`-e <cmd>`? verify), `bash`/git-bash (works via `-lic`
today — verify login-shell profile loads), and document `command-shell`
values for Windows in CLAUDE.md/README. Unit-test the wrap table (T32
makes it pure). Consider `+list` showing the shell flavor per pane.

*Validation:* on box — `--command` runs correctly under pwsh, cmd,
git-bash, and WSL (if installed); unit tests cover every flavor branch.

*Evidence (done):* wrap table extended (wsl `--`, nu `-e`) + Mac-parity
keep-alive for posix flavors (`; exec "shell" -li` — git-bash panes used
to die after the command); every branch unit-tested; on-box:
cmd/powershell/git-bash markers read back + panes alive; wsl created but
box only has the locked-down docker-desktop distro (`/bin/sh: Permission
denied` — informational); pwsh7/nu not installed. CLAUDE.md documents the
Windows flavors.

## T35 — Sticky pane banner on win32 (Phase I)

Main's pane-banner feature (merged 2026-07-13): `+set-banner` CLI, OSC 7778,
`pane_banner`/`prompt_banner` apprt actions, cmd+R editor on Mac
(`SurfacePaneBanner.swift` is the reference, ~162 lines). Win32 currently
acks both actions as no-ops (App.zig ack list) and the IpcHandlers lack the
`set-banner` verb (CLI errors gracefully). Implement: banner strip above the
surface, the IPC verb, OSC routing, and a rename-style edit popup for
`prompt_banner` (ctrl+r is taken? check; Mac added cmd+shift+r for rename).

*Validation:* `+set-banner` sets/clears a visible banner; OSC 7778
round-trip from inside the pane; prompt_banner editor works.

*Evidence (done 2026-07-19):* Full parity port, per-pane like the Mac:

- `banner_markdown.zig` — pure Zig port of the Mac `BannerMarkdown`
  parser (bold/italic/underline/code/`[text](url)`-with-scheme, `\`
  escapes, unterminated-literal, nesting, 6-line cap). 14 unit tests, in
  every lane via apprt.zig.
- `BannerOverlay.zig` — WS_EX_LAYERED popup strip glued to the pane top
  (DimOverlay pattern, but NOT click-through: links open via
  ShellExecuteW with a hand cursor; other clicks focus the pane via
  deferSetFocus). GDI run painting with a per-style font cache
  (Segoe UI / Consolas for code), LWA alpha 242, strip fill =
  lighten/darken(pane bg incl. T67 tint, 0.09/0.07), bottom divider.
  Repositioning rides `Window.updateDimOverlays` → `updatePaneBanners`
  (layout, WM_MOVE, tab switch, config reload re-color live).
- `BannerDialog.zig` — "Set Pane Banner" editor (T50 dark-dialog
  pattern): multi-line ES_WANTRETURN edit prefilled with the raw source,
  Enter = newline, **Ctrl+Enter/OK = save**, Escape = cancel, Tab
  cycles; keybind **ctrl+shift+b** (cmd+r is Mac-only; plain ctrl+r is
  shell history) + palette entry "Set Pane Banner…". Editor closes if
  its pane dies (`+close` while open).
- IPC `set-banner` verb (pure `parseSetBannerArgs` in args.zig, unit
  tested): window targets hit the focused pane, `--clear`/empty clears,
  literal `\n` → line break, Mac semantics. `+list --json` leaves carry
  an additive `banner` field (source text) like `background_tint`.
- OSC 7778 was already routed by the shared core; the win32
  `.pane_banner` action now lands in `Surface.setPaneBanner`.

`test/win32/pane-banner.ps1` ALL PASS (30) ×3 on-box: +list model,
strip glued/width/height growth/6-line cap, pinned own-DC fill color +
composited alpha-blend pixel (32,32,40 over #101014), clear paths,
per-pane + window-target semantics, OSC 7778 round-trip incl. spaces,
unknown-target error, editor open/commit/cancel E2E via SendInput.
P1–P3 + both test lanes green. Harness lessons: the probe process must
be per-monitor-DPI-aware (T59a lesson — virtualized rects miss the 39px
strip), sample composited pixels via CopyFromScreen with the window
parked topmost (GetPixel skips layered windows; desktop windows pollute
point samples), and read a layered window's own DC only AFTER the
composited sample (GetDC knocks an SLWA surface out of the composite
until repaint).

## T36 — On-box release install refresh flow (Phase H)

A locally-installed release build powers daily use so `/reset-context` and
other ghoztty-IPC workflows work from on-box sessions (user directive
2026-07-13). Install: `%LOCALAPPDATA%\Programs\Ghoztty\{ghoztty.exe, share\}`
(exe+share side-by-side, same layout as the portable ZIP; resourcesDir
climbs from the exe), dir on user PATH. **Release builds must use
`-Dtarget=x86_64-windows-gnu`** — native msvc + GUI subsystem fails with
`undefined symbol: WinMain` (GhosttyExe.zig sets .Windows subsystem for
non-Debug; zig's msvc CRT expects WinMain). Refresh = rebuild ReleaseFast
gnu, re-run the copy + PATH script. Release exe speaks the
`ghoztty-<username>` pipe; Debug exes keep `ghoztty-debug-<username>`, so
both run side by side.

*Validation:* `ghoztty +list` from a fresh shell answers via the installed
release instance; `+list --pid` resolves a pane from inside it; skill-driven
`/reset-context` clears a session (the original blocked workflow).

*Evidence (in-progress, ae71b19b4 + follow-ups):* 2026-07-13: merged
origin/main (62 commits); both test lanes + P1–P3 ALL PASS post-merge;
ReleaseFast gnu exe installed + user PATH; verified: cold auto-launch,
+list, in-pane `+list --pid=$PID` → pane name, exit 0; teardown clean.
REMAINING: live skill-driven /reset-context from a session inside the
installed release (attempted at the 2026-07-15 task boundary — see log).
2026-07-15: upgrade script proven end-to-end twice (16:32 and 23:29 runs
in %TEMP%\ghoztty-upgrade.log: kill → swap exe+pdb → mirror share →
relaunch+resume); fixed the resume gap — `claude --continue` without a
prompt idles, ResumeCommand now appends "read go.md and go" so refreshed
sessions re-enter the task loop.

## T37 — CLAUDE.md symmetry mandate + dual-arch dev instructions

User directive 2026-07-13: **all new features must land in BOTH the
Windows and Mac builds — the two are to be kept symmetric.** Update the
repo CLAUDE.md to state this as a standing rule, and add clear
instructions for starting and debugging each architecture: Mac (zig build
+ Ghoztty-Debug.app, debug socket) and Windows (native Debug build with
`ZIG_GLOBAL_CACHE_DIR` on the repo drive, Console-subsystem stderr, debug
pipe, release builds via `-Dtarget=x86_64-windows-gnu`, installed-release
layout under `%LOCALAPPDATA%\Programs\Ghoztty`). Fold in the test lanes
(none/win32) and the P1–P3 acceptance scripts so either seat can validate.

*Validation:* CLAUDE.md review — a fresh session on either OS can build,
run, and debug from CLAUDE.md alone.

## T38 — Windows build in the release process (Phase H)

User directive 2026-07-13: when we release, the Windows build ships too.
Extend the release flow (currently Mac-centric; see `dist/` and the T24
release-channel work) to build/stage/publish the Windows artifacts (MSI
once T23 lands, portable ZIP meanwhile) alongside the Mac release —
same version, same tag, one process.

*Validation:* a release run produces and publishes both platforms'
artifacts with matching versions.

## T39 — Website installer link for Windows (Phase H)

User directive 2026-07-13: the website must offer the Windows installer
with the same filename conventions as the other platforms — arch and
version in the filename (e.g. `Ghoztty-<version>-windows-x86_64.msi` /
`...-portable-x86_64.zip`; match the exact existing pattern when
implementing). The site lives in the gh-pages branch (see the relay
"ghpages mirror" commits on main). Depends on T38 publishing versioned
artifacts to link to.

*Validation:* website shows a working Windows download whose filename
carries arch + version, alongside the existing platform links.

## T40 — FIX PERF: lost renderer wakeups / slow scrolling (Phase I)

Original report (user 2026-07-13): scrolling "extremely slow, not smooth
at all" in the release build while Claude Code (TUI, alt-screen) is
running.

ROOT CAUSE FOUND + FIXED: renderer wakeup notifications were 100% lost on
Windows — termio held a BY-VALUE COPY of the renderer thread's xev.Async,
and the IOCP backend's Async is pure userspace state (guard+flag+waiter
ptr), so the copy's waiter stayed null and every queueRender notify
vanished (kqueue/eventfd Asyncs share a kernel fd, so Mac/Linux never
noticed). Under heavy output the screen repainted ONLY on the 600ms
cursor-blink timer. Fix: renderer_wakeup is now `*xev.Async` through
Options/Termio/StreamHandler, pointing at self.renderer_thread.wakeup.

Also added: env-gated perf telemetry (GHOZTTY_PERF=1 → fps/max-gap,
wakeups/s, queue_render/s, pty reads/s, slow-mutex warns),
GHOZTTY_PIPE_SUFFIX endpoint override so instrumented release builds run
beside the installed app, and test/win32/wheel-scroll.ps1 (wheel = 3
lines/notch regression guard; investigated and confirmed the config
discrete default 3 already matches Windows convention — do NOT stack
SPI_GETWHEELSCROLLLINES on top, that gives 9).

*Evidence (done):* on-box 2026-07-14 ReleaseFast, 80MB visible stream
(10x `type` 8MB): BEFORE fps=1-2 with max_gap≈610ms (blink-only;
wakeups_per_s pinned at 1 while queue_render ran 36k/s into the dead
copy); AFTER fps=119-120, max_gap 9-11ms sustained, wakeups tracking load.
Debug lane: parse ceiling ~170KB/s and renderer waited up to ~1s on
renderer_state.mutex (starvation is Debug-amplified; zero slow-mutex warns
in release at 3MB/s — relevant to T48 candidate 2). Both test lanes green;
P1-P3 + wheel-scroll ALL PASS. NOTE at the time: installed release still
had the bug until the next release refresh — delivered via the 2026-07-14
23:29 upgrade run + portable/share refresh 2026-07-15 (see T49).

## T41 — Skip close confirmation when the shell is idle (Phase I)

User report 2026-07-13: closing a tab that is just cmd.exe sitting at a
prompt shows the "Processes are still running" confirmation. The Mac asks
only when something beyond the shell is running (`needsConfirmQuit` /
config `confirm-close-surface`). On Windows the shell itself is always a
live child over ConPTY, so the naive check always says "running".
Investigate: enumerate the shell's child processes (ProcessTree.zig from
T31 already walks Toolhelp32 ancestry — reuse) and confirm only when the
shell has descendants (or the foreground process differs from the shell).

*Validation:* close an idle cmd/pwsh tab → no dialog; close a tab running
a child (e.g. `ping -t`) → dialog appears.

## T42 — Remote sessions drop the user's env/PATH (Phase G)

User report 2026-07-13: a remote Windows session opened from the Mac had
none of the user's PATH entries. Likely cause: `ghoztty-agent` runs as a
service/background process whose environment block lacks the interactive
user's registry env (HKCU Environment), and the ConPTY shell inherits the
agent's env. Investigate: agent should build the user token environment
(CreateEnvironmentBlock / reading HKCU+HKLM Environment and merging, as
Windows logon does) for spawned sessions.

*Validation:* remote session's `echo %PATH%` matches an interactive local
shell's PATH (including user-scope entries like the Ghoztty install dir).

## T43 — Proper visual debug banner on win32 (Phase I, lower priority)

The Mac debug build shows a real banner; the win32 build only marks the
title (" [DEBUG]" suffix, added 2026-07-13 as an interim). Build a real
visual marker — e.g. a colored strip across the window top (the T35
banner infrastructure, once built, is the natural vehicle: a permanent
debug-styled banner row) or a tinted tab bar.

*Validation:* debug build visually unmistakable at a glance; release
build unaffected.

## T44 — FIX CRASH: rename overlay in a single-tab window (Phase I)

Pressing ctrl+shift+r in a single-tab DEBUG window crashed the whole app
(window vanished; user-observed 2026-07-13, twice). Background:
`startTabRename` used to anchor the rename Edit to `tab_rects[tab_idx]`,
which is zeroed when the tab bar is hidden (single tab,
`window-show-tab-bar=auto`) → INVISIBLE edit that steals focus ("mystery
box", user-reported on the release build; Escape dismisses it there).

Investigation notes kept for reuse: synthetic input via keybd_event chords
with correct scan codes + verified focus on `GhozttyTerminal` never fired
the binding (5 attempts; modifier state via GetKeyState vs injected input
was the leading theory) — real keystrokes fire it fine. That gap was later
solved in `test/win32/kb-actions.ps1` (AttachThreadInput+SetFocus+
SendInput; see the win32-keybind-test-harness memory note).

*Evidence (done, 7510d2cd2 + follow-up):* root cause was the
hidden-tab-bar case: tab_rects zeroed → rename Edit created invisible
while stealing focus (un-dismissable "mystery box", app looked dead). Fix
= client-area anchor fallback (7510d2cd2); on-box 2026-07-14 verified via
new `test/win32/kb-actions.ps1` (real ctrl+shift+r chord into the surface
HWND): binding fires prompt_surface_title, edit appears, Enter commits,
+list shows new title, no crash; focus-loss destroy path also exercised.
Release refresh unblocked.

## T45 — `+send-keys --when-idle` acceptance test (Phase I)

`test/win32/ipc-when-idle.ps1`.

*Evidence (done):* on-box 2026-07-13: ALL PASS (14 assertions — idle pane
sends <0.2s; busy marker holds send (job still polling at +4s, no
delivery), releases when marker scrolls out of the 10-line window;
--idle-timeout=3 releases after 3.1s). Mechanism verified correct on win32
— the reset-context incident was marker drift, not a ghoztty bug (see
T46).

## T46 — `--when-idle` busy-marker drift fix (Phase I)

Claude Code v2.1.207 no longer renders "esc to interrupt" (spinner shows
`(4m 49s · ↓ 14.9k tokens)`), so panes running current Claude Code always
looked idle and sends fired mid-turn (keystrokes queued into the busy
session, dropped by /clear). Fixed with a marker-free heuristic: busy =
marker OR tail changing between 500ms polls (spinners/timers animate every
second); idle = neither, across 3 consecutive polls (~1s — a ticking
seconds timer can never look stable).

*Evidence (done):* on-box 2026-07-14: ipc-when-idle.ps1 ALL PASS (18
asserts incl. new no-marker streaming hold: held 6.7s until quiescent;
idle static pane sends after 1.1s stability window; timeout fallback
3.1s); live hold against this session's own busy v2.1.207 pane via staged
release exe.

## T47 — ctrl+k → clear_screen default keybind on Windows (Phase I)

User report: no way to clear the console from the keyboard; action was
palette-only. Performable, so it falls through on the alternate screen
(mac cmd+k semantics); shadows readline kill-line at a primary-screen
prompt.

*Evidence (done):* on-box 2026-07-14 via `test/win32/kb-actions.ps1`:
ctrl+k at a primary-screen cmd prompt clears screen+scrollback (marker
gone from +read, clear_screen io message logged); after ESC[?1049h the
same chord matches the binding but is NOT consumed (no clear io message —
falls through to the TUI); Surface.zig clear_screen returns false on
alternate screen (verified in code + on-box).

## T48a — Root-cause the release GUI deadlock (Phase I)

DONE 2026-07-15. Full dump analysis + reproduce steps:
`t48-deadlock-dump-analysis.md`. Verdict + fix direction are summarised in
the T48 section below (they were investigated together). The re-entrant
IME/CTF `SetFocus` → `Condition.wait()` mechanism is confirmed from the dump
with debugger evidence (`~*k` / `!locks` / raw-stack walk / disasm at
`ghoztty+0x1ffa0e`). T48 (implement the deferral fix) remains todo.

## T48 — FIX DEADLOCK: release GUI freeze under busy TUI load (Phase I)

Release GUI froze (Responding=false, all 18 threads Wait, CPU delta 0)
while hosting a busy Claude Code pane; window stopped repainting, IPC
clients hung then got pipe-busy. Full minidump:
`D:\git\ghoztty\.dumps\ghoztty-9056-deadlock-20260714-183552.dmp` (install
exe of 2026-07-14 16:32, ~2bb4c802d). Top waits: EventPairLow ×2,
UserRequest. Suspect GUI-thread lock vs renderer/io under heavy TUI output
(related: T40 jerky scrolling). RECURRED 2026-07-14 21:05 (WER AppHangB1,
hang sig f7d6, installed exe; Windows closed it, no dump kept). Dump
unsymbolizable: ReleaseFast defaults `-Dstrip=true`
(src/build/Config.zig:345) so no ghoztty.pdb existed.

SAFEGUARDS in place: `scripts/watchdog-ghoztty-windows.ps1` (polls release
exe every 3s; ≥15s Responding=false → full minidump to .dumps\ + kill +
relaunch w/ claude --continue, keeps 4 dumps); release staging rebuilt
with `-Dstrip=false` (pdb now emitted); upgrade script copies ghoztty.pdb
beside installed exe.

ROOT CAUSE CONFIRMED 2026-07-15 (T48a) via cdb + MS public symbols on the
existing 744MB dump — full analysis + reproduce steps in
`t48-deadlock-dump-analysis.md`. Summary:

- **Not a lock cycle.** `!locks` = 15 CS scanned, none owned; every non-GUI
  thread is cleanly idle (IOCP / ReadFile / NVIDIA waits); the OS wait-chain
  finds only the GUI thread stuck with wait type `(null)`. No EventPairLow
  anywhere (the old "EventPairLow ×2" was WER bucket noise).
- **Mechanism:** the GUI thread calls `SetFocus` *synchronously inside its
  WindowProc*. SetFocus runs the IME/CTF cascade inline
  (`user32!ImeSystemHandler → imm32!ImmSetActiveContext →
  msctf!CtfImeSetActiveContext`), which does a synchronous `SendMessage`
  (WM_IME_SETCONTEXT) that **re-enters our WindowProc**; on that nested,
  non-pumping stack ghoztty calls `std.Thread.Condition.wait()` (Zig →
  `SleepConditionVariableSRW`, INFINITE) and blocks forever. Raw-stack walk
  + disasm at `ghoztty+0x1ffa0e` confirm the primitive and the chain.
- Same re-entrancy CLASS as the WM_GETOBJECT/oleacc hang whose fix
  (`return 0` for `OBJID_CLIENT`, App.zig:2485) was already in this build
  (`e0118f682`, ancestor of dump build `2bb4c802d`). That guard closed only
  the oleacc trigger; the **IME/CTF SetFocus path is uncovered** → recurrence.
- All three old ranked candidates refuted (details in the analysis doc).

Task split (sizing rule): **T48a = root-cause investigation → DONE** (this
context). **T48 = implement the fix** (todo, dep T48a). Fix direction:
defer `SetFocus` out of WindowProc (PostMessage a private WM_APP_SETFOCUS,
call SetFocus at the top of the message loop) so the IME/CTF cascade runs
where the thread can pump; belt-and-suspenders, once a *matching* symbolized
dump identifies the `+0x1ffa0e` subsystem, stop the GUI thread from
`Condition.wait()`-ing inside message dispatch. Candidate SetFocus-in-WndProc
sites: App.zig:2537/2546/2555/2566 + Surface/Window focus-on-click paths.
IPC pipe-busy is purely downstream (listener on the stuck GUI thread,
IpcServer.zig:294).

DONE 2026-07-15. Implemented the primary deferral fix. New
`App.deferSetFocus(hwnd)` posts a private `WM_APP_SETFOCUS` (WM_APP+5) to the
target window; the run loop performs the real `SetFocus` at the **top of the
message loop** (intercepted before Translate/Dispatch, never dispatched to a
WndProc), so SetFocus's IME/CTF cascade runs on a shallow, pumpable stack
instead of nested inside a mouse/focus WndProc under the NVIDIA WH_CALLWNDPROC
hook. Principled boundary: **defer only terminal-surface focus targets** (the
OpenGL windows that drive the IME/CTF hook path); EDIT controls and dialog
Tab-navigation keep synchronous focus (immediate typing/key routing, and they
don't trigger the nvoglv64 cascade). 23 surface-focus sites converted across
App.zig (mouse handlers + present_terminal), Window.zig (tab/split/close/hero
+ WM_SETFOCUS forward + rename-close), Surface.zig (search/palette close),
IpcHandlers.zig, QuickTerminal.zig, RenameDialog/MachineChooser close. The
belt-and-suspenders "no Condition.wait on the GUI thread inside dispatch"
half stays open pending a *matching* symbolized dump of `+0x1ffa0e` (watchdog
is now `-Dstrip=false`, so the next hang dump is symbolizable).

*Validation (done):* GUI build (`-Dapp-runtime=win32 -Doptimize=Debug`)
clean; both test lanes (`none`+`win32`) green; kb-actions.ps1 ALL PASS (25,
focus-on-input + rename-dialog deferred refocus + ctrl+k); ipc-p1/p2/p3 ALL
PASS (window/pane/send-keys unaffected). New `test/win32/focus-defer.ps1` ALL
PASS (9): PostMessage real WM_LBUTTONDOWN into each surface HWND → deferred
SetFocus lands real GUI focus on the clicked pane (verified cross-thread via
GetGUIThreadInfo().hwndFocus), and under a 1500-focus-change click storm
during heavy terminal output the GUI thread stays responsive
(SendMessageTimeout SMTO_ABORTIFHUNG returns; +list still answers — the IPC
listener lives on the GUI thread; focus still moves after the storm).

## T49 — Hero mode regression report → stale binary (Phase F)

User report 2026-07-14: hero mode "still doesn't work" on Windows despite
T19 done validation of 2026-07-12.

INVESTIGATED 2026-07-14: NO code regression on HEAD — new
`test/win32/hero-mode.ps1` geometry oracle (real chords, 3-pane) is ALL
PASS on BOTH Debug (12 asserts, incl. binding-dispatch log check) and a
fresh ReleaseFast gnu build (11 asserts): toggle on, hero seeds from
focused pane, ctrl+alt+down moves hero, toggle off restores exact tree
rects. No binding shadow (ctrl+shift+space dispatches, log-verified), no
user-config shadow (config has zero keybinds), palette arm correct,
installed 2bb4c802d DOES contain T19.

RESOLVED 2026-07-15: user's repro was almost certainly a STALE BINARY —
the box ran FOUR different ghoztty builds simultaneously (installed
release; Desktop portable exe dated JULY 5 — pre-IPC,
pre-hero-everything; a second portable instance; one running off
\\homeassistant\share dated Jul 12 pre-hero). "Not in the command palette"
was the tell: HEAD/2bb4c802d both list it. All locations refreshed to HEAD
2026-07-15 (dated .baks); windows opened before the refresh still run old
code until relaunched. T52 filed so build identity is visible in-app.

PIXEL-VERIFIED 2026-07-15 (user directive "look at its pixels"):
hero-mode.ps1 now captures PrintWindow(PW_RENDERFULLCONTENT) screenshots +
asserts rendered content per pane (distinct-color floor) + carousel ratio
~25%; screenshots human-reviewed — hero content, carousel reflow, nav
promotion all correct. Harness lesson: CopyFromScreen reads occluding
windows (first pixel run produced false blank/strip readings); PrintWindow
is deterministic (3/3 identical counts).

*Evidence (done, c795455ff + follow-up):* hero-mode.ps1 16 asserts ALL
PASS 3/3 on ReleaseFast HEAD incl. pixel layer; screenshots in
%TEMP%\ghoztty-hero-{tree,on,nav}.png reviewed by eye 2026-07-15;
stale-binary root cause (Jul 5 / Jul 12 exes) fixed — all four install
locations serve HEAD build of 2026-07-14 23:25.

## T50 — Real "Rename Window" dialog (Phase I)

T44 fixed the crash but the affordance was still a bare borderless Edit
control anchored to the client area — no label, no OK/Cancel, not
obviously a dialog (user, 2026-07-14). Build a real modal-ish rename
dialog (caption "Rename Window", edit box prefilled with current title,
Enter=OK / Esc=Cancel buttons, centered on the owner window, DPI-aware);
keep the same commit path (titleOverride precedence per T10).

DONE 2026-07-15: new `src/apprt/win32/RenameDialog.zig` — owner-centered
WS_POPUP+WS_CAPTION dialog (dark title bar/controls), label "Window
title:", prefilled edit (override else active-tab title), OK/Cancel
buttons, owner disabled while open (modal, but app msg loop/renderer/IPC
stay live), Tab/Enter/Escape routed via App.run's WM_KEYDOWN intercept
(renameDialogOwning), commit via setTitleOverride (empty clears → reverts
to shell title). prompt_title now opens this instead of the inline
tab-rename edit; double-click on a visible tab still uses inline rename.
DPI-aware pure `layout()` + `nextFocus()` unit-tested in the win32 lane
(win32.zig test import). kb-actions.ps1 extended: 20 T50 asserts (open,
caption, edit/OK/Cancel present, modal owner-disabled, centered,
Enter-commit visible in +list, T10 precedence vs shell title, reopen
prefilled, Escape discards, empty clears, owner re-enabled each close).

*Evidence (done, 39988009a):* on-box 2026-07-15: kb-actions.ps1 ALL PASS
(25 asserts incl. all 20 T50 + T47 regressions); P1–P3 ALL PASS; both test
lanes green. Harness note: FindWindowExW($dlg,_,'EDIT',$null) fails from
PowerShell ($null title marshals to "" → matches only empty-titled
windows; the edit is prefilled) — added a class-only ChildByClass helper.

## T51 — Full parity RE-AUDIT

User directive 2026-07-15: "redo your audit as a task at the end". After
the priority queue lands: re-run the three-way audit (Mac features vs
win32 implementation vs actual on-box behavior, method per
windows-parity-audit.md), explicitly including everything user-reported
this week (hero, rename, remote/auth, perf, palette contents), plus
Windows-native look-and-feel gaps ("get the windows things looking
windowsy"). Every finding becomes a new task row — the audit is not done
until the table contains them.

*Evidence (done 2026-07-18):* four parallel code sweeps (action matrix vs
`src/apprt/action.zig` + Mac dispatch; IPC verbs/GUI features vs
IPCServer.swift + macos/Sources/Features; config coverage vs Config.zig
consumers; look-and-feel vs the T50 bar across all 20 win32 UI surfaces),
each with file:line verification, plus an on-box behavior leg: fresh
Debug build, `ipc-p1`/`ipc-p2`/`ipc-p3` ALL PASS, `hero-mode.ps1` ALL
PASS (60), `ipc-version.ps1` ALL PASS, both unit-test lanes exit 0 —
every user-reported item from the week (hero, rename, remote/auth, perf,
palette) re-verified green at HEAD. Findings: 16, filed as T65–T80 (see
their sections below; F-numbers in the rows map to the finding list).
Two corrections to the 2026-07-12 audit recorded in
`windows-parity-audit.md` (split-divider-color and unfocused-split-* were
listed "honored" but are not implemented). T28's no-op set confirmed
unchanged; `check_for_updates` no-op is deliberate (T24). Mac-side gap
reconfirmed: the Swift IPC server still lacks the `version` verb (T37).

## T52 — Build provenance visible in-app (Phase I)

The 2026-07-15 "no parity" report came from a July-5 exe among FOUR
coexisting builds. Surface version+commit+build date where a user/session
can trivially see it: `+version` verb over IPC (and CLI), the
About/palette surface, and `+list --json` metadata; include the git hash
at build time.

*Acceptance:* from any pane, one command answers "which build is this
window running?"

*Validation:* `test/win32/ipc-version.ps1` — `+version` "Running Instance"
commit/mode/runtime/exe/pid match the served instance and git HEAD;
`+list --json` `data.build` matches; palette → "about" → Enter opens the
About box (chord-injected, palette-popup positive control); `+version`
with no instance still exits 0 with "none detected".

*Evidence (done 2026-07-18):* one collection point,
`src/apprt/win32/provenance.zig` (comptime version/commit/mode/runtime +
runtime exe path, exe mtime as "YYYY-MM-DD HH:MM:SS UTC", pid), feeds all
three surfaces: new IPC `version` verb (IpcHandlers), `+list --json`
`data.build` (optional `List.Build` — null omits the field, so the golden
Mac shape and its tests are unchanged), and `+version`'s new "Running
Instance" section (dials via ipc_client; prints "none detected" /
"running, but no version support" instead of failing — the Mac Swift
server doesn't implement the verb yet, see T37/T51). Palette "About
Ghoztty" entry is local-only like the remote entry (MessageBox is
WndProc-safe — it pumps its own modal loop, unlike the T48 hang).
`ipc-version.ps1` ALL PASS (22) x3 (the chord retries the foreground race
up to 3x — same caveat as hero-mode.ps1); P1–P3 and both test lanes
green. The CLI exe vs server exe can differ (stale-install confusion,
T49) — that's exactly what the Running Instance section exposes.

## T53 — Long-context reliability + perf soak/tuning (Phase I)

User 2026-07-15: "usable for long contexts... not slow, or crashing, well
tuned". Build an on-box soak harness: hours-long Claude-Code-like TUI load
(streaming, alt-screen churn, big scrollback) across several panes; watch
GHOZTTY_PERF telemetry (fps/max-gap/wakeups), memory growth
(scrollback/page_list), handle counts, and the T48 watchdog. Fix what it
surfaces (each finding = task row or fix-in-place if small). Also: profile
input latency and scrollback-seek on huge histories; verify no degradation
at 100k+ lines.

Split 2026-07-16 (sizing rule): T53a = harness + first bounded soak;
T53b = the multi-hour run + profiling + fixes.

### T53a — Soak harness + first bounded soak

`test/win32/soak.ps1`: fully IPC-driven (no chords — safe to run beside
real work), release-staging exe isolated on the `-soak` pipe suffix with
GHOZTTY_PERF=1. Layout: named window + 3 load panes, all `--shell=cmd`:
`soak-stream` (endless 8MB `type` loop — sustained visible streaming),
`soak-altscr` (PS loop toggling ESC[?1049h/l with output bursts —
alt-screen churn), `soak-grow` (150k-line scrollback, then idle), plus the
original pane kept idle for latency probes. Samples every 15s: working
set, private bytes, handle/thread counts, GDI/USER objects
(GetGuiResources), Responding. Every 60s: input-latency probe
(`+send-keys` marker echo → poll `+read` until visible, ms). At the end:
+read-on-big-scrollback latency, telemetry slice from the app log
(release info-level lines; only the soak exe has GHOZTTY_PERF set, so
`perf ` lines are attributable), assertions (alive+responding, IPC
answers, median fps under load, no >5s frame stall, bounded
private-bytes/handle growth in the second half, big-scrollback +read <
1s), CSV + report under `%TEMP%\ghoztty-soak\<stamp>\`, single
ALL PASS / N FAILURE(S) line. `-Minutes` parameterizes duration
(default 30); `-Detach` relaunches itself detached for the T53b
multi-hour run and writes the same report for a later session to read.

*Validation:* bounded soak on the box completes with the report written
and assertions green (or findings filed as task rows).

*Evidence (done 2026-07-16):* the harness's very first smoke found a
P0-class bug: **`App.wakeup()` posted one WM_APP_WAKEUP per surface-
mailbox push with no coalescing**, so a pane flooding tiny writes (cmd
echo loop: 600k lines in <10s through ConPTY) filled the GUI thread's
10,000-entry posted-message quota and **every PostMessageW in the process
failed** — IPC answered `{"success":false,"error":"server not ready"}`
(40/40 +list failures during a storm), and deferred SetFocus (T48) and
hero snapshots (T59a) would silently drop on the same quota. Fix:
`wakeup_pending` atomic flag — at most one wakeup queued (xev.Async's
N-signals→≥1-delivery contract), cleared before `tick()` in msgWndProc
so signals during tick re-post; failed posts clear the flag so it can't
wedge shut. After: `ipc-under-load.ps1` ALL PASS (40/40 +list, 5/5
+send-keys mid-storm, +read returns content mid-storm); 2-min soak smoke
11/11 (fps median 24 across 4 panes under stream+altscr churn, memory/
handle growth ~0, echo latency 264ms median). Findings filed: T62
(+read stalled 16.1s against the tiny-write storm — renderer-mutex
starvation; two all-empty +read results were also seen near peak in an
earlier probe). One unexplained one-off: an isolated test instance
exited silently (no WER, no watchdog kill) minutes after a storm —
never reproduced; the long soak's alive-assertion watches for it.
Diagnosis trail for posterity: raw pipe client caught the "server not
ready" error string the CLI hides; cmd builtins (echo) never update the
ConPTY title, so title-based "is it running" checks are useless — use
+read content. Telemetry gotcha: idle unfocused panes redraw only on
demand, so `perf max_gap_ms` legitimately hits ~60s on them — never
assert a global stall bound from it.

### T53b — Multi-hour soak + profiling + fixes

Launch `soak.ps1 -Minutes 180+ -Detach` (survives context resets; report
harvested from `%TEMP%\ghoztty-soak\`), plus interactive profiling the
harness can't do: keyboard scrollback-seek feel at 100k+ lines
(scroll_to_top/page-up under load), input latency at the keyboard, and
tuning fixes from whatever T53a/the long run surface. Harvest note: the
detached 180-min soak launched 2026-07-16 23:24 (`%TEMP%\ghoztty-soak\
20260716-232428\`) runs a binary that PREDATES the T62/T63 fixes — its
baseline probe already logged the known T62 stall (19.1s, WARN, not
asserted); read the report with that in mind.

*Evidence (done 2026-07-17):* the detached 180-min soak finished
**ALL PASS (11)**: GUI alive + responding at all 720 samples, 180/180
echo probes ok (median 248ms, worst 304ms), median fps 59 under the
4-pane stream/alt-screen load, growth q1→q4 ≈ zero (private +0.5MB,
handles/GDI/USER +0), big-scrollback +read 76ms at the end, zero
slow-mutex warns. Only WARN: the known T62 baseline stall (19.1s) on
the pre-fix binary — already fixed and regression-guarded. Interactive
profiling via the new `test/win32/profile-latency.ps1` (landed with
T64, 3cb802605): fully isolated instance (`-prof` pipe suffix + own
log file via LOCALAPPDATA override so a concurrent soak's telemetry
slice stays clean), real SendInput keyboard path with a pixel-hash
viewport-moved oracle and per-key WM_NULL GUI-thread RTT sampling.
Results (ReleaseFast, ALL PASS 14): keyboard echo latency median 65ms
on a fresh pane → 81ms at 150k scrollback lines (no degradation);
ctrl+home/shift+pgdn seek bursts show GUI RTT 0ms and renderer
59–60fps both idle and while the SAME pane streams an echo storm;
+read mid-storm 79ms and +close of the storming window 122ms (T62/T63
bounds hold in release optimization). No tuning fixes warranted from
either run; the harness's one product finding became T64 (SendInput
unicode injection dropped — fixed same session). Delivery: HEAD
release (T62/T63/T64) rebuilt to zig-out-release and refreshed to all
three install locations (installed via upgrade-ghoztty-windows.ps1,
Desktop portable, homeassistant share) at this boundary, as deferred
from the T62 session.

## T62 — FIX: +read stalls under tiny-write floods (renderer-mutex starvation)

Found by the T53a soak baseline probe: `+read --name=<pane>` took
**16.1s** while the target pane's cmd blasted ~60k echo lines/s
(finished normally; 75ms on the same 150k-line scrollback once idle;
the 8MB/s `type` storm did NOT trigger it — small-write count, not
byte rate, is the trigger). Matches T48's static candidate 2: the GUI
thread (serving the marshaled IPC verb) waits on `renderer_state.mutex`
while the IO thread re-acquires it per small batch in
`processOutputLocked` (src/termio/Termio.zig) — starvation, not
deadlock. A GUI-thread stall this long also freezes the UI (same class
as the user's "not responding" complaints under load).

*Fix (done 2026-07-17):* bound the lock cadence by DATA rate, not write
count. `ReadThread.threadMainWindows` (src/termio/Exec.zig) now reads
into a 64KB buffer and, after each blocking ReadFile, tops up via
PeekNamedPipe→ReadFile until the buffer is full or the pipe is drained —
ONE processOutput (one renderer-mutex cycle) per batch instead of one
per tiny write. Idle-pane keystrokes peek 0 and parse immediately (no
latency added). The GHOZTTY_PERF pty line grew `batches_per_s`.

*Validation (2026-07-17):* `ipc-under-load.ps1` grew a T62 section — an
endless cmd echo-storm pane, then `+read` against it with a 2s bound:
**80–127ms observed post-fix vs 16–19s pre-fix**; ALL PASS (7) incl.
the original wakeup-flood guards. Both unit lanes green; P1–P3 ALL
PASS. Also hardened the kill sweeps in ipc-p1/p2/p3 + ipc-under-load to
match only the exact exe under test — the old `*zig-out*` pattern would
have killed the detached zig-out-release soak (it survived the full
validation run).

## T63 — FIX: +close of a noisy window hung the GUI thread forever (read-thread join race)

Found 2026-07-17 by the T62 validation run: teardown's `+close
--target=ipcload` sat 9+ minutes (app Not Responding) until killed. cdb
stacks: GUI thread in handleClose → cleanupAllSurfaces → Exec deinit →
`read_thread.join()`; reader parked in a blocking ReadFile. Root cause:
`Exec.threadExit` fired CancelIoEx ONCE, but the cancel only lands if
the reader has a ReadFile in flight at that exact instant — it misses
when the reader is parsing (e.g. the final burst subprocess stop
flushes through ConPTY), and the missed cancel left join() waiting
forever. Pre-existing race; the T62 batching widened the parse window
enough to hit it reliably. Fix (same commit as T62): the reader checks
the quit byte (PeekNamedPipe on the quit pipe) before EVERY blocking
read, and threadExit retries CancelIoEx + WaitForSingleObject(20ms) on
the thread handle until the reader exits. os/windows.zig re-exports
WAIT_OBJECT_0/WAIT_TIMEOUT.

*Validation (2026-07-17):* `ipc-under-load.ps1` teardown is now
asserted, not just performed: `+close` of the storm window must return
in <10s — 277ms observed (pre-fix: 9+ min hang). ALL PASS (7); P1–P3
ALL PASS (heavy +close coverage).

## T64 — FIX: SendInput-unicode (VK_PACKET) text injection silently dropped

Found 2026-07-17 by the T53b profiling harness: its input-latency probe
typed via KEYEVENTF_UNICODE and nothing ever reached the pane, while
plain-VK typing worked. That is the injection path used by screen
readers, the on-screen/touch keyboard, and automation tools — all of
them typed nothing into win32 ghoztty.

Root cause (three layers, all fixed 2026-07-17):

1. `App.run`'s `skip_translate` suppressed TranslateMessage for ALL
   surface keydowns to protect the ToUnicode dead-key state — including
   VK_PACKET, whose WM_CHAR is *generated by* TranslateMessage. The
   handleKeyEvent comment promised "the actual character follows as
   WM_CHAR", but that WM_CHAR could never exist. Fix: exempt VK_PACKET
   (like the existing VK_PROCESSKEY IME exemption); packets bypass
   layout translation, so the dead-key state is untouched.
2. `Surface.handleKeyEvent` left `key_event_produced_text` STUCK from
   the previous real keydown (under skip_translate ordinary keys never
   get the WM_CHAR that clears it), so the injected WM_CHAR would be
   eaten as a "duplicate" of the prior key. Fix: the VK_PACKET branch
   clears the flag before returning.
3. In win32-input mode (9001 — which ConPTY panes commonly enable) the
   WM_CHAR handler dropped ALL chars. Since skip_translate means
   ordinary keys produce no WM_CHAR and IME results are consumed whole
   in WM_IME_COMPOSITION (never DefWindowProc'd → no WM_IME_CHAR
   duplicates), any WM_CHAR arriving in this mode is injected text.
   Fix: route it to the previously-unreachable `sendWin32CharEvent`
   (synthetic vk=0 win32-input sequence), with a debug-log oracle.

*Validation (2026-07-17):* `kb-actions.ps1` grew a T64 section: forces
mode 9001 OFF then ON explicitly (no dependence on ConPTY defaults) and
injects unicode after a real VK key (arms the sticky flag) — the token
must appear via `+read` in both modes, plus the win32-input log oracle.
ALL PASS (28, incl. all prior T50/T47 chord assertions — no key-path
regression); both unit lanes green; P1–P3 ALL PASS.

## T54 — Resume-doc diet

User 2026-07-15: "divide up the logs so your context doesn't bloat
massively... for unrelated tasks, we may not need to load them". The
state-table rows had grown into paragraph-length narratives. Restructure:
table rows shrink to one line (status + pointer); per-task detail moves to
per-task sections in this file; the resume protocol tells a fresh session
to read ONLY the goal block, priorities, table, and its one task's
section. Target: resume read < ~15k tokens.

*Evidence (done 2026-07-15):* this file created; `windows-parity-tasks.md`
rewritten as the slim hot doc (one-line table rows, protocol reads
goal+priorities+table+one section); go.md updated to name this file among
the split-out docs. Hot doc shrank from ~65KB (~30k+ tokens) to well under
the 15k-token resume budget.

## T55 — FIX: hero-mode.ps1 fails on HEAD (chords not dispatched)

Filed 2026-07-15 during T20 validation. `test/win32/hero-mode.ps1` fails
5/17 (4/17 with `-ExePath`, which skips the log assertion) — and it fails
IDENTICALLY on a clean HEAD build (94dea4642, verified in a throwaway
worktree), so it is NOT a T20 regression; it predates this session.

Symptom: the positive control dispatches (ctrl+shift+r →
`prompt_surface_title` appears in the debug log), but ctrl+shift+space
never dispatches `toggle_hero_mode` and ctrl+alt+down never moves the
hero — geometry stays the plain tree (carousel assertion reports 100%
width). So key INJECTION works; the hero bindings specifically don't
fire. The default binding is `physical:space` + ctrl+shift
(`src/config/Config.zig` ~7139). Leads: physical-key (VK_SPACE) matching
in `handleKeyEvent` vs the unicode-key rename binding that DOES match;
or space's WM_CHAR suppression path eating the keydown. T54's session
landed the pixel layer in 911cae47e — first establish (git log / T54
log entry) whether the script was ever green on-box after that commit.

*Validation:* `test/win32/hero-mode.ps1` ALL PASS on the box.

## T56 — Remote reconnect on win32 (WP-D1 parity) (Phase G)

Filed 2026-07-15 during T21b validation. When the agent dies under a live
remote window, win32 today degrades to a clean dead pane (no hang, no
crash — `ipc-relay.ps1` §6/§7 prove it), but the Mac has the full WP-D1
reconnect state machine: CONNECTED → RECONNECTING on transport EOF,
bounded redial with backoff (`tcp_dial`/`relay_dial` + handshake
deadline), re-ATTACH by session UUID (agent keeps detached sessions
alive), yellow-pill status UI. The Zig core primitives are shared and
already proven headlessly (`wp4_e2e.zig` phases 2–4); the work is the
win32 driver: state observer on the connection, redial loop off the GUI
thread, ATTACH-then-DETACH swap ordering (see the Phase-4 notes), and a
Windows-native status affordance.

*Validation:* extend `ipc-relay.ps1`: kill + restart the agent under a
live window → the pane comes back (reattach) or reports a clear
disconnected state; no hang, no crash, no orphan connection threads.

## T58 — Hero mode TRUE port: design (win32) (Phase F)

Filed 2026-07-16 from a mid-session user correction: "the macos hero mode
maximizes the current screen and has a right side vertical carousel with
thumbnails of the other screens you can swap between, with animations and
such. you didn't port that at all. you need to add tasks to the list to
reevaluate this." T19 shipped a static live-pane stand-in (see the T19
CORRECTION note). This task designs the real port; T59 implements it.

**Behavioral spec of the Mac implementation** (extracted 2026-07-16 from
`macos/Sources/Features/HeroMode/` — HeroModeState/HeroModeView/
HeroPaneView/HeroCarouselView.swift — so the T58/T59 sessions do not need
to re-read the Swift):

- *Layout*: hero pane fills `(1 − carouselRatio)` of the width, full
  height, on the LEFT; carousel column on the RIGHT. `carouselRatio`
  defaults to 0.25, clamped 0.1–0.6, adjustable by dragging the divider.
- *Hero pane* (HeroPaneView): ALL leaves live in a vertical strip of
  hero-sized slots (slot = full hero rect + 40px gap); the strip's Y
  offset positions the selected slot in view. Selection change ANIMATES
  the strip (0.35s ease-in-ease-out slide) — the outgoing pane slides
  out, the incoming one slides in. Only the visible slot's terminal grid
  is reflowed (`sizeDidChange`); off-screen slots reflow lazily on
  selection. During divider drags the reflow is debounced (80ms) so the
  drag glides; frames resize immediately.
- *Carousel* (HeroCarouselView): vertical strip of thumbnail TILES, one
  per leaf (including the hero's own leaf). Tiles show SNAPSHOT IMAGES of
  each pane (Mac: `surfaceLayer.render` into a bitmap), not live panes.
  Visible tiles refresh on a 0.15s timer (paused while scrolling; one
  refresh 0.2s after scrolling ends). Thumb size mirrors the hero pane's
  aspect ratio: width ≤ 88% of carousel width, height capped at 70% of
  carousel height (shrink width to preserve AR when the cap binds); 8px
  gap; ~6% horizontal padding. The strip CENTERS the selected tile
  vertically and animates re-centering on selection change (0.3s ease,
  skipped on first show). Mouse wheel scrolls the strip with clamped
  offset (max half the overflow either way); selection change resets the
  scroll offset.
- *Tile chrome*: rounded corners (6px), 1px border. Selected: 2px blue
  border (0.416, 0.416, 1.0) + soft glow shadow (radius 15, opacity 0.4),
  full alpha. Hovered: purple border (0.545, 0.361, 0.965), alpha 0.6.
  Normal: gray border (white 0.5 @ 0.3), alpha 0.35 (i.e. unselected
  thumbnails are dimmed). Click (mouse-up inside) a tile selects it —
  which swaps it into the hero with both animations. Carousel background:
  black @ 0.3 alpha over the window background.
- *Divider*: 6px hit area, 1px visible line; gray normally, blue while
  hovered/dragged; horizontal-resize cursor on hover; drag adjusts
  `carouselRatio` (measured in global coords so it doesn't oscillate),
  clamped 0.1–0.6.
- *Navigation*: shift+cmd+up/down select prev/next (win32 already maps
  ctrl+alt+arrows via gotoSplit interception — keep). Focus follows
  selection; external focus change moves the selection (T19 plumbing).
- *Unchanged T19 plumbing that stays*: toggle action + keybind, >1 leaf
  activation guard, seed selection from focused leaf, zoom mutual
  exclusion, tree-change clamp/deactivate, per-tab state, +list
  unaffected.

**Design decisions (T58, resolved 2026-07-16, from code study of
Window.zig/Surface.zig/generic.zig/OpenGL.zig/Thread.zig):**

1. *Thumbnails — renderer-side snapshots. Capture-from-HWND REJECTED.*
   Surfaces are `WS_CHILD` GL windows: child HWNDs have no DWM
   redirection surface of their own, SW_HIDE'd windows aren't composited
   at all, and `PrintWindow(PW_RENDERFULLCONTENT)` on a GL child is
   driver-fragile — no HWND-capture path can give live thumbnails of
   hidden panes. Instead the renderer thread captures its own output:
   - Hook: in `generic.zig` `drawFrame` (win32-only, `comptime`-gated),
     immediately BEFORE `drawFrameEnd`'s SwapBuffers — register the
     snapshot `defer` AFTER the `defer self.api.drawFrameEnd()` at
     generic.zig:1492 so it runs first (LIFO); the back buffer then
     holds the complete frame. Renderer reaches the apprt surface via
     `rt_surface` (Options.zig:21).
   - Capture: if the per-surface snapshot request flag is set (one
     atomic load per frame when idle — T53 bar), `glBlitFramebuffer`
     default-FB → small lazily-created FBO at the requested THUMB size
     (GL_LINEAR), `glReadPixels` BGRA from the FBO (≈0.5MB vs ≈10MB
     full-res per capture), store into an apprt-Surface-owned
     mutex-guarded buffer, bump seq, clear the flag,
     `PostMessage(parent, WM_APP_HERO_SNAP, wparam = leaf HWND)`. GUI
     validates the HWND (`GWLP_USERDATA` surface lookup) before touching
     anything, memcpys into a per-leaf `CreateDIBSection` cache when seq
     changed, `InvalidateRect`s the tile. GL's bottom-up readback
     matches bottom-up DIB layout — no flip needed.
   - Request side: a 150ms GUI timer (Mac-parity refresh) while hero is
     active on the active tab sets requested+size per visible tile and
     `renderer_thread.wakeup.notify()`. Idle panes produce no frame →
     no capture → stale thumb is correct (content unchanged).
   - RISK + de-risk spike (T59a step 1): back-buffer rendering of a
     HIDDEN window relies on compositor-era pixel ownership (fine on
     Win10/11 DWM in practice; classic offscreen-GL technique). Spike
     asserts non-black capture from a hidden pane on the box FIRST.
     Fallback if blank: non-hero surfaces stay visible-but-occluded
     stacked BEHIND the hero pane with `WS_CLIPSIBLINGS` added to the
     surface class (snapshot pipeline unchanged; only HWND placement
     changes).
2. *Non-hero surfaces: SW_HIDE, renderer kept awake, all hero-sized.*
   Non-hero leaves are hidden like zoom does today, BUT keep
   `setVisible(true)` (renderer occlusion stays "visible" — Thread.zig
   gates drawFrame on it) so they keep producing frames for thumbnails.
   ALL leaves stay `MoveWindow`'d to the hero rect even while hidden:
   thumbnails inherit the hero aspect ratio for free and selection swap
   needs NO grid reflow — the Mac keeps all strip slots hero-sized for
   exactly this reason. Enter/exit hero = one reflow per leaf.
3. *Carousel: owner-paint in the parent window; new module.* No child
   HWNDs per tile. New `src/apprt/win32/HeroCarousel.zig` (Window.zig is
   already ~105KB — no-mega-files rule): per-tab state (ratio, scroll,
   hover, animations, DIB cache), double-buffered paint (memory DC),
   hit-test, input handlers; Window.zig gets thin shims (WM_PAINT after
   paintTabBar, mouse branches, WM_APP_HERO_SNAP, WM_TIMER ids). Pure
   geometry/easing/scroll-clamp math in `hero_math.zig` with unit tests
   (win32 test lane; no OS imports so the none lane can take it too).
   Chrome (Windows-native, T50 bar): tile = 6px rounded rect
   (`CreateRoundRectRgn` clip + `RoundRect` border); snapshot BitBlt
   (captured at tile size; StretchBlt HALFTONE only on size mismatch);
   dimming via `AlphaBlend` `SourceConstantAlpha` ≈ 255/153/89
   (selected/hover/normal — Mac 1.0/0.6/0.35); borders: selected
   RGB(106,106,255) 2px, hover RGB(139,92,246) 1px, normal gray 1px;
   SKIP the Mac glow shadow (GDI has no cheap soft shadow — deliberate
   simplification). Carousel bg = window bg darkened 30% toward black.
   Decls to add in win32.zig: `StretchBlt`, `SetStretchBltMode`,
   `AlphaBlend` (msimg32), `CreateRoundRectRgn`, `RoundRect`,
   `SelectClipRgn` (CreateDIBSection/BitBlt/TrackMouseEvent exist).
   Geometry (Mac parity): thumb w ≤ 88% carousel w, ~6% h-padding,
   h = w/heroAR capped at 70% carousel h (shrink w to keep AR when the
   cap binds), 8px gap, selected tile centered vertically, wheel scroll
   clamped to ±half the overflow, offset reset on selection change.
4. *Input routing.* Parent WndProc gains carousel branches when hero
   active: WM_MOUSEMOVE hover (TrackMouseEvent) → invalidate changed
   tiles; WM_LBUTTONUP inside a tile → select (Mac selects on mouse-up);
   NEW parent WM_MOUSEWHEEL handler (screen→client coords) — wheel
   reaches the parent via Win10+ "scroll inactive windows on hover"
   routing, PLUS fallback: the Surface wheel handler forwards to the
   carousel when hero is active and the cursor sits over the carousel
   region (WM_MOUSEWHEEL otherwise follows keyboard focus = hero pane).
   Divider: 6px hit band at the hero/carousel boundary (1px visible
   line; gray, accent while hovered/dragged), IDC_SIZEWE cursor, drag
   updates NEW per-tab `tab_hero_ratio` (default 0.25, clamp 0.1–0.6;
   replaces the T19 `HERO_CAROUSEL_RATIO` const; save/restore it in
   moveTabTo's hero bookkeeping like the other per-tab hero arrays),
   with `MoveWindow` of the hero throttled to 80ms during the drag (Mac
   debounces reflow 80ms; on win32 frame==grid, so throttle the resize
   itself — deliberate simplification, carousel repaints every tick).
5. *Animations: timer-driven easing, snapshot-slide for the hero.* One
   ~16ms `SetTimer` alive only while an animation runs; progress from a
   real-time clock (std.time.Instant), ease-in-out cubic; honor
   `SPI_GETCLIENTAREAANIMATION` (skip animations when the user disabled
   them). Selection slide (0.35s, Mac parity): during the slide BOTH
   hero HWNDs stay hidden and the hero region owner-paints the outgoing
   + incoming SNAPSHOTS sliding by hero_h + 40px·scale in the selection
   direction; at the end SW_SHOW the incoming surface and SetFocus
   (deferred, T48). Avoids per-tick SetWindowPos of live GL children
   and SetWindowRgn clipping hacks; content freezes ≤350ms, which reads
   the same as the Mac's live slide. Carousel re-center (0.3s, skipped
   on first show) animates the scroll offset the same way.
6. *Plumbing kept from T19 (unchanged behavior, new effects).* Toggle
   action/keybind, >1-leaf guard, seed from focused leaf, zoom mutual
   exclusion, tree-change clamp/deactivate (now also clamps scroll and
   cancels animations), per-tab state, ctrl+alt arrows via gotoSplit
   interception, heroOnSurfaceFocused → full swap path (show/hide +
   animation). Background tabs: tab switch occludes panes as today →
   thumbnails pause; re-request on re-activation. Teardown: snapshot
   buffer freed AFTER core_surface deinit (renderer thread already
   stopped) — matches existing deinit order.
7. *hero-mode.ps1 rewrite (new geometry oracle).* After toggle: hero
   HWND visible with rect == client minus carousel (ratio 0.25) at full
   height; ALL other leaf HWNDs `IsWindowVisible == false` AND sized ==
   hero rect; no child HWNDs inside the carousel region. ctrl+alt+down
   (600ms settle for the slide) → next leaf visible at hero rect,
   previous hidden. Toggle off → all leaves visible, tree rects
   restored. Palette section (T57) and ctrl+k positive control (T55)
   unchanged.

*T59 sizing:* too big for one context → split into T59a (snapshot
pipeline + layout rework + static carousel) and T59b (interactions +
motion + polish); rows + sections added 2026-07-16, T59 umbrella row
replaced (T21/T22 precedent).

*Validation (T58):* DONE 2026-07-16 — decisions 1–7 above recorded with
code-level anchors (hook line, module split, decls to add, risk spike
first); T59 split into two context-sized tasks with ordered steps.

## T59a — Hero mode TRUE port: snapshot pipeline + static carousel (Phase F)

First half of the T58 design (read the T58 decisions section first — it
has the code-level anchors). Ordered steps, riskiest first:

1. *De-risk spike*: hidden-pane capture — hide a pane's HWND while
   keeping renderer visibility true, request a snapshot (T58 decision 1
   pipeline, can be a crude full-res glReadPixels first), assert
   non-black pixels on the box. If blank on this driver, switch to the
   documented fallback (visible-but-occluded behind hero +
   WS_CLIPSIBLINGS) and record it here.
2. Snapshot plumbing end-to-end: request flag + thumb size + FBO blit +
   BGRA readback in the generic.zig pre-swap hook; mutex buffer + seq on
   the apprt Surface; WM_APP_HERO_SNAP + HWND-validated GUI pickup +
   per-leaf DIB cache; 150ms refresh timer while hero active.
3. Hero layout rework: all leaves MoveWindow'd to the hero rect,
   non-hero SW_HIDE with renderer kept awake, enter/exit reflow,
   per-tab `tab_hero_ratio` field (still fixed 0.25 until T59b drag).
4. `HeroCarousel.zig` + `hero_math.zig` static render: tile geometry
   (Mac-parity numbers), snapshots BitBlt'd with rounded-corner clip,
   dimming + selected border, click-to-select (instant swap, no
   animation yet), selected tile statically centered. Unit tests for
   hero_math in the win32 lane (+ none lane if the build wires it).
5. Rewrite `test/win32/hero-mode.ps1` per the T58 oracle (decision 7).

*Validation:* on-box: 3-pane layout → toggle hero → hero maximized
left, carousel of dimmed thumbnails right, selected tile highlighted;
click a tile → it swaps into the hero; ctrl+alt+up/down move selection;
thumbnails visibly update while a busy TUI runs in a non-hero pane
(spike + timer working); toggle-off restores the exact tree. Rewritten
`hero-mode.ps1` ALL PASS; both test lanes + P1–P3 green.

*Evidence (DONE 2026-07-16):*

- *Spike outcome (step 1):* better than planned — instead of reading the
  window back buffer, `OpenGL.captureThumb` blits `last_target` (the
  OFFSCREEN texture every frame renders into before `present()`) into a
  lazily-created thumb FBO and does one small `glReadPixels`. Offscreen
  texture content is always defined regardless of HWND visibility, so
  hidden panes capture cleanly by construction; the documented
  visible-but-occluded fallback was never needed. Verified on-box:
  `hero snap committed` debug lines from all (hidden) panes + carousel
  pixels of a hidden busy pane visibly changing (screenshot shows live
  `ping -t` output inside a hidden pane's thumbnail).
- *Pipeline (step 2):* per-Surface mutex-guarded request/buffer/seq
  (GUI pre-sizes the buffer; the renderer never allocates; one atomic
  load per frame when idle), pre-swap defer hook in generic.zig
  drawFrame (runs even on the `presentLastTarget` no-redraw path, so a
  GUI `wakeup.notify()` refreshes idle panes' thumbs), WM_APP_HERO_SNAP
  (WM_APP+6) with tree-validated HWND, per-Surface bottom-up DIB cache
  (matches GL readback order — no flip), 150ms `HERO_SNAP_TIMER_ID`
  heartbeat paused while minimized (IsIconic).
- *Layout (step 3):* non-hero leaves SW_HIDE + `setVisible(true)`;
  every leaf MoveWindow'd to the hero rect; per-tab `tab_hero_ratio`
  (default 0.25) carried through addTab/closeTab/moveTabTo;
  `hitTestDivider` returns null in hero mode.
- *Carousel (step 4):* `HeroCarousel.zig` (geometry + double-buffered
  owner paint: darkened column, divider line, rounded-clipped
  AlphaBlend thumbs — selected 255 / normal 89 alpha, accent-blue
  selected border; glow shadow skipped per design) + `hero_math.zig`
  (pure; 8 unit tests wired into BOTH lanes via the apprt.zig test
  block). Click-to-select on WM_LBUTTONUP. WM_PAINT restructured into
  `paintWindow` (one BeginPaint for tab bar + carousel).
- *hero-mode.ps1 (step 5):* rewritten to the T58 oracle in two phases —
  2-pane snapshot-pipeline phase (both tiles on-screen; log + pixel-diff
  oracles) then 3-pane layout/nav/click/palette phase. ALL PASS on-box
  (39 assertions; ran via a wait-for-input-idle runner because
  SetForegroundWindow is denied while the user actively uses the box).
  Harness lessons recorded in the script comments: pixel scripts MUST be
  per-monitor-DPI-aware (PrintWindow silently clips at 125% DPI
  otherwise), and the carousel strip is in TREE ITERATION ORDER with
  prev/next clamped at the ends (Mac parity) — the focused pane isn't
  necessarily first, so the nav step tries down then up.
- Both unit-test lanes green; P1–P3 ALL PASS.

## T59b — Hero mode TRUE port: interactions, motion, polish (Phase F)

Second half of the T58 design, on top of T59a:

1. Wheel scroll (parent WM_MOUSEWHEEL + Surface-side fallback), clamped
   offset, selected-tile centering math shared with T59a.
2. Divider: hit band + hover/drag chrome + IDC_SIZEWE, drag updates
   per-tab ratio (clamp 0.1–0.6), 80ms-throttled hero resize.
3. Hover chrome (TrackMouseEvent, purple border, 0.6 alpha) + tile
   invalidation on hover change.
4. Animations: selection snapshot-slide (0.35s) + carousel re-center
   (0.3s), 16ms timer, ease-in-out cubic, SPI_GETCLIENTAREAANIMATION
   respected; hero-mode.ps1 gets the 600ms settle before geometry
   asserts.
5. Perf pass: GHOZTTY_PERF fps with hero on vs off (no regression, no
   jank while a busy TUI feeds thumbnails); tune refresh/anim timers if
   needed.

*Validation:* on-box: everything in the T59a list PLUS click-swap is
animated, wheel scrolls the carousel, divider drag resizes hero/carousel
live, hover highlights tiles; GHOZTTY_PERF shows no fps regression.
`hero-mode.ps1` ALL PASS; both test lanes + P1–P3 green; screenshot
archived in `test/win32/artifacts/`.

*Evidence (DONE 2026-07-16):*

- *Wheel (step 1):* per-tab `tab_hero_scroll` + `hero_math.clampScroll`
  (±half the strip overflow, Mac parity; strip that fits pins to 0;
  clamped at read time in `HeroCarousel.geometry` so tree changes
  self-heal stale offsets). Two delivery paths per T58 decision 4: a new
  parent `WM_MOUSEWHEEL` branch (screen→client coords; Win10+ hover
  routing) AND a Surface-side fallback (`heroWheelScreenCursor`) for
  wheel-follows-focus routing. One detent = half a tile step; selection
  change resets the offset; manual scroll cancels a live re-center.
- *Divider (step 2):* `heroHitDivider` on the 6px band; IDC_SIZEWE on
  hover (WM_SETCURSOR branch), accent-blue divider line while
  hovered/dragged; drag recomputes the per-tab ratio from the absolute
  cursor x (clamp 0.1–0.6), leaf `MoveWindow`s throttled to 80ms while
  the carousel repaints every tick; double-click resets ratio to 0.25
  (parity with tree-divider double-click).
- *Hover (step 3):* `hero_hover_tile` tracked in a parent WM_MOUSEMOVE
  branch (TrackMouseEvent shared with the tab bar; WM_MOUSELEAVE
  clears); hovered tile paints alpha 153 + 1px purple RGB(139,92,246).
- *Animations (step 4):* selection snapshot-slide (0.35s) — both hero
  HWNDs hidden, hero region owner-paints outgoing+incoming snapshot DIBs
  (HALFTONE-stretched) sliding by hero_h + 40px·scale; incoming shown +
  focused at slide end. Carousel re-center (0.3s) — visual strip offset
  decays from the pre-switch position to the new centered one. One 16ms
  timer alive only while animating; progress from std.time.Instant;
  `hero_math.easeInOutCubic`; `SPI_GETCLIENTAREAANIMATION` honored
  (instant swap when the user disabled client-area animations). Layout,
  tab switch, and tree change cancel animations (slide cancel reveals
  the selected pane); rapid re-selects retarget cleanly.
- *Perf (step 5):* GHOZTTY_PERF with a busy `ping -t` pane: hero OFF avg
  1.4 fps/renderer (1Hz workload, max gap ≈ ping cadence); hero ON avg
  7.1 fps — exactly the 150ms thumbnail heartbeat, max gap 174ms, no
  stalls; during an animated swap avg 7.3 fps, no gap spike. No tuning
  needed: the anim timer lives only for the 350ms slide.
- *hero-mode.ps1:* phase 3 added (mid-slide oracle: 0 visible panes
  while the region owner-paints — gated on the OS animation setting;
  hover + wheel debug-log oracles; 5-pane overflow wheel scrolled
  offset −88; divider drag narrowed the hero 578→427px with all hidden
  leaves re-sized; double-click reset restored ~25%). ALL PASS on-box,
  58 assertions. Screenshot: `test/win32/artifacts/hero-mode-t59b.png`.
  PS 5.1 lesson: hex literals that fill 32 bits (0xFF880000) parse as
  NEGATIVE Int32 — use decimal for UIntPtr wparams.
- Both unit-test lanes green (3 new hero_math tests); P1–P3 ALL PASS.

## T61 — FIX: swap_split in hero mode mutates the hidden tree (Phase F)

Filed + fixed 2026-07-16 from two live user reports: hero nav from index 1
"goes back to index 2 rather than 0", and toggling hero off restored panes
in the wrong locations. Root cause: on Windows ctrl+shift+arrows is bound
to `swap_split` (Config.zig ~6806); hero mode only intercepted
`goto_split`, so the chord did a real SPATIAL tree swap while the tree's
geometry was hidden behind the hero layout. Focus-follows
(`heroOnSurfaceFocused`) then chased the swapped pane to its new leaf
index — the "went to 2" symptom — and the mutated tree is what toggle-off
restored. Both reports, one bug. The intended hero-nav chord was only
ever bound on Mac (cmd+shift+up/down, Config.zig ~7127); the Windows
binding promised there ("with hero mode itself, T19") never landed.

Fix (Window.zig `swapSplit`): hero mode intercepts swap_split at the same
choke point as the gotoSplit interception (covers keybind + palette
entries). up/down (and previous/next) move the carousel selection via
`heroSelect` — making ctrl+shift+up/down the natural Windows mirror of
the Mac hero-nav chord — and left/right are no-ops. Outside hero mode
swap_split is unchanged.

*Validation (done 2026-07-16):* hero-mode.ps1 grew step 3b: in hero mode
ctrl+shift+down then up must move the selection, and the pre-existing
per-HWND "tree geometry restored exactly after toggle-off" assertion now
runs AFTER those chords, doubling as the no-tree-mutation oracle. ALL
PASS on-box (60 assertions); both unit-test lanes green; P1–P3 ALL PASS.

## Backlog — Mac features with no win32 equivalent yet

Promote to a task row when prioritized; don't work these ad hoc.

- **Session/window save-restore** — no equivalent of `TerminalRestorable*`;
  `window-save-state` ignored. Medium effort (persist layout manifest,
  reopen on launch).
- **Terminal inspector** — `inspector`/`render_inspector` are no-ops; the
  Mac has a real inspector window. Dev tool, not user-critical.
- **Tab tear-out & surface drag-out** — tab drag only reorders in-window;
  no drag-out-to-new-window, no `SurfaceDragSource` equivalent.
- **Tab overview** — no-op on win32 (and effectively no-op on Mac too).
- **Settings UI / About window / config-errors window** — Windows is
  file-only config (works: `ctrl+,` opens it, reload via
  `ctrl+shift+,`/palette; file at `%LOCALAPPDATA%\ghostty\config.ghostty`).
- **Selection/primary clipboard** — `supportsClipboard` only `.standard`;
  no paste-from-selection.
- **In-surface visual bell** — bell is MessageBeep + taskbar flash only.
- **UI Automation / screen-reader accessibility** — no UIA surface (Mac AX
  was already out of scope; a Windows screen-reader pass is its own
  effort).
- **Child-exited inline bar** — win32 uses a modal MessageBox vs the Mac's
  in-window bar.
- **IME/CJK deep verification, log rotation, perf/GL driver matrix** —
  carried from the spec backlog.

Out of scope (platform N/A, decided): secure input
(`EnableSecureEventInput` has no Windows equivalent), undo/redo
(NSUndoManager-based), Dock/Services/AppleScript/App Intents, Spaces
behavior, Quick Look, macOS titlebar-tab styles, Sparkle (T24 covers the
Windows-appropriate update path), AX attributes (`AXWindowActivityState` —
ztabby is a Mac consumer).

## T65 — FIX: show_child_exited suppresses the core fallback (Phase I)

Found by T51 (F1). `src/apprt/win32/App.zig:1226-1262` only shows a
blocking `MessageBoxW` when `exit_code != 0`, yet returns `true` in every
case — so the core (`src/Surface.zig:1402-1493`) never runs its fallback:
with `wait-after-command` a clean exit shows NOTHING (terminal sits
static, looks like a hang), and fast abnormal exits lose the rich
in-terminal diagnostic (command + runtime, Surface.zig:1496-1553). Mac
shows a non-modal dismissible banner even for exit 0
(Ghostty.ChildExitedMessage.swift). This also subsumes the backlog's
"child-exited inline bar" note above.

*Fix:* return `false` whenever nothing was displayed (minimum); better,
replace the modal with a non-blocking banner overlay showing the same
success/error content as Mac.

*Done 2026-07-18.* `.show_child_exited` now returns `false` (MessageBoxW
removed); the core draws its in-terminal UI. A native non-modal banner
(full Mac parity) rides on the T35 pane-banner infrastructure. Validation
surfaced three adjacent bugs, all fixed in the same change:

1. **ConPTY late-frame race** (`src/termio/Exec.zig`): ConPTY renders its
   final frame(s) asynchronously AFTER the process exits, so the
   immediately-notified surface wrote its exit message and the late
   repaint erased it (blank pane; a pre-exit `echo` survived because it
   was in ConPTY's buffer — that asymmetry was the tell). On Windows,
   `processExitCommon` now parks the notification and a 50ms timer
   (`exitNotifyTimer`) fires it once a read-thread byte counter
   (`read_activity`, bumped both sides of each parse batch) is stable for
   a full tick, capped at 20 ticks (1s). Pure gate logic
   (`exitNotifyShouldFire`) is unit-tested in both lanes.
2. **Wrong-type GWLP_USERDATA cast, random key eating + AV**
   (`src/apprt/win32/App.zig` run loop): the popup-edit WM_KEYDOWN
   intercepts did `GetParent(msg.hwnd)` → cast its GWLP_USERDATA to
   `*Surface`. For a keystroke on the terminal surface itself (every
   normal keypress) the parent is the top-level GhozttyWindow whose
   userdata is a `*Window`, so `search_active`/`palette_edit` reads were
   out-of-bounds garbage — usually false (harmless), sometimes true
   (keys silently eaten by handleSearchKey), sometimes AV (reproduced
   under cdb: `run+0x944`, App.zig:432). New `surfaceParentOf()` verifies
   the parent's class is TERMINAL_CLASS_NAME before the cast; both
   intercept sites use it.
3. **Close-on-keypress dead under Win32 Input Mode** (`src/Surface.zig`):
   ConPTY enables DEC 9001, which makes `encodeKey` return null on
   Windows (the apprt emitter owns encoding), so the core's "key press
   that encodes closes an exited surface" check could never fire.
   `keyCallback` now closes an exited surface on any non-modifier press
   (comptime Windows-gated). Also `queueRender()` after both exit-message
   writes — the win32 renderer is wakeup-driven and the text otherwise
   sat unpainted until an unrelated event.

*Validation:* `test/win32/ipc-child-exited.ps1` ALL PASS (18) three runs.
Covers: clean exit 0 + `wait-after-command` shows the press-any-key
notice; abnormal exit 3 shows the rich diagnostic (header + command +
`Runtime:`); no `#32770` dialog owned by ghoztty + IPC responsive; a REAL
SendInput key press (kb-actions recipe — `+send-keys` writes to the PTY
and cannot exercise the close-on-key path) closes the waited pane while
the abnormal pane stays. Uses a private `XDG_CONFIG_HOME` config
(`wait-after-command=true`, `abnormal-command-exit-runtime=5000` for
determinism). Regression: both test lanes, P1–P3, kb-actions (28),
ipc-under-load (7), hero-mode (60) ALL PASS.

## T66 — FIX: reset_window_size hardcodes 800×600 (Phase I)

Found by T51 (F2). `src/apprt/win32/App.zig:1331-1357` resizes to a
literal 800×600; `.initial_size` (App.zig:1160-1187) applies once and
stores nothing; `window-width`/`window-height` are referenced nowhere in
the win32 apprt. Mac stores the initial-size action per window and
`returnToDefaultSize` restores it (TerminalController.swift:1492).

*Fix:* store the last `initial_size` w/h on the Window; use it in
`reset_window_size` (fall back to 800×600 only if never set).

*Validation:* set `window-width`/`window-height`, resize the window, run
the reset keybind → returns to configured size, not 800×600.

**DONE 2026-07-18.** `Window.default_client_size` (+ shared
`Window.setClientSize`, which owns the AdjustWindowRectEx/SetWindowPos
client-size math) is written on every `initial_size` action and read by
`reset_window_size` (`orelse 800×600`). Semantics matched to Mac/GTK,
which both treat the action as store-only (Mac stores
`surfaceView.initialSize`, GTK `setDefaultSize`): win32 now applies the
live resize only once per window (`initial_size_applied`), so the
re-send from every font-size change (`setCellSize` →
`recomputeInitialSize`) updates the stored default without resizing a
window in use — previously ctrl+= with window-width set snapped the
window back to the configured grid size. Command palette gained "Reset
Window Size" (core command.zig has it; the static win32 list didn't —
the T57 drift class).

Evidence: `test/win32/reset-window-size.ps1` ALL PASS (10) ×3 —
configured 120×20 launch applies (client 1158×422 ≠ 800×600), manual
resize + ctrl+alt+f9 returns exactly, font zoom ×3 leaves the window
un-resized then reset lands on the recomputed default (1446×534),
no-config case resets to exactly 800×600; toggle_maximize positive
control per T55. P1–P3 + both test lanes green. Gotcha for future key
tests: ctrl+alt+m never reaches ghoztty — another app on the box owns
it via RegisterHotKey (message-loop tracing showed the keydown absent
from the queue while ctrl+alt+j/f9 arrive fine).

## T67 — Window/pane background tint (`--color`/`--split-color`) (Phase I)

Found by T51 (F3). Mac implements per-window/pane background tint with
palette-contrast adjustment + context-menu NSColorPanel picker
(IPCServer.swift:401-483, docs/design/window-color.md). win32 parses and
drops both flags (`src/apprt/ipc/args.zig:115-116`); no consumer in
IpcHandlers.zig; no picker in the context menu (Surface.zig:2523-2542).

*Fix:* honor the flags end-to-end (surface bg override + contrast shift),
add a "Background Color…" context-menu entry using the common color
dialog (`ChooseColorW`).

*Validation:* `+new-window --color=#334455` tints; `+split
--split-color=…` tints the pane; picker round-trips; P1–P3 stay green.

**DONE 2026-07-18 (5bf9a65d6).** Four layers, all Mac-parity:

- `color_math.zig` (pure, unit-tested in both lanes): hex parse
  (`#rgb`/`#rrggbb`), Rec.601 luminance/isLight, HSB lighten/darken,
  `shiftedTint` (5% — the shipping Mac `shiftedTint` uses 0.05, not the
  design doc's worked 0.15 example), WCAG-4.5 CIELAB palette
  binary-search (`adjustPaletteForContrast` port), `randomDark`.
- `Surface.applyBackgroundTint`: sets terminal bg under the renderer
  mutex; explicit colors (CLI/picker) also set a black/white contrast fg
  + the 16 adjusted ANSI colors (Mac applyColorScheme); scrollbar theme
  follows; renderer woken. `+list --json` leaves carry an additive
  `background_tint` (#rrggbb, omitted when untinted — golden Mac shape
  unchanged).
- Verbs: `+new-window --color/--split-color`, `+split --color`, value
  `random` (dark muted). Invalid hex never reaches the server — the
  shared CLI rejects it (`error.InvalidValue`), same as the Mac; the
  handler still silently ignores unparseable values from raw clients.
  Plain splits (keyboard or IPC, local or remote) inherit the parent
  pane's effective bg shifted, applied post-init in `newSplitAt` — an
  explicit color overwrites it right after.
- Context menu "Background Color…" → `ChooseColorW` (comdlg32, now
  linked) seeded CC_RGBINIT with the pane's effective background;
  OK applies the full scheme. Windows-native stand-in for the Mac's
  live NSColorPanel (common dialog is modal; no live preview).

Evidence: `test/win32/window-color.ps1` ALL PASS (14) ×3 — `+list`
model asserts, screen-pixel probe (#334455 reads back 51,68,85 at the
pane center), exact shift oracle #334455→#384b5e (pinned in a unit
test too), inline `--split-color`, untinted-pane absence, `random`
dark+well-formed, CLI reject, and menu→dialog→Enter automation
(right-click → `B` mnemonic → #32770 appears → tint == configured bg).
P1–P3, split-dim (23), hero-mode (60), both test lanes: green.

## T68 — Remote inheritance: `--from-focused` + New Window on remote (Phase G)

Found by T51 (F4). Mac reuses the focused window's remote host for
`--from-focused` (IPCServer.swift:413-427, 555-589 →
newWindowInheritingRemote; spec WP4). win32 drops the flag
(args.zig:115-116) and `.new_window` (App.zig:834-853) never checks for
a focused remote surface — New Window on a remote pane always opens
local.

*Fix:* plumb the focused surface's remote connection (relay device or
host:port + per-host defaults) into new-window/split creation when the
flag is set or the keybind fires on a remote pane.

*Validation:* extend the `ipc-relay-login.ps1`-style fake-agent harness:
open a remote window, ctrl+shift+n / `+new-window --from-focused` → the
second window dials the same agent.

**DONE 2026-07-18 (c8f1da16e).** Four layers, all Mac-parity
(BaseTerminalController.newSplit / TerminalController.newWindowInheritingRemote,
§WP4):

- `args.zig` parses `--from-focused` (unit-tested both lanes).
- **Tabs/splits stay remote:** `Window.addTab`/`newSplitAt` synthesize
  `.remote` overrides when no IPC baton is pending and the window is
  remote — fresh session on the SAME connection, inheriting the parent
  pane's command (`remoteCommand()`) and LIVE cwd (`GET_CWD` RPC,
  1.5s bound, on the GUI thread — the same synchronous-dial trade the
  ≤10s remote open already makes on win32; failure ⇒ agent default cwd).
- **`+split` on a remote window is never local:** explicit
  `--command`/`--working-directory` forward REMOTE-native (no local
  shell wrap; `-e` argv joined); with no explicit values the handler
  passes no overrides so full inheritance applies. `+split/--new-window
  --from-focused` mirror the keyboard paths (front window, no
  name/target registration — Mac rule).
- **New Window re-dials:** `Window.remote_machine` records the dialed
  identity (host:port or relay base+device, owned dupes;
  `RemoteOpenOptions.machine` plumbed from both dial paths + chooser).
  ctrl+n / `+new-window --from-focused` on a remote window calls
  `App.openRemoteWindowFrom`: snapshot command, bounded cwd query on the
  parent's conn, then a FRESH dial (tcp or relay via `resolveToken`) —
  win32 windows each own their transport (deviation from the Mac's
  shared cross-window connection, matches the task's "dials the same
  agent" contract). Failed re-dial ⇒ T80 ConfirmDialog (keybind) /
  error response (IPC), never a silent local window. Win32 has no
  per-host default shell store yet, so fresh sessions use the agent's
  default shell (T22-era gap, unchanged).

Evidence: `test/win32/remote-inherit.ps1` ALL PASS ×3 (+1 on the
rebuilt binary) — loopback-agent harness with a marker-dir live-cwd
oracle (cmd.exe emits no OSC 7, so only agent-side GET_CWD inheritance
can land a pane in the cd'd dir), ctrl+t SendInput chord re-runs the
parent's remote command in the new tab, `+new-window --from-focused`
adds a second ESTABLISHED agent connection (netstat assert) and
inherits, local-parent fall-through stays local (no extra connection),
dead agent ⇒ nonzero exit naming the remote machine, app alive after.
P1–P3, ipc-remote, both test lanes: green. ipc-relay ==6/==7 fails
identically at pre-T68 a22134f44 → filed as T81 (pre-existing).

## T69 — Config-error UI on win32 (Phase I)

Found by T51 (F5). A broken config only produces `log.err`
(App.zig:156-165) — invisible in release (GUI-subsystem) builds; the
user gets defaults with no explanation. Mac shows
ConfigurationErrorsController with the diagnostic list.

*Fix:* when config load yields diagnostics, show them once at startup —
a T50-pattern dialog (or T80's TaskDialog) listing file:line + message,
with "Open Config" and "Ignore" buttons.

*Validation:* write a config with a bad key, launch → dialog lists the
diagnostic; fix config → no dialog.

**DONE 2026-07-18.** `App.showConfigErrorsIfAny` formats the config's
`_diagnostics` (capped at 8, "…and N more") and shows a T80
`ConfirmDialog` with custom captions — "Open Config" (runs the extracted
`openConfigFile` helper, same code as the `open_config` action) and
"Ignore". Shown twice: once at startup in `run()` right after the first
window exists (so it has an owner to center on; the dialog's own modal
pump keeps paints/IPC flowing), and after every hard `reload_config`
(soft reloads don't re-parse). ConfirmDialog grew `ok_label`/
`cancel_label` options with a measured button width
(`buttonWidth`, unit-tested; buttons widen past the standard 88 DIP to
fit captions). Evidence: `test/win32/config-errors.ps1` ALL PASS (10)
×3 — broken-config startup shows the dark dialog with the right
captions, Escape ignores and the app lives, clean config shows nothing,
ctrl+shift+comma reload on a newly-broken file shows the dialog (rename
dialog as chord positive control) and stays silent once fixed. P1–P3,
confirm-dialogs.ps1 (20), both test lanes: all green. Config isolation
in the script via `XDG_CONFIG_HOME`.

## T70 — CLI on PATH for Windows installs (Phase H)

Found by T51 (F6). Mac self-heals `~/.local/bin/ghoztty` + shell PATH on
every launch (CommandLineInstaller.swift). The MSI
(`dist/windows-installer/build-msi.sh`) writes no Environment/PATH table
entries; only the manually-set user PATH (2026-07-13) makes `ghoztty`
resolve today. Distinct from T23 (uninstall entry bug).

*Fix:* add the install dir to the user PATH via the MSI Environment
table (and/or a first-run self-check in the app mirroring the Mac flow).

*Validation:* fresh MSI install on a clean PATH → new shell resolves
`ghoztty`; uninstall removes the entry.

**DONE 2026-07-18.** Both prongs:

- *Runtime self-heal* (covers script-delivered installs, the delivery
  path actually used on this box): `src/apprt/win32/PathInstaller.zig`
  runs on a detached thread at the end of `App.init` (master instance
  only). Gate: only acts when the exe runs from
  `%LOCALAPPDATA%\Programs\Ghoztty`, so zig-out/portable never touch
  the PATH; `GHOZTTY_PATH_SELFHEAL=0|off` disables, `=force` bypasses
  the gate (test hook). Reads `HKCU\Environment\Path` preserving the
  value kind (REG_SZ/REG_EXPAND_SZ; bails on any other type), detects
  the entry in any spelling — case, quotes, trailing `\`, or an
  unexpanded `%VAR%` form (compares against the
  ExpandEnvironmentStringsW-expanded value too) — appends only when
  genuinely missing, then broadcasts WM_SETTINGCHANGE("Environment")
  with SMTO_ABORTIFHUNG so new Explorer-launched shells see it. Pure
  decision logic in `path_env.zig` (normalize/eqlDir/contains/append),
  unit-tested in both lanes via apprt.zig.
- *MSI*: `build-msi.sh` gained a `C_UserPathEntry` component
  (`<Environment Name="PATH" Value="[INSTALLDIR]" Part="last"
  Action="set" Permanent="no" System="no">`). **wixl gotcha (0.106):
  it ignores `Permanent="no"`** and emits the Environment table Name
  as `=PATH` — install works but uninstall leaves the entry behind.
  The script now patches the table post-compile (msiinfo export → sed
  `=PATH`→`=-PATH` → msibuild -i), with a grep guard that fails the
  build if wixl's output shape changes. Also made the version-stamp
  sed portable (BSD `sed -i ''` → redirect+mv) so the script runs on
  Linux/Docker as well as Mac.

*Evidence:* `test/win32/path-selfheal.ps1` ALL PASS (13) ×3 on-box
2026-07-18 — location gate (zig-out exe never writes), forced heal
appends exactly once preserving value kind, idempotent relaunch is
byte-identical, quoted/case/trailing-`\` and %VAR% spellings detected
as present, original PATH restored. MSI E2E on-box via a throwaway
`GhozttyPathTest` MSI (distinct UpgradeCode/Name/dir so the real
install is untouched; built with msitools+wixl in a debian:stable
Docker container, same patch): install /qn → user PATH entry appears;
uninstall /qn → entry removed, files gone. The real MSI built by the
updated script shows `=-PATH  [~];[INSTALLDIR]  C_UserPathEntry` in
its Environment table. Regression: P1–P3 ALL PASS, both test lanes
green at HEAD.

## T71 — Claude Code integration setup flow (Phase I)

Found by T51 (F7). Mac detects the `claude` CLI and offers to install
the ghoztty-claude-plugin marketplace plugin (first-run + menu action,
ClaudeCodeIntegration.swift). No win32 trace.

*Fix:* port the detection + prompt (T50-pattern dialog) + a command
palette entry ("Install Claude Code Integration"); run the same
`claude plugin` commands.

*Validation:* on-box with claude installed: palette entry runs the
install; declining is remembered.

**DONE 2026-07-18.** New `ClaudeIntegration.zig` + pure
`claude_setup.zig` (step/outcome/state-grammar logic, unit tests in both
lanes via apprt.zig). Launch check runs on a detached thread with the
PathInstaller-style canonical-install gate (`GHOZTTY_CLAUDE_SETUP`:
`0`/`off` disables, `force` skips the gate): find the claude CLI
(`GHOZTTY_CLAUDE_EXE` override → process PATH claude.exe/.cmd/.bat →
native `%USERPROFILE%\.local\bin` / npm `%APPDATA%\npm` well-knowns);
skip silently — recording `accepted` — when installed_plugins.json
(`GHOZTTY_CLAUDE_PLUGINS_JSON` override) already has any `ghoztty@`
plugin; else post WM_APP_CLAUDE_PROMPT → T80 ConfirmDialog "Set Up
Claude Code Integration?" (Set Up / Not Now; answer persisted at
`%LOCALAPPDATA%\ghoztty\claude_setup`, `GHOZTTY_CLAUDE_STATE_DIR`
override; `declined` is written pre-show so a crash mid-dialog never
turns into a per-launch nag; a missing claude leaves the prompt
unburned). Accepting — or the new "Install Claude Code Integration"
palette entry (local-only like About, T52 pattern) — runs
`claude plugin marketplace add dzearing/ghoztty-claude-plugin` +
`claude plugin install ghoztty@ghoztty-claude-plugin` on a background
thread (create_no_window, .cmd shims handled by Zig's Child; "already"
in output counts as success, the Mac rule; single-flight guard);
outcome returns via WM_APP_CLAUDE_DONE — first-run success stays
silent, palette outcomes and all failures get Mac-parity dialogs
(Ready / Already Set Up / Not Found / Failed+detail). Evidence:
`test/win32/claude-integration.ps1` ALL PASS (26) ×3 on-box 2026-07-18
— stub claude.cmd logs exact command ids; decline persists across
relaunch; accept via Enter runs both commands silently; palette rerun
reports "Claude Code Integration Ready"; no-claude case burns nothing
and reports "Claude Code Not Found". Regression: P1–P3 + both test
lanes green. Known limit: no per-invocation timeout on the claude runs
(Mac uses 120 s) — a hung CLI only wedges its background thread, never
the GUI.

## T72 — Tab accent-color tagging (Phase I)

Found by T51 (F8). Mac tags tabs with 10 named accent colors
(TerminalTabColor.swift); the win32 custom tab bar has no equivalent.
Cosmetic, lower priority. Fix: context-menu submenu on the tab → accent
stripe/background in the owner-drawn tab paint; persist per tab.
Validation: visual + tab context menu exercised in a script where
feasible.

**DONE 2026-07-18.** New pure module `tab_color.zig` (hero_math pattern,
unit tests in both lanes): the 10-value `TabColor` enum in Mac order,
the macOS *dark* system-color RGB table (vibrant on the dark tab bar),
menu labels, and `writeSwatch` — an anti-aliased premultiplied-ARGB
swatch renderer (filled disc per color; ring + slash for None, the Mac
glyph). Window.zig: per-tab `tab_colors` array that rides every tab
shuffle (addTab insert, close shift, moveTab swap, drag moveTabTo — and
moveTab gained the previously-missing hero-state swaps, a latent bug of
the same shape); the tab context menu grew a "Tab Color" submenu
(DPI-scaled 32bpp DIB swatch via MENUITEMINFOW.hbmpItem, MF_CHECKED on
the current pick, bitmaps deleted after the menu closes); paintTabBar
draws a `max(3px·scale, 2)` accent stripe across the top of tagged tabs
(active and inactive — the tag marks the tab, not focus). Evidence:
`test/win32/tab-color.ps1` ALL PASS (11) ×3 on-box 2026-07-18 — ctrl+t
positive control (bar height → DPI scale → tab geometry), right-click →
#32768 menu-window assert, menu driven by first-letter matching ('T'
opens the submenu, 'R'/'N' select — SendInput arrow-key nav proved
unreliable against the menu modal loop, first-letter matching is the
robust path), red stripe pixel-asserted on tab 0 (and absent on tab 1),
stripe persists while the tab is inactive, None clears it. Regression:
P1–P3, hero-mode (60), both test lanes — all green.

## T73 — Honor `split-divider-color` (Phase I)

Found by T51 (F9); corrects the 2026-07-12 audit. `paintDividerNode`
hardcodes `CreatePen(0, line_w, 0x00808080)` (Window.zig:1464). Fix:
read the config color (fall back to current gray), convert RGB→COLORREF.
Validation: set `split-divider-color = #ff0000`, split, divider is red;
config reload re-colors live.

**DONE 2026-07-18.** `paintDividers` computes the pen COLORREF once
(`split-divider-color` orelse the old 0x808080 gray) and threads it
through `paintDividerNode`; `Window.onConfigChange` now repaints
dividers via the same GetDC path layoutSplits uses (the lines live in
inter-pane gaps WM_PAINT never covers), so a config reload re-colors
live. Evidence: new `test/win32/split-divider.ps1` ALL PASS (9) ×3
on-box 2026-07-18 — hermetic config-file launch shows a red divider
pixel in the gap (and no gray), rewriting the file + ctrl+shift+,
re-colors it blue live (polled), defaults run shows the gray fallback;
ctrl+k positive control gates the chord path. Regression: P1–P3,
split-dim (23), both test lanes — all green. Harness note: the script
must call `SetProcessDpiAwarenessContext(-4)` first — virtualized
GetPixel sampling on this >100% DPI box never sees the 1-2 px line
(same lesson as hero-mode.ps1).

## T74 — Implement `unfocused-split-opacity`/`-fill` (Phase I)

Found by T51 (F10); corrects the 2026-07-12 audit (listed honored, is
not — no dimming code exists in the win32 apprt). Mac/GTK dim unfocused
split panes toward `unfocused-split-fill` at `unfocused-split-opacity`.
Fix: layered dim overlay or paint-over in the split container on focus
change (the hero carousel's dimmed thumbs are a separate hardcoded
path). Validation: two splits, unfocused pane visibly dims; config knobs
respected; focus flip updates both panes.

**DONE 2026-07-18.** New `DimOverlay.zig`: per-pane WS_EX_LAYERED +
WS_EX_TRANSPARENT + WS_EX_NOACTIVATE popup owned by the surface HWND
(the Scrollbar.zig pattern — DWM composites it above the pane's OpenGL,
which a plain child window can't do), created lazily on first dim.
Uniform dimming uses SetLayeredWindowAttributes(LWA_ALPHA) + a solid
brush — alpha = (1 − opacity) × 255, fill = `unfocused-split-fill`
orelse `background`, exactly the Mac formula
(Ghostty.Config.swift/SurfaceView.swift). Pure alpha/decision logic in
`dim_math.zig` (overlayAlpha + shouldDim), unit-tested in both lanes
via apprt.zig. `Window.updateDimOverlays` walks ALL tabs (popups don't
hide with their pane's HWND) and runs from: layoutSplits (defer — every
layout path incl. hero/zoom early returns), the surface WM_SETFOCUS
handler, the top-level WM_MOVE handler (screen-positioned popups), and
Window.onConfigChange. Dimming is suppressed for zoom, hero mode,
single-pane tabs, inactive tabs, and opacity=1 (alpha 0 = off).
Evidence: new `test/win32/split-dim.ps1` ALL PASS (23) ×3 on-box
2026-07-18 — three GUI launches: defaults (one overlay over the
unfocused pane, alpha 77 read via GetLayeredWindowAttributes, ex-style
bits asserted, ctrl+alt+up focus flip moves the overlay, zoom hides /
unzoom restores), `--unfocused-split-opacity=1` (no overlay ever), and
`--unfocused-split-opacity=0.5 --unfocused-split-fill=#ff0000
--background=#000000` (alpha 128 + composited screen pixel at the
dimmed pane center reads exactly 128,0,0). Regression: P1–P3,
split-zoom-nav (16), hero-mode (60), both test lanes — all green.
Harness note: wrap 1-element function returns in `@()` (PS 5.1 unrolls
+ pscustomobject lacks intrinsic .Count).

## T75 — Honor `focus-follows-mouse` (Phase I)

Found by T51 (F11). Mac focuses the split under the pointer on
mouse-move when enabled (SurfaceView_AppKit.swift:1049). win32
`handleMouseMove` (Surface.zig:2575-2587) only forwards cursor position.
Fix: when enabled and the surface under the cursor is unfocused, focus
it (via the T48 deferred-SetFocus path). Validation: config on, two
splits, hover switches focus without click; off → no change.

**DONE 2026-07-18.** `Surface.handleMouseMove` now calls a new
`focusFollowsMouse` when the config is set. Two guards before the
`App.deferSetFocus` (T48 — never SetFocus inside a WndProc):
(1) real-motion gate — the app tracks the last mouse SCREEN position
(`App.ffm_last_screen_pos`, shared across surfaces so the guard holds
when the message lands on a *different* pane than the last one); Windows
delivers WM_MOUSEMOVE to whatever appears under a stationary cursor
(split created/closed, pane shown), and without this a pane
materializing under the mouse yanks focus from the pane being typed in —
the win32 analog of the GTK surface's `is_cursor_still` guard.
(2) active-window gate — `GetActiveWindow() == parent_window.hwnd`, so
hovering an inactive window never raises it (Windows convention) and an
open popup (command palette, rename/confirm dialog, machine chooser —
all separate active windows) never has its focus stolen by a stray move
over the terminal. WM_SETFOCUS then does the usual active-surface / hero
/ dim-overlay bookkeeping, so no extra wiring was needed. Evidence: new
`test/win32/focus-follows-mouse.ps1` ALL PASS (10) ×3 on-box
2026-07-18 — run 1 (`--focus-follows-mouse=true`): real cursor glide
(SetCursorPos steps) B→A moves focus to A with no click, glide back
returns it to B; run 2 (default off): same glide leaves focus on B, then
a real click on A still focuses it (positive control that the cursor
genuinely traveled). ctrl+k/clear_screen keyboard control gates run 1.
P1–P3 + both test lanes green at HEAD.

## T76 — Honor `window-inherit-font-size` (Phase I)

Found by T51 (F12). embedded.zig:1427-1431 carries the focused surface's
live (ctrl+scroll-zoomed) font size into new surfaces; win32's newConfig
path only inherits working directory — new windows/tabs/splits snap back
to the configured `font-size`. Fix: mirror newSurfaceOptions in the
win32 new-surface path. Validation: zoom a pane, open tab/split/window →
same size; config off → default size.

**DONE 2026-07-18.** win32 `Surface.zig` init now captures
`app.core_app.focusedSurface().font_size.points` before
`core_surface.init` (focus only moves to the new pane later via the T48
deferred SetFocus, so the focused surface is still the opener) and, when
`window-inherit-font-size` is set and the size differs, applies it AFTER
init via `setFontSize` — exactly the embedded.zig split (options
captured in newSurfaceOptions, applied post-init at embedded.zig:1084),
so `original_font_size` keeps the config default and `reset_font_size`
still returns to it. Covers window/tab/split and IPC-created surfaces
alike (same init path; consistent with how win32 already inherits the
working directory from the focused surface for IPC windows). Evidence:
new `test/win32/font-inherit.ps1` ALL PASS (21) ×3 on-box 2026-07-18 —
two GUI launches (default + `--window-inherit-font-size=false`); oracle
is `mode con` grid columns (full-width down-splits: same font ⇔ same
columns) plus estimated cell px width for the new-window path; ctrl+= ×6
zoom doubles as the injection positive control (64→43 cols). Inherit on:
split and new window both at 43 cols / 14.56 cell px (== zoomed); off:
both back at 64 cols / 9.78 cell px (== default). Both test lanes +
P1–P3 ALL PASS at HEAD.

## T77 — FIX: gotoSplit while zoomed focuses a hidden pane (Phase I)

Found by T51 (F13). `gotoSplit` (Window.zig:1652-1691) never touches
`tree.zoomed`: navigating splits while zoomed moves keyboard focus to a
pane that is not rendered (the zoomed one stays on screen). Mac/GTK
honor `split-preserve-zoom.navigation` (clear zoom by default, or move
it). Fix: in gotoSplit, if zoomed and the target differs — clear zoom
(default) or re-zoom the target per config. Validation: script — zoom,
ctrl+alt+arrow, assert the focused pane is visible for both config
values.

**DONE 2026-07-18.** gotoSplit's leaf arm now mirrors the GTK reference
(`gtk/class/split_tree.zig` ~359): when `tree.zoomed != null`, clear the
zoom (default) or `tree.zoom(dest_handle)` under
`split-preserve-zoom = navigation`, then `layoutSplits()` before the
deferred SetFocus so the target is visible when focus lands; also added
GTK's same-target early-out (`dest_handle == handle`). Evidence: new
`test/win32/split-zoom-nav.ps1` ALL PASS (16) on-box 2026-07-18 — two
GUI launches (default + `--split-preserve-zoom=navigation` via CLI
config arg, user config untouched): zoom B → ctrl+alt+up → default:
zoom cleared, both visible, focus A; navigation: only A visible (zoom
followed); in both, GetGUIThreadInfo-read focus is on a VISIBLE pane
(the bug). ctrl+k positive control + no-crash guards included. Both
test lanes + P1–P3 green.

## T78 — `window-title-font-family` (Phase I)

Found by T51 (F14). Honored on Mac (TerminalController.swift:762); win32
uses plain `SetWindowTextW` — a custom titlebar font needs a custom-draw
caption. Design-level backlog (same tier as window-save-state); revisit
if the custom tab bar ever absorbs the caption row.

**DONE 2026-07-18** (Windows-native scope). The audit's backlog tag only
holds for the DWM caption *text*: on a standard-frame window that font is
system-owned (changing it means replacing the whole caption, which no
native Windows app does short of a full custom titlebar). But win32
Ghoztty already owner-draws the surface where it renders titles — the tab
bar — with an HFONT hardcoded to Segoe UI. The config now drives that
font end-to-end: new pure `src/apprt/win32/title_font.zig` resolves the
face name (Segoe UI fallback for unset/empty/invalid-UTF-8, UTF-16
conversion, LF_FACESIZE-1 truncation that never splits a surrogate pair;
6 unit tests registered in apprt.zig so they run in both lanes);
`Window.createTabFont` (re)creates the font at current DPI scale and
re-pushes WM_SETFONT to the resize overlay so a reload never leaves it
holding a deleted HFONT; `onConfigChange` recreates + invalidates the
bar so `reload_config` re-fonts live. GDI maps unknown faces to a
fallback font, so bad values degrade gracefully. The DWM caption keeps
the system font by design; revisit only if a custom-draw titlebar ever
lands.

Evidence: `test/win32/title-font.ps1` **ALL PASS (9) ×3** — per-column
lit-pixel raster signature over the tab title text + "+" glyph (both
drawn with tab_font): default-vs-Times New Roman diff 430 (CLI arg
path), same-family-via-`--config-file` diff exactly 0 (deterministic
mem-DC rendering; negative control), edit file → ctrl+shift+comma diff
430 back to a raster identical to default (live-reload path, diff 0
vs launch A). Bar height unchanged by family; no crash. P1–P3 ALL
PASS; both test lanes green; win32 Debug GUI build clean.

## T79 — Dark-mode context menus (Phase I)

Found by T51 (F15). Both `TrackPopupMenuEx` menus — terminal
(Surface.zig:2530) and tab bar (Window.zig:2547) — draw with the light
classic menu palette on dark chrome; no
`SetPreferredAppMode`/`AllowDarkModeForWindow`/CBT hook exists anywhere
in the win32 tree (every custom popup dark-themes itself individually).
Fix: call uxtheme ordinal-135 `SetPreferredAppMode(AllowDark)` +
`FlushMenuThemes` at app init (undocumented-but-stable, used by
Terminal/Explorer), matching the app's theme; fall back to owner-draw if
the ordinal is unavailable. Validation: on-box screenshot check of both
menus in dark theme; light theme unchanged.

**DONE 2026-07-18.** New `src/apprt/win32/DarkMode.zig`: resolves uxtheme
ordinals #135 (`SetPreferredAppMode`) and #136 (`FlushMenuThemes`) at
runtime via `LoadLibraryW`/`GetProcAddress` (new decls in win32.zig);
missing ordinals degrade to a no-op (pre-fix light menus), so no
owner-draw fallback is needed — every OS the app supports (1809+, ConPTY
floor) has them. The 1809-vs-1903 #135 signature difference is handled by
probing ordinal #138 (`ShouldSystemUseDarkMode`, 1903+): present →
enum-mode call; absent → BOOL `AllowDarkModeForApp` (force_light maps to
FALSE). Mode derivation mirrors `Window.applyChromeTheme`'s DWM decision
so menus always match the title bar: `dark`/`light` → ForceDark/
ForceLight, `system` → AllowDark (tracks OS apps-theme flips live),
`auto`/`ghostty` → forced by background luminance. `DarkMode.apply` is
called at App.init (before any menu exists), on `config_change`, and in
the top-level WM_SETTINGCHANGE handler (flushes the USER menu-theme cache
on OS flips). Unit test `modeForTheme decision table` registered in
apprt/win32.zig's test block (win32 lane; collection verified by
sabotage-run — 1 failed — then restored).

Evidence: `test/win32/dark-menus.ps1` ALL PASS (6) — real right-click
SendInput opens both menus (surface + tab bar) in two GUI launches;
menu window (class `#32768`) interior screenshot-averaged:
`--window-theme=dark` → avg luminance 52/49 (< 90);
`--window-theme=light` → 240/244 (> 160); no crash. P1–P3 ALL PASS;
both test lanes green; GUI Debug build clean.

## T80 — Dark-mode message boxes (Phase I)

Found by T51 (F16). Six light `MessageBoxW` sites break the dark chrome:
About (Surface.zig:1799), per-window close confirm (Window.zig:2796),
per-surface close confirm (Surface.zig:810), clipboard paste-protection
confirm (Surface.zig:849), child-exited ×2 (App.zig:1243,1252 — note
T65 may remove these). Fix: a small shared T50-pattern confirm dialog
(or `TaskDialogIndirect` + CBT-hook dark theming) used by all sites.
Validation: each prompt visually dark; Enter/Esc semantics preserved;
existing acceptance scripts (close-confirm paths) stay green.

**DONE 2026-07-18.** New `src/apprt/win32/ConfirmDialog.zig`: T50-pattern
dark dialog (dark DWM caption, RenameDialog palette, DarkMode_Explorer
buttons, system icon via `DrawIconEx`, DT_CALCRECT-measured multi-line
text so the About box widens to fit the exe path) with a **synchronous**
API — `show()` disables the owner and runs its own nested message pump,
the exact shape MessageBoxW runs internally (T48-safe: the thread keeps
pumping, IPC's message-only window and renderer wakeups stay live;
WM_APP_SETFOCUS deferred-focus handling is replicated in the pump). All
four remaining sites swapped with zero control-flow change: window close
confirm (`Window.confirmCloseIfNeeded`), surface close confirm
(`Surface.close`), clipboard paste-protection confirm
(`Surface.confirmClipboard`), About box (`Surface.showAboutDialog`,
OK-only + info icon). The child-exited pair was already removed by T65.
Semantics preserved: `default_cancel` mirrors MB_DEFBUTTON2 (focus +
Enter default on Cancel), Escape/✕ cancel (dismiss-as-OK for OK-only),
Tab cycles OK↔Cancel; if dialog construction ever fails it falls back to
MessageBoxW so a prompt is never silently skipped. IPC `+close` was
verified to bypass the confirm (IpcHandlers calls `window.close()`
directly) so automation cannot hang. Layout is pure + unit-tested
(7 tests, win32 lane). Agent-tray MessageBoxes (`src/remote/agent/
tray.zig`) are a separate app with its own light UI — out of scope.
Evidence: `test/win32/confirm-dialogs.ps1` **ALL PASS (20) ×3** — real
ctrl+w / WM_CLOSE(X) / palette-"about" each open a `GhozttyConfirmDialog`;
screenshot-sampled interiors dark (avg lum 45/42/39); Escape cancels;
Enter-on-default cancels (window stays); Tab+Enter approves (window
closes); About round-trip crash-free. P1–P3, ipc-child-exited, and both
test lanes green at HEAD.

## T81 — FIX: GUI unresponsive after agent death under a live relay window (Phase G)

Found 2026-07-18 by the T68 regression sweep. `ipc-relay.ps1` ==6/==7
now report 3 FAILURES: after `Stop-Process` on the relay-mode agent
under a live relay window, `+list` does not answer within 15s ("+list
still answers after agent death" FAIL), and although `+close
--target=relwin` later succeeds (20s bound) the follow-up list no
longer shows the base window ("app survived the teardown" FAIL).

**PRE-EXISTING, not a T68 regression:** reproduced byte-identically at
`a22134f44` (pre-T68 HEAD, detached-checkout rebuild) — same 3
assertions fail, sections 1–5 all pass. The suite last ran green at
T21b-era HEAD, so the break landed somewhere in the T48–T80 span
(candidates: T48 SetFocus deferral, T62/T63 read/close paths, T65
child-exited rework — bisect first).

**ROOT CAUSE (2026-07-18): a process-killing PANIC, not a hang.** When
the agent dies, the relay drops the client WebSocket without a WS close
frame; the mux pump's `transport.read` errors → `shutdownOnce` →
`WsClient.closeImpl`, which did `posix.shutdown(.both)` and THEN sent a
"best-effort" WS close frame. On Windows that send returns
`WSAESHUTDOWN`, which `std.net.Stream.Writer`'s `handleSendError` maps
to `unreachable` → the whole GUI process aborts (debug stack:
`pumpInput → shutdownOnce → transport.close → closeImpl →
sendCloseDuringShutdown → flushOut → std sendBufs → unreachable`). The
"15s +list hang" was the CLI waiting on a server dying mid-panic
(symbolizing the stack takes seconds, during which IPC still answers);
the "missing base window" afterwards was simply no app left. Repro'd
outside the harness with GUI stderr captured (manual script, kill →
panic ~t+3–13s, process exit).

**Bug 2 (why a clean `+close` never crashed):** `Window.onDestroy` —
the path every WM_CLOSE/`+close` takes — skipped `deinit()`'s remote
teardown entirely: `remote_dialed` (connection + ws socket + pump/
reader/writer/heartbeat threads) LEAKED on every remote-window close,
so the healthy-close path never even reached `closeImpl`.

*Fix (this commit):*
- New `src/remote/socket_rw.zig`: `recvOnce`/`sendOnce` with COMPLETE
  Winsock/errno mappings (extraction of `socket_stream.zig`'s
  `posixRecv`/`posixSend`; every close-race flavour → `error.Closed`
  etc., never std's `unreachable`) + heap-pinned `std.Io.Reader`/
  `Writer` impls over them. `ws_client.zig` now uses these instead of
  `std.net.Stream.Reader/Writer` (whose overlapped send/recv path
  panics on `WSAESHUTDOWN`/`WSA_OPERATION_ABORTED`); also fixes the
  same class agent-side (the agent reuses `WsClient`), and the ws
  socket now gets `SO_NOSIGPIPE` on Darwin (parity with SocketStream).
- `closeImpl` no longer sends a close frame after `shutdown(.both)` —
  it could never be delivered on ANY platform post-shutdown; peers must
  treat raw EOF as disconnect (already the documented contract).
- `Window.onDestroy` tears down `remote_dialed`/`remote_machine` like
  `deinit()` (safe: `close()` ran `cleanupAllSurfaces` first, so no
  termio backend borrows the conn).
- Unit tests in `socket_rw.zig` incl. the T81 regression (flush after
  `shutdown(.both)` must be `error.WriteFailed`, not a panic), wired
  into both lanes (`main_ghostty.zig`) and `test-agent`
  (`agent_test.zig`).

*Evidence (2026-07-18, on-box):* `ipc-relay.ps1` ALL PASS ×3 (was 3
FAILURES at ==6/==7); P1–P3 + `remote-inherit.ps1` ALL PASS; both unit
lanes green. `test-agent` failures proven PRE-EXISTING (identical 5
failures + crash at a 52e1fd73b baseline worktree) → filed T82.
Related: T56 (reconnect) unchanged — a dead link now degrades to a
quiet EOF'd session instead of killing the app.

## T82 — FIX: `zig build test-agent` never green on Windows (Phase G)

Found during T81 (2026-07-18) and proven pre-existing: a baseline
worktree at 52e1fd73b (pre-T81-fix) shows the IDENTICAL failure set.
Not part of the parity validation lanes (`-Dapp-runtime=none`/`win32`
+ P1–P3), so it went unnoticed.

Failure inventory (agent-core aggregator `ghoztty-agent-core-test`,
160/167 at baseline; 164/171 with T81's 4 new socket_rw tests):
- `keepalive` integration ×2: the TEST HARNESS's `TestWsServer.
  handleConn` reads with `std.net.Stream.read` → `windows.ReadFile`
  on an overlapped SOCKET with a null OVERLAPPED →
  `GetLastError(87)` (ERROR_INVALID_PARAMETER) → upgrade never
  answered → dial fails. Fix direction: use `socket_rw.recvOnce` (or
  the Reader) in the harness instead of `Stream.read`.
- `self_update` ×3 (`checkAndStage`, `applyStaged`, `runLoop`): same
  87 signature via `http_client`'s std reader against the local test
  HTTP server; `runLoop` then fails `expect(staged)`.
- A leaked thread from the failed integration tests crashes later
  (exit 3), attributed by the runner to whatever test is executing —
  observed against `socket_stream: close unblocks a blocked read`
  (that test is fine in isolation; do NOT chase it first).
- `ghoztty-agent-test` root: `pty_child: real pty spawn` segfault
  (0xffffffffffffffff, KERNELBASE) — separate, needs its own look.

*Validation:* `zig build test-agent` exits 0 on the box, three runs in
a row; the parity lanes + P1–P3 stay green.

## T83 — FIX: goto_tab off-by-one on win32 (found by T01)

`ctrl+1` selected tab 2, `ctrl+2` was a no-op with two tabs. Root cause:
`Window.selectTab` treated the `GotoTab` payload as a 0-based index, but
the configured value is 1-indexed (`goto_tab:1` = first tab) on Mac
(`TerminalController.onGotoTab`: "The configured value is 1-indexed",
out-of-range clamps to the last tab) and GTK. Fix in `Window.zig`
`selectTab`: `_` arm now rejects `raw < 1` and selects
`@min(raw - 1, tab_count - 1)`.

*Validation:* `keybinds-t01.ps1` ctrl+1/ctrl+2/ctrl+9 assertions green on
the box (selected-tab index via `+list --json`); both test lanes + GUI
build green.

*Evidence (done 2026-07-18):* fixed in the T01 session, same commit.
Post-fix run: ctrl+1 selects tab 1, ctrl+2 selects tab 2, ctrl+9 selects
the last tab.

## T84 — FIX: ^C never signals the ConPTY child (found by T01)

User impact: a runaway native command (`ping -t`, `type` of a huge file,
any non-TUI child) cannot be interrupted with ctrl+c in a Windows shell
pane. TUI apps (Claude Code, vim) are unaffected — they read raw 0x03
themselves, which is why daily use never surfaced this.

Findings from the T01 session (2026-07-18, all verified on the box):
- Repro WITHOUT keybinds: `+send-keys --target=<pane> C-c` against a
  cmd.exe pane running `ping -t 127.0.0.1` → ping keeps running (raw
  0x03 IS written to the ConPTY input pipe — `normalizeConptyInput`
  passes it through; typed echo commands through the same path land).
- The keybind side is CORRECT: ctrl+c matches `copy_to_clipboard=.mixed`
  (performable), core returns false with no selection, the event falls
  through to encoding (win32-input mode or raw). With a selection, copy
  works (clipboard verified).
- `CommandCore.startWindows` does NOT pass `CREATE_NEW_PROCESS_GROUP`
  (which would disable ^C for the tree) — flags are only
  `CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT`.
- `CreatePseudoConsole` is called with flags=0 (`src/pty.zig:430`).
Open question: why doesn't conhost cook 0x03 (or the win32-input-mode
ctrl+c sequence) into CTRL_C_EVENT? Next step: standalone probe — extend
the `conpty_smoke.zig` pattern to spawn `cmd`, run `ping -t`, write
0x03, observe; compare against a WT/openconsole reference. Also check
whether the win32-input-mode encoding of ctrl+c (Uc=0x03, ctrl-state
bits) matches Windows Terminal's byte-for-byte.

*Validation:* `keybinds-t01.ps1` goes ALL PASS (its SIGINT assert is the
regression oracle); manual ctrl+c on a real keyboard stops `ping -t` in
cmd, PowerShell, and git-bash panes.

**RESOLVED 2026-07-19.** Root cause: the **inherited ignore-Ctrl-C
flag**, not ConPTY/conhost. A process created with
`CREATE_NEW_PROCESS_GROUP` starts with ^C delivery disabled
(`SetConsoleCtrlHandler(NULL, TRUE)` semantics), and that flag is
inherited by every descendant across `CreateProcess` — through GUI
processes and into ConPTY children. The T01 session launched the GUI
from an automation chain that had the flag set, so cmd/ping in every
pane inherited ^C-disabled; conhost cooked 0x03 → CTRL_C_EVENT
correctly all along. The same failure hits real users whenever the GUI
is auto-launched by `+new-window` from a flagged chain (scripts, CI,
Claude Code sessions — the common launch path on this box).

Probe evidence (conpty_smoke, new `--ctrlc*` scenarios): raw 0x03 AND
win32-input-encoded ^C failed in ghoztty's Pty, an anon-pipe ConPTY,
classic `conhost --headless`, AND WT's OpenConsole with the same
driver; a `--report-ctrlc` child with an armed handler observed the
event is simply never delivered; `GenerateConsoleCtrlEvent` (no VT, no
ConPTY, visible or hidden console) also failed → not a cooking bug.
Clearing the flag in the spawning parent flipped every scenario to
INTERRUPT OK / EVENT DELIVERED.

Fix: `w32.SetConsoleCtrlHandler(null, 0)` at the top of win32
`App.init` — children spawned by this instance inherit ^C enabled
regardless of how the GUI was launched. Verified end-to-end from the
worst-case chain: `+send-keys C-c` stops `ping -t` (the original
repro), and `keybinds-t01.ps1` is ALL PASS (23/23) incl. SIGINT.

Test-harness trap recorded for future probes: any interrupt-delivery
test spawned from an automation harness MUST clear the ignore flag
first or it false-negatives (conpty_smoke now does this in `main`).

## T86 — Harden foreground grab across kb-injection test scripts

Found by T25: with a browser window foreground on the unattended box,
`SetForegroundWindow` from a background process is silently ignored, so
every chord-injection script aborts its positive control ("foreground
owned by another window"). The fix (proven in `hero-mode.ps1`, 2026-07-19)
is two-part, inside the grab retry loop: (1) `AttachThreadInput` to the
*current foreground owner's* thread for the duration of the grab, and
(2) inject an Alt tap via `SendInput` first so this process is the
last-input source — both halves of the Win32 foreground-permission rules.
Port that loop to the other ~20 scripts that call
`SetForegroundWindow(top)` (keybinds-t01, kb-actions, profile-latency,
split-*, tab-color, title-font, window-color, font-inherit, ipc-version,
ipc-machine-chooser, ipc-child-exited, focus-follows-mouse,
confirm-dialogs, config-errors, claude-integration, remote-inherit, …
grep for `SetForegroundWindow(top);`).

*Validation:* with a non-ghoztty window deliberately foregrounded (e.g.
`Start-Process notepad` + focus it), each ported script still reaches its
positive control and passes; scripts stay ALL PASS in the normal case.

## T87 — Mac seat: macOS regression build + merge to main (T25 tail)

The working agreements require the Mac regression build
(`zig build -Doptimize=Debug` with the Mac toolchain) green before any
merge to main. T25's on-box conformance is complete (see T25 evidence);
this task is the Mac-side remainder: run the regression build, then merge
`users/dzearing/windows-amd64` to main. Also the natural moment for a
live relay dial to a real Mac device (§8 item 9's only untested leg) and
the T29/T30 Mac-side fixes.

*Validation:* Mac build green; merge lands; post-merge `+list` smoke on
both OSes.

## T88 — Merge latest origin/main + parity analysis (user directive 2026-07-19)

Merged origin/main `8bb5d9845` (154 commits, 137 files, +28k lines) into
`users/dzearing/windows-amd64` (merge `74322cf05`). Three conflicts, all
trivial (.gitignore both-added, CLAUDE.md both-added bullets under
`--shell`, connection.zig test using this branch's mutex-guarded
`seenChannel()` vs main's u128 atomic). Three post-merge Windows fixes
(`362d1d4bc`):

- `src/Surface.zig` — the new session-persistence shell-integration
  switch didn't handle the T27 `.powershell` flavor (compile error);
  added to the argv-rewrite arm (powershell integration IS an argv
  rewrite: `-NoExit -Command` dot-sourcing ghostty.ps1).
- `src/remote/connection.zig` — main's new `relaunch_channel:
  std.atomic.Value(u128)` doesn't compile on x86_64 (no 128-bit
  atomics); converted to the same mutex-guarded pattern as
  `seen_channel`.
- `src/remote/protocol.zig` — `Hello.encode` used default stringify
  options, which EMIT null optionals on zig 0.15.2, so main's own new
  back-compat test ("null build_version is elided") was red; encode now
  passes `.emit_null_optional_fields = false` (matches `encodeJson` and
  the documented additive-field contract). This test was failing on main
  itself — flag to the Mac seat.

**Incoming feature clusters and their Windows disposition:**

1. **Session persistence** (~60 commits; `src/remote/agent/*`,
   `src/cli/sessions.zig`, macOS LocalAgentManager/manifests/restore,
   config `session-persistence`/`session-relaunch`, `+sessions`,
   CLAUDE.md "Session Persistence" + agent-contract sections) → gap:
   entire feature is macOS-gated (AF_UNIX agent socket, LaunchAgent,
   peercred). Filed **T89a/T89**.
2. **Viewer panes** (~15 commits; `--view` on +new-window/+split,
   src/viewer/* vendored offline renderer assets, macOS WKWebView
   feature set, `+list` `view:`/`type:viewer` marks, viewer IPC error
   contract) → gap: no win32 viewer. Filed **T90a/T90**. Note the
   CLI-side `--view` plumbing and `+list` formatter changes are shared
   and already on this branch post-merge; win32 IpcHandlers must reject
   `--view` gracefully until T90 (currently it forwards the arg — the
   server ignores unknown args, so behavior is "opens a terminal";
   acceptable until T90, but T90a should pin the interim error).
3. **Banner markdown upgrades** (Mac `SurfacePaneBanner.swift`:
   headings, tables incl. headerless + bold-width columns + cell wrap,
   task-list checkboxes, aligned bullet/ordered lists, `---` rules,
   block gaps, symmetric padding/content inset, shaded bg sharing the
   pane tint hue, collapse toggle) → win32 `banner_markdown.zig` +
   strip overlay support a smaller subset. Filed **T91**.
4. **Window-level titles** (core `prompt_window_title` action +
   `PromptTitle.window`; ctrl/cmd+shift+r REBOUND from
   prompt_surface_title to prompt_window_title; Mac adds separate
   Change Pane/Tab/Window Title commands; `+rename --title=""` clears
   the pin; titlebar falls back window → tab → pane) → win32
   `.prompt_title` handler ignores the payload and always opens the T50
   window-rename dialog, so ctrl+shift+r still works post-merge (no
   regression), but the three-level title model + empty-clears-pin need
   a real port. Filed **T92**.
5. **Brokered OAuth (BFF)** (relay /oauth/exchange, /renew, /signout +
   session tokens; Mac client drops the client secret; build-time
   `-Dgoogle-client-id`) → win32 `+relay-login` still runs the
   Desktop-app + client-secret flow against Google directly. Filed
   **T93**.
6. **Split divider grab handle** (Mac: real ~9pt AppKit hit target) →
   win32 divider hit target unverified. Filed **T94**.
7. **Shared-core improvements Windows gets for free** (verify, no port
   needed): termio RESIZE routed around the bounded mailbox
   (`eb1876f09`), `+sessions`/CLI arena race fix (`f014f4dc7`),
   remote-core structured snapshot + delta replay & HELLO
   hostname/build_version/capability negotiation (used by win32 remote
   windows too — T56 reconnect should build on `grid_snapshot`),
   login-shell resolution in IPC resolveShell (`646651574`, POSIX
   branch only — win32 has its own flavor logic).
8. **Mac-only platform integration** (AppleScript, App Intents,
   QuickTerminal restoration, `open -a` / dock drop): no Windows
   analog planned; viewer file-association piece is folded into T90.

*Validation:* merge committed; Debug GUI build + both test lanes green;
P1/P2/P3 ALL PASS on-box. Tracker rows T89a–T94 filed with details
sections; log entry appended.

## T89a — Session persistence on Windows: design (Phase K)

Port the session-persistence feature (CLAUDE.md "Session Persistence"
section; `docs/design/session-persistence.md`) to Windows. T89a is the
design pass; it must produce a decided architecture + a split of T89
into right-sized implementation tasks (the Mac effort took ~60 commits —
expect T89b..T89x). Design questions to settle, with recommended
starting points:

- **Transport**: the agent's app-facing socket is 0600 AF_UNIX +
  SO_PEERCRED. Windows: named pipe (`ghoztty-agent-<user>`) with an
  owner-only DACL (the IpcServer.zig pattern) OR localhost TCP +
  token. Named pipe is the natural fit; the agent core already
  comptime-gates UDS (`c7b372892`).
- **PTY ownership**: agent owns ConPTY pseudoconsoles; app re-attaches
  by streaming the agent's ring + grid snapshot (the `grid_snapshot`
  capability landed in remote-core and is transport-agnostic). The
  inherited-ignore-^C lesson (T84) applies to agent-spawned children.
- **Autostart**: LaunchAgent analog = HKCU Run key or per-user
  scheduled task (survives reboot; scheduled task can restart-on-crash).
- **Storage**: `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\`
  (sessions.json, ring snapshots) mirroring the Mac layout.
- **Config**: honor `session-persistence` / `session-relaunch` on
  win32 (docs currently say "macOS"; un-gate once the agent works).
- **Scope order**: local persistence first (survive app quit/upgrade/
  crash), then reboot scrollback (ring snapshots), then agent lazy
  upgrade + the wire-contract rules (CLAUDE.md "Agent contract"), then
  cross-machine browse (Mac T16–T18 are also still open).
- **Quit flow**: quit must not threaten sessions that survive
  (`853ec3168`); win32 close-confirm logic needs the same carve-out.
- **`+sessions`**: the CLI verb is shared; it needs the Windows dial
  path (named pipe) + `--pid`-style docs.
- **T82 cleanup** (agent-core tests red on Windows) is a natural
  prerequisite — fold its fix into the first implementation task.

*Validation:* design section written here + T89 split into sized
subtask rows; no code.

## T89 — Session persistence on Windows: implement (Phase K)

Placeholder for the implementation series; T89a will split it. End
state: parity with CLAUDE.md "Session Persistence" — new local
windows/tabs/splits run under a Windows `ghoztty-agent`, survive app
quit/crash/upgrade with same-PID re-attach (layout, titles, cwd,
scrollback), reboot relaunch per `session-relaunch`, `+sessions` works,
agent upgrade is lazy + non-destructive, and the E2E harness
(`scripts/e2e/session-persistence.py` or a PS port) passes on-box.

*Validation:* per-subtask scripts + an on-box kill/upgrade/reboot E2E;
both lanes + P1–P3 stay green.

## T90a — Viewer panes on Windows: design (Phase K)

Port viewer panes (CLAUDE.md "Viewer Panes") to win32. Mac uses
WKWebView + a bundled offline renderer (`src/viewer/viewer.html` +
vendored markdown-it/highlight.js/DOMPurify — already shared assets on
this branch). Windows: **WebView2** is the recommended engine (ships on
Win11; runtime detection + graceful fallback error pane when absent).
Design must cover: PaneView-equivalent in the win32 split tree (panes
are currently all terminal surfaces — the SplitTree leaf needs a
viewer variant, mirroring Mac's `SplitTree<PaneView>` retype); the
custom-scheme/virtual-host mapping for the offline renderer; `--view`
resolution (shared CLI already rewrites relative paths); live-reload
file watcher (ReadDirectoryChangesW, atomic-save survival); link
routing policy; `+list` `view:` prefix + `"type":"viewer"`/`"url"`
JSON; `+read`/`+send-keys`/`+set-state`/`+set-banner` → "is a viewer
pane, not a terminal" exit 1; `+close` never prompts; focus/zoom/
equalize/nav keybinds with viewer focus; session-persistence restore
(depends T89 ordering — viewers restore by re-opening); `.md` file
association (interim: skip installer wiring, palette + CLI only);
palette open-in-pane commands; interim behavior for `--view` before
T90 lands (explicit "viewers not yet supported on Windows" error
beats silently opening a terminal — pin in design).

*Validation:* design section + T90 split into sized subtasks; no code.

## T90 — Viewer panes on Windows: implement (Phase K)

Placeholder; T90a splits it. End state: `+new-window --view` /
`+split --view` render markdown/text/websites in win32 panes per
CLAUDE.md, with live reload, link routing, IPC contract, and palette
commands; validated by a `viewer-panes.ps1` acceptance script.

*Validation:* `viewer-panes.ps1` ALL PASS ×3; P1–P3 + both lanes green.

## T91 — Banner markdown parity with Mac (Phase I)

Mac's pane banner grew: headings; tables (GFM + headerless, columns
sized to BOLD render width, long-cell wrap); task-list checkboxes
(native look); aligned bullet/ordered lists (incl. checkbox-led list
leading gap + consistent text-line block gaps); `---` horizontal-rule
separators; symmetric padding + content inset; shaded background that
shares the pane tint hue (T67 tint exists on win32); a collapse
toggle. Win32 (`src/apprt/win32/banner_markdown.zig` + the T35 strip
overlay) supports bold/italic/underline/code/links/multi-line only.
Port the delta into the pure zig parser + owner-drawn strip (unit
tests in both lanes for parsing/layout math;6-line display cap may
need revisiting for tables/collapse).

*Validation:* extend `pane-banner.ps1` (table/checkbox/heading/hr/
collapse assertions) ALL PASS ×3; unit tests green in both lanes.

*Evidence (done 2026-07-19):* `banner_markdown.zig` rewritten as a block
parser mirroring the Mac `BannerMarkdown` enum: `parseBlocks` →
text/heading/rule/list/table blocks, native `.checkbox` inline segments
(glyph fallback in nested spans and mid-paragraph, `[x](url)` stays a
link), ATX headings (7-hash/no-space stay text), `- - -` thematic
breaks, mixed-marker list runs (`- `/`* `/`1. `/`[x]`, decimal `1.5`
excluded), GFM tables (escaped `\|`, `:` alignment, ragged-row
pad/truncate, all-empty header = headerless), display cap 6→10 with
Mac's exact row accounting, plus a pure `wrapTokens` greedy word-wrap
for layout tests. `BannerOverlay.zig` rewritten as a shared
measure/draw walker (one code path for height + paint): 12dip padding,
8dip block gaps, heading sizes 17–12pt-equivalent, full-width rule
divider, marker-gutter lists (drawn dot, secondary ordered numbers,
RoundRect native checkboxes — green wash/border/check via
strip-bg blends), tables with bold-measured column widths (+2 slack,
360dip cap), per-cell word wrap growing row height, `:` alignment,
header divider; collapse toggle on click for multi-line banners
(chevron up/down, 30dip first-line sliver with an AlphaBlend
alpha-ramp fade, single-line banners keep click-to-focus). Strip bg
already keyed off the pane tint (T67 path). Validation: pane-banner.ps1
grown 30→37 asserts (10-line cap arithmetic, h1 taller than text, hr
thinner than a text row, 4-source-line table renders 3 rows, ScanGreen
finds native green check pixels, PostMessage click collapse/expand
round-trip) ALL PASS ×3; both unit lanes green; P1–P3 ALL PASS.

## T92 — Window-level titles: three-level model + pin semantics (Phase I)

Port the Mac window-title model: `prompt_window_title` (ctrl+shift+r —
the default bind CHANGED upstream from prompt_surface_title) pins the
window titlebar over tab/pane titles until cleared (empty input
clears); titlebar precedence window-pin → active tab title → active
pane title; separate palette commands "Change Window Title…",
"Change Tab Title…", "Change Pane Title…" (win32 palette currently
only has the T50 "Rename Window"); `+rename --title=""` must CLEAR
the pin (verify win32 IpcHandlers — Mac fixed this in `9c7665354`);
win32 `.prompt_title` must branch on the `PromptTitle` payload
(surface/tab/window) instead of ignoring it. Post-merge state: no
regression (ctrl+shift+r still opens the T50 dialog), but all three
prompts funnel to the same window-level override.

*Validation:* new `window-title.ps1` — pin wins over OSC title, empty
clears, tab/pane prompts set their own levels, `+rename` empty-title
clear; ALL PASS ×3.

**DONE 2026-07-19.** Implementation:

- `Surface.zig`: `title_from_terminal` field — non-null while a manual
  pane title is held; `setTitle` (OSC path) then updates the remembered
  terminal title instead of displacing the user's; `setUserTitle`
  sets/clears, clearing restores the remembered title (Mac
  `SurfaceView.titleFromTerminal` parity). Freed in deinit.
- `Window.zig`: `tab_title_pinned[MAX_TABS]` (mirrored through every
  tab shift/swap/move site); `onTabTitleChanged` skips pinned tabs AND
  non-focused panes (tab title = focused pane's title, Mac parity);
  `refreshTabTitle` re-derives on pane focus change (hooked in App.zig
  WM_SETFOCUS); `setTabTitlePin`; inline tab rename now pins (empty
  clears); `setTitleOverride` treats empty as clear; prompt helpers
  `promptTabTitle`/`promptPaneTitle`.
- `RenameDialog.zig`: `Level = {pane,tab,window}` — per-level caption
  ("Change Pane/Tab/Window Title"), label, prefill, and commit path
  (`setUserTitle` / `setTabTitlePin` / `setTitleOverride`); pane/tab
  targets resolved at commit via address-only `findTabIndex` so an
  IPC-closed pane no-ops. Pure caption/label unit tests added.
- `App.zig`: `.prompt_title` branches on the PromptTitle payload
  (surface/tab/window) instead of always opening the window dialog.
- `IpcHandlers.zig`: `+rename --title=""` and `+new-window --title=`
  clear/skip the pin instead of pinning an empty string (Mac 9c7665354).
- Palette: "Rename Window" replaced by "Change Window Title…" /
  "Change Tab Title…" / "Change Pane Title…" (command.zig naming).
- kb-actions.ps1 caption assert updated ("Change Window Title").

*Evidence:* `window-title.ps1` ALL PASS (46) ×3 (S1 OSC baseline, S2
IPC pin+clear, S3 ctrl+shift+r dialog E2E, S4 pane prompt incl.
remembered-title restore, S5 tab pin vs OSC, S6 three-level peel);
ipc-p1/p2/p3 ALL PASS; hero-mode.ps1 ALL PASS (60) (palette
regression); both unit-test lanes green. kb-actions.ps1 self-skipped
(un-hardened foreground grab, pre-existing — T86).

## T93 — Brokered OAuth (BFF) for Windows relay sign-in (Phase G)

Mac moved to relay-brokered OAuth: the app never holds the Google
client secret; it exchanges the auth code at the relay
(`/oauth/exchange`), stores an opaque session token, renews via
`/renew`, signs out via `/signout`; the Google client id is baked at
build time (`-Dgoogle-client-id`, release workflow bakes it into the
DMG). Win32 `+relay-login` still does the direct Desktop-app +
client-secret flow and DPAPI-stores the refresh token. Port: reuse
the loopback-redirect browser flow but exchange at the relay;
DPAPI-store the session token + email; token-resolution order in
`+new-remote-window` unchanged (explicit `--token` → account →
`GHOSTTY_RELAY_TOKEN`); `+relay-logout` calls `/signout`; bake the
client id via the existing build option on Windows release builds;
keep reading legacy DPAPI refresh-token stores (or force one
re-login with a clear message — decide in-task).

*Validation:* extend `ipc-relay-login.ps1` fake-issuer harness with
brokered endpoints; ALL PASS ×3.

## T94 — Split divider grab-handle hit target (Phase I)

Mac replaced the hairline divider hit area with a real ~9pt AppKit
grab handle (`001834466`). Verify the win32 split divider drag hit
target (regular splits, not hero) and widen to a comparable
DPI-scaled band (~9 DIP) if it's hairline-width today; cursor
feedback (SIZEWE/SIZENS) over the whole band.

*Validation:* `split-divider.ps1` gains a hit-target assertion
(drag from ±4 DIP off the divider line still resizes); ALL PASS ×3.

*Done 2026-07-19.* Verified the old target was ±3 DIP AND effectively
clipped to the ~5 DIP visual gap: pane child HWNDs cover everything
outside the gap, so the parent never saw mouse input past ±2.5 DIP.
Two-part fix:

- `Window.hitTestDividerNode`: half-band 3.0 → 4.5 DIP (min 4 px),
  ~9 DIP total per Mac `001834466`; `hitTestDivider` made pub.
- `App.surfaceWndProc` WM_NCHITTEST (new w32 consts WM_NCHITTEST /
  HTTRANSPARENT): if the screen point maps into the parent's divider
  band, return HTTRANSPARENT so the hit falls through to the parent
  Window, which already owns drag + SIZEWE/SIZENS cursor feedback
  (WM_SETCURSOR → hitTestDivider). Suppressed during an active drag;
  popups (search/palette) unaffected.

Evidence: `split-divider.ps1` grew a T94 tail on the default-config run
— SIZENS on the line and at ±4 DIP over the pane surfaces (proves the
fall-through, not just the gap), no SIZENS at pane center (band
bounded), and two real-input drags starting +4/−4 DIP off the line each
moved the divider (1252→1336→1251 px). ALL PASS (15) ×3; P1–P3 ALL
PASS; both test lanes green. Bonus: the script's foreground grab now
uses the T86 hero-mode pattern (attach-to-fg-thread + Alt tap + retry)
— the plain grab ABORTed on this box with a browser focused.
