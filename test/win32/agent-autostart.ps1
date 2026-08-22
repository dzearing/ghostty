# Agent-autostart acceptance (tracker T89h): the GUI writes/refreshes an HKCU
# Run entry for the local session-persistence agent when persistence engages,
# so the agent comes back at sign-in after a reboot and rematerializes its
# recorded sessions as relaunchable tombstones.
#
# Sections:
#   A. Run-key write: hermetic debug GUI + GHOZTTY_AGENT_AUTOSTART=force (the
#      test hook — debug builds never write the key otherwise) => the
#      lineage-suffixed value `GhozttyAgent-debug` appears and carries the
#      exact daemon command line (agent exe + --listen-pipe/--port-file/
#      --sessions-file, all quoted).
#   B. Reboot proxy: kill the GUI, then the agent (the reboot analog), then
#      execute the Run-key command VERBATIM via Win32_Process.Create — the
#      same raw-CreateProcess treatment Windows gives Run entries at sign-in.
#      The agent must come back and list the pre-kill session as a DEAD
#      tombstone (alive=false) materialized from sessions.json.
#   C. Debug gate: without the force hook a debug GUI writes NO Run value.
#
# Hermetic: per-run $env:LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN; only ever
# kills ghoztty/ghoztty-agent processes launched from zig-out; saves and
# restores any pre-existing `GhozttyAgent-debug` Run value (release
# `GhozttyAgent` is never touched — debug builds use the -debug name).
#
#   powershell -NoProfile -File test\win32\agent-autostart.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches, and a pane-launched app would otherwise hand its work to
# a respawned twin mid-test.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'

# T680: private IPC endpoint before ANY CLI call. Run from a Ghoztty pane this
# script inherits $GHOZTTY_IPC_SOCKET, which names the USER'S app - without a
# suffix every `+list`/`+sessions` below reads their live window tree instead
# of the instance launched here, and Wait-FirstPane "finds" a pane this run
# never opened.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'agentauto')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-agent-autostart-$PID"
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$valueName = 'GhozttyAgent-debug'

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}

function Stop-GuiOnly {
    # T351: the shared, path-exact kill (lib\CleanSlate.ps1). -AppOnly is the
    # point of this helper - the agent (and its PTYs) stay up - and exact-exe is
    # what the private copy's '*zig-out*' filter got wrong: that also matched a
    # detached instance running from zig-out-release (T53b).
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
}

function Run-Cli($argsLine, $out, $timeoutSec = 15) {
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
function Wait-FirstPane($tmp, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $code = Run-Cli '+list --json' "$tmp\list.json" 10
        if ($code -eq 0) {
            $tree = $null
            try { $tree = Out-Text "$tmp\list.json" | ConvertFrom-Json } catch {}
            if ($null -ne $tree) {
                $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
                foreach ($w in @($windows)) {
                    foreach ($t in @($w.tabs)) {
                        $leaf = Find-Leaf $t.splits
                        if ($null -ne $leaf) { return $leaf }
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Get-RunValue {
    try { (Get-ItemProperty -Path $runKey -Name $valueName -ErrorAction Stop).$valueName }
    catch { $null }
}

function Start-Gui($label) {
    $tmp = Join-Path $root $label
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    # persistence: on (default) - a launch with persistence off never autostarts an agent, which is the subject.
    $p = Start-Process -FilePath $Exe -PassThru -WindowStyle Minimized `
        -ArgumentList @('--title=t89h-agent-autostart')
    return @{ Tmp = $tmp; Proc = $p }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedAutostart = $env:GHOZTTY_AGENT_AUTOSTART
$savedRunValue = Get-RunValue
Remove-ItemProperty -Path $runKey -Name $valueName -ErrorAction SilentlyContinue

Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)

# Throws (and so aborts the run) if anything already answers on the private
# suffix, or if $Exe is a release build on the user's own endpoints (T350).
Assert-GhozttyPrivateEndpoint -Exe $Exe

$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

# ============================================================================
"== A: persistence engages under force hook -> Run key written"
# ============================================================================
$env:GHOZTTY_AGENT_AUTOSTART = 'force'
$a = Start-Gui 'a'
$pane = Wait-FirstPane $a.Tmp
Assert "A1 GUI opened a pane" ($null -ne $pane)

# The Run value appears once the agent resolve succeeds (same moment the
# session opens); give it a short grace poll.
$runCmd = $null
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline) {
    $runCmd = Get-RunValue
    if ($runCmd) { break }
    Start-Sleep -Milliseconds 300
}
Assert "A2 Run value '$valueName' written" ($null -ne $runCmd)
"  run command: $runCmd"
Assert "A3 command starts with the quoted agent exe" ($runCmd -like "`"$AgentExe`"*")
Assert "A4 command pins the debug-lineage pipe" ($runCmd -like '*--listen-pipe=\\.\pipe\ghoztty-agent-debug-*')
Assert "A5 command carries port-file under the engaging LOCALAPPDATA" ($runCmd -like "*--port-file=$($a.Tmp)\ghoztty\local-agent-debug\port.json*")
Assert "A6 command carries sessions-file under the engaging LOCALAPPDATA" ($runCmd -like "*--sessions-file=$($a.Tmp)\ghoztty\local-agent-debug\sessions.json*")

# A live session exists (what section B expects to come back as a tombstone).
$code = Run-Cli '+sessions --json' "$($a.Tmp)\sess.json"
$rows = $null
try { $rows = Out-Text "$($a.Tmp)\sess.json" | ConvertFrom-Json } catch {}
$sid = if ($null -ne $rows) { @($rows)[0].id } else { $null }
Assert "A7 one live agent session before the reboot proxy" ($null -ne $rows -and @($rows).Count -eq 1 -and @($rows)[0].alive -eq $true)

# ============================================================================
"== B: reboot proxy -> Run command restarts agent, session tombstones back"
# ============================================================================
# Reboot analog: everything dies. Kill the GUI first (no CLOSE is sent — app
# death never ends sessions), then the agent itself.
Stop-GuiOnly
$portFile = Join-Path $a.Tmp 'ghoztty\local-agent-debug\port.json'
$oldAgentPid = 0
try { $oldAgentPid = [int]((Get-Content $portFile -Raw | ConvertFrom-Json).pid) } catch {}
Assert "B1 agent alive before the proxy kill" ($oldAgentPid -gt 0 -and $null -ne (Get-Process -Id $oldAgentPid -ErrorAction SilentlyContinue))
Stop-Process -Id $oldAgentPid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800
Assert "B2 agent dead after the proxy kill" ($null -eq (Get-Process -Id $oldAgentPid -ErrorAction SilentlyContinue))

# Execute the Run-key command VERBATIM, the way winlogon/Explorer does at
# sign-in: a raw command line through CreateProcess (Win32_Process.Create).
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $runCmd }
Assert "B3 Run command launched (CreateProcess rc=0)" ($null -ne $created -and $created.ReturnValue -eq 0)

# The fresh agent binds, rewrites port.json (new pid), and materializes the
# recorded session from sessions.json as a dead-but-relaunchable tombstone.
$newAgentPid = 0
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    try {
        $p2 = [int]((Get-Content $portFile -Raw | ConvertFrom-Json).pid)
        if ($p2 -gt 0 -and $p2 -ne $oldAgentPid -and $null -ne (Get-Process -Id $p2 -ErrorAction SilentlyContinue)) {
            $newAgentPid = $p2; break
        }
    } catch {}
    Start-Sleep -Milliseconds 500
}
Assert "B4 fresh agent running from the Run command" ($newAgentPid -gt 0)

$code = Run-Cli '+sessions --json' "$($a.Tmp)\sess2.json"
$rows2 = $null
try { $rows2 = Out-Text "$($a.Tmp)\sess2.json" | ConvertFrom-Json } catch {}
$tomb = if ($null -ne $rows2) { @($rows2) | Where-Object { $_.id -eq $sid } | Select-Object -First 1 } else { $null }
Assert "B5 pre-reboot session id came back" ($null -ne $tomb)
Assert "B6 ...as a DEAD tombstone (alive=false)" ($null -ne $tomb -and $tomb.alive -eq $false)

Stop-TestProcs

# ============================================================================
"== C: debug gate -> no Run value without the force hook"
# ============================================================================
Remove-ItemProperty -Path $runKey -Name $valueName -ErrorAction SilentlyContinue
Remove-Item env:GHOZTTY_AGENT_AUTOSTART -ErrorAction SilentlyContinue
$c = Start-Gui 'c'
$paneC = Wait-FirstPane $c.Tmp
Assert "C1 GUI opened a pane" ($null -ne $paneC)
# Persistence still engaged (session exists)...
$code = Run-Cli '+sessions --json' "$($c.Tmp)\sess.json"
$rowsC = $null
try { $rowsC = Out-Text "$($c.Tmp)\sess.json" | ConvertFrom-Json } catch {}
Assert "C2 persistence engaged (agent session exists)" ($null -ne $rowsC -and @($rowsC).Count -ge 1)
# ...but a debug build without the hook must not write the Run key.
Start-Sleep -Seconds 2
Assert "C3 no Run value written by a debug build" ($null -eq (Get-RunValue))

# ============================================================================
# Cleanup
# ============================================================================
Stop-TestProcs
Remove-ItemProperty -Path $runKey -Name $valueName -ErrorAction SilentlyContinue
if ($null -ne $savedRunValue) { Set-ItemProperty -Path $runKey -Name $valueName -Value $savedRunValue }
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
if ($null -ne $savedAutostart) { $env:GHOZTTY_AGENT_AUTOSTART = $savedAutostart }
else { Remove-Item env:GHOZTTY_AGENT_AUTOSTART -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) { "ALL PASS" ; exit 0 }
else { "$($script:failures) FAILURE(S)" ; exit 1 }
