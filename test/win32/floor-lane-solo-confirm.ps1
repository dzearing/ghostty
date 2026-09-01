<#
.SYNOPSIS
  Acceptance test for scripts\lib\LaneSolo.ps1 and floor-lane.ps1's solo
  confirm pass (T1170).

.DESCRIPTION
  A floor lane that goes red because the box was loaded is not the same event
  as one that goes red because the code is broken. T1170 was a whole task spent
  discovering that difference by hand: three full agent-lane runs to establish
  that the only green one was the filtered one. The confirm pass makes the run
  itself answer the question -- and the rule it must never break is that the
  answer does NOT change the verdict. A lane that failed under load is still
  red, and floor-lane still exits non-zero.

  Arms 1-6 drive the pure library against planted log text, including the
  decoy line the T1170 report says every reader chases first (`error: while
  executing test '...'` names the test COMMAND, not a failure). Arms 7-9 are
  the wiring: the switch exists, red stays red, and the narrowed re-run really
  does reach zig with one -Dtest-filter per named test.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $RepoRoot 'scripts\lib\LaneSolo.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

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

$Sandbox = Join-Path $env:TEMP ("lane-solo-test-{0}" -f $PID)
if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null

try {
    # ---- arms 1-6: naming the failing tests --------------------------------

    # Verbatim from the T1170 report, decoy line included.
    $log1 = Join-Path $Sandbox 'loaded.log'
    @(
        "error: 'apprt.win32.ViewerPane.test.host floor: a real controller on a real window, on this box' failed: error.WaitForTimeout",
        "[viewer_pane] (warn): waitFor: nothing satisfied the wait; pane still for 30004ms (bound 30s), 30004ms total",
        "error: while executing test 'benchmark.OscParser.decltest.OscParser', the following test command failed:",
        "error: the following build command failed with exit code 1:"
    ) | Set-Content -LiteralPath $log1 -Encoding ascii

    $n1 = @(Get-FailedTestName -LogPath $log1)
    Check 'names exactly the one failing test' ($n1.Count -eq 1) ("got: " + ($n1 -join ' | '))
    Check 'names it by its source title, which is what -Dtest-filter matches' `
        ($n1[0] -eq 'host floor: a real controller on a real window, on this box') ($n1 -join ' | ')
    Check 'does NOT chase the "while executing test" decoy' `
        (($n1 -join ' ') -notmatch 'OscParser') ($n1 -join ' | ')

    # `logged errors:` is the other shape the runner prints, and it is a
    # failure just as much as `failed:` is.
    $log2 = Join-Path $Sandbox 'logged.log'
    @(
        "error: 'pkg.Thing.test.a thing that logs' logged errors:",
        "error: 'pkg.Other.test.another thing' failed: error.Boom"
    ) | Set-Content -LiteralPath $log2 -Encoding ascii
    $n2 = @(Get-FailedTestName -LogPath $log2)
    Check 'both failure shapes are named' ($n2.Count -eq 2) ($n2 -join ' | ')
    Check 'a logged-errors failure is named by title too' `
        ($n2 -contains 'a thing that logs') ($n2 -join ' | ')

    # A log with no test failure at all (a build break, a crash) must name
    # nothing, so the confirm pass skips rather than re-running the world.
    $log3 = Join-Path $Sandbox 'buildbreak.log'
    @(
        "src\apprt\win32\ViewerPane.zig:10:5: error: expected type 'bool'",
        "error: the following command failed with 1 compilation errors:"
    ) | Set-Content -LiteralPath $log3 -Encoding ascii
    Check 'a build break names no test' (@(Get-FailedTestName -LogPath $log3).Count -eq 0)

    # ---- the verdict wording ------------------------------------------------

    $green = Get-SoloVerdictNote -SoloResult 'PASS'
    Check 'green alone is called out as NOT reproduced' `
        ($green -match 'NOT reproduced' -and $green -match 'harness') $green
    Check 'red alone is called out as reproduced' `
        ((Get-SoloVerdictNote -SoloResult 'FAIL') -match 'reproduced' ) ''
    Check 'a stalled solo run keeps its own verdict word' `
        ((Get-SoloVerdictNote -SoloResult 'STALL') -match '^STALL') ''

    # ---- arms 7-9: the wiring in floor-lane.ps1 -----------------------------

    $floor = Join-Path $RepoRoot 'scripts\floor-lane.ps1'
    $src = Get-Content -LiteralPath $floor -Raw

    Check 'floor-lane dot-sources the library' ($src -match 'lib.LaneSolo\.ps1')
    Check 'the confirm pass runs on FAIL and is on by default' `
        ($src -match "\`$r -eq 'FAIL' -and -not \`$NoSoloConfirm")

    # THE RULE: the annotation must not green a red lane. If a future edit ever
    # made the verdict follow the solo result, this is what catches it.
    $mainLoop = $src.Substring($src.IndexOf('$alone = Invoke-SoloConfirm'))
    $mainLoop = $mainLoop.Substring(0, [Math]::Min(600, $mainLoop.Length))
    Check 'a green solo run does NOT rewrite the lane verdict' `
        ($mainLoop -notmatch "\`$r\s*=\s*'PASS'") $mainLoop

    # And the narrowed re-run really reaches zig: one -Dtest-filter per test.
    # -Repeat 0 would skip the lane entirely, so this drives the arg builder by
    # running the cheapest lane there is against a filter that matches nothing.
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $floor `
        -Lane none -Filter 'GhozttyLaneSoloNoSuchTest' -MinFreeGB 0 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Check 'a filtered lane passes the filter through to zig' `
        ($out -match '-Dtest-filter="GhozttyLaneSoloNoSuchTest"') $out
    Check 'a filtered run does not trigger the confirm pass' `
        ($out -notmatch 'solo confirm') $out

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard lane-solo-confirm -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
