# T470 measurement: what does a table of dead tombstones actually cost the agent?
#
# The task's own Details asked for this number before the fix, because the
# arithmetic (256 x 2 MB) is an upper bound on RESERVATION, not necessarily on
# what Windows charges: a committed page nobody has touched costs address space
# and commit charge, not working set. So this measures both, on both builds.
#
#   -Agent <path>   the ghoztty-agent.exe to measure (required)
#   -Tombstones <n> how many dead sessions to seed (default 256 = max_dead_sessions)
#
# Prints one line: `<label> ws=<MB> private=<MB>`. Nothing is asserted here; the
# committed regression test is the byte-counted unit test in session.zig.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Agent,
    [int]$Tombstones = 256,
    [string]$Label = 'agent'
)
$ErrorActionPreference = 'Stop'

$root = Join-Path $env:TEMP ("t470-measure-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$agentDir = Join-Path $root 'ghoztty\local-agent-debug'
New-Item -ItemType Directory -Force $agentDir | Out-Null

# Same record shape the T278 fixture seeds: a restored persistent pane's leftover.
$recs = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $Tombstones; $i++) {
    $id = ('{0:x8}' -f ($i + 1)) + 'deadbeefcafef00d0000000000000000'.Substring(0, 24)
    $recs.Add('{"id":"' + $id + '","cwd":"C:\\Users","pinned":true,"created_ms":1785863794903,"unclaimed_restarts":0}')
}
[System.IO.File]::WriteAllText(
    (Join-Path $agentDir 'sessions.json'),
    '{"version":1,"sessions":[' + ($recs -join ',') + ']}')

# A private pipe name and an explicit roster file, so this never goes anywhere
# near the user's live agent or its state directory.
$pipe = '\\.\pipe\ghoztty-t470m-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$old = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $root
try {
    $p = Start-Process -FilePath $Agent -PassThru -WindowStyle Hidden -ArgumentList @(
        '--listen-pipe', $pipe,
        '--headless',
        '--sessions-file', (Join-Path $agentDir 'sessions.json'))
    $null = $p.Handle
    # Give it time to read sessions.json and materialize the whole table.
    Start-Sleep -Seconds 6
    $p.Refresh()
    $ws = [math]::Round($p.WorkingSet64 / 1MB, 1)
    $pm = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
    "$Label tombstones=$Tombstones ws=${ws}MB private=${pm}MB"
    $p.Kill()
    $p.WaitForExit(5000) | Out-Null
} finally {
    $env:LOCALAPPDATA = $old
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
