<#
.SYNOPSIS
    T1219 - what does CI say about the commit this branch is sitting on?

.DESCRIPTION
    The loop pushes on every turn (T1057 made that a gate) and a build machine
    immediately tries to build what it pushed. Until this script, nothing in
    the turn ever read the answer: on 2026-08-31 fork-ci's windows-cross job
    had been failing for ten hours, with the exact failure that later killed
    the win-v1.36.0 release run, and the first thing to notice was the release.

    Same division of labour as stranded work (T847) and unpushed work (T1057):

      * `go-loop-exec.ps1 claim` REPORTS the verdict at the top of every turn
        and never fails on it - a claim that can exit nonzero over the state of
        a build machine would wedge the loop, which is the disease not the cure.
      * `parity-tasks.ps1 validate` FAILS on a red one, at the gate every
        commit passes through, so a turn cannot narrate a finished task over a
        branch the build says is broken.

    THE SUBJECT IS THE BRANCH HEAD SHA, not "the newest run". A red run for a
    commit three pushes back has usually already been answered; the question
    that matters at a turn boundary is whether what is on this branch right now
    builds. When no run exists for that sha yet (just pushed, or never pushed)
    the verdict is CI UNKNOWN - informational, because "nobody has built it
    yet" is not evidence of breakage.

    AN IN-PROGRESS RUN IS NOT A FAILURE. Every turn's own push starts a build
    that takes minutes; gating on it would stop the loop dead at every boundary
    for no information. It is reported, and the NEXT turn's claim is what
    catches it - which is exactly the cadence that was missing.

    Verdict, over the runs whose headSha is the branch head:

      CI RED          any completed run concluded failure / timed_out /
                      startup_failure / action_required. Names the workflow,
                      the failing job and the run URL.
      CI IN PROGRESS  no red one, and at least one run still going.
      CI OK           every run completed, at least one succeeded.
      CI NO VERDICT   runs exist but all were skipped or cancelled.
      CI UNKNOWN      no run for this sha, or gh is missing / unauthenticated /
                      the network is down. Never a failure.

    Exit codes: 0 for everything except CI RED, which is 8.

    ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

.EXAMPLE
    powershell -NoProfile -File scripts\ci-status.ps1 check
    powershell -NoProfile -File scripts\ci-status.ps1 check -Quiet   # green: silent
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check')]
    [string]$Action = 'check',

    [string]$Repo,

    # The GitHub repository to ask. NEVER let `gh` resolve this itself: this
    # repo has `upstream` (ghostty-org/ghostty) as a remote and a bare gh
    # command resolves to it (go.md, step 6.9).
    [string]$Nwo = 'dzearing/ghoztty',

    # The commit whose build we are asking about. Defaults to the repo's HEAD.
    [string]$Sha,

    # The branch to enumerate runs for. Defaults to the repo's current branch.
    [string]$Branch,

    # Read the run list from a file instead of calling gh. This is how the
    # acceptance harness constructs a red verdict without a red build machine:
    # the parsing and the verdict are the script's own, only the transport is
    # replaced. Also settable as GHOZTTY_CI_RUNS_JSON so the two callers can be
    # driven red through their own command lines.
    [string]$RunsJsonFile,

    [int]$TimeoutSeconds = 30,

    # Say nothing when the verdict is green. The claim wants every line; the
    # validate gate only wants the bad news.
    [switch]$Quiet,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not $RunsJsonFile -and $env:GHOZTTY_CI_RUNS_JSON) { $RunsJsonFile = $env:GHOZTTY_CI_RUNS_JSON }
if (-not $Sha -and $env:GHOZTTY_CI_SHA) { $Sha = $env:GHOZTTY_CI_SHA }

# Conclusions that mean the build said no. `cancelled` is deliberately absent:
# a cancelled run is a superseded push or somebody's hand on the button, and
# treating it as red would make the gate cry wolf on every fast follow-up.
$RedConclusions = @('failure', 'timed_out', 'startup_failure', 'action_required')

function Get-GitValue([string[]]$argList) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Repo @argList 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (@($out) -join "`n").Trim()
    } finally { $ErrorActionPreference = $prev }
}

# Run gh and answer with @{ Code; Out }. Same stderr discipline as
# git-commit-guard.ps1's Git-Run: under PS 5.1 with $ErrorActionPreference =
# 'Stop', a native command's stderr line becomes a TERMINATING ErrorRecord, so
# a routine gh warning would kill the claim it was only supposed to inform.
function Invoke-Gh([string[]]$argList) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # NEVER `| Out-String` here: it wraps at the host's buffer width, and a
        # wrap lands INSIDE a sha in the JSON payload - which ConvertFrom-Json
        # tolerates, so the corruption shows up as "no run for this sha" rather
        # than as a parse error. Cost half an hour on the first run of this.
        $out = @(& gh @argList 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
        return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
    } catch {
        return @{ Code = 127; Out = $_.Exception.Message }
    } finally { $ErrorActionPreference = $prev }
}

# PS 5.1's ConvertFrom-Json hands a JSON array back as ONE object rather than
# enumerating it, so `@(... | ConvertFrom-Json)` counts 1 no matter how many
# runs came back - and the whole list then looks like a single run whose
# headSha matches nothing. The ForEach-Object is what unrolls it.
function Expand-Json([string]$text) {
    if (-not $text) { return @() }
    return @($text | ConvertFrom-Json | ForEach-Object { $_ })
}

function Get-Runs {
    param([string]$ForBranch)
    if ($RunsJsonFile) {
        if (-not (Test-Path -LiteralPath $RunsJsonFile)) {
            return @{ Ok = $false; Why = "runs file not found: $RunsJsonFile"; Runs = @() }
        }
        try {
            $text = [System.IO.File]::ReadAllText($RunsJsonFile, [System.Text.Encoding]::UTF8)
            return @{ Ok = $true; Why = ''; Runs = @(Expand-Json $text) }
        } catch {
            return @{ Ok = $false; Why = "runs file is not JSON: $RunsJsonFile"; Runs = @() }
        }
    }
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { return @{ Ok = $false; Why = 'gh is not installed on this box'; Runs = @() } }
    $ghArgs = @('run', 'list', '--repo', $Nwo, '--branch', $ForBranch, '--limit', '30',
        '--json', 'databaseId,headSha,workflowName,status,conclusion,event,url,createdAt')
    $r = Invoke-Gh $ghArgs
    if ($r.Code -ne 0) {
        $why = ($r.Out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if (-not $why) { $why = "gh run list exited $($r.Code)" }
        return @{ Ok = $false; Why = $why; Runs = @() }
    }
    try { return @{ Ok = $true; Why = ''; Runs = @(Expand-Json $r.Out) } }
    catch { return @{ Ok = $false; Why = 'gh returned output that is not JSON'; Runs = @() } }
}

# The one extra call, made only when the verdict is already red: which job
# failed? A run url alone sends the reader to a page to find that out, and the
# whole point of reporting at a turn boundary is that the answer is already in
# front of them.
function Get-FailingJobs {
    param($Run)
    # Offline (the acceptance fixture): the run object may carry its own `jobs`
    # array, in the shape `gh run view --json jobs` returns. The FILTER below is
    # the real one either way - only the transport is replaced.
    if ($RunsJsonFile) {
        if ($null -eq $Run.jobs) { return @() }
        return @($Run.jobs |
            Where-Object { $RedConclusions -contains [string]$_.conclusion } |
            ForEach-Object { [string]$_.name })
    }
    if (-not $Run.databaseId) { return @() }
    $r = Invoke-Gh @('run', 'view', [string]$Run.databaseId, '--repo', $Nwo, '--json', 'jobs')
    if ($r.Code -ne 0) { return @() }
    try {
        $parsed = $r.Out | ConvertFrom-Json
        return @($parsed.jobs |
            Where-Object { $RedConclusions -contains [string]$_.conclusion } |
            ForEach-Object { [string]$_.name })
    } catch { return @() }
}

# --------------------------------------------------------------------------
$head = $Sha
if (-not $head) { $head = Get-GitValue @('rev-parse', 'HEAD') }
$branch = $Branch
if (-not $branch) { $branch = Get-GitValue @('rev-parse', '--abbrev-ref', 'HEAD') }

$lines = @()
$verdict = 'unknown'
$detail = ''
$runUrl = ''
$jobs = @()

if (-not $head -or -not $branch -or $branch -eq 'HEAD') {
    $verdict = 'unknown'
    $detail = 'no branch head to ask about (detached HEAD, or not a git repo)'
}
else {
    $short = $head.Substring(0, [Math]::Min(9, $head.Length))
    $fetched = Get-Runs -ForBranch $branch
    if (-not $fetched.Ok) {
        $verdict = 'unknown'
        $detail = $fetched.Why
    }
    else {
        $mine = @($fetched.Runs | Where-Object { [string]$_.headSha -eq $head })
        if ($mine.Count -eq 0) {
            $verdict = 'unknown'
            $detail = "no run for $short yet on $branch"
        }
        else {
            $red = @($mine | Where-Object {
                    [string]$_.status -eq 'completed' -and $RedConclusions -contains [string]$_.conclusion
                })
            $running = @($mine | Where-Object { [string]$_.status -ne 'completed' })
            $good = @($mine | Where-Object { [string]$_.conclusion -eq 'success' })
            if ($red.Count -gt 0) {
                $verdict = 'red'
                $first = $red[0]
                $runUrl = [string]$first.url
                $jobs = @(Get-FailingJobs $first)
                $detail = "{0} concluded {1} for {2}" -f $first.workflowName, $first.conclusion, $short
            }
            elseif ($running.Count -gt 0) {
                $verdict = 'in-progress'
                $detail = "{0} still running for {1}" -f (@($running | ForEach-Object { $_.workflowName }) -join ', '), $short
            }
            elseif ($good.Count -gt 0) {
                $verdict = 'ok'
                $detail = "{0} passed for {1}" -f (@($good | ForEach-Object { $_.workflowName }) -join ', '), $short
            }
            else {
                $verdict = 'no-verdict'
                $detail = "every run for $short was skipped or cancelled"
            }
        }
    }
}

switch ($verdict) {
    'red' {
        $lines += ("CI RED {0} (run {1})" -f $detail, $runUrl)
        foreach ($j in @($jobs | Select-Object -First 6)) { $lines += ("    failing job: {0}" -f $j) }
        if ($jobs.Count -gt 6) { $lines += ("    ... and {0} more failing job(s)" -f ($jobs.Count - 6)) }
        $lines += "  (the branch this turn is pushing onto does not build: fix it, or -NoCiCheck with a reason)"
    }
    'in-progress' { $lines += ("CI IN PROGRESS {0} - not a failure; the next turn's claim reads the result" -f $detail) }
    'ok' { $lines += ("CI OK {0}" -f $detail) }
    'no-verdict' { $lines += ("CI NO VERDICT {0}" -f $detail) }
    default { $lines += ("CI UNKNOWN {0}" -f $detail) }
}

if ($Json) {
    ([ordered]@{
            verdict = $verdict
            sha     = [string]$head
            branch  = [string]$branch
            detail  = $detail
            url     = $runUrl
            jobs    = @($jobs)
            red     = ($verdict -eq 'red')
        } | ConvertTo-Json -Depth 4)
}
elseif (-not ($Quiet -and $verdict -ne 'red')) {
    $lines
}

if ($verdict -eq 'red') { exit 8 }
exit 0
