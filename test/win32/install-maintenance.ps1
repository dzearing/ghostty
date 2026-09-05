# Re-running the installer for the version you already have must SAY SO (T1291).
#
# THE DEFECT, in the user's words on 2026-09-03: "I also tried installing the
# msi with a version already installed and it just silently quit. […] there
# should be some message to ask what to do (reinstall, cancel) that's a standard
# dialog to let you know you're already good, not just silently fail."
#
# Why it was silent, and why nothing logged a problem: an MSI whose ProductCode
# is already installed puts Windows Installer into MAINTENANCE mode, and
# maintenance mode hands the whole question - repair? change? remove? - to the
# package's authored UI. This package has none, deliberately: a double-clicked
# install is a progress bar and then a terminal, with no wizard anywhere. So
# there was nothing to show, no feature state changed, and msiexec exited 0
# without a word. Every part of that was working as designed.
#
# The fix under test: the package asks THE APP, through the same type-51/type-50
# custom-action pair it already uses for --install-prepare and for
# launch-on-finish. msiexec runs `[INSTALLDIR]ghoztty.exe --install-maintenance`,
# the app puts up the dark Ghoztty dialog relabelled Repair / Cancel, and the
# answer comes back as the process exit code - 0 to let the pre-armed
# REINSTALL=ALL proceed, 1602 (ERROR_INSTALL_USEREXIT) to end the transaction
# cleanly. Those two numbers ARE the feature: any other non-zero value surfaces
# as error 1721, which is a worse outcome than the silence being replaced.
#
# What this asserts:
#
#   A  the shipped shape: the flag, the two exit codes, the relabelled buttons,
#      the early-exit hook in main, the lane wiring, the MSI's four custom
#      actions with their conditions and their hand-written sequence numbers -
#      the band between CostFinalize and InstallValidate, ahead of the prepare
#      step - and the Upgrade table's three separate version bands (so
#      "you already have this" is never announced as "a newer version").
#   E  the build-time read-back can say no: the verifier that ships inside
#      build-msi.sh is extracted and fed each broken CustomAction /
#      InstallExecuteSequence / Upgrade table it exists to reject (T1133).
#      Needs python and nothing else - no Docker, no msitools, no MSI.
#   L  the LIVE behaviour, against the real debug build: the dialog actually
#      appears, its buttons actually say Repair and Cancel, and clicking each
#      one leaves the process with the exit code msiexec has to see. L5 is the
#      control - the seam that answers without a dialog agrees with the dialog,
#      so neither half can be passing for the trivial reason.
#
# What is deliberately NOT here: a real msiexec maintenance run. That needs a
# signed, versioned package and would touch the user's installed Ghoztty, which
# is this repo's first non-negotiable. The MSI half is asserted at its source
# and at its build-time read-back; the half that decides what the user actually
# sees and what msiexec is actually told - the dialog and its exit codes - is
# measured live.
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1), so the
# modal dialog never takes the user's foreground.
#
# isolation: partial - launches the repo debug build as a prompt process only.
# It creates no window of the terminal, binds no IPC endpoint and starts no
# agent; every process it starts is tracked by pid on the test desktop.
#
#   powershell -NoProfile -File test\win32\install-maintenance.ps1
#   powershell -NoProfile -File test\win32\install-maintenance.ps1 -TeethCheck

param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    # Re-run every section-A check against a deliberately broken copy of its
    # surface and assert it goes red. Proves the checks measure what they claim.
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
# Section L's dialog is MODAL. It goes up on the background desktop or it goes
# up in front of whatever the user is reading.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')

$script:passes = 0
$script:failures = 0
$script:skipped = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}
function Skip($name, $why) { "  SKIP $name ($why)"; $script:skipped++ }

$paths = [ordered]@{
    maint = 'src\apprt\win32\install_maintenance.zig'
    app   = 'src\apprt\win32\App.zig'
    main  = 'src\main_ghostty.zig'
    agg   = 'src\apprt\win32.zig'
    msi   = 'dist\windows-installer\build-msi.sh'
}

$text = [ordered]@{}
foreach ($k in $paths.Keys) {
    $p = Join-Path $Repo $paths[$k]
    if (-not (Test-Path -LiteralPath $p)) {
        "FATAL: missing $p"
        "1 FAILURE(S)"
        exit 1
    }
    $text[$k] = (Get-Content -LiteralPath $p -Raw)
}

# ---------------------------------------------------------------------------
# A - the shipped shape. Each check is a predicate over file CONTENT so
# -TeethCheck can feed it the mutation it exists to catch.
# ---------------------------------------------------------------------------

# The hand-written sequence numbers of the maintenance band, read out of the wxs
# (T1367). They are written down rather than derived from anchors because wixl
# resolves an After= that names a CUSTOM action by appending to the END of
# InstallExecuteSequence, which is how the Repair/Cancel question came to be
# asked after the install had already run.
function MaintSequence($msi) {
    $n = @{}
    foreach ($m in ([regex]'<Custom Action="([A-Za-z]+)" Sequence="(\d+)"').Matches($msi)) {
        $n[$m.Groups[1].Value] = [int]$m.Groups[2].Value
    }
    return $n
}

$checks = [ordered]@{
    'A1 the prompt is spelled as an argv flag, the way its neighbour is' =
        { param($t) $t.maint -match 'pub const flag = "--install-maintenance";' }
    'A2 Cancel is 1602, the one code msiexec ends quietly on' =
        { param($t) $t.maint -match 'pub const user_exit_code: u32 = 1602;' -and
                    $t.maint -match '(?s)\.cancel => user_exit_code' }
    'A3 Repair is 0, indistinguishable from an action that just succeeded' =
        { param($t) $t.maint -match '(?s)\.repair => 0' }
    'A4 the buttons say what they do' =
        { param($t) $t.maint -match '\.ok_label = std\.unicode\.utf8ToUtf16LeStringLiteral\("Repair"\)' -and
                    $t.maint -match '\.cancel_label = std\.unicode\.utf8ToUtf16LeStringLiteral\("Cancel"\)' }
    'A5 the message leads with the reassurance, not with the repair' =
        { param($t) $t.maint -match 'is already installed, so there is nothing to update' }
    'A6 it uses the standalone dialog - this process has no App behind it' =
        { param($t) $t.maint -match 'ConfirmDialog\.showStandalone\(' }
    'A7 Enter lands on Cancel, so a reflex does not start rewriting files' =
        { param($t) $t.maint -match '\.default_cancel = true,' }
    'A8 the apprt exposes it the way it exposes the prepare step' =
        { param($t) $t.app -match 'pub fn runInstallMaintenance\(alloc: Allocator\) \?u8 \{' }
    'A9 main asks before any window or IPC endpoint exists' =
        { param($t) $t.main -match '(?s)@hasDecl\(apprt\.App, "runInstallMaintenance"\) and state\.action == null' }
    'A10 the module tests are wired into the lane (T1191)' =
        { param($t) $t.agg -match '_ = @import\("win32/install_maintenance\.zig"\);' }
    'A11 the MSI carries the prompt custom action' =
        { param($t) $t.msi -match '<CustomAction Id="MaintenancePrompt"' -and
                    $t.msi -match 'ExeCommand="--install-maintenance --installed-version=\[ARPDISPLAYVERSION\]"' }
    'A12 the prompt is immediate and CHECKS its exit code' =
        { param($t)
          $ca = ([regex]'(?s)<CustomAction Id="MaintenancePrompt".*?/>').Match($t.msi)
          $ca.Success -and $ca.Value -match 'Execute="immediate"' -and $ca.Value -match 'Return="check"' }
    'A13 Repair is pre-armed BEFORE CostFinalize, where feature states are decided' =
        { param($t)
          $n = MaintSequence $t.msi
          ($t.msi -match '<CustomAction Id="SetRepairMode" Property="REINSTALL" Value="ALL"/>') -and
          $n['SetRepairMode'] -gt 0 -and $n['SetRepairMode'] -lt 1000 -and
          $n['SetRepairModeFlags'] -gt 0 -and $n['SetRepairModeFlags'] -lt 1000 }
    'A14 the question is asked after INSTALLDIR resolves and before anything is written (T1367)' =
        { param($t)
          $n = MaintSequence $t.msi
          $n['SetMaintenancePromptCmd'] -gt 1000 -and
          $n['MaintenancePrompt'] -gt $n['SetMaintenancePromptCmd'] -and
          $n['MaintenancePrompt'] -lt $n['PrepareInstallDir'] -and
          $n['PrepareInstallDir'] -lt 1400 }
    'A14b no action in that band anchors on another CUSTOM action (T1367)' =
        { param($t)
          # wixl appends an After= that names a custom action to the end of the
          # table - past InstallFinalize - so the whole band is numbered by hand.
          $band = 'SetRepairMode|SetRepairModeFlags|SetMaintenancePromptCmd|MaintenancePrompt|SetPrepareInstallDirCmd|PrepareInstallDir'
          $rows = ([regex]"(?m)^\s*<Custom Action=`"($band)`"([^>]*)>").Matches($t.msi)
          ($rows.Count -eq 6) -and -not ($rows | Where-Object { $_.Groups[2].Value -notmatch 'Sequence="\d+"' }) }
    'A15 a silent or updater-driven install never sees the dialog' =
        { param($t)
          $rows = ([regex]'(?m)^\s*<Custom Action="(MaintenancePrompt|SetMaintenancePromptCmd|SetRepairMode|SetRepairModeFlags)"[^>]*>(.*?)</Custom>').Matches($t.msi)
          ($rows.Count -eq 4) -and -not ($rows | Where-Object { $_.Groups[2].Value -notmatch 'UILevel &gt; 3' }) }
    'A16 uninstall, patching and being replaced by a newer package are excluded' =
        { param($t)
          $rows = ([regex]'(?m)^\s*<Custom Action="(MaintenancePrompt|SetMaintenancePromptCmd|SetRepairMode|SetRepairModeFlags)"[^>]*>(.*?)</Custom>').Matches($t.msi)
          ($rows.Count -eq 4) -and -not ($rows | Where-Object {
              $_.Groups[2].Value -notmatch 'NOT REMOVE' -or
              $_.Groups[2].Value -notmatch 'NOT PATCH' -or
              $_.Groups[2].Value -notmatch 'NOT UPGRADINGPRODUCTCODE' }) }
    'A17 the same version is its own band, detected separately from a newer one' =
        { param($t) $t.msi -match '(?s)<UpgradeVersion Minimum="@PRODUCT_VERSION@" IncludeMinimum="yes"\s*\n\s*Maximum="@PRODUCT_VERSION@" IncludeMaximum="yes"\s*\n\s*OnlyDetect="yes"\s*\n\s*Property="SAMEVERSIONFOUND"/>' }
    'A18 and the newer band no longer swallows the equal version' =
        { param($t) $t.msi -match '(?s)<UpgradeVersion Minimum="@PRODUCT_VERSION@" IncludeMinimum="no"\s*\n\s*OnlyDetect="yes"\s*\n\s*Property="NEWERVERSIONFOUND"/>' }
    'A19 each band says the true thing rather than the same thing' =
        { param($t) $t.msi -match 'This version of Ghoztty is already installed, so there is nothing to update' -and
                    $t.msi -match '<Condition Message="A newer version of Ghoztty is already installed[^"]*">NOT NEWERVERSIONFOUND</Condition>' }
    'A20 the build reads the whole arrangement back out of the compiled package' =
        { param($t) $t.msi -match 'CustomAction table has no MaintenancePrompt row' -and
                    $t.msi -match 'Upgrade table has no \{prop\} row' }
    'A21 the read-back rejects a prompt whose answer would be ignored' =
        { param($t) $t.msi -match 'ignores its exit code - Cancel would repair anyway' -and
                    $t.msi -match 'is asynchronous - msiexec would not wait for the answer' }
}

$mutations = [ordered]@{
    'A1 the prompt is spelled as an argv flag, the way its neighbour is' =
        @{ Key = 'maint'; Find = 'pub const flag = "--install-maintenance";'; Replace = 'pub const flag = "";' }
    'A2 Cancel is 1602, the one code msiexec ends quietly on' =
        @{ Key = 'maint'; Find = 'pub const user_exit_code: u32 = 1602;'; Replace = 'pub const user_exit_code: u32 = 1;' }
    'A3 Repair is 0, indistinguishable from an action that just succeeded' =
        @{ Key = 'maint'; Find = '.repair => 0'; Replace = '.repair => 3' }
    'A4 the buttons say what they do' =
        @{ Key = 'maint'; Find = '.ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Repair")'
           Replace = '.ok_label = std.unicode.utf8ToUtf16LeStringLiteral("OK")' }
    'A5 the message leads with the reassurance, not with the repair' =
        @{ Key = 'maint'; Find = 'is already installed, so there is nothing to update'; Replace = 'cannot be installed' }
    'A6 it uses the standalone dialog - this process has no App behind it' =
        @{ Key = 'maint'; Find = 'ConfirmDialog.showStandalone('; Replace = 'ConfirmDialog.show(' }
    'A7 Enter lands on Cancel, so a reflex does not start rewriting files' =
        @{ Key = 'maint'; Find = '.default_cancel = true,'; Replace = '.default_cancel = false,' }
    'A8 the apprt exposes it the way it exposes the prepare step' =
        @{ Key = 'app'; Find = 'pub fn runInstallMaintenance(alloc: Allocator) ?u8 {'
           Replace = 'fn unusedMaintenance(alloc: Allocator) ?u8 {' }
    'A9 main asks before any window or IPC endpoint exists' =
        @{ Key = 'main'; Find = '@hasDecl(apprt.App, "runInstallMaintenance")'; Replace = '@hasDecl(apprt.App, "runNothing")' }
    'A10 the module tests are wired into the lane (T1191)' =
        @{ Key = 'agg'; Find = '_ = @import("win32/install_maintenance.zig");'; Replace = '' }
    'A11 the MSI carries the prompt custom action' =
        @{ Key = 'msi'; Find = 'ExeCommand="--install-maintenance --installed-version=[ARPDISPLAYVERSION]"'; Replace = 'ExeCommand=""' }
    'A12 the prompt is immediate and CHECKS its exit code' =
        @{ Key = 'msi'; Find = "                  Execute=`"immediate`"`n                  Return=`"check`"/>"
           Replace = "                  Execute=`"immediate`"`n                  Return=`"ignore`"/>" }
    'A13 Repair is pre-armed BEFORE CostFinalize, where feature states are decided' =
        @{ Key = 'msi'; Find = '<Custom Action="SetRepairMode" Sequence="990">'
           Replace = '<Custom Action="SetRepairMode" Sequence="1200">' }
    'A14 the question is asked after INSTALLDIR resolves and before anything is written (T1367)' =
        @{ Key = 'msi'; Find = '<Custom Action="MaintenancePrompt" Sequence="1020">'
           Replace = '<Custom Action="MaintenancePrompt" Sequence="1050">' }
    'A14b no action in that band anchors on another CUSTOM action (T1367)' =
        @{ Key = 'msi'; Find = '<Custom Action="MaintenancePrompt" Sequence="1020">'
           Replace = '<Custom Action="MaintenancePrompt" After="SetMaintenancePromptCmd">' }
    'A15 a silent or updater-driven install never sees the dialog' =
        @{ Key = 'msi'; Find = '<Custom Action="MaintenancePrompt" Sequence="1020">Installed AND NOT REMOVE AND NOT PATCH AND NOT UPGRADINGPRODUCTCODE AND UILevel &gt; 3</Custom>'
           Replace = '<Custom Action="MaintenancePrompt" Sequence="1020">Installed AND NOT REMOVE AND NOT PATCH AND NOT UPGRADINGPRODUCTCODE</Custom>' }
    'A16 uninstall, patching and being replaced by a newer package are excluded' =
        @{ Key = 'msi'; Find = '<Custom Action="SetRepairMode" Sequence="990">Installed AND NOT REMOVE AND NOT PATCH AND NOT UPGRADINGPRODUCTCODE AND UILevel &gt; 3</Custom>'
           Replace = '<Custom Action="SetRepairMode" Sequence="990">Installed AND UILevel &gt; 3</Custom>' }
    'A17 the same version is its own band, detected separately from a newer one' =
        @{ Key = 'msi'; Find = 'Property="SAMEVERSIONFOUND"/>'; Replace = 'Property="NEWERVERSIONFOUND"/>' }
    'A18 and the newer band no longer swallows the equal version' =
        @{ Key = 'msi'; Find = '<UpgradeVersion Minimum="@PRODUCT_VERSION@" IncludeMinimum="no"'
           Replace = '<UpgradeVersion Minimum="@PRODUCT_VERSION@" IncludeMinimum="yes"' }
    'A19 each band says the true thing rather than the same thing' =
        @{ Key = 'msi'; Find = 'This version of Ghoztty is already installed, so there is nothing to update'
           Replace = 'A newer version of Ghoztty is already installed' }
    'A20 the build reads the whole arrangement back out of the compiled package' =
        @{ Key = 'msi'; Find = 'CustomAction table has no MaintenancePrompt row'; Replace = 'warning only' }
    'A21 the read-back rejects a prompt whose answer would be ignored' =
        @{ Key = 'msi'; Find = 'ignores its exit code - Cancel would repair anyway'; Replace = 'is fine' }
}

if ($TeethCheck) {
    "== install-maintenance -TeethCheck: each check, fed the state it exists to catch =="
    foreach ($name in $checks.Keys) {
        if (-not $mutations.Contains($name)) {
            "  FAIL $name (no mutation declared)"; $script:failures++; continue
        }
        $m = $mutations[$name]
        $poisoned = [ordered]@{}
        foreach ($k in $text.Keys) { $poisoned[$k] = $text[$k] }
        if (-not $text[$m.Key].Contains($m.Find)) {
            "  FAIL $name (mutation target not present: $($m.Find))"; $script:failures++; continue
        }
        $poisoned[$m.Key] = $text[$m.Key].Replace($m.Find, $m.Replace)
        if (& $checks[$name] $poisoned) { "  FAIL $name (mutation not caught)"; $script:failures++ }
        else { "  PASS $name (caught)"; $script:passes++ }
    }
    ""
    if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
    exit ([int]($script:failures -gt 0))
}

"== install-maintenance A: the shipped tree =="
foreach ($name in $checks.Keys) { Assert $name (& $checks[$name] $text) }

"== install-maintenance A: every check has a demonstration =="
$missing = @($checks.Keys | Where-Object { -not $mutations.Contains($_) })
Assert "A22 no check ships without a mutation (-TeethCheck covers all $($checks.Count))" ($missing.Count -eq 0)
if ($missing.Count -gt 0) { $missing | ForEach-Object { "       undemonstrated: $_" } }

# ---------------------------------------------------------------------------
# E - the build-time read-back, watched failing. Section A proves the verifier
# is WIRED; this proves it can say no. The code under test is extracted from
# build-msi.sh itself, so what is demonstrated is what ships, and it is fed
# synthetic tables rather than a real MSI - which is what makes the
# demonstration runnable on a box with no Docker and no msitools.
# ---------------------------------------------------------------------------
"== install-maintenance E: the maintenance gate, fed each MSI it must reject =="
$py = $null
foreach ($cand in @('python', 'python3', 'py')) {
    if (-not (Get-Command $cand -ErrorAction SilentlyContinue)) { continue }
    $probe = & $cand -V 2>&1
    if ($LASTEXITCODE -eq 0 -and "$probe" -match '^Python 3') { $py = $cand; break }
}
if (-not $py) {
    Skip 'E  maintenance gate demonstration' 'no python interpreter on PATH'
} else {
    $verifier = ([regex]'(?ms)^python3 - "\$WORK/CustomAction\.idt" "\$WORK/InstallExecuteSequence\.idt" "\$WORK/Upgrade\.idt".*?\n(.*?)\nPYEOF$').Match($text.msi)
    if (-not $verifier.Success) {
        Assert 'E0 the maintenance verifier is extractable from build-msi.sh' $false
    } else {
        $tmpE = Join-Path ([System.IO.Path]::GetTempPath()) ("install-maintenance-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpE | Out-Null
        try {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            function Put($name, $body) {
                $p = Join-Path $tmpE $name
                [System.IO.File]::WriteAllText($p, $body, $utf8)
                return $p
            }
            $vp = Put 'verify.py' $verifier.Groups[1].Value
            $t = "`t"
            $cond = 'Installed AND NOT REMOVE AND NOT PATCH AND NOT UPGRADINGPRODUCTCODE AND UILevel > 3'

            # A correctly wired package, in .idt shape: three header lines then
            # rows. CustomAction is Action/Type/Source/Target; sequence tables
            # are Action/Condition/Sequence; Upgrade is UpgradeCode/VersionMin/
            # VersionMax/Language/Attributes/Remove/ActionProperty.
            $goodCa = @(
                "Action${t}Type${t}Source${t}Target",
                "s72${t}i2${t}S72${t}S255",
                "CustomAction${t}Action",
                "SetRepairMode${t}51${t}REINSTALL${t}ALL",
                "SetRepairModeFlags${t}51${t}REINSTALLMODE${t}amus",
                "SetMaintenancePromptCmd${t}51${t}MAINTENANCEPROMPTCMD${t}[INSTALLDIR]ghoztty.exe",
                "MaintenancePrompt${t}50${t}MAINTENANCEPROMPTCMD${t}--install-maintenance --installed-version=[ARPDISPLAYVERSION]"
            ) -join "`r`n"
            # CostFinalize sits at 1000 in the standard sequence and
            # InstallValidate at 1400; the arming rows are below the first and
            # the whole question sits between them, ahead of the prepare step,
            # so every ordering check has something real to compare (T1367).
            $goodSeq = @(
                "Action${t}Condition${t}Sequence",
                "s72${t}S255${t}I2",
                "InstallExecuteSequence${t}Action",
                "SetRepairMode${t}$cond${t}990",
                "SetRepairModeFlags${t}$cond${t}991",
                "CostFinalize${t}${t}1000",
                "SetMaintenancePromptCmd${t}$cond${t}1010",
                "MaintenancePrompt${t}$cond${t}1020",
                "PrepareInstallDir${t}Installed OR OLDERVERSIONFOUND${t}1040",
                "InstallValidate${t}${t}1400"
            ) -join "`r`n"
            $goodUp = @(
                "UpgradeCode${t}VersionMin${t}VersionMax${t}Language${t}Attributes${t}Remove${t}ActionProperty",
                "s38${t}S20${t}S20${t}S255${t}i4${t}S255${t}s72",
                "Upgrade${t}UpgradeCode",
                "{GUID}${t}0.0.0${t}26.9.301${t}${t}256${t}${t}OLDERVERSIONFOUND",
                "{GUID}${t}26.9.301${t}26.9.301${t}${t}770${t}${t}SAMEVERSIONFOUND",
                "{GUID}${t}26.9.301${t}${t}${t}2${t}${t}NEWERVERSIONFOUND"
            ) -join "`r`n"

            function RunVerifier($ca, $seq, $up) {
                $f1 = Put ("ca-" + [guid]::NewGuid().ToString('N') + '.idt') $ca
                $f2 = Put ("seq-" + [guid]::NewGuid().ToString('N') + '.idt') $seq
                $f3 = Put ("up-" + [guid]::NewGuid().ToString('N') + '.idt') $up
                & $py $vp $f1 $f2 $f3 2>&1 | Out-Null
                return $LASTEXITCODE
            }
            function DropRow($table, $action) {
                return (($table -split "`r`n" | Where-Object { $_ -notmatch "^$action`t" }) -join "`r`n")
            }

            Assert 'E1 a correctly wired MSI passes' `
                ((RunVerifier $goodCa $goodSeq $goodUp) -eq 0)
            Assert 'E2 an MSI with no MaintenancePrompt - the silent one - is rejected' `
                ((RunVerifier (DropRow $goodCa 'MaintenancePrompt') (DropRow $goodSeq 'MaintenancePrompt') $goodUp) -ne 0)
            Assert 'E3 a prompt that IGNORES its answer, so Cancel repairs anyway, is rejected' `
                ((RunVerifier ($goodCa -replace "MaintenancePrompt${t}50", "MaintenancePrompt${t}114") $goodSeq $goodUp) -ne 0)
            Assert 'E4 an ASYNCHRONOUS prompt, which nobody waits for, is rejected' `
                ((RunVerifier ($goodCa -replace "MaintenancePrompt${t}50", "MaintenancePrompt${t}178") $goodSeq $goodUp) -ne 0)
            Assert 'E5 a prompt that runs the wrong command is rejected' `
                ((RunVerifier ($goodCa -replace '--install-maintenance', '--version') $goodSeq $goodUp) -ne 0)
            Assert 'E6 an unconditional prompt - one a silent install would hit - is rejected' `
                ((RunVerifier $goodCa ($goodSeq -replace [regex]::Escape($cond), '1') $goodUp) -ne 0)
            Assert 'E7 a prompt sequenced BEFORE CostFinalize, with no INSTALLDIR yet, is rejected' `
                ((RunVerifier $goodCa ($goodSeq -replace "MaintenancePrompt${t}$([regex]::Escape($cond))${t}1020", "MaintenancePrompt${t}$cond${t}900") $goodUp) -ne 0)
            Assert 'E8 REINSTALL armed AFTER CostFinalize, where Repair would do nothing, is rejected' `
                ((RunVerifier $goodCa ($goodSeq -replace "SetRepairMode${t}$([regex]::Escape($cond))${t}990", "SetRepairMode${t}$cond${t}1200") $goodUp) -ne 0)
            Assert 'E9 an MSI that never arms REINSTALL at all is rejected' `
                ((RunVerifier (DropRow $goodCa 'SetRepairMode') (DropRow $goodSeq 'SetRepairMode') $goodUp) -ne 0)
            Assert 'E10 a prompt with no command property set is rejected' `
                ((RunVerifier (DropRow $goodCa 'SetMaintenancePromptCmd') (DropRow $goodSeq 'SetMaintenancePromptCmd') $goodUp) -ne 0)
            Assert 'E11 an Upgrade table with no equal-version band is rejected' `
                ((RunVerifier $goodCa $goodSeq (DropRow $goodUp '\{GUID\}\t26\.9\.301\t26\.9\.301')) -ne 0)
            Assert 'E12 a NEWERVERSIONFOUND that swallows the equal version is rejected' `
                ((RunVerifier $goodCa $goodSeq ($goodUp -replace "26\.9\.301${t}${t}${t}2${t}", "26.9.301${t}${t}${t}258${t}")) -ne 0)
            # T1367. 6605 is not a number anybody chose: it is where wixl puts an
            # action whose only anchor is an After= naming another custom action,
            # which is past InstallFinalize. The old check said "after
            # CostFinalize" and the end of the table satisfies that, so the
            # question was asked once the install had run and Cancel cancelled
            # nothing. These three are the shapes that hole let through.
            Assert 'E13 a prompt appended past InstallValidate - asked after the install ran - is rejected' `
                ((RunVerifier $goodCa ($goodSeq -replace "MaintenancePrompt${t}$([regex]::Escape($cond))${t}1020", "MaintenancePrompt${t}$cond${t}6605") $goodUp) -ne 0)
            Assert 'E14 a prompt asked AFTER the prepare step has renamed the agent aside is rejected' `
                ((RunVerifier $goodCa ($goodSeq -replace "MaintenancePrompt${t}$([regex]::Escape($cond))${t}1020", "MaintenancePrompt${t}$cond${t}1300") $goodUp) -ne 0)
            Assert 'E15 a sequence table with no InstallValidate to measure against is rejected' `
                ((RunVerifier $goodCa (DropRow $goodSeq 'InstallValidate') $goodUp) -ne 0)
        } finally {
            Remove-Item -LiteralPath $tmpE -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# L - the live half. The real debug exe, on a background desktop, with nobody
# clicking anything by hand. This is the part that decides what the user SEES
# and what msiexec is TOLD, and neither can be read off the source.
# ---------------------------------------------------------------------------
# The live half runs only against a real build. The try stays at the TOP level
# either way, so `Complete-TestBody` is reachable by this script's own flow - a
# marker buried inside a conditional is one an unwind can skip (T1039, and
# lib\BodyCompleteAudit.ps1 enforces it).
$live = Test-Path -LiteralPath $Exe
if (-not $live) {
    Skip 'L  live prompt and exit codes' "$Exe not found - build it first"
}
if ($live) {
    [void](Set-GhozttyTestIsolation -Tag 'instmaint')
    Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
    Register-RepoBuildTeardown -Exe $Exe | Out-Null
    New-TestDesktop | Out-Null
}
try {
    if ($live) {
        "== install-maintenance L: the dialog and its exit codes, live =="
        # Runs the prompt with no -Answer seam and returns what happened:
        # the button captions it offered, and the exit code pressing $Press
        # left behind.
        function Invoke-LivePrompt([string]$Press) {
            $started = Start-OnTestDesktop -Exe $Exe `
                -Arguments @('--install-maintenance', '--installed-version=9.9.9')
            # Touch .Handle while the child is still alive. A Process object
            # that never cached its handle answers ExitCode with nothing once
            # the process is gone, and an empty exit code compared against 0
            # is a quiet FAIL rather than an error.
            try { $null = $started.Process.Handle } catch { }
            $dlg = Wait-TestWindow -ProcessId $started.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 30000
            # Read every caption BEFORE pressing anything: the press dismisses
            # the dialog, and a button read after that answers with the empty
            # string rather than its label.
            $labels = @()
            $target = [IntPtr]::Zero
            if ($dlg -ne [IntPtr]::Zero) {
                foreach ($b in (Get-TestChildWindows -Window $dlg -Class 'Button')) {
                    $cap = Get-TestControlText -Control ([IntPtr]$b.Hwnd)
                    $labels += $cap
                    if ($cap -eq $Press) { $target = [IntPtr]$b.Hwnd }
                }
            }
            $pressed = $false
            if ($target -ne [IntPtr]::Zero) {
                Send-TestControlClick -Control $target | Out-Null
                $pressed = $true
            }
            $code = $null
            if ($started.Process) {
                if ($started.Process.WaitForExit(20000)) { $code = $started.Process.ExitCode }
            }
            if ($null -eq $code) { Stop-Process -Id $started.Pid -Force -ErrorAction SilentlyContinue }
            return [pscustomobject]@{ Dialog = $dlg; Labels = $labels; Pressed = $pressed; ExitCode = $code }
        }

        $repair = Invoke-LivePrompt 'Repair'
        Assert 'L1 the installer prompt actually puts a dialog on screen' `
            ($repair.Dialog -ne [IntPtr]::Zero)
        Assert 'L2 its buttons say Repair and Cancel' `
            ((($repair.Labels | Sort-Object) -join '|') -eq 'Cancel|Repair')
        if ((($repair.Labels | Sort-Object) -join '|') -ne 'Cancel|Repair') {
            "       buttons seen: [$($repair.Labels -join '] [')]"
        }
        Assert 'L3 pressing Repair leaves msiexec a plain success (0)' `
            ($repair.Pressed -and $repair.ExitCode -eq 0)
        if (-not ($repair.Pressed -and $repair.ExitCode -eq 0)) {
            "       pressed=$($repair.Pressed) exit=$($repair.ExitCode)"
        }

        $cancel = Invoke-LivePrompt 'Cancel'
        Assert 'L4 pressing Cancel leaves msiexec ERROR_INSTALL_USEREXIT (1602)' `
            ($cancel.Pressed -and $cancel.ExitCode -eq 1602)

        # The control. If the seam and the dialog ever disagreed, the two
        # sections above would be measuring different code paths, and the
        # cheap one would be the one anybody reached for next.
        $seamRepair = Invoke-OnTestDesktop -Exe $Exe `
            -Arguments @('--install-maintenance', '--answer=repair') -TimeoutSec 60
        $seamCancel = Invoke-OnTestDesktop -Exe $Exe `
            -Arguments @('--install-maintenance', '--answer=cancel') -TimeoutSec 60
        Assert 'L5 the answer seam agrees with the buttons (0 and 1602, no dialog)' `
            ((-not $seamRepair.TimedOut) -and ($seamRepair.ExitCode -eq 0) -and
             (-not $seamCancel.TimedOut) -and ($seamCancel.ExitCode -eq 1602))

        # And an ordinary start is still an ordinary start: the flag parser is
        # the thing standing between this feature and a terminal that opens a
        # repair dialog instead of a shell.
        $version = Invoke-OnTestDesktop -Exe $Exe -Arguments @('+version') -TimeoutSec 60
        Assert 'L6 a start WITHOUT the flag is untouched by any of this' `
            ((-not $version.TimedOut) -and ($version.ExitCode -eq 0) -and
             ($version.Output -match 'version'))
    }

    # LAST statement of the top-level try (T1039): the body reached its end, so
    # a green verdict below is about the whole harness rather than about
    # however much of it happened before something threw.
    Complete-TestBody
} finally {
    if ($live) { Remove-TestDesktop | Out-Null }
}

# --- stamp (T783) ----------------------------------------------------------
# A clean green run stamps the files this harness covers. A run with a SKIP did
# not cover everything, so it does not stamp.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard install-maintenance -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'install-maintenance' -MinPass 30
