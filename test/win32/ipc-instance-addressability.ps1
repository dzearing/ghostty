# Instance addressability acceptance (tracker T118).
#
# An IPC command run INSIDE a pane must drive the app instance that owns that
# pane - not whichever build the `ghoztty` on $PATH derives its endpoint from.
# The app bakes its own bound endpoint into every pane's environment as
# $GHOZTTY_IPC_SOCKET (a PIPE NAME on Windows; same var as the Mac socket path,
# by decision - see the task file), and the CLI prefers it over the derivation.
#
# Two instances stand in for "debug build vs installed release": each is the
# SAME exe launched with a different GHOZTTY_PIPE_SUFFIX, so each binds its own
# pipe. That is exactly the shape of the real bug - two live instances whose
# endpoints differ - without needing two builds on disk.
#
# What each check discriminates:
#
#   1. the baked value is instance A's OWN pipe (not a guess, not empty).
#   2. from inside A's pane, with the harness suffix REMOVED from the child's
#      env, `+list` still reaches A. Without the bake the CLI would derive
#      `-debug` and find nothing - which is precisely what check 3 proves by
#      doing it: clearing the baked var in the same pane makes the same command
#      fail. That negative control is what makes check 2 evidence rather than
#      "the CLI happened to work".
#   4. an explicit override aims the command elsewhere (documented escape
#      hatch): a bogus pipe name must fail, not fall back.
#   5. the SERVER never binds an inherited value. Instance B is launched with
#      GHOZTTY_IPC_SOCKET pointing at A's pipe (what happens when you start a
#      dev build from a pane of the installed release); it must still bind its
#      OWN derived name, and its panes must be baked with that.
#   5b. an explicit GHOZTTY_PIPE_SUFFIX outranks the baked endpoint. This is
#      what keeps this very suite honest: a script started from one of the
#      user's panes inherits their endpoint, and must still drive the instance
#      it aimed at.
#   6. neither does the AlreadyRunning FORWARD: instance C, launched with B's
#      suffix (so its bind fails) and A's pipe in its env, must forward its
#      new-window to B - the instance it collided with - and leave A alone.
#
# T248: the repo's app AND agent are killed and the debug layout manifest is
# dropped at setup, so `--target` idempotency cannot focus a previous run's
# pane instead of building this run's fixture.
#
# Instance A runs with session persistence ON (agent-backed panes, the OPEN env
# path) and B with it OFF (plain exec panes), so both local bake paths are
# exercised - and B cannot restore A's manifest and attach A's panes, which
# would make every "which instance answered?" assertion meaningless.
#
#   powershell -NoProfile -File test\win32\ipc-instance-addressability.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    # Keep the probe scratch dir (every probe's .cmd, its captured output and
    # its exit code) for post-mortem instead of deleting it at teardown.
    [switch]$KeepTmp
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t118-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

$user = $env:USERNAME
if (-not $user) { $user = 'default' }
$pipeA = "\\.\pipe\ghoztty-t118a-$user"
$pipeB = "\\.\pipe\ghoztty-t118b-$user"
$pipeGhost = "\\.\pipe\ghoztty-t118ghost-$user"

# Run a CLI verb against one instance: the suffix picks the endpoint, and the
# baked var is always cleared here so the HARNESS never accidentally rides the
# very mechanism under test.
function Invoke-Cli([string]$Suffix, [string[]]$CliArgs) {
    $env:GHOZTTY_PIPE_SUFFIX = $Suffix
    Remove-Item Env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
    # `ghoztty +verb > file` writes zero bytes from PowerShell (T245) - capture
    # through a pipe instead.
    $out = (& $Exe @CliArgs 2>&1 | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}

function Get-WindowCount([string]$Suffix) {
    $env:GHOZTTY_PIPE_SUFFIX = $Suffix
    Remove-Item Env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
    # stderr dropped, not merged: a warning line in the stream would break the
    # JSON parse and read as "no windows".
    $out = (& $Exe +list --json 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not $out.Trim()) { return -1 }
    try { $j = $out | ConvertFrom-Json } catch { return -1 }
    return @($j.data.windows).Count
}

# Drive a probe INSIDE a pane. The probe is a .cmd file so the pane's shell
# flavor does not matter (`cmd /c <file>` runs the same from cmd or pwsh) and
# so nothing this script cares about has to survive PowerShell's native
# command-line quoting; the command itself travels by --keys-file, which is
# byte-exact (T210).
function Invoke-PaneProbe {
    # $Body is [string[]] on purpose: as [string] PowerShell joins the lines
    # with spaces, and `set X= set Y= <cmd>` is one assignment that runs
    # nothing - a probe that reports exit 0 and an empty capture.
    param(
        [string]$Suffix,
        [string]$Target,
        [string]$Name,
        [string[]]$Body
    )
    $cmdFile = Join-Path $tmp "$Name.cmd"
    $rcFile = Join-Path $tmp "$Name.rc"
    Remove-Item $rcFile -ErrorAction SilentlyContinue
    # NOTE the space before `>`: `echo %ERRORLEVEL%> file` with a 0 in the
    # variable is `echo 0> file`, and cmd reads the digit immediately before a
    # redirection operator as a HANDLE - so it redirects stdin and leaves the
    # file empty. Cost an entire run of "the probe never reported".
    Set-Content -Path $cmdFile -Encoding ASCII -Value (@('@echo off') + $Body + @("echo %ERRORLEVEL% > `"$rcFile`""))

    $keys = Join-Path $tmp "$Name.keys"
    [IO.File]::WriteAllText($keys, "cmd /c `"$cmdFile`"", (New-Object Text.UTF8Encoding($false)))
    Invoke-Cli $Suffix @('+send-keys', "--target=$Target", "--keys-file=$keys", 'Enter') | Out-Null

    # Poll for CONTENT, not existence: the redirect creates the file before cmd
    # writes the line, and a zero-byte read here reads as "the probe vanished".
    for ($i = 0; $i -lt 80; $i++) {
        if (Test-Path $rcFile) {
            $raw = (Get-Content $rcFile -Raw -ErrorAction SilentlyContinue)
            if ($raw -and $raw.Trim()) { return [int]$raw.Trim() }
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Host "    (probe '$Name' never reported; files: $((Get-ChildItem $tmp).Name -join ', '))"
    return $null
}

function Read-ProbeFile([string]$Name) {
    $p = Join-Path $tmp $Name
    if (-not (Test-Path $p)) { return '' }
    return (Get-Content $p -Raw)
}

# $InheritedSocket is what an app launched from ANOTHER instance's pane sees.
# -NoPersistence keeps a second instance from restoring (and re-ATTACHing) the
# first one's panes out from under it via the shared debug layout manifest; it
# also puts that instance's panes on the plain-exec spawn path, so instance A
# (persistence on, agent-backed) and instance B cover both local bake paths.
# -NoWait is for an instance expected to forward and exit immediately.
function Start-Instance {
    param(
        [string]$Suffix,
        [string]$InheritedSocket,
        [string]$ErrLog,
        [switch]$NoPersistence,
        [switch]$NoWait
    )
    $env:GHOZTTY_PIPE_SUFFIX = $Suffix
    if ($InheritedSocket) { $env:GHOZTTY_IPC_SOCKET = $InheritedSocket }
    else { Remove-Item Env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue }
    $appArgs = @('--window-width=100', '--window-height=30')
    # A value the CLI parser accepts - `parseBool` (src/cli/args.zig) takes
    # 1/t/T/true/on/yes and 0/f/F/false/off/no, and anything else is an
    # InvalidValue that is logged and dropped, leaving persistence ON. The
    # instance then RESTORES the other instance's manifest and attaches its
    # panes, which is a fixture that quietly answers a different question than
    # the one being asked. (`off` was in that rejected set when this comment was
    # written; 8f7af4466 added on/off/yes/no on 2026-08-04. Corrected in T158,
    # where lib\PersistenceSweep.ps1 now checks the VALUE, not just the flag.)
    if ($NoPersistence) { $appArgs += '--session-persistence=false' }
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $appArgs -StdErr $ErrLog
    Remove-Item Env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
    if ($app -and -not $NoWait) {
        Wait-TestWindow -ProcessId $app.Pid -TimeoutMs 25000 | Out-Null
        Start-Sleep -Seconds 2
    }
    return $app
}

function Stop-RepoProcesses([string[]]$Names) {
    foreach ($name in $Names) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 600
}

Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
New-TestDesktop | Out-Null

try {
    Write-Host 'SETUP: instance A on a private endpoint'
    $appA = Start-Instance -Suffix '-t118a' -ErrLog (Join-Path $tmp 'a.log')
    if (-not $appA) { throw 'SETUP FAIL: instance A did not start' }
    $r = Invoke-Cli '-t118a' @('+new-window', '--target=t118aw')
    Assert ($r.Code -eq 0) 'SETUP: named window in A'
    Start-Sleep -Seconds 3

    Write-Host ''
    Write-Host '1. the pane is baked with A''s OWN endpoint'
    $rc = Invoke-PaneProbe '-t118a' 't118aw' 'baked' @(
        "echo %GHOZTTY_IPC_SOCKET%> `"$tmp\baked.txt`""
    )
    $baked = (Read-ProbeFile 'baked.txt').Trim()
    Assert ($rc -eq 0) 'probe ran in the pane'
    Assert ($baked -eq $pipeA) "baked GHOZTTY_IPC_SOCKET is A's pipe (got '$baked')"

    Write-Host ''
    Write-Host '2. a CLI run inside the pane reaches A with no suffix to help it'
    $rc = Invoke-PaneProbe '-t118a' 't118aw' 'inpane' @(
        'set GHOZTTY_PIPE_SUFFIX=',
        "`"$Exe`" +list > `"$tmp\inpane.txt`" 2>&1"
    )
    $inpane = Read-ProbeFile 'inpane.txt'
    Assert ($rc -eq 0) '+list exits 0 inside the pane'
    Assert ($inpane -match 't118aw') '+list from the pane sees A''s own window'

    Write-Host ''
    Write-Host '3. NEGATIVE CONTROL: clear the baked var and the same command fails'
    $rc = Invoke-PaneProbe '-t118a' 't118aw' 'nobake' @(
        'set GHOZTTY_PIPE_SUFFIX=',
        'set GHOZTTY_IPC_SOCKET=',
        "`"$Exe`" +list > `"$tmp\nobake.txt`" 2>&1"
    )
    $nobake = Read-ProbeFile 'nobake.txt'
    Assert ($rc -ne 0 -and $null -ne $rc) 'without the bake, +list fails (derives -debug)'
    Assert ($nobake -notmatch 't118aw') 'and it does not see A''s window'

    Write-Host ''
    Write-Host '4. an explicit override aims the command elsewhere'
    $rc = Invoke-PaneProbe '-t118a' 't118aw' 'override' @(
        'set GHOZTTY_PIPE_SUFFIX=',
        "set GHOZTTY_IPC_SOCKET=$pipeGhost",
        "`"$Exe`" +list > `"$tmp\override.txt`" 2>&1"
    )
    Assert ($rc -ne 0 -and $null -ne $rc) 'a bogus endpoint fails instead of falling back'

    Write-Host ''
    Write-Host '5. the SERVER ignores an inherited endpoint'
    $countA = Get-WindowCount '-t118a'
    $appB = Start-Instance -Suffix '-t118b' -InheritedSocket $pipeA `
        -ErrLog (Join-Path $tmp 'b.log') -NoPersistence
    if (-not $appB) { throw 'SETUP FAIL: instance B did not start' }
    $r = Invoke-Cli '-t118b' @('+new-window', '--target=t118bw')
    Assert ($r.Code -eq 0) 'B answers on its OWN derived endpoint'
    Start-Sleep -Seconds 3
    $listA = (Invoke-Cli '-t118a' @('+list')).Text
    Assert ($listA -notmatch 't118bw') 'and B did not bind (or serve) A''s endpoint'
    $rc = Invoke-PaneProbe '-t118b' 't118bw' 'bakedb' @(
        "echo %GHOZTTY_IPC_SOCKET%> `"$tmp\bakedb.txt`""
    )
    $bakedB = (Read-ProbeFile 'bakedb.txt').Trim()
    Assert ($bakedB -eq $pipeB) "B's pane is baked with B's pipe (got '$bakedB')"

    Write-Host ''
    Write-Host '5b. an explicit suffix outranks the baked endpoint'
    # This is what keeps an acceptance script launched from one of the USER'S
    # panes on the build it was asked to test: it sets a suffix, and the pane it
    # inherited an endpoint from must not win.
    $rc = Invoke-PaneProbe '-t118a' 't118aw' 'aimed' @(
        'set GHOZTTY_PIPE_SUFFIX=-t118b',
        "`"$Exe`" +list > `"$tmp\aimed.txt`" 2>&1"
    )
    $aimed = Read-ProbeFile 'aimed.txt'
    Assert ($rc -eq 0) 'the suffixed +list runs from inside A''s pane'
    Assert ($aimed -match 't118bw') 'and it lands on B, the instance it aimed at'
    Assert ($aimed -notmatch 't118aw') 'not on A, whose endpoint the pane carries'

    Write-Host ''
    Write-Host '6. so does the AlreadyRunning forward'
    $countA = Get-WindowCount '-t118a'
    $countB = Get-WindowCount '-t118b'
    # C collides with B on the pipe name, so its bind fails and it forwards a
    # new-window before exiting. With A's endpoint in its environment, the
    # forward must still go to B.
    Start-Instance -Suffix '-t118b' -InheritedSocket $pipeA `
        -ErrLog (Join-Path $tmp 'c.log') -NoPersistence -NoWait | Out-Null
    Start-Sleep -Seconds 6
    Assert ((Get-WindowCount '-t118b') -eq ($countB + 1)) 'C forwarded its window to B'
    Assert ((Get-WindowCount '-t118a') -eq $countA) 'and A gained nothing'
} catch {
    # An escaping exception must SCORE, not print a green summary on its way out.
    Assert $false "unexpected error: $_"
} finally {
    Remove-Item Env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
    if ($KeepTmp) { Write-Host "  (probe scratch kept: $tmp)" }
    else { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
