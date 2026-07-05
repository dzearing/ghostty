-- +goose Up
-- M1: invite-code accounts. Adds the tenancy tables (accounts, invite_codes,
-- signin_attempts) that govern the closed-signup sign-in path. The Postgres
-- sketch in docs/design/multi-tenant-launch-plan.md §3 is adapted to SQLite:
-- uuids and timestamps are TEXT/TIMESTAMP (as 0001_devices.sql does), counts
-- are INTEGER.
--
-- NOTE ON devices.account_id: the plan (§5) makes a physical FK on `devices`
-- OPTIONAL for M1. We DEFER it to M2. SQLite cannot add a column with a
-- non-constant default and backfilling a NOT NULL FK across legacy rows (some
-- of which have no google_sub yet) is awkward and error-prone. Ownership stays
-- keyed on devices.owner_sub (with an owner_email fallback for legacy rows) —
-- the accounts table is joined by google_sub when needed. M2 can add the
-- physical account_id column once every live device has a bound sub.

-- accounts: one row per signed-up user, keyed on the stable Google `sub`
-- (the authz anchor). `email` is the current contact/display address and may
-- change; `google_sub` never does. A UNIQUE index on google_sub is implied by
-- the UNIQUE constraint and serves the sign-in lookup.
CREATE TABLE accounts (
    id              TEXT PRIMARY KEY,               -- uuid
    google_sub      TEXT NOT NULL UNIQUE,           -- stable OIDC subject; authz key
    email           TEXT NOT NULL,                  -- current email (lowercased)
    status          TEXT NOT NULL DEFAULT 'active', -- active | blocked
    invited_by_code TEXT,                           -- code consumed at signup (nullable; migrated owners have none)
    created_at      TIMESTAMP NOT NULL,
    blocked_at      TIMESTAMP,                      -- nullable
    blocked_reason  TEXT                            -- nullable
);

-- invite_codes: human-typable signup codes. `max_uses` NULL = unlimited;
-- `uses` is incremented atomically on consume. `expires_at`/`revoked_at` NULL
-- mean never-expires / not-revoked. `created_by` (admin account id) is
-- populated by the M2 admin API; NULL for test/bootstrap-seeded codes.
CREATE TABLE invite_codes (
    code       TEXT PRIMARY KEY,
    created_by TEXT,                        -- admin account id (M2); nullable now
    max_uses   INTEGER,                     -- NULL = unlimited
    uses       INTEGER NOT NULL DEFAULT 0,
    expires_at TIMESTAMP,                   -- NULL = never expires
    revoked_at TIMESTAMP,                   -- NULL = not revoked
    note       TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMP NOT NULL
);

-- signin_attempts: an append-only audit of every sign-in decision made on the
-- invite path (recorded when INVITE_SIGNUP is ON). Feeds the M2 admin sign-in
-- feed. `outcome` is one of the documented enum values; `account_id` is set
-- when the attempt resolved to (or created) an account.
CREATE TABLE signin_attempts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         TIMESTAMP NOT NULL,
    email      TEXT NOT NULL DEFAULT '',
    google_sub TEXT NOT NULL DEFAULT '',
    ip         TEXT NOT NULL DEFAULT '',
    outcome    TEXT NOT NULL,   -- allowed | blocked | no_account | bad_invite | expired_invite | revoked_invite | exhausted_invite | not_verified
    account_id TEXT             -- nullable
);

-- The admin feed lists attempts newest-first; index ts for that scan.
CREATE INDEX idx_signin_attempts_ts ON signin_attempts (ts);

-- +goose Down
DROP INDEX idx_signin_attempts_ts;
DROP TABLE signin_attempts;
DROP TABLE invite_codes;
DROP TABLE accounts;
