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
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	OwnerEmail string    `json:"owner_email"`
	TokenHash  string    `json:"token_hash"` // hex(SHA-256(raw token))
	CreatedAt  time.Time `json:"created_at"`
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

// CreateDevice enrolls a new device owned by ownerEmail. It generates a
// 32-byte high-entropy token, stores only its SHA-256 hash, persists the
// directory, and returns the device plus the RAW token (shown to the caller
// once and never recoverable thereafter).
func (s *Store) CreateDevice(ownerEmail, name string) (*Device, string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return nil, "", fmt.Errorf("generate token: %w", err)
	}
	rawToken := base64.RawURLEncoding.EncodeToString(buf)

	sum := sha256.Sum256([]byte(rawToken))
	dev := &Device{
		ID:         uuid.NewString(),
		Name:       name,
		OwnerEmail: strings.ToLower(ownerEmail),
		TokenHash:  hex.EncodeToString(sum[:]),
		CreatedAt:  time.Now().UTC(),
	}

	s.mu.Lock()
	s.devices[dev.ID] = dev
	err := s.save()
	s.mu.Unlock()
	if err != nil {
		return nil, "", fmt.Errorf("persist device: %w", err)
	}

	return dev, rawToken, nil
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
