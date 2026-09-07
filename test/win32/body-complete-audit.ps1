<#
.SYNOPSIS
    T1039 acceptance - a run that DID NOT FINISH must not print ALL PASS, and
    must not stamp its guard.

.DESCRIPTION
    Four sections:

      A. The shared scorer ON THE WIRE (`lib\TestScore.ps1`). Fixture scripts
         are launched as real processes and their last line and exit code read
         back, because the defect is a property of the process - what the run
         PRINTED and what it EXITED with over a body that unwound - not of a
         function return value. Section A3 reproduces the original shape rather
         than a stand-in: `Get-Content -Raw` on an empty file answers $null, and
         `$null.Trim()` is the statement-terminating error that ended T329's
         run at the top of its last section.

      B. The STAMP gate (`scripts\guard-due.ps1 update`), against a throwaway
         repo. This is the half that outlives the run: a red line scrolls away,
         a stamp keeps a guard quiet until the covered files change again. Both
         directions - an unwound run writes no stamp, a finished one still does.

      C. The analyzer (`lib\BodyCompleteAudit.ps1`) against fixtures, both
         directions: a correctly marked script yields nothing, each violating
         shape is named, and a guarded expression at the top level - the
         `try { $x = [int]$s } catch { $x = 0 }` idiom - is NOT reported, since
         an audit that cries about six of those is an audit nobody reads.

      D. The sweep over `test\win32\*.ps1`: no script scored by the shared
         scorer may still have an unwind path to a green verdict.

    `-TeethCheck` proves the section-D assertion can fail: it injects a
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
. (Join-Path $PSScriptRoot 'lib\BodyCompleteAudit.ps1')

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

$tmp = Join-Path $env:TEMP "ghoztty-t1039-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

$lib = (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# Run a fixture and report its LAST line plus its real exit code. `& powershell`
# with the output captured leaves $LASTEXITCODE set by the child, so there is no
# Start-Process handle to cache (the trap `lib\ExitCodeAudit.ps1` sweeps for).
function Invoke-Fixture([string]$Body, [string]$Tag) {
    $f = Join-Path $tmp "$Tag.ps1"
    Set-Content -LiteralPath $f -Encoding utf8 -Value (@(
        "`$ErrorActionPreference = 'Continue'"
        ". '$lib'"
        $Body
    ) -join "`r`n")
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 |
        ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $last = if ($out.Count -gt 0) { $out[-1] } else { '' }
    return [pscustomobject]@{ Last = $last; Code = $code; All = $out }
}

# ===========================================================================
Write-Host ''
Write-Host '== A: the scorer, on the wire'
# ===========================================================================

$r = Invoke-Fixture @'
try {
    $pass = 7
    Complete-TestBody
} finally { }
Write-TestVerdict -Pass $pass -Fail 0
'@ 'a-finished'
Assert 'A1 a run that reached the end of its body still says ALL PASS' ($r.Last -match 'ALL PASS \(7 assertions\)')
AssertEq 'A2 and still exits 0' 0 $r.Code

# A STATEMENT-terminating error, which is the whole defect class: it unwinds
# the try, runs the finally, and then execution CONTINUES with the statements
# after it - the stamp and the verdict - with the failure count untouched. A
# division by zero, a method on $null, and a bad cast all behave this way under
# `Continue`; a cmdlet raised to `-ErrorAction Stop` does not, and neither does
# `throw` (see A7b).
$r = Invoke-Fixture @'
$pass = 7
try {
    $z = 1 / 0
    $pass = 9
    Complete-TestBody
} finally { Write-Host '  cleanup ran' }
Write-TestVerdict -Pass $pass -Fail 0
'@ 'a-unwound'
Assert 'A3 an unwound body says RUN DID NOT FINISH' ($r.Last -match 'RUN DID NOT FINISH \(7 assertions passed\)')
Assert 'A4 and names what is wrong with the verdict' ($r.Last -match 'unmeasured')
Assert 'A5 and does NOT say ALL PASS' ($r.Last -notmatch 'ALL PASS')
AssertEq 'A6 and exits 2, not 0' 2 $r.Code
Assert 'A7 the finally still ran, which is why this shape hides so well' (($r.All -join "`n") -match 'cleanup ran')

# The contrast worth stating, because it is why this rule is about the QUIET
# error and not about exceptions in general: a bare `throw` at the top level is
# SCRIPT-terminating. The run ends there, no verdict line is printed at all,
# and the exit code is already red without anybody's help.
$r = Invoke-Fixture @'
$pass = 7
try {
    throw 'section 4 blew up'
    Complete-TestBody
} finally { Write-Host '  cleanup ran' }
Write-TestVerdict -Pass $pass -Fail 0
'@ 'a-throw'
Assert 'A7b an explicit throw ends the script with no verdict at all' (
    ($r.All -join "`n") -notmatch '(ALL PASS|RUN DID NOT FINISH)')
Assert 'A7c and is red on its own' ($r.Code -ne 0)

# The original, not a stand-in: -Raw answers $null for an empty file.
$empty = Join-Path $tmp 'empty.txt'
Set-Content -LiteralPath $empty -Value '' -NoNewline
$r = Invoke-Fixture @"
`$pass = 27
try {
    `$raw = Get-Content '$empty' -Raw
    `$said = `$raw.Trim()
    `$pass = 28
    Complete-TestBody
} finally { }
Write-TestVerdict -Pass `$pass -Fail 0 -Label 'ACTIVITY MONITOR DIALED ACCEPTANCE'
"@ 'a-t329'
Assert 'A8 the T329 shape (a .Trim() on an empty file) is caught by the same rule' (
    $r.Last -match 'ACTIVITY MONITOR DIALED ACCEPTANCE: RUN DID NOT FINISH \(27 assertions passed\)')
AssertEq 'A9 and exits 2 where it used to exit 0' 2 $r.Code

# The other verdicts must keep their own wording: this rule only ever speaks
# over a verdict that would otherwise be GREEN.
$r = Invoke-Fixture 'Write-TestVerdict -Pass 4 -Fail 2' 'a-fail'
Assert 'A10 a run with failures still says FAILURE(S), not DID NOT FINISH' ($r.Last -match '2 FAILURE\(S\)')
AssertEq 'A11 and still exits 1 - a different answer from an unwound run' 1 $r.Code

$r = Invoke-Fixture "Write-TestAssertedNothing -Reason 'the port was held' -Label 'X ACCEPTANCE'" 'a-precondition'
Assert 'A12 a deliberate precondition skip still says ASSERTED NOTHING' ($r.Last -match '^X ACCEPTANCE: ASSERTED NOTHING')
AssertEq 'A13 and still exits 2' 2 $r.Code

$r = Invoke-Fixture 'Write-TestVerdict -Pass 3 -Fail 0 -MinPass 20' 'a-too-little'
Assert 'A14 a run below its own floor still says ASSERTED TOO LITTLE' ($r.Last -match 'ASSERTED TOO LITTLE')

$r = Invoke-Fixture '$v = Write-TestVerdict -Pass 5 -Fail 0 -NoExit; "kind=$($v.Kind) code=$($v.Code)"' 'a-noexit'
AssertEq 'A15 -NoExit reports the incomplete verdict too, instead of exiting' 'kind=incomplete code=2' $r.Last

$r = Invoke-Fixture 'Complete-TestBody; "env=$env:GHOZTTY_TEST_BODY"' 'a-env'
AssertEq 'A16 the marker publishes the run state for child processes to read' 'env=complete' $r.Last

$r = Invoke-Fixture '"env=$env:GHOZTTY_TEST_BODY"' 'a-env-armed'
AssertEq 'A17 and the dot-source alone arms it - there is nothing else to remember' 'env=pending' $r.Last

# ===========================================================================
Write-Host ''
Write-Host '== B: the stamp gate, against a throwaway repo'
# ===========================================================================

# A repo-shaped directory holding this guard's own covered files, so `update`
# has something real to hash and its stamp lands where nothing else reads it.
$fakeRepo = Join-Path $tmp 'repo'
New-Item -ItemType Directory -Force (Join-Path $fakeRepo 'test\win32\lib') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fakeRepo 'scripts') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'body-complete-audit.ps1') (Join-Path $fakeRepo 'test\win32\') -Force
Copy-Item (Join-Path $PSScriptRoot 'lib\TestScore.ps1') (Join-Path $fakeRepo 'test\win32\lib\') -Force
Copy-Item (Join-Path $PSScriptRoot 'lib\BodyCompleteAudit.ps1') (Join-Path $fakeRepo 'test\win32\lib\') -Force
$stampFile = Join-Path $fakeRepo 'test\win32\body-complete-audit.stamp.json'
$guardScript = Join-Path $Repo 'scripts\guard-due.ps1'

function Invoke-Stamp([string]$BodyState) {
    $f = Join-Path $tmp "stamp-$BodyState.ps1"
    $set = if ($BodyState -eq 'unset') {
        "Remove-Item env:GHOZTTY_TEST_BODY -ErrorAction SilentlyContinue"
    } else {
        "`$env:GHOZTTY_TEST_BODY = '$BodyState'"
    }
    Set-Content -LiteralPath $f -Encoding utf8 -Value (@(
        $set
        "& powershell -NoProfile -ExecutionPolicy Bypass -File '$guardScript' update -Guard body-complete -Repo '$fakeRepo' 2>&1 | ForEach-Object { `"`$_`" }"
        "exit `$LASTEXITCODE"
    ) -join "`r`n")
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}

Remove-Item -LiteralPath $stampFile -Force -ErrorAction SilentlyContinue
$s = Invoke-Stamp 'pending'
Assert 'B1 an unwound run is REFUSED the stamp' ($s.Text -match 'STAMP REFUSED')
Assert 'B2 and is told the guard stays due, which is the honest answer' ($s.Text -match 'stays due')
Assert 'B3 and no stamp file is written' (-not (Test-Path $stampFile))
AssertEq 'B4 and the refusal has its own exit code, not a silent 0' 3 $s.Code

$s = Invoke-Stamp 'complete'
Assert 'B5 a finished run still stamps' ($s.Text -match 'STAMPED body-complete')
Assert 'B6 and the stamp file is really there' (Test-Path $stampFile)
AssertEq 'B7 and it exits 0 as before' 0 $s.Code

# A caller that is not a scored run at all - a hand `update`, or one of the 175
# scripts that hand-roll their verdict - must be unaffected by this gate.
Remove-Item -LiteralPath $stampFile -Force -ErrorAction SilentlyContinue
$s = Invoke-Stamp 'unset'
Assert 'B8 a caller with no run state stamps exactly as before' ($s.Text -match 'STAMPED body-complete')
AssertEq 'B9 and exits 0' 0 $s.Code

# ===========================================================================
Write-Host ''
Write-Host '== C: the analyzer, both directions'
# ===========================================================================

function Findings([string[]]$Text) { return @(Get-BodyCompleteFindings -Text $Text) }
function Kinds([string[]]$Text) { return (@(Findings $Text | ForEach-Object { $_.Kind }) -join ',') }

$clean = @(
    '. (Join-Path $PSScriptRoot "lib\TestScore.ps1")'
    'function Assert($n, $c) { if ($c) { $script:pass++ } else { $script:fail++ } }'
    'try {'
    '    Assert "one" $true'
    '    Complete-TestBody'
    '} finally { Write-Host "cleanup" }'
    'Write-TestVerdict -Pass $script:pass -Fail $script:fail'
)
AssertEq 'C1 a correctly marked script yields nothing' '' (Kinds $clean)

$unmarkedTry = $clean | ForEach-Object { $_ } | Where-Object { $_ -notmatch 'Complete-TestBody' }
AssertEq 'C2 a measured try with no catch and no marker is named' 'uncaught-try,missing' (Kinds $unmarkedTry)

$markedAfter = @(
    '. (Join-Path $PSScriptRoot "lib\TestScore.ps1")'
    'function Assert($n, $c) { if ($c) { $script:pass++ } else { $script:fail++ } }'
    'try {'
    '    Assert "one" $true'
    '} finally { Write-Host "cleanup" }'
    'Complete-TestBody'
    'Write-TestVerdict -Pass $script:pass -Fail $script:fail'
)
AssertEq 'C3 a marker AFTER the try proves nothing and is named' 'uncaught-try' (Kinds $markedAfter)

$caught = @(
    '. (Join-Path $PSScriptRoot "lib\TestScore.ps1")'
    'function Assert($n, $c) { if ($c) { $script:pass++ } else { $script:fail++ } }'
    'try {'
    '    Assert "one" $true'
    '} catch {'
    '    $script:fail++'
    '} finally { Write-Host "cleanup" }'
    'Complete-TestBody'
    'Write-TestVerdict -Pass $script:pass -Fail $script:fail'
)
AssertEq 'C4 a try that scores its own throw in a catch is the other honest shape' '' (Kinds $caught)

$silent = $caught | ForEach-Object { if ($_ -eq '    $script:fail++') { '    Write-Host "oh well"' } else { $_ } }
AssertEq 'C5 a catch that swallows the throw is named' 'silent-catch' (Kinds $silent)

# A COMMENT naming the scorer is not a use of it. The script most likely to
# name `lib\TestScore.ps1` in prose is the one explaining why it hand-rolls its
# own scoring, and reporting that as two findings is a false finding in the one
# audit whose whole value is that its findings are real.
$commentOnly = @(
    '# This script scores itself rather than through lib\TestScore.ps1, so it'
    '# keeps its own $script:bodyComplete flag.'
    'function Assert($n, $c) { if ($c) { $script:pass++ } else { $script:fail++ } }'
    'try {'
    '    Assert "one" $true'
    '} finally { Write-Host "cleanup" }'
    'if ($script:fail -eq 0) { Write-Host "ALL PASS" }'
)
AssertEq 'C5b a comment naming the scorer does not make a script scored by it' '' (Kinds $commentOnly)
# ...and the rule still has teeth when the same file really does dot-source it.
$commentAndReal = @('. (Join-Path $PSScriptRoot "lib\TestScore.ps1")') + $commentOnly
AssertEq 'C5c but a real dot-source in the same file is still measured' `
    'uncaught-try,missing' (Kinds $commentAndReal)

$guarded = @(
    '. (Join-Path $PSScriptRoot "lib\TestScore.ps1")'
    'function Assert($n, $c) { if ($c) { $script:pass++ } else { $script:fail++ } }'
    'try { $x = [int]"nope" } catch { $x = 0 }'
    'Assert "one" $true'
    'Complete-TestBody'
    'Write-TestVerdict -Pass $script:pass -Fail $script:fail'
)
AssertEq 'C6 a guarded expression at the top level is NOT a run body' '' (Kinds $guarded)

$wrapped = @(
    '. (Join-Path $PSScriptRoot "lib\TestScore.ps1")'
    'function Assert($n, $c) { if ($c) { $script:pass++ } else { $script:fail++ } }'
    'function Run-SectionA { Assert "one" $true }'
    'try { Run-SectionA } finally { Write-Host "cleanup" }'
    'Complete-TestBody'
    'Write-TestVerdict -Pass $script:pass -Fail $script:fail'
)
AssertEq 'C7 a try whose measuring is one call deep is still a run body' 'uncaught-try' (Kinds $wrapped)

$unscored = @(
    'function Assert($n, $c) { if ($c) { $script:pass++ } else { $script:fail++ } }'
    'try { Assert "one" $true } finally { Write-Host "cleanup" }'
    'if ($script:fail -eq 0) { "ALL PASS"; exit 0 }'
)
AssertEq 'C8 a script that does not use the shared scorer is out of this rule' '' (Kinds $unscored)

$exempt = @('# body-audit: this fixture states its intent') + $unmarkedTry
AssertEq 'C9 the stated-intent marker exempts a file' '' (Kinds $exempt)

AssertEq 'C10 a file that does not parse is reported rather than assumed clean' 'parse-error' (
    Kinds @('. (Join-Path $PSScriptRoot "lib\TestScore.ps1")', 'try {', 'Write-TestVerdict -Pass 1 -Fail 0'))

# ===========================================================================
Write-Host ''
Write-Host '== D: the sweep over the suite'
# ===========================================================================

$planted = @()
if ($TeethCheck) {
    $p = Join-Path $PSScriptRoot 'zz-t1039-teeth-check.ps1'
    Set-Content -LiteralPath $p -Encoding ascii -Value @(
        '# planted by body-complete-audit.ps1 -TeethCheck; deleted at the end of the run.'
        '. (Join-Path $PSScriptRoot "lib\TestScore.ps1")'
        'function Assert($n, $c) { if ($c) { $script:pass++ } else { $script:fail++ } }'
        'try { Assert "one" $true } finally { Write-Host "cleanup" }'
        'Write-TestVerdict -Pass $script:pass -Fail $script:fail'
    )
    $planted += $p
    Write-Host '  TEETH CHECK: a real violator is in the swept directory'
}

try {
    $sweep = @(Get-BodyCompleteSweep $PSScriptRoot)
} finally {
    foreach ($p in $planted) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

$hard = @($sweep | Where-Object { (Get-BodyCompleteHardKinds) -contains $_.Kind })
foreach ($x in $hard) {
    Write-Host ("    {0,-13} {1}:{2}  {3}" -f $x.Kind, (Split-Path $x.Path -Leaf), $x.Line, $x.Detail)
}
if ($TeethCheck) {
    Assert 'D1 the sweep sees a planted violator (teeth check)' ($hard.Count -gt 0)
    Assert 'D2 and names it as the planted file' (@($hard | Where-Object { $_.Path -match 'zz-t1039-teeth-check' }).Count -gt 0)
} else {
    AssertEq 'D1 no scored script has an unwind path to a green verdict' 0 $hard.Count
    Assert 'D2 and the sweep actually looked at the scored scripts' (
        @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File |
            Where-Object { (Get-Content $_.FullName -Raw) -match 'TestScore\.ps1' }).Count -ge 50)
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# The marker goes BEFORE the stamp, not before the verdict: the stamp is a
# child process reading this run's state, so a marker set after it would be a
# run refusing to stamp itself.
Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files, and never a teeth check -
# that run deliberately plants a violator, so its red says nothing about the
# suite as it stands.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard body-complete -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'BODY COMPLETE AUDIT' -MinPass 20
