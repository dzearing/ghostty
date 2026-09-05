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
#      runs panes under the agent, kills the APP (not the agent), and relaunches
#      with GHOZTTY_RESTORE_SKIP=1 — the T620 seam that forces the real
#      degradation where neither restore source yields a window (manifest gone,
#      GET_LAYOUTS faulted). The agent then holds live children with no viewer.
#      Dropping the manifest alone stopped working when launch-time restore
#      learned to recover such a window from the agent's own layout store
#      (T194); a second-instance fixture is no better, because the manifest and
#      layout store are shared across pipe-suffix instances and the adopting
#      launch STEALS the other instance's session (see T620).
#   2. Right paints the cursor - the first card's fill picks up the accent wash
#      it did not have a moment earlier (the plain card is its own control).
#   3. Return resumes THAT row: the app logs the id it attached, the chooser
#      closes, and - the independent oracle - `ghoztty +sessions --json`, which
#      dials the agent directly and never goes through the app, flips that
#      session's `attached` from false to true.
#   4. a session whose program has EXITED is not offered at all (D91/T1364).
#      The user's rule is that the list means "what is still running that you
#      have no window on", so a tombstone - relaunchable or not - is simply not
#      a row. T466 read D91's question the other way and listed such rows with a
#      "can relaunch" badge, which made the list grow with finished work every
#      time the box rebooted. The fixture kills the agent to produce tombstones,
#      then asserts their ABSENCE two ways: the roster's own oracle line
#      ("chooser roster: listing N session(s), M exited hidden"), cross-checked
#      against `+sessions --json`, and a keyboard walk over the whole rendered
#      list that never lands on one. The agent keeps the tombstones, because
#      launch-time restore still revives them from a saved layout.
#
# POSITIVE CONTROL for (4): section 4 reopens the chooser and acts on a LIVE
# row with the same keys. Section 3's headline assertion is an ABSENCE, which a
# dialog that ignored every keystroke would also satisfy - so the control is
# what separates "the tombstones are gone" from "nothing in here works at all"
# (the T240 lesson).
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

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = "-t320$PID"
# The T620 restore-skip seam is set at the RELAUNCH, not before the first
# launch; clear a leak from a parent shell so the first launch is a real one.
Remove-Item Env:\GHOZTTY_RESTORE_SKIP -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChooserCursor.ps1')  # Step-ChooserCursor / Walk-ChooserCursorToId

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

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

# Half of the orphan fixture: the relaunched app must not re-attach the very
# sessions this test needs to be unattached. The manifest delete alone stopped
# being enough when T194 taught launch-time restore to pull layout blobs from
# the AGENT (alive across the kill, answering GET_LAYOUTS from memory), so the
# relaunch also sets GHOZTTY_RESTORE_SKIP — the deletion stays because it keeps
# the fixture honest about what a crash-regressed manifest looks like.
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

# The rows the roster actually RENDERS, in agent order: the sessions whose
# program is still running (T1364 - a tombstone is not a row). The keyboard
# cursor's index space is this list - which is the property under test, so it is
# derived here from the agent's own reply rather than assumed.
function Get-RenderedSessions {
    return @(Get-Sessions | Where-Object { $_.alive })
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

# --- Cursor-log navigation (T602/T620, shared in lib\ChooserCursor.ps1) ------
# The walk that reads the app's own cursor log back instead of assuming the
# roster's displayed order lives in one place now (T1107) - it had been copied
# into chooser-resume-remote.ps1 with a different timeout, and orphan-notify.ps1
# was still counting Downs blind. These two keep their positional shape so the
# call sites below read as they always did.
function Step-Cursor($chooser, $filter, $log, $key) {
    return Step-ChooserCursor -Chooser $chooser -Filter $filter -Log $log -Key $key
}

function Walk-CursorToId($chooser, $filter, $log, [string[]]$TargetIds, [int]$MaxRows) {
    return Walk-ChooserCursorToId -Chooser $chooser -Filter $filter -Log $log `
        -TargetIds $TargetIds -MaxRows $MaxRows
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
    # point of session persistence. The relaunch runs under GHOZTTY_RESTORE_SKIP
    # (plus the manifest delete) so launch-time restore cannot re-attach them -
    # the T194 agent-side layout store would otherwise rebuild the window and
    # every row would take the already-open shortcut instead of resuming.
    Stop-RepoProcesses @('ghoztty')
    Remove-LayoutManifest
    $orphans = @(Get-Sessions | Where-Object { $_.alive })
    Assert ($orphans.Count -ge 2) "the sessions outlived the app ($($orphans.Count) alive)"

    $env:GHOZTTY_RESTORE_SKIP = '1'
    $g = Launch-Gui $errlog2 @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died on relaunch'; exit 1 }
    Start-Sleep -Seconds 2

    # The seam must have ENGAGED, and say so - otherwise a future launch-order
    # change could leave restore running and this fixture would fail three
    # asserts down with no pointer at why.
    $skipLine = Wait-LogLine $errlog2 'session-restore: skipped entirely by GHOZTTY_RESTORE_SKIP' 4000
    Assert ($null -ne $skipLine) 'the relaunch skipped launch-time restore (T620 seam engaged)'

    $rendered = @(Get-RenderedSessions)
    Assert ($rendered.Count -ge 3) "the roster has the orphans plus the new pane ($($rendered.Count) rows)"
    # The rows to resume are ORPHANS: alive with no viewer. The relaunched app's
    # own pane is alive too and sits somewhere in the same displayed list (which
    # T602 sorts by name or CPU), so rows are chosen by what they ARE and found
    # by the cursor-landing log rather than by a precomputed index.
    $orphanIds = @($rendered | Where-Object { $_.alive -and -not $_.attached } | ForEach-Object { $_.id })
    Assert ($orphanIds.Count -ge 1) "a live row with no viewer is rendered ($($orphanIds.Count) of $($rendered.Count))"
    if ($orphanIds.Count -lt 1) { Write-Host 'SETUP FAIL: no orphaned live session'; exit 1 }

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
    $shot = Get-TestWindowPixels -Window $chooser -Sync
    try {
        $distinct = Get-TestDistinctColors -Shot $shot
        Assert ($distinct -gt 3) "the capture is a real frame, not a black mid-paint one ($distinct colors)"
        $plain = Get-TestPixel -Shot $shot -X ($client.Left + $geo.CardX) -Y ($client.Top + $geo.CardY)
    } finally { Close-TestWindowPixels -Shot $shot }

    $entered = Step-Cursor $chooser $filter $errlog2 'Right'
    Assert ($entered -ne $null -and $entered -ne '') "Right steps the cursor into the roster (landed on $entered)"
    Start-Sleep -Milliseconds 600

    $cursored = $null
    $shot = Get-TestWindowPixels -Window $chooser -Sync
    try {
        $cursored = Get-TestPixel -Shot $shot -X ($client.Left + $geo.CardX) -Y ($client.Top + $geo.CardY)
    } finally { Close-TestWindowPixels -Shot $shot }

    $bLift = -999
    if ($plain -and $cursored) { $bLift = [int]$cursored.B - [int]$plain.B }
    # The cursor wash is the user's accent (a blue on this box's default) over
    # the card, so the blue channel is the one that must move. The plain card,
    # sampled one keystroke earlier at the same point, is the control.
    Assert ($bLift -gt 8) "the cursored card picks up the accent wash (B +$bLift)"

    # Walk to an orphan's row, reading each landing back from the app's own
    # cursor log - the displayed order is T602-sorted, so the log is the only
    # index space the walk can trust.
    $walkedId = Walk-CursorToId $chooser $filter $errlog2 $orphanIds $rendered.Count
    Assert ($null -ne $walkedId) "the cursor walk lands on an orphaned live row ($walkedId)"
    if ($null -eq $walkedId) { Write-Host 'SETUP FAIL: cursor never reached an orphan row'; exit 1 }
    Start-Sleep -Milliseconds 400

    $before = @(Get-Sessions)
    Send-ChooserKey $chooser $filter 'Return' | Out-Null
    $attach = Wait-LogLine $errlog2 'resume session: attaching local session id=' 6000
    Assert ($null -ne $attach) 'Return on the cursored row resumes it'

    $resumedId = ''
    if ($attach -and $attach -match 'id=([0-9a-fA-F]+)') { $resumedId = $Matches[1] }
    Assert ($resumedId -eq $walkedId) `
        "the resumed session is the row the cursor was on ($resumedId vs $walkedId)"

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

    # --- A finished session is NOT listed (D91/T1364) -----------------------
    Write-Host ''
    Write-Host '3. a session whose program has exited is not offered at all'
    # Killing the agent turns every live child into a tombstone; the respawned
    # agent rematerializes them from sessions.json as relaunchable rows - the
    # exact shape a reboot produces, and the one T466 used to LIST with a
    # "can relaunch" badge. Per D91 those rows are over and the chooser must not
    # carry them. GHOZTTY_RESTORE_SKIP is still set, deliberately: without it
    # this relaunch would adopt the agent's layout blobs and RELAUNCH the
    # tombstones as fresh shells (T89g), leaving no dead row for this section to
    # find. The new app's own panes supply the live rows.
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-LayoutManifest
    $g = Launch-Gui $errlog3 @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died on second relaunch'; exit 1 }
    Start-Sleep -Seconds 2

    $all = @(Get-Sessions)
    $deadIds = @($all | Where-Object { -not $_.alive } | ForEach-Object { $_.id })
    $rows = @(Get-RenderedSessions)
    $liveIds = @($rows | ForEach-Object { $_.id })
    Assert ($deadIds.Count -ge 1) "the agent is holding tombstones ($($deadIds.Count) of $($all.Count))"
    Assert ($liveIds.Count -ge 1) "and a live session too ($($liveIds.Count))"
    if ($deadIds.Count -lt 1 -or $liveIds.Count -lt 1) { Write-Host 'SETUP FAIL: need one dead and one live session'; exit 1 }

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Wait-LogLine $errlog3 'chooser roster: loaded (\d+) session' 8000 | Out-Null

    # The ABSENCE oracle, and the reason it is one: the rows are owner-drawn, so
    # the roster says out loud what it LISTED and what it HID
    # (SessionRoster.logListed), and that is cross-checked here against
    # `ghoztty +sessions --json`, which dials the agent directly and never goes
    # through the app. An empty fixture cannot pass it - the agent must report
    # the tombstones for `hidden` to match. This replaces T466's "N session(s)
    # can relaunch" oracle rather than deleting it: the same mark, asserted
    # absent. Read the LAST such line: the roster is adopted on every fetch, so
    # earlier opens left their own counts in this log.
    $markLines = @(Select-String -Path $errlog3 -Pattern 'chooser roster: listing (\d+) session\(s\), (\d+) exited hidden')
    $listed = if ($markLines.Count -gt 0) { [int]$markLines[-1].Matches[0].Groups[1].Value } else { -1 }
    $hidden = if ($markLines.Count -gt 0) { [int]$markLines[-1].Matches[0].Groups[2].Value } else { -1 }
    Assert ($hidden -eq $deadIds.Count) `
        "the roster hides exactly the finished sessions (hid $hidden, agent says $($deadIds.Count))"
    Assert ($listed -eq $liveIds.Count) `
        "and lists exactly the live ones (listed $listed, agent says $($liveIds.Count))"

    # And the cursor cannot reach one: the keyboard walk over the whole rendered
    # list never lands on a tombstone id, so there is no row to press Return on
    # even for someone who tries. The walk is bounded by the rendered count,
    # which is what the roster claims to be showing.
    $deadLanded = Walk-CursorToId $chooser $filter $errlog3 $deadIds $rows.Count
    Assert ($null -eq $deadLanded) `
        "no cursor landing names a finished session (landed on '$deadLanded')"

    # Nothing was opened, so this chooser is still up: dismiss it for the
    # control below, which opens its own.
    Send-ChooserKey $chooser $filter 'Escape' | Out-Null
    Start-Sleep -Milliseconds 600
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'the chooser closes on Escape'

    # The agent's own roster is unchanged by any of it: refusing to LIST a
    # tombstone must not retire it, because launch-time restore still revives
    # those leaves from a saved layout (a different path, D91 untouched).
    $stillDead = @(Get-Sessions | Where-Object { -not $_.alive } | ForEach-Object { $_.id })
    Assert ($stillDead.Count -ge $deadIds.Count) `
        "the agent still holds its tombstones for launch-time restore ($($stillDead.Count))"

    # POSITIVE CONTROL: the same keys, a LIVE row, in a freshly reopened
    # chooser (section 3 dismissed the last one with Escape). Section 3's
    # headline assertion is an ABSENCE - no tombstone row, no cursor landing on
    # one - and a dialog that swallowed every keystroke would satisfy it too, so
    # this control is what says the keys reach the roster at all.
    #
    # A session already open here is FOCUSED rather than attached a second time
    # - the agent rebinds a session to its newest ATTACH, so resuming one twice
    # would take the pane away from the window that has it (a deliberate
    # divergence from Mac, T330). That focus is what this control reads.
    Write-Host ''
    Write-Host '4. positive control: the same keys DO act on a live row'
    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens after the relaunch'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser for the control'; exit 1 }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Wait-LogLine $errlog3 'chooser roster: loaded (\d+) session' 8000 | Out-Null
    $rows = @(Get-RenderedSessions)
    $liveIds = @($rows | Where-Object { $_.alive } | ForEach-Object { $_.id })
    $liveLanded = Walk-CursorToId $chooser $filter $errlog3 $liveIds $rows.Count
    Assert ($null -ne $liveLanded) "the cursor walk lands on the live row ($liveLanded)"
    Start-Sleep -Milliseconds 400
    # Counted, not merely awaited: a line matched from section 3's leftovers
    # would pass a Wait with the keystroke never arriving.
    $focusesBefore = Count-LogLines $errlog3 'session already open, focusing its pane'
    Send-ChooserKey $chooser $filter 'Return' | Out-Null
    $waited = 0
    while ($waited -lt 6000 -and (Count-LogLines $errlog3 'session already open, focusing its pane') -le $focusesBefore) {
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    Assert ((Count-LogLines $errlog3 'session already open, focusing its pane') -gt $focusesBefore) `
        'Return on a live row that is open here focuses its pane'
    Start-Sleep -Seconds 1
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'and the chooser dismissed onto it'
} finally {
    Remove-Item Env:\GHOZTTY_RESTORE_SKIP -ErrorAction SilentlyContinue
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
}

# --- stamp (T783/T816) ------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?".
# This harness earned its row the hard way: it sat red at SETUP FAIL for eight
# days (2026-08-04 -> T620) because nothing tied a restore-path change to the
# fixture it broke. Every SETUP FAIL path above exits before here, so a run
# that proved nothing cannot stamp.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-resume -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
