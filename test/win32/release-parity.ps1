# A release cannot silently ship macOS-only (T579).
#
# Until merge-back a full release is two tag pushes (v* on main, win-v* on the
# Windows branch), and forgetting the second one produces no error anywhere --
# the site's links keep answering 200 with an old build. That is how the
# Windows channel sat three weeks stale (T38) and then shipped v1.32.0/v1.33.0
# macOS-only for six days. scripts\check-release-parity.ps1 is the detector:
# newest vX.Y.Z release and newest win-vX.Y.Z release must carry the same
# version, and fork-ci.yml runs it on every push to the Windows branch.
#
# What this asserts:
#
#   A  the checker's verdicts, against fixtures -- including A1, the REAL
#      pre-T577 state (newest v1.31.0 vs newest win-v1.4.1), which is the
#      failure this whole family exists for. Drafts, prereleases and
#      non-semver tags (tip, rc) must never count as either half.
#   B  the wiring: fork-ci.yml really runs the checker on push, the checker
#      parses under PS 5.1, and release.yml is untouched -- a Windows gap must
#      be structurally unable to fail the macOS release.
#   C  live: the checker answers against the real repo (IN STEP or GAP are
#      BOTH passes here -- the harness proves the question gets answered, the
#      CI job is what acts on the answer). Skipped without network/gh.
#
# Read-only; talks to the network only in C.
#
#   powershell -NoProfile -File test\win32\release-parity.ps1
param(
    [string]$Repo = 'D:\git\ghoztty',
    # C is skipped when gh cannot reach the API; -RequireNetwork turns that
    # skip into a failure.
    [switch]$RequireNetwork
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skipped = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}
function Skip($name, $why) {
    if ($RequireNetwork) { "  FAIL $name ($why)"; $script:failures++ }
    else { "  SKIP $name ($why)"; $script:skipped++ }
}

$checker = Join-Path $Repo 'scripts\check-release-parity.ps1'
$tmp = Join-Path $env:TEMP ("release-parity-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Rel($tag, $draft = $false, $pre = $false) {
    return @{ tag_name = $tag; draft = $draft; prerelease = $pre }
}
function Write-Fixture($name, $releases) {
    $path = Join-Path $tmp $name
    # -InputObject on purpose: piping a one-element array into ConvertTo-Json
    # unwraps it to a bare object under PS 5.1, and the checker expects an
    # array like the GitHub API returns.
    ConvertTo-Json -InputObject @($releases) -Depth 4 |
        Set-Content -LiteralPath $path -Encoding ASCII
    return $path
}
function Invoke-Checker($fixturePath) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $checker `
        -ReleasesJson $fixturePath 2>&1
    return @{ Exit = $LASTEXITCODE; Text = ($out | Out-String) }
}

# ============================================================================
"== A: verdicts against fixtures"
# ============================================================================

# A1: the real pre-T577 state. Newest v1.31.0, newest win-v1.4.1 -- 24
# releases where a Windows user saw nothing. The checker must call it a GAP
# and name BOTH versions, because "a person noticing a date" was the only
# detector last time.
$f = Write-Fixture 'a1.json' @(
    (Rel 'v1.31.0'), (Rel 'v1.30.0'), (Rel 'v1.29.0'), (Rel 'v1.28.0'),
    (Rel 'win-v1.4.1'), (Rel 'win-v1.4.0')
)
$r = Invoke-Checker $f
AssertEq 'A1 pre-T577 state is a gap (exit 1)' 1 $r.Exit
Assert 'A1 names the macOS version' ($r.Text -match 'v1\.31\.0')
Assert 'A1 names the Windows version' ($r.Text -match 'win-v1\.4\.1')
Assert 'A1 says GAP' ($r.Text -match '^GAP:')

# A2: in step -- same version on both halves reports nothing wrong.
$f = Write-Fixture 'a2.json' @((Rel 'v1.31.0'), (Rel 'v1.30.0'), (Rel 'win-v1.31.0'))
$r = Invoke-Checker $f
AssertEq 'A2 matched versions exit 0' 0 $r.Exit
Assert 'A2 says IN STEP' ($r.Text -match '^IN STEP:')

# A3: drafts and prereleases are not releases a user can be behind on. A
# drafted v1.32.0 must not turn a matched pair into a gap.
$f = Write-Fixture 'a3.json' @(
    (Rel 'v1.32.0' $true), (Rel 'v1.31.5' $false $true),
    (Rel 'v1.31.0'), (Rel 'win-v1.31.0')
)
$r = Invoke-Checker $f
AssertEq 'A3 draft/prerelease ignored (exit 0)' 0 $r.Exit

# A4: tags that are not exactly (win-)vX.Y.Z are other channels (tip, rc);
# they must count as neither half.
$f = Write-Fixture 'a4.json' @(
    (Rel 'tip'), (Rel 'v2.0.0-rc1'), (Rel 'win-v2.0.0-rc1'),
    (Rel 'v1.31.0'), (Rel 'win-v1.31.0')
)
$r = Invoke-Checker $f
AssertEq 'A4 non-semver tags ignored (exit 0)' 0 $r.Exit
Assert 'A4 keyed on the semver pair' ($r.Text -match 'v1\.31\.0')

# A5: Windows ahead of macOS is not a gap -- the assertion is "Windows is not
# behind", not string equality of the newest two tags.
$f = Write-Fixture 'a5.json' @((Rel 'v1.30.0'), (Rel 'win-v1.31.0'))
$r = Invoke-Checker $f
AssertEq 'A5 Windows ahead exits 0' 0 $r.Exit

# A6: no win-v release at all is the largest possible gap, not an error.
$f = Write-Fixture 'a6.json' @((Rel 'v1.31.0'))
$r = Invoke-Checker $f
AssertEq 'A6 no Windows releases is a gap (exit 1)' 1 $r.Exit
Assert 'A6 says none' ($r.Text -match 'newest Windows release: none')

# A7: the 2026-08-16 live shape -- v1.33.0/v1.32.0 over win-v1.31.0 -- counts
# how far behind, so the report says what a person acts on.
$f = Write-Fixture 'a7.json' @(
    (Rel 'v1.33.0'), (Rel 'v1.32.0'), (Rel 'v1.31.0'), (Rel 'win-v1.31.0')
)
$r = Invoke-Checker $f
AssertEq 'A7 live-shaped gap exits 1' 1 $r.Exit
Assert 'A7 counts 2 releases behind' ($r.Text -match '2 release\(s\) behind')

# A8: a missing fixture is "could not answer" (exit 2), never "fine".
$r = Invoke-Checker (Join-Path $tmp 'does-not-exist.json')
AssertEq 'A8 unreadable input exits 2' 2 $r.Exit

# ============================================================================
"== B: wiring"
# ============================================================================

$forkCi = Get-Content -LiteralPath (Join-Path $Repo '.github\workflows\fork-ci.yml') -Raw
$macWf = Get-Content -LiteralPath (Join-Path $Repo '.github\workflows\release.yml') -Raw

Assert 'B1 fork-ci has a release-parity job' ($forkCi -match '(?m)^  release-parity:')
Assert 'B2 the job runs the checker' ($forkCi -match 'check-release-parity\.ps1')
Assert 'B3 the job runs on push' ($forkCi -match "release-parity:[\s\S]*?github\.event_name == 'push'")
# A Windows gap must be structurally unable to fail the macOS release: the
# checker must not appear anywhere in release.yml's pipeline.
Assert 'B4 release.yml never runs the checker' ($macWf -notmatch 'check-release-parity')

# B5: the checker parses under PS 5.1 (the release-artifacts harness earned
# this gate the hard way: a BOM-less em dash made a whole script unparseable
# under `powershell -File` from the day it was written).
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($checker, [ref]$null, [ref]$parseErrors) | Out-Null
AssertEq 'B5 checker parses cleanly' 0 (@($parseErrors).Count)

# ============================================================================
"== C: live"
# ============================================================================

# IN STEP and GAP are both passes: this section proves the question gets
# ANSWERED against the real API; fork-ci's red/green is what acts on the
# answer. Only exit 2 (could not answer) or garbled output fails it.
$ghOk = $false
try { & gh auth status 2>&1 | Out-Null; $ghOk = ($LASTEXITCODE -eq 0) } catch {}
if (-not $ghOk) {
    Skip 'C1 live check answers' 'gh unavailable or unauthenticated'
} else {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $checker 2>&1
    $code = $LASTEXITCODE
    $text = $out | Out-String
    Assert 'C1 live check answers (exit 0 or 1)' ($code -eq 0 -or $code -eq 1)
    Assert 'C2 live verdict is IN STEP or GAP' ($text -match '^(IN STEP:|GAP:|NOTHING TO COMPARE)')
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this harness been run against the checker as it now
# stands?". Red leaves the stamp alone, and so does a run with skips -- a
# network-less run never asked the live question it would be vouching for.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard release-parity -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) {
    if ($script:skipped -gt 0) { "ALL PASS ($($script:skipped) skipped)" } else { "ALL PASS" }
    exit 0
} else {
    "$($script:failures) FAILURE(S)"
    exit 1
}
