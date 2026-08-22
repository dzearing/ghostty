# T298 acceptance: what a per-card metrics PROBE does when the machine is not
# there.
#
# `activity-monitor-remote.ps1` section H covers the happy half - an inactive
# card carrying live uptime/CPU/mem from its own dialed connection. It cannot
# cover this half, and the reason is worth stating: there, a machine has a card
# only because a WINDOW is connected to it, so every card in that fixture is by
# construction reachable. A second loopback agent would give it an unreachable
# one, except `--listen` takes the single-instance guard
# (`src/remote/agent/single_instance.zig`) and the second agent exits 183
# before it ever binds.
#
# So this script fakes the OTHER source of cards: the relay DIRECTORY. A
# loopback HTTP listener answers `/v1/client/devices` with one device that has
# never existed, and refuses the `/v1/client/connect` WebSocket upgrade that a
# probe dial would need. The same fake-directory harness
# `ipc-machine-chooser.ps1` uses, pointed at the Activity Monitor.
#
# What it asserts:
#
#   A. the panel's carousel gains a card for the directory's machine, and the
#      panel PROBES it - a directory entry is not just a label;
#   B. a dial the machine refuses paints `unreachable` on that card. This is
#      the assertion that fails if a failed probe leaves the card sitting on
#      "connecting" forever, or worse keeps painting the directory's stale
#      `online: true`;
#   C. it is NOT re-dialed inside its backoff. The panel ticks every 1.5s and
#      the backoff floor is 30s, so a 20-second watch that sees the dial count
#      move means the probe is looping - which against a real relay would be
#      ~13 dials a minute per dead machine, forever, for as long as the panel
#      is open;
#   D. and the panel stays alive and keeps sampling its own source throughout -
#      an unreachable card must not take the panel down with it.
#
# ORACLE. Cards are GDI-painted strings with no control to query, so the oracle
# is the panel's own `carousel ... states=` line (T298), which reports each
# card's summary - the struct the painter formats, not a restatement of the
# claim - alongside the `probing machine=` / `probe connected` dial log.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and asserts at the end that it
# never took the user's foreground.
# T248: the repo's agent is killed and the app launched with
# --session-persistence=false.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [int]$DirPort = 47921, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$errlog = Join-Path $env:TEMP 'ghoztty-activity-probefail-stderr.log'
$env:GHOZTTY_PIPE_SUFFIX = '-activityprobefail'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# The device the directory lists and the relay never connects. `online: true`
# on purpose: the card would report "online" from this flag alone, so a probe
# that quietly did nothing would look exactly like a probe that worked - which
# is the failure B exists to catch.
$DEVICE_ID = 'dev-never-there'

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
}

function Get-Panels {
    return @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyActivityMonitor')
}

# The panel's most recent state line - used only to prove the panel is still
# sampling its own source (D).
function Get-PanelState {
    if (-not (Test-Path $errlog)) { return $null }
    $pat = 'activity monitor: source=(\S+) total=(\d+) shown=(\d+)'
    $m = @(Select-String -Path $errlog -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    return [pscustomobject]@{ Source = $g[1].Value; Total = [int]$g[2].Value }
}

# The panel's most recent carousel line (T296/T298). Same parser as
# activity-monitor-remote.ps1; `states` is what this script is about.
function Get-Carousel {
    if (-not (Test-Path $errlog)) { return $null }
    $pat = 'activity monitor: carousel cards=(\d+) focus=(-?\d+) active=(-?\d+) scroll=(-?\d+) probes=(\d+) rects=(\S*) states=(\S*)'
    $m = @(Select-String -Path $errlog -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    $states = @()
    foreach ($part in ($g[7].Value -split ';')) {
        if (-not $part) { continue }
        $c = $part -split '/'
        if ($c.Count -ne 6) { continue }
        $states += [pscustomobject]@{
            Id = $c[0]; State = $c[1]; UptimeS = [int64]$c[2]
            CpuPct = [int]$c[3]; MemUsed = [int64]$c[4]; MemTotal = [int64]$c[5]
        }
    }
    return [pscustomobject]@{
        Cards = [int]$g[1].Value; Probes = [int]$g[5].Value; States = $states; RawSt = $g[7].Value
    }
}

function Get-CardState([string]$Id) {
    $c = Get-Carousel
    if ($null -eq $c) { return $null }
    foreach ($s in $c.States) { if ($s.Id -eq $Id) { return $s } }
    return $null
}

function Wait-CardState([string]$Id, [string[]]$States, [int]$TimeoutMs = 30000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $last = Get-CardState $Id
        if ($null -ne $last -and $States -contains $last.State) { return $last }
        Start-Sleep -Milliseconds 500
    }
    return $last
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

# --- Fake relay: a directory that lists one machine, and a connect endpoint
# that refuses ---------------------------------------------------------------
#
# Every request gets a plain HTTP response - 200 + the device list for
# `/v1/client/devices`, 404 for anything else. A probe's relay dial needs a 101
# WebSocket upgrade, so 404 makes it fail at the upgrade rather than by
# timeout: the card must report unreachable because the machine SAID no, which
# is the fast, deterministic version of the same verdict.
$hitFile = Join-Path $env:TEMP "ghoztty-probefail-hits-$PID.txt"
Remove-Item $hitFile -ErrorAction SilentlyContinue
$devicesJson = "{`"devices`":[{`"id`":`"$DEVICE_ID`",`"name`":`"Never There`",`"hostname`":`"never.local`",`"online`":true}]}"
$dirJob = Start-Job -ScriptBlock {
    param($port, $body, $hitFile)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    $payload = [Text.Encoding]::UTF8.GetBytes($body)
    $ok = [Text.Encoding]::UTF8.GetBytes(
        "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n") + $payload
    $no = [Text.Encoding]::UTF8.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
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
            if ($reqLine -match '/v1/client/devices') {
                $stream.Write($ok, 0, $ok.Length)
            } else {
                $stream.Write($no, 0, $no.Length)
            }
            $stream.Flush()
        } catch {}
        $client.Close()
    }
} -ArgumentList $DirPort, $devicesJson, $hitFile
Start-Sleep -Milliseconds 600

Kill-RepoInstances
Remove-Item $errlog -ErrorAction SilentlyContinue
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # Signed in via the env token, against the fake relay, and isolated from any
    # real account store so GHOSTTY_RELAY_TOKEN is what resolves.
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DirPort"
    $env:GHOSTTY_RELAY_TOKEN = 'faketoken-probefail'
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $env:TEMP "ghoztty-probefail-acct-$PID\account.dat")
    $script:app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -StdErr $errlog
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no pane'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    # Positive control: the chord injection works, so "the panel never opened"
    # later is a product verdict and not a dead probe.
    $ctlPopup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $ctlPopup = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($ctlPopup -ne [IntPtr]::Zero) { break }
    }
    if ($ctlPopup -eq [IntPtr]::Zero) {
        Write-Host 'ABORT: positive control failed (palette never opened) - injection broken, not a T298 verdict'
        exit 1
    }
    Write-Host 'OK    positive control: ctrl+shift+p opens the palette'
    $ctlEdit = Find-TestWindowEx -Parent $ctlPopup -Class 'EDIT'
    if ($ctlEdit -ne [IntPtr]::Zero) { Send-TestControlKey -Control $ctlEdit -Key Escape | Out-Null }
    Start-Sleep -Milliseconds 400

    # --- A. The directory's machine gets a card, and the panel probes it -----
    if (-not (Invoke-Palette $top $pane 'ACTIVITY MONITOR' 'A')) {
        Write-Host 'SETUP FAIL: palette dispatch not delivered'; exit 1
    }
    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
    Assert ($panel -ne [IntPtr]::Zero) 'A the palette opened the Local Activity Monitor panel'
    if ($panel -eq [IntPtr]::Zero) { throw 'no panel to test' }

    $card = Wait-CardState $DEVICE_ID @('connecting', 'failed', 'live') 20000
    Assert ($null -ne $card) "A the directory's machine got a card (states=$((Get-Carousel).RawSt))"
    $hits = Get-Content $hitFile -ErrorAction SilentlyContinue
    Assert (($hits -join "`n") -match '/v1/client/devices') 'A the panel fetched the device directory'
    Assert (Select-String -Path $errlog -Pattern "activity monitor: probing machine=$DEVICE_ID kind=relay" -Quiet) `
        'A ...and PROBED it over the relay, rather than just labelling the card'

    # --- B. A refused dial paints `unreachable` ------------------------------
    # NOT `online`, which is what the directory said and what the card would
    # report from the flag alone; NOT `connecting`, which would leave a machine
    # that is simply gone looking like one that is about to answer.
    $failed = Wait-CardState $DEVICE_ID @('failed') 30000
    if ($NegativeControl) {
        Assert ($null -ne $failed -and $failed.State -eq 'live') `
            "B(neg) the unreachable card is asserted LIVE (this run MUST fail) (state=$($failed.State))"
    } else {
        Assert ($null -ne $failed -and $failed.State -eq 'failed') `
            "B a machine that refuses the dial paints unreachable (state=$($failed.State))"
    }
    # --- C. And it is not re-dialed inside its backoff -----------------------
    # 20s of watching, against a 1.5s tick and a 30s backoff floor: a looping
    # probe moves this count by ~13, a correct one by 0.
    $probePat = "activity monitor: probing machine=$DEVICE_ID"
    $before = @(Select-String -Path $errlog -Pattern $probePat).Count
    Assert ($before -ge 1) "C the machine was dialed at least once (dials=$before)"
    Start-Sleep -Seconds 20
    $after = @(Select-String -Path $errlog -Pattern $probePat).Count
    Assert ($after -eq $before) "C ...and NOT re-dialed inside its backoff ($before -> $after)"

    # --- D. The panel is unharmed by the machine it cannot reach -------------
    $st = Get-PanelState
    Assert ($null -ne $st -and $st.Source -eq 'Local') "D the panel is still on its own source (source=$($st.Source))"
    Assert ($null -ne $st -and $st.Total -gt 0) 'D ...and still sampling it'
    Assert ((@(Get-Panels)).Count -eq 1) 'D the panel is still open'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'D the app survives an unreachable machine'

    Send-TestWindowClose -Window $panel | Out-Null
    Start-Sleep -Seconds 2
    Assert ((@(Get-Panels)).Count -eq 0) 'D the panel closed cleanly with a failed probe in it'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'D the app survives that close'
} finally {
    Remove-TestDesktop
    if ($null -ne $dirJob) { Stop-Job $dirJob -ErrorAction SilentlyContinue; Remove-Job $dirJob -Force -ErrorAction SilentlyContinue }
    Kill-RepoInstances
    Remove-Item $hitFile -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $env:TEMP "ghoztty-probefail-acct-$PID") -ErrorAction SilentlyContinue
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
if ($script:fail -eq 0) { Write-Host "ACTIVITY MONITOR PROBE-FAIL ACCEPTANCE: ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
