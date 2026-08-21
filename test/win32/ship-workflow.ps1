# T1058 acceptance - the ship workflow: the cutover readiness gate and the
# per-feature worktree/branch/PR lifecycle.
#
#   powershell -NoProfile -File test\win32\ship-workflow.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state: the subjects
# are two git/gh-driving scripts, so the lifecycle half runs entirely inside a
# throwaway repo pair under $env:TEMP, and the readiness half only READS this
# repo.
#
# isolation: none - no ghoztty binary is run and no CLI verb is invoked; the
# only executables this script starts are git and (read-only, section C) gh.
# (T680 meta-check reads this marker.)
#
# WHY IT EXISTS
#
# Both subjects are gates, and a gate that is wrong is worse than no gate: one
# says "this branch is ready to become the trunk" and the other deletes
# worktrees and branches. Every section below is an assertion that a REFUSAL
# actually refuses, because that is the half that cannot be checked by using the
# tool - a script that has quietly stopped refusing looks exactly like one that
# had nothing to refuse.
#
# A - ship-readiness reports honestly. An unmeasured criterion is UNKNOWN and
#     counts against readiness; the numbers it prints are the numbers git gives;
#     it never mutates the repo it judges; and a criterion that fails carries a
#     remedy, because a gate with no exit is a gate people route around.
# B - the feature lifecycle, end to end, in a sandbox: new / list / pr / done,
#     including every refusal (duplicate slug, bad slug, dirty tree, nothing to
#     propose, unpushed commits, missing worktree).
# C - the gh landmine. This repo has upstream (ghostty-org/ghostty) as a remote
#     and gh resolves to it by default, so a bare `gh pr create` here would
#     offer this fork's work to the public Ghostty project. Every gh call in the
#     family must name --repo, and this section is what keeps that true.
# D - the docs are wired: the workflow doc exists and covers the lifecycle, and
#     go.md reaches both scripts, so a turn following only go.md can execute one.
param(
    [string]$Repo
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
$script:skips = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name $detail" -ForegroundColor Red; $script:failures++ }
}
function Skip($name, $why) { Write-Host "  SKIP $name - $why" -ForegroundColor Yellow; $script:skips++ }
function Say($m) { Write-Host $m }

$Readiness = Join-Path $Repo 'scripts\ship-readiness.ps1'
$Feature = Join-Path $Repo 'scripts\ship-feature.ps1'
$Doc = Join-Path $Repo 'docs\design\windows-parity-ship-workflow.md'
$GoMd = Join-Path $Repo 'go.md'

# Per-record capture (T883): a merged 2>&1 stream on a native command is
# formatted to the host's buffer width, so an assertion over that text would be
# an assertion about the console it ran in.
function Invoke-Script {
    param([string]$Path, [string[]]$ScriptArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $Path @ScriptArgs 2>&1)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n"); Lines = $out }
}

function Invoke-GitIn {
    param([string]$At, [string[]]$GitArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $At @GitArgs 2>&1)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n"); Lines = $out }
}

$sandbox = Join-Path $env:TEMP ("ship-workflow-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    # =====================================================================
    Say ''
    Say 'A - ship-readiness reports honestly'
    # =====================================================================

    if (-not (Test-Path $Readiness)) {
        Skip 'A (all)' 'scripts\ship-readiness.ps1 missing'
    }
    else {
        $before = (Invoke-GitIn $Repo @('status', '--porcelain')).Text
        $headBefore = (Invoke-GitIn $Repo @('rev-parse', 'HEAD')).Text
        $fetchHead = Join-Path $Repo '.git\FETCH_HEAD'
        $fetchBefore = if (Test-Path $fetchHead) { (Get-Item $fetchHead).LastWriteTimeUtc } else { $null }

        $r = Invoke-Script $Readiness @('-Json', '-Repo', $Repo)
        $payload = $null
        try { $payload = $r.Text | ConvertFrom-Json } catch { $payload = $null }

        Assert 'A1 -Json emits a parseable payload' ($null -ne $payload) "text: $($r.Text.Substring(0, [Math]::Min(200, $r.Text.Length)))"

        if ($payload) {
            $names = @($payload.criteria | ForEach-Object { $_.Name })
            # The criterion set is the contract. A criterion that silently
            # disappears is a gate that silently stopped gating, and every one
            # of these is load-bearing for the cutover decision.
            $required = @('tree', 'push', 'behind', 'p0', 'inprogress', 'macseat', 'guards', 'ghrepo', 'lanes', 'accept')
            $missing = @($required | Where-Object { $names -notcontains $_ })
            Assert 'A2 every cutover criterion is reported' ($missing.Count -eq 0) "missing: $($missing -join ',')"

            # An unmeasured criterion must never read as satisfied. This is the
            # assertion that keeps -RunLanes honest: without it, "the lanes were
            # green last week" is not evidence and must not produce READY.
            $lanes = @($payload.criteria | Where-Object { $_.Name -eq 'lanes' })[0]
            $accept = @($payload.criteria | Where-Object { $_.Name -eq 'accept' })[0]
            Assert 'A3 lanes are UNKNOWN without -RunLanes' ($lanes.State -eq 'UNKNOWN') "state: $($lanes.State)"
            Assert 'A4 accept is UNKNOWN without -RunLanes' ($accept.State -eq 'UNKNOWN') "state: $($accept.State)"
            Assert 'A5 UNKNOWN counts as unmet' (@($payload.unmet) -contains 'lanes' -and @($payload.unmet) -contains 'accept') `
                "unmet: $(@($payload.unmet) -join ',')"
            Assert 'A6 an unmet criterion means not ready' ($payload.ready -eq $false) "ready: $($payload.ready)"
            Assert 'A7 the verdict is the exit code' ($r.Code -eq 1) "exit: $($r.Code)"

            # Every failure carries a way out. A gate whose message is only
            # "no" is a gate somebody eventually deletes.
            $noRemedy = @($payload.criteria | Where-Object { $_.State -ne 'PASS' -and -not $_.Remedy })
            Assert 'A8 every unmet criterion carries a remedy' ($noRemedy.Count -eq 0) `
                "without remedy: $(@($noRemedy | ForEach-Object { $_.Name }) -join ',')"

            # The numbers are git's, not the script's opinion of git.
            $behind = @($payload.criteria | Where-Object { $_.Name -eq 'behind' })[0]
            $realBehind = (Invoke-GitIn $Repo @('rev-list', '--count', 'HEAD..origin/main')).Text.Trim()
            if ($realBehind -match '^\d+$') {
                if ([int]$realBehind -eq 0) {
                    Assert 'A9 behind matches git (contained)' ($behind.State -eq 'PASS') "detail: $($behind.Detail)"
                }
                else {
                    Assert 'A9 behind matches git' ($behind.State -eq 'FAIL' -and $behind.Detail -match "^$realBehind commit") `
                        "git says $realBehind; detail: $($behind.Detail)"
                }
            }
            else {
                Skip 'A9 behind matches git' 'origin/main not resolvable here'
            }
        }

        # A readiness check that fetched, staged, or otherwise moved the repo it
        # is judging would make its own answer a moving target - and this one is
        # meant to be safe to run at any point in a turn.
        $after = (Invoke-GitIn $Repo @('status', '--porcelain')).Text
        $headAfter = (Invoke-GitIn $Repo @('rev-parse', 'HEAD')).Text
        $fetchAfter = if (Test-Path $fetchHead) { (Get-Item $fetchHead).LastWriteTimeUtc } else { $null }
        Assert 'A10 readiness does not change the working tree' ($before -eq $after)
        Assert 'A11 readiness does not move HEAD' ($headBefore -eq $headAfter)
        Assert 'A12 readiness does not fetch' ($fetchBefore -eq $fetchAfter) `
            "FETCH_HEAD $fetchBefore -> $fetchAfter"

        # The gh criterion must have teeth: pointed at a repository that is not
        # the fork, it has to fail. Otherwise "gh is configured" would be
        # satisfied by gh being configured for ANYTHING, which is precisely the
        # upstream-by-default state this criterion exists to catch.
        $r2 = Invoke-Script $Readiness @('-Json', '-Repo', $Repo, '-ForkRepo', 'nobody/not-a-repo')
        $p2 = $null
        try { $p2 = $r2.Text | ConvertFrom-Json } catch { $p2 = $null }
        if ($p2) {
            $gh2 = @($p2.criteria | Where-Object { $_.Name -eq 'ghrepo' })[0]
            Assert 'A13 ghrepo fails when gh does not resolve to the named fork' ($gh2.State -eq 'FAIL') `
                "state: $($gh2.State) detail: $($gh2.Detail)"
        }
        else {
            Skip 'A13 ghrepo teeth' 'second readiness run did not emit JSON'
        }
    }

    # =====================================================================
    Say ''
    Say 'B - the feature lifecycle, in a sandbox'
    # =====================================================================

    if (-not (Test-Path $Feature)) {
        Skip 'B (all)' 'scripts\ship-feature.ps1 missing'
    }
    else {
        # A bare repo standing in for origin, and a clone standing in for this
        # working tree. Real git all the way down: the subject's whole job is
        # git plumbing, and a mocked git would assert nothing.
        $originDir = Join-Path $sandbox 'origin.git'
        $workDir = Join-Path $sandbox 'repo'
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        & git init --bare -b main $originDir *> $null
        & git clone $originDir $workDir *> $null
        & git -C $workDir config user.email 'test@example.com' *> $null
        & git -C $workDir config user.name 'Ship Workflow Test' *> $null
        Set-Content -Path (Join-Path $workDir 'README.md') -Value 'seed' -Encoding ascii
        & git -C $workDir add README.md *> $null
        & git -C $workDir commit -m 'seed' *> $null
        & git -C $workDir push -u origin main *> $null

        # gh is deliberately pointed at a repository that does not exist, so the
        # PR lookups fail and return "no PR known" rather than reaching over the
        # network to the real fork from a test.
        $sandboxArgs = @('-Repo', $workDir, '-ForkRepo', 'nobody/not-a-repo')
        $wtRoot = "$workDir-wt"

        $b1 = Invoke-Script $Feature (@('new', '-Slug', 'demo-feature') + $sandboxArgs + @('-NoFetch'))
        $demoDir = Join-Path $wtRoot 'demo-feature'
        Assert 'B1 new creates the worktree' ($b1.Code -eq 0 -and (Test-Path $demoDir)) "exit $($b1.Code): $($b1.Text)"
        $demoBranch = (Invoke-GitIn $demoDir @('rev-parse', '--abbrev-ref', 'HEAD')).Text.Trim()
        Assert 'B2 the branch carries the prefix' ($demoBranch -eq 'users/dzearing/demo-feature') "branch: $demoBranch"
        $forkedFrom = (Invoke-GitIn $demoDir @('rev-parse', 'HEAD')).Text.Trim()
        $trunkSha = (Invoke-GitIn $workDir @('rev-parse', 'origin/main')).Text.Trim()
        Assert 'B3 it forks from the trunk' ($forkedFrom -eq $trunkSha) "$forkedFrom vs $trunkSha"

        $b4 = Invoke-Script $Feature (@('new', '-Slug', 'demo-feature') + $sandboxArgs + @('-NoFetch'))
        Assert 'B4 a duplicate slug is refused' ($b4.Code -eq 1 -and $b4.Text -match 'REFUSED') "exit $($b4.Code): $($b4.Text)"

        $b5 = Invoke-Script $Feature (@('new', '-Slug', 'Not A Slug') + $sandboxArgs + @('-NoFetch'))
        Assert 'B5 a non-kebab slug is refused' ($b5.Code -eq 1 -and $b5.Text -match 'REFUSED') "exit $($b5.Code): $($b5.Text)"

        $b6 = Invoke-Script $Feature (@('list', '-Json') + $sandboxArgs)
        $rows = $null
        try { $rows = @($b6.Text | ConvertFrom-Json) } catch { $rows = $null }
        Assert 'B6 list finds the worktree' ($null -ne $rows -and @($rows | Where-Object { $_.Slug -eq 'demo-feature' }).Count -eq 1) `
            "text: $($b6.Text)"

        # Nothing proposed yet: a PR over zero commits describes nothing, and
        # opening one is a notification everybody learns to ignore.
        $b7 = Invoke-Script $Feature (@('pr', '-Slug', 'demo-feature', '-Title', 'x') + $sandboxArgs)
        Assert 'B7 pr over zero commits is refused' ($b7.Code -eq 1 -and $b7.Text -match 'no commits of its own') `
            "exit $($b7.Code): $($b7.Text)"

        Set-Content -Path (Join-Path $demoDir 'feature.txt') -Value 'work' -Encoding ascii
        $b8 = Invoke-Script $Feature (@('pr', '-Slug', 'demo-feature', '-Title', 'x') + $sandboxArgs)
        Assert 'B8 pr over a dirty tree is refused' ($b8.Code -eq 1 -and $b8.Text -match 'uncommitted') `
            "exit $($b8.Code): $($b8.Text)"

        & git -C $demoDir add feature.txt *> $null
        & git -C $demoDir commit -m 'feature work' *> $null

        $b9 = Invoke-Script $Feature (@('list', '-Json') + $sandboxArgs)
        $rows9 = $null
        try { $rows9 = @($b9.Text | ConvertFrom-Json) } catch { $rows9 = $null }
        $row9 = if ($rows9) { @($rows9 | Where-Object { $_.Slug -eq 'demo-feature' })[0] } else { $null }
        Assert 'B9 list counts the commit' ($null -ne $row9 -and "$($row9.Ahead)" -eq '1') "row: $($b9.Text)"

        # The refusal that protects work: the commit exists only here.
        $b10 = Invoke-Script $Feature (@('done', '-Slug', 'demo-feature') + $sandboxArgs)
        Assert 'B10 done refuses unpushed commits' ($b10.Code -eq 1 -and $b10.Text -match 'never pushed|not pushed') `
            "exit $($b10.Code): $($b10.Text)"
        Assert 'B11 the refusal left the worktree alone' (Test-Path $demoDir)

        & git -C $demoDir push -u origin $demoBranch *> $null

        $b12 = Invoke-Script $Feature (@('done', '-Slug', 'demo-feature') + $sandboxArgs)
        Assert 'B12 done removes a pushed worktree' ($b12.Code -eq 0 -and -not (Test-Path $demoDir)) `
            "exit $($b12.Code): $($b12.Text)"
        $branchGone = (Invoke-GitIn $workDir @('rev-parse', '--verify', '--quiet', "refs/heads/$demoBranch")).Code -ne 0
        Assert 'B13 done deletes the local branch' $branchGone

        $b14 = Invoke-Script $Feature (@('done', '-Slug', 'demo-feature') + $sandboxArgs)
        Assert 'B14 done on a missing worktree is refused, not a crash' ($b14.Code -eq 1 -and $b14.Text -match 'REFUSED') `
            "exit $($b14.Code): $($b14.Text)"

        # -Force is the abandon path: it must work over exactly the state that
        # the unforced path refuses, and it must say that it was used.
        Invoke-Script $Feature (@('new', '-Slug', 'abandoned') + $sandboxArgs + @('-NoFetch')) | Out-Null
        $abDir = Join-Path $wtRoot 'abandoned'
        Set-Content -Path (Join-Path $abDir 'scratch.txt') -Value 'junk' -Encoding ascii
        & git -C $abDir add scratch.txt *> $null
        & git -C $abDir commit -m 'unpushed' *> $null
        $b15 = Invoke-Script $Feature (@('done', '-Slug', 'abandoned', '-Force') + $sandboxArgs)
        Assert 'B15 -Force discards an abandoned feature' ($b15.Code -eq 0 -and -not (Test-Path $abDir)) `
            "exit $($b15.Code): $($b15.Text)"
        Assert 'B16 -Force says it was used' ($b15.Text -match '-Force was used') "text: $($b15.Text)"

        $b17 = Invoke-Script $Feature (@('list') + $sandboxArgs)
        Assert 'B17 list handles the empty state' ($b17.Code -eq 0 -and $b17.Text -match 'no feature worktrees') `
            "exit $($b17.Code): $($b17.Text)"
    }

    # =====================================================================
    Say ''
    Say 'C - the gh landmine cannot come back'
    # =====================================================================

    # Every gh invocation in the family names its repository. Written as a scan
    # rather than a behavioural assertion on purpose: the failure is a call that
    # SUCCEEDS against the wrong repository, so there is no error to catch - by
    # the time anything is observable, a pull request exists on somebody else's
    # project.
    $familyScripts = @($Readiness, $Feature) | Where-Object { Test-Path $_ }
    $bareGh = @()
    foreach ($f in $familyScripts) {
        $lineNo = 0
        $inHelp = $false
        foreach ($line in (Get-Content $f)) {
            $lineNo++
            # The comment-based help block explains the landmine at length, so
            # scanning it finds the prose describing the bug and reports it AS
            # the bug. Skip the help block and ordinary line comments; what is
            # left is code.
            if ($line -match '^\s*<#') { $inHelp = $true }
            if ($inHelp) {
                if ($line -match '#>') { $inHelp = $false }
                continue
            }
            if ($line -match '^\s*#') { continue }
            # `gh pr`, `gh issue`, `gh api`, `gh run` - the repository-scoped
            # verbs. `gh repo set-default` and `gh auth` are not, and reading
            # the configured default is the whole point of the ghrepo check.
            if ($line -match '\bgh\s+(pr|issue|api|run)\b' -and $line -notmatch '--repo') {
                $bareGh += ("{0}:{1}: {2}" -f (Split-Path -Leaf $f), $lineNo, $line.Trim())
            }
        }
    }
    Assert 'C1 no repository-scoped gh call omits --repo' ($bareGh.Count -eq 0) ("`n    " + ($bareGh -join "`n    "))

    # The fork's own name must be a default somewhere, not a value every caller
    # is expected to remember and type.
    $forkDefaulted = @($familyScripts | Where-Object { (Get-Content $_ -Raw) -match "ForkRepo\s*=\s*'dzearing/ghoztty'" })
    Assert 'C2 the fork is the default -ForkRepo in both scripts' ($forkDefaulted.Count -eq $familyScripts.Count) `
        "defaulted in $($forkDefaulted.Count) of $($familyScripts.Count)"

    # And the funnel is single. `--repo` on every call site is only as good as
    # the number of call sites somebody has to remember to write it on; one
    # funnel makes the NEXT call site inherit the guard instead of needing it.
    $ghSites = @()
    $inHelp2 = $false
    $lineNo2 = 0
    foreach ($line in (Get-Content $Feature)) {
        $lineNo2++
        if ($line -match '^\s*<#') { $inHelp2 = $true }
        if ($inHelp2) {
            if ($line -match '#>') { $inHelp2 = $false }
            continue
        }
        if ($line -match '^\s*#') { continue }
        if ($line -match '&\s*gh\b') { $ghSites += "$lineNo2" }
    }
    Assert 'C3 gh is invoked from exactly one place in ship-feature' ($ghSites.Count -eq 1) `
        "invocation lines: $($ghSites -join ',')"

    # =====================================================================
    Say ''
    Say 'D - the workflow is reachable from the docs a turn actually reads'
    # =====================================================================

    if (-not (Test-Path $Doc)) {
        Assert 'D1 the ship-workflow doc exists' $false "expected $Doc"
    }
    else {
        $docText = Get-Content $Doc -Raw
        Assert 'D1 the ship-workflow doc exists' $true
        # The doc has to carry the whole lifecycle, or a turn reading it stops
        # somewhere in the middle and improvises the rest - which is the state
        # this task exists to end.
        $lifecycle = @('ship-readiness.ps1', 'ship-feature.ps1 new', 'ship-feature.ps1 pr', 'ship-feature.ps1 done')
        $absent = @($lifecycle | Where-Object { $docText -notmatch [regex]::Escape($_) })
        Assert 'D2 the doc covers the whole lifecycle' ($absent.Count -eq 0) "absent: $($absent -join ', ')"
        Assert 'D3 the doc names the gh landmine' ($docText -match '--repo') 'no --repo guidance in the doc'
    }

    if (-not (Test-Path $GoMd)) {
        Skip 'D4 go.md reaches the workflow' 'go.md missing'
    }
    else {
        $goText = Get-Content $GoMd -Raw
        Assert 'D4 go.md reaches the readiness gate' ($goText -match 'ship-readiness\.ps1')
        Assert 'D5 go.md reaches the feature lifecycle' ($goText -match 'ship-feature\.ps1')
        Assert 'D6 go.md links the workflow doc' ($goText -match 'windows-parity-ship-workflow\.md')
    }
}
catch {
    # A crash mid-run used to fall straight through to the verdict and print ALL
    # PASS over the handful of assertions that had run before it - the shape
    # verdict-exit-audit exists to distrust.
    Write-Host "  FAIL harness crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    $script:failures++
}
finally {
    # Worktrees hold administrative files under the parent repo's .git, so the
    # directory tree is only half the cleanup; prune what the sandbox left
    # behind before the sandbox itself goes.
    $workDirCleanup = Join-Path $sandbox 'repo'
    if (Test-Path -LiteralPath $workDirCleanup) {
        & git -C $workDirCleanup worktree prune *> $null
    }
    foreach ($p in @("$sandbox", "$sandbox-wt", (Join-Path $sandbox 'repo-wt'))) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has anybody run this against the workflow as it now stands?". A red
# run - or one with skipped sections - leaves the stamp alone.
if ($script:failures -eq 0 -and $script:skips -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard ship-workflow -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
if ($script:failures -eq 0) {
    $note = ''
    if ($script:skips -gt 0) { $note = " / $script:skips skipped" }
    Say "SHIP-WORKFLOW: ALL PASS ($script:passes$note)"
    exit 0
}
else {
    Say "SHIP-WORKFLOW: $script:failures FAILURE(S) / $script:passes passed"
    exit 1
}
