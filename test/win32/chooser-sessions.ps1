# Machine-chooser SESSION ROSTER acceptance (tracker T318).
#
# The Ctrl+Shift+N chooser's detail pane now lists the selected machine's live
# agent sessions - a liveness dot, the label ladder, activity/status badges,
# cwd + command sublines and a Kill button (Mac's `detailSessions`,
# MachineChooserView.swift:544/:608-730). This script drives that end to end
# against a REAL local agent with REAL sessions:
#
#   1. the roster loads OFF the GUI thread and lands: the app logs
#      "chooser roster: loaded N session(s)", and N equals what
#      `ghoztty +sessions --json` reports from the same agent;
#   2. cards are actually PAINTED - the first card's fill is measurably
#      lighter than the dialog background it sits on;
#   3. Kill ends the session: clicking the first card's Kill button opens the
#      destructive confirmation, approving it logs the close, the agent
#      confirms it, and `+sessions` stops listing that id.
#
# WHY A LOG LINE IS THE ORACLE. The roster is owner-drawn on the dialog's own
# surface - there are no HWNDs to read back with WM_GETTEXT, so "what did it
# load" cannot be measured the way a control's caption can. The count is said
# out loud by the app (SessionRoster.adopt) and cross-checked against an
# INDEPENDENT source (`+sessions`, which dials the agent directly and does not
# go through the app at all). The pixels answer the separate question of
# whether anything was drawn.
#
# NEGATIVE CONTROL (run 2, mandatory - a pixel probe with no negative control
# is a probe of the background): with the agent killed the roster resolves to
# `failed`, and the same probe point must come back AT the dialog background.
# Without this, "the card is lighter than the background" would pass against a
# chooser that painted no roster at all as long as some other chrome happened
# to sit there.
#
# T248: the repo's agent AND its app are killed at setup, so the fixture is
# built fresh every run instead of measuring the previous run's sessions.
# T267: the script sets its own window size rather than inheriting whatever
# the last GUI script left in window_placement-debug.
#
#   powershell -NoProfile -File test\win32\chooser-sessions.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$agentExe = Join-Path (Split-Path $Exe -Parent) 'ghoztty-agent.exe'

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-t318'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# Kill only what this repo built. The installed release (and ITS agent, which
# owns the user's real terminal) is never touched.
function Stop-RepoProcesses {
    foreach ($name in @('ghoztty', 'ghoztty-agent')) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 500
}

# The DEBUG agent's own state dir (never the installed release's): dropping
# sessions.json between runs is what makes the fixture deterministic. Without
# it the agent rematerializes every previous run's sessions as relaunchable
# tombstones - which are legitimately connectable, so they show up as roster
# rows and the count under test becomes "however many times this script has
# ever run".
function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

# `ghoztty +verb > file` writes zero bytes from PowerShell (T245) - capture
# through a pipe instead.
function Get-Sessions {
    $out = (& $Exe +sessions --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return @() }
    try { $j = $out | ConvertFrom-Json } catch { return @() }
    if ($null -eq $j) { return @() }
    # PS5.1 unrolls a one-element array on return, so wrap before counting.
    return @($j)
}

# Round HALF AWAY FROM ZERO, the way Zig's `@round` does. [math]::Round() is
# BANKER'S rounding and the two disagree at 112.5% - the latent DPI bug T257
# found in four copies of the tab-strip datum.
function Px([double]$dip, [double]$scale) { return [int][math]::Floor($dip * $scale + 0.5) }

# The chooser's session region and the first card's Kill button, derived the
# way `chooser_layout.layout` / `chooser_sessions.rowLayout` derive them. Every
# number here is a pure DIP constant - nothing on this path comes from text
# metrics, which is the only reason it can be re-derived at all (T256).
function Get-RosterGeometry([double]$s) {
    $margin = Px 16 $s
    $gap = Px 8 $s
    $controlH = Px 28 $s
    $clientW = Px 840 $s
    $clientH = Px 540 $s

    $avatarD = Px 32 $s
    $emailH = (Px 12 $s) + (Px 4 $s)
    $linkH = (Px 14 $s) + (Px 4 $s)
    $stackGap = Px 2 $s
    $accountH = [math]::Max([math]::Max($avatarD, $emailH + $stackGap + $linkH), $controlH)
    $headerDividerY = $gap + $accountH + $gap

    $cancelTop = $clientH - $margin - $controlH
    $footerDividerY = $cancelTop - $margin
    $bodyTop = $headerDividerY + 1
    $bodyBottom = $footerDividerY

    $masterW = Px 260 $s
    $detailLeft = $masterW + 1
    $glyphW = Px 32 $s
    $titleH = (Px 20 $s) + (Px 4 $s)
    $subtitleH = (Px 12 $s) + (Px 4 $s)
    $glyphBottom = $bodyTop + $margin + $glyphW
    $subBottom = $bodyTop + $margin + $titleH + (Px 2 $s) + $subtitleH
    $identityBottom = [math]::Max($glyphBottom, $subBottom)
    $actionTop = $identityBottom + (Px 12 $s)

    $left = $detailLeft + $margin
    $right = $clientW - $margin
    $top = $actionTop + $controlH + (Px 12 $s)
    $bottom = $bodyBottom - $margin

    # First card: padded on all sides, its Kill button a 28 DIP painted square
    # against the trailing padding, centred on the title's line box.
    $padX = Px 12 $s
    $padY = Px 8 $s
    $cardTitleH = (Px 14 $s) + (Px 4 $s)
    $killW = Px 28 $s
    $killX = $right - $padX - [int]([math]::Floor($killW / 2))
    $killY = $top + $padY + [int]([math]::Floor($cardTitleH / 2))

    return [pscustomobject]@{
        Left = $left; Top = $top; Right = $right; Bottom = $bottom
        KillX = $killX; KillY = $killY
        # A point INSIDE the first card's fill and clear of every mark: one
        # scale-step in from the card's left edge, on the title's line.
        CardX = $left + (Px 4 $s); CardY = $top + $padY + [int]([math]::Floor($cardTitleH / 2))
    }
}

function Launch-Gui($errlog, [string[]]$extra) {
    $args = @('--window-width=100', '--window-height=30') + $extra
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $args -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

# Wait for the Nth occurrence of a pattern. A refetch logs the SAME line the
# first fetch did, so "the line is present" proves nothing about the second one
# - the count is the only thing that distinguishes them.
function Wait-LogCount($path, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $path) {
            $m = @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue)
            if ($m.Count -ge $want) { return $m[$want - 1].Line }
        }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $null
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

Write-Host 'T318 chooser session roster'
Stop-RepoProcesses
Reset-AgentState
New-TestDesktop | Out-Null

$errlog = Join-Path $env:TEMP "ghoztty-t318-stderr-$PID.log"
$errlog2 = Join-Path $env:TEMP "ghoztty-t318-stderr2-$PID.log"
Remove-Item $errlog, $errlog2 -ErrorAction SilentlyContinue

try {
    # --- Run 1: a real agent with real sessions ----------------------------
    Write-Host ''
    Write-Host '1. roster loads from the local agent'
    $g = Launch-Gui $errlog @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    # A second pane, so the roster has more than one row to lay out.
    & $Exe +split --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 2

    $before = @(Get-Sessions)
    Assert ($before.Count -ge 1) "the agent has sessions to list (found $($before.Count))"
    if ($before.Count -lt 1) { Write-Host 'SETUP FAIL: no agent sessions'; exit 1 }

    $chooser = [IntPtr]::Zero
    if (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N) {
        $chooser = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    }
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }

    $line = Wait-LogLine $errlog 'chooser roster: loaded (\d+) session' 6000
    Assert ($null -ne $line) 'the roster fetch landed on the GUI thread'
    $loaded = -1
    if ($line -match 'loaded (\d+) session') { $loaded = [int]$Matches[1] }
    Assert ($loaded -eq $before.Count) `
        "the roster count matches the agent's own ($loaded vs $($before.Count))"

    # --- Cards are painted ------------------------------------------------
    Write-Host ''
    Write-Host '2. the cards are painted'
    $scale = (Get-TestWindowDpi -Window $chooser) / 96.0
    $geo = Get-RosterGeometry $scale
    $rect = Get-TestWindowRect -Window $chooser
    # Client origin: the dialog is WS_CAPTION, so the client top is below the
    # frame. Capture and address in SCREEN coordinates via the capture's own
    # origin plus the client offset the layout is expressed in.
    $shot = Get-TestWindowPixels -Window $chooser
    try {
        $distinct = Get-TestDistinctColors -Shot $shot
        Assert ($distinct -gt 3) "the capture is a real frame, not a black mid-paint one ($distinct colors)"

        $client = Get-TestWindowRect -Window $chooser -Client
        $cardPx = Get-TestPixel -Shot $shot -X ($client.Left + $geo.CardX) -Y ($client.Top + $geo.CardY)
        $bgPx = Get-TestPixel -Shot $shot -X ($client.Left + $geo.Left) -Y ($client.Top + $geo.Bottom - 2)
        $script:cardLum = if ($cardPx) { [int]$cardPx.R } else { -1 }
        $script:bgLum = if ($bgPx) { [int]$bgPx.R } else { -1 }
        Assert ($script:cardLum -gt $script:bgLum) `
            "the first card's fill is lighter than the pane behind it ($($script:cardLum) vs $($script:bgLum))"

        # The `open` badge: every session in this fixture IS open in one of the
        # app's own panes, so each card must carry the GREEN badge and not the
        # neutral `attached` one. Scanned rather than measured - a badge sits
        # after the label, whose width comes from text metrics and therefore
        # cannot be re-derived here (T256). Any strongly green pixel on the
        # first card's title line is the badge; run 2 (no cards at all) is the
        # negative control for it.
        $green = 0
        for ($x = $geo.Left; $x -lt $geo.Right; $x += 2) {
            $p = Get-TestPixel -Shot $shot -X ($client.Left + $x) -Y ($client.Top + $geo.CardY)
            if ($p -and $p.G -gt ($p.R + 20) -and $p.G -gt ($p.B + 20)) { $green++ }
        }
        $script:greenRun1 = $green
        Assert ($green -gt 0) "the open badge is drawn on a session open in our own pane ($green px)"
    } finally { Close-TestWindowPixels -Shot $shot }

    # --- Kill --------------------------------------------------------------
    Write-Host ''
    Write-Host '3. Kill ends the session'
    # Send-TestMouse takes SCREEN coordinates (it SetCursorPos'es them and then
    # ScreenToClient's for the posted lparam), so the client-space geometry is
    # offset by the client origin here rather than passed raw.
    $cr = Get-TestWindowRect -Window $chooser -Client
    Send-TestMouse -Window $chooser -X ($cr.Left + $geo.KillX) -Y ($cr.Top + $geo.KillY) `
        -Button left -Action click | Out-Null
    $confirm = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 3000
    Assert ($confirm -ne [IntPtr]::Zero) "the Kill button opens a confirmation"

    if ($confirm -ne [IntPtr]::Zero) {
        # Tab then Enter: the dialog is destructive, so its DEFAULT button is
        # Cancel and a bare Enter must not approve it (T50 parity).
        Send-TestControlKey -Control $confirm -Key Tab | Out-Null
        Start-Sleep -Milliseconds 200
        Send-TestControlKey -Control $confirm -Key Enter | Out-Null

        $killLine = Wait-LogLine $errlog 'chooser roster: ending session id=' 4000
        Assert ($null -ne $killLine) 'approving the confirmation ends the session'
        $killedId = ''
        if ($killLine -match 'id=([0-9a-f]+)') { $killedId = $Matches[1] }

        # The oracle is the REFETCH, not the close's own reply. Measured on box
        # (T323): closing a session with a live child makes the agent terminate
        # + free it BEFORE it sends CLOSE_SESSION_RESULT, which can take longer
        # than the 5s RPC budget - so `confirmed=true` is not reliably
        # observable even when the close plainly worked. What IS reliable is
        # that the session is gone afterwards, from two independent sources.
        $reload = Wait-LogCount $errlog 'chooser roster: loaded \d+ session' 2 10000
        Assert ($null -ne $reload) 'the roster refetched itself after the kill'
        $reloaded = -1
        if ($reload -match 'loaded (\d+) session') { $reloaded = [int]$Matches[1] }
        Assert ($reloaded -eq ($before.Count - 1)) `
            "the refetched roster is one shorter ($reloaded vs $($before.Count - 1))"

        Start-Sleep -Seconds 1
        # @() at the CALL site: a PS5.1 function returning a one-element array
        # unrolls it, and a scalar's .Count is $null - which compares LESS THAN
        # anything and would pass this assertion for free.
        $after = @(Get-Sessions)
        Assert ($after.Count -lt $before.Count) `
            "the agent stopped listing it ($($before.Count) -> $($after.Count))"
        if ($killedId -ne '') {
            $stillThere = @($after | Where-Object { $_.id -eq $killedId })
            Assert ($stillThere.Count -eq 0) 'the killed id specifically is gone'
        }
    }

    # --- Run 2: the negative control --------------------------------------
    Write-Host ''
    Write-Host '4. negative control: no agent, no cards'
    Stop-RepoProcesses
    Reset-AgentState
    $g2 = Launch-Gui $errlog2 @('--session-persistence=false')
    if (-not $g2) { Write-Host 'SETUP FAIL: GUI died at launch (run 2)'; exit 1 }
    $chooser2 = [IntPtr]::Zero
    if (Send-TestKeys -Window $g2.Top -Target $g2.Surface -Modifiers ctrl, shift -Key N) {
        $chooser2 = Wait-TestWindow -ProcessId $g2.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    }
    Assert ($chooser2 -ne [IntPtr]::Zero) 'the chooser opens with no agent running'
    if ($chooser2 -ne [IntPtr]::Zero) {
        Start-Sleep -Seconds 3
        $shot2 = Get-TestWindowPixels -Window $chooser2
        try {
            $client2 = Get-TestWindowRect -Window $chooser2 -Client
            $px2 = Get-TestPixel -Shot $shot2 -X ($client2.Left + $geo.CardX) -Y ($client2.Top + $geo.CardY)
            $lum2 = if ($px2) { [int]$px2.R } else { -1 }
            Assert ($lum2 -lt $script:cardLum) `
                "no card is drawn where run 1 had one ($lum2 vs $($script:cardLum))"
            $green2 = 0
            for ($x = $geo.Left; $x -lt $geo.Right; $x += 2) {
                $p = Get-TestPixel -Shot $shot2 -X ($client2.Left + $x) -Y ($client2.Top + $geo.CardY)
                if ($p -and $p.G -gt ($p.R + 20) -and $p.G -gt ($p.B + 20)) { $green2++ }
            }
            Assert ($green2 -eq 0) `
                "and no badge either, so the green scan discriminates ($green2 vs $($script:greenRun1))"
        } finally { Close-TestWindowPixels -Shot $shot2 }
    }
} finally {
    Stop-RepoProcesses
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" -ForegroundColor Green; exit 0 }
Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red
exit 1
