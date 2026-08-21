<#
.SYNOPSIS
  The per-feature lifecycle after the cutover: a worktree off `main`, a branch,
  a pull request, and a teardown - as four commands instead of four remembered
  incantations.

.DESCRIPTION
  T1058. User directive, 2026-08-21: after the branch is merged back, "continue
  work from there or build individual worktrees for new features and make prs."

  Once the trunk is `main`, a turn no longer commits where it stands. It forks a
  worktree, works there, proposes the result, and the worktree goes away when
  the proposal lands. Every one of those steps has a way to be subtly wrong -
  branching off a stale main, opening the PR against the wrong repository,
  deleting a worktree that still holds unpushed commits - so each one is a
  command here with the check built in rather than a line in a document that a
  turn may or may not read carefully.

  THE COMMANDS

    new     Create `<repo>-wt\<slug>` holding a fresh branch off the trunk.
            Fetches first, so the fork point is today's main and not whatever
            was cached. Refuses a slug that already exists rather than
            reattaching to it, because silently landing in someone else's
            worktree is how two features end up in one branch.

    list    Every worktree in this family, with its branch, its commit, whether
            it is dirty, whether it is pushed, and its open PR if it has one.
            This is what a turn reads when it inherits work instead of starting
            it.

    pr      Push the branch and open (or report) its pull request. ALWAYS with
            an explicit --repo: this repo has `upstream` (ghostty-org/ghostty)
            as a remote and gh resolves to it by default, so an unqualified
            `gh pr create` here offers the fork's work to the public Ghostty
            project. Refuses a dirty tree and refuses a branch with no commits
            of its own, since both produce a PR that says nothing.

    done    Remove the worktree and delete its branch. Refuses while the tree is
            dirty or the branch has unpushed commits, and refuses while the PR
            is still open unless -Force - the merge is the signal that the work
            is safe to delete, and "I am fairly sure it merged" is not.

  WHY A WORKTREE AND NOT A BRANCH SWITCH. This box runs a long-lived Ghoztty
  build out of `zig-out`, a dashboard server, an agent, and a go-loop whose lock
  is keyed on a pane in this directory. `git checkout` under all of that swaps
  the source out from under a running build; a worktree gives the feature its
  own directory and leaves the loop's tree alone. It also means an unfinished
  feature is a directory somebody can see, not a stash somebody must remember.

  RELATIONSHIP TO THE /wt SKILL. The user's `/wt` skill also makes worktrees; it
  is the INTERACTIVE path - it opens a Ghoztty window, installs dependencies and
  starts a Claude session for a human. This is the loop's non-interactive path
  and deliberately launches nothing. They can coexist on the same worktree.

  EXIT CODES
    0  the command did what it says
    1  refused, with the reason on stdout
    2  the command could not run at all (bad repo, missing git or gh)

.EXAMPLE
  powershell -NoProfile -File scripts\ship-feature.ps1 new -Slug banner-fade
  powershell -NoProfile -File scripts\ship-feature.ps1 list
  powershell -NoProfile -File scripts\ship-feature.ps1 pr -Slug banner-fade -Title "..." -Body "..."
  powershell -NoProfile -File scripts\ship-feature.ps1 done -Slug banner-fade
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('new', 'list', 'pr', 'done')]
    [string]$Command,

    # Short kebab-case name for the feature. Becomes both the worktree
    # directory name and the leaf of the branch name.
    [string]$Slug,

    # Resolved in the body ($PSScriptRoot is unbound in parameter defaults).
    [string]$Repo,

    # What a feature branch forks from, and what its PR targets.
    [string]$Trunk = 'main',
    [string]$Remote = 'origin',

    # Branch names carry this prefix so they sort together and match the shape
    # `main` already carries from the Mac seat (users/dzearing/<feature>).
    [string]$BranchPrefix = 'users/dzearing',

    # The fork, named explicitly in every gh call. See the header.
    [string]$ForkRepo = 'dzearing/ghoztty',

    # `pr` only.
    [string]$Title,
    [string]$Body,
    [switch]$Draft,

    # `done` only: delete even though the PR is still open or unmergeable. Says
    # so loudly; exists for a feature that was abandoned rather than merged.
    [switch]$Force,

    # Skip the network fetch. For tests and for a box with no network; the fork
    # point is then whatever the local trunk ref happens to be, which is exactly
    # the staleness `new` normally prevents, so it prints that it was used.
    [switch]$NoFetch,

    [switch]$Json
)

$ErrorActionPreference = 'Continue'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path (Join-Path $Repo '.git'))) {
    Write-Host "ERROR: not a git repo: $Repo"
    exit 2
}

# Worktrees live BESIDE the repo, never inside it: a worktree under the repo
# root would be walked by every glob, every `zig build` cache scan and every
# tracker sweep in here, and .gitignore would have to grow a rule that a new
# slug could outrun.
$WorktreeRoot = "$Repo-wt"

function Write-Result {
    param([string]$Text)
    Write-Host $Text
}

function Invoke-GitIn {
    param([string]$Dir, [string[]]$GitArgs)
    $out = & git -C $Dir @GitArgs 2>&1
    return @{ Ok = ($LASTEXITCODE -eq 0); Text = ($out | Out-String).Trim(); Code = $LASTEXITCODE }
}

function Get-SlugBranch {
    param([string]$S)
    return "$BranchPrefix/$S"
}

function Test-Slug {
    param([string]$S)
    # Kebab-case only. The slug becomes a directory name AND a git ref, and the
    # intersection of what those two accept is narrower than either.
    return ($S -match '^[a-z0-9][a-z0-9-]*[a-z0-9]$' -or $S -match '^[a-z0-9]$')
}

function Get-FamilyWorktrees {
    # `git worktree list --porcelain` is the only listing that survives paths
    # with spaces; the human-readable form is column-aligned and ambiguous.
    $lines = @(& git -C $Repo worktree list --porcelain 2>&1)
    $items = @()
    $cur = $null
    foreach ($l in $lines) {
        $s = "$l"
        if ($s -match '^worktree\s+(.+)$') {
            if ($cur) { $items += $cur }
            $cur = [pscustomobject]@{ Path = $Matches[1].Trim(); Branch = ''; Head = '' }
        }
        elseif ($s -match '^HEAD\s+(\S+)' -and $cur) { $cur.Head = $Matches[1] }
        elseif ($s -match '^branch\s+refs/heads/(.+)$' -and $cur) { $cur.Branch = $Matches[1].Trim() }
    }
    if ($cur) { $items += $cur }
    # Only ours: anything under the worktree root. Someone else's detached
    # worktree elsewhere on the box is none of this script's business.
    $rootNorm = ($WorktreeRoot -replace '\\', '/').TrimEnd('/')
    return @($items | Where-Object {
            $p = ($_.Path -replace '\\', '/').TrimEnd('/')
            $p -like "$rootNorm/*"
        })
}

# THE ONLY place in this script that runs a repository-scoped gh verb, and it
# passes --repo unconditionally. A single funnel rather than --repo on each call
# site because the failure mode is a call that SUCCEEDS against the wrong
# repository - there is no error to catch, and by the time anything is
# observable a pull request exists on the upstream Ghostty project. One funnel
# is also what makes the scan in test\win32\ship-workflow.ps1 section C exact:
# a second gh call anywhere else in the file is a finding, not a judgement call.
function Invoke-GhPr {
    param([string]$Verb, [string[]]$Rest = @())
    $out = & gh pr $Verb --repo $ForkRepo @Rest 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = ($out | Out-String).Trim() }
}

function Get-PrForBranch {
    param([string]$BranchName)
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { return $null }
    $r = Invoke-GhPr 'list' @('--head', $BranchName, '--state', 'all', '--json', 'number,state,title,url,isDraft')
    if (-not $r.Ok) { return $null }
    try { $parsed = $r.Text | ConvertFrom-Json } catch { return $null }
    if (-not $parsed) { return $null }
    return @($parsed)[0]
}

switch ($Command) {

    # ------------------------------------------------------------------ new --
    'new' {
        if (-not $Slug) { Write-Result 'ERROR: -Slug is required'; exit 2 }
        if (-not (Test-Slug $Slug)) {
            Write-Result "REFUSED: '$Slug' is not a kebab-case slug (a-z, 0-9, hyphens)"
            exit 1
        }
        $branch = Get-SlugBranch $Slug
        $dest = Join-Path $WorktreeRoot $Slug

        if (Test-Path $dest) {
            Write-Result "REFUSED: $dest already exists. Use 'list' to see it, or 'done -Slug $Slug' to remove it."
            exit 1
        }
        $existing = Invoke-GitIn $Repo @('rev-parse', '--verify', '--quiet', "refs/heads/$branch")
        if ($existing.Ok) {
            Write-Result "REFUSED: branch $branch already exists. Pick another slug, or clean up the old feature first."
            exit 1
        }

        if ($NoFetch) {
            Write-Result "NOTE: -NoFetch was used; the fork point is the local $Remote/$Trunk, which may be stale."
        }
        else {
            $f = Invoke-GitIn $Repo @('fetch', $Remote, $Trunk)
            if (-not $f.Ok) {
                Write-Result "REFUSED: git fetch $Remote $Trunk failed: $($f.Text)"
                exit 1
            }
        }

        $base = "$Remote/$Trunk"
        $baseOk = Invoke-GitIn $Repo @('rev-parse', '--verify', '--quiet', $base)
        if (-not $baseOk.Ok) {
            Write-Result "REFUSED: no such ref: $base"
            exit 1
        }

        if (-not (Test-Path $WorktreeRoot)) {
            New-Item -ItemType Directory -Path $WorktreeRoot -Force | Out-Null
        }
        $add = Invoke-GitIn $Repo @('worktree', 'add', '-b', $branch, $dest, $base)
        if (-not $add.Ok) {
            Write-Result "ERROR: git worktree add failed: $($add.Text)"
            exit 2
        }
        $sha = (Invoke-GitIn $dest @('rev-parse', '--short', 'HEAD')).Text
        Write-Result "CREATED $dest"
        Write-Result "  branch $branch"
        Write-Result "  forked from $base at $sha"
        Write-Result "  next: work there, then: ship-feature.ps1 pr -Slug $Slug -Title `"...`""
        exit 0
    }

    # ----------------------------------------------------------------- list --
    'list' {
        $wts = Get-FamilyWorktrees
        $rows = @()
        foreach ($w in $wts) {
            $slug = Split-Path -Leaf $w.Path
            $st = Invoke-GitIn $w.Path @('status', '--porcelain')
            $dirtyCount = @(($st.Text -split "`r?`n") | Where-Object { $_.Trim() }).Count
            $unpushed = '-'
            $up = Invoke-GitIn $w.Path @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
            if ($up.Ok) {
                $c = Invoke-GitIn $w.Path @('rev-list', '--count', "$($up.Text)..HEAD")
                if ($c.Ok) { $unpushed = $c.Text }
            }
            else { $unpushed = 'no-upstream' }
            $ahead = '-'
            $a = Invoke-GitIn $w.Path @('rev-list', '--count', "$Remote/$Trunk..HEAD")
            if ($a.Ok) { $ahead = $a.Text }
            $pr = Get-PrForBranch $w.Branch
            $rows += [pscustomobject]@{
                Slug     = $slug
                Branch   = $w.Branch
                Ahead    = $ahead
                Dirty    = $dirtyCount
                Unpushed = $unpushed
                Pr       = if ($pr) { "#$($pr.number) $($pr.state)" } else { '-' }
                PrUrl    = if ($pr) { $pr.url } else { '' }
                Path     = $w.Path
            }
        }
        if ($Json) {
            # Always an array, even for one row: a caller indexing [0] on an
            # unrolled single object gets a character, which is the PS 5.1 trap
            # this whole family keeps stepping in.
            ConvertTo-Json @($rows) -Depth 4
        }
        elseif ($rows.Count -eq 0) {
            Write-Result "no feature worktrees under $WorktreeRoot"
        }
        else {
            $rendered = $rows |
            Select-Object Slug, Branch, Ahead, Dirty, Unpushed, Pr |
            Format-Table -AutoSize | Out-String -Width 200
            Write-Host $rendered.TrimEnd()
            Write-Host ""
            Write-Result ("{0} feature worktree(s) under {1}" -f $rows.Count, $WorktreeRoot)
        }
        exit 0
    }

    # ------------------------------------------------------------------- pr --
    'pr' {
        if (-not $Slug) { Write-Result 'ERROR: -Slug is required'; exit 2 }
        $dest = Join-Path $WorktreeRoot $Slug
        if (-not (Test-Path $dest)) {
            Write-Result "REFUSED: no worktree at $dest. Create it with 'new -Slug $Slug'."
            exit 1
        }
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if (-not $gh) { Write-Result 'ERROR: gh CLI not installed'; exit 2 }

        $branch = (Invoke-GitIn $dest @('rev-parse', '--abbrev-ref', 'HEAD')).Text
        $st = Invoke-GitIn $dest @('status', '--porcelain')
        $dirty = @(($st.Text -split "`r?`n") | Where-Object { $_.Trim() })
        if ($dirty.Count -gt 0) {
            Write-Result ("REFUSED: {0} uncommitted path(s) in {1}. Commit them; a PR must describe committed work." -f $dirty.Count, $dest)
            exit 1
        }
        $ahead = Invoke-GitIn $dest @('rev-list', '--count', "$Remote/$Trunk..HEAD")
        if ($ahead.Ok -and $ahead.Text -eq '0') {
            Write-Result "REFUSED: $branch has no commits of its own over $Remote/$Trunk. There is nothing to propose."
            exit 1
        }

        $push = Invoke-GitIn $dest @('push', '-u', $Remote, $branch)
        if (-not $push.Ok) {
            Write-Result "ERROR: push failed: $($push.Text)"
            exit 2
        }

        $existing = Get-PrForBranch $branch
        if ($existing -and $existing.state -eq 'OPEN') {
            Write-Result "PR ALREADY OPEN #$($existing.number): $($existing.url)"
            Write-Result "  pushed $($ahead.Text) commit(s); the PR updates itself."
            exit 0
        }

        if (-not $Title) {
            Write-Result 'ERROR: -Title is required to open a new PR'
            exit 2
        }
        $rest = @('--base', $Trunk, '--head', $branch, '--title', $Title)
        if ($Body) { $rest += @('--body', $Body) } else { $rest += @('--body', '') }
        if ($Draft) { $rest += '--draft' }
        $created = Invoke-GhPr 'create' $rest
        if (-not $created.Ok) {
            Write-Result "ERROR: opening the pull request failed: $($created.Text)"
            exit 2
        }
        $url = (($created.Text) -split "`r?`n" | Where-Object { $_ -match '^https?://' } | Select-Object -First 1)
        Write-Result "PR OPENED $($url.Trim())"
        Write-Result "  base $Trunk  head $branch  repo $ForkRepo"
        exit 0
    }

    # ----------------------------------------------------------------- done --
    'done' {
        if (-not $Slug) { Write-Result 'ERROR: -Slug is required'; exit 2 }
        $dest = Join-Path $WorktreeRoot $Slug
        if (-not (Test-Path $dest)) {
            Write-Result "REFUSED: no worktree at $dest"
            exit 1
        }
        $branch = (Invoke-GitIn $dest @('rev-parse', '--abbrev-ref', 'HEAD')).Text

        if (-not $Force) {
            $st = Invoke-GitIn $dest @('status', '--porcelain')
            $dirty = @(($st.Text -split "`r?`n") | Where-Object { $_.Trim() })
            if ($dirty.Count -gt 0) {
                Write-Result ("REFUSED: {0} uncommitted path(s) in {1}. Commit or revert them, or pass -Force to discard." -f $dirty.Count, $dest)
                exit 1
            }
            $up = Invoke-GitIn $dest @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
            if ($up.Ok) {
                $c = Invoke-GitIn $dest @('rev-list', '--count', "$($up.Text)..HEAD")
                if ($c.Ok -and $c.Text -ne '0') {
                    Write-Result "REFUSED: $($c.Text) commit(s) in $branch are not pushed. Push them, or pass -Force to discard."
                    exit 1
                }
            }
            else {
                $ahead = Invoke-GitIn $dest @('rev-list', '--count', "$Remote/$Trunk..HEAD")
                if ($ahead.Ok -and $ahead.Text -ne '0') {
                    Write-Result "REFUSED: $branch has $($ahead.Text) commit(s) and was never pushed. Push them, or pass -Force to discard."
                    exit 1
                }
            }
            $pr = Get-PrForBranch $branch
            if ($pr -and $pr.state -eq 'OPEN') {
                Write-Result "REFUSED: PR #$($pr.number) is still OPEN ($($pr.url)). Merge or close it, or pass -Force."
                exit 1
            }
        }
        else {
            Write-Result "NOTE: -Force was used; dirty, unpushed and open-PR checks were skipped."
        }

        $rm = Invoke-GitIn $Repo @('worktree', 'remove', $dest, '--force')
        if (-not $rm.Ok) {
            Write-Result "ERROR: git worktree remove failed: $($rm.Text)"
            exit 2
        }
        # The branch goes with it. -D rather than -d: the merge happened on the
        # remote (a squash or a merge commit), so the local ref is very often
        # not an ancestor of the local trunk and -d would refuse a branch that
        # is genuinely shipped.
        $del = Invoke-GitIn $Repo @('branch', '-D', $branch)
        if ($del.Ok) { Write-Result "REMOVED $dest and branch $branch" }
        else { Write-Result "REMOVED $dest; branch $branch could not be deleted: $($del.Text)" }
        exit 0
    }
}
