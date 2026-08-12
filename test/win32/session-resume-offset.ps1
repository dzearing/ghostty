# T739 acceptance: the resume offset a re-attach records must be the agent's
# stream head, not the head plus the size of the repaint the agent just injected.
#
# The defect: `Remote.appliedOffset()` - the number persisted in the session
# manifest as the NEXT attach's `last_byte_offset` - counted every byte fed to
# the parser. Two of the things the agent sends on ATTACH are not stream bytes
# at all: its `[N bytes of scrollback lost]` marker, and the `grid_snapshot`
# repaint of the visible screen. So every single re-attach recorded a position
# PAST the end of the agent's stream by exactly the repaint's size (169 bytes,
# measured while landing T666). The next attach was then clamped back to the
# head (T532) and whatever real output sat between the two was never replayed -
# invisible on a quiet pane, because the repaint covers the same screen, and
# silently lost output on a busy one.
#
# The fix labels the injection on the wire (`DATA_REPAINT`, 0x15, gated on
# `capability.repaint_data`), because it cannot be inferred: a repaint anchored
# at the head and the first LIVE frame after it are identical on the wire.
#
# The arms, all scored from the app's own attach log - the only place either
# number is observable, since a pane that skipped 169 bytes and a pane that did
# not look exactly the same:
#
#   A. Three kill/restore cycles of a QUIET pane. Every attach must report
#      `requested == head`, and the "recorded offset ... is ahead of the agent's
#      stream head" clamp warning must never appear.
#   B. The teeth, from the same tree: the same cycles with
#      GHOZTTY_RESUME_COUNT_BYTES=1, which puts the pre-T739 accounting back and
#      changes nothing else. The overshoot MUST return and the clamp MUST fire -
#      arm A asserts the absence of something, and an absence is evidence only
#      when the same harness can be made to see it present.
#   C. Skew: the same cycles with GHOSTTY_AGENT_SUPPRESS_CAPS=repaint_data, an
#      agent advertising the HELLO of a build that predates 0x15. The pane must
#      still restore, still be live, and still not overshoot.
#
# Arm C passing is worth reading carefully, because it says where the fix
# actually lives. The accounting is client-side and anchor-authoritative, so on
# WINDOWS it lands even against an old agent: ConPTY repaints after every
# attach, that paint is real stream data anchored at the head, and it re-states
# the true position over the miscounted one. What the 0x15 framing buys is that
# the position is right BY CONSTRUCTION rather than because something arrived
# afterwards to correct it - which is the only thing that holds for a peer that
# does not repaint on attach. That half is asserted in the unit lanes
# (`src/remote/agent/server.zig`, `src/remote/connection.zig`), not here.
#
# Hermetic: a per-run LOCALAPPDATA, GHOSTTY_LOCAL_AGENT_BIN and IPC pipe suffix,
# run on a BACKGROUND Win32 desktop, and it only ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\session-resume-offset.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Cycles = 3,
    [switch]$KeepRoot,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$repo = 'D:\git\ghoztty'
$root = Join-Path $env:TEMP "ghoztty-resume-offset-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# Kill ONLY the app: the detached agent keeps its PTYs, which is the whole
# scenario (quit / crash / upgrade, then re-attach).
function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: on (default) - the restore path IS the subject.
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit, or ExitCode reads empty and
    # every `-eq 0` gate scores a working CLI as a failure (lib\ExitCodeAudit.ps1).
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tag, $timeoutSec = 12) {
    Run-CliArgs @('+list', '--json') "$tmp\list-$tag.json" $timeoutSec | Out-Null
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function All-Leaves($tree) {
    if ($null -eq $tree) { return , @() }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    $acc = @()
    foreach ($w in @($windows)) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Wait-PaneId($tag, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        foreach ($leaf in All-Leaves (Get-List $tag)) {
            if ($leaf.id) { return [string]$leaf.id }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

# ---- app log (the oracle) --------------------------------------------------
# Debug builds are Console-subsystem, so std.log goes to STDERR, captured per
# launch. Opened ReadWrite because the app still holds the handle.
function Read-AppLog($path) {
    if (-not $path -or -not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le 0) { return '' }
            $buf = New-Object byte[] $fs.Length
            $n = $fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        } finally { $fs.Dispose() }
    } catch { return '' }
}
# Poll: the line may not be flushed yet, and a single read would turn a timing
# gap into a false failure.
function Wait-AttachLine($path, $timeoutSec = 40) {
    $rx = 'attach: requested=(\d+) head=(\d+) resumed_at=(\d+)'
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $m = [regex]::Match((Read-AppLog $path), $rx)
        if ($m.Success) {
            return @{
                requested = [uint64]$m.Groups[1].Value
                head      = [uint64]$m.Groups[2].Value
                resumed   = [uint64]$m.Groups[3].Value
            }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}
function Log-HasClampWarning($path) {
    return ((Read-AppLog $path) -match 'is ahead of the agent''s stream head')
}

# The manifest write is DEBOUNCED off layout mutations, and this test kills the
# app outright (no graceful quit, so no final sync) - so the capture whose
# offset the next launch resumes from has to be provoked. A window title pin is
# the cheapest mutation: it marks the layout dirty and changes nothing about the
# tree, and prints nothing into the pane (which matters here - the pane must
# stay QUIET after the capture, or `requested == head` is not the claim).
function Provoke-ManifestWrite($pane, $tag) {
    Run-CliArgs @('+rename', "--target=$pane", '--title=t739-quiet') "$tmp\ren-$tag.txt" 12 | Out-Null
    Start-Sleep -Milliseconds 1200
}
function Manifest-Path { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }
function Manifest-Offsets {
    $p = Manifest-Path
    if (-not (Test-Path $p)) { return @() }
    $raw = Out-Text $p
    return @([regex]::Matches($raw, '"screen_snapshot_offset"\s*:\s*(\d+)') |
        ForEach-Object { [uint64]$_.Groups[1].Value })
}

# One kill/restore cycle. Returns the attach numbers the restored pane logged.
function Invoke-RestoreCycle($n, $arm) {
    Stop-AppOnly
    $log = Join-Path $tmp "app-$arm-$n.err.txt"
    # persistence: on (default) - a restore is the entire point.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @() -StdErr $log
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 45000
    if ($top -eq [IntPtr]::Zero) { return @{ up = $false; log = $log } }
    $att = Wait-AttachLine $log 45
    return @{ up = $true; log = $log; attach = $att; pid = $app.Pid }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$saved = @{
    lad  = $env:LOCALAPPDATA
    bin  = $env:GHOSTTY_LOCAL_AGENT_BIN
    pipe = $env:GHOZTTY_PIPE_SUFFIX
    supp = $env:GHOSTTY_AGENT_SUPPRESS_CAPS
    seam = $env:GHOZTTY_RESUME_COUNT_BYTES
}
$env:GHOZTTY_PIPE_SUFFIX = '-resumeoffset'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

$null = Assert-GhozttyIsolatedBuild -Exe $Exe
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)

$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

foreach ($arm in @('A', 'B', 'C')) {
    # Removed, not emptied: an empty value is still a value the agent reads.
    [Environment]::SetEnvironmentVariable('GHOSTTY_AGENT_SUPPRESS_CAPS', $null)
    [Environment]::SetEnvironmentVariable('GHOZTTY_RESUME_COUNT_BYTES', $null)
    switch ($arm) {
        'A' { Say "== A: $Cycles kill/restore cycles of a quiet pane - the recorded offset IS the head" }
        'B' {
            Say "== B: teeth - the pre-T739 accounting, from this same tree, must overshoot"
            $env:GHOZTTY_RESUME_COUNT_BYTES = '1'
        }
        'C' {
            Say "== C: skew - an agent that predates DATA_REPAINT still restores, live and unclamped"
            # The running agent already negotiated WITH the capability; a fresh
            # one has to come up under the suppression for the HELLO to change.
            $env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'repaint_data'
        }
    }
    Stop-TestProcs
    Remove-Item -Recurse -Force (Join-Path $tmp 'ghoztty') -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null

    # Launch 0: an ordinary OPEN. Nothing is injected on an open, so this
    # launch's offset accounting is exact on any build - it is the baseline the
    # cycles below start from.
    $log0 = Join-Path $tmp "app-$arm-0.err.txt"
    $app0 = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t739') -StdErr $log0
    $up0 = (Wait-TestWindow -ProcessId $app0.Pid -Class 'GhozttyWindow' -TimeoutMs 45000) -ne [IntPtr]::Zero
    Assert "$arm.0 the first launch came up" $up0
    if (-not $up0) { continue }
    $pane = Wait-PaneId "$arm-0" 45
    Assert "$arm.0 the startup pane is addressable" ($null -ne $pane)
    if (-not $pane) { continue }
    # A live pane, not a painted one: everything below is about what its session
    # has produced, so a frozen pane would make the numbers meaningless.
    Assert "$arm.0 the pane is live before any restore" `
        (Test-PaneLive -Exe $Exe -Target $pane -Tmp $tmp -Tag "$arm-live0")
    Provoke-ManifestWrite $pane "$arm-0"
    Assert "$arm.0 the manifest recorded a resume offset" (@(Manifest-Offsets | Where-Object { $_ -gt 0 }).Count -ge 1)

    $overshoots = 0
    $warned = 0
    $cyclesRun = 0
    for ($i = 1; $i -le $Cycles; $i++) {
        $r = Invoke-RestoreCycle $i $arm
        Assert "$arm.$i the restored app came up" ($r.up)
        if (-not $r.up) { break }
        $att = $r.attach
        Assert "$arm.$i the restored pane re-ATTACHED (its numbers are in the log)" ($null -ne $att)
        if ($null -eq $att) { break }
        $cyclesRun++
        Say "     requested=$($att.requested) head=$($att.head) resumed_at=$($att.resumed)"
        if ($att.requested -gt $att.head) { $overshoots++ }
        if (Log-HasClampWarning $r.log) { $warned++ }

        if ($arm -ne 'B') {
            # The claim, exactly: for a pane that has produced nothing since the
            # manifest was written, the position we recorded is the position the
            # session reached - not that plus our own repaint.
            #
            # Arm C holds it too, and that is not luck: the anchor-authoritative
            # accounting is client-side, so it lands even when the agent frames
            # its repaint as plain DATA - the ConPTY paint that follows the
            # repaint is anchored at the head and re-states the true position.
            # What the 0x15 framing adds is that this no longer DEPENDS on
            # something arriving afterwards to correct it (a peer that does not
            # repaint on attach has nothing behind the injection).
            Assert "$arm.$i requested offset == agent head ($($att.requested) vs $($att.head))" `
                ($att.requested -eq $att.head)
            Assert "$arm.$i the resume was honored, not clamped" ($att.resumed -eq $att.requested)
        }

        $pane = Wait-PaneId "$arm-$i" 45
        Assert "$arm.$i the restored pane is addressable" ($null -ne $pane)
        if (-not $pane) { break }
        Assert "$arm.$i the restored pane is LIVE, not a picture" `
            (Test-PaneLive -Exe $Exe -Target $pane -Tmp $tmp -Tag "$arm-live$i")
        Provoke-ManifestWrite $pane "$arm-$i"
    }

    if ($arm -eq 'B') {
        # Teeth: with the old accounting nothing else about the run changes, so
        # arm A's green is only evidence because this arm goes red. The
        # overshoot is the injected repaint's size, on every cycle, and the
        # clamp that catches it is where the real output was being skipped.
        # All but the FIRST cycle, and that exception is structural rather than
        # slack: cycle 1 resumes from an offset the OPEN-era launch recorded,
        # and an OPEN has no injected repaint to miscount. The error is minted
        # BY an attach, so it shows up from the attach after the first.
        $want = $cyclesRun - 1
        Assert "B the pre-T739 accounting overshoots the head ($overshoots of $cyclesRun cycles, want $want)" `
            ($cyclesRun -gt 1 -and $overshoots -eq $want)
        Assert "B ...and the clamp fires on it, which is where output was lost ($warned of $cyclesRun)" `
            ($cyclesRun -gt 1 -and $warned -eq $want)
    } else {
        Assert "$arm no attach was ever clamped back to the head ($warned warning(s) across $cyclesRun cycles)" `
            ($cyclesRun -gt 0 -and $warned -eq 0)
        Assert "$arm no attach ever asked to resume past the stream head ($overshoots of $cyclesRun)" `
            ($cyclesRun -gt 0 -and $overshoots -eq 0)
    }
}

} finally {
    Stop-TestProcs
    Stop-TestForegroundWatch
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    $env:GHOSTTY_AGENT_SUPPRESS_CAPS = $saved.supp
    $env:GHOZTTY_RESUME_COUNT_BYTES = $saved.seam
    # -KeepRoot leaves the per-launch app logs behind: they are the only record
    # of what each attach decided, and a failing arm is unreadable without them.
    if ($KeepRoot) { Write-Host "  (kept: $root)" }
    else { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures
