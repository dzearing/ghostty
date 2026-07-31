# T66 acceptance: reset_window_size returns to the CONFIGURED default
# (window-width/height x cell size - Mac returnToDefaultSize parity),
# not a hardcoded 800x600; with no configured size it falls back to
# 800x600. Also guards the T66 semantic fix that `initial_size`
# re-sends are store-only: a font zoom (ctrl+=) recomputes the stored
# default but must NOT live-resize the window; the next reset returns
# to the recomputed (larger-cell) default.
#
# Oracle: GetClientRect of the top-level GhozttyWindow (the harness makes
# this process per-monitor-v2 DPI aware, so pixels are physical).
#
# Actions are bound to bare F-keys and delivered as posted WM_KEYDOWN/UP to
# the surface HWND - handleKeyEvent reads the VK from wparam and mods from
# GetKeyState, so no modifier state is needed. Positive control:
# f8=toggle_maximize with an IsZoomed oracle proves posted-key dispatch
# works; if it fails the script ABORTS (not a T66 verdict).
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private win32 driver this script used to carry is gone; the harness
# supplies the equivalents (Start-OnTestDesktop, Send-TestKeys,
# Set-TestWindowSize, Test-TestWindowZoomed).
#
# LOCALAPPDATA is redirected to a throwaway dir so the T85 placement
# memory (written by the maximize control) never leaks between tests.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint: the app inherits this through CreateProcessW, so
# the user's own instance is never queried or disturbed.
$env:GHOZTTY_PIPE_SUFFIX = '-resetsizetest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

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

# "width,height" of a window's client area.
function Get-Client([IntPtr]$top) {
    $r = Get-TestWindowRect -Window $top -Client
    return "$($r.Width),$($r.Height)"
}

function Parse-WH([string]$s) {
    $c = $s -split ','
    @([int]$c[0], [int]$c[1])
}

# Poll until the client area equals "w,h" (exact) or times out; returns
# the last observed "w,h".
function Wait-Client([IntPtr]$top, [string]$want, [int]$ms = 4000) {
    $last = ''
    for ($t = 0; $t -lt [int]($ms / 200); $t++) {
        Start-Sleep -Milliseconds 200
        $last = Get-Client $top
        if ($last -eq $want) { return $last }
    }
    return $last
}

function Post-Key([IntPtr]$top, [IntPtr]$pane, [string]$key, [int]$count) {
    for ($n = 0; $n -lt $count; $n++) {
        Send-TestKeys -Window $top -Target $pane -Key $key | Out-Null
        Start-Sleep -Milliseconds 120
    }
}

# Throwaway LOCALAPPDATA: keeps the T85 placement memory out of real state.
$script:fakeLocal = Join-Path $env:TEMP ("ghoztty-t66-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $script:fakeLocal | Out-Null

# Sets $script:app / $script:top (returning an array trips PS unwrap
# rules with multiple-assignment).
function Launch([string[]]$configArgs) {
    Kill-RepoInstances
    $cliArgs = @(
        '--session-persistence=false'
        '--keybind=f9=reset_window_size'
        '--keybind=f8=toggle_maximize'
        '--keybind=f7=increase_font_size:1'
    ) + $configArgs
    $savedLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $script:fakeLocal
    try {
        $a = Start-OnTestDesktop -Exe $exe -Arguments $cliArgs
    } finally {
        $env:LOCALAPPDATA = $savedLocal
    }
    Start-Sleep -Seconds 3
    if ($a.Process -and $a.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $t = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($t -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $extra = Get-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow' -Exclude $t
    if ($extra -ne [IntPtr]::Zero) { Write-Host 'SETUP FAIL: more than one top window'; exit 1 }
    # Isolation, asserted per launch: we found the window on the test desktop
    # and it must NOT be enumerable on the user's.
    Assert (-not (Test-TestDesktopLeak -ProcessId $a.Pid)) 'window is NOT enumerable on the interactive desktop'
    $script:app = $a
    $script:top = $t
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    # --- Case A: configured window-width/height --------------------------
    # 120x20 cells is far from any cell-size multiple that lands on exactly
    # 800x600 px, so "initial != 800x600" is a meaningful assert.
    Launch @('--window-width=120', '--window-height=20')
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal pane'; exit 1 }

    $init = Get-Client $top
    $initW, $initH = Parse-WH $init
    Write-Host "INFO  configured initial client = $init"
    Assert ($initW -gt 0 -and $initH -gt 0) "cfg: initial client size readable ($init)"
    Assert (-not ($initW -eq 800 -and $initH -eq 600)) 'cfg: configured size is not the 800x600 fallback'

    # Positive control: posted f8 must maximize (posted-key dispatch works).
    Post-Key $top $pane 'F8' 1
    $zoomed = $false
    for ($t = 0; $t -lt 15; $t++) { Start-Sleep -Milliseconds 200; if (Test-TestWindowZoomed -Window $top) { $zoomed = $true; break } }
    if (-not $zoomed) {
        Write-Host 'ABORT: posted f8 did not maximize - key injection/binding broken, not a T66 verdict'
        exit 1
    }
    Write-Host 'OK    positive control: posted f8 maximized the window'
    Post-Key $top $pane 'F8' 1   # restore
    Start-Sleep -Milliseconds 600
    Assert (-not (Test-TestWindowZoomed -Window $top)) 'cfg: posted f8 again restored the window'

    # Resize away from the default, then reset must return EXACTLY to it.
    Set-TestWindowSize -Window $top -Width 240 -Height 130 -Grow | Out-Null
    Start-Sleep -Milliseconds 400
    $stretched = Get-Client $top
    Assert ($stretched -ne $init) "cfg: manual resize changed the client area ($init -> $stretched)"
    Post-Key $top $pane 'F9' 1   # reset_window_size
    $after = Wait-Client $top $init
    Assert ($after -eq $init) "cfg: reset returned to configured size ($after == $init), not 800x600"

    # Font zoom: initial_size re-sends are STORE-ONLY - the window must not
    # live-resize - but reset afterwards goes to the recomputed default.
    Post-Key $top $pane 'F7' 3   # increase_font_size x3
    Start-Sleep -Milliseconds 900
    $afterZoom = Get-Client $top
    Assert ($afterZoom -eq $init) "cfg: font zoom did not live-resize the window ($afterZoom == $init)"
    Post-Key $top $pane 'F9' 1   # reset_window_size
    Start-Sleep -Milliseconds 1200
    $reset2 = Get-Client $top
    $r2W, $r2H = Parse-WH $reset2
    # -NegativeControl inverts this expectation, so a passing run proves the
    # assertion still discriminates rather than being true of everything.
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting reset-after-zoom did NOT grow - this run MUST fail'
        Assert ($r2W -le $initW -and $r2H -le $initH) "cfg (inverted): reset after zoom did NOT grow ($reset2 vs $init)"
    } else {
        Assert ($r2W -gt $initW -and $r2H -gt $initH) "cfg: reset after zoom used the RECOMPUTED default ($reset2 > $init)"
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'cfg: no crash'
    $launched += $script:GhozttyTestDesktopPids
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    # --- Case B: no configured size -> 800x600 fallback ------------------
    Launch @()
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal pane (case B)'; exit 1 }

    Set-TestWindowSize -Window $top -Width 220 -Height 140 -Grow | Out-Null
    Start-Sleep -Milliseconds 400
    $before = Get-Client $top
    Post-Key $top $pane 'F9' 1   # reset_window_size
    $after = Wait-Client $top '800,600'
    Assert ($after -eq '800,600') "fallback: reset with no configured size went to 800x600 (was $before, got $after)"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'fallback: no crash'
    $launched += $script:GhozttyTestDesktopPids
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item -Recurse -Force $script:fakeLocal -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
