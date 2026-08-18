# T463 acceptance: git diff viewer panes on win32.
#
# `--view=git-status:` and `--view=git-diff:<revspec>` open a viewer pane that
# RENDERS a diff. What is asserted:
#
#   - both schemes open a pane whose leaf is `"type":"viewer"`, whose `url` is
#     the CANONICAL spec (`git-status` typed without its colon comes back as
#     `git-status:`), and whose title is what the diff SHOWS ("Working tree",
#     the revspec) rather than the scheme that produced it.
#   - the repository is resolved from `--working-directory`, and the file list
#     git produced reaches the page: staged, unstaged and untracked kept apart,
#     with the right counts.
#   - a bad revspec is REPORTED, not swallowed as "no changes" -- the failure
#     this task exists for, since `git diff nosuchref` prints nothing and fails.
#   - a directory in no repository renders the explanatory card.
#   - a `git-status:` pane picks up a change in the working tree on its own
#     (the 2s poll), and `+reload` re-runs the diff.
#
# THE ORACLE, and why it is the app's own stderr: `+list --json` cannot see
# inside a WebView2 and the suite runs on a background desktop where nothing
# can screenshot one, so "this pane really rendered this diff" has to be
# readable in the GUI's log -- the same rule the worktree probe's acceptance
# (T633) follows. `ViewerPane.applyDiffListing` logs one line per push:
#
#   viewer diff pane=<id> spec=<location> repo=<path> files=N +A -D status=<...>
#   viewer diff pane=<id> file=<path> status=<letter> patch=<bytes>
#
# and those two lines are what every content assertion below reads. The pane's
# IDENTITY (type, url, title) is asserted through `+list --json`, which is the
# half that is visible from outside.
#
# POSITIVE CONTROLS: every "the diff failed" assertion is paired with a diff in
# the same repository that must SUCCEED, so a green run cannot be one where the
# whole feature is dead. The scratch repository is built and committed here, so
# the expected counts are known exactly rather than read back from the same
# command under test.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never steals
# the user's foreground. Only touches ghoztty processes running from this repo's
# zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-diff.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = '-vdtest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# A PIPE, not a `>` redirect: `ghoztty +verb > file` from PowerShell writes zero
# bytes against the GUI-subsystem exe (T245).
function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-Leaf($target, $name) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) {
        if ($w.target -ne $target) { continue }
        foreach ($leaf in @(Get-Leaves $w.tabs[0].splits)) {
            if (-not $name -or $leaf.name -eq $name) { return $leaf }
        }
    }
    return $null
}

function Wait-Leaf($target, $name) {
    for ($t = 0; $t -lt 30; $t++) {
        $leaf = Get-Leaf $target $name
        if ($leaf) { return $leaf }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

# The GUI's stderr, wrapped by PS 5.1's console width -- so every match below
# runs against whitespace-collapsed text (the viewer-panes.ps1 convention).
function Get-Log {
    if (-not (Test-Path $script:errlog)) { return '' }
    return ((Get-Content $script:errlog -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ')
}

# Wait for a diff LISTING line for one pane, and return it. `-After` skips the
# lines already seen, which is what makes a re-render (a poll, a reload)
# distinguishable from the render that was already on screen.
function Wait-DiffLine([string]$PaneId, [int]$After = 0, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        # The status text has spaces in it ("Not a git repository"), so the
        # match ends at the next LOG PREFIX rather than at whitespace -- the
        # lines were collapsed onto one by `Get-Log`.
        $hits = @([regex]::Matches((Get-Log), "viewer diff pane=$PaneId spec=\S+ repo=\S* files=\d+ \+\d+ -\d+ status=.*?(?= (?:info|warn|debug|err)\(|$)"))
        if ($hits.Count -gt $After) { return $hits[$hits.Count - 1].Value }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Count-DiffLines([string]$PaneId) {
    return @([regex]::Matches((Get-Log), "viewer diff pane=$PaneId spec=")).Count
}

function Wait-DiffFileLine([string]$PaneId, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $hits = @([regex]::Matches((Get-Log), "viewer diff pane=$PaneId file=(\S+) status=(\S+) patch=(\d+)"))
        if ($hits.Count -gt 0) { return $hits[$hits.Count - 1] }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

# `git.exe`, not `git`: PowerShell resolves a command name against FUNCTIONS
# first and is case-insensitive, so a helper named `Git` calling `& git` calls
# itself. (It fails silently too — `$LASTEXITCODE` simply stays empty, which
# reads exactly like a git that is not installed.)
function Invoke-Git([string[]]$GitArgs) {
    & git.exe @GitArgs 2>&1 | Out-Null
}

# --- the scratch repository ------------------------------------------------
# Built here so every count below is KNOWN rather than read back from the same
# command under test: one committed file, one tracked file modified but not
# staged, one file staged, and one untracked.
$work = Join-Path $env:TEMP ("ghoztty-t463-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:errlog = Join-Path $env:TEMP 'ghoztty-viewer-diff-stderr.log'
Remove-Item $script:errlog -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Content -Path (Join-Path $work 'kept.txt') -Value "one`ntwo`nthree" -Encoding utf8
Set-Content -Path (Join-Path $work 'edited.txt') -Value "alpha`nbeta" -Encoding utf8
Invoke-Git @('-C', $work, 'init', '-q')
Invoke-Git @('-C', $work, 'config', 'user.email', 't463@example.com')
Invoke-Git @('-C', $work, 'config', 'user.name', 'T463')
Invoke-Git @('-C', $work, 'add', '-A')
Invoke-Git @('-C', $work, 'commit', '-q', '-m', 'base')
$headSha = (& git.exe -C $work rev-parse --short HEAD 2>$null | Out-String).Trim()

# unstaged: a tracked file gains a line.
Add-Content -Path (Join-Path $work 'edited.txt') -Value 'gamma'
# staged: a brand new file, added to the index.
Set-Content -Path (Join-Path $work 'staged.txt') -Value "s1`ns2" -Encoding utf8
Invoke-Git @('-C', $work, 'add', 'staged.txt')
# untracked: never added.
Set-Content -Path (Join-Path $work 'loose.txt') -Value "u1`nu2`nu3" -Encoding utf8

if (-not $headSha) {
    Write-TestAssertedNothing -Label 'T463 ACCEPTANCE' -Reason "the scratch repository could not be created in $work"
}

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # Session persistence OFF so the run starts from a BLANK layout (T158): a
    # previous run's manifest would restore its own `vd` window and every
    # `--target=vd` would idempotently focus THAT.
    $app = Start-OnTestDesktop -Exe $exe -StdErr $script:errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Label 'T463 ACCEPTANCE' -Reason 'the GUI died at launch'
    }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Label 'T463 ACCEPTANCE' -Reason 'no GhozttyWindow after launch'
    }

    # --- 1. CONTROL: a plain viewer still opens ------------------------------
    # Without this, every "the diff pane rendered" assertion below could be
    # failing for a reason that has nothing to do with diffs.
    $r = Invoke-Verb @('+new-window', '--target=vdctl', '--view=about:blank')
    Assert ($r.Code -eq 0) "CONTROL: +new-window --view=about:blank exits 0 (got $($r.Code))"
    $ctl = Wait-Leaf 'vdctl' $null
    Assert ($null -ne $ctl) 'CONTROL: a plain viewer pane exists'

    # --- 2. --view=git-status: opens a diff pane -----------------------------
    # `git-status` WITHOUT its colon, so the canonicalization is under test too.
    $r = Invoke-Verb @('+new-window', '--target=vd', "--working-directory=$work", '--view=git-status')
    Assert ($r.Code -eq 0) "+new-window --view=git-status exits 0 (got $($r.Code))"
    $leaf = Wait-Leaf 'vd' $null
    Assert ($null -ne $leaf) 'a pane was created for git-status'
    if ($leaf) {
        Assert ($leaf.type -eq 'viewer') "its leaf reports type=viewer (got '$($leaf.type)')"
        Assert ($leaf.url -eq 'git-status:') "+list --json reports the CANONICAL url (got '$($leaf.url)')"
        Assert ($leaf.title -eq 'Working tree') "the pane is titled by what it shows (got '$($leaf.title)')"

        # The listing reached the page: three files, one per section, with the
        # counts this script wrote.
        $line = Wait-DiffLine $leaf.id
        Assert ($null -ne $line) 'the pane pushed a diff listing to the page'
        if ($line) {
            Assert ($line -match 'files=3') "the listing counts 3 files - staged, unstaged and untracked (got '$line')"
            Assert ($line -match 'status=ok') "the listing reports no failure (got '$line')"
            $wantRepo = [regex]::Escape($work)
            Assert ($line -match "repo=$wantRepo") "the repository came from --working-directory (got '$line')"
            # +1 unstaged, +2 staged, +3 untracked: the untracked count is the
            # file's own line count, which only a READ of the file can produce.
            Assert ($line -match '\+6 -0') "the listing sums the per-file counts (got '$line')"
        }

        # ...and a FILE's patch reached it too, which is the half a listing
        # alone does not prove.
        $fileLine = Wait-DiffFileLine $leaf.id
        Assert ($null -ne $fileLine) 'the pane pushed a file patch to the page'
        if ($fileLine) {
            Assert ([int]$fileLine.Groups[3].Value -gt 0) `
                "the patch has bytes in it (got $($fileLine.Groups[3].Value))"
        }
    }

    # --- 3. --view=git-diff:<sha> renders one commit -------------------------
    $r = Invoke-Verb @('+split', '--target=vd', '--name=vdcommit', "--working-directory=$work", "--view=git-diff:$headSha")
    Assert ($r.Code -eq 0) "+split --view=git-diff:<sha> exits 0 (got $($r.Code))"
    $commitLeaf = Wait-Leaf 'vd' 'vdcommit'
    Assert ($null -ne $commitLeaf) 'a pane was created for the commit diff'
    if ($commitLeaf) {
        Assert ($commitLeaf.url -eq "git-diff:$headSha") "its url is the spec (got '$($commitLeaf.url)')"
        Assert ($commitLeaf.title -eq $headSha) "its title is the revspec (got '$($commitLeaf.title)')"
        $line = Wait-DiffLine $commitLeaf.id
        Assert ($null -ne $line) 'the commit pane pushed a listing'
        if ($line) {
            # The base commit added exactly the two files this script wrote.
            Assert ($line -match 'files=2') "one commit's own changes are 2 files (got '$line')"
            Assert ($line -match 'status=ok') "the commit listing reports no failure (got '$line')"
        }
    }

    # --- 4. a bad revspec is REPORTED ---------------------------------------
    # The defect this task exists for: `git diff nosuchref..HEAD` prints nothing
    # and exits nonzero, and reading that as "no changes" is a swallowed error.
    $r = Invoke-Verb @('+split', '--target=vd', '--name=vdbad', "--working-directory=$work", '--view=git-diff:no-such-ref-here..HEAD')
    Assert ($r.Code -eq 0) "+split with a bad revspec still opens a pane (got $($r.Code))"
    $badLeaf = Wait-Leaf 'vd' 'vdbad'
    Assert ($null -ne $badLeaf) 'a pane was created for the bad revspec'
    if ($badLeaf) {
        $line = Wait-DiffLine $badLeaf.id
        Assert ($null -ne $line) 'the bad-revspec pane pushed a listing'
        if ($line) {
            Assert ($line -match 'status=git could not produce this diff') `
                "a bad revspec is named, not swallowed (got '$line')"
            Assert ($line -notmatch 'status=ok') 'a bad revspec is NOT reported as a clean diff'
        }
    }

    # --- 5. a directory in no repository says so -----------------------------
    $r = Invoke-Verb @('+split', '--target=vd', '--name=vdnorepo', "--working-directory=$env:TEMP", '--view=git-status:')
    Assert ($r.Code -eq 0) "+split outside a repo still opens a pane (got $($r.Code))"
    $noRepoLeaf = Wait-Leaf 'vd' 'vdnorepo'
    Assert ($null -ne $noRepoLeaf) 'a pane was created outside a repository'
    if ($noRepoLeaf) {
        $line = Wait-DiffLine $noRepoLeaf.id
        Assert ($null -ne $line) 'the no-repo pane pushed a listing'
        if ($line) {
            Assert ($line -match 'status=Not a git repository') `
                "a directory in no working tree is named (got '$line')"
        }
    }

    # --- 6. a status pane follows the working tree ---------------------------
    # The poll, and the reason it must not redraw when nothing moved: the count
    # before is taken AFTER the pane settled, so a pane that re-pushed every
    # two seconds would fail the "quiet" assertion below.
    if ($leaf) {
        Start-Sleep -Seconds 5
        $quiet = Count-DiffLines $leaf.id
        Start-Sleep -Seconds 5
        $stillQuiet = Count-DiffLines $leaf.id
        Assert ($stillQuiet -eq $quiet) `
            "an unchanged working tree is not re-pushed every poll ($quiet -> $stillQuiet)"

        Set-Content -Path (Join-Path $work 'fresh.txt') -Value "n1" -Encoding utf8
        $line = Wait-DiffLine $leaf.id -After $stillQuiet
        Assert ($null -ne $line) 'a new file in the working tree reaches the pane on its own'
        if ($line) {
            Assert ($line -match 'files=4') "the poll picked up the fourth file (got '$line')"
        }
    }

    # --- 7. +reload re-runs the diff ----------------------------------------
    if ($commitLeaf) {
        $before = Count-DiffLines $commitLeaf.id
        $r = Invoke-Verb @('+reload', '--target=vdcommit')
        Assert ($r.Code -eq 0) "+reload on a diff pane exits 0 (got $($r.Code))"
        $line = Wait-DiffLine $commitLeaf.id -After $before
        Assert ($null -ne $line) '+reload re-ran the diff (a fresh listing was pushed)'
    }

    # --- 8. the app survived all of it --------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
Write-TestVerdict -Label 'T463 ACCEPTANCE' -Pass $script:pass -Fail $script:fail
