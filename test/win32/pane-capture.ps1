# T275 acceptance: the debug-only `capture-pane` IPC action - reading the
# OpenGL terminal glass off the background test desktop.
#
# WHAT IS BEING PROVED, and why it needs proving. The harness's CAPTURE LIMIT
# (TestDesktop.ps1's header) says a PrintWindow of a `GhozttyTerminal` child
# comes back as a FLAT FILL off the input desktop, and there is no composite
# there to GetPixel either - so T214 DROPPED every assertion about what the
# terminal was actually showing rather than let one score green against a pane
# rendering nothing. This script asserts the route that replaces them: the app's
# own renderer hands its pixels out, through the same readback hero mode's
# carousel thumbnails already use (`Surface.heroSnap*` -> `OpenGL.captureThumb`).
#
# THE LOAD-BEARING ORACLE IS SECTION 3, and it is deliberately not "the capture
# has many colors". Two panes are given DIFFERENT background tints and each
# capture's dominant color must match ITS OWN pane's tint. A flat fill cannot
# produce two different right answers; neither can a capture that reads the
# wrong pane, a stale buffer, or the window behind it. Section 2's color count
# is the probe hero-mode.ps1 lost, restored on top of that foundation.
#
# Section 5 hides the whole window (SW_HIDE) and captures anyway, because
# "works for a pane nobody can see" is the entire point - the readback reads the
# offscreen render target, not the window's back buffer, so no desktop, no
# composite and no visibility is involved.
#
# -NegativeControl expects pane B's capture to be pane A's tint, which MUST
# fail: that is exactly the answer a flat fill or a wrong-pane read would give,
# so a green negative control means the discrimination in section 3 is not real.
#
# Runs on the BACKGROUND test desktop and never takes the user's foreground.
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolated endpoint: every oracle here is an IPC probe, and both ends inherit
# this (the CLI from this shell, the GUI through the harness's CreateProcessW),
# so they address THIS run's instance and nothing else on the box.
$env:GHOZTTY_PIPE_SUFFIX = '-capturetest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# The window object registered under $target from `+list --json`, or $null.
function Get-Win($target) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 30; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

# A capture of $target once the pane has actually produced a frame. A pane in
# the first moments of its life has presented nothing yet, and the server
# answers that with "produced no frame to capture" - a real state, not a flake,
# so it is waited out rather than asserted against.
function Wait-Capture($target, [int]$Width, [int]$Height) {
    for ($t = 0; $t -lt 25; $t++) {
        $shot = Get-TestPaneCapture -Target $target -Width $Width -Height $Height
        if ($shot) { return $shot }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

Kill-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$appPid = 0

try {

# persistence: --session-persistence=false. A persisted session makes
# `+new-window --target=` idempotent against the LAST run's pane, so every
# capture below would be of a window this run never created (T248).
$app = Start-OnTestDesktop -Exe $exe -Arguments @(
    '--config-default-files=false', '--session-persistence=false', '--background=#101014')
$appPid = [int]$app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) {
    Write-TestAssertedNothing -Reason 'GUI died at launch' -Label 'pane-capture'
}
$launchTop = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
if ($launchTop -eq [IntPtr]::Zero) {
    Write-TestAssertedNothing -Reason 'launch window never appeared' -Label 'pane-capture'
}
Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) `
    'GUI is NOT enumerable on the interactive desktop'

# --- 1. The mechanism: a capture comes back as a real image ---------------
& $exe +new-window --target=capA --color=`#204080 | Out-Null
if (-not (Wait-Win 'capA')) {
    Write-TestAssertedNothing -Reason 'window capA never registered' -Label 'pane-capture' -Skipped $script:skipped
}
$shotA = Wait-Capture 'capA'
Assert ($null -ne $shotA) "capture-pane returns an image for a live pane ($(Get-LastPaneCaptureError))"
if ($null -eq $shotA) {
    Write-TestVerdict -Pass $script:pass -Fail ($script:fail + 1) -Skipped $script:skipped -Label 'pane-capture'
}

Assert ($shotA.Bitmap.Width -eq $shotA.Width -and $shotA.Bitmap.Height -eq $shotA.Height) `
    "decoded PNG matches the reported size ($($shotA.Bitmap.Width)x$($shotA.Bitmap.Height) vs $($shotA.Width)x$($shotA.Height))"
Assert ($shotA.Width -gt 100 -and $shotA.Height -gt 100) `
    "capture defaults to the pane's own size ($($shotA.Width)x$($shotA.Height))"
Assert ($shotA.Bytes -gt 100) "capture wrote a non-trivial PNG ($($shotA.Bytes) bytes)"

# --- 2. The probe T214 dropped: the pane RENDERS CONTENT ------------------
# A pane showing a shell prompt is many colors; a flat fill is one. This is
# hero-mode.ps1's `Get-PaneColorCount >= 8` claim, restored against pixels that
# are actually the pane's.
$colorsA = Get-TestPaneColorCount -Shot $shotA
Assert ($colorsA -ge 8) "pane renders content: $colorsA distinct colors in the glass (>= 8)"

# --- 3. THE DISCRIMINATOR: each capture is of ITS OWN pane ----------------
# Two panes, two tints. The dominant color of a terminal capture is its
# background by definition (most of a pane is background), so each must report
# its own. Nothing that reads a flat fill, the wrong pane, or a stale buffer can
# get both of these right.
& $exe +new-window --target=capB --color=`#802040 | Out-Null
if (-not (Wait-Win 'capB')) {
    Write-TestVerdict -Pass $script:pass -Fail ($script:fail + 1) -Skipped $script:skipped -Label 'pane-capture'
}
$shotB = Wait-Capture 'capB'
Assert ($null -ne $shotB) "capture-pane returns an image for the second pane ($(Get-LastPaneCaptureError))"

$domA = Get-TestPaneDominantColor -Shot $shotA
$domB = if ($shotB) { Get-TestPaneDominantColor -Shot $shotB } else { $null }
Assert (Test-PaneColorNear -Color $domA -R 0x20 -G 0x40 -B 0x80) `
    "pane A's glass carries pane A's tint #204080 (dominant $domA)"
if ($NegativeControl) {
    # MUST fail: this is precisely the answer a flat fill or a wrong-pane read
    # would give, so a green here means section 3 discriminates nothing.
    Assert (Test-PaneColorNear -Color $domB -R 0x20 -G 0x40 -B 0x80) `
        "NEGATIVE CONTROL: pane B's glass carries pane A's tint (dominant $domB)"
} else {
    Assert (Test-PaneColorNear -Color $domB -R 0x80 -G 0x20 -B 0x40) `
        "pane B's glass carries pane B's tint #802040 (dominant $domB)"
    Assert ($domA -ne $domB) "the two panes' captures differ ($domA vs $domB)"
}

# --- 4. An explicit size is honoured --------------------------------------
$small = Get-TestPaneCapture -Target 'capA' -Width 64 -Height 48
Assert ($null -ne $small -and $small.Width -eq 64 -and $small.Height -eq 48) `
    "--width/--height are honoured ($(if ($small) { "$($small.Width)x$($small.Height)" } else { Get-LastPaneCaptureError }))"
if ($small) {
    # Downscaled, but still the pane: the tint survives the resize.
    Assert (Test-PaneColorNear -Color (Get-TestPaneDominantColor -Shot $small -Step 2) -R 0x20 -G 0x40 -B 0x80) `
        'a downscaled capture is still that pane'
    Close-TestPaneCapture $small
}

# --- 5. A pane nobody can see captures anyway ------------------------------
# The whole reason this route exists: the readback reads the offscreen render
# target, so window visibility is not involved. Hidden with SW_HIDE, which is
# strictly stronger than the "not focused" every capture above already was.
# `+list --json` window ids ARE the decimal HWND, so the window found through
# the registry and the window handed to the harness are the same object.
$winA = Get-Win 'capA'
$topA = if ($winA -and $winA.id) { [IntPtr][int64]$winA.id } else { $null }
if ($null -eq $topA) {
    Write-Host 'SKIP  hidden-window capture: capA has no window id to hide'
    $script:skipped++
} else {
    [void](Set-TestWindowShown -Window $topA -Show $false)
    Start-Sleep -Milliseconds 400
    $hidden = Wait-Capture 'capA'
    Assert ($null -ne $hidden) "a HIDDEN pane still captures ($(Get-LastPaneCaptureError))"
    if ($hidden) {
        Assert (Test-PaneColorNear -Color (Get-TestPaneDominantColor -Shot $hidden) -R 0x20 -G 0x40 -B 0x80) `
            'the hidden capture is still pane A'
        Assert ((Get-TestPaneColorCount -Shot $hidden) -ge 8) `
            'the hidden pane is still rendering content'
        Close-TestPaneCapture $hidden
    }
    [void](Set-TestWindowShown -Window $topA -Show $true)
}

# --- 6. Every failure names a different state ------------------------------
$miss = Invoke-GhozttyIpc -Action 'capture-pane' -Arguments @('--target=nosuchpane', "--path=$env:TEMP\nope.png")
Assert ($miss -and -not $miss.success -and "$($miss.error)" -like "*not found in registry*") `
    "an unknown target says so (got '$(if ($miss) { $miss.error } else { 'no response' })')"

& $exe +split --target=capA --name=capview --view=about:blank | Out-Null
Start-Sleep -Milliseconds 800
$viewer = Invoke-GhozttyIpc -Action 'capture-pane' -Arguments @('--target=capview', "--path=$env:TEMP\nope.png")
Assert ($viewer -and -not $viewer.success -and "$($viewer.error)" -like "*viewer pane, not a terminal*") `
    "a viewer pane is refused by name (got '$(if ($viewer) { $viewer.error } else { 'no response' })')"

$noargs = Invoke-GhozttyIpc -Action 'capture-pane' -Arguments @("--path=$env:TEMP\nope.png")
Assert ($noargs -and -not $noargs.success -and "$($noargs.error)" -like "*--target is required*") `
    "a missing --target says so (got '$(if ($noargs) { $noargs.error } else { 'no response' })')"

$badsize = Invoke-GhozttyIpc -Action 'capture-pane' -Arguments @('--target=capA', "--path=$env:TEMP\nope.png", '--width=0')
Assert ($badsize -and -not $badsize.success -and "$($badsize.error)" -like "*--width/--height*") `
    "a nonsense size is refused, not clamped (got '$(if ($badsize) { $badsize.error } else { 'no response' })')"

Assert (-not (Test-Path "$env:TEMP\nope.png")) 'a refused capture writes no file'

Close-TestPaneCapture $shotA
if ($shotB) { Close-TestPaneCapture $shotB }

# --- 7. The run never took the user's foreground ---------------------------
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "the user's foreground was never taken ($($leaked -join ', '))"
Complete-TestBody  # T1039: the run reached the end of its body

} finally {
    if ($appPid) {
        Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue
    }
    Kill-RepoInstances
    if ($td) { Remove-TestDesktop $td }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'pane-capture'
