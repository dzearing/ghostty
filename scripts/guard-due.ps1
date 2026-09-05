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

  ADVISORY ROWS (T1189). A row may declare `Advisory = $true`, which means it
  is REPORTED everywhere a blocking row is and never counted against the
  validate gate. That is not a softer version of the same claim - it is for the
  one shape this mechanism otherwise handles badly: a question this box is
  physically unable to answer (the MSI compile needs Linux tooling and
  therefore Docker, which is deliberately kept down here), whose real
  enforcement lives elsewhere (fork-ci compiles the package on every push and
  `validate` fails on a red CI verdict). Before it, that row was due after every
  packaging edit and the only way past the gate was `-NoGuardDue` on every
  commit; a hatch pressed every time stops being a signal, and it hid the case
  the hatch exists for. An advisory row still says `GUARD DUE (advisory)` until
  it is cleared, so nothing goes quiet.

  CLEARED FROM CI (T1189). A row may declare `CiEvidence` - a workflow and a
  job whose green run over a commit proves what the harness would have proved
  locally. `stamp-ci` finds a successful run of that job, checks that every
  covered file AT THAT RUN'S COMMIT hashes the same as the file on disk now, and
  only then writes the stamp (recording the run url and sha as its provenance).
  A stamp written from a run whose tree differed would be the exact lie this
  whole mechanism exists to prevent, so the content check is not optional and
  there is no hatch past it.

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
    [ValidateSet('check', 'update', 'list', 'stamp-ci')]
    [string]$Action = 'check',

    # Limit to one harness by name. Omitted => every row in the table.
    [string]$Guard,

    [string]$Repo,
    [switch]$Json,

    # --- stamp-ci only (T1189) --------------------------------------------
    # The GitHub repository to ask. NEVER let `gh` resolve this itself: this
    # repo has `upstream` (ghostty-org/ghostty) as a remote and a bare gh
    # command resolves to it (go.md, step 6.9).
    [string]$Nwo = 'dzearing/ghoztty',

    # The branch whose runs are enumerated. Defaults to the repo's current one.
    [string]$Branch,

    # Read the run list from a file instead of calling gh, in the shape
    # `gh run list --json ...` returns (each run may carry its own `jobs`
    # array, as `gh run view --json jobs` returns them). This is how the
    # acceptance harness constructs green and red CI without a build machine:
    # the eligibility rules are the script's own, only the transport is
    # replaced. Also settable as GHOZTTY_GUARD_CI_RUNS_JSON.
    [string]$RunsJsonFile,

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
#
# Every pattern here must MATCH SOMETHING in this repo (T1227). One that does
# not is not an error you will see: it contributes no files and the row goes on
# reporting CURRENT over the ones that are left, so the guard quietly watches
# less code than it claims to. `check` audits the table for that before it
# reports any verdict; move a file and its entry moves with it.
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
    # The cleanup screen (T1188). It DELETES things on the user's primary
    # machine on the strength of a classification it makes itself, and the two
    # behaviours that keep that safe - the ghost-registration refusal and
    # per-item confirmation - are invisible when broken: a screen that offered
    # `msiexec /x` on {A10466B5-...} would look completely normal right up to
    # the moment it deleted the live install, and an "are you sure" that ignores
    # the answer produces a run that reads as successful. Nothing in the P1-P3
    # floor launches it, so this row is what ties an edit to its harness.
    [pscustomobject]@{
        Name   = 'ghoztty-cleanup'
        Script = 'test\win32\ghoztty-cleanup.ps1'
        Stamp  = 'test\win32\ghoztty-cleanup.stamp.json'
        Covers = @(
            'test\win32\ghoztty-cleanup.ps1',
            'scripts\ghoztty-cleanup.ps1'
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
            'src\apprt\win32\source_checkout.zig',
            'src\os\source_checkout.zig',
            'src\apprt\ipc\url_scheme.zig'
        )
    },
    # The REGISTRATION CLASS (T1151): every write a build makes outside its own
    # checkout and state dir - the ghoztty:// handler, the agent Run key, the
    # user PATH, the home hook scripts, the standalone-MSI adoption - and the
    # inventory that names them. The per-site harnesses each prove ONE gate;
    # this one proves the SET is complete, so a new registration added without a
    # gate goes red instead of waiting for a third incident (T1124, T1146).
    [pscustomobject]@{
        Name   = 'registration-sites'
        Script = 'test\win32\registration-sites.ps1'
        Stamp  = 'test\win32\registration-sites.stamp.json'
        Covers = @(
            'test\win32\registration-sites.ps1',
            'docs\design\windows-registration-sites.md',
            'src\os\source_checkout.zig',
            'src\apprt\win32\source_checkout.zig',
            'src\apprt\win32\url_scheme.zig',
            'src\apprt\win32\LocalAgent.zig',
            'src\apprt\win32\PathInstaller.zig',
            'src\apprt\win32\AgentIntegration.zig',
            'src\remote\agent\adopt.zig'
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
    # The viewer's ERROR CARD (T381): the only thing that photographs the card a
    # viewer paints when there is no WebView2 runtime. The unit lane proves the
    # layout module's arithmetic and cannot see a pixel; this box HAS the
    # runtime, so nothing else here ever takes that branch at all. Covers the
    # painter, the geometry module, the failure strings it renders, and the
    # shared measurement lib the probe reads pixels through.
    [pscustomobject]@{
        Name   = 'viewer-error-card'
        Script = 'test\win32\viewer-error-card.ps1'
        Stamp  = 'test\win32\viewer-error-card.stamp.json'
        Covers = @(
            'test\win32\viewer-error-card.ps1',
            'test\win32\lib\ColorMath.ps1',
            'src\apprt\win32\viewer_error_card.zig'
        )
    },
    # Closing a viewer, and the window around one (T1356): the only thing that
    # closes a window holding a viewer pane and then keeps asserting. Every
    # other viewer harness opens viewers and lets the desktop teardown reap the
    # process, so the teardown ORDER - a WebView2 `Close` pumping messages into
    # a window whose tree is mid-free - had no coverage at all, and the one
    # script that stumbled on the crash was edited to stop closing. Covers the
    # window teardown sites and the sweep the pump re-entered.
    [pscustomobject]@{
        Name   = 'viewer-close'
        Script = 'test\win32\viewer-close.ps1'
        Stamp  = 'test\win32\viewer-close.stamp.json'
        Covers = @(
            'test\win32\viewer-close.ps1',
            'src\apprt\win32\Window.zig',
            'src\apprt\win32\PaneView.zig',
            'src\apprt\win32\ViewerPane.zig'
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
    # The diff pane's file tree (T464): the only thing that proves the tree the
    # `none` lane builds ever reaches a card. The pure module asserts the
    # nesting, the chain collapsing and the sections exhaustively and cannot
    # see whether a row was drawn, whether clicking one opened a file, or
    # whether the card switched from listing headings to listing files. Covers
    # the transform, the card that paints it, and the pane that owns which of
    # the two subjects it is showing.
    [pscustomobject]@{
        Name   = 'viewer-diff-tree'
        Script = 'test\win32\viewer-diff-tree.ps1'
        Stamp  = 'test\win32\viewer-diff-tree.stamp.json'
        Covers = @(
            'test\win32\viewer-diff-tree.ps1',
            'src\apprt\win32\viewer_file_tree.zig',
            'src\apprt\win32\ViewerTOCPanel.zig'
        )
    },
    # Image panes (T1183): the only thing that proves the zoom rules reach a
    # real picture. The none lane asserts the arithmetic exhaustively and
    # cannot see whether the number ever left the process - the whole feature
    # is a page, a served file and a bridge, none of which a unit test crosses.
    # Covers the rules, the page that draws them, and both halves of the bridge
    # between them.
    [pscustomobject]@{
        Name   = 'viewer-image'
        Script = 'test\win32\viewer-image.ps1'
        Stamp  = 'test\win32\viewer-image.stamp.json'
        Covers = @(
            'test\win32\viewer-image.ps1',
            'src\apprt\win32\viewer_image.zig',
            'src\viewer\image.js',
            'src\viewer\viewer.js'
        )
    },
    # Find-in-page (T1184): the search is shared JavaScript and the card is a
    # native window, so what nothing else can check is that the two agree — a
    # chord posted into the page reaching the card, and the card's query
    # reaching the page's counter. Covers the engine, the pure half, the card,
    # and the pane that carries messages between them.
    [pscustomobject]@{
        Name   = 'viewer-find'
        Script = 'test\win32\viewer-find.ps1'
        Stamp  = 'test\win32\viewer-find.stamp.json'
        Covers = @(
            'test\win32\viewer-find.ps1',
            'src\viewer\find.js',
            'src\apprt\win32\viewer_find.zig',
            'src\apprt\win32\ViewerFindBar.zig',
            'src\apprt\win32\viewer_accel.zig'
        )
    },
    # The viewer nav bar's PRESENCE (T1131, finished by T1185): every viewer
    # flavor keeps its address bar on screen, in every mode, with no hover
    # anywhere in the path. The unit lanes assert the band arithmetic; only
    # this script proves that a real `+split --view=` pane comes up with the
    # bar shown and reserving its band instead of covering the page. Covers the
    # pane that insets the content, the module that sizes the band, and the bar
    # itself - which is the window whose visibility is being measured.
    [pscustomobject]@{
        Name   = 'viewer-nav-pin'
        Script = 'test\win32\viewer-nav-pin.ps1'
        Stamp  = 'test\win32\viewer-nav-pin.stamp.json'
        Covers = @(
            'test\win32\viewer-nav-pin.ps1',
            'src\apprt\win32\viewer_nav_layout.zig',
            'src\apprt\win32\ViewerPane.zig',
            'src\apprt\win32\ViewerNavBar.zig'
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
            'src\apprt\win32\source_checkout.zig',
            'src\os\source_checkout.zig',
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
    # VANISHED sessions (T1162): the reaper's process-table sweep, the only thing
    # that notices a persistent session whose shell exited with nothing reading
    # it. Both directions are the point and neither is visible to a unit test on
    # a synthetic map: a dead session must stop being offered, and a LIVE one
    # must survive every sweep. A regression either way is silent - one leaks
    # unusable sessions forever, the other kills panes the user is still using.
    [pscustomobject]@{
        Name   = 'session-vanished'
        Script = 'test\win32\session-vanished.ps1'
        Stamp  = 'test\win32\session-vanished.stamp.json'
        Covers = @(
            'test\win32\session-vanished.ps1',
            'src\remote\agent\session.zig',
            'src\remote\agent\proc.zig',
            'src\remote\agent\descendants.zig'
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
    # The INSTALL-OWNERSHIP rule (T1218, decision D85): nothing in this repo may
    # replace the user's installed Ghoztty - only the in-app updater, and only
    # with a published release. The rule lives in one dot-sourced file and is
    # enforced at two call sites, none of which any lane or P1-P3 script touches,
    # and the failure it prevents is silent by construction: the swap succeeds,
    # the terminal keeps working, and the version it reports describes bytes
    # nobody ever released. This row replaced `morning-refresh`, whose harness was
    # retired along with the morning swap it guarded.
    [pscustomobject]@{
        Name   = 'install-ownership'
        Script = 'test\win32\install-ownership.ps1'
        Stamp  = 'test\win32\install-ownership.stamp.json'
        Covers = @(
            'scripts\install-ownership.ps1',
            'scripts\upgrade-ghoztty-windows.ps1',
            'scripts\launch-upgrade.ps1',
            'test\win32\install-ownership.ps1'
        )
    },
    # The OTHER half of D85 (T1220): the daily publish is now the only way the
    # day's work reaches the user's terminal, and every part of it fails quietly.
    # A due decision that goes shy ships nothing and looks identical to a quiet
    # day; a version scheme that walks the wrong axis is only visible weeks
    # later; a skip that became a failure stalls the loop. Nothing in the lanes
    # or the P1-P3 floor touches any of it. This row is the replacement for
    # `morning-refresh`'s, which retired with the swap it guarded.
    [pscustomobject]@{
        Name   = 'daily-publish'
        Script = 'test\win32\daily-publish.ps1'
        Stamp  = 'test\win32\daily-publish.stamp.json'
        Covers = @(
            'scripts\daily-publish.ps1',
            'scripts\publish-windows-release.ps1',
            'scripts\publish-windows-tag.ps1',
            'test\win32\daily-publish.ps1'
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
            'dist\windows-installer\sign-artifacts.sh',
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
    #
    # ADVISORY since T1189, and that word is doing real work. The question this
    # row asks - does the package still COMPILE? - cannot be answered on this
    # box at all: wixl is Linux tooling, Docker is deliberately kept down here
    # (a WSL2 backend that has buried the machine before), and starting it is
    # the user's call. So the row was due after every build-msi.sh edit and the
    # only way past the pre-commit gate was `validate -NoGuardDue` - an override
    # pressed every time, which is indistinguishable from the misuse that hatch
    # exists to make visible. A blocking gate with only one possible answer is
    # not a gate.
    #
    # What still holds build-msi.sh to account, so this is a de-escalation and
    # not a hole:
    #   * the `install-launch` row below covers the same file and IS blocking -
    #     it is cleared by a Docker-less run, so a build-msi.sh edit still has
    #     to produce evidence before it can be committed;
    #   * sections B5-B7 of this same harness parse the generated WXS without
    #     Docker, which is T1218's whole defect class;
    #   * fork-ci's `windows-cross` job COMPILES the MSI on every push, and
    #     `parity-tasks.ps1 validate` already FAILS on a red CI verdict (T1219),
    #     so the compile is enforced by the machine that can actually answer it,
    #     one turn later, rather than by a stamp nothing here can write.
    #
    # This row is what reports whether that answer has been READ: printed by
    # every claim, never counted against validate, and cleared either by a local
    # Docker run (exactly as before) or from the green CI run that proved it -
    #
    #   powershell -NoProfile -File scripts\guard-due.ps1 stamp-ci -Guard release-artifacts-packaging
    #
    # which stamps only when the covered files at that run's commit are byte for
    # byte what is on disk now (see `CiEvidence` and the `stamp-ci` action).
    [pscustomobject]@{
        Name       = 'release-artifacts-packaging'
        Script     = 'test\win32\release-artifacts.ps1'
        RunArgs    = '-RequireDocker'
        Stamp      = 'test\win32\release-artifacts-packaging.stamp.json'
        Advisory   = $true
        CiEvidence = [pscustomobject]@{ Workflow = 'Fork CI'; Job = 'windows-cross' }
        Covers     = @(
            'dist\windows-installer\build-msi.sh'
        )
    },
    # Remote Desktop, for real (T1253). This is the second shape of the row
    # above: a question this box is PHYSICALLY unable to answer, whose answer
    # matters anyway. Windows 11 Pro serves one interactive session at a time,
    # so an RDP connection from anywhere - localhost included - disconnects the
    # console rather than joining it; getting a remote session takes a second
    # machine and a person on it. Unlike `release-artifacts-packaging` there is
    # no `CiEvidence` to lean on either: a GitHub runner has no RDP session
    # either, and the whole point of T1253 is that the environment, not the
    # code path, is the subject. `GHOZTTY_GL_FORCE_VERSION` proves the path.
    #
    # So this row is a standing REMINDER with a narrow trigger: an edit to the
    # two files that decide which OpenGL implementation a remote session ends
    # up on makes the recorded RDP evidence stale, and says so at every claim,
    # until somebody re-runs it from a remote session. `Surface.zig` is
    # deliberately NOT covered - it is edited constantly for reasons that have
    # nothing to do with GL selection, and a row that is always due is a row
    # nobody reads.
    [pscustomobject]@{
        Name     = 'rdp-session'
        Script   = 'test\win32\rdp-session.ps1'
        Stamp    = 'test\win32\rdp-session.stamp.json'
        Advisory = $true
        Covers   = @(
            'src\renderer\gl_loader.zig',
            'src\renderer\gl_report.zig',
            'test\win32\rdp-session.ps1'
        )
    },
    # The shared log sink (T270, T410). `%LOCALAPPDATA%\ghoztty\ghoztty.log` is
    # the only diagnostic surface a release build leaves behind, and its two
    # contracts - every line carries a timestamp and a pid inside ONE write, and
    # the file is bounded to two generations - are measured by nothing in the
    # P1-P3 floor. They cannot be: the sink is compiled out of Debug builds, so
    # the only thing that can answer is an acceptance run against a release exe.
    #
    # `src\main_ghostty.zig` is deliberately NOT covered, on the `Surface.zig`
    # argument above: it holds the ~25-line call site, and it is edited most
    # weeks for startup reasons that cannot reach the sink, while the logic that
    # decides line SHAPE and the size BOUND is entirely in the two modules
    # below. A row that is due after every unrelated startup edit is a row
    # nobody reads - and it would charge each of those edits a ReleaseFast
    # build, which is what running this harness costs.
    [pscustomobject]@{
        Name   = 'log-sink'
        Script = 'test\win32\log-append.ps1'
        Stamp  = 'test\win32\log-sink.stamp.json'
        Covers = @(
            'src\os\log_stamp.zig',
            'src\os\log_rotate.zig',
            'test\win32\log-append.ps1'
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
            '.claude\commands\release.md',
            # Section C reads the agent's relay entry point to assert the
            # self-updater is GONE from the code, not merely unpublished (T550).
            'src\remote\agent\main.zig',
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
    # Installing over a running Ghoztty closes it and brings it back, and never
    # asks for a reboot (T1204). The app half is a registration and one branch
    # in a window handler - both invisible until an installer meets a locked
    # file, which is the worst possible time to discover them missing - and the
    # MSI half is a property nobody would notice going absent until a user is
    # told to restart their PC. `Window.zig` and `App.zig` are deliberately not
    # listed: they are touched by nearly every task, and a row that is
    # permanently due is a row nobody reads.
    [pscustomobject]@{
        Name   = 'install-restart'
        Script = 'test\win32\install-restart.ps1'
        Stamp  = 'test\win32\install-restart.stamp.json'
        Covers = @(
            'src\apprt\win32\restart_manager.zig',
            'dist\windows-installer\build-msi.sh',
            'test\win32\install-restart.ps1'
        )
    },
    # An upgrade must not kill the sessions it exists to preserve (T1207). The
    # agent and its `--pty-host` holders are windowless, so the Restart
    # Manager's only move on them is termination - and the whole defence is one
    # custom action scheduled before InstallValidate plus a small module that
    # renames one image aside. Every part of that is invisible until an
    # installer meets a live session, which is the worst possible moment to
    # discover it missing. `App.zig` and `main_ghostty.zig` are deliberately not
    # listed: they are touched by nearly every task, and a row that is
    # permanently due is a row nobody reads.
    [pscustomobject]@{
        Name   = 'install-prepare'
        Script = 'test\win32\install-prepare.ps1'
        Stamp  = 'test\win32\install-prepare.stamp.json'
        Covers = @(
            'src\apprt\win32\install_prepare.zig',
            'dist\windows-installer\build-msi.sh',
            'test\win32\install-prepare.ps1'
        )
    },
    # Re-running the installer for the version already installed must say so
    # rather than vanish (T1291). The MSI half and the app half are one feature
    # - the package runs the exe and reads its exit code - so an edit to either
    # side asks the same harness whether the pair still agrees.
    [pscustomobject]@{
        Name   = 'install-maintenance'
        Script = 'test\win32\install-maintenance.ps1'
        Stamp  = 'test\win32\install-maintenance.stamp.json'
        Covers = @(
            'src\apprt\win32\install_maintenance.zig',
            'dist\windows-installer\build-msi.sh',
            'test\win32\install-maintenance.ps1'
        )
    },
    # Somebody actually installs the installer and clicks through it (T1299).
    # Fresh install, upgrade, same-version maintenance, older-over-newer and
    # uninstall, driven with a real msiexec against a real package rewritten to
    # a throwaway identity - the only row in this table whose subject is the
    # product a user meets rather than the recipe that builds it.
    #
    # ADVISORY, and for the reason `release-artifacts-packaging` above is: the
    # subject is a PACKAGE, this box cannot build one (wixl, therefore Docker),
    # and the newest published release is by definition the state of the world
    # BEFORE the edit that makes this row due. So on the turn that edits
    # `build-msi.sh` the question is unanswerable here, which is exactly the
    # shape a hatch pressed every time cannot carry. It reports at every claim,
    # the daily publish gives it a package carrying the change within a day, and
    # its teeth in the meantime are fork-ci's `windows-cross` compile of the same
    # file. A clean walk with no skipped case stamps it the normal way.
    [pscustomobject]@{
        Name     = 'install-walkthrough'
        Script   = 'test\win32\install-walkthrough.ps1'
        Stamp    = 'test\win32\install-walkthrough.stamp.json'
        Advisory = $true
        Covers   = @(
            'dist\windows-installer\build-msi.sh',
            'scripts\msi-test-identity.ps1',
            'test\win32\install-walkthrough.ps1'
        )
    },
    # "Which Ghoztty am I running?" has ONE answer per surface (T1205). Windows
    # cannot replace a running image, so the file on disk and the process in
    # front of the user are routinely different builds - and the About box used
    # to print one's version beside the other's date, which is worse than
    # printing nothing. Nothing here fails to compile when it drifts: a lost
    # field, a renamed label, a comparison that quietly always answers "fresh"
    # all leave a green build and an unanswerable question. `Surface.zig` and
    # `App.zig` are deliberately not listed - every task touches them, and a
    # permanently-due row is a row nobody reads.
    [pscustomobject]@{
        Name   = 'build-identity'
        Script = 'test\win32\ipc-version.ps1'
        Stamp  = 'test\win32\ipc-version.stamp.json'
        Covers = @(
            'src\apprt\win32\provenance.zig',
            'src\apprt\win32\image_freshness.zig',
            'src\apprt\win32\tray_notify.zig',
            'src\cli\version.zig',
            'test\win32\ipc-version.ps1'
        )
    },
    # A startup failure is VISIBLE (T1177). The whole point of this code is a
    # dialog that appears when nothing else can, so an edit to any link in that
    # chain - the reporter, the dialog it builds on, the message text, or the
    # `main` that routes every startup error into it - has to re-answer "does
    # the failure still reach the user?". `App.zig` holds the no-window guard
    # that MINTS the error and is deliberately not listed: no guard in this
    # table covers it, because a file every task touches would leave this row
    # permanently due and therefore permanently ignored.
    [pscustomobject]@{
        Name   = 'startup-failure'
        Script = 'test\win32\startup-failure.ps1'
        Stamp  = 'test\win32\startup-failure.stamp.json'
        Covers = @(
            'src\apprt\win32\startup_error.zig',
            'src\apprt\win32\ConfirmDialog.zig',
            'src\main_ghostty.zig',
            # T1251: which GL implementation is chosen decides WHICH of arms E
            # and F the user gets - an honest refusal or a working terminal on
            # the fallback - so an edit here has to re-answer both.
            'src\renderer\gl_loader.zig',
            'test\win32\startup-failure.ps1'
        )
    },
    # The in-app update (T1178). This is the one code path that REPLACES the
    # app on disk and quits the terminal to do it, and every failure mode is
    # invisible to a compiler: an asset matcher that picks the wrong release,
    # a content check that lets an HTML page reach msiexec, an applier that
    # forgets to relaunch. `App.zig` holds the balloon and the dialog and is
    # deliberately not listed, for the same reason the startup-failure row
    # leaves it out - a file every task touches would leave this row
    # permanently due and therefore permanently ignored.
    [pscustomobject]@{
        Name   = 'update-apply'
        Script = 'test\win32\update-apply.ps1'
        Stamp  = 'test\win32\update-apply.stamp.json'
        Covers = @(
            'src\apprt\win32\update_apply.zig',
            'src\apprt\win32\update_install.zig',
            'src\apprt\win32\update_check.zig',
            'src\apprt\win32\install_location.zig',
            'test\win32\update-apply.ps1',
            'test\win32\lib\ApplierSandbox.ps1'
        )
    },
    # Whether a failed update SAYS anything (T1206). The update-apply row above
    # covers the same two files for a different question - did the applier get
    # to msiexec and back - and neither row can answer the other's. A change
    # that keeps the choreography and drops the dialog leaves update-apply
    # green and puts the user back where they started: a window that said
    # "configuring" and then vanished.
    [pscustomobject]@{
        Name   = 'update-failure-visible'
        Script = 'test\win32\update-failure-visible.ps1'
        Stamp  = 'test\win32\update-failure-visible.stamp.json'
        Covers = @(
            'src\apprt\win32\update_apply.zig',
            'src\apprt\win32\update_install.zig',
            'test\win32\update-failure-visible.ps1',
            'test\win32\lib\ApplierSandbox.ps1'
        )
    },
    # The release-channel check itself (T24, T1171): does the app find a newly
    # published win-v release, and does it stay quiet about one it has already
    # offered? Nothing tied this harness to the code under it, and it drifted
    # into a SETUP FAIL nobody saw - T1217 renamed the `+version` "off" reason
    # and the flavor probe went on demanding the old wording, so every run
    # after it stopped at scenario 4. `App.zig` is out for the usual reason
    # (a file every task touches leaves a row permanently due); the version
    # line is in, because that string IS what the probe reads.
    [pscustomobject]@{
        Name   = 'update-check'
        Script = 'test\win32\update-check.ps1'
        Stamp  = 'test\win32\update-check.stamp.json'
        Covers = @(
            'src\apprt\win32\update_check.zig',
            'src\apprt\win32\install_location.zig',
            'src\cli\version.zig',
            'test\win32\update-check.ps1'
        )
    },
    # The last inch of the update, which update-apply cannot reach: msiexec
    # SUCCEEDING (T1194). It installs a REAL published win-v release under a
    # throwaway product identity, lets the app find and stage the next one, and
    # runs the applier for real - so it is the only thing in the suite that can
    # say the version on disk actually moved, that a live session's holder
    # survived it, and that the sidelined image is gone after the next launch.
    # The identity rewriter is covered too: a package it half-rewrites installs
    # fine and then cannot be upgraded or removed, which is a failure with no
    # symptom until somebody tries.
    [pscustomobject]@{
        Name   = 'update-real-msi'
        Script = 'test\win32\update-real-msi.ps1'
        Stamp  = 'test\win32\update-real-msi.stamp.json'
        Covers = @(
            'src\apprt\win32\update_apply.zig',
            'src\apprt\win32\update_install.zig',
            'scripts\msi-test-identity.ps1',
            'dist\windows-installer\build-msi.sh',
            'test\win32\lib\ThrowawayProduct.ps1',
            'test\win32\update-real-msi.ps1'
        )
    },
    # The JOIN the two harnesses either side of it each stub out (T1209): a real
    # msiexec install driven by the IN-APP updater over a terminal that is
    # RUNNING, closed the way the Restart Manager closes it, with a live session
    # behind it. update-apply stops at msiexec's verdict; update-real-msi kills
    # the app first and hands the applier a pid that has already exited;
    # install-restart sends the close messages with no installer behind them.
    # This one measures the close, the replace, the reopen and the surviving
    # session as one sequence, which is the only order a user ever sees them in.
    [pscustomobject]@{
        Name   = 'update-graceful'
        Script = 'test\win32\update-graceful.ps1'
        Stamp  = 'test\win32\update-graceful.stamp.json'
        Covers = @(
            'src\apprt\win32\update_apply.zig',
            'src\apprt\win32\update_install.zig',
            'src\apprt\win32\install_prepare.zig',
            'scripts\msi-test-identity.ps1',
            'dist\windows-installer\build-msi.sh',
            'test\win32\lib\ThrowawayProduct.ps1',
            'test\win32\update-graceful.ps1'
        )
    },
    # The update download's own REPORT (T1195): does a consented download show
    # progress a user can watch, is a stall named as a stall rather than left
    # looking like a slow link, and does the unprompted background pre-download
    # stay silent? The panel paints on a background desktop where no pixel can
    # be read, so the harness's oracle is the sentence the panel logs - which
    # is why `UpdateProgress.zig` is in this row and not just the model.
    [pscustomobject]@{
        Name   = 'update-progress'
        Script = 'test\win32\update-progress.ps1'
        Stamp  = 'test\win32\update-progress.stamp.json'
        Covers = @(
            'src\apprt\win32\update_progress.zig',
            'src\apprt\win32\UpdateProgress.zig',
            'src\apprt\win32\update_install.zig',
            'test\win32\update-progress.ps1'
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
    # The second-opinion scanner check (T1312): a checker that has only ever
    # been observed saying "clean" is indistinguishable from one that cannot say
    # anything else, and this one is not in the P1-P3 floor -- it is an offline
    # canned-response harness that nothing else would ever run. Its covered set
    # includes daily-publish.ps1 because section G asserts the readback still
    # calls it, which is the wiring that makes the question get asked at all.
    [pscustomobject]@{
        Name   = 'verify-release-clean'
        Script = 'test\win32\verify-release-clean.ps1'
        Stamp  = 'test\win32\verify-release-clean.stamp.json'
        Covers = @(
            'scripts\verify-release-clean.ps1',
            'scripts\daily-publish.ps1',
            'test\win32\verify-release-clean.ps1'
        )
    },
    # The false-positive submission packet (T1313): a report to Microsoft
    # corrects the BYTES it names, and this project publishes new bytes several
    # times a day -- so the packet is generated from the current release rather
    # than typed once. Its harness is offline and not in the P1-P3 floor, and
    # its covered set includes verify-release-clean.ps1 because the packet gets
    # its hashes from there: if that script's idea of "the files" changes, the
    # packet's does too and nothing else would notice.
    [pscustomobject]@{
        Name   = 'false-positive-report'
        Script = 'test\win32\false-positive-report.ps1'
        Stamp  = 'test\win32\false-positive-report.stamp.json'
        Covers = @(
            'scripts\report-false-positive.ps1',
            'scripts\verify-release-clean.ps1',
            'test\win32\false-positive-report.ps1'
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
    # The reconnect ladder ON THE RELAY PATH (T1276). The pure policy is unit
    # tested and the ladder's driver has an on-box script for the TCP case
    # (remote-reconnect-fresh), so what nothing else covered is the path a
    # user's second machine actually uses: the credential a relay re-dial
    # carries, and the difference between "the machine is unreachable" (climb)
    # and "the bearer was rejected" (terminal). The defect this closes lived
    # entirely in that gap and every other harness stayed green through it.
    [pscustomobject]@{
        Name   = 'remote-reconnect-relay'
        Script = 'test\win32\remote-reconnect-relay.ps1'
        Stamp  = 'test\win32\remote-reconnect-relay.stamp.json'
        Covers = @(
            'src\apprt\win32\RemoteReconnect.zig',
            'src\apprt\win32\remote_reconnect.zig',
            'src\remote\relay_dial.zig',
            'test\win32\lib\FakeRelay.ps1',
            'test\win32\remote-reconnect-relay.ps1'
        )
    },
    # The relay window end to end against a REAL relay and a REAL agent (T368),
    # where remote-reconnect-relay above drives a fake one. It is the only thing
    # that kills and RESTARTS the agent under a live remote window, so it owns
    # two claims nothing else can make: the ladder settles on a definite verdict
    # rather than spinning, and the transports it dialed on the way are freed at
    # +close instead of accumulating threads. Until T368 the script had no row
    # at all, so an edit to the ladder or the dial was tied to nothing.
    [pscustomobject]@{
        Name   = 'ipc-relay'
        Script = 'test\win32\ipc-relay.ps1'
        Stamp  = 'test\win32\ipc-relay.stamp.json'
        Covers = @(
            'src\apprt\win32\RemoteReconnect.zig',
            'src\apprt\win32\remote_reconnect.zig',
            'src\remote\relay_dial.zig',
            'src\apprt\ipc\list.zig',
            'test\win32\ipc-relay.ps1'
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
        # And the OTHER side of the drift compare (T1325). Section A asserts the
        # mirror is byte-identical to tip-of-main, a question whose answer moves
        # when main moves and never when our tree does - so without these the
        # guard could only ever go red by accident. It did exactly that: main
        # rewrote both SKILL.md files on 2026-09-02, the mirror was stale from
        # that moment, and the check stayed quiet until an unrelated edit to a
        # covered file happened to reopen it two days later.
        Upstream = @(
            'macos/Resources/Ghoztty/hooks/ghoztty-banner.sh',
            'macos/Resources/Ghoztty/hooks/ghoztty-activity-state.sh',
            'macos/Resources/Ghoztty/skills/ghoztty/SKILL.md',
            'macos/Resources/Ghoztty/skills/process-feedback/SKILL.md'
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
    # What a plain-shell session is RUNNING, in the roster (T545). The sampler
    # behind it ticks every ~10s and its only other reader is a restart notice,
    # so a regression here is invisible to every interactive use of the tree —
    # `+sessions` simply goes back to saying nothing, which is also what it said
    # before the feature existed.
    [pscustomobject]@{
        Name   = 'sessions-running-cmd'
        Script = 'test\win32\sessions-running-cmd.ps1'
        Stamp  = 'test\win32\sessions-running-cmd.stamp.json'
        Covers = @(
            'src\cli\sessions.zig',
            'src\remote\agent\pty_child.zig',
            'src\remote\agent\pty_holder_child.zig',
            # T552 added arm D, the pane<->session round trip, so the harness now
            # also covers the path that carries `pane_id` from the OPEN's env to
            # the roster row: the agent records it, the wire type declares it and
            # the client dupes it. An edit anywhere along that chain makes this
            # script due, which is the point - the two directions of the join are
            # answered by two different servers and only this run compares them.
            'src\remote\agent\server.zig',
            'src\remote\protocol.zig',
            'src\remote\connection.zig',
            'test\win32\sessions-running-cmd.ps1'
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
    # The solo confirm pass (T1170) only speaks on a day already going badly --
    # a red lane -- and a parser that has quietly stopped matching reports the
    # same "the log names no failing test" as a lane that crashed. Same rule as
    # the rows around it: the library and this harness are covered,
    # scripts\floor-lane.ps1 is not, so a stall-detector edit does not gate on
    # it; the wiring arms prove the wiring instead.
    [pscustomobject]@{
        Name   = 'lane-solo-confirm'
        Script = 'test\win32\floor-lane-solo-confirm.ps1'
        Stamp  = 'test\win32\floor-lane-solo-confirm.stamp.json'
        Covers = @(
            'scripts\lib\LaneSolo.ps1',
            'test\win32\floor-lane-solo-confirm.ps1'
        )
    },
    # The commit preflight (T453) speaks only on a box that is already out of
    # memory, which is rarer still than a red lane -- and a gate nobody has ever
    # seen refuse is indistinguishable from one that cannot refuse. Same
    # coverage rule as the rows around it: the library and this harness gate,
    # scripts\floor-lane.ps1 does not; the wiring arms prove the wiring.
    [pscustomobject]@{
        Name   = 'lane-commit-headroom'
        Script = 'test\win32\floor-lane-commit-headroom.ps1'
        Stamp  = 'test\win32\floor-lane-commit-headroom.stamp.json'
        Covers = @(
            'scripts\lib\CommitHeadroom.ps1',
            'test\win32\floor-lane-commit-headroom.ps1'
        )
    },
    # The compiler-crash retry (T451) is the same shape again: it speaks only
    # when zig.exe itself has faulted, which is roughly weekly, so a classifier
    # that has quietly stopped matching is indistinguishable from a month with
    # no compiler crash in it -- and the failure mode is the expensive one, a
    # toolchain fault read as broken code. Same coverage rule as the rows around
    # it: the library and this harness gate, scripts\floor-lane.ps1 does not.
    [pscustomobject]@{
        Name   = 'lane-compiler-crash'
        Script = 'test\win32\floor-lane-compiler-crash.ps1'
        Stamp  = 'test\win32\floor-lane-compiler-crash.stamp.json'
        Covers = @(
            'scripts\lib\CompilerCrash.ps1',
            'test\win32\floor-lane-compiler-crash.ps1'
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
    # The WHEA report's whole subject is a filter that must never be applied
    # (T452): corrected hardware errors log at WARNING level, so a query
    # filtered to Error reads a box logging 8000 of them a month as silent -
    # which is exactly what T449 recorded. That defect lives in one line of
    # scripts\whea-report.ps1 and would be trivial to reintroduce while
    # "tidying" the query, with no symptom at all until the next crash
    # investigation trusts the answer.
    [pscustomobject]@{
        Name   = 'whea-report'
        Script = 'test\win32\whea-report.ps1'
        Stamp  = 'test\win32\whea-report.stamp.json'
        Covers = @(
            'scripts\whea-report.ps1',
            'test\win32\whea-report.ps1'
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
    # T527: the GUI postmortem is the third crash row, and it covers the case
    # neither of the two above can - a death nobody was watching for, in a run
    # whose subject was something else entirely. Like them it is only ever
    # exercised on a bad day, so a quietly broken diagnosis is indistinguishable
    # from a run in which nothing died. lib\TestDesktop.ps1 is deliberately NOT
    # in Covers: it is the harness every GUI script edits for its own reasons,
    # and gating all of those on this one script is exactly the noise T783 warns
    # about. What IS covered is the postmortem library and its own acceptance.
    [pscustomobject]@{
        Name   = 'gui-postmortem'
        Script = 'test\win32\gui-postmortem.ps1'
        Stamp  = 'test\win32\gui-postmortem.stamp.json'
        Covers = @(
            'test\win32\lib\GuiPostmortem.ps1',
            'scripts\lib\CrashDiag.ps1',
            'test\win32\gui-postmortem.ps1'
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
    # The decisions CLI (T566), for the same reason as the row above: nothing
    # in the zig lanes or the P1-P3 floor executes a line of
    # `scripts\parity-decisions.ps1`, and its failure mode is not a red test
    # but a decision the USER reads - the one audience that cannot check it
    # against the code. `scripts\parity-tasks.ps1` is deliberately NOT covered
    # here even though it carries the relay: the `gate-negatives` row below
    # already fires on every edit to it, and its DECISION PROBLEMS registry row
    # points at this harness, so the relay has a guard without a third harness
    # falling due on every tracker change.
    [pscustomobject]@{
        Name   = 'parity-decisions'
        Script = 'test\win32\parity-decisions.ps1'
        Stamp  = 'test\win32\parity-decisions.stamp.json'
        Covers = @(
            'scripts\parity-decisions.ps1',
            'test\win32\parity-decisions.ps1'
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
            'scripts\ci-status.ps1',
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
    # The dashboard's DOM level (T565): the page's 74k of inline JS, driven in a
    # real browser. The HTTP harness above proves the script PARSES; only this
    # one proves a button still does what it says. It shares the page and the
    # server with that guard on purpose - either harness going stale over a
    # dashboard edit is worth saying out loud, and they answer different
    # questions about the same file.
    [pscustomobject]@{
        Name   = 'dashboard-dom'
        Script = 'test\win32\dashboard-dom.ps1'
        Stamp  = 'test\win32\dashboard-dom.stamp.json'
        Covers = @(
            'scripts\task-dashboard.page.html',
            'scripts\task-dashboard.js',
            'test\win32\dashboard-dom.ps1',
            'test\win32\lib\dashboard-stub-server.js',
            'test\win32\lib\dashboard-dom-selftest.js'
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
    # What a layout sync COSTS the UI thread (T412). The cost is paid on a real
    # box with real panes under real output pressure, so no unit lane can see
    # it: eight busy panes measured 991 ms per capture before the reuse rule,
    # and the only thing standing between that and a regression is this harness
    # actually being run. The row covers the cost/budget module and the script;
    # App.zig is deliberately NOT here (it moves daily for unrelated reasons and
    # would leave a multi-minute GUI run due every turn - the same call the
    # session-layout-preserve row above makes).
    [pscustomobject]@{
        Name   = 'layout-capture-cost'
        Script = 'test\win32\layout-capture-cost.ps1'
        Stamp  = 'test\win32\layout-capture-cost.stamp.json'
        Covers = @(
            'src\apprt\win32\layout_cost.zig',
            'test\win32\layout-capture-cost.ps1'
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
    # The feedback user-report rule (T1321): a report drained from the viewer
    # feedback queue is a USER report, so the pass that fixes one records a
    # release request and files what it defers with `-UserReport` - otherwise
    # the fix rides the ordinary daily cadence and the person who reported it
    # downloads the same broken build again (the T1294 shape, paid for real on
    # 2026-09-03). The rule lives in a skill document the app SHIPS, in two
    # copies that must not drift, so an edit to either copy - or to the embedded
    # asset's tripwire, or to the doc that explains the intake - has to re-prove
    # it. Static scan, no app, under a second.
    [pscustomobject]@{
        Name   = 'feedback-user-report'
        Script = 'test\win32\feedback-user-report.ps1'
        Stamp  = 'test\win32\feedback-user-report.stamp.json'
        Covers = @(
            'macos\Resources\Ghoztty\skills\process-feedback\SKILL.md',
            'src\apprt\win32\assets\ghoztty\skills\process-feedback\SKILL.md',
            'src\apprt\win32\GhosttyAssets.zig',
            'docs\claude\viewers.md',
            'test\win32\feedback-user-report.ps1'
        )
    },
    # The control-character lint (T1231): a text file holding a real 0x07/0x08/
    # 0x0c where a backslash escape was meant. Fifteen files were in that state,
    # and one of them was THIS file's own coverage table - `src\apprt\win32\...`
    # written as `src<0x07>pprt\...`, a path that could never resolve, in a guard
    # row whose whole job is to resolve paths. Coverage is deliberately narrow:
    # the scanner, its two callers (the loop's pre-commit validate and the git
    # hook that covers the other window sharing this tree) and the harness. The
    # tree it scans is NOT in the list - every commit would make the guard due,
    # which is what the pre-commit hook already answers per commit. About two
    # seconds.
    [pscustomobject]@{
        Name   = 'control-char-scan'
        Script = 'test\win32\control-char-scan.ps1'
        Stamp  = 'test\win32\control-char-scan.stamp.json'
        Covers = @(
            'scripts\control-char-scan.ps1',
            'scripts\githooks\pre-commit',
            'test\win32\control-char-scan.ps1'
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
            # T1100: the capability declaration is the same foundation asked the
            # other way round - what the desktop CANNOT do, and therefore which
            # scripts skip rather than fail. Section Z of the harness is the only
            # thing that drives its skip path.
            'test\win32\lib\DesktopCapability.ps1',
            'test\win32\test-desktop-harness.ps1'
        )
    },
    # The P1-P3 floor's fixture gate (T1285). The floor is what CLAUDE.md names
    # as the bar for every change, and on 2026-09-02 it scored sixteen product
    # failures for an app that had simply stopped answering - its fixture verbs
    # were called with `[void](...)`, so the one thing that would have said so
    # was thrown away. lib\FloorFixture.ps1 is the refusal that replaced them,
    # and a refusal is only a refusal while it can still fire: section B of the
    # harness constructs an unreachable app and demands ONE setup failure rather
    # than a cascade. The three floor scripts ride along because they are the
    # only callers, so an edit that quietly reverts one back to `[void]` has to
    # answer to the same harness. About a minute.
    [pscustomobject]@{
        Name   = 'ipc-floor-setup'
        Script = 'test\win32\ipc-floor-setup.ps1'
        Stamp  = 'test\win32\ipc-floor-setup.stamp.json'
        Covers = @(
            'test\win32\lib\FloorFixture.ps1',
            'test\win32\ipc-floor-setup.ps1',
            'test\win32\ipc-p1.ps1',
            'test\win32\ipc-p2.ps1',
            'test\win32\ipc-p3.ps1'
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
    # The T476 compiler-crash reduction. The reduction pins ghoztty's
    # `src\build\uucode_config.zig` verbatim - and the crash NEEDS that config,
    # since a trimmed one compiles clean - so an edit to the real config that
    # leaves the copy behind turns the reduction into a description of a build
    # that no longer exists. The harness also re-asks whether the compiler bug
    # is still there, which is the only thing standing between a zig upgrade
    # that fixes it and `-Dtest-llvm` living in build.zig forever. Two to three
    # minutes when it has to generate uucode's tables, seconds after that;
    # `-SkipCompile` runs the drift checks alone.
    [pscustomobject]@{
        Name   = 'zig-repro-t476'
        Script = 'test\win32\zig-repro-t476.ps1'
        Stamp  = 'test\win32\zig-repro-t476.stamp.json'
        Covers = @(
            'src\build\uucode_config.zig',
            'test\zig-repro\t476-selfhosted-backend\*',
            'test\zig-repro\t476-selfhosted-backend\src\*',
            'test\win32\zig-repro-t476.ps1'
        )
    },
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
    # T1343: what a splitter drag COSTS. The batched frame wait is invisible to
    # every other check in the tree - a change that puts the per-pane wait back
    # breaks no assertion, compiles clean, and is felt as "janky" weeks later by
    # the user who reported it the first time. NARROW on purpose: the drag path
    # and the pure cost module, not Window.zig at large. About three minutes,
    # off the input desktop.
    [pscustomobject]@{
        Name   = 'drag-perf'
        Script = 'test\win32\drag-perf.ps1'
        Stamp  = 'test\win32\drag-perf.stamp.json'
        Covers = @(
            'src\apprt\win32\drag_perf.zig',
            # The chrome fan-out counters the harness asserts on since T1345 —
            # the drag line's chrome_moves/blits/heals come from here, so an
            # edit to this module is an edit to what drag-perf.ps1 measures.
            'src\apprt\win32\chrome_fanout.zig',
            'test\win32\drag-perf.ps1'
        )
    },
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
            'test\win32\harness-process-leak.ps1',
            # T1168: the autostart half of the same leak is ARMED in
            # Isolation.ps1 (where the instance suffix is minted) and SWEPT in
            # CleanSlate.ps1 (the backstop for a killed run). Section R is the
            # only thing that exercises either, so an edit to them has to make
            # this guard due - their own guards audit the corpus, not this.
            'test\win32\lib\Isolation.ps1',
            'test\win32\lib\CleanSlate.ps1'
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

    # T1191 - the reachability sweep. It covers `src\apprt\win32.zig` itself,
    # which is unusual for a row and is the whole point: the file the rule is
    # about is a hand-written list, and the moment somebody adds a win32 module
    # without adding its line, this row goes due and the sweep says which one.
    # It also covers the win32 module directory, because a NEW module with
    # tests is exactly the case the rule exists for and nothing else notices it
    # arriving.
    [pscustomobject]@{
        Name   = 'test-reach'
        Script = 'test\win32\test-reach-audit.ps1'
        Stamp  = 'test\win32\test-reach-audit.stamp.json'
        Covers = @(
            'test\win32\test-reach-audit.ps1',
            'test\win32\lib\TestReachAudit.ps1',
            'src\apprt\win32.zig',
            'src\apprt\win32\*.zig'
        )
    }

    # T1193 - the user-desktop launch sweep. It covers the whole acceptance
    # directory on purpose: the case it exists for is a NEW script that starts
    # the app outside the harness, and a row that watched only the analyzer
    # would go green on the day that script lands. It also covers
    # `src\cli\ghostty.zig`, because the "these verbs cannot create a process"
    # list is a claim about that enum and section C is what re-checks it.
    [pscustomobject]@{
        Name   = 'desktop-launch'
        Script = 'test\win32\desktop-launch-audit.ps1'
        Stamp  = 'test\win32\desktop-launch-audit.stamp.json'
        Covers = @(
            'test\win32\*.ps1',
            'test\win32\lib\DesktopLaunchAudit.ps1',
            'test\win32\lib\TestDesktop.ps1',
            'src\cli\ghostty.zig'
        )
    },
    # T364 - the chrome's COLOR math, which nothing in the four lanes scores
    # against a painted pixel. chrome-theme.ps1 is the one harness that reads
    # the band, the hover and the panel surfaces off the screen and compares
    # them to values it DERIVES from these two modules, so an edit here is
    # exactly the kind that a green unit-test suite and a green build both miss.
    # The oracle library is covered with them: it mirrors the Zig, and a mirror
    # that drifts is the failure this harness cannot catch on its own.
    #
    # Deliberately NARROW. The painters that consume these colors
    # (Window.zig, tab_shape.zig) are not here - they change constantly, and a
    # row that is always due is a row nobody reads.
    [pscustomobject]@{
        Name   = 'chrome-theme'
        Script = 'test\win32\chrome-theme.ps1'
        Stamp  = 'test\win32\chrome-theme.stamp.json'
        Covers = @(
            'src\apprt\win32\chrome_theme.zig',
            'src\apprt\win32\color_math.zig',
            'src\apprt\win32\panel_theme.zig',
            'test\win32\lib\ColorMath.ps1',
            'test\win32\chrome-theme.ps1'
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

# Is this run auditing the repo the script itself lives in? The table's paths
# are FACTS ABOUT THIS REPOSITORY, so "that pattern matches nothing" only means
# something here; against a fixture or a foreign tree it is the normal case and
# already has its own sentence (`GUARD N/A`). Compared by resolved path rather
# than by "was -Repo passed", because the real pre-commit gate passes -Repo
# explicitly with the repo root in it (parity-tasks.ps1) - keying on the flag
# would have switched the check off in exactly the run that needs it.
$AuditingOwnRepo = $false
try {
    $ownRepo = Split-Path -Parent $PSScriptRoot
    $AuditingOwnRepo = ((Resolve-Path -LiteralPath $Repo).Path.TrimEnd('\', '/') -eq
        (Resolve-Path -LiteralPath $ownRepo).Path.TrimEnd('\', '/'))
} catch { $AuditingOwnRepo = $false }

function Get-TableFaults($rowsToAudit) {
    <#
      T1227. A `Covers` entry that matches NOTHING contributes nothing, silently:
      Get-CoveredFiles asks Get-ChildItem with -ErrorAction SilentlyContinue and
      moves on. A whole row that matches nothing is reported (`GUARD N/A`), but a
      row with one good pattern and one broken one is not - it looks CURRENT
      while quietly watching one file fewer than it claims. That is a check that
      cannot fire, which go.md says a gate must never be.

      Two faults, and they answer different questions:

        * control-char - a path carrying a byte below 0x20. Always checked, in
          any tree: no file can have such a name, so the entry is a typo
          wherever it is read. This is the shape a shell heredoc leaves behind
          when it halves a backslash (`\a` -> 0x07, `\b` -> 0x08).

        * matches-nothing - a pattern that matches no file while ANOTHER pattern
          in the same row does. The sibling is what makes it a typo rather than
          a foreign tree, and it is why this needs no allow-list: a row that is
          wholly inapplicable stays silent.
    #>
    $faults = @()
    foreach ($row in @($rowsToAudit)) {
        $matched = @{}
        foreach ($pattern in $row.Covers) {
            $n = @(Get-ChildItem -Path (Join-Path $Repo $pattern) -File -ErrorAction SilentlyContinue).Count
            $matched[$pattern] = $n
            if ($pattern -match '[\x00-\x1f\x7f]') {
                $shown = ($pattern -replace '[\x00-\x1f\x7f]', '?')
                $codes = @()
                foreach ($ch in $pattern.ToCharArray()) {
                    if ([int]$ch -lt 0x20 -or [int]$ch -eq 0x7f) { $codes += ('0x{0:x2}' -f [int]$ch) }
                }
                $faults += [pscustomobject]@{
                    Guard = $row.Name; Pattern = $shown; Reason = 'control-char'
                    Detail = ("contains {0} where a path separator belongs" -f ($codes -join ', '))
                }
            }
        }
        if (-not $AuditingOwnRepo) { continue }
        $live = @($matched.Values | Where-Object { $_ -gt 0 }).Count
        if ($live -eq 0) { continue }
        foreach ($pattern in $row.Covers) {
            if ($matched[$pattern] -eq 0 -and $pattern -notmatch '[\x00-\x1f\x7f]') {
                $faults += [pscustomobject]@{
                    Guard = $row.Name; Pattern = $pattern; Reason = 'matches-nothing'
                    Detail = 'nothing in this tree matches it, though the row''s other patterns do'
                }
            }
        }
    }
    return @($faults)
}

function Write-TableFaults($faults) {
    foreach ($f in @($faults)) {
        "GUARD TABLE FAULT {0}: covers '{1}' - {2}" -f $f.Guard, $f.Pattern, $f.Detail
    }
    if (@($faults).Count -gt 0) {
        "  (a covered path that cannot match never changes, so its guard can never go due)"
        "  fix the path in scripts\guard-due.ps1, or drop the entry if the file is gone"
    }
}

function Get-NormalizedFileHash([string]$fullPath) {
    <#
      SHA-256 of the file's bytes with CRLF folded to LF and any UTF-8 BOM
      dropped. .ps1 carries no `text` attribute in .gitattributes, so the bytes
      on disk depend on the checkout's line-ending settings; hashing them raw
      would report every file as changed on a differently-configured clone, and
      a gate that cries wolf on a fresh clone is a gate nobody reads.

      Takes a full path rather than a repo-relative one so `stamp-ci` can hash a
      blob it extracted from a commit through the SAME normalisation the stamp
      itself uses - comparing a git blob hash against a working-tree file would
      answer a subtly different question (whether the checkout's filters match),
      which is not the question.
    #>
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
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

function Get-NormalizedHash([string]$relPath) {
    return Get-NormalizedFileHash (Join-Path $Repo $relPath)
}

function Get-LiveMap($row) {
    $map = [ordered]@{}
    foreach ($rel in (Get-CoveredFiles $row)) { $map[$rel] = Get-NormalizedHash $rel }
    return $map
}

<#
  T1325. A row may also watch files that live in ANOTHER tree - `Upstream` is a
  list of paths inside `origin/main`, and their blob shas go into the stamp
  beside the covered files' hashes.

  Why a row would want that: `hook-json` asserts that the vendored asset mirror
  is byte-identical to tip-of-main, and NOTHING in our tree changes when main
  advances. So the mirror went stale on 2026-09-02, the harness would have said
  so, and the guard never reopened to ask it - the T1099 shape, a verdict that
  can only ever say "fine" until something unrelated pokes it. Keying on the
  upstream BLOB rather than on main's head sha means ordinary main churn is
  silent and a change to a file we actually mirror is not.

  An answer is only possible where `origin/main` exists; a clone without it (a
  fixture repo, a fresh worktree with no fetch) gets $null, and $null means
  "cannot answer", never "changed" - so the gate can no more go red for missing
  a remote than it can for missing the files it covers.
#>
function Get-UpstreamMap($row) {
    if (-not $row.Upstream) { return $null }
    # try/catch as well as 2>$null: a tree with no `.git` at all makes git print
    # a repository-level fatal that --quiet cannot suppress, and under this
    # script's ErrorActionPreference that is a terminating NativeCommandError
    # rather than a line on stderr. That tree is precisely the "cannot answer"
    # case, so it must be a $null, not a throw.
    $head = ''
    try { $head = (& git -C $Repo rev-parse --verify --quiet origin/main 2>$null | Out-String).Trim() } catch { $head = '' }
    if (-not $head) { return $null }
    $map = [ordered]@{}
    foreach ($rel in @($row.Upstream)) {
        $ref = "origin/main:$($rel -replace '\\', '/')"
        $sha = ''
        try { $sha = (& git -C $Repo rev-parse --verify --quiet $ref 2>$null | Out-String).Trim() } catch { $sha = '' }
        # A path main has DELETED is a real finding, not a reason to bail: the
        # empty string differs from whatever the stamp holds, so it reads as
        # moved and the harness gets to say what that means.
        $map[$ref] = $sha
    }
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

function Get-StampUpstreamMap($stamp) {
    $map = [ordered]@{}
    if ($null -eq $stamp -or $null -eq $stamp.upstream) { return $map }
    foreach ($p in $stamp.upstream.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
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
            Advisory = [bool]$row.Advisory; CiGuard = ($null -ne $row.CiEvidence)
            Kind = 'n/a'; Reason = 'no-covered-files'; Findings = @()
            Files = @(); StampedAt = ''; StampedCommit = ''; StampedUncommitted = @()
            StampedSource = ''; StampedCiUrl = ''
        }
    }
    # A plain array, not a generic List: PowerShell 5.1's enumerable binder
    # throws "Argument types do not match" on @(<empty List[object]>), which is
    # exactly the CURRENT case - the one this gate reports most often.
    $findings = @()

    if ($null -eq $stamp) {
        return [pscustomobject]@{
            Name = $row.Name; Script = $row.Script; RunArgs = [string]$row.RunArgs; Stamp = $row.Stamp
            Advisory = [bool]$row.Advisory; CiGuard = ($null -ne $row.CiEvidence)
            Kind = 'due'; Reason = 'no-stamp'; Findings = @()
            Files = @($live.Keys); StampedAt = ''; StampedCommit = ''; StampedUncommitted = @()
            StampedSource = ''; StampedCiUrl = ''
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

    # The upstream half (T1325), reported as its own finding kind so a reader
    # can tell "somebody edited our copy" from "main edited theirs".
    $upstreamMoved = $false
    $liveUp = Get-UpstreamMap $row
    if ($null -ne $liveUp) {
        $stampedUp = Get-StampUpstreamMap $stamp
        foreach ($ref in $liveUp.Keys) {
            if (-not $stampedUp.Contains($ref) -or $stampedUp[$ref] -ne $liveUp[$ref]) {
                $findings += [pscustomobject]@{ Kind = 'upstream'; Path = $ref }
                $upstreamMoved = $true
            }
        }
    }

    $kind = if ($findings.Count -gt 0) { 'due' } else { 'current' }
    $reason = ''
    if ($findings.Count -gt 0) {
        $reason = if ($upstreamMoved -and $findings.Count -eq @($findings | Where-Object { $_.Kind -eq 'upstream' }).Count) {
            'upstream-moved'
        } else { 'covered-files-changed' }
    }
    return [pscustomobject]@{
        Name = $row.Name; Script = $row.Script; RunArgs = [string]$row.RunArgs; Stamp = $row.Stamp
        Advisory = [bool]$row.Advisory; CiGuard = ($null -ne $row.CiEvidence)
        Kind = $kind; Reason = $reason; Findings = $findings
        Files = @($live.Keys)
        StampedAt = [string]$stamp.generated
        StampedCommit = [string]$stamp.commit
        StampedUncommitted = @($stamp.uncommitted | Where-Object { $_ })
        StampedSource = [string]$stamp.source
        StampedCiUrl = [string]$stamp.ciRun
    }
}

function Write-Stamp($row, $Provenance) {
    <#
      Rewrite the stamp only when the file MAP actually moved. A green harness
      run that changed nothing must leave a clean working tree behind it -
      otherwise every run of the harness produces a diff, and a diff nobody
      means is a diff nobody reads.

      $Provenance (T1189) is an ordered map of extra fields describing WHERE the
      evidence came from - the CI run url and sha, for a stamp written by
      `stamp-ci`. A change of provenance over an unchanged file map still
      rewrites, because "the same code, proved somewhere else" is exactly the
      transition worth recording; a stamp that already names this run is left
      alone, so re-running stamp-ci is a no-op like every other update here.
    #>
    $live = Get-LiveMap $row
    $prevStamp = Read-Stamp $row
    $existing = Get-StampMap $prevStamp
    $same = ($existing.Count -eq $live.Count)
    if ($same) {
        foreach ($k in $live.Keys) {
            if (-not $existing.Contains($k) -or $existing[$k] -ne $live[$k]) { $same = $false; break }
        }
    }
    # The upstream shas the run just vouched for (T1325). Where `origin/main` is
    # unreachable the previous stamp's map is carried forward untouched: a box
    # that cannot ask the question must not answer it by erasing the key, which
    # would silently retire the guard for everybody who pulls that stamp.
    $liveUp = Get-UpstreamMap $row
    $prevUp = Get-StampUpstreamMap $prevStamp
    if ($null -eq $liveUp) { $liveUp = $prevUp }
    if ($same) {
        if ($liveUp.Count -ne $prevUp.Count) { $same = $false }
        else {
            foreach ($k in $liveUp.Keys) {
                if (-not $prevUp.Contains($k) -or $prevUp[$k] -ne $liveUp[$k]) { $same = $false; break }
            }
        }
    }
    if ($same -and $Provenance) {
        foreach ($k in $Provenance.Keys) {
            $was = if ($prevStamp) { [string]$prevStamp.$k } else { '' }
            if ($was -ne [string]$Provenance[$k]) { $same = $false; break }
        }
    }
    elseif ($same -and $prevStamp -and [string]$prevStamp.source) {
        # A local harness run re-taking a stamp that CI had written must drop
        # the CI provenance with it, or the file keeps naming a run that is no
        # longer what vouches for it.
        $same = $false
    }
    if ($same) { return [pscustomobject]@{ Written = $false; Files = @($live.Keys) } }

    $commit = ''
    try { $commit = (& git -C $Repo rev-parse --short HEAD 2>$null | Out-String).Trim() } catch { $commit = '' }

    <#
      Which covered files were NOT that commit's content when the stamp was
      taken (T1164). The stamp gate is a CONTENT check and always was, so this
      changes no verdict - it exists because the provenance line did not say
      so. On 2026-08-23 a green run at 01:59 stamped the working tree that was
      committed seven minutes later as 9d445b377, and the line therefore read
      `stamped 2026-08-23 from 820193367` - a commit that predated the change.
      A turn read that as proof the gate had let a changed file through and
      opened a question about the gate; the gate was right and the sentence was
      not. `from <sha> +N uncommitted` cannot be read that way.
    #>
    $uncommitted = @()
    try {
        $porcelain = @(& git -C $Repo status --porcelain --untracked-files=all -- @($live.Keys) 2>$null)
        foreach ($line in $porcelain) {
            if (-not $line -or $line.Length -le 3) { continue }
            # `XY <path>`, and for a rename `XY <old> -> <new>`: the new name is
            # the one that is in the stamp.
            $path = $line.Substring(3).Trim()
            $arrow = $path.LastIndexOf(' -> ')
            if ($arrow -ge 0) { $path = $path.Substring($arrow + 4) }
            $uncommitted += $path.Trim('"').Replace('\', '/')
        }
    } catch { $uncommitted = @() }
    $uncommitted = @($uncommitted | Sort-Object -Unique)

    $files = [ordered]@{}
    foreach ($k in $live.Keys) { $files[$k] = $live[$k] }
    $doc = [ordered]@{
        guard        = $row.Name
        script       = $row.Script.Replace('\', '/')
        generated    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        commit       = $commit
        uncommitted  = $uncommitted
    }
    if ($Provenance) { foreach ($k in $Provenance.Keys) { $doc[$k] = $Provenance[$k] } }
    if ($liveUp.Count -gt 0) {
        $up = [ordered]@{}
        foreach ($k in $liveUp.Keys) { $up[$k] = $liveUp[$k] }
        $doc['upstream'] = $up
    }
    $doc['files'] = $files
    $json = ($doc | ConvertTo-Json -Depth 5)
    $path = Join-Path $Repo $row.Stamp
    # A first stamp in a tree that has no test\win32 yet (a fixture repo, a
    # fresh worktree) must not die on the missing directory.
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
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

    'stamp-ci' {
        <#
          T1189. Clear a row from the build machine that CAN answer its
          question, for the case this box physically cannot: the MSI compile
          needs wixl, wixl is Linux tooling, and Docker is deliberately kept
          down here.

          The claim it writes is narrow on purpose - "a run of <workflow>'s
          <job> concluded success over a commit whose covered files are byte for
          byte the ones on disk now" - and every part of it is checked:

            * the run's workflow name matches the row's CiEvidence,
            * the run completed with conclusion `success`,
            * the NAMED JOB inside it concluded success (a run can be green with
              the job that matters skipped, which proves nothing),
            * every covered file at that run's commit hashes the same as the
              working tree, through this script's own normalisation.

          Anything short of that stamps nothing and exits 1: an unproved stamp
          is the exact lie the whole mechanism exists to prevent, so there is no
          hatch past the content check.
        #>
        if ($env:GHOZTTY_TEST_BODY -eq 'pending' -and -not $IgnoreRunState) {
            "STAMP REFUSED: the calling run has not reached the end of its body (GHOZTTY_TEST_BODY=pending)."
            exit 3
        }
        if (-not $RunsJsonFile -and $env:GHOZTTY_GUARD_CI_RUNS_JSON) { $RunsJsonFile = $env:GHOZTTY_GUARD_CI_RUNS_JSON }

        $ciRows = @($rows | Where-Object { $null -ne $_.CiEvidence })
        if ($ciRows.Count -eq 0) {
            "ERROR no selected guard declares CiEvidence (known: {0})" -f (
                (@($GuardTable | Where-Object { $null -ne $_.CiEvidence } | ForEach-Object { $_.Name })) -join ', ')
            exit 2
        }

        # Same stderr discipline as ci-status.ps1's Invoke-Gh: under PS 5.1 with
        # $ErrorActionPreference = 'Stop' a native command's stderr line becomes
        # a TERMINATING error, so a routine gh warning would kill the run it was
        # only meant to inform.
        function Invoke-Gh([string[]]$argList) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                # NEVER `| Out-String` here: it wraps at the host's buffer width
                # and a wrap lands INSIDE a sha, which ConvertFrom-Json tolerates
                # (ci-status.ps1 paid half an hour for that one).
                $out = @(& gh @argList 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
                return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
            } catch {
                return @{ Code = 127; Out = $_.Exception.Message }
            } finally { $ErrorActionPreference = $prev }
        }

        # PS 5.1 hands a JSON array back as ONE object rather than enumerating
        # it; the ForEach-Object is what unrolls it.
        function Expand-Json([string]$text) {
            if (-not $text) { return @() }
            return @($text | ConvertFrom-Json | ForEach-Object { $_ })
        }

        function Get-GitOut([string[]]$argList) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $out = & git -C $Repo @argList 2>$null
                if ($LASTEXITCODE -ne 0) { return $null }
                return (@($out) -join "`n").Trim()
            } finally { $ErrorActionPreference = $prev }
        }

        $branch = $Branch
        if (-not $branch) { $branch = Get-GitOut @('rev-parse', '--abbrev-ref', 'HEAD') }

        $runs = @()
        if ($RunsJsonFile) {
            if (-not (Test-Path -LiteralPath $RunsJsonFile)) {
                "CI EVIDENCE UNAVAILABLE: runs file not found: {0}" -f $RunsJsonFile
                exit 1
            }
            $runs = @(Expand-Json ([System.IO.File]::ReadAllText($RunsJsonFile, [System.Text.Encoding]::UTF8)))
        }
        else {
            if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
                "CI EVIDENCE UNAVAILABLE: gh is not installed on this box"
                exit 1
            }
            if (-not $branch -or $branch -eq 'HEAD') {
                "CI EVIDENCE UNAVAILABLE: no branch to enumerate runs for (detached HEAD?)"
                exit 1
            }
            $r = Invoke-Gh @('run', 'list', '--repo', $Nwo, '--branch', $branch, '--limit', '30',
                '--json', 'databaseId,headSha,workflowName,status,conclusion,url,createdAt')
            if ($r.Code -ne 0) {
                $why = (@($r.Out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                if (-not $why) { $why = "gh run list exited $($r.Code)" }
                "CI EVIDENCE UNAVAILABLE: {0}" -f $why
                exit 1
            }
            try { $runs = @(Expand-Json $r.Out) }
            catch { "CI EVIDENCE UNAVAILABLE: gh returned output that is not JSON"; exit 1 }
        }

        function Test-JobGreen($run, [string]$jobName) {
            # Offline (the acceptance fixture): the run object carries its own
            # `jobs` array, in the shape `gh run view --json jobs` returns. The
            # rule below is the real one either way; only the transport moves.
            $jobs = $null
            if ($null -ne $run.jobs) { $jobs = @($run.jobs) }
            elseif ($run.databaseId) {
                $jr = Invoke-Gh @('run', 'view', [string]$run.databaseId, '--repo', $Nwo, '--json', 'jobs')
                if ($jr.Code -ne 0) { return @{ Ok = $false; Why = "could not read the run's jobs" } }
                try { $jobs = @(($jr.Out | ConvertFrom-Json).jobs) }
                catch { return @{ Ok = $false; Why = "the run's jobs are not JSON" } }
            }
            if ($null -eq $jobs -or $jobs.Count -eq 0) { return @{ Ok = $false; Why = 'the run lists no jobs' } }
            $mine = @($jobs | Where-Object { [string]$_.name -eq $jobName })
            if ($mine.Count -eq 0) { return @{ Ok = $false; Why = "no job named '$jobName' in that run" } }
            $bad = @($mine | Where-Object { [string]$_.conclusion -ne 'success' })
            if ($bad.Count -gt 0) {
                return @{ Ok = $false; Why = ("job '{0}' concluded {1}" -f $jobName, [string]$bad[0].conclusion) }
            }
            return @{ Ok = $true; Why = '' }
        }

        function Test-ContentMatches($row, [string]$sha) {
            # Every covered file, as that commit had it, hashed through this
            # script's own normalisation. Extracted with Start-Process rather
            # than a PowerShell redirect because a redirect re-encodes the
            # stream and would change the bytes being hashed.
            if ($null -eq (Get-GitOut @('cat-file', '-e', "$sha^{commit}"))) {
                # cat-file -e prints nothing on success, so a null here is
                # ambiguous; ask again in a form that answers.
                if ($null -eq (Get-GitOut @('rev-parse', '--verify', "$sha^{commit}"))) {
                    return @{ Ok = $false; Why = "commit $($sha.Substring(0, [Math]::Min(9, $sha.Length))) is not in this clone (fetch first)" }
                }
            }
            $work = Join-Path ([IO.Path]::GetTempPath()) ("guard-due-ci-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $work | Out-Null
            try {
                foreach ($rel in (Get-CoveredFiles $row)) {
                    $blobOut = Join-Path $work 'blob.bin'
                    $errOut = Join-Path $work 'blob.err'
                    $pathInGit = $rel.Replace('\', '/')
                    $proc = Start-Process -FilePath 'git' -PassThru -Wait -NoNewWindow `
                        -ArgumentList @('-C', $Repo, 'show', "${sha}:${pathInGit}") `
                        -RedirectStandardOutput $blobOut -RedirectStandardError $errOut
                    if ($proc.ExitCode -ne 0) {
                        return @{ Ok = $false; Why = "$pathInGit did not exist at that commit" }
                    }
                    if ((Get-NormalizedFileHash $blobOut) -ne (Get-NormalizedHash $rel)) {
                        return @{ Ok = $false; Why = "$pathInGit differs from the version that run built" }
                    }
                }
                return @{ Ok = $true; Why = '' }
            }
            finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        }

        $failed = 0
        foreach ($row in $ciRows) {
            $ev = $row.CiEvidence
            $cands = @($runs | Where-Object {
                    [string]$_.workflowName -eq [string]$ev.Workflow -and
                    [string]$_.status -eq 'completed' -and
                    [string]$_.conclusion -eq 'success'
                })
            if ($cands.Count -eq 0) {
                "CI EVIDENCE NONE {0}: no successful '{1}' run on {2}" -f $row.Name, $ev.Workflow, $branch
                $failed++
                continue
            }
            $stamped = $false
            $reasons = @()
            foreach ($run in $cands) {
                $sha = [string]$run.headSha
                if (-not $sha) { continue }
                $short = $sha.Substring(0, [Math]::Min(9, $sha.Length))
                $jobOk = Test-JobGreen $run ([string]$ev.Job)
                if (-not $jobOk.Ok) { $reasons += ("{0}: {1}" -f $short, $jobOk.Why); continue }
                $contentOk = Test-ContentMatches $row $sha
                if (-not $contentOk.Ok) { $reasons += ("{0}: {1}" -f $short, $contentOk.Why); continue }
                $prov = [ordered]@{
                    source     = 'ci'
                    ciWorkflow = [string]$ev.Workflow
                    ciJob      = [string]$ev.Job
                    ciSha      = $sha
                    ciRun      = [string]$run.url
                }
                $w = Write-Stamp $row $prov
                if ($w.Written) {
                    "STAMPED FROM CI {0} ({1} files) <- {2} {3} at {4}" -f $row.Name, @($w.Files).Count, $ev.Workflow, $ev.Job, $short
                    if ($run.url) { "  run: {0}" -f [string]$run.url }
                } else {
                    "STAMP UNCHANGED {0} (already stamped from this run)" -f $row.Name
                }
                $stamped = $true
                break
            }
            if (-not $stamped) {
                "CI EVIDENCE REJECTED {0}: no successful '{1}' run proves the code on disk" -f $row.Name, $ev.Job
                foreach ($why in @($reasons | Select-Object -First 5)) { "    $why" }
                "  (the covered files must be exactly what that run built; push this code and let CI answer)"
                $failed++
            }
        }
        exit ([int]($failed -gt 0))
    }

    'check' {
        $states = @(foreach ($row in $rows) { Get-GuardState $row })
        # The table's own integrity, before its verdicts (T1227): a row whose
        # coverage names a path that cannot match is reporting on less code than
        # it says it does, and every CURRENT line it prints afterwards is worth
        # correspondingly less.
        $faults = @(Get-TableFaults $rows)
        if ($Json) {
            # An array, always - a single-row table must not collapse to an object.
            ConvertTo-Json -Depth 6 -InputObject @($states)
            # The faults go to the error stream so the object stream stays valid
            # JSON for whoever parses it, and still reach a caller that merges
            # the two (2>&1, which is how the acceptance harness reads it).
            foreach ($line in (Write-TableFaults $faults)) { [Console]::Error.WriteLine($line) }
            exit ([int]((@($states | Where-Object { $_.Kind -eq 'due' }).Count + $faults.Count) -gt 0))
        }
        Write-TableFaults $faults
        $due = $faults.Count
        foreach ($s in $states) {
            if ($s.Kind -eq 'n/a') {
                "GUARD N/A {0}: nothing in this tree matches its coverage" -f $s.Name
                continue
            }
            if ($s.Kind -eq 'current') {
                $stampedAt = if ($s.StampedAt) { $s.StampedAt.Substring(0, [Math]::Min(10, $s.StampedAt.Length)) } else { '?' }
                # A stamp CI wrote says so, because "proved on the build machine"
                # and "proved here" are different sentences and the reader of a
                # green line is entitled to know which one they are reading.
                if ($s.StampedSource -eq 'ci') {
                    "GUARD CURRENT {0} ({1} files, stamped {2} from CI run {3})" -f $s.Name, @($s.Files).Count, $stampedAt, $s.StampedCiUrl
                    continue
                }
                # `from <sha>` is where the stamp was taken, not what it holds -
                # a green run over uncommitted work stamps the tree it saw, and
                # the sha it names predates that content (T1164). Say so, so the
                # line cannot be read as the gate having missed a change.
                $wip = @($s.StampedUncommitted).Count
                "GUARD CURRENT {0} ({1} files, stamped {2}{3}{4})" -f $s.Name, @($s.Files).Count, $stampedAt,
                    $(if ($s.StampedCommit) { " from $($s.StampedCommit)" } else { '' }),
                    $(if ($wip -gt 0) { " +$wip uncommitted" } else { '' })
                continue
            }
            # An advisory row (T1189) is reported in the same breath as every
            # other and counted against nothing: its subject is a question this
            # box cannot answer, and its enforcement lives elsewhere. The word
            # is in the line so a reader can never mistake one for a gate that
            # let something through.
            $tag = if ($s.Advisory) { ' (advisory)' } else { $due++; '' }
            if ($s.Reason -eq 'no-stamp') {
                "GUARD DUE{0} {1}: no stamp - {2} has never recorded a green run over this code" -f $tag, $s.Name, $s.Script
            } else {
                "GUARD DUE{0} {1}: {2} has not been run since these changed:" -f $tag, $s.Name, $s.Script
                foreach ($f in $s.Findings) { "    {0,-8} {1}" -f $f.Kind, $f.Path }
            }
            # RunArgs is how a row says "this harness needs more than its bare
            # name to clear ME" - the packaging row wants -RequireDocker, which
            # turns the Docker skips into failures so a run that cannot clear it
            # says so instead of reporting ALL PASS and leaving it due.
            "  run: powershell -NoProfile -File {0}{1}" -f $s.Script,
                $(if ($s.RunArgs) { " $($s.RunArgs)" } else { '' })
            # The second remedy, for a row whose evidence CI can produce and this
            # box cannot: name it, or the only route a reader knows about is the
            # one that does not work here.
            if ($s.CiGuard) {
                "  or, once the build machine has gone green over this exact code: powershell -NoProfile -File scripts\guard-due.ps1 stamp-ci -Guard {0}" -f $s.Name
            }
        }
        exit ([int]($due -gt 0))
    }
}
