# Relay-window acceptance (tracker T21b): +new-remote-window --relay/--device
# through a LOCAL rendezvous relay (go build ./relay, DEV_AUTH) against a debug
# build + a loopback ghoztty-agent in --relay mode. Non-interactive; asserts and
# exits nonzero on any failure. Only ever touches ghoztty processes running
# from the repo zig-out (plus the relay.exe it builds into $env:TEMP).
#
#   powershell -NoProfile -File test\win32\ipc-relay.ps1
#
# Covers: relay dial + open window (happy path), terminal round-trip through
# relay+agent (send-keys -> read), --command forwarded into the agent OPEN,
# tokenless refusal ("not signed in"), bad-token dial failure (Mac-parity
# error), agent killed under a live window => GUI keeps answering IPC (no
# hang/crash), agent RESTARTED under that dead window => the ladder settles on a
# definite verdict (T368), +close teardown, and no connection threads left
# behind afterwards.
#
# SETUP IS GATED (T1105). Sections 0a-0c build the world every claim below
# stands on - the relay, the agent, and a live app to open relay windows in -
# and each of them ABORTS the run rather than letting its failure cascade. One
# broken precondition must report as one failure: on 2026-08-22 the base window
# in 0c failed, thirteen assertions that never had an app ran anyway, and the
# resulting `14 FAILURE(S)` was triaged as fourteen relay defects.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$RelaySrc = 'D:\git\ghoztty\relay',
    [int]$RelayPort = 47911
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-relay-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
New-Item -ItemType Directory -Force "$tmp\state" | Out-Null

$DevToken = 'devtok-e2e'
$RelayBase = "http://127.0.0.1:$RelayPort"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Run the CLI with a hard timeout so a hung GUI can never hang the script
# (that IS one of the failure modes under test). Returns the exit code, or
# $null on timeout. Output lands in $tmp\$outfile.
#
# T1105: it also records WHAT happened in $script:lastCli, because the exit code
# alone cannot tell "the CLI refused with 3" from "the CLI never returned" - and
# the log of a failed run is all anybody gets afterwards. The 2026-08-22 sweep
# scored this script 14 FAILURE(S) and the log could not say whether the very
# first one was a refusal or a 20-second hang.
function Run-Cli($argsLine, $outfile, $timeoutSec = 20) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$tmp\$outfile`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $sw.Stop()
        $script:lastCli = @{ Args = $argsLine; Out = $outfile
            Why = "TIMED OUT after ${timeoutSec}s (the CLI never returned)" }
        return $null
    }
    $sw.Stop()
    $script:lastCli = @{ Args = $argsLine; Out = $outfile
        Why = "exited $($p.ExitCode) after $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" }
    return $p.ExitCode
}

function Get-Out($outfile) {
    if (Test-Path "$tmp\$outfile") { Get-Content "$tmp\$outfile" -Raw } else { '' }
}

# Print the last Run-Cli's diagnosis and whatever the CLI wrote. Both halves are
# what the sweep log was missing: the *reason* for a nonzero exit, and the
# stdout/stderr the CLI produced on the way to it.
function Show-LastCli {
    if (-not $script:lastCli) { "    (no CLI call recorded)"; return }
    "    ghoztty $($script:lastCli.Args)"
    "    -> $($script:lastCli.Why)"
    $out = (Get-Out $script:lastCli.Out)
    if ([string]::IsNullOrWhiteSpace($out)) { "    -> wrote no output" }
    else { "    -> output:"; ($out.TrimEnd() -split "`r?`n" | ForEach-Object { "       $_" }) }
}

# The GUI process under test, path-exact on $Exe. Every `ghoztty.exe` a Run-Cli
# call spawns lives under the same path, so "the app" is the OLDEST of them -
# Stop-TestProcs cleared the field before 0c, which makes the base window's
# instance the first one started. Used for the two things only the process can
# answer: is it still alive (no crash), and how many threads is it holding
# (no orphaned connection threads).
function Get-AppProc {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe } |
        Sort-Object CreationDate | Select-Object -First 1
}

function Get-AppThreadCount {
    $p = Get-AppProc
    if ($null -eq $p) { return -1 }
    return [int]$p.ThreadCount
}

# The T609 connection object for one window, or $null. Every read goes through a
# real `+list --json` CLI call, so a poll that stops answering is itself the
# hang this script exists to catch: the caller gets $null AND $script:lastCli
# names the timeout.
function Get-Connection($target, $outfile, $timeoutSec = 15) {
    $code = Run-Cli '+list --json' $outfile $timeoutSec
    if ($code -ne 0) { return $null }
    $j = $null
    try { $j = (Get-Out $outfile) | ConvertFrom-Json } catch { return $null }
    if (-not ($j -and $j.data -and $j.data.windows)) { return $null }
    $w = $j.data.windows | Where-Object { $_.target -eq $target } | Select-Object -First 1
    if ($null -eq $w) { return $null }
    if ($w.PSObject.Properties.Name -notcontains 'connection') { return $null }
    return $w.connection
}

function Format-Connection($c) {
    if ($null -eq $c) { return '(none)' }
    return ($c | ConvertTo-Json -Compress)
}

function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) for the app and its
    # sibling agent - the private copies each filtered differently. The extra
    # process below is this script's own litter, so it stays local.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 0)
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-relay-e2e.exe'" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

Stop-TestProcs

# T441: this run's own IPC endpoint, before any CLI call - otherwise the
# Run-Cli calls below inherit the caller pane's baked `$GHOZTTY_IPC_SOCKET` and
# open relay windows in (and +send-keys into) the user's installed release.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ipcrelay')
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== 0a: build + start a local relay (DEV_AUTH)"
Push-Location $RelaySrc
& go build -o "$tmp\ghoztty-relay-e2e.exe" . 2>&1 | Select-Object -Last 3
$goExit = $LASTEXITCODE
Pop-Location
Assert "relay builds" ($goExit -eq 0)
if ($goExit -ne 0) { "$($script:failures) FAILURE(S)"; exit 1 }

$env:LISTEN_ADDR = "127.0.0.1:$RelayPort"
$env:METRICS_ADDR = '127.0.0.1:0'
$env:DEV_AUTH = 'true'
$env:DEV_CLIENT_TOKEN = $DevToken
$env:DEV_EMAIL = 'dev@example.com'
$env:STATE_DIR = "$tmp\state"
$relay = Start-Process -FilePath "$tmp\ghoztty-relay-e2e.exe" -PassThru -WindowStyle Hidden
foreach ($k in 'LISTEN_ADDR','METRICS_ADDR','DEV_AUTH','DEV_CLIENT_TOKEN','DEV_EMAIL','STATE_DIR') {
    Remove-Item "env:$k" -ErrorAction SilentlyContinue
}

$healthy = $false
foreach ($i in 1..20) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri "$RelayBase/healthz" -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $healthy = $true; break }
    } catch { Start-Sleep -Milliseconds 500 }
}
Assert "relay is healthy" $healthy
if (-not $healthy) { Stop-TestProcs; "$($script:failures) FAILURE(S)"; exit 1 }

"== 0b: enroll a device + start a loopback agent in --relay mode"
$dev = $null
try {
    $dev = Invoke-RestMethod -Method Post -Uri "$RelayBase/v1/client/devices" `
        -Headers @{ Authorization = "Bearer $DevToken" } `
        -ContentType 'application/json' -Body '{"name":"e2e-device"}'
} catch {}
Assert "device enrolled (id + token)" ($null -ne $dev -and $dev.id -and $dev.token)
if ($null -eq $dev) { Stop-TestProcs; "$($script:failures) FAILURE(S)"; exit 1 }

# Env token wins over the box's real relay.env; heartbeat redirected so this
# harness agent never touches the installed agent's per-user state.
#
# T1105: GHOZTTY_AGENT_INSTANCE forks this agent onto its own single-instance
# guard, pipe and state dir (T167). Without it the harness agent claims the
# LEGACY relay singleton `Global\GhozttyAgentDaemon-<SID>` - the same name the
# box's own relay agent and every other relay harness compete for - so a leaked
# agent from an earlier script could take this one over mid-run, or be taken
# over by it. Every sibling relay harness (agent-relay-session-e2e,
# agent-sharing-uplink, ipc-remote, remote-inherit) already forks its lineage;
# this one was the last that did not. Its stdout/stderr go to files so an agent
# that dies has something to say for itself.
# T368 factored the launch into a function: section 6b starts a SECOND agent on
# the same lineage (same GHOZTTY_AGENT_INSTANCE, same device token, same
# heartbeat file) after killing the first. A restarted agent that differs in any
# of those is not the same machine coming back, it is a different one, and the
# reconnect claim would be measuring the wrong thing.
function Start-HarnessAgent($tag) {
    $savedAgentInstance = $env:GHOZTTY_AGENT_INSTANCE
    $env:GHOZTTY_AGENT_INSTANCE = "ipcrelay$PID"
    $env:GHOSTTY_DEVICE_TOKEN = $dev.token
    $env:GHOSTTY_AGENT_HEARTBEAT = "$tmp\agent.heartbeat"
    $p = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$tmp\$tag.out" -RedirectStandardError "$tmp\$tag.err" `
        -ArgumentList "--relay=$RelayBase", "--headless"
    $null = $p.Handle   # before any HasExited/ExitCode read (lib\ExitCodeAudit.ps1)
    if ($null -eq $savedAgentInstance) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $savedAgentInstance }
    Remove-Item env:GHOSTTY_DEVICE_TOKEN -ErrorAction SilentlyContinue
    Remove-Item env:GHOSTTY_AGENT_HEARTBEAT -ErrorAction SilentlyContinue
    return $p
}

$agent = Start-HarnessAgent 'agent'
Start-Sleep -Seconds 3
Assert "agent is running" (-not $agent.HasExited)
if ($agent.HasExited) {
    "    agent exited $($agent.ExitCode) (183 = another instance holds the guard)"
    foreach ($f in 'agent.out', 'agent.err') {
        $t = (Get-Out $f)
        if (-not [string]::IsNullOrWhiteSpace($t)) {
            "    $($f):"; ($t.TrimEnd() -split "`r?`n" | Select-Object -Last 8 | ForEach-Object { "       $_" })
        }
    }
    Stop-TestProcs
    Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue
    "$($script:failures) FAILURE(S)"; exit 1
}

"== 0c: base local window"
# SETUP, not a claim about the relay: sections 1-7 all need a live app to open
# relay windows in, so a failure here is one fault and everything after it is
# noise. T1105: the 2026-08-22 sweep reported `14 FAILURE(S)` from exactly this
# shape - 0c failed, thirteen doomed assertions followed, and the count sent
# triage looking for fourteen defects. Bail here the way 0a and 0b do.
$code = Run-Cli '+new-window --target=relbase' 'base.txt'
Assert "base window exit 0" ($code -eq 0)
if ($code -ne 0) {
    Show-LastCli
    "  ABORTING: the base window is SETUP - every assertion below needs a live app."
    Stop-TestProcs
    Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue
    "$($script:failures) FAILURE(S)"; exit 1
}
Start-Sleep -Seconds 2
# T1105: prove an instance ANSWERS before asserting whose it is.
# Assert-GhozttyIsolated passes vacuously against a dead endpoint - it looks for
# a foreign `"exe"` and the caller's pane id, and "No running Ghoztty instance
# found." contains neither. In the sweep it printed PASS one line under the 0c
# failure, which read as "an app is up, the launch just returned nonzero" and is
# the opposite of what had happened.
$listRaw = Get-GhozttyListRaw -Exe $Exe
Assert "an instance is actually answering (the isolation check below is not vacuous)" (
    $listRaw -notmatch 'No running Ghoztty')
if ($listRaw -match 'No running Ghoztty') {
    "    +list answered: $($listRaw.Trim())"
    "  ABORTING: nothing is listening on $($env:GHOZTTY_PIPE_SUFFIX)."
    Stop-TestProcs
    Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue
    "$($script:failures) FAILURE(S)"; exit 1
}
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe

"== 1: relay dial + open (happy path)"
$code = Run-Cli "+new-remote-window --relay=$RelayBase --device=$($dev.id) --token=$DevToken --name=relwin" 'open.txt' 30
Assert "exit 0" ($code -eq 0)
if ($code -ne 0) { Show-LastCli }
Start-Sleep -Seconds 2
$code = Run-Cli '+list' 'list1.txt'
Assert "relay window registered under --name" ((Get-Out 'list1.txt') -match '\[target: relwin\]')

"== 1b: +list --json publishes the remote window's connection state (T609)"
# The oracle T368 asserts the reconnect ladder against. Before this the ONLY way
# to read a remote window's link health from outside the process was to grep the
# app log, which is a side effect of the implementation rather than a contract.
Run-Cli '+list --json' 'list1json.txt' | Out-Null
$j1 = $null
try { $j1 = (Get-Out 'list1json.txt') | ConvertFrom-Json } catch { }
$relwin = $null; $relbase = $null
if ($j1 -and $j1.data -and $j1.data.windows) {
    $relwin  = $j1.data.windows | Where-Object { $_.target -eq 'relwin' }  | Select-Object -First 1
    $relbase = $j1.data.windows | Where-Object { $_.target -eq 'relbase' } | Select-Object -First 1
}
Assert "the relay window is in +list --json" ($null -ne $relwin)
Assert "it reports connection.state = connected" (
    $null -ne $relwin -and $relwin.PSObject.Properties.Name -contains 'connection' -and
    $relwin.connection.state -eq 'connected')
# A healthy link carries neither of the conditional fields: a value that is
# meaningless in a state is absent, not emitted empty.
Assert "a connected window reports no attempt and no self_healable" (
    $null -ne $relwin -and $null -ne $relwin.connection -and
    ($relwin.connection.PSObject.Properties.Name -notcontains 'attempt') -and
    ($relwin.connection.PSObject.Properties.Name -notcontains 'self_healable'))
# Absence is what distinguishes a local window; there is no "state": "local".
Assert "the LOCAL base window has no connection field at all" (
    $null -ne $relbase -and $relbase.PSObject.Properties.Name -notcontains 'connection')
if ($null -eq $relwin -or $relwin.connection.state -ne 'connected') {
    "    +list --json said: $((Get-Out 'list1json.txt').Trim())"
}

"== 2: terminal round-trip through relay + agent"
$code = Run-Cli '+send-keys --target=relwin "echo relay-roundtrip-ok" Enter' 'sk.txt'
Assert "send-keys exit 0" ($code -eq 0)
if ($code -ne 0) { Show-LastCli }
Start-Sleep -Seconds 3
$code = Run-Cli '+read --name=relwin --lines=40' 'read1.txt'
Assert "remote output visible via +read" ((Get-Out 'read1.txt') -match 'relay-roundtrip-ok')

"== 3: --command runs through the remote shell"
$code = Run-Cli "+new-remote-window --relay=$RelayBase --device=$($dev.id) --token=$DevToken --name=relcmd `"--command=echo relay-cmd-marker`"" 'opencmd.txt' 30
Assert "exit 0" ($code -eq 0)
if ($code -ne 0) { Show-LastCli }
Start-Sleep -Seconds 3
$code = Run-Cli '+read --name=relcmd --lines=40' 'read2.txt'
Assert "command output visible" ((Get-Out 'read2.txt') -match 'relay-cmd-marker')
Run-Cli '+close --target=relcmd' 'closecmd.txt' | Out-Null

"== 4: tokenless relay dial is refused with sign-in guidance"
$savedTok = $env:GHOSTTY_RELAY_TOKEN
$env:GHOSTTY_RELAY_TOKEN = $null
$code = Run-Cli "+new-remote-window --relay=$RelayBase --device=$($dev.id) --name=reltokenless" 'notoken.txt'
$env:GHOSTTY_RELAY_TOKEN = $savedTok
Assert "exit nonzero" ($code -ne 0 -and $null -ne $code)
Assert "error says not signed in" ((Get-Out 'notoken.txt') -match 'not signed in')
if (-not ((Get-Out 'notoken.txt') -match 'not signed in')) { Show-LastCli }

"== 5: bad token fails the dial with the Mac-parity error"
$code = Run-Cli "+new-remote-window --relay=$RelayBase --device=$($dev.id) --token=wrong-token --name=relbad" 'badtok.txt' 30
Assert "exit nonzero" ($code -ne 0 -and $null -ne $code)
Assert "error names device via relay" ((Get-Out 'badtok.txt') -match [regex]::Escape("failed to reach $($dev.id) via relay"))
if (-not ((Get-Out 'badtok.txt') -match [regex]::Escape("failed to reach $($dev.id) via relay"))) { Show-LastCli }

"== 6: agent killed under a live relay window => GUI keeps answering (no hang)"
# T368: the pre-drop thread baseline, sampled while the link is still healthy.
# Section 7 reads it back after +close - a connection that is dropped, re-dialed
# and then torn down must not leave its transport threads behind. Max of three
# samples, because a GUI process's pool workers come and go and the claim is
# about a LEAK, not about hitting one number.
$threadsBefore = 0
foreach ($i in 1..3) {
    $n = Get-AppThreadCount
    if ($n -gt $threadsBefore) { $threadsBefore = $n }
    Start-Sleep -Milliseconds 300
}
"  app thread baseline before the drop: $threadsBefore"

Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$code = Run-Cli '+list' 'list2.txt' 15
Assert "+list still answers after agent death" ($null -ne $code -and $code -eq 0)
if ($code -ne 0) { Show-LastCli }
Assert "app still alive (base window listed)" ((Get-Out 'list2.txt') -match '\[target: relbase\]')

# T609: the field TRACKS the drop rather than being a constant.
#
# T1276 tightened this from "has left `connected`" to the state the ladder is
# actually supposed to be in three seconds after a drop: `reconnecting`, or a
# `disconnected` that is still SELF-HEALABLE. The loose version accepted the
# defect - a terminal `{"state":"disconnected","self_healable":false}` at t+3s,
# which is the ladder giving up before it has dialed once - and stayed green
# through it for as long as it existed. `self_healable:false` this early is the
# one reading that means "nothing will bring this window back", and nothing
# reachable in three seconds justifies it.
#
# The full connected -> reconnecting(N) -> connected walk, and the 401 rule that
# is allowed to be terminal, are `test\win32\remote-reconnect-relay.ps1`'s.
Run-Cli '+list --json' 'list2json.txt' 15 | Out-Null
$j2 = $null
try { $j2 = (Get-Out 'list2json.txt') | ConvertFrom-Json } catch { }
$dropped = $null
if ($j2 -and $j2.data -and $j2.data.windows) {
    $dropped = $j2.data.windows | Where-Object { $_.target -eq 'relwin' } | Select-Object -First 1
}
Assert "connection.state left 'connected' once the agent died" (
    $null -ne $dropped -and $null -ne $dropped.connection -and
    $dropped.connection.state -in @('reconnecting', 'disconnected'))
Assert "and the window is still recoverable (climbing, or waiting on a re-dial)" (
    $null -ne $dropped -and $null -ne $dropped.connection -and (
        $dropped.connection.state -eq 'reconnecting' -or
        $dropped.connection.self_healable -eq $true))
if ($null -ne $dropped -and $null -ne $dropped.connection) {
    "    connection: $($dropped.connection | ConvertTo-Json -Compress)"
}

"== 6b: agent RESTARTED under the dead relay window => the ladder settles (T368)"
# T368's own clause, verbatim: "kill + restart the agent under a LIVE remote
# window, then assert the pane comes back (re-ATTACH) or reports a clear
# disconnected state - no hang, no crash, no orphan connection threads."
#
# The disjunction is deliberate and it is the whole contract. What must NOT
# happen is the third thing: a window that sits in `reconnecting` forever, or
# vanishes, or takes the GUI down with it. So the assertion is that the ladder
# reaches a DEFINITE verdict inside a budget that covers it, and that whichever
# verdict it reaches is internally consistent and backed by the window actually
# working (the connected arm is proved with a round-trip, not with a field).
#
# Budget: the fast ladder is 5 attempts at 1/2/4/8/15s (~30s from the drop), and
# an exhausted ladder arms a background re-dial every 45s. 150s covers the fast
# pass plus two slow re-dials, so a slow recovery reads as a recovery and not as
# a failure.
#
# Which arm this box takes TODAY is the disconnected one, and T1278 is why: a
# hard-killed `--listen` agent loses its session records, so the restarted agent
# reaps the still-live PTY holder as an orphan and the ladder is told
# `session_gone`. That is a real defect with its own task; it is NOT this
# script's subject, and hard-coding either arm here would make the harness go
# red the day T1278 is fixed and the window starts coming back instead.
$agent2 = Start-HarnessAgent 'agent2'
Start-Sleep -Seconds 3
Assert "restarted agent is running" (-not $agent2.HasExited)
if ($agent2.HasExited) {
    "    agent2 exited $($agent2.ExitCode) (183 = another instance holds the guard)"
    foreach ($f in 'agent2.out', 'agent2.err') {
        $t = (Get-Out $f)
        if (-not [string]::IsNullOrWhiteSpace($t)) {
            "    $($f):"; ($t.TrimEnd() -split "`r?`n" | Select-Object -Last 8 | ForEach-Object { "       $_" })
        }
    }
}

$settled = $null
$seen = @()
$stalled = $false
$sw6b = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw6b.Elapsed.TotalSeconds -lt 150) {
    $c = Get-Connection 'relwin' 'list6b.txt' 15
    if ($null -eq $c) {
        # Either the CLI stopped answering or the window left +list --json.
        # Both are failures of this section and neither is worth waiting out.
        $stalled = $true
        break
    }
    $desc = Format-Connection $c
    if ($seen -notcontains $desc) { $seen += $desc; "  t+$([math]::Round($sw6b.Elapsed.TotalSeconds))s $desc" }
    if ($c.state -ne 'reconnecting') { $settled = $c; break }
    Start-Sleep -Seconds 3
}
$sw6b.Stop()

Assert "the relay window kept answering +list --json throughout the restart" (-not $stalled)
if ($stalled) { Show-LastCli }
Assert "the app survived the kill + restart (no crash)" ($null -ne (Get-AppProc))
Assert "the ladder settled on a definite verdict within 150s (not stuck reconnecting)" (
    $null -ne $settled)
if ($null -eq $settled) { "    last states seen: $($seen -join ' -> ')" }

if ($null -ne $settled -and $settled.state -eq 'connected') {
    # The re-ATTACH arm. A field is not a working window, so prove it the way
    # section 2 proved the original link: drive the remote shell and read it back.
    "  arm: RE-ATTACHED after $([math]::Round($sw6b.Elapsed.TotalSeconds))s"
    Assert "a re-connected window reports no attempt count" (
        $settled.PSObject.Properties.Name -notcontains 'attempt')
    $code = Run-Cli '+send-keys --target=relwin "echo relay-reattach-ok" Enter' 'sk2.txt'
    Assert "send-keys through the restored link exits 0" ($code -eq 0)
    if ($code -ne 0) { Show-LastCli }
    Start-Sleep -Seconds 3
    $code = Run-Cli '+read --name=relwin --lines=40' 'read3.txt'
    Assert "the re-attached pane echoes through the new transport" (
        (Get-Out 'read3.txt') -match 'relay-reattach-ok')
} elseif ($null -ne $settled) {
    # The clear-disconnected arm. "Clear" is the assertion: a disconnected
    # window has to say whether anything will ever bring it back, because that
    # is the difference between the status pill telling the user to wait and
    # telling them to act.
    "  arm: DISCONNECTED after $([math]::Round($sw6b.Elapsed.TotalSeconds))s (T1278: the restarted agent reaps the holder)"
    Assert "the verdict is 'disconnected', not some third state" ($settled.state -eq 'disconnected')
    Assert "and it says whether the window is self-healable" (
        $settled.PSObject.Properties.Name -contains 'self_healable' -and
        $settled.self_healable -is [bool])
    Assert "a disconnected window reports no attempt count" (
        $settled.PSObject.Properties.Name -notcontains 'attempt')
}

"== 7: +close tears the dead relay window down cleanly (no hang)"
$code = Run-Cli '+close --target=relwin' 'close1.txt' 20
Assert "close exit 0 within timeout" ($code -eq 0)
if ($code -ne 0) { Show-LastCli }
Start-Sleep -Seconds 2
$code = Run-Cli '+list' 'list3.txt' 15
Assert "relay window gone" (-not ((Get-Out 'list3.txt') -match '\[target: relwin\]'))
Assert "app survived the teardown" ((Get-Out 'list3.txt') -match '\[target: relbase\]')

# T368: no orphan connection threads. The window under test dropped its
# transport, ran a ladder that dialed more of them, and has now been closed - so
# every transport it ever held is retired and freed, and the process must be
# back where it started. This is the check that a retired transport being "shut
# down off-thread" actually finishes: a leak here is invisible to every other
# assertion in this file, and it accumulates one window at a time in a terminal
# people leave open for days.
#
# Retirement is asynchronous by design, so this waits rather than sampling once.
$threadsAfter = -1
$swT = [System.Diagnostics.Stopwatch]::StartNew()
while ($swT.Elapsed.TotalSeconds -lt 45) {
    $threadsAfter = Get-AppThreadCount
    if ($threadsAfter -ge 0 -and $threadsAfter -le $threadsBefore) { break }
    Start-Sleep -Seconds 2
}
$swT.Stop()
"  app threads: $threadsBefore before the drop -> $threadsAfter after +close"
Assert "no connection threads left behind after +close (<= the pre-drop baseline)" (
    $threadsAfter -ge 0 -and $threadsAfter -le $threadsBefore)

"== cleanup"
Run-Cli '+close --target=relbase' 'closebase.txt' | Out-Null
Stop-TestProcs
if ($agent2) { Stop-Process -Id $agent2.Id -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone - red stays due. T368 added the row: before it, nothing tied an edit to
# RemoteReconnect.zig or the relay dial to running the harness that owns the
# ladder end to end.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard ipc-relay 2>&1 | ForEach-Object { "  $_" }
}

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
