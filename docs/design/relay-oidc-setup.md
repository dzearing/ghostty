# Relay Google OIDC setup — deploy runbook (WP-B1)

Flip the relay from `DEV_AUTH` (static bearer) to **real Google sign-in**.
The code path is already implemented and test-verified (`relay/auth.go`,
`relay/auth_oidc_test.go`); this document is only the ~10 minutes of Google
Cloud Console clicks plus the env flip on the relay VM.

**Read the consequence first (§5):** the moment `DEV_AUTH` goes off, the dev
client token stops working, so the Mac app's `GHOSTTY_RELAY_TOKEN` dev flow
401s until WP-B2 (in-app sign-in) lands or you paste a fresh real ID token.
**Enrolled agents are unaffected** — device tokens are a separate mechanism
and keep working. Do the flip when you can live with that.

---

## 1. Google Cloud Console — register the OAuth client (~7 min)

### 1a. Project + consent screen (one-time)

1. Open <https://console.cloud.google.com/> (account: `dzearing@gmail.com`).
2. Top bar project picker → **New project** → name `ghoztty-relay` → **Create**
   → wait for the notification, then **select** the new project.
3. Left nav → **APIs & Services → OAuth consent screen** (Google now brands
   this "Google Auth Platform" — same thing; if prompted, click
   **Get started**).
4. Fill the branding form:
   - **App name:** `Ghoztty Remote`
   - **User support email:** `dzearing@gmail.com`
   - **Audience / User type:** **External**
   - **Developer contact email:** `dzearing@gmail.com`
   - Agree → **Create**.
5. Leave the app in **Testing** publishing status (do NOT click Publish).
   Under **Audience → Test users → + Add users**, add `dzearing@gmail.com`.
   Testing mode caps you at 100 test users and skips Google's verification
   review — exactly right for a personal relay whose server-side allowlist is
   `ALLOWED_EMAILS` anyway.
6. Scopes: **no action needed.** The relay only ever reads `openid` + `email`
   claims, which are non-sensitive default scopes; nothing to register.

### 1b. The OAuth client ID — Desktop (Mac app sign-in)

7. Left nav → **APIs & Services → Credentials** → **+ Create credentials →
   OAuth client ID**.
8. **Application type:** **Desktop app**. Why this type:
   - The macOS client (WP-B2) is a native app doing browser sign-in with a
     **loopback redirect** (`http://127.0.0.1:<random-port>`) + PKCE. Google
     allows loopback redirects for Desktop clients automatically — you do
     **not** register redirect URIs for Desktop clients (there is no field).
   - Do NOT pick "iOS" (wants an App Store bundle ID) or "Web application"
     (wants fixed redirect URIs and expects a confidential server).
9. **Name:** `ghoztty-client` → **Create**.
10. Copy the **Client ID** (`<something>.apps.googleusercontent.com`) and the
    **Client secret** (Desktop-app "secrets" are not confidential; it is only
    needed for token-endpoint calls, e.g. the §4 curl check and WP-B2).
    Stash both in your password manager.

### 1b-2. The SECOND OAuth client — device-code enroll (agents)

Google only allows the device-code grant ("OAuth for TVs and Limited-Input
Devices") for clients of type **TVs and Limited Input devices** — the Desktop
client above cannot use it. The agent self-enroll flow
(`ghoztty-agent --enroll`) therefore needs its own client:

11. **Credentials → + Create credentials → OAuth client ID** again.
12. **Application type:** **TVs and Limited Input devices**.
13. **Name:** `ghoztty-agent` → **Create**.
14. Copy this client's **Client ID** and **Client secret** too. (No, there is
    no missing field: TV/limited-input clients **do** get a client secret —
    like Desktop secrets it is not confidential, but Google's token endpoint
    requires it on device-code polls.) These become
    `GOOGLE_DEVICE_CLIENT_ID` / `GOOGLE_DEVICE_CLIENT_SECRET` in §2.

ID tokens minted through this client carry *its* ID as `aud`; the relay
accepts either client's `aud` (explicit allowlist in `relay/auth.go`), so
tokens from the enroll flow and from the Mac app's sign-in both verify.

### 1b-3. The THIRD OAuth client — browser (web) enroll

The default enrollment UX is Tailscale-style: `ghoztty-agent --enroll` opens
the owner's browser, they approve the Google sign-in, done — no code to type.
That leg is a standard server-side authorization-code flow, which needs a
client of type **Web application** with a fixed redirect URI on the relay:

15. **Credentials → + Create credentials → OAuth client ID** once more.
16. **Application type:** **Web application**.
17. **Name:** `ghoztty-web-enroll` → **Create**.
18. Under **Authorized redirect URIs → + Add URI**, enter EXACTLY:

    ```
    https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com/enroll/callback
    ```

    (General form: `https://<relay-host>/enroll/callback` — it must match the
    relay's public base char-for-char; Google rejects mismatched callbacks.)
    No authorized JavaScript origins needed.
19. Copy this client's **Client ID** and **Client secret**. These become
    `GOOGLE_WEB_CLIENT_ID` / `GOOGLE_WEB_CLIENT_SECRET` in §2. Unlike the
    Desktop/TV "secrets", a Web client secret IS confidential — it lives only
    in the relay's env file and the code exchange happens server-side; it is
    never given to agents or browsers.

These env vars are **optional**: with them unset, web enrollment answers 503
and agents automatically fall back to the §1b-2 device-code flow (that is
also the headless path — `--no-browser`/`--headless-enroll` forces it).

## 2. Configure the relay VM (~2 min)

SSH to the Azure VM (`ghoztty-relay-dz17575.westus2.cloudapp.azure.com`, RG
`ghoztty-relay-rg`). The systemd unit `ghoztty-relay` reads its env from
`/etc/ghoztty-relay.env`.

```bash
sudo cp /etc/ghoztty-relay.env /etc/ghoztty-relay.env.bak   # rollback copy
sudoedit /etc/ghoztty-relay.env
```

Set:

```bash
GOOGLE_CLIENT_ID=<the-desktop-client-id-from-step-10>.apps.googleusercontent.com
GOOGLE_DEVICE_CLIENT_ID=<the-tv-client-id-from-step-14>.apps.googleusercontent.com
GOOGLE_DEVICE_CLIENT_SECRET=<the-tv-client-secret-from-step-14>
GOOGLE_WEB_CLIENT_ID=<the-web-client-id-from-step-19>.apps.googleusercontent.com
GOOGLE_WEB_CLIENT_SECRET=<the-web-client-secret-from-step-19>
ALLOWED_EMAILS=dzearing@gmail.com
DEV_AUTH=false          # or delete the DEV_AUTH / DEV_CLIENT_TOKEN / DEV_EMAIL lines
STATE_DIR=/var/lib/ghoztty-relay   # keep whatever is already there
LISTEN_ADDR=127.0.0.1:8080         # keep
```

(`GOOGLE_DEVICE_CLIENT_ID`/`_SECRET` drive the agent device-code enroll; if
they are unset the relay falls back to `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`
for enroll, which Google will refuse for a Desktop client — so set them.
`GOOGLE_WEB_CLIENT_ID`/`_SECRET` drive the browser enroll flow; leaving them
unset just downgrades enrollment UX to the device-code prompt.)

Notes:
- `ALLOWED_EMAILS` is comma-separated, case-insensitive. A valid Google login
  by anyone NOT listed is rejected (401) — the consent-screen test-user list is
  not the authorization boundary, this is.
- **Caddy needs no changes.** It keeps terminating TLS on :443 and
  reverse-proxying `127.0.0.1:8080` (including the `/dl/*` installer path).
  OIDC verification is entirely inside the Go process (outbound HTTPS to
  `accounts.google.com` for discovery + JWKS — allow outbound 443, which the
  VM already has).

Restart and check the startup log line:

```bash
sudo systemctl restart ghoztty-relay
journalctl -u ghoztty-relay -n 20 --no-pager
```

You must see `OIDC client auth enabled issuer=https://accounts.google.com` and
you must NOT see `DEV_AUTH enabled`. If instead you see
`GOOGLE_CLIENT_ID unset`, the env file did not take — fix before proceeding
(with DEV_AUTH also off the relay now rejects **all** clients).

## 3. Get a real ID token for testing (~1 min)

On the Mac, with `CID`/`CSECRET` from step 10:

```bash
# 1. Open the consent URL in a browser (any random loopback port is fine):
open "https://accounts.google.com/o/oauth2/v2/auth?client_id=$CID&redirect_uri=http://127.0.0.1:8765&response_type=code&scope=openid%20email"
```

Sign in as `dzearing@gmail.com`. The browser lands on
`http://127.0.0.1:8765/?code=4/0A...` and shows "connection refused" — that's
fine, **copy the `code` value from the address bar** (it's single-use,
~10 min lifetime).

```bash
# 2. Exchange the code for tokens:
curl -s https://oauth2.googleapis.com/token \
  -d client_id="$CID" -d client_secret="$CSECRET" \
  -d code="<the-code>" -d redirect_uri=http://127.0.0.1:8765 \
  -d grant_type=authorization_code
# => JSON containing "id_token": "eyJ..."   (valid ~1 hour)
export IDT="<the id_token value>"
```

## 4. Verification checklist

```bash
FQDN=ghoztty-relay-dz17575.westus2.cloudapp.azure.com

# [ ] Real Google ID token works (lists the enrolled devices):
curl -s -H "Authorization: Bearer $IDT" https://$FQDN/v1/client/devices
#     => {"devices":[...windows-home etc...]}  HTTP 200

# [ ] Old dev client token is DEAD:
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer <old dev token>" https://$FQDN/v1/client/devices
#     => 401

# [ ] No token / garbage token => 401:
curl -s -o /dev/null -w '%{http_code}\n' https://$FQDN/v1/client/devices   # 401

# [ ] Agents unaffected: device list above shows "online":true for
#     windows-home (its device token still authenticates the control WS).

# [ ] Full path: open a real remote window using the ID token as the client token:
zig-out/Ghoztty-Debug.app/Contents/MacOS/ghoztty +new-remote-window \
  --relay=https://$FQDN --device=<device-id> --token="$IDT" --name=maximushome
```

A non-allowlisted Google account's token must also get 401 (test if you have a
second account handy).

## 5. Rollback (one line)

```bash
sudo cp /etc/ghoztty-relay.env.bak /etc/ghoztty-relay.env && sudo systemctl restart ghoztty-relay
```

(i.e. re-enable `DEV_AUTH=true` + `DEV_CLIENT_TOKEN` + `DEV_EMAIL`). Dev and
OIDC auth can coexist — `DEV_AUTH=true` with `GOOGLE_CLIENT_ID` set accepts
both, which is a fine halfway state while WP-B2 is in flight.

## Appendix: what the relay actually verifies

Per `relay/auth.go` (tested in `relay/auth_oidc_test.go` against a fake local
issuer): RS256 signature against Google's published JWKS, `iss ==
https://accounts.google.com`, `aud ∈ {GOOGLE_CLIENT_ID,
GOOGLE_DEVICE_CLIENT_ID, GOOGLE_WEB_CLIENT_ID}`
(the latter entries only when configured; fail-closed explicit allowlist),
`exp`, `sub` present,
`email_verified == true`, then `email ∈ ALLOWED_EMAILS`. Any failure →
fail-closed 401, never bridged. The verified identity (email + Google `sub`)
scopes all device CRUD and connects.
