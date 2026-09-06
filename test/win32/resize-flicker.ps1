# T1031 acceptance: resizing panes does not blank them first.
#
# THE DEFECT, because it decides what this script can honestly assert.
# The user's report was "when i resize a pane, the panes flicker fairly badly
# ... it seems like we're clearing and repainting on every frame", across three
# interactions: dragging a split divider, dragging the window edge, and
# expanding/collapsing the sticky banner. All three run one layout path, and
# four things on it each put a flat background rectangle on screen ahead of the
# GL frame:
#
#   1. The container window was created without WS_CLIPCHILDREN and the pane
#      children without WS_CLIPSIBLINGS, so parent-side drawing and the
#      transient mismatched geometry of an unbatched layout pass were free to
#      land on pixels a pane owns.
#   2. The surface's WM_ERASEBKGND filled the WHOLE client with the background
#      brush unconditionally, "because the OpenGL renderer will overwrite the
#      entire client area on the next frame". The NEXT frame was the bug: the
#      erase is synchronous, the GL frame is not.
#   3. layoutNode moved each leaf with its own MoveWindow.
#   4. The "block until the renderer has presented at the new size" path was
#      gated on in_live_resize, which is only set at WM_ENTERSIZEMOVE - so the
#      divider drag and the banner toggle, neither of which is a modal size
#      loop, never took it. That is why dragging the window edge already looked
#      better than dragging a divider.
#
# THE ORACLE, and what is deliberately NOT asserted here.
# The obvious test - sample pane pixels mid-drag and fail on a flat frame - is
# a coin flip, for the two reasons banner-resize-repaint.ps1 already measured:
# off the input desktop the terminal surface does not come back from
# PrintWindow at all (Get-TestWindowPixels refuses it by name), and on it the
# window between the erase and the swap is sub-frame, so polling at ~10ms from
# another process catches it essentially never. A test that passes because the
# shutter opened at a lucky moment proves nothing.
#
# What replaces it asks the app the same question directly, and none of it is
# timing-dependent:
#
#   A. The erase DECISION, read out of the debug build's stderr: the handler
#      logs `surface erase surface=.. presented=.. fill=..` every time it runs,
#      and a surface holding a presented frame must never say fill=true. That
#      is mechanism 2, stated by the app rather than photographed.
#      Not by probing the window: WM_ERASEBKGND carries an HDC, an HDC is a
#      per-process handle, and the version of this script that sent the message
#      from here went green with the fix REVERTED - the app's FillRect was
#      writing through a handle that meant nothing on its side. Its own teeth
#      check is what caught it, which is why every erase assertion below is
#      paired with a vacuity check that the oracle is alive.
#   B. The clip styles, read back off the live windows: WS_CLIPCHILDREN on the
#      container, WS_CLIPSIBLINGS on every visible pane. That is mechanism 1,
#      and it is the pair that makes parent/sibling overpaint impossible rather
#      than merely unlikely.
#   C. Both hold across a posted divider drag and a whole-window resize, and
#      the panes still TILE the content area afterwards - so the batched
#      layout pass (mechanism 3) did not trade a flicker for a gap or an
#      overlap. T155's tiling invariant is what a stale divider line lives in.
#
#   D. The SYNCHRONOUS PRESENT, added by T1393 - mechanism 4, which nothing
#      here could see until the app was made to state it. Each layout pass logs
#      `window resize cause=.. panes=.. sync=.. fresh=.. waits=.. timeouts=..`,
#      and a pass that resized panes the user can see must have put every one
#      of them on the wait (`sync + fresh >= panes`; `fresh` is a pane with
#      nothing presented yet, for which declining is the rule). That is what
#      caught the second cause of the same reported symptom five days after
#      T1031 closed: the wait was gated on `in_live_resize` - i.e. on
#      WM_ENTERSIZEMOVE, i.e. on a MODAL SIZE LOOP - so maximize, restore,
#      Aero-snap and a title-bar double-click each resized every visible pane
#      with the anti-flicker path switched off, and section C2 above could not
#      tell, because `Set-TestWindowPos` never opens a size loop either.
#
# Mechanism 4 no longer has "no observable this script can reach": "the pane
# blocked for a frame" is still a schedule rather than a pixel, but a schedule
# the app can be asked about. The unit half of the fix -
# WHEN the erase should still fill (a surface with no presented frame, and the
# search/palette popups that share its window class) - is
# src/apprt/win32/resize_paint.zig, run in every app-runtime lane.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never takes
# the user's foreground - asserted, not assumed.
#
# -NegativeControl inverts the erase and synchronous-present assertions and
# MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\resize-flicker.ps1
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

$env:GHOZTTY_PIPE_SUFFIX = "-resizeflicker$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-resize-flicker-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$WS_CLIPSIBLINGS = 0x04000000
$WS_CLIPCHILDREN = 0x02000000
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$WM_MOUSEMOVE = 0x0200
$MK_LBUTTON = [IntPtr]1
# T1393: the non-modal whole-window resize paths.
$WM_ENTERSIZEMOVE = 0x0231
$WM_EXITSIZEMOVE = 0x0232
$WM_SYSCOMMAND = 0x0112
$SC_MAXIMIZE = 0xF030
$SC_RESTORE = 0xF120

$script:pass = 0
$script:fail = 0
$script:skipped = 0
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

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' |
        Where-Object Visible)
}

# The erase decisions the app has logged so far, newest last. Each entry is
# @{ Surface; Presented; Fill }.
#
# This is read out of the debug build's stderr and not asked of the window,
# because WM_ERASEBKGND carries an HDC and an HDC does not survive a process
# boundary: a probe that sends the message from here hands the app a handle
# that means nothing on its side, so the app's FillRect fails, the DC comes
# back untouched, and the assertion reads "declined" whether the fix is in or
# out. That version of this script was written, went green, and was caught by
# its own teeth check. The app states the decision instead - same shape as
# pane-banner.ps1's `banner collapse from=` oracle.
function Get-EraseDecisions([string]$log) {
    if (-not (Test-Path $log)) { return @() }
    $out = @()
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match 'surface erase surface=(\w+) presented=(\w+) fill=(\w+)') {
            $out += [pscustomobject]@{
                Surface   = ($Matches[1] -eq 'true')
                Presented = ($Matches[2] -eq 'true')
                Fill      = ($Matches[3] -eq 'true')
            }
        }
    }
    return @($out)
}

# The whole-window resize passes the app has logged so far, newest last (T1393).
# Each entry is @{ Cause; Panes; Sync; Waits; Timeouts } - `Sync` being how many
# of the `Panes` resized by that pass blocked for a frame at their new size.
function Get-ResizePasses([string]$log) {
    if (-not (Test-Path $log)) { return @() }
    $out = @()
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match 'window resize cause=(\w+) panes=(\d+) sync=(\d+) fresh=(\d+) waits=(\d+) timeouts=(\d+)') {
            $out += [pscustomobject]@{
                Cause    = $Matches[1]
                Panes    = [int]$Matches[2]
                Sync     = [int]$Matches[3]
                Fresh    = [int]$Matches[4]
                Waits    = [int]$Matches[5]
                Timeouts = [int]$Matches[6]
            }
        }
    }
    return @($out)
}

# The defect, stated as a predicate: a terminal surface that already holds a
# presented frame must never blank itself. Everything from $since onward.
function Get-BlankingErases($all, [int]$since) {
    $bad = @()
    for ($i = $since; $i -lt $all.Count; $i++) {
        $e = $all[$i]
        if ($e.Surface -and $e.Presented -and $e.Fill) { $bad += "line $i" }
    }
    return $bad
}

# Panes that are missing WS_CLIPSIBLINGS.
function Get-UnclippedPanes($panes) {
    $bad = @()
    foreach ($p in $panes) {
        $st = Get-TestWindowStyle -Window ([IntPtr]$p.Hwnd)
        if (($st -band $WS_CLIPSIBLINGS) -eq 0) { $bad += ("0x{0:X}" -f $p.Hwnd) }
    }
    return $bad
}

# T155's invariant, in the one direction a split can break it: two panes side
# by side must not overlap, and the gap between them is the divider band - a
# parent-owned strip, never zero and never wide enough to be a hole. Returns
# violations, empty when it holds.
function Get-TileViolations($panes, [string]$where, [int]$maxBand) {
    $v = @()
    if ($panes.Count -ne 2) { return @("${where}: expected 2 panes, saw $($panes.Count)") }
    $sorted = @($panes | Sort-Object Left)
    $gap = $sorted[1].Left - $sorted[0].Right
    if ($gap -lt 0) { $v += "${where}: panes OVERLAP by $([math]::Abs($gap))px" }
    elseif ($gap -gt $maxBand) { $v += "${where}: $($gap)px gap between panes (band max $maxBand)" }
    if ($sorted[0].Top -ne $sorted[1].Top) {
        $v += "${where}: pane tops disagree ($($sorted[0].Top) vs $($sorted[1].Top))"
    }
    return $v
}

$td = New-TestDesktop -Interactive:$Interactive
try {
    Kill-RepoInstances
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false',
        # T1393 section D5: there is no CLI verb for either half of a tab
        # switch, so the script binds two keys it can post.
        '--keybind=f9=new_tab', '--keybind=f8=previous_tab')
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'

    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) 'top-level window appeared'
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }

    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1200 -Height 820)
    Start-Sleep -Milliseconds 800

    # ---- B1. the container clips its children ---------------------------
    $topStyle = Get-TestWindowStyle -Window ([IntPtr]$top)
    Assert ((($topStyle -band $WS_CLIPCHILDREN) -ne 0)) `
        ("container has WS_CLIPCHILDREN (style=0x{0:X})" -f $topStyle)

    & $exe +split --direction=right 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $panes = Get-VisiblePanes ([IntPtr]$top)
    Assert ($panes.Count -eq 2) "split produced 2 panes (saw $($panes.Count))"
    if ($panes.Count -ne 2) { throw 'no split' }

    # ---- B2. the panes clip each other ----------------------------------
    $unclipped = Get-UnclippedPanes $panes
    Assert ($unclipped.Count -eq 0) ('every visible pane has WS_CLIPSIBLINGS' +
        $(if ($unclipped.Count) { ' -- missing on ' + ($unclipped -join ', ') } else { '' }))

    # ---- A. the erase decision, settled ---------------------------------
    # WARM-UP FIRST, so the check below has something to be about. Whether the
    # handler has run yet at this point is a startup race - the teeth run for
    # this script caught the settled checkpoint reading an empty log and
    # passing for free - so provoke the erases deliberately rather than hoping
    # the launch produced some.
    foreach ($w in @(1150, 1050, 1200)) {
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width $w -Height 820)
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 500
    $panes = Get-VisiblePanes ([IntPtr]$top)

    # VACUITY NEXT. The whole erase half of this script asserts "no line says
    # it filled", which a build that logs nothing satisfies for free - a
    # release build (no debug logging), or a refactor that stops the handler
    # running at all. So the oracle has to be shown to be alive before it is
    # believed: at least one erase decision logged, over a surface, with a
    # frame already presented. That is the exact state the fix is about.
    $decisions = Get-EraseDecisions $errlog
    $live = @($decisions | Where-Object { $_.Surface -and $_.Presented })
    if ($decisions.Count -eq 0) {
        $script:skipped++
        Write-Host "SKIP  no `surface erase` oracle in the log - release build?" -ForegroundColor Yellow
    } else {
        Assert ($live.Count -gt 0) `
            ("the erase oracle is live: $($decisions.Count) decision(s) logged, " +
             "$($live.Count) of them over a surface holding a presented frame")
    }

    # THE DEFECT ITSELF. A pane that already holds a frame must never blank
    # itself: that is one displayed flat frame ahead of a GL frame that was
    # already on its way, once per relayout tick.
    $blanking = Get-BlankingErases $decisions 0
    $eraseOk = ($blanking.Count -eq 0)
    if ($NegativeControl) { $eraseOk = -not $eraseOk }
    Assert $eraseOk ('a pane that has presented a frame DECLINES the background fill' +
        $(if ($blanking.Count) { ' -- ' + (($blanking | Select-Object -First 4) -join ', ') } else { '' }))
    $seen = $decisions.Count

    # The band is a few DIP wide; scale the ceiling so this is not a 96dpi-only
    # assertion. Generous on purpose - the claim is "no hole", not a pixel spec.
    $dpi = Get-TestWindowDpi -Window ([IntPtr]$top)
    $maxBand = [int](24 * ($dpi / 96.0))
    Write-Host "  window dpi=$dpi (band ceiling ${maxBand}px)"

    $tv = Get-TileViolations $panes 'settled' $maxBand
    Assert ($tv.Count -eq 0) ('panes tile the content area before the drag' +
        $(if ($tv.Count) { ' -- ' + ($tv -join '; ') } else { '' }))

    # ---- C1. across a posted divider drag -------------------------------
    $tr = Get-TestWindowRect -Window ([IntPtr]$top)
    $sorted = @($panes | Sort-Object Left)
    $startX = $sorted[0].Right - $tr.Left
    $startY = [int](($sorted[0].Top + $sorted[0].Bottom) / 2) - $tr.Top

    $dragViolations = @()
    [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_LBUTTONDOWN `
        -WParam $MK_LBUTTON -LParam (New-LParam $startX $startY))
    Start-Sleep -Milliseconds 150
    for ($i = 1; $i -le 10; $i++) {
        $nx = $startX + ($i * 20)
        [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_MOUSEMOVE `
            -WParam $MK_LBUTTON -LParam (New-LParam $nx $startY))
        Start-Sleep -Milliseconds 60
        $now = Get-VisiblePanes ([IntPtr]$top)
        $dragViolations += Get-TileViolations $now "drag-$i" $maxBand
    }
    [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_LBUTTONUP `
        -WParam ([IntPtr]::Zero) -LParam (New-LParam ($startX + 200) $startY))
    Start-Sleep -Milliseconds 400

    Assert ($dragViolations.Count -eq 0) ('panes tile at every step of a divider drag' +
        $(if ($dragViolations.Count) { ' -- ' + (($dragViolations | Select-Object -First 4) -join '; ') } else { '' }))
    $decisions = Get-EraseDecisions $errlog
    $dragFilling = Get-BlankingErases $decisions $seen
    Assert ($dragFilling.Count -eq 0) ('no pane blanks itself during a divider drag' +
        $(if ($dragFilling.Count) { ' -- ' + (($dragFilling | Select-Object -First 4) -join ', ') } else { '' }))
    $seen = $decisions.Count

    # ---- C2. across whole-window resizes --------------------------------
    $winViolations = @()
    foreach ($w in @(1100, 950, 800, 1000, 1250)) {
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width $w -Height 820)
        Start-Sleep -Milliseconds 350
        $now = Get-VisiblePanes ([IntPtr]$top)
        $winViolations += Get-TileViolations $now "winresize-$w" $maxBand
    }
    Assert ($winViolations.Count -eq 0) ('panes tile across whole-window resizes' +
        $(if ($winViolations.Count) { ' -- ' + (($winViolations | Select-Object -First 4) -join '; ') } else { '' }))
    $decisions = Get-EraseDecisions $errlog
    $winFilling = Get-BlankingErases $decisions $seen
    # The window-edge drag is the one interaction that already had a
    # synchronous-present path, and it is also the one that proves the path was
    # never actually synchronous: `signalFrameDrawn` had no caller, so the wait
    # it feeds sat on an event nobody set and expired after 16ms every time.
    Assert ($winFilling.Count -eq 0) ('no pane blanks itself across window resizes' +
        $(if ($winFilling.Count) { ' -- ' + (($winFilling | Select-Object -First 4) -join ', ') } else { '' }))
    Assert ($decisions.Count -gt $seen) `
        ("window resizes actually reached the erase handler ($($decisions.Count - $seen) new decision(s)) - " +
         "without this the assertion above has nothing to be true about")
    $seen = $decisions.Count

    # ---- C3. across a banner expand/collapse ----------------------------
    # The third reported interaction. Setting a banner reserves a strip above
    # the pane and relayouts it, which is the same path with a different
    # trigger; the panes must survive it with the same two properties.
    $banner = 'A banner long enough to wrap over several lines so the reserved strip is genuinely tall and the pane below it really does resize when the banner appears and disappears.'
    & $exe +set-banner --target=window-1 $banner 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $exe +set-banner --target=window-1 '' 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $now = Get-VisiblePanes ([IntPtr]$top)
    $decisions = Get-EraseDecisions $errlog
    $bannerFilling = Get-BlankingErases $decisions $seen
    $bannerViolations = Get-TileViolations $now 'banner-cleared' $maxBand

    Assert ($bannerFilling.Count -eq 0) ('no pane blanks itself across a banner set/clear' +
        $(if ($bannerFilling.Count) { ' -- ' + ($bannerFilling -join ', ') } else { '' }))
    Assert ($bannerViolations.Count -eq 0) ('panes tile after the banner strip is given back' +
        $(if ($bannerViolations.Count) { ' -- ' + ($bannerViolations -join '; ') } else { '' }))

    # ---- D. the synchronous present, on every whole-window path ---------
    # T1393. Sections A-C prove nobody PAINTS background over a pane. They say
    # nothing about the other way a blank frame reaches the screen: the window
    # changes size, and the enlarged GL surface sits there holding the flat
    # clear color until the renderer presents at the new size. That gap is
    # closed by blocking the UI thread on the renderer's frame event - and
    # until T1393 the gate on it was `in_live_resize`, i.e. WM_ENTERSIZEMOVE,
    # i.e. a MODAL SIZE LOOP.
    #
    # Which is why section C2 above passed while the user could still see the
    # blink: `Set-TestWindowPos` resizes without a size loop, so it never
    # exercised the wait at all, and neither does maximize, Aero-snap or a
    # title-bar double-click - the three gestures a person actually uses to
    # resize a whole window without dragging its edge. The pre-fix build,
    # instrumented with the oracle below, answered:
    #
    #   cause=restored  panes=2 sync=2   <- bracketed frame drag
    #   cause=maximized panes=2 sync=0   <- maximize: no guarantee
    #   cause=restored  panes=2 sync=0   <- restore:  no guarantee
    #
    # Same oracle shape as the erase decision, and for the same reason: "the
    # pane waited for its frame" is a SCHEDULE, not a pixel, so no probe in
    # another process can photograph it. The pass states it instead.
    # Four panes, not the two the sections above need: the guarantee is
    # per-pane ("every pane of the pass waited"), so a two-pane window cannot
    # tell "all of them" apart from "the active one". Sections A-C are done
    # with the tiling assertions by here, so the extra splits are free.
    & $exe +split --direction=down 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $exe +split --direction=right 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $wide = @(Get-VisiblePanes ([IntPtr]$top))
    Assert ($wide.Count -ge 4) "four panes open for the whole-window checks (saw $($wide.Count))"

    $winresizeBefore = (Get-ResizePasses $errlog).Count

    # D1. a bracketed modal frame drag - the one path that already worked, kept
    # here as the positive control for the three below.
    [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_ENTERSIZEMOVE `
        -WParam ([IntPtr]::Zero) -LParam ([IntPtr]::Zero))
    foreach ($w in @(1120, 1040, 1180)) {
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width $w -Height 820)
        Start-Sleep -Milliseconds 250
    }
    [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_EXITSIZEMOVE `
        -WParam ([IntPtr]::Zero) -LParam ([IntPtr]::Zero))
    Start-Sleep -Milliseconds 300

    # D2. maximize, which is also what a title-bar double-click sends, and
    # D3. restore. Neither raises WM_ENTERSIZEMOVE.
    [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_SYSCOMMAND `
        -WParam ([IntPtr]$SC_MAXIMIZE) -LParam ([IntPtr]::Zero))
    Start-Sleep -Milliseconds 900
    [void](Send-TestRawMessage -Window ([IntPtr]$top) -Message $WM_SYSCOMMAND `
        -WParam ([IntPtr]$SC_RESTORE) -LParam ([IntPtr]::Zero))
    Start-Sleep -Milliseconds 900

    # D4. a snap: the window is resized to half the work area with no size loop
    # around it, which is the shape of Win+Left and of a drag-to-edge (whose
    # resize lands after WM_EXITSIZEMOVE).
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 0 -Y 0 -Width 760 -Height 900)
    Start-Sleep -Milliseconds 600

    # D5. a second tab, and a switch BACK to the first after the window has
    # changed size underneath it. A hidden tab's panes are not laid out while
    # it is hidden, so the switch is the first time they take the new size -
    # and the user is watching the tab appear, which makes it the same kind of
    # relayout as a resize. `selectTabIndex` therefore reports through the same
    # oracle, with cause=tabswitch.
    #
    # Driven by keybinds because there is no `+new-window --tab` verb and no
    # IPC action for either half; the keys are POSTED (Send-TestKeys), so this
    # works on the background desktop where SendInput does not.
    $panesBefore = (Get-VisiblePanes ([IntPtr]$top)).Count
    [void](Send-TestKeys -Window ([IntPtr]$top) -Target ([IntPtr]$wide[0].Hwnd) -Key F9)
    Start-Sleep -Seconds 3
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 20 -Y 20 -Width 1240 -Height 780)
    Start-Sleep -Milliseconds 600
    [void](Send-TestKeys -Window ([IntPtr]$top) -Target ([IntPtr]$wide[0].Hwnd) -Key F8)
    Start-Sleep -Milliseconds 900

    $passes = @(Get-ResizePasses $errlog)
    $newPasses = @($passes | Select-Object -Skip $winresizeBefore)
    $withPanes = @($newPasses | Where-Object { $_.Panes -gt 0 })

    # VACUITY, same discipline as section A: "no pass skipped the wait" is free
    # for a build that logs nothing and for a run where no pane was resized.
    if ($newPasses.Count -eq 0) {
        $script:skipped++
        Write-Host "SKIP  no ``window resize`` oracle in the log - release build?" -ForegroundColor Yellow
    } else {
        Assert ($withPanes.Count -gt 0) `
            ("the resize oracle is live: $($newPasses.Count) whole-window pass(es), " +
             "$($withPanes.Count) of them actually resized a pane")
        $causes = @($withPanes | ForEach-Object { $_.Cause } | Sort-Object -Unique)
        Assert ($causes -contains 'maximized') `
            ("the non-modal paths were reached (causes: $($causes -join ', '))")
        Assert ($causes -contains 'tabswitch') `
            ("a background tab was switched to (causes: $($causes -join ', '))")
    }

    # THE DEFECT: a pass that resized panes the user can see must have put
    # every one of them on the synchronous-present path.
    $unguarded = @()
    foreach ($p in $withPanes) {
        # `Fresh` panes are the rule's own carve-out, not a gap: a pane with
        # nothing presented has no pixels to protect, and a brand-new tab's
        # pane is in exactly that state when the tab strip appears and
        # relayouts the window (cause=tabbar panes=1 sync=0 fresh=1).
        if (($p.Sync + $p.Fresh) -lt $p.Panes) {
            $unguarded += "cause=$($p.Cause) panes=$($p.Panes) sync=$($p.Sync) fresh=$($p.Fresh)"
        }
    }
    $syncOk = ($unguarded.Count -eq 0)
    if ($NegativeControl) { $syncOk = -not $syncOk }
    Assert $syncOk ('every whole-window resize waits for a frame in every pane' +
        $(if ($unguarded.Count) { ' -- ' + (($unguarded | Select-Object -First 4) -join '; ') } else { '' }))

    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
}

# --- stamp (T783) ----------------------------------------------------------
# A clean green run RECORDS the content of resize_paint.zig and this script, so
# scripts\guard-due.ps1 can answer "has anybody run this against the erase rule
# as it now stands?". Stamped only on a run with no failures AND no skips, and
# never on a -NegativeControl run, whose whole point is that it fails.
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard resize-flicker -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
# One scorer owns the wording AND the exit code (T271).
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
