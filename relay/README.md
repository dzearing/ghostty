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
| PATCH  | `/v1/client/devices/{id}`         | OIDC         | Rename an owned device (`{"name":"..."}`); returns the updated device view. |
| DELETE | `/v1/client/devices/{id}`         | OIDC         | Delete an owned device **and revoke its token**; any live agent connections are closed. Returns `204`. |
| GET    | `/v1/client/connect?device=<id>`  | OIDC         | Open a session to an owned, online device and bridge it. |
| POST   | `/v1/enroll/start`                | none         | Begin device-code **self-enroll** (`{"name":"<machine name>"}`); returns `{verification_url, user_code, device_code_handle, interval, expires_in}`. |
| POST   | `/v1/enroll/poll`                 | none (rate-limited) | Poll a pending enrollment (`{"device_code_handle":"..."}`). Pending → `{"status":"pending"}`; approved → `{"status":"complete", device_id, device_token, relay_base}` **once**; denied/expired/rejected are terminal. |
| GET    | `/healthz`                        | none         | Liveness probe. |

## Self-enrollment (OAuth device-code flow)

Agents on fresh machines enroll **themselves** — no pre-minted token to copy
around. The installer:

1. `POST /v1/enroll/start` with `{"name":"<hostname>"}` and prints:

   ```
   To register this machine, visit https://www.google.com/device
   and enter code: WXYZ-1234
   ```

2. Polls `POST /v1/enroll/poll` with the returned `device_code_handle`
   (respecting `interval`; premature polls get `429 {"status":"slow_down"}`).
3. The owner signs in with Google (2FA and all) and approves.
4. The next poll returns `{"status":"complete","device_id":...,
   "device_token":...,"relay_base":...}` **exactly once**. The installer
   persists the token (e.g. `%LOCALAPPDATA%\ghoztty\relay.env`) and starts
   `ghoztty-agent --relay=<relay_base>`.

Poll outcomes: `200 pending` (keep polling), `429 slow_down` (too fast),
`200 complete` (done, single-shot), `403 denied` (owner refused),
`410 expired` (code timed out), `403 rejected` (a real Google login that is
not on `ALLOWED_EMAILS`), `404` (unknown or already-consumed handle). All
4xx/410 outcomes except `429` are terminal — start over.

Design notes:

- **Google's `device_code` never leaves the relay.** The caller gets an
  opaque 256-bit `device_code_handle` instead; the real code is a bearer
  credential against Google's token endpoint, so keeping it server-side means
  the relay alone controls the poll rate Google sees and the owner's ID token
  never transits the (still-unauthenticated) agent box.
- **Enrollment is idempotent**: same verified owner + same requested name →
  the **same device id** with a **rotated credential** (the old token is
  revoked). Re-running the installer is therefore also the lost-token
  recovery path. A different name creates a distinct device.
- The ID token produced by the sign-in is verified **exactly** like
  interactive client auth (same verifier, same `ALLOWED_EMAILS`).
- Abuse bounds: pending enrollments are capped (32), expire on Google's
  `expires_in`, and per-handle polling is throttled to the advertised
  interval without contacting Google.
- Requires `GOOGLE_CLIENT_ID` (and normally `GOOGLE_CLIENT_SECRET`); the
  device/token endpoints are read from Google's OIDC discovery document.
  Without OIDC configured the endpoints answer `503`.

## Configuration (environment variables)

| Variable           | Default            | Purpose |
|--------------------|--------------------|---------|
| `LISTEN_ADDR`      | `127.0.0.1:8080`   | Plain-HTTP listen address (TLS handled by Caddy). |
| `GOOGLE_CLIENT_ID` | *(unset)*          | OAuth/OIDC client ID; Google ID tokens must carry this as `aud`. Required for real client auth and for self-enrollment. |
| `GOOGLE_CLIENT_SECRET` | *(unset)*      | OAuth client secret, used only when polling Google's token endpoint during self-enrollment (required by Google for desktop/TV client types; not confidential for those types). |
| `RELAY_BASE_URL`   | *(unset)*          | Public https base URL returned to freshly enrolled agents (`relay_base`). When unset it is derived from the request `Host` header, which is correct behind Caddy. |
| `ALLOWED_EMAILS`   | *(empty)*          | Comma-separated authorization allowlist of verified Google emails. A valid login by anyone not listed is rejected — including at self-enrollment. |
| `STATE_DIR`        | `./state`          | Directory holding `devices.json` (persisted device hashes). |
| `DEV_AUTH`         | `false`            | **Testing only.** Accept a static bearer as a stand-in for OIDC. Logs a loud warning at startup. |
| `DEV_CLIENT_TOKEN` | *(unset)*          | The static bearer accepted when `DEV_AUTH=true`. |
| `DEV_EMAIL`        | *(unset)*          | Identity that a successful dev-auth maps to (becomes the device owner). |

Setting up real Google OIDC (registering the OAuth client, flipping the VM from
`DEV_AUTH` to `GOOGLE_CLIENT_ID`/`ALLOWED_EMAILS`, verification + rollback) is a
~10 minute runbook: see **`../docs/design/relay-oidc-setup.md`**. `DEV_AUTH=true`
and OIDC can coexist during transition — the static token and real ID tokens are
both accepted until `DEV_AUTH` is turned off.

### Security model (summary)

- **Clients:** the Google ID token is fully verified — signature against
  Google's JWKS (issuer `https://accounts.google.com`), `aud == GOOGLE_CLIENT_ID`,
  `exp`, `sub` present, and `email_verified == true`. The email must then be on
  `ALLOWED_EMAILS`. Presence of a token is never sufficient. The verified
  identity is `{email, sub}` (Google's stable subject ID). Every HTTP request
  the OIDC machinery makes (discovery, JWKS refresh) is bounded by a 15s client
  timeout. The whole path is exercised in `auth_oidc_test.go` against a fake
  local issuer (self-minted RS256 tokens): valid accepted; wrong aud/iss,
  expired, forged signature, unverified/missing email, and non-allowlisted
  logins all rejected.
- **Agents:** the presented device token is SHA-256'd and compared
  constant-time against the stored hash. **Raw tokens are never stored or
  logged** — only their SHA-256 hash is persisted to `devices.json`.
- **Authorization:** a client may only list/connect/rename/delete devices whose
  `owner_email` matches its verified email. Unknown / unowned device IDs return
  `404` (not enumerable).
- **Revocation:** deleting a device removes its token hash (the token can never
  authenticate again) and immediately closes its live control connection and
  any bridged sessions.
- **Fail-closed:** any auth failure → HTTP 401 (or WS close 1008) and **no
  bridge**.
- **Abuse bounds:** pending sessions are capped, session setup times out (~15s),
  control connections have a ping/pong heartbeat with timeout, and the
  unauthenticated enroll endpoints cap pending enrollments and throttle polls
  per handle.

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

Rename and delete a device:

```bash
curl -s -X PATCH http://127.0.0.1:8080/v1/client/devices/<device-uuid> \
  -H "Authorization: Bearer dev-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"name":"newname"}'
# => {"id":"...","name":"newname","online":false,"created_at":"..."}

curl -s -X DELETE http://127.0.0.1:8080/v1/client/devices/<device-uuid> \
  -H "Authorization: Bearer dev-secret-token"
# => 204 No Content; the device token is revoked and any live agent
#    connection is closed. A subsequent agent dial with that token gets 401.
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
fail-closed auth (`TestUnauthorizedRejected`), refusing offline devices
(`TestConnectOfflineDevice`), and device CRUD in `devices_crud_test.go`:
rename (`TestRenameDevice`), delete (`TestDeleteDevice`), delete-revokes-token
(`TestDeleteRevokesCredential`), and owner scoping (`TestCrudOwnerScoping`).

## Source layout

| File                          | Purpose |
|-------------------------------|---------|
| `main.go`                     | Wiring, HTTP server, graceful shutdown. |
| `config.go`                   | Environment-variable configuration. |
| `auth.go`                     | OIDC client verification, device-token verification, dev mode. |
| `enroll.go`                   | OAuth device-code self-enrollment (start/poll state machine). |
| `store.go`                    | Device persistence (`devices.json`), token hashing, idempotent upsert. |
| `directory.go`                | Online-agent registry, control connections, pending sessions. |
| `bridge.go`                   | The bidirectional `io.Copy` splice. |
| `handlers.go`                 | HTTP/WebSocket endpoint handlers. |
| `bridge_integration_test.go` | End-to-end bridge + auth tests. |
| `devices_crud_test.go`       | Device rename/delete/revocation/owner-scoping tests. |
| `auth_oidc_test.go`          | OIDC client-auth tests against a fake local issuer (JWKS + self-minted RS256 tokens). |
| `enroll_test.go`             | Self-enroll tests against fake Google device-code/token endpoints (happy path, idempotent re-enroll, denied/expired, allowlist rejection, poll rate limit). |
