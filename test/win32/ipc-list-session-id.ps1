# T332 acceptance: +list --json reports which agent session a pane is bound to.
#
#   powershell -NoProfile -File test\win32\ipc-list-session-id.ps1
#
# Covers: a session-persistence pane's leaf carries a `session_id` that matches
# an alive+attached row in `+sessions --json` (the pane<->session join, which
# used to live only inside the app); a viewer leaf omits the field entirely
# (additive - old parsers and non-persistent panes see the shape they always
# did). Only ever touches ghoztty processes running from the repo zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-t332-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't332')

# T1240: the CLI runs ON THE TEST DESKTOP, not on the user's. `+new-window` is
# the one verb that auto-launches the app, and the window it spawns lands on the
# desktop of the process that spawned it - so this script used to throw a window
# across whatever the user was reading. `Invoke-OnTestDesktop` is `& $Exe` with a
# desktop named in the STARTUPINFO; nothing else about the assertions changed.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}

# Every CLI call in this file goes through here. It returns { ExitCode, Output,
# Pid, TimedOut }; the child's stdout and stderr are captured to a file by the
# harness, which is also what the old `cmd /c ... > file` dance was for - a
# GUI-subsystem exe writes zero bytes to a PowerShell `>` redirect (T245).
function Ghoz([string[]]$GhozArgs) {
    return Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
}

function Get-ListJson {
    try { (Ghoz @('+list', '--json')).Output | ConvertFrom-Json } catch { $null }
}

function Get-SessionsJson {
    try { (Ghoz @('+sessions', '--json')).Output | ConvertFrom-Json } catch { $null }
}

# Flatten a splits node into its terminal-leaf objects.
function Get-Leaves($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    $out = @()
    $out += Get-Leaves $node.left
    $out += Get-Leaves $node.right
    return $out
}

function Get-WindowLeaves([string]$Target) {
    $json = Get-ListJson
    if ($null -eq $json) { return @() }
    $win = $json.data.windows | Where-Object { $_.target -eq $Target }
    if ($null -eq $win) { return @() }
    $out = @()
    foreach ($tab in $win.tabs) { $out += Get-Leaves $tab.splits }
    return $out
}

$transcript = Join-Path $env:TEMP 'ghoztty-ipc-t332-last.log'

$td = New-TestDesktop

& {

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== 1: a persistent pane's leaf reports its agent session id"
$r = Ghoz @('+new-window', '--target=t332w')
Assert "new-window exit 0" ($r.ExitCode -eq 0)

# Poll: the id is published once the app<->agent OPEN handshake resolves, which
# on a cold agent spawn (Defender scanning the fresh exe) can take a while.
$sid = $null
$deadline = (Get-Date).AddSeconds(30)
do {
    $leaves = Get-WindowLeaves 't332w'
    $term = $leaves | Where-Object { $_.type -eq 'terminal' } | Select-Object -First 1
    if ($term -and $term.PSObject.Properties['session_id'] -and $term.session_id) {
        $sid = $term.session_id
        break
    }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
Assert-GhozttyIsolated -Exe $Exe
Assert "terminal leaf carries a non-empty session_id" ($null -ne $sid -and $sid.Length -gt 0)

"== 2: the id joins against +sessions --json (alive, attached)"
$row = $null
if ($sid) {
    $sessions = Get-SessionsJson
    $row = $sessions | Where-Object { $_.id -eq $sid }
}
Assert "+sessions has a row with that id" ($null -ne $row)
Assert "row is alive" ($row -and $row.alive -eq $true)
Assert "row is attached" ($row -and $row.attached -eq $true)

"== 3: a viewer leaf omits the field"
$r = Ghoz @('+split', '--target=t332w', '--name=t332view', '--view=D:\git\ghoztty\README.md')
Assert "split --view exit 0" ($r.ExitCode -eq 0)
$viewer = $null
$deadline = (Get-Date).AddSeconds(15)
do {
    $leaves = Get-WindowLeaves 't332w'
    $viewer = $leaves | Where-Object { $_.type -eq 'viewer' } | Select-Object -First 1
    if ($viewer) { break }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
Assert "viewer pane listed" ($null -ne $viewer)
Assert "viewer has no session_id property" (
    $viewer -and ($null -eq $viewer.PSObject.Properties['session_id']))

"== teardown"
[void](Ghoz @('+close', '--target=t332w'))
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

} 2>&1 | Tee-Object -FilePath $transcript

""
if ($script:failures -eq 0) {
    "T332 ACCEPTANCE: ALL PASS"
    exit 0
} else {
    $trailer = "T332 ACCEPTANCE: $script:failures FAILURE(S) - details: $transcript"
    Add-Content $transcript $trailer
    $trailer
    exit 1
}
