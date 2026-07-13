-- +goose Up
-- M2: admin surface. Adds the admin-mutation audit table (plan §3 admin_audit)
-- and an is_admin flag on accounts so admins can be managed in the DB without
-- env changes (ADMIN_SUBS stays as the bootstrap/recovery path; the effective
-- rule is: admin = sub ∈ ADMIN_SUBS OR accounts.is_admin = 1).
--
-- NOTE ON THE ADMIN IDENTITY COLUMN: the plan §3 sketch calls this column
-- admin_account_id, but a bootstrap admin (authorized purely via ADMIN_SUBS)
-- may have NO accounts row at all, so an account id cannot be the required
-- key. The stable Google `sub` always exists for a verified admin ("dev"
-- under DEV_AUTH), so the audit row keys on admin_sub; admin_email rides
-- along for human readability (emails can change, the sub cannot).
--
-- NOTE ON devices.account_id: still deferred (see 0002 header). Live devices
-- have no bound subs until the M1 cutover happens; ownership stays on
-- owner_sub with the owner_email fallback.
CREATE TABLE admin_audit (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts          TIMESTAMP NOT NULL,
    admin_sub   TEXT NOT NULL,             -- stable OIDC sub of the acting admin
    admin_email TEXT NOT NULL DEFAULT '',  -- display/contact at time of action
    action      TEXT NOT NULL,             -- account.block | account.unblock | account.delete | invite.create | invite.revoke
    target      TEXT NOT NULL DEFAULT '',  -- account id / invite code acted on
    detail      TEXT NOT NULL DEFAULT ''   -- small JSON blob with action specifics
);

-- The audit feed lists mutations newest-first; index ts for that scan.
CREATE INDEX idx_admin_audit_ts ON admin_audit (ts);

-- Managed-in-DB admin flag. INTEGER 0/1 (SQLite has no BOOLEAN). Bootstrap
-- admins from ADMIN_SUBS bypass this; the flag exists so admin-ness can later
-- be granted/revoked at runtime without touching the environment.
ALTER TABLE accounts ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0;

-- +goose Down
-- SQLite supports DROP COLUMN since 3.35 (2021); modernc.org/sqlite v1.53
-- bundles a far newer engine, and the Up->Down->Up round-trip is proven by
-- TestMigration0003RoundTrip. is_admin is droppable (no index/constraint
-- references it), so no table rebuild is needed.
ALTER TABLE accounts DROP COLUMN is_admin;
DROP INDEX idx_admin_audit_ts;
DROP TABLE admin_audit;
