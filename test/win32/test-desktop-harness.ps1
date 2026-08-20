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
#   limit       and where that capture STOPS: the GhozttyTerminal surface.
#               T214 (2026-08-01) turned the header's prose into three
#               measured assertions - the guard refuses it by class, the
#               forced capture is a flat fill, and the fill does not move when
#               the pane renders. The last two are the negative control for
#               the first: without them the refusal is a superstition.
#               T275 (2026-08-11) added a fourth, and it is a PAIR with those:
#               route 0 (`capture-pane`, the app reading back its own
#               renderer) captures the SAME pane at the SAME moment and sees
#               the text. The limit is unrepealed; what changed is that there
#               is now somewhere to send a probe that hits it.
#               T303 (2026-08-20) widened the guard past the one class it knew:
#               PrintWindow sees GDI, not composition, so EVERY WinUI/XAML
#               window (Task Manager measured flat black 1379x1134, 1 color,
#               reported success) captures as nothing. Three more assertions -
#               the bitmap-level refusal fires on a known-flat surface, its
#               message names the cause and the opt-out, and real chrome still
#               sails through, which is the half that keeps a stricter guard
#               from being a broken one.
#
# `-NegativeControl` inverts the three T303 assertions and the class refusal
# beside them; that run must FAIL. Without it the guards are a superstition -
# an assertion that cannot be made to fail proves nothing about the code it
# claims to cover.
#
# The capture assertion carries its own negative control: the SAME probe runs
# against a light-chrome window and a dark-chrome one and must separate them.
# A blank or stale bitmap cannot pass both.
#
# T213 (2026-08-01): that control used to flip `--window-theme=light|dark`,
# and it stopped separating anything. Since T254/T205 the caption band is
# CLIENT-painted by us and derives from `background` (+20 per channel), not
# from the DWM caption `window-theme` used to restyle - so both halves read the
# SAME meanLum 65-71. Note how it failed: the light half went red while the
# dark half stayed GREEN on the identical pixels, because 71 satisfies "< 100".
# A two-sided control is only a control if both sides are asserted against the
# separation, so the halves now assert the gap between them as well.
# Whether `window-theme` SHOULD still reach the caption is a product question,
# filed as T273 - not something this harness gets to decide by measuring.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = '-harnesstest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
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

# Mean luminance of the window's CAPTION band, via the harness's only working
# capture path. The caption on purpose: PrintWindow on a background desktop
# returns GDI-painted chrome and NOT the OpenGL terminal surface (see the
# harness header), so a probe aimed at the terminal would read a flat fill and
# "pass" against nothing. Since T254 that band is ours, not DWM's, which is
# exactly why it is capturable at all.
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
    # `--background=ffffff` is the input the caption band actually derives from
    # (Window.paintCaption: bg + 20 per channel). Deliberately NOT
    # `--window-theme=light`, which no longer reaches it - see the header.
    # `--foreground=101010` is load-bearing for the route-0 assertion below and
    # for nothing else: the default foreground is white, so a `--background=
    # ffffff` window renders white on white and its glass really IS one color.
    # Route 0 said so, which is the correct answer and a useless control - the
    # comparison it has to make is against a pane with visible text in it.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--session-persistence=false', '--background=ffffff', '--foreground=101010',
        '--window-show-tab-bar=always')
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
    if ($paneName) { $paneText = (& $exe +read --name=$paneName --lines=20 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String) }
    Assert ($paneText -match [regex]::Escape($token)) "Send-TestText delivered '$token' to the terminal"
    Assert (-not ($paneText -match 'hhaarrnneessss')) 'Send-TestText did NOT double characters (no WM_CHAR)'

    # --- THE CAPTURE LIMIT, measured rather than asserted from the header
    #     (T214). The pane has just echoed a token, so it is definitely
    #     rendering content. Three assertions, in the order that makes the
    #     trap visible:
    #
    #       1. the guard refuses the capture BY CLASS, before anything can be
    #          measured - a flat fill is a valid bitmap, so there is nothing to
    #          detect after the fact;
    #       2. -AllowTerminalSurface gets through, and what comes back is a
    #          flat fill on a pane full of text;
    #       3. it is the SAME flat fill after more text renders.
    #
    #     (2) and (3) are the negative control for (1): they prove the refusal
    #     guards a real limit. They are also the trap itself, stated as a
    #     measurement - a probe here does not fail loudly, it passes against
    #     nothing.
    $refused = $false
    try { Get-TestWindowPixels -Window $pane | Out-Null }
    catch { $refused = ($_.Exception.Message -match 'GhozttyTerminal') }
    if ($NegativeControl) { $refused = -not $refused }
    Assert $refused 'Get-TestWindowPixels REFUSES the GhozttyTerminal surface by class'

    # --- THE SAME LIMIT, ONE CLASS WIDER (T303). The class refusal above knows
    #     one window. Every WinUI/XAML window captures as the same flat fill and
    #     no class list predicts them, so the SECOND guard reads the bitmap: a
    #     non-trivial capture that is one color over its whole interior throws,
    #     after retrying long enough to rule out a window that had not painted.
    #     Fixture: this pane, which -AllowTerminalSurface lets past the class
    #     refusal and which is known-flat forever - the permanent half of the
    #     failure, measured rather than simulated. The two switches are separate
    #     on purpose, which is what makes this fixture possible at all.
    $uniformRefused = $false
    $uniformMsg = ''
    try { Get-TestWindowPixels -Window $pane -AllowTerminalSurface -UniformTimeoutMs 300 | Out-Null }
    catch { $uniformMsg = $_.Exception.Message; $uniformRefused = ($uniformMsg -match 'UNIFORM') }
    if ($uniformRefused) {
        Write-Host "capture: uniform guard fired - $($uniformMsg.Substring(0, [math]::Min(120, $uniformMsg.Length)))..."
    }
    if ($NegativeControl) { $uniformRefused = -not $uniformRefused }
    Assert $uniformRefused 'Get-TestWindowPixels REFUSES a UNIFORM capture (the WinUI/DirectComposition class of empty)'

    $uniformMentions = ($uniformMsg -match 'DirectComposition') -and ($uniformMsg -match 'AllowUniform')
    if ($NegativeControl) { $uniformMentions = -not $uniformMentions }
    Assert $uniformMentions 'the uniform refusal names DirectComposition and the -AllowUniform opt-out'

    #     ...and the other side of the control, which is the half that would
    #     make this guard worse than nothing: real GDI chrome must sail through
    #     it. A guard that also refuses the captures the suite depends on is not
    #     a stricter harness, it is a broken one.
    $chromeOk = $false
    $chromeErr = ''
    try {
        $chromeShot = Get-TestWindowPixels -Window $top -Sync
        try { $chromeOk = ((Get-TestDistinctColors -Shot $chromeShot) -ge 8) }
        finally { Close-TestWindowPixels $chromeShot }
    } catch { $chromeErr = $_.Exception.Message }
    if ($chromeErr) { Write-Host "capture: chrome window threw - $chromeErr" }
    if ($NegativeControl) { $chromeOk = -not $chromeOk }
    Assert $chromeOk 'the uniform guard does NOT refuse a real ghoztty chrome window'

    $shot = Get-TestWindowPixels -Window $pane -AllowTerminalSurface -AllowUniform
    try {
        $surfColors = Get-TestDistinctColors -Shot $shot
        $surfLum = Get-TestBrightness -Shot $shot
    } finally { Close-TestWindowPixels $shot }
    Write-Host "capture: terminal surface distinct=$surfColors meanLum=$surfLum"
    Assert ($surfColors -le 2) `
        "the terminal surface captures as a FLAT FILL ($surfColors distinct colors on a pane that just echoed '$token')"

    Send-TestText -Window $top -Target $pane -Text 'echo ZZZZZZZZZZZZZZZZ' | Out-Null
    Send-TestKeys -Window $top -Target $pane -Key Enter | Out-Null
    Start-Sleep -Milliseconds 1200
    $shot2 = Get-TestWindowPixels -Window $pane -AllowTerminalSurface -AllowUniform
    try {
        $surfColors2 = Get-TestDistinctColors -Shot $shot2
        $surfLum2 = Get-TestBrightness -Shot $shot2
    } finally { Close-TestWindowPixels $shot2 }
    Write-Host "capture: terminal surface after more output distinct=$surfColors2 meanLum=$surfLum2"
    Assert (($surfColors2 -le 2) -and ([math]::Abs($surfLum2 - $surfLum) -le 1)) `
        "the flat fill does not move when the terminal renders (distinct=$surfColors2 meanLum=$surfLum2 vs $surfLum)"

    #       4. ROUTE 0 SEES WHAT PRINTWINDOW CANNOT (T275). Same pane, same
    #          moment: `capture-pane` has the pane's own renderer read back its
    #          offscreen target, and that capture is full of the text the flat
    #          fill above could not see. This is the pair that keeps both facts
    #          true at once - the PrintWindow limit is real and unrepealed, and
    #          there is now a way around it that does not go through PrintWindow
    #          at all. Without it, a future reader has only the refusal and no
    #          idea what to do instead.
    if ($paneName) {
        $route0 = Get-TestPaneCapture -Target $paneName
        $route0Colors = if ($route0) { Get-TestPaneColorCount -Shot $route0 } else { 0 }
        if ($route0) { Close-TestPaneCapture $route0 }
        Write-Host "capture: route 0 (capture-pane) distinct=$route0Colors"
        Assert ($route0Colors -ge 8) `
            "route 0 reads the SAME pane as real content ($route0Colors distinct colors, vs $surfColors2 through PrintWindow)"
    } else {
        Write-Host 'SKIP  route 0 comparison: the pane has no registered name to capture'
        $script:skipped++
    }

    # --- a modifier CHORD: ctrl+shift+t must add a tab.
    Assert ((Get-TabCount) -eq 1) 'setup: one tab before the chord'
    Send-TestKeys -Window $top -Target $pane -Modifiers ctrl,shift -Key T | Out-Null
    Start-Sleep -Milliseconds 1000
    Assert ((Get-TabCount) -eq 2) 'Send-TestKeys ctrl+shift+t fired its keybind (2 tabs)'

    # --- capture, bright half.
    $lightLum = Measure-TitlebarLuminance $top
    Write-Host "capture: light-chrome caption meanLum=$lightLum"
    Assert ($lightLum -gt 150) "Get-TestWindowPixels returns REAL chrome for a light-chrome window (meanLum=$lightLum)"

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
        '--session-persistence=false', '--background=000000', '--window-show-tab-bar=always')
    $launched += $app2.Pid
    Start-Sleep -Seconds 3
    $top2 = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyWindow'
    Assert ($top2 -ne [IntPtr]::Zero) 'second launch: window found on the test desktop'
    if ($top2 -ne [IntPtr]::Zero) {
        $darkLum = Measure-TitlebarLuminance $top2
        Write-Host "capture: dark-chrome caption meanLum=$darkLum"
        Assert ($darkLum -ge 0 -and $darkLum -lt 100) `
            "capture reads dark chrome as dark (dark meanLum=$darkLum)"
        # The SEPARATION, asserted in its own right. Without this, two halves
        # reading the SAME number can still both be green - which is exactly
        # how the retired window-theme control survived (both sides ~71).
        Assert (($lightLum - $darkLum) -ge 100) `
            "capture SEPARATES the two chromes (light $lightLum - dark $darkLum >= 100)"
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

# --- stamp (T783, wired here by T303) --------------------------------------
# A clean green run RECORDS the content of lib\TestDesktop.ps1 and this script,
# so scripts\guard-due.ps1 can answer "has anybody run this against the library
# as it now stands?". Stamped only on a run with no failures AND no skips - a
# skipped section proved less than the whole harness claims - and never on a
# -NegativeControl run, whose whole point is that it fails. Red stays due.
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard test-desktop -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
# One scorer owns the wording AND the exit code (T271), so a run that skipped a
# section says so in the line anybody reads (T219) and a run that asserted
# nothing cannot report a pass.
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
