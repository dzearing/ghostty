# Execution-window marking and duplicate resolution for the go.md loop (T139).
#
# The lock (scripts\go-loop-lock.ps1) answers "is another session already
# working the loop?". It cannot answer "which windows are even TRYING to?" -
# and that distinction matters, because the user routinely keeps a second
# Claude window open on this repo that only FILES tasks and never executes
# them. That window must never be treated as a rival, and must never be closed.
#
# So an execution window says so out loud: its Ghoztty window title is pinned
# to "<marker> ..." (default marker "[go-loop]") via `ghoztty +rename`, which
# `+list --json` reports back. Marked = executing. Unmarked = leave alone,
# always.
#
# `claim` is the one command go.md step 0 runs. It:
#   1. takes the lock,
#   2. on success marks this window and resolves any OTHER marked window as a
#      duplicate - it messages that window (so its session is told why), then
#      closes it, then CONTINUES; the user is never asked,
#   3. on BUSY stands down: messages the primary, unmarks, and closes itself.
#
# The arbiter is the lock, not a negotiation: whoever holds it is primary. That
# is symmetric (both sides compute the same answer) and cannot deadlock.
#
# Actions: claim | mark | unmark | list
# Exit codes: 0 primary (carry on), 3 stood down (stop), 2 error.
#
#   powershell -NoProfile -File scripts\go-loop-exec.ps1 claim
#   powershell -NoProfile -File scripts\go-loop-exec.ps1 list
param(
    [Parameter(Position = 0)]
    [ValidateSet('claim', 'mark', 'unmark', 'list')]
    [string]$Action = 'list',

    [string]$Repo,
    [string]$LockPath,
    [string]$PaneId = $env:GHOZTTY_PANE_ID,
    [int]$ClaudePid = 0,
    [string]$GhozttyExe,
    [string]$Marker = '[go-loop]',
    [string]$Label = 'ghoztty parity',
    [int]$StaleMinutes = 30,
    [int]$GraceSeconds = 5,
    [switch]$NoSelfClose,     # stand down without closing this window (tests)
    [switch]$NoClose,         # find duplicates but do not close them (tests)
    [switch]$Json
)

$ErrorActionPreference = 'Continue'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not $LockPath) { $LockPath = Join-Path (Join-Path $Repo 'temp') 'go-loop.lock.json' }
if (-not $GhozttyExe) {
    $GhozttyExe = 'ghoztty'
    $installed = Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty\ghoztty.exe'
    if (Test-Path $installed) { $GhozttyExe = $installed }
}
$lockScript = Join-Path $PSScriptRoot 'go-loop-lock.ps1'

function Ghoz([string[]]$argList) {
    $out = & $GhozttyExe @argList 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

function Get-Windows {
    $r = Ghoz @('+list', '--json')
    if ($r.Code -ne 0) { return @() }
    try { $j = $r.Out | ConvertFrom-Json } catch { return @() }
    $out = @()
    foreach ($w in $j.data.windows) {
        $panes = New-Object System.Collections.ArrayList
        foreach ($t in $w.tabs) { Add-Leaves $t.splits $panes }
        $out += [pscustomobject]@{
            Id     = $w.id
            Target = $w.target
            Title  = $w.title
            Panes  = @($panes | ForEach-Object { $_.id })
        }
    }
    return $out
}
function Add-Leaves($node, $acc) {
    if ($null -eq $node) { return }
    if ($node.type -eq 'leaf') { $acc.Add($node.terminal) | Out-Null; return }
    Add-Leaves $node.left $acc
    Add-Leaves $node.right $acc
}

function Get-MyWindow($windows) {
    if (-not $PaneId) { return $null }
    foreach ($w in $windows) { if ($w.Panes -contains $PaneId) { return $w } }
    return $null
}

function Test-Marked($w) {
    if (-not $w -or -not $w.Title) { return $false }
    return $w.Title.StartsWith($Marker)
}

function Set-Mark($paneId) {
    return Ghoz @('+rename', "--target=$paneId", "--title=$Marker $Label")
}
function Clear-Mark($paneId) {
    # An empty title unpins the window title; the pane's own title takes over.
    return Ghoz @('+rename', "--target=$paneId", '--title=')
}

function Send-Note($paneId, $text) {
    return Ghoz @('+send-keys', "--target=$paneId", $text, 'Enter')
}

# Identity must be forwarded to the lock, not re-derived there: the lock script
# would otherwise fall back to the CALLING shell's $env:GHOZTTY_PANE_ID, which
# is the harness's pane, not the one being claimed.
function Lock-Args([string]$action) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $lockScript, $action,
        '-Repo', $Repo, '-LockPath', $LockPath, '-StaleMinutes', $StaleMinutes)
    if ($PaneId) { $a += @('-PaneId', $PaneId) }
    if ($ClaudePid -gt 0) { $a += @('-ClaudePid', $ClaudePid) }
    return $a
}

function Get-LockStatus {
    $raw = & powershell @(Lock-Args 'status') -Json 2>&1 | Out-String
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

$windows = Get-Windows
$mine = Get-MyWindow $windows

switch ($Action) {

    'list' {
        $rows = foreach ($w in $windows) {
            [pscustomobject]@{
                target = $w.Target
                marked = (Test-Marked $w)
                self   = ($null -ne $mine -and $w.Id -eq $mine.Id)
                title  = $w.Title
                pane   = @($w.Panes)[0]
            }
        }
        if ($Json) { $rows | ConvertTo-Json -Depth 4 }
        else {
            foreach ($r in $rows) {
                $flag = '     '
                if ($r.marked) { $flag = 'EXEC ' }
                $me = ''
                if ($r.self) { $me = '  <- this session' }
                "$flag$($r.target)  $($r.title)$me"
            }
        }
        exit 0
    }

    'mark' {
        if (-not $PaneId) { 'ERROR no pane id (not running in a Ghoztty pane)'; exit 2 }
        $r = Set-Mark $PaneId
        if ($r.Code -ne 0) { "ERROR rename failed: $($r.Out)"; exit 2 }
        "MARKED pane=$PaneId title=`"$Marker $Label`""
        exit 0
    }

    'unmark' {
        if (-not $PaneId) { 'ERROR no pane id (not running in a Ghoztty pane)'; exit 2 }
        Clear-Mark $PaneId | Out-Null
        "UNMARKED pane=$PaneId"
        exit 0
    }

    'claim' {
        # 1. The lock is the arbiter.
        $acq = & powershell @(Lock-Args 'acquire') 2>&1 | Out-String
        $acqCode = $LASTEXITCODE
        $acq = $acq.Trim()

        if ($acqCode -eq 3) {
            # 2. Stand down - but only for a primary that is really there.
            $lock = Get-LockStatus
            $ownerPane = ''
            if ($lock) { $ownerPane = $lock.pane_id }
            $ownerWindow = $null
            foreach ($w in $windows) { if ($w.Panes -contains $ownerPane) { $ownerWindow = $w } }

            "STAND-DOWN $acq"
            if ($ownerWindow) {
                Send-Note $ownerPane ("$Marker duplicate execution window (pane $PaneId) stood down; " +
                    'you hold the loop lock and are primary.') | Out-Null
                "  notified primary in pane $ownerPane"
            } else {
                "  primary pane $ownerPane is not in this app's window list; standing down anyway"
            }
            if ($PaneId) { Clear-Mark $PaneId | Out-Null; "  unmarked this window" }
            if (-not $NoSelfClose -and $PaneId -and $ownerWindow) {
                "  closing this duplicate window"
                Ghoz @('+close', "--target=$PaneId") | Out-Null
            }
            exit 3
        }
        if ($acqCode -ne 0) { "ERROR acquire failed ($acqCode): $acq"; exit 2 }

        # 3. We are primary. Say so in the title, then clear out any rival.
        "PRIMARY $acq"
        if ($PaneId) {
            Set-Mark $PaneId | Out-Null
            "  marked this window `"$Marker $Label`""
        }

        $dupes = @()
        foreach ($w in $windows) {
            if ($mine -and $w.Id -eq $mine.Id) { continue }
            if (Test-Marked $w) { $dupes += $w }
        }
        if ($dupes.Count -eq 0) { "  no duplicate execution windows"; exit 0 }

        foreach ($d in $dupes) {
            $pane = @($d.Panes)[0]
            "  DUPLICATE execution window target=$($d.Target) pane=$pane title=`"$($d.Title)`""
            Send-Note $pane ("$Marker this window is a duplicate execution window. " +
                "Pane $PaneId holds the loop lock and is primary. Stop working; this window is closing.") | Out-Null
            if ($NoClose) { "    (not closing: -NoClose)"; continue }
            Start-Sleep -Seconds $GraceSeconds
            $r = Ghoz @('+close', "--target=$pane")
            "    closed (exit $($r.Code))"
        }
        "  resolved $($dupes.Count) duplicate(s); continuing"
        exit 0
    }
}
