# Windows parity — session log

History only. **Do not read this file as part of normal resume** —
`windows-parity-tasks.md` (state table + task sections) is the hot doc.
Open a single entry here only when you need the backstory for a specific
task (why a decision was made, what a past validation actually proved).


Append newest-first: `YYYY-MM-DD — <tasks touched> — <what happened, what's
next, any surprises>`.

- 2026-08-02 - **T29 done - the Mac action fallthroughs are real, and they are
  an inherited UPSTREAM defect, not the bad merge the task guessed.** `git log
  -L` on the region names it: upstream `38e64c370` implemented
  `SHOW_CHILD_EXITED` by replacing the body the five cases SHARED - the
  `known but unimplemented ... return false` one - and left the four preceding
  `fallthrough`s attached to the new call. The chain looks deliberate because
  it was, for the body it used to have.
  - **The severity is not in the wrong case, it is in the C union.** Every arm
    reads `action.action` as a different member; the four that fell through are
    **void-payload** actions, and `Action.cval`'s `@unionInit` leaves the rest
    of the extern union UNDEFINED. So `toggle_window_decorations` read
    `child_exited.timetime_ms` out of garbage and could pop a "process exited"
    bar over a live surface. `size_limit` - emitted on every surface init -
    escaped only by luck: its `max_width/max_height` overlay `timetime_ms`, and
    they are 0, so the `> 0` guard rejected it. That is why nobody noticed.
  - **Win32 cannot have this bug**, which is worth stating as more than a
    status: it switches on a Zig tagged union, so the compiler binds each arm's
    payload to its tag. The defect class exists only across the C boundary.
  - **The Mac half of the validation was NOT run and is not claimed** - this box
    has no Swift toolchain, so the fix rests on a code read plus the
    archaeology. Filed as **T340** (Mac seat: build + keybind-verify) rather
    than left implied. **T341** is the root enabler: make `cval` zero the
    union's bytes so the next wrong reader gets a defined zero, testable in the
    none lane here.
  - Floor green: none lane, `test-agent`, P1-P3 ALL PASS. The win32 lane failed
    once on **T258** (`client DATA reaches the child`, len 0 vs `ls -la\n`) and
    was green on the identical re-run; recorded there as its third occurrence -
    a third distinct assertion, same file, same "bytes had not arrived" shape.

- 2026-08-02 - **T336 done - cross-machine Restore All, which closes T146.**
  Rebuilding a REMOTE machine's whole topology here is T335's machinery pointed
  at a dialed connection, so what the task was really about is the one
  structural difference: **a win32 window OWNS its transport**. One dial per
  window, plus one for the pull - a shared connection would die with whichever
  rebuilt window the user closed first. `RestoreTransport` makes that a value
  (connection + local_agent + the dial the window takes + machine identity +
  the reanchor bit), so no caller can set the connection and forget the
  ownership.
  - **The double-attach guard stayed, against the task's own prediction.** Mac
    drops it cross-machine because its ids come from the local manifest; ours
    are read off live panes, so it keeps working over the relay - and without it
    a second press would tear apart the windows the first press built. It needed
    SCOPING, not deleting: a session id means nothing without its machine.
  - **T319's fixture could not test this, for a product reason.** Only an APP
    pushing to ITS OWN local agent creates a layout blob (T334), so a bare
    `--listen` agent holds none and a correct implementation returns zero
    against it - a test that passes while proving nothing. The only machine here
    an app has lived on is this box, whose agent speaks a NAMED PIPE, so
    `test/win32/lib/PipeBridge.ps1` fronts it on TCP and the relay bridges to
    that. Deleting `port.json` afterwards is what makes it honest: the Local row
    can then only fail, so everything the app saw, it saw through the relay.
  - Also: frames authored on the far machine's monitors are re-clamped onto a
    visible local one (`restore_frame.zig`, 9 unit tests); `FakeRelay` gained
    `-TripUnauthorizedFile` because a permanently-401 device can never load the
    roster a gated button needs; CLAUDE.md's "Restore All is local only on
    Windows" is retired.
  - Filed **T339**: the N+1 dials run on the GUI thread (Mac dials off it) -
    invisible on loopback, ~2 s of frozen app for 6 windows on a real relay.
  - Validation: `chooser-restore-all-remote.ps1` ALL PASS (32) twice; both test
    lanes, `test-agent`, the GUI Debug link, P1-P3, and the four chooser/layout
    scripts green. `session-reattach` is 2 red - both the pre-existing T223
    focus-churn assertions the script labels as such.

- 2026-08-01 - **T312 done** (T227's last split; chooser finding 10). The
  owner-drawn machine list draws three states now instead of one:
  `chooser_rows.rowPaint` resolves fill/border/ring together and `drawRow`
  reads `ODS_FOCUS` alongside `ODS_SELECTED`. The rim REPLACES the pill's
  outline rather than nesting inside it, and `focus_path_inset` carries the
  pen's half-width so §2.2's "inset 1 DIP" is where it says it is instead of
  hanging over the pill's edge.
  - **The acceptance script had been measuring a state it never named.** The
    chooser opens with focus in the FILTER, so `selected row is accent-tinted`
    was a probe of the *unfocused* selection all along - invisible while there
    was only one state, and a failure against a correct build the moment there
    were two. Both halves are asserted now, each in the state it belongs to
    (8 new assertions; 72 ALL PASS, negative control still 2 FAILURE(S)).
  - Filed **T317**: the win32 test lane segfaulted once in
    `terminal.PageList` (`page.verifyIntegrity` -> `hash_map.get`) and passed
    on an immediate re-run of the same tree. Same shape as T258 one lane over,
    and the same cost - it teaches turns to re-run a floor lane until green.
  - Floor: both test lanes, the full win32 GUI Debug link, `test-agent`,
    P1-P3 - all green on the box.

- 2026-07-31 - **T217 batch 3** (10 of 23): `confirm-dialogs`, `config-errors`,
  `remote-inherit` migrated onto the background test desktop. The two dialog
  scripts are ALL PASS x3 (27 and 15 assertions) with FAILING negative
  controls; `remote-inherit` is migrated but stays RED on **T178** (3
  identical failures x3, all downstream of section 3's missing
  `t68-split-marker`) - a product bug, not a harness one, and its gate.
  - **A batch-2 assertion was vacuous and is fixed.** `Remove-TestDesktop`
    empties the live pid list as it kills processes, and the foreground-leak
    assertion runs *after* the `finally` that calls it - so `command-registry`
    and `window-title` were asserting "no test-desktop app ever became
    foreground" against an EMPTY list. It could not have failed. The harness
    now keeps a separate never-cleared list behind `Get-TestLaunchedPids`;
    both scripts re-run green with the assertion actually scoring something.
    (Batch 1's scripts were never affected - they snapshot inside the try.)
  - `config-errors` printed its failure count and **exited 0**, so a red run
    scored as green to any exit-code-reading driver. It exits 1 now.
  - T178 gains measured evidence rather than the old guesses: the app logs
    `surface child exited exit_code=0 runtime=6ms wait_after_command=true`
    and the pane holds only the exit notice, so the command IS forwarded and
    DOES run - what goes missing is its OUTPUT. That rules out two of the
    three filed hypotheses and points at the attach/replay seam for a
    short-lived remote command. Its old fourth red (`new tab pane appeared`)
    now passes: the harness lands ctrl+t where the foreground grab used to
    race.
  - **T183 reproduced on the win32 lane** (it was filed as a none-lane flake):
    same `session_meta ... FileNotFound` then `panic: attempt to use null
    value`, this time with the line pinned (`fc.last_resize.?`,
    server.zig:3480), triggered by running the floor lanes while acceptance
    scripts ran - the normal thing to do on this box. Solo re-run green.
  - `split-dim` is **blocked on T214**, not merely pending: it probes the
    terminal surface's own pixels, which PrintWindow returns as a flat fill.
    Recorded in T217 so a later batch does not "migrate" it into an assertion
    that passes against nothing.
  - Next: T217 batch 4 (13 remain, `split-dim` excluded).

- 2026-07-30 (later still) - **T200 DONE**, and a correction to the entry below.
  **The T196 delivery to the installed release never ran.** The previous turn
  launched `upgrade-ghoztty-windows.ps1` detached at the boundary, reported it as
  "upgrading now", and ended. 45 minutes later the log had no new line and the
  installed app/agent pids were unchanged; the T139 watchdog was the only thing
  that noticed. Fixed the mechanism first (the T112/T187 precedent) and then
  completed the delivery through it.
  - Root cause, measured with a negative control: `Start-Process -ArgumentList
    @(...)` does NOT quote its elements, so a multi-word `-ResumePrompt` is
    re-tokenized by the child's parser. With a bare `-` in the text (an empty
    parameter name) binding died BEFORE line 1 - nothing logged, and the hidden
    detached child's stderr went nowhere. Without the hyphen it was worse: the
    bind "succeeded" and assigned prose to three parameters at once
    (`$Staging='Verify'`, `$ResumeCommand='It'`, `$LoopPaneId='did'`). It aborted
    only by luck, on a staging dir that happened not to exist.
  - Three layers, because any one alone still leaves a silent path:
    `PositionalBinding=$false` (a bare `[CmdletBinding()]` was NOT enough - every
    `[string]` param is positional, so a stray word still landed in
    `$InstallDir` and ran), `-ResumePromptFile` so free text never touches argv,
    and new `scripts/launch-upgrade.ps1` which gates success on the upgrade
    script's own first log line rather than on `Start-Process` returning.
  - New section **L** in `upgrade-no-fork.ps1` (31 assertions), **ALL PASS x3**.
    It caught five real defects in the fix itself, including a launcher that
    declared every HEALTHY launch a failure (it regex-escaped its marker and then
    searched with `-SimpleMatch`, hunting for `===\ upgrade\ start`) and a test
    that was itself pushing free text through argv - the disease reproducing
    inside its own cure, which is what forced the in-process `-Prompt` /
    command-line `-PromptFile` split now documented in `go.md`.
  - The permanent oracle is L1/L2: the exact prompt that killed the real
    delivery, still failing, still logging nothing. No care with argv can fix it;
    only the file can.

- 2026-07-30 (later) - **T196 DONE** (delivery of T145 + T147 to all 3 install
  locations; no product code changed). Floor re-run at HEAD `9968a62d9`: both
  lanes + `test-agent` exit 0, P1-P3 ALL PASS. ReleaseFast gnu `-Dstrip=false`
  staged to `zig-out-release`; Desktop portable and the share's extracted copy
  swapped (6 binaries + `share\`, previous kept as `.bak-20260730-t196`), the
  share's loose agent refreshed, the zip rebuilt; the installed release via the
  detached upgrade script at the boundary.
  - Both delivered copies were RUN, not just copied - each `+version` reports
    `+9968a62d9`. Copying is not evidence that the thing you copied works.
  - The box was already IN the T147 scenario, so this delivery is a field test
    of it: the installed agent (pid 27568) had been serving since **2026-07-29
    17:21** across four same-day binary swaps, with **4 live attached sessions**
    including the loop's own pane. `decide(..., live=4)` therefore owes the
    mandatory confirmation dialog, not a silent refresh - and `ConfirmDialog`
    was read first to confirm its modal loop still pumps IPC, so the dialog
    cannot wedge the resume. The right answer for this box is "Later";
    confirming would relaunch the pane running the loop.
  - The hand-built zip exited 0 and was wrong twice (rooted at
    `Ghoztty-portable-x64\Ghoztty\...` instead of `Ghoztty\...`, and carrying
    both pdbs - 41.9 MB vs 20.3 MB). Caught only by diffing its entries against
    the artifact it replaced. Filed **T198** (script + PROVE the delivery, since
    the copy loop was never the hard part) and **T199** (a harness left a GUI
    ghoztty running out of `%TEMP%\gh-dbg2\install` for 19 hours).
  - Next: **T146** per priority 3f (the session chooser; likely needs a split).

- 2026-07-28 - LOOP POST-MORTEM (the loop stalled 7h20m; root cause found) +
  new rows T131/T132 + the 99.9%-parity bar recorded. The turn ended at
  06:36:05Z with a summary and NO /reset-context, on the assumption that the
  upgrade script's relaunch would carry the loop. It did not, and the transcript
  proves it: no prompt reached any session in this project between 06:36:05Z and
  the user's 13:56Z message. Read the relaunched pane to find out why instead of
  theorizing -- it is sitting at Claude Code's "Is this a project you trust?"
  prompt with `Accessing workspace: C:\Windows\System32`. So `+new-window
  --target=main --working-directory=D:\git\ghoztty --command="claude … --continue"`
  auto-launched the app (the pipe owner died with the kill) and the pane landed
  in the LAUNCHER's cwd, not the requested one; `--continue` then had no session
  to resume and Claude blocked on a prompt nobody was there to answer. Filed as
  **T132** (product bug), and the script now (a) sets its own cwd and (b) VERIFIES
  the landed `working_directory`, logging RELAUNCH-CWD OK/FAIL -- a wrong-cwd
  relaunch was indistinguishable from a healthy one from the log, which is why it
  cost hours instead of seconds. go.md gained a "THE TURN" section (the user's
  own words for the loop) stating that ending a turn without the reset is a
  failure, not a pause. Also filed **T131** from a live user report: terminal
  content scrolls BEHIND the banner overlay, and Mac has since moved the banner
  to a rounded, shadowed card. Recorded the standing bar: parity is measured
  against Mac's CURRENT state, at a 99.9% validated confidence level.

- 2026-07-27 (latest) - T113 delivery VERIFIED + T129 DONE. Verified the T113
  delivery from this session's own pane, which is the real-world test the row
  asked for: upgrade log shows the exe + agent swap and the correct resume
  command, `+list --json` reports the running build as `+43aa8b972`, the pane
  exports `$GHOZTTY_PANE_ID`, and the plugin banner hook set this pane's banner
  (read back out of the `banner` field). T129 then closed the other half of the
  user's report: the ctrl+shift+b chord was correct but unnamed, so the win32
  context menu (Windows' only menu surface) gained a "Set Pane Banner..." row,
  and every bound row is now labeled `Title\tChord` from the LIVE keybind set --
  `context_menu.action(id)` moved the id->action map into the pure model so the
  label and the dispatch read the same source. Run 4 of the script rebinds the
  action and asserts the label follows, which is what proves it isn't
  hardcoded. `context-menu.ps1` ALL PASS (31) x3; both lanes + test-agent +
  P1-P3 + pane-banner (42) green. DELIVERED to all 3 install locations
  (user-facing discoverability fix): ReleaseFast gnu `-Dstrip=false` staged to
  `zig-out-release`, portable + share swapped, installed release via the
  detached upgrade script at the boundary. Next: T130 (make the plugin-side
  banner-hook fixes durable -- they live only in this box's plugin cache), then
  T38/T39.

- 2026-07-27 (later still) - T113 IN-PROGRESS, first validation run: 4 failures
  of ~35, and the core is green. A/B/D/E all pass, which is the hard half --
  ids are real UUIDs, distinct per pane, resolve with no prior registration,
  and survive BOTH an app-quit re-attach and an agent-restart RELAUNCH with
  the respawned shell baked with the same id.

  C2/C3 (legacy 0x/decimal surface-id aliases) are probably a HARNESS defect,
  not a product one. Hand-verified on a hermetic exec instance that both
  spellings resolve and land a banner (exit 0, banner readable back). The
  harness asserts them through Marker-LandsIn, which echoes into a SPLIT pane
  and reads it back -- and a split inside the harness's -WindowStyle Minimized
  window can be about ONE COLUMN wide. My own repro hit exactly that: +read
  returned the prompt one character per line. That would shred the marker.
  Do not "fix" the product for C2/C3 before re-running with a real window.

  F4/F5 is the real remaining work: a launcher that already carries
  GHOZTTY_PANE_ID poisons the panes it opens -- the inherited value wins over
  the pane's own. The bake itself is fine (unconditional, applied after the
  IPC overrides), so the fault is downstream in how config.env reaches the
  child: exec env_override ordering, or the agent OPEN env. Note the harness
  comment at section C already flags a sibling of this for GHOSTTY_SURFACE_ID
  on agent panes and blames T117 -- worth checking whether that is the same
  defect wearing two hats.

  Stopped here deliberately per the go.md context rule rather than pushing on:
  this context had already absorbed a 70-commit merge, a full parity audit,
  and a user-reported outage diagnosis.

- 2026-07-27 (later) - T129 filed, T113 priority raised, loop found DEAD. The
  user surfaced two banner complaints and both were worth having.

  "ctrl-r doesn't rename them" is a NON-BUG: Windows deliberately binds the
  banner editor to ctrl+shift+b (Config.zig:7005 - plain ctrl+r is the shell's
  reverse-history search). But the win32 context menu has no "Set Pane
  Banner..." entry where Mac does, so there is no in-app way to learn the
  chord and the feature reads as broken. Filed as T129.

  "the plugin hooks that update the banner aren't working" root-caused to
  T113, on the box. The plugin's resolve_pane tries $GHOZTTY_PANE_ID, then a
  cached name validated against /dev/$TTY_NAME, then +list --tty. All three
  fail on Windows: the var is unset, and an agent-backed pane reports "not a
  tty" so both fallbacks get an empty tty. The hook swallows its own errors,
  so it fails invisibly. This reframes T113 from a contract nicety to a live
  outage and finally gives it an end-to-end validation a user would feel.

  Also found: the loop has NO supervisor. No scheduled task, and the only
  HKCU Run entry is GhozttyAgent. It self-perpetuates only via /reset-context
  per task, so any turn that ends without a reset kills it silently. It died
  after 2026-07-21 14:33 (upgrade log resume arg intact, so not the known
  resume-arg-drop failure) and sat cold 6 days until the user noticed. A
  watchdog does not exist and probably should.

- 2026-07-27 - T117 DONE (merge origin/main 1e1cdbbd2, 70 commits), T118-T128
  filed. Merged rather than rebased: the branch was 203 ahead / 70 behind, has
  synced by merge every previous time, and the task table cites commit hashes a
  rebase would invalidate. User chose merge after seeing both options.

  Five of the six conflicts were one story: main centralized CLI socket
  resolution into `apprt/ipc.zig` while this branch had already centralized the
  same thing into the cross-platform `os/ipc_client.zig` (Windows needs named
  pipes). Verified main's edit to each CLI file was ONLY that refactor before
  keeping ours, so nothing was dropped except a duplicate — the one genuinely
  new capability in main's version is instance addressability, filed as T118
  instead of being silently lost. CLAUDE.md hand-merged.

  Three build breaks, none of which existed on either side alone. (1)
  `Action.Key.wireName` is a switch this branch owns and main added a `.reload`
  member to the enum it switches over — exhaustive-switch failure from the
  combination. (2) `helpgen.zig` blew the 1000-branch comptime quota once the
  action list grew. (3) The one worth remembering: main's new `socketPathFrom`
  calls `std.c.getuid()`, so the `none` lane failed to LINK on Windows
  (`undefined symbol: getuid`) — main cannot see this, and it will keep
  happening every time main adds POSIX-shaped code to a shared file. Fixed by
  making the resolver actually correct on Windows (derive branch delegates to
  `ipc_client.endpointPath`, the pipe name the win32 CLI really dials) rather
  than ifdef-ing the symbol away.

  Gap triage: classified all 70 commits by `src/` (shared, arrives free) vs
  `macos/`-only (needs a Windows answer). ~60% are macOS-only. Highest-value
  finds are NOT the big visible features: T118 (a CLI run inside a Debug pane
  silently drives the installed RELEASE app — the T116 confusion class, with no
  per-pane escape hatch on Windows) and T125's second half (CLAUDE.md mandates
  an explicit "upgrading will reset all windows" confirmation on an
  incompatible agent skew; Windows implements neither that nor the lazy
  non-destructive upgrade, and the win32 agent already outlives the app, so the
  skew is reachable today). T120/T121/T123 are cheap ports of fixes main just
  made to code Windows still carries in its pre-fix form. T128 is an
  investigation, not a bug: win32 is structurally immune to the Mac's
  recovery-kills-sessions bug, which suggests it may have the mirror defect
  (`+rearrange` dropping a pane may leak its session) — unverified, needs
  `+sessions` before/after on the box.

  Deliberately did NOT widen T90b-T90h to absorb 16 new viewer commits; that
  re-scoping is T127 so the growth stays visible. Validation: win32 Debug GUI
  build + both test lanes. Next: T113 is still `todo` with WIP committed
  (b86dce1d0) and unvalidated.

- 2026-07-21 (on-box, 53) - T115 + T114 DONE, one fix. Picked T115; its own
  row and details said "do T114 first and re-measure", and measurement said
  they were the same defect, so both closed together.

  The filed T115 theory (Remote-side analog of T63: a hung IO reader) was
  REFUTED by the first measurement. New `closeperf` telemetry splits
  `Surface.deinit` into backend-shutdown / renderer-join / io-join:
  `renderer_join=33257ms io_join=4049ms`. The IO teardown the row blamed was
  11%. The renderer thread takes the pane's renderer mutex once per frame in
  `updateFrame` and that is where it notices its stop, so starving it blocks
  the GUI's join for exactly as long -- its own long-standing telemetry read
  `slow state mutex acquire ms=65392`. `+read` was starving on the same mutex
  (lockwait 23628ms for 45ms of work). One producer, two victims.

  Fix: fairness ticket on `renderer.State` (`priority_waiters` +
  `lockPriority`/`yieldToPriorityWaiters`). Waiters announce themselves and
  clear the ticket ON ACQUISITION; the Remote drain keeps the mutex FREE
  between slices until the waiter is in. T111b's bare `std.Thread.yield()` was
  not enough because SwitchToThread only yields to a same-core runnable thread
  -- a hint, not a handoff. Priority waiters: renderer `updateFrame`,
  `+read`, `isWin32InputMode`. Plus `drainRing` bails once `io.closing` is
  set (finishing a wake parses up to 32x16 KiB into a terminal about to be
  freed: io_join 4049ms -> 38ms).

  A unit test earned its keep: the first implementation bounded the handoff by
  SPIN COUNT, and 512 SwitchToThread calls elapse in microseconds -- the test
  failed, and the shipped bound is a duration (2ms). Only the box would have
  found that otherwise, and only sometimes.

  Validation: `session-persistence.ps1` ALL PASS x3, the first fully green run
  of that script (E4 223/175/207ms, E11 154/172/199ms, E12 139/248/140ms, E2
  40/40 x3). Both lanes + test-agent + P1-P3 green; the none lane flaked once
  on an agent PTY round-trip test and passed on re-run (recorded as a flake).

  Surprise worth more than it cost: `ipc-under-load.ps1` failed its T111b
  accept-pool guard deterministically with the exact pre-fix signature. Not a
  regression -- the script's default -ExePath was `zig-out-release`, a day-old
  staging build that predated the pool. A direct probe proved the pool healthy
  on the build under test (3 hogs fine, exhausted at 4, no leak after 40
  requests). Default repointed at `zig-out\bin` + a staleness warning. The T49
  stale-binary lesson, recurring inside a standing "must stay ALL PASS"
  script.

  Next: the held delivery (T110 + T111a/b + T114/T115) to all 3 install
  locations, then T113.

- 2026-07-21 (on-box, 52) — T111b DONE. Both of the row's filed hypotheses
  were WRONG, and the instrumentation added this session is the only reason
  that is known: splitting the IPC round trip into accept/read/queue/handler
  showed a `+list` handler at 29347ms with queue 0ms, and — the decisive
  one — E4's `+read` produced NO handler log line at all, so its 9202ms was
  never a read latency; the request never reached the app. An isolation
  experiment then reproduced T111's exact string and latency on a
  completely IDLE app: hold the server's single pipe instance with a raw
  client and every `ghoztty +list` fails after 9190ms with "No running
  Ghoztty instance found." Two layers, both fixed: a 4-instance accept pool
  (a slow handler can no longer make a running app look absent) and a
  per-pane pwd cache fed by the `.pwd` action win32 had been ACKing and
  dropping. Two things the cache got wrong before it was right, both caught
  by measurement, not review: seeding lazily charged the lock to whichever
  `+list` saw a pane first (19155ms handler), and skipping the seed when a
  pane has no pwd at all — which is every `+split` without a working
  directory — meant the miss repeated forever (68312ms handler). Seeding
  eagerly at surface creation, negatives included, took `+list` worst from
  29347ms to 141ms with handler=0ms. E2 7/40 → 40/40; E3/E5/E10 green.
  ALSO: the harness had been fabricating evidence — `Run-Cli` killed only
  cmd.exe on timeout, the orphaned CLI child kept the redirect file open,
  and every later probe died at ~35ms with exit 1 and no output, so 2 real
  timeouts were recorded as 26 failures with a stale successful list left
  in the artifact file. Fixed with `taskkill /F /T`; earlier T111 evidence
  should be re-read with that in mind. Section E is still red on E4 and
  E11/E12, now split out as T114 (`+read` loses ~190 consecutive lock races;
  the yield added here moved it 15514ms → 1439ms, enough to prove the
  mechanism, not enough to hold the 2s bound) and T115 (`+close` handler
  64883ms on the GUI thread — a cost that ALWAYS existed and that T111b
  unmasked by removing the accidental throttle; E11 was 7.2s before and is
  30.2s now, and saying so is the point). Next on-box: T115, then T114.

- 2026-07-21 (on-box, 51) — T112 DONE (jumped the queue ahead of T111b:
  it is the loop's own continuation mechanism, and it is an out-of-repo
  skill edit, so it was cheap). Root cause confirmed, not assumed —
  `+list --json` reports `"pid":0` for every leaf, so the `--pid` ancestry
  walk answers "IPC request failed". The prescribed fix did not survive
  contact: **`$GHOZTTY_PANE_ID` does not exist on win32** (Swift-side
  concept; the core only exports `GHOSTTY_SURFACE_ID` +
  `GHOZTTY_WINDOW_NAME`/`GHOZTTY_PANE_NAME`, and in this pane PANE_NAME held
  the *window* name — the exact trap the skill's old note warned about).
  Shipped a 3-step chain instead: pane id → `GHOSTTY_SURFACE_ID` as unsigned
  decimal (== the registered leaf name; the `0x` hex form is rejected) → the
  legacy `--pid`/`--tty` walk, each candidate probed with a cheap `+read` so
  a wrong value falls through rather than clearing someone else's pane.
  Correction to the row's premise: the marketplace source repo **is** on this
  box (`D:\git\dzearing-claude-marketplace`, a `directory` marketplace) — it
  was 11 commits behind, so fast-forwarded first, then edited; pushed b9a1082,
  plugin 0.10.1→0.10.2, cache byte-identical. Filed **T113** (win32 should
  export `GHOZTTY_PANE_ID` per CLAUDE.md's documented contract, which would
  demote T112's fallback from load-bearing to belt-and-braces). No product
  code touched, so no build/lane runs; the reset at this boundary is the
  end-to-end validation. Next: **T111b** (unchanged, publish blocker).

- 2026-07-21 (on-box, 49) — T89i DELIVERED, left blocked(T111):
  new `test/win32/session-persistence.ps1` ports the py harness (scenario +
  crash-kill re-attach ×3 + winsize) and adds flood-during-reattach gap-fill
  and a bounded persistence-on soak. It immediately earned its keep: found
  **T110** — split ratios were NEVER persisted (`markLayoutDirty` fired on
  every topology/title/color/frame change but on NO ratio change), so every
  restore came back 50/50; fixed at all four ratio-mutation sites.
  `session-reattach.ps1` B5 had missed it for two tasks because it only
  asserts the ratio is *in range* — 0.5 passes. Also found **T111**, which
  is why this task is `blocked` and not `done`: the GUI went Windows-"Not
  Responding" under the double agent-backed storm with an unanswered
  `+list` (the user saw it live and interrupted). It looked intermittent —
  the same section was 40/40 the run before — but once E2 was
  timeout-guarded it reproduced hard: **`+list` 1/40**, and the CLI's own
  error is `No running Ghoztty instance found.`, i.e. the GUI-thread pipe
  listener stops ACCEPTING, not merely answering slowly. Section E's bar is
  precedented (`ipc-under-load.ps1` holds the same 40/40 under the same
  storm on the Exec path), so those asserts stay red as a real signal
  rather than being relaxed to make the task look finished. T111 is the
  next task and is a publish blocker: persistence is default-on, so every
  local pane rides the starved path. Two self-inflicted lessons, both after
  that wedge left storm panes spamming the user's live desktop: guard EVERY
  CLI call in a flood section with the timeout-guarded `Run-Cli` (an
  unguarded one hangs the whole run instead of recording a failed probe),
  and make storms bounded + minimized. Third lesson, cheaper: a PS 5.1
  unary comma on return PLUS `@()` at the call site NESTS the array, so
  `.Count` reads 1 — that alone faked 28 failures on the first run. Fourth,
  and it closes an open question T89h left for this task: the "transient
  exit=-1" on the test lanes is NOT a flake — piping a build into
  `Select-Object -First N` stops the pipeline and tears down the running
  `zig build`, so it exits -1 with no failure text. Redirect to a file and
  filter the FILE; both lanes + test-agent are green that way. `go.md` now
  says so. Delivery to the 3 install locations is deliberately HELD: T110
  is user-visible and should ship, but not in a release that still carries
  T111's freeze on the same subsystem — deliver both together when T111
  lands. The boundary reset itself then FAILED and became **T112**:
  `+list --pid` returns "IPC request failed" from inside a pane because
  persistence is default-on, so every pane's shell is a child of the
  agent, not the GUI, and the ancestry walk can't match (panes list as
  `pid:0`); `$GHOZTTY_PANE_ID` is unset too. `/reset-context` resolves its
  own pane exactly that way, so the loop can no longer clear its own
  context — the very failure mode go.md was written to prevent. Cleared by
  hand this time. Next:
  **T111** (ahead of T38 — a GUI freeze on the default path outranks
  release packaging).
- 2026-07-20 (on-box, 48) — loop repair after the T106 delivery: the 16:10
  upgrade's resume never produced a live claude (loop stalled; user
  noticed) and its agent swap failed on a .bak that is the RUNNING
  agent's mapped image (undeletable, renameable). Fixed the script
  (delete-else-dated-rename fallback), manually installed the staging
  agent (4:06 PM build) alongside the already-swapped app exe, relaunched
  the loop in the installed Ghoztty with a fresh session. T105+T106 are
  both live in all install locations; running agent stays on its old
  binary until next cold start (lazy upgrade, by design).
- 2026-07-20 (on-box, 47) — T106 DONE (visible relaunch lost re-attached
  scrollback). Root cause was NOT the suspected repaint race: byte dumps
  proved visible/minimized relaunches feed IDENTICAL streams; the loss was
  parse geometry (raw ring replay is geometry-bound VT; at the restored
  window's transient grid the recorded scrolls never fire, so conhost's
  post-attach ESC[2J erases everything). Fix: additive
  `Attached.replay_rows/cols` (agent reports pre-attach geometry) + client
  replay-at-capture-geometry with reflow-to-live exactly at
  `snapshot_at_offset`, + `captureFrame` uses rcNormalPosition for iconic
  windows (manifest recorded the −32000 stub). session-reattach F5 flipped
  to VISIBLE (real-world style; F8 was the RED oracle) ALL PASS ×3; lanes +
  test-agent ×3 + P1–P3 + session-relaunch/open/close green. Filed T109
  (mixed-geometry ring → WP-D3 persisted snapshots endgame). Next per
  item-20 queue: T89i.
- 2026-07-20 (on-box, 46) — T105 DONE (restore focus ping-pong live-lock,
  user-hit on the delivered release; an earlier session left the fix
  uncommitted — this session validated + landed it). T89h delivery
  verified in ghoztty-upgrade.log (12:25: exe+agent swapped, share
  mirrored, correct resume). Fix: foreground-guarded deferred focus
  (`App.performDeferredFocus`, both pump loops). session-reattach.ps1 grew
  a VISIBLE-relaunch cycle: F10 (early-grab + 3s flip sampling) + F11
  (seeded co-pending 0x8005 asserts); baseline-proven RED (33–44 flips/3s
  pre-fix) → ALL PASS ×3 post-fix (0 flips). Standing bar green (win32
  lane + test-agent each showed the known transient silent -1 once, green
  on rerun ×3). Surprises → new tasks: T106 (visible relaunch loses
  replayed scrollback — real-world path, harness only passed because F5
  relaunches minimized) + T107 (focus-defer tail reds pre-existing).
  Delivery to all 3 install locations launched at boundary. Next per
  item-20 queue: T106 → T89i.
- 2026-07-20 (on-box, 45) — T89h DONE (session-persistence ships): HKCU
  Run autostart (`GhozttyAgent[-debug]`, exact spawn command via shared
  `agentCommandLine`, release-gated w/ force hook), agent exe now a
  required sibling in default build + MSI (File-table version-lie to dodge
  the T23 vanish rule) + publish script, upgrade script never kills the
  agent + rename-swaps its exe + SESSIONS-SURVIVE log assert, docs
  un-gated to macOS+Windows. New agent-autostart.ps1 ALL PASS ×3 (incl.
  reboot proxy: verbatim Run command via Win32_Process.Create → session
  back as tombstone); msi-upgrade (35) incl. agent asserts; standing bar
  green. Surprise: test-agent flaked exit=-1 ×3 early (no failure text,
  gone across 5 logged runs — watch in T89i soak); msi-upgrade's
  -V2ProductVer default encodes the DATE (pass current, e.g. 26.7.2002).
  Delivery launched at boundary (first time the installed release gets an
  agent at all). Next: T89i; resumed session checks ghoztty-upgrade.log.
- 2026-07-20 (on-box, 44) — T100 DONE (native-msvc GUI-subsystem link,
  the T89h delivery blocker). Root cause pinned against zig 0.15.2
  std/start.zig: MSVC libc + `pub fn main` exports only C `main`, and the
  Windows subsystem makes lld-link enter via libcmt's WinMainCRTStartup →
  undefined WinMain. Fix: explicit `mainCRTStartup` entry (subsystem stays
  GUI) via new `src/build/win32_entry.zig`, wired into agent + app
  release; gnu path untouched. Agent builds+runs (agent-pipe ×3),
  ReleaseFast msvc app links again, standing bar green. One stale pre-fix
  debug agent (held the zig-out exe lock) had to be killed. Next: T89h.

- 2026-07-20 (on-box, 43) — T101 DONE (banner occlusion; user live-review
  item b). Key discovery: the filed root cause (sizeCallback full height)
  was WRONG in a load-bearing way — the win32 renderer re-reads the HWND
  client rect every frame (`OpenGL.surfaceSize`) and resets glViewport
  from it, so lying to sizeCallback would only blank the pane BOTTOM. The
  correct fix is Mac-VStack-parity at the HWND level: all 3 surface
  positioning paths (layoutNode / zoomed / layoutHero) reserve the strip
  band via new pure `banner_layout.clampInset` (unit tests both lanes) +
  `Surface.bannerLayoutInset`; the overlay glues INTO the vacated band;
  set/clear/collapse/DPI all relayout (new `App.relayoutOwnerWindow` for
  the collapse toggle, GWLP_USERDATA-guarded). Grid size, GL viewport,
  and mouse coords follow the real client rect for free. pane-banner.ps1
  matcher now REQUIRES strip-bottom == live pane top + 5 new band asserts
  (top shift == strip height, bottom unchanged, clear/collapse give the
  band back, split-slot band); stable ×3. Surprise: 4 failures during
  validation turned out ALL PRE-EXISTING (proven by git-stash baseline
  rebuild: identical failures, incl. BOTH pixel-read oracles returning
  pane bg and the ctrl+shift+b chord swallowed = T95 wedge signature) →
  filed T103 instead of chasing box state. Lanes + test-agent + P1–P3
  green. Next: T102 (right-click context menu), then the item-20 publish
  queue (T100 → T89h → …).
- 2026-07-20 (on-box, 42) — T89g DONE (tombstone RELAUNCH floor). The
  materialize → ATTACH(dead+relaunchable) → RELAUNCH → ring-replay + divider
  machinery is entirely OS-agnostic (agent `session`/`server`/`ring_snapshot` +
  `termio/Remote`, no win32 branches). The ONE win32 gap: `restoreSessionLayout`
  built its attach set from `sess.alive` only, so a relaunchable tombstone was
  treated as dead → the leaf nulled its `session_id` and OPENed a fresh shell.
  Fix: propagate the wire `relaunchable` field into `connection.OwnedSession`
  (already on `protocol.SessionInfo`; agent `server.zig:1182` sets it) and
  forward any **alive-or-relaunchable** id to ATTACH (`attach_set`, `alive`→
  `attach` rename across the 5 restore helpers). termio then fires RELAUNCH per
  `session-relaunch` (`.auto` immediately, `.prompt` on first keystroke). New
  `session-relaunch.ps1` ALL PASS (19) ×3: kills BOTH app+agent (real reboot
  path), a fresh agent re-materializes sessions.json → tombstones; A(auto) same
  id RELAUNCHed + `--- session restarted ---` divider + pre-kill ring scrollback
  precedes it; B(prompt) live tombstone + press-any-key affordance → keystroke
  → deferred relaunch. Both lanes + test-agent + P1–P3 green. Surprises:
  (1) em-dashes in the .ps1 mojibaked under PS5.1's ANSI read (the known trap) —
  rewrote pure-ASCII; (2) A11 needed `+read --lines=2000` — the fresh shell's
  restart banner wraps into many rows in the ultra-narrow minimized pane,
  pushing the replayed marker past a 200-row window. Next on-box: T89h, gated on
  T100 (build the agent exe via the gnu target). **User live-review (on-box)
  filed T101** (banner overlay occludes terminal content — handleResize passes
  full height, no top inset) + **T102** (right-click pastes instead of a
  Mac-parity context menu) + a ghoztty-skill fix (banner title needs `#`);
  banner heading SIZE was a non-bug (user's title lacked `#`; heading sizing
  already matches Mac and pane-banner.ps1's heading-taller assert passes).
- 2026-07-20 (on-box, 41) — T89f2 DONE (launch restore + ATTACH). Session
  re-attach now closes: `App.restoreSessionLayout` (run first in `run()`) loads
  the T89f1 manifest, find-or-spawns the local agent, probes `LIST_SESSIONS`
  liveness (tri-state — drop a window only when every session-backed leaf is
  positively dead; unknown/probe-fail attempts ATTACH; no agent ⇒ blank window),
  and rebuilds each window/tab/split by replaying `newSplitAt` over the flat node
  array. NEW `Overrides.Remote.session_id` + `Surface.remote_session_id` thread
  the leaf id through `remoteBackend()` (was hardcoded null) → core ATTACH; blank
  startup window suppressed when ≥1 window restores. Presentation reapplied
  (title pin, tab color, hero ratio, active tab, frame/maximized) + pane IPC
  names re-registered. `session-reattach.ps1` grew §F (kill app only → relaunch →
  2 windows/3 panes, SAME 3 sessions ATTACHed not re-OPENed, scrollback + IPC
  name + title pin back), ALL PASS ×3; both lanes + test-agent + P1–P3 green.
  Surprises: (1) narrow minimized panes wrap the scrollback marker per-glyph —
  used the T99 whitespace-stripped match; (2) F9 flaked on `Wait-Manifest`
  racing the atomic rewrite — a direct re-read poll is race-robust; (3) filed
  **T100** — `zig build agent` EXE fails to link on the box (WinMain/subsystem,
  pre-existing since my diff is app-only), blocks T89h delivery. Windows PID
  identity proven via session-id reuse + survives-kill (T98 bogus local pid).
  Next on-box: T89g (tombstone relaunch floor). T96 folds with the close path.
- 2026-07-20 (on-box, 40) — T89f split + T89f1 DONE. T89f (same-PID re-attach
  restore) was too big for one context, so it was split into T89f1 (manifest +
  capture/debounced-atomic-write) and T89f2 (launch restore + ATTACH + suppress
  blank window); implemented f1 this session. New pure `session_layout.zig`
  (flat-node schema mirroring `SplitTree.nodes`, snake_case JSON, atomic write,
  `%LOCALAPPDATA%` path, both-lane unit tests) + an `App` capture walk (window
  frame/maximized, tab order/color/hero-ratio/title-pin, split tree + per-leaf
  session_id/title/ipc-name; excludes remote + quick-terminal windows) + a 250ms
  WM_TIMER debounce armed from every layout/title/color/frame/reorder mutation +
  a bounded pending-sid retry (agent-backed panes publish the session id AFTER
  the async OPEN, so the first capture misses it; retry ≤40×400ms, Mac
  `syncAndCaptureSessionIDs` analog) + a synchronous flush on `terminate()` and
  `WM_ENDSESSION`. Two surprises during validation, both script-side (the
  capture code was correct from the first manual manifest dump): PowerShell
  unwraps a 1-element array to a scalar (so `Leaf-Sids`'s single sid indexed as a
  char — fixed with a unary-comma return), and `$x = if(c){@(pipe)}else{@()}`
  did NOT capture the array (fixed by assigning the pipeline directly). The
  next-most-useful finding: startup-only (no mutation) now lands the session_id
  in the manifest within ~2s thanks to the retry — the case a user who opens and
  immediately reboots depends on. `session-reattach.ps1` (write half) ALL PASS
  ×3; both test lanes (none 3038 / win32 3106) + `test-agent` 6267 + P1–P3 green.
  Next on-box: T89f2 (thread `session_id` through `Overrides.Remote` →
  `remoteBackend()` → core ATTACH, positive-dead probe, suppress blank window,
  grow the script's restore/same-PID half).

- 2026-07-20 (on-box, 39) — T99 DONE: IPC-created surfaces are now agent-backed
  on a local persistence window. `+new-window` (first pane), its inline
  `--split`, and `+split` each gained a `local_agent_conn` branch mirroring the
  cross-machine `remote_dialed` one: no explicit cmd/cwd ⇒ null baton so
  `buildRemoteInherit` injects the local agent (splits inherit the parent's cwd
  via GET_CWD); else a `.remote{local_agent=true}` override carrying the
  agent-native command + the window/pane-name env. The unblocker was
  `App.createWindow`'s `is_remote` guard, which now excludes a `local_agent`
  override so a `+new-window`'s window still gets `local_agent_conn` and its
  later tabs/splits inherit the same agent. `session-open.ps1` grew section D
  (+split → 2 sessions, +new-window → 3, split typing round-trips, `+list` pid 0)
  and `session-close.ps1` grew section D (close ONE pane of a 2-pane window ⇒
  only that session ends, sibling survives — the scenario T99 unblocks). One
  harness fix: `Test-Typing` strips whitespace before matching, because a split
  inside a MINIMIZED test window has a ~0 client rect and wraps output one glyph
  per line (a test-window artifact — the agent session/echo/stream are all
  live). Both ALL PASS ×3; both lanes + test-agent + P1–P3 green. Two inserted
  sections needed a leading `Stop-TestProcs` (a prior section's leftover
  GUI/agent holds the per-user IPC pipe + single-instance guard). Left open
  (pre-existing): T98 (agent pane pid reads as a system pid). Next on-box: T89f
  (same-PID re-attach restore), which these agent-backed splits were blocking.
- 2026-07-20 (on-box, 38) — T89e DONE: close-vs-quit session semantics. Wired
  the core's `close_on_exit` (Remote backend's CLOSE-vs-DETACH atomic, reached
  via new win32 `Surface.setSessionCloseIntent`) into the user-close paths:
  `closeSplitSurface` marks the removed leaf, `closeTabByIndex` the whole tab,
  `Window.close` all tabs (new `markAllSessionsClose`) — all BEFORE the deinit
  that frees the surfaces and reads the flag, so `+close`/X/Alt+F4/close_window
  END the agent session. `Window.deinit` (the `.quit`→PostQuitMessage→terminate
  teardown) deliberately does NOT mark, and new WM_QUERYENDSESSION/WM_ENDSESSION
  handlers allow logoff without a CLOSE, so app-exit paths DETACH (sessions
  survive, re-attach next launch). Palette "Quit" → "Quit Ghoztty (keep
  sessions)" when persistence on. Confirm carve-out was a no-op: win32 quit has
  no dialog (so "quit never scares" already holds), and the close-confirm is now
  ACCURATE since closing truly ends the session. `session-close.ps1` ALL PASS
  (9) ×3 — A: `+close` pane ⇒ 0 alive; B: `+close` window ⇒ 0 alive; C: hard-
  kill GUI ⇒ session survives alive+detached. Both lanes + test-agent + P1–P3
  green. SURPRISE that became **T99**: IPC-created windows/tabs/splits aren't
  agent-backed — only the STARTUP window is. `+new-window`/`+split` panes report
  real pids + add no `+sessions` row because the IPC override baton (env/name
  vars, non-null even with no command) suppresses `buildRemoteInherit`'s local-
  agent injection in `addTab`/`newSplitAt` (the `remote_dialed` branch handles
  cross-machine, but no `local_agent_conn` branch exists). T89d-lineage gap;
  forced `session-close.ps1` onto the single startup session. Next on-box: T99
  (then T89f re-attach, which needs agent-backed IPC surfaces).
- 2026-07-20 (on-box, 37) — T89d DONE: win32 surfaces open under the local
  session-persistence agent. New `LocalAgent.zig` find-or-spawn (dial
  port.json{pipe} → CreateProcessW DETACHED spawn → 2s-bounded poll; 15s
  failure cooldown; exec fallback; `GHOSTTY_LOCAL_AGENT_BIN` override), owned by
  `App.local_agent`; `createWindow` injects the shared conn into non-remote
  windows when `session-persistence` is on. Reused the existing seams: one flag
  (`Overrides.Remote.local_agent` → `remoteBackend().local_shell_integration`)
  turns on the core's whole local-agent contract (shell-integration + GHOSTTY_*
  env + `pinned`), and `buildRemoteInherit` (the T68 cross-machine inheritance
  path) now also carries the local agent so the initial surface + every
  tab/split inherit it from ONE choke point — almost no new surface/core code.
  Agent clears the inherited ignore-^C flag at init (T84, one layer down: the
  agent is spawned with CREATE_NEW_PROCESS_GROUP). Two surprises during
  validation: (1) the STARTUP window was built inline in `App.run`, bypassing
  the `createWindow` injection — routed it through `createWindow` (first run
  caught this: agent never spawned). (2) the `+sessions` pid for a local ConPTY
  session reads as a system pid (428 "Secure System") — ConPTY reparents the
  child, so I dropped the pid-ancestry assertion for the STRONGER
  survives-app-quit proof (kill the GUI, the agent still lists the session
  alive+detached) and filed T98 for the bogus pid. `session-open.ps1` ALL PASS
  (18) ×3; P1–P3 (persistence ON, default) + both lanes + test-agent ×3 green.
  Next: T89e (close-vs-quit; folds with T96's production pty-teardown fix).
- 2026-07-20 (on-box, 36) — T97 DONE (test-agent floor un-flaked). Picked
  T97 over the queued T89d because a flaky agent floor reds every task's
  "test-agent green ×3" bar, including T89d's own validation — worth clearing
  first. Fix (a): `DiskCache.writeCacheFile` flushes then `renameWithRetry`,
  retrying `renameIntoPlace` on `error.AccessDenied` (Windows only,
  1/2/4/8/16ms backoff) so an AV/indexer racing the atomic rename no longer
  drops the write; new "repeated rewrites replace atomically" test. Surprise:
  the failure that *looked* like T97 in my fresh shell was actually the
  cross-drive cache panic (`convertPathArg` assert) — my Bash shell lacked
  `ZIG_GLOBAL_CACHE_DIR`; test-agent was already green once the env var was
  set. So T97 is a genuine flake (Defender timing), now hardened, not a hard
  fail. Validation: test-agent green ×3, `-Dtest-filter="disk cache"` green,
  both app lanes green. Not delivered to install locations (test-floor
  robustness, not a user-facing feature). Next: T89d.
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

## 2026-07-20 — T102: Mac-parity right-click context menu

Root-caused the user's "right-click pastes": Claude Code enables mouse
reporting (SetConsoleMode → conhost emits DECSET outward), the core
consumes the press and reports it — Claude Code pastes. Mac-identical
semantics; the menu itself existed since Jul 5. Fixed the real gaps: menu
grown to full Mac parity via pure `context_menu.zig` (+ unit tests, both
lanes), mouse mods now from wparam MK_ bits (makes the Mac shift+right-click
reporting bypass reliable + automatable), WM_CONTEXTMENU/VK_APPS keyboard
path. Default stays context-menu; `right-click-action=paste` is the WT-style
opt-in. New `context-menu.ps1` ALL PASS (19) ×3 — fully PostMessage-driven,
so it runs clean under the GameInputSvc SendInput wedge (which was active
all session; sudo disabled, service restart unavailable). Lanes +
test-agent ×3 + P1–P3 green. Cleaned probe debris (debug agent store +
session-layout-debug.json). Notable: raw `?1002h` from a ConPTY child does
NOT propagate outward — only console-API mouse mode does; CLI bools reject
`on/off`.

## 2026-07-20 — delivery: T101+T102 to all 3 install locations

Built HEAD (7653b1590) ReleaseFast staging via the T100 gnu-target
workaround. Desktop portable + share copy refreshed via the established
.bak rename-swap (running windows keep old code until relaunched);
installed release swapped via the detached upgrade script (kill/swap/
resume, default -ResumeCommand). Next task: T100 (agent exe), then T89h
per the item-20 publish queue.

## 2026-07-21 — T111 split: T111a (drain hold-time bound) landed, T111b open

Measured the agent-path IPC starvation instead of trusting the filed prime
suspect — and the suspect was wrong. Boundary instrumentation showed the
`+list` stall is `queue 0ms + handler 1.4-5.5s`, inside the handler it is
`pwd()` (title/pid 0ms) on the pane's renderer mutex, and drain telemetry
read `lockwait=0%` with 16 KiB chunks: the drain HOLDS the mutex ~330ms per
call, it never waits for it. The 256 KiB inbound ring coalesces the stream to
4x what a ConPTY read ever returns, so the fix is to slice DOWN to ~4 KiB —
the opposite of T62's batching, which the T111 row had proposed and which
would have made it strictly worse.

T111a: `feedSliced` + pure `SliceIter` (4 unit tests, canary-verified to
actually run). Same storm A/B: `+list` worst 5504ms -> 767ms vs an Exec
baseline of 709ms, so the agent path is no longer worse than the path it
replaced. Harness: E2 1/40 -> 15/40, E10 4.2s -> 630ms; A-D + E1 + E6-E12
PASS. Both lanes + test-agent + build green.

T111b (next, publish blocker): E2/E3/E4/E5 still red. `+read` at 9.2s with
~80ms holds means ~100 consecutive lost races (barging), and E5 fails on a
QUIET pane whose mutex is free — so something global is also in play (agent
write path, or serialization behind the single-instance IPC pipe). Both
hypotheses are UNPROVEN and written down as such; instrument first. A ready
win is cached pwd via the `.pwd` apprt action win32 currently drops, which
takes `+list` off the contended path entirely.

Split per go.md's sizing rule: one context could not carry both mechanisms.
Not delivered to install locations — T110 and T111a both ride with the T111b
fix so the release does not ship a half-fixed freeze on the default path.

## 2026-07-27 — T113 done: the product was right, the harness was lying

The 4 failures the previous session left (C2/C3, F4/F5) were all one harness
bug: `Run-Cli` goes through `cmd /c`, so `%VAR%` in a probe was expanded against
the HARNESS's own env before ghoztty saw it. F4/F5 read back the poison the test
itself had planted; C2/C3 targeted the harness's own surface id. Instrumenting
every hop (bake → config.env → OPEN.env → the agent's child_env) showed the id
correct throughout, and `GHOSTTY_BIN_DIR` coming back as the INSTALLED path —
a value neither side could produce — pinned it on the probe text. Probe now
clears the var for the send.

New section G runs the REAL plugin hook inside a pane, and it earned its keep
immediately: the app fix alone would NOT have restored the user's banners. The
hook `exit 0`s on a missing tty before it ever reads `$GHOZTTY_PANE_ID` (no
Windows pane has a tty), and `jq` — a hard dependency — was not installed on
this box. Both fixed on the box; durability filed as T130 since they live only
in the plugin cache.

pane-id.ps1 ALL PASS (45) ×3; both lanes + test-agent + P1–P3 green.

DELIVERED to all 3 install locations (this one is user-facing — the installed
release was still the 2026-07-21 build, so the user's panes had no
`$GHOZTTY_PANE_ID` at all and their banners could not work no matter what the
plugin did): ReleaseFast gnu `-Dstrip=false` staged to `zig-out-release`
(`+version` = `+43aa8b972`); Desktop portable + `\\homeassistant\share` swapped
with `.bak-20260727-t113`; installed release via the detached upgrade script at
the task boundary (default `-ResumeCommand`, so its relaunch is also this
task's context reset). Note this delivery also ships the whole T117 merge of
origin/main to the user's build for the first time.

**Resumed session: verify the delivery, in this order** — (1) `%TEMP%\ghoztty-
upgrade.log` for the exe + agent swap lines; (2) `$GHOZTTY_PANE_ID` is set in
your own pane (it is a NEW pane of the NEW build, so it must be); (3) the
banner hooks actually fire now — that is the user's original report, and the
resumed session is the real-world test of it. Next: T129 (banner editor
discoverability), then T130 (make the plugin fixes durable), then T38/T39.

## 2026-07-28 — T132 done: the filed repro was not the defect

Took T132 (the loop-killer). Measured before fixing, and the row's own
validation passed on the PRE-fix build: with no instance running,
`+new-window --working-directory=<dir>` from `C:\Windows\System32` produced a
pane correctly in `<dir>` (reported *and* asked of the shell). The panes sitting
in System32 were the ones session RESTORE had brought back — a different
mechanism entirely.

Two real defects, both proven on the box:

1. `handleOpen` never recorded `OPEN.cwd`. `session_meta.Record` has always had
   the field and `handleRelaunch` has always read it, but nothing ever set it —
   all 37 sessions in the debug agent's `sessions.json` had no `cwd` key. Any
   session outliving its agent (reboot, or the upgrade script swapping
   `ghoztty-agent.exe`) relaunched with a null cwd and inherited the AGENT's.
   Shared code: Mac has this too, just with a milder symptom.
2. `autoLaunchInstance` spawned the GUI with `lpCurrentDirectory = null`, so the
   new instance — and its startup window, its `inherit` panes, and the agent it
   spawns — inherited the CLI's cwd. A detached launcher sits in System32, which
   is exactly where defect 1 then dumped the relaunched panes.

Fix: `Session.setCwd` + record at OPEN; pure `args.autoLaunchDirectory`
(last-wins, `inherit`/`home`/empty → null) passed as the spawn's working
directory.

New `test/win32/auto-launch-cwd.ps1` ALL PASS (21) ×3. **Negative control run
before believing it:** both fixes neutralized in place and the binary rebuilt →
B3/B4/C4/C5/C6 fail, every one reporting `c:\windows\system32`, the user's
symptom verbatim; section A passes in BOTH builds, which is the evidence that
the row's stated repro never touched the defect. Unit tests in the none lane
(`autoLaunchDirectory` sentinels/empty/prefix-lookalike/last-wins) and in
test-agent (OPEN records cwd → sessions.json; RELAUNCH respawns in the recorded
cwd, via a new `FakeSpawner.lastCwd`).

Mid-task the box rebooted unexpectedly and corrupted the repo-local
`.zig-cache` (build-runner panic, not a code error); cleared it and rebuilt
cold. Filed **T134** for the Mac seat to carry defect 1 across.

## 2026-07-28 — T131: the banner is a floating glass card, and it is opaque

The user's two complaints ("text scrolling behind the banner", "Mac has moved
to a rounded overlay with a shadow") were one defect. Measured first, on the
user's own live pane: T101's band reservation is intact — the terminal HWND
starts exactly at the banner's bottom edge — so nothing is ever laid out under
the banner. What leaked was the overlay's WINDOW alpha (`WS_EX_LAYERED`, SLWA
242): the terminal's stale pixels, still sitting in the band the layout
vacated, composited through the strip. A capture of the user's pane shows
`v2.1.220` legible through it.

Fix: new pure `banner_card.zig`, the port of Mac's `GlassCard` /
`GlassCardBackground`. A rounded-rect SDF gives antialiased corners and a
smoothstep of the same SDF gives the elevation shadow (GDI has neither), and
the whole card is composited against the pane background there — so the window
is now fully opaque and the see-through is structurally impossible. Mac's
numbers: 12px uniform margin, 14px radius, white@6% wash (black@4% on light,
as an alpha composite, not `color_math`'s HSB lift), sheen + hairline rim,
black@30% blur 8 offset 4.

`pane-banner.ps1` ALL PASS (45) ×3, up from 34. It also closed **T103**: those
four "box state" failures since 2026-07-20 were the layered alpha itself — the
composited pixel now equals the own-DC pixel, and the ctrl+shift+b chord passes
with no wedge.

The harness had a bug worth more than the assert count: it only ever passed on
its FIRST run. Session restore handed it back its own previous `bw` window,
split and all, and `+new-window --target=bw` idempotently focuses an existing
target — so every later run banner'd the restored split's focused pane and read
pane 0 empty (19 identical failures, deterministic). Now launched with
`--session-persistence=false`.

Filed **T136** (a `test-agent` panic-flake in `RESIZE and SIGNAL are recorded
on the child`, green on re-run — a standing gate should not flake) and **T137**
(`--session-persistence=off` is silently rejected on the CLI although the docs
spell it that way; only `=false` parses).

Delivery verified by the resumed session: upgrade log clean, running instance
at `commit: 179804307`, and this session's own pane renders the card. One trap
for the next pixel probe — `PrintWindow` on the banner overlay right after a
relaunch came back as a card with NO content, which looked exactly like a
regression; it is a WM_PRINT/DWM-surface artifact on a layered window (we
handle WM_PAINT, not WM_PRINTCLIENT). Raise the window and `CopyFromScreen`
instead: every row is there.

## 2026-07-29 — the loop had forked, and then stopped

The user came back to two windows both running `go.md`, both stopped. State,
measured rather than assumed:

- **Two sessions.** `claude` pid 16076 (08:01) and pid 644 (09:46:40). The
  09:46 one is the upgrade script's relaunch; the 08:01 one is the session the
  upgrade was supposed to have killed. It survived because the agent owns its
  PTY and the script deliberately never kills the agent — so the relaunched app
  re-attached it while the script also started a fresh `--continue` session.
  Both then resumed the same transcript and worked T131. Filed **T138**.
- **No repo damage:** tree clean, in sync with origin, and the duplicate never
  committed — the three T131 commits are all from this session.
- **Why it stopped:** both sessions ended their turn with a written report
  instead of `/reset-context`. That is the documented loop-killer (go.md step
  7) and it is now the second and third time it has happened. Filed **T139**
  for the single-instance guard the user asked for plus the watchdog `go.md`
  admits does not exist.
- **Banner overlap was mine, not the product's.** T131's `raiseshot.ps1` probe
  set `HWND_TOPMOST` on both banner overlays to beat occlusion and never
  restored it, so background windows' banners floated over foreground windows
  for the rest of the day. Clearing the bit fixed it. The product still cannot
  self-heal from it (`updatePosition` uses `SWP_NOZORDER`) — filed **T142**.

Two parity gaps the user surfaced by hand, both ahead of the old queue:
**T141** (`+relay-login`/`+relay-logout` exist only on Windows — the Mac client
never had them, and the chooser advertises one; delete and audit the CLI for
other one-platform verbs) and **T140** (the Ctrl+Shift+N chooser is a bare
Win32 dialog with a clipped footer, nowhere near Mac's).

45 rows remain open. Nothing about this effort is finished.

## 2026-07-29 - T139 done: the loop now has a lock and a supervisor

Both halves of the user's ask landed. `go.md` gained a **step 0** that takes a
lock (`scripts/go-loop-lock.ps1`) before a task is even picked: a session in a
different pane gets exit 3, names the owner, and stops. Ownership is keyed on
the PANE rather than the pid on purpose - `/reset-context` keeps both, but the
upgrade script kills claude and relaunches it in the same pane, and that is the
same loop slot, not a rival. A dead owner or a heartbeat older than 30 min is
taken over, so the lock cannot introduce the failure it is preventing.

The second half is `scripts/go-loop-watchdog.ps1` - the supervisor `go.md`
flatly said did not exist. It watches the heartbeat and, only while tracker
rows remain, re-enters with the cheapest fitting action: nudge a live-but-
stalled session, restart claude in a surviving pane, or open a window. A pane
still emitting output is mid-task and is left alone (measured with two `+read`
samples, not assumed). It is installed and running on the box via an HKCU Run
entry - the scheduled task was the first choice and `schtasks /SC ONLOGON`
returned *Access is denied* without elevation.

`go-loop-guard.ps1` ALL PASS (58) x3. Sections I and J are real end-to-end
against a live debug GUI, not simulations: the watchdog's window really runs
the resume shim (marker read back out of the pane), and the nudge really lands
as typed text in a stalled pane with no second window opened.

Two things this turn surfaced. `+list --pid=` fails on every pane on this box -
agent-backed panes report `pid:0`, so CLAUDE.md's documented tty-less
self-identification route is dead wherever session persistence is on (which is
the default). Filed **T153**. And the fork this task exists to prevent was
visible while working it: a second, user-directed Claude session was editing
this same working tree throughout, which is why this turn's commits name their
paths explicitly.

**Same-day correction from the user, folded into T139.** The second window is
*only filing tasks*, and treating it as a rival would have been the wrong rule.
So execution windows now say so out loud: `scripts/go-loop-exec.ps1` pins the
window title to `[go-loop] ...` and **only marked windows are ever touched** -
the task-filing window is unmarked, so it can never be closed or contended
with. When two windows ARE both marked, the sessions settle it themselves: the
lock holder messages the duplicate and closes it; the duplicate messages the
primary, unmarks, and closes itself. No question reaches the user.

The bug that section L caught on its first run is the one worth remembering:
`claim` delegated to the lock without forwarding `-PaneId`, so the lock
re-derived identity from the calling shell's `$env:GHOZTTY_PANE_ID` and the
primary diagnosed *itself* as the duplicate - and closed its own window. Log
lines would have looked plausible; asserting against real windows in `+list`
did not.

Floor for this turn: both test lanes exit 0, `test-agent` exit 0, P1/P2/P3 ALL
PASS, `go-loop-guard.ps1` ALL PASS (78) x3.

## 2026-07-29 - T154 done: the flag was missing, and the probe proved it

ctrl+v could not paste a screenshot into Claude Code. The row had already
root-caused it by inspection - the win32 ctrl-mirror binds ctrl+v with a bare
`put()` while ctrl+c and ctrl+k beside it use `putFlags(.performable)` - and
the whole turn was really about not taking that on faith. One line changed in
`Config.zig`.

What made it verifiable was the oracle: a PowerShell probe running INSIDE the
pane, blocked on `[Console]::ReadKey($true)`, printing the raw character code
it receives. Reading the pane's rendered text cannot tell "pasted nothing"
from "swallowed the key"; a character code can. Text clipboard should yield
90 (`Z`, the token's first char), an image-only clipboard should yield 22
(`^V`), and a swallowed chord shows up as the probe never printing at all.

Pre-fix, on the box: `1 FAILED / 11 passed` - section B at `probe char=-1`
while section C (ctrl+shift+v, which has always carried the flag) returned
22. That asymmetry is the diagnosis, measured rather than argued: same chord
target, same clipboard, different flag, different outcome. Post-fix ALL PASS
(12) x3.

The turn's real cost was the harness, not the fix. The first draft of
`clipboard-paste.ps1` failed its own positive control - typed keys never
reached the shell despite `SendInput` reporting every event delivered and
`GetForegroundWindow() == top`. The terminal surface is a `GhozttyTerminal`
CHILD of the `GhozttyWindow` top-level, and a window raised programmatically
is foreground with focus still on the FRAME. One `SetFocus(paneChild)` fixed
it. Then running `keybinds-t01.ps1` as a regression showed it failing its own
positive control the same way, 14 of 21 red - the standing keybind coverage
has been reporting harness artifacts, filed as T157. A script whose positive
control fails is not evidence about the product in either direction.

Also filed T156: shift+insert -> `paste_from_selection` is the same defect one
block over, and worse - win32 has no selection clipboard, so it can never
perform AND is swallowed, i.e. the chord does nothing at all today.

Floor for this turn: both test lanes exit 0, `test-agent` exit 0, P1/P2/P3
ALL PASS, `clipboard-paste.ps1` ALL PASS (12) x3.

DELIVERED to all 3 install locations (the user reported this one and it blocks
their daily workflow): ReleaseFast gnu `-Dstrip=false` staged to
`zig-out-release` (`+version` = `+650ea4da9`); Desktop portable +
`\homeassistant\share` swapped with `.bak-20260729-t154`; installed release
via the detached upgrade script at the task boundary (default
`-ResumeCommand`, so its relaunch is also this turn's context reset). The
resumed session verifies `%TEMP%\ghoztty-upgrade.log`, then `+version`, then
the fix itself by pasting a screenshot into a Claude Code pane. Next: T155.

## 2026-07-29 - T155 done: the filed mechanism was wrong, and the first test passed on the broken build

Split dividers rendered as double and triple lines. The row had root-caused it
by inspection: a 5 DIP gap with a 1px hairline stroked down the middle, a
parent that erases nothing, and therefore "every ratio change strokes a NEW
line and leaves the OLD one on screen". Two of its three defects were exactly
right. The third - the mechanism that actually made the user see doubles - was
wrong, and the way that surfaced is the whole lesson of this turn.

The first oracle dragged a divider three times and counted contiguous runs of
divider-colored pixels on a scanline. It reported `exactly ONE divider band
after 3 drags (got 1)` **on the pre-fix build**. A test that passes on the
broken build is worth nothing, so the mechanism had to be measured instead of
argued: dragging moves the line clear of the old gap, and the growing pane's
child window covers the stale pixels. Sweeping window-resize steps against the
pre-fix build found the real trigger - 3x 4px shrink gave TWO runs at offsets
973,975, while 6/8/10/14px steps gave one, because a bigger drift pushes the
old line out of the gap where a child covers it. Repeated SMALL resizes, each
drifting the split by less than the gap was wide. That is why the user saw it
resizing a window and nobody saw it dragging dividers.

The fix is one pure module (`split_geometry.zig`) replacing arithmetic that
was triplicated across layout, paint, and hit-test: gap == band == 1 DIP (Mac's
`splitterVisibleSize`), so panes and divider TILE the rect and no parent-owned
pixel is left to hold a stale line; and the band is FillRect'd rather than
stroked, which also kills the 3-edge look.

`WM_ERASEBKGND` is the other half worth recording. The row asked for a real
erase handler; adding one regressed `pane-banner.ps1`. That was settled by
comparison rather than by reasoning about layered windows: pane-banner gave ALL
PASS (45) on the pre-fix build, failed on the build with the hook, and passed
again with the hook removed. It is unnecessary once the tiling holds, so the
handler still returns 1 - now with a comment saying why, so the next person
does not re-add it.

Two more traps, both harness: the pixel oracle needs a screen-pixel control
(an occluded window reads as "0 divider pixels" and looks exactly like a
product failure - it did, twice, before the control went in), and
`split-dim.ps1` + `split-zoom-nav.ps1` launch a GUI per section without
`--session-persistence=false`, so each section restored the previous
section's panes. Both fixed; the sweep of the other ~28 scripts is T158.

Floor for this turn: both test lanes exit 0, `test-agent` exit 0, P1/P2/P3 ALL
PASS, `split-divider.ps1` ALL PASS (25) x3, and `split-dim` (23),
`split-zoom-nav` (16), `pane-banner` (45) ALL PASS.

DELIVERED to all 3 install locations (user-reported and visible on every split):
ReleaseFast gnu `-Dstrip=false` staged to `zig-out-release` (`+version` =
`+f30ae30e9`); Desktop portable + `\homeassistant\share` swapped; installed
release via the detached upgrade script at the task boundary (default
`-ResumeCommand`, so its relaunch is also this turn's context reset). The
resumed session verifies `%TEMP%\ghoztty-upgrade.log`, then `+version`, then
that a split shows ONE hairline divider and still shows one after nudging the
window edge a few px. Next: T130.

Note for whoever runs the next delivery: `scratchpad/deliver.ps1`'s backup tag
is hardcoded per-task, so it overwrote the previous `.bak-20260729-t154` files.
The live binaries were never at risk; only one generation of backup was lost.

## 2026-07-29 - T130 done: the durability gap had already swallowed one fix

Mirrored the Windows banner-hook fixes into the plugin source repo
(`dzearing/ghoztty-claude-plugin` 5a40ac9, 0.7.0 -> 0.8.0). The task existed
because the fixes lived only in this box's plugin cache, where a plugin update
would silently revert them - and the first diff showed that had ALREADY
happened. The cached 0.7.0 hook carried the tty fix and source did not (3 hunks,
19 lines); worse, the `# ` heading documentation applied to the 0.4.0 cached
SKILL.md was simply gone from 0.7.0, whose SKILL.md matched source byte-for-byte.
One of the two fixes was lost by a release before anyone noticed. That is the
argument for mirroring, made by the artifact rather than by me.

The jq question was the only real decision. Vendoring a JSON read/merge in sh
was rejected: the state values are banner markdown carrying quotes, pipes,
backslashes and `\n`, and a hand-rolled writer that gets escaping subtly wrong
CORRUPTS banners instead of failing - strictly worse than the dependency. The
trap was never jq, it was `exit 0`. So the hook now announces itself: no jq
means a one-time per-pane banner saying the banner is inactive and how to fix
it, which works precisely because `ghoztty +set-banner` needs no jq. Guarded by
a `nojq-<pane-id>` flag so it fires once, not every prompt.

Validation: `pane-id.ps1` ALL PASS (45) - section G runs the highest-versioned
cached hook end-to-end and asserts it painted a banner on its own pane via the
pane-id CLI path, not the OSC fallback. Plus two direct checks of the new code:
the mirrored script drove this live session's banner (read back out of `+list
--json`), and with jq removed from PATH the announce path exits 0 and writes its
guard file. Both lanes + `test-agent` re-run green; no app source changed.

Also mirrored into the active cache so this box has the fix now. The version
trap stands: in-process hooks keep running the old script until a session
restarts.

## 2026-07-29 - T127 done: the viewer scope, re-cut against the code

Refreshed the Windows viewer design against the Mac viewer as it exists today
(`docs/design/viewer-panes-windows.md`), decided the v1 line, and re-scoped the
band. T90a was written against 8 commits; there are 27. The rule T127 set for
itself - do not silently widen T90b-T90h - is what shaped the output: each of
those seven rows got an explicit "Re-scoped" note, the new v1 surface became its
own tasks (T159 nav chrome + address bar, T160 markdown TOC, T161 zoom +
pane-scoped chords, T162 selection-toolbar Copy), the cuts became rows too
(T163 popups, T164 feedback capture, design-first), and T90g was NARROWED to
say what it no longer owns.

Reading the code rather than the commit subjects changed the plan four times.
The shared viewer JS is NOT free the way this task assumed: rendering is, but
`viewer.js` and `selection.js` both post to native through
`window.webkit.messageHandlers`, so WebView2 needs a ~6-line shim over
`chrome.webview` - and forking the JS is rejected, or every future Mac viewer
commit needs a Windows translation. The TOC, which looked like the expensive
half of file viewing, is cheap: it is the SAME glass card as the pane banner,
and T131 already ported that to `banner_card.zig`, which is what moved it into
v1 next to the address bar the user named. Feedback capture went the other way -
its three hard parts (lsof port->cwd, `NSTextAttachment` image chips,
clipboard-safe interactive capture) are all platform-specific, so it is a design
problem, not a port, and it is deferred with the reasons written down instead of
being absorbed into a chrome task. And the pane-scoped chords can only have
their STRUCTURE copied: on Windows ctrl+r is free (a viewer pane has no shell)
where on Mac it belonged to the banner editor.

Two corrections to the record. T127's own Summary said `--view` returns T90b's
"viewers are not yet supported on Windows"; it does not - `VerbArgs` has no
`view` field, so the flag is silently dropped as unknown, which is the worse
behavior T90a wanted to replace. And `resolveViewArgument`'s POSIX-only
absolute-path test is still live at `src/cli/split.zig:212` /
`new_window.zig:319`; the address bar's `isFilePath` will need the identical
Windows-shaped fix, so both are cited in the rows that own them.

Checked the inventory was actually current before designing against it:
`git log HEAD..origin/main -- macos/Sources/Features/Viewer src/viewer` is
empty, so 27 is the whole delta. The 12 unmerged non-viewer commits were not
free either - `d6f1c1de5` (banner link hover + action menu) had no row anywhere
and became **T165**, and the client-scoped What's New band belongs to the
existing T125, noted there. Filing them now instead of at merge time is T152's
discipline applied early.

Validation: docs only, no source touched. `parity-tasks.ps1 validate` ALL PASS
(195 tasks), both test lanes and `zig build test-agent` exit 0, P1/P2/P3
ACCEPTANCE ALL PASS. Next: T123 per priority 3f (the banner table's 360pt cap),
with T159-T162 sequenced behind T90b-T90e.

## 2026-07-29 - T138 done: the resume is a decision now, and two blind diagnostics could not say so

The upgrade script assumed its own kill ended the loop's Claude session. That
stopped being true at T89 - the agent owns the PTY and is never killed - so the
script's unconditional `claude --continue` relaunch landed on top of a session
that was still alive, and the user got two windows building T131 (2026-07-28).

The fix is a decision made from one knowable fact: is the Claude that launched
this script still alive after the swap? `scripts/loop-session.ps1` (new)
resolves it (`-LoopClaudePid` -> `$env:CLAUDE_PID` -> ancestry walk) and stamps
its start time so a recycled pid cannot impersonate it. Alive => bring the app
back with a plain `Start-Process`, wait for restore to re-attach the pane, and
`+send-keys --when-idle` the prompt into it. Dead => relaunch, as before. The
pane comes from the inherited `$env:GHOZTTY_PANE_ID`; pane trees were unusable
because `+list --json` reports pid 0 and an empty working_directory for
agent-backed panes, which is the row's original plan refuted and now **T166**.

Two diagnostics turned out to have been lying the whole time, and both were
found by building the test rather than by reading the code. The `+sessions`
probe parsed line-by-line while the command prints a pretty-printed array, so
`SESSIONS-SURVIVE` had been SKIPPING since T89h - on a box with four live
sessions it logged 0. And `+new-window --target=main` is idempotent: with the
IPC names restored, the relaunch FOCUSES the existing window and never runs its
command. The pre-fix script does that in the negative control - `UPGRADE OK
(relaunched...)` with the resume command never started - so the same defect
forks in the field and stalls silently in the sandbox depending on which side
of the restore race the request lands. The relaunch now verifies a window
actually appeared and retries under a unique target if not.

`test/win32/upgrade-no-fork.ps1` ALL PASS x3 (48 assertions): A pure (incl. the
pre-fix parser oracle), B reuse (no fork, same pane re-attached, prompt
delivered, `pre-kill agent sessions: 2` + SESSIONS-SURVIVE OK), C relaunch
intact, D relaunch onto a restored window still resumes. Building it cost three
runs to a silent trap worth its own row: a debug agent already on the box takes
a per-user single-instance mutex, so a sandbox agent exits 183 and the app
quietly falls back to non-persistent panes - **T167**, with a
"the pane really is agent-backed" assert added here so it can never pass for
the wrong reason again. **T168** tracks converging the duplicated identity
helpers in `go-loop-lock.ps1`.

Both test lanes and `zig build test-agent` exit 0; P1/P2/P3 ACCEPTANCE ALL
PASS. Next: T141 per priority 3e (delete the Windows-only relay-login verbs),
then T140, T142.

## 2026-07-29 - T141 done: the verbs are gone, and disabling a button made the dialog deaf

`+relay-login` / `+relay-logout` are deleted. They were T21a's Windows analog of
the Mac's Keychain `RelayAccount`, and the Mac needed no CLI verb because it
signs in from the machine chooser - so the fix was not to rename them but to
put sign-in where the Mac already has it. `MachineChooser` gained an account row
(email + Sign Out, or "Sign in with Google..." when signed out) above the
filter; the flow itself moved to a new shared `src/remote/relay_signin.zig`, and
its async half to `src/apprt/win32/RelayAccountRow.zig`.

It has to be async: `signIn` blocks for as long as a consent screen takes, so
inline it would freeze every window. A detached thread posts WM_APP+9 to
`App.msg_hwnd` (ClaudeIntegration's pattern) and the GUI-thread landing routes
the outcome to whichever chooser is open - or to nobody, because the store is
the state and not the dialog. On success the row relabels AND re-fetches the
device list in place.

**The one defect the validation caught was measured, not argued.** `Escape
closed the chooser` failed on the first full run, and the obvious reading -
"Escape is mis-routed" - was wrong. Disabling the focused button makes Windows
drop the thread's keyboard focus entirely, and with no focus window WM_KEYDOWN
arrives with `msg.hwnd == null`, which `App.run`'s dialog-key routing cannot
attribute to the chooser: Enter, Escape and Tab all went dead for the duration
of the sign-in. Proven with a cross-process `GetGUIThreadInfo` oracle (GetFocus
is per-thread-queue, so a harness in another process cannot use it) that FAILED
pre-fix beside the Escape assertion and passes after `refreshAccountRow` hands
focus to the filter before disabling the button. Deleting the CLI files also
almost deleted test coverage: they were what pulled `relay_account` into the
`none` lane, so `relay_signin` is registered in `main_ghostty.zig`.

The audit's useful answer is structural: the `Action` enum is one shared source
with no `builtin.os.tag` branch, so a one-platform verb cannot exist there
without someone adding one. What does still exist is the same divergence one
level down - verbs both seats accept and only one can answer: `+version`'s
Running Instance section (Mac `IPCServer.swift` has no `case "version"`,
**T169**) and `+list --pid` (parses everywhere, resolved server-side, no `"pid"`
anywhere in the Mac server, **T170**). `+reload`'s Windows absence is viewer
panes, already T127's.

`ipc-relay-login.ps1` -> `relay-account.ps1` (the old name advertised a verb
that no longer exists), reworked to drive the GUI: chord -> chooser -> BM_CLICK
the account button -> harness plays the browser off the URL the app logs. ALL
PASS (53) x3 plus two earlier back-to-back runs. Both lanes + `test-agent` exit
0; P1-P3 and `ipc-machine-chooser.ps1` ALL PASS. **T171** records the one
unreproduced flake (30 pass / 1 fail) whose text the summarising loop threw
away - filed rather than shrugged off. Next: T140, then T142.

## 2026-07-30 - T172 done (T140 split 1/3): the chooser rows, and two probes that lied before the code did

T140 was too big for one context - Mac's chooser is a 840x540 master-detail
view over session browse, metrics and account management - so it was split:
**T172** (this: rows, filter, footer), **T173** (master-detail structure + the
per-row `...` menu), **T174** (per-host defaults store + Host Settings dialog,
which Windows has never had at all: `Window.zig` says so in a comment).

This is the half the user screenshotted. The list is owner-drawn now
(`LBS_OWNERDRAWFIXED`, no `LBS_HASSTRINGS` - the lParam is the row index):
each row is a status shape, a GDI-drawn machine glyph, the name, and a dimmed
subline, with the selection an inset rounded accent pill instead of a
full-width system-blue bar. The row model is pure and ported straight from
Mac, `hostnameSubtext` rule included (`MaximusHome` over `(maximushome)` is
noise, so that row says "Relay device"). The glyphs are DRAWN, not an icon
font - a missing symbol font can render as tofu, and geometry can be
unit-tested. The empty filter got its cue banner. And the footer wraps: the
hint is measured with `DT_CALCRECT | DT_WORDBREAK` and the dialog grows by
exactly the extra lines, capped at four, so the clipped "...to list your"
sentence cannot come back.

One ordering trap: `WM_MEASUREITEM` arrives DURING `CreateWindowExW`, before
the dialog's userdata points at `self`, so row height is set explicitly with
`LB_SETITEMHEIGHT`. Hover needed the listbox subclassed - the parent never
sees a control's own mouse messages.

The evidence is what took the time. Both new on-box probes passed vacuously
at first and had to be made honest:

- Every pixel assertion agreed on one wrong value. Cause: an unaware process
  gets DPI-VIRTUALIZED `GetWindowRect` while `Graphics.CopyFromScreen` is
  physical - the capture was 189px off at 125%. `SetProcessDPIAware()` first,
  and the DPI scale is now derived from the chooser's own client width
  (`px(440, scale)` by construction) rather than hardcoded.
- Per-pixel `GetPixel` on the desktop DC under DWM is ~1000x slower than a
  blit; it turned a seconds-long script into a minutes-long one. One
  `CopyFromScreen` per probe set, then managed reads.

With that fixed the pill reads b-r = 47 - exactly the computed
`blend(30,30,30, 3D8EF8, 0.25)` - while the gutter beside it and an
unselected row read 0. **Negative control on the claim that matters**: paint
the fill edge-to-edge and `selection is inset, not full-width` FAILS at b-r =
47 in the gutter. Reverted and re-passed. A second, signed-out launch proves
the footer independently: 3 hint lines to the signed-in run's 1, the window
taller by exactly that, and the wrapped tail actually painted inside the
control. `ipc-machine-chooser.ps1` ALL PASS (23) x3; both lanes +
`test-agent` exit 0; P1-P3 ALL PASS. Next: T173, then T174, then T142.

## 2026-07-30 - T173 split; T175 (chooser master-detail shell)

T173 ("master-detail layout + per-row `...` menu") was two tasks wearing one
id: a layout port and a network-backed menu with its own modal prompt. Split
into **T175** (shell) and **T176** (menu + relay Rename/Remove), and did T175.

The chooser is now Mac's 840x540 master-detail: account row and rule, a fixed
260-wide machine column on a faint wash, a vertical rule, a detail pane naming
the selected machine with `New Window` beside it, a rule, and **Cancel alone**
in the footer. Geometry moved out to a new pure `chooser_layout.zig` (the old
`MachineChooser.Layout` and its tests went with it); the wash, the rules and
the detail header are painted in `WM_PAINT`, so the detail glyph is the same
GDI silhouette the rows draw, one size up.

Two defects the new assertions caught, neither guessable from the code:

- A listbox snaps its height to whole items **at creation, using the default
  item height** - our `LB_SETITEMHEIGHT` lands afterwards. It shaved a row off
  and pinned the height there, so when the status strip wrapped the column
  silently stopped flexing (measured: list -0 for strip +60). `chooser_layout`
  snaps to whole rows itself, so `LBS_NOINTEGRALHEIGHT` is now correct and the
  accounting is exact (-56 for +60, whole rows, list ends above the strip).
- `LB_SETCURSEL` does not send `LBN_SELCHANGE`, so arrowing moved the highlight
  and left the detail pane describing the machine you had left.

Also recorded as deliberate, not oversight: the detail pane below the header is
**empty**, because what fills it on Mac is the browsed session list and Windows
cannot browse sessions until T146. `ipc-machine-chooser.ps1` 26 -> 34
assertions, ALL PASS x3; `relay-account.ps1` ALL PASS (its account-button
finder had to learn the new `New Window` label); both test lanes +
`test-agent` exit 0; P1-P3 ALL PASS. Next: **T176**, then T174, then T142.

## 2026-07-30 - T176 (chooser row menu + relay Rename/Remove)

The chooser's rows are now manageable. A `...` button beside `New Window` and a
right-click on a row open the same menu, built by a new pure `chooser_menu.zig`
from the row kind: `Rename...` | sep | `Remove from Account...`. Behind them,
`relay_directory` gained `renameDevice` (PATCH) and `deleteDevice` (DELETE)
over a new method-generic `http_client.requestAuth`, with path segments
percent-encoded so a hostile device id cannot retarget the request.

Three decisions worth keeping:

- **The row's task file said not to spin a nested message loop; I did anyway.**
  `ConfirmDialog` (T80) is that dialog minus a text field and already runs one,
  citing the T48 analysis - which found the deadlock was a NON-PUMPING wait
  inside a WndProc, not nesting. So `Rename...` is `ConfirmDialog` plus an
  optional field (`Options.input` + `prompt()`), which is also what Mac does
  (NSAlert + accessoryView, the same class as the remove confirmation). A field
  takes focus with its seed selected and forces Enter onto OK; the destructive
  remove keeps MB_DEFBUTTON2, and the script proves Enter there CANCELS with no
  DELETE sent.
- **`Host Settings...` is absent, not greyed** - one bool
  (`HOST_SETTINGS_AVAILABLE`) that T174 flips. `hasMenu` derives from `build`,
  so a row whose only item is gated away gets no menu instead of an empty
  popup, and no menu ever opens with a leading separator.
- **The test found a real gap by accident.** With the rename finally landing,
  the whole remove block stopped running - because the re-list selected row 0
  and hid the `...`. Renaming a machine was throwing the user back to Local.
  `reloadDevices` now re-anchors by device ID (copied out first - the refetch
  frees the arena it points into), by ID and not index because a refetch may
  reorder. Mac calls this `reanchorSelection`.

The harness trap that cost the time: **a cross-process `SetWindowTextW` on an
EDIT does not type into it.** It updated USER32's cached window text - so the
script's `GetWindowTextW` read the new name back and the assertion passed -
while the control's buffer kept the old one, and the app, reading in-process
via `WM_GETTEXT`, saw the OLD name. The rename became a silent no-op that read
as a product bug. The script now sends real keystrokes and reads the field with
`WM_GETTEXT`, which also makes the assertion honest: it proves the seed is
pre-selected, because typing replaces it.

New `test/win32/chooser-menu.ps1` drives both entry points with real mouse
clicks against a STATEFUL fake relay (it really renames and deletes, so the
re-list shows the consequence) and reads the live popup through `MN_GETHMENU` +
`GetMenuStringW` to assert the exact item list. ALL PASS (33) x3; both test
lanes + `test-agent` exit 0; P1-P3 ALL PASS; `ipc-machine-chooser.ps1`,
`relay-account.ps1` and `confirm-dialogs.ps1` re-run green. Filed **T177** (the
detail action row is short Mac's `Activity`, and `Restore All` which belongs to
T146). Next: **T174**, then T142.

- 2026-07-30 (on-box) — **T174 DONE**: Windows finally has per-host remote
  defaults. Three pieces — a `host_defaults.zig` store (JSON under
  `%LOCALAPPDATA%`, keyed on the relay DEVICE ID else `host:port`, so a rename
  cannot orphan a machine's settings; corrupt/blank/duplicate rows degrade to
  empty rather than failing; `GHOSTTY_HOST_DEFAULTS` overrides the path for
  tests), a `HostSettingsDialog.zig` two-row editor in the ConfirmDialog
  nested-pump shape (working-directory EDIT + editable shell combo with Mac's
  exact 6 presets, Save/Cancel), and `HOST_SETTINGS_AVAILABLE` flipped so
  `Host Settings…` LEADS the chooser's row menu.

  Applied at Mac's two altitudes, deliberately not everywhere: a NEW remote
  window takes cwd + shell — seeded once in `App.openDialedWindow`, the single
  remote-open tail, so the chooser, T68's inheriting re-dial and
  `+new-remote-window` all inherit it from one site (Mac needs two) — while a
  tab/split takes the SHELL ONLY, because its cwd comes from the parent pane's
  live GET_CWD and a per-host default must not yank a split away from where its
  parent is. The local session-persistence agent is excluded: it is this
  machine, not a host with defaults.

  Two win32 specifics: the combo's OPEN drop-down owns Enter and Escape (without
  the `CB_GETDROPPEDSTATE` guard, picking a preset by keyboard would also
  save-and-close the dialog behind the list), and focus inside an editable combo
  lands on its inner EDIT — so both the nested pump's key routing and the Tab
  cycle resolve that child back through `GetParent`. One correctness catch during
  review: `RemoteInherit` is returned BY VALUE, so the inherited shell had to be
  heap-owned like its `cwd` — an inline buffer would have dangled the moment the
  struct was copied to the caller.

  The trap that cost the time was in the harness, not the product: **`+send-keys`
  translates escapes**, so `cd …\t174-elsewhere` arrived with a literal TAB,
  cmd tab-completed elsewhere, the `cd` never happened, and the split-cwd
  assertion read as a product bug. Backslashes are doubled now and the script
  proves the parent moved before asking where its split landed. New
  `test/win32/host-settings.ps1` ALL PASS (61) ×3 (real GUI for the editor +
  real loopback agent for the apply rules, with a MEASURED before/after shell
  flip so it cannot pass by matching the box default); `chooser-menu.ps1` updated
  for the 3-item menu, ALL PASS (33); ipc-machine-chooser, relay-account,
  confirm-dialogs green; both lanes + `test-agent` + P1–P3 green. Filed **T178**:
  `remote-inherit.ps1` is red on 4 assertions (the remote-native `--command`
  split's marker never appears) — PROVEN pre-existing by building a worktree at
  HEAD `f1f973b88` and reproducing the identical four. Next: **T142**.

## 2026-07-30 - T142 done: the overlays defend their z-order, and the baseline assertion found the real bug

- **T142 done.** The filed cause (a T131 probe left `HWND_TOPMOST` on two
  overlays and `SWP_NOZORDER` meant nothing ever cleared it) was real and is
  fixed — but the *healthy baseline* assertion of the new harness failed before
  any injection, and that is where the user's actual report lived: with window B
  in the foreground directly over window A, A's banner overlay indexed **above
  B**, and the `Between(overlay, A)` probe named the sandwiched windows
  (`GhozttyScrollbar, GhozttyWindow`). Mechanism: `SWP_SHOWWINDOW` lifts a popup
  to the top of the non-topmost band, and ownership only pins a popup above its
  OWN owner — nothing keeps it below unrelated windows. So any banner set while
  its window was not in front floated over other apps indefinitely, no stray
  probe required.

  One helper fixes both: `win32.healOverlayZOrder(hwnd, owner)` clears a stray
  topmost bit AND re-seats the popup directly above its owner when a foreign
  VISIBLE window has got between them. Called after every reposition
  (`BannerOverlay.updatePosition`, `DimOverlay.show`,
  `Scrollbar.repositionAndResize`, `Window.showResizeOverlay`) and — the part
  that matters for a window nobody resizes — from **`WM_ACTIVATE`** via
  `Window.healOverlayZOrders` / `Surface.healOverlayZOrders`, because switching
  windows is exactly when the defect becomes visible. Policy is a pure
  `overlay_zorder.zig` (`isStray`, `walkStep`) unit-tested in the none lane.

  Three drafts were wrong and the harness said so each time, not an argument:
  the check must be **owner-relative** (`toggle_window_float_on_top` and the
  quick terminal make a window topmost and Windows propagates the bit to owned
  popups — clearing it would hide the banner behind its own floating window;
  section E asserts the propagated bit SURVIVES); `SetWindowPos(overlay, owner)`
  puts the overlay **behind** its owner (measured `ov=6, A=5` — an owned window
  cannot be sunk by the SYSTEM's ordering, but an explicit call is honored as
  given), so the seat is `GetWindow(root, GW_HWNDPREV)`; and re-placing
  unconditionally churns sibling overlays against each other every layout pass,
  so the walk short-circuits when already seated.

  New `test/win32/overlay-zorder.ps1` ALL PASS (24) ×3, with a **negative
  control** (fix neutered by an early `return`, same binary otherwise) at **9
  FAILED / 13 passed** — baseline trio, reposition-heal, activation-heal and
  both dim/scrollbar cases all fail pre-fix. Both lanes + `test-agent` + P1–P3
  green; `pane-banner.ps1` and `split-dim.ps1` re-run green. Harness trap worth
  remembering: **PowerShell variables are case-insensitive**, so `$OV = Hwnd-Of
  $ov` destroyed the rect row it came from and every geometry probe then sampled
  `(6685007, …)`, which reads exactly like a product verdict. Filed **T179**
  (probes must restore `HWND_NOTOPMOST` — the class of harness bug that
  manufactured this task's phantom) and **T180** (the transient drag-preview
  popup and the quick terminal were left out of the heal on purpose; verify
  rather than assume). Next: **T133** per 3d.

## 2026-07-30 - T133 done: the reset helper wipes the composer, and now proves the reset landed

- **T133 done.** The cache-only `C-u` composer wipe is mirrored into the
  `dzearing-claude-marketplace` source repo (`2ef7766`, dzearing-skills
  0.10.2 → 0.11.0) — it was the only drift in the whole plugin, and it was the
  line that keeps the loop alive. Added the "while there" half: the helper now
  reads the pane back to verify both the `/clear` and the continuation, and on
  failure writes a `!!! RESET-CONTEXT FAILED` block with the pane tail into its
  log *and* sets a pane banner. The continuation is sent either way — an
  uncleared context merely gets big, a missing one stops the loop. New
  `test/win32/reset-context.ps1` ALL PASS (24) ×3 against a readline-based
  composer model, with a negative control (the `C-u` line deleted, nothing
  else) reproducing the filed `nn/clear` symptom and tripping the loud path.
  Filed **T181** (`+read` transiently fails on a pane `+list` already reports —
  an empty tail reads exactly like a product verdict). Both lanes, `test-agent`
  and P1–P3 green. Next: **T38/T39 per item 20** — that closes the 3d chain
  (T132 → T131 → T130 → T133); check for 3e–3g leftovers first, they outrank it.

## 2026-07-30 - T123 done: banner tables size to the pane, not a fixed 360pt cap

- **T123 done** (3e/3g were already clear, so this is 3f's first open item —
  the user's *"the text in the table has fixed width and doesn't use available
  space"*). Mac's `columnWidths(natural:available:)` ported line for line; what
  did NOT port is how the width arrives. Mac reads it with a SwiftUI
  `GeometryReader`, win32 has none, so it goes **top-down through the layout
  call that already runs on every resize** — `layoutNode` →
  `bannerLayoutInset(slot_w, slot_h)` → `insetHeight(scale, pane_w)`. One-way,
  so the measurement↔column feedback loop `c94a8158a` had to break on the Mac
  cannot form here.
- Beyond the port: `ensureContentHeight` had been measuring the band at
  `1 << 20` px — infinity — so the reserved band came from a layout that could
  never be the one painted. Measure and paint now share one width, which is
  what lets the band track a rewrap. Long unbroken tokens break mid-string
  (`breakWideTokens` + one `GetTextExtentExPointW` per chunk, with
  `utf16PrefixBytes` keeping the split off codepoint and surrogate-pair
  boundaries), and cells cap at 3 lines with a tail ellipsis.
- **The band height IS the oracle** — `pane-banner.ps1` section 6g counts
  display rows from the overlay rect, so every assertion is self-relative and
  needs no pixel constants at any DPI. ALL PASS (54) ×3. The **negative
  control** (`T123_NEUTERED`, left in the source) fails **exactly those 6 and
  nothing else**, and its numbers are the user's report measured: a >360px
  value wrapped at 146px on a 1400px pane while the short one sat at 121px;
  narrowing 1400 → 520 moved the band 146 → 146, i.e. not at all; a 90-char
  token took one clipped line; one nasty cell blew the band to 446px. The pane
  measured 1382 → 502 px across that resize, so "a banner can pin a minimum
  pane width" is closed by measurement.
- Two harness traps worth remembering. **Non-ASCII inside a PowerShell string
  literal** in a BOM-less UTF-8 `.ps1`: PS 5.1 decodes it as cp1252 and an em
  dash becomes `â€"` — that `"` is a smart quote PS treats as a **string
  delimiter**, so the parse blows up lines later. Every em dash already in
  these scripts sits in a COMMENT, which is why it had never bitten. And the
  file-rewrite half of the same trap bit me directly: `(Get-Content -Raw) |
  Set-Content -Encoding utf8` mojibaked `BannerOverlay.zig` in one shot
  (recovered by re-encoding the UTF-8 read back through cp1252 — the round trip
  is exactly reversible). Use the Edit tool on repo text; never a PowerShell
  whole-file rewrite.
- Filed **T184** (text/heading/list blocks still clip instead of wrapping — the
  same complaint one block type over, and the T123 machinery is what fixes it),
  **T183** (an agent-server test that panics on a null when its temp dir
  vanishes; it took the none lane red once while P1–P3 ran concurrently and
  passed solo — a floor lane that lies is expensive), and **T182** from a live
  user question: `/reset-context` shouted `RESET-CONTEXT FAILED` on a reset
  that fully worked, because T133's new check looks for the continuation text
  echoed in the pane and *accepting* the prompt is what erases it. Both lanes,
  `test-agent` and P1–P3 green. Next: **T144** per 3f.

## 2026-07-30 - T144 done: new panes stop landing in System32, and the config that would have let you say otherwise was never written

- The user's report ("it keeps defaulting to windows system32 folder
  (HORRIBLE!)") had a filed primary hypothesis, and it held - but only after it
  was **measured**. There is no API for "another process's cwd", so the agent's
  `RTL_USER_PROCESS_PARAMETERS.CurrentDirectory` was read out of its PEB while
  the user's real build ran: the installed agent, started by the T89h HKCU `Run`
  entry, sits in `C:\WINDOWS\system32`. The repo-launched debug agent sits in
  `D:\git\ghoztty` - which is exactly why months of on-box testing never saw
  this.
- The defect: `Surface.zig` refused to forward the resolved
  `working-directory` to *any* remote agent. Correct and load-bearing for a
  CROSS-MACHINE agent (a local path on a different-OS agent is the OPEN-stall
  wedge); wrong for the LOCAL one, which is this same machine. So the OPEN
  carried no cwd and the child spawned wherever the agent was sitting. The
  invariant that closes it: **the same app with the same config must not open in
  two different directories depending on `session-persistence`**. Mac has
  forwarded it since the local agent landed (`TerminalController.swift`);
  Windows never ported that line. The rule now lives in shared core as
  `termio.Remote.openWorkingDirectory`.
- **Two premises in the filed row were wrong.** The loader does NOT read
  `config` - since 1.3.0 the default is `config.ghostty` and the user's file was
  at the right path, just empty. And "find out what wrote it": Ghoztty did.
  `writeConfigTemplate` printed a ~2 KiB template into a 4096-byte buffered
  writer and **never flushed**, so every user with no config got a zero-byte one
  - and an empty file still counted as "a config exists", so it was never
  retried. That is why the user had no escape hatch: there was nowhere to
  discover `working-directory`. Both fixed; an empty config now self-heals, a
  file that fails to PARSE is still never clobbered.
- **The CLI cannot reproduce this bug.** `ghoztty +new-window` always inserts
  `--working-directory=<caller's cwd>` when the flag is absent
  (`src/cli/new_window.zig:268`) - by design, a CLI-opened window belongs where
  you typed. A first draft of the harness asserted on `+new-window` and "failed"
  for that reason. The report is about **ctrl+n**, so section D injects the real
  chord.
- `test/win32/new-window-cwd.ps1` ALL PASS (39) x3. Its section A proves the
  trap is ARMED before asserting it is harmless (the agent's cwd IS the
  launcher's), so nothing can pass vacuously. **Negative control**
  (`T144_NEUTERED`): 8 assertions fail and they read as the user's report -
  every persistence-ON shell in `c:\windows\system32`, persistence-OFF fine.
  Both lanes, `test-agent` and P1-P3 green.
- Harness trap worth keeping: **PowerShell unrolls a one-element array on
  return**, and a lone `PSCustomObject` has no usable `.Count` in PS 5.1, so
  `(Windows-Of $tree).Count -ge 1` was *always false* for a single-window app -
  three assertions failing while the ones after them passed. `return ,@(...)`.
  `auto-launch-cwd.ps1` only escaped it by always waiting for >=2 windows.
- Filed **T185** (a Windows pane reports its INITIAL cwd forever - cmd/powershell
  emit no OSC 7, so `+list` and window-inherit are both stale the moment you
  `cd`) and **T186** (Mac seat: both changes are shared core and unrun there;
  the template flush is very likely an upstream bug worth reporting).
- DELIVERED to all 3 install locations (user-facing): ReleaseFast gnu
  `-Dstrip=false` staged to `zig-out-release` (`+version` = `+43681d1c2`);
  Desktop portable + `\homeassistant\share` swapped with `.bak-20260730-t144`;
  installed release via the detached upgrade script at the boundary (default
  `-ResumeCommand`, so its resume is also this turn's continuation). Resumed
  session verifies, in order: `%TEMP%\ghoztty-upgrade.log`, then that
  `%LOCALAPPDATA%\ghostty\config.ghostty` is no longer zero bytes (the user's
  real profile had exactly that), then that its own pane and a fresh ctrl+n are
  not in System32. Next: **T143** (the missing menu bar) per 3f.

## 2026-07-30 - T187 done: the upgrade script called a running app dead, and the loop stalled until a human pinged

- Found by T144's own delivery. `%TEMP%\ghoztty-upgrade.log` said
  `RESUME-REUSE FAIL: the app did not come back up` at 09:07:00 - while
  `ghoztty.exe` pid 35456 was up, `StartTime 9:06:00 AM`, and answering `+list`
  fine afterwards. Because a false "app is dead" is fatal-but-don't-fork, the
  resume prompt was never typed. This is the failure class T138/T139 exist to
  prevent, so it jumped the queue (the T112 precedent: the loop's own
  continuation mechanism gets fixed first).
- **Both filed mechanisms were REFUTED by measurement**, which is the part worth
  keeping. Time from `Start-Process` to first successful `+list --json`, debug
  build, app killed with the agent left alive: cold start **427ms**; restore of
  a 5-pane manifest **451ms**; restore with the agent **suspended outright**
  (`NtSuspendProcess`, 40s) **10 755ms**. So the pre-loop
  `restoreSessionLayout` is neither slow nor unbounded - it gives up and the
  message loop starts in ~11s. "The app did not come back up" is essentially
  never true after ~11s, and a 60s IPC blackout is not restore.
- What the numbers DO indict is the probe. `Get-ListJson` ran `& $oldExe +list
  --json` with **no timeout**, and `Wait-Instance` only checked its deadline
  BETWEEN calls - so a single blocking probe (exactly what a client connecting
  to a bound-but-not-yet-accepting pipe can do) swallows the entire window
  without the loop iterating, and the deadline then reports death. The verdict
  was also keyed solely on IPC, never on the far simpler fact that the process
  the script itself started is alive.
- Fix: `Invoke-GhozttyListJson` in `loop-session.ps1` - one BOUNDED probe
  returning `@{Json; Why}` - put in the shared lib precisely so a test can drive
  it with stand-in executables. `Wait-Instance` now takes the started process,
  bails when it EXITS, logs the first failure and then every ~15s, and the reuse
  deadline is 60s -> 180s. The FAIL line says WHICH of "exited" / "alive but IPC
  unreachable" happened; the old one asserted the first while the truth was the
  second.
- `upgrade-no-fork.ps1` A22-A30: a stand-in `.cmd` that sleeps 30s must return
  within its own 3s bound and say `hung` (pre-fix it blocked for the callee's
  duration - the whole defect); an exit-1 stand-in must surface `exit=1` AND its
  first output line so the log explains itself next time.
- Filed **T188** for the pre-loop restore latency, on its own merits rather than
  fixed opportunistically: `restoreSessionLayout()` runs before `GetMessageW`,
  so IPC is bound-but-unserviced for its duration. Small and bounded today
  (numbers above), but the bound is a timeout rather than a design.
- `upgrade-no-fork.ps1` ALL PASS (60) x3 and `go-loop-guard.ps1` ALL PASS
  (`loop-session.ps1` is shared by both).

## 2026-07-30 - T189 done: one command list, so a second command surface cannot drift from the first

- T143 (*"on the mac version, there is a way to access the menu bar. On
  windows, there's none."*) does not fit one context - host design, a ~60-item
  tree, an HMENU host, and a script that walks every item. Split into **T189**
  (design + pure model) and **T190** (the GUI host). This is T189.
- **The host decision, with reasons rather than taste**: a `≡` button at the
  end of the tab strip opening a nested popup, NOT `SetMenu`. The classic menu
  BAR is drawn by the system frame and ignores the uxtheme dark-mode ordinals
  (only popups honor them - the whole T79 mechanism), so it would be a light
  strip pinned over a dark terminal; it also lives outside the client area,
  and every layout path in `Window.zig` is written against "client top == tab
  strip". Windows Terminal, VS Code and Edge all use a button.
- **The refactor is the point of this half.** The palette owned a private
  `palette_entries` array in `Surface.zig`. A menu is a second surface over
  the same commands, and two hand-maintained lists drift - that is exactly
  T57, where fork actions had keybinds but never reached the palette's
  parallel list, so hero mode was undiscoverable while working. New pure
  `commands.zig` is the ONE registry both surfaces read; new `menu_bar.zig`
  holds the tree, mnemonics and per-item state and references commands by id.
  `Surface.performCommand` is the single dispatch path.
- Anti-drift is a TEST, not a habit: `everyCommandIsPlacedOrOmitted` fails the
  build unless every registry command is in the menu tree or in
  `menu_bar.omitted` with a written reason. Adding a command now forces a
  decision instead of quietly landing in one surface.
- Free side effect: because the palette renders the registry, ten commands
  that had a keybind and no palette row now have one (Close All Windows,
  Show/Hide All Terminals, Command Palette, Find Next/Previous, Hide Find Bar,
  Jump to Selection, the four Move Divider rows, Check for Updates, Help).
- Rows deliberately NOT in the tree, each because the command does nothing on
  Windows rather than because of taste: Undo/Redo, Services/Hide Others/Show
  All/Bring All to Front, Secure Keyboard Entry, Terminal Inspector, **Paste
  Selection** (`supportsClipboard` returns false for `.selection` - see T156)
  and **Float on Top** (no win32 handler at all - filed as **T191**).
- New `test/win32/command-registry.ps1` **ALL PASS (19) x3**, asserting by
  outcome: a pre-existing command still dispatches after the refactor, a
  filter matching nothing dispatches nothing (and - verified in
  `handlePaletteKey`, not assumed - leaves the palette OPEN), and a command
  that reached the palette only via the registry dispatches.
- **Negative control run for real**: renaming that one registry row and
  rebuilding failed **exactly one assertion and nothing else** (18/1), then
  restoring it returned 19/19.
- That control also caught **T192**: `zig build` exits 1 on `AccessDenied`
  installing `ghoztty-agent.exe` while a repo-lineage agent is running - after
  it has already installed a new `ghoztty.exe`. A false "it didn't build" over
  a binary that did change, which is the T49 lesson with the sign flipped.
- Floor: both lanes + `test-agent` + P1-P3 green; `hero-mode.ps1` ALL PASS (60)
  as the palette-dispatch regression check.

## 2026-07-30 - T190 done: the menu exists now, and the strip it lives in had to start existing too

- **T143 is closed by this half.** T189 landed the model and the one dispatch
  path; nothing was reachable. Now: a `≡` button at the right end of the tab
  strip, a recursively built `HMENU` (85 rows across five submenus plus the
  Settings pair), `TPM_RETURNCMD` → `menu_bar.fromMenuCommandId` →
  `Surface.performCommand`. No second dispatch path — that was the T189
  contract and it holds.
- **The task's premise was wrong in one place, and it mattered.** T190 assumed
  the tab strip is there. `window-show-tab-bar = auto` hid it until a second
  tab existed, so the menu button was invisible in exactly the default
  single-tab window whose missing menu the user reported. On win32 `auto` now
  shows the strip from the first window: macOS can afford "tabs only" because
  its app menu lives in the system menu bar, Windows has no such bar, and since
  this task the strip IS the menu host. Windows Terminal, VS Code and Edge all
  show a strip with one tab, so it is also the native shape. `never` stays the
  opt-out (F10 / lone Alt / the palette still reach the menu there).
- **Accelerator labels are a MOVE, not a copy.** `formatTrigger`/`keyName` came
  out of `Surface.zig` into a new pure `menu_label.zig` with `withAccel` and
  its own tests, so the context menu (T129) and the menu format a chord through
  one code path. `menuItemLabel` refuses to label a non-`binding` command, so
  New Remote Window / About / Help / the plugin install never advertise the
  placeholder action's chord.
- **F10 and a lone Alt open it**, posted (WM_APP+10) rather than tracked inside
  the key WndProc — the key finishes being delivered and the modal loop never
  nests inside a keyboard message (the T48 class). Two deliberate narrowings:
  Alt only counts when nothing else happens between its down and up (so
  alt+key, alt-as-modifier and alt+tab are untouched, and the release is never
  consumed), and **F10 yields on the ALTERNATE screen**, because every TUI that
  binds F10 runs there and a shell prompt does not.
- **Measured, not argued (1).** That alternate-screen read is on the key path,
  so the plain `renderer_state.mutex` was the wrong lock: F10 right after a
  zoom produced NO menu within 3s and then opened one seconds later, out of
  band. `lockPriority`/`unlockPriority` (T114), exactly like `isWin32InputMode`
  next to it.
- **Measured, not argued (2).** The harness scored the product wrong for three
  runs. Its "back on the primary screen" oracle was "`+read` works again" — but
  `+read` failing means *nothing to read*, not *alternate screen*, and a
  ^C-killed child never emits `?1049l`, so the terminal was still on the
  alternate screen and F10 was correctly passing through. The child now
  switches back itself and prints a marker; seeing the marker is positive
  proof. Filed **T193** for `+read`'s unhelpful answer on the alternate screen.
- Harness note worth carrying: `GetMenuState(MF_BYPOSITION)` returns a
  submenu's ITEM COUNT in the high byte, so any submenu with 8–15 items sets
  0x800 and reads as MF_SEPARATOR. Check `GetSubMenu` first. (`context-menu.ps1`
  carries the same latent bug; its menu has no submenus, so it never fires.)
- New `test/win32/menu-bar.ps1` **ALL PASS (47) ×3** — button (incl. a pixel
  check for the painted glyph with a blank-strip control, and proof the `+`
  beside it still works), the full recursive tree, four dispatches asserted by
  outcome, state gating both ways, the T89e Exit label under both settings, a
  rebind relabel, and the keyboard section.
- **Two negative controls, both run for real.** Retitling ONE row failed
  **exactly the two predicted assertions** (the tree compare and the Ctrl+T
  label lookup) and nothing else — 45/2 — then 47/47 on restore. And disabling
  the new right-edge button pin failed exactly the reflow section, in the way
  the mechanism predicts: only 24 of the 26 requested tabs could be opened,
  because the `+` the script was clicking had itself scrolled off the edge.
- That reflow section exists because the strip's buttons were drawn AFTER the
  last tab, and tabs stop shrinking at a minimum width — so past ~26 tabs on
  this box both buttons left the screen. A pre-existing `+` bug nobody had hit,
  which would now take the whole menu with it. Both are pinned to the right
  edge now, and the tab count in the test is COMPUTED from the window's width
  and DPI: the first version hardcoded 18, which still fit here and proved
  nothing.
- **A crash caught by review, not by luck.** `Window.close()` calls
  `DestroyWindow` synchronously and `onDestroy` frees the `Window` allocation,
  so File → Close Window / Exit free the very window whose menu host is on the
  stack. The first version cleared the button's lit state in a `defer`, i.e.
  after the dispatch — a use-after-free on the row every Windows user reaches
  for. The script now chooses Close Window, accepts the confirmation, and
  asserts the app is still healthy afterwards; with the `defer` put back that
  run leaves `+list` failing with "Failed to read IPC response length".
- Floor: both lanes + `test-agent` + P1–P3 green; regressions `context-menu.ps1`
  ALL PASS (31) — the accelerator formatter was MOVED, so that is the assertion
  that the older menu still labels its chords — `command-registry.ps1` (19),
  and, because the strip now shows in a single-tab window, `split-divider.ps1`
  (25), `pane-banner.ps1` (54) and `hero-mode.ps1` (60).
- DELIVERED to all 3 install locations (ReleaseFast gnu `-Dstrip=false`,
  `+version` = `+5d07c3835`): Desktop portable + the `\homeassistant\share`
  copy swapped, installed release via the detached upgrade script at the
  boundary — with `-ResumePrompt` set to this turn's `/reset-context`, so the
  reset lands after the swap and the fresh session verifies the upgrade log
  and `+version` first.

## 2026-07-30 - T145 done: a dead agent no longer means dead panes until you relaunch

Kill the local `ghoztty-agent` while the GUI is up and, before this, every
persistent pane was frozen until the user quit and relaunched — the exact
failure session persistence exists to prevent. Windows had only launch-time
restore (T89f2); the Mac's in-place recovery (`03f0f1f30`, hardened by
`e65cfa4d5`) had no equivalent here.

- **Split first.** The row named two Mac commits that are two mechanisms, and
  the second (`20e505aaf`, reconcile launch restore against the agent's
  authoritative layouts) turns out to need machinery win32 does not have:
  **win32 never calls `SET_LAYOUT` at all**, so a straight port would union
  against an always-empty roster and change nothing. That half is now **T194**.
- **The decisions are pure** (`agent_recovery.zig`): the settle-window verdict
  and the "whose session may a tree swap end?" invariant, unit-tested in both
  lanes. Detection is EVENT-DRIVEN — the connection FSM's state handler fires on
  the reader thread under `state_mutex`, so it posts `WM_APP_AGENT_LINK_DOWN`
  and returns (the T190 post-don't-track-inline pattern); the settle timer is
  armed only while a down link is being judged, so an idle app does no polling.
- **The rebuild reuses the restore walker.** `recoverLocalAgentInPlace` captures
  the live topology into the same `session_layout` structs the manifest uses and
  replays each tab through `restoreFirstLeaf`/`restoreAttachOverride`/
  `restoreBuildSubtree`, so ratios, tab colors, hero ratios, pinned titles, IPC
  names and pane ids all come back through code every restore test covers. One
  new primitive: `Window.replaceTabRootSurface`, which swaps a tab's whole tree
  and deliberately never marks close intent — the departing leaves left because
  we replaced them, and their sessions are the ones the new leaves just
  re-ATTACHed (`e65cfa4d5`).
- **A live use-after-free was fixed on the way in.** `sharedConnection` freed a
  dead cached connection (`Dialed.deinit` → `conn.destroy`) while
  `Surface.remote_conn` and `Window.local_agent_conn` still held that raw
  pointer; the comment claiming the core kept it alive was simply wrong, nothing
  refcounts it. Replaced connections are now RETIRED — shut down, kept
  allocated — and freed only in `LocalAgent.deinit`, which `App.terminate`
  already runs after every window is gone.
- **Measured, not argued.** A file-only pid read would have misdiagnosed every
  crash: a dead agent leaves `port.json` behind, so the recorded pid would have
  MATCHED and the app would have logged "same agent, transport failed" about a
  process that no longer exists. `liveAgentPid` gates on the pid being a running
  process (Mac gates the same read on `kill(pid, 0)`), with access-denied
  counting as alive.
- New `test/win32/agent-recovery.ps1` **ALL PASS (25) ×3** — and the assertion
  that carries the task is C6, a marker round-tripping through the rebuilt pane.
  Section B proves the trap is ARMED (the panes are genuinely broken before
  recovery is asserted) and C4 pins the defining invariant that the APP pid
  never changed.
- **Negative control, run for real.** With the watch disabled the script failed
  **exactly** the six recovery assertions (C1/C2/C5/C6/D1/D2) and nothing else.
  That sections A, B and E still passed is the point: the topology survives a
  dead agent, so only RESPONSIVENESS separates recovered from frozen — a
  topology-only test would have passed the broken build.
- **The harness lied three times before it measured anything.** Timed
  `WaitForExit(ms)` leaves `ExitCode` unreadable unless you touch `$p.Handle`
  first; a quoted argument through `cmd /c` reaches cmd WITH its quotes
  (`'"echo MARK"' is not recognized`); and the minimized test window makes a
  split pane a couple of columns wide, so the marker WRAPS one character per row
  and fell off the top of a 25-line read. All three scored a working pane as
  broken.
- Floor: both lanes + `test-agent` + P1–P3 green; regressions `session-reattach`,
  `session-open`, `session-close`, `session-relaunch` ALL PASS, plus
  `split-divider` (25) and `pane-banner` (54) because the swap touches tab
  visibility and surface lifetime.
- Filed **T194** (the split-out launch-restore half) and **T195** (the settle
  window is unit-tested but has no on-box blip test).

## 2026-07-30 - T147 done: the new agent was already on disk; nothing ever picked it up

The row said Windows' agent upgrade was DESTRUCTIVE. It was **inert**, and the
audit had to come before the code to see that. `ae2be57cb` needs no port at all
(its FIX 2, the headless emulator + VT repaint on ATTACH, is shared Zig the
win32 agent has carried since it first built; FIX 1 is launchd), and the
delivery script already renames the running agent's exe aside instead of killing
it (T89h). The real gap was the other half of `c6ad0fc07`: **nothing ever
adopted the new binary.** The running agent keeps every PTY and serves forever,
so an agent-side fix reached the user only after a reboot — the Mac's 1.15.0
incident, one platform later.

- The decision is pure and unit-tested (`agent_upgrade.zig`): parse
  `--version`, order stamps by `YYYYMMDD`, `isStale` (null ⇒ pre-versioned ⇒
  stale, newer ⇒ never downgrade), `decide → none | refresh_now |
  confirm_first`. Idle restarts silently; live sessions get the mandatory
  confirmation CLAUDE.md requires, and a decline defers to the next idle moment
  instead of nagging.
- **Liveness is asked of the AGENT, not counted from this app's panes** — the
  one place a literal port would have been actively dangerous. At app quit every
  window is destroyed while its sessions stay alive on purpose, so a pane count
  reads 0 at exactly the moment a restart destroys the most work. Unknown
  liveness ⇒ do nothing: "we couldn't ask how much this would destroy" is never
  grounds for destroying it.
- Two more decisions worth their comments: the idle arm re-dials through
  `recoverLocalAgentInPlace` (no LIVE sessions still permits windows full of
  TOMBSTONES, which must be RELAUNCHed onto the new agent, not left on a retired
  connection), and a 2/run restart cap so a restart that doesn't cure staleness
  can't kill an innocent agent on every window close.
- `agent-upgrade.ps1` **ALL PASS (38) ×3**, measured by outcome — agent pids,
  dialogs on screen, panes that still answer. The contract assert is C5: the
  agent pid is unchanged *while the dialog is up*, i.e. consent comes before the
  destruction. D proves the accept path is in place (agent pid changes, app pid
  does not, pane responsive again); E proves the deferral promise is kept
  (decline, then the last pane closes ⇒ silent refresh, no second dialog).
- **Negative control, run for real:** with the check stubbed out the script
  failed *exactly* the six T147 assertions and nothing else — B and F still
  passed, so they are controls rather than filler.
- Staleness is faked with a **debug-only** `GHOZTTY_AGENT_BUNDLED_VERSION`: every
  stamp in a real build comes from the same binary the agent runs, so there is no
  way to fabricate an old agent from a new tree. Input only; the decision and the
  restart are the shipping ones.
- **The harness lied first, again.** Six assertions failed against a build whose
  correct `+list --json` output sat complete in the redirect file: a timed
  `WaitForExit(ms)` leaves `$p.ExitCode` empty unless `.Handle` was cached before
  the child exited. The durable lesson is the second fix, not the first — gate an
  oracle on the OUTPUT, never on a shell-plumbing detail. Filed as **T197**.
- Floor: both lanes + `test-agent` + P1–P3 green; `agent-recovery` (25) and
  `session-close` ALL PASS as regressions.
- Filed **T196** (deliver T145 + T147 to all 3 install locations — until then
  the mechanism that makes future agent fixes reach users exists only in
  zig-out) and **T197**; annotated **T125**, whose correctness half this closes,
  leaving the What's-new accessory and protocol-SKEW gating.

## 2026-07-30 - T196 field outcome: the dialog was working the whole time; the log just never said so

- **T196 delivery verified.** `%TEMP%\ghoztty-upgrade.log` ends `UPGRADE OK`, and
  `ghoztty +version` reports `1.4.0-users-dzearing-windows-amd64-+9968a62d9` —
  the installed release really is on the delivered commit, through the new
  `scripts/launch-upgrade.ps1` path (T200).
- **T147's field check came back as outcome 2, the contract-correct one:** the
  mandatory `GhozttyConfirmDialog` ("Restart the Ghoztty background terminal
  process?") was up, owner window disabled, body naming **4 open terminal
  sessions**. Answered **Later** — confirming would have relaunched all four as
  tombstones, including this loop's own pane. Agent pid **27568 unchanged**
  throughout; after the decline the log records `user deferred destructive agent
  refresh (4 live session(s))`. Consent before destruction held in the field,
  not just in the harness.
- Inputs measured rather than assumed: the running agent's HELLO advertises
  `build_version` **`20260728-349eba4f6`**, the bundled binary prints
  **`20260730-e69d41755`** ⇒ `confirm_first`. An agent from *two days* earlier
  had survived four binary swaps — precisely the gap T147 exists to close.
- **It read as the third outcome ("delivery did not take") for twenty minutes,
  and the diagnosis is the finding.** Two false negatives stacked: `Get-Process |
  Where MainWindowTitle` never surfaces an *owned* dialog (and this one sat on a
  second monitor), and a pending modal writes **no log line at all** — every
  message in `refreshLocalAgentIfStale` after `bundled agent build is …` is
  emitted only once the user answers, and the `.none` arm logs nothing ever. So
  "a correct confirmation is waiting" and "the check decided nothing" and "the
  check never ran" are one indistinguishable silence. Filed as **T201**.
- Durable probes, both cheap: read a running agent's build straight from its
  HELLO by opening the `pipe` in `port.json` with `NamedPipeClientStream` and
  dumping the first frame (`"build_version"` is plain-text JSON); enumerate an
  app's dialogs with `EnumWindows` by pid using **`CharSet=CharSet.Unicode`** —
  the Ansi default truncates every wide string to its first character, which is
  how the first pass printed `class=[G] title=[R]` and looked like garbage.
- T201 also carries a doc correction: `protocol.zig` claims a null
  `build_version` is "never treated as stale" and its test comment says "the app
  must treat null as not-stale", both contradicting `agent_upgrade.isStale`,
  which treats null as stale on purpose. The code is right; the comments invite
  someone to "fix" the policy backwards.

## 2026-07-30 - T201 done: the agent-upgrade decision now says what it decided, before it acts

- The policy returns **why** as well as **what**: `agent_upgrade.Reason` +
  `Decision` + `evaluate()`, with `decide()` reduced to a projection of it so
  every existing unit test still means what it did. `isStale` remains the sole
  authority on staleness and `evaluate` only classifies the *not*-stale case, so
  the two cannot drift apart.
- `refreshLocalAgentIfStale` logs the decision **at the point of decision**,
  with all four inputs, and `promptAndRefreshLocalAgent` announces the modal
  **before** `ConfirmDialog.show` blocks. Both silent early returns now speak —
  including the attempt ceiling, which the T147 comment already claimed was
  "logged rather than silently absorbed" and wasn't.
- Why it mattered: three distinct box states (`current`, `newer, don't
  downgrade`, `bundled unknown`) all collapsed to a `.none` that logged nothing,
  and the `confirm_first` arm logged only *after* the user answered a modal that
  can sit there forever. So "waiting on the user", "decided nothing" and "never
  ran" were one indistinguishable silence — which is exactly how a working
  dialog got mistaken for a failed delivery earlier the same day.
- `agent-upgrade.ps1` **ALL PASS (44)**, up from 38. The load-bearing three are
  C9/C10/C11: the decision line and the pending-modal line are asserted **while
  the dialog is still up**, and C11 re-checks the dialog is *still* up
  afterwards — so the ordering is proven, not assumed.
- **Negative control, run for real:** with both log calls stubbed and the GUI
  rebuilt, the suite failed **exactly** B7, C9, C10, E8 (4 / 40 passed). C11 and
  F4 still passed, so they are controls rather than filler, and no pre-existing
  assertion moved.
- Harness lesson: the exe under test is a **Debug** build, so `std.log` goes to
  **stderr** — the `%LOCALAPPDATA%\ghoztty\ghoztty.log` sink is release-only and
  drops `.debug` lines besides. Asserting against that file would have matched
  nothing forever and looked like a code failure. `Start-App` now captures
  per-arm stderr (read with `FileShare.ReadWrite`, since the app holds it).
- Floor at this change: `zig build -Dapp-runtime=win32 -Doptimize=Debug`, both
  test lanes, `zig build test-agent` all exit 0; P1/P2/P3 each `ACCEPTANCE: ALL
  PASS`.

## 2026-07-30 - T202 done: the tab strip stops stretching, and starts looking like a tab strip

The user screenshotted a single-tab window and named four things: a weird blue
line at the bottom, a "+" butt up against the tab and looking clipped, a
misaligned hamburger, and "HORRIBLY amateur ... like a backend developer built
the ui." Three of the four came from **one** rule: `paintTabBar` handed the
LAST tab whatever width was left, so a single tab spanned the window, which
flung the close button to the far edge, jammed the "+" against it, and
stretched the selection accent into a full-width blue rule.

- **Measured the target instead of quoting it.** Live Windows Terminal via
  `PrintWindow(PW_RENDERFULLCONTENT)`, read pixel by pixel: three tabs took
  900 px of a 1610 px strip and left ~700 px empty; the selected tab is a
  rounded-top chiclet filled with the CONTENT background; unselected tabs have
  no fill; there is no accent underline anywhere. Written up as
  `docs/design/win32-tab-strip.md` so T203/T204/T206 paint to one agreed
  target.
- Geometry extracted to a pure `tab_strip_layout.zig` (11 unit tests): equal
  share clamped to [60, 200] DIP, no remainder rule, tabs that do not fit get a
  zero rect rather than a rect under the buttons, the "+" travels with the last
  tab, the menu button is pinned right. The close box had been recomputed in
  three places; it is one function now, so paint and hit test cannot drift.
- The right-edge padding defect from the same live review landed here rather
  than in T204, because T202 had not been committed yet: `strip_pad_r` makes
  the strip inset the same at both ends.
- **Negative control, run for real:** `T202_NEUTERED = true` restores the
  remainder rule; rebuilt and re-ran `test/win32/tab-strip.ps1` — exactly the
  6 geometry assertions failed, the accent-rule / dead-space / many-tab /
  menu assertions still passed. Restored and rebuilt.
- Harness lesson worth keeping: `tab-color.ps1` and `window-title.ps1` fail
  on this box right now, and an A/B against parked pre-change sources proved
  the failures are identical at `HEAD`. A fullscreen Unreal title holds the
  foreground with `GameInputSvc` running — the documented input wedge, and
  the thing **T207** exists to fix. Do not attribute a keyboard-driven GUI
  failure to a code change without that A/B; it costs one rebuild and it is the
  difference between a real regression and a wasted day.
## 2026-07-30 — T204 + T206: the tab strip stops looking hand-assembled

Live user review drove both. On the icon buttons: *"icon buttons should have a
consistent design with consistent hover and centered icons … why doesn't the
chevron in the banner have a similar hover? why doesn't the x to close a tab
have a similar hover?"* On the tabs: *"don't you see how the edge of the banner
has this gradient highlight border? tabs should too, and inactive tabs should
be visible somewhat and tabs should have gaps in between. And the bottom
corners of the selected tab should curve into the edge."*

**T204** — new pure `icon_button.zig`: one shared square target, one rounded
fill, one per-state shade, glyphs centered on both axes. All four icon buttons
use it (the banner chevron was pulled into scope — it had no hover because the
overlay had no `WM_MOUSEMOVE` handler at all). Glyphs are stroked rather than
font characters, which drops T204's Segoe-Fluent-Icons deliverable along with
its tofu risk and decouples glyph size from the tab-title font.

**T206** — new pure `tab_shape.zig`: the strip's back buffer became a DIB
section and tabs are composited per pixel, the way `banner_card.zig` composites
the banner. Rim constants and the inactive-surface lift are *imported* from
that module, not copied. Selected-tab bottom corners flare concave into the
baseline; tabs gained a real `tab_gap` and lost the inter-tab hairline.

Tests: 26 new unit tests across the two modules, both lanes green, negative
controls `T204_NEUTERED` / `T206_NEUTERED`. Verified visually with a
`PrintWindow` capture (no focus steal).

**Not done, deliberately:** the on-box pixel assertions. Mid-task the user said
*"you KEEP STEALING FOCUS USE ANOTHER DESKTOP for testing"*, so the GUI scripts
were stopped. Filed as **T209**, blocked on **T207**. T207 is now the top
priority — it is infrastructure the visual tasks depend on, not a nicety.

Commit: `4565e4e42`.

## 2026-07-30 — T207 spiked and split (T211 / T212 / T213)

The "use another desktop for testing" question is answered, measured rather
than argued. `test/win32/test-desktop-spike.ps1` launches a real ghoztty onto a
background `CreateDesktopW` desktop and tests every mechanism the harness needs:
**ALL PASS (12 assertions) x3**.

Isolation is total — the window is not enumerable on the interactive desktop
and never becomes foreground there (sampled every 150ms throughout).

The two surprises both cut against the task as written:

- **Capture is fine.** T207 expected the pixel probes to be the casualty, since
  DWM composes only the input desktop. Half right: `CopyFromScreen`/`BitBlt`
  off the desktop DC is dead (BitBlt returns false outright), but
  `PrintWindow(PW_RENDERFULLCONTENT)` returns real content — mean luminance 246
  and 64 distinct colors off a `--window-theme=light` window, against the same
  OpenGL surface. So the probes migrate; they just cannot screenshot. No VM
  needed for them.
- **`SendInput` is the actual blocker.** Win32 refuses it off the input desktop:
  0 of 12 events accepted, `GetLastError` = 5 ACCESS_DENIED. All 36 driving
  scripts must switch to posted `WM_KEYDOWN` — which works, and so do modifier
  chords (`ctrl+shift+t` fired its keybind, tabs 1 -> 2) once the key state is
  set with `SetKeyboardState` on the input queue shared via
  `AttachThreadInput`. That contradicts the interactive-desktop lesson that
  faked key state never sticks: with no raw-input thread to overwrite it, it
  does.

Post only `WM_KEYDOWN`, never `WM_CHAR` as well — the terminal window class
skips `TranslateMessage` and calls `ToUnicode` itself, so posting both doubles
every character (the spike produced `sSpPiIkKeEbB` before that was understood).

Split into **T211** (shared harness: persistent worker thread bound to the
desktop, `Focus-TestWindow` replacing the 30 private `GrabForeground` copies,
`Send-TestKeys`, `Get-TestWindowPixels`), **T212** (migrate the driving
scripts; posted MOUSE input is still unproven and carries the risk), **T213**
(migrate the pixel probes, rebasing every screen-coordinate probe to
window-relative). T209 now blocks on T213 rather than T207.

Floor: both `zig build test` lanes and `test-agent` green. P1-P3 deliberately
NOT run — they `Start-Process` a GUI window, which steals focus, and this
change touches no product code.

Commit: `dfb0fa54c`.

## 2026-07-30 — T211: the shared test-desktop harness, and two things it found

`test/win32/lib/TestDesktop.ps1` ships. GUI acceptance scripts can now run on
a background `CreateDesktopW` desktop: one persistent worker thread bound to
it (SetThreadDesktop is per-thread and fails on a thread that owns windows),
with every desktop-side call marshalled onto it. `Focus-TestWindow` replaces
the T86 `GrabForeground` copies, `Send-TestKeys`/`Send-TestText` replace
SendInput with posted messages plus `SetKeyboardState` over the shared input
queue, and `Get-TestWindowPixels` replaces `CopyFromScreen` with
`PrintWindow(PW_RENDERFULLCONTENT)`. `-Interactive` /
`GHOZTTY_TEST_INTERACTIVE=1` is the documented debug escape hatch.

Two acceptance scripts: `test-desktop-harness.ps1` (the harness's own, 19
assertions, capture negative control built in) and `split-zoom-nav.ps1`
migrated as the proof-of-concept (20 assertions, `-NegativeControl` still
FAILS). Both ALL PASS x3, and the interactive-desktop foreground watcher never
once saw a harness-launched pid.

Two findings, both filed rather than left as lore:

- **A product bug (fixed here).** `App.performDeferredFocus` required
  `GetForegroundWindow() == root` (the T89f2 ping-pong guard), and a
  background desktop has NO foreground window — so every deferred focus was
  dropped and keyboard focus could not move at all. Now decided by the pure,
  unit-tested `shouldPerformDeferredFocus` plus a cached `onInputDesktop()`;
  the interactive path is unchanged. Sweep for siblings: **T215**.
- **T207's capture answer was too generous.** `PrintWindow` returns GDI
  chrome only; the OpenGL terminal surface reads as a flat fill (child window
  captured meanLum 255 / 1 distinct color, unchanged after typing). The
  spike's 64 distinct colors were its tab strip. Chrome probes (T213) are
  fine — a titlebar band separates light from dark at 240 vs 34. Terminal-
  content probes are **T214**, which T209 now depends on.

Floor: both `zig build test` lanes, `test-agent`, P1-P3, and the T207 spike
all green.

## 2026-07-30 - T212 split, and T216 answers the mouse question: yes

T212 (migrate every SendInput-driving GUI script) was one task over 65 files
and would not fit a context, so it is split three ways: **T216** prove the
mouse, **T217** the 23 keyboard-only scripts, **T218** the 12 mouse-driven
ones. T216 done here.

**The verdict is YES, on both counts that were in doubt.** Posted mouse
messages reach the app (a posted left click moved keyboard focus to the
clicked pane), and `TrackPopupMenuEx` runs perfectly well on a background
desktop - the `#32768` window appears, paints, and dismisses on a posted
Escape. `PrintWindow` reads it with real content (52 distinct colors), because
a menu is GDI chrome, which is the half of the capture limit that survives.
So **nothing routes to the T207 option-B bucket**; T218 can convert all 12.

Two things stood between that answer and a working `dark-menus.ps1`:

- **A product bug (fixed here).** `SetCursorPos`/`GetCursorPos` are dead off
  the input desktop, and `Surface.getCursorPos` answered a failed
  `GetCursorPos` with an error. That error came back out of
  `mouseButtonCallback`, `handleMouseButton` read it as "consumed", and the
  apprt only opens the context menu when the core returns UNCONSUMED - so
  right-click did nothing at all. The surface now caches the client position
  each mouse MESSAGE carries and falls back to it, which is the more accurate
  number anyway (queue-synchronized with the event, where `GetCursorPos`
  reports where the pointer is now). Not test-only: `GetCursorPos` also fails
  on a locked workstation, the secure desktop, and a disconnected RDP session.
- **A capture trap.** The first green run read `dark surface menu is dark
  (avg 0)` - a capture taken mid-paint is solid black, and solid black
  satisfies "is it dark?" for the wrong reason. Same menu: meanLum 0 / 1
  color at 350ms, meanLum 52 / 53 colors at 400ms. `Get-TestDistinctColors`
  is now in the harness and `dark-menus` polls for real content before
  scoring. Every migrated brightness probe needs the same guard.

Harness gained `Send-TestMouse` (posted, screen coords, converted per target;
`-Target` must name the window that would really have received the click,
since posted messages skip hit testing), `Wait-TestPopupMenu`, and
`Get-TestDistinctColors`.

`dark-menus.ps1` ALL PASS (10) x3 with stable readings (dark 52/49, light
240/244), `-NegativeControl` fails 2 of 8 as required, isolation asserted per
launch and across the run. Floor: both `zig build test` lanes, `test-agent`,
P1-P3 green.

## 2026-07-31 - T217 batch 1: four keyboard-only scripts off the user's desktop

`reset-window-size`, `font-inherit`, `ipc-version`, `ipc-child-exited` now run
on the T211 background desktop. 4 of 23 done; the remaining 19 are listed in
the task file.

Two of the four never had a `Start-Process` to convert: they let
`+new-window` AUTO-SPAWN the app, which puts the GUI on the user's desktop no
matter what the harness does. They now start it with `Start-OnTestDesktop`
first (config env inherits through `CreateProcessW`) and drive that instance.
All four also set `GHOZTTY_PIPE_SUFFIX` unconditionally - several only
isolated the endpoint when `-ExePath` was passed, so a default run talked to
whatever answered the shared pipe.

Harness gained `Set-TestWindowSize` / `Test-TestWindowZoomed` (the size
tests' oracle and their posted-key positive control), `Send-TestWindowClose`
(posted WM_CLOSE - a posted Enter/Escape never reaches a standard dialog,
which only sees translated messages), and `Get-TestWindowClass`. Its worker
now asks for per-monitor-v2 DPI awareness before falling back to
`SetProcessDPIAware`, so another process's window rect is never virtualized -
`reset-window-size` compares exact pixels.

What the migration found: `ipc-version` was asserting the About box is a
`#32770` MessageBox. It has been a native `GhozttyConfirmDialog` since the
T50 chrome pass. Nobody noticed because the old foreground grab kept losing
the race and the whole section took its `SKIP palette test` branch - on the
test desktop the chord always lands, so a section that had been silently
skipping started asserting. Assume every SKIP-able section has un-run
assertions in it.

Also cost one false FAIL: `@()` must wrap the CALL, not live inside the
helper. PowerShell unrolls a function's array return, and a one-element
result then arrives as a scalar whose `.Count` is `$null`, which reads as
"0 panes".

All four ALL PASS x3 (12 runs), negative controls fail as required, and every
run asserts - not assumes - that no test-desktop app ever took foreground on
the interactive desktop. Floor: both `zig build test` lanes, `test-agent`,
P1-P3 green.

## 2026-07-31 - T217 batch 2: three more scripts off the user's desktop

`window-size-memory`, `window-title` and `command-registry` migrated onto the
background test desktop; 7 of 23 done. Each ALL PASS x3, each with a new
`-NegativeControl` switch that fails as required (none of the three had one),
and each asserting - not assuming - that no test-desktop app ever took
foreground on the interactive desktop.

Harness gained the primitives a placement test needs: `Invoke-TestDragResize`
(WM_ENTERSIZEMOVE -> SetWindowPos -> WM_EXITSIZEMOVE) and
`Send-TestSysCommand` (WM_SYSCOMMAND), because the behaviour under test is
precisely that a USER resize persists and a programmatic one does not, so
`Set-TestWindowSize` cannot stand in for a drag. Plus
`Get-TestWindowNormalRect` (the restored size, readable while maximized),
`Get-TestWorkArea`, and `Get-TestControlText` / `Set-TestControlText`
(WM_GETTEXT / WM_SETTEXT). All of them route through one new
`SendMessageTimeoutW` helper - a plain synchronous send into a wedged app
would block the single worker thread the whole harness marshals through.

`Get-TestWorkArea` has to run on the worker thread rather than the host: the
work area is per-desktop and a background desktop has no taskbar, so the
interactive desktop's rectangle is the wrong thing to clamp-check the app
against.

What the migration found: `window-size-memory` is nondeterministic with
session persistence ON. Each section's app re-attaches to the surviving agent
and restores the layout manifest, whose geometry competes with the placement
memory the test is about - and the manifest write races the force-kill
between sections. It failed 6 assertions on its first run and passed the next
three; `--session-persistence=false` makes it deterministic. Note
`Kill-RepoInstances` does not close that hole: it kills `ghoztty.exe`, not
`ghoztty-agent.exe`. Second finding, same shape as batch 1's: deleting
`window-title`'s S3 SKIP branch took it from 39 to 50 assertions with no new
coverage written. The old foreground grab kept losing its race, and 11
assertions had simply never run.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green, and all six
previously-migrated scripts re-run green against the changed harness.

## 2026-07-31 - T217 batch 4: two more scripts, and the second mechanism limit

`clipboard-paste` (22 assertions) and `kb-actions` (42, up from 24) migrated
onto the test desktop, ALL PASS x3 each, negative controls FAIL. Harness gains
`Test-TestWindowEnabled` (modality: an owner window is disabled exactly while
its modal dialog is up) and `Send-TestInjectedChar`.

The batch's real finding is a **second measured mechanism limit**, alongside
the capture one: `SendInput(KEYEVENTF_UNICODE)` has no faithful replacement
off the input desktop. The obvious substitute - post
`WM_KEYDOWN(VK_PACKET, char in the lParam HIWORD)` - looks documented and
silently does nothing; the character never arrives, because a real packet
carries its 16-bit character out of band while a posted lParam has only an
8-bit scan-code field. A posted `WM_CHAR` to the same surface does arrive.
So `kb-actions`'s T64 section still covers the app's injected-WM_CHAR
handling but NOT `App.run`'s TranslateMessage exemption for VK_PACKET. The
assertions were renamed to say what they prove and the residue is filed as
**T222** (proposal: factor the `skip_translate` switch into a pure predicate
and unit-test it, which covers it with no desktop at all). Relabelling them
instead would have been exactly the vacuous assertion batch 3 warned about.
Measured in a throwaway probe rather than reasoned about, and written into
`lib/TestDesktop.ps1` as "MECHANISM LIMIT - VK_PACKET" so it is not
re-derived.

Second finding: **`keybinds-t01` is not a keyboard-only script.** Its "ctrl+c
WITH selection" section word-selects with a real SendInput MOUSE double-click,
and that section is live. T212's split misfiled it; it moved to T218 and
T217's denominator went 23 -> 22 (10 remain). Third: `kb-actions` went from 24
to 42 assertions with no new coverage written - three sections had silent SKIP
branches, same shape as batch 2's `window-title`.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green; all eleven
previously-migrated scripts re-run against the changed harness. Two reds in
that sweep, neither from this change: `ipc-version` compared the binary's
baked commit against HEAD and the exe was three commits stale (green after a
rebuild - a reminder that this assertion doubles as a stale-build detector),
and `remote-inherit`'s 3 are the known pre-existing T178.

## 2026-07-31 - T217 batch 5: the first batch the harness already covered

`claude-integration` and `new-window-cwd` migrated onto the test desktop; 14
of 22, 8 remain (one of them, `split-dim`, still blocked on T214). Both are
ALL PASS x3 - 36 assertions and 53 - and both negative controls fail with
exactly 1 failure. This is the first batch that needed **no**
`lib/TestDesktop.ps1` addition at all: batches 1-4 each hit a mechanism the
harness lacked, and this one was the mechanical conversion T212 predicted.
So there is no harness regression sweep in this entry, because nothing in the
harness changed.

The one real trap was self-inflicted and general: `new-window-cwd`'s `Assert`
wrote its PASS/FAIL line to the **pipeline**, and the migration put the
per-launch leak assertion inside `Launch`, which RETURNS the launched app. The
return value silently became `@('  PASS ...', $app)` and `$app.Pid` read
`$null`. `Assert`/`AssertEq` use `Write-Host` now. Any remaining script whose
helpers both assert and return has the same hole.

Two things the migration exposed rather than invented. `claude-integration`
now asserts the first-run prompt is **modal** (`Test-TestWindowEnabled` on the
owner window, up and down) - added to the harness in batch 4 and unused until
now - and its two palette sections no longer hide behind
`if (...) {} else { Assert $false }`. `new-window-cwd` stopped hunting for its
seeded window by pinned title: `+list --json`'s window `id` is the hwnd, so it
addresses the window by NAME and confirms the hwnd with
`Get-TestWindowClass`, then `Focus-TestWindow` + `Get-TestFocusedWindow` names
the pane ctrl+n actually inherits from. Batch 3 used that pairing to pick the
right pane within a window; here it picks the right **window**, where every
pane is an indistinguishable `cmd.exe`.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green.

## 2026-07-31 - T217 batch 6: two more scripts, and a product bug the move found

`agent-upgrade` and `session-reattach` onto the test desktop; 16 of 22 done, 6
left. `agent-upgrade` is ALL PASS (53 assertions, up from 45) x3 with its
negative control failing as required. `session-reattach` is **migrated and RED
on a new task, T223**, which the migration is what found.

T223: `App.performDeferredFocus` bypasses the T105 foreground guard off the
input desktop - `shouldPerformDeferredFocus(false, ...)` returns true
unconditionally, which is T215's fix and whose stated reason is sound (a
background desktop has no foreground window, so the guard would drop every
focus change and keyboard focus could never move). The assumption underneath it
was that the T105 two-window restore ping-pong needed foreground activation and
so could not happen there. It does not, and it does: focusFlips measured 34-40
in 3s across three runs, against a pre-T105 baseline of 36 and a post-fix 0.
`onInputDesktop()` is also false on a locked workstation, behind a secure
desktop, and in a disconnected RDP session, so this is a user-facing path -
the same shape of mistake as T216's `GetCursorPos`. The script keeps F10/F11
red and named for T223 rather than relaxing the bound; everything else in it
(A-E, F1-F9) passes.

The general lesson for the rest of T217: before trusting a green on the test
desktop, ask what the PRODUCT does differently off the input desktop.
`onInputDesktop()` in `App.zig` is the list of places to ask. Here the feared
outcome was a vacuous PASS (guard bypassed, every assert dropped, oracle proves
nothing) and the actual outcome was a genuine RED - both need the same question
asked. Corollary: `GetForegroundWindow` is null for EVERY window on a
background desktop, so any assertion built on it scores zero and passes
silently. `session-reattach`'s F11b ("foreground stays parked") was deleted for
that reason rather than relabelled; grep a candidate script for
`GetForegroundWindow` before migrating it.

Cheaper than expected: `session-reattach` drives everything through
`+list`/`+sessions`/`+read` and the on-disk manifest, so only its three
`Start-Process` GUI launches touched the desktop, and its 120-line private
`T105Drv` became four harness calls plus a 12-line `Measure-FocusFlips`. One
new harness primitive was needed - `Send-TestRawMessage`, a raw `PostMessage`
for the app's private `WM_APP+n` protocol (F11 seeds a co-pending pair of
`WM_APP_SETFOCUS` asserts; no user gesture produces that).

Also noted for later: `profile-latency` is at-risk like `split-dim`. Its
scroll positive control is a PrintWindow pixel hash of the TERMINAL surface -
the CAPTURE LIMIT case, where the two hashes would come back equal and the
assertion inverts rather than merely weakening - and it measures input latency
through `SendInput`, which a posted-key port would turn into a different
quantity. Decide that deliberately rather than converting it mechanically.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green.

## 2026-07-31 - T217 batch 7: relay-account + ipc-machine-chooser onto the test desktop

Two more keyboard-only GUI scripts migrated, 18 of 22 done. `relay-account`
ALL PASS (61) x3 and `ipc-machine-chooser` ALL PASS (45) x3, both negative
controls FAIL as required (1 failure, exit 1, each inverting a normally-passing
load-bearing claim: the account row flipping to "Sign Out", and T175's detail
pane following the selection).

The headline is what the migration DELETED. `ipc-machine-chooser` ended with
`if ($aborted) { "SKIPPED (foreground unavailable)"; exit 0 }` - a busy box
scored a green exit 0 having asserted nothing at all, and no suite driver could
tell. `relay-account` had the same shape per-section ("those sections need the
foreground; they SKIP, never fail"), which quietly removed its entire GUI half.
Both are gone: on the test desktop a chooser that does not open is a SETUP
FAIL. Grep a candidate for `exit 0` before migrating it.

Measured, not assumed: the chooser's pixel probes port unchanged. The accent
pill and its gutter, the column wash, the hairline rule, the empty filter's cue
banner, the wrapped status strip and the detail-pane region signature all give
the same verdicts through `Get-TestWindowPixels` (PrintWindow) as they did
through `CopyFromScreen` - 64 distinct colors, pill tint 47, gutter 0. The
CAPTURE LIMIT is about the OpenGL terminal surface, not native dialogs, and
this is the demonstration.

Three harness additions: `Send-TestControlClick` (BM_CLICK, sent so the handler
has run when it returns), `Invoke-TestMessage` (a SENT message returning its
RESULT - `Send-TestRawMessage` posts and returns a bool, which cannot answer
"how many rows does this listbox have"), and `Get-TestWindowStyle`. Both
scripts also gained the modality pair via `Test-TestWindowEnabled` - the owner
window is disabled while the chooser is up - which neither asserted before.

Filed **T224**: `overlay-zorder` and `profile-latency` are not mechanical
conversions and must not be treated as such. `overlay-zorder`'s entire oracle
is "the overlay sits BELOW the FOREGROUND window", and there is no foreground
on a background desktop; whether SetActiveWindow is a faithful stand-in (z-order
and WM_ACTIVATE both) has to be measured before a line of it is ported, or the
assertions invert quietly. That leaves `pane-banner` as T217's only remaining
plain migration.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green. Harness
regression after the three additions: `test-desktop-harness` (19),
`split-zoom-nav` (20), `confirm-dialogs` (27), `window-title` (50),
`command-registry` (22) all ALL PASS.

## 2026-07-31 - T217 batch 8: pane-banner, and the last plain migration

`pane-banner` onto the test desktop: **ALL PASS (65) x3**, negative control 1
FAILURE. 54 `Assert` call sites before, six of them behind a foreground-grab
SKIP - the whole ctrl+shift+b editor section, which on a busy box scored a
green exit having run none of it. That section now also asserts the editor is
MODAL, arrives PREFILLED with the current banner, and that its prefill is
SELECTED (a single posted WM_CHAR replaces it).

**This is the batch that pins down what the CAPTURE LIMIT is about: the OpenGL
surface, and nothing else.** Every pixel oracle here reads the banner overlay's
own GDI chrome - a WS_EX_LAYERED popup painting in WM_PAINT - and every one
produces the same verdict through `PrintWindow` as it did through
`GetDC`/`CopyFromScreen`: 64 distinct colors, card wash 30,30,34, band corner
16,16,20, shadow 12,12,15, 31 green pixels in the checkbox gutter. Measured
first, then asserted. A layered popup is not a special case for PrintWindow -
worth saying, because the old script needed `CopyFromScreen` precisely because
a raw screen-DC `GetPixel` skips layered windows.

The one oracle that could not survive the move was REPLACED, not relabelled:
T131's "composited pixel == own-DC pixel" (the proof the glass card is opaque)
has no meaning where there is no composite, so it became
`GetLayeredWindowAttributes` reporting alpha 255 / LWA_ALPHA / no colour key -
the state that made the two sides equal in the first place.

Harness: `Get-TestWindows` (all top-level windows of a class - "no overlay
windows remain" needs a count, not a first hit), `Set-TestWindowPos` (a MOVE;
`Set-TestWindowSize` deliberately never moves, and the move is what exercises
`WM_MOVE -> updatePaneBanners`), `Get-TestLayeredAttrs`, and **`Width`/`Height`
on `Get-TestChildWindows`** - missing, which cost two red lines reading
`"the pane really shrank ( -> px)"`. A `$null` property is a silent wrong
answer in PowerShell, and an empty interpolation in a FAIL message is the tell.

T217 closes at **19 of 22**: that is every script it can migrate. The other
three are each blocked on a mechanism decision owned elsewhere, so they moved
to **T225** (deps T214 + T224) rather than lingering as an open thread behind a
closed task - `split-dim` on T214, `overlay-zorder` and `profile-latency` on
T224.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green. Harness
regression - wider than previous batches, since `Get-TestChildWindows` is used
by every migrated script: `test-desktop-harness` (19), `split-zoom-nav` (20),
`confirm-dialogs` (27), `window-title` (50), `command-registry` (22),
`font-inherit` (25), `new-window-cwd` all ALL PASS.

## 2026-07-31 - T218 batch 1: the mouse half opens, and the synthetic double-click was a fiction

First two of the 13 mouse-driving scripts onto the test desktop:
`keybinds-t01` (30 assertions, ALL PASS x3) and `focus-defer` (11, ALL PASS
x3). Both negative controls FAIL. 11 remain.

`keybinds-t01` failed exactly one assertion on its first migrated run - the
ctrl+c-copy one, the only section that needed the mouse - and the product was
innocent. `Send-TestMouse -Action doubleclick` posted down / up /
**WM_LBUTTONDBLCLK** / up, which is what the OS delivers only to a
**CS_DBLCLKS** window. `GhozttyWindow` has that style (divider equalize); the
`GhozttyTerminal` surface class does not, and counts its own clicks from plain
button-downs. The posted DBLCLK went nowhere, the core saw one click, and no
word-select happened. `MouseEvent` now reads the target's class style
(`GetClassLongPtrW`) and sends the sequence that target would really get. T216
established that a posted click has to name the window a real click would hit;
this is the same rule for the message's identity, and `split-divider` (still
ahead in this task) is the CS_DBLCLKS side of it.

Two harness additions, both because `focus-defer` is a deadlock repro rather
than a gesture test: `Send-TestClickStorm` (unpaced posted down/up pairs -
`Send-TestMouse`'s ~100ms of per-click settling would stretch its 1500 focus
changes to four minutes and destroy the load shape) and
`Test-TestWindowResponsive` (the WM_NULL / SMTO_ABORTIFHUNG hang oracle).

Two things the move surfaced in the scripts themselves. `keybinds-t01` went
24 -> 30 assertions with no new coverage invented: nearly every section was
wrapped in an `if ABORT { SKIP }` and the foreground grab lost that race often
enough for whole sections to vanish from a "passing" run. And its ctrl+c/SIGINT
assertion still carried "KNOWN FAIL until the ConPTY ^C-signal task is fixed" -
T84 fixed that, it passes every run, comment removed.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green. Harness
regression after the doubleclick change: `dark-menus` (10),
`test-desktop-harness` (19), `split-zoom-nav` (20) all ALL PASS.

## 2026-07-31 - T218 batch 2: the tab-strip chrome trio, and three stale assumptions

`title-font`, `tab-color` and `tab-strip` onto the test desktop, taken as one
batch because all three read the same GDI-painted strip. 12 / 15 / 21
assertions, each ALL PASS x3, each negative control FAILS. 5 of 13 done; 8
remain (chooser-menu, context-menu, focus-follows-mouse, hero-mode,
host-settings, menu-bar, split-divider, window-color).

The migration was the plain recipe: PrintWindow for the probes (the tab strip
is chrome, the half of the CAPTURE LIMIT that survives), clicks POSTED at the
TOP-LEVEL window because that is what paints and hit-tests the strip,
`Send-TestControlKey` for the tab-color menu's first-letter matching, and the
cursor parking deleted outright - it existed so hover chrome could not pollute
a sample, and a background desktop has no pointer to park.

Everything that took real time was rot the migration exposed, and none of it
was a migration artifact - all three would fail on the interactive desktop
today. `tab-color` derived the bar height from the jump when a second tab
appears; since T190 the strip is up from the FIRST window on Windows, so the
pane never moves and `barH` came out 0 before a single tab-color assertion ran.
`tab-strip` compared the measured chiclet against `max_tab_w`, but the SLOT is
`max_tab_w` and the drawn chiclet gives up `tab_gap` of it - 243 measured
against 250 expected, tolerance 3. And `tab-strip` read the selected tab as
"first dark pixel until the first light one", which the chiclet's antialiased
rounded edge turns into a 1px-wide tab: it now takes the LONGEST dark run on
the scanline. The old scan got away with it on a screen grab, where that edge
blended differently - same claim, different pixels, which is the class of
difference a capture-path change is guaranteed to expose.

The rule that generalises: a geometry constant a script hard-codes is a claim
about the product, and an unrun script's claims rot silently. When a migrated
script's positive control fails, check the product's current geometry BEFORE
weakening the assertion - twice out of three here the script was wrong and the
product was right.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green.

## 2026-07-31 - T218 batch 3: the pointer pair, and two oracles a background desktop cannot hold

`focus-follows-mouse` (14 assertions, up from 11) and `split-divider` (29, up
from ~25) onto the test desktop, ALL PASS x3 each, both negative controls FAIL.
7 of 13 done; 6 remain (chooser-menu, context-menu, hero-mode, host-settings,
menu-bar, window-color).

These were the two T218 flagged to check first, because "SetCursorPos /
GetCursorPos are dead off the input desktop". Measured, and it corrects a claim
the harness header made: `SetCursorPos` returns FALSE on a background desktop
and `GetCursorPos` returns -1,-1. The header said the opposite. Corrected in
place.

The pair then split on exactly that question. `focus-follows-mouse` never
needed the cursor at all - `Surface.focusFollowsMouse` compares
`ClientToScreen(lparam)` against the last screen position, so the coordinates
travel IN the message and a posted move is the same evidence a hardware move
is. What posting does not reproduce is hit-testing, so each glide step is
addressed to the pane that CONTAINS it; naming the wrong pane would make the
app focus whatever it was told and the assertion would pass on a broken
product. `split-divider`'s four SIZENS assertions did need it and are gone
(T228): `WM_SETCURSOR` carries no coordinates, so the handler must read
`GetCursorPos`, and with nothing to read it falls through to DefWindowProc -
measured returning 0 at every point on the band. Four `WM_NCHITTEST` probes on
the pane replace them, reading the HTTRANSPARENT fall-through at the source.

The more interesting loss (also T228) is T155's cross-pane stale-line scan. It
counted divider-colored runs across both panes on the premise that a stale line
under a pane has been overpainted by that pane - a COMPOSITED-SCREEN fact, and
there is no composite here. A PrintWindow capture keeps every intermediate line
a drag ever painted: 3 drags, 13 runs, against a healthy product, and neither a
window move nor three resizes clears them. The scan now covers the
parent-visible strip between the pane rects and asserts the gap IS the band
plus the whole gap is one solid fill.

The rule that generalises: an oracle whose validity rests on one window
covering another is asserting something the capture path does not reproduce.
The screen-pixel controls go the same way - "is my probe occluded?" is
meaningless against a window capture, and becomes "did the capture hold real
content".

Also learned: `WM_NCHITTEST` is an underused oracle - the product's own
decision function, answerable cross-process, needing neither pixels nor a
cursor. And a posted down/moves/up drag on the TOP-LEVEL window is a faithful
divider drag, because `updateDividerDrag` reads the WM_MOUSEMOVE lparam and
consults neither MK_LBUTTON nor the cursor.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green.

## 2026-07-31 - T218 batch 4: the popup-menu pair, and a constant the product left behind

`context-menu` (37 assertions) and `menu-bar` (60) onto the test desktop, each
ALL PASS x3 with a failing negative control. 9 of 13 done; chooser-menu,
hero-mode, host-settings and window-color remain.

Both scripts were already 100% PostMessage-driven and neither ran on a
background desktop. What is desktop-bound is not INPUT, it is window
ENUMERATION: `EnumWindows`/`EnumChildWindows` walk the calling thread's
desktop, so every FindTop/FindPane/MenuWindow returned nothing. HMENU reads do
NOT move - a menu handle is not a desktop object - so both tree walks stay
in-process. The rule for the next batch is to ask what a call takes: HWND means
harness, a handle you already hold means local.

Two measurements that removed work. `context-menu`'s section A parked the
physical cursor before right-clicking, because the core resolves the clicked
word through `getCursorPos`; T216 had already given win32 a fallback to
`last_cursor_client`, so the posted click's own coordinates carry it and the
SetCursorPos call is deleted rather than replaced. That is the counter-case to
`split-divider`: a cursor-reading path CAN migrate when the product has a
message-derived fallback. And the clipboard is a WINDOW STATION resource, not a
desktop one, so both paste sections migrated untouched.

The interesting failure was not a migration artifact. `menu-bar` clicked a
hard-coded 46px left of the client's right edge to hit the "+", which encoded a
layout the product abandoned in T202 (a lone tab no longer stretches, so the
"+" travels with the last tab and sits ~260px from the LEFT) and was DPI-blind
besides - at 125% that offset lands inside the menu button, so the "+" click
opened the menu and no tab ever appeared. Five assertions failing against a
healthy product, invisible because the script had not been re-run. Replaced by
`Strip-Geometry`, `tab_strip_layout.zig`'s published model evaluated at the
window's DPI, self-checking because every consumer asserts an outcome. T231
filed to delete that duplication by having the product report its own hit
regions.

Two more SKIP branches retired, the batch-1 lesson again: A(pixels) dropped
GrabForeground+CopyFromScreen for PrintWindow (the strip is GDI-painted chrome)
so it always runs, and the alternate-screen setup became an assertion instead
of silently dropping three F10 assertions. Harness gained `Send-TestSysKey`,
one half of a WM_SYSKEYDOWN/UP pair at a time, because section G's contract is
about the PAIRING.

Floor: both `zig build test` lanes, `test-agent`, P1-P3 green. Harness
regression after the `Send-TestSysKey` addition: dark-menus, test-desktop-harness
and focus-defer all ALL PASS.

## 2026-07-31 - T230: an agent restart never re-runs your command again

User directive, verbatim: *"We should not ever re-execute the commands which
were previously ran."* Reaffirmed mid-turn: *"the app can reboot, that's fine,
but windows reopened should not try to rerun commands... some sort of session
was interrupted by an upgrade message, and should leave the user at a shell
prompt."* `session-relaunch` defaulted to `auto`, so every agent restart
(reboot, T147 agent upgrade) RELAUNCHed each pane's recorded command - 15
`relaunched dead session` lines in the on-box log, three of them in the single
boot after the 2026-07-31 upgrade.

New default `session-relaunch = notify`: the pane OPENs a brand-new session on a
fresh shell in the tombstone's recorded cwd, retires the tombstone, and prints a
notice naming the command it did NOT run. `auto`/`prompt` survive as opt-ins.
Wire change is additive only (`Attached.argv`, plus `cwd`/`argv` on the DEAD
reply) - an older agent omits them and the notice simply loses its command line.

Two things this turn measured that were not obvious:

- **The notice has to be written twice.** A fresh `cmd.exe` under ConPTY opens
  with a full-screen repaint that erases whatever the notice printed a moment
  earlier; printing it after the shell's paint would put it *below* the prompt.
  So it also goes up as an OSC 7778 sticky banner - a native overlay a screen
  clear cannot reach. Stream text = selectable/copyable; banner = guaranteed
  visible. `+list --json`'s `banner` field is what the test scores.
- **A recorded cwd that no longer exists killed the pane outright.** Arm C
  deleted the layout's working directory and got 0/3 interactive panes:
  `CreateProcessW` fails on a missing `lpCurrentDirectory`, so the OPEN never
  replies. `PtySpawner.resolveSpawnCwd` now falls back to `$HOME` /
  `%USERPROFILE%`. Pre-existing, and it hit `auto` (RELAUNCH) just as hard.

New `test/win32/session-relaunch-notify.ps1` ALL PASS (45), scored on the
process table (neither `ping -n <unique>` runs again), the per-pane banner (each
names its OWN command, no cross-talk) and pane responsiveness (3/3), with arm B
as the opt-in control (`auto` still respawns both). Harness trap re-learned the
hard way: `Start-Process -ArgumentList` quotes nothing, so a bare
`--command=ping -n 9749 127.0.0.1` was re-tokenized into four positional
arguments and every marker assertion failed against a working product. Second
trap: arms shared one `LOCALAPPDATA`, so arm C restored arm B's windows and
`+new-window --target=nA` merely FOCUSED the existing one - each arm now gets a
virgin state dir.

Floor: both `zig build test` lanes, `test-agent`, P1-P3, `session-relaunch`
(T89g) and `agent-upgrade` (T147, 53) all green.

Filed: **T236** (`auto-launch-cwd.ps1` B3 fails at HEAD - PRE-EXISTING, proved
by A/B against a short-circuited `resolveSpawnCwd`), **T237** (the bounded
`CLOSE_SESSION` RPC times out against the local agent even though the capability
is negotiated; T230 sidesteps it fire-and-forget, T146's Kill cannot), **T238**
(`terminal.PageList` "less rows trims blank lines" flaked once with exit 3 =
panic, passed on an immediate re-run).

T229's own half - the app disappearing after the confirm - is NOT closed by
this, but the user has explicitly downgraded it: an app reboot on agent upgrade
is acceptable to them, so long as nothing re-executes.

## 2026-07-31 - T232: the tab strip's gaps and glyphs, measured instead of intended

The user walked the strip pixel by pixel and every complaint was arithmetic.
Two independent root causes, both now named in `win32-design-system.md`:
**gaps were measured to the HIT BOX** (8 DIP of constant plus 5 DIP of
invisible slack per side, painting as 13 at 100% and 16 px at their 125%), and
**the band was too short for the control** (a 29 DIP band centering a 26 DIP
square, so its "padding" truncated to 1-2 px and landed differently at every
scale). A 16:1 ratio between two gaps that should both be on the 4 DIP scale.

So the numbers are derived now, not chosen. `bar_h` is
`tab_top_pad + pad_sm + icon_button.target + pad_sm` = 4 + 4 + 28 + 4 = **40
DIP**; `layout()` computes in painted edges and derives hit boxes at the end;
`hitBox()` is the exact inverse of `targetBox()` so the call sites never had to
learn a new convention. `tab_top_pad` 3 -> 4 and `text_pad` 10 -> 8, both of
which were off the spacing scale. `tabBarHeight()` stopped keeping a second
copy of the constant.

Glyphs became filled quads (`Polygon` + `NULL_PEN`, in the new shared
`icon_button_paint.zig`) instead of `CreatePen`/`LineTo`, whose dropped
endpoint and wide-pen bias were literally the "left half of the plus is shorter
than the right half" report. Every mark extent is **parity-matched to its
square's side**, which is what makes the centering exact arithmetic rather than
luck - and that corrected a rule the design system had written as "round to an
even number of pixels", the right instinct applied to the wrong quantity.

Mid-task the user caught the close "x" rendering as a **filled bowtie**: the
first cut read the 45° relation backwards, setting the corner offset `k` to
`1.5 * stroke_w` as though thickness were `k/sqrt2` when it is `k*sqrt2`. 2x
too heavy. Fixed to `k ~= 3t/4`, pinned by a test, and written up as design
system §4.3 - the arithmetic is not obvious and it will be met again by the
next diagonal glyph.

Evidence: both lanes + `test-agent` + P1-P3 green. `tab-strip.ps1` ALL PASS
(25) x3 at 125% including a new pixel section that measures the "+" off the
capture - `gapLeft=21 gapBot=15` (1.4:1, was 26:11 on the mark and 16:1 on the
square) and `armL=6 armR=6`. Negative control: `T202_NEUTERED = true` ->
6 FAILED / 15 passed, exactly the named assertions. `tab-color.ps1` (15),
`title-font.ps1` (12) after their DPI oracle moved to `/40.0`, `pane-banner.ps1`
(65).

Filed: **T239** (the banner chevron measures its arm thickness vertically at
45°, so it paints ~0.71x the stroke width the other three glyphs do - the same
class of one-control-disagreeing-with-the-set defect, found by the arithmetic
rather than by eye).

## 2026-07-31 - T232 delivered, and a near-miss the delivery itself caused

Installed release verified at `+de07541ee` == HEAD, so the T232 chrome fix is
on the box.

The delivery then exposed a loop-killer, filed as **T241** and put at the very
top of Current priorities. The upgrade's `reuse` path relaunches claude in-pane
but never updates the lock's `claude_pid`, so the lock kept the pre-upgrade pid
(22928, genuinely dead) while the live session was 13060. Five minutes later
the watchdog read that stale pid, correctly concluded the recorded owner was
gone, and took its `restart-in-pane` branch - which types a `.cmd` PATH into the
pane. The pane runs a Claude Code TUI, so the path landed in the prompt box as
text. `send-keys exit=0`. Nothing re-entered, nothing logged an error.

The loop survived only because the user saw the stray path and pasted it back.
That is the same silent-death mode that cost six days in July, arriving through
the supervisor that was built to prevent it - so it outranks the UI block.

`Test-OwnerAlive` is not at fault; it was handed a stale pid. Both halves need
fixing: the upgrade must hand the lock its new pid, and the watchdog must not
use the shell-prompt shim on a pane that already has a live claude (its `nudge`
branch is already right for that case).

## 2026-07-31 - T242: the selected tab's rim was tracing a seam, not an edge

*"the active tab seems to have a horizontal line at the bottom, making it feel
disconnected from the pane below."* Real, and it quietly undid T202: the whole
selection idiom is that the selected chiclet is filled with the CONTENT
background and MERGES into the pane, which is why there is no underline and no
accent bar. A line across its baseline puts the separation back.

The cause was a shape being asked to do two jobs. `sdTab` clips the silhouette
square at the baseline with a half-plane so the fill cannot paint past `bar_h`,
and the rim was derived from that same clipped field - so it faithfully traced
the clip. At the bottom row `sd = -1`, giving `rim = 1.0 * RIM_BOT (0.04)`:
about 10 levels of white across the tab's full width, and across the flares'
width too, since each flare box also stopped dead at the baseline.

Fix: coverage stays clipped, the rim does not. `sdTabRim()` is the un-clipped
field (body below the baseline as before, flare boxes now running to `b + rb`),
and `sdTab` is *defined as* `@max(sdTabRim(...), y - b)` so the two can never
drift apart. The rim then has only real edges left to trace - top corners,
sides, and each flare's outboard concave curve.

Not fixed by setting `RIM_BOT` to 0: that dims the rim up the tab's whole
height to hide one row of it, and the artifact returns the moment anyone tunes
it back above zero.

Measured both ways rather than assumed. `test/win32/tab-strip.ps1` gained
section 2c (the seam row must be no brighter than an interior row of the same
fill); rebuilt with the old math it reports `seam=33 interior=0` and FAILS -
(11,11,11) over a (0,0,0) fill, matching the predicted `0.04 * 255` to within
rounding - and with the fix, `seam=0 interior=0`. ALL PASS x3, negative control
still failing 1/26, P1-P3 ALL PASS, both test lanes + test-agent + the GUI link
green. The two new unit tests fail (and only those two) when the rim is put
back on the clipped field.

Filed **T243** on the way through: `zig build` on this box panics inside the
build runner - no diagnostic, no `error:` line - unless `ZIG_GLOBAL_CACHE_DIR`
is on the repo's drive. That knowledge lived only in a private session memory
and cost time again this turn, so build.zig should say it out loud.

## 2026-07-31 - T241: ask the pane who is listening, not the lock

The watchdog decided how to re-enter the loop by asking "is the pid I recorded
still alive?" - a question about a process, when the one that matters is about
the PANE. On 2026-07-31 that made it type the resume shim's PATH into a pane
running Claude Code, where it became a chat message: `send-keys exit=0`, no
error, nothing re-entered.

The lock's pid is stale for the whole window between a claude relaunching in
the pane and that session reaching go.md step 0. Correcting T241's own premise
on the way: the upgrade's `reuse` path did NOT cause it - the log reads
`UPGRADE OK (reused claude pid=22928)`, the pid the lock already held. Claude
22928 exited and 13060 started seven seconds before the watchdog fired. The
skew is general, so the fix had to be too.

New `scripts/go-loop-pane-probe.ps1` classifies a pane's tail as
claude/shell/unknown, with one rule doing the work: a shell prompt on the last
non-empty line WINS, because a live TUI always owns the bottom of the screen -
so Claude output above a prompt reads as "claude exited", not "claude is here".
The watchdog nudges on `owner_alive OR occupant == claude`, reserves the shim
for a real shell prompt, verifies the pane afterwards, and logs
`occupant=<who>` every tick. `go-loop-lock.ps1` gained `adopt` so a relaunched
claude in the owning pane can keep the lock.

`+list --pid` was the exact probe and could not be used: on a
session-persistence box every pane reports `pid: 0`, so it matches nothing
(**T244**). Building the negative control also surfaced that `+send-keys`
eats backslash escapes, so the shim path was typed raw - `C:\Users\tom\...`
arrives with a TAB in it; now escaped, and reproduced live before fixing.
**T245**: ghoztty CLI output redirected with `>` from PowerShell writes an
empty file (a pipe or cmd.exe is fine) - silent, and it cost two detours here.

Proved rather than argued: same scenario, old watchdog `ACTION
restart-in-pane`, new watchdog `ACTION nudge`. `go-loop-guard.ps1` ALL PASS
(103), with N2/N3 as the positive control that a genuine shell prompt still
gets the shim; its GUI sections now run on the T211 background desktop. Both
test lanes + test-agent + P1-P3 green.

## 2026-07-31 - T240: the menu was there, the workflow just never reached it

*"there is no right click context menu like in the mac version. WTF."* The
menu has shipped since T102, all 17 items in Mac order. It never appeared
because the win32 apprt showed it only when the core returned *unconsumed*,
and mouse reporting consumes a right-press - so the feature existed everywhere
except in the panes anyone actually uses.

Measured rather than assumed, and the measurement nearly went the wrong way
twice. A probe against a freshly launched Claude Code reported "mouse
reporting NOT active", which would have refuted the whole task; the pane was
still on the trust dialog. Past it, at the real prompt (v2.1.220): reporting
on, right-click consumed, no menu. Then a physical-input probe "reproduced"
the bug in a *plain* pane too - a false positive from the probe's own
oversized `INPUT` struct, which made `SendInput` accept 0 events and send
nothing. Hence the rule now written into the new script: **a synthetic-input
probe asserts a positive control first, or its negative result means nothing.**

The fix asks the core *before* it sees the press - `rightPressWouldReport` -
because asking afterwards is too late: the click is already reported and the
selection the menu would act on is already cleared. Only the `context-menu`
disposition diverts; `right-click-action = paste` still hands the click to the
app, reporting or not.

T240's own first lesson landed on T240: it cited the Mac source line but
modeled the framework calling it, and AppKit's documented right-click path
runs `NSView.rightMouseDown` -> `menuForEvent:`, not the reverse - which would
mean Mac suppresses the menu under reporting too. Unverifiable from this seat,
so it ships as the user asked for and **T246** has the Mac seat check it in
minutes.

New: `test/win32/context-menu-real-input.ps1` - physical SendInput on the
interactive desktop, ALL PASS (11), `-NegativeControl` 1 FAILURE. It exists
because `context-menu.ps1` is PostMessage-driven and structurally cannot see
this class of defect. That script's section D asserted the old behavior as
"Mac parity"; it is inverted, gated on the fixture printing `MOUSEMODE-ON`,
and paired with a new D2 (reporting + `paste` = no menu) so "a menu appeared"
can no longer pass on a fixture whose console mode never landed. Both test
lanes + test-agent + P1-P3 green.

## 2026-07-31 - T150: the picker set a background and left the text behind

The user asked for the context menu's *Background Color...* to come with "a
bunch of logic for remapping foreground colors to adapt". The menu and the
`ChooseColorW` picker already existed (T67); the adaptation was one third of
the way there. Ported the rest of Mac's `c3e9999e7` and closed a hole it does
not have:

- **Palette 16-255 was never revisited.** `applyBackgroundTint` adjusted ANSI
  0-15 and stopped, so 256-color content - prompt greys off the grayscale
  ramp, cube colors - kept the OLD background's lightness. Now regenerated in
  the same mutex hold via `terminal.color.generate256Color(..., harmonious)`,
  the base 16 kept as adjusted. Measured on box: index 250 on a `#f0f0f0`
  background goes 1.67:1 -> 10.6:1.
- **Truecolor was unreachable by any palette work.** A program that emitted
  `38;2;r;g;b` chose those channels for the background it saw at startup and
  is never told it moved. Push `min_contrast = 3.0` to the renderer, which
  adjusts per cell at draw time (the shared hue-preserving `contrasted_color`
  was already in the tree). Measured: `230,230,230` on `#f0f0f0` renders as
  `138,138,138` = 3.03:1, against a `minimum-contrast` default of 1.
- **`contrastForeground` could return a foreground UNDER the floor.** It
  picked black/white by Rec.601 lightness, which disagrees with WCAG across a
  band of mid-tones: `#777777` reads "dark", so it chose white at 4.42:1 when
  black gives 4.76:1. Now chosen by contrast, which is self-correcting for all
  16.7M colors the picker accepts - the worst case is the crossover
  background, and there both sides are 4.58:1. Mac has the same hole; **T247**
  carries it over.
- **`contrastAdjusted` could return a still-failing color.** Its hue-preserving
  L* search only ever moved AWAY from the background, and a saturated color
  clamps against the sRGB gamut before reaching the luminance it needs, so
  against a mid-tone background neither side has room. It now tries the other
  side and falls back to black/white - the same order of preference as
  `contrasted_color`. Found by the sweep test, not by inspection.

New: `test/win32/color-contrast.ps1` + `lib/paint-blocks.ps1`, ALL PASS (14).
None of this is visible in `+list --json`, so the oracle is a screen-pixel
read of a pane painted entirely in one color class at a time.

Three ways that script was green while proving nothing, all fixed in it:
**a block glyph cannot test minimum contrast** (`renderer/cell.zig:
noMinContrast` exempts every graphics element on purpose, so the band
rendered its raw color and would have called a working renderer broken);
**ConPTY reports a row count the app does not render** (66 vs ~53), so band
arithmetic off `[Console]::WindowHeight` aimed the probe into the neighbouring
band, which asserted fine - the fixture now paints the whole screen per step
and the probe needs no row math; and **`+new-window --target=` is idempotent
against a PERSISTED session**, so after the first run the fixture never ran
and the probe read the previous run's pixels - the harness now kills the
repo's agent too and launches with `--session-persistence=off`. That last one
is a trap for every acceptance script that reuses a target name.

Unit side: sweep tests over the full lightness range rather than handpicked
themes. Both test lanes + test-agent + P1-P3 green; `window-color.ps1` (T67)
still ALL PASS (14).

## 2026-07-31 — T235: tabs size to content, capped by proportion

The user, with a screenshot: *"in the tab control, you have tons of horiz
realestate, and yet you are truncating the tab text here."* The cause was
`max_tab_w = 200 DIP` from T202, doing exactly what it was written to do.
Replaced by the design system's §6b rule: a tab's preferred width is its
measured title plus padding, floored at `min_tab_w` and capped at **50% of the
tab run** — a proportion of the container, not a DIP constant — falling back to
T202's equal share only when the preferred widths do not all fit. The
anti-stretch rule (a tab is never handed the remainder) is untouched.

`tab_strip_layout.zig` stays text-free: `layout` takes a `[]const i32` of
preferred widths and `tab_count` is gone (the array's length is the count, so
the two cannot disagree). `paintTabBar` measures with `GetTextExtentPoint32W`
against the DC that already has the tab font selected. `Metrics.preferredWidth`
is written as the exact inverse of `titleRect` and a unit test pins that at
five scales — a pixel of drift there means a tab sized to its own preference
ellipsizes anyway.

Measured on the box at 125%: the long-titled tab 690 px vs the retired cap's
245, and the default-titled tab beside it 344 — i.e. **the ordinary default
title was already ~275 DIP, so the 200 DIP cap was truncating essentially every
tab the user had.** The screenshot was the general case, not an edge case.

Two lessons. The acceptance script could not see this bug at all until it had
**two different titles in one window** — every tab in it carried the same
shell-set title, under which a fixed cap and a content-derived width are
indistinguishable; section 7 now launches `-e cmd.exe /K title <long>` and
opens a second default-titled tab beside it. And the original T202 reasoning
was wrong in an instructive way: the Windows Terminal measurement was right,
but "equal-share-capped needs no text measurement in the layout module" was
*convenience* presented as a design rule. The module is still text-free; the
caller measures and passes the widths in.

Evidence: both test lanes + `test-agent` + the GUI Debug link green;
`tab-strip.ps1` ALL PASS (35) x3; source-level negative control
(`T202_NEUTERED = true`) 9 FAILED / 26 passed, failing exactly the width rules
and no others; P1–P3 ALL PASS. Follow-up T249 filed: a tab's width is now a
function of a string the shell rewrites constantly — observe whether the strip
visibly jumps before adding machinery to stop it.

## 2026-07-31 - T233: the divider was a hairline that only the cursor reacted to

User, walking the chrome: *"I think the splitter lines should be 2px and have a
hover color that emphasizes it. 'lights it up in dark' or 'darkens it' in light
modes."* Both halves checked out. `bandPx` was 1 DIP (Mac's `SplitView.swift`
1 pt, ported literally), and 1 DIP rounds to a SINGLE physical pixel at both
100% and 125% — the two scales most users run — so the control read as a
rendering artifact. And hovering it changed only the mouse cursor, which tells
nobody who is looking at the divider and shows up on no screenshot.

`bandPx` is now `max(round(2 * scale), 2)`, a **deliberate divergence from Mac**
recorded in `win32-design-system.md` §5 so a later parity sweep does not undo
it. `split_geometry.zig` gained the color half beside the geometry: `HOVER_DELTA`
(25) and `dividerColor(rest, dark, hot)`, whose SIGN convention is asserted
against `icon_button.fillDelta` rather than restated — only the magnitude
differs (25 vs 15), because a 2 DIP mark needs more delta to read than a 28 DIP
button fill. Which way to shade comes from the PANE background, not the OS
theme: a light terminal under a dark Windows theme is ordinary, and the divider
has to read against the panes it separates. A drag outranks hover, since the
pointer routinely leaves the band mid-drag and the mark must not flicker back
to rest under the hand holding it.

**A second defect surfaced only because the test could not see the first fix.**
The hover repainted through `layoutSplits`' `GetDC` + `paintDividers` shortcut,
looked right on screen, and was invisible to a `PrintWindow` capture: that path
draws straight to the window DC and never marks the region dirty, so the pixels
never reach the backing store. It is correct for its own job — a band that MOVED
has no dirty region to mark, because a child already covers its old spot — and
wrong for a band that only changed COLOR. Now `refreshDividerBand` invalidates
that one band's rect and lets the normal paint cycle do it.

**And a harness limit that had to be measured, not assumed.** A posted
`WM_MOUSEMOVE` cannot hold a hover on the background test desktop: a debug log
on both sides shows `divider hover=0`, then `WM_MOUSELEAVE` within one frame,
then `divider hover=null` — `TrackMouseEvent` watches the REAL cursor and there
is none there (`SetCursorPos` fails off the input desktop). The band is back to
rest before the first capture 60ms later. Not a product defect; on a real
desktop that leave IS the un-hover. So the claim is proved in two halves: the
COLOR by pixels mid-DRAG (`dragging_split` does not depend on the cursor and
runs through the same one hot color), read rest → hot → rest from one probe at
three moments, and the TRIGGER by the debug-log oracle.

Evidence: both test lanes + `test-agent` + the GUI Debug link green;
`split-divider.ps1` ALL PASS (38, from 30) with `-NegativeControl` still
failing; P1–P3 ALL PASS. Measured at 125%: band 3px, where the retired formula
gave 1px. The PowerShell mirror of `bandPx` must pass
`[MidpointRounding]::AwayFromZero` — .NET defaults to banker's rounding and
125% lands exactly on the midpoint, so the naive form expects 2px where the
product correctly paints 3.

## 2026-07-31 - T233 delivery verified on the box; T241's last open item closed, T253 filed

Verification pass, no product change.

**T233 landed.** `ghoztty +version` reports `1.4.0-...-+efaa7f151` for both the
installed binary and the running instance, matching HEAD. `test/win32/split-divider.ps1`
is ALL PASS (38 assertions) with every T233 assertion green: the band measures
3px at 120 dpi (2 DIP, never a single physical pixel), rest is the configured
gray, a move onto the band sets the hot state, leaving drops it, and the band
stays lit through a drag.

**T241's "still open" item is now observed rather than predicted.** The lock's
`claude_pid` (13060) is the claude that actually owns this pane - confirmed by
walking the session's own ancestry from inside it, not by trusting the record -
and `pane_id` matches `$GHOZTTY_PANE_ID`. The watchdog's pane probe logged
`occupant=claude (lock owner_alive=True)` and took the nudge branch; the shim
branch that caused T241 was never reached. Evidence written into T241.

**What the same pass turned up: T253.** The tick that logged `occupant=claude`
also re-entered, because the heartbeat had been stale since 16:31 - nothing
refreshes it *during* a turn, and the T233 delivery ran 46 minutes past its
step-6 heartbeat. So a healthy long turn draws a nudge, and that nudge types
`read go.md and go` + Enter into a session that is still working, where it
queues and starts a second task in a context that was supposed to reset.
`Test-PaneProducing` does not catch it: five lines, 8 seconds apart. Filed with
the sketch (beat the heartbeat from a hook that already fires, widen the probe,
make the resume prompt reset-first so a wrong nudge is merely expensive).

**T234 turned out to be sized on a false premise, so it split: T254.** T234
opened with *"we do own the caption bar ... a paint + hit-test change, not a
new mechanism."* We do not: every window is plain `WS_OVERLAPPEDWINDOW`, there
is no `WM_NCCALCSIZE` anywhere in `src/apprt/win32/`, and T78/T203 only ask DWM
to restyle *its* caption. **T205 had recorded exactly that a day earlier and
the two files never met.** The custom caption is now T254, built once for both
callers; ordering settled as T254 -> T234 -> T205.

**T254 is implemented.** `WM_NCCALCSIZE` hands the caption band to the client
area (with the maximized frame inset), `caption_layout.zig` lays it out to the
design system (36 DIP = 4 + 28 + 4, the shared 28 DIP square, 4 DIP between
painted edges, hit boxes that reach the top-right corner for Fitts' law but
never overlap), `WM_NCHITTEST` answers `HTTOP*`/`HTCAPTION`/`HTMINBUTTON`/
`HTMAXBUTTON`/`HTCLOSE` — `HTMAXBUTTON` being what keeps Snap Layouts alive —
and the three buttons paint through the same `paintIconButton` the strip's
"+"/"≡"/"×" use. Green: all three zig lanes, `test/win32/caption-bar.ps1` ALL
PASS (14) with a failing `-NegativeControl`, P1-P3 ALL PASS, plus a
`PrintWindow` capture read at 125%.

**It is not `done`, and the floor is not green: T256.** Moving the strip off
client `y = 0` broke the two scripts that measure it from there —
`tab-strip.ps1` 7 failed, `menu-bar.ps1` 19 failed. That is T232's recorded
blast radius arriving one task late (it changed the strip's ORIGIN, not its
height). T256 repairs them self-relatively and then closes T254; it is the next
task ahead of everything.

**Also filed: T255.** The caption buttons' `SC_*` effects cannot be adjudicated
on the background test desktop — a *plain* `WM_CLOSE` is ignored there too on a
long-lived window, though a fresh one closes fine. So `caption-bar.ps1` SKIPs
that section behind a positive control and says so, rather than passing
quietly. Two design-system amendments landed with the work: closed-outline
glyphs use a **1 DIP** stroke (2 DIP on a 10 DIP box reads as a filled square —
it shipped for one build), and §6's "host chrome in the caption bar" is now
actually possible.

## 2026-07-31 — T256: the scripts measured the strip from a datum that had moved (and one that had changed underneath them)

T254 moved the tab strip off client `y = 0`, and the two scripts that derive the
strip's band from the client rect's own top failed against a correct build —
`tab-strip.ps1` 7, `menu-bar.ps1` 19. Repaired, and **T254 is now `done`**;
the standing floor is green again.

`tab-strip.ps1`'s scale came from `barH / 40.0`, so with the caption band folded
into the measurement it reported **2.375 at a real 1.25** and every DIP constant
in the script was wrong by 90%. Scale now comes from `Get-TestWindowDpi` — the
same `GetDpiForWindow` the app derives `Window.scale` from — `$capH` is
`caption_layout`'s own construction at that scale, and the strip's height is the
REMAINDER up to the pane child's top. The old "the bar is visible" positive
control became `barH == 3*sm + sq`: measuring the strip and checking it against
its own construction catches a wrong caption offset instead of letting it skew
silently. `menu-bar.ps1` needed one `Caption-Height` helper in the two places
that turn a strip y into a screen y.

**That fixed 15 of the 19 — and the remaining 4 were never about the caption.**
`Strip-Geometry` re-implemented `tab_strip_layout`'s tab SIZING to find the "+",
and T235 had changed that rule one task earlier: ~250 px modelled (equal share,
capped at the retired 200 DIP) against a real content-sized ~344 px, so the "+"
click landed back inside tab 1, no tab was ever created, and four assertions
downstream of "a second tab exists" fell with it. **A script cannot re-derive a
width that comes from text metrics, and it should not try** — T249's point,
arriving early. The tab run is no longer modelled: only the right-anchored
button band is derived, and the last tab's painted right edge is measured off a
capture by scanning leftward from the menu button along a row below the "+"
glyph's extent. `Start-Gui` gained `--background=#000000` to make that scan
safe — an inactive tab's fill is the strip lifted by `INACTIVE_LIFT` (6% of
white), ~14 levels on a dark strip and ~1 on a light one. Its `$btnW` was also
still 36 DIP, the pre-T232 hit box; gaps are measured against the 28 DIP painted
square.

Green: `tab-strip.ps1` ALL PASS (35) and `menu-bar.ps1` ALL PASS (60), x3 each,
both negative controls still failing; `caption-bar.ps1` ALL PASS (14) and P1-P3
ALL PASS; both `zig build test` lanes first try.

**Also filed: T258 — `zig build test-agent` is flaky, and it was found the hard
way.** It went red on a two-`.ps1` diff, on a DIFFERENT assertion each time:
`FLOW pause halts streaming` (expected 6, found 0), then `client DATA reaches
the child`, then green on the third run. Both are `remote/agent/server.zig`
ConPTY round-trip tests and both read a short buffer rather than a wrong one —
the T89b timing lesson recurring. A floor lane that fails 2 runs in 3 trains the
next turn to re-run until green, which is how a real regression gets waved
through.

**Filed: T257.** This is the second chrome change to break scripts that each
re-derive the same datum privately, and after this repair both still carry their
own copy of the caption height, the bar height, the button band and a tab-run
pixel scan — two implementations of one measurement. Hoist it into
`TestDesktop.ps1` before T205 moves the datum a third time.

## 2026-07-31 - T234: the strip was spending 40 DIP of every window to display a choice that did not exist

The user's ask, and it was correct on all three counts: *"don't we own the
header? can't we put a '...' button to the left of the minimize button, and use
that space? Then we do not need to use tabs by default, wasting precious
vertical space. The mac client does not use tabs by default."*

Shipped as ONE change, because it is one change. The strip could not go away
while it was the app's only menu host - that is exactly what pinned
`window-show-tab-bar = auto` to `=> true` on Windows from T190 until now. So
`auto` is now `tab_count > 1 or !customCaption()`, and the menu moved into the
caption as a fourth button.

**Measured on the box at 125%: the pane's top sits 45 px under the client top
with one tab (that is `caption_h`, i.e. no strip) and 95 px with
`--window-show-tab-bar=always`. 50 physical px - 40 DIP, 2-3 rows - returned to
every window, permanently.** A second tab takes it 45 -> 95; closing back
returns it to 45.

Three decisions inside the button that were not obvious going in:

* **`pad_md` (8), not `pad_sm` (4), between "..." and minimize.** Ours and the
  OS's are different GROUPS of controls, and four evenly spaced squares is
  precisely the undifferentiated cluster the "+"/hamburger pair was reported
  as. Asserted between PAINTED edges in the unit test and as a plain-chrome
  pixel in `caption-bar.ps1`.
* **It answers `HTSYSMENU`** - Windows' own code for "the control that opens
  this window's menu". Reusing it rather than inventing a private hit code is
  what keeps the button on the same non-client mouse path as its neighbours and
  announcing itself correctly. Its one piece of `DefWindowProc` baggage, that a
  double-click there means `SC_CLOSE`, is swallowed at the DBLCLK site.
* **It does not get the corner.** Fitts' law gives the top-right to close, so
  the "..." sits left of the whole system trio and its hit box reaches no window
  edge. A destructive button and a menu button must not be reachable by the same
  careless throw of the pointer.

The strip's own hamburger was **kept** - the second of the two answers T234
allowed - and the why is filed as **T260**: it is still the only menu host on a
caption-less window (`window-decoration = none`), so it has to become
*conditional*, and conditional changes `runWidth`, the datum three acceptance
scripts key off. Recorded as a deferral, not as "fine as is".

Green: new `tab-strip-autohide.ps1` ALL PASS (13) x3 with its negative control
failing; `caption-bar.ps1` ALL PASS (17); `tab-strip.ps1` (35) and `menu-bar.ps1`
(60) still ALL PASS; both `zig build test` lanes, `test-agent` and the win32 GUI
build green; P1-P3 ALL PASS.

**The new glyph test was proved to run rather than assumed to.** Breaking its
quad count made the none lane fail with `expected 4, found 3`; then it was
reverted. A new test in a module reached only through `apprt.zig`'s test-root
list is exactly the kind that can silently not be compiled in.

**Filed: T259 - `tab-color.ps1` has been red since T254/T235, and T234 did not
break it.** It measures the strip as `paneTop - clientTop`, which since T254 is
`caption_h + bar_h`, then derives `scale = barH / 40` and rebuilds the tab width
from T202's retired equal-share rule. On the box it printed `barH=45`
(= `caption_h` exactly; the strip is 50) and `scale=1.125` against a real 1.25.
Before T234 the same expression returned 95, giving `scale=2.375` - so it cannot
have been right at either value. Same defect T256 fixed in the two scripts it
did cover; do it with T257 so the count of private copies goes to zero.

**T137, second sighting, and it cost an hour.** `--session-persistence=off` is
swallowed by the bool parser, and the resulting persistence-ON window is **not
focusable at all** on the background test desktop: `Focus-TestWindow` returned
false five times running against a window with a perfectly good visible pane,
and every keyboard-driven assertion was unrunnable. Changing that one flag to
`=false` fixed it with nothing else touched. A swallowed bad value for a KNOWN
key does not fail where you can see it - it surfaces as an unrelated-looking
harness failure two layers away. `caption-bar.ps1` was still passing `=off` in
two places and is corrected.

## 2026-07-31 - T257 + T259: four scripts each kept their own copy of where the chrome is

The turn opened by verifying the T234 delivery the way a delivery has to be
verified: `ghoztty +version` read back `+5ad81a99e`, then the installed release
was actually looked at. A brand new window shows no tab strip (the pane starts
at the caption's bottom edge) and the caption carries `...` immediately left of
minimize, which opens the window menu; a second tab brings the strip back.
`tab-strip-autohide.ps1` against the installed exe: ALL PASS (13).

One note for whoever screenshots the chrome next: a real screen grab
(`CopyFromScreen`) captures the caption and the banner but returns the terminal
body as a flat fill, exactly like `PrintWindow` does. That is the CAPTURE LIMIT
the harness already documents, not a rendering bug - proved by capturing a
second window known to have visible content and getting the same flat body,
while `+read` showed the pane's text was there all along.

**T257 + T259 (done together, as T259 asked).** The datum moved twice - T254
moved the strip off client `y = 0`, T235 changed what sizes a tab - and each
time it cost a pile of failures in scripts that each re-derived it privately.
The hoist is `test/win32/lib/ChromeGeometry.ps1`, dot-sourced from the end of
`TestDesktop.ps1` (a sibling, not 200 more lines in a file already at 1910; every
consumer gets it with no second load line). It draws one line explicitly:
positions and gaps are DERIVED from DIP constants the way the layout modules
derive them, and tab widths are MEASURED off a capture, because they come from
text metrics and a script cannot reproduce them.

Private copies went to **zero**, from four scripts rather than the two the task
scoped - `tab-strip.ps1` and `menu-bar.ps1` as written up, plus
`tab-strip-autohide.ps1` and `tab-color.ps1`. `menu-bar.ps1`'s `Strip-Geometry`
went from ~55 lines to ~15; its leftward tab scan generalized into
`Get-TestTabExtents` (every chiclet's left/right/center), so there is one scan
implementation instead of two, and `Get-TestTabRunRight` is now the last
extent's right edge.

**A latent bug fell out of the hoist, which is the argument for doing it.** The
layout modules round with Zig's `@round` - half away from zero. PowerShell's
`[math]::Round()` is BANKER'S rounding. `menu-bar.ps1` had passed
`MidpointRounding::AwayFromZero`; the other four had not. The two agree at
100/125/150/200% because nothing lands on .5 there, which is precisely why four
scripts carried it unnoticed, and they disagree at 112.5% where `4 * 1.125` is 4
in PowerShell and 5 in the app. Four private copies meant four chances to be
wrong and no way to notice; one copy means one place to be right.

Two assertions got stronger rather than merely relocated, both where a loose
bound existed only because the exact number was out of reach without another
private copy: autohide's "plausible strip" (`barH` in 30..56 DIP) and
tab-color's `barH` in 20..80 are both `-eq bar_h` now.

**T259's second half is the one worth remembering.** `tab-color.ps1` derived
`scale = barH / 40.0` from a `barH` that was really `caption_h`, getting 1.125
against a real 1.25, then rebuilt the tab width from T202's retired
equal-share-clamped-to-[60,200] rule: 225 px against real chiclets of 346 and
344. A ~120 px error, which is why every right-click landed on empty strip. It
was not repaired, it was deleted - the tabs are measured now. The INFO line
reports `scale=1.25` and `tab0=[5,351) tab1=[357,701)`, identical across three
runs while the screen-relative click points track the window, so the
measurement is stable rather than accidentally passing.

Evidence: `tab-strip.ps1` 35, `menu-bar.ps1` 60, `caption-bar.ps1` 17,
`pane-banner.ps1` 65, `context-menu.ps1` 42, `tab-strip-autohide.ps1` 13, and
`tab-color.ps1` 16 x3 - all ALL PASS, all five negative controls still failing.
Floor: both lanes exit 0, `test-agent` exit 0, P1-P3 ALL PASS. The win32 lane's
first run failed on `remote.agent.server.test.METRICS_SUB ...` and passed on
re-run - **T258's known flake**, and this change touches no `.zig` at all.

**Filed: T261 - `/reset-context` reports FAILED on a reset that fully worked.**
Found as a live banner on the go-loop pane at the start of the turn, telling the
user to recover by hand. The log shows `/clear` verified, the continuation typed
and submitted, and the failure declared two seconds later - while the pane tail
in that same log shows `ctx: 0k/1000k` and a `Frolicking...` spinner, i.e. a
freshly cleared session already working on the continuation. The oracle greps
the last **25** lines for the prompt's first 24 characters, and a submitted
prompt scrolls out of that window the moment the model starts responding. The
probe races the model and loses when the model is quick; the `sleep 2` before it
makes losing more likely. This matters beyond noise: go.md's one allowed
exception is a failed reset, so a false FAILED can stall the loop in exactly the
way step 7 exists to prevent.

**Filed: T262 - `zig build` panics when `ZIG_GLOBAL_CACHE_DIR` is unset.** The
none lane's first run this turn did not fail, it panicked (`reached unreachable
code` in `build_zcu.obj`, then `unable to read results of configure phase`),
which reads like a compiler bug or a source error. Reproduced deliberately in
both directions on the same HEAD: unset -> exit 1 + panic (twice, fresh cache
tmp each time, so not one poisoned entry); set to `D:\zig-global-cache` -> exit
0. `zig build --help` exits 0 unset, so a quick sanity check misses it. Same
shape as the `-First N` warning already in go.md, which was mis-filed twice as a
transient flake before someone wrote it down; this one is undocumented and will
be misread the same way.

## 2026-07-31 - T260: two buttons, one band apart, opening the same menu

Taken ahead of T205, which is the UI block's next item, because T205 merges the
tab strip INTO the caption row - and merging first would have put the strip's
"hamburger" and the caption's "..." eight DIP apart in ONE row, which is the
undifferentiated-cluster complaint at its worst. The `has_menu` plumbing this
needed is also exactly what T205 needs.

The strip's menu button is now conditional on there being no other host:
`stripHasMenu() == !customCaption()`, the same rule the caption uses to decide
whether IT hosts the menu. It could not simply be deleted - a
`window-decoration = none` window has no caption, and the strip is the only
menu host it has, which is why T234's visibility rule already read
`tab_count > 1 or !customCaption()`. Dropping it hands the tab run back exactly
one 28 DIP square and one 8 DIP group gap (asserted at four scales), so tabs
get wider, which is T235's direction.

Two things it turned up, both filed:

**`Send-TestMouse` cannot click caption-band chrome (T263).** It posts CLIENT
mouse messages; since T254 the caption band is client area that the window
claims back through `WM_NCHITTEST`, so a real click there arrives as
`WM_NCLBUTTONDOWN` and the harness sends nothing the app handles. Cost a full
red run - 17 failures - while the pixel probe said the glyph was painted where
the metrics put it and F10 opened the same menu. Worked around by asking the
app for the hit code and posting the NC pair (`caption-bar.ps1`'s idiom), but
it matters far more for T205: every strip click in four scripts moves into that
band.

**A private copy of the button band, again (T264).** `tab-strip.ps1` asserted
the run against `clientW - padR - 2*btn - gap` - two buttons, restated locally,
three weeks after T257 deleted four copies of the same kind of thing. It reads
`RunRight - gap` from the shared module now. The last copy, in
`caption-bar.ps1`, is T264.

The decision T260 asked for, on `menu-bar.ps1`: NOT moving the whole script to
a caption-less window. The window a user runs has a caption, and moving the
script off it would leave the mainstream case untested. The script asks the
WINDOW where its menu host is instead, so every content section is unchanged;
section A gained the T260 assertions on the normal window, and a new section H
runs one `--window-decoration=none` window to prove the strip KEEPS its button
where nothing else hosts the menu. H is the load-bearing half - without it,
every A assertion would pass just as well against a build that deleted the
button outright.

Evidence: menu-bar.ps1 ALL PASS (71, up from 54) with its negative control
still failing on exactly the one ink assertion; tab-strip.ps1 37,
tab-strip-autohide.ps1 13, caption-bar.ps1 17, tab-color.ps1 16, all ALL PASS;
both zig test lanes exit 0; test-agent green on re-run after the known T258
ConPTY flake; P1-P3 ALL PASS.

## 2026-07-31 - T205: two rows of chrome could never line up, so there is one row now

The user's complaint was an alignment one - *"the hamburger icon ... doesn't
horizontally align under the X above it"*, sent with a screenshot of Windows
Terminal as the reference. The alignment was the symptom. Ghoztty drew a caption
row and a separate tab strip beneath it: two runs of controls owned by two
layouts, which can only ever *approximate* each other, and the approximation
drifts with DPI and with the caption button width. It is not fixable by nudging
x coordinates.

The tab run lives in the caption band now, on a window that owns its caption and
has a strip. Measured at the user's 125%: chrome went from 95 physical px to 50,
**45 px of terminal back on every multi-tab window**, and the alignment became
structural rather than approximate.

Two decisions carry the whole change:

**Chrome that shares a row shares a baseline.** The caption buttons take
`btn_top` from the STRIP's own derivation - `icon_button.targetBox` of
`tab_strip_layout.buttonHit` - not from centering a 28 DIP square in the 40 DIP
band. The "+" and the tab close "x" have been on that frame since T204;
centering would have landed 2 px off it, i.e. reproduced the user's complaint
inside the fix. `caption_h` is likewise `tab_strip_layout.bar_h`, one number
from one module.

**Two painters, one row, disjoint blits.** `Layout.band_left` is the seam: the
strip paints and BitBlts `[0, band_left)`, the caption `[band_left, client_w)`,
and `Window.stripClientWidth` hands the strip `band_left + strip_pad_r`, which
is exactly the width at which a menu-less strip lands the "+"'s painted limit ON
the seam (asserted, not assumed). Both fill the identical background so the seam
is invisible; what it buys is that a caption repaint - a hover on close - cannot
erase a tab, and the paint ORDER stops mattering.

`ncHitTest` gained `client_right` so the strip's controls answer HTCLIENT in the
band (otherwise every tab would drag the window). It is a parameter rather than
a Layout field because the "+" travels with the last tab, whose width comes from
text metrics that module never measures - so `Window` passes the rect the strip
PUBLISHED, the same one `handleTabBarClick` reads, clamped to the seam so a
stale rect can never swallow close.

**T257's prediction paid out exactly.** Two app files, and one new argument
(`-StripVisible`) across `lib\ChromeGeometry.ps1` and its nine call sites.

It also charged interest, and that is the lesson worth keeping: **two scripts
had never controlled their own window size** and had been inheriting
`window_placement-debug` (T85) from whichever GUI script ran last, so their
conditions depended on RUN ORDER. `tab-strip.ps1` went 3 red on a default 782 px
client - every condition it sets up is a ratio OF THE TAB RUN and it was not
controlling the input that ratio is taken of - and `menu-bar.ps1` went 2 red on
ink probes that assumed a wide strip. Both size their window now; filed as T267,
because nobody clears that file and the sweep is wider than these two.

Two more script corrections T205 forced, both of which would have been GREEN and
empty: `menu-bar.ps1`'s `StripRightX` was aiming at the caption's close button
(a posted CLIENT click cannot press one, so "nothing happened" would have passed
forever), and its blank-ink control probed `cw / 2`, which stopped being blank
when the strip's half of the row shrank. The control is `Strip-Geometry`'s
`DeadX` now - blank by construction, not by luck.

Follow-ups: **T265** (a pinned window title has nowhere to paint on a merged
row - matches WT, but ghoztty documents the pin, so the decision is recorded
rather than drifted into), **T266** (the top resize edge now sits ON the tabs;
almost certainly correct, but the thickness has not been measured against the
reference), **T267** (above). **T258** gained new evidence: the win32 test lane
HUNG on `remote.agent.server.test.FLOW pause`, 3400/3467 passed, flat CPU for
six minutes - so that flake is not confined to `test-agent` and not confined to
failing.

Evidence: chrome-merged-row.ps1 ALL PASS (19) with its negative control failing
as required; tab-strip.ps1 37, tab-strip-autohide.ps1 15, menu-bar.ps1 71,
caption-bar.ps1 17, tab-color.ps1 16, all ALL PASS; both zig test lanes exit 0;
test-agent exit 0; P1-P3 ALL PASS.

## 2026-08-01 - T229: the confirmed agent upgrade that took the app with it

Shipped both halves the task asked for, plus a third the investigation forced.
The third is the interesting one: **the log sink was silently losing lines**.
`ghoztty.log` is appended to concurrently by the GUI, the agent and every
one-shot `ghoztty +...` CLI, and the writer did `createFile` + `seekFromEnd` +
`write` - two writers that both resolve end-of-file to N both write AT N.
Measured against the real release binary with a negative control: 24 concurrent
`+list` runs, pre-fix 214 of 216 lines, fixed 216 of 216. That is the sink
T229's own primary evidence ("the app never logged another line") was read
from, and it would have defeated every diagnostic added for it.
`FILE_APPEND_DATA` fixes it; `test/win32/log-append.ps1` guards it.

The rest: the retired connection's teardown moved OFF the GUI thread
(`Connection.shutdown` JOINS four peer threads, and a peer that does not exit
wedges the app with no log line and no crash - the observed signature); a step
trail through the destructive restart so a hang names the step it stopped in;
`recoverLocalAgentInPlace` returns `?usize` with no silent exits, including the
`orelse return` the task is named for; an explicit failure dialog instead of an
empty desktop; and a refresh-in-progress guard so the app cannot quit itself
mid-rebuild.

**Not proven, and said out loud:** the field failure was never reproduced -
four shapes on box (fresh window; restored windows with 3 live sessions across
2; the same streaming; the same under a genuinely older agent binary) all
rebuilt correctly. It did NOT crash, though: no WER event exists for
`ghoztty.exe` near any of the three confirms. So it exited cleanly or hung, and
the async teardown is a fix for the leading hypothesis. **T268** is the runbook
for the next occurrence.

Its other lesson is testability: **the release lineage cannot be tested on this
box at all** while the user's agent runs - the single-instance guard is a named
mutex keyed on the user SID with no Windows override (its POSIX sibling has
one). The test-spawned release agent yielded only because the redirected
LOCALAPPDATA also hid the heartbeat; with it visible and stale, the run would
have killed the user's real agent. **T269**. And a harness lesson: a blind
`Tab`+`Enter` on the confirmation can land on *Later*, so the run measures the
decline path while asserting about the accept path - and passes.

Follow-ups: **T268** (diagnose the next occurrence from the step trail),
**T269** (release-lineage testability), **T270** (the log still has no
timestamps or pids).

Evidence: agent-upgrade.ps1 ALL PASS (82, was 53) with new arms H (the user's
restore+busy shape) and I (re-dial made impossible; must log the ABORT, show the
dialog, stay up); log-append.ps1 ALL PASS with its pre-fix negative control
failing as required; both zig test lanes exit 0; test-agent exit 0; P1-P3 ALL
PASS.

## 2026-08-01 - T218 batch 5: a dialog key posted at the dialog is a key the drop-down never sees

The chooser pair - `chooser-menu` (37 assertions, was 34) and `host-settings`
(65, was 60) - onto the background test desktop. 11 of 13 done; `hero-mode` and
`window-color` remain. `ipc-machine-chooser` (T217) already drives the same
Ctrl+Shift+N surface, so the mechanics were the plain recipe and everything
interesting was in three places.

**Post a dialog key at the FOCUSED control, not at the dialog.**
`host-settings` A(3) asserts that Enter/Escape with the shell drop-down open
belong to the LIST, and `HostSettingsDialog.handleKey` implements that by
returning **false** while the combo is dropped - so the key falls through to
`msg.hwnd`. Posted at the dialog, that fall-through goes to the dialog and the
drop-down never sees it: the assertion still passes, having measured the
harness. `Get-TestFocusedWindow` first, then post there, is what a hardware
keystroke does. (Corollary, measured: both dialogs run the nested-modal-pump
shape, which runs `TranslateMessage` over what it does not consume - so a posted
`VK_BACK` still becomes a WM_CHAR and the "clear both fields" section needed no
workaround.)

**`Find-TestWindowEx` IS the direct-child filter.** An editable COMBOBOX owns an
inner EDIT, so "the dialog's own Edit" cannot come from `Get-TestChildWindows`
(EnumChildWindows walks every descendant). The old script hand-rolled a
`GetParent` filter; `FindWindowExW` already enumerates direct children only. No
harness addition - the fix was reading what the existing helper does.

**Two more SKIP-on-a-busy-box branches retired**, and one of them was worse than
batch 1's: `host-settings` printed `ALL PASS (0 assertions, 1 skipped)` and
exited 0 whenever another window held the foreground. Its remaining skip (the
fake relay port already in use) now exits 1 - box state that prevents every
assertion is not a pass.

First batch with no product bug and no harness change.

Evidence: chooser-menu ALL PASS (37) x3, negative control 1 FAILED / 36 passed;
host-settings ALL PASS (65) x3, negative control 1 FAILED / 64 passed; no
launched pid ever seen on the interactive desktop; both zig test lanes exit 0;
test-agent exit 0; P1-P3 ALL PASS.

## 2026-08-01 - T218 batch 6: the capture limit is a property of the painter, and the task closes

The last two mouse scripts - `hero-mode` (63 assertions) and `window-color`
(22, was 14) - onto the background test desktop. **13 of 13; T218 is done.**
Both were the ones earlier batches had flagged as *maybe not migratable*, and
they resolved in opposite directions from the same rule.

**`hero-mode`'s carousel oracle survives, and it is the best pixel evidence in
the fleet.** The column has no child HWND: `HeroCarousel.paint` draws into the
PARENT window's DC inside BeginPaint, and every thumbnail refresh goes through
`InvalidateRect` - so it lands in the backing store PrintWindow reads, unlike a
GetDC paint (T233). The tiles ARE terminal content, moved across the boundary by
the app itself: each pane's renderer captures its GL output into a DIB
(`Surface.heroSnap*`) and the GUI thread blits it with GDI. Measured: 101
distinct colors in the column, signature changing while a busy TUI runs in a
HIDDEN pane. **Ask which thread painted the pixels, not which technology
produced them.**

**Three assertions could not come across, all aimed at a `GhozttyTerminal` child
directly** - `hero-mode`'s two `Get-PaneColorCount` probes and `window-color`'s
composited pane-centre probe. Dropped in place with the reason in each script
header, never weakened into something a flat fill could pass. That is now T214's
whole remaining pixel scope, and its question 1 is answered for both scripts it
named as candidates.

**`window-color` shows the third route working.** Losing its only "the color
reaches the pixels" oracle would have left the tint asserted only in
`+list --json`. `Surface.refreshBannerColors` colors the pane banner from
`background_tint orelse config.background`, and the banner is a GDI-painted
layered popup `pane-banner.ps1` already pins to the pane background exactly - so
the script raises a banner on the tinted pane and reads the band corner:
`#334455` -> `51,68,85`. Labeled for what it is: the tint escapes the data model
into painted pixels, NOT proof that the GL clear color changed. **When an
app-side capture is not worth building, look for another consumer of the same
value that the app already paints natively.**

Two PowerShell 5.1 traps, one run each, both silent: a function's `return @(...)`
UNROLLS, so a one-element result arrives as a scalar whose `.Count` is `$null`
and `$null -eq 1` is a quiet FAIL (`return , @(...)` fixes it); and the comma
binds tighter than `+` in an array literal, so `@($a + $x, $b + $y)` throws
`op_Addition`.

Two more SKIP branches retired - `hero-mode`'s palette section (silent), and
`window-color`'s picker section, which is the inverse failure mode worth naming:
it skipped AND incremented the failure count, producing an unexplained red with
no assertion attached. A skip that swallows assertions is useless whichever way
it scores.

Filed onward rather than left loose: **T267** gains two more instances (neither
script sizes its own window; `hero-mode`'s divider drag and pixel-signature
bounds are absolute numbers under an inherited client size), and **T258** was
reproduced a third time, identically - same two `remote/agent/server.zig`
assertions, same order, 2 of 3 runs, on a diff of two `.ps1` files.

Evidence: hero-mode ALL PASS (63) x3, negative control 1 FAILED / 62 passed;
window-color ALL PASS (22) x3, negative control 1 FAILED / 21 passed; both
scripts score their capture's distinct-color guard before any pixel oracle; no
launched pid ever seen on the interactive desktop; `zig build test` both lanes
exit 0; `test-agent` exit 0 on run 3 (runs 1-2 are T258, above); P1-P3
ACCEPTANCE: ALL PASS.

**Post-batch sweep, same day.** With T217 and T218 both closed the fleet-wide
claim became *"the acceptance scripts no longer steal the user's foreground"* -
so it got checked instead of assumed. Five scripts still call
`SendInput`/`SetForegroundWindow` without the harness; three are deliberate
(`profile-latency` measures injection timing, `context-menu-real-input` exists
precisely to click for real, `test-desktop-spike` measures the desktop) and
**two are plain misses that T212's split never bucketed**: `overlay-zorder`
(T142) and `split-dim` (T74). Filed as **T272**, which also asks for the
exception list to be DECLARED and enforced by a check - an undeclared exception
is indistinguishable from a miss.

## 2026-08-01 - T213 done: the migration had landed, the CONTROL had not

T213's own work turned out to be already done - T216/T217/T218 each swept the
pixel probes in their batch, so `CopyFromScreen` survives in comments only.
Verified rather than assumed: all 8 chrome probes ALL PASS **x3** on the test
desktop (dark-menus 10, confirm-dialogs 27, config-errors 15,
ipc-machine-chooser 45, tab-strip 37, menu-bar 71, pane-banner 65, hero-mode
63). The 9th, `profile-latency.ps1`, stays put - it hashes a `GhozttyTerminal`
child, which PrintWindow flat-fills, and T214 already owns it.

What the verification found is the entry worth keeping. `test-desktop-harness.ps1`
- the script that proves `Get-TestWindowPixels` returns real chrome for all 8 -
compared `--window-theme=light` against `--window-theme=dark` and the two now
read the **identical** caption band, rgb 60,64,72. Since T254 client-painted
the caption and T205 merged the tabs into it, the band derives from
`background` (+20/channel) and neither painter reads `window-theme` at all;
the `DwmSetWindowAttribute` calls still fire and paint nothing. **T273.**

**It failed HALF green.** The light side (`> 150`) went red on 71 while the
dark side (`< 100`) stayed PASS on those same pixels - so a discriminator that
had stopped discriminating entirely still produced a green assertion, and that
green was evidence of nothing. A two-sided control is only a control if the
SEPARATION is asserted; that assertion (`light - dark >= 100`) is now there,
and it is the one the regression could not have survived. Re-pointed at the
input the band really derives from, it reads 243 vs 24 and the harness is ALL
PASS (20).

Reading the painters for that answer surfaced a second, independent defect:
the band is derived but every foreground on it is a frozen constant chosen for
a dark bar (title/active label/button glyphs `230,230,230`, inactive label and
close glyph `150,150,150`). At `background = ffffff` the band clamps to white
and those land at **1.25:1** and **2.96:1** against a mandatory 4.5:1 - an
ordinary light config, not a corner case. **T274**, with the fix scoped as one
resolver rather than five edits, and T150/T247's color-math bugs flagged so
they are not ported in.

Evidence: 8 scripts x3 ALL PASS as above; test-desktop-harness ALL PASS (20)
with the new separation assertion; `zig build test` both lanes exit 0;
`test-agent` failed run 1 on `remote.agent.server.test.client DATA reaches the
child` and passed runs 2-3 - T258 again, same assertion, unchanged by this
diff; P1-P3 ACCEPTANCE: ALL PASS.

## 2026-08-01 - T214: the capture limit is now refused by class, not remembered

The open half of T214 was a decision, and a decision that lives only in a
header regrows. Finished question 1 by reading all 22 pixel-probing scripts'
capture targets rather than inferring them: 20 probe chrome, and the terminal-
content set is `profile-latency.ps1`'s scroll hash plus **`color-contrast.ps1`,
which every previous sweep missed** - including T272's, whose pattern was
"grabs foreground". That script grabs none; it reads `GetDC(NULL)` + `GetPixel`,
which is dead off the input desktop for an entirely different reason. Being
un-runnable in the loop is the property that matters, and stealing focus is
only one cause of it. **T276.**

Question 2 is answered as four ordered routes, written where the next author
will be standing (`lib\TestDesktop.ps1`'s CAPTURE LIMIT header): ask which
thread PAINTED the pixels; substitute another native painter of the same value;
drop the assertion in place with its reason; or declare it interactive by
design. Route 0 - an app-side GL readback over IPC - is deliberately not built
for 3 assertions and 2 scripts that all had a cheaper route, and it is filed
as **T275** rather than left implicit, with the observation that makes it cheap
when it comes: `Surface.heroSnap` already crosses the GL->GDI boundary, so what
is missing is a way to ASK for the snapshot, not a way to take one.

The enforceable half is the point. `Get-TestWindowPixels` now REFUSES a
`GhozttyTerminal` capture by class, up front - a flat fill is a perfectly valid
bitmap, so there is nothing to detect after the fact, and refusing by class is
the only place the check can work. All 29 existing call sites audited: none
targets a terminal child, so the guard costs no migration.

And the header's prose became three measured assertions in
`test-desktop-harness.ps1`, on a pane that has just echoed a token: the guard
refuses; a forced capture reads **1 distinct color, meanLum 255**; and it is
the SAME 1 color and 255 after more output renders. That last one is the
required negative control in its stronger form - the fill is shown not to move
AT ALL while the pane renders, so a probe there does not fail loudly, it passes
against nothing. The positive control sits in the same run: chrome separates
light caption from dark by 219 levels.

T209 was recorded as blocked on this answer. It is not: all nine of its
assertions are GDI-painted chrome, which is the half that captures. Said so in
its file.

Evidence: `test-desktop-harness.ps1` ALL PASS (23, up from 20); `zig build
test` both lanes exit 0; `test-agent` exit 0; P1-P3 ACCEPTANCE: ALL PASS.

## 2026-08-01 - T224: the ACTIVE window is a measured stand-in for the foreground, and two product bugs fell out of validating it

`overlay-zorder.ps1`'s whole oracle was expressed against
`GetForegroundWindow`, which is 0 for every window on a background desktop.
The stand-in is `GetGUIThreadInfo.hwndActive`, and the point of this task was
to MEASURE that it is faithful before porting a line. It is: `Focus-TestWindow`
really raises the window inside the band (oz2 active `ov=3 A=4 B=1`; activate
oz1 and A goes above B), and it really delivers WM_ACTIVATE - an injected
stray topmost heals on activation alone, and `Window.healOverlayZOrders` has
exactly one caller in the tree, the WM_ACTIVATE handler. So section D ports as
a proof rather than an approximation.

Two things did NOT port, named with their measurements instead of weakened.
The sandwich is no longer the section-B repro: topmosting the overlay also
raises its OWNER, unopposed where no window holds the foreground, so `Sandwich`
reads `0:` in the healthy AND the injected state. The repro is now z-index
against the active window (healthy `ov=3 > B=1`, injected `ov=0 < B=4`) plus
`WindowFromPoint` - both equally true on the interactive desktop, so the port
did not fork the oracle. And the `SWP_SHOWWINDOW` lift does not reproduce at
all: re-showing the overlay with the product's own flags put it back at the
same index.

The one that would have silently killed the migration: **`Focus-TestWindow`'s
boolean return is not the activation oracle.** Without `-Child` it returns
False on a ghoztty window, because the app moves focus to the terminal child.
The old script aborted the run on `GrabForeground`'s return; a mechanical port
of that gate aborts every run and prints no verdict.

`profile-latency` is decided, not migrated: interactive by design, already
declared in the harness header. `split-dim` is the last one left (T225/T272).

Validation kept the T217 bar and then turned up two product defects. **T277**:
section E needs a legitimately-topmost owner and the app cannot reach one -
the bound `toggle_window_float_on_top` leaves `WS_EX_TOPMOST` clear (with a
`new_window` control keybind proving the keybind path works), an injected
`HWND_TOPMOST` does not stick either, and a plain `charmap` window in the same
harness keeps it in every condition. E skips loudly and names T277 rather than
failing the T142 heal for someone else's bug. **T278**: P2 and P3 failed on a
CLEAN tree, and the cause was not their verbs - the debug agent had filled its
256-session cap entirely with dead pinned tombstones, so every new pane came up
with no child and nothing said so (`--session-persistence=false` was the
control: `+read` exit 0, marker present). Sidelined the file; the reaper is the
fix.

Evidence: `overlay-zorder.ps1` ALL PASS (24) x3, `-NegativeControl` FAILS on
the inverted new oracle; `pane-banner.ps1` ALL PASS (65) after the
`lib\TestDesktop.ps1` additions; `zig build test` both lanes exit 0;
`test-agent` exit 0; P1-P3 ACCEPTANCE: ALL PASS.

## 2026-08-01 - T225: the last GUI script migrates, and its "terminal-content" blocker was never terminal content

`split-dim.ps1` was the final entry on T217's un-migratable list and T272's last
miss. It had been blocked since T214 on one assertion: run 3 sampled the
COMPOSITED SCREEN (`GetDC(NULL)` + `GetPixel`) at the dimmed pane's centre and
asserted "red-tinted", and there is no composited screen off the input desktop.

The blocker dissolves under T214's own first route. **Ask which thread PAINTED
the pixels.** The dim overlay is not the terminal - it is its own top-level
window that the app's GUI thread fills with a solid GDI brush (`DimOverlay.zig`
WM_PAINT / WM_ERASEBKGND `FillRect`), so `Get-TestWindowPixels` on the
`GhozttyDimOverlay` reads the real fill. Measured before a line was ported:
`255,0,0` under `--unfocused-split-fill=#ff0000`, `16,16,20` under a defaulted
fill on `--background=#101014`. Three tasks had carried this as a
terminal-surface probe (T214's table, T225's own blocker table, T276 item 3)
because it *sampled over* the terminal; what it sampled was a window in front of
it. **Where a probe reads is not what it reads.**

What the substitute does not cover is named in the header rather than assumed
away: DWM's composite of fill and alpha - what the eye sees. Both INPUTS to that
composite are asserted (painted fill, `GetLayeredWindowAttributes` alpha) and
the blend is Windows' own, not app logic. The old check was the weaker of the
two anyway: it asked whether one pixel leaned red; this pins the exact color.

A uniform fill is 1 distinct color by design, so `Get-TestDistinctColors` is no
guard here. The guard is that the SAME probe reads two DIFFERENT colors under
two configs - which is why run 1's background is now pinned to `#101014`, and
that turns "the fill defaults to the background color" from a header comment
into an exact assertion the script never had.

Also filed while auditing: **T262 is a duplicate of T243** (`zig build` panics
opaquely without `ZIG_GLOBAL_CACHE_DIR`), marked
`skipped(duplicate -> T243)` with its evidence folded in. It bit again at the
top of this turn - the first `zig build` panicked, was re-run verbatim as a
suspected transient, and panicked identically. Two turns hit that wall, neither
found the other's task, and both filed: documentation that must be *found* keeps
failing here, which is the argument for T243's fix (a real diagnostic from
`build.zig` at the moment of the panic) over another note.

Evidence: `split-dim.ps1` ALL PASS (29, up from 23) x3, `-NegativeControl` FAILS
on the inverted fill oracle and reached it; `Test-TestDesktopLeak` false at every
launch and the sampled foreground watch saw no launched pid; no
`lib\TestDesktop.ps1` change, so no harness regression surface; `zig build test`
both lanes exit 0; `test-agent` exit 0; P1-P3 ACCEPTANCE: ALL PASS.

## 2026-08-01 - T210: the resume prompt died on the last argv hop, and the echo check that saw it was written as a shrug

The 2026-07-30 delivery reported `LAUNCH OK`, `exe swapped`, `UPGRADE OK`, and a
correct `+version` - and the context was never reset. What arrived in the pane
was the TAIL of the prompt as prose, submitted as an ordinary message; the
session ran to ~250k.

**Root cause: PowerShell 5.1 does not escape an embedded `"` when it builds a
native command line.** Not MSYS, not length. T200 moved the launch onto
`-ResumePromptFile` so free text never travels through argv; the prompt then
reached the pane as a positional `+send-keys` argument - the one hop further
down, and the identical defect. Measured with an argv oracle: `%VARS%`, `+`,
`-Flag` and `'single quotes'` are safe; a `"` or a trailing `\` breaks the child
outright. End to end into a raw-console capture, `/reset-context settle the
"DWM/PrintWindow" ...` arrived 130 -> 128 chars with both quotes gone, exit 0.
And `resolveArgument` concatenates positional arguments with NO separator, which
is precisely the field signature `come after.read go.md and go`.

The length theory is dead, measured: byte-exact at 1222, 2500, 5000 and 10000
characters. The tracker's "keep resume prompts SHORT" mitigation was aimed at the
wrong suspect and is withdrawn. A leading slash command is fine at every size.

Shipped: `+send-keys --keys-file=<path>` sends a file's bytes VERBATIM (no key
notation, no escape processing) and keeps its position among the positional
arguments, so `--keys-file=p.txt Enter` sends the file and then the CR. Zero
protocol change. `New-LoopPromptFile` / `Test-LoopPromptArrived` in
`loop-session.ps1` are the one copy of the transport and the comparison, shared
by the upgrade script, the watchdog and `go-loop-exec.ps1`.

Two things worth keeping. **The gate had to move BEFORE the Enter.** The obvious
fix - fail if the prompt is not in the tail after sending - would fail a correct
delivery, because `/reset-context` clears the pane on purpose and erases its own
evidence. Type, verify, then submit; and on failure do not submit at all, so no
fragment concatenates with the watchdog's next nudge. **And the old check could
never have passed anyway**: it did an exact `IndexOf` against a tail where the
input box has wrapped the prompt across lines. It failed on healthy deliveries,
which is *why* it had been written as "the TUI may have consumed it" instead of a
gate. Fixing the oracle is what made the gate possible - a check that cries wolf
gets demoted to a comment, and then the one real wolf walks past it.

Evidence: `ipc-send-keys-fidelity.ps1` (new) ALL PASS 19 - byte-exact capture via
`[Console]::ReadKey($true)`, and every keys-file case has a live
positional-argument negative control with the same payload (130->128, 97->91),
because otherwise green cannot distinguish "the fix works" from "this payload was
never broken". `upgrade-no-fork.ps1` ALL PASS 118: new section M (the transport +
the wrapped-tail oracle + its pre-fix `IndexOf` oracle) and new section E, the
end-to-end gate control - a swallow process consumes input without echoing it, so
the send succeeds and the text never appears, and the run must exit nonzero
without logging `UPGRADE OK (`. Section B's E2E prompt is now hostile; the old
`T138-REUSE-PROMPT` was a quoteless single token that argv could not break, so
the E2E had been blind to the defect that mattered. Both lanes + `test-agent` exit
0; P1-P3 + `go-loop-guard.ps1` ALL PASS.

Two asserts first passed for the wrong reason and both were greps of prose: E4
matched the new FAIL message's own words "NOT UPGRADE OK", and M14 matched the
comment documenting the removal of the string it was looking for. Both now key on
a log TAG. **Assert on the tag a program emits, never on the prose around it.**

Follow-ups: **T279** (the same hazard at every other PowerShell -> CLI call site:
`+rename --title`, `+set-banner`, `--command`) and **T280**
(`ConvertTo-SendKeysLiteral` is redundant now - it existed only because the text
was on argv).

**Addendum, same turn.** The fix nearly shipped a regression worse than the bug.
These scripts drive whichever ghoztty is INSTALLED, and the watchdog is a
long-lived HKCU Run process; an exe that predates `--keys-file` treats it as
ordinary TEXT and types the PATH into the pane - the T241 failure, recreated by
its own fix, inside the watchdog that exists to catch it. Probed before pushing:
the installed release (+96fbe40c7) did NOT support the flag. So the transport is
now chosen at RUNTIME per exe (`+send-keys --help` exits 0 and touches no pane,
so it is a side-effect-free capability probe), cached, and falls back to argv with
a `WARNING:` naming the degradation - CLAUDE.md's app/agent HELLO rule applied to
the CLI. **A new flag is a compatibility boundary the moment a script uses it
against an exe it did not build.**

## 2026-08-01 - T208: the delivery had no idea what it was delivering

`upgrade-ghoztty-windows.ps1` never builds - by design, it copies whatever sits
in `zig-out-release` - and `launch-upgrade.ps1` only checked that the directory
EXISTED. So the contract was "the caller builds first", written down nowhere the
caller reads. Delivering T202 on 2026-07-30 that shipped the previous delivery's
binary while `LAUNCH OK`, `exe swapped` and `UPGRADE OK` all reported success;
`+version` still said `+9968a62d9`.

The fix is a number both ends can compare - the commit `GitVersion.zig` bakes in
as semver build metadata - read and compared in ONE place
(`scripts/delivery-version.ps1`) by three gates: the launcher builds and then
refuses to launch a prefix that is not HEAD (exit 3, nothing started); the
upgrade script re-checks before the kill and skips the entire destructive region
on stale bits; and it reads the INSTALLED exe back afterwards, so `UPGRADE OK`
means the right bits are on disk instead of "a file copy returned success". The
other two install locations are mirrored automatically once the primary verifies,
and skipped when it does not. `test\win32\upgrade-staleness.ps1` - ALL PASS, 45
assertions, hermetic.

Two decisions worth keeping. **Stale bits skip the swap but still RESUME**: the
delivery must not happen, but a silently stalled loop is the more expensive
failure (T200, T241), and `UPGRADE FAILED` plus exit 1 already make it
unmistakable. And **the failure is asserted on the marker count, not the
message** - "no upgrade was started" is the half that matters, and a script that
only checks for the right words can pass while launching anyway.

The lesson is not that the idea was missing. `publish-windows-release.ps1` - the
MSI path - has always built first and thrown unless the exe reported
`$Version+$hash`. The loop's own delivery path, which runs far more often and is
the one the user sees, never inherited that discipline. **Two pipelines doing the
same job, and only the one a human watches got the check.**

One fallout in `upgrade-no-fork.ps1`: its L section drove the launcher at an
EMPTY staging directory, which is now refused before the launch mechanics it
tests are reached. It stages a copy of the built exe and passes `-SkipBuild
-ExpectedCommit`. The argv whitespace guard moved ahead of the build with it, so
a mis-quoted path costs zero minutes instead of a full ReleaseFast build.

**Addendum, same turn.** The suite never builds - that is what makes it hermetic
- so the build step shipped untested by it. Running the launcher for real caught
it in one go: with `ZIG_GLOBAL_CACHE_DIR` unset, zig's global cache lands under
`%LOCALAPPDATA%` on C: while the repo is on D:, a `Run` step cannot express a
cross-drive absolute path relative to its child cwd, and the build panics in
`convertPathArg` - surfacing as "unable to read results of configure phase"
under a build-runner stack trace. Every hand-run build here exports the variable
first, which is precisely why it was invisible: **a habit of the operator is not
a property of the script**, and a detached delivery child inherits the launching
tool shell's environment, not the operator's habits. The launcher now fills the
default itself, on the repo's own drive, and never overrides an explicit setting.
Verified end to end afterwards from a shell with the variable unset: cache
pinned, build a no-op, gate green against real HEAD, `LAUNCH OK`.

## 2026-08-01 - T209: the pixel assertions landed, and both negative controls turned out to be hollow

T204 and T206 shipped their geometry and their per-pixel math fully unit-tested
and never asserted on the box - the user had just said "you KEEP STEALING FOCUS
USE ANOTHER DESKTOP", so the GUI scripts stopped running at all. T211/T216-T218
gave the desktop back and T214 settled that `PrintWindow` captures the GDI
chrome, which is every claim T209 wanted. So this turn wrote them:
`tab-strip.ps1` 38 -> 56 assertions, `pane-banner.ps1` 65 -> 67, ALL PASS x3.

The interesting half is what the negative controls did when asked to fail.
**Neither could.** `icon_button.T204_NEUTERED` moved no glyph at all -
`glyphCentered()` was exported, documented and unit-tested, and both paint
sites called `targetBox` directly, so the flag changed the fills and left every
glyph exactly where the shipped build puts it. `tab_shape.T206_NEUTERED` left
the flare and the antialiasing on while its own doc comment claimed it removed
the flare. Between them, four of the assertions this task exists to write had
no control whatsoever. Both are fixed (`glyphTarget(m, box, glyph)`, and a
neuter branch in `sdTabRim`/`renderTab`); the audit of the two remaining flags
is **T283**.

The lesson is where the defect was VISIBLE. `icon_button.zig` reads perfectly:
the predicate is declared, its doc comment is right, a unit test pins it. The
whole failure is at the call sites, which is the one place nobody looks when
reviewing a negative control. **A control that answers a question no paint site
asks is decoration** - and it reads, in a task file, exactly like evidence.

Second finding, sharper than T233's: the hover FILL is not merely hard to catch
on the background desktop, **the hovered frame is never painted**.
`WM_MOUSELEAVE` is a POSTED message and `WM_PAINT` is the lowest priority in
the queue, so the leave is always drained before the paint the move dirtied.
300 posted moves never caught a lit fill - not on the close "x", not on the "+"
that has lit one since before T204. Both scripts therefore probe it with the
"+" as the harness's own positive control and SKIP when it is not caught ("+
caught, x not" is a defect; "neither" is the race), and the TRIGGER is asserted
from new debug oracles instead. **T282** is the follow-up.

Three test-authoring traps, all worth the next author's time: a tab's measured
right edge reads one pixel SHORT because its last fill column carries the side
rim (which doubles into a centering delta, so the shipped build sits at +2); a
scan outboard of a tab reaches the "+" button unless it is bounded by
`group_gap - btn_pad`, which is how the T204 control turned a healthy flare
red; and an `else` around the shape assertions let the T206 control show only
ONE of four failing, because the silhouette claims need the selected tab and
were gated on the inactive ones being measurable.

## 2026-08-01 - T226 splits four ways, and T284's layout math found the panel's first paint bug before any paint existed

Windows has zero lines of the Mac Activity Monitor, and T226 was one task for
the whole thing. `RemoteActivityMonitorView.swift` is 1383 lines and the
comparable win32 surface (`MachineChooser.zig`) is 1872, so it was split before
starting rather than after blowing a context: **T284** (pure layout math) ->
**T285** (owner-drawn window + registry + LOCAL metrics/proc table) -> **T286**
(Kill with confirm, New Process, error banner) -> **T287** (remote sources, the
card carousel switcher, and the chooser Activity button, which closes T177).

T284 landed both pure modules: `activity_layout.zig` (24 tests) and
`trend_gauge.zig` (10), registered in `src/apprt.zig` so they run in every
app-runtime lane. Both test lanes, `test-agent`, and P1-P3 are green, and the
counts are checkable: `-Dtest-filter` runs 84 and 98 against an unfilterable
baseline of 74, i.e. exactly the 10 and 24 declared.

**The interesting part is that the tests failed first, on a real defect.** Laid
out with Mac's fixed 240-wide filter field, the control bar needs 730 px at 100%
and the panel opens at 700 - so the badge slot inverted and the count label
overlapped the checkbox. Ordering and the design system's "nothing touches
anything" both failed on it. The fix follows Mac instead of patching the
symptom: `.frame(maxWidth: 240)` is a MAXIMUM and a SwiftUI TextField yields
under pressure, so the filter is now the row's one elastic control, capped at
240 and floored at 120, asserted across 620..3000 px.

That is the argument for building geometry as a pure module first, and it is
stronger than "it is testable": this was a PAINT defect, and it was found and
fixed before one line of GDI existed to paint it wrong. It would otherwise have
shipped as a screenshot in a user bug report, which is precisely how the whole
UI quality block got filed.

Two decisions recorded so T285 does not relitigate them. Mac's ad-hoc 10 pt
paddings are snapped to the 4 DIP scale (control rows `md`, the gauge band keeps
Mac's own 12). And the intra-dialog separators stay 1 px hairlines like the
sibling chooser: section 5's 2 DIP band governs the DRAGGABLE split lines
between panes, where a vanishing line costs the user a grab target, and a rule
inside a dialog has no grab band to lose.

## 2026-08-01 - T285: the Activity Monitor opens on Windows, and the capture found what no assertion would have

The panel exists. `ActivityMonitor.zig` opens from the command palette as "Open
Activity Monitor", paints T284's regions with GDI, and fills them from the LOCAL
samplers `metrics.Sampler` / `proc.ProcSampler` - the two trend gauges, the
filter/Show-all/count control bar, and a five-column process table with sorting,
multi-select, wheel + keyboard scrolling and an overlay thumb. `activity_rows.zig`
carries the pure half (28 tests: the filter composition, the spawned-tree
marking, the sort order, every cell's text), registered in `src/apprt.zig`. One
panel per SOURCE: a second open focuses the existing one, keyed on a `Source`
union that already has its `.remote` arm so T287 does not have to retrofit the
registry. All four zig lanes green, P1-P3 ALL PASS, and
`test\win32\activity-monitor.ps1` is ALL PASS at 46 assertions with its
`-NegativeControl` inversion failing as designed.

**The defect this turn is proudest of was found by LOOKING at the panel.** The
sort indicator was appended to the header title, and `"% CPU"` plus an arrow does
not fit the 60-90 DIP CPU column - so `DT_END_ELLIPSIS` ate the arrow and the
panel showed `"% CPU..."` with no indicator on the very column it was sorted by.
No assertion in the script would ever have caught it: the script reads neither
the title nor the arrow. It took one `PrintWindow` capture and one human look.
The rule that follows is small and cheap: **a new pixel surface gets one look at
a capture, on top of whatever the probes assert.** The arrow now has its own
reserved slot and is a filled `Polygon` rather than a text glyph (section 4).

The second find is section 2.3's own sentence, still the easiest to miss: the
Path column's secondary gray clears 4.5:1 against the panel (5.4:1) and FAILS it
against the selection fill (2.8:1). **The contrast floor is checked against the
fill the text actually sits on.**

Four harness traps were re-paid and are now written into the script so they are
not paid a third time. `Get-TestChildWindows -Class 'BUTTON'` matches nothing -
the harness compares class names exactly and the class is `Button`. A
one-element array return unrolls in PS 5.1, so `(Get-Panels).Count` was `$null`
and a correct app failed the "exactly ONE panel" assertion. `Send-TestMouse`
takes SCREEN coordinates, so a header click passed in client coordinates landed
past the table's right edge where `columnAt` correctly returns null. And the
sharpest one: **a channel-dominance pixel probe is not a tint probe** - "bluer
than it is red" passes on ClearType's color fringes, which appear wherever there
is text, so the first chart probe passed against a panel whose charts had not
drawn yet. GDI fills solid brushes with no antialiasing, so the tints land as
their literal constants; the probe now matches them exactly, with control probes
asserting each tint is absent from the other gauge's half and from the table -
and it waits for a third poll first, because a chart with one sample correctly
paints nothing.

Two scoping decisions recorded rather than argued later. "New Process..." is
created DISABLED instead of omitted: the layout module reserves its rect, so the
control bar has the geometry the module describes from day one (which the script
measures), and a disabled control is an honest state where a live button that
does nothing is not - T286 enables it. And sampling runs off the GUI thread with
`close` JOINing the worker, because a poll enumerates ~300 processes and opens
each one; a dropped tick is deliberate, so a slow machine cannot accumulate a
backlog of enumerations.

## 2026-08-01 - T146 split into T318 -> T319/T320 -> T321, before it was started

T312 closed T227, which closed the Ctrl+Shift+N polish block, so the next
priority item is T146 - the chooser's *function* half. It is four Mac commits
behind one title and the context rule says that gets split before it is picked
up, not after. Evidence, not estimate: `MachineChooser.zig` is 108 KB and
matches `session` exactly **four** times, and all four are the string "Session
expired - sign in again above." in relay error mapping (:728, :1567, :1577,
:1579). The surface has none of it. Mac's supporting code is ~19.5 KB
(`SessionBrowserProbe.swift`) + ~30 KB (`SessionLayoutManifest.swift`) + ~38 KB
(`SessionLayoutRestore.swift`), and the three comparable tasks on this same
surface each split (T226 into four, T227 into three, T203 into three).

The scoping read changed what the children ARE, which is the point of doing it.
**The data plane is already cross-platform Zig and already called from win32**:
`Connection.requestSessions` (`connection.zig:1598`), `requestLayouts` (:1693),
`closeSession` (:2114) - and `App.zig:1263` already runs the first against the
local agent's warm shared connection. Mac reaches the same functions through
`embedded.zig:2802/:2913`; win32 calls them directly. So T318-T321 are UI +
threading tasks in the shape T295 already established, not systems tasks, and
each child file cites the Mac lines it ports rather than restating them.

**T322 is the finding.** `relaunchable` is on the wire (`protocol.zig:576`,
round-tripped by the test at :2094) and in the client struct
(`connection.zig:564`), but the C API row omits it - `SessionJsonRow`
(`embedded.zig:2820-2833`) emits twelve fields and that is not one of them, and
Swift decodes it `?? false` (`SessionBrowserProbe.swift:49`). So Mac's
`isConnectable = alive || relaunchable` (:56) is `alive` alone, and the filter
written to KEEP resumable reboot-floor tombstones is what hides them - the same
rows `wp4_e2e.zig:868` asserts are resumable. `+sessions --json` has the hole
too (`cli/sessions.zig:237`). It matters here because Windows reads the Zig
struct directly and would show what Mac hides: a platform divergence created by
an omission rather than a decision. Settle it before T318 renders a row.

Docs-only turn: `parity-tasks.ps1 validate` ALL PASS (352 tasks), no source
touched, so the build/test floor was not re-run.

Follow-ups: **T288** (two private copies of the same case-fold substring
search), **T289** (the panel is keyboard-operable but has no visible focus
anywhere, which section 2.2 calls an accessibility defect rather than a polish
item), **T290** (it keeps enumerating every process while minimized). Next in
the T226 chain is **T286** (Kill with confirm, New Process, the error banner),
then **T287** (remote sources + the carousel, which closes T177).

## 2026-08-01 - T286: Kill, New Process and the error banner, and a negative control that had to survive being right

Third of the T226 split. The panel can now act, not just watch: Kill behind a
mandatory confirmation, a New Process dialog, and a dismissable error banner
under the table. All wording, the failure aggregation, the empty-state choice
and the selection prune went into a new pure `activity_actions.zig` (15 tests in
the none lane); the dialog went into `NewProcessDialog.zig`, built as a sibling
of `HostSettingsDialog` rather than a third `ConfirmDialog` flavor, for the
reason that file already records - a labeled two-row form is a different dialog,
not a wider message box.

Three things are worth carrying forward.

**The confirmation wording is a deliberate divergence, and a test guards it.**
Mac says "This sends a termination signal to the process." Windows has no such
signal: `proc_control.killWindows` is `TerminateProcess`, immediate and
ungraceful, which that module's own header calls out as the TERM==KILL caveat.
Repeating Mac's sentence would have shipped a confirmation that misdescribes its
own action - worse than none - so the Windows body says what actually happens,
and a unit test asserts the word "signal" never appears in it. Parity is with
the BEHAVIOR, not with the sentence.

**A dialog that quotes borrowed strings has to stop the thing that frees them.**
The confirmation names the row (`Kill cmd.exe (PID 16696)?`) from a name
borrowed out of the current snapshot, and both dialogs run a nested pump - so a
1.5 s poll landing mid-dialog would have destroyed the snapshot under the text on
screen. `modal` suspends adoption for the dialog's life and adopts on the way
out. Filed as **T292** with the copy-instead-of-borrow alternative, because the
cost is real: the trend charts pause while a dialog is up, and Mac's do not.

**The negative control had to be designed, not just declared.** "Cancelling
leaves the process alive" is the assertion a merely cosmetic confirmation would
fail, so the script must genuinely reach the kill path and stop - and it must do
that without becoming a script that kills a bystander. Two rules made that safe.
The fixture is `cmd.exe /C pause`, a throwaway that blocks forever with no child
process to orphan. And the affirmative button is only clicked when the
confirmation dialog ITSELF named the spawned pid, so a mis-targeted row makes the
run fail rather than terminate something the box needs. Row 0 is deterministic
because the section sorts by PID **ascending** first: any other pid whose decimal
string contains this one's must have more digits, hence be numerically larger.

One harness lesson: `Send-TestControlClick` SENDS `BM_CLICK`, and every action
button here opens a modal whose nested pump does not return until answered - a
sent click sits in it until the send timeout. Opening a modal needs a POSTED
click (`Send-TestMouse`); clicking the buttons INSIDE the dialog can stay sent,
because those handlers only set a flag.

`activity-monitor.ps1` is ALL PASS at 82 assertions (was 63), `-NegativeControl`
still red, both test lanes + `test-agent` + the Debug GUI link green, P1-P3 ALL
PASS. Follow-ups: **T291** (`CREATE_NEW_CONSOLE` flashes a console window on
every spawn - and the comment above that flag records why the obvious
`DETACHED_PROCESS` fix killed its own children), **T292** (above), **T293**
(multi-row Kill is unit-tested but never exercised on the box). Next in the chain
is **T287**: remote sources + the carousel, which also closes T177.

## 2026-08-01 - T177: the chooser's action row becomes a run, and the button that opens a machine it cannot reach yet

Mac's machine-chooser detail header is `[New Window] [Restore All]? [Activity]?
[...]?` (`MachineChooserView.swift:456-494`). Windows had two of those, laid
out as two named slots with the `...` pinned to the primary button's right
edge. **Activity** was the gap this task was filed for (T226 built the panel it
opens; T287 will connect it).

**Slots became a run.** `Layout.primary_btn`/`menu_btn` are gone. `Layout` now
carries the band plus three numbers - gap 8, caption padding 12, minimum button
96, every one on the design system's 4 DIP scale (§1) - and
`chooser_layout.actionRow(l, comp, text)` packs the row left to right. The
composition is named, not implied: `Composition.restore_all` exists and is
never set, because the whole value of a run is that the row grows by one
without anything else moving, and a flag nobody sets is what keeps that true
(T146's half is now "create the button and set the flag").

**Composition changes with the machine, so PLACEMENT has to as well.** This is
the part a slots-shaped mind gets wrong: hiding Activity does not just hide
Activity, it MOVES the `...` beside it. `refreshDetail` re-packs on every
selection change, not only on DPI change. The module also stays text-free -
`ActionText` carries measured captions and the module adds the padding - which
is T235's lesson applied before it could be re-learned rather than after.

**The interesting decision is what the button refuses to do.** Mac dismisses
the chooser and dials (`finish(nil)` then `presentDialing`, :1488-1492).
Windows dismisses too, and here it is load-bearing rather than cosmetic: the
chooser DISABLES its owner, so a panel opened over it would surface behind a
dead window. But the dial itself is T287, and the panel's sampler is local.
Wiring it up as-is would have produced a panel titled `Activity - E2E-Box`
listing THIS machine's processes - a lie with no tell. So `buildSnapshot`
returns `error.RemoteSourceNotConnected` for a remote source and the panel says
"Couldn't connect / The E2E-Box source is unreachable." A degraded state the
user can read beats a confident state that is wrong, and T287 replaces exactly
one branch.

Two smaller things that had to be right for that to be safe: the panel now owns
its source strings (`Remote{id, name}` copied into the instance) because the
chooser frees its device arena on the way out, and identity stayed the **id**
while the label became the **name** - Mac's split, which is what stops a rename
from opening a second panel on the same machine.

**A test that could not have caught this before now can.** `chooser-menu.ps1`'s
`Get-MenuButton` was "the first button to the right of New Window" - which is
Activity now, so the helper would have silently scored the wrong control. It
finds the SQUARE button in the row instead: shape, which the design system
fixes, rather than a label that is a non-ASCII ellipsis. The script grew the
composition (Local row = `New Window` alone; remote = three, in order, one gap,
each sized to its own caption, whole run inside the pane), the click (panel
titled for the SELECTED machine, chooser gone first, a second press focusing
the same window), and the refusal - whose oracle is the log line, because the
empty state is painted text, not a control.

**And the same locator was copied into two more scripts.** T257's finding
again, in a different subsystem: `host-settings.ps1` had its own
"first button right of New Window" copy - which would have clicked **Activity**
and opened a panel while asserting about a menu - and `relay-account.ps1`
identified the account button by *excluding* the labels it is not
(`New Window`, `Open`, `Cancel`), an exclusion list that grows silently and had
just gained a fourth member. Both were repaired against something the design
system fixes rather than against a label: the menu button is the SQUARE one in
the action row, and the account button is the TOPMOST one in the dialog. Three
copies of one locator meant three chances to be wrong, and two of them would
have failed as confidently as the first.

`chooser-menu.ps1` ALL PASS at 55 assertions (was 38), `host-settings.ps1` 65,
`relay-account.ps1` and `ipc-machine-chooser.ps1` ALL PASS,
`activity-monitor.ps1` ALL PASS at 82, P1-P3 ALL PASS, both test lanes +
`test-agent` + the Debug GUI link green. Next in this chain is **T287** (dial +
carousel), which now has the one-line diff it needs written down in its own
file.

## 2026-08-01 - T295 (T287 split): the Activity Monitor reaches a real machine, and the dial had to land somewhere that outlives the panel

**T287 was split first** — T295 (remote data plane) + T296 (in-panel machine
carousel) — because the two halves answer different questions and only one of
them was small. T296's bulk is not the cards: the panel has no machine list (the
chooser's comes from a synchronous HTTPS GET a non-modal window cannot make) and
win32 has **no `MachineMetricsProbe` equivalent at all**, so the per-card
summaries are a subsystem.

T295 is the half that closes what T177 left open: `buildSnapshot`'s first
statement was `if (self.source == .remote) return
error.RemoteSourceNotConnected`, and the chooser's Activity button opened a
panel that said "Couldn't connect" on purpose. Both of Mac's connection-owning
entry styles now exist — **dialed** (the chooser button, owned) and **reused**
(the palette on a remote window, borrowed) — with remote `proc_list`,
`metrics_sub`, `proc_kill` and `proc_spawn` behind them.

**Where the dial LANDS is the decision worth recording.** The obvious shape — a
detached thread posting its result to the panel's own HWND — leaks a live
connection every time the user closes the panel mid-dial, because
`DestroyWindow` DISCARDS a window's queued messages and that message is what
carries ownership of the dialed transport. So it posts to the APP's
message-only window, which outlives every panel, and a `(slot, serial)` pair
says whether the panel that asked is still there. The serial is not decoration:
slots are reused the instant they free, so a slot-only check would hand a NEW
panel a connection to the OLD panel's machine and caption it with the new one's
name. `panelMatches` is pure and unit-tested on exactly that case.

**Close order is ownership order.** Unsubscribe metrics first — that return is
the guarantee no further callback fires into `self` — then, for an OWNED
connection only, `shutdown()` BEFORE joining the sample worker, since `shutdown`
runs `failPendingRpcs` and an unresponsive agent would otherwise hold the GUI
for the full 5 s RPC timeout. A borrowed connection is never shut down or
freed: it is a window's shell.

**A loopback agent enumerates the same box**, so "the table populated" proves
nothing — a panel that silently sampled THIS process would look identical under
another machine's name, which is the very lie the old refusal existed to
prevent. The distinguishing field is the snapshot's ROOT PID (the agent's own
for a remote sample, this process's for a local one), so `rebuild`'s state line
gained `root=` and the new `test/win32/activity-monitor-remote.ps1` asserts it
equals the agent pid the harness started: `source=127.0.0.1:47913 total=303
shown=3 root=40288` against app pid 35688. Its last assertion is the ownership
one — after the reused panel closes, the remote pane still round-trips through
the agent.

`chooser-menu.ps1`'s refusal assertion was replaced rather than kept: it was a
claim about the gap. It now asserts the feature — the button DIALS, an
unreachable machine reports `dial failed`, and no row is ever shown under a
machine we could not reach.

`activity-monitor-remote.ps1` ALL PASS at 17 (its `-NegativeControl` fails with
exactly 1, as it must), `activity-monitor.ps1` ALL PASS at 82, `chooser-menu.ps1`
ALL PASS at 57, P1-P3 ALL PASS, both test lanes + `test-agent` + the Debug GUI
link green (`test-agent` needed one re-run for the known T258 ConPTY flake).
Follow-ups: **T296** (carousel) and **T297** — the DIALED path still has no
success-case coverage, and it is the only path that FREES what it owns.

## 2026-08-01 - T296 (T287 split): the carousel switches source in place, and the stale sample is dropped by generation rather than by waiting for it

The panel can now move to any other source in one click without opening a second
window - Local first, then every registered machine - which is the last piece of
T226's Activity Monitor that a user can see.

Three parts, and the interesting one is not the painting. The **machine list**
comes from `relay_directory.listDevices`, a synchronous authenticated HTTPS GET
the chooser can afford on the GUI thread because it is a modal dialog with a
spinner; a non-modal panel cannot, so it runs on a detached thread and lands as
`WM_APP_ACTIVITY_MACHINES` on the APP's message-only window - the same
outlives-the-panel rule T295 established for the dial, because `DestroyWindow`
discards a window's queued messages. Devices are copied BY VALUE out of the
parse arena before it dies. The **cards** are pure (`activity_cards.zig`, 13
tests) plus `activity_layout.cardContent`, whose text block is CENTERED so its
padding is symmetric by construction instead of by two constants somebody has to
keep equal. The **switch** is `switchToCard` / `teardownSource` /
`resetForNewSource`.

Three decisions carry it. **The active source always has a card**, even when the
directory does not list it (a borrowed connection, a signed-out account, a failed
fetch, a machine deleted while the panel sat open) - a carousel that cannot show
you where you are is lying, and with Local pinned at index 0 there is always a
way home. **A sample worker started for the old source is dropped by GENERATION,
not by joining it**: joining would freeze the GUI for up to the 5 s RPC timeout
on a BORROWED connection, which cannot be `shutdown` to cut the wait short
because it is a live window's shell - and adopting it would paint one machine's
processes under another's name. **The switch bumps `serial`**, which routes an
in-flight dial for the abandoned source onto `onDialed`'s panel-is-gone path
where it frees what it opened; that is T295's mechanism reused rather than a
second one invented.

Deliberately NOT shipped, and named rather than dropped: Mac's
`MachineMetricsProbe` dials EVERY registered machine and holds a metrics
subscription on each, live, for the panel's lifetime. That is a connection-budget
design, not a paint pass, so it is **T298**. Inactive cards report the relay
directory's own `online` flag and print no number they do not have - the state
enum has an `.idle` case for exactly this. Missing information, not wrong
information.

`activity-monitor-remote.ps1` ALL PASS at 33 (up from 24), `activity-monitor.ps1`
still ALL PASS at 82 (a one-source panel paints no carousel at all), P1-P3 ALL
PASS, both test lanes + `test-agent` green. The oracle is the panel's own
`carousel cards=N focus=i active=j scroll=x rects=...` line and the script clicks
the rect the PAINTER reported - T257's lesson applied before it could bite. Its
first run was red for a good reason worth writing down: **`Send-TestMouse` takes
SCREEN coordinates** (it `SetCursorPos`es before posting) while those rects are
CLIENT ones, so five assertions failed against a build that was fine -
`Get-TestWindowRect -Client` returns the client rect already in screen space, and
its origin is the whole conversion. Follow-ups: **T298** (per-card metrics),
**T299** (`ActivityMonitor.zig` is ~3,000 lines and needs splitting), **T300**
(the carousel is not reachable by Tab), **T301** (switching back to a machine a
remote WINDOW is already connected to re-dials through the relay and simply fails
when signed out).

## 2026-08-01 - T302 (T227 split): the chooser's numbers get written down, and the native reference turns out to be uncapturable

T227 - the pixel-parity pass over the whole Ctrl+Shift+N surface - is measure +
spec + implement + assert across three modules at four DPI scales and two
themes. That is past one context, and T227's own text already named the spec doc
as its first deliverable, so the measurement half split out as **T302** and
landed as `docs/design/win32-machine-chooser.md`. Same move T202 made for the
tab strip, for the same reason: write the numbers down once and every later task
paints to one agreed target instead of to an opinion.

Mac's side came out exact - 45 metrics read straight out of
`MachineChooserView.swift` with line cites, because SwiftUI states its own
paddings, radii and opacities numerically. Windows' side did not, and the
interesting part of the turn is why.

**T227's stated method for the Windows reference does not work, and it fails
silently.** `PrintWindow(PW_RENDERFULLCONTENT)` against Task Manager returned a
**flat black** 1379x1134 bitmap - one distinct color over a 7px grid, an 8 KB
PNG - and reported success. The seam scan then found zero vertical seams, which
reads as "this app has no master-detail seam" rather than "there is no capture".
Cause is architectural: Task Manager, Settings and every other Win11
master-detail app are WinUI/XAML compositing through DirectComposition, so
nothing is ever painted into the window DC. Exactly T214's `GhozttyTerminal`
limit, one class wider - and the same failure shape, *empty rather than absent*.
The Win32 apps that DO capture are classic GDI dialogs, i.e. precisely the ones
that do not show the Win11 idiom, so a capture that works is a capture of the
wrong thing. Follow-up **T303** makes the flat capture throw instead of measure.

So the doc sources the Windows side three ways and labels every claim with which
one it came from: **measured** (`SystemParametersInfoForDpi` says the system
font is Segoe UI 9 pt at 12/15/18/24 px across 96/120/144/192 dpi; DWM says this
box's accent is `#680081`, a purple; `uxtheme` says BUTTON content margins are
3 all round and has **no** Win11 answer for `LISTVIEW/LISTITEM`, returning
`#FFFFFF` for every state including selected), **documented** (the Fluent
12/14/20/28 ramp, marked as such on every use), and **read from our own source**
for current state. Nothing eyeballed.

The delta is 13 findings, each with a file and line. The three biggest are one
defect wearing three hats - the surface is hardcoded dark (`COLOR_BG =
RGB(32,32,32)` plus a literal `DWMWA_USE_IMMERSIVE_DARK_MODE = 1`, duplicated
verbatim in `HostSettingsDialog.zig`), every wash/divider/hover composites
`#FFFFFF` unconditionally so a light background erases the column wash and the
rules outright, and the accent is a hardcoded `#3D8EF8` against the box's real
purple. All three are **T203's** mechanism, not the chooser's, and the doc says
so: T227 consumes that plumbing rather than re-deriving it. What stays with T227
is the type ramp (15/20/12 against a 14/20/12 target and a 12 px system font),
the missing avatar and monogram, a row radius and icon column off the design
system's scale, five surviving off-scale spacings, no focus indicator on the
owner-drawn list, and no contrast floor on `secondary_gray`.

Cheap second lesson, recorded so nobody repeats it: **Task Manager launches
elevated**, so a non-elevated session cannot close it again - `Stop-Process`,
`CloseMainWindow` and `taskkill` all return Access Denied, and the window is
still on the user's desktop. A reference fixture you cannot clean up is a bad
fixture.

Docs only; no lane re-run. `parity-tasks.ps1 validate` ALL PASS (333 tasks).

## 2026-08-01 - T304 (T203 split): the chrome gets one color source, and the primitive it needed already existed twice

T203 - the tab strip ignoring the system accent and breaking in light themes -
is a color module, a five-file rewiring, live repaint on two system messages, a
Mica judgment call, and an acceptance script that MUTATES the box's accent and
apps theme and has to put both back. That is not one context, so it split:
**T304** the derivation, **T305** the wiring plus the pixel assertions, **T306**
the Mica decision. This is T304.

The accent source settled quickly and empirically.
`HKCU\Software\Microsoft\Windows\DWM\AccentColor` reads `4286644328` on this
box, which is `0xFF810068` - **ABGR**, not ARGB - decoding to `#680081`, exactly
the accent T302 measured through DWM. Explorer's `AccentColorMenu` holds the
same DWORD and is the fallback. Two sources were REJECTED with their evidence in
the source: `AccentPalette`'s eight shades, because its index semantics are
reverse-engineered and index 3 - the one usually claimed to BE the accent - is
`#A94DC1` here, a color the user never picked; and `DwmGetColorizationColor`,
because `ColorizationColor` is `0xC4680081`, a composed value whose alpha byte a
caller expecting an accent would read as a channel.

The more useful finding is what the module needed and did not have to invent.
"Composite white over a dark background or black over a light one" already
existed **twice** - `banner_card.fillColor` and `tab_shape.lift`, character for
character - and a third time as `Window.paintTabBar`'s `bg + 20` per channel.
The third copy is T203's root cause #2: an add moves a light background the
WRONG WAY, so bar, hover and active all converge on near-white and the fixed
grey text goes illegible. So `wash` was hoisted into `color_math` and both
survivors now call it, which is the T257 lesson applied one module earlier than
usual: three copies meant three chances to be wrong, and the wrong one was the
one nobody had a unit test for. Same shape for the contrast search -
`contrastAdjusted` was hardwired to 4.5, and the accent needs WCAG 1.4.11's 3.0,
so the existing CIELAB search took a `target` parameter rather than growing a
sibling. A second search tuned to 3.0 is how two answers start disagreeing about
what "hue-preserving" means.

`chrome_theme.resolve` returns the whole palette in one shot, deliberately: bar,
hover, text, text_secondary, accent, on_accent, danger, on_danger are each only
correct RELATIVE to the others, and resolving them one at a time against
whatever background the caller happened to hold is precisely how the app ended
up with two different invented blues (`chooser_rows.accent = #3D8EF8` and
`ActivityMonitor.COLOR_ACCENT = RGB(80,160,235)`) and two different reds.

Validation is a sweep, not a swatch: ~96 backgrounds across the luminance range,
greys plus saturated, x 7 accents including pure black, pure white and a very
light saturated pick - every text pair >= 4.5:1, every accent/danger pair >=
3.0:1, every on-accent foreground >= 4.5:1, and bar/hover always
distinguishable. A single hand-picked pair proves nothing here; `bg + 20` looked
fine against the one background anybody ever checked it against, which is how it
survived to 2026-08-01.

One thing done rather than assumed: the registry reader was verified END TO END
with a temporary print in the win32 lane (`accent = #680081`), then the print
was removed and the shipped test asserts only the machine-independent invariant,
so it cannot fail on someone else's box. Decoding correctly in a unit test is
not evidence that the key was read.

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0,
`zig build -Dapp-runtime=win32 -Doptimize=Debug` exit 0, `test-agent` exit 0.
P1-P3 ALL PASS. Because `wash` changed two shipping call sites, the two pixel
scripts that render them ran too: `tab-strip.ps1` ALL PASS (56),
`pane-banner.ps1` ALL PASS (67). No surface consumes the palette yet - that is
T305, and it is what makes any of this visible.

## 2026-08-01 - T305 (T203 split): the chrome consumes the palette, and the test that measured a color nobody picked

T304 landed `chrome_theme.zig` with nothing consuming it. This turn wired every
win32 chrome surface to it: `Window.chromePalette()` is the one resolution site,
and `paintTabBar` / `paintCaption` both read a single `Palette` instead of the
eight literals they held between them. `chooser_rows.accent` (`#3D8EF8`) and
`ActivityMonitor.COLOR_ACCENT` (`RGB(80,160,235)`) - two files, two different
blues, neither the user's - are gone, along with the carousel's ported
`RGB(106,106,255)` / `RGB(139,92,246)` pair. Accent changes arrive as
`WM_DWMCOLORIZATIONCOLORCHANGED`, which drops the cache and invalidates the
chrome; `WM_SETTINGCHANGE` was extended rather than duplicated.

**T274 is discharged by it and marked done.** That task asked for exactly this
module and named its own failure case: at `background = ffffff` the `+ 20`
arithmetic clamps the band to pure white and the frozen `RGB(230,230,230)` title
measures 1.25:1. Measured after: band `#EBEBEB`, title **14.89:1**. Scored at
`#f3f3f3` and `#1e1e1e` too, each against the value the app's own rule derives
rather than a pasted constant.

Two findings are worth more than the wiring.

**The task's validation asked for a pixel that does not exist.** T305 specified
sampling the ACTIVE-TAB INDICATOR and asserting it tracks the accent. The tab
strip paints no accent at all - a tab's fill is `tab_shape.fillColor` off the
strip and content backgrounds - and adding one is precisely what T304's "the
dark strip must not visibly move" note forbids. Satisfying the step as written
would have meant inventing the pixel to measure. The claim is scored on a
surface that really does paint the accent (the Activity Monitor's active card)
and the correction is recorded in the task and in the script header, because a
validation step a correct build cannot satisfy is a defect in the task.

**A test asserted a color nobody picked, and only a personalized box could tell.**
`ipc-machine-chooser.ps1` probes the selection pill with `b - r >= 25` - a BLUE
tint - which silently depended on `chooser_rows.accent` being `#3D8EF8`. The
moment the accent became a system setting the probe read `b - r = 6` against
this box's real `#680081` and failed a correct build. The fix is not a looser
threshold: the script now PINS the accent it measures and restores it in a
`finally`. An oracle for a system-derived pixel has to state its input, which is
the T174 rule reaching an input that only became one today.

The new script is `test/win32/chrome-theme.ps1` (ALL PASS, 34). Its strongest
pair is the cache: the registry is moved with NO notification and the panel must
still paint the OLD accent, and only then does the posted message make the next
one paint the new one. Without that first half, B3 would pass just as well
against a per-paint registry read that never needed invalidating.

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0,
`zig build -Dapp-runtime=win32 -Doptimize=Debug` exit 0, `test-agent` exit 0.
P1-P3 ALL PASS. Regression across every script that renders the touched chrome:
`tab-strip` (56), `caption-bar` (17), `pane-banner` (67), `chrome-merged-row`
(19), `menu-bar` (71), `tab-color` (16), `activity-monitor` (82), `hero-mode`
(63), `ipc-machine-chooser` (45). `-NegativeControl` fails 1 of 34, and the
box's accent is verified restored after every run including that one.
Follow-ups: T307 (an open panel does not repaint on an accent change), T308 (the
panels are still hardcoded dark), T309 (two derivations of the light/dark
decision).

## 2026-08-01 - T310 (T227 split): the chooser gets the ramp, and a fixed grey turns out to be a light-theme outage

T227 was the Ctrl+Shift+N polish pass and it was too big for one context, so it
split three ways: **T310** (metrics, type, the secondary contrast floor),
**T311** (the account row's avatar and its Sign Out link), **T312** (the list has
no focus indicator). Two of the doc's thirteen findings were already closed by
T305 before anyone acted on the table - `chooser_rows`' washes are
`color_math.wash` and its accent is a parameter - and finding 1 belongs to T308.

The visible half is arithmetic against `win32-machine-chooser.md` 3.2: the row's
selection radius 6 -> 4, a **28 reserved icon column** with a 16 mark centered in
it where a 20-wide mark used to BE the column, the five off-scale row spacings
snapped (1 -> a derived half of a 2 rhythm, 7 -> 4, 6 -> 4, 10 -> 12, 10 -> 8),
plus the two Mac numbers 3.2 names in the layout module itself (filter pad
14 -> 12, the shared gap 10 -> 8). Two spacing-scale tests - one per module -
now walk every gap and fail on any value outside {2,4,8,12,16,24}. Sizes are
asserted separately and by source, because a size is not a gap.

**The type ramp could not be edited in place, only hoisted.** `font_h =
px(15, scale)` is written out in SEVEN dialogs. Changing the chooser's copy to
3.2's 14 would have made the chooser the one dialog that disagrees with the
rest - a different inconsistency, not a fix - so the ramp became
`src/apprt/win32/type_ramp.zig` (caption 12 / body 14 / subtitle 20 semibold),
the Ctrl+Shift+N surface consumes it, `win32-design-system.md` gains 2.4, and
the other five dialogs are **T313** rather than quietly left behind. Same
argument T257 made for the chrome geometry: the duplication is not the defect,
the silent divergence it permits is.

**A fixed foreground color cannot satisfy a contrast floor.**
`secondary_gray = #999999` carried the row sublines, the offline status rings,
the machine glyphs and the detail subtitle. It is 5.2:1 on the dark wash the
chooser paints and **2.8:1 on Fluent's light surface** - under the 4.5:1 text
floor AND the 3:1 chrome floor - so a light theme would have taken all four out
together, and nothing in the code said so. It is now `secondaryOn(bg)` and
`onlineOn(bg)`, delegating to a `chrome_theme.textSecondaryOn` hoisted out of
`resolve` so the bar's answer and the chooser's cannot drift, and scored by a
96-background sweep rather than a hand-picked pair - which is exactly how the
grey survived this long.

Two process notes.

**The claim with no oracle was named, not faked.** Finding 12's defect is
light-theme-only and the chooser is still hardcoded dark (T308), so a pixel probe
for it would measure a surface this build cannot produce. Per T305's rule the
claim is scored where it is real - the unit sweep - and the gap is written into
the task instead of dressed up as a passing assertion.

**A pixel probe needs a threshold that discriminates, and the first one did
not.** Finding 8's whole visible consequence is the text column moving 8 DIP
right, so the probe finds the first BRIGHT column in row 0's band (the title is
230, the glyph beside it is the de-emphasized ramp, so brightness separates them
without knowing where the glyph ends). The first bound was 62 DIP, which rounds
to 78 at this box's 1.25 - and the retired geometry lands at ~78 too, so it would
have passed both builds. Measured 87 now; the bounds sit inside the ~9 px window.
Having to write it as a band at all is **T314**: this script keeps a private
banker's-rounding `Dip`, the T257 divergence in the one script T257 did not
sweep, and a metric the module composes from individually-rounded parts cannot
be reproduced by rounding the total at any rounding mode.

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0,
`zig build -Dapp-runtime=win32 -Doptimize=Debug` exit 0, `test-agent` exit 0.
P1-P3 ALL PASS. On box `ipc-machine-chooser` ALL PASS **50** (was 45) with
`-NegativeControl` failing exactly 1; regression green across `host-settings`
(65), `chooser-menu` (57), `relay-account`, `chrome-theme` (34), `tab-strip`
(56) and `activity-monitor` (82).

## 2026-08-01 - T311 (T227 split): the account row stops being a slot, and the test that could not see the state it was testing

Findings 5 and 6 of `win32-machine-chooser.md`: no avatar and no monogram, and
"Sign Out" as a button where Mac has a link - both states sharing one fixed
150 DIP slot, so both were as wide as "Sign in with Google…".

**Neither is really a paint bug; the LAYOUT could not express the signed-in
state.** `Layout` named one `account_status` rect and one `account_btn` rect,
which is exactly Mac's signed-OUT composition and nothing else - and the band
was `control_h`, so a two-line stack had nowhere to go even if someone drew one.
So the row became a packer, the shape T177 already gave the detail pane's action
row: `AccountBand` + `accountRow(l, state, text)` returning
`{text, avatar?, link?, button?}`. The band is now `max(avatar_d, email_h + 2 +
link_h, control_h)` = **36 DIP**, up from 28; the dialog did not grow with it
(Mac's fixed 840x540), so the body took the 8 and the list sheds it in whole
rows the way the wrapping status strip already did.

Three decisions the task asked to be stated rather than made silently. **The
monogram is 32, not Mac's 34** - 34 is off the 4 DIP scale and 32 is
`SM_CXICON`, the rule the detail pane's mark already follows, so the surface has
one identity-mark size instead of two nearby ones. **Its fill is flat accent,
not a gradient**: the letter's contrast floor is computed against ONE color, and
a gradient makes that floor a function of position - legible at one end of the
disc and not necessarily at the other - for a cue the shape already carries.
And **the letter is `type_ramp.bodyStrong`, not a new size**: Mac's `size * 0.42`
of a 34 circle is 14.3, which IS the ramp's body, so the mark lands on Mac's
number while T310's ramp stays 12/14/20.

**The link is a second control, not a restyled button.** `BS_OWNERDRAW` keeps
the tab stop, the focus and `BN_CLICKED` that a clickable STATIC would throw
away, and only the paint is ours - accent, borderless, underlined on
hover/press, system focus rect when focused. The signed-out state keeps a REAL
themed button: owner-drawing it too would have made it the one hand-painted
button on a surface of themed ones, which is the inconsistency the design system
calls a defect. `accountControl()` is the single answer to "the thing the user
can press", so the focus cycle, the Enter handler and the click routing cannot
disagree, and the Tab walk's existing skip-the-hidden loop needed no change.
Hover comes from `WM_SETCURSOR` - the child forwards it, and the message already
names the window under the pointer, so enter and leave are one test. Its gap
(no message arrives at all if the pointer leaves the dialog without crossing it,
so the underline can stick) is **T315**, deferred with its reasoning: the
obvious `TrackMouseEvent`-on-the-parent fix has an unproven premise about a
child under the cursor, and getting it wrong kills the hover instead of the
stick.

**The acceptance script could not reach the state it was about to test.** Both
existing `ipc-machine-chooser` runs are signed OUT at the ACCOUNT tier - run 1
has a credential via `GHOSTTY_RELAY_TOKEN` but no account - so nothing in it had
ever rendered the signed-in row. A third run now seeds a DPAPI account store
directly, and that is what the new assertions measure: the disc is the PINNED
accent (`rgb 61,142,248`), it carries a letter, the email and the link share a
right edge, the email sits above it. ALL PASS **65** (was 50).

Its lesson is small and general: **a control that is hidden is not on the row.**
`relay-account.ps1` identified the account control as "the topmost BUTTON",
which was sound while the row had one - with two, the hidden one is still the
topmost, so the signed-in run would have read the signed-OUT caption and
reported a working flip as broken. `Get-ChooserControls` filters on `Visible`
now.

Finding 6 measured at 1.25: sign-in button **198 px**, link **70**, retired
fixed slot 188 - three numbers where there used to be one. Follow-ups **T315**
(above) and **T316** (the signed-out row still shows a sentence Mac has no state
for; decide it and write it into §2.4 either way).

**The win32 lane hung, and it was T258 again.** `remote.agent.server.test.FLOW
pause halts streaming` sat at a flat 123.02s of CPU across two samples two
minutes apart, 4 threads all waiting, no child - killed at ~11 minutes, and the
"1 failed / exit 255" is the kill. The immediately preceding run of the same
lane on the same source was exit 0, and this diff cannot reach an agent test.
Same test, same profile, same lane as T258's recorded T205 hang, appended there
as a fourth datapoint: the hang is now 2 of 2 in the **win32** lane rather than
`test-agent`, so the lane is not the variable, the test is. Re-run exit 0.

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0 (on the
re-run, above), `zig build -Dapp-runtime=win32 -Doptimize=Debug` exit 0,
`test-agent` exit 0. P1-P3 ALL PASS. On box `ipc-machine-chooser` ALL PASS **65**
(was 50) with `-NegativeControl` failing exactly 2 (the detail-pane signature
and the monogram fill, each reached); regression green across `relay-account`,
`chooser-menu` (57) and `host-settings` (65).

## 2026-08-01 - T322: the field that made a filter a constant, and the five lanes that were not checking the file

Mac's `BrowsedSession.isConnectable` is `alive || relaunchable`, and its comment
says the second term is there to keep resumable reboot-floor tombstones listed.
`relaunchable` never arrived: it exists on the wire (`protocol.zig:576`) and in
`connection.OwnedSession` (`:681`), but both JSON rows that carry it outward -
the C API's `SessionJsonRow` (`embedded.zig`) and `+sessions --json`'s `JsonRow`
(`cli/sessions.zig`) - emitted twelve fields without it. Swift decoded `?? false`,
so the filter written to KEEP those rows was the thing removing them. Both rows
now emit it; additive, no protocol bump. Windows reads the Zig struct directly,
so this is also the divergence T318 would otherwise have inherited by default.

Verified end-to-end rather than by compile: the live repo agent's real
tombstones come back `"alive": false, "exit_code": null, "relaunchable": true`.
The unit test decodes into a struct that REQUIRES the key, so dropping it fails
the parse; and it was confirmed *reachable* by filter count (75 vs a 74 baseline)
instead of assumed.

The turn's finding is the near-miss. A positive control - breaking the new line
to a nonexistent field - showed **every standing lane exits 0 on it**, including
a macOS-target lib build, which constructs the lib and never installs it
(`build.zig:320`), so nothing depends on the compile and it never runs. `CAPI` is
reached only from `main_c.zig:41`, which no exe lane touches. The one lane that
does name the error is a windows-target lib, and it cannot build for an unrelated
POSIX-only reason (`ssh_transport.zig`). So the C API is edited from this seat
and compiled by nothing: **T323**. **T324** is the deliberately-out-of-scope
half - the human `+sessions` column still prints a relaunchable tombstone as
plain `dead`.

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0,
`test-agent` exit 0 (first run hit T258's known `server.zig:2684` ConPTY flake;
green on re-run), `zig build -Dapp-runtime=win32 -Doptimize=Debug` exit 0 (after
killing the repo's own running `ghoztty-agent.exe`, which held the install
target). P1-P3 ALL PASS.

## 2026-08-01 - T318 (T146 split): the chooser gets its session roster, and every pane on screen was badged as someone else's

The Ctrl+Shift+N chooser had no roster at all - `MachineChooser.zig`'s only four
matches for `session` were a relay error string. It now lists the local agent's
live sessions in the detail pane, with the label ladder, activity/status badges,
cwd + command sublines and Kill. Three pieces: `chooser_sessions.zig` (pure -
ladder, filter, badges, card geometry, scroll clamp, tone->pixel colors; 16 unit
tests), `SessionRoster.zig` (the RPC off-thread, the state, the painting, the
hit testing - kept out of the 106 KB `MachineChooser.zig`), and
`chooser_layout.sessions` for the region. `LocalAgent.dialProbe` is the "dial the
agent that is already running, never spawn one" path a browse must use.

Not an expander: Mac's roster is `detailSessions(target)` for the SELECTED
machine, so selecting the Local row IS the expand. `isConnectable` is
`alive or relaunchable` - a deliberate divergence from Mac, whose C API drops the
field (T322) and therefore hides the resumable tombstones the filter was written
to keep.

The finding is the `open` badge. A pane's live session id is
`core_surface.remoteSessionId()`; `Surface.remote_session_id` is set ONLY when a
pane attaches to a restored session, so a freshly OPENed persistent pane has
none - and the first build badged every pane on the user's own screen `attached`
("someone else holds it") rather than `open` ("you do"). Every test passed
through it; a screenshot did not. The acceptance now scans for the green badge
with the no-agent run as its negative control. Three follow-ups: **T325** (the
shared contrast search returns 8-bit colors a hair under the float floor it just
cleared - measured 2.9905, and three test sites now carry a tolerance for it),
**T326** (the agent terminates the child before replying to CLOSE_SESSION, so a
Kill that worked reports `error.Timeout`), **T327** (`Send-TestMouse` takes
screen coordinates while the comment beside it documents client ones - it cost a
debugging cycle against a working feature).

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0,
`test-agent` exit 0, `zig build -Dapp-runtime=win32 -Doptimize=Debug` exit 0
(after killing the repo's own running `ghoztty-agent.exe`, which held the install
target). P1-P3 ALL PASS. New: `test/win32/chooser-sessions.ps1` ALL PASS (16).

## 2026-08-01 - T319 (T146 split): the roster reaches another machine, and the relay finally has a stand-in

The chooser's session roster now follows the selection to a REMOTE machine: a
relay device's row dials that machine, runs `LIST_SESSIONS` over that
connection, and shows its sessions with the same rows, badges and Kill. No new
RPC - `Connection.requestSessions` is transport-agnostic - so the task was the
dial, its ownership (dialled, read, freed; the local agent's warm connection is
`LocalAgent`'s and is never touched here), and the per-row states. The pure half
is `chooser_sessions.Target` + `transitionFor`, which is where Mac's
`refreshInPlace` vs `fetchIfNeeded` distinction lives: re-selecting a machine
must not flash its region back to `Loading`. Telling an expired credential apart
from an unreachable machine needed one transport change - `ws_client` collapsed
every non-101 into `WebSocketUpgradeFailed`, and now returns
`WebSocketUnauthorized` on 401/403 - because "session expired" is the one dial
failure a user can act on.

The finding is a THIRD `row != .local` gate. Painting and the subtitle count
both lost theirs; `sessionView` - hit-testing, hover, scroll - kept one, so a
remote machine's cards drew and could not be clicked. It keys on the roster's
own target now. A test caught it, not a reading.

The bigger half is that none of this was testable. Every relay-dialled surface
in the app goes through `relay_dial.dial`, and nothing on box could answer one:
`activity-monitor-remote.ps1` says exactly that in its own header.
`test/win32/lib/FakeRelay.ps1` is the stand-in - device directory and a real
RFC 6455 upgrade bridged to a `ghoztty-agent --listen`, one port, one loop, with
401/502 injection by device id and a trip file so a negative control can turn
the relay off AFTER the fixture was built through it. It cost two bugs worth
keeping: `[int] -shr 56` is silently `-shr 24` in .NET (the 8-byte frame length
went out corrupt), and BOTH obvious peer-liveness probes are wrong -
`TcpClient.Connected` reports the last I/O's state, and
`Poll(SelectRead) && Available == 0` races the loop's own reads and tore down
healthy bridges 30 ms after the upgrade, which reached the app as
`error.ConnectionClosed`.

What makes the count mean something is the fixture, not the assertion: the app
runs with persistence off and every repo agent is killed first, so the Local row
MUST resolve to `failed` while the device row loads 2. A roster that quietly
enumerated this box would put the same number on both.

Two follow-ups. **T328**: a Kill on a remote row loses its refetch - the close
and the list behind it both fail (`ConnectionClosed`, sometimes `Timeout`, which
is T326 exactly), so the row vanishes by optimistic hide while the count goes
stale. A retry on a fresh dial WEDGED the worker and was reverted; the script
prints a NOTE where that assertion belongs rather than asserting the bug green.
**T329**: the fake relay makes T295's uncovered DIALED entry testable at last.

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0,
`test-agent` exit 0. P1-P3 ALL PASS. New:
`test/win32/chooser-sessions-remote.ps1` ALL PASS (19) and `-NegativeControl`
ALL PASS (13); `chooser-sessions.ps1` still ALL PASS (16).

## 2026-08-02 - T320 (T146 split): a browsed session becomes openable, and the test's own fixture was the bug

Return on a session row now dismisses the chooser and opens a window whose pane
ATTACHes to that session. The keyboard model is Mac's verbatim - Right steps
into the roster, Up/Down walk it, stepping above the first row hands navigation
back to the machine list, Return resumes the cursored row instead of the
machine's primary action - and it needed no focus plumbing at all, because
`handleKey` already intercepts arrows and Return before any control sees them.
Left/Right are consumed only when the filter cannot use them: in a field with
text they are caret keys.

Mac's index-space rule (`highlightedSessions` filters to `isConnectable` so
Return resumes the row the highlight is on) is STRUCTURAL here rather than
duplicated: the painter, `killAt`, `rowAt` and the cursor all take the same
`[]const VisibleRow` that `visible()` returned, so there is no second list to
disagree with. The cursor is clamped where it is used, not kept in sync, so a
roster that shrank under it cannot resume whatever slid into the index. The
alive guard lives once, in `resumeTarget`, which hands back `.none` for a
tombstone - callers have nothing to forget.

One deliberate divergence, filed as T330: a row already open in one of our own
panes is FOCUSED, not attached twice. The agent rebinds a session to its newest
ATTACH (`agent/server.zig:1026-1067`), so Mac's unconditional resume takes the
pane away from the window that has it, and "show me that session" is satisfied
either way.

The lesson is the fixture. A session that is merely listed cannot test resume -
every session the app has open takes the focus short-circuit - so the test needs
a live session with NO viewer, built the way a user gets one: run panes under
the agent, kill the APP only, drop the layout manifest, relaunch. The first run
failed 6 assertions and all 6 were the script assuming the agent lists sessions
in creation order and picking row 0. The agent's order is its store's; the app's
own session came first, so the "orphan" it resumed was a pane it already had
open. Rows are chosen by what they ARE now (alive, no viewer) and the cursor is
walked to that index - which tests the index space harder than a fixed 0 did.

Follow-ups: **T331** (the REMOTE half of resume has never run on box; T319's
FakeRelay can answer one), **T332** (`+list --json` never reports a pane's
session, so the pane-side oracle this task's own validation assumed does not
exist), **T333** (`adopt` resets the scroll, which now jumps a parked cursor off
screen on a refresh in place).

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0, the full
Debug GUI link exit 0, `test-agent` exit 0. P1-P3 ALL PASS. New:
`test/win32/chooser-resume.ps1` ALL PASS (21); `chooser-sessions.ps1` still ALL
PASS (16).

## 2026-08-02 - T321 split -> T334: this machine was invisible to Restore All, because it pushed nothing

T321 (agent-owned layout blobs + Restore All) was split before it was started.
Reading its three parts against the code turned up a fourth nobody had scoped:
**win32 pushes no layout blobs at all.** `grep -rn "setLayout|requestLayouts"
src/apprt/win32/` matches only doc comments, and the sole `Connection.setLayout`
caller in the tree is `embedded.zig:2909` - the C API Mac's
`LocalAgentManager.pushLayout` uses. So the store Restore All reads from is
always empty here, and a Windows machine cannot be restored from anywhere,
including from itself. Children: **T334** (this), **T335** (the button, the
`>= 2 alive` rule, the LOCAL rebuild, the CLAUDE.md correction), **T336** (the
cross-machine half; it closes T146). **T337** came out of the same reading and
is not a child: the blob schema is lineage-shaped, so a Mac viewer decodes
nothing from a Windows machine and vice versa.

T334 is the plumbing. `Connection.setLayoutNoWait` is the fire-and-forget
`SET_LAYOUT` (mirroring `closeSessionNoWait`): `enqueue` only appends to the
writer thread's queue, so the mirror never touches the socket on the UI thread.
It is deliberately ungated where `close_session` is gated, and the reason is
checkable: these opcodes shipped in the SAME commit as the agent handler that
answers them (`43bfb8e4a`, 2026-07-16), which predates every `ghoztty-agent.exe`
that has ever run - there is no skew window. `layout_blobs.zig` (new, pure, in
the every-lane test block) is the two conversions: a window out to blob +
session ids, and a `LAYOUTS` reply back to replayable windows. A malformed INNER
blob is skipped and counted; a malformed OUTER payload is an error, because
answering "no windows" over a transport fault is the failure that looks like
success.

The design decision worth keeping is that the push is a **reconcile, not an
edit**. There is no window-close hook: each sync re-pushes only what changed and
DELETES every tracked key that is no longer live. That same property is what
makes the manifest's index-derived key safe - closing window 0 renames window 1
to `win-0`, and one pass pushes the new bytes and deletes the absent `win-1`.

Two lessons from the acceptance script, both about asserting too early. The
session id a record claims is NOT present on the first push (the pane publishes
it asynchronously; `syncSessionLayout` already re-arms a retry for exactly
this), so the script waits for the record to settle rather than to exist. And PS
5.1's array unrolling failed only the SIMPLE case: the single-leaf window came
back from a helper as a bare `PSCustomObject` with a `$null` `.Count`, while the
three-node split tree survived - so the trap passed the interesting assertion
and failed the trivial one, which reads exactly like a product bug in the
single-pane path.

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0, the full
Debug GUI link exit 0, `test-agent` exit 0. P1-P3 ALL PASS. New:
`test/win32/layout-blobs.ps1` ALL PASS twice (21 assertions).

## 2026-08-02 - T335 (T321 split): Restore All, and a Tab walk that never walked

The button T177 packed a slot for finally exists. Selecting a machine with two
or more LIVE sessions offers **Restore All**, which pulls the layout blobs T334
started pushing, probes liveness, and replays each window through the SAME
`restoreWindow` that launch-time restore uses - so a rebuild is a restore
sourced from the AGENT's copy rather than from this box's manifest. That source
is the point: it works when the local manifest is gone, which is exactly the
case a crash produces and exactly when launch-time restore can do nothing.

Mac's `>= 2 alive` rule ported with its reason attached: one session has no
topology to rebuild and Resume already opens it, so a Restore All that lights up
on one pane is a second button for the first button's job. The predicate is
`alive`, not `isConnectable` - two relaunchable tombstones look like two rows
and have nothing to attach to.

Two properties are load-bearing and neither is obvious. The composition is
re-applied when the ROSTER changes, not only when the selection does: the roster
arrives asynchronously, so a button derived from it and computed only on
selection change is computed before its data exists and never appears. And the
rebuild skips a window whose sessions are already open here - the agent rebinds
a session to the newest ATTACH, so a second rebuild would take the panes out of
the window it just made.

The interesting failure was in the harness. `Send-TestKeys` SetFocus()es its
`-Target` before posting, so five Tabs aimed at the filter walk the same first
step five times; a probe printing the focused HWND after each said `filter,
list, list, list, list`. Each Tab has to be re-aimed at whatever now holds
focus. That is also why a real defect had survived since T177: the chooser's Tab
ladder never recognised the Activity button, so focus on it read as the filter
and Tab jumped back to the list. **No test had ever taken a second Tab.**

Filed **T338**: the blob key is not stable across app runs (`window-N` comes
from a per-process counter), so the relaunched app's blank window takes the dead
run's key and the previous first window becomes unrestorable - verified with a
before/after reading of the agent's store. The new script names its fixture
window to work around it.

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0, the full
Debug GUI link exit 0, `test-agent` exit 0. P1-P3 ALL PASS. New:
`test/win32/chooser-restore-all.ps1` ALL PASS twice (31 assertions). Regression:
`chooser-resume.ps1`, `chooser-sessions.ps1`, `ipc-machine-chooser.ps1` (72) and
`layout-blobs.ps1` all ALL PASS.

## 2026-08-02 - T338: a window that outlives its app run needs a name that does too

Restore All rebuilds what the agent holds, and for an ordinary window the agent
no longer held it. The blob key was the manifest window id - the ipc name when a
window has one, `win-{index}` when it does not - and NEITHER survives an app run:
the auto ipc name `window-N` comes off a counter that restarts at 1 per process.
So the relaunched app's blank startup window pushed under run 1's first window's
key, the push is an upsert, and the topology was gone inside the 250ms layout
debounce. The one case Restore All exists for - a crash that took the local
manifest with it - is also the case that destroyed the record.

Every window now carries a `layout_uuid`, generated from the same `pane_id`
generator the panes use and re-adopted by `restoreWindow` - which covers both
rebuild sources for free, since launch-time restore and Restore All both arrive
there as a `session_layout.Window`. The manifest records it as an optional
`uuid`; the key is `uuid orelse id`, and that fallback is the only path a
pre-T338 blob can take.

The consequence worth writing down: this makes the agent's store an ARCHIVE
rather than a mirror. Old blobs stop being recycled, and nothing in the app
bounds them - the delete pass deliberately only reaches keys THIS run pushed.
What bounds them is `SessionStore.reapLayouts`, which drops a record once none of
its sessions exists. That was always true; it just was not load-bearing while
every key got overwritten anyway.

The positive control is the evidence. Reverting only the key expression turned 9
assertions red - but F3, "the dead run's record survived under its own key",
stayed GREEN, because the key `window-1` was still there. Only its CONTENTS had
been replaced. A test for this defect has to assert what a record SAYS, not that
it exists.

`chooser-restore-all.ps1` lost its workaround: it named its fixture window
precisely because an explicit ipc name was the only stable key. Its startup
window is now split too, so the crash orphans two multi-pane windows and both
must come back (1 -> 3). The unnamed one is found by SHAPE, not name - its
`window-N` collides with the one the relaunched app already handed its own blank
window, which is T121's problem, not this one's.

Filed T342 (that script's step-4 Tab walk failed once in two runs; a flaky
positive control is worse than none) and T343 (in-place agent recovery still
pairs windows to captures by POSITION, restating the capture's skip rule by hand
- the uuid is a real key it could use).

Lanes: `test -Dapp-runtime=none` exit 0, `-Dapp-runtime=win32` exit 0, the full
Debug GUI link exit 0, `test-agent` exit 0. P1-P3 ALL PASS.
`layout-blobs.ps1` ALL PASS (37, incl. the new section F). `chooser-restore-all.ps1`
ALL PASS (36).
