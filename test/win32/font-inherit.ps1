# T76 acceptance: `window-inherit-font-size` — a new split/window must
# inherit the focused pane's LIVE (ctrl+= zoomed) font size when the
# option is on (default), and snap back to the configured font-size when
# it is off.
#
# Oracle: grid columns reported by `mode con` inside each pane. All test
# panes are full-window-width down-splits, so same font <=> same column
# count; a bigger font <=> fewer columns. The new-window path (different
# pixel width) is asserted via estimated cell width = pane_px_width/cols.
#
# Positive control: the ctrl+= zoom itself — if columns do not shrink
# after 6 chords, input injection is broken and the script ABORTS (not a
# T76 verdict), per the T55 pattern.
#
# Two GUI launches: default (inherit on) and --window-inherit-font-size=false.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private win32 driver (FontDrv, with its own GrabForeground + SendInput)
# is gone; the harness supplies the equivalents.
#
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
# Isolate the IPC endpoint unconditionally: the app inherits this through
# CreateProcessW and so does every `& $exe +...` below, so the user's own
# instance is never queried or disturbed.
$env:GHOZTTY_PIPE_SUFFIX = "-fontinherittest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

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

# Visible terminal panes of a window, with the pixel width the cell-size
# estimates need. ALWAYS call as @(Get-Panes ...): PowerShell unrolls a
# function's array return, and a lone pane then arrives as a scalar whose
# .Count is $null - which reads as "0 panes" in an assertion.
function Get-Panes([IntPtr]$top) {
    @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' |
        Where-Object Visible |
        ForEach-Object {
            [pscustomobject]@{
                Hwnd = $_.Hwnd; Top = $_.Top; Width = ($_.Right - $_.Left)
            }
        })
}

# Run `mode con` in a named pane and return the Columns value for THIS
# probe. The end marker is typed with a cmd caret (T76^DONE...) so the
# literal marker string exists only in the OUTPUT, never in the echoed
# command line; the columns value is the last "Columns:" before it.
$script:probeN = 0
function Get-Cols([string]$pane) {
    $script:probeN++
    $marker = "T76DONE$($script:probeN)"
    $typed = "mode con & echo T76^DONE$($script:probeN)"
    & $exe +send-keys --target=$pane $typed Enter 2>$null | Out-Null
    for ($t = 0; $t -lt 40; $t++) {
        Start-Sleep -Milliseconds 250
        $txt = & $exe +read --name=$pane --lines=40 2>$null | Out-String
        $idx = $txt.LastIndexOf($marker)
        if ($idx -ge 0) {
            $m = [regex]::Matches($txt.Substring(0, $idx), 'Columns:\s*(\d+)')
            if ($m.Count -gt 0) { return [int]$m[$m.Count - 1].Groups[1].Value }
        }
    }
    return -1
}

function Run-Case([string]$label, [string[]]$extraArgs, [bool]$expectInherit) {
    Kill-RepoInstances

    # Mandatory: each launch writes a session-layout manifest the next one
    # would restore, so case 2 would come up with case 1's panes (T131).
    $app = Start-OnTestDesktop -Exe $exe -Arguments (@('--session-persistence=false') + $extraArgs)
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    if ((Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -Exclude $top) -ne [IntPtr]::Zero) {
        Write-Host "SETUP FAIL ($label): more than one top window"; exit 1
    }

    # Isolation, asserted per launch.
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        "$label window is NOT enumerable on the interactive desktop"

    # Pane t76a: full-width down-split running cmd (mode con needs cmd).
    & $exe +split --direction=down --name=t76a --shell=cmd "--command=echo ready-a" 2>$null | Out-Null
    Start-Sleep -Milliseconds 1200
    $panes = @(Get-Panes $top)
    Assert ($panes.Count -eq 2) "$label setup: 2 panes after split"
    if ($panes.Count -ne 2) { exit 1 }
    $paneA = $panes | Sort-Object Top | Select-Object -Last 1   # bottom = t76a

    $colsBefore = Get-Cols 't76a'
    Assert ($colsBefore -gt 0) "$label t76a default columns readable ($colsBefore)"
    if ($colsBefore -le 0) { exit 1 }

    # Zoom t76a: ctrl+= x6 (increase_font_size). Columns must shrink —
    # this doubles as the input-injection positive control.
    for ($n = 0; $n -lt 6; $n++) {
        $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Modifiers ctrl -Key plus
        if (-not $r) { Write-Host "ABORT: zoom chord not sent"; exit 1 }
    }
    Start-Sleep -Milliseconds 800
    $colsZoom = Get-Cols 't76a'
    if ($colsZoom -le 0 -or $colsZoom -ge $colsBefore) {
        Write-Host "ABORT: ctrl+= did not shrink columns ($colsBefore -> $colsZoom) - injection/zoom broken, not a T76 verdict"
        exit 1
    }
    Write-Host "OK    positive control: ctrl+= zoom shrank columns ($colsBefore -> $colsZoom)"

    # New SPLIT from the zoomed pane: same full width, so inherit on
    # means identical columns; inherit off means the default columns.
    & $exe +split --target=t76a --name=t76b --direction=down --shell=cmd "--command=echo ready-b" 2>$null | Out-Null
    Start-Sleep -Milliseconds 1200
    $colsB = Get-Cols 't76b'
    Assert ($colsB -gt 0) "$label t76b columns readable ($colsB)"
    if ($expectInherit) {
        Assert ($colsB -eq $colsZoom) "$label split INHERITED zoomed font (cols $colsB == zoomed $colsZoom)"
    } else {
        Assert ($colsB -eq $colsBefore) "$label split kept CONFIG font (cols $colsB == default $colsBefore)"
    }

    # New WINDOW from the zoomed focus chain (focused pane is t76b, which
    # itself inherited in run 1). Different pixel width, so compare
    # estimated cell width = pane_px_width / cols.
    & $exe +new-window --target=t76w --shell=cmd "--command=echo ready-w" 2>$null | Out-Null
    $newTop = [IntPtr]::Zero
    for ($t = 0; $t -lt 25; $t++) {
        Start-Sleep -Milliseconds 200
        $newTop = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -Exclude $top
        if ($newTop -ne [IntPtr]::Zero) { break }
    }
    Assert ($newTop -ne [IntPtr]::Zero) "$label new window opened"
    if ($newTop -eq [IntPtr]::Zero) { exit 1 }

    $listJson = & $exe +list --json 2>$null | ConvertFrom-Json
    $win = $listJson.data.windows | Where-Object { $_.target -eq 't76w' }
    $paneW = $win.tabs[0].splits.terminal.name
    Assert ($null -ne $paneW -and $paneW) "$label new-window pane name via +list ($paneW)"
    $colsW = Get-Cols $paneW
    Assert ($colsW -gt 0) "$label t76w columns readable ($colsW)"

    # Cell-width estimates. Pane A keeps full window width through the
    # down-splits; measure fresh rects now.
    $widthA = (@(Get-Panes $top) | Where-Object { $_.Hwnd -eq $paneA.Hwnd }).Width
    $wPanes = @(Get-Panes $newTop)
    Assert ($wPanes.Count -eq 1) "$label new window has 1 pane ($($wPanes.Count))"
    $widthW = $wPanes[0].Width
    $cellBefore = $widthA / $colsBefore
    $cellZoom = $widthA / $colsZoom
    $cellW = $widthW / $colsW
    $msg = "cellpx before={0:N2} zoom={1:N2} newwin={2:N2}" -f $cellBefore, $cellZoom, $cellW
    if ($expectInherit) {
        Assert ([math]::Abs($cellW / $cellZoom - 1) -le 0.08) "$label new window INHERITED zoomed font ($msg)"
        Assert ($cellW / $cellBefore -ge 1.15) "$label new window font is clearly bigger than config default ($msg)"
    } else {
        Assert ([math]::Abs($cellW / $cellBefore - 1) -le 0.08) "$label new window kept CONFIG font ($msg)"
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) "$label no crash"
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    # -NegativeControl inverts run 1's expectation, so a passing run proves
    # the assertion still discriminates rather than being true of everything.
    if ($NegativeControl) { Write-Host 'NEGATIVE CONTROL: run 1 asserts inherit is OFF - this run MUST fail' }
    Run-Case 'inherit-on' @() (-not $NegativeControl)
    $launched += $script:GhozttyTestDesktopPids
    Run-Case 'inherit-off' @('--window-inherit-font-size=false') $false
    $launched += $script:GhozttyTestDesktopPids
} finally {
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
