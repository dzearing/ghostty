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

**THE BAR (user, 2026-07-28, verbatim):** *"we are not done until we have
achieved our overall goals with a 99.9% well validated confidence level that
we have parity in all the places we can with the mac version of ghoztty. that
means current state!"*

Three things follow, and they are not negotiable:

- **Current state, not the state we forked from.** Parity is measured against
  Mac Ghoztty *as it is today*, so upstream merges (T88, T117) are part of the
  job, not a distraction from it — and every merge must be followed by a gap
  audit that files rows (that is what produced T89a–T94 and T118–T128).
- **99.9% confidence means validated, not believed.** A row goes `done` only
  with evidence that was actually run on the box. "It compiles", "it looks
  right", and "the code is obviously correct" are not evidence. When a harness
  and the product disagree, prove which one is lying (T113's four failures were
  the harness; T111b's two prime suspects were both refuted by instrumentation).
- **"In all the places we can"** — where a Mac concept has no Windows analog,
  build the native equivalent and record the divergence in the row, so the gap
  is a decision on the record rather than an omission.

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
   T89f).
16. ~~T89b~~ — DONE 2026-07-19 (`zig build test-agent` green ×3, now part
   of the standing validation set; overlapped-socket harness reads →
   socket_rw + http_client PRODUCTION fix + PtyChild teardown deadlock
   fix + per-OS pty tests; T82 folded in and closed).
17. ~~T89c~~ — DONE 2026-07-20 (agent `--listen-pipe` + `+sessions` pipe
   dial; new `pipe_stream.zig`, RTC re-rooted at `src/` so it builds on
   Windows w/ `--pipe`/`--hold`/`--close-session`, `agent-pipe.ps1`
   ALL PASS (25) ×3; both lanes + test-agent ×3 + P1–P3 green. Filed
   **T96** (pre-existing ConPTY close-teardown hang, repro'd over TCP too)
   + a T89d note on local/relay single-instance separation). Next on-box:
   **T89d1** (split out of T89d, done 2026-07-20: the single-instance note
   fixed — `--listen-pipe` local agent takes a distinct `local[-debug]`
   guard so it coexists with the relay agent) **→ T89d**. NOTE: T89d1's
   validation surfaced **T97** — `zig build test-agent` is red on the box
   from 4 PRE-EXISTING upstream `ssh-cache.DiskCache` AtomicFile/renameatW
   failures (proven on baseline; both app lanes green). **T97 DONE
   2026-07-20** (renameWithRetry backoff on `AccessDenied`) — agent floor
   green ×3 again. The recurring on-box trap is the cross-drive cache
   panic, NOT T97: set `ZIG_GLOBAL_CACHE_DIR=D:\zig-global-cache` before
   diagnosing a red floor. **T89d DONE 2026-07-20** (surfaces open
   under the local agent — `LocalAgent.zig` find-or-spawn + `createWindow`
   injection + `buildRemoteInherit` inheritance + `local_shell_integration`
   branch + agent ^C clear; `session-open.ps1` ALL PASS (18) ×3 incl.
   survives-app-quit; filed T98 for the bogus local-session pid).
17. ~~T89e~~ — DONE 2026-07-20 (close-vs-quit: user close ⇒ CLOSE via
   `setSessionCloseIntent` in the pane/tab/window close paths, app quit +
   WM_ENDSESSION ⇒ detach; palette "Quit Ghoztty (keep sessions)";
   `session-close.ps1` ALL PASS (9) ×3). Validation surfaced **T99**
   (IPC-created windows/tabs/splits aren't agent-backed — only the startup
   window is; the IPC override baton suppresses `buildRemoteInherit`). ~~T99~~
   DONE 2026-07-20 (IPC `+new-window`/`+split`/inline-split now open under the
   local agent via a local_agent branch mirroring remote_dialed; agent-backed
   IPC splits unblocked). T89f was too big for one context, so it was split
   2026-07-20 into **T89f1** (manifest + capture/debounced-atomic-write) and
   **T89f2** (launch restore + ATTACH + suppress blank window). **T89f1 DONE
   2026-07-20** (`session_layout.zig` + `App` capture walk + WM_TIMER debounce
   + pending-sid retry + quit/WM_ENDSESSION flush; `session-reattach.ps1`
   write-half ALL PASS ×3). **T89f2 DONE 2026-07-20** (launch restore:
   `App.restoreSessionLayout` loads the manifest, probes agent liveness
   (tri-state), rebuilds windows/tabs/splits, and threads each leaf's
   `session_id` through a NEW `Overrides.Remote.session_id` →
   `Surface.remoteBackend()` → core ATTACH; blank startup window suppressed
   when restore opens ≥1 window. `session-reattach.ps1` grown to section F
   (mark scrollback → kill app only → relaunch → same 3 sessions ATTACHed +
   scrollback + IPC names + title pin back), ALL PASS ×3; both lanes +
   test-agent + P1–P3 green. Validation surfaced **T100** (`zig build agent`
   exe fails to link on the box — WinMain/subsystem; pre-existing, blocks
   T89h delivery)).
18. ~~T89g~~ — DONE 2026-07-20 (tombstone RELAUNCH floor): the machinery is
   OS-agnostic; the one win32 gap was `restoreSessionLayout` attaching only
   `alive==true` ids (tombstones nulled → fresh OPEN). Fix: propagate wire
   `relaunchable` into `connection.OwnedSession`; forward **alive-or-
   relaunchable** ids to ATTACH so shared termio RELAUNCHes per
   `session-relaunch`. `session-relaunch.ps1` ALL PASS (19) ×3; both lanes +
   test-agent + P1–P3 green. **Next on-box: T89h** (autostart + upgrade guard
   + agent in release zip/MSI + delivery) — needs the AGENT exe, so **T100**
   (build agent via `-Dtarget=x86_64-windows-gnu`, or a wWinMain shim) is the
   real blocker to clear first. T96 still folds with the close path.
   T29/T30/T87 remain Mac-seat.
19. **USER LIVE-REVIEW ITEMS (2026-07-20) — do these FIRST, in order**, ahead
    of T89h (the user surfaced them on-box and is waiting): **(a)** ghoztty-
    skill banner-title fix — the skill sets a banner title WITHOUT a leading
    `#`, so it renders body-size; prefix the title line with `# ` (quick; skill
    lives in the marketplace repo + plugin cache, not this repo). **(b) T101** —
    banner overlay occludes terminal content: `Surface.handleResize` passes the
    FULL pane height to `core_surface.sizeCallback` (Surface.zig:2387), so the
    grid fills the whole pane UNDER the floating layered banner. Inset the
    terminal drawable from the top by the banner strip height, dynamic on
    set/grow/collapse/clear + DPI. **(c) T102** — right-click pastes instead of
    a Mac-parity context menu (Copy/Paste/Split/Change Title/Background Color…);
    build a native `TrackPopupMenu` (T79 dark-mode) wired to the palette
    actions. NOTE: banner heading SIZE was a NON-bug (the user's title lacked
    `#`; sizing already matches Mac — pane-banner.ps1's heading-taller assert
    passes). **(b) T101 DONE 2026-07-20** (strip band now RESERVED above the
    terminal in every layout path — see row; filed T103 for the pre-existing
    pane-banner pixel-oracle/wedge failures found during validation). **(c)
    T102 DONE 2026-07-20** (Mac-parity menu + wparam-mods shift bypass +
    VK_APPS path — the "paste" was Claude Code consuming the reported
    right-click, Mac-identical; shift+right-click opens the menu over such
    TUIs — see row/details). Item 19 is COMPLETE except the item-19(a)
    source-repo mirror (queued at the end of item 20). Next: the item-20
    publish queue, starting at **T100**. (a) DONE 2026-07-20 in the
    ACTIVE PLUGIN CACHE
    (`~/.claude/plugins/cache/dzearing-claude-marketplace/ghoztty/0.4.0/skills/
    ghoztty/SKILL.md`: headings documented + examples use `# Title\n…`);
    durability follow-up: mirror the edit into the source repo
    `github.com/dzearing/ghoztty-claude-plugin` (not cloned on this box —
    clone it, apply, commit/push, bump plugin version).
20. **PUBLISH-READINESS QUEUE (user directive 2026-07-20, standing): work
    fully autonomously — no questions — until the Windows version is READY
    to publish.** Order after item 19's (b)/(c): ~~T100~~ (DONE 2026-07-20:
    msvc GUI-entry fix, agent exe builds — see row) → ~~T89h~~ (DONE
    2026-07-20: autostart Run key + upgrade-script agent guard +
    sessions-survive assert + agent in default build/MSI/publish + docs
    un-gate — see row; delivery to all 3 install locations launched at the
    task boundary, resumed session verifies %TEMP%\ghoztty-upgrade.log —
    VERIFIED 2026-07-20 12:25: exe + agent swapped, share mirrored, correct
    resume) → **T105** (DONE 2026-07-20: restore focus ping-pong live-lock —
    user-hit on the delivered release; foreground-guarded deferred focus; F10/
    F11 oracle baseline-proven; filed T106 visible-relaunch scrollback loss +
    T107 focus-defer tail reds; delivery launched at boundary) → ~~T106~~
    (DONE 2026-07-20: visible-relaunch scrollback loss — parse-geometry root
    cause, additive `Attached.replay_rows/cols` + client capture-geometry
    replay + iconic-frame capture fix; session-reattach F cycle now VISIBLE,
    ALL PASS ×3; filed T109 mixed-geometry-ring endgame) → **T89i**
    (2026-07-21: `session-persistence.ps1` DELIVERED — py-harness port +
    winsize + flood-gap-fill + bounded persistence-on soak; sections A–D
    green; found and FIXED **T110** (split ratios never persisted — every
    restore came back 50/50). Left `blocked(T111)`: its section E
    reproduces a real IPC starvation on the agent path) → ~~T111~~ (split
    2026-07-21 into T111a + T111b — one context could not carry both
    mechanisms). **T111a DONE 2026-07-21**: the stall was measured, not
    guessed — `+list` blocks in its HANDLER (queue 0ms) on each pane's
    `renderer_state.mutex` via `pwd()`, because the agent path's 256 KiB
    ring coalesces the stream and fed the parser 16 KiB (~330ms of
    held-lock parse) per call vs Exec's ~4 KiB/~40ms. Capping one lock
    cycle at 4 KiB took `+list` worst 5504ms → 767ms (Exec baseline
    709ms) and E2 1/40 → 15/40, E10 4.2s → 630ms. It also REFUTED the
    row's prime suspect (too few/coarse lock cycles, not too many —
    T62-style batching would have made it worse). → **T111b (DO THIS
    NEXT — publish blocker)**: section E is still red on E2 (15/40),
    E3/E4 (`+read` 9.2s) and E5 (QUIET-pane round-trip — which a
    per-pane-mutex theory does not explain, so instrument before
    fixing). Hypotheses + the ready-made `.pwd`-cache win are in the
    T111b row. **~~T111b~~ DONE 2026-07-21** — both of its filed hypotheses
    were REFUTED by the instrumentation it added: the failures were (1) a
    single-pipe-instance server that stopped ACCEPTING whenever a handler
    was slow, so a running app answered "No running Ghoztty instance
    found." (reproduced on an IDLE app in 9190ms), and (2) `+list` taking
    every pane's renderer mutex to read a pwd it can cache. Fixed with a
    4-instance accept pool + an eagerly-seeded per-pane pwd cache: **E2
    7/40 → 40/40**, E3/E5/E10 green, `+list` worst 29347ms → 141ms. It also
    caught the harness fabricating 24 of those failures (orphaned CLI child
    holding the redirect file). Section E's remaining two reds are a
    DIFFERENT, now-measured mechanism and were split out as T115 + T114.
    **~~T115~~ + ~~T114~~ DONE 2026-07-21 — one fix, because they were one
    defect.** `closeperf` telemetry refuted T115's filed T63 analogy on the
    first run (`renderer_join=33257ms` vs `io_join=4049ms`): the GUI was
    blocked joining the RENDERER thread, which takes the same per-pane mutex
    once per frame and only notices its stop request there (its own telemetry:
    `slow state mutex acquire ms=65392`). `+read` was starving on that same
    mutex. Fix: a fairness ticket on `renderer.State` — waiters announce
    themselves and clear on ACQUISITION, and the Remote drain keeps the mutex
    FREE between slices until the waiter is in (a real handoff; T111b's bare
    yield was a same-core hint), bounded at 2ms so the drain cannot be starved
    in turn; plus `drainRing` bails once `io.closing` is set. **`session-
    persistence.ps1` ALL PASS x3 — first fully green run**: E4 223/175/207ms,
    E11 154/172/199ms, E12 139/248/140ms, E2 40/40 x3. Renderer worst frame
    acquire 65392ms → 164ms (that number IS the user-visible freeze). Also
    caught a harness trap: `ipc-under-load.ps1` defaulted to the day-old
    `zig-out-release` binary and so failed T111b's accept-pool guard against a
    build that predated it — default repointed at `zig-out\bin` + a staleness
    warning (the T49 lesson, recurring unnoticed in a standing script). **JUMPED AHEAD OF T111b, 2026-07-21: ~~T112~~ DONE** — the
    `/reset-context` breakage is the loop's own continuation mechanism, so it
    was fixed first (cheap, out-of-repo skill edit; the reset at that task's
    boundary was itself the end-to-end validation). Gap it surfaced: ~~T113~~ (win32 never exported
    `$GHOZTTY_PANE_ID` despite CLAUDE.md documenting it; DONE 2026-07-27, see 3b) → **T38** (Windows build in the release process; version+arch
    in installer/zip filenames) → **T39** (website: Windows installer
    download link, same filename format) → the skill source-repo mirror
    from item 19(a). T90b–T90h (viewer panes) follow after publish
    readiness unless the user says otherwise.

3b. ~~**T113**~~ — **DONE 2026-07-27** (user-reported outage: the ghoztty-plugin
   banner hooks silently do nothing on Windows). The app side was already
   committed as WIP `b86dce1d0`; validating it showed all 4 remaining failures
   were **fabricated by the harness** (`Run-Cli`'s `cmd /c` wrapper expanded
   `%VAR%` against the HARNESS's own env before the pane saw the probe), and
   that the outage had a SECOND cause outside this repo: the plugin hook
   `exit 0`s on a missing tty before it ever reads `$GHOZTTY_PANE_ID`, and the
   box had no `jq`. Both fixed; `pane-id.ps1` ALL PASS (45) ×3 including a new
   section G that runs the real hook end-to-end. Plugin-fix durability (mirror
   to the source repo, jq dependency) filed as **T130**. DELIVERY VERIFIED
   2026-07-27 by the resumed session: upgrade log clean, the session's own pane
   exports `$GHOZTTY_PANE_ID`, and the banner hook set this pane's banner (read
   back out of `+list --json`). **DELIVERED to all 3 install locations** (the
   installed release was still 2026-07-21, i.e. the user's panes had no pane id
   at all): staging `+43aa8b972`, portable + share swapped, installed release
   via the detached upgrade script at the boundary — the resumed session
   verifies `%TEMP%\ghoztty-upgrade.log`, then that its OWN pane has
   `$GHOZTTY_PANE_ID`, then that the banner hooks fire.

3c. ~~**T129**~~ — **DONE 2026-07-27** (the other half of the same user report:
   "ctrl-r doesn't rename them"). The chord was right and the app never said so.
   The win32 context menu — the only menu surface Windows has — gained a "Set
   Pane Banner..." row, and every bound row is now labeled `Title\tChord` from
   the LIVE keybind set, so a rebind relabels the menu and unbound rows stay
   bare. `context-menu.ps1` ALL PASS (31) ×3 (incl. choosing the row opens the
   editor, and a rebind run). DELIVERED to all 3 install locations.

3d. **NEXT, in this order** (user-reported live 2026-07-28, ahead of the item-20
   publish queue): ~~**T132**~~ (**DONE 2026-07-28** — the loop-killer. Its filed
   repro turned out NOT to be the defect: the requested pane was always correct,
   and the System32 panes were session RESTORE's. Real causes were the agent
   never recording `OPEN.cwd` (so every RELAUNCH inherited the agent's cwd —
   shared code, Mac too) plus an auto-launch that spawned the GUI with no
   working directory. `auto-launch-cwd.ps1` ALL PASS (21) ×3, negative-control
   proven) → ~~**T131**~~ (**DONE 2026-07-28** — both halves were one defect:
   the T101 band reservation was holding, but the overlay's WINDOW alpha
   composited the stale terminal pixels left in the vacated band through the
   strip. Drawing Mac's `GlassCardBackground` card (new pure `banner_card.zig`)
   composites the card against the pane background, so the window is opaque and
   the see-through is gone with the flat strip. `pane-banner.ps1` ALL PASS (45)
   ×3 — and that script had only ever passed on its FIRST run, because session
   restore handed it back its own previous `bw` window; it now launches with
   `--session-persistence=false`. Closed T103 (its four "box-state" oracle
   failures were the layered alpha) and filed T136 + T137) → **T130** (make the
   plugin-side banner-hook fixes durable) → **T133** (same, for the
   `/reset-context` composer wipe) → T38/T39 per item 20.

4. **Post-merge parity band (T118–T128), filed 2026-07-27 by ~~T117~~** (merge
   of origin/main `1e1cdbbd2`, 70 commits). These do NOT displace T113/T38/T39
   above — slot them in as follows:
   - **T120, T121** are cheap and self-contained (a pure-function constant
     range; a name-reservation rule). Each is a fix main already made to code
     Windows still carries in its **pre-fix** form, so they are pure catch-up
     with a known-good answer to copy. Take them opportunistically.
   - **T118** (instance addressability) is the highest-value item in the band:
     a CLI command run inside a Debug pane silently drives the installed
     RELEASE app, with no per-pane escape hatch on Windows. That is the T116
     confusion class, and it bites *this project's own tooling* hardest.
   - **T125's agent-upgrade half** is the only band item that is a CLAUDE.md
     *contract* gap rather than a feature gap — the mandated "upgrading will
     reset all windows" confirmation has no Windows implementation, and the
     win32 agent already outlives the app, so the skew is reachable today.
     The "What's new" notes UI is a separate, lower-priority follow-on.
   - **T122, T123** are user-visible banner defects (T123 also makes the
     just-merged CLAUDE.md over-promise for win32 — fix the code, not the doc).
   - **T128** is an investigation to run before it becomes a support question,
     and it is cheap: `+sessions` before/after a `+rearrange` that drops a pane.
   - **T119, T124, T126, T127** are gated or cosmetic: T119 and T127 belong
     with the viewer work (T90b–T90h), T126 is an audit, T124 is cosmetic and
     explicitly a Windows-native *reinterpretation*, not a port.

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
| T38 | Windows build in the release process — fold `publish-windows-release.ps1` (gnu-target ReleaseFast, per T100) into the standard release flow so every release produces the Windows zip + MSI alongside the Mac artifacts; installer/zip filenames MUST carry version + arch (e.g. `Ghoztty-<version>-x64.msi` / `Ghoztty-portable-<version>-x64.zip` — match the existing win-vX.Y.Z release asset convention from T24); agent exe included (T89h) | H | T23,T24 | todo | — |
| T39 | Website: Windows installer download link — add the Windows download to the site next to the Mac one, pointing at the latest win-vX.Y.Z GitHub release asset; SAME filename format as published (version/arch in the installer name) so the link/copy stays consistent across releases; include portable-zip alternative + minimum-OS note | H | T38 | todo | — |
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
| T89b | Agent test floor — done 2026-07-19: `zig build test-agent` green ×3. Harness `std.net.Stream` reads = ReadFile-on-overlapped-socket → err 87 (keepalive/link_control/self_update loopback servers → new `socket_rw.readStream`/`writeAllStream`); PRODUCTION fix: http_client's std reader/writer had the same bug (http + the TCP layer under TLS) → socket_rw; PtyChild terminate DEADLOCK (pty.deinit's CloseHandle-before-ClosePseudoConsole blocks forever on the reader's in-flight sync ReadFile) → two-phase `pty.closeConsole`/`deinitAfterReader`; pty tests: defer-order UAF (sink freed before reader join = the T82 "segfault"), POSIX-only commands → per-OS variants, 15.6ms-tick spin waits → wall-clock; link_control test: stale-`connected` reconnect race + leaked loop thread on failure. Lanes + GUI + P1–P3 green | K | T89a | done | (this commit) |
| T89c | Agent `--listen-pipe` mode — done 2026-07-20: new `pipe_stream.zig` (overlapped named-pipe `PipeStream`/`PipeListener`/`dialHandle`, owner-only DACL = the peercred-gate analog, CancelIoEx-on-close), agent `--listen-pipe=\\.\pipe\…` daemon + console-ctrl graceful-stop snapshot + additive port.json `pipe` field, `tcp_dial.dialPipe` + `+sessions` Windows dial (LOCALAPPDATA state dir); RTC re-rooted at `src/` (+shim) so it builds on Windows, gained `--pipe`/`--hold`/`--close-session`; `agent-pipe.ps1` ALL PASS (25) ×3, both lanes + test-agent ×3 + P1–P3 green. Filed T96 (pre-existing ConPTY close-teardown hang, repro'd over TCP too) | K | T89b | done | (this commit) |
| T89d1 | Agent single-instance MODE-KEYED identity — done 2026-07-20: split out of T89d (the folded T89c note). `single_instance` grows an `Instance` key threaded through acquire/takeover/heartbeat; `--listen-pipe` (the Windows local-persistence agent) takes a distinct `local[-debug]` guard (mutex `Global\GhozttyAgentDaemon-local[-debug]-<sid>` + `agent-local[-debug]` lock/heartbeat) so it coexists with a legacy-keyed relay agent; `.listen`/`.listen-unix`/`.relay` unchanged (POSIX `--listen-unix` collision flagged to Mac seat). `is_debug` added to agent_build_options; pure name/path composers unit-tested (filtered exit 0); both app lanes green. `test-agent` red ONLY from 4 pre-existing upstream `ssh-cache.DiskCache` renameatW failures (proven on baseline) → filed T97 (validation-bar blocker) | K | T89c | done | bd253c1bf |
| T89d | Win32 surfaces OPEN under local agent — done 2026-07-20: new `LocalAgent.zig` find-or-spawn (dial port.json{pipe} → CreateProcessW DETACHED spawn → 2s-bounded poll; 15s failure cooldown; exec fallback; `GHOSTTY_LOCAL_AGENT_BIN` override), `App.local_agent` injected at `createWindow` (startup window now routed through it) for non-remote windows when `session-persistence` on, `Window.local_agent_conn` inherited by the initial surface + all tabs/splits via the SAME `buildRemoteInherit` seam as T68, `Overrides.Remote.local_agent`→`remoteBackend().local_shell_integration` (core injects shell-integration/GHOSTTY_* env + `pinned`), agent clears inherited ignore-^C at init (T84, one layer down). `session-open.ps1` ALL PASS (18) ×3 incl. survives-app-quit; P1–P3 (persistence ON) + both lanes + test-agent ×3 green. Filed T98 (bogus local-session pid). (Split 2026-07-20: single-instance coexistence carved out as T89d1.) | K | T89c,T89d1 | done | 091a9682a |
| T89e | Close-vs-quit semantics — done 2026-07-20: user close (pane/tab/window, +close) sets `close_on_exit` via new `Surface.setSessionCloseIntent` in `closeSplitSurface`/`closeTabByIndex`/`Window.close`(markAllSessionsClose) ⇒ agent session ENDS; app-quit teardown (`Window.deinit`) + new WM_QUERYENDSESSION/WM_ENDSESSION handlers send no CLOSE ⇒ sessions survive detached; palette "Quit Ghoztty (keep sessions)" when persistence on; confirm carve-out = no-op (win32 quit has no dialog; close-confirm now accurate). `session-close.ps1` ALL PASS (9) ×3; both lanes + test-agent + P1–P3 green. Filed T99 (IPC-created surfaces not agent-backed) | K | T89d | done | e09698132 |
| T89f | Same-PID re-attach restore — umbrella; split 2026-07-20 (too big for one context) into T89f1 (manifest + capture/write) + T89f2 (launch restore + ATTACH + suppress blank window) | K | T89e | skipped(split → T89f1/T89f2) | — |
| T89f1 | Session-layout manifest + capture/debounced-atomic-write — done 2026-07-20: pure `session_layout.zig` (flat-node schema, snake_case JSON, atomic write, `%LOCALAPPDATA%` path w/ -debug, both-lane unit tests) + `App` capture walk (window frame/maximized, tab order/color/hero-ratio/title pin, split tree + per-leaf session_id/title/ipc-name; excludes remote + quick-terminal windows) + 250ms WM_TIMER debounce armed from every layout/title/color/frame/reorder mutation + bounded pending-sid retry (async OPEN publishes the id late) + flush on `terminate()`/WM_ENDSESSION. `session-reattach.ps1` (write half) ALL PASS ×3; both lanes + test-agent + P1–P3 green | K | T89e | done | 91e01bab4 |
| T89f2 | Launch restore + ATTACH — done 2026-07-20: `App.restoreSessionLayout` (gate on persistence → load manifest → find-or-spawn agent → tri-state `LIST_SESSIONS` liveness probe [drop a window only when EVERY session-backed leaf is positively dead; unknown/probe-fail ⇒ attempt] → rebuild each window via createWindow+addTab+newSplitAt, replaying the flat split tree recursively [horizontal→right/vertical→down, ratio = left share] → reapply title pin/tab color/hero ratio/active tab/frame → re-register pane IPC names). NEW `Overrides.Remote.session_id` + `Surface.remote_session_id` thread the leaf id through `remoteBackend()` (was hardcoded null) → core `RemoteBackend.session_id` so termio ATTACHes (gap-fill = full-ring replay; snapshot capture is T89g). Blank startup window suppressed in `run()` when restore opens ≥1 window. Dead/id-less leaves re-open FRESH agent-backed panes (tree preserved). `session-reattach.ps1` §F ALL PASS ×3 (kill-app-only → relaunch → 2 windows/3 panes, SAME 3 sessions ATTACHed not re-OPENed, scrollback + IPC name + title pin back); both lanes + test-agent + P1–P3 green. Filed T100 (agent-exe build) | K | T89f1 | done | ae5e436a2 |
| T89g | Tombstone relaunch floor on win32 — done 2026-07-20: the tombstone/RELAUNCH machinery is OS-agnostic; the one win32 gap was `App.restoreSessionLayout` building its attach set from `alive==true` only, so relaunchable tombstones were nulled → fresh OPEN. Fix: propagate wire `relaunchable` into `connection.OwnedSession`; forward any **alive-or-relaunchable** id to ATTACH (`attach_set`; `alive`→`attach` rename across 5 restore helpers) so shared termio fires RELAUNCH per `session-relaunch`. `session-relaunch.ps1` ALL PASS (19) ×3 — A(auto): same id RELAUNCHed + divider + pre-kill ring scrollback precedes it; B(prompt): live tombstone + press-any-key affordance, keystroke fires deferred relaunch. Both lanes + test-agent + P1–P3 green | K | T89f | done | e2b4e6555 |
| T89h | Autostart + upgrade guard + agent packaging/delivery — done 2026-07-20: GUI writes/refreshes HKCU Run `GhozttyAgent[-debug]` with the exact spawn command line (shared `agentCommandLine`; release-only, `GHOZTTY_AGENT_AUTOSTART` 0/off/force hooks) when persistence engages; default `zig build` now installs `ghoztty-agent.exe` as a required sibling on Windows; MSI packages it (build-msi.sh hard-requires + File-table version mirrored from the app exe's strictly-increasing FILEVERSION — deliberate version-lie so the T23 vanishing-file rule can't bite the semver-stamped agent); publish script stamps `-Dagent-semver` + verifies; upgrade script never kills the agent, rename-swaps its exe (lazy upgrade) + logs a SESSIONS-SURVIVE assert; CLAUDE.md/Config.zig un-gated to macOS+Windows. `agent-autostart.ps1` ALL PASS ×3 (Run-key shape, reboot proxy via verbatim Win32_Process.Create → tombstones back, debug gate); `msi-upgrade.ps1` ALL PASS (35) incl. new agent-present v1/v2 asserts; session-open/reattach + P1–P3 + both lanes + test-agent green | K | T89g | done | (this commit) |
| T89i | E2E hardening — done 2026-07-21: new `test/win32/session-persistence.ps1` (hermetic, zig-out-lineage-only kills) ports the py harness and adds the scoped soak: A 2-window/5-pane scenario with distinct `+rearrange` ratios, B crash-kill (`taskkill /f`) re-attach ×3 (same session ids, exact topology+ratios, cumulative scrollback; recovery 1.1–1.2s), C winsize/ConPTY geometry across restore (`mode con` oracle — no tty needed), D flood-during-reattach gap-fill (region-split loss contract: nothing lost from the dead-gap/post-attach region; ≤1 clobbered row in the replayed pre-kill block = the T109 junction), E persistence-on soak (double storm: +list 40/40, echo-storm +read 144ms < T62 2s, mid-storm relaunch re-ATTACHed 7/7, +close 7.9s/6.4s < T63 10s, IPC recovers to sub-2s). Surfaced+fixed **T110**. A–D are green and stable; the harness is DELIVERED and doing its job. Status is `blocked` rather than `done` ONLY because its own bar (ALL PASS ×3) cannot be met while **T111** — the agent-path IPC starvation section E reproduces (`+list` 1/40) — is open: E's asserts are precedented (`ipc-under-load.ps1` holds the same bar on the Exec path), so they stay RED as a real product signal instead of being relaxed to fit. Flip to done once T111 lands | K | T89h | blocked(T114+T115 — section E's E4/E11/E12 still red; T111/T111a/T111b took E2/E3/E5 green) | (this commit) |
| T110 | FIX: split-ratio changes never armed the session-layout capture — found by T89i (2026-07-21): baseline ratios 0.30/0.70/0.40 came back **0.5/0.5/0.5** after every crash-kill restore (deterministic ×3). `markLayoutDirty` was called from every topology/title/color/frame mutation but from NO ratio mutation, so the manifest kept whatever ratios existed at the last unrelated write — a `+rearrange` or divider drag that was the final change before quit was never persisted, and restore rebuilt splits at their creation default. Restore side was already correct (`restoreBuildSubtree` → `newSplitAt` → `SplitTree.split` forwards the ratio); there was simply nothing but 0.5 to pass. Fix: arm the capture in `endDividerDrag` (at drag END — one debounced write per drag, mirroring `persistPlacement`'s WM_EXITSIZEMOVE coalescing), `equalizeSplits`, the divider double-click reset, and `handleRearrange`. Missed until now because `session-reattach.ps1` B5 only asserts the ratio is IN RANGE (0.5 passes) — catching it needs a distinct ratio compared across restore, which is T89i's B*.6. **NOT YET DELIVERED** to the 3 install locations (go.md's delivery rule): it is user-visible and should ship, but deliberately held to ride WITH the T111 fix rather than shipping a release that still carries the T111 freeze on the same subsystem. Deliver both together when T111 lands. **STILL HELD after T111b (2026-07-21):** T111b fixed the IPC outage but unmasked T115 — `+close` of a flooded pane now blocks the GUI thread ~65s where it took ~7s before. Shipping now would trade an IPC failure the user can retry for a minute-long GUI freeze they cannot, so delivery waits for T115 (then T114). **DELIVERED 2026-07-21** with the T114/T115 fairness fix — the whole held stack (T110 ratios + T111a/T111b IPC + T114/T115 renderer-mutex fairness) shipped to all 3 install locations together, which is what the hold was for | K | T89f1 | done | (this commit) |
| T111 | FIX: IPC dies under a sustained agent-backed DOUBLE storm (byte-heavy `type` loop + tiny-write echo loop, both agent-backed) — found by T89i 2026-07-21, now REPRODUCIBLE. First hit: the app window went Windows-"Not Responding" with a `ghoztty +list` unanswered for minutes (user-visible; killed by hand). Re-run with the guarded harness: **E2 `+list` answered 1/40** (38 fast failures + 1 hard timeout), and E3/E4/E5 then failed too — the GUI is starved for the whole storm section, not momentarily slow. TWO DISTINCT failure strings, both captured in artifacts: `Failed to read IPC response length` (pipe connected, reply never came) and **`No running Ghoztty instance found.`** (the CLI cannot even connect — the GUI-thread pipe listener has stopped ACCEPTING). Not the T53a signature (`server not ready` = posted-message quota), so the wakeup-coalescing fix does not cover this. The bar is precedented, not invented: `ipc-under-load.ps1` runs the SAME `type`-loop storm and asserts the SAME 40/40, and T62/T63 hold it on the Exec path — so the agent data path is strictly worse than the path it replaced, and since persistence is default-on EVERY local pane now lives there. Prime suspect: renderer-mutex starvation — `Remote`'s ring drain calls `processOutputTracked` per chunk (up to 32 per wake), one lock cycle each, where T62 fixed exactly this for Exec by batching to ONE lock cycle per batch. Start by A/B-ing the same storm with `--session-persistence=false`. PUBLISH BLOCKER (GUI freeze on the default path). **Split 2026-07-21 into T111a (landed) + T111b (remainder)** — one context could not carry both mechanisms; the prime suspect above was MEASURED AND REFUTED (see T111a) | K | T89i | skipped(split → T111a/T111b) | — |
| T111a | FIX: bound per-lock parse work on the agent drain — done 2026-07-21. Instrumented the boundary instead of guessing: `+list`'s GUI-thread wait splits into **queue 0ms + handler 1400–5500ms**, and inside the handler it is `buildNode`'s per-leaf `core_surface.pwd()` (title/pid are 0ms) blocking on that pane's `renderer_state.mutex`. Drain telemetry: `lockwait=0%` — the drain never WAITS for the mutex, it HOLDS it, feeding the parser **16 KiB per `processOutputTracked` call ≈ 330ms of held-lock parse per chunk**. The 256 KiB inbound ring COALESCES the stream, so the agent path hands the parser 4x what a ConPTY `ReadFile` ever returns (Exec measured at ~4 KiB / ~40ms holds). This **REFUTES the T111 prime suspect** (it guessed too MANY lock cycles needing T62-style batching; the truth is too FEW and too COARSE — batching would have made it strictly worse). Fix: `feedSliced` + pure `SliceIter` cap one lock cycle at 4 KiB, converging on T62's "one lock cycle per ~4 KiB" from the opposite direction. Same storm, measured A/B: `+list` worst **5504ms → 767ms** (Exec baseline 709ms), `pwd()` worst **3257ms → 534ms** (Exec 569ms) — agent path is no longer strictly worse than the path it replaced. Harness: **E2 1/40 → 15/40**, **E10 4.2s → 630ms**, E11/E12 `+close` 3.5s/1.5s. 4 new `SliceIter` unit tests (canary-verified to actually run); both lanes + test-agent + build green | K | T89i | done | (this commit) |
| T111b | FIX: the IPC server stopped ACCEPTING under load; `+list` sat on every pane's renderer mutex — done 2026-07-21. **BOTH filed hypotheses were wrong**, and only instrumentation said so. Added `GHOZTTY_PERF` timing at the IPC boundary (accept/read/queue/handler, `+read` lockwait-vs-dump, a named line per pwd cache miss). It showed (a) a `+list` handler at **29347ms** with **queue 0ms** — not message-loop starvation; (b) E4's `+read` logged **no handler line at all**, so its 9202ms was never a read latency, the request never reached the app — refuting hypothesis 1 as its cause; (c) an isolation experiment on an IDLE app (one raw client occupies the single pipe instance) reproduced T111's exact string and latency: **9190ms then `No running Ghoztty instance found.`** Root cause was therefore TWO layers: the **amplifier** — one pipe instance served strictly serially, so any slow handler stopped the server ACCEPTING and a running app reported itself absent (a failed `ConnectNamedPipe` also retired the listener for the life of the process); and the **trigger** — `buildNode` called `core_surface.pwd()` per leaf, taking each pane's renderer mutex. Fix: a 4-instance accept pool (instance 0 keeps FIRST_PIPE_INSTANCE, so the single-instance lock is unchanged; handlers still run one at a time on the GUI thread) + accept-failure recovery; and a per-pane cached pwd fed by the `.pwd` action win32 previously ACKed and dropped (the GTK use of that action), seeded eagerly at surface creation while the pane is still quiet — lazy seeding charged that lock to whichever `+list` saw the pane first, measured as a 19155ms handler. Cached negatively too: a pane launched without a working directory never gets a terminal pwd, and re-asking put `+list` straight back on the mutex (68312ms handler). Result: **E2 7/40 → 40/40**, E3/E5 green, E10 first-probe 2662ms → 117ms, `+list` worst **29347ms → 141ms** with handler=0ms and zero cache misses. Also FIXED a harness defect that had been fabricating evidence: `Run-Cli` killed only cmd.exe on timeout, so the orphaned CLI child kept the redirect file open and every later probe died at ~35ms with exit 1 and no output — 2 real timeouts recorded as 26 failures (now `taskkill /F /T`). Left red and split out: **T114** (`+read` lock fairness) + **T115** (`+close` teardown) | K | T111a | done | (this commit) |
| T114 | `+read` of a FLOODED agent-backed pane loses long races on that pane's renderer mutex — section E's E4, all that is left of it after T111b removed the connect failure that used to mask it. Now measured as real work: `ipcperf read pane=echoP lockwait=15514ms dump=47ms` — the wait is ~190 CONSECUTIVE lost races against the drain, not one long hold (T111a already bounded each hold to 4 KiB). T111b added `std.Thread.yield()` between slices in `feedSliced`, which moved the worst lockwait 15514ms → 1439ms — enough to prove the mechanism, NOT enough to hold E4's 2000ms bound (a later run still spiked to ~11.9s). SwitchToThread only yields to a ready thread on the SAME processor, so it is a hint, not a handoff. Candidate: a real fairness ticket — an atomic "a GUI-side waiter wants this pane's mutex" that the drain checks between slices and honors with a bounded sleep, so a waiter cannot be starved indefinitely. Note the drain is SHARED core code (`termio/Remote.zig`, used by Mac remote panes too), so the flag needs a home that does not regress the other apprts; verify both lanes and leave Mac behavior unchanged. Validation: section E's E3/E4 within the T62 2000ms bound, plus `ipc-under-load.ps1` for the Exec path. PUBLISH BLOCKER. **DONE 2026-07-21 — same fix as T115, because they were the same defect**: a fairness ticket on `renderer.State` (`priority_waiters` + `lockPriority`/`yieldToPriorityWaiters`) lets the Remote drain keep the mutex FREE between slices until an announced waiter is actually inside — a handoff, where T111b's bare yield was only a same-core hint. `+read` lockwait 23628ms → 10–27ms, worst probe 30259ms → 206ms. The candidate in this row is what shipped; the one correction measurement forced is that the bound must be a DURATION (2ms), not a spin count — 512 SwitchToThread calls elapse in microseconds and can expire before a waiter on another core is scheduled (caught by a unit test, not by the box) | K | T111b | done | (this commit) |
| T115 | `+close` of a FLOODED agent-backed pane blocks the GUI thread for a MINUTE in its teardown — section E's E11/E12 (T63's 10s bound). Measured on the GUI thread, so this is not a connect or queue effect: `ipcperf action=close handler=64883ms`, and the next verb behind it logged `queue=24864ms`. This is the Remote-backend analog of T63 (which fixed exactly this for Exec: a missed one-shot CancelIoEx left the reader blocked and `+close` hung 9+ minutes). REGRESSION HONESTY: E11/E12 PASSED before T111b (7192ms/3129ms on the same box the same day) and fail after it — not because close got slower in itself, but because T111b stopped the GUI thread from hogging the renderer mutex, which had been throttling the drain and pacing the storm. The cost was always there; T111b removed what was hiding it. Both `+close` and `+read` (T114) scale together with drain aggressiveness — the T111b yield moved close 33s → 18s in the same experiment that moved read 15.5s → 1.4s — so the two may share a fix; check T114 first, and fold T96 (pre-existing ConPTY close-teardown hang, repro'd over TCP) in here. Validation: E11/E12 under the T63 10s bound, `+close` never blocking the GUI thread more than that. PUBLISH BLOCKER. **DONE 2026-07-21 — and the filed T63 analogy was REFUTED by the first measurement.** New `closeperf` telemetry splits `Surface.deinit` into its three serial phases and named the culprit immediately: `shutdown=0ms renderer_join=33257ms io_join=4049ms` — the IO teardown this row blamed was 11% of it. The GUI was blocked joining the RENDERER thread, which takes the same per-pane mutex once per frame in `updateFrame` (and that is where it notices its stop request); its own long-standing telemetry read `slow state mutex acquire ms=65392`. So T115 and T114 were one defect with two victims, fixed by the T114 fairness ticket: renderer_join 33257ms → 61ms, renderer worst acquire 65392ms → 164ms, `+close` 37452ms → 252ms. Second, smaller fix in the same path: `drainRing` returns immediately once `io.closing` is set (finishing a wake parses up to 32×16 KiB into a terminal about to be freed — ~7.7s of the 10s bound; io_join 4049ms → 38ms). T96 folds in: the close path no longer blocks on teardown parse | K | T111b | done | (this commit) |
| T116 | FIX (harness safety): `session-persistence.ps1` drove the USER'S live terminal when pointed at a release exe — found 2026-07-21 while trying to grade the delivery artifact with `-Exe zig-out-release\bin\ghoztty.exe`. The script is hermetic in `LOCALAPPDATA` only; its ENDPOINTS come from the build mode (Debug ⇒ `ghoztty-debug-<user>` + `ghoztty-agent-debug-<user>`), and that — not the temp dir — is what had always kept it clear of the installed release. With a release exe both names collide: the app it launches loses the single-instance race, so every CLI call in the script, `+close` included, is aimed at the running instance. Sections A–D "failed" against the user's windows while closing them; the GUI ended up gone (persistence kept every shell alive under the agent, including the session driving the work, and they came back on relaunch). `GHOZTTY_PIPE_SUFFIX` cannot fix it — `LocalAgent.pipeName` derives the agent pipe from build mode alone. Fix: a mechanism-free pre-flight — if anything already answers on the endpoint the target exe would use, abort (exit 2) before touching a window; plus a header note that a release artifact simply cannot be graded by this harness. Lesson: "hermetic" was true of state and false of endpoints, and only one of those was written down | K | T89i | done | (this commit) |
| T112 | FIX (loop hygiene): pane SELF-identification is broken for agent-backed panes, which breaks `/reset-context` — found 2026-07-21 at the T89i boundary, on the INSTALLED release (f9be1f35d). `ghoztty +list --pid=<winpid>` returns `IPC request failed` from inside a pane while plain `+list` and `+version` answer fine, because persistence is default-on (T89h): every local pane's shell is a child of `ghoztty-agent`, NOT of the GUI, so `ProcessTree`'s ancestry walk can never match — and `+list` shows those panes as `pid:0` (the T98 lineage). The documented fallback fails too: `$GHOZTTY_PANE_ID` is UNSET in the pane (CLAUDE.md promises it is baked at spawn and preserved across re-attach, and calls it the preferred self-ID over pid/tty) — must distinguish "not baked for agent-backed panes" from "this pane predates the feature and kept its old baked env across re-attach", so check a FRESHLY created agent-backed pane first. `$GHOZTTY_PANE_NAME` is not a substitute (it holds the WINDOW name for `+new-window` panes). IMPACT beyond tooling: `/reset-context` resolves its own pane this exact way, so the autonomous loop can no longer reset its own context — the precise failure mode that produced the 716k-token session go.md exists to prevent; it now depends on the user clearing by hand. Fix the export (and/or give `+list` a self-ID path that works for agent-backed panes), then repoint the reset-context skill at it | K | T98 | todo | — |
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
| T96 | FIX: agent session CLOSE with a live ConPTY child hangs the serving thread on Windows — found by T89c (2026-07-20). `handleCloseSession`/`handleClose` UNLINK the session (roster updates), then `freeUnlinked` → session.deinit → `Pty.deinit` blocks ~forever tearing down the ConPTY (the T89b two-phase `closeConsole` fix was applied to the TEST teardown; the PRODUCTION close path still uses the untouched `Pty.deinit`), so the `CLOSE_SESSION_RESULT` reply is never sent and the client's RPC times out (~10s). Transport-independent (repro'd over TCP too, exactly 10s). Blast radius bounded: only that one serving thread wedges; the accept loop + other connections keep working. Fix: apply the two-phase pty teardown (close pseudoconsole → join reader → deinit) to the production session-close path. Folds naturally with T89e (close-vs-quit) | K | T89b | todo | — |
| T97 | FIX (validation blocker): `zig build test-agent` red on the box — 4 failures, all `cli.ssh-cache.DiskCache` (`disk cache operations` + `disk cache cleans up temp files`, ×2 test binaries) in `renameatW → ACCESS_DENIED` from `std.fs.AtomicFile.finish()`. Found by T89d1 (2026-07-20); PROVEN pre-existing (identical on the pre-T89d1 baseline via git-stash) and upstream (came in via T88's merge: `5423d64c6` ssh-cache AtomicFile + `d29e1cc13` "windows: ...lack of file locking"). Deterministic now (AtomicFile tmp+rename racing Defender/indexer on Windows); T89c's "green ×3" caught a quiet window. Blocks the standing test-agent bar for ALL tasks. Likely fix: retry `finish()` on ACCESS_DENIED (Windows rename-replace flake) or drop the CLI ssh-cache tests from the agent graph. NOT in the app lanes (both green). Candidate for the Mac seat (upstream code). DONE 2026-07-20: `DiskCache.writeCacheFile` now flushes then `renameWithRetry` — retries `renameIntoPlace` on `error.AccessDenied` with 1/2/4/8/16ms backoff (Windows only; POSIX makes one attempt), so an AV/indexer racing the atomic rename no longer flakes the write. New test "disk cache repeated rewrites replace atomically". test-agent green ×3 + filtered `disk cache` green + both app lanes green. NOTE: the box's real recurring trap is the cross-drive cache panic (needs `ZIG_GLOBAL_CACHE_DIR=D:\zig-global-cache`), which masquerades as this failure when unset | — | — | done | 220132f9c |
| T98 | FIX: local-agent session pid reads as a system pid on Windows — `+sessions`/`+list` report a bogus child pid (428 "Secure System" observed) for a LOCAL agent-backed ConPTY session instead of the shell pid; ConPTY reparents the child, so the agent's recorded pid does not track the real shell. Found by T89d (2026-07-20; worked around there by proving agent-ownership via survives-app-quit instead of pid ancestry). Impact: `+list --pid` self-ID and any pid-based tooling on agent-backed panes. Pre-existing agent behavior (T89b/T89c pty pid capture), not introduced by T89d; NOT in the parity validation lanes. Investigate the agent's ConPTY child-pid capture (PROCESS_INFORMATION.dwProcessId vs the pseudoconsole host) | K | T89b | todo | — |
| T99 | FIX: IPC-created windows/tabs/splits are not agent-backed on a local persistence window — with `session-persistence=on` only the STARTUP window's pane is agent-backed; `+new-window`/`+split`/`+new-window --split` (proven on-box: real pids, no `+sessions` row) open plain exec panes. Root cause: the IPC override baton (env/name vars, non-null even with no command) suppresses `buildRemoteInherit`'s local-agent injection in `addTab`/`newSplitAt` — the `remote_dialed` branch handles cross-machine but no `local_agent_conn` branch exists. T89d-lineage gap; agent-created panes silently don't persist. DONE 2026-07-20: handleNewWindow (first pane), its inline split, and handleSplit each gained a local-agent branch mirroring `remote_dialed` — no explicit cmd/cwd ⇒ null baton so `buildRemoteInherit` injects the agent (splits inherit the parent's cwd via GET_CWD); else a `.remote{local_agent=true}` override carrying the agent-native command + the name env. createWindow's is_remote check now excludes local-agent overrides so a `+new-window`'s window still gets `local_agent_conn` for its later tabs/splits. `session-open.ps1` grew section D (a `+split` and a `+new-window` each add a `+sessions` row, `+list` pid 0, split typing round-trips) + a whitespace-tolerant read (narrow minimized-window panes wrap one glyph/line); `session-close.ps1` grew section D (close ONE pane of a 2-pane window ⇒ only that session ends, sibling survives) — the scenario T99 unblocks. Both ALL PASS ×3; both lanes + test-agent + P1–P3 green | K | T89d | done | c1e3fb513 |
| T84 | FIX: ctrl+c never interrupted ConPTY children — root cause: the GUI process inherited the ignore-^C flag (set by CREATE_NEW_PROCESS_GROUP anywhere up the launcher chain — scripts, CI, `+new-window` auto-launch from automation) and every ConPTY shell inherited it in turn; conhost's 0x03→CTRL_C_EVENT cooking was never broken. Fix: clear the flag at App.init via `SetConsoleCtrlHandler(null, 0)`. Probe scenarios added to conpty_smoke (`--ctrlc`/`--ctrlc-win32`/`--ctrlc-anon`/`--ctrlc-mode`/`--ctrlc-host`/`--ctrlc-self`/`--report-ctrlc`). `keybinds-t01.ps1` ALL PASS (23) incl. the SIGINT assert. See details | I | — | done | 3b085a661 |
| T101 | FIX banner occlusion — done 2026-07-20: the real culprit was deeper than sizeCallback (win32 renderer re-reads the HWND client rect every frame, so a height lie only blanks the pane BOTTOM); fix = reserve the strip band in all 3 surface-positioning paths (layoutNode/zoomed/layoutHero) via new pure `banner_layout.clampInset` + `Surface.bannerLayoutInset`, overlay glues INTO the vacated band (`owner.top - inset`), relayout on set/clear/collapse (`App.relayoutOwnerWindow`) + DPI. Grid/viewport/mouse all follow the real client rect. pane-banner.ps1 matcher now REQUIRES bottom-meets-pane-top + 5 new band asserts, stable ×3; lanes + test-agent + P1–P3 green. Remaining failures are pre-existing box/oracle issues → T103 | I | T35 | done | (this commit) |
| T102 | Mac-parity right-click context menu — done 2026-07-20. The user's "right-click pastes" was Claude Code receiving the reported right-click (mouse reporting consumes the press — Mac-identical); the real gaps fixed: menu grown to full Mac parity (pure `context_menu.zig` model: Copy/Paste/Select All, 4 splits, Reset, Read-only checkbox, Background Color…, Tab/Pane Title…), shift+right-click bypass made reliable (mouse mods now from wparam MK_ bits), WM_CONTEXTMENU (VK_APPS) keyboard path added. Disposition: default = menu (Mac parity), `right-click-action=paste` stays the WT-style opt-in. `context-menu.ps1` ALL PASS (19) ×3 (PostMessage-driven, wedge-immune); lanes + test-agent ×3 + P1–P3 green. See details | I | T67,T79 | done | (this commit) |
| T103 | FIX: pane-banner.ps1 pixel oracles + editor chord red on the box — PRE-EXISTING (proven at pre-T101 baseline via git-stash, identical failures): both CopyFromScreen composite AND own-DC GetPixel read pane bg instead of the strip fill (banners DO render interactively — probe-context issue: topmost/owned-popup z-order, GetPixel-on-layered semantics, or box state), plus ctrl+shift+b swallowed (T95 GameInputSvc wedge signature). T91 was ALL PASS ×3 on 2026-07-19; broke between then and 2026-07-20 with no banner-code change. Re-probe after wedge clears; rework oracles if still red. See details | — | — | done | 732dabac9 — RESOLVED BY T131, and the cause was the product, not the box: both pixel reads were of a `WS_EX_LAYERED` SLWA-242 window, whose composite the probes could not read reliably (and whose alpha was itself the T131 bug). The card overlay is opaque, so all four are green ×3 — composited pixel now EQUALS the own-DC pixel, `checked box paints green check pixels` (31 found), and `ctrl+shift+b opens the banner editor` passes with no wedge |
| T104 | PARITY GAP: win32 GUI ignores `-e <args…>` (Mac/Linux `ghostty -e cmd…` runs the command in the first window; on win32 the args are silently dropped and the pane runs the default shell). Found by T102 validation (2026-07-20) — its harness had to fall back to `--command=…` (which works, incl. spaces when quoted as one argv entry). Implement `-e` arg collection in the win32 CLI/app launch path mapping to the same exec override as `--command`, matching the Mac flavor conventions; add a launch case to an acceptance script | I | — | todo | — |
| T100 | FIX native-MSVC GUI-subsystem link (`undefined symbol: WinMain`) — done 2026-07-20: with MSVC libc + `pub fn main`, std.start exports only C `main`, and `/subsystem:windows` makes lld-link pick libcmt's `WinMainCRTStartup` (needs a never-defined `WinMain`). Fix: keep the GUI subsystem, enter via `mainCRTStartup` — new `src/build/win32_entry.zig setMsvcGuiEntry` (msvc-abi-gated `exe.entry`) wired into GhosttyAgent + GhosttyExe's Windows-subsystem branch; gnu target untouched. `zig build agent` + ReleaseFast msvc app both link; agent Subsystem=2 in PE; `agent-pipe.ps1` ALL PASS ×3; lanes + test-agent ×3 + P1–P3 green. T89h unblocked | K | — | done | (this commit) |
| T105 | FIX: 2-window session restore live-locks in a foreground ping-pong — done 2026-07-20: each restored window's queued WM_APP_SETFOCUS assert steals activation from the other; the loser's WM_SETFOCUS forwarding queues the next assert, alternating forever (app uncontrollable; hit by the user on the T89h-delivered release). Fix: `App.performDeferredFocus` executes a deferred assert ONLY while its root window holds foreground (a deferred assert is a forward of focus already received, never a grab); stale asserts drop, both pump loops (run loop + ConfirmDialog modal) routed through it. Oracle: `session-reattach.ps1` new F10 (2nd app-kill + VISIBLE relaunch + early foreground grab + 3s flip sampling) + F11 (seeded co-pending 0x8005 asserts must settle) — baseline-proven RED pre-fix (F10 33–38 flips/3s, F11 38–44), ALL PASS ×3 post-fix (0 flips); focus-defer.ps1 click asserts still pass (its 2 tail reds are pre-existing → T107); both lanes + test-agent ×3 + P1–P3 green. Validation also surfaced T106 | K | T89f2 | done | (this commit) |
| T106 | FIX: visible relaunch loses re-attached scrollback — done 2026-07-20. Byte-dump proof: visible/minimized get IDENTICAL streams; the loss was parse-GEOMETRY (raw ring replay is geometry-bound VT — at the restored window's transient grid the recorded scrolls never fire, so nothing reaches scrollback before conhost's post-attach `ESC[2J` fresh-paint). Fix: agent reports pre-attach geometry via additive `Attached.replay_rows/cols` (agent-floor test added); client replays at it (`attach_reflow_target`, reflow-to-live exactly at `snapshot_at_offset`, straddling chunk split); `captureFrame` records rcNormalPosition for iconic windows (was the −32000 stub). session-reattach.ps1 F5 flipped to VISIBLE (F8 = the pre-fix-RED oracle) ALL PASS ×3; session-relaunch/open/close, both lanes, test-agent ×3, P1–P3 green. Mixed-geometry-ring remainder → T109 | K | T89f2 | done | (this commit) |
| T107 | FIX: focus-defer.ps1 tail asserts red on the box — PRE-EXISTING (2026-07-20, identical on pre/post-T105 binaries ×3): after the FD-LOAD flood + 1500-click storm, `+list` times out (>8s; GUI-thread IPC listener busy — the script's own teardown comment already notes the flood keeps it busy) and `focus still moves after storm` fails, while WM_NULL stays responsive; separately the 3-pane setup intermittently yields 1 surface (split race after a fresh agent spawn). Likely harness timing (flood pacing + foreground loss), possibly a real listener-starvation bug under sustained output — decide which and fix script or product | — | T48 | todo | — |
| T109 | Mixed-geometry ring replay → WP-D3 persisted snapshots on Windows — filed from T106 (2026-07-20). The ring concatenates segments drawn at different geometries (each attach resize appends a conhost fresh-paint at the new size); single-geometry replay is only faithful for its own segments (T106 anchors to the agent's last-drawn geometry — right for the stable common case). Endgame: persist a WP-D3 structured snapshot per pane (debounced, beside the T89f manifest) and attach at `attach_offset = snapshot offset` so no full-ring raw replay happens; folds in T106's evicted-head completion-lag caveat. T89i (2026-07-21) measured the user-visible cost: at the junction where the replayed block starts overwriting the restored pane's existing screen content, exactly ONE already-seen row is clobbered before it can scroll into scrollback (seq 6 lost in one run, seq 2 in another, none in a third — always inside the replayed pre-kill block, never in the dead-gap; the same junction truncates the replayed cmd banner mid-line). `session-persistence.ps1` D5 bounds it at one row and D5b guarantees zero loss in the dead-gap/post-attach region, so this fix's win is that last row. After publish readiness | K | T89f2 | todo | — |
| T108 | INVESTIGATE: release-box restore anomalies seen during the T105 episode (2026-07-20, from the session that wrote the fix): (a) manifest leaves arrived WITHOUT `session_id` → restore spawned FRESH pinned cmd sessions instead of re-attaching (agent session leak — 7 pinned sessions accumulated; `+sessions` on the user's local agent is the check); (b) `session-layout.json` capture stopped updating (stale since 12:02 that day, before the live-lock episode). Neither reproduces in session-reattach.ps1 (its leaves always carry ids, capture asserts green) — likely release-box lineage (pre-T89f2-fix app writing, or debounce timer starved during the ping-pong). Verify against the delivered post-T105 release: check the user's manifest freshness + pinned-session count, prune leaked sessions, and root-cause if either recurs | K | T89f2 | todo | — |

| T112 | FIX (loop-critical): `/reset-context` is broken for EVERY agent-backed pane — its Step 1 probe maps the session to a pane via `/proc/self/winpid` → `ghoztty +list --pid=<winpid>`, which returns empty because ConPTY reparenting makes agent-backed panes report a bogus child pid (this IS T98's impact, escalated: session-persistence is default-on, so every local pane is agent-backed and pid ancestry never resolves). Observed 2026-07-21: the loop worker finished T89i, tried to self-reset, got "pane lookup came back empty", and stalled at an idle prompt until the supervisor typed `/clear` by hand — i.e. this breaks the autonomous loop's own continuation mechanism, not just a convenience command. Durable fix: switch the skill's probe to `$GHOZTTY_PANE_ID` (CLAUDE.md already names it the preferred self-ID: baked at spawn, survives relaunch/re-attach, valid for agent-backed AND remote panes where pid/tty are meaningless), keeping the `--pid` walk as fallback; skill lives in the marketplace repo + active plugin cache (same two-location edit as item 19a), not this repo. Fixing T98's pid capture would ALSO restore the old path but is neither necessary nor sufficient for remote panes. **DONE 2026-07-21**: root cause CONFIRMED on-box — `+list --json` reports `"pid":0` for every pane, so the ancestry walk answers "IPC request failed". `$GHOZTTY_PANE_ID` turned out NOT to exist on win32 (Mac-only; filed **T113**), so the fix is a verified 3-step chain: `$GHOZTTY_PANE_ID` → `$GHOSTTY_SURFACE_ID` as unsigned decimal (== the pane's registered name; the raw `0x` hex is rejected) → the legacy `--pid`/`--tty` walk, each candidate probed with a cheap `+read` so a wrong value falls through instead of clearing someone else's pane. Both locations edited (active plugin cache 0.10.1 + source repo `D:\git\dzearing-claude-marketplace` — it IS on this box, contrary to the item-19a note; pushed as b9a1082, plugin 0.10.1→0.10.2) | K | — | done | b9a1082 (marketplace repo) |
| T113 | win32 doesn't export `$GHOZTTY_PANE_ID` — CLAUDE.md documents it as the universal, preferred pane self-ID ("baked at spawn", "accepted directly by every `--target`/`--name`", "prefer it over pid/tty"), but grep shows the Zig/core side only ever sets `GHOSTTY_SURFACE_ID` + `GHOZTTY_WINDOW_NAME`/`GHOZTTY_PANE_NAME` (`src/Surface.zig:896-900`); the id is a Swift/macOS-side concept, and win32's `+list --json` leaf `id`/`name` is the decimal surface id instead. Found by T112, which had to add a `$GHOSTTY_SURFACE_ID`→decimal fallback because of it. Fix: export `GHOZTTY_PANE_ID` on win32 (surface-id-derived is fine — it is already stable and persisted in the session-layout manifest) AND accept the `0x…` hex spelling as a target alias, so the documented contract holds on both platforms and the T112 fallback becomes dead weight rather than load-bearing. Also re-check `+list --json` leaf `id` naming vs the Mac golden shape. **PRIORITY RAISED 2026-07-27 — this is not a documentation-contract nicety, it is why the user's banner hooks are dead.** Root-caused on the box from the user's report ("the ghoztty plugin is supposed to have hooks to update the banner which isn't working"): the plugin's `resolve_pane()` (ghoztty plugin 0.7.0, `hooks/ghoztty-banner.sh`) tries `$GHOZTTY_PANE_ID` → a cached name validated against `/dev/$TTY_NAME` → `ghoztty +list --tty="$TTY_NAME"`, and on Windows ALL THREE fail: the var is unset (this task), and `tty` reports "not a tty" in an agent-backed pane so both fallbacks get an empty tty. `resolve_pane` returns empty, `+set-banner` is never called, and the SessionStart/UserPromptSubmit/Stop hooks silently no-op. Confirmed in a live pane: `GHOZTTY_PANE_ID=<unset>`, `GHOSTTY_SURFACE_ID=0x95584e6058ee31b6`, `tty=not a tty` — and that hex as decimal (10761437485317632438) IS the pane's registered name, which is exactly why T112's fallback works and is currently load-bearing. **Implementation is already written and committed as WIP `b86dce1d0` (unvalidated); what remains is validation.** The user-visible end-to-end validation this row previously lacked: after the fix, the plugin's banner hooks must update the banner with no plugin edit. **FIRST VALIDATION RUN 2026-07-27: 4 FAILURES of ~35, and the CORE of the task is GREEN.** Passing: A/B (fresh ids, distinct per pane, resolve with no registration, `+set-banner --target=<id>` lands on the right pane and leaves the sibling alone), **D (app-quit re-attach — same id, manifest carries it, re-attached shell's baked id unchanged)** and **E (agent restart / tombstone RELAUNCH — same id, respawned shell baked with it)**, i.e. the hard durability half of the contract holds. Hand-verified out-of-band on a hermetic exec instance: `+list --json` leaf `id` is now a real UUID (`BF8BB0F1-…`, Mac golden shape), the pane bakes BOTH `GHOZTTY_PANE_ID=<uuid>` and `GHOSTTY_SURFACE_ID=0x…`, and **both legacy aliases DO resolve** (`+set-banner --target=0x926ab37d70c1d227` and `--target=10550442428412842535` each exit 0 and the banner lands) — so C2/C3's failure is NOT the alias mechanism and is most likely harness-side (`Marker-LandsIn` reads back through a SPLIT pane, and a split in the harness's `-WindowStyle Minimized` window can be ~1 column wide, which shreds the marker across lines; my own repro reproduced exactly that 1-char-per-line read). **DONE 2026-07-27 — all 4 failures were FABRICATED BY THE HARNESS, and the product was correct at every hop.** `Run-Cli` reaches ghoztty through `cmd.exe /c`, which expands `%VAR%` against the HARNESS's OWN environment before ghoztty ever sees the probe text: F4/F5 read back the poison the test itself had planted in its env (the "inherited id wins" symptom), and C1 falsely PASSED on the harness's own `$GHOSTTY_SURFACE_ID` so C2/C3 then targeted a pane that does not exist in the test app. Proven, not guessed: instrumenting the whole chain showed the bake, `config.env`, the forwarded `OPEN.env` and the agent's `child_env` all carried the pane's own id, while an OS-level discriminator (`GHOSTTY_BIN_DIR` = the INSTALLED path, not zig-out) showed the probe text had been substituted upstream — and `%VAR%` vs a shell-free spawn reproduced it in isolation. Fix is harness-side: `Probe-PaneEnv` clears the var from its own env for the send (an UNDEFINED var passes through cmd untouched). Also added **section G**, the end-to-end the row demanded: the REAL plugin hook script, run inside a pane, paints that pane's banner via `$GHOZTTY_PANE_ID` — which surfaced the outage's SECOND cause, outside this repo: the hook `exit 0`s on a missing tty BEFORE reading the var (fatal on Windows, where no pane has one) and needs `jq`, absent on this box. Both fixed on the box (plugin cache edit + winget jq); durability filed as **T130**. `pane-id.ps1` ALL PASS (45) ×3; both lanes + `test-agent` + P1–P3 green | K | T112 | done | b86dce1d0, (this commit) |
| T117 | Merge latest origin/main — done 2026-07-27: merged `1e1cdbbd2` (70 commits: viewer address bar/TOC/zoom/feedback, banner Liquid Glass refresh, agent-update "What's new", instance addressability, hero key navigator) into `users/dzearing/windows-amd64` by MERGE (this branch has never rebased — the task table cites commit hashes, which a rebase would invalidate). 6 conflicts, all one shape: main centralized CLI socket resolution into `apprt/ipc.zig` while this branch had already centralized it into the cross-platform `src/os/ipc_client.zig` — resolved to ours in `read/list/rearrange/new_remote_window.zig` + `apprt/none.zig` after verifying main's edit was ONLY that refactor; CLAUDE.md hand-merged (kept main's `+reload` section + banner persistence, re-inserted the Windows Ctrl+Shift+B chord note). 2 real post-merge build fixes: `Action.Key.wireName` was missing `.reload` (non-exhaustive switch — main added the enum member, this branch owns the switch) and `helpgen.zig` blew the 1000-branch comptime quota once the action list grew. Win32 Debug GUI build + both test lanes green. Parity gaps filed as T118–T128 | — | — | done | (this commit) |
| T118 | Instance addressability on Windows — main's `ab3c1e25d` bakes `$GHOZTTY_IPC_SOCKET` into every pane's env so an IPC command run inside a pane drives THAT pane's app instead of whatever `ghoztty` on `$PATH` resolves to; on Windows NEITHER half exists (grep: no `GHOZTTY_IPC_SOCKET` anywhere in `src/apprt/win32/` or `src/os/ipc_client.zig`). `ipc_client.endpointPath` derives the pipe name from build mode + `USERNAME` alone, so a `+split` run from a Debug pane silently drives the installed RELEASE app — the exact confusion class that burned T116, and unlike Mac there is no escape hatch. Fix: bake the resolved endpoint into the pane env on all three win32 spawn paths (plain exec, agent-backed OPEN incl. the agent's RELAUNCH replay, remote), and have `endpointPath` prefer it; keep `GHOZTTY_PIPE_SUFFIX` working for the harnesses. Note the Windows analog is a PIPE NAME, not a socket path — decide whether to reuse the documented `GHOZTTY_IPC_SOCKET` name (CLAUDE.md's "Instance addressability" says socket) or add a sibling, and write the choice down | K | T117 | todo | — |
| T119 | `+reload` verb unhandled on win32 — main's `2daaa98c9` added the action; the CLI/`apprt.ipc` plumbing came in free with T117 (and `wireName` now maps it), but `IpcHandlers.dispatch` has no `"reload"` branch, so the verb falls through to the unknown-action error rather than the documented "is a terminal pane, nothing to reload". Real behavior only lands with viewer panes (T90b–T90h), so the near-term deliverable is the parity ERROR string; wire the actual reload as part of T90e/T90f | K | T117 | todo | — |
| T120 | `--color=random` window tints are indistinguishable on Windows — `color_math.randomDark` uses HSB s `0.2–0.3` / b `0.1–0.15`, the exact ranges main replaced in `45f4f2250` because every window landed on the same near-black (brightest channel ~26–38/255, hue imperceptible). Fix: raise to s `0.33–0.46` / b `0.13–0.18` to match, and keep the doc comment's "IPCServer.randomDarkColor parity" claim true. Trivial, self-contained, has a unit-testable pure function already | K | T117 | todo | — |
| T121 | Auto `window-N` target names can DUPLICATE after a session restore — `IpcRegistry.nextWindowName` is a bare `window_counter += 1` that restarts at zero every app launch, while T89f session restore re-adopts window names minted by a PREVIOUS run. A restored `window-3` plus three fresh windows ⇒ two live windows holding one target name, and `+close`/`+split`/`+rename` route to whichever registered first. Main fixed the same defect in `565b77a58` by RESERVING adopted names (advance the allocator past any adopted `window-N`) and by checking live windows, not just the registry, before honoring a name. Port both halves; the reservation must also cover `GHOZTTY_WINDOW_NAME` inherited at spawn and explicit `+new-window --target=` | K | T117 | todo | — |
| T122 | Pane banners don't survive relaunch/re-attach on Windows — main's `5d5897936` added a `banner` field to the session-layout manifest so a restore brings banner text back across quit/relaunch/upgrade re-attach and agent RELAUNCH. win32's `session_layout.zig` has no banner field at all (grep: zero `banner` hits). Note the READ side is already at parity — `IpcHandlers.zig:1368` emits `banner` in `+list --json` — so this is purely manifest write + restore-apply. Additive manifest field, so it must degrade cleanly both ways per the CLAUDE.md agent-contract rules (older app reading a newer manifest and vice versa) | K | T117 | todo | — |
| T123 | Banner table columns use a FIXED 360pt cap on Windows — `BannerOverlay.MAX_CELL_W = 360.0` is the exact constant main replaced in `1d56c6948`+`c94a8158a`; CLAUDE.md (now merged) documents the post-fix contract: column widths derive from the pane's CURRENT width so the banner reflows live on resize and never blocks the pane from shrinking (even a long unbroken token breaks mid-string), and a cell is capped at 3 wrapped lines with a tail ellipsis so one nasty cell can't blow up banner height. Windows currently satisfies none of that, so the merged CLAUDE.md now over-promises for win32 — fix the code, don't weaken the doc | K | T117 | todo | — |
| T124 | Banner visual refresh parity (6 Mac commits, cosmetic) — `6778d22a0` Liquid Glass floating card + stable collapse geometry, `286078a2f`/`755af5c97` glass tinted off the pane background + elliptical sheen, `53e763c28` stable pane-hued card (dropped focus-reactive glassEffect), `088c44201` composite off a single pane-colored element, `ec0c62671`+`89465f320` instant collapse/expand with the terminal inset snapping once. win32's `BannerOverlay.zig` is a hand-painted GDI strip, so this is a deliberate REINTERPRETATION, not a port — Windows should look Windows-native (THE GOAL), so decide per-item what to adopt (the collapse/inset timing fixes are behavioral and worth taking; Liquid Glass is a macOS material with no native analog). Lowest priority of the T118–T128 band | K | T117 | todo | — |
| T125 | No agent-update dialog and no "What's new" on Windows — main added a whole feature (`981d18e29` ReleaseNotesStore, `1d7f809b3` WhatsNewTracking, `d28adcec1` WhatsNewNotesView, `f5c75454f`+`1f8f7c302` reframed agent-restart dialog copy, `1a236ecf7` scoping notes to agent-process changes, `047a80c47` bundling the notes JSON) that is entirely macOS Swift. On Windows `update_check.zig` covers only the APP-version check (T24, `win-v*` tags) and `LocalAgent.zig:264` states outright that "the listen-pipe agent never self-updates" — so the CLAUDE.md agent-contract's mandatory-update path (lazy non-destructive upgrade, else an explicit "upgrading will reset all windows" confirmation) has NO Windows implementation. That contract gap is the real risk here, well above the notes UI: file the notes viewer as nice-to-have, but treat the agent-upgrade confirmation as a correctness requirement. Note `release-notes/` JSON is repo-shared, so only the presentation + tracking need porting | K | T117 | todo | — |
| T126 | Hero-mode key navigation audit vs main's `HeroKeyNavigator` — `280f2449e` extracted navigation into a dedicated navigator because the Mac was navigating a STALE snapshot of the split tree and could act on a window other than the aimed-at one; `4eb13a651` then fixed an arrow-nav beep and a skipped pane. win32 has its own hero implementation (`HeroCarousel.zig` + `hero_math.zig`), so this is an audit, not a port: confirm win32 navigates the LIVE tree (it calls `heroOnTreeChanged` on rearrange, which is a good sign but not proof) and that arrow nav skips nothing. The viewer half of `1e0cf5484`/`4eb13a651` is moot until T90 lands viewer panes | K | T117 | todo | — |
| T127 | T90b–T90h viewer scope has GROWN — the T90a design (2026-07-19) predates 16 main viewer commits that added capabilities its task split never accounted for: navigable address bar + sliding/omnibox completion + `file://` display (`13b950e77`, `6af1fc12a`, `25c454b24`), native + in-page markdown TOC (`2137da95a`, `3691cc4e8`, `2af9a6e95`), browser-style zoom (`dc5daa4c5`), popups-as-windows (`0b8335d7c`), quote-from-page toolbar + screenshot key (`1cf83764b`, `2f0b286ba`), worktree-aware feedback capture (`4cf88905d`, `1edce34c7`, `efe1e1d17`, `bd5667887`), copy/paste + browser-like focus (`a7fc890a9`), Cmd-R/Cmd-D pane-scoped keys (`14d22875a`), and `+reload` (T119). Do NOT silently widen T90b–T90h: re-scope them against the current Mac viewer FIRST (a T90a refresh), decide explicitly what Windows v1 ships vs defers, and record the deferrals as rows so they stay visible. Much of the JS (`src/viewer/*.js`, incl. the new `selection.js`) is shared and came in free with T117 — it is the WebView2 host side that has to catch up | K | T117,T90a | todo | — |
| T128 | INVESTIGATE: does `+rearrange` dropping a pane LEAK its agent session? — main's `e65cfa4d5` fixed the mirror-image bug on Mac (a tree SWAP marked every departed leaf CLOSE-on-free, so in-place recovery killed the very sessions it recovered) and hardened it into an invariant: a session still referenced by the new tree is never marked CLOSE-on-free. win32 does NOT infer intent from tree departure — `setSessionCloseIntent(true)` is called only at explicit user-close sites (`Window.zig:979/1083/3515`) — so win32 is structurally immune to main's bug. But the `+rearrange` handler swaps trees and destroys panes absent from the new layout via refcount, with no close-intent set, which suggests the OPPOSITE defect: a dropped pane DETACHes and its agent session lingers forever instead of ending. Unverified — confirm with `+sessions` before/after a `+rearrange` that drops a pane; if it leaks, set the intent on exactly the dropped leaves (and only those, so recovery-style swaps stay safe) | K | T117 | todo | — |
| T129 | Banner editor is UNDISCOVERABLE on Windows — reported by the user 2026-07-27 as "ctrl-r doesn't rename them". Working as designed: `Config.zig:7005` deliberately binds the editor to **ctrl+shift+b** on Windows because plain ctrl+r is the shell's reverse-history-search and ctrl+shift+r is the cross-platform rename. The defect is that nothing in the app SAYS so. The win32 context menu (`context_menu.zig`) offers "Change Tab Title..." and "Change Pane Title..." but has no "Set Pane Banner..." entry, where Mac exposes it in both the menu and the command palette — so a user who knows the Mac chord has no in-app path to the Windows one and concludes the feature is broken. Fix: add "Set Pane Banner..." to the win32 context menu (and the command palette if it has an entry list), with the ctrl+shift+b accelerator shown in the item text so the chord is self-teaching. Cheap, and it converts a "feature is broken" report into a discovered feature | K | T117 | done | eb3c3044f — row added + EVERY bound row now labeled "Title\tChord" from the live keybind set (palette already had the entry + a hint); `context-menu.ps1` ALL PASS (31) ×3 |
| T131 | **Banner overlay: terminal content scrolls BEHIND it, and the overlay is a flat band where Mac now draws a rounded, shadowed card.** User-reported live 2026-07-28 on the delivered `+eb3c3044f` build: "i see the text scrolling behind the banner. in the mac version we have changed this to not scroll behind, and for the banner to have more of a rounded overlay with shadow appearance." T101 reserved a strip band above the terminal drawable, so either that reservation is not holding in the current build (regressed by a later layout path, or the band is computed from a stale/short height when the banner wraps or grows) or it never covered the scroll path — **measure before fixing**; the failing case is scrolling content, not a static frame. Then port the Mac's *current* banner appearance: rounded corners + drop shadow (the `GlassCardBackground` card look), not the flat full-width strip win32 draws now. Both halves are user-visible parity against Mac's current state. **DONE 2026-07-28: one fix for both halves.** Measured first: T101's reservation IS holding (terminal HWND top == banner bottom, on the user's own live pane), so no glyph is ever laid out under the banner — what leaked was the overlay's WINDOW alpha (`WS_EX_LAYERED` SLWA 242), which composited the stale terminal pixels still sitting in the vacated band THROUGH the strip (a capture of the user's pane shows `v2.1.220` bleeding through it). Fix: new pure `banner_card.zig` — the port of `GlassCard`/`GlassCardBackground` — composites the whole card against the pane background (rounded-rect SDF for antialiased corners, a smoothstep of the same SDF for the shadow; GDI has neither), so the window is now fully OPAQUE and the see-through is structurally impossible. Mac's numbers: 12px uniform margin, 14px radius, white@6% wash (black@4% on light, as an alpha composite — NOT `color_math`'s HSB lift), specular sheen + hairline rim, black@30% blur 8 offset 4. `banner_layout.bandHeight` puts the margin on both sides so the terminal starts a breath under the card | K | T101 | done | 732dabac9 — `pane-banner.ps1` ALL PASS (45) ×3 (was 34) incl. the new card oracles: band corner reads the pane bg EXACTLY, composited screen pixel == own-DC pixel (opacity proof), interior is the white@6% wash, shadow darkens under the card; both lanes + test-agent + P1–P3 green. **DELIVERED to all 3 install locations** (portable + share swapped directly, installed release via the detached upgrade script) and **VERIFIED by the resumed session**: upgrade log clean (exe + agent swapped, share mirrored, `RELAUNCH-CWD OK`), the running instance reports `commit: 179804307`, and this session's OWN banner renders as the card. Capture note for the next probe: `PrintWindow` right after a relaunch returned a card with NO content — a WM_PRINT/DWM-surface artifact on a layered window, NOT the product; a raise-then-`CopyFromScreen` of the same overlay shows every row |
| T132 | **`--working-directory` lost on the auto-launch path (the loop-killer)** — done 2026-07-28. The filed repro was NOT the defect: on the pre-fix build the requested pane already came up in `<dir>`; the panes in `C:\Windows\System32` were the ones session RESTORE brought back. Two real causes, both proven on the box: (1) `handleOpen` never recorded `OPEN.cwd`, so `s.cwd` was null for every session ever opened (all 37 in the debug agent's `sessions.json` had no `cwd`) and `handleRelaunch` respawned with a null cwd — a session outliving its agent (reboot, or the upgrade script swapping `ghoztty-agent.exe`) landed in the AGENT's cwd; shared code, so Mac has it too; (2) `autoLaunchInstance` passed `lpCurrentDirectory=null`, so the auto-launched GUI — and the startup window, `inherit` panes, and the agent it spawns — inherited the CLI's cwd, which for a detached launcher is System32. Fixed with `Session.setCwd` + record at OPEN, and a pure `args.autoLaunchDirectory` (last-wins; `inherit`/`home`/empty → null) passed as the spawn's cwd. `auto-launch-cwd.ps1` ALL PASS (21) ×3; **negative control run**: both fixes neutralized + rebuilt ⇒ B3/B4/C4/C5/C6 fail, every one reporting `c:\windows\system32` (the user's symptom verbatim) while A passes in both builds | K | — | done | (this commit) |
| T133 | **Make the `/reset-context` composer-wipe fix durable** (same class as T130, different plugin — `dzearing-skills`, not `ghoztty`). 2026-07-28 the reset failed a second way: the helper typed `/clear` correctly (`rc=0` in `/tmp/reset-context-last.log`) but two stray characters were already in the composer, so the submit sent **`nn/clear` as an ordinary message** — no clear, context kept growing, loop stalled again. This is the loop's own continuation mechanism failing twice in one session (see T132 for the first), so it is worth hardening rather than retrying. Fixed in the ACTIVE cache (`~/.claude/plugins/cache/dzearing-claude-marketplace/dzearing-skills/0.10.2/skills/reset-context/scripts/reset-context.sh`): send `C-u --when-idle` to kill the input line before typing `/clear`. Like T130, a plugin update silently reverts it — mirror into the `dzearing-skills` source repo + bump. While there, consider having the helper VERIFY the clear landed (read the pane and check the banner/greeting) and log LOUDLY if not, the same lesson T132 applied to the upgrade script: a continuation that silently no-ops is what makes these cost hours | K | — | todo | — |
| T134 | **Mac seat: carry the T132 agent fix across.** `handleOpen` never recording `OPEN.cwd` (fixed 2026-07-28 in `src/remote/agent/server.zig`) is SHARED code, so macOS has the same defect: a session's working directory is never persisted to `sessions.json` and `handleRelaunch` respawns with a null cwd, landing the child in the agent's cwd. The symptom is milder on Mac — the per-user LaunchAgent has a stable cwd rather than whatever a detached launcher was sitting in — but a session relaunched after a reboot or an agent upgrade still comes back in the wrong directory, and `+sessions` reports no working directory for any session (CLAUDE.md documents it as "the working directory (when known)"). The fix is already on this branch and needs a Mac-side regression run + the merge to main (same channel as T87). Validation: the two `test-agent` cases added with T132 (`OPEN records cwd → sessions.json carries it`, `RELAUNCH respawns in the RECORDED cwd`) are OS-agnostic and should pass on macOS unchanged; on-box, `+sessions` should start reporting a cwd | K | T132 | todo | — |
| T135 | **`+new-window --target=<name>` silently discards `--working-directory`/`--command` when the target already exists.** Found 2026-07-28 while root-causing T132. The idempotent rule ("a named target that already exists is focused, not recreated") is Mac-parity and correct as a rule, but combined with session restore it makes the loop's own relaunch a no-op: `upgrade-ghoztty-windows.ps1` calls `+new-window --target=main --working-directory=… --command="claude … --continue"`, and if restore has already rebuilt a window named `main` (the manifest persists `ipc_name`), the request just focuses it and the command never runs — the pane keeps whatever the tombstone RELAUNCH respawned. T132 makes that respawn land in the right directory, so the loop now survives, but a caller still gets `success:true` for a request that did nothing it asked for. Decide and implement one of: (a) apply the flags to the existing target (re-`cd`/re-run is not generally safe), (b) report a distinct outcome (`focused` vs `created`) in the JSON reply so callers can branch, or (c) an explicit `--recreate`/`--fail-if-exists` flag. Check what Mac does with the same request before diverging. Validation: an on-box case in `auto-launch-cwd.ps1` (or its own script) asserting the chosen contract for an already-registered target | K | T132 | todo | — |
| T136 | **`zig build test-agent` flaked once: `remote.agent.server.test "RESIZE and SIGNAL are recorded on the child"` exited with code 3** (expected 0), 2026-07-28 during T131's floor run; the identical re-run was green, and both app lanes were green in the same session. Not T97 (that was `ssh-cache.DiskCache`/`renameatW`, and `ZIG_GLOBAL_CACHE_DIR` was set correctly here). Exit code 3 from a test child is a PANIC, not an assertion failure, so this is a real crash in the agent's RESIZE/SIGNAL recording path that a re-run hides — the agent floor is a standing gate for every task, so a flake here silently costs a rebuild every time it hits. Investigate: run that one test in a loop (`--test-filter "RESIZE and SIGNAL"`) until it reproduces, then read the panic. Suspects are the child-process teardown race the T89b work touched (`PtyChild` teardown) and a use-after-free of the recorded child handle when the test's child exits before the SIGNAL is recorded. Validation: the filtered test green ×100, then `test-agent` green ×3 | K | — | todo | — |
| T137 | **`--session-persistence=off` is silently rejected on the CLI** (doc/impl mismatch). CLAUDE.md and the tracker both document the setting as `session-persistence = off\|on`, but the config bool parser takes `true`/`false` only: `ghoztty --session-persistence=off` produces a config error that is swallowed at startup and the default `true` stays in force — the app restores the previous layout anyway. Found 2026-07-28 in T131 (the pane-banner harness used `=off`, saw restore happen regardless, and only worked once switched to `=false`). A user following the documented spelling gets the opposite of what they asked for, silently, which is the worst failure mode for a persistence switch. Decide and implement one of: (a) accept `on`/`off` (and `yes`/`no`) in the bool parser — check what Mac's parser accepts first, since config syntax is shared, (b) keep the parser and fix every doc to say `true`/`false`. Either way a bad config VALUE for a known key should surface (startup config-error dialog, like `config-errors.ps1` covers) rather than being swallowed. Validation: extend `config-errors.ps1` with the rejected-value case + whichever spelling is chosen | K | — | todo | — |
| T130 | Ghoztty Claude-Code plugin: make the Windows banner-hook fixes DURABLE (they currently live only in this box's active plugin cache, `~/.claude/plugins/cache/dzearing-claude-marketplace/ghoztty/0.7.0/hooks/ghoztty-banner.sh`, and a plugin update would silently revert them and re-break the user's banners). Two edits to mirror into the source repo `github.com/dzearing/ghoztty-claude-plugin` (not cloned on this box) + a version bump: (a) the tty gate — `TTY_NAME=$(find_tty) || exit 0` bailed BEFORE `$GHOZTTY_PANE_ID` was ever read, which is fatal on Windows where no pane has a tty, now `|| TTY_NAME=""` with a both-routes-gone bail, a pane-id-keyed state file, and an OSC fallback that no-ops without a tty; (b) `jq` is a hard dependency (`command -v jq || exit 0`) and was ABSENT on this box until this task installed it (winget `jqlang.jq`, user scope) — a Windows user without jq gets the same silent no-op, so either vendor/relax the dependency or make the plugin say why it is inert. Also carries the item-19(a) `# ` banner-title mirror | K | T113 | todo | — |

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
