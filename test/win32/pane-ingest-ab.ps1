# T1464 acceptance: is a pane SLOWER when its ConPTY is held by the agent?
#
#   powershell -NoProfile -File test\win32\pane-ingest-ab.ps1
#   powershell -NoProfile -File test\win32\pane-ingest-ab.ps1 -NegativeControl
#
# THE QUESTION THIS ANSWERS. T1463 measured, on an optimized build, the same
# 9.4 MB workload through three terminals on this box:
#
#     conhost                                  7,950 / 8,468 / 7,956 ms
#     Ghoztty pane, LOCAL ConPTY (Exec.zig)    6,511 / 6,138 ms
#     Ghoztty pane, AGENT-held (Remote.zig)   12,863 / 12,706 ms
#
# The same build, the same workload, 2.1x slower when the PTY is held by
# `ghoztty-agent` - and the agent-held one is the configuration we ship. The
# parse cost was identical in both (~41 ms of every second), so the deficit was
# the RELAY: the trip from the holder's ConPTY read, across two named pipes, to
# the app's parser, which was carrying the stream ~60 bytes at a time at
# 10,000-22,600 messages a second.
#
# That contrast is the entire finding, and until this script it existed once, by
# hand, in a scratchpad. What is regressed here is the RATIO rather than any
# absolute time: the ratio is what named the defect, and unlike a millisecond
# count it means the same thing on a Debug build, on a loaded box, and on
# somebody else's hardware.
#
# Sections:
#   A. Local-ConPTY pane (`--session-persistence=false`, termio.Exec) - the
#      control, the same app doing the same work with no relay in the path.
#   B. Agent-held pane (`--session-persistence=true`, termio.Remote) - the
#      shipped configuration.
#   C. The contrast: B is not materially slower than A.
#   D. conhost, for context. Reported, and asserted only as a sanity floor -
#      the box is not the variable this script controls.
#   E. The run stayed off the interactive desktop.
#
# -NegativeControl makes every timing arm wait for a stamp file the workload
# never writes, so each measured arm must go RED while the setup arms stay
# green. That is the proof the arms score ARRIVAL rather than the clock.
#
# READ THE RATIO ON AN OPTIMIZED BUILD. Against the default Debug `zig-out` the
# contrast INVERTS - measured 0.20x, agent-held 10.3 s against local 50.9 s -
# and that is not a relay win. Debug's parser is ~150x slower per byte (T1463),
# so a local pane back-pressures its child down to its own parse rate while the
# agent's ring absorbs the whole burst and lets the child run on. The same run
# shows it: `holder_read` still delivers 10,671 chunks a second while every leg
# downstream carries 2 frames a second of 32 KB, i.e. the writer coalescing this
# task added working exactly as designed against a consumer that is genuinely
# behind. Section C is still worth running on Debug - it is a liveness and
# correctness check on both paths - but the NUMBER only means something under
# `-ReleaseSandbox`.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1): every oracle is a
# CLI round trip or a file the child stamps, both desktop-independent.
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    # T1463's own size, ~7.7 MB of Claude-Code-shaped output, and it is not a
    # dial to turn down: at 20,000 chunks all three terminals finish in ~300 ms
    # and the agent path measures 0.89x - the relay's cost only exists once the
    # burst outlasts every buffer in the chain. A cheaper run measures nothing.
    [int]$Chunks = 400000,
    [int]$WaitSeconds = 300,
    # Measure an OPTIMIZED build. A ReleaseFast `zig-out` derives the same IPC
    # and agent endpoints as the user's installed release, so it can only be
    # measured under the three-knob release sandbox (T1158) - which is exactly
    # what the T1463 numbers this script regresses were taken under. Without
    # this switch a release build is REFUSED rather than silently driving the
    # terminal the user is sitting in.
    [switch]$ReleaseSandbox,
    # Leave the run's artifacts (app stderr, the workload, the stamps) on disk.
    # The path oracle below reads the app's own log, so a run that disagrees
    # with expectation is diagnosable only if that log outlives it.
    [switch]$KeepArtifacts,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ingestab' -ReleaseSandbox:$ReleaseSandbox)

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-ingest-ab-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# The app's own telemetry is this script's PATH ORACLE, and it has to be: a
# pane that could not reach an agent falls back to the local ConPTY silently,
# and the fallback looks exactly like a fast agent. `perf agent_feed` is logged
# only by `termio/Remote.zig` and `perf pty` only by `termio/Exec.zig`, so which
# line the app emitted says which backend carried the workload. T1463 measured
# the LOCAL path twice believing it was the agent one before this was checked.
$env:GHOZTTY_PERF = '1'

# ...and the agent's and the holders' halves of it, which reach nobody
# otherwise: the app's stderr is redirected by this script, but nothing
# redirects the agent's and nothing at all launches a pty holder except the
# agent. Both inherit this directory and append their relay meters to a file per
# process (`relay-perf-<pid>.log`), so a run that measures a deficit also says
# WHICH leg of the trip it is in.
$env:GHOZTTY_RELAY_PERF_DIR = $tmp

# --- bounds -----------------------------------------------------------------
# How much slower the agent-held pane may be than the local one.
#
# READ THIS BEFORE TIGHTENING IT. 2.50 is not the goal - it is a CEILING over a
# deficit that is still open. Measured on this box, optimized build: 2.25x
# before T1464's relay work and 1.97-2.15x after it, against a target of 1.0x.
# So the arm below asks "has the relay got WORSE?", which is the question a
# regression test can answer today, and the goal state (agent-held ingest at
# least conhost's) belongs to the task that carries the remaining deficit. When
# that lands, this number comes down to ~1.40 - wide enough for a loaded box,
# narrow enough that half the original regression fails it - and the assertion
# text below stops hedging.
$relayRatioBound = 2.50
# A run that produced no output at all would otherwise "pass" every ratio, so
# each pane must also clear a floor. Deliberately generous: the slowest thing
# measured on this box was the Debug agent path at ~50 KB/s.
$rateFloorKb = 20

# ---------------------------------------------------------------------------
# One CLI verb through cmd.exe with a real redirect (ghoztty.exe is
# GUI-subsystem, so `& $exe ... |` returns nothing), with a bounded wait so a
# wedged server fails the run instead of hanging it.
function Invoke-Ghoztty([string]$argsLine, [int]$timeoutSec = 20) {
    $out = Join-Path $tmp ("cli-{0}.txt" -f (Get-Random))
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # exitcode-audit: cache before any wait (T197)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    $text = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    Remove-Item $out -ErrorAction SilentlyContinue
    if ($null -eq $text) { return '' }
    return $text
}

<#
The pane `+list --json` reports for a window target, or $null. The whole
terminal object rather than its id, because `session_id` on it is this script's
PATH ORACLE: `+list` carries the agent session a pane is bound to and omits the
field entirely for a plain local ConPTY pane (T332), so it answers "is this pane
really on the relay?" without depending on how long the workload ran.
#>
function Get-Pane([string]$target) {
    $json = (Invoke-Ghoztty '+list --json').Trim()
    if (-not $json) { return $null }
    $data = $null
    try { $data = ($json | ConvertFrom-Json).data } catch { return $null }
    foreach ($w in $data.windows) {
        if ($w.target -eq $target) { return $w.tabs[0].splits.terminal }
    }
    return $null
}

<# Is this pane agent-backed? `session_id` present ⇒ yes (T332). #>
function Test-AgentBacked($pane) {
    if ($null -eq $pane) { return $false }
    $sid = $pane.session_id
    return ($null -ne $sid -and "$sid".Trim().Length -gt 0)
}

# --- the workload -----------------------------------------------------------
# A Claude-Code-shaped output stream (T1458): not a `cat` of one big file but
# many small writes - streaming token text, a spinner, and frequent full-width
# CR repaints of a status line. It times ITSELF and stamps the elapsed ms into a
# file, so the number is the writer's own clock and does not depend on how the
# harness launched it. Byte for byte the same file in all three terminals.
$workload = Join-Path $tmp 'workload.ps1'
@'
param([int]$Chunks = 4000, [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
# Pre-build every chunk so the loop pays for terminal work, not for PowerShell
# string formatting - without this the emitter dominates and every terminal
# looks identical no matter what it does.
$spin = @('|', '/', '-', '\')
$bar = '=' * 46
$chunkList = New-Object 'System.Collections.Generic.List[string]'
for ($i = 0; $i -lt $Chunks; $i++) {
    if ($i % 7 -eq 0) {
        $s = $spin[[int](($i / 7) % 4)]
        $chunkList.Add("`r$s Working ($i)  $bar`r")
    } elseif ($i % 23 -eq 0) {
        $chunkList.Add("`n  * step $i complete`n")
    } else {
        $chunkList.Add("token$i ")
    }
}
$chunkArr = $chunkList.ToArray()
$bytes = 0
foreach ($c in $chunkArr) { $bytes += $c.Length }
$out = [Console]::Out
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($c in $chunkArr) { $out.Write($c) }
$out.Flush()
$sw.Stop()
$ms = $sw.ElapsedMilliseconds
$out.Write("`nWORKLOAD_DONE ELAPSED_MS=$ms CHUNKS=$Chunks`n")
if ($OutFile) { "ELAPSED_MS=$ms BYTES=$bytes" | Set-Content -Encoding ascii $OutFile }
'@ | Set-Content -Encoding ascii $workload

<#
Write the .cmd shim a terminal runs. No arguments and no quoting for the caller
to mangle: every value is baked in when the file is written, which is what makes
`+send-keys <path>` and `cmd /c <path>` byte-identical launches.
#>
function New-RunShim([string]$tag) {
    $shim = Join-Path $tmp "go-$tag.cmd"
    $stamp = Join-Path $tmp "elapsed-$tag.txt"
    @(
        '@echo off',
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$workload`" -Chunks $Chunks -OutFile `"$stamp`""
    ) | Set-Content -Encoding ascii $shim
    # The pane is driven with `--keys-file`, whose bytes are sent VERBATIM. A
    # Windows path typed as a positional argument is not: `+send-keys` runs key
    # notation over it, so a CR escape inside a `run-...` path arrives as a
    # real carriage return and the shell sees the line broken in two.
    # (Observed: the shim ran as two commands, neither of which existed.)
    # The keys file is also written
    # WITHOUT a trailing newline, so the `Enter` after it is the only submit.
    $keys = Join-Path $tmp "keys-$tag.txt"
    [System.IO.File]::WriteAllText($keys, $shim)
    return [pscustomobject]@{ Shim = $shim; Stamp = $stamp; Keys = $keys }
}

<#
Wait for a workload stamp and parse it. Under -NegativeControl it watches a path
nothing ever writes, so every arm scoring the result must go red. Never throws.
#>
function Wait-Workload([string]$stamp, [int]$timeoutSec) {
    $watch = if ($NegativeControl) { "$stamp.never" } else { $stamp }
    $dl = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $dl) {
        if (Test-Path $watch) {
            $raw = Get-Content $watch -Raw
            if ($null -eq $raw) { $raw = '' }
            $ms = if ($raw -match 'ELAPSED_MS=(\d+)') { [int]$matches[1] } else { 0 }
            $by = if ($raw -match 'BYTES=(\d+)') { [int]$matches[1] } else { 0 }
            if ($ms -gt 0) {
                return [pscustomobject]@{
                    Ms = $ms
                    Bytes = $by
                    KbPerSec = if ($ms -gt 0) { [int](($by / 1024.0) / ($ms / 1000.0)) } else { 0 }
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

<#
Bring up an app with the given persistence setting, run the workload in a fresh
pane, and return the writer's own timing (or $null). Never throws: an arm that
scores $null fails rather than ending the run (T1039).
#>
function Measure-Pane([string]$tag, [bool]$persistence, [bool]$warmAgent) {
    $run = New-RunShim $tag
    $errFile = Join-Path $tmp "app-$tag.err"

    # A COLD sandbox has no agent, and the app waits only ~2 s for the one it
    # spawns before deciding "no local agent" for the whole session - so a pane
    # opened in the first app of a fresh sandbox is LOCAL however persistent it
    # was asked to be. Bring one app up purely to spawn the agent, kill the APP
    # only, and measure in a second app that finds the agent already there.
    # Without this the agent-held section measures the local path and reports a
    # 1.01x ratio over a defect of 2.1x (observed while writing this script).
    if ($warmAgent) {
        [void](Start-OnTestDesktop -Exe $Exe `
                -Arguments @("--session-persistence=true") `
                -StdErr (Join-Path $tmp "warm-$tag.err") -AllowReleaseBuild:$ReleaseSandbox)
        $agentPath = Get-GhozttyAgentPath -Exe $Exe
        for ($t = 0; $t -lt 80; $t++) {
            Start-Sleep -Milliseconds 500
            $up = @(Get-Process -Name ghoztty-agent -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -eq $agentPath })
            if ($up.Count -gt 0) { break }
        }
        Start-Sleep -Seconds 5
        Reset-GhozttyTestState -Exe $Exe -AppOnly -SettleMs 1000 -AllowReleaseBuild:$ReleaseSandbox | Out-Null
        Start-Sleep -Seconds 2
    }

    $app = Start-OnTestDesktop -Exe $Exe `
        -Arguments @("--session-persistence=$($persistence.ToString().ToLower())") `
        -StdErr $errFile -AllowReleaseBuild:$ReleaseSandbox
    Start-Sleep -Seconds 4

    # A `+new-window` that lands while the app's OWN startup resolve is still in
    # flight gets `sharedConnection() == null` ("still resolving; answering
    # none") and opens a plain local shell - silently, and in the section whose
    # entire subject is the agent path. Wait for the connection the app logs
    # before asking for the window. (Observed: the agent section measured
    # `termio.Exec` and reported a 1.01x ratio over a 2.1x defect.)
    if ($warmAgent) {
        $ready = Wait-ForLine $errFile 'shared local-agent connection ready' 60
        if (-not $ready) { "  (warning) the app never reported a ready local-agent connection" }
        Start-Sleep -Seconds 1
    }

    [void](Invoke-Ghoztty "+new-window --target=ab$tag" 60)

    $pane = $null
    $paneId = $null
    for ($t = 0; $t -lt 60; $t++) {
        $pane = Get-Pane "ab$tag"
        if ($null -ne $pane) { $paneId = $pane.id }
        if ($paneId) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $paneId) {
        return [pscustomobject]@{
            Pane = $null; Primed = $false; Result = $null; App = $app; Err = $errFile; Agent = $false
        }
    }

    # Prime: the shell is alive and its echo reaches the screen, so a workload
    # that never runs is the workload's fault and not the pane's.
    [void](Invoke-Ghoztty "+send-keys --target=$paneId `"echo READY`" Enter")
    $primed = $false
    for ($t = 0; $t -lt 60; $t++) {
        Start-Sleep -Milliseconds 250
        if ((Invoke-Ghoztty "+read --name=$paneId --lines=6") -match 'READY') { $primed = $true; break }
    }
    if (-not $primed) {
        return [pscustomobject]@{
            Pane = $paneId; Primed = $false; Result = $null; App = $app; Err = $errFile
            Agent = (Test-AgentBacked $pane)
        }
    }

    # Re-read the pane now that its shell has answered. `+list` reports the
    # agent session from `liveSessionId()`, which is null until the OPEN has
    # completed - so the object fetched the instant the window appeared says
    # "local" about every pane, agent-held ones included.
    $settled = Get-Pane "ab$tag"
    if ($null -ne $settled) { $pane = $settled }

    [void](Invoke-Ghoztty "+send-keys --target=$paneId --keys-file=`"$($run.Keys)`" Enter")
    $r = Wait-Workload $run.Stamp $WaitSeconds
    # A workload that never stamped leaves the pane holding the reason (a shell
    # that never saw the line, a powershell that refused the file). Capture it
    # here rather than making the next run guess.
    $tail = ''
    if ($null -eq $r) { $tail = (Invoke-Ghoztty "+read --name=$paneId --lines=12") }
    return [pscustomobject]@{
        Pane = $paneId; Primed = $true; Result = $r; App = $app; Tail = $tail; Err = $errFile
        Agent = (Test-AgentBacked $pane)
    }
}

<#
Read a log the app still has OPEN. `Get-Content` on a live redirect target is a
sharing violation, and this script has to read one WHILE the app runs (below).
Never throws: anything unreadable is the empty string.
#>
function Read-LogSafe([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs)
        $t = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        if ($null -eq $t) { return '' }
        return $t
    } catch { return '' }
}

<#
Did the app log `needle`? Never throws: a missing or empty log answers false,
which fails the arm rather than ending the run.
#>
function Test-PerfLine([string]$errFile, [string]$needle) {
    return ((Read-LogSafe $errFile) -match [regex]::Escape($needle))
}

<#
Wait (bounded) for `needle` to appear in a live log. Answers whether it did.
#>
function Wait-ForLine([string]$errFile, [string]$needle, [int]$timeoutSec) {
    $dl = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $dl) {
        if (Test-PerfLine $errFile $needle) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Show-Run([string]$tag, $r) {
    if ($null -eq $r) { "  ${tag}: no result"; return }
    if (-not $r.Primed) { "  ${tag}: pane never primed (pane=$($r.Pane))"; return }
    if ($null -eq $r.Result) {
        "  ${tag}: workload never finished; pane tail:"
        foreach ($ln in ("$($r.Tail)" -split "`r?`n")) { if ($ln.Trim()) { "    | $ln" } }
        return
    }
    "  ${tag}: {0} ms, {1:N0} bytes, {2} KB/s (writer clock)" -f $r.Result.Ms, $r.Result.Bytes, $r.Result.KbPerSec
}

$localRun = $null
$agentRun = $null
$conhost = $null

try {
    "== setup: {0} chunks{1}" -f $Chunks, $(
        if ($NegativeControl) { ' (NEGATIVE CONTROL - watching a stamp nothing writes)' } else { '' })

    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 -AllowReleaseBuild:$ReleaseSandbox | Out-Null
    Assert-GhozttyPrivateEndpoint -Exe $Exe -AllowReleaseBuild:$ReleaseSandbox
    New-TestDesktop | Out-Null

    # --- Section A: the local-ConPTY control --------------------------------
    "== A: local-ConPTY pane (termio.Exec, no relay in the path)"
    $localRun = Measure-Pane 'local' $false $false
    Show-Run 'A' $localRun
    Assert 'A1 the local pane came up and its shell echoes' (
        $null -ne $localRun -and $localRun.Primed)
    Assert 'A2 the pane really was LOCAL (+list reports no agent session)' (
        $null -ne $localRun -and -not $localRun.Agent)
    Assert 'A2b the workload finished in the local pane' (
        $null -ne $localRun -and $null -ne $localRun.Result)
    Assert "A3 local ingest is at least $rateFloorKb KB/s" (
        $null -ne $localRun -and $null -ne $localRun.Result -and $localRun.Result.KbPerSec -ge $rateFloorKb)
    Assert 'A4 the local pane is still LIVE afterwards' (
        $null -ne $localRun -and $localRun.Pane -and (Test-PaneLive -Exe $Exe -Target $localRun.Pane -Tmp $tmp))

    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 -AllowReleaseBuild:$ReleaseSandbox | Out-Null

    # --- Section B: the shipped, agent-held path ----------------------------
    "== B: agent-held pane (termio.Remote, the shipped configuration)"
    $agentRun = Measure-Pane 'agent' $true $true
    Show-Run 'B' $agentRun
    Assert 'B1 the agent-held pane came up and its shell echoes' (
        $null -ne $agentRun -and $agentRun.Primed)
    Assert 'B2 the pane really was AGENT-HELD (+list names its agent session)' (
        $null -ne $agentRun -and $agentRun.Agent)
    Assert 'B2b the workload finished in the agent-held pane' (
        $null -ne $agentRun -and $null -ne $agentRun.Result)
    Assert "B3 agent-held ingest is at least $rateFloorKb KB/s" (
        $null -ne $agentRun -and $null -ne $agentRun.Result -and $agentRun.Result.KbPerSec -ge $rateFloorKb)
    Assert 'B4 the agent-held pane is still LIVE afterwards' (
        $null -ne $agentRun -and $agentRun.Pane -and (Test-PaneLive -Exe $Exe -Target $agentRun.Pane -Tmp $tmp))

    # The relay's own meters, from the agent and the holder processes. Reported
    # rather than asserted: they are how a red C1 is diagnosed, and their shape
    # (bytes per frame, frames per wake) is what named the defect.
    $relayLogs = @(Get-ChildItem -Path $tmp -Filter 'relay-perf-*.log' -ErrorAction SilentlyContinue)
    if ($relayLogs.Count -gt 0) {
        # The MEDIAN busy second, not the busiest: every leg of this relay peaks
        # near the local path's rate while the burst is still being absorbed by
        # the buffers in front of it, and reporting that peak says the relay is
        # fine when the sustained rate is half of it.
        "  relay meters (median busy second per leg):"
        $byLeg = @{}
        foreach ($f in $relayLogs) {
            foreach ($ln in (Read-LogSafe $f.FullName) -split "`r?`n") {
                if ($ln -match '^perf (?<leg>\S+) .*kb_per_s=(?<kb>\d+)') {
                    $leg = $matches['leg']; $kb = [int]$matches['kb']
                    if ($kb -lt 20) { continue }   # an idle second is not a sample
                    if (-not $byLeg.ContainsKey($leg)) { $byLeg[$leg] = @() }
                    $byLeg[$leg] += [pscustomobject]@{ Kb = $kb; Line = $ln }
                }
            }
        }
        foreach ($leg in ($byLeg.Keys | Sort-Object)) {
            $rows = @($byLeg[$leg] | Sort-Object Kb)
            "    " + $rows[[int]($rows.Count / 2)].Line
        }
    }

    # --- Section C: the contrast --------------------------------------------
    "== C: the relay's cost"
    $ratio = 0.0
    if ($null -ne $localRun -and $null -ne $localRun.Result -and
        $null -ne $agentRun -and $null -ne $agentRun.Result -and $localRun.Result.Ms -gt 0) {
        $ratio = $agentRun.Result.Ms / [double]$localRun.Result.Ms
        "  agent / local = {0:N2}x  ({1} ms vs {2} ms)" -f $ratio, $agentRun.Result.Ms, $localRun.Result.Ms
    } else {
        "  agent / local = (not measured)"
    }
    Assert "C1 the relay has not got worse (agent within ${relayRatioBound}x of local)" (
        $ratio -gt 0 -and $ratio -le $relayRatioBound)

    # --- Section D: conhost, for context ------------------------------------
    "== D: conhost control"
    $ch = New-RunShim 'conhost'
    $cp = Start-Process -FilePath $env:ComSpec -WindowStyle Minimized -PassThru `
        -ArgumentList '/c', $ch.Shim
    $null = $cp.Handle   # exitcode-audit: cache before any wait (T197)
    $conhost = Wait-Workload $ch.Stamp $WaitSeconds
    try { if (-not $cp.HasExited) { $cp.Kill() } } catch {}
    if ($null -ne $conhost) {
        "  D: {0} ms, {1} KB/s (writer clock)" -f $conhost.Ms, $conhost.KbPerSec
        if ($null -ne $agentRun -and $null -ne $agentRun.Result) {
            "  agent / conhost = {0:N2}x" -f ($agentRun.Result.Ms / [double]$conhost.Ms)
        }
    } else {
        "  D: conhost never finished"
    }
    Assert "D1 the conhost control ran and cleared $rateFloorKb KB/s" (
        $null -ne $conhost -and $conhost.KbPerSec -ge $rateFloorKb)

    Assert 'E1 the run never took the interactive desktop' (
        $null -ne $agentRun -and $null -ne $agentRun.App -and
        -not (Test-TestDesktopLeak -ProcessId $agentRun.App.Pid))

    Complete-TestBody   # T1039: last statement of the try body, before the stamp
} finally {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 -AllowReleaseBuild:$ReleaseSandbox | Out-Null
    Remove-TestDesktop
    if ($KeepArtifacts) { "  artifacts: $tmp" }
    else { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# --- stamp (T783) -----------------------------------------------------------
# A green run records the content of the relay this harness covers, so
# scripts\guard-due.ps1 can answer "has anything measured the relay against the
# code as it now stands?". A red run - the negative control included - leaves
# the stamp alone.
if ($script:failures -eq 0 -and -not $NegativeControl -and -not $ReleaseSandbox) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard relay-throughput -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'PANE-INGEST-AB' -Pass $script:passes -Fail $script:failures
