# T669 acceptance: a transparent picture in the feedback carousel shows the
# TILE'S OWN FILL through its see-through parts, not black.
#
# The defect this pins down: the tile decode asked GDI+ for an HBITMAP with
# `0xFF000000` as the background, i.e. it composited every alpha pixel against
# opaque BLACK before anything got to paint. A logo with a transparent
# background, or a screenshot cropped to rounded corners, therefore came back as
# a black slab -- worst in light theme, where a black square in a pale strip
# reads as a broken thumbnail rather than as a transparent one.
#
# What is asserted, per theme:
#
#   1. The pasted picture is decoded into a tile at all (the strip counts it AND
#      draws it -- two different claims).
#   2. A pixel in the picture's fully TRANSPARENT half matches the tile's own
#      fill, sampled from the tile's inset ring in the same capture.
#   3. That pixel is nowhere near black, which is the regression itself stated
#      as its own assertion rather than left implied by (2).
#   4. A pixel in the picture's OPAQUE half is still the colour it was, so
#      "keeps the alpha" did not quietly become "lost the picture".
#
# BOTH THEMES, because the whole argument for compositing at paint time rather
# than at decode time is that the cached bitmap must not carry a theme colour.
# Light is where the bug was ugliest; dark is where a fix that hard-codes
# something dark would still look fine and be just as wrong. The band's colours
# derive from the PANE BACKGROUND (`ViewerFeedbackBar.applyTheme`), so each arm
# launches with its own `--background` rather than a `--window-theme` that does
# not reach this surface.
#
# ORACLES. This runs on the BACKGROUND test desktop, where CopyFromScreen and
# SendInput are dead (T233). Two readable things stand in:
#
#   - the composer's own carousel report on stderr, which names the tile count
#     and the strip's geometry in the band's client coordinates, plus the
#     per-tile `thumb=#N box=B decoded=WxH` line -- together they say exactly
#     which pixels of the capture are the picture and which are the tile;
#   - a SYNCHRONOUS PrintWindow capture of the composer band, which is a
#     GDI-painted native window and therefore one of the surfaces that does
#     survive off the input desktop (the band handles WM_PRINTCLIENT for exactly
#     this). The terminal surface, which does not, is never captured here.
#
# Ctrl+V is sent with Send-TestViewerChord rather than Send-TestKeys: the
# composer's interception asks the app's own GetKeyState for the modifier, and
# only the attaching variant arranges that.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-feedback-alpha.ps1
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

# Each arm runs its OWN app on its OWN endpoint (set inside Invoke-Arm), so the
# two themes never have to be separated by a kill: a mid-run TerminateProcess is
# indistinguishable from a crash to the postmortem watcher, and a red herring in
# a script's output is a cost paid by every later reader of it.
$env:GHOZTTY_PIPE_SUFFIX = "-fbalpha$PID"

# The paste goes through window messages into a native control, so this suite
# pins itself to the RichEdit surface (T1102). The CAROUSEL is the band's own
# GDI paint on either surface -- it is not part of the web composer's document --
# but the only way to put a picture in it from here is the control.
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

function Get-Carousel($errlog, $paneId) {
    $hit = $null
    $pat = "viewer feedback pane=$([regex]::Escape($paneId)) carousel=(\w+) tiles=(\d+) " +
           "scroll=(-?\d+) selected=(-?\d+) left=(-?\d+) top=(-?\d+) thumb=(\d+) stride=(\d+)" +
           " view=(-?\d+) max=(-?\d+) cue=(\w+) focus=(-?\d+)"
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match $pat) {
            $hit = [pscustomobject]@{
                Tiles  = [int]$Matches[2]
                Scroll = [int]$Matches[3]
                Left   = [int]$Matches[5]
                Top    = [int]$Matches[6]
                Thumb  = [int]$Matches[7]
                Stride = [int]$Matches[8]
            }
        }
    }
    return $hit
}

function Wait-Carousel($errlog, $paneId, [int]$Tiles) {
    for ($t = 0; $t -lt 40; $t++) {
        $c = Get-Carousel $errlog $paneId
        if ($c -and $c.Tiles -eq $Tiles) { return $c }
        Start-Sleep -Milliseconds 250
    }
    return (Get-Carousel $errlog $paneId)
}

function Wait-Image($errlog, $paneId, [int]$Number) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) image=#$Number bytes=(\d+) live=(\d+)") {
                return $true
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

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

# The picture under test: a SQUARE so it fills the tile's inset box exactly
# (no letterboxing to reason about), fully transparent on the left half and
# opaque red on the right. Two halves rather than a checkerboard because the
# assertions sample well away from the seam -- a resampling filter is entitled
# to blend across it, and asserting that it does not would be asserting the
# interpolation mode instead of the alpha.
function New-HalfTransparentPng([int]$Side) {
    $bmp = New-Object System.Drawing.Bitmap $Side, $Side,
        ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $clear = [System.Drawing.Color]::FromArgb(0, 0, 0, 0)
    $solid = [System.Drawing.Color]::FromArgb(255, 220, 30, 30)
    for ($y = 0; $y -lt $Side; $y++) {
        for ($x = 0; $x -lt $Side; $x++) {
            $bmp.SetPixel($x, $y, $(if ($x -lt $Side / 2) { $clear } else { $solid }))
        }
    }
    return $bmp
}

function Set-ClipboardTransparentPng([int]$Side) {
    $bmp = New-HalfTransparentPng $Side
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $bytes = $ms.ToArray()
    # The PNG format specifically, not a DIB: a device bitmap on the clipboard
    # has nowhere to put an alpha channel, so pasting one would test nothing.
    $do = New-Object System.Windows.Forms.DataObject
    $do.SetData('PNG', $false, (New-Object System.IO.MemoryStream(, $bytes)))
    [System.Windows.Forms.Clipboard]::SetDataObject($do, $true)
    Start-Sleep -Milliseconds 250
    return $bytes.Length
}

function Format-Color($c) { return "$($c.R),$($c.G),$($c.B)" }

function Test-ColorNear($a, $b, [int]$Tol) {
    return ([Math]::Abs($a.R - $b.R) -le $Tol -and
            [Math]::Abs($a.G - $b.G) -le $Tol -and
            [Math]::Abs($a.B - $b.B) -le $Tol)
}

function Get-Distance($a, $b) {
    return [Math]::Max([Math]::Max([Math]::Abs($a.R - $b.R), [Math]::Abs($a.G - $b.G)),
                       [Math]::Abs($a.B - $b.B))
}

# --- a THROWAWAY working tree, not this repo ---------------------------------
$work = Join-Path $env:TEMP ("ghoztty-fbalpha-accept-" + $PID)
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

# One arm: launch with $Background, paste the transparent picture, and read the
# tile's pixels back out of a synchronous capture of the band.
function Invoke-Arm([string]$Label, [string]$Background) {
    $env:GHOZTTY_PIPE_SUFFIX = "-fbalpha$PID-$Label"
    $errlog = Join-Path $env:TEMP "ghoztty-viewer-feedback-alpha-$Label-stderr.log"
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog `
        -Arguments @('--session-persistence=false', "--background=$Background")
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Assert $false "[$Label] the GUI survived launch"
        return
    }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Assert $false "[$Label] a GhozttyWindow appeared"
        return
    }

    $target = "alphawin$Label"
    $r = Invoke-Verb @('+new-window', "--target=$target", "--view=$viewFile")
    Assert ($r.Code -eq 0) "[$Label] +new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win $target)) "[$Label] the viewer window exists"
    $paneId = Get-OnlyPaneId $target
    Assert ($null -ne $paneId) "[$Label] the viewer window has exactly one pane (id '$paneId')"
    if (-not $paneId) { return }
    Assert (Wait-WorktreeShown $errlog $paneId) "[$Label] the pane resolved a worktree, so it can file a report"

    $view = $null
    for ($t = 0; $t -lt 20; $t++) {
        $view = Get-ViewerHost $appPid
        if ($view) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $view) "[$Label] the viewer host window was found"
    if (-not $view) { return }

    Assert (Invoke-FeedbackButton $view) "[$Label] the revealed nav bar took a click at the feedback button"
    Assert (Wait-FeedbackOpen $errlog $paneId) "[$Label] the pane reports the composer OPEN"
    Assert (Wait-ComposerSurface $errlog 'richedit') `
        "[$Label] ...on the RichEdit surface this script can drive (got '$(Get-ComposerSurface $errlog)')"

    $fb = $null
    for ($t = 0; $t -lt 20; $t++) {
        $fb = Get-ChromeChild $view.Pane 'GhozttyViewerFeedback'
        if ($fb) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $fb) "[$Label] a GhozttyViewerFeedback child window exists"
    if (-not $fb) { return }

    $rich = $null
    foreach ($c in @(Get-TestChildWindows -Window $fb -Class $null)) {
        if ([string]$c.Class -eq 'RichEdit50W') { $rich = [IntPtr]$c.Hwnd; break }
    }
    Assert ($null -ne $rich) "[$Label] the composer hosts its RichEdit50W text control"
    if (-not $rich) { return }

    $bytes = Set-ClipboardTransparentPng 48
    Assert ($bytes -gt 0) "[$Label] a half-transparent PNG is on the clipboard ($bytes bytes)"
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
    Assert (Wait-Image $errlog $paneId 1) "[$Label] the paste attached image #1"

    $geo = Wait-Carousel $errlog $paneId 1
    Assert ($geo -and $geo.Tiles -eq 1) "[$Label] the strip shows one tile (got '$($geo.Tiles)')"
    $dec = Wait-ThumbDecoded $errlog $paneId 1
    Assert ($null -ne $dec) "[$Label] the picture decoded into a tile bitmap"
    if (-not $geo -or $geo.Tiles -ne 1 -or -not $dec) { return }
    Assert ($dec.W -eq $dec.Box -and $dec.H -eq $dec.Box) `
        "[$Label] the square picture fills the tile's inset box ($($dec.W)x$($dec.H) in $($dec.Box))"

    # The band's own pixels. Synchronous (WM_PRINTCLIENT), which is what makes
    # this readable at all off the input desktop -- and what makes it a picture
    # of a settled window rather than one caught mid-paint.
    $shot = Get-TestWindowPixels -Window $fb -Sync
    try {
        $tileL = $geo.Left + 0 * $geo.Stride - $geo.Scroll
        $tileT = $geo.Top
        $inset = [int](($geo.Thumb - $dec.Box) / 2)
        Assert ($inset -ge 2) "[$Label] the tile insets its picture by enough to sample ($inset px)"
        $imgL = $tileL + [int](($geo.Thumb - $dec.W) / 2)
        $imgT = $tileT + [int](($geo.Thumb - $dec.H) / 2)
        $midY = $imgT + [int]($dec.H / 2)

        Assert (($tileL -ge 0) -and (($tileL + $geo.Thumb) -le $shot.Width) -and
                (($tileT + $geo.Thumb) -le $shot.Height)) `
            "[$Label] the tile is inside the captured band ($tileL,$tileT +$($geo.Thumb) in $($shot.Width)x$($shot.Height))"

        # The reference: the tile's own fill, read from the inset ring of the
        # SAME capture. Sampling it rather than re-deriving the theme colour is
        # the point -- the claim is "the picture shows the tile through", and a
        # hard-coded expectation would only ever prove this script agrees with
        # itself about `applyTheme`.
        $fill = $shot.Bitmap.GetPixel($tileL + [int]($inset / 2), $tileT + [int]($geo.Thumb / 2))
        # Quarter-width in from each edge: deep inside each half.
        $clear = $shot.Bitmap.GetPixel($imgL + [int]($dec.W / 4), $midY)
        $solid = $shot.Bitmap.GetPixel($imgL + [int]($dec.W * 3 / 4), $midY)

        Assert (Test-ColorNear $clear $fill 6) `
            "[$Label] the transparent half shows the TILE'S FILL ($(Format-Color $clear) vs fill $(Format-Color $fill))"

        # The regression as its own assertion. `$clear -eq $fill` above would be
        # satisfied for free by a theme whose fill IS black, so both arms use a
        # background whose derived tile fill is plainly not black -- which is
        # also why the dark arm is a dark BLUE-GREY rather than #101010.
        $black = [System.Drawing.Color]::FromArgb(255, 0, 0, 0)
        Assert ((Get-Distance $fill $black) -gt 24) `
            "[$Label] the tile fill is far enough from black for that to mean something (distance $(Get-Distance $fill $black))"
        Assert ((Get-Distance $clear $black) -gt 24) `
            "[$Label] ...and the transparent half is not the flat black the old decode produced (distance $(Get-Distance $clear $black))"

        # And the opaque half is still the picture.
        $red = [System.Drawing.Color]::FromArgb(255, 220, 30, 30)
        Assert (Test-ColorNear $solid $red 24) `
            "[$Label] the opaque half still carries the picture's own colour ($(Format-Color $solid))"
    } finally {
        $shot.Bitmap.Dispose()
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) "[$Label] GUI process alive after the arm"
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) `
        "[$Label] GUI never became visible on the interactive desktop"
}

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # LIGHT first: the theme the bug was ugliest in, and the one where a black
    # slab is unmistakable.
    Invoke-Arm 'light' 'ffffff'
    Invoke-Arm 'dark' '1e2430'
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
