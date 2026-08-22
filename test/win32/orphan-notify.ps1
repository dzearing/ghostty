# Long-unattached session NOTIFICATION acceptance (tracker T534).
#
# The agent keeps a pinned live session forever once no window shows it (D18:
# never silently reap). Discovery is the app's job: a periodic check reads the
# local roster, and a session continuously unattached past a threshold earns
# ONE tray balloon naming it; clicking it opens the chooser (T520's badge +
# Resume/Kill), and ignoring it IS "Keep" — a per-episode stamp file keeps the
# episode quiet. This script drives the policy against a REAL agent + app,
# with the debug-only env seams shrinking "24 hours" to seconds:
#
#   1. NEGATIVE CONTROL: sessions held by panes produce NO notification even
#      after several check ticks past the threshold.
#   2. A session opened directly against the agent (remote-test-client --hold,
#      the T520 shape) and left unattached past the threshold IS announced —
#      the oracle line names exactly that session — and the agent's own
#      `+sessions --json` independently reports its `unattached_since` clock.
#   3. KEEP: further check ticks do NOT re-announce the stamped episode, and
#      the stamp file records it.
#   4. RESUME resets the clock: resuming the session from the chooser makes
#      the agent report `unattached_since: null` (a later orphan episode would
#      start a fresh clock — the per-episode re-arm is unit-tested).
#
# WHY A LOG LINE IS THE ORACLE. On the background test desktop there is no
# notification area, so the balloon itself cannot be read back; the app
# therefore says the DECISION out loud ("orphan notify: session=...") BEFORE
# asking the shell to show anything, and this script asserts the decision plus
# the independent agent-side clock.
#
#   powershell -NoProfile -File test\win32\orphan-notify.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$ClientExe = 'D:\git\ghoztty\zig-out\bin\remote-test-client.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
# T359: remote-test-client is an on-demand build target, so a clean tree does
# not have it. Resolve it here - and build it if it is missing - before any
# isolation or launch, since this shells out to zig.
. (Join-Path $PSScriptRoot 'lib\TestClient.ps1')
$ClientExe = Resolve-RemoteTestClient -ClientExe $ClientExe -Repo $repo

# Isolate the app's IPC endpoint; the debug agent is per-user (setup kills the
# repo's agent, so the app starts a fresh one this run owns).
$env:GHOZTTY_PIPE_SUFFIX = "-t534$PID"
# The debug-only policy seams: notify after 4s continuously unattached, check
# every 2s, and (never reached here) re-notify the same episode after 1h.
$env:GHOZTTY_ORPHAN_NOTIFY_AFTER_MS = '4000'
$env:GHOZTTY_ORPHAN_CHECK_MS = '2000'
$env:GHOZTTY_ORPHAN_RENOTIFY_MS = '3600000'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PipeBridge.ps1')  # Get-LocalAgentPipeName

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

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

$stampFile = Join-Path $env:LOCALAPPDATA 'ghoztty\orphan-notify-debug.json'

# `ghoztty +verb > file` writes zero bytes from PowerShell (T245) - capture
# through a pipe instead.
function Get-Sessions {
    $out = (& $Exe +sessions --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return @() }
    try { $j = $out | ConvertFrom-Json } catch { return @() }
    if ($null -eq $j) { return @() }
    return @($j)
}

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

function Count-NotifyLines($path) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Select-String -Path $path -Pattern 'orphan notify: session=' -ErrorAction SilentlyContinue).Count
}

function Wait-NotifyLine($path, [int]$after, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Count-NotifyLines $path) -gt $after) {
            return @(Select-String -Path $path -Pattern 'orphan notify: session=' -ErrorAction SilentlyContinue)[-1].Line
        }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $null
}

Write-Host 'T534 long-unattached session notification'
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent', 'remote-test-client')
Reset-AgentState
Remove-Item $stampFile -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json') -ErrorAction SilentlyContinue
New-TestDesktop | Out-Null

$errlog = Join-Path $env:TEMP "ghoztty-t534-stderr-$PID.log"
$clientlog = Join-Path $env:TEMP "ghoztty-t534-client-$PID.log"
Remove-Item $errlog, $clientlog -ErrorAction SilentlyContinue

try {
    # --- 1. Attached sessions never notify (negative control) --------------
    Write-Host ''
    Write-Host '1. sessions held by panes stay quiet past the threshold'
    $haveClient = ($ClientExe -and (Test-Path $ClientExe))
    Assert $haveClient "remote-test-client available ($(Get-RemoteTestClientBuildCommand))"
    if (-not $haveClient) { Write-Host "SETUP FAIL: $(Get-RemoteTestClientBuildCommand)"; exit 1 }

    $g = Launch-Gui $errlog @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    # Threshold (4s) + several check ticks (2s each) with only pane-held
    # sessions: the check runs, and the decision must be "say nothing".
    Start-Sleep -Seconds 10
    Assert ((Count-NotifyLines $errlog) -eq 0) 'no notification for sessions open in panes'

    # --- 2. A long-unattached session is announced -------------------------
    Write-Host ''
    Write-Host '2. a session nobody has looked at past the threshold is announced'
    $pipe = "\\.\pipe\$(Get-LocalAgentPipeName)"
    $pc = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$ClientExe`" --pipe=$pipe --hold=1 > `"$clientlog`" 2>&1`""
    if (-not $pc.WaitForExit(25000)) { Stop-Process -Id $pc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800

    $loose = @(Get-Sessions | Where-Object { $_.alive -and -not $_.attached })
    Assert ($loose.Count -eq 1) "the agent reports exactly one live session with no viewer ($($loose.Count))"
    if ($loose.Count -lt 1) { Write-Host 'SETUP FAIL: direct OPEN left no orphan'; exit 1 }
    # The agent's additive clock is the independent oracle: set while orphaned.
    Assert ($null -ne $loose[0].unattached_since) 'the agent reports unattached_since for the orphan'

    # Threshold 4s + check tick 2s: the announcement lands within ~10s.
    $line = Wait-NotifyLine $errlog 0 15000
    Assert ($null -ne $line) 'the app announces the long-unattached session'
    $announced = ''
    if ($line -and $line -match 'session=([0-9a-fA-F]+)') { $announced = $Matches[1] }
    Assert ($announced -eq $loose[0].id) "the announcement names the orphan ($announced vs $($loose[0].id))"

    # --- 3. Keep: the stamped episode stays quiet --------------------------
    Write-Host ''
    Write-Host '3. ignoring the notification suppresses re-announcement (Keep)'
    $count = Count-NotifyLines $errlog
    Start-Sleep -Seconds 8  # four more check ticks
    Assert ((Count-NotifyLines $errlog) -eq $count) 'no re-announcement of the stamped episode'
    $stampOk = $false
    if (Test-Path $stampFile) {
        try {
            $stamps = (Get-Content $stampFile -Raw | ConvertFrom-Json).stamps
            $stampOk = @($stamps | Where-Object { $_.id -eq $loose[0].id }).Count -eq 1
        } catch {}
    }
    Assert $stampOk 'the stamp file records the announced episode'

    # --- 4. Resume resets the unattached clock -----------------------------
    Write-Host ''
    Write-Host '4. resuming the session clears its clock (attach resets it)'
    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Assert ($filter -ne [IntPtr]::Zero) 'the chooser has its filter field'

    $rendered = @(Get-RenderedSessions)
    $targetIdx = -1
    for ($i = 0; $i -lt $rendered.Count; $i++) {
        if ($rendered[$i].id -eq $loose[0].id) { $targetIdx = $i; break }
    }
    Assert ($targetIdx -ge 0) "the orphan is rendered to resume (index $targetIdx of $($rendered.Count))"
    if ($targetIdx -lt 0) { Write-Host 'SETUP FAIL: orphan not in rendered list'; exit 1 }

    Send-TestKeys -Window $chooser -Target $filter -Key 'Right' | Out-Null
    for ($i = 0; $i -lt $targetIdx; $i++) { Send-TestKeys -Window $chooser -Target $filter -Key 'Down' | Out-Null }
    Start-Sleep -Milliseconds 400
    Send-TestKeys -Window $chooser -Target $filter -Key 'Return' | Out-Null
    Start-Sleep -Seconds 3

    $row = @(Get-Sessions | Where-Object { $_.id -eq $loose[0].id })
    Assert ($row.Count -eq 1 -and $row[0].attached) 'the agent reports the resumed session ATTACHED'
    Assert ($row.Count -eq 1 -and $null -eq $row[0].unattached_since) 'the attach reset unattached_since to null'
} finally {
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent', 'remote-test-client')
    Remove-Item $stampFile -ErrorAction SilentlyContinue
    Remove-TestDesktop
}

# A clean green run stamps the covered files (T783); a red run leaves the
# stamp alone on purpose - red must stay due.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard orphan-notify -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
