# Windows parity — task tracker

**This is the canonical resume doc for the Windows parity effort.**
It is deliberately small: the state table is ground truth, and everything
narrative lives elsewhere (see "Related docs"). Do not grow table rows past
one line — put detail in `windows-parity-details.md`.

## Resume protocol (fresh session starts here)

**ONE TASK PER CONTEXT, then reset.** (A session that chained tasks hit a
716k context on 2026-07-12. Everything needed to resume lives in git + this
doc.) See `go.md`.

1. Read `go.md` and this doc ONLY. Do NOT read the details/log/audit/spec
   docs wholesale — they are split out precisely to keep resume cheap.
2. Pick the first task in **Current priorities** below; if that list is
   empty, the first `todo` row in the state table whose deps are `done`.
3. Read ONLY your task's section in `windows-parity-details.md`
   (Grep `^## T<id> ` for its line, then Read that slice). Before any IPC
   task, also read the "Architecture decisions (pinned)" section of
   `windows-parity-spec.md`. First session on a fresh box: read the
   "Bootstrap & environment" section of the details doc too.
4. Set the row `in-progress` (fold the doc edit into the task's first
   commit). Implement methodically. Small commits on
   `users/dzearing/windows-amd64`.
5. Run the task's **Validation** (in its details section). Do not mark
   `done` on a clean build alone — validation must actually pass, on the
   box when it says so.
6. Update: the state table row (status + commit hash — ONE line), the
   task's details section (evidence), and append ONE short dated entry to
   `windows-parity-log.md` (a few lines; no build output, no diffs).
7. Push, then **reset context** (`/reset-context read go.md and go`) and end
   the turn. Do not start the next task in the same context.

Task sizing: if a task looks like it will exceed ~250k context, split it in
the table first (e.g. `T19a` design + `T19` implement) and commit the split.
Keep tool output small — grep build logs for `error`, take only the last
line of acceptance scripts (they print ALL PASS / N FAILURE(S) by design).

New tasks: add a table row + a details section (bugs found during
validation become tasks, not loose threads). Never delete a task — mark
`skipped(<reason>)` so decisions stay visible.

**THE GOAL (user, 2026-07-15, verbatim intent):** Windows Ghoztty at full
parity with Mac Ghoztty, *very reliable and usable for long contexts*.
Thoroughly test it, optimize, fine-tune, make the Windows things look
Windows-native. Not slow, not crashing — well tuned and well tested.
The user is stepping away: do NOT stop to ask clarifying questions; audit
your own trail; use adversarial investigation for hard problems and
recommended approaches where they exist.

## Current priorities (user directive 2026-07-15, overrides table order)

Work these first, in order, before falling back to first-todo-in-table:

1. ~~T50~~ — DONE 2026-07-15 (real "Rename Window" dialog).
2. ~~T54~~ — DONE 2026-07-15 (this doc restructure; resume read is now
   small).
3. **~~T20~~ → ~~T21b~~ → ~~T21a~~ → ~~T22~~** — remote windows on Windows: T20
   (direct TCP) DONE 2026-07-15; T21 split 2026-07-15 (sizing rule);
   T21b (relay dial in the GUI) DONE 2026-07-15; T21a (browser sign-in +
   DPAPI creds + `+relay-login`/`+relay-logout` + GUI account tier) DONE
   2026-07-15, validated by `ipc-relay-login.ps1` ALL PASS (fake-issuer
   login E2E + logout + error path + account-tier window open with no
   `--token`). T22 split 2026-07-15 (too big for one context): T22a (chooser
   design) → T22b (Zig device-directory client) → T22c (win32 chooser dialog
   + ctrl+shift+n + palette entry). T22a DONE 2026-07-15 (design in details
   doc); T22b DONE 2026-07-15 (Zig device-directory client, 7ec2c7119, both
   test lanes green); **T22c DONE 2026-07-15** (4e7edfc9b: ctrl+shift+n +
   "New Remote Window" palette entry open a native machine chooser that
   lists relay devices and opens one via the shared `App.openRelayWindow`;
   `ipc-machine-chooser.ps1` ALL PASS on-box — real chord → chooser opens →
   `GET /v1/client/devices` → Escape-close, no crash). The T22 remote-window
   series is complete; remaining Phase-G follow-ups are T56 (reconnect) and
   T42 (remote env/PATH). Next in this priority list: T58.
4. **~~T48a~~ → ~~T48~~** — deadlock. **T48 (fix) DONE 2026-07-15**
   (e35ef81fd): `App.deferSetFocus` posts WM_APP_SETFOCUS; the run loop does
   the real SetFocus at the top of the loop so the IME/CTF cascade never runs
   nested inside a mouse/focus WndProc. 23 terminal-surface focus sites
   deferred; EDIT/dialog focus stays synchronous. `focus-defer.ps1` ALL PASS
   (9). T48a (root-cause) DONE 2026-07-15:
   analyzed the existing 744MB dump with cdb + MS public symbols (no
   ghoztty pdb needed). NOT a lock cycle — the GUI thread calls `SetFocus`
   inside its WindowProc, the IME/CTF cascade re-enters the WindowProc via a
   synchronous SendMessage, and ghoztty `Condition.wait()`s forever on that
   non-pumping stack. Refutes all three old candidates. Full analysis:
   `t48-deadlock-dump-analysis.md`. **T48 (implement fix) is next**: defer
   SetFocus out of WindowProc so the IME/CTF cascade runs where the thread
   can pump.
5. **~~T58~~ → ~~T59a~~ → ~~T59b~~** — hero mode TRUE port (user, 2026-07-16,
   mid-session correction: T19's win32 port is a static live-pane
   stand-in; the Mac hero = maximized pane + animated snapshot-thumbnail
   carousel). T58 (design) DONE 2026-07-16. T59a DONE 2026-07-16:
   snapshot pipeline (offscreen-target capture — hidden panes capture
   cleanly, spike risk gone) + hidden/hero-sized pane layout +
   owner-painted static carousel + click-select. **T59b DONE 2026-07-16**:
   wheel scroll (parent + surface-fallback routing), divider drag +
   per-tab ratio + double-click reset, hover chrome, snapshot-slide +
   re-center animations (16ms timer, reduced-motion honored), perf pass
   clean (thumbnail heartbeat ≈7fps/renderer, no stalls); hero-mode.ps1
   ALL PASS (58 assertions, incl. a mid-slide oracle); both test lanes +
   P1–P3 green. The hero-mode TRUE port is COMPLETE. Next: T53.
6. ~~T53~~ — COMPLETE 2026-07-17. T53a DONE (soak harness; found+fixed
   the WM_APP_WAKEUP queue flood). T62/T63 DONE (pty read batching;
   +close join race). **T53b DONE 2026-07-17**: the detached 180-min
   soak finished ALL PASS (11) — zero leak growth (private +0.5MB,
   handles/GDI/USER +0 q1→q4), responsive at all 720 samples, 180/180
   echo probes median 248ms, median fps 59; only WARN was the known
   T62 stall (binary predated the fix). Interactive profiling
   (`profile-latency.ps1`, ALL PASS 14): keyboard latency 65→81ms at
   0→150k scrollback lines, GUI-thread RTT 0ms through seek bursts
   idle AND mid-storm, T62/T63 bounds re-verified on ReleaseFast. No
   tuning fixes needed; the harness's one product finding became T64
   (unicode injection, fixed same session). HEAD release delivered to
   all 3 install locations. Next in this list: T52.
7. ~~T52~~ — DONE 2026-07-18: `ghoztty +version` now answers "which build
   is this window running?" from any pane (new IPC `version` verb →
   "Running Instance" section with version/commit/mode/exe/modified/pid);
   `+list --json` carries the same as `data.build` (additive — Mac golden
   shape untouched); command palette gained "About Ghoztty". Validated by
   `test/win32/ipc-version.ps1` ALL PASS (22) three runs in a row; P1–P3
   + both test lanes green. Next: T51.
8. ~~T51~~ — DONE 2026-07-18: full parity re-audit (4 parallel sweeps —
   action matrix, IPC/GUI features, config coverage, native
   look-and-feel — plus on-box verification: P1–P3, hero-mode (60),
   ipc-version, both test lanes ALL green at HEAD). 16 findings filed as
   **T65–T80**. Suggested order for working them (user-visible bugs →
   "windowsy" theming → config parity → features): ~~T65~~ (done
   2026-07-18), ~~T77~~ (done 2026-07-18), ~~T79~~ (done 2026-07-18),
   ~~T80~~ (done 2026-07-18), ~~T74~~ (done 2026-07-18), ~~T73~~ (done
   2026-07-18), ~~T76~~ (done 2026-07-18), ~~T75~~ (done 2026-07-18), ~~T69~~ (done
   2026-07-18), ~~T68~~ (done 2026-07-18; filed T81 — pre-existing
   relay-agent-death GUI hang found by its regression runs), ~~T81~~ (done
   2026-07-18: was a process-killing PANIC in the ws teardown + a remote
   transport leak on `+close`; filed T82 — pre-existing test-agent
   failures on Windows), ~~T67~~ (done 2026-07-18), ~~T70~~ (done
   2026-07-18: PATH self-heal + MSI Environment entry), ~~T71~~ (done
   2026-07-18: first-run offer + palette entry for the Claude Code
   plugin install), ~~T66~~ (done 2026-07-18: reset to stored
   initial_size; re-sends store-only), ~~T72~~ (done 2026-07-18:
   Tab Color submenu + accent stripe), ~~T78~~ (done 2026-07-18:
   tab-bar title font). **The priority queue is exhausted** — fall back
   to first-todo-in-table / the order above.
9. ~~T84~~ (done 2026-07-19: root cause was the inherited ignore-^C
   flag, not ConPTY — fixed by clearing it at App.init; keybinds-t01.ps1
   ALL PASS 23/23).
10. ~~T85~~ — DONE 2026-07-19 (new-window size memory; placement
   persisted on interactive resize/maximize, config > memory > default).
11. ~~T25~~ — DONE 2026-07-19 (spec §8 conformance gate: `conformance.ps1`
   items 1–7 ALL PASS ×3 + hero/relay/skill evidence; spec §9 filled).
   Filed T86 (harness foreground hardening) + T87 (Mac seat: regression
   build + merge to main).
12. ~~T35~~ — DONE 2026-07-19 (sticky pane banner: IPC + OSC 7778 + strip
   overlay + ctrl+shift+b editor; `pane-banner.ps1` ALL PASS (30) ×3).
13. ~~T88~~ — DONE 2026-07-19 (merged main 8bb5d9845; gaps filed as
   T89a–T94). ~~T91~~ (done 2026-07-19: banner markdown parity — block
   parser + overlay renderer, pane-banner.ps1 37 asserts ×3). ~~T92~~
   (done 2026-07-19: three-level title model — window pin → tab pin →
   pane title; `window-title.ps1` ALL PASS (46) ×3; kb-actions.ps1's
   un-hardened chord grab skipped its whole run during regression —
   T86's case grew stronger). ~~T94~~ (done 2026-07-19: ~9 DIP grab band
   via NCHITTEST fall-through; split-divider.ps1 (15) ×3 — its foreground
   grab is now T86-hardened, one script down). ~~T86~~ (done 2026-07-19:
   GrabForeground in all 20 remaining scripts + already-fg guard
   everywhere; 19/20 validated vs live foreign fg; filed T95 for the
   keybinds-t01 tail, blocked on the box's GameInputSvc wedge). ~~T93~~
   (done 2026-07-19: brokered OAuth port — see row; box still wedged at
   session start, T95 skipped; a detached watcher later saw the wedge
   clear once ~21:34, it flaps — re-probe before T95).
14. ~~T89a~~ — DONE 2026-07-19 (session-persistence Windows design +
   T89 split into T89b–T89i; T95 re-probed at session start: still
   wedged — SendInput swallowed, session unelevated, stays blocked).
   **Next on-box, in order: ~~T90a~~ → T89b → T89c…T89i** (then the
   T90b–T90h implement series; T29/T30/T87 are Mac-seat; T28's
   remainder and T82 fold into T89b). Flag for the Mac seat: main's
   `Hello.encode`/build_version elision test was red on main itself —
   fixed on this branch (362d1d4bc), needs to flow back via T87.
15. ~~T90a~~ — DONE 2026-07-19 (viewer-panes Windows design: loader-less
   WebView2 + PaneView retype + Mac-parity contracts; T90 split into
   T90b–T90h, T90b–T90g independent of the T89 series, T90h needs
   T89f). Next on-box: **T89b**.

Done recently: T40 (lost renderer wakeups) fixed and DELIVERED to all
install locations 2026-07-15; T49 hero-mode report root-caused to a stale
July-5 exe (no code regression; pixel-verified on HEAD).

## State table

One line per row. Full spec + validation + evidence per task:
`windows-parity-details.md` (`## T<id>` sections).

| ID | Task | Phase | Deps | Status | Commits |
|----|------|-------|------|--------|---------|
| T01 | Verify keybinds on box — done 2026-07-18 via new `keybinds-t01.ps1` (chord injection + mouse word-select; positive controls). All checklist chords verified on HEAD Debug; 2 real bugs found → T83 (goto_tab off-by-one, fixed) + T84 (inherited ignore-^C flag, fixed 2026-07-19). Script ALL PASS (23) since the T84 fix | A | — | done | — |
| T02 | Keybind gaps: ctrl+p, ctrl+f4 | A | — | done | 82e096f4b |
| T03 | Named-pipe client helper + CLI un-guard | B | — | done | 353d70abf.. |
| T04 | Pipe server in win32 App + marshal + DACL | B | T03 | done | 1a44125de |
| T05 | `+list` | B | T04 | done | da9d56d0d |
| T06 | `+new-window` full flags + auto-launch | B | T04 | done | e80e32d39 |
| T07 | `+close` | B | T06 | done | e80e32d39 |
| T08 | P1 acceptance script `ipc-p1.ps1` | B | T05,T06,T07 | done | e80e32d39 |
| T09 | `+split` | C | T08 | done | 72943724a |
| T10 | `+rename` / titleOverride precedence | C | T08 | done | see details |
| T11 | `+send-keys` full notation | C | T08 | done | see details |
| T12 | P2 acceptance script `ipc-p2.ps1` | C | T09,T10,T11 | done | see details |
| T13 | `+read` | D | T08 | done | 1aac69e91 |
| T14 | `+set-state` + OSC 7777 + title suffix | D | T08 | done | fee87d441 |
| T15 | `+rearrange` | D | T09 | done | see details |
| T16 | P3 acceptance script `ipc-p3.ps1` | D | T13,T14,T15 | done | see details |
| T17 | Skill conformance on the box | E | T12,T16 | done | doc only |
| T18 | `swap_split` on win32 | F | — | done | see details |
| T19a | Hero mode design (win32) | F | T18 | done | see details |
| T19 | Hero mode on win32 (implement) (CORRECTION 2026-07-16: shipped a static geometric stand-in, NOT the Mac design — see T58/T59) | F | T19a | done | f37bd1e3c |
| T20 | `+new-remote-window` direct TCP | G | T08 | done | 2ed989866 |
| T21a | Browser sign-in + DPAPI creds + `+relay-login` CLI | G | T21b | done | 64c4329c2 |
| T21b | Relay dial path in win32 GUI (`--relay`/`--device`) | G | T20 | done | 89e31b7fb |
| T22a | Machine chooser design (win32) | G | T21a | done | 6d944531e |
| T22b | Zig relay device-directory client (`/v1/client/devices`) | G | T22a | done | 7ec2c7119 |
| T22c | win32 machine chooser dialog + ctrl+shift+n + palette entry | G | T22b | done | 4e7edfc9b |
| T23 | MSI upgrade/uninstall fix — done 2026-07-19: root cause was wixl's EMPTY File.Version (packaged exe "unversioned" → costing skip + RExP delete = the 26.7.502 vanishing exe), NOT RExP placement. Fix: per-build FILEVERSION (`-Dwindows-file-version`) stamped into the exe + mirrored into the File table, MsiFileHash emptied, `wixl -a x64`, `--test-identity` throwaway E2E; `msi-upgrade.ps1` ALL PASS (33) ×3 incl. ghost-recovery; see details for the on-box 26.7.502 ghost note | H | — | done | 5edea9532 |
| T24 | Windows release channel + update check — done 2026-07-19: win-vX.Y.Z GitHub releases (--latest=false, MSI asset; win-v1.4.1 published live), notify-only in-app check gated to -Dwindows-update-check channel builds, `publish-windows-release.ps1`, provenance `update_check` field; `update-check.ps1` ALL PASS (12) ×3, P1–P3 + ipc-version + both lanes green | H | T23 | done | 3b0c3bbde.. |
| T25 | Full conformance checklist (spec §8) — done 2026-07-19: new `conformance.ps1` (items 1–7 E2E from cold, CLAUDE.md three-pane w/ documented Windows equivalents) ALL PASS ×3; item 8 hero-mode.ps1 (60) after harness foreground fix, item 9 fake-relay E2E, item 10 per T17; spec §9 filled; Mac regression + merge → T87; harness gap → T86 | — | T17,T19,T21a | done | (this commit) |
| T26 | OS color-scheme sync | I | — | done | see details |
| T27 | PowerShell shell integration | I | — | done | see details |
| T28 | Minor action no-ops cleanup | I | — | in-progress | see details |
| T29 | Mac-side: action fallthroughs to showChildExited | I | — | todo | — |
| T30 | Mac-side: IPC dial must not modal-block | I | — | todo | — |
| T31 | `+list --pid` + real pid leaf data | I | T05 | done | see details |
| T32 | Split IpcServer.zig; pure logic + unit tests | J | — | done | 640457b0d.. |
| T33 | Native win32 test lane | J | T32 | done | see details |
| T34 | Windows shell types, first-class | J | — | done | see details |
| T35 | Sticky pane banner on win32 — done 2026-07-19: `+set-banner` verb + OSC 7778 + layered-popup strip (markdown subset via pure banner_markdown.zig, clickable links, per-pane) + ctrl+shift+b editor dialog + palette entry + `+list` additive `banner`; `pane-banner.ps1` ALL PASS (30) ×3 | I | — | done | (this commit) |
| T36 | Release install refresh flow | H | — | in-progress | ae71b19b4.. |
| T37 | CLAUDE.md symmetry mandate + dual-arch instructions | — | — | todo | — |
| T38 | Windows build in the release process | H | T23,T24 | todo | — |
| T39 | Website: Windows installer download link | H | T38 | todo | — |
| T40 | FIX PERF: lost renderer wakeups (slow scrolling) | I | — | done | see details |
| T41 | Skip close-confirm when shell is idle | I | — | todo | — |
| T42 | Remote sessions: user env/PATH missing | G | — | todo | — |
| T43 | Proper visual debug banner on win32 | I | — | todo (lower priority) | — |
| T44 | FIX CRASH: rename overlay, single-tab window | I | — | done | 7510d2cd2.. |
| T45 | `--when-idle` acceptance test `ipc-when-idle.ps1` | I | T11 | done | see details |
| T46 | `--when-idle` busy-marker drift fix | I | T45 | done | see details |
| T47 | ctrl+k → clear_screen keybind | I | — | done | see details |
| T48a | Root-cause the release GUI deadlock (dump analysis) | I | — | done | see details |
| T48 | FIX DEADLOCK: defer SetFocus out of WindowProc (re-entrant IME/CTF hang) | I | T48a | done | e35ef81fd |
| T49 | Hero-mode regression report → stale binary (CORRECTION 2026-07-16: the user's actual repro was the command palette, not the keybind — see T57) | F | T19 | done | c795455ff.. |
| T50 | Real "Rename Window" dialog | I | T44 | done | 39988009a |
| T51 | Full parity RE-AUDIT — done 2026-07-18: 4-sweep audit (actions, IPC/GUI features, config, native look-and-feel) + on-box verification; 16 findings filed as T65–T80; audit appendix updated (2 prior-audit corrections) | — | T50,T22c,T48,T53 | done | 1eb21bdf2 |
| T52 | Build provenance visible in-app: IPC `version` verb, `+version` "Running Instance" section, `+list --json` data.build, palette "About Ghoztty" box (shared win32 provenance.zig); `ipc-version.ps1` ALL PASS 3x | I | — | done | cd3c47068 |
| T53a | Soak harness `test/win32/soak.ps1` + first bounded on-box soak + findings filed. FOUND+FIXED: WM_APP_WAKEUP message-queue flood broke ALL IPC under load (see details); regression guard `test/win32/ipc-under-load.ps1` | I | T40 | done | 517967173 |
| T53b | Multi-hour detached soak (180 min ALL PASS, zero leaks) + keyboard-latency/scrollback-seek profiling (`profile-latency.ps1` ALL PASS; no degradation at 150k lines) + release delivered to all install locations. No tuning fixes needed; found T64. See details | I | T53a | done | 3cb802605.. |
| T62 | FIX: +read stalls many seconds (16s observed) while a pane floods tiny writes — renderer-mutex starvation on the GUI/IPC path (T48 static candidate 2, now reproduced). Fixed: read-thread batching (64KB + pipe top-up), one lock cycle per batch; 80–127ms post-fix. See details | I | T53a | done | 5562c65ab |
| T63 | FIX: +close of a noisy window hung the GUI thread forever — Exec.threadExit's one-shot CancelIoEx missed while the reader parsed, join() never returned (found by the T62 validation run, 9+ min hang observed). Fixed with T62: quit-byte check before every blocking read + retrying cancel; +close now asserted <10s in ipc-under-load.ps1 (277ms). See details | I | T62 | done | 5562c65ab |
| T54 | Resume-doc diet (this restructure) | — | — | done | 6968d82e7 |
| T55 | FIX: hero-mode.ps1 fails on HEAD (chords not dispatched) — root cause was the TEST's positive control: ctrl+shift+r now opens the T50 modal rename dialog, which disables the owner window and silently ate every later chord. Control switched to ctrl+k (clear_screen, no UI left behind); not a key-path regression | F | T19 | done | (this commit) |
| T60 | FIX: window title jitters a few px left/right on a timer while busy (user, 2026-07-16; row renumbered from a duplicate T56 on 2026-07-16). Likely cause: Claude Code's title spinner — the braille glyphs (⠐/⠂/…) come from a FALLBACK font (MS Gothic per app log) with per-glyph advance widths, so the centered title re-centers to a different width every spinner frame. Investigate where the win32 tab/title text is drawn (Window.zig caption/tab paint); candidate fixes: left-align the title, reserve a fixed-width cell for the leading glyph, or measure/center on the title minus the spinner char | I | — | todo | — |
| T57 | FIX: "Toggle Hero Mode" (and other fork actions) missing from the win32 command palette — the REAL cause of the T49 user report ("no hero mode in command palette", 2026-07-16): the palette is a hardcoded static list (Surface.zig palette_entries), never updated with fork actions, so hero mode was undiscoverable even though the keybind worked. Added: Toggle Hero Mode, Swap Split Right/Down/Left/Up, Rename Window (prompt_surface_title). Skipped prompt_surface_banner (win32 no-op until T35). hero-mode.ps1 grew a palette section: ctrl+shift+p → type "hero" → Enter → hero geometry asserted. Consider (T51 audit): generate palette entries from core command.zig defaults instead of a parallel list, so this class of drift can't recur | F | T19 | done | (this commit) |
| T56 | Remote reconnect on win32 (WP-D1 parity) | G | T21b | todo | — |
| T58 | Hero mode TRUE port — design (win32): Mac hero = animated hero strip + snapshot thumbnail carousel + drag divider; T19 shipped a static live-pane stand-in (user, 2026-07-16). Decided: renderer-side FBO-downscaled snapshots (pre-swap hook in generic.zig; HWND capture rejected — child GL windows have no DWM surface), non-hero panes SW_HIDE + renderer kept awake + all hero-sized (no reflow on swap), owner-painted carousel in new HeroCarousel.zig, snapshot-slide animation, per-tab ratio + divider drag. T59 split → T59a/T59b | F | T19 | done | (this commit) |
| T59a | Hero mode TRUE port — snapshot pipeline + static carousel. Spike outcome: capture reads the OFFSCREEN render target (OpenGL.captureThumb), so hidden panes capture cleanly — no fallback needed. Renderer hook in generic.zig; Surface snap buffer/DIB + WM_APP_HERO_SNAP; SW_HIDE + renderer-awake layout, all leaves hero-sized; owner-painted HeroCarousel.zig + hero_math.zig (unit tests in both lanes); click-select; per-tab ratio field; hero-mode.ps1 rewritten (DPI-aware harness) | F | T58 | done | a859c9976 |
| T59b | Hero mode TRUE port — interactions/motion: wheel scroll, divider drag + per-tab ratio, hover chrome, slide + re-center animations, reduced-motion, GHOZTTY_PERF check, screenshot | F | T59a | done | 5a10762ed |
| T61 | FIX: swap_split (ctrl+shift+arrows) in hero mode silently swapped panes in the hidden tree (user, 2026-07-16: nav from index 1 "went to 2", and exit restored a mutated layout). Hero now intercepts swap_split: up/down = prev/next selection (Windows mirror of the Mac hero-nav chord), left/right no-op | F | T59b | done | 26f375c76 |
| T64 | FIX: SendInput-unicode (VK_PACKET) text injection silently dropped — screen readers/on-screen keyboards/automation typed nothing into panes (found by the T53b profiling harness; both input modes affected). See details | I | — | done | 3cb802605 |
| T65 | FIX: show_child_exited suppressed the core fallback — done 2026-07-18: returns false (modal removed), core in-terminal UI shows; + 3 adjacent fixes found by validation (ConPTY late-frame notify delay in Exec.zig, GWLP_USERDATA wrong-type-cast keystroke crash in App.zig run loop, win32-input-mode close-on-keypress). `ipc-child-exited.ps1` ALL PASS x3 (T51 F1) | I | — | done | 0eebf126c |
| T66 | reset_window_size — done 2026-07-18: resets to the stored initial_size (window-width/height × cell size; 800×600 only when unset), initial_size re-sends store-only (Mac/GTK parity: font zoom no longer live-resizes), palette "Reset Window Size"; `reset-window-size.ps1` ALL PASS (10) ×3 (T51 F2) | I | — | done | b11961d5c |
| T67 | Window/pane background tint — done 2026-07-18: `--color`/`--split-color`/`random` end-to-end (bg + contrast fg + WCAG-4.5 palette), plain splits inherit shifted parent bg, "Background Color…" ChooseColorW menu entry, `+list` additive `background_tint`; `window-color.ps1` ALL PASS (14) ×3 (T51 F3) | I | — | done | 5bf9a65d6 |
| T68 | Remote inheritance — done 2026-07-18: `--from-focused` on +new-window/+split; plain tabs/splits in a remote window reuse the connection + inherit command/live cwd (GET_CWD); ctrl+n re-dials the recorded machine; `remote-inherit.ps1` ALL PASS ×3 (T51 F4) | G | T21b | done | c8f1da16e |
| T69 | Config-error UI — done 2026-07-18: startup + hard-reload diagnostics shown in a dark ConfirmDialog with "Open Config"/"Ignore" (custom captions + measured button width); `config-errors.ps1` ALL PASS (10) ×3 (T51 F5) | I | — | done | 9cef52567 |
| T70 | CLI on PATH — done 2026-07-18: PathInstaller.zig self-heal at GUI launch (gated to %LOCALAPPDATA%\Programs\Ghoztty, any-spelling detection, WM_SETTINGCHANGE) + MSI user-PATH Environment entry (wixl drops Permanent=no; build-msi.sh patches `=-PATH` post-compile). `path-selfheal.ps1` ALL PASS (13) ×3; MSI add/remove E2E via throwaway MSI (T51 F6) | H | — | done | c581370f4 |
| T71 | Claude Code integration — done 2026-07-18: first-run offer (canonical-install-gated, answer persisted, declining remembered) + "Install Claude Code Integration" palette entry run `claude plugin marketplace add`/`install` on a background thread with Mac-parity outcome dialogs (ClaudeIntegration.zig + pure claude_setup.zig); `claude-integration.ps1` ALL PASS (26) ×3 (T51 F7) | I | — | done | b3f2b02be |
| T72 | Tab accent-color tagging — done 2026-07-18: "Tab Color" context-menu submenu (10 Mac colors, DIB swatches, checkmark) + top accent stripe in the owner-drawn tab paint; color rides tab reorders (also fixed moveTab's missing hero-state swaps); `tab-color.ps1` ALL PASS (11) ×3 (T51 F8) | I | — | done | b50759cd4 |
| T73 | `split-divider-color` — done 2026-07-18: paintDividers reads the config color (gray 0x808080 fallback), onConfigChange repaints so reload re-colors live; `split-divider.ps1` ALL PASS (9) ×3 (T51 F9) | I | — | done | ef4b6de11 |
| T74 | `unfocused-split-opacity`/`-fill` — done 2026-07-18: per-pane layered click-through dim popups (DimOverlay.zig + dim_math.zig, Mac-parity alpha), driven from layout/focus/move/config-reload; `split-dim.ps1` ALL PASS (23) ×3 (T51 F10) | I | — | done | 630f5fef0 |
| T75 | `focus-follows-mouse` — done 2026-07-18: hover focuses the split under the pointer via deferred SetFocus, gated on real screen-coord motion + active-window; `focus-follows-mouse.ps1` ALL PASS (10) ×3 (T51 F11) | I | — | done | 72a15194e |
| T76 | `window-inherit-font-size` — done 2026-07-18: focused surface's live font size captured pre-init, applied post-init via setFontSize (embedded.zig parity; reset_font_size keeps config default); `font-inherit.ps1` ALL PASS (21) ×3 (T51 F12) | I | — | done | 4e97799c2 |
| T77 | FIX: gotoSplit while split-zoomed moves keyboard focus to a hidden pane — honor `split-preserve-zoom.navigation` (clear or follow zoom on navigation); `split-zoom-nav.ps1` ALL PASS (16) both config values (T51 F13) | I | — | done | 1e02507c1 |
| T78 | `window-title-font-family` — done 2026-07-18: drives the owner-drawn tab bar font + resize overlay (DWM caption font is not app-controllable; Windows-native scope), live config reload; pure title_font.zig (unit tests both lanes); `title-font.ps1` ALL PASS (9) ×3 (T51 F14) | I | — | done | 6a117e1ae |
| T79 | Dark-mode context menus — done 2026-07-18: DarkMode.zig routes `window-theme` through uxtheme ordinals #135/#136 at init/config-reload/WM_SETTINGCHANGE; `dark-menus.ps1` ALL PASS (6) (T51 F15) | I | — | done | 3c0960d0d |
| T80 | Dark-mode message boxes — done 2026-07-18: shared ConfirmDialog.zig (T50-pattern dark dialog, synchronous nested-pump API) replaces all 4 remaining MessageBoxW sites; `confirm-dialogs.ps1` ALL PASS (20) ×3 (T51 F16) | I | — | done | f3626ba2f |
| T81 | FIX: "GUI unresponsive" after agent death under a live relay window — done 2026-07-18: was a PANIC, not a hang (ws close-frame send after `shutdown(.both)` → `WSAESHUTDOWN` → std `unreachable` killed the process) + `onDestroy` leaked the remote transport on every `+close`. New `socket_rw.zig` panic-free socket Reader/Writer; `ipc-relay.ps1` ALL PASS ×3. See details | G | — | done | aeb856ebe |
| T82 | FIX: `zig build test-agent` has never been green on Windows — 5 pre-existing agent-core integration failures (keepalive ×2, self_update ×3; harness uses `std.net.Stream.read` = `ReadFile`-on-overlapped-socket → GetLastError(87)) + a leaked-thread crash mis-attributed to socket_stream + a pty_child segfault. Found (and proven pre-existing at 52e1fd73b baseline) during T81. Not in the parity validation lanes; folds into T89b (session-persistence test floor) | G | — | skipped(folded into T89b) | — |
| T83 | FIX: goto_tab off-by-one on win32 — ctrl+1 selected tab 2, ctrl+2 no-op with 2 tabs; `Window.selectTab` treated the 1-indexed GotoTab payload as 0-based. Now `@min(raw-1, count-1)` w/ raw<1 rejected (Mac/GTK parity incl. out-of-range→last). Found+fixed by T01; validated by `keybinds-t01.ps1` | A | T01 | done | a18611ab5 |
| T85 | FIX: new windows don't remember size — done 2026-07-19: outer size + maximized flag persisted on user-interactive changes only (WM_EXITSIZEMOVE + max/restore transitions) to `%LOCALAPPDATA%\ghoztty\window_placement` (`-debug` for Debug builds); creation uses config > memory (work-area-clamped) > 800×600; `maximize` config now honored; reset stays the escape hatch; `window-size-memory.ps1` ALL PASS (20) ×3, `reset-window-size.ps1` (focus-free rewrite) ALL PASS (10), P1–P3 + both lanes green | I | — | done | 67b0f24a5 |
| T86 | Harden foreground grab in kb-injection scripts — done 2026-07-19: shared `GrabForeground` (already-fg guard + attach-to-fg-thread + Alt tap, retried w/ backoff) ported to all 20 remaining scripts incl. PS-side grab sites; guard added to hero-mode/window-title/split-divider too (an unguarded Alt tap self-latches menu mode when already foreground — broke chooser-Escape/About-box/copy until guarded). Validated vs a live foreign-fg window: 19/20 ALL PASS (chooser + ipc-version ×3); keybinds-t01 fix blocked by box wedge → T95 | — | — | done | (this commit) |
| T87 | Mac seat: macOS regression build green + merge to main (T25 tail, per working agreements); natural moment for a live relay dial + T29/T30 | — | T25 | todo | — |
| T88 | Merge latest origin/main — done 2026-07-19: merged 8bb5d9845 (154 commits: session persistence, viewer panes, banner markdown, brokered OAuth, window titles) as 74322cf05; 3 post-merge Windows fixes (362d1d4bc: .powershell in the new shell-integration switch, u128-atomic → mutex in connection.zig test agent, Hello.encode null-elision — that test was red on main itself, flag to Mac seat); both lanes + Debug GUI + P1–P3 green; parity gaps filed as T89a–T94 | — | — | done | 74322cf05.. |
| T89a | Session persistence on Windows: DESIGN — done 2026-07-19: 3-way survey (Mac design + agent core + win32 app); decided: named-pipe listener (`--listen-pipe`, IpcServer DACL pattern, pipe-backed Stream, additive port.json `pipe`), separate local-agent instance under `%LOCALAPPDATA%\ghoztty\local-agent[-debug]`, Zig LocalAgent find-or-spawn w/ 2s bound + exec fallback, close-sends-CLOSE vs quit-keeps-sessions (new quit action + WM_ENDSESSION), viewer-side layout manifest + ATTACH re-attach, HKCU Run key autostart, T82 as the T89b floor; split T89 → T89b–T89i. Full design in details §T89a | K | T88 | done | (this commit) |
| T89 | Session persistence on Windows: IMPLEMENT — umbrella; split by T89a into T89b–T89i (agent-owned ConPTYs survive app quit/crash/upgrade w/ same-PID re-attach, reboot relaunch, +sessions; lazy agent upgrade stays deferred as on Mac) | K | T89a | skipped(split → T89b–T89i) | — |
| T89b | Agent test floor: `zig build test-agent` green on Windows — harness socket reads → socket_rw (keepalive ×2, self_update ×3), leaked-thread crash, pty_child segfault (folds in T82) | K | T89a | todo | — |
| T89c | Agent `--listen-pipe` mode (byte-mode pipe, owner DACL, pipe Stream impl, port.json `pipe`, local-agent storage dir, graceful-stop snapshot hook) + `+sessions` Windows dial (`dialPipe`); `agent-pipe.ps1` | K | T89b | todo | — |
| T89d | Win32 surfaces OPEN under local agent: LocalAgent.zig find-or-spawn (2s bound, 15s cooldown, exec fallback), consume session-persistence, remote_conn injection (pinned, env, T84 ^C flag); `session-open.ps1` | K | T89c | todo | — |
| T89e | Close-vs-quit semantics: user close ⇒ CLOSE, quit paths keep sessions ("Quit Ghoztty (keep sessions)" + WM_ENDSESSION), confirm carve-out per Mac 853ec3168; `session-close.ps1` | K | T89d | todo | — |
| T89f | Layout manifest + same-PID re-attach restore (session-layout json, debounced sync, launch restore w/ positive-dead probe, ATTACH by session id, gap-fill); `session-reattach.ps1` | K | T89e | todo | — |
| T89g | Tombstone relaunch floor on win32: agent-restart/reboot, session-relaunch auto|prompt E2E, ring-snapshot scrollback + divider; `session-relaunch.ps1` | K | T89f | todo | — |
| T89h | Autostart (HKCU Run key) + upgrade-script agent guard + agent in release zip/MSI + delivery to all 3 install locations + docs un-gate | K | T89g | todo | — |
| T89i | E2E hardening: PS port of session-persistence.py (incl. --winsize), crash-kill re-attach, persistence-on soak + flood-during-reattach; `session-persistence.ps1` | K | T89h | todo | — |
| T90a | Viewer panes on Windows: DESIGN — done 2026-07-19: 3-way survey (Mac viewer impl + win32 structure + WebView2 research); pinned: loader-less WebView2 (registry probe + internal create export, error-card degrade), PaneView retype `{terminal,viewer}`, WebResourceRequested 3-tier resolver, Mac-parity IPC strings + additive list `type`/`url`, interim explicit `--view` error, FFM/T94-band/hero exclusions, T89f manifest reserves `kind`/`viewer_location`; split T90 → T90b–T90h. Design in details §T90a | K | T88 | done | (this commit) |
| T90 | Viewer panes on Windows: IMPLEMENT — umbrella; split by T90a into T90b–T90h | K | T90a | skipped(split → T90b–T90h) | — |
| T90b | Viewer IPC/CLI floor: VerbArgs.view + mutual-exclusion, interim "viewers are not yet supported on Windows" error, additive list.zig `pane_type`/`url`, resolveViewArgument isAbsolute fix; seed `viewer-panes.ps1` | K | T90a | todo | — |
| T90c | PaneView retype (pure refactor): SplitTree(Surface)→SplitTree(PaneView) across Window/IpcHandlers/IpcRegistry/HeroCarousel + overlay walks; regression-validated only | K | T90b | todo | — |
| T90d | WebView2 host floor: webview2.zig COM decls + loader-less probe, shared env/UDF, ViewerPane HWND/controller lifecycle, native error card, web-mode `--view` E2E, verb rejections | K | T90c | todo | — |
| T90e | File viewers: mode-by-extension, WebResourceRequested 3-tier resolver, __viewer injection, +list viewer fields populated, PreferredColorScheme dark sync, error card | K | T90d | todo | — |
| T90f | Viewer live reload (ReadDirectoryChangesW + debounce) + link routing (browser / .md→viewer split / default app) | K | T90e | todo | — |
| T90g | Viewer chrome & commands: T92 titles, hero exclusion, accelerator forwarding, dim walk, split-from-viewer cwd, palette Open File/URL in Pane | K | T90f | todo | — |
| T90h | Viewer session-persistence restore (T89f manifest fields) + full viewer-panes.ps1 hardening ×3 | K | T90g,T89f | todo | — |
| T91 | Banner markdown parity — done 2026-07-19: block parser rewrite (parseBlocks: headings, `---` rules, marker-gutter lists, GFM+headerless tables w/ `:` alignment + `\|`, native checkboxes, 10-line cap) + overlay measure/draw walker (bold-measured capped column widths, cell word-wrap, green RoundRect checkboxes, chevron collapse w/ fade, 12dip padding); `pane-banner.ps1` grown to 37 asserts ALL PASS ×3, P1–P3 + both lanes green | I | T88 | done | (this commit) |
| T92 | Window-level titles — done 2026-07-19: three-level model (window pin → tab pin → pane title); `.prompt_title` branches on payload into a 3-level RenameDialog (Mac captions), Surface user-title w/ terminal-title restore, per-tab pin, `+rename --title=""`/empty-commit clears, 3 palette entries; `window-title.ps1` ALL PASS (46) ×3 | I | T88 | done | (this commit) |
| T93 | Brokered OAuth for Windows relay sign-in — done 2026-07-19: new relay_session.zig (/oauth/exchange|renew|signout), account store = session token + expiry + relay_base (DPAPI), renew rotates + persists, no client secret anywhere, -Dgoogle-client-id via build_config, logout revokes, legacy store ⇒ one re-login; `ipc-relay-login.ps1` rewritten (31) ALL PASS ×3, P1–P3 + both lanes + GUI build green | G | T88 | done | (this commit) |
| T94 | Split divider grab-handle hit target — done 2026-07-19: band widened ±3→±4.5 DIP (~9 DIP, Mac `001834466` parity) + WM_NCHITTEST/HTTRANSPARENT fall-through on surface children (the ~5 DIP visual gap no longer clips the band); SIZENS/SIZEWE feedback across it; `split-divider.ps1` +6 T94 asserts (real-input ±4 DIP drags) + T86-hardened foreground grab, ALL PASS (15) ×3 | I | T88 | done | (this commit) |
| T95 | keybinds-t01 copy-click fix needs its ×3: T85 placement memory made new windows tall, so the copy test's window-CENTER dclick landed below the X block (pre-existing since T85, NOT a grab issue — probe: fresh-window dclick+ctrl+c copies fine). Fixed via upper-row probe loop (0.08–0.28 height, clipboard-verified). Re-run ×3 once the box's GameInputSvc wedge clears (SendInput swallowed + unbeatable fg lock, unelevated fix impossible — elevated `Restart-Service GameInputSvc`). Re-probed 2026-07-19 (T89a session): still swallowed (rel 10/40/120 + abs move all no-op), session unelevated | — | T86 | blocked(GameInputSvc wedge — needs elevated service restart or reboot) | — |
| T84 | FIX: ctrl+c never interrupted ConPTY children — root cause: the GUI process inherited the ignore-^C flag (set by CREATE_NEW_PROCESS_GROUP anywhere up the launcher chain — scripts, CI, `+new-window` auto-launch from automation) and every ConPTY shell inherited it in turn; conhost's 0x03→CTRL_C_EVENT cooking was never broken. Fix: clear the flag at App.init via `SetConsoleCtrlHandler(null, 0)`. Probe scenarios added to conpty_smoke (`--ctrlc`/`--ctrlc-win32`/`--ctrlc-anon`/`--ctrlc-mode`/`--ctrlc-host`/`--ctrlc-self`/`--report-ctrlc`). `keybinds-t01.ps1` ALL PASS (23) incl. the SIGINT assert. See details | I | — | done | 3b085a661 |

Status values: `todo` / `in-progress` / `done` / `blocked(<on what>)` /
`skipped(<reason>)`.

## Key code landmarks

- `src/apprt/win32/` IPC (as of 2026-07-12): IpcServer.zig (pipe
  transport), IpcHandlers.zig (verbs), IpcRegistry.zig (named targets),
  ProcessTree.zig (`--pid` ancestry); pure logic in `src/apprt/ipc/`
  (args.zig, list.zig — unit tested in both lanes). No action stubs remain
  (T19 landed the last one). `startUpdateCheck` still hard-disabled (T24).
- `src/apprt/none.zig` `sendIpc` — Mac client wire protocol (4-byte BE length
  + JSON), reuse `src/apprt/ipc.zig` `parseResponse`.
- `macos/Sources/Features/IPC/IPCServer.swift` — reference server semantics
  (registry, idempotency, send-keys notation, list format, rearrange).
- `macos/Sources/Features/Terminal/BaseTerminalController.swift` — activity
  title suffix + titleOverride precedence.
- `src/remote/` — shared Zig remote core (ws_client, relay_dial, client_mux,
  ssh_transport); termio `.remote` backend. Swift supplies only UI + creds.
- `src/config/Config.zig` ~line 6880 — the Windows ctrl-mirror keybind block.
- Windows keyboard path: `src/apprt/win32/Surface.zig` `handleKeyEvent`.

## Related docs (read only the slice you need)

- `windows-parity-details.md` — per-task spec/validation/evidence sections
  (`## T<id>`), plus "Bootstrap & environment" and the backlog. Read ONLY
  your task's section.
- `windows-parity-log.md` — dated session log, newest first. Open a single
  entry only when you need the backstory for your current task. Append ONE
  short entry at every task boundary.
- `windows-parity-audit.md` — the 2026-07-12 three-way audit findings.
- `windows-parity-spec.md` — architecture decisions (pinned). Read its
  "Architecture decisions" section before implementing any IPC task.
