package main

import (
	"bytes"
	"crypto/rand"
	"testing"
)

func testKey(t *testing.T) []byte {
	t.Helper()
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		t.Fatal(err)
	}
	return k
}

func TestEncryptDecryptRoundTrip(t *testing.T) {
	key := testKey(t)
	plain := []byte("1//0gRefreshTokenExampleValue")
	ct, err := encryptSecret(key, plain)
	if err != nil {
		t.Fatalf("encrypt: %v", err)
	}
	if bytes.Contains(ct, plain) {
		t.Fatal("ciphertext leaks plaintext")
	}
	got, err := decryptSecret(key, ct)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("round trip mismatch: got %q want %q", got, plain)
	}
}

func TestEncryptNonceUnique(t *testing.T) {
	key := testKey(t)
	a, _ := encryptSecret(key, []byte("x"))
	b, _ := encryptSecret(key, []byte("x"))
	if bytes.Equal(a, b) {
		t.Fatal("same plaintext must not produce identical ciphertext (nonce reuse)")
	}
}

func TestDecryptWrongKeyFails(t *testing.T) {
	ct, _ := encryptSecret(testKey(t), []byte("secret"))
	if _, err := decryptSecret(testKey(t), ct); err == nil {
		t.Fatal("decrypt with wrong key must fail")
	}
}

func TestDecodeSessionEncKey(t *testing.T) {
	// 32 bytes ("0123456789abcdef0123456789abcdef"), base64-std encoded.
	good := "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
	k, err := decodeSessionEncKey(good)
	if err != nil || len(k) != 32 {
		t.Fatalf("decode good key: len=%d err=%v", len(k), err)
	}
	if _, err := decodeSessionEncKey("too-short"); err == nil {
		t.Fatal("short key must be rejected")
	}
	if _, err := decodeSessionEncKey(""); err == nil {
		t.Fatal("empty key must be rejected")
	}
}
