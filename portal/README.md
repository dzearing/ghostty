# Ghoztty Relay — Admin Portal

React (Vite) SPA for the relay's `/v1/admin` REST API (M2). Dashboard,
sign-in attempts feed, account management (block/unblock/delete), and invite
codes. Dark-first UI, Recharts for the dashboard chart, React Query for data.

## Development

Run a relay locally, then the portal:

```bash
# 1. Relay on 127.0.0.1:8080 (dev auth, admin = the dev token's sub "dev")
cd relay
DEV_AUTH=true DEV_CLIENT_TOKEN=devtoken DEV_EMAIL=dev@example.com \
ADMIN_SUBS=dev INVITE_SIGNUP=true STATE_DIR=/tmp/relay-state \
go run .

# 2. Portal
cd portal
npm install
npm run dev            # http://localhost:5173
```

`vite dev` proxies `/v1/admin` to `http://127.0.0.1:8080`, so the SPA is
same-origin with the API in dev exactly as it is in prod — **no CORS anywhere,
and no relay changes needed**. Sign in via the "dev sign-in" toggle on the
sign-in screen and paste `devtoken`.

Checks:

```bash
npm run build      # tsc --noEmit + vite build
npm run lint       # eslint
npm test           # vitest (mocked fetch; no relay needed)
```

## Authentication

- **Google (production):** the sign-in screen renders a Google Identity
  Services button. The resulting ID token has `aud` = the configured **web
  client ID**, which the relay already accepts (`relay/auth.go` allowedAuds
  includes `GOOGLE_WEB_CLIENT_ID`), so the credential is sent as
  `Authorization: Bearer` on every call with no token exchange.
- **Client ID at runtime:** fetched from `/portal-config.json` (served next to
  the static assets), *not* baked in at build time — one artifact works in
  every environment and rotating the ID is a file edit, not a rebuild:

  ```json
  { "googleClientId": "<web-client-id>.apps.googleusercontent.com" }
  ```

- **Token custody:** the bearer token lives **in memory only** — never
  localStorage/sessionStorage. Persisted tokens are exfiltratable at leisure
  by any XSS on the origin; a memory-only token limits the blast radius to
  the live session. The cost is a re-prompt on refresh, which GIS
  `auto_select` usually reduces to a silent one-tap.
- **401** → token dropped, sign-in screen with a "session expired" note, and
  a GIS silent re-prompt is attempted.
- **403** → the "signed in, but not an admin" page showing the caller's email
  and `sub` (copyable), so a human can add it to the relay's `ADMIN_SUBS`.
- **Dev escape hatch:** the "dev sign-in" toggle accepts a pasted token — the
  relay's static `DEV_CLIENT_TOKEN` when it runs with `DEV_AUTH=true` (maps to
  sub `dev`; make it an admin with `ADMIN_SUBS=dev`), or any raw ID token.

## Production serving (Caddy)

`npm run build` emits static assets in `dist/`. Serve them on a dedicated
admin subdomain with Caddy fronting the relay (which stays on loopback
`127.0.0.1:8080`), e.g. in the existing Caddyfile:

```caddyfile
admin.relay.example.com {
    # Admin API → relay (same-origin, so no CORS anywhere).
    handle /v1/admin/* {
        reverse_proxy 127.0.0.1:8080
    }

    # SPA static assets + runtime config.
    handle {
        root * /srv/ghoztty-admin-portal
        try_files {path} /index.html   # client-side routing
        file_server
    }
}
```

Deploy steps (not automated here; M3 does NOT deploy):

1. `npm run build`
2. Copy `dist/` to the VM: `/srv/ghoztty-admin-portal`
3. Write `/srv/ghoztty-admin-portal/portal-config.json` with the
   `GOOGLE_WEB_CLIENT_ID` value (same client the relay is configured with).
4. Add the Caddy site block above; reload Caddy.
5. Ensure `ADMIN_SUBS` on the relay contains the Google `sub` of each admin.

Note: only `/v1/admin/*` is proxied on the admin host — the user/agent
surfaces stay on the main relay host. Authorization is enforced by the relay
itself (401/403), not by the proxy.

## Structure

```
src/
  api/        types + fetch client (error mapping) + React Query hooks
  auth/       GIS loader + auth state machine (in-memory token custody)
  components/ dialogs, badges, toasts, skeletons, empty/error states
  pages/      Dashboard, Attempts, Accounts, AccountDetail, Invites
  shell/      AppShell (sidebar/header), sign-in / not-admin gate pages
  styles/     tokens.css (design tokens, dark+light), base.css, app.css
  lib/        time & outcome presentation helpers, JWT payload peek
```

Routes are code-split; Recharts (the heaviest dependency) loads only with the
dashboard chunk.
