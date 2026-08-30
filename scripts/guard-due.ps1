<#
.SYNOPSIS
  Report which acceptance harnesses have not been run since the code they
  cover last changed.

.DESCRIPTION
  T783. On 2026-08-11 b64c3e8aa prefixed every scripts\go-loop-lock.ps1 message
  with an ISO timestamp. 26 assertions in test\win32\go-loop-guard.ps1 anchor on
  the answer's FIRST WORD (^ACQUIRED, ^held, ^stale-dead), so the whole guard
  went red against a lock script that was working perfectly - and nobody noticed
  for a day, because that guard is not in the P1-P3 floor and nothing tied an
  edit of the loop's scripts to it. The loop's supervisor is the one thing whose
  failure nothing else can catch, so its harness going quietly red is the worst
  place in the tree for that gap.

  THE MECHANISM. A green harness run STAMPS the content of every file it covers
  (scripts\guard-due.ps1 update, called by the harness itself). This command
  compares the files on disk against that stamp:

    * every covered file hashes the same as the stamp  => the harness has been
      run against exactly this code. CURRENT, exit 0.
    * any covered file changed, appeared, or vanished  => nothing has run that
      harness against the code as it now stands. DUE, exit 1, naming the files.

  It is a CHANGE gate, not a schedule: a stamp does not go stale with time, and
  a file edited and edited back is not due. The stamp is committed, so it
  travels with the change - a `git pull` that brings in a loop-script edit made
  on another seat reads as DUE here, which is the case a purely local mtime or
  a "did this turn touch it" check cannot see.

  WHAT IT IS NOT. It never runs the harness (that would put a multi-minute
  GUI-launching acceptance script inside whatever called this), and it never
  decides that a harness PASSES - only that one has not been asked. A red
  harness run leaves the stamp alone, so red stays due.

  WIRED INTO (both deliberately different in force):
    * scripts\go-loop-exec.ps1 claim - go.md step 0, every turn. Reports, never
      fails: a claim that can exit nonzero over a stale stamp would wedge the
      loop, which is the disease, not the cure.
    * scripts\parity-tasks.ps1 validate - go.md step 6, before every commit.
      FAILS, because that is the gate with teeth, and the remedy (run the
      harness, or fix what it caught) is the work this exists to cause.

  Acceptance: test\win32\guard-due.ps1.

.EXAMPLE
  powershell -NoProfile -File scripts\guard-due.ps1
  powershell -NoProfile -File scripts\guard-due.ps1 check -Json
  powershell -NoProfile -File scripts\guard-due.ps1 update -Guard go-loop
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'update', 'list')]
    [string]$Action = 'check',

    # Limit to one harness by name. Omitted => every row in the table.
    [string]$Guard,

    [string]$Repo,
    [switch]$Json,

    # T1039 escape hatch, for the ONE caller whose subject is stamping itself:
    # `test\win32\guard-due.ps1` drives `update` against a throwaway fixture
    # repo from inside its own unfinished run, so the run-state gate below
    # would refuse the very thing it is measuring. It says so in the output
    # when it is used, because a silent hatch is how a gate stops meaning
    # anything.
    [switch]$IgnoreRunState
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

# ---------------------------------------------------------------------------
# The coverage table. One row per harness; adding a row is the whole cost of
# closing this gap for the next harness that grows one.
#
# `Covers` are repo-relative globs. Keep a row to the family the harness is
# ABOUT: a gate that demands a go-loop run every time a shared library moves is
# noise, and noise is how a gate gets ignored. scripts\lib\NativeArgv.ps1 is
# reached transitively from here and is deliberately NOT covered - it has its
# own acceptance (test\win32\cli-argv-fidelity.ps1), which is the same argument
# in the other direction.
# ---------------------------------------------------------------------------
$GuardTable = @(
    [pscustomobject]@{
        Name   = 'go-loop'
        Script = 'test\win32\go-loop-guard.ps1'
        Stamp  = 'test\win32\go-loop-guard.stamp.json'
        Covers = @(
            'scripts\go-loop-*.ps1',
            'scripts\loop-session.ps1',
            'scripts\git-commit-guard.ps1',
            'scripts\githooks\*',
            'test\win32\go-loop-guard.ps1'
        )
    },
    # The ship workflow (T1058): the cutover readiness gate and the per-feature
    # worktree/branch/PR lifecycle. Neither is touched by any lane - one only
    # reads git and the tracker, the other only runs when somebody starts or
    # finishes a feature - so an edit that broke a REFUSAL would be invisible
    # until the day it deleted a worktree holding unpushed work, or opened a
    # pull request against the upstream Ghostty project. The doc is covered too,
    # because section D asserts the workflow is reachable from it and that wiring
    # is what rots first. go.md is deliberately NOT covered: it is edited by
    # almost every process change in the project, so a row for it would leave
    # this harness permanently due, and a gate that is always red is a gate
    # nobody reads. Section D still asserts go.md's wiring on every run.
    [pscustomobject]@{
        Name   = 'ship-workflow'
        Script = 'test\win32\ship-workflow.ps1'
        Stamp  = 'test\win32\ship-workflow.stamp.json'
        Covers = @(
            'scripts\ship-readiness.ps1',
            'scripts\ship-feature.ps1',
            'test\win32\ship-workflow.ps1',
            'docs\design\windows-parity-ship-workflow.md'
        )
    },
    # Stage 0 of the upstream pull (T957): the upstream remote and the union merge
    # drivers. Neither is exercised by any lane - the remote is git config and
    # the drivers only fire inside a merge - so nothing else would notice a
    # `.gitattributes` edit that stops matching, or an `ensure` that quietly
    # stops repairing. Both failures are invisible until a merge stage needs
    # them, which is the worst possible moment to find out.
    [pscustomobject]@{
        Name   = 'upstream-remote'
        Script = 'test\win32\upstream-remote.ps1'
        Stamp  = 'test\win32\upstream-remote.stamp.json'
        Covers = @(
            'test\win32\upstream-remote.ps1',
            'scripts\upstream-remote.ps1',
            '.gitattributes',
            # T1099: the plan doc IS the input - `check` derives the sha list
            # from it, so a re-cut stage introduces a sha nothing has anchored
            # yet, and the harness is what notices. Without this row the plan
            # could name a new merge point and the gate would stay green over it.
            'docs\design\windows-parity-upstream-pull-plan.md'
        )
    },
    # The other half of Stage 0 (T956): the fork-identity overlay. Same argument
    # as above and one more - this one WRITES to a tree, so the failure mode is
    # not "a merge stage is harder than expected" but "52 upstream files were
    # rewritten by a rule that had quietly gone wrong". The rules are exercised
    # by nothing else, and the plan's appendix that the harness derives its file
    # list from is edited by the daily intake.
    [pscustomobject]@{
        Name   = 'fork-identity'
        Script = 'test\win32\fork-identity.ps1'
        Stamp  = 'test\win32\fork-identity.stamp.json'
        Covers = @(
            'test\win32\fork-identity.ps1',
            'scripts\fork-identity.ps1'
        )
    },
    # The ghoztty:// URL scheme (T1124). The registration is a REGISTRY write
    # the user's shell then obeys, and nothing in the P1-P3 floor launches a GUI
    # to watch it happen: the unit lanes see the scheme name and the command
    # string, never the decision to write them. That is how a release build
    # sitting in `zig-out-release` came to own the user's links for days with
    # every lane green. This row ties that decision - the build-mode split and
    # the source-checkout location gate - to the one harness that measures it.
    [pscustomobject]@{
        Name   = 'url-scheme'
        Script = 'test\win32\url-scheme.ps1'
        Stamp  = 'test\win32\url-scheme.stamp.json'
        Covers = @(
            'test\win32\url-scheme.ps1',
            'src\apprt\win32\url_scheme.zig',
            'src\apprt\ipc\url_scheme.zig'
        )
    },
    # The startup job self-escape (T675): the only harness that proves a
    # pane-launched app respawns itself OUT of a kill-on-close job and
    # survives the teardown that used to kill it mid-refresh. Interactive
    # desktop only (the escape rides the shell-parent hop), so it is not in
    # the P1-P3 floor; the unit lanes see shouldEscape but never a real job.
    [pscustomobject]@{
        Name   = 'job-escape-startup'
        Script = 'test\win32\job-escape-startup.ps1'
        Stamp  = 'test\win32\job-escape-startup.stamp.json'
        Covers = @(
            'test\win32\job-escape-startup.ps1',
            'src\apprt\win32\job_escape.zig',
            'src\apprt\win32\job_spawn.zig',
            'src\apprt\win32\job_object.zig'
        )
    },
    # The viewer suite carries the browser-leak tripwire (T594): the only
    # thing that scores whether a test run handed a page to the user's real
    # browser, and it is not in the P1-P3 floor. The zig-side guard
    # (ViewerPane's is_test refusal) is exercised by the win32 lane every
    # floor run and is deliberately NOT covered here.
    [pscustomobject]@{
        Name   = 'viewer-panes'
        Script = 'test\win32\viewer-panes.ps1'
        Stamp  = 'test\win32\viewer-panes.stamp.json'
        Covers = @(
            'test\win32\viewer-panes.ps1',
            'test\win32\lib\BrowserLeak.ps1'
        )
    },
    # Narrow viewer panes (T1130): the only thing that measures viewer chrome
    # against the pane it lives in. The unit lanes assert the pure layout
    # modules and cannot see a WINDOW placed outside its parent, and the P1-P3
    # floor never squeezes a pane - which is how a contents card 88px past its
    # own pane went unnoticed. Covers the two layout modules the containment
    # depends on as well as the script.
    [pscustomobject]@{
        Name   = 'viewer-narrow-pane'
        Script = 'test\win32\viewer-narrow-pane.ps1'
        Stamp  = 'test\win32\viewer-narrow-pane.stamp.json'
        Covers = @(
            'test\win32\viewer-narrow-pane.ps1',
            'src\apprt\win32\viewer_toc_layout.zig',
            'src\apprt\win32\viewer_nav_layout.zig',
            'src\apprt\win32\ViewerTOCPanel.zig',
            'src\apprt\win32\ViewerNavBar.zig'
        )
    },
    # The viewer nav-bar PIN (T1131): which viewer flavors keep their address
    # bar on screen and which peek on hover. The unit lanes assert the policy
    # table and the pane's own record of it; only this script proves that a
    # real `+split --view=` pane comes up with the bar shown - or hidden - and
    # that a shown bar reserves its band instead of covering the page. Covers
    # the pane that applies the pin and the module that decides it.
    [pscustomobject]@{
        Name   = 'viewer-nav-pin'
        Script = 'test\win32\viewer-nav-pin.ps1'
        Stamp  = 'test\win32\viewer-nav-pin.stamp.json'
        Covers = @(
            'test\win32\viewer-nav-pin.ps1',
            'src\apprt\win32\viewer_nav_layout.zig',
            'src\apprt\win32\ViewerPane.zig'
        )
    },
    # The feedback composer (T644): its undo behaviour, quote formatting and
    # send path live in ViewerFeedbackBar and are proved only by this harness
    # - the unit lanes see the pure modules but never a RichEdit. T644 itself
    # arrived through this gap: arm J sat red with nothing tying a composer
    # edit to a re-run.
    [pscustomobject]@{
        Name   = 'viewer-feedback'
        Script = 'test\win32\viewer-feedback.ps1'
        Stamp  = 'test\win32\viewer-feedback.stamp.json'
        Covers = @(
            'test\win32\viewer-feedback.ps1',
            'src\apprt\win32\ViewerFeedbackBar.zig',
            'src\apprt\win32\richedit_tom.zig',
            'src\apprt\win32\viewer_feedback_doc.zig'
        )
    },
    # The composer's WEB surface (T934): the second WebView2 controller that
    # replaced the RichEdit, its page, and the two-way message channel between
    # them. Separate from `viewer-feedback` above because the two drive
    # different surfaces - that suite pins itself to the RichEdit fallback,
    # which is the only one window messages can reach from the background test
    # desktop, and this one proves the surface users actually get.
    [pscustomobject]@{
        Name   = 'viewer-composer'
        Script = 'test\win32\viewer-composer.ps1'
        Stamp  = 'test\win32\viewer-composer.stamp.json'
        Covers = @(
            'test\win32\viewer-composer.ps1',
            'src\apprt\win32\ViewerFeedbackWeb.zig',
            'src\apprt\win32\viewer_feedback_page.zig',
            'src\viewer\composer.js',
            'src\viewer\composer.css'
        )
    },
    # The per-session ConPTY holder (T904): the only harness that drives a
    # real `--pty-host` process over its real control pipe - ConPTY output,
    # resize, reconnect gap-replay, exit-code delivery, the Job Object
    # subtree kill, and the pipe's owner-only DACL. The pure protocol/replay
    # units run in the test-agent lane every floor run and are deliberately
    # NOT covered here; the runtime files are.
    [pscustomobject]@{
        Name   = 'pty-host'
        Script = 'test\win32\pty-host.ps1'
        Stamp  = 'test\win32\pty-host.stamp.json'
        Covers = @(
            'test\win32\pty-host.ps1',
            'src\remote\agent\pty_host.zig',
            'src\remote\agent\pty_host_smoke.zig',
            'src\remote\agent\pty_host_proto.zig'
        )
    },
    # Holder-backed sessions (T905): the only harness that measures the promise
    # the holder design exists for - kill the AGENT and the shell keeps running.
    # It runs a real app + agent + holder and reads the outcome off the process
    # table and `sessions.json`, with a flag-OFF negative control proving the
    # old behavior (shell dies with the agent) is what changed. Neither test
    # lane can see any of this: it is entirely about which PROCESS owns a
    # ConPTY, and both children present the identical `session.Child` vtable.
    [pscustomobject]@{
        Name   = 'pty-holder'
        Script = 'test\win32\pty-holder.ps1'
        Stamp  = 'test\win32\pty-holder.stamp.json'
        Covers = @(
            'test\win32\pty-holder.ps1',
            'src\remote\agent\pty_holder_child.zig',
            'src\remote\agent\pty_host_spec.zig'
        )
    },
    # Agent AUTOSTART + the reboot floor (T89h; row added by T1108): the only
    # harness that executes the HKCU Run value the way winlogon does - raw
    # CreateProcess on the recorded command line - and then asserts what comes
    # back. A quoting slip in that value, or a Run-key name that stops matching
    # the build lineage, is invisible to every lane and to every other script:
    # they all start the agent themselves. The reboot half rides the same run,
    # so `session_meta`/`materialize` changing what a restored session looks
    # like makes it due too. T1108 is the case for the row - the script sat red
    # from the T1094 sweep with nothing obliged to run it, and it was red
    # because holders (T909) made its reboot proxy stop being one.
    [pscustomobject]@{
        Name   = 'agent-autostart'
        Script = 'test\win32\agent-autostart.ps1'
        Stamp  = 'test\win32\agent-autostart.stamp.json'
        Covers = @(
            'test\win32\agent-autostart.ps1',
            'src\apprt\win32\LocalAgent.zig',
            'src\remote\agent\session_meta.zig'
        )
    },
    # Holder RE-ADOPTION (T906): the only harness that measures the number that
    # separates adoption from the relaunch path agent-recovery.ps1 covers - the
    # SHELL PID is unchanged across a manager kill. It also owns the orphan
    # sweep, which is destructive by design (it shuts holders down), so the
    # rules that decide who gets reaped must never ship un-run.
    [pscustomobject]@{
        Name   = 'holder-adopt'
        Script = 'test\win32\holder-adopt.ps1'
        Stamp  = 'test\win32\holder-adopt.stamp.json'
        Covers = @(
            'test\win32\holder-adopt.ps1',
            'src\remote\agent\holder_adopt.zig',
            'src\remote\agent\session_meta.zig'
        )
    },
    # Holder DURABILITY (T911): the only harness that measures the ring snapshot
    # FILE rather than the pane, which is the difference between "the app still
    # has the pixels" and "a fresh viewer can replay it". It owns the meaning of
    # an ACK to a holder - permission to FREE - and getting that wrong is silent:
    # every other holder harness passes while the tail of a user's scrollback
    # stops existing the moment the agent dies.
    [pscustomobject]@{
        Name   = 'holder-durable'
        Script = 'test\win32\holder-durable.ps1'
        Stamp  = 'test\win32\holder-durable.stamp.json'
        Covers = @(
            'test\win32\holder-durable.ps1',
            'src\remote\agent\ring_snapshot.zig'
        )
    },
    # Holder VOLUME (T969): the sibling of the row above, for the other half of
    # the recoverable window. Durability answers "is anything still holding it";
    # this answers "was it written down before the holder had to drop it". The
    # failure it guards is a busy pane silently getting a smaller crash-recovery
    # guarantee than a quiet one, which no per-pane test can see - the pane is
    # correct either way, and only the file on disk is short.
    [pscustomobject]@{
        Name   = 'holder-volume'
        Script = 'test\win32\holder-volume.ps1'
        Stamp  = 'test\win32\holder-volume.stamp.json'
        Covers = @(
            'test\win32\holder-volume.ps1',
            'src\remote\agent\session.zig',
            'src\remote\agent\pty_holder_child.zig'
        )
    },
    # Pane INGEST LAG (T1142): the only harness that measures how far behind its
    # own child a pane's SCREEN runs. Every other test asks whether output
    # ARRIVES; this one asks how fast, on both the agent-backed path and the
    # local `termio.Exec` one, and asserts that the backlog drains rather than
    # stalls. It exists because "the app's terminal state trails the agent's ring
    # by minutes on a burst" was folklore for a week - true on the Debug build,
    # false on the release build, and nothing on the box could tell the two
    # apart. Neither test lane can see any of it: the number only exists with a
    # real ConPTY, a real child and a real parse loop under it.
    [pscustomobject]@{
        Name   = 'pane-ingest-lag'
        Script = 'test\win32\pane-ingest-lag.ps1'
        Stamp  = 'test\win32\pane-ingest-lag.stamp.json'
        Covers = @(
            'test\win32\pane-ingest-lag.ps1',
            'src\termio\Remote.zig',
            'src\termio\Exec.zig',
            'src\renderer\State.zig',
            'src\remote\inbound_ring.zig'
        )
    },
    # Holders AT SCALE (T909): once holder-backed spawning became the default,
    # the per-session process stopped being a cost an opt-in user chose and
    # became one every box pays. This is the only harness that runs a realistic
    # fleet of sessions at once and reads the cost off the process table - and
    # the only one where a per-session teardown leak shows up as a pile of
    # orphans rather than as one process nobody notices. It also owns the
    # spawn-time decision in `pty_child.zig`, which no other harness covers:
    # a holder-spawn failure falls back to the in-process child with only a log
    # line, so "every live session has a holder" is the assertion that catches
    # a silent fallback.
    [pscustomobject]@{
        Name   = 'holder-soak'
        Script = 'test\win32\holder-soak.ps1'
        Stamp  = 'test\win32\holder-soak.stamp.json'
        Covers = @(
            'test\win32\holder-soak.ps1',
            'src\remote\agent\pty_child.zig'
        )
    },
    # Non-destructive agent HANDOFF (T907): the choreography that lets the
    # session manager replace itself with a newer build while sessions are open.
    # Two things make it un-shippable un-run. It is the only harness that proves
    # the ROLLBACK - a successor that dies must leave the ORIGINAL agent serving,
    # and the failure mode of getting that wrong is "no agent at all" - and it is
    # the only one that measures the shell pid ACROSS an upgrade rather than
    # across a kill.
    [pscustomobject]@{
        Name   = 'agent-handoff'
        Script = 'test\win32\agent-handoff.ps1'
        Stamp  = 'test\win32\agent-handoff.stamp.json'
        Covers = @(
            'test\win32\agent-handoff.ps1',
            'src\remote\agent\handoff.zig',
            'src\apprt\win32\agent_upgrade.zig',
            'src\remote\agent_build.zig'
        )
    },
    # The agent-upgrade DECISION as the user meets it (T147/T125/T907), and the
    # row T1037 exists because of: the policy grew a whole new arm when the agent
    # learned to replace itself, four of this harness's assertions became wrong
    # in the same commit, and nothing obliged anyone to re-run it - so it sat 27-
    # red at HEAD for 12 days. It is the only harness that drives the real dialog
    # (mandatory modality, decline, accept, the deferral to the next idle moment)
    # and the only one that measures the STAND-DOWN: no dialog, no restart, the
    # session carried across by the agent itself. App.zig is deliberately not
    # covered - it moves for a hundred unrelated reasons and would leave this
    # multi-minute GUI run due every turn - so the residual gap is App.zig's
    # WIRING of the check, which only a run of this catches.
    [pscustomobject]@{
        Name   = 'agent-upgrade'
        Script = 'test\win32\agent-upgrade.ps1'
        Stamp  = 'test\win32\agent-upgrade.stamp.json'
        Covers = @(
            'test\win32\agent-upgrade.ps1',
            'src\apprt\win32\agent_upgrade.zig',
            'src\apprt\win32\LocalAgent.zig'
        )
    },
    # Cross-lineage layout blobs (T337/T623): the only harness that proves the
    # REAL binary translates a Mac-shaped blob on the launch-restore path and,
    # since T623, that the restored window lands the right way up (the
    # primaryScreenHeight flip). Not in the P1-P3 floor, and the unit lanes
    # cannot see whether decodeLayouts is actually wired into restore.
    [pscustomobject]@{
        Name   = 'layout-blob-cross-lineage'
        Script = 'test\win32\layout-blob-cross-lineage.ps1'
        Stamp  = 'test\win32\layout-blob-cross-lineage.stamp.json'
        Covers = @(
            'src\apprt\win32\mac_layout_blob.zig',
            'src\apprt\win32\layout_blobs.zig',
            'src\apprt\win32\restore_frame.zig',
            'test\win32\layout-blob-cross-lineage.ps1'
        )
    },
    # The delivery pipeline (T531): upgrade-ghoztty-windows.ps1 kills the
    # user's terminal, swaps the installed release, and must bring the terminal
    # back - an edit that breaks any of that only ever fails during a real
    # delivery, where nobody is watching, and neither harness is in the P1-P3
    # floor. The -NoResume incident (2026-08-06: a delivery left the user with
    # no terminal at all) is exactly the class of regression these gate.
    [pscustomobject]@{
        Name   = 'upgrade-staleness'
        Script = 'test\win32\upgrade-staleness.ps1'
        Stamp  = 'test\win32\upgrade-staleness.stamp.json'
        Covers = @(
            'scripts\upgrade-ghoztty-windows.ps1',
            'scripts\launch-upgrade.ps1',
            'scripts\delivery-version.ps1',
            'test\win32\upgrade-staleness.ps1',
            # T1098: section E is what raised a system-modal dialog for as long
            # as it existed, and E23 is the arm that would now catch it.
            'test\win32\lib\ModalSweep.ps1'
        )
    },
    # The UNATTENDED half of the delivery (T1120), which had a harness and no row
    # here either: `morning-refresh.ps1` restarts the user's terminal at 5am with
    # nobody in front of it, and its contract is that NOTHING it starts can raise
    # a prompt. That claim is checked only by this harness - not by any lane, not
    # by P1-P3 - and it went stale in exactly the way a guard exists to catch: an
    # assertion about the agent-restart modal was left behind by T1056 and sat red
    # until a full-suite sweep tripped over it. It covers the app-side marker code
    # as well as the two scripts, because the prompt that must not appear is the
    # app's.
    [pscustomobject]@{
        Name   = 'morning-refresh'
        Script = 'test\win32\morning-refresh.ps1'
        Stamp  = 'test\win32\morning-refresh.stamp.json'
        Covers = @(
            'scripts\morning-refresh.ps1',
            'scripts\upgrade-ghoztty-windows.ps1',
            'src\apprt\win32\agent_upgrade.zig',
            # The prompts section E enumerates live here. These two churn often
            # and the harness is hermetic and takes well under a minute, which is
            # the trade: a cheap run every so often, against a suppression that
            # can be deleted in a one-line edit nothing else would notice.
            'src\apprt\win32\App.zig',
            'src\apprt\win32\AgentIntegration.zig',
            'test\win32\morning-refresh.ps1'
        )
    },
    # The MEASURED half of the delivery (T198), which had a harness but no row
    # here: `deliver-windows-build.ps1` is what proves the Desktop portable, the
    # network share, the loose agent and the portable ZIP actually received the
    # build - and every claim it makes is a read-back, so an edit that weakens
    # one turns a delivery into an assertion again without any lane going red.
    # Its harness is hermetic (a sandbox under %TEMP%, no Docker, no network), so
    # there is no reason for it not to be gated. Noticed while adding the
    # sign-in read-back in T795.
    [pscustomobject]@{
        Name   = 'deliver-verify'
        Script = 'test\win32\deliver-windows-build.ps1'
        Stamp  = 'test\win32\deliver-windows-build.stamp.json'
        Covers = @(
            'scripts\deliver-windows-build.ps1',
            'scripts\delivery-manifest.ps1',
            'test\win32\deliver-windows-build.ps1'
        )
    },
    # The reboot floor's ONE user-visible promise (T230/T823): an agent restart
    # must never put a recorded command back on a CPU. Nothing in the P1-P3 floor
    # or either unit lane can see it - the policy only fires when the agent has
    # restarted and materialized a dead tombstone from disk, which takes a real
    # reboot-equivalent cycle - so a `termio\Remote.zig` edit that broke it would
    # stay invisible until the user's next reboot silently started a brand-new
    # Claude Code session in every pane, which is the exact complaint that
    # produced T230. Only the DEFAULT-policy harness is gated: `rerun`/`prompt`
    # are opt-ins nobody's reboot lands on by accident, and their harness
    # (`session-relaunch.ps1`) is one more long GUI run per Remote.zig edit for a
    # path the default never takes. That ungated harness is where T824's DECRQM
    # oracle lives (section A: the replay re-arms the dead program's mouse
    # tracking, and the reset must land behind it) - run it by hand when the
    # RELAUNCH path in `termio\Remote.zig` changes.
    [pscustomobject]@{
        Name   = 'session-relaunch'
        Script = 'test\win32\session-relaunch-notify.ps1'
        Stamp  = 'test\win32\session-relaunch-notify.stamp.json'
        Covers = @(
            'src\termio\Remote.zig',
            'src\termio\session_notice.zig',
            # T975: the agent's pipe TRANSPORT belongs here because this harness
            # is the only thing that noticed when it broke. A listener that
            # stopped accepting after one abandoned dial passed every test lane
            # (nothing there aborts a dial) and every other acceptance script
            # (they all reach a healthy agent first) - and cost a rebooting user
            # their entire layout, because the app's own timed-out dial was the
            # thing that wedged the agent it had just spawned.
            'src\remote\pipe_stream.zig',
            # T922: what a restored pane can possibly SHOW is decided before the
            # kill, by the manifest. The writer and the refresh policy are
            # therefore part of this harness's subject - arm A15 is scored on a
            # marker that only reaches the pane through this file - even though
            # neither is on the restore path itself. `App.zig` is deliberately
            # NOT here: it is edited by most tasks and would leave this
            # twelve-minute GUI run due every turn, so the policy was split out
            # into `layout_refresh.zig` to be watchable on its own. The residual
            # gap is App.zig's WIRING of it (the timer, the pane walk), which
            # only a run of this harness catches.
            'src\apprt\win32\session_layout.zig',
            'src\apprt\win32\layout_refresh.zig',
            # T974: arm M is the only place the ADOPTION path is scored on what
            # the user sees - the program they were running is the same process,
            # and no pane claims an interruption. `holder-adopt` covers the same
            # file on the mechanism side (same shell pid, same holder); this
            # harness is what notices when adoption still "works" and the panes
            # get told they died anyway. Rarely edited, so the twelve-minute run
            # this makes due is not a per-turn cost.
            'src\remote\agent\holder_adopt.zig',
            'test\win32\session-relaunch-notify.ps1'
        )
    },
    # T1048: the only harness that measures WHICH captured tree a rebuilt tab is
    # rebuilt from. It drives the one window nothing else can reach - the tab
    # list moving between `captureSessionLayout` and the rebuild, while the
    # re-dial is blocked on a frozen agent - and scores the shell pid at each tab
    # POSITION. agent-recovery.ps1 covers the same recovery on a single-tab
    # window, where a positional join and an identity join agree, so a pairing
    # regression is invisible there and green everywhere else: the panes all come
    # back, just holding each other's sessions.
    [pscustomobject]@{
        Name   = 'agent-recovery-tabs'
        Script = 'test\win32\agent-recovery-tabs.ps1'
        Stamp  = 'test\win32\agent-recovery-tabs.stamp.json'
        Covers = @(
            'test\win32\agent-recovery-tabs.ps1',
            # The pairing itself, and the identity it pairs on. `App.zig` is
            # deliberately not here for the same reason session-relaunch keeps it
            # out: it is edited by most tasks and would leave this GUI run due
            # every turn.
            'src\apprt\win32\session_layout.zig'
        )
    },
    # The clipboard is a machine-wide resource with a give-up-at-once API, so
    # its regressions are INTERMITTENT by construction: a copy that vanishes one
    # time in ten reads to a user as flakiness in their own hands, and to every
    # other harness here as a pass. This one manufactures the contention (a
    # second process holding the clipboard on a real HWND) and drives a real
    # copy through OSC 52, so the give-up shape fails ON PURPOSE rather than on
    # somebody's unlucky afternoon. Surface.zig is deliberately NOT covered - it
    # is edited by most tasks and would leave this due every turn; the retry
    # helper and the source guard in arm C are what keep the call sites honest.
    [pscustomobject]@{
        Name   = 'clipboard-retry'
        Script = 'test\win32\clipboard-retry.ps1'
        Stamp  = 'test\win32\clipboard-retry.stamp.json'
        Covers = @(
            'src\apprt\win32\clipboard_open.zig',
            'src\apprt\win32\clipboard_image.zig',
            'test\win32\clipboard-retry.ps1'
        )
    },
    [pscustomobject]@{
        Name   = 'upgrade-no-fork'
        Script = 'test\win32\upgrade-no-fork.ps1'
        Stamp  = 'test\win32\upgrade-no-fork.stamp.json'
        Covers = @(
            'scripts\upgrade-ghoztty-windows.ps1',
            'scripts\loop-session.ps1',
            'test\win32\upgrade-no-fork.ps1'
        )
    },
    # The release wiring (T578): the workflows, the shared artifact/toolchain
    # scripts, and the on-box publish path only ever execute during an actual
    # release or a CI run nobody on this box watches, so an edit to any of
    # them can only be caught by the static harness -- which sat red for a
    # week after T577 changed the triggers, because nothing tied these files
    # to a run of it.
    #
    # SPLIT IN TWO (T898). release-artifacts.ps1 has a Docker-gated section, and
    # it only stamped on a run with zero skips - the right bar for the packaging
    # payload, and the wrong one for a workflow file. Docker is deliberately kept
    # down on this box, so between 2026-08-16 and 2026-08-18 an edit to
    # fork-ci.yml left this row due FOREVER: twelve turns met a permanently-red
    # guard, twelve filed a duplicate task for it, and every commit in between
    # went out under the `-NoGuardDue` hatch, which is how a hatch stops meaning
    # anything. The wiring files below are proved end to end by sections A, C, E
    # and F, none of which touch Docker, so this row stamps from an ordinary
    # green run. The two payload scripts moved to the packaging row, which keeps
    # the zero-skip bar.
    [pscustomobject]@{
        Name   = 'release-artifacts'
        Script = 'test\win32\release-artifacts.ps1'
        Stamp  = 'test\win32\release-artifacts.stamp.json'
        Covers = @(
            '.github\workflows\release-windows.yml',
            '.github\workflows\fork-ci.yml',
            'dist\windows-installer\build-release-artifacts.sh',
            'dist\windows-installer\install-msitools.sh',
            'scripts\publish-windows-release.ps1',
            'test\win32\release-artifacts.ps1'
        )
    },
    # The PACKAGING half of the same harness (T898): the scripts that actually
    # build the payload, whose only real proof is section B running them and
    # reading the artifact back. A run that could not build vouching for the
    # payload is the exact lie T783's mechanism exists to prevent.
    #
    # Split in two by T1052, because the two payloads no longer have the same
    # requirement. The MSI needs wixl/msitools, which is Linux tooling and
    # therefore Docker on this box; the portable ZIP needs bash + python3 and
    # nothing else, so section B builds it through Git Bash and reads its entry
    # set back on any box with git installed. Keeping them on one row meant the
    # ZIP - the artifact that had silently shipped without ghoztty.com for
    # months - could not be proved here at all. The harness itself is
    # deliberately NOT covered by either row: it is the wiring row's subject,
    # and an edit to a static assertion must not put these rows out of reach.
    [pscustomobject]@{
        Name    = 'release-artifacts-packaging'
        Script  = 'test\win32\release-artifacts.ps1'
        RunArgs = '-RequireDocker'
        Stamp   = 'test\win32\release-artifacts-packaging.stamp.json'
        Covers  = @(
            'dist\windows-installer\build-msi.sh'
        )
    },
    [pscustomobject]@{
        Name   = 'release-artifacts-zip'
        Script = 'test\win32\release-artifacts.ps1'
        Stamp  = 'test\win32\release-artifacts-zip.stamp.json'
        Covers = @(
            'dist\windows-installer\build-portable-zip.sh'
        )
    },
    # The site's Windows downloads (T353). Both halves of the release's website
    # update -- the rewrite script and the gh-pages publish script it runs
    # inside -- only ever execute during a real release, and the publish
    # script's retry loop does not execute even then unless a concurrent
    # appcast push beats it. Section G runs both for real against local bare
    # repos with that collision staged, so an edit here can be caught on this
    # box; nothing else in the tree looks at either file. Stamped by any run
    # with zero failures: sections E and F need the network and cover neither
    # script, so gating the stamp on their skips would make this row a wedge on
    # an offline box (the T898 lesson).
    # One Windows installer (T1175). The retirement of the standalone agent
    # MSI is a SHAPE, not a code path: nothing crashes if a link, a publish
    # target or a doc paragraph brings the second installer back, and nothing
    # else in the tree reads these files. This row is what makes an edit to
    # any download surface ask whether the invariant still holds.
    [pscustomobject]@{
        Name   = 'one-installer'
        Script = 'test\win32\one-installer.ps1'
        Stamp  = 'test\win32\one-installer.stamp.json'
        Covers = @(
            'relay\deploy\ghpages\index.html',
            'relay\deploy\ghpages\landing\main.js',
            'relay\deploy\www\index.html',
            'relay\deploy\install.ps1',
            'relay\deploy\publish-agent.sh',
            'relay\deploy\Caddyfile.example',
            'relay\README.md',
            'test\win32\one-installer.ps1'
        )
    },
    # Installing ends with a running terminal, and installs the whole product
    # (T1176). Both halves are shapes inside one bash script: a dropped agent
    # or twin makes a half-product that looks installed, and a dropped custom
    # action makes an install that finishes with nothing on screen. Neither is
    # visible without building an MSI, which needs Docker on this box - so
    # this row is what makes an edit to build-msi.sh ask the question here,
    # where it can be answered with no toolchain at all.
    [pscustomobject]@{
        Name   = 'install-launch'
        Script = 'test\win32\install-launch.ps1'
        Stamp  = 'test\win32\install-launch.stamp.json'
        Covers = @(
            'dist\windows-installer\build-msi.sh',
            'dist\windows-installer\build-release-artifacts.sh',
            '.github\workflows\fork-ci.yml',
            'test\win32\install-launch.ps1'
        )
    },
    [pscustomobject]@{
        Name   = 'website-windows-links'
        Script = 'test\win32\website-windows-download.ps1'
        Stamp  = 'test\win32\website-windows-links.stamp.json'
        Covers = @(
            'dist\website\publish-windows-links.sh',
            'dist\website\update-windows-links.py',
            'test\win32\website-windows-download.ps1'
        )
    },
    # Single-instance launch (T1022): the only harness that proves a second
    # launch of one build JOINS the app already running while a second LINEAGE
    # still starts its own. Both arms need two real GUI launches racing for one
    # endpoint, which no unit lane can stage, and the whole behavior lives in
    # `App.init`'s bind -> AlreadyRunning -> forward path. It is not in the
    # P1-P3 floor, so without this row an edit to the endpoint derivation or to
    # the handoff could silently turn every launch into a second app again.
    [pscustomobject]@{
        Name   = 'single-instance-join'
        Script = 'test\win32\single-instance-join.ps1'
        Stamp  = 'test\win32\single-instance-join.stamp.json'
        Covers = @(
            'test\win32\single-instance-join.ps1',
            'src\os\ipc_handoff.zig',
            'src\apprt\win32\IpcServer.zig'
        )
    },
    # Release version-drift detection (T579): the checker and its CI wiring
    # only ever matter around a release, which is exactly when nobody on this
    # box is watching -- the same argument as release-artifacts above. Its
    # harness overlaps fork-ci.yml with that row on purpose: section B here
    # asserts the release-parity job's wiring, which release-artifacts.ps1
    # does not look at.
    [pscustomobject]@{
        Name   = 'release-parity'
        Script = 'test\win32\release-parity.ps1'
        Stamp  = 'test\win32\release-parity.stamp.json'
        Covers = @(
            'scripts\check-release-parity.ps1',
            '.github\workflows\fork-ci.yml',
            'test\win32\release-parity.ps1'
        )
    },
    # `--when-idle`'s busy detection (T46 motion, T517 --busy-marker): a broken
    # idle poll only ever fails inside a detached automation send — the loop
    # types into a mid-turn session and the damage reads as "the agent ignored
    # the prompt", never as a send_keys bug — and ipc-when-idle.ps1 is not in
    # the P1-P3 floor, so nothing else ties a send_keys.zig edit to a run of it.
    [pscustomobject]@{
        Name   = 'when-idle'
        Script = 'test\win32\ipc-when-idle.ps1'
        Stamp  = 'test\win32\ipc-when-idle.stamp.json'
        Covers = @(
            'src\cli\send_keys.zig',
            'test\win32\ipc-when-idle.ps1'
        )
    },
    # The sharing uplink (T546) only ever runs when a machine is marked shared,
    # so a regression in the raise/park/reconcile path is invisible to the
    # P1-P3 floor and to every local-agent test - nothing else ties an edit of
    # the uplink graft (main.zig), its config module, or the loop/creds
    # machinery it drives to a run of the harness that dials a real listener.
    [pscustomobject]@{
        Name   = 'agent-sharing-uplink'
        Script = 'test\win32\agent-sharing-uplink.ps1'
        Stamp  = 'test\win32\agent-sharing-uplink.stamp.json'
        Covers = @(
            'src\remote\agent\sharing.zig',
            'src\remote\agent\main.zig',
            'src\remote\agent\relay_creds.zig',
            'src\remote\agent\link_control.zig',
            'test\win32\agent-sharing-uplink.ps1'
        )
    },
    # The PAYLOAD half of the same uplink (T887). agent-sharing-uplink proves
    # the machine dials the relay; this one proves what arrives down that dial
    # becomes a session in the SAME store the local pipe serves. It is the only
    # thing on the box that exercises serveControl's open command, RelayWorker's
    # data dial, and serveOne over a relay transport - so an edit to any of them
    # that keeps the DIAL green can still break the one-store claim, which is
    # the whole point of the consolidated agent.
    [pscustomobject]@{
        Name   = 'agent-relay-session'
        Script = 'test\win32\agent-relay-session-e2e.ps1'
        Stamp  = 'test\win32\agent-relay-session-e2e.stamp.json'
        Covers = @(
            'src\remote\agent\main.zig',
            'src\remote\agent\server.zig',
            'src\remote\agent\session.zig',
            'src\remote\agent\link_control.zig',
            'src\remote\ws_client.zig',
            'src\cli\sessions.zig',
            'test\win32\lib\FakeAgentRelay.ps1',
            'test\win32\agent-relay-session-e2e.ps1'
        )
    },
    # Standalone-install adoption (T549) only fires on a box that still has
    # the old agent MSI, so the whole flow - idle-stop, the deny-terminate
    # shield around the uninstall, the Run-key repair - is invisible to the
    # P1-P3 floor; nothing else ties an adopt.zig edit to the harness that
    # proves the shield still refuses a mid-uninstall kill.
    [pscustomobject]@{
        Name   = 'agent-adopt'
        Script = 'test\win32\agent-adopt.ps1'
        Stamp  = 'test\win32\agent-adopt.stamp.json'
        Covers = @(
            'src\remote\agent\adopt.zig',
            'test\win32\agent-adopt.ps1'
        )
    },
    # The share-this-machine toggle (T547) only ever acts when a user flips it,
    # so its enrollment worker and file plumbing are invisible to the P1-P3
    # floor - nothing else ties an edit of the toggle's async module to a run
    # of the harness that drives the checkbox against a fake relay.
    [pscustomobject]@{
        Name   = 'share-machine'
        Script = 'test\win32\share-machine.ps1'
        Stamp  = 'test\win32\share-machine.stamp.json'
        Covers = @(
            'src\apprt\win32\ShareMachineRow.zig',
            'test\win32\share-machine.ps1'
        )
    },
    # The divergence inventory (T516) is upstream-pull planning's input: a set
    # computation that drifts wrong sends a future merge hunting conflicts in
    # the wrong files, and nothing in the P1-P3 floor runs its harness.
    [pscustomobject]@{
        Name   = 'divergence-inventory'
        Script = 'test\win32\divergence-inventory.ps1'
        Stamp  = 'test\win32\divergence-inventory.stamp.json'
        Covers = @(
            'scripts\divergence-inventory.ps1',
            'test\win32\divergence-inventory.ps1'
        )
    },
    # The vendored agent assets (T866) rot silently: main edits its copy of a
    # skill or hook script and nothing here goes red until someone re-runs the
    # drift compare, and a banner-script or +json edit that breaks the jq-free
    # flow only ever fails inside an agent's hook, where stderr is discarded.
    [pscustomobject]@{
        Name   = 'hook-json'
        Script = 'test\win32\hook-json.ps1'
        Stamp  = 'test\win32\hook-json.stamp.json'
        Covers = @(
            'src\cli\json.zig',
            'src\apprt\win32\GhosttyAssets.zig',
            'src\apprt\win32\assets\ghoztty\hooks\*.sh',
            'src\apprt\win32\assets\ghoztty\skills\*\SKILL.md',
            'src\apprt\win32\assets\ghoztty\upstream\hooks\*.sh',
            'src\apprt\win32\assets\ghoztty\upstream\skills\*\SKILL.md',
            'test\win32\hook-json.ps1'
        )
    },
    # The forgotten-session notification (T534): its policy only ever acts a
    # DAY after a session is orphaned, so a regression is invisible to every
    # interactive use of the tree, and its harness is not in the P1-P3 floor.
    [pscustomobject]@{
        Name   = 'orphan-notify'
        Script = 'test\win32\orphan-notify.ps1'
        Stamp  = 'test\win32\orphan-notify.stamp.json'
        Covers = @(
            'src\apprt\win32\orphan_notify.zig',
            'src\apprt\win32\tray_notify.zig',
            'test\win32\orphan-notify.ps1',
            'test\win32\lib\ChooserCursor.ps1'
        )
    },
    # The activity-state machine (T605): main's own oracle run verbatim under
    # Git Bash against the live win32 hook asset, plus the native-pid arms the
    # oracle cannot see. A hook-script edit that breaks a transition only ever
    # fails inside an agent's hook, where stderr is discarded, and the vendored
    # oracle mirror rots exactly like the T866 asset mirrors.
    [pscustomobject]@{
        Name   = 'activity-state'
        Script = 'test\win32\activity-state.ps1'
        Stamp  = 'test\win32\activity-state.stamp.json'
        Covers = @(
            'src\apprt\win32\assets\ghoztty\hooks\ghoztty-activity-state.sh',
            'test\win32\lib\upstream\test-activity-state.sh',
            'test\win32\activity-state.ps1'
        )
    },
    # The Activity Monitor PANEL (T989), which is a different subject from the
    # activity-state hook above: a window with a text field, a live table and
    # two destructive actions, and the only harness that drives any of it.
    # T989 was a panic reachable by typing into that field, found by accident
    # while measuring something else - the class of defect the floor lanes
    # cannot see, since the panel's own logic only runs behind an HWND.
    # Deliberately narrow: the panel's pure modules (layout, rows, cards, the
    # gauge) carry their own unit tests in the win32 lane, and covering them
    # here would fire this gate on edits the script cannot fail on.
    [pscustomobject]@{
        Name   = 'activity-monitor'
        Script = 'test\win32\activity-monitor.ps1'
        Stamp  = 'test\win32\activity-monitor.stamp.json'
        Covers = @(
            'src\apprt\win32\ActivityMonitor.zig',
            'test\win32\activity-monitor.ps1'
        )
    },
    # The menu bar (T987): menu-bar.ps1 carries a full model of every submenu,
    # row and separator, and nothing tied that model to the tables it mirrors -
    # so T871's rename of one Help row left the harness one assertion red for
    # months, which is how a red suite becomes background noise. Covers the two
    # tables the model IS (menu_bar.zig's node tree, commands.zig's titles) and
    # the harness itself; the rest of the win32 chrome is out of scope, since a
    # gate that fires on every chrome edit is the noise T783 warns about.
    [pscustomobject]@{
        Name   = 'menu-bar'
        Script = 'test\win32\menu-bar.ps1'
        Stamp  = 'test\win32\menu-bar.stamp.json'
        Covers = @(
            'src\apprt\win32\menu_bar.zig',
            'src\apprt\win32\commands.zig',
            'test\win32\menu-bar.ps1'
        )
    },
    # Crash evidence is the other thing whose failure nothing else catches: a
    # capture path that has quietly stopped working looks exactly like a lane
    # that did not crash, and is only ever exercised on a day already going
    # badly. scripts\floor-lane.ps1 is deliberately NOT covered - it is edited
    # for reasons that have nothing to do with crash capture (stall detection,
    # lane table), and a gate that fires on those is the noise T783 warns about.
    [pscustomobject]@{
        Name   = 'crash-first-chance'
        Script = 'test\win32\crash-first-chance.ps1'
        Stamp  = 'test\win32\crash-first-chance.stamp.json'
        Covers = @(
            'scripts\lib\CrashDump.ps1',
            'scripts\lib\CrashCatch.ps1',
            'scripts\crash-catch.ps1',
            'test\win32\crash-first-chance.ps1'
        )
    },
    # The cache self-heal (T494) fires only on a torn cache, i.e. on a day
    # already going badly, so a quietly broken detector looks exactly like "no
    # corruption happened". scripts\floor-lane.ps1 itself stays uncovered for
    # the same reason as in the crash rows: its heal wiring is proven by this
    # harness's parse/wiring arms without gating every stall-detector edit.
    [pscustomobject]@{
        Name   = 'cache-heal'
        Script = 'test\win32\floor-lane-cache-heal.ps1'
        Stamp  = 'test\win32\floor-lane-cache-heal.stamp.json'
        Covers = @(
            'scripts\lib\CacheHeal.ps1',
            'test\win32\floor-lane-cache-heal.ps1'
        )
    },
    # The leaked-test-binary sweep (T837) is measurement first: its whole job is
    # to make a rare leak COUNTABLE, and a detector that has quietly stopped
    # matching reports the same "leaked test binaries: 0" as a clean run. Same
    # rule as the rows above -- the library and this harness are covered,
    # scripts\floor-lane.ps1 is not, so a stall-detector edit does not gate on
    # it; the wiring arm proves the wiring instead.
    [pscustomobject]@{
        Name   = 'lane-leak-sweep'
        Script = 'test\win32\floor-lane-leak-sweep.ps1'
        Stamp  = 'test\win32\floor-lane-leak-sweep.stamp.json'
        Covers = @(
            'scripts\lib\LaneLeak.ps1',
            'test\win32\floor-lane-leak-sweep.ps1'
        )
    },
    # The T443 instruments have the same failure profile as the crash captures,
    # in its purest form: T832 exists because both of them measured a condition
    # the defect has never occurred in, and reported "all clear" for months
    # while it was still there. A broken soak or a breakpoint that never arms
    # is indistinguishable from good news, so the harness has to be run against
    # the code as it stands rather than remembered.
    [pscustomobject]@{
        Name   = 'test-binary-soak'
        Script = 'test\win32\test-binary-soak.ps1'
        Stamp  = 'test\win32\test-binary-soak.stamp.json'
        Covers = @(
            'scripts\test-binary-soak.ps1',
            # The verdict the soak reports is DECIDED here since T877:
            # Get-CrashOccurrenceLine is what turns a round into `crash=` rather
            # than `fail=`. An edit to the classifier that never re-ran this
            # harness is the same hole T877 itself was, one layer down.
            'scripts\lib\CrashDiag.ps1',
            'test\win32\test-binary-soak.ps1'
        )
    },
    [pscustomobject]@{
        Name   = 'crash-databreak'
        Script = 'test\win32\crash-databreak.ps1'
        Stamp  = 'test\win32\crash-databreak.stamp.json'
        Covers = @(
            'scripts\crash-databreak.ps1',
            'scripts\lib\DataBreak.ps1',
            # DataBreak plants its breakpoints THROUGH New-CdbScript, so the
            # filter list and the script's tail are load-bearing here too. T478
            # armed the breakpoint exception and changed that tail; without this
            # row nothing would have asked whether a planted bp still fires.
            'scripts\lib\CrashCatch.ps1',
            'test\win32\crash-databreak.ps1'
        )
    },
    # A window class that paints itself but cannot paint into a caller's DC has
    # NO in-app symptom (T940): the app looks right and every pixel assertion
    # over that window silently goes back to the DWM capture that tears. Nothing
    # at compile time or run time notices, which is how 65 probes across 34
    # scripts stayed on the torn capture (T843). The guard is armed by any win32
    # source, deliberately: the case worth catching is a NEW window class, which
    # no narrower list could name in advance. The audit is static text over
    # source and finishes in about a second, so being due often costs a second,
    # not a turn.
    [pscustomobject]@{
        Name   = 'printclient-audit'
        Script = 'test\win32\printclient-audit.ps1'
        Stamp  = 'test\win32\printclient-audit.stamp.json'
        Covers = @(
            'src\apprt\win32\*.zig',
            'test\win32\printclient-audit.ps1'
        )
    },
    # crash-stacks.ps1 is the acceptance for the catcher ITSELF, and until T478
    # nothing tied it to the library it tests: the `bpe` blind spot -- a Zig
    # panic reported as "ran clean" on 10 runs out of 10 -- went a month without
    # a harness anyone was obliged to run. Overlapping crash-first-chance's
    # coverage is deliberate; the two prove different halves (this one catches a
    # crash live, that one reads the dump Windows already wrote).
    [pscustomobject]@{
        Name   = 'crash-stacks'
        Script = 'test\win32\crash-stacks.ps1'
        Stamp  = 'test\win32\crash-stacks.stamp.json'
        Covers = @(
            'scripts\lib\CrashCatch.ps1',
            'scripts\crash-catch.ps1',
            'test\win32\crash-stacks.ps1'
        )
    },
    # The banner is the one piece of chrome the user reads all day, and its
    # regressions are HORIZONTAL - a column that stops halfway is invisible to
    # every height oracle in the suite, so only pane-banner.ps1's pixel probes
    # can see it. The row was held back while that script was one-run-in-three
    # red; T835 found the flake was in the CAPTURE, not the banner, and with a
    # synchronous capture the script is deterministic enough to gate on.
    [pscustomobject]@{
        Name   = 'pane-banner'
        Script = 'test\win32\pane-banner.ps1'
        Stamp  = 'test\win32\pane-banner.stamp.json'
        Covers = @(
            'src\apprt\win32\BannerOverlay.zig',
            'src\apprt\win32\banner_layout.zig',
            'src\apprt\win32\banner_card.zig',
            'src\apprt\win32\banner_markdown.zig',
            'src\apprt\win32\banner_link.zig',
            'src\apprt\win32\BannerDialog.zig',
            'test\win32\pane-banner.ps1'
        )
    },
    # The hovered-frame capture is the ONLY way any script can photograph a
    # hover fill off the background desktop (T282), and it is a seam nothing
    # else exercises: four scripts consume it, none of them would fail
    # obviously if it started handing back the wrong frame. That is not
    # hypothetical - T845 is exactly that, a capture that returned the
    # UN-hovered frame about one run in ten and reported success, so the fill
    # assertions in pane-banner.ps1 read a correct build as a dead button. This
    # row ties the seam's own harness to the seam.
    [pscustomobject]@{
        Name   = 'hover-capture'
        Script = 'test\win32\hover-capture.ps1'
        Stamp  = 'test\win32\hover-capture.stamp.json'
        Covers = @(
            'src\apprt\win32\ipc_hover.zig',
            'src\apprt\win32\hover_capture.zig',
            'test\win32\lib\HoverCapture.ps1',
            'test\win32\hover-capture.ps1'
        )
    },
    # The loop's own continuation mechanism, and a harness with a history of
    # crying wolf (T483): its section B once flaked 1-in-3, so an edit to it
    # that nobody re-runs is exactly the "trusted from memory" gap T783 closes.
    # The helper it tests lives in the plugin cache OUTSIDE this repo, so the
    # row can only cover the script itself - the D-section arms are what tie
    # the cache copy to its source repo.
    [pscustomobject]@{
        Name   = 'reset-context'
        Script = 'test\win32\reset-context.ps1'
        Stamp  = 'test\win32\reset-context.stamp.json'
        Covers = @(
            'test\win32\reset-context.ps1'
        )
    },
    # The CLI's flag-rejection contract (T489): every field-parsing verb
    # routes its unknown/misvalued flags through args.zig's reporter, and
    # nothing in the P1-P3 floor ever types a MISTYPED flag - a regression
    # here reads as scripts quietly doing the wrong thing, which is the
    # silent-ignore disease the task existed for. The row stays on the two
    # ENGINES - args.zig for the field-parsing verbs, verb_flags.zig for the
    # forwarding ones (T852) - rather than all of src\cli: per-verb wiring is
    # pinned by the none-lane unit tests the floor already runs.
    [pscustomobject]@{
        Name   = 'cli-unknown-flag'
        Script = 'test\win32\cli-unknown-flag.ps1'
        Stamp  = 'test\win32\cli-unknown-flag.stamp.json'
        Covers = @(
            'src\cli\args.zig',
            'src\cli\verb_flags.zig',
            'test\win32\cli-unknown-flag.ps1'
        )
    },
    # The window-name env export (T492): panes of AUTO-named windows carry
    # $GHOZTTY_WINDOW_NAME, which nothing in the P1-P3 floor reads back out of
    # a pane's shell. The bake lives inside src\apprt\win32\Surface.zig's init,
    # which is deliberately NOT covered - that file moves for reasons that have
    # nothing to do with env bakes, and a gate that launches a multi-window GUI
    # harness on every Surface edit is the noise T783 warns about. The row
    # covers the script itself (the reset-context precedent).
    [pscustomobject]@{
        Name   = 'window-name-env'
        Script = 'test\win32\window-name-env.ps1'
        Stamp  = 'test\win32\window-name-env.stamp.json'
        Covers = @(
            'test\win32\window-name-env.ps1'
        )
    },
    # Shell-integration detection + the agent argv delivery (T151, T513):
    # detectShell's Windows spellings (.exe suffix, full paths, mixed case)
    # are proven end-to-end only by this harness — the none-lane unit tests
    # pin the table, but nothing else in the floor opens an agent-backed pane
    # and reads the child's command line back. The row stays on
    # shell_integration.zig (the subject) rather than all of src\termio:
    # Exec.zig moves for reasons that have nothing to do with detection.
    [pscustomobject]@{
        Name   = 'agent-shell-integration'
        Script = 'test\win32\agent-shell-integration.ps1'
        Stamp  = 'test\win32\agent-shell-integration.stamp.json'
        Covers = @(
            'src\termio\shell_integration.zig',
            'test\win32\agent-shell-integration.ps1'
        )
    },
    # The GUI launch-command path (T104, T487, T514): -e / --command= / a
    # config `command`, incl. the bare-shell-as-shell-choice forwarding. The
    # row stays on the harness itself: the code under test lives in core
    # src\Surface.zig, which moves for a hundred reasons this 4-minute GUI
    # harness cannot see, so covering it there would wedge every core edit.
    # An edit to the harness (or its assertions) must re-prove itself, which
    # before this row nothing required.
    [pscustomobject]@{
        Name   = 'gui-launch-command'
        Script = 'test\win32\gui-launch-command.ps1'
        Stamp  = 'test\win32\gui-launch-command.stamp.json'
        Covers = @(
            'test\win32\gui-launch-command.ps1'
        )
    },
    # Windows paths and URLs as LINKS in a pane (T757), and the gestures that
    # select one (T802's double-click arms). The regex half is pinned
    # exhaustively in the none lane; what only this harness can answer is what
    # the surface selects when clicked. The row covers the URL regex — the one
    # source file whose edits change this script's verdict and nothing else —
    # plus the harness itself. Deliberately NOT core src\Surface.zig: it moves
    # for a hundred reasons a 4-minute GUI harness cannot see (same call the
    # gui-launch-command row makes).
    [pscustomobject]@{
        Name   = 'terminal-link-paths'
        Script = 'test\win32\terminal-link-paths.ps1'
        Stamp  = 'test\win32\terminal-link-paths.stamp.json'
        Covers = @(
            'src\config\url.zig',
            'test\win32\terminal-link-paths.ps1'
        )
    },
    # The agent-integration first-run + plugin migration (T870) and the
    # Agent Integrations management window (T871): the prompts, the
    # off-thread install/probe marshalling, the migration's uninstall-first
    # ordering and the dialog's row actions are proven end-to-end only by
    # this harness — the unit lanes pin the pure pieces (service, migration
    # module, manifest parse, row derivation) but nothing else in the floor
    # launches the GUI with an unanswered state file. The row stays on the
    # flow modules; the shared components underneath (RuntimeIntegration,
    # hook specs) move under their own unit tests.
    [pscustomobject]@{
        Name   = 'claude-integration'
        Script = 'test\win32\claude-integration.ps1'
        Stamp  = 'test\win32\claude-integration.stamp.json'
        Covers = @(
            'src\apprt\win32\AgentIntegration.zig',
            'src\apprt\win32\AgentIntegrationsDialog.zig',
            'src\apprt\win32\agent_integrations_vm.zig',
            'src\apprt\win32\claude_plugin_migration.zig',
            'src\apprt\win32\claude_setup.zig',
            'test\win32\claude-integration.ps1'
        )
    },
    # The agent-integration ENGINE end-to-end (T872): install idempotence,
    # staleness, the typed refusals, rollback, the shared-banner refcount,
    # uninstall exactness and the migration's script-ownership rules, driven
    # through the real app over the debug-only `agent-integration` IPC seam.
    # The unit lanes pin every component in tempdirs; what only this harness
    # proves is that the APP wires them together behind the sandbox seams —
    # so the row covers the component/service modules the claude-integration
    # row deliberately leaves to unit tests, plus the seam itself.
    [pscustomobject]@{
        Name   = 'agent-integrations'
        Script = 'test\win32\agent-integrations.ps1'
        Stamp  = 'test\win32\agent-integrations.stamp.json'
        Covers = @(
            'src\apprt\win32\ipc_agent_integration.zig',
            'src\apprt\win32\agent_integration_service.zig',
            'src\apprt\win32\RuntimeIntegration.zig',
            'src\apprt\win32\runtime_probe.zig',
            'src\apprt\win32\runtime_agent.zig',
            'src\apprt\win32\BannerScriptInstaller.zig',
            'src\apprt\win32\SkillComponent.zig',
            'src\apprt\win32\HookComponent.zig',
            'src\apprt\win32\ClaudeHookSpec.zig',
            'src\apprt\win32\CopilotHookSpec.zig',
            'src\apprt\win32\hook_scripts.zig',
            'src\apprt\win32\managed_marker.zig',
            'src\apprt\win32\managed_file.zig',
            'src\apprt\win32\claude_plugin_manifest.zig',
            'test\win32\agent-integrations.ps1'
        )
    },
    # The tracker CLI itself (T892). `scripts\parity-tasks.ps1` is what the loop
    # picks work with and what the dashboard writes through, and NOTHING in the
    # zig lanes or the P1-P3 floor executes a line of it - its only proof is
    # this harness. A silent regression here does not show up as a red test, it
    # shows up as the loop taking the wrong task or a status flip going
    # unrecorded, which is exactly the class of defect T564 and T892 exist to
    # stop. The task DIRECTORY is deliberately not covered: 200 task files move
    # every day for reasons the CLI's behaviour cannot notice.
    [pscustomobject]@{
        Name   = 'parity-tasks'
        Script = 'test\win32\parity-tasks-seat.ps1'
        Stamp  = 'test\win32\parity-tasks-seat.stamp.json'
        Covers = @(
            'scripts\parity-tasks.ps1',
            'test\win32\parity-tasks-seat.ps1'
        )
    },
    # The two gates every turn runs, held to the rule that a gate must be
    # SHOWN to fail (T1133). Deliberately overlapping the `go-loop` and
    # `parity-tasks` rows above: those two ask "does this script still work?",
    # and this one asks the different question "can each of its refusals still
    # go red, and is every condition it reports demonstrated somewhere?". An
    # edit that adds a report to either gate must therefore re-run this and
    # register the new condition, which is the whole point - three checks in
    # one month turned out to be unable to fail, and nothing was obliged to
    # notice.
    [pscustomobject]@{
        Name   = 'gate-negatives'
        Script = 'test\win32\gate-negatives.ps1'
        Stamp  = 'test\win32\gate-negatives.stamp.json'
        Covers = @(
            'scripts\parity-tasks.ps1',
            'scripts\go-loop-exec.ps1',
            'test\win32\gate-negatives.ps1'
        )
    },
    # The on-demand test client (T359). `remote-test-client` is built by its own
    # zig step and by nothing the default build reaches, so six acceptance
    # scripts produce it themselves through lib\TestClient.ps1. Nothing in the
    # P1-P3 floor or the zig lanes runs a line of that helper, and its failure
    # mode is quiet: the client is simply absent again, and the scripts that
    # need it go back to failing on a precondition that reads like a product
    # bug. The six consumers are deliberately NOT covered - they move for agent
    # and session reasons this helper cannot see; section E re-derives the
    # consumer list from the tree on every run, so a seventh is caught without
    # a row here.
    [pscustomobject]@{
        Name   = 'test-client'
        Script = 'test\win32\test-client-build.ps1'
        Stamp  = 'test\win32\test-client-build.stamp.json'
        Covers = @(
            'test\win32\lib\TestClient.ps1',
            'test\win32\test-client-build.ps1'
        )
    },
    # The dashboard (T505): its detached server keeps serving whatever code it
    # was started with, so a page or server edit that broke the app stays "up"
    # and is only ever met by the user. Nothing in the P1-P3 floor touches it.
    # scripts\task-dashboard.ps1 (the pane launcher) is deliberately NOT
    # covered - it moves for pane/viewer reasons the HTTP harness cannot see.
    [pscustomobject]@{
        Name   = 'task-dashboard'
        Script = 'test\win32\task-dashboard.ps1'
        Stamp  = 'test\win32\task-dashboard.stamp.json'
        Covers = @(
            'scripts\task-dashboard.js',
            'scripts\task-dashboard.page.html',
            'test\win32\task-dashboard.ps1'
        )
    },
    # The acceptance-suite runner (T361). It is the one tool whose subject is
    # the other 241 scripts, so a regression in it does not fail loudly - it
    # mis-scores a sweep, and a wall of green is exactly what nobody re-reads.
    # Nothing in the P1-P3 floor touches it.
    [pscustomobject]@{
        Name   = 'suite-run'
        Script = 'test\win32\suite-run.ps1'
        Stamp  = 'test\win32\suite-run.stamp.json'
        Covers = @(
            'scripts\suite-run.ps1',
            'scripts\lib\Duration.ps1',
            'test\win32\suite-run.ps1',
            # T1098: the between-script modal sweep is the runner's, and section
            # M is the only thing that exercises it.
            'test\win32\lib\ModalSweep.ps1',
            # T1125: soak.ps1 is the one script that declares its own timeout,
            # and section N reads that declaration out of the shipping file. A
            # turn that changes soak's runtime and not its declaration is
            # exactly the regression that put it back to `stall`, so the
            # harness owes an answer whenever that file moves.
            'test\win32\soak.ps1'
        )
    },
    # The palette's "Focus: <pane>" jump entries (T555). The pure derivation
    # rides the none lane; this row ties the HARNESS to its own family only -
    # Surface.zig/IpcHandlers.zig move for a hundred non-palette reasons and
    # are the P1-P3 floor's problem, so gating this harness on them is noise.
    [pscustomobject]@{
        Name   = 'palette-jump'
        Script = 'test\win32\palette-jump.ps1'
        Stamp  = 'test\win32\palette-jump.stamp.json'
        Covers = @(
            'src\apprt\win32\palette_jump.zig',
            'test\win32\palette-jump.ps1'
        )
    },
    # The tab cwd tooltip (T447/T556/T557). Same shape as palette-jump: the
    # text derivation lives in tab_tooltip.zig (none-lane unit tested; this
    # harness scores it end-to-end at hover time), and the row ties the
    # harness to that family only - the show/theme plumbing sits in
    # Window.zig, which moves for a hundred non-tooltip reasons and is the
    # P1-P3 floor's problem, so gating this harness on it is noise.
    [pscustomobject]@{
        Name   = 'tab-tooltip'
        Script = 'test\win32\tab-tooltip.ps1'
        Stamp  = 'test\win32\tab-tooltip.stamp.json'
        Covers = @(
            'src\apprt\win32\tab_tooltip.zig',
            'test\win32\tab-tooltip.ps1'
        )
    },
    # The session-layout carry-forward (T590): the manifest's loss-prevention
    # arm only ever executes on a DEGRADED launch (agent unspawnable), which
    # no P1-P3 floor run produces, so an edit to the schema/merge module can
    # only be caught by this harness. Same shape as palette-jump: the row ties
    # the harness to its own family only - the restore/sync walk lives in
    # App.zig, which moves for a hundred non-layout reasons and is the floor's
    # problem, so gating this harness on it is noise.
    [pscustomobject]@{
        Name   = 'session-layout-preserve'
        Script = 'test\win32\session-layout-preserve.ps1'
        Stamp  = 'test\win32\session-layout-preserve.stamp.json'
        Covers = @(
            'src\apprt\win32\session_layout.zig',
            'test\win32\session-layout-preserve.ps1'
        )
    },
    # The deferred launch restore (T976): the retry only ever runs on a launch
    # that found NO agent within its spawn deadline, which no P1-P3 floor run
    # produces - the floor always reaches a healthy agent first. The row covers
    # the policy module and the agent-side entry point the tick dials through;
    # App.zig is deliberately NOT here (it moves for a hundred unrelated reasons
    # and would leave this multi-minute GUI run due every turn), so the residual
    # gap is App.zig's WIRING of the timer, which only a run of this catches.
    [pscustomobject]@{
        Name   = 'restore-late-agent'
        Script = 'test\win32\restore-late-agent.ps1'
        Stamp  = 'test\win32\restore-late-agent.stamp.json'
        Covers = @(
            'src\apprt\win32\restore_retry.zig',
            'src\apprt\win32\LocalAgent.zig',
            'test\win32\restore-late-agent.ps1'
        )
    },
    # The chooser's control LOCATOR (T294) and its Tab walk (T342) - the module
    # every other chooser script asks "which control is this", and the one place
    # that answer is checked against MachineChooser.zig's own ids. It went red
    # unnoticed for the fortnight between T547 adding a SHARE_ID and T342
    # running this script for another reason: nothing tied an id added to the
    # dialog to the harness table that mirrors it, which is precisely the drift
    # section A exists to catch. Coverage is the id-bearing half of the dialog
    # plus the module and its script; the run is short and opens one chooser.
    [pscustomobject]@{
        Name   = 'chooser-controls'
        Script = 'test\win32\chooser-controls.ps1'
        Stamp  = 'test\win32\chooser-controls.stamp.json'
        Covers = @(
            'src\apprt\win32\MachineChooser.zig',
            'test\win32\lib\ChooserControls.ps1',
            'test\win32\chooser-controls.ps1'
        )
    },
    # The chooser's session-list sort (T602): the headers are owner-drawn and
    # the order is asserted through log oracles only this harness reads - the
    # P1-P3 floor opens no chooser, so a sort/cursor regression is invisible to
    # it. The row covers the sort model and its persistence, not the whole
    # chooser (chooser-*.ps1 have their own runs).
    [pscustomobject]@{
        Name   = 'chooser-session-sort'
        Script = 'test\win32\chooser-session-sort.ps1'
        Stamp  = 'test\win32\chooser-session-sort.stamp.json'
        Covers = @(
            'src\apprt\win32\chooser_session_sort.zig',
            'test\win32\chooser-session-sort.ps1'
        )
    },
    # The chooser's session RESUME (T320/T620/T816): taking over a live session
    # that has no window is the machine chooser's reason to list sessions at
    # all, and no other harness drives it - the P1-P3 floor never opens the
    # chooser, and the sort harness above stops at the cursor. The row exists
    # because this one went red for eight days without anybody noticing: its
    # FIXTURE broke when launch-time restore grew a second source, so the run
    # exited SETUP FAIL having proved nothing about resume. Coverage is the
    # roster the cursor walks - the RPC/state/paint half (SessionRoster.zig) and
    # the pure row model whose connectable filter decides which rows render
    # (chooser_sessions.zig) - plus the harness itself. MachineChooser.zig is
    # deliberately NOT here: it hosts sixteen chooser features, moves about
    # daily, and gating a four-minute GUI run on it would make this due for
    # reasons that have nothing to do with resume (the same call the
    # session-layout-preserve row makes about App.zig).
    [pscustomobject]@{
        Name   = 'chooser-resume'
        Script = 'test\win32\chooser-resume.ps1'
        Stamp  = 'test\win32\chooser-resume.stamp.json'
        Covers = @(
            'src\apprt\win32\SessionRoster.zig',
            'src\apprt\win32\chooser_sessions.zig',
            'test\win32\chooser-resume.ps1',
            'test\win32\lib\ChooserCursor.ps1'
        )
    },
    # The chooser's session resume against a REMOTE machine (T331): the same
    # keystroke as the row above, on a machine reached over the relay. Separate
    # from `chooser-resume` because the two prove different halves - that one
    # ends at the local agent, this one is the ONLY thing on box that runs
    # `App.resumeRelaySession`, the `.remote` arm of `resumeRow`, and the ATTACH
    # shape of `openDialedWindow` (a resume must NOT send the machine's per-host
    # default cwd, because an attach does not spawn). Coverage is that open tail
    # and the per-host store it deliberately skips, plus the shared roster the
    # cursor walks and the harness itself. `MachineChooser.zig` is left out for
    # the reason the row above states.
    [pscustomobject]@{
        Name   = 'chooser-resume-remote'
        Script = 'test\win32\chooser-resume-remote.ps1'
        Stamp  = 'test\win32\chooser-resume-remote.stamp.json'
        Covers = @(
            'src\apprt\win32\SessionRoster.zig',
            'src\apprt\win32\chooser_sessions.zig',
            'src\apprt\win32\host_defaults.zig',
            'test\win32\chooser-resume-remote.ps1',
            'test\win32\lib\ChooserCursor.ps1'
        )
    },
    # The chooser's ORPHAN MARK (T520/T1106): the "not in any window" count and,
    # in its third section, the mark going AWAY when the row is resumed. Nothing
    # else asserts either half - the two resume rows above prove the resume and
    # never look at the mark, and the mark's oracle is a log line no floor lane
    # reads. The row exists because this harness sat `4 FAILURE(S)` in the
    # 242-script sweep with no guard obliging anyone to run it, and the failure
    # read as a broken attach when it was the harness walking the roster blind.
    # Coverage is the roster that both computes the count and hosts the cursor
    # (SessionRoster.zig), the pure row model behind what renders
    # (chooser_sessions.zig), the shared walk, and the harness itself.
    # MachineChooser.zig is left out for the reason the resume rows state.
    [pscustomobject]@{
        Name   = 'chooser-orphan-badge'
        Script = 'test\win32\chooser-orphan-badge.ps1'
        Stamp  = 'test\win32\chooser-orphan-badge.stamp.json'
        Covers = @(
            'src\apprt\win32\SessionRoster.zig',
            'src\apprt\win32\chooser_sessions.zig',
            'test\win32\chooser-orphan-badge.ps1',
            'test\win32\lib\ChooserCursor.ps1'
        )
    },
    # The chooser's ACCOUNT ROW (T316): the sign-in flow and the four
    # compositions the row takes (signed in / signing in / signed out /
    # unconfigured). No other harness drives it - the P1-P3 floor opens no
    # chooser, and the two rows above stop at the session list. The row exists
    # because this harness IS the only check on what the row says: T316 changed
    # the signed-out composition and every assertion that could have caught a
    # mistake lives here, in a script nothing obliged anyone to run. Coverage is
    # the row's own module (the pure label/status/monogram logic plus the async
    # sign-in it drives), the account state the CLI and the tray read the same
    # way, and the harness itself. MachineChooser.zig is deliberately NOT here
    # for the reason the chooser-resume row states: it hosts sixteen features
    # and moves about daily, and a GUI run gated on it would be due for reasons
    # this row cannot fail on.
    [pscustomobject]@{
        Name   = 'relay-account'
        Script = 'test\win32\relay-account.ps1'
        Stamp  = 'test\win32\relay-account.stamp.json'
        Covers = @(
            'src\apprt\win32\RelayAccountRow.zig',
            'src\remote\relay_signin.zig',
            'test\win32\relay-account.ps1'
        )
    },
    # The chooser's TEXT FIELD (T990), the sibling of the activity-monitor row
    # above: both harnesses exist because a fixed-size UTF-8 destination behind
    # a win32 EDIT is a crash with a threshold, and neither floor lane can see
    # it - the conversion only runs behind an HWND. Coverage is the bounded
    # conversion itself (`utf16_text.zig`, which every text field in the app now
    # goes through) plus the harness. MachineChooser.zig is deliberately NOT
    # here for the reason the chooser-resume row states: it hosts sixteen
    # features and moves about daily, and a four-minute GUI run gated on it
    # would be due for reasons this script cannot fail on.
    [pscustomobject]@{
        Name   = 'machine-chooser'
        Script = 'test\win32\machine-chooser.ps1'
        Stamp  = 'test\win32\machine-chooser.stamp.json'
        Covers = @(
            'src\apprt\win32\utf16_text.zig',
            'test\win32\machine-chooser.ps1'
        )
    },
    # The isolation meta-check (T680): the only thing that fails when a
    # test\win32 script drives the CLI with no private IPC endpoint - the
    # defect class that reads the user's own panes. Covering the whole top
    # level of the test tree is the point: the property must be re-proved
    # whenever ANY script changes, and the scan is static text, well under a
    # second, so the wide net costs nothing.
    [pscustomobject]@{
        Name   = 'isolation-meta'
        Script = 'test\win32\isolation-meta.ps1'
        Stamp  = 'test\win32\isolation-meta.stamp.json'
        Covers = @(
            'test\win32\*.ps1'
        )
    },
    # The launch pre-flight meta-check (T1033): the only thing that fails when
    # a test\win32 script LAUNCHES the app without asking whether the exe is a
    # debug build - i.e. whether it is about to open windows in the user's own
    # terminal and grade a binary nobody here built. Covers lib\ as well as the
    # top level, because the seam it exercises (Start-OnTestDesktop's own
    # pre-flight, which ~80 GUI scripts inherit) lives in lib\TestDesktop.ps1.
    # Static text plus a handful of stub calls, about a second.
    [pscustomobject]@{
        Name   = 'launch-preflight'
        Script = 'test\win32\launch-preflight-audit.ps1'
        Stamp  = 'test\win32\launch-preflight-audit.stamp.json'
        Covers = @(
            'test\win32\*.ps1',
            'test\win32\lib\*.ps1'
        )
    },
    # The verdict/exit meta-check (T221, given a guard by T963): a script that
    # PRINTS failure and EXITS 0 reports a red run to the loop as green. Its two
    # siblings above were guarded and this one was not, so it sat red at HEAD
    # until T883 happened to run it by hand - which is the exact question this
    # table answers, asked about the audit that answers it. Same wide net and
    # the same reason: the sweep reads every acceptance script, so a new script
    # (or a new verdict tail on an old one) must re-prove the property. lib\ is
    # covered because the analyzer lives there. AST over source, about a second.
    [pscustomobject]@{
        Name   = 'verdict-exit'
        Script = 'test\win32\verdict-exit-audit.ps1'
        Stamp  = 'test\win32\verdict-exit-audit.stamp.json'
        Covers = @(
            'test\win32\*.ps1',
            'test\win32\lib\*.ps1'
        )
    },
    # One shared kill for the app under test and its sibling agent (T351). T248
    # hoisted it and converted 19 scripts; three weeks later 133 scripts carried
    # a private copy again, four of them redefining the shared NAME so the copy
    # won inside the process. A sweep alone has already been tried, and the
    # regrowth is what a sweep alone buys. Same wide net as the audits above,
    # for the same reason: the property is about the corpus, so any new or
    # edited acceptance script must re-prove it. Static text over source, about
    # a second.
    [pscustomobject]@{
        Name   = 'cleanslate'
        Script = 'test\win32\cleanslate-audit.ps1'
        Stamp  = 'test\win32\cleanslate-audit.stamp.json'
        Covers = @(
            'test\win32\*.ps1',
            'test\win32\lib\*.ps1'
        )
    },
    # The host-dependent capture meta-check (T883): a merged stream formatted
    # through Out-String reads differently in every host - decorated and
    # wrapped where one can format, blank where none can - so a stderr-text
    # oracle can pass for the wrong reason or fail for a phantom one. 14 red
    # asserts in viewer-panes.ps1 hid behind that for months (T526), and the
    # split brain is the worst part: green when a human runs the script by
    # hand, blind in the loop. Same wide net as isolation-meta, for the same
    # reason - the property must be re-proved whenever ANY script changes, and
    # the scan is AST over source in about a second. lib\ IS covered here: one
    # of the 56 swept sites was in lib\BuildMode.ps1.
    [pscustomobject]@{
        Name   = 'stderr-capture'
        Script = 'test\win32\stderr-capture-audit.ps1'
        Stamp  = 'test\win32\stderr-capture-audit.stamp.json'
        Covers = @(
            'test\win32\*.ps1',
            'test\win32\lib\*.ps1',
            'docs\claude\testing.md'
        )
    },
    # The docs routing meta-check (T822): the pointers that make the
    # progressive-disclosure split navigable - the root routing table, every
    # `docs/claude/<file>.md` path cited in the tree, and every `<doc>
    # "<section>"` citation. The split shipped with two citations already
    # dangling at CLAUDE.md sections that had moved into a partition, and
    # nothing but a human reading validation criteria found them. Covering the
    # root and the whole partitions directory is the point: rename a heading or
    # a partition and the pointers at it must be re-proved. Static text, well
    # under a second.
    [pscustomobject]@{
        Name   = 'docs-routing'
        Script = 'test\win32\docs-routing.ps1'
        Stamp  = 'test\win32\docs-routing.stamp.json'
        Covers = @(
            'CLAUDE.md',
            'docs\claude\*.md',
            'test\win32\docs-routing.ps1'
        )
    },
    # The merge-terminology lint (T1097): "merge back" named three unrelated
    # operations - the cutover to `main`, an upstream pull FROM ghostty-org, and
    # upstreaming TO it (which never happens) - and reading one as another cost
    # a full round trip with the user twice in one day, plus a task filed on the
    # misreading. CLAUDE.md bans the bare phrase; this row is what keeps the ban
    # from decaying into a comment nobody checks. The net is wide on purpose:
    # the phrase can reappear in ANY doc, script or task file, so an edit to the
    # three disambiguating docs, to the tracker's live prose, or to the lint
    # itself must re-prove the tree. Static scan over tracked text, about a
    # second.
    [pscustomobject]@{
        Name   = 'merge-terminology'
        Script = 'test\win32\merge-terminology.ps1'
        Stamp  = 'test\win32\merge-terminology.stamp.json'
        Covers = @(
            'CLAUDE.md',
            'go.md',
            'docs\design\windows-parity-ship-workflow.md',
            'docs\design\windows-parity-upstream-pull-plan.md',
            'scripts\ship-readiness.ps1',
            'test\win32\merge-terminology.ps1'
        )
    },
    # The chooser's SELECTION TREATMENT (T828): the pixels a user reported as "a
    # loud purple pill with a thick purple outline". Coverage is the row model
    # that resolves the pill, the mark and the rim (chooser_rows.zig), the
    # painter that draws them (MachineChooser.zig's drawRow), the session card's
    # copy of the same treatment (chooser_sessions.zig / SessionRoster.zig) and
    # the harness. MachineChooser.zig IS here, unlike the chooser-resume row
    # above, because the defect lived in the painter: a model change that the
    # painter does not draw is exactly the hole this guard exists to close, and
    # the run is under a minute.
    [pscustomobject]@{
        Name   = 'chooser-selection'
        Script = 'test\win32\chooser-selection.ps1'
        Stamp  = 'test\win32\chooser-selection.stamp.json'
        Covers = @(
            'src\apprt\win32\list_selection.zig',
            'src\apprt\win32\chooser_rows.zig',
            'src\apprt\win32\chooser_sessions.zig',
            'src\apprt\win32\MachineChooser.zig',
            'src\apprt\win32\SessionRoster.zig',
            'test\win32\chooser-selection.ps1'
        )
    },
    # The PROCESS TABLE's selection treatment (T1008): the second list on this
    # platform, and the one that was still wearing the accent pill T828 retired
    # on the chooser. Coverage is the shared model both lists resolve their
    # colours from (list_selection.zig), the painter that draws them
    # (ActivityMonitor.zig's paintTable / paintTableFocus) and the harness.
    #
    # ActivityMonitor.zig is deliberately in TWO rows - here and in
    # 'activity-monitor' above - because the panel makes two separate claims and
    # neither harness can check the other's: activity-monitor drives the panel's
    # behavior and reads its log, and this one reads the pixels of one row. A
    # painter edit owes both, which is the honest answer; the alternative is a
    # hole exactly where T1008's defect lived.
    [pscustomobject]@{
        Name   = 'activity-selection'
        Script = 'test\win32\activity-selection.ps1'
        Stamp  = 'test\win32\activity-selection.stamp.json'
        Covers = @(
            'src\apprt\win32\list_selection.zig',
            'src\apprt\win32\ActivityMonitor.zig',
            'test\win32\activity-selection.ps1'
        )
    },
    # The Activity Monitor's DIALED path (T297) - the third row on
    # ActivityMonitor.zig, for the same reason there is a second: it is the only
    # harness that runs a dial at all. 'activity-monitor' drives a LOCAL panel
    # and 'activity-monitor-remote' a BORROWED one, so the code that owns a
    # transport - startDial, onDialed, adoptDial, and close's shutdown-then-join
    # - is reachable from neither. `relay_dial.zig` is covered because the dial
    # IS that call, and `lib\FakeRelay.ps1` because the whole success case
    # exists only through its bridge: a change to either can make this harness
    # pass over a path it never took.
    #
    # `activity_dial.zig` joined the list in T329, and its absence until then is
    # the failure mode this table exists to prevent: T299 MOVED startDial /
    # onDialed / adoptDial / teardownSource out of `ActivityMonitor.zig` into a
    # file of their own, and the row that named those four functions in its own
    # comment kept pointing at the file they had left. An edit to the connection
    # plane made nothing due.
    [pscustomobject]@{
        Name   = 'activity-monitor-dialed'
        Script = 'test\win32\activity-monitor-dialed.ps1'
        Stamp  = 'test\win32\activity-monitor-dialed.stamp.json'
        Covers = @(
            'src\apprt\win32\ActivityMonitor.zig',
            'src\apprt\win32\activity_dial.zig',
            'src\remote\relay_dial.zig',
            'test\win32\lib\FakeRelay.ps1',
            'test\win32\activity-monitor-dialed.ps1'
        )
    },
    # The shared test-desktop library itself (T303). lib\TestDesktop.ps1 is what
    # every GUI acceptance script in this suite stands on - the desktop, the
    # input, the capture and the capture's GUARDS - and until now nothing
    # obliged anyone to run its acceptance after editing it, which is this
    # table's whole subject asked about its own foundation. A guard that grew
    # teeth here (T214's class refusal, T303's uniform refusal) is precisely
    # what a silent edit could file back down: both refuse a capture, and a
    # refusal that stops firing turns green without turning red first. About
    # two minutes, off the input desktop.
    [pscustomobject]@{
        Name   = 'test-desktop'
        Script = 'test\win32\test-desktop-harness.ps1'
        Stamp  = 'test\win32\test-desktop-harness.stamp.json'
        Covers = @(
            'test\win32\lib\TestDesktop.ps1',
            'test\win32\test-desktop-harness.ps1'
        )
    },
    # The build-mode gate itself (T350, tightened by T1158). BuildMode.ps1 was
    # only ever covered by the build-fresh row above, whose script grades the
    # FRESHNESS half - so the gate's own harness, build-mode-guard.ps1, had no
    # row and an edit to the refusal logic pointed nobody at it. That is not
    # theoretical: T1158 is a defect in exactly this file, where `-Allow`
    # returned unconditionally and a release-lineage soak seeded the user's
    # agent with sessions nothing could reap. Isolation.ps1 rides along because
    # it is where the three knobs are now set in one call, and the gate's whole
    # question is whether they were. Non-interactive, launches nothing (release
    # builds are played by stub exes), a few seconds.
    [pscustomobject]@{
        Name   = 'build-mode'
        Script = 'test\win32\build-mode-guard.ps1'
        Stamp  = 'test\win32\build-mode-guard.stamp.json'
        Covers = @(
            'test\win32\lib\BuildMode.ps1',
            'test\win32\lib\Isolation.ps1',
            'test\win32\build-mode-guard.ps1'
        )
    },
    # The freshness half of the pre-flight (T1028), and the most self-referential
    # row in this table: lib\BuildFresh.ps1 is what stops a green run STAMPING a
    # row here about an exe that was never built from the code it graded. It sits
    # in front of all 49 scripts that call Assert-GhozttyIsolatedBuild, so an
    # edit that quietly stops it refusing would turn every other stamp into a
    # claim nobody checked. Non-interactive, launches nothing, a few seconds.
    [pscustomobject]@{
        Name   = 'build-fresh'
        Script = 'test\win32\build-fresh-guard.ps1'
        Stamp  = 'test\win32\build-fresh-guard.stamp.json'
        Covers = @(
            'test\win32\lib\BuildFresh.ps1',
            'test\win32\lib\BuildMode.ps1',
            'test\win32\build-fresh-guard.ps1'
        )
    },
    # The build-cache sweeper and the floor lane's disk pre-flight (T1054). The
    # thing being protected is a diagnosis, not a feature: when the drive is
    # full zig fails in five seconds with a bare `error: Unexpected` and names
    # nothing, so a regression here does not look like a regression - it looks
    # like the code being red, which is what cost a turn its whole context on
    # 2026-08-21. Neither floor lane nor P1-P3 exercises the sweeper, and the
    # `sweep` path in particular DELETES, so it must not be able to drift
    # unwatched. Non-interactive, launches nothing, a few seconds.
    [pscustomobject]@{
        Name   = 'build-cache'
        Script = 'test\win32\build-cache.ps1'
        Stamp  = 'test\win32\build-cache.stamp.json'
        Covers = @(
            'scripts\lib\BuildCache.ps1',
            'scripts\build-cache.ps1',
            'test\win32\build-cache.ps1'
        )
    },
    # The resize paint path (T1031). `resize_paint.zig` is the rule that says a
    # pane which already holds pixels must NOT blank itself ahead of the GL
    # frame, and the acceptance script asks a live pane that same question
    # through a DC it owns. Neither the floor lanes nor P1-P3 look at it: the
    # unit tests prove the rule, and nothing else proves the rule is still
    # WIRED to the window. The failure mode is the quiet one - the app goes
    # back to flashing background on every resize frame and every test stays
    # green, because a flicker is a timing artifact no other assertion can see.
    # Deliberately NARROW: Window.zig / App.zig / Surface.zig move for a
    # hundred unrelated reasons and would make this row due every other turn,
    # which is how a coverage table trains people to reach for -NoGuardDue.
    # About a minute, off the input desktop.
    [pscustomobject]@{
        Name   = 'resize-flicker'
        Script = 'test\win32\resize-flicker.ps1'
        Stamp  = 'test\win32\resize-flicker.stamp.json'
        Covers = @(
            'src\apprt\win32\resize_paint.zig',
            'test\win32\resize-flicker.ps1'
        )
    },
    # The leak teardown (T199, T1127). `lib\HarnessLeak.ps1` is the only thing
    # standing between a harness that dies mid-run and a live app left on the
    # box, and since T1127 it is also what stops the ordinary scripts leaking
    # the agent's `--pty-host` holders - a leak that is invisible to the script
    # causing it and surfaces as a failure in whichever script runs NEXT. No
    # lane touches it and P1-P3 does not either: it is harness plumbing, so the
    # only thing that ever exercises it is its own acceptance. About a minute,
    # off the input desktop.
    [pscustomobject]@{
        Name   = 'harness-leak'
        Script = 'test\win32\harness-process-leak.ps1'
        Stamp  = 'test\win32\harness-process-leak.stamp.json'
        Covers = @(
            'test\win32\lib\HarnessLeak.ps1',
            'test\win32\harness-process-leak.ps1'
        )
    },
    # The honesty of every OTHER row in this table (T1039). A harness whose body
    # unwinds mid-run used to print ALL PASS and then STAMP - recording every
    # file it covers as freshly proven while a whole section measured nothing -
    # so a guard could go quiet over code nobody had tested. The scorer's
    # completion marker and the `update` refusal above are what stop that, and
    # this row is what notices when either one stops working. It covers
    # `scripts\guard-due.ps1` itself, unlike every other row: a new harness row
    # landing here makes this one due, which is a few seconds of a non-GUI
    # script, and the alternative is leaving the stamp gate as the one piece of
    # this machinery nothing re-checks.
    [pscustomobject]@{
        Name   = 'body-complete'
        Script = 'test\win32\body-complete-audit.ps1'
        Stamp  = 'test\win32\body-complete-audit.stamp.json'
        Covers = @(
            'test\win32\body-complete-audit.ps1',
            'test\win32\lib\BodyCompleteAudit.ps1',
            'test\win32\lib\TestScore.ps1',
            'scripts\guard-due.ps1'
        )
    }
)

function Get-RepoRelative([string]$full) {
    $rel = $full.Substring($Repo.Length).TrimStart('\', '/')
    return $rel.Replace('\', '/')
}

function Get-CoveredFiles($row) {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $row.Covers) {
        $full = Join-Path $Repo $pattern
        foreach ($f in @(Get-ChildItem -Path $full -File -ErrorAction SilentlyContinue)) {
            $rel = Get-RepoRelative $f.FullName
            if (-not $found.Contains($rel)) { $found.Add($rel) | Out-Null }
        }
    }
    # Ordinal sort so the stamp's key order is the same on every box.
    return @($found.ToArray() | Sort-Object -CaseSensitive)
}

function Get-NormalizedHash([string]$relPath) {
    <#
      SHA-256 of the file's bytes with CRLF folded to LF and any UTF-8 BOM
      dropped. .ps1 carries no `text` attribute in .gitattributes, so the bytes
      on disk depend on the checkout's line-ending settings; hashing them raw
      would report every file as changed on a differently-configured clone, and
      a gate that cries wolf on a fresh clone is a gate nobody reads.
    #>
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Repo $relPath))
    $out = New-Object System.Collections.Generic.List[byte]
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0D -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 0x0A) { continue }
        $out.Add($bytes[$i])
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($out.ToArray())
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
}

function Get-LiveMap($row) {
    $map = [ordered]@{}
    foreach ($rel in (Get-CoveredFiles $row)) { $map[$rel] = Get-NormalizedHash $rel }
    return $map
}

function Read-Stamp($row) {
    $path = Join-Path $Repo $row.Stamp
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Get-StampMap($stamp) {
    $map = [ordered]@{}
    if ($null -eq $stamp -or $null -eq $stamp.files) { return $map }
    foreach ($p in $stamp.files.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    return $map
}

function Get-GuardState($row) {
    <#
      The whole decision, as data: Kind ('current' | 'due'), Findings (one per
      file that moved), plus what the stamp said. Pure apart from reading files,
      so `check`, `-Json` and the acceptance script all read the same answer.
    #>
    $live = Get-LiveMap $row
    $stamp = Read-Stamp $row
    $stamped = Get-StampMap $stamp

    # A row whose coverage matches NO file in this tree is not applicable here:
    # there is nothing that could have changed, so it cannot be due. That is the
    # normal case whenever the gate is pointed at a foreign tree -- which is
    # exactly what this gate's own acceptance script does, with a fixture repo
    # shaped like ONE row. Without this, adding a second row to the table made
    # eight of its arms fail over an exit code that had nothing to do with them,
    # and every future row would do it again.
    #
    # It is reported, never silent: a row whose globs are a typo says so as
    # `GUARD N/A`, which is a different sentence from `GUARD CURRENT` and cannot
    # be mistaken for one.
    if ($live.Count -eq 0 -and $null -eq $stamp) {
        return [pscustomobject]@{
            Name = $row.Name; Script = $row.Script; RunArgs = [string]$row.RunArgs; Stamp = $row.Stamp
            Kind = 'n/a'; Reason = 'no-covered-files'; Findings = @()
            Files = @(); StampedAt = ''; StampedCommit = ''
        }
    }
    # A plain array, not a generic List: PowerShell 5.1's enumerable binder
    # throws "Argument types do not match" on @(<empty List[object]>), which is
    # exactly the CURRENT case - the one this gate reports most often.
    $findings = @()

    if ($null -eq $stamp) {
        return [pscustomobject]@{
            Name = $row.Name; Script = $row.Script; RunArgs = [string]$row.RunArgs; Stamp = $row.Stamp
            Kind = 'due'; Reason = 'no-stamp'; Findings = @()
            Files = @($live.Keys); StampedAt = ''; StampedCommit = ''
        }
    }

    foreach ($rel in $live.Keys) {
        if (-not $stamped.Contains($rel)) {
            $findings += [pscustomobject]@{ Kind = 'new'; Path = $rel }
        } elseif ($stamped[$rel] -ne $live[$rel]) {
            $findings += [pscustomobject]@{ Kind = 'changed'; Path = $rel }
        }
    }
    foreach ($rel in @($stamped.Keys)) {
        if (-not $live.Contains($rel)) {
            $findings += [pscustomobject]@{ Kind = 'removed'; Path = $rel }
        }
    }

    $kind = if ($findings.Count -gt 0) { 'due' } else { 'current' }
    $reason = if ($findings.Count -gt 0) { 'covered-files-changed' } else { '' }
    return [pscustomobject]@{
        Name = $row.Name; Script = $row.Script; RunArgs = [string]$row.RunArgs; Stamp = $row.Stamp
        Kind = $kind; Reason = $reason; Findings = $findings
        Files = @($live.Keys)
        StampedAt = [string]$stamp.generated
        StampedCommit = [string]$stamp.commit
    }
}

function Write-Stamp($row) {
    <#
      Rewrite the stamp only when the file MAP actually moved. A green harness
      run that changed nothing must leave a clean working tree behind it -
      otherwise every run of the harness produces a diff, and a diff nobody
      means is a diff nobody reads.
    #>
    $live = Get-LiveMap $row
    $existing = Get-StampMap (Read-Stamp $row)
    $same = ($existing.Count -eq $live.Count)
    if ($same) {
        foreach ($k in $live.Keys) {
            if (-not $existing.Contains($k) -or $existing[$k] -ne $live[$k]) { $same = $false; break }
        }
    }
    if ($same) { return [pscustomobject]@{ Written = $false; Files = @($live.Keys) } }

    $commit = ''
    try { $commit = (& git -C $Repo rev-parse --short HEAD 2>$null | Out-String).Trim() } catch { $commit = '' }

    $files = [ordered]@{}
    foreach ($k in $live.Keys) { $files[$k] = $live[$k] }
    $doc = [ordered]@{
        guard     = $row.Name
        script    = $row.Script.Replace('\', '/')
        generated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        commit    = $commit
        files     = $files
    }
    $json = ($doc | ConvertTo-Json -Depth 5)
    $path = Join-Path $Repo $row.Stamp
    # UTF-8 without a BOM, LF endings: *.json is `text eol=lf` in .gitattributes.
    [System.IO.File]::WriteAllText($path, ($json -replace "`r`n", "`n") + "`n",
        (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Written = $true; Files = @($live.Keys) }
}

$rows = @($GuardTable)
if ($Guard) {
    $rows = @($GuardTable | Where-Object { $_.Name -eq $Guard })
    if ($rows.Count -eq 0) {
        Write-Host ("ERROR unknown guard '{0}' (known: {1})" -f $Guard, (($GuardTable | ForEach-Object { $_.Name }) -join ', '))
        exit 2
    }
}

switch ($Action) {

    'list' {
        foreach ($row in $rows) {
            "{0}  {1}" -f $row.Name, $row.Script
            foreach ($rel in (Get-CoveredFiles $row)) { "    $rel" }
        }
        exit 0
    }

    'update' {
        # T1039. A stamp says "this harness was run against exactly this code",
        # and it is the half that OUTLIVES the run: a red line scrolls away, a
        # stamp keeps the guard quiet until the files change again. A harness
        # whose body unwound measured nothing past the throw, so it has no
        # business recording anything as proven - and it reaches here anyway,
        # because the stamp block sits between the `finally` and the verdict.
        #
        # `lib\TestScore.ps1` publishes the run's state in the environment and
        # this is a CHILD PROCESS of the harness, so it inherits it: `pending`
        # means armed-and-not-finished. Anything else - `complete`, or unset for
        # a caller that is not a scored run at all (a hand `update`, a script
        # that does not use the shared scorer) - stamps exactly as before.
        if ($env:GHOZTTY_TEST_BODY -eq 'pending') {
            if (-not $IgnoreRunState) {
                "STAMP REFUSED: the calling run has not reached the end of its body (GHOZTTY_TEST_BODY=pending)."
                "  Nothing was stamped, so this guard stays due - which is the correct answer for a run that did not finish."
                exit 3
            }
            "STAMP RUN-STATE IGNORED: -IgnoreRunState was passed over an unfinished run."
        }
        $wrote = 0
        foreach ($row in $rows) {
            $r = Write-Stamp $row
            if ($r.Written) {
                "STAMPED {0} ({1} files) -> {2}" -f $row.Name, @($r.Files).Count, $row.Stamp
                $wrote++
            } else {
                "STAMP UNCHANGED {0} ({1} files)" -f $row.Name, @($r.Files).Count
            }
        }
        exit 0
    }

    'check' {
        $states = @(foreach ($row in $rows) { Get-GuardState $row })
        if ($Json) {
            # An array, always - a single-row table must not collapse to an object.
            ConvertTo-Json -Depth 6 -InputObject @($states)
            exit ([int](@($states | Where-Object { $_.Kind -eq 'due' }).Count -gt 0))
        }
        $due = 0
        foreach ($s in $states) {
            if ($s.Kind -eq 'n/a') {
                "GUARD N/A {0}: nothing in this tree matches its coverage" -f $s.Name
                continue
            }
            if ($s.Kind -eq 'current') {
                $stampedAt = if ($s.StampedAt) { $s.StampedAt.Substring(0, [Math]::Min(10, $s.StampedAt.Length)) } else { '?' }
                "GUARD CURRENT {0} ({1} files, stamped {2}{3})" -f $s.Name, @($s.Files).Count, $stampedAt,
                    $(if ($s.StampedCommit) { " from $($s.StampedCommit)" } else { '' })
                continue
            }
            $due++
            if ($s.Reason -eq 'no-stamp') {
                "GUARD DUE {0}: no stamp - {1} has never recorded a green run over this code" -f $s.Name, $s.Script
            } else {
                "GUARD DUE {0}: {1} has not been run since these changed:" -f $s.Name, $s.Script
                foreach ($f in $s.Findings) { "    {0,-8} {1}" -f $f.Kind, $f.Path }
            }
            # RunArgs is how a row says "this harness needs more than its bare
            # name to clear ME" - the packaging row wants -RequireDocker, which
            # turns the Docker skips into failures so a run that cannot clear it
            # says so instead of reporting ALL PASS and leaving it due.
            "  run: powershell -NoProfile -File {0}{1}" -f $s.Script,
                $(if ($s.RunArgs) { " $($s.RunArgs)" } else { '' })
        }
        exit ([int]($due -gt 0))
    }
}
