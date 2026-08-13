# T471 acceptance: the scrollback guard follows the CHILD's pty, not the local OS.
#
# T431 fixed real data loss: growing a pane's row count imports scrollback into
# the active area, and a ConPTY child's post-resize repaint then erases it -
# permanently, because the import is a MOVE. The guard that stops that
# (`src/termio/history_guard.zig`) used to switch itself on with
# `builtin.os.tag == .windows`, which answers "does the LOCAL machine run ConPTY
# children". For a local pane that is the same question. For a REMOTE pane it is
# not: the shell lives on the agent's machine, so a Mac window can own a ConPTY
# child (guard needed, and its absence was the same data loss) and a Windows
# window can own a POSIX one (guard pointless).
#
# So the agent reports its pty flavour in the HELLO (`Hello.pty_flavor`, an
# additive optional field) and each pane arms the guard from THAT.
#
# WHAT THIS SCRIPT CAN AND CANNOT MEASURE ON ONE BOX. The real cross-OS case
# needs two machines running two operating systems. What one box CAN prove is the
# thing that was actually wrong - that the decision is read off the wire rather
# than off `builtin.os.tag` - by making the agent report the other flavour:
#
#   A  agent reports what it really is (conpty)  -> guard ARMED  -> no history lost
#   B  agent reports `posix` (GHOZTTY_AGENT_PTY_FLAVOR, a debug-only test seam)
#                                                -> guard OFF    -> history IS lost
#
# B asserts LOSS, and that is deliberate. The child in B is still a real ConPTY
# that still repaints, so a client that took the flavour off the wire disarms a
# guard it needed and the rows the viewport gained are eaten - exactly the
# pre-T431 behaviour. Loss is therefore the only observable that says "the
# flavour is load-bearing"; if the client were still deciding from the local OS,
# B would come back clean and indistinguishable from A. It is a negative control,
# not a description of anything a user should ever see.
#
# It also catches the way this script could quietly measure nothing: if the panes
# were NOT agent-backed (persistence off, or the agent refused to start), every
# pane is an exec pane whose flavour is this machine's, B loses nothing, and B
# fails. A green B is only reachable through a real HELLO.
#
# THE ORACLE is numbered lines, as in `scrollback-narrow.ps1`: fill the pane with
# `line 1`..`line 500`, read the scrollback back with `+read` after the gesture,
# and a number that was there before and is not there after is destroyed history.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1) and only touches
# ghoztty processes running from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\history-guard-flavor.ps1
param(
    [string]$ExePath,
    [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = '-hgflavor'
$errlog = Join-Path $env:TEMP 'ghoztty-hgflavor-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

# `ghoztty +verb > file` writes 0 bytes from PowerShell; a pipe is the only
# capture that works (T245).
function Read-Pane([string]$name, [int]$lines) {
    return (& $exe +read --name=$name --lines=$lines 2>&1 | Out-String)
}

# The set of `line <N>` numbers present in a read. `,` keeps PowerShell from
# unrolling the set into the pipeline.
function Get-LineNumbers([string]$text) {
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($m in [regex]::Matches($text, '(?m)^\s*line (\d+)\s*$')) {
        [void]$set.Add([int]$m.Groups[1].Value)
    }
    return , $set
}

function Get-FirstLeafId($node) {
    if (-not $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal.id }
    $l = Get-FirstLeafId $node.left
    if ($l) { return $l }
    return Get-FirstLeafId $node.right
}

# Send a command line VERBATIM. PowerShell 5.1 does not escape embedded quotes
# when it builds a native command line (T279), so the bytes go through a file.
function Send-Line([string]$paneId, [string]$text) {
    $f = Join-Path $env:TEMP ("ghoztty-hgflavor-keys-" + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding $false))
    & $exe +send-keys --target=$paneId "--keys-file=$f" Enter 2>&1 | Out-Null
    Remove-Item $f -ErrorAction SilentlyContinue
}

function Missing-From($before, $after) {
    $missing = @()
    foreach ($n in @($before)) { if (-not $after.Contains($n)) { $missing += $n } }
    return , (@($missing | Sort-Object))
}

# One trial: bring the app up with the agent reporting `$Flavor` (empty = tell
# the truth), fill a pane, make it taller, and report what the scrollback lost.
# Returns @{ Filled = <lines captured>; Lost = <lines destroyed>; Sessions = <n> }.
function Invoke-GrowTrial([string]$Label, [string]$Flavor) {
    if ($Flavor) { $env:GHOZTTY_AGENT_PTY_FLAVOR = $Flavor }
    else { Remove-Item Env:\GHOZTTY_AGENT_PTY_FLAVOR -ErrorAction SilentlyContinue }

    # A fresh agent per trial: the flavour is read once, at agent start, and an
    # agent left over from the previous trial would answer with ITS flavour.
    Kill-RepoInstances

    $result = @{ Filled = 0; Lost = -1; Sessions = 0 }
    # persistence: ON deliberately - an agent-backed pane is the whole subject
    # here, and an exec pane has no HELLO to read a flavour from.
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', '--session-persistence=true')
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($top -eq [IntPtr]::Zero) { return $result }

    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 820)
    Start-Sleep -Seconds 3

    # How many agent sessions exist tells us the pane really is agent-backed.
    # Reported, not asserted here: section B is the assertion that can only pass
    # through a real HELLO.
    try {
        $sj = & $exe +sessions --json 2>&1 | Out-String
        $result.Sessions = @(($sj | ConvertFrom-Json).data.sessions).Count
    } catch { $result.Sessions = -1 }

    $json = & $exe +list --json 2>&1 | Out-String
    $w = (($json | ConvertFrom-Json).data.windows)[0]
    $paneId = Get-FirstLeafId $w.tabs[0].splits
    if ($paneId -notmatch '^[0-9A-Fa-f-]{36}$') { return $result }

    Send-Line $paneId 'for /l %i in (1,1,500) do @echo line %i'
    Start-Sleep -Seconds 12
    $before = Get-LineNumbers (Read-Pane $paneId 900)
    $result.Filled = $before.Count
    if ($before.Count -lt 450) { return $result }

    # The gesture: a taller pane. Ghostty pulls history down to fill the rows the
    # viewport gained; whether that history survives is the guard's whole job.
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 1300)
    Start-Sleep -Seconds 4
    $after = Get-LineNumbers (Read-Pane $paneId 900)
    $lost = Missing-From $before $after
    $result.Lost = $lost.Count

    $note = "  $Label".PadRight(38) + "$($before.Count) -> $($after.Count) lines"
    if ($lost.Count) {
        $note += "  -- LOST $($lost.Count): " + (($lost | Select-Object -First 20) -join ',')
    }
    Write-Host $note
    Write-Host "     agent sessions=$($result.Sessions) reported flavour=$(if ($Flavor) { $Flavor } else { 'conpty (real)' })"
    return $result
}

$td = New-TestDesktop -Interactive:$Interactive
Kill-RepoInstances

try {
    # ---- A. the agent tells the truth: guard ARMED -----------------------
    $a = Invoke-GrowTrial 'A agent says conpty (real)' ''
    Assert ($a.Filled -ge 450) "A: the fill captured ~500 lines (saw $($a.Filled))"
    if ($a.Filled -ge 450) {
        Assert ($a.Lost -eq 0) `
            "A: an agent-backed ConPTY pane kept its scrollback when grown (lost $($a.Lost))"
    }

    # ---- B. the agent claims POSIX: guard OFF ----------------------------
    # The negative control. Same box, same ConPTY child, one field different on
    # the wire - so a non-zero loss here is the flavour being load-bearing, and a
    # zero would mean the client is still deciding from `builtin.os.tag`.
    $b = Invoke-GrowTrial 'B agent says posix (test seam)' 'posix'
    Assert ($b.Filled -ge 450) "B: the fill captured ~500 lines (saw $($b.Filled))"
    if ($b.Filled -ge 450) {
        Assert ($b.Lost -gt 0) `
            "B: a pane told its child is POSIX disarms the guard (lost $($b.Lost), expected > 0)"
        Assert ($b.Sessions -ge 1) `
            "B: the pane was agent-backed, so the flavour came off a real HELLO (sessions=$($b.Sessions))"
    }
}
finally {
    Remove-Item Env:\GHOZTTY_AGENT_PTY_FLAVOR -ErrorAction SilentlyContinue
    Kill-RepoInstances
    Remove-TestDesktop
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
