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
# Mechanism 4 has no observable this script can reach: "the pane blocked up to
# 16ms for a frame" is a schedule, not a pixel. The unit half of the fix -
# WHEN the erase should still fill (a surface with no presented frame, and the
# search/palette popups that share its window class) - is
# src/apprt/win32/resize_paint.zig, run in every app-runtime lane.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never takes
# the user's foreground - asserted, not assumed.
#
# -NegativeControl inverts the erase assertion and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\resize-flicker.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = '-resizeflicker'
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
        '--config-default-files=false', '--background=#101014', '--session-persistence=false')
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
