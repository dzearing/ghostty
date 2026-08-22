# T126 acceptance: hero-mode key navigation reads the LIVE split tree, moves
# exactly one tile per press, and only ever moves the window it was aimed at.
#
# WHY THIS SCRIPT EXISTS. Main fixed three hero-navigation defects on the Mac
# that win32 never inherited the CODE for, so the only honest way to close the
# audit is to measure the win32 behavior directly:
#
#   280f2449e - the Mac's key monitor captured the split tree as it was when
#               hero mode was entered, so a pane added afterwards was
#               unreachable and a pane closed afterwards left the selection
#               pointing past the end. (Arms B and C.)
#   280f2449e - the same monitor was app-wide, so one press stepped EVERY
#               window in hero mode and each pulled focus to its own new
#               selection. (Arm D.)
#   4eb13a651 - a focused viewer pane re-injected the chord, so one press
#               stepped TWICE and skipped a pane. (Arm A's one-line-per-press
#               oracle, and arm E.)
#
# win32 has its own implementation (HeroCarousel.zig + hero_math.zig +
# Window.heroSelect), so none of those patches port. What the audit found is
# that the first two hazards are absent BY CONSTRUCTION here - gotoSplit /
# swapSplit / heroSelect read `tab_trees` and `leafCount` live, and a bound
# action is routed through `core_surface.rt_surface.parent_window`, so there is
# no snapshot to go stale and no app-wide monitor to spray. Construction is an
# argument, not evidence; these arms are the evidence.
#
# ARM E is the real defect the audit turned up. `viewer_accel.forwards()` did
# not admit `toggle_hero_mode`, so a focused viewer swallowed ctrl+shift+space
# into the page: with a viewer selected you could navigate the carousel but not
# leave hero mode, on a pane that T397 had already made a full carousel citizen.
#
# THE ORACLES. Two, and they answer different questions:
#   - GEOMETRY: in hero mode exactly ONE leaf is visible, and which HWND that
#     is names the selection. Reading it needs no pixels.
#   - THE DEBUG LOG: `heroSelect req=<asked> clamped=<taken> cur=<from> n=<leaf
#     count>` is emitted once per selection attempt, BEFORE the no-op early
#     return, so a clamped press is visible as a press. `n=` is the live leaf
#     count at the instant of the keystroke, which is what makes arms B and C
#     provable rather than plausible. One line per press is the anti-double-step
#     claim. A release build emits no log; those sub-claims then say so and skip
#     rather than passing vacuously.
#
# -NegativeControl inverts arm A to "the walk SKIPPED a pane", which must fail
# on a healthy build - that is the shape of the Mac's double-step bug.
#
# Runs on the background test desktop. Only touches ghoztty processes running
# from this repo's zig-out*.
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
$env:GHOZTTY_PIPE_SUFFIX = '-heronavtest'
$errlog = Join-Path $env:TEMP 'ghoztty-hero-nav-stderr.log'
Remove-Item $errlog -Force -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Skip([string]$label) { Write-Host "SKIP  $label" -ForegroundColor Yellow; $script:skipped++ }

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# ---- leaf enumeration ------------------------------------------------------

# Every leaf of a top-level window, BOTH kinds, hidden ones included. Hero mode
# hides all but the selected leaf, so the hidden ones are half the state.
#
# Unary comma on the return: PowerShell unrolls an array on return, so a
# one-element result would arrive as a scalar whose .Count is $null - and
# `$null -eq 1` is a quiet FAIL, not an error.
function Get-Leaves([IntPtr]$top) {
    $all = @()
    foreach ($cls in @('GhozttyTerminal', 'GhozttyViewer')) {
        $all += @(Get-TestChildWindows -Window $top -Class $cls | ForEach-Object {
            [pscustomobject]@{ Hwnd = [int64]$_.Hwnd; Kind = $cls; Visible = $_.Visible }
        })
    }
    return , @($all)
}

# The single visible leaf's HWND as a string (hero mode names the selection
# that way), or '' when the window is not showing exactly one.
# Leaf count from the TREE (`+list --json`), not from child HWNDs.
#
# A closed pane's child window is deliberately never destroyed:
# `Surface.deinit` says so in as many words - OPENGL32.dll hooks window
# destruction and segfaults after the WGL context is gone, so the HWND is left
# for the parent window's own teardown to reap. It survives hidden, at its last
# size, for the app's life. Counting HWNDs therefore counts corpses, and arm C
# is precisely the arm that closes something. Selection claims still read HWNDs
# (a corpse is hidden, and hero mode's claim is about the VISIBLE leaf).
function Get-TreeLeaves($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node) }
    return @(Get-TreeLeaves $node.left) + @(Get-TreeLeaves $node.right)
}
function Get-TreeLeafCount([string]$target) {
    $j = & $exe +list --json | ConvertFrom-Json
    foreach ($w in @($j.data.windows)) {
        if ($w.target -ne $target) { continue }
        $n = 0
        foreach ($tab in @($w.tabs)) { $n += @(Get-TreeLeaves $tab.splits).Count }
        return $n
    }
    return -1
}
function Wait-TreeLeafCount([string]$target, [int]$want, [int]$timeoutMs = 10000) {
    $deadline = [Environment]::TickCount + $timeoutMs
    while ([Environment]::TickCount -lt $deadline) {
        if ((Get-TreeLeafCount $target) -eq $want) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Get-HeroId([IntPtr]$top) {
    $v = @((Get-Leaves $top) | Where-Object Visible)
    if ($v.Count -ne 1) { return '' }
    return "$($v[0].Hwnd)"
}

# ---- the debug-log oracle --------------------------------------------------

$script:haveLog = $false
$script:hsPattern = 'heroSelect req=(-?\d+) clamped=(\d+) cur=(\d+) n=(\d+)'

# Both readers re-scan the whole file. It is small, and the alternative - a
# tail-follow - would need state this script does not otherwise keep.
#
# Deliberately SCALAR-returning, one number and one record. An earlier draft
# returned the parsed array with the usual unary-comma guard, and
# `@(Get-...).Count` then read 1 (the whole array as one item) on every call:
# the per-press deltas were all 0, and `.N` on the array came back as an ARRAY
# of Ns, which Assert cannot coerce. A helper that hands back one value cannot
# be got wrong that way.
function Get-HeroSelectCount {
    if (-not $script:haveLog) { return 0 }
    $n = 0
    foreach ($m in @(Select-String -Path $errlog -Pattern $script:hsPattern -AllMatches)) {
        $n += $m.Matches.Count
    }
    return $n
}
function Get-LastHeroSelect {
    if (-not $script:haveLog) { return $null }
    $last = $null
    foreach ($m in @(Select-String -Path $errlog -Pattern $script:hsPattern -AllMatches)) {
        foreach ($g in $m.Matches) { $last = $g }
    }
    if ($null -eq $last) { return $null }
    return [pscustomobject]@{
        Req = [int]$last.Groups[1].Value
        Clamped = [int]$last.Groups[2].Value
        Cur = [int]$last.Groups[3].Value
        N = [int]$last.Groups[4].Value
    }
}

# ---- input -----------------------------------------------------------------

# A nav chord at the window's currently selected (= only visible) leaf, then
# time for the deferred SetFocus (T48) and the 350ms selection slide to settle,
# so the caller's sample is post-navigation rather than mid-animation.
function Send-Nav([IntPtr]$top, [string]$key, [string[]]$mods = @('ctrl', 'alt')) {
    $v = @((Get-Leaves $top) | Where-Object Visible)
    if ($v.Count -ne 1) { return $false }
    $ok = Send-TestKeys -Window $top -Target ([IntPtr]$v[0].Hwnd) -Modifiers $mods -Key $key
    Start-Sleep -Milliseconds 800
    return $ok
}

# Park the selection on the FIRST tile. `$n` presses of Up can never overshoot
# (heroSelect clamps at 0), so the strip ends at index 0 wherever it started.
function Reset-ToTop([IntPtr]$top, [int]$n) {
    for ($i = 0; $i -lt $n; $i++) { Send-Nav $top 'Up' | Out-Null }
}

# Walk the strip top to bottom, one ctrl+alt+Down per step. Returns the HWNDs
# visited in order plus, per step, how many heroSelect lines that ONE press
# produced (the anti-double-step number).
function Walk-Strip([IntPtr]$top, [int]$n) {
    Reset-ToTop $top $n
    $seen = New-Object System.Collections.Generic.List[string]
    $lines = New-Object System.Collections.Generic.List[int]
    $seen.Add((Get-HeroId $top))
    for ($i = 1; $i -lt $n; $i++) {
        $before = Get-HeroSelectCount
        Send-Nav $top 'Down' | Out-Null
        $lines.Add((Get-HeroSelectCount) - $before)
        $seen.Add((Get-HeroId $top))
    }
    return @{ Seen = @($seen.ToArray()); Lines = @($lines.ToArray()) }
}

# ---------------------------------------------------------------------------

Stop-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue

$viewFile = Join-Path $env:TEMP 'ghoztty-hero-nav-view.md'
Set-Content -Path $viewFile -Encoding UTF8 -Value @'
# Hero nav viewer fixture

A viewer pane is a full carousel citizen, so the chord that leaves hero mode
has to answer while it holds focus.
'@

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$appA = $null
$appPid = 0

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: arm A is inverted to "the walk SKIPPED a pane" - this run MUST fail'
    }

    # session-persistence=false: the force-kills this script brackets itself
    # with would otherwise leave sessions that re-attach LAST run's shells.
    $sp = @{ Exe = $exe; Arguments = @('--config-default-files=false', '--session-persistence=false') }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $appA = Start-OnTestDesktop @sp
    $appPid = [int]$appA.Pid
    Start-Sleep -Seconds 3
    if ($appA.Process -and $appA.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $topA = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    if ($topA -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Set-TestWindowSize -Window $topA -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) `
        'GUI is NOT enumerable on the interactive desktop'

    $script:haveLog = (Test-Path $errlog)
    if (-not $script:haveLog) {
        Write-Host 'NOTE: no debug log (release build) - the per-press log claims will SKIP; geometry still decides'
    }

    # The auto-name of the first window, so arm C can ask the TREE how many
    # leaves it has (see Get-TreeLeafCount for why HWNDs cannot answer that).
    $targetA = (& $exe +list --json | ConvertFrom-Json).data.windows[0].target
    Assert ($targetA -is [string] -and $targetA.Length -gt 0) "setup: window A is targetable as '$targetA'"

    # A four-leaf strip: enough that a skipped pane is a skipped pane rather
    # than a clamp at an end.
    foreach ($name in @('heron_b', 'heron_c', 'heron_d')) {
        & $exe +split --direction=down --name=$name | Out-Null
        Start-Sleep -Milliseconds 700
    }
    $leaves = Get-Leaves $topA
    Assert ($leaves.Count -eq 4) "setup: 4 terminal leaves (got $($leaves.Count))"
    if ($leaves.Count -ne 4) { Write-Host 'ABORT: 4-pane fixture not built'; exit 1 }
    $allA = @($leaves | ForEach-Object { "$($_.Hwnd)" })

    # POSITIVE CONTROL: a chord posted at a terminal reaches binding dispatch,
    # so a dead nav below cannot be blamed on injection (T157's lesson).
    $focus0 = [IntPtr]$leaves[0].Hwnd
    Assert (Send-TestKeys -Window $topA -Target $focus0 -Modifiers ctrl -Key K) `
        'CONTROL: ctrl+k injected at a terminal'
    Start-Sleep -Milliseconds 500
    if ($script:haveLog) {
        $ctl = (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet) -eq $true
        if (-not $ctl) {
            Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection is broken, not hero nav'
            exit 1
        }
        Write-Host 'OK    CONTROL: injection reaches bindings (clear_screen dispatched)'
    }

    # --- Enter hero mode -----------------------------------------------------
    Assert (Send-TestKeys -Window $topA -Target $focus0 -Modifiers ctrl, shift -Key Space) `
        'hero toggle chord delivered'
    Start-Sleep -Milliseconds 1200
    Assert (-not ($appA.Process -and $appA.Process.HasExited)) 'no crash entering hero mode'
    Assert ((Get-HeroId $topA) -ne '') 'hero on: exactly one visible leaf'

    # --- Arm A: arrow navigation skips nothing -------------------------------
    # n-1 presses from the top must visit all n leaves, each press landing on a
    # leaf not yet seen. A double-delivered chord (the Mac's viewer bug) shows
    # up as a short visit list with a gap in it.
    $walk = Walk-Strip $topA 4
    $distinct = @($walk.Seen | Sort-Object -Unique)
    $noBlank = @($walk.Seen | Where-Object { $_ -eq '' }).Count -eq 0
    Assert $noBlank 'A: every step of the walk left exactly one visible leaf'
    $covered = ($distinct.Count -eq 4) -and (@($distinct | Where-Object { $allA -notcontains $_ }).Count -eq 0)
    if ($NegativeControl) {
        Assert (-not $covered) "A: 3 presses from the top visit all 4 leaves, none twice (visited $($distinct.Count))"
    } else {
        Assert $covered "A: 3 presses from the top visit all 4 leaves, none twice (visited $($distinct.Count) of 4)"
    }
    if ($script:haveLog) {
        $single = @($walk.Lines | Where-Object { $_ -ne 1 }).Count -eq 0
        Assert $single "A: each press produced exactly ONE heroSelect (got $($walk.Lines -join ',')) - no double-step"
        $lastA = Get-LastHeroSelect
        $lastN = if ($null -ne $lastA) { $lastA.N } else { -1 }
        Assert ($lastN -eq 4) "A: navigation counted 4 leaves (n=$lastN)"
    } else {
        Skip 'A: per-press heroSelect log claims (no debug log)'
    }

    # --- Arm B: a pane added while hero mode is ACTIVE is reachable ----------
    # The Mac symptom: Cmd+Shift+Down stopped one short, because the monitor
    # was walking the pane list as it was when hero mode was entered.
    & $exe +split --direction=down --name=heron_e | Out-Null
    Start-Sleep -Milliseconds 1200
    $leaves5 = Get-Leaves $topA
    Assert ($leaves5.Count -eq 5) "B: the split landed while hero was on (got $($leaves5.Count) leaves)"
    Assert ((Get-HeroId $topA) -ne '') 'B: hero mode survived the split (still one visible leaf)'
    $allA5 = @($leaves5 | ForEach-Object { "$($_.Hwnd)" })
    $walk5 = Walk-Strip $topA 5
    $distinct5 = @($walk5.Seen | Sort-Object -Unique)
    Assert (($distinct5.Count -eq 5) -and (@($distinct5 | Where-Object { $allA5 -notcontains $_ }).Count -eq 0)) `
        "B: 4 presses reach all 5 leaves including the one added mid-hero (visited $($distinct5.Count) of 5)"
    if ($script:haveLog) {
        $lastB = Get-LastHeroSelect
        $lastN5 = if ($null -ne $lastB) { $lastB.N } else { -1 }
        Assert ($lastN5 -eq 5) "B: navigation counted the LIVE 5 leaves, not the 4 hero mode opened with (n=$lastN5)"
    } else {
        Skip 'B: live leaf-count log claim (no debug log)'
    }

    # --- Arm C: a pane closed while hero mode is active clamps ---------------
    # The Mac symptom: the selection pointed past the end of the list. Here the
    # selection is parked on the LAST tile first, so the close is guaranteed to
    # be the case that needs clamping.
    Send-Nav $topA 'Down' | Out-Null   # already at the bottom; a no-op that proves it
    & $exe +close --target=heron_e | Out-Null
    $settled = Wait-TreeLeafCount $targetA 4
    Assert $settled "C: the pane closed while hero was on (tree has $(Get-TreeLeafCount $targetA) leaves)"
    Assert ((Get-HeroId $topA) -ne '') 'C: the selection did not point past the end (still one visible leaf)'
    $beforeC = Get-HeroSelectCount
    Send-Nav $topA 'Up' | Out-Null
    if ($script:haveLog) {
        Assert ((Get-HeroSelectCount) -gt $beforeC) 'C: the pane still navigates after the close'
        $lastC = Get-LastHeroSelect
        if ($null -ne $lastC) {
            Assert ($lastC.N -eq 4) "C: navigation counted the LIVE 4 leaves (n=$($lastC.N))"
            Assert ($lastC.Cur -lt 4) "C: the selection was inside the tree when the key landed (cur=$($lastC.Cur), n=4)"
        }
    } else {
        Skip 'C: post-close log claims (no debug log)'
    }

    # --- Arm D: one press moves only the window it was aimed at --------------
    # The Mac symptom: with two windows in hero mode, one press stepped BOTH
    # (measured A=1 B=1, then A=2 B=2) and each pulled focus to its own new
    # selection. On win32 a bound action rides the focused surface to its own
    # parent window, so this is the arm that proves there is no app-wide hook.
    $topsBefore = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | ForEach-Object { [int64]$_.Hwnd })
    & $exe +new-window --target=heronav2 | Out-Null
    Start-Sleep -Seconds 2
    $topB = [IntPtr]::Zero
    for ($t = 0; $t -lt 25 -and $topB -eq [IntPtr]::Zero; $t++) {
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ($topsBefore -notcontains [int64]$w.Hwnd) { $topB = [IntPtr][int64]$w.Hwnd }
        }
        if ($topB -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
    }
    Assert ($topB -ne [IntPtr]::Zero) 'D: second window created'
    if ($topB -ne [IntPtr]::Zero) {
        Set-TestWindowSize -Window $topB -Width 1000 -Height 700 | Out-Null
        & $exe +split --target=heronav2 --direction=down --name=heron_b2 | Out-Null
        Start-Sleep -Milliseconds 1000
        $leavesB = Get-Leaves $topB
        Assert ($leavesB.Count -eq 2) "D: window B has 2 leaves (got $($leavesB.Count))"

        Assert (Send-TestKeys -Window $topB -Target ([IntPtr]$leavesB[0].Hwnd) -Modifiers ctrl, shift -Key Space) `
            'D: hero toggle delivered to window B'
        Start-Sleep -Milliseconds 1200
        $heroB0 = Get-HeroId $topB
        $heroA0 = Get-HeroId $topA
        Assert (($heroA0 -ne '') -and ($heroB0 -ne '')) 'D: both windows are in hero mode'

        if (($heroA0 -ne '') -and ($heroB0 -ne '')) {
            # Down, then Up if Down was a clamp. Child-window enumeration order
            # is z-order, not the tree-iteration order the strip is built from,
            # so "leaf 0" here may already be the LAST tile and pressing Down
            # from it is a correct no-op (hero-mode.ps1 learned this the hard
            # way on 2026-07-16).
            $heroA1 = $heroA0
            foreach ($k in 'Down', 'Up') {
                if ($heroA1 -ne $heroA0) { break }
                Send-Nav $topA $k | Out-Null
                $heroA1 = Get-HeroId $topA
            }
            $heroB1 = Get-HeroId $topB
            Assert ($heroA1 -ne $heroA0) 'D: a press aimed at window A moved window A'
            Assert ($heroB1 -eq $heroB0) 'D: ...and left window B exactly where it was'

            $heroB2 = $heroB1
            foreach ($k in 'Down', 'Up') {
                if ($heroB2 -ne $heroB1) { break }
                Send-Nav $topB $k | Out-Null
                $heroB2 = Get-HeroId $topB
            }
            $heroA2 = Get-HeroId $topA
            Assert ($heroB2 -ne $heroB1) 'D: a press aimed at window B moved window B'
            Assert ($heroA2 -eq $heroA1) 'D: ...and left window A exactly where it was'
        }
    }

    # --- Arm E: hero mode toggles from a FOCUSED VIEWER pane (T126 fix) ------
    # `viewer_accel.forwards()` did not admit `toggle_hero_mode`, so the chord
    # fell through to the page: a selected viewer could be navigated but not
    # navigated OUT of. The chord goes to Chrome_WidgetWin_1, the only HWND in
    # WebView2's chain whose loop turns a posted WM_KEYDOWN into an
    # AcceleratorKeyPressed event (probed on-box, 2026-08-06 - see
    # viewer-panes.ps1 section 11b).
    & $exe +split --target=heronav2 --direction=right --name=heron_view "--view=$viewFile" | Out-Null
    Start-Sleep -Seconds 3
    $leavesBv = Get-Leaves $topB
    $viewers = @($leavesBv | Where-Object { $_.Kind -eq 'GhozttyViewer' })
    Assert ($viewers.Count -eq 1) "E: window B gained a viewer leaf (got $($viewers.Count))"
    Assert ((Get-HeroId $topB) -ne '') 'E: hero mode survived adding the viewer'

    $chrome = [IntPtr]::Zero
    $viewHost = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $chrome -eq [IntPtr]::Zero; $t++) {
        foreach ($h in @(Get-TestChildWindows -Window $topB -Class 'GhozttyViewer')) {
            if (-not $h.Visible) { continue }
            $widget = @(Get-TestChildWindows -Window ([IntPtr][int64]$h.Hwnd) -Class '*' |
                Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' })
            if ($widget.Count -ge 1) {
                $chrome = [IntPtr][int64]$widget[0].Hwnd
                $viewHost = [IntPtr][int64]$h.Hwnd
            }
        }
        if ($chrome -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
    }
    Assert ($chrome -ne [IntPtr]::Zero) 'E: the viewer is the selected leaf and its Chromium input child is up'

    if ($chrome -ne [IntPtr]::Zero) {
        Focus-TestWindow -Window $topB -Child $viewHost | Out-Null
        Start-Sleep -Milliseconds 400

        # POSITIVE CONTROL for this arm: a chord that was ALREADY forwarded
        # (goto_split, the hero nav chord) works from the viewer. Without it, a
        # dead toggle below could be dead injection.
        $navBefore = Get-HeroId $topB
        Assert (Send-TestViewerChord -Window $topB -Target $chrome -Modifiers ctrl, alt -Key Up) `
            'E CONTROL: ctrl+alt+Up injected at the viewer'
        Start-Sleep -Milliseconds 1200
        Assert ((Get-HeroId $topB) -ne $navBefore) 'E CONTROL: hero nav already answered from a focused viewer'

        # Back to the viewer, then the chord under test, both directions.
        Focus-TestWindow -Window $topB -Child $viewHost | Out-Null
        Start-Sleep -Milliseconds 300
        Send-TestViewerChord -Window $topB -Target $chrome -Modifiers ctrl, alt -Key Down | Out-Null
        Start-Sleep -Milliseconds 1200
        $onViewer = (Get-TestWindowClass -Window ([IntPtr](Get-TestFocusedWindow -Window $topB)))
        Write-Host "      (focus class before the toggle: $onViewer)"

        Assert (Send-TestViewerChord -Window $topB -Target $chrome -Modifiers ctrl, shift -Key Space) `
            'E: ctrl+shift+space injected at the viewer'
        Start-Sleep -Milliseconds 1500
        # Assigned first, then counted: `@(Get-Leaves ...).Count` is 1 (the
        # whole array as one item), the same unary-comma trap the log readers
        # above document.
        $leavesE = Get-Leaves $topB
        $totalB = $leavesE.Count
        $allVisible = @($leavesE | Where-Object Visible).Count
        $left = ($allVisible -eq $totalB) -and ($totalB -gt 1)
        Assert $left "E: hero mode LEFT from a focused viewer (visible $allVisible of $totalB leaves)"

        # Gated on the leave, not run beside it. On the unfixed build the
        # window never left hero mode, so an unconditional "entered again"
        # assertion passes on the broken behavior it is supposed to catch -
        # a green line next to the red one, which is worse than no line.
        if ($left) {
            Focus-TestWindow -Window $topB -Child $viewHost | Out-Null
            Start-Sleep -Milliseconds 400
            Assert (Send-TestViewerChord -Window $topB -Target $chrome -Modifiers ctrl, shift -Key Space) `
                'E: ctrl+shift+space injected at the viewer again'
            Start-Sleep -Milliseconds 1500
            Assert ((Get-HeroId $topB) -ne '') 'E: ...and hero mode ENTERED again from the same viewer'
        } else {
            Skip 'E: re-enter from the viewer (it never left, so there is nothing to re-enter)'
        }
        Assert (-not ($appA.Process -and $appA.Process.HasExited)) 'E: no crash toggling hero from a viewer'
    }
}
finally {
    if ($appPid -ne 0) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue }
    Stop-RepoInstances
    Remove-TestDesktop -Desktop $td
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
$launched = @(Get-TestLaunchedPids)
$leaked = @($fgSeen | Where-Object { $launched -contains $_ })
Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'

if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass$(if ($script:skipped) { ", $script:skipped SKIPPED" }))" -ForegroundColor Green; exit 0 }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
