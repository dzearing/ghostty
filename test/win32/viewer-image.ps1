# T1183 acceptance: an image opens as a PICTURE, fitted, not as source text.
#
# What is asserted:
#
#   - `--view=<file>.png` (and .jpg/.gif/.webp/.svg) enters image mode: the
#     picture is FETCHED through the pane's own origin, with an image MIME
#     type, which a syntax-highlighted source view never does.
#   - the pane fits it on open: a picture larger than the pane opens below
#     100%, and `zoom` equals `fit` exactly.
#   - best-fit NEVER upscales: a 16x16 icon in a full-size pane opens at 100%,
#     not blown up to fill it.
#   - 100% is one image pixel per DEVICE pixel: the CSS scale the pane pushes
#     is `zoom / dpr`, at whatever scale factor the display reports.
#   - a vector (.svg) is measured as a vector, where 100% is the drawing's own
#     size rather than a pixel count.
#   - `+list --json` reports the pane the way it reports every other viewer
#     mode: type `viewer`, `url` the file's own path.
#   - `+reload` re-fetches the bytes (the revision moves), which is what makes
#     a re-exported screenshot appear.
#   - a corrupt/undecodable image gets the pane's own error card naming the
#     file, rather than a blank matte.
#   - a `.txt` control in the same run produces NONE of it.
#
# ORACLE, and why it is the log. This runs on the background test desktop,
# where CopyFromScreen and SendInput are dead (T233), so nothing out here can
# see a rendered picture. The pane states what it decided instead:
#
#     viewer image pane=<id> event=<e> natural=WxH viewport=WxH dpr=D kind=K
#         zoom=Z fit=F fitting=B scale=S
#     viewer image served pane=<id> rev=<n> bytes=<n> mime=<type>
#
# The first is emitted by `applyImageMessage`, the only place a zoom is
# decided; the second by `serveImage`, the only place the file's bytes reach
# the page. Neither line can be produced by any other path, and a source view
# produces neither.
#
# NOT asserted here, deliberately: the GESTURES. A double-click, a ctrl+wheel
# notch and a pinch cannot be delivered on this desktop at all, and a harness
# that pretended to would be asserting its own fake. What decides those is
# arithmetic - `Geometry.doubleClickZoom`, `.stepped`, `.clamp` - and it is
# asserted exhaustively without a browser in the none lane, in
# `src\apprt\win32\viewer_image.zig` ("double-click toggles fit and 100%, and
# still toggles when they coincide" is the fit==100% case the task names). What
# THIS script proves is the other half: that the numbers those rules produce
# actually reach a picture on screen.
#
# -NegativeControl inverts the two load-time assertions in section B and MUST
# fail with exactly TWO failures, so a run that scores anything else is
# measuring something other than the fit.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-image.ps1
param(
    [string]$ExePath,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vimg$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0

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

function Get-OnlyPane($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0]
}

# Every image decision this pane has reported, oldest first.
function Get-ImageStates($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return @() }
    $out = @()
    $re = "viewer image pane=$([regex]::Escape($paneId)) event=(\S+) natural=(\S+)x(\S+) " +
          "viewport=(\S+)x(\S+) dpr=(\S+) kind=(\S+) zoom=(\S+) fit=(\S+) fitting=(\S+) scale=(\S+)"
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match $re) {
            $out += [pscustomobject]@{
                Event    = $Matches[1]
                NatW     = [double]$Matches[2]
                NatH     = [double]$Matches[3]
                ViewW    = [double]$Matches[4]
                ViewH    = [double]$Matches[5]
                Dpr      = [double]$Matches[6]
                Kind     = $Matches[7]
                Zoom     = [double]$Matches[8]
                Fit      = [double]$Matches[9]
                Fitting  = ($Matches[10] -eq 'true')
                Scale    = [double]$Matches[11]
            }
        }
    }
    return $out
}

# The pane's first `loaded` decision - the open, before anything could resize
# it. Waited for, because the picture has to decode in the browser first.
function Wait-Loaded($errlog, $paneId) {
    for ($t = 0; $t -lt 80; $t++) {
        $hit = @(Get-ImageStates $errlog $paneId | Where-Object { $_.Event -eq 'loaded' })
        if ($hit.Count -gt 0) { return $hit[0] }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Get-ImageServed($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return @() }
    $out = @()
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer image served pane=$([regex]::Escape($paneId)) rev=(\d+) bytes=(\d+) mime=(\S+)") {
            $out += [pscustomobject]@{ Rev = [int]$Matches[1]; Bytes = [int]$Matches[2]; Mime = $Matches[3] }
        }
    }
    return $out
}

function Wait-ImageServed($errlog, $paneId, [int]$AtLeast = 1) {
    for ($t = 0; $t -lt 80; $t++) {
        $n = @(Get-ImageServed $errlog $paneId)
        if ($n.Count -ge $AtLeast) { return $n }
        Start-Sleep -Milliseconds 250
    }
    return @(Get-ImageServed $errlog $paneId)
}

function Near([double]$a, [double]$b, [double]$tol = 0.002) {
    return ([Math]::Abs($a - $b) -le $tol)
}

# --- the pictures under test -----------------------------------------------
$dir = Join-Path $env:TEMP ('ghoztty-t1183-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir | Out-Null

Add-Type -AssemblyName System.Drawing

# A picture far larger than any pane on this box, so best-fit MUST shrink it.
$bigPath = Join-Path $dir 'big.png'
$big = New-Object System.Drawing.Bitmap 4000, 3000
try {
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.Clear([System.Drawing.Color]::CornflowerBlue)
    $g.Dispose()
    $big.Save($bigPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $big.Dispose() }

# A 16x16 icon: smaller than any pane, so fit would be an enormous upscale -
# and must not be.
$iconPath = Join-Path $dir 'icon.png'
$icon = New-Object System.Drawing.Bitmap 16, 16
try {
    $g = [System.Drawing.Graphics]::FromImage($icon)
    $g.Clear([System.Drawing.Color]::Firebrick)
    $g.Dispose()
    $icon.Save($iconPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $icon.Dispose() }

# A JPEG, because the extension table is a table and one entry proves nothing.
$jpgPath = Join-Path $dir 'shot.jpg'
$jpg = New-Object System.Drawing.Bitmap 800, 400
try {
    $g = [System.Drawing.Graphics]::FromImage($jpg)
    $g.Clear([System.Drawing.Color]::SeaGreen)
    $g.Dispose()
    $jpg.Save($jpgPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
} finally { $jpg.Dispose() }

# Vector art with an intrinsic size, which is what makes 100% mean something
# different for it.
$svgPath = Join-Path $dir 'logo.svg'
Set-Content -LiteralPath $svgPath -Encoding UTF8 -Value @'
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120" viewBox="0 0 240 120">
  <rect width="240" height="120" fill="#4477cc"/>
</svg>
'@

# A `.png` that is not one: the error-card path.
$corruptPath = Join-Path $dir 'broken.png'
Set-Content -LiteralPath $corruptPath -Value 'this is not a picture' -Encoding ASCII

# The control: a text file in the same directory, opened in the same run.
$txtPath = Join-Path $dir 'notes.txt'
Set-Content -LiteralPath $txtPath -Value 'T1183 control: plain text' -Encoding UTF8

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-image-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # --- A. a .png opens as a picture, and its bytes are fetched -------------
    $r = Invoke-Verb @('+new-window', '--target=t1183big', "--view=$bigPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.png exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't1183big')) 'the image viewer window exists'
    $leaf = Get-OnlyPane 't1183big'
    $bigPane = if ($leaf) { $leaf.id } else { $null }
    Assert ($null -ne $bigPane) 'the image viewer window has exactly one pane'

    # PS5.1: a function's array return unrolls, so a one-element result has a
    # $null .Count until it is re-wrapped. Every call site here re-wraps.
    $served = @(Wait-ImageServed $errlog $bigPane)
    Assert ($served.Count -ge 1) 'the picture was fetched through the pane origin, not rendered as text'
    Assert ($served.Count -ge 1 -and $served[0].Mime -eq 'image/png') `
        "...with an image MIME type (got '$(if ($served.Count) { $served[0].Mime } else { '-' })')"

    # --- B. it opens FITTED, below 100% -------------------------------------
    $st = Wait-Loaded $errlog $bigPane
    Assert ($null -ne $st) 'the pane decided a zoom for the picture'
    Assert ($st -and $st.NatW -eq 4000 -and $st.NatH -eq 3000) `
        "the pane measured the picture's real size (got $(if ($st) { "$($st.NatW)x$($st.NatH)" } else { '-' }))"
    Assert ($st -and $st.Kind -eq 'raster') 'a PNG is measured as raster art'

    $fitted = ($st -and $st.Fitting -and (Near $st.Zoom $st.Fit))
    $shrunk = ($st -and $st.Zoom -lt 1 -and $st.Zoom -gt 0)
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the picture does NOT open fitted - this run MUST fail'
        Assert (-not $fitted) 'B: a fresh picture opens at best-fit (negative control)'
        Assert (-not $shrunk) 'B: a picture larger than the pane opens below 100% (negative control)'
    } else {
        Assert $fitted 'B: a fresh picture opens at best-fit'
        Assert $shrunk "B: a picture larger than the pane opens below 100% (zoom=$(if ($st) { $st.Zoom } else { '-' }))"
    }

    # The fit is the CONSTRAINING axis of the pane it actually got, recomputed
    # here from the numbers the pane reported rather than from a guess.
    if ($st -and $st.ViewW -gt 0 -and $st.ViewH -gt 0) {
        $unit = 1 / [Math]::Max($st.Dpr, 1)
        $want = [Math]::Min(
            $st.ViewW / ($st.NatW * $unit),
            $st.ViewH / ($st.NatH * $unit))
        if ($want -gt 1) { $want = 1 }
        Assert (Near $st.Fit $want) `
            "B: fit is the constraining axis of this pane (reported $($st.Fit), recomputed $([Math]::Round($want, 4)))"
    } else {
        $script:skipped++
        Write-Host 'SKIP  B: the pane reported no viewport to recompute the fit against'
    }

    # 100% means one image pixel per DEVICE pixel, so the CSS scale the pane
    # pushes is the zoom divided by the display's scale factor. This is the
    # whole definition, measured at whatever dpr this box actually has.
    if ($st) {
        Assert (Near $st.Scale ($st.Zoom / [Math]::Max($st.Dpr, 1))) `
            "B: the pushed scale is zoom/dpr - one image pixel per device pixel at 100% (dpr=$($st.Dpr))"
    }

    # --- C. best-fit never upscales ------------------------------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183icon', "--view=$iconPath")
    Assert ($r.Code -eq 0) "+new-window --view=<icon>.png exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't1183icon')) 'the icon window exists'
    $iconLeaf = Get-OnlyPane 't1183icon'
    $iconPane = if ($iconLeaf) { $iconLeaf.id } else { $null }
    $ist = Wait-Loaded $errlog $iconPane
    Assert ($null -ne $ist) 'the icon pane decided a zoom'
    Assert ($ist -and $ist.NatW -eq 16 -and $ist.NatH -eq 16) 'the icon was measured at 16x16'
    Assert ($ist -and (Near $ist.Fit 1)) `
        "C: a 16px icon in a full-size pane fits at 100%, not blown up (fit=$(if ($ist) { $ist.Fit } else { '-' }))"
    Assert ($ist -and (Near $ist.Zoom 1)) 'C: ...and that is the zoom it opens at'

    # --- D. the rest of the extension table ---------------------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183jpg', "--view=$jpgPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.jpg exits 0 (got $($r.Code))"
    $jpgLeaf = Get-OnlyPane 't1183jpg'
    $jpgPane = if ($jpgLeaf) { $jpgLeaf.id } else { $null }
    $jserved = @(Wait-ImageServed $errlog $jpgPane)
    Assert ($jserved.Count -ge 1 -and $jserved[0].Mime -eq 'image/jpeg') `
        "D: a .jpg is served as image/jpeg (got '$(if ($jserved.Count) { $jserved[0].Mime } else { '-' })')"
    $jst = Wait-Loaded $errlog $jpgPane
    Assert ($jst -and $jst.NatW -eq 800 -and $jst.NatH -eq 400) 'D: and it is measured at its real size'

    # --- E. a vector is measured as one --------------------------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183svg', "--view=$svgPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.svg exits 0 (got $($r.Code))"
    $svgLeaf = Get-OnlyPane 't1183svg'
    $svgPane = if ($svgLeaf) { $svgLeaf.id } else { $null }
    $sserved = @(Wait-ImageServed $errlog $svgPane)
    Assert ($sserved.Count -ge 1 -and $sserved[0].Mime -eq 'image/svg+xml') `
        "E: an .svg is a picture, served as image/svg+xml (got '$(if ($sserved.Count) { $sserved[0].Mime } else { '-' })')"
    $sst = Wait-Loaded $errlog $svgPane
    Assert ($sst -and $sst.Kind -eq 'vector') `
        "E: ...and is measured as vector art, where 100% is its own size (kind=$(if ($sst) { $sst.Kind } else { '-' }))"
    if ($sst) {
        Assert (Near $sst.Scale $sst.Zoom) 'E: a vector''s scale is its zoom - no device-pixel term'
    }

    # --- F. +list --json reports it like any other viewer --------------------
    $leaf = Get-OnlyPane 't1183big'
    Assert ($leaf -and $leaf.type -eq 'viewer') "F: +list --json calls the pane a viewer (got '$($leaf.type)')"
    Assert ($leaf -and $leaf.url -eq $bigPath) `
        "F: ...and reports the file's own path (got '$($leaf.url)')"

    # --- G. +reload re-fetches the bytes -------------------------------------
    $before = @(Get-ImageServed $errlog $bigPane).Count
    $r = Invoke-Verb @('+reload', "--target=$bigPane")
    Assert ($r.Code -eq 0) "+reload against an image pane exits 0 (got $($r.Code))"
    $after = @(Wait-ImageServed $errlog $bigPane -AtLeast ($before + 1)).Count
    Assert ($after -gt $before) `
        "G: +reload re-fetched the picture (served $before time(s), then $after)"
    $revs = @(Get-ImageServed $errlog $bigPane | ForEach-Object { $_.Rev })
    Assert ($revs.Count -ge 2 -and $revs[-1] -gt $revs[0]) `
        'G: ...under a new revision, which is what makes the browser go back to disk'

    # --- H. an undecodable picture gets the pane's own card ------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183bad', "--view=$corruptPath")
    Assert ($r.Code -eq 0) "+new-window --view=<corrupt>.png exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't1183bad')) 'the corrupt-image window exists'
    $carded = $false
    for ($t = 0; $t -lt 60; $t++) {
        $txt = (Get-Content $errlog -ErrorAction SilentlyContinue | Out-String)
        if ($txt -match ('viewer file error: Cannot display this image \(' + [regex]::Escape($corruptPath) + '\)')) {
            $carded = $true; break
        }
        Start-Sleep -Milliseconds 250
    }
    Assert $carded 'H: the error card names the picture that could not be displayed'

    # --- I. the control: a text file is still text ---------------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183txt', "--view=$txtPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.txt exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't1183txt')) 'the control window exists'
    $txtLeaf = Get-OnlyPane 't1183txt'
    $txtPane = if ($txtLeaf) { $txtLeaf.id } else { $null }
    Start-Sleep -Seconds 2
    Assert (@(Get-ImageServed $errlog $txtPane).Count -eq 0) `
        'I: a .txt pane never fetched a picture'
    Assert (@(Get-ImageStates $errlog $txtPane).Count -eq 0) `
        'I: ...and never decided an image zoom'

    # --- J. the app survived all of it ---------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due. A negative-control run is red by construction, so it
# never stamps.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-image -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
} else {
    Write-Host "$script:fail FAILURE(S) ($script:pass passed$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
    exit 1
}
