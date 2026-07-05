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
	// _txlock=immediate makes every db.Begin() acquire the write lock up front
	// (BEGIN IMMEDIATE) instead of lazily on first write — so busy_timeout
	// governs the wait and a deferred read-then-write tx can never hit the
	// non-waiting SQLITE_BUSY_SNAPSHOT (517) it otherwise would under concurrent
	// writers (e.g. the invite consume race). Reads still run outside a tx and
	// are unaffected.
	dsn := "file:" + dbPath + "?_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)&_pragma=busy_timeout(5000)&_txlock=immediate"
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

// CreateDevice enrolls a new device owned by (ownerEmail, ownerSub). It
// generates a 32-byte high-entropy token, stores only its SHA-256 hash,
// persists the row, and returns the device plus the RAW token (shown to the
// caller once and never recoverable thereafter). ownerSub is always stamped so
// the row is sub-owned from birth (authz keys on sub); it is only ever empty
// under dev auth (Identity.Sub == "dev") or a test that passes "".
func (s *Store) CreateDevice(ownerEmail, ownerSub, name string) (*Device, string, error) {
	rawToken, hash, err := newDeviceToken()
	if err != nil {
		return nil, "", err
	}
	dev := &Device{
		ID:         uuid.NewString(),
		Name:       name,
		OwnerEmail: strings.ToLower(ownerEmail),
		OwnerSub:   ownerSub,
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
	// M4: the full logic lives in UpsertDeviceLimited (quotas.go); maxDevices 0
	// = no quota check, preserving this method's historical contract.
	return s.UpsertDeviceLimited(ownerEmail, ownerSub, name, 0)
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

// --- Ownership scoping: google_sub with an email fallback (plan §4.4) --------
//
// The authz key is the caller's stable Google `sub`. A device is the caller's
// when its owner_sub is non-empty AND equals the caller's sub. Devices enrolled
// before owner_sub existed (or via dev auth) have an empty owner_sub — for
// those the caller's lowercased email is the fallback key. The predicate below
// encodes exactly that: sub-match for sub-stamped rows, email-match for legacy
// rows. It never mixes the two (a row with a sub can only be reached by that
// sub), so two accounts sharing no sub can never see each other's devices.
//
// ownsClause is the shared WHERE fragment; ownsArgs supplies its (?,?) params.
const ownsClause = `((owner_sub != '' AND owner_sub = ?) OR (owner_sub = '' AND owner_email = ?))`

// ownsArgs returns the (sub, email) parameter pair for ownsClause. Email is
// lowercased to match how it is stored.
func ownsArgs(id Identity) (string, string) {
	return id.Sub, strings.ToLower(id.Email)
}

// ListByOwnerIdent returns all devices owned by the caller (sub-keyed, with the
// legacy email fallback), sorted by name. This is the sub-aware replacement for
// ListByOwner; the older email-only method is retained for the legacy importer
// test and internal callers that only have an email.
func (s *Store) ListByOwnerIdent(id Identity) []*Device {
	sub, email := ownsArgs(id)
	rows, err := s.db.Query(
		`SELECT `+deviceCols+` FROM devices WHERE `+ownsClause+` ORDER BY name ASC`,
		sub, email,
	)
	if err != nil {
		s.logger.Error("list by owner failed", "sub", sub, "err", err)
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
		s.logger.Error("list by owner iter failed", "sub", sub, "err", err)
		return nil
	}
	return out
}

// RenameDeviceByOwner is the sub-aware rename: it renames iff the device exists
// AND is owned by the caller (sub-match or legacy email fallback), in one
// owner-scoped UPDATE. Returns nil for "no such owned device" (callers must not
// distinguish not-found from not-yours).
func (s *Store) RenameDeviceByOwner(id string, owner Identity, newName string) (*Device, error) {
	sub, email := ownsArgs(owner)
	res, err := s.db.Exec(
		`UPDATE devices SET name = ? WHERE id = ? AND `+ownsClause,
		newName, id, sub, email,
	)
	if err != nil {
		return nil, fmt.Errorf("persist rename: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return nil, fmt.Errorf("persist rename: %w", err)
	}
	if n == 0 {
		return nil, nil
	}
	d := s.Get(id)
	if d == nil {
		return nil, nil // raced with a delete
	}
	return d, nil
}

// DeleteDeviceByOwner is the sub-aware delete: it removes the device iff it
// exists AND is owned by the caller (sub-match or legacy email fallback),
// revoking the token hash. Returns whether a device was deleted.
func (s *Store) DeleteDeviceByOwner(id string, owner Identity) (bool, error) {
	sub, email := ownsArgs(owner)
	res, err := s.db.Exec(
		`DELETE FROM devices WHERE id = ? AND `+ownsClause,
		id, sub, email,
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

// OwnedBy reports whether the device is owned by the caller under the same
// sub-with-email-fallback rule. Used by the connect ownership gate in place of
// the old dev.OwnerEmail != email check.
func (d *Device) OwnedBy(id Identity) bool {
	if d.OwnerSub != "" {
		return d.OwnerSub == id.Sub
	}
	return d.OwnerEmail == strings.ToLower(id.Email)
}

// DistinctOwners returns the distinct (owner_sub, owner_email) pairs across all
// devices — the source of truth for migrating existing owners into accounts
// (plan §4.1), read from SQLite rather than devices.json.
func (s *Store) DistinctOwners() ([]struct{ Sub, Email string }, error) {
	rows, err := s.db.Query(`SELECT DISTINCT owner_sub, owner_email FROM devices`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []struct{ Sub, Email string }
	for rows.Next() {
		var o struct{ Sub, Email string }
		if err := rows.Scan(&o.Sub, &o.Email); err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// HasLegacyDeviceForEmail reports whether any device with an EMPTY owner_sub is
// owned by ownerEmail — i.e. a device enrolled before sub existed / via dev
// auth. This is the "existing owner from before accounts" signal the sign-in
// gate uses to migrate that owner without an invite code (plan §4.1).
func (s *Store) HasLegacyDeviceForEmail(ownerEmail string) bool {
	ownerEmail = strings.ToLower(ownerEmail)
	var n int
	err := s.db.QueryRow(
		`SELECT COUNT(*) FROM devices WHERE owner_sub = '' AND owner_email = ?`, ownerEmail,
	).Scan(&n)
	if err != nil {
		s.logger.Error("legacy device check failed", "err", err)
		return false
	}
	return n > 0
}

// BindLegacyDevicesToSub stamps ownerSub onto every legacy (empty-sub) device
// owned by ownerEmail, so their ownership becomes sub-keyed going forward. Run
// once, when a legacy owner first signs in and their account is created.
func (s *Store) BindLegacyDevicesToSub(ownerEmail, ownerSub string) error {
	if ownerSub == "" {
		return fmt.Errorf("bind legacy devices: empty sub")
	}
	_, err := s.db.Exec(
		`UPDATE devices SET owner_sub = ? WHERE owner_sub = '' AND owner_email = ?`,
		ownerSub, strings.ToLower(ownerEmail),
	)
	if err != nil {
		return fmt.Errorf("bind legacy devices: %w", err)
	}
	return nil
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
