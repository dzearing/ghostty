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
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'install-restart' -MinPass 20
