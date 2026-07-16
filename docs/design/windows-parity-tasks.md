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
5. **~~T58~~ → T59a → T59b** — hero mode TRUE port (user, 2026-07-16,
   mid-session correction: T19's win32 port is a static live-pane
   stand-in; the Mac hero = maximized pane + animated snapshot-thumbnail
   carousel). T58 (design) DONE 2026-07-16: decisions + sized two-part
   plan recorded in the T58 details section — renderer-side snapshots
   (HWND capture rejected), owner-painted carousel, snapshot-slide
   animation. Next: T59a (pipeline + static carousel, spike first),
   then T59b (interactions + motion).
6. **T53** — long-context reliability + perf soak/tuning pass.
7. **T52** — build provenance surfaced in-app (the 2026-07-15 "no parity"
   report was a July-5 exe — make "which build is this" answerable at a
   glance).
8. **T51** — full parity re-audit. Deliberately LAST in the queue per the
   user: after the above land, re-audit Windows vs Mac so nothing is
   missing, and file new tasks from the findings.

Done recently: T40 (lost renderer wakeups) fixed and DELIVERED to all
install locations 2026-07-15; T49 hero-mode report root-caused to a stale
July-5 exe (no code regression; pixel-verified on HEAD).

## State table

One line per row. Full spec + validation + evidence per task:
`windows-parity-details.md` (`## T<id>` sections).

| ID | Task | Phase | Deps | Status | Commits |
|----|------|-------|------|--------|---------|
| T01 | Verify fresh ZIP keybinds on box | A | — | todo | — |
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
| T23 | MSI fix → uninstall entry works | H | — | todo | — |
| T24 | Windows release channel + update check | H | T23 | todo | — |
| T25 | Full conformance checklist (spec §8) | — | T17,T19,T21a | todo | — |
| T26 | OS color-scheme sync | I | — | done | see details |
| T27 | PowerShell shell integration | I | — | done | see details |
| T28 | Minor action no-ops cleanup | I | — | in-progress | see details |
| T29 | Mac-side: action fallthroughs to showChildExited | I | — | todo | — |
| T30 | Mac-side: IPC dial must not modal-block | I | — | todo | — |
| T31 | `+list --pid` + real pid leaf data | I | T05 | done | see details |
| T32 | Split IpcServer.zig; pure logic + unit tests | J | — | done | 640457b0d.. |
| T33 | Native win32 test lane | J | T32 | done | see details |
| T34 | Windows shell types, first-class | J | — | done | see details |
| T35 | Sticky pane banner on win32 | I | — | todo | — |
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
| T51 | Full parity RE-AUDIT | — | T50,T22c,T48,T53 | todo | — |
| T52 | Build provenance visible in-app (`+version`) | I | — | todo | — |
| T53 | Long-context reliability + perf soak/tuning | I | T40 | todo | — |
| T54 | Resume-doc diet (this restructure) | — | — | done | 6968d82e7 |
| T55 | FIX: hero-mode.ps1 fails on HEAD (chords not dispatched) — root cause was the TEST's positive control: ctrl+shift+r now opens the T50 modal rename dialog, which disables the owner window and silently ate every later chord. Control switched to ctrl+k (clear_screen, no UI left behind); not a key-path regression | F | T19 | done | (this commit) |
| T60 | FIX: window title jitters a few px left/right on a timer while busy (user, 2026-07-16; row renumbered from a duplicate T56 on 2026-07-16). Likely cause: Claude Code's title spinner — the braille glyphs (⠐/⠂/…) come from a FALLBACK font (MS Gothic per app log) with per-glyph advance widths, so the centered title re-centers to a different width every spinner frame. Investigate where the win32 tab/title text is drawn (Window.zig caption/tab paint); candidate fixes: left-align the title, reserve a fixed-width cell for the leading glyph, or measure/center on the title minus the spinner char | I | — | todo | — |
| T57 | FIX: "Toggle Hero Mode" (and other fork actions) missing from the win32 command palette — the REAL cause of the T49 user report ("no hero mode in command palette", 2026-07-16): the palette is a hardcoded static list (Surface.zig palette_entries), never updated with fork actions, so hero mode was undiscoverable even though the keybind worked. Added: Toggle Hero Mode, Swap Split Right/Down/Left/Up, Rename Window (prompt_surface_title). Skipped prompt_surface_banner (win32 no-op until T35). hero-mode.ps1 grew a palette section: ctrl+shift+p → type "hero" → Enter → hero geometry asserted. Consider (T51 audit): generate palette entries from core command.zig defaults instead of a parallel list, so this class of drift can't recur | F | T19 | done | (this commit) |
| T56 | Remote reconnect on win32 (WP-D1 parity) | G | T21b | todo | — |
| T58 | Hero mode TRUE port — design (win32): Mac hero = animated hero strip + snapshot thumbnail carousel + drag divider; T19 shipped a static live-pane stand-in (user, 2026-07-16). Decided: renderer-side FBO-downscaled snapshots (pre-swap hook in generic.zig; HWND capture rejected — child GL windows have no DWM surface), non-hero panes SW_HIDE + renderer kept awake + all hero-sized (no reflow on swap), owner-painted carousel in new HeroCarousel.zig, snapshot-slide animation, per-tab ratio + divider drag. T59 split → T59a/T59b | F | T19 | done | (this commit) |
| T59a | Hero mode TRUE port — snapshot pipeline + static carousel: hidden-pane capture spike FIRST, then plumbing, hero layout rework, HeroCarousel.zig/hero_math.zig static paint + click-select, hero-mode.ps1 rewrite | F | T58 | todo | — |
| T59b | Hero mode TRUE port — interactions/motion: wheel scroll, divider drag + per-tab ratio, hover chrome, slide + re-center animations, reduced-motion, GHOZTTY_PERF check, screenshot | F | T59a | todo | — |

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
