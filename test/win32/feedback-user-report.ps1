# T1321 acceptance: a report drained from the viewer feedback queue is treated
# as a USER REPORT, on the bytes that actually ship.
#
# Why this exists. T1315 made `user-report: true` the thing that turns closing
# a task into a same-day release request, because a fix a person asked for is
# not delivered until they can install it - on 2026-09-03 the user downloaded
# the same broken installer twice and reported the same bug twice, with the fix
# sitting on the branch (T1294). The single biggest producer of genuine user
# reports is the viewer feedback button, and the skill that drains its queue
# (`process-feedback`) ended at "commit and move on": nothing anywhere recorded
# that a person was waiting, so every one of those fixes rode the ordinary
# daily cadence.
#
# THE RULE this checks, in the skill document the app installs:
#
#   complete path  records a release request
#                  (`scripts/daily-publish.ps1 -Request -Reason ...`)
#   blocked path   files what it did not fix with
#                  (`scripts/parity-tasks.ps1 new -UserReport`), and says what
#                  the flag buys (`user-report: true`)
#
# and that the two copies of that document - the Mac bundle resource and the
# `@embedFile`d Windows asset - are byte-identical, since the Windows app ships
# the second one and a drift there is a fix nobody is told is waiting.
#
# `upstream/` is deliberately NOT compared: it is the pristine mirror of
# tip-of-main's `macos/Resources/Ghoztty/` (GhosttyAssets.zig's header), so it
# is EXPECTED to lag this branch until the cutover. Asserting equality there
# would fail the moment this branch edits a shipped skill, which is exactly
# what it is for.
#
# Static scan, no app, no CLI - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\feedback-user-report.ps1
#   powershell -NoProfile -File test\win32\feedback-user-report.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it only reads files.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

function Read-Text([string]$Path) {
    # ReadAllText decodes the UTF-8 the repo is written in; PS 5.1's
    # Get-Content would read it as the ANSI codepage and mangle every dash.
    try { return [System.IO.File]::ReadAllText($Path) } catch { return '' }
}

$MacSkill = Join-Path $Repo 'macos\Resources\Ghoztty\skills\process-feedback\SKILL.md'
$WinSkill = Join-Path $Repo 'src\apprt\win32\assets\ghoztty\skills\process-feedback\SKILL.md'
$Assets   = Join-Path $Repo 'src\apprt\win32\GhosttyAssets.zig'
$Viewers  = Join-Path $Repo 'docs\claude\viewers.md'

# The three phrases that carry the rule. Each is checked as a literal, because
# a paraphrase in the skill is a paraphrase an agent has to interpret - the
# whole point is that the document names the exact command to run.
$Required = @(
    @{ Key = 'daily-publish.ps1 -Request'
       Why = 'the complete path records a release request' },
    @{ Key = 'parity-tasks.ps1 new -UserReport'
       Why = 'the blocked/deferred path files as a user report' },
    @{ Key = 'user-report: true'
       Why = 'the document says what the flag actually buys' }
)

function Get-Missing([string]$Text) {
    $missing = @()
    foreach ($r in $Required) {
        if ($Text.IndexOf($r.Key, [StringComparison]::Ordinal) -lt 0) { $missing += $r.Key }
    }
    return ,$missing
}

# ---------------------------------------------------------------------------
# A: the scanner bites - synthetic fixtures, both directions. A check that has
#    only ever been seen saying "fine" is indistinguishable from one that
#    cannot say anything else.
# ---------------------------------------------------------------------------
""
"A: the scan itself"
$goodFixture = @'
Commit, then run:
powershell -NoProfile -File scripts/daily-publish.ps1 -Request -Reason "x"
and file the rest with scripts/parity-tasks.ps1 new -UserReport -Title "y",
which writes user-report: true.
'@
$badFixture = @'
Commit, then move the folder to complete/ and reset context.
'@
Assert 'A1 a compliant document reports nothing missing' ((Get-Missing $goodFixture).Count -eq 0)
Assert 'A2 a document with the wiring stripped reports all three' ((Get-Missing $badFixture).Count -eq 3) `
    "(reported $((Get-Missing $badFixture).Count))"

# ---------------------------------------------------------------------------
# B: the live skill documents carry the rule.
# ---------------------------------------------------------------------------
""
"B: the shipped skill documents"
foreach ($pair in @(@{ N = 'mac bundle resource'; P = $MacSkill }, @{ N = 'embedded win32 asset'; P = $WinSkill })) {
    Assert "B0 the $($pair.N) exists" (Test-Path -LiteralPath $pair.P) $pair.P
    $missing = Get-Missing (Read-Text $pair.P)
    foreach ($m in $missing) { "  MISSING in $($pair.N): $m" }
    Assert "B1 the $($pair.N) carries all three phrases" ($missing.Count -eq 0) `
        "($($missing.Count) missing)"
}

# ---------------------------------------------------------------------------
# C: the copy the Windows app embeds is the copy the Mac app ships. The Windows
#    build reads its skill out of the exe, so a drift here means the two
#    platforms hand an agent different instructions - the divergence CLAUDE.md
#    calls the defect.
# ---------------------------------------------------------------------------
""
"C: the two copies agree"
$macText = Read-Text $MacSkill
$winText = Read-Text $WinSkill
Assert 'C1 mac and win32 copies are byte-identical' `
    ($macText.Length -gt 0 -and $macText -ceq $winText) `
    "(mac $($macText.Length) chars, win $($winText.Length) chars)"

# ---------------------------------------------------------------------------
# D: the rule is asserted where the bytes ship (the none-lane tripwire) and
#    explained where a reader lands (the viewers doc). A rule in a document
#    that nothing checks is a rule that decays; a check nobody can find is a
#    check nobody maintains.
# ---------------------------------------------------------------------------
""
"D: the rule is guarded and documented"
$assetsText = Read-Text $Assets
Assert 'D1 GhosttyAssets.zig has the none-lane tripwire' `
    ($assetsText.IndexOf('daily-publish.ps1 -Request', [StringComparison]::Ordinal) -ge 0 -and
     $assetsText.IndexOf('parity-tasks.ps1 new -UserReport', [StringComparison]::Ordinal) -ge 0)
Assert 'D2 the embedded asset is the file this harness checked' `
    ($assetsText.IndexOf('assets/ghoztty/skills/process-feedback/SKILL.md', [StringComparison]::Ordinal) -ge 0)
$viewersText = Read-Text $Viewers
Assert 'D3 docs\claude\viewers.md describes the intake obligation' `
    ($viewersText.IndexOf('process-feedback', [StringComparison]::Ordinal) -ge 0 -and
     $viewersText.IndexOf('-UserReport', [StringComparison]::Ordinal) -ge 0)

# ---------------------------------------------------------------------------
# Negative control: the scan must go RED against the REAL shipped file, not
# only against section A's strings. Strip the wiring out of the embedded asset,
# re-scan it, and assert - INVERTED - that nothing was reported. A working scan
# fails that assertion, so a healthy repo scores exactly 1 FAILURE here; a scan
# whose needle quietly stopped matching would pass it and be caught. The file
# is restored either way, including on a crash.
# ---------------------------------------------------------------------------
if ($NegativeControl) {
    ""
    "NEGATIVE CONTROL: asserting a gutted asset reports nothing missing - a working scan MUST fail this"
    $original = [System.IO.File]::ReadAllText($WinSkill)
    $missing = @()
    try {
        $gutted = $original
        foreach ($r in $Required) { $gutted = $gutted.Replace($r.Key, 'REDACTED') }
        [System.IO.File]::WriteAllText($WinSkill, $gutted, (New-Object Text.UTF8Encoding($false)))
        # No `@(...)` around the call: Get-Missing returns a comma-wrapped array
        # so an empty result survives, and wrapping the already-unrolled result
        # again would collapse three findings into one element (PS 5.1).
        $missing = Get-Missing (Read-Text $WinSkill)
    } finally {
        [System.IO.File]::WriteAllText($WinSkill, $original, (New-Object Text.UTF8Encoding($false)))
    }
    Assert 'N1 a gutted asset reports nothing missing (inverted)' ($missing.Count -eq 0) `
        "(reported $($missing.Count), which is the healthy answer)"
    Assert 'N2 the asset is restored byte for byte' `
        ([System.IO.File]::ReadAllText($WinSkill) -ceq $original)
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this scan been run against the tree as it now stands?".
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard feedback-user-report -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
else { "$script:failures FAILURE(S) ($script:passes passed)"; exit 1 }
