# T42 acceptance: a session the agent spawns must have the interactive user's
# environment, not just whatever environment the agent process happened to
# inherit.
#
#   powershell -NoProfile -File test\win32\agent-user-env.ps1
#
# The defect: every agent-spawned child (session-persistence AND cross-machine)
# clones the AGENT PROCESS's environment, which is a snapshot of whoever started
# the agent - an HKCU Run entry, a scheduled task, an SSH bridge, a self-update
# relaunch. A cross-machine OPEN forwards no env at all, so a remote Windows
# session opened from the Mac came up with the system PATH and NONE of the
# user's entries (user report 2026-07-13).
#
# How this reproduces the condition without needing a second machine: it starts
# a real ghoztty-agent whose own PATH has been STRIPPED to %SystemRoot%\system32
# + %SystemRoot%, drives it with remote-test-client over a named pipe, and has
# the spawned cmd.exe dump its whole environment to a file (`set > file`). A
# file, not the PTY, because an 80-column ConPTY wraps a long PATH mid-entry and
# the assertion would be measuring the terminal instead of the environment.
#
# The negative control is the same run with GHOZTTY_USER_ENV=off in the agent's
# environment: the overlay is skipped and the marker must be ABSENT. Without it
# a green run proves nothing - the stripped PATH could simply not have been
# stripped.
#
# T358 extends the same harness to the agent's OTHER spawn path: PROC_SPAWN
# (Activity Monitor "New Process"), which launches a DETACHED process via a
# direct CreateProcessW instead of a PTY. Each scenario also drives
# `remote-test-client --spawn "set > file"` and asserts the detached child's
# PATH the same way - marker present with the overlay on, absent with it off.
#
# Hermetic: LOCALAPPDATA, the port/sessions files and the heartbeat are all
# redirected into a per-PID temp dir, and only agents launched from this
# script's own pipe are ever stopped.
param(
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$ClientExe = 'D:\git\ghoztty\zig-out\bin\remote-test-client.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# T359: remote-test-client is an on-demand build target, so a tree that only
# ever ran the normal build does not have it. Resolve (and build it if needed)
# HERE, before %LOCALAPPDATA% is redirected below - this shells out to zig.
. (Join-Path $PSScriptRoot 'lib\TestClient.ps1')
$ClientExe = Resolve-RemoteTestClient -ClientExe $ClientExe

$script:failures = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t42-userenv-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

"== 0: preconditions"
Assert "agent exe exists" (Test-Path $AgentExe)
Assert "remote-test-client available ($(Get-RemoteTestClientBuildCommand))" ($ClientExe -and (Test-Path $ClientExe))
if ($script:failures -gt 0) { "$($script:failures) FAILURE(S)"; exit 1 }

# ---------------------------------------------------------------------------
# The marker: an entry of the user's OWN registry PATH (HKCU\Environment\Path)
# that does not live under %SystemRoot%, so the stripped agent PATH cannot
# contain it by accident. Read expanded - that is the form a shell sees.
$userPathRaw = ''
try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($null -ne $key) {
        $userPathRaw = [string]$key.GetValue('Path', '')
        $key.Close()
    }
} catch { $userPathRaw = '' }
$userPath = [Environment]::ExpandEnvironmentVariables($userPathRaw)

$winRoot = $env:SystemRoot
$marker = $null
foreach ($e in ($userPath -split ';')) {
    $t = $e.Trim().Trim('"').TrimEnd('\')
    if ($t.Length -eq 0) { continue }
    if ($t.ToLower().StartsWith($winRoot.ToLower())) { continue }
    $marker = $t
    break
}

if ($null -eq $marker) {
    # T271: this used to print ALL PASS and exit 0 having asserted nothing about
    # the feature - a box without a usable PATH entry scored the whole run green.
    Write-TestAssertedNothing -Reason 'no usable HKCU\Environment\Path entry on this box - nothing to assert' -Skipped 1
}
"  marker (user PATH entry): $marker"

# ---------------------------------------------------------------------------
# Run one scenario: start an agent with a stripped PATH, have a session dump its
# environment to a file, return the dumped Path value ('' when the dump never
# arrived). $overlay 'off' sets GHOZTTY_USER_ENV=off in the AGENT's environment.
function Invoke-Scenario($tag, $overlay) {
    $dir = Join-Path $tmp $tag
    New-Item -ItemType Directory -Force $dir | Out-Null
    $stateDir = Join-Path $dir 'ghoztty\local-agent-debug'
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $envFile = Join-Path $dir 'env.txt'
    $pipe = "\\.\pipe\ghoztty-agent-t42-$PID-$tag"

    $savedPath = $env:Path
    $savedLocal = $env:LOCALAPPDATA
    # THE CONDITION: an agent whose environment carries no user PATH at all.
    $env:Path = "$winRoot\system32;$winRoot"
    $env:LOCALAPPDATA = $dir
    $env:GHOSTTY_AGENT_HEARTBEAT = (Join-Path $dir 'agent.heartbeat')
    if ($overlay -eq 'off') { $env:GHOZTTY_USER_ENV = 'off' }

    $agent = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -ArgumentList "--listen-pipe=$pipe", "--port-file=$(Join-Path $stateDir 'port.json')", `
        "--sessions-file=$(Join-Path $stateDir 'sessions.json')", "--headless", "--force-replace"

    $env:Path = $savedPath
    $env:LOCALAPPDATA = $savedLocal
    Remove-Item env:GHOSTTY_AGENT_HEARTBEAT -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_USER_ENV -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2
    $started = -not $agent.HasExited

    # `set > <file>` dumps the child's whole environment. The path has no spaces
    # (it is under %TEMP%), and the whole command is one quoted argv element.
    $client = $null
    if ($started) {
        $client = Start-Process -FilePath $ClientExe -PassThru -WindowStyle Hidden `
            -ArgumentList "--pipe=$pipe --exec `"set > $envFile`" --timeout 4" `
            -RedirectStandardOutput (Join-Path $dir 'client.out') `
            -RedirectStandardError (Join-Path $dir 'client.err')
        if (-not $client.WaitForExit(30000)) {
            Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
        }
    }

    $pathLine = ''
    if (Test-Path $envFile) {
        foreach ($line in (Get-Content $envFile)) {
            if ($line -match '^(?i)path=(.*)$') { $pathLine = $Matches[1]; break }
        }
    }

    # T358: the DETACHED spawn path (PROC_SPAWN). The spawned cmd.exe dumps its
    # own environment; the child is detached, so poll for the file to fill in.
    $spawnEnvFile = Join-Path $dir 'spawn-env.txt'
    if ($started) {
        $spawnClient = Start-Process -FilePath $ClientExe -PassThru -WindowStyle Hidden `
            -ArgumentList "--pipe=$pipe --spawn=`"set > $spawnEnvFile`" --timeout 4" `
            -RedirectStandardOutput (Join-Path $dir 'spawn-client.out') `
            -RedirectStandardError (Join-Path $dir 'spawn-client.err')
        if (-not $spawnClient.WaitForExit(30000)) {
            Stop-Process -Id $spawnClient.Id -Force -ErrorAction SilentlyContinue
        }
        $deadline = (Get-Date).AddSeconds(6)
        while ((Get-Date) -lt $deadline) {
            if ((Test-Path $spawnEnvFile) -and ((Get-Item $spawnEnvFile).Length -gt 0)) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    $spawnPathLine = ''
    if (Test-Path $spawnEnvFile) {
        foreach ($line in (Get-Content $spawnEnvFile)) {
            if ($line -match '^(?i)path=(.*)$') { $spawnPathLine = $Matches[1]; break }
        }
    }

    if ($null -ne $agent -and -not $agent.HasExited) {
        Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 400

    return @{
        started = $started; path = $pathLine; dump = (Test-Path $envFile)
        spawnPath = $spawnPathLine; spawnDump = (Test-Path $spawnEnvFile)
    }
}

function Test-HasEntry($pathValue, $entry) {
    foreach ($e in ($pathValue -split ';')) {
        $t = $e.Trim().Trim('"').TrimEnd('\')
        if ($t.Length -eq 0) { continue }
        if ($t -ieq $entry) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
"== 1: overlay ON - a session started by a PATH-stripped agent still has the user's PATH"
$on = Invoke-Scenario 'on' 'default'
Assert "agent started" ($on.started)
Assert "the session dumped its environment" ($on.dump)
Assert "dumped PATH is non-empty" ($on.path.Length -gt 0)
Assert "dumped PATH still has the system entries (positive control)" (
    Test-HasEntry $on.path "$winRoot\system32")
Assert "dumped PATH contains the user entry '$marker'" (Test-HasEntry $on.path $marker)

"== 1b: T358 - a DETACHED spawn (PROC_SPAWN) gets the user's PATH too"
Assert "the spawned process dumped its environment" ($on.spawnDump)
Assert "spawned PATH is non-empty" ($on.spawnPath.Length -gt 0)
Assert "spawned PATH still has the system entries (positive control)" (
    Test-HasEntry $on.spawnPath "$winRoot\system32")
Assert "spawned PATH contains the user entry '$marker'" (Test-HasEntry $on.spawnPath $marker)

# ---------------------------------------------------------------------------
"== 2: negative control - GHOZTTY_USER_ENV=off leaves the stripped PATH stripped"
$off = Invoke-Scenario 'off' 'off'
Assert "agent started (control)" ($off.started)
Assert "the session dumped its environment (control)" ($off.dump)
Assert "dumped PATH still has the system entries (control)" (
    Test-HasEntry $off.path "$winRoot\system32")
Assert "dumped PATH does NOT contain '$marker' with the overlay off" (
    -not (Test-HasEntry $off.path $marker))

"== 2b: T358 negative control - the detached spawn stays stripped with the overlay off"
Assert "the spawned process dumped its environment (control)" ($off.spawnDump)
Assert "spawned PATH still has the system entries (control)" (
    Test-HasEntry $off.spawnPath "$winRoot\system32")
Assert "spawned PATH does NOT contain '$marker' with the overlay off" (
    -not (Test-HasEntry $off.spawnPath $marker))

# ---------------------------------------------------------------------------
"== 3: the overlay never weakens what the agent already had"
# Every entry the stripped agent carried must survive the merge, in place.
Assert "system32 is still the FIRST entry (existing entries keep their position)" (
    (($on.path -split ';')[0]).Trim().TrimEnd('\') -ieq "$winRoot\system32")
Assert "no entry appears twice (case-insensitive dedupe)" (
    $(
        $seen = @{}
        $dupe = $false
        foreach ($e in ($on.path -split ';')) {
            $t = $e.Trim().Trim('"').TrimEnd('\').ToLower()
            if ($t.Length -eq 0) { continue }
            if ($seen.ContainsKey($t)) { $dupe = $true; break }
            $seen[$t] = $true
        }
        -not $dupe
    ))

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body
Write-TestVerdict -Pass $script:passes -Fail $script:failures
