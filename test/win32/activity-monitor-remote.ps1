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
        Source = $g[1].Value
        Total  = [int]$g[2].Value
        Shown  = [int]$g[3].Value
        Root   = [int64]$g[6].Value
    }
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
    # Click below the carousel to put keyboard focus on the panel without
    # landing on a card.
    Send-TestMouse -Window $panel -Target $panel `
        -X ($origin.Left + 8) -Y ($origin.Top + $car.Rects[0].Bottom + 8) -Action click | Out-Null
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
