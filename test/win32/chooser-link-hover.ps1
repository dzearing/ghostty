# Machine-chooser account-link hover acceptance (T315).
#
#   powershell -NoProfile -File test\win32\chooser-link-hover.ps1
#
# T311 built the chooser's signed-in "Sign Out" LINK and drove its hover from
# the dialog's WM_SETCURSOR: the message names the window under the pointer, so
# "entered the link" and "moved off it onto something else in the dialog" were
# the same one test. What that could not see is the pointer going from the link
# STRAIGHT OUT of the window - no further WM_SETCURSOR arrives at all, and the
# underline stayed lit until the pointer came back. The link sits a margin in
# from the client's top-right corner, so "up or right and you are out" is the
# easy path, not a corner case.
#
# T315 puts a TrackMouseEvent(TME_LEAVE) subclass on the LINK. On the DIALOG it
# would be wrong: while the pointer is over a child, the parent is not the
# window under the cursor, so the parent's leave fires the moment the pointer
# ENTERS the link - which would clear the hover on entry and "fix" the sticking
# by deleting the feature. That inverted failure is exactly what the positive
# control below exists to catch.
#
# What this script asserts, by measuring PAINT (the underline is an underlined
# FONT, so hovering strictly adds ink to the link's rect):
#
#   1. baseline - the link paints, unhovered and unfocused, with some ink;
#   2. positive control - WM_SETCURSOR naming the link adds ink (the underline
#      appears). A leave-on-entry regression fails here, not silently;
#   3. the fix - WM_MOUSELEAVE at the LINK takes the ink back to baseline. On a
#      pre-T315 binary the link has no subclass, WM_MOUSELEAVE reaches the stock
#      BUTTON proc, `link_hot` is never cleared and the ink stays elevated;
#   4. it is repeatable - a second enter/leave cycle behaves the same, so the
#      subclass is not a one-shot;
#   5. the link still WORKS after being subclassed - it keeps its label, its
#      geometry and its tab stop (a subclass that ate messages would show here).
#
# Why posted messages rather than a real pointer: TrackMouseEvent watches the
# REAL cursor (T233), and SetCursorPos is refused off the input desktop, so no
# automated run on the test desktop can HOLD a hover. Posting WM_SETCURSOR sets
# the state the real message would, without arming the tracker that would
# immediately un-set it; posting WM_MOUSELEAVE at the link is byte-for-byte the
# message Windows delivers when the pointer leaves. Neither shortcut fakes the
# thing being measured, which is the app's own repaint.
#
# T217/T218: runs on a BACKGROUND Win32 desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Capture is PrintWindow
# (PW_RENDERFULLCONTENT), the only path that works there, and the chooser is
# GDI-painted chrome so it captures for real (the OpenGL terminal surface, the
# one thing PrintWindow flattens, is not involved).
#
# The account store is redirected to a temp DPAPI blob (GHOSTTY_ACCOUNT_STORE)
# so the box's real account is never read or written. Only ever touches ghoztty
# processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Drawing
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would answer for somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-linkhover'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false
# A drive that dies mid-way (a mistyped helper call, a throw out of a capture)
# unwinds to the `finally` and would otherwise reach the summary having scored
# only the setup assertions - i.e. report ALL PASS for a run that measured
# nothing. Nothing but the last line of the drive sets this.
$script:drove = $false

function Assert([bool]$cond, [string]$name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

$WM_SETCURSOR = 0x0020
$WM_MOUSELEAVE = 0x02A3
$WM_MOUSEMOVE = 0x0200
$HTCLIENT = 1

$tmp = Join-Path $env:TEMP "ghoztty-linkhover-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$AccountStore = Join-Path $tmp 'account.dat'
$errlog = Join-Path $tmp 'stderr.log'

# Seed the account store with a DPAPI blob in the current (T93) shape, so the
# chooser opens ALREADY signed in and shows the link rather than the sign-in
# button. Relay base points at a dead port on purpose: the device fetch is not
# what this script is about, and a chooser with only the Local row still paints
# the whole account band.
function Write-AccountStore {
    $exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
    $json = '{"session_token":"sess-linkhover","expiry":' + $exp +
        ',"email":"e2e@example.com","relay_base":"http://127.0.0.1:47999"}'
    $enc = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($json), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($AccountStore, $enc)
}

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
}

# The account row's live control is whichever of its two buttons is VISIBLE -
# the owner-drawn link when signed in, the bordered button when not - and the
# row sits above every other button in the dialog, so "topmost visible BUTTON"
# names it without depending on its label.
function Get-AccountControl([IntPtr]$chooser) {
    $btns = @(Get-TestChildWindows -Window $chooser -Class 'Button' |
        Where-Object { $_.Visible } | Sort-Object Top)
    if ($btns.Count -eq 0) { return $null }
    return $btns[0]
}

# Ink in a screen rect of a capture: pixels that differ from the rect's most
# common color (its background) by more than a small tolerance. Counting ink
# rather than sampling one row is what makes the metric independent of where
# the underline lands, of the theme, and of the text itself - the underlined
# face is the same glyphs PLUS a rule, so hovering can only add.
function Measure-Ink($shot, $rect) {
    $x0 = [Math]::Max(0, $rect.Left - $shot.Left)
    $y0 = [Math]::Max(0, $rect.Top - $shot.Top)
    $x1 = [Math]::Min($shot.Width, $rect.Right - $shot.Left)
    $y1 = [Math]::Min($shot.Height, $rect.Bottom - $shot.Top)
    if ($x1 -le $x0 -or $y1 -le $y0) { return -1 }

    # A FLAT array, indexed by hand: `$px[$x - $x0, $y - $y0]` on a 2-D array is
    # a PS 5.1 trap - the comma binds tighter than the minus, so it parses as
    # `$px[$x - ($x0, $y) - $y0]` and dies in op_Subtraction.
    $w = $x1 - $x0
    $h = $y1 - $y0
    $counts = @{}
    $px = New-Object 'int[]' ($w * $h)
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $shot.Bitmap.GetPixel($x0 + $x, $y0 + $y)
            $key = ($c.R -shl 16) -bor ($c.G -shl 8) -bor $c.B
            $px[($y * $w) + $x] = $key
            if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
        }
    }
    $bgKey = 0; $bgN = -1
    foreach ($k in $counts.Keys) { if ($counts[$k] -gt $bgN) { $bgN = $counts[$k]; $bgKey = $k } }
    $br = ($bgKey -shr 16) -band 0xFF; $bg = ($bgKey -shr 8) -band 0xFF; $bb = $bgKey -band 0xFF

    $ink = 0
    foreach ($k in $px) {
        $d = [Math]::Abs((($k -shr 16) -band 0xFF) - $br) +
             [Math]::Abs((($k -shr 8) -band 0xFF) - $bg) +
             [Math]::Abs(($k -band 0xFF) - $bb)
        if ($d -gt 24) { $ink++ }
    }
    return $ink
}

# Ink in the link's rect, captured off the CHOOSER (PrintWindow on the parent
# renders its children, and the dialog is the window that owns the band).
function Get-LinkInk([IntPtr]$chooser, $linkRect) {
    Start-Sleep -Milliseconds 250
    $shot = Get-TestWindowPixels -Window $chooser
    try { return (Measure-Ink $shot $linkRect) } finally { Close-TestWindowPixels $shot }
}

if (-not (Test-Path $Exe)) { Write-Host "SETUP FAIL: $Exe not found"; exit 1 }

Write-AccountStore
Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Remove-Item env:GHOSTTY_ACCOUNT_STORE -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: GhozttyWindow not found'; exit 1 }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: GhozttyTerminal not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the GUI is NOT enumerable on the interactive desktop'

    [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
    $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opened the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser to score'; exit 1 }
    Start-Sleep -Milliseconds 500

    # --- the subject: the signed-in link -------------------------------------
    $ctl = Get-AccountControl $chooser
    Assert ($null -ne $ctl) 'the account row has a visible control'
    if ($null -eq $ctl) { Write-Host 'SETUP FAIL: no account control'; exit 1 }
    $link = [IntPtr]$ctl.Hwnd
    $label = Get-TestControlText -Control $link
    Assert ($label -eq 'Sign Out') "the seeded account signed the chooser in, so the control is the link (label='$label')"
    if ($label -ne 'Sign Out') { Write-Host 'SETUP FAIL: chooser is not in the signed-in state'; exit 1 }

    $linkRect = Get-TestWindowRect -Window $link
    Assert (($linkRect.Right - $linkRect.Left) -gt 0 -and ($linkRect.Bottom - $linkRect.Top) -gt 0) `
        'the link has a real rect to measure'

    # A FOCUSED link underlines too (`marked = link_hot or pressed or focused`),
    # which would peg the metric at its maximum and make every state look hot.
    # The chooser puts focus in the filter, so this is an assertion, not a fix-up.
    $focus = Get-TestFocusedWindow -Window $chooser
    Assert ($focus -ne $link) 'the link does not hold focus, so focus is not underlining it for us'

    # --- (1) baseline --------------------------------------------------------
    $rest = Get-LinkInk $chooser $linkRect
    Assert ($rest -gt 0) "the link paints at rest (ink=$rest)"
    if ($rest -le 0) {
        Write-Host 'SETUP FAIL: the capture found no ink in the link rect - nothing below can discriminate'
        exit 1
    }

    # --- (2) positive control: entering underlines ---------------------------
    # lparam is MAKELPARAM(hit-test, mouse message), the shape Windows sends;
    # the handler reads only wparam (the window under the pointer).
    $lp = [IntPtr](($WM_MOUSEMOVE -shl 16) -bor $HTCLIENT)
    [void](Send-TestRawMessage -Window $chooser -Message $WM_SETCURSOR -WParam $link -LParam $lp)
    $hot = Get-LinkInk $chooser $linkRect
    Assert ($hot -gt $rest) "the pointer entering the link adds the underline (rest=$rest, hot=$hot)"

    # --- (3) the fix: leaving the WINDOW clears it ---------------------------
    # No second WM_SETCURSOR is posted here on purpose: this is the path where
    # the pointer left the dialog outright, so WM_MOUSELEAVE is the only news
    # the app gets. Pre-T315 the link had no subclass and this changed nothing.
    [void](Send-TestRawMessage -Window $link -Message $WM_MOUSELEAVE)
    $left = Get-LinkInk $chooser $linkRect
    if ($NegativeControl) {
        $script:negReached = $true
        Assert ($left -ge $hot) "NEGATIVE CONTROL: the underline SHOULD have stuck (hot=$hot, after leave=$left)"
    } else {
        Assert ($left -lt $hot) "leaving the window clears the underline (hot=$hot, after leave=$left)"
        Assert ($left -eq $rest) "and it lands back exactly on the resting paint (rest=$rest, after leave=$left)"
    }

    # --- (4) repeatable ------------------------------------------------------
    [void](Send-TestRawMessage -Window $chooser -Message $WM_SETCURSOR -WParam $link -LParam $lp)
    $hot2 = Get-LinkInk $chooser $linkRect
    [void](Send-TestRawMessage -Window $link -Message $WM_MOUSELEAVE)
    $left2 = Get-LinkInk $chooser $linkRect
    Assert ($hot2 -eq $hot -and $left2 -eq $rest) `
        "a second enter/leave cycle repeats it exactly (hot2=$hot2, left2=$left2)"

    # --- (5) the subclass did not break the control --------------------------
    $rect2 = Get-TestWindowRect -Window $link
    Assert ((Get-TestControlText -Control $link) -eq 'Sign Out') 'the link still answers WM_GETTEXT with its label'
    Assert ($rect2.Left -eq $linkRect.Left -and $rect2.Right -eq $linkRect.Right) 'the link did not move or resize'
    # WM_GETDLGCODE is the discriminating forward test: the BUTTON class answers
    # it with DLGC_BUTTON, and DefWindowProcW answers 0. (WM_GETTEXT above is
    # not - DefWindowProcW serves that one too, so a subclass that lost its way
    # to the original proc would still pass it.)
    $dlgcode = [int](Invoke-TestMessage -Window $link -Message 0x0087)
    Assert (($dlgcode -band 0x2000) -ne 0) `
        "the subclass still forwards to the BUTTON class (WM_GETDLGCODE=0x$('{0:X}' -f $dlgcode))"
    $style = Get-TestWindowStyle -Window $link
    Assert (($style -band 0x0000000B) -eq 0x0000000B) `
        "the link kept BS_OWNERDRAW (style=0x$('{0:X}' -f $style))"
    Assert (Test-TestWindowEnabled -Window $link) 'the link is still enabled'

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
    Write-Host "CHOOSER-LINK-HOVER ACCEPTANCE: ALL PASS ($($script:pass) assertions)"
    exit 0
} else {
    Write-Host "CHOOSER-LINK-HOVER ACCEPTANCE: $($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red
    exit 1
}
