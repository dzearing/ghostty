<#
.SYNOPSIS
  Answer, mechanically, whether this branch is ready to be cut over onto the
  fork's `main` - and name every criterion that is not yet satisfied.

.DESCRIPTION
  T1058. User directive, 2026-08-21: "when we feel like we're in a stable state
  and feature complete, we would get this all merged back into main and continue
  work from there or build individual worktrees for new features and make prs."

  "When we feel like" is the part this script removes. The cutover from one
  long-lived branch to per-feature branches happens ONCE, it is the moment 1397
  commits of unreviewed work become the trunk, and a mood is not a gate. Every
  criterion below is a command whose answer is a number or an exit code, so the
  go/no-go is a check somebody can re-run rather than a judgement call somebody
  has to defend.

  WHICH MERGE THIS IS. Three different merges used to share the name "merge
  back" and they are not the same job (T1097; the same table opens
  docs\design\windows-parity-ship-workflow.md and
  docs\design\windows-parity-upstream-pull-plan.md):

    cutover        `users/dzearing/windows-amd64` -> `main` on dzearing/ghoztty.
                   THIS script gates it. Has never happened.
    upstream pull  ghostty-org/ghostty -> this fork. Planned in
                   windows-parity-upstream-pull-plan.md, on the user's call
                   only (D80), not gated here.
    upstreaming    this fork -> ghostty-org/ghostty. Never happens; the
                   `upstream` remote is fetch-only by construction (D80).

  THE CRITERIA, and why each one is a gate rather than a nice-to-have:

    tree        Nothing uncommitted. A cutover merge that carries a dirty tree
                merges work nobody reviewed and nobody can name.
    push        HEAD == its upstream. An unpushed commit is invisible to the
                other seat, so a merge computed here would not be the merge
                that happens.
    p0          No open P0. A P0 is by definition a crash, hang, data loss or a
                broken feature; "stable" cannot be true over one.
    inprogress  No task in-progress other than the one running this check.
                Half-finished work in the trunk is the thing the PR boundary
                exists to prevent.
    guards      scripts\guard-due.ps1 check is clean. A due harness means
                nobody has run that acceptance suite against the code as it now
                stands, so "green" is a memory, not a measurement.
    behind      origin/main is fully contained in HEAD. main is a live branch -
                the Mac seat merges feature branches into it - so a merge with
                unmerged main commits is a real three-way merge with conflicts,
                not a cutover. Merge main INTO the branch first, resolve there
                where the floor lanes can judge it, and this drops to 0.
    macseat     T87 (Mac seat: macOS regression build + merge to main) is done
                or sequenced. This box cannot build or run macOS, so the Mac
                half of the merge validation is unowned work until a human
                takes it. Named, never silently assumed.
    lanes       The four floor lanes green. NOT measured unless -RunLanes is
                passed, and an unmeasured criterion is reported UNKNOWN and
                counts as unsatisfied - which is the honest answer, because a
                lane that was green yesterday says nothing about today's tree.
    accept      P1-P3 acceptance scripts green. Same rule, same -RunLanes.
    ghrepo      `gh` resolves to the fork, not to upstream. See below.

  THE gh LANDMINE. This repo has both `origin` (dzearing/ghoztty) and
  `upstream` (ghostty-org/ghostty) as remotes and, until this task, no
  `gh repo set-default`. `gh` picks a repository by walking the remotes, and a
  bare `gh pr list` here answers with UPSTREAM's open pull requests - which
  means a bare `gh pr create` under the new workflow would offer this fork's
  Windows work as a pull request to the public Ghostty project. That is not a
  style preference; it is an outward-facing mistake that cannot be taken back,
  so it is a readiness criterion and every script in this family passes --repo
  explicitly rather than trusting resolution.

  EXIT CODES are the verdict, so a caller can branch without parsing:
    0  READY      - every criterion satisfied
    1  NOT READY  - at least one criterion failed or is unmeasured
    2  ERROR      - the check itself could not run (not a repo, git missing)

.EXAMPLE
  powershell -NoProfile -File scripts\ship-readiness.ps1
  powershell -NoProfile -File scripts\ship-readiness.ps1 -Json
  powershell -NoProfile -File scripts\ship-readiness.ps1 -RunLanes
#>
[CmdletBinding()]
param(
    # Resolved in the body: $PSScriptRoot is not bound while parameter defaults
    # are evaluated under PS 5.1, so a default that reads it dies before line 1.
    [string]$Repo,

    # The branch being merged FROM. Defaults to the current branch.
    [string]$Branch,

    # The branch being merged INTO.
    [string]$Trunk = 'origin/main',

    # The fork's GitHub repository, owner/name. Every gh call in this family
    # names it explicitly; this is the value they name.
    [string]$ForkRepo = 'dzearing/ghoztty',

    # The task this check is being run FROM, if any. It is legitimately
    # in-progress - the turn holding it is the one asking - so it does not count
    # against the `inprogress` criterion. Everything else does.
    [string]$SelfTask = '',

    # Actually run the floor lanes and the P1-P3 acceptance scripts. Off by
    # default because it costs minutes and takes the per-user IPC pipe; without
    # it those two criteria report UNKNOWN and the verdict is NOT READY, which
    # is deliberate - see the header.
    [switch]$RunLanes,

    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$script:SelfTask = $SelfTask

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path (Join-Path $Repo '.git'))) {
    Write-Host "ERROR: not a git repo: $Repo"
    exit 2
}
Push-Location $Repo

# ---------------------------------------------------------------- helpers ----

# Every criterion is one of these. `State` is PASS / FAIL / UNKNOWN; UNKNOWN is
# for a criterion that was not measured this run (see -RunLanes) and never for
# one that was measured and came back ambiguous - an ambiguous measurement is a
# FAIL, because the whole point is that "we did not look" cannot read as ready.
$script:Criteria = @()
function Add-Criterion {
    param(
        [string]$Name,
        [string]$State,
        [string]$Detail,
        [string]$Remedy = ''
    )
    $script:Criteria += [pscustomobject]@{
        Name   = $Name
        State  = $State
        Detail = $Detail
        Remedy = $Remedy
    }
}

# These acceptance scripts and lane wrappers print a single verdict line by
# design, and it is the only line worth carrying into a criterion. Returns an
# empty string rather than $null so a caller can format it without a null check.
function Get-LastLine {
    param([object[]]$Records)
    if (-not $Records) { return '' }
    $lines = @($Records | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return '' }
    return $lines[$lines.Count - 1].Trim()
}

function Invoke-Git {
    param([string[]]$GitArgs)
    $out = & git @GitArgs 2>&1
    return @{ Ok = ($LASTEXITCODE -eq 0); Text = ($out | Out-String).Trim(); Code = $LASTEXITCODE }
}

# ------------------------------------------------------------------ tree ----

$statusOut = Invoke-Git @('status', '--porcelain')
if (-not $statusOut.Ok) {
    Write-Host "ERROR: git status failed: $($statusOut.Text)"
    Pop-Location
    exit 2
}
$dirty = @($statusOut.Text -split "`r?`n" | Where-Object { $_.Trim() })
if ($dirty.Count -eq 0) {
    Add-Criterion 'tree' 'PASS' 'working tree clean'
}
else {
    $names = @($dirty | ForEach-Object { ($_ -replace '^..\s+', '') } | Select-Object -First 5)
    Add-Criterion 'tree' 'FAIL' ("{0} uncommitted path(s): {1}" -f $dirty.Count, ($names -join ', ')) `
        'commit them on this branch, or revert them, before the cutover'
}

# --------------------------------------------------------------- branch ------

if (-not $Branch) {
    $b = Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')
    $Branch = $b.Text
}

# ------------------------------------------------------------------ push -----

$upstreamRef = Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
if (-not $upstreamRef.Ok) {
    Add-Criterion 'push' 'FAIL' "branch '$Branch' has no upstream" `
        "git push -u origin $Branch"
}
else {
    $counts = Invoke-Git @('rev-list', '--left-right', '--count', "$($upstreamRef.Text)...HEAD")
    $parts = @($counts.Text -split '\s+' | Where-Object { $_ -ne '' })
    $unpushed = if ($parts.Count -ge 2) { [int]$parts[1] } else { -1 }
    if ($unpushed -eq 0) {
        Add-Criterion 'push' 'PASS' "$Branch == $($upstreamRef.Text)"
    }
    else {
        Add-Criterion 'push' 'FAIL' "$unpushed commit(s) not pushed to $($upstreamRef.Text)" `
            'git push'
    }
}

# ---------------------------------------------------------------- behind -----

# Deliberately does NOT fetch. A readiness check that mutates refs behind the
# caller's back turns "what is the state" into "what is the state after I
# changed it", and the number would then depend on network weather. Fetch is
# the caller's act; -Trunk names the ref that gets read.
$trunkExists = Invoke-Git @('rev-parse', '--verify', '--quiet', $Trunk)
if (-not $trunkExists.Ok) {
    Add-Criterion 'behind' 'FAIL' "trunk ref '$Trunk' does not exist locally" `
        'git fetch origin main'
}
else {
    $bh = Invoke-Git @('rev-list', '--count', "HEAD..$Trunk")
    $behind = 0
    if ($bh.Ok -and $bh.Text -match '^\d+$') { $behind = [int]$bh.Text }
    $ah = Invoke-Git @('rev-list', '--count', "$Trunk..HEAD")
    $ahead = 0
    if ($ah.Ok -and $ah.Text -match '^\d+$') { $ahead = [int]$ah.Text }
    if ($behind -eq 0) {
        Add-Criterion 'behind' 'PASS' "$Trunk fully contained; $ahead commit(s) to merge"
    }
    else {
        Add-Criterion 'behind' 'FAIL' "$behind commit(s) on $Trunk not in $Branch (ahead $ahead)" `
            "git merge $Trunk into $Branch first, resolve here, re-run the floor lanes"
    }
}

# -------------------------------------------------------------- tracker ------

$tasksScript = Join-Path $PSScriptRoot 'parity-tasks.ps1'
$taskDir = Join-Path $Repo 'docs\design\windows-parity-tasks'
if (-not (Test-Path $taskDir)) {
    Add-Criterion 'p0' 'FAIL' 'task directory not found' ''
    Add-Criterion 'inprogress' 'FAIL' 'task directory not found' ''
}
else {
    # Read the frontmatter directly rather than shelling out to parity-tasks.ps1
    # `list` and parsing its table: the table truncates status at 24 characters
    # by design, which is exactly the field being classified here.
    $openP0 = @()
    $inProgress = @()
    foreach ($f in Get-ChildItem -Path $taskDir -Filter 'T*.md' -File) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        if ($text -notmatch '(?s)^---\r?\n(.*?)\r?\n---') { continue }
        $fm = $Matches[1]
        $status = ''
        if ($fm -match '(?m)^status:\s*"?([^"\r\n]*)"?\s*$') { $status = $Matches[1].Trim() }
        $priority = ''
        if ($fm -match '(?m)^priority:\s*"?([^"\r\n]*)"?\s*$') { $priority = $Matches[1].Trim() }
        $seat = ''
        if ($fm -match '(?m)^seat:\s*"?([^"\r\n]*)"?\s*$') { $seat = $Matches[1].Trim() }
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $isOpen = ($status -eq 'todo' -or $status -eq 'in-progress')
        if ($isOpen -and $priority -eq 'P0') {
            # Seat is carried into the message: a P0 blocks the cutover whoever
            # owns it (it is a crash, a hang, data loss or a broken feature by
            # definition), but this box cannot close a mac-seat one, so the
            # reader needs to know which of the two situations they are in.
            $openP0 += $(if ($seat -eq 'mac') { "$id(mac)" } else { $id })
        }
        # Mac-seat tasks are not this box's work in flight, so they never gate
        # the Windows cutover the way an unfinished Windows task does.
        if ($status -eq 'in-progress' -and $seat -ne 'mac') { $inProgress += $id }
    }
    if ($openP0.Count -eq 0) {
        Add-Criterion 'p0' 'PASS' 'no open P0'
    }
    else {
        Add-Criterion 'p0' 'FAIL' ("open P0: {0}" -f ($openP0 -join ', ')) `
            'close them, or re-triage with set-priority and say why'
    }

    # The task running this check is legitimately in-progress; anything else is
    # work the cutover would bury.
    $others = @($inProgress | Where-Object { $_ -ne $script:SelfTask })
    if ($others.Count -eq 0) {
        Add-Criterion 'inprogress' 'PASS' 'no other task in-progress'
    }
    else {
        Add-Criterion 'inprogress' 'FAIL' ("in-progress: {0}" -f ($others -join ', ')) `
            'finish them or set them back to todo'
    }

    # T87 is the Mac seat's half of this merge and cannot be done from here.
    $t87 = Join-Path $taskDir 'T87.md'
    if (-not (Test-Path $t87)) {
        Add-Criterion 'macseat' 'FAIL' 'T87 not found' ''
    }
    else {
        $t87text = [System.IO.File]::ReadAllText($t87)
        $t87status = 'unknown'
        if ($t87text -match '(?m)^status:\s*"?([^"\r\n]*)"?\s*$') { $t87status = $Matches[1].Trim() }
        if ($t87status -eq 'done' -or $t87status -like 'skipped*') {
            Add-Criterion 'macseat' 'PASS' "T87 is $t87status"
        }
        else {
            Add-Criterion 'macseat' 'FAIL' "T87 (Mac regression build + merge) is $t87status" `
                'the Mac seat runs it, or the cutover is explicitly sequenced behind a dated commitment'
        }
    }
}

# --------------------------------------------------------------- guards ------

$guardScript = Join-Path $PSScriptRoot 'guard-due.ps1'
if (-not (Test-Path $guardScript)) {
    Add-Criterion 'guards' 'FAIL' 'guard-due.ps1 not found' ''
}
else {
    $guardOut = & powershell -NoProfile -File $guardScript check 2>&1
    $guardCode = $LASTEXITCODE
    if ($guardCode -eq 0) {
        Add-Criterion 'guards' 'PASS' 'no acceptance harness is due'
    }
    else {
        $due = @($guardOut | Out-String) -split "`r?`n" | Where-Object { $_ -match 'DUE' } | Select-Object -First 3
        Add-Criterion 'guards' 'FAIL' ("guard-due reports DUE: {0}" -f (($due -join '; ').Trim())) `
            'run the named harness until it is clean, which re-stamps it'
    }
}

# --------------------------------------------------------------- gh repo -----

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Add-Criterion 'ghrepo' 'FAIL' 'gh CLI not installed' 'winget install GitHub.cli'
}
else {
    # `gh repo set-default --view` prints the configured repository, or an error
    # naming the fact that none is set. Anything other than the fork is the
    # landmine in the header: unqualified gh commands would talk to upstream.
    $ghDefault = (& gh repo set-default --view 2>&1 | Out-String).Trim()
    if ($ghDefault -eq $ForkRepo) {
        Add-Criterion 'ghrepo' 'PASS' "gh default repo is $ForkRepo"
    }
    else {
        # gh writes its "no default set" advice to stderr with an `X ` marker
        # and a follow-on sentence; report the fact, not the paragraph.
        $shown = '(none set)'
        if ($ghDefault -and $ghDefault -notmatch 'No default remote repository') {
            $shown = (($ghDefault -split "`r?`n")[0]).Trim()
        }
        Add-Criterion 'ghrepo' 'FAIL' "gh default repo is not the fork: $shown" `
            "gh repo set-default $ForkRepo"
    }
}

# ---------------------------------------------------------------- lanes ------

if (-not $RunLanes) {
    Add-Criterion 'lanes' 'UNKNOWN' 'floor lanes not measured this run' `
        're-run with -RunLanes'
    Add-Criterion 'accept' 'UNKNOWN' 'P1-P3 acceptance not measured this run' `
        're-run with -RunLanes'
}
else {
    $floor = Join-Path $PSScriptRoot 'floor-lane.ps1'
    if (-not (Test-Path $floor)) {
        Add-Criterion 'lanes' 'FAIL' 'floor-lane.ps1 not found' ''
    }
    else {
        Write-Host "running floor lanes (this takes minutes)..."
        # Per-record, never `| Out-String` on a merged native stream (T883): that
        # formats to the host's buffer width, so what lands in the criterion
        # would depend on the console this happened to run in.
        $laneOut = @(& powershell -NoProfile -File $floor -Lane all 2>&1)
        $laneCode = $LASTEXITCODE
        $laneTail = Get-LastLine $laneOut
        if ($laneCode -eq 0) {
            Add-Criterion 'lanes' 'PASS' ("floor-lane -Lane all: {0}" -f $laneTail)
        }
        else {
            Add-Criterion 'lanes' 'FAIL' ("floor-lane -Lane all exit {0}: {1}" -f $laneCode, $laneTail) `
                'fix the lane, then re-run'
        }
    }

    # Sequentially, never overlapped: an acceptance script kills agents and
    # takes the per-user pipe, and box load from a concurrent lane has wedged
    # these before (go.md step 3).
    $acceptFails = @()
    $acceptRan = @()
    foreach ($p in @('ipc-p1.ps1', 'ipc-p2.ps1', 'ipc-p3.ps1')) {
        $path = Join-Path $Repo (Join-Path 'test\win32' $p)
        if (-not (Test-Path $path)) {
            $acceptFails += "$p missing"
            continue
        }
        Write-Host "running $p ..."
        $out = @(& powershell -NoProfile -File $path 2>&1)
        $code = $LASTEXITCODE
        $acceptRan += $p
        if ($code -ne 0) {
            $acceptFails += ("{0} exit {1}: {2}" -f $p, $code, (Get-LastLine $out))
        }
    }
    if ($acceptFails.Count -eq 0) {
        Add-Criterion 'accept' 'PASS' ("{0} green" -f ($acceptRan -join ', '))
    }
    else {
        Add-Criterion 'accept' 'FAIL' ($acceptFails -join ' | ') 'fix what they caught, then re-run'
    }
}

# --------------------------------------------------------------- verdict -----

$failed = @($script:Criteria | Where-Object { $_.State -ne 'PASS' })
$ready = ($failed.Count -eq 0)

if ($Json) {
    $payload = [pscustomobject]@{
        ready      = $ready
        branch     = $Branch
        trunk      = $Trunk
        forkRepo   = $ForkRepo
        ranLanes   = [bool]$RunLanes
        criteria   = $script:Criteria
        unmet      = @($failed | ForEach-Object { $_.Name })
    }
    $payload | ConvertTo-Json -Depth 5
}
else {
    Write-Host ""
    Write-Host ("SHIP READINESS  {0} -> {1}" -f $Branch, $Trunk)
    Write-Host ("-" * 72)
    foreach ($c in $script:Criteria) {
        $mark = switch ($c.State) {
            'PASS' { 'ok  ' }
            'FAIL' { 'FAIL' }
            default { '??  ' }
        }
        Write-Host ("  {0}  {1,-11} {2}" -f $mark, $c.Name, $c.Detail)
        if ($c.State -ne 'PASS' -and $c.Remedy) {
            Write-Host ("        -> {0}" -f $c.Remedy)
        }
    }
    Write-Host ("-" * 72)
    if ($ready) {
        Write-Host "READY: every criterion satisfied. See docs\design\windows-parity-ship-workflow.md for the cutover steps."
    }
    else {
        Write-Host ("NOT READY: {0} of {1} criteria unmet ({2})." -f $failed.Count, $script:Criteria.Count, (($failed | ForEach-Object { $_.Name }) -join ', '))
    }
}

Pop-Location
if ($ready) { exit 0 } else { exit 1 }
