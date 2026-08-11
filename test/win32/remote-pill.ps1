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
#   2. A connected pill is NOT a button. WM_NCHITTEST at the pill answers
#      HTCAPTION, i.e. it is still titlebar you can pick the window up by. A
#      quiet status chip that ate a patch of the drag band would be a
#      regression you only notice when your window will not move.
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
$env:GHOZTTY_PIPE_SUFFIX = '-rempilltest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Ok([string]$msg) { $script:pass++; Write-Host "  PASS  $msg" }
function Bad([string]$msg) { $script:fail++; Write-Host "  FAIL  $msg" }
function Check([bool]$cond, [string]$msg) { if ($cond) { Ok $msg } else { Bad $msg } }

$HTCAPTION = 2; $HTOBJECT = 19
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
    # vertical center, and remote_pill puts the connected dot one pad_x
    # (8 DIP) in from the capsule's trailing edge with an 8 DIP diameter.
    $m = Get-TestChromeMetrics -Window $remote -StripVisible $false
    $scale = $m.Scale
    $px = { param($dip) [int][Math]::Round($dip * $scale) }
    $win = Get-TestWindowRect -Window $remote
    $cli = Get-TestWindowRect -Window $remote -Client
    $borderX = [int](($win.Width - $cli.Width) / 2)
    $pillRight = $m.CaptionOverflowLeft - $m.PadMd
    $pillCy = $m.CaptionBtnTop + [int]($m.BtnPaint / 2)
    # Dot center: pad_x (8) + half a dot (4) in from the capsule's right edge.
    $dotCx = $pillRight - (& $px 12.0)
    # Anywhere inside the capsule's trailing padding: fill color, whatever the
    # label happens to measure.
    $fillCx = $pillRight - (& $px 4.0)
    $sxDot = $win.Left + $borderX + $dotCx
    $sxFill = $win.Left + $borderX + $fillCx
    $sy = $win.Top + $pillCy
    Write-Host "  scale=$scale pillRight=$pillRight cy=$pillCy dotX=$dotCx fillX=$fillCx"

    function PillPixel([int]$sx) {
        $shot = Get-TestWindowPixels -Window $remote
        try { return Get-TestPixel -Shot $shot -X $sx -Y $sy } finally { Close-TestWindowPixels $shot }
    }

    # --- 1. connected: a green dot -----------------------------------------
    $dot = PillPixel $sxDot
    if ($NegativeControl) {
        Check (-not (IsGreenish $dot)) "NEGATIVE CONTROL: no green dot on a connected remote window"
    } else {
        Check (IsGreenish $dot) "connected pill paints a green dot (rgb $($dot.R),$($dot.G),$($dot.B))"
    }

    # --- 2. a connected pill is still draggable titlebar --------------------
    Check ((HitAt $remote $sxFill $sy) -eq $HTCAPTION) `
        "a quiet pill answers HTCAPTION - it does not eat a patch of the drag band"

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
    $greenAt = -1
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 1000
        if (IsGreenish (PillPixel $sxDot)) { $greenAt = $i; break }
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
    $lshot = Get-TestWindowPixels -Window $local
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
