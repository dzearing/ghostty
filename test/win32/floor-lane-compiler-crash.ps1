<#
.SYNOPSIS
  Acceptance test for scripts\lib\CompilerCrash.ps1 and floor-lane.ps1's
  compiler-crash retry (T451).

.DESCRIPTION
  `zig.exe` itself takes fatal faults on this box -- eight in the 32 days to
  2026-09-04, four of them at the same offset inside one minute. When it does,
  the lane dies on a bare `exited with error code 5` and reads exactly like
  broken code; on 2026-08-04 that sent a whole turn to the Windows event log by
  hand before a plain re-run passed in 186s.

  What must be true, and what each arm proves:

    1-6  the classifier. A zig.exe crash is the toolchain's; one of OUR test
         binaries crashing VETOES that verdict (relabelling it would erase the
         evidence the T443 crash hunt collects); no record at all yields no
         verdict, because a truncated exit code cannot tell exit(5) from an
         access violation.
    7-9  the report. It names the fault, it names a REPEATED fault site (the
         thing that distinguishes a compiler bug from a sick machine), and it
         says whether a retry is coming.
    10   end to end, with a REAL crash: a genuine access-violating process
         named zig.exe is driven through floor-lane.ps1, which must print the
         COMPILER CRASH block, re-run once, and tag the summary -- rather than
         reporting a bare FAIL.
    11   the negative control for arm 10: an ordinary non-zero exit, no crash,
         stays a plain FAIL with no compiler-crash block anywhere.

  Arm 10 runs the crasher on the BACKGROUND test desktop (T1241), so neither
  its console nor any WER dialog lands on the user's screen.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $RepoRoot 'scripts\lib\CompilerCrash.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

# A stand-in for one parsed `Application Error` record, shaped exactly like
# Get-ProcessCrashEvent's output so the classifier is driven by the same objects
# it sees in production.
function New-CrashRecord {
    param(
        [string]$App,
        [string]$Module = 'zig.exe',
        [string]$Offset = '0x00000000000394d8',
        [string]$Code = '0xc0000005'
    )
    [pscustomobject]@{
        Time          = Get-Date
        App           = $App
        ExceptionCode = $Code
        ExceptionName = 'STATUS_ACCESS_VIOLATION'
        Module        = $Module
        FaultOffset   = $Offset
        ProcessId     = '0x1234'
    }
}

$Sandbox = Join-Path $env:TEMP ("compiler-crash-test-{0}" -f $PID)
if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null

try {
    # -- 1: a zig.exe crash in the window IS the toolchain's fault
    $v = Get-CompilerCrashVerdict -Crashes @(New-CrashRecord -App 'zig.exe')
    Check 'a zig.exe crash is classified as a compiler crash' ($v.IsCompilerCrash) $v.Reason
    Check 'the verdict names the compiler in its reason' ($v.Reason -match 'zig\.exe crashed 1 time') $v.Reason

    # -- 2: one of OUR test binaries crashing is NOT
    $v = Get-CompilerCrashVerdict -Crashes @(New-CrashRecord -App 'ghostty-test.exe' -Module 'ghostty-test.exe')
    Check 'a test-binary crash is not a compiler crash' (-not $v.IsCompilerCrash) $v.Reason
    Check 'the reason says the red is ours' ($v.Reason -match 'ghostty-test\.exe') $v.Reason

    # -- 3: the veto. Both crashed -> ours wins, because relabelling it as a
    #       toolchain fault would erase the T443 hunt's evidence.
    $v = Get-CompilerCrashVerdict -Crashes @(
        (New-CrashRecord -App 'zig.exe'),
        (New-CrashRecord -App 'ghoztty-agent-test.exe' -Module 'ghoztty-agent-test.exe')
    )
    Check 'a test-binary crash vetoes a simultaneous compiler crash' (-not $v.IsCompilerCrash) $v.Reason
    Check 'the vetoed verdict still carries the test crash' ($v.TestCrashes.Count -eq 1) "got $($v.TestCrashes.Count)"

    # -- 4: silence is the safe answer -- no record, no verdict
    $v = Get-CompilerCrashVerdict -Crashes @()
    Check 'no crash record yields no compiler-crash verdict' (-not $v.IsCompilerCrash) $v.Reason
    Check 'and says why it is quiet' ($v.Reason -match 'no Application Error record') $v.Reason
    $v = Get-CompilerCrashVerdict -Crashes $null
    Check 'a null crash list is handled, not thrown on' (-not $v.IsCompilerCrash) $v.Reason

    # -- 5: somebody else's crash in the same window is nobody's verdict
    $v = Get-CompilerCrashVerdict -Crashes @(New-CrashRecord -App 'HxTsr.exe' -Module 'HxTsr.exe')
    Check 'an unrelated process crashing is not a compiler crash' (-not $v.IsCompilerCrash) $v.Reason

    # -- 6: a caller may extend the test-binary list (floor-lane's
    #       -ExtraTestExeNames), and that extension must veto too
    $v = Get-CompilerCrashVerdict -Crashes @((New-CrashRecord -App 'zig.exe'), (New-CrashRecord -App 'fixture-test.exe')) `
        -TestExeNames @('ghostty-test.exe', 'fixture-test.exe')
    Check 'an extended test-binary list vetoes as well' (-not $v.IsCompilerCrash) $v.Reason

    # -- 7: a REPEATED fault site is named -- the evidence that separates a
    #       compiler bug from random corruption on a sick machine
    $v = Get-CompilerCrashVerdict -Crashes @(
        (New-CrashRecord -App 'zig.exe' -Offset '0x00000000000394d8'),
        (New-CrashRecord -App 'zig.exe' -Offset '0x00000000000394d8')
    )
    Check 'two crashes at one offset are reported as a repeated site' `
        ($v.RepeatedSite -match '0x00000000000394d8 \(2x\)') "got '$($v.RepeatedSite)'"
    $v2 = Get-CompilerCrashVerdict -Crashes @(
        (New-CrashRecord -App 'zig.exe' -Offset '0x0000000002303d52'),
        (New-CrashRecord -App 'zig.exe' -Offset '0x000000000230f248')
    )
    Check 'two crashes at different offsets name no repeated site' ($v2.RepeatedSite -eq '') "got '$($v2.RepeatedSite)'"

    # -- 8: the report says what died, where, and what happens next
    $lines = @(Format-CompilerCrashReport -Verdict $v -LaneName 'agent' -WillRetry $true)
    $text = ($lines -join "`n")
    Check 'the report leads with COMPILER CRASH and the lane' ($text -match 'COMPILER CRASH: lane agent') $text
    Check 'the report says the code is not to blame' ($text -match 'not because the code is broken') $text
    Check 'the report names the fault offset' ($text -match '0x00000000000394d8') $text
    Check 'the report announces the retry' ($text -match 're-running this lane once') $text
    Check 'the report names the repeated site when there is one' `
        (((Format-CompilerCrashReport -Verdict $v -LaneName 'agent') -join "`n") -match 'same fault site repeats') ''

    $spent = ($(Format-CompilerCrashReport -Verdict $v -LaneName 'agent' -WillRetry $false) -join "`n")
    Check 'a spent budget says so instead of promising a retry' `
        (($spent -match 'ALREADY retried') -and ($spent -notmatch 're-running this lane once')) $spent

    # -- 9: a non-compiler verdict prints nothing at all
    $none = @(Format-CompilerCrashReport -Verdict (Get-CompilerCrashVerdict -Crashes @()) -LaneName 'none')
    Check 'a non-compiler verdict produces no report' ($none.Count -eq 0) "got $($none.Count) line(s)"

    # -- 10: end to end, through the wrapper, with a REAL access violation
    $crashSrc = Join-Path $Sandbox 'av.zig'
    @(
        'pub fn main() void {',
        '    const p: *volatile u8 = @ptrFromInt(0x10);',
        '    p.* = 1;',
        '}'
    ) | Set-Content -Path $crashSrc -Encoding Ascii
    if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
        # CLAUDE.md: the global cache must sit on the repo's drive.
        $env:ZIG_GLOBAL_CACHE_DIR = (Join-Path (Split-Path -Qualifier $RepoRoot) '\zig-global-cache')
    }
    Push-Location $Sandbox
    # ReleaseFast on purpose: that is how the shipped zig.exe is built, so the
    # fixture dies the way the compiler does, with no segfault handler.
    $buildOut = & zig build-exe av.zig -OReleaseFast 2>&1
    Pop-Location
    $built = Join-Path $Sandbox 'av.exe'
    Check 'the crash fixture built' (Test-Path $built) "$buildOut"

    if (Test-Path $built) {
        # The name is the whole point: WER records the FILE name, so a copy
        # called zig.exe produces exactly the record a crashed compiler does.
        $fakeZig = Join-Path $Sandbox 'zig.exe'
        Copy-Item $built $fakeZig -Force

        $null = New-TestDesktop
        $laneOut = Invoke-OnTestDesktop -Exe (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $RepoRoot 'scripts\floor-lane.ps1'),
            '-Command', $fakeZig, '-NoCatch', '-NoSweep', '-MinFreeGB', '0') `
            -WorkingDirectory $RepoRoot -TimeoutSec 300
        $t = "$($laneOut.StdOut)`n$($laneOut.StdErr)"

        Check 'the wrapper saw the lane fail' ($t -match 'LANE command FAIL') $t
        Check 'the wrapper names it a COMPILER CRASH' ($t -match 'COMPILER CRASH: lane command') $t
        Check 'the block names the crashed compiler process' ($t -match 'CRASH .*zig\.exe') $t
        Check 'the wrapper re-runs the lane once' `
            (([regex]::Matches($t, 'LANE command FAIL')).Count -ge 2) `
            "saw $((([regex]::Matches($t,'LANE command FAIL')).Count)) lane result(s)"
        Check 'a second compiler crash spends the budget rather than looping' `
            ($t -match 'ALREADY retried') $t
        Check 'the summary is tagged with the compiler crash' `
            ($t -match 'FLOOR SUMMARY: command=FAIL \[compiler crashed') $t
        Check 'red is still red: the wrapper still exits non-zero' ($laneOut.ExitCode -ne 0) "exit $($laneOut.ExitCode)"
    }

    # -- 11: the negative control. An ordinary non-zero exit is NOT a crash, and
    #        must not pick up a compiler-crash block or a retry.
    $plain = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\floor-lane.ps1') `
        -Command 'cmd /c exit 7' -NoCatch -NoSweep -MinFreeGB 0 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Check 'an ordinary failing command still fails' ($plain -match 'LANE command FAIL') $plain
    Check 'and is not called a compiler crash' ($plain -notmatch 'COMPILER CRASH') $plain
    Check 'and is not retried' (([regex]::Matches($plain, 'LANE command FAIL')).Count -eq 1) $plain
    Check 'and its summary carries no compiler tag' ($plain -notmatch 'compiler crashed') $plain

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    Remove-TestDesktop | Out-Null
    if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard lane-compiler-crash -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
