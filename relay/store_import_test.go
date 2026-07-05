package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestLoadStoreImportsLegacyJSON proves the one-time devices.json -> SQLite
// importer: seed a legacy devices.json, LoadStore, then assert the devices are
// present, owner-scoped, and authenticate by their raw-token hash.
func TestLoadStoreImportsLegacyJSON(t *testing.T) {
	dir := t.TempDir()
	jsonPath := filepath.Join(dir, "devices.json")
	dbPath := filepath.Join(dir, "ghoztty-relay.db")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	// Two devices for two different owners. token_hash mirrors what the relay
	// would have stored: hex(SHA-256(raw token)). We compute a real hash so
	// AuthenticateToken (which hashes the presented raw token) can match.
	rawA := "raw-token-aaaa"
	rawB := "raw-token-bbbb"
	legacy := []*Device{
		{
			ID:         "id-a",
			Name:       "boxA",
			Hostname:   "boxA.local",
			OwnerEmail: "Alice@Example.com", // mixed case -> must be lowercased
			OwnerSub:   "sub-alice",
			TokenHash:  hashHex(rawA),
			CreatedAt:  time.Date(2025, 1, 2, 3, 4, 5, 0, time.UTC),
		},
		{
			ID:         "id-b",
			Name:       "boxB",
			OwnerEmail: "bob@example.com",
			TokenHash:  hashHex(rawB),
			CreatedAt:  time.Date(2025, 6, 7, 8, 9, 10, 0, time.UTC),
		},
	}
	data, err := json.MarshalIndent(legacy, "", "  ")
	if err != nil {
		t.Fatalf("marshal legacy: %v", err)
	}
	if err := os.WriteFile(jsonPath, data, 0o600); err != nil {
		t.Fatalf("write legacy json: %v", err)
	}

	store, err := LoadStore(dbPath, jsonPath, logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	defer store.Close()

	// The legacy JSON must be left in place as a backup.
	if _, err := os.Stat(jsonPath); err != nil {
		t.Fatalf("legacy devices.json should remain as backup: %v", err)
	}

	// Devices are present and owner-scoped (email lowercased on import).
	alice := store.ListByOwner("alice@example.com")
	if len(alice) != 1 || alice[0].ID != "id-a" {
		t.Fatalf("expected 1 device for alice, got %+v", alice)
	}
	if alice[0].Hostname != "boxA.local" || alice[0].OwnerSub != "sub-alice" {
		t.Fatalf("device fields not preserved: %+v", alice[0])
	}
	if !alice[0].CreatedAt.Equal(legacy[0].CreatedAt) {
		t.Fatalf("created_at not preserved: got %v want %v", alice[0].CreatedAt, legacy[0].CreatedAt)
	}
	if n := len(store.ListByOwner("bob@example.com")); n != 1 {
		t.Fatalf("expected 1 device for bob, got %d", n)
	}

	// The imported credentials authenticate.
	if d := store.AuthenticateToken(rawA); d == nil || d.ID != "id-a" {
		t.Fatalf("rawA should authenticate to id-a, got %+v", d)
	}
	if d := store.AuthenticateToken(rawB); d == nil || d.ID != "id-b" {
		t.Fatalf("rawB should authenticate to id-b, got %+v", d)
	}
	if d := store.AuthenticateToken("not-a-real-token"); d != nil {
		t.Fatalf("bogus token must not authenticate, got %+v", d)
	}
}

// TestLoadStoreImportIsIdempotent proves the importer runs only on an empty
// table: a second LoadStore over a populated DB must not re-import or error,
// even if devices.json still exists.
func TestLoadStoreImportIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	jsonPath := filepath.Join(dir, "devices.json")
	dbPath := filepath.Join(dir, "ghoztty-relay.db")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	legacy := []*Device{{
		ID:         "id-a",
		Name:       "boxA",
		OwnerEmail: "alice@example.com",
		TokenHash:  hashHex("tok"),
		CreatedAt:  time.Now().UTC(),
	}}
	data, _ := json.MarshalIndent(legacy, "", "  ")
	if err := os.WriteFile(jsonPath, data, 0o600); err != nil {
		t.Fatalf("write legacy json: %v", err)
	}

	// First load imports.
	s1, err := LoadStore(dbPath, jsonPath, logger)
	if err != nil {
		t.Fatalf("LoadStore #1: %v", err)
	}
	// Rename it so we can detect an errant re-import (which would restore boxA).
	if _, err := s1.RenameDevice("id-a", "alice@example.com", "renamed"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	s1.Close()

	// Second load must NOT re-import; the rename must persist.
	s2, err := LoadStore(dbPath, jsonPath, logger)
	if err != nil {
		t.Fatalf("LoadStore #2: %v", err)
	}
	defer s2.Close()

	devs := s2.ListByOwner("alice@example.com")
	if len(devs) != 1 {
		t.Fatalf("expected exactly 1 device after reload, got %d", len(devs))
	}
	if devs[0].Name != "renamed" {
		t.Fatalf("rename not persisted / importer clobbered it: %q", devs[0].Name)
	}
}

// TestLoadStoreNoLegacyFile proves a fresh install (no devices.json) yields an
// empty, working store rather than an error.
func TestLoadStoreNoLegacyFile(t *testing.T) {
	dir := t.TempDir()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	store, err := LoadStore(filepath.Join(dir, "ghoztty-relay.db"), filepath.Join(dir, "devices.json"), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	defer store.Close()

	if n := len(store.ListByOwner("anyone@example.com")); n != 0 {
		t.Fatalf("expected empty store, got %d devices", n)
	}
	// And it is a functioning store.
	dev, raw, err := store.CreateDevice("x@example.com", "box")
	if err != nil {
		t.Fatalf("CreateDevice: %v", err)
	}
	if d := store.AuthenticateToken(raw); d == nil || d.ID != dev.ID {
		t.Fatalf("created device should authenticate")
	}
}

// hashHex returns hex(SHA-256(raw)), matching the relay's stored token form.
func hashHex(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}
