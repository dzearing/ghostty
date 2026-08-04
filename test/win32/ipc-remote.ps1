# Remote-window acceptance (tracker T20): +new-remote-window direct TCP
# against a debug build + a loopback ghoztty-agent. Non-interactive; asserts
# and exits nonzero on any failure. Only ever touches ghoztty processes
# running from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\ipc-remote.ps1
#
# Covers: dial + open window (happy path), terminal round-trip through the
# agent (send-keys -> read), --command forwarded into the agent OPEN,
# dial-failure error (no listener), tokenless relay-args refusal (T21b;
# the full relay path is covered by ipc-relay.ps1), +close teardown
# without wedging the app.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Port = 47901
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-remote-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: this run's own IPC endpoint, before any CLI call — otherwise every
# `& $Exe` inherits the caller pane's baked `$GHOZTTY_IPC_SOCKET` and the
# +new-remote-window calls below open windows in the user's installed release.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ipcrem')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Same app+agent kill as before, but exact-exe (a '*zig-out*' CommandLine
# match also catches a detached zig-out-release instance, T53b) and with the
# debug session-layout manifest dropped, which the private copy never did.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}

function Get-List {
    cmd /c "`"$Exe`" +list > `"$tmp\list.txt`" 2>&1" | Out-Null
    Get-Content "$tmp\list.txt" -Raw
}

function Read-Pane($name, $outfile) {
    cmd /c "`"$Exe`" +read --name=$name --lines=40 > `"$tmp\$outfile`" 2>&1" | Out-Null
    Get-Content "$tmp\$outfile" -Raw
}

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== 0: start a loopback agent + a base window"
# GHOSTTY_AGENT_LOCK: unique lock path so this harness agent never fights an
# installed/real agent's single-instance guard.
$env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
$agent = Start-Process -FilePath $AgentExe -ArgumentList "--listen", "127.0.0.1:$Port", "--headless" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
Assert "agent is running" (-not $agent.HasExited)

& $Exe +new-window --target=rembase 2>&1 | Out-Null
Assert "base window exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe

"== 1: +new-remote-window dial + open"
cmd /c "`"$Exe`" +new-remote-window --host=127.0.0.1 --port=$Port --name=rem > `"$tmp\open.txt`" 2>&1"
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$list = Get-List
Assert "remote window registered under --name" ($list -match '\[target: rem\]')

"== 2: terminal round-trip through the agent"
& $Exe +send-keys --target=rem "echo remote-roundtrip-ok" Enter 2>&1 | Out-Null
Assert "send-keys exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 3
$dump = Read-Pane 'rem' 'read-rem.txt'
Assert "remote output visible via +read" ($dump -match 'remote-roundtrip-ok')

"== 3: --command runs through the remote shell"
cmd /c "`"$Exe`" +new-remote-window --host=127.0.0.1 --port=$Port --name=remcmd `"--command=echo remote-cmd-marker`" > `"$tmp\opencmd.txt`" 2>&1"
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 3
$dump = Read-Pane 'remcmd' 'read-remcmd.txt'
Assert "command output visible" ($dump -match 'remote-cmd-marker')

"== 4: dial failure surfaces the Mac-parity error"
$deadPort = $Port + 1
cmd /c "`"$Exe`" +new-remote-window --host=127.0.0.1 --port=$deadPort --name=remdead > `"$tmp\dead.txt`" 2>&1"
Assert "exit nonzero" ($LASTEXITCODE -ne 0)
$err = Get-Content "$tmp\dead.txt" -Raw
Assert "error names the endpoint" ($err -match "failed to reach 127.0.0.1:$deadPort")

"== 5: tokenless relay args are refused with sign-in guidance (T21b)"
$savedTok = $env:GHOSTTY_RELAY_TOKEN
$env:GHOSTTY_RELAY_TOKEN = $null
cmd /c "`"$Exe`" +new-remote-window --relay=https://relay.example --device=dev1 > `"$tmp\relay.txt`" 2>&1"
$env:GHOSTTY_RELAY_TOKEN = $savedTok
Assert "exit nonzero" ($LASTEXITCODE -ne 0)
$err = Get-Content "$tmp\relay.txt" -Raw
Assert "refusal says not signed in" ($err -match 'not signed in')

"== 6: +close tears the remote window down cleanly"
& $Exe +close --target=remcmd 2>&1 | Out-Null
& $Exe +close --target=rem 2>&1 | Out-Null
Assert "close exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$list = Get-List
Assert "remote windows gone" (-not ($list -match '\[target: rem\]'))
Assert "app still alive (base window listed)" ($list -match '\[target: rembase\]')

"== cleanup"
& $Exe +close --target=rembase 2>&1 | Out-Null
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
