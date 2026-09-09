# T646 acceptance: the thumbnail carousel under the viewer's feedback composer.
#
# What is asserted, in the shape the task's validation criteria ask for:
#
#   A. An empty composer has NO carousel at all -- no row, no gap, nothing
#      logged. This is the state the geometry says costs zero pixels, and it is
#      also the state every composer opens in.
#   B. Paste two pictures and BOTH thumbnails appear: the strip reports two
#      tiles, sized and placed inside the band.
#   C. Clicking a thumbnail selects its chip in the composer. Proved twice --
#      the app names the chip's character range, and a single Backspace right
#      after the click removes that whole chip, which only a real selection
#      does.
#   D. Deleting a chip takes its thumbnail with it: the strip drops to one tile
#      and the survivor is the OTHER picture, keeping its number (#2, never
#      renumbered to #1).
#   E. Emptying the composer empties the strip, and the row disappears again.
#   F. (T668) A strip longer than the band SAYS so: the end with pictures past
#      it carries a cue, clicking that cue pages the ribbon that way, and the
#      cue at an end with nothing behind it is gone.
#   G. (T668) The keyboard reaches a picture that is off the edge: Tab stops on
#      the strip, Home/End/arrows walk it and scroll it, and Enter selects that
#      picture's chip -- the same observable outcome a click has in C.
#   H. (T668) Widened past the whole ribbon, neither end shows a cue.
#
# ORACLES. This runs on the BACKGROUND test desktop, where CopyFromScreen and
# SendInput are dead (T233), so nothing here can look at painted pixels. Two
# readable things stand in:
#
#   - the composer's own carousel report on stderr, which names the tile count,
#     the scroll offset, the ringed tile AND the strip's geometry in the band's
#     client coordinates -- the geometry is there so this script can point a
#     click at a tile rather than re-deriving its position from design-system
#     constants and getting it subtly wrong at 1.25 scaling;
#   - the RichEdit's own text (WM_GETTEXT), which is what the user sees.
#
# Ctrl+V is sent with Send-TestViewerChord rather than Send-TestKeys: the
# composer's interception asks the app's own GetKeyState for the modifier, and
# only the attaching variant arranges that.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-feedback-carousel.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-fbcar$PID"

# The chip oracle below is the RichEdit's own text, so this suite pins itself to
# the RichEdit surface (T1102). See lib\ComposerSurface.ps1 for why asking is not
# enough and the run also PROVES which surface it got.
. (Join-Path $PSScriptRoot 'lib\ComposerSurface.ps1')
Set-ComposerSurface 'richedit'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

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

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-OnlyPaneId($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0].id
}

function Get-ViewerHost($appPid) {
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
            return [pscustomobject]@{ Top = [IntPtr]$top.Hwnd; Pane = [IntPtr]$h.Hwnd }
        }
    }
    return $null
}

function Get-ChromeChild($paneHwnd, [string]$Class) {
    $c = @(Get-TestChildWindows -Window $paneHwnd -Class $Class)
    if ($c.Count -lt 1) { return $null }
    return [IntPtr]$c[0].Hwnd
}

function Wait-WorktreeShown($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer worktree pane=$([regex]::Escape($paneId)) feedback=(\w+)") {
                if ($Matches[1] -eq 'shown') { return $true }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Wait-FeedbackOpen($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        $open = $null
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) open=(\w+) bar_h=(\d+)") {
                $open = ($Matches[1] -eq 'true')
            }
        }
        if ($open) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# The composer's LAST carousel report. Everything the strip knows about itself.
function Get-Carousel($errlog, $paneId) {
    $hit = $null
    $pat = "viewer feedback pane=$([regex]::Escape($paneId)) carousel=(\w+) tiles=(\d+) " +
           "scroll=(-?\d+) selected=(-?\d+) left=(-?\d+) top=(-?\d+) thumb=(\d+) stride=(\d+)" +
           " view=(-?\d+) max=(-?\d+) cue=(\w+) focus=(-?\d+)"
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match $pat) {
            $hit = [pscustomobject]@{
                What     = $Matches[1]
                Tiles    = [int]$Matches[2]
                Scroll   = [int]$Matches[3]
                Selected = [int]$Matches[4]
                Left     = [int]$Matches[5]
                Top      = [int]$Matches[6]
                Thumb    = [int]$Matches[7]
                Stride   = [int]$Matches[8]
                View     = [int]$Matches[9]
                Max      = [int]$Matches[10]
                Cue      = $Matches[11]
                Focus    = [int]$Matches[12]
            }
        }
    }
    return $hit
}

# The last carousel report satisfying $Test -- the T668 arms wait on the cue
# and the keyboard ring rather than on a tile count.
function Wait-CarouselWhere($errlog, $paneId, [scriptblock]$Test) {
    for ($t = 0; $t -lt 40; $t++) {
        $c = Get-Carousel $errlog $paneId
        if ($c -and (& $Test $c)) { return $c }
        Start-Sleep -Milliseconds 250
    }
    return (Get-Carousel $errlog $paneId)
}

function Wait-Carousel($errlog, $paneId, [int]$Tiles) {
    for ($t = 0; $t -lt 40; $t++) {
        $c = Get-Carousel $errlog $paneId
        if ($c -and $c.Tiles -eq $Tiles) { return $c }
        Start-Sleep -Milliseconds 250
    }
    return (Get-Carousel $errlog $paneId)
}

# The composer's LAST reported image attach: `image=#N bytes=B live=L`.
function Wait-Image($errlog, $paneId, [int]$Number) {
    for ($t = 0; $t -lt 40; $t++) {
        $hit = $null
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) image=#(\d+) bytes=(\d+) live=(\d+)") {
                $hit = [pscustomobject]@{ Number = [int]$Matches[1]; Live = [int]$Matches[3] }
            }
        }
        if ($hit -and $hit.Number -eq $Number) { return $hit }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# A tile the strip actually DREW: `thumb=#N box=B decoded=WxH`. Counting a tile
# and being able to paint one are different claims, and off-desktop this is the
# only way to tell them apart.
function Wait-ThumbDecoded($errlog, $paneId, [int]$Number) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) thumb=#$Number box=(\d+) decoded=(\d+)x(\d+)") {
                return [pscustomobject]@{
                    Box = [int]$Matches[1]
                    W   = [int]$Matches[2]
                    H   = [int]$Matches[3]
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# The composer's LAST reported tile click: `thumbnail=#N chip=A..B`.
function Wait-ThumbClick($errlog, $paneId, [int]$Number) {
    for ($t = 0; $t -lt 30; $t++) {
        $hit = $null
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) thumbnail=#(\d+) chip=(\d+)\.\.(\d+)") {
                $hit = [pscustomobject]@{
                    Number = [int]$Matches[1]
                    Start  = [int]$Matches[2]
                    End    = [int]$Matches[3]
                }
            }
        }
        if ($hit -and $hit.Number -eq $Number) { return $hit }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Invoke-FeedbackButton($view) {
    [void](Send-TestRawMessage -Window $view.Pane -Message 0x8016)
    Start-Sleep -Milliseconds 600
    $nb = Get-ChromeChild $view.Pane 'GhozttyViewerNav'
    if (-not $nb) { return $false }
    $rect = Get-TestWindowRect $nb
    if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { return $false }
    $scale = $rect.Height / 36.0
    $x = [int]($rect.Right - [Math]::Round(18 * $scale))
    $y = [int]($rect.Top + $rect.Height / 2)
    return (Send-TestMouse -Window $view.Top -Target $nb -X $x -Y $y)
}

# Click the middle of tile $Index, in screen coordinates derived from the
# composer window's own rect plus the geometry the app reported.
function Click-Thumb($view, $fb, $geo, [int]$Index) {
    $rect = Get-TestWindowRect $fb
    if (-not $rect) { return $false }
    $x = $rect.Left + $geo.Left + $Index * $geo.Stride - $geo.Scroll + [int]($geo.Thumb / 2)
    $y = $rect.Top + $geo.Top + [int]($geo.Thumb / 2)
    return (Send-TestMouse -Window $view.Top -Target $fb -X ([int]$x) -Y ([int]$y))
}

# Click a point in the composer band's own client coordinates -- what the T668
# cue arms need, since a cue is not a tile and has no index to point at.
function Click-Band($view, $fb, [int]$X, [int]$Y) {
    $rect = Get-TestWindowRect $fb
    if (-not $rect) { return $false }
    return (Send-TestMouse -Window $view.Top -Target $fb `
            -X ([int]($rect.Left + $X)) -Y ([int]($rect.Top + $Y)))
}

# Where keyboard focus last LANDED inside the composer (T640's oracle, which
# T668 extends with the `carousel` stop).
function Get-Focus($errlog, $paneId) {
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback focus pane=$([regex]::Escape($paneId)) stop=(\w+)") {
            $hit = $Matches[1]
        }
    }
    return $hit
}

function Wait-Focus($errlog, $paneId, [string]$Stop) {
    for ($t = 0; $t -lt 30; $t++) {
        $f = Get-Focus $errlog $paneId
        if ($f -eq $Stop) { return $f }
        Start-Sleep -Milliseconds 250
    }
    return (Get-Focus $errlog $paneId)
}

function New-TestBitmap([int]$W, [int]$H, [int]$Seed) {
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            $c = [System.Drawing.Color]::FromArgb(
                255,
                ($x * 7 + $Seed) % 256,
                ($y * 11 + $Seed) % 256,
                (($x + $y) * 3 + $Seed) % 256)
            $bmp.SetPixel($x, $y, $c)
        }
    }
    return $bmp
}

function Set-ClipboardPng([int]$W, [int]$H, [int]$Seed) {
    $bmp = New-TestBitmap $W $H $Seed
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $bytes = $ms.ToArray()
    $do = New-Object System.Windows.Forms.DataObject
    $do.SetData('PNG', $false, (New-Object System.IO.MemoryStream(, $bytes)))
    [System.Windows.Forms.Clipboard]::SetDataObject($do, $true)
    Start-Sleep -Milliseconds 250
    return , $bytes
}

# --- a THROWAWAY working tree, not this repo ---------------------------------
$work = Join-Path $env:TEMP ("ghoztty-fbcar-accept-" + $PID)
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Content -Path (Join-Path $work 'README.md') -Encoding utf8 -Value @(
    '# Throwaway',
    '',
    'a paragraph in the throwaway repo',
    ''
)
& git -C $work init --initial-branch=main *> $null
& git -C $work add -A *> $null
& git -C $work -c user.name='ghoztty test' -c user.email='test@ghoztty' commit -m 'throwaway' *> $null
$workRoot = (& git -C $work rev-parse --show-toplevel 2>$null | Out-String).Trim().Replace('/', '\')
if (-not $workRoot) { Write-Host "SETUP FAIL: could not make a throwaway repo at $work"; exit 1 }
$viewFile = Join-Path $work 'README.md'

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-feedback-carousel-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    $r = Invoke-Verb @('+new-window', '--target=carwin', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'carwin')) 'the viewer window exists'
    $paneId = Get-OnlyPaneId 'carwin'
    Assert ($null -ne $paneId) "the viewer window has exactly one pane (id '$paneId')"
    Assert (Wait-WorktreeShown $errlog $paneId) 'the pane resolved a worktree, so it can file a report'

    $view = $null
    for ($t = 0; $t -lt 20; $t++) {
        $view = Get-ViewerHost $appPid
        if ($view) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $view) 'the viewer host window was found'
    if (-not $view) { throw 'no viewer host window' }

    Assert (Invoke-FeedbackButton $view) 'the revealed nav bar took a click at the feedback button'
    Assert (Wait-FeedbackOpen $errlog $paneId) 'the pane reports the composer OPEN'
    Assert (Wait-ComposerSurface $errlog 'richedit') `
        "...on the RichEdit surface this script can drive (got '$(Get-ComposerSurface $errlog)')"

    $fb = $null
    for ($t = 0; $t -lt 20; $t++) {
        $fb = Get-ChromeChild $view.Pane 'GhozttyViewerFeedback'
        if ($fb) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $fb) 'a GhozttyViewerFeedback child window exists'
    if (-not $fb) { throw 'no composer window' }

    $rich = $null
    foreach ($c in @(Get-TestChildWindows -Window $fb -Class $null)) {
        if ([string]$c.Class -eq 'RichEdit50W') { $rich = [IntPtr]$c.Hwnd; break }
    }
    Assert ($null -ne $rich) 'the composer hosts its RichEdit50W text control'
    if (-not $rich) { throw 'no text control in the composer' }

    # --- A. an empty composer has no strip -----------------------------------
    # The strip reports itself on every change, so "no report at all" is the
    # honest reading of "there is no carousel row" -- the band is exactly as
    # tall as it was before T646.
    $emptyBarH = (Get-TestWindowRect $fb).Height
    Assert ($null -eq (Get-Carousel $errlog $paneId)) `
        'an empty composer has no carousel at all -- nothing reported'
    Assert ($emptyBarH -gt 0) "the composer band has a height to compare against ($emptyBarH)"

    # --- B. two pastes, two thumbnails ---------------------------------------
    [void](Set-ClipboardPng 40 30 17)
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
    Assert ($null -ne (Wait-Image $errlog $paneId 1)) 'the first paste attached image #1'
    $c1 = Wait-Carousel $errlog $paneId 1
    Assert ($c1 -and $c1.Tiles -eq 1) "the strip appears with one tile (got '$($c1.Tiles)')"

    [void](Set-ClipboardPng 20 12 91)
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
    Assert ($null -ne (Wait-Image $errlog $paneId 2)) 'the second paste attached image #2'
    $geo = Wait-Carousel $errlog $paneId 2
    Assert ($geo -and $geo.Tiles -eq 2) "BOTH thumbnails are in the strip (got '$($geo.Tiles)')"
    if (-not $geo -or $geo.Tiles -ne 2) { throw 'the carousel never reported two tiles' }

    Assert ($geo.Thumb -gt 0 -and $geo.Stride -gt $geo.Thumb) `
        "the tiles have a size and a pitch wider than themselves ($($geo.Thumb)/$($geo.Stride))"
    $barH = (Get-TestWindowRect $fb).Height
    Assert ($barH -gt $emptyBarH) `
        "the band grew to make room for the strip ($emptyBarH -> $barH)"
    Assert (($geo.Top + $geo.Thumb) -le $barH) `
        "the strip fits inside the band (bottom $($geo.Top + $geo.Thumb) vs $barH)"
    Assert ($geo.Left -ge 4) "the strip clears the band's leading edge ($($geo.Left))"

    $text = (Get-TestControlText $rich)
    Assert (($text -match '\[Image #1\]') -and ($text -match '\[Image #2\]')) `
        "the composer holds both chips (holds '$text')"

    # ...and both were really decoded into a bitmap, letterboxed to the source's
    # own aspect ratio rather than stretched to the square tile.
    $d1 = Wait-ThumbDecoded $errlog $paneId 1
    $d2 = Wait-ThumbDecoded $errlog $paneId 2
    Assert ($null -ne $d1 -and $null -ne $d2) 'both pictures decoded into tile bitmaps'
    if ($d1 -and $d2) {
        Assert ($d1.Box -gt 0 -and $d1.Box -lt $geo.Thumb) `
            "the picture is inset inside its tile ($($d1.Box) inside $($geo.Thumb))"
        # 40x30 is landscape: it fills the box's width and keeps 3:4 of it.
        Assert ($d1.W -eq $d1.Box -and $d1.H -eq [int][Math]::Floor($d1.Box * 30 / 40)) `
            "the 40x30 picture kept its shape ($($d1.W)x$($d1.H) in a $($d1.Box) box)"
        Assert ($d2.W -eq $d2.Box -and $d2.H -eq [int][Math]::Floor($d2.Box * 12 / 20)) `
            "the 20x12 picture kept its own ($($d2.W)x$($d2.H) in a $($d2.Box) box)"
    }

    # --- C. clicking a thumbnail selects its chip ----------------------------
    Assert (Click-Thumb $view $fb $geo 0) 'the strip took a click on its first tile'
    $click = Wait-ThumbClick $errlog $paneId 1
    Assert ($null -ne $click) "clicking the first tile named image #1's chip"
    Assert ($click -and $click.End -gt $click.Start) `
        "...as a character RANGE, not a caret ($($click.Start)..$($click.End))"
    $sel = Get-Carousel $errlog $paneId
    Assert ($sel -and $sel.Selected -eq 0) `
        "...and the strip rings that tile (selected '$($sel.Selected)')"

    # The range is a real selection in the control, not just a number in a log:
    # one Backspace over it removes the WHOLE chip.
    [void](Send-TestControlKey -Control $rich -Key Backspace)
    Start-Sleep -Milliseconds 500
    $afterDelete = (Get-TestControlText $rich)
    Assert ($afterDelete -notmatch '\[Image #1\]') `
        "one Backspace after the click removed the whole chip (holds '$afterDelete')"
    Assert ($afterDelete -match '\[Image #2\]') '...and left the other chip alone'

    # --- D. a deleted chip takes its thumbnail with it -----------------------
    $c = Wait-Carousel $errlog $paneId 1
    Assert ($c -and $c.Tiles -eq 1) `
        "the strip dropped to one tile with the chip (got '$($c.Tiles)')"
    Assert (Click-Thumb $view $fb $c 0) 'the surviving tile took a click'
    $click2 = Wait-ThumbClick $errlog $paneId 2
    Assert ($null -ne $click2) `
        'the survivor is image #2 -- numbers are stable, never renumbered to #1'

    # --- E. emptying the composer empties the strip --------------------------
    [void](Send-TestControlKey -Control $rich -Key Backspace)
    Start-Sleep -Milliseconds 500
    $c0 = Wait-Carousel $errlog $paneId 0
    Assert ($c0 -and $c0.Tiles -eq 0) `
        "deleting the last chip removes the strip entirely (got '$($c0.Tiles)')"
    $shrunk = (Get-TestWindowRect $fb).Height
    Assert ($shrunk -eq $emptyBarH) `
        "...and the band is exactly as tall as it was before any picture ($shrunk vs $emptyBarH)"

    # --- F. an overflowing strip SAYS there is more, at the end that has it --
    # T668. The cue is a fade and a chevron -- painted chrome, which this
    # desktop cannot photograph -- so the strip's own `cue=` is the oracle, and
    # the clicks below prove the affordance under it actually pages.
    $wrect = Get-TestWindowRect $view.Top
    if ($wrect) {
        [void](Set-TestWindowSize -Window $view.Top -Width 520 -Height $wrect.Height)
        Start-Sleep -Milliseconds 700
    }

    $c = $null
    $pasted = 0
    while ($pasted -lt 16) {
        $pasted++
        [void](Set-ClipboardPng 40 30 (100 + $pasted))
        [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
        $c = Wait-Carousel $errlog $paneId $pasted
        if (-not $c -or $c.Tiles -ne $pasted) { break }
        if ($c.Max -gt 0 -and $pasted -ge 3) { break }
    }
    Assert ($c -and $c.Tiles -eq $pasted) `
        "the strip took $pasted pictures (reports '$($c.Tiles)')"
    Assert ($c -and $c.Max -gt 0) `
        "...more than fit across the band (view $($c.View), overflow $($c.Max))"
    if (-not $c -or $c.Max -le 0) { throw 'the strip never overflowed its viewport' }
    $tiles = $c.Tiles

    # Page back to the first picture by clicking the LEADING cue, which is the
    # mouse affordance the fade is advertising.
    for ($i = 0; $i -lt 20; $i++) {
        $c = Get-Carousel $errlog $paneId
        if (-not $c -or $c.Scroll -le 0) { break }
        [void](Click-Band $view $fb ($c.Left + 3) ($c.Top + [int]($c.Thumb / 2)))
        Start-Sleep -Milliseconds 300
    }
    $c = Wait-CarouselWhere $errlog $paneId { param($x) $x.Scroll -eq 0 }
    Assert ($c.Scroll -eq 0) `
        "clicking the leading cue pages back to the first picture (scroll $($c.Scroll))"
    Assert ($c.Cue -eq 'end') `
        "...where the only cue is the trailing one, because that is the only end with more (cue '$($c.Cue)')"

    # One click on the TRAILING cue moves the ribbon, and the leading end then
    # has content past it too.
    [void](Click-Band $view $fb ($c.Left + $c.View - 3) ($c.Top + [int]($c.Thumb / 2)))
    $c = Wait-CarouselWhere $errlog $paneId { param($x) $x.Scroll -gt 0 }
    Assert ($c.Scroll -gt 0) `
        "clicking the trailing cue pages toward the pictures off the edge (scroll $($c.Scroll))"
    Assert ($c.Cue -eq 'both' -or $c.Cue -eq 'start') `
        "...and the leading end now says so as well (cue '$($c.Cue)')"

    # ...and at the far end the trailing cue is gone: a cue that stayed up with
    # nothing behind it would be the same lie as no cue at all.
    for ($i = 0; $i -lt 20; $i++) {
        $c = Get-Carousel $errlog $paneId
        if (-not $c -or $c.Scroll -ge $c.Max) { break }
        [void](Click-Band $view $fb ($c.Left + $c.View - 3) ($c.Top + [int]($c.Thumb / 2)))
        Start-Sleep -Milliseconds 300
    }
    $c = Wait-CarouselWhere $errlog $paneId { param($x) $x.Scroll -ge $x.Max }
    Assert ($c.Scroll -eq $c.Max) "the strip pages all the way to the last picture (scroll $($c.Scroll)/$($c.Max))"
    Assert ($c.Cue -eq 'start') "...and only the leading cue is left there (cue '$($c.Cue)')"

    # --- G. the keyboard reaches a picture that is off the edge --------------
    # The gap T668 was filed for: every tile was mouse-only. Tab now stops on
    # the strip and the arrows walk it, which is the Windows model for a strip
    # of like items.
    [void](Send-TestControlKey -Control $rich -Key Tab)
    $focusStop = Wait-Focus $errlog $paneId 'carousel'
    Assert ($focusStop -eq 'carousel') `
        "Tab from the text now stops on the strip of pictures (focus '$focusStop')"
    $c = Wait-CarouselWhere $errlog $paneId { param($x) $x.Focus -ge 0 }
    Assert ($c.Focus -ge 0) "...with the ring on a real tile (focus '$($c.Focus)')"

    [void](Send-TestControlKey -Control $fb -Key Home)
    $c = Wait-CarouselWhere $errlog $paneId { param($x) $x.Focus -eq 0 }
    Assert ($c.Focus -eq 0) "Home walks the ring to the first picture (focus '$($c.Focus)')"
    Assert ($c.Scroll -eq 0) "...and the strip scrolled to show it (scroll $($c.Scroll))"

    # End reaches the LAST picture, which at this width is off the edge -- the
    # exact thing the keyboard could not do before.
    [void](Send-TestControlKey -Control $fb -Key End)
    $c = Wait-CarouselWhere $errlog $paneId { param($x) $x.Focus -eq ($tiles - 1) }
    Assert ($c.Focus -eq ($tiles - 1)) `
        "End reaches the last picture, which does not fit on screen (focus '$($c.Focus)' of $tiles)"
    Assert ($c.Scroll -eq $c.Max) "...by scrolling the strip to it (scroll $($c.Scroll)/$($c.Max))"

    [void](Send-TestControlKey -Control $fb -Key Left)
    $c = Wait-CarouselWhere $errlog $paneId { param($x) $x.Focus -eq ($tiles - 2) }
    Assert ($c.Focus -eq ($tiles - 2)) "Left steps back one picture (focus '$($c.Focus)')"
    $tileLeft = $c.Focus * $c.Stride - $c.Scroll
    Assert ($tileLeft -ge 0 -and ($tileLeft + $c.Thumb) -le $c.View) `
        "...and it is wholly inside the viewport, not half off it ($tileLeft..$($tileLeft + $c.Thumb) in $($c.View))"

    # Enter does what a click does: it selects that picture's chip, which is
    # also where the ring goes -- back to the text with the caret.
    $ringed = $c.Focus
    [void](Send-TestControlKey -Control $fb -Key Enter)
    $c = Wait-CarouselWhere $errlog $paneId { param($x) $x.Selected -eq $ringed }
    Assert ($c.Selected -eq $ringed) `
        "Enter on the focused tile selects that picture's chip (selected '$($c.Selected)')"
    Assert ($c.Focus -lt 0) `
        "...and hands the keyboard back to the text rather than leaving a ring behind (focus '$($c.Focus)')"
    $afterEnter = (Get-TestControlText $rich)
    Assert ($afterEnter -match '\[Image #') "the report still holds its pictures after the walk"

    # --- H. a strip that FITS has no cue at either end -----------------------
    # The other half of the contract, and the one a fade gets wrong by being
    # always-on: widen the band past the whole ribbon and the cues go away.
    if ($wrect) {
        $wide = ($tiles + 2) * $c.Stride + 240
        [void](Set-TestWindowSize -Window $view.Top -Width $wide -Height $wrect.Height)
    }
    $c = Wait-CarouselWhere $errlog $paneId { param($x) $x.Max -eq 0 }
    Assert ($c.Max -eq 0) `
        "widened past the whole ribbon, the strip has nothing to scroll (view $($c.View), overflow $($c.Max))"
    Assert ($c.Cue -eq 'none') "...and neither end shows a cue (cue '$($c.Cue)')"

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
