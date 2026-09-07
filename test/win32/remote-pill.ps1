# T367 acceptance: the remote connection pill in the caption band.
#
# A remote window's link can die with nothing on screen changing - until T367
# the only way to find out was to type into a pane and watch nothing happen.
# The pill is the affordance that says so, and the button that fixes it.
#
# What this asserts, and how:
#
#   1. CONNECTED shows a green dot. A real remote window is opened against a
#      loopback ghoztty-agent, the window is PrintWindow'd, and the pixel where
#      caption_layout + remote_pill say the dot lands is measured to be
#      distinctly green. Painted pixels from a live window - not a synthesized
#      answer.
#   2. A connected pill NAMES the machine and IS a button (T610). The label is
#      read from the app's own oracle line (a name in the caption face is a
#      handful of grey pixels no probe can read back), the capsule is measured
#      to be wider than the wordless dot-only pill it used to be, and
#      WM_NCHITTEST at the pill answers HTOBJECT. Mac's MachinePillCapsule is
#      clickable in exactly this state; before T610 this section asserted the
#      opposite, which was T367 stopping deliberately short.
#   2b. Clicking a CONNECTED pill opens the Activity Monitor on this window's
#      existing connection - a GhozttyActivityMonitor window appears, and the
#      app logs that it reused a connection rather than dialing its own.
#   3. DROPPED turns the pill red and MAKES it a button. The agent is killed;
#      the script polls until the capsule paints red and WM_NCHITTEST answers
#      HTOBJECT at the same point.
#   4. The button ACTS, and the window COMES BACK. The WM_NCLBUTTONDOWN/UP pair
#      Windows posts after its own hit test is sent on HTOBJECT; the app dials
#      IMMEDIATELY - a manual attempt, distinguishable in the log from an
#      automatic one because an automatic attempt waits out a backoff and a
#      manual one does not - and the pill goes GREEN again, which is the answer
#      the button exists to give.
#   5. A LOCAL window has no pill at all. Same strip of band, plain chrome.
#      A local window keeps its whole drag band, which is the other half of
#      section 2's trade: only a window that HAS a machine gives up that width.
#
# LIMITS, stated rather than glossed:
#   * Section 4 posts the messages the OS would post. It proves the handler is
#     right; it does not prove Windows routes a real pointer to it (T240).
#     Section 3's hit-test assertion is what proves the OS would ask.
#   * Section 4's recovery arm was suspended between T367 and T611, when a
#     manual reconnect whose remote session was gone - a restarted agent, a
#     rebooted box - still took the driver's `.terminal` arm and the pill
#     correctly stayed red. T611 made the click open a fresh shell per pane, so
#     the arm is back to the assertion this file was written with first. What
#     the recovered pane CONTAINS (the same split layout, live shells) is
#     `remote-reconnect-fresh.ps1`; here it is only the pill.
#
# NEGATIVE CONTROL: -NegativeControl inverts section 1 (asserts the connected
# pill is ABSENT) and MUST fail.
#
# Runs on the background test desktop; only ever touches ghoztty processes
# started by this script.
param(
    [string]$ExePath,
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Port = 47913,
    [switch]$NegativeControl
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-rempilltest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')

# T1127: the finally below kills the agent it started, and the agent's
# `--pty-host` holders survive that by design - they own the ConPTY and escape
# the job on purpose, so a per-pid kill never reaches them. Arm the
# build-scoped teardown so nothing from zig-out outlives the script.
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Ok([string]$msg) { $script:pass++; Write-Host "  PASS  $msg" }
function Bad([string]$msg) { $script:fail++; Write-Host "  FAIL  $msg" }
function Check([bool]$cond, [string]$msg) { if ($cond) { Ok $msg } else { Bad $msg } }

$HTOBJECT = 19
$WM_NCHITTEST = 0x0084; $WM_NCLBUTTONDOWN = 0x00A1; $WM_NCLBUTTONUP = 0x00A2

function PackPoint([int]$x, [int]$y) {
    return [IntPtr](([int64]($y -band 0xFFFF) -shl 16) -bor [int64]($x -band 0xFFFF))
}
function HitAt($h, [int]$sx, [int]$sy) {
    return [int](Invoke-TestMessage -Window $h -Message $WM_NCHITTEST -LParam (PackPoint $sx $sy))
}

# Distinctly green / red / amber: the channel that carries the meaning leads
# the other two by a clear margin. Deliberately not an exact RGB match - every
# one of these colors is contrast-floored against the band it lands on, so the
# literal value depends on the user's theme and is not a thing a test may pin.
function IsGreenish($c) { return ($null -ne $c) -and ($c.G - $c.R -gt 24) -and ($c.G - $c.B -gt 24) }
function IsReddish($c) { return ($null -ne $c) -and ($c.R - $c.G -gt 40) -and ($c.R - $c.B -gt 40) }

New-TestDesktop | Out-Null
$agent = $null
$tmp = Join-Path $env:TEMP "ghoztty-rempill-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$exitCode = 1
try {
    Write-Host "T367 remote connection pill acceptance"
    Write-Host "  exe:   $exe"
    Write-Host "  agent: $AgentExe"

    # A loopback agent to be remote TO. Its own lock path so it can never
    # fight a real agent's single-instance guard.
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
    $agent = Start-Process -FilePath $AgentExe -ArgumentList "--listen", "127.0.0.1:$Port", "--headless" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if ($agent.HasExited) { throw 'SETUP FAIL: loopback agent exited immediately' }

    $applog = Join-Path $tmp 'app.log'
    $proc = Start-OnTestDesktop -Exe $exe -StdErr $applog -Arguments @(
        '--config-default-files=false',
        # `false`, not `off`: the bool parser takes true/false only (T137).
        '--session-persistence=false',
        '--background=#000000',
        # Standalone caption band: no strip to share the row, so the pill's
        # vertical center is the caption's own button baseline and the
        # arithmetic below is the simplest true statement of it.
        '--window-show-tab-bar=never'
    )
    $local = Wait-TestWindow -ProcessId $proc.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($local -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no GhozttyWindow appeared' }
    Start-Sleep -Milliseconds 2000

    # Snapshot the window set, so the remote one is identified by BEING NEW
    # rather than by a title the app is free to change under us.
    $before = @(Get-TestWindows -ProcessId $proc.Pid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })

    cmd /c "`"$exe`" +new-remote-window --host=127.0.0.1 --port=$Port > `"$tmp\open.txt`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        throw "SETUP FAIL: +new-remote-window exit $LASTEXITCODE - $(Get-Content "$tmp\open.txt" -Raw)"
    }
    Start-Sleep -Seconds 3

    $remote = [IntPtr]::Zero
    foreach ($w in (Get-TestWindows -ProcessId $proc.Pid -Class 'GhozttyWindow')) {
        if ($before -contains $w.Hwnd) { continue }
        $remote = [IntPtr]$w.Hwnd
    }
    if ($remote -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no remote GhozttyWindow appeared' }

    Set-TestWindowSize -Window $remote -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 1200

    # --- where the pill is, from the DIP constants -------------------------
    # Restated here from the design system's numbers rather than read out of
    # the binary, which is what makes this an oracle: caption_layout puts the
    # pill one GROUP gap (pad_md) left of the "..." square, sharing its
    # vertical center, and remote_pill puts the mark one pad_x (8 DIP) in from
    # the capsule's LEADING edge with an 8 DIP diameter.
    #
    # The trailing edge is arithmetic; the leading edge is not, because the
    # capsule's width follows a GDI-measured label (T610 gave the connected
    # pill the machine's name, so this is true in every state now). It is found
    # instead of assumed, by walking WM_NCHITTEST left until the answer stops
    # being the pill - which is the same edge `caption_layout` computes
    # `drag_right` from, asked of the running window.
    $m = Get-TestChromeMetrics -Window $remote -StripVisible $false
    $scale = $m.Scale
    $px = { param($dip) [int][Math]::Round($dip * $scale) }
    $win = Get-TestWindowRect -Window $remote
    $cli = Get-TestWindowRect -Window $remote -Client
    $borderX = [int](($win.Width - $cli.Width) / 2)
    $pillRight = $m.CaptionOverflowLeft - $m.PadMd
    $pillCy = $m.CaptionBtnTop + [int]($m.BtnPaint / 2)
    # Dot center: pad_x (8) + half a dot (4) in from the capsule's right edge.
    # (filled in per measurement by PillLeft/DotX below)
    # Anywhere inside the capsule's trailing padding: fill color, whatever the
    # label happens to measure.
    $fillCx = $pillRight - (& $px 4.0)
    $sxFill = $win.Left + $borderX + $fillCx
    $sy = $win.Top + $pillCy
    Write-Host "  scale=$scale pillRight=$pillRight cy=$pillCy fillX=$fillCx"

    function PillPixel([int]$sx) {
        $shot = Get-TestWindowPixels -Window $remote -Sync
        try { return Get-TestPixel -Shot $shot -X $sx -Y $sy } finally { Close-TestWindowPixels $shot }
    }

    # The capsule's leading edge in SCREEN x: walk left from its trailing edge
    # while WM_NCHITTEST still answers "the pill". -1 when the pill is not a
    # button at all, which is a real answer and not a measurement failure.
    function PillLeft {
        $sxRight = $win.Left + $borderX + $pillRight
        if ((HitAt $remote ($sxRight - 2) $sy) -ne $HTOBJECT) { return -1 }
        for ($dx = 2; $dx -lt 400; $dx += 2) {
            if ((HitAt $remote ($sxRight - $dx) $sy) -ne $HTOBJECT) { return $sxRight - $dx + 2 }
        }
        return -1
    }

    # Screen x of the status dot's center: pad_x (8) + half a dot (4) in from
    # the capsule's leading edge.
    function DotX {
        $l = PillLeft
        if ($l -lt 0) { return -1 }
        return $l + (& $px 12.0)
    }

    # --- 1. connected: a green dot -----------------------------------------
    $sxDot = DotX
    Write-Host "  pill leading edge found at screen x=$(PillLeft), dot at $sxDot"
    $dot = if ($sxDot -ge 0) { PillPixel $sxDot } else { $null }
    if ($NegativeControl) {
        Check (-not (IsGreenish $dot)) "NEGATIVE CONTROL: no green dot on a connected remote window"
    } else {
        Check (IsGreenish $dot) "connected pill paints a green dot (rgb $($dot.R),$($dot.G),$($dot.B))"
    }

    # --- 2. a connected pill names the machine, and is a button (T610) ------
    # The label, from the app's own oracle line. `+new-remote-window --host`
    # makes a `.tcp` machine, whose display name is the host we dialed - the
    # same string the close confirmation and the tooltip speak.
    $pillLine = ''
    if (Test-Path $applog) {
        $pillLine = @(Get-Content $applog | Select-String -Pattern 'remote pill mode=connected' |
            Select-Object -Last 1 | ForEach-Object { $_.Line })
        if ($pillLine -is [array]) { $pillLine = $pillLine[0] }
    }
    Check ($pillLine -match 'label=127\.0\.0\.1') `
        "a connected pill NAMES the machine - $pillLine"

    # ...and the capsule really got wider for it: the wordless pill was
    # dot (8) + pad_x (8) * 2 = 24 DIP, so anything at that width is a pill
    # that measured no label at all.
    $wordless = & $px 24.0
    $pillW = -1
    if ($pillLine -match 'w=(\d+)') { $pillW = [int]$Matches[1] }
    Check ($pillW -gt $wordless) `
        "and the capsule grew for the name (w=$pillW px > wordless $wordless px)"

    # A button, where it used to be draggable titlebar. The trade is stated in
    # caption_layout.Pill: an interactive pill takes its own width out of the
    # drag band, and it sits at the band's trailing end where the drag region
    # already stopped for the "..." beside it.
    Check ((HitAt $remote $sxFill $sy) -eq $HTOBJECT) `
        "a connected pill answers HTOBJECT - clicking it is a click, not a drag"

    # --- 2b. clicking a connected pill opens the Activity Monitor -----------
    $panelsBefore = @(Get-TestWindows -ProcessId $proc.Pid -Class 'GhozttyActivityMonitor').Count
    Send-TestRawMessage -Window $remote -Message $WM_NCLBUTTONDOWN -WParam ([IntPtr]$HTOBJECT) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 150
    Send-TestRawMessage -Window $remote -Message $WM_NCLBUTTONUP -WParam ([IntPtr]$HTOBJECT) -LParam (PackPoint 0 0) | Out-Null

    $panel = [IntPtr]::Zero
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 500
        $now = @(Get-TestWindows -ProcessId $proc.Pid -Class 'GhozttyActivityMonitor')
        if ($now.Count -gt $panelsBefore) { $panel = [IntPtr]$now[$now.Count - 1].Hwnd; break }
    }
    Check ($panel -ne [IntPtr]::Zero) "clicking a connected pill opens the Activity Monitor"

    # On THIS window's connection, not a second dial of its own: the panel that
    # dials logs `dialing`, the one that borrows logs `reusing`. Mac's
    # presentReusing, and the reason the pill click is not just the palette
    # entry with extra steps.
    $reused = $false
    if (Test-Path $applog) {
        $reused = @(Get-Content $applog | Select-String -Pattern 'activity monitor: reusing').Count -gt 0
    }
    Check $reused "...on the window's EXISTING connection, not a second dial"

    if ($panel -ne [IntPtr]::Zero) { Send-TestWindowClose -Window $panel | Out-Null; Start-Sleep -Milliseconds 800 }

    # --- 3. dropped: red, and now a button ----------------------------------
    Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
    $agent = $null
    $redAt = -1
    $hitAt = -1
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 1000
        if ($redAt -lt 0 -and (IsReddish (PillPixel $sxFill))) { $redAt = $i }
        if ($hitAt -lt 0 -and (HitAt $remote $sxFill $sy) -eq $HTOBJECT) { $hitAt = $i }
        if ($redAt -ge 0 -and $hitAt -ge 0) { break }
    }
    Check ($redAt -ge 0) "a dropped link turns the pill red (after ${redAt}s)"
    Check ($hitAt -ge 0) "and makes it a button - WM_NCHITTEST answers HTOBJECT (after ${hitAt}s)"

    # ...and it STILL names the machine (D93 / T1433). Until 2026-09-07 the
    # status REPLACED the name here, which made three dropping remote windows
    # identical in the titlebar - the one question the pill exists to answer,
    # unanswerable exactly when it matters. The oracle line is used because the
    # label is a handful of grey pixels a probe cannot read back.
    $degradedLine = ''
    if (Test-Path $applog) {
        $degradedLine = @(Get-Content $applog |
            Select-String -Pattern 'remote pill mode=(reconnecting|disconnected)' |
            Select-Object -Last 1 | ForEach-Object { $_.Line })
        if ($degradedLine -is [array]) { $degradedLine = $degradedLine[0] }
    }
    Check ($degradedLine -match 'label=127\.0\.0\.1 ') `
        "a degraded pill STILL names the machine - $degradedLine"
    Check ($degradedLine -match 'label=127\.0\.0\.1 .*Reconnect') `
        "and the status follows the name rather than replacing it"

    # --- 4. the button acts, and the window comes back ----------------------
    # Two arms, and the second is the one that matters to a user: the click has
    # to DIAL, and it has to leave the window working. The agent is restarted
    # before the click, so its sessions are gone - the ordinary case (T611), and
    # the one the recovery arm was suspended over until the driver learned to
    # answer it with a fresh shell per pane.
    #
    # The attempt is unambiguous in the log: an automatic ladder attempt waits
    # out a backoff (`in 1000ms`), a MANUAL one dials immediately (`in 0ms`), so
    # a 0ms line that was not there before the click is the click. The recovery
    # is measured in PIXELS at the same point section 1 measured green.
    $before4 = 0
    if (Test-Path $applog) {
        $before4 = @(Get-Content $applog | Select-String -Pattern 'attempt 1/5 in 0ms').Count
    }

    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent2.lock'
    $agent = Start-Process -FilePath $AgentExe -ArgumentList "--listen", "127.0.0.1:$Port", "--headless" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Send-TestRawMessage -Window $remote -Message $WM_NCLBUTTONDOWN -WParam ([IntPtr]$HTOBJECT) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 150
    Send-TestRawMessage -Window $remote -Message $WM_NCLBUTTONUP -WParam ([IntPtr]$HTOBJECT) -LParam (PackPoint 0 0) | Out-Null

    $firedAt = -1
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 1000
        $now = @(Get-Content $applog -ErrorAction SilentlyContinue | Select-String -Pattern 'attempt 1/5 in 0ms').Count
        if ($now -gt $before4) { $firedAt = $i; break }
    }
    Check ($firedAt -ge 0) "clicking Reconnect dials immediately - a manual attempt, no backoff (after ${firedAt}s)"

    # ...and the window is LIVE again. The machine is back but its sessions are
    # not, so this is the fresh-shell swap - the pill going quiet-green is the
    # window saying it has a working transport under it once more.
    # Re-found, not reused: the capsule was "Reconnect" wide a moment ago and
    # is name-wide again now, so the leading edge has moved.
    $greenAt = -1
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 1000
        $dx2 = DotX
        if ($dx2 -ge 0 -and (IsGreenish (PillPixel $dx2))) { $greenAt = $i; break }
    }
    Check ($greenAt -ge 0) "and the window comes BACK - the pill is green again (after ${greenAt}s)"

    if (($firedAt -lt 0 -or $greenAt -lt 0) -and (Test-Path $applog)) {
        Write-Host "  -- app log, remote reconnect lines --"
        Get-Content $applog | Select-String -Pattern 'remote reconnect' | Select-Object -Last 12 | ForEach-Object { "    $($_.Line)" }
    }

    # --- 5. a local window has no pill --------------------------------------
    Set-TestWindowSize -Window $local -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 800
    $lwin = Get-TestWindowRect -Window $local
    $lcli = Get-TestWindowRect -Window $local -Client
    $lborder = [int](($lwin.Width - $lcli.Width) / 2)
    $lshot = Get-TestWindowPixels -Window $local -Sync
    try {
        $bare = Get-TestPixel -Shot $lshot -X ($lwin.Left + $lborder + $pillRight - (& $px 40.0)) -Y ($lwin.Top + 2)
        $clean = $true
        # The whole strip a pill would occupy is one flat chrome color.
        for ($dx = 4; $dx -le 120; $dx += 4) {
            $c = Get-TestPixel -Shot $lshot -X ($lwin.Left + $lborder + $pillRight - (& $px ([double]$dx))) -Y ($lwin.Top + $pillCy)
            if ($null -eq $c) { continue }
            $d = [math]::Abs($c.R - $bare.R) + [math]::Abs($c.G - $bare.G) + [math]::Abs($c.B - $bare.B)
            if ($d -gt 24) { $clean = $false; break }
        }
        Check $clean "a LOCAL window paints no pill - the band left of the '...' is plain chrome"
    } finally { Close-TestWindowPixels $lshot }

    Write-Host ""
    if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) checks)"; $exitCode = 0 }
    else { Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)"; $exitCode = 1 }

    # --- stamp (T783, row added by T610) ----------------------------------
    # A green run RECORDS the content of the pill's sources and this script, so
    # scripts\guard-due.ps1 can answer "has anything run this harness against
    # the code as it now stands?". Nothing tied an edit to `remote_pill.zig` or
    # to the caption band's click routing to this script before T610, which is
    # the gap that mattered the moment T610 INVERTED one of the assertions here
    # (a connected pill answers HTOBJECT where it used to answer HTCAPTION). A
    # red run leaves the stamp alone on purpose, and a -NegativeControl run
    # never stamps.
    if ($script:fail -eq 0 -and -not $NegativeControl) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard remote-pill -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
    }
} catch {
    Write-Host "  FAIL  $($_.Exception.Message)"
    Write-Host "1 FAILURE(S)"
    $exitCode = 1
} finally {
    if ($null -ne $agent) { Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop | Out-Null
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
exit $exitCode
