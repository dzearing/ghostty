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
# Must match $AnchorPrefix in scripts\upstream-remote.ps1 (T1099). Spelled out
# here rather than imported so this script asserts against the ref names a human
# would type, not against whatever the script under test happens to define.
$AnchorPrefix = 'upstream-anchor/'

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
$unanchored = @()
foreach ($s in $planShas) {
    $t = Invoke-GitIn $Repo @('cat-file', '-t', $s)
    if ($t.Code -ne 0 -or $t.Text -ne 'commit') { $unresolved += $s; continue }
    if (-not (Test-GitOk $Repo @('merge-base', '--is-ancestor', $s, 'upstream/main'))) { $unreachable += $s }
    # T1099: the tag is the anchor that actually keeps the object alive. Compare
    # the OBJECT, not the tag's existence - a tag left over from a re-cut plan
    # would otherwise read as an anchor for a sha it no longer points at.
    $tagged = Invoke-GitIn $Repo @('rev-parse', '--verify', '--quiet', "refs/tags/$AnchorPrefix$s^{commit}")
    $target = Invoke-GitIn $Repo @('rev-parse', '--verify', '--quiet', "$s^{commit}")
    if ($tagged.Code -ne 0 -or $tagged.Text -ne $target.Text) { $unanchored += $s }
}
Assert 'A5 every sha the plan cites resolves to a commit' ($unresolved.Count -eq 0) "(missing: $($unresolved -join ', '))"
Assert 'A6 every one is an ancestor of upstream/main, so the ref keeps it alive' ($unreachable.Count -eq 0) "(dangling: $($unreachable -join ', '))"
# A6 is the WEAK anchor and A6b is the durable one. A remote-tracking ref
# disappears the moment somebody runs `git remote remove upstream` - which
# happened on 2026-08-22 and left every sha below reachable from nothing for an
# hour and a half (T1099).
Assert 'A6b ...and every one is anchored by a local tag, which no remote operation can prune' ($unanchored.Count -eq 0) "(unanchored: $($unanchored -join ', '))"

$checkOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript check -Repo $Repo)
$checkCode = $LASTEXITCODE
Assert 'A7 `upstream-remote.ps1 check` scores this repo green' ($checkCode -eq 0) "(exit $checkCode)"
Assert 'A8 ...and says so in one readable line' (@($checkOut | Where-Object { $_ -match '^UPSTREAM OK' }).Count -eq 1) "(got: $($checkOut -join ' / '))"

# The line the LOOP prints every turn is `ensure`'s, not `check`'s, and until
# T1099 it answered a weaker question: upstream/main resolving, with the plan
# shas never asked about at all. A9 is the assertion that the two verdicts are
# now the same verdict.
$ensureOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript ensure -Repo $Repo -NoFetch)
Assert 'A9 the claim`s own line (`ensure`) agrees with `check` on this repo' (@($ensureOut | Where-Object { $_ -match '^UPSTREAM OK' }).Count -eq 1) "(got: $($ensureOut -join ' / '))"
Assert 'A10 ...and reports the anchor count, so the gate names what it checked' (@($ensureOut | Where-Object { $_ -match 'anchored by tag' }).Count -ge 1) "(got: $($ensureOut -join ' / '))"

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

# ---------------------------------------------------------------------------
Say ''
Say 'E. the anchor survives the remote being removed (T1099)'
# ---------------------------------------------------------------------------
# The failure this section exists for is not hypothetical: on 2026-08-22 a turn
# ran `git remote remove upstream` by hand, which deleted refs/remotes/upstream/*
# and left all eight plan shas reachable from nothing. Re-adding the remote did
# not bring the ref back. Everything here runs in a throwaway repo with its own
# plan doc, so the assertion is about the MECHANISM and does not depend on the
# live repo happening to be healthy.

$anchorRepo = Join-Path $sandbox 'anchor'
New-Item -ItemType Directory -Force -Path $anchorRepo | Out-Null
[void](Invoke-GitIn $anchorRepo @('init', '-q', '.'))
$planShasFixture = @()
foreach ($i in 1..3) {
    Set-Content -LiteralPath (Join-Path $anchorRepo "f$i.txt") -Value "v$i" -Encoding UTF8
    [void](Invoke-GitCommit $anchorRepo @('add', "f$i.txt"))
    [void](Invoke-GitCommit $anchorRepo @('commit', '-qm', "stage $i"))
    $planShasFixture += (Invoke-GitIn $anchorRepo @('rev-parse', '--short=9', 'HEAD')).Text
}
# The plan doc is where the sha list comes from, in the fixture exactly as in
# the real repo - so this also covers the extraction, not just the anchoring.
$fixturePlanDir = Join-Path $anchorRepo 'docs\design'
New-Item -ItemType Directory -Force -Path $fixturePlanDir | Out-Null
$planLines = @('# fixture plan', '')
foreach ($s in $planShasFixture) { $planLines += "- stage at ``$s``" }
Set-Content -LiteralPath (Join-Path $fixturePlanDir 'windows-parity-merge-back-plan.md') -Value $planLines -Encoding UTF8

$e0 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript check -Repo $anchorRepo)
Assert 'E1 `check` calls an un-anchored plan sha out by name' (@($e0 | Where-Object { $_ -match 'is not anchored' }).Count -ge 1) "(got: $($e0 -join ' / '))"

[void](& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript ensure -Repo $anchorRepo -NoFetch)
$tagsAfter = @((Invoke-GitIn $anchorRepo @('tag', '-l', "$AnchorPrefix*")).Lines | Where-Object { $_ })
Assert 'E2 `ensure` anchors every plan sha with a tag' ($tagsAfter.Count -eq $planShasFixture.Count) "(got $($tagsAfter.Count) of $($planShasFixture.Count): $($tagsAfter -join ', '))"

# THE POINT OF THE SECTION: rip the remote out, the way 2026-08-22 did.
[void](Invoke-GitIn $anchorRepo @('remote', 'remove', 'upstream'))
Assert 'setup: the remote really is gone' (-not (Test-GitOk $anchorRepo @('remote', 'get-url', 'upstream')))
$stillAnchored = @()
foreach ($s in $planShasFixture) {
    $tagged = Invoke-GitIn $anchorRepo @('rev-parse', '--verify', '--quiet', "refs/tags/$AnchorPrefix$s^{commit}")
    if ($tagged.Code -eq 0 -and $tagged.Text) { $stillAnchored += $s }
}
Assert 'E3 every sha is STILL anchored with the remote removed' ($stillAnchored.Count -eq $planShasFixture.Count) "(kept: $($stillAnchored.Count) of $($planShasFixture.Count))"

# `git gc --prune=now` is the operation the whole task is about. An anchored
# object must survive it; that is what "anchor" means.
[void](Invoke-GitIn $anchorRepo @('reflog', 'expire', '--expire=now', '--all'))
[void](Invoke-GitIn $anchorRepo @('gc', '--prune=now', '--quiet'))
$survived = @()
foreach ($s in $planShasFixture) {
    $t = Invoke-GitIn $anchorRepo @('cat-file', '-t', $s)
    if ($t.Code -eq 0 -and $t.Text -eq 'commit') { $survived += $s }
}
Assert 'E4 ...and survives `git gc --prune=now` with every reflog expired' ($survived.Count -eq $planShasFixture.Count) "(survived: $($survived.Count) of $($planShasFixture.Count))"

# The verdict must still be able to go RED for the sha question alone. A plan
# citing a sha this repo has never seen is the cheapest way to ask that.
Add-Content -LiteralPath (Join-Path $fixturePlanDir 'windows-parity-merge-back-plan.md') -Value '- stage at `0123456789abcdef0123456789abcdef01234567`'
$e5 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript ensure -Repo $anchorRepo -NoFetch)
Assert 'E5 `ensure` prints UPSTREAM PROBLEM for a sha the plan cites and the repo lacks' (@($e5 | Where-Object { $_ -match '^UPSTREAM PROBLEM' }).Count -eq 1) "(got: $($e5 -join ' / '))"
Assert 'E6 ...and still exits 0, so a bad verdict cannot wedge the claim' ($LASTEXITCODE -eq 0) "(exit $LASTEXITCODE)"

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
