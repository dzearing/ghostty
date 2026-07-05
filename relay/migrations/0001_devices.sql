-- +goose Up
-- Devices table mirrors the legacy devices.json Device struct exactly.
-- The raw device token is never stored; only hex(SHA-256(raw token)).
CREATE TABLE devices (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    hostname    TEXT NOT NULL DEFAULT '',
    owner_email TEXT NOT NULL,
    owner_sub   TEXT NOT NULL DEFAULT '',
    token_hash  TEXT NOT NULL,
    created_at  TIMESTAMP NOT NULL
);

-- Owner-scoped listing (ListByOwner) is the hot read path.
CREATE INDEX idx_devices_owner_email ON devices (owner_email);

-- Token authentication is a direct indexed equality lookup on the SHA-256
-- digest; the digest is unique per credential, so a UNIQUE index both speeds
-- AuthenticateToken and guards against duplicate hashes.
CREATE UNIQUE INDEX idx_devices_token_hash ON devices (token_hash);

-- +goose Down
DROP TABLE devices;
