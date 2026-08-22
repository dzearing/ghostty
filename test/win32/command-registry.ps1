# T189 acceptance: the command palette runs off the SHARED command registry.
#
# T189 moved the palette's private `palette_entries` array out of Surface.zig
# into `commands.zig`, so the palette and the menu system (T143/T190) render
# one list and dispatch through one path (`Surface.performCommand`). The unit
# tests in the none lane cover the model; this script covers the two things
# only the running app can answer:
#
#   A. a command that was ALREADY in the palette still dispatches after the
#      refactor (regression: the palette is the app's most-used command
#      surface and its dispatch path was rewritten), and
#   B. a command that reached the palette only BECAUSE of the shared registry
#      dispatches too - `Show/Hide All Terminals` (toggle_visibility) had a
#      binding and no palette row before T189.
#
# Both are asserted by OUTCOME, not by reading palette text: a row that is
# absent cannot dispatch, so an outcome is proof of presence as well. A
# negative control (a filter that matches nothing) must dispatch nothing, so
# a passing A/B cannot be "Enter does something no matter what".
#
# A positive control (ctrl+k clear_screen, the T55 pattern) runs first, so an
# injection failure aborts instead of reading as a T189 regression.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private win32 driver this script used to carry is gone. Note the split
# the harness enforces: the palette is OPENED with a chord on the terminal
# surface (Send-TestKeys), but its search box is a standard EDIT, so the
# filter goes in as WM_CHAR and Enter/Escape as posted navigation keys
# (Send-TestControlText / Send-TestControlKey).
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
$errlog = Join-Path $env:TEMP 'ghoztty-command-registry-stderr.log'
# Isolate the IPC endpoint (inherited through CreateProcessW): Tab-Count must
# count THIS instance's tabs, not whatever answers the shared pipe.
$env:GHOZTTY_PIPE_SUFFIX = '-cmdregtest'

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

# Count tabs in the first window reported by `+list --json`.
function Tab-Count {
    $raw = & $exe +list --json 2>$null
    if (-not $raw) { return -1 }
    try { $j = ($raw -join "`n") | ConvertFrom-Json } catch { return -1 }
    $wins = @($j.data.windows)
    if ($wins.Count -eq 0) { return 0 }
    return @($wins[0].tabs).Count
}

# The palette popup: a top-level GhozttyTerminal (the window itself is a
# GhozttyWindow, so there is nothing to exclude).
function Find-Palette {
    Get-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyTerminal'
}

# Open the palette, type a filter, press Enter. Returns $true when the whole
# sequence was delivered.
function Invoke-Palette([IntPtr]$top, [IntPtr]$pane, [string]$filter, [string]$label) {
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    Assert ($popup -ne [IntPtr]::Zero) "$label palette opened"
    if ($popup -eq [IntPtr]::Zero) { return $false }
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    Assert ($edit -ne [IntPtr]::Zero) "$label palette search box found"
    if ($edit -eq [IntPtr]::Zero) { return $false }
    Send-TestControlText -Control $edit -Text $filter | Out-Null
    $sent = Send-TestControlKey -Control $edit -Key Enter
    Assert $sent "$label filter '$filter' + Enter delivered"
    Start-Sleep -Milliseconds 800
    return $sent
}

Kill-RepoInstances
Remove-Item $errlog -ErrorAction SilentlyContinue
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # --session-persistence=false: a restored manifest would hand this run a
    # previous section's panes (the T131/T155 trap).
    $script:app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no pane'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'
    Assert ((Tab-Count) -eq 1) 'setup: one tab'

    # --- Positive control: injection reaches binding dispatch ----------------
    $r = Send-TestKeys -Window $top -Target $pane -Modifiers ctrl -Key K   # ctrl+k
    if (-not $r) { Write-Host 'ABORT: control chord not sent'; exit 1 }
    Start-Sleep -Milliseconds 500
    if (Test-Path $errlog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T189 verdict'
            exit 1
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    # --- A. A pre-existing palette command still dispatches ------------------
    # "New Tab" shipped in the palette long before T189; after the refactor it
    # resolves through commands.registry -> Surface.performCommand. Outcome: a
    # second tab.
    if (Invoke-Palette $top $pane 'NEW TAB' 'A') {
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'A no crash dispatching a registry command'
        $tabs = Tab-Count
        # -NegativeControl inverts this one, so a passing run proves the
        # assertion discriminates rather than being true of any outcome.
        if ($NegativeControl) {
            Write-Host 'NEGATIVE CONTROL: asserting "New Tab" opened NO tab - this run MUST fail'
            Assert ($tabs -eq 1) "A (inverted): New Tab dispatched nothing (still $tabs tabs)"
        } else {
            Assert ($tabs -eq 2) "A pre-existing command `"New Tab`" dispatched (got $tabs tabs)"
        }
    }

    # --- B. Negative control: a filter that matches nothing does nothing -----
    # Runs BEFORE the visibility test, which leaves the window hidden. Without
    # this, A and C could both pass on an app that ran *something* on Enter.
    $before = Tab-Count
    if (Invoke-Palette $top $pane 'ZZZZ' 'B') {
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'B no crash on an empty filter'
        Assert ((Tab-Count) -eq $before) "B empty filter dispatched nothing (still $before tabs)"
        # Enter with nothing selected returns before the close, so the palette
        # STAYS OPEN for the user to fix their filter (Surface.handlePaletteKey ->
        # executePaletteSelection, unchanged by T189 and what VS Code and Windows
        # Terminal both do). Asserted so a future "close on Enter" change has to
        # be a decision rather than a silent one.
        $popup = Find-Palette
        Assert ($popup -ne [IntPtr]::Zero) 'B palette stays open when the filter matches nothing'
        # Close it so the next section opens a palette rather than toggling one.
        if ($popup -ne [IntPtr]::Zero) {
            $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
            if ($edit -ne [IntPtr]::Zero) { Send-TestControlKey -Control $edit -Key Escape | Out-Null }
            Start-Sleep -Milliseconds 500
            Assert ((Find-Palette) -eq [IntPtr]::Zero) 'B Escape closes the palette'
        }
    }

    # --- C. A command that only the shared registry put in the palette -------
    # `Show/Hide All Terminals` (toggle_visibility) had a binding and NO palette
    # row before T189. Outcome: the window is hidden. Asserted last because it
    # leaves the app with nothing on screen to type into.
    $pane2 = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane2 -eq [IntPtr]::Zero) { $pane2 = $pane }
    if (Invoke-Palette $top $pane2 'HIDE ALL' 'C') {
        $hidden = $false
        for ($t = 0; $t -lt 30 -and -not $hidden; $t++) {
            Start-Sleep -Milliseconds 100
            $any = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -AllowHidden
            $hidden = ($any -ne [IntPtr]::Zero) -and (-not (Test-TestWindowVisible -Window $any))
        }
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'C app alive after Show/Hide All Terminals'
        Assert $hidden 'C new registry command "Show/Hide All Terminals" dispatched (window hidden)'
        $any = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -AllowHidden
        Assert (($any -ne [IntPtr]::Zero) -and (Test-TestWindowExists -Window $any)) 'C window hidden, not destroyed'
    }
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run
    # by now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
