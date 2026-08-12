# Machine-chooser SESSION RESUME acceptance (tracker T320).
#
# T318/T319 made the selected machine's sessions VISIBLE. This is the task that
# makes one of them openable: the keyboard sub-cursor steps into the roster
# (Right), walks it (Up/Down), and Return dismisses the chooser and opens a
# window whose pane ATTACHes to that session - Mac's `WindowTarget.resumeSession`
# (MachineChooserView.swift:20, :127-133, :167-170).
#
# What this drives, end to end, against a REAL local agent:
#
#   1. a session the app does NOT have open is resumable at all. The fixture
#      builds one the only way a user does: run panes under the agent, kill the
#      APP (not the agent), drop the layout manifest so nothing auto-restores,
#      and relaunch. The agent then holds live children with no viewer.
#   2. Right paints the cursor - the first card's fill picks up the accent wash
#      it did not have a moment earlier (the plain card is its own control).
#   3. Return resumes THAT row: the app logs the id it attached, the chooser
#      closes, and - the independent oracle - `ghoztty +sessions --json`, which
#      dials the agent directly and never goes through the app, flips that
#      session's `attached` from false to true.
#   4. a DEAD row cannot be resumed. Only ALIVE sessions attach; a relaunchable
#      tombstone is listed (its recorded argv can revive it via RELAUNCH, a
#      different verb) but Return on it must do nothing but say so.
#
# POSITIVE CONTROL for (4), mandatory: after the dead row refuses, the SAME
# chooser and the SAME keys resume a live row. Without it, "nothing happened"
# is equally consistent with the keys never arriving - which is how a confident,
# wrong negative gets recorded (the T240 lesson).
#
# T248: the repo's agent AND its app are killed at setup and the agent's state
# is dropped, so the fixture is built fresh instead of measuring the previous
# run's sessions.
# T267: the script sets its own window size rather than inheriting whatever the
# last GUI script left in window_placement-debug.
#
#   powershell -NoProfile -File test\win32\chooser-resume.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-t320'

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
    foreach ($name in $Names) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 600
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

# Dropping the layout manifest is what makes the orphan fixture: without it the
# relaunched app re-attaches the very sessions this test needs to be unattached,
# and every row would take the already-open shortcut instead of resuming.
function Remove-LayoutManifest {
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

# The rows the roster actually RENDERS, in agent order: the connectable ones
# (alive, or a relaunchable tombstone). The keyboard cursor's index space is
# this list - which is the property under test, so it is derived here from the
# agent's own reply rather than assumed.
function Get-RenderedSessions {
    return @(Get-Sessions | Where-Object { $_.alive -or $_.relaunchable })
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

Write-Host 'T320 chooser session resume'
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
Reset-AgentState
Remove-LayoutManifest
New-TestDesktop | Out-Null

$errlog1 = Join-Path $env:TEMP "ghoztty-t320-stderr1-$PID.log"
$errlog2 = Join-Path $env:TEMP "ghoztty-t320-stderr2-$PID.log"
$errlog3 = Join-Path $env:TEMP "ghoztty-t320-stderr3-$PID.log"
Remove-Item $errlog1, $errlog2, $errlog3 -ErrorAction SilentlyContinue

try {
    # --- Fixture: sessions the app does not have open ----------------------
    Write-Host ''
    Write-Host '1. an orphaned live session exists to resume'
    $g = Launch-Gui $errlog1 @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    & $Exe +split --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 2
    $seeded = @(Get-Sessions)
    Assert ($seeded.Count -ge 2) "the agent owns the app's panes (found $($seeded.Count))"

    # Kill the APP only. The agent keeps the children alive - that is the whole
    # point of session persistence - and with the manifest gone the relaunch
    # cannot re-attach them.
    Stop-RepoProcesses @('ghoztty')
    Remove-LayoutManifest
    $orphans = @(Get-Sessions | Where-Object { $_.alive })
    Assert ($orphans.Count -ge 2) "the sessions outlived the app ($($orphans.Count) alive)"

    $g = Launch-Gui $errlog2 @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died on relaunch'; exit 1 }
    Start-Sleep -Seconds 2

    $rendered = @(Get-RenderedSessions)
    Assert ($rendered.Count -ge 3) "the roster has the orphans plus the new pane ($($rendered.Count) rows)"
    # The row to resume is an ORPHAN: alive with no viewer. The relaunched app's
    # own pane is alive too and sits somewhere in the same list (the agent's
    # order is its store's, not creation order), so the row is chosen by what it
    # IS rather than by where it happens to be.
    $targetIdx = -1
    for ($i = 0; $i -lt $rendered.Count; $i++) {
        if ($rendered[$i].alive -and -not $rendered[$i].attached) { $targetIdx = $i; break }
    }
    Assert ($targetIdx -ge 0) "a live row with no viewer is rendered (index $targetIdx of $($rendered.Count))"
    if ($targetIdx -lt 0) { Write-Host 'SETUP FAIL: no orphaned live session'; exit 1 }
    $target = $rendered[$targetIdx]

    # --- The cursor, then the resume ---------------------------------------
    Write-Host ''
    Write-Host '2. Right paints the cursor, Return resumes the row it is on'
    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Assert ($filter -ne [IntPtr]::Zero) 'the chooser has its filter field'

    $line = Wait-LogLine $errlog2 'chooser roster: loaded (\d+) session' 8000
    Assert ($null -ne $line) 'the roster loaded before anything was navigated'

    $scale = (Get-TestWindowDpi -Window $chooser) / 96.0
    $geo = Get-TestChooserRosterGeometry -Scale $scale
    $client = Get-TestWindowRect -Window $chooser -Client

    $plain = $null
    $shot = Get-TestWindowPixels -Window $chooser
    try {
        $distinct = Get-TestDistinctColors -Shot $shot
        Assert ($distinct -gt 3) "the capture is a real frame, not a black mid-paint one ($distinct colors)"
        $plain = Get-TestPixel -Shot $shot -X ($client.Left + $geo.CardX) -Y ($client.Top + $geo.CardY)
    } finally { Close-TestWindowPixels -Shot $shot }

    Send-ChooserKey $chooser $filter 'Right' | Out-Null
    Start-Sleep -Milliseconds 600

    $cursored = $null
    $shot = Get-TestWindowPixels -Window $chooser
    try {
        $cursored = Get-TestPixel -Shot $shot -X ($client.Left + $geo.CardX) -Y ($client.Top + $geo.CardY)
    } finally { Close-TestWindowPixels -Shot $shot }

    $bLift = -999
    if ($plain -and $cursored) { $bLift = [int]$cursored.B - [int]$plain.B }
    # The cursor wash is the user's accent (a blue on this box's default) over
    # the card, so the blue channel is the one that must move. The plain card,
    # sampled one keystroke earlier at the same point, is the control.
    Assert ($bLift -gt 8) "the cursored card picks up the accent wash (B +$bLift)"

    # Walk to the orphan's row. Right entered at index 0; each Down is one row
    # in the RENDERED list, which is the property under test.
    for ($i = 0; $i -lt $targetIdx; $i++) { Send-ChooserKey $chooser $filter 'Down' | Out-Null }
    Start-Sleep -Milliseconds 400

    $before = @(Get-Sessions)
    Send-ChooserKey $chooser $filter 'Return' | Out-Null
    $attach = Wait-LogLine $errlog2 'resume session: attaching local session id=' 6000
    Assert ($null -ne $attach) 'Return on the cursored row resumes it'

    $resumedId = ''
    if ($attach -and $attach -match 'id=([0-9a-fA-F]+)') { $resumedId = $Matches[1] }
    Assert ($resumedId -eq $target.id) `
        "the resumed session is the row the cursor was on ($resumedId vs $($target.id))"

    Start-Sleep -Seconds 2
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'the chooser dismissed itself onto the resumed window'

    # The independent oracle: the agent, dialled directly, now reports a viewer
    # on that session. Nothing about this reading goes through the app.
    $after = @(Get-Sessions)
    $row = @($after | Where-Object { $_.id -eq $resumedId })
    Assert ($row.Count -eq 1 -and $row[0].attached) `
        'the agent reports the resumed session ATTACHED'
    $wasAttached = @($before | Where-Object { $_.id -eq $resumedId -and $_.attached }).Count
    Assert ($wasAttached -eq 0) 'and it was NOT attached a moment before (the resume is what bound it)'

    # --- A dead row cannot be resumed --------------------------------------
    Write-Host ''
    Write-Host '3. a relaunchable tombstone is listed but not resumable'
    # Killing the agent turns every live child into a tombstone; the respawned
    # agent rematerializes them from sessions.json as relaunchable rows.
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-LayoutManifest
    $g = Launch-Gui $errlog3 @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died on second relaunch'; exit 1 }
    Start-Sleep -Seconds 2

    $rows = @(Get-RenderedSessions)
    $deadIdx = -1
    $liveIdx = -1
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($deadIdx -lt 0 -and -not $rows[$i].alive) { $deadIdx = $i }
        if ($liveIdx -lt 0 -and $rows[$i].alive) { $liveIdx = $i }
    }
    Assert ($deadIdx -ge 0) "a tombstone row is rendered (index $deadIdx of $($rows.Count))"
    Assert ($liveIdx -ge 0) "a live row is rendered too (index $liveIdx)"
    if ($deadIdx -lt 0 -or $liveIdx -lt 0) { Write-Host 'SETUP FAIL: need one dead and one live row'; exit 1 }

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Wait-LogLine $errlog3 'chooser roster: loaded (\d+) session' 8000 | Out-Null

    # Walk to the dead row: Right enters at index 0, then Down per step.
    Send-ChooserKey $chooser $filter 'Right' | Out-Null
    for ($i = 0; $i -lt $deadIdx; $i++) { Send-ChooserKey $chooser $filter 'Down' | Out-Null }
    Start-Sleep -Milliseconds 400
    $attachesBefore = Count-LogLines $errlog3 'resume session: attaching'
    Send-ChooserKey $chooser $filter 'Return' | Out-Null
    Start-Sleep -Seconds 2

    $attachesAfter = Count-LogLines $errlog3 'resume session: attaching'
    Assert ($attachesAfter -eq $attachesBefore) 'Return on a tombstone attaches nothing'
    Assert (Test-TestWindowExists -Window $chooser) 'and the chooser stays open instead of dismissing onto nothing'

    # POSITIVE CONTROL: the same chooser, the same keys, a LIVE row. Without
    # this the two assertions above would pass just as well if no keystroke
    # ever reached the dialog.
    #
    # The only live session left after the agent restart is the app's OWN pane,
    # and a session already open here is FOCUSED rather than attached a second
    # time - the agent rebinds a session to its newest ATTACH, so resuming one
    # twice would take the pane away from the window that has it (a deliberate
    # divergence from Mac, T330). That focus is what this control reads.
    Write-Host ''
    Write-Host '4. positive control: the same keys DO act on a live row'
    $steps = $liveIdx - $deadIdx
    if ($steps -gt 0) {
        for ($i = 0; $i -lt $steps; $i++) { Send-ChooserKey $chooser $filter 'Down' | Out-Null }
    } else {
        for ($i = 0; $i -lt (-$steps); $i++) { Send-ChooserKey $chooser $filter 'Up' | Out-Null }
    }
    Start-Sleep -Milliseconds 400
    Send-ChooserKey $chooser $filter 'Return' | Out-Null
    $focused = Wait-LogLine $errlog3 'session already open, focusing its pane' 6000
    Assert ($null -ne $focused) 'Return on a live row that is open here focuses its pane'
    Start-Sleep -Seconds 1
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'and the chooser dismissed onto it'
} finally {
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
