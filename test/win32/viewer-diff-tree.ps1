# T464 acceptance: the diff viewer pane's file-tree side panel on win32.
#
# A diff that touches thirty files is one very long scroll without a way to
# jump between them. Mac puts a file tree down the side of the pane, on the
# SAME card its table of contents uses. This asserts the Windows twin:
#
#   - opening a `git-diff:<sha>` pane builds a TREE, not a flat list: the
#     changed files nested under folder rows, with a chain of single-child
#     directories collapsed into one row.
#   - a `git-status:` pane groups its files under working-tree SECTION headers
#     (Staged / Changes / Untracked), which a commit's diff has none of.
#   - the card follows the PANE's width live: a gutter beside the document when
#     the pane is wide, a floating overlay when it is narrow.
#   - clicking a FILE row opens that file's patch (the pane shows one patch at
#     a time, so selecting and opening are one act).
#   - clicking a FOLDER row shuts it, and its files leave the list; clicking it
#     again brings them back.
#
# THE ORACLE, and why it is the app's own stderr: the panel is a child window
# whose contents `+list --json` cannot see, and this suite runs on a background
# desktop where nothing can photograph one (lib\TestDesktop.ps1's capture
# limit). So `ViewerPane.rebuildDiffTree` logs one line per rebuild --
#
#   viewer tree pane=<id> rows=N files=N folders=N sections=N shut=N layout=<mode> selected=<path>
#
# -- and that line is what every shape assertion below reads. The card's
# EXISTENCE and its containment inside the pane are asserted through the window
# tree (`GhozttyViewerTOC`), which is visible from outside; the file a click
# opened is read from T463's own `viewer diff pane=<id> file=<path>` line.
#
# POSITIVE CONTROLS: section A asserts the tree is non-trivial (folders exist,
# a chain collapsed) before anything else, so a green run cannot be one where
# the panel is empty or absent. The scratch repository is built and committed
# here, so every expected count is known exactly rather than read back from the
# feature under test.
#
# Runs on the BACKGROUND test desktop, so it never steals the user's
# foreground. Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-diff-tree.ps1
#
# -NegativeControl inverts section A's "the tree has folder rows" assertion and
# MUST fail with exactly ONE failure, so a run that scores anything else is
# measuring something other than the tree.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vdt$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type -Namespace VDT -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
'@

function Get-Rect([IntPtr]$h) {
    $r = New-Object VDT.U+RECT
    [void][VDT.U]::GetWindowRect($h, [ref]$r)
    return $r
}
function Rect-Width($r) { return ($r.right - $r.left) }
function Rect-Height($r) { return ($r.bottom - $r.top) }
function Inside($inner, $outer) {
    return ($inner.left -ge $outer.left -and $inner.right -le $outer.right -and
            $inner.top -ge $outer.top -and $inner.bottom -le $outer.bottom)
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
function Wait-Win([string]$target) {
    for ($t = 0; $t -lt 30; $t++) {
        $d = Get-Data
        if ($d) { foreach ($w in $d.windows) { if ($w.target -eq $target) { return $w } } }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

# The GUI's stderr, wrapped by PS 5.1's console width -- so every match below
# runs against whitespace-collapsed text (the viewer-diff.ps1 convention).
function Get-Log {
    if (-not (Test-Path $script:errlog)) { return '' }
    return ((Get-Content $script:errlog -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ')
}

$treeRe = 'viewer tree pane=(\S+) rows=(\d+) files=(\d+) folders=(\d+) sections=(\d+) shut=(\d+) layout=(\S+) selected=(\S+)'

# The LAST tree line for a pane, as a record. `-After` skips the lines already
# seen, which is what makes a rebuild distinguishable from the state that was
# already on screen.
function Wait-Tree([string]$PaneId, [int]$After = 0, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $hits = @([regex]::Matches((Get-Log), $treeRe)) | Where-Object { $_.Groups[1].Value -eq $PaneId }
        $hits = @($hits)
        if ($hits.Count -gt $After) {
            $m = $hits[$hits.Count - 1]
            return [pscustomobject]@{
                Rows     = [int]$m.Groups[2].Value
                Files    = [int]$m.Groups[3].Value
                Folders  = [int]$m.Groups[4].Value
                Sections = [int]$m.Groups[5].Value
                Shut     = [int]$m.Groups[6].Value
                Layout   = $m.Groups[7].Value
                Selected = $m.Groups[8].Value
                Count    = $hits.Count
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Count-Tree([string]$PaneId) {
    return @(@([regex]::Matches((Get-Log), $treeRe)) | Where-Object { $_.Groups[1].Value -eq $PaneId }).Count
}

# The side panel's presentation, logged once per CHANGE by `logPanelLayout`.
$panelRe = 'viewer panel pane=(\S+) layout=(\S+) kind=(\S+) items=(\d+)'

function Get-Panel([string]$PaneId) {
    $hits = @(@([regex]::Matches((Get-Log), $panelRe)) | Where-Object { $_.Groups[1].Value -eq $PaneId })
    if ($hits.Count -eq 0) { return $null }
    $m = $hits[$hits.Count - 1]
    return [pscustomobject]@{
        Layout = $m.Groups[2].Value
        Kind   = $m.Groups[3].Value
        Items  = [int]$m.Groups[4].Value
        Count  = $hits.Count
    }
}

function Wait-Panel([string]$PaneId, [string]$Layout, [int]$TimeoutMs = 8000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Panel $PaneId
        if ($p -and $p.Layout -eq $Layout) { return $p }
        Start-Sleep -Milliseconds 250
    }
    return (Get-Panel $PaneId)
}

# The file whose patch the pane last pushed (T463's own oracle).
function Get-OpenFile([string]$PaneId) {
    $hits = @([regex]::Matches((Get-Log), "viewer diff pane=$PaneId file=(\S+) status="))
    if ($hits.Count -eq 0) { return $null }
    return $hits[$hits.Count - 1].Groups[1].Value
}

# `git.exe`, not `git`: PowerShell resolves a command name against FUNCTIONS
# first and is case-insensitive, so a helper named `Git` calling `& git` calls
# itself.
function Invoke-Git([string[]]$GitArgs) {
    & git.exe @GitArgs 2>&1 | Out-Null
}

# --- the scratch repository ------------------------------------------------
# A shape chosen so every tree behavior has something to bite on: a THREE-deep
# single-child chain (`src/apprt/win32`, which must collapse to one row), a
# second folder beside it, and a file at the root.
$work = Join-Path $env:TEMP ("ghoztty-t464-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:errlog = Join-Path $env:TEMP 'ghoztty-viewer-diff-tree-stderr.log'
Remove-Item $script:errlog -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Path (Join-Path $work 'src\apprt\win32') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $work 'docs') -Force | Out-Null
Set-Content -Path (Join-Path $work 'root.txt') -Value "r1`nr2" -Encoding utf8
Set-Content -Path (Join-Path $work 'src\apprt\win32\alpha.txt') -Value "a1`na2" -Encoding utf8
Set-Content -Path (Join-Path $work 'src\apprt\win32\beta.txt') -Value "b1`nb2" -Encoding utf8
Set-Content -Path (Join-Path $work 'docs\readme.md') -Value "d1`nd2" -Encoding utf8
Invoke-Git @('-C', $work, 'init', '-q')
Invoke-Git @('-C', $work, 'config', 'user.email', 't464@example.com')
Invoke-Git @('-C', $work, 'config', 'user.name', 'T464')
Invoke-Git @('-C', $work, 'add', '-A')
Invoke-Git @('-C', $work, 'commit', '-q', '-m', 'base')
# The commit under test: all four files change, so `git-diff:<sha>` yields four
# committed files in three directories.
Add-Content -Path (Join-Path $work 'root.txt') -Value 'r3'
Add-Content -Path (Join-Path $work 'src\apprt\win32\alpha.txt') -Value 'a3'
Add-Content -Path (Join-Path $work 'src\apprt\win32\beta.txt') -Value 'b3'
Add-Content -Path (Join-Path $work 'docs\readme.md') -Value 'd3'
Invoke-Git @('-C', $work, 'add', '-A')
Invoke-Git @('-C', $work, 'commit', '-q', '-m', 'four files')
$headSha = (& git.exe -C $work rev-parse --short HEAD 2>$null | Out-String).Trim()

# The working tree, for the sections assertion: one unstaged edit, one staged
# add, one untracked file.
Add-Content -Path (Join-Path $work 'docs\readme.md') -Value 'd4'
Set-Content -Path (Join-Path $work 'src\apprt\win32\staged.txt') -Value "s1" -Encoding utf8
Invoke-Git @('-C', $work, 'add', 'src/apprt/win32/staged.txt')
Set-Content -Path (Join-Path $work 'loose.txt') -Value "u1" -Encoding utf8

if (-not $headSha) {
    Write-TestAssertedNothing -Label 'T464 ACCEPTANCE' -Reason "the scratch repository could not be created in $work"
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$launched = @()
$td = New-TestDesktop -Interactive:$Interactive

try {
    $app = Start-OnTestDesktop -Exe $exe -StdErr $script:errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    $launched += $script:GhozttyTestDesktopPids
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    Invoke-Verb @('+new-window', '--target=vdt') | Out-Null
    if (-not (Wait-Win 'vdt')) { Write-Host 'SETUP FAIL: no vdt window'; exit 1 }
    $r = Invoke-Verb @('+split', '--target=vdt', "--view=git-diff:$headSha",
        "--working-directory=$work", '--name=dtree')
    if ($r.Code -ne 0) { Write-Host "SETUP FAIL: +split --view exited $($r.Code): $($r.Out)"; exit 1 }
    Start-Sleep -Seconds 4

    $w = Wait-Win 'vdt'
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    $term = @($leaves | Where-Object { $_.type -ne 'viewer' })
    $view = @($leaves | Where-Object { $_.type -eq 'viewer' })
    if ($term.Count -ne 1 -or $view.Count -ne 1) {
        Write-Host "SETUP FAIL: expected one terminal + one viewer, got $($leaves.Count) leaves"; exit 1
    }
    $paneId = $view[0].id
    if (-not $paneId) { $paneId = $view[0].name }

    $top = [IntPtr]::Zero
    foreach ($t in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        if (@(Get-TestChildWindows -Window ([IntPtr]$t.Hwnd) -Class 'GhozttyViewer').Count -ge 1) {
            $top = [IntPtr]$t.Hwnd
        }
    }
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no window carries a GhozttyViewer'; exit 1 }
    # MAXIMIZE before measuring anything: the gutter layout needs 720 DIP of
    # PANE, and a default-sized window at ratio 20 does not have it. This is
    # setup, not an assertion -- what section B measures is the SWITCH between
    # the two layouts, which needs a window that can reach both sides of it.
    [void](Send-TestSysCommand -Window $top -Command 'maximize')
    Start-Sleep -Milliseconds 1200
    $dpi = [VDT.U]::GetDpiForWindow($top)
    $scale = $dpi / 96.0
    $topRect = Get-Rect $top
    Write-Host ("window dpi={0} scale={1} width={2}px ({3} DIP) pane={4} sha={5}" -f `
        $dpi, $scale, (Rect-Width $topRect), [int]((Rect-Width $topRect) / $scale), $paneId, $headSha)
    if (((Rect-Width $topRect) / $scale) -lt 900) {
        Write-Host "SETUP FAIL: the desktop is too narrow to reach the gutter layout"; exit 1
    }

    function Set-ViewerRatio([int]$leftPercent) {
        $layout = '{"direction":"horizontal","ratio":' + $leftPercent +
            ',"left":{"pane":"' + $term[0].name + '"},"right":{"pane":"' + $view[0].name + '"}}'
        $res = Invoke-Verb @('+rearrange', '--target=vdt', ('--layout=' + ($layout -replace '"', '\"')))
        Start-Sleep -Milliseconds 1500
        return $res
    }

    function Get-TocHwnd {
        foreach ($h in @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')) {
            foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$h.Hwnd) -Class 'GhozttyViewerTOC')) {
                $rr = Get-Rect ([IntPtr]$c.Hwnd)
                if ((Rect-Width $rr) -gt 0) { return [IntPtr]$c.Hwnd }
            }
        }
        return [IntPtr]::Zero
    }

    # -----------------------------------------------------------------------
    # A. The tree, and that it IS a tree.
    #
    # Four files in three directories, one of which is a three-deep chain of
    # single-child folders. A flat list would report folders=0; an uncollapsed
    # tree would report folders=4 (src, apprt, win32, docs). The contract is
    # TWO folder rows -- `src/apprt/win32` and `docs` -- which is the one shape
    # neither mistake produces.
    # -----------------------------------------------------------------------
    [void](Set-ViewerRatio 20)
    $a = Wait-Tree $paneId 0
    Assert ($null -ne $a) 'A: the pane logged a file tree for its diff'
    if ($a) {
        Assert ($a.Files -eq 4) "A: all four changed files are listed (got $($a.Files))"
        $wantFolders = if ($NegativeControl) { 99 } else { 2 }
        Assert ($a.Folders -eq $wantFolders) `
            "A: the chain collapsed to two folder rows, src/apprt/win32 and docs (got $($a.Folders))"
        Assert ($a.Sections -eq 0) "A: a commit's diff has no working-tree sections (got $($a.Sections))"
        Assert ($a.Rows -eq ($a.Files + $a.Folders + $a.Sections)) `
            "A: every row is a file, a folder or a section (rows=$($a.Rows))"
        Assert ($a.Selected -ne '-') "A: a file is open, so the tree has something selected"
    }

    $toc = Get-TocHwnd
    Assert ($toc -ne [IntPtr]::Zero) 'A: the pane shows a side-panel card'
    if ($toc -ne [IntPtr]::Zero) {
        $hostRect = Get-Rect ([IntPtr](@(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')[0].Hwnd))
        Assert (Inside (Get-Rect $toc) $hostRect) 'A: the card is inside the pane'
    }

    # -----------------------------------------------------------------------
    # B. Wide vs narrow: the layout follows the PANE, live.
    #
    # 720 DIP is `viewer_toc_layout.gutter_min_dip`. Above it the card sits in
    # a gutter with the document reflowing beside it; below it the card becomes
    # an overlay behind the nav bar's contents button. Dragging the divider has
    # to move it between the two without re-opening the pane.
    # -----------------------------------------------------------------------
    $wide = Wait-Panel $paneId 'gutter'
    Assert ($null -ne $wide -and $wide.Layout -eq 'gutter') `
        "B: a wide pane puts the card in a gutter (got $(if ($wide) { $wide.Layout } else { 'nothing' }))"
    if ($wide) {
        Assert ($wide.Kind -eq 'files') "B: and the card is listing FILES, not headings (got $($wide.Kind))"
    }

    # The switch follows the pane's width LIVE: dragging the split divider
    # moves the card between the two presentations without re-opening anything.
    [void](Set-ViewerRatio 85)
    $narrow = Wait-Panel $paneId 'compact'
    Assert ($null -ne $narrow -and $narrow.Layout -eq 'compact') `
        "B: dragging the divider narrow floats the card as an overlay (got $(if ($narrow) { $narrow.Layout } else { 'nothing' }))"
    if ($narrow) {
        Assert ($narrow.Items -eq 4) "B: narrowing loses no files (got $($narrow.Items))"
    }
    [void](Set-ViewerRatio 20)
    $back = Wait-Panel $paneId 'gutter'
    Assert ($null -ne $back -and $back.Layout -eq 'gutter') `
        'B: and dragging it wide again puts the card back in the gutter'

    # -----------------------------------------------------------------------
    # C. Clicking rows: a file opens, a folder shuts.
    #
    # The card is an owner-painted window with no controls in it, so a click is
    # a posted WM_LBUTTONUP at a client point -- exactly the message the OS
    # would deliver. Where the rows ARE is not assumed: the list is scanned
    # from the top down until something happens, and WHAT happened is read from
    # the log. That makes the assertion "a click on the list does the right
    # thing" rather than "a click at y=91 does".
    # -----------------------------------------------------------------------
    $toc = Get-TocHwnd
    if ($toc -eq [IntPtr]::Zero) {
        Assert $false 'C: no card to click (skipped the click assertions)'
    } else {
        $tr = Get-Rect $toc
        $cw = Rect-Width $tr
        $ch = Rect-Height $tr
        # SCREEN coordinates: Send-TestMouse converts to the target's client
        # rect itself, so a client-relative x/y would land somewhere else
        # entirely. A third of the way across the card: past the indent,
        # nowhere near the resize handle straddling its right edge.
        $cx = $tr.left + [int]($cw / 3)
        $y0 = $tr.top + 4
        $maxY = $tr.top + [Math]::Min($ch - 4, [int](340 * $scale))
        $step = [Math]::Max(4, [int](4 * $scale))

        $folderHit = $false
        $baseline = Wait-Tree $paneId 0
        $shutFiles = 0
        for ($y = $y0; $y -lt $maxY -and -not $folderHit; $y += $step) {
            $seen = Count-Tree $paneId
            [void](Send-TestMouse -Window $top -Target $toc -X $cx -Y $y -Action 'click' -Client)
            Start-Sleep -Milliseconds 220
            if ((Get-Log) -match 'viewer tree pane=' + $paneId + ' folder=') {
                $t = Wait-Tree $paneId $seen 4000
                if ($t -and $t.Shut -ge 1) {
                    $folderHit = $true
                    $shutFiles = $t.Files
                    $folderY = $y
                }
            }
        }
        Assert $folderHit 'C: clicking a folder row shuts it'
        if ($folderHit) {
            Assert ($shutFiles -lt 4) `
                "C: a shut folder takes its files out of the list (got $shutFiles of 4)"
            $seen = Count-Tree $paneId
            [void](Send-TestMouse -Window $top -Target $toc -X $cx -Y $folderY -Action 'click' -Client)
            $t = Wait-Tree $paneId $seen 5000
            Assert ($null -ne $t -and $t.Shut -eq 0 -and $t.Files -eq 4) `
                "C: clicking it again brings them back (shut=$($t.Shut) files=$($t.Files))"
        }

        # And a FILE row. The scan steps in small increments, so several
        # clicks land inside the same row -- and a folder row would otherwise
        # be shut and re-shut all the way down the list. A click that toggles
        # a folder is UNDONE immediately, so the tree the scan walks stays the
        # one section A measured.
        $openBefore = Get-OpenFile $paneId
        $fileHit = $false
        for ($y = $y0; $y -lt $maxY -and -not $fileHit; $y += $step) {
            $folders = @([regex]::Matches((Get-Log), 'viewer tree pane=' + $paneId + ' folder=')).Count
            [void](Send-TestMouse -Window $top -Target $toc -X $cx -Y $y -Action 'click' -Client)
            Start-Sleep -Milliseconds 260
            $after = @([regex]::Matches((Get-Log), 'viewer tree pane=' + $paneId + ' folder=')).Count
            if ($after -gt $folders) {
                # A folder: put it back the way it was and carry on.
                [void](Send-TestMouse -Window $top -Target $toc -X $cx -Y $y -Action 'click' -Client)
                Start-Sleep -Milliseconds 260
                continue
            }
            $now = Get-OpenFile $paneId
            if ($now -and $openBefore -and $now -ne $openBefore) {
                $fileHit = $true
                Write-Host "      clicked a file row at y=$y -> $now (was $openBefore)"
            }
        }
        Assert $fileHit 'C: clicking a file row opens that file'
    }

    # -----------------------------------------------------------------------
    # D. A working-tree diff groups its files under section headers.
    #
    # `git-status:` is the one spec with more than one origin, and the sections
    # are how "staged" is told from "not staged" without reading the badges.
    # A commit's diff (section A) has none, which is the pair that makes this
    # an assertion about ORIGINS rather than about a decoration.
    # -----------------------------------------------------------------------
    $r = Invoke-Verb @('+split', '--target=vdt', '--view=git-status:',
        "--working-directory=$work", '--name=dstatus')
    Assert ($r.Code -eq 0) "D: +split --view=git-status: succeeded ($($r.Out.Trim()))"
    Start-Sleep -Seconds 4
    $w2 = Wait-Win 'vdt'
    $statusLeaf = @(Get-Leaves $w2.tabs[0].splits) | Where-Object { $_.name -eq 'dstatus' }
    if (-not $statusLeaf) {
        Assert $false 'D: the git-status pane never appeared'
    } else {
        $sid = $statusLeaf.id
        if (-not $sid) { $sid = $statusLeaf.name }
        $d = Wait-Tree $sid 0
        Assert ($null -ne $d) 'D: the working-tree pane logged a file tree'
        if ($d) {
            Assert ($d.Sections -ge 2) `
                "D: staged, unstaged and untracked get their own headers (got $($d.Sections))"
            Assert ($d.Files -ge 3) "D: every changed file is listed (got $($d.Files))"
        }
    }

    # -----------------------------------------------------------------------
    # E. The card knows WHAT it is listing.
    #
    # One card serves both subjects, so the failure worth guarding is a
    # document pane that shows a diff's file tree (or the other way round). A
    # markdown pane opened beside the diff must report `kind=contents`, and the
    # diff pane must still report `kind=files`.
    # -----------------------------------------------------------------------
    $md = Join-Path $repo 'CLAUDE.md'
    $r = Invoke-Verb @('+split', '--target=vdt', "--view=$md", '--name=dmd')
    Assert ($r.Code -eq 0) "E: +split --view=<markdown> succeeded ($($r.Out.Trim()))"
    Start-Sleep -Seconds 4
    $mdLeaf = @(Get-Leaves (Wait-Win 'vdt').tabs[0].splits) | Where-Object { $_.name -eq 'dmd' }
    if (-not $mdLeaf) {
        Assert $false 'E: the markdown pane never appeared'
    } else {
        $mid = $mdLeaf.id
        if (-not $mid) { $mid = $mdLeaf.name }
        $mp = Get-Panel $mid
        Assert ($null -ne $mp) 'E: the markdown pane showed a side-panel card'
        if ($mp) {
            Assert ($mp.Kind -eq 'contents') `
                "E: a document's card lists its CONTENTS, not a diff's files (got $($mp.Kind))"
        }
        Assert ((Count-Tree $mid) -eq 0) 'E: and a markdown pane never builds a file tree'
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI survived all of it'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) `
        'the GUI never became visible on the interactive desktop'
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Write-Host ''
    [void](Invoke-Verb @('+close', '--target=vdt'))
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop $td
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) `
    "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due. A negative-control run is red by construction, so it
# never stamps.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-diff-tree -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T464 ACCEPTANCE' -Pass $script:pass -Fail $script:fail
