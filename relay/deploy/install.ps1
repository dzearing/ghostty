# ghoztty-agent installer — download, enroll (if needed), autostart. Idempotent.
#
# HOSTED COPY: this file is served by the relay VM as /dl/install.ps1
# (Caddy `handle_path /dl/*` → /var/www/ghoztty-dl). After editing it here,
# upload it to the VM:  scp relay/deploy/install.ps1 <vm>:/var/www/ghoztty-dl/
#
# Usage (paste in a normal PowerShell window on the Windows box):
#
#   irm https://<relay>/dl/install.ps1 | iex
#
# With NO token set, a fresh box self-enrolls via the OAuth device-code flow:
# the agent prints "visit <url>, enter code XXXX-XXXX", you sign in with
# Google, and the credential lands in relay.env automatically (WP-B3).
#
# A pre-minted token still works (skips the interactive sign-in):
#
#   $env:DEVICE_TOKEN='<per-box token>'; irm https://<relay>/dl/install.ps1 | iex
#
# Re-running with an existing relay.env keeps the credential and just updates
# the binary. No admin rights required.

$ErrorActionPreference = 'Stop'
$RelayBase = if ($env:RELAY_BASE) { $env:RELAY_BASE } else { 'https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com' }
$RunDir    = Join-Path $env:LOCALAPPDATA 'ghoztty'
$ExePath   = Join-Path $RunDir 'ghoztty-agent.exe'
$EnvFile   = Join-Path $RunDir 'relay.env'
$Launcher  = Join-Path $RunDir 'run-agent.ps1'
$PidFile   = Join-Path $RunDir 'launcher.pid'

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
Write-Host "== ghoztty-agent installer ==" -ForegroundColor Cyan
Write-Host "   relay : $RelayBase"
Write-Host "   dir   : $RunDir"

# --- stop anything already running (frees the exe for overwrite) --------------
if (Test-Path $PidFile) {
  $oldPid = Get-Content $PidFile -ErrorAction SilentlyContinue
  if ($oldPid) { try { & taskkill.exe /F /T /PID $oldPid 2>$null | Out-Null } catch {} }
}
Get-Process -Name 'ghoztty-agent' -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -eq $ExePath } |
  ForEach-Object { try { & taskkill.exe /F /T /PID $_.Id 2>$null | Out-Null } catch {} }
Start-Sleep -Milliseconds 500

# --- download the agent binary (needed below for --enroll too) ----------------
$tmp = "$ExePath.new"
Invoke-WebRequest -Uri "$RelayBase/dl/ghoztty-agent.exe" -OutFile $tmp -UseBasicParsing
Move-Item -Force $tmp $ExePath
Write-Host ("   agent : downloaded ({0:N1} MB)" -f ((Get-Item $ExePath).Length / 1MB))

# --- credential config ---------------------------------------------------------
if ($env:DEVICE_TOKEN) {
  # Pre-minted token provided: write relay.env directly (legacy/manual path).
  "RELAY_BASE=$RelayBase`nDEVICE_TOKEN=$($env:DEVICE_TOKEN)" | Set-Content -LiteralPath $EnvFile
  Write-Host "   token : written to relay.env (from DEVICE_TOKEN)"
} elseif (Test-Path $EnvFile) {
  Write-Host "   token : keeping existing relay.env"
} else {
  # Fresh box, no token: self-enroll via the OAuth device-code flow. The agent
  # prints the "visit URL, enter code" prompt, polls the relay, and writes
  # relay.env itself on success. NOTE: the agent is a GUI-subsystem exe, so its
  # stdout only reaches this console through a pipeline — hence ForEach-Object.
  Write-Host "   token : none - enrolling this machine with your Google account..." -ForegroundColor Yellow
  & $ExePath --enroll --relay=$RelayBase 2>&1 | ForEach-Object { Write-Host "   $_" }
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $EnvFile)) {
    Write-Error "Enrollment failed (exit $LASTEXITCODE). Re-run the installer to try again."
  }
  Write-Host "   token : enrolled; credential saved to relay.env" -ForegroundColor Green
}

# --- write the launcher (reads relay.env, keeps the agent alive) --------------
@'
$RunDir  = Join-Path $env:LOCALAPPDATA 'ghoztty'
$ExePath = Join-Path $RunDir 'ghoztty-agent.exe'
$EnvFile = Join-Path $RunDir 'relay.env'
$PID | Set-Content (Join-Path $RunDir 'launcher.pid')
while ($true) {
  $base = $null
  Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*RELAY_BASE\s*=\s*(.+)$')   { $base = $Matches[1].Trim() }
    if ($_ -match '^\s*DEVICE_TOKEN\s*=\s*(.+)$') { $env:GHOSTTY_DEVICE_TOKEN = $Matches[1].Trim() }
  }
  # (The agent can now also read relay.env itself; the env var is kept for
  # back-compat with older binaries.) GUI-subsystem exe: no console pops up.
  $p = Start-Process -FilePath $ExePath -ArgumentList @('--relay', $base) -PassThru `
        -RedirectStandardOutput (Join-Path $RunDir 'agent.out.log') `
        -RedirectStandardError  (Join-Path $RunDir 'agent.err.log')
  $p.WaitForExit()
  Start-Sleep -Seconds 3
}
'@ | Set-Content -LiteralPath $Launcher

# --- autostart at logon --------------------------------------------------------
$launchCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`""
try {
  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  Register-ScheduledTask -TaskName 'GhozttyAgent' -Action $action -Trigger $trigger -Force | Out-Null
  Write-Host "   start : scheduled task 'GhozttyAgent' (at logon)"
} catch {
  # Fall back to a Startup-folder launcher if task registration is denied.
  $startup = [Environment]::GetFolderPath('Startup')
  Set-Content -LiteralPath (Join-Path $startup 'ghoztty-agent.cmd') -Value "start `"`" $launchCmd"
  Write-Host "   start : Startup-folder shortcut (task registration unavailable)"
}

# --- start it now ---------------------------------------------------------------
Start-Process powershell.exe -WindowStyle Hidden `
  -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`""
Start-Sleep -Seconds 4

$proc = Get-Process -Name 'ghoztty-agent' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $ExePath }
if ($proc) {
  Write-Host "OK: agent running (pid $($proc.Id))." -ForegroundColor Green
} else {
  Write-Host "WARNING: agent not detected yet; check logs below." -ForegroundColor Yellow
}
$errLog = Join-Path $RunDir 'agent.err.log'
if (Test-Path $errLog) { Write-Host '--- agent.err.log (tail) ---'; Get-Content $errLog -Tail 8 }
