<#
.SYNOPSIS
    Run a built test binary N times and report how many runs CRASHED. T473.

.DESCRIPTION
    The T443 corruption lands on roughly half of runs, which makes every
    single-run result worthless: "it passed" and "it is fixed" look identical.
    Every claim about that signal therefore needs a run count behind it, and
    this is the thing that produces one.

    It runs the binary directly out of .zig-cache (no build, no build runner),
    because that is the only way 10+ runs is affordable, and it separates the
    three outcomes that a bare exit code smears together:

      CRASH   - the process died on an exception. `std.process.Child` truncates
                a Windows exit code to a byte, so this is recognised from the
                stderr signature AND the low-byte NTSTATUS decode, then
                confirmed against the Windows `Application Error` log.
      FAIL    - the tests ran and some failed. A real red test, not a crash.
      PASS    - clean.

    Comparing two configurations (a control arm and a suspect arm) is the whole
    point: pass -Label so the two summaries are told apart in a transcript.

.PARAMETER Lane
    Soak the newest test binary a zig lane built, instead of naming an exe.
    `agent` covers both agent test binaries, soaking each in turn.

.OUTPUTS
    A per-run table and a final one-line summary:
        SOAK <label>: runs=N pass=P fail=F crash=C  crash-rate=C/N (xx%)
    Exit 0 = no crashes, 1 = at least one crash, 2 = could not run.

.EXAMPLE
    powershell -NoProfile -File scripts\test-binary-soak.ps1 -Lane none -Runs 12 -Label debug-llvm
.EXAMPLE
    powershell -NoProfile -File scripts\test-binary-soak.ps1 -Exe .\zig-out\bin\x.exe -Runs 10
#>
[CmdletBinding()]
param(
    [ValidateSet('none', 'win32', 'agent')][string]$Lane,
    [string]$Exe,
    [string[]]$Arguments = @(),
    [int]$Runs = 10,
    [string]$Label = '',
    [int]$TimeoutSeconds = 900,
    [string]$OutDir = "$env:TEMP\ghoztty-soak",
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\CrashCatch.ps1"
. "$PSScriptRoot\lib\CrashDiag.ps1"

# ------------------------------------------------------------- what to run

$targets = @()
if ($Exe) { $targets = @((Resolve-Path -LiteralPath $Exe).Path) }
elseif ($Lane) {
    $targets = @(Get-LaneTestBinary -Lane $Lane -Repo $Repo)
    if ($targets.Count -eq 0) {
        Write-Host "soak: nothing built for lane '$Lane' under $Repo\.zig-cache\o -- run the lane once first."
        exit 2
    }
}
else {
    Write-Host 'soak: pass -Lane <none|win32|agent> or -Exe <path>.'
    exit 2
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
    'Stack overflow'
)

$totals = [ordered]@{ pass = 0; fail = 0; crash = 0 }
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

    for ($i = 1; $i -le $Runs; $i++) {
        $log = Join-Path $OutDir ("{0}-{1}-{2:d2}.log" -f $tag, $stamp, $i)
        $since = Get-Date
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # cmd.exe redirection, not PowerShell's: PS 5.1 wraps a native
        # command's stderr in ErrorRecords and can flip $? on a clean exit.
        $argLine = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        & cmd.exe /c "`"$t`" $argLine > `"$log`" 2>&1"
        $code = $LASTEXITCODE
        $sw.Stop()

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
        if ($code -ne 0) { $cand = @(Get-NtStatusCandidate -Code $code) }
        [array]$evt = @()
        if ($code -ne 0 -and ($sig -or $cand.Count -gt 0)) {
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
        if ($code -eq 0) {
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

$n = $rows.Count
$rate = if ($n -gt 0) { [math]::Round(100.0 * $totals.crash / $n) } else { 0 }
Write-Host ''
Write-Host ("SOAK {0}: runs={1} pass={2} fail={3} crash={4}  crash-rate={4}/{1} ({5}%)" -f `
        $tag, $n, $totals.pass, $totals.fail, $totals.crash, $rate)
Write-Host "  logs: $OutDir"

if ($totals.crash -gt 0) { exit 1 }
exit 0
