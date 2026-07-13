-- +goose Up
-- M4: per-account quota overrides (plan §5 M4).
--
-- Shape decision: nullable override COLUMNS on `accounts` rather than a
-- separate account_quotas table. Quotas are strictly 1:1 with accounts, the
-- M2 admin surface reads/writes them alongside the account row, and
-- NULL-means-"use the configured default" falls out of the column type for
-- free — a separate table would buy nothing except a join and a second
-- upsert path to keep consistent.
--
-- Semantics (enforced in quotas.go):
--   NULL = use the env default (QUOTA_MAX_DEVICES / QUOTA_MAX_SESSIONS)
--   0    = unlimited for this account
--   >0   = hard cap for this account
--
-- NOTE: this is 0004; 0003 belongs to the concurrently-developed M2 branch
-- and is absent here by design. goose applies by version number and tolerates
-- the gap (0001, 0002, 0004 apply in order).
ALTER TABLE accounts ADD COLUMN max_devices INTEGER;
ALTER TABLE accounts ADD COLUMN max_sessions INTEGER;

-- +goose Down
ALTER TABLE accounts DROP COLUMN max_devices;
ALTER TABLE accounts DROP COLUMN max_sessions;
