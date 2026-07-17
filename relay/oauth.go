package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// sessionTTL is how long a minted relay session token is valid before the app
// must renew it. Short by design; renew re-checks the allowlist.
const sessionTTL = time.Hour

// googleTokens is the subset of Google's token-endpoint response the brokered
// flow needs. Unlike enroll.go's postTokenForm (id_token only), this captures
// the refresh token.
type googleTokens struct {
	IDToken      string `json:"id_token"`
	RefreshToken string `json:"refresh_token"`
	AccessToken  string `json:"access_token"`
	ExpiresIn    int    `json:"expires_in"`
}

// googleExchangeCode redeems an authorization code (+ PKCE verifier) at Google's
// token endpoint using the DESKTOP client id + secret, capturing the refresh
// token. Returns (tokens, oauthErr, err): oauthErr is a protocol-level OAuth
// error code; err is transport/5xx/malformed.
func (h *Handler) googleExchangeCode(ctx context.Context, code, codeVerifier, redirectURI string) (*googleTokens, string, error) {
	form := url.Values{
		"grant_type":    {"authorization_code"},
		"client_id":     {h.cfg.GoogleClientID},
		"client_secret": {h.cfg.GoogleClientSecret},
		"code":          {code},
		"code_verifier": {codeVerifier},
		"redirect_uri":  {redirectURI},
	}
	return h.postGoogleToken(ctx, form)
}

// googleRefresh redeems a stored refresh token for fresh tokens using the
// DESKTOP client id + secret.
func (h *Handler) googleRefresh(ctx context.Context, refreshToken string) (*googleTokens, string, error) {
	form := url.Values{
		"grant_type":    {"refresh_token"},
		"client_id":     {h.cfg.GoogleClientID},
		"client_secret": {h.cfg.GoogleClientSecret},
		"refresh_token": {refreshToken},
	}
	return h.postGoogleToken(ctx, form)
}

func (h *Handler) postGoogleToken(ctx context.Context, form url.Values) (*googleTokens, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.auth.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, "", fmt.Errorf("build token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := h.auth.httpClient.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, "", fmt.Errorf("read token response: %w", err)
	}
	if resp.StatusCode >= 500 {
		return nil, "", fmt.Errorf("token endpoint status %d", resp.StatusCode)
	}
	var out struct {
		googleTokens
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, "", fmt.Errorf("parse token response (status %d): %w", resp.StatusCode, err)
	}
	if out.Error != "" {
		return nil, out.Error, nil
	}
	if resp.StatusCode == http.StatusOK && out.IDToken != "" {
		return &out.googleTokens, "", nil
	}
	return nil, "", fmt.Errorf("token endpoint returned neither id_token nor error (status %d)", resp.StatusCode)
}

// oauthUnavailable reports whether the brokered flow can't run (missing secret
// key or Google client not configured). Fail-closed → 503.
func (h *Handler) oauthUnavailable() bool {
	return len(h.cfg.SessionEncKey) != 32 || h.cfg.GoogleClientID == "" ||
		h.cfg.GoogleClientSecret == "" || h.auth.tokenURL == ""
}

// isLoopbackRedirect accepts only loopback redirect URIs (the app's PKCE
// loopback receiver), so the relay is not a generic code-exchange oracle.
func isLoopbackRedirect(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" {
		return false
	}
	host := u.Hostname()
	return host == "127.0.0.1" || host == "::1" || host == "localhost"
}

type sessionResponse struct {
	SessionToken string `json:"session_token"`
	Expiry       int64  `json:"expiry"` // unix seconds
	Email        string `json:"email"`
	Picture      string `json:"picture,omitempty"`
}

// handleOAuthExchange: POST /oauth/exchange (JSON, UNAUTHENTICATED — the
// authorization code + PKCE verifier ARE the credential). Body:
// {code, code_verifier, redirect_uri}. Exchanges the code with Google (desktop
// client secret, server-side), verifies + allowlists the id_token, stores the
// refresh token encrypted, and mints a relay session token.
func (h *Handler) handleOAuthExchange(w http.ResponseWriter, r *http.Request) {
	if h.oauthUnavailable() {
		http.Error(w, "brokered oauth not configured", http.StatusServiceUnavailable)
		return
	}
	var body struct {
		Code        string `json:"code"`
		CodeVerif   string `json:"code_verifier"`
		RedirectURI string `json:"redirect_uri"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&body); err != nil ||
		body.Code == "" || body.CodeVerif == "" || body.RedirectURI == "" {
		http.Error(w, "invalid body: expected {code, code_verifier, redirect_uri}", http.StatusBadRequest)
		return
	}
	if !isLoopbackRedirect(body.RedirectURI) {
		http.Error(w, "redirect_uri must be loopback", http.StatusBadRequest)
		return
	}

	tokens, oauthErr, err := h.googleExchangeCode(r.Context(), body.Code, body.CodeVerif, body.RedirectURI)
	if err != nil {
		h.logger.Warn("oauth exchange upstream error", "err", err)
		http.Error(w, "upstream token exchange failed", http.StatusBadGateway)
		return
	}
	if oauthErr != "" {
		h.logger.Warn("oauth exchange rejected by google", "oauth_error", oauthErr)
		http.Error(w, "token exchange rejected: "+oauthErr, http.StatusBadRequest)
		return
	}
	if tokens.RefreshToken == "" {
		http.Error(w, "google did not return a refresh token", http.StatusBadGateway)
		return
	}

	out, err := h.mintSession(r.Context(), tokens)
	if err != nil {
		if errors.Is(err, ErrUnauthorized) {
			http.Error(w, "not authorized", http.StatusForbidden)
			return
		}
		h.logger.Error("mint session failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// mintSession verifies + allowlists the id_token, extracts display claims,
// encrypts the refresh token, and persists a new session row.
func (h *Handler) mintSession(ctx context.Context, tokens *googleTokens) (*sessionResponse, error) {
	ident, err := h.auth.VerifyIDToken(ctx, tokens.IDToken) // signature/aud/exp + ALLOWED_EMAILS
	if err != nil {
		return nil, err
	}
	picture := parsePictureClaim(tokens.IDToken)
	enc, err := encryptSecret(h.cfg.SessionEncKey, []byte(tokens.RefreshToken))
	if err != nil {
		return nil, err
	}
	raw, exp, err := h.store.CreateSession(ident.Sub, ident.Email, enc, sessionTTL)
	if err != nil {
		return nil, err
	}
	return &sessionResponse{
		SessionToken: raw,
		Expiry:       exp.Unix(),
		Email:        ident.Email,
		Picture:      picture,
	}, nil
}

// handleOAuthRenew: POST /oauth/renew (Bearer session token). Uses the stored
// Google refresh token to mint a fresh id_token, RE-CHECKS the allowlist, and
// rotates the session token. Accepts a just-expired token (SessionForRenew
// ignores the 1h expiry within the idle cap); rejects revoked/absent/idle-max.
func (h *Handler) handleOAuthRenew(w http.ResponseWriter, r *http.Request) {
	if h.oauthUnavailable() {
		http.Error(w, "brokered oauth not configured", http.StatusServiceUnavailable)
		return
	}
	raw := bearerToken(r)
	row, ok := h.store.SessionForRenew(raw)
	if !ok {
		http.Error(w, "session not renewable", http.StatusUnauthorized)
		return
	}
	refreshPlain, err := decryptSecret(h.cfg.SessionEncKey, row.RefreshEnc)
	if err != nil {
		h.logger.Error("decrypt refresh token failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	tokens, oauthErr, err := h.googleRefresh(r.Context(), string(refreshPlain))
	if err != nil {
		http.Error(w, "upstream refresh failed", http.StatusBadGateway)
		return
	}
	if oauthErr != "" {
		// invalid_grant etc. → the Google grant is dead (revoked). Kill the row.
		_ = h.store.RevokeSession(raw)
		http.Error(w, "refresh rejected: "+oauthErr, http.StatusUnauthorized)
		return
	}
	ident, err := h.auth.VerifyIDToken(r.Context(), tokens.IDToken) // re-run allowlist
	if err != nil {
		_ = h.store.RevokeSession(raw)
		http.Error(w, "not authorized", http.StatusForbidden)
		return
	}

	// Google rotates refresh tokens sometimes; keep the newest.
	newRefresh := row.RefreshEnc
	if tokens.RefreshToken != "" {
		if enc, encErr := encryptSecret(h.cfg.SessionEncKey, []byte(tokens.RefreshToken)); encErr == nil {
			newRefresh = enc
		}
	}
	newRaw, _, err := newDeviceToken()
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	exp := time.Now().Add(sessionTTL)
	if err := h.store.RotateSession(raw, newRaw, newRefresh, exp); err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, &sessionResponse{
		SessionToken: newRaw,
		Expiry:       exp.Unix(),
		Email:        ident.Email,
		Picture:      parsePictureClaim(tokens.IDToken),
	})
}

// handleOAuthSignout: POST /oauth/signout (Bearer session token). Revokes the
// session and destroys the stored Google refresh token. Idempotent.
func (h *Handler) handleOAuthSignout(w http.ResponseWriter, r *http.Request) {
	if raw := bearerToken(r); raw != "" {
		_ = h.store.RevokeSession(raw)
	}
	w.WriteHeader(http.StatusNoContent)
}

// parsePictureClaim best-effort reads the `picture` claim from a JWT payload
// (display only; the id_token was already verified by VerifyIDToken). Returns
// "" when absent or unparseable.
func parsePictureClaim(idToken string) string {
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Picture string `json:"picture"`
	}
	_ = json.Unmarshal(payload, &claims)
	return claims.Picture
}
