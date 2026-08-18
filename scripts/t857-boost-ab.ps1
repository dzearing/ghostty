<#
.SYNOPSIS
  Run the T857 Turbo-Boost-off arm and put the machine back, in one command.

.DESCRIPTION
  T857 needs the crash-prone soak measured with Turbo Boost DISABLED, to tell a
  hardware fault from a software one for the T443 ghost. Disabling boost needs
  an elevated shell, and the loop has none (Windows sudo is disabled on this
  box), so this is the one step a human has to launch.

  It used to be handed over as two bare `powercfg` lines with "restore 100
  afterwards" as a footnote. That is a bad instruction: the machine is left
  degraded until somebody REMEMBERS to undo it, and the person who has to
  remember is the one who did not want the chore in the first place. This
  script exists so there is nothing to remember.

  Two properties make it safe:

  1. **Your power scheme is never modified.** The boost-off setting is applied
     to a DUPLICATE scheme which is activated for the run and deleted after.
     Even a hard failure cannot leave a wrong value inside the scheme you use
     every day - the worst case is a temporary scheme still being active, which
     `-RestoreOnly` (and the boot-time safety net below) fixes.
  2. **The restore does not depend on this script finishing.** Before touching
     anything it registers a RunOnce entry that reactivates your original scheme
     and deletes the temporary one. So a crash, a closed window, a Ctrl-C, or a
     power cut still ends with the machine back to normal at the next sign-in.
     The `finally` block does it immediately in every ordinary case, and clears
     the safety net once it has.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

.EXAMPLE
  # The whole arm - disable boost, soak, restore. Needs an elevated shell.
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\t857-boost-ab.ps1

.EXAMPLE
  # Panic button: put the power scheme back and delete any leftover temp scheme.
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\t857-boost-ab.ps1 -RestoreOnly
#>
[CmdletBinding()]
param(
    [int]$Runs = 15,
    [int]$LoadWorkers = 4,
    [string]$Label = 't857-boost-OFF',
    [string]$Repo = 'D:\git\ghoztty',
    # Undo only: reactivate the saved scheme, delete leftovers, clear the net.
    [switch]$RestoreOnly,
    # Set boost off and return immediately, leaving the soak to be run by hand.
    # The safety net stays armed, so the machine still recovers on its own.
    [switch]$NoSoak
)

$ErrorActionPreference = 'Stop'

$TempSchemeName = 'Ghoztty T857 boost-off (temporary)'
$RunOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$RunOnceName = 'GhozttyT857RestorePower'
$StateFile = Join-Path $env:ProgramData 'ghoztty-t857-power.json'

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ActiveSchemeGuid {
    $out = (& powercfg /getactivescheme) -join ' '
    $m = [regex]::Match($out, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if (-not $m.Success) { throw "could not read the active power scheme from: $out" }
    return $m.Groups[1].Value
}

function Get-ThrottleMax {
    $out = (& powercfg /query scheme_current sub_processor PROCTHROTTLEMAX) -join "`n"
    $m = [regex]::Match($out, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    if (-not $m.Success) { return $null }
    return [Convert]::ToInt32($m.Groups[1].Value, 16)
}

# The safety net. Registered BEFORE the first change and cleared only after the
# restore has actually happened, so every window in which the machine is left
# altered is covered by something that does not need this process to survive.
function Set-SafetyNet([string]$OriginalGuid, [string]$TempGuid) {
    $cmd = "cmd.exe /c powercfg /setactive $OriginalGuid & powercfg /delete $TempGuid"
    New-ItemProperty -Path $RunOnceKey -Name $RunOnceName -Value $cmd `
        -PropertyType String -Force | Out-Null
    @{ original = $OriginalGuid; temp = $TempGuid } | ConvertTo-Json |
        Set-Content -Path $StateFile -Encoding utf8
}

function Clear-SafetyNet {
    try { Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction Stop } catch {}
    try { Remove-Item $StateFile -ErrorAction Stop } catch {}
}

function Restore-Power([string]$OriginalGuid, [string]$TempGuid) {
    if ($OriginalGuid) {
        & powercfg /setactive $OriginalGuid | Out-Null
        Write-Host "  reactivated your scheme $OriginalGuid"
    }
    if ($TempGuid) {
        try { & powercfg /delete $TempGuid | Out-Null; Write-Host "  deleted the temporary scheme $TempGuid" } catch {}
    }
    Clear-SafetyNet
    $now = Get-ThrottleMax
    if ($null -ne $now) {
        Write-Host ("  PROCTHROTTLEMAX now reads {0} ({1})" -f $now,
            $(if ($now -ge 100) { 'boost back ON - normal' } else { 'STILL CAPPED - see below' }))
        if ($now -lt 100) {
            Write-Warning "Boost is still capped. Run this script with -RestoreOnly, or set it by hand:"
            Write-Warning "  powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX 100"
            Write-Warning "  powercfg /setactive scheme_current"
        }
    }
}

if (-not (Test-Elevated)) {
    Write-Host ''
    Write-Host 'This needs an elevated shell (it changes a power setting).' -ForegroundColor Yellow
    Write-Host 'Start Windows Terminal / PowerShell with "Run as administrator", then:'
    Write-Host ''
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File $Repo\scripts\t857-boost-ab.ps1"
    Write-Host ''
    Write-Host 'Nothing has been changed.'
    exit 2
}

# --- panic button -----------------------------------------------------------
if ($RestoreOnly) {
    $orig = $null; $temp = $null
    if (Test-Path $StateFile) {
        try {
            $st = Get-Content $StateFile -Raw | ConvertFrom-Json
            $orig = $st.original; $temp = $st.temp
        }
        catch {}
    }
    if (-not $orig) {
        # No state file: fall back to raising the CURRENT scheme's cap, which is
        # the only thing left to undo if the temp scheme was already removed.
        Write-Host 'No saved state; raising the active scheme cap back to 100.'
        & powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX 100 | Out-Null
        & powercfg /setdcvalueindex scheme_current sub_processor PROCTHROTTLEMAX 100 | Out-Null
        & powercfg /setactive scheme_current | Out-Null
        Clear-SafetyNet
        Write-Host ("PROCTHROTTLEMAX now reads {0}" -f (Get-ThrottleMax))
        exit 0
    }
    Write-Host 'Restoring:'
    Restore-Power -OriginalGuid $orig -TempGuid $temp
    exit 0
}

# --- the arm ----------------------------------------------------------------
$original = Get-ActiveSchemeGuid
$before = Get-ThrottleMax
Write-Host ("Your scheme: {0}  (PROCTHROTTLEMAX {1})" -f $original, $before)

if ($before -ne $null -and $before -lt 100) {
    Write-Warning "Boost already looks capped at $before. Run -RestoreOnly first so the baseline is honest."
    exit 1
}

$dup = (& powercfg /duplicatescheme $original) -join ' '
$m = [regex]::Match($dup, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
if (-not $m.Success) { throw "could not duplicate the power scheme: $dup" }
$tempGuid = $m.Groups[1].Value

try {
    Set-SafetyNet -OriginalGuid $original -TempGuid $tempGuid
    Write-Host "Safety net armed: your scheme is restored at next sign-in even if this dies."

    & powercfg /changename $tempGuid $TempSchemeName 'Delete me - created by scripts\t857-boost-ab.ps1' | Out-Null
    & powercfg /setacvalueindex $tempGuid sub_processor PROCTHROTTLEMAX 99 | Out-Null
    & powercfg /setdcvalueindex $tempGuid sub_processor PROCTHROTTLEMAX 99 | Out-Null
    & powercfg /setactive $tempGuid | Out-Null

    $now = Get-ThrottleMax
    if ($now -ne 99) { throw "boost-off did not take: PROCTHROTTLEMAX reads $now, wanted 99" }
    Write-Host "Turbo Boost OFF (PROCTHROTTLEMAX 99) on a throwaway scheme; yours is untouched."

    if ($NoSoak) {
        Write-Host ''
        Write-Host 'Leaving boost off as asked. When you are done, run:'
        Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File $Repo\scripts\t857-boost-ab.ps1 -RestoreOnly"
        Write-Host '(or just sign out and back in - the safety net does it for you.)'
        exit 0
    }

    Write-Host ''
    Write-Host "Running the boost-off arm: $Runs runs, $LoadWorkers build workers..."
    & powershell -NoProfile -File (Join-Path $Repo 'scripts\test-binary-soak.ps1') `
        -Lane none -Runs $Runs -LoadWorkers $LoadWorkers -LoadKind build -NoCatch `
        -Label $Label -Repo $Repo
    Write-Host ''
    Write-Host "Boost-off arm finished. Compare against the boost-on baseline recorded in T443."
}
finally {
    Write-Host ''
    Write-Host 'Putting your machine back:'
    Restore-Power -OriginalGuid $original -TempGuid $tempGuid
}
