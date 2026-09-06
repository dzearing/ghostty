# T446 acceptance: a pending multi-key sequence and an active key table are
# VISIBLE on Windows.
#
# Ghoztty lets a binding be a sequence (press one combination, then a second
# key finishes it) and lets a binding drop you into a named "key table" where
# the keyboard temporarily means something else. Until this task the win32
# `.key_sequence` and `.key_table` apprt actions were acknowledged no-ops, so
# a pane waiting for the second half of a chord looked EXACTLY like a pane that
# had ignored the first half, and a table entered by accident silently
# reinterpreted every subsequent key with nothing on screen to say so.
#
# The mark is the key-state pill (class GhozttyKeyState, a WS_EX_LAYERED popup
# owned by the pane's surface HWND - `KeyStateIndicator.zig`).
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never steals
# the user's foreground - asserted here, not assumed.
#
# ORACLES. All structural, none pixel-based, for the reason readonly-badge.ps1
# documents: the pill paints through UpdateLayeredWindow and never services
# WM_PAINT, so PrintWindow has nothing to render.
#
#   - EXISTENCE + VISIBILITY of the pill, per pane, per state, and the
#     TRANSITIONS between them: it appears on the first key of a sequence, goes
#     away when the sequence completes AND when it is abandoned, appears on a
#     table activation and goes away on the matching deactivation.
#   - WHICH PANE it marks, by rect containment against each pane's own rect.
#   - THE ANCHOR, computed rather than eyeballed. The pill's window is the card
#     plus a UNIFORM shadow allowance, so the gap from the pane's bottom edge is
#     exactly `round(INSET*s) - (round(SHADOW_BLUR*s) + round(SHADOW_DY*s))` =
#     8s - (4s + 2s) in DIP, and the card is horizontally centered. Recomputed
#     from the window's real DPI, which is what makes it a regression test for
#     the geometry rather than a restatement of it.
#   - CONTENT, by WIDTH DELTAS rather than by reading pixels: a second nested
#     table adds a chevron and a name, and a pending key on top of a table adds
#     a divider and a key cap. Both must make the pill strictly wider. That is
#     what distinguishes "the pill appeared" from "the pill says what happened".
#
# Everything below the pixel line - the card's fill and opacity, the drop
# shade, the key-cap chips, the divider, the animated dots and both WCAG floors
# - is asserted in `key_state_pill.zig`'s unit tests, swept over the whole
# background ramp at 1.0/1.25/1.5/2.0, and the stack's push/pop/clear semantics
# in `key_state.zig`'s.
#
# A positive control (ctrl+k clear_screen, the T55/T74 pattern) runs first, so
# a broken injection aborts with a diagnosis instead of reading as a T446
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
$env:GHOZTTY_PIPE_SUFFIX = "-kstest$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-key-state-stderr.log'

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
# which disagrees at exactly .5 - i.e. at 1.25 scaling, which is the scale most
# of these defects first show up at.
function Px([double]$dip, [double]$scale) {
    return [int][math]::Round($dip * $scale, [System.MidpointRounding]::AwayFromZero)
}

function Get-Pills([int]$procId) {
    return @(Get-TestWindows -ProcessId $procId -Class 'GhozttyKeyState')
}

function Get-VisiblePills([int]$procId) {
    return @(Get-Pills $procId | Where-Object Visible)
}

# Poll until the visible-pill count settles on $want.
#
# The `@()` is load-bearing: a function's array return UNROLLS in PS 5.1, so a
# one-element result arrives as a bare pscustomobject whose `.Count` is $null -
# which never equals 1 and turns every wait into a silent timeout that still
# passes at the call site.
function Wait-PillCount([int]$procId, [int]$want) {
    for ($t = 0; $t -lt 30; $t++) {
        $found = @(Get-VisiblePills $procId)
        if ($found.Count -eq $want) { return $found }
        Start-Sleep -Milliseconds 100
    }
    Write-Host "DEBUG wait timeout: wanted $want visible pill(s)"
    Get-Pills $procId | ForEach-Object {
        Write-Host "DEBUG raw pill: $($_.Hwnd) vis=$($_.Visible) $($_.Left),$($_.Top),$($_.Right),$($_.Bottom)"
    }
    return (Get-VisiblePills $procId)
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
        Write-Host 'NEGATIVE CONTROL: section C asserts the pill sits at a DELIBERATELY WRONG bottom inset - this run MUST fail'
    }

    Remove-Item $errlog -ErrorAction SilentlyContinue
    # --session-persistence=false is mandatory: a launch writes a
    # session-layout manifest that the NEXT run would restore, so the second
    # run would come up with this run's panes.
    #
    # The bindings are all UNMODIFIED FUNCTION KEYS on purpose. A posted
    # WM_KEYDOWN carries no modifier state (GetKeyState is per-thread and a
    # cross-process post never sets it), so a chord-based sequence would be
    # untestable off the input desktop - while f5>f6 exercises exactly the same
    # core path.
    #
    # NOT f10, and this is a trap worth naming: `Surface.handleKeyEvent`
    # intercepts F10 for the menu system (T190) BEFORE the key reaches
    # `keyCallback`, so an f10 in a binding never dispatches - and the menu it
    # opens then swallows every key after it. A first draft used `f9>f10` and
    # read as "the pill never updates again" for the whole rest of the run.
    $sp = @{
        Exe       = $exe
        Arguments = @(
            '--session-persistence=false',
            '--background=#101014',
            '--keybind=f5>f6=clear_screen',
            '--keybind=f7=activate_key_table:outer',
            '--keybind=outer/f8=deactivate_key_table',
            '--keybind=outer/f7=activate_key_table:inner',
            '--keybind=inner/f8=deactivate_key_table'
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
    # The pill window is the card plus a uniform shadow allowance, so the gap
    # from the pane's bottom edge is the inset MINUS that allowance.
    $wantGap = (Px 8 $scale) - ((Px 4 $scale) + (Px 2 $scale))
    Write-Host "INFO  dpi=$dpi scale=$scale expected pane-bottom gap=$wantGap px"

    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    Assert ($panes.Count -eq 1) "setup: one pane ($($panes.Count))"
    if ($panes.Count -lt 1) { exit 1 }
    $paneA = $panes[0]

    # -----------------------------------------------------------------------
    # Positive control: posted keys reach binding dispatch at all.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Modifiers ctrl -Key K
    if (-not $r) { Write-Host 'ABORT: control chord not sent'; exit 1 }
    Start-Sleep -Milliseconds 400
    if (Test-Path $errlog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T446 verdict'
            exit 1
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), key delivery only'
    }

    # -----------------------------------------------------------------------
    # A. A pane with nothing pending wears nothing.
    # -----------------------------------------------------------------------
    $pills = @(Get-VisiblePills $app.Pid)
    Assert ($pills.Count -eq 0) "A: no pill before anything is pending ($($pills.Count))"

    # -----------------------------------------------------------------------
    # B. The first key of a sequence makes the wait visible.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f5
    Assert $r 'B: f5 (first half of the sequence) delivered'
    $pills = @(Wait-PillCount $app.Pid 1)
    Assert ($pills.Count -eq 1) "B: exactly one visible pill while the sequence waits ($($pills.Count))"
    if ($pills.Count -ne 1) { throw 'no pill to measure' }
    $pill = $pills[0]
    Assert (Inside $pill $paneA) 'B: the pill is inside the pane that is waiting'
    $seqWidth = $pill.Right - $pill.Left

    # -----------------------------------------------------------------------
    # C. The anchor: bottom-centered, at the computed inset.
    # -----------------------------------------------------------------------
    $gapBottom = $paneA.Bottom - $pill.Bottom
    $script:negReached = $true
    $want = if ($NegativeControl) { $wantGap + 5 } else { $wantGap }
    Assert ($gapBottom -eq $want) "C: pill is $want px above the pane's bottom edge (got $gapBottom)"
    $gapLeft = $pill.Left - $paneA.Left
    $gapRight = $paneA.Right - $pill.Right
    Assert ([math]::Abs($gapLeft - $gapRight) -le 1) `
        "C: pill is horizontally centered in the pane (left $gapLeft vs right $gapRight)"
    # It really is a chip, not a band: nowhere near full pane width.
    Assert ($seqWidth -lt [int](($paneA.Right - $paneA.Left) / 2)) `
        'C: the pill is a chip, not a full-width strip'

    # -----------------------------------------------------------------------
    # D. Window style: layered (so it composites over the pane's OpenGL
    #    content), never activating, and NOT WS_EX_TRANSPARENT.
    #
    #    That last one inverted with T576. Click-through is still the rule -
    #    the pill sits where a selection drag ends - but the CARD now answers
    #    a hover with the key-table explainer, and an ex-style that says
    #    "click through this window" is all or nothing: it would have made the
    #    card unhoverable too. The rule moved into WM_NCHITTEST, which decides
    #    it per point, and section G2 asserts it there. Keeping this assertion
    #    inverted rather than deleting it is deliberate: re-adding the style
    #    would silently take the explainer away again.
    # -----------------------------------------------------------------------
    $ex = Get-TestWindowStyle -Window ([IntPtr]$pill.Hwnd) -ExStyle
    Assert (($ex -band 0x80000) -ne 0) 'D: pill is WS_EX_LAYERED'
    Assert (($ex -band 0x8000000) -ne 0) 'D: pill is WS_EX_NOACTIVATE'
    Assert (($ex -band 0x20) -eq 0) `
        'D: pill is NOT WS_EX_TRANSPARENT - click-through is per-point now (T576)'

    # -----------------------------------------------------------------------
    # E. Completing the sequence clears the pill - and runs the action.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f6
    Assert $r 'E: f6 (second half of the sequence) delivered'
    $pills = @(Wait-PillCount $app.Pid 0)
    Assert ($pills.Count -eq 0) "E: the pill cleared when the sequence completed ($($pills.Count))"

    # -----------------------------------------------------------------------
    # F. ABANDONING a sequence clears it too. This is the half a naive
    #    implementation gets wrong: the core reports `.end` for both outcomes,
    #    and a pill that only cleared on success would strand the user looking
    #    at a chord they are no longer in.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f5
    Assert $r 'F: f5 delivered again'
    $pills = @(Wait-PillCount $app.Pid 1)
    Assert ($pills.Count -eq 1) "F: pill is back ($($pills.Count))"
    # f4 is bound to nothing, which is how a sequence is escaped.
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f4
    Assert $r 'F: f4 (not part of the sequence) delivered'
    $pills = @(Wait-PillCount $app.Pid 0)
    Assert ($pills.Count -eq 0) "F: the pill cleared when the sequence was abandoned ($($pills.Count))"

    # -----------------------------------------------------------------------
    # G. A key table is named on screen for as long as it is active.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f7
    Assert $r 'G: f7 (activate_key_table:outer) delivered'
    $pills = @(Wait-PillCount $app.Pid 1)
    Assert ($pills.Count -eq 1) "G: the active key table shows a pill ($($pills.Count))"
    if ($pills.Count -ne 1) { throw 'no key-table pill to measure' }
    $oneTable = $pills[0].Right - $pills[0].Left
    Assert (Inside $pills[0] $paneA) 'G: the key-table pill is inside its pane'
    Assert (($paneA.Bottom - $pills[0].Bottom) -eq $wantGap) `
        'G: the key-table pill uses the same anchor as the sequence pill'

    # -----------------------------------------------------------------------
    # G2 (T576). The card EXPLAINS itself, and only the card takes the
    #     pointer.
    #
    #     Two halves, both asserted against the window's own routing answer
    #     (WM_NCHITTEST is the question Windows itself asks before it delivers
    #     a click, so this is the mechanism rather than a proxy for it):
    #
    #       - the card hit-tests as ours, which is what lets the pointer rest
    #         on it long enough for the explainer tooltip to show, and
    #       - everything else the pill's window covers - the shadow allowance
    #         on all four sides - answers HTTRANSPARENT and falls through to
    #         the terminal underneath. That is the regression the pill's
    #         click-through rule exists to prevent, and it is now decided per
    #         point instead of by WS_EX_TRANSPARENT, so it needs a test.
    #
    #     The boundary is asserted at the exact pixel on each edge, computed
    #     from the window's real DPI, not eyeballed inside a margin.
    # -----------------------------------------------------------------------
    $pad = (Px 4 $scale) + (Px 2 $scale)
    $pillW = $pills[0]
    $cx = [int](($pillW.Left + $pillW.Right) / 2)
    $cy = [int](($pillW.Top + $pillW.Bottom) / 2)
    $hp = [IntPtr]$pillW.Hwnd

    function Route([int]$x, [int]$y) {
        return (Get-TestMouseRoute -Window $top -Target $hp -X $x -Y $y).Code
    }

    Assert ((Route $cx $cy) -eq 1) 'G2: the card itself takes the pointer (HTCLIENT)'
    Assert ((Route ($pillW.Left) ($pillW.Top)) -eq -1) `
        'G2: the window corner falls through to the terminal (HTTRANSPARENT)'
    Assert ((Route $cx ($pillW.Bottom - 1)) -eq -1) `
        'G2: the shadow band below the card falls through'
    Assert ((Route $cx ($pillW.Top + $pad - 1)) -eq -1) `
        'G2: one pixel above the card is still the terminal'
    Assert ((Route $cx ($pillW.Top + $pad)) -eq 1) `
        'G2: the card top edge is the first row that is ours'
    Assert ((Route ($pillW.Left + $pad - 1) $cy) -eq -1) `
        'G2: one pixel left of the card is still the terminal'
    Assert ((Route ($pillW.Left + $pad) $cy) -eq 1) `
        'G2: the card left edge is the first column that is ours'
    Assert ((Route ($pillW.Right - $pad) $cy) -eq -1) `
        'G2: the card right edge is exclusive - past it is the terminal'

    # The explainer itself. The tooltip is a native comctl32 control in
    # SUBCLASS mode, so the SHOW is the system's decision on a real hover -
    # which the background test desktop cannot hold (T233, the tab tooltip's
    # reasoning). What IS assertable, and is the whole of what this code
    # owns: the control exists and the tool is armed over the card with the
    # heading the user reads.
    if (Test-Path $errlog) {
        $armed = @(Select-String -Path $errlog -Pattern 'key state explainer armed' |
            Select-Object -Last 1)
        Assert ($armed.Count -eq 1) 'G2: the explainer is armed once the pill shows'
        if ($armed.Count -eq 1) {
            Write-Host "INFO  $($armed[0].Line.Trim())"
            Assert ($armed[0].Line -match 'title="Key Table"') `
                'G2: it is armed with the heading Mac shows'
            Assert ($armed[0].Line -match "rect=\d+,\d+,\d+,\d+") `
                'G2: it is armed over a real rect'
        }
    } else {
        Write-Host 'OK    G2 degraded: no debug log (release build), routing asserted only'
    }
    # -AllowHidden: a tooltip control is a hidden popup until something asks
    # for it, which is the point - it exists, armed, waiting.
    $tips = @(Get-TestWindows -ProcessId $app.Pid -Class 'tooltips_class32' -AllowHidden)
    Assert ($tips.Count -ge 1) `
        "G2: the tooltip control exists, so a hover has something to show ($($tips.Count))"

    # And it REACHES the screen. A hover cannot be held on the background test
    # desktop (T233: no pointer lives there), but a CLICK on the card shows the
    # same bubble the hover delay does - which is also Mac's gesture for the
    # same popover - so the click path is the one that can be asserted here.
    # The hover path is the same `tipShow`, one timer earlier.
    $r = Send-TestMouse -Window $top -Target $hp -X $cx -Y $cy -Action click
    Assert $r 'G2: click on the card delivered'
    $shown = @()
    for ($t = 0; $t -lt 30; $t++) {
        $shown = @(Get-TestWindows -ProcessId $app.Pid -Class 'tooltips_class32' -AllowHidden |
            Where-Object Visible)
        if ($shown.Count -ge 1) { break }
        Start-Sleep -Milliseconds 100
    }
    Assert ($shown.Count -ge 1) `
        "G2: the explainer is on screen after the card is clicked ($($shown.Count))"
    if ($shown.Count -ge 1) {
        $b = $shown[0]
        Write-Host "INFO  explainer rect $($b.Left),$($b.Top),$($b.Right),$($b.Bottom)"
        # ABOVE the card, not over it: the pill hugs the pane's bottom edge, so
        # a bubble placed where the control would put it by default covers the
        # thing it is explaining (or falls off the pane).
        Assert ($b.Bottom -le ($pillW.Top + $pad)) `
            'G2: the explainer sits above the card, not over it'
        # Centered on the card, within a pixel of rounding.
        $bc = [int](($b.Left + $b.Right) / 2)
        Assert ([math]::Abs($bc - $cx) -le 2) `
            "G2: the explainer is centered on the card (bubble $bc vs card $cx)"
        Assert (($b.Right - $b.Left) -gt ($pillW.Right - $pillW.Left)) `
            'G2: it is a paragraph, wider than the pill it explains'
    }
    if (Test-Path $errlog) {
        Assert ((Select-String -Path $errlog -Pattern 'key state explainer shown' -Quiet) -eq $true) `
            'G2: the app logged the explainer show'
    }

    # Leaving the key table takes the explainer with it: a bubble that outlived
    # the card would be a stray box floating over the terminal.
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f8
    Assert $r 'G2: f8 (deactivate) delivered'
    $gone = @(Wait-PillCount $app.Pid 0)
    Assert ($gone.Count -eq 0) 'G2: the pill went away with the table'
    $still = @(Get-TestWindows -ProcessId $app.Pid -Class 'tooltips_class32' -AllowHidden |
        Where-Object Visible)
    Assert ($still.Count -eq 0) `
        "G2: the explainer went away with the pill ($($still.Count) left on screen)"

    # Back into the table, for the sections below - which expect exactly the
    # state section G left behind.
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f7
    Assert $r 'G2: f7 re-entered the key table'
    $pills = @(Wait-PillCount $app.Pid 1)
    Assert ($pills.Count -eq 1) "G2: the pill is back ($($pills.Count))"

    # -----------------------------------------------------------------------
    # H. NESTED tables: the stack is a stack. A second table must make the
    #    pill wider (a chevron plus a second name), and one deactivation must
    #    leave the OUTER table still named rather than clearing the pill.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f7
    Assert $r 'H: f7 again (activate_key_table:inner) delivered'
    Start-Sleep -Milliseconds 500
    $pills = @(Get-VisiblePills $app.Pid)
    Assert ($pills.Count -eq 1) "H: still exactly one pill for the nested stack ($($pills.Count))"
    if ($pills.Count -eq 1) {
        $twoTables = $pills[0].Right - $pills[0].Left
        Assert ($twoTables -gt $oneTable) `
            "H: the nested table widened the pill ($oneTable -> $twoTables px)"
        Assert (($paneA.Bottom - $pills[0].Bottom) -eq $wantGap) `
            'H: the wider pill is still anchored to the pane bottom'
        Assert ([math]::Abs(($pills[0].Left - $paneA.Left) - ($paneA.Right - $pills[0].Right)) -le 1) `
            'H: the wider pill is still centered'

        # ...and a sequence ON TOP of a table shows both, which is the case a
        # single-slot indicator could not represent at all.
        $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f5
        Assert $r 'H: f5 delivered while two tables are active'
        Start-Sleep -Milliseconds 500
        $both = @(Get-VisiblePills $app.Pid)
        Assert ($both.Count -eq 1) "H: tables and a pending sequence share one pill ($($both.Count))"
        if ($both.Count -eq 1) {
            $bothWidth = $both[0].Right - $both[0].Left
            Assert ($bothWidth -gt $twoTables) `
                "H: the pending key widened the pill again ($twoTables -> $bothWidth px)"
        }
        # Abandon the sequence; the TABLES must survive it.
        $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f4
        Assert $r 'H: f4 delivered to abandon the sequence'
        Start-Sleep -Milliseconds 500
        $after = @(Get-VisiblePills $app.Pid)
        Assert ($after.Count -eq 1) "H: the pill survived the abandoned sequence, because the tables did ($($after.Count))"
        if ($after.Count -eq 1) {
            Assert ((($after[0].Right - $after[0].Left)) -eq $twoTables) `
                'H: it went back to naming exactly the two tables'
        }
    }

    # One pop leaves the outer table active - the whole reason this is a stack.
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f8
    Assert $r 'H: f8 (deactivate_key_table) delivered'
    Start-Sleep -Milliseconds 500
    $pills = @(Get-VisiblePills $app.Pid)
    Assert ($pills.Count -eq 1) "H: one pop did NOT clear the pill ($($pills.Count))"
    if ($pills.Count -eq 1) {
        Assert ((($pills[0].Right - $pills[0].Left)) -eq $oneTable) `
            'H: the pill is back to naming just the outer table'
    }

    # -----------------------------------------------------------------------
    # I. Per-pane, which is the whole point. Split: the new pane has no key
    #    state, so it gets no pill, and the old one keeps its own - re-anchored
    #    and re-centered, since the split moved its edges.
    # -----------------------------------------------------------------------
    & $exe +split --direction=right | Out-Null
    Start-Sleep -Milliseconds 1200
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Sort-Object Left)
    Assert ($panes.Count -eq 2) "I: split produced 2 panes ($($panes.Count))"
    if ($panes.Count -eq 2) {
        $paneA = $panes[0]; $paneB = $panes[1]
        $pills = @(Wait-PillCount $app.Pid 1)
        Assert ($pills.Count -eq 1) "I: still exactly one pill after the split ($($pills.Count))"
        if ($pills.Count -eq 1) {
            $pill = $pills[0]
            Assert (Inside $pill $paneA) 'I: the pill stayed on the pane that is in a key table'
            Assert (-not (Inside $pill $paneB)) 'I: the pill is NOT on the new pane'
            Assert (($paneA.Bottom - $pill.Bottom) -eq $wantGap) `
                "I: pill re-anchored to the pane's bottom edge (got $($paneA.Bottom - $pill.Bottom))"
            Assert ([math]::Abs(($pill.Left - $paneA.Left) - ($paneA.Right - $pill.Right)) -le 1) `
                're-centered in the narrower pane'
        }

        # -------------------------------------------------------------------
        # J. Both panes in a table -> two pills, one per pane.
        # -------------------------------------------------------------------
        $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneB.Hwnd) -Key f7
        Assert $r 'J: f7 delivered to pane B'
        $pills = @(Wait-PillCount $app.Pid 2)
        Assert ($pills.Count -eq 2) "J: two visible pills, one per pane in a table ($($pills.Count))"
        if ($pills.Count -eq 2) {
            $onA = @($pills | Where-Object { Inside $_ $paneA })
            $onB = @($pills | Where-Object { Inside $_ $paneB })
            Assert ($onA.Count -eq 1 -and $onB.Count -eq 1) 'J: one pill on each pane'
        }

        # -------------------------------------------------------------------
        # K. Leaving the table on one pane clears only that pane's pill.
        # -------------------------------------------------------------------
        $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneB.Hwnd) -Key f8
        Assert $r 'K: f8 delivered to pane B'
        $pills = @(Wait-PillCount $app.Pid 1)
        Assert ($pills.Count -eq 1) "K: pane B's pill cleared ($($pills.Count) left)"
        if ($pills.Count -eq 1) {
            Assert (Inside $pills[0] $paneA) "K: the OTHER pane's pill is untouched"
        }
    }

    # -----------------------------------------------------------------------
    # L. Leaving the last table clears the mark entirely.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$paneA.Hwnd) -Key f8
    Assert $r 'L: f8 delivered to pane A'
    $pills = @(Wait-PillCount $app.Pid 0)
    Assert ($pills.Count -eq 0) "L: no visible pill once every table is left ($($pills.Count))"

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

# --- stamp (T783, row added by T576) --------------------------------------
# A green run RECORDS the content of the pill's sources and this script, so
# scripts\guard-due.ps1 can answer "has anything run this harness against the
# code as it now stands?". This is the only script that drives a real key table
# on a real GUI, so it is the only thing that can prove any of it: the pill's
# anchor, what it says, which pane it marks, that only its card takes the
# pointer, and that the explainer reaches the screen and leaves with the card.
# A red run leaves the stamp alone on purpose, and a -NegativeControl run never
# stamps.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard key-state-pill -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
