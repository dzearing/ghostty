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
# Default target is the DEBUG build under test, like every other script in
# this directory. It used to default to zig-out-release, and that silently
# graded a stale binary: on 2026-07-21 this script reported 2 FAILURES on the
# T111b accept-pool guard while the actual build under test passed it — the
# release staging dir was a day old and predated the pool (the T49
# stale-binary lesson, re-learned). Pass -ExePath to grade a release build.
param(
    [string]$ExePath = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)
$ErrorActionPreference = 'Stop'
$repo = 'D:\git\ghoztty'
$exe = $ExePath
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: exe not found: $exe"; exit 1 }
# Loud staleness check: grading a binary older than the newest build in the
# repo is almost always an accident, and it reads as a product failure.
$newest = Get-ChildItem 'D:\git\ghoztty\zig-out*\bin\ghoztty.exe' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newest -and $newest.FullName -ne (Resolve-Path $exe).Path -and
    $newest.LastWriteTime -gt (Get-Item $exe).LastWriteTime) {
    Write-Host ("WARNING: grading $exe ($((Get-Item $exe).LastWriteTime)) but " +
        "$($newest.FullName) is NEWER ($($newest.LastWriteTime)) -- stale target?") -ForegroundColor Yellow
}
$env:GHOZTTY_PIPE_SUFFIX = '-ipcload'

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Kill only stale instances of THE EXE UNDER TEST — never the whole
# zig-out* family: a detached soak (T53b) runs from zig-out-release and
# must survive this script running against the debug exe. T248: the sibling
# agent and the debug session-layout manifest go too, or `--target=ipcload`
# focuses a PERSISTED pane from the previous run instead of a fresh shell.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
Reset-GhozttyTestState -Exe $exe -SettleMs 500 | Out-Null

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
    $out = & $exe +list 2>&1 | ForEach-Object { $_.ToString() } | Out-String
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

# T62: +read against a TINY-WRITE storm. The type-loop storm above is
# byte-heavy but write-light and never triggered the stall; the trigger
# is write COUNT — a cmd echo loop is one ConPTY write per line
# (~60k/s). Before the read-thread batching fix each write took its own
# renderer-mutex cycle and this +read starved 16-19s on the GUI thread
# (whole app frozen). Bound: 2s.
& $exe +split --target=ipcload --name=ipcload-echo --direction=down --shell=cmd `
    "--command=for /l %i in (0,0,1) do @echo tiny-write-storm %i zzzzzzzzzzzzzzzzzzzzzzzzzzzz" | Out-Null
Start-Sleep -Seconds 2
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$echoTail = & $exe +read --name=ipcload-echo --lines=5 | Out-String
$sw.Stop()
Assert ($echoTail -match 'tiny-write-storm') "echo-storm pane +read returns content (len $($echoTail.Length))"
Assert ($sw.ElapsedMilliseconds -lt 2000) "echo-storm +read latency $($sw.ElapsedMilliseconds)ms < 2000ms (T62)"

# T111b: the server must keep ACCEPTING while a request is outstanding.
# With a single pipe instance it could not: one client holding the instance
# (or one slow handler) made every other client exhaust its PIPE_BUSY retries
# and print "No running Ghoztty instance found." — a running app reported as
# absent. Measured before the instance pool: 9190ms then that error, on an
# app that was otherwise completely idle. Simulated here by a raw pipe client
# that connects and never sends a request, which parks a listener in its
# request read exactly like a slow handler parks one on the GUI thread.
$pipeName = "ghoztty$($env:GHOZTTY_PIPE_SUFFIX)-$env:USERNAME"
$hog = New-Object System.IO.Pipes.NamedPipeClientStream(
    '.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
$hogOk = $true
try { $hog.Connect(5000) } catch { $hogOk = $false }
Assert $hogOk "raw client can occupy one pipe instance (name: $pipeName)"
if ($hogOk) {
    $swHog = [System.Diagnostics.Stopwatch]::StartNew()
    & $exe +list | Out-Null
    $hogCode = $LASTEXITCODE
    $swHog.Stop()
    $hog.Dispose()
    Assert ($hogCode -eq 0) "+list still answers while a client occupies an instance (exit $hogCode)"
    Assert ($swHog.ElapsedMilliseconds -lt 5000) (
        "+list latency with an instance occupied $($swHog.ElapsedMilliseconds)ms < 5000ms " +
        "(pre-fix: ~9190ms then 'No running Ghoztty instance found.')")
}

# Teardown — asserted, not just performed: closing a window with noisy
# panes used to hang the GUI thread forever in Exec.threadExit's
# read_thread.join() when the one-shot CancelIoEx missed (the reader was
# parsing the kill-flush burst, not blocked in ReadFile). Observed: +close
# stuck 9+ minutes with the app Not Responding.
$swClose = [System.Diagnostics.Stopwatch]::StartNew()
& $exe +close --target=ipcload | Out-Null
$swClose.Stop()
Assert ($swClose.ElapsedMilliseconds -lt 10000) "+close of the storm window returns in $($swClose.ElapsedMilliseconds)ms < 10s"
Start-Sleep -Seconds 1
# cleanslate-exempt: spares the CLI invocations, which the shared kill would take
Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -eq $exe -and $_.CommandLine -notmatch '\+' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) / $script:pass passed" -ForegroundColor Red; exit 1 }
