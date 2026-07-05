package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dzearing/ghoztty-relay/migrations"
	"github.com/google/uuid"
	"github.com/pressly/goose/v3"

	_ "modernc.org/sqlite" // pure-Go SQLite driver (CGO_ENABLED=0 safe)
)

// Device is an enrolled remote machine (an agent). The raw device token is
// NEVER stored; only its SHA-256 hash (hex) is persisted. The raw token is
// returned exactly once, at enrollment.
type Device struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Hostname is the machine's OS-reported hostname, distinct from the
	// user-facing display Name: rename changes Name only, never Hostname.
	// Sources: seeded from the enrolled machine name by device-code
	// self-enrollment at creation, then kept fresh by the agent's
	// X-Ghoztty-Hostname header on each control connect. Empty on devices
	// that predate this field (or enrolled via the manual client POST) whose
	// agent has not yet connected with the header — omitempty keeps old
	// devices.json files valid.
	Hostname   string `json:"hostname,omitempty"`
	OwnerEmail string `json:"owner_email"`
	// OwnerSub is the owner's stable OIDC subject id (Google `sub`), recorded
	// by device-code self-enrollment. Empty on devices enrolled before this
	// field existed or via dev auth — email remains the ownership key, sub is
	// the forward-looking account anchor (roadmap §2.1). omitempty keeps old
	// devices.json files valid.
	OwnerSub  string    `json:"owner_sub,omitempty"`
	TokenHash string    `json:"token_hash"` // hex(SHA-256(raw token))
	CreatedAt time.Time `json:"created_at"`
}

// Store is the concurrency-safe, SQLite-backed device directory. It replaces
// the former flat-file (devices.json) implementation behind the identical
// method set; concurrency is delegated to SQLite itself (WAL mode), so no
// in-process mutex is needed.
type Store struct {
	db     *sql.DB
	logger *slog.Logger
}

// LoadStore opens (creating if absent) the SQLite database at dbPath in WAL
// mode, applies embedded goose migrations, and — on a first, empty boot where a
// legacy devices.json still exists at legacyJSONPath — imports those rows once.
// A missing database file is not an error (fresh install); a missing legacy
// JSON file is likewise fine (nothing to import).
func LoadStore(dbPath, legacyJSONPath string, logger *slog.Logger) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o700); err != nil {
		return nil, fmt.Errorf("create state dir: %w", err)
	}

	// WAL for concurrent readers + a writer; foreign_keys on for future FKs;
	// busy_timeout so brief writer contention retries rather than erroring.
	dsn := "file:" + dbPath + "?_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)&_pragma=busy_timeout(5000)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}

	// modernc.org/sqlite is safe for concurrent use, but a single writer + WAL
	// is the intended model; leaving the pool at defaults is fine.
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}

	if err := runMigrations(db); err != nil {
		db.Close()
		return nil, fmt.Errorf("run migrations: %w", err)
	}

	s := &Store{db: db, logger: logger}

	if err := s.importLegacyJSON(legacyJSONPath); err != nil {
		db.Close()
		return nil, fmt.Errorf("import legacy devices: %w", err)
	}

	count, err := s.count()
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("count devices: %w", err)
	}
	logger.Info("loaded device directory", "count", count, "db", dbPath)
	return s, nil
}

// runMigrations applies the embedded goose migrations to db.
func runMigrations(db *sql.DB) error {
	goose.SetBaseFS(migrations.FS)
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("sqlite3"); err != nil {
		return err
	}
	return goose.Up(db, ".")
}

// count returns the number of device rows.
func (s *Store) count() (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM devices`).Scan(&n)
	return n, err
}

// importLegacyJSON performs the one-time devices.json -> SQLite import. It is
// a no-op if the table already has rows (idempotent) or the JSON file is
// absent. The JSON file is left in place as a backup.
func (s *Store) importLegacyJSON(legacyJSONPath string) error {
	if legacyJSONPath == "" {
		return nil
	}

	n, err := s.count()
	if err != nil {
		return err
	}
	if n > 0 {
		return nil // already migrated / not empty — skip
	}

	data, err := os.ReadFile(legacyJSONPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // fresh install, nothing to import
		}
		return fmt.Errorf("read legacy devices file: %w", err)
	}

	var list []*Device
	if err := json.Unmarshal(data, &list); err != nil {
		return fmt.Errorf("parse legacy devices file: %w", err)
	}
	if len(list) == 0 {
		return nil
	}

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	for _, d := range list {
		if _, err := tx.Exec(
			`INSERT INTO devices (id, name, hostname, owner_email, owner_sub, token_hash, created_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?)`,
			d.ID, d.Name, d.Hostname, strings.ToLower(d.OwnerEmail), d.OwnerSub, d.TokenHash, d.CreatedAt.UTC(),
		); err != nil {
			return fmt.Errorf("insert imported device %s: %w", d.ID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}

	s.logger.Info("imported legacy devices.json into sqlite",
		"count", len(list), "src", legacyJSONPath)
	return nil
}

// Close releases the underlying database handle.
func (s *Store) Close() error {
	if s.db == nil {
		return nil
	}
	return s.db.Close()
}

// newDeviceToken generates a 32-byte high-entropy raw device token and its
// hex-encoded SHA-256 hash (the only form the relay ever stores).
func newDeviceToken() (raw, hashHex string, err error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", "", fmt.Errorf("generate token: %w", err)
	}
	raw = base64.RawURLEncoding.EncodeToString(buf)
	sum := sha256.Sum256([]byte(raw))
	return raw, hex.EncodeToString(sum[:]), nil
}

// scanDevice reads one Device row from a *sql.Row or *sql.Rows.
func scanDevice(sc interface{ Scan(...any) error }) (*Device, error) {
	var d Device
	var created time.Time
	if err := sc.Scan(&d.ID, &d.Name, &d.Hostname, &d.OwnerEmail, &d.OwnerSub, &d.TokenHash, &created); err != nil {
		return nil, err
	}
	d.CreatedAt = created.UTC()
	return &d, nil
}

const deviceCols = `id, name, hostname, owner_email, owner_sub, token_hash, created_at`

// CreateDevice enrolls a new device owned by ownerEmail. It generates a
// 32-byte high-entropy token, stores only its SHA-256 hash, persists the row,
// and returns the device plus the RAW token (shown to the caller once and
// never recoverable thereafter).
func (s *Store) CreateDevice(ownerEmail, name string) (*Device, string, error) {
	rawToken, hash, err := newDeviceToken()
	if err != nil {
		return nil, "", err
	}
	dev := &Device{
		ID:         uuid.NewString(),
		Name:       name,
		OwnerEmail: strings.ToLower(ownerEmail),
		TokenHash:  hash,
		CreatedAt:  time.Now().UTC(),
	}

	if _, err := s.db.Exec(
		`INSERT INTO devices (`+deviceCols+`) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		dev.ID, dev.Name, dev.Hostname, dev.OwnerEmail, dev.OwnerSub, dev.TokenHash, dev.CreatedAt,
	); err != nil {
		return nil, "", fmt.Errorf("persist device: %w", err)
	}

	return dev, rawToken, nil
}

// UpsertDevice is the idempotent device-code self-enroll primitive. If a
// device with the same (owner, name) already exists it keeps its identity
// (same ID, same CreatedAt — chooser entries, session manifests, and rename
// history stay attached) and ROTATES its credential: the new token replaces
// the old hash, so the previous token is revoked at that instant. Otherwise a
// new device is created. Exactly one credential is ever valid per device —
// the schema stores a single TokenHash, and re-running the installer is the
// recovery path for a lost token, which only works if the fresh token wins.
//
// If duplicate (owner, name) rows exist (possible via repeated manual POSTs),
// the oldest one deterministically wins; the others are left untouched.
// ownerSub, when non-empty, is recorded on the device (backfilling devices
// enrolled before OwnerSub existed).
//
// Returns the device plus the RAW token, shown to the caller once. The
// read-modify-write is done in a single transaction so it cannot race a
// concurrent mutation.
func (s *Store) UpsertDevice(ownerEmail, ownerSub, name string) (*Device, string, error) {
	rawToken, hash, err := newDeviceToken()
	if err != nil {
		return nil, "", err
	}
	ownerEmail = strings.ToLower(ownerEmail)

	tx, err := s.db.Begin()
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback()

	// Oldest (owner, name) row wins deterministically; ties broken by id.
	existing, err := scanDevice(tx.QueryRow(
		`SELECT `+deviceCols+` FROM devices
		 WHERE owner_email = ? AND name = ?
		 ORDER BY created_at ASC, id ASC
		 LIMIT 1`,
		ownerEmail, name,
	))
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, "", fmt.Errorf("lookup upsert target: %w", err)
	}

	if existing != nil {
		existing.TokenHash = hash
		if ownerSub != "" {
			existing.OwnerSub = ownerSub
		}
		if _, err := tx.Exec(
			`UPDATE devices SET token_hash = ?, owner_sub = ? WHERE id = ?`,
			existing.TokenHash, existing.OwnerSub, existing.ID,
		); err != nil {
			return nil, "", fmt.Errorf("persist upsert: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return nil, "", fmt.Errorf("persist upsert: %w", err)
		}
		return existing, rawToken, nil
	}

	dev := &Device{
		ID:   uuid.NewString(),
		Name: name,
		// Device-code enrollment names the device after the machine's
		// hostname, so at creation the two coincide. They diverge when the
		// owner renames the device (rename never touches Hostname) and the
		// hostname is thereafter refreshed by the agent's control connects.
		Hostname:   name,
		OwnerEmail: ownerEmail,
		OwnerSub:   ownerSub,
		TokenHash:  hash,
		CreatedAt:  time.Now().UTC(),
	}
	if _, err := tx.Exec(
		`INSERT INTO devices (`+deviceCols+`) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		dev.ID, dev.Name, dev.Hostname, dev.OwnerEmail, dev.OwnerSub, dev.TokenHash, dev.CreatedAt,
	); err != nil {
		return nil, "", fmt.Errorf("persist device: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, "", fmt.Errorf("persist device: %w", err)
	}
	cp := *dev
	return &cp, rawToken, nil
}

// SetHostname records the device's OS-reported hostname (from the agent's
// X-Ghoztty-Hostname control-connect header). A no-op when the device is
// unknown or the hostname is unchanged; persists otherwise. Display Name is
// never touched — hostname and name are independent. The check-then-update is
// transactional so it cannot race a concurrent delete/rename.
func (s *Store) SetHostname(id, hostname string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var current string
	err = tx.QueryRow(`SELECT hostname FROM devices WHERE id = ?`, id).Scan(&current)
	if errors.Is(err, sql.ErrNoRows) {
		return nil // unknown device — no-op
	}
	if err != nil {
		return fmt.Errorf("lookup hostname: %w", err)
	}
	if current == hostname {
		return nil // unchanged — no-op
	}

	if _, err := tx.Exec(`UPDATE devices SET hostname = ? WHERE id = ?`, hostname, id); err != nil {
		return fmt.Errorf("persist hostname: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("persist hostname: %w", err)
	}
	return nil
}

// Get returns the device with the given id, or nil.
func (s *Store) Get(id string) *Device {
	d, err := scanDevice(s.db.QueryRow(
		`SELECT `+deviceCols+` FROM devices WHERE id = ?`, id,
	))
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			s.logger.Error("get device failed", "id", id, "err", err)
		}
		return nil
	}
	return d
}

// ListByOwner returns all devices owned by ownerEmail, sorted by name.
func (s *Store) ListByOwner(ownerEmail string) []*Device {
	ownerEmail = strings.ToLower(ownerEmail)
	rows, err := s.db.Query(
		`SELECT `+deviceCols+` FROM devices WHERE owner_email = ? ORDER BY name ASC`,
		ownerEmail,
	)
	if err != nil {
		s.logger.Error("list by owner failed", "owner", ownerEmail, "err", err)
		return nil
	}
	defer rows.Close()

	var out []*Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			s.logger.Error("scan device failed", "err", err)
			return nil
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		s.logger.Error("list by owner iter failed", "owner", ownerEmail, "err", err)
		return nil
	}
	return out
}

// RenameDevice updates the display name of the device iff it exists AND is
// owned by ownerEmail. The ownership check and the mutation happen in one
// statement (owner-scoped UPDATE) so they cannot race with a concurrent
// delete. Returns a copy of the updated device, or nil if there is no such
// owned device (callers must not distinguish "not found" from "not yours").
func (s *Store) RenameDevice(id, ownerEmail, newName string) (*Device, error) {
	ownerEmail = strings.ToLower(ownerEmail)

	res, err := s.db.Exec(
		`UPDATE devices SET name = ? WHERE id = ? AND owner_email = ?`,
		newName, id, ownerEmail,
	)
	if err != nil {
		return nil, fmt.Errorf("persist rename: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return nil, fmt.Errorf("persist rename: %w", err)
	}
	if n == 0 {
		return nil, nil // no such owned device
	}

	d := s.Get(id)
	if d == nil {
		// Raced with a delete after the update; caller treats nil as "gone".
		return nil, nil
	}
	return d, nil
}

// DeleteDevice removes the device iff it exists AND is owned by ownerEmail.
// Removal revokes the device credential: the token hash is gone, so the raw
// token can never authenticate again (AuthenticateToken finds no match).
// Returns whether a device was deleted.
func (s *Store) DeleteDevice(id, ownerEmail string) (bool, error) {
	ownerEmail = strings.ToLower(ownerEmail)

	res, err := s.db.Exec(
		`DELETE FROM devices WHERE id = ? AND owner_email = ?`,
		id, ownerEmail,
	)
	if err != nil {
		return false, fmt.Errorf("persist delete: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("persist delete: %w", err)
	}
	return n > 0, nil
}

// AuthenticateToken returns the device whose stored token hash matches the
// presented raw token, or nil. The raw token is hashed with SHA-256 and looked
// up by its digest via the UNIQUE token_hash index — a direct equality match
// on the digest, which does not leak timing about the raw token (the digest is
// derived deterministically before the lookup).
func (s *Store) AuthenticateToken(rawToken string) *Device {
	if rawToken == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(rawToken))
	hashHex := hex.EncodeToString(sum[:])

	d, err := scanDevice(s.db.QueryRow(
		`SELECT `+deviceCols+` FROM devices WHERE token_hash = ?`, hashHex,
	))
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			s.logger.Error("authenticate token failed", "err", err)
		}
		return nil
	}
	return d
}
