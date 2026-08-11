# T151 acceptance: an agent-backed pane gets shell integration injected.
#
#   powershell -NoProfile -File test\win32\agent-shell-integration.ps1
#
# The defect: with session persistence on (the default), every normal pane runs
# its shell under ghoztty-agent — and the Windows agent DROPPED the `OPEN.argv`
# shell-integration rewrite the app forwards (pty_child.zig gated it to POSIX,
# on a comment claiming the client never sends it on Windows; the client is
# platform-independent and always sends it). So a `--shell=powershell` pane
# started bare: no ghostty.ps1, no OSC 133 prompt marks, no OSC 7 cwd
# reporting. A second half of the defect sat client-side: with no explicit
# shell, detection fell back to `/bin/zsh` and fake-detected zsh for a pane the
# agent actually spawns as cmd.exe.
#
# Sections:
#   A  `+new-window --shell=powershell` (agent-backed): the pane's child
#      process command line carries the integration rewrite
#      (`-NoExit -Command . '…ghostty.ps1'`), the pane's env carries
#      GHOSTTY_POWERSHELL, and — the user-visible payoff — a `cd` inside the
#      pane updates the cwd `+list` reports, which only OSC 7 can do for
#      PowerShell (Set-Location never moves the process cwd, so the T185 PEB
#      fallback cannot explain it).
#   B  default pane (no --shell): spawns plain cmd.exe with NO integration
#      argv — the client must not forward a bogus rewrite for a shell that
#      cannot be integrated.
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: per-run
# LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN + private IPC suffix (Isolation.ps1),
# and it only ever kills ghoztty/ghoztty-agent processes launched from zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-t151-shellint-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.ExecutablePath -like 'D:\git\ghoztty\zig-out\*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 900
}

# `ghoztty +verb > file` from PowerShell writes zero bytes (T245): route
# through cmd.exe's redirection.
function Run-Cli($argsLine, $out, $timeoutSec = 30) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Find-Leaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    if ($node.type -eq 'split') {
        $l = Find-Leaf $node.left
        if ($null -ne $l) { return $l }
        return (Find-Leaf $node.right)
    }
    return $null
}
function Get-Tree($tag) {
    $code = Run-Cli '+list --json' "$root\list-$tag.json" 20
    if ($code -ne 0) { return $null }
    try { return (Out-Text "$root\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function Pane-In($tree, $target) {
    foreach ($w in (Windows-Of $tree)) {
        if ($w.target -ne $target) { continue }
        foreach ($t in @($w.tabs)) {
            $leaf = Find-Leaf $t.splits
            if ($null -ne $leaf) { return $leaf }
        }
    }
    return $null
}
# Poll +list until the target pane reports a live pid (the agent's OPENED reply
# and the attach land moments after the window appears).
function Wait-Pane($tag, $target, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $pane = $null
    $n = 0
    while ((Get-Date) -lt $deadline) {
        $pane = Pane-In (Get-Tree "$tag$n") $target
        if ($null -ne $pane -and [int]$pane.pid -gt 0) { return $pane }
        $n++
        Start-Sleep -Milliseconds 800
    }
    return $pane
}
function Norm($p) {
    if ($null -eq $p) { return '' }
    return ($p.Trim().TrimEnd('\').ToLowerInvariant())
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$markerDir = Join-Path $root 'cwd-marker'
New-Item -ItemType Directory -Force $markerDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

"== 0: preconditions"
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent exe exists in zig-out" (Test-Path $AgentExe)
Assert "ghostty.ps1 is in the build's resources" `
    (Test-Path 'D:\git\ghoztty\zig-out\share\ghostty\shell-integration\powershell\ghostty.ps1')
if ($script:failures -gt 0) { "$($script:failures) FAILURE(S)"; exit 1 }

$state = Join-Path $root 'state'
New-Item -ItemType Directory -Force (Join-Path $state 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $state
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't151')
Assert-GhozttyPrivateEndpoint -Exe $Exe

# ============================================================================
"== A: agent-backed --shell=powershell pane gets the integration rewrite"
# ============================================================================
$codeA = Run-Cli '+new-window --target=t151ps --shell=powershell' "$root\new-a.txt" 60
Assert "A1 +new-window --shell=powershell succeeded (exit 0)" ($codeA -eq 0)

$paneA = Wait-Pane 'a' 't151ps' 40
Assert "A2 the pane is up with a live pid" ($null -ne $paneA -and [int]$paneA.pid -gt 0)
Assert-GhozttyIsolated -Exe $Exe

# THE argv-verbatim oracle: the agent spawned the child FROM OPEN.argv, so the
# child process's own command line carries the dot-source rewrite. Before the
# fix this was a bare `powershell`.
$procA = $null
if ($null -ne $paneA -and [int]$paneA.pid -gt 0) {
    $procA = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$paneA.pid)"
}
Assert "A3 the pane's child is powershell" `
    ($null -ne $procA -and $procA.Name -match '^(powershell|pwsh)')
Assert "A4 its command line carries the integration rewrite (-NoExit -Command)" `
    ($null -ne $procA -and $procA.CommandLine -match '-NoExit' -and $procA.CommandLine -match '-Command')
Assert "A5 its command line dot-sources ghostty.ps1" `
    ($null -ne $procA -and $procA.CommandLine -match 'ghostty\.ps1')

# The env half (OPEN.env, T04b): setupPowershell exports GHOSTTY_POWERSHELL.
Run-Cli '+send-keys --target=t151ps --when-idle --idle-timeout=20 "echo GHPS=$env:GHOSTTY_POWERSHELL" Enter' "$root\sk-a.txt" 45 | Out-Null
$envSeen = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline -and -not $envSeen) {
    Start-Sleep -Milliseconds 900
    Run-Cli '+read --name=t151ps --lines=40' "$root\read-a.txt" 20 | Out-Null
    if ((Out-Text "$root\read-a.txt") -match 'GHPS=.*ghostty\.ps1') { $envSeen = $true }
}
Assert "A6 GHOSTTY_POWERSHELL reached the pane's environment" $envSeen

# The user-visible payoff: OSC 7 cwd reporting. Set-Location never moves the
# PowerShell PROCESS cwd, so +list can only learn this directory from the
# shell integration's OSC 7 — the T185 PEB fallback cannot explain a pass.
Run-Cli "+send-keys --target=t151ps `"cd '$markerDir'`" Enter" "$root\sk-cd.txt" 30 | Out-Null
$cwdSeen = $false
$deadline = (Get-Date).AddSeconds(30)
$n = 0
while ((Get-Date) -lt $deadline -and -not $cwdSeen) {
    Start-Sleep -Milliseconds 900
    $p = Pane-In (Get-Tree "cwd$n") 't151ps'
    $n++
    if ($null -ne $p -and (Norm $p.working_directory) -eq (Norm $markerDir)) { $cwdSeen = $true }
}
Assert "A7 +list reports the cd'd directory (OSC 7 flowed from the integration)" $cwdSeen

# ============================================================================
"== B: a default pane (no --shell) spawns plain cmd.exe, no integration argv"
# ============================================================================
$codeB = Run-Cli '+new-window --target=t151def' "$root\new-b.txt" 60
Assert "B1 +new-window (no shell) succeeded (exit 0)" ($codeB -eq 0)

$paneB = Wait-Pane 'b' 't151def' 40
Assert "B2 the default pane is up with a live pid" ($null -ne $paneB -and [int]$paneB.pid -gt 0)

$procB = $null
if ($null -ne $paneB -and [int]$paneB.pid -gt 0) {
    $procB = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$paneB.pid)"
}
Assert "B3 the default pane's child is cmd.exe (COMSPEC default)" `
    ($null -ne $procB -and $procB.Name -ieq 'cmd.exe')
Assert "B4 no integration argv leaked into the default pane" `
    ($null -ne $procB -and $procB.CommandLine -notmatch 'ghostty\.ps1' -and $procB.CommandLine -notmatch '-NoExit')

# ---- teardown --------------------------------------------------------------
Run-Cli '+close --target=t151ps' "$root\close-a.txt" 15 | Out-Null
Run-Cli '+close --target=t151def' "$root\close-b.txt" 15 | Out-Null
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -eq $savedAgentBin) {
    Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
} else {
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
}
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) { "ALL PASS"; exit 0 } else { "$($script:failures) FAILURE(S)"; exit 1 }
