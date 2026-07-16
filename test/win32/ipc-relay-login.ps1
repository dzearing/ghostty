# Relay account sign-in acceptance (tracker T21a): +relay-login / +relay-logout
# and the GUI account-tier of +new-remote-window (open a relay window with NO
# --token, authenticated by the signed-in account).
#
#   powershell -NoProfile -File test\win32\ipc-relay-login.ps1
#
# Self-contained and non-interactive. A raw-TCP "fake Google" serves the OAuth
# token endpoint (injected via GHOSTTY_OAUTH_TOKEN_ENDPOINT); the account store
# is redirected to a temp path (GHOSTTY_ACCOUNT_STORE) so the box's real
# account is never touched. Covers:
#   1. +relay-login --no-browser end to end: PKCE + loopback redirect + code
#      exchange -> DPAPI account.dat written, "Signed in as <email>".
#   2. account.dat round-trips: +relay-logout removes it, "Signed out".
#   3. token-endpoint failure -> login exits nonzero, no account written.
#   4. account tier: with account.dat present, +new-remote-window WITHOUT
#      --token dials a live relay+agent using an ID token minted from the
#      stored refresh grant (needs go + ghoztty-agent).
#
# Only ever touches ghoztty processes running from the repo zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$RelaySrc = 'D:\git\ghoztty\relay',
    [int]$TokenPort = 47921,
    [int]$RelayPort = 47912
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-relay-login-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
New-Item -ItemType Directory -Force "$tmp\state" | Out-Null

$AccountStore = "$tmp\account.dat"
$TokenEndpoint = "http://127.0.0.1:$TokenPort/token"
$DevToken = 'devtok-login-e2e'
$RelayBase = "http://127.0.0.1:$RelayPort"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Get-Out($outfile) {
    if (Test-Path "$tmp\$outfile") { Get-Content "$tmp\$outfile" -Raw } else { '' }
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

function B64Url([byte[]]$b) {
    [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# A fake unsigned JWT (header.payload.sig) — only the payload is decoded by the
# client (signature is the relay's job). Carries email + a far-future exp.
$exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
$payloadJson = "{`"email`":`"e2e@example.com`",`"exp`":$exp}"
$hdrSeg = B64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"none"}'))
$plSeg = B64Url ([Text.Encoding]::UTF8.GetBytes($payloadJson))
$jwt = "$hdrSeg.$plSeg.sig"
$tokenBody = "{`"access_token`":`"at`",`"expires_in`":3600,`"id_token`":`"$jwt`",`"refresh_token`":`"rt-e2e`",`"token_type`":`"Bearer`",`"scope`":`"openid email profile`"}"

# Start the raw-TCP fake token endpoint (avoids HttpListener's URL-ACL admin
# requirement). Serves a fixed 200 token response to every POST.
function Start-FakeToken($port, $body) {
    Start-Job -ScriptBlock {
        param($port, $body)
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $payload = [Text.Encoding]::UTF8.GetBytes($body)
        $resp = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
        $respBytes = [Text.Encoding]::UTF8.GetBytes($resp) + $payload
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                Start-Sleep -Milliseconds 60
                $buf = New-Object byte[] 16384
                while ($stream.DataAvailable) { [void]$stream.Read($buf, 0, $buf.Length) }
                $stream.Write($respBytes, 0, $respBytes.Length)
                $stream.Flush()
            } catch {}
            $client.Close()
        }
    } -ArgumentList $port, $body
}

# Drive +relay-login --no-browser to completion by simulating the browser: the
# CLI prints the auth URL then blocks on its loopback listener; we parse the
# redirect_uri + state out of the URL and GET it with a code. Returns the login
# exit code; stdout lands in $tmp\$outfile.
function Invoke-Login($outfile, $tokenEndpoint, $timeoutSec = 25) {
    # Launch via cmd.exe (like Run-Cli): Start-Process -RedirectStandardOutput
    # leaves $p.ExitCode unpopulated, but a cmd redirect to a file both lets us
    # poll stdout live AND yields a real exit code.
    $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
    $env:GHOSTTY_OAUTH_TOKEN_ENDPOINT = $tokenEndpoint
    $env:GHOSTTY_OAUTH_AUTH_ENDPOINT = "http://127.0.0.1:$TokenPort/authorize"
    $argsLine = '+relay-login --no-browser --client-id=cid-e2e --client-secret=csec-e2e'
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$tmp\$outfile`" 2>&1`""
    foreach ($k in 'GHOSTTY_ACCOUNT_STORE', 'GHOSTTY_OAUTH_TOKEN_ENDPOINT', 'GHOSTTY_OAUTH_AUTH_ENDPOINT') {
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

Stop-TestProcs
Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue

"== 0: start the fake Google token endpoint"
$tokenJob = Start-FakeToken $TokenPort $tokenBody
$listening = $false
foreach ($i in 1..20) {
    try {
        $t = [System.Net.Sockets.TcpClient]::new(); $t.Connect('127.0.0.1', $TokenPort); $t.Close()
        $listening = $true; break
    } catch { Start-Sleep -Milliseconds 250 }
}
Assert "fake token endpoint listening" $listening
if (-not $listening) { Stop-TestProcs; Get-Job | Remove-Job -Force; "$($script:failures) FAILURE(S)"; exit 1 }

"== 1: +relay-login --no-browser end to end"
$code = Invoke-Login 'login1.out' $TokenEndpoint
Assert "login exit 0" ($code -eq 0)
Assert "prints signed-in email" ((Get-Out 'login1.out') -match 'Signed in as e2e@example.com')
Assert "account.dat written" (Test-Path $AccountStore)
# DPAPI blob must not be plaintext JSON (it is encrypted at rest).
$blob = if (Test-Path $AccountStore) { Get-Content $AccountStore -Raw } else { '' }
Assert "account.dat is not plaintext" (-not ($blob -match 'refresh_token'))

"== 2: +relay-logout removes the account"
$env:GHOSTTY_ACCOUNT_STORE = $AccountStore
$code = Run-Cli '+relay-logout' 'logout1.out'
Remove-Item env:GHOSTTY_ACCOUNT_STORE -ErrorAction SilentlyContinue
Assert "logout exit 0" ($code -eq 0)
Assert "logout says signed out" ((Get-Out 'logout1.out') -match 'Signed out')
Assert "account.dat gone" (-not (Test-Path $AccountStore))

"== 3: token-endpoint failure -> login fails, no account written"
# Point at a dead port: the code exchange POST is refused.
$code = Invoke-Login 'login2.out' 'http://127.0.0.1:1/token'
Assert "login exit nonzero" ($code -ne 0 -and $null -ne $code)
Assert "reports token exchange failure" ((Get-Out 'login2.out') -match 'Token exchange failed')
Assert "no account.dat after failed login" (-not (Test-Path $AccountStore))

"== 4: account tier -> +new-remote-window with NO --token"
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
        # The relay's DEV_AUTH accepts a client bearer only if it exactly equals
        # DEV_CLIENT_TOKEN. The account tier dials with the ID token minted from
        # the stored account (the fake JWT the token endpoint returns), so set
        # DEV_CLIENT_TOKEN to that same JWT — then the account-tier bearer is
        # accepted end to end.
        $env:LISTEN_ADDR = "127.0.0.1:$RelayPort"; $env:METRICS_ADDR = '127.0.0.1:0'
        $env:DEV_AUTH = 'true'; $env:DEV_CLIENT_TOKEN = $jwt
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
                -Headers @{ Authorization = "Bearer $jwt" } `
                -ContentType 'application/json' -Body '{"name":"login-e2e"}'
        } catch {}
        Assert "device enrolled" ($null -ne $dev -and $dev.id)

        if ($healthy -and $dev) {
            # Sign in (fresh account.dat) BEFORE launching the GUI.
            $code = Invoke-Login 'login3.out' $TokenEndpoint
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

            # Launch the GUI with the account store + fake token endpoint in its
            # env, and NO GHOSTTY_RELAY_TOKEN, so the ONLY token source is the
            # signed-in account (the tier under test).
            $savedTok = $env:GHOSTTY_RELAY_TOKEN
            Remove-Item env:GHOSTTY_RELAY_TOKEN -ErrorAction SilentlyContinue
            $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
            $env:GHOSTTY_OAUTH_TOKEN_ENDPOINT = $TokenEndpoint
            $code = Run-Cli '+new-window --target=acctbase' 'acctbase.out'
            Assert "base window exit 0" ($code -eq 0)
            Start-Sleep -Seconds 2

            $code = Run-Cli "+new-remote-window --relay=$RelayBase --device=$($dev.id) --name=acctwin" 'acctopen.out' 30
            Assert "account-tier open exit 0 (no --token)" ($code -eq 0)
            Start-Sleep -Seconds 2
            $code = Run-Cli '+list' 'acctlist.out'
            Assert "account-tier window registered" ((Get-Out 'acctlist.out') -match '\[target: acctwin\]')

            Run-Cli '+close --target=acctwin' 'acctclose.out' | Out-Null
            Run-Cli '+close --target=acctbase' 'acctclosebase.out' | Out-Null
            foreach ($k in 'GHOSTTY_ACCOUNT_STORE', 'GHOSTTY_OAUTH_TOKEN_ENDPOINT') {
                Remove-Item "env:$k" -ErrorAction SilentlyContinue
            }
            if ($null -ne $savedTok) { $env:GHOSTTY_RELAY_TOKEN = $savedTok }
            if ($agent) { Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue }
        }
        if ($relay) { Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue }
    }
}

"== cleanup"
Stop-TestProcs
if ($tokenJob) { Stop-Job $tokenJob -ErrorAction SilentlyContinue; Remove-Job $tokenJob -Force -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
