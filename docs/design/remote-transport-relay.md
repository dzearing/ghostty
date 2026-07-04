# Remote Transport: Tailscale-free Secure Tunnel

> Status: design proposal (2026-06-28). Supplements `remote-machines.md` §4
> (Transport) and §15 (Security). Motivated by: **Tailscale is banned in the
> user's org**, but the shipped increment uses an *unauthenticated raw-TCP
> listener on `0.0.0.0:7777`* that relied entirely on Tailscale for trust and
> reachability. This doc specifies how local Ghoztty and `ghoztty-agent` reach
> each other **securely without Tailscale**.

---

## 1. Problem & what Tailscale was actually providing

The current wire path (`src/remote/tcp_dial.zig` ↔ `src/remote/agent/main.zig`)
is **plaintext, unauthenticated TCP**. The agent header says so directly: *"any
host that can reach the port can open a shell session… relies entirely on network
trust (Tailscale / a trusted LAN)."*

Tailscale was silently providing **three** things. Any replacement must cover all
three:

1. **Encryption** on the wire — currently none.
2. **Authentication** — currently none (no token, no mTLS, no SSH).
3. **Reachability / NAT traversal** — outbound-only mesh between machines that may
   both sit behind NAT (e.g. the corp laptop ↔ the home `maximushome` box).

Topology in scope is **both/mix**: some remotes are corp-internal (reachable
directly or via an SSH bastion); some are behind home NAT with no public IP.

## 2. Note: the design already mandates SSH

`remote-machines.md` §4.1 specifies the transport as
`ssh <host> ghoztty-agent attach` — SSH owns auth (`authorized_keys`),
encryption, and agent push; §13 documents OpenSSH-Server on Windows; §15's entire
security model is "SSH access = the trust boundary." **The raw-TCP-over-Tailscale
listener is a deviation from the spec**, taken as a shortcut to get the Windows
box working. Phase 0 below returns to the designed SSH transport; Phase 1 adds the
relay the user wants for seamless NAT traversal.

## 3. Architecture: relay-gated rendezvous, SSH carried inside

**Principle: the relay does reachability + sign-in only. SSH does encryption +
auth.** Two layers, each doing one job, neither hand-rolled. (This is how
Cloudflare Access-for-SSH, Teleport, and HashiCorp Boundary work.)

```
  ┌──────────────┐   wss://relay:443 (outbound)   ┌──────────────┐
  │ Ghoztty (mac)│ ───────────────────────────►   │              │
  │  client      │                                 │    RELAY     │
  └──────┬───────┘                                 │  (your VPS)  │
         │  SSH (E2E) carried inside the WS stream  │  - OIDC sign-in
         │  ════════════════════════════════════►  │  - device directory
  ┌──────┴───────┐   wss://relay:443 (outbound)    │  - stream bridge
  │ ghoztty-agent│ ◄───────────────────────────    │              │
  │  (remote)    │                                  └──────────────┘
  └──────────────┘
  Relay sees only SSH ciphertext. It cannot read keystrokes.
```

### 3.1 Why outbound-only `wss://` on 443

- **NAT-agnostic on both ends.** Neither the agent nor the client needs an inbound
  port. The home-NAT box and the corp box connect *out* to the relay identically —
  this is what makes "both/mix" work with one mechanism.
- **Corp-proxy friendly.** Port 443 + WebSocket-over-TLS looks like ordinary HTTPS;
  it traverses corporate egress proxies that block novel protocols.
- The framed Ghoztty protocol rides inside the WS binary frames; the existing mux
  sees a byte stream exactly as it does for TCP today.

### 3.2 The relay (your VPS)

A small service. Three responsibilities, nothing more:

1. **Sign-in (OIDC).** Browser OAuth for the *user* (Google/GitHub →
   `dzearing@gmail.com`); device-code enrollment for the *agent* → a long-lived
   device credential. The relay never sees SSH keys or shell bytes.
2. **Directory.** Tracks which agents (devices) are online, per account.
   **This replaces hardcoded `Machine.swift`** — the machine list becomes "my
   online devices," populated live from the relay.
3. **Stream bridge.** On `connect(device)`: verify the caller's account owns/【is
   authorized for】that device, then splice the two outbound WS streams into one
   bidirectional pipe. Pure relay (TURN-style); all bytes flow through it as
   ciphertext. P2P hole-punch is a **later optimization**, not v1.

The relay is **untrusted for confidentiality** (SSH is E2E) but **trusted for
availability + authorization** (it's in the path; if it's down, no new sessions;
it decides who may reach which device). Operational cost is real: uptime,
patching, abuse — this is "a small Tailscale control-plane + DERP." Justified only
because seamless NAT traversal is a hard requirement.

### 3.3 SSH carried over the relay (E2E)

The client opens an authenticated WS session to the relay targeting device X, then
runs SSH with that stream as its transport:

```
ssh -o ProxyCommand="ghoztty-relay-connect --device=%h" \
    <device-id> ghoztty-agent attach [--session=<uuid>]
```

`ghoztty-relay-connect` is a tiny helper (or in-process dialer) that: presents the
cached OIDC token, asks the relay to bridge to `--device`, and pipes the resulting
WS stream to stdin/stdout. SSH then performs its normal key handshake **end to
end** with the agent over that pipe. Result: **zero new crypto code**, reuses
`authorized_keys` + the §4.1 interactive-auth/host-key UX already designed, and the
relay only ever sees SSH ciphertext.

The agent side mirrors this: instead of (or alongside) the TCP listener, the agent
maintains an outbound WS registration to the relay and, per inbound bridged
session, runs its existing `ConnWorker` over the stream.

### 3.4 Data path, cost & P2P

**In the v1 (proven) design, all bytes flow client → relay → agent.** That is fine,
because the cost depends entirely on *what* is flowing:

- **Terminal sessions = trivial.** Keystrokes + screen output are KB/s; a heavy day
  is single-digit-to-low-tens of MB. Azure's first **100 GB/mo egress is free**
  (then ~$0.087/GB), and MSDN credit covers it regardless. Relaying shells is
  effectively free — no optimization needed.
- **Bulk port-forwarding (§8 tunneling) = the only real cost driver.** Large file
  transfers / big HTTP payloads pushed through a forwarded port can move real GBs.
  This — not shells — is where a direct path pays off.

**Direct / P2P (v2 optimization, mirrors Tailscale's DERP model):**
1. **Direct dial when reachable** — if one end is routable (corp box, or via
   bastion), the relay does only auth + discovery, then the client connects straight
   to the agent; the relay carries nothing after the handshake.
2. **NAT hole-punching** — relay acts as a STUN/ICE-style **signaling** server so two
   NATed ends learn each other's public IP:port and punch a **direct UDP** path;
   data then bypasses the relay (relay saw only the handshake).
3. **Hybrid (end state)** — always auth+signal at the relay, *attempt* P2P, **fall
   back to relaying data when P2P fails.** Cheap, reliable, and E2E-SSH on every path.

**Two caveats, both pointing to "ship relay first":**
- P2P needs **UDP/QUIC**, a different transport than the proven SSH-over-WSS (TCP) —
  bigger build (STUN/ICE/punch), hence v2 (aligns with §16 "UDP roaming" in
  `remote-machines.md`).
- **Corp networks often block outbound UDP** (443-only). Tailscale itself then falls
  back to DERP-relay-over-TLS-443 — i.e. our WSS relay. So the headline path
  (**corp laptop → home box**) will likely relay anyway — but that path is terminal
  traffic, the cheap case. Home↔home punches directly with ease.

**Decision:** ship relay-everything for v1 (cheap for shells); add direct/P2P later
as a targeted optimization for bulk forwarding + throughput-sensitive paths. P2P does
not block v1.

## 4. Code seam (minimal churn)

The transport is already abstracted: `SocketStream` → `ClientMux`/`ServerMux` →
`Connection`, and `tcp_dial.zig` is ~60 lines. Each transport is just **a dialer
that yields a `connectionStream()` into the existing mux.** Everything above the
transport — protocol, sessions, resync, the Activity Monitor — is untouched.

New/changed pieces:

- **Client:** `src/remote/relay_dial.zig` (sibling of `tcp_dial.zig`) — open WS to
  relay, auth, request bridge, return a stream. Wire to a new
  `ghostty_remote_connection_new_relay(...)` C export (mirror of
  `ghostty_remote_connection_new_tcp`).
- **Agent:** an outbound `--relay=<url>` registration mode in
  `src/remote/agent/main.zig` alongside the listener; each bridged session →
  existing `ConnWorker`.
- **macOS:** OIDC sign-in sheet; populate the machine list from the relay
  directory instead of the hardcoded `Machine.swift` array; "Sign in" + device
  list in the connect flow.
- **Relay service:** a new small codebase (language TBD — Go/Rust/Zig). Outbound
  WS, OIDC, directory, bridge. Deployed on a personal VPS.
- **`ghoztty-relay-connect`** helper for the SSH `ProxyCommand` (or fold into the
  client dialer).

## 5. Security model (delta vs `remote-machines.md` §15)

- **Confidentiality/integrity of shell traffic:** SSH end-to-end. Relay sees
  ciphertext only. No new crypto to audit (Phase 1a). If Noise is chosen later
  (Phase 1b), that handshake becomes new security-sensitive code — use a vetted
  library, never hand-roll.
- **Authentication is a HARD REQUIREMENT, fail-closed (the headline invariant).**
  An open relay that bridges into shells is catastrophic, so *every* connection —
  client AND agent — authenticates before the relay does anything, and the default
  with no/invalid credential is REJECT. Three layers, defense in depth:
  1. **Client (human) → OIDC sign-in.** Browser OAuth with Google; the relay
     verifies the ID token *properly* (signature against Google's JWKS, `iss`,
     `aud`, `exp`, nonce) — presence of a token is never enough.
     **2FA rides along for free:** because sign-in is Google's flow, the relay
     inherits the user's Google **2-step verification** — registering a new client
     requires the Google password *and* the second factor. No 2FA system to build.
  2. **Identity allowlist (authz, not just authn).** OIDC proves "*a* Google user";
     the relay bridges only if that verified email is on a hardcoded allowlist (just
     the owner). A valid Google login by anyone else is rejected.
  3. **Agent (machine) → enrolled device credential.** A daemon can't do interactive
     2FA, so it carries a long-lived device key/token **minted once at enrollment**,
     when the signed-in (2FA'd) owner approves the device. 2FA gates enrollment; the
     device key gates every subsequent connect. Revocable from the relay.
  Plus the SSH layer **inside** the tunnel (`authorized_keys`) as a fully
  independent gate: a relay compromise still can't open a shell without the SSH key;
  a stolen SSH key still can't reach a device without a valid relay session. An
  attacker must defeat BOTH.
- **Optional network-level brick wall — mTLS.** Require a client cert at the TLS
  handshake (Caddy `client_auth`), so anything without the cert is dropped before app
  logic. Ideal on the agent/home side. Caveat: a corp TLS-intercepting proxy can break
  client mTLS, so keep it optional and agent-side; OIDC is the portable client gate.
- **Kill the unauthenticated listener.** The `0.0.0.0:7777` raw listener must be
  removed or bound to `127.0.0.1` only. It is the current security hole, not a
  feature to preserve.
- **Trust boundary unchanged from §15:** a compromised remote account = full
  compromise of that host's sessions. The relay does not expand this.
- **Relay abuse:** rate-limit enrollment + bridge requests; scope device directory
  strictly to the authenticated account; log bridge events.

## 6. Phasing

- **Phase 0 — remove Tailscale now, no server.** Switch the transport back to the
  designed SSH path (§4.1). Unblocks corp-internal + bastion (ProxyJump)
  immediately; removes the unauthenticated listener. Home-NAT box still needs a
  jump host in this phase. **No relay to build or host.**
- **Phase 1a — relay carrying SSH.** Stand up the VPS relay + Google/GitHub OIDC;
  `relay_dial.zig`, agent `--relay` mode, `ghoztty-relay-connect`, macOS sign-in +
  live device list. This makes both/mix + home-NAT "just work" after login. *(Chosen
  E2E = SSH-over-relay; chosen IdP = Google/GitHub; host = personal VPS.)*
- **Phase 1b (optional, later) — Noise E2E + P2P.** Drop the per-host SSH
  dependency via Noise_IK on enrolled device keys; add NAT hole-punching so traffic
  goes direct when possible and falls back to relay. Only if SSH-per-host or
  relay-bandwidth become real pain.

## 7. Work packages (supplements `remote-machines.md` §18)

- **WP-T0 — SSH transport (Phase 0).** Replace `tcp_dial` default with the §4.1
  SSH bootstrap (`SSH_ASKPASS` interactive auth, first-contact host-key UX, agent
  push, ControlMaster). Bind any remaining listener to loopback. Remove
  Tailscale-IP assumptions from `Machine.swift`.
- **WP-T1 — Relay service. ✅ BUILT + DEPLOYED + PROVEN (2026-06-28).** Go service
  in `relay/` (module `github.com/dzearing/ghoztty-relay`), reverse-tunnel model:
  agent holds `/v1/agent/control`, relay sends `{"type":"open","session"}`, agent
  dials `/v1/agent/data?session=`, relay splices client↔agent as an opaque byte pipe
  (`websocket.NetConn` + `io.Copy`). Full Google OIDC verification (sig/iss/aud/exp +
  `email_verified` + email allowlist) for clients; SHA-256-hashed, constant-time
  device tokens for agents; device enrollment via `POST /v1/client/devices`;
  in-memory online directory; bounded pending sessions + setup timeout + control
  heartbeat; fail-closed throughout. Behind Caddy (TLS) on the West US 2 test VM as a
  hardened systemd unit (dedicated user, `ProtectSystem=strict`). End-to-end bridge
  round-trip verified over the live public WSS path; negative-auth (401) verified.
  **Remaining for prod:** register a Google OAuth client → set `GOOGLE_CLIENT_ID` +
  `ALLOWED_EMAILS` and disable `DEV_AUTH`; add audit logging + rate limits. Has an
  `e2e` smoke-test tool (`go run ./cmd/e2e`) and a `go test` integration test.
- **WP-T2 — Client relay transport. 🟡 TRANSPORT PROVEN (2026-06-28).** Realized as
  **SSH-over-relay via `ProxyCommand`** (cleaner than a bespoke Zig WS dialer):
  reuses the existing `ssh_transport.zig`, which already builds the full ssh argv and
  now takes a `proxy_command` field emitting `-o ProxyCommand=` (done; unit-tested,
  81/81). The ProxyCommand runs **`relay-connect`** (Go, `relay/cmd/relay-connect`):
  it opens an authenticated `/v1/client/connect` WS and splices it to stdio, so ssh
  handshakes end-to-end with the remote sshd through the relay (relay sees only
  ciphertext). **Proven:** `ssh` from a Mac through the live relay into the VM's sshd.
  **Remaining:** a thin `relayDialConfig` helper + `ghostty_remote_connection_new_relay`
  C export that points `proxy_command` at `relay-connect` and sets host=device-id.
- **WP-T3 — Agent relay connector. 🟡 PROVEN (2026-06-28).** Realized as
  **`relay-agent`** (Go, `relay/cmd/relay-agent`): outbound registration on
  `/v1/agent/control`, and per `open` it dials `/v1/agent/data?session=` and bridges
  to a local target (the machine's sshd for SSH-over-relay; later the local
  `ghoztty-agent` endpoint directly). Reconnect loop + systemd unit. This supersedes
  the old "`--relay` flag inside `agent/main.zig` feeding `ConnWorker`" plan — the
  connector is a separate sidecar, so the agent stays transport-agnostic. **Still
  retire/loopback-bind** the legacy `0.0.0.0:7777` listener in `agent/main.zig`.
- **WP-T4 — macOS sign-in + dynamic machine list.** OIDC sheet, token cache,
  device list from relay directory (replaces hardcoded `Machine.swift`), connect
  flow.

## 7.5 Validation spike — RESULTS (2026-06-28) ✅

The keystone assumption ("a corp-banned-Tailscale network will still let both ends
reach an outbound `wss://:443` relay") was **proven end-to-end against the real corp
network**, not assumed.

**Test rig:** Azure VM `ghoztty-relay` (Ubuntu 22.04, Standard_B1s, West US 2) on
the user's **personal MSDN subscription** (`dzearing@hotmail.com` — separate from the
work tenant). FQDN `ghoztty-relay-dz17575.westus2.cloudapp.azure.com`
(IP 4.154.77.152). Caddy terminating TLS with a real **Let's Encrypt** cert;
`/ws` reverse-proxied to a Python `websockets` echo server; a browser self-test page
at `/`. RG: `ghoztty-relay-rg`.

**Results (run from the corp laptop):**
- ✅ Corp egress reaches the external HTTPS relay (placeholder body returned).
- ✅ Valid public-CA TLS (Let's Encrypt) served and accepted.
- ✅ **WebSocket upgrade survives the corp network** (browser self-test = green
  "WSS WORKS"; server-side `curl --http1.1` upgrade returned `101 Switching
  Protocols`).

**Conclusion:** the relay-gated-rendezvous + SSH-over-WSS:443 design is viable on
this network **as-is**. No fallback (HTTPS-chunked transport) is needed. Whether the
corp proxy does TLS interception turned out moot — WSS passes either way.

**Teardown:** `az group delete -n ghoztty-relay-rg --yes` removes all test
resources. (Kept running for now as the dev relay host.)

## 8. Open questions

- Relay language/framework + VPS deploy story (systemd? container?).
- Token storage on macOS (Keychain) + refresh; agent device-credential rotation.
- Device naming / multi-user accounts on a shared relay (future).
- Bandwidth/latency of pure relay vs. when to invest in P2P (Phase 1b trigger).
