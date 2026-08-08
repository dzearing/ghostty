# FakeRelay.ps1 - a loopback stand-in for the rendezvous relay (T319).
#
# WHY THIS EXISTS. Every relay-dialed surface in the app (the chooser's session
# roster, its Activity button, cross-machine resume) goes through
# `relay_dial.dial`, which opens `ws://<base>/v1/client/connect?device=<id>` and
# treats the WebSocket as a TRANSPARENT BYTE PIPE to the remote agent. Until
# this file there was no way to exercise that on box: `ipc-machine-chooser.ps1`
# fakes the device DIRECTORY (plain HTTP), which is enough to get a row into the
# list and nothing more, and `activity-monitor-remote.ps1` says so out loud -
# "the DIALED entry needs a relay device". So the remote half of those surfaces
# was reachable only by unit tests and reading.
#
# WHAT IT IS. One TcpListener, one single-threaded event loop, three behaviours:
#
#   GET /v1/client/devices        -> the directory JSON (what the chooser lists)
#   GET /v1/client/connect?device -> a real RFC 6455 upgrade, then a byte bridge
#                                    to a `ghoztty-agent --listen host:port`
#   anything else                 -> 404
#
# The loop is single-threaded ON PURPOSE: the directory GET and the WebSocket
# have to share ONE port (`relay_base` is one origin for both), and a job that
# blocks in `AcceptTcpClient` while a bridge is open would deadlock the surface
# under test. `Pending()` + `DataAvailable` polling keeps every connection
# serviced without a thread each.
#
# BRIDGING RULES. Client->server frames are masked (RFC 6455 requires it of a
# client) and are unmasked before their payload is written to the agent socket.
# Server->client frames are unmasked binary, one per read chunk - the framing
# does NOT have to match what the client sent, because the client's
# `readMessage` reassembles and the layer above it reads a STREAM. `ping` is
# answered, `close` tears the pair down.
#
# FAILURE INJECTION. A test needs the sad paths more than the happy one, so a
# device id is also a verb:
#
#   -UnauthorizedDevice <ids>  the upgrade answers 401 (an expired credential)
#   -UnreachableDevice <ids>   the upgrade answers 502 (the machine is offline)
#
# Both take a comma-separated list, so a negative-control run can add the
# otherwise-good device to one of them without a second parameter.
#
# Both are the NORMAL case in a chooser listing every enrolled device, and both
# must resolve to a state of the region rather than a modal.
#
# Three more are FILE-triggered, so a run can change the machine's behaviour
# part-way through - after a fixture has been built through it, or after a
# roster has loaded: `-TripFile` (502 from then on), `-TripUnauthorizedFile`
# (401 from then on) and `-SlowConnectFile` (every connect answered
# `-SlowConnectMs` late, deferred rather than slept on).
#
# Everything is loopback-only and lives in a background job; `Stop-FakeRelay`
# kills it. The request log is the independent evidence that a dial really went
# through the relay rather than some local shortcut.

Set-StrictMode -Off

function Start-FakeRelay {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$AgentPort,
        [Parameter(Mandatory = $true)][string]$DevicesJson,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [string]$UnauthorizedDevice = '',
        [string]$UnreachableDevice = '',
        # While this file EXISTS, every `/v1/client/connect` answers 502. It is
        # how a negative control turns the relay off partway through a run,
        # after the fixture it needs has already been built through it.
        [string]$TripFile = '',
        # The same idea as `-TripFile`, answering 401 instead of 502: while this
        # file EXISTS the bearer is treated as expired. A device that is
        # PERMANENTLY unauthorized (`-UnauthorizedDevice`) can never get its
        # roster loaded, so it cannot reach a surface that is gated on having
        # one - the Restore All button, for instance. Expiring a credential
        # AFTER the roster loaded is both the reachable path and the honest one:
        # tokens go stale between one click and the next.
        [string]$TripUnauthorizedFile = '',
        # While this file EXISTS, every `/v1/client/connect` is answered
        # `-SlowConnectMs` LATER (T339). It is how a run makes the link slow on
        # purpose - a restore that dials N+1 times is only visibly wrong when a
        # dial takes long enough to notice - without the relay itself stalling:
        # the answer is deferred to a later pass of the loop, never slept on, so
        # every live bridge keeps pumping in the meantime.
        [string]$SlowConnectFile = '',
        [int]$SlowConnectMs = 1500
    )

    Remove-Item $LogPath -ErrorAction SilentlyContinue

    $job = Start-Job -ScriptBlock {
        param($port, $agentPort, $devicesJson, $logPath, $unauthDev, $deadDev, $tripFile, $tripAuthFile,
            $slowFile, $slowMs)

        function Write-RelayLog([string]$m) {
            Add-Content -Path $logPath -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m)
        }

        # Read exactly $n bytes, or $null if the peer went away. Only ever
        # called once a frame has started arriving, so the block is bounded by
        # the peer finishing a frame it already committed to.
        function Read-Exact($stream, [int]$n) {
            if ($n -le 0) { return New-Object byte[] 0 }
            $buf = New-Object byte[] $n
            $off = 0
            while ($off -lt $n) {
                try { $r = $stream.Read($buf, $off, $n - $off) } catch { return $null }
                if ($r -le 0) { return $null }
                $off += $r
            }
            return $buf
        }

        # One unmasked frame (server->client; a server MUST NOT mask).
        function Send-Frame($stream, [int]$opcode, [byte[]]$payload) {
            $len = $payload.Length
            $hdr = New-Object System.Collections.Generic.List[byte]
            $hdr.Add([byte](0x80 -bor $opcode))
            if ($len -lt 126) {
                $hdr.Add([byte]$len)
            } elseif ($len -le 65535) {
                $hdr.Add([byte]126)
                $hdr.Add([byte](($len -shr 8) -band 0xFF))
                $hdr.Add([byte]($len -band 0xFF))
            } else {
                # [int64], NOT the [int] $len: .NET masks a shift count to the
                # operand's width, so `[int] -shr 56` is silently `-shr 24` and
                # the 8-byte length goes out corrupt. (The chunk size below
                # keeps this path unreachable; it is correct anyway because a
                # frame header that is wrong by a factor of 2^32 desynchronises
                # the peer's parser and reads, from the app, as a connection
                # that closed for no reason.)
                $len64 = [int64]$len
                for ($i = 7; $i -ge 0; $i--) { $hdr.Add([byte](($len64 -shr ($i * 8)) -band 0xFF)) }
            }
            $bytes = $hdr.ToArray()
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                if ($len -gt 0) { $stream.Write($payload, 0, $len) }
                $stream.Flush()
                return $true
            } catch { return $false }
        }

        # Answer one deferred `/v1/client/connect`: reject it, or complete the
        # WebSocket upgrade and register the bridge. Split out of the accept
        # branch so the answer can be held back by `-SlowConnectFile` without
        # the loop sleeping (T339); with no slow file it runs on the same pass
        # the request arrived on, which is what it always did.
        #
        # The decision is made HERE, not when the request landed, so a trip file
        # dropped mid-flight still applies to a connect already in the queue.
        function Complete-Connect($p) {
            $device = $p.Device
            $key = $p.Key
            $ns = $p.Ws
            $client = $p.Client

            $unauthList = @()
            if ($unauthDev) { $unauthList = @($unauthDev -split ',' | ForEach-Object { $_.Trim() }) }
            $deadList = @()
            if ($deadDev) { $deadList = @($deadDev -split ',' | ForEach-Object { $_.Trim() }) }

            $tripped = $false
            if ($tripFile -and (Test-Path $tripFile)) { $tripped = $true }
            $trippedAuth = $false
            if ($tripAuthFile -and (Test-Path $tripAuthFile)) { $trippedAuth = $true }

            if ($trippedAuth) {
                Write-RelayLog "REJECT 401 (tripped) device=$device"
                Write-Http $ns '401 Unauthorized' 'text/plain' 'expired'
                $client.Close()
            } elseif ($tripped) {
                Write-RelayLog "REJECT 502 (tripped) device=$device"
                Write-Http $ns '502 Bad Gateway' 'text/plain' 'tripped'
                $client.Close()
            } elseif ($unauthList -contains $device) {
                Write-RelayLog "REJECT 401 device=$device"
                Write-Http $ns '401 Unauthorized' 'text/plain' 'expired'
                $client.Close()
            } elseif ($deadList -contains $device) {
                Write-RelayLog "REJECT 502 device=$device"
                Write-Http $ns '502 Bad Gateway' 'text/plain' 'offline'
                $client.Close()
            } elseif (-not $key) {
                Write-Http $ns '400 Bad Request' 'text/plain' 'no key'
                $client.Close()
            } else {
                $sha = [System.Security.Cryptography.SHA1]::Create()
                $accept = [Convert]::ToBase64String($sha.ComputeHash(
                        [Text.Encoding]::ASCII.GetBytes($key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')))
                $agentSock = $null
                try {
                    $agentSock = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $agentPort)
                    $agentSock.NoDelay = $true
                } catch {
                    Write-RelayLog "REJECT 502 (agent dial failed) device=$device"
                    Write-Http $ns '502 Bad Gateway' 'text/plain' 'agent unreachable'
                    $client.Close()
                    $agentSock = $null
                }
                if ($null -ne $agentSock) {
                    # A read that can block forever stalls the WHOLE relay - it
                    # is one loop - and a stalled relay looks to the app like a
                    # connection that stopped answering, which its heartbeat
                    # then shuts down as `error.ConnectionClosed`. Every socket
                    # here gets a deadline so a bridge can only ever kill
                    # itself.
                    $ns.ReadTimeout = 5000
                    $ns.WriteTimeout = 5000
                    $agentSock.GetStream().ReadTimeout = 5000
                    $agentSock.GetStream().WriteTimeout = 5000
                    $resp = "HTTP/1.1 101 Switching Protocols`r`nUpgrade: websocket`r`n" +
                    "Connection: Upgrade`r`nSec-WebSocket-Accept: $accept`r`n`r`n"
                    $rb = [Text.Encoding]::ASCII.GetBytes($resp)
                    $ns.Write($rb, 0, $rb.Length)
                    $ns.Flush()
                    [void]$bridges.Add([pscustomobject]@{
                            Client = $client
                            Ws     = $ns
                            Agent  = $agentSock
                            AgentS = $agentSock.GetStream()
                            Device = $device
                        })
                    Write-RelayLog "BRIDGE up device=$device"
                }
            }
        }

        function Write-Http($stream, [string]$status, [string]$contentType, [string]$body) {
            $payload = [Text.Encoding]::UTF8.GetBytes($body)
            $head = "HTTP/1.1 $status`r`n"
            if ($contentType) { $head += "Content-Type: $contentType`r`n" }
            $head += "Content-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($head) + $payload
            try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } catch {}
        }

        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        Write-RelayLog "LISTEN 127.0.0.1:$port -> agent 127.0.0.1:$agentPort"

        $bridges = New-Object System.Collections.ArrayList
        # Accepted `/connect` requests waiting for their answer's deadline.
        $deferred = New-Object System.Collections.ArrayList
        # 32 KiB, so an agent->client frame always fits the 16-bit length form.
        # Framing is free to differ from what the client sent: the layer above
        # the WebSocket reads a STREAM, and `readMessage` reassembles.
        $chunk = New-Object byte[] 32768

        while ($true) {
            $idle = $true
            try {

            if ($listener.Pending()) {
                $idle = $false
                $client = $listener.AcceptTcpClient()
                $client.NoDelay = $true
                $ns = $client.GetStream()

                # Request head, byte at a time (it is tiny, and this cannot
                # over-read into the first WebSocket frame).
                $head = ''
                $one = New-Object byte[] 1
                $deadline = (Get-Date).AddSeconds(5)
                while (-not $head.EndsWith("`r`n`r`n") -and (Get-Date) -lt $deadline) {
                    if ($ns.DataAvailable) {
                        try { $r = $ns.Read($one, 0, 1) } catch { break }
                        if ($r -le 0) { break }
                        $head += [char]$one[0]
                    } else {
                        Start-Sleep -Milliseconds 5
                    }
                }
                $lines = $head -split "`r`n"
                $reqLine = $lines[0]
                Write-RelayLog "REQ $reqLine"

                if ($reqLine -match '/v1/client/devices') {
                    Write-Http $ns '200 OK' 'application/json' $devicesJson
                    $client.Close()
                } elseif ($reqLine -match '/v1/client/connect') {
                    $device = ''
                    if ($reqLine -match 'device=([^ &]+)') { $device = $Matches[1] }
                    $key = ''
                    $auth = ''
                    foreach ($line in $lines) {
                        if ($line -match '^(?i)sec-websocket-key:\s*(.+)$') { $key = $Matches[1].Trim() }
                        if ($line -match '^(?i)authorization:\s*(.+)$') { $auth = $Matches[1].Trim() }
                    }
                    Write-RelayLog "CONNECT device=$device auth=$auth"

                    # A SLOW link, without stalling the relay (T339). The answer
                    # is deferred, not slept on: this is one loop, so a sleep
                    # here would freeze every live bridge too and the app would
                    # see connections that stopped answering rather than a dial
                    # that takes a while. With no slow file the deadline is now,
                    # so the sweep below completes it on this same pass.
                    $delayMs = 0
                    if ($slowFile -and (Test-Path $slowFile)) { $delayMs = $slowMs }
                    [void]$deferred.Add([pscustomobject]@{
                            Client  = $client
                            Ws      = $ns
                            Device  = $device
                            Key     = $key
                            ReadyAt = (Get-Date).AddMilliseconds($delayMs)
                        })
                    if ($delayMs -gt 0) {
                        Write-RelayLog "DEFER ${delayMs}ms device=$device"
                    }
                } else {
                    Write-Http $ns '404 Not Found' 'text/plain' 'no'
                    $client.Close()
                }
            }

            # Deferred connects whose deadline has passed. Answered from the
            # loop rather than from a sleep, so live bridges keep pumping while
            # a "slow" dial is outstanding.
            foreach ($p in @($deferred)) {
                if ((Get-Date) -lt $p.ReadyAt) { continue }
                $idle = $false
                $deferred.Remove($p)
                Complete-Connect $p
            }

            foreach ($b in @($bridges)) {
                $dead = $false

                # client -> agent: one whole frame per pass.
                try { $avail = $b.Ws.DataAvailable } catch { $avail = $false; $dead = $true }
                if (-not $dead -and $avail) {
                    $idle = $false
                    $h = Read-Exact $b.Ws 2
                    if ($null -eq $h) {
                        $dead = $true
                    } else {
                        $op = $h[0] -band 0x0F
                        $masked = ($h[1] -band 0x80) -ne 0
                        $len = $h[1] -band 0x7F
                        if ($len -eq 126) {
                            $e = Read-Exact $b.Ws 2
                            if ($null -eq $e) { $dead = $true } else { $len = ($e[0] * 256) + $e[1] }
                        } elseif ($len -eq 127) {
                            $e = Read-Exact $b.Ws 8
                            if ($null -eq $e) { $dead = $true } else {
                                $len = 0
                                foreach ($x in $e) { $len = ($len * 256) + $x }
                            }
                        }
                        $mask = $null
                        if (-not $dead -and $masked) {
                            $mask = Read-Exact $b.Ws 4
                            if ($null -eq $mask) { $dead = $true }
                        }
                        $payload = $null
                        if (-not $dead) {
                            $payload = Read-Exact $b.Ws $len
                            if ($null -eq $payload) { $dead = $true }
                        }
                        if (-not $dead) {
                            if ($masked -and $len -gt 0) {
                                for ($i = 0; $i -lt $len; $i++) {
                                    $payload[$i] = [byte](($payload[$i] -bxor $mask[$i % 4]) -band 0xFF)
                                }
                            }
                            if ($op -eq 8) {
                                Write-RelayLog "CLOSE from client device=$($b.Device)"
                                $dead = $true
                            } elseif ($op -eq 9) {
                                [void](Send-Frame $b.Ws 10 $payload)
                            } elseif ($len -gt 0) {
                                try {
                                    $b.AgentS.Write($payload, 0, $len)
                                    $b.AgentS.Flush()
                                } catch { $dead = $true }
                            }
                        }
                    }
                }

                # agent -> client: whatever is buffered, as one binary frame.
                if (-not $dead) {
                    try { $aavail = $b.AgentS.DataAvailable } catch { $aavail = $false; $dead = $true }
                    if (-not $dead -and $aavail) {
                        $idle = $false
                        try { $n = $b.AgentS.Read($chunk, 0, $chunk.Length) } catch { $n = -1 }
                        if ($n -le 0) {
                            $dead = $true
                        } else {
                            $slice = New-Object byte[] $n
                            [Array]::Copy($chunk, 0, $slice, 0, $n)
                            if (-not (Send-Frame $b.Ws 2 $slice)) { $dead = $true }
                        }
                    }
                }

                # NOTE: there is deliberately NO liveness probe here. Both of
                # the obvious ones are wrong: `TcpClient.Connected` reports the
                # state as of the last I/O (so a closed peer still reads as
                # connected), and `Poll(SelectRead) && Available == 0` races
                # this loop's own reads - it tore down healthy bridges ~30 ms
                # after the upgrade, which surfaced in the app as
                # `error.ConnectionClosed` on a Kill that was otherwise fine.
                # A bridge dies when a read or a write says so, or when the
                # client sends a close frame. A short-lived relay leaking a few
                # idle pairs costs nothing.

                if ($dead) {
                    Write-RelayLog "BRIDGE down device=$($b.Device)"
                    try { $b.Client.Close() } catch {}
                    try { $b.Agent.Close() } catch {}
                    $bridges.Remove($b)
                }
            }

            } catch {
                # A relay that dies silently is indistinguishable from a
                # product bug (it cost a debugging cycle here), so every
                # unexpected error is logged and the loop keeps running.
                Write-RelayLog "ERROR $($_.Exception.Message)"
            }

            if ($idle) { Start-Sleep -Milliseconds 5 }
        }
    } -ArgumentList $Port, $AgentPort, $DevicesJson, $LogPath, $UnauthorizedDevice, $UnreachableDevice, $TripFile, $TripUnauthorizedFile, $SlowConnectFile, $SlowConnectMs

    # Wait for the listener to actually bind before handing the job back: a
    # relay that is not listening yet reads exactly like a relay that is broken.
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $LogPath) -and (Select-String -Path $LogPath -Pattern 'LISTEN' -Quiet)) { break }
        Start-Sleep -Milliseconds 100
    }
    return $job
}

function Stop-FakeRelay {
    param($Job)
    if ($null -eq $Job) { return }
    Stop-Job $Job -ErrorAction SilentlyContinue
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
}

function Get-FakeRelayLog {
    param([string]$LogPath)
    if (-not (Test-Path $LogPath)) { return @() }
    return @(Get-Content $LogPath)
}
