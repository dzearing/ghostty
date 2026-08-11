<#
T277 - toggle_window_float_on_top actually pins the window.

The regression this guards: `SetWindowPos(HWND_TOPMOST)` is not a reliable
report of its own outcome. With no foreground window - a background desktop, a
locked session, the moment between two windows taking focus - it returns TRUE
with GetLastError()==0 and leaves WS_EX_TOPMOST clear, and an identical call
issued immediately after lands. That is why the action read as "a feature that
does nothing" from a KEYBIND while working from the Window menu: the menu path
happened to run with a foreground window and the keybind path did not.
`win32.setTopmost` reads the ex-style back and retries; this script drives the
keybind path, which is the one that used to fail.

Sections:
  A. the bound action pins the window, and toggling again unpins it
  B. the pin propagates to the pane's banner overlay, and survives a banner
     reposition (the "legitimate topmost owner" the T142 heal protects)

NOTE (T607): a SECOND ghoztty window on the background test desktop puts the
first into a state where NOTHING can topmost it - not this app, not an external
SetWindowPos from the harness - while a non-ghoztty window (charmap) in the very
same desktop takes the bit in every condition. So this script deliberately runs
ONE window. overlay-zorder.ps1 section E is the two-window case and stays
skipped until T607 explains it.
#>
param(
    [string]$ExePath,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW) so a real
# instance on the shared pipe cannot answer for this run.
$env:GHOZTTY_PIPE_SUFFIX = '-fottest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    foreach ($name in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$name'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 800
}

function Test-Topmost([IntPtr]$h) {
    return ((Get-TestWindowStyle -Window $h -ExStyle) -band 0x8) -ne 0
}

# Activation is read back from GetGUIThreadInfo: Focus-TestWindow's return is
# about the FOCUSED hwnd, which the app moves to the pane child.
function Set-Active([IntPtr]$top, [IntPtr]$pane) {
    Focus-TestWindow -Window $top -Child $pane | Out-Null
    for ($t = 0; $t -lt 20; $t++) {
        if ((Get-TestActiveWindow -Window $top) -eq [int64]$top) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Wait-Topmost([IntPtr]$h, [bool]$want) {
    for ($t = 0; $t -lt 25; $t++) {
        if ((Test-Topmost $h) -eq $want) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # A control keybind alongside the subject: "the chord reached the app" must
    # be measured, or a dead harness reads as a broken feature.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--background=#101014',
        '--session-persistence=false',
        '--target=fot1',
        '--keybind=ctrl+shift+f7=toggle_window_float_on_top',
        '--keybind=ctrl+shift+f6=write_screen_file')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    $A = [IntPtr](@(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')[0].Hwnd)
    $pane = Get-TestChildWindow -Window $A -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal child'; exit 1 }
    if (-not (Set-Active $A $pane)) { Write-Host 'SETUP FAIL: could not activate the window'; exit 1 }

    # -----------------------------------------------------------------------
    # A. The bound action pins and unpins the window.
    # -----------------------------------------------------------------------
    Assert (-not (Test-Topmost $A)) 'A: a fresh window is not pinned'

    Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
    Assert (Wait-Topmost $A $true) 'A: the bound toggle_window_float_on_top PINS the window (WS_EX_TOPMOST)'

    Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
    Assert (Wait-Topmost $A $false) 'A: pressing it again unpins the window'

    # -----------------------------------------------------------------------
    # B. A pinned window takes its banner overlay with it, and a reposition of
    # the banner does not knock either of them out of the topmost band. This is
    # the state overlay_zorder's heal is written to leave alone.
    # -----------------------------------------------------------------------
    # Target the pane by its own id rather than a name: the window's name comes
    # from the launch flag, and a banner on the wrong target is a silent no-op
    # that would read here as "the overlay never appeared".
    $paneId = $null
    try {
        $json = (& $exe +list --json 2>$null | Out-String).Trim()
        if ($json) {
            $w = @(($json | ConvertFrom-Json).data.windows)[0]
            if ($w) { $paneId = @(@($w.tabs)[0].panes)[0].id }
        }
    } catch { }
    if (-not $paneId) {
        Write-Host "SETUP NOTE: no pane id from +list --json, falling back to the window's auto name"
        $paneId = 'window-1'
    }
    & $exe +set-banner --target=$paneId '**T277** pinned owner' | Out-Null
    $ov = $null
    for ($t = 0; $t -lt 25 -and -not $ov; $t++) {
        $ov = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyBannerOverlay')[0]
        if (-not $ov) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ov) {
        Write-Host 'SKIP B: no banner overlay window appeared'
        $script:skipped++
    } else {
        $ovHwnd = [IntPtr]$ov.Hwnd
        Set-Active $A $pane | Out-Null
        Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
        $pinned = Wait-Topmost $A $true
        Assert $pinned 'B: the window pins with a banner up'
        if ($pinned) {
            Assert (Wait-Topmost $ovHwnd $true) 'B: the pin propagates to the owned banner overlay'
            # A new banner re-lays-out and re-seats the overlay, which is where
            # a heal that cleared the propagated bit would drag the OWNER out of
            # the topmost band with it.
            & $exe +set-banner --target=$paneId '**T277** pinned owner, relaid out' | Out-Null
            Start-Sleep -Milliseconds 1500
            Assert (Test-Topmost $ovHwnd) 'B: a banner reposition PRESERVES the overlay pin'
            Assert (Test-Topmost $A) 'B: and does not knock the window itself out of the band'
            $zOv = Get-TestZIndex -Window $ovHwnd
            $zA = Get-TestZIndex -Window $A
            Assert ($zOv -lt $zA) "B: the overlay is still above its own window (ov=$zOv < win=$zA)"

            Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
            Assert (Wait-Topmost $A $false) 'B: unpinning clears the window'
            Assert (Wait-Topmost $ovHwnd $false) 'B: unpinning clears the overlay with it'
        }
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
}

if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" }
exit ([int]($script:fail -gt 0))
