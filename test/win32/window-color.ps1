# T67 acceptance: window/pane background tint (`--color` / `--split-color`)
# + split-inheritance shift + context-menu "Background Color..." picker.
#
# Oracles:
#   - `+list --json` panes carry an additive `background_tint` (#rrggbb)
#     field when tinted (absent otherwise).
#   - A NATIVE-PIXEL probe proves the tint escapes the data model: the pane
#     banner overlay paints the pane's EFFECTIVE background around its card
#     (Surface.refreshBannerColors takes `background_tint orelse config
#     background`), so a banner raised on a tinted pane must have the tint in
#     its band corners. See the migration note below for why this replaced the
#     old screen-pixel probe.
#   - The plain-split inheritance value is pinned exactly: #334455 parent
#     -> #384b5e child (the color_math.zig unit-test oracle, Mac
#     shiftedTint parity: HSB brightness +5% toward white on dark parents).
#   - Picker: right-click menu -> "B" mnemonic -> ChooseColorW (comdlg
#     #32770) -> Enter accepts the CC_RGBINIT initial color (= the pane's
#     effective background) -> the untinted launch window gains an explicit
#     tint equal to the configured background.
#
# T218 batch 6: migrated onto the BACKGROUND test desktop
# (test/win32/lib/TestDesktop.ps1), so the run never takes the user's
# foreground - asserted here, not assumed.
#
# THE ONE PROBE THAT COULD NOT MIGRATE AS-IS, AND HOW IT CAME BACK (T218 batch
# 2 flagged it; T214 dropped it; T275 restored it). Section 1 used to read the
# composited SCREEN pixel at the pane centre to prove the tint reached the
# glass. The glass is the OpenGL terminal surface, which is exactly the half of
# the harness's CAPTURE LIMIT that PrintWindow returns as a flat fill - and off
# the input desktop there is no composite to GetPixel either. So it was DROPPED
# rather than weakened into an assertion that scores a blank fill.
#
# Section 1 now asserts it TWICE, on two different sides of the boundary. The
# banner band is the GDI half: a layered popup whose band the product fills
# with the pane's effective background (pane-banner.ps1 pins the same corner
# pixel), so it proves the tint reaches native painted output. The pane capture
# is the glass itself - the debug-only `capture-pane` IPC action has the pane's
# OWN renderer read back its content (`lib\PaneCapture.ps1`), which needs no
# desktop and no composite, so the GL clear color is finally assertable here.
#
# -NegativeControl expects the picker to apply #334455 (a color it never
# picks) instead of the configured background, which MUST fail: that value is
# only reachable through right-click -> menu -> mnemonic -> dialog -> Enter ->
# IPC readback, so the run proves the whole chain ran.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Always isolated, not just under -ExePath: every oracle here is an IPC probe,
# and both ends inherit this (the CLI from this shell, the GUI through the
# harness's CreateProcessW), so they address THIS run's instance and nothing
# else on the box.
$env:GHOZTTY_PIPE_SUFFIX = '-colortest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# +list --json -> the window object registered under $target, or (with an
# 'id:<hwnd>' argument) the window whose id matches - window ids are the
# decimal HWND, so a window found through the harness can be addressed exactly.
function Get-Win($target) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    foreach ($w in $data.windows) {
        if ($target -like 'id:*') { if ($w.id -eq $target.Substring(3)) { return $w } }
        elseif ($w.target -eq $target) { return $w }
    }
    return $null
}

# All leaf terminals of a splits node, in traversal order.
function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

# Poll for a pane tint: window $target, leaf index $i, expected value (or
# 'ANY' for present, 'NONE' for absent). Returns the observed value.
function Wait-Tint($target, [int]$i, [string]$expect) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) {
            $leaves = @(Get-Leaves $w.tabs[0].splits)
            if ($leaves.Count -gt $i) {
                $tint = $leaves[$i].background_tint
                if ($expect -eq 'NONE' -and -not $tint) { return '(absent)' }
                if ($expect -eq 'ANY' -and $tint) { return $tint }
                if ($tint -eq $expect) { return $tint }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    $w = Get-Win $target
    if ($w) {
        $leaves = @(Get-Leaves $w.tabs[0].splits)
        if ($leaves.Count -gt $i -and $leaves[$i].background_tint) { return $leaves[$i].background_tint }
    }
    return '(absent)'
}

# The banner overlay glued above pane $Pane (same left edge, its bottom at the
# pane's top - T101 reserves the band above the terminal), or $null.
function Get-Overlay([int]$procId, $Pane) {
    foreach ($o in @(Get-TestWindows -ProcessId $procId -Class 'GhozttyBannerOverlay')) {
        if ([math]::Abs($o.Left - $Pane.Left) -le 2 -and
            [math]::Abs($o.Bottom - $Pane.Top) -le 2) { return $o }
    }
    return $null
}

# "r,g,b" at a WINDOW-coordinate point of a capture ('' when off the shot).
function Get-ShotPx($shot, [int]$x, [int]$y) {
    if ($x -lt 0 -or $y -lt 0 -or $x -ge $shot.Width -or $y -ge $shot.Height) { return '' }
    $c = $shot.Bitmap.GetPixel($x, $y)
    return "$($c.R),$($c.G),$($c.B)"
}

# Raise a banner on $target's pane and read the band corner of its overlay,
# which the product fills with the pane's EFFECTIVE background. Returns
# @{ Px = 'r,g,b'; Colors = <distinct colors in the capture> } - the caller
# scores the color guard itself, because "no ink" is satisfied for entirely
# the wrong reason by an empty capture.
function Measure-BannerBand([int]$procId, [IntPtr]$top, [string]$target) {
    & $exe +set-banner --target=$target 'tint probe' | Out-Null
    $overlay = $null
    for ($t = 0; $t -lt 40 -and -not $overlay; $t++) {
        Start-Sleep -Milliseconds 150
        $pane = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
        if ($pane.Count -ge 1) { $overlay = Get-Overlay $procId $pane[0] }
    }
    if (-not $overlay) { return @{ Px = '(no overlay)'; Colors = 0 } }
    $shot = Get-TestWindowPixels -Window ([IntPtr]$overlay.Hwnd) -Sync
    try {
        return @{
            Px = (Get-ShotPx $shot 2 2)
            Colors = (Get-TestDistinctColors -Shot $shot -Inset 2)
        }
    } finally { Close-TestWindowPixels $shot }
}

Kill-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$appPid = 0

try {

# Launch the GUI with a pinned config background so the picker section has a
# deterministic effective (untinted) background. session-persistence=false:
# a persisted session makes `+new-window --target=` idempotent against LAST
# run's pane, so the fixtures below would measure a window this run never
# created (T248).
$app = Start-OnTestDesktop -Exe $exe -Arguments @(
    '--config-default-files=false', '--session-persistence=false', '--background=#101014')
$appPid = [int]$app.Pid
$launched += $appPid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$launchTop = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
if ($launchTop -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: launch window not found'; exit 1 }
# T267 sweep: this script deliberately does NOT call Set-TestWindowSize. No
# assertion here is a ratio of the window - section 7 right-clicks the pane's
# own CENTRE (derived from its client rect, whatever that is) and the banner
# probe reads an overlay it locates by HWND. What it needed was DETERMINISM,
# not a particular size, and the launch helper now supplies it by clearing
# window_placement-debug, so every launch is the built-in 800x600 default
# instead of whatever the last GUI script left behind.
Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) `
    'GUI is NOT enumerable on the interactive desktop'

# --- 1. +new-window --color tints the first pane (model + painted band) --
& $exe +new-window --target=cw --color=`#334455 | Out-Null
$tint = Wait-Tint 'cw' 0 '#334455'
Assert ($tint -eq '#334455') "new-window --color: background_tint reported (got $tint)"

# The tint escapes the data model into pixels the app really paints. NOT the
# glass: see the header - the GL surface cannot be captured here, and this
# asserts the banner band, which the product fills with the pane's effective
# background.
# A window's `id` in +list --json IS its decimal HWND, so the tinted window is
# addressable exactly rather than by "the one that is not the launch window".
$cwWin = Get-Win 'cw'
$cwTop = if ($cwWin) { [IntPtr][int64]$cwWin.id } else { [IntPtr]::Zero }
Assert ($cwTop -ne [IntPtr]::Zero) 'the tinted window is addressable by its +list id'
$band = Measure-BannerBand $appPid $cwTop 'cw'
Assert ($band.Colors -ge 2) "banner capture holds real content ($($band.Colors) distinct colors)"
Assert ($band.Px -eq '51,68,85') `
    "new-window --color: the tint is the pane background the banner band paints (got $($band.Px))"

# ...and now THE GLASS ITSELF (T275). This is the probe T214 dropped, restored
# against pixels the pane's own renderer produced rather than a PrintWindow
# flat fill. The dominant color of a terminal capture is its background by
# definition, so it is the GL clear color the tint had to reach - a strictly
# stronger claim than the banner band above, which is GDI.
$glass = Get-TestPaneCapture -Target 'cw'
$glassDom = if ($glass) { Get-TestPaneDominantColor -Shot $glass } else { $null }
Assert ($null -ne $glass -and (Get-TestPaneColorCount -Shot $glass) -ge 4) `
    "glass capture holds real content ($(if ($glass) { "$(Get-TestPaneColorCount -Shot $glass) distinct colors" } else { Get-LastPaneCaptureError }))"
Assert (Test-PaneColorNear -Color $glassDom -R 51 -G 68 -B 85) `
    "new-window --color: the tint reached the GL clear color (dominant $glassDom)"
if ($glass) { Close-TestPaneCapture $glass }

# --- 2. plain +split inherits the shifted parent tint (exact oracle) -----
& $exe +split --target=cw --name=cp1 | Out-Null
$tint = Wait-Tint 'cw' 1 '#384b5e'
Assert ($tint -eq '#384b5e') "plain split: inherits #334455 shifted -> #384b5e (got $tint)"

# --- 3. +split --color explicit tint -------------------------------------
& $exe +split --pane=cp1 --name=cp2 --color=`#803020 | Out-Null
$tint = Wait-Tint 'cw' 2 '#803020'
Assert ($tint -eq '#803020') "split --color: explicit tint wins (got $tint)"

# --- 4. inline split: --split-color explicit, first pane untinted --------
& $exe +new-window --target=cw2 --split=right --split-color=`#204060 --name=cp3 | Out-Null
$tint = Wait-Tint 'cw2' 1 '#204060'
Assert ($tint -eq '#204060') "inline split --split-color applied (got $tint)"
$tint = Wait-Tint 'cw2' 0 'NONE'
Assert ($tint -eq '(absent)') "no --color: first pane reports no tint (got $tint)"

# --- 5. --color=random: dark, and TELLABLE APART -------------------------
# T120: the darkness assertion alone was green through the whole defect. The
# retired ranges (sat 0.2-0.3, bri 0.1-0.15) put every window on the same
# near-black, and what a viewer actually sees is the CHROMA (max - min
# channel = b * s * 255), which those ranges capped at ~11 and typically left
# near 8. So assert the floor the old code could not clear, on more than one
# window - a single sample cannot show that two windows differ.
$randomTints = @()
foreach ($n in 1..3) {
    $t = "cw3$n"
    & $exe +new-window --target=$t --color=random | Out-Null
    $tint = Wait-Tint $t 0 'ANY'
    Assert ($tint -match '^#[0-9a-f]{6}$') "random ${n}: well-formed hex tint (got $tint)"
    if ($tint -match '^#[0-9a-f]{6}$') {
        $randomTints += $tint
        $r = [Convert]::ToInt32($tint.Substring(1, 2), 16)
        $g = [Convert]::ToInt32($tint.Substring(3, 2), 16)
        $b = [Convert]::ToInt32($tint.Substring(5, 2), 16)
        $lum = (0.299 * $r + 0.587 * $g + 0.114 * $b) / 255.0
        Assert ($lum -lt 0.2) "random ${n}: dark color (luminance $([math]::Round($lum,3)))"

        $hi = [math]::Max($r, [math]::Max($g, $b))
        $lo = [math]::Min($r, [math]::Min($g, $b))
        Assert (($hi - $lo) -ge 10) "random ${n}: hue reads - chroma $($hi - $lo) >= 10 (was <= 11, typ. 8)"
        Assert ($hi -ge 32) "random ${n}: lifted off black - peak channel $hi >= 32 (was ~26)"
    }
}
Assert (($randomTints | Select-Object -Unique).Count -gt 1) `
    "random: three windows are not all the same tint ($($randomTints -join ' '))"
foreach ($n in 1..3) { & $exe +close --target="cw3$n" | Out-Null }

# --- 6. invalid --color is rejected by the CLI (shared Mac behavior) -----
# (PS 5.1 wraps redirected native stderr in ErrorRecords that terminate
# under EAP=Stop, so relax EAP around the intentionally-failing call.)
$eap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $exe +new-window --target=cw4 --color=`#zzzzzz 2>$null | Out-Null
$ErrorActionPreference = $eap
Assert ($LASTEXITCODE -ne 0) 'invalid --color: CLI rejects with nonzero exit'
Assert ($null -eq (Get-Win 'cw4')) 'invalid --color: no window created'

# --- 7. context-menu picker: right-click -> "B" -> ChooseColorW -> Enter -
# The untinted LAUNCH window's effective background is the configured
# #101014; CC_RGBINIT seeds the dialog with it, Enter (OK) applies it as an
# explicit tint, observable in +list.
#
# The old script wrapped this whole section in a SKIP branch when it could not
# take the foreground - a green run that asserted nothing (T218 batch 1's
# finding). On the test desktop focus always lands, so a failure here is a
# failure.
$expectPicked = if ($NegativeControl) { '#334455' } else { '#101014' }
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: the picker is expected to apply #334455, which it never picks - this run MUST fail'
}
$launchPane = Get-TestChildWindow -Window $launchTop -Class 'GhozttyTerminal'
Assert ($launchPane -ne [IntPtr]::Zero) 'picker: launch window pane found'
Assert (Focus-TestWindow -Window $launchTop -Child $launchPane) 'picker: launch window focused'

$pr = Get-TestWindowRect -Window $launchPane -Client
$cx = [int](($pr.Left + $pr.Right) / 2)
$cy = [int](($pr.Top + $pr.Bottom) / 2)
[void](Send-TestMouse -Window $launchTop -Target $launchPane -X $cx -Y $cy -Button right)
$menuWnd = Wait-TestPopupMenu -ProcessId $appPid -TimeoutMs 3000
Assert ($menuWnd -ne [IntPtr]::Zero) 'picker: right-click opened the context menu'

# Menu mnemonic: unique first letter executes "Background Color...".
# Send-TestControlKey posts without touching focus; Send-TestKeys would
# SetFocus first and dismiss the menu.
[void](Send-TestControlKey -Control $launchPane -Key B)
$dlg = [IntPtr]::Zero
for ($t = 0; $t -lt 30 -and $dlg -eq [IntPtr]::Zero; $t++) {
    Start-Sleep -Milliseconds 150
    $dlg = Get-TestWindow -ProcessId $appPid -Class '#32770'
}
Assert ($dlg -ne [IntPtr]::Zero) 'picker: ChooseColorW dialog opened from the context menu'
if ($dlg -ne [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 300
    # Post Enter at the FOCUSED control, not at the dialog: comdlg32 runs the
    # standard IsDialogMessage pump, and that is where a hardware Return lands
    # (T218 batch 5). A key posted at the dialog itself is a key its focused
    # child never sees.
    $focused = Get-TestFocusedWindow -Window $dlg
    if ($focused -eq [IntPtr]::Zero) { $focused = $dlg }
    [void](Send-TestControlKey -Control $focused -Key Enter)
    $tint = Wait-Tint "id:$([int64]$launchTop)" 0 $expectPicked
    Assert ($tint -eq $expectPicked) "picker: OK applies the effective background as tint (got $tint)"
} else {
    # Never leave a stray menu up for the next section.
    [void](Send-TestControlKey -Control $launchPane -Key Escape)
}

# --- 8. app still alive and responsive -----------------------------------
$alive = -not ($app.Process -and $app.Process.HasExited)
Assert $alive 'GUI process alive after all scenarios'
$json = (& $exe +list --json 2>$null | Out-String).Trim()
Assert ($json -match '"success":true') '+list still responds'

} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live list: this runs AFTER Remove-TestDesktop
    # has emptied that one, and comparing against an empty set is an assertion
    # that passes because it checked nothing.
    $launched = @(@($launched) + @(Get-TestLaunchedPids) | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
