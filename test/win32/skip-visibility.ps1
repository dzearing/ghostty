# skip-visibility acceptance (T219): a section this suite SKIPPED is named in
# the one line anybody reads.
#
#   powershell -NoProfile -File test\win32\skip-visibility.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state: the subject is
# the HARNESS, so this reads .ps1 text, runs one pure script and one four-line
# fixture of its own.
#
# Why it exists. `ipc-version.ps1` asserted the About box is a `#32770`
# MessageBox; it has been a native GhozttyConfirmDialog since the T50 chrome
# pass. Every run still printed ALL PASS, because the foreground grab kept
# losing the race and the whole palette section took its SKIP branch instead
# (T217). A skip is legitimate - pwsh is not installed, there is no network, a
# release build compiled the debug oracle out. A skip the RESULT cannot see is
# an un-run assertion wearing a green hat, and go.md reads exactly one line
# (`| Select-Object -Last 1`), so a `(2 section(s) SKIPPED)` line printed above
# the verdict is invisible to the only reader there is.
#
# A: the analyzer catches the shape it exists for, and only that shape.
# B: the sweep - every violator is a named, task-linked exception, and every
#    exception still violates, so the list can only shrink.
# C: the rule on the wire - a real script's last line carries its skip count.
#
# `-TeethCheck` proves section B can go red at all: it drops a real violator off
# the exception list and adds a converted script to it, and the run PASSES only
# if both assertions turn over. A green sweep whose red path nobody has seen is
# the same claim this whole script exists to distrust.
param([switch]$TeethCheck)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\SkipAudit.ps1')

# The leading comma is load-bearing: a bare `return @(...)` UNROLLS, so a
# one-finding result comes back as a scalar whose `.Count` is $null and every
# assertion below silently passes (PS 5.1).
function Findings($lines) { return , @(Get-SkipAuditFindings -Text $lines) }
function KindsOf($lines) { return (Findings $lines | ForEach-Object { $_.Kind }) -join ',' }

# ============================================================================
"== A: the analyzer catches the shape it exists for, and only that shape"
# ============================================================================
# Fixtures are the literal text of a summary block, so they read as the code
# they are judging rather than as regex trivia.

$unreported = @(
    # skip-audit: fixture text for the analyzer, not this script skipping
    'if ($null -eq $hot) { Write-Host ''SKIP T233 (rest): empty capture'' }',
    'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }'
)
$f = Findings $unreported
Assert "A1 a skip with a silent ALL PASS is two findings" ($f.Count -eq 2)
Assert "A2 the kinds are uncounted + unreported" ((KindsOf $unreported) -eq 'uncounted,unreported')
Assert "A3 the unreported finding points at the verdict line" (
    $f.Count -eq 2 -and ($f | Where-Object { $_.Kind -eq 'unreported' }).Line -eq 2)

$fixed = @(
    'if ($null -eq $hot) { Write-Host ''SKIP T233 (rest): empty capture''; $script:skipped++ }',
    'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))" }'
)
Assert "A4 the canonical shape is clean" ((Findings $fixed).Count -eq 0)

# Counted but unreported is still the whole defect: the number exists and the
# line nobody-but-a-human-scrolling ever sees is where it goes.
$countedOnly = @(
    'if ($null -eq $hot) { Write-Host ''SKIP T233 (rest): empty capture''; $script:skipped++ }',
    'if ($script:skipped -gt 0) { Write-Host "($script:skipped section(s) SKIPPED)" }',
    'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }'
)
Assert "A5 a count printed ABOVE the verdict is still unreported" (
    (KindsOf $countedOnly) -eq 'unreported')

# Reported without a counter, which several scripts legitimately do when the
# skip is a single named thing.
$namedInline = @(
    'if (-not (Get-Command $shellPath)) {',
    '    Write-Host "SKIP  $Shell is not installed on this box"',
    '    Write-Host "ALL PASS ($script:pass assertions, $Shell skipped)"',
    '    exit 0',
    '}'
)
Assert "A6 a verdict that names the skip in words is clean" ((Findings $namedInline).Count -eq 0)

# The early-exit shape: the SKIP line IS the last line, so there is no summary
# for it to be missing from.
$skipAll = @(
    'if (-not $sent) { Write-Host ''SKIP ALL: harness could not post keys''; exit 0 }',
    'if ($script:fail -eq 0) { Write-Host "ALL PASS" }'
)
Assert "A7 SKIP-then-exit needs no counter" ((Findings $skipAll).Count -eq 0)

# ...but printing SKIP, then ALL PASS, then exiting is the defect. agent-user-env
# did exactly this, and its last line read ALL PASS with a section un-run.
$skipThenPass = @(
    'if ($null -eq $marker) {',
    '    "  SKIP no usable HKCU\Environment\Path entry on this box"',
    '    "ALL PASS"',
    '    exit 0',
    '}'
)
Assert "A8 SKIP-then-ALL-PASS-then-exit is caught" ((KindsOf $skipThenPass) -match 'uncounted')

# The three shapes that are NOT this script skipping. Every one of them was
# reported by a looser first draft of the analyzer.
$notSkips = @(
    'Assert ''D13 but never claims OK'' (@($out)[-1] -like ''DELIVER SKIPPED:*'')',
    'Set-Content $f ''status: "skipped(split -> T2, T5)"''',
    'Write-Host ''NEGATIVE CONTROL: arm A is inverted to "the walk SKIPPED a pane"''',
    'Write-Host "WARN  too few perf log windows - telemetry assertions skipped"',
    'if ($script:fail -eq 0) { Write-Host "ALL PASS" }'
)
Assert "A9 assertions, fixture data, prose and WARNs are not skip sites" (
    (Findings $notSkips).Count -eq 0)

# A verdict asserted about ANOTHER tool's output is not this script's verdict.
$foreignVerdict = @(
    'Write-Host ''SKIP P13 (node not on PATH)''; $script:skipped++',
    'Assert ''P13 the dashboard reads the beacon'' ($dashOut -match ''ALL PASS'')'
)
Assert "A10 an ALL PASS asserted about a subprocess is not a verdict line" (
    (Findings $foreignVerdict).Count -eq 0)

# The stated-intent escape hatch, same convention as `# persistence:` and
# `# exitcode-audit:`.
$marked = @(
    '# skip-audit: this IS the counted sink',
    'Write-Host "  SKIP $Label"',
    'if ($script:fail -eq 0) { Write-Host "ALL PASS" }'
)
Assert "A11 a # skip-audit: marker exempts a site" ((Findings $marked).Count -eq 0)

# The bug that emptied the sweep to zero while looking like a tightening: the
# `-Host` in `Write-Host "SKIP ..."` matched a `-\w+\s*['"]` operand pattern.
$writeHost = @(
    'Write-Host "SKIP D: injection did not stick"',
    'if ($script:fail -eq 0) { Write-Host "ALL PASS" }'
)
Assert "A12 Write-Host's own hyphen does not read as a comparison operator" (
    (Findings $writeHost).Count -eq 2)

# ============================================================================
""
"== B: the sweep - violators are named exceptions, and the list only shrinks"
# ============================================================================
$sweep = @(Get-SkipAuditSweep (Join-Path $Repo 'test\win32'))
$pending = Get-SkipAuditPending
$violators = @($sweep | ForEach-Object { Split-Path $_.Path -Leaf } | Sort-Object -Unique)

if ($TeethCheck) {
    # Synthesized rather than taken off the real state, so the mode keeps its
    # teeth once the pending list reaches EMPTY - which is the whole point of
    # the list and would otherwise be the moment this stopped proving anything.
    $violators = @($violators) + 'unconverted-fixture.ps1'   # violates, unlisted
    $pending = @{ 'ipc-version.ps1' = 'T219' }               # converted, listed
    "  TEETH CHECK: a violator with no exception, and a converted script still listed"
}

$unlisted = @($violators | Where-Object { -not $pending.ContainsKey($_) })
$stale = @($pending.Keys | Where-Object { $violators -notcontains $_ })

if ($TeethCheck) {
    Assert "B1 goes red when a violator is not a named exception" ($unlisted.Count -gt 0)
    Assert "B2 goes red when a converted script is still listed" ($stale.Count -gt 0)
} else {
    Assert "B1 no script violates the rule without being a named exception" ($unlisted.Count -eq 0)
    if ($unlisted.Count -gt 0) {
        foreach ($u in $unlisted) {
            "       $u"
            $sweep | Where-Object { (Split-Path $_.Path -Leaf) -eq $u } |
                ForEach-Object { "         L$($_.Line) $($_.Kind): $($_.Detail)" }
        }
    }

    # An exception that no longer violates must LEAVE the list. Without this the
    # list is a permanent allowlist rather than a shrinking one, which is how a
    # baseline outlives the work it was a baseline for.
    Assert "B2 every listed exception still violates (none is stale)" ($stale.Count -eq 0)
    if ($stale.Count -gt 0) { foreach ($s in $stale) { "       $s is converted - drop it from `$SkipAuditPending" } }
}

$missingFile = @($pending.Keys | Where-Object {
    -not (Test-Path (Join-Path $Repo "test\win32\$_")) })
Assert "B3 every listed exception is a file that exists" ($missingFile.Count -eq 0)

$unlinked = @($pending.Keys | Where-Object { $pending[$_] -notmatch '^T\d+$' })
Assert "B4 every exception names the task that converts it" ($unlinked.Count -eq 0)

$taskDir = Join-Path $Repo 'docs\design\windows-parity-tasks'
$deadTask = @($pending.Values | Sort-Object -Unique | Where-Object {
    -not (Test-Path (Join-Path $taskDir "$_.md")) })
Assert "B5 those tasks are filed" ($deadTask.Count -eq 0)

"  ($($violators.Count) pending script(s): $($violators -join ', '))"

# ============================================================================
""
"== C: the rule on the wire - the last line carries the count"
# ============================================================================
# A pure, four-second script with two forceable skip branches. Its output is
# the oracle rather than its exit code (T197).
$pure = Join-Path $PSScriptRoot 'upgrade-resume-readiness.ps1'
$log = Join-Path $env:TEMP "skip-visibility-$PID.log"
cmd /c "powershell -NoProfile -File `"$pure`" -PureOnly > `"$log`" 2>&1" | Out-Null
$out = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
$last = if ($out.Count) { $out[-1].Trim() } else { '<no output>' }
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

Assert "C1 the skipped sections printed their SKIP lines" (
    (@($out | Where-Object { $_ -cmatch '^\s*SKIP' })).Count -eq 2)
Assert "C2 the LAST line carries the count, not just an ALL PASS" (
    $last -eq 'ALL PASS (2 SKIPPED)')
if ($last -ne 'ALL PASS (2 SKIPPED)') { "       last line was: $last" }

# The count is real rather than a constant: a run with nothing skipped says
# nothing, and two skips say two. The fixture is the canonical shape from
# lib\SkipAudit.ps1, so this measures what that file tells people to write.
$fixture = Join-Path $env:TEMP "skip-shape-$PID.ps1"
@(
    'param([int]$Skips = 0)',
    '$script:pass = 3',
    'for ($i = 1; $i -le $Skips; $i++) { "  SKIP section $i"; $script:skipped++ }',
    '"ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"'
) | Set-Content -LiteralPath $fixture -Encoding ASCII

$none = (& powershell -NoProfile -File $fixture -Skips 0 | Select-Object -Last 1)
$two = (& powershell -NoProfile -File $fixture -Skips 2 | Select-Object -Last 1)
Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
Assert "C3 a clean run says nothing about skips" ($none -eq 'ALL PASS (3 assertions)')
Assert "C4 two skips read back as two" ($two -eq 'ALL PASS (3 assertions, 2 SKIPPED)')

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
