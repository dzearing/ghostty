package main

// ratelimit.go — M4 in-memory abuse-control rate limiting (plan §5 M4).
//
// Token buckets keyed by client IP or caller identity, one limiter per abuse
// surface. Deliberately in-memory only: counters reset on restart, which is
// accepted for the single-VM beta (a restart is rare, operator-driven, and an
// attacker cannot trigger one; persistence would buy little and cost a write
// per request). Each limiter's budget is env-configured per minute; 0 disables
// that limiter entirely.
//
// Where the limits bite (and why there):
//
//   - SIGN-IN (per IP, FAILURES only): checked/charged in
//     Authenticator.AuthenticateClient — the single choke point every client
//     bearer-auth passes through in BOTH flag states (ALLOWED_EMAILS and
//     INVITE_SIGNUP). Every client API request verifies a token there, so
//     charging each request would throttle legitimate active users; instead
//     the budget is only CHARGED on auth failure and CHECKED up front. A
//     brute-forcer burns the budget and gets 429s before any verification
//     work; a legitimate user consumes nothing. Per IP (not identity) because
//     a failed verification yields no trustworthy identity to key on.
//   - ENROLL START (per IP, every request): POST /v1/enroll/start is
//     unauthenticated and mints upstream Google traffic + relay state — the
//     most abusable endpoint. Budgeted per request.
//   - ENROLL POLL (per IP, every request): a backstop behind the existing
//     per-handle interval throttle in enroll.go — that throttle is per
//     enrollment, so an attacker rotating bogus handles could still spin the
//     handler; this bounds the raw per-IP request rate. Generous default
//     (legit device-flow polling is ~12/min per enrollment).
//   - CLIENT CONNECT (per identity, every request): bounds session-churn
//     abuse by an authenticated caller. Keyed on identity (sub, email
//     fallback) rather than IP so a roaming client is limited as one caller.
//
// Exceeded -> HTTP 429 with a Retry-After header (where the response is still
// plain HTTP, i.e. before any WebSocket upgrade).

import (
	"errors"
	"math"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// RateLimitedError is returned when a request is refused by a rate limiter.
// It rides through the auth error path so handlers can translate it into a
// 429 (writeAuthErr) instead of the generic 401.
type RateLimitedError struct {
	RetryAfter time.Duration
}

func (e *RateLimitedError) Error() string { return "rate limited" }

// sweepEvery / staleAfter govern bucket garbage collection. A bucket idle for
// staleAfter has fully refilled (full refill takes exactly 60s at any budget),
// so dropping it is semantically identical to keeping it.
const (
	sweepEvery = time.Minute
	staleAfter = 2 * time.Minute
)

// RateLimiter is a concurrency-safe token-bucket limiter over string keys.
// Capacity and refill are both perMin: a full minute's budget may be burst,
// then sustained use refills at perMin/60 per second. perMin <= 0 disables
// the limiter (everything allowed). A nil *RateLimiter is likewise disabled.
type RateLimiter struct {
	perMin int

	mu        sync.Mutex
	buckets   map[string]*tokenBucket
	lastSweep time.Time
	now       func() time.Time // test seam
}

type tokenBucket struct {
	tokens float64
	last   time.Time
}

func newRateLimiter(perMin int) *RateLimiter {
	return &RateLimiter{
		perMin:  perMin,
		buckets: make(map[string]*tokenBucket),
		now:     time.Now,
	}
}

func (l *RateLimiter) enabled() bool { return l != nil && l.perMin > 0 }

// ratePerSec is the refill rate.
func (l *RateLimiter) ratePerSec() float64 { return float64(l.perMin) / 60.0 }

// Allow takes one token for key. Returns (true, 0) when allowed, or
// (false, retryAfter) when the budget is exhausted.
func (l *RateLimiter) Allow(key string) (bool, time.Duration) {
	if !l.enabled() {
		return true, 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.bucketLocked(key)
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	return false, l.retryAfterLocked(b)
}

// Peek reports whether key is currently out of budget WITHOUT consuming a
// token. Used by the charge-on-failure sign-in limiter.
func (l *RateLimiter) Peek(key string) (blocked bool, retryAfter time.Duration) {
	if !l.enabled() {
		return false, 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.bucketLocked(key)
	if b.tokens >= 1 {
		return false, 0
	}
	return true, l.retryAfterLocked(b)
}

// Charge consumes one token for key without reporting an outcome (floored at
// zero — going "into debt" would let a burst extend the lockout unboundedly).
func (l *RateLimiter) Charge(key string) {
	if !l.enabled() {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.bucketLocked(key)
	b.tokens = math.Max(0, b.tokens-1)
}

// bucketLocked returns key's bucket refilled to now, creating it full.
// Caller holds l.mu.
func (l *RateLimiter) bucketLocked(key string) *tokenBucket {
	now := l.now()
	l.sweepLocked(now)
	b := l.buckets[key]
	if b == nil {
		b = &tokenBucket{tokens: float64(l.perMin), last: now}
		l.buckets[key] = b
		return b
	}
	if elapsed := now.Sub(b.last).Seconds(); elapsed > 0 {
		b.tokens = math.Min(float64(l.perMin), b.tokens+elapsed*l.ratePerSec())
		b.last = now
	}
	return b
}

// retryAfterLocked is the time until one whole token refills.
func (l *RateLimiter) retryAfterLocked(b *tokenBucket) time.Duration {
	need := 1 - b.tokens
	if need <= 0 {
		return 0
	}
	return time.Duration(need / l.ratePerSec() * float64(time.Second))
}

// sweepLocked drops buckets idle long enough to have fully refilled, bounding
// memory against key churn (e.g. an attacker rotating spoofed XFF values).
// Caller holds l.mu.
func (l *RateLimiter) sweepLocked(now time.Time) {
	if now.Sub(l.lastSweep) < sweepEvery {
		return
	}
	l.lastSweep = now
	for k, b := range l.buckets {
		if now.Sub(b.last) >= staleAfter {
			delete(l.buckets, k)
		}
	}
}

// RateLimiters bundles the per-surface limiters. Constructed once in
// NewHandler; a nil *RateLimiters disables everything (methods are nil-safe
// so an Authenticator wired without a Handler keeps working).
type RateLimiters struct {
	signin      *RateLimiter // failed sign-ins, per IP
	enrollStart *RateLimiter // enroll starts, per IP
	enrollPoll  *RateLimiter // enroll polls, per IP (backstop)
	connect     *RateLimiter // client connects, per identity
}

// NewRateLimiters builds the limiter set from config (0 disables a surface).
func NewRateLimiters(cfg *Config) *RateLimiters {
	return &RateLimiters{
		signin:      newRateLimiter(cfg.RateSigninPerMin),
		enrollStart: newRateLimiter(cfg.RateEnrollPerMin),
		enrollPoll:  newRateLimiter(cfg.RateEnrollPollPerMin),
		connect:     newRateLimiter(cfg.RateConnectPerMin),
	}
}

// --- Authenticator hooks (the sign-in choke point) ---------------------------

// SetRateLimits binds the limiter set to the Authenticator. Late-bound by
// NewHandler (mirroring SetGate) so production and every test server get it
// through the one wiring path with no main.go/test changes.
func (a *Authenticator) SetRateLimits(rl *RateLimiters) { a.limits = rl }

// checkSigninBudget refuses up front when ip has burned its failed-sign-in
// budget. Nil-safe: no limiter set, or the surface disabled, allows.
func (rl *RateLimiters) checkSigninBudget(ip string) error {
	if rl == nil {
		return nil
	}
	if blocked, retry := rl.signin.Peek(ip); blocked {
		return &RateLimitedError{RetryAfter: retry}
	}
	return nil
}

// chargeSigninFailure burns one unit of ip's failed-sign-in budget.
func (rl *RateLimiters) chargeSigninFailure(ip string) {
	if rl == nil {
		return
	}
	rl.signin.Charge(ip)
}

// --- Handler hooks -----------------------------------------------------------

// writeAuthErr maps an AuthenticateClient error onto the wire: rate-limit
// refusals become 429 + Retry-After; everything else keeps the historical
// bare 401.
func (h *Handler) writeAuthErr(w http.ResponseWriter, err error) {
	var rle *RateLimitedError
	if errors.As(err, &rle) {
		setRetryAfter(w, rle.RetryAfter)
		writeJSON(w, http.StatusTooManyRequests, map[string]any{"error": "rate limited"})
		return
	}
	http.Error(w, "unauthorized", http.StatusUnauthorized)
}

// limitEnrollStart applies the per-IP enroll-start budget. Returns true if
// the request was refused (response already written).
func (h *Handler) limitEnrollStart(w http.ResponseWriter, r *http.Request) bool {
	if h.rl == nil {
		return false
	}
	ok, retry := h.rl.enrollStart.Allow(clientIP(r))
	if ok {
		return false
	}
	setRetryAfter(w, retry)
	// Same terse text style as the pending-enrollment 429 above it.
	http.Error(w, "rate limited, retry later", http.StatusTooManyRequests)
	return true
}

// limitEnrollPoll applies the per-IP poll backstop. The refusal reuses the
// poll protocol's slow_down shape so existing agents just back off.
func (h *Handler) limitEnrollPoll(w http.ResponseWriter, r *http.Request) bool {
	if h.rl == nil {
		return false
	}
	ok, retry := h.rl.enrollPoll.Allow(clientIP(r))
	if ok {
		return false
	}
	setRetryAfter(w, retry)
	writeJSON(w, http.StatusTooManyRequests, map[string]any{
		"status":   "slow_down",
		"interval": ceilSeconds(retry),
	})
	return true
}

// limitConnect applies the per-identity connect budget (every attempt is
// charged — unlike sign-in, the caller here is authenticated and churn itself
// is the abuse). Returns true if refused (response written).
func (h *Handler) limitConnect(w http.ResponseWriter, ident Identity) bool {
	if h.rl == nil {
		return false
	}
	ok, retry := h.rl.connect.Allow(quotaKey(ident))
	if ok {
		return false
	}
	setRetryAfter(w, retry)
	writeJSON(w, http.StatusTooManyRequests, map[string]any{"error": "rate limited"})
	return true
}

// setRetryAfter writes a Retry-After header, rounded up so a client that
// honors it exactly cannot arrive a fraction early and get refused again.
func setRetryAfter(w http.ResponseWriter, d time.Duration) {
	w.Header().Set("Retry-After", strconv.Itoa(ceilSeconds(d)))
}

// ceilSeconds converts a duration to whole seconds, rounding up, min 1.
func ceilSeconds(d time.Duration) int {
	s := int(math.Ceil(d.Seconds()))
	if s < 1 {
		s = 1
	}
	return s
}
