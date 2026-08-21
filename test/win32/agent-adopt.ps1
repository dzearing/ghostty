# Standalone-install adoption acceptance (T549): a consolidated local agent
# that finds a standalone 'Ghoztty Agent' install adopts it - sharing marked
# on, the standalone agent stopped only once idle, the uninstall run under the
# deny-terminate shield, and the contested Run-key value restored.
#
#   powershell -NoProfile -File test\win32\agent-adopt.ps1
#
# Covers: debug gating (no adoption without BOTH env overrides); the full
# adoption flow against a fake install dir + fake uninstall command (sharing
# marked, busy standalone left alone, idle standalone terminated, uninstall
# invoked exactly once, the shield refusing a Stop-Process against the
# adopting agent mid-uninstall, the deleted Run value restored, adoption.json
# done); the done short-circuit on restart; and the GHOSTTY_ADOPT_DISABLE
# kill switch.
#
# Hermetic: GHOZTTY_AGENT_INSTANCE forks the single-instance guard, the state
# dir + fake install dir live under $env:TEMP (no spaces - the uninstall
# override is a raw CreateProcessW line), GHOSTTY_RELAY_ENV points at a
# nonexistent scratch path so the marked-on sharing uplink can never dial the
# real relay, and the Run value name is PID-scoped so the real GhozttyAgent
# entry is never touched. The "standalone agent" is a copied powershell.exe
# renamed ghoztty-agent.exe whose cmd child simulates a live session (the
# busy walk ignores ConPTY plumbing precisely so console stand-ins work).
param(
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:passes = 0
$script:failures = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t549-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$stateDir = Join-Path $tmp 'agent-state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$fakeDir = Join-Path $tmp 'standalone'
$portFile = Join-Path $stateDir 'port.json'
$sessFile = Join-Path $stateDir 'sessions.json'
$sharingFile = Join-Path $stateDir 'sharing.json'
$adoptFile = Join-Path $stateDir 'adoption.json'
$uninstLog = Join-Path $tmp 'uninstall.log'
$fakeUninstall = Join-Path $tmp 'fake-uninstall.cmd'
$pipe = "\\.\pipe\ghoztty-agent-t549-$PID"
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = "GhozttyAgentT549-$PID"
$preRunValue = '"C:\app\ghoztty-agent.exe" "--listen-pipe=app-t549"'

if (-not (Test-Path $AgentExe)) {
    "SKIP whole run: $AgentExe not built (zig build agent first)"
    Write-TestVerdict -Label 'T549 AGENT ADOPT' -Pass 0 -Fail 0 -Skipped 1
}

function Stop-TestProcs {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { ($_.CommandLine -like '*t549*') -or ($_.ExecutablePath -like '*ghoztty-t549*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
}

function Start-TestAgent($outFile, $errFile) {
    $p = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList "--listen-pipe=$pipe", "--port-file=$portFile", "--sessions-file=$sessFile", '--headless'
    $null = $p.Handle   # cache before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    return $p
}

function Read-Shared($file) {
    if (-not (Test-Path $file)) { return '' }
    try {
        $fs = [System.IO.FileStream]::new($file, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Wait-ForText($file, $pattern, $timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-Shared $file) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function New-FakeStandalone {
    New-Item -ItemType Directory -Force $fakeDir | Out-Null
    Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        (Join-Path $fakeDir 'ghoztty-agent.exe') -Force
}

"== 0: fake standalone install + pre-seeded app-owned Run value"
Stop-TestProcs
New-FakeStandalone
Set-ItemProperty -Path $runKey -Name $runValueName -Value $preRunValue
Assert 'fake install dir exists' (Test-Path (Join-Path $fakeDir 'ghoztty-agent.exe'))

$env:GHOZTTY_AGENT_INSTANCE = "t549$PID"
$env:GHOSTTY_RELAY_ENV = Join-Path $tmp 'no-such-relay.env'
$env:GHOSTTY_ADOPT_INSTALL_DIR = $fakeDir
$env:GHOSTTY_ADOPT_RUNKEY_NAME = $runValueName
$env:GHOSTTY_ADOPT_INTERVAL_MS = '1000'
try {
    "== 1: debug gate - install dir override alone is NOT enough to adopt"
    # No GHOSTTY_ADOPT_UNINSTALL_CMD: a debug agent must refuse to act.
    $a1 = Start-TestAgent "$tmp\a1.out" "$tmp\a1.err"
    Assert 'gated agent came up' (Wait-ForText $portFile 'pipe' 15)
    Start-Sleep -Seconds 3
    Assert 'no adoption without both overrides' ((Read-Shared "$tmp\a1.err") -notmatch 'adoption')
    Assert 'sharing.json untouched by the gated agent' (-not (Test-Path $sharingFile))
    Stop-TestProcs

    "== 2: adoption - sharing marked, idle-stop honored, shielded uninstall, Run value restored"
    # The fake standalone: busy for ~10s (a cmd 'session' pinging), then idle
    # (only its conhost left, which the busy walk must ignore).
    $fake = Start-Process -FilePath (Join-Path $fakeDir 'ghoztty-agent.exe') -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-Command', "& cmd /d /c 'ping -n 10 127.0.0.1 > nul'; Start-Sleep 600"
    $null = $fake.Handle
    Start-Sleep -Seconds 2
    $fakeKids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($fake.Id)" |
        Where-Object { $_.Name -ne 'conhost.exe' })
    Assert 'positive control: fake standalone has a live session child' ($fakeKids.Count -ge 1)

    Remove-Item $portFile -ErrorAction SilentlyContinue
    $env:GHOSTTY_ADOPT_UNINSTALL_CMD = "$env:SystemRoot\System32\cmd.exe /d /c $fakeUninstall"
    $a2 = Start-TestAgent "$tmp\a2.out" "$tmp\a2.err"
    # The fake uninstall: records the run, tries to kill the adopting agent
    # (the shield must refuse it - this is exactly what the MSI's KillAgentCA
    # does), deletes the Run value and the install dir like the real MSI.
    @(
        '@echo off',
        "echo ran >> $uninstLog",
        "powershell -NoProfile -Command `"try { Stop-Process -Id $($a2.Id) -Force -ErrorAction Stop; 'kill-ok' } catch { 'kill-denied' }`" >> $uninstLog",
        "reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v $runValueName /f > nul 2>&1",
        "rmdir /s /q $fakeDir",
        'exit /b 0'
    ) | Set-Content -Path $fakeUninstall -Encoding ascii

    Assert 'adopting agent came up' (Wait-ForText $portFile 'pipe' 15)
    Assert 'adoption announced' (Wait-ForText "$tmp\a2.err" 'adopting \(T549\)' 15)
    Assert 'sharing marked enabled' (Wait-ForText "$tmp\a2.err" 'sharing marked enabled' 15)
    Assert 'sharing.json says enabled' ((Read-Shared $sharingFile) -match '"enabled":true')
    Assert 'busy standalone put adoption into waiting' (Wait-ForText "$tmp\a2.err" 'waiting for idle' 20)
    Assert 'standalone NOT stopped while busy' (-not $fake.HasExited)

    # The cmd 'session' drains (~10s), then 3 idle polls at 1s land the stop.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $fake.HasExited) { Start-Sleep -Milliseconds 500 }
    Assert 'idle standalone was stopped' $fake.HasExited
    Assert 'stop was announced' (Wait-ForText "$tmp\a2.err" 'idle; stopped it' 10)

    Assert 'uninstall override ran' (Wait-ForText $uninstLog 'ran' 30)
    Assert 'adoption completed' (Wait-ForText "$tmp\a2.err" 'adoption complete' 30)
    Assert 'uninstall ran exactly once' (([regex]::Matches((Read-Shared $uninstLog), 'ran')).Count -eq 1)
    Assert 'shield refused the mid-uninstall kill' ((Read-Shared $uninstLog) -match 'kill-denied')
    Assert 'adopting agent survived its own uninstall step' (-not $a2.HasExited)
    Assert 'fake install dir removed by the uninstall' (-not (Test-Path $fakeDir))
    $restored = (Get-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue).$runValueName
    Assert 'deleted Run value was restored verbatim' ($restored -eq $preRunValue)
    Assert 'restore was announced' ((Read-Shared "$tmp\a2.err") -match 'restored the')
    Assert 'adoption.json records done' ((Read-Shared $adoptFile) -match '"done":true')
    Stop-TestProcs

    "== 3: restart - done short-circuits, no second adoption"
    Remove-Item $portFile -ErrorAction SilentlyContinue
    $a3 = Start-TestAgent "$tmp\a3.out" "$tmp\a3.err"
    Assert 'post-adoption agent came up' (Wait-ForText $portFile 'pipe' 15)
    Start-Sleep -Seconds 3
    Assert 'no re-adoption after done' ((Read-Shared "$tmp\a3.err") -notmatch 'adopting')
    Stop-TestProcs

    "== 4: kill switch - GHOSTTY_ADOPT_DISABLE=1 stops everything"
    Remove-Item $adoptFile -ErrorAction SilentlyContinue
    Remove-Item $portFile -ErrorAction SilentlyContinue
    New-FakeStandalone
    $env:GHOSTTY_ADOPT_DISABLE = '1'
    $a4 = Start-TestAgent "$tmp\a4.out" "$tmp\a4.err"
    Assert 'disabled agent came up' (Wait-ForText $portFile 'pipe' 15)
    Start-Sleep -Seconds 3
    Assert 'kill switch suppresses adoption' ((Read-Shared "$tmp\a4.err") -notmatch 'adoption|adopting')
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-TestProcs
    Remove-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue
    foreach ($n in 'GHOZTTY_AGENT_INSTANCE','GHOSTTY_RELAY_ENV','GHOSTTY_ADOPT_INSTALL_DIR',
                   'GHOSTTY_ADOPT_RUNKEY_NAME','GHOSTTY_ADOPT_INTERVAL_MS',
                   'GHOSTTY_ADOPT_UNINSTALL_CMD','GHOSTTY_ADOPT_DISABLE') {
        Remove-Item "env:$n" -ErrorAction SilentlyContinue
    }
}

# MinPass = the full-run assertion count: an abort mid-run must never score a
# truncated run as ALL PASS.
Write-TestVerdict -Label 'T549 AGENT ADOPT' -Pass $script:passes -Fail $script:failures -MinPass 26
