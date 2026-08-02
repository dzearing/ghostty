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

$taskScript = Join-Path $Repo 'scripts\parity-tasks.ps1'
$realDir = Join-Path $Repo 'docs\design\windows-parity-tasks'
$fixture = Join-Path $env:TEMP "ghoztty-parity-seat-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Run parity-tasks.ps1 against the fixture dir; return @{ Code; Out }.
function Task-Run {
    param([string[]]$CmdArgs, [string]$Dir = $fixture)
    $out = & powershell -NoProfile -File $taskScript @CmdArgs -TaskDir $Dir 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

# Write one fixture task file. $SeatLine is emitted verbatim, so passing ''
# reproduces a pre-T344 file (no seat field at all).
function New-FixtureTask {
    param([string]$Id, [string]$Status = 'todo', [string]$SeatLine = '', [string]$Deps = '[]')
    $lines = @(
        '---'
        "id: $Id"
        ("title: " + (ConvertTo-Json "fixture $Id" -Compress))
        'phase: "K"'
        "deps: $Deps"
        ("status: " + (ConvertTo-Json $Status -Compress))
        'commits: []'
    )
    if ($SeatLine) { $lines += $SeatLine }
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
Assert 'list reports T1 as win' ($r.Out -match '(?m)^T1\s+todo\s+K\s+win\b')

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

# --- teardown ---------------------------------------------------------------
if (Test-Path $fixture) { Remove-Item -Recurse -Force $fixture }

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
