# Machine-chooser acceptance (tracker T22c): ctrl+shift+n opens the "New
# Remote Window" picker, which fetches the signed-in account's enrolled relay
# devices and (on selection) dials one through the shared open path. The dialog
# is GUI, so this drives the REAL ctrl+shift+n chord into the debug build's
# surface and asserts the open+fetch path end to end:
#
#   1. a debug log line proves the chord reached openMachineChooser;
#   2. a GhozttyMachineChooser window appears;
#   3. the chooser performed GET /v1/client/devices against a loopback fake
#      relay directory (the deterministic positive control - it only happens
#      if the chooser actually opened and ran its fetch);
#   4. the app survives opening and Escape-closing the chooser (no crash).
#
# T172 adds the look of the thing (the T140 report): the list is owner-drawn
# with two-line machine rows, the selection is an INSET rounded accent pill
# rather than a full-width system-blue bar (pixel-probed, with an unselected
# row as the negative control), the filter shows a cue banner while empty, and
# the status strip WRAPS - a second, signed-out run proves it never clips.
#
# T175 adds the SHAPE (Mac's master-detail chooser): a fixed 840x540 dialog, a
# washed machine column at the left separated by a hairline rule, a detail pane
# at the right that names the selected machine and carries the "New Window"
# primary action, and Cancel alone in the footer. The detail pane is asserted to
# FOLLOW the selection (arrow down must repaint it), and - since the window no
# longer grows - the wrapping strip now takes its extra lines out of the LIST.
#
#   powershell -NoProfile -File test\win32\ipc-machine-chooser.ps1
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1), so
# it never takes the user's foreground - asserted at the end, not assumed. The
# private win32 driver (McDrv) is gone. What the migration changed beyond the
# mechanics:
#
#   * it no longer SKIPs. The whole script used to exit 0 with "SKIPPED
#     (foreground unavailable)" whenever another window owned the foreground,
#     so a busy box scored a green run that had asserted nothing. On the test
#     desktop the chord always lands and a missing chooser is a SETUP FAIL.
#   * the pixel probes moved from CopyFromScreen (dead off the input desktop)
#     to PrintWindow via Get-TestWindowPixels. Everything they read is the
#     dialog's own GDI chrome - the list's owner-drawn rows, the column wash,
#     the rule, the cue banner, the status strip - which is exactly the half of
#     the CAPTURE LIMIT that migrates. Each capture is guarded with
#     Get-TestDistinctColors: a window captured mid-paint comes back solid
#     black, and black satisfies a "was anything drawn?" probe while proving
#     nothing (T216).
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$DirPort = 47931,
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = '-mctest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
Add-Type -AssemblyName System.Security

$script:pass = 0
$script:fail = 0
$script:skip = 0
$script:negReached = $false
$script:negReached3 = $false
# Signed-in geometry, captured in run 1 and compared against the signed-out
# run's (T172 wrapping footer).
$script:chooserH1 = 0
$script:hintH1 = 0
$script:hintLineH = 0
$script:listH1 = 0
$script:rowH1 = 0
# The signed-OUT account control's width, compared against the signed-in link's
# in the T311 section: one fixed slot would make them equal.
$script:acctBtnW1 = 0
# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its caller gets @('  PASS ...', $value) (the T217 batch-5 trap).
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# --- window/control helpers (all through the test-desktop worker thread) ------
function Get-Rect([IntPtr]$h) { Get-TestWindowRect -Window $h }
function Get-Height([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return -1 }
    return (Get-TestWindowRect -Window $h).Height
}

# WHICH CONTROL IS WHICH comes from lib\ChooserControls.ps1 (T294), which
# TestDesktop.ps1 already dot-sources - `Get-ChooserPrimaryButton`,
# `Get-ChooserCancelButton`, `Get-ChooserList`, `Get-ChooserFilterField`,
# `Get-ChooserAccountButton`, `Get-ChooserHintText` - and the generic
# enumerator is `Get-TestControls` (lib\TestDesktop.ps1).
#
# This script used to find them by creation ORDER ("the first ListBox") and by
# LABEL ("the button that says New Window"), and it kept private copies of both
# lookups. The label one made an assertion circular: it found the primary action
# BY the caption `New Window` and then asserted the caption was `New Window`.
# The lookup asks the app for the control's own id now, so that assertion is a
# real one.

# Seed a DPAPI account store in the CURRENT (T93) shape, so a GUI comes up
# SIGNED IN without running the browser flow. The account row's signed-in
# composition (T311) is otherwise unreachable from this script.
function Write-AccountStore([string]$path, [string]$token, [string]$email, [string]$relayBase) {
    $exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
    $json = "{`"session_token`":`"$token`",`"expiry`":$exp,`"email`":`"$email`",`"relay_base`":`"$relayBase`"}"
    $enc = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($json), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($path, $enc)
}

# The chooser's client width is `px(840, scale)` by construction (T175, see
# chooser_layout.layout), so the live DPI scale - and with it the one-line
# status-strip height, `px(16, scale)` - is derivable from the window itself
# instead of hardcoded per box.
function Get-ChooserScale([IntPtr]$h) {
    $c = Get-TestWindowRect -Window $h -Client
    if ($c.Width -le 0) { return 1.0 }
    return $c.Width / 840.0
}

# A DIP measurement in the chooser's physical pixels is `Get-TestChromeDip`
# (lib\ChromeGeometry.ps1, dot-sourced through TestDesktop.ps1 above). This
# script used to keep a private `Dip` that rounded with PowerShell's default -
# BANKER'S rounding - where every layout module rounds with Zig's `@round`,
# half AWAY from zero. The two agree at 100/125/150/200% and disagree at
# 112.5%, so the bug was latent rather than absent (T257 found it in four
# scripts and swept them; this one measures its own dialog through its own
# helper, so it was never in that sweep - T314).
#
# `text_x` below is the OTHER half of the same lesson: a metric the module
# COMPOSES out of individually-rounded terms cannot be reproduced by rounding
# the total, at any rounding mode. See `Get-ChooserTextX`.

# The text column's left edge, composed the way `chooser_rows.rowMetrics`
# composes it: the pill inset (4), the status column's left pad (8) and width
# (12), the gap to the icon column (4), the icon column (28), and the gap to
# the text (12) - each `px()`-rounded on its own, then summed. Rounding their
# 68 DIP total instead happens to agree at 1.25 and does not at 1.125, where
# the module gives 79 and the total gives 77.
function Get-ChooserTextX([double]$scale) {
    $terms = @(4.0, 8.0, 12.0, 4.0, 28.0, 12.0)
    $sum = 0
    foreach ($t in $terms) { $sum += (Get-TestChromeDip -Dip $t -Scale $scale) }
    return $sum
}

# --- capture -----------------------------------------------------------------
# PrintWindow with no flags - the chooser paints the frame itself, synchronously,
# in answer to WM_PRINTCLIENT (T940/T942), rather than DWM handing back an
# asynchronous copy of the composited surface. CopyFromScreen is dead off the
# input desktop either way. Still retried: a capture taken before the dialog has
# a frame to give either throws (the sync path refuses a window that drew
# nothing) or comes back near-solid, and a solid frame would satisfy every
# drawn-pixel/tint probe below while proving nothing (T216).
function Get-Shot([IntPtr]$h) {
    $shot = $null
    for ($t = 0; $t -lt 15; $t++) {
        if ($shot) { Close-TestWindowPixels $shot }
        $shot = $null
        Start-Sleep -Milliseconds 200
        try { $shot = Get-TestWindowPixels -Window $h -Sync } catch { continue }
        if ((Get-TestDistinctColors -Shot $shot) -ge 8) { break }
    }
    return $shot
}

# Screen-coordinate pixel from a shot, as @(r, g, b).
function Get-ShotPixel($Shot, [int]$X, [int]$Y) {
    $px = Get-TestPixel -Shot $Shot -X $X -Y $Y
    if ($null -eq $px) { return @(-1, -1, -1) }
    return @([int]$px.R, [int]$px.G, [int]$px.B)
}

# The first column in a screen band holding a pixel at least $Min bright in
# every channel, as an offset from $X0 - or -1 if there is none.
#
# The threshold is what makes this a probe for the TEXT column rather than for
# "anything drawn": the row's title is COLOR_TEXT (230) while its status ring
# and machine glyph are the de-emphasized ramp (~160), so a floor between the
# two finds where the text begins without having to know where the glyph ended.
function Get-FirstBrightColumn($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int]$Min) {
    for ($x = $X0; $x -lt $X1; $x++) {
        for ($y = $Y0; $y -lt $Y1; $y++) {
            $lx = $x - $Shot.Left
            $ly = $y - $Shot.Top
            if ($lx -lt 0 -or $ly -lt 0 -or $lx -ge $Shot.Width -or $ly -ge $Shot.Height) { continue }
            $px = $Shot.Bitmap.GetPixel($lx, $ly)
            if ([int]$px.R -ge $Min -and [int]$px.G -ge $Min -and [int]$px.B -ge $Min) {
                return $x - $X0
            }
        }
    }
    return -1
}

# The strongest blue tint (b - r) anywhere in a screen rect.
#
# Since T828 the accent on a selected row lives on ONE thing: the 4x16
# indicator capsule at the pill's leading edge, `chrome_theme.accentOn(fill,
# accent)` - the accent clamped to 3:1 against the pill it sits on - so with the
# accent this script pins it is far bluer than the neutral wash around it. (It
# used to be a full accent rim, and this comment used to say so; T988.) A max is
# the right statistic because the mark is four DIP of a capsule: its exact x
# moves with DPI rounding, and a fixed-coordinate probe would be asserting where
# the mark is rather than that it exists. Everything else in the band is grey
# text or a grey glyph, so nothing else competes.
function Get-MaxBlueTint($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1) {
    $max = -255
    for ($y = $Y0; $y -lt $Y1; $y++) {
        for ($x = $X0; $x -lt $X1; $x++) {
            $lx = $x - $Shot.Left
            $ly = $y - $Shot.Top
            if ($lx -lt 0 -or $ly -lt 0 -or $lx -ge $Shot.Width -or $ly -ge $Shot.Height) { continue }
            $px = $Shot.Bitmap.GetPixel($lx, $ly)
            $t = [int]$px.B - [int]$px.R
            if ($t -gt $max) { $max = $t }
        }
    }
    return $max
}

# A cheap position-weighted checksum of a screen rect: two different strings
# rendered in the same box give different values, where a bare drawn-pixel
# COUNT can collide.
function Get-RegionSignature($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1) {
    $sig = 0
    for ($y = $Y0; $y -lt $Y1; $y++) {
        for ($x = $X0; $x -lt $X1; $x++) {
            $lx = $x - $Shot.Left
            $ly = $y - $Shot.Top
            if ($lx -lt 0 -or $ly -lt 0 -or $lx -ge $Shot.Width -or $ly -ge $Shot.Height) { continue }
            $px = $Shot.Bitmap.GetPixel($lx, $ly)
            $sig = ($sig + ($lx + 1) * [int]$px.R + ($ly + 1) * [int]$px.B) % 2147483647
        }
    }
    return $sig
}

# How many pixels in a screen rect differ from (R,G,B) by more than Tol in any
# channel - i.e. how much was actually DRAWN there.
function Measure-DrawnPixels($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int]$R, [int]$G, [int]$B, [int]$Tol) {
    $n = 0
    for ($y = $Y0; $y -lt $Y1; $y++) {
        for ($x = $X0; $x -lt $X1; $x++) {
            $lx = $x - $Shot.Left
            $ly = $y - $Shot.Top
            if ($lx -lt 0 -or $ly -lt 0 -or $lx -ge $Shot.Width -or $ly -ge $Shot.Height) { continue }
            $px = $Shot.Bitmap.GetPixel($lx, $ly)
            if ([Math]::Abs([int]$px.R - $R) -gt $Tol -or
                [Math]::Abs([int]$px.G - $G) -gt $Tol -or
                [Math]::Abs([int]$px.B - $B) -gt $Tol) { $n++ }
        }
    }
    return $n
}

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Exact-exe rather than a '*zig-out*' CommandLine match (T53b), plus the
# sibling agent and the debug session-layout manifest, so a previous run's
# window cannot be restored under this run's target name.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
}

# Open the chooser with ctrl+shift+n and wait for the window. On the test
# desktop there is no foreground race, so a zero return is the PRODUCT not
# opening it.
function Open-Chooser($g) {
    if (-not (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N)) {
        return [IntPtr]::Zero
    }
    return (Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000)
}

# Launch a GUI on the test desktop and find its window + surface.
function Launch-Gui($errlog) {
    # `--background` is pinned because the dialog's surface is DERIVED from it
    # since T308 (`chrome_theme.chromeBase` under the default
    # `window-theme = auto`), and the row probes below score the accent tint as
    # b-r. Ghostty's default background is #282c34, which carries b-r = 12 of
    # its own - so on a correct build the "untinted" control measured a tint
    # that came from the terminal background rather than from any pill. A
    # neutral grey gives b-r = 0 at rest, which is what makes the tint probes
    # mean what they say (the same reason the script pins the accent below).
    #
    # The client id is pinned for the same class of reason (T747): with none
    # resolvable the account row is in its `unconfigured` state and draws NO
    # sign-in button at all, so this script's signed-out measurements would be
    # measuring a state it is not about - and which one a build lands in depends
    # on whether the box has a google-client-id.txt, which is not a property of
    # the code under test. The value is never used: nothing here signs in.
    $env:GHOSTTY_GOOGLE_CLIENT_ID = 'cid-chooser-layout'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false', '--background=#1e1e1e') -StdErr $errlog
    Remove-Item env:GHOSTTY_GOOGLE_CLIENT_ID -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

# --- Fake relay device directory (loopback HTTP; records each request) -------
$hitFile = Join-Path $env:TEMP "ghoztty-mc-hits-$PID.txt"
Remove-Item $hitFile -ErrorAction SilentlyContinue
$devicesJson = '{"devices":[{"id":"dev-e2e","name":"E2E-Box","hostname":"e2e.local","online":true}]}'
$dirJob = Start-Job -ScriptBlock {
    param($port, $body, $hitFile)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    $payload = [Text.Encoding]::UTF8.GetBytes($body)
    $resp = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
    $respBytes = [Text.Encoding]::UTF8.GetBytes($resp) + $payload
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            Start-Sleep -Milliseconds 40
            $buf = New-Object byte[] 16384
            $sb = New-Object Text.StringBuilder
            while ($stream.DataAvailable) {
                $n = $stream.Read($buf, 0, $buf.Length)
                [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
            }
            $reqLine = ($sb.ToString() -split "`r`n")[0]
            Add-Content -Path $hitFile -Value $reqLine
            $stream.Write($respBytes, 0, $respBytes.Length)
            $stream.Flush()
        } catch {}
        $client.Close()
    }
} -ArgumentList $DirPort, $devicesJson, $hitFile
Start-Sleep -Milliseconds 600

$errlog = Join-Path $env:TEMP "ghoztty-mc-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue
$acctDir = Join-Path $env:TEMP "ghoztty-mc-acct-$PID"
$acctDir2 = Join-Path $env:TEMP "ghoztty-mc-acct2-$PID"
# T311's third run comes up with a REAL (seeded) account, which is the only way
# to reach the account row's signed-in composition.
$acctDir3 = Join-Path $env:TEMP "ghoztty-mc-acct3-$PID"
$T311_EMAIL = 'monogram@example.com'

# --- Pin the accent the selection pill is drawn from (T305) -----------------
#
# The pill is `chooser_rows.selectionFill(ROW_BG, accent)` and `accent` is the
# USER'S, read from HKCU\...\DWM\AccentColor. So a probe of the pill is a probe
# of a system setting, and it has to state its input: #3D8EF8 is the literal
# `chooser_rows.accent` used to hold, it clears the 3:1 floor against ROW_BG
# unassisted (so `chrome_theme.accentOn` hands it back untouched), and it is
# what the b-r assertions below were written against.
#
# Restored - the original value, or its ABSENCE - in the `finally`, so a
# mid-script failure cannot leave the box repainted (T179). PS5.1 reads a
# REG_DWORD with the top bit set as a value that does not fit Int32, hence the
# byte round-trip rather than a cast.
$DWM_KEY = 'HKCU:\Software\Microsoft\Windows\DWM'
$origAccent = $null
$hadAccent = $false
$p = Get-ItemProperty -Path $DWM_KEY -Name AccentColor -ErrorAction SilentlyContinue
if ($null -ne $p) {
    $hadAccent = $true
    $origAccent = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$p.AccentColor), 0)
}
# ABGR, little-endian: bytes R,G,B,FF IS the 0xAABBGGRR DWORD.
Set-ItemProperty -Path $DWM_KEY -Name AccentColor -Type DWord `
    -Value ([BitConverter]::ToInt32([byte[]]@(0x3D, 0x8E, 0xF8, 0xFF), 0))

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # --- Launch a debug GUI signed in via the env token, isolated from any real
    # account so GHOSTTY_RELAY_TOKEN is what resolves. -----------------------
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DirPort"
    $env:GHOSTTY_RELAY_TOKEN = 'faketoken-e2e'
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $acctDir 'account.dat')
    $g = Launch-Gui $errlog
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    if (-not $g) { Write-Host 'SETUP FAIL: GUI did not come up'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) 'signed-in GUI is NOT enumerable on the interactive desktop'

    $chooser = Open-Chooser $g
    Start-Sleep -Milliseconds 300
    $err = Get-Content $errlog -Raw -ErrorAction SilentlyContinue
    $hits = Get-Content $hitFile -ErrorAction SilentlyContinue

    Assert ($err -match 'machine chooser: opening via ctrl\+shift\+n') 'ctrl+shift+n reached openMachineChooser (stderr)'
    Assert ($chooser -ne [IntPtr]::Zero) 'GhozttyMachineChooser window opened'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser to score'; exit 1 }
    Assert ((Get-TestControlText -Control $chooser) -eq 'New Remote Window') 'chooser caption is "New Remote Window"'
    # The chooser is modal over its own window - cross-process, a disabled owner
    # is the only checkable form of that, and nothing here asserted it before.
    Assert (-not (Test-TestWindowEnabled -Window $g.Top)) 'the owner window is disabled while the chooser is up'
    Assert (($hits -join "`n") -match '/v1/client/devices') 'chooser fetched the device directory (GET /v1/client/devices)'
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'app survived opening the chooser'

    # --- T172: rows carry machine identity, not a system-blue bar ------------
    $LBS_OWNERDRAWFIXED = 0x0010
    $LBS_HASSTRINGS = 0x0040
    $LB_GETITEMHEIGHT = 0x01A1
    $LB_GETCOUNT = 0x018B

    $list = ConvertTo-TestHwnd (Get-ChooserList -Chooser $chooser)
    $edit = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Assert ($list -ne [IntPtr]::Zero) 'chooser has a machine list'

    # The live DPI scale, derived from the window's own fixed 840 width. Needed
    # this early since T310, because the row probes below are stated in DIP.
    $scale = Get-ChooserScale $chooser

    $shot = Get-Shot $chooser
    Assert ((Get-TestDistinctColors -Shot $shot) -ge 8) "the chooser capture holds real content ($(Get-TestDistinctColors -Shot $shot) distinct colors)"

    $rowH = 0
    if ($list -ne [IntPtr]::Zero) {
        $style = Get-TestWindowStyle -Window $list
        Assert (($style -band $LBS_OWNERDRAWFIXED) -ne 0) 'list rows are owner-drawn (LBS_OWNERDRAWFIXED)'
        Assert (($style -band $LBS_HASSTRINGS) -eq 0) 'list no longer stores single-line strings (no LBS_HASSTRINGS)'

        $rowH = [int](Invoke-TestMessage -Window $list -Message $LB_GETITEMHEIGHT)
        Assert ($rowH -ge 40) "row height fits a name + subline (got $rowH, want >= 40)"

        $count = [int](Invoke-TestMessage -Window $list -Message $LB_GETCOUNT)
        Assert ($count -eq 2) "list shows Local + the fetched device (got $count rows)"

        # Pixel oracle: the selected row is an INSET rounded pill. Probe the
        # gutter beside it (must stay list background) and the pill itself,
        # then an unselected row at the same x as a negative control. This is
        # exactly what the T140 screenshot got wrong: a full-width system-blue
        # selection bar.
        #
        # T312 splits this in two, because the pill's strength is now a
        # function of WHERE KEYBOARD FOCUS IS and a probe that does not say
        # which state it measures is measuring whichever one it happened to
        # catch. The chooser opens with focus in the FILTER
        # (`MachineChooser.open` -> `SetFocus(self.filter)`), so this shot is
        # the list UNFOCUSED: a neutral pill, no accent in it.
        $lr = Get-Rect $list
        $yRow0 = $lr.Top + 1 + [int]($rowH / 2)
        $yRow1 = $lr.Top + 1 + $rowH + [int]($rowH / 2)
        $rowTop = $lr.Top + 1
        $rowBot = $rowTop + $rowH
        $pillX0 = $lr.Left + (Get-TestChromeDip -Dip 4.0 -Scale $scale)
        $pillX1 = $lr.Left + (Get-TestChromeDip -Dip 60.0 -Scale $scale)
        $gutter = Get-ShotPixel $shot ($lr.Left + 3) $yRow0
        $pill = Get-ShotPixel $shot ($lr.Left + 14) $yRow0
        $unsel = Get-ShotPixel $shot ($lr.Left + 14) $yRow1

        # The tint is measured as b-r because the accent this run SET (below)
        # is blue. Before T305 the accent was a literal in `chooser_rows.zig`
        # and this probe silently depended on it; now it is a system setting,
        # so the script pins the input it measures instead of scoring whatever
        # this box happens to be personalized to (which is #680081 here, and
        # made b-r = 6 - a correct build reading as a failure).
        $gutterTint = $gutter[2] - $gutter[0]
        $pillTint = $pill[2] - $pill[0]
        $unselTint = $unsel[2] - $unsel[0]
        Assert ($gutterTint -le 10) "selection is inset, not full-width (b-r = $gutterTint in the gutter)"
        Assert ($unselTint -le 10) "unselected row stays untinted (b-r = $unselTint)"

        # --- T312 finding 10: focus is visible, and it is a THIRD state -----
        #
        # Three claims, each measured in the state it belongs to:
        #   1. list unfocused -> the selected row is a NEUTRAL pill, and so is
        #      the mark at its leading edge. Drawn (brighter than the row
        #      background beside it) but carrying none of the accent, which is
        #      what says "the caret is elsewhere".
        #   2. list focused   -> the FILL stays neutral and steps up a weight
        #      (`selection_wash_unfocused` 0.10 -> `_focused` 0.16), and the
        #      accent appears on the 4x16 indicator capsule at the pill's
        #      leading edge. That is T828's treatment - Windows 11's list
        #      selection instead of Mac's tinted pill - and the indicator is
        #      the WHOLE of the row's accent, so the pill body has none.
        #   3. focus leaves   -> it goes back.
        #
        # This probe used to demand an accent TINT in the pill body (b - r >= 25
        # at Left+14) and went red the day T828 deliberately removed it. Its
        # successor is not a deletion (T988): the colour half of the oracle
        # moved to the band the accent moved to, and gained the fill-weight
        # check, so "the row repainted into the emphasized state" is still
        # measured in colour and not only in the region signature.
        #
        # The trigger and the color are separate oracles (T233): the region
        # signature says the row repainted at all, the tints say what it
        # repainted INTO. A signature alone would pass on any change; a tint
        # alone cannot tell a repaint from a stale capture.
        #
        # The two bands are split at the body sample: the mark lives at DIP
        # 6..10 (`fill_inset_x` + `xs`, 4 wide), the body sample at +14 is past
        # it, and the pill runs to DIP 60. Splitting there rather than
        # re-deriving the capsule's rect keeps the probe off a rounding
        # assumption at fractional scales.
        $markX1 = $lr.Left + 14
        Assert ($pillTint -le 10) "unfocused list: the selected row carries no accent (b-r = $pillTint)"
        Assert (($pill[0] - $gutter[0]) -ge 12) "unfocused list: the selected row still draws a neutral pill (r $($pill[0]) vs gutter $($gutter[0]))"
        $markUnfocused = Get-MaxBlueTint $shot $pillX0 $rowTop $markX1 $rowBot
        $bodyUnfocused = Get-MaxBlueTint $shot $markX1 $rowTop $pillX1 $rowBot
        $sigUnfocused = Get-RegionSignature $shot $pillX0 $rowTop $pillX1 $rowBot
        Assert ($markUnfocused -le 12) "unfocused list: the indicator mark is neutral too (max b-r = $markUnfocused in the mark band)"
        Assert ($bodyUnfocused -le 12) "unfocused list: no accent anywhere in the pill body (max b-r = $bodyUnfocused)"

        # One Tab from the filter is the list (`nextFocus`: filter -> list).
        Send-TestControlKey -Control $chooser -Key Tab | Out-Null
        Start-Sleep -Milliseconds 350
        $shotFocus = Get-Shot $chooser
        $pillF = Get-ShotPixel $shotFocus ($lr.Left + 14) $yRow0
        $pillFTint = $pillF[2] - $pillF[0]
        $markFocused = Get-MaxBlueTint $shotFocus $pillX0 $rowTop $markX1 $rowBot
        $bodyFocused = Get-MaxBlueTint $shotFocus $markX1 $rowTop $pillX1 $rowBot
        $sigFocused = Get-RegionSignature $shotFocus $pillX0 $rowTop $pillX1 $rowBot
        Close-TestWindowPixels $shotFocus
        Assert ($sigFocused -ne $sigUnfocused) "Tab onto the list repaints the focused row (signature $sigUnfocused -> $sigFocused)"
        Assert ($pillFTint -le 10) "focused list: the pill fill stays neutral, the accent is not in it (b-r = $pillFTint at the pill body)"
        Assert (($pillF[0] - $pill[0]) -ge 4) "focused list: the fill steps up to the emphasized wash (r $($pill[0]) -> $($pillF[0]))"
        Assert ($markFocused -ge 25) "focused list: the accent is on the indicator mark (max b-r = $markFocused in the mark band)"
        Assert ($bodyFocused -le 12) "focused list: and nowhere else on the row (max b-r = $bodyFocused across the pill body)"

        # And it reverts. Tab again rather than Shift+Tab: the app asks
        # `GetKeyState(VK_SHIFT)`, which a POSTED message never sets, so a
        # posted Shift+Tab would go forwards and this assertion would be
        # testing the wrong transition. Forward from the list is the detail
        # action, which is always visible.
        Send-TestControlKey -Control $chooser -Key Tab | Out-Null
        Start-Sleep -Milliseconds 350
        $shotBlur = Get-Shot $chooser
        $pillB = Get-ShotPixel $shotBlur ($lr.Left + 14) $yRow0
        $markBlur = Get-MaxBlueTint $shotBlur $pillX0 $rowTop $pillX1 $rowBot
        Close-TestWindowPixels $shotBlur
        Assert ((($pillB[2] - $pillB[0])) -le 10) "Tab away: the selection gives the accent back (b-r = $(($pillB[2] - $pillB[0])))"
        Assert ($markBlur -le 12) "Tab away: the indicator mark is neutral again (max b-r = $markBlur)"

        # T310 finding 8: the icon column is 28, not 20, so the text column's
        # left edge is 68 DIP from the row's edge (4 pill inset + 8 + a 12
        # status column + 4 + a 28 icon column + 12) where it used to be 60.
        # That 8 DIP is the whole visible consequence of reserving a column
        # instead of letting the mark BE the column, and it is only checkable
        # on screen - the unit test can only prove the number, not that the
        # painter used it.
        #
        # Row 0 is Local, which draws no status shape, so the only marks in the
        # band are the machine glyph (dim) and the title (bright).
        $bandTop = $lr.Top + 1
        $bandBot = $bandTop + $rowH
        # The expected value is EXACT now (T314): `Get-ChooserTextX` composes it
        # the way the module does, so the probe is anchored on `text_x` itself
        # rather than on a band picked to survive the arithmetic. What is left
        # over is only what the FONT adds - the "L" of "Local"'s left side
        # bearing - so the window is [text_x, text_x + sm]. MEASURED on this box
        # at 1.25: text_x = 85, first bright column = 87, ceiling 90. The
        # retired geometry put `text_x` at 60 DIP -> 75 px, which now misses the
        # floor by 10 px instead of the ~9 px of slack the band left.
        $textX = Get-ChooserTextX $scale
        $bearing = Get-TestChromeDip -Dip 4.0 -Scale $scale
        $textAt = Get-FirstBrightColumn $shot $lr.Left $bandTop ($lr.Left + (Get-TestChromeDip -Dip 110.0 -Scale $scale)) $bandBot 200
        Assert ($textAt -ge $textX) "the row's text starts at the composed text column (first bright column at $textAt, text_x = $textX)"
        Assert ($textAt -ge 0 -and $textAt -le ($textX + $bearing)) "and no further in than one glyph bearing (first bright column at $textAt, want <= $($textX + $bearing))"
    }

    if ($edit -ne [IntPtr]::Zero) {
        # Cue banner: the filter's TEXT is empty, yet its interior has drawn
        # pixels - the placeholder the old unlabeled box lacked.
        $er = Get-Rect $edit
        $drawn = Measure-DrawnPixels $shot ($er.Left + 4) ($er.Top + 4) ($er.Right - 4) ($er.Bottom - 4) 30 30 30 12
        Assert ((Get-TestControlText -Control $edit) -eq '') 'filter field is empty'
        Assert ($drawn -ge 40) "filter shows a cue banner while empty ($drawn drawn pixels)"
    }

    $script:chooserH1 = Get-Height $chooser
    # One wrapped line of the status strip. Since T310 that box is the type
    # ramp's CAPTION (12) plus `sm` leading, and the STATIC is rendered in the
    # caption font too - the reserved height and the font that fills it have to
    # come from the same place or a wrapped strip clips again (the T140 defect).
    # 12 + 4 still lands on 16, so this line is unchanged and is now also the
    # check that the two did not drift apart.
    $script:hintLineH = Get-TestChromeDip -Dip 16.0 -Scale $scale
    $hint1 = ConvertTo-TestHwnd (Get-ChooserStatic -Chooser $chooser -Edge bottom)
    if ($hint1 -ne [IntPtr]::Zero) { $script:hintH1 = Get-Height $hint1 }
    Assert ($script:hintH1 -eq $script:hintLineH) "signed-in status strip is one line (line=$($script:hintLineH), got $($script:hintH1))"
    if ($list -ne [IntPtr]::Zero) {
        $script:listH1 = Get-Height $list
        $script:rowH1 = $rowH
    }

    # --- T175: the master-detail shell --------------------------------------
    # T140's report was that the dialog "looks nothing like the mac dialog".
    # Mac's is 840x540 with a washed machine column at the left, a detail pane
    # at the right carrying the machine's identity and its primary action, and
    # Cancel alone in the footer. Each of those is asserted here against the
    # real window, not against the layout function.
    $cr = Get-TestWindowRect -Window $chooser -Client
    Assert ([Math]::Abs($cr.Height - (Get-TestChromeDip -Dip 540.0 -Scale $scale)) -le 2) "chooser client is Mac's 540 tall at this DPI (got $($cr.Height), want $(Get-TestChromeDip -Dip 540.0 -Scale $scale))"

    $orgX = $cr.Left
    $orgY = $cr.Top
    $masterRight = Get-TestChromeDip -Dip 260.0 -Scale $scale
    $footerY = Get-TestChromeDip -Dip 480.0 -Scale $scale

    # The column is a wash: brighter than the dialog surface beside it, at the
    # same height, below the last row.
    $yBody = $orgY + (Get-TestChromeDip -Dip 300.0 -Scale $scale)
    $washPx = Get-ShotPixel $shot ($orgX + (Get-TestChromeDip -Dip 200.0 -Scale $scale)) $yBody
    $panePx = Get-ShotPixel $shot ($orgX + (Get-TestChromeDip -Dip 600.0 -Scale $scale)) $yBody
    Assert (($washPx[0] - $panePx[0]) -ge 4) "machine column sits on a wash (col r=$($washPx[0]) vs pane r=$($panePx[0]))"

    # ...and a hairline rule divides them. Sample the 3 candidate columns so a
    # rounding-off-by-one does not read as absence.
    $ruleR = 0
    foreach ($dx in -1, 0, 1) {
        $p = Get-ShotPixel $shot ($orgX + $masterRight + $dx) $yBody
        if ($p[0] -gt $ruleR) { $ruleR = $p[0] }
    }
    Assert (($ruleR - $washPx[0]) -ge 8) "a rule separates the columns (rule r=$ruleR vs wash r=$($washPx[0]))"

    # The primary action is Mac's "New Window", it lives in the detail pane, and
    # the footer holds Cancel alone.
    #
    # Both are found by their control ID (T294), so the caption assertion below
    # is a real one: keyed on the label, it found the button BY the caption it
    # then asserted, and could only ever have passed.
    $buttons = @(Get-TestControls -Window $chooser -Class 'Button')
    $primary = Get-ChooserPrimaryButton -Chooser $chooser
    $cancel = Get-ChooserCancelButton -Chooser $chooser
    Assert ($null -ne $primary -and $primary.Text -eq 'New Window') "the primary action is labeled 'New Window' (saw: $(($buttons | ForEach-Object { $_.Text }) -join ', '))"
    Assert ($null -ne $cancel -and $cancel.Text -eq 'Cancel') 'the footer has a Cancel button'
    if ($primary) {
        Assert ((($primary.Left - $orgX) -gt $masterRight)) "the primary action is in the detail pane (left=$($primary.Left - $orgX), column ends at $masterRight)"
        Assert ((($primary.Bottom - $orgY) -lt $footerY)) 'the primary action is above the footer, not in it'
    }
    $inFooter = @($buttons | Where-Object { ($_.Top - $orgY) -ge $footerY })
    Assert ($inFooter.Count -eq 1 -and $inFooter[0].Text -eq 'Cancel') "Cancel is alone in the footer (found: $(($inFooter | ForEach-Object { $_.Text }) -join ', '))"

    # --- T310: one control height across the surface -------------------------
    # Design system 2.1. The filter field and the account control were 26 while
    # Cancel and the detail pane's action row were 28 - a 2 px difference that
    # reads as nobody having decided rather than as a hierarchy, and invisible
    # at 100% until you put two of them on one screenshot.
    #
    # Asserted as a RELATIONSHIP between real HWNDs, not against a re-derived
    # number: a control's height is a composed metric (a line box plus padding),
    # so rebuilding it from 28 * scale would restate at one rounding what the
    # module builds at several - and this claim needs no arithmetic at all.
    if ($cancel) {
        $ctlH = $cancel.Bottom - $cancel.Top
        if ($primary) {
            Assert ((($primary.Bottom - $primary.Top)) -eq $ctlH) "the detail action is the same height as Cancel (primary=$($primary.Bottom - $primary.Top), cancel=$ctlH)"
        }
        if ($edit -ne [IntPtr]::Zero) {
            $eh = Get-Height $edit
            Assert ($eh -eq $ctlH) "the filter field is the same height as Cancel (filter=$eh, cancel=$ctlH)"
        }
        # Signed OUT, the account row's control is the bordered button; the
        # signed-in state's link is hidden, so `Visible` is what tells them apart
        # (T311).
        # Asserted, not just guarded: a null here used to skip the two
        # measurements below in silence, and the row losing its button is
        # exactly what happens in the `unconfigured` state (T747) - a state this
        # script pins itself out of, and would want to hear about if it landed
        # in one anyway.
        $acct = Get-ChooserAccountButton -Chooser $chooser
        Assert ($null -ne $acct) 'the signed-out account row has a visible control to measure'
        if ($acct) {
            Assert ((($acct.Bottom - $acct.Top)) -eq $ctlH) "the account control is the same height as Cancel (account=$($acct.Bottom - $acct.Top), cancel=$ctlH)"
            $script:acctBtnW1 = $acct.Right - $acct.Left
            # T311 finding 6: the slot used to be a flat 150 DIP whatever the
            # caption was. "Sign in with Google…" is WIDER than that, so a
            # content-sized button is measurably not the retired slot.
            Assert ($script:acctBtnW1 -ne (Get-TestChromeDip -Dip 150.0 -Scale $scale)) "the account button is sized to its caption, not the retired 150 DIP slot (width=$($script:acctBtnW1), retired=$(Get-TestChromeDip -Dip 150.0 -Scale $scale))"
        }
    }

    # The detail pane names the selected machine, and it FOLLOWS the selection:
    # arrowing onto the relay device must repaint it.
    $dx0 = $orgX + (Get-TestChromeDip -Dip 300.0 -Scale $scale)
    $dx1 = $orgX + (Get-TestChromeDip -Dip 620.0 -Scale $scale)
    $dy0 = $orgY + (Get-TestChromeDip -Dip 60.0 -Scale $scale)
    $dy1 = $orgY + (Get-TestChromeDip -Dip 110.0 -Scale $scale)
    $headDrawn = Measure-DrawnPixels $shot $dx0 $dy0 $dx1 $dy1 32 32 32 12
    Assert ($headDrawn -ge 40) "the detail pane renders the machine's identity ($headDrawn drawn pixels)"
    $sigLocal = Get-RegionSignature $shot $dx0 $dy0 $dx1 $dy1
    Close-TestWindowPixels $shot

    # The chooser reads raw WM_KEYDOWN through App.run's routing (it is not a
    # standard #32770), so posted arrows and Escape reach it.
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    Start-Sleep -Milliseconds 350
    $shotDown = Get-Shot $chooser
    $sigDevice = Get-RegionSignature $shotDown $dx0 $dy0 $dx1 $dy1
    Close-TestWindowPixels $shotDown
    # -NegativeControl inverts THIS one: "the detail pane follows the selection"
    # is T175's behavioural claim, it normally passes, and it can only pass when
    # the chord landed, the list holds both machines and the pane repainted - so
    # inverting it discriminates instead of riding an already-red assertion.
    $follows = ($sigDevice -ne $sigLocal)
    $script:negReached = $true
    if ($NegativeControl) {
        Assert (-not $follows) "NEGATIVE CONTROL: the detail pane did NOT follow the selection (signature $sigLocal -> $sigDevice)"
    } else {
        Assert $follows "the detail pane follows the selection (signature $sigLocal -> $sigDevice)"
    }

    # Escape closes the chooser (routed via handleKey).
    Send-TestControlKey -Control $chooser -Key Escape | Out-Null
    Start-Sleep -Milliseconds 400
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'Escape closed the chooser'
    Assert (Test-TestWindowEnabled -Window $g.Top) 'the owner window is enabled again once the chooser is gone'
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'app survived closing the chooser'

    # --- T172: signed out, the footer WRAPS and the list gives up the room ----
    # The T140 screenshot's footer was clipped mid-sentence ("...to list your"):
    # the hint was a fixed one-line slot. Signed out, that hint is a long
    # sentence, so it must occupy more lines than the signed-in case (whose hint
    # is empty), the dialog must stay its fixed size, and the wrapped remainder
    # must actually be painted INSIDE the control.
    if ($script:chooserH1 -gt 0 -and $script:hintH1 -gt 0 -and $script:listH1 -gt 0) {
        Stop-DebugGhoztty
        $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $acctDir2 'account.dat')
        $g2 = Launch-Gui (Join-Path $env:TEMP "ghoztty-mc-stderr2-$PID.log")
        Remove-Item 'env:GHOSTTY_ACCOUNT_STORE' -ErrorAction SilentlyContinue
        if (-not $g2) { Write-Host 'SETUP FAIL: signed-out GUI did not come up'; exit 1 }
        Assert (-not (Test-TestDesktopLeak -ProcessId $g2.Pid)) 'signed-out GUI is NOT enumerable on the interactive desktop'

        $chooser2 = Open-Chooser $g2
        Assert ($chooser2 -ne [IntPtr]::Zero) 'chooser opens with no credential'
        if ($chooser2 -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 400
            $hint2 = ConvertTo-TestHwnd (Get-ChooserStatic -Chooser $chooser2 -Edge bottom)
            $hintH2 = Get-Height $hint2
            $chooserH2 = Get-Height $chooser2
            $list2 = ConvertTo-TestHwnd (Get-ChooserList -Chooser $chooser2)
            $listH2 = if ($list2 -ne [IntPtr]::Zero) { Get-Height $list2 } else { 0 }

            Assert ($hintH2 -ge 2 * $script:hintLineH) "signed-out status strip wraps to 2+ lines (line=$($script:hintLineH), got $hintH2)"
            # Since T175 the dialog is Mac's fixed 840x540, so the extra lines
            # come out of the LIST's height instead of the window's - same
            # no-clipping invariant, measured on the thing that flexes.
            Assert ($chooserH2 -eq $script:chooserH1) "dialog stayed a fixed size (was $($script:chooserH1), now $chooserH2)"
            # The list sheds the room in WHOLE rows (an owner-drawn listbox must
            # never render a clipped half row), so the accounting is "the extra
            # strip height, to the nearest row" - and the list must end above the
            # strip, which is the actual no-overlap invariant the old
            # grow-the-dialog assertion stood for.
            $shed = $script:listH1 - $listH2
            $grew = $hintH2 - $script:hintH1
            Assert ($shed -ge ($grew - $script:rowH1) -and $shed -le ($grew + $script:rowH1)) "the list gave up the extra strip height, to the nearest row (list -$shed, strip +$grew, row $($script:rowH1))"
            Assert ($script:rowH1 -gt 0 -and ($listH2 % $script:rowH1) -eq 0) "the list still holds whole rows only ($listH2 / row $($script:rowH1))"
            $lr2 = Get-Rect $list2
            $hr2 = Get-Rect $hint2
            Assert ($lr2.Bottom -le $hr2.Top) "the list stops above the wrapped strip (list ends $($lr2.Bottom), strip starts $($hr2.Top))"

            # The wrapped remainder is painted inside the control, not cut off:
            # the strip's bottom half has text pixels on the column wash it sits
            # on.
            $mid = $hr2.Top + [int]($hintH2 / 2)
            $shot2 = Get-Shot $chooser2
            Assert ((Get-TestDistinctColors -Shot $shot2) -ge 8) "the signed-out capture holds real content ($(Get-TestDistinctColors -Shot $shot2) distinct colors)"
            $tail = Measure-DrawnPixels $shot2 $hr2.Left $mid $hr2.Right $hr2.Bottom 40 40 40 12
            Close-TestWindowPixels $shot2
            Assert ($tail -ge 20) "the wrapped tail of the strip is rendered ($tail drawn pixels below the first line)"
        }
        Assert (-not ($g2.App.Process -and $g2.App.Process.HasExited)) 'app survived the signed-out chooser'
    }

    # --- T311: the account row's identity block (findings 5 and 6) -----------
    # Signed IN, Mac's account row is the email over a LINK-styled "Sign Out"
    # with a 34 px accent monogram circle beside them; win32 drew a static plus
    # a 150 DIP button and no identity cue at all. This run seeds a DPAPI
    # account store so the app comes up signed in - the composition is
    # unreachable from the two runs above, both of which are signed out at the
    # ACCOUNT tier (run 1 has a credential, via GHOSTTY_RELAY_TOKEN, but no
    # account).
    Stop-DebugGhoztty
    New-Item -ItemType Directory -Force -Path $acctDir3 | Out-Null
    $store3 = Join-Path $acctDir3 'account.dat'
    Write-AccountStore $store3 'faketoken-t311' $T311_EMAIL "http://127.0.0.1:$DirPort"
    $errlog3 = Join-Path $env:TEMP "ghoztty-mc-stderr3-$PID.log"
    $env:GHOSTTY_ACCOUNT_STORE = $store3
    $g3 = Launch-Gui $errlog3
    Remove-Item 'env:GHOSTTY_ACCOUNT_STORE' -ErrorAction SilentlyContinue
    if (-not $g3) {
        Write-Host 'SETUP FAIL: signed-in GUI did not come up'
        $script:fail++
    } else {
        $chooser3 = Open-Chooser $g3
        Assert ($chooser3 -ne [IntPtr]::Zero) 'chooser opens with a seeded account'
        if ($chooser3 -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 500
            $scale3 = Get-ChooserScale $chooser3
            $cr3 = Get-TestWindowRect -Window $chooser3 -Client
            $org3X = $cr3.Left
            $org3Y = $cr3.Top

            # Both account controls, asked for by id (T294) rather than
            # inferred from "every button above the header rule" - so where
            # they SIT is now an assertion of its own instead of a premise of
            # the lookup.
            $bandBot3 = $org3Y + (Get-TestChromeDip -Dip 52.0 -Scale $scale3)
            $acctBtns = @(Get-ChooserAccountButton -Chooser $chooser3 -IncludeHidden)
            $liveAcct = @($acctBtns | Where-Object { $_.Visible })
            Assert ($acctBtns.Count -eq 2) "the account row carries both controls (found $($acctBtns.Count))"
            Assert (@($acctBtns | Where-Object { $_.Top -lt $bandBot3 }).Count -eq $acctBtns.Count) `
                "both account controls sit in the band above the header rule (band ends at $bandBot3, tops: $(($acctBtns | ForEach-Object { $_.Top }) -join ', '))"
            Assert ($liveAcct.Count -eq 1) "exactly one account control is visible at a time (visible: $($liveAcct.Count))"
            if ($liveAcct.Count -eq 1) {
                # Finding 6, the behavioural half: signed in, the control is the
                # LINK - and its width follows "Sign Out", not the wider
                # "Sign in with Google…" the signed-out state shows. One shared
                # 150 DIP slot would make these two equal.
                Assert ($liveAcct[0].Text -eq 'Sign Out') "signed in, the account control reads 'Sign Out' (got '$($liveAcct[0].Text)')"
                $linkW = $liveAcct[0].Right - $liveAcct[0].Left
                Assert ($script:acctBtnW1 -gt 0) 'the signed-out button width was captured to compare against'
                Assert ($linkW -lt $script:acctBtnW1) "the link is sized to ITS caption, not to a slot shared with sign-in (link=$linkW, button=$($script:acctBtnW1))"
                # A link has no border and no button padding, so it is also
                # shorter than the surface's button floor.
                Assert ($linkW -lt (Get-TestChromeDip -Dip 96.0 -Scale $scale3)) "the link is not padded like a button (width=$linkW, button floor=$(Get-TestChromeDip -Dip 96.0 -Scale $scale3))"
            }

            # The email is the identity text, right-aligned above the link.
            $topStatic = $null
            foreach ($s in Get-TestControls -Window $chooser3 -Class 'Static') {
                if ($null -eq $topStatic -or $s.Top -lt $topStatic.Top) { $topStatic = $s }
            }
            Assert ($null -ne $topStatic -and $topStatic.Text -eq $T311_EMAIL) "the account row shows the signed-in email (got '$(if ($topStatic) { $topStatic.Text })')"
            if ($topStatic -and $liveAcct.Count -eq 1) {
                Assert ([Math]::Abs($topStatic.Right - $liveAcct[0].Right) -le 1) "the email and the link share a right edge (email=$($topStatic.Right), link=$($liveAcct[0].Right))"
                Assert ($topStatic.Bottom -le $liveAcct[0].Top) 'the email sits ABOVE the link, as a stack'
            }

            # Finding 5, the pixel half: the monogram circle. Its fill is
            # `chrome_theme.accentOn(DIALOG_BG, accent)` and the accent is PINNED
            # at the top of this script (#3D8EF8, which clears the 3:1 floor
            # unassisted, so it comes back untouched) - T305's rule that an
            # oracle for a system-derived pixel must state its input.
            #
            # The disc is `avatar_d` (32) square at the band's trailing edge:
            # x in [840-16-32, 840-16], y centered in the 36 band that starts 8
            # below the client top.
            $avR = $org3X + (Get-TestChromeDip -Dip 824.0 -Scale $scale3)
            $avL = $org3X + (Get-TestChromeDip -Dip 792.0 -Scale $scale3)
            $avT = $org3Y + (Get-TestChromeDip -Dip 10.0 -Scale $scale3)
            $avB = $org3Y + (Get-TestChromeDip -Dip 42.0 -Scale $scale3)
            $shot3 = Get-Shot $chooser3
            Assert ((Get-TestDistinctColors -Shot $shot3) -ge 8) "the signed-in capture holds real content ($(Get-TestDistinctColors -Shot $shot3) distinct colors)"
            # Sample INSIDE the disc but off its center line, where the letter
            # is: the fill is what the ring reads.
            $ring = Get-ShotPixel $shot3 ($avL + [int](($avR - $avL) * 0.12)) ($avT + [int](($avB - $avT) * 0.5))
            $fillHit = ([Math]::Abs($ring[0] - 0x3D) -le 12 -and
                        [Math]::Abs($ring[1] - 0x8E) -le 12 -and
                        [Math]::Abs($ring[2] - 0xF8) -le 12)
            $script:negReached3 = $true
            if ($NegativeControl) {
                Assert (-not $fillHit) "NEGATIVE CONTROL: the monogram disc is NOT the pinned accent (rgb $($ring -join ','))"
            } else {
                Assert $fillHit "the monogram disc is filled with the pinned accent (rgb $($ring -join ','), want 61,142,248)"
            }
            # …and it carries a letter: pixels inside the disc that are NOT the
            # fill. `contrastForeground(#3D8EF8)` is black here, so the glyph is
            # as far from the fill as it gets.
            $glyph = Measure-DrawnPixels $shot3 ($avL + 6) ($avT + 6) ($avR - 6) ($avB - 6) 0x3D 0x8E 0xF8 20
            Assert ($glyph -ge 10) "the monogram draws its letter ($glyph non-fill pixels inside the disc)"

            Close-TestWindowPixels $shot3
            Send-TestControlKey -Control $chooser3 -Key Escape | Out-Null
            Start-Sleep -Milliseconds 300
        }
        Assert (-not ($g3.App.Process -and $g3.App.Process.HasExited)) 'app survived the signed-in chooser'
    }
} finally {
    if ($hadAccent) {
        Set-ItemProperty -Path $DWM_KEY -Name AccentColor -Value $origAccent -Type DWord
    } else {
        Remove-ItemProperty -Path $DWM_KEY -Name AccentColor -ErrorAction SilentlyContinue
    }
    Remove-TestDesktop
    Stop-DebugGhoztty
    Stop-Job $dirJob -ErrorAction SilentlyContinue
    Remove-Job $dirJob -Force -ErrorAction SilentlyContinue
    Remove-Item $hitFile, $errlog -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $acctDir, $acctDir2, $acctDir3 -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run by
    # now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    Assert ($launched.Count -gt 0) 'the run actually launched apps on the test desktop'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# A -NegativeControl run that never reached an inverted assertion proves
# nothing, so say so instead of exiting green. There are TWO since T311 (the
# detail pane following the selection, and the monogram's fill), so a
# -NegativeControl run is expected to fail exactly 2.
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion (detail pane)'
}
if ($NegativeControl -and -not $script:negReached3) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion (monogram)'
}

Write-Host ''
if ($script:skip -gt 0) { Write-Host "($($script:skip) section(s) SKIPPED)" }
if ($script:fail -eq 0) {
    Write-Host "MACHINE-CHOOSER ACCEPTANCE: ALL PASS ($script:pass assertions)"
    exit 0
} else {
    Write-Host "MACHINE-CHOOSER ACCEPTANCE: $($script:fail) FAILURE(S) ($script:pass passed)" -ForegroundColor Red
    exit 1
}
