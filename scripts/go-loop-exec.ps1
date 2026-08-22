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
# New-LoopPromptFile (T210). Functions only, no side effects at load.
. (Join-Path $PSScriptRoot 'loop-session.ps1')

function Ghoz([string[]]$argList) {
    # T279: the command line is built HERE, not by PowerShell. This script hands
    # ghoztty a window LABEL (`--title=$Marker $Label`) and a duplicate-window
    # NOTE - text a caller composed, which can carry a `"` or end in `\`, and
    # PowerShell 5.1 puts neither on a command line intact.
    #
    # It also settles T663 for this script: reaching CreateProcess directly
    # captures a GUI-subsystem exe's stdout without the `2>&1` merge that used to
    # force it, so `+list --json` is parsed from stdout alone and a stderr line
    # can no longer break ConvertFrom-Json. Err is kept separately for the log.
    $r = Invoke-NativeExact -FilePath (Resolve-GhozttyCliExe $GhozttyExe) -Arguments $argList
    return @{ Code = $r.Code; Out = $r.Out.Trim(); Err = $r.Err.Trim() }
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
    # T210: through a file when the exe supports it, never argv otherwise. This is
    # the duplicate-window message and it is prose - PowerShell 5.1 does not
    # escape an embedded `"` when it builds a native command line, and +send-keys
    # concatenates positional arguments with NO separator, so a re-tokenized note
    # arrives as run-together text. $GhozttyExe here is usually the INSTALLED
    # release, which can predate the flag, so the transport is probed not assumed.
    $keys = New-LoopSendKeysText -Exe $GhozttyExe -Text $text -Tag 'exec-note'
    try { return Ghoz (@('+send-keys', "--target=$paneId") + $keys.Args + @('Enter')) }
    finally { if ($keys.File) { Remove-Item -LiteralPath $keys.File -ErrorAction SilentlyContinue } }
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
        if ($r.Code -ne 0) { "ERROR rename failed: $($r.Out) $($r.Err)".Trim(); exit 2 }
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

        # T783: is the loop's own harness stale? Reported here because this is
        # the one command every turn runs first, and because a loop-script edit
        # can arrive by `git pull` from a turn that never touched it. REPORTED,
        # never enforced: a claim that could exit nonzero over a stale stamp
        # would wedge the loop, which is the disease and not the cure. The teeth
        # are in `parity-tasks.ps1 validate`, at the pre-commit gate.
        # T1054: zig never evicts its build cache and this repo builds all day,
        # so the drive fills on roughly a monthly clock - and a full drive does
        # not announce itself. Every floor lane dies in five seconds with a bare
        # `error: Unexpected` from zig, which reads as red code, so a turn can
        # spend its whole context on a compiler error that is really a disk.
        # Reported (and cleared) HERE because this is the one command every turn
        # runs before it needs the disk, and because clearing is only safe when
        # no lane is mid-build - which at claim time is guaranteed. Never fatal
        # and never nonzero: a claim that can fail over housekeeping wedges the
        # loop. The check itself is O(1) on free space plus one non-recursive
        # directory enumeration, so a healthy box pays nothing for it.
        $cacheScript = Join-Path $PSScriptRoot 'build-cache.ps1'
        if (Test-Path -LiteralPath $cacheScript) {
            $cacheOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $cacheScript sweep -Repo $Repo 2>&1 | Out-String
            foreach ($line in ($cacheOut -split "`r?`n")) { if ($line.Trim()) { "  $($line.Trim())" } }
        }

        $dueScript = Join-Path $PSScriptRoot 'guard-due.ps1'
        if (Test-Path -LiteralPath $dueScript) {
            $dueOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $dueScript check -Repo $Repo 2>&1 | Out-String
            foreach ($line in ($dueOut -split "`r?`n")) { if ($line.Trim()) { "  $line" } }
        }

        # T948: arm the shared-index commit guard. core.hooksPath is LOCAL
        # config - it cannot arrive by `git pull`, and a clone where nobody ran
        # `install` has no guard at all - so it is re-asserted here, in the one
        # command every turn runs first. Idempotent and silent-ish when already
        # set; never fatal, because a repo that cannot take a hook config is
        # still a repo the loop must be able to work in.
        $guardScript = Join-Path $PSScriptRoot 'git-commit-guard.ps1'
        if (Test-Path -LiteralPath $guardScript) {
            $guardOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript install -Repo $Repo 2>&1 | Out-String
            foreach ($line in ($guardOut -split "`r?`n")) { if ($line.Trim()) { "  $line" } }
        }

        # T957: keep the `upstream` remote wired up. Same argument as the commit
        # guard above and the same remedy: a remote is LOCAL config, so it cannot
        # arrive by `git pull` and a fresh clone has none - and without it every
        # sha docs\design\windows-parity-upstream-pull-plan.md pins is reachable
        # from no ref at all, which makes them `git gc` bait. Never fatal: a
        # fetch needs GitHub, and a loop that cannot claim because the network
        # is down is a worse failure than a stale upstream ref. Fetches at most
        # once a day.
        #
        # T1099: `ensure` also ANCHORS each plan sha with a local tag, and the
        # line printed below is now the full verdict rather than "upstream/main
        # resolved". It used to be the weaker one, which is why this block could
        # print UPSTREAM OK on the very turn whose acceptance run scored five
        # failures against this repo. It can print UPSTREAM PROBLEM now; it still
        # exits 0, because the teeth belong in test\win32\upstream-remote.ps1
        # (via guard-due), not in a claim that must never wedge.
        $upstreamScript = Join-Path $PSScriptRoot 'upstream-remote.ps1'
        if (Test-Path -LiteralPath $upstreamScript) {
            $upOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $upstreamScript ensure -Repo $Repo 2>&1 | Out-String
            foreach ($line in ($upOut -split "`r?`n")) { if ($line.Trim()) { "  $line" } }
        }

        # T829: did the box come back from its last reboot by itself, or did the
        # loop sit dead until somebody signed in? Reported HERE for the same
        # reason the guard report above is: this is the one command every turn
        # runs, and it is the first moment after a reboot that anything of ours
        # is alive to say so. Nothing can send a signal DURING that outage -
        # with no interactive session there is no process to send one - so the
        # signal is the first thing seen on the way back, and it is a measured
        # number rather than somebody's recollection. Idempotent on the boot
        # timestamp, so it speaks once per reboot and stays silent every other
        # turn.
        $bootScript = Join-Path $PSScriptRoot 'go-loop-boot.ps1'
        if (Test-Path -LiteralPath $bootScript) {
            $bootOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $bootScript record -Repo $Repo 2>&1 | Out-String
            foreach ($line in ($bootOut -split "`r?`n")) { if ($line.Trim()) { $line } }
        }

        # T847: anything dirty in the tree RIGHT NOW is a dead turn's work -
        # this turn has not touched a file yet. The CLAUDE.md split sat
        # uncommitted for two days while task commits landed around it, because
        # nothing at any turn boundary was obliged to notice; this snapshot is
        # the noticing. Same division of labor as the guard-due report above:
        # reported here, enforced by `parity-tasks.ps1 validate`, which fails
        # while these paths are still dirty - fold them into their own commit,
        # revert them, or hand them to a filed task with
        # `parity-tasks.ps1 ack-stranded <Tid>` (the ack survives re-claims).
        # The snapshot lives NEXT TO THE LOCK, so a harness driving claim with
        # a fixture -LockPath never touches the real repo's snapshot. Caveat:
        # a manual mid-turn `claim` re-snapshots the turn's own uncommitted
        # edits as stranded; the validate failure that causes is loud and its
        # message says what to do, which beats a silent miss in both directions.
        $strandedPath = $LockPath -replace '\.lock\.json$', '.stranded.json'
        if ($strandedPath -eq $LockPath) { $strandedPath = "$LockPath.stranded.json" }
        $gitDirty = @(& git -C $Repo status --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) {
            "  (stranded-work check skipped: git status failed in $Repo)"
        } elseif (@($gitDirty | Where-Object { $_ }).Count -eq 0) {
            if (Test-Path -LiteralPath $strandedPath) {
                Remove-Item -LiteralPath $strandedPath -Force -ErrorAction SilentlyContinue
            }
            "  tree clean at claim"
        } else {
            $paths = @($gitDirty | Where-Object { $_ } | ForEach-Object { $_.Substring(3) })
            $ackTask = $null; $ackPaths = @()
            if (Test-Path -LiteralPath $strandedPath) {
                try {
                    $old = Get-Content -LiteralPath $strandedPath -Raw | ConvertFrom-Json
                    if ($old.ackTask) { $ackTask = [string]$old.ackTask; $ackPaths = @($old.ackPaths) }
                } catch { }
            }
            $snapDir = Split-Path -Parent $strandedPath
            if ($snapDir -and -not (Test-Path -LiteralPath $snapDir)) {
                New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
            }
            ([ordered]@{
                takenAt  = (Get-Date).ToString('o')
                pane     = $PaneId
                paths    = $paths
                ackTask  = $ackTask
                ackPaths = $ackPaths
            } | ConvertTo-Json -Depth 4) | Out-File -FilePath $strandedPath -Encoding utf8
            "  STRANDED WORK: $($paths.Count) path(s) already dirty at claim (a dead turn's work) - validate will fail while they stay dirty; fold, revert, or ack-stranded them"
            foreach ($p in @($paths | Select-Object -First 8)) { "    $p" }
            if ($paths.Count -gt 8) { "    ... and $($paths.Count - 8) more" }
        }

        # T1057: is anything committed here that origin has never seen? The
        # tree being clean says nothing about that - a turn that committed and
        # died before pushing leaves a spotless tree and work only this box
        # has. Reported here and FAILED ON by `parity-tasks.ps1 validate`, the
        # same two-ended arrangement as stranded work above, because the rule
        # that says to push every commit (go.md step 4) had to be restated by
        # the user twice while it was honour-system.
        $pushGuard = Join-Path $PSScriptRoot 'git-commit-guard.ps1'
        if (Test-Path -LiteralPath $pushGuard) {
            $pushOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $pushGuard unpushed -Repo $Repo 2>&1 | Out-String
            foreach ($line in ($pushOut -split "`r?`n")) { if ($line.Trim()) { "  $line" } }
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
