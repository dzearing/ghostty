<#
.SYNOPSIS
    Run a built test binary N times and report how many runs CRASHED. T473.

.DESCRIPTION
    The T443 corruption lands on roughly half of runs, which makes every
    single-run result worthless: "it passed" and "it is fixed" look identical.
    Every claim about that signal therefore needs a run count behind it, and
    this is the thing that produces one.

    It runs the LANE, through `zig build`, and separates the three outcomes
    that a bare exit code smears together. Running the binary straight out of
    .zig-cache is cheaper and was the original behaviour, but T832 measured
    what that costs: the T443 corruption has never once been observed in a
    directly-launched process (~200 runs, 0 crashes -- including the exact
    binary that had dumped three times that morning), against 5 aborts in 26
    build-runner lane runs on the same box on 2026-08-14. `zig build` passes
    `--listen=-`, so `lib/compiler/test_runner.zig` takes `mainServer()` and
    drives one test per pipe message instead of `mainTerminal()`'s back-to-back
    loop -- a different scheduling pattern and a different set of stack
    leftovers under every test. So a standalone soak can report "all clear"
    indefinitely while the defect is still there; it is still available behind
    `-Mode standalone`, and it says so in its own output.

    The three outcomes:

      CRASH   - the process died on an exception. `std.process.Child` truncates
                a Windows exit code to a byte, so this is recognised from the
                stderr signature AND the low-byte NTSTATUS decode, then
                confirmed against the Windows `Application Error` log.
      FAIL    - the tests ran and some failed. A real red test, not a crash.
      PASS    - clean.

    Comparing two configurations (a control arm and a suspect arm) is the whole
    point: pass -Label so the two summaries are told apart in a transcript.

.PARAMETER Lane
    Which lane to soak. In build-runner mode this is the `zig build` target;
    in standalone mode it selects the newest test binary that lane built
    (`agent` covers both agent test binaries, soaking each in turn).

.PARAMETER Mode
    build-runner (the default whenever -Lane is given) repeats the lane through
    `zig build`, which is the only condition T443 has ever been seen in.
    standalone runs the built exe directly -- faster, and structurally unable
    to reproduce T443; it prints a warning saying so. -Exe is always
    standalone, because a bare exe has no lane to build.

.PARAMETER NoCatch
    Build-runner mode only: pass -NoCatch to floor-lane.ps1, so a crashed run
    is not re-run under cdb. Skips a couple of minutes per crash when the crash
    RATE is what is being measured rather than any single stack.

.PARAMETER Concurrency
    Standalone mode only. Run this many copies of the binary AT THE SAME TIME
    per round (default 1, which is the original sequential behaviour). Lane
    runs are never overlapped (T401): a lane starved by another lane wedges,
    and a wedge is not a data point.

    This is not a speed knob, it is the experiment. Every T443 crash was
    observed under `zig build` / `floor-lane.ps1`, which has several test
    processes and compiles in flight at once; every clean run -- 47 of them,
    including the byte-identical binary that produced the 07:13 dump -- was a
    single process on an idle box. A signal that needs the machine
    oversubscribed to appear cannot be soaked for one process at a time, which
    is how 47 runs of a "50% flaky" crash came back green and told us nothing.

.OUTPUTS
    A per-run table and a final one-line summary:
        SOAK <label>: mode=M runs=N pass=P fail=F crash=C  crash-rate=C/N (xx%)
    Exit 0 = no crashes, 1 = at least one crash, 2 = could not run.

.EXAMPLE
    powershell -NoProfile -File scripts\test-binary-soak.ps1 -Lane agent -Runs 10
.EXAMPLE
    powershell -NoProfile -File scripts\test-binary-soak.ps1 -Exe .\zig-out\bin\x.exe -Runs 10
#>
[CmdletBinding()]
param(
    [ValidateSet('none', 'win32', 'agent')][string]$Lane,
    [string]$Exe,
    [ValidateSet('auto', 'build-runner', 'standalone')][string]$Mode = 'auto',
    [switch]$NoCatch,
    [string]$Filter = '',
    # Soak this command as if it were a lane (floor-lane.ps1 -Command). The
    # whole build-runner path -- watchdog, crash scan, classification -- runs
    # over it, which is how the mode is testable end to end without staging a
    # real intermittent crash. Same reason floor-lane grew -Command.
    [string]$LaneCommand = '',
    [string[]]$Arguments = @(),
    [int]$Runs = 10,
    [ValidateRange(1, 64)][int]$Concurrency = 1,
    [string]$Label = '',
    [int]$TimeoutSeconds = 900,
    [string]$OutDir = "$env:TEMP\ghoztty-soak",
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\CrashCatch.ps1"
. "$PSScriptRoot\lib\CrashDiag.ps1"

# ------------------------------------------------------------- what to run

if (-not $Exe -and -not $Lane -and -not $LaneCommand) {
    Write-Host 'soak: pass -Lane <none|win32|agent> or -Exe <path>.'
    exit 2
}
if ($Exe -and $Mode -eq 'build-runner') {
    Write-Host 'soak: -Exe has no lane to build; use -Lane for build-runner mode.'
    exit 2
}
if ($LaneCommand -and $Mode -eq 'standalone') {
    Write-Host 'soak: -LaneCommand is a build-runner fixture; it has no standalone form.'
    exit 2
}

# The default is the condition the defect occurs in, not the cheap one (T832).
$mode = $Mode
if ($mode -eq 'auto') { $mode = if ($Exe) { 'standalone' } else { 'build-runner' } }
# floor-lane names a -Command run 'command', not after a lane.
$laneName = if ($LaneCommand) { 'command' } else { $Lane }

$targets = @()
if ($mode -eq 'standalone') {
    if ($Exe) { $targets = @((Resolve-Path -LiteralPath $Exe).Path) }
    else {
        $targets = @(Get-LaneTestBinary -Lane $Lane -Repo $Repo)
        if ($targets.Count -eq 0) {
            Write-Host "soak: nothing built for lane '$Lane' under $Repo\.zig-cache\o -- run the lane once first."
            exit 2
        }
    }
    # Only for OUR test binaries: a fixture exe has no build runner to be the
    # wrong side of, and a warning that cries wolf stops being read.
    $warnStandalone = [bool]$Lane -or
        (@($targets | Where-Object { (Split-Path -Leaf $_) -match '^(ghostty-test|ghoztty-agent(-core)?-test)\.exe$' }).Count -gt 0)
    if ($warnStandalone) {
        Write-Host 'soak: MODE=standalone -- the test binary is launched directly (mainTerminal).'
        Write-Host '      T443 has NEVER been observed in this condition: ~200 direct runs across that'
        Write-Host '      task with 0 crashes, including the exact binary that had dumped three times'
        Write-Host '      that morning, against 5 aborts in 26 build-runner lane runs on 2026-08-14.'
        Write-Host '      A green soak here is not evidence about T443. See T832; drop -Mode to use'
        Write-Host '      the build runner.'
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tag = if ($Label) { $Label } else { 'soak' }

# Stderr signatures that mean "the process died", not "a test failed". Zig's
# own segfault handler dies in a recursive panic on this box (T450), so the
# second line is as common as the first.
$crashPatterns = @(
    'Segmentation fault',
    'recursive panic',
    'General protection exception',
    'Illegal instruction',
    'Stack overflow',
    # A Zig panic aborts the process; the test runner never gets to report a
    # result for it. Four of the five 2026-08-14 T443 aborts arrived this way
    # ("thread 12188 panic: page map metadata pointer corrupted"), so a list
    # that only knows about faults classifies the signal it exists for as a
    # red test.
    'thread \d+ panic:'
)

# Extra signatures that only a lane transcript can carry: `zig build` names a
# crashed test command in its own words, and T444's decode turns the truncated
# NTSTATUS back into one.
$laneCrashPatterns = $crashPatterns + @(
    'the following test command crashed',
    'Access violation',
    'exited with error code (3|5)\b',
    'GHOZTTY-CRASH-BEGIN'
)

$totals = [ordered]@{ pass = 0; fail = 0; crash = 0; hang = 0 }
$rows = @()

foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host "soak: no such exe: $t"
        exit 2
    }
    $exeName = Split-Path -Leaf $t
    Write-Host ''
    Write-Host "soak: $exeName"
    Write-Host "      $t"
    Write-Host "      $Runs run(s), label='$tag'"

    # cmd.exe redirection, not PowerShell's: PS 5.1 wraps a native command's
    # stderr in ErrorRecords and can flip $? on a clean exit.
    $argLine = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '

    $started = 0
    while ($started -lt $Runs) {
        $batch = [math]::Min($Concurrency, $Runs - $started)
        if ($Concurrency -gt 1) {
            Write-Host ("  -- round: {0} concurrent, runs {1}-{2} --" -f $batch, ($started + 1), ($started + $batch))
        }

        $pending = @()
        for ($k = 1; $k -le $batch; $k++) {
            $idx = $started + $k
            $log = Join-Path $OutDir ("{0}-{1}-{2:d2}.log" -f $tag, $stamp, $idx)
            # ONE string, not an array: Start-Process does not quote the
            # elements of -ArgumentList, so an array is re-tokenised on spaces
            # (the T200 trap). The doubled outer quote is cmd's own /c rule --
            # it strips the first and last quote of the remainder.
            $cmdLine = '/c ""' + $t + '" ' + $argLine + ' > "' + $log + '" 2>&1"'
            $p = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -PassThru -WindowStyle Hidden
            # Touch .Handle BEFORE the child can exit, or PS 5.1 hands back an
            # EMPTY ExitCode later and every crash silently classifies as PASS.
            $null = $p.Handle
            $pending += [pscustomobject]@{
                Index = $idx; Log = $log; Proc = $p; Since = (Get-Date)
                Sw    = [System.Diagnostics.Stopwatch]::StartNew(); TimedOut = $false
            }
        }

        foreach ($e in $pending) {
            if (-not $e.Proc.WaitForExit($TimeoutSeconds * 1000)) {
                $e.TimedOut = $true
                try { $e.Proc.Kill() } catch {}
                try { $null = $e.Proc.WaitForExit(10000) } catch {}
            }
            $e.Sw.Stop()
        }

        $started += $batch

        foreach ($e in $pending) {
        $i = $e.Index
        $log = $e.Log
        $since = $e.Since
        # Wall time from launch to observed exit. Under -Concurrency this is
        # measured per process, so it is real elapsed time, not a share of it.
        $sw = $e.Sw
        $code = if ($e.TimedOut) { -1 } else { $e.Proc.ExitCode }

        $tail = ''
        if (Test-Path -LiteralPath $log) {
            $tail = (Get-Content -LiteralPath $log -Tail 40 -ErrorAction SilentlyContinue) -join "`n"
        }
        $sig = $false
        foreach ($p in $crashPatterns) { if ($tail -match $p) { $sig = $true; break } }

        # A nonzero code whose low byte decodes to a fatal NTSTATUS is a crash
        # SUSPICION on its own (a program really can exit(5)); the event log is
        # what turns it into evidence.
        # [array], and NOT `$cand = if (...) { @(...) }`: PowerShell 5.1 unrolls
        # the array an `if` expression produces, so a ONE-element result lands as
        # a bare object whose `.Count` is $null -- and `$null -gt 0` is false, so
        # every single-candidate crash silently classified as a red test.
        [array]$cand = @()
        if ($code -ne 0 -and -not $e.TimedOut) { $cand = @(Get-NtStatusCandidate -Code $code) }
        [array]$evt = @()
        if ($code -ne 0 -and -not $e.TimedOut -and ($sig -or $cand.Count -gt 0)) {
            # WER writes the `Application Error` record ASYNCHRONOUSLY, a second
            # or two after the process is already gone. Querying immediately
            # finds nothing and the run gets filed as a red test instead of a
            # crash -- which is the single worst mistake this script could make,
            # since the whole point is counting crashes. Give it a moment.
            foreach ($try in 1..4) {
                [array]$evt = @(Get-ProcessCrashEvent -Since $since.AddSeconds(-2) -NameLike $exeName)
                if ($evt.Count -gt 0) { break }
                Start-Sleep -Milliseconds 750
            }
        }

        $verdict = 'PASS'
        $note = ''
        if ($e.TimedOut) {
            $verdict = 'HANG'
            $totals.hang++
            $note = "no exit within ${TimeoutSeconds}s; killed"
        }
        elseif ($code -eq 0) {
            $totals.pass++
        }
        elseif ($sig -or $evt.Count -gt 0 -or $cand.Count -gt 0) {
            $verdict = 'CRASH'
            $totals.crash++
            if ($evt.Count -gt 0) {
                $note = "$($evt[-1].ExceptionCode) $($evt[-1].ExceptionName) $($evt[-1].Module)+$($evt[-1].FaultOffset)"
            }
            elseif ($cand.Count -gt 0) {
                $note = "exit $code -> $($cand[0].Hex) $($cand[0].Name) (no event record; suspicion only)"
            }
            else { $note = "exit $code" }
        }
        else {
            $verdict = 'FAIL'
            $totals.fail++
            $note = "exit $code"
            $failLine = ($tail -split "`n" | Where-Object { $_ -match 'passed;|error:' } | Select-Object -Last 1)
            if ($failLine) { $note += " | " + $failLine.Trim() }
        }

        # The victim test is the last one zig named before it died -- the single
        # most useful field in a crash run, and it is only in the log.
        $victim = ''
        if ($verdict -eq 'CRASH') {
            $v = ($tail -split "`n" | Where-Object { $_ -match '^\s*\d+/\d+\s+\S' } | Select-Object -Last 1)
            if ($v) { $victim = $v.Trim() }
        }

        $rows += [pscustomobject]@{
            Run     = $i
            Exe     = $exeName
            Verdict = $verdict
            Seconds = [int]$sw.Elapsed.TotalSeconds
            Note    = $note
            Victim  = $victim
            Log     = $log
        }
        $line = "  run {0,2}/{1}: {2,-5} {3,4}s" -f $i, $Runs, $verdict, [int]$sw.Elapsed.TotalSeconds
        if ($note) { $line += "  $note" }
        Write-Host $line
        if ($victim) { Write-Host "            victim: $victim" }
        }
    }
}

# ------------------------------------------------------ build-runner rounds
#
# One `zig build <lane>` per round, driven through floor-lane.ps1 so a round
# inherits its watchdog (a wedged lane is reported as a wedge rather than
# waited on forever) and its crash capture, instead of this script growing a
# second copy of both. Sequential by construction -- T401: an overlapped lane
# starves and wedges, and a wedge is not a data point.

if ($mode -eq 'build-runner') {
    $laneScript = Join-Path $PSScriptRoot 'floor-lane.ps1'
    if (-not (Test-Path -LiteralPath $laneScript)) {
        Write-Host "soak: floor-lane.ps1 is not next to this script ($laneScript)."
        exit 2
    }
    # A lane run plus a cdb crash capture can outlast the standalone default.
    $roundTimeout = [math]::Max($TimeoutSeconds, 2400)
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }

    Write-Host ''
    if ($LaneCommand) { Write-Host "soak: build-runner, staged command: $LaneCommand" }
    else { Write-Host "soak: build-runner, lane '$Lane' (zig build)" }
    Write-Host "      $Runs round(s), label='$tag'"
    if ($Concurrency -gt 1) {
        Write-Host "      -Concurrency $Concurrency ignored here: lane runs are never overlapped (T401)"
    }

    for ($i = 1; $i -le $Runs; $i++) {
        $log = Join-Path $OutDir ("{0}-{1}-{2:d2}.log" -f $tag, $stamp, $i)
        $laneArgs = '-NoProfile -File "' + $laneScript + '" -Repeat 1'
        if ($LaneCommand) { $laneArgs += ' -Command "' + $LaneCommand + '"' }
        else { $laneArgs += ' -Lane ' + $Lane }
        if ($NoCatch) { $laneArgs += ' -NoCatch' }
        if ($Filter) { $laneArgs += ' -Filter "' + $Filter + '"' }
        # ONE string, and cmd's own doubled-outer-quote rule -- as above.
        $cmdLine = '/c ""' + $psExe + '" ' + $laneArgs + ' > "' + $log + '" 2>&1"'

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -PassThru -WindowStyle Hidden
        $null = $p.Handle
        $timedOut = $false
        if (-not $p.WaitForExit($roundTimeout * 1000)) {
            $timedOut = $true
            try { $p.Kill() } catch {}
            try { $null = $p.WaitForExit(10000) } catch {}
        }
        $sw.Stop()
        $code = if ($timedOut) { -1 } else { $p.ExitCode }

        # floor-lane's transcript names the lane log it wrote; the test output
        # (and the crash text) is in there, not in the transcript.
        $txt = ''
        $laneLog = ''
        $laneResult = ''
        if (Test-Path -LiteralPath $log) {
            $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
            $txt = $lines -join "`n"
            foreach ($l in $lines) {
                if ($l -match '^\s*log:\s*(\S.*)$') { $laneLog = $matches[1].Trim() }
                if ($l -match ('^LANE\s+' + [regex]::Escape($laneName) + '\s+(\w+)\s+in\s+')) { $laneResult = $matches[1] }
            }
        }

        $sig = $false
        foreach ($pat in $laneCrashPatterns) { if ($txt -match $pat) { $sig = $true; break } }
        if (-not $sig -and $laneLog -and (Test-Path -LiteralPath $laneLog)) {
            # Select-String, not Get-Content: a lane log is thousands of test
            # lines and this runs once per pattern per round.
            foreach ($pat in $laneCrashPatterns) {
                if (@(Select-String -LiteralPath $laneLog -Pattern $pat -List -ErrorAction SilentlyContinue).Count -gt 0) {
                    $sig = $true; break
                }
            }
        }

        $verdict = 'PASS'
        $note = ''
        if ($timedOut) {
            $verdict = 'HANG'; $totals.hang++
            $note = "no exit within ${roundTimeout}s; killed"
        }
        elseif ($code -eq 0) { $totals.pass++ }
        elseif ($laneResult -eq 'STALL' -or $laneResult -eq 'TIMEOUT' -or $code -eq 2 -or $code -eq 3) {
            $verdict = 'HANG'; $totals.hang++
            $note = "floor-lane reported $laneResult"
        }
        elseif ($sig) {
            $verdict = 'CRASH'; $totals.crash++
            $hitLine = ''
            foreach ($pat in $laneCrashPatterns) {
                $h = @($txt -split "`n" | Where-Object { $_ -match $pat } | Select-Object -First 1)
                if ($h.Count -eq 1) { $hitLine = $h[0].Trim(); break }
                if ($laneLog -and (Test-Path -LiteralPath $laneLog)) {
                    $h = @(Select-String -LiteralPath $laneLog -Pattern $pat -List -ErrorAction SilentlyContinue)
                    if ($h.Count -ge 1) { $hitLine = $h[0].Line.Trim(); break }
                }
            }
            $note = if ($hitLine) { $hitLine } else { "exit $code" }
        }
        else {
            $verdict = 'FAIL'; $totals.fail++
            $note = "exit $code"
            $failLine = ($txt -split "`n" | Where-Object { $_ -match 'error:|passed;' } | Select-Object -First 1)
            if ($failLine) { $note += ' | ' + $failLine.Trim() }
        }

        $victim = ''
        if ($verdict -eq 'CRASH' -and $laneLog -and (Test-Path -LiteralPath $laneLog)) {
            $v = @(Select-String -LiteralPath $laneLog -Pattern '^\s*\d+/\d+\s+\S' -ErrorAction SilentlyContinue |
                    Select-Object -Last 1)
            if ($v.Count -eq 1) { $victim = $v[0].Line.Trim() }
        }

        $rows += [pscustomobject]@{
            Run     = $i
            Exe     = "lane:$laneName"
            Verdict = $verdict
            Seconds = [int]$sw.Elapsed.TotalSeconds
            Note    = $note
            Victim  = $victim
            Log     = $log
        }
        $line = "  run {0,2}/{1}: {2,-5} {3,4}s" -f $i, $Runs, $verdict, [int]$sw.Elapsed.TotalSeconds
        if ($note) { $line += "  $note" }
        Write-Host $line
        if ($victim) { Write-Host "            victim: $victim" }
        if ($laneLog) { Write-Host "            lane log: $laneLog" }
    }
}

$n = $rows.Count
$rate = if ($n -gt 0) { [math]::Round(100.0 * $totals.crash / $n) } else { 0 }
Write-Host ''
$conc = if ($mode -eq 'build-runner') { 1 } else { $Concurrency }
$summary = "SOAK {0}: mode={7} runs={1} concurrency={6} pass={2} fail={3} crash={4}  crash-rate={4}/{1} ({5}%)" -f `
    $tag, $n, $totals.pass, $totals.fail, $totals.crash, $rate, $conc, $mode
if ($totals.hang -gt 0) { $summary += "  hang=$($totals.hang)" }
Write-Host $summary
if ($mode -eq 'standalone' -and $warnStandalone) {
    Write-Host '  NOTE: standalone -- see the warning above; this says nothing about T443 (T832).'
}
Write-Host "  logs: $OutDir"

# A hang is not a crash, but it is emphatically not a clean run either -- the
# whole point of this script is that "it exited 0" is the only thing allowed to
# read as green.
if ($totals.crash -gt 0 -or $totals.hang -gt 0) { exit 1 }
exit 0
