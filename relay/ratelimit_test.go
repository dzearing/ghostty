package main

// M4 rate-limit tests: limiter unit behavior under concurrency, the
// charge-on-failure sign-in limiter, per-IP enroll start/poll limits, the
// per-identity connect limit, and a concurrent load test proving the budget
// holds under a flood (run with -race for the concurrency guarantee).

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// TestRateLimiterConcurrent hammers one limiter key from many goroutines and
// asserts the allowed count equals the burst budget (the token bucket's
// capacity), with everything else refused — and that keys are independent.
func TestRateLimiterConcurrent(t *testing.T) {
	const budget = 50
	l := newRateLimiter(budget)

	var allowed, denied atomic.Int64
	var wg sync.WaitGroup
	for g := 0; g < 20; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 10; i++ { // 200 total attempts
				if ok, retry := l.Allow("attacker"); ok {
					allowed.Add(1)
				} else {
					denied.Add(1)
					if retry <= 0 {
						t.Error("denied Allow returned non-positive retryAfter")
					}
				}
			}
		}()
	}
	wg.Wait()

	// The flood finishes in well under a second, so refill (budget/60 per
	// second) can add at most one extra token.
	if got := allowed.Load(); got < budget || got > budget+1 {
		t.Fatalf("allowed = %d, want ≈ %d (the configured budget)", got, budget)
	}
	if allowed.Load()+denied.Load() != 200 {
		t.Fatalf("allowed+denied = %d, want 200", allowed.Load()+denied.Load())
	}

	// Another key is unaffected.
	if ok, _ := l.Allow("innocent"); !ok {
		t.Fatal("independent key was refused")
	}

	// Disabled (0) and nil limiters allow everything.
	if ok, _ := newRateLimiter(0).Allow("x"); !ok {
		t.Fatal("perMin=0 limiter refused; 0 must disable")
	}
	var nilL *RateLimiter
	if ok, _ := nilL.Allow("x"); !ok {
		t.Fatal("nil limiter refused")
	}
}

// TestSigninRateLimitFlood: repeated FAILED sign-ins from one IP burn the
// budget and then get 429 + Retry-After — including for a subsequently valid
// token from the same IP (the brute-force lockout).
func TestSigninRateLimitFlood(t *testing.T) {
	ts, goodToken, _ := newQuotaTestServer(t, func(cfg *Config) { cfg.RateSigninPerMin = 3 })

	get := func(token string) *http.Response {
		req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/client/devices", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		resp.Body.Close()
		return resp
	}

	for i := 0; i < 3; i++ {
		if resp := get("wrong-token"); resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("bad token #%d = %d, want 401 (budget not yet burned)", i+1, resp.StatusCode)
		}
	}
	resp := get("wrong-token")
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("bad token #4 = %d, want 429", resp.StatusCode)
	}
	if resp.Header.Get("Retry-After") == "" {
		t.Fatal("429 missing Retry-After header")
	}
	// The IP is locked out even for the valid credential.
	if resp := get(goodToken); resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("valid token from burned IP = %d, want 429", resp.StatusCode)
	}
}

// TestSigninSuccessNotCharged: successful authenticated traffic consumes no
// sign-in budget — only failures do.
func TestSigninSuccessNotCharged(t *testing.T) {
	ts, goodToken, _ := newQuotaTestServer(t, func(cfg *Config) { cfg.RateSigninPerMin = 2 })

	for i := 0; i < 10; i++ {
		req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/client/devices", nil)
		req.Header.Set("Authorization", "Bearer "+goodToken)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("valid request #%d = %d, want 200 (successes must not charge)", i+1, resp.StatusCode)
		}
	}
	// The full failure budget is still available.
	for i := 0; i < 2; i++ {
		req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/client/devices", nil)
		req.Header.Set("Authorization", "Bearer nope")
		resp, _ := http.DefaultClient.Do(req)
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("bad token #%d = %d, want 401", i+1, resp.StatusCode)
		}
	}
}

// TestEnrollStartRateLimitLoad is the M4 load test: a concurrent flood of the
// unauthenticated /v1/enroll/start and assert allowed ≈ budget, rest 429.
// (On this no-OIDC server an ALLOWED request answers 503 "enrollment
// unavailable" — the limiter runs first, so 503 = passed the limiter.)
func TestEnrollStartRateLimitLoad(t *testing.T) {
	const budget = 25
	ts, _, _ := newQuotaTestServer(t, func(cfg *Config) { cfg.RateEnrollPerMin = budget })

	const floods = 300
	var passed, limited, other atomic.Int64
	var sawRetryAfter atomic.Bool
	var wg sync.WaitGroup
	for g := 0; g < 30; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < floods/30; i++ {
				resp, err := http.Post(ts.URL+"/v1/enroll/start", "application/json",
					strings.NewReader(`{"name":"floodbox"}`))
				if err != nil {
					t.Errorf("enroll start: %v", err)
					return
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				switch resp.StatusCode {
				case http.StatusServiceUnavailable: // passed the limiter
					passed.Add(1)
				case http.StatusTooManyRequests:
					limited.Add(1)
					if resp.Header.Get("Retry-After") != "" {
						sawRetryAfter.Store(true)
					}
				default:
					other.Add(1)
				}
			}
		}()
	}
	wg.Wait()

	if other.Load() != 0 {
		t.Fatalf("unexpected statuses: %d", other.Load())
	}
	// Refill during the (sub-second) flood can add at most ~1 token.
	if p := passed.Load(); p < budget || p > budget+2 {
		t.Fatalf("passed = %d, want ≈ %d (the configured budget)", p, budget)
	}
	if limited.Load() != floods-passed.Load() {
		t.Fatalf("limited = %d, want %d", limited.Load(), floods-passed.Load())
	}
	if !sawRetryAfter.Load() {
		t.Fatal("no 429 carried a Retry-After header")
	}
}

// TestEnrollPollRateLimit: the per-IP poll backstop kicks in past the budget
// and answers in the poll protocol's slow_down shape.
func TestEnrollPollRateLimit(t *testing.T) {
	ts, _, _ := newQuotaTestServer(t, func(cfg *Config) { cfg.RateEnrollPollPerMin = 3 })

	poll := func() (int, map[string]any) {
		resp, err := http.Post(ts.URL+"/v1/enroll/poll", "application/json",
			strings.NewReader(`{"device_code_handle":"bogus"}`))
		if err != nil {
			t.Fatalf("poll: %v", err)
		}
		defer resp.Body.Close()
		var body map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			t.Fatalf("decode poll (status %d): %v", resp.StatusCode, err)
		}
		return resp.StatusCode, body
	}

	for i := 0; i < 3; i++ {
		if status, _ := poll(); status != http.StatusNotFound {
			t.Fatalf("poll #%d = %d, want 404 (unknown handle, limiter passed)", i+1, status)
		}
	}
	status, body := poll()
	if status != http.StatusTooManyRequests || body["status"] != "slow_down" {
		t.Fatalf("poll #4 = %d %v, want 429 slow_down", status, body)
	}
}

// TestConnectRateLimit: the per-identity connect budget 429s past the limit
// (each attempt charges, whatever its outcome).
func TestConnectRateLimit(t *testing.T) {
	ts, clientToken, _ := newQuotaTestServer(t, func(cfg *Config) { cfg.RateConnectPerMin = 2 })
	deviceID, _ := enrollDevice(t, ts, clientToken, "offlinebox")

	connect := func() int {
		resp := doJSON(t, http.MethodGet, ts.URL+"/v1/client/connect?device="+deviceID, clientToken, "")
		resp.Body.Close()
		return resp.StatusCode
	}

	for i := 0; i < 2; i++ {
		if status := connect(); status != http.StatusConflict {
			t.Fatalf("connect #%d = %d, want 409 (device offline, limiter passed)", i+1, status)
		}
	}
	if status := connect(); status != http.StatusTooManyRequests {
		t.Fatalf("connect #3 = %d, want 429", status)
	}
}

// TestRateLimiterRefill: after the budget is burned, tokens come back at
// perMin/60 per second (via the injectable clock).
func TestRateLimiterRefill(t *testing.T) {
	l := newRateLimiter(60) // 1 token/second
	now := time.Unix(1000, 0)
	l.now = func() time.Time { return now }

	for i := 0; i < 60; i++ {
		if ok, _ := l.Allow("k"); !ok {
			t.Fatalf("burst Allow #%d refused", i+1)
		}
	}
	if ok, retry := l.Allow("k"); ok || retry <= 0 {
		t.Fatalf("Allow after burn = (%v, %v), want refusal with positive retry", ok, retry)
	}
	now = now.Add(1500 * time.Millisecond) // refills 1.5 tokens
	if ok, _ := l.Allow("k"); !ok {
		t.Fatal("Allow after refill window refused")
	}
	if ok, _ := l.Allow("k"); ok {
		t.Fatal("second Allow allowed but only ~0.5 tokens should remain")
	}
}
