# Agent named-pipe listener acceptance (tracker T89c): the local session-
# persistence transport on Windows. Starts a real ghoztty-agent in the new
# --listen-pipe mode, drives it with a scratch client (remote-test-client over
# the pipe), and enumerates sessions with the real `ghoztty +sessions` CLI
# dialing the SAME pipe (app closed). Non-interactive; asserts and exits nonzero
# on any failure. Only touches ghoztty processes from the repo zig-out, under a
# hermetic $env:LOCALAPPDATA so it never reads/writes a real agent's state.
#
#   powershell -NoProfile -File test\win32\agent-pipe.ps1
#
# Covers: pipe bind + port.json {pipe} shape, +sessions over the pipe with no
# sessions (text + --json), a held scratch session enumerated alive+attached,
# session SURVIVES the viewer detaching (still listed, detached), session-scoped
# CLOSE removes it AND answers inside the RPC timeout (T96), agent death =>
# +sessions fails gracefully (no hang/crash).
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$ClientExe = 'D:\git\ghoztty\zig-out\bin\remote-test-client.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-agent-pipe-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# isolation: none - `+sessions` dials the AGENT pipe it finds via
# %LOCALAPPDATA%\ghoztty\local-agent-debug\port.json, never the app IPC
# endpoint, and LOCALAPPDATA is redirected to $tmp below with a per-PID pipe
# name - so the user's agent and app are unreachable by construction. An app
# pipe suffix would isolate an endpoint this script never dials (T680).

# The debug ghoztty +sessions CLI reads %LOCALAPPDATA%\ghoztty\local-agent-debug\
# port.json. Point LOCALAPPDATA at our tmp so the test is fully hermetic (never
# touches a real local agent) and the agent's --port-file lands where the CLI looks.
$savedLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $tmp
$stateDir = Join-Path $tmp 'ghoztty\local-agent-debug'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$portFile = Join-Path $stateDir 'port.json'
$sessFile = Join-Path $stateDir 'sessions.json'
$pipe = "\\.\pipe\ghoztty-agent-t89c-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Run ghoztty +sessions with a hard timeout (a wedged agent must never hang the
# script — that is a failure mode under test). Returns the exit code, or $null on
# timeout. Output (stdout+stderr) lands in $tmp\$outfile.
function Run-Cli($argsLine, $outfile, $timeoutSec = 15) {
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
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='remote-test-client.exe'" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

Stop-TestProcs

"== 0: start a ghoztty-agent in --listen-pipe mode"
# --force-replace + a redirected heartbeat keep this hermetic: the pipe agent
# shares the per-user single-instance guard with any relay agent, so force-replace
# guarantees we win it, and the redirected heartbeat never touches real state.
$env:GHOSTTY_AGENT_HEARTBEAT = "$tmp\agent.heartbeat"
$agent = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
    -ArgumentList "--listen-pipe=$pipe", "--port-file=$portFile", "--sessions-file=$sessFile", "--headless", "--force-replace"
Remove-Item env:GHOSTTY_AGENT_HEARTBEAT -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Assert "agent is running" (-not $agent.HasExited)

"== 1: agent published port.json with the additive {pipe} field"
Assert "port.json exists" (Test-Path $portFile)
$info = $null
try { $info = Get-Content $portFile -Raw | ConvertFrom-Json } catch {}
Assert "port.json is valid JSON" ($null -ne $info)
Assert "port is 0 (a pipe has no port)" ($null -ne $info -and $info.port -eq 0)
Assert "pipe field matches the bound name" ($null -ne $info -and $info.pipe -eq $pipe)
Assert "pid recorded" ($null -ne $info -and $info.pid -gt 0)

"== 2: +sessions over the pipe with no sessions"
$code = Run-Cli '+sessions' 'empty.txt'
Assert "+sessions exit 0" ($code -eq 0)
Assert "+sessions reports no sessions" ((Get-Out 'empty.txt') -match 'No sessions')
$code = Run-Cli '+sessions --json' 'emptyjson.txt'
Assert "+sessions --json exit 0" ($code -eq 0)
Assert "+sessions --json is an empty array" ((Get-Out 'emptyjson.txt').Trim() -match '^\[\s*\]$')

"== 3: scratch client OPENs a session and holds it; +sessions enumerates it"
# Hold long enough to run the attached-state checks before it detaches.
$client = Start-Process -FilePath $ClientExe -PassThru -WindowStyle Hidden `
    -ArgumentList "--pipe=$pipe", "--hold=12" `
    -RedirectStandardOutput "$tmp\client.out" -RedirectStandardError "$tmp\client.err"
Start-Sleep -Seconds 3
$sid = ((Get-Out 'client.out') -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{8,}$' } | Select-Object -First 1)
Assert "scratch client printed a session id" ($null -ne $sid -and $sid.Length -ge 8)

$code = Run-Cli '+sessions' 'one.txt'
Assert "+sessions exit 0 (one session)" ($code -eq 0)
Assert "session id listed" ((Get-Out 'one.txt') -match [regex]::Escape($sid))
Assert "session listed as alive" ((Get-Out 'one.txt') -match 'alive')
Assert "session listed as attached" ((Get-Out 'one.txt') -match 'attached')

$code = Run-Cli '+sessions --json' 'onejson.txt'
$rows = $null
try { $rows = Get-Out 'onejson.txt' | ConvertFrom-Json } catch {}
Assert "+sessions --json parses to one row" ($null -ne $rows -and @($rows).Count -eq 1)
Assert "json row is the held session, alive+attached" (
    $null -ne $rows -and @($rows)[0].id -eq $sid -and @($rows)[0].alive -eq $true -and @($rows)[0].attached -eq $true)

"== 4: session SURVIVES the viewer detaching (still listed, now detached)"
# Wait for the hold to elapse; the client detaches (does NOT CLOSE), so the
# agent keeps the session alive with no viewer attached.
if (-not $client.WaitForExit(15000)) { Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
$code = Run-Cli '+sessions --json' 'survive.txt'
$rows = $null
try { $rows = Get-Out 'survive.txt' | ConvertFrom-Json } catch {}
Assert "session survived the viewer leaving" ($null -ne $rows -and @($rows).Count -eq 1 -and @($rows)[0].id -eq $sid)
Assert "session still alive but now detached" (
    $null -ne $rows -and @($rows)[0].alive -eq $true -and @($rows)[0].attached -eq $false)

"== 5: session-scoped CLOSE (over the pipe) removes it AND answers (T96)"
# CLOSE_SESSION unlinks the session from the store, terminates its ConPTY child,
# then replies CLOSE_SESSION_RESULT on the request channel. Both halves are
# asserted: the session is gone, AND the client got its answer.
#
# T96 was the second half missing. The reply reached the client's control reader
# and stopped there — `close_session_result` was the one A→C reply type with no
# arm in `handleControlInternal`, so the parked RPC never woke and every
# close-by-id burned the full 10 s timeout and then reported failure over a
# session the agent had already killed ~30 ms in. Hence the LATENCY bound below,
# not just an exit code: a re-broken dispatch fails the same way it did before,
# by taking the timeout, and only a bound catches that.
$sw = [Diagnostics.Stopwatch]::StartNew()
$closer = Start-Process -FilePath $ClientExe -PassThru -WindowStyle Hidden `
    -ArgumentList "--pipe=$pipe", "--close-session=$sid" `
    -RedirectStandardOutput "$tmp\close.out" -RedirectStandardError "$tmp\close.err"
$null = $closer.Handle   # cache the handle or ExitCode reads back empty (PS 5.1)
$closerExited = $closer.WaitForExit(15000)
$sw.Stop()
if (-not $closerExited) { Stop-Process -Id $closer.Id -Force -ErrorAction SilentlyContinue }
$closeErr = if (Test-Path "$tmp\close.err") { Get-Content "$tmp\close.err" -Raw } else { '' }
Assert "close-session client exited" $closerExited
Assert "close-session reported ok=true" ($closeErr -match "close-session $([regex]::Escape($sid)): ok=true")
# The client's own RPC timeout is 10 s, so anything at or past it is the T96
# shape. Measured after the fix: ~60 ms.
Assert "CLOSE_SESSION_RESULT arrived well inside the RPC timeout (T96)" (
    $closerExited -and $sw.ElapsedMilliseconds -lt 5000)
if ($sw.ElapsedMilliseconds -ge 5000) { "  NOTE: close-session took $($sw.ElapsedMilliseconds) ms" }
Start-Sleep -Seconds 1
$code = Run-Cli '+sessions --json' 'closed.txt'
$rows = $null
try { $rows = Get-Out 'closed.txt' | ConvertFrom-Json } catch {}
Assert "CLOSE over the pipe removed the session" ($null -ne $rows -and @($rows).Count -eq 0)
Assert "+sessions still answers after the CLOSE (agent not wedged)" ($code -eq 0)

"== 6: agent death => +sessions fails gracefully (no hang, no crash)"
Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$code = Run-Cli '+sessions' 'dead.txt'
Assert "+sessions returns (no hang) after agent death" ($null -ne $code)
Assert "+sessions exits nonzero" ($code -ne 0)
Assert "error message is graceful" ((Get-Out 'dead.txt') -match 'could not connect|did not answer|no local agent')

"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
