package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Device is an enrolled remote machine (an agent). The raw device token is
// NEVER stored; only its SHA-256 hash (hex) is persisted. The raw token is
// returned exactly once, at enrollment.
type Device struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
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

// Store is the concurrency-safe, file-backed device directory.
type Store struct {
	mu      sync.RWMutex
	path    string
	devices map[string]*Device
	logger  *slog.Logger
}

// LoadStore loads the persisted devices from path. A missing file is not an
// error (fresh install); it yields an empty store.
func LoadStore(path string, logger *slog.Logger) (*Store, error) {
	s := &Store{
		path:    path,
		devices: make(map[string]*Device),
		logger:  logger,
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return s, nil
		}
		return nil, fmt.Errorf("read devices file: %w", err)
	}

	var list []*Device
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, fmt.Errorf("parse devices file: %w", err)
	}
	for _, d := range list {
		s.devices[d.ID] = d
	}
	logger.Info("loaded device directory", "count", len(s.devices), "path", path)
	return s, nil
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

// CreateDevice enrolls a new device owned by ownerEmail. It generates a
// 32-byte high-entropy token, stores only its SHA-256 hash, persists the
// directory, and returns the device plus the RAW token (shown to the caller
// once and never recoverable thereafter).
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

	s.mu.Lock()
	s.devices[dev.ID] = dev
	err = s.save()
	s.mu.Unlock()
	if err != nil {
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
// Returns the device plus the RAW token, shown to the caller once.
func (s *Store) UpsertDevice(ownerEmail, ownerSub, name string) (*Device, string, error) {
	rawToken, hash, err := newDeviceToken()
	if err != nil {
		return nil, "", err
	}
	ownerEmail = strings.ToLower(ownerEmail)

	s.mu.Lock()
	defer s.mu.Unlock()

	var existing *Device
	for _, d := range s.devices {
		if d.OwnerEmail != ownerEmail || d.Name != name {
			continue
		}
		if existing == nil ||
			d.CreatedAt.Before(existing.CreatedAt) ||
			(d.CreatedAt.Equal(existing.CreatedAt) && d.ID < existing.ID) {
			existing = d
		}
	}

	if existing != nil {
		oldHash, oldSub := existing.TokenHash, existing.OwnerSub
		existing.TokenHash = hash
		if ownerSub != "" {
			existing.OwnerSub = ownerSub
		}
		if err := s.save(); err != nil {
			// Keep memory consistent with disk on persist failure.
			existing.TokenHash, existing.OwnerSub = oldHash, oldSub
			return nil, "", fmt.Errorf("persist upsert: %w", err)
		}
		cp := *existing
		return &cp, rawToken, nil
	}

	dev := &Device{
		ID:         uuid.NewString(),
		Name:       name,
		OwnerEmail: ownerEmail,
		OwnerSub:   ownerSub,
		TokenHash:  hash,
		CreatedAt:  time.Now().UTC(),
	}
	s.devices[dev.ID] = dev
	if err := s.save(); err != nil {
		delete(s.devices, dev.ID)
		return nil, "", fmt.Errorf("persist device: %w", err)
	}
	cp := *dev
	return &cp, rawToken, nil
}

// Get returns the device with the given id, or nil.
func (s *Store) Get(id string) *Device {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.devices[id]
}

// ListByOwner returns all devices owned by ownerEmail, sorted by name.
func (s *Store) ListByOwner(ownerEmail string) []*Device {
	ownerEmail = strings.ToLower(ownerEmail)
	s.mu.RLock()
	defer s.mu.RUnlock()

	var out []*Device
	for _, d := range s.devices {
		if d.OwnerEmail == ownerEmail {
			out = append(out, d)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// RenameDevice updates the display name of the device iff it exists AND is
// owned by ownerEmail. The ownership check and the mutation happen under one
// lock so they cannot race with a concurrent delete. Returns a copy of the
// updated device, or nil if there is no such owned device (callers must not
// distinguish "not found" from "not yours").
func (s *Store) RenameDevice(id, ownerEmail, newName string) (*Device, error) {
	ownerEmail = strings.ToLower(ownerEmail)
	s.mu.Lock()
	defer s.mu.Unlock()

	d := s.devices[id]
	if d == nil || d.OwnerEmail != ownerEmail {
		return nil, nil
	}

	oldName := d.Name
	d.Name = newName
	if err := s.save(); err != nil {
		d.Name = oldName // keep memory consistent with disk on persist failure
		return nil, fmt.Errorf("persist rename: %w", err)
	}

	cp := *d
	return &cp, nil
}

// DeleteDevice removes the device iff it exists AND is owned by ownerEmail.
// Removal revokes the device credential: the token hash is gone, so the raw
// token can never authenticate again (AuthenticateToken finds no match).
// Returns whether a device was deleted.
func (s *Store) DeleteDevice(id, ownerEmail string) (bool, error) {
	ownerEmail = strings.ToLower(ownerEmail)
	s.mu.Lock()
	defer s.mu.Unlock()

	d := s.devices[id]
	if d == nil || d.OwnerEmail != ownerEmail {
		return false, nil
	}

	delete(s.devices, id)
	if err := s.save(); err != nil {
		s.devices[id] = d // keep memory consistent with disk on persist failure
		return false, fmt.Errorf("persist delete: %w", err)
	}
	return true, nil
}

// AuthenticateToken returns the device whose stored token hash matches the
// presented raw token, or nil. The comparison is constant-time to avoid
// leaking which (or whether a) device matched via timing.
func (s *Store) AuthenticateToken(rawToken string) *Device {
	if rawToken == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(rawToken))

	s.mu.RLock()
	defer s.mu.RUnlock()

	var match *Device
	for _, d := range s.devices {
		stored, err := hex.DecodeString(d.TokenHash)
		if err != nil {
			continue
		}
		// ConstantTimeCompare returns 1 on match. We keep scanning even after a
		// match so total work does not depend on match position.
		if subtle.ConstantTimeCompare(sum[:], stored) == 1 {
			match = d
		}
	}
	return match
}

// save writes the directory to disk atomically. Caller must hold s.mu.
func (s *Store) save() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}

	list := make([]*Device, 0, len(s.devices))
	for _, d := range s.devices {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })

	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}

	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
