# ghoztty-agent installer — thin wrapper over the per-user MSI. Idempotent.
#
# HOSTED COPY: this file is served by the relay VM as /dl/install.ps1
# (Caddy `handle_path /dl/*` → /var/www/ghoztty-dl). It is uploaded by
# relay/deploy/publish-agent.sh alongside the MSI.
#
# Usage (paste in a normal PowerShell window on the Windows box):
#
#   irm https://<relay>/dl/install.ps1 | iex
#
# Downloads the current versioned MSI (Ghoztty-Agent-X.Y.Z-x64.msi) and
# installs it silently — per-user, no admin/UAC. The MSI does the rest:
# retires any legacy install.ps1 layout (watchdog scheduled task + old
# %LOCALAPPDATA%\ghoztty\ exe), installs to %LOCALAPPDATA%\Programs\Ghoztty
# Agent\, registers the HKCU Run key for start-at-logon, and launches the
# agent immediately. With no credential the launched agent self-enrolls via
# Google sign-in: a browser window opens on this machine — approve the
# sign-in there and the credential lands in relay.env automatically.
#
# A pre-minted token still works (skips the interactive sign-in):
#
#   $env:DEVICE_TOKEN='<per-box token>'; irm https://<relay>/dl/install.ps1 | iex
#
# Re-running with an existing relay.env keeps the credential and just updates
# the binary.

$ErrorActionPreference = 'Stop'
$RelayBase = if ($env:RELAY_BASE) { $env:RELAY_BASE } else { 'https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com' }
$StateDir  = Join-Path $env:LOCALAPPDATA 'ghoztty'   # shared agent state (relay.env, logs)
$EnvFile   = Join-Path $StateDir 'relay.env'

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Write-Host "== ghoztty-agent installer ==" -ForegroundColor Cyan
Write-Host "   relay : $RelayBase"

# --- credential first: the MSI launches the agent at the end of the install,
#     and the agent reads relay.env from $StateDir at startup. ------------------
if ($env:DEVICE_TOKEN) {
  "RELAY_BASE=$RelayBase`nDEVICE_TOKEN=$($env:DEVICE_TOKEN)" | Set-Content -LiteralPath $EnvFile
  Write-Host "   token : written to relay.env (from DEVICE_TOKEN)"
} elseif (Test-Path $EnvFile) {
  Write-Host "   token : keeping existing relay.env"
} else {
  Write-Host "   token : none - the agent will open a browser to enroll this machine" -ForegroundColor Yellow
  Write-Host "           after install; approve the Google sign-in there" -ForegroundColor Yellow
}

# --- resolve the current versioned MSI from the publish manifest --------------
$msiUrlPath = '/dl/ghoztty-agent.msi'   # stable-URL fallback
try {
  $manifest = Invoke-RestMethod -Uri "$RelayBase/dl/version.json" -UseBasicParsing
  $win = $manifest.'windows-x86_64'
  if ($win.msi) { $msiUrlPath = $win.msi }
  if ($win.semver) {
    Write-Host "   ver   : $($win.semver) (build $($win.version))"
  } elseif ($win.version) {
    Write-Host "   ver   : $($win.version)"
  }
} catch {
  Write-Host "   ver   : unknown (version.json unavailable; using stable MSI URL)"
}

# --- download + silent per-user install ----------------------------------------
$msiFile = Join-Path $env:TEMP (Split-Path $msiUrlPath -Leaf)
Invoke-WebRequest -Uri "$RelayBase$msiUrlPath" -OutFile $msiFile -UseBasicParsing
Write-Host ("   msi   : downloaded {0} ({1:N1} MB)" -f (Split-Path $msiFile -Leaf), ((Get-Item $msiFile).Length / 1MB))

$msiLog = Join-Path $env:TEMP 'ghoztty-agent-msi.log'
$p = Start-Process msiexec.exe -ArgumentList "/i `"$msiFile`" /qn /l* `"$msiLog`"" -Wait -PassThru
if ($p.ExitCode -ne 0) {
  Write-Error "MSI install failed (exit $($p.ExitCode)). See $msiLog"
}
Write-Host "   msi   : installed (per-user; starts at logon via HKCU Run key)"

# --- confirm the agent the MSI launched is up ----------------------------------
Start-Sleep -Seconds 3
$exePath = Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty Agent\ghoztty-agent.exe'
$proc = Get-Process -Name 'ghoztty-agent' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exePath }
if ($proc) {
  Write-Host "OK: agent running (pid $($proc.Id))." -ForegroundColor Green
} else {
  Write-Host "NOTE: agent process not detected yet. If enrollment is pending, check for a browser window; otherwise launch 'Ghoztty Agent' from the Start Menu." -ForegroundColor Yellow
}
