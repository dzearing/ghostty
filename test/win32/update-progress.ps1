# T1195 acceptance: the update DOWNLOAD reports itself while it runs.
#
# Before this, consenting to an update on the `auto-update = check` path
# produced one tray balloon ("Downloading the update...") and then silence
# until the app either restarted into the new build or said the download had
# failed. Tens of megabytes on a slow link is a long silence, and a silence is
# the one thing a stall and a slow transfer look identical through.
#
# What this drives, end to end on a real box:
#
#   1. A TRICKLED HTTP asset (a local TcpListener, 64 KB at a time) is
#      downloaded after a consented click. The panel window appears, and the
#      app's own log carries a run of progress lines whose byte counts ADVANCE
#      and whose percentages come from a real Content-Length.
#   2. A STALLED transfer - the server sends 2 MB and then stops - is called
#      out as stalled rather than continuing to imply progress.
#   3. A transfer that completes and turns out not to be a package fails
#      VISIBLY, and says something different from #2.
#   4. The `auto-update = download` path (the package is fetched in the
#      background, before the user clicks anything) shows NO panel: there is
#      nobody waiting on it, and chrome for an unprompted background transfer
#      is chrome the user did not ask for.
#
# Nothing here touches GitHub or the user's installed Ghoztty: the release
# feed is a file:// JSON, the asset is served from 127.0.0.1 by this script,
# and no scenario ever produces a valid package - so no applier is ever armed
# and msiexec is never run.
#
# The click is SYNTHESIZED, not performed: the balloon callback is posted into
# the app's message-only window (as notification-click-focus.ps1 does, with
# the same T240 caveat - this proves the handler and everything downstream of
# it, and nothing about whether the shell delivers the click), and the confirm
# dialog's OK is a posted WM_COMMAND. A background desktop renders no balloon
# and no human can click one there.
#
# The oracle is the app's own log rather than the panel's pixels: it paints on
# a background Win32 desktop where CopyFromScreen reads nothing, and the panel
# is custom-drawn so it carries no readable control text. `UpdateProgress`
# logs the same sentence it paints, on every state change worth a line.
#
# T218 house rules apply: runs on a BACKGROUND Win32 desktop
# (test/win32/lib/TestDesktop.ps1) so it never takes the user's foreground,
# and only ever touches ghoztty processes from the repo zig-out.
#
# -NegativeControl inverts case 1's central assertion and MUST fail.
#
#   powershell -NoProfile -File test\win32\update-progress.ps1
param(
    [string]$Exe,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { Write-Host "SETUP FAIL: $Exe missing (zig build first)"; exit 1 }

# Isolate the IPC endpoint before any CLI call - inherited by the app through
# CreateProcessW and by every `& $Exe +...` below.
$env:GHOZTTY_PIPE_SUFFIX = "-updprog$PID"
# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-DebugGhoztty {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
}

# ------------------------------------------------------------------ fixtures

$work = Join-Path $env:TEMP "ghoztty-t1195-$PID"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

$staging = Join-Path $env:LOCALAPPDATA 'ghoztty\updates-debug'

# The asset server. A raw TcpListener rather than HttpListener: HttpListener
# needs a registered URL ACL (that is an admin operation), and everything the
# download needs from a server is a status line, a Content-Length and a body
# it can be made to deliver slowly.
$serverScript = {
    param($Port, $TotalBytes, $ChunkBytes, $DelayMs, $StopAfterBytes, $HangSeconds, $NoLength)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, [int]$Port)
    $listener.Start()
    try {
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                # Drain the request headers so the client is not left writing.
                $buf = New-Object byte[] 4096
                $stream.ReadTimeout = 5000
                try { [void]$stream.Read($buf, 0, $buf.Length) } catch {}

                # A server that will not say how long the body is: the client
                # then has nothing to measure a short read against, which is
                # the case the truncation check must leave alone.
                $lengthHeader = if ([int]$NoLength -eq 1) { '' } else { "Content-Length: $TotalBytes`r`n" }
                $head = "HTTP/1.1 200 OK`r`n" +
                        "Content-Type: application/octet-stream`r`n" +
                        $lengthHeader +
                        "Connection: close`r`n`r`n"
                $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($headBytes, 0, $headBytes.Length)
                $stream.Flush()

                $chunk = New-Object byte[] ([int]$ChunkBytes)
                $sent = 0
                $hung = $false
                while ($sent -lt [int]$TotalBytes) {
                    if ([int]$StopAfterBytes -gt 0 -and -not $hung -and $sent -ge [int]$StopAfterBytes) {
                        $hung = $true
                        Start-Sleep -Seconds ([int]$HangSeconds)
                        break
                    }
                    $n = [Math]::Min([int]$ChunkBytes, [int]$TotalBytes - $sent)
                    $stream.Write($chunk, 0, $n)
                    $stream.Flush()
                    $sent += $n
                    if ([int]$DelayMs -gt 0) { Start-Sleep -Milliseconds ([int]$DelayMs) }
                }
            } catch {
            } finally {
                try { $client.Close() } catch {}
            }
        }
    } finally {
        $listener.Stop()
    }
}

$script:serverJob = $null
function Start-AssetServer([int]$Port, [int]$TotalBytes, [int]$ChunkBytes, [int]$DelayMs, [int]$StopAfterBytes = 0, [int]$HangSeconds = 0, [int]$NoLength = 0) {
    Stop-AssetServer
    $script:serverJob = Start-Job -ScriptBlock $serverScript -ArgumentList $Port, $TotalBytes, $ChunkBytes, $DelayMs, $StopAfterBytes, $HangSeconds, $NoLength
    # Give the listener a moment to bind before anything dials it.
    Start-Sleep -Milliseconds 700
    return ($script:serverJob.State -ne 'Failed')
}

function Stop-AssetServer {
    if ($script:serverJob) {
        Stop-Job $script:serverJob -ErrorAction SilentlyContinue
        Remove-Job $script:serverJob -Force -ErrorAction SilentlyContinue
        $script:serverJob = $null
    }
}

# A free loopback port, taken and released so the job can bind it.
function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = $l.LocalEndpoint.Port
    $l.Stop()
    return $p
}

# The asset URL must contain /download/win-v<version>/ - that is how the
# scanner proves an asset belongs to the release it is offering.
function New-Feed([string]$name, [string]$assetUrl) {
    $json = '[{"tag_name":"v1.17.0","assets":[]},' +
            '{"tag_name":"win-v9.9.9","assets":[{"browser_download_url":"' + $assetUrl + '"}]}]'
    $path = Join-Path $work $name
    [IO.File]::WriteAllText($path, $json)
    return 'file:///' + ($path -replace '\\', '/')
}

# --- the tray callback, exactly as the shell would send it -------------------
# WM_APP_TRAY is WM_APP+3 (App.zig); under NOTIFYICON_VERSION the wparam is the
# icon's uID and the low word of lparam is the event. uID 2 is the update
# balloon (tray_notify.update_uid).
$WM_APP_TRAY = 0x8003
$NIN_BALLOONUSERCLICK = 0x0405
$UID_UPDATE = 2
$WM_COMMAND = 0x0111
$IDOK = 1

function Get-AppLog { if (Test-Path $script:appLog) { Get-Content $script:appLog -Raw } else { '' } }

function Wait-Log([string]$Pattern, [int]$TimeoutMs = 20000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 250) {
        if ((Get-AppLog) -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Wait-PanelWindow([int]$TimeoutMs = 15000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 100) {
        $w = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyUpdateProgress')
        if ($w.Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# Post the balloon click, then OK the confirm dialog it raises. Returns true
# when both landed.
function Invoke-ConsentedDownload {
    if (-not (Send-TestRawMessage -Window $script:msgWnd -Message ([uint32]$WM_APP_TRAY) `
              -WParam ([IntPtr]$UID_UPDATE) -LParam ([IntPtr]$NIN_BALLOONUSERCLICK))) { return $false }
    $dlg = [IntPtr]::Zero
    for ($t = 0; $t -lt 10000; $t += 200) {
        $d = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyConfirmDialog')
        if ($d.Count -gt 0) { $dlg = [IntPtr]$d[0].Hwnd; break }
        Start-Sleep -Milliseconds 200
    }
    if ($dlg -eq [IntPtr]::Zero) { return $false }
    # BN_CLICKED (0) in the high word, IDOK in the low: the dialog's own
    # WM_COMMAND path, which is what its OK button posts.
    return (Send-TestRawMessage -Window $dlg -Message ([uint32]$WM_COMMAND) `
            -WParam ([IntPtr]$IDOK) -LParam ([IntPtr]::Zero))
}

# The byte counts the panel logged, in order, as integers of MB*10 - enough to
# say "these advanced" without re-parsing the whole sentence.
function Get-ProgressTenths {
    $out = @()
    foreach ($m in [regex]::Matches((Get-AppLog), 'update progress: ([\d.]+) MB of')) {
        $out += [int]([double]$m.Groups[1].Value * 10)
    }
    return $out
}

function Start-App([string]$FeedUrl, [string[]]$ExtraArgs) {
    Stop-DebugGhoztty
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
    Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\update_check_at') -ErrorAction SilentlyContinue
    $env:GHOZTTY_UPDATE_URL = $FeedUrl
    $script:appLog = Join-Path $work ("app-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".log")
    $args = @('--session-persistence=false') + $ExtraArgs
    $script:app = Start-OnTestDesktop -Exe $Exe -Arguments $args -StdErr $script:appLog
    $script:appPid = $script:app.Pid
    Start-Sleep -Seconds 3
    if ($script:app.Process -and $script:app.Process.HasExited) { return $false }
    $script:msgWnd = Find-TestMessageWindow -ProcessId $script:appPid
    return ($script:msgWnd -ne [IntPtr]::Zero)
}

# ------------------------------------------------------------------- driver

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

# ---------------------------------------------------------------- 1: it moves
Write-Host '== 1: a trickled download reports its progress while it runs'
$port = Get-FreePort
# 12 MB at 64 KB every 30 ms is about 6 seconds of transfer - long enough to
# be watched, which is the whole complaint this task came from.
Assert (Start-AssetServer -Port $port -TotalBytes (12 * 1024 * 1024) -ChunkBytes (64 * 1024) -DelayMs 30) `
    'asset server listening on loopback'
$assetUrl = "http://127.0.0.1:$port/download/win-v9.9.9/Ghoztty-9.9.9-x64.msi"
$feed = New-Feed 'trickle.json' $assetUrl

Assert (Start-App $feed @('--auto-update=check')) 'app up with auto-update=check (nothing pre-downloaded)'
Assert (Wait-Log 'showing update balloon for win-v9\.9\.9') 'the app found win-v9.9.9 and offered it'
Assert ((Get-AppLog) -notmatch 'update download: staged') 'auto-update=check staged nothing before the click'

Assert (Invoke-ConsentedDownload) 'balloon click accepted and the confirm dialog OKed'
$panelSeen = (Wait-PanelWindow)
if ($NegativeControl) {
    Assert (-not $panelSeen) 'NEGATIVE CONTROL: inverted - the progress panel must NOT appear'
} else {
    Assert $panelSeen 'the progress panel window (GhozttyUpdateProgress) appeared'
}

# Let the transfer run out, then read what the panel said while it did.
Assert (Wait-Log 'update progress: .*(failed|complete)' 30000) 'the download reached a terminal state'
$tenths = Get-ProgressTenths
Assert ($tenths.Count -ge 2) "the panel reported progress more than once (got $($tenths.Count) lines)"
if ($tenths.Count -ge 2) {
    Assert ($tenths[-1] -gt $tenths[0]) `
        "the reported byte count ADVANCED ($($tenths[0]/10) MB -> $($tenths[-1]/10) MB)"
}
Assert ((Get-AppLog) -match 'update progress: [\d.]+ MB of [\d.]+ MB \(\d+%\)') `
    'the bar was DETERMINATE: a real Content-Length produced a percentage'
Assert ((Get-AppLog) -notmatch 'update progress: .*Stalled') `
    'a slow-but-moving transfer was never called stalled'
# The body is 12 MB of zeros, so it downloads fully and then fails the package
# check - a visible failure that arms no applier and runs no msiexec.
Assert ((Get-AppLog) -match 'update progress: The download failed') `
    'a download that turns out not to be a package fails VISIBLY'

Stop-AssetServer
Stop-DebugGhoztty

# --------------------------------------------------------------- 2: it stalls
Write-Host '== 2: a stalled transfer is called out, not left implying progress'
$port2 = Get-FreePort
# 2 MB arrives, then the server holds the connection open and sends nothing.
Assert (Start-AssetServer -Port $port2 -TotalBytes (12 * 1024 * 1024) -ChunkBytes (64 * 1024) `
        -DelayMs 10 -StopAfterBytes (2 * 1024 * 1024) -HangSeconds 30) `
    'asset server listening (stall mode)'
$assetUrl2 = "http://127.0.0.1:$port2/download/win-v9.9.9/Ghoztty-9.9.9-x64.msi"
$feed2 = New-Feed 'stall.json' $assetUrl2

Assert (Start-App $feed2 @('--auto-update=check')) 'app up for the stall scenario'
Assert (Wait-Log 'showing update balloon for win-v9\.9\.9') 'the app offered the release (stall scenario)'
Assert (Invoke-ConsentedDownload) 'consented to the download that will stall'
Assert (Wait-PanelWindow) 'the progress panel appeared (stall scenario)'
# The stall threshold is 10s; give it that plus slack.
Assert (Wait-Log 'update progress: Stalled' 25000) 'the panel said STALLED after the bytes stopped'
Assert ((Get-AppLog) -match 'update progress: Stalled.*no data for \d+s') `
    'the stall names how long it has been quiet, so it is not mistaken for slow'
Assert ((Get-AppLog) -match 'update progress: [\d.]+ MB of') `
    'the same run had shown real progress BEFORE it stalled'

Stop-AssetServer
Stop-DebugGhoztty

# ----------------------------------------------- 3: no chrome for a background fetch
Write-Host '== 3: the auto-update=download path shows no panel (nobody is waiting)'
$port3 = Get-FreePort
Assert (Start-AssetServer -Port $port3 -TotalBytes (8 * 1024 * 1024) -ChunkBytes (64 * 1024) -DelayMs 30) `
    'asset server listening (background pre-download)'
$assetUrl3 = "http://127.0.0.1:$port3/download/win-v9.9.9/Ghoztty-9.9.9-x64.msi"
$feed3 = New-Feed 'predownload.json' $assetUrl3

Assert (Start-App $feed3 @('--auto-update=download')) 'app up with auto-update=download'
# Watch across the whole pre-download, which is where a panel would appear if
# the policy split had been got wrong.
$panelDuringFetch = $false
for ($t = 0; $t -lt 12000; $t += 250) {
    if (@(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyUpdateProgress').Count -gt 0) {
        $panelDuringFetch = $true
        break
    }
    Start-Sleep -Milliseconds 250
}
Assert (-not $panelDuringFetch) 'no progress panel during an unprompted background download'
Assert ((Get-AppLog) -match 'update pre-download failed|update download:') `
    'CONTROL: the background download actually ran (so the absence above means something)'
Assert ((Get-AppLog) -notmatch 'update progress:') `
    'the background download reported no progress lines either'

Stop-AssetServer
Stop-DebugGhoztty

# ------------------------------------- 4: a transfer cut short is not a package
Write-Host '== 4: a download the network cuts off is refused, not staged (T1243)'
$port4 = Get-FreePort
# 12 MB promised, 2 MB delivered, then the connection closes. The read loop
# ends exactly the way a complete transfer ends, so only the Content-Length
# can tell the two apart.
Assert (Start-AssetServer -Port $port4 -TotalBytes (12 * 1024 * 1024) -ChunkBytes (64 * 1024) `
        -DelayMs 5 -StopAfterBytes (2 * 1024 * 1024) -HangSeconds 0) `
    'asset server listening (cut-off mode)'
$assetUrl4 = "http://127.0.0.1:$port4/download/win-v9.9.9/Ghoztty-9.9.9-x64.msi"
$feed4 = New-Feed 'cutoff.json' $assetUrl4

Assert (Start-App $feed4 @('--auto-update=check')) 'app up for the cut-off scenario'
Assert (Wait-Log 'showing update balloon for win-v9\.9\.9') 'the app offered the release (cut-off scenario)'
Assert (Invoke-ConsentedDownload) 'consented to the download that will be cut off'
Assert (Wait-Log 'the transfer was cut short' 30000) `
    'the short body was recognised as a cut-off transfer, not a finished one'
Assert ((Get-AppLog) -match 'update download failed: error\.Truncated') `
    'it failed as Truncated - the length check, not the package check, caught it'
Assert ((Get-AppLog) -notmatch 'update download: staged') `
    'nothing was staged, so no half-package can reach msiexec'
Assert ((Get-AppLog) -match 'update progress: The download failed') `
    'the panel said the download FAILED rather than "Download complete."'

Stop-AssetServer
Stop-DebugGhoztty

# ------------------------------- 5: a server with no Content-Length is unchanged
Write-Host '== 5: a server that sends no Content-Length still downloads (T1243)'
$port5 = Get-FreePort
Assert (Start-AssetServer -Port $port5 -TotalBytes (4 * 1024 * 1024) -ChunkBytes (64 * 1024) `
        -DelayMs 5 -NoLength 1) `
    'asset server listening (no Content-Length)'
$assetUrl5 = "http://127.0.0.1:$port5/download/win-v9.9.9/Ghoztty-9.9.9-x64.msi"
$feed5 = New-Feed 'nolength.json' $assetUrl5

Assert (Start-App $feed5 @('--auto-update=check')) 'app up for the no-length scenario'
Assert (Wait-Log 'showing update balloon for win-v9\.9\.9') 'the app offered the release (no-length scenario)'
Assert (Invoke-ConsentedDownload) 'consented to the length-less download'
Assert (Wait-Log 'update download failed' 30000) 'the length-less download reached a terminal state'
# 4 MB of zeros is a complete body that is not a package: the download ran to
# the end and the package check is what rejected it. A Truncated verdict here
# would mean the check had started guessing at an unknown length.
Assert ((Get-AppLog) -match 'update download failed: error\.NotAPackage') `
    'it ran to completion and failed the PACKAGE check, not the length check'
Assert ((Get-AppLog) -notmatch 'the transfer was cut short') `
    'an unknown length was never treated as a short read'

Stop-AssetServer

} finally {
    Write-Host '== teardown'
    Stop-AssetServer
    $script:launched = @(Get-TestLaunchedPids)
    Remove-TestDesktop
    Stop-DebugGhoztty
    Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
# The captured stderr IS the evidence for most of these assertions, so it only
# goes away on a clean run - a red that deletes its own diagnostics costs the
# next turn a whole reproduction.
if ($script:fail -eq 0) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
else { Write-Host "logs kept in $work" }
# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard update-progress -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) assertions)"; exit 0 }
else { Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red; exit 1 }
