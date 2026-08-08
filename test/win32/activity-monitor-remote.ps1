# T295 acceptance: the Activity Monitor panel against a REMOTE source.
#
# T285 built the panel on the LOCAL source and T295 gives it a connection. Two
# of Mac's three entry styles differ only in WHO OWNS that connection
# (RemoteActivityMonitor.swift:8-16), and ownership is the thing that can go
# quietly wrong, so it is what this script is about:
#
#   A. a remote WINDOW's palette opens a panel titled for the MACHINE, not
#      "Activity - Local";
#   B. the rows come from the AGENT, not from this process;
#   C. the registry still focuses rather than duplicates, across the remote
#      source;
#   D. closing that panel LEAVES THE REMOTE WINDOW'S SESSION ALIVE - the panel
#      borrowed the window's connection and must never free it.
#
# T296 adds the switcher to the same fixture, because a carousel needs a second
# source and this script is where one exists:
#
#   E. the machine-card carousel moves the panel to another source IN PLACE -
#      one click, no second window, retitled, sampling the new machine - while
#      ARROWING dials nothing, and switching away from a BORROWED connection
#      leaves the window's session alive exactly as closing does.
#
# T300 adds the other way in, for the same reason - a carousel needs a second
# source to be reachable at all:
#
#   F. the carousel is reachable BY KEYBOARD from a cold open: Tab alone walks
#      to it with no mouse click anywhere in the panel, Left/Right/Home/End
#      then move the ring without dialing, and Return commits the switch -
#      while a focused BUTTON still owns Space, which is why the pre-T300 gate
#      could not simply be deleted.
#
# T301 closes the round trip E only half made:
#
#   G. switching BACK to a machine a live WINDOW is connected to keeps that
#      machine's CARD reachable and BORROWS the window's connection instead of
#      re-dialing one - and when that window closes underneath, the panel is
#      told to let go rather than reading freed memory. (The app then crashes
#      for an OLDER, unrelated reason - see G4's note and T613.)
#
# WHY B NEEDS AN ORACLE AT ALL. The loopback agent enumerates the same box, so
# "the table populated" proves nothing: a panel that silently sampled THIS
# process would produce an identical-looking table under another machine's
# name, which is exactly the lie T295's predecessor refused to tell. The
# distinguishing field is the snapshot's ROOT PID: the agent's own pid for a
# remote sample (PROC_SNAPSHOT.agent_pid), this app's for a local one. It is
# logged by `ActivityMonitor.rebuild` as `root=`, alongside the counts the
# painter walks - a derivation of the painted state, not a restatement of the
# assertion.
#
# CONTROLS. Two positive controls run before any verdict: ctrl+shift+p must
# open the palette (else the injection is broken, not the product), and the
# remote pane must round-trip through the agent (else the link is broken).
# `-NegativeControl` inverts B - it asserts the root pid is the APP's, i.e.
# that the panel sampled locally - and that run MUST fail.
#
# NOT COVERED HERE: the DIALED entry (the chooser's Activity button) needs a
# relay device, which needs a signed-in account; `chooser-menu.ps1` covers the
# button and this covers the data plane it lands on.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and asserts at the end that it
# never took the user's foreground.
# T248: the repo's agent is killed and the app launched with
# --session-persistence=false, so a restored manifest cannot hand this run a
# previous run's panes.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [int]$Port = 47913, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$agentExe = Join-Path (Split-Path $exe -Parent) 'ghoztty-agent.exe'
$errlog = Join-Path $env:TEMP 'ghoztty-activity-remote-stderr.log'
$tmp = Join-Path $env:TEMP "ghoztty-activity-remote-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:GHOZTTY_PIPE_SUFFIX = '-activityremote'
$env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:agent = $null
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    foreach ($name in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$name'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 500
}

# The panel's most recent state line. `root` is the field this script exists
# for; the rest is carried so a failure prints something readable.
function Get-PanelState {
    if (-not (Test-Path $errlog)) { return $null }
    $pat = 'activity monitor: source=(\S+) total=(\d+) shown=(\d+) needle="([^"]*)" show_all=(\w+) sort=\w+/\w+ selected=\d+ root=(-?\d+)'
    $m = @(Select-String -Path $errlog -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    return [pscustomobject]@{
        Source  = $g[1].Value
        Total   = [int]$g[2].Value
        Shown   = [int]$g[3].Value
        ShowAll = $g[5].Value
        Root    = [int64]$g[6].Value
    }
}

# The panel's most recent focus-stop line (T300), i.e. where the keyboard is.
# The only oracle for it: `carousel` and `table` are owner-drawn REGIONS of the
# panel's own window, so GetFocus answers the panel's hwnd for either and
# cannot tell them apart.
function Get-FocusStop {
    if (-not (Test-Path $errlog)) { return $null }
    $m = @(Select-String -Path $errlog -Pattern 'activity monitor: focus (\w+) -> (\w+)') | Select-Object -Last 1
    if (-not $m) { return $null }
    return $m.Matches[0].Groups[2].Value
}

function Wait-PanelState([string]$SourceLike, [int]$TimeoutMs = 12000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $s = Get-PanelState
        if ($null -ne $s -and $s.Source -like $SourceLike -and $s.Total -gt 0) { return $s }
        Start-Sleep -Milliseconds 300
    }
    return Get-PanelState
}

function Get-Panels {
    return @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyActivityMonitor')
}

# The panel's most recent carousel line (T296). `rects` is the painter's own
# card arithmetic, so a click can land on a painted card without this script
# re-deriving a layout it would then be asserting against itself.
function Get-Carousel {
    if (-not (Test-Path $errlog)) { return $null }
    $pat = 'activity monitor: carousel cards=(\d+) focus=(-?\d+) active=(-?\d+) scroll=(-?\d+) rects=(\S*)'
    $m = @(Select-String -Path $errlog -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    $rects = @()
    foreach ($part in ($g[5].Value -split ';')) {
        if (-not $part) { continue }
        $c = $part -split ','
        if ($c.Count -ne 4) { continue }
        $rects += [pscustomobject]@{
            Left = [int]$c[0]; Top = [int]$c[1]; Right = [int]$c[2]; Bottom = [int]$c[3]
        }
    }
    return [pscustomobject]@{
        Cards  = [int]$g[1].Value
        Focus  = [int]$g[2].Value
        Active = [int]$g[3].Value
        Scroll = [int]$g[4].Value
        Rects  = $rects
        Raw    = $g[5].Value
    }
}

# Open the palette on $pane, type $filter, press Enter.
function Invoke-Palette([IntPtr]$top, [IntPtr]$pane, [string]$filter, [string]$label) {
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    Assert ($popup -ne [IntPtr]::Zero) "$label palette opened"
    if ($popup -eq [IntPtr]::Zero) { return $false }
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($edit -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL: $label palette edit not found"; return $false }
    Send-TestControlText -Control $edit -Text $filter | Out-Null
    $sent = Send-TestControlKey -Control $edit -Key Enter
    Start-Sleep -Milliseconds 900
    return $sent
}

function Read-Pane([string]$name) {
    cmd /c "`"$exe`" +read --name=$name --lines=40 > `"$tmp\read.txt`" 2>&1" | Out-Null
    if (-not (Test-Path "$tmp\read.txt")) { return '' }
    return (Get-Content "$tmp\read.txt" -Raw)
}

Kill-RepoInstances
Remove-Item $errlog -ErrorAction SilentlyContinue
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # --- Setup: a loopback agent, then the app on the test desktop -----------
    if (-not (Test-Path $agentExe)) { Write-Host "SETUP FAIL: no agent at $agentExe"; exit 1 }
    $script:agent = Start-Process -FilePath $agentExe `
        -ArgumentList '--listen', "127.0.0.1:$Port", '--headless' -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if ($script:agent.HasExited) { Write-Host 'SETUP FAIL: loopback agent died at launch'; exit 1 }
    $agentPid = $script:agent.Id
    Write-Host "OK    setup: loopback agent pid=$agentPid on 127.0.0.1:$Port"

    $script:app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $localTop = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($localTop -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $localPane = Get-TestChildWindow -Window $localTop -Class 'GhozttyTerminal'
    if ($localPane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no pane'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    # --- Positive control 1: the chord injection works -----------------------
    $ctlPopup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $localTop -Target $localPane -Modifiers ctrl, shift -Key P)) { continue }
        $ctlPopup = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($ctlPopup -ne [IntPtr]::Zero) { break }
    }
    if ($ctlPopup -eq [IntPtr]::Zero) {
        Write-Host 'ABORT: positive control failed (palette never opened) - injection broken, not a T295 verdict'
        exit 1
    }
    Write-Host 'OK    positive control 1: ctrl+shift+p opens the palette'
    $ctlEdit = Find-TestWindowEx -Parent $ctlPopup -Class 'EDIT'
    if ($ctlEdit -ne [IntPtr]::Zero) { Send-TestControlKey -Control $ctlEdit -Key Escape | Out-Null }
    Start-Sleep -Milliseconds 400

    # --- Setup: a remote window on that agent --------------------------------
    cmd /c "`"$exe`" +new-remote-window --host=127.0.0.1 --port=$Port --name=remact > `"$tmp\open.txt`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ABORT: +new-remote-window failed: $(Get-Content "$tmp\open.txt" -Raw)"
        exit 1
    }
    Start-Sleep -Seconds 3
    $tops = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')
    $remoteTop = [IntPtr]::Zero
    foreach ($w in $tops) { if ([IntPtr]$w.Hwnd -ne $localTop) { $remoteTop = [IntPtr]$w.Hwnd } }
    if ($remoteTop -eq [IntPtr]::Zero) { Write-Host 'ABORT: remote window never appeared'; exit 1 }
    $remotePane = Get-TestChildWindow -Window $remoteTop -Class 'GhozttyTerminal'
    if ($remotePane -eq [IntPtr]::Zero) { Write-Host 'ABORT: remote window has no pane'; exit 1 }

    # --- Positive control 2: the remote pane really talks to the agent -------
    cmd /c "`"$exe`" +send-keys --target=remact `"echo activity-remote-up`" Enter > nul 2>&1" | Out-Null
    Start-Sleep -Seconds 3
    if ((Read-Pane 'remact') -notmatch 'activity-remote-up') {
        Write-Host 'ABORT: positive control failed (remote pane never round-tripped) - the agent link is broken, not a T295 verdict'
        exit 1
    }
    Write-Host 'OK    positive control 2: the remote pane round-trips through the agent'

    # --- A. The remote window's palette opens a panel for the MACHINE --------
    if (-not (Invoke-Palette $remoteTop $remotePane 'ACTIVITY MONITOR' 'A')) {
        Write-Host 'SETUP FAIL: palette dispatch not delivered'; exit 1
    }
    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
    Assert ($panel -ne [IntPtr]::Zero) 'A the palette on a remote window opens a panel'
    if ($panel -eq [IntPtr]::Zero) { throw 'no panel to test' }

    $title = Get-TestWindowText -Window $panel
    Assert ($title -like "*127.0.0.1:$Port*") "A the panel is titled for the MACHINE (got '$title')"
    Assert ($title -notlike '*Local*') 'A the panel is NOT the Local panel'

    # --- B. The rows came from the AGENT -------------------------------------
    $state = Wait-PanelState "127.0.0.1:$Port"
    Assert ($null -ne $state) 'B the remote panel logged a sample'
    if ($null -ne $state) {
        Write-Host "      state: source=$($state.Source) total=$($state.Total) shown=$($state.Shown) root=$($state.Root)"
        Assert ($state.Source -eq "127.0.0.1:$Port") 'B the sample is attributed to the remote source'
        Assert ($state.Total -gt 0) 'B the remote process table POPULATED'
        if ($NegativeControl) {
            Assert ($state.Root -eq $app.Pid) 'B(neg) the root pid is the APP (this run MUST fail)'
        } else {
            Assert ($state.Root -eq $agentPid) "B the snapshot's root pid is the AGENT's ($agentPid), not this app's ($($app.Pid))"
        }
    }

    # --- C. The registry still focuses rather than duplicates ----------------
    Invoke-Palette $remoteTop $remotePane 'ACTIVITY MONITOR' 'C' | Out-Null
    Start-Sleep -Milliseconds 800
    Assert ((@(Get-Panels)).Count -eq 1) 'C a second invocation focuses the same panel, it does not open a second'

    # --- D. Closing the panel leaves the WINDOW's session alive --------------
    # The panel BORROWED this window's connection. Freeing it here would take
    # the window's shell down with it, silently, and only a round-trip
    # afterwards can tell.
    Send-TestWindowClose -Window $panel | Out-Null
    Start-Sleep -Seconds 2
    Assert ((@(Get-Panels)).Count -eq 0) 'D the panel closed'
    Assert (Select-String -Path $errlog -Pattern 'activity monitor: closed source=' -Quiet) 'D the panel tore itself down'

    cmd /c "`"$exe`" +send-keys --target=remact `"echo activity-remote-still-alive`" Enter > nul 2>&1" | Out-Null
    Start-Sleep -Seconds 3
    $after = Read-Pane 'remact'
    Assert ($after -match 'activity-remote-still-alive') 'D the remote pane STILL round-trips after the panel closed (the borrowed connection was not freed)'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'D the app survives'

    # --- E. The carousel switches source IN PLACE (T296) ---------------------
    # Re-open the panel on the machine and drive its switcher. Everything here
    # keys off the panel's own `carousel` log line, whose `rects=` field is the
    # PAINTER's arithmetic - a script that re-derived the card geometry would be
    # asserting a layout against itself (the T257 lesson).
    if (-not (Invoke-Palette $remoteTop $remotePane 'ACTIVITY MONITOR' 'E')) {
        Write-Host 'SETUP FAIL: palette dispatch not delivered for E'; exit 1
    }
    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
    Assert ($panel -ne [IntPtr]::Zero) 'E the panel re-opened for the carousel section'
    if ($panel -eq [IntPtr]::Zero) { throw 'no panel to test the carousel on' }
    Wait-PanelState "127.0.0.1:$Port" | Out-Null

    $car = Get-Carousel
    Assert ($null -ne $car) 'E the panel logged its carousel'
    if ($null -ne $car) {
        Write-Host "      carousel: cards=$($car.Cards) focus=$($car.Focus) active=$($car.Active) rects=$($car.Raw)"
        # Local plus the machine this panel is showing. The machine is NOT in
        # the relay directory here (no account), which is exactly the case the
        # active-source card exists for.
        Assert ($car.Cards -ge 2) 'E the carousel offers at least Local and the active machine'
        Assert ($car.Active -ge 0) 'E the active source has a card of its own'
        Assert ($car.Rects.Count -eq $car.Cards) 'E every card reported a painted rect'
    }

    # Card rects are CLIENT coordinates; `Send-TestMouse` takes SCREEN ones (it
    # SetCursorPos'es before posting). The client rect comes back in screen
    # space, so its origin is the whole conversion.
    $origin = Get-TestWindowRect -Window $panel -Client

    # E1. Arrowing moves the FOCUS RING and nothing else - no dial, no switch.
    $dialsBefore = @(Select-String -Path $errlog -Pattern 'activity monitor: dialing ').Count
    $srcBefore = (Get-PanelState).Source
    $focusBefore = $car.Focus
    # Put keyboard focus on the panel without landing on a card. Well below the
    # carousel, not just past the cards: the band's own padding belongs to the
    # carousel too, and at 125% that padding is where "card bottom + 8" lands.
    # A click down there focuses the TABLE, so since T289 - where the arrow keys
    # belong to the focus stop that has them - one Tab is what walks focus round
    # to the carousel (the cycle wraps table -> carousel).
    Send-TestMouse -Window $panel -Target $panel `
        -X ($origin.Left + 8) -Y ($origin.Bottom - 30) -Action click | Out-Null
    Start-Sleep -Milliseconds 300
    Send-TestKeys -Window $panel -Target $panel -Key Tab | Out-Null
    Start-Sleep -Milliseconds 300
    Send-TestKeys -Window $panel -Target $panel -Key Left | Out-Null
    Start-Sleep -Milliseconds 500
    $car2 = Get-Carousel
    Assert ($null -ne $car2 -and $car2.Focus -ne $focusBefore) "E1 arrowing moved the focus ring ($focusBefore -> $($car2.Focus))"
    Assert ((Get-PanelState).Source -eq $srcBefore) 'E1 arrowing did NOT change the source'
    Assert ((@(Select-String -Path $errlog -Pattern 'activity monitor: dialing ')).Count -eq $dialsBefore) 'E1 arrowing dialed NOTHING'

    # E2. Clicking the Local card switches in place - one click, same window.
    $panelsBefore = (@(Get-Panels)).Count
    $localCard = $car.Rects[0]
    $cx = $origin.Left + [int](($localCard.Left + $localCard.Right) / 2)
    $cy = $origin.Top + [int](($localCard.Top + $localCard.Bottom) / 2)
    Send-TestMouse -Window $panel -Target $panel -X $cx -Y $cy -Action click | Out-Null
    Start-Sleep -Seconds 3
    $sw = Wait-PanelState 'Local' 10000
    Assert ($null -ne $sw -and $sw.Source -eq 'Local') "E2 the panel switched to Local (source=$($sw.Source))"
    Assert ($null -ne $sw -and $sw.Root -eq $app.Pid) "E2 it is now sampling THIS process ($($app.Pid)), not the agent ($agentPid)"
    Assert ((@(Get-Panels)).Count -eq $panelsBefore) 'E2 the switch did NOT open a second window'
    Assert ((Get-TestWindowText -Window $panel) -like '*Local*') 'E2 the window retitled for the new source'
    Assert (Select-String -Path $errlog -Pattern 'activity monitor: switching .* -> Local' -Quiet) 'E2 the panel logged the switch'

    # E3. Switching away from a BORROWED connection must not free it - the same
    # ownership rule D asserts for close, at the other place it can go wrong.
    cmd /c "`"$exe`" +send-keys --target=remact `"echo activity-after-switch`" Enter > nul 2>&1" | Out-Null
    Start-Sleep -Seconds 3
    Assert ((Read-Pane 'remact') -match 'activity-after-switch') 'E3 the remote pane still round-trips after the panel switched away (the borrowed connection was not freed)'

    Send-TestWindowClose -Window $panel | Out-Null
    Start-Sleep -Seconds 2
    Assert ((@(Get-Panels)).Count -eq 0) 'E the switched panel closed cleanly'

    # --- F. The carousel is KEYBOARD-reachable from a COLD OPEN (T300) --------
    # T289 put the carousel in the panel's Tab cycle; this is the arm that
    # proves a keyboard-only user can GET to it. Every keystroke below is posted
    # to whichever control holds focus and NOTHING is clicked inside the panel -
    # the moment a click lands, the mouse has done the reaching and the claim is
    # gone. (E1 above deliberately clicks first, because its subject is the ring
    # arithmetic rather than the reach.)
    if (-not (Invoke-Palette $remoteTop $remotePane 'ACTIVITY MONITOR' 'F')) {
        Write-Host 'SETUP FAIL: palette dispatch not delivered for F'; exit 1
    }
    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
    Assert ($panel -ne [IntPtr]::Zero) 'F the panel re-opened for the keyboard section'
    if ($panel -eq [IntPtr]::Zero) { throw 'no panel to test keyboard reach on' }
    Wait-PanelState "127.0.0.1:$Port" | Out-Null

    $filterEdit = Find-TestWindowEx -Parent $panel -Class 'EDIT'
    Assert ($filterEdit -ne [IntPtr]::Zero) 'F the filter field was found'

    # F1. A cold open leaves the keyboard in the filter field, and Tab ALONE
    # walks it round to the carousel.
    Assert ((Get-TestFocusedWindow -Window $panel) -eq $filterEdit) 'F1 a freshly opened panel puts the keyboard in the filter field'
    Assert ((Get-FocusStop) -eq 'filter') 'F1 ...and the panel itself says that is where the keyboard is'
    $carF = Get-Carousel
    Assert ($null -ne $carF -and $carF.Cards -ge 2) 'F1 the fresh panel has a carousel to reach'

    $walk = @('filter')
    $ctl = $filterEdit
    foreach ($i in 1..6) {
        Send-TestControlKey -Control $ctl -Key Tab | Out-Null
        Start-Sleep -Milliseconds 250
        $stop = Get-FocusStop
        $walk += $stop
        if ($stop -eq 'carousel') { break }
        $ctl = Get-TestFocusedWindow -Window $panel
        if ($ctl -eq [IntPtr]::Zero) { break }
    }
    Assert ($walk[-1] -eq 'carousel') "F1 Tab alone reaches the carousel from a cold open, no mouse ($($walk -join ' -> '))"
    Assert ((Get-TestFocusedWindow -Window $panel) -eq $panel) 'F1 Win32 focus is on the panel window, which owns the painted cards'

    # F2. The ring answers to the arrows AND to Home/End (T300) - and none of it
    # dials, which is the rule E1 asserts for the mouse-reached carousel.
    $dialsBefore = @(Select-String -Path $errlog -Pattern 'activity monitor: dialing ').Count
    $srcBefore = (Get-PanelState).Source
    $cards = $carF.Cards
    foreach ($step in @(
            @{ Key = 'End';   Want = $cards - 1; Label = 'End jumps the ring to the last card' },
            @{ Key = 'Home';  Want = 0;          Label = 'Home jumps it back to the first' },
            @{ Key = 'Right'; Want = 1;          Label = 'Right steps one card along' },
            @{ Key = 'Left';  Want = 0;          Label = 'Left steps one card back' })) {
        Send-TestControlKey -Control $panel -Key $step.Key | Out-Null
        Start-Sleep -Milliseconds 400
        $c = Get-Carousel
        Assert ($null -ne $c -and $c.Focus -eq $step.Want) "F2 $($step.Label) (focus=$($c.Focus), want $($step.Want))"
    }
    Assert ((Get-PanelState).Source -eq $srcBefore) 'F2 walking the strip did NOT change the source'
    Assert ((@(Select-String -Path $errlog -Pattern 'activity monitor: dialing ')).Count -eq $dialsBefore) 'F2 walking the strip dialed NOTHING'

    # F3. NEGATIVE CONTROL, and the reason T300's gate could not simply be
    # deleted: Space and Return belong to whichever BUTTON has focus. A carousel
    # that took them globally would make the panel's buttons unpressable from
    # the keyboard, so with a button focused Space must press THAT and leave
    # both the source and the ring alone.
    #
    # "Show all" rather than Kill: the claim is the same one, its result is in
    # the panel's own state line, and Kill would have to terminate a real
    # process on the sampled machine to make it.
    Send-TestControlKey -Control $panel -Key Tab | Out-Null
    Start-Sleep -Milliseconds 250
    Send-TestControlKey -Control (Get-TestFocusedWindow -Window $panel) -Key Tab | Out-Null
    Start-Sleep -Milliseconds 250
    Assert ((Get-FocusStop) -eq 'show_all') "F3 two Tabs from the carousel reach the ""Show all"" button (stop=$(Get-FocusStop))"
    $showAllBtn = Get-TestFocusedWindow -Window $panel
    $checkBefore = (Get-PanelState).ShowAll
    $ringBefore = (Get-Carousel).Focus
    Send-TestControlKey -Control $showAllBtn -Key Space | Out-Null
    Start-Sleep -Seconds 2
    $stF = Get-PanelState
    Assert ($stF.ShowAll -ne $checkBefore) "F3 Space pressed the focused button ($checkBefore -> $($stF.ShowAll))"
    Assert ($stF.Source -eq $srcBefore) 'F3 ...and did NOT switch source'
    Assert ((Get-Carousel).Focus -eq $ringBefore) 'F3 ...and did NOT move the carousel ring'

    # F4. Return on the focused card commits the switch - the keyboard half of
    # E2's click. Tab back round to the carousel first (Kill is out of the cycle
    # with nothing selected), then Home to put the ring on Local.
    foreach ($i in 1..3) {
        $ctl = Get-TestFocusedWindow -Window $panel
        if ($ctl -eq [IntPtr]::Zero) { break }
        Send-TestControlKey -Control $ctl -Key Tab | Out-Null
        Start-Sleep -Milliseconds 250
        if ((Get-FocusStop) -eq 'carousel') { break }
    }
    Assert ((Get-FocusStop) -eq 'carousel') 'F4 Tab walks back round to the carousel'
    Send-TestControlKey -Control $panel -Key Home | Out-Null
    Start-Sleep -Milliseconds 400
    Assert ((Get-Carousel).Focus -eq 0) 'F4 the ring is on the Local card'
    $panelsBefore = (@(Get-Panels)).Count
    Send-TestControlKey -Control $panel -Key Enter | Out-Null
    $swF = Wait-PanelState 'Local' 12000
    Assert ($null -ne $swF -and $swF.Source -eq 'Local') "F4 Return committed the switch to Local (source=$($swF.Source))"
    Assert ((@(Get-Panels)).Count -eq $panelsBefore) 'F4 the keyboard switch did NOT open a second window'

    Send-TestWindowClose -Window $panel | Out-Null
    Start-Sleep -Seconds 2
    Assert ((@(Get-Panels)).Count -eq 0) 'F the keyboard-driven panel closed cleanly'

    # --- G. Switching BACK to a machine a window is on borrows, never re-dials
    # (T301) ----------------------------------------------------------------
    # E proved the panel can leave a borrowed machine. Coming home was the half
    # that did not work, in two compounding ways: the machine's card DISAPPEARED
    # the moment it stopped being the active source (nothing lists a
    # 127.0.0.1:PORT box - the relay directory does not know it, and with no
    # signed-in account the directory is empty anyway), so the trip to Local was
    # one-way; and had a card existed, the switch would have dialed a FRESH
    # relay connection, which with no account simply fails while a perfectly
    # good link sits one window away.
    #
    # The oracle for "it did not re-dial" is the panel's own `dialing` line,
    # counted before and after: a borrow leaves it untouched. The oracle for "it
    # really came back" is the same root pid B uses - the AGENT's, not this
    # app's - so a panel that came home to a card but sampled nothing cannot
    # pass.
    if (-not (Invoke-Palette $remoteTop $remotePane 'ACTIVITY MONITOR' 'G')) {
        Write-Host 'SETUP FAIL: palette dispatch not delivered for G'; exit 1
    }
    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
    Assert ($panel -ne [IntPtr]::Zero) 'G the panel re-opened on the borrowed connection'
    if ($panel -eq [IntPtr]::Zero) { throw 'no panel to test the borrow on' }
    Wait-PanelState "127.0.0.1:$Port" | Out-Null

    # Walk the keyboard round to the carousel from wherever it is. Same Tab
    # cycle F1 proved reachable; this is only transport for G's own claim.
    function Reach-Carousel([IntPtr]$p) {
        foreach ($i in 1..7) {
            if ((Get-FocusStop) -eq 'carousel') { return $true }
            $c = Get-TestFocusedWindow -Window $p
            if ($c -eq [IntPtr]::Zero) { return $false }
            Send-TestControlKey -Control $c -Key Tab | Out-Null
            Start-Sleep -Milliseconds 250
        }
        return ((Get-FocusStop) -eq 'carousel')
    }

    $dialsBeforeG = @(Select-String -Path $errlog -Pattern 'activity monitor: dialing ').Count
    Assert (Reach-Carousel $panel) 'G the keyboard reached the carousel'
    Send-TestControlKey -Control $panel -Key Home | Out-Null
    Start-Sleep -Milliseconds 400
    Send-TestControlKey -Control $panel -Key Enter | Out-Null
    $gLocal = Wait-PanelState 'Local' 12000
    Assert ($null -ne $gLocal -and $gLocal.Source -eq 'Local') "G the panel left the machine for Local (source=$($gLocal.Source))"

    # G1. THE card is still there. This is the arm that failed before T301: with
    # the machine no longer active, nothing kept its card alive.
    $carG = Get-Carousel
    Assert ($null -ne $carG) 'G1 the panel logged its carousel from Local'
    if ($null -ne $carG) {
        Write-Host "      carousel from Local: cards=$($carG.Cards) focus=$($carG.Focus) active=$($carG.Active)"
        Assert ($carG.Cards -ge 2) "G1 the machine a WINDOW is connected to still has a card while the panel sits on Local (cards=$($carG.Cards))"
    }

    # G2. Return to it. `End` is the machine card: Local is always first.
    Assert (Reach-Carousel $panel) 'G2 the keyboard reached the carousel again'
    Send-TestControlKey -Control $panel -Key End | Out-Null
    Start-Sleep -Milliseconds 400
    Send-TestControlKey -Control $panel -Key Enter | Out-Null
    $gBack = Wait-PanelState "127.0.0.1:$Port" 12000
    Assert ($null -ne $gBack -and $gBack.Source -eq "127.0.0.1:$Port") "G2 the panel switched BACK to the machine (source=$($gBack.Source))"
    if ($null -ne $gBack) {
        Assert ($gBack.Total -gt 0) 'G2 it is sampling the machine again'
        Assert ($gBack.Root -eq $agentPid) "G2 the snapshot's root pid is the AGENT's ($agentPid) again, not this app's ($($app.Pid))"
    }

    # G3. And it got there by BORROWING - no second connection to a machine we
    # were already talking to, and nothing that needs an account.
    Assert ((@(Select-String -Path $errlog -Pattern 'activity monitor: dialing ')).Count -eq $dialsBeforeG) 'G3 switching back dialed NOTHING'
    Assert (Select-String -Path $errlog -Pattern 'activity monitor: borrowing a window' -Quiet) 'G3 the panel logged that it borrowed the window connection'

    cmd /c "`"$exe`" +send-keys --target=remact `"echo activity-after-borrow`" Enter > nul 2>&1" | Out-Null
    Start-Sleep -Seconds 3
    Assert ((Read-Pane 'remact') -match 'activity-after-borrow') 'G3 the remote pane still round-trips while the panel borrows its connection'

    # G4. Closing the WINDOW while the panel borrows. The window frees the
    # transport; a panel still sampling through it would be reading freed
    # memory, and nothing refcounts it - so the window's teardown has to hand
    # the panel its notice, which is what this asserts.
    #
    # WHY SURVIVAL IS NOT ASSERTED HERE. The app crashes moments later, and it
    # is NOT this dangler: the same close crashes with T301's release neutered
    # to a no-op (T296-era behavior) and does NOT crash with no panel open at
    # all. The fault lands after `Window.onDestroy` has fully run, back inside
    # DestroyWindow while Win32 destroys the child HWNDs, with an OPENGL32
    # frame on the stack - the hazard `Surface.deinit` already names in a
    # comment. It is filed as T613, which owns the survival assertions; adding
    # them here would only make this script red about somebody else's bug.
    cmd /c "`"$exe`" +close --target=remact > nul 2>&1" | Out-Null
    Start-Sleep -Seconds 4
    Assert (Select-String -Path $errlog -Pattern 'borrowed connection is going away' -Quiet) 'G4 the closing window told the panel to let go of its connection'
} finally {
    # cmd, not `& $exe ... 2>&1`: under $ErrorActionPreference='Stop' a native
    # command writing to stderr inside a redirected pipeline is a TERMINATING
    # error, and a teardown that throws would swallow the run's verdict.
    cmd /c "`"$exe`" +close --target=remact > nul 2>&1" | Out-Null
    Remove-TestDesktop
    if ($null -ne $script:agent) {
        Stop-Process -Id $script:agent.Id -Force -ErrorAction SilentlyContinue
    }
    Kill-RepoInstances
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ACTIVITY MONITOR REMOTE ACCEPTANCE: ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
