# T412 acceptance: what one session-layout sync COSTS the UI thread, measured
# on box at the pane counts the user actually runs.
#
# WHY THIS EXISTS. T109 made every layout sync do a per-pane structured VT dump
# (up to 600 rows) under the pane's renderer mutex, and `App.syncSessionLayout`
# runs on the UI thread. Two triggers are not rare:
#
#   * a window DRAG or a maximize/restore writes it synchronously at the end of
#     the gesture (T220 - the manifest is written before the placement memory
#     so a kill between the two cannot strand the frame), and
#   * the T922 refresh writes it up to every two seconds while panes print.
#
# T412 was filed believing the drag re-armed a 250 ms debounce over and over.
# It does not - and has not since T220 - so the question narrowed rather than
# went away: ONE synchronous capture at the end of every gesture, on the thread
# that has to repaint. Nothing measured said whether that was affordable.
#
# WHAT IT FOUND, and what changed because of it. Eight panes printing
# continuously cost **991 ms** per capture, mean 593 ms - a full second of frozen
# UI every time the user let go of a window edge, and again whenever the T922
# refresh fired. Almost none of it was the dump itself (151 KB of VT); it was
# waiting on `renderer_state.mutex`, which the IO thread holds while feeding
# output. So a sync now says whether it needs FRESH screens: a drag, a tab, a
# split, a rename move the topology and carry the last screens forward
# (`ScreenCapture.reuse`, `Surface.last_snapshot`), and only the T922 refresh -
# which waits for quiet first - and the quit/shutdown flush re-dump. Section F
# is what keeps that true.
#
# HOW IT MEASURES. `App.reportLayoutCost` (T412) emits one machine-readable line
# per sync - `session-layout sync total_us=... capture_us=... write_us=...
# push_us=... panes=... snapshot_bytes=... wrote=... fresh_screens=...` - at
# DEBUG, which a Debug
# build writes to stderr and this script redirects to a file. (At INFO, and only
# when the sync missed the frame budget, so a release user's log carries the
# hitch and nothing else.) The script then drives real drag-resize gestures
# through the real WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE path and reads the samples
# those gestures produced.
#
# THE ARMS. Three pane counts (1, 3, 8), each measured twice:
#
#   * IDLE - every pane sitting at a prompt. The floor.
#   * FLOODED - every split printing continuously. This is the interesting one:
#     the dump takes `renderer_state.mutex`, which the IO thread holds while
#     feeding output, so a busy pane is the worst case and an idle one says
#     almost nothing about it.
#
# THE BUDGET is one display frame at 60 Hz (16,667 us), because that is the unit
# the cost is spent in - the sync blocks the message pump, so a sync that fits
# in a frame cannot drop one and a sync that does not is a visible hitch at the
# end of the drag. `src\apprt\win32\layout_cost.zig` owns that number; this
# script asserts against it.
#
# Fully hermetic: a per-run $env:LOCALAPPDATA, a private IPC endpoint, its own
# agent binary, and a background test desktop. It only ever kills ghoztty /
# ghoztty-agent processes launched from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\layout-capture-cost.ps1

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Gestures = 6,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers. Dot-sourced ahead of any isolation setup,
# because it drops an inherited $GHOZTTY_IPC_SOCKET - a test never wants the
# caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$script:rows = @()

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

# The budget, kept in step with layout_cost.zig by reading it FROM there. A
# hand-copied constant is a second definition, and the one thing worse than an
# unmeasured cost is a budget that silently stopped matching the code's.
$budgetUs = 16667
$costSrc = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\apprt\win32\layout_cost.zig'
if (Test-Path $costSrc) {
    $m = [regex]::Match((Get-Content $costSrc -Raw), 'frame_budget_us:\s*u64\s*=\s*([0-9_]+)')
    if ($m.Success) { $budgetUs = [int]($m.Groups[1].Value -replace '_', '') }
}

$root = Join-Path $env:TEMP "ghoztty-t412-$PID"
$tmp = Join-Path $root 'run'
$appLog = Join-Path $root 'app.err'

# ---------------------------------------------------------------------------
# Sample parsing
# ---------------------------------------------------------------------------
$costRe = [regex]'session-layout sync total_us=(\d+) capture_us=(\d+) write_us=(\d+) push_us=(\d+) panes=(\d+) snapshot_bytes=(\d+) wrote=(\w+) fresh_screens=(\w+)'

# Every cost sample in $appLog from byte $from onward, plus the new end offset.
function Read-Samples([long]$from) {
    if (-not (Test-Path $appLog)) { return @{ Samples = @(); End = $from } }
    $fs = [System.IO.File]::Open($appLog, 'Open', 'Read', 'ReadWrite')
    try {
        $end = $fs.Length
        if ($end -le $from) { return @{ Samples = @(); End = $end } }
        [void]$fs.Seek($from, 'Begin')
        $buf = New-Object byte[] ($end - $from)
        $n = $fs.Read($buf, 0, $buf.Length)
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
    } finally { $fs.Dispose() }
    $out = @()
    foreach ($mm in $costRe.Matches($text)) {
        $out += [pscustomobject]@{
            TotalUs   = [int]$mm.Groups[1].Value
            CaptureUs = [int]$mm.Groups[2].Value
            WriteUs   = [int]$mm.Groups[3].Value
            PushUs    = [int]$mm.Groups[4].Value
            Panes     = [int]$mm.Groups[5].Value
            SnapBytes = [int]$mm.Groups[6].Value
            Wrote     = ($mm.Groups[7].Value -eq 'true')
            Fresh     = ($mm.Groups[8].Value -eq 'true')
        }
    }
    return @{ Samples = $out; End = $end }
}

function Get-LogEnd { if (Test-Path $appLog) { (Get-Item $appLog).Length } else { 0 } }

# ---------------------------------------------------------------------------
# Isolation + launch
# ---------------------------------------------------------------------------
[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't412cost')
Assert-GhozttyPrivateEndpoint -Exe $Exe

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
$td = New-TestDesktop -Interactive:$Interactive

function Run-Cli([string[]]$argv, [int]$timeoutSec = 20) {
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $argv -TimeoutSec $timeoutSec
    if ($r.TimedOut) { return $null }
    return $r
}

# A pane runs whatever the app was configured with, so every pane in this run -
# the startup one included - is a known PowerShell. That is what lets one flood
# command drive all of them.
$launchArgs = @(
    '--title=t412-cost',
    '--session-persistence=true',
    '--command=powershell -NoProfile'
)

"== A: launch, and the instrumentation is actually reporting"
$app = Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs -StdErr $appLog
$top = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadline) {
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 500
}
Assert 'A1 the GUI came up' ($top -ne [IntPtr]::Zero)
if ($top -eq [IntPtr]::Zero) {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
    $env:LOCALAPPDATA = $savedLocalAppData
    "LAYOUT-CAPTURE-COST: 1 FAILURE(S)"
    exit 1
}
Start-Sleep -Seconds 4

$listed = Run-Cli @('+list', '--json')
Assert 'A2 the app answers +list on the private endpoint' ($null -ne $listed -and $listed.ExitCode -eq 0)

# The startup window has no IPC name, and `+split --target=` only resolves
# NAMES - so the panes are grown in a named second window. That is not a
# workaround for the measurement: `captureSessionLayout` walks every window in
# the app, so the cost a gesture on the startup window pays already includes
# them, and two windows is the more honest shape anyway.
$made = Run-Cli @('+new-window', '--target=t412w')
Assert 'A3 a named window to grow panes in' ($null -ne $made -and $made.ExitCode -eq 0)
Start-Sleep -Seconds 3

# ---------------------------------------------------------------------------
# The flood: an infinite printer, sent through --keys-file so PowerShell 5.1's
# native-command quoting cannot mangle it, and stopped with a real C-c.
# ---------------------------------------------------------------------------
$floodFile = Join-Path $root 'flood.txt'
[System.IO.File]::WriteAllText(
    $floodFile,
    'while ($true) { 1..200 | ForEach-Object { "T412 flood line $_ ' + ('x' * 40) + '" }; Start-Sleep -Milliseconds 10 }')

$script:panes = @()   # IPC names of the splits this run created

function Start-Flood {
    foreach ($p in $script:panes) {
        [void](Run-Cli @('+send-keys', "--target=$p", "--keys-file=$floodFile", 'Enter'))
    }
    Start-Sleep -Seconds 3
    # The control for the whole flooded arm. Since the fix, a flooded capture
    # REUSES the cached screen, so its `snapshot_bytes` no longer prove the
    # panes were busy - and without this, a flood that silently failed to start
    # would make the fix look better than it is by measuring a second idle arm.
    # Read a pane back instead: the words have to be on the screen.
    $r = Run-Cli @('+read', "--name=$($script:panes[0])", '--lines=30')
    return ($null -ne $r -and $r.Output -match 'T412 flood line')
}
function Stop-Flood {
    foreach ($p in $script:panes) { [void](Run-Cli @('+send-keys', "--target=$p", 'C-c')) }
    Start-Sleep -Seconds 2
}

# One measurement arm: $Gestures real drag-resize gestures, alternating the
# delta so the window walks back and forth instead of growing off the screen.
# Each gesture's WM_EXITSIZEMOVE calls syncSessionLayout synchronously.
function Measure-Arm([string]$label, [int]$expectPanes) {
    $mark = Get-LogEnd
    for ($g = 0; $g -lt $Gestures; $g++) {
        $dw = if ($g % 2 -eq 0) { 40 } else { -40 }
        $dh = if ($g % 2 -eq 0) { 30 } else { -30 }
        [void](Invoke-TestDragResize -Window $top -DeltaWidth $dw -DeltaHeight $dh)
        Start-Sleep -Milliseconds 700
    }
    Start-Sleep -Milliseconds 800
    $read = Read-Samples $mark
    $s = @($read.Samples)
    if ($s.Count -eq 0) {
        "    [$label] NO SAMPLES"
        return [pscustomobject]@{ Label = $label; Count = 0; MaxUs = -1; MeanUs = -1; MaxPanes = 0 }
    }
    $max = ($s | Measure-Object -Property TotalUs -Maximum).Maximum
    $mean = [int](($s | Measure-Object -Property TotalUs -Average).Average)
    $maxCap = ($s | Measure-Object -Property CaptureUs -Maximum).Maximum
    $maxPanes = ($s | Measure-Object -Property Panes -Maximum).Maximum
    $anyFresh = @($s | Where-Object { $_.Fresh }).Count
    $maxSnap = ($s | Measure-Object -Property SnapBytes -Maximum).Maximum
    $row = [pscustomobject]@{
        Label    = $label
        Count    = $s.Count
        MaxUs    = $max
        MeanUs   = $mean
        MaxCapUs = $maxCap
        MaxPanes = $maxPanes
        SnapKB   = [int]($maxSnap / 1024)
        Fresh    = $anyFresh
    }
    $script:rows += $row
    "    [$label] n=$($s.Count) panes=$maxPanes max=$([math]::Round($max/1000,2))ms mean=$([math]::Round($mean/1000,2))ms capture_max=$([math]::Round($maxCap/1000,2))ms snapshot=$($row.SnapKB)KB fresh=$anyFresh/$($s.Count)"
    return $row
}

# Grow the app's TOTAL pane count to $target: the startup window's one pane,
# plus t412w's root pane, plus one split per call. Splits alternate direction so
# the tree stays roughly square and no pane collapses below a usable size.
function Grow-Panes([int]$target) {
    while (($script:panes.Count + 2) -lt $target) {
        $n = $script:panes.Count + 1
        $name = "t412p$n"
        $dir = if ($n % 2 -eq 0) { 'right' } else { 'down' }
        $r = Run-Cli @('+split', '--target=t412w', "--name=$name", "--direction=$dir")
        if ($null -eq $r -or $r.ExitCode -ne 0) { break }
        $script:panes += $name
        Start-Sleep -Milliseconds 900
    }
    Start-Sleep -Seconds 3
}

try {
    "== B: 2 panes"
    $b1 = Measure-Arm 'n=2 idle' 2
    Assert 'B1 the sync emits a cost sample per gesture (negative control: zero means the instrumentation is not wired)' ($b1.Count -gt 0)
    Assert "B2 the sample counts the live panes (panes=$($b1.MaxPanes))" ($b1.MaxPanes -ge 1)

    "== C: 3 panes"
    Grow-Panes 3
    $c1 = Measure-Arm 'n=3 idle' 3
    $flooded3 = Start-Flood
    Assert 'C1 flood control: the panes are actually printing at n=3' $flooded3
    $c2 = Measure-Arm 'n=3 flooded' 3
    Stop-Flood

    "== D: 8 panes"
    Grow-Panes 8
    $d1 = Measure-Arm 'n=8 idle' 8
    $flooded8 = Start-Flood
    $d2 = Measure-Arm 'n=8 flooded' 8
    Stop-Flood

    Assert "D1 the run actually reached 8 panes (got $($d1.MaxPanes))" ($d1.MaxPanes -ge 8)
    Assert 'D2 the 8-pane arms produced samples' ($d1.Count -gt 0 -and $d2.Count -gt 0)

    # The control for the flooded arm. It cannot be `snapshot_bytes` any more:
    # since the fix a flooded capture REUSES the cached screen, so those bytes
    # say nothing about how busy the panes were. Without this, a flood that
    # silently failed to start would make the fix look better than it is by
    # measuring a second idle arm.
    Assert 'D3 flood control: the panes are actually printing at n=8' $flooded8
    Assert "D4 the captures carry a real screen for every pane ($($d1.SnapKB) KB)" ($d1.SnapKB -gt 0)

    "== F: the drag path carries screens forward"
    # The whole fix, stated as a measurement rather than as a claim: not one
    # sample produced by a drag gesture may have re-dumped the screens. A
    # `.fresh` sample here means some caller regressed to the 991 ms path.
    $dragFresh = ($script:rows | Measure-Object -Property Fresh -Sum).Sum
    Assert "F1 no drag-triggered sync re-dumped the panes' screens ($dragFresh fresh samples)" ($dragFresh -eq 0)

    "== E: the budget"
    foreach ($r in $script:rows) {
        Assert ("E {0}: max sync {1} ms is within the {2} ms frame budget" -f
            $r.Label, [math]::Round($r.MaxUs / 1000, 2), [math]::Round($budgetUs / 1000, 2)) ($r.MaxUs -le $budgetUs)
    }

    ''
    'measured cost of one session-layout sync:'
    $script:rows | Format-Table Label, Count, MaxPanes, @{n = 'max_ms'; e = { [math]::Round($_.MaxUs / 1000, 2) } },
    @{n = 'mean_ms'; e = { [math]::Round($_.MeanUs / 1000, 2) } },
    @{n = 'capture_max_ms'; e = { [math]::Round($_.MaxCapUs / 1000, 2) } }, SnapKB, Fresh | Out-String | Write-Host
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has anybody measured the sync cost against the code as it now stands?"
# Red leaves the stamp alone - red stays due.
if ($script:failures -eq 0) {
    $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard layout-capture-cost -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
if ($script:failures -eq 0) { "ALL PASS ($script:passes assertions)"; exit 0 }
"LAYOUT-CAPTURE-COST: $script:failures FAILURE(S) / $script:passes passed"
exit 1
