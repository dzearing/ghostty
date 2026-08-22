# T215 acceptance: the app's reading of "which window is active" survives a
# background desktop.
#
# A background desktop (CreateDesktopW - what the whole GUI acceptance suite
# runs on since T211/T216-T218) has NO FOREGROUND WINDOW AT ALL:
# GetForegroundWindow returns 0 for every window on it. So every product site
# that asked "am I the foreground window?" answered "no" there, permanently,
# with nothing logged - a guard that stops guarding rather than one that
# fails. T211 found the first instance (deferred focus asserts were all
# dropped, so keyboard focus could not move between panes); this script pins
# the two that a caller can OBSERVE:
#
#   A/B/C  `+list --json` reports the ACTIVE window as `focused`. Pre-fix the
#          field was false for every window, always, which a caller cannot
#          tell apart from "the app is in the background".
#   D      A default-target verb (`+split` with no --target) lands in the
#          ACTIVE window. Pre-fix `frontWindow` matched nothing and fell
#          through to "the most recently created window", which is a
#          DIFFERENT window the moment a script has opened two.
#
# Both are byte-identical on the input desktop, where foreground is still the
# only thing consulted - see src/apprt/win32/window_active.zig.
#
# -NegativeControl inverts arm D (asserting the split lands in the NEWEST
# window rather than the active one) and MUST fail: that is the pre-fix
# answer, so a run that passes with it means arm D is not reading routing at
# all.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\window-active.ps1
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

# Isolate the IPC endpoint unconditionally - inherited by the app through
# CreateProcessW and by every `& $exe +...` below.
$env:GHOZTTY_PIPE_SUFFIX = "-wactest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
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

# `+list --json`'s windows, as {Id (the hwnd, decimal), Target, Focused}.
# Piped, not redirected: ghoztty.exe is GUI-subsystem, so PowerShell only
# waits for it (and captures anything) when its stdout goes to a pipe.
function Get-ListedWindows {
    $out = (& $exe +list --json 2>$null | Out-String)
    if (-not $out.Trim()) { return @() }
    $j = $out | ConvertFrom-Json
    return @($j.data.windows | ForEach-Object {
        [pscustomobject]@{ Id = [int64]$_.id; Target = $_.target; Focused = [bool]$_.focused }
    })
}

function Get-FocusedIds { @((Get-ListedWindows | Where-Object Focused | ForEach-Object { $_.Id })) }

function Count-Panes([int64]$hwnd) {
    @(Get-TestChildWindows -Window ([IntPtr]$hwnd) -Class 'GhozttyTerminal' |
        Where-Object Visible).Count
}

# Move activation to a window. The child matters: a Ghoztty top-level forwards
# WM_SETFOCUS down to its terminal surface (the T48 deferred path), so
# Focus-TestWindow's own GetFocus() check only agrees when it is told the pane
# it will end up on. Naming the top-level alone reports failure over a
# perfectly good activation.
function Activate-Window([int64]$hwnd, [string]$label) {
    $pane = Get-TestChildWindow -Window ([IntPtr]$hwnd) -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL: no pane in $label"; exit 1 }
    if (-not (Focus-TestWindow -Window ([IntPtr]$hwnd) -Child $pane)) {
        Write-Host "SETUP FAIL: could not activate $label"; exit 1
    }
    Start-Sleep -Milliseconds 400
}

Kill-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$appPid = 0

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: arm D asserts the split lands in the NEWEST window - this run MUST fail'
    }

    # --session-persistence=false: each launch would otherwise write a layout
    # manifest that the next one restores (T131).
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    $appPid = $app.Pid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $w1 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($w1 -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: first window not found'; exit 1 }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'window is NOT enumerable on the interactive desktop'

    # A second, NEWER window. Everything below turns on w1 (older) being the
    # active one while w2 (newer) is what a "most recently created" fallback
    # would pick.
    & $exe +new-window --target=wa2 | Out-Null
    Start-Sleep -Seconds 2
    $tops = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object Visible)
    Assert ($tops.Count -eq 2) "setup: 2 top-level windows (saw $($tops.Count))"
    if ($tops.Count -ne 2) { exit 1 }
    $w2 = [int64]($tops | Where-Object { $_.Hwnd -ne [int64]$w1 } | Select-Object -First 1).Hwnd

    # ---- A: exactly one window reports focused -------------------------
    Activate-Window ([int64]$w1) 'w1'
    $focused = Get-FocusedIds
    Assert ($focused.Count -eq 1) `
        "A: +list --json reports exactly one focused window (saw $($focused.Count))"

    # ---- B: and it is the one we activated -----------------------------
    Assert ($focused.Count -eq 1 -and $focused[0] -eq [int64]$w1) `
        'B: the focused window is the one activation was moved to (w1)'

    # ---- C: it FOLLOWS activation --------------------------------------
    # A field hardcoded true for, say, the first window would pass A and B;
    # only moving activation tells the two apart.
    Activate-Window $w2 'w2'
    $focused2 = Get-FocusedIds
    Assert ($focused2.Count -eq 1 -and $focused2[0] -eq $w2) `
        'C: moving activation to w2 moves `focused` with it'

    # ---- D: a default-target verb follows activation, not creation -----
    # Back to w1 (the OLDER window), then split with no --target at all.
    Activate-Window ([int64]$w1) 'w1 (again)'
    $before1 = Count-Panes ([int64]$w1)
    $before2 = Count-Panes $w2
    & $exe +split --direction=right | Out-Null
    Start-Sleep -Milliseconds 1200
    $after1 = Count-Panes ([int64]$w1)
    $after2 = Count-Panes $w2
    Write-Host "      panes w1 $before1 -> $after1 , w2 $before2 -> $after2"
    if ($NegativeControl) {
        Assert ($after2 -eq $before2 + 1 -and $after1 -eq $before1) `
            'D: the untargeted split landed in the NEWEST window (negative control)'
    } else {
        Assert ($after1 -eq $before1 + 1) 'D: the untargeted split landed in the ACTIVE window (w1)'
        Assert ($after2 -eq $before2) 'D: ...and not in the most recently created one (w2)'
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    $launched += $script:GhozttyTestDesktopPids
} finally {
    if ($appPid) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Kill-RepoInstances
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
