# T1079 acceptance: a `+split`/`+rearrange` with no explicit anchor lands at the
# pane it was invoked FROM, not at whatever window is focused when the app gets
# around to the message.
#
# THE DEFECT. The default anchor used to be resolved on the app's side at HANDLE
# time (`frontWindow`), which is racy by construction: an agent in window A asks
# for a side pane, the user clicks window B in the meantime, and the pane opens
# in B. The race does not need a user either - an agent's command is asynchronous
# with respect to focus even when nobody touches anything.
#
# The CLI half already shipped here: `apprt.ipc.seedCallerPane` inserts
# `--caller-pane=$GHOZTTY_PANE_ID` ahead of anything from `-e` on, for both
# `+split` and `+rearrange`. The APP half was macOS-only, and the win32 server's
# argument parser ignores what it does not recognize ON PURPOSE (the app<->CLI
# compatibility contract), so the flag was silently dropped and Windows kept the
# old focused-window fallback. T1079 gives the win32 server its own
# `callerAnchorPane`.
#
# HOW THE RACE IS DRIVEN WITHOUT A USER: window B is created SECOND, so it is
# the app's front window (foreground on the interactive desktop; the most
# recently created window under `frontWindow`'s fallback on a background one) for
# the whole run - splitting a pane never raises its window. Section B proves that
# rather than assuming it: with nothing forwarded, a `+split` lands in B. Every
# later section then sets `$GHOZTTY_PANE_ID` to a pane in window A and asks where
# the pane went.
#
#   * broken: every section lands in B - the flag is dropped and the fallback
#     answers every time.
#   * fixed:  C and H land in A (the caller's window), while B, D, E and F still
#     land in B - explicit targeting and the no-caller fallback are untouched.
#
# The precedence table itself (explicit target/pane/from-focused wins, absent or
# empty changes nothing, an unresolvable caller pane FALLS BACK while an explicit
# `--pane=` naming nothing stays a hard error) is unit tested in both zig lanes -
# `apprt.ipc.args.callerAnchorPane`. This script is the end-to-end half: it is
# the only thing that proves the flag survives the CLI, the wire and the server's
# parser and reaches the window that opens.
#
# Hermetic: a per-run $env:LOCALAPPDATA and a private IPC endpoint suffix, and it
# only ever kills ghoztty / ghoztty-agent processes launched from this repo's
# zig-out. Runs on a BACKGROUND desktop (T217) so the fixture windows never steal
# the user's foreground. Session persistence is OFF - the anchoring question is
# about windows, and plain ConPTY panes make the run fast and agent-free.
#
#   powershell -NoProfile -File test\win32\caller-anchor.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "  PASS $label" }
    else { $script:fail++; Write-Host "  FAIL $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# ---- CLI -------------------------------------------------------------------
# One `ghoztty +verb`, with `$GHOZTTY_PANE_ID` set to EXACTLY $PaneId for the
# duration of the call - '' meaning "unset", which is the plain non-Ghoztty
# shell case and NOT what this harness inherits. That distinction is the whole
# point: an acceptance script started from one of the user's own Ghoztty panes
# has the user's pane id in its environment, so a run that simply forwarded what
# it inherited would seed a foreign id and measure the fallback every time.
#
# Reached through `cmd.exe /c` with the redirect INSIDE the command line: a PS
# 5.1 pipeline does not report a native exit code reliably (lib\ExitCodeAudit.ps1),
# and $p.Handle is cached before any wait or ExitCode reads empty.
function Run-Cli([string]$argsLine, [string]$outName, [string]$PaneId = '', [int]$timeoutSec = 25) {
    $out = Join-Path $tmp $outName
    $saved = $env:GHOZTTY_PANE_ID
    $code = $null
    try {
        if ($PaneId -ne '') { $env:GHOZTTY_PANE_ID = $PaneId }
        else { Remove-Item env:GHOZTTY_PANE_ID -ErrorAction SilentlyContinue }
        $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
            -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
        $null = $p.Handle
        if (-not $p.WaitForExit($timeoutSec * 1000)) {
            & taskkill.exe /F /T /PID $p.Id *> $null
        } else {
            $code = $p.ExitCode
        }
    } finally {
        if ($null -eq $saved) { Remove-Item env:GHOZTTY_PANE_ID -ErrorAction SilentlyContinue }
        else { $env:GHOZTTY_PANE_ID = $saved }
    }
    $raw = Get-Content $out -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { $raw = '' }
    return @{ exit = $code; out = $raw }
}

# ---- +list --json ----------------------------------------------------------
function Get-List([string]$tag) {
    $r = Run-Cli '+list --json' "list-$tag.json" '' 20
    if ($r.exit -ne 0) { return $null }
    try { return ($r.out | ConvertFrom-Json) } catch { return $null }
}
function Get-ListWindows($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function Walk-Leaves($node) {
    $acc = @()
    if ($null -eq $node) { return $acc }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') {
        $acc += Walk-Leaves $node.left
        $acc += Walk-Leaves $node.right
    }
    return $acc
}
function Get-WindowLeaves($w) {
    $acc = @()
    foreach ($t in @($w.tabs)) { $acc += Walk-Leaves $t.splits }
    return $acc
}
# The id of the window holding the pane spelled $key (a pane id or a registered
# --name), or '' when no window holds it.
function Get-WindowOfPane($tree, [string]$key) {
    foreach ($w in Get-ListWindows $tree) {
        foreach ($leaf in @(Get-WindowLeaves $w)) {
            if ($leaf.id -eq $key -or $leaf.name -eq $key) { return $w.id }
        }
    }
    return ''
}
function Get-LeafCount($tree, [string]$windowId) {
    foreach ($w in Get-ListWindows $tree) {
        if ($w.id -eq $windowId) { return @(Get-WindowLeaves $w).Count }
    }
    return 0
}
# Poll until $key names a pane somewhere, then answer WHICH window holds it.
# '' after the timeout, which every caller scores as a failure rather than
# waiting forever.
function Wait-WindowOfPane([string]$tag, [string]$key, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $w = Get-WindowOfPane (Get-List $tag) $key
        if ($w -ne '') { return $w }
        Start-Sleep -Milliseconds 400
    }
    return ''
}
function Wait-LeafCount([string]$tag, [int]$count, [int]$timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $tree = $null
    while ((Get-Date) -lt $deadline) {
        $tree = Get-List $tag
        $n = 0
        foreach ($w in Get-ListWindows $tree) { $n += @(Get-WindowLeaves $w).Count }
        if ($n -ge $count) { return $tree }
        Start-Sleep -Milliseconds 400
    }
    return $tree
}
function Get-TotalLeaves($tree) {
    $n = 0
    foreach ($w in Get-ListWindows $tree) { $n += @(Get-WindowLeaves $w).Count }
    return $n
}
# The root node of a window's active tab, for the +rearrange oracle.
function Get-ActiveRoot($tree, [string]$windowId) {
    foreach ($w in Get-ListWindows $tree) {
        if ($w.id -ne $windowId) { continue }
        foreach ($t in @($w.tabs)) { if ($t.selected) { return $t.splits } }
        return @($w.tabs)[0].splits
    }
    return $null
}
# PS 5.1 native-arg passing eats embedded quotes; escape them for Win32.
function Send-Rearrange([string]$tag, [string]$layout, [string]$paneId, [string]$extra = '') {
    $line = "+rearrange $extra --layout=" + ($layout -replace '"', '\"')
    return (Run-Cli $line "rearrange-$tag.txt" $paneId 20)
}

# A pane id shaped like a real one that names nothing: the "my own pane closed
# while my script kept running" case, which must FALL BACK and never fail.
$GONE_PANE = '3f7a1c9d-0000-4000-8000-b1079b1079b1'

# ================================================================== setup
if (-not (Test-Path $Exe)) { throw "ghoztty exe not found: $Exe" }

$root = Join-Path $env:TEMP "ghoztty-caller-anchor-$PID"
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty') | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $tmp
$appLog = Join-Path $tmp 'app.err'

[void](Set-GhozttyTestIsolation -Tag 'anchor')
Assert-GhozttyPrivateEndpoint -Exe $Exe

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ================================================== A: two windows, A then B
    "== A: window A comes up, then window B is created second"
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $appLog `
        -Arguments @('--title=t1079-A', '--session-persistence=false')
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the GUI window never appeared' -Label 'caller-anchor'
    }
    $tree = Wait-LeafCount 'a0' 1 40
    $leaves = @()
    foreach ($w in Get-ListWindows $tree) { $leaves += Get-WindowLeaves $w }
    Assert ($leaves.Count -eq 1) "A1 the GUI came up with one pane and answers +list (got $($leaves.Count))"
    if ($leaves.Count -lt 1) { throw 'setup: no first pane' }
    Assert-GhozttyIsolated -Exe $Exe
    $paneA = $leaves[0].id
    Assert ($paneA -match '^[0-9A-Fa-f]{8}-') "A2 window A's pane has a pane id ($paneA)"

    $r = Run-Cli '+new-window --title=t1079-B' 'newwin.txt' '' 25
    Assert ($r.exit -eq 0) "A3 +new-window made a second window (exit $($r.exit))"
    $tree = Wait-LeafCount 'a1' 2 30
    Assert ((Get-ListWindows $tree).Count -eq 2) "A4 two windows exist (got $((Get-ListWindows $tree).Count))"
    $paneB = ''
    foreach ($w in Get-ListWindows $tree) {
        foreach ($leaf in @(Get-WindowLeaves $w)) { if ($leaf.id -ne $paneA) { $paneB = $leaf.id } }
    }
    if ($paneB -eq '') { throw 'setup: window B has no pane' }
    $WA = Get-WindowOfPane $tree $paneA
    $WB = Get-WindowOfPane $tree $paneB
    Assert ($WA -ne '' -and $WB -ne '' -and $WA -ne $WB) 'A5 the two panes are in different windows'
    if ($WA -eq $WB) { throw 'setup: both panes landed in one window' }

    # ============================================ B: the fallback, and the fixture
    # Nothing forwarded is the plain non-Ghoztty shell case AND the control that
    # establishes which window the app falls back to - every later section is
    # read against it.
    "== B: with no caller pane, a +split still lands in the app's front window"
    $r = Run-Cli '+split --direction=right --name=t1079ctl' 'split-ctl.txt' '' 25
    Assert ($r.exit -eq 0) "B1 the split succeeded (exit $($r.exit))"
    $whereCtl = Wait-WindowOfPane 'b0' 't1079ctl' 20
    Assert ($whereCtl -eq $WB) 'B2 it landed in window B, the front window (fallback unchanged)'
    if ($whereCtl -ne $WB) { throw 'fixture: window B is not the fallback window; the rest cannot be read' }

    # ============================================================== C: the fix
    "== C: a +split invoked from window A's pane lands in window A"
    $r = Run-Cli '+split --direction=right --name=t1079anch' 'split-anchor.txt' $paneA 25
    Assert ($r.exit -eq 0) "C1 the split succeeded (exit $($r.exit))"
    $whereAnchor = Wait-WindowOfPane 'c0' 't1079anch' 20
    $claimC = ($whereAnchor -eq $WA)
    if ($NegativeControl) { $claimC = ($whereAnchor -eq $WB) }
    Assert $claimC 'C2 it anchored at the CALLER, not at the focused window'

    # ================================================ D: anything explicit wins
    "== D: an explicit --target beats the caller pane"
    $r = Run-Cli "+split --direction=right --name=t1079tgt --target=$paneB" 'split-target.txt' $paneA 25
    Assert ($r.exit -eq 0) "D1 the split succeeded (exit $($r.exit))"
    Assert ((Wait-WindowOfPane 'd0' 't1079tgt' 20) -eq $WB) 'D2 it landed where --target said, in window B'

    "== E: --from-focused beats the caller pane"
    # `--from-focused` skips --name registration by design (it is the inheriting
    # trigger), so the oracle is B's leaf count rather than a named pane.
    $before = Get-LeafCount (Get-List 'e0') $WB
    $r = Run-Cli '+split --direction=right --from-focused' 'split-focused.txt' $paneA 25
    Assert ($r.exit -eq 0) "E1 the split succeeded (exit $($r.exit))"
    $deadline = (Get-Date).AddSeconds(20)
    $afterB = $before
    $afterA = Get-LeafCount (Get-List 'e1') $WA
    while ((Get-Date) -lt $deadline) {
        $t = Get-List 'e2'
        $afterB = Get-LeafCount $t $WB
        $afterA = Get-LeafCount $t $WA
        if ($afterB -gt $before) { break }
        Start-Sleep -Milliseconds 400
    }
    Assert ($afterB -eq $before + 1) "E2 the pane went to the focused window (B: $before -> $afterB)"
    Assert ($afterA -eq 2) "E3 window A was left alone (still $afterA panes)"

    # ================================= F: a caller pane that no longer resolves
    "== F: a caller pane naming nothing falls back instead of failing"
    $r = Run-Cli '+split --direction=right --name=t1079stale' 'split-stale.txt' $GONE_PANE 25
    Assert ($r.exit -eq 0) "F1 the split still succeeded (exit $($r.exit)) - a script outliving its pane is ordinary"
    Assert ((Wait-WindowOfPane 'f0' 't1079stale' 20) -eq $WB) 'F2 it fell back to the front window'

    # ============================ G: an explicit --pane naming nothing is a typo
    "== G: an explicit --pane naming nothing stays a hard error"
    $totalBefore = Get-TotalLeaves (Get-List 'g0')
    $r = Run-Cli "+split --direction=right --pane=$GONE_PANE" 'split-badpane.txt' $paneA 25
    Assert ($r.exit -ne 0) "G1 it failed (exit $($r.exit)) rather than falling back"
    Assert ($r.out -match 'not found') "G2 it said which pane was not found"
    Start-Sleep -Milliseconds 800
    Assert ((Get-TotalLeaves (Get-List 'g1')) -eq $totalBefore) 'G3 no pane was created anywhere'

    # ================================================ H: +rearrange anchors too
    # "Rearrange this window" means the caller's window. The layout names panes
    # that live in a PARTICULAR window, so the focused-window guess made the
    # command fail outright as often as it moved the wrong one - window B does
    # not contain window A's panes.
    "== H: a +rearrange invoked from window A's pane rearranges window A"
    $rootBefore = Get-ActiveRoot (Get-List 'h0') $WA
    Assert ($rootBefore.type -eq 'split' -and $rootBefore.direction -eq 'horizontal') `
        "H1 window A starts as a horizontal split (oracle control: $($rootBefore.direction))"
    $layout = '{"direction":"vertical","ratio":30,"left":{"pane":"' + $paneA + '"},"right":{"pane":"t1079anch"}}'
    $r = Send-Rearrange 'h' $layout $paneA
    Assert ($r.exit -eq 0) "H2 the rearrange succeeded (exit $($r.exit)); out=$($r.out.Trim())"
    Start-Sleep -Milliseconds 800
    $treeH = Get-List 'h1'
    $rootAfter = Get-ActiveRoot $treeH $WA
    Assert ($rootAfter.direction -eq 'vertical') `
        "H3 window A's layout is the one that was asked for (got $($rootAfter.direction))"
    Assert ((Get-LeafCount $treeH $WA) -eq 2) 'H4 both of window A''s panes survived the move'

    "== I: a +rearrange with an unresolvable caller pane still uses the front window"
    # The fallback half of H: with nothing to anchor at, the layout is applied to
    # the front window - which does not contain these panes, so the command fails
    # exactly as it did before T1079.
    $r = Send-Rearrange 'i' $layout $GONE_PANE
    Assert ($r.exit -ne 0) "I1 it failed against the front window (exit $($r.exit))"
    Assert ($r.out -match 'not in the target window') 'I2 it said the panes are not in that window'

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Kill-RepoInstances
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# ------------------------------------------------- foreground discipline
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'caller-anchor'
