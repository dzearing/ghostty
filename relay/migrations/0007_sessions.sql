-- +goose Up
-- Brokered-OAuth relay sessions (BFF). One row per active client session.
-- The raw session token is never stored; only hex(SHA-256(raw token)), exactly
-- like device tokens. The Google refresh token is stored AES-256-GCM encrypted
-- (crypto.go) — the one recoverable secret the relay holds.
CREATE TABLE sessions (
    token_hash        TEXT PRIMARY KEY,      -- hex(SHA-256(raw session token))
    google_sub        TEXT NOT NULL,
    email             TEXT NOT NULL,
    refresh_enc       BLOB NOT NULL,         -- encrypted Google refresh token
    created_at        TIMESTAMP NOT NULL,
    expires_at        TIMESTAMP NOT NULL,    -- session-token validity (1h)
    last_used_at      TIMESTAMP NOT NULL,
    revoked_at        TIMESTAMP              -- NULL = active
);

CREATE INDEX idx_sessions_sub ON sessions (google_sub);

-- +goose Down
DROP TABLE sessions;
