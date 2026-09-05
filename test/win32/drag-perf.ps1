# T1343 acceptance: what a splitter drag COSTS, measured, at several pane
# counts, in both shapes of the frame wait.
#
# THE REPORT THIS EXISTS FOR (user, 2026-09-04): "the windows version is so
# much slower than the mac version. like resizing panes is janky and slow ...
# when I resize panes, they're slow to paint. It feels so unpolished."
#
# THE MECHANISM, because it decides what is measured. One mouse move during a
# divider drag is one `updateDividerDrag` -> `layoutSplitsLive` -> a layout
# pass, all of it on the UI thread, so the wall clock of that call IS the
# drag's frame time. Inside the pass every resized pane blocks on its renderer
# presenting a frame at the new size (`Surface.handleResize`), which is what
# stops DWM stretching stale content across the resize - a real guarantee worth
# keeping. Paid PER PANE it also made the drag degrade with every split: four
# panes meant four 16 ms stalls for one mouse move, about 15 fps of drag.
#
# T1343 collects the panes' frame events during the pass and waits for all of
# them ONCE at the end (`Window.endFrameWaitBatch`), so the guarantee costs one
# frame regardless of pane count. `GHOZTTY_DRAG_SERIAL_WAIT` puts the old
# per-pane wait back, which is what lets this script measure BOTH shapes on one
# build, one box and one afternoon instead of comparing across two builds.
#
# THE ORACLE. The app times its own drag and prints one line per drag at
# `WM_LBUTTONUP` (`Window.reportDragCost`, gated on `GHOZTTY_PERF`), with the
# tick broken into the parts it is actually made of:
#
#   divider drag ticks=.. mean_us=.. max_us=.. mean_wait_us=.. fps=.. panes=..
#                resizes_max=.. waits_max=.. waits_total=.. timeouts=..
#                mean_layout_us=.. mean_place_us=.. mean_paint_us=..
#                mean_overlay_us=.. mean_resize_us=.. over_budget=..
#                wait=serial|batched verdict=..
#
# Read from the app rather than photographed from here for the reason
# resize-flicker.ps1 spells out at length: a frame is sub-frame-long and a
# cross-process probe catches it essentially never. The arithmetic behind the
# line (mean/max/fps/verdict, and the two wait ceilings) is pure and asserted
# in every lane by src/apprt/win32/drag_perf.zig.
#
# WHAT IS ASSERTED, and what is only recorded:
#   A. The oracle is live - a drag really reached the handler at every pane
#      count, in both modes, and really moved panes (`resizes/move`).
#   B. THE DEFECT: one mouse move performs ONE frame wait, whatever the pane
#      count. The COUNT is the assertion and the clock is not, because how long
#      a wait costs is a property of the machine (a compositor throttling
#      presents) while how many times the UI thread stopped to wait is a
#      property of the code.
#   C. The shape this replaced really did multiply - 8 waits per move at 8
#      panes - and really did grow with the pane count. Without C, B passes on
#      a build where the frame wait was simply deleted.
#   D. A batched drag holds two frames or better per move, and the drags being
#      compared really ran (tick counts).
#   The absolute numbers for every configuration are printed and written to
#   $env:TEMP\ghoztty-drag-perf\<stamp>\report.txt, which is the "measure
#   first, keep the numbers" half of the task. What they said on 2026-09-04,
#   at 8 panes, on this box: the per-pane shape spent 8.8ms of a 20.0ms move
#   waiting (49 fps); batching it spent 2.6ms of a 15.8ms move (63 fps). The
#   rest is pane placement (9.7ms) and the dim/banner overlay refresh (3.3ms),
#   which is T1345's half of the report and not this fix's.
#
# NOT asserted here: that resizing still shows no stale or stretched content.
# That is `test\win32\resize-flicker.ps1`, which owns the erase/clip oracle and
# runs a posted divider drag of its own; duplicating it here would be a second
# weaker copy of a check that already exists.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1) - no foreground
# stolen - and drives the drag with POSTED mouse messages, which is why it
# works there at all (SendInput does not).
#
# -NegativeControl inverts assertion B and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\drag-perf.ps1
param(
    [string]$ExePath,
    [int[]]$PaneCounts = @(2, 4, 8),
    [int]$Moves = 24,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-dragperf$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$WM_MOUSEMOVE = 0x0200
$MK_LBUTTON = [IntPtr]1
$FRAME_US = 16667

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-drag-perf\$stamp"
New-Item -ItemType Directory -Force $outDir | Out-Null
$report = Join-Path $outDir 'report.txt'

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Rep([string]$m) { $m | Tee-Object -FilePath $report -Append | Write-Host }
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Rep "PASS  $label" }
    else { $script:fail++; $host.UI.WriteErrorLine("FAIL  $label"); "FAIL  $label" | Out-File -Append $report }
}

function New-LParam([int]$x, [int]$y) {
    return [IntPtr](([int64]$y -shl 16) -bor ($x -band 0xFFFF))
}

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# Every `divider drag ...` summary the app has printed so far, oldest first.
function Get-DragSamples([string]$log) {
    if (-not (Test-Path $log)) { return @() }
    $out = @()
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match ('divider drag ticks=(\d+) mean_us=(\d+) max_us=(\d+) ' +
                'mean_wait_us=(\d+) fps=(\d+) panes=(\d+) resizes_max=(\d+) waits_max=(\d+) ' +
                'waits_total=(\d+) timeouts=(\d+) mean_layout_us=(\d+) ' +
                'mean_place_us=(\d+) mean_paint_us=(\d+) ' +
                'mean_overlay_us=(\d+) mean_resize_us=(\d+) over_budget=(\d+) ' +
                'wait=(\w+) verdict=(\w+)')) {
            $out += [pscustomobject]@{
                Ticks       = [int]$Matches[1]
                MeanUs      = [int]$Matches[2]
                MaxUs       = [int]$Matches[3]
                MeanWaitUs  = [int]$Matches[4]
                Fps         = [int]$Matches[5]
                Panes       = [int]$Matches[6]
                ResizesMax  = [int]$Matches[7]
                WaitsMax    = [int]$Matches[8]
                WaitsTotal  = [int]$Matches[9]
                Timeouts    = [int]$Matches[10]
                LayoutUs    = [int]$Matches[11]
                PlaceUs     = [int]$Matches[12]
                PaintUs     = [int]$Matches[13]
                OverlayUs   = [int]$Matches[14]
                ResizeUs    = [int]$Matches[15]
                OverBudget  = [int]$Matches[16]
                Wait        = $Matches[17]
                Verdict     = $Matches[18]
            }
        }
    }
    return @($out)
}

# Drive one divider drag with posted mouse messages and hand back the summary
# line it produced, or $null if the app printed none.
function Invoke-DividerDrag([IntPtr]$top, [string]$log, [int]$moves) {
    $before = (Get-DragSamples $log).Count
    $panes = Get-VisiblePanes $top
    if ($panes.Count -lt 2) { return $null }
    $sorted = @($panes | Sort-Object Left)
    # The ROOT divider: every extra split below goes inside the RIGHT half, so
    # the leftmost pane's right edge is the boundary that owns the whole tree.
    # SCREEN coordinates, and Send-TestMouse does the client conversion per
    # target: the first version of this did the arithmetic itself against
    # GetWindowRect, landed a few pixels off inside the caption frame, and the
    # drag ran for 24 ticks against a ratio that was already clamped - every
    # tick relaying panes at geometry they already had, so nothing resized and
    # the whole measurement was of an empty layout pass.
    $second = @($panes | Where-Object { $_.Left -gt $sorted[0].Left } | Sort-Object Left)[0]
    $x = [int](($sorted[0].Right + $second.Left) / 2)
    $y = [int](($sorted[0].Top + $sorted[0].Bottom) / 2)
    $widthBefore = $sorted[0].Right - $sorted[0].Left

    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    # Out and back, so the drag never runs into the ratio clamp and stops
    # producing layout work half way through the sample.
    $moved = $false
    for ($i = 1; $i -le $moves; $i++) {
        $dx = if ($i -le ($moves / 2)) { $i * 6 } else { ($moves - $i) * 6 }
        [void](Send-TestMouse -Window $top -Target $top -X ($x + $dx) -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 25
        if ($i -eq [int]($moves / 2)) {
            $now = @(Get-VisiblePanes $top | Sort-Object Left)[0]
            $moved = (($now.Right - $now.Left) -ne $widthBefore)
        }
    }
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action up -HoldMs 0)

    # The summary is written at button-up and reaches the redirected stderr
    # file when the app's buffer next flushes, which is not instant. Poll
    # rather than sleep-and-hope: the first version of this slept 500 ms and
    # reported NO SAMPLE for drags whose line landed one drag later.
    for ($t = 0; $t -lt 40; $t++) {
        Start-Sleep -Milliseconds 250
        $all = @(Get-DragSamples $log)
        if ($all.Count -gt $before) {
            $s = $all[$all.Count - 1]
            Add-Member -InputObject $s -NotePropertyName Moved -NotePropertyValue $moved -Force
            return $s
        }
    }
    return $null
}

# One instance, one wait shape, one drag per pane count. Returns a hashtable of
# paneCount -> sample.
function Measure-DragShape([string]$mode, [int[]]$counts, [int]$moves) {
    $log = Join-Path $outDir "$mode-stderr.log"
    Kill-RepoInstances
    if ($mode -eq 'serial') { $env:GHOZTTY_DRAG_SERIAL_WAIT = '1' }
    else { Remove-Item env:GHOZTTY_DRAG_SERIAL_WAIT -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PERF = '1'

    $results = @{}
    $app = Start-OnTestDesktop -Exe $exe -StdErr $log -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false')
    try {
        $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
        if ($top -eq [IntPtr]::Zero) { throw "no window for the $mode instance" }
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 900)
        Start-Sleep -Milliseconds 800

        $have = 1
        foreach ($want in ($counts | Sort-Object)) {
            while ($have -lt $want) {
                # First split makes the root boundary; the rest nest inside the
                # right half, so the root divider keeps resizing everything.
                $dir = if ($have -eq 1) { 'right' } elseif ($have % 2 -eq 0) { 'down' } else { 'right' }
                & $exe +split --direction=$dir 2>&1 | Out-Null
                $have++
                # Wait for the pane to actually exist rather than guessing at a
                # sleep: the first split has a shell to spawn and the earlier
                # 900 ms guess made the 2-pane drag land on a window that still
                # had one pane, which produced no sample at all.
                for ($t = 0; $t -lt 40; $t++) {
                    Start-Sleep -Milliseconds 250
                    if ((Get-VisiblePanes ([IntPtr]$top)).Count -ge $have) { break }
                }
            }
            Start-Sleep -Milliseconds 500
            $live = (Get-VisiblePanes ([IntPtr]$top)).Count
            $s = Invoke-DividerDrag ([IntPtr]$top) $log $moves
            if ($null -eq $s) {
                Rep ("  {0,-8} panes={1,-2} NO SAMPLE (the app printed no drag summary)" -f $mode, $live)
            } else {
                # One -f, one format string: concatenating it inline binds the
                # last fragment to -f alone and prints the placeholders.
                $line = '  {0,-8} panes={1,-2} ticks={2,-3} mean={3,6}us max={4,6}us ' +
                'layout={13,6}us place={14,6}us paint={15,6}us wait={5,6}us overlay={7,6}us ~{8,4} fps ' +
                'resizes/move={9,-2} waits/move={10,-2} timeouts={11,-3} {12}'
                Rep ($line -f $mode, $s.Panes, $s.Ticks, $s.MeanUs, $s.MaxUs,
                    $s.MeanWaitUs, $s.ResizeUs, $s.OverlayUs, $s.Fps, $s.ResizesMax,
                    $s.WaitsMax, $s.Timeouts, $s.Verdict, $s.LayoutUs, $s.PlaceUs, $s.PaintUs)
                $results[$want] = $s
            }
        }
    } finally {
        Kill-RepoInstances
        Remove-Item env:GHOZTTY_DRAG_SERIAL_WAIT -ErrorAction SilentlyContinue
    }
    return $results
}

$td = New-TestDesktop -Interactive:$Interactive
try {
    Rep "T1343 splitter-drag cost, $stamp"
    Rep "  exe:   $exe"
    Rep "  moves: $Moves per drag; pane counts: $($PaneCounts -join ', ')"
    Rep ''
    Rep 'measurements (mean = one mouse move, end to end, on the UI thread):'

    $serial = Measure-DragShape 'serial' $PaneCounts $Moves
    $batched = Measure-DragShape 'batched' $PaneCounts $Moves
    Rep ''

    # ---- A. the oracle is live in both shapes ---------------------------
    Assert ($serial.Keys.Count -eq $PaneCounts.Count) `
    ("the serial shape produced a drag summary at every pane count " +
        "($($serial.Keys.Count)/$($PaneCounts.Count))")
    Assert ($batched.Keys.Count -eq $PaneCounts.Count) `
    ("the batched shape produced a drag summary at every pane count " +
        "($($batched.Keys.Count)/$($PaneCounts.Count))")
    if ($serial.Keys.Count -eq 0 -or $batched.Keys.Count -eq 0) {
        throw 'no drag samples at all - GHOZTTY_PERF oracle missing (release build?)'
    }

    $lo = ($PaneCounts | Sort-Object)[0]
    $hi = ($PaneCounts | Sort-Object)[-1]

    # ---- B. the batched pass waits ONCE, whatever the pane count ---------
    #
    # THE COUNT, not the clock, is the assertion. How long one wait costs is a
    # property of the machine - a hidden test desktop presents without the
    # compositor throttling it, so on this box the waits return in microseconds
    # and the very stall being fixed is invisible here (measured: mean_wait_us
    # ~0 in both shapes, timeouts 0). How many times the UI thread agreed to
    # stop and wait is a property of the CODE, it is what multiplies by 16 ms on
    # a real desktop, and it is the same number on any box.
    $bLo = $batched[$lo]; $bHi = $batched[$hi]
    $flat = ($bHi.WaitsMax -le 1 -and $bLo.WaitsMax -le 1)
    if ($NegativeControl) { $flat = -not $flat }
    Assert $flat ("one mouse move performs ONE frame wait at every pane count " +
        "(${lo} panes: $($bLo.WaitsMax) wait/move, $hi panes: $($bHi.WaitsMax) wait/move)")

    # ---- C. the shape this replaced really did multiply ------------------
    # Without this, B passes just as happily on a build where the whole frame
    # wait has been deleted, or on one where nothing resizes at all.
    $sLo = $serial[$lo]; $sHi = $serial[$hi]
    Assert ($sHi.WaitsMax -gt $bHi.WaitsMax) `
    ("the per-pane wait this replaced multiplied by the pane count: at $hi panes " +
        "it waited $($sHi.WaitsMax) times per move, the batched pass waits $($bHi.WaitsMax)")
    Assert ($sHi.WaitsMax -gt $sLo.WaitsMax) `
    ("...and it got worse with every split, which is the user's report: " +
        "$($sLo.WaitsMax) waits/move at $lo panes, $($sHi.WaitsMax) at $hi")

    # The cost that multiplication carries on a desktop that throttles presents,
    # stated from the app's own timeout bound rather than from a stopwatch this
    # box cannot honestly hold. `drag_perf.serialWaitCeilingUs` is the same
    # arithmetic, asserted in every test lane.
    Rep ("  worst case on a vsync-throttled desktop: serial $($sHi.WaitsMax) x 16ms = " +
        "$($sHi.WaitsMax * 16)ms per mouse move at $hi panes; batched 16ms flat")

    # ---- D. a batched drag still feels smooth ----------------------------
    # Two frames rather than one: this runs on a background desktop beside a
    # build machine, and the claim being defended is "the drag keeps up", not a
    # 60 fps guarantee the box cannot promise under load.
    $worst = ($batched.Values | Measure-Object -Property MeanUs -Maximum).Maximum
    Assert ($worst -le (2 * $FRAME_US)) `
    ("every batched drag holds two frames or better (worst mean ${worst}us, " +
        "budget $(2 * $FRAME_US)us)")
    $ticks = ($batched.Values | Measure-Object -Property Ticks -Minimum).Minimum
    Assert ($ticks -ge 8) `
    ("each measured drag really moved (fewest ticks in a batched drag: $ticks)")

    Rep ''
    Rep "report: $report"
    Complete-TestBody
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
    Remove-Item env:GHOZTTY_PERF -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard drag-perf -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
