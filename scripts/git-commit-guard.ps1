# Commit guard for a SHARED working tree (tracker T948).
#
# Two Claude windows are the normal arrangement on this box - the go-loop
# window plus an unmarked window filing tasks or auditing (go.md step 0 never
# closes the unmarked one). They share one working tree, which means they share
# one INDEX, and `git commit` commits the index rather than "my work".
#
# On 2026-08-17 that cost T850 its own commit: the loop window had staged
# exactly its eight paths and was composing the message when the other window
# committed with `-A`. Git did what it was told - it committed the index, which
# by then held both sets of changes - so a whole clipboard fix landed under a
# subject describing none of it, and it was pushed before anyone noticed. Three
# things break when that happens: the dashboard's activity feed describes the
# wrong change, `set-status -Commit <sha>` points a task at a misleading
# artifact, and an unfinished edit from the other window can ship.
#
# Two mechanisms, deliberately independent, because either one alone still
# loses:
#
#   PREVENT - an advisory lock held across the stage->commit window (seconds),
#             enforced on everybody else by the `pre-commit` hook in
#             scripts\githooks. The holder's own git children carry
#             GHOZTTY_COMMIT_LOCK_KEY and pass through; another session's commit
#             is REFUSED with the remedy in the message. A lock older than its
#             ttl is stale and is cleared rather than obeyed, so a crashed
#             holder cannot wedge the repo.
#
#   DETECT  - `commit` reads the finished commit back and proves it contains
#             ONLY the paths it was asked to commit. A session that bypasses
#             the hook (--no-verify, a git that ignores hooksPath, a hook that
#             was never installed) still cannot make this quiet: the swallow is
#             named, with the sha, before the turn moves on. Prevention that is
#             only as good as the other window's cooperation is not a gate.
#
# The commit itself uses an explicit PATHSPEC (`git commit -- <paths>`), which
# ignores whatever else is sitting in the shared index. That is what keeps the
# theft from running in the other direction as well.
#
# One thing `commit` deliberately cannot carry: an INDEX-ONLY change, such as a
# mode bit set with `git update-index --chmod=+x` (core.filemode is false on
# Windows, so that is the only way to record one). A pathspec commit takes the
# WORKING TREE content of its paths and ignores the index, which is exactly what
# makes it immune to the other window - and equally blind to a staged mode. For
# those, hold the lock and commit the index yourself:
#
#   $k = 'modebit'
#   scripts\git-commit-guard.ps1 hold -Key $k
#   $env:GHOZTTY_COMMIT_LOCK_KEY = $k; git commit -m '...'
#   scripts\git-commit-guard.ps1 release -Force
#
# PUSHING IS PART OF COMMITTING (T1057). `commit` pushes by default and
# `-NoPush` is the way out, because the other arrangement is the one that
# failed: the rule "push immediately after every commit" is go.md step 4, it is
# what makes a commit visible to the other seat and survivable across a dead
# box, and with `-Push` as an opt-in it stayed honour-system - the user had to
# state it twice (2026-08-07, 2026-08-21). A rule restated is a rule not
# enforced. `unpushed` is the same question asked at a turn boundary, and it is
# wired into both ends of the turn: go-loop-exec.ps1's claim reports it, and
# parity-tasks.ps1's validate FAILS on it, so a finished task cannot be
# narrated over a commit that never left this machine.
#
# Actions: install | status | hold | release | commit | verify | push | unpushed
# Exit codes: 0 ok, 2 usage/error, 3 lock held by another session,
#             4 not the owner (release), 5 the commit contains foreign paths,
#             6 git refused the commit, 7 HEAD is ahead of its upstream.
#
#   powershell -NoProfile -File scripts\git-commit-guard.ps1 install
#   powershell -NoProfile -File scripts\git-commit-guard.ps1 commit `
#       -Paths 'src\apprt\win32\App.zig','docs\design\windows-parity-log.md' `
#       -MessageFile temp\msg.txt
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'status', 'hold', 'release', 'commit', 'verify', 'push', 'unpushed')]
    [string]$Action = 'status',

    [string]$Repo,
    # Where the lock lives. Defaults to <git-dir>\ghoztty-commit.lock, which is
    # per-worktree and never committed - the same scope as the index it guards.
    [string]$LockPath,
    [string[]]$Paths,
    [string]$Message,
    [string]$MessageFile,
    [string]$Sha,
    # Identifies the holder to a human reading a refusal. Not an identity check.
    [string]$Holder,
    # The token a child git must carry to be let through the hook. Generated per
    # hold; passed explicitly only by tests.
    [string]$Key,
    [int]$TtlSeconds = 0,
    # Kept so the documented `-Push` invocations that predate T1057 still bind;
    # pushing is the default now, so it asks for what already happens.
    [switch]$Push,
    # The explicit way NOT to push, which is the only way a commit is allowed to
    # stay on this box. It prints that it was used and why, so a turn that took
    # it can be explained rather than silently excused.
    [switch]$NoPush,
    [string]$Reason,
    [switch]$Force,
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
$hooksDir = Join-Path $PSScriptRoot 'githooks'

# How long a hold is honoured before the hook treats it as debris. The window it
# covers is a `git add` plus a `git commit`; 120s is two orders of magnitude of
# headroom over that, and short enough that a crashed holder blocks the other
# window for less time than it takes to notice.
$DefaultTtl = 120

function Fail([string]$msg, [int]$code) { Write-Output $msg; exit $code }

# Run git and answer with @{ Code; Out }.
#
# `& git ... 2>&1` under PowerShell 5.1 wraps every stderr LINE in an
# ErrorRecord, and with $ErrorActionPreference = 'Stop' that record is
# terminating - so `git add` printing its routine "LF will be replaced by CRLF"
# warning killed this script mid-commit on its first real use, with exit code 0
# in hand. Exit codes are the only failure signal here; stderr is text.
function Git-Run([string[]]$argList) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Repo @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
    } finally { $ErrorActionPreference = $prev }
}

function Get-GitDir {
    $d = & git -C $Repo rev-parse --absolute-git-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $d) { return $null }
    return ($d | Select-Object -First 1).Trim()
}

function Get-LockPath {
    if ($LockPath) { return $LockPath }
    $g = Get-GitDir
    if (-not $g) { return $null }
    return (Join-Path $g 'ghoztty-commit.lock')
}

function Read-Lock([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    $h = @{}
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ($line -match '^([a-z]+)=(.*)$') { $h[$matches[1]] = $matches[2] }
    }
    if (-not $h.ContainsKey('key')) { return $null }
    if (-not $h.ContainsKey('ttl')) { $h['ttl'] = "$DefaultTtl" }
    $h['age'] = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int]$h['epoch'])
    $h['stale'] = ($h['age'] -lt 0 -or $h['age'] -gt [int]$h['ttl'])
    return $h
}

function Write-Lock([string]$path, [string]$key, [string]$holder, [int]$ttl) {
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lines = @(
        "key=$key",
        "holder=$holder",
        "pid=$PID",
        "epoch=$epoch",
        "ttl=$ttl",
        "iso=$((Get-Date).ToString('o'))"
    )
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    # LF + no BOM: the reader is a POSIX sh hook.
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
}

function Default-Holder {
    $who = if ($env:GHOZTTY_PANE_ID) { "pane $env:GHOZTTY_PANE_ID" } else { "pid $PID" }
    return "$who ($env:USERNAME)"
}

# Repo-relative, forward slashes, no trailing slash - the shape `git show
# --name-only` answers in, so the two sets can be compared as strings.
function Normalize-Path([string]$p) {
    $s = $p.Trim() -replace '\\', '/'
    $rootFwd = ($Repo -replace '\\', '/').TrimEnd('/')
    if ($s -like "$rootFwd/*") { $s = $s.Substring($rootFwd.Length + 1) }
    return $s.TrimEnd('/')
}

# `powershell -File script.ps1 -Paths a,b,c` hands the whole list over as ONE
# string - -File binds every argument as text and never splits an array - so a
# comma-separated list is split here rather than silently becoming one absurd
# pathspec. Both spellings (repeated -Paths, or one comma-separated string) mean
# the same thing.
function Expand-Paths([string[]]$raw) {
    return @($raw | ForEach-Object { $_ -split ',' } | ForEach-Object { Normalize-Path $_ } | Where-Object { $_ })
}

# Where this branch stands against the thing it is supposed to be shared
# through. Kind is one of:
#   ok          - there is an upstream; Count says how far ahead HEAD is
#   no-upstream - the branch has never been pushed anywhere, so every commit on
#                 it is local-only. Not a lesser problem than being ahead: it is
#                 the same problem with a longer tail.
#   detached    - mid-rebase / a checked-out sha. Nothing to push, nothing to say.
#   no-repo     - caller's problem.
#
# Every git call here goes through Git-Run, and both reasons are traps this
# script has already been bitten by. `& git ... 2>$null` does NOT protect
# against $ErrorActionPreference = 'Stop' - a git that writes to stderr (asking
# for the upstream of a branch that has none does exactly that) still raises a
# terminating NativeCommandError. And `| Select-Object -First 1` tears the
# pipeline down before git exits, so the $LASTEXITCODE read afterwards belongs
# to a killed process: that alone made a branch with a perfectly good upstream
# report as having none.
function Get-PushState {
    $b = Git-Run @('symbolic-ref', '--quiet', '--short', 'HEAD')
    if ($b.Code -ne 0 -or -not $b.Out) {
        $inside = Git-Run @('rev-parse', '--is-inside-work-tree')
        if ($inside.Code -ne 0) { return @{ Kind = 'no-repo' } }
        return @{ Kind = 'detached'; Branch = ''; Upstream = ''; Count = 0 }
    }
    $branch = ($b.Out -split "`r?`n")[0].Trim()
    $u = Git-Run @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
    if ($u.Code -ne 0 -or -not $u.Out) {
        return @{ Kind = 'no-upstream'; Branch = $branch; Upstream = ''; Count = 0 }
    }
    $up = ($u.Out -split "`r?`n")[0].Trim()
    $c = Git-Run @('rev-list', '--count', "$up..HEAD")
    $n = 0
    if ($c.Code -eq 0) { [int]::TryParse((($c.Out -split "`r?`n")[0].Trim()), [ref]$n) | Out-Null }
    $subjects = @()
    if ($n -gt 0) {
        $l = Git-Run @('log', '--oneline', '--no-decorate', '-n', '8', "$up..HEAD")
        if ($l.Code -eq 0) { $subjects = @($l.Out -split "`r?`n" | Where-Object { $_.Trim() }) }
    }
    return @{ Kind = 'ok'; Branch = $branch; Upstream = $up; Count = $n; Subjects = $subjects }
}

# The state as the lines a human acts on: @{ Ok; Lines }. A function that both
# printed and answered would be unusable here - PowerShell folds everything a
# function writes into its return value, so `$ok = Report ...` would swallow the
# very lines the report exists to show.
function Get-PushReport($st) {
    $lines = @()
    switch ($st.Kind) {
        'detached' { return @{ Ok = $true; Lines = @('push check skipped (detached HEAD - nothing to push)') } }
        'no-upstream' {
            $lines += "UNPUSHED WORK: branch $($st.Branch) has no upstream - nothing on it has ever been shared."
            $lines += "  (set one and push: git -C $Repo push -u origin $($st.Branch))"
            return @{ Ok = $false; Lines = $lines }
        }
        'ok' {
            if ($st.Count -eq 0) { return @{ Ok = $true; Lines = @("push clean ($($st.Branch) == $($st.Upstream))") } }
            $lines += "UNPUSHED WORK: $($st.Count) commit(s) on $($st.Branch) are not on $($st.Upstream):"
            foreach ($s in $st.Subjects) { $lines += "  $s" }
            $lines += "  (go.md step 4: every commit is pushed, mid-task ones included - an unpushed commit is"
            $lines += "   invisible to the other seat and dies with the box. Push them:"
            $lines += "   powershell -NoProfile -File scripts\git-commit-guard.ps1 push)"
            return @{ Ok = $false; Lines = $lines }
        }
    }
    return @{ Ok = $true; Lines = @() }
}

# Push, and treat the one recoverable failure as recoverable: a rejected push
# means somebody else moved the branch, which go.md step 4 answers with
# pull/rebase and push again. Deliberately NO autostash - the working tree is
# shared with the other Claude window, and quietly stashing its half-written
# edits to get a push through is a worse outcome than saying the push is stuck.
# Narration comes back in Lines rather than being written here, for the same
# reason Get-PushReport does not print: a bare string inside a function is not
# output, it is part of the RETURN VALUE, and one stray line turns the result
# hashtable into an array whose .Ok is a collection. That shape "worked" by
# accident on the first run of this code.
function Invoke-PushWithRebase {
    $lines = @()
    $res = Git-Run @('push')
    if ($res.Code -eq 0) { return @{ Ok = $true; Out = $res.Out; Rebased = $false; Lines = $lines } }
    if ($res.Out -notmatch 'non-fast-forward|fetch first|Updates were rejected|behind its remote') {
        return @{ Ok = $false; Out = $res.Out; Rebased = $false; Lines = $lines }
    }
    $lines += 'push rejected (the branch moved under us) - pulling with rebase, per go.md step 4'
    $pull = Git-Run @('-c', 'rebase.autoStash=false', 'pull', '--rebase')
    if ($pull.Code -ne 0) {
        return @{ Ok = $false; Rebased = $true; Lines = $lines
            Out = ("push was rejected and the rebase did not run:`n" + $pull.Out) }
    }
    $res2 = Git-Run @('push')
    return @{ Ok = ($res2.Code -eq 0); Out = $res2.Out; Rebased = $true; Lines = $lines }
}

function Test-PathCovered([string]$file, [string[]]$requested) {
    foreach ($r in $requested) {
        if ($file -eq $r -or $file.StartsWith("$r/")) { return $true }
    }
    return $false
}

switch ($Action) {

    # ---------------------------------------------------------------- install
    # core.hooksPath is LOCAL config (per clone, like the index it guards), so
    # this cannot ride in with a `git pull` - it is re-asserted every turn by
    # go-loop-exec.ps1's claim. Absolute path on purpose: git's handling of a
    # relative hooksPath has changed between versions, and a hooks dir resolved
    # against the wrong cwd is a guard that silently is not there.
    'install' {
        $hook = Join-Path $hooksDir 'pre-commit'
        if (-not (Test-Path -LiteralPath $hook)) { Fail "ERROR no pre-commit hook at $hook" 2 }
        $current = (& git -C $Repo config --local --get core.hooksPath 2>$null)
        if ($LASTEXITCODE -ne 0) { $current = $null }
        $want = (Resolve-Path -LiteralPath $hooksDir).Path
        if ($current -and (($current -replace '\\', '/').TrimEnd('/') -eq ($want -replace '\\', '/').TrimEnd('/'))) {
            if (-not $Quiet) { "commit guard armed (hooksPath already set)" }
            exit 0
        }
        & git -C $Repo config --local core.hooksPath $want 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "ERROR could not set core.hooksPath" 2 }
        if (-not $Quiet) { "commit guard armed (hooksPath -> $want)" }
        exit 0
    }

    # ----------------------------------------------------------------- status
    'status' {
        $lp = Get-LockPath
        if (-not $lp) { Fail "ERROR not a git repo: $Repo" 2 }
        $L = Read-Lock $lp
        $hooks = (& git -C $Repo config --local --get core.hooksPath 2>$null)
        if ($LASTEXITCODE -ne 0) { $hooks = '' }
        if ($Json) {
            $jKey = ''; $jHolder = ''; $jAge = 0; $jTtl = $DefaultTtl
            if ($L) { $jKey = $L['key']; $jHolder = $L['holder']; $jAge = $L['age']; $jTtl = [int]$L['ttl'] }
            ([ordered]@{
                lock      = $lp
                held      = ($null -ne $L -and -not $L['stale'])
                stale     = ($null -ne $L -and $L['stale'])
                key       = $jKey
                holder    = $jHolder
                age       = $jAge
                ttl       = $jTtl
                hooksPath = $hooks
            } | ConvertTo-Json -Depth 3)
            exit 0
        }
        if (-not $L) { "free (hooksPath=$hooks)"; exit 0 }
        if ($L['stale']) { "stale holder=`"$($L['holder'])`" age=$($L['age'])s ttl=$($L['ttl'])s - the next commit clears it"; exit 0 }
        "held holder=`"$($L['holder'])`" age=$($L['age'])s ttl=$($L['ttl'])s key=$($L['key'])"
        exit 0
    }

    # ------------------------------------------------------------------- hold
    'hold' {
        $lp = Get-LockPath
        if (-not $lp) { Fail "ERROR not a git repo: $Repo" 2 }
        $ttl = if ($TtlSeconds -gt 0) { $TtlSeconds } else { $DefaultTtl }
        $L = Read-Lock $lp
        if ($L -and -not $L['stale'] -and -not $Force -and ($L['key'] -ne $Key)) {
            "BUSY holder=`"$($L['holder'])`" age=$($L['age'])s - another session is composing a commit"
            exit 3
        }
        $k = if ($Key) { $Key } else { [guid]::NewGuid().ToString('N') }
        $h = if ($Holder) { $Holder } else { Default-Holder }
        Write-Lock $lp $k $h $ttl
        if (-not $Quiet) { "HELD key=$k holder=`"$h`" ttl=${ttl}s" }
        exit 0
    }

    # ---------------------------------------------------------------- release
    'release' {
        $lp = Get-LockPath
        if (-not $lp) { Fail "ERROR not a git repo: $Repo" 2 }
        $L = Read-Lock $lp
        if (-not $L) { if (-not $Quiet) { "free" }; exit 0 }
        if (-not $Force -and $Key -and $L['key'] -ne $Key) {
            "NOT OWNER holder=`"$($L['holder'])`" - pass -Force to break it"
            exit 4
        }
        Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue
        if (-not $Quiet) { "RELEASED" }
        exit 0
    }

    # ----------------------------------------------------------------- commit
    # Stage exactly these paths, commit exactly these paths, then read the
    # commit back and prove it. The pathspec is what makes the commit immune to
    # what else is in the shared index; the read-back is what makes a bypassed
    # hook loud instead of silent.
    'commit' {
        if (-not $Paths -or $Paths.Count -eq 0) { Fail "ERROR commit needs -Paths" 2 }
        if (-not $Message -and -not $MessageFile) { Fail "ERROR commit needs -Message or -MessageFile" 2 }
        $lp = Get-LockPath
        if (-not $lp) { Fail "ERROR not a git repo: $Repo" 2 }

        $want = @(Expand-Paths $Paths)
        $ttl = if ($TtlSeconds -gt 0) { $TtlSeconds } else { $DefaultTtl }

        $L = Read-Lock $lp
        if ($L -and -not $L['stale'] -and -not $Force) {
            "BUSY holder=`"$($L['holder'])`" age=$($L['age'])s - another session is composing a commit"
            exit 3
        }
        $k = if ($Key) { $Key } else { [guid]::NewGuid().ToString('N') }
        $holderText = if ($Holder) { $Holder } else { Default-Holder }
        Write-Lock $lp $k $holderText $ttl

        $msgFile = $MessageFile
        $tempMsg = $null
        if (-not $msgFile) {
            $tempMsg = Join-Path ([System.IO.Path]::GetTempPath()) "ghoztty-commit-$PID.txt"
            [System.IO.File]::WriteAllText($tempMsg, $Message, (New-Object System.Text.UTF8Encoding $false))
            $msgFile = $tempMsg
        }

        $prev = & git -C $Repo rev-parse HEAD 2>$null
        $env:GHOZTTY_COMMIT_LOCK_KEY = $k
        try {
            # Stage first so a NEW file is known to the index - a pathspec
            # commit only matches paths git already knows.
            $add = Git-Run (@('add', '--') + $want)
            if ($add.Code -ne 0) { "ERROR git add failed:"; $add.Out; exit 6 }

            # What else is somebody else holding in the index right now? Not an
            # error - the pathspec excludes it - but the one moment where the
            # shared index is observable, so it is said out loud.
            $stagedAll = @(& git -C $Repo diff --cached --name-only 2>$null | Where-Object { $_ })
            $foreignStaged = @($stagedAll | Where-Object { -not (Test-PathCovered $_ $want) })
            if ($foreignStaged.Count -gt 0 -and -not $Quiet) {
                "note: $($foreignStaged.Count) path(s) staged by another session are EXCLUDED by the pathspec:"
                foreach ($f in ($foreignStaged | Select-Object -First 5)) { "  $f" }
            }

            $commit = Git-Run (@('commit', '-F', $msgFile, '--cleanup=whitespace', '--') + $want)
            if ($commit.Code -ne 0) {
                "ERROR git commit failed:"; $commit.Out; exit 6
            }
        } finally {
            Remove-Item Env:GHOZTTY_COMMIT_LOCK_KEY -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue
            if ($tempMsg) { Remove-Item -LiteralPath $tempMsg -Force -ErrorAction SilentlyContinue }
        }

        $sha = (& git -C $Repo rev-parse HEAD 2>$null | Select-Object -First 1)
        if ($sha -eq $prev) { "ERROR no commit was created"; exit 6 }
        $short = (& git -C $Repo rev-parse --short HEAD 2>$null | Select-Object -First 1)

        $actual = @(& git -C $Repo show --pretty=format: --name-only --no-renames $sha 2>$null | Where-Object { $_ })
        $extra = @($actual | Where-Object { -not (Test-PathCovered $_ $want) })
        if ($extra.Count -gt 0) {
            ""
            "SWALLOWED WORK: commit $short contains $($extra.Count) path(s) it was never asked to commit."
            foreach ($f in $extra) { "  $f" }
            "This is T948: another session's changes landed under this subject."
            "Nothing has been pushed. Split them out before anything else:"
            "  git -C $Repo reset --soft HEAD~1   # then re-stage only your paths"
            exit 5
        }
        "COMMITTED $short ($($actual.Count) path(s), all requested)"

        # T1057: the push is not a switch any more. A commit that stays on this
        # box is invisible to the other seat and dies with the box, and the rule
        # saying so had to be restated twice while it was opt-in.
        if ($NoPush) {
            $why = if ($Reason) { $Reason } else { 'no reason given' }
            "PUSH SKIPPED (-NoPush): $why"
            "  $short is now local-only; the next claim and the next validate will both say so until it is pushed."
            exit 0
        }
        # Nowhere to push TO is not the same failure as a push that did not
        # work: the commit is made and correct, and exiting non-zero over it
        # would read as "the commit failed". Say it, and leave the teeth to the
        # gate - `unpushed` counts a branch with no upstream as unpushed work,
        # so this cannot go quiet.
        $st = Get-PushState
        if ($st.Kind -eq 'detached') { "PUSH SKIPPED: detached HEAD - there is no branch to push"; exit 0 }
        if ($st.Kind -eq 'no-upstream') {
            "PUSH SKIPPED: branch $($st.Branch) has no upstream - $short is local-only until one is set"
            "  (set one and push: git -C $Repo push -u origin $($st.Branch))"
            exit 0
        }
        # git push narrates progress on stderr even when it works - the same
        # trap Git-Run exists for, and here it would report a good push as a
        # failure right after a commit that is already made.
        # NOT $push: PowerShell variable names are case-insensitive, so that
        # would assign a hashtable to the [switch]$Push parameter and die in
        # its type conversion before a line of this block ran.
        $pushRes = Invoke-PushWithRebase
        $pushRes.Lines
        if (-not $pushRes.Ok) { "ERROR push failed:"; $pushRes.Out; exit 6 }
        if ($pushRes.Rebased) {
            # A rebase rewrites the commit, so the sha reported before it is no
            # longer the one on the remote - and `set-status -Commit <sha>`
            # would pin the task to a commit that no longer exists.
            $short = (& git -C $Repo rev-parse --short HEAD 2>$null | Select-Object -First 1)
            "PUSHED $short (rebased onto the moved branch; the sha above is the pre-rebase one)"
        } else {
            "PUSHED $short"
        }
        exit 0
    }

    # ------------------------------------------------------------------- push
    # The remedy `unpushed` names, so the answer to "you have unpushed work" is
    # one command rather than a decision about how to handle a rejection.
    'push' {
        $st = Get-PushState
        if ($st.Kind -eq 'no-repo') { Fail "ERROR not a git repo: $Repo" 2 }
        if ($st.Kind -eq 'detached') { "push check skipped (detached HEAD - nothing to push)"; exit 0 }
        if ($st.Kind -eq 'no-upstream') { (Get-PushReport $st).Lines; exit 7 }
        if ($st.Count -eq 0) { "push clean ($($st.Branch) == $($st.Upstream))"; exit 0 }
        $res = Invoke-PushWithRebase
        $res.Lines
        if (-not $res.Ok) { "ERROR push failed:"; $res.Out; exit 6 }
        "PUSHED $($st.Count) commit(s) to $($st.Upstream)$(if ($res.Rebased) { ' (after a rebase onto the moved branch)' })"
        exit 0
    }

    # --------------------------------------------------------------- unpushed
    # "Is anything committed here that origin has never seen?" Asked at both
    # ends of a turn: reported by go-loop-exec.ps1 claim, failed on by
    # parity-tasks.ps1 validate. Exit 7 is the whole point - a report nobody is
    # obliged to act on is how the same rule ends up being restated twice.
    'unpushed' {
        $st = Get-PushState
        if ($st.Kind -eq 'no-repo') { Fail "ERROR not a git repo: $Repo" 2 }
        if ($Json) {
            ([ordered]@{
                kind     = $st.Kind
                branch   = [string]$st.Branch
                upstream = [string]$st.Upstream
                count    = [int]$st.Count
                clean    = ($st.Kind -eq 'detached' -or ($st.Kind -eq 'ok' -and $st.Count -eq 0))
            } | ConvertTo-Json -Depth 3)
            if ($st.Kind -eq 'no-upstream' -or ($st.Kind -eq 'ok' -and $st.Count -gt 0)) { exit 7 }
            exit 0
        }
        $report = Get-PushReport $st
        if (-not ($Quiet -and $report.Ok)) { $report.Lines }
        if ($report.Ok) { exit 0 }
        exit 7
    }

    # ----------------------------------------------------------------- verify
    # The same read-back, after the fact: does <sha> contain only these paths?
    'verify' {
        if (-not $Paths -or $Paths.Count -eq 0) { Fail "ERROR verify needs -Paths" 2 }
        $target = if ($Sha) { $Sha } else { 'HEAD' }
        $want = @(Expand-Paths $Paths)
        $actual = @(& git -C $Repo show --pretty=format: --name-only --no-renames $target 2>$null | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { Fail "ERROR no such commit: $target" 2 }
        $extra = @($actual | Where-Object { -not (Test-PathCovered $_ $want) })
        if ($extra.Count -gt 0) {
            "SWALLOWED WORK: $target contains $($extra.Count) foreign path(s):"
            foreach ($f in $extra) { "  $f" }
            exit 5
        }
        "CLEAN $target ($($actual.Count) path(s), all requested)"
        exit 0
    }
}
