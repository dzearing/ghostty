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

# T1240: the CLI runs ON THE TEST DESKTOP, not on the user's. `+new-window` is
# the one verb that auto-launches the app, and the window it spawns lands on the
# desktop of the process that spawned it - so this script used to throw a window
# across whatever the user was reading. `Invoke-OnTestDesktop` is `& $Exe` with a
# desktop named in the STARTUPINFO; nothing else about the assertions changed.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# Every CLI call in this file goes through here. It returns { ExitCode, Output,
# Pid, TimedOut }; the child's stdout and stderr are captured to a file by the
# harness, which is also what the old `cmd /c ... > file` dance was for - a
# GUI-subsystem exe writes zero bytes to a PowerShell `>` redirect (T245).
function Ghoz([string[]]$GhozArgs) {
    return Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
}

function Get-List {
    return (Ghoz @('+list')).Output
}

function Read-Pane($name) {
    return (Ghoz @('+read', "--name=$name", '--lines=40')).Output
}

$td = New-TestDesktop

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== 0: start a loopback agent + a base window"
# GHOSTTY_AGENT_LOCK: unique lock path so this harness agent never fights an
# installed/real agent's single-instance guard.
$env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
$agent = Start-Process -FilePath $AgentExe -ArgumentList "--listen", "127.0.0.1:$Port", "--headless" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
Assert "agent is running" (-not $agent.HasExited)

$r = Ghoz @('+new-window', '--target=rembase')
Assert "base window exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe

"== 1: +new-remote-window dial + open"
$r = Ghoz @('+new-remote-window', '--host=127.0.0.1', "--port=$Port", '--name=rem')
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
$list = Get-List
Assert "remote window registered under --name" ($list -match '\[target: rem\]')

"== 2: terminal round-trip through the agent"
$r = Ghoz @('+send-keys', '--target=rem', 'echo remote-roundtrip-ok', 'Enter')
Assert "send-keys exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 3
$dump = Read-Pane 'rem'
Assert "remote output visible via +read" ($dump -match 'remote-roundtrip-ok')

"== 3: --command runs through the remote shell"
$r = Ghoz @('+new-remote-window', '--host=127.0.0.1', "--port=$Port", '--name=remcmd', '--command=echo remote-cmd-marker')
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 3
$dump = Read-Pane 'remcmd'
Assert "command output visible" ($dump -match 'remote-cmd-marker')

"== 4: dial failure surfaces the Mac-parity error"
$deadPort = $Port + 1
$r = Ghoz @('+new-remote-window', '--host=127.0.0.1', "--port=$deadPort", '--name=remdead')
Assert "exit nonzero" ($r.ExitCode -ne 0)
$err = $r.Output
Assert "error names the endpoint" ($err -match "failed to reach 127.0.0.1:$deadPort")

"== 5: tokenless relay args are refused with sign-in guidance (T21b)"
$savedTok = $env:GHOSTTY_RELAY_TOKEN
$env:GHOSTTY_RELAY_TOKEN = $null
$r = Ghoz @('+new-remote-window', '--relay=https://relay.example', '--device=dev1')
$env:GHOSTTY_RELAY_TOKEN = $savedTok
Assert "exit nonzero" ($r.ExitCode -ne 0)
$err = $r.Output
Assert "refusal says not signed in" ($err -match 'not signed in')

"== 6: +close tears the remote window down cleanly"
[void](Ghoz @('+close', '--target=remcmd'))
$r = Ghoz @('+close', '--target=rem')
Assert "close exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
$list = Get-List
Assert "remote windows gone" (-not ($list -match '\[target: rem\]'))
Assert "app still alive (base window listed)" ($list -match '\[target: rembase\]')

"== cleanup"
[void](Ghoz @('+close', '--target=rembase'))
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
