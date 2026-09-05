# T456 acceptance: resizing a pane that has a banner never leaves an
# unpainted region around the card.
#
# WHAT THE DEFECT ACTUALLY WAS, because it changed what this script can
# assert. The banner is a WS_EX_LAYERED popup glued to the band the layout
# reserves above its pane (BannerOverlay.zig). Its class was registered with
# `.style = 0`, i.e. WITHOUT CS_HREDRAW|CS_VREDRAW - so a SetWindowPos that
# changed the popup's SIZE invalidated nothing at all (measured: GetUpdateRect
# returned 0 after a 40px widen). Every pixel of the card is laid out against
# the current band size - the rounded rim and its shadow sit on the edges, the
# chevron column is measured in from the right, each block is word-wrapped to
# the content width - so the card kept its old geometry while the band around
# it moved with the drag. That is the "unpainted gaps / the overlay lags the
# drag" the user reported. DimOverlay survives `.style = 0` because it is a
# flat fill, where a partial repaint is indistinguishable from a full one.
#
# THE ORACLE, and one thing the task asked for that is NOT worth asserting.
# T456's Validation asked for a mid-drag pixel sample. Two measurements moved
# it here instead:
#   1. Off the input desktop, layered popups do not come back from
#      PrintWindow (the only capture that works there), and the banner IS a
#      layered popup - so there is no pixel of the card to sample.
#   2. On the interactive desktop, where CopyFromScreen does see it, the
#      remaining window between the pane's MoveWindow and the popup's
#      SetWindowPos is sub-frame. Polling it from another process at ~10ms
#      catches it essentially never, so a pixel assertion would be a coin
#      flip dressed as a test.
# What replaces it asserts the cause and the geometry rather than a lucky
# frame, and neither part is timing-dependent:
#   A. The live banner window's CLASS style carries CS_HREDRAW|CS_VREDRAW.
#      That is the fix, read back off the running app.
#   B. The TILING INVARIANT holds at every step of a posted divider drag and
#      after a whole-window resize: the banner popup exactly covers the band
#      above its pane (same left, same right, its bottom on the pane's top).
#      A gap in that arithmetic IS a parent-owned region nothing paints.
#   C. The same invariant holds during a HERO divider drag (T1324). Hero mode
#      runs its own drag handler, which reached `layoutHero` directly and so
#      skipped the pane-chrome pass every other layout path gets for free from
#      `layoutSplits`. The banner kept its pre-drag geometry for the length of
#      the drag and healed on button-up, so the sampling has to be MID-drag.
# The "repaint landed in the same pass, not one WM_PAINT later" half is a unit
# test - `banner overlay: a size-changing updatePosition repaints in the same
# pass` in BannerOverlay.zig, run at 1.0/1.25/1.5/2.0.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never takes
# the user's foreground - asserted at the end, not assumed. The drag is a
# posted down/moves/up on the top-level window, which is where the OS routes a
# band click after the pane answers HTTRANSPARENT (the mechanism
# split-divider.ps1 established).
#
# -NegativeControl inverts the tiling assertion and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\banner-resize-repaint.ps1
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

$env:GHOZTTY_PIPE_SUFFIX = "-bannerrepaint$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-banner-repaint-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$CS_VREDRAW = 0x0001
$CS_HREDRAW = 0x0002
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$WM_MOUSEMOVE = 0x0200
$MK_LBUTTON = [IntPtr]1

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

# Pack a client-coordinate point into an LPARAM the way the OS does.
function New-LParam([int]$x, [int]$y) {
    return [IntPtr](([int64]$y -shl 16) -bor ($x -band 0xFFFF))
}

# The band above $pane must be exactly covered by $banner. Returns a list of
# human-readable violations, empty when the invariant holds.
function Get-TilingViolations($banner, $pane, [string]$where) {
    $v = @()
    if ($banner.Left -ne $pane.Left) {
        $v += "$where left: banner $($banner.Left) vs pane $($pane.Left)"
    }
    if ($banner.Right -ne $pane.Right) {
        $v += "$where right: banner $($banner.Right) vs pane $($pane.Right)"
    }
    if ($banner.Bottom -ne $pane.Top) {
        $v += "$where seam: banner bottom $($banner.Bottom) vs pane top $($pane.Top)"
    }
    return $v
}

function Get-Banner([int]$appPid) {
    $b = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyBannerOverlay')
    if ($b.Count -eq 0) { return $null }
    return $b[0]
}

function Get-Rect([int64]$hwnd) {
    $r = Get-TestWindowRect -Window ([IntPtr]$hwnd)
    return $r
}

$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
Kill-RepoInstances

try {
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false')
    $launched += $script:GhozttyTestDesktopPids
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'

    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) 'top-level window appeared'
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }

    # A known size so the band arithmetic below has room, and so the drag has
    # somewhere to go. SWP_NOACTIVATE keeps the background desktop quiet.
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1200 -Height 820)
    Start-Sleep -Milliseconds 800

    & $exe +split --direction=right 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $panes = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' |
        Where-Object Visible)
    Assert ($panes.Count -eq 2) "split produced 2 panes (saw $($panes.Count))"
    if ($panes.Count -ne 2) { throw 'no split' }

    # A multi-line banner: several wrapped blocks, so the band is tall and its
    # height genuinely depends on the pane width.
    $banner = 'Wrap me: a deliberately long banner paragraph that needs several lines so the reserved band is tall and the card geometry really does depend on the pane width.\n- [x] first checklist row long enough to wrap onto a second line\n- [ ] second row also long enough to wrap in a narrow pane'
    & $exe +set-banner --target=window-1 $banner 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $b = Get-Banner $appPid
    Assert ($null -ne $b) 'banner overlay window exists'
    if (-not $b) { throw 'no banner' }

    # ---- A. the fix itself, read off the live window --------------------
    $cls = Get-TestWindowClassStyle -Window ([IntPtr]$b.Hwnd)
    Assert ((($cls -band $CS_HREDRAW) -ne 0) -and (($cls -band $CS_VREDRAW) -ne 0)) `
        ("banner class has CS_HREDRAW|CS_VREDRAW (style=0x{0:X})" -f $cls)

    # Which pane owns it: the one whose top edge sits on the banner's bottom.
    # Re-query first - setting the banner pushed the owner pane's top DOWN by
    # the band, so the rects captured before `+set-banner` are stale.
    $panes = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' |
        Where-Object Visible)
    $owner = $panes | Where-Object { [math]::Abs($_.Top - $b.Bottom) -le 4 } | Select-Object -First 1
    Assert ($null -ne $owner) 'found the banner''s owner pane'
    if (-not $owner) { throw 'no owner pane' }

    $v = Get-TilingViolations $b $owner 'settled'
    Assert ($v.Count -eq 0) ('band tiles the pane before the drag' +
        $(if ($v.Count) { ' -- ' + ($v -join '; ') } else { '' }))

    # ---- B1. posted divider drag, BOTH directions -----------------------
    # Dragging so the bannered pane SHRINKS is the direction that vacates
    # parent-owned pixels (narrower pane -> more wrapping -> taller band ->
    # the pane top moves DOWN), so it is where a missing repaint shows.
    $dpi = Get-TestWindowDpi -Window ([IntPtr]$top)
    Write-Host "  window dpi=$dpi (scale $([math]::Round($dpi/96.0,2)))"

    $tr = Get-Rect $top
    $or = Get-Rect $owner.Hwnd
    $startX = $or.Left - $tr.Left            # divider, in client coords
    $startY = [int](($or.Top + $or.Bottom) / 2) - $tr.Top

    $allViolations = @()
    foreach ($dir in @(1, -1)) {
        $label = if ($dir -gt 0) { 'shrink' } else { 'grow' }
        [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_LBUTTONDOWN `
            -WParam $MK_LBUTTON -LParam (New-LParam $startX $startY))
        Start-Sleep -Milliseconds 150
        for ($i = 1; $i -le 12; $i++) {
            $nx = $startX + ($dir * $i * 20)
            [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_MOUSEMOVE `
                -WParam $MK_LBUTTON -LParam (New-LParam $nx $startY))
            Start-Sleep -Milliseconds 60
            $bb = Get-Banner $appPid
            $pp = Get-Rect $owner.Hwnd
            if ($bb) {
                $allViolations += Get-TilingViolations $bb $pp "drag-$label-$i"
            }
        }
        [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_LBUTTONUP `
            -WParam ([IntPtr]::Zero) -LParam (New-LParam ($startX + $dir * 12 * 20) $startY))
        Start-Sleep -Milliseconds 400
    }
    $dragOk = ($allViolations.Count -eq 0)
    if ($NegativeControl) { $dragOk = -not $dragOk }
    Assert $dragOk ('band tiles the pane at every step of a divider drag, both directions' +
        $(if ($allViolations.Count) { ' -- ' + (($allViolations | Select-Object -First 4) -join '; ') } else { '' }))

    # ---- B2. whole-window resize (goal 2) -------------------------------
    $winViolations = @()
    foreach ($w in @(1100, 950, 800, 1000, 1250)) {
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width $w -Height 820)
        Start-Sleep -Milliseconds 350
        $bb = Get-Banner $appPid
        $pp = Get-Rect $owner.Hwnd
        if ($bb) { $winViolations += Get-TilingViolations $bb $pp "winresize-$w" }
    }
    Assert ($winViolations.Count -eq 0) ('band tiles the pane across whole-window resizes' +
        $(if ($winViolations.Count) { ' -- ' + (($winViolations | Select-Object -First 4) -join '; ') } else { '' }))

    # ---- C. hero mode: the banner must track the HERO divider drag -------
    # T1324. Hero mode has its OWN divider (hero pane on the left, thumbnail
    # carousel on the right) and its own drag handler, `heroUpdateDividerDrag`,
    # which called `layoutHero` DIRECTLY to get the 80ms leaf-resize throttle.
    # Every other layout path reaches the pane chrome through `layoutSplits`'s
    # trailing `updateDimOverlays`; that one did not, so the hero pane narrowed
    # under the drag while its banner kept the pre-drag geometry and left stale
    # strip pixels behind. `heroEndDividerDrag` then ran a full `layoutSplits`,
    # which is why the artifacts healed the instant the button came up and the
    # bug only ever existed DURING the drag - so this samples mid-drag, before
    # the button-up, which is the only place it is observable.
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1200 -Height 820)
    Start-Sleep -Milliseconds 400
    # The chord goes at the bannered LEAF, not the top-level window: hero is a
    # surface binding, and the pane that has focus when it fires becomes the
    # hero - which is also what puts the banner's owner on screen.
    [void](Send-TestKeys -Window ([IntPtr]$top) -Target ([IntPtr]$owner.Hwnd) `
        -Modifiers @('ctrl', 'shift') -Key 'space')
    Start-Sleep -Milliseconds 1200

    $heroPanes = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' |
        Where-Object Visible)
    Assert ($heroPanes.Count -eq 1) "hero mode: exactly one visible pane (saw $($heroPanes.Count))"
    if ($heroPanes.Count -eq 1) {
        $hero = $heroPanes[0]
        $hb = Get-Banner $appPid
        # The banner hides itself when its owner pane is not visible, so a
        # banner that is present at all here belongs to the hero.
        Assert (($null -ne $hb) -and ($hb.Visible)) 'hero mode: the bannered pane is the hero and its strip is showing'
        if ($hb -and $hb.Visible) {
            $v = Get-TilingViolations $hb $hero 'hero-settled'
            Assert ($v.Count -eq 0) ('band tiles the hero pane before the hero drag' +
                $(if ($v.Count) { ' -- ' + ($v -join '; ') } else { '' }))

            # Press in the hero divider band and walk LEFT (the user's case:
            # the hero narrows, so the band rewraps taller and both edges of
            # the banner have to move). Each step sleeps past the 80ms leaf
            # throttle so the sample sees a settled leaf rather than a frame
            # the app has not laid out yet.
            $heroViolations = @()
            $midY = [int](($hero.Top + $hero.Bottom) / 2)
            $divX = $hero.Right + 3
            [void](Send-TestMouse -Window ([IntPtr]$top) -Target ([IntPtr]$top) `
                -X $divX -Y $midY -Action down)
            Start-Sleep -Milliseconds 150
            for ($i = 1; $i -le 8; $i++) {
                $nx = $divX - ($i * 25)
                [void](Send-TestMouse -Window ([IntPtr]$top) -Target ([IntPtr]$top) `
                    -X $nx -Y $midY -Action move)
                Start-Sleep -Milliseconds 200
                $bb = Get-Banner $appPid
                $pp = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' |
                    Where-Object Visible)
                if ($bb -and $pp.Count -eq 1) {
                    $heroViolations += Get-TilingViolations $bb $pp[0] "herodrag-$i"
                }
            }
            [void](Send-TestMouse -Window ([IntPtr]$top) -Target ([IntPtr]$top) `
                -X ($divX - 200) -Y $midY -Action up)
            Start-Sleep -Milliseconds 500

            $heroOk = ($heroViolations.Count -eq 0)
            if ($NegativeControl) { $heroOk = -not $heroOk }
            Assert $heroOk ('band tiles the hero pane at every step of a hero divider drag' +
                $(if ($heroViolations.Count) { ' -- ' + (($heroViolations | Select-Object -First 4) -join '; ') } else { '' }))

            # And the hero actually narrowed - otherwise the loop above proved
            # nothing, because a divider that never moved cannot desynchronise
            # anything from it.
            $after = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' |
                Where-Object Visible)
            if ($after.Count -eq 1) {
                Assert ($after[0].Width -le ($hero.Width - 100)) `
                    "hero drag actually moved the divider (was $($hero.Width), now $($after[0].Width))"
            }
        }
    }

    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" -ForegroundColor Green }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
