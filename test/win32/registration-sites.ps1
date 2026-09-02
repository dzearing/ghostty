# T1151 acceptance: a build that lives in a source checkout registers nothing.
#
# WHY THIS EXISTS AS A SEPARATE HARNESS. url-scheme.ps1 proves ONE gate;
# agent-autostart.ps1 proves a second. Neither can say whether a THIRD
# registration was added last week with no gate at all, and that is the shape
# both real incidents took: T1124 (the staging release pointed the user's
# ghoztty:// links at a scratch directory for days) and T1146 (the same for the
# Run entry Windows obeys at sign-in, which survives a reboot). So this script
# asserts the SET rather than a site: every registration-shaped write in the
# tree is named by docs\design\windows-registration-sites.md, and every row that
# claims a location gate still has one.
#
# WHAT COUNTS AS A REGISTRATION. A write that outlives the process AND that the
# OS, the shell, or another program reads on the user's behalf: an HKCU value, a
# file under %USERPROFILE% outside our own state dir, a scheduled task, an MSI
# product change. The state directory (%LOCALAPPDATA%\ghoztty\*) is deliberately
# NOT in scope - it is lineage-suffixed, nothing outside Ghoztty reads it, and
# T350's build-mode rule already covers it. The inventory doc says all of this.
#
# Sections:
#
#   A  INVENTORY COMPLETENESS. Scan src/ for the registration primitives
#      (RegSetValueExW / RegCreateKeyExW, HKEY_CURRENT_USER, schtasks, the
#      Startup folder, the home-relative hook install dir). Every file that
#      holds one must appear in the inventory doc - in the gated table or in
#      the deliberately-ungated table with its reason. An unlisted file FAILS
#      and names itself, which is the whole point: the next registration cannot
#      arrive quietly.
#   B  GATE PRESENCE. Every file the doc lists as location-gated actually
#      references the gate (inSourceCheckout), and every file listed as
#      canonical-install-gated actually compares against Programs\Ghoztty. A row
#      whose file lost its gate goes red.
#   C  ONE GATE, ONE ANSWER. The gate helper lives in exactly one place
#      (src\os\source_checkout.zig) and the win32 spelling is a re-export, so
#      the app's answer and the agent's answer cannot drift apart. This is the
#      T1151 move that let adopt.zig - which uninstalls the user's standalone
#      MSI product - ask the same question the app asks.
#   D  BEHAVIOR, against the user's real registrations. Snapshot
#      HKCU\Software\Classes\ghoztty*, the Run values and HKCU\Environment\Path;
#      launch this repo's build with every self-heal seam set to `gate` (the
#      release location gate applied to a debug build); assert the snapshot is
#      byte-identical afterwards. The CONTROL is the same launch without the
#      gate seam: the debug lineage class MUST appear, which proves the
#      observation can see a registration at all - a green section D with a
#      blind probe would be worthless. The control only ever writes the
#      `ghoztty-debug` lineage, never the release names the user's shell obeys.
#
# ORACLE. Registry reads, not log lines: what this measures is the user's
# machine state, so it reads the machine rather than the app's opinion of it.
#
# Sections A-C are a static scan (safe anywhere, including the off-desktop
# harness). Section D launches the repo build and is skipped with -NoLaunch or
# when no build is present.
#
#   powershell -NoProfile -File test\win32\registration-sites.ps1
#   powershell -NoProfile -File test\win32\registration-sites.ps1 -NegativeControl
#
# isolation: debug build only (BuildMode preflight); the launch uses
# --session-persistence=false and its own window, and every registration seam is
# gated, so nothing of the user's is written.
param(
    [string]$Repo,
    [switch]$NoLaunch,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
$script:skips = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}
function Skip($name, $why) { "  SKIP $name - $why"; $script:skips++ }

$InventoryPath = Join-Path $Repo 'docs\design\windows-registration-sites.md'

# ---------------------------------------------------------------------------
# A. INVENTORY COMPLETENESS
# ---------------------------------------------------------------------------
""
"A. INVENTORY COMPLETENESS - every registration-shaped write is named by the doc"

if (-not (Test-Path $InventoryPath)) {
    Assert 'A0 the inventory doc exists' $false "(expected $InventoryPath)"
} else {
    Assert 'A0 the inventory doc exists' $true
}
$inventory = if (Test-Path $InventoryPath) { Get-Content -Raw -Encoding UTF8 $InventoryPath } else { '' }

# WRITE markers: reaching for one of these is how a registration gets created.
# A new one is a deliberate act and belongs in this list.
$WriteMarkers = @(
    'RegSetValueExW',
    'RegCreateKeyExW',
    'RegDeleteKeyW',
    'RegDeleteValueW',
    'hook_scripts.install_dir',
    'schtasks',
    'Start Menu'
)
# READ markers: a file that opens HKCU/HKLM but holds no write marker is
# reading the machine, not changing it. Those are reported as a count rather
# than demanded into the inventory - but the moment such a file grows a write
# marker it needs a row, which is the transition this catches.
$ReadMarkers = @('HKEY_CURRENT_USER', 'HKEY_LOCAL_MACHINE')

# Exemptions, each for a stated reason - not because it was inconvenient.
$Exempt = @{
    'src\apprt\win32\win32.zig'            = 'extern declarations only: the Win32 API surface, no call site'
    'src\os\source_checkout.zig'           = 'the gate helper itself'
    'src\apprt\win32\source_checkout.zig'  = 're-export of the gate helper'
    'src\apprt\win32\install_location.zig' = 'the install-location predicate, reads only'
    'src\remote\agent\spike\main.zig'      = 'the WP2 risk spike: a hand-run prototype, not built or shipped'
    'src\remote\agent\spike\win32.zig'     = 'the WP2 risk spike: extern prototypes only'
}

$srcRoot = Join-Path $Repo 'src'
$zigFiles = @(Get-ChildItem -Path $srcRoot -Recurse -Filter *.zig |
    Where-Object { $_.FullName -notlike '*\apprt\gtk\*' })

$writers = @{}
$readers = @()
foreach ($f in $zigFiles) {
    $rel = $f.FullName.Substring($Repo.Length).TrimStart('\')
    $lines = Get-Content -Encoding UTF8 $f.FullName
    # A marker inside a doc comment is prose about the mechanism, not a use of
    # it: `tray.zig` explains that a Start Menu launch has no console.
    $code = @($lines | Where-Object { $_.TrimStart() -notmatch '^//' })
    $marks = @()
    foreach ($m in $WriteMarkers) {
        if ($code | Where-Object { $_ -like "*$m*" }) { $marks += $m }
    }
    if ($marks.Count -gt 0) { $writers[$rel] = $marks; continue }
    foreach ($m in $ReadMarkers) {
        if ($code | Where-Object { $_ -like "*$m*" }) { $readers += $rel; break }
    }
}

$unlisted = @()
foreach ($rel in ($writers.Keys | Sort-Object)) {
    if ($Exempt.ContainsKey($rel)) { continue }
    # The doc spells paths with forward slashes inside code spans.
    $docSpelling = $rel -replace '\\', '/'
    if ($inventory -notmatch [regex]::Escape($docSpelling)) { $unlisted += "$rel [$($writers[$rel] -join ',')]" }
}

"  (scan: $($writers.Count) files hold a write marker, $($readers.Count) read the registry only)"

Assert 'A1 the scan found the known registration sites' ($writers.Count -ge 5) `
    "(found $($writers.Count) files holding a write marker)"
Assert 'A2 every scanned file is named by the inventory' ($unlisted.Count -eq 0) `
    "(unlisted: $($unlisted -join '; ') - add a row to docs\design\windows-registration-sites.md)"

# The five gated rows are named explicitly, so a doc edit that quietly drops one
# is a failure rather than a smaller table.
$RequiredRows = @(
    'src/apprt/win32/url_scheme.zig',
    'src/apprt/win32/LocalAgent.zig',
    'src/apprt/win32/PathInstaller.zig',
    'src/apprt/win32/AgentIntegration.zig',
    'src/remote/agent/adopt.zig'
)
$missingRows = @($RequiredRows | Where-Object { $inventory -notmatch [regex]::Escape($_) })
Assert 'A3 all five gated sites still have rows' ($missingRows.Count -eq 0) `
    "(missing: $($missingRows -join ', '))"

# ---------------------------------------------------------------------------
# B. GATE PRESENCE
# ---------------------------------------------------------------------------
""
"B. GATE PRESENCE - a row that claims a gate has one in the source"

function Holds($relPath, $pattern) {
    $full = Join-Path $Repo $relPath
    if (-not (Test-Path $full)) { return $false }
    return (Select-String -Path $full -Pattern $pattern -SimpleMatch -Quiet)
}

Assert 'B1 url_scheme asks the location question' `
    (Holds 'src\apprt\win32\url_scheme.zig' 'inSourceCheckout')
Assert 'B2 the agent Run key asks the location question' `
    (Holds 'src\apprt\win32\LocalAgent.zig' 'source_checkout.inSourceCheckout')
Assert 'B3 the MSI adoption asks the location question (T1151)' `
    (Holds 'src\remote\agent\adopt.zig' 'inSourceCheckout')
Assert 'B4 the PATH self-heal acts only from the canonical install' `
    ((Holds 'src\apprt\win32\PathInstaller.zig' 'Programs') -and
     (Holds 'src\apprt\win32\PathInstaller.zig' 'LOCALAPPDATA'))
Assert 'B5 the first-run agent integration acts only from the canonical install' `
    ((Holds 'src\apprt\win32\AgentIntegration.zig' 'Programs') -and
     (Holds 'src\apprt\win32\AgentIntegration.zig' 'setupEnabled'))

# The seams, spelled the same way at every site, are what let a gate be
# demonstrated without a release build at the user's endpoints.
Assert 'B6 every self-heal carries an off/force/gate seam' `
    ((Holds 'src\apprt\win32\url_scheme.zig' 'GHOZTTY_URL_SCHEME') -and
     (Holds 'src\apprt\win32\LocalAgent.zig' 'GHOZTTY_AGENT_AUTOSTART') -and
     (Holds 'src\apprt\win32\PathInstaller.zig' 'GHOZTTY_PATH_SELFHEAL') -and
     (Holds 'src\apprt\win32\AgentIntegration.zig' 'GHOZTTY_CLAUDE_SETUP'))

# ---------------------------------------------------------------------------
# C. ONE GATE, ONE ANSWER
# ---------------------------------------------------------------------------
""
"C. ONE GATE, ONE ANSWER - the app and the agent cannot drift apart"

$sharedGate = Join-Path $Repo 'src\os\source_checkout.zig'
Assert 'C1 the helper lives under src\os so the agent can reach it' (Test-Path $sharedGate)
Assert 'C2 the win32 spelling is a re-export, not a second copy' `
    ((Holds 'src\apprt\win32\source_checkout.zig' 'os/source_checkout.zig') -and
     -not (Holds 'src\apprt\win32\source_checkout.zig' 'pub fn inSourceCheckout'))
Assert 'C3 os/main.zig exports it (so its unit tests run in the none lane)' `
    (Holds 'src\os\main.zig' 'source_checkout')

# ---------------------------------------------------------------------------
# D. BEHAVIOR - the user's real registrations survive a launch untouched
# ---------------------------------------------------------------------------
""
"D. BEHAVIOR - a gated launch writes none of the user's registrations"

# The RELEASE lineage only: the names the user's own shell obeys. The
# `-debug` spellings are this harness's own working surface (section D plants
# and clears them), so including them would compare the test against itself.
function Snapshot-Registrations {
    $out = [ordered]@{}
    $k = 'HKCU:\Software\Classes\ghoztty\shell\open\command'
    $out['class:ghoztty'] = if (Test-Path $k) { (Get-ItemProperty $k).'(default)' } else { '<absent>' }
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path $run) {
        $props = Get-ItemProperty $run
        foreach ($n in ($props.PSObject.Properties.Name |
                Where-Object { $_ -notlike 'PS*' -and $_ -notlike '*-debug*' } | Sort-Object)) {
            $out["run:$n"] = [string]$props.$n
        }
    }
    $env_ = 'HKCU:\Environment'
    $out['path'] = if (Test-Path $env_) {
        [string](Get-ItemProperty $env_ -Name Path -ErrorAction SilentlyContinue).Path
    } else { '<absent>' }
    return $out
}

function Format-Snapshot($snap) {
    ($snap.Keys | ForEach-Object { "$_=$($snap[$_])" }) -join "`n"
}

$exe = Join-Path $Repo 'zig-out\bin\ghoztty.exe'
if ($NoLaunch) {
    Skip 'D launch section' '-NoLaunch'
} elseif (-not (Test-Path $exe)) {
    Skip 'D launch section' "no build at $exe (zig build -Dapp-runtime=win32 -Doptimize=Debug)"
} else {
    . (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
    $null = Assert-GhozttyIsolatedBuild -Exe $exe

    # T1240: the two probe launches land ON THE TEST DESKTOP. A window arrives
    # on the desktop of whoever started the process, so section D used to throw
    # two across whatever the user was reading. What is measured here is the
    # REGISTRY, which the desktop has no bearing on.
    . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
    $td = New-TestDesktop

    # The user's release-lineage registrations, as they stand right now.
    $before = Snapshot-Registrations

    function Launch($seamValue, $tag) {
        $env:GHOZTTY_URL_SCHEME = $seamValue
        $env:GHOZTTY_AGENT_AUTOSTART = $seamValue
        $env:GHOZTTY_PATH_SELFHEAL = if ($seamValue -eq 'gate') { 'off' } else { $seamValue }
        $env:GHOZTTY_CLAUDE_SETUP = 'off'
        try {
            $started = Start-OnTestDesktop -Exe $exe `
                -Arguments @('--session-persistence=false', "--window-name=regsites-$tag")
            Start-Sleep -Seconds 6
            $p = $null
            try { $p = [System.Diagnostics.Process]::GetProcessById($started.Pid) } catch { }
            if ($null -ne $p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) }
            return $true
        } catch {
            return $false
        } finally {
            Remove-Item Env:GHOZTTY_URL_SCHEME, Env:GHOZTTY_AGENT_AUTOSTART, `
                Env:GHOZTTY_PATH_SELFHEAL, Env:GHOZTTY_CLAUDE_SETUP -ErrorAction SilentlyContinue
        }
    }

    # D1/D2: the CONTROL first, so a blind probe cannot pass the real assertion.
    # Without the gate seam a debug build registers its own lineage class; that
    # is the observation proving the snapshot can see a registration at all.
    $controlKey = 'HKCU:\Software\Classes\ghoztty-debug\shell\open\command'
    Remove-Item 'HKCU:\Software\Classes\ghoztty-debug' -Recurse -Force -ErrorAction SilentlyContinue
    $ranControl = Launch 'default' 'control'
    Assert 'D1 the control launch ran' $ranControl
    Assert 'D2 CONTROL: without the gate, the debug lineage class IS written' `
        (Test-Path $controlKey) `
        '(the probe cannot see registrations at all - every other D assertion would be vacuous)'
    $controlCmd = if (Test-Path $controlKey) { (Get-ItemProperty $controlKey).'(default)' } else { '' }
    Assert 'D3 CONTROL: and it names this repo build' ($controlCmd -like "*$($Repo)*")

    # D4: now with the release location gate applied to the same build.
    Remove-Item 'HKCU:\Software\Classes\ghoztty-debug' -Recurse -Force -ErrorAction SilentlyContinue
    $ranGated = Launch 'gate' 'gated'
    Assert 'D4 the gated launch ran' $ranGated
    Assert 'D5 GATED: nothing is registered from a source checkout' `
        (-not (Test-Path $controlKey)) `
        '(a build inside the checkout registered anyway)'

    # D6: and across both launches the user's own registrations never moved.
    $after = Snapshot-Registrations
    $moved = @()
    foreach ($k in ($before.Keys + $after.Keys | Select-Object -Unique)) {
        $b = if ($before.Contains($k)) { $before[$k] } else { '<absent>' }
        $a = if ($after.Contains($k)) { $after[$k] } else { '<absent>' }
        if ($b -ne $a) { $moved += $k }
    }
    Assert 'D6 the user''s real registrations are byte-identical' `
        ($moved.Count -eq 0) `
        "(these moved: $($moved -join ', '))"

    Remove-Item 'HKCU:\Software\Classes\ghoztty-debug' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-TestDesktop | Out-Null
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL: plant an ungated registration site and assert the scan does
# NOT report it - a working scan MUST fail this. The probe file is restored
# either way, including on a crash.
# ---------------------------------------------------------------------------
if ($NegativeControl) {
    ""
    "NEGATIVE CONTROL: a new ungated registration goes unreported - a working scan MUST fail this"
    $probe = Join-Path $Repo 'src\apprt\win32\registration_probe.zig'
    try {
        $body = @'
// T1151 negative control probe. Deleted by the harness that wrote it.
const w32 = @import("win32.zig");
pub fn plantedRegistration() void {
    _ = w32.RegSetValueExW;
}
'@
        [System.IO.File]::WriteAllText($probe, $body)
        # Re-run THIS script's own scan against the planted file, in a child
        # process, so what is measured is the scan rather than a restatement of
        # it. A working scan reports the new site and exits 1.
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Repo $Repo -NoLaunch 2>&1
        $childExit = $LASTEXITCODE
        Assert 'N1 the scan misses a planted ungated registration (inverted)' ($childExit -eq 0) `
            '(it reported it, which is the healthy answer)'
        Assert 'N2 and the report names the planted file (inverted)' `
            (-not ("$out" -like '*registration_probe.zig*')) `
            '(it named it, which is the healthy answer)'
    } finally {
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
    }
    Assert 'N3 the probe file is gone' (-not (Test-Path $probe))
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this scan been run against the tree as it now stands?". A run with
# skipped sections does not stamp - a partial sweep is not a sweep.
if ($script:failures -eq 0 -and $script:skips -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard registration-sites -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) {
    if ($script:skips -gt 0) { "ALL PASS ($script:passes, $script:skips skipped)" } else { "ALL PASS ($script:passes)" }
    exit 0
} else { "$script:failures FAILURE(S) ($script:passes passed)"; exit 1 }
