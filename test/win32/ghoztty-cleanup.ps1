# T1188 acceptance - the cleanup screen.
#
#   powershell -NoProfile -File test\win32\ghoztty-cleanup.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state: every section
# runs the REAL script against a throwaway sandbox built under $env:TEMP, with a
# scratch registry hive under HKCU:\Software\dzearing-cleanup-test. The one
# section that looks at the actual box (H) is read-only by construction - it runs
# `inventory`, which has no removal path at all.
#
# isolation: none - no ghoztty binary is run and no CLI verb is invoked; the only
# executables this script starts are powershell and reg (T680 meta-check reads
# this marker).
#
# WHY IT EXISTS
#
# This script deletes things on the user's primary machine, on the strength of a
# classification it makes itself. Two of its behaviours are load-bearing and both
# are the kind that pass silently when broken:
#
#   * the ghost-registration guard. {A10466B5-...} is a dead MSI registration
#     whose uninstall would delete the LIVE install's files. A cleanup screen
#     that offered `msiexec /x` on it would look completely normal right up to
#     the moment it destroyed the user's terminal. Section B asserts the refusal
#     AND, as its negative control, that an ordinary registration IS offered -
#     because a guard that refuses everything is not a guard, it is a broken
#     script, and both look like "the dangerous thing did not happen".
#   * per-item confirmation. Section C answers no to one item and yes to another
#     in the same run and asserts exactly one of them is gone. An "are you sure"
#     that ignores the answer is the classic way this goes wrong, and nothing
#     about a successful-looking run would show it.
#
# Sections:
#   A - inventory finds each seeded artifact class with its provenance
#   B - the ghost guard: protected entry never offered, no msiexec string for it,
#       and (negative control) an ordinary registration IS offered one
#   C - per-item confirmation: no keeps, yes removes, unanswered defaults to keep
#   D - verdict accounting: dirty exits 1, `keep` makes it exit 0, `unkeep` undoes
#   E - `keep` refuses a reason-less keep (a keep nobody can read back)
#   F - -DryRun removes nothing but reports what it would
#   G - the in-use guard: an artifact held open by a live process is BLOCKED
#   H - the real box, read-only: inventory exits 0 and finds the release install
param(
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Script = Join-Path $Repo 'scripts\ghoztty-cleanup.ps1'

$script:failures = 0
$script:passes = 0
$script:skips = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name $detail" -ForegroundColor Red; $script:failures++ }
}
function Skip($name, $why) { Write-Host "  SKIP $name - $why" -ForegroundColor Yellow; $script:skips++ }
function Say($m) { Write-Host $m }
function Head($m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }

if (-not (Test-Path -LiteralPath $Script)) {
    Say "CLEANUP: cannot run - $Script is missing"
    exit 1
}

# --------------------------------------------------------------- sandbox ----

$Sandbox = Join-Path $env:TEMP ('ghoztty-cleanup-test\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID)
$TestHive = 'HKCU:\Software\dzearing-cleanup-test'

# The scratch hive mirrors the shape of the real one so the script's own key
# paths are exercised, not a simplified stand-in.
$H_Run = "$TestHive\Run"
$H_App = "$TestHive\App"
$H_Uninstall = "$TestHive\Uninstall"
$H_Env = "$TestHive\Env"

$GhostCode = '{A10466B5-D625-4A80-95D2-8AA648F5086C}'
$PlainCode = '{11111111-2222-3333-4444-555555555555}'

function New-Sandbox {
    Remove-Sandbox
    New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null

    $release = Join-Path $Sandbox 'Programs\Ghoztty'
    $portable = Join-Path $Sandbox 'Desktop\Ghoztty-portable-x64\Ghoztty'
    $devbin = Join-Path $Sandbox 'repo\zig-out-fake\bin'
    $state = Join-Path $Sandbox 'state'
    $startmenu = Join-Path $Sandbox 'StartMenu'
    $startup = Join-Path $Sandbox 'Startup'
    foreach ($d in @($release, $portable, $devbin, $state, $startmenu, $startup)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    # Stand-in exes: the screen reads size and mtime off them and asks for a file
    # version, all of which a plain file answers honestly (empty version).
    Set-Content -LiteralPath (Join-Path $release 'ghoztty.exe') -Value 'release' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $portable 'ghoztty.exe') -Value 'portable' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $devbin 'ghoztty.exe') -Value 'dev' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $state 'relay.env') -Value 'GHOZTTY_RELAY=x' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $state 'session-layout.json') -Value '{}' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $startmenu 'Ghoztty.lnk') -Value 'lnk' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $startup 'ghoztty-agent.cmd') -Value 'rem' -Encoding ascii

    foreach ($k in @($H_Run, $H_App, $H_Uninstall, $H_Env, "$H_App\Ghoztty")) {
        New-Item -Path $k -Force | Out-Null
    }
    New-ItemProperty -Path $H_Run -Name 'GhozttyAgent' -Value 'C:\nowhere\ghoztty-agent.exe' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $H_App -Name 'Marker' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $H_Env -Name 'Path' -Value ('C:\Windows;' + $release + ';C:\other') -PropertyType String -Force | Out-Null

    # Two ARP registrations: the protected ghost and an ordinary one. The
    # ordinary one is the negative control for the guard.
    New-Item -Path "$H_Uninstall\$GhostCode" -Force | Out-Null
    New-ItemProperty -Path "$H_Uninstall\$GhostCode" -Name 'DisplayName' -Value 'Ghoztty' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "$H_Uninstall\$GhostCode" -Name 'DisplayVersion' -Value '26.7.502' -PropertyType String -Force | Out-Null
    New-Item -Path "$H_Uninstall\$PlainCode" -Force | Out-Null
    New-ItemProperty -Path "$H_Uninstall\$PlainCode" -Name 'DisplayName' -Value 'Ghoztty Remote Agent' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "$H_Uninstall\$PlainCode" -Name 'DisplayVersion' -Value '1.12.1' -PropertyType String -Force | Out-Null

    return [pscustomobject]@{
        Release   = $release
        Portable  = Join-Path $Sandbox 'Desktop\Ghoztty-portable-x64'
        DevRoot   = Join-Path $Sandbox 'repo'
        State     = $state
        StartMenu = $startmenu
        Startup   = $startup
        KeepFile  = Join-Path $Sandbox 'keep.json'
    }
}

function Remove-Sandbox {
    if (Test-Path -LiteralPath $Sandbox) {
        Remove-Item -LiteralPath $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $TestHive) {
        Remove-Item -LiteralPath $TestHive -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Run the screen against the sandbox. Returns the combined output text plus the
# exit code; everything is asserted against those two, the way a user reads it.
function Invoke-Screen {
    param([string[]]$ScriptArgs, $Env)
    $log = Join-Path $Sandbox ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
    $common = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script
    ) + $ScriptArgs + @(
        '-ReleaseDir', $Env.Release,
        '-PortableDirs', $Env.Portable,
        '-DevRoot', $Env.DevRoot,
        '-StateDir', $Env.State,
        '-StartMenuDir', $Env.StartMenu,
        '-StartupDir', $Env.Startup,
        '-RunKeyPath', $H_Run,
        '-AppRegKeyPath', $H_App,
        '-UninstallKeyPaths', $H_Uninstall,
        '-PathRegKey', $H_Env,
        '-KeepFile', $Env.KeepFile,
        # Pipes and scheduled tasks are machine-wide and cannot be sandboxed, so
        # they are off here: a real GhozttyGoLoopWatchdog task would otherwise
        # make every sandbox verdict permanently dirty. Section H covers them
        # against the real box instead, read-only.
        '-NoPipeScan', '-NoTaskScan'
    )
    # Start-Process with explicit redirects rather than a PowerShell `*>` or
    # `2>` (T883): every assertion below is a text match against the screen's own
    # output, and a PowerShell redirection formats error records through the
    # HOST's formatter on the way to disk - so the same run yields different text
    # in a console and in a consoleless child, and a phrase an assert matches on
    # can land across a wrap. This writes the child's raw bytes to two separate
    # files: stdout is the oracle, stderr is kept beside it so a launch failure is
    # still readable rather than discarded.
    $errLog = $log + '.err'
    # Quote every element by hand: Start-Process -ArgumentList does NOT quote its
    # elements, so a multi-word value (`-Reason "uninstalled by hand"`) is
    # re-tokenized into positional arguments before the child's parameter binder
    # ever sees it. Trailing backslashes are trimmed because `"C:\x\"` escapes the
    # closing quote.
    $quoted = @($common | ForEach-Object { '"' + ($_ -replace '\\+$', '') + '"' })
    $p = Start-Process -FilePath 'powershell' -ArgumentList $quoted -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $errLog
    $null = $p.Handle   # cache the handle before reading ExitCode (the PS trap)
    $code = $p.ExitCode
    $text = ''
    if (Test-Path -LiteralPath $log) { $text = (Get-Content -LiteralPath $log -Raw) }
    if ($null -eq $text) { $text = '' }
    $err = ''
    if (Test-Path -LiteralPath $errLog) { $err = (Get-Content -LiteralPath $errLog -Raw) }
    if ($null -eq $err) { $err = '' }
    return [pscustomobject]@{ Text = $text; Err = $err; Code = $code }
}

# ------------------------------------------------------------------- A ------

Head 'A - inventory finds each seeded artifact class'
$envA = New-Sandbox
$a = Invoke-Screen -ScriptArgs @('inventory', '-NoProcessScan') -Env $envA
Assert 'A1 exits 0' ($a.Code -eq 0) "got $($a.Code)"
Assert 'A2 finds the release install' ($a.Text -match 'install-release') ''
Assert 'A3 finds the portable copy' ($a.Text -match 'install-portable-1') ''
Assert 'A4 finds the dev prefix' ($a.Text -match 'install-dev-zig-out-fake') ''
# The dev prefix nests its exe under bin\; an inventory that reports
# "no ghoztty.exe present" for it is wrong in the quiet way (fixed while
# writing this harness, from the first real-box run).
Assert 'A5 reads the dev prefix exe under bin\' ($a.Text -notmatch 'no ghoztty\.exe present') ''
Assert 'A6 finds the autostart entry' ($a.Text -match 'run-GhozttyAgent') ''
Assert 'A7 finds the settings key' ($a.Text -match 'reg-app-Ghoztty') ''
Assert 'A8 finds the PATH entry' ($a.Text -match 'path-user') ''
Assert 'A9 finds the Start Menu shortcut' ($a.Text -match 'startmenu-Ghoztty\.lnk') ''
Assert 'A10 finds the legacy Startup drop' ($a.Text -match 'startup-ghoztty-agent\.cmd') ''
Assert 'A11 finds the state directory' ($a.Text -match 'state-dir') ''
Assert 'A12 reports provenance, not just paths' ($a.Text -match 'from  MSI Environment component') ''

# ------------------------------------------------------------------- B ------

Head 'B - the ghost guard, with its negative control'
$b = Invoke-Screen -ScriptArgs @('inventory', '-NoProcessScan') -Env $envA
Assert 'B1 the ghost registration is present in the inventory' ($b.Text -match [regex]::Escape($GhostCode)) ''
Assert 'B2 it is marked PROTECTED' ($b.Text -match 'PROTECTED') ''
# The assertion that matters: no uninstall command is EMITTED for it anywhere in
# the screen's output. Searched as a literal string, because that is what a user
# would copy and paste.
$ghostCmd = 'msiexec /x ' + $GhostCode
Assert 'B3 no msiexec command is offered for the ghost' ($b.Text -notmatch [regex]::Escape($ghostCmd)) ''
$plainCmd = 'msiexec /x ' + $PlainCode
Assert 'B4 negative control: an ordinary registration IS offered one' ($b.Text -match [regex]::Escape($plainCmd)) ''
# And `clean` must refuse it too - the inventory view is not the only door.
$b2 = Invoke-Screen -ScriptArgs @('clean', '-NoProcessScan', '-DryRun', '-Answer', ('arp-' + $GhostCode + '=y')) -Env $envA
Assert 'B5 clean refuses the ghost even when answered yes' `
    ($b2.Text -match ('skip arp-' + [regex]::Escape($GhostCode) + ' - PROTECTED')) ''
Assert 'B6 clean never emits the ghost uninstall command' ($b2.Text -notmatch [regex]::Escape($ghostCmd)) ''
# A protected item is accounted for by definition; it must not hold the verdict
# hostage forever.
Assert 'B7 the ghost counts as protected, not unaccounted' ($b.Text -match '1 protected') ''

# ------------------------------------------------------------------- C ------

Head 'C - per-item confirmation: no keeps, yes removes'
$envC = New-Sandbox
$shortcut = Join-Path $envC.StartMenu 'Ghoztty.lnk'
$startupCmd = Join-Path $envC.Startup 'ghoztty-agent.cmd'
# One `-Answer` token carrying a comma-separated list: repeating the switch on a
# native command line does not append, it replaces, so `-Answer a -Answer b`
# would silently drop the first answer.
$c = Invoke-Screen -ScriptArgs @('clean', '-NoProcessScan',
    '-Answer', 'startmenu-Ghoztty.lnk=y,startup-ghoztty-agent.cmd=n') -Env $envC
Assert 'C1 the yes item is gone' (-not (Test-Path -LiteralPath $shortcut)) $shortcut
Assert 'C2 the no item survives' (Test-Path -LiteralPath $startupCmd) $startupCmd
# Everything else in the sandbox went unanswered, and unanswered must mean keep -
# a cleanup screen whose default is "remove" is a disaster with a prompt on it.
Assert 'C3 unanswered items are untouched (release)' (Test-Path -LiteralPath $envC.Release) ''
Assert 'C4 unanswered items are untouched (state)' (Test-Path -LiteralPath $envC.State) ''
Assert 'C5 unanswered items are untouched (registry)' `
    ($null -ne (Get-ItemProperty -LiteralPath $H_Run -Name 'GhozttyAgent' -ErrorAction SilentlyContinue)) ''
Assert 'C6 clean re-audits after removing' ($c.Text -match 'RE-AUDIT') ''
Assert 'C7 clean ends on a verdict' ($c.Text -match 'CLEANUP VERDICT') ''

# ------------------------------------------------------------------- D ------

Head 'D - verdict accounting'
$envD = New-Sandbox
$d1 = Invoke-Screen -ScriptArgs @('verdict', '-NoProcessScan') -Env $envD
Assert 'D1 a dirty sandbox is UNACCOUNTED and exits 1' `
    (($d1.Code -eq 1) -and ($d1.Text -match 'UNACCOUNTED')) "code=$($d1.Code)"

# Remove everything removable, then account for the rest with explicit keeps.
$allIds = @('install-release', 'install-portable-1', 'install-dev-zig-out-fake',
    'run-GhozttyAgent', 'reg-app-Ghoztty', 'path-user',
    'startmenu-Ghoztty.lnk', 'startup-ghoztty-agent.cmd', 'state-dir')
$answers = ($allIds | ForEach-Object { $_ + '=y' }) -join ','
$d2 = Invoke-Screen -ScriptArgs @('clean', '-NoProcessScan', '-Answer', $answers) -Env $envD
# The ordinary ARP registration cannot be removed from here by design (an
# uninstall is the user's act), so it is the one thing left over - which is
# exactly what a deliberate keep is for.
# Asserted on DISK first: "the advisory is what remains" is also true of a run
# that removed nothing at all, and a comma-separated answer list that the binder
# silently collapsed into one string did exactly that - every item read as
# declined and the section passed anyway.
Assert 'D2a the answered installs are actually gone' `
    ((-not (Test-Path -LiteralPath $envD.Release)) -and (-not (Test-Path -LiteralPath $envD.State))) ''
Assert 'D2 after removing everything removable, only the advisory remains' `
    ($d2.Text -match ('remains   arp-' + [regex]::Escape($PlainCode))) ''
Assert 'D3 the sweep still exits 1 while it is unaccounted' ($d2.Code -eq 1) "code=$($d2.Code)"

$keep = Invoke-Screen -ScriptArgs @('keep', ('arp-' + $PlainCode), '-Reason', 'uninstalled by hand after this run') -Env $envD
Assert 'D4 keep is recorded' ($keep.Code -eq 0) "code=$($keep.Code)"
$d3 = Invoke-Screen -ScriptArgs @('verdict', '-NoProcessScan') -Env $envD
Assert 'D5 a deliberately kept item makes the verdict CLEAN' `
    (($d3.Code -eq 0) -and ($d3.Text -match 'VERDICT: CLEAN')) "code=$($d3.Code)"
Assert 'D6 the verdict names what was kept and why' ($d3.Text -match 'uninstalled by hand after this run') ''

$unkeep = Invoke-Screen -ScriptArgs @('unkeep', ('arp-' + $PlainCode)) -Env $envD
Assert 'D7 unkeep is accepted' ($unkeep.Code -eq 0) "code=$($unkeep.Code)"
$d4 = Invoke-Screen -ScriptArgs @('verdict', '-NoProcessScan') -Env $envD
Assert 'D8 unkeep puts it back to unaccounted' ($d4.Code -eq 1) "code=$($d4.Code)"

# ------------------------------------------------------------------- E ------

Head 'E - a keep without a reason is refused'
$e = Invoke-Screen -ScriptArgs @('keep', 'install-release') -Env $envD
Assert 'E1 exits 2 (not viable), not 0' ($e.Code -eq 2) "code=$($e.Code)"
Assert 'E2 says why' ($e.Text -match 'needs -Reason') ''

# ------------------------------------------------------------------- F ------

Head 'F - -DryRun removes nothing'
$envF = New-Sandbox
$f = Invoke-Screen -ScriptArgs @('clean', '-NoProcessScan', '-DryRun',
    '-Answer', 'install-release=y,state-dir=y') -Env $envF
Assert 'F1 reports what it would remove' ($f.Text -match 'WOULD REMOVE install-release') ''
Assert 'F2 the release install survives' (Test-Path -LiteralPath $envF.Release) ''
Assert 'F3 the state dir survives' (Test-Path -LiteralPath $envF.State) ''

# ------------------------------------------------------------------- G ------

Head 'G - an artifact held open by a live process is BLOCKED, not removed'
$envG = New-Sandbox
# A directory cannot be recursively removed while a process holds a file in it
# open. That is the real-world shape (the loop runs inside the install it would
# be deleting), so hold a handle rather than simulate the check.
$held = Join-Path $envG.Release 'held.dat'
Set-Content -LiteralPath $held -Value 'x' -Encoding ascii
$fs = $null
try {
    $fs = [System.IO.File]::Open($held, 'Open', 'Read', 'None')
} catch { $fs = $null }
if ($null -eq $fs) {
    Skip 'G1 in-use guard' 'could not open an exclusive handle in the sandbox'
} else {
    try {
        $g = Invoke-Screen -ScriptArgs @('clean', '-NoProcessScan', '-Answer', 'install-release=y') -Env $envG
        Assert 'G1 the removal fails loudly rather than half-succeeding silently' `
            ($g.Text -match 'FAILED  install-release') ''
        Assert 'G2 the run reports failure' ($g.Code -eq 1) "code=$($g.Code)"
        Assert 'G3 the held file is still there' (Test-Path -LiteralPath $held) ''
    } finally {
        $fs.Close()
        $fs.Dispose()
    }
}

# ------------------------------------------------------------------- H ------

Head 'H - the real box, read-only'
# `inventory` has no removal path, so this is safe by construction and is the
# only thing here that proves the DEFAULTS point at real locations. A screen that
# works beautifully against a sandbox and finds nothing on the box it was written
# for is the failure this section exists to catch.
$hlog = Join-Path $Sandbox 'realbox.log'
$hp = Start-Process -FilePath 'powershell' -NoNewWindow -Wait -PassThru `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, 'inventory', '-NoPipeScan') `
    -RedirectStandardOutput $hlog -RedirectStandardError ($hlog + '.err')
$null = $hp.Handle
$hcode = $hp.ExitCode
$htext = ''
if (Test-Path -LiteralPath $hlog) { $htext = (Get-Content -LiteralPath $hlog -Raw) }
if ($null -eq $htext) { $htext = '' }
Assert 'H1 inventory of the real box exits 0' ($hcode -eq 0) "code=$hcode"
Assert 'H2 it finds the installed release' ($htext -match 'install-release') ''
Assert 'H3 it finds the dev prefixes in this repo' ($htext -match 'install-dev-zig-out') ''
# Scheduled tasks are the one artifact class that cannot be sandboxed, so this is
# the only place the collector is exercised at all. The go-loop watchdog task is
# registered on this box by scripts\go-loop-boot.ps1 install, which step 0 of
# every turn re-runs, so it is a dependable subject.
if ($htext -match 'SCHEDULED TASKS') {
    Assert 'H6 scheduled tasks are inventoried' ($htext -match 'task-Ghoztty') ''
} else {
    Skip 'H6 scheduled tasks' 'no Ghoztty scheduled task is registered on this box'
}
Assert 'H4 it never emits the ghost uninstall command' `
    ($htext -notmatch [regex]::Escape('msiexec /x ' + $GhostCode)) ''
if ($htext -match [regex]::Escape($GhostCode)) {
    Assert 'H5 the real ghost registration is marked PROTECTED' ($htext -match 'PROTECTED') ''
} else {
    Skip 'H5 real ghost registration' 'the ghost entry is not registered on this box'
}

# --------------------------------------------------------------- negative ----

if ($NegativeControl) {
    Head 'NEGATIVE CONTROL - the guard is removed and the run must go red'
    $envN = New-Sandbox
    $n = Invoke-Screen -ScriptArgs @('inventory', '-NoProcessScan', '-ProtectedProductCodes', 'none') -Env $envN
    $offered = ($n.Text -match [regex]::Escape('msiexec /x ' + $GhostCode))
    Assert 'N1 with the ghost dropped from the protected list, it IS offered' $offered `
        'the guard is not doing the work - protection comes from somewhere else'
    Say '  (that PASS is the proof section B can fail: B3 is asserting a real refusal)'
}

Remove-Sandbox

if ($script:failures -eq 0 -and $script:skips -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard ghoztty-cleanup -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
if ($script:failures -eq 0) {
    $note = ''
    if ($script:skips -gt 0) { $note = " / $script:skips skipped" }
    Say "GHOZTTY-CLEANUP: ALL PASS ($script:passes$note)"
    exit 0
} else {
    Say "GHOZTTY-CLEANUP: $script:failures FAILURE(S) / $script:passes passed"
    exit 1
}
