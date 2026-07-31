# T211 acceptance: the shared test-desktop harness itself.
#
# test/win32/lib/TestDesktop.ps1 is what every other GUI acceptance script is
# about to depend on (T212/T213), so it needs its own coverage: a harness that
# silently stops delivering input or silently captures a blank bitmap would
# turn the whole suite green for the wrong reason.
#
# Each mechanism the harness replaces is exercised end-to-end against a real
# ghoztty on a background desktop, and asserted by OUTCOME read back over IPC
# or from the window tree - never by "the call returned true":
#
#   desktop     the window exists on the test desktop and is NOT enumerable on
#               the interactive one, and nothing we launch ever takes
#               foreground there (the user's actual complaint).
#   focus       Focus-TestWindow, which replaces the T86 GrabForeground that
#               cannot work off the input desktop.
#   text        Send-TestText into a terminal -> the characters appear in
#               +read, exactly once (posting WM_CHAR as well as WM_KEYDOWN
#               doubles every character; the T207 spike hit that).
#   chords      Send-TestKeys ctrl+shift+t -> a second tab in +list.
#   controls    Send-TestControlText/Key into the rename dialog's EDIT, which
#               is the OPPOSITE convention (standard controls need WM_CHAR,
#               and nothing translates a posted message) -> the window title
#               changes.
#   capture     Get-TestWindowPixels via PrintWindow(PW_RENDERFULLCONTENT),
#               the only capture that survives off the input desktop.
#
# The capture assertion carries its own negative control: the SAME probe runs
# against a light window and a dark one and must separate them. A blank or
# stale bitmap cannot pass both.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = '-harnesstest'

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

function Get-Tree {
    $raw = & $exe +list --json 2>$null
    if (-not $raw) { return $null }
    try { return ($raw -join "`n") | ConvertFrom-Json } catch { return $null }
}

function Get-TabCount {
    $j = Get-Tree
    if (-not $j) { return -1 }
    return @($j.data.windows[0].tabs).Count
}

# Mean luminance of the window's TITLEBAR band, via the harness's only working
# capture path. The titlebar on purpose: PrintWindow on a background desktop
# returns GDI-painted chrome and NOT the OpenGL terminal surface (see the
# harness header), so a probe aimed at the terminal would read a flat fill and
# "pass" against nothing.
function Measure-TitlebarLuminance([IntPtr]$Window) {
    $shot = Get-TestWindowPixels -Window $Window
    try {
        # Parenthesised: in a PowerShell array literal the comma binds tighter
        # than `+`, so unbracketed arithmetic concatenates arrays instead.
        $r = @(($shot.Left + 6), ($shot.Top + 6), ($shot.Left + $shot.Width - 6), ($shot.Top + 34))
        return Get-TestBrightness -Shot $shot -Rect $r -Inset 0 -Step 2
    } finally { Close-TestWindowPixels $shot }
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    # ---------------------------------------------------------------------
    # A. desktop + focus + input, on a LIGHT window (also the bright half of
    #    the capture control).
    # ---------------------------------------------------------------------
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--session-persistence=false', '--window-theme=light', '--window-show-tab-bar=always')
    $launched += $app.Pid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Assert ($top -ne [IntPtr]::Zero) 'Wait-TestWindow finds the window ON the test desktop'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no window'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'the window is NOT enumerable on the interactive desktop'

    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    Assert ($pane -ne [IntPtr]::Zero) 'Get-TestChildWindow finds the terminal surface'

    $r = Get-TestWindowRect -Window $top
    Assert ($r.Width -gt 100 -and $r.Height -gt 100) "Get-TestWindowRect returns a real rect ($($r.Width)x$($r.Height))"

    # --- focus: what replaces GrabForeground off the input desktop.
    Assert (Focus-TestWindow -Window $top -Child $pane) 'Focus-TestWindow reports focus taken'
    Assert ((Get-TestFocusedWindow -Window $top) -eq ([int64]$pane)) `
        'Get-TestFocusedWindow agrees the pane holds focus'

    # --- text into a TERMINAL: WM_KEYDOWN only. Doubling is the failure mode
    #     to watch for, so it is asserted directly.
    $token = 'harness-ok-42'
    Send-TestText -Window $top -Target $pane -Text "echo $token" | Out-Null
    Send-TestKeys -Window $top -Target $pane -Key Enter | Out-Null
    Start-Sleep -Milliseconds 1200
    $paneName = $null
    $j = Get-Tree
    if ($j) { $paneName = $j.data.windows[0].tabs[0].splits.terminal.name }
    $paneText = ''
    if ($paneName) { $paneText = (& $exe +read --name=$paneName --lines=20 2>&1 | Out-String) }
    Assert ($paneText -match [regex]::Escape($token)) "Send-TestText delivered '$token' to the terminal"
    Assert (-not ($paneText -match 'hhaarrnneessss')) 'Send-TestText did NOT double characters (no WM_CHAR)'

    # --- a modifier CHORD: ctrl+shift+t must add a tab.
    Assert ((Get-TabCount) -eq 1) 'setup: one tab before the chord'
    Send-TestKeys -Window $top -Target $pane -Modifiers ctrl,shift -Key T | Out-Null
    Start-Sleep -Milliseconds 1000
    Assert ((Get-TabCount) -eq 2) 'Send-TestKeys ctrl+shift+t fired its keybind (2 tabs)'

    # --- capture, bright half.
    $lightLum = Measure-TitlebarLuminance $top
    Write-Host "capture: light titlebar meanLum=$lightLum"
    Assert ($lightLum -gt 150) "Get-TestWindowPixels returns REAL chrome for a light window (meanLum=$lightLum)"

    # --- standard controls: the rename dialog's EDIT. Opposite convention to
    #     the terminal - WM_CHAR, because nothing translates a posted message.
    $title = 'HarnessTitle'
    Send-TestKeys -Window $top -Target $pane -Modifiers ctrl,shift -Key R | Out-Null
    $dlg = [IntPtr]::Zero
    for ($t = 0; $t -lt 40 -and $dlg -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 100
        $dlg = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyRenameDialog'
    }
    Assert ($dlg -ne [IntPtr]::Zero) 'ctrl+shift+r opened the rename dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        $edit = Find-TestWindowEx -Parent $dlg -Class 'EDIT'
        Assert ($edit -ne [IntPtr]::Zero) 'rename dialog EDIT found'
        if ($edit -ne [IntPtr]::Zero) {
            # No ctrl+A first: a modifier chord does NOT survive into a
            # standard control this way. The app TranslateMessage's dialog
            # messages, and translation reads the queue's own key state rather
            # than the state we set for the posted message - so ctrl+a arrives
            # as a literal 'a'. The new text is therefore appended, which is
            # all this assertion needs.
            Send-TestControlText -Control $edit -Text $title | Out-Null
            Start-Sleep -Milliseconds 200
            Send-TestControlKey -Control $edit -Key Enter | Out-Null
            Start-Sleep -Milliseconds 700
            $wt = Get-TestWindowText -Window $top
            Assert ($wt -match [regex]::Escape($title)) `
                "Send-TestControlText typed into a standard control (window title now '$wt')"
        }
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'app alive through the whole harness run'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ---------------------------------------------------------------------
    # B. capture NEGATIVE CONTROL: the same probe on a dark window must land
    #    on the other side of the threshold. A blank (all-black) or stale
    #    bitmap cannot pass both halves.
    # ---------------------------------------------------------------------
    $app2 = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--session-persistence=false', '--window-theme=dark', '--window-show-tab-bar=always')
    $launched += $app2.Pid
    Start-Sleep -Seconds 3
    $top2 = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyWindow'
    Assert ($top2 -ne [IntPtr]::Zero) 'second launch: window found on the test desktop'
    if ($top2 -ne [IntPtr]::Zero) {
        $darkLum = Measure-TitlebarLuminance $top2
        Write-Host "capture: dark titlebar meanLum=$darkLum"
        Assert ($darkLum -ge 0 -and $darkLum -lt 100) `
            "capture separates dark chrome from light (dark meanLum=$darkLum vs light $lightLum)"
    }
    Stop-Process -Id $app2.Pid -Force -ErrorAction SilentlyContinue
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'nothing the harness launched ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
