# Relay-Brokered OAuth (BFF) — Design Spec

- **Date:** 2026-07-16
- **Branch:** `users/dzearing/brokered-oauth`
- **Status:** Approved (design), pending implementation

## Problem

The macOS app currently performs the full Google OAuth token exchange itself
(`GoogleOAuth.TokenClient` POSTs to `https://oauth2.googleapis.com/token` with
`client_id` + `client_secret`), and resolves the Google client id/secret at
runtime from env vars (`GHOSTTY_GOOGLE_CLIENT_ID/_SECRET`) or UserDefaults
(`GhosttyGoogleClientID/Secret`). Nothing is baked into the build.

Two problems:

1. **Fragile runtime credential lookup.** On the user's machine none of those
   sources were set (the env pair had only been provided via `launchctl setenv`,
   which does not survive a reboot), so `RelayAccount.isConfigured` was `false`.
   That made `AppDelegate.newRemoteWindow(_:)` silently fall back to a plain
   local window on ⌘⇧N instead of showing the chooser — the app looked broken.
2. **Client-side credential-secrecy dependency.** Even though the desktop
   `client_secret` is non-confidential per RFC 8252 (security rests on PKCE +
   the relay's email allowlist), shipping it in/near the client leaves a
   client-impersonation / quota-abuse vector, and the app persists Google
   refresh + id tokens locally.

## Goal

Move the confidential Google `client_secret` off the app and onto the **relay**,
using a full **BFF (backend-for-frontend) brokered token exchange**. The app
keeps PKCE + loopback and obtains the authorization `code` locally, then hands it
to the relay. The relay holds the secret, performs the code→token exchange (and
all refreshes) with Google, enforces the email allowlist, and mints its own
short-lived **relay session token** for the app.

**Google id/refresh tokens must never touch the client** — they live only on the
relay (refresh token encrypted at rest).

### Non-goals
- Multi-user support (single owner today; allowlist unchanged).
- Changing the transport/dial/agent protocols (unchanged).
- Backward compatibility for already-signed-in clients: the sole user accepts a
  one-time re-sign-in and a brief relay disruption during cutover.

## Architecture

Three parties:

- **App (macOS):** PKCE + loopback → authorization `code` locally → POST
  `{code, code_verifier, redirect_uri}` to the relay → receives
  `{session_token, expiry, email, picture?}`. Stores **only the session token**
  in Keychain; uses it as the Bearer for every relay call; renews before expiry.
  Builds the Google authorize URL with a **build-time-compiled client id**.
  Never sees the client secret or any Google token.
- **Relay (Go):** holds `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` (the Desktop
  client). Exchanges the code with Google, verifies the id_token (existing
  aud-allowlist + `ALLOWED_EMAILS`), stores the Google refresh token encrypted at
  rest, mints the opaque session token, and renews sessions using the stored
  refresh token. `/v1/client/*` authenticate via the session token.
- **Google:** unchanged.

## Relay design

### New endpoints

`POST /oauth/exchange`
- Body: `{ code, code_verifier, redirect_uri }`.
- Validate `redirect_uri` is a **loopback** address (`127.0.0.1` / `[::1]` /
  `localhost`), so the relay isn't a generic code-exchange oracle.
- Call Google's token endpoint (`grant_type=authorization_code`) with
  `client_id` + `client_secret` (Desktop) + `code` + `code_verifier` +
  `redirect_uri`, capturing `id_token`, `refresh_token`, `expires_in`.
- Verify the id_token with the **existing** `VerifyIDToken` (signature/issuer/exp
  via JWKS, aud in the allowlist, `email_verified`, `sub`, `ALLOWED_EMAILS`).
  Reject → `401/403`, no session minted.
- Require a `refresh_token` in the response (the app requests `access_type=offline`
  + `prompt=consent`, so it is present). Missing → `400`.
- Extract `email`, and `picture`/`name` claims for display.
- Insert a session row: encrypt the refresh token, `token_hash = hex(SHA-256(raw))`,
  `expires_at = now + 1h`.
- Return `{ session_token, expiry, email, picture? }`.

`POST /oauth/renew`
- Bearer = the current session token. Accepted even if just past `expires_at`
  (within a max-idle window); rejected if `revoked_at` set or row absent/expired
  past max-idle.
- Decrypt the stored refresh token → Google refresh grant → fresh id_token
  (+ possibly rotated refresh_token).
- **Re-run `VerifyIDToken`** on the fresh id_token (so upstream revocation or an
  allowlist removal is caught). Google refresh failure or allowlist denial →
  revoke/delete the row, `401`.
- **Rotate** the session token (new `token_hash`), bump `expires_at`, update the
  stored refresh token if Google rotated it, update `last_used_at`.
- Return `{ session_token, expiry, email, picture? }`.

`POST /oauth/signout`
- Bearer = session token. Revoke the row and **delete the stored Google refresh
  token** (Google tokens must not outlive the session). Best-effort from the app.

### Client auth switch

`authenticateClient` (`relay/auth.go:188-230`) becomes: `DEV_AUTH` branch (kept —
tests only) → **session-token lookup** (hash the bearer, indexed lookup, check
`expires_at`/`revoked_at`, map to `Identity{email, sub}`) → `401`. The
raw-Google-ID-token-as-client-bearer path is **removed**. Google verification now
lives only in `/oauth/exchange` and `/oauth/renew`. Admin routes keep their
existing id-token path (ops/curl surface, not the app).

### Session token model — opaque + SQLite, rotated on renew

Matches the relay's existing device-token pattern (`store.go:195-203`): opaque
random token, store `hex(SHA-256)` only, return raw once. No JWT signing key to
manage; instant revocation; and a server row is required anyway to hold the
refresh token.

New goose migration `0007_sessions.sql`, table `sessions`:

| column | notes |
|---|---|
| `token_hash` | `hex(SHA-256(raw))`, `UNIQUE` index — the lookup key |
| `google_sub` | identity |
| `email` | identity / display |
| `google_refresh_token_enc` | AES-256-GCM ciphertext (nonce-prefixed) |
| `created_at` | |
| `expires_at` | session-token validity (**1h**) |
| `last_used_at` | for idle expiry |
| `revoked_at` | nullable; set on sign-out |

Lifetime: the session **token** is valid 1h; the **row** persists across renews
until sign-out, refresh failure, or ~60-day idle (`last_used_at`). Multiple rows
per account are allowed (multiple devices); each sign-in gets its own Google
refresh token (`prompt=consent`).

### Refresh token encrypted at rest — AES-256-GCM

New env var `SESSION_ENC_KEY` (32 bytes, base64), delivered via the same systemd
`EnvironmentFile` as `GOOGLE_CLIENT_SECRET`. The brokered flow refuses to operate
if unset (fail-closed). Nothing recoverable is stored in the relay DB today; the
Google refresh token is the crown jewel, so a DB-only leak must not expose it.
Implementation: stdlib `crypto/aes` + `crypto/cipher` (GCM), random nonce per
record, ~30 lines. New store methods live alongside `accounts.go`/`settings.go`.

### Config additions
- `SESSION_ENC_KEY` (required for the brokered flow).
- Reuse existing `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` (Desktop client) for
  the exchange. No new client registration.

## macOS app design

### `GoogleOAuth.swift`
- Keep: PKCE (verifier/challenge/base64url), `authorizationURL` (still points at
  Google — the browser goes to Google), `LoopbackCodeReceiver`.
- Replace the Google `TokenClient` with a small **relay session client** that
  POSTs to `/oauth/exchange` and `/oauth/renew`. Drop `client_secret`, the Google
  `refresh(refreshToken:)`, and client-side id-token claim parsing/expiry math
  (`TokenResponse`, `IDTokenClaims`, `CachedIDToken`) — the relay now returns
  `{session_token, expiry, email, picture?}`.
- `Endpoints` stays injectable for tests (fake relay). Fields become
  `authorization` (Google) + `exchange` + `renew` (relay base).

### `RelayAccount.swift`
- Keychain `Stored` becomes `{ sessionToken, expiry, email, picture? }` (was
  refresh token). Same service/accessibility. The session token is short-lived +
  server-revocable — a net client-side improvement over storing a Google refresh
  token.
- `signIn()` → PKCE + loopback → `code` → POST `/oauth/exchange` → store session
  → publish `email`/`pictureURL`.
- `currentToken()` (was `currentIDToken()`): return the cached session token
  while `expiry` has > 60s left; else POST `/oauth/renew` with the stored token,
  store + return the rotated token. Keep the in-flight coalescing
  (`refreshTask`) and off-main Keychain hops.
- `signOut()`: best-effort POST `/oauth/signout`, then delete Keychain + clear
  state (existing machine-list clear + window-close logic unchanged).
- **Remove runtime credential lookups entirely:** delete `clientConfig()`,
  `ClientConfig`, `clientIDDefaultsKey`/`clientSecretDefaultsKey`, the
  `GHOSTTY_GOOGLE_CLIENT_ID/_SECRET` env + `GhosttyGoogleClient*` UserDefaults
  paths, **and the `GHOSTTY_RELAY_TOKEN` devToken fallback** (its only purpose —
  pre-`DEV_AUTH`-off bring-up — is gone; keeping it would re-introduce the exact
  runtime-credential fragility being removed).
- **Client id** now comes from `Bundle.main.infoDictionary["GhosttyGoogleClientID"]`
  (injectable for tests). `isConfigured` = client id present → always true in a
  shipped build.
- `resolveToken()` resolves **only** the session token (no devToken).

### Consumers (unchanged call semantics)
`RelayDirectoryClient`, `AppDelegate`, `BaseTerminalController`, `IPCServer`,
`RemoteActivityMonitor`, `MachineChooserView`, `Machine.swift`,
`TerminalController` call `resolveToken()`/`hasCredentials`/`isConfigured` — same
signatures, now backed by the session token. Update comments/error strings that
mention `GHOSTTY_RELAY_TOKEN`.

### ⌘⇧N fix
Because sign-in is always possible now (client id baked in), **⌘⇧N always
presents the chooser** (Local + machines + sign-in/out footer) — never a silent
local window. Drop the fragile 3-condition guard in
`AppDelegate.newRemoteWindow(_:)`.

## Build / release wiring

- `build.zig`: add option `-Dgoogle-client-id=<id>` (default empty). When empty,
  read a **git-ignored** local file for dev builds (e.g.
  `macos/google-client-id.txt`); add it to `.gitignore`.
- `src/build/GhosttyXcodebuild.zig`: pass `GHOSTTY_GOOGLE_CLIENT_ID=<id>` as an
  xcodebuild build setting (build + run steps), mirroring how `MARKETING_VERSION`
  is passed.
- `macos/Ghostty-Info.plist`: add `GhosttyGoogleClientID` =
  `$(GHOSTTY_GOOGLE_CLIENT_ID)` (the plist already uses `$(...)` build-setting
  substitution).
- Release workflows (`.github/workflows/release-tip.yml`, `release-tag.yml`):
  pass the id from a GitHub Actions secret (via the zig build option or the
  xcodebuild setting / PlistBuddy, matching how `GhosttyCommit` is set). No secret
  committed or in git history.

The client id is public (it appears in the browser authorize URL); managing it as
build config keeps it out of the repo and lets the client be rotated without a
code change. It is not a secret — the secret stays on the relay only.

## Testing

- **Relay** (`relay/oauth_exchange_test.go`, on the existing fake-issuer harness
  in `auth_oidc_test.go` / `enroll_test.go`): add a `tokenHandler` returning
  `{id_token, refresh_token, access_token}`; assert
  - successful exchange mints a session token and persists the refresh token
    (encrypted) + returns email;
  - `ALLOWED_EMAILS` enforcement (email not allowed → rejected, no session);
  - aud mismatch → rejected;
  - renew uses the stored refresh token → new (rotated) session token and
    re-checks the allowlist;
  - `/v1/client/*` accepts the minted session token and **rejects a raw Google
    id_token**;
  - signout revokes the row + removes the refresh token;
  - AES-GCM encrypt/decrypt round-trip.
- **Swift** (`macos/Tests/Remote/GoogleOAuthTests.swift` + the swiftc harness):
  keep the PKCE RFC vector + authorize-URL + base64url tests; replace the Google
  token-endpoint tests with a **fake relay** endpoint returning
  `{session_token, ...}`; Keychain e2e stores the session token.
- **Build/verify gate:** `zig build -Doptimize=Debug`, the Swift test target, and
  `cd relay && go test ./...` all green.

## Rollout / cutover (sole user; brief disruption acceptable)

1. Land code + tests on the branch.
2. Verify e2e against a **local relay** (real Desktop client id/secret provided
   locally, `DEV_AUTH=false`, temp SQLite, `SESSION_ENC_KEY` set) with the debug
   app: full browser sign-in → session token → list devices → renew → sign-out.
3. Deploy the new relay to the Azure VM: run migration, add `SESSION_ENC_KEY`,
   confirm `GOOGLE_CLIENT_ID/SECRET` + `ALLOWED_EMAILS` + `DEV_AUTH=false`,
   restart.
4. Build the app with the real client id; re-sign-in; verify the live flow.

**Secrets needed at verification time (from the password manager):** the Desktop
client **id** (dev-build local file + CI secret), the Desktop client **secret**
(local + prod relay env), and a generated `SESSION_ENC_KEY`. None committed.

## Docs

Update `docs/design/remote-relay-roadmap.md` to the brokered BFF model (secret
server-side only, relay session tokens, build-time client id, env/UserDefaults +
`GHOSTTY_RELAY_TOKEN` paths removed).

## Security summary

- Confidential `client_secret` lives only on the relay.
- Google id/refresh tokens never touch the client; refresh token encrypted at
  rest on the relay.
- Client holds only a short-lived (1h), server-revocable session token.
- Allowlist enforced at exchange **and** re-checked on every renew.
- No secret in the app binary or in git history.
- No runtime credential lookup remains on the client (`isConfigured` always true
  in a shipped build) — the ⌘⇧N silent-fallback bug cannot recur.
