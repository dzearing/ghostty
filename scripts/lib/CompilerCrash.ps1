<#
.SYNOPSIS
    Tell a lane that died because the COMPILER crashed apart from a lane that
    died because the code is red (T451).

.DESCRIPTION
    `zig.exe` itself takes fatal faults on this box -- eight of them in the 32
    days to 2026-09-04, four of those at the same offset within one minute --
    and when it does, `zig build` reports

        error: the following command exited with error code 5:

    and nothing else. T444 taught the wrapper to decode that 5 (it is
    `0xC0000005 & 0xFF`, an access violation in a child) and to name the process
    the Windows Application log says actually died. What nothing did with that
    answer was ACT on it: a crashed compiler was still counted as a lane
    failure, so a floor run went red over a toolchain fault and the turn reading
    it had to go to the event log by hand to find out that its code was fine.
    That happened on 2026-08-04 and cost the T377 turn; a bare re-run of the
    same lane, no source change, passed in 186s.

    A compiler crash is not a result. This library is the classifier that says
    so, kept pure (it takes the parsed crash records, not the log) so
    floor-lane.ps1 owns the retry policy and the acceptance test can drive every
    branch against planted records.

    The precedence rule is the important part: **our own test binary crashing
    always wins.** ghostty-test.exe faulting is the T443 hunt's whole subject,
    and a lane that relabelled it "the compiler crashed, retrying" would erase
    the evidence the crash hunt is built to collect -- so when both a test
    binary and zig.exe are in the window, this reports NOT a compiler crash and
    says why. Silence is the other safe answer: with no Application Error record
    naming the compiler there is no verdict, because the truncated exit code
    alone cannot tell `exit(5)` from an access violation (see
    scripts/lib/CrashDiag.ps1).

    Dot-source it:  . "$PSScriptRoot\lib\CompilerCrash.ps1"
    ASCII only, PowerShell 5.1 compatible.
#>

# The toolchain processes whose crash is never our result. `zig.exe` is the
# compiler and the build runner both; a fault in either is a fault in the tool
# we drive, not in the code it is compiling.
$script:COMPILERCRASH_EXES = @(
    'zig.exe'
)

function Get-CompilerCrashVerdict {
    <#
    .SYNOPSIS
        Did this lane fail because the toolchain crashed?
    .PARAMETER Crashes
        The parsed `Application Error` records for the lane's window, as
        Get-ProcessCrashEvent returns them (App / ExceptionCode / Module /
        FaultOffset / Time / ProcessId).
    .PARAMETER TestExeNames
        Our own test binaries. A crash in one of these vetoes the verdict.
    .OUTPUTS
        One object:
          IsCompilerCrash  bool   -- the lane's red is the toolchain's
          CompilerCrashes  array  -- the records naming a compiler process
          TestCrashes      array  -- the records naming one of ours
          RepeatedSite     string -- module+offset seen more than once, or ''
          Reason           string -- one sentence, always populated
    #>
    param(
        [AllowEmptyCollection()][AllowNull()][object[]]$Crashes = @(),
        [string[]]$TestExeNames = @('ghostty-test.exe', 'ghoztty-agent-test.exe'),
        [string[]]$CompilerExeNames = $script:COMPILERCRASH_EXES
    )

    $records = @(@($Crashes) | Where-Object { $null -ne $_ })
    $ours = @($records | Where-Object { $TestExeNames -contains $_.App })
    $tool = @($records | Where-Object { $CompilerExeNames -contains $_.App })

    # A module+offset that shows up twice is a repeated CODE PATH, not a
    # coincidence: zig.exe is a ReleaseFast build and these offsets are
    # module-relative, so ASLR does not move them between runs. Worth naming in
    # the report, because it is the difference between "the machine is sick" and
    # "the compiler has a bug", and it is the evidence an upstream report needs.
    $repeated = ''
    if ($tool.Count -gt 1) {
        $sites = @{}
        foreach ($c in $tool) { $key = ('{0}+{1}' -f $c.Module, $c.FaultOffset); $sites[$key] = 1 + [int]$sites[$key] }
        $hit = @($sites.GetEnumerator() | Where-Object { $_.Value -gt 1 } | Sort-Object -Property Value -Descending)
        if ($hit.Count -gt 0) { $repeated = ('{0} ({1}x)' -f $hit[0].Key, $hit[0].Value) }
    }

    $verdict = [pscustomobject]@{
        IsCompilerCrash = $false
        CompilerCrashes = $tool
        TestCrashes     = $ours
        RepeatedSite    = $repeated
        Reason          = ''
    }

    if ($ours.Count -gt 0) {
        $verdict.Reason = ("a test binary crashed ({0}), so this red is ours to explain, not the toolchain's" -f
            (($ours | ForEach-Object { $_.App } | Select-Object -Unique) -join ', '))
        return $verdict
    }
    if ($tool.Count -eq 0) {
        $verdict.Reason = 'no Application Error record names the compiler in this lane window'
        return $verdict
    }

    $verdict.IsCompilerCrash = $true
    $verdict.Reason = ("{0} crashed {1} time(s) during this lane" -f
        (($tool | ForEach-Object { $_.App } | Select-Object -Unique) -join ', '), $tool.Count)
    return $verdict
}

function Format-CompilerCrashReport {
    <#
    .SYNOPSIS
        The lines a lane prints when the toolchain, not the code, killed it.
    .DESCRIPTION
        Worded so a human reading a red floor run stops looking for the bug in
        their diff. Says what died, where, whether the site repeats, and what
        the wrapper is about to do about it.
    .OUTPUTS
        string[] -- empty when the verdict is not a compiler crash.
    #>
    param(
        [Parameter(Mandatory)]$Verdict,
        [string]$LaneName = '?',
        # $false when the retry budget for this lane is already spent, so the
        # report says "already retried" instead of promising another run.
        [bool]$WillRetry = $true
    )

    if (-not $Verdict -or -not $Verdict.IsCompilerCrash) { return @() }

    $out = @("COMPILER CRASH: lane $LaneName is red because the toolchain died, not because the code is broken")
    foreach ($c in @($Verdict.CompilerCrashes)) {
        $out += ("  {0:HH:mm:ss} {1} pid={2} {3} in {4}+{5}" -f
            $c.Time, $c.App, $c.ProcessId, $c.ExceptionCode, $c.Module, $c.FaultOffset)
    }
    if ($Verdict.RepeatedSite) {
        $out += ("  the same fault site repeats: {0} - a repeated code path in a ReleaseFast binary, not random corruption" -f $Verdict.RepeatedSite)
    }
    if ($WillRetry) {
        $out += '  re-running this lane once; a second failure is the code and is reported as such (T451)'
    }
    else {
        $out += '  this lane was ALREADY retried once for a compiler crash, so this result stands (T451)'
    }
    return $out
}
