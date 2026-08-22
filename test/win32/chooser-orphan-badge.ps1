# Machine-chooser ORPHAN MARK acceptance (tracker T520).
#
# The chooser's local roster now marks each live session that no local pane
# holds - the "not in any window" badge - so a left-over session (the agent
# holds it, nothing shows it) is distinguishable at a glance from one that some
# other window has. This script drives the mark's whole life cycle against a
# REAL local agent:
#
#   1. POSITIVE/NEGATIVE CONTROL: with every session held by an open pane, the
#      roster says "0 session(s) not in any window" - the oracle line fires
#      even at zero, so the mark's ABSENCE is asserted, not assumed.
#   2. OPEN a session directly against the agent (remote-test-client --hold,
#      the T411/T108 shape: the client detaches and the session stays alive
#      with no pane) - reopening the chooser counts exactly that one.
#   3. Resume the marked row from the roster (Right/Down/Return, the T320
#      path); reopening the chooser shows the count back at zero - the mark
#      clears the moment a window holds the session.
#
# WHY A LOG LINE IS THE ORACLE. The roster is owner-drawn on the dialog's own
# surface - there is no HWND to read a badge back from - so the count is said
# out loud per adopted local roster (SessionRoster.logOrphans) and
# cross-checked here against an INDEPENDENT source: `ghoztty +sessions --json`,
# which dials the agent directly and never goes through the app. Because the
# same count can legitimately repeat across chooser opens, every wait is on the
# NUMBER of matching lines rising past a baseline, never on "a line exists".
#
# WHY NOT the kill-the-app-and-drop-the-manifest fixture chooser-resume.ps1
# uses: since T194 the launch restore also consults the agent's own layout
# blobs, so a relaunch re-attaches everything and no orphan survives it. The
# direct-OPEN client is the shape that stays orphaned by construction.
#
# T248: the repo's agent AND app are killed at setup and the agent's state is
# dropped, so the fixture is built fresh every run.
# T267: the script sets its own window size rather than inheriting one.
#
#   powershell -NoProfile -File test\win32\chooser-orphan-badge.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    # Speaks the agent protocol directly. Built on demand: `zig build remote-test-client`.
    [string]$ClientExe = 'D:\git\ghoztty\zig-out\bin\remote-test-client.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $ClientExe)) { $ClientExe = Join-Path $repo 'zig-out\bin\remote-test-client.exe' }

# Isolate the app's IPC endpoint (inherited through CreateProcessW). The AGENT
# pipe has no env override - the debug agent is per-user - which is fine: setup
# kills the repo's agent, so the app starts a fresh one this run owns.
$env:GHOZTTY_PIPE_SUFFIX = "-t520$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PipeBridge.ps1')  # Get-LocalAgentPipeName

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# Kill only what this repo built. The installed release (and ITS agent, which
# owns the user's real terminal) is never touched.
function Stop-RepoProcesses([string[]]$Names) {
    # T351: the ghoztty halves go through the one shared, path-exact kill
    # (lib\CleanSlate.ps1) - every private copy answered "does the agent go too"
    # alone. Anything else in $Names is this script's own litter, so it stays local.
    if ($Names -contains 'ghoztty') {
        [void](Stop-RepoGhoztty -Exe $Exe -AppOnly:(-not ($Names -contains 'ghoztty-agent')) -SettleMs 0)
    }
    foreach ($name in ($Names | Where-Object { $_ -notin @('ghoztty', 'ghoztty-agent') })) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 600
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json', 'layouts.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

function Remove-LayoutManifest {
    Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json') -ErrorAction SilentlyContinue
}

# `ghoztty +verb > file` writes zero bytes from PowerShell (T245) - capture
# through a pipe instead.
function Get-Sessions {
    $out = (& $Exe +sessions --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return @() }
    try { $j = $out | ConvertFrom-Json } catch { return @() }
    if ($null -eq $j) { return @() }
    # PS5.1 unrolls a one-element array on return, so wrap before counting.
    return @($j)
}

# The rows the roster renders, in agent order (alive or relaunchable) - the
# keyboard cursor's index space, derived from the agent's own reply.
function Get-RenderedSessions {
    return @(Get-Sessions | Where-Object { $_.alive -or $_.relaunchable })
}

function Launch-Gui($errlog, [string[]]$extra) {
    $args = @('--window-width=100', '--window-height=30') + $extra
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $args -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

function Open-Chooser($g) {
    if (-not (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N)) { return [IntPtr]::Zero }
    return Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
}

function Wait-LogLine($path, $pattern, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $path) {
            $m = Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue
            if ($m) { return $m[-1].Line }
        }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $null
}

function Count-LogLines($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

# The oracle: "chooser roster: N session(s) not in any window", once per
# adopted local roster. The same N can repeat across opens, so the wait is on
# the line COUNT rising past $after, not on the line existing.
function OrphanPattern([int]$n) { return "chooser roster: $n session\(s\) not in any window" }
function Wait-OrphanLine($path, [int]$n, [int]$after, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Count-LogLines $path (OrphanPattern $n)) -gt $after) { return $true }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $false
}

function Send-ChooserKey($chooser, $filter, $key) {
    return Send-TestKeys -Window $chooser -Target $filter -Key $key
}

Write-Host 'T520 chooser orphan mark ("not in any window")'
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent', 'remote-test-client')
Reset-AgentState
Remove-LayoutManifest
New-TestDesktop | Out-Null

$errlog = Join-Path $env:TEMP "ghoztty-t520-stderr-$PID.log"
$clientlog = Join-Path $env:TEMP "ghoztty-t520-client-$PID.log"
Remove-Item $errlog, $clientlog -ErrorAction SilentlyContinue

try {
    # --- 1. Sessions held by panes are never marked ------------------------
    Write-Host ''
    Write-Host '1. every session is in a pane: the roster counts zero marks'
    Assert (Test-Path $ClientExe) 'remote-test-client exists in zig-out (zig build remote-test-client)'
    if (-not (Test-Path $ClientExe)) { Write-Host 'SETUP FAIL: build remote-test-client first'; exit 1 }

    $g = Launch-Gui $errlog @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    & $Exe +split --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 2
    $seeded = @(Get-Sessions)
    Assert ($seeded.Count -ge 2) "the agent owns the app's panes (found $($seeded.Count))"

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Assert ($filter -ne [IntPtr]::Zero) 'the chooser has its filter field'
    Assert ($null -ne (Wait-LogLine $errlog 'chooser roster: loaded (\d+) session' 8000)) 'the local roster loaded'
    # The oracle fires even at zero, so absence-of-mark is a measured claim:
    # both panes (post-split churn) are open here, nothing is left over.
    Assert (Wait-OrphanLine $errlog 0 0 6000) 'sessions held by open panes carry no mark (count 0 said out loud)'
    Send-ChooserKey $chooser $filter 'Escape' | Out-Null
    Start-Sleep -Milliseconds 600

    # --- 2. A session opened directly against the agent is marked ----------
    Write-Host ''
    Write-Host '2. a live session no pane holds gets counted'
    $pipe = "\\.\pipe\$(Get-LocalAgentPipeName)"
    $pc = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$ClientExe`" --pipe=$pipe --hold=1 > `"$clientlog`" 2>&1`""
    if (-not $pc.WaitForExit(25000)) { Stop-Process -Id $pc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800

    # The independent oracle: the agent itself, dialled directly, reports the
    # orphan alive with no viewer - the exact set the roster must mark.
    $loose = @(Get-Sessions | Where-Object { $_.alive -and -not $_.attached })
    Assert ($loose.Count -eq 1) "the agent reports exactly one live session with no viewer ($($loose.Count))"
    if ($loose.Count -lt 1) { Write-Host 'SETUP FAIL: direct OPEN left no orphan'; exit 1 }

    $zeroBase = Count-LogLines $errlog (OrphanPattern 0)
    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Assert (Wait-OrphanLine $errlog 1 0 8000) "the roster marks exactly that session 'not in any window'"

    # --- 3. Resuming the marked row clears its mark ------------------------
    Write-Host ''
    Write-Host '3. resuming the marked session takes its mark away'
    $rendered = @(Get-RenderedSessions)
    $targetIdx = -1
    for ($i = 0; $i -lt $rendered.Count; $i++) {
        if ($rendered[$i].id -eq $loose[0].id) { $targetIdx = $i; break }
    }
    Assert ($targetIdx -ge 0) "the marked row is rendered to resume (index $targetIdx of $($rendered.Count))"
    if ($targetIdx -lt 0) { Write-Host 'SETUP FAIL: orphan not in rendered list'; exit 1 }

    Send-ChooserKey $chooser $filter 'Right' | Out-Null
    for ($i = 0; $i -lt $targetIdx; $i++) { Send-ChooserKey $chooser $filter 'Down' | Out-Null }
    Start-Sleep -Milliseconds 400
    Send-ChooserKey $chooser $filter 'Return' | Out-Null
    $attach = Wait-LogLine $errlog 'resume session: attaching local session id=' 6000
    Assert ($null -ne $attach) 'Return resumes the marked row'
    $resumedId = ''
    if ($attach -and $attach -match 'id=([0-9a-fA-F]+)') { $resumedId = $Matches[1] }
    Assert ($resumedId -eq $loose[0].id) "the resumed session is the marked one ($resumedId vs $($loose[0].id))"
    Start-Sleep -Seconds 2
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'the chooser dismissed onto the resumed window'

    # The agent's own view agrees: the orphan now has a viewer.
    $row = @(Get-Sessions | Where-Object { $_.id -eq $loose[0].id })
    Assert ($row.Count -eq 1 -and $row[0].attached) 'the agent reports the resumed session ATTACHED'

    # Reopen: a fresh adopt recounts against the live window set, and the
    # resumed session now has a window, so the count is back at zero - a NEW
    # zero line, past the baseline from step 1.
    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens once more'
    Assert (Wait-OrphanLine $errlog 0 $zeroBase 8000) 'the resumed session dropped its mark (count back to 0)'
} finally {
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent', 'remote-test-client')
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
