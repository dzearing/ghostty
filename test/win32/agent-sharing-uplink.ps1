# Sharing uplink acceptance (T546): the consolidated local agent raises the
# relay control loop IN-PROCESS when sharing.json says so, over the same
# store the local pipe serves.
#
#   powershell -NoProfile -File test\win32\agent-sharing-uplink.ps1
#
# Covers: a --listen-pipe agent with NO sharing.json never dials (negative
# control); writing {"enabled":true} beside sessions.json raises the uplink
# hot (a real `GET /v1/agent/control` with the relay.env Bearer token arrives
# at a loopback listener); {"enabled":false} parks it (the dial stream stops);
# an agent started with sharing already enabled dials without any toggle; and
# sharing enabled with NO relay.env credential degrades to local-only with one
# explanatory line, the pipe still served.
#
# Hermetic: GHOZTTY_AGENT_INSTANCE forks the single-instance guard, the pipe
# name is test-unique, GHOSTTY_RELAY_ENV points the credential lookup at a
# scratch file, and the state dir lives under $env:TEMP. The "relay" is a raw
# loopback TCP listener that logs each request and answers 404 - the agent
# treats that as a dial failure and redials on its base backoff, which is
# exactly the evidence stream the assertions read.
param(
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:passes = 0
$script:failures = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t546-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$stateDir = Join-Path $tmp 'agent-state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$portFile = Join-Path $stateDir 'port.json'
$sessFile = Join-Path $stateDir 'sessions.json'
$sharingFile = Join-Path $stateDir 'sharing.json'
$relayEnv = Join-Path $tmp 'relay.env'
$dialLog = Join-Path $tmp 'dials.log'
$portOut = Join-Path $tmp 'listener-port.txt'
$pipe = "\\.\pipe\ghoztty-agent-t546-$PID"
$token = "tok-t546-$PID"

if (-not (Test-Path $AgentExe)) {
    "SKIP whole run: $AgentExe not built (zig build agent first)"
    Write-TestVerdict -Label 'T546 SHARING UPLINK' -Pass 0 -Fail 0 -Skipped 1
}

function Stop-TestAgents {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*t546*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
}

function Start-TestAgent($outFile, $errFile) {
    $p = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList "--listen-pipe=$pipe", "--port-file=$portFile", "--sessions-file=$sessFile", '--headless'
    $null = $p.Handle   # cache before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    return $p
}

# Read a file that a live process may hold open for writing (Start-Process
# redirect targets): plain ReadAllText throws a sharing violation there, so
# open with FileShare ReadWrite. Returns '' when unreadable/absent.
function Read-Shared($file) {
    if (-not (Test-Path $file)) { return '' }
    try {
        $fs = [System.IO.FileStream]::new($file, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

# Wait until a file contains $pattern (regex), up to $timeoutSec. Returns bool.
function Wait-ForText($file, $pattern, $timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-Shared $file) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-DialCount {
    return ([regex]::Matches((Read-Shared $dialLog), 'GET /v1/agent/control')).Count
}

"== 0: loopback 'relay' listener + scratch credential"
Stop-TestAgents
$listener = Start-Job -ScriptBlock {
    param($logPath, $portPath)
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $port = $l.LocalEndpoint.Port
    Set-Content -Path $portPath -Value $port -Encoding ascii
    while ($true) {
        $client = $l.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 1500
            $stream = $client.GetStream()
            Start-Sleep -Milliseconds 300   # let the request land
            $buf = New-Object byte[] 8192
            $text = ''
            while ($stream.DataAvailable) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $text += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
            }
            if ($text.Length -gt 0) { Add-Content -Path $logPath -Value $text -Encoding ascii }
            $resp = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`n`r`n")
            $stream.Write($resp, 0, $resp.Length)
        } catch {}
        try { $client.Close() } catch {}
    }
} -ArgumentList $dialLog, $portOut
$gotPort = Wait-ForText $portOut '\d' 10
Assert 'loopback listener came up' $gotPort
if (-not $gotPort) {
    Stop-Job $listener -ErrorAction SilentlyContinue; Remove-Job $listener -Force -ErrorAction SilentlyContinue
    Write-TestVerdict -Label 'T546 SHARING UPLINK' -Pass $script:passes -Fail ($script:failures + 1)
}
$relayPort = (Get-Content $portOut | Select-Object -First 1).Trim()
# http:// maps to plaintext ws:// - the loopback-test rule shared with ws_client.
Set-Content -Path $relayEnv -Value "RELAY_BASE=http://127.0.0.1:$relayPort`nDEVICE_TOKEN=$token" -Encoding ascii

$env:GHOZTTY_AGENT_INSTANCE = "t546$PID"
$env:GHOSTTY_RELAY_ENV = $relayEnv
try {
    "== 1: no sharing.json - agent serves the pipe and never dials (negative control)"
    $agent = Start-TestAgent "$tmp\a1.out" "$tmp\a1.err"
    Assert 'agent came up (port.json)' (Wait-ForText $portFile 'pipe' 15)
    Assert 'agent is running' (-not $agent.HasExited)
    Start-Sleep -Seconds 8
    Assert 'no relay dial without sharing.json' ((Get-DialCount) -eq 0)
    Assert 'no sharing chatter when unconfigured' ((Read-Shared "$tmp\a1.err") -notmatch 'sharing')

    "== 2: hot enable - writing sharing.json raises the uplink in-process"
    Set-Content -Path $sharingFile -Value '{"version":1,"enabled":true}' -Encoding ascii
    Assert 'agent announced the raise' (Wait-ForText "$tmp\a1.err" 'relay uplink raised' 20)
    Assert 'control dial reached the relay' (Wait-ForText $dialLog 'GET /v1/agent/control' 20)
    Assert 'dial authenticated with the relay.env token' (Wait-ForText $dialLog "Bearer $token" 5)

    "== 3: hot disable - the uplink parks and the dial stream stops"
    Set-Content -Path $sharingFile -Value '{"version":1,"enabled":false}' -Encoding ascii
    Assert 'agent announced the park' (Wait-ForText "$tmp\a1.err" 'sharing disabled; parking' 20)
    Start-Sleep -Seconds 6   # drain any dial already in flight/backoff
    $parkedCount = Get-DialCount
    Start-Sleep -Seconds 8   # well past the 3s base backoff: a live loop would redial
    Assert 'no new dials while parked' ((Get-DialCount) -eq $parkedCount)
    Assert 'agent survived the toggle cycle' (-not $agent.HasExited)
    Stop-TestAgents

    "== 4: enabled at startup - dials with no toggle (synchronous first reconcile)"
    Remove-Item $portFile -ErrorAction SilentlyContinue
    $preCount = Get-DialCount
    Set-Content -Path $sharingFile -Value '{"version":1,"enabled":true}' -Encoding ascii
    $agent2 = Start-TestAgent "$tmp\a2.out" "$tmp\a2.err"
    Assert 'agent came up sharing-enabled' (Wait-ForText $portFile 'pipe' 15)
    Assert 'uplink raised at startup' (Wait-ForText "$tmp\a2.err" 'relay uplink raised' 20)
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and (Get-DialCount) -le $preCount) { Start-Sleep -Milliseconds 500 }
    Assert 'startup-enabled agent dialed' ((Get-DialCount) -gt $preCount)
    Stop-TestAgents

    "== 5: enabled but no credential - local-only with one explanatory line"
    Remove-Item $portFile -ErrorAction SilentlyContinue
    Remove-Item $relayEnv -ErrorAction SilentlyContinue
    $agent3 = Start-TestAgent "$tmp\a3.out" "$tmp\a3.err"
    Assert 'credential-less agent still serves the pipe' (Wait-ForText $portFile 'pipe' 15)
    Assert 'agent explains why the uplink is down' (Wait-ForText "$tmp\a3.err" 'uplink cannot start' 15)
    Start-Sleep -Seconds 6
    Assert 'explanation is said once, not per tick' (([regex]::Matches((Read-Shared "$tmp\a3.err"), 'uplink cannot start')).Count -eq 1)
    Assert 'credential-less agent is still running' (-not $agent3.HasExited)
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-TestAgents
    Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
    Remove-Item env:GHOSTTY_RELAY_ENV -ErrorAction SilentlyContinue
    Stop-Job $listener -ErrorAction SilentlyContinue
    Remove-Job $listener -Force -ErrorAction SilentlyContinue
}

# A clean green run stamps the files this harness covers (T783), so
# `scripts\guard-due.ps1` can answer "has anybody run this against the code as it
# now stands?". It was in that coverage table from the start but had no stamp
# call, which meant the guard went DUE on the first `main.zig` edit and could
# never come back - the one shape a staleness gate must not have, since a guard
# that is permanently red is a guard everybody learns to step over.
if ($script:failures -eq 0 -and $script:passes -ge 18) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-sharing-uplink -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

# MinPass = the full-run assertion count: an abort (exception past section N
# jumping to finally) must never score the truncated run as ALL PASS.
Write-TestVerdict -Label 'T546 SHARING UPLINK' -Pass $script:passes -Fail $script:failures -MinPass 18
