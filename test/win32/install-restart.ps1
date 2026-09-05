# Installing over a running Ghoztty is a normal operation, not a wall (T1204).
#
# THE DEFECT, in the user's words on 2026-08-31: the installer "said configuring
# and disappeared", and then demanded a reboot of the whole PC. Two things were
# missing behind that, and neither one is exotic:
#
#   1. The app did not participate in the RESTART MANAGER. Windows has one
#      mechanism for "I need to replace a file you are holding": ask the app to
#      close, replace the files, start it back up. An app plays along by
#      REGISTERING for restart and by actually EXITING when it is asked. Ghoztty
#      did neither, so Windows Installer was left with a locked exe and only bad
#      options - fail the transaction, or schedule the replacement for the next
#      reboot and tell the user to restart their machine.
#
#   2. The package did not refuse a reboot. The file replacement had already
#      completed; what Windows Installer had done was inherit the machine's
#      unrelated pending-reboot state and present it as this install's
#      requirement. Nothing in a per-user terminal under %LOCALAPPDATA% can
#      ever need one.
#
# What this asserts:
#
#   A  the source of both halves is in the shipped shape: the app registers for
#      restart with the flags that mean "restart me for an update and nothing
#      else", the window handler exits on a Restart Manager close and does NOT
#      on a cancelled session end, the module's tests are wired into the lane
#      (T1191), and the MSI carries REBOOT=ReallySuppress with the Restart
#      Manager left enabled.
#   E  the build-time read-back can say no: the verifier that ships inside
#      build-msi.sh is extracted and fed each broken Property table it exists
#      to reject (T1133). Needs python and nothing else - no Docker, no
#      msitools, no MSI.
#   L  the LIVE behaviour, against the real debug build: Windows reports the
#      process as registered for restart, the app agrees to a Restart Manager
#      close, and it actually EXITS for one - which is the half that decides
#      whether an upgrade over a running terminal is a blink or a files-in-use
#      failure. L4 is the control: a session end that is cancelled leaves the
#      app running, so "it exits" cannot be passing for the trivial reason.
#
# What is deliberately NOT here: a real msiexec install. That needs a signed,
# versioned package and would replace the user's installed Ghoztty, which is
# this repo's first non-negotiable. The MSI half is asserted at its source and
# at its build-time read-back; the app half - the part that actually regressed
# into a locked file - is measured live.
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1), so it
# never takes the user's foreground, and hermetically: private IPC endpoint,
# per-run $env:LOCALAPPDATA, and it only ever kills ghoztty processes launched
# from the repo zig-out.
#
# isolation: full - launches the repo debug build under a private endpoint.
#
#   powershell -NoProfile -File test\win32\install-restart.ps1
#   powershell -NoProfile -File test\win32\install-restart.ps1 -TeethCheck

param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive,
    # Re-run every section-A check against a deliberately broken copy of its
    # surface and assert it goes red. Proves the checks measure what they claim.
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$script:passes = 0
$script:failures = 0
$script:skipped = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}
function Skip($name, $why) { "  SKIP $name ($why)"; $script:skipped++ }

$paths = [ordered]@{
    msi = 'dist\windows-installer\build-msi.sh'
    rm  = 'src\apprt\win32\restart_manager.zig'
    app = 'src\apprt\win32\App.zig'
    off = 'src\apprt\win32\install_restart.zig'
    mai = 'src\main_ghostty.zig'
    win = 'src\apprt\win32\Window.zig'
    agg = 'src\apprt\win32.zig'
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
# A - the shipped shape of both halves. Each check is a predicate over file
# CONTENT so -TeethCheck can feed it the mutation it exists to catch.
# ---------------------------------------------------------------------------

$checks = [ordered]@{
    'A1 the app asks Windows to restart it after an update' =
        { param($t) $t.rm -match 'RegisterApplicationRestart\(null, restart_flags\)' }
    'A2 the restart flags exclude crash, hang and reboot relaunches' =
        { param($t) $t.rm -match 'pub const restart_flags: u32 = RESTART_NO_CRASH \| RESTART_NO_HANG \| RESTART_NO_REBOOT;' }
    'A3 and do NOT exclude the update case they exist for' =
        { param($t)
          $line = ([regex]'(?m)^pub const restart_flags:.*$').Match($t.rm).Value
          $line -and ($line -notmatch 'RESTART_NO_PATCH') }
    'A4 a launched app registers itself' =
        { param($t) $t.app -match '(?m)^\s*restart_manager\.register\(\);' }
    'A5 an installer close is told apart from a logoff' =
        { param($t) $t.rm -match 'pub fn isCloseAppRequest' -and $t.rm -match 'ENDSESSION_CLOSEAPP: usize = 0x00000001' }
    'A6 the window EXITS for an installer close, so nobody waits on us' =
        { param($t) $t.win -match '(?s)restart_manager\.isCloseAppRequest\(@bitCast\(lparam\)\)\) \{.{0,400}?std\.process\.exit\(0\);' }
    'A7 a cancelled session end is not treated as one' =
        { param($t) $t.win -match '(?s)w32\.WM_ENDSESSION => \{.{0,900}?if \(wparam == 0\) return 0;' }
    'A8 the module tests are wired into the lane (T1191)' =
        { param($t) $t.agg -match '_ = @import\("win32/restart_manager\.zig"\);' }
    'A9 the MSI never asks for a reboot' =
        { param($t) $t.msi -match '<Property Id="REBOOT" Value="ReallySuppress"/>' }
    'A10 the build reads that back out of the compiled package' =
        { param($t) $t.msi -match 'msiinfo export "\$OUT" Property' }
    'A11 the read-back FAILS the build rather than warning' =
        { param($t) $t.msi -match 'Property table has no REBOOT row' }
    'A12 disabling the Restart Manager is refused, not merely avoided' =
        { param($t) $t.msi -match 'MSIRESTARTMANAGERCONTROL' -and $t.msi -match 'MSIDISABLERMRESTART' }
    'A14 the installer can OFFER a restart from the build it just wrote (T1352)' =
        { param($t) $t.off -match 'pub const flag = "--install-restart";' }
    'A15 the offer closes with the Restart Manager pair, not a window close' =
        { param($t) $t.off -match 'w32\.WM_QUERYENDSESSION' -and $t.off -match 'w32\.WM_ENDSESSION' -and $t.off -match 'restart_manager\.ENDSESSION_CLOSEAPP' -and $t.off -notmatch 'w32\.WM_CLOSE' }
    'A16 and never terminates a window that will not close' =
        { param($t) $t.off -notmatch 'TerminateProcess' }
    'A17 a declined offer still leaves a reminder' =
        { param($t) $t.off -match 'fn remind\(' -and $t.off -match 'w32\.NIM_ADD' }
    'A18 only this install is ever offered up, never a dev build beside it' =
        { param($t) $t.off -match 'pub fn isInstalledApp' -and $t.off -match 'isInstalledApp\(path, dir\)' }
    'A19 an ordinary launch dispatches the flag before it becomes a terminal' =
        { param($t) $t.mai -match 'runInstallRestart' }
    'A20 the offer module tests are wired into the lane (T1191)' =
        { param($t) $t.agg -match '_ = @import\("win32/install_restart\.zig"\);' }
    'A21 the package runs the offer on the UPGRADE path, with a UI, only' =
        { param($t) $t.msi -match '<Custom Action="RestartApp" After="LaunchApp">NOT Installed AND OLDERVERSIONFOUND AND UILevel &gt; 3 AND RESTARTAPP = "1"</Custom>' }
    'A22 the offer never blocks the install it follows' =
        { param($t) $t.msi -match '(?s)<CustomAction Id="RestartApp".{0,400}?Return="asyncNoWait"' }
    'A23 the build reads that wiring back out of the compiled package' =
        { param($t) $t.msi -match 'CustomAction table has no RestartApp row' }
}

$mutations = [ordered]@{
    'A1 the app asks Windows to restart it after an update' =
        @{ Key = 'rm'; Find = 'RegisterApplicationRestart(null, restart_flags)'; Replace = '0' }
    'A2 the restart flags exclude crash, hang and reboot relaunches' =
        @{ Key = 'rm'; Find = 'RESTART_NO_CRASH | RESTART_NO_HANG | RESTART_NO_REBOOT;'; Replace = '0;' }
    'A3 and do NOT exclude the update case they exist for' =
        @{ Key = 'rm'; Find = 'RESTART_NO_CRASH | RESTART_NO_HANG | RESTART_NO_REBOOT;'; Replace = 'RESTART_NO_CRASH | RESTART_NO_HANG | RESTART_NO_REBOOT | RESTART_NO_PATCH;' }
    'A4 a launched app registers itself' =
        @{ Key = 'app'; Find = '    restart_manager.register();'; Replace = '' }
    'A5 an installer close is told apart from a logoff' =
        @{ Key = 'rm'; Find = 'pub fn isCloseAppRequest'; Replace = 'fn unusedCloseCheck' }
    'A6 the window EXITS for an installer close, so nobody waits on us' =
        @{ Key = 'win'; Find = 'std.process.exit(0);'; Replace = 'log.info("would exit", .{});' }
    'A7 a cancelled session end is not treated as one' =
        @{ Key = 'win'; Find = 'if (wparam == 0) return 0;'; Replace = '' }
    'A8 the module tests are wired into the lane (T1191)' =
        @{ Key = 'agg'; Find = '_ = @import("win32/restart_manager.zig");'; Replace = '' }
    'A9 the MSI never asks for a reboot' =
        @{ Key = 'msi'; Find = '<Property Id="REBOOT" Value="ReallySuppress"/>'; Replace = '<Property Id="REBOOT" Value="Suppress"/>' }
    'A10 the build reads that back out of the compiled package' =
        @{ Key = 'msi'; Find = 'msiinfo export "$OUT" Property'; Replace = 'true # no read-back' }
    'A11 the read-back FAILS the build rather than warning' =
        @{ Key = 'msi'; Find = 'Property table has no REBOOT row'; Replace = 'warning only' }
    'A12 disabling the Restart Manager is refused, not merely avoided' =
        @{ Key = 'msi'; Find = 'MSIDISABLERMRESTART'; Replace = 'SOMETHINGELSE' }
    'A14 the installer can OFFER a restart from the build it just wrote (T1352)' =
        @{ Key = 'off'; Find = 'pub const flag = "--install-restart";'; Replace = 'pub const flag = "--nope";' }
    'A15 the offer closes with the Restart Manager pair, not a window close' =
        @{ Key = 'off'; Find = 'w32.WM_QUERYENDSESSION'; Replace = 'w32.WM_CLOSE' }
    'A16 and never terminates a window that will not close' =
        @{ Key = 'off'; Find = 'const still_open = waitForExit(targets);'; Replace = 'const still_open = TerminateProcess(targets);' }
    'A17 a declined offer still leaves a reminder' =
        @{ Key = 'off'; Find = 'fn remind('; Replace = 'fn unusedRemind(' }
    'A18 only this install is ever offered up, never a dev build beside it' =
        @{ Key = 'off'; Find = 'if (!isInstalledApp(path, dir)) continue;'; Replace = '_ = path;' }
    'A19 an ordinary launch dispatches the flag before it becomes a terminal' =
        @{ Key = 'mai'; Find = 'runInstallRestart'; Replace = 'runNothingAtAll' }
    'A20 the offer module tests are wired into the lane (T1191)' =
        @{ Key = 'agg'; Find = '_ = @import("win32/install_restart.zig");'; Replace = '' }
    'A21 the package runs the offer on the UPGRADE path, with a UI, only' =
        @{ Key = 'msi'; Find = 'NOT Installed AND OLDERVERSIONFOUND AND UILevel &gt; 3 AND RESTARTAPP = "1"'; Replace = 'NOT Installed AND OLDERVERSIONFOUND' }
    'A22 the offer never blocks the install it follows' =
        @{ Key = 'msi'; Find = 'Return="asyncNoWait"'; Replace = 'Return="check"' }
    'A23 the build reads that wiring back out of the compiled package' =
        @{ Key = 'msi'; Find = 'CustomAction table has no RestartApp row'; Replace = 'warning only' }
}

if ($TeethCheck) {
    "== install-restart -TeethCheck: each check, fed the state it exists to catch =="
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

"== install-restart A: the shipped tree =="
foreach ($name in $checks.Keys) { Assert $name (& $checks[$name] $text) }

"== install-restart A: every check has a demonstration =="
$missing = @($checks.Keys | Where-Object { -not $mutations.Contains($_) })
Assert "A13 no check ships without a mutation (-TeethCheck covers all $($checks.Count))" ($missing.Count -eq 0)
if ($missing.Count -gt 0) { $missing | ForEach-Object { "       undemonstrated: $_" } }

# ---------------------------------------------------------------------------
# E - the build-time read-back, watched failing. Section A proves the verifier
# is WIRED; this proves it can say no. The code under test is extracted from
# build-msi.sh itself, so what is demonstrated is what ships, and it is fed
# synthetic Property tables rather than a real MSI - which is what makes the
# demonstration runnable on a box with no Docker and no msitools.
# ---------------------------------------------------------------------------
"== install-restart E: the no-reboot gate, fed each MSI it must reject =="
$py = $null
foreach ($cand in @('python', 'python3', 'py')) {
    if (-not (Get-Command $cand -ErrorAction SilentlyContinue)) { continue }
    $probe = & $cand -V 2>&1
    if ($LASTEXITCODE -eq 0 -and "$probe" -match '^Python 3') { $py = $cand; break }
}
if (-not $py) {
    Skip 'E  no-reboot gate demonstration' 'no python interpreter on PATH'
} else {
    $verifier = ([regex]'(?ms)^python3 - "\$WORK/Property\.idt".*?\n(.*?)\nPYEOF$').Match($text.msi)
    if (-not $verifier.Success) {
        Assert 'E0 the no-reboot verifier is extractable from build-msi.sh' $false
    } else {
        $tmpE = Join-Path ([System.IO.Path]::GetTempPath()) ("install-restart-" + [guid]::NewGuid().ToString('N'))
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
            $goodProps = @(
                "Property${t}Value",
                "s72${t}l0",
                "Property${t}Property",
                "MSIINSTALLPERUSER${t}1",
                "ARPNOMODIFY${t}1",
                "REBOOT${t}ReallySuppress"
            ) -join "`r`n"

            function RunVerifier($body) {
                $f = Put ("prop-" + [guid]::NewGuid().ToString('N') + '.idt') $body
                & $py $vp $f 2>&1 | Out-Null
                return $LASTEXITCODE
            }

            Assert 'E1 a correctly wired MSI passes' ((RunVerifier $goodProps) -eq 0)
            Assert 'E2 an MSI with no REBOOT row is rejected' `
                ((RunVerifier (($goodProps -split "`r`n" | Where-Object { $_ -notmatch '^REBOOT' }) -join "`r`n")) -ne 0)
            Assert 'E3 REBOOT=Suppress - which still prompts - is rejected' `
                ((RunVerifier ($goodProps -replace 'ReallySuppress', 'Suppress')) -ne 0)
            Assert 'E4 an MSI that disables the Restart Manager is rejected' `
                ((RunVerifier ($goodProps + "`r`nMSIRESTARTMANAGERCONTROL${t}Disable")) -ne 0)
            Assert 'E5 an MSI that closes the app and never reopens it is rejected' `
                ((RunVerifier ($goodProps + "`r`nMSIDISABLERMRESTART${t}1")) -ne 0)
        } finally {
            Remove-Item -LiteralPath $tmpE -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# R - the upgrade restart offer's build-time read-back, watched failing (T1352,
# and the T1133 rule that a gate ships with the demonstration that it can say
# no). Extracted from build-msi.sh itself and fed synthetic CustomAction /
# InstallExecuteSequence tables, so it needs python and nothing else.
# ---------------------------------------------------------------------------
"== install-restart R: the restart-offer gate, fed each MSI it must reject =="
if (-not $py) {
    Skip 'R  restart-offer gate demonstration' 'no python interpreter on PATH'
} else {
    $rv = ([regex]'(?ms)^echo "==> verify upgrade restart offer.*?<<''PYEOF''\r?\n(.*?)\r?\nPYEOF$').Match($text.msi)
    if (-not $rv.Success) {
        Assert 'R0 the restart-offer verifier is extractable from build-msi.sh' $false
    } else {
        $tmpR = Join-Path ([System.IO.Path]::GetTempPath()) ("install-restart-r-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpR | Out-Null
        try {
            $utf8R = New-Object System.Text.UTF8Encoding($false)
            function PutR($name, $body) {
                $f = Join-Path $tmpR $name
                [System.IO.File]::WriteAllText($f, $body, $utf8R)
                return $f
            }
            $vpR = PutR 'verify-restart.py' $rv.Groups[1].Value
            $t = "`t"
            # 242 = exe-from-property (50) + Async (64) + Continue (128), i.e.
            # Return="asyncNoWait".
            $goodCa = @(
                "Action${t}Type${t}Source${t}Target",
                "s72${t}i2${t}S72${t}S255",
                "CustomAction${t}Action",
                "RestartApp${t}242${t}RESTARTAPPCMD${t}--install-restart --installed-version=[ARPDISPLAYVERSION]",
                "SetRestartAppCmd${t}51${t}RESTARTAPPCMD${t}[INSTALLDIR]ghoztty.exe"
            ) -join "`r`n"
            $upgradeCond = 'NOT Installed AND OLDERVERSIONFOUND AND UILevel > 3 AND RESTARTAPP = "1"'
            function SeqTable($restartSeq, $cond) {
                return @(
                    "Action${t}Condition${t}Sequence",
                    "s72${t}S255${t}I2",
                    "InstallExecuteSequence${t}Action",
                    "InstallFinalize${t}${t}6600",
                    "SetRestartAppCmd${t}${t}6602",
                    "RestartApp${t}${cond}${t}${restartSeq}"
                ) -join "`r`n"
            }
            function RunRestartVerifier($ca, $seq) {
                $f1 = PutR ("ca-" + [guid]::NewGuid().ToString('N') + '.idt') $ca
                $f2 = PutR ("seq-" + [guid]::NewGuid().ToString('N') + '.idt') $seq
                & $py $vpR $f1 $f2 2>&1 | Out-Null
                return $LASTEXITCODE
            }

            $goodSeq = SeqTable 6603 $upgradeCond
            Assert 'R1 a correctly wired offer passes' `
                ((RunRestartVerifier $goodCa $goodSeq) -eq 0)
            Assert 'R2 an MSI with no RestartApp action is rejected - the silence this fixes' `
                ((RunRestartVerifier (($goodCa -split "`r`n" | Where-Object { $_ -notmatch '^RestartApp' }) -join "`r`n") $goodSeq) -ne 0)
            Assert 'R3 a SYNCHRONOUS offer, which would block the installer on a dialog, is rejected' `
                ((RunRestartVerifier ($goodCa -replace [regex]::Escape("RestartApp${t}242"), "RestartApp${t}50") $goodSeq) -ne 0)
            Assert 'R4 an offer sequenced before the files are written is rejected' `
                ((RunRestartVerifier $goodCa (SeqTable 6500 $upgradeCond)) -ne 0)
            Assert 'R5 an offer a SILENT install would see is rejected' `
                ((RunRestartVerifier $goodCa (SeqTable 6603 'NOT Installed AND OLDERVERSIONFOUND AND RESTARTAPP = "1"')) -ne 0)
            Assert 'R6 an offer that excludes the upgrade - the only case it exists for - is rejected' `
                ((RunRestartVerifier $goodCa (SeqTable 6603 'NOT Installed AND NOT OLDERVERSIONFOUND AND UILevel > 3 AND RESTARTAPP = "1"')) -ne 0)
            Assert 'R7 an offer that runs something other than --install-restart is rejected' `
                ((RunRestartVerifier ($goodCa -replace '--install-restart --installed-version=\[ARPDISPLAYVERSION\]', '--version') $goodSeq) -ne 0)
        } finally {
            Remove-Item -LiteralPath $tmpR -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# L - the live half, against the real debug build.
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# GetApplicationRestartSettings is how Windows itself answers "would the
# Restart Manager bring this process back?" - it reads the registration the
# process made with RegisterApplicationRestart. Asking Windows rather than
# asking our own source is the whole point of this section.
if (-not ('T1204.Rm' -as [type])) {
    Add-Type -Namespace T1204 -Name Rm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, uint pid);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(System.IntPtr h);

[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetApplicationRestartSettings(
    System.IntPtr hProcess,
    System.Text.StringBuilder pwzCommandline,
    ref uint pcchSize,
    ref uint pdwFlags);

// Returns the restart flags, or -1 when the process is not registered.
public static long RestartFlags(uint pid) {
    // PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
    System.IntPtr h = OpenProcess(0x0400 | 0x0010, false, pid);
    if (h == System.IntPtr.Zero) return -2;
    try {
        var sb = new System.Text.StringBuilder(1024);
        uint size = 1024;
        uint flags = 0;
        int hr = GetApplicationRestartSettings(h, sb, ref size, ref flags);
        if (hr != 0) return -1;
        return (long)flags;
    } finally { CloseHandle(h); }
}
'@
}

$WM_QUERYENDSESSION = 0x0011
$WM_ENDSESSION = 0x0016
$ENDSESSION_CLOSEAPP = 1
$ENDSESSION_LOGOFF = -2147483648   # 0x80000000 as a signed IntPtr

# The live half runs only against a real build. The try stays at the TOP level
# either way, so `Complete-TestBody` is reachable by this script's own flow -
# a marker buried inside a conditional is one an unwind can skip (T1039, and
# lib\BodyCompleteAudit.ps1 enforces it).
$live = Test-Path $Exe
if (-not $live) {
    Skip 'L  live restart-manager behaviour' "$Exe not found - build it first"
}
$root = Join-Path $env:TEMP "ghoztty-install-restart-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
if ($live) {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    New-Item -ItemType Directory -Force $root | Out-Null
    [void](Set-GhozttyTestIsolation -Tag 'instrestart')
    Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
    Register-RepoBuildTeardown -Exe $Exe | Out-Null
    $td = New-TestDesktop -Interactive:$Interactive
}
try {
    if ($live) {
        # ====================================================================
        "== install-restart L: Windows agrees this app can be closed and reopened =="
        # ====================================================================
        $tmpL = Join-Path $root 'l'
        New-Item -ItemType Directory -Force $tmpL | Out-Null
        $env:LOCALAPPDATA = $tmpL

        $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1204-live')
        $proc = $app.Process
        if ($proc) { $null = $proc.Handle }
        $win = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
        Assert 'L0 the app came up with a window' ($win -ne [IntPtr]::Zero)

        # 11 = RESTART_NO_CRASH | RESTART_NO_HANG | RESTART_NO_REBOOT. The bit
        # that must NOT be there is RESTART_NO_PATCH (4): that is the one that
        # means "do not restart me after an update", i.e. exactly this case.
        $flags = -3
        for ($i = 0; $i -lt 30 -and $flags -lt 0; $i++) {
            $flags = [T1204.Rm]::RestartFlags([uint32]$app.Pid)
            if ($flags -lt 0) { Start-Sleep -Milliseconds 200 }
        }
        Assert "L1 Windows reports the process registered for restart (flags=$flags)" ($flags -ge 0)
        Assert 'L2 registered for an UPDATE restart specifically (no RESTART_NO_PATCH)' `
            ($flags -ge 0 -and ($flags -band 4) -eq 0)
        Assert 'L3 and not for crash, hang or reboot relaunches' `
            ($flags -eq 11)

        # The Restart Manager's close: WM_QUERYENDSESSION with
        # ENDSESSION_CLOSEAPP, then WM_ENDSESSION. This is literally what an
        # installer does to a GUI app holding a file it needs to replace.
        $agreed = 0
        if ($win -ne [IntPtr]::Zero) {
            $agreed = Invoke-TestMessage -Window $win -Message ([uint32]$WM_QUERYENDSESSION) `
                -WParam ([IntPtr]::Zero) -LParam ([IntPtr]$ENDSESSION_CLOSEAPP)
        }
        Assert "L4 the app agrees to close for an installer (returned $agreed)" ($agreed -ne 0)

        if ($win -ne [IntPtr]::Zero) {
            [void](Invoke-TestMessage -Window $win -Message ([uint32]$WM_ENDSESSION) `
                -WParam ([IntPtr]1) -LParam ([IntPtr]$ENDSESSION_CLOSEAPP))
        }
        $exited = $false
        if ($proc) { $exited = $proc.WaitForExit(15000) }
        Assert 'L5 and then actually EXITS, instead of leaving its files locked' $exited

        # ====================================================================
        "== install-restart L: the control - a cancelled session end is not an exit =="
        # ====================================================================
        # Without this arm, L5 is also satisfied by an app that dies on any
        # WM_ENDSESSION it is handed, which would end a user's terminal the
        # first time a shutdown was proposed and then cancelled.
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $tmpM = Join-Path $root 'm'
        New-Item -ItemType Directory -Force $tmpM | Out-Null
        $env:LOCALAPPDATA = $tmpM

        $app2 = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1204-control')
        $proc2 = $app2.Process
        if ($proc2) { $null = $proc2.Handle }
        $win2 = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
        Assert 'L6 the control instance came up' ($win2 -ne [IntPtr]::Zero)
        if ($win2 -ne [IntPtr]::Zero) {
            # wParam FALSE: the session end everybody agreed to was called off.
            [void](Invoke-TestMessage -Window $win2 -Message ([uint32]$WM_ENDSESSION) `
                -WParam ([IntPtr]::Zero) -LParam ([IntPtr]$ENDSESSION_CLOSEAPP))
            # And a real logoff, which Windows terminates itself: our handler
            # must not race it by exiting early.
            [void](Invoke-TestMessage -Window $win2 -Message ([uint32]$WM_ENDSESSION) `
                -WParam ([IntPtr]1) -LParam ([IntPtr]$ENDSESSION_LOGOFF))
        }
        Start-Sleep -Milliseconds 1200
        $stillUp = $false
        if ($proc2) { $stillUp = -not $proc2.HasExited }
        Assert 'L7 a cancelled end and a logoff leave the terminal running' $stillUp

        # ====================================================================
        "== install-restart L: the upgrade restart OFFER (T1352) =="
        # ====================================================================
        # The offer is the installed exe run by msiexec after the files have
        # been replaced. Here it is the repo build run against the repo build,
        # which is the same relationship: the exe making the offer is not the
        # process being offered up.
        #
        # Driven through --answer, the acceptance seam: what is worth measuring
        # is the OUTCOME - the running app exits and a new one takes its place -
        # and a dialog cannot be clicked on a background desktop, where
        # synthetic input does not reach.
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $tmpN = Join-Path $root 'n'
        New-Item -ItemType Directory -Force $tmpN | Out-Null
        $env:LOCALAPPDATA = $tmpN
        $installDir = Split-Path -Parent $Exe

        $app3 = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1352-offer')
        $proc3 = $app3.Process
        if ($proc3) { $null = $proc3.Handle }
        $win3 = Wait-TestWindow -ProcessId $app3.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
        Assert 'L8 the instance to be offered up came up' ($win3 -ne [IntPtr]::Zero)

        function Invoke-Offer($offerArgs, $tag, $timeoutMs) {
            $errFile = Join-Path $root "offer-$tag.err"
            $h = Start-OnTestDesktop -Exe $Exe -Arguments $offerArgs -StdErr $errFile
            if ($h.Process) {
                $null = $h.Process.Handle
                [void]$h.Process.WaitForExit($timeoutMs)
            }
            $err = ''
            if (Test-Path -LiteralPath $errFile) { $err = (Get-Content -LiteralPath $errFile -Raw) }
            return [pscustomobject]@{ Pid = $h.Pid; Process = $h.Process; Err = $err }
        }

        # The control, and the reason the dir filter exists: an installer for a
        # DIFFERENT install must not touch this one. Without this arm, L11 is
        # equally satisfied by code that closes every Ghoztty it can find -
        # which on this box would be the user's terminal.
        $wrongDir = Join-Path $root 'not-an-install'
        $offerA = Invoke-Offer @('--install-restart', "--install-dir=$wrongDir", '--answer=restart') 'wrongdir' 30000
        $survived = $false
        if ($proc3) { $survived = -not $proc3.HasExited }
        Assert 'L9 an offer for a DIFFERENT install leaves this one alone' $survived
        Assert 'L9b and says it found nothing to offer' ($offerA.Err -match 'no running windows')

        # Declining leaves the app running - and says so, which is the half the
        # user could not see on 2026-09-05.
        $offerB = Invoke-Offer @('--install-restart', "--install-dir=$installDir", '--answer=later',
            '--installed-version=1.36.99') 'later' 60000
        $stillThere = $false
        if ($proc3) { $stillThere = -not $proc3.HasExited }
        Assert 'L10 declining the offer leaves the terminal running' $stillThere
        Assert 'L10b and the offer FOUND the running window' ($offerB.Err -match 'window\(s\) from')
        Assert 'L10c and recorded the declined answer' ($offerB.Err -match 'answer=later')

        # And accepting: the running app exits, and a new one comes up on the
        # exe that made the offer.
        $before = @(Get-Process -Name 'ghoztty' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $Exe } | ForEach-Object { $_.Id })
        $offerC = Invoke-Offer @('--install-restart', "--install-dir=$installDir", '--answer=restart',
            '--installed-version=1.36.99') 'restart' 90000
        $wentAway = $false
        if ($proc3) { $wentAway = $proc3.WaitForExit(30000) }
        Assert 'L11 accepting the offer closes the running terminal' $wentAway
        Assert 'L11b and it was closed for an UPDATE, not asked to quit' ($offerC.Err -match 'answer=restart')

        $fresh = 0
        for ($i = 0; $i -lt 60 -and $fresh -eq 0; $i++) {
            $now = @(Get-Process -Name 'ghoztty' -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $Exe -and $_.Id -ne $app3.Pid -and $_.Id -ne $offerC.Pid })
            if ($now.Count -gt 0) { $fresh = $now[0].Id }
            if ($fresh -eq 0) { Start-Sleep -Milliseconds 500 }
        }
        Assert "L12 and a new terminal comes up on the new build (pid $fresh)" ($fresh -ne 0)
        if ($fresh -ne 0) {
            $script:GhozttyTestDesktopPids += $fresh
            $freshWin = Wait-TestWindow -ProcessId $fresh -Class 'GhozttyWindow' -TimeoutMs 30000
            Assert 'L13 with a window, not just a process' ($freshWin -ne [IntPtr]::Zero)
        }

    }

    # LAST statement of the top-level try (T1039): an unwind from anywhere
    # above must not reach the verdict as if the run had finished.
    Complete-TestBody
} finally {
    if ($live) {
        $env:LOCALAPPDATA = $savedLocalAppData
        Remove-TestDesktop
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

# --- stamp (T783) ----------------------------------------------------------
# A clean green run stamps the files this harness covers. A run with a SKIP did
# not cover everything, so it does not stamp.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard install-restart -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'install-restart' -MinPass 30
