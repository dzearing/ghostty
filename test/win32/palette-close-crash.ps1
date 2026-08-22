# T613: closing a window that has EVER opened one of the surface popups must
# not take the process down.
#
# THE DEFECT. `App.surfaceWndProc` serves three windows - the terminal child
# HWND, the search-bar popup and the command-palette popup - and its WM_DESTROY
# handler cleared `Surface.hwnd` for all three. `Surface.deinit` destroys the
# two popups a few lines BEFORE it clears the terminal window's GWLP_USERDATA,
# so the popup's WM_DESTROY nulled `hwnd`, the trailing `if (self.hwnd)` did
# nothing, and the terminal window went into `DestroyWindow` still holding a
# `*Surface` freed moments later. Win32 dispatches that window's WM_DESTROY
# through OPENGL32's `wglWndProc` subclass into the same procedure, which read
# the freed pointer: a hard segfault taking every window and every terminal in
# the process with it.
#
# WHY IT LOOKED LIKE AN ACTIVITY-MONITOR BUG. It was found closing a remote
# window with the Activity Monitor open (`activity-monitor-remote.ps1` G4), and
# "with no panel open" did not crash - because reaching the panel means opening
# the command PALETTE. The panel was the passenger. Nothing here is remote,
# nothing here needs an agent, and one arm never touches the palette at all.
#
# WHAT EACH ARM ADDS:
#   A. the palette, then `+close` - the plain CLI path.
#   B. the palette, then the title-bar X (real WM_SYSCOMMAND SC_CLOSE), because
#      that is the path a user actually takes and it is a different caller.
#   C. the SEARCH bar instead of the palette - the other popup with the same
#      wndproc and the same field, so the fix is not palette-shaped.
#
# The oracle is the process, not the screen: a crash is not a failed assertion
# anywhere, it is the absence of a pid. Each arm therefore also asserts the
# OTHER window is still there, which is what "the app survived" has to mean.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and asserts at the end that it
# never took the user's foreground.
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$errlog = Join-Path $env:TEMP 'ghoztty-palette-close-stderr.log'
$env:GHOZTTY_PIPE_SUFFIX = "-paletteclose$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

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
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
}

function Get-Tops { return @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow' | ForEach-Object { [IntPtr]$_.Hwnd }) }

# Open a named window and hand back its top HWND, by diffing the window set.
function New-NamedWindow([string]$name) {
    $before = Get-Tops
    cmd /c "`"$exe`" +new-window --target=$name > nul 2>&1" | Out-Null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        foreach ($h in Get-Tops) { if ($before -notcontains $h) { return $h } }
    }
    return [IntPtr]::Zero
}

# ctrl+shift+p, wait for the palette popup, Escape it back out. The popup uses
# the TERMINAL window class (it shares the surface wndproc - which is the whole
# point of this script), so that is what identifies it.
function Open-AndClosePalette([IntPtr]$top, [IntPtr]$pane) {
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    if ($popup -eq [IntPtr]::Zero) { return $false }
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($edit -ne [IntPtr]::Zero) { Send-TestControlKey -Control $edit -Key Escape | Out-Null }
    Start-Sleep -Milliseconds 500
    return $true
}

# ctrl+shift+f opens the search bar; Escape closes it. Its popup is a
# TERMINAL-class window too, and the count label is what tells it from the
# palette (which has only an EDIT).
function Open-AndCloseSearch([IntPtr]$top, [IntPtr]$pane) {
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key F)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    if ($popup -eq [IntPtr]::Zero) { return $false }
    $label = Find-TestWindowEx -Parent $popup -Class 'STATIC'
    if ($label -eq [IntPtr]::Zero) { return $false }   # that was the palette, not the search bar
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($edit -ne [IntPtr]::Zero) { Send-TestControlKey -Control $edit -Key Escape | Out-Null }
    Start-Sleep -Milliseconds 500
    return $true
}

function Test-AppAlive { return $null -ne (Get-Process -Id $script:app.Pid -ErrorAction SilentlyContinue) }

Kill-RepoInstances
Remove-Item $errlog -ErrorAction SilentlyContinue
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # persistence: explicitly OFF - a restored manifest would hand this run a
    # previous run's panes and windows, and every arm counts windows.
    $script:app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $home1 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($home1 -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    # --- Positive control: the chord injection works at all ------------------
    $homePane = Get-TestChildWindow -Window $home1 -Class 'GhozttyTerminal'
    if ($homePane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: home window has no pane'; exit 1 }
    if (-not (Open-AndClosePalette $home1 $homePane)) {
        Write-Host 'ABORT: positive control failed (palette never opened) - injection broken, not a verdict'
        exit 1
    }
    Write-Host 'OK    positive control: ctrl+shift+p opens the palette'

    # --- A. palette, then `+close` ------------------------------------------
    $wA = New-NamedWindow 'pcA'
    Assert ($wA -ne [IntPtr]::Zero) 'A a second window opened'
    if ($wA -ne [IntPtr]::Zero) {
        $paneA = Get-TestChildWindow -Window $wA -Class 'GhozttyTerminal'
        Assert (Open-AndClosePalette $wA $paneA) 'A the palette opened in it'
        cmd /c "`"$exe`" +close --target=pcA > nul 2>&1" | Out-Null
        Start-Sleep -Seconds 3
        Assert (Test-AppAlive) 'A the app survived +close on a window that had opened the palette'
        if (Test-AppAlive) {
            Assert ((Get-Tops).Count -ge 1) 'A the first window is still open'
        }
    }

    if (-not (Test-AppAlive)) { Write-Host 'ABORT: the app is gone; later arms have nothing to run against'; exit 1 }

    # --- B. palette, then the title-bar X ------------------------------------
    $wB = New-NamedWindow 'pcB'
    Assert ($wB -ne [IntPtr]::Zero) 'B a window opened for the title-bar close'
    if ($wB -ne [IntPtr]::Zero) {
        $paneB = Get-TestChildWindow -Window $wB -Class 'GhozttyTerminal'
        Assert (Open-AndClosePalette $wB $paneB) 'B the palette opened in it'
        Assert (Send-TestSysCommand -Window $wB -Command close) 'B SC_CLOSE was delivered'
        Start-Sleep -Seconds 3
        Assert (Test-AppAlive) 'B the app survived the title-bar X on a window that had opened the palette'
        if (Test-AppAlive) {
            Assert ((Get-Tops) -notcontains $wB) 'B that window really closed'
        }
    }

    if (-not (Test-AppAlive)) { Write-Host 'ABORT: the app is gone; the last arm has nothing to run against'; exit 1 }

    # --- C. the SEARCH bar, then `+close` ------------------------------------
    $wC = New-NamedWindow 'pcC'
    Assert ($wC -ne [IntPtr]::Zero) 'C a window opened for the search-bar arm'
    if ($wC -ne [IntPtr]::Zero) {
        $paneC = Get-TestChildWindow -Window $wC -Class 'GhozttyTerminal'
        if (Open-AndCloseSearch $wC $paneC) {
            $script:pass++; Write-Host 'PASS  C the search bar opened in it'
            cmd /c "`"$exe`" +close --target=pcC > nul 2>&1" | Out-Null
            Start-Sleep -Seconds 3
            Assert (Test-AppAlive) 'C the app survived +close on a window that had opened the SEARCH bar'
        } else {
            Write-Host 'SKIP  C search bar: ctrl+shift+f did not raise the search popup'
            $script:skipped++
        }
    }
} finally {
    foreach ($n in @('pcA', 'pcB', 'pcC')) {
        cmd /c "`"$exe`" +close --target=$n > nul 2>&1" | Out-Null
    }
    Remove-TestDesktop
    Kill-RepoInstances
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
    Write-Host "PALETTE CLOSE CRASH: ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
    exit 0
} else {
    Write-Host "$script:fail FAILURE(S) ($script:pass passed$(if ($script:skipped) { ", $script:skipped SKIPPED" }))" -ForegroundColor Red
    exit 1
}
