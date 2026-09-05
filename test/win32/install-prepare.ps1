# An upgrade must not kill the sessions it exists to preserve (T1207).
#
# THE DEFECT this covers: your terminals survive Ghoztty closing because
# `ghoztty-agent.exe` and one `--pty-host` holder per session keep the shells
# running. Those processes have no windows. The Restart Manager only offers a
# graceful close to processes that HAVE one - for everything else its only move
# is to terminate. So a double-clicked MSI over a running Ghoztty would end
# every restored session, which is exactly what session persistence exists to
# prevent. T1204 fixed the APP half of this (it registers for restart and exits
# politely); the agent and its holders could not be fixed the same way.
#
# The fix under test: the package runs `ghoztty.exe --install-prepare` out of
# the OLD install immediately BEFORE InstallValidate - the action where Windows
# Installer asks the Restart Manager who holds the files it is about to write.
# That step renames `ghoztty-agent.exe` aside. Windows refuses to delete or
# overwrite a running image but will happily rename one, and the open handles
# follow the file - so the holders keep running, the package's own agent path is
# unheld, and there is nothing left for the Restart Manager to shut down.
#
# What this asserts:
#
#   A  the shipped shape: the prepare module's flag, its image list (the agent,
#      and pointedly NOT the app, which the Restart Manager closes gracefully),
#      the early-exit hook in main, the lane wiring, and the MSI's custom action
#      with its condition and its position before InstallValidate.
#   E  the build-time read-back can say no: the verifier that ships inside
#      build-msi.sh is extracted and fed each broken CustomAction /
#      InstallExecuteSequence table it exists to reject (T1133). Needs python
#      and nothing else - no Docker, no msitools, no MSI.
#   L  the LIVE behaviour, against the real debug build: a real windowless
#      `ghoztty-agent.exe --pty-host` holder is started out of a THROWAWAY
#      directory, `ghoztty.exe --install-prepare --install-dir=<that dir>` is
#      run against it, and the three things that decide whether an upgrade is
#      survivable are measured - the image moved aside, the holder still
#      running, and the original path free for an installer to write. L6/L7 are
#      the controls: an unlocked image is left alone (no churn on an ordinary
#      install) and a sideline something is STILL running out of is not swept,
#      so neither half of the rule can be passing for the trivial reason.
#
# What is deliberately NOT here: a real msiexec install. That needs a signed,
# versioned package and would replace the user's installed Ghoztty, which is
# this repo's first non-negotiable. The MSI half is asserted at its source and
# at its build-time read-back; the half that actually decides whether the user's
# shells live - the rename, with a real holder running out of the file - is
# measured live.
#
# isolation: partial - runs the repo debug build's prepare step against a
# throwaway directory under $env:TEMP. No window, no IPC endpoint, no agent
# pipe: the holder is bound to a per-run session id and killed by PID.
#
#   powershell -NoProfile -File test\win32\install-prepare.ps1
#   powershell -NoProfile -File test\win32\install-prepare.ps1 -TeethCheck

param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # Re-run every section-A check against a deliberately broken copy of its
    # surface and assert it goes red. Proves the checks measure what they claim.
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
# T1241: section L's holder and prepare steps run on the background test
# desktop, not the user's.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:passes = 0
$script:failures = 0
$script:skipped = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}
function Skip($name, $why) { "  SKIP $name ($why)"; $script:skipped++ }

$paths = [ordered]@{
    prep = 'src\apprt\win32\install_prepare.zig'
    app  = 'src\apprt\win32\App.zig'
    main = 'src\main_ghostty.zig'
    agg  = 'src\apprt\win32.zig'
    msi  = 'dist\windows-installer\build-msi.sh'
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

$checks = [ordered]@{
    'A1 the prepare step is spelled as an argv flag, not an env var' =
        { param($t) $t.prep -match 'pub const flag = "--install-prepare";' }
    'A2 the agent image is what gets moved aside' =
        { param($t) $t.prep -match '(?s)pub const sideline_images = \[_\]\[\]const u8\{[^}]*"ghoztty-agent\.exe"' }
    'A3 and the app image is NOT - the Restart Manager closes that one' =
        { param($t)
          $decl = ([regex]'(?s)pub const sideline_images = \[_\]\[\]const u8\{(.*?)\};').Match($t.prep)
          $decl.Success -and ($decl.Groups[1].Value -notmatch '"ghoztty\.exe"') }
    'A4 an in-use image is RENAMED, never deleted or killed' =
        { param($t) $t.prep -match 'renameAbsolute' -and $t.prep -notmatch 'TerminateProcess' }
    'A5 only a locked image is touched, so a normal install churns nothing' =
        { param($t) $t.prep -match '(?m)^\s*if \(!isLocked\(path\)\) continue;' }
    'A6 nothing here can fail the install' =
        { param($t) $t.prep -match '(?m)^\s*return 0;' -and $t.prep -notmatch 'std\.process\.exit\(1\)' }
    'A7 the apprt exposes it the way it exposes the update applier' =
        { param($t) $t.app -match 'pub fn runInstallPrepare\(alloc: Allocator\) \?u8 \{' }
    'A8 main asks before any window or IPC endpoint exists' =
        { param($t) $t.main -match '(?s)@hasDecl\(apprt\.App, "runInstallPrepare"\) and state\.action == null' }
    'A9 the module tests are wired into the lane (T1191)' =
        { param($t) $t.agg -match '_ = @import\("win32/install_prepare\.zig"\);' }
    'A10 the MSI carries the prepare custom action' =
        { param($t) $t.msi -match '<CustomAction Id="PrepareInstallDir"' -and
                    $t.msi -match 'ExeCommand="--install-prepare"' }
    'A11 it runs BEFORE InstallValidate, where the holders would be chosen' =
        { param($t)
          # An explicit number rather than Before="InstallValidate" since T1367:
          # wixl orders two customs anchored on the same standard action by hash
          # iteration, and this one has to follow the Repair/Cancel prompt.
          $m = ([regex]'<Custom Action="PrepareInstallDir" Sequence="(\d+)"').Match($t.msi)
          $m.Success -and [int]$m.Groups[1].Value -lt 1400 }
    'A12 it is immediate and ignores its exit code' =
        { param($t)
          $ca = ([regex]'(?s)<CustomAction Id="PrepareInstallDir".*?/>').Match($t.msi)
          $ca.Success -and $ca.Value -match 'Execute="immediate"' -and $ca.Value -match 'Return="ignore"' }
    'A13 it only fires when there is an existing install in the way' =
        { param($t) $t.msi -match '<Custom Action="PrepareInstallDir" Sequence="\d+">Installed OR OLDERVERSIONFOUND</Custom>' }
    'A14 the build reads the action back out of the compiled package' =
        { param($t) $t.msi -match 'CustomAction table has no PrepareInstallDir row' }
    'A15 the read-back rejects a deferred or asynchronous prepare step' =
        { param($t) $t.msi -match 'is deferred - a deferred action runs after InstallValidate' -and
                    $t.msi -match 'is asynchronous - it must finish before InstallValidate' }
}

$mutations = [ordered]@{
    'A1 the prepare step is spelled as an argv flag, not an env var' =
        @{ Key = 'prep'; Find = 'pub const flag = "--install-prepare";'; Replace = 'pub const flag = "";' }
    'A2 the agent image is what gets moved aside' =
        @{ Key = 'prep'; Find = '"ghoztty-agent.exe"'; Replace = '"nothing.exe"' }
    'A3 and the app image is NOT - the Restart Manager closes that one' =
        @{ Key = 'prep'; Find = 'pub const sideline_images = [_][]const u8{"ghoztty-agent.exe"};'
           Replace = 'pub const sideline_images = [_][]const u8{ "ghoztty-agent.exe", "ghoztty.exe" };' }
    'A4 an in-use image is RENAMED, never deleted or killed' =
        @{ Key = 'prep'; Find = 'renameAbsolute'; Replace = 'TerminateProcess' }
    'A5 only a locked image is touched, so a normal install churns nothing' =
        @{ Key = 'prep'; Find = '        if (!isLocked(path)) continue;'; Replace = '' }
    'A6 nothing here can fail the install' =
        @{ Key = 'prep'; Find = '    return 0;'; Replace = '    std.process.exit(1);' }
    'A7 the apprt exposes it the way it exposes the update applier' =
        @{ Key = 'app'; Find = 'pub fn runInstallPrepare(alloc: Allocator) ?u8 {'; Replace = 'fn unusedPrepare(alloc: Allocator) ?u8 {' }
    'A8 main asks before any window or IPC endpoint exists' =
        @{ Key = 'main'; Find = '@hasDecl(apprt.App, "runInstallPrepare")'; Replace = '@hasDecl(apprt.App, "runNothing")' }
    'A9 the module tests are wired into the lane (T1191)' =
        @{ Key = 'agg'; Find = '_ = @import("win32/install_prepare.zig");'; Replace = '' }
    'A10 the MSI carries the prepare custom action' =
        @{ Key = 'msi'; Find = 'ExeCommand="--install-prepare"'; Replace = 'ExeCommand=""' }
    'A11 it runs BEFORE InstallValidate, where the holders would be chosen' =
        @{ Key = 'msi'; Find = '<Custom Action="PrepareInstallDir" Sequence="1040">'
           Replace = '<Custom Action="PrepareInstallDir" Sequence="1450">' }
    'A12 it is immediate and ignores its exit code' =
        @{ Key = 'msi'; Find = 'Return="ignore"'; Replace = 'Return="check"' }
    'A13 it only fires when there is an existing install in the way' =
        @{ Key = 'msi'; Find = 'Sequence="1040">Installed OR OLDERVERSIONFOUND</Custom>'
           Replace = 'Sequence="1040">1</Custom>' }
    'A14 the build reads the action back out of the compiled package' =
        @{ Key = 'msi'; Find = 'CustomAction table has no PrepareInstallDir row'; Replace = 'warning only' }
    'A15 the read-back rejects a deferred or asynchronous prepare step' =
        @{ Key = 'msi'; Find = 'is deferred - a deferred action runs after InstallValidate'; Replace = 'is fine' }
}

if ($TeethCheck) {
    "== install-prepare -TeethCheck: each check, fed the state it exists to catch =="
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

"== install-prepare A: the shipped tree =="
foreach ($name in $checks.Keys) { Assert $name (& $checks[$name] $text) }

"== install-prepare A: every check has a demonstration =="
$missing = @($checks.Keys | Where-Object { -not $mutations.Contains($_) })
Assert "A16 no check ships without a mutation (-TeethCheck covers all $($checks.Count))" ($missing.Count -eq 0)
if ($missing.Count -gt 0) { $missing | ForEach-Object { "       undemonstrated: $_" } }

# ---------------------------------------------------------------------------
# E - the build-time read-back, watched failing. Section A proves the verifier
# is WIRED; this proves it can say no. The code under test is extracted from
# build-msi.sh itself, so what is demonstrated is what ships, and it is fed
# synthetic tables rather than a real MSI - which is what makes the
# demonstration runnable on a box with no Docker and no msitools.
# ---------------------------------------------------------------------------
"== install-prepare E: the custom-action gate, fed each MSI it must reject =="
$py = $null
foreach ($cand in @('python', 'python3', 'py')) {
    if (-not (Get-Command $cand -ErrorAction SilentlyContinue)) { continue }
    $probe = & $cand -V 2>&1
    if ($LASTEXITCODE -eq 0 -and "$probe" -match '^Python 3') { $py = $cand; break }
}
if (-not $py) {
    Skip 'E  custom-action gate demonstration' 'no python interpreter on PATH'
} else {
    $verifier = ([regex]'(?ms)^python3 - "\$WORK/CustomAction\.idt" "\$WORK/InstallExecuteSequence\.idt".*?\n(.*?)\nPYEOF$').Match($text.msi)
    if (-not $verifier.Success) {
        Assert 'E0 the custom-action verifier is extractable from build-msi.sh' $false
    } else {
        $tmpE = Join-Path ([System.IO.Path]::GetTempPath()) ("install-prepare-" + [guid]::NewGuid().ToString('N'))
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

            # A correctly wired package, in .idt shape: three header lines then
            # rows. CustomAction is Action/Type/Source/Target; sequence tables
            # are Action/Condition/Sequence.
            $goodCa = @(
                "Action${t}Type${t}Source${t}Target",
                "s72${t}i2${t}S72${t}S255",
                "CustomAction${t}Action",
                "SetLaunchAppCmd${t}51${t}LAUNCHAPPCMD${t}[INSTALLDIR]ghoztty.exe",
                "LaunchApp${t}242${t}LAUNCHAPPCMD${t}",
                "SetPrepareInstallDirCmd${t}51${t}PREPAREINSTALLDIRCMD${t}[INSTALLDIR]ghoztty.exe",
                "PrepareInstallDir${t}114${t}PREPAREINSTALLDIRCMD${t}--install-prepare"
            ) -join "`r`n"
            $goodSeq = @(
                "Action${t}Condition${t}Sequence",
                "s72${t}S255${t}I2",
                "InstallExecuteSequence${t}Action",
                "SetPrepareInstallDirCmd${t}${t}1398",
                "PrepareInstallDir${t}Installed OR OLDERVERSIONFOUND${t}1399",
                "InstallValidate${t}${t}1400",
                "InstallFinalize${t}${t}6600",
                "SetLaunchAppCmd${t}${t}6601",
                "LaunchApp${t}NOT Installed AND NOT OLDERVERSIONFOUND AND UILevel > 3 AND LAUNCHAPP = `"1`"${t}6602"
            ) -join "`r`n"

            function RunVerifier($ca, $seq) {
                $f1 = Put ("ca-" + [guid]::NewGuid().ToString('N') + '.idt') $ca
                $f2 = Put ("seq-" + [guid]::NewGuid().ToString('N') + '.idt') $seq
                & $py $vp $f1 $f2 2>&1 | Out-Null
                return $LASTEXITCODE
            }
            function DropRow($table, $action) {
                return (($table -split "`r`n" | Where-Object { $_ -notmatch "^$action`t" }) -join "`r`n")
            }

            Assert 'E1 a correctly wired MSI passes' ((RunVerifier $goodCa $goodSeq) -eq 0)
            Assert 'E2 an MSI with no PrepareInstallDir action is rejected' `
                ((RunVerifier (DropRow $goodCa 'PrepareInstallDir') (DropRow $goodSeq 'PrepareInstallDir')) -ne 0)
            Assert 'E3 a prepare step sequenced AFTER InstallValidate is rejected' `
                ((RunVerifier $goodCa ($goodSeq -replace 'PrepareInstallDir\tInstalled OR OLDERVERSIONFOUND\t1399', "PrepareInstallDir${t}Installed OR OLDERVERSIONFOUND${t}1500")) -ne 0)
            Assert 'E4 a DEFERRED prepare step - which would run too late - is rejected' `
                ((RunVerifier ($goodCa -replace 'PrepareInstallDir\t114', "PrepareInstallDir${t}1138") $goodSeq) -ne 0)
            Assert 'E5 an ASYNCHRONOUS prepare step - which would not finish in time - is rejected' `
                ((RunVerifier ($goodCa -replace 'PrepareInstallDir\t114', "PrepareInstallDir${t}242") $goodSeq) -ne 0)
            Assert 'E6 a prepare step whose failure would fail the install is rejected' `
                ((RunVerifier ($goodCa -replace 'PrepareInstallDir\t114', "PrepareInstallDir${t}50") $goodSeq) -ne 0)
            Assert 'E7 a prepare step that runs the wrong command is rejected' `
                ((RunVerifier ($goodCa -replace '--install-prepare', '--version') $goodSeq) -ne 0)
            Assert 'E8 an unconditional prepare step is rejected' `
                ((RunVerifier $goodCa ($goodSeq -replace 'Installed OR OLDERVERSIONFOUND', '1')) -ne 0)
            Assert 'E9 a prepare step with no command property set is rejected' `
                ((RunVerifier (DropRow $goodCa 'SetPrepareInstallDirCmd') (DropRow $goodSeq 'SetPrepareInstallDirCmd')) -ne 0)
        } finally {
            Remove-Item -LiteralPath $tmpE -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# L - the live half. A real windowless holder, out of a throwaway directory.
# ---------------------------------------------------------------------------
"== install-prepare L: a real holder, and an installer's path cleared around it =="

if (-not (Test-Path -LiteralPath $Exe)) {
    Skip 'L  live prepare against a running holder' "no debug build at $Exe"
} elseif (-not (Test-Path -LiteralPath $AgentExe)) {
    Skip 'L  live prepare against a running holder' "no agent build at $AgentExe"
} else {
    # A release zig-out derives the USER's endpoints and state directory
    # (T350), and this section starts a real agent holder - so refuse one before
    # anything is launched rather than after.
    Assert-GhozttyIsolatedBuild -Exe $Exe

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("install-prepare-live-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $holder = $null
    $td = New-TestDesktop
    try {
        # The throwaway "install": a copy of the agent under the name an
        # installer would replace, plus a stale sideline for the sweep control.
        $agentPath = Join-Path $root 'ghoztty-agent.exe'
        Copy-Item -LiteralPath $AgentExe -Destination $agentPath -Force
        $stale = Join-Path $root 'ghoztty-agent.exe.old-1'
        Set-Content -LiteralPath $stale -Value 'leftover' -Encoding ascii

        # A real `--pty-host` holder: windowless, long-lived, and running out of
        # the copy above - which is what makes this a measurement of the defect
        # rather than of a file lock we invented. Its pipe is named for a
        # per-run session id, so it cannot collide with the user's sessions.
        $sid = 't1207-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $holderApp = Start-OnTestDesktop -Exe $agentPath `
            -Arguments @('--pty-host', "--session-id=$sid")
        $holder = $holderApp.Process
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline -and -not $holder.HasExited) {
            # The holder is up as soon as it has the image mapped, which is
            # true the moment the process exists. Give it a beat to get past
            # argument parsing so an ARGUMENT error reads as one.
            Start-Sleep -Milliseconds 400
            break
        }
        if ($holder.HasExited) {
            Skip 'L  live prepare against a running holder' "the holder exited immediately (exit $($holder.ExitCode))"
        } else {
            $before = $holder.Id

            # -Wait -PassThru rather than `&`: a RELEASE ghoztty.exe is a GUI
            # subsystem image, which PowerShell does not wait for, and a test
            # that measured the directory before the step had run would be a
            # coin flip. (The exit code is read off the waited-on object, never
            # off $LASTEXITCODE, which is empty for a Start-Process child.)
            # T1241: on the TEST desktop. `--install-prepare` opens no window
            # of its own, but ghoztty.exe is a GUI-subsystem image and a step
            # that ever did would put it on the user's screen. Invoke-OnTestDesktop
            # waits the way -Wait did and hands back the same exit code.
            $prep = Invoke-OnTestDesktop -Exe $Exe `
                -Arguments @('--install-prepare', "--install-dir=$root") -TimeoutSec 120
            $prepExit = $prep.ExitCode

            $sidelined = @(Get-ChildItem -LiteralPath $root -Filter 'ghoztty-agent.exe.old-*' -File |
                Where-Object { $_.Name -ne 'ghoztty-agent.exe.old-1' })

            Assert 'L1 the prepare step exits cleanly' ($prepExit -eq 0)
            Assert 'L2 the in-use agent image was renamed aside' ($sidelined.Count -eq 1)
            Assert 'L3 the holder that owns the session is STILL RUNNING' `
                ($null -ne (Get-Process -Id $before -ErrorAction SilentlyContinue))
            # The whole point: the path the installer writes is now free. If
            # this can be created, the Restart Manager has nothing to shut down.
            $free = $false
            try {
                [System.IO.File]::WriteAllText($agentPath, 'a fresh agent from the package')
                $free = $true
            } catch { $free = $false }
            Assert 'L4 the path an installer would write is free' $free
            Assert 'L5 the leftover from an earlier install was swept' `
                (-not (Test-Path -LiteralPath $stale))

            # The control: with nothing holding it, a prepare step is a no-op.
            # A prepare that renamed unconditionally would leave every ordinary
            # install with a junk file and a fresh agent nobody is running.
            # (The sideline from the first run is still there on purpose - the
            # holder is still running out of it, so the sweep must leave it be.)
            $sidelinesBefore = @(Get-ChildItem -LiteralPath $root -Filter 'ghoztty-agent.exe.old-*' -File |
                ForEach-Object { $_.Name } | Sort-Object)
            $prep2 = Invoke-OnTestDesktop -Exe $Exe `
                -Arguments @('--install-prepare', "--install-dir=$root") -TimeoutSec 120
            $sidelinesAfter = @(Get-ChildItem -LiteralPath $root -Filter 'ghoztty-agent.exe.old-*' -File |
                ForEach-Object { $_.Name } | Sort-Object)
            Assert 'L6 an unlocked image is left alone (no churn on a normal install)' `
                ((Test-Path -LiteralPath $agentPath) -and
                 (($sidelinesBefore -join '|') -eq ($sidelinesAfter -join '|')) -and
                 ($prep2.ExitCode -eq 0))
            Assert 'L7 a sideline something is STILL running out of is not swept' `
                ($sidelinesAfter.Count -eq 1)
        }
    } finally {
        if ($holder -and -not $holder.HasExited) {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 300
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-TestDesktop | Out-Null
    }
}

# The body reached its end (T1205's lesson, enforced by lib\TestScore.ps1): every
# section above ran, so a green verdict below is about the whole harness rather
# than about however much of it happened before something threw.
Complete-TestBody

# --- stamp (T783) ----------------------------------------------------------
# A clean green run stamps the files this harness covers. A run with a SKIP did
# not cover everything, so it does not stamp.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard install-prepare -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'install-prepare' -MinPass 20
