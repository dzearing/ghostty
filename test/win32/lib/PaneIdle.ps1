# PaneIdle.ps1 - "is this pane's shell sitting at its prompt?" (T1284).
#
# A pane whose shell has DESCENDANTS does not close on a chord: `Surface.close`
# asks `shellIsIdleNow`, and a busy shell raises the confirmation dialog
# instead (T41). That dialog is MODAL - it disables the owner window and runs
# its own message loop - so a script that closes a pane without first knowing
# the shell is idle does not merely score one wrong assertion. It scores the
# rest of the run: the pane count never moves, the owner never re-enables, and
# every later chord reads as "the keystroke never arrived".
#
# That is precisely the shape `chooser-close-chord.ps1` scored inside the suite
# on 2026-09-02 (three reds) and never scored alone (ALL PASS), which was filed
# as a chord that could not reach a background desktop. The chord reaches it
# fine. What varies with box load is whether the shell in a freshly split pane
# has finished starting.
#
# Usage (after lib\TestDesktop.ps1, which owns the window helpers):
#
#     . (Join-Path $PSScriptRoot 'lib\PaneIdle.ps1')
#     $idle = Wait-PanesIdle -Exe $Exe -TimeoutMs 20000
#     Assert $idle.Idle "the shells are idle before the chord ($($idle.Text))"
#     ...
#     $dlg = Get-CloseConfirmDialog -ProcessId $g.Pid
#     Assert ($dlg -eq [IntPtr]::Zero) 'the close raised no confirmation dialog'
#     [void](Clear-CloseConfirmDialog -ProcessId $g.Pid)

# Every live descendant pid of $Root, from the OS process table.
function Get-DescendantPids([int]$Root) {
    if ($Root -le 0) { return @() }
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId, Name
    $byParent = @{}
    foreach ($p in $all) {
        $key = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($key)) { $byParent[$key] = @() }
        $byParent[$key] += $p
    }
    $out = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        foreach ($child in $byParent[$cur]) {
            $out += $child
            $queue.Enqueue([int]$child.ProcessId)
        }
    }
    # Plain `return`: `return ,$out` would wrap an EMPTY array in a one-element
    # array, so `@(Get-DescendantPids …)` would count one child where there are
    # none - the PS 5.1 trap that makes an idle shell read as busy.
    return $out
}

# Every pane's shell pid, straight from the app. `+list --json` reports each
# tab's split TREE, so the shells are its leaves.
function Get-PaneShellPids([string]$Exe) {
    $json = & $Exe +list --json 2>$null | Out-String
    if (-not $json -or $json.Trim().Length -eq 0) { return @() }
    try { $tree = $json | ConvertFrom-Json } catch { return @() }
    if ($null -eq $tree) { return @() }
    $root = if ($tree.PSObject.Properties.Name -contains 'data') { $tree.data } else { $tree }
    $out = @()
    foreach ($w in @($root.windows)) {
        foreach ($t in @($w.tabs)) {
            $stack = New-Object System.Collections.Stack
            $stack.Push($t.splits)
            while ($stack.Count -gt 0) {
                $n = $stack.Pop()
                if ($null -eq $n) { continue }
                if ($n.type -eq 'leaf') {
                    if ($n.terminal -and [int]$n.terminal.pid -gt 0) { $out += [int]$n.terminal.pid }
                } else {
                    if ($n.right) { $stack.Push($n.right) }
                    if ($n.left) { $stack.Push($n.left) }
                }
            }
        }
    }
    return $out
}

<#
Wait until EVERY pane the app reports has a descendant-free shell.

Returns a hashtable rather than a bare bool, so the caller can name what was
still running when it gave up:

    Idle  - $true when every shell was descendant-free before the timeout
    Pids  - the shell pids that were examined
    Busy  - the descendant processes still there at the end
    Text  - a one-line summary for an assertion message

A run with NO panes yet answers not-idle: "nothing to be busy" and "the app has
not told us about its panes" are different states, and only the caller knows
which one it is looking at.
#>
function Wait-PanesIdle {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [int]$TimeoutMs = 20000,
        [int]$PollMs = 400
    )
    $waited = 0
    $pids = @()
    $busy = @()
    while ($true) {
        $pids = @(Get-PaneShellPids $Exe)
        if ($pids.Count -gt 0) {
            $busy = @()
            foreach ($shell in $pids) { $busy += @(Get-DescendantPids $shell) }
            if ($busy.Count -eq 0) {
                return @{ Idle = $true; Pids = $pids; Busy = @(); Text = "$($pids.Count) shell(s) idle" }
            }
        }
        if ($waited -ge $TimeoutMs) { break }
        Start-Sleep -Milliseconds $PollMs
        $waited += $PollMs
    }
    $text = if ($pids.Count -eq 0) {
        'the app reported no panes'
    } else {
        "still running: " + (($busy | ForEach-Object { $_.Name }) -join ',')
    }
    return @{ Idle = $false; Pids = $pids; Busy = $busy; Text = $text }
}

# The close-confirmation dialog, if one is up. `Surface.close` raises it for a
# shell that is not idle, and `Window.confirmCloseIfNeeded` for the WM_CLOSE
# half; both use the same window class.
function Get-CloseConfirmDialog {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    return (Get-TestWindow -ProcessId $ProcessId -Class 'GhozttyConfirmDialog')
}

# Escape any close-confirmation dialog, so a modal raised by a close nobody
# expected cannot go on disabling the owner window for the rest of the run.
# Returns $true when one was there and is now gone.
function Clear-CloseConfirmDialog {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$TimeoutMs = 3000
    )
    $dlg = Get-CloseConfirmDialog -ProcessId $ProcessId
    if ($dlg -eq [IntPtr]::Zero) { return $false }
    [void](Send-TestControlKey -Control $dlg -Key Escape)
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        if ((Get-CloseConfirmDialog -ProcessId $ProcessId) -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $false
}
