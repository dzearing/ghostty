# Relay account sign-in acceptance (tracker T21a, brokered model T93):
# +relay-login / +relay-logout against the relay's brokered OAuth endpoints,
# and the GUI account-tier of +new-remote-window (relay session token, renewed
# + rotated near expiry).
#
#   powershell -NoProfile -File test\win32\ipc-relay-login.ps1
#
# Self-contained and non-interactive. A raw-TCP "fake relay" serves the
# brokered endpoints (POST /oauth/exchange | /oauth/renew | /oauth/signout)
# and logs every hit; the account store is redirected to a temp path
# (GHOSTTY_ACCOUNT_STORE) so the box's real account is never touched. Covers:
#   1. +relay-login --no-browser end to end: PKCE + loopback redirect + code
#      handed to the RELAY's /oauth/exchange -> DPAPI account.dat written
#      (session token only - no Google token), "Signed in as <email>".
#   2. +relay-logout: POST /oauth/signout (Bearer = session token) observed,
#      account.dat removed, "Signed out".
#   3. exchange failure (dead relay) -> login exits nonzero, no account.
#   4. no client id anywhere -> clear error (build has no -Dgoogle-client-id).
#   5. legacy pre-T93 store (refresh_token shape): logout still works; the
#      GUI account tier treats it as signed out ("not signed in" error).
#   6. renew + rotation: a near-expiry session is renewed at the STORED relay
#      (Bearer = old token) and the rotated token is persisted.
#   7. account tier E2E: with a fresh session, +new-remote-window WITHOUT
#      --token dials a live relay+agent (needs go + ghoztty-agent).
#
# Only ever touches ghoztty processes running from the repo zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$RelaySrc = 'D:\git\ghoztty\relay',
    [int]$FakeAPort = 47921,
    [int]$FakeBPort = 47922,
    [int]$RelayPort = 47912
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Security
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-relay-login-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
New-Item -ItemType Directory -Force "$tmp\state" | Out-Null

$AccountStore = "$tmp\account.dat"
$FakeABase = "http://127.0.0.1:$FakeAPort"
$FakeBBase = "http://127.0.0.1:$FakeBPort"
$RelayBase = "http://127.0.0.1:$RelayPort"
$SessTok = 'sess-e2e-1'
$RenewedTok = 'sess-e2e-renewed'
$HitsA = "$tmp\hits-a.log"
$HitsB = "$tmp\hits-b.log"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
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
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-relay-login-e2e.exe'" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

# Start a raw-TCP fake relay serving the brokered OAuth endpoints (avoids
# HttpListener's URL-ACL admin requirement). Routes on the request line, logs
# "<METHOD> <PATH>|auth=<bearer>" per hit, and answers:
#   POST /oauth/exchange -> 200 {session_token: $tok,     expiry: now+$ttl, ...}
#   POST /oauth/renew    -> 200 {session_token: $renewTok, expiry: now+3600, ...}
#   POST /oauth/signout  -> 204
#   anything else        -> 404
function Start-FakeRelay($port, $tok, $ttl, $renewTok, $hitsFile) {
    Start-Job -ScriptBlock {
        param($port, $tok, $ttl, $renewTok, $hitsFile)
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
                Add-Content -Path $hitsFile -Value "$line|auth=$auth"
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                if ($line -match '^POST /oauth/exchange') {
                    $body = "{`"session_token`":`"$tok`",`"expiry`":$($now + $ttl),`"email`":`"e2e@example.com`",`"picture`":`"https://x/p.png`"}"
                    $out = Resp200 $body
                } elseif ($line -match '^POST /oauth/renew') {
                    $body = "{`"session_token`":`"$renewTok`",`"expiry`":$($now + 3600),`"email`":`"e2e@example.com`"}"
                    $out = Resp200 $body
                } elseif ($line -match '^POST /oauth/signout') {
                    $out = $r204
                } else {
                    $out = $r404
                }
                $stream.Write($out, 0, $out.Length)
                $stream.Flush()
            } catch {}
            $client.Close()
        }
    } -ArgumentList $port, $tok, $ttl, $renewTok, $hitsFile
}

function Wait-Listening($port) {
    foreach ($i in 1..20) {
        try {
            $t = [System.Net.Sockets.TcpClient]::new(); $t.Connect('127.0.0.1', $port); $t.Close()
            return $true
        } catch { Start-Sleep -Milliseconds 250 }
    }
    return $false
}

# Drive +relay-login --no-browser to completion by simulating the browser: the
# CLI prints the auth URL then blocks on its loopback listener; we parse the
# redirect_uri + state out of the URL and GET it with a code. Returns the login
# exit code; stdout lands in $tmp\$outfile.
function Invoke-Login($outfile, $relayBase, $extraArgs = '--client-id=cid-e2e', $timeoutSec = 25) {
    # Launch via cmd.exe (like Run-Cli): Start-Process -RedirectStandardOutput
    # leaves $p.ExitCode unpopulated, but a cmd redirect to a file both lets us
    # poll stdout live AND yields a real exit code.
    $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
    $env:GHOSTTY_OAUTH_AUTH_ENDPOINT = "$FakeABase/authorize"
    $argsLine = "+relay-login --no-browser $extraArgs --relay=$relayBase"
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$tmp\$outfile`" 2>&1`""
    foreach ($k in 'GHOSTTY_ACCOUNT_STORE', 'GHOSTTY_OAUTH_AUTH_ENDPOINT') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }

    $redir = $null; $state = $null
    foreach ($i in 1..60) {
        Start-Sleep -Milliseconds 250
        $c = Get-Content "$tmp\$outfile" -Raw -ErrorAction SilentlyContinue
        if ($c -and ($c -match 'redirect_uri=([^&\r\n]+)') ) {
            $redir = [uri]::UnescapeDataString($matches[1])
            if ($c -match 'state=([^&\r\n]+)') { $state = $matches[1] }
            break
        }
        if ($p.HasExited) { break }
    }
    if ($redir -and $state) {
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 `
                -Uri "$redir/?code=FAKECODE-123&state=$state" | Out-Null
        } catch {}
    }
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}

# Write a pre-T93 (direct-Google) account store: DPAPI-protected legacy JSON.
function Write-LegacyStore {
    $json = '{"client_id":"cid-old","client_secret":"sec-old","refresh_token":"rt-legacy","email":"legacy@example.com"}'
    $enc = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($json), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($AccountStore, $enc)
}

Stop-TestProcs
Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
# The CLI forwards its own GHOSTTY_RELAY_TOKEN as --token, which would bypass
# the account tier under test - make sure it is absent for the whole run.
$savedTok = $env:GHOSTTY_RELAY_TOKEN
Remove-Item env:GHOSTTY_RELAY_TOKEN -ErrorAction SilentlyContinue

"== 0: start the fake brokered relays"
$jobA = Start-FakeRelay $FakeAPort $SessTok 3600 $RenewedTok $HitsA
$jobB = Start-FakeRelay $FakeBPort $SessTok 30 $RenewedTok $HitsB
Assert "fake relay A listening" (Wait-Listening $FakeAPort)
$fakeBUp = Wait-Listening $FakeBPort
Assert "fake relay B listening" $fakeBUp
if (-not (Test-Path $HitsA) -and -not (Wait-Listening $FakeAPort)) {
    Stop-TestProcs; Get-Job | Stop-Job -ErrorAction SilentlyContinue; Get-Job | Remove-Job -Force
    "$($script:failures) FAILURE(S)"; exit 1
}

"== 1: +relay-login --no-browser end to end (brokered exchange)"
$code = Invoke-Login 'login1.out' $FakeABase
Assert "login exit 0" ($code -eq 0)
Assert "prints signed-in email" ((Get-Out 'login1.out') -match 'Signed in as e2e@example.com')
Assert "account.dat written" (Test-Path $AccountStore)
# DPAPI blob must not be plaintext JSON (it is encrypted at rest).
$blob = if (Test-Path $AccountStore) { Get-Content $AccountStore -Raw } else { '' }
Assert "account.dat is not plaintext" (-not ($blob -match 'session_token'))
Assert "exchange hit the relay" ((Get-Hits $HitsA) -match 'POST /oauth/exchange')

"== 2: +relay-logout revokes at the relay and removes the account"
$env:GHOSTTY_ACCOUNT_STORE = $AccountStore
$code = Run-Cli '+relay-logout' 'logout1.out'
Remove-Item env:GHOSTTY_ACCOUNT_STORE -ErrorAction SilentlyContinue
Assert "logout exit 0" ($code -eq 0)
Assert "logout says signed out" ((Get-Out 'logout1.out') -match 'Signed out')
Assert "account.dat gone" (-not (Test-Path $AccountStore))
Assert "signout hit with the session bearer" ((Get-Hits $HitsA) -match [regex]::Escape("POST /oauth/signout HTTP/1.1|auth=$SessTok"))

"== 3: relay unreachable -> login fails, no account written"
$code = Invoke-Login 'login2.out' 'http://127.0.0.1:1'
Assert "login exit nonzero" ($code -ne 0 -and $null -ne $code)
Assert "reports token exchange failure" ((Get-Out 'login2.out') -match 'Token exchange failed')
Assert "no account.dat after failed login" (-not (Test-Path $AccountStore))

"== 4: no client id -> clear error (unless a dev id file is present)"
if (Test-Path 'D:\git\ghoztty\macos\google-client-id.txt') {
    "  SKIP no-client-id case (dev google-client-id.txt bakes an id into this build)"
} else {
    $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
    $code = Run-Cli "+relay-login --no-browser --relay=$FakeABase" 'login3.out' 10
    Remove-Item env:GHOSTTY_ACCOUNT_STORE -ErrorAction SilentlyContinue
    Assert "id-less login exit nonzero" ($code -ne 0 -and $null -ne $code)
    Assert "id-less login names the fix" ((Get-Out 'login3.out') -match 'no Google OAuth client id')
}

"== 5: legacy pre-T93 store -> logout tolerates it; GUI treats it as signed out"
Write-LegacyStore
Assert "legacy store staged" (Test-Path $AccountStore)
$env:GHOSTTY_ACCOUNT_STORE = $AccountStore
$code = Run-Cli '+relay-logout' 'logout2.out'
Assert "legacy logout exit 0" ($code -eq 0)
Assert "legacy store deleted" (-not (Test-Path $AccountStore))
Remove-Item env:GHOSTTY_ACCOUNT_STORE -ErrorAction SilentlyContinue

# GUI half: launch the GUI with the account store env (auto-launch inherits
# it), a legacy store staged, and NO GHOSTTY_RELAY_TOKEN -> the account tier
# must refuse ("not signed in"), not present a dead Google token.
Write-LegacyStore
$env:GHOSTTY_ACCOUNT_STORE = $AccountStore
$code = Run-Cli '+new-window --target=acctbase' 'acctbase.out'
Assert "base window exit 0" ($code -eq 0)
Start-Sleep -Seconds 2
$code = Run-Cli "+new-remote-window --relay=$FakeABase --device=zzz" 'legacyopen.out' 30
Assert "legacy account tier refuses" ($code -ne 0 -and (Get-Out 'legacyopen.out') -match 'not signed in')

"== 6: near-expiry session -> renewed at the stored relay, rotation persisted"
if (-not $fakeBUp) {
    "  SKIP renew case (fake relay B did not start)"
} else {
    $code = Invoke-Login 'login4.out' $FakeBBase
    Assert "short-expiry login exit 0" ($code -eq 0)
    # The dial itself fails (fake relay has no ws endpoint) - what matters is
    # that the GUI RENEWED first (Bearer = the old token) instead of refusing.
    $code = Run-Cli "+new-remote-window --relay=$FakeBBase --device=zzz" 'renewopen.out' 30
    Assert "renew hit with the old bearer" ((Get-Hits $HitsB) -match [regex]::Escape("POST /oauth/renew HTTP/1.1|auth=$SessTok"))
    Assert "dial proceeded past auth (not 'not signed in')" ((Get-Out 'renewopen.out') -match 'failed to reach zzz')
    # Rotation must be persisted: decrypt the store and find the new token.
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
} else {
    Push-Location $RelaySrc
    & go build -o "$tmp\ghoztty-relay-login-e2e.exe" . 2>&1 | Select-Object -Last 2
    $goExit = $LASTEXITCODE
    Pop-Location
    Assert "relay builds" ($goExit -eq 0)

    if ($goExit -eq 0) {
        # The relay's DEV_AUTH accepts a client bearer only if it exactly
        # equals DEV_CLIENT_TOKEN. The account tier presents the relay session
        # token minted by the fake exchange, so set DEV_CLIENT_TOKEN to that
        # same value - then the account-tier bearer is accepted end to end.
        $env:LISTEN_ADDR = "127.0.0.1:$RelayPort"; $env:METRICS_ADDR = '127.0.0.1:0'
        $env:DEV_AUTH = 'true'; $env:DEV_CLIENT_TOKEN = $SessTok
        $env:DEV_EMAIL = 'dev@example.com'; $env:STATE_DIR = "$tmp\state"
        $relay = Start-Process -FilePath "$tmp\ghoztty-relay-login-e2e.exe" -PassThru -WindowStyle Hidden
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
                -ContentType 'application/json' -Body '{"name":"login-e2e"}'
        } catch {}
        Assert "device enrolled" ($null -ne $dev -and $dev.id)

        if ($healthy -and $dev) {
            # Fresh sign-in (long expiry) so the account tier serves the
            # cached session token without a renew.
            $code = Invoke-Login 'login5.out' $FakeABase
            Assert "re-login exit 0" ($code -eq 0 -and (Test-Path $AccountStore))

            # Launch the agent.
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
Remove-Item env:GHOSTTY_ACCOUNT_STORE -ErrorAction SilentlyContinue
if ($null -ne $savedTok) { $env:GHOSTTY_RELAY_TOKEN = $savedTok }
Stop-TestProcs
foreach ($j in @($jobA, $jobB)) {
    if ($j) { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue }
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
