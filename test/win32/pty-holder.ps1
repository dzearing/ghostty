# T905 acceptance: a persistent session's shell no longer dies with the agent.
#
# The promise this measures, in the user's terms: the background process that
# manages persistent terminal sessions can crash, be killed, or be replaced by
# a newer build, and the shells keep running. Until T905 the opposite was
# structurally guaranteed - the agent owned every session's ConPTY and put every
# shell in its own kill-on-close Job Object, so "the manager died" meant "your
# sessions died". T905 moves the ConPTY, the shell and its job into a per-
# session HOLDER process that escapes the agent's job.
#
# Sections:
#   A. Flag ON: a new agent-backed pane is holder-backed. `sessions.json`
#      records the holder's control pipe + pid, a `--pty-host` process is
#      really running under that pid, and the pane's shell is a child of the
#      HOLDER (not of the agent).
#   B. Kill the AGENT. The holder survives, the shell survives, and the
#      holder's control pipe still accepts a connection - which is what makes
#      the session re-adoptable (T906 does the adopting).
#   C. NEGATIVE CONTROL, flag OFF: the same steps record no holder fields, the
#      shell is a child of the AGENT, and killing the agent DOES take the shell
#      with it. Without this arm, section B would pass on a box where nothing
#      ever dies, and the flag's "bit-identical when off" claim would be
#      untested.
#
# Hermetic: a per-run $env:LOCALAPPDATA, a private IPC pipe suffix, and
# GHOSTTY_LOCAL_AGENT_BIN pinned to the agent under test. Only processes whose
# ExecutablePath is the exe/agent under test are ever stopped - never the user's
# installed release, which owns their live sessions.
#
#   powershell -NoProfile -File test\win32\pty-holder.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'PTY-HOLDER' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'PTY-HOLDER' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

# --- process helpers: ONLY ever the binaries under test ----------------------

function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgentProcs {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe })
}
# The session manager itself: an agent process that is NOT one of the per-
# session holders (holders are the same binary in `--pty-host` mode).
function Get-TestAgents {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -notmatch '--pty-host' })
}
function Get-TestHolders {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -match '--pty-host' })
}
function Get-Children([int]$parentPid) {
    return , @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$parentPid")
}
function Test-Alive([int]$procId) {
    if ($procId -le 0) { return $false }
    return $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
}
function Stop-TestProcs {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-TestAgentProcs)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

function Wait-NewAgent($excludePids, $timeoutSec = 40) {
    $excludePids = @($excludePids | ForEach-Object { [int]$_ })
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $fresh = @((Get-TestAgents) | Where-Object { $excludePids -notcontains [int]$_.ProcessId })
        if ($fresh.Count -gt 0) { return [int]$fresh[0].ProcessId }
        Start-Sleep -Milliseconds 400
    }
    return 0
}

# `sessions.json` lives under the (per-run) agent state directory; find it
# rather than re-deriving the layout here, so a state-dir move cannot silently
# turn this into a test of nothing.
function Wait-SessionsFile([string]$root, [int]$timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $f = @(Get-ChildItem -Path $root -Filter 'sessions.json' -Recurse -File -ErrorAction SilentlyContinue)
        foreach ($c in $f) {
            $txt = Get-Content -LiteralPath $c.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt -and $txt -match '"sessions"\s*:\s*\[\s*\{') { return $c.FullName }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Test-PipeConnects([string]$fullPipePath) {
    if (-not $fullPipePath) { return $false }
    # `\\.\pipe\NAME` -> NAME (NamedPipeClientStream takes the bare name).
    $name = $fullPipePath -replace '^\\\\\.\\pipe\\', ''
    $npc = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name, ([System.IO.Pipes.PipeDirection]::InOut))
    try {
        $npc.Connect(3000)
        return $true
    } catch {
        return $false
    } finally {
        try { $npc.Dispose() } catch {}
    }
}

# One arm of the experiment: bring up an app + agent with the holder flag in a
# given state, open a pane, and report what the agent recorded.
function Invoke-Arm([bool]$HolderOn, [string]$Tag) {
    $root = Join-Path $env:TEMP "ghoztty-pty-holder-$Tag-$PID"
    New-Item -ItemType Directory -Force $root | Out-Null

    $env:LOCALAPPDATA = $root
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    if ($HolderOn) { $env:GHOZTTY_AGENT_PTY_HOLDER = '1' }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }

    Stop-TestProcs
    $before = @((Get-TestAgents) | ForEach-Object { [int]$_.ProcessId })

    # persistence: on (default) - an agent-backed pane is the whole subject.
    $app = Start-Process -FilePath $Exe -ArgumentList @("--title=holder-$Tag") -PassThru
    $ready = $false
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Alive $app.Id)) { break }
        $out = (& $Exe +list 2>$null) | Out-String
        if ($out -match '\S') { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }

    $agentPid = if ($ready) { Wait-NewAgent $before 40 } else { 0 }
    $metaPath = if ($agentPid -ne 0) { Wait-SessionsFile $root 40 } else { $null }

    $holderPipe = $null
    $holderPid = 0
    if ($metaPath) {
        # Read the record the AGENT wrote, not a re-derivation of it.
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        foreach ($s in @($meta.sessions)) {
            if ($s.PSObject.Properties.Name -contains 'holder_pipe' -and $s.holder_pipe) {
                $holderPipe = [string]$s.holder_pipe
                $holderPid = [int]$s.holder_pid
                break
            }
        }
    }

    return [pscustomobject]@{
        Root       = $root
        Ready      = $ready
        AppPid     = $app.Id
        AgentPid   = $agentPid
        MetaPath   = $metaPath
        HolderPipe = $holderPipe
        HolderPid  = $holderPid
    }
}

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSocket = $env:GHOZTTY_IPC_SOCKET

# A private endpoint so nothing here can reach the user's terminal. The suffix
# OUTRANKS the baked GHOZTTY_IPC_SOCKET inherited from the pane this was
# started in - clear the baked value too.
$env:GHOZTTY_PIPE_SUFFIX = "-t905-$PID"
Remove-Item env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue

$roots = @()
try {
    # ========================================================================
    Say "== A: flag ON - the pane's shell lives in a holder, not in the agent"
    # ========================================================================
    $on = Invoke-Arm $true 'on'
    $roots += $on.Root
    Assert 'A1 premise: the app is up and answering IPC' $on.Ready
    Assert 'A2 premise: a local agent is running' ($on.AgentPid -ne 0)
    Assert 'A3 the agent persisted a session record' ($null -ne $on.MetaPath)
    Assert 'A4 sessions.json records the holder control pipe' (
        $on.HolderPipe -and $on.HolderPipe -match 'pty-host')
    Assert 'A5 sessions.json records the holder pid' ($on.HolderPid -gt 0)

    $holderProcs = Get-TestHolders
    Assert 'A6 a --pty-host holder process is running' ($holderProcs.Count -ge 1)
    Assert 'A7 the recorded pid IS a live holder process' (
        $on.HolderPid -gt 0 -and
        (@($holderProcs | Where-Object { [int]$_.ProcessId -eq $on.HolderPid }).Count -eq 1))

    # The shell must hang off the HOLDER. That parentage is the mechanism: the
    # holder owns the ConPTY and the kill-on-close job over this subtree, which
    # is exactly why the agent's death cannot reach it.
    $holderKids = if ($on.HolderPid -gt 0) { Get-Children $on.HolderPid } else { @() }
    $shell = @($holderKids | Where-Object { $_.Name -match '^(cmd|powershell|pwsh|conhost)\.exe$' } |
        Select-Object -First 1)
    $shellPid = if ($shell.Count -eq 1) { [int]$shell[0].ProcessId } else { 0 }
    Assert 'A8 the session shell is a child of the holder' ($shellPid -gt 0)

    $agentKids = if ($on.AgentPid -ne 0) { Get-Children $on.AgentPid } else { @() }
    $agentShells = @($agentKids | Where-Object { $_.Name -match '^(cmd|powershell|pwsh)\.exe$' })
    Assert 'A9 the agent itself owns no session shell' ($agentShells.Count -eq 0)

    # ========================================================================
    Say "== B: kill the AGENT - the shell and its holder live on"
    # ========================================================================
    Stop-Process -Id $on.AgentPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Assert 'B1 premise: the agent is really gone' (-not (Test-Alive $on.AgentPid))
    Assert 'B2 the holder SURVIVED the agent' (Test-Alive $on.HolderPid)
    Assert 'B3 the session shell SURVIVED the agent' (Test-Alive $shellPid)
    Assert 'B4 the holder still accepts a control connection (re-adoptable)' (
        Test-PipeConnects $on.HolderPipe)

    Stop-TestProcs
    Start-Sleep -Milliseconds 500
    Assert 'B5 no holder is left behind once everything is stopped' (
        (Get-TestHolders).Count -eq 0)

    # ========================================================================
    Say "== C: negative control, flag OFF - today's behavior, unchanged"
    # ========================================================================
    $off = Invoke-Arm $false 'off'
    $roots += $off.Root
    Assert 'C1 premise: the app is up and answering IPC' $off.Ready
    Assert 'C2 premise: a local agent is running' ($off.AgentPid -ne 0)
    Assert 'C3 premise: the agent persisted a session record' ($null -ne $off.MetaPath)
    Assert 'C4 with the flag off, no holder fields are written' ($null -eq $off.HolderPipe)
    Assert 'C5 with the flag off, no holder process is spawned' ((Get-TestHolders).Count -eq 0)

    $offKids = if ($off.AgentPid -ne 0) { Get-Children $off.AgentPid } else { @() }
    $offShell = @($offKids | Where-Object { $_.Name -match '^(cmd|powershell|pwsh)\.exe$' } |
        Select-Object -First 1)
    $offShellPid = if ($offShell.Count -eq 1) { [int]$offShell[0].ProcessId } else { 0 }
    Assert 'C6 the session shell is a child of the AGENT' ($offShellPid -gt 0)

    Stop-Process -Id $off.AgentPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Assert 'C7 premise: the agent is really gone' (-not (Test-Alive $off.AgentPid))
    Assert 'C8 the shell DIED with the agent (the defect T905 removes)' (
        $offShellPid -gt 0 -and -not (Test-Alive $offShellPid))
} finally {
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    if ($savedPipe) { $env:GHOZTTY_PIPE_SUFFIX = $savedPipe }
    else { Remove-Item env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
    if ($savedSocket) { $env:GHOZTTY_IPC_SOCKET = $savedSocket }
    foreach ($r in $roots) {
        Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pty-holder -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'PTY-HOLDER' -Pass $script:passes -Fail $script:failures
