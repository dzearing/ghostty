# Relay account acceptance (T21a store, T93 brokered model, T141 GUI move).
# Renamed from ipc-relay-login.ps1: there is no +relay-login verb any more.
#
#   powershell -NoProfile -File test\win32\relay-account.ps1
#
# T141 moved sign-in/sign-out out of the CLI and into the machine chooser's
# account row (the Mac has never had a CLI verb for it). So this script proves:
#
#   1. the CLI verbs are GONE - +relay-login / +relay-logout are rejected and
#      no longer appear in +help. This is the deliverable, so it is asserted
#      first and it is a hard failure, not a warning.
#   2. GUI sign-in end to end: ctrl+shift+n opens the chooser, its account
#      button reads "Sign in with Google...", clicking it starts the brokered
#      flow (PKCE + loopback), the harness plays the browser, the code is
#      exchanged at the RELAY, a DPAPI account.dat appears, and the row flips
#      to the signed-in email + "Sign Out" WITHOUT reopening the chooser.
#   3. GUI sign-out on the same row: POST /oauth/signout with the session
#      bearer, account.dat removed, button back to "Sign in with Google...".
#   4. sign-in against a dead relay: the flow fails, the chooser stays up and
#      says so, and no account is written.
#   5. legacy pre-T93 store: the GUI account tier treats it as signed out, and
#      says so WITHOUT naming a CLI verb.
#   6. renew + rotation: a near-expiry stored session is renewed at the STORED
#      relay (Bearer = old token) and the rotated token is persisted.
#   7. account tier E2E: with a fresh session, +new-remote-window WITHOUT
#      --token dials a live relay+agent (needs go + ghoztty-agent).
#
# Sections 5-7 SEED the account store directly (a DPAPI blob in the current
# shape) instead of re-driving the GUI: what they exercise is the reader/renew
# tier, and keeping the chord grabs to sections 2-4 keeps the script fast and
# deterministic.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1), so
# it never takes the user's foreground - asserted at the end, not assumed. The
# private win32 driver (AcctDrv) this script used to carry is gone. Three notes
# on what the migration changed beyond the mechanics:
#
#   * the chooser sections no longer SKIP. They used to bail out whenever the
#     foreground grab lost its race ("those sections need the foreground; they
#     SKIP, never fail"), which quietly took the whole GUI half of this script
#     out of a run. On the test desktop the chord always lands, so a chooser
#     that does not open is now a hard SETUP FAIL.
#   * the account button is still activated with Send-TestControlClick
#     (BM_CLICK) rather than a synthetic mouse click, for the original reason:
#     it keeps the assertions about the ROW - its label flipping, its enabled
#     state - independent of whether a click landed on the right pixel.
#   * sections 5-7 used to let `+new-window` AUTO-SPAWN the GUI, which puts a
#     window on the user's desktop. They launch it on the test desktop now.
#
# T171 hardened three things after one unreproducible failure whose text was
# lost - a run that produced 30 assertions out of a full 53 and then simply
# stopped, with no SKIP line to explain it:
#
#   * PORTS ARE PER-RUN, not fixed numbers. Each fake relay (and the live relay
#     in section 7) gets a port the OS just handed out, and the port is asserted
#     FREE immediately before it is bound.
#   * A fake relay is up when it ANSWERS ITS OWN NONCE, not when a TCP connect
#     succeeds. A connect also succeeds against a dying listener from the
#     previous run and against any unrelated process holding the port.
#   * A TERMINATING error is an assertion failure with its message and line,
#     not a silent end of run - and a failing run KEEPS its temp directory
#     (both GUIs' stderr, every CLI's stdout, both hit logs) and prints the
#     path. Losing that evidence is what made the original failure a mystery.
#
# Self-contained and non-interactive. A raw-TCP "fake relay" serves the
# brokered endpoints (POST /oauth/exchange | /oauth/renew | /oauth/signout) and
# logs every hit; the account store is redirected to a temp path
# (GHOSTTY_ACCOUNT_STORE) so the box's real account is never touched. Only ever
# touches ghoztty processes running from the repo zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$RelaySrc = 'D:\git\ghoztty\relay',
    # 0 = pick a port nobody holds, per run (see Get-FreePort). These used to be
    # fixed numbers, which is a latent trap: two runs back to back can meet on
    # the same port while the previous run's listener is still dying, and then
    # "something is listening" is true of a socket that will never answer.
    [int]$FakeAPort = 0,
    [int]$FakeBPort = 0,
    [int]$RelayPort = 0,
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Security
# Isolate the IPC endpoint (inherited through CreateProcessW by the GUI, and
# through the environment by every Run-Cli): an instance answering the shared
# pipe would answer this run's +list about somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-relayacct'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:failures = 0
$script:skipped = 0
$script:negReached = $false
$tmp = Join-Path $env:TEMP "ghoztty-relay-acct-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
New-Item -ItemType Directory -Force "$tmp\state" | Out-Null

# A port nobody holds: bind an ephemeral one and let it go. A port that WAS free
# a moment ago beats a guessed number - the fixed 47921/47922/47912 could still
# be held (or be in TIME_WAIT) from the previous run of this very script, which
# is hypothesis 1 of T171.
function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = $l.LocalEndpoint.Port
    $l.Stop()
    return $p
}

# Is this port bindable RIGHT NOW? Asserted before each fake relay starts, so a
# port that is still held fails loudly here instead of turning into a fake relay
# that never came up and a section that mysteriously produces no assertions.
function Test-PortFree([int]$port) {
    try {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $l.Start(); $l.Stop()
        return $true
    } catch { return $false }
}

if ($FakeAPort -eq 0) { $FakeAPort = Get-FreePort }
if ($FakeBPort -eq 0) { $FakeBPort = Get-FreePort }
if ($RelayPort -eq 0) { $RelayPort = Get-FreePort }

$AccountStore = "$tmp\account.dat"
$FakeABase = "http://127.0.0.1:$FakeAPort"
$FakeBBase = "http://127.0.0.1:$FakeBPort"
$RelayBase = "http://127.0.0.1:$RelayPort"
$SessTok = 'sess-e2e-1'
# Unique per run: what a fake relay echoes back so the harness can tell its own
# listener from any other process that has the port (T171).
$ProbeNonce = "n$PID-$(Get-Random -Minimum 100000 -Maximum 999999)"
$RenewedTok = 'sess-e2e-renewed'
$HitsA = "$tmp\hits-a.log"
$HitsB = "$tmp\hits-b.log"
# The signed-out button label, built with an explicit U+2026 so this file stays
# ASCII (the app renders a real ellipsis, matching the Mac's "Sign in with
# Google...").
$SignInLabel = "Sign in with Google$([char]0x2026)"

# Write-Host, not the pipeline: a helper that both asserts and RETURNS a value
# would otherwise hand its caller @('  PASS ...', $value) (the T217 batch-5
# trap), and Launch-Gui below does exactly that.
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name" }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}

function Get-Out($outfile) {
    if (Test-Path "$tmp\$outfile") { Get-Content "$tmp\$outfile" -Raw } else { '' }
}

function Get-Hits($hitsFile) {
    if (Test-Path $hitsFile) { Get-Content $hitsFile -Raw } else { '' }
}

# Run the CLI with a hard timeout (a hung GUI must fail the script, not hang it).
function Run-Cli($argsLine, $outfile, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$tmp\$outfile`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}

function Stop-TestProcs {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-relay-acct-e2e.exe'" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

# --- chooser control lookup --------------------------------------------------
# WHICH CONTROL IS WHICH comes from lib\ChooserControls.ps1 (T294), which
# TestDesktop.ps1 already dot-sources: `Get-ChooserAccountButton` (the LIVE one
# of the account row's two controls - T311 gave it a bordered button for the
# signed-out state and an owner-drawn link for the signed-in one, and hides
# whichever this state does not use), `Get-ChooserAccountStatusText` and
# `Get-ChooserHintText`.
#
# This script used to own private copies. Its account lookup identified the
# button by EXCLUDING the labels it is not (`New Window`, `Open`, `Cancel`) -
# an exclusion list that grows silently, and T177's Activity had just made it a
# member short. The repair keyed on position instead; the lookup asks the app
# for the control's own id now, so neither a new neighbour nor a relabel can
# reach it - and the LABEL stays free to be what the assertions here are about.
#
# Control text still comes from WM_GETTEXT, never GetWindowTextW, which is
# cross-process cached and reads stale for a label the app just changed in
# place - exactly this script's claim.

# Is `$h` the chooser itself or one of its descendants? Replaces the driver's
# GetParent walk: EnumChildWindows (Get-TestChildWindows) is recursive, so the
# membership test is the same statement without a second mechanism.
function Test-InsideChooser([IntPtr]$chooser, [IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return $false }
    if ($h -eq $chooser) { return $true }
    foreach ($c in Get-TestChildWindows -Window $chooser -Class '*') {
        if (([IntPtr]$c.Hwnd) -eq $h) { return $true }
    }
    return $false
}

# Start a raw-TCP fake relay serving the brokered OAuth endpoints (avoids
# HttpListener's URL-ACL admin requirement). Routes on the request line, logs
# "<METHOD> <PATH>|auth=<bearer>" per hit, and answers:
#   POST /oauth/exchange    -> 200 {session_token: $tok,      expiry: now+$ttl}
#   POST /oauth/renew       -> 200 {session_token: $renewTok, expiry: now+3600}
#   POST /oauth/signout     -> 204
#   GET  /v1/client/devices -> 200 {devices:[...]}
#   anything else           -> 404
#
# It also answers GET /__probe/<nonce> with that same nonce, which is how the
# harness tells THIS run's listener from whatever else happens to accept on the
# port (T171). Probe hits are deliberately not written to $hitsFile - the hit log
# is evidence about the app's traffic, and a harness probe in it would be a
# second thing every "did the app call X" assertion has to reason around.
function Start-FakeRelay($port, $tok, $ttl, $renewTok, $hitsFile, $nonce) {
    Start-Job -ScriptBlock {
        param($port, $tok, $ttl, $renewTok, $hitsFile, $nonce)
        function Resp200($body) {
            $p = [Text.Encoding]::UTF8.GetBytes($body)
            $h = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($p.Length)`r`nConnection: close`r`n`r`n"
            return ([Text.Encoding]::UTF8.GetBytes($h) + $p)
        }
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $r204 = [Text.Encoding]::UTF8.GetBytes("HTTP/1.1 204 No Content`r`nConnection: close`r`n`r`n")
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
                $auth = ''
                if ($req -match 'Authorization:\s*Bearer\s+(\S+)') { $auth = $matches[1] }
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                # The nonce guard is not paranoia: the first cut of this forgot to
                # pass $nonce into the job, and an empty one turns the pattern
                # into "any /__probe/ path", i.e. a probe that answers itself.
                $isProbe = ($nonce -and ($line -match "^GET /__probe/$nonce"))
                if (-not $isProbe) { Add-Content -Path $hitsFile -Value "$line|auth=$auth" }
                if ($isProbe) {
                    $out = Resp200 "{`"probe`":`"$nonce`"}"
                } elseif ($line -match '^POST /oauth/exchange') {
                    $body = "{`"session_token`":`"$tok`",`"expiry`":$($now + $ttl),`"email`":`"e2e@example.com`",`"picture`":`"https://x/p.png`"}"
                    $out = Resp200 $body
                } elseif ($line -match '^POST /oauth/renew') {
                    $body = "{`"session_token`":`"$renewTok`",`"expiry`":$($now + 3600),`"email`":`"e2e@example.com`"}"
                    $out = Resp200 $body
                } elseif ($line -match '^POST /oauth/signout') {
                    $out = $r204
                } elseif ($line -match '^GET /v1/client/devices') {
                    $out = Resp200 '{"devices":[{"id":"dev-e2e","name":"E2E-Box","hostname":"e2e.local","online":true}]}'
                } else {
                    $out = $r404
                }
                $stream.Write($out, 0, $out.Length)
                $stream.Flush()
            } catch {}
            $client.Close()
        }
    } -ArgumentList $port, $tok, $ttl, $renewTok, $hitsFile, $nonce
}

# Wait until the fake relay ANSWERS - not merely until something accepts on the
# port (T171). A TCP connect succeeds against a listener that is being torn down
# and against any unrelated process that happened to grab the port; only the
# nonce coming back proves the thing behind it is this run's fake relay and that
# it is serving requests. Returns the failure reason so the assertion can say
# what it saw.
function Wait-FakeRelay($port, $nonce) {
    $why = 'never tried'
    foreach ($i in 1..20) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 `
                -Uri "http://127.0.0.1:$port/__probe/$nonce"
            if ($r.StatusCode -eq 200 -and $r.Content -match [regex]::Escape($nonce)) {
                return @{ Ok = $true; Why = '' }
            }
            $why = "answered $($r.StatusCode) without the nonce"
        } catch { $why = $_.Exception.Message }
        Start-Sleep -Milliseconds 250
    }
    return @{ Ok = $false; Why = $why }
}

# Launch a GUI ON THE TEST DESKTOP, wired to a fake relay + a temp account
# store, with the browser open suppressed so the harness plays the browser
# itself. Session persistence off so a restore cannot hand this run a previous
# run's window (the T131 lesson). Returns { App, Pid, Top, Surface }.
function Launch-Gui($relayBase, $errlog) {
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
    $env:GHOSTTY_RELAY_BASE = $relayBase
    $env:GHOSTTY_GOOGLE_CLIENT_ID = 'cid-e2e'
    $env:GHOSTTY_OAUTH_AUTH_ENDPOINT = "$FakeABase/authorize"
    $env:GHOZTTY_ENROLL_NO_OPEN = '1'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    foreach ($k in 'GHOSTTY_ACCOUNT_STORE', 'GHOSTTY_RELAY_BASE', 'GHOSTTY_GOOGLE_CLIENT_ID',
        'GHOSTTY_OAUTH_AUTH_ENDPOINT', 'GHOZTTY_ENROLL_NO_OPEN') {
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

# Open the chooser with ctrl+shift+n. Returns the chooser HWND, or
# [IntPtr]::Zero - which on the test desktop means the product did not open it,
# not that the harness lost a foreground race.
function Open-Chooser($g) {
    if (-not (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N)) {
        return [IntPtr]::Zero
    }
    $chooser = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    if ($chooser -ne [IntPtr]::Zero) { Start-Sleep -Milliseconds 400 }
    return $chooser
}

# Play the browser: the GUI logs "open this URL to sign in: <url>" to stderr;
# parse the redirect_uri + state out of it and GET the redirect with a code.
function Complete-BrowserRedirect($errlog, $timeoutSec = 20) {
    $redir = $null; $state = $null
    foreach ($i in 1..($timeoutSec * 4)) {
        Start-Sleep -Milliseconds 250
        $c = Get-Content $errlog -Raw -ErrorAction SilentlyContinue
        if ($c -and $c -match 'open this URL to sign in: (\S+)') {
            $url = $matches[1]
            if ($url -match 'redirect_uri=([^&\s]+)') { $redir = [uri]::UnescapeDataString($matches[1]) }
            if ($url -match 'state=([^&\s]+)') { $state = $matches[1] }
            if ($redir -and $state) { break }
        }
    }
    if (-not ($redir -and $state)) { return $false }
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 `
            -Uri "$redir/?code=FAKECODE-123&state=$state" | Out-Null
    } catch {}
    return $true
}

# Wait for a stderr line to appear (the GUI's own account-flow telemetry).
function Wait-Stderr($errlog, $pattern, $timeoutSec = 15) {
    foreach ($i in 1..($timeoutSec * 4)) {
        Start-Sleep -Milliseconds 250
        $e = Get-Content $errlog -Raw -ErrorAction SilentlyContinue
        if ($e -and $e -match $pattern) { return $true }
    }
    return $false
}

# Seed the account store with a DPAPI blob in the CURRENT (T93) shape.
function Write-AccountStore($token, $ttlSeconds, $relayBase) {
    $exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $ttlSeconds
    $json = "{`"session_token`":`"$token`",`"expiry`":$exp,`"email`":`"e2e@example.com`",`"relay_base`":`"$relayBase`"}"
    $enc = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($json), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($AccountStore, $enc)
}

# Write a pre-T93 (direct-Google) account store: DPAPI-protected legacy JSON.
function Write-LegacyStore {
    $json = '{"client_id":"cid-old","client_secret":"sec-old","refresh_token":"rt-legacy","email":"legacy@example.com"}'
    $enc = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($json), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($AccountStore, $enc)
}

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found"; exit 1 }
$exeAge = (Get-Date) - (Get-Item $Exe).LastWriteTime
if ($exeAge.TotalHours -gt 6) {
    "  WARN $Exe is $([int]$exeAge.TotalHours)h old - rebuild before trusting a pass"
}

Stop-TestProcs
Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
# The CLI forwards its own GHOSTTY_RELAY_TOKEN as --token, which would bypass
# the account tier under test - make sure it is absent for the whole run.
$savedTok = $env:GHOSTTY_RELAY_TOKEN
Remove-Item env:GHOSTTY_RELAY_TOKEN -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$jobA = $null; $jobB = $null

try {
    "== 0: start the fake brokered relays"
    "  ports: A=$FakeAPort B=$FakeBPort relay=$RelayPort  logs: $tmp"
    Assert "fake relay A port $FakeAPort is free before we bind it" (Test-PortFree $FakeAPort)
    Assert "fake relay B port $FakeBPort is free before we bind it" (Test-PortFree $FakeBPort)
    $jobA = Start-FakeRelay $FakeAPort $SessTok 3600 $RenewedTok $HitsA $ProbeNonce
    $jobB = Start-FakeRelay $FakeBPort $SessTok 30 $RenewedTok $HitsB $ProbeNonce
    $upA = Wait-FakeRelay $FakeAPort $ProbeNonce
    if (-not $upA.Ok) { "  (relay A never answered: $($upA.Why))" }
    Assert "fake relay A answers its probe" $upA.Ok
    $upB = Wait-FakeRelay $FakeBPort $ProbeNonce
    if (-not $upB.Ok) { "  (relay B never answered: $($upB.Why))" }
    $fakeBUp = $upB.Ok
    Assert "fake relay B answers its probe" $fakeBUp

    "== 1: the +relay-login / +relay-logout CLI verbs are gone (T141)"
    $code = Run-Cli '+relay-login --no-browser' 'gone1.out' 10
    Assert "+relay-login rejected" ($code -ne 0 -and $null -ne $code)
    Assert "+relay-login is reported as unrecognized" (
        (Get-Out 'gone1.out') -match 'unknown|invalid|no such|[Uu]nrecognized|not a valid')
    $code = Run-Cli '+relay-logout' 'gone2.out' 10
    Assert "+relay-logout rejected" ($code -ne 0 -and $null -ne $code)
    $code = Run-Cli '+help' 'help.out' 15
    $help = Get-Out 'help.out'
    Assert "+help does not advertise relay-login" (-not ($help -match 'relay-login'))
    Assert "+help does not advertise relay-logout" (-not ($help -match 'relay-logout'))
    Assert "+help still lists new-remote-window (positive control)" ($help -match 'new-remote-window')

    "== 2/3: GUI sign-in then sign-out from the chooser's account row"
    $errlog = "$tmp\gui-a.stderr.log"
    Remove-Item $AccountStore -ErrorAction SilentlyContinue
    $g = Launch-Gui $FakeABase $errlog
    if (-not $g) { Write-Host 'SETUP FAIL: GUI did not come up for the sign-in section'; $script:failures++; exit 1 }
    Assert "sign-in GUI is NOT enumerable on the interactive desktop" (
        -not (Test-TestDesktopLeak -ProcessId $g.Pid))

    $chooser = Open-Chooser $g
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: ctrl+shift+n opened no chooser'; $script:failures++; exit 1 }
    Assert "chooser opened" ($chooser -ne [IntPtr]::Zero)
    # A chooser is modal over its own window: the owner is disabled for exactly
    # as long as it is up. Cross-process, that is the only checkable form of
    # "modal", and nothing in the old script asserted it.
    Assert "owner window is disabled while the chooser is up" (
        -not (Test-TestWindowEnabled -Window $g.Top))

    $btn = Get-ChooserAccountButton -Chooser $chooser
    Assert "account row has a button" ($null -ne $btn)
    Assert "signed-out label is the Google sign-in" ($null -ne $btn -and $btn.Text -eq $SignInLabel)
    Assert "signed-out status says 'Not signed in'" ((Get-ChooserAccountStatusText -Chooser $chooser) -eq 'Not signed in')

    if ($null -ne $btn) {
        Send-TestControlClick -Control $btn.Hwnd | Out-Null
        # The flow runs off the GUI thread, so the chooser must still be up (and
        # its button in a disabled pending state) while the "browser" is open. A
        # synchronous sign-in would fail this.
        Start-Sleep -Milliseconds 800
        Assert "chooser still up while signing in" (Test-TestWindowExists -Window $chooser)
        $busy = Get-ChooserAccountButton -Chooser $chooser
        Assert "button disabled while signing in" ($null -ne $busy -and -not $busy.Enabled)
        # Disabling the focused button would drop keyboard focus for the whole
        # dialog (WM_KEYDOWN then arrives with hwnd == NULL and Enter/Escape/Tab
        # stop being routed). The row must hand focus off before it disables the
        # button.
        $busyFocus = Get-TestFocusedWindow -Window $chooser
        Assert "keyboard focus stays inside the chooser while busy" (
            $busyFocus -ne [IntPtr]::Zero -and (Test-InsideChooser $chooser $busyFocus))

        Assert "browser redirect delivered" (Complete-BrowserRedirect $errlog)
        Assert "GUI reports sign_in ok" (Wait-Stderr $errlog 'relay account: sign_in ok')
        Assert "exchange hit the relay" ((Get-Hits $HitsA) -match 'POST /oauth/exchange')
        Assert "account.dat written" (Test-Path $AccountStore)
        $blob = if (Test-Path $AccountStore) { Get-Content $AccountStore -Raw } else { '' }
        Assert "account.dat is not plaintext" (-not ($blob -match 'session_token'))

        # The row updates IN PLACE - no reopen.
        Start-Sleep -Milliseconds 600
        $after = Get-ChooserAccountButton -Chooser $chooser
        # -NegativeControl inverts THIS one: "signing in through the chooser's
        # account row flips the row to signed-in, in place" is the claim T141
        # exists for, and it normally passes, so the control discriminates.
        $flipped = ($null -ne $after -and $after.Text -eq 'Sign Out')
        $script:negReached = $true
        if ($NegativeControl) {
            Assert "NEGATIVE CONTROL: button did NOT flip to 'Sign Out'" (-not $flipped)
        } else {
            Assert "button flipped to 'Sign Out'" $flipped
        }
        Assert "button re-enabled" ($null -ne $after -and $after.Enabled)
        Assert "status shows the signed-in email" ((Get-ChooserAccountStatusText -Chooser $chooser) -eq 'e2e@example.com')
        Assert "device list refetched after sign-in" ((Get-Hits $HitsA) -match 'GET /v1/client/devices')

        "  -- 3: sign out on the same row"
        if ($null -ne $after) {
            Send-TestControlClick -Control $after.Hwnd | Out-Null
            Assert "GUI reports sign_out ok" (Wait-Stderr $errlog 'relay account: sign_out ok')
            Assert "signout hit with the session bearer" (
                (Get-Hits $HitsA) -match [regex]::Escape("POST /oauth/signout HTTP/1.1|auth=$SessTok"))
            Assert "account.dat gone" (-not (Test-Path $AccountStore))
            Start-Sleep -Milliseconds 500
            $out = Get-ChooserAccountButton -Chooser $chooser
            Assert "button back to the Google sign-in" ($null -ne $out -and $out.Text -eq $SignInLabel)
            Assert "status back to 'Not signed in'" ((Get-ChooserAccountStatusText -Chooser $chooser) -eq 'Not signed in')
            Assert "hint says signed out" ((Get-ChooserHintText -Chooser $chooser) -match 'Signed out|Already signed out')
        }
    }

    # The chooser reads raw WM_KEYDOWN through App.run's routing (it is not a
    # standard #32770), so a POSTED Escape reaches it.
    Send-TestControlKey -Control $chooser -Key Escape | Out-Null
    Start-Sleep -Milliseconds 400
    Assert "Escape closed the chooser" (-not (Test-TestWindowExists -Window $chooser))
    Assert "owner window is enabled again once the chooser is gone" (
        Test-TestWindowEnabled -Window $g.Top)
    Assert "app survived the account flow" (-not ($g.App.Process -and $g.App.Process.HasExited))

    if ($g.App.Process -and -not $g.App.Process.HasExited) {
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800

    "== 4: sign-in against a dead relay -> fails, no account, chooser says so"
    $errlog2 = "$tmp\gui-dead.stderr.log"
    Remove-Item $AccountStore -ErrorAction SilentlyContinue
    $g2 = Launch-Gui 'http://127.0.0.1:1' $errlog2
    if (-not $g2) { Write-Host 'SETUP FAIL: GUI did not come up for the dead-relay section'; $script:failures++; exit 1 }
    Assert "dead-relay GUI is NOT enumerable on the interactive desktop" (
        -not (Test-TestDesktopLeak -ProcessId $g2.Pid))
    $ch2 = Open-Chooser $g2
    Assert "chooser opened (dead relay)" ($ch2 -ne [IntPtr]::Zero)
    if ($ch2 -ne [IntPtr]::Zero) {
        $b2 = Get-ChooserAccountButton -Chooser $ch2
        if ($null -ne $b2) { Send-TestControlClick -Control $b2.Hwnd | Out-Null }
        Assert "browser redirect delivered (dead relay)" (Complete-BrowserRedirect $errlog2)
        Assert "GUI reports sign_in failed" (Wait-Stderr $errlog2 'relay account: sign_in failed')
        Assert "no account.dat after failed sign-in" (-not (Test-Path $AccountStore))
        Start-Sleep -Milliseconds 500
        Assert "chooser survived the failure" (Test-TestWindowExists -Window $ch2)
        Assert "the failure is reported in the chooser" ((Get-ChooserHintText -Chooser $ch2) -match "ouldn't|failed|not completed")
        $b2b = Get-ChooserAccountButton -Chooser $ch2
        Assert "button re-enabled after failure" (
            $null -ne $b2b -and $b2b.Enabled -and $b2b.Text -eq $SignInLabel)
    }
    Assert "app survived a failed sign-in" (-not ($g2.App.Process -and $g2.App.Process.HasExited))
    if ($g2.App.Process -and -not $g2.App.Process.HasExited) {
        Stop-Process -Id $g2.Pid -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800

    # Sections 5-7 are CLI/reader-tier claims, but they still need a GUI for
    # +new-window / +new-remote-window to land in. Launching it here (rather
    # than letting the CLI auto-spawn it) is what keeps the window off the
    # user's desktop - an auto-spawn inherits the CLI's desktop, not this one.
    "== 5: legacy pre-T93 store -> the GUI account tier treats it as signed out"
    Write-LegacyStore
    Assert "legacy store staged" (Test-Path $AccountStore)
    $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
    $g3 = Launch-Gui $FakeABase "$tmp\gui-cli.stderr.log"
    if (-not $g3) { Write-Host 'SETUP FAIL: GUI did not come up for the CLI sections'; $script:failures++; exit 1 }
    Assert "CLI-section GUI is NOT enumerable on the interactive desktop" (
        -not (Test-TestDesktopLeak -ProcessId $g3.Pid))
    $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
    $code = Run-Cli '+new-window --target=acctbase' 'acctbase.out'
    Assert "base window exit 0" ($code -eq 0)
    Start-Sleep -Seconds 2
    $code = Run-Cli "+new-remote-window --relay=$FakeABase --device=zzz" 'legacyopen.out' 30
    $legacyOut = Get-Out 'legacyopen.out'
    Assert "legacy account tier refuses" ($code -ne 0 -and $legacyOut -match 'not signed in')
    Assert "refusal points at the chooser, not a deleted CLI verb" (
        $legacyOut -match 'machine chooser' -and -not ($legacyOut -match 'relay-login'))

    "== 6: near-expiry stored session -> renewed at the stored relay, rotation persisted"
    if (-not $fakeBUp) {
        "  SKIP renew case (fake relay B did not start)"
        $script:skipped++
    } else {
        Write-AccountStore $SessTok 30 $FakeBBase
        # The dial itself fails (fake relay has no ws endpoint) - what matters is
        # that the GUI RENEWED first (Bearer = the old token) instead of refusing.
        $code = Run-Cli "+new-remote-window --relay=$FakeBBase --device=zzz" 'renewopen.out' 30
        Assert "renew hit with the old bearer" (
            (Get-Hits $HitsB) -match [regex]::Escape("POST /oauth/renew HTTP/1.1|auth=$SessTok"))
        Assert "dial proceeded past auth (not 'not signed in')" ((Get-Out 'renewopen.out') -match 'failed to reach zzz')
        $plain = ''
        try {
            $raw = [IO.File]::ReadAllBytes($AccountStore)
            $plain = [Text.Encoding]::UTF8.GetString(
                [Security.Cryptography.ProtectedData]::Unprotect($raw, $null, 'CurrentUser'))
        } catch {}
        Assert "rotated token persisted" ($plain -match [regex]::Escape($RenewedTok))
    }

    "== 7: account tier -> +new-remote-window with NO --token (live relay+agent)"
    $haveGo = [bool](Get-Command go -ErrorAction SilentlyContinue)
    $haveAgent = Test-Path $AgentExe
    if (-not ($haveGo -and $haveAgent)) {
        "  SKIP account-tier open (need go + ghoztty-agent; go=$haveGo agent=$haveAgent)"
        $script:skipped++
    } else {
        Push-Location $RelaySrc
        & go build -o "$tmp\ghoztty-relay-acct-e2e.exe" . 2>&1 | Select-Object -Last 2
        $goExit = $LASTEXITCODE
        Pop-Location
        Assert "relay builds" ($goExit -eq 0)

        if ($goExit -eq 0) {
            # The relay's DEV_AUTH accepts a client bearer only if it exactly equals
            # DEV_CLIENT_TOKEN. The account tier presents the stored relay session
            # token, so set DEV_CLIENT_TOKEN to that same value - then the
            # account-tier bearer is accepted end to end.
            Assert "relay port $RelayPort is free before we bind it" (Test-PortFree $RelayPort)
            $env:LISTEN_ADDR = "127.0.0.1:$RelayPort"; $env:METRICS_ADDR = '127.0.0.1:0'
            $env:DEV_AUTH = 'true'; $env:DEV_CLIENT_TOKEN = $SessTok
            $env:DEV_EMAIL = 'dev@example.com'; $env:STATE_DIR = "$tmp\state"
            $relay = Start-Process -FilePath "$tmp\ghoztty-relay-acct-e2e.exe" -PassThru -WindowStyle Hidden
            foreach ($k in 'LISTEN_ADDR', 'METRICS_ADDR', 'DEV_AUTH', 'DEV_CLIENT_TOKEN', 'DEV_EMAIL', 'STATE_DIR') {
                Remove-Item "env:$k" -ErrorAction SilentlyContinue
            }
            $healthy = $false
            foreach ($i in 1..20) {
                try { if ((Invoke-WebRequest -UseBasicParsing -Uri "$RelayBase/healthz" -TimeoutSec 2).StatusCode -eq 200) { $healthy = $true; break } }
                catch { Start-Sleep -Milliseconds 500 }
            }
            Assert "relay healthy" $healthy

            $dev = $null
            try {
                $dev = Invoke-RestMethod -Method Post -Uri "$RelayBase/v1/client/devices" `
                    -Headers @{ Authorization = "Bearer $SessTok" } `
                    -ContentType 'application/json' -Body '{"name":"acct-e2e"}'
            } catch {}
            Assert "device enrolled" ($null -ne $dev -and $dev.id)

            if ($healthy -and $dev) {
                # A fresh (long expiry) stored session so the account tier serves
                # the cached token without a renew.
                Write-AccountStore $SessTok 3600 $RelayBase

                $env:GHOSTTY_DEVICE_TOKEN = $dev.token
                $env:GHOSTTY_AGENT_HEARTBEAT = "$tmp\agent.heartbeat"
                $agent = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
                    -ArgumentList "--relay=$RelayBase", "--headless"
                Remove-Item env:GHOSTTY_DEVICE_TOKEN -ErrorAction SilentlyContinue
                Remove-Item env:GHOSTTY_AGENT_HEARTBEAT -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
                Assert "agent running" (-not $agent.HasExited)

                $code = Run-Cli "+new-remote-window --relay=$RelayBase --device=$($dev.id) --name=acctwin" 'acctopen.out' 30
                Assert "account-tier open exit 0 (no --token)" ($code -eq 0)
                Start-Sleep -Seconds 2
                $code = Run-Cli '+list' 'acctlist.out'
                Assert "account-tier window registered" ((Get-Out 'acctlist.out') -match '\[target: acctwin\]')

                Run-Cli '+close --target=acctwin' 'acctclose.out' | Out-Null
                if ($agent) { Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue }
            }
            if ($relay) { Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    "== cleanup"
    Run-Cli '+close --target=acctbase' 'acctclosebase.out' | Out-Null
} catch {
    # $ErrorActionPreference is Continue, so a NON-terminating error prints and
    # the run carries on - but a terminating one (a marshalling failure, a
    # web-request throw) used to end the run with the remaining sections simply
    # never producing assertions, and no line saying why. That is the shape T171
    # was filed over: assertions stop, no SKIP, nothing to read.
    Write-Host "  FAIL script terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    $script:failures++
} finally {
    Remove-TestDesktop
    Remove-Item env:GHOSTTY_ACCOUNT_STORE -ErrorAction SilentlyContinue
    if ($null -ne $savedTok) { $env:GHOSTTY_RELAY_TOKEN = $savedTok }
    Stop-TestProcs
    foreach ($j in @($jobA, $jobB)) {
        if ($j) { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue }
    }
    # A failing run keeps its evidence (both GUIs' stderr, every CLI's stdout,
    # both relays' hit logs). Deleting it was how T171's failure text was lost -
    # a tidy summary line is worth less than the run's own logs.
    if ($script:failures -eq 0) {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    } else {
        Write-Host "  logs kept: $tmp"
    }
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run by
    # now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    Assert "the run actually launched apps on the test desktop" ($launched.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

# A -NegativeControl run that never reached the inverted assertion proves
# nothing, so say so instead of exiting green.
if ($NegativeControl -and -not $script:negReached) {
    Assert "NEGATIVE CONTROL never reached its inverted assertion" $false
}

if ($script:skipped -gt 0) { "($($script:skipped) section(s) SKIPPED)" }
if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
