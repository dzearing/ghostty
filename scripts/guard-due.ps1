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
    [switch]$Json
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
            'test\win32\go-loop-guard.ps1'
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
            'test\win32\upgrade-staleness.ps1'
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
    [pscustomobject]@{
        Name   = 'release-artifacts'
        Script = 'test\win32\release-artifacts.ps1'
        Stamp  = 'test\win32\release-artifacts.stamp.json'
        Covers = @(
            '.github\workflows\release-windows.yml',
            '.github\workflows\fork-ci.yml',
            'dist\windows-installer\build-release-artifacts.sh',
            'dist\windows-installer\install-msitools.sh',
            'dist\windows-installer\build-msi.sh',
            'dist\windows-installer\build-portable-zip.sh',
            'scripts\publish-windows-release.ps1',
            'test\win32\release-artifacts.ps1'
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
    # The divergence inventory (T516) is merge-back planning's input: a set
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
            'test\win32\orphan-notify.ps1'
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
    # silent-ignore disease the task existed for. The row stays on args.zig
    # (the engine) rather than all of src\cli: per-verb wiring is pinned by
    # the none-lane unit tests the floor already runs.
    [pscustomobject]@{
        Name   = 'cli-unknown-flag'
        Script = 'test\win32\cli-unknown-flag.ps1'
        Stamp  = 'test\win32\cli-unknown-flag.stamp.json'
        Covers = @(
            'src\cli\args.zig',
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
            Name = $row.Name; Script = $row.Script; Stamp = $row.Stamp
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
            Name = $row.Name; Script = $row.Script; Stamp = $row.Stamp
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
        Name = $row.Name; Script = $row.Script; Stamp = $row.Stamp
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
            "  run: powershell -NoProfile -File {0}" -f $s.Script
        }
        exit ([int]($due -gt 0))
    }
}
