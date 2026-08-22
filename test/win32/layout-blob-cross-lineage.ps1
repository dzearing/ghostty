# Cross-LINEAGE layout blobs (tracker T337) - a macOS-shaped blob rebuilds here.
#
# A layout blob is opaque to the agent by design, so its schema is a contract
# between two VIEWERS - and the two lineages never shared one. macOS pushes a
# `SessionLayoutManifest.Entry`: camelCase keys, ONE blob per TAB (siblings share
# a `tabGroupID` and order by `tabIndex`), and a NESTED `tree` whose Swift enum
# cases wrap their payload in `_0`. win32 pushes a `session_layout.Window`:
# snake_case, one blob per WINDOW, a FLAT `nodes` array with `left`/`right`
# indices. Before T337 a Windows viewer pointed at a Mac decoded none of it and
# reported "nothing to restore" - the feature looked present and was not.
#
# The unit tests in `layout_blobs.zig` / `mac_layout_blob.zig` own the decode
# surface. What they cannot show is that the REAL binary spends the translation:
# that `decodeLayouts` is on the launch-restore path, that a translated window
# survives `restoreWindow`, and that Mac's per-TAB records come back as ONE
# window with its tabs rather than N loose ones. That is this script.
#
#   A. Build a 2-window / 3-pane layout on a hermetic instance and let the agent
#      mirror it (2 layout records, 3 live sessions).
#   B. TRANSPLANT: stop the app AND the agent, then rewrite the agent's
#      `layouts.json` so both records hold MAC-shaped blobs over the same three
#      session ids - two entries sharing one `tabGroupID`, `tabIndex` 0 and 1.
#      Delete the local manifest, so restore has nothing but those blobs to read.
#   C. RESTORE: relaunch and assert ONE window with TWO tabs and THREE panes -
#      the topology the Mac blobs describe, not the 2-window one the fixture had
#      - with the split in tab ONE, and an ATTACH issued for each of the three
#      session ids the Mac blobs named.
#
# C is the assertion that was RED before T337: every blob was skipped as
# unreadable and the relaunch opened a blank window. `-NegativeControl` inverts
# it, so a run that scores this build as still-broken is available on demand.
# C5 is the T623 half: the blobs carry `primaryScreenHeight`, so the restored
# window must land the same way UP it was left (Cocoa's bottom-up y flipped
# about the source primary's top edge), not vertically mirrored.
#
# Why the agent is stopped in B: it holds its blob store in MEMORY and answers
# GET_LAYOUTS from there, so editing `layouts.json` under a live agent would
# change nothing and the script would pass on the old bytes.
#
# The cost of stopping it is that the three sessions come back as relaunchable
# TOMBSTONES rather than the same PIDs. That is still a supported attach path
# (`restoreWindowHasAttachableLeaf`: "alive or relaunchable tombstone") and the
# ATTACHes are what this script reads. What it deliberately does NOT assert is
# the roster afterwards: `session-relaunch = restore` (the default) brings the
# pane up on a FRESH shell in the recorded cwd and RETIRES the tombstone, so the
# three ids on the roster at the end are new by design - a fact about the
# relaunch policy, not about blob translation. `session-crash-recover.ps1` is
# the oracle for same-PID re-attach, which needs a surviving agent.
#
# Non-interactive and headless-safe: no foreground grabs and no synthetic input,
# so it needs no background-desktop harness. Fully hermetic: a per-run
# $env:LOCALAPPDATA, a per-run GHOSTTY_LOCAL_AGENT_BIN, a private IPC pipe
# suffix, and it ONLY ever kills ghoztty / ghoztty-agent processes launched from
# the repo zig-out - never the user's installed release.
#
#   powershell -NoProfile -File test\win32\layout-blob-cross-lineage.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-xlineage-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

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

# A Debug build links the CONSOLE subsystem, so its std.log lands on stderr and
# a failure can be explained rather than guessed at.
function Start-App($title, $log) {
    $a = @{
        FilePath    = $Exe
        WindowStyle = 'Minimized'
        ArgumentList = @("--title=$title", '--window-width=100', '--window-height=30')
    }
    if ($log) {
        $a['RedirectStandardError'] = $log
        $a['RedirectStandardOutput'] = "$log.out"
    }
    Start-Process @a | Out-Null
}

# --- the agent's session roster ---------------------------------------------

function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Ids($rows) { return @($rows | Where-Object { $_.alive -eq $true } | ForEach-Object { $_.id }) }
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if (@(Alive-Ids $rows).Count -eq $target) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}

# --- the agent's layout blob store ------------------------------------------

function Layouts-Path($tmp) { return (Join-Path $tmp 'ghoztty\local-agent-debug\layouts.json') }
function Get-Layouts($tmp) {
    $path = Layouts-Path $tmp
    if (-not (Test-Path $path)) { return @() }
    $doc = $null
    try { $doc = (Get-Content $path -Raw) | ConvertFrom-Json } catch { return @() }
    if ($null -eq $doc -or $null -eq $doc.layouts) { return @() }
    return @($doc.layouts)
}
function Wait-Records($tmp, $n, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $recs = @()
    while ((Get-Date) -lt $deadline) {
        $recs = Get-Layouts $tmp
        if (@($recs).Count -eq $n) { return @($recs) }
        Start-Sleep -Milliseconds 400
    }
    return @($recs)
}

function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

# --- the Mac blobs we transplant --------------------------------------------

# A macOS `SessionLayoutManifest.Entry` as `JSONEncoder` writes it: camelCase,
# a nested `tree`, and the `_0` wrapper Swift synthesizes for an enum case with
# one unlabeled associated value (SE-0295). `$leafIds` of length 2 builds a
# split over two panes; length 1 builds a bare leaf.
function New-MacEntry($entryId, $groupId, $tabIndex, $title, $ipcName, $leafIds) {
    $tree = $null
    if (@($leafIds).Count -eq 2) {
        $tree = @{ split = @{ '_0' = @{
            direction = 'horizontal'
            ratio     = 0.5
            left      = @{ leaf = @{ '_0' = @{ sessionID = $leafIds[0] } } }
            right     = @{ leaf = @{ '_0' = @{ sessionID = $leafIds[1] } } }
        } } }
    } else {
        $tree = @{ leaf = @{ '_0' = @{ sessionID = $leafIds[0] } } }
    }
    $entry = @{
        id       = $entryId
        tabGroupID = $groupId
        tabIndex = $tabIndex
        titleOverride = $title
        tree     = $tree
        # Cocoa coordinates: y is measured UP from the bottom-left of a
        # 1400pt-tall source primary (primaryScreenHeight, T623), so the
        # window's top sits 1400-60-620 = 720 down from the screen top.
        frame    = @{ x = 80; y = 60; width = 900; height = 620 }
        primaryScreenHeight = 1400
    }
    if ($ipcName) { $entry['ipcName'] = $ipcName }
    return ($entry | ConvertTo-Json -Depth 20 -Compress)
}

# --- the live topology, read back through the CLI ----------------------------

function Get-Tree($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($code -ne 0) { return $null }
    $tree = $null
    try { $tree = Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json } catch {}
    return $tree
}
# PS 5.1 UNROLLS a function's array return, so these emit their elements and
# EVERY call site wraps in `@()`. Returning `, @(...)` instead would fix the
# one-element case and break the many-element one - `@()` around a wrapped array
# counts 1 - which is how a correct 2-window build reads as "1 window".
function Tree-Windows($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function Leaf-Nodes($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node) }
    if ($node.type -eq 'split') { return @(@(Leaf-Nodes $node.left) + @(Leaf-Nodes $node.right)) }
    return @()
}
function All-Leaves($tree) {
    $out = @()
    foreach ($w in @(Tree-Windows $tree)) {
        foreach ($t in @($w.tabs)) { $out += @(Leaf-Nodes $t.splits) }
    }
    return $out
}
function Count-Tabs($tree) {
    $c = 0
    foreach ($w in @(Tree-Windows $tree)) { $c += @($w.tabs).Count }
    return $c
}
# Poll until the live tree matches (windows, tabs, panes); returns the last
# reading either way so a failed assertion still shows what was there.
function Wait-Topology($tmp, $tag, $wins, $tabs, $panes, $timeoutSec = 50) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $tree = $null
    while ((Get-Date) -lt $deadline) {
        $tree = Get-Tree $tmp $tag
        if (@(Tree-Windows $tree).Count -eq $wins -and
            (Count-Tabs $tree) -eq $tabs -and
            @(All-Leaves $tree).Count -eq $panes) { return $tree }
        Start-Sleep -Milliseconds 600
    }
    return $tree
}
function Shape($tree) {
    return "$(@(Tree-Windows $tree).Count) window(s) / $(Count-Tabs $tree) tab(s) / $(@(All-Leaves $tree).Count) pane(s)"
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'xlineage')
Assert-GhozttyPrivateEndpoint -Exe $Exe

try {

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# ============================================================================
"== A: a 2-window / 3-pane fixture, mirrored into the agent's blob store"
# ============================================================================
Start-App 't337-fixture' "$tmp\app-a.log"
Wait-AliveCount $tmp 'a0' 1 30 | Out-Null
Assert-GhozttyIsolated -Exe $Exe

Run-Cli '+split --direction=right --name=xl-sib' "$tmp\split.txt" 20 | Out-Null
Run-Cli '+new-window --target=xl-second' "$tmp\newwin.txt" 25 | Out-Null

$rowsA = Wait-AliveCount $tmp 'a' 3 30
$idsA = @(Alive-Ids $rowsA)
Assert "A1 three agent-backed sessions are alive" ($idsA.Count -eq 3)

$treeA = Wait-Topology $tmp 'a' 2 2 3 45
"  (fixture topology: $(Shape $treeA))"
Assert "A2 the fixture is two windows / three panes" (
    @(Tree-Windows $treeA).Count -eq 2 -and @(All-Leaves $treeA).Count -eq 3)

$recsA = Wait-Records $tmp 2 30
Assert "A3 the agent holds a layout record per window" (@($recsA).Count -eq 2)

# ============================================================================
"== B: TRANSPLANT - the same session ids, described by MAC-shaped blobs"
# ============================================================================
# Both the app and the agent go: the agent answers GET_LAYOUTS from memory, so
# an edit under a live one would be read by nobody.
Stop-TestProcs
Assert "B1 nothing from zig-out is still running" (
    @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe' or Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' }).Count -eq 0)

$group = 'GGGGGGGG-1111-4222-8333-444444444444'
$macA = New-MacEntry '1D0A0B0C-0000-4000-8000-000000000001' $group 0 'mac tab one' 'xl-mac' @($idsA[0], $idsA[1])
$macB = New-MacEntry '1D0A0B0C-0000-4000-8000-000000000002' $group 1 'mac tab two' $null   @($idsA[2])

$doc = @{
    version = 1
    layouts = @(
        @{ key = 'mac-entry-1'; blob = $macA; session_ids = @($idsA[0], $idsA[1]) },
        @{ key = 'mac-entry-2'; blob = $macB; session_ids = @($idsA[2]) }
    )
}
# NOT Set-Content -Encoding utf8: PS 5.1 writes a BOM, and the agent's loader is
# std.json, which rejects one - the store would come up empty and the script
# would score a working build as broken.
[System.IO.File]::WriteAllText(
    (Layouts-Path $tmp),
    ($doc | ConvertTo-Json -Depth 20 -Compress),
    (New-Object System.Text.UTF8Encoding($false)))

$recsB = Get-Layouts $tmp
$macShaped = @($recsB | Where-Object {
    $_.blob -like '*"tree"*' -and $_.blob -like '*_0*' -and
    $_.blob -like '*sessionID*' -and $_.blob -notlike '*"tabs"*' })
Assert "B2 both stored blobs are macOS-shaped (nested tree, _0 payloads, camelCase)" (
    @($recsB).Count -eq 2 -and $macShaped.Count -eq 2)
Assert "B3 they reference exactly the three fixture sessions" (
    @($recsB | ForEach-Object { $_.session_ids } | Sort-Object -Unique).Count -eq 3)

Remove-Item (Manifest-Path $tmp) -Force -ErrorAction SilentlyContinue
Assert "B4 the local manifest is gone, so restore can only read the blobs" (
    -not (Test-Path (Manifest-Path $tmp)))

# ============================================================================
"== C: RESTORE - the Mac topology is rebuilt here, tabs and all"
# ============================================================================
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
Start-App 't337-restored' "$tmp\app-c.log"

# One window with TWO tabs and THREE panes: the shape the Mac blobs describe,
# NOT the two-window shape the fixture had. Reading the fixture's shape back
# would mean the transplant never took; reading one window with one pane would
# mean the blobs were skipped and a blank window opened.
$treeC = Wait-Topology $tmp 'c' 1 2 3 60
$winsC = @(Tree-Windows $treeC).Count
$tabsC = Count-Tabs $treeC
$leavesC = @(All-Leaves $treeC)
"  (post-relaunch topology: $winsC window(s) / $tabsC tab(s) / $($leavesC.Count) pane(s))"

$rowsC = Wait-AliveCount $tmp 'c' 3 40
$idsC = @(Alive-Ids $rowsC)

# The per-tab shape, which is what says the NESTED tree flattened correctly and
# the entries landed in `tabIndex` order: the split rode in `tabIndex` 0, the
# lone leaf in 1. A translator that lost the split, or sorted the group by reply
# order (the reply lists tab 1 first), gets these the wrong way round.
$tabPanes = @()
foreach ($w in @(Tree-Windows $treeC)) {
    foreach ($t in @($w.tabs)) { $tabPanes += @(Leaf-Nodes $t.splits).Count }
}

# Every session id the Mac blobs named was ATTACHed to. The roster afterwards is
# deliberately NOT the oracle - `session-relaunch = restore` retires each
# tombstone and opens a fresh shell, so those ids are new by design (header).
$logC = "$tmp\app-c.log"
$logText = Out-Text $logC
$attached = @($idsA | Where-Object { $logText -like "*attach: session=$_*" })

if ($NegativeControl) {
    # Invert the claim T337 exists for. A control that PASSES here is scoring a
    # build that still drops every Mac blob on the floor.
    "NEGATIVE CONTROL: asserting the Mac blobs were NOT rebuilt - this run MUST fail"
    Assert "C1 the relaunch did not rebuild the Mac topology (inverted)" (
        -not ($winsC -eq 1 -and $tabsC -eq 2 -and $leavesC.Count -eq 3))
} else {
    Assert "C1 one window with two tabs and three panes came back" (
        $winsC -eq 1 -and $tabsC -eq 2 -and $leavesC.Count -eq 3)
    Assert "C2 the split landed in tab one and the lone pane in tab two" (
        $tabPanes.Count -eq 2 -and $tabPanes[0] -eq 2 -and $tabPanes[1] -eq 1)
    Assert "C3 all three session ids the Mac blobs named were ATTACHed to" (
        $attached.Count -eq 3)
    Assert "C4 no extra window was opened alongside the rebuild" ($winsC -eq 1)

    # C5 (T623): the Mac blobs carried primaryScreenHeight=1400 with a Cocoa
    # (bottom-up) frame y=60 h=620, so the restored window's top must sit at
    # 1400-60-620 = 720 from the screen top - NOT at the vertically mirrored 60
    # a pass-through would produce. The oracle is the re-synced local manifest,
    # which records the captured frame of the window the restore actually
    # placed. Tolerance covers workspace-vs-screen conversion drift for a
    # minimized window; it is far smaller than the 660px flip being asserted.
    $frameY = $null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        try {
            $man = (Get-Content (Manifest-Path $tmp) -Raw -ErrorAction Stop) | ConvertFrom-Json
            $manWins = @($man.windows | Where-Object { $null -ne $_.frame })
            if ($manWins.Count -ge 1) { $frameY = $manWins[0].frame.y; break }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    "  (restored window frame y = $frameY, flip target 720, mirrored value 60)"
    Assert "C5 the restored window came back the right way up (y ~ 720, not 60)" (
        $null -ne $frameY -and [math]::Abs($frameY - 720) -le 80)
}

if ($script:failures -gt 0) {
    "== DIAG: fixture ids=$($idsA -join ' ')"
    "== DIAG: post-restore alive ids=$($idsC -join ' ') attached=$($attached.Count)"
    "== DIAG: panes per tab=$($tabPanes -join ',')"
    "== DIAG: layouts.json at $(Layouts-Path $tmp)"
    $rl = "$tmp\app-c.log"
    if (Test-Path $rl) {
        "== DIAG: restore log lines --"
        Get-Content $rl | Select-String -Pattern 'session-restore|restore all|attach|layout' | Select-Object -Last 25 | ForEach-Object { "     $_" }
    }
}

} finally {
    "== cleanup"
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($script:failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { "artifacts preserved at $root" }
}

# A green NORMAL run stamps the covered files (T783) so guard-due can answer
# "has this harness been run against the code as it now stands?". Red leaves
# the stamp alone (red stays due), and a -NegativeControl run - green or not -
# is scoring an inverted claim, which is not a sweep of the guard's subject.
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path (Split-Path $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard layout-blob-cross-lineage -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS ($script:passes assertions)"; exit 0 }
else { "$($script:failures) FAILURE(S) / $script:passes passed"; exit 1 }
