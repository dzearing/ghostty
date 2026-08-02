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

**THE BAR, RESTATED AND SHARPENED (user, 2026-07-31, verbatim):** *"Your idea
of parity is not the same as mine. I mean, pixel parity, the UX looks and feels
cohesive and polished and scrubbed, and it isn't just buttons that exist in the
same place, but it looks like a posh win32 version of the MacOS app. The borders
look nice. There's a master details view. There are ways to get to the activity
viewer. If you haven't even built the activity monitor, then you don't have
parity with the dialogue in the MacOS app."*

This is a **correction**, and it retires the reading that had been in force:

- **A control that exists in the same place is not parity.** T172/T175/T176
  shipped the chooser's rows, master-detail and row menu and the tracker read
  that as the chooser being done. It is not done: the Activity Monitor behind
  its detail row was never built (T226), its button was never filed until
  T177, and nothing has been judged for finish.
- **Pixel parity and polish are part of the deliverable, not a follow-up.**
  Borders, seams, selection states, type ramp, DPI. Measure the target the way
  T202 did (`win32-tab-strip.md`) rather than eyeballing it.
- **"Posh win32 version of the macOS app"** is the phrase to design to — a
  Windows-native execution held to the Mac original's level of finish, not a
  cloned macOS dialog and not a functional stand-in.
- **A missing panel is a missing feature, even when its host dialog looks
  right.** Before calling any surface parity-complete, ask what every control
  on the Mac side OPENS, and whether that thing exists here.

**THE GOAL (user, 2026-07-15, verbatim intent):** Windows Ghoztty at full
parity with Mac Ghoztty, *very reliable and usable for long contexts*.
Thoroughly test it, optimize, fine-tune, make the Windows things look
Windows-native. Not slow, not crashing — well tuned and well tested.
The user is stepping away: do NOT stop to ask clarifying questions; audit
your own trail; use adversarial investigation for hard problems and
recommended approaches where they exist.

## Current priorities (user directive 2026-07-15, overrides table order)

Work these first, in order, before falling back to first-todo-in-table:

00000. **LOOP RELIABILITY, 2026-07-31 — T241.** Ahead of the UI block because
    the loop's own reliability gates every other item on this list (the same
    reasoning that kept T208/T210 in the top block).

    Delivering T232, the upgrade relaunched claude in-pane and never updated
    the lock's `claude_pid`. Four minutes later the watchdog read the stale pid,
    concluded "owner claude is gone", and **typed a `.cmd` path into a pane
    running a Claude Code TUI** — so the path became a user message and nothing
    re-entered. `send-keys exit=0`; no error anywhere. The loop survived only
    because the user saw the stray path and pasted it back.

    Every delivery opens that window, and this is exactly the silent-death mode
    that already cost six days once. Fix both halves: the upgrade must hand the
    lock its new pid, and the watchdog must not use the shell-prompt shim on a
    pane that already has a live claude in it (its `nudge` branch is already
    correct for that case).

00000. **~~T240~~ (done, 2026-07-31) — the right-click context menu was
    unreachable in every pane the user runs.** *"there is no right click
    context menu like in the mac version. WTF."* The menu existed (17 items,
    Mac order, T102) but was gated on the core returning `!consumed`, and
    mouse reporting consumes a right-press — verified live: Claude Code at its
    prompt (v2.1.220) has reporting ON. A right-press that reporting would
    swallow now opens the menu instead (`Surface.rightPressWouldReport`, asked
    BEFORE the core sees the press); `right-click-action = paste` still hands
    the click to the app.

    Two process lessons survive it. **An acceptance script that synthesizes
    the trigger cannot validate the trigger** — `context-menu.ps1` is
    PostMessage-driven, so its 19 green assertions could never see this; the
    new `test/win32/context-menu-real-input.ps1` clicks for real. And **a
    synthetic-input probe needs a positive control**: a broken `INPUT` struct
    made `SendInput` send nothing and produced a confident, wrong
    "reproduction" in a pane that was fine.

    T240's own first lesson — *a parity claim about Mac behavior must cite the
    Mac source line* — then landed on T240: it cited the line but modeled the
    framework wrong. AppKit's documented right-click path is
    `NSView.rightMouseDown` → `menuForEvent:`, not the reverse, which would
    mean Mac suppresses the menu under reporting too. **T246** has the Mac seat
    settle it empirically in minutes.

    **~~T150~~ (done, 2026-07-31)** rode directly behind it: the user wanted
    the menu's *Background Color…* to actually adapt (*"plus a bunch of logic
    for remapping foreground colors to adapt"*). The picker already set a
    background and a contrast foreground; what was missing was everything
    underneath — palette 16–255 was never regenerated (index 250 sat at 1.67:1
    on a light pick, now 10.6:1), truecolor was beyond every palette until
    `min_contrast = 3.0` reached it at draw time (230,230,230 → 138,138,138 =
    3.03:1), and two sub-floor holes in the color math itself — a Rec.601
    side-choice that put `#777777` on white at 4.42:1, and a one-sided L*
    search that returned still-failing colors. Both of those last two are in
    the Mac code it was ported from: **T247**.

    Its process lesson is **T248**, and it is not confined to color:
    `+new-window --target=` is idempotent against a **persisted** session, and
    killing `ghoztty.exe` does not remove one. So from the second run onward,
    an acceptance script that reuses a target name never runs its fixture — it
    focuses last run's pane and measures last run's pixels. The fix is to kill
    the repo's agent too and launch with `--session-persistence=off`.

0000. **THE UI QUALITY BLOCK (user, 2026-07-31, with screenshots).** The user
    walked the tab strip pixel by pixel and every complaint checks out as
    arithmetic. The systemic answer landed first:
    **`docs/design/win32-design-system.md` is now mandatory reading before any
    win32 chrome change**, and CLAUDE.md points at it. The rules it fixes —
    one 4 DIP spacing scale, nothing touches anything, **gaps measured between
    PAINTED edges not hit boxes**, size the container to the control, one icon
    button size, contrast floors, a radius/elevation scale, glyphs as filled
    shapes with optical widths, 2 DIP dividers with real hover, vertical space
    belongs to the terminal, horizontal chrome sizes to content with a
    proportional cap.

    Then the tasks that bring the chrome into compliance:

    **~~T232~~ → ~~T242~~ → ~~T235~~ → ~~T233~~ → ~~T254~~ → ~~T256~~ →
    ~~T234~~. The UI quality block is done.**

    **~~T234~~ (done, 2026-07-31)** was the big one, and it returned **50
    physical px of terminal to every window at the user's 125%** (40 DIP, 2-3
    rows), measured as the pane's own top: 45 px below the client top with one
    tab, 95 with `--window-show-tab-bar=always`. Both halves shipped together
    because they ARE one change — the strip could not go away while it was the
    app's only menu host, which is what pinned `auto => true` on Windows from
    T190 until here. `auto` is now `tab_count > 1 or !customCaption()`, and the
    menu lives in the caption as a "…" button that answers **`HTSYSMENU`** (so
    it takes Windows' own non-client path and announces itself correctly),
    opens on PRESS like every menu bar, and sits `pad_md` — not `pad_sm` —
    clear of the system trio because ours and the OS's are different GROUPS.
    It deliberately does NOT get the top-right corner: that belongs to close.

    Two follow-ups. **T260**: the strip's own hamburger was KEPT, and the why
    is the task — it is still the only menu host on a caption-less window, so
    it has to become *conditional*, which moves `runWidth`, the datum three
    scripts key off. **~~T259~~ (done, 2026-07-31, with T257)**.

    **~~T257~~ + ~~T259~~ (done, 2026-07-31)** cleared the way for T205. The
    chrome datum now lives once, in `test/win32/lib/ChromeGeometry.ps1`
    (dot-sourced from `TestDesktop.ps1`, so every script already loads it), split
    on the line that matters: positions and gaps are **derived** the way the
    layout modules derive them, tab widths are **measured** off a capture
    because they come from text metrics. Private copies went to zero across
    **four** scripts, not the two T257 scoped.

    Its lesson is the argument for hoisting at all, and it is not "less
    duplication": the layout modules round with Zig's `@round` (half away from
    zero) and PowerShell's `[math]::Round()` is BANKER'S rounding. One of the
    five copies got that right. The two agree at 100/125/150/200% and diverge
    at 112.5%, so four scripts carried a latent DPI bug that no run on this box
    could surface. **Four copies meant four chances to be wrong and no way to
    notice.** Two loose plausibility bands also became exact checks against
    `bar_h`, because the exact number was finally reachable.

    T259's own half — `tab-color.ps1` derived `scale` from a `barH` that was
    really `caption_h` (1.125 vs a real 1.25) and rebuilt tab widths from
    T202's retired rule: 225 px against real chiclets of 346 and 344, a ~120 px
    error that put every right-click on empty strip. Deleted, not repaired.

    **~~T205~~ (done, 2026-07-31) — the tabs are in the titlebar.** The
    prediction held to the letter: two app files, and ONE new argument
    (`-StripVisible`) across `ChromeGeometry.ps1` and its nine call sites.
    Measured at the user's 125%, chrome went from 95 physical px to 50 — **45
    px of terminal back on every multi-tab window**, on top of T234's 50.

    Two decisions carry it. **Chrome that shares a row shares a baseline:** the
    caption buttons take `btn_top` from the STRIP's own derivation, because the
    "+" and the tab close "×" have been on that frame since T204 and centering
    the square in the 40 DIP band would have landed 2 px off it — reproducing
    the user's complaint inside the fix. And **two painters, one row, disjoint
    blits:** `band_left` is the seam, so a caption repaint cannot erase a tab
    and the paint ORDER stops mattering.

    Its interest is the lesson: **two scripts had never controlled their own
    window size** and were inheriting `window_placement-debug` from whichever
    GUI script ran last, so their conditions depended on RUN ORDER —
    `tab-strip.ps1` 3 red, `menu-bar.ps1` 2. Every condition `tab-strip.ps1`
    sets up is a ratio OF THE TAB RUN, and it was not controlling the input the
    ratio is taken of. **T267.** Two more probes would have been GREEN AND
    EMPTY: `menu-bar.ps1` was clicking the caption's close button and asserting
    that nothing happened, which a posted CLIENT click can never make happen.

    Follow-ups: **T265** (a pinned window title has nowhere to paint on a merged
    row), **T266** (the top resize edge now sits ON the tabs — measure WT before
    changing it), **T267** (above).

    **~~T256~~ (done, 2026-07-31)** unblocked it and closed T254. The caption
    band moved the strip off client `y = 0`, and both scripts that measured it
    from there failed — `tab-strip.ps1` 7, `menu-bar.ps1` 19. Its lesson is
    wider than the offset: 4 of those 19 were **T235's** width change, not
    T254's origin change, because `Strip-Geometry` re-implemented the tab SIZING
    rule to locate the "+". *A script cannot re-derive a width that comes from
    text metrics.* The tab run is measured off a capture now. Follow-ups:
    **T257** (both scripts still keep private copies of the same chrome datum —
    hoist it before T205 moves it a third time) and **T258** (`test-agent` is
    flaky: a different `remote/agent/server.zig` ConPTY assertion fails on ~2
    runs in 3, which trains turns to re-run a floor lane until green).

    - **T233 (done, 2026-07-31)** — *"I think the splitter lines should be 2px
      and have a hover color that emphasizes it."* Both halves were real:
      `bandPx` was 1 DIP, which rounds to a **single physical pixel at both
      100% and 125%** — the two scales most users run — and hovering changed
      only the cursor, which tells nobody who is looking at the divider. Now
      `max(round(2 * scale), 2)` (a deliberate Mac divergence, recorded in
      design system §5) plus a hover/drag shade whose SIGN is asserted against
      `icon_button.fillDelta` rather than restated. Shade direction comes from
      the PANE background, not the OS theme.

      Two lessons. **A `GetDC` paint never marks the region dirty**, so the
      hover was correct on screen and invisible to `PrintWindow` — the pixels
      never reached the backing store, and two assertions failed against a
      build that was behaving correctly (**T252** audits the other sites).
      And **a posted `WM_MOUSEMOVE` cannot hold a hover on the test desktop**:
      `TrackMouseEvent` watches the REAL cursor, so `WM_MOUSELEAVE` lands
      within one frame — proved with a debug log on both sides rather than
      assumed, and the oracle was split into the COLOR (pixels, mid-drag) and
      the TRIGGER (debug log). Follow-ups **T250** (the hero divider still
      disagrees with §5 in the same window) and **T251** (a user's
      `split-divider-color` has no contrast floor).

    - **T235 (done, 2026-07-31)** — *"you have tons of horiz realestate, and
      yet you are truncating the tab text here."* `max_tab_w = 200 DIP` is
      retired: a tab is its measured title plus padding, floored at 60 DIP and
      capped at **50% of the tab run**, falling back to T202's equal share only
      under pressure. The anti-stretch rule survives untouched. Measured at the
      user's 125%: a long-titled tab 690 px against the retired cap's 245 — and
      the *default* title already wanted 344, so the cap was truncating
      essentially every tab, not just long ones.

      Two lessons. **A one-title window cannot test a width rule** — under a
      single shell-set title a fixed cap and a content-derived width are
      indistinguishable, which is why `tab-strip.ps1` was green through the
      whole defect; it now puts two different titles in one window. And T202's
      reasoning was wrong in a way worth naming: the Windows Terminal
      measurement was right, but *"equal-share-capped needs no text measurement
      in the layout module"* was **convenience presented as a design rule**.
      The module is still text-free — the caller measures and passes widths in.
      Follow-up **T249**: a tab's width is now a function of a string the shell
      rewrites constantly.

    - **T242 (done, 2026-07-31)** — *"the active tab seems to have a horizontal
      line at the bottom, making it feel disconnected from the pane below."*
      Root-caused: `sdTab` clips the silhouette square at the baseline with a
      half-plane (`max(body_round, y - b)`), and the rim is derived from that
      same field — so it faithfully traces an edge that isn't real. At the
      bottom row `sd = -1`, so `rim = 1.0 * RIM_BOT (0.04)`, lightening the
      seam row by ~9 levels across the tab's full width. Fix: derive the rim
      from the UN-clipped shape; keep coverage clipped. Goes right after T232
      because it is the same surface and it defeats T202's entire selection
      idiom (the selected chiclet is supposed to MERGE into the pane).

    - **T232** — the strip's spacing and glyph geometry. Measured at the
      user's 125%: the "+" square sits **16 px** from the tab and **1 px**
      from the strip's bottom edge (a 16:1 ratio between two gaps that should
      be equal), and the close "×" clears the tab's top edge by 1–2 px. Root
      causes are gaps measured to hit boxes and a 29 DIP band holding a 26 DIP
      square. Also replaces `LineTo` pen strokes (which drop the endpoint and
      bias wide pens) with filled shapes, and gives the hamburger its own
      optical width. **Carries a blast radius: `bar_h` is the DPI oracle for
      three acceptance scripts.**
    - **T235** — tabs truncate titles at a fixed 200 DIP cap while the strip
      sits half empty. Size to content, cap at 50% of the run, keep T202's
      anti-stretch rule.
    - **T233** — split dividers: 2 DIP (1 DIP rounds to an invisible single
      pixel at 100/125%) with a real hover color change, not a cursor change.
    - **T254** — the prerequisite T234 assumed it already had. T234 sized
      itself small on *"we do own the caption bar … a paint + hit-test change,
      not a new mechanism"*; that is false, and **T205 had already written down
      why** a day earlier: every window is plain `WS_OVERLAPPEDWINDOW`, there is
      no `WM_NCCALCSIZE` anywhere in `src/apprt/win32/`, and T78/T203 only ask
      DWM to restyle *its* caption. So T254 builds the caption we do not have —
      NCCALCSIZE takeover, `caption_layout.zig`, our own min/max/close, and
      `HTMAXBUTTON` so Snap Layouts survives — once, for both callers.
      Ordering settled: **T254 → T234 → T205.** Its process lesson: *when a
      task's summary makes a load-bearing claim about existing machinery, verify
      it against the source before sizing the task, and read the sibling task
      that covers the same subsystem.* A claim inherited from another task file
      is not evidence.
    - **T234** — the big one: **no tab strip at one tab** (Mac shows none) and
      a "…" button in the caption bar left of minimize. Reclaims 32–40 DIP of
      every window. Now depends on T254; what remains here is the button rect
      plus the visibility rule.

000. **AHEAD OF EVERYTHING as of 2026-07-31 (user bug report, same day).**
    The agent-upgrade path is broken in two ways the user hit for real, and it
    fires on every upgrade with live sessions:

    **T229 → T230.**

    - **T229** — confirming the mandatory upgrade dialog **kills the app**:
      the windows never come back and the log stops mid-path (`in-place
      recovery` has never once printed in the whole on-box log, across two
      confirms). The user consents to losing their sessions and loses the app
      too, silently. This outranks the test-infra chain: it is the one place
      where a destructive confirmation ends in an empty desktop.
    - **T230** — after an agent reset we RELAUNCH each pane's recorded
      command (`session-relaunch = auto`). The user has explicitly rejected
      this: *"We should not ever re-execute the commands which were previously
      ran."* Replace the default with a fresh shell prompt plus a notice that
      names the previous command for copy/paste.

00. **TOP OF THE LIST as of 2026-07-31 (user directive).** Verbatim: *"Let's
    get the test infrastructure complete, but prioritize the new window parity
    and activity viewer immediately next."* So the 2026-07-30 chain below runs
    to completion, and then the Ctrl+Shift+N surface is next — ahead of
    anything else in this list or the table:

    **finish test infra (T217 → T218 → T213 → T214 → T225 → T209, with T210
    and T208 kept in that block because the loop's own reliability gates
    everything) → then T226 → T177 → T227 → T146.**

    - **T226 (new, 2026-07-31)** — port the Mac **Activity Monitor**. Windows
      has ZERO of it; it was never filed anywhere until now. Ordered FIRST of
      the three because T177 is the button that opens it, and a button that
      opens nothing is not worth landing on its own. The data plane is already
      cross-platform (`metrics.zig`, `proc.zig`, `proc_control.zig`,
      `proc_spawn.zig` all have Windows branches — verified by reading them),
      so this is a win32 UI task in the shape of `MachineChooser.zig`, not a
      systems task.
    - **T177** — the chooser detail row's missing **Activity** button (and a
      note that **Restore All** belongs to T146). Its "trace the Mac side
      first, and fold into T146 if it depends on session browsing" question is
      **answered: it does not.** The Activity panel is process/metrics
      monitoring, independent of T146, which is why T226 exists as its own
      task.
    - **T227 (new, 2026-07-31; split 2026-08-01)** — the **pixel-parity and
      polish pass** over the whole Ctrl+Shift+N surface (chooser + Host
      Settings + account row), judged as one cohesive surface. This is where
      the restated BAR above gets discharged. Deliberately ordered AFTER
      T226/T177, since both change the detail row's composition and a polish
      pass run before them runs twice.

      **~~T302~~ (done, 2026-08-01)** is its measurement half, and the target
      it paints to is now written down once, in
      **`docs/design/win32-machine-chooser.md`** — Mac's 45 metrics with
      `MachineChooserView.swift` line cites, Windows' measured through
      `SystemParametersInfoForDpi` / `GetSystemMetrics` / `uxtheme` / DWM, and
      a 13-item delta on the current chooser. Same move T202 made for the tab
      strip.

      Two things it settled. **T227's stated native-reference method does not
      work**: `PrintWindow(PW_RENDERFULLCONTENT)` returns a flat black bitmap
      for Task Manager / Settings / any WinUI app (DirectComposition, nothing
      in the window DC) and reports success while doing it — T214's terminal
      limit one class wider, and the same *empty rather than absent* failure.
      **T303** makes it throw. And **the three biggest defects on the surface
      belong to T203** — hardcoded dark, every wash/divider/hover blending
      toward white unconditionally, a hardcoded `#3D8EF8` accent against this
      box's real `#680081` — so T227 consumes that plumbing rather than
      re-deriving it, and keeps the type ramp, the avatar/monogram, the radius
      and icon column, the off-scale spacings, the list focus indicator, and
      the `secondary_gray` contrast floor.

      **~~T310~~ → ~~T311~~ → T312.** T311 (done, 2026-08-01) recomposed the
      account row: the band is now sized to its tallest CONTENT (36 DIP, up
      from the 28 control height) so it can hold Mac's email-over-link stack,
      "Sign Out" is an owner-drawn LINK beside a 32 DIP accent monogram, and
      both states' controls size to their own measured captions — the sign-in
      button is 198 px at 1.25 against the retired fixed slot's 188, and the
      link is 70. Its own follow-ups are **T315** (the link's hover can stick
      when the pointer leaves the dialog without crossing it — deferred because
      the obvious `TrackMouseEvent` fix has an unproven premise about a child
      under the cursor) and **T316** (the signed-out row still shows a sentence
      Mac has no state for; decide it and write it into §2.4 either way).
      **~~T312~~ (done, 2026-08-01)** — the owner-drawn list's focus indicator —
      closed the split, and with it T227. **The Ctrl+Shift+N polish pass is
      done.**
    - **T146 (split 2026-08-01 → T318 → T319/T320 → T321)** — the other half of
      the chooser's *function*: cross-machine session browse/resume, Kill,
      Restore All. Split before it was started, per the context rule: four Mac
      commits behind one title, and `MachineChooser.zig` (108 KB) matches
      `session` exactly **four** times, all four the relay error string
      *"Session expired — sign in again above."* — so the surface has zero of
      it.

      The children are **UI tasks, not systems tasks**, because the data plane
      is already cross-platform Zig and already called from win32:
      `Connection.requestSessions` (`connection.zig:1598`), `requestLayouts`
      (`:1693`), `closeSession` (`:2114`), with `App.zig:1263` already running
      the first against the local agent's warm shared connection. T295's
      dial-off-thread + ownership discipline is the pattern T319 reuses rather
      than re-derives.

      - **T318** — the LOCAL machine's roster in the detail pane, Mac's label
        ladder (`liveTitle` → agent title → persisted title → cwd basename →
        argv → `pid N`), and Kill.
      - **~~T319~~ (done, 2026-08-01)** — the same roster for a REMOTE machine
        over the relay. The prediction held: no new RPC, and the work was the
        dial, its ownership, and the per-row failures. Two things it turned up.
        A **third** `row != .local` gate, in `sessionView` — painting and the
        subtitle had lost theirs, so a remote machine's cards drew and could not
        be clicked; and `ws_client` collapsed every non-101 into one error, so a
        rejected bearer could not be told from an unreachable relay (it returns
        `WebSocketUnauthorized` on 401/403 now).
        The bigger half is that **no relay-dialled surface had ever been
        exercised on box** — `activity-monitor-remote.ps1` says so in its own
        header. `test/win32/lib/FakeRelay.ps1` is the stand-in: directory +
        a real WebSocket upgrade bridged to a `ghoztty-agent --listen`, with
        401/502 injection and a trip file. Follow-ups **T328** (a Kill on a
        remote row loses its refetch — the NOTE the script prints instead of
        asserting the bug green) and **T329** (T295's uncovered DIALED entry is
        testable at last).
      - **T320** — resume ONE browsed session. Two Mac rules carry it: only
        ALIVE sessions attach (a *relaunchable* tombstone needs `RELAUNCH`,
        a different verb), and the keyboard sub-cursor's index space must equal
        the rendered list's — the bug T312 just finished proving this list is
        prone to.
      - **~~T321~~ (split 2026-08-02 → T334 → T335 → T336)** — agent-owned
        layout blobs + **Restore All**. Split before it was started: reading its
        three parts against the code turned up a fourth nobody had scoped —
        **win32 pushes no layout blobs at all**, so the agent Restore All reads
        from is always empty here (only `embedded.zig:2909`, Mac's C API, ever
        calls `Connection.setLayout`). **T334** is that plumbing (SET_LAYOUT on
        sync + delete on close, GET_LAYOUTS decode); **T335** is the button, the
        ≥ 2-alive rule, the LOCAL rebuild through the existing
        `App.restoreWindow`, and the CLAUDE.md correction; **T336** is the
        cross-machine half and closes T146 — separated because win32 windows
        each OWN their transport where Mac hands every rebuilt window one
        connection, so N windows is N dials or a stated sharing rule.
        **T337** came out of the same reading and is not a child: the blob
        schema is *lineage-shaped* (Mac pushes camelCase
        `SessionLayoutManifest.Entry`, win32 will push snake_case flat-node
        `session_layout.Window`), so cross-machine Restore All works within a
        lineage and silently shows "nothing to restore" across one.

      **T322** came out of the same reading and should be settled before T318
      renders a row: `relaunchable` exists on the wire (`protocol.zig:576`) and
      in the client struct (`connection.zig:564`) but is **omitted from the C
      API row** (`embedded.zig:2820-2833`), so Mac's
      `isConnectable = alive || relaunchable` filter is a constant today and
      hides the resumable reboot-floor tombstones `wp4_e2e.zig:868` proves are
      resumable. Windows reads the Zig struct directly and would diverge by
      default.

0. **TOP OF THE LIST as of 2026-07-30 (user directive, mid-turn):**
   **~~T211~~ → ~~T212~~ (split) → ~~T216~~ → T217 → T218 → T210 → T208 →
   T213 → T214 → T209.**

   - **~~T212~~** — split 2026-07-30, too big for one context (65 scripts,
     35 grabbing foreground, 36 driving SendInput): **T216** (prove the
     mouse), **T217** (23 keyboard-only scripts), **T218** (12 mouse-driven
     scripts).

   - **~~T216~~** — DONE 2026-07-30. The verdict is **YES**: posted mouse
     input reaches the app and `TrackPopupMenuEx` runs on a background
     desktop, so no script routes to the T207 option-B bucket.
     `dark-menus.ps1` is the worked example for the mouse half.
     It found and fixed a product bug (`Surface.getCursorPos` erroring when
     `GetCursorPos` fails killed EVERY click, so right-click opened no menu —
     which also affects a locked workstation / secure desktop / disconnected
     RDP) and a test trap (an all-black mid-paint capture satisfies a "is it
     dark?" assertion; `Get-TestDistinctColors` is the guard). Read T216
     before doing T217/T218.

   - **~~T211~~** — DONE 2026-07-30. The shared harness is
     `test/win32/lib/TestDesktop.ps1`; dot-source it and read its header
     before writing or migrating any GUI script. `split-zoom-nav.ps1` is the
     worked example and `test-desktop-harness.ps1` is the harness's own
     acceptance script. It found and fixed a product bug (deferred focus was
     dead on a non-input desktop → sweep is **T215**) and narrowed T207's
     capture answer (PrintWindow gets chrome, not the terminal surface →
     **T214**, which now blocks T209 instead of T213 alone).
     **The no-GUI-tests-on-the-interactive-desktop rule still stands until
     T212 has migrated the rest of the scripts.**

   - **~~T207~~** — the user, verbatim, while a test run was grabbing their
     screen: *"you KEEP STEALING FOCUS USE ANOTHER DESKTOP for testing"*.
     **Spiked and split 2026-07-30 → T211 / T212 / T213.** The answer is a
     background `CreateDesktopW` desktop, and the spike
     (`test/win32/test-desktop-spike.ps1`, ALL PASS ×3) settled every
     mechanism question on box:
     isolation is **total**; `PrintWindow(PW_RENDERFULLCONTENT)` **works**
     there (so the pixel probes CAN move — that was the feared blocker and it
     is not one); `CopyFromScreen`/`BitBlt` is **dead** there; and the real
     blocker is **`SendInput`, which win32 refuses off the input desktop**
     (0 events accepted, ACCESS_DENIED) — posted `WM_KEYDOWN` plus
     `SetKeyboardState` over an `AttachThreadInput`-shared queue replaces it,
     chords included.
     **The rule stays in force until T212 lands: do not run any
     `test/win32/*.ps1` GUI script on the interactive desktop.** The unit
     lanes (`zig build test -Dapp-runtime=none|win32`, `test-agent`) never
     steal focus and are always fine.
   - **~~T210~~ (done, 2026-08-01)** — a resume prompt beginning with
     `/reset-context` was mangled on the way into the pane, the reset silently
     never fired, and the session ran to ~250k. **The cause was QUOTING, not
     length**: PowerShell 5.1 does not escape an embedded `"` when it builds a
     native command line, and the prompt's last hop to the pane was a positional
     `+send-keys` argument — T200 moved the *launch* onto a file and the
     identical defect survived one hop downstream. Measured: the transport is
     byte-exact at 1222, 2500, 5000 and 10000 characters, so the old
     "keep resume prompts SHORT" mitigation was aimed at the wrong suspect and
     is withdrawn. Prompts now travel by `--keys-file`, and the echo check is a
     GATE — verified BEFORE the Enter, because `/reset-context` clears the pane
     and a post-submit check would fail a correct delivery.
   - **T208** — the delivery path can ship a stale binary. Until it lands,
     build `--prefix zig-out-release` yourself and check `+version` against
     `git rev-parse --short HEAD` before AND after.
   - **T209** — the on-box pixel assertions T204/T206 could not run. Blocked
     on T213 (which gives them a capture path that works off the interactive
     desktop), not on T207 any more.

   T203 (system accent + light/dark) and T205 (tabs inside the titlebar) are
   the remaining tab-strip cosmetics and come after these four.

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
   failures were the layered alpha) and filed T136 + T137) → ~~**T130**~~
   (**DONE 2026-07-29** — mirrored to `dzearing/ghoztty-claude-plugin`
   `5a40ac9`, 0.7.0 → 0.8.0. The diff proved the task's own premise: 0.7.0 had
   ALREADY silently reverted the `# ` heading fix applied to the 0.4.0 cache.
   jq stays a dependency — vendoring a JSON writer for markdown-bearing values
   would corrupt banners rather than fail — but a missing jq now announces
   itself in a one-time per-pane banner instead of `exit 0`. `pane-id.ps1` ALL
   PASS (45)) → ~~**T133**~~ (**DONE 2026-07-30** — same, for the
   `/reset-context` composer wipe: mirrored to
   `dzearing/dzearing-claude-marketplace` `2ef7766`, 0.10.2 → 0.11.0, and it
   was the plugin's ONLY drift. The helper now verifies both the clear and the
   continuation by reading the pane back, shouting into its log and onto a pane
   banner when either fails, while always sending the continuation — liveness
   beats cleanliness. New `reset-context.ps1` ALL PASS (24) ×3 with a negative
   control that reproduces the filed `nn/clear`; filed T181) →
   **T38/T39 per item 20**.

3e. **USER LIVE-REVIEW, 2026-07-29 — do these FIRST, ahead of 3d.** The user
   came back to a stopped, forked loop and a chooser that is visibly not
   Mac-parity: ~~**T139**~~ (**DONE 2026-07-29** — `go.md` gained a **step 0**
   that takes a pane-keyed lock (`scripts/go-loop-lock.ps1`): a second session
   gets exit 3 and stops instead of building the same task twice, while a dead
   owner or a >30min-stale heartbeat is taken over so a crash can never wedge
   the loop. The other half is `scripts/go-loop-watchdog.ps1`, the supervisor
   `go.md` said did not exist: it watches that heartbeat and re-enters with the
   cheapest fitting action — nudge a stalled-but-live session, restart claude in
   a surviving pane, or open a window — while leaving a pane that is still
   emitting output alone. Installed and running on the box. Plus
   `scripts/go-loop-exec.ps1`: the execution window pins its title to
   `[go-loop] …` so it is distinguishable from the user's task-filing window —
   only marked windows are ever touched — and a duplicate is resolved with no
   human in the loop (the two sessions message each other; the loser closes).
   `go-loop-guard.ps1` ALL PASS (78) ×3, sections I–L real end-to-end against a
   live GUI. Filed T153) → ~~**T138**~~ (**DONE 2026-07-29** — the resume is a
   DECISION now: the script stamps the launching claude before the kill and,
   if it outlived the swap (which it always does since T89 — the agent owns
   the PTY), types the prompt into its re-attached pane instead of starting a
   second `claude --continue`. Two diagnostics were found lying while building
   the test: the `+sessions` probe parsed line-by-line against a
   pretty-printed array, so SESSIONS-SURVIVE had been SKIPPING since T89h; and
   `+new-window --target=main` is idempotent, so with the IPC names restored
   the relaunch FOCUSED the old window and ran nothing — the pre-fix negative
   control logged `UPGRADE OK (relaunched...)` with the command never started.
   `upgrade-no-fork.ps1` ALL PASS (48) ×3. Filed T166–T168) → ~~**T141**~~
   (**DONE 2026-07-29** — both verbs deleted; sign-in is now the chooser's own
   account row, Mac-shaped, run on a detached thread that posts back to the
   message loop so the window never freezes while the browser is open. The
   validation caught a real defect and MEASURED it instead of arguing it:
   `Escape` stopped working because disabling the focused button drops the
   thread's keyboard focus, and with no focus window `WM_KEYDOWN` arrives with
   `msg.hwnd == null`, which the dialog-key routing cannot attribute — so the
   whole dialog went deaf. A new cross-process `GetGUIThreadInfo` oracle failed
   pre-fix and passes post-fix. The audit's structural finding: the `Action`
   enum has no `builtin.os.tag` branch, so a one-platform verb cannot exist
   there any more — but the same divergence one level down does, and both cases
   are filed (**T169** `+version`'s Running Instance section, **T170** `+list
   --pid`, both Mac-seat; `+reload`'s Windows absence stays with T127).
   `ipc-relay-login.ps1` → `relay-account.ps1`, ALL PASS (53) ×3. Also filed
   **T171** for one unreproduced harness flake) → ~~**T140**~~ (rebuild the
   Ctrl+Shift+N chooser to Mac parity — **split 2026-07-30**, too big for one
   context: **T172** → **T173** → **T174**. ~~T172~~ DONE 2026-07-30
   (4e5c2e149: owner-drawn rows — status shape, drawn machine glyph, name +
   dimmed subline, and an INSET rounded accent pill instead of the full-width
   system-blue bar; cue-banner filter; a footer that wraps and grows the dialog
   by exactly its extra lines. `ipc-machine-chooser.ps1` ALL PASS (23) ×3 with
   a pixel oracle proven by a negative control — and two probes that lied
   first: DPI-virtualized `GetWindowRect` vs physical `CopyFromScreen`, and
   desktop-DC `GetPixel` being ~1000x slower than a blit). ~~T173~~ **split
   2026-07-30** — a layout port and a network-backed menu with its own modal
   prompt were two tasks in one id: **T175** (shell) → **T176** (menu). ~~T175~~
   DONE 2026-07-30: the chooser is Mac's 840x540 master-detail — account row +
   rule, a fixed 260-wide machine column on a wash, a vertical rule, a detail
   pane naming the selected machine with `New Window` beside it, and Cancel
   ALONE in the footer. Geometry moved to a pure `chooser_layout.zig`; the wash,
   rules and detail header are painted in `WM_PAINT`. Two defects the new
   assertions caught: a listbox snaps its height to whole items **at creation
   using the default item height** (so the column silently stopped flexing when
   the strip wrapped — fixed with `LBS_NOINTEGRALHEIGHT` plus our own whole-row
   snap), and `LB_SETCURSEL` does not notify (so arrow keys left the detail pane
   describing the machine you left). The detail pane below the header is
   deliberately EMPTY until T146 brings session browsing.
   `ipc-machine-chooser.ps1` 26 → 34 assertions, ALL PASS ×3.
   ~~T176~~ DONE 2026-07-30 (the per-row `⋯` menu + relay Rename…/Remove from
   Account…; filed T177). ~~T174~~ **DONE 2026-07-30**: Windows finally has
   per-host remote defaults — a `host_defaults.zig` store under
   `%LOCALAPPDATA%` keyed on the relay device id (else `host:port`, Mac's
   `settingsKey`), a `HostSettingsDialog.zig` two-row editor with Mac's 6 shell
   presets in an editable combo, and the gate in `chooser_menu` flipped so
   `Host Settings…` LEADS the row menu. Applied at Mac's exact two altitudes: a
   new remote window takes cwd + shell (seeded in `openDialedWindow`, the ONE
   open tail — Mac needs two sites), a tab/split takes the SHELL ONLY because
   its cwd inherits from the parent pane. New `host-settings.ps1` ALL PASS (61)
   ×3, driving the real GUI for the editor and a real loopback agent for the
   apply rules — including a measured before/after shell flip, so it proves the
   store changed the shell instead of matching the box default. Filed **T178**
   (`remote-inherit.ps1` red on 4 assertions, PROVEN pre-existing against a
   HEAD worktree). ~~**T142**~~ **DONE 2026-07-30** (overlay z-order
   self-healing): the filed stray-`HWND_TOPMOST` cause was real, but the new
   harness's HEALTHY-baseline assertion failed before any injection and that is
   where the user's report actually lived — `SWP_SHOWWINDOW` lifts a popup to the
   top of the non-topmost band and ownership only pins it above its OWN window,
   so a background window's banner floated over the foreground app with no probe
   involved. One helper (`win32.healOverlayZOrder`) clears the stray bit AND
   re-seats the popup above its owner, called on every reposition and on
   `WM_ACTIVATE` (the moment the defect is seen). Owner-RELATIVE, because
   `toggle_window_float_on_top` / the quick terminal legitimately propagate the
   bit to owned popups. `overlay-zorder.ps1` ALL PASS (24) ×3; negative control
   9 FAILED / 13 passed. Filed T179 + T180. **Next: T133** per 3d.

3f. **USER LIVE-REVIEW #2, 2026-07-29 (same day, later) — "The goal is
   complete parity with the macOS client."** The user named three gaps by
   hand and then asked for a full sweep: *"What other changes came in that you
   did not write parity for? Please review all the changes from the last 3
   weeks and make sure that there are workitems for all of the parity work."*
   That sweep was run (107 Mac/viewer commits since 2026-07-08, each grepped
   against every `windows-parity-*.md`) and **found 16 commits with ZERO
   references in any Windows doc** — filed as T145–T151. The three the user
   named were already tracked but not shipped, which is the real lesson:
   *tracked ≠ shipped, and a narrative sweep hides what an enumeration
   catches.* Order:
   - ~~**T127**~~ — the viewer panes. **DONE 2026-07-29** (re-scope only, no
     code): refreshed design in `docs/design/viewer-panes-windows.md`, v1 line
     decided, T90b–T90h each annotated instead of silently widened, new v1
     surface filed as T159 (nav chrome + address bar), T160 (markdown TOC),
     T161 (zoom + pane-scoped chords), T162 (selection-toolbar Copy), and the
     cuts filed as rows: T163 (popups), T164 (feedback capture, design-first).
     Two premises in the row were wrong and are corrected there: `--view` does
     NOT answer "viewers are not yet supported on Windows" (it is silently
     dropped — `VerbArgs` has no `view` field), and the shared viewer JS is not
     free (it posts through `window.webkit.messageHandlers`, so WebView2 needs
     a shim). **The viewer BUILD order is now T90b → T90c → T90d → T90e → T90f
     → T90g → T90h with T159–T162 sequenced behind their deps**; it is still
     the largest hole and still ahead of the cosmetics below.
   - **T123** — the banner table's fixed 360pt cap. Re-reported verbatim by
     the user, still `MAX_CELL_W = 360.0` at `BannerOverlay.zig:68`, and the
     Mac fix is a known-good port. Cheapest user-visible win on the list.
   - ~~**T144**~~ — **DONE 2026-07-30**: ctrl+n opened in `C:\Windows\System32`.
     The filed primary hypothesis held, but only after it was measured: the
     installed agent's own cwd (read out of its PEB while the user's build ran)
     really is System32, because the T89h `Run` entry starts it there — while a
     repo-launched debug agent sits in the repo, which is why the box never
     showed this. `Surface.zig` withheld the resolved `working-directory` from
     *every* remote agent; correct for a cross-machine one (the OPEN-stall
     wedge), wrong for the LOCAL one, so the OPEN carried no cwd and the child
     spawned wherever the agent sat. Now shared-core
     `termio.Remote.openWorkingDirectory`, matching Mac's
     `TerminalController.swift`. The escape-hatch half had two wrong premises in
     the row: the loader reads `config.ghostty` (the user's file was at the RIGHT
     path, just empty), and what wrote it was **Ghoztty** —
     `writeConfigTemplate` never flushed its 4096-byte buffer, so every user
     with no config got a zero-byte one, which then counted as "a config exists"
     and was never retried. Both fixed; empty configs self-heal, parse-failing
     ones are never clobbered. New `test/win32/new-window-cwd.ps1` ALL PASS (39)
     ×3 — section A proves the trap is ARMED before asserting it is harmless, and
     section D presses the REAL ctrl+n because `+new-window` always inserts the
     caller's cwd and so cannot reproduce the bug. Negative control: 8 failures,
     all of them the user's report. Filed **T185** (a Windows pane reports its
     INITIAL cwd forever — no OSC 7 from cmd/powershell) and **T186** (Mac seat:
     both changes are shared core; the template flush is likely upstream).
   - ~~**T187**~~ — **DONE 2026-07-30, jumped the queue** (the T112 precedent:
     the loop's own continuation mechanism gets fixed first). T144's delivery
     logged `RESUME-REUSE FAIL: the app did not come back up` while the app was
     up and answering, so the resume prompt was never typed and the loop sat
     dead until the user pinged. Both filed mechanisms were REFUTED by
     measurement — restore is 451ms with a healthy agent and 10.7s with the
     agent suspended outright, so it can never produce a 60s blackout. The
     defect was the probe: `+list` ran with no timeout and the wait loop only
     checked its deadline between calls, so one blocking probe swallowed the
     whole window. Now a bounded `Invoke-GhozttyListJson` in `loop-session.ps1`,
     a wait that watches the started PROCESS and logs every failure, and a
     180s deadline. `upgrade-no-fork.ps1` A22–A30 ALL PASS. Filed **T188** for
     the pre-loop restore latency on its own merits.
   - ~~**T143**~~ — the missing menu bar. Every discoverability complaint
     (T129 included) was a symptom of this. **DONE 2026-07-30** via its two
     halves: ~~T189~~ (the host decision + `commands.zig`/`menu_bar.zig`, the
     ONE list the palette and the menu both render) → ~~T190~~ (the `≡`
     tab-strip button, the recursive HMENU, dispatch through the single
     `Surface.performCommand`, accelerator labels from the live keybind set,
     and F10 / lone-Alt activation; `menu-bar.ps1` ALL PASS (49) ×3 with two
     real negative controls). T190 also had to make the tab strip show in a
     single-tab window — on Windows the strip IS the menu host, so `auto`
     hiding it left the menu invisible in exactly the default window the
     user's report was about. Filed T191/T192/T193 along the way.
   - **T145 → T147 → T146 → T151 → T148 → T150 → T149** — the sweep's
     findings, session-persistence correctness first (crash recovery, then
     non-destructive upgrade delivery — both are CLAUDE.md contract gaps, not
     feature gaps), then the chooser's function, then the cosmetics.
   - **T152** — make the sweep a gate, not a habit, so the next merge cannot
     leak the way T88's and T117's did.

3g. **USER LIVE-REVIEW #3, 2026-07-29 (same day, later still).** Two more,
   both root-caused by inspection before filing — neither needs a build to
   diagnose, and both are small: ~~**T154**~~ (**DONE 2026-07-29**, 61e4e847c —
   the filed one-flag diagnosis was right and the row's own testable
   prediction held: pre-fix, an image-only clipboard + ctrl+v delivered NO
   character to the pane while ctrl+shift+v delivered 22, so the defect was
   the `performable` flag and not the chord. New `clipboard-paste.ps1` proves
   it with an in-pane `[Console]::ReadKey` probe — reading rendered text
   cannot tell "pasted nothing" from "swallowed the key", a character code
   can. ALL PASS (12) ×3. Audit of the rest of the block found one real gap
   (**T156**, shift+insert); building the harness exposed **T157**, the
   standing `keybinds-t01.ps1` failing its own positive control) → **T155**
   (split dividers
   accumulate stale lines because the parent's `WM_ERASEBKGND` paints
   nothing and the divider is stroked outside the paint cycle). T154 is the
   cheapest fix on the whole board and unblocks the user's daily workflow;
   do it first. Slot both ahead of the 3f cosmetics (T149/T150).
   ~~**T155**~~ — **DONE 2026-07-29**: defects (b) 3-edge render and (c)
   inconsistent width were as filed, but **(a)'s mechanism was filed wrong and
   the first oracle passed on the broken build** — dragging a divider does NOT
   leave the old line behind (the growing pane covers it); repeated SMALL
   window resizes do, each drifting the split by less than the gap was wide.
   Measured, not argued: 3× 4px shrink gave TWO bands pre-fix, 6/8/10/14px gave
   one. Fixed with a new pure `split_geometry.zig` (gap == band == 1 DIP, Mac's
   `splitterVisibleSize`, so panes and divider TILE and no parent-owned pixel
   can hold a stale line) + FillRect instead of a stroke. A `WM_ERASEBKGND`
   handler was tried and REVERTED — it regressed `pane-banner.ps1` and the
   tiling makes it unnecessary. `split-divider.ps1` 15 → 25 assertions, ALL
   PASS ×3 (pre-fix: 2 FAILED, both on the resize case, both axes). Filed
   **T158** (the ~28 other scripts that launch without
   `--session-persistence=false`). Next: **T130** per 3d.

3h. **USER LIVE-REVIEW #4, 2026-07-30 — the tab strip. DO THESE FIRST, ahead
   of everything in 3d–3g.** The user screenshotted a single-tab window and
   named four things by hand: *"there's some weird blue line ... why is the
   blue line on the bottom???? and then there's a + button which is butt up
   against the edge of the tab and looks clipped and a weird hamburger button
   which is misaligned from the x button. It just looks HORRIBLY amateur. Like
   a backend developer built the ui."* Plus the standing bar: *"You need to
   use expert design skills to build something that feels well designed and
   native to windows, but retains the functionality of ghoztty. We have a high
   bar for quality."*

   All four complaints are real and all four were read out of the code, not
   guessed — `drawTabBar` in `src/apprt/win32/Window.zig`. The strip was grown
   feature-by-feature (T72 stripe, T78 font, T190 menu button) and has never
   had a visual design pass. Filed as three tasks, in this order:
   - **T202** (geometry, shape, selection idiom) — do FIRST, it sets the
     layout model the other two paint into. One structural bug causes three of
     the four symptoms: a single tab is stretched to the full client width
     (`Window.zig:2741` hands the last tab the remainder, bypassing the
     `max_tab_w` computed 16 lines above), which is what throws the close
     button to the far edge, jams the "+" against it, and stretches the
     selection accent into the full-width blue rule the user asked about. The
     accent itself is the wrong idiom: a bottom underline is Fluent's
     NavigationView/Pivot selection cue, where it is short and centered — a
     TabView marks selection with a rounded-top chiclet filled in the content
     background and needs no line. Extract the geometry to a pure
     `tab_strip_layout.zig`; it is inline in a 300-line paint function today,
     which is why none of it is testable.
   - **T203** (system accent + light/dark theming) — the accent is a hardcoded
     `RGB(0x3D,0x8E,0xF8)` literal (`Window.zig:2683`, and the same literal is
     duplicated in the chooser's selection pill from T172), and every other
     color is `background + 20/+35` per channel, which assumes a dark
     background and collapses to near-white in a light theme.
   - **T204** (the control glyphs) — the user's "misaligned" is exact: close,
     "+" and menu are text characters drawn `DT_LEFT` in three
     differently-sized boxes, with the close button vertically framed
     differently from the other two. `DT_CENTER` appears nowhere in the
     function. Needs one shared icon-button helper so alignment is structural.

   - **T205** (tabs belong INSIDE the titlebar) — filed from the user's
     follow-up the same evening, sent with a stock Windows Terminal screenshot
     as the reference: *"this is normal terminal and it looks more polished
     than what you've built ... the hamburger icon is too small and doesn't
     horizontally align under the X above it, icons still feel too small."*
     The alignment half is not a T204 nudge — that X is the WINDOW's caption
     button on a separate row, and Terminal/Edge/Explorer all put tabs *in*
     the titlebar. Two rows with two owners (DWM owns the caption, we own the
     strip) can only ever approximately align, and the approximation drifts
     with DPI and caption width. T205 removes the second row. Highest risk of
     the band (custom `WM_NCCALCSIZE` frame — dragging, Snap Layouts,
     maximize padding, high contrast), so it goes LAST, after T202–T204 have
     settled the strip's own painting. The icon-size half of that quote is
     T204's: the glyphs inherit T78's tab TITLE font (~12 px) instead of being
     chrome-sized 16 DIP in a >=32 DIP square.

   - **T206** (tab chrome shares the banner card's language) — *"the tab
     should have similar borders to the banner. It should feel cohesive"* plus
     *"they don't show shadowing around the active tab, and i really can't
     make the tab out on the background."* The legibility half is measurable,
     not taste: the strip is `background + 20` and the active tab is the raw
     `background`, ~8% apart, with no rim and no shadow reinforcing it. Derive
     the contrast target by MEASURING the banner card against its own pane
     background — that surface is already legible and signed off, so it keeps
     the two cohesive by construction. Deps T202+T203.

   Note these are cosmetic-looking but rank above the 3f cosmetics on purpose:
   this is the chrome the user sees every time the app opens, and it is the
   specific thing they called amateur.

3i. **USER LIVE-REVIEW #5, 2026-07-30 — the harness takes the box hostage.**
   *"when you're running tests, you keep stealing focus. is there any way they
   could be run in docker image so i can use my compute."* Filed as **T207**.
   Docker is a dead end for the scripts that hurt (Windows containers have no
   DWM, no window station, no display adapter — the 6 pixel-probe scripts and
   every T202–T206 visual assertion need real composition); the pure lanes
   would containerize fine but never steal focus anyway. The workable fix is a
   separate Win32 **desktop** (`CreateDesktopW` + `STARTUPINFO.lpDesktop`),
   which is an input-isolation boundary — 35 of 63 scripts grab foreground and
   36 send input, and none of them can take the foreground from a desktop the
   user is not on. One risk decides the shape of the whole task and must be
   spiked first: DWM composes only the INPUT desktop, so `CopyFromScreen` may
   return nothing on a background one. Slot T207 by how much it costs the
   user: it is not a parity item, but it is the reason the box is unusable
   while the loop runs, so treat it as infrastructure ahead of the cosmetics
   if the spike comes back cheap.

3j. **T208 — the delivery path can silently ship a stale binary. Rank it
   above the 3h cosmetics.** Hit for real delivering T202 on 2026-07-30:
   `launch-upgrade.ps1` said `LAUNCH OK`, the upgrade log said `exe swapped`
   and `UPGRADE OK`, and the installed release still reported `+9968a62d9`
   — the binary from that afternoon. `upgrade-ghoztty-windows.ps1` has **no
   build step** (its header says so) and `launch-upgrade.ps1` only checks that
   `zig-out-release` *exists*, so the delivery copies whatever the previous
   delivery left there. go.md documents the launch invocation in detail and
   never says to build first, so a turn that follows it exactly ships stale
   bits and gets "success" from every signal it has. T203/T204/T206 exist
   because the user cannot see fixes; this is the mechanism that keeps them
   from seeing *any* fix, so it goes first. Until it lands, **build
   `--prefix zig-out-release` yourself before calling `launch-upgrade.ps1`,
   and check `ghoztty +version` against `git rev-parse --short HEAD`
   afterwards.**

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

> **FROZEN 2026-07-29 — this table is a historical snapshot, not ground truth.**
> Tasks now live one-per-file in `windows-parity-tasks/` (`T<id>.md`), so two
> agents can file and edit tasks without writing to the same file. That change
> was made because this table had already produced a duplicate `T112` (one bug
> filed twice) and a duplicate `T153` (two sessions minting the same id on the
> same day).
>
> **Do not add or edit rows here.** Use the script:
>
> ```
> powershell -NoProfile -File scripts\parity-tasks.ps1 next
> powershell -NoProfile -File scripts\parity-tasks.ps1 show T144
> powershell -NoProfile -File scripts\parity-tasks.ps1 new -Title "..." -Phase K
> powershell -NoProfile -File scripts\parity-tasks.ps1 set-status T144 -Status done -Commit <sha>
> ```
>
> Format and full command set: `windows-parity-tasks/README.md`. Everything in
> this table was migrated (185 files, `validate` passes). The rest of THIS file
> — the resume protocol above and **Current priorities**, which still outranks
> `next` — remains live and correct.

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
| T123 | Banner table columns use a FIXED 360pt cap on Windows — `BannerOverlay.MAX_CELL_W = 360.0` is the exact constant main replaced in `1d56c6948`+`c94a8158a`; CLAUDE.md (now merged) documents the post-fix contract: column widths derive from the pane's CURRENT width so the banner reflows live on resize and never blocks the pane from shrinking (even a long unbroken token breaks mid-string), and a cell is capped at 3 wrapped lines with a tail ellipsis so one nasty cell can't blow up banner height. Windows currently satisfies none of that, so the merged CLAUDE.md now over-promises for win32 — fix the code, don't weaken the doc. **RE-REPORTED BY THE USER 2026-07-29** — *"Even the banner has the same stupid bugs i fixed in the mac client a week or 2 ago! The text in the table has fixed width and doesn't use available space."* Still unfixed and still verifiable by inspection: `src/apprt/win32/BannerOverlay.zig:68` `const MAX_CELL_W: f32 = 360.0`, consumed at `:605`. PRIORITY RAISED — this is a user-visible regression against a bug already fixed on the Mac, and it is cheap: the Mac fix (`1d56c6948`) replaced the constant with a pane-width-derived budget, so this is a port of known-good logic, not a design task | K | T117 | todo | — |
| T124 | Banner visual refresh parity (6 Mac commits, cosmetic) — `6778d22a0` Liquid Glass floating card + stable collapse geometry, `286078a2f`/`755af5c97` glass tinted off the pane background + elliptical sheen, `53e763c28` stable pane-hued card (dropped focus-reactive glassEffect), `088c44201` composite off a single pane-colored element, `ec0c62671`+`89465f320` instant collapse/expand with the terminal inset snapping once. win32's `BannerOverlay.zig` is a hand-painted GDI strip, so this is a deliberate REINTERPRETATION, not a port — Windows should look Windows-native (THE GOAL), so decide per-item what to adopt (the collapse/inset timing fixes are behavioral and worth taking; Liquid Glass is a macOS material with no native analog). Lowest priority of the T118–T128 band | K | T117 | todo | — |
| T125 | No agent-update dialog and no "What's new" on Windows — main added a whole feature (`981d18e29` ReleaseNotesStore, `1d7f809b3` WhatsNewTracking, `d28adcec1` WhatsNewNotesView, `f5c75454f`+`1f8f7c302` reframed agent-restart dialog copy, `1a236ecf7` scoping notes to agent-process changes, `047a80c47` bundling the notes JSON) that is entirely macOS Swift. On Windows `update_check.zig` covers only the APP-version check (T24, `win-v*` tags) and `LocalAgent.zig:264` states outright that "the listen-pipe agent never self-updates" — so the CLAUDE.md agent-contract's mandatory-update path (lazy non-destructive upgrade, else an explicit "upgrading will reset all windows" confirmation) has NO Windows implementation. That contract gap is the real risk here, well above the notes UI: file the notes viewer as nice-to-have, but treat the agent-upgrade confirmation as a correctness requirement. Note `release-notes/` JSON is repo-shared, so only the presentation + tracking need porting | K | T117 | todo | — |
| T126 | Hero-mode key navigation audit vs main's `HeroKeyNavigator` — `280f2449e` extracted navigation into a dedicated navigator because the Mac was navigating a STALE snapshot of the split tree and could act on a window other than the aimed-at one; `4eb13a651` then fixed an arrow-nav beep and a skipped pane. win32 has its own hero implementation (`HeroCarousel.zig` + `hero_math.zig`), so this is an audit, not a port: confirm win32 navigates the LIVE tree (it calls `heroOnTreeChanged` on rearrange, which is a good sign but not proof) and that arrow nav skips nothing. The viewer half of `1e0cf5484`/`4eb13a651` is moot until T90 lands viewer panes | K | T117 | todo | — |
| T127 | T90b–T90h viewer scope has GROWN — the T90a design (2026-07-19) predates 16 main viewer commits that added capabilities its task split never accounted for: navigable address bar + sliding/omnibox completion + `file://` display (`13b950e77`, `6af1fc12a`, `25c454b24`), native + in-page markdown TOC (`2137da95a`, `3691cc4e8`, `2af9a6e95`), browser-style zoom (`dc5daa4c5`), popups-as-windows (`0b8335d7c`), quote-from-page toolbar + screenshot key (`1cf83764b`, `2f0b286ba`), worktree-aware feedback capture (`4cf88905d`, `1edce34c7`, `efe1e1d17`, `bd5667887`), copy/paste + browser-like focus (`a7fc890a9`), Cmd-R/Cmd-D pane-scoped keys (`14d22875a`), and `+reload` (T119). Do NOT silently widen T90b–T90h: re-scope them against the current Mac viewer FIRST (a T90a refresh), decide explicitly what Windows v1 ships vs defers, and record the deferrals as rows so they stay visible. Much of the JS (`src/viewer/*.js`, incl. the new `selection.js`) is shared and came in free with T117 — it is the WebView2 host side that has to catch up. **UPDATED 2026-07-29** — add `89d9de2af` (raw HTML in markdown via DOMPurify-sanitized output) to the inventory; that makes **27** Mac viewer commits against a design written for the first 8. **USER-REPORTED THE SAME DAY**, and correctly: *"another huge huge huge missing feature: web view panes. You have no support for the web view, the address bar we added in macos, markdown viewing, the table of contents work, ... all missing."* Tracked ≠ shipped — T90d–T90h are all `todo`, so on Windows `--view` still returns the T90b "viewers are not yet supported on Windows" error and NONE of the viewer surface exists. This is the single largest parity hole in the product and should be re-scoped and sequenced ahead of the cosmetic band | K | T117,T90a | todo | — |
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
| T138 | **The upgrade script forks the loop: TWO Claude sessions end up running `go.md` at once.** User-hit 2026-07-28 ("there are 2 windows trying to run the session… both windows tried to build T131"). Proven on the box: `claude` pid 16076 started 08:01 and was STILL ALIVE after the 09:46 upgrade, alongside `claude` pid 644 started 09:46:40 by the script's relaunch. `upgrade-ghoztty-windows.ps1`'s header states the assumption — *"killing ghoztty.exe kills the session's shell and Claude with it"* — and that assumption died with T89: the agent owns the PTY, is deliberately never killed, and the relaunched app RE-ATTACHES the surviving pane. So the script now produces a second session on top of the one it never killed, both resuming the same transcript via `--continue "read go.md and go"`, both picking the same first task. (`+sessions` returned 0 in the log — the pre-kill probe is ALSO wrong, `$oldExe +sessions` was run at the moment the exe was being replaced; fixing the probe is part of this.) No repo damage this time: the duplicate never committed. Fix: before relaunching, look for a pane already running claude in `WorkingDirectory` (via `+list --json` + the pane's process tree) and re-use it instead of opening a new window; the relaunch is only correct when the kill actually orphaned the session. Validation: an on-box case that starts a persistent claude pane, runs the script, and asserts exactly ONE claude process in the repo afterwards | K | T89h | todo | — |
| T139 | **Nothing stops two loops from running, and nothing restarts one that stops** — the user's ask, verbatim: *"if you detect multiple processes trying to work on 'go' process, we need to find a way to stop that as they would clash."* Two halves. **(a) Single-instance guard:** a lock the loop takes at the top of `go.md` step 1 — a file recording pane id + claude pid + a heartbeat timestamp; a session that finds a FRESH lock owned by a live pid stops immediately and says so instead of working the same task twice (T138 is one way to fork the loop; a user opening a second window by hand is another). Stale locks (dead pid, or a heartbeat older than ~30 min) are taken over, so a crash never wedges the loop permanently. **(b) Watchdog:** `go.md` says outright *"Nothing supervises this loop"*, and a turn that ends with a report instead of `/reset-context` kills it silently — that cost six days once (2026-07-21 → 07-27) and stopped it again 2026-07-28 (both forked sessions ended their turn with a summary). Something outside the session — a scheduled task, or the agent — should notice the lock's heartbeat going stale while tasks remain `todo` and re-enter the loop. Validation: two sessions started deliberately ⇒ the second refuses; a killed session ⇒ the watchdog re-enters within its interval. **DONE 2026-07-29**: `scripts/go-loop-lock.ps1` (pane-keyed lock, pid+start-time liveness so a recycled pid can't hold it, dead-owner/stale-heartbeat takeover so a crash can't wedge it) is taken at a new `go.md` **step 0**, exit 3 ⇒ the second session stops; `scripts/go-loop-watchdog.ps1` re-enters via the cheapest fitting action (nudge a stalled-but-live session / restart claude in a surviving pane / open a window), leaves a pane that is still emitting output alone, and autostarts from an HKCU Run entry (`/SC ONLOGON` needs elevation). Third piece, added the same day on the user's correction (*"don't ask me to resolve"*): `scripts/go-loop-exec.ps1` pins the execution window's title to `[go-loop] …` (via `+rename`, readable from `+list --json`) so an execution window is distinguishable from the user's task-filing window — **only marked windows are ever touched** — and `claim` resolves a duplicate with no human in the loop: the primary messages the duplicate's session and closes it, the duplicate messages the primary, unmarks and closes itself. The lock is the arbiter, so both sides compute the same answer and it cannot deadlock. `go-loop-guard.ps1` ALL PASS (78) ×3, incl. sections I/J/K/L end-to-end against a live debug GUI (a real duplicate window is really closed while an unmarked window is untouched). Filed T153 | K | — | done | `52d8fd232` |
| T140 | **The Cmd/Ctrl+Shift+N machine chooser is not Mac-parity** — user-reported 2026-07-28 with a screenshot: *"I hit ctrl shift n, and the dialog looks nothing like the mac dialog, so clearly you aren't done."* T22c shipped a functional native chooser (list + open + escape) and stopped there; what is on screen is a bare Win32 dialog — default listbox with a full-width blue selection bar, an unlabeled empty edit at the top, a footer line that is CLIPPED mid-sentence (*"Not signed in — run `ghoztty +relay-login` to list your"*), and OK/Cancel buttons. Mac's is a proper chooser: per-row machine identity, host settings via a row `⋯` menu (CLAUDE.md documents it), and a sign-in affordance that is not a truncated sentence. Port the Mac dialog's structure and visual language (this is the T50 "Windows things should look Windows-native, not like bare controls" bar applied to the chooser), and make the footer wrap/size to its text. Depends on the T141 decision for what the not-signed-in row should say | K | T22c | todo | — |
| T141 | **`+relay-login` / `+relay-logout` are Windows-only commands the Mac client never had — remove them.** User directive 2026-07-28: *"What is +relay-login? This is a command I NEVER ADDED to the mac client. I don't want commands that only exist on one platform."* T21a invented the pair as the Windows analog of the macOS Keychain-backed `RelayAccount` (Mac signs in from the GUI, so it needed no CLI verb), and the chooser now instructs the user to run one — the divergence is not just present, it is being advertised in the UI. This overrides the "build the native equivalent where the concept has no analog" clause: the concept HAS an analog (GUI sign-in), so the CLI surface must not diverge. Do: move sign-in/sign-out into the GUI (the chooser's own affordance, DPAPI store unchanged), delete both CLI verbs and their docs from CLAUDE.md, and keep the stored-credential reader. Then AUDIT the whole win32 CLI for other one-platform verbs and report them in this row — the same rule applies to every one of them. Validation: `ipc-relay-login.ps1` reworked to drive the GUI path; a diff of the win32 command list against the Mac one with every remaining difference justified in the row | K | T21a | todo | — |
| T142 | **The banner overlay does not defend its z-order** — user-reported 2026-07-28 as *"windows in the background have banners that overlap windows in the foreground"*. ROOT CAUSE THIS TIME WAS NOT THE PRODUCT: a T131 verification probe (`raiseshot.ps1`) called `SetWindowPos(banner, HWND_TOPMOST)` to beat occlusion and never restored `HWND_NOTOPMOST`, so both overlays stayed topmost for the rest of the day; clearing the bit restored correct ordering (banner directly above its own window, both below whatever is foreground) and the symptom went away. But the product made it possible and could not recover from it: `updatePosition` passes `SWP_NOZORDER`, so once anything — a probe, a screen recorder, another app's stray `SetWindowPos` — leaves the bit set, nothing ever clears it. Fix: place the overlay explicitly on every reposition (just above its owner, `HWND_NOTOPMOST`) instead of `SWP_NOZORDER`, so the z-order is re-asserted continuously and is self-healing; same for the scrollbar/dim overlays if they share the pattern. Validation: an on-box case that sets `HWND_TOPMOST` on a live overlay, triggers a reposition, and asserts `WS_EX_TOPMOST` is gone and the overlay sits directly above its owner | K | T131 | todo | — |
| T143 | **Windows has no menu bar — the entire menuing system is Mac-only.** User-reported 2026-07-29: *"on the mac version, there is a way to access the menu bar. On windows, there's none."* Verified: `macos/` ships a full `NSMenu` main menu (File / Edit / View / Window / Help) whose items are the discoverable home for Change Window Title, Change Tab Title, Change Pane Title, Set Pane Banner, Tab Color, New Remote Window, File→Open, Reload, Quit-with-sessions, etc.; win32 has only the T102 right-click context menu and the command palette, so every one of those actions is undiscoverable unless the user already knows its chord (this is the same root complaint as T129, which is a symptom of this task, and it is why T141's sign-in has nowhere to live in the GUI). Not a literal `NSMenu` port — Windows convention is a window menu bar or a hamburger/⌄ button in the title bar. Design first (a T143a), then implement: pick the host (owner-drawn menu bar under the tab strip vs. a caption button opening a real `HMENU` — dark-mode via the T79 uxtheme path either way), mirror the Mac menu tree item-for-item with the same accelerator labels, drive every item through the SAME action dispatch the palette uses (no second code path), and keep it in sync with the palette so an action can never appear in one and not the other. Validation: an on-box script that opens the menu, walks every item, and asserts each fires its action; plus a static test that the menu tree and the palette command list cover the same action set | K | — | todo | — |
| T144 | **New windows (ctrl+n) open in `C:\Windows\System32`.** User-reported 2026-07-29: *"it keeps defaulting to windows system32 folder (HORRIBLE!) this should never be the default path for opening cmd."* Two defects, one symptom. (a) THE BUG: `Config.finalize` already resolves the win32 default to `.home` (`probableCliEnvironment()` returns false on Windows, so wd = `.home` → `HOMEDRIVE`+`HOMEPATH`), and `apprt.surface.newConfig` only overrides it from the parent pane's OSC-7 pwd — so `C:\Windows\System32` cannot come from config resolution at all. PRIMARY HYPOTHESIS (verify on the box before fixing, do not assume): the agent-backed spawn path drops the resolved cwd and the ConPTY child inherits the AGENT's own cwd, which is `C:\Windows\System32` because the T89h HKCU `Run` autostart entry launches it detached from there — the exact mechanism `src/apprt/ipc/args.zig:144-171` (T132) and `src/remote/agent/server.zig:755-762` already call out for the auto-launch and RELAUNCH paths, never fixed for the ordinary OPEN. Confirm by comparing the pane's cwd with `session-persistence=on` vs `off` and by reading the running agent's own cwd. Secondary candidate: `Exec.zig:1105` silently drops a cwd that fails `access()`. (b) THE MISSING ESCAPE HATCH: the user has NO config file — `%LOCALAPPDATA%\ghostty\` contains only a zero-byte, mis-named `config.ghostty` (the loader reads `config`, no extension), so nothing they could have set would ever load. Fix (a), then make the default reachable: honor `working-directory = <path>` from `%LOCALAPPDATA%\ghostty\config` on every new window/tab/split, and find out what wrote `config.ghostty` (a file-association or first-run artifact writing the wrong name is its own bug — a user who "set" a config and saw no effect would have no way to tell). Validation: on-box, ctrl+n from a Start-menu-launched app lands in `%USERPROFILE%` with no config and in the configured path with one, with persistence both on and off | K | — | todo | — |
| T145 | **Agent-crash recovery has no Windows equivalent — 2 Mac commits, ZERO references in any Windows doc.** `03f0f1f30` (in-place agent-crash recovery: rebuild local windows from the agent WITHOUT an app relaunch) and `20e505aaf` (recover crash-orphaned windows from the agent's authoritative layout). Windows has only T89f2 launch-time restore, so if the agent dies while the app is running the panes are simply dead until the user quits and relaunches — the failure mode session persistence exists to prevent. Port both: treat the agent's layout blob as authoritative, rebuild in place on reconnect, and reconcile against the local session-layout manifest. Note `e65cfa4d5`'s lesson (recovery must not kill the sessions it recovers) — that is T128's mirror-image bug and the two should be validated together | K | T89f2 | todo | — |
| T146 | **The session chooser is functionally a stub next to the Mac's — 4 Mac commits, ZERO references.** `040c6a959` (master–detail redesign: live sessions, Kill, richer labels), `c066f8681` (cross-machine session BROWSE in the Cmd-Shift-N chooser), `236a217ca` (resume a single browsed session on the local machine), `43bfb8e4a` (agent-owned layout blobs + cross-machine "Resume all"), plus `e5da5d02b` (reap dead tombstones so only connectable sessions are listed). NOTE: CLAUDE.md still claims cross-machine session move is *"scoped but not yet built"* — that is STALE, the Mac shipped it 2026-07-16 and CLAUDE.md must be corrected as part of this task. T140 covers how the chooser LOOKS; this covers what it DOES, and the two should land together or T140 will re-skin a dialog that is about to grow a master–detail pane | K | T140 | todo | — |
| T147 | **Agent upgrade delivery is destructive on Windows — 2 Mac commits, ZERO references.** `c6ad0fc07` (non-destructive agent upgrade delivery) and `ae2be57cb` (eliminate tombstone reload + blank re-attach on upgrade). This is the mechanism CLAUDE.md's "Agent contract & upgrade compatibility" section mandates — *"prefer a lazy, non-destructive agent upgrade… carry sessions across… drain/snapshot and resume so no work is lost"* — and the win32 agent (T89h) has none of it, so every agent upgrade is the very silent session reset that contract forbids. Port the drain/snapshot/resume handoff and the upgrade-path re-attach fix, and pair with the T125 update dialog so the mandatory-confirmation fallback exists for the skew case | K | T89h | todo | — |
| T148 | **Local splits/tabs/windows may re-run the parent's command on Windows.** `cdb689025` (Mac, ZERO references) fixed exactly this: a new local split/tab/window under the agent inherited and re-executed the parent pane's `--command` instead of starting a plain shell. Win32's T99 wired IPC-created panes through the agent without this guard. Verify on the box (open a window with `--command`, then ctrl+n / split from it) and port the fix if it reproduces; if it does not, record the negative result rather than closing silently | K | T99 | todo | — |
| T149 | **Banner chrome parity: no collapse toggle, no content inset.** `a5adff229` (symmetric padding, content inset, shaded background, collapse toggle) has ZERO references in any Windows doc; `ec0c62671`/`89465f320` (instant-then-animated collapse/expand with the terminal inset snapping once) are cited only in passing. A Mac banner can be collapsed to a thin strip and expanded again; the win32 overlay cannot, so a tall banner permanently eats pane rows with no user recourse. Depends on T131's card work landing first so the collapsed state has a shape to collapse to | K | T131 | todo | — |
| T150 | **Runtime background-color changes are not accessibility-safe on Windows.** `c3e9999e7` (single-pass, accessible runtime background changes) and `752f3178a` (stop the background-color picker flipping panes to white) have ZERO references. Win32 got the T67 tint and the T120 random-tint fix but not the single-pass accessible recompute, so a live background change can leave foreground/selection/cursor contrast below the WCAG 4.5 floor the Mac now guarantees. Port the single-pass recompute and add a contrast assertion to the T67 validation | K | T67 | todo | — |
| T151 | **Agent-backed panes may not get shell integration injected.** `173320776` (inject shell integration for local-agent panes, Mac, ZERO references) — without it an agent-backed pane never emits OSC 7, which silently breaks cwd inheritance (T144), `+list` cwd reporting, and the shell-integration prompt features. T27 shipped PowerShell shell integration for the DIRECT spawn path only; verify whether the T89d agent OPEN path injects it at all, on every supported shell flavor | K | T27,T89d | todo | — |
| T152 | **Make the parity sweep systematic — the per-merge sweeps have been leaking.** Filed 2026-07-29 after the user found three gaps by hand (viewer panes, the menu bar, the banner table width) and a full re-audit then found **16 Mac commits from the last 3 weeks with ZERO references in ANY Windows doc** (T145–T151 above). The T88 and T117 sweeps were narrative summaries, not enumerations, so a commit could be merged and never mapped to a row. Fix the PROCESS: a checked-in script that, for a given merge range, lists every commit touching `macos/` or `src/viewer/` and reports which have no task-id reference in `docs/design/windows-parity-*.md`; run it as a gate at every `origin/main` merge (T88/T117 pattern) and file a row for every unmapped commit before the merge task can be marked done. Also add a `Parity coverage` note to the merge task template so the enumeration is evidence, not prose | K | — | todo | — |
| T153 | **`ghoztty +list --pid=<pid>` never matches on a session-persistence box** — found 2026-07-29 during T139 while mapping claude pids to panes. CLAUDE.md documents `--pid` as *"the tty-less way for a process inside a pane to discover its own pane"*, but `+list --pid=$PID` and `--pid=<a real pane's claude pid>` both fail with `IPC request failed` (exit 1) against the live release app, and plain `+list --json` shows why: **every** terminal leaf reports `"pid":0` (and `"tty":""`), because agent-backed panes' shells are children of `ghoztty-agent.exe`, not of the app, so the app has no pid to walk ancestry from. Persistence is on by default, so this is the normal case, not an edge one — the documented fallback route is dead on every pane. T113's `$GHOZTTY_PANE_ID` is the better answer and works, so the user-facing impact is small, but a documented CLI verb that always fails is worse than one that says it cannot help. Do: have the app ask the agent for each session's child pid when the pane is agent-backed (the agent already reports `pid` in `+sessions --json` — session `c00af3d8…` correctly reported pid 1008), fill `pid` in `+list --json`, and make `--pid` walk ancestry against it; if a pane genuinely has no pid, `--pid` should exit with a message naming `$GHOZTTY_PANE_ID` as the route to use. Note T98 (bogus local-session pid) is adjacent — check whether that fix and this one are the same plumbing. Validation: extend `pane-id.ps1` with a section that resolves this pane via `--pid` on a persistence-on box, plus a `+list --json` assert that `pid` is non-zero for an agent-backed pane | K | T89d | todo | — |
| T155 | **Split dividers render as double/triple lines instead of one solid line.** User-reported 2026-07-29 with a screenshot showing two parallel verticals and a 3-line stack near the top. ROOT-CAUSED BY INSPECTION (no build needed), two compounding defects. **(a) Stale lines are never erased — this is the double/triple.** `Window.zig:3839` handles the parent's `WM_ERASEBKGND => return 1`, i.e. it claims the background is erased and paints nothing (the surface CHILD class *does* fill, `App.zig:3443`, so panes are fine — only the inter-pane gap, which the parent owns, is never cleared). Divider lines are then stroked OUTSIDE the paint cycle via a raw `GetDC` right after layout (`layoutSplits:1707-1714`, again in `onConfigChange:451`), with the code's own comment conceding WM_PAINT "misses the content area gaps". So nothing ever clears the gap: every ratio change (divider drag, window resize, pane add/remove, DPI change, tab switch) strokes a NEW line at the new `split_x` and leaves the OLD one on screen. They accumulate — two lines after one drag, three after two. **(b) Even a correctly-painted divider reads as 3 edges.** `paintDividerNode:1830-1844` leaves a 5-DIP gap (left pane ends `split_x - gap/2`, right starts `split_x + (gap+1)/2`) and strokes a hairline at `split_x`, so the render is *pane bg | 2px parent bg | 1px line | 2px parent bg | pane bg* — and with T67 per-pane tints the parent bg is a different color than either pane, making all three boundaries visible. Mac draws a solid filled divider with no gap. **(c) Width is not 2px and not constant.** `line_w = @max(@round(1.0 * scale), 1)` → 1px at 100%/125%, 2px at 150%/200%. Fix: paint the divider as part of the parent's WM_PAINT (fill the whole gap rect with the divider color via `FillRect`, one solid band, no `GetDC` side-channel) and give the parent a real `WM_ERASEBKGND` so no region can hold stale pixels; match the Mac's divider thickness and treat `split-divider-color` (T73) as the fill, not a stroke. Validation: extend the T73/T94 on-box script with pixel oracles that drag a divider N times and assert exactly ONE band of divider-colored pixels on the scanline, at 100/125/150/200% DPI, for both split axes | K | T73,T94 | todo | — |
| T154 | **ctrl+v does not paste screenshots into Claude Code panes (alt+v does).** User-reported 2026-07-29. ROOT-CAUSED BY INSPECTION — a one-flag omission, and the machinery to fix it already exists and is already used by this binding's own neighbors. `Config.zig:6934-6938` binds Windows `ctrl+v` → `paste_from_clipboard` with a plain `put()` and **no `performable` flag**. `Surface.startClipboardRequest` documents the contract at `Surface.zig:6744-6746` — *"Returns true if the request was started, false if it was not (e.g., clipboard doesn't contain text for paste requests). This allows performable keybinds to pass through when the action cannot be performed"* — and the win32 side ALREADY honors it: `Surface.clipboardRequest:1214` returns false when `GetClipboardData(CF_UNICODETEXT)` is null, which is exactly the image-on-clipboard case. But the fall-through at `Surface.zig:3662` is gated on `leaf.flags.performable`, so without the flag ghoztty swallows ctrl+v unconditionally, pastes nothing (no text on the clipboard), and Claude Code never receives the keystroke it would have used to read the image from the clipboard itself. alt+v works precisely because it is unbound and reaches the TUI as `ESC v`. This is a Windows-only divergence: the shared block at `Config.zig:6553-6558` binds cmd+v (Mac) / ctrl+shift+v (elsewhere) **with** `performable = true`, and ctrl+c / ctrl+k in the very same Windows mirror block use `putFlags(..., .{ .performable = true })` — ctrl+v is the only one that forgot. Fix: switch it to `putFlags` with `performable = true`. **Testable prediction to confirm first:** on today's build `ctrl+shift+v` should ALREADY paste an image correctly into Claude Code while `ctrl+v` does not — verify that asymmetry before changing anything, because it proves the diagnosis end-to-end. Then audit the rest of the Windows ctrl-mirror block for other bindings that should be performable but are not. Validation: an on-box case that puts an image (no text) on the clipboard and asserts ctrl+v reaches the pane, plus a text-clipboard case asserting ctrl+v still pastes text and does NOT leak a stray `^V` | K | — | todo | — |

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
