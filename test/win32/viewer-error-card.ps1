# T381 acceptance: the viewer pane's ERROR CARD, on the box, in pixels.
#
# WHAT THIS COVERS AND WHY NOTHING ELSE DID. T373 shipped the native card a
# viewer paints instead of web content when there is no WebView2 runtime, and
# `src\apprt\win32\viewer_error_card.zig` asserts every NUMBER in it at 1.0,
# 1.25, 1.5 and 2.0. Those are the geometry's own arithmetic. What no test on
# this box could reach was the PAINT: the runtime is installed here, so every
# live viewer takes the success path and the card had never been on a screen -
# a whole surface whose only evidence was a layout function agreeing with
# itself.
#
# THE DRILL. `GHOZTTY_WEBVIEW2_BROWSER_DIR` overrides the runtime probe
# outright (T372) - including the "does it exist" check - so pointing it at a
# directory that is not there makes a box WITH the runtime take the
# runtime-absent branch faithfully. It is inherited through CreateProcessW, so
# it is set on THIS process before the app is launched and reaches the app and
# nothing else.
#
# WHY ITS OWN SCRIPT rather than a section in viewer-panes.ps1: that override
# is process-wide and permanent for the instance that inherits it, and every
# one of viewer-panes.ps1's eleven sections needs a WORKING WebView2. Bolting a
# runtime-absent instance onto the end of that run would either break its
# sections or hide behind a second endpoint nobody could see - and the card has
# to be measured on TWO backgrounds anyway, which is two more GUI launches. The
# guard-due row is `viewer-error-card`.
#
# THE CAPTURE. `GhozttyViewer` answers WM_PRINTCLIENT (the printclient-audit
# contract), so `Get-TestWindowPixels -Sync` photographs the pane's own GDI
# painting synchronously - no DWM composite, no foreground, no cursor. That is
# what lets this run on the background test desktop where CopyFromScreen and
# PW_RENDERFULLCONTENT are dead.
#
# WHAT IS ASSERTED, per background:
#
#   * the pane background is the CONFIGURED background, exactly - the proof
#     that these are the viewer's own pixels and not a blank bitmap;
#   * a card is painted: its fill differs from the pane background;
#   * its painted extent matches `viewer_error_card.layout` at this box's
#     scale - centered horizontally and vertically, and clearing the pane edge
#     by a full scaled margin;
#   * the message line clears 4.5:1 against the MEASURED card fill and the
#     hint line clears it too - they are text, and the design system's text
#     floor does not care that the news is bad;
#   * the rim clears 3:1 against the same fill - the chrome floor.
#
# Both a DARK and a LIGHT `background` are run, because the card derives its
# fill from the PANE background rather than from the OS theme: a light terminal
# is a real configuration and it is the one where a wash has the least room.
#
# THE CONTROL is section C: the same launch WITHOUT the override. WebView2 comes
# up, the page renders, and the card's two vertical edges are simply not there.
# Without it every "the card is here" assertion in A and B would be scored by a
# script that cannot tell a card from any other non-background pixel, and the
# drill itself would be unproven - a green run with the override doing nothing
# looks identical to a green run with it working.
#
#   powershell -NoProfile -File test\win32\viewer-error-card.ps1
#
# -NegativeControl raises the two contrast floors past what any color pair can
# reach and MUST fail with exactly SIX failures - the message, the hint and the
# rim on each of the two backgrounds. Anything else means the probe is measuring
# something other than the card's legibility.
param([string]$ExePath, [switch]$Interactive, [switch]$NegativeControl)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vec$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
. (Join-Path $PSScriptRoot 'lib\ColorMath.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
# Arms the run (T1039): the dot-source itself, so a body that unwinds cannot
# reach `Complete-TestBody` and cannot be scored green - or stamp its guard.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# T1127: everything running out of this build's directory is reaped when this
# PowerShell exits, including a detached --pty-host holder no PID-based
# teardown at the bottom could reach.
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The directory that is not there. Under %TEMP% rather than a made-up drive so
# the path is well formed on any box, and with the PID in it so two runs cannot
# race over one name.
$noRuntime = Join-Path $env:TEMP "ghoztty-no-webview2-$PID"
Remove-Item -Recurse -Force $noRuntime -ErrorAction SilentlyContinue

function Invoke-Verb([string[]]$VerbArgs) {
    # A PIPE, never a `>` redirect (T245), and each object stringified before
    # Out-String (T526): a consoleless host formats an ErrorRecord as a blank
    # line while its ToString() keeps the text.
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}

function Wait-Win([string]$target) {
    for ($t = 0; $t -lt 25; $t++) {
        $d = Get-Data
        if ($d) { foreach ($w in $d.windows) { if ($w.target -eq $target) { return $w } } }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

# `viewer_error_card.layout`, in the scaled pixels the paint uses. A second
# implementation of the module's arithmetic on purpose: that is the only way to
# connect the numbers the unit tests prove to the pixels this script photographs
# (the ChromeGeometry.ps1 rule). `Get-TestChromeDip` rounds half away from zero,
# matching the Zig's `@round` - [math]::Round does NOT (banker's rounding), and
# the two disagree at 112.5%.
function Get-CardLayout([int]$W, [int]$H, [double]$Scale) {
    $px = { param([double]$dip) Get-TestChromeDip -Dip $dip -Scale $Scale }
    $margin = & $px 12.0
    $padding = & $px 16.0
    $gap = & $px 8.0
    $msgH = & $px 20.0
    $hintH = & $px 16.0
    $maxW = & $px 420.0
    $minW = & $px 160.0

    $availW = $W - 2 * $margin
    $availH = $H - 2 * $margin
    $cardH = 2 * $padding + $msgH + $gap + $hintH
    if ($availW -lt $minW) { return $null }
    if ($availH -lt $cardH) { return $null }
    $cardW = [Math]::Min($availW, $maxW)

    $left = [Math]::Floor(($W - $cardW) / 2.0)
    $top = [Math]::Floor(($H - $cardH) / 2.0)
    return [pscustomobject]@{
        Margin = $margin; Padding = $padding; Gap = $gap
        Left = [int]$left; Top = [int]$top
        Right = [int]$left + $cardW; Bottom = [int]$top + $cardH
        Width = $cardW; Height = $cardH
        MessageTop = [int]$top + $padding
        MessageBottom = [int]$top + $padding + $msgH
        HintTop = [int]$top + $padding + $msgH + $gap
        HintBottom = [int]$top + $padding + $msgH + $gap + $hintH
    }
}

# The card's PAINTED horizontal extent on the row through its vertical middle:
# the first and last x that is not the pane background. That row falls in the
# gap between the two text lines, so nothing but the card's own fill and its
# rim can be on it. Returns $null when the row is entirely background - which
# is what section C's control asserts.
function Get-PaintedRun($Shot, [int]$Y, [int[]]$Bg) {
    $first = -1; $last = -1
    for ($x = 0; $x -lt $Shot.Width; $x++) {
        $c = Get-TestPixel -Shot $Shot -X ($Shot.Left + $x) -Y $Y
        if ($null -eq $c) { continue }
        if ($c.R -eq $Bg[0] -and $c.G -eq $Bg[1] -and $c.B -eq $Bg[2]) { continue }
        if ($first -lt 0) { $first = $x }
        $last = $x
    }
    if ($first -lt 0) { return $null }
    return [pscustomobject]@{ First = $first; Last = $last }
}

# The same scan down a column, bounded to the card's neighbourhood so the nav
# bar at the top of the pane cannot join in.
function Get-PaintedColumn($Shot, [int]$X, [int]$Y0, [int]$Y1, [int[]]$Bg) {
    $first = -1; $last = -1
    for ($y = [Math]::Max(0, $Y0); $y -lt [Math]::Min($Shot.Height, $Y1); $y++) {
        $c = Get-TestPixel -Shot $Shot -X $X -Y ($Shot.Top + $y)
        if ($null -eq $c) { continue }
        if ($c.R -eq $Bg[0] -and $c.G -eq $Bg[1] -and $c.B -eq $Bg[2]) { continue }
        if ($first -lt 0) { $first = $y }
        $last = $y
    }
    if ($first -lt 0) { return $null }
    return [pscustomobject]@{ First = $first; Last = $last }
}

# How many of the card's two vertical edges show a COLOR TRANSITION on a row.
#
# The card-present oracle that survives a working WebView2. `Get-PaintedRun`
# above compares against the pane background, which is the right question only
# while the host's own fill is what the capture shows; with a runtime found,
# `PrintWindow` brings the Chromium child's page along and about:blank paints
# the whole row white, so "not the background" is true of every pixel and says
# nothing. A rounded rect, by contrast, IS a pair of transitions at two known
# x's - rim against what is outside, rim against the fill inside - and a page
# of uniform white has neither.
function Get-CardEdgeTransitions($Shot, $Lay, [int]$Y) {
    $n = 0
    # Each pair built with the arithmetic in its OWN parentheses: in PowerShell
    # the comma binds tighter than `-`, so `@($Lay.Left - 1, $Lay.Left)` is
    # `$Lay.Left - @(1, $Lay.Left)` and throws op_Subtraction (found on this
    # script's first run, where the throw unwound the whole section).
    $pairs = @(
        , @(($Lay.Left - 1), $Lay.Left)
        , @(($Lay.Right - 1), $Lay.Right)
    )
    foreach ($pair in $pairs) {
        $a = Get-TestPixel -Shot $Shot -X ($Shot.Left + $pair[0]) -Y $Y
        $b = Get-TestPixel -Shot $Shot -X ($Shot.Left + $pair[1]) -Y $Y
        if ($null -eq $a -or $null -eq $b) { continue }
        if ($a.R -ne $b.R -or $a.G -ne $b.G -or $a.B -ne $b.B) { $n++ }
    }
    return $n
}

# The color of the text in a line rect: the extreme AWAY from the fill. GDI
# antialiases a glyph toward its background, so the stroke centres carry the
# real color and everything else is between it and the fill.
function Get-LineColor($Rect, [int[]]$Fill) {
    if ($null -eq $Rect) { return $null }
    if (Test-IsLight $Fill[0] $Fill[1] $Fill[2]) { return , $Rect.Darkest }
    return , $Rect.Lightest
}

# Launch one GUI with a background, open a viewer pane, and hand back the
# viewer host window plus the scale it is painting at.
function Start-Case([string]$Hex, [string]$Tag) {
    $errlog = Join-Path $env:TEMP "ghoztty-viewer-error-card-$Tag.log"
    Remove-Item $errlog -ErrorAction SilentlyContinue
    # --config-default-files=false so the user's own config cannot pick the
    # background out from under the case.
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--session-persistence=false', '--config-default-files=false', "--background=$Hex")
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 15000
    if ($top -eq [IntPtr]::Zero) { return $null }

    $r = Invoke-Verb @('+new-window', '--target=vec', '--view=about:blank')
    if ($r.Code -ne 0) { Write-Host "  ($Tag) +new-window --view exited $($r.Code): $($r.Out)" }
    if ($null -eq (Wait-Win 'vec')) { return $null }

    # The viewer host, under whichever top-level window ended up carrying it.
    $host_ = [IntPtr]::Zero
    for ($t = 0; $t -lt 40 -and $host_ -eq [IntPtr]::Zero; $t++) {
        foreach ($w in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
            foreach ($h in @(Get-TestChildWindows -Window ([IntPtr][int64]$w.Hwnd) -Class 'GhozttyViewer')) {
                if ($h.Width -gt 0 -and $h.Height -gt 0) { $host_ = [IntPtr][int64]$h.Hwnd; break }
            }
            if ($host_ -ne [IntPtr]::Zero) { break }
        }
        if ($host_ -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
    }
    if ($host_ -eq [IntPtr]::Zero) { return $null }
    $dpi = [int](Get-TestWindowDpi -Window $host_)
    return [pscustomobject]@{ App = $app; Host = $host_; Scale = $dpi / 96.0 }
}

function Stop-Case { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

# The two floors, from the design system. Inverted by -NegativeControl, which
# must therefore FAIL: a probe that cannot score red on a legible card is not
# measuring legibility.
$TEXT_FLOOR = 4.5
$CHROME_FLOOR = 3.0

Stop-Case
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # =====================================================================
    # A / B. The card, on a dark and on a light pane background
    # =====================================================================
    $env:GHOZTTY_WEBVIEW2_BROWSER_DIR = $noRuntime
    foreach ($case in @(
            @{ Sec = 'A'; Name = 'dark'; Bg = @(0x1E, 0x1E, 0x1E) },
            @{ Sec = 'B'; Name = 'light'; Bg = @(0xF3, 0xF3, 0xF3) })) {

        $sec = $case.Sec
        $bg = $case.Bg
        $hex = Format-Rgb $bg
        $c = Start-Case $hex "$sec-$($case.Name)"
        Assert ($null -ne $c) "$sec/$($case.Name) a viewer pane came up on background $hex"
        if ($null -eq $c) { Stop-Case; continue }

        try {
            Assert (-not (Test-TestDesktopLeak -ProcessId $c.App.Pid)) `
                "$sec/$($case.Name) the GUI is NOT on the interactive desktop"

            # Poll for the card: the probe fails asynchronously (the WebView2
            # environment request is answered on a callback), so the first
            # paint after the pane appears can still be the plain background.
            $shot = $null
            $run = $null
            $lay = $null
            for ($t = 0; $t -lt 40; $t++) {
                if ($shot) { Close-TestWindowPixels $shot }
                $shot = Get-TestWindowPixels -Window $c.Host -Sync -AllowUniform
                $lay = Get-CardLayout $shot.Width $shot.Height $c.Scale
                if ($null -eq $lay) { break }
                $midY = $shot.Top + [int](($lay.Top + $lay.Bottom) / 2)
                $run = Get-PaintedRun $shot $midY $bg
                if ($run) { break }
                Start-Sleep -Milliseconds 250
            }

            Assert ($null -ne $lay) `
                "$sec/$($case.Name) the pane is big enough for a card ($($shot.Width)x$($shot.Height) at scale $($c.Scale))"
            if ($null -eq $lay) { continue }

            # The pane background is EXACTLY what was configured. Sampled in
            # the clearance band down the pane's left edge, which the card may
            # never enter. This is the assertion that says these are the
            # viewer's own pixels: a bitmap of anything else fails it.
            $midY = $shot.Top + [int](($lay.Top + $lay.Bottom) / 2)
            $edge = Measure-Box $shot ($shot.Left + 2) ($midY - 8) ($shot.Left + $lay.Margin - 2) ($midY + 8)
            Assert ($null -ne $edge -and $edge.Mode[0] -eq $bg[0] -and $edge.Mode[1] -eq $bg[1] -and $edge.Mode[2] -eq $bg[2]) `
                ("$sec/$($case.Name) the pane paints the configured background $hex in its clearance band " +
                 "(measured $(if ($edge) { Format-Rgb $edge.Mode } else { 'nothing' }))")

            Assert ($null -ne $run) "$sec/$($case.Name) a card is painted (something other than the background on the card's middle row)"
            if ($null -eq $run) { continue }

            # The same question section C's control asks, asked here in the
            # positive: both of the card's vertical edges are a color
            # transition. Scored in both directions so the control's oracle is
            # known to be able to say yes.
            Assert ((Get-CardEdgeTransitions $shot $lay $midY) -eq 2) `
                "$sec/$($case.Name) both of the card's vertical edges are a color transition"

            # GEOMETRY. The painted run's ends ARE the card's rim, so this is
            # the card's width, its centering and its clearance from the pane
            # edge in one measurement, against the module's own arithmetic.
            Assert ($run.First -eq $lay.Left) `
                "$sec/$($case.Name) the card's left edge is at $($lay.Left) (painted $($run.First))"
            Assert ($run.Last -eq $lay.Right - 1) `
                "$sec/$($case.Name) the card's right edge is at $($lay.Right - 1) (painted $($run.Last))"
            Assert ($run.First -ge $lay.Margin -and ($shot.Width - 1 - $run.Last) -ge $lay.Margin) `
                "$sec/$($case.Name) the card clears both pane edges by a full $($lay.Margin)px margin"
            Assert ([Math]::Abs($run.First - ($shot.Width - 1 - $run.Last)) -le 1) `
                "$sec/$($case.Name) the card is horizontally centered ($($run.First) left, $($shot.Width - 1 - $run.Last) right)"

            $col = Get-PaintedColumn $shot ($shot.Left + [int](($lay.Left + $lay.Right) / 2)) `
                ($lay.Top - $lay.Margin) ($lay.Bottom + $lay.Margin) $bg
            Assert ($null -ne $col -and $col.First -eq $lay.Top -and $col.Last -eq $lay.Bottom - 1) `
                ("$sec/$($case.Name) the card's top/bottom edges are at $($lay.Top)/$($lay.Bottom - 1) " +
                 "(painted $(if ($col) { "$($col.First)/$($col.Last)" } else { 'nothing' }))")

            # COLOR. The fill is MEASURED, never predicted: the card derives it
            # from the pane background through a wash and a contrast clamp, and
            # a second implementation of the clamp here would be a second copy
            # of the thing under test.
            $inner = Measure-Box $shot ($shot.Left + $lay.Left + 2) ($shot.Top + $lay.Top + 2) `
                ($shot.Left + $lay.Right - 2) ($shot.Top + $lay.Bottom - 2)
            Assert ($null -ne $inner) "$sec/$($case.Name) the card interior captured"
            if ($null -eq $inner) { continue }
            $fill = $inner.Mode
            Assert (-not ($fill[0] -eq $bg[0] -and $fill[1] -eq $bg[1] -and $fill[2] -eq $bg[2])) `
                "$sec/$($case.Name) the card's fill $(Format-Rgb $fill) is distinct from the pane background $hex"

            $msg = Measure-Box $shot ($shot.Left + $lay.Left + $lay.Padding) ($shot.Top + $lay.MessageTop) `
                ($shot.Left + $lay.Right - $lay.Padding) ($shot.Top + $lay.MessageBottom)
            $hint = Measure-Box $shot ($shot.Left + $lay.Left + $lay.Padding) ($shot.Top + $lay.HintTop) `
                ($shot.Left + $lay.Right - $lay.Padding) ($shot.Top + $lay.HintBottom)
            $msgColor = Get-LineColor $msg $fill
            $hintColor = Get-LineColor $hint $fill

            Assert ($null -ne $msgColor -and $null -ne $hintColor) "$sec/$($case.Name) both text lines captured"
            if ($null -eq $msgColor -or $null -eq $hintColor) { continue }

            # Both lines are TEXT and take the text floor. The hint is
            # de-emphasized, which is a reason for it to be quieter and not a
            # reason for it to be unreadable - `textSecondaryOn` exists because
            # a flat gray was 2.8:1 on a light surface (chrome_theme.zig).
            $msgRatio = Get-Contrast $msgColor $fill
            $hintRatio = Get-Contrast $hintColor $fill
            $textWant = if ($NegativeControl) { 25.0 } else { $TEXT_FLOOR }
            Assert ($msgRatio -ge $textWant) `
                ("$sec/$($case.Name) the message line clears $textWant`:1 on the card fill " +
                 "($(Format-Rgb $msgColor) on $(Format-Rgb $fill) = $([Math]::Round($msgRatio, 2)):1)")
            Assert ($hintRatio -ge $textWant) `
                ("$sec/$($case.Name) the hint line clears $textWant`:1 on the card fill " +
                 "($(Format-Rgb $hintColor) on $(Format-Rgb $fill) = $([Math]::Round($hintRatio, 2)):1)")

            # The rim, on the card's middle row: the painted run's own first
            # pixel, which is the rounded rect's stroke.
            $rimPix = Get-TestPixel -Shot $shot -X ($shot.Left + $run.First) -Y $midY
            Assert ($null -ne $rimPix) "$sec/$($case.Name) the rim pixel captured"
            if ($null -eq $rimPix) { continue }
            $rim = @([int]$rimPix.R, [int]$rimPix.G, [int]$rimPix.B)
            $rimRatio = Get-Contrast $rim $fill
            $chromeWant = if ($NegativeControl) { 25.0 } else { $CHROME_FLOOR }
            Assert ($rimRatio -ge $chromeWant) `
                ("$sec/$($case.Name) the rim clears $chromeWant`:1 on the card fill " +
                 "($(Format-Rgb $rim) on $(Format-Rgb $fill) = $([Math]::Round($rimRatio, 2)):1)")
        } finally {
            if ($shot) { Close-TestWindowPixels $shot }
            Stop-Case
        }
    }

    # =====================================================================
    # C. THE CONTROL: without the override there is no card
    # =====================================================================
    #
    # The same launch with the runtime found normally, and the card's two
    # vertical edges are gone. Without this, A and B would be scored by a script
    # that cannot tell a card from any other non-background pixel - and the
    # DRILL would be unproven, because an override that silently did nothing
    # would leave a run that looks exactly like a passing one.
    #
    # Measured as EDGES rather than as "the row is all background" (T381, first
    # run): with a runtime found, the host's own painting is not what comes back
    # for the region a live Chromium child occupies, so every pixel there
    # differs from the pane background and the background test says nothing at
    # all. The transitions are the shape of a card, and what is there instead
    # has none.
    #
    # WHAT THIS CONTROL DOES NOT CLAIM. It cannot see a card painted UNDER a
    # live web view, because that region of the capture is the child's. It does
    # not need to: `ViewerPane.paint` returns before the card whenever the state
    # is not `.failed`, and `fail()` is what sets that state - a pane cannot
    # have both. What the control IS for is the drill: that the override changes
    # the pane's state at all, which the clearance-band pair below measures
    # directly.
    Remove-Item Env:\GHOZTTY_WEBVIEW2_BROWSER_DIR -ErrorAction SilentlyContinue
    $bg = @(0x1E, 0x1E, 0x1E)
    $hex = Format-Rgb $bg
    $c = Start-Case $hex 'C-control'
    Assert ($null -ne $c) "C/control a viewer pane came up with the runtime found normally"
    if ($c) {
        $shot = $null
        try {
            # Give the real WebView2 the same wall-clock A and B gave the
            # failure path, so "no card" is not merely "not yet".
            Start-Sleep -Seconds 5
            $shot = Get-TestWindowPixels -Window $c.Host -Sync -AllowUniform
            $lay = Get-CardLayout $shot.Width $shot.Height $c.Scale
            Assert ($null -ne $lay) "C/control the pane is big enough for a card ($($shot.Width)x$($shot.Height))"
            if ($lay) {
                $midY = $shot.Top + [int](($lay.Top + $lay.Bottom) / 2)
                $edges = Get-CardEdgeTransitions $shot $lay $midY
                $row = Measure-Box $shot $shot.Left $midY ($shot.Left + $shot.Width) ($midY + 1)
                Assert ($edges -eq 0) `
                    ("C/control no card is painted when the runtime is found " +
                     "($edges of the card's 2 edges show a transition; the row is mostly " +
                     "$(if ($row) { Format-Rgb $row.Mode } else { 'nothing' }))")

                # The other half, and the one that makes the first half mean
                # something: the clearance band is NOT the pane background here,
                # because a live Chromium child is over it. A and B assert that
                # same band IS the background, so the two runs are provably in
                # different states rather than merely scoring differently.
                $band = Measure-Box $shot ($shot.Left + 2) ($midY - 8) ($shot.Left + $lay.Margin - 2) ($midY + 8)
                Assert ($null -ne $band -and -not ($band.Mode[0] -eq $bg[0] -and $band.Mode[1] -eq $bg[1] -and $band.Mode[2] -eq $bg[2])) `
                    ("C/control a live web view covers the host's own painting " +
                     "(clearance band is $(if ($band) { Format-Rgb $band.Mode } else { 'nothing' }), not $hex)")
            }
        } finally {
            if ($shot) { Close-TestWindowPixels $shot }
            Stop-Case
        }
    }

    Complete-TestBody
} finally {
    Remove-Item Env:\GHOZTTY_WEBVIEW2_BROWSER_DIR -ErrorAction SilentlyContinue
    Remove-TestDesktop
    Stop-Case
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due, and so does a run that unwound - `guard-due.ps1 update`
# reads GHOZTTY_TEST_BODY out of this process and refuses a `pending` one.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-error-card -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
# -MinPass is the floor this run knows it ought to clear: 17 assertions per
# background, plus the control's 3 and the foreground verdict. A throw that
# unwinds one section leaves far less than that, and a score of 6 out of 38 is
# much closer to ASSERTED NOTHING than to a pass (T271/T1039) - which is exactly
# what the first run of this script printed before the marker was wired in.
Write-TestVerdict -Label 'VIEWER ERROR CARD' -Pass $script:pass -Fail $script:fail -MinPass 30
