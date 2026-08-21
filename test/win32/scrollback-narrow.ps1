# T431 acceptance: RESIZING a ConPTY pane must never DESTROY scrollback.
#
# The mechanism, both halves of which are fine alone:
#   1. Ghostty's resize IMPORTS history into the active area - it "pulls down"
#      scrollback when the row count grows and the cursor is on the bottom row
#      (`PageList.resizeWithoutReflow`, the `.gt` branch), and a reflow refills
#      a blank-bottomed viewport the same way. Both are a MOVE of the
#      active-area boundary, not a copy.
#   2. A ConPTY child repaints its whole viewport after every resize
#      (conhost opens with ESC[H ESC[2J), erasing rows it does not know about.
# Together: the imported rows are erased, and are then gone from history too.
#
# WHAT THE MEASUREMENT ACTUALLY FOUND, because the task was filed against the
# wrong axis. Narrowing a pane destroys NOTHING - not a hard narrow, not a
# divider-style drag, not widening back. Growing the pane's HEIGHT destroys
# exactly as many lines as the viewport gains rows (measured: 1400x820 ->
# 1400x1300 permanently deleted lines 456-473 of 500). Making a window taller,
# maximizing it, un-zooming, closing a split below: all of them. So the height
# gestures below are the ones under test, and the width gestures are kept as
# the control that says the oracle is not simply blind.
#
# THE ORACLE is numbered lines. The pane is filled with `line <N>` for N in
# 1..500 and the same scrollback is read back after each gesture. A line
# number that was there before a gesture and is not there after is destroyed
# history - `+read` walks the scrollback, so nothing else can explain a gap.
#
# The gestures, in the order a person would do them:
#   A  fill                          - baseline, what the pane captured
#   B  one hard narrow (window)      - control: width is innocent
#   C  many small narrows (a drag)   - control: what a divider drag emits
#   D  widen back                    - control
#   D2 grow the HEIGHT               - THE BUG
#   D3 shrink the height back        - the direction that costs nothing
#   D4 taller AND narrower           - both at once
#   E  clear-screen, then narrow     - a blank-bottomed viewport over deep
#                                      history is the state the reflow half
#                                      needs; T423 measured it in a unit test
#   F  +split                        - halves the pane in place
#
# Note on E under cmd.exe and Windows PowerShell: `cls` / `Clear-Host` clear
# conhost's WHOLE buffer (they emit ESC[3J), so they take the scrollback with
# them exactly as they do in conhost and Windows Terminal. That is native
# behaviour, not this bug, and it makes those two flavors unable to reach state
# E at all - which is itself worth knowing. `-Shell bash` uses terminfo `clear`
# (ESC[H ESC[2J, no 3J) and DOES reach it.
#
# There is no -NegativeControl switch: the real negative control was run, which
# is the pre-fix build. It failed D2 and D4 on this box at these geometries.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1) so it never takes
# the user's foreground. Only touches ghoztty processes running from this
# repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\scrollback-narrow.ps1
#   powershell -NoProfile -File test\win32\scrollback-narrow.ps1 -Shell bash
param(
    [string]$ExePath,
    [ValidateSet('cmd', 'pwsh', 'powershell', 'bash')]
    [string]$Shell = 'cmd',
    [switch]$Persist,
    [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = '-sbnarrow'
$errlog = Join-Path $env:TEMP 'ghoztty-sbnarrow-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
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
    Start-Sleep -Milliseconds 500
}

# `ghoztty +verb > file` writes 0 bytes from PowerShell; a pipe is the only
# capture that works (T245).
function Read-Pane([string]$name, [int]$lines) {
    return (& $exe +read --name=$name --lines=$lines 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
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

# `+list --json` nests panes in a split tree: {type:leaf,terminal:{id}} or
# {type:split,left,right}. Walk to the first leaf.
function Get-FirstLeafId($node) {
    if (-not $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal.id }
    $l = Get-FirstLeafId $node.left
    if ($l) { return $l }
    return Get-FirstLeafId $node.right
}

# Send a command line VERBATIM. PowerShell 5.1 does not escape embedded quotes
# when it builds a native command line, so `echo "line $i"` arrives at the pane
# with its quotes stripped and prints `line491` - close enough to look right and
# wrong enough to break the oracle. --keys-file is the byte-exact path.
function Send-Line([string]$paneId, [string]$text) {
    $f = Join-Path $env:TEMP ("ghoztty-sbnarrow-keys-" + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding $false))
    & $exe +send-keys --target=$paneId "--keys-file=$f" Enter 2>&1 | Out-Null
    Remove-Item $f -ErrorAction SilentlyContinue
}

function Missing-From($before, $after) {
    $missing = @()
    foreach ($n in @($before)) { if (-not $after.Contains($n)) { $missing += $n } }
    return , (@($missing | Sort-Object))
}

# Read the pane and report what the previous set lost. Returns the new set.
function Step([string]$paneId, [string]$label, $prev) {
    $set = Get-LineNumbers (Read-Pane $paneId 900)
    $lost = Missing-From $prev $set
    $note = "  $label".PadRight(34) + "$($set.Count) lines"
    if ($lost.Count) {
        $note += "  -- LOST $($lost.Count): " + (($lost | Select-Object -First 20) -join ',')
        Write-Host $note -ForegroundColor Yellow
    } else {
        Write-Host $note
    }
    $script:lastLost = $lost
    return , $set
}

# Per-flavor: the command that prints `line 1` .. `line 500`, and the clear.
$fill = switch ($Shell) {
    'cmd'        { 'for /l %i in (1,1,500) do @echo line %i' }
    'pwsh'       { '1..500 | ForEach-Object { "line $_" }' }
    'powershell' { '1..500 | ForEach-Object { "line $_" }' }
    'bash'       { 'for i in $(seq 1 500); do echo "line $i"; done' }
}
$clear = switch ($Shell) {
    'cmd'        { 'cls' }
    'pwsh'       { 'clear' }
    'powershell' { 'clear' }
    'bash'       { 'clear' }
}
$shellPath = switch ($Shell) {
    'cmd'        { $null }
    'pwsh'       { 'pwsh.exe' }
    'powershell' { 'powershell.exe' }
    'bash'       { 'C:\Program Files\Git\bin\bash.exe' }
}

$td = New-TestDesktop -Interactive:$Interactive
Kill-RepoInstances

try {
    $launchArgs = @('--config-default-files=false')
    $launchArgs += $(if ($Persist) { '--session-persistence=true' } else { '--session-persistence=false' })
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid

    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) 'top-level window appeared'
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }
    Write-Host "  shell=$Shell persistence=$([bool]$Persist)"

    # `command-shell` only governs IPC --command, not the pane's own shell, so a
    # non-cmd flavor gets its own window opened with --shell/--command (which
    # keeps the shell alive after the command by design, per flavor).
    # A flavor that is not installed on this box is a SKIP, not a failure -
    # otherwise the absence of pwsh reads as a scrollback bug.
    # The verdict goes through the shared scorer (T271): this branch ends the
    # run, so if the setup assertions above had ALSO been skipped it would score
    # a run that measured nothing as a pass.
    if ($shellPath -and -not (Get-Command $shellPath -ErrorAction SilentlyContinue)) {
        Write-Host "SKIP  $Shell is not installed on this box ($shellPath)" -ForegroundColor DarkGray
        Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped 1
    }

    if ($shellPath) {
        & $exe +new-window --target=flavor "--shell=$shellPath" '--command=echo ready' 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        $top = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | Where-Object Visible |
            Select-Object -Last 1)[0].Hwnd
    }

    # A wide window, so narrowing later is a real change in columns.
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 820)
    Start-Sleep -Seconds 2

    $json = & $exe +list --json 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    $wins = ($json | ConvertFrom-Json).data.windows
    $w = if ($shellPath) { @($wins | Where-Object { $_.target -eq 'flavor' })[0] } else { $wins[0] }
    $paneId = Get-FirstLeafId $w.tabs[0].splits
    Assert ($paneId -match '^[0-9A-Fa-f-]{36}$') "found pane id ($paneId)"

    # ---- A. fill --------------------------------------------------------
    Send-Line $paneId $fill
    Start-Sleep -Seconds 10
    $setA = Step $paneId 'A fill' @()
    if ($setA.Count -lt 450) {
        $raw = Read-Pane $paneId 40
        Write-Host "     --- what the pane actually shows ---" -ForegroundColor DarkGray
        ($raw -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 12) |
            ForEach-Object { Write-Host "     | $_" -ForegroundColor DarkGray }
    }
    Assert ($setA.Count -ge 450) "the fill captured ~500 lines (saw $($setA.Count))"

    # ---- B. one hard narrow ---------------------------------------------
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 700 -Height 820)
    Start-Sleep -Seconds 3
    $setB = Step $paneId 'B narrow 1400->700' $setA
    Assert ($script:lastLost.Count -eq 0) "one hard narrow destroyed no scrollback"

    # ---- C. many small narrows, the way a drag arrives -------------------
    for ($w = 690; $w -ge 460; $w -= 20) {
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width $w -Height 820)
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Seconds 2
    $setC = Step $paneId 'C drag 700->460' $setB
    Assert ($script:lastLost.Count -eq 0) "a divider-style drag destroyed no scrollback"

    # ---- D. widen back ---------------------------------------------------
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 820)
    Start-Sleep -Seconds 3
    $setD = Step $paneId 'D widen back to 1400' $setC
    Assert ($script:lastLost.Count -eq 0) "widening back destroyed no scrollback"

    # ---- D2. grow the pane's HEIGHT --------------------------------------
    # A taller viewport is the other way to get blank rows under the content:
    # conhost grows its buffer and leaves the new rows empty, while ghostty
    # pulls history down to fill the taller active area. If the repaint then
    # erases them, growing a window eats scrollback.
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 1300)
    Start-Sleep -Seconds 3
    $setD2 = Step $paneId 'D2 taller 820->1300' $setD
    Assert ($script:lastLost.Count -eq 0) "growing the pane's height destroyed no scrollback"

    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 600)
    Start-Sleep -Seconds 3
    $setD3 = Step $paneId 'D3 shorter 1300->600' $setD2
    Assert ($script:lastLost.Count -eq 0) "shrinking the pane's height destroyed no scrollback"

    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 700 -Height 1300)
    Start-Sleep -Seconds 3
    $setD4 = Step $paneId 'D4 taller AND narrower' $setD3
    Assert ($script:lastLost.Count -eq 0) "growing height while narrowing destroyed no scrollback"

    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 820)
    Start-Sleep -Seconds 2
    $setD = Get-LineNumbers (Read-Pane $paneId 900)

    # ---- E. clear the viewport, then narrow ------------------------------
    # This is the state the mechanism needs: deep history, blank viewport.
    Send-Line $paneId $clear
    Start-Sleep -Seconds 3
    $setE0 = Step $paneId "E0 after '$clear'" $setD
    $clearAtePast = $script:lastLost.Count
    if ($clearAtePast -ge 400) {
        Write-Host "     ('$clear' clears the whole buffer on this shell -- state E is unreachable here)"
    }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 600 -Height 820)
    Start-Sleep -Seconds 3
    $setE = Step $paneId 'E narrow over blank viewport' $setE0
    Assert ($script:lastLost.Count -eq 0) `
        "narrowing over a cleared viewport destroyed no scrollback"

    # ---- F. +split halves the pane in place ------------------------------
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 820)
    Start-Sleep -Seconds 2
    $setF0 = Get-LineNumbers (Read-Pane $paneId 900)
    & $exe +split --direction=right 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $setF = Step $paneId 'F +split (pane halved)' $setF0
    Assert ($script:lastLost.Count -eq 0) "splitting off the pane destroyed no scrollback"
    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail
