# Machine-chooser ROSTER REFETCH acceptance (tracker T333).
#
# T319 gave the roster a refresh IN PLACE: re-pointing it at the machine it is
# already showing refetches without resetting anything else, so a re-selection
# does not flash the region back to Loading. T320 then put a keyboard cursor in
# that roster, which can be parked several rows down a list long enough to have
# scrolled. Adopting a landed fetch still ended with `scroll = 0` - harmless
# while the roster was read-only, and a visible regression the moment there was
# a cursor to scroll away from: the highlighted card jumped off screen until
# the next keystroke dragged it back.
#
# What this drives, end to end, against a REAL local agent:
#
#   1. a roster taller than its region (eight windows, one agent session each).
#   2. Right + Down to the LAST row, which forces the region to scroll: the
#      cursored card's accent wash appears at the BOTTOM of the region, where
#      `scrollToCursor` puts it and where a zero offset cannot leave it. The
#      same point sampled one keystroke earlier is the control.
#   3. a refetch of the SAME machine - a filter edit re-selects the same row,
#      which is the chooser's own `refresh_in_place` path - and the wash is
#      STILL there.
#
# The refetch is proved independently by the app's own "chooser roster: loaded"
# line, so (3) can never pass because nothing happened. Without that counter
# this whole script would be a screenshot of a dialog nobody touched.
#
# Why not a section in `chooser-resume.ps1`: that script's fixture builds an
# ORPHANED session by dropping the layout manifest, and launch-time restore has
# since learned to recover such a window from the AGENT's own layout store
# (T194), so it exits at SETUP FAIL before any section could run. Filed
# separately; this property needs no orphan.
#
#   powershell -NoProfile -File test\win32\chooser-roster-refetch.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = "-t333$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# Kill only what this repo built. The installed release (and ITS agent, which
# owns the user's real terminal) is never touched.
function Stop-RepoProcesses([string[]]$Names) {
    # T351: the ghoztty halves go through the one shared, path-exact kill
    # (lib\CleanSlate.ps1) - every private copy answered "does the agent go too"
    # alone. Anything else in $Names is this script's own litter, so it stays local.
    if ($Names -contains 'ghoztty') {
        [void](Stop-RepoGhoztty -Exe $Exe -AppOnly:(-not ($Names -contains 'ghoztty-agent')) -SettleMs 0)
    }
    foreach ($name in ($Names | Where-Object { $_ -notin @('ghoztty', 'ghoztty-agent') })) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 600
}

# A known-empty box: the agent's sessions AND its layout store, plus the app's
# manifest. `layouts.json` is only safe to delete with the agent DEAD - it owns
# the file and would rewrite it - which is why this runs after the kill.
function Reset-GhozttyState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json', 'layouts.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json') -ErrorAction SilentlyContinue
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

# The rows the roster actually RENDERS, in agent order: the sessions whose
# program is still running (T1364 - a tombstone is not a row). The cursor's
# index space is this list, so it is derived from the agent's own reply rather
# than assumed.
function Get-RenderedSessions {
    return @(Get-Sessions | Where-Object { $_.alive })
}

function Launch-Gui($errlog) {
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--window-width=100', '--window-height=30', '--session-persistence=true'
    ) -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

function Open-Chooser($g) {
    if (-not (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N)) { return [IntPtr]::Zero }
    return Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
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

function Count-LogLines($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

# Keys go to the filter EDIT, which is where focus sits when the chooser opens -
# the state a real user is in when they press Right.
function Send-ChooserKey($chooser, $filter, $key) {
    return Send-TestKeys -Window $chooser -Target $filter -Key $key
}

# One pixel of the chooser, in screen coordinates.
function Sample($chooser, $x, $y) {
    $shot = Get-TestWindowPixels -Window $chooser -Sync
    try { return Get-TestPixel -Shot $shot -X $x -Y $y } finally { Close-TestWindowPixels -Shot $shot }
}

Write-Host 'T333 chooser roster refetch keeps the cursor on screen'
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
Reset-GhozttyState
New-TestDesktop | Out-Null

$errlog = Join-Path $env:TEMP "ghoztty-t333-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

try {
    # --- A roster taller than its region -----------------------------------
    Write-Host ''
    Write-Host '1. a roster long enough to scroll'
    $g = Launch-Gui $errlog
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    # Each window's pane is one agent session. Windows rather than splits:
    # eight splits of a 100x30 window are not eight panes the app will grant.
    for ($i = 1; $i -le 8; $i++) {
        & $Exe +new-window --target=t333-$i 2>$null | Out-Null
    }
    Start-Sleep -Seconds 2
    $rows = @(Get-RenderedSessions)
    Assert ($rows.Count -ge 8) "the agent holds a roster worth scrolling ($($rows.Count) rows)"
    if ($rows.Count -lt 8) { Write-Host 'SETUP FAIL: roster too short to scroll'; exit 1 }

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Assert ($filter -ne [IntPtr]::Zero) 'the chooser has its filter field'
    $loaded = Wait-LogLine $errlog 'chooser roster: loaded (\d+) session' 8000
    Assert ($null -ne $loaded) 'the roster loaded before anything was navigated'

    $scale = (Get-TestWindowDpi -Window $chooser) / 96.0
    $geo = Get-TestChooserRosterGeometry -Scale $scale
    $client = Get-TestWindowRect -Window $chooser -Client
    # Inside the LAST card: one scale-step in from the region's left edge (clear
    # of every mark, as `CardX` is for the first card) and up from the region's
    # bottom by less than a card. `scrollToCursor` lands the cursored last row's
    # bottom exactly on the region's, so this point is in its fill - and is
    # background or a plain card at any other offset.
    $probeX = $client.Left + $geo.CardX
    $probeY = $client.Top + $geo.Bottom - (Get-TestChromeDip 12 $scale)

    $shot = Get-TestWindowPixels -Window $chooser -Sync
    try {
        $distinct = Get-TestDistinctColors -Shot $shot
        Assert ($distinct -gt 3) "the capture is a real frame, not a black mid-paint one ($distinct colors)"
        $plain = Get-TestPixel -Shot $shot -X $probeX -Y $probeY
    } finally { Close-TestWindowPixels -Shot $shot }

    # --- Park the cursor at the bottom -------------------------------------
    Write-Host ''
    Write-Host '2. the cursor walks to the last row and the region follows it'
    Send-ChooserKey $chooser $filter 'Right' | Out-Null
    for ($i = 1; $i -lt $rows.Count; $i++) { Send-ChooserKey $chooser $filter 'Down' | Out-Null }
    Start-Sleep -Milliseconds 800

    $parked = Sample $chooser $probeX $probeY
    $parkLift = -999
    if ($plain -and $parked) { $parkLift = [int]$parked.B - [int]$plain.B }
    # The cursor wash is the user's accent (a blue on this box's default) over
    # the card, so the blue channel is the one that must move.
    Assert ($parkLift -gt 8) "the cursored last card is scrolled into view (B +$parkLift)"

    # --- The refetch -------------------------------------------------------
    Write-Host ''
    Write-Host '3. a refetch of the SAME machine leaves it where it is'
    # A filter edit re-selects the same row, which is the chooser's own
    # `refresh_in_place`. "L" keeps the Local row matched, so the target never
    # moves and this is a refresh rather than a machine change.
    $loadsBefore = Count-LogLines $errlog 'chooser roster: loaded'
    Send-ChooserKey $chooser $filter 'L' | Out-Null
    $waited = 0
    while ($waited -lt 8000 -and (Count-LogLines $errlog 'chooser roster: loaded') -le $loadsBefore) {
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    $loadsAfter = Count-LogLines $errlog 'chooser roster: loaded'
    Assert ($loadsAfter -gt $loadsBefore) `
        "the same machine was refetched in place ($loadsBefore -> $loadsAfter loads)"
    Start-Sleep -Milliseconds 700

    $after = Sample $chooser $probeX $probeY
    $afterLift = -999
    if ($plain -and $after) { $afterLift = [int]$after.B - [int]$plain.B }
    Assert ($afterLift -gt 8) `
        "the cursored card is STILL painted in the region after the refetch (B +$afterLift)"
} finally {
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
