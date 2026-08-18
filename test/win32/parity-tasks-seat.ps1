# parity-tasks seat acceptance (tracker T344): the loop's task selector must
# never hand this box a task only the other seat can do, and must never hide
# one silently.
#
# Sections:
#   A. Back-compat: a task file with no `seat:` field is `win`, and `next`
#      returns it. (Every pre-T344 file is in this shape.)
#   B. `next` skips a `mac` todo, returns the next eligible one, and NAMES what
#      it skipped and why.
#   C. `next -Seat mac` returns that same mac task - the other seat has a queue,
#      the task did not disappear.
#   D. `any` is returned to BOTH seats.
#   E. No ready task for this seat => exit 1, and the output still lists the
#      other seat's todos.
#   F. `list` shows every seat by default; `-Seat` filters it.
#   G. `validate` rejects a seat outside the set (a typo would hide a task from
#      every seat) and passes a good one.
#   H. `new -Seat mac` writes the field; `new` without it writes `win`.
#   I. Against the REAL tracker: `validate` ALL PASS, and `next` no longer
#      returns a Mac-seat task.
#   J. `next` orders by PRIORITY before id, and an untriaged task loses to a
#      deliberate P2. `set-priority` writes the field and the reason.
#   K. PRIORITY outranks `order:` (D55, user 2026-08-12). An unplaced P0 beats
#      every positioned lower-priority task - the 2026-08-11 incident, where
#      three hand-reported P0s carrying no `order:` ranked MaxValue and sat
#      behind ~200 positioned P2s for a day. `order:` still sequences INSIDE a
#      band: a decimal injects between two same-priority neighbours without
#      renumbering, and an unparseable order reads as absent rather than as 0.
#   K2. Triage can re-prioritise and that alone moves the queue head, with no
#      renumbering. `set-priority` journals the transition (naming the old
#      priority and the reason), writes `triage-reason:`, stays silent on a
#      no-op, and honours `-NoNote` for a bulk pass.
#   L. `next -Claim` marks the picked task in-progress in the same breath;
#      plain `next` stays a read-only question.
#   M. Stale in-progress resume (2026-08-05): one agent runs the queue, so a
#      task still in-progress when `next -Claim` runs is a stale claim and is
#      handed BACK (RESUME:) instead of new work; plain `next` only reports it
#      (IN FLIGHT:). `note` appends timestamped progress-log entries; a claim
#      seeds the log; `new -Tags` writes tags and validate rejects a bogus one;
#      an in-progress task with no progress log fails validate.
#   N. Status journaling (T564): every `set-status` appends the transition to
#      the task's own progress log, preserving the OLD status verbatim - which
#      is the only place a discarded `blocked(reason)` survives. `-SourceNote`
#      names who asked, a no-op writes nothing, and `-NoNote` is the bulk
#      escape hatch.
#   O. The same, end to end through the dashboard: a POST to `/api/status`
#      carrying the button's own label lands in the file as
#      "(by dashboard: <label>)". Runs a private node server on port 7913 with
#      GHOZTTY_TASK_DIR pointed at the fixture, so the real tracker and the
#      real dashboard on 7788 are never touched. Skipped if node is absent.
#   P. Un-blocking needs evidence (T892): moving a task OUT of `blocked(...)`
#      is refused without `-SourceNote`, restates the task's `unblock:`
#      condition both in the refusal and on the way through, and leaves the
#      file untouched when it refuses. `-NoNote` keeps the bulk pass and says
#      it took it. Every other transition - claim, close, re-park - is
#      unchanged.
#
# Hermetic: sections A-H run against a fixture task dir under $env:TEMP via
# `-TaskDir`; docs\design\windows-parity-tasks\ is only ever READ (section I).
# No GUI, no foreground grab - safe on any desktop.
#
#   powershell -NoProfile -File test\win32\parity-tasks-seat.ps1
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
# Set when a section could not run at all (node absent). A run with a skipped
# section is green but not WHOLE, so it must not stamp the guard (T783's rule).
$script:skipped = $false

$taskScript = Join-Path $Repo 'scripts\parity-tasks.ps1'
$realDir = Join-Path $Repo 'docs\design\windows-parity-tasks'
$fixture = Join-Path $env:TEMP "ghoztty-parity-seat-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Run parity-tasks.ps1 against the fixture dir; return @{ Code; Out }.
function Task-Run {
    param([string[]]$CmdArgs, [string]$Dir = $fixture)
    $out = & powershell -NoProfile -File $taskScript @CmdArgs -TaskDir $Dir 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

# Write one fixture task file. $SeatLine is emitted verbatim, so passing ''
# reproduces a pre-T344 file (no seat field at all).
function New-FixtureTask {
    param(
        [string]$Id, [string]$Status = 'todo', [string]$SeatLine = '',
        [string]$Deps = '[]',
        # Emitted verbatim like $SeatLine, so '' reproduces a pre-priority file.
        [string]$PriorityLine = '',
        [string]$OrderLine = '',
        # Extra frontmatter lines, emitted verbatim after the fixed ones. Used
        # for fields only some tasks carry, e.g. `unblock:` on a parked task.
        [string[]]$ExtraLines = @()
    )
    $lines = @(
        '---'
        "id: $Id"
        ("title: " + (ConvertTo-Json "fixture $Id" -Compress))
        # `order:` and `priority:` are emitted only when asked, so the default
        # fixture is deliberately unordered and untriaged - the state most of
        # the tracker was in before the ranking pass, and the one the fallbacks
        # have to handle.
        "deps: $Deps"
        ("status: " + (ConvertTo-Json $Status -Compress))
        'commits: []'
    )
    if ($SeatLine) { $lines += $SeatLine }
    if ($PriorityLine) { $lines += $PriorityLine }
    if ($OrderLine) { $lines += $OrderLine }
    foreach ($extra in $ExtraLines) { if ($extra) { $lines += $extra } }
    $lines += @('---', '', "# $Id - fixture", '')
    $path = Join-Path $fixture "$Id.md"
    [System.IO.File]::WriteAllText($path, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding $false))
}

function Reset-Fixture {
    if (Test-Path $fixture) { Remove-Item -Recurse -Force $fixture }
    New-Item -ItemType Directory -Force $fixture | Out-Null
}

Reset-Fixture

# --- A. a file with no seat field is win -------------------------------------
'A. default seat (no "seat:" field == win)'
New-FixtureTask -Id 'T1'                              # no seat line at all
New-FixtureTask -Id 'T2' -SeatLine 'seat: "mac"'
New-FixtureTask -Id 'T3' -SeatLine 'seat: "any"'

$r = Task-Run @('next')
Assert 'next exits 0' ($r.Code -eq 0)
Assert 'next returns the seat-less task T1' ($r.Out -match 'NEXT: T1\b')
Assert 'next reports the seat it resolved to' ($r.Out -match 'seat=win')

$r = Task-Run @('list')
Assert 'list shows a Seat column' ($r.Out -match 'Seat')
# Columns are Ord, Id, Pri, Status, Seat; unset shows '--' in both numeric ones.
Assert 'list reports T1 as win' ($r.Out -match '(?m)^\s*--\s+T1\s+--\s+todo\s+win\b')

# --- B. next skips mac, loudly ----------------------------------------------
""
"B. next skips a mac todo and names it"
& powershell -NoProfile -File $taskScript set-status T1 -Status done -TaskDir $fixture | Out-Null

$r = Task-Run @('next')
Assert 'next exits 0 with T2(mac) at the head' ($r.Code -eq 0)
Assert 'next skips T2 and returns T3' ($r.Out -match 'NEXT: T3\b')
Assert 'next says one todo was skipped for another seat' ($r.Out -match 'Skipped 1 todo\(s\) for another seat')
Assert 'next names T2 and its seat' ($r.Out -match 'T2\(mac\)')
Assert 'next does not silently drop it' ($r.Out -match 'this seat=win')

# --- C. the other seat has its own queue ------------------------------------
""
"C. next -Seat mac returns the mac task"
$r = Task-Run @('next', '-Seat', 'mac')
Assert 'next -Seat mac exits 0' ($r.Code -eq 0)
Assert 'next -Seat mac returns T2' ($r.Out -match 'NEXT: T2\b')
Assert 'next -Seat mac reports seat=mac' ($r.Out -match 'seat=mac')

# --- D. any belongs to both seats -------------------------------------------
""
'D. an "any" task is returned to both seats'
$r = Task-Run @('next', '-Seat', 'mac')
Assert 'mac seat skipped nothing of its own' ($r.Out -notmatch 'T3\(any\)')
& powershell -NoProfile -File $taskScript set-status T2 -Status done -TaskDir $fixture | Out-Null
$r = Task-Run @('next', '-Seat', 'mac')
Assert 'mac seat gets the any task when its own queue is empty' ($r.Out -match 'NEXT: T3\b')
$r = Task-Run @('next')
Assert 'win seat gets the same any task' ($r.Out -match 'NEXT: T3\b')

# --- E. nothing for this seat => exit 1, other seat still listed -------------
""
"E. no ready task for this seat"
Reset-Fixture
New-FixtureTask -Id 'T1' -SeatLine 'seat: "mac"'
New-FixtureTask -Id 'T2' -SeatLine 'seat: "mac"'

$r = Task-Run @('next')
Assert 'next exits 1 when only the other seat has work' ($r.Code -eq 1)
Assert 'the message names this seat' ($r.Out -match 'No ready task for seat=win')
Assert 'the other seat''s todos are still printed' ($r.Out -match 'Other seat:.*T1\(mac\).*T2\(mac\)')
$r = Task-Run @('next', '-Seat', 'mac')
Assert 'the mac seat still finds them' ($r.Out -match 'NEXT: T1\b')

# --- F. list filtering ------------------------------------------------------
""
"F. list -Seat filters, list alone does not"
Reset-Fixture
New-FixtureTask -Id 'T1'
New-FixtureTask -Id 'T2' -SeatLine 'seat: "mac"'
New-FixtureTask -Id 'T3' -SeatLine 'seat: "any"'

$r = Task-Run @('list')
Assert 'list defaults to every seat (3 tasks)' ($r.Out -match '3 task\(s\)')
$r = Task-Run @('list', '-Seat', 'win')
Assert 'list -Seat win yields win + any (2)' ($r.Out -match '2 task\(s\)')
Assert 'list -Seat win excludes T2' ($r.Out -notmatch '(?m)^T2\s')
$r = Task-Run @('list', '-Seat', 'mac')
Assert 'list -Seat mac yields mac + any (2)' ($r.Out -match '2 task\(s\)')
Assert 'list -Seat mac excludes T1' ($r.Out -notmatch '(?m)^T1\s')

# --- G. validate guards the field -------------------------------------------
""
"G. validate rejects a bogus seat"
$r = Task-Run @('validate')
Assert 'a clean fixture validates' ($r.Code -eq 0 -and $r.Out -match 'ALL PASS')

New-FixtureTask -Id 'T4' -SeatLine 'seat: "windows"'   # plausible typo
$r = Task-Run @('validate')
Assert 'a bogus seat fails validate' ($r.Code -eq 1)
Assert 'validate names the task and the value' ($r.Out -match "ODD SEAT: T4 = 'windows'")
$r = Task-Run @('next')
Assert 'the typo does not steal the head of the queue' ($r.Out -match 'NEXT: T1\b')
Assert 'and next reports it as skipped rather than dropping it' ($r.Out -match 'T4\(windows\)')
Remove-Item (Join-Path $fixture 'T4.md') -Force

# --- H. new writes the field ------------------------------------------------
""
"H. new -Seat writes the field"
$r = Task-Run @('new', '-Title', 'a mac thing', '-Seat', 'mac')
Assert 'new -Seat mac exits 0' ($r.Code -eq 0)
$macFile = Join-Path $fixture 'T4.md'
Assert 'new allocated T4' (Test-Path $macFile)
$txt = [System.IO.File]::ReadAllText($macFile)
Assert 'the created file carries seat: "mac"' ($txt -match '(?m)^seat: "mac"$')

$r = Task-Run @('new', '-Title', 'a win thing')
$winFile = Join-Path $fixture 'T5.md'
Assert 'new without -Seat defaults to win' (Test-Path $winFile)
$txt = [System.IO.File]::ReadAllText($winFile)
Assert 'the created file carries seat: "win"' ($txt -match '(?m)^seat: "win"$')
$r = Task-Run @('validate')
Assert 'both created files validate' ($r.Code -eq 0)

# --- I. the real tracker ----------------------------------------------------
""
"I. the real tracker"
$r = Task-Run @('validate') $realDir
Assert 'the real tracker validates' ($r.Code -eq 0 -and $r.Out -match 'ALL PASS')

$r = Task-Run @('next') $realDir
Assert 'next on the real tracker exits 0' ($r.Code -eq 0)
Assert 'next no longer returns the Mac-side T30' ($r.Out -notmatch 'NEXT: T30\b')
Assert 'next returns a task this box can do' ($r.Out -match 'seat=(win|any)')
Assert 'and it says which mac todos it passed over' ($r.Out -match 'another seat.*T30\(mac\)')

$r = Task-Run @('next', '-Seat', 'mac') $realDir
Assert 'the Mac seat gets T30 as its head' ($r.Out -match 'NEXT: T30\b')

# --- J. priority outranks id ------------------------------------------------
""
"J. next orders by priority before id"
Reset-Fixture
# Deliberately inverted: the lowest id is the LEAST important, so an ordering
# that still works in id order cannot pass this section by accident.
New-FixtureTask -Id 'T1' -PriorityLine 'priority: "P2"'
New-FixtureTask -Id 'T2'                                   # untriaged
New-FixtureTask -Id 'T3' -PriorityLine 'priority: "P1"'
New-FixtureTask -Id 'T4' -PriorityLine 'priority: "P0"'
New-FixtureTask -Id 'T5' -PriorityLine 'priority: "P0"'

$r = Task-Run @('next')
Assert 'next takes a P0 over three lower ids' ($r.Out -match 'NEXT: T4\b')
Assert 'next reports the priority it picked on' ($r.Out -match 'priority=P0')

# Id is the tiebreaker INSIDE a band, so removing T4 must yield T5 - not T1.
Remove-Item (Join-Path $fixture 'T4.md') -Force
$r = Task-Run @('next')
Assert 'id still breaks ties inside a band' ($r.Out -match 'NEXT: T5\b')

# An untriaged task sorts AFTER P2: it must not outrank a deliberate P2.
Remove-Item (Join-Path $fixture 'T5.md') -Force
Remove-Item (Join-Path $fixture 'T3.md') -Force
$r = Task-Run @('next')
Assert 'an untriaged task does not outrank a P2' ($r.Out -match 'NEXT: T1\b')
Assert 'and next names the untriaged one it passed over' ($r.Out -notmatch 'NEXT: T2\b')

$r = Task-Run @('list', '-Priority', 'P2')
Assert 'list -Priority filters to that band' ($r.Out -match '1 task\(s\)')
Assert 'list shows the Pri column value' ($r.Out -match '(?m)^\s*--\s+T1\s+P2\s+todo\b')

$r = Task-Run @('set-priority', 'T2', '-Priority', 'P0', '-Summary', 'it wedges the app')
Assert 'set-priority exits 0' ($r.Code -eq 0)
$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T2.md'))
Assert 'set-priority writes the field on a file that lacked one' ($txt -match '(?m)^priority: "P0"$')
Assert 'set-priority records why' ($txt -match '(?m)^triage-reason: "it wedges the app"$')
$r = Task-Run @('next')
Assert 'and the newly-ranked task takes the head' ($r.Out -match 'NEXT: T2\b')
Assert 'next prints the reason for the rank' ($r.Out -match 'why: it wedges the app')

$r = Task-Run @('validate')
Assert 'a fixture with priorities still validates' ($r.Code -eq 0)

# Read the id back out of `new`'s own output rather than predicting it: ids are
# allocated from the highest one present, and this section has been deleting
# files. A hardcoded id makes ReadAllText throw, $txt keep its PREVIOUS value,
# and the assertion pass against the wrong file.
function New-AndRead {
    param([string[]]$ExtraArgs)
    $res = Task-Run (@('new', '-Title', 'a fixture thing') + $ExtraArgs)
    if ($res.Out -notmatch 'created (T\d+[a-z]?\d*):') { return @{ Code = $res.Code; Text = '' } }
    return @{ Code = $res.Code; Text = [System.IO.File]::ReadAllText((Join-Path $fixture ($Matches[1] + '.md'))) }
}
$n = New-AndRead @('-Priority', 'P0')
Assert 'new -Priority exits 0' ($n.Code -eq 0)
Assert 'new -Priority writes the field' ($n.Text -match '(?m)^priority: "P0"$')
$n = New-AndRead @()
Assert 'new without -Priority defaults to P1' ($n.Text -match '(?m)^priority: "P1"$')

# --- K. PRIORITY outranks order (D55) ----------------------------------------
""
"K. next orders by priority before order"
Reset-Fixture
# Inverted on purpose: the BEST priority gets the WORST order, and an UNPLACED
# P0 sits against a well-placed P2. That second pair is the whole incident this
# rule exists for - on 2026-08-11 three P0s the user reported by hand carried no
# `order:`, so they ranked MaxValue and sat behind ~200 positioned P2s for a
# full day. A sort that still consulted order first cannot pass this section by
# accident.
New-FixtureTask -Id 'T1' -PriorityLine 'priority: "P0"' -OrderLine 'order: 50'
New-FixtureTask -Id 'T2' -PriorityLine 'priority: "P2"' -OrderLine 'order: 2'
New-FixtureTask -Id 'T3' -PriorityLine 'priority: "P1"' -OrderLine 'order: 1'
New-FixtureTask -Id 'T4' -PriorityLine 'priority: "P0"'          # unordered

$r = Task-Run @('next')
Assert 'next takes a P0 at order 50 over a P1 at order 1' ($r.Out -match 'NEXT: T1\b')
Assert 'next reports the priority it picked on' ($r.Out -match 'priority=P0\b')
Assert 'the P1 at order 1 no longer heads the queue' ($r.Out -notmatch 'NEXT: T3\b')

$r = Task-Run @('list')
Assert 'list is printed in queue order: both P0s, then P1, then P2' (
    $r.Out -match '(?s)T1.*T4.*T3.*T2')

# The regression that started this: an unplaced P0 must still outrank every
# positioned lower-priority task. Removing the only ordered P0 leaves T4, which
# has no `order:` at all.
$r = Task-Run @('set-status', 'T1', '-Status', 'done')
$r = Task-Run @('next')
Assert 'an UNORDERED P0 beats a positioned P1 and P2' ($r.Out -match 'NEXT: T4\b')
Assert 'and it reports as unordered rather than inventing a position' ($r.Out -match 'order=unordered')

# `order:` keeps its job INSIDE the band: a decimal injects between two
# same-priority neighbours without renumbering, which is the whole reason it is
# fractional. It just cannot cross a priority boundary any more.
New-FixtureTask -Id 'T6' -PriorityLine 'priority: "P2"' -OrderLine 'order: 3'
$r = Task-Run @('set-order', 'T6', '-Order', '1.5')
Assert 'set-order accepts a decimal' ($r.Code -eq 0)
$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T6.md'))
Assert 'set-order writes it invariantly (a dot, never a comma)' ($txt -match '(?m)^order: 1\.5$')
$r = Task-Run @('list')
Assert 'the injected P2 lands ahead of its same-band neighbour' ($r.Out -match '(?s)T6.*T2')
Assert 'but still behind every higher-priority task' ($r.Out -match '(?s)T4.*T3.*T6')

# A garbled order must not read as 0 and seize the head of its band.
New-FixtureTask -Id 'T5' -PriorityLine 'priority: "P2"' -OrderLine 'order: banana'
$r = Task-Run @('next')
Assert 'an unparseable order is treated as absent, not as 0' ($r.Out -match 'NEXT: T4\b')
$r = Task-Run @('validate')
Assert 'a fixture with orders validates' ($r.Code -eq 0)

# --- K2. triage can re-prioritise, and it moves the queue ---------------------
""
"K2. set-priority reassesses the queue and journals the change"
Reset-Fixture
New-FixtureTask -Id 'T1' -PriorityLine 'priority: "P2"' -OrderLine 'order: 1'
New-FixtureTask -Id 'T2' -PriorityLine 'priority: "P2"' -OrderLine 'order: 2'

$r = Task-Run @('next')
Assert 'the well-placed P2 heads the queue to begin with' ($r.Out -match 'NEXT: T1\b')

# The flexibility the user asked for: triage decides T2 matters more, and that
# alone must change what comes next - with no renumbering of anything.
$r = Task-Run @('set-priority', 'T2', '-Priority', 'P0', '-Summary', 'user reported it by hand')
Assert 'set-priority succeeds' ($r.Code -eq 0)
Assert 'and names what it changed FROM' ($r.Out -match 'was P2')
$r = Task-Run @('next')
Assert 're-prioritising alone moves the head of the queue' ($r.Out -match 'NEXT: T2\b')
Assert 'even though its order is still worse' ($r.Out -match 'order=2\b')

$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T2.md'))
Assert 'the change is journalled in the progress log' ($txt -match 'priority: P2 -> P0')
Assert 'with the reason it was given' ($txt -match 'user reported it by hand')
Assert 'and the triage reason is written to frontmatter' ($txt -match '(?m)^triage-reason:')

# A no-op re-triage must not write an entry saying P0 -> P0; a bulk
# normalisation pass would otherwise journal every task on the board.
$before = [System.IO.File]::ReadAllText((Join-Path $fixture 'T2.md'))
$r = Task-Run @('set-priority', 'T2', '-Priority', 'P0')
$after = [System.IO.File]::ReadAllText((Join-Path $fixture 'T2.md'))
Assert 'a no-op re-priority writes no journal entry' ($before -eq $after)

# And the bulk escape hatch, same as set-status has.
$r = Task-Run @('set-priority', 'T2', '-Priority', 'P1', '-NoNote')
$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T2.md'))
Assert '-NoNote suppresses the journal entry' ($txt -notmatch 'priority: P0 -> P1')
Assert 'but the field itself still changed' ($txt -match '(?m)^priority: "P1"$')

# --- L. next -Claim marks the task -------------------------------------------
""
"L. next -Claim marks the task in-progress"
# Its own fixture, deliberately. L and M used to inherit whatever K happened to
# leave behind, so re-stating K's rule broke both of them nine assertions deep -
# in a file whose whole subject is that the queue must not depend on invisible
# state. T3 heads this queue because it is the only P0.
Reset-Fixture
New-FixtureTask -Id 'T3' -PriorityLine 'priority: "P0"' -OrderLine 'order: 1'
New-FixtureTask -Id 'T1' -PriorityLine 'priority: "P1"' -OrderLine 'order: 50'
New-FixtureTask -Id 'T2' -PriorityLine 'priority: "P1"' -OrderLine 'order: 2'
New-FixtureTask -Id 'T4' -PriorityLine 'priority: "P1"'          # unordered
New-FixtureTask -Id 'T5' -PriorityLine 'priority: "P2"' -OrderLine 'order: 3'
$r = Task-Run @('next')
Assert 'the only P0 heads this fixture' ($r.Out -match 'NEXT: T3\b')
$r = Task-Run @('next')
Assert 'next alone does NOT change status' (
    [System.IO.File]::ReadAllText((Join-Path $fixture 'T3.md')) -match '(?m)^status: "todo"$')

$r = Task-Run @('next', '-Claim')
Assert 'next -Claim still names the task' ($r.Out -match 'NEXT: T3\b')
Assert 'and says it claimed it' ($r.Out -match 'CLAIMED: T3')
Assert 'the file is now in-progress' (
    [System.IO.File]::ReadAllText((Join-Path $fixture 'T3.md')) -match '(?m)^status: "in-progress"$')
$r = Task-Run @('next')
Assert 'a claimed task is no longer offered' ($r.Out -notmatch 'NEXT: T3\b')

# --- M. stale in-progress resume + progress log + tags ------------------------
""
"M. stale resume, note, tags"
# From section L, T3 is in-progress (claimed) and T4/T2/T1/T5 are todo. A new
# turn's `next -Claim` must hand T3 BACK rather than claim fresh work.
$r = Task-Run @('next', '-Claim')
Assert 'next -Claim resumes the stale in-progress task' ($r.Code -eq 0 -and $r.Out -match 'RESUME: T3\b')
Assert 'resume does not claim new work' ($r.Out -notmatch 'CLAIMED:')
Assert 'resume says how to reassess' ($r.Out -match 'Progress log' -and $r.Out -match 'git status')
$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T3.md'))
Assert 'the claim seeded a progress log' ($txt -match '(?m)^## Progress log\s*$')
Assert 'the resume appended its own entry' ($txt -match 'stale in-progress claim picked up')

# Plain `next` stays read-only: it reports the in-flight task and still
# answers with the queue head.
$r = Task-Run @('next')
Assert 'plain next reports IN FLIGHT' ($r.Out -match 'IN FLIGHT: T3\b')
Assert 'plain next still answers with a todo' ($r.Out -match 'NEXT: T\d')

# `note` appends a timestamped entry, with an optional session stamp.
$r = Task-Run @('note', 'T3', '-Text', 'built the thing; validating next', '-Session', 'sess-42')
Assert 'note exits 0' ($r.Code -eq 0)
$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T3.md'))
Assert 'note appended the text' ($txt -match 'built the thing; validating next')
Assert 'note stamped the session' ($txt -match '\[session sess-42\]')
Assert 'entries are timestamped' ($txt -match '(?m)^- \d{4}-\d{2}-\d{2} \d{2}:\d{2}')
# Entries land inside the section, in chronological order.
Assert 'the new entry follows the claim entry' (
    $txt.IndexOf('built the thing') -gt $txt.IndexOf('claimed; work starting'))

# An in-progress task with no progress log fails validate.
New-FixtureTask -Id 'T90' -Status 'in-progress'
$r = Task-Run @('validate')
Assert 'in-progress without a progress log fails validate' ($r.Code -eq 1 -and $r.Out -match 'NO PROGRESS LOG: T90')
Remove-Item (Join-Path $fixture 'T90.md') -Force

# Tags: `new -Tags` writes the field, an unknown tag is refused at mint time,
# and a bogus tag in a file fails validate.
$n = New-AndRead @('-Tags', 'fix,polish')
Assert 'new -Tags exits 0' ($n.Code -eq 0)
Assert 'new -Tags writes the list' ($n.Text -match '(?m)^tags: \["fix", "polish"\]$')
Assert 'new scaffolds validation criteria' ($n.Text -match '(?m)^## Validation criteria$')
$r = Task-Run @('new', '-Title', 'bogus tag', '-Tags', 'testing')
Assert 'an unknown tag is refused at mint time' ($r.Code -ne 0 -or $r.Out -match 'Unknown tag')
New-FixtureTask -Id 'T91'
$p91 = Join-Path $fixture 'T91.md'
$t91 = [System.IO.File]::ReadAllText($p91) -replace '(?m)^commits: \[\]$', ("commits: []`ntags: [""banana""]")
[System.IO.File]::WriteAllText($p91, $t91, (New-Object System.Text.UTF8Encoding $false))
$r = Task-Run @('validate')
Assert 'a bogus tag in a file fails validate' ($r.Code -eq 1 -and $r.Out -match "ODD TAG: T91 = 'banana'")
Remove-Item $p91 -Force
$r = Task-Run @('validate')
Assert 'the fixture is clean again' ($r.Code -eq 0)

# --- N. every status change journals itself (T564) ---------------------------
""
"N. set-status journals the transition"
Reset-Fixture
New-FixtureTask -Id 'T1'          # todo, and deliberately with NO progress log

function Get-LogLines {
    param([string]$Id = 'T1')
    $t = [System.IO.File]::ReadAllText((Join-Path $fixture "$Id.md"))
    return @([regex]::Matches($t, '(?m)^- \d{4}-\d{2}-\d{2} \d{2}:\d{2}'))
}

$r = Task-Run @('set-status', 'T1', '-Status', 'blocked(waiting on a crash to recur)')
Assert 'set-status exits 0' ($r.Code -eq 0)
$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T1.md'))
Assert 'a file with no progress log gains one' ($txt -match '(?m)^## Progress log\s*$')
Assert 'the entry names both ends of the transition' (
    $txt -match 'status: todo -> blocked\(waiting on a crash to recur\)')
Assert 'set-status says out loud that it journaled' ($r.Out -match 'journaled: status: todo ->')

# The T443 case exactly: the dashboard's button writes a BARE todo, so the
# reason only survives if the note captured the old status verbatim.
$r = Task-Run @('set-status', 'T1', '-Status', 'todo', '-SourceNote', 'dashboard: Mark unblocked', '-Session', 'sess-7')
$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T1.md'))
Assert 'the discarded blocked(reason) survives in the log' (
    $txt -match 'status: blocked\(waiting on a crash to recur\) -> todo')
Assert 'the note names who asked for it' ($txt -match '\(by dashboard: Mark unblocked\)')
Assert 'and stamps the session' ($txt -match '\[session sess-7\]')
Assert 'two transitions, two entries' ((Get-LogLines).Count -eq 2)

# A no-op is not a transition: re-running the same status must not pad the log.
$r = Task-Run @('set-status', 'T1', '-Status', 'todo')
Assert 'setting the same status again exits 0' ($r.Code -eq 0)
Assert 'and writes no entry' ((Get-LogLines).Count -eq 2)

# -NoNote is the bulk-normalisation escape hatch, and nothing else.
$r = Task-Run @('set-status', 'T1', '-Status', 'done', '-Commit', 'abc1234', '-NoNote')
$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T1.md'))
Assert '-NoNote still applies the status' ($txt -match '(?m)^status: "done"$')
Assert '-NoNote still records the commit' ($txt -match '(?m)^commits: \["abc1234"\]$')
Assert '-NoNote suppresses the entry' ((Get-LogLines).Count -eq 2)

# A commit-carrying transition names the commit in the log, so `done` is
# traceable to its evidence from the task file alone.
$r = Task-Run @('set-status', 'T1', '-Status', 'todo')
$r = Task-Run @('set-status', 'T1', '-Status', 'done', '-Commit', 'def5678')
$txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T1.md'))
Assert 'a done transition carries its commit' ($txt -match 'status: todo -> done \[commit def5678\]')

$r = Task-Run @('validate')
Assert 'a journaled fixture still validates' ($r.Code -eq 0)

# --- O. the dashboard button's label reaches the file (T564) -----------------
""
"O. dashboard /api/status writes the receipt end to end"
$node = (Get-Command node -ErrorAction SilentlyContinue)
if (-not $node) {
    Assert 'SKIP: node is not on PATH, so the server half cannot be exercised' $true
    $script:skipped = $true
}
else {
    Reset-Fixture
    New-FixtureTask -Id 'T1' -Status 'blocked(armed watch - needs an occurrence)'
    # A port of its own: 7788 is very likely serving the real tracker right now,
    # and this section must never write into it.
    $port = 7913
    $dash = Join-Path $Repo 'scripts\task-dashboard.js'
    $env:GHOZTTY_TASK_DIR = $fixture
    # persistence: n/a - this starts node (the dashboard server), not ghoztty.
    $srv = Start-Process -FilePath $node.Source `
        -ArgumentList @($dash, '--port', "$port") `
        -PassThru -WindowStyle Hidden
    # Cache the handle before the child can exit, or PS 5.1 hands back an empty
    # ExitCode and a dead server reads as a healthy one (the T443 soak lesson).
    $null = $srv.Handle
    try {
        $up = $false
        foreach ($i in 1..40) {
            try {
                $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/data" -TimeoutSec 5
                $up = $true; break
            }
            catch { Start-Sleep -Milliseconds 250 }
        }
        Assert 'the dashboard server came up on its own port' $up
        if ($up) {
            $body = @{ id = 'T1'; status = 'todo'; source = 'is unblocked and back in the queue' } | ConvertTo-Json
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/status" -Method Post `
                -ContentType 'application/json' -Body $body -TimeoutSec 30
            Assert 'the POST is accepted' ($null -ne $resp)
            $txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T1.md'))
            Assert 'the status moved' ($txt -match '(?m)^status: "todo"$')
            Assert 'the blocked reason survives in the log' (
                $txt -match 'status: blocked\(armed watch - needs an occurrence\) -> todo')
            Assert 'the log names the dashboard' ($txt -match '\(by dashboard: is unblocked and back in the queue\)')

            # A request with no source still leaves a receipt: "someone clicked
            # something here" beats silence, which is the whole defect.
            $body = @{ id = 'T1'; status = 'in-progress' } | ConvertTo-Json
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/status" -Method Post `
                -ContentType 'application/json' -Body $body -TimeoutSec 30
            $txt = [System.IO.File]::ReadAllText((Join-Path $fixture 'T1.md'))
            Assert 'a source-less POST still says it came from the dashboard' (
                $txt -match '\(by dashboard: status button\)')
        }
    }
    finally {
        if ($srv -and -not $srv.HasExited) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item Env:\GHOZTTY_TASK_DIR -ErrorAction SilentlyContinue
    }
}

# --- P. un-blocking needs evidence (T892) ------------------------------------
""
"P. set-status gates the way OUT of blocked(...)"
Reset-Fixture
$unblockText = 'powercfg PROCTHROTTLEMAX must read 99 (boost off) before this comes back.'
New-FixtureTask -Id 'T1' -Status 'blocked(armed watch - needs an occurrence)' `
    -ExtraLines @(("unblock: " + (ConvertTo-Json $unblockText -Compress)))

function Get-FixtureText { param([string]$Id = 'T1') [System.IO.File]::ReadAllText((Join-Path $fixture "$Id.md")) }
function Get-PLines { param([string]$Id = 'T1') @([regex]::Matches((Get-FixtureText $Id), '(?m)^- \d{4}-\d{2}-\d{2} \d{2}:\d{2}')) }

# The 2026-08-16 09:26 shape exactly: a bare flip out of blocked, with nothing
# said about the condition and nobody having checked it.
$r = Task-Run @('set-status', 'T1', '-Status', 'todo')
Assert 'a bare un-block FAILS' ($r.Code -ne 0)
Assert 'and says why in words' ($r.Out -match 'un-blocking needs evidence')
Assert 'and restates the unblock condition' ($r.Out -match 'PROCTHROTTLEMAX must read 99')
Assert 'and names the -SourceNote it wants' ($r.Out -match '-SourceNote')
Assert 'the file is untouched: still blocked' (
    (Get-FixtureText) -match '(?m)^status: "blocked\(armed watch - needs an occurrence\)"$')
Assert 'and nothing was journaled' ((Get-PLines).Count -eq 0)

# With evidence it goes through, and the condition is echoed at the moment
# somebody claims it is satisfied.
$r = Task-Run @('set-status', 'T1', '-Status', 'todo', '-SourceNote', 'powercfg re-read: PROCTHROTTLEMAX is 99')
Assert 'an un-block WITH a source note exits 0' ($r.Code -eq 0)
Assert 'the status moved' ((Get-FixtureText) -match '(?m)^status: "todo"$')
Assert 'the receipt names what was checked' (
    (Get-FixtureText) -match '\(by powercfg re-read: PROCTHROTTLEMAX is 99\)')
Assert 'and the command echoed the condition being claimed' (
    $r.Out -match 'unblock condition you are claiming is satisfied' -and $r.Out -match 'PROCTHROTTLEMAX')

# The bulk hatch still opens, and is loud about it - same contract as
# -NoGuardDue: a flip made under it can be explained rather than excused.
$r = Task-Run @('set-status', 'T1', '-Status', 'blocked(re-parked)')
$before = (Get-PLines).Count
$r = Task-Run @('set-status', 'T1', '-Status', 'todo', '-NoNote')
Assert '-NoNote gets a bulk pass through the gate' ($r.Code -eq 0)
Assert 'and says out loud that it bypassed it' ($r.Out -match 'bypassed the un-block evidence gate')
Assert 'the status still moved' ((Get-FixtureText) -match '(?m)^status: "todo"$')
Assert 'and no receipt was written' ((Get-PLines).Count -eq $before)

# A parked task with no `unblock:` field is gated just the same - the gate is
# about the transition, not about the field being present.
New-FixtureTask -Id 'T2' -Status 'blocked(no condition recorded)'
$r = Task-Run @('set-status', 'T2', '-Status', 'todo')
Assert 'a blocked task with no unblock: is still gated' ($r.Code -ne 0)
Assert 'and the message says the condition is missing' ($r.Out -match 'records no')

# Everything that is NOT an un-block is untouched.
New-FixtureTask -Id 'T3' -Status 'todo'
$r = Task-Run @('set-status', 'T3', '-Status', 'in-progress')
Assert 'todo -> in-progress needs no source note' ($r.Code -eq 0)
$r = Task-Run @('set-status', 'T3', '-Status', 'done', '-Commit', 'abc1234')
Assert 'in-progress -> done needs no source note' ($r.Code -eq 0)
New-FixtureTask -Id 'T4' -Status 'blocked(first reason)'
$r = Task-Run @('set-status', 'T4', '-Status', 'blocked(second reason)')
Assert 'a re-park (blocked -> blocked) needs no source note' ($r.Code -eq 0)
Assert 'and still journals the transition' (
    (Get-FixtureText 'T4') -match 'status: blocked\(first reason\) -> blocked\(second reason\)')

$r = Task-Run @('validate')
Assert 'the gated fixture still validates' ($r.Code -eq 0)

# --- teardown ---------------------------------------------------------------
if (Test-Path $fixture) { Remove-Item -Recurse -Force $fixture }

# --- stamp (T783/T892) ------------------------------------------------------
# A clean green run with nothing skipped records the covered files, so
# scripts\guard-due.ps1 can answer "has anyone run this harness against
# parity-tasks.ps1 as it now stands?". Nothing in the zig lanes or the P1-P3
# floor executes the tracker CLI, so this is its only gate.
if ($script:failures -eq 0 -and -not $script:skipped) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard parity-tasks -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}
elseif ($script:skipped) {
    "  (no stamp: a section was skipped, so this run does not prove the harness ran whole)"
}

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
