<#
.SYNOPSIS
    T271 acceptance - a run that asserted NOTHING must not exit 0.

.DESCRIPTION
    Three sections:

      A. The shared scorer ON THE WIRE (`lib\TestScore.ps1`). Fixture scripts
         are launched as real processes and their last line and exit code read
         back, because the whole defect class is "the last line and the exit
         code disagreed with what the run actually measured" - which is a
         property of the process, not of a function return value.

      B. The analyzer (`lib\AssertedNothingAudit.ps1`) against fixtures, both
         directions: a clean verdict yields nothing, and each violating shape
         is named.

      C. The sweep over `test\win32\*.ps1`: no acceptance script may still have
         a `zero-count` or `early-green` path. `uncounted-final` is reported
         with its number rather than asserted - converting those onto the
         shared scorer is T775.

    `-TeethCheck` proves the section-C assertion can fail: it injects a
    synthesized violator and requires the sweep to go red. Run it after any
    change to the analyzer.

    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this scores scripts, it does not run them.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\AssertedNothingAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function AssertEq([string]$name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path $env:TEMP "ghoztty-t271-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

# ===========================================================================
Write-Host ''
Write-Host '== A: the shared scorer, on the wire'
# ===========================================================================

# Run a fixture and report its LAST line plus its real exit code. `& powershell`
# with the output captured leaves $LASTEXITCODE set by the child, so there is no
# Start-Process handle to cache (the trap `lib\ExitCodeAudit.ps1` sweeps for).
function Invoke-Fixture([string]$Body, [string]$Tag) {
    $f = Join-Path $tmp "$Tag.ps1"
    $lib = (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
    Set-Content -LiteralPath $f -Encoding utf8 -Value (@(
        ". '$lib'"
        $Body
    ) -join "`r`n")
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 |
        ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $last = if ($out.Count -gt 0) { $out[-1] } else { '' }
    return [pscustomobject]@{ Last = $last; Code = $code; All = $out }
}

$r = Invoke-Fixture 'Write-TestVerdict -Pass 7 -Fail 0' 'a-pass'
Assert 'A1 a run with passing assertions still says ALL PASS' ($r.Last -match 'ALL PASS \(7 assertions\)')
AssertEq 'A2 and still exits 0' 0 $r.Code

$r = Invoke-Fixture 'Write-TestVerdict -Pass 0 -Fail 0 -Skipped 1' 'a-nothing'
Assert 'A3 a run that asserted nothing says ASSERTED NOTHING' ($r.Last -match 'ASSERTED NOTHING')
Assert 'A4 and names it as not a pass' ($r.Last -match 'proved nothing')
Assert 'A5 and does NOT say ALL PASS' ($r.Last -notmatch 'ALL PASS')
AssertEq 'A6 and exits 2, not 0' 2 $r.Code
Assert 'A7 and still reports what it skipped' ($r.Last -match '1 SKIPPED')

$r = Invoke-Fixture 'Write-TestVerdict -Pass 4 -Fail 2' 'a-fail'
Assert 'A8 a run with failures says FAILURE(S)' ($r.Last -match '2 FAILURE\(S\)')
AssertEq 'A9 and exits 1 - a different answer from asserting nothing' 1 $r.Code

$r = Invoke-Fixture 'Write-TestVerdict -Pass 3 -Fail 0 -MinPass 20' 'a-too-little'
Assert 'A10 a run far below its own floor says ASSERTED TOO LITTLE' ($r.Last -match 'ASSERTED TOO LITTLE \(3 of at least 20')
AssertEq 'A11 and exits 2 as well' 2 $r.Code

$r = Invoke-Fixture "Write-TestAssertedNothing -Reason 'the port was held' -Label 'X ACCEPTANCE'" 'a-precondition'
Assert 'A12 the precondition helper names the reason' (($r.All -join "`n") -match 'SKIP whole run: the port was held')
Assert 'A13 and scores it as asserted nothing' ($r.Last -match '^X ACCEPTANCE: ASSERTED NOTHING')
AssertEq 'A14 and exits 2' 2 $r.Code

# The label is what a suite driver greps for, so it must survive.
$r = Invoke-Fixture "Write-TestVerdict -Label 'P1 ACCEPTANCE' -Pass 2 -Fail 0 -Unit 'checks'" 'a-label'
AssertEq 'A15 the label and unit reach the verdict line' 'P1 ACCEPTANCE: ALL PASS (2 checks)' $r.Last

# -NoExit is the seam P1-P3 use to tee their failure line into a transcript.
$r = Invoke-Fixture '$v = Write-TestVerdict -Pass 0 -Fail 0 -NoExit; "kind=$($v.Kind) code=$($v.Code)"' 'a-noexit'
AssertEq 'A16 -NoExit returns the verdict instead of exiting' 'kind=nothing code=2' $r.Last
AssertEq 'A17 and leaves the exit code to the caller' 0 $r.Code

# ===========================================================================
Write-Host ''
Write-Host '== B: the analyzer, both directions'
# ===========================================================================

function Get-Kinds([string[]]$Text) {
    return @(Get-AssertedNothingFindings -Path 'fixture.ps1' -Text $Text |
        ForEach-Object { $_.Kind })
}

$clean = @(
    '$script:pass = 0'
    'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)"; exit 0 }'
    'Write-Host "$script:fail FAILURE(S)"'
    'exit 1'
)
AssertEq 'B1 a counted final verdict is clean' 0 (Get-Kinds $clean).Count

$zero = @(
    'if ($noBuild) {'
    '    Write-Host "ALL PASS (0 checks, $script:skipped SKIPPED)"'
    '    exit 0'
    '}'
    'Write-Host "ALL PASS ($script:pass assertions)"'
)
Assert 'B2 a hardcoded zero count is named' ((Get-Kinds $zero) -contains 'zero-count')

$early = @(
    'if ($portHeld) {'
    '    Write-Host "  SKIP whole run: the port was held"'
    '    Write-Host "ALL PASS (1 SKIPPED)"'
    '    exit 0'
    '}'
    'Write-Host "ALL PASS ($script:pass assertions)"'
)
Assert 'B3 a green verdict on an abort path is named' ((Get-Kinds $early) -contains 'early-green')

$earlyRed = @(
    'if ($portHeld) {'
    '    Write-Host "  SKIP whole run: the port was held"'
    '    Write-Host "ASSERTED NOTHING (0 assertions)"'
    '    exit 2'
    '}'
    'Write-Host "ALL PASS ($script:pass assertions)"'
)
AssertEq 'B4 the same branch exiting nonzero is clean' 0 (Get-Kinds $earlyRed).Count

$uncounted = @(
    'if ($script:failures -eq 0) { "ALL PASS"; exit 0 } else { "$($script:failures) FAILURE(S)"; exit 1 }'
)
Assert 'B5 a final verdict with no count is reported' ((Get-Kinds $uncounted) -contains 'uncounted-final')

$scored = @(
    '. (Join-Path $PSScriptRoot "lib\TestScore.ps1")'
    'Write-TestVerdict -Pass $script:passes -Fail $script:failures'
)
AssertEq 'B6 a script on the shared scorer has nothing to report' 0 (Get-Kinds $scored).Count

# Somebody else's verdict being SCORED is not this script emitting one - three
# scripts in the suite compare against a `ALL PASS` line they captured.
$operand = @(
    '$laneText = & other.ps1'
    'Check "the lane passed" ($laneText -match "ALL PASS")'
    'if ($fail -eq 0) { "ALL PASS ($pass assertions)"; exit 0 }'
    'exit 1'
)
AssertEq 'B7 a compared ALL PASS is not read as a verdict' 0 (Get-Kinds $operand).Count

$exempt = @(
    '# asserted-nothing-audit: a helper process with nothing to score'
    'if ($x) { "ALL PASS (0 checks)"; exit 0 }'
)
AssertEq 'B8 the stated-intent marker exempts a file' 0 (Get-Kinds $exempt).Count

# ===========================================================================
Write-Host ''
Write-Host '== C: the sweep over the acceptance suite'
# ===========================================================================

$sweep = @(Get-AssertedNothingSweep (Join-Path $Repo 'test\win32'))
$hardKinds = Get-AssertedNothingHardKinds
$hard = @($sweep | Where-Object { $hardKinds -contains $_.Kind })

if ($TeethCheck) {
    # Synthesized rather than taken off the real state, so this mode keeps its
    # teeth once the suite is clean - which is the whole point and would
    # otherwise be the moment it stopped proving anything.
    $hard = @($hard) + [pscustomobject]@{
        Path = 'synthetic-violator.ps1'; Line = 1; Kind = 'early-green'
        Detail = 'teeth check' }
    Write-Host '  TEETH CHECK: a synthesized early-green violator is in the sweep'
    Assert 'C1 goes red when a script can score green having asserted nothing' ($hard.Count -gt 0)
} else {
    Assert 'C1 no acceptance script can score green having asserted nothing' ($hard.Count -eq 0)
    foreach ($h in $hard) {
        Write-Host "       $(Split-Path $h.Path -Leaf):$($h.Line) $($h.Kind) - $($h.Detail)"
    }
}

# The analyzer must actually have read the suite - a sweep that found no files
# would report zero violations and look identical to a clean one.
$scanned = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'test\win32') -Filter *.ps1 -File).Count
Assert 'C2 the sweep read the whole suite' ($scanned -gt 100)

$uncountedFinal = @($sweep | Where-Object { $_.Kind -eq 'uncounted-final' })
Write-Host "  ($($uncountedFinal.Count) script(s) still print an UNCOUNTED final verdict - T775 converts them)"

# T775's ratchet: the number may fall, never rise. A name list of 40-odd files
# would be noise nobody reads; a ceiling is the same guarantee in one number.
#
# LOWER THIS when you convert a script onto the shared scorer; never raise it to
# make a red run go green. It sat 2 OVER for eight days (T962) because the four
# harnesses filed since it was set each hand-rolled their own verdict, and this
# assertion is the only thing that says so - the ceiling is a ratchet exactly to
# the extent that a run that finds it exceeded is treated as work to do.
$ceiling = 37
Assert "C3 the uncounted-final count did not grow past $ceiling" ($uncountedFinal.Count -le $ceiling)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host ''
Write-TestVerdict -Label 'T271 ACCEPTANCE' -Pass $script:pass -Fail $script:fail -MinPass 20
