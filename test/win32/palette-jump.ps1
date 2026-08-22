# T555 acceptance: the command palette lists "Focus: <pane>" jump entries -
# one per live pane across every window, filterable by the pane's working
# directory - and selecting one focuses that pane's window and tab.
#
# WHAT THIS COVERS. The Mac palette's jumpOptions let the keyboard reach any
# pane by name; this drives the win32 twin end to end:
#
#   J1. cross-WINDOW jump: from window A, filtering by a directory only one
#       pane (in window B) sits in and pressing Enter activates window B and
#       focuses that pane.
#   J2. cross-TAB jump: from window B's second tab, the same filter + Enter
#       selects the FIRST tab again and focuses its pane - the background
#       tab's pane must be revealed, not focused while hidden
#       (IpcHandlers.focusTarget's T555 tab switch).
#   J3. negative control: a filter matching nothing leaves Enter a no-op
#       (the palette stays up), Escape still closes, and the app survives.
#
# WHAT IT DOES NOT COVER. The row RENDERING (the dimmed cwd subtitle) is
# owner-drawn and unreadable from a script; the subtitle/label derivation is
# unit-tested in the none lane (src/apprt/win32/palette_jump.zig). The filter
# matching the DIRECTORY here is itself evidence the subtitle was derived:
# no static command contains the unique dir name, so a hit means the jump
# entry carried the pane's cwd.
#
# T218 house rules: runs on a BACKGROUND Win32 desktop, never takes the
# user's foreground, and only touches ghoztty processes from this repo's
# zig-out.
#
#   powershell -NoProfile -File test\win32\palette-jump.ps1
param(
    [string]$Exe,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { $Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint before any CLI call.
$env:GHOZTTY_PIPE_SUFFIX = "-palettejump$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
}

# The palette popup is a top-level GhozttyTerminal-class window (it shares
# the surface wndproc). Every surface that has EVER opened one keeps a
# HIDDEN popup around, so "the palette is open" must mean the VISIBLE one -
# Wait-TestWindow would happily return a hidden popup from a previous arm.
function Wait-VisiblePalette([int]$TimeoutMs = 5000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 200) {
        $vis = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyTerminal' |
            Where-Object { $_.Visible })
        if ($vis.Count -ge 1) { return [IntPtr]$vis[0].Hwnd }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

function Test-PaletteVisible {
    $vis = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyTerminal' |
        Where-Object { $_.Visible })
    return ($vis.Count -ge 1)
}

# Open the palette over a pane and hand back its EDIT control.
function Open-Palette([IntPtr]$top, [IntPtr]$pane) {
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-VisiblePalette
        if ($popup -ne [IntPtr]::Zero) {
            $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
            if ($edit -ne [IntPtr]::Zero) { return @{ Popup = $popup; Edit = $edit } }
        }
    }
    return $null
}

# Focus is asynchronous (T48 deferred SetFocus), so every focus claim polls.
function Wait-PaneFocus([IntPtr]$top, [int64]$Expected, [int]$TimeoutMs = 5000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 100) {
        if ([int64](Get-TestFocusedWindow -Window $top) -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Wait-ActiveWindow([IntPtr]$probe, [int64]$Expected, [int]$TimeoutMs = 5000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 100) {
        if ([int64](Get-TestActiveWindow -Window $probe) -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# The window object registered under $target from +list --json, or $null.
# The chooser-restore recipe verbatim: Out-String (an explicit exe path
# needs a real pipe to deliver stdout), then unwrap the {data: ...}
# envelope, then @(...) every walk (PS 5.1 unrolls one-element arrays).
function Get-ListedWindow([string]$target) {
    $out = (& $Exe +list --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return $null }
    try { $j = $out | ConvertFrom-Json } catch { return $null }
    if ($null -ne $j -and $null -ne $j.data) { $j = $j.data }
    if ($null -eq $j) { return $null }
    foreach ($w in @($j.windows)) {
        if ($w.target -eq $target) { return $w }
    }
    return $null
}

# The selected tab index of the window registered under $target; -1 when
# unreadable.
function Get-SelectedTab([string]$target) {
    $win = Get-ListedWindow $target
    if ($null -eq $win) { return -1 }
    $sel = @($win.tabs) | Where-Object { $_.selected } | Select-Object -First 1
    if ($null -eq $sel) { return -1 }
    return [int]$sel.index
}

function Get-TabCount([string]$target) {
    $win = Get-ListedWindow $target
    if ($null -eq $win) { return 0 }
    return @($win.tabs).Count
}

# A directory name nothing else on the box shares - the filter that must
# match exactly one pane's cwd subtitle.
$zebraName = 'pj-zebra-unique'
$zebra = Join-Path $env:TEMP $zebraName
New-Item -ItemType Directory -Force -Path $zebra | Out-Null

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {

Write-Host '== setup: window A (repo cwd) + window B (unique cwd)'
# --session-persistence=false: a restored layout would decide pane count and
# focus.
$errlog = Join-Path $env:TEMP "ghoztty-palette-jump-$PID.log"
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
$script:appPid = $app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

$winA = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
if ($winA -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: launch window not found'; exit 1 }
Assert (-not (Test-TestDesktopLeak -ProcessId $script:appPid)) 'window is NOT enumerable on the interactive desktop'
$paneA = Get-TestChildWindow -Window $winA -Class 'GhozttyTerminal'
if ($paneA -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: window A has no pane'; exit 1 }

& $Exe +new-window --target=pjB "--working-directory=$zebra" 2>&1 | Out-Null
$deadline = (Get-Date).AddSeconds(10)
$winB = [IntPtr]::Zero
while ((Get-Date) -lt $deadline -and $winB -eq [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 400
    foreach ($w in @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyWindow')) {
        if ($w.Hwnd -ne [int64]$winA) { $winB = [IntPtr]$w.Hwnd }
    }
}
Assert ($winB -ne [IntPtr]::Zero) 'window B (pjB) opened'
if ($winB -eq [IntPtr]::Zero) { exit 1 }
$paneB = Get-TestChildWindow -Window $winB -Class 'GhozttyTerminal'
Assert ($paneB -ne [IntPtr]::Zero) 'window B has a pane'
# Give B's shell a moment to start so its cwd is readable when the palette
# snapshots.
Start-Sleep -Seconds 2

Write-Host '== positive control: the palette opens and Escape closes it'
[void](Focus-TestWindow -Window $winA -Child $paneA)
$pal = Open-Palette $winA $paneA
if ($null -eq $pal) {
    Write-Host 'ABORT: positive control failed (palette never opened) - injection broken, not a verdict'
    exit 1
}
Write-Host 'OK    positive control: ctrl+shift+p opens the palette'
Send-TestControlKey -Control $pal.Edit -Key Escape | Out-Null
Start-Sleep -Milliseconds 500
Assert (-not (Test-PaletteVisible)) 'Escape closed the palette'

Write-Host '== J1: cross-window jump - filter by the unique cwd, Enter focuses window B'
[void](Focus-TestWindow -Window $winA -Child $paneA)
Assert (Wait-PaneFocus $winA ([int64]$paneA)) 'J1 setup: focus parked on window A''s pane'
$pal = Open-Palette $winA $paneA
Assert ($null -ne $pal) 'J1 the palette opened over window A'
if ($null -ne $pal) {
    Assert (Send-TestControlText -Control $pal.Edit -Text $zebraName) 'J1 typed the unique dir name as the filter'
    Start-Sleep -Milliseconds 500
    Send-TestControlKey -Control $pal.Edit -Key Enter | Out-Null
    Assert (Wait-ActiveWindow $winA ([int64]$winB)) 'J1 window B became the active window'
    Assert (Wait-PaneFocus $winB ([int64]$paneB)) 'J1 window B''s pane took focus'
    Assert (-not (Test-PaletteVisible)) 'J1 the palette closed on Enter'
}

Write-Host '== J2: cross-tab jump - a second tab in B, then jump back to tab 0''s pane'
Assert (Send-TestKeys -Window $winB -Target $paneB -Modifiers ctrl, shift -Key T) 'J2 sent ctrl+shift+t (new tab)'
$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline -and (Get-TabCount 'pjB') -lt 2) { Start-Sleep -Milliseconds 400 }
Assert ((Get-TabCount 'pjB') -eq 2) 'J2 window B has two tabs'
Assert ((Get-SelectedTab 'pjB') -eq 1) 'J2 the new tab is selected'
# The new tab's pane is the VISIBLE terminal child now (tab 0's is hidden).
$paneB2 = Get-TestChildWindow -Window $winB -Class 'GhozttyTerminal'
Assert ($paneB2 -ne [IntPtr]::Zero -and [int64]$paneB2 -ne [int64]$paneB) 'J2 the new tab''s pane is the visible one'
$pal = Open-Palette $winB $paneB2
Assert ($null -ne $pal) 'J2 the palette opened over the second tab'
if ($null -ne $pal) {
    Assert (Send-TestControlText -Control $pal.Edit -Text $zebraName) 'J2 typed the unique dir name as the filter'
    Start-Sleep -Milliseconds 500
    Send-TestControlKey -Control $pal.Edit -Key Enter | Out-Null
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline -and (Get-SelectedTab 'pjB') -ne 0) { Start-Sleep -Milliseconds 300 }
    Assert ((Get-SelectedTab 'pjB') -eq 0) 'J2 the jump selected tab 0 again'
    Assert (Wait-PaneFocus $winB ([int64]$paneB)) 'J2 tab 0''s pane took focus'
}

Write-Host '== J3: negative control - a filter matching nothing leaves Enter a no-op'
$pal = Open-Palette $winB $paneB
Assert ($null -ne $pal) 'J3 the palette opened'
if ($null -ne $pal) {
    Assert (Send-TestControlText -Control $pal.Edit -Text 'zzqqxvv-no-such-entry') 'J3 typed a filter that matches nothing'
    Start-Sleep -Milliseconds 500
    Send-TestControlKey -Control $pal.Edit -Key Enter | Out-Null
    Start-Sleep -Milliseconds 700
    Assert (Test-PaletteVisible) 'J3 Enter on an empty list left the palette open'
    Send-TestControlKey -Control $pal.Edit -Key Escape | Out-Null
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-PaletteVisible)) 'J3 Escape still closes it'
}
Assert ($null -ne (Get-Process -Id $script:appPid -ErrorAction SilentlyContinue)) 'the app survived all arms'

} finally {
    & $Exe +close --target=pjB 2>&1 | Out-Null
    Remove-TestDesktop
    Stop-DebugGhoztty
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) {
    # A clean green run records the covered files so scripts\guard-due.ps1
    # can answer "has anyone run this harness against the code as it now
    # stands?" (T783). Red runs leave the stamp alone - red must stay due.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard palette-jump -Repo $repo 2>&1 | ForEach-Object { "  $_" }
    Write-Host "PALETTE JUMP: ALL PASS ($script:pass assertions)"
    exit 0
} else {
    Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red
    exit 1
}
