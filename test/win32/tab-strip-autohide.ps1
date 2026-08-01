# T234 acceptance: the tab strip is not painted at one tab, and the window
# menu moved into the caption bar as a "..." button.
#
# The user's report, verbatim: "don't we own the header? can't we put a '...'
# button to the left of the minimize button, and use that space? Then we do not
# need to use tabs by default, wasting precious vertical space. The mac client
# does not use tabs by default."
#
# Both halves are ONE change, which is why they are one script: the strip could
# not go away while it was the app's only menu host (that is what pinned
# `auto => true` on Windows from T190 to here), and the caption button is what
# releases it. So a run that showed the strip gone but could not open a menu
# would be a regression, not a pass.
#
# What it asserts, and how - all by geometry and by live hit tests, never by
# "the code says so":
#
#   1. ONE TAB, DEFAULT CONFIG: the first pane's top sits exactly `caption_h`
#      (4 + 28 + 4 DIP) below the client top. Not "no strip is painted" - the
#      strip's absence is only worth anything if the terminal GETS the rows,
#      and that is a measured pane offset.
#   2. POSITIVE CONTROL, same size window, --window-show-tab-bar=always: the
#      same measurement is `caption_h + bar_h`. Without this an app that had
#      simply stopped creating panes correctly would read as a pass, and the
#      per-window row gain is the DIFFERENCE of the two, measured rather than
#      quoted from the design doc.
#   3. THE TRANSITION, live, in one window: ctrl+t drops the pane by exactly
#      bar_h (the strip appeared), and closing back to one tab lifts it by
#      exactly bar_h again. Panes are not lost or scrambled across either.
#   4. THE "..." BUTTON: WM_NCHITTEST over its square answers HTSYSMENU, which
#      is the code Windows itself uses for "the control that opens this
#      window's menu"; pressing it opens a real popup menu (a #32768 window on
#      this desktop, read live - not inferred from our own state).
#   5. NOTHING ELSE IN THE CAPTION MOVED: maximize still answers HTMAXBUTTON
#      (that code is what the Snap Layouts flyout watches for, so a button
#      inserted too close to it silently deletes a Windows 11 feature), close
#      still answers HTCLOSE, and the band left of "..." still drags.
#
# NEGATIVE CONTROL: -NegativeControl inverts section 1 (asserts the strip IS
# up at one tab under the default config) and MUST fail.
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
$env:GHOZTTY_PIPE_SUFFIX = '-autohidetest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Ok([string]$m) { $script:pass++; Write-Host "  PASS  $m" }
function Bad([string]$m) { $script:fail++; Write-Host "  FAIL  $m" -ForegroundColor Red }
function Check([bool]$c, [string]$m) { if ($c) { Ok $m } else { Bad $m } }

# win32 hit-test codes (win32.zig).
$HTCAPTION = 2; $HTSYSMENU = 3; $HTMAXBUTTON = 9; $HTCLOSE = 20
$WM_NCHITTEST = 0x0084; $WM_NCLBUTTONDOWN = 0x00A1

function PackPoint([int]$x, [int]$y) {
    return [IntPtr](([int64]($y -band 0xFFFF) -shl 16) -bor [int64]($x -band 0xFFFF))
}
function HitAt($h, [int]$sx, [int]$sy) {
    return [int](Invoke-TestMessage -Window $h -Message $WM_NCHITTEST -LParam (PackPoint $sx $sy))
}

# A window, sized, with its first pane found. Both launches go through this so
# the two measurements in section 2 cannot differ by anything but the flag.
function Start-Win([string[]]$extra) {
    Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
    # --confirm-close-surface=false: section 3 has to CLOSE a tab, and the
    # default puts a modal dialog in front of that (confirm-dialogs.ps1 owns
    # that behavior). Driving the dialog here would be testing the dialog.
    $app = Start-OnTestDesktop -Exe $exe -Arguments (@(
            '--config-default-files=false',
            '--session-persistence=false',
            '--confirm-close-surface=false',
            '--background=#000000'
        ) + $extra)
    $h = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($h -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no GhozttyWindow appeared' }
    Start-Sleep -Milliseconds 2500
    Set-TestWindowSize -Window $h -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 1200
    [pscustomobject]@{ App = $app; Pid = [int]$app.Pid; Top = $h }
}

# How far the first VISIBLE pane's top sits below the client area's top. This
# is the whole oracle of sections 1-3: it is caption_h with no strip and
# caption_h + bar_h with one, and it is the terminal's own geometry rather
# than a guess about what was painted.
function Pane-Offset($h) {
    $cli = Get-TestWindowRect -Window $h -Client
    $panes = @(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($panes.Count -lt 1) { return -1 }
    return ($panes[0].Top - $cli.Top)
}

function Kill-App($w) {
    if ($null -eq $w) { return }
    Stop-Process -Id $w.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
}

New-TestDesktop | Out-Null
$exitCode = 1
$auto = $null
$always = $null
try {
    Write-Host 'T234 tab-strip autohide + caption overflow acceptance'
    Write-Host "  exe: $exe"
    if ($NegativeControl) {
        Write-Host '  NEGATIVE CONTROL: asserts the strip IS up at one tab - this run MUST fail'
    }

    # --- 1. one tab, default config: no strip --------------------------------
    $auto = Start-Win @()
    $h = $auto.Top
    # Derived from the DIP constants rather than read out of the binary, but no
    # longer restated HERE - lib\ChromeGeometry.ps1 is the one copy (T257), and
    # it rounds the way Zig's @round does, which `Px` above did not.
    $m = Get-TestChromeMetrics -Window $h
    $dpi = $m.Dpi
    $scale = $m.Scale
    $padSm = $m.PadSm
    $padMd = $m.PadMd
    $btn = $m.BtnPaint
    $capH = $m.CaptionH
    Write-Host "  dpi=$dpi scale=$scale capH=$capH"

    $offAuto = Pane-Offset $h
    if ($offAuto -lt 0) { throw 'SETUP FAIL: no visible pane in the default-config window' }
    if ($NegativeControl) {
        Check ($offAuto -gt $capH) `
            "NEGATIVE CONTROL: the strip is up at one tab (pane offset $offAuto > capH $capH)"
    } else {
        Check ($offAuto -eq $capH) `
            "one tab, default config: no strip - the pane starts right under the caption (offset $offAuto, capH $capH)"
    }

    # --- 4/5. the caption's "..." and its neighbours -------------------------
    # Right-anchored, same arithmetic as caption_layout.layout: close, maximize,
    # minimize one (square + gap) apart, then "..." one GROUP step (pad_md)
    # further left because it is ours, not the OS's.
    $win = Get-TestWindowRect -Window $h
    $cli = Get-TestWindowRect -Window $h -Client
    $borderX = [int](($win.Width - $cli.Width) / 2)
    $step = $btn + $padSm
    $closeL = $cli.Width - $padSm - $btn
    $maxL = $closeL - $step
    $minL = $maxL - $step
    $overL = $minL - $padMd - $btn
    $bandY = $win.Top + $capH - 2
    function ClientX([int]$cx) { return $win.Left + $borderX + $cx }

    $hitOver = HitAt $h (ClientX ($overL + [int]($btn / 2))) $bandY
    $hitMax = HitAt $h (ClientX ($maxL + [int]($btn / 2))) $bandY
    $hitClose = HitAt $h (ClientX ($closeL + [int]($btn / 2))) $bandY
    $hitDrag = HitAt $h (ClientX ($overL - $padMd)) $bandY
    Check ($hitOver -eq $HTSYSMENU) `
        "the '...' button hit-tests as HTSYSMENU, Windows' own code for the window menu (got $hitOver)"
    Check ($hitMax -eq $HTMAXBUTTON) `
        "maximize still answers HTMAXBUTTON, so Snap Layouts still works (got $hitMax)"
    Check ($hitClose -eq $HTCLOSE) "close still answers HTCLOSE (got $hitClose)"
    Check ($hitDrag -eq $HTCAPTION) `
        "the band left of '...' still drags the window (got $hitDrag)"

    # --- 3. the transition, live --------------------------------------------
    # Ahead of the menu press ON PURPOSE. `TrackPopupMenuEx` is modal ON THE
    # GUI THREAD, so while the popup is up every question this script asks
    # that window blocks. Running the transition first means a menu that
    # refuses to dismiss fails as itself instead of as three unrelated
    # assertions "not being able to run".
    $panes = @(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal' | Where-Object Visible)
    $focused = $false
    if ($panes.Count -ge 1) {
        for ($f = 0; $f -lt 5 -and -not $focused; $f++) {
            $focused = Focus-TestWindow -Window $h -Child ([IntPtr]$panes[0].Hwnd)
            if (-not $focused) { Start-Sleep -Milliseconds 400 }
        }
    }
    Write-Host "  (panes=$($panes.Count) focused=$focused)"
    if ($panes.Count -ge 1 -and $focused) {
        [void](Send-TestKeys -Window $h -Target ([IntPtr]$panes[0].Hwnd) -Modifiers ctrl -Key T)
        $offTwo = -1
        for ($t = 0; $t -lt 30; $t++) {
            Start-Sleep -Milliseconds 200
            $all = @(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal')
            if ($all.Count -eq 2) { $offTwo = Pane-Offset $h; if ($offTwo -gt $capH) { break } }
        }
        $barH = $offTwo - $capH
        Check ($offTwo -gt $capH) `
            "a second tab brings the strip back (pane offset $capH -> $offTwo, bar_h $barH)"
        # bar_h is 4+4+28+4 = 40 DIP (T232). Asserted as a RANGE, not the exact
        # number: this script's job is the visibility rule, and pinning the
        # strip's height here would make it fail for a tab-strip change that
        # has nothing to do with T234 (the T256 lesson).
        # T257: this used to be a loose "between 30 and 56 DIP" plausibility
        # band, because the exact number was not available here without keeping
        # a fourth private copy of it. It is now the same measured-vs-derived
        # positive control tab-strip.ps1 uses, so a strip that comes back at the
        # WRONG height is a failure rather than a pass.
        Check ($barH -eq $m.BarH) `
            "the strip that appeared is exactly bar_h, not a stray offset ($barH px, expected $($m.BarH))"

        # ...and closing back to one tab hides it again. The new tab is the
        # active one and holds a single pane, so ctrl+w (close_surface) takes
        # the tab with it.
        $live = @(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal' | Where-Object Visible)
        $target = if ($live.Count -ge 1) { [IntPtr]$live[0].Hwnd } else { [IntPtr]$panes[0].Hwnd }
        $refocus = Focus-TestWindow -Window $h -Child $target
        [void](Send-TestKeys -Window $h -Target $target -Modifiers ctrl -Key W)
        $offBack = -1
        for ($t = 0; $t -lt 40; $t++) {
            Start-Sleep -Milliseconds 200
            $offBack = Pane-Offset $h
            if ($offBack -eq $capH) { break }
        }
        Check ($offBack -eq $capH) `
            "closing back to one tab hides the strip again (offset $offBack, capH $capH, refocused=$refocus)"
        # VISIBLE panes, deliberately not "child windows": a closed surface's
        # HWND outlives the close (it is hidden, then torn down later), so a
        # total-count oracle here reads 2 against a product that closed the tab
        # correctly - which is exactly what it did on the first run of this
        # script.
        Check ((@(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal' | Where-Object Visible)).Count -eq 1) `
            'exactly one pane is showing after the round trip - nothing was lost or scrambled'
    } else {
        Bad 'the strip show/hide transition could not run (no focusable pane)'
    }

    # --- 4b. pressing "..." opens a REAL menu --------------------------------
    # A #32768 popup, read from the desktop rather than from our own state:
    # "we set menu_open" would pass against a build that never created one.
    Send-TestRawMessage -Window $h -Message $WM_NCLBUTTONDOWN `
        -WParam ([IntPtr]$HTSYSMENU) -LParam (PackPoint 0 0) | Out-Null
    $menu = Wait-TestPopupMenu -ProcessId $auto.Pid -TimeoutMs 4000
    Check ($menu -ne [IntPtr]::Zero) "pressing '...' opens the window menu (popup hwnd $menu)"
    if ($menu -ne [IntPtr]::Zero) {
        # WM_CANCELMODE, not a posted Escape: the menu runs its own message
        # loop on the GUI thread, and cancelling it from another process is
        # what that message is documented for.
        Send-TestRawMessage -Window $h -Message 0x001F -WParam ([IntPtr]0) -LParam ([IntPtr]0) | Out-Null
        $gone = $false
        for ($t = 0; $t -lt 25; $t++) {
            Start-Sleep -Milliseconds 200
            if (-not (Test-TestWindowVisible -Window $menu)) { $gone = $true; break }
        }
        Check $gone 'the menu dismisses again, so the GUI thread is not left modal'
    }
    Kill-App $auto; $auto = $null

    # --- 2. positive control: the same window WITH the strip -----------------
    $always = Start-Win @('--window-show-tab-bar=always')
    $offAlways = Pane-Offset $always.Top
    Check ($offAlways -gt $capH) `
        "positive control: --window-show-tab-bar=always still shows the strip at one tab (offset $offAlways)"
    $gain = $offAlways - $offAuto
    Check ($gain -gt 0) `
        "the default window really gains those rows back: $gain px of terminal, every window, forever"
    Kill-App $always; $always = $null

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
    Kill-App $auto
    Kill-App $always
    Remove-TestDesktop
}
exit $exitCode
