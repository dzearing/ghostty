# Shared readers for the win32 session-layout manifest (T655).
#
# The manifest (`$LOCALAPPDATA\ghoztty\session-layout-debug.json`) is the file a
# restore is built from, so it is also the only place several persistence
# invariants are directly observable: which panes were captured, what screen
# each one recorded, and — the reason this file exists — the absolute agent-
# stream byte offset that screen reflects (`screen_snapshot_offset`, the WP-D3
# resume point). Three scripts had grown their own copy of the same four
# readers; T655 needed a fourth, so they live here instead.
#
# Dot-source it:
#
#   . (Join-Path $PSScriptRoot 'lib\SessionManifest.ps1')
#
# Every function takes the run's private state dir (`$tmp`, i.e. whatever the
# script set `$env:LOCALAPPDATA` to) rather than reading the ambient one: these
# scripts are hermetic and must never score against the user's real manifest.

# Where the manifest lives under a given state dir. The `-debug` name is the
# debug build's; a release build writes `session-layout.json` beside it, and no
# acceptance script may ever touch that one.
function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

# The parsed manifest, or $null when it does not exist yet or is mid-replace.
# A torn read of the atomic replace is transient by construction, so a failed
# parse is answered with $null (look again) rather than an exception.
function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw -Encoding utf8 | ConvertFrom-Json) } catch { return $null }
}

# Poll until `$pred` says the manifest is the one you are waiting for. Waiting
# on the FILE rather than sleeping a guessed interval is the difference between
# measuring the product and measuring the capture debounce: the app re-captures
# a pane's screen a couple of seconds after its output goes quiet.
function Wait-Manifest($tmp, $pred, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { try { if (& $pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 400
    }
    return $m
}

# Every leaf in the manifest, flattened across windows/tabs/nodes.
#
# NOT `All-Leaves`: several of these scripts already have a function by that
# name for the very different tree in `+list --json`, and a dot-source that
# silently replaced it would hand a live-window walker a manifest.
#
# The `, ` on the return is load-bearing: without it PowerShell unrolls a
# one-element array and the caller's `.Count` reads $null (lib\CountOrZero.ps1
# documents the trap). Its price is the OTHER half of the same rule, and it is
# the one that bites: **call it bare, never `@(Manifest-Leaves $m)`**. The `@()`
# does not unroll the wrapper - it keeps it - so the loop runs ONCE over the
# whole array, and PowerShell's member enumeration then makes
# `$leaf.screen_snapshot_offset` an `Object[]` of every pane's offset rather
# than one number. Measured: that is exactly how the first T655 run died, and
# `First-Snapshot-Leaf` carried the same `@()` from the day it was written -
# harmless only because the manifests it had been pointed at held one leaf.
function Manifest-Leaves($m) {
    $leaves = @()
    foreach ($w in @($m.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($n in @($t.nodes)) {
                if ($null -ne $n.leaf) { $leaves += $n.leaf }
            }
        }
    }
    return , $leaves
}

# The first leaf that recorded a WP-D3 pair (a screen AND the offset it
# reflects). Both halves are required: a leaf with a screen and no offset is a
# pre-T109 or budget-dropped record and says nothing about the resume point.
function First-Snapshot-Leaf($m) {
    if ($null -eq $m) { return $null }
    foreach ($leaf in (Manifest-Leaves $m)) {
        if ($leaf.screen_snapshot -and $leaf.screen_snapshot_offset) { return $leaf }
    }
    return $null
}

# T655: pane_id -> recorded resume point, for every leaf that has both.
#
# `pane_id` is the key rather than `session_id` or the leaf id because it is the
# ONE identity that round-trips a restore (session_layout.zig: the re-attached
# or relaunched process keeps the env it was spawned with). A restore-policy
# relaunch mints a brand-new session id, so keying on that would compare a pane
# against nothing.
function Snapshot-Offsets($m) {
    $map = @{}
    if ($null -eq $m) { return $map }
    foreach ($leaf in (Manifest-Leaves $m)) {
        # NOT `$pid`: that is a read-only automatic variable and assigning to
        # it throws inside the loop, which would leave the map silently empty.
        $pane = [string]$leaf.pane_id
        if ($pane -eq '') { continue }
        if ($null -eq $leaf.screen_snapshot_offset) { continue }
        $map[$pane] = [uint64]$leaf.screen_snapshot_offset
    }
    return $map
}
