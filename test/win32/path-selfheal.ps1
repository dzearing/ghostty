# T70 acceptance: the GUI self-heals the user PATH (HKCU\Environment\Path)
# so `ghoztty` resolves from any shell — the Windows analog of macOS
# CommandLineInstaller. PathInstaller.zig runs at App.init on a background
# thread, gated to the canonical install dir (%LOCALAPPDATA%\Programs\
# Ghoztty); GHOZTTY_PATH_SELFHEAL=force bypasses the gate so this script can
# exercise the flow with the zig-out debug build.
#
# Cases:
#   A gate:      launch with no env var (exe is in zig-out, not the install
#                dir) -> Path untouched.
#   B heal:      launch with =force on a Path missing the exe dir -> the dir
#                is appended, exactly once, value prefix + registry value
#                kind preserved. (Also the positive control proving the
#                mechanism works, so A/C/D/E no-writes are meaningful.)
#   C idempotent: relaunch with =force -> value byte-identical.
#   D variants:  entry already present as quoted + trailing-backslash +
#                different case -> not added again.
#   E %VAR%:     entry present only as an unexpanded %VAR% form -> detected
#                via expansion, not added again.
#
# The REAL user Path is used as the base (never replaced wholesale — new
# shells during the run must keep working); the original value + kind are
# restored in a finally block. Only touches ghoztty processes running from
# this repo's zig-out.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
$exeDir = Split-Path $exe -Parent

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Get-UserPathRaw {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        try {
            $kind = $k.GetValueKind('Path')
            $val = [string]$k.GetValue('Path', '',
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } catch { $kind = $null; $val = $null }
        [pscustomobject]@{ Value = $val; Kind = $kind }
    } finally { $k.Close() }
}

function Set-UserPathRaw([string]$value, $kind) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try { $k.SetValue('Path', $value, $kind) } finally { $k.Close() }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Launch the GUI, give the self-heal thread time to run, kill it. Returns
# $true if the process survived (didn't crash at init).
function Launch-Gui([string]$healEnv) {
    Kill-RepoInstances
    if ($null -ne $healEnv) { $env:GHOZTTY_PATH_SELFHEAL = $healEnv }
    try {
        $proc = Start-Process -FilePath $exe -PassThru
    } finally {
        Remove-Item Env:GHOZTTY_PATH_SELFHEAL -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    $alive = -not $proc.HasExited
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    return $alive
}

# Poll until the raw user Path contains $needle (substring), up to $secs.
function Wait-PathContains([string]$needle, [int]$secs) {
    for ($t = 0; $t -lt $secs * 4; $t++) {
        if ((Get-UserPathRaw).Value -like "*$needle*") { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$orig = Get-UserPathRaw
if ($null -eq $orig.Kind) {
    Write-Host 'SETUP FAIL: user Path value absent — refusing to run against a profile with no PATH'
    exit 1
}

# Base value for the tests: the real Path minus any existing zig-out entry
# (normally none; guards a re-run after an aborted script).
$base = (($orig.Value -split ';') | Where-Object {
    $_.Trim().Trim('"').TrimEnd('\') -ne $exeDir
}) -join ';'

try {
    # --- A: location gate — no env var, exe in zig-out -> no write.
    Set-UserPathRaw $base $orig.Kind
    $alive = Launch-Gui $null
    Assert $alive 'A gate: GUI survived launch'
    Assert ((Get-UserPathRaw).Value -eq $base) 'A gate: Path untouched (exe not in install dir)'

    # --- B: forced heal on a Path missing the entry.
    Set-UserPathRaw $base $orig.Kind
    $alive = Launch-Gui 'force'
    Assert $alive 'B heal: GUI survived launch'
    Assert (Wait-PathContains $exeDir 10) 'B heal: exe dir appeared on the user Path'
    $after = Get-UserPathRaw
    $expected = if ($base.TrimEnd() -match ';$') { "$($base.TrimEnd())$exeDir" } else { "$base;$exeDir" }
    Assert ($after.Value -eq $expected) 'B heal: appended exactly once at the end, prefix intact'
    Assert ($after.Kind -eq $orig.Kind) 'B heal: registry value kind preserved'

    # --- C: idempotent — entry already present verbatim -> byte-identical.
    $healed = (Get-UserPathRaw).Value
    $alive = Launch-Gui 'force'
    Assert $alive 'C idempotent: GUI survived launch'
    Assert ((Get-UserPathRaw).Value -eq $healed) 'C idempotent: Path byte-identical after relaunch'

    # --- D: entry present as quoted + trailing backslash + different case.
    $variant = $base + ';"' + $exeDir.ToUpper() + '\"'
    Set-UserPathRaw $variant $orig.Kind
    $alive = Launch-Gui 'force'
    Assert $alive 'D variants: GUI survived launch'
    Assert ((Get-UserPathRaw).Value -eq $variant) 'D variants: quoted/case/trailing-backslash form detected, no duplicate'

    # --- E: entry present only as an unexpanded %VAR% form.
    $env:GHOZTTY_T70_DIR = $exeDir
    $varform = $base + ';%GHOZTTY_T70_DIR%'
    Set-UserPathRaw $varform $orig.Kind
    $alive = Launch-Gui 'force'
    Remove-Item Env:GHOZTTY_T70_DIR -ErrorAction SilentlyContinue
    Assert $alive 'E %VAR%: GUI survived launch'
    Assert ((Get-UserPathRaw).Value -eq $varform) 'E %VAR%: expanded form detected, no duplicate'
} finally {
    Kill-RepoInstances
    Set-UserPathRaw $orig.Value $orig.Kind
    Remove-Item Env:GHOZTTY_T70_DIR -ErrorAction SilentlyContinue
}

$restored = Get-UserPathRaw
Assert ($restored.Value -eq $orig.Value -and $restored.Kind -eq $orig.Kind) 'cleanup: original user Path restored'

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
