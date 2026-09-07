# Machine-chooser session-card KILL HOVER acceptance (T588).
#
#   powershell -NoProfile -File test\win32\chooser-kill-hover.ps1
#
# T318 built the session roster's per-card Kill button and drove its hover from
# the DIALOG's WM_MOUSEMOVE: the cards are painted on the dialog itself, not in
# a child control, so their pointer handling lives in the dialog's window
# procedure. What a move-only handler cannot see is the pointer going from a
# Kill button STRAIGHT OUT of the chooser - no further WM_MOUSEMOVE arrives at
# all, `roster.hover_kill` keeps naming the card it last saw, and the button
# stays lit until the pointer comes back. Same defect class T315 fixed on the
# account link, on a sibling control in the same dialog.
#
# T588 arms a TrackMouseEvent(TME_LEAVE) on the DIALOG and clears the hover in
# its WM_MOUSELEAVE. Unlike T315 the tracking belongs on the dialog rather than
# on a child window: the cards ARE the dialog's own paint, so the parent's leave
# firing when the pointer enters a child (the listbox, the filter, the link) is
# the correct answer - the pointer is genuinely off the card.
#
# What this script asserts, by measuring PAINT in the first card's Kill box. A
# hovered Kill draws a rounded fill behind its "x" (icon_button.fillDelta, 15
# per channel) and brightens the glyph, so hovering strictly adds pixels that
# differ from the card's fill:
#
#   1. baseline - the Kill "x" paints on an unhovered card, with some ink;
#   2. positive control - a hover at the Kill point adds the fill. A
#      leave-on-entry regression (the danger of arming the tracker on the
#      DIALOG rather than on a child) fails HERE rather than passing as a fix;
#   3. the fix - after the pointer has been over the Kill button and then left
#      the dialog, the box is back at its resting paint. On a pre-T588 binary
#      nothing clears `hover_kill` and the fill stays lit;
#   4. it is repeatable - a second enter/leave cycle behaves the same, so the
#      tracker is re-armed per entry rather than being a one-shot;
#   5. the dialog still WORKS as a dialog - the roster still hit-tests, so the
#      Kill button opens its confirmation after all the hover traffic.
#
# WHY TWO DIFFERENT CAPTURES. A POSTED WM_MOUSEMOVE cannot survive to the paint
# it dirties once a leave tracker is armed (T282): the OS posts WM_MOUSELEAVE
# within a frame because there is no real cursor on a background desktop, and
# WM_PAINT is the lowest-priority message in the queue, so the leave is always
# drained first. That is exactly the behaviour under test - so the HOT frame is
# taken with Get-TestHoverCapture, which has the app send the move and capture
# inside one handler on its GUI thread (no message loop in between, so no leave
# can land in the middle), and the LEFT frame is taken the ordinary way after a
# posted move plus a posted WM_MOUSELEAVE. Byte for byte the message Windows
# delivers on leave; the pixels are the app's own repaint either way.
#
# T217/T218: runs on a BACKGROUND Win32 desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Capture is the synchronous
# PrintWindow (T942), which the chooser answers by painting the frame itself.
#
# Only ever touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers, dot-sourced ahead of any isolation setup
# because it drops an inherited $GHOZTTY_IPC_SOCKET - a test never wants the
# caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would answer for somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = "-killhover$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false
# A drive that dies mid-way unwinds to the `finally` and would otherwise reach
# the summary having scored only the setup assertions - i.e. report ALL PASS for
# a run that measured nothing. Nothing but the last line of the drive sets this.
$script:drove = $false

function Assert([bool]$cond, [string]$name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

$WM_MOUSEMOVE = 0x0200
$WM_MOUSELEAVE = 0x02A3

$tmp = Join-Path $env:TEMP "ghoztty-killhover-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$errlog = Join-Path $tmp 'stderr.log'

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

function Wait-LogLine($path, $pattern, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $path) {
            $m = Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue
            if ($m) { return $m[-1].Line }
        }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $null
}

# MAKELPARAM(x, y) for a client-space mouse message.
function Pack-Point([int]$x, [int]$y) {
    return [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF))
}

# Pixels in a screen rect that differ from a reference color by more than a
# small tolerance. Counting pixels rather than sampling one is what makes the
# metric independent of where the fill's rounded corners land, of the theme and
# of the glyph itself - a hover strictly ADDS covered pixels to the box.
function Measure-InkVs($shot, $rect, [int]$rr, [int]$rg, [int]$rb) {
    $x0 = [Math]::Max(0, $rect.Left - $shot.Left)
    $y0 = [Math]::Max(0, $rect.Top - $shot.Top)
    $x1 = [Math]::Min($shot.Width, $rect.Right - $shot.Left)
    $y1 = [Math]::Min($shot.Height, $rect.Bottom - $shot.Top)
    if ($x1 -le $x0 -or $y1 -le $y0) { return -1 }
    $ink = 0
    for ($y = $y0; $y -lt $y1; $y++) {
        for ($x = $x0; $x -lt $x1; $x++) {
            $c = $shot.Bitmap.GetPixel($x, $y)
            $d = [Math]::Abs([int]$c.R - $rr) + [Math]::Abs([int]$c.G - $rg) + [Math]::Abs([int]$c.B - $rb)
            if ($d -gt 24) { $ink++ }
        }
    }
    return $ink
}

# The card's own fill, read from a Kill-box-sized patch of card immediately to
# the LEFT of the Kill box - same card, same row, clear of the button. The
# reference has to come from OUTSIDE the box: a hovered Kill's fill can be the
# majority of its own box, so a mode taken inside it would make the box its own
# reference and score the hovered state as LESS ink, not more.
function Get-CardFill($shot, $box) {
    $w = $box.Right - $box.Left
    $counts = @{}
    $x0 = [Math]::Max(0, ($box.Left - $w - 4) - $shot.Left)
    $x1 = [Math]::Min($shot.Width, ($box.Right - $w - 4) - $shot.Left)
    $y0 = [Math]::Max(0, $box.Top - $shot.Top)
    $y1 = [Math]::Min($shot.Height, $box.Bottom - $shot.Top)
    if ($x1 -le $x0 -or $y1 -le $y0) { return $null }
    for ($y = $y0; $y -lt $y1; $y++) {
        for ($x = $x0; $x -lt $x1; $x++) {
            $c = $shot.Bitmap.GetPixel($x, $y)
            # [int] casts are load-bearing: PowerShell keeps a [byte] left
            # operand's TYPE through -shl, so `$c.R -shl 16` truncates back to
            # a byte and every key collapses to its blue channel.
            $key = ([int]$c.R -shl 16) -bor ([int]$c.G -shl 8) -bor [int]$c.B
            if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
        }
    }
    $bestKey = -1; $bestN = -1
    foreach ($k in $counts.Keys) { if ($counts[$k] -gt $bestN) { $bestN = $counts[$k]; $bestKey = $k } }
    if ($bestKey -lt 0) { return $null }
    return [pscustomobject]@{
        R = ($bestKey -shr 16) -band 0xFF
        G = ($bestKey -shr 8) -band 0xFF
        B = $bestKey -band 0xFF
    }
}

# Ink in the Kill box of a plain (un-hovered-by-the-app) capture.
function Get-KillInk([IntPtr]$chooser, $box) {
    Start-Sleep -Milliseconds 250
    $shot = Get-TestWindowPixels -Window $chooser -Sync
    try {
        $fill = Get-CardFill $shot $box
        if ($null -eq $fill) { return -1 }
        return (Measure-InkVs $shot $box $fill.R $fill.G $fill.B)
    } finally { Close-TestWindowPixels $shot }
}

if (-not (Test-Path $Exe)) { Write-Host "SETUP FAIL: $Exe not found"; exit 1 }

Write-Host 'T588 chooser session-card Kill hover'
Stop-DebugGhoztty
Reset-AgentState
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $app = Start-OnTestDesktop -Exe $Exe `
        -Arguments @('--window-width=100', '--window-height=30', '--session-persistence=true') `
        -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: GhozttyWindow not found'; exit 1 }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: GhozttyTerminal not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the GUI is NOT enumerable on the interactive desktop'

    # A second pane, so the roster has more than one card to lay out.
    & $Exe +split --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 2

    [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
    $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opened the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser to score'; exit 1 }

    $line = Wait-LogLine $errlog 'chooser roster: loaded (\d+) session' 8000
    $loaded = -1
    if ($line -and $line -match 'loaded (\d+) session') { $loaded = [int]$Matches[1] }
    Assert ($loaded -ge 1) "the roster has at least one session card to hover (loaded=$loaded)"
    if ($loaded -lt 1) { Write-Host 'SETUP FAIL: no roster cards'; exit 1 }
    Start-Sleep -Milliseconds 500

    # --- the subject: the first card's Kill box ------------------------------
    # Client-space DIP layout (lib\ChromeGeometry.ps1), offset by the client
    # origin so every rect below is in the SCREEN coordinates the captures and
    # the hover probe both speak.
    $scale = (Get-TestWindowDpi -Window $chooser) / 96.0
    $geo = Get-TestChooserRosterGeometry -Scale $scale
    $client = Get-TestWindowRect -Window $chooser -Client
    $killW = [int][math]::Floor(28 * $scale + 0.5)
    $half = [int][math]::Floor($killW / 2)
    $killSx = $client.Left + $geo.KillX
    $killSy = $client.Top + $geo.KillY
    $box = [pscustomobject]@{
        Left = $killSx - $half; Top = $killSy - $half
        Right = $killSx + $half; Bottom = $killSy + $half
    }
    Assert (($box.Right - $box.Left) -gt 0 -and ($box.Bottom - $box.Top) -gt 0) `
        'the Kill button has a real box to measure'

    # --- (1) baseline --------------------------------------------------------
    $rest = Get-KillInk $chooser $box
    Assert ($rest -gt 0) "the Kill x paints on an unhovered card (ink=$rest)"
    if ($rest -le 0) {
        Write-Host 'SETUP FAIL: no ink in the Kill box - nothing below can discriminate'
        exit 1
    }

    # --- (2) positive control: hovering lights the fill ----------------------
    # The app sends the move and captures inside one handler (T282), so the
    # leave its own tracker arms cannot land before the paint.
    $hotShot = Get-TestHoverCapture -Hwnd $chooser -X $killSx -Y $killSy
    Assert ($null -ne $hotShot) "the hover capture came back ($(Get-LastHoverCaptureError))"
    $hot = -1
    if ($null -ne $hotShot) {
        try {
            Assert ($hotShot.Hit -eq 1) "the Kill point hit-tests as CLIENT, so the roster saw the move (hit=$($hotShot.Hit))"
            Assert ([bool]$hotShot.Changed) 'the hover changed the frame at all'
            $fill = Get-CardFill $hotShot $box
            if ($null -ne $fill) { $hot = Measure-InkVs $hotShot $box $fill.R $fill.G $fill.B }
        } finally { Close-TestHoverCapture $hotShot }
    }
    Assert ($hot -gt $rest) "pointing at Kill lights its fill (rest=$rest, hot=$hot)"

    # --- (3) the fix: leaving the dialog clears it ---------------------------
    # The posted move is the app's ONLY news that the pointer reached the
    # button; the posted leave is byte-for-byte what Windows delivers when it
    # then goes straight out of the window. Pre-T588 the dialog armed no
    # tracker, WM_MOUSELEAVE fell through to DefWindowProcW and the fill stayed.
    [void](Send-TestRawMessage -Window $chooser -Message $WM_MOUSEMOVE -LParam (Pack-Point $geo.KillX $geo.KillY))
    Start-Sleep -Milliseconds 200
    [void](Send-TestRawMessage -Window $chooser -Message $WM_MOUSELEAVE)
    $left = Get-KillInk $chooser $box
    if ($NegativeControl) {
        $script:negReached = $true
        Assert ($left -gt $rest) "NEGATIVE CONTROL: the Kill fill SHOULD have stuck (rest=$rest, after leave=$left)"
    } else {
        Assert ($left -eq $rest) "leaving the dialog clears the Kill fill (rest=$rest, after leave=$left)"
    }

    # --- (4) repeatable ------------------------------------------------------
    $hotShot2 = Get-TestHoverCapture -Hwnd $chooser -X $killSx -Y $killSy
    $hot2 = -1
    if ($null -ne $hotShot2) {
        try {
            $fill2 = Get-CardFill $hotShot2 $box
            if ($null -ne $fill2) { $hot2 = Measure-InkVs $hotShot2 $box $fill2.R $fill2.G $fill2.B }
        } finally { Close-TestHoverCapture $hotShot2 }
    }
    [void](Send-TestRawMessage -Window $chooser -Message $WM_MOUSEMOVE -LParam (Pack-Point $geo.KillX $geo.KillY))
    Start-Sleep -Milliseconds 200
    [void](Send-TestRawMessage -Window $chooser -Message $WM_MOUSELEAVE)
    $left2 = Get-KillInk $chooser $box
    if (-not $NegativeControl) {
        Assert ($hot2 -eq $hot -and $left2 -eq $rest) `
            "a second enter/leave cycle repeats it exactly (hot2=$hot2, left2=$left2)"
    }

    # --- (5) the roster still works ------------------------------------------
    # A leave handler that cleared more than the hover - the roster's rows, its
    # scroll offset, the dialog's own hit testing - would show here: the Kill
    # button must still open its confirmation after all that pointer traffic.
    Send-TestMouse -Window $chooser -X $killSx -Y $killSy -Button left -Action click | Out-Null
    $confirm = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 3000
    Assert ($confirm -ne [IntPtr]::Zero) 'the Kill button still opens its confirmation after the hover drive'
    if ($confirm -ne [IntPtr]::Zero) {
        [void](Send-TestControlKey -Control $confirm -Key Escape)
        Start-Sleep -Milliseconds 400
    }

    [void](Send-TestControlKey -Control $chooser -Key Escape)
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'Escape closed the chooser'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the app survived the whole hover drive'
    $script:drove = $true

} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    Assert ($launched.Count -gt 0) 'the run actually launched apps on the test desktop'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Assert $script:drove 'the hover drive ran to the end (nothing threw out of it)'
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "CHOOSER-KILL-HOVER ACCEPTANCE: ALL PASS ($($script:pass) assertions)"
    exit 0
} else {
    Write-Host "CHOOSER-KILL-HOVER ACCEPTANCE: $($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red
    exit 1
}
