# Upgrade the installed Windows release Ghoztty in place and resume work.
#
# Designed to be launched DETACHED from a Claude Code session running inside
# the very Ghoztty instance being upgraded (killing ghoztty.exe kills the
# session's shell and Claude with it, so nothing in that process tree can do
# the swap). Launch it in its own console and end the turn:
#
#   Start-Process powershell -WindowStyle Hidden -ArgumentList `
#     '-NoProfile','-ExecutionPolicy','Bypass','-File',
#     'D:\git\ghoztty\scripts\upgrade-ghoztty-windows.ps1'
#
# Sequence: wait -> kill release ghoztty processes (install dir only; debug
# zig-out instances untouched) -> swap exe + share\ from the staging prefix
# -> relaunch a window that resumes the most recent Claude session in the
# repo. Every step is appended to %TEMP%\ghoztty-upgrade.log so the resumed
# session can verify what happened.
param(
    [string]$Staging = 'D:\git\ghoztty\zig-out-release',
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Ghoztty",
    [string]$WorkingDirectory = 'D:\git\ghoztty',
    # Runs in the relaunched window; --continue resumes the most recent
    # Claude session in WorkingDirectory (i.e. the one this kill orphaned).
    # --continue restores the conversation, NOT the dead process's CLI
    # flags, so launch-mode flags like --dangerously-skip-permissions must
    # be repeated here or the resumed session drops back to prompting.
    # The trailing prompt is REQUIRED: --continue alone restores the
    # conversation and then sits idle waiting for input (observed
    # 2026-07-14 -> "you stopped working"); the starter prompt re-enters
    # the go.md task loop immediately.
    [string]$ResumeCommand = 'claude --dangerously-skip-permissions --continue "read go.md and go"',
    [int]$DelaySeconds = 3,
    [switch]$NoResume
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP 'ghoztty-upgrade.log'
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content $log }

Log "=== upgrade start (staging=$Staging)"

$newExe = Join-Path $Staging 'bin\ghoztty.exe'
$oldExe = Join-Path $InstallDir 'ghoztty.exe'
if (-not (Test-Path $newExe)) { Log "ABORT: staging exe not found: $newExe"; exit 1 }
if (-not (Test-Path $oldExe)) { Log "ABORT: installed exe not found: $oldExe"; exit 1 }

# Let the launching Claude turn finish so the session transcript is flushed
# before its terminal is killed.
Start-Sleep -Seconds $DelaySeconds

# Kill only release instances (running from the install dir). Debug/test
# instances under zig-out keep running.
$victims = @(Get-Process ghoztty -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$InstallDir*" })
Log "killing $($victims.Count) release ghoztty process(es): $($victims.Id -join ', ')"
$victims | Stop-Process -Force -ErrorAction SilentlyContinue

# Wait for the exe to unlock, then swap. Keep one .bak for rollback.
$swapped = $false
foreach ($try in 1..20) {
    try {
        Copy-Item $oldExe "$oldExe.bak" -Force -ErrorAction Stop
        Copy-Item $newExe $oldExe -Force -ErrorAction Stop
        $swapped = $true
        break
    } catch {
        Log "swap attempt ${try}: $($_.Exception.Message)"
        Start-Sleep -Milliseconds 500
    }
}
if (-not $swapped) { Log 'ABORT: could not replace exe after 20 tries'; exit 1 }
Log 'exe swapped'

# Keep the matching PDB next to the installed exe so freeze/crash dumps are
# symbolizable (T48). Release builds must use -Dstrip=false to produce one.
$newPdb = Join-Path $Staging 'bin\ghoztty.pdb'
if (Test-Path $newPdb) {
    Copy-Item $newPdb (Join-Path $InstallDir 'ghoztty.pdb') -Force
    Log 'pdb copied alongside exe'
} else {
    Log 'WARNING: no ghoztty.pdb in staging (built with strip?); dumps from this build will be unsymbolized'
}

$stagingShare = Join-Path $Staging 'share'
if (Test-Path $stagingShare) {
    robocopy $stagingShare (Join-Path $InstallDir 'share') /MIR /NFL /NDL /NJH /NJS | Out-Null
    Log "share\ mirrored (robocopy exit $LASTEXITCODE)"
} else {
    Log 'no share\ in staging; kept existing'
}

if ($NoResume) { Log 'UPGRADE OK (no-resume)'; exit 0 }

# Auto-launches the freshly installed exe (the pipe owner died with the kill).
& $oldExe +new-window --target=main "--working-directory=$WorkingDirectory" "--command=$ResumeCommand" 2>&1 |
    ForEach-Object { Log "relaunch: $_" }
Log "UPGRADE OK (relaunched, resume: $ResumeCommand)"
exit 0
