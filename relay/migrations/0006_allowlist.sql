-- +goose Up
-- DB-backed sign-in allowlist, manageable LIVE from the admin portal
-- (allowlist.go / admin_allowlist.go). The EFFECTIVE allowlist consulted in
-- `allowlist` signup mode is the UNION of:
--
--   - these rows (source "db": added/removed from the portal, no restart), and
--   - the ALLOWED_EMAILS environment variable (source "env").
--
-- ALLOWED_EMAILS is demoted to a bootstrap/recovery allowance — the same
-- pattern as ADMIN_SUBS and the signup_mode env seed: it is ALWAYS honored
-- (so a wedged DB or an accidental portal deletion can never lock out the
-- operator), it is NEVER imported into this table, and the portal shows its
-- entries distinctly labeled and immutable. Emails are stored lowercased;
-- membership checks compare lowercased.
CREATE TABLE allowed_emails (
    email      TEXT PRIMARY KEY,
    note       TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMP NOT NULL
);

-- +goose Down
DROP TABLE allowed_emails;
