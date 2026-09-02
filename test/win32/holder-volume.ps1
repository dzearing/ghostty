# T969 acceptance: a pane printing FASTER than the holder retains still has a
# recoverable window - scrollback is saved on VOLUME, not only on a timer.
#
# In the user's terms: after T911, a crash of the background session manager
# gives you back everything printed since scrollback was last saved. But it was
# only saved every 30 seconds, and only about a megabyte of unsaved output can
# be held anywhere in the meantime - so a pane in the middle of a noisy build
# printed past that between two saves and the OLDEST of it was dropped to make
# room. The pane you were watching was fine; what a crash could hand back was
# not. The panes that print the most are exactly the ones whose recovery is
# worth the most, which is why this is the case worth closing.
#
# So this harness measures the RING SNAPSHOT FILE on disk, like its T911 sibling
# `holder-durable.ps1` - the file a fresh viewer replays from is the thing that
# had the hole - but it overruns the holder's replay ring before the crash
# instead of staying inside it.
#
# SCALED-DOWN NUMBERS, deliberately. The shipped pair is a 1 MB holder ring and
# a snapshot due at 512 KB of unsaved output; this run sets 64 KB and 32 KB via
# the agent's env knobs. Same ratio, same mechanism, and the whole flood is over
# in a second or two - printing a megabyte through a ConPTY would take long
# enough to race the 30-second timer this harness has to stay inside, which would
# make the control arm measure the timer rather than the trigger. That the
# SHIPPED numbers hold the same ratio is pinned where it belongs, as a unit test
# over the two constants (`pty_holder_child.zig`).
#
# THREE numbers decide whether this harness measures anything, not two (T1116).
# The marker has to land in the gap between the holder's retention and the
# AGENT's output ring: past the holder (or the holder alone could hand it back,
# and the volume trigger is not what saved it) but still inside the ring (or no
# snapshot can reach it, because a snapshot writes the ring as it stands). The
# first version of this script sized the flood at "four times the holder ring"
# in the bytes it TYPED - and a ConPTY does not pass those bytes through, it
# re-renders: 256 KB of payload arrived as more than 2 MB, overran the agent's
# own ring, and the marker was gone from the only buffer a snapshot could have
# written. B4 and C3 read as "the flush never fires" when in fact it fired
# throughout and had nothing left to save.
#
# So the flood is sized in what the ring actually RECORDS, the placement is
# ASSERTED rather than assumed (B3b/B3c below, measured from the snapshot file's
# own length), and the agent ring is pinned by env so an inherited
# GHOSTTY_AGENT_RING_BYTES cannot move the target silently.
#
# Sections:
#   A. Baseline: a holder-backed pane, and PROOF that ring snapshots are running
#      in this run - a first marker typed and observed landing in a .ring file.
#      That also synchronizes the clock: a snapshot just happened, so the whole
#      30-second interval is available for section B.
#   B. The overrun. A second marker is typed, confirmed on screen and confirmed
#      ABSENT from disk; then enough is printed to push several times the
#      holder's retention through the pane, MEASURED off the snapshot file
#      rather than counted in typed bytes. THE assertion: the marker reaches a
#      .ring file well inside the periodic interval, because the volume trigger
#      fired, not the timer.
#   C. The crash. The session manager is hard-killed and the replacement adopts
#      the surviving holder. The marker is still on disk - the holder dropped it
#      long ago, so nothing but the volume-triggered snapshot could have kept it.
#
# `-NegativeControl` runs the SAME build with GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES=0,
# the off switch for the volume trigger, and asserts the marker is LOST. That is
# a real measurement of this box rather than an inverted assertion: if the
# control arm also keeps the marker, this harness is not measuring what it
# claims (the likeliest cause being a periodic snapshot landing inside section
# B's window, which would make both arms pass).
#
# Hermetic: a per-run $env:LOCALAPPDATA, a private IPC endpoint (lib\Isolation),
# GHOSTTY_LOCAL_AGENT_BIN pinned to the agent under test, and only processes
# whose ExecutablePath is the exe/agent under test are ever stopped - never the
# user's installed release, which owns their live sessions.
#
#   powershell -NoProfile -File test\win32\holder-volume.ps1
#   powershell -NoProfile -File test\win32\holder-volume.ps1 -NegativeControl
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl
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

# The scaled-down pair, held in the shipped ratio (threshold = half the ring).
$HolderReplayBytes = 65536
$VolumeBytes = 32768
# The agent's own output ring - the buffer a snapshot writes. Pinned rather than
# left at its 2 MB default so an inherited GHOSTTY_AGENT_RING_BYTES cannot move
# the far edge of the window the marker has to land in, and deliberately the
# widest of the three: the flood has to clear the holder's 64 KB and stay under
# this, and both margins are asserted below (B3b/B3c).
$RingBytes = 1048576
# One CHUNK of the flood, typed as its own command. Section B keeps sending
# chunks until the ring has RECORDED twice the holder's retention, so the volume
# that matters is measured on the way rather than guessed from the payload - see
# the flood block for why a ConPTY makes the two numbers unrelated.
#
# The line WIDTH is load-bearing and it is 80, inside the pane's 100 columns.
# The first version printed 500-character lines: every one of them wrapped over
# five rows, each row scrolled the viewport, and a ConPTY answers a scroll by
# re-rendering - so 16 KB of payload took over a minute to get through the pane
# and arrived as hundreds of KB. Lines that fit the pane cost about what they
# say they cost.
$FloodChunkLines = 256
$FloodWidth = 80

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'HOLDER-VOLUME' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'HOLDER-VOLUME' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
# T1239: every launch below - the GUI and the CLI verbs that talk to it - goes
# through the harness, so the windows land on a background desktop instead of
# across whatever the user is reading.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# --- process helpers: ONLY ever the binaries under test ----------------------

function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgentProcs {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe })
}
function Get-TestAgents {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -notmatch '--pty-host' })
}
function Get-TestHolders {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -match '--pty-host' })
}
function Test-Alive([int]$procId) {
    if ($procId -le 0) { return $false }
    return $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
}
function Stop-Everything {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-TestAgents)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
    foreach ($p in (Get-TestHolders)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 400
}
function Wait-NewAgent($excludePids, $timeoutSec = 45) {
    $excludePids = @($excludePids | ForEach-Object { [int]$_ })
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $fresh = @((Get-TestAgents) | Where-Object { $excludePids -notcontains [int]$_.ProcessId })
        if ($fresh.Count -gt 0) { return [int]$fresh[0].ProcessId }
        Start-Sleep -Milliseconds 400
    }
    return 0
}

# --- CLI plumbing ------------------------------------------------------------

# T1239: every CLI verb runs on the TEST DESKTOP, so a verb that auto-launches
# the app cannot throw a window across what the user is reading. The old shape
# was a `cmd /c "... > file"` dance, which existed only because a GUI-subsystem
# exe writes nothing to a PowerShell redirect (T245) - the harness captures both
# handles to a file itself, so the dance goes with it. The wait is still bounded,
# or a wedged server hangs the script instead of failing it.
function Run-Cli([string]$argsLine, [string]$out, [int]$timeoutSec = 15) {
    $argv = @($argsLine -split '\s+' | Where-Object { $_ -ne '' })
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $argv -TimeoutSec $timeoutSec
    $text = if ($null -ne $r.Output) { $r.Output } else { '' }
    [System.IO.File]::WriteAllText($out, $text)
    if ($r.TimedOut) { return $null }
    return $r.ExitCode
}
function Run-CliArgs([string[]]$argv, [string]$out, [int]$timeoutSec = 15) {
    return Run-Cli ($argv -join ' ') $out $timeoutSec
}
function Out-Text([string]$f) { if (Test-Path $f) { return (Get-Content $f -Raw) } return '' }

function Get-Sessions([string]$tmp, [string]$tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    try { $rows = (Out-Text "$tmp\sess-$tag.json") | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Read-PaneText([string]$tmp, [string]$target, [string]$tag, [int]$lines = 60) {
    $rc = Run-Cli "+read --name=$target --lines=$lines" "$tmp\read-$tag.txt" 15
    if ($rc -ne 0) { return '' }
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', '')
}
function Wait-PaneHas([string]$tmp, [string]$target, [string]$tag, [string]$needle, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        if ((Read-PaneText $tmp $target "$tag$i") -match [regex]::Escape($needle)) { return $true }
        $i++
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in (Windows-Of $tree)) {
        foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits }
    }
    return , $acc
}
function Get-Tree([string]$tmp, [string]$tag) {
    $rc = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($rc -ne 0) { return $null }
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}

# --- the measurement: what is on DISK ----------------------------------------

# Every ring snapshot under the per-run state dir, read as bytes. Found by
# extension rather than re-derived from a path, so a state-dir move cannot
# silently turn this into a test of nothing.
function Get-RingFiles([string]$root) {
    return , @(Get-ChildItem -Path $root -Filter '*.ring' -Recurse -File -ErrorAction SilentlyContinue)
}
function Ring-Has([string]$root, [string]$needle) {
    foreach ($f in (Get-RingFiles $root)) {
        $txt = ''
        try { $txt = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::ASCII) } catch { continue }
        if ($txt -match [regex]::Escape($needle)) { return $true }
    }
    return $false
}
# The length of ONE session's snapshot file - the observable this harness sizes
# its flood against (T1116). It is the ring as the agent holds it, so its growth
# across the flood is the real byte volume the ConPTY produced, and its ceiling
# is the ring capacity. 0 when the session has never been snapshotted.
function Ring-LenFor([string]$root, [string]$sessionId) {
    if (-not $sessionId) { return 0 }
    foreach ($f in (Get-RingFiles $root)) {
        if ($f.BaseName -eq $sessionId) { return [int]$f.Length }
    }
    return 0
}
function Wait-RingHas([string]$root, [string]$needle, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Ring-Has $root $needle) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

$root = Join-Path $env:TEMP "ghoztty-holder-volume-$PID"
$tmp = Join-Path $root 'run'
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER
$savedDurable = $env:GHOZTTY_AGENT_DURABLE_ACK
$savedReplay = $env:GHOZTTY_AGENT_HOLDER_REPLAY_BYTES
$savedVolume = $env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES
$savedRing = $env:GHOSTTY_AGENT_RING_BYTES
$td = New-TestDesktop

try {
    Stop-Everything
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # Holder-backed spawning is the DEFAULT since T909: clear only an inherited
    # opt-out, because with holders off there is no replay buffer to overrun and
    # the whole script would measure nothing.
    Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue
    # T911's durability gate is the floor this builds on: without it the holder
    # frees on delivery and section C is a measurement of T911, not of T969.
    Remove-Item env:GHOZTTY_AGENT_DURABLE_ACK -ErrorAction SilentlyContinue
    $env:GHOZTTY_AGENT_HOLDER_REPLAY_BYTES = "$HolderReplayBytes"
    $env:GHOSTTY_AGENT_RING_BYTES = "$RingBytes"
    if ($NegativeControl) {
        # The control arm: same build, same box, volume trigger OFF - i.e. the
        # pre-T969 behavior, where only the 30-second timer writes scrollback.
        $env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES = '0'
        Say "== NEGATIVE CONTROL: GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES=0 (the marker must be LOST)"
    } else {
        $env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES = "$VolumeBytes"
    }

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'volume969')
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    # ========================================================================
    Say "== A: baseline - a holder-backed pane, and ring snapshots proven live"
    # ========================================================================
    $before = @((Get-TestAgents) | ForEach-Object { [int]$_.ProcessId })
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--title=t969-volume', '--window-width=100', '--window-height=30'))

    $appPid = 0
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $rc = Run-Cli '+list --json' "$tmp\list-a.json" 10
        if ($rc -eq 0 -and (Out-Text "$tmp\list-a.json") -match '\S') {
            $app = @(Get-TestApps | Where-Object { $_.CommandLine -like '*t969-volume*' })
            if ($app.Count -ge 1) { $appPid = [int]$app[0].ProcessId; break }
        }
        Start-Sleep -Milliseconds 600
    }
    Assert 'A1 premise: the app is up and answering IPC' ($appPid -gt 0)
    if ($appPid -le 0) {
        Write-TestVerdict -Label 'HOLDER-VOLUME' -Pass $script:passes -Fail $script:failures
    }
    Assert-GhozttyIsolated -Exe $Exe

    $pane = 't969p'
    $firstId = $null
    foreach ($lf in (All-Leaves (Get-Tree $tmp 'a1'))) { if (-not $firstId) { $firstId = $lf.id } }
    if ($firstId) {
        Run-Cli "+split --pane=$firstId --name=$pane --direction=right" "$tmp\split.txt" 20 | Out-Null
    } else {
        Run-Cli "+new-window --name=$pane" "$tmp\newwin.txt" 20 | Out-Null
    }

    $agentPid = Wait-NewAgent $before 45
    Assert 'A2 premise: a session manager is running' ($agentPid -ne 0)

    $paneLeaf = $null
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $lv = @((All-Leaves (Get-Tree $tmp 'a2')) | Where-Object { $_.name -eq $pane })
        if ($lv.Count -eq 1 -and $lv[0].session_id) { $paneLeaf = $lv[0]; break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'A3 the named pane exists and is agent-backed (it carries a session id)' (
        $null -ne $paneLeaf)
    if ($null -eq $paneLeaf) {
        Write-TestVerdict -Label 'HOLDER-VOLUME' -Pass $script:passes -Fail $script:failures
    }
    $sessionId = [string]$paneLeaf.session_id

    $shellPidA = 0
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        foreach ($r in (Get-Sessions $tmp 'a')) {
            if ([string]$r.id -eq $sessionId -and $r.alive -eq $true) { $shellPidA = [int]$r.pid }
        }
        if ($shellPidA -gt 0) { break }
        Start-Sleep -Milliseconds 600
    }
    Assert 'A4 the agent roster reports a live shell pid for that session' ($shellPidA -gt 0)
    Assert 'A5 the session is holder-backed (a --pty-host process is serving it)' (
        (Get-TestHolders).Count -ge 1)

    # A first marker, followed all the way to DISK. Two things at once: it proves
    # ring snapshots are running in this run at all, and it tells us a snapshot
    # just fired - so section B has the whole periodic interval to itself.
    $warm = "T969WARM$PID" + "Z"
    Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $warm, 'Enter') "$tmp\keys-warm.txt" 12 | Out-Null
    Assert 'A6 the pane is LIVE (the shell echoed the warm-up marker)' (
        Wait-PaneHas $tmp $pane 'warm' $warm 30)
    $warmOnDisk = Wait-RingHas $tmp $warm 75
    Assert 'A7 ring snapshots are running: the warm-up marker reached a .ring file' $warmOnDisk
    if (-not $warmOnDisk) {
        Say "    diagnostic: ring files seen -> $((Get-RingFiles $tmp) | ForEach-Object { $_.Name })"
        Write-TestVerdict -Label 'HOLDER-VOLUME' -Pass $script:passes -Fail $script:failures
    }
    $snapshotAt = Get-Date
    # The far end of the flood's target window: what this session's snapshot file
    # holds BEFORE the flood. Everything section B measures is growth from here.
    $ringLenBefore = Ring-LenFor $tmp $sessionId

    # ========================================================================
    Say "== B: the overrun - a marker, then more output than the holder can hold"
    # ========================================================================
    $marker = "T969GAP$PID" + "Z"
    Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $marker, 'Enter') "$tmp\keys-gap.txt" 12 | Out-Null
    Assert 'B1 the marker is on screen (the shell printed it)' (
        Wait-PaneHas $tmp $pane 'gap' $marker 20)

    # THE premise. If this fails, a snapshot landed between the marker and here
    # and the run is measuring a marker that was already safe - which would pass
    # either way.
    Assert 'B2 premise: the marker is NOT in any ring snapshot yet' (-not (Ring-Has $tmp $marker))

    # THE FLOOD, measured in what the RING RECORDS (T1116). Chunks are typed
    # until the snapshot file has grown by twice the holder's retention - which
    # is the property section C depends on (the marker is past the holder's
    # horizon) and the one B4 needs (it is still inside the ring a snapshot
    # writes). Both edges are asserted below rather than assumed.
    #
    # Two things this deliberately does NOT do, each of which made an earlier
    # version measure something else:
    #
    #  * It does not size the flood in TYPED bytes. A ConPTY re-renders rather
    #    than forwarding, and the amplification is large (~17x here: 20 KB typed
    #    arrives as ~348 KB) and not linear in the burst size. The original
    #    256 KB burst overran the agent's whole 2 MB ring, so the marker was gone
    #    from the only buffer a snapshot could write and B4/C3 read as a flush
    #    that never fires.
    #  * It does not wait for the flood's end marker to appear ON SCREEN. `+read`
    #    answers from the APP's terminal state, and the app is far behind the
    #    agent while a Debug build ingests a flood - the ring had all 348 KB
    #    inside a minute while the pane still showed nothing but 'F's five
    #    minutes later. The ring file is both the faster instrument and the one
    #    this harness is actually about.
    $floodTarget = $HolderReplayBytes * 2
    $floodCeiling = [int]($RingBytes / 2)
    $floodFile = Join-Path $tmp 'flood.txt'
    $recorded = 0
    $typed = 0
    $markerSecs = -1
    # T1239: how long a chunk is given before the next one is typed. Long enough
    # for 256 lines to print, short enough that several chunks' output is still
    # unsaved at once.
    $ChunkDwellSec = 2
    # BOTH ARMS TYPE THE SAME FLOOD. The control used to type ONE chunk and
    # dwell, which worked only while a rendering ConPTY inflated that chunk past
    # the holder's 64 KB retention on the user's desktop; off the input desktop
    # a chunk is about its own size, 20 KB never overruns the holder, and the
    # control KEPT the marker for a reason that had nothing to do with the
    # trigger it is controlling for. It now floods exactly as the measured arm
    # does - the trigger being off is the only difference between them - and
    # finishes well inside the 30-second periodic pass, so the clock still
    # cannot write the marker and be mistaken for the volume.
    $maxChunks = 8
    for ($c = 1; $c -le $maxChunks; $c++) {
        # The end marker is assembled from two halves inside the pane's command so
        # the contiguous string cannot appear in the shell's echo of the command
        # line; it is a diagnostic here rather than a gate.
        $doneHead = "T969DO"
        $doneTail = "NE$PID" + "C$c" + "Z"
        $done = $doneHead + $doneTail
        $floodCmd = "powershell -NoProfile -Command `"1..$FloodChunkLines | ForEach-Object { 'F' * $FloodWidth }; 'x' + '$doneHead' + '$doneTail'`""
        [IO.File]::WriteAllText($floodFile, $floodCmd, [Text.Encoding]::ASCII)
        $t0 = Get-Date
        $sendRc = Run-CliArgs @('+send-keys', "--target=$pane", "--keys-file=$floodFile", 'Enter') "$tmp\keys-flood$c.txt" 15
        if ($sendRc -ne 0) { Say "    diagnostic: chunk $c send rc=$sendRc, cli said '$(('' + (Out-Text "$tmp\keys-flood$c.txt")).Trim())'" }

        # Watch the ring grow (and watch for the marker landing on disk, which is
        # what B4 scores). Bounded, so a pane that prints nothing fails rather
        # than hangs.
        # T1239: the chunks go BACK TO BACK. The old shape waited up to 60 s on
        # every one of them - longer than the agent's 30-second periodic pass -
        # so each chunk's output was written out (and the unsaved counter reset
        # to zero) before the next chunk arrived, and no amount of flooding
        # could reach the volume threshold by accumulation. That was invisible
        # while the script ran on the user's own desktop: a rendering ConPTY
        # re-renders a scrolling flood into ~17x its payload, so ONE chunk
        # cleared the 32 KB trigger on its own. Off the input desktop nothing
        # re-renders, a chunk arrives at about the size it says it is, and
        # 20 KB sits just under the trigger - measured, both ways, on box. The
        # short dwell is what lets unsaved output PILE UP, which is the
        # condition the trigger exists to notice. Patience for a slow box moved
        # to the settle loop after the flood, where waiting cannot suppress the
        # very thing being measured.
        $chunkDeadline = (Get-Date).AddSeconds($ChunkDwellSec)
        while ((Get-Date) -lt $chunkDeadline) {
            Start-Sleep -Milliseconds 700
            if ($markerSecs -lt 0 -and (Ring-Has $tmp $marker)) {
                $markerSecs = [int]((Get-Date) - $snapshotAt).TotalSeconds
            }
            $recorded = (Ring-LenFor $tmp $sessionId) - $ringLenBefore
            if ($recorded -ge $floodTarget -or $recorded -ge $floodCeiling) { break }
        }
        $typed += $FloodChunkLines * $FloodWidth
        $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        $arm = if ($NegativeControl) { ' (control)' } else { '' }
        Say "    chunk $c$arm : $($FloodChunkLines * $FloodWidth) B typed; ring has recorded $recorded B in $secs s"
        if ($recorded -ge $floodTarget -or $recorded -ge $floodCeiling) { break }
    }
    # T1239: settle. The chunks were typed back to back, so the pane can still
    # be printing when the last one is sent - wait for the ring to reach the
    # target rather than scoring it at the instant the typing stopped. Waiting
    # HERE cannot mask the trigger the way the old per-chunk wait did: the
    # output that has to cross the threshold is already through the pane.
    $settleDeadline = (Get-Date).AddSeconds(30)
    while (-not $NegativeControl -and (Get-Date) -lt $settleDeadline) {
        if ($recorded -ge $floodTarget -or $recorded -ge $floodCeiling) { break }
        Start-Sleep -Milliseconds 700
        if ($markerSecs -lt 0 -and (Ring-Has $tmp $marker)) {
            $markerSecs = [int]((Get-Date) - $snapshotAt).TotalSeconds
        }
        $recorded = (Ring-LenFor $tmp $sessionId) - $ringLenBefore
    }
    $floodSecs = [int]((Get-Date) - $snapshotAt).TotalSeconds
    Say "    (flood done $floodSecs s after the last snapshot; the periodic pass is 30 s)"

    # THE PLACEMENT, asserted rather than assumed. Both edges of the window the
    # marker has to sit in: past the holder's retention (else the holder could
    # hand the marker back on its own and B4/C3 would prove nothing about the
    # trigger) and inside the agent's ring (else the marker is gone from the only
    # buffer a snapshot writes, and no flush however prompt could have saved it).
    if (-not $NegativeControl) {
        Say ("    (typed $typed B -> ring recorded $recorded B; holder retains " +
             "$HolderReplayBytes B, ring holds $RingBytes B)")
        Assert 'B3 the flood pushed more through the pane than the holder retains' (
            $recorded -gt $HolderReplayBytes)
        Assert 'B3b premise: the flood stayed inside the agent ring (a snapshot can still reach the marker)' (
            $recorded -lt $floodCeiling)
    }

    # THE assertion. The marker reached disk while the flood was still running -
    # well inside the periodic interval - so the trigger that wrote it was the
    # VOLUME of output, not the clock. `$markerSecs` is when it appeared, counted
    # from section A's snapshot, so a periodic pass cannot be mistaken for it.
    if ($NegativeControl) {
        Assert 'B4 (control) with the trigger off, nothing wrote the marker inside the interval' (
            $markerSecs -lt 0)
    } else {
        Say "    (the marker reached disk $markerSecs s after the last snapshot)"
        Assert 'B4 the marker reached a .ring file inside the periodic interval (the volume trigger fired)' (
            $markerSecs -ge 0 -and $markerSecs -lt 24)
    }

    # Hard kill: no shutdown path runs, so nothing flushes on the way out. That
    # is the crash this task is about.
    Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Assert 'B5 premise: the session manager is really gone' (-not (Test-Alive $agentPid))
    Assert 'B6 premise: the shell outlived it (the holder still owns it)' (Test-Alive $shellPidA)

    # ========================================================================
    Say "== C: after the crash - what a fresh viewer can still replay"
    # ========================================================================
    $newAgentPid = Wait-NewAgent (@($before) + @($agentPid)) 60
    Assert 'C1 a replacement session manager came up' ($newAgentPid -ne 0 -and $newAgentPid -ne $agentPid)

    # Adoption, not relaunch - the same shell pid. Without this the holder never
    # replayed anything and C3 would be measuring the wrong failure.
    $shellPidC = 0
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        foreach ($r in (Get-Sessions $tmp 'c')) {
            if ([string]$r.id -eq $sessionId -and $r.alive -eq $true) { $shellPidC = [int]$r.pid }
        }
        if ($shellPidC -gt 0) { break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'C2 premise: the same shell was adopted (same pid, nothing relaunched)' (
        $shellPidC -gt 0 -and $shellPidC -eq $shellPidA)

    # THE end-to-end assertion. The holder dropped these bytes long before the
    # crash - they were four floods ago in a 64 KB ring - so the only thing that
    # can still hand them back is a snapshot the volume trigger wrote.
    $recovered = Wait-RingHas $tmp $marker 100
    if ($NegativeControl) {
        Assert 'C3 (control) the marker was LOST, as it is lost without the volume trigger' (-not $recovered)
    } else {
        Assert 'C3 the marker is still on disk after the crash' $recovered
        if (-not $recovered) {
            Say "    diagnostic: ring files -> $((Get-RingFiles $tmp) | ForEach-Object { "$($_.Name) ($($_.Length) bytes)" })"
        }
    }
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-Everything
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    if ($null -ne $savedDurable) { $env:GHOZTTY_AGENT_DURABLE_ACK = $savedDurable }
    else { Remove-Item env:GHOZTTY_AGENT_DURABLE_ACK -ErrorAction SilentlyContinue }
    if ($null -ne $savedReplay) { $env:GHOZTTY_AGENT_HOLDER_REPLAY_BYTES = $savedReplay }
    else { Remove-Item env:GHOZTTY_AGENT_HOLDER_REPLAY_BYTES -ErrorAction SilentlyContinue }
    if ($null -ne $savedRing) { $env:GHOSTTY_AGENT_RING_BYTES = $savedRing }
    else { Remove-Item env:GHOSTTY_AGENT_RING_BYTES -ErrorAction SilentlyContinue }
    if ($null -ne $savedVolume) { $env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES = $savedVolume }
    else { Remove-Item env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard holder-volume -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'HOLDER-VOLUME' -Pass $script:passes -Fail $script:failures
