# Tombstone RELAUNCH floor (tracker T89g). session-reattach.ps1 proves the
# SAME-PID re-attach path (kill only the app; the detached agent keeps every PTY
# alive, so restore ATTACHes live sessions). THIS script proves the harder path:
# the AGENT itself dies (reboot / agent upgrade) so its children are gone, but
# its on-disk state survives - sessions.json + rings/<id>.ring. On the next app
# launch the freshly-spawned agent re-materializes each session from disk as a
# relaunchable TOMBSTONE (dead, no exit_code, relaunchable=true), restore ATTACHes
# each recorded session id, and the shared termio path fires RELAUNCH per the
# `session-relaunch` policy:
#
#   A (rerun):  restore ATTACHes the tombstones and each pane auto-RELAUNCHes with
#               NO user input. The agent replays the pane's on-disk ring snapshot
#               (pre-kill scrollback) and then emits the "--- session restarted ---"
#               divider, so +read shows the pre-kill marker FOLLOWED BY the divider,
#               and the SAME session id is alive again (respawned, not re-OPENed).
#   B (prompt): restore ATTACHes the tombstone but does NOT respawn - the pane shows
#               "Session ended: press any key to relaunch" and the session stays
#               a dead tombstone (alive=false). The first keystroke (via +send-keys)
#               fires the deferred RELAUNCH: the id goes alive and the divider prints.
#
# The tombstone materialization + RELAUNCH state machine is shared/cross-platform
# (src/remote/agent/{session,server}.zig, src/termio/Remote.zig); this exercises it
# end-to-end through the win32 restore path (App.restoreSessionLayout), which T89g
# taught to forward relaunchable-tombstone ids to ATTACH instead of nulling them out.
#
# Non-interactive; asserts and exits nonzero on any failure. Fully hermetic: a
# per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN, and it ONLY ever
# kills ghoztty / ghoztty-agent processes launched from the repo zig-out (never the
# user's real release instance, which uses a different agent lineage + state dir).
#
#   powershell -NoProfile -File test\win32\session-relaunch.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-session-relaunch-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900)
}

# Run a zig-out ghoztty +command with a hard timeout; stdout+stderr -> $out.
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

# ---- +list / +sessions helpers (shared with the reattach suite) ------------
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
function Find-Pane($tree) {
    if ($null -eq $tree) { return $null }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    foreach ($w in @($windows)) {
        foreach ($t in @($w.tabs)) {
            $leaf = Find-Leaf $t.splits
            if ($null -ne $leaf) { return $leaf }
        }
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
            $pane = Find-Pane $tree
            if ($null -ne $pane) { return $pane }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

# The rows of `+sessions --json`, or @() if the CLI failed / no agent / empty.
function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Count-Alive($rows) { return @($rows | Where-Object { $_.alive -eq $true }).Count }
function Alive-Ids($rows) {
    return @($rows | Where-Object { $_.alive -eq $true } | ForEach-Object { $_.id })
}
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if ((Count-Alive $rows) -eq $target) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}
# Row for one session id (whatever its state), or $null.
function Row-For($rows, $id) { return @($rows | Where-Object { $_.id -eq $id })[0] }
# Poll until session $id reports alive == $true; returns the last rows read.
function Wait-IdAlive($tmp, $tag, $id, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        $r = Row-For $rows $id
        if ($null -ne $r -and $r.alive -eq $true) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}
# Poll until session $id is KNOWN to the agent but NOT alive (a tombstone).
function Wait-IdTombstone($tmp, $tag, $id, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        $r = Row-For $rows $id
        if ($null -ne $r -and $r.alive -ne $true) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}

# ---- Manifest helpers (debug lineage writes the -debug filename) ------------
function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }
function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}
function Wait-Manifest($tmp, $pred, $timeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { try { if (& $pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 300
    }
    return $m
}
# The session_id of the manifest leaf whose ipc_name matches $name (or $null).
function Sid-ByName($m, $name) {
    if ($null -eq $m) { return $null }
    foreach ($w in @($m.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($n in @($t.nodes)) {
                if ($null -ne $n.leaf -and $n.leaf.ipc_name -eq $name) { return $n.leaf.session_id }
            }
        }
    }
    return $null
}

# ---- Ring-snapshot helpers -------------------------------------------------
function Ring-Path($tmp, $sid) { return (Join-Path $tmp "ghoztty\local-agent-debug\rings\$sid.ring") }
# Wait until session $sid's on-disk ring snapshot is refreshed AFTER $afterTime,
# i.e. a periodic flush has captured everything in the ring up to now (incl. the
# marker we already confirmed is in the pane). The reaper flushes dirty rings
# every ~30s, so allow generous headroom. Returns $true once the snapshot lands.
function Wait-RingFresh($tmp, $sid, $afterTime, $timeoutSec = 45) {
    $p = Ring-Path $tmp $sid
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $p) {
            $mt = (Get-Item $p).LastWriteTime
            if ($mt -gt $afterTime) { return $true }
        }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

# One hermetic GUI launch with an explicit session-relaunch policy. On $restore
# we pass NO --title (restore rebuilds the layout and suppresses the blank window).
function Launch($tmp, $title, $relaunch, $restore) {
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    $launchArgs = @("--session-relaunch=$relaunch")
    if (-not $restore) { $launchArgs += "--title=$title" }
    # persistence: on (default) - session persistence IS this script's subject.
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList $launchArgs | Out-Null
}

# Marker match after whitespace strip (survives narrow-window per-glyph wrapping,
# same technique as session-reattach.ps1's marker/scrollback assertions).
function Stripped($f) { return ((Out-Text $f) -replace '\s', '') }

# ---- VT mode probes (T824) -------------------------------------------------
# The reboot replay is the DEAD program's RAW byte stream, so replaying it
# re-enables every mode that program had enabled - in a pane it no longer
# controls. Left armed, mouse tracking turns every pointer move into typed input
# (`35;1;12M` at the shell prompt). The fix resets those modes once the replay
# has landed; these helpers are the oracle for it.
#
# DECRQM (`CSI ? Ps $ p`) is the only way to ASK the terminal what a mode's value
# is, and its answer (`CSI ? Ps ; Pv $ y`, Pv 1 = set / 2 = reset) is delivered as
# INPUT to the pane's child. So the probe has to be a program that both asks and
# reads the answer back: left to the shell, the reply is raced by the prompt and
# echoed as a broken command.
#
# Three things about `+send-keys` shape these helpers, each measured on box:
#   * adjacent text arguments CONCATENATE WITH NO SEPARATOR, so a probe cannot be
#     parameterised as `probe.cmd VTPRE 1003` - it arrives as `probe.cmdVTPRE1003`.
#     Every probe therefore gets its own generated `.cmd` with the tag and mode
#     already baked in, and exactly ONE text word is ever sent.
#   * `\t`, `\n`, `\r`, `\\` and `\e` are ESCAPES in text, so a path with `\t` in
#     it (`...\Temp\t824...`) arrives with a TAB in the middle. `$root` is under
#     `$env:TEMP\ghoztty-session-relaunch-<pid>`, whose remaining separators are
#     all safe - keep it that way if this moves.
#   * `-NoProfile` would be parsed as one of send-keys' OWN flags, which is the
#     other reason everything goes through a `.cmd` shim.
#
# The reader is `$Host.UI.RawUI` (ReadConsoleInput) rather than
# `[Console]::KeyAvailable`, which throws outright the moment stdin is anything
# but a console - true for every nested invocation this harness might grow.
function Write-ModeProbes($dir) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $probe = @'
param([string]$Tag, [int]$Mode)
$esc = [char]27
$sb = New-Object System.Text.StringBuilder
[Console]::Write($esc + '[?' + $Mode + '$p')
$deadline = (Get-Date).AddSeconds(5)
try {
    $ui = $Host.UI.RawUI
    while ((Get-Date) -lt $deadline) {
        if ($ui.KeyAvailable) {
            $k = $ui.ReadKey('NoEcho,IncludeKeyDown')
            [void]$sb.Append($k.Character)
            if ($k.Character -eq 'y') { break }
        }
        else { Start-Sleep -Milliseconds 20 }
    }
}
catch { }
$raw = $sb.ToString() -replace '[^0-9;?$y]', ''
Write-Host ($Tag + '=' + $raw)
'@
    Set-Content -Path (Join-Path $dir 'vt-mode-probe.ps1') -Value $probe -Encoding ascii
    $arm = @'
$esc = [char]27
[Console]::Write($esc + '[?1003h')
[Console]::Write($esc + '[?1006h')
[Console]::Write($esc + '[?2004h')
Write-Host 'MODESARMEDOK'
'@
    Set-Content -Path (Join-Path $dir 'vt-mode-arm.ps1') -Value $arm -Encoding ascii
    Set-Content -Path (Join-Path $dir 'vtarm.cmd') `
        -Value '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vt-mode-arm.ps1"' -Encoding ascii
}

# Ask the pane's child to enable any-event mouse tracking + SGR encoding +
# bracketed paste, and confirm the child ran (so the bytes are really in the
# session's ring and will be replayed). Returns $true on confirmation.
function Invoke-ArmModes($dir, $tmp, $target, $timeoutSec = 25) {
    Run-Cli "+send-keys --target=$target $dir\vtarm.cmd Enter" "$tmp\arm-send.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Run-Cli "+read --name=$target --lines=200" "$tmp\arm-read.txt" 10 | Out-Null
        # The echoed command line does not contain the marker, only the output does.
        if ((Stripped "$tmp\arm-read.txt") -match 'MODESARMEDOK') { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# DECRQM one mode in the pane and return its reported value ('1' set, '2' reset,
# '' = no answer). $tag must be unique per call: a pane's PREVIOUS answer is
# replayed back into its scrollback across a relaunch, so a shared tag would read
# the pre-kill answer as the current one.
function Get-ModeValue($dir, $tmp, $target, $tag, $mode, $timeoutSec = 30) {
    $shim = Join-Path $dir "vtp$tag.cmd"
    Set-Content -Path $shim -Encoding ascii `
        -Value "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0vt-mode-probe.ps1`" -Tag $tag -Mode $mode"
    Run-Cli "+send-keys --target=$target $shim Enter" "$tmp\probe-send-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Run-Cli "+read --name=$target --lines=400" "$tmp\probe-read-$tag.txt" 10 | Out-Null
        $s = Stripped "$tmp\probe-read-$tag.txt"
        $m = [regex]::Match($s, [regex]::Escape("$tag=") + '\?' + $mode + ';(\d)')
        if ($m.Success) { return $m.Groups[1].Value }
        # 1s, not 300ms: each poll is a CLI process against the same app, and a
        # tight loop here starves the agent's periodic ring flush that A5 waits on.
        Start-Sleep -Seconds 1
    }
    return ''
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# T441: a private IPC endpoint, which the per-section LOCALAPPDATA redirect does
# NOT cover — the endpoint a CLI dials comes from the pane's baked
# `$GHOZTTY_IPC_SOCKET` unless a suffix outranks it. This script kills agents
# and drives relaunches; aimed at the user's release it would do that to their
# live sessions.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
# T652: the "attached is not alive" oracle. Read its header before adding an
# assertion about a relaunched pane.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
[void](Set-GhozttyTestIsolation -Tag 'sessrelaunch')
Assert-GhozttyPrivateEndpoint -Exe $Exe

# ============================================================================
"== A: session-relaunch=rerun - agent restart auto-RELAUNCHes with divider + ring scrollback"
# ============================================================================
$tmpA = Join-Path $root 'rerun'
Launch $tmpA 't89g-rerun' 'rerun' $false
$paneA = Wait-FirstPane $tmpA 25
Assert "A1 startup pane came up under the local agent" ($null -ne $paneA)
Assert-GhozttyIsolated -Exe $Exe

# A named second pane so we can target its ring / +read / relaunch precisely.
Run-Cli '+split --direction=right --name=relp' "$tmpA\split.txt" 15 | Out-Null
$rowsA = Wait-AliveCount $tmpA 'a-setup' 2 18
Assert "A2 +split opened a second agent-backed session (2 alive)" ((Count-Alive $rowsA) -eq 2)

# Learn relp's session id from the manifest (leaf ipc_name -> session_id).
$mA = Wait-Manifest $tmpA { param($m) $null -ne (Sid-ByName $m 'relp') } 12
$relpSid = Sid-ByName $mA 'relp'
Assert "A3 the named pane's session id was captured in the manifest" ($null -ne $relpSid)

# Plant a whitespace-free marker into relp; confirm it reached the pane.
$markerA = "RELAUNCHAUTO$($PID)ZZZ"
Run-Cli "+send-keys --target=relp $markerA Enter" "$tmpA\mark.txt" 12 | Out-Null
$preOk = $false
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    Run-Cli '+read --name=relp --lines=200' "$tmpA\read-pre.txt" 10 | Out-Null
    if ((Stripped "$tmpA\read-pre.txt") -match $markerA) { $preOk = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert "A4 marker is in the named pane before the agent dies" $preOk

# T824: arm the modes a dead TUI would leave behind, so the ring we are about to
# flush contains them and the replay re-arms them - the exact defect. Done BEFORE
# the ring-flush wait below so the arming bytes are in the snapshot.
$probeDir = Join-Path $root 'probes'
Write-ModeProbes $probeDir
Assert "A4b the pane's child enabled mouse tracking (armed into the ring)" (
    Invoke-ArmModes $probeDir $tmpA 'relp')
# Positive control: without it, a post-relaunch "reset" reading is unfalsifiable -
# it would also be what a pane that never armed anything reports.
$preMode = Get-ModeValue $probeDir $tmpA 'relp' 'VTPRE' 1003
Assert "A4c DECRQM reports any-event mouse tracking SET before the agent dies (control)" (
    $preMode -eq '1')

# Ensure the agent flushes relp's ring (with the marker) to disk before we kill
# it - otherwise a -Force kill would lose the tail and there'd be nothing to
# replay. Gate on the ring file's mtime advancing past "now".
$markTime = Get-Date
$ringOk = Wait-RingFresh $tmpA $relpSid $markTime 45
Assert "A5 relp's ring snapshot was flushed to disk (captures the marker)" $ringOk

# Record the ids the agent is keeping, then KILL BOTH the app AND the agent.
# The agent's children die with it; only sessions.json + rings/ survive on disk.
$idsA = @(Alive-Ids (Wait-AliveCount $tmpA 'a-before' 2 15))
Assert "A6 two sessions are alive before the agent is killed" ($idsA.Count -eq 2)
$sessJson = Join-Path $tmpA 'ghoztty\local-agent-debug\sessions.json'
Assert "A7 sessions.json persisted the sessions to disk" (Test-Path $sessJson)
Stop-TestProcs

# Agent is gone: no agent process, dial must fail (the app will spawn a fresh one).
$agentAlive = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' }).Count
Assert "A8 the agent process is gone after the kill" ($agentAlive -eq 0)

# Relaunch. A fresh agent loads sessions.json -> relaunchable tombstones; restore
# ATTACHes each id; policy=rerun respawns each pane in-place. Suppress the blank
# window and rebuild the layout.
Launch $tmpA 't89g-rerun' 'rerun' $true

# The SAME relp session id must come back ALIVE - proof the tombstone RELAUNCHed
# (a fresh OPEN would mint a new id and leave relp's id dead/absent).
$rowsPost = Wait-IdAlive $tmpA 'a-post' $relpSid 30
$relpBack = Row-For $rowsPost $relpSid
Assert "A9 the SAME relp session id is alive again after agent restart (RELAUNCH)" (
    $null -ne $relpBack -and $relpBack.alive -eq $true)

# +read the relaunched pane: the agent replayed the pre-kill scrollback (marker)
# and then the divider, so the marker must appear BEFORE "--- session restarted ---".
# Read a large line count: the fresh shell's restart banner ("Microsoft Windows
# [Version ...]") wraps into many visual rows in the ultra-narrow minimized pane,
# so the replayed marker sits well above the last 200 rows.
$autoDiv = $false
$autoOrder = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    $code = Run-Cli '+read --name=relp --lines=2000' "$tmpA\read-post.txt" 10
    if ($code -eq 0) {
        $s = (Out-Text "$tmpA\read-post.txt") -replace '\s', ''
        if ($s -match 'sessionrestarted') {
            $autoDiv = $true
            $mi = $s.IndexOf($markerA)
            $di = $s.IndexOf('sessionrestarted')
            if ($mi -ge 0 -and $di -ge 0 -and $mi -lt $di) { $autoOrder = $true }
            break
        }
    }
    Start-Sleep -Milliseconds 700
}
Assert "A10 the relaunched pane shows the '--- session restarted ---' divider" $autoDiv
Assert "A11 the pre-kill ring scrollback (marker) precedes the divider" $autoOrder

# A12 (T652): ATTACHED IS NOT ALIVE. A9-A11 read the pane's SCREEN, and every
# one of them is satisfied by a recording: the replayed marker is by definition
# a replay, the divider is a line the agent printed on its own, and an `alive`
# row is the agent's view of a child that may be wired to nothing. Type into the
# RESPAWNED shell and require it to answer - the half of RELAUNCH that a user
# actually needs, and the half a frozen pane would fail.
Assert "A12 the auto-relaunched pane is LIVE (input reaches the NEW child, output returns)" (
    Test-PaneLive -Exe $Exe -Target 'relp' -Tmp $tmpA -Tag 'SRA')

# A13 (T824): the replay put the DEAD program's modes back on, in a pane that
# program no longer controls. A4c proved they were on before the kill and A11
# proved the replay happened, so a `2` here can only be the reset the agent
# spliced in behind the replay. Without it the user's next mouse move types
# `35;1;12M` at the respawned shell's prompt.
$postMode = Get-ModeValue $probeDir $tmpA 'relp' 'VTPOST' 1003
Assert "A13 the replayed pane reports any-event mouse tracking RESET after relaunch" (
    $postMode -eq '2')
$postPaste = Get-ModeValue $probeDir $tmpA 'relp' 'VTPOSTBP' 2004
Assert "A13b bracketed paste is reset too (the whole replay_mode_reset set, not just mouse)" (
    $postPaste -eq '2')

Stop-TestProcs

# ============================================================================
"== B: session-relaunch=prompt - tombstone waits for a keystroke, then RELAUNCHes"
# ============================================================================
$tmpB = Join-Path $root 'prompt'
Launch $tmpB 't89g-prompt' 'prompt' $false
$paneB = Wait-FirstPane $tmpB 25
Assert "B1 startup pane came up under the local agent" ($null -ne $paneB)

Run-Cli '+split --direction=right --name=prp' "$tmpB\split.txt" 15 | Out-Null
$rowsB = Wait-AliveCount $tmpB 'b-setup' 2 18
Assert "B2 +split opened a second agent-backed session (2 alive)" ((Count-Alive $rowsB) -eq 2)

$mB = Wait-Manifest $tmpB { param($m) $null -ne (Sid-ByName $m 'prp') } 12
$prpSid = Sid-ByName $mB 'prp'
Assert "B3 the named pane's session id was captured in the manifest" ($null -ne $prpSid)

# Kill both app + agent (no ring-flush wait needed: the prompt path shows an
# affordance and defers the relaunch, independent of prior scrollback).
Stop-TestProcs

# Relaunch with policy=prompt. Restore ATTACHes the tombstone but must NOT
# respawn - the pane shows the affordance and the session stays a dead tombstone.
Launch $tmpB 't89g-prompt' 'prompt' $true

# The relp/prp id must be KNOWN but NOT alive (a tombstone awaiting a keystroke).
$rowsTomb = Wait-IdTombstone $tmpB 'b-tomb' $prpSid 30
$prpRow = Row-For $rowsTomb $prpSid
Assert "B4 policy=prompt did NOT auto-respawn - the id is a live tombstone (alive=false)" (
    $null -ne $prpRow -and $prpRow.alive -ne $true)

# The pane renders the press-any-key affordance.
$promptOk = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    $code = Run-Cli '+read --name=prp --lines=200' "$tmpB\read-prompt.txt" 10
    if ($code -eq 0) {
        $s = (Out-Text "$tmpB\read-prompt.txt") -replace '\s', ''
        if ($s -match 'pressanykeytorelaunch') { $promptOk = $true; break }
    }
    Start-Sleep -Milliseconds 700
}
Assert "B5 the pane shows 'Session ended: press any key to relaunch'" $promptOk

# The first keystroke fires the deferred RELAUNCH: the id goes alive.
Run-Cli '+send-keys --target=prp Enter' "$tmpB\key.txt" 12 | Out-Null
$rowsRe = Wait-IdAlive $tmpB 'b-relaunched' $prpSid 30
$prpBack = Row-For $rowsRe $prpSid
Assert "B6 a keystroke RELAUNCHed the tombstone - the SAME id is alive again" (
    $null -ne $prpBack -and $prpBack.alive -eq $true)

# And the divider printed on the deferred relaunch.
$promptDiv = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    $code = Run-Cli '+read --name=prp --lines=200' "$tmpB\read-relaunched.txt" 10
    if ($code -eq 0 -and (((Out-Text "$tmpB\read-relaunched.txt") -replace '\s', '') -match 'sessionrestarted')) {
        $promptDiv = $true; break
    }
    Start-Sleep -Milliseconds 700
}
Assert "B7 the deferred relaunch printed the '--- session restarted ---' divider" $promptDiv

# B8 (T652): the same claim on the deferred path. B6 says the agent reports the
# id alive and B7 that a divider printed; neither says the keystroke path is
# still wired to the shell that keystroke started.
Assert "B8 the keystroke-relaunched pane is LIVE (input reaches the NEW child, output returns)" (
    Test-PaneLive -Exe $Exe -Target 'prp' -Tmp $tmpB -Tag 'SRB')

# ============================================================================
if ($script:failures -gt 0) {
    "== DIAG: rerun read-post =="
    if (Test-Path "$tmpA\read-post.txt") { Get-Content "$tmpA\read-post.txt" -Raw }
    "== DIAG: prompt read =="
    if (Test-Path "$tmpB\read-prompt.txt") { Get-Content "$tmpB\read-prompt.txt" -Raw }
    "== DIAG: relpSid=$relpSid prpSid=$prpSid"
}

# ============================================================================
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
