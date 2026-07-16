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

## T24 — Windows release channel + enable update check (Phase H)

Publish Windows builds as GitHub releases tagged `win-vX.Y.Z`; remove the
`if (true) return;` in `startUpdateCheck`; on newer tag → notify with a
link (portable) or download+launch MSI (once T23 lands). Decide notify-only
vs auto-install and record here.

*Validation:* box on older version + newer tag published → update prompt
appears within the check interval; following it lands the new version.

## T25 — Full conformance checklist, spec §8 end-to-end (final gate)

Run spec §8 items 1–10 end-to-end on the box from a fresh start, including
the CLAUDE.md three-pane example verbatim. Update spec §9 status table.
Then: macOS regression build green, merge to main per the working
agreements.

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

Static analysis (code read, unverified vs dump) candidate causes ranked:

1. GUI-thread reentrant win32k callback self-block — same class as the
   fixed WM_GETOBJECT/oleacc hang documented at
   src/apprt/win32/App.zig:2294 (EventPairLow matches that signature);
2. GUI thread blocks on renderer_state.mutex per keystroke
   (src/apprt/win32/Surface.zig:2534 isWin32InputMode, also
   IpcHandlers.zig:358 +read) while PTY-reader thread holds it in
   processOutputLocked (src/termio/Termio.zig:675) — starvation unless
   owner itself blocked;
3. unsynchronized shared CS_OWNDC HDC: GUI WM_ERASEBKGND FillRect
   (App.zig:2211) vs renderer-thread wglMakeCurrent/SwapBuffers
   (renderer/OpenGL.zig:266,336).

IPC pipe-busy is downstream: listener blocks unbounded on GUI thread at
IpcServer.zig:294.

NEXT: wait for a symbolized watchdog dump, then confirm cycle via ~*kb +
lock-owner walk. The refreshed install has a matching pdb, so the next
watchdog dump WILL be symbolizable. Adversarial investigation applies.

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

## T52 — Build provenance visible in-app (Phase I)

The 2026-07-15 "no parity" report came from a July-5 exe among FOUR
coexisting builds. Surface version+commit+build date where a user/session
can trivially see it: `+version` verb over IPC (and CLI), the
About/palette surface, and `+list --json` metadata; include the git hash
at build time.

*Acceptance:* from any pane, one command answers "which build is this
window running?"

## T53 — Long-context reliability + perf soak/tuning (Phase I)

User 2026-07-15: "usable for long contexts... not slow, or crashing, well
tuned". Build an on-box soak harness: hours-long Claude-Code-like TUI load
(streaming, alt-screen churn, big scrollback) across several panes; watch
GHOZTTY_PERF telemetry (fps/max-gap/wakeups), memory growth
(scrollback/page_list), handle counts, and the T48 watchdog. Fix what it
surfaces (each finding = task row or fix-in-place if small). Also: profile
input latency and scrollback-seek on huge histories; verify no degradation
at 100k+ lines.

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
