package main

import (
	"io"
	"log/slog"
	"testing"
	"time"
)

func newSessionTestStore(t *testing.T) *Store {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	s, err := LoadStore(t.TempDir()+"/db.sqlite", "", logger)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestCreateAndAuthenticateSession(t *testing.T) {
	s := newSessionTestStore(t)
	raw, exp, err := s.CreateSession("sub-1", "user@example.com", []byte("enc"), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if raw == "" || time.Until(exp) <= 0 {
		t.Fatalf("bad session: raw=%q exp=%v", raw, exp)
	}
	ident, ok := s.AuthenticateSession(raw)
	if !ok || ident.Sub != "sub-1" || ident.Email != "user@example.com" {
		t.Fatalf("authenticate: ok=%v ident=%+v", ok, ident)
	}
	if _, ok := s.AuthenticateSession("bogus"); ok {
		t.Fatal("bogus token must not authenticate")
	}
}

func TestAuthenticateSessionExpired(t *testing.T) {
	s := newSessionTestStore(t)
	raw, _, _ := s.CreateSession("sub", "u@e.com", []byte("enc"), -time.Minute) // already expired
	if _, ok := s.AuthenticateSession(raw); ok {
		t.Fatal("expired session must not authenticate")
	}
	// but it is still renewable
	if _, ok := s.SessionForRenew(raw); !ok {
		t.Fatal("expired-but-fresh session must be renewable")
	}
}

func TestRotateAndRevokeSession(t *testing.T) {
	s := newSessionTestStore(t)
	raw, _, _ := s.CreateSession("sub", "u@e.com", []byte("enc1"), time.Hour)
	newRaw, _, _ := s.CreateSession("tmp", "t@e.com", []byte("x"), time.Hour) // just to get a fresh raw token value
	_ = s.RevokeSession(newRaw)
	if err := s.RotateSession(raw, newRaw, []byte("enc2"), time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.AuthenticateSession(raw); ok {
		t.Fatal("old token must be invalid after rotation")
	}
	ident, ok := s.AuthenticateSession(newRaw)
	if !ok || ident.Sub != "sub" {
		t.Fatalf("rotated token must carry original identity: ok=%v ident=%+v", ok, ident)
	}
	row, ok := s.SessionForRenew(newRaw)
	if !ok || string(row.RefreshEnc) != "enc2" {
		t.Fatalf("rotation must update refresh_enc: ok=%v row=%+v", ok, row)
	}
	if err := s.RevokeSession(newRaw); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.AuthenticateSession(newRaw); ok {
		t.Fatal("revoked session must not authenticate")
	}
	if _, ok := s.SessionForRenew(newRaw); ok {
		t.Fatal("revoked session must not be renewable")
	}
}
