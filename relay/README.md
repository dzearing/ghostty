# ghoztty-relay

A secure rendezvous **relay** for the Ghoztty remote-machines feature. It lets a
local Ghoztty client open shells on a remote `ghoztty-agent` where **both ends
dial OUTBOUND** over `wss://:443`, so it works through NAT and corporate
firewalls without Tailscale.

The relay does three things and nothing more:

1. **Sign-in.** Clients (humans) authenticate with a Google OIDC ID token;
   agents (machines) authenticate with an enrolled device token.
2. **Directory.** Tracks which agents are online, per owner.
3. **Stream bridge.** Splices the two outbound WebSocket streams into one
   bidirectional, **opaque** byte pipe.

The relay is an ngrok-style reverse tunnel: the agent holds a long-lived
**control** WebSocket; when a client wants in, the relay sends an `open` command
over that control channel, the agent dials back a **data** WebSocket, and the
relay bridges the client's stream to the agent's data stream.

**It never inspects the payload.** SSH is tunneled end-to-end inside the stream;
the relay only ever sees ciphertext. TLS is terminated by **Caddy in front**, so
this Go service listens on plain HTTP (`127.0.0.1:8080` by default) and speaks
WebSocket.

See `../docs/design/remote-transport-relay.md` for the full design (§3
architecture, §5 security).

## Endpoints

| Method | Path                              | Auth         | Purpose |
|--------|-----------------------------------|--------------|---------|
| GET    | `/v1/agent/control`               | device token | Agent registers online; relay sends `{"type":"open","session":...}` commands; ping/pong heartbeat. |
| GET    | `/v1/agent/data?session=<uuid>`   | device token | Agent dials back in response to `open`; matched to the session and bridged. |
| GET    | `/v1/client/devices`              | OIDC         | List the caller's devices with online status. |
| POST   | `/v1/client/devices`              | OIDC         | Enroll a device (`{"name":"..."}`); returns the raw device token **once**. |
| GET    | `/v1/client/connect?device=<id>`  | OIDC         | Open a session to an owned, online device and bridge it. |
| GET    | `/healthz`                        | none         | Liveness probe. |

## Configuration (environment variables)

| Variable           | Default            | Purpose |
|--------------------|--------------------|---------|
| `LISTEN_ADDR`      | `127.0.0.1:8080`   | Plain-HTTP listen address (TLS handled by Caddy). |
| `GOOGLE_CLIENT_ID` | *(unset)*          | OAuth/OIDC client ID; Google ID tokens must carry this as `aud`. Required for real client auth. |
| `ALLOWED_EMAILS`   | *(empty)*          | Comma-separated authorization allowlist of verified Google emails. A valid login by anyone not listed is rejected. |
| `STATE_DIR`        | `./state`          | Directory holding `devices.json` (persisted device hashes). |
| `DEV_AUTH`         | `false`            | **Testing only.** Accept a static bearer as a stand-in for OIDC. Logs a loud warning at startup. |
| `DEV_CLIENT_TOKEN` | *(unset)*          | The static bearer accepted when `DEV_AUTH=true`. |
| `DEV_EMAIL`        | *(unset)*          | Identity that a successful dev-auth maps to (becomes the device owner). |

### Security model (summary)

- **Clients:** the Google ID token is fully verified — signature against
  Google's JWKS (issuer `https://accounts.google.com`), `aud == GOOGLE_CLIENT_ID`,
  `exp`, and `email_verified == true`. The email must then be on `ALLOWED_EMAILS`.
  Presence of a token is never sufficient.
- **Agents:** the presented device token is SHA-256'd and compared
  constant-time against the stored hash. **Raw tokens are never stored or
  logged** — only their SHA-256 hash is persisted to `devices.json`.
- **Authorization:** a client may only list/connect devices whose `owner_email`
  matches its verified email. Unknown / unowned device IDs return `404` (not
  enumerable).
- **Fail-closed:** any auth failure → HTTP 401 (or WS close 1008) and **no
  bridge**.
- **Abuse bounds:** pending sessions are capped, session setup times out (~15s),
  and control connections have a ping/pong heartbeat with timeout.

## Build

```bash
go build ./...                 # local build
go test ./...                  # run the integration test (no Google/Caddy needed)
go vet ./...

# Cross-compile for the Linux VM:
GOOS=linux GOARCH=amd64 go build -o ghoztty-relay .
```

## Running behind Caddy

The relay listens on plain HTTP on loopback; Caddy terminates TLS (Let's Encrypt)
and reverse-proxies WebSocket upgrades through. A minimal `Caddyfile`:

```caddyfile
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

(Caddy proxies WebSocket upgrades automatically; no extra directives needed.)

Run the service (e.g. under systemd) with production config:

```bash
GOOGLE_CLIENT_ID="<your-oauth-client-id>.apps.googleusercontent.com" \
ALLOWED_EMAILS="dzearing@gmail.com" \
STATE_DIR=/var/lib/ghoztty-relay \
LISTEN_ADDR=127.0.0.1:8080 \
./ghoztty-relay
```

A sample systemd unit:

```ini
[Unit]
Description=ghoztty-relay
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ghoztty-relay
Environment=GOOGLE_CLIENT_ID=<client-id>.apps.googleusercontent.com
Environment=ALLOWED_EMAILS=dzearing@gmail.com
Environment=STATE_DIR=/var/lib/ghoztty-relay
Environment=LISTEN_ADDR=127.0.0.1:8080
Restart=on-failure
DynamicUser=yes
StateDirectory=ghoztty-relay

[Install]
WantedBy=multi-user.target
```

## Manual testing with DEV_AUTH

`DEV_AUTH` lets you exercise enrollment and the bridge with no Google or Caddy.

### 1. Start the relay in dev mode

```bash
DEV_AUTH=true \
DEV_CLIENT_TOKEN=dev-secret-token \
DEV_EMAIL=dev@example.com \
STATE_DIR=./state \
LISTEN_ADDR=127.0.0.1:8080 \
go run .
```

You'll see `WARN: DEV_AUTH enabled — not for production`.

### 2. Enroll a device (curl)

```bash
curl -s -X POST http://127.0.0.1:8080/v1/client/devices \
  -H "Authorization: Bearer dev-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"name":"testbox"}'
# => {"id":"<device-uuid>","name":"testbox","token":"<raw-device-token>"}
```

The `token` is returned **once**; it is what an agent presents. List devices:

```bash
curl -s http://127.0.0.1:8080/v1/client/devices \
  -H "Authorization: Bearer dev-secret-token"
# => {"devices":[{"id":"...","name":"testbox","online":false,"created_at":"..."}]}
```

### 3. Verify bytes flow through the bridge

The end-to-end flow (enroll → agent control WS → client connect WS → assert an
echo round-trips both ways through the bridge) is automated in
`bridge_integration_test.go`. It spins the server on a random port with
`DEV_AUTH`, registers a fake agent, connects a client, and asserts payloads
cross the bridge in both directions:

```bash
go test -run TestBridgeEndToEnd -v ./...
```

This proves the bridge end-to-end without Google or Caddy. Other tests cover
fail-closed auth (`TestUnauthorizedRejected`) and refusing offline devices
(`TestConnectOfflineDevice`).

## Source layout

| File                          | Purpose |
|-------------------------------|---------|
| `main.go`                     | Wiring, HTTP server, graceful shutdown. |
| `config.go`                   | Environment-variable configuration. |
| `auth.go`                     | OIDC client verification, device-token verification, dev mode. |
| `store.go`                    | Device persistence (`devices.json`), token hashing. |
| `directory.go`                | Online-agent registry, control connections, pending sessions. |
| `bridge.go`                   | The bidirectional `io.Copy` splice. |
| `handlers.go`                 | HTTP/WebSocket endpoint handlers. |
| `bridge_integration_test.go` | End-to-end bridge + auth tests. |
