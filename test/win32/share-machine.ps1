# Share-this-machine toggle acceptance (T547): the machine chooser's account
# row carries a per-machine "Share this machine" checkbox that writes the
# agent's sharing.json and, on a machine with no device credential, runs
# browser-less device enrollment first.
#
#   powershell -NoProfile -File test\win32\share-machine.ps1
#
# Covers, end to end against a fake relay on loopback:
#   A. the checkbox EXISTS in the chooser's account row, visible, enabled and
#      UNCHECKED when no sharing.json exists (opt-in default, decision D22).
#   B. with a credential already in relay.env, one click writes
#      {"enabled":true} to sharing.json with NO enrollment traffic, and the
#      box checks. The credential file is untouched.
#   C. a second click writes {"enabled":false} and unchecks; the credential
#      is KEPT (toggling off is not a sign-out).
#   D. with relay.env DELETED, a click runs the real enrollment flow against
#      the fake relay (/v1/enroll/start web flow, /v1/enroll/poll -> complete),
#      persists relay.env with the granted token, THEN enables sharing.
#   E. the state survives closing and reopening the chooser: a fresh chooser
#      reads sharing.json and opens checked.
#   F. enrollment failure (relay unreachable) leaves the box UNCHECKED and
#      sharing DISABLED - the box never shows a state the work did not reach.
#
# Hermetic: GHOSTTY_SHARING_CONFIG and GHOSTTY_RELAY_ENV point both files at a
# scratch dir (the same overrides the agent's own path resolution honors, so
# the app writes exactly where a real agent would read); GHOSTTY_RELAY_BASE
# aims the chooser at the fake relay; GHOZTTY_ENROLL_NO_OPEN suppresses the
# real browser. Runs on the background test desktop (T217) and only ever
# touches ghoztty processes from the repo zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t547-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$sharingCfg = Join-Path $tmp 'sharing.json'
$relayEnv = Join-Path $tmp 'relay.env'
$hitsFile = Join-Path $tmp 'relay-hits.log'
$errlog = Join-Path $tmp 'gui-stderr.log'
$nonce = [guid]::NewGuid().ToString('N')

if (-not (Test-Path $Exe)) {
    "SKIP whole run: $Exe not built"
    Write-TestVerdict -Label 'T547 SHARE MACHINE' -Pass 0 -Fail 0 -Skipped 1
}

# The build-mode gate (T350): a non-debug zig-out derives the USER's endpoints.
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe

# T248 shared reset, exact-exe scoped.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
function Stop-DebugGhoztty { Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null }

function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

# A fake relay serving the ENROLL endpoints. Start answers the web flow with an
# enroll_url (nobody visits it - the poll completes immediately, which is the
# legitimate "owner already approved in the browser" timeline compressed);
# poll answers complete with the device credential. Every non-probe hit is
# logged so section B can assert the ABSENCE of enrollment traffic.
function Start-FakeRelay($port, $hitsFile, $nonce) {
    Start-Job -ScriptBlock {
        param($port, $hitsFile, $nonce)
        function Resp200($body) {
            $p = [Text.Encoding]::UTF8.GetBytes($body)
            $h = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($p.Length)`r`nConnection: close`r`n`r`n"
            return ([Text.Encoding]::UTF8.GetBytes($h) + $p)
        }
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $r404 = [Text.Encoding]::UTF8.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                Start-Sleep -Milliseconds 80
                $buf = New-Object byte[] 16384
                $req = ''
                while ($stream.DataAvailable) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $req += [Text.Encoding]::UTF8.GetString($buf, 0, $n)
                }
                $line = ($req -split "`r`n")[0]
                $isProbe = ($nonce -and ($line -match "^GET /__probe/$nonce"))
                if (-not $isProbe) { Add-Content -Path $hitsFile -Value $line }
                if ($isProbe) {
                    $out = Resp200 "{`"probe`":`"$nonce`"}"
                } elseif ($line -match '^POST /v1/enroll/start') {
                    $out = Resp200 "{`"enroll_url`":`"http://127.0.0.1:$port/enroll/e2e`",`"device_code_handle`":`"h-t547`",`"interval`":1,`"expires_in`":60}"
                } elseif ($line -match '^POST /v1/enroll/poll') {
                    $out = Resp200 "{`"status`":`"complete`",`"device_id`":`"dev-t547`",`"device_token`":`"tok-enrolled-t547`",`"relay_base`":`"http://127.0.0.1:$port`"}"
                } elseif ($line -match '^GET /v1/client/devices') {
                    $out = Resp200 '{"devices":[]}'
                } else {
                    $out = $r404
                }
                $stream.Write($out, 0, $out.Length)
                $stream.Flush()
            } catch {}
            $client.Close()
        }
    } -ArgumentList $port, $hitsFile, $nonce
}

function Wait-FakeRelay($port, $nonce) {
    foreach ($i in 1..20) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri "http://127.0.0.1:$port/__probe/$nonce"
            if ($r.StatusCode -eq 200 -and $r.Content -match [regex]::Escape($nonce)) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# The share checkbox inside a chooser: the BUTTON whose text is the T547 label.
function Get-ShareCheckbox([IntPtr]$chooser) {
    $c = @(Get-TestControls -Window $chooser -Class 'Button' |
        Where-Object { $_.Text -eq 'Share this machine' })
    if ($c.Count -ge 1) { return $c[0] }
    return $null
}

function Get-ShareChecked([IntPtr]$chooser) {
    $cb = Get-ShareCheckbox $chooser
    if ($null -eq $cb) { return $null }
    # BM_GETCHECK = 0x00F0; BST_CHECKED = 1
    return ((Invoke-TestMessage -Window $cb.Hwnd -Message 0x00F0) -eq 1)
}

# Wait until sharing.json exists and reports the wanted enabled value.
function Wait-SharingEnabled([bool]$want, [int]$timeoutSec = 8) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $sharingCfg) {
            $raw = Get-Content $sharingCfg -Raw -ErrorAction SilentlyContinue
            if ($raw -match '"enabled"\s*:\s*true' -and $want) { return $true }
            if ($raw -match '"enabled"\s*:\s*false' -and -not $want) { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Launch-Gui($relayBase) {
    $env:GHOSTTY_SHARING_CONFIG = $sharingCfg
    $env:GHOSTTY_RELAY_ENV = $relayEnv
    $env:GHOSTTY_RELAY_BASE = $relayBase
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    $env:GHOZTTY_ENROLL_NO_OPEN = '1'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    foreach ($k in 'GHOSTTY_SHARING_CONFIG', 'GHOSTTY_RELAY_ENV', 'GHOSTTY_RELAY_BASE',
        'GHOSTTY_ACCOUNT_STORE', 'GHOZTTY_ENROLL_NO_OPEN') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

function Open-Chooser($g) {
    if (-not (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N)) {
        return [IntPtr]::Zero
    }
    $chooser = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    if ($chooser -ne [IntPtr]::Zero) { Start-Sleep -Milliseconds 400 }
    return $chooser
}

$port = Get-FreePort
$relayJob = Start-FakeRelay $port $hitsFile $nonce
if (-not (Wait-FakeRelay $port $nonce)) {
    "SETUP FAIL: fake relay never answered on port $port"
    Stop-Job $relayJob -ErrorAction SilentlyContinue; Remove-Job $relayJob -Force -ErrorAction SilentlyContinue
    Write-TestVerdict -Label 'T547 SHARE MACHINE' -Pass 0 -Fail 1
}

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    "== A: the toggle exists, unchecked by default (opt-in, D22)"
    $g = Launch-Gui "http://127.0.0.1:$port"
    if ($null -eq $g) { throw 'SETUP FAIL: GUI did not come up' }
    $chooser = Open-Chooser $g
    Assert 'chooser opened' ($chooser -ne [IntPtr]::Zero)
    if ($chooser -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no chooser to score' }
    $cb = Get-ShareCheckbox $chooser
    Assert 'share checkbox present in the account row' ($null -ne $cb)
    if ($null -eq $cb) { throw 'SETUP FAIL: no checkbox to drive' }
    Assert 'share checkbox visible' $cb.Visible
    Assert 'share checkbox enabled' $cb.Enabled
    Assert 'unchecked with no sharing.json (sharing is opt-in)' ((Get-ShareChecked $chooser) -eq $false)
    Assert 'no sharing.json was created just by opening the chooser' (-not (Test-Path $sharingCfg))

    "== B: toggle on with an existing credential - one file write, no enrollment"
    Set-Content -Path $relayEnv -Value "RELAY_BASE=http://127.0.0.1:$port`nDEVICE_TOKEN=tok-seeded-t547`n" -Encoding ascii
    [void](Send-TestControlClick -Control $cb.Hwnd)
    Assert 'sharing.json says enabled:true' (Wait-SharingEnabled $true)
    Start-Sleep -Milliseconds 400
    Assert 'checkbox is checked' ((Get-ShareChecked $chooser) -eq $true)
    $envRaw = Get-Content $relayEnv -Raw -ErrorAction SilentlyContinue
    Assert 'credential file untouched by the flip' ($envRaw -match 'tok-seeded-t547')
    $hits = if (Test-Path $hitsFile) { Get-Content $hitsFile -Raw } else { '' }
    Assert 'no enrollment traffic when a credential exists' ($hits -notmatch '/v1/enroll/')

    "== C: toggle off keeps the credential"
    [void](Send-TestControlClick -Control $cb.Hwnd)
    Assert 'sharing.json says enabled:false' (Wait-SharingEnabled $false)
    Start-Sleep -Milliseconds 400
    Assert 'checkbox is unchecked' ((Get-ShareChecked $chooser) -eq $false)
    Assert 'credential KEPT on toggle-off (not a sign-out)' ((Get-Content $relayEnv -Raw -ErrorAction SilentlyContinue) -match 'tok-seeded-t547')

    "== D: toggle on with NO credential runs enrollment first"
    Remove-Item $relayEnv -Force -ErrorAction SilentlyContinue
    [void](Send-TestControlClick -Control $cb.Hwnd)
    # Enrollment: start + first poll at 1s interval, then the two file writes.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $relayEnv)) { Start-Sleep -Milliseconds 300 }
    Assert 'relay.env written by enrollment' (Test-Path $relayEnv)
    Assert 'relay.env carries the granted token' ((Get-Content $relayEnv -Raw -ErrorAction SilentlyContinue) -match 'tok-enrolled-t547')
    Assert 'sharing enabled after enrollment' (Wait-SharingEnabled $true 10)
    Start-Sleep -Milliseconds 600
    Assert 'checkbox checked after enrollment' ((Get-ShareChecked $chooser) -eq $true)
    $hits = if (Test-Path $hitsFile) { Get-Content $hitsFile -Raw } else { '' }
    Assert 'relay saw the enroll start' ($hits -match 'POST /v1/enroll/start')
    Assert 'relay saw the enroll poll' ($hits -match 'POST /v1/enroll/poll')

    "== E: the state survives closing and reopening the chooser"
    [void](Send-TestControlKey -Control $chooser -Key Escape)
    Start-Sleep -Milliseconds 600
    $chooser2 = Open-Chooser $g
    Assert 'chooser reopened' ($chooser2 -ne [IntPtr]::Zero)
    if ($chooser2 -ne [IntPtr]::Zero) {
        Assert 'fresh chooser opens CHECKED from sharing.json' ((Get-ShareChecked $chooser2) -eq $true)
    }
    Assert 'GUI never leaked to the interactive desktop' (-not (Test-TestDesktopLeak -ProcessId $g.Pid))

    "== F: enrollment failure leaves the toggle honestly OFF"
    Stop-DebugGhoztty
    Remove-Item $relayEnv -Force -ErrorAction SilentlyContinue
    Remove-Item $sharingCfg -Force -ErrorAction SilentlyContinue
    $deadPort = Get-FreePort   # freed immediately - nothing listens there
    $g2 = Launch-Gui "http://127.0.0.1:$deadPort"
    if ($null -eq $g2) { throw 'SETUP FAIL: second GUI did not come up' }
    $chooser3 = Open-Chooser $g2
    Assert 'chooser opened against the dead relay' ($chooser3 -ne [IntPtr]::Zero)
    if ($chooser3 -ne [IntPtr]::Zero) {
        $cb3 = Get-ShareCheckbox $chooser3
        Assert 'share checkbox present' ($null -ne $cb3)
        if ($null -ne $cb3) {
            [void](Send-TestControlClick -Control $cb3.Hwnd)
            # The dial fails fast (connection refused); give the revert time.
            $deadline = (Get-Date).AddSeconds(12)
            $reverted = $false
            while ((Get-Date) -lt $deadline) {
                $chk = Get-ShareChecked $chooser3
                $cbNow = Get-ShareCheckbox $chooser3
                if ($chk -eq $false -and $cbNow -and $cbNow.Enabled) { $reverted = $true; break }
                Start-Sleep -Milliseconds 400
            }
            Assert 'checkbox reverts to unchecked + enabled on failure' $reverted
            $enabledNow = (Test-Path $sharingCfg) -and ((Get-Content $sharingCfg -Raw -ErrorAction SilentlyContinue) -match '"enabled"\s*:\s*true')
            Assert 'sharing never enabled by a failed enrollment' (-not $enabledNow)
            Assert 'no relay.env from a failed enrollment' (-not (Test-Path $relayEnv))
        }
    }
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
    Stop-Job $relayJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $relayJob -Force -ErrorAction SilentlyContinue | Out-Null
}

$fgSeen = @(Stop-TestForegroundWatch)
"foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert 'the foreground watcher actually sampled (negative control)' ($fgSeen.Count -gt 0)
    Assert 'the run actually launched apps on the test desktop' ($launched.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert 'no test-desktop app ever became foreground' ($leaked.Count -eq 0)
}

if ($script:failures -gt 0) {
    "--- evidence kept at $tmp ---"
    if (Test-Path $errlog) {
        '--- gui stderr (share/enroll lines) ---'
        Select-String -Path $errlog -Pattern 'share|enroll|sharing' -ErrorAction SilentlyContinue | ForEach-Object { $_.Line }
    }
} else {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard share-machine -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'T547 SHARE MACHINE' -Pass $script:passes -Fail $script:failures -MinPass 28
