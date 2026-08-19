# verdict-exit-audit acceptance (T221): a script that PRINTS failure EXITS
# failure, and a script that prints success exits success.
#
#   powershell -NoProfile -File test\win32\verdict-exit-audit.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state: the subject is
# the HARNESS, so this reads .ps1 text and runs four small fixtures of its own.
#
# Why it exists. `chooser-menu.ps1` and `host-settings.ps1` ended with a bare
#
#     if ($script:fail -eq 0) { "ALL PASS (...)" } else { "$fail FAILURE(S) (...)" }
#
# and no `exit` anywhere near it, so a run with red assertions fell off the end
# of the script with `$LASTEXITCODE` at 0. `config-errors.ps1` had the identical
# bug (fixed in T217). The summary line was right every time; anything SCORING
# the script by its exit code read a failing run as a pass. All three are fixed,
# so what is left to do is close the CLASS - which is what T221 asked for, in
# its own words: sweep for the shape "rather than trusting the 'no exit 1
# anywhere' search that found these two".
#
# A: the analyzer catches the shapes it exists for, and only those shapes.
# B: the sweep - every acceptance script in test\win32 scores its own verdict.
# C: the rule on the wire - both directions, measured, on real exit codes.
#
# `-TeethCheck` proves section B can go red at all: it synthesizes a violator
# that no exemption covers, and the run PASSES only if the assertion turns over.
# A green sweep whose red path nobody has seen is the same claim this script
# exists to distrust.
param([switch]$TeethCheck)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\VerdictExitAudit.ps1')

# The leading comma is load-bearing: a bare `return @(...)` UNROLLS, so a
# one-finding result comes back as a scalar whose `.Count` is $null and every
# assertion below silently passes (PS 5.1).
function Findings($lines) { return , @(Get-VerdictExitFindings -Text $lines) }
function KindsOf($lines) { return (Findings $lines | ForEach-Object { $_.Kind }) -join ',' }

# ============================================================================
"== A: the analyzer catches the shapes it exists for, and only those shapes"
# ============================================================================
# Fixtures are the literal text of a verdict block, so they read as the code
# they are judging rather than as regex trivia.

# A1 is the defect verbatim - the tail chooser-menu.ps1 and host-settings.ps1
# both shipped with.
$t221 = @(
    'if ($script:fail -eq 0) {',
    '    "ALL PASS ($($script:pass) assertions, $($script:skip) skipped)"',
    '} else {',
    '    "$($script:fail) FAILURE(S) ($($script:pass) passed, $($script:skip) skipped)"',
    '}'
)
Assert "A1 the original T221 tail is a fallthrough" ((KindsOf $t221) -eq 'fallthrough')
Assert "A2 the finding points at the verdict block" ((Findings $t221)[0].Line -eq 1)

# Worse than falling off the end, because it reads as deliberate.
Assert "A3 a failure branch that exits 0 is caught" ((KindsOf @(
    'if ($f -eq 0) { "ALL PASS"; exit 0 } else { "$f FAILURE(S)"; exit 0 }')) -eq 'exits-zero')
Assert 'A4 a bare "exit" on the failure branch is exiting 0' ((KindsOf @(
    'if ($f -eq 0) { "ALL PASS"; exit 0 } else { "$f FAILURE(S)"; exit }')) -eq 'exits-zero')

# The other direction, and the reason the rule is not just "contains exit 1":
# drop the `exit 0` out of the early-return shape and a GREEN run announces
# failure and exits 1.
Assert "A5 a pass branch that falls into the failure verdict is caught" ((KindsOf @(
    'if ($f -eq 0) { "ALL PASS" }',
    '"$f FAILURE(S)"',
    'exit 1')) -eq 'pass-falls-through')

# All three shapes the suite actually uses must stay silent. These are copied
# from real scripts: the if/else one-liner (agent-pipe), the early return
# (chooser-sessions), and the shared computed exit (skip-visibility).
Assert "A6 the if/else one-liner is clean" ((KindsOf @(
    'if ($script:failures -eq 0) { "ALL PASS"; exit 0 }',
    'else { "$($script:failures) FAILURE(S)"; exit 1 }')) -eq '')
Assert "A7 the early-return shape is clean" ((KindsOf @(
    'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)"; exit 0 }',
    'Write-Host "$script:fail FAILURE(S) ($script:pass passed)"',
    'exit 1')) -eq '')
Assert "A8 a computed exit code is not statically judged" ((KindsOf @(
    'if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }',
    'exit ([int]($script:failures -gt 0))')) -eq '')

# Somebody else's verdict is not this script's verdict. go-loop-guard and
# crash-stacks both assert on the ALL PASS of a tool they invoke, and
# skip-visibility WRITES one into a fixture file - all three would otherwise be
# scored against a line they never print.
Assert "A9 a compared-against ALL PASS is not mistaken for a verdict" ((KindsOf @(
    'Assert "the tool passed" ($out -match ''ALL PASS'')',
    'if ($f -eq 0) { "ALL PASS"; exit 0 } else { "$f FAILURE(S)"; exit 1 }')) -eq '')
Assert "A10 an ALL PASS written into a fixture is stepped past" ((KindsOf @(
    '@(''"ALL PASS ($script:pass)"'') | Set-Content $fixture',
    'if ($f -eq 0) { "ALL PASS"; exit 0 } else { "$f FAILURE(S)"; exit 1 }')) -eq '')

# The exemption, and the thing it must not become: a marker turns a file off
# entirely, so it is a statement about the whole file and reads as one.
Assert "A11 a file with no verdict at all is a finding" ((KindsOf @('"hello"')) -eq 'no-verdict')
Assert "A12 the # verdict-audit: marker exempts a helper" ((KindsOf @(
    '# verdict-audit: a helper process, nothing to score',
    '"hello"')) -eq '')

# A13/A14 (T963): the wording of the PASS verdict is itself a choice in several
# scripts - `ALL PASS (N)` for a clean run, `ALL PASS (N, K SKIPPED)` for one
# that skipped sections - so the innermost `if` around the last ALL PASS is the
# SKIPPED question, not the pass/fail question. Reading that one scored
# `tab-tooltip.ps1` as a fallthrough while its real failure path exited 1, and
# would have gone quiet over an `exit 0` nested where no failure ever reaches.
Assert "A13 a pass verdict nested inside its own if is scored against the real failure branch" ((KindsOf @(
    'if ($script:fail -eq 0) {',
    '    if ($script:skipped) { "ALL PASS ($script:pass assertions, $script:skipped SKIPPED)" }',
    '    else { stamp-the-guard; "ALL PASS ($script:pass assertions)" }',
    '}',
    'else { "$script:fail FAILURE(S) / $script:pass passed"; exit 1 }')) -eq '')
Assert "A14 and an exit 0 nested in the pass branch does not answer for the failure path" ((KindsOf @(
    'if ($script:fail -eq 0) {',
    '    if ($script:skipped) { "ALL PASS ($script:pass assertions, $script:skipped SKIPPED)"; exit 0 }',
    '    else { "ALL PASS ($script:pass assertions)"; exit 0 }',
    '}',
    'else { "$script:fail FAILURE(S) / $script:pass passed" }')) -eq 'fallthrough')

# ============================================================================
""
"== B: the sweep - every acceptance script scores its own verdict"
# ============================================================================
$suite = Join-Path $Repo 'test\win32'

# -TeethCheck plants a real violator IN the swept directory rather than
# appending a name to the result afterwards. Appending would assert that a list
# somebody just added to is non-empty - true whatever the analyzer does, and
# therefore no teeth at all. This way the sweep has to walk the tree and find
# it, which is the code path section B actually depends on. try/finally so a
# failure mid-section cannot leave the fixture in the repo.
$planted = $null
try {
    if ($TeethCheck) {
        $planted = Join-Path $suite 'zz-verdict-teeth-fixture.ps1'
        @(
            '# A planted violator (verdict-exit-audit.ps1 -TeethCheck). Deleted by',
            '# the finally block that wrote it; safe to delete by hand if it survives.',
            'if ($f -eq 0) { "ALL PASS (1 assertions)" } else { "$f FAILURE(S)" }'
        ) | Set-Content -LiteralPath $planted -Encoding ASCII
        "  TEETH CHECK: planted $(Split-Path $planted -Leaf) - a verdict that scores nothing"
    }

    $sweep = @(Get-VerdictExitSweep $suite)
    $scripts = @(Get-ChildItem $suite -Filter *.ps1 -File)
    $violators = @($sweep | ForEach-Object { Split-Path $_.Path -Leaf } | Sort-Object -Unique)

    if ($TeethCheck) {
        Assert "B1 the sweep finds a planted violator" (
            $violators -contains 'zz-verdict-teeth-fixture.ps1')
        Assert "B1b and calls it a fallthrough" ((@($sweep | Where-Object {
            (Split-Path $_.Path -Leaf) -eq 'zz-verdict-teeth-fixture.ps1' }).Kind) -eq 'fallthrough')
    } else {
        Assert "B1 every acceptance script scores its own verdict" ($violators.Count -eq 0)
        foreach ($v in $violators) {
            "       $v"
            $sweep | Where-Object { (Split-Path $_.Path -Leaf) -eq $v } |
                ForEach-Object { "         L$($_.Line) $($_.Kind): $($_.Detail)" }
        }
    }
} finally {
    if ($planted) { Remove-Item -LiteralPath $planted -Force -ErrorAction SilentlyContinue }
}

# The count is the evidence T221 asked for: "checked N scripts, all exit
# correctly" is what closes the class, not a silent green line. An empty sweep
# over an empty directory would also be silent, which is what B2 rules out.
Assert "B2 the sweep actually read the suite" ($scripts.Count -gt 100)
"  (checked $($scripts.Count) acceptance scripts; $($violators.Count) violation(s))"

# ============================================================================
""
"== C: the rule on the wire - both directions, on real exit codes"
# ============================================================================
# The analyzer reads text; this measures the codes. Fixtures rather than the
# real GUI scripts because a verdict block is four lines and a chooser run is
# ten minutes - and because a fixture can be forced red on demand, which is the
# direction that has never been exercised in anger.
function Measure-Fixture($name, $body, $switches) {
    $p = Join-Path $env:TEMP "verdict-exit-$PID-$name.ps1"
    $body | Set-Content -LiteralPath $p -Encoding ASCII
    $log = Join-Path $env:TEMP "verdict-exit-$PID-$name.log"
    # cmd /c so the exit code is the child's own, not PowerShell's opinion of
    # it, and so the redirect is done by the shell (T197: Start-Process's
    # ExitCode reads back empty unless .Handle was cached while it was alive).
    cmd /c "powershell -NoProfile -File `"$p`" $switches > `"$log`" 2>&1" | Out-Null
    $code = $LASTEXITCODE
    $out = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $p, $log -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Code = $code
        Last = if ($out.Count) { $out[-1].Trim() } else { '<no output>' }
    }
}

# The two canonical shapes, each run green and red. This is the pair of claims
# T221 made and neither of the two named scripts had ever been run for: exits 1
# on failure, AND exits 0 on success.
$ifElse = @(
    'param([int]$Fail = 0)',
    '$script:pass = 3',
    'if ($Fail -eq 0) { "ALL PASS ($script:pass assertions)"; exit 0 }',
    'else { "$Fail FAILURE(S) ($script:pass passed)"; exit 1 }'
)
$early = @(
    'param([int]$Fail = 0)',
    '$script:pass = 3',
    'if ($Fail -eq 0) { "ALL PASS ($script:pass assertions)"; exit 0 }',
    '"$Fail FAILURE(S) ($script:pass passed)"',
    'exit 1'
)

foreach ($shape in @(
    @{ Name = 'ifelse'; Body = $ifElse; Label = 'the if/else shape' },
    @{ Name = 'early';  Body = $early;  Label = 'the early-return shape' })) {

    $green = Measure-Fixture $shape.Name $shape.Body ''
    $red = Measure-Fixture $shape.Name $shape.Body '-Fail 2'

    Assert "C $($shape.Label): a green run says ALL PASS" ($green.Last -match '^ALL PASS')
    Assert "C $($shape.Label): a green run exits 0" ($green.Code -eq 0)
    Assert "C $($shape.Label): a red run says FAILURE(S)" ($red.Last -match 'FAILURE\(S\)')
    Assert "C $($shape.Label): a red run exits 1" ($red.Code -eq 1)
    if ($red.Code -ne 1) { "       red run exited $($red.Code) after printing: $($red.Last)" }
}

# And the negative control for the whole section: the defect itself, on the
# wire. Without this, C measures two shapes that pass and never demonstrates
# that the thing being guarded against is real.
$broken = @(
    'param([int]$Fail = 0)',
    'if ($Fail -eq 0) { "ALL PASS (3 assertions)" }',
    'else { "$Fail FAILURE(S) (3 passed)" }'
)
$brokenRed = Measure-Fixture 'broken' $broken '-Fail 2'
Assert "C the unfixed shape is the defect: prints FAILURE(S), exits 0" (
    $brokenRed.Last -match 'FAILURE\(S\)' -and $brokenRed.Code -eq 0)
Assert "C and the analyzer would have caught it" ((KindsOf $broken) -eq 'fallthrough')

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this sweep been run against the suite as it now stands?" -
# the question nobody could answer while this audit sat red at HEAD (T963).
# NOT under -TeethCheck: that run plants a violator in the swept directory and
# scores the analyzer for finding it, so it never observes a clean suite and
# must not claim to have.
if ($script:failures -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard verdict-exit -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
