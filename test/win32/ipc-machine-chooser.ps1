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

$script:pass = 0
$script:fail = 0
$script:skip = 0
$script:negReached = $false
# Signed-in geometry, captured in run 1 and compared against the signed-out
# run's (T172 wrapping footer).
$script:chooserH1 = 0
$script:hintH1 = 0
$script:hintLineH = 0
$script:listH1 = 0
$script:rowH1 = 0
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

# The nth (0-based) descendant of $parent with class $cls, in z-order.
function Get-NthChild([IntPtr]$parent, [string]$cls, [int]$nth) {
    $all = @(Get-TestChildWindows -Window $parent -Class $cls)
    if ($all.Count -le $nth) { return [IntPtr]::Zero }
    return [IntPtr]$all[$nth].Hwnd
}

# The $cls child sitting LOWEST in the dialog (largest top edge). The chooser
# has two STATICs - the account status at the top and the footer hint at the
# bottom - and this picks the hint without depending on creation order.
function Get-LowestChild([IntPtr]$parent, [string]$cls) {
    $best = [IntPtr]::Zero
    $bestTop = [int]::MinValue
    foreach ($c in Get-TestChildWindows -Window $parent -Class $cls) {
        if ($c.Top -gt $bestTop) { $bestTop = $c.Top; $best = [IntPtr]$c.Hwnd }
    }
    return $best
}

# {Text, Left, Top, Right, Bottom} for every $cls child, so a test can find a
# control by its LABEL instead of by creation order. Text via WM_GETTEXT, which
# unlike GetWindowTextW is not a stale cross-process cache.
function Get-Controls([IntPtr]$parent, [string]$cls) {
    return @(Get-TestChildWindows -Window $parent -Class $cls | ForEach-Object {
        [pscustomobject]@{
            Text   = (Get-TestControlText -Control ([IntPtr]$_.Hwnd))
            Left   = $_.Left; Top = $_.Top; Right = $_.Right; Bottom = $_.Bottom
        }
    })
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

# A DIP measurement in the chooser's physical pixels.
function Dip($scale, $v) { return [int][Math]::Round($v * $scale) }

# --- capture -----------------------------------------------------------------
# PrintWindow(PW_RENDERFULLCONTENT) - CopyFromScreen is dead off the input
# desktop. Retried until the capture holds real content: a window captured
# mid-paint comes back solid black, and black would satisfy every
# drawn-pixel/tint probe below while proving nothing (T216).
function Get-Shot([IntPtr]$h) {
    $shot = $null
    for ($t = 0; $t -lt 15; $t++) {
        if ($shot) { Close-TestWindowPixels $shot }
        Start-Sleep -Milliseconds 200
        $shot = Get-TestWindowPixels -Window $h
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

function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
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
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
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

    $list = Get-NthChild $chooser 'ListBox' 0
    $edit = Get-NthChild $chooser 'Edit' 0
    Assert ($list -ne [IntPtr]::Zero) 'chooser has a machine list'

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

        # Pixel oracle: the selected row is an INSET rounded accent pill. Probe
        # the gutter beside it (must stay list background) and the pill itself
        # (must be accent-tinted), then an unselected row at the same x as a
        # negative control. This is exactly what the T140 screenshot got wrong:
        # a full-width system-blue selection bar.
        $lr = Get-Rect $list
        $yRow0 = $lr.Top + 1 + [int]($rowH / 2)
        $yRow1 = $lr.Top + 1 + $rowH + [int]($rowH / 2)
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
        Assert ($pillTint -ge 25) "selected row is accent-tinted (b-r = $pillTint at the pill)"
        Assert ($gutterTint -le 10) "selection is inset, not full-width (b-r = $gutterTint in the gutter)"
        Assert ($unselTint -le 10) "unselected row stays untinted (b-r = $unselTint)"
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
    $scale = Get-ChooserScale $chooser
    $script:hintLineH = Dip $scale 16
    $hint1 = Get-LowestChild $chooser 'Static'
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
    Assert ([Math]::Abs($cr.Height - (Dip $scale 540)) -le 2) "chooser client is Mac's 540 tall at this DPI (got $($cr.Height), want $(Dip $scale 540))"

    $orgX = $cr.Left
    $orgY = $cr.Top
    $masterRight = Dip $scale 260
    $footerY = Dip $scale 480

    # The column is a wash: brighter than the dialog surface beside it, at the
    # same height, below the last row.
    $yBody = $orgY + (Dip $scale 300)
    $washPx = Get-ShotPixel $shot ($orgX + (Dip $scale 200)) $yBody
    $panePx = Get-ShotPixel $shot ($orgX + (Dip $scale 600)) $yBody
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
    $buttons = @(Get-Controls $chooser 'Button')
    $primary = $buttons | Where-Object { $_.Text -eq 'New Window' }
    $cancel = $buttons | Where-Object { $_.Text -eq 'Cancel' }
    Assert ($null -ne $primary) "the primary action is labeled 'New Window' (saw: $(($buttons | ForEach-Object { $_.Text }) -join ', '))"
    Assert ($null -ne $cancel) 'the footer has a Cancel button'
    if ($primary) {
        Assert ((($primary.Left - $orgX) -gt $masterRight)) "the primary action is in the detail pane (left=$($primary.Left - $orgX), column ends at $masterRight)"
        Assert ((($primary.Bottom - $orgY) -lt $footerY)) 'the primary action is above the footer, not in it'
    }
    $inFooter = @($buttons | Where-Object { ($_.Top - $orgY) -ge $footerY })
    Assert ($inFooter.Count -eq 1 -and $inFooter[0].Text -eq 'Cancel') "Cancel is alone in the footer (found: $(($inFooter | ForEach-Object { $_.Text }) -join ', '))"

    # The detail pane names the selected machine, and it FOLLOWS the selection:
    # arrowing onto the relay device must repaint it.
    $dx0 = $orgX + (Dip $scale 300)
    $dx1 = $orgX + (Dip $scale 620)
    $dy0 = $orgY + (Dip $scale 60)
    $dy1 = $orgY + (Dip $scale 110)
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
            $hint2 = Get-LowestChild $chooser2 'Static'
            $hintH2 = Get-Height $hint2
            $chooserH2 = Get-Height $chooser2
            $list2 = Get-NthChild $chooser2 'ListBox' 0
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
    Remove-Item -Recurse -Force $acctDir, $acctDir2 -ErrorAction SilentlyContinue
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

# A -NegativeControl run that never reached the inverted assertion proves
# nothing, so say so instead of exiting green.
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
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
