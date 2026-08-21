# T229 acceptance: the shared ghoztty.log must not LOSE lines under concurrent
# writers.
#
# %LOCALAPPDATA%\ghoztty\ghoztty.log is a single sink that the GUI app, the
# agent and every one-shot `ghoztty +...` CLI invocation append to at the same
# time - on a box driving Ghoztty from scripts there are several a second. The
# old writer opened the file, seeked to end, wrote and closed. That is not an
# append: two processes that both resolve end-of-file to N both write AT N, and
# the later write silently overwrites the earlier one's bytes.
#
# Why this is a T229 assertion and not a tidy-up: the whole primary evidence for
# T229 was "the app logged nothing after the confirm", and the fix for it is a
# trail of log lines through the destructive restart. Both are worthless if the
# sink drops lines whenever something else is running. The fix is
# FILE_APPEND_DATA (main_ghostty.zig openAppendW), which Windows defines as
# placing each write at the current end of file as one operation.
#
# The oracle is line COUNT and line SHAPE, measured on the real binary:
#   - every launched process contributes its startup banner, so the total is
#     deterministic per build;
#   - a clobbered line is detectable without knowing the count: the writer only
#     ever emits lines starting with the T270 prefix and a log level, so a line
#     that does not is a line something wrote over.
#
# T270 adds the second half of the sink's contract to this script: surviving
# lines have to be READABLE, not just present. Every line carries
# `<iso-8601-utc-millis> <pid> ` ahead of the level, which is what makes the
# shared file demultiplexable by process and orderable in time - the two things
# T229's own investigation could not do. The assertions below are the ones that
# matter for that: the shape holds on EVERY line, each writer's own pid is in
# there, a pid's lines are monotonic in time, and the prefix is part of the same
# single write as its message (a prefix written separately could land after
# another process's line and split this one in half - the T229 defect, back
# again by another route).
#
# Release build only - the file sink is compiled out of Debug builds (they log
# to stderr). Hermetic: its own LOCALAPPDATA and IPC pipe suffix, and it only
# runs `+list`, which touches nothing.
#
#   powershell -NoProfile -File test\win32\log-append.ps1
#   powershell -NoProfile -File test\win32\log-append.ps1 -Exe <pre-fix exe>   # negative control
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out-release\bin\ghoztty.exe',
    [int]$Writers = 24,
    [switch]$NegativeControl
)

# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches, and a pane-launched app would otherwise hand its work to
# a respawned twin mid-test.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

$root = Join-Path $env:TEMP "ghoztty-log-append-$PID"
$saved = @{ lad = $env:LOCALAPPDATA; pipe = $env:GHOZTTY_PIPE_SUFFIX }
New-Item -ItemType Directory -Force (Join-Path $root 'ghoztty') | Out-Null
$env:LOCALAPPDATA = $root
# No server answers this suffix, so every +list fails fast and exits - the point
# is the startup banner each one writes on its way through. Per-PID (T680) so a
# leaked instance from an earlier run can never be the thing that answers.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'logappend')
# T1033: the build-mode pre-flight, answered explicitly rather than skipped.
# This script's SUBJECT is a release build - the file sink is compiled out of
# Debug - and what makes that safe is above: its own LOCALAPPDATA (so the log
# it counts is not the user's), its own pipe suffix, and a workload of nothing
# but `+list`, which opens no window and starts no agent.
Assert-GhozttyIsolatedBuild -Exe $Exe -Allow | Out-Null
$logPath = Join-Path $root 'ghoztty\ghoztty.log'
# ...and the pre-flight is itself a writer: it asks the exe for `+version`, and
# a release build logs its startup banner on the way through. Those lines would
# be counted into the per-process baseline below and then multiplied by 24,
# which reads as "23 x banner lines lost". Start the measurement from empty.
Remove-Item $logPath -Force -ErrorAction SilentlyContinue

try {

Assert "setup: exe exists" (Test-Path $Exe)

# One warm-up run alone: its line count IS the per-process contribution, so the
# expected total is derived from the binary under test rather than hard-coded
# (a build that changes its banner must not silently turn this into a no-op).
# persistence: n/a - a CLI invocation, which opens no window.
$p = Start-Process -FilePath $Exe -ArgumentList @('+list') -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $root 'warm.out') -RedirectStandardError (Join-Path $root 'warm.err')
$null = $p.Handle
$warmPid = $p.Id
$p.WaitForExit(20000) | Out-Null
Assert "premise: the release build writes to ghoztty.log at all" (Test-Path $logPath)
$perProc = @(Get-Content $logPath).Count
Say "    one process writes $perProc line(s)"
Assert "premise: a run contributes at least a few lines" ($perProc -ge 3)

Remove-Item $logPath -Force -ErrorAction SilentlyContinue

# All writers at once. Start-Process returns immediately, so they overlap.
$procs = @()
for ($i = 0; $i -lt $Writers; $i++) {
    # persistence: n/a - a CLI invocation, which opens no window.
    $procs += Start-Process -FilePath $Exe -ArgumentList @('+list') -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $root "w$i.out") -RedirectStandardError (Join-Path $root "w$i.err")
}
foreach ($q in $procs) { $null = $q.Handle }
$launched = @($procs | ForEach-Object { $_.Id })
foreach ($q in $procs) { $q.WaitForExit(60000) | Out-Null }
Start-Sleep -Milliseconds 500

$lines = @(Get-Content $logPath)
$expected = $perProc * $Writers
Say "    $Writers concurrent writers => $($lines.Count) line(s), expected $expected"

# Every line this binary emits starts with a T270 timestamp+pid prefix and then
# a std.log level. Anything else is a line that was written over - detectable
# with no knowledge of the expected count, which is what makes this a shape
# assertion and not just arithmetic.
$shape = '^(?<ts>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z) (?<pid>\d+) (debug|info|warning|error)'
$malformed = @($lines | Where-Object { $_ -notmatch $shape })
if ($malformed.Count -gt 0) {
    Say "    first malformed line: '$($malformed[0])'"
}

if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting the sink LOSES lines - a fixed build MUST fail this'
    Assert "N1 concurrent writers lose lines (inverted)" ($lines.Count -lt $expected)
} else {
    Assert "L1 no line was lost under $Writers concurrent writers" ($lines.Count -eq $expected)
    Assert "L2 no line was written over (every line carries the prefix and a log level)" ($malformed.Count -eq 0)

    # --- T270: the surviving lines are readable ------------------------------
    # Parse once; every assertion below reads this table rather than re-scanning.
    $parsed = @()
    foreach ($ln in $lines) {
        $m = [regex]::Match($ln, $shape)
        if ($m.Success) {
            $parsed += [pscustomobject]@{
                Pid   = [int]$m.Groups['pid'].Value
                Stamp = $m.Groups['ts'].Value
                Time  = [datetime]::ParseExact($m.Groups['ts'].Value, "yyyy-MM-ddTHH:mm:ss.fffZ",
                                               [cultureinfo]::InvariantCulture,
                                               [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                                               [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            }
        }
    }
    Assert "L3 every line's timestamp parses as a real UTC instant" ($parsed.Count -eq $lines.Count)

    # The point of the pid: the sink is demultiplexable. Every process we
    # launched must be nameable in the file, and nothing else may appear - a
    # stray pid would mean the field is not the writer's own.
    $seen = @($parsed | ForEach-Object { $_.Pid } | Sort-Object -Unique)
    $missing = @($launched | Where-Object { $seen -notcontains $_ })
    $extra = @($seen | Where-Object { $launched -notcontains $_ -and $_ -ne $warmPid })
    Say "    $($seen.Count) distinct pid(s) in the file for $Writers writer(s)"
    Assert "L4 every launched writer's own pid appears in the file" ($missing.Count -eq 0)
    Assert "L5 no pid appears that did not write this file" ($extra.Count -eq 0)
    Assert "L6 the file demultiplexes to one process per pid" ($seen.Count -eq $Writers)

    # Ordering: within a pid the stamps must never go backwards. Across pids
    # they need not (two processes really do interleave), so this is the
    # strongest true claim - and it is the one that makes "did it die or sit
    # there for twenty minutes" answerable.
    $nonMonotonic = 0
    foreach ($group in ($parsed | Group-Object Pid)) {
        $prev = $null
        foreach ($row in $group.Group) {
            if ($null -ne $prev -and $row.Time -lt $prev) { $nonMonotonic++ }
            $prev = $row.Time
        }
    }
    Assert "L7 each pid's lines are monotonic in time" ($nonMonotonic -eq 0)

    # The whole run happened in the last few minutes, so a prefix that was
    # constant, epoch-clamped, or copied from a build stamp fails here.
    $now = [datetime]::UtcNow
    $stale = @($parsed | Where-Object { ($now - $_.Time).TotalMinutes -gt 10 -or $_.Time -gt $now.AddMinutes(1) })
    Assert "L8 the timestamps are this run's, not a constant" ($stale.Count -eq 0)

    # A prefix emitted as its own write could land after another process's line,
    # splitting this one in two: the tail would then be a level-first line with
    # no prefix, and the head a prefix with no message. L2 catches the tail;
    # this catches the head, which is the half that still starts with a digit.
    $headless = @($lines | Where-Object { $_ -match '^\d{4}-\d\d-\d\dT[\d:.]+Z \d+ *$' })
    Assert "L9 no line is a bare prefix (the prefix rides its message's write)" ($headless.Count -eq 0)
}

} finally {
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Say ""
if ($script:failures -eq 0) { Say "LOG-APPEND: ALL PASS ($script:passes)"; exit 0 }
else { Say "LOG-APPEND: $script:failures FAILURE(S) / $script:passes passed"; exit 1 }
