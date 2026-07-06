-- +goose Up
-- Runtime service settings: a small key/value table for flags an admin flips
-- LIVE from the portal (no env edit, no restart). Values are strings; each
-- consumer validates its own key.
--
-- First consumer: key 'signup_mode' = 'open' | 'invite' | 'closed' |
-- 'allowlist' — the sign-up policy (settings.go):
--   open      = anyone with a verified Google account gets an account on
--               first sign-in (no invite code)
--   invite    = new accounts require a valid invite code (M1 behavior)
--   closed    = no new sign-ups; existing accounts keep working. A refused
--               fresh identity is audited with the NEW signin_attempts
--               outcome value 'signup_closed' (accounts.go enum + the
--               metrics label list in metrics.go).
--   allowlist = the legacy ALLOWED_EMAILS env gate (pre-M1 behavior)
-- When the row is absent the mode is seeded from the environment:
-- SIGNUP_MODE, else INVITE_SIGNUP=true -> invite, else allowlist — so
-- existing deployments keep their exact behavior until the mode is changed.
CREATE TABLE settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at TIMESTAMP NOT NULL
);

-- +goose Down
DROP TABLE settings;
