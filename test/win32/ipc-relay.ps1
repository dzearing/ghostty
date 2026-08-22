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
# hang/crash), +close teardown.
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
function Run-Cli($argsLine, $outfile, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$tmp\$outfile`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}

function Get-Out($outfile) {
    if (Test-Path "$tmp\$outfile") { Get-Content "$tmp\$outfile" -Raw } else { '' }
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

# T441: this run's own IPC endpoint, before any CLI call — otherwise the
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
$env:GHOSTTY_DEVICE_TOKEN = $dev.token
$env:GHOSTTY_AGENT_HEARTBEAT = "$tmp\agent.heartbeat"
$agent = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
    -ArgumentList "--relay=$RelayBase", "--headless"
Remove-Item env:GHOSTTY_DEVICE_TOKEN -ErrorAction SilentlyContinue
Remove-Item env:GHOSTTY_AGENT_HEARTBEAT -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Assert "agent is running" (-not $agent.HasExited)

"== 0c: base local window"
$code = Run-Cli '+new-window --target=relbase' 'base.txt'
Assert "base window exit 0" ($code -eq 0)
Start-Sleep -Seconds 2
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe

"== 1: relay dial + open (happy path)"
$code = Run-Cli "+new-remote-window --relay=$RelayBase --device=$($dev.id) --token=$DevToken --name=relwin" 'open.txt' 30
Assert "exit 0" ($code -eq 0)
Start-Sleep -Seconds 2
$code = Run-Cli '+list' 'list1.txt'
Assert "relay window registered under --name" ((Get-Out 'list1.txt') -match '\[target: relwin\]')

"== 2: terminal round-trip through relay + agent"
$code = Run-Cli '+send-keys --target=relwin "echo relay-roundtrip-ok" Enter' 'sk.txt'
Assert "send-keys exit 0" ($code -eq 0)
Start-Sleep -Seconds 3
$code = Run-Cli '+read --name=relwin --lines=40' 'read1.txt'
Assert "remote output visible via +read" ((Get-Out 'read1.txt') -match 'relay-roundtrip-ok')

"== 3: --command runs through the remote shell"
$code = Run-Cli "+new-remote-window --relay=$RelayBase --device=$($dev.id) --token=$DevToken --name=relcmd `"--command=echo relay-cmd-marker`"" 'opencmd.txt' 30
Assert "exit 0" ($code -eq 0)
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

"== 5: bad token fails the dial with the Mac-parity error"
$code = Run-Cli "+new-remote-window --relay=$RelayBase --device=$($dev.id) --token=wrong-token --name=relbad" 'badtok.txt' 30
Assert "exit nonzero" ($code -ne 0 -and $null -ne $code)
Assert "error names device via relay" ((Get-Out 'badtok.txt') -match [regex]::Escape("failed to reach $($dev.id) via relay"))

"== 6: agent killed under a live relay window => GUI keeps answering (no hang)"
Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$code = Run-Cli '+list' 'list2.txt' 15
Assert "+list still answers after agent death" ($null -ne $code -and $code -eq 0)
Assert "app still alive (base window listed)" ((Get-Out 'list2.txt') -match '\[target: relbase\]')

"== 7: +close tears the dead relay window down cleanly (no hang)"
$code = Run-Cli '+close --target=relwin' 'close1.txt' 20
Assert "close exit 0 within timeout" ($code -eq 0)
Start-Sleep -Seconds 2
$code = Run-Cli '+list' 'list3.txt' 15
Assert "relay window gone" (-not ((Get-Out 'list3.txt') -match '\[target: relwin\]'))
Assert "app survived the teardown" ((Get-Out 'list3.txt') -match '\[target: relbase\]')

"== cleanup"
Run-Cli '+close --target=relbase' 'closebase.txt' | Out-Null
Stop-TestProcs
Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
