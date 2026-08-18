# FakeAgentRelay.ps1 - a loopback stand-in for the AGENT side of the relay (T887).
#
# WHY A SECOND FAKE RELAY. `FakeRelay.ps1` is the CLIENT side: it answers
# `/v1/client/devices` and `/v1/client/connect`, and bridges the app's dial to a
# `ghoztty-agent --listen host:port`. That shape cannot exercise the sharing
# uplink at all, because in the uplink the AGENT is the one that dials OUT: it
# holds `GET /v1/agent/control` open forever and waits to be told to open
# sessions. Until this file, nothing had ever sent it that instruction - the
# T546 harness's listener answers 404, which the agent treats as a dial failure
# - so "a session opened over the relay lands in the same store the local pipe
# serves" was true by code shape and by nothing else.
#
# WHAT IT IS. One background job, one single-threaded event loop, TWO listeners:
#
#   relay origin (the agent dials this; RELAY_BASE points at it)
#     GET /v1/agent/control          -> RFC 6455 upgrade, then held open. This
#                                       is the channel the "open a session"
#                                       command travels down.
#     GET /v1/agent/data?session=ID  -> RFC 6455 upgrade, then paired with the
#                                       waiting entry client as a byte bridge.
#     anything else                  -> 404
#
#   entry port (the test's client dials this)
#     a raw TCP connect means "somebody on the other side of the relay wants a
#     terminal on this machine": the loop mints a rendezvous id, sends
#     {"type":"open","session":"<id>"} down the live control WebSocket, and waits
#     for the agent's answering data dial to pair with.
#
# The entry port is deliberately RAW TCP rather than a WebSocket: what connects
# to it is `remote-test-client.exe <host> <port>`, which speaks the agent frame
# protocol over a plain socket. The relay is a transparent byte pipe either way,
# so wrapping the test client's end in a second WebSocket would only test this
# file's framing twice.
#
# FRAMING RULES (identical to FakeRelay.ps1's, with the roles swapped). The
# agent is a WebSocket CLIENT, so ITS frames are masked and are unmasked before
# their payload is written to the raw socket. Ours are unmasked, one binary
# frame per read chunk - the framing does not have to match what the agent sent,
# because `ws_client.readMessage` reassembles and the layer above reads a
# STREAM. `ping` is answered with a `pong` (the agent's keepalive closes a
# control link with no inbound frames), `close` tears the pair down.
#
# The loop is single-threaded ON PURPOSE, the same reason FakeRelay.ps1 is: both
# listeners and every live bridge share one job, and a job that blocks in
# `AcceptTcpClient` while a bridge is open would deadlock the surface under
# test. `Pending()` + `DataAvailable` polling keeps everything serviced.
#
# The log is the independent evidence that a session really came in over the
# relay rather than through some local shortcut: CONTROL up / OPEN sent / DATA
# up, in that order, with the session id.

Set-StrictMode -Off

function Start-FakeAgentRelay {
    param(
        # Written once both listeners are bound: "relay=<port> entry=<port>".
        [Parameter(Mandatory = $true)][string]$PortFile,
        [Parameter(Mandatory = $true)][string]$LogPath,
        # Seconds an entry client waits for the agent's answering data dial
        # before it is dropped (a parked uplink never answers).
        [int]$PendingTimeoutSec = 20
    )

    Remove-Item $LogPath -ErrorAction SilentlyContinue
    Remove-Item $PortFile -ErrorAction SilentlyContinue

    $job = Start-Job -ScriptBlock {
        param($portFile, $logPath, $pendingTimeoutSec)

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
                # operand's width, so `[int] -shr 56` is silently `-shr 24`.
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

        # One whole inbound frame, unmasked. @{ Op; Payload } or $null when the
        # peer went away mid-frame.
        function Read-Frame($stream) {
            $h = Read-Exact $stream 2
            if ($null -eq $h) { return $null }
            $op = $h[0] -band 0x0F
            $masked = ($h[1] -band 0x80) -ne 0
            $len = $h[1] -band 0x7F
            if ($len -eq 126) {
                $e = Read-Exact $stream 2
                if ($null -eq $e) { return $null }
                $len = ($e[0] * 256) + $e[1]
            } elseif ($len -eq 127) {
                $e = Read-Exact $stream 8
                if ($null -eq $e) { return $null }
                $len = 0
                foreach ($x in $e) { $len = ($len * 256) + $x }
            }
            $mask = $null
            if ($masked) {
                $mask = Read-Exact $stream 4
                if ($null -eq $mask) { return $null }
            }
            $payload = Read-Exact $stream $len
            if ($null -eq $payload) { return $null }
            if ($masked -and $len -gt 0) {
                for ($i = 0; $i -lt $len; $i++) {
                    $payload[$i] = [byte](($payload[$i] -bxor $mask[$i % 4]) -band 0xFF)
                }
            }
            return @{ Op = $op; Payload = $payload }
        }

        # Request head, byte at a time (it is tiny, and this cannot over-read
        # into the first WebSocket frame).
        function Read-Head($ns) {
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
            return $head
        }

        function Send-Upgrade($ns, [string]$key) {
            $sha = [System.Security.Cryptography.SHA1]::Create()
            $accept = [Convert]::ToBase64String($sha.ComputeHash(
                    [Text.Encoding]::ASCII.GetBytes($key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')))
            $resp = "HTTP/1.1 101 Switching Protocols`r`nUpgrade: websocket`r`n" +
            "Connection: Upgrade`r`nSec-WebSocket-Accept: $accept`r`n`r`n"
            $rb = [Text.Encoding]::ASCII.GetBytes($resp)
            try { $ns.Write($rb, 0, $rb.Length); $ns.Flush(); return $true } catch { return $false }
        }

        function Write-Http($stream, [string]$status, [string]$body) {
            $payload = [Text.Encoding]::UTF8.GetBytes($body)
            $head = "HTTP/1.1 $status`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($head) + $payload
            try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } catch {}
        }

        $relayL = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $relayL.Start()
        $entryL = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $entryL.Start()
        $relayPort = $relayL.LocalEndpoint.Port
        $entryPort = $entryL.LocalEndpoint.Port
        Set-Content -Path $portFile -Value "relay=$relayPort entry=$entryPort" -Encoding ascii
        Write-RelayLog "LISTEN relay=$relayPort entry=$entryPort"

        # The live control WebSocket (the agent's uplink), if one is up.
        $control = $null
        $controlClient = $null
        # Entry clients whose `open` has been sent, waiting for the agent's data
        # dial to pair with.
        $pending = New-Object System.Collections.ArrayList
        # Paired (raw client <-> agent data WebSocket) byte pipes.
        $bridges = New-Object System.Collections.ArrayList
        $seq = 0
        # 32 KiB, so a raw->agent frame always fits the 16-bit length form.
        $chunk = New-Object byte[] 32768

        while ($true) {
            $idle = $true
            try {

                if ($relayL.Pending()) {
                    $idle = $false
                    $c = $relayL.AcceptTcpClient()
                    $c.NoDelay = $true
                    $ns = $c.GetStream()
                    $head = Read-Head $ns
                    $lines = $head -split "`r`n"
                    $req = $lines[0]
                    Write-RelayLog "REQ $req"
                    $key = ''
                    $auth = ''
                    foreach ($line in $lines) {
                        if ($line -match '^(?i)sec-websocket-key:\s*(.+)$') { $key = $Matches[1].Trim() }
                        if ($line -match '^(?i)authorization:\s*(.+)$') { $auth = $Matches[1].Trim() }
                    }

                    if ($req -match '/v1/agent/control') {
                        if (-not $key) {
                            Write-RelayLog 'CONTROL rejected (no key)'
                            Write-Http $ns '400 Bad Request' 'no key'
                            $c.Close()
                        } elseif ($null -ne $control) {
                            # A second control dial while one is live: the real
                            # relay dup-kicks the older one. Keep the newer.
                            Write-RelayLog 'CONTROL replaced (dup dial)'
                            try { $controlClient.Close() } catch {}
                            if (Send-Upgrade $ns $key) {
                                $control = $ns
                                $controlClient = $c
                                Write-RelayLog "CONTROL up auth=$auth"
                            } else { $c.Close() }
                        } else {
                            if (Send-Upgrade $ns $key) {
                                $control = $ns
                                $controlClient = $c
                                Write-RelayLog "CONTROL up auth=$auth"
                            } else { $c.Close() }
                        }
                    } elseif ($req -match '/v1/agent/data') {
                        $sid = ''
                        if ($req -match 'session=([^ &]+)') { $sid = $Matches[1] }
                        $match = @($pending | Where-Object { $_.SessionId -eq $sid })
                        if (-not $key -or $match.Count -eq 0) {
                            Write-RelayLog "DATA orphan session=$sid auth=$auth"
                            Write-Http $ns '404 Not Found' 'no such session'
                            $c.Close()
                        } elseif (Send-Upgrade $ns $key) {
                            $p = $match[0]
                            $pending.Remove($p)
                            [void]$bridges.Add([pscustomobject]@{
                                    Raw       = $p.Raw
                                    RawS      = $p.RawS
                                    Ws        = $ns
                                    WsClient  = $c
                                    SessionId = $sid
                                })
                            Write-RelayLog "DATA up session=$sid auth=$auth"
                        } else {
                            $c.Close()
                        }
                    } else {
                        Write-Http $ns '404 Not Found' 'no'
                        $c.Close()
                    }
                }

                if ($entryL.Pending()) {
                    $idle = $false
                    $rc = $entryL.AcceptTcpClient()
                    $rc.NoDelay = $true
                    if ($null -eq $control) {
                        # Nobody is holding the uplink: there is no way to ask
                        # this machine for a terminal. That is the negative
                        # control's expected outcome, not an error.
                        Write-RelayLog 'ENTRY refused (no control link)'
                        try { $rc.Close() } catch {}
                    } else {
                        $seq++
                        $sid = "e2e-$seq"
                        $msg = '{"type":"open","session":"' + $sid + '"}'
                        if (Send-Frame $control 1 ([Text.Encoding]::ASCII.GetBytes($msg))) {
                            Write-RelayLog "OPEN sent session=$sid"
                            [void]$pending.Add([pscustomobject]@{
                                    Raw       = $rc
                                    RawS      = $rc.GetStream()
                                    SessionId = $sid
                                    At        = (Get-Date)
                                })
                        } else {
                            Write-RelayLog "OPEN send failed session=$sid"
                            try { $controlClient.Close() } catch {}
                            $control = $null
                            try { $rc.Close() } catch {}
                        }
                    }
                }

                # The control channel carries nothing FROM the agent except
                # keepalive traffic - but it must be serviced, because the
                # agent's keepalive closes a link with no inbound frames.
                #
                # EOF is detected with Poll+Available rather than
                # `DataAvailable`, which is `Available > 0` and therefore reads
                # exactly the same as a healthy idle link when the peer has gone:
                # parking the uplink (`WsClient.close` = shutdown(both) + close)
                # sends no close frame, so a DataAvailable-only loop believes it
                # still holds a control link forever. Poll+Available is the
                # racy check FakeRelay.ps1 warns about ONLY where another reader
                # can drain the socket between the two calls; this loop is the
                # sole reader of the control socket, so the pair is atomic
                # enough here and nothing else can make Available lie.
                if ($null -ne $control) {
                    $eof = $false
                    $ready = $false
                    try {
                        $sock = $controlClient.Client
                        if ($sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) {
                            if ($sock.Available -eq 0) { $eof = $true } else { $ready = $true }
                        }
                    } catch { $eof = $true }
                    if ($eof) {
                        Write-RelayLog 'CONTROL down'
                        try { $controlClient.Close() } catch {}
                        $control = $null
                    } elseif ($ready) {
                        $idle = $false
                        $f = Read-Frame $control
                        if ($null -eq $f -or $f.Op -eq 8) {
                            Write-RelayLog 'CONTROL down'
                            try { $controlClient.Close() } catch {}
                            $control = $null
                        } elseif ($f.Op -eq 9) {
                            [void](Send-Frame $control 10 $f.Payload)
                        }
                    }
                }

                # An entry client the agent never answered for (a parked uplink
                # drops the `open` on the floor). Dropping it makes the negative
                # control observable instead of hanging.
                foreach ($p in @($pending)) {
                    if (((Get-Date) - $p.At).TotalSeconds -gt $pendingTimeoutSec) {
                        Write-RelayLog "PENDING expired session=$($p.SessionId)"
                        $pending.Remove($p)
                        try { $p.Raw.Close() } catch {}
                    }
                }

                foreach ($b in @($bridges)) {
                    $dead = $false

                    # agent -> client: one whole frame per pass, unmasked.
                    try { $wav = $b.Ws.DataAvailable } catch { $wav = $false; $dead = $true }
                    if (-not $dead -and $wav) {
                        $idle = $false
                        $f = Read-Frame $b.Ws
                        if ($null -eq $f) {
                            $dead = $true
                        } elseif ($f.Op -eq 8) {
                            Write-RelayLog "CLOSE from agent session=$($b.SessionId)"
                            $dead = $true
                        } elseif ($f.Op -eq 9) {
                            [void](Send-Frame $b.Ws 10 $f.Payload)
                        } elseif ($f.Payload.Length -gt 0) {
                            try {
                                $b.RawS.Write($f.Payload, 0, $f.Payload.Length)
                                $b.RawS.Flush()
                            } catch { $dead = $true }
                        }
                    }

                    # client -> agent: whatever is buffered, as one binary frame.
                    if (-not $dead) {
                        try { $rav = $b.RawS.DataAvailable } catch { $rav = $false; $dead = $true }
                        if (-not $dead -and $rav) {
                            $idle = $false
                            try { $n = $b.RawS.Read($chunk, 0, $chunk.Length) } catch { $n = -1 }
                            if ($n -le 0) {
                                $dead = $true
                            } else {
                                $slice = New-Object byte[] $n
                                [Array]::Copy($chunk, 0, $slice, 0, $n)
                                if (-not (Send-Frame $b.Ws 2 $slice)) { $dead = $true }
                            }
                        }
                    }

                    # NOTE: no liveness probe, for the reasons FakeRelay.ps1
                    # records at length - both obvious ones (TcpClient.Connected,
                    # Poll+Available) tear down healthy bridges. A bridge dies
                    # when a read or a write says so, or on a close frame.

                    if ($dead) {
                        Write-RelayLog "BRIDGE down session=$($b.SessionId)"
                        try { $b.Raw.Close() } catch {}
                        try { $b.WsClient.Close() } catch {}
                        $bridges.Remove($b)
                    }
                }

            } catch {
                # A relay that dies silently is indistinguishable from a product
                # bug, so every unexpected error is logged and the loop lives on.
                Write-RelayLog "ERROR $($_.Exception.Message)"
            }

            if ($idle) { Start-Sleep -Milliseconds 5 }
        }
    } -ArgumentList $PortFile, $LogPath, $PendingTimeoutSec

    # Wait for both listeners to actually bind before handing the job back: a
    # relay that is not listening yet reads exactly like a relay that is broken.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $LogPath) -and (Select-String -Path $LogPath -Pattern 'LISTEN' -Quiet)) { break }
        Start-Sleep -Milliseconds 100
    }
    return $job
}

# @{ Relay = <port>; Entry = <port> } once the job has bound, else $null.
function Get-FakeAgentRelayPorts {
    param([Parameter(Mandatory = $true)][string]$PortFile)
    if (-not (Test-Path $PortFile)) { return $null }
    $line = (Get-Content $PortFile | Select-Object -First 1)
    if ($line -notmatch 'relay=(\d+)\s+entry=(\d+)') { return $null }
    return @{ Relay = [int]$Matches[1]; Entry = [int]$Matches[2] }
}

function Stop-FakeAgentRelay {
    param($Job)
    if ($null -eq $Job) { return }
    Stop-Job $Job -ErrorAction SilentlyContinue
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
}

function Get-FakeAgentRelayLog {
    param([Parameter(Mandatory = $true)][string]$LogPath)
    if (-not (Test-Path $LogPath)) { return @() }
    return @(Get-Content $LogPath)
}
