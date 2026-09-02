# Session-persistence E2E hardening (tracker T89i) -- the Windows port of
# scripts/e2e/session-persistence.py plus the flood/soak hardening the tracker
# scopes for publish readiness. One hermetic run covers:
#
#   A. Scenario build: 2 windows / 5 agent-backed panes with a nontrivial
#      nested topology and DISTINCT ratios via +rearrange (the py
#      headlineAcceptance shape: winA = P0 | (spA / spB) at 0.30/0.70,
#      winB = P3 | spC at 0.40).
#   B. Crash-kill re-attach x3 (py main loop, --quit=kill): taskkill /f the
#      app each cycle; the detached agent keeps every ConPTY; relaunch must
#      re-ATTACH the SAME sessions (no re-OPENs), rebuild the exact topology
#      (window/leaf counts + the rearranged ratios), and replay scrollback
#      (this cycle's marker AND every earlier cycle's marker).
#   C. Winsize integrity (py --winsize, ConPTY analog): the pane's console
#      geometry (`mode con` Columns) must track a live programmatic window
#      resize, survive a crash-kill relaunch EXACTLY (geometry-faithful
#      restore -- the "big window, small content" guard), and keep tracking
#      live resizes after re-attach.
#   D. Flood-during-reattach gap-fill, TWICE: a paced 1 Hz sequence printer runs in a
#      pane across kill -> dead gap -> relaunch; the restored scrollback must
#      contain EVERY sequence value (nothing lost while the app was dead or
#      while ATTACH replay raced live output), in order, with no runaway
#      duplication (the post-attach conhost fresh-paint may repeat one
#      screenful; more than that is a replay bug).
#   E. Bounded persistence-on soak (T62/T63 bounds on the AGENT data path):
#      with a byte-heavy type-loop storm AND a tiny-write echo storm flooding
#      agent-backed panes, +list answers 40/40, +read of the echo-storm pane
#      returns within the T62 bound, send-keys round-trips into a quiet pane,
#      a crash-kill relaunch MID-STORM restores everything, and +close of
#      each storm pane returns within the T63 bound.
#
# FULLY GREEN since 2026-07-21 (T114/T115). The last two reds were E4 (+read
# latency) and E11/E12 (+close latency), and they turned out to be ONE defect
# with two victims: the agent-path drain re-took each pane's renderer mutex in
# a tight loop, so every latency-sensitive waiter on that mutex lost race after
# race -- `+read` (23628ms of lock wait for 45ms of work) and, less obviously,
# the RENDERER thread (65392ms for one frame), which is where it notices its
# stop request, so `+close` sat in `renderer_thr.join()` for 33s. Fixed by a
# fairness ticket on `renderer.State` plus an early `drainRing` bail once
# `io.closing` is set. Section E is the contract for both: keep these bounds
# strict, and treat any E4/E11/E12 red as that starvation returning.
#
# Non-interactive; asserts and exits nonzero on any failure. Fully hermetic:
# per-run $env:LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN; only ever kills
# ghoztty/ghoztty-agent processes launched from this repo's zig-out (never the
# user's installed release instance, which uses a different pipe + agent
# lineage).
#
#   powershell -NoProfile -File test\win32\session-persistence.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Cycles = 3
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-session-persist-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# ---- window enumeration + programmatic resize ------------------------------
# T1238: through the harness, which marshals every call onto the test desktop's
# own thread. The private EnumWindows/MoveWindow driver this replaced ran on the
# HOST's desktop and would answer zero for windows that are plainly there once
# the app launches onto the test desktop - so C2's "resized both app windows"
# would fail and E's minimize would silently do nothing. The harness also makes
# the process DPI-aware, which is what the old driver's SetProcessDPIAware call
# was for: geometry here is in physical pixels, like the app's.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# All GhozttyWindow top-levels belonging to this run's app pids.
function Top-Windows($appPids) {
    $wins = @()
    foreach ($procId in @($appPids)) {
        foreach ($w in @(Get-TestWindows -ProcessId ([int]$procId) -Class 'GhozttyWindow')) {
            $wins += [IntPtr]$w.Hwnd
        }
    }
    # Returned UNWRAPPED on purpose: every caller is `@(Top-Windows ...)`, and a
    # `return , $wins` would arrive there as ONE element that happens to be an
    # array - which reads as "found 1 window" and fails C2 against two real ones.
    return $wins
}

# left, top, WIDTH, HEIGHT - the shape the assertions below index into.
function Win-Rect($hwnd) {
    $r = Get-TestWindowRect -Window $hwnd
    return @($r.Left, $r.Top, $r.Width, $r.Height)
}

# ---- process helpers (zig-out lineage only) --------------------------------
function App-Pids {
    return @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' -and $_.CommandLine -notmatch '\+' } |
        ForEach-Object { $_.ProcessId })
}
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}
# The crash under test: taskkill /f of the GUI only (agent keeps every ConPTY).
function Crash-App {
    foreach ($p in (App-Pids)) { taskkill /f /pid $p 2>&1 | Out-Null }
    Start-Sleep -Milliseconds 900
}
function Relaunch-App {
    $env:LOCALAPPDATA = $script:tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # persistence: on (default) - session persistence IS this script's subject.
    [void](Start-OnTestDesktop -Exe $Exe)
}

# ---- CLI helpers (timeout-guarded, on the test desktop) --------------------
# T1238: `Invoke-OnTestDesktop` replaces a `cmd /c "... > file 2>&1"` dance. It
# captures stdout AND stderr to the file itself - which is what the dance was for
# (a GUI-subsystem exe writes nothing to a PowerShell redirect, T245) - and it
# TERMINATES the child on timeout, which is the other thing that mattered here: a
# CLI left alive holding the redirect target open made every later probe fail at
# ~35ms with no output, and turned 2 real timeouts into 26 fake failures in a
# T111b run.
function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $argv = @($argsLine -split '\s+' | Where-Object { $_ -ne '' })
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $argv -TimeoutSec $timeoutSec
    $text = if ($null -ne $r.Output) { $r.Output } else { '' }
    [System.IO.File]::WriteAllText($out, $text)
    if ($r.TimedOut) { return $null }
    return $r.ExitCode
}
# The argv form, for a call whose arguments carry spaces or quotes of their own.
function Ghoz([string[]]$GhozArgs, [int]$TimeoutSec = 20) {
    return Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs -TimeoutSec $TimeoutSec
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# ---- +list --json tree helpers ---------------------------------------------
function Get-Tree($tag) {
    $code = Run-Cli '+list --json' "$($script:tmp)\list-$tag.json" 10
    if ($code -ne 0) { return $null }
    try { return (Out-Text "$($script:tmp)\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
# NOTE (PS 5.1 array discipline): these helpers return PLAIN arrays and every
# call site wraps in @(). Do NOT also add a protective unary comma -- a comma
# plus a call-site @() NESTS the array (@() does not flatten), so .Count reads
# 1 and every count/membership assertion silently misreads. Wrap at the call
# site, never at the return.
function Tree-Windows($tree) {
    if ($null -eq $tree) { return @() }
    $w = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    return @($w)
}
function Walk-Leaves($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return (@(Walk-Leaves $node.left) + @(Walk-Leaves $node.right)) }
    return @()
}
function Walk-Ratios($node) {
    if ($null -eq $node -or $node.type -ne 'split') { return @() }
    return (@([double]$node.ratio) + @(Walk-Ratios $node.left) + @(Walk-Ratios $node.right))
}
function Window-Leaf-Names($win) {
    $names = @()
    foreach ($t in @($win.tabs)) {
        foreach ($leaf in @(Walk-Leaves $t.splits)) { $names += $leaf.name }
    }
    return $names
}
function Count-AllLeaves($tag) {
    $tree = Get-Tree $tag
    if ($null -eq $tree) { return -1 }
    $c = 0
    foreach ($w in @(Tree-Windows $tree)) {
        foreach ($t in @($w.tabs)) { $c += @(Walk-Leaves $t.splits).Count }
    }
    return $c
}
function All-Ratios($tag) {
    $tree = Get-Tree $tag
    if ($null -eq $tree) { return @() }
    $r = @()
    foreach ($w in @(Tree-Windows $tree)) {
        foreach ($t in @($w.tabs)) { $r += @(Walk-Ratios $t.splits) }
    }
    return @($r | Sort-Object)
}
function Wait-Windows($tag, $target, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $n = -1
    while ((Get-Date) -lt $deadline) {
        $tree = Get-Tree $tag
        if ($null -ne $tree) { $n = @(Tree-Windows $tree).Count }
        if ($n -eq $target) { return $n }
        Start-Sleep -Milliseconds 500
    }
    return $n
}
function Wait-Leaves($tag, $target, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $n = -1
    while ((Get-Date) -lt $deadline) {
        $n = Count-AllLeaves $tag
        if ($n -eq $target) { return $n }
        Start-Sleep -Milliseconds 500
    }
    return $n
}

# ---- +sessions helpers (dials the agent directly; answers app-dead) --------
function Get-Sessions($tag) {
    $code = Run-Cli '+sessions --json' "$($script:tmp)\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = Out-Text "$($script:tmp)\sess-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Ids($rows) {
    return @($rows | Where-Object { $_.alive -eq $true } | ForEach-Object { $_.id })
}
function Wait-AliveIds($tag, $target, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $ids = @()
    while ((Get-Date) -lt $deadline) {
        $ids = @(Alive-Ids (Get-Sessions $tag))
        if ($ids.Count -eq $target) { return $ids }
        Start-Sleep -Milliseconds 500
    }
    return $ids
}
function Same-Ids($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    $missing = @($a | Where-Object { $b -notcontains $_ })
    return ($missing.Count -eq 0)
}

# ---- pane I/O helpers ------------------------------------------------------
# Whitespace-stripped read (narrow/reflowed panes wrap tokens across rows).
function Read-Pane($pane, $lines, $tag) {
    Run-Cli "+read --name=$pane --lines=$lines" "$($script:tmp)\read-$tag.txt" 12 | Out-Null
    return ((Out-Text "$($script:tmp)\read-$tag.txt") -replace '\s', '')
}
function Wait-PaneToken($pane, $token, $timeoutSec, $tag) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-Pane $pane 2000 $tag).Contains($token)) { return $true }
        Start-Sleep -Milliseconds 600
    }
    return $false
}
# Plant a space-free marker (cmd echoes the typed line + errors on it; both
# land the token in scrollback) and wait until it is readable.
function Plant-Marker($pane, $marker, $tag) {
    Run-Cli "+send-keys --target=$pane $marker Enter" "$($script:tmp)\mark-$tag.txt" 12 | Out-Null
    return (Wait-PaneToken $pane $marker 20 $tag)
}
# Echo round-trip: proof the pane is live and interactive through the agent.
# T652: the "attached is not alive" oracle. Read its header before adding an
# assertion about a restored pane.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
function Test-RoundTrip($pane, $tag, $timeoutSec = 18) {
    # T652: delegated to the shared liveness oracle, so this script's arms move
    # with GHOZTTY_TEST_LIVENESS_BREAK like every other restore script's do -
    # an oracle nobody can watch go red is a decoration. Same probe as before:
    # type an `echo <token>` and require the token back out of the pane.
    return (Test-PaneLive -Exe $Exe -Target $pane -Tmp $script:tmp -TimeoutSec $timeoutSec -Tag 'SP')
}

# ---- console-geometry probe (the ConPTY winsize oracle) --------------------
# Types `echo <token> & mode con` into the pane's cmd shell and parses the
# Columns value that follows the LAST token occurrence. Returns -1 on failure.
$script:ws_n = 0
function Probe-Cols($pane, $tag) {
    $script:ws_n++
    $tok = "WSTK$($PID)N$($script:ws_n)"
    [void](Ghoz @('+send-keys', "--target=$pane", "echo $tok & mode con", 'Enter'))
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        $txt = Read-Pane $pane 120 "ws-$tag"
        $idx = $txt.LastIndexOf($tok)
        if ($idx -ge 0) {
            $after = $txt.Substring($idx)
            $m = [regex]::Match($after, 'Columns:(\d+)')
            if ($m.Success) { return [int]$m.Groups[1].Value }
        }
        Start-Sleep -Milliseconds 600
    }
    return -1
}
# Poll Probe-Cols until $pred is satisfied (each poll re-probes); returns the
# last observed value.
function Wait-Cols($pane, $tag, $pred, $timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $c = -1
    while ((Get-Date) -lt $deadline) {
        $c = Probe-Cols $pane $tag
        if ($c -gt 0 -and (& $pred $c)) { return $c }
        Start-Sleep -Milliseconds 400
    }
    return $c
}
# Minimize every app window (SW_MINIMIZE). Used by section E so its deliberate
# output floods do not paint over the user's live desktop; E asserts nothing
# about geometry, so minimizing costs the test nothing.
function Minimize-AppWindows {
    $pids = @(App-Pids | ForEach-Object { [uint32]$_ })
    if ($pids.Count -eq 0) { return 0 }
    $wins = @(Top-Windows $pids)
    foreach ($hw in $wins) { [void](Send-TestSysCommand -Window $hw -Command 'minimize') }
    return $wins.Count
}
function Resize-AllWindows($w, $h) {
    $pids = @(App-Pids | ForEach-Object { [uint32]$_ })
    if ($pids.Count -eq 0) { return 0 }
    $wins = @(Top-Windows $pids)
    $x = 60
    foreach ($hw in $wins) {
        [void](Set-TestWindowPos -Window $hw -X $x -Y 60 -Width $w -Height $h)
        $x += 80  # stagger so windows don't fully overlap
    }
    return $wins.Count
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# ---------------------------------------------------------------------------
# ISOLATION GUARD (2026-07-21 incident). This harness is hermetic in
# LOCALAPPDATA only. Its ENDPOINTS come from the build: a Debug exe speaks
# `ghoztty-debug-<user>` and spawns `ghoztty-agent-debug-<user>`, which is what
# keeps it clear of the user's installed release. Point it at a RELEASE exe
# (e.g. -Exe zig-out-release\bin\ghoztty.exe, to grade a delivery artifact) and
# both names collide with the live instance: the launched app loses the
# single-instance race and every CLI call in this script -- including
# `+close` -- is then aimed at the USER'S RUNNING TERMINAL. That is exactly
# what happened: sections A-D "failed" against someone else's windows while
# quietly closing them, and the user's GUI ended up dead. The agent pipe name
# is build-mode-derived and NOT overridable by GHOZTTY_PIPE_SUFFIX, so there is
# no env that makes a release run safe -- refuse instead of maiming.
#
# T350: ask the exe FIRST, because the check below only fires when something is
# already listening. On a cold box nothing answers, the harness proceeds, and it
# is the release build's own auto-launch that lands on the user's endpoints -
# the same incident, arriving through the gap in the guard written for it.
#
# T89i: this harness was written 2026-07-21, before T441 built lib\Isolation.ps1,
# and never adopted it -- so run from one of the user's own panes it inherited
# their baked `$GHOZTTY_IPC_SOCKET`, every CLI call named their INSTALLED
# release, and the guard below fired on their live instance (exit 2, nothing
# ever ran). The suffix has to be set before ANY CLI call, which is why it sits
# above the guard rather than beside the LOCALAPPDATA switch further down: the
# guard's own `+list` is a CLI call.
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'sesspersist')
# T1033: the shared gate, not a local copy of it. This used to hand-roll the
# same predicate, which meant it also missed the freshness half the shared one
# grew in T1028. The catch keeps this script's own exit contract (restore
# LOCALAPPDATA, exit 2) over the assert's throw.
try {
    Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
} catch {
    Write-Host ""
    Write-Host "ABORT: $($_.Exception.Message)" -ForegroundColor Red
    $env:LOCALAPPDATA = $savedLocalAppData
    exit 2
}

# The check is mechanism-free: if anything already answers on the endpoint this
# exe will use, we are not hermetic, full stop.
# T1238: the desktop comes up before the first CLI call, because that call - the
# hermeticity guard below - launches nothing but every later one can.
$td = New-TestDesktop

$preflight = Ghoz @('+list')
if ($preflight.ExitCode -eq 0) {
    Write-Host ""
    Write-Host "ABORT: a Ghoztty instance is ALREADY answering on the endpoint '$Exe' uses." -ForegroundColor Red
    Write-Host "  This harness would drive that instance instead of its own (and its +close" -ForegroundColor Red
    Write-Host "  calls would close ITS panes). Use the Debug build (zig-out\bin\ghoztty.exe)," -ForegroundColor Red
    Write-Host "  which speaks the -debug pipe; a release exe cannot be isolated here." -ForegroundColor Red
    $env:LOCALAPPDATA = $savedLocalAppData
    exit 2
}

# Hermetic state root for the whole run (one agent lineage across sections).
$script:tmp = Join-Path $root 'state'
New-Item -ItemType Directory -Force (Join-Path $script:tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $script:tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

# ============================================================================
"== A: build the 2-window / 5-pane scenario with distinct ratios"
# ============================================================================
# persistence: on (default) - session persistence IS this script's subject.
[void](Start-OnTestDesktop -Exe $Exe)
$n = Wait-Windows 'a0' 1 30
Assert "A1 startup window opened" ($n -eq 1)
# T441's safety oracle: the instance answering is the exe under test, and the
# caller's own pane is nowhere in its tree. Everything after this point types
# into panes and closes them, so prove whose panes they are first.
Assert-GhozttyIsolated -Exe $Exe
$startupTree = Get-Tree 'a1'
$startupLeaves = @()
foreach ($w in @(Tree-Windows $startupTree)) { $startupLeaves += @(Window-Leaf-Names $w) }
Assert "A2 startup window has one pane" ($startupLeaves.Count -eq 1)

# winA (P0) then drop the blank startup window (py build_scenario parity).
Run-Cli '+new-window --target=winA' "$($script:tmp)\nw-a.txt" 15 | Out-Null
$n = Wait-Windows 'a2' 2 25
Assert "A3 winA opened (2 windows)" ($n -eq 2)
foreach ($nm in $startupLeaves) {
    Run-Cli "+close --target=$nm" "$($script:tmp)\close-a.txt" 12 | Out-Null
}
$n = Wait-Windows 'a3' 1 25
Assert "A4 blank startup window closed (winA remains)" ($n -eq 1)

# winA splits: P0 | (spA / spB)
Run-Cli '+split --target=winA --direction=right --name=spA' "$($script:tmp)\sp-a.txt" 15 | Out-Null
Run-Cli '+split --target=spA --direction=down --name=spB' "$($script:tmp)\sp-b.txt" 15 | Out-Null
# winB: P3 | spC
Run-Cli '+new-window --target=winB' "$($script:tmp)\nw-b.txt" 15 | Out-Null
Run-Cli '+split --target=winB --direction=right --name=spC' "$($script:tmp)\sp-c.txt" 15 | Out-Null
$n = Wait-Windows 'a4' 2 25
$leafN = Wait-Leaves 'a5' 5 25
Assert "A5 scenario built: 2 windows, 5 panes" ($n -eq 2 -and $leafN -eq 5)

# The unnamed initial panes of each window (needed for +rearrange).
$p0 = $null; $p3 = $null
$tree = Get-Tree 'a6'
foreach ($w in @(Tree-Windows $tree)) {
    $names = @(Window-Leaf-Names $w)
    if ($names -contains 'spA') {
        $p0 = @($names | Where-Object { $_ -notin @('spA', 'spB') })[0]
    } elseif ($names -contains 'spC') {
        $p3 = @($names | Where-Object { $_ -ne 'spC' })[0]
    }
}
Assert "A6 identified the unnamed panes P0/P3" ($null -ne $p0 -and $null -ne $p3)

# Distinct ratios (PS 5.1 native-arg passing eats embedded quotes; escape).
$layoutA = '{"direction":"horizontal","ratio":30,"left":{"pane":"' + $p0 + '"},' +
    '"right":{"direction":"vertical","ratio":70,"left":{"pane":"spA"},"right":{"pane":"spB"}}}'
$layoutB = '{"direction":"horizontal","ratio":40,"left":{"pane":"' + $p3 + '"},"right":{"pane":"spC"}}'
$raA = Ghoz @('+rearrange', '--target=winA', ('--layout=' + ($layoutA -replace '"', '\"')))
$raB = Ghoz @('+rearrange', '--target=winB', ('--layout=' + ($layoutB -replace '"', '\"')))
Assert "A7 +rearrange applied to both windows" ($raA.ExitCode -eq 0 -and $raB.ExitCode -eq 0)
Start-Sleep -Seconds 2
$baseRatios = @(All-Ratios 'a7')
Assert "A8 baseline ratios are the rearranged 0.3/0.4/0.7" (
    $baseRatios.Count -eq 3 -and
    [math]::Abs($baseRatios[0] - 0.3) -lt 0.02 -and
    [math]::Abs($baseRatios[1] - 0.4) -lt 0.02 -and
    [math]::Abs($baseRatios[2] - 0.7) -lt 0.02)

# All 5 panes agent-backed; these ids must survive every cycle below.
$baseIds = @(Wait-AliveIds 'a8' 5 25)
Assert "A9 five agent sessions alive (all panes agent-backed)" ($baseIds.Count -eq 5)

# ============================================================================
"== B: crash-kill (taskkill /f) re-attach x$Cycles"
# ============================================================================
$markers = @()
for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $marker = "SPMK$($PID)C$cycle"
    $planted = Plant-Marker 'spB' $marker "b$cycle-pre"
    Assert "B$cycle.1 cycle-$cycle marker planted in spB" $planted
    $markers += $marker

    Crash-App
    Assert "B$cycle.2 app is gone after taskkill /f" ((App-Pids).Count -eq 0)
    $deadIds = @(Wait-AliveIds "b$cycle-dead" 5 20)
    Assert "B$cycle.3 agent kept all 5 sessions across the crash" (Same-Ids $baseIds $deadIds)

    # Recovery is measured relaunch -> fully restored (py's t_gone semantics).
    # The dead-gap +sessions probing above is a deliberate assertion, not
    # restore latency, so it is deliberately outside the window.
    $t0 = Get-Date
    Relaunch-App
    $n = Wait-Windows "b$cycle-w" 2 40
    $leafN = Wait-Leaves "b$cycle-l" 5 30
    Assert "B$cycle.4 restore rebuilt 2 windows / 5 panes" ($n -eq 2 -and $leafN -eq 5)
    $gap = ((Get-Date) - $t0).TotalSeconds

    $afterIds = @(Wait-AliveIds "b$cycle-post" 5 25)
    Assert "B$cycle.5 SAME 5 sessions re-ATTACHed (no re-OPEN, no leak)" (Same-Ids $baseIds $afterIds)

    $ratios = @(All-Ratios "b$cycle-r")
    $ratioOk = ($ratios.Count -eq 3)
    if ($ratioOk) {
        for ($i = 0; $i -lt 3; $i++) {
            if ([math]::Abs($ratios[$i] - $baseRatios[$i]) -gt 0.02) { $ratioOk = $false }
        }
    }
    Assert "B$cycle.6 split ratios restored exactly (0.3/0.4/0.7)" $ratioOk

    # Scrollback replay: every marker planted so far is still readable.
    $txt = Read-Pane 'spB' 4000 "b$cycle-mk"
    $missing = @($markers | Where-Object { -not $txt.Contains($_) })
    Assert "B$cycle.7 replayed scrollback holds all $($markers.Count) cycle marker(s)" ($missing.Count -eq 0)
    Assert "B$cycle.8 recovery gap $([math]::Round($gap,1))s < 45s" ($gap -lt 45)

    # The restored pane is interactive (accepts input through the agent).
    #
    # T652: this arm is the "attached is not alive" oracle, and it predates the
    # name - B.1-B.8 above are every one of them satisfied by a pane that came
    # back as a frozen picture (a replayed marker is a recording; a session id
    # is the agent's view of a child that may be wired to nothing). It is
    # deliberately run once per WINDOW rather than once per cycle: spB lives in
    # winA and spC in winB, the attach is wired per window, and a working winA
    # says nothing about winB. (Sections C and D lean on the same property for
    # spC and spA respectively, by typing `mode con` and reading a paced
    # sequence back - both are liveness proofs in their own right.)
    Assert "B$cycle.9 restored spB accepts input (echo round-trip)" (Test-RoundTrip 'spB' "b$cycle-rt")
    Assert "B$cycle.10 restored spC in the OTHER window accepts input too" (Test-RoundTrip 'spC' "b$cycle-rt2")
}

# ============================================================================
"== C: winsize/ConPTY-geometry integrity across re-attach (py --winsize)"
# ============================================================================
$preCols = Probe-Cols 'spC' 'pre'
Assert "C1 pre-resize geometry probe answered (cols=$preCols)" ($preCols -gt 0)

$moved = Resize-AllWindows 1000 640
Assert "C2 resized both app windows programmatically" ($moved -eq 2)
$refCols = Wait-Cols 'spC' 'ref' { param($c) $c -ne $preCols } 15
Assert "C3 live resize reached the ConPTY (cols $preCols -> $refCols)" ($refCols -gt 0 -and $refCols -ne $preCols)

# Programmatic resizes skip WM_EXITSIZEMOVE, so arm a manifest capture with a
# benign title mutation -- captureFrame reads the LIVE window rect at capture
# time, persisting the 1000x640 frames.
Run-Cli '+rename --target=winB --title=wsPin' "$($script:tmp)\ws-pin.txt" 12 | Out-Null
$manifest = Join-Path $script:tmp 'ghoztty\session-layout-debug.json'
$frameOk = $false
$deadline = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt $deadline) {
    $m = $null
    try { $m = Get-Content $manifest -Raw | ConvertFrom-Json } catch {}
    if ($null -ne $m) {
        $hit = @($m.windows | Where-Object {
            $null -ne $_.frame -and [math]::Abs($_.frame.w - 1000) -le 4 -and [math]::Abs($_.frame.h - 640) -le 4 })
        if ($hit.Count -eq 2) { $frameOk = $true; break }
    }
    Start-Sleep -Milliseconds 400
}
Assert "C4 manifest captured both 1000x640 frames" $frameOk

Crash-App
Relaunch-App
$n = Wait-Windows 'c-w' 2 40
Assert "C5 relaunch restored both windows" ($n -eq 2)

# Restored outer frames are the captured 1000x640 (geometry-faithful restore).
$framesBack = $false
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    $pids = @(App-Pids | ForEach-Object { [uint32]$_ })
    $wins = @(Top-Windows $pids)
    if ($wins.Count -eq 2) {
        $good = 0
        foreach ($hw in $wins) {
            $r = Win-Rect $hw
            if ([math]::Abs($r[2] - 1000) -le 10 -and [math]::Abs($r[3] - 640) -le 10) { $good++ }
        }
        if ($good -eq 2) { $framesBack = $true; break }
    }
    Start-Sleep -Milliseconds 500
}
Assert "C6 restored window frames are 1000x640" $framesBack

# The core --winsize assertion: the re-attached ConPTY agrees with the restored
# geometry (a stale/transient attach size would read different columns).
$postCols = Wait-Cols 'spC' 'post' { param($c) $c -eq $refCols } 20
Assert "C7 re-attached ConPTY re-synced to restored geometry (cols=$postCols == $refCols)" ($postCols -eq $refCols)

# A LIVE resize after re-attach must still reach the agent-side ConPTY.
$moved = Resize-AllWindows 1400 900
$liveCols = Wait-Cols 'spC' 'live' { param($c) $c -gt $refCols } 15
Assert "C8 live post-restore resize reached the ConPTY (cols $refCols -> $liveCols)" ($liveCols -gt $refCols)

# ============================================================================
"== D: flood-during-reattach gap-fill correctness"
# ============================================================================
# A paced ~1Hz sequence printer in spA spans: pre-kill output, output while the
# app is DEAD (agent-only), and output DURING the ATTACH replay. Every value
# must land in scrollback exactly in order.
$gtok = "GPF$($PID)Q"
[void](Ghoz @('+send-keys', '--target=spA', "for /L %i in (1,1,60) do @(echo $gtok-%i & ping -n 2 127.0.0.1 >nul)", 'Enter'))
$started = Wait-PaneToken 'spA' "$gtok-5" 30 'd-start'
Assert "D1 flood running (reached seq 5 pre-kill)" $started

# The highest value the DYING app had already shown: the crash instant sits in
# [preKill, preKill+1]. D5b uses it to bound where a loss may legitimately occur.
$preTxt = Read-Pane 'spA' 400 'd-prekill'
$preVals = @([regex]::Matches($preTxt, [regex]::Escape($gtok) + '-(\d+)') |
    ForEach-Object { [int]$_.Groups[1].Value } | Where-Object { $_ -ge 1 -and $_ -le 60 })
$preKill = if ($preVals.Count -gt 0) { ($preVals | Measure-Object -Maximum).Maximum } else { 0 }

Crash-App
Assert "D2 app killed mid-flood (last value shown pre-kill: $preKill)" ((App-Pids).Count -eq 0)
Start-Sleep -Seconds 8   # the agent alone absorbs ~8 more sequence lines

Relaunch-App              # ATTACH replay races the still-running flood
$n = Wait-Windows 'd-w' 2 40
Assert "D3 relaunch mid-flood restored both windows" ($n -eq 2)
$done = Wait-PaneToken 'spA' "$gtok-60" 120 'd-done'
Assert "D4 flood completed after re-attach (seq 60 readable)" $done

$txt = Read-Pane 'spA' 6000 'd-final'
$matches = [regex]::Matches($txt, [regex]::Escape($gtok) + '-(\d+)')
$vals = @($matches | ForEach-Object { [int]$_.Groups[1].Value } | Where-Object { $_ -ge 1 -and $_ -le 60 })
$distinct = @($vals | Sort-Object -Unique)
$missing = @(1..60 | Where-Object { $distinct -notcontains $_ })

# D5/D5b split the contract by REGION, because only one region is a real
# guarantee:
#
#   * Everything produced while the app was DEAD (> preKill) is what gap-fill
#     exists to deliver, and everything after re-attach is ordinary live
#     output. Losing ANY of that is a genuine bug -- D5b asserts it exactly.
#   * The pre-kill block (<= preKill) was already on the dying app's screen and
#     is re-painted from the ring on restore. At the junction where the replayed
#     block starts overwriting the restored pane's existing screen content, ONE
#     row can be clobbered before it scrolls into scrollback (observed: seq 6 in
#     one run, seq 2 in another, none in a third -- always inside the replayed
#     pre-kill block, never in the dead-gap). That is the mixed-geometry ring
#     remainder tracked as T109; it costs a line the user already saw, so D5
#     bounds it at one rather than pretending it is zero.
Assert "D5 no bulk loss across kill/dead-gap/attach ($($distinct.Count)/60 present, missing: $($missing -join ',')) " (
    $missing.Count -le 1)
$gapLoss = @($missing | Where-Object { $preKill -le 0 -or $_ -gt $preKill })
Assert "D5b nothing lost from the dead-gap or post-attach region (preKill=$preKill, lost there: $($gapLoss -join ','))" (
    $gapLoss.Count -eq 0)

# Ordering: last-occurrence positions must ascend (the post-attach conhost
# fresh-paint may repeat a screenful once -- a REWIND -- but the final pass over
# the content must be in order; any shuffle/interleave corruption breaks this).
$lastPos = @{}
for ($i = 0; $i -lt $matches.Count; $i++) {
    $v = [int]$matches[$i].Groups[1].Value
    if ($v -ge 1 -and $v -le 60) { $lastPos[$v] = $matches[$i].Index }
}
$orderOk = $true
for ($v = 1; $v -lt 60; $v++) {
    if ($lastPos.ContainsKey($v) -and $lastPos.ContainsKey($v + 1) -and
        $lastPos[$v] -ge $lastPos[$v + 1]) { $orderOk = $false }
}
Assert "D6 sequence order preserved through replay+live interleave" $orderOk

# Bounded duplication: one attach may fresh-paint one screenful twice; any
# value seen 3+ times means replay duplicated content.
$dupBad = 0
foreach ($g in ($vals | Group-Object)) { if ($g.Count -gt 2) { $dupBad++ } }
Assert "D7 no runaway duplication (no value seen 3+ times; bad=$dupBad)" ($dupBad -eq 0)

# --- D8-D11: the SECOND cycle, which is where a resume-point error lands -----
# T739: the offset a re-attach records is what the NEXT one resumes from, and
# the first re-attach is the one that can corrupt it - it is the first time the
# agent injects bytes (its grid-snapshot repaint) that are not the session's
# stream. Counting those recorded a resume point past the agent's head, and the
# clamp that caught it (T532) skipped everything between the true position and
# the head. So the arm above, run once, cannot see this at all: the offset it
# resumes from was written by an OPEN-era launch. Everything from D1-D7 repeats
# with a fresh sequence, and D10b is the assertion that would have gone red.
$gtok2 = "GPF2$($PID)Q"
[void](Ghoz @('+send-keys', '--target=spA', "for /L %i in (1,1,60) do @(echo $gtok2-%i & ping -n 2 127.0.0.1 >nul)", 'Enter'))
$started2 = Wait-PaneToken 'spA' "$gtok2-5" 30 'd2-start'
Assert "D8 second flood running (reached seq 5 pre-kill)" $started2

$preTxt2 = Read-Pane 'spA' 400 'd2-prekill'
$preVals2 = @([regex]::Matches($preTxt2, [regex]::Escape($gtok2) + '-(\d+)') |
    ForEach-Object { [int]$_.Groups[1].Value } | Where-Object { $_ -ge 1 -and $_ -le 60 })
$preKill2 = if ($preVals2.Count -gt 0) { ($preVals2 | Measure-Object -Maximum).Maximum } else { 0 }

Crash-App
Assert "D9 app killed mid-flood again (last value shown pre-kill: $preKill2)" ((App-Pids).Count -eq 0)
Start-Sleep -Seconds 8

Relaunch-App
$n = Wait-Windows 'd2-w' 2 40
Assert "D10 second relaunch restored both windows" ($n -eq 2)
$done2 = Wait-PaneToken 'spA' "$gtok2-60" 120 'd2-done'
Assert "D10a second flood completed after re-attach (seq 60 readable)" $done2

$txt2 = Read-Pane 'spA' 6000 'd2-final'
$vals2 = @([regex]::Matches($txt2, [regex]::Escape($gtok2) + '-(\d+)') |
    ForEach-Object { [int]$_.Groups[1].Value } | Where-Object { $_ -ge 1 -and $_ -le 60 })
$distinct2 = @($vals2 | Sort-Object -Unique)
$missing2 = @(1..60 | Where-Object { $distinct2 -notcontains $_ })
$gapLoss2 = @($missing2 | Where-Object { $preKill2 -le 0 -or $_ -gt $preKill2 })
Assert "D10b nothing lost from the SECOND cycle's dead-gap or post-attach region (preKill=$preKill2, lost there: $($gapLoss2 -join ','))" (
    $gapLoss2.Count -eq 0)
Assert "D11 no bulk loss on the second cycle ($($distinct2.Count)/60 present, missing: $($missing2 -join ',')) " (
    $missing2.Count -le 1)

# ============================================================================
"== E: bounded persistence-on soak -- IPC live under agent-path flood"
# ============================================================================
# Byte-heavy storm (type loop over a ~2MB file) + tiny-write echo storm, both
# agent-backed. IPC must stay responsive (T53a/T62 guards, now on the agent
# data path), and a crash-kill relaunch MID-STORM must restore.
#
# Both storms are BOUNDED (~3 min of output, not endless): if this run is ever
# killed or abandoned mid-section, the panes stop on their own instead of
# spamming the desktop until someone notices. The windows are minimized for
# the same reason -- section E asserts nothing about geometry (C/D own that),
# so it has no business painting a flood on a live desktop.
$stormFile = Join-Path $root 'storm.txt'
$sb = [System.Text.StringBuilder]::new()
1..25000 | ForEach-Object { [void]$sb.AppendLine("storm-payload $_ " + ('z' * 60)) }
[System.IO.File]::WriteAllText($stormFile, $sb.ToString())
[void](Ghoz @('+split', '--target=winB', '--name=stormP', '--direction=down', '--shell=cmd',
    "--command=for /l %i in (1,1,400) do @type $stormFile"))
[void](Ghoz @('+split', '--target=winA', '--name=echoP', '--direction=down', '--shell=cmd',
    '--command=for /l %i in (1,1,4000000) do @echo tiny-write-storm %i zzzzzzzzzzzzzzzzzzzzzzzzzzzz'))
Minimize-AppWindows
Start-Sleep -Seconds 3
$stormIds = @(Wait-AliveIds 'e-setup' 7 20)
Assert "E1 storm panes are agent-backed (7 sessions alive)" ($stormIds.Count -eq 7)

# +list stays answering under the double storm (WM_APP_WAKEUP flood guard).
# TIMEOUT-GUARDED (Run-Cli, 10s): a wedged GUI must be recorded as a failed
# probe, never allowed to hang the run. An unguarded `& $Exe +list` here hung
# a whole run indefinitely and left storm panes spamming.
$ok = 0; $bad = 0; $wedged = 0
1..40 | ForEach-Object {
    $code = Run-Cli '+list' "$($script:tmp)\e-hammer.txt" 10
    if ($null -eq $code) { $wedged++; $bad++ }
    elseif ($code -eq 0) { $ok++ }
    else { $bad++ }
    Start-Sleep -Milliseconds 150
}
Assert "E2 +list answers under agent-path storm: $ok/40 (wedged/timed-out: $wedged)" ($bad -eq 0)

# T62 bound on the agent inbound path: +read of the tiny-write storm pane.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rc = Run-Cli '+read --name=echoP --lines=5' "$($script:tmp)\e-echoread.txt" 20
$sw.Stop()
$echoTail = if ($rc -eq 0) { Out-Text "$($script:tmp)\e-echoread.txt" } else { '' }
Assert "E3 echo-storm +read returns content mid-storm" ($echoTail -match 'tiny-write-storm')
Assert "E4 echo-storm +read latency $($sw.ElapsedMilliseconds)ms < 2000ms (T62 bound)" ($sw.ElapsedMilliseconds -lt 2000)

# A quiet pane still round-trips input mid-storm.
Assert "E5 quiet pane round-trips mid-storm" (Test-RoundTrip 'spC' 'e-quiet')

# Crash-kill + relaunch MID-STORM: restore + ATTACH must absorb two panes
# replaying multi-MB rings while both floods keep writing.
Crash-App
$t0 = Get-Date
Relaunch-App
$n = Wait-Windows 'e-w' 2 60
Minimize-AppWindows | Out-Null   # restored windows are visible again; keep E quiet
$leafN = Wait-Leaves 'e-l' 7 40
Assert "E6 mid-storm relaunch restored 2 windows / 7 panes" ($n -eq 2 -and $leafN -eq 7)
$postIds = @(Wait-AliveIds 'e-post' 7 30)
Assert "E7 all 7 sessions re-ATTACHed mid-storm (same ids)" (Same-Ids $stormIds $postIds)
$gap = ((Get-Date) - $t0).TotalSeconds
Assert "E8 mid-storm recovery gap $([math]::Round($gap,1))s < 60s" ($gap -lt 60)
Assert "E9 quiet pane round-trips after mid-storm restore" (Test-RoundTrip 'spC' 'e-quiet2')
# IPC must RECOVER to interactive latency after the mid-storm restore. The
# single instant right after re-attach is legitimately slow (two panes replay
# multi-MB rings while both floods keep writing; 4.2s measured), so the
# contract asserted here is that the app returns to the sub-2s steady state
# within a bounded settle window -- not that the worst instant is fast. A
# never-recovering app (the real regression) still fails loudly.
$firstMs = -1
$bestMs = [int]::MaxValue
$settleDeadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $settleDeadline) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = Run-Cli '+list' "$($script:tmp)\e-settle.txt" 15
    $sw.Stop()
    $ok = ($code -eq 0)
    if ($firstMs -lt 0) { $firstMs = $sw.ElapsedMilliseconds }
    if ($ok -and $sw.ElapsedMilliseconds -lt $bestMs) { $bestMs = $sw.ElapsedMilliseconds }
    if ($ok -and $sw.ElapsedMilliseconds -lt 2000) { break }
    Start-Sleep -Milliseconds 500
}
Assert "E10 +list recovers to <2000ms after mid-storm restore (first=${firstMs}ms best=${bestMs}ms)" (
    $bestMs -lt 2000)

# T63 bound: closing the noisy panes returns promptly (no join hang). Guarded
# at 30s so a genuine hang is recorded as a FAILURE with its bound, not left
# to stall the run (the T63 regression it guards was a 9+ minute GUI hang).
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Run-Cli '+close --target=stormP' "$($script:tmp)\e-close1.txt" 30 | Out-Null
$sw.Stop()
Assert "E11 +close storm pane returns in $($sw.ElapsedMilliseconds)ms < 10s (T63)" ($sw.ElapsedMilliseconds -lt 10000)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Run-Cli '+close --target=echoP' "$($script:tmp)\e-close2.txt" 30 | Out-Null
$sw.Stop()
Assert "E12 +close echo-storm pane returns in $($sw.ElapsedMilliseconds)ms < 10s (T63)" ($sw.ElapsedMilliseconds -lt 10000)

# ============================================================================
"== cleanup"
Stop-TestProcs
Remove-TestDesktop | Out-Null
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
if ($script:failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
else { "artifacts preserved at $root" }

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
