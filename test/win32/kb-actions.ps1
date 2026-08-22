# Keyboard-action acceptance: drives REAL key chords into the debug build's
# surface HWND and asserts GUI-side behavior.
#
#   T50: ctrl+shift+r opens the real "Rename Window" dialog (caption, edit
#        prefilled, OK/Cancel, owner-centered, owner disabled); Enter
#        commits via titleOverride (wins over shell titles, T10), Escape
#        cancels, empty text clears the override. Supersedes the T44
#        rename-edit assertions (no crash in a single-tab window).
#   T47: ctrl+k clears the primary screen (+ scrollback); on the alternate
#        screen the performable binding is unconsumed and falls through.
#   T64: injected character input (screen readers, on-screen keyboards,
#        automation) lands in both terminal input modes.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private KbDrv driver (T86 GrabForeground + SendInput) is gone.
#
# T64 is the one section the move genuinely narrows, and it says so where the
# assertions are: SendInput(KEYEVENTF_UNICODE) is exactly what a background
# desktop refuses, and a posted VK_PACKET is not a substitute (it is never
# translated - measured, see MECHANISM LIMIT in lib/TestDesktop.ps1). The
# injected-WM_CHAR handling is still covered; App.run's TranslateMessage
# exemption for VK_PACKET is not, and that residue is T222 rather than a
# label quietly left claiming more than it tests.
#
# Only touches ghoztty processes running from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\kb-actions.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$errlog = Join-Path $env:TEMP 'ghoztty-kb-actions-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue

# Isolate the IPC endpoint unconditionally - inherited by the app through
# CreateProcessW and by every `& $Exe +...` below.
$env:GHOZTTY_PIPE_SUFFIX = "-kbactionstest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# ctrl+shift+r, retried: the chord can land while the window is still
# settling. Returns the dialog HWND, or IntPtr::Zero.
function Open-RenameDialog {
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $script:top -Target $script:surface -Modifiers ctrl,shift -Key R)) { continue }
        $d = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyRenameDialog' -TimeoutMs 3000
        if ($d -ne [IntPtr]::Zero) { return $d }
    }
    return [IntPtr]::Zero
}

function Get-Dialog {
    return (Get-TestWindow -ProcessId $script:appPid -Class 'GhozttyRenameDialog')
}

# --- Setup: fresh debug instance on the test desktop -------------------------
# --session-persistence=false: a restored layout manifest would carry a
# previous run's window title into the assertions below (batch-2 lesson).
[void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {

$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
$script:appPid = $app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$script:top = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
if ($script:top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
Assert (-not (Test-TestDesktopLeak -ProcessId $script:appPid)) 'window is NOT enumerable on the interactive desktop'

# The surface the app itself considers active: GhozttyWindow gives WM_KEYDOWN
# to DefWindowProc and only forwards FOCUS to the active pane, so a chord
# posted at the window is silently dropped (batch-3 lesson).
Focus-TestWindow -Window $script:top | Out-Null
Start-Sleep -Milliseconds 500
$script:surface = [IntPtr](Get-TestFocusedWindow -Window $script:top)
Assert ((Get-TestWindowClass -Window $script:surface) -eq 'GhozttyTerminal') 'window forwarded focus to a terminal surface'

$listJson = & $Exe +list --json | ConvertFrom-Json
$pane = $listJson.data.windows[0].tabs[0].splits.terminal.name
$win = $listJson.data.windows[0].target
Assert (-not [string]::IsNullOrEmpty($pane)) 'pane name resolved from +list'

# --- T50: "Rename Window" dialog (supersedes the T44 rename-edit path) ------
$dlg = Open-RenameDialog
Assert ($dlg -ne [IntPtr]::Zero) 'T50 dialog opened on ctrl+shift+r'
Assert (-not ($app.Process -and $app.Process.HasExited)) 'T50 no crash after ctrl+shift+r (single tab)'
if ($dlg -eq [IntPtr]::Zero) {
    # In -NegativeControl mode the inverted assertion below is the whole
    # point of the run; if the section never reaches it, fail loudly rather
    # than let the control pass by skipping.
    if ($NegativeControl) { Assert $false 'NEGATIVE CONTROL never reached its inverted assertion' }
} else {
    # T92: ctrl+shift+r is prompt_window_title; the T50 dialog caption
    # follows the Mac prompt naming.
    Assert ((Get-TestWindowText -Window $dlg) -eq 'Change Window Title') 'T50 dialog caption is "Change Window Title"'
    $edit = Find-TestWindowEx -Parent $dlg -Class 'Edit'
    $okBtn = Find-TestWindowEx -Parent $dlg -Class 'BUTTON' -Title 'OK'
    $cancelBtn = Find-TestWindowEx -Parent $dlg -Class 'BUTTON' -Title 'Cancel'
    Assert ($edit -ne [IntPtr]::Zero) 'T50 dialog has an edit box'
    Assert ($okBtn -ne [IntPtr]::Zero) 'T50 dialog has an OK button'
    Assert ($cancelBtn -ne [IntPtr]::Zero) 'T50 dialog has a Cancel button'
    Assert (-not (Test-TestWindowEnabled -Window $script:top)) 'T50 owner window disabled while dialog open (modal)'
    $dr = Get-TestWindowRect -Window $dlg
    $tr = Get-TestWindowRect -Window $script:top
    $dcx = ($dr.Left + $dr.Right) / 2; $tcx = ($tr.Left + $tr.Right) / 2
    $dcy = ($dr.Top + $dr.Bottom) / 2; $tcy = ($tr.Top + $tr.Bottom) / 2
    Assert (([Math]::Abs($dcx - $tcx) -le 3) -and ([Math]::Abs($dcy - $tcy) -le 3)) 'T50 dialog centered on owner'

    # Enter commits via titleOverride. The dialog arrives PREFILLED, so the
    # value goes in with WM_SETTEXT rather than by typing (batch-2 lesson);
    # RenameDialog's keys are routed from the App.run intercept, so a posted
    # Enter does reach it (batch-3 lesson).
    Set-TestControlText -Control $edit -Text 'KBTEST_TITLE' | Out-Null
    Send-TestControlKey -Control $edit -Key Enter | Out-Null
    Start-Sleep -Milliseconds 500
    Assert ((Get-Dialog) -eq [IntPtr]::Zero) 'T50 dialog closed on Enter'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'T50 no crash after commit'
    Assert (Test-TestWindowEnabled -Window $script:top) 'T50 owner re-enabled after close'
    $list = & $Exe +list --json | Out-String
    # -NegativeControl inverts the claim the whole T50 block exists for -
    # that the dialog's commit actually renames the window. The run MUST
    # fail here; that is what proves the assertion discriminates.
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the rename does NOT commit - this run MUST fail'
        Assert ($list -notmatch 'KBTEST_TITLE') 'T50 (inverted) window title NOT committed'
    } else {
        Assert ($list -match 'KBTEST_TITLE') 'T50 window title committed (visible in +list)'
    }

    # titleOverride precedence (T10): a shell-set title updates the TAB
    # label but the window caption keeps the override.
    & $Exe +send-keys --target=$win 'title SHELLSET_TITLE' Enter | Out-Null
    Start-Sleep -Seconds 2
    $listJson2 = & $Exe +list --json | ConvertFrom-Json
    $tabTitle = $listJson2.data.windows[0].tabs[0].title
    Assert ($tabTitle -match 'SHELLSET_TITLE') 'T50 shell-set title reached the tab label'
    Assert ((Get-TestWindowText -Window $script:top) -match 'KBTEST_TITLE') 'T50 override beats shell title (T10 precedence)'

    # Reopen: edit prefilled with the current override; Escape cancels
    # without applying.
    $dlg2 = Open-RenameDialog
    Assert ($dlg2 -ne [IntPtr]::Zero) 'T50 dialog reopened'
    if ($dlg2 -ne [IntPtr]::Zero) {
        $edit2 = Find-TestWindowEx -Parent $dlg2 -Class 'Edit'
        # WM_GETTEXT, not GetWindowTextW: the latter is cross-process cached
        # for a standard control and reads stale.
        Assert ((Get-TestControlText -Control $edit2) -eq 'KBTEST_TITLE') 'T50 edit prefilled with current title'
        Set-TestControlText -Control $edit2 -Text 'SHOULD_NOT_APPLY' | Out-Null
        Send-TestControlKey -Control $edit2 -Key Escape | Out-Null
        Start-Sleep -Milliseconds 500
        Assert ((Get-Dialog) -eq [IntPtr]::Zero) 'T50 dialog closed on Escape'
        $list3 = & $Exe +list --json | Out-String
        Assert (($list3 -match 'KBTEST_TITLE') -and ($list3 -notmatch 'SHOULD_NOT_APPLY')) 'T50 Escape discarded the edit'
        Assert (Test-TestWindowEnabled -Window $script:top) 'T50 owner re-enabled after cancel'
    }

    # Reopen: empty text clears the override (reverts to shell title).
    $dlg3 = Open-RenameDialog
    Assert ($dlg3 -ne [IntPtr]::Zero) 'T50 dialog reopened for the clear case'
    if ($dlg3 -ne [IntPtr]::Zero) {
        $edit3 = Find-TestWindowEx -Parent $dlg3 -Class 'Edit'
        Set-TestControlText -Control $edit3 -Text '' | Out-Null
        Send-TestControlKey -Control $edit3 -Key Enter | Out-Null
        Start-Sleep -Milliseconds 500
        Assert ((Get-Dialog) -eq [IntPtr]::Zero) 'T50 dialog closed on empty commit'
        Assert ((Get-TestWindowText -Window $script:top) -notmatch 'KBTEST_TITLE') 'T50 empty text cleared the override'
    }
}

# --- T47: ctrl+k clears primary screen ---------------------------------------
& $Exe +send-keys --target=$win "dir C:\Windows\System32\drivers& echo KBFILL_MARKER" Enter | Out-Null
Start-Sleep -Seconds 2
$before = & $Exe +read --name=$pane --lines=40 | Out-String
Assert ($before -match 'KBFILL_MARKER') 'T47 fill landed in the pane'
if ($before -match 'KBFILL_MARKER') {
    Assert (Send-TestKeys -Window $script:top -Target $script:surface -Modifiers ctrl -Key K) 'T47 ctrl+k injected'
    Start-Sleep -Milliseconds 800
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'T47 no crash after ctrl+k'
    $after = & $Exe +read --name=$pane --lines=40 | Out-String
    Assert ($after -notmatch 'KBFILL_MARKER') 'T47 primary screen cleared'
    Assert (Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -Quiet) 'T47 clear_screen io message logged'

    # Alternate screen: the performable binding must be unconsumed.
    & $Exe +send-keys --target=$win "powershell -nop -c `"[console]::Write([char]27+'[?1049h')`"" Enter | Out-Null
    Start-Sleep -Seconds 3
    $clearsBefore = (Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -AllMatches | Measure-Object).Count
    Assert (Send-TestKeys -Window $script:top -Target $script:surface -Modifiers ctrl -Key K) 'T47 alt-screen ctrl+k injected'
    Start-Sleep -Milliseconds 800
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'T47 no crash after alt-screen ctrl+k'
    $clearsAfter = (Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -AllMatches | Measure-Object).Count
    Assert ($clearsAfter -eq $clearsBefore) 'T47 alt screen: clear_screen NOT consumed (fell through)'
}

# --- T64: INJECTED character input -------------------------------------------
# Screen readers, on-screen keyboards, and automation inject text that did not
# come from this surface's own WM_KEYDOWN. Both terminal input modes are forced
# explicitly so the test does not depend on whether ConPTY enabled win32-input
# mode (9001) on its own.
#
# COVERAGE NOTE, and it is a narrowing: on the interactive desktop this used
# SendInput(KEYEVENTF_UNICODE), so it covered the VK_PACKET keydown AND
# App.run's TranslateMessage exemption for it AND the WM_CHAR that exemption
# produces. Off the input desktop only the last is reachable - a posted
# VK_PACKET is never translated (measured; see MECHANISM LIMIT in
# lib/TestDesktop.ps1), so the packet half of the path is NOT covered here.
# Tracked as T222; the assertions below are named for what they actually
# prove rather than inheriting the old labels.
& $Exe +send-keys --target=$win "powershell -nop -c `"[console]::Write([char]27+'[?1049l')`"" Enter | Out-Null
Start-Sleep -Seconds 2
& $Exe +send-keys --target=$win "powershell -nop -c `"[console]::Write([char]27+'[?9001l')`"" Enter | Out-Null
Start-Sleep -Seconds 2

# 'a' goes in as a plain VK key: it proves the surface is live and taking real
# keys, so a failure below is about the INJECTED characters and not about
# focus having drifted.
Assert (Send-TestText -Window $script:top -Target $script:surface -Text 'a') 'T64 prefix VK key injected'
Assert (Send-TestInjectedChar -Window $script:top -Target $script:surface -Text 'uni1ok') 'T64 injected chars posted'
Start-Sleep -Milliseconds 800
$tail = & $Exe +read --name=$pane --lines=5 | Out-String
Assert ($tail -match 'auni1ok') 'T64 injected characters land in normal mode (after a real VK key)'
Send-TestKeys -Window $script:top -Target $script:surface -Key Escape | Out-Null  # clear the input line
Start-Sleep -Milliseconds 300

# Force win32-input mode (9001) ON and inject again. This is the half T64
# actually fixed: in 9001 mode an injected WM_CHAR must be re-encoded as a
# synthetic win32-input sequence rather than dropped.
& $Exe +send-keys --target=$win "powershell -nop -c `"[console]::Write([char]27+'[?9001h')`"" Enter | Out-Null
Start-Sleep -Seconds 2
Assert (Send-TestText -Window $script:top -Target $script:surface -Text 'b') 'T64 prefix VK key injected (9001)'
Assert (Send-TestInjectedChar -Window $script:top -Target $script:surface -Text 'uni2ok') 'T64 injected chars posted (9001)'
Start-Sleep -Milliseconds 800
$tail2 = & $Exe +read --name=$pane --lines=5 | Out-String
Assert ($tail2 -match 'buni2ok') 'T64 injected characters land in win32-input mode (9001)'
Assert (Select-String -Path $errlog -Pattern 'injected WM_CHAR in win32-input mode' -Quiet) 'T64 injected char routed via win32-input encoding (log oracle)'

} finally {
    # Read the launched pids BEFORE cleanup: Remove-TestDesktop empties the
    # live pid list as it kills, and an emptied list makes the leak assertion
    # below vacuous (the batch-3 lesson).
    $script:launched = @(Get-TestLaunchedPids)
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)"; exit 0 }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
