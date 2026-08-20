# T957 acceptance - Stage 0 of the merge-back plan: the upstream remote stays
# wired up, and the append-only files merge by UNION instead of conflicting.
#
#   powershell -NoProfile -File test\win32\upstream-remote.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state: the subject is
# git configuration and git's own merge machinery, so this reads the repo and
# runs its merges inside throwaway repos under $env:TEMP.
#
# isolation: none - no ghoztty binary is run and no CLI verb is invoked; the
# only executable this script starts is git (T680 meta-check reads this marker).
#
# WHY IT EXISTS
#
# docs\design\windows-parity-merge-back-plan.md pins six staged merge points and
# a fork point by sha. Until T957 those objects were reachable from NOTHING: an
# earlier `divergence-inventory.ps1` had fetched them by sha into no ref, so a
# `git gc` was free to drop them and the plan would still READ correctly with
# none of its shas resolving. Section A is the assertion that this cannot be
# true again, and it derives the sha list FROM the plan, so a re-cut stage is
# covered the day it is written rather than the day somebody remembers this file.
#
# Section B is the durability half. A remote is LOCAL config - it cannot arrive
# by `git pull`, and a fresh clone or the Mac seat's clone starts without one -
# so `scripts\upstream-remote.ps1 ensure` re-asserts it every turn from the
# claim, and what is checked here is that `ensure` actually REPAIRS a repo
# rather than only reporting on a healthy one.
#
# Section C is the union merge driver, measured on the REAL divergence rather
# than a fixture: our `.gitignore` and upstream's both grew lines in the same
# two regions, which is a textual conflict in every merge stage. The negative
# control (the same merge with no `.gitattributes`) is what proves the driver is
# doing the work - a "merged clean" with nothing to resolve would assert nothing.
#
# Section D is the honesty check on the attribute list: a `merge=union` line
# whose pattern matches no file, or a listed path that no longer exists, is a
# driver that silently is not there.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name $detail" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

$UpstreamUrl = 'https://github.com/ghostty-org/ghostty.git'
$EnsureScript = Join-Path $Repo 'scripts\upstream-remote.ps1'

# Every git call here reports through its exit code. SilentlyContinue is
# function-scoped so a git that writes to stderr - a missing remote and an
# unknown sha are both NORMAL answers in this script - does not land a
# NativeCommandError on the host, and nothing formats a merged stream (T883).
function Invoke-GitIn {
    param([string]$At, [string[]]$GitArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $At @GitArgs 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n").Trim(); Lines = $out }
}
function Test-GitOk {
    param([string]$At, [string[]]$GitArgs)
    return (Invoke-GitIn $At $GitArgs).Code -eq 0
}
# Commits in the fixtures carry their identity on the command line, so a box
# with no user.name configured still runs this script.
$Ident = @('-c', 'user.email=t@example.invalid', '-c', 'user.name=t', '-c', 'commit.gpgsign=false')
function Invoke-GitCommit {
    param([string]$At, [string[]]$GitArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $At @Ident @GitArgs 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n").Trim() }
}

$sandbox = Join-Path $env:TEMP "ghoztty-upstream-remote-$PID"
if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

try {

# ---------------------------------------------------------------------------
Say ''
Say 'A. the permanent remote, on this box'
# ---------------------------------------------------------------------------

Assert 'setup: scripts\upstream-remote.ps1 exists' (Test-Path -LiteralPath $EnsureScript)

$configured = (Invoke-GitIn $Repo @('remote', 'get-url', 'upstream')).Text
Assert 'A1 an `upstream` remote is configured' ([bool]$configured) "(got '$configured')"
$normalized = ($configured -replace '\.git$', '').TrimEnd('/')
$expected = ($UpstreamUrl -replace '\.git$', '').TrimEnd('/')
Assert 'A2 it points at ghostty-org/ghostty' ($normalized -eq $expected) "(got '$configured')"

$head = Invoke-GitIn $Repo @('rev-parse', '--short=9', 'upstream/main')
Assert 'A3 upstream/main resolves (the ref that keeps the objects alive)' ($head.Code -eq 0) "(got '$($head.Text)')"
if ($head.Code -eq 0) { Say "    upstream/main = $($head.Text)" }

# The sha list comes out of the plan doc, not out of this script.
$planPath = Join-Path $Repo 'docs\design\windows-parity-merge-back-plan.md'
Assert 'setup: the merge-back plan is where it is expected' (Test-Path -LiteralPath $planPath)
$planShas = @()
if (Test-Path -LiteralPath $planPath) {
    $planText = Get-Content -LiteralPath $planPath -Raw
    $seen = @{}
    foreach ($m in [regex]::Matches($planText, '`([0-9a-f]{9,40})`')) { $seen[$m.Groups[1].Value] = $true }
    $planShas = @($seen.Keys | Sort-Object)
}
Say "    the plan cites $($planShas.Count) sha(s)"
Assert 'A4 the plan cites the staged merge points at all' ($planShas.Count -ge 6)

$unresolved = @()
$unreachable = @()
foreach ($s in $planShas) {
    $t = Invoke-GitIn $Repo @('cat-file', '-t', $s)
    if ($t.Code -ne 0 -or $t.Text -ne 'commit') { $unresolved += $s; continue }
    if (-not (Test-GitOk $Repo @('merge-base', '--is-ancestor', $s, 'upstream/main'))) { $unreachable += $s }
}
Assert 'A5 every sha the plan cites resolves to a commit' ($unresolved.Count -eq 0) "(missing: $($unresolved -join ', '))"
Assert 'A6 every one is an ancestor of upstream/main, so the ref keeps it alive' ($unreachable.Count -eq 0) "(dangling: $($unreachable -join ', '))"

$checkOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript check -Repo $Repo)
$checkCode = $LASTEXITCODE
Assert 'A7 `upstream-remote.ps1 check` scores this repo green' ($checkCode -eq 0) "(exit $checkCode)"
Assert 'A8 ...and says so in one readable line' (@($checkOut | Where-Object { $_ -match '^UPSTREAM OK' }).Count -eq 1) "(got: $($checkOut -join ' / '))"

# ---------------------------------------------------------------------------
Say ''
Say 'B. ensure REPAIRS a repo, not just reports on a healthy one'
# ---------------------------------------------------------------------------
# All of section B runs -NoFetch: the repair being measured is configuration,
# and a section that needs GitHub would go red on an offline box for a reason
# that has nothing to do with the code under test.

$fixture = Join-Path $sandbox 'fixture'
New-Item -ItemType Directory -Force -Path $fixture | Out-Null
[void](Invoke-GitIn $fixture @('init', '-q', '.'))
Set-Content -LiteralPath (Join-Path $fixture 'seed.txt') -Value 'seed' -Encoding UTF8
[void](Invoke-GitCommit $fixture @('add', 'seed.txt'))
[void](Invoke-GitCommit $fixture @('commit', '-qm', 'seed'))

Assert 'setup: the fixture starts with no upstream remote' (-not (Test-GitOk $fixture @('remote', 'get-url', 'upstream')))

$b1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript ensure -Repo $fixture -NoFetch)
Assert 'B1 `ensure` adds the remote to a repo that has none' ((Invoke-GitIn $fixture @('remote', 'get-url', 'upstream')).Text -match 'ghostty-org/ghostty') "(got: $($b1 -join ' / '))"
Assert 'B2 ...and exits 0 even with nothing fetched, so a claim cannot wedge' ($LASTEXITCODE -eq 0)

# A DRIFTED url is the dangerous case: it resolves, so nothing complains, and
# every sha it fetches belongs to somebody else's repository.
[void](Invoke-GitIn $fixture @('remote', 'set-url', 'upstream', 'https://github.com/someone-else/ghostty.git'))
[void](& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript ensure -Repo $fixture -NoFetch)
Assert 'B3 a drifted remote URL is corrected back to upstream' ((Invoke-GitIn $fixture @('remote', 'get-url', 'upstream')).Text -match 'ghostty-org/ghostty')

$before = @(Invoke-GitIn $fixture @('remote', '-v')).Text
[void](& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript ensure -Repo $fixture -NoFetch)
$after = @(Invoke-GitIn $fixture @('remote', '-v')).Text
Assert 'B4 `ensure` is idempotent (a second run changes nothing)' ($before -eq $after)

# check must FAIL on a repo that is not wired up - the half that makes it a
# gate rather than a status line.
$bare = Join-Path $sandbox 'bare'
New-Item -ItemType Directory -Force -Path $bare | Out-Null
[void](Invoke-GitIn $bare @('init', '-q', '.'))
$badOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript check -Repo $bare)
$badCode = $LASTEXITCODE
Assert 'B5 `check` exits 1 on a repo with no upstream remote' ($badCode -eq 1) "(exit $badCode)"
Assert 'B6 ...and names the remedy in its own output' (@($badOut | Where-Object { $_ -match 'upstream-remote\.ps1 ensure' }).Count -ge 1) "(got: $($badOut -join ' / '))"

# ---------------------------------------------------------------------------
Say ''
Say 'C. the union merge driver, on the real .gitignore divergence'
# ---------------------------------------------------------------------------

$mergeBase = (Invoke-GitIn $Repo @('merge-base', 'HEAD', 'upstream/main')).Text
Assert 'setup: a merge base with upstream exists' ([bool]$mergeBase)

$attrPath = Join-Path $Repo '.gitattributes'
Assert 'setup: the repo ships a .gitattributes' (Test-Path -LiteralPath $attrPath)

if ($mergeBase -and (Test-Path -LiteralPath $attrPath)) {
    # Three real versions of one real file. Staged as a fixture repo so the
    # merge can be run twice, with and without the driver, without ever
    # touching this working tree.
    function New-GitignoreFixture {
        param([string]$Dir, [switch]$WithAttributes)
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        [void](Invoke-GitIn $Dir @('init', '-q', '.'))
        $target = Join-Path $Dir '.gitignore'
        (Invoke-GitIn $Repo @('show', "${mergeBase}:.gitignore")).Lines | Set-Content -LiteralPath $target -Encoding UTF8
        if ($WithAttributes) {
            # The REPO's own file, so what is graded is the artifact we ship.
            Copy-Item -LiteralPath $attrPath -Destination (Join-Path $Dir '.gitattributes') -Force
            [void](Invoke-GitCommit $Dir @('add', '.gitattributes'))
        }
        [void](Invoke-GitCommit $Dir @('add', '.gitignore'))
        [void](Invoke-GitCommit $Dir @('commit', '-qm', 'base'))
        [void](Invoke-GitIn $Dir @('checkout', '-qb', 'ours'))
        (Invoke-GitIn $Repo @('show', 'HEAD:.gitignore')).Lines | Set-Content -LiteralPath $target -Encoding UTF8
        [void](Invoke-GitCommit $Dir @('commit', '-qam', 'ours'))
        [void](Invoke-GitIn $Dir @('checkout', '-q', 'HEAD~0'))
        [void](Invoke-GitIn $Dir @('checkout', '-qb', 'theirs', (Invoke-GitIn $Dir @('rev-parse', 'ours~1')).Text))
        (Invoke-GitIn $Repo @('show', 'upstream/main:.gitignore')).Lines | Set-Content -LiteralPath $target -Encoding UTF8
        [void](Invoke-GitCommit $Dir @('commit', '-qam', 'theirs'))
        [void](Invoke-GitIn $Dir @('checkout', '-q', 'ours'))
    }

    $plain = Join-Path $sandbox 'gi-plain'
    New-GitignoreFixture -Dir $plain
    $plainMerge = Invoke-GitCommit $plain @('merge', 'theirs', '-m', 'merge')
    Assert 'C1 premise: without the driver, our .gitignore and upstream''s CONFLICT' ($plainMerge.Code -ne 0) "(merge exited $($plainMerge.Code))"

    $withAttr = Join-Path $sandbox 'gi-union'
    New-GitignoreFixture -Dir $withAttr -WithAttributes
    $unionMerge = Invoke-GitCommit $withAttr @('merge', 'theirs', '-m', 'merge')
    Assert 'C2 with the repo''s .gitattributes, the same merge is clean' ($unionMerge.Code -eq 0) "(merge exited $($unionMerge.Code): $($unionMerge.Text))"

    $merged = @(Get-Content -LiteralPath (Join-Path $withAttr '.gitignore'))
    $markers = @($merged | Where-Object { $_ -match '^(<<<<<<<|=======$|>>>>>>>)' })
    Assert 'C3 the merged file carries no conflict markers' ($markers.Count -eq 0) "(found $($markers.Count))"

    # Union means BOTH sides survive. Pick one line each side added that the
    # other has never had, so a "clean" merge that silently dropped a side
    # cannot pass this.
    $oursOnly = @($merged | Where-Object { $_.Trim() -eq 'zig-out-*/' }).Count
    $theirsOnly = @($merged | Where-Object { $_.Trim() -eq 'zig-pkg/' }).Count
    Assert 'C4 an ours-only line survives the union' ($oursOnly -ge 1)
    Assert 'C5 a theirs-only line survives the union' ($theirsOnly -ge 1)

    # And the whole of each side is there, not just the sampled line: every
    # non-empty, non-comment entry from both sides must appear in the result.
    function Get-Entries {
        param([string]$Rev, [string]$At)
        $lines = (Invoke-GitIn $At @('show', "${Rev}:.gitignore")).Lines
        return @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    $ourEntries = Get-Entries -Rev 'ours' -At $withAttr
    $theirEntries = Get-Entries -Rev 'theirs' -At $withAttr
    $mergedSet = @{}
    foreach ($l in $merged) { $mergedSet[$l.Trim()] = $true }
    $lostOurs = @($ourEntries | Where-Object { -not $mergedSet.ContainsKey($_) })
    $lostTheirs = @($theirEntries | Where-Object { -not $mergedSet.ContainsKey($_) })
    Assert 'C6 no entry of ours was lost' ($lostOurs.Count -eq 0) "(lost: $($lostOurs -join ', '))"
    Assert 'C7 no entry of theirs was lost' ($lostTheirs.Count -eq 0) "(lost: $($lostTheirs -join ', '))"
}

# ---------------------------------------------------------------------------
Say ''
Say 'D. the attribute list is honest'
# ---------------------------------------------------------------------------

$unionPaths = @()
if (Test-Path -LiteralPath $attrPath) {
    foreach ($line in (Get-Content -LiteralPath $attrPath)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -match '^(?<pat>\S+)\s+.*\bmerge=union\b') { $unionPaths += $Matches['pat'] }
    }
}
Say "    $($unionPaths.Count) path(s) declared merge=union: $($unionPaths -join ', ')"
Assert 'D1 .gitignore is declared merge=union (the plan''s named file)' ($unionPaths -contains '.gitignore')

# A pattern that matches nothing is a driver that silently is not there. Ask
# git itself rather than re-implementing its pattern matching.
$missing = @()
$notUnion = @()
foreach ($p in $unionPaths) {
    if (-not (Test-Path -LiteralPath (Join-Path $Repo $p))) { $missing += $p; continue }
    $attr = (Invoke-GitIn $Repo @('check-attr', 'merge', '--', $p)).Text
    if ($attr -notmatch 'merge:\s*union') { $notUnion += "$p -> '$attr'" }
}
Assert 'D2 every declared path exists in the tree' ($missing.Count -eq 0) "(missing: $($missing -join ', '))"
Assert 'D3 git itself reports merge=union for every declared path' ($notUnion.Count -eq 0) "(got: $($notUnion -join '; '))"

# The rule that makes this list safe to grow: union merge NEVER conflicts, so
# it may only be given to files where taking both sides is always correct. A
# .zig, .swift or .json under a union driver would silently produce a file that
# does not parse, which is worse than the conflict it avoided.
$unsafe = @($unionPaths | Where-Object { $_ -match '\.(zig|swift|json|zon|yml|yaml|toml|c|h|m|rc)$' })
Assert 'D4 no structured-syntax file is under a union driver' ($unsafe.Count -eq 0) "(unsafe: $($unsafe -join ', '))"

if ($NegativeControl) {
    Say ''
    Say 'NEGATIVE CONTROL: asserting the union driver is ABSENT - a wired repo MUST fail this'
    Assert 'N1 .gitignore is NOT declared merge=union (inverted)' (-not ($unionPaths -contains '.gitignore'))
}

} catch {
    # A crash mid-run used to fall straight through to the verdict below and
    # print ALL PASS over the handful of assertions that had run before it -
    # the exact shape verdict-exit-audit exists to distrust. Seen for real
    # while writing this script: a helper named `Git` shadowed git.exe and
    # recursed until PowerShell's call depth gave out, in section A.
    Write-Host "  FAIL harness crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    $script:failures++
} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# A clean green run stamps the covered files (T783), so scripts\guard-due.ps1
# can answer "has this been run against the remote wiring and the merge drivers
# as they now stand?". A run with a red assertion - or the -NegativeControl run,
# which is red by construction - deliberately leaves the stamp alone.
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard upstream-remote -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
if ($script:failures -eq 0) { Say "UPSTREAM-REMOTE: ALL PASS ($script:passes)"; exit 0 }
else { Say "UPSTREAM-REMOTE: $script:failures FAILURE(S) / $script:passes passed"; exit 1 }
