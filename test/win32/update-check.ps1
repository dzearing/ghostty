# T24 acceptance: the Windows update check (notify-only win-v* channel).
#
# The check lives in src/apprt/win32/App.zig + update_check.zig: on launch,
# channel builds (-Dwindows-update-check) fetch the GitHub releases list,
# scan for the newest `win-v*` tag, and show a tray balloon when it is
# newer than the running build. Dev builds never check; the
# GHOZTTY_UPDATE_URL env override force-enables the check (and bypasses
# the 1h throttle) so this script can drive a plain Debug build against
# canned file:// feeds (WinINet handles file:// URLs) plus one real-network
# smoke against the published channel.
#
# Scenarios (each = one GUI launch, stderr captured; Debug builds use the
# console subsystem so std.log lands on stderr):
#   1. feed win-v9.9.9 among Mac tags -> "update available" + balloon log
#   2. feed with Mac tags only        -> "no win-v release found"
#   3. feed win-v0.0.1 (older)        -> "up to date"
#   4. no env override -> flavor-dependent (probed via `+version`'s
#      "update check: on/off" line): dev builds must stay silent (gate);
#      channel builds (-Dwindows-update-check, e.g. zig-out right after a
#      publish-windows-release.ps1 run) must check the real channel.
#   5. real GitHub channel            -> check completes against the live
#      releases list (available or up-to-date, whichever matches HEAD's
#      version vs the published win-v tag)
#   6. the check REPEATS on a timer (T1171): a release published while the
#      app is running is found without a restart, and the version already
#      offered is not re-announced on every tick
param([string]$ExePath)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches, and a pane-launched app would otherwise hand its work to
# a respawned twin mid-test.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$ErrorActionPreference = 'Stop'
# T680: one private IPC endpoint for the whole run, claimed before anything
# launches or dials. This replaces the old per-scenario set/remove of
# GHOZTTY_PIPE_SUFFIX, which left gaps and reused a fixed name across runs.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't24')
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: $exe missing (zig build first)"; exit 1 }
# T1033: a private pipe suffix moves the APP endpoint only - the agent pipe and
# the state files stay build-mode derived - so the exe about to be launched is
# checked for the -debug lineage before the first launch, not assumed.
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

$feedDir = Join-Path $env:TEMP 'ghoztty-t24-feeds'
New-Item -ItemType Directory -Force $feedDir | Out-Null

# Canned GitHub /releases list bodies (newest-first, compact JSON like the
# real API). Mac tags must be skipped by the scanner.
$feedNewer = '[{"tag_name":"v1.17.0","name":"mac"},{"tag_name":"win-v9.9.9","name":"win"},{"tag_name":"win-v1.0.0"}]'
$feedMacOnly = '[{"tag_name":"v1.17.0"},{"tag_name":"v1.16.2"},{"tag_name":"v1.16.1"}]'
$feedOlder = '[{"tag_name":"v1.17.0"},{"tag_name":"win-v0.0.1"}]'

# Launch the GUI with an optional GHOZTTY_UPDATE_URL, capture stderr for
# $waitSecs, kill it, return the stderr text.
function Run-Scenario([string]$label, [string]$updateUrl, [int]$waitSecs = 8) {
    Kill-RepoInstances
    $errFile = Join-Path $env:TEMP "ghoztty-t24-$label.err.txt"
    Remove-Item $errFile -ErrorAction SilentlyContinue
    if ($updateUrl) { $env:GHOZTTY_UPDATE_URL = $updateUrl }
    else { Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue }
    # The private pipe (Set-GhozttyTestIsolation, top of file) means the
    # launch can't forward to a live instance and exit.
    try {
        # One retry on early exit: a launch racing a just-killed prior
        # instance occasionally dies during startup.
        $proc = $null
        foreach ($attempt in 1, 2) {
            # persistence: off. Each scenario launches and kills the GUI, so with
            # it on every later scenario restores the windows the earlier ones
            # left - and the update banner would be looked for in a pane this
            # run never opened (T158).
            $proc = Start-Process -FilePath $exe -ArgumentList '--session-persistence=false' `
                -PassThru -RedirectStandardError $errFile
            # Before any HasExited poll, or the exit code in the SETUP FAIL
            # message below reads back empty (lib\ExitCodeAudit.ps1).
            $null = $proc.Handle
            $deadline = (Get-Date).AddSeconds($waitSecs)
            while ((Get-Date) -lt $deadline -and -not $proc.HasExited) { Start-Sleep -Milliseconds 500 }
            if (-not $proc.HasExited) { break }
            Write-Host "NOTE ($label): GUI exited early (attempt $attempt)"
            Start-Sleep -Seconds 2
        }
        if ($proc.HasExited) {
            Write-Host "SETUP FAIL ($label): GUI exited early twice (code $($proc.ExitCode))"
            exit 1
        }
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    } finally {
        Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
    }
    if (Test-Path $errFile) { return [IO.File]::ReadAllText($errFile) }
    return ''
}

function New-Feed([string]$name, [string]$json) {
    $path = Join-Path $feedDir $name
    [IO.File]::WriteAllText($path, $json)
    return 'file:///' + ($path -replace '\\', '/')
}

# -- 1. newer win-v release -> update available + balloon ----------------
$log1 = Run-Scenario 'newer' (New-Feed 'newer.json' $feedNewer)
Assert ($log1 -match 'update available: current=\S+ latest=win-v9\.9\.9') 'newer: "update available" logged with win-v9.9.9'
Assert ($log1 -match 'showing update balloon for win-v9\.9\.9') 'newer: balloon shown on GUI thread'
Assert ($log1 -notmatch 'update check failed') 'newer: no fetch failure'

# -- 2. no win-v tags in the feed ----------------------------------------
$log2 = Run-Scenario 'maconly' (New-Feed 'maconly.json' $feedMacOnly)
Assert ($log2 -match 'no win-v release found') 'mac-only: scanner reports no win-v release'
Assert ($log2 -notmatch 'update available') 'mac-only: no update offered'
Assert ($log2 -notmatch 'showing update balloon') 'mac-only: no balloon'

# -- 3. older win-v release -> up to date --------------------------------
$log3 = Run-Scenario 'older' (New-Feed 'older.json' $feedOlder)
Assert ($log3 -match 'update check: up to date \(current=\S+ latest=win-v0\.0\.1\)') 'older: up-to-date logged'
Assert ($log3 -notmatch 'showing update balloon') 'older: no balloon'

# -- 4. no env override: dev builds gated, channel builds check ----------
# Probe the exe flavor from its own `+version` output (the private pipe means
# the "Running Instance" query finds nothing and only the CLI's own build
# section prints).
$verOut = Join-Path $env:TEMP 'ghoztty-t24-version.txt'
# persistence: n/a - a CLI invocation, which opens no window.
$vp = Start-Process $exe -ArgumentList '+version' -RedirectStandardOutput $verOut -NoNewWindow -PassThru
if (-not $vp.WaitForExit(15000)) { try { $vp.Kill() } catch {}; Write-Host 'SETUP FAIL: +version hung'; exit 1 }
$verText = [IO.File]::ReadAllText($verOut)
$isChannel = $verText -match 'update check: on \(win-v channel\)'
# The "off" reason is not fixed text: T1217 added "off (not the installed
# release)" beside the older "off (dev build)", and this probe went on
# demanding the older wording - which is why the whole scenario had been
# SETUP FAILing against a perfectly good zig-out build. Only the on/off
# verdict matters here; the parenthetical is the reason, not the answer.
if (-not $isChannel -and $verText -notmatch 'update check: off \(') {
    Write-Host 'SETUP FAIL: +version printed no "update check" line'; exit 1
}
# Channel builds throttle automatic checks to one per hour via this
# timestamp file; clear it so the scenario is deterministic.
Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\update_check_at') -ErrorAction SilentlyContinue
$log4 = Run-Scenario 'gated' ''
if ($isChannel) {
    Assert ($log4 -match 'update available|update check: up to date') 'no-override: channel build checks the real channel'
    Assert ($log4 -notmatch 'update check failed') 'no-override: channel check succeeded'
} else {
    Assert ($log4 -notmatch 'update available|up to date|no win-v release|update check failed') 'no-override: dev build never checks'
}

# -- 5. real channel smoke ------------------------------------------------
$log5 = Run-Scenario 'live' 'https://api.github.com/repos/dzearing/ghoztty/releases?per_page=30' 12
$liveOk = ($log5 -match 'update available: current=\S+ latest=win-v') -or
          ($log5 -match 'update check: up to date \(current=\S+ latest=win-v') -or
          ($log5 -match 'no win-v release found')
Assert $liveOk 'live: check completes against the real GitHub channel'
Assert ($log5 -notmatch 'update check failed') 'live: fetch + parse succeeded'
# Once win-v1.4.1+ is published the scanner must actually find it:
Assert ($log5 -match 'latest=win-v\d') 'live: a published win-v release was found'

# -- 6. the check REPEATS while the app runs (T1171) ---------------------
# The automatic check used to run once, at launch: a release published while
# a window was open reached it only on the next restart. It now re-asks on a
# timer, and the same version is offered ONCE - a deferred update must not
# re-balloon (and must not re-download) every tick.
#
# GHOZTTY_UPDATE_RECHECK_MS (Debug builds only) shortens the ten-minute
# cadence so a second tick is observable; the feed file is rewritten under the
# running app to publish a newer release mid-session.
$recheckFeed = Join-Path $feedDir 'recheck.json'
[IO.File]::WriteAllText($recheckFeed, $feedNewer)
$recheckUrl = 'file:///' + ($recheckFeed -replace '\\', '/')
Kill-RepoInstances
$errFile6 = Join-Path $env:TEMP 'ghoztty-t24-recheck.err.txt'
Remove-Item $errFile6 -ErrorAction SilentlyContinue
$env:GHOZTTY_UPDATE_URL = $recheckUrl
$env:GHOZTTY_UPDATE_RECHECK_MS = '3000'
$log6 = ''
try {
    $proc6 = Start-Process -FilePath $exe -ArgumentList '--session-persistence=false' `
        -PassThru -RedirectStandardError $errFile6
    $null = $proc6.Handle
    # Two ticks at the launch version: the first re-check must find win-v9.9.9
    # again and stay quiet about it.
    Start-Sleep -Seconds 9
    if ($proc6.HasExited) {
        Write-Host "SETUP FAIL (recheck): GUI exited early (code $($proc6.ExitCode))"; exit 1
    }
    # Publish a newer release under the running app.
    [IO.File]::WriteAllText($recheckFeed, '[{"tag_name":"win-v9.9.10"},{"tag_name":"win-v9.9.9"}]')
    Start-Sleep -Seconds 9
    Stop-Process -Id $proc6.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
} finally {
    Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_UPDATE_RECHECK_MS -ErrorAction SilentlyContinue
}
if (Test-Path $errFile6) { $log6 = [IO.File]::ReadAllText($errFile6) }
Assert ($log6 -match 'showing update balloon for win-v9\.9\.9') 'recheck: launch check offers win-v9.9.9'
Assert ($log6 -match 'win-v9\.9\.9 already offered; not re-notifying') 'recheck: the check ran again and stayed quiet about the same version'
Assert (([regex]::Matches($log6, 'showing update balloon for win-v9\.9\.9')).Count -eq 1) 'recheck: the deferred version is offered exactly once'
Assert ($log6 -match 'update available: current=\S+ latest=win-v9\.9\.10') 'recheck: a release published mid-session is found without a restart'
Assert ($log6 -match 'showing update balloon for win-v9\.9\.10') 'recheck: the newer release raises a fresh notification'

Kill-RepoInstances
Write-Host ''
# --- stamp (T783) ----------------------------------------------------------
# Only a clean run stamps, so a red harness stays due - which is the whole
# point of the row this writes to: before T1171 nothing tied this script to
# the code it covers, and it sat SETUP FAILing on a renamed `+version` string.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard update-check -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
