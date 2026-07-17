package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
)

// encryptSecret seals plaintext with AES-256-GCM under key (32 bytes). The
// 12-byte random nonce is prepended to the returned ciphertext. Used to protect
// the Google refresh token at rest (the one recoverable secret the relay
// stores); everything else is a one-way hash.
func encryptSecret(key, plaintext []byte) ([]byte, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// decryptSecret opens a ciphertext produced by encryptSecret.
func decryptSecret(key, ciphertext []byte) ([]byte, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	ns := gcm.NonceSize()
	if len(ciphertext) < ns {
		return nil, errors.New("ciphertext too short")
	}
	return gcm.Open(nil, ciphertext[:ns], ciphertext[ns:], nil)
}

func newGCM(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("session enc key must be 32 bytes, got %d", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// decodeSessionEncKey parses SESSION_ENC_KEY: base64-std (padded or raw) of
// exactly 32 bytes. Empty/short is an error (fail-closed).
func decodeSessionEncKey(s string) ([]byte, error) {
	if s == "" {
		return nil, errors.New("SESSION_ENC_KEY is empty")
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding} {
		if k, err := enc.DecodeString(s); err == nil && len(k) == 32 {
			return k, nil
		}
	}
	return nil, errors.New("SESSION_ENC_KEY must be base64 of exactly 32 bytes")
}
