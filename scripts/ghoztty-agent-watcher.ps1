# ghoztty-agent-watcher.ps1
# ── Run this ONCE on the Windows box. Keep the window open. ──
# It watches the share for a new ghoztty-agent.exe and hot-swaps it:
# stops the running agent, copies the new build to a stable local path, starts it.
# This removes you from the deploy loop — Claude just drops a new .exe on the share
# and it goes live within a few seconds.
#
#   Usage:  powershell -ExecutionPolicy Bypass -File \\homeassistant\share\ghoztty-windows\ghoztty-agent-watcher.ps1
#
# First launch will pop ONE Windows Firewall prompt (Allow). After that, the agent
# always runs from the same local path, so you'll never be prompted again.

$ErrorActionPreference = 'Continue'
$ShareDir   = '\\homeassistant\share\ghoztty-windows'
$Share      = Join-Path $ShareDir 'ghoztty-agent.exe'
$ShareLogs  = Join-Path $ShareDir 'logs'           # mirrored here so Claude can read from /Volumes/share
$RunDir     = Join-Path $env:LOCALAPPDATA 'ghoztty'
$Local      = Join-Path $RunDir 'ghoztty-agent.exe'
$LogOut     = Join-Path $RunDir 'agent.out.log'
$LogErr     = Join-Path $RunDir 'agent.err.log'
$WatcherLog = Join-Path $RunDir 'watcher.log'
$Listen     = '0.0.0.0:7777'
$PollSec    = 3

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
try { New-Item -ItemType Directory -Force -Path $ShareLogs | Out-Null } catch {}
function Log($m){
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Host $line
  try { Add-Content -LiteralPath $WatcherLog -Value $line } catch {}
}
# Mirror local logs to the share so Claude can read them remotely (best-effort).
function SyncLogs(){
  try {
    foreach ($f in @($LogOut, $LogErr, $WatcherLog)) {
      if (Test-Path $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $ShareLogs (Split-Path $f -Leaf)) -Force -ErrorAction SilentlyContinue }
    }
  } catch {}
}
function HashOf($p){ if (Test-Path $p) { (Get-FileHash -Algorithm SHA256 $p).Hash } else { $null } }

$proc = $null
$deployed = $null
Log "watcher started."
Log "  share : $Share"
Log "  local : $Local"
Log "  listen: $Listen"
Log "Drop a new ghoztty-agent.exe on the share and it auto-deploys. Ctrl-C to stop."

while ($true) {
  try {
    $srcHash = HashOf $Share
    $alive   = ($proc -ne $null) -and (-not $proc.HasExited)

    if ($srcHash -and (($srcHash -ne $deployed) -or (-not $alive))) {
      if ($srcHash -ne $deployed) { Log "new build detected: $($srcHash.Substring(0,12))..." }
      elseif (-not $alive)        { Log "agent exited; restarting." }

      # Stop the agent we started, plus any strays running from our local path.
      if ($alive) { Log "stopping old agent (pid $($proc.Id))"; try { $proc.Kill(); $proc.WaitForExit(5000) | Out-Null } catch {} }
      Get-Process -Name 'ghoztty-agent' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $Local } |
        ForEach-Object { try { $_.Kill() } catch {} }
      Start-Sleep -Milliseconds 500

      # Copy the new build over the stable local path (retry past the brief exe lock).
      $copied = $false
      for ($i = 0; $i -lt 25; $i++) {
        try { Copy-Item -LiteralPath $Share -Destination $Local -Force; $copied = $true; break }
        catch { Start-Sleep -Milliseconds 300 }
      }
      if (-not $copied) { Log "ERROR: could not copy new build (still locked?); will retry next poll"; Start-Sleep -Seconds $PollSec; continue }

      # Launch it (no window; stdout/stderr -> log files).
      $proc = Start-Process -FilePath $Local -ArgumentList @('--listen', $Listen) `
                -PassThru -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr
      $deployed = $srcHash
      Start-Sleep -Milliseconds 400
      $banner = if (Test-Path $LogOut) { (Get-Content $LogOut -Tail 1 -ErrorAction SilentlyContinue) } else { '' }
      Log "started build $($srcHash.Substring(0,12)) pid $($proc.Id)  [$banner]"
    }
  } catch {
    Log "ERROR: $($_.Exception.Message)"
  }
  SyncLogs
  Start-Sleep -Seconds $PollSec
}
