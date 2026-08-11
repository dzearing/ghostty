# T142 acceptance: the layered overlays defend their z-order.
#
# Every win32 overlay (banner strip, dim overlay, themed scrollbar, resize
# overlay) is a WS_POPUP owned by the pane/window it decorates, so Windows
# keeps it above its OWNER for free - and says nothing about the windows in
# between. Two ways it ends up over other applications, both permanent
# because every reposition used to pass SWP_NOZORDER:
#   1. a stray WS_EX_TOPMOST (we never set it; a T131 verification probe did
#      and never put it back - the filed cause of this task);
#   2. simply being SHOWN while its window is not in front, since
#      SWP_SHOWWINDOW lifts a popup to the top of the non-topmost band.
# Either way the user sees "windows in the background have banners that
# overlap windows in the foreground".
#
# T224/T272: runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it
# never steals the user's foreground.
#
# ACTIVATION, on the test desktop. The whole oracle used to be expressed
# against GetForegroundWindow, and a background desktop has NO foreground
# window - it returns 0 for every window. The stand-in is the ACTIVE window
# (GetGUIThreadInfo.hwndActive, `Get-TestActiveWindow`), and T224 MEASURED
# that it is faithful for this claim before a line was ported:
#
#   - Focus-TestWindow really does raise the window inside the non-topmost
#     band, exactly as a real activation does. With oz2 active the indices
#     read ov=2 A=4 B=1; activating oz1 instead reads A above B. Reproduced
#     across two runs.
#   - It really does deliver WM_ACTIVATE to the app: an injected stray
#     topmost heals on activation alone, with no layout event, and the only
#     caller of Window.healOverlayZOrders in the whole tree is the
#     WM_ACTIVATE handler (Window.zig). So section D is portable, not
#     approximated.
#   - Its BOOLEAN RETURN is not the activation oracle. Called without
#     -Child it returns False on a ghoztty window, because the app moves
#     keyboard focus to the GhozttyTerminal child, so GetFocus() is never the
#     top-level. Gating an abort on that return (which is what the old
#     GrabForeground gate became) would have aborted every run with no
#     verdict. This script gates on Get-TestActiveWindow instead.
#
# WHAT DOES NOT REPRODUCE HERE, named rather than quietly weakened:
#
#   - The SANDWICH is no longer the section-B repro. Measured: topmosting the
#     overlay also raises its OWNER to the top of the band, unopposed on a
#     desktop where no window holds the foreground, so nothing foreign lands
#     between the overlay and its owner - Sandwich reads "0:" in the healthy
#     AND the injected state. It stays as a healthy-state invariant (A/C);
#     the defect is caught by the two measures that DID discriminate: the
#     overlay's z-index against the ACTIVE window (healthy 2 > 1, injected
#     0 < 4) and WindowFromPoint over the banner band (healthy: oz2's
#     terminal; injected: GhozttyBannerOverlay). Both statements hold on the
#     interactive desktop too, so -Interactive scores the same assertions.
#   - The SWP_SHOWWINDOW LIFT - section A's original discovery - does not
#     reproduce off the input desktop. Measured: hiding the overlay and
#     re-showing it with SWP_SHOWWINDOW|SWP_NOZORDER (the product's own
#     flags) put it back at the SAME index, still below the active window,
#     where on the input desktop it went to the top of the band. So section A
#     is a healthy-state baseline here and nothing more; the stray-bit half
#     is what carries the repro.
#
# No pixels: WindowFromPoint respects z-order and sees layered popups, which
# is what "is the banner in front here?" needs, and there is no composited
# screen off the input desktop to sample anyway (CAPTURE LIMIT).
#
# Oracles (z-order is read as an index into the EnumWindows top-down
# enumeration, so "above" and "below" are measured, not inferred):
#   A. healthy: the banner overlay has no topmost bit, sits above its own
#      window, and sits BELOW the active window.
#   B. negative control: SetWindowPos(overlay, HWND_TOPMOST) reproduces the
#      filed report - the same overlay now indexes above the active window
#      and WindowFromPoint says the banner is what you see there.
#   C. a reposition heals it: bit gone, still above its own window, nothing
#      foreign sandwiched.
#   D. so does an activation change (WM_ACTIVATE), which is when the defect
#      is actually noticed - a window nobody resizes would stay broken.
#   E. a LEGITIMATE topmost owner (toggle_window_float_on_top, the quick
#      terminal) is preserved: Windows propagates the bit to owned popups,
#      and healing must not strip it or the banner would hide behind its own
#      window. This is the case that makes the fix owner-RELATIVE.
#   F. the same healing reaches the dim overlay and the scrollbar popup,
#      which share the helper.
#   G. (T180) so does the hovered-URL bubble, which T142 skipped as
#      "short-lived" - only its visibility is; the HWND outlives every hover.
#   H. (T180) the quick terminal, which topmosts ITSELF, keeps both its own
#      band and the propagated bit on its owned popup across a heal.
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$ExePath,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = '-oztest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The AGENT too (T248): +new-window --target= is idempotent against a
# PERSISTED session, and killing ghoztty.exe does not remove one, so from the
# second run onward a surviving agent would hand this run last run's windows.
function Stop-RepoInstances {
    foreach ($name in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$name'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 800
}

function Get-Win($target) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    foreach ($w in ($json | ConvertFrom-Json).data.windows) {
        if ($w.target -eq $target) { return $w }
    }
    return $null
}
function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Test-Topmost([IntPtr]$h) {
    return ((Get-TestWindowStyle -Window $h -ExStyle) -band 0x8) -ne 0
}

# Activate a window and WAIT for the app's queue to agree. The return value of
# Focus-TestWindow is about the FOCUSED hwnd (which the app moves to the pane
# child), so activation is read back from GetGUIThreadInfo instead - see the
# ACTIVATION note above.
function Set-Active([IntPtr]$top, [IntPtr]$pane) {
    Focus-TestWindow -Window $top -Child $pane | Out-Null
    for ($t = 0; $t -lt 20; $t++) {
        if ((Get-TestActiveWindow -Window $top) -eq [int64]$top) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# Who is visibly on top at the middle of the banner card, as
# "<hwnd>:<rootHwnd>:<class>".
function Get-FrontAt($rect) {
    $x = [int](($rect.Left + $rect.Right) / 2)
    $y = [int](($rect.Top + $rect.Bottom) / 2)
    return Get-TestWindowAt -X $x -Y $y
}
function Test-FrontIsOverlay([string]$front, [int64]$overlay) {
    return (($front -split ':')[0] -eq $overlay.ToString())
}

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # Session persistence off so the run starts from a blank layout (T131).
    # (`=false`, not `=off`: the CLI bool parser takes true/false only.)
    # The float keybind is bound at launch: toggle_window_float_on_top has no
    # default binding, and section E needs the PRODUCT's own float, not an
    # injected one.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--background=#101014',
        '--session-persistence=false',
        '--keybind=ctrl+shift+f9=toggle_window_float_on_top',
        '--keybind=ctrl+shift+f10=toggle_quick_terminal')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'

    # -----------------------------------------------------------------------
    # Setup: two overlapping windows in one process. A carries a banner; B is
    # parked exactly on top of A so "B is active" also means "B covers A's
    # banner band", which is what makes the front-most control meaningful.
    # -----------------------------------------------------------------------
    & $exe +new-window --target=oz1 | Out-Null
    $winA = Wait-Win 'oz1'
    if (-not $winA) { Write-Host 'SETUP FAIL: oz1 not registered'; exit 1 }
    $A = [IntPtr]([int64]$winA.id)

    & $exe +new-window --target=oz2 | Out-Null
    $winB = Wait-Win 'oz2'
    if (-not $winB) { Write-Host 'SETUP FAIL: oz2 not registered'; exit 1 }
    $B = [IntPtr]([int64]$winB.id)

    Set-TestWindowPos -Window $A -X 120 -Y 120 -Width 900 -Height 600 | Out-Null
    Set-TestWindowPos -Window $B -X 120 -Y 120 -Width 900 -Height 600 | Out-Null
    Start-Sleep -Milliseconds 600

    $paneA = Get-TestChildWindow -Window $A -Class 'GhozttyTerminal'
    $paneB = Get-TestChildWindow -Window $B -Class 'GhozttyTerminal'
    if ($paneA -eq [IntPtr]::Zero -or $paneB -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no terminal child in oz1/oz2'; exit 1
    }

    & $exe +set-banner --target=oz1 '**T142** z-order probe' | Out-Null
    $ov = $null
    for ($t = 0; $t -lt 25 -and -not $ov; $t++) {
        $ov = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyBannerOverlay')[0]
        if (-not $ov) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ov) { Write-Host 'SETUP FAIL: no banner overlay for oz1'; exit 1 }
    $ovHwnd = [IntPtr]$ov.Hwnd

    Assert ((Get-TestWindowOwner -Window $ovHwnd) -eq [int64]$A) 'the banner overlay is OWNED by oz1 (the pin this whole task is about)'

    # Activate B - from here on, A is a BACKGROUND window.
    if (-not (Set-Active $B $paneB)) {
        Write-Host 'ABORT: could not activate oz2 - no z-order verdict possible'
        exit 1
    }
    Start-Sleep -Milliseconds 500

    # -----------------------------------------------------------------------
    # A. Healthy baseline.
    # -----------------------------------------------------------------------
    Assert (-not (Test-Topmost $ovHwnd)) 'A: banner overlay is not topmost to begin with'
    $zOv = Get-TestZIndex -Window $ovHwnd
    $zA = Get-TestZIndex -Window $A
    $zB = Get-TestZIndex -Window $B
    Assert ($zOv -ge 0 -and $zA -ge 0 -and $zB -ge 0) "A: all three windows are in the z-order (ov=$zOv A=$zA B=$zB)"
    Assert ($zOv -lt $zA) "A: overlay sits ABOVE its own window (ov=$zOv < A=$zA)"
    # The load-bearing new oracle (T224), so this is what -NegativeControl
    # inverts: if it cannot fail, the migration proved nothing.
    $belowActive = ($zOv -gt $zB)
    $script:negReached = $true
    if ($NegativeControl) { $belowActive = -not $belowActive }
    Assert $belowActive "A: overlay sits BELOW the active window (ov=$zOv > B=$zB)"
    $btw = Get-TestOverlaySandwich -Overlay $ovHwnd -Owner $A
    Assert ($btw -like '0:*') "A: nothing foreign is sandwiched between the overlay and its window ($btw)"

    # z-order control: the front-most window over A's banner band must be B,
    # not A's banner.
    $ovRect = Get-TestWindowRect -Window $ovHwnd
    $front = Get-FrontAt $ovRect
    $frontRootIsB = ((($front -split ':')[1]) -eq ([int64]$B).ToString())
    Assert (-not (Test-FrontIsOverlay $front ([int64]$ovHwnd))) "A: the banner is not the front-most window over its own band ($front)"
    if (-not $frontRootIsB) {
        Write-Host "SKIP front-most control: oz2 is not what covers the band ($front) - the front-most asserts are skipped"
    }

    # -----------------------------------------------------------------------
    # B. Reproduce the defect: a stray probe topmosts the overlay.
    # -----------------------------------------------------------------------
    Set-TestWindowTopmost -Window $ovHwnd -On $true | Out-Null
    Start-Sleep -Milliseconds 400
    Assert (Test-Topmost $ovHwnd) 'B: injection took (overlay now carries WS_EX_TOPMOST)'
    $zOv = Get-TestZIndex -Window $ovHwnd
    $zB = Get-TestZIndex -Window $B
    Assert ($zOv -lt $zB) "B: repro - the background window's banner now indexes ABOVE the active window (ov=$zOv < B=$zB)"
    if ($frontRootIsB) {
        $front = Get-FrontAt $ovRect
        Assert (Test-FrontIsOverlay $front ([int64]$ovHwnd)) "B: repro - the banner is now the front-most window over the active window ($front)"
    }

    # -----------------------------------------------------------------------
    # C. A reposition heals it. (Measured, not assumed: topmosting an owned
    # popup also raises its OWNER within the band, so B is no longer
    # guaranteed to be in front here - which is why the invariant is
    # expressed against A, and the "below the active window" statement is D's
    # job.)
    # -----------------------------------------------------------------------
    # Two lines, so the band height changes and a real layout pass runs.
    & $exe +set-banner --target=oz1 "**T142** z-order probe\nsecond line" | Out-Null
    $healed = $false
    for ($t = 0; $t -lt 25 -and -not $healed; $t++) {
        Start-Sleep -Milliseconds 200
        $healed = (-not (Test-Topmost $ovHwnd))
    }
    Assert $healed 'C: reposition cleared the stray WS_EX_TOPMOST'
    $zOv = Get-TestZIndex -Window $ovHwnd
    $zA = Get-TestZIndex -Window $A
    Assert ($zOv -lt $zA) "C: overlay still above its own window after healing (ov=$zOv < A=$zA)"
    $btw = Get-TestOverlaySandwich -Overlay $ovHwnd -Owner $A
    Assert ($btw -like '0:*') "C: the sandwiched window is gone - overlay seated back onto its own window ($btw)"

    # -----------------------------------------------------------------------
    # D. An activation change heals it too (no layout event at all) - this is
    # the moment the user notices, and a window nobody resizes needs it. The
    # heal is REACHABLE ONLY from the WM_ACTIVATE handler (verified: it is the
    # single caller of Window.healOverlayZOrders), so this assertion is also
    # the proof that the harness delivers a real activation.
    # -----------------------------------------------------------------------
    Set-TestWindowTopmost -Window $ovHwnd -On $true | Out-Null
    Start-Sleep -Milliseconds 300
    if (-not (Test-Topmost $ovHwnd)) {
        Write-Host 'SKIP D: injection did not stick (something repositioned in between)'
    } else {
        $okA = Set-Active $A $paneA
        Start-Sleep -Milliseconds 400
        $okB = Set-Active $B $paneB
        Start-Sleep -Milliseconds 600
        if (-not ($okA -and $okB)) {
            Write-Host 'SKIP D: activation switching failed - not a T142 verdict'
        } else {
            $healed2 = $false
            for ($t = 0; $t -lt 15 -and -not $healed2; $t++) {
                Start-Sleep -Milliseconds 200
                $healed2 = (-not (Test-Topmost $ovHwnd))
            }
            Assert $healed2 'D: window activation cleared the stray WS_EX_TOPMOST'
            $zOv = Get-TestZIndex -Window $ovHwnd
            $zB = Get-TestZIndex -Window $B
            Assert ($zOv -gt $zB) "D: overlay below the active window after activation heal (ov=$zOv > B=$zB)"
            $ovD = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyBannerOverlay')[0]
            if ($ovD -and $frontRootIsB) {
                $front = Get-FrontAt (Get-TestWindowRect -Window ([IntPtr]$ovD.Hwnd))
                Assert (-not (Test-FrontIsOverlay $front ([int64]$ovHwnd))) "D: the banner no longer shows over the active window ($front)"
            }
        }
    }

    # -----------------------------------------------------------------------
    # E. A LEGITIMATE topmost owner is preserved. toggle_window_float_on_top
    # and the quick terminal both topmost the WINDOW; Windows propagates the
    # bit to owned popups, so a heal that just cleared the bit would drop the
    # banner below its own floating window. The heal is owner-relative for
    # this reason.
    #
    # The float is taken through the PRODUCT'S OWN action (the bound
    # toggle_window_float_on_top, run from inside the pane), not by injecting
    # HWND_TOPMOST from the harness the way B does: it is the mechanism
    # section E actually claims to protect.
    #
    # SKIPPED, NOT ASSERTED, PENDING T277. The app cannot currently REACH a
    # legitimately-topmost state: measured here, neither the bound action nor
    # an injected HWND_TOPMOST leaves WS_EX_TOPMOST on a ghoztty window, while
    # a plain Win32 window (charmap) in the same harness and desktop keeps it
    # in every condition. Asserting the preservation rule against a state that
    # never happens would be the vacuous assertion T217 batch 3 warns about,
    # and FAILING here would report the T142 heal as broken when what is
    # broken is float-on-top itself. So E announces the skip and names T277;
    # the moment the float sticks, this block starts asserting again with no
    # further edit.
    # -----------------------------------------------------------------------
    if (-not (Set-Active $A $paneA)) {
        Write-Host 'SKIP E: could not activate oz1 to send it the float keybind'
    } else {
        Send-TestKeys -Window $A -Target $paneA -Key F9 -Modifiers ctrl, shift | Out-Null
        $floated = $false
        for ($t = 0; $t -lt 25 -and -not $floated; $t++) {
            Start-Sleep -Milliseconds 200
            $floated = Test-Topmost $A
        }
        if (-not $floated) {
            Write-Host 'SKIP E: toggle_window_float_on_top left the window non-topmost - float-on-top is broken (T277), so the "legitimate topmost owner" case cannot be set up'
        }
        if ($floated) {
            $propagated = Test-Topmost $ovHwnd
            Assert $propagated 'E: the float propagates to the owned overlay (positive control)'
            if ($propagated) {
                & $exe +set-banner --target=oz1 '**T142** floating owner' | Out-Null
                Start-Sleep -Milliseconds 1200
                Assert (Test-Topmost $ovHwnd) 'E: reposition PRESERVED the propagated topmost bit (float-on-top not broken)'
                $zOv = Get-TestZIndex -Window $ovHwnd
                $zA = Get-TestZIndex -Window $A
                Assert ($zOv -lt $zA) "E: floating window's overlay still above it (ov=$zOv < A=$zA)"
            }
            Send-TestKeys -Window $A -Target $paneA -Key F9 -Modifiers ctrl, shift | Out-Null
            $unfloated = $false
            for ($t = 0; $t -lt 25 -and -not $unfloated; $t++) {
                Start-Sleep -Milliseconds 200
                $unfloated = (-not (Test-Topmost $A))
            }
            Assert $unfloated 'E: the toggle un-floats the window again'
            & $exe +set-banner --target=oz1 '**T142** grounded owner' | Out-Null
            $grounded = $false
            for ($t = 0; $t -lt 25 -and -not $grounded; $t++) {
                Start-Sleep -Milliseconds 200
                $grounded = (-not (Test-Topmost $ovHwnd))
            }
            Assert $grounded 'E: un-floating the owner leaves the overlay non-topmost again'
        }
    }

    # -----------------------------------------------------------------------
    # F. The dim overlay and the scrollbar popup share the helper.
    # -----------------------------------------------------------------------
    & $exe +split --target=oz1 --direction=down | Out-Null
    Start-Sleep -Milliseconds 1200
    $dim = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyDimOverlay')
    if ($dim.Count -lt 1) {
        Write-Host 'SKIP F/dim: no visible dim overlay (unfocused-split-opacity?)'
    } else {
        $dimHwnd = [IntPtr]$dim[0].Hwnd
        Set-TestWindowTopmost -Window $dimHwnd -On $true | Out-Null
        Start-Sleep -Milliseconds 200
        Assert (Test-Topmost $dimHwnd) 'F/dim: injection took'
        # A window resize re-shows every dim overlay through the layout path.
        Set-TestWindowPos -Window $A -X 120 -Y 120 -Width 880 -Height 580 | Out-Null
        $dimHealed = $false
        for ($t = 0; $t -lt 25 -and -not $dimHealed; $t++) {
            Start-Sleep -Milliseconds 200
            $dimHealed = (-not (Test-Topmost $dimHwnd))
        }
        Assert $dimHealed 'F/dim: reposition cleared the stray WS_EX_TOPMOST'
    }

    $sb = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyScrollbar' -AllowHidden)
    if ($sb.Count -lt 1) {
        Write-Host 'SKIP F/scrollbar: no scrollbar popup found'
    } else {
        $sbHwnd = [IntPtr]$sb[0].Hwnd
        Set-TestWindowTopmost -Window $sbHwnd -On $true | Out-Null
        Start-Sleep -Milliseconds 200
        Assert (Test-Topmost $sbHwnd) 'F/scrollbar: injection took'
        Set-TestWindowPos -Window $A -X 120 -Y 120 -Width 860 -Height 560 | Out-Null
        $sbHealed = $false
        for ($t = 0; $t -lt 25 -and -not $sbHealed; $t++) {
            Start-Sleep -Milliseconds 200
            $sbHealed = (-not (Test-Topmost $sbHwnd))
        }
        Assert $sbHealed 'F/scrollbar: reposition cleared the stray WS_EX_TOPMOST'
    }

    # -----------------------------------------------------------------------
    # G (T180). The hovered-URL bubble is on the list too.
    #
    # T142 skipped it as a "short-lived popup". Only its VISIBILITY is short:
    # the HWND is created on the first link hover and lives until the surface
    # is destroyed (Surface.deinit), so a stray topmost on it survives every
    # later hover - the same permanent defect sections B/C are about, on a
    # popup that appears over whatever the user is reading.
    #
    # Driving it needs a CTRL-HELD hover: both link paths in core
    # (`linkAtPos`) gate on ctrlOrSuper, and the win32 side reads the modifier
    # with GetKeyState - which is why this is posted through Send-TestMouse
    # (AttachThreadInput + SetKeyboardState), MEASURED to work here before the
    # section was written. The bubble is a STATIC popup owned by the window and
    # is identified by its TEXT being the URL, which is what tells it apart
    # from the resize overlay (also a STATIC popup, owned by the same window).
    # -----------------------------------------------------------------------
    # Its OWN window: section F split oz1, so "the focused pane of oz1" is no
    # longer $paneA and a send-keys against the window would print the URL
    # into the wrong pane.
    & $exe +new-window --target=oz3 | Out-Null
    $winC = Wait-Win 'oz3'
    $C = if ($winC) { [IntPtr]([int64]$winC.id) } else { [IntPtr]::Zero }
    $paneC = if ($C -ne [IntPtr]::Zero) { Get-TestChildWindow -Window $C -Class 'GhozttyTerminal' } else { [IntPtr]::Zero }
    if ($paneC -eq [IntPtr]::Zero) {
        Write-Host 'SKIP G: could not open oz3 for the hovered-URL bubble'
    } else {
    Set-TestWindowPos -Window $C -X 140 -Y 140 -Width 900 -Height 600 | Out-Null
    Start-Sleep -Milliseconds 600
    & $exe +send-keys --target=oz3 'echo https://example.com/t180-bubble' Enter | Out-Null
    Start-Sleep -Seconds 2
    $paneRect = Get-TestWindowRect -Window $paneC
    function Get-UrlBubble {
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'Static' -AllowHidden)) {
            if ((Get-TestWindowText -Window ([IntPtr]$w.Hwnd)) -like 'http*') { return $w }
        }
        return $null
    }
    # Scan the pane for the printed URL: the cell the link sits in is not
    # something the harness can compute (font metrics, prompt length), so the
    # hover walks a coarse grid until the bubble appears.
    $hitX = 0; $hitY = 0
    $bubble = $null
    :hover for ($y = $paneRect.Top + 8; $y -lt $paneRect.Top + 300 -and -not $bubble; $y += 14) {
        for ($x = $paneRect.Left + 8; $x -lt $paneRect.Left + 420; $x += 24) {
            Send-TestMouse -Window $C -Target $paneC -X $x -Y $y -Action move -Modifiers ctrl | Out-Null
            $b = Get-UrlBubble
            if ($b) { $bubble = $b; $hitX = $x; $hitY = $y; break hover }
        }
    }
    if (-not $bubble) {
        Write-Host 'SKIP G: the ctrl-hover never raised the hovered-URL bubble - no T180 verdict'
    } else {
        $bubbleHwnd = [IntPtr]$bubble.Hwnd
        Assert ((Get-TestWindowOwner -Window $bubbleHwnd) -eq [int64]$C) 'G: the hovered-URL bubble is OWNED by oz3'
        Assert (-not (Test-Topmost $bubbleHwnd)) 'G: the bubble is not topmost to begin with'

        Set-TestWindowTopmost -Window $bubbleHwnd -On $true | Out-Null
        Start-Sleep -Milliseconds 300
        if (-not (Test-Topmost $bubbleHwnd)) {
            Write-Host 'SKIP G: injection did not stick on the bubble'
        } else {
            Assert $true 'G: injection took (bubble now carries WS_EX_TOPMOST)'
            # Off the link and back on: the core dedupes a hover that stays in
            # the same CELL, so leaving and returning is what guarantees a
            # fresh setMouseOverLink - the reposition this task adds the heal
            # to. (Moving off also clears the bubble, which is the hide path.)
            Send-TestMouse -Window $C -Target $paneC -X ($paneRect.Right - 24) -Y $hitY -Action move -Modifiers ctrl | Out-Null
            Start-Sleep -Milliseconds 300
            Send-TestMouse -Window $C -Target $paneC -X $hitX -Y $hitY -Action move -Modifiers ctrl | Out-Null
            $bubbleHealed = $false
            for ($t = 0; $t -lt 25 -and -not $bubbleHealed; $t++) {
                Start-Sleep -Milliseconds 200
                $bubbleHealed = (-not (Test-Topmost $bubbleHwnd))
            }
            Assert $bubbleHealed 'G: re-hovering the link cleared the stray WS_EX_TOPMOST on the bubble'
            $zBub = Get-TestZIndex -Window $bubbleHwnd
            $zC = Get-TestZIndex -Window $C
            Assert ($zBub -ge 0 -and $zBub -lt $zC) "G: the bubble is still above its own window after healing (bubble=$zBub < oz3=$zC)"
        }
    }
    }

    # -----------------------------------------------------------------------
    # H (T180). The quick terminal is the case the owner-RELATIVE rule exists
    # to protect, and section E cannot reach it when float-on-top is unwell.
    # The quick terminal topmosts ITSELF (QuickTerminal.animateIn ->
    # w32.setTopmost), Windows propagates the bit to its owned popups, and the
    # heal must leave BOTH alone: demoting an owned popup drags its owner out
    # of the topmost band with it, so a heal that "fixed" the propagated bit
    # would silently un-float the quick terminal.
    #
    # The scrollbar is the popup used here because every surface creates one -
    # no banner has to be set on a window +list may not name.
    # -----------------------------------------------------------------------
    $before = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' -AllowHidden | ForEach-Object { $_.Hwnd })
    if (-not (Set-Active $A $paneA)) {
        Write-Host 'SKIP H: could not activate oz1 to send it the quick-terminal keybind'
    } else {
        Send-TestKeys -Window $A -Target $paneA -Key F10 -Modifiers ctrl, shift | Out-Null
        $qt = [IntPtr]::Zero
        for ($t = 0; $t -lt 30 -and $qt -eq [IntPtr]::Zero; $t++) {
            Start-Sleep -Milliseconds 200
            foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' -AllowHidden)) {
                if ($before -notcontains $w.Hwnd) { $qt = [IntPtr]$w.Hwnd; break }
            }
        }
        if ($qt -eq [IntPtr]::Zero) {
            Write-Host 'SKIP H: the quick terminal never appeared'
        } elseif (-not (Test-Topmost $qt)) {
            Write-Host 'SKIP H: the quick terminal came up NON-topmost, so the "legitimate topmost owner" case cannot be set up here'
        } else {
            Assert $true 'H: the quick terminal is topmost (positive control)'
            $qtSb = $null
            for ($t = 0; $t -lt 25 -and -not $qtSb; $t++) {
                foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyScrollbar' -AllowHidden)) {
                    if ((Get-TestWindowOwner -Window ([IntPtr]$w.Hwnd)) -eq [int64]$qt) { $qtSb = $w; break }
                }
                if (-not $qtSb) { Start-Sleep -Milliseconds 200 }
            }
            if (-not $qtSb) {
                Write-Host 'SKIP H: the quick terminal has no owned scrollbar popup to heal'
            } else {
                $qtSbHwnd = [IntPtr]$qtSb.Hwnd
                $propagated = Test-Topmost $qtSbHwnd
                Assert $propagated 'H: the quick terminal float propagates to its owned popup (positive control)'
                if ($propagated) {
                    # A resize runs the layout path, which repositions the
                    # scrollbar - and therefore heals it.
                    $qtRect = Get-TestWindowRect -Window $qt
                    Set-TestWindowPos -Window $qt -X $qtRect.Left -Y $qtRect.Top `
                        -Width ($qtRect.Right - $qtRect.Left - 40) -Height ($qtRect.Bottom - $qtRect.Top) | Out-Null
                    Start-Sleep -Milliseconds 1200
                    Assert (Test-Topmost $qtSbHwnd) 'H: the heal PRESERVED the propagated topmost bit on the quick terminal popup'
                    Assert (Test-Topmost $qt) 'H: the quick terminal itself was never dragged out of the topmost band'
                }
            }
            Send-TestKeys -Window $A -Target $paneA -Key F10 -Modifiers ctrl, shift | Out-Null
            Start-Sleep -Milliseconds 800
        }
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
}

# The user's actual complaint, asserted rather than assumed. Runs AFTER the
# cleanup, so it reads the surviving all-pids list - the live one is emptied by
# Remove-TestDesktop and would score against nothing (T217 batch 3).
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# T179: this script is the repo's only WS_EX_TOPMOST injector, and a probe that
# pins a window and never puts it back is what manufactured T142's phantom bug.
# Every injection above is expected to be healed by the PRODUCT (sections C, D
# and F assert exactly that), so the restore in Remove-TestDesktop should have
# found nothing left to do. Anything it did have to un-pin is a window this run
# would have leaked. Read after the cleanup - the restore happens IN it.
$strayPins = @(Get-TestTopmostRestored)
Assert ($strayPins.Count -eq 0) "no probe left a window topmost (harness had to un-pin: $($strayPins -join ','))"

# A -NegativeControl run that never reached the inverted assertion proves
# nothing, and would otherwise report a clean pass.
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
