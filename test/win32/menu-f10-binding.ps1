# T575 acceptance: a user binding on F10 fires, and does not open the menu.
#
# F10 opens the menu bar on Windows, and `Surface.trackMenuActivation` claims
# the key before `keyCallback` ever sees it (T190). Claiming it UNCONDITIONALLY
# meant a `keybind = f10=...` was accepted by the config and then silently never
# dispatched - and the menu it opened instead swallowed every following key, so
# the keyboard read as stuck. This script is the oracle for the narrowing: the
# binding wins where the user stated an intent, the platform default survives
# everywhere else.
#
# Four launches, because a keybind set is app-wide and each phase needs a
# different one:
#
#   A: `--keybind=f10=new_tab` - F10 opens a TAB and NO menu.
#   B: no f10 binding at all - F10 opens the MENU and no tab. This is the
#      positive control for A's "no menu appeared": without it, a build that
#      broke menu activation outright would pass A, C and D vacuously.
#   C: `--keybind=f9>f10=new_tab` - F10 as the SECOND HALF of a sequence still
#      reaches the binding, which is the case the sketch in T575 named as the
#      one that must not open a menu.
#   D: `--keybind=f7=activate_key_table:t575` + `--keybind=t575/f10=new_tab` -
#      the same for an active key table.
#
# ORACLES, both by outcome and both structural:
#
#   - THE ACTION: the tab count from `+list --json`, polled (opening a tab is
#     asynchronous - the key posts a message, the app then spawns a shell). Not
#     the debug log, so the script measures the same thing against a release
#     build.
#   - THE MENU: the live popup window (class #32768) owned by this app's pid,
#     via Wait-TestPopupMenu. "No menu" is asserted with a real wait, not a
#     single glance.
#
# F10 is delivered as WM_SYSKEYDOWN/WM_SYSKEYUP (Send-TestSysKey), which is how
# Windows delivers it for real; f9 and f7 are ordinary posted key messages.
# Unmodified function keys throughout: a posted WM_KEYDOWN carries no modifier
# state off the input desktop, so a chord-based binding would be untestable
# here while a function key exercises the identical core path.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never takes
# the user's foreground - asserted, not assumed.
#
# -NegativeControl inverts A's expectation (it demands that F10 open the menu
# even with a binding) and MUST fail; it is how a run proves the menu probe
# reads the live popup rather than returning a constant.
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
# Always isolate the IPC endpoint: the app inherits this env through
# CreateProcessW and so does every `& $exe +...` below, so the user's own
# instance is never queried or disturbed.
$env:GHOZTTY_PIPE_SUFFIX = "-f10bindtest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function List-Json { & $exe +list --json 2>$null | ConvertFrom-Json }

# The `@()` is load-bearing: a function's array return UNROLLS in PS 5.1, so a
# one-element result arrives as a bare object whose `.Count` is $null.
function Tab-Count {
    try { return @((List-Json).data.windows[0].tabs).Count } catch { return -1 }
}

# Poll until the window reports $want tabs. Opening a tab is asynchronous, so a
# fixed sleep is a bet on box load rather than an oracle (the T1110 lesson).
function Wait-TabCount([int]$want, [int]$ms = 8000) {
    $last = -1
    for ($t = 0; $t -lt $ms; $t += 250) {
        $last = Tab-Count
        if ($last -eq $want) { return $last }
        Start-Sleep -Milliseconds 250
    }
    return $last
}

function Wait-Menu([int]$gpid, [int]$ms = 3000) {
    Wait-TestPopupMenu -ProcessId $gpid -TimeoutMs $ms
}

function Close-Menu([IntPtr]$top, [int]$gpid) {
    # A menu is modal and owns the keyboard, so the Escape that dismisses it is
    # sent at the control, not posted at the pane (menu-bar.ps1's Send-MenuKey).
    [void](Send-TestControlKey -Control $top -Key Escape)
    for ($t = 0; $t -lt 2000; $t += 100) {
        if ((Get-TestWindow -ProcessId $gpid -Class '#32768') -eq [IntPtr]::Zero) { return }
        Start-Sleep -Milliseconds 100
    }
}

function Stop-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# One phase: launch with $Arguments, hand the caller the window + pane, tear the
# app back down. Every phase needs its own keybind set, and a keybind set is
# app-wide, so a phase IS a launch.
function Invoke-Phase([string[]]$Arguments, [scriptblock]$Body) {
    Stop-RepoInstances
    # --session-persistence=false is mandatory: a launch writes a
    # session-layout manifest that the NEXT phase would restore, so phase B
    # would come up holding phase A's second tab.
    $args2 = @('--session-persistence=false', '--background=#101014') + $Arguments
    $app = Start-OnTestDesktop -Exe $exe -Arguments $args2
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal pane'; exit 1 }
    try {
        & $Body $app $top $pane
    } finally {
        # Mark the corpse as OURS before making one. The harness reports every
        # launch that died UNMARKED as a crash with a postmortem block (T527),
        # and a phase that ends by killing its own app is not a crash - four
        # such blocks in a green run is exactly the noise that teaches a reader
        # to skip the log.
        foreach ($r in $script:GhozttyTestDesktopLaunches) {
            if ($r.Pid -eq $app.Pid) { $r.Killed = $true }
        }
        Stop-RepoInstances
    }
}

function Send-F10([IntPtr]$pane) {
    [void](Send-TestSysKey -Window $pane -Key F10 -Action down)
    [void](Send-TestSysKey -Window $pane -Key F10 -Action up)
}

# T1110: the teardown block that reaps this build's app AND agent at the end.
Register-RepoBuildTeardown -Exe $exe | Out-Null

Stop-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: section A asserts a BOUND F10 opens the menu - this run MUST fail'
    }

    # -----------------------------------------------------------------------
    # A. A bound F10 fires the binding and leaves the menu shut.
    # -----------------------------------------------------------------------
    Invoke-Phase @('--keybind=f10=new_tab') {
        param($app, $top, $pane)

        Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
            'A: the window is NOT enumerable on the interactive desktop'

        $before = Tab-Count
        Assert ($before -eq 1) "A: one tab before the press (got $before)"

        Send-F10 $pane

        $after = Wait-TabCount 2
        Assert ($after -eq 2) "A: F10 dispatched its binding - a tab opened ($before -> $after)"

        $script:negReached = $true
        $m = Wait-Menu $app.Pid 2000
        $opened = ($m -ne [IntPtr]::Zero)
        if ($NegativeControl) {
            Assert $opened 'A(neg): F10 opens the menu even though it is bound'
        } else {
            Assert (-not $opened) 'A: F10 did NOT open the menu while it is bound'
        }
        if ($opened) { Close-Menu $top $app.Pid }
    }

    # -----------------------------------------------------------------------
    # B. With no binding, the platform default is untouched. POSITIVE CONTROL
    #    for every "no menu" assertion above and below.
    # -----------------------------------------------------------------------
    Invoke-Phase @() {
        param($app, $top, $pane)

        $before = Tab-Count
        Send-F10 $pane

        $m = Wait-Menu $app.Pid 3000
        Assert ($m -ne [IntPtr]::Zero) 'B: an UNBOUND F10 still opens the menu (the Windows default survives)'
        if ($m -ne [IntPtr]::Zero) { Close-Menu $top $app.Pid }

        $after = Tab-Count
        Assert ($after -eq $before) "B: and it opened no tab ($before -> $after)"
    }

    # -----------------------------------------------------------------------
    # C. F10 as the second half of a SEQUENCE.
    # -----------------------------------------------------------------------
    Invoke-Phase @('--keybind=f9>f10=new_tab') {
        param($app, $top, $pane)

        $before = Tab-Count
        Assert (Send-TestKeys -Window $top -Target $pane -Key f9) 'C: f9 (first half of the sequence) delivered'
        Start-Sleep -Milliseconds 400
        Send-F10 $pane

        $after = Wait-TabCount ($before + 1)
        Assert ($after -eq ($before + 1)) "C: f9>f10 completed the sequence and opened a tab ($before -> $after)"

        $m = Wait-Menu $app.Pid 2000
        Assert ($m -eq [IntPtr]::Zero) 'C: the sequence key did NOT open the menu'
        if ($m -ne [IntPtr]::Zero) { Close-Menu $top $app.Pid }
    }

    # -----------------------------------------------------------------------
    # D. F10 as a trigger inside an ACTIVE KEY TABLE.
    # -----------------------------------------------------------------------
    Invoke-Phase @('--keybind=f7=activate_key_table:t575', '--keybind=t575/f10=new_tab') {
        param($app, $top, $pane)

        $before = Tab-Count
        Assert (Send-TestKeys -Window $top -Target $pane -Key f7) 'D: f7 (the table activation) delivered'
        Start-Sleep -Milliseconds 400
        Send-F10 $pane

        $after = Wait-TabCount ($before + 1)
        Assert ($after -eq ($before + 1)) "D: the table's f10 fired and opened a tab ($before -> $after)"

        $m = Wait-Menu $app.Pid 2000
        Assert ($m -eq [IntPtr]::Zero) 'D: the table key did NOT open the menu'
        if ($m -ne [IntPtr]::Zero) { Close-Menu $top $app.Pid }
    }
} finally {
    Remove-TestDesktop
    # Path-exact, so it can only ever reach zig-out's app and agent, never the
    # ones the user's install is running.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live list: this runs AFTER Remove-TestDesktop
    # has emptied that one, and comparing against an empty set is an assertion
    # that passes because it checked nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

if ($NegativeControl -and -not $script:negReached) {
    Write-Host 'NEGATIVE CONTROL NEVER REACHED - the inverted assertion did not run' -ForegroundColor Red
    exit 1
}
# A green run stamps the covered files (T783/T987) so guard-due can answer "has
# this harness been run against the F10 rule as it now stands?". Red leaves the
# stamp alone: red stays due.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard menu-f10-binding -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)"; exit 0 }
Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red
exit 1
