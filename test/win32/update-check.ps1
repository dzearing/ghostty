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
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: $exe missing (zig build first)"; exit 1 }

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
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
    # Isolated pipe so the launch can't forward to a live instance and exit.
    $env:GHOZTTY_PIPE_SUFFIX = '-t24test'
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
        Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue
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
# Probe the exe flavor from its own `+version` output (isolated pipe so
# the "Running Instance" query finds nothing and only the CLI's own build
# section prints).
$env:GHOZTTY_PIPE_SUFFIX = '-t24probe'
$verOut = Join-Path $env:TEMP 'ghoztty-t24-version.txt'
# persistence: n/a - a CLI invocation, which opens no window.
$vp = Start-Process $exe -ArgumentList '+version' -RedirectStandardOutput $verOut -NoNewWindow -PassThru
if (-not $vp.WaitForExit(15000)) { try { $vp.Kill() } catch {}; Write-Host 'SETUP FAIL: +version hung'; exit 1 }
Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue
$verText = [IO.File]::ReadAllText($verOut)
$isChannel = $verText -match 'update check: on \(win-v channel\)'
if (-not $isChannel -and $verText -notmatch 'update check: off \(dev build\)') {
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

Kill-RepoInstances
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
