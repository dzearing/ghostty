# IPC-under-load acceptance (T53a finding): CLI verbs must keep answering
# while a pane streams heavily. Regression guard for the WM_APP_WAKEUP
# message-queue flood — before the coalescing fix, one posted wakeup per
# surface-mailbox push filled the GUI thread's 10,000-entry posted-message
# quota under an echo storm and EVERY PostMessageW failed: +list answered
# {"success":false,"error":"server not ready"} for the whole storm
# (40/40 failures observed), deferred SetFocus and hero snapshots dropped.
#
# Fully IPC-driven (no keyboard injection). Isolated pipe suffix, only
# touches ghoztty processes from this repo's zig-out*.
param(
    [string]$ExePath = 'D:\git\ghoztty\zig-out-release\bin\ghoztty.exe'
)
$ErrorActionPreference = 'Stop'
$repo = 'D:\git\ghoztty'
$exe = $ExePath
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: exe not found: $exe"; exit 1 }
$env:GHOZTTY_PIPE_SUFFIX = '-ipcload'

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') -and $_.CommandLine -notmatch '\+' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

& $exe +new-window --target=ipcload --shell=cmd | Out-Null
Start-Sleep -Seconds 3
& $exe +list | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'SETUP FAIL: +list before load'; exit 1 }

# Storm pane: an endless `type` loop over a 2MB file. A bounded echo loop
# is useless here — cmd pushes 600k echo lines through ConPTY in <10s, so
# it would end before the hammer. The type loop streams until teardown.
$assetDir = Join-Path $env:TEMP 'ghoztty-soak'
New-Item -ItemType Directory -Force $assetDir | Out-Null
$stormFile = Join-Path $assetDir 'storm.txt'
if (-not (Test-Path $stormFile) -or (Get-Item $stormFile).Length -lt 2000000) {
    $sb = [System.Text.StringBuilder]::new()
    1..25000 | ForEach-Object { [void]$sb.AppendLine("storm-payload $_ " + ('z' * 60)) }
    [System.IO.File]::WriteAllText($stormFile, $sb.ToString())
}
& $exe +split --target=ipcload --name=ipcload-storm --direction=right --shell=cmd `
    "--command=for /l %i in (1,1,2000000) do @type $stormFile" | Out-Null
Start-Sleep -Seconds 1

# Resolve the idle (original) pane's auto-registered name now: the leaf
# that is NOT the storm pane. It is the probe target later (probes must
# NOT go to the window target -- that routes to the active pane, which is
# the storm pane right after the split).
$leaves = @()
function Walk($node) {
    if ($null -ne $node.terminal) { $script:leaves += $node.terminal }
    if ($null -ne $node.left) { Walk $node.left; Walk $node.right }
}
(& $exe +list --json | ConvertFrom-Json).data.windows |
    Where-Object { $_.target -eq 'ipcload' } |
    ForEach-Object { Walk $_.tabs[0].splits }
$probePane = ($leaves | Where-Object { $_.name -ne 'ipcload-storm' } | Select-Object -First 1).name
if (-not $probePane) { Write-Host 'SETUP FAIL: probe pane not resolved'; exit 1 }

# Hammer +list while the storm runs.
$ok = 0
$bad = 0
$firstErr = ''
1..40 | ForEach-Object {
    $out = & $exe +list 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { $ok++ }
    else { $bad++; if (-not $firstErr) { $firstErr = ($out.Trim() -split "`n")[0] } }
    Start-Sleep -Milliseconds 150
}
Assert ($bad -eq 0) "+list answers under storm: $ok/40 ok$(if ($firstErr) { " (first err: $firstErr)" })"

# The storm must still be running for the hammer to have meant anything,
# and +read of a heavily-streaming pane must return content (an empty
# read here is its own bug).
$tail = & $exe +read --name=ipcload-storm --lines=5 | Out-String
Assert ($tail -match 'storm-payload') "storm still streaming and +read returns content mid-storm (len $($tail.Length))"

# send-keys + read round-trip mid-storm, into the IDLE pane by name.
$sendOk = 0
1..5 | ForEach-Object {
    & $exe +send-keys --target=$probePane "echo LOADPROBE_$_" Enter 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $sendOk++ }
    Start-Sleep -Milliseconds 200
}
Assert ($sendOk -eq 5) "+send-keys answers under storm: $sendOk/5 ok"
Start-Sleep -Milliseconds 800
$probeTail = & $exe +read --name=$probePane --lines=10 | Out-String
Assert ($probeTail -match 'LOADPROBE_5') 'probe echoes executed in the idle pane'

# Teardown.
& $exe +close --target=ipcload | Out-Null
Start-Sleep -Seconds 1
Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -eq $exe -and $_.CommandLine -notmatch '\+' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) / $script:pass passed" -ForegroundColor Red; exit 1 }
