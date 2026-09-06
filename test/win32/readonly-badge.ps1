# T445 acceptance: a read-only pane wears a badge, per pane, and the badge is
# the way back out of the mode.
#
# Read-only drops every keystroke on the floor. Until this task the win32
# `.readonly` apprt action was an acknowledged no-op, so a read-only pane and
# a wedged pane looked exactly alike and the only way to tell them apart was
# to open the context menu and look for a checkmark. The badge
# (class GhozttyReadonlyBadge, a WS_EX_LAYERED popup owned by the pane's
# surface HWND, `ReadonlyBadge.zig`) is the mark.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never
# steals the user's foreground - asserted here, not assumed.
#
# ORACLES. All structural, none pixel-based, and that is a decision rather
# than an omission:
#
#   - EXISTENCE + VISIBILITY of the badge window, per pane. A popup is its own
#     top-level window, so `Get-TestWindows -Class GhozttyReadonlyBadge` sees
#     it off the input desktop exactly as on it.
#   - WHICH PANE it marks, by rect containment against each pane's own rect.
#     This is the assertion that a tab-title glyph could not have made, and
#     the reason decision D30 chose a per-pane badge.
#   - THE ANCHOR, computed rather than eyeballed. The badge's window is the
#     card plus its shadow allowance, so the gap from the pane's top and right
#     edges is exactly `round(INSET*s) - (round(SHADOW_BLUR*s) +
#     round(SHADOW_DY*s))` = 8s - (4s + 2s) in DIP. Recomputed here from the
#     window's real DPI, which is what makes it a regression test for the
#     geometry and not a restatement of it.
#
# CAPTURE LIMIT, named rather than quietly dropped: the badge paints through
# UpdateLayeredWindow and never services WM_PAINT, so PrintWindow (what
# Get-TestWindowPixels uses) has nothing to render and cannot confirm the
# CARD's colors or the label. Those are covered where they are decidable
# instead - `readonly_badge.zig`'s unit tests assert the card's opacity, its
# fill, the drop shade's falloff, the border ring's color, and both WCAG
# floors, swept over the whole background ramp at 1.0/1.25/1.5/2.0.
#
# A positive control (ctrl+k clear_screen, the T55/T74 pattern) runs first, so
# a broken injection aborts with a diagnosis instead of reading as a T445
# regression.
#
# Only touches ghoztty processes running from this repo's zig-out*.
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
# Always isolate the IPC endpoint: the app inherits this env through
# CreateProcessW and so does every `& $exe +...` below, so the user's own
# instance is never queried or disturbed.
$env:GHOZTTY_PIPE_SUFFIX = "-rotest$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-readonly-badge-stderr.log'

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

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# Zig's @round is half-away-from-zero; [math]::Round is banker's by default,
# which disagrees at exactly .5 - i.e. at 1.25 scaling, which is the scale
# most of these defects first show up at.
function Px([double]$dip, [double]$scale) {
    return [int][math]::Round($dip * $scale, [System.MidpointRounding]::AwayFromZero)
}

function Get-Badges([int]$procId) {
    return @(Get-TestWindows -ProcessId $procId -Class 'GhozttyReadonlyBadge')
}

function Get-VisibleBadges([int]$procId) {
    return @(Get-Badges $procId | Where-Object Visible)
}

# Poll until the visible-badge count settles on $want (focus and layout land
# asynchronously through the T48 deferred-SetFocus path).
#
# The `@()` is load-bearing: a function's array return UNROLLS in PS 5.1, so a
# one-element result arrives as a bare pscustomobject whose `.Count` is $null
# — which never equals 1 and turned every wait into a silent 3s timeout that
# still passed at the call site.
function Wait-BadgeCount([int]$procId, [int]$want) {
    for ($t = 0; $t -lt 30; $t++) {
        $found = @(Get-VisibleBadges $procId)
        if ($found.Count -eq $want) { return $found }
        Start-Sleep -Milliseconds 100
    }
    Write-Host "DEBUG wait timeout: wanted $want visible badge(s)"
    Get-Badges $procId | ForEach-Object {
        Write-Host "DEBUG raw badge: $($_.Hwnd) vis=$($_.Visible) $($_.Left),$($_.Top),$($_.Right),$($_.Bottom)"
    }
    return (Get-VisibleBadges $procId)
}

# T574: the machine-readable half of the badge. Every terminal leaf `+list
# --json` reports, as objects with `.name` and `.readonly` — the field is
# ADDITIVE, so a pane that is not read-only has no `readonly` key at all and
# `.readonly` reads as $null there rather than $false.
function Get-PaneReadonly {
    $json = & $exe +list --json 2>$null | Out-String
    if (-not $json -or $json.Trim().Length -eq 0) { return @() }
    try { $tree = $json | ConvertFrom-Json } catch { return @() }
    if ($null -eq $tree) { return @() }
    $root = if ($tree.PSObject.Properties.Name -contains 'data') { $tree.data } else { $tree }
    $out = @()
    foreach ($w in @($root.windows)) {
        foreach ($t in @($w.tabs)) {
            $stack = New-Object System.Collections.Stack
            $stack.Push($t.splits)
            while ($stack.Count -gt 0) {
                $n = $stack.Pop()
                if ($null -eq $n) { continue }
                if ($n.type -eq 'leaf') {
                    $term = $n.terminal
                    if ($term) {
                        $has = @($term.PSObject.Properties.Name) -contains 'readonly'
                        $out += [pscustomobject]@{
                            Name     = $term.name
                            Focused  = [bool]$term.focused
                            Present  = $has
                            Readonly = if ($has) { [bool]$term.readonly } else { $false }
                        }
                    }
                } else {
                    if ($n.right) { $stack.Push($n.right) }
                    if ($n.left) { $stack.Push($n.left) }
                }
            }
        }
    }
    # Plain `return`: `return ,$out` counts an EMPTY array as one element at an
    # `@()` call site (the PS 5.1 trap PaneIdle.ps1 names).
    return $out
}

# Poll `+list --json` until the number of panes reporting read-only settles on
# $want. The badge and the wire field are driven from the same core state, but
# they are published on different paths, so this waits rather than assuming
# the badge's settle already covered it.
function Wait-ReadonlyCount([int]$want) {
    for ($t = 0; $t -lt 30; $t++) {
        $leaves = @(Get-PaneReadonly)
        $on = @($leaves | Where-Object { $_.Readonly })
        if ($on.Count -eq $want) { return $leaves }
        Start-Sleep -Milliseconds 100
    }
    return @(Get-PaneReadonly)
}

# Is $inner entirely inside $outer?
function Inside($inner, $outer) {
    return ($inner.Left -ge $outer.Left) -and ($inner.Top -ge $outer.Top) -and
           ($inner.Right -le $outer.Right) -and ($inner.Bottom -le $outer.Bottom)
}

Stop-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$app = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: section C asserts the badge is anchored at a DELIBERATELY WRONG inset - this run MUST fail'
    }

    Remove-Item $errlog -ErrorAction SilentlyContinue
    # --session-persistence=false is mandatory: a launch writes a
    # session-layout manifest that the NEXT run would restore, so the second
    # run would come up with this run's panes.
    $sp = @{
        Exe       = $exe
        Arguments = @(
            '--session-persistence=false',
            '--background=#101014',
            '--keybind=ctrl+shift+o=toggle_readonly'
        )
    }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'window is NOT enumerable on the interactive desktop'

    $dpi = Get-TestWindowDpi -Window $top
    if (-not $dpi -or $dpi -le 0) { $dpi = 96 }
    $scale = [double]$dpi / 96.0
    # The badge window is the card plus its shadow allowance, so the gap from
    # the pane edge is the inset MINUS that allowance.
    $wantGap = (Px 8 $scale) - ((Px 4 $scale) + (Px 2 $scale))
    Write-Host "INFO  dpi=$dpi scale=$scale expected pane-edge gap=$wantGap px"

    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    Assert ($panes.Count -eq 1) "setup: one pane ($($panes.Count))"
    if ($panes.Count -lt 1) { exit 1 }
    $paneA = $panes[0]

    # -----------------------------------------------------------------------
    # Positive control: the chord reaches binding dispatch at all.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Modifiers ctrl -Key K
    if (-not $r) { Write-Host 'ABORT: control chord not sent'; exit 1 }
    Start-Sleep -Milliseconds 400
    if (Test-Path $errlog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T445 verdict'
            exit 1
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    # PowerShell variable names are CASE-INSENSITIVE, so a badge list in `$b`
    # and a pane in `$B` are ONE variable. That cost two false failures here
    # (the pane silently became the badge list, so "the badge is not on the
    # new pane" compared the badge to itself and the next chord went to the
    # badge's own HWND). Hence `$paneA`/`$paneB` and `$badges`.

    # -----------------------------------------------------------------------
    # A. A pane that is not read-only wears nothing.
    # -----------------------------------------------------------------------
    $badges = @(Get-VisibleBadges $app.Pid)
    Assert ($badges.Count -eq 0) "A: no badge before read-only is turned on ($($badges.Count))"

    # T574: and the wire says so too — additively, i.e. by omitting the key.
    $leaves = @(Get-PaneReadonly)
    Assert ($leaves.Count -eq 1) "A: +list --json reports one pane ($($leaves.Count))"
    Assert (@($leaves | Where-Object { $_.Present }).Count -eq 0) `
        'A: +list --json omits `readonly` entirely while the mode is off'

    # -----------------------------------------------------------------------
    # B. Toggling read-only marks the pane, immediately.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Modifiers ctrl, shift -Key O
    Assert $r 'B: toggle_readonly chord delivered'
    $badges = @(Wait-BadgeCount $app.Pid 1)
    Assert ($badges.Count -eq 1) "B: exactly one visible badge ($($badges.Count))"
    if ($badges.Count -ne 1) { throw 'no badge to measure' }
    $badge = $badges[0]
    Assert (Inside $badge $paneA) 'B: the badge is inside the pane it marks'

    # T574: an automation that finds +send-keys swallowed can now ASK why.
    $leaves = @(Wait-ReadonlyCount 1)
    $on = @($leaves | Where-Object { $_.Readonly })
    Assert ($on.Count -eq 1) "B: +list --json reports exactly one read-only pane ($($on.Count))"
    if ($on.Count -eq 1) {
        Assert ($on[0].Focused) 'B: the pane reported read-only is the one that was toggled'
    }

    # -----------------------------------------------------------------------
    # C. The anchor: top-right of the pane, at the computed inset.
    # -----------------------------------------------------------------------
    $gapRight = $paneA.Right - $badge.Right
    $gapTop = $badge.Top - $paneA.Top
    $script:negReached = $true
    $want = if ($NegativeControl) { $wantGap + 5 } else { $wantGap }
    Assert ($gapRight -eq $want) "C: badge is $want px from the pane's right edge (got $gapRight)"
    Assert ($gapTop -eq $want) "C: badge is $want px from the pane's top edge (got $gapTop)"
    # It really is a corner chip, not a band: nowhere near full pane width.
    Assert (($badge.Right - $badge.Left) -lt [int](($paneA.Right - $paneA.Left) / 2)) `
        'C: the badge is a corner chip, not a full-width strip'

    # -----------------------------------------------------------------------
    # D. Window style: layered (so it composites over the pane's OpenGL
    #    content) and NOT click-through (so it can be the way out).
    # -----------------------------------------------------------------------
    $ex = Get-TestWindowStyle -Window ([IntPtr]$badge.Hwnd) -ExStyle
    Assert (($ex -band 0x80000) -ne 0) 'D: badge is WS_EX_LAYERED'
    Assert (($ex -band 0x8000000) -ne 0) 'D: badge is WS_EX_NOACTIVATE'
    Assert (($ex -band 0x20) -eq 0) 'D: badge is NOT WS_EX_TRANSPARENT (it is clickable)'

    # -----------------------------------------------------------------------
    # E. Per-pane, which is the whole point. Split: the new pane is not
    #    read-only, so it gets no badge, and the old one keeps its own -
    #    re-anchored to its NEW right edge, since the split shrank it.
    # -----------------------------------------------------------------------
    & $exe +split --direction=right | Out-Null
    Start-Sleep -Milliseconds 1000
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Sort-Object Left)
    Assert ($panes.Count -eq 2) "E: split produced 2 panes ($($panes.Count))"
    if ($panes.Count -eq 2) {
        $paneA = $panes[0]; $paneB = $panes[1]
        $badges = @(Wait-BadgeCount $app.Pid 1)
        Assert ($badges.Count -eq 1) "E: still exactly one badge after the split ($($badges.Count))"
        if ($badges.Count -eq 1) {
            $badge = $badges[0]
            Assert (Inside $badge $paneA) 'E: the badge stayed on the read-only pane'
            Assert (-not (Inside $badge $paneB)) 'E: the badge is NOT on the new pane'
            # The split moved pane A's right edge; the badge followed it.
            Assert (($paneA.Right - $badge.Right) -eq $wantGap) `
                "E: badge re-anchored to the pane's new right edge (got $($paneA.Right - $badge.Right))"
        }

        # -------------------------------------------------------------------
        # F. Both panes read-only -> two badges, one per pane.
        # -------------------------------------------------------------------
        $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneB.Hwnd) -Modifiers ctrl, shift -Key O
        Assert $r 'F: toggle_readonly chord delivered to pane B'
        $badges = @(Wait-BadgeCount $app.Pid 2)
        Assert ($badges.Count -eq 2) "F: two visible badges, one per read-only pane ($($badges.Count))"
        if ($badges.Count -eq 2) {
            $onA = @($badges | Where-Object { Inside $_ $paneA })
            $onB = @($badges | Where-Object { Inside $_ $paneB })
            Assert ($onA.Count -eq 1 -and $onB.Count -eq 1) 'F: one badge on each pane'

            # T574: two badges, two panes on the wire — this is the assertion
            # a single global flag could not have passed.
            $leaves = @(Wait-ReadonlyCount 2)
            Assert ((@($leaves | Where-Object { $_.Readonly })).Count -eq 2) `
                "F: +list --json reports both panes read-only ($((@($leaves | Where-Object { $_.Readonly })).Count))"
            Assert ($leaves.Count -eq 2) "F: +list --json still reports two panes ($($leaves.Count))"

            # ---------------------------------------------------------------
            # G. Clicking a badge leaves read-only - the mark is the way out.
            # ---------------------------------------------------------------
            if ($onB.Count -eq 1) {
                $target = $onB[0]
                $cx = [int](($target.Left + $target.Right) / 2)
                $cy = [int](($target.Top + $target.Bottom) / 2)
                $r = Send-TestMouse -Window $top -Target ([IntPtr]$target.Hwnd) `
                    -X $cx -Y $cy -Button left -Action click
                Assert $r 'G: click delivered to the badge'
                $badges = @(Wait-BadgeCount $app.Pid 1)
                Assert ($badges.Count -eq 1) "G: clicking the badge left read-only ($($badges.Count) badge(s) left)"
                if ($badges.Count -eq 1) {
                    Assert (Inside $badges[0] $paneA) "G: the OTHER pane's badge is untouched"
                }
                # T574: leaving the mode drops the key again, on that pane only.
                $leaves = @(Wait-ReadonlyCount 1)
                Assert ((@($leaves | Where-Object { $_.Readonly })).Count -eq 1) `
                    "G: +list --json reports one read-only pane after the click ($((@($leaves | Where-Object { $_.Readonly })).Count))"
                Assert ((@($leaves | Where-Object { -not $_.Present })).Count -eq 1) `
                    'G: the pane that left read-only has no `readonly` key at all'
            }
        }
    }

    # -----------------------------------------------------------------------
    # H. Toggling back off clears the mark.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Modifiers ctrl, shift -Key O
    Assert $r 'H: toggle_readonly off chord delivered'
    $badges = @(Wait-BadgeCount $app.Pid 0)
    Assert ($badges.Count -eq 0) "H: no visible badge once read-only is off ($($badges.Count))"

    # T574: and the field is gone from every pane, not merely false.
    $leaves = @(Wait-ReadonlyCount 0)
    Assert ((@($leaves | Where-Object { $_.Present })).Count -eq 0) `
        'H: +list --json omits `readonly` on every pane once the mode is off'

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Stop-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

# A -NegativeControl run that never reached the inverted assertion proves
# nothing, and would otherwise report a clean pass.
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

# --- stamp (T783, row added by T574) --------------------------------------
# A green run RECORDS the content of the badge sources and this script, so
# scripts\guard-due.ps1 can answer "has anything run this harness against the
# code as it now stands?". This is the only script that can enter read-only
# mode at all - it drives the real chord on a real GUI - so it is the only
# thing that can prove either half of the mode: the badge a human sees and the
# `readonly` field `+list --json` reports. A red run leaves the stamp alone on
# purpose, and a -NegativeControl run never stamps.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard readonly-badge -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
