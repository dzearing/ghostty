# T263 acceptance: Send-TestMouse routes a click the way Windows routes it.
#
# Windows decides which FAMILY of mouse message a point produces by asking the
# window WM_NCHITTEST first: HTCLIENT produces WM_LBUTTONDOWN & co., anything
# else produces the WM_NC* twin with the hit code in wparam. Until T263 the
# harness only ever posted the client form, so every click on the caption band
# - which since T254 is client PIXELS the window claims back through its hit
# test - reached no handler at all. It looked like nothing happened, which is
# indistinguishable from a broken product: T260 lost 17 assertions to it while
# F10 and the pixel probes passed, and each script that hit it grew its own
# hand-rolled WM_NCHITTEST + WM_NCLBUTTONDOWN pair to work around it.
#
# What this asserts, and how:
#
#   A. THE DECISION. Get-TestMouseRoute reports the target's own answer at a
#      point: HTMINBUTTON over minimize, HTCAPTION over the empty band,
#      HTCLIENT over the terminal. That is the input to the routing, read from
#      the app rather than modelled, so a button that MOVED reads as a moved
#      button instead of as an action that did not happen.
#   B. THE EFFECT. A plain `Send-TestMouse -Action click` on the minimize
#      button iconifies the window - no NC messages anywhere in the script.
#   C. THE OLD BEHAVIOR IS THE CONTROL. `-Client` at the SAME point does
#      nothing at all, which is the pre-T263 harness reproduced on demand. It
#      is what makes B's pass evidence about the routing rather than about the
#      button, and it is what keeps the escape hatch honest.
#   D. THE ROUTING DOES NOT OVER-CLAIM. A click on the empty caption band
#      (HTCAPTION) presses no button: the window is not iconified, not
#      maximized, not moved, not closed, the app still answers, and the NEXT
#      button click still works. A rule that turned every caption click into a
#      button press would be worse than no rule.
#   E. THE CLIENT PATH IS UNTOUCHED. A click on a terminal surface still goes
#      as a client message and still moves keyboard focus to that pane - the
#      oracle every mouse-driven script in this suite already depends on.
#
# NEGATIVE CONTROL: -NegativeControl forces B's click through -Client (i.e.
# runs it as the pre-T263 harness) and MUST fail.
#
# Runs on the background test desktop (test/win32/lib/TestDesktop.ps1), so it
# never takes the user's foreground. Only touches ghoztty processes running
# from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = '-ncroute'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Ok([string]$m) { $script:pass++; Write-Host "  PASS  $m" }
function Bad([string]$m) { $script:fail++; Write-Host "  FAIL  $m" }
function Check([bool]$c, [string]$m) { if ($c) { Ok $m } else { Bad $m } }

$HTCAPTION = 2; $HTMINBUTTON = 8; $HTCLIENT = 1
function Minimized([IntPtr]$h) { return ((Get-TestWindowStyle -Window $h) -band 0x20000000) -ne 0 }

New-TestDesktop | Out-Null
$exitCode = 1
try {
    Write-Host 'T263 mouse routing acceptance'
    Write-Host "  exe: $exe"

    # persistence: explicit --session-persistence=false below; this script
    # restores nothing and must not inherit the previous run's panes.
    $proc = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false',
        '--session-persistence=false',
        '--background=#000000',
        '--window-show-tab-bar=never'
    )
    $h = Wait-TestWindow -ProcessId $proc.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($h -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no GhozttyWindow appeared' }
    Start-Sleep -Milliseconds 2500
    Set-TestWindowSize -Window $h -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 1200

    # The button centers, from the shared DIP constants - the same arithmetic
    # caption-bar.ps1 derives and asserts against real pixels there. This
    # script is about the ROUTING, so it takes that derivation on trust and
    # section A re-checks each point against the app's own hit test before
    # anything is clicked.
    $m = Get-TestChromeMetrics -Window $h -StripVisible $false
    $win = Get-TestWindowRect -Window $h
    $cli = Get-TestWindowRect -Window $h -Client
    $borderX = [int](($win.Width - $cli.Width) / 2)
    $capW = $m.CapBtnW
    $closeL = $cli.Width - $capW
    $minL = $closeL - $capW - $capW
    $bandY = $win.Top + [int]($m.CaptionH / 2)
    $xMin = $win.Left + $borderX + $minL + [int]($capW / 2)
    $xBand = $win.Left + $borderX + 40
    $xTerm = $win.Left + $borderX + 200
    $yTerm = $win.Top + $m.CaptionH + 120
    Write-Host "  dpi=$($m.Dpi) capH=$($m.CaptionH) minimize=($xMin,$bandY) band=($xBand,$bandY) terminal=($xTerm,$yTerm)"

    # --- A: the decision -----------------------------------------------------
    $rMin = Get-TestMouseRoute -Window $h -X $xMin -Y $bandY
    $rBand = Get-TestMouseRoute -Window $h -X $xBand -Y $bandY
    $rTerm = Get-TestMouseRoute -Window $h -X $xTerm -Y $yTerm
    Check ($rMin.Code -eq $HTMINBUTTON -and $rMin.NonClient) `
        "A: the minimize point routes non-client, HTMINBUTTON (got $($rMin.Code))"
    Check ($rBand.Code -eq $HTCAPTION -and $rBand.NonClient) `
        "A: the empty band routes non-client, HTCAPTION (got $($rBand.Code))"
    Check ($rTerm.Code -eq $HTCLIENT -and -not $rTerm.NonClient) `
        "A: a point over the terminal routes CLIENT (got $($rTerm.Code))"

    # --- B: the effect -------------------------------------------------------
    # One ordinary click. Nothing in this script posts an NC message by hand,
    # which is the whole point: a script should not have to know which band it
    # is aiming at.
    [void](Send-TestMouse -Window $h -Target $h -X $xMin -Y $bandY -Action click -Client:$NegativeControl)
    Start-Sleep -Milliseconds 900
    if ($NegativeControl) {
        Check (Minimized $h) 'NEGATIVE CONTROL: a pre-T263 client click on minimize iconifies the window'
    } else {
        Check (Minimized $h) 'B: a plain click on the minimize button iconifies the window'
    }
    Send-TestSysCommand -Window $h -Command 'restore' | Out-Null
    Start-Sleep -Milliseconds 900
    Check (-not (Minimized $h)) 'B: the window restored, so the checks below start from a known state'

    # --- C: the escape hatch, and the bug it reproduces ----------------------
    [void](Send-TestMouse -Window $h -Target $h -X $xMin -Y $bandY -Action click -Client)
    Start-Sleep -Milliseconds 900
    Check (-not (Minimized $h)) `
        'C: -Client at the same point does nothing - the pre-T263 harness, reproduced on demand'

    # --- D: the routing does not over-claim ----------------------------------
    # A press on HTCAPTION is a window DRAG to DefWindowProc, not a button.
    # Measured here rather than assumed: with no physical button held the drag
    # loop ends immediately, so the window neither moves nor stops answering.
    $before = Get-TestWindowRect -Window $h
    [void](Send-TestMouse -Window $h -Target $h -X $xBand -Y $bandY -Action click)
    Start-Sleep -Milliseconds 900
    $after = Get-TestWindowRect -Window $h
    Check (-not (Minimized $h)) 'D: a click on the empty caption band does not iconify the window'
    Check (-not (Test-TestWindowZoomed -Window $h)) 'D: ...and does not maximize it'
    Check (Test-TestWindowExists -Window $h) 'D: ...and does not close it'
    Check (($before.Left -eq $after.Left) -and ($before.Top -eq $after.Top)) `
        "D: ...and leaves it where it was ($($before.Left),$($before.Top) -> $($after.Left),$($after.Top))"
    Check (Test-TestWindowResponsive -Window $h -TimeoutMs 3000) `
        'D: ...and the app still pumps messages afterwards'
    # The band click must not have left the window in a modal state either:
    # the next real click still lands.
    [void](Send-TestMouse -Window $h -Target $h -X $xMin -Y $bandY -Action click)
    Start-Sleep -Milliseconds 900
    Check (Minimized $h) 'D: a button click still works after a caption-band click'
    Send-TestSysCommand -Window $h -Command 'restore' | Out-Null
    Start-Sleep -Milliseconds 900

    # --- E: the client path is untouched -------------------------------------
    $surface = Get-TestChildWindow -Window $h -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) {
        Bad 'E: no terminal surface child to click'
    } else {
        # Focus, not pixels: a client WM_LBUTTONDOWN on a surface is what moves
        # the GUI thread's keyboard focus to that pane, and the deferred
        # SetFocus makes it asynchronous - so it is polled (T105).
        [void](Send-TestMouse -Window $h -Target $surface -X $xTerm -Y $yTerm -Action click)
        $focused = $false
        for ($t = 0; $t -lt 3000; $t += 100) {
            Start-Sleep -Milliseconds 100
            if ([IntPtr](Get-TestFocusedWindow -Window $h) -eq $surface) { $focused = $true; break }
        }
        Check $focused 'E: a click on the terminal still lands as a client message (it takes focus)'
        Check (-not (Minimized $h)) 'E: ...and did not leak into the caption'
    }

    Write-Host ''
    if ($script:fail -eq 0) {
        Write-Host "ALL PASS ($script:pass assertions)"
        $exitCode = 0
    } else {
        Write-Host "$script:fail FAILURE(S) ($script:pass passed)"
        $exitCode = 1
    }
} catch {
    Write-Host ''
    Write-Host "1 FAILURE(S) - $($_.Exception.Message)"
    $exitCode = 1
} finally {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $exe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
}
exit $exitCode
