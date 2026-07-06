package main

// M5a tests: the /metrics backbone. They prove (1) isolation — metrics are
// served ONLY by the dedicated listener, never the public mux; (2) the
// instrumentation moves under a real end-to-end bridge session (agents online,
// sessions, bridge bytes) THROUGH the InstrumentHTTP middleware, which also
// proves Hijacker survives wrapping (the WebSocket upgrades would fail
// otherwise); (3) sign-in outcome counters increment on gate decisions.
//
// Event counters are process-global (see metrics.go), so all assertions on
// them are DELTA-based: read before, act, assert the difference. Tests in one
// package run sequentially unless marked parallel, so deltas are stable.

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

// newInstrumentedTestServer mirrors newTestServer (bridge_integration_test.go)
// but serves the public mux through InstrumentHTTP — production wiring — and
// also returns a second httptest server standing in for the dedicated metrics
// listener (same Metrics/Handler code path as StartMetricsServer).
func newInstrumentedTestServer(t *testing.T) (public *httptest.Server, metrics *httptest.Server, clientToken string, store *Store) {
	t.Helper()

	cfg := &Config{
		ListenAddr:     "127.0.0.1:0",
		StateDir:       t.TempDir(),
		DevAuth:        true,
		DevClientToken: "dev-secret-token",
		DevEmail:       "dev@example.com",
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	auth, err := NewAuthenticator(context.Background(), cfg, logger)
	if err != nil {
		t.Fatalf("NewAuthenticator: %v", err)
	}
	store, err = LoadStore(cfg.DBPath(), cfg.DevicesPath(), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	auth.SetGate(NewSigninGate(cfg, store, logger))
	dir := NewDirectory(logger)
	h := NewHandler(cfg, auth, store, dir, logger)

	mux := http.NewServeMux()
	h.Register(mux)
	public = httptest.NewServer(InstrumentHTTP(mux)) // production wiring
	t.Cleanup(public.Close)

	metrics = httptest.NewServer(NewMetrics(dir, store).Handler())
	t.Cleanup(metrics.Close)

	return public, metrics, cfg.DevClientToken, store
}

// scrape GETs a metrics endpoint and returns the text exposition body.
func scrape(t *testing.T, url string) string {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("scrape: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("scrape status = %d, want 200", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("scrape read: %v", err)
	}
	return string(b)
}

// gaugeValue extracts the value of an UNLABELED sample line ("name value")
// from a scrape body. Fails the test if the sample is absent.
func gaugeValue(t *testing.T, body, name string) float64 {
	t.Helper()
	for _, line := range strings.Split(body, "\n") {
		if rest, ok := strings.CutPrefix(line, name+" "); ok {
			v, err := strconv.ParseFloat(strings.TrimSpace(rest), 64)
			if err != nil {
				t.Fatalf("parse %s sample %q: %v", name, line, err)
			}
			return v
		}
	}
	t.Fatalf("metric %s not found in scrape:\n%s", name, body)
	return 0
}

// waitFor polls cond until true or the deadline passes. Hooks fire on the
// server's goroutines a hair after the client observes an effect, so gauge and
// counter assertions poll briefly instead of racing.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// TestMetricsIsolatedFromPublicMux proves the load-bearing property of the
// design: /metrics exists ONLY on the dedicated listener. The public mux 404s
// it (and that 404 is itself counted, route-bounded as "unmatched").
func TestMetricsIsolatedFromPublicMux(t *testing.T) {
	public, metrics, _, _ := newInstrumentedTestServer(t)

	before := testutil.ToFloat64(mHTTPRequests.WithLabelValues("unmatched", "404"))

	resp, err := http.Get(public.URL + "/metrics")
	if err != nil {
		t.Fatalf("get public /metrics: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("public /metrics status = %d, want 404 (metrics must not be publicly served)", resp.StatusCode)
	}
	if got := testutil.ToFloat64(mHTTPRequests.WithLabelValues("unmatched", "404")); got != before+1 {
		t.Fatalf("unmatched/404 counter = %v, want %v", got, before+1)
	}

	// The dedicated listener DOES serve the full family set.
	body := scrape(t, metrics.URL+"/metrics")
	for _, fam := range []string{
		"ghoztty_relay_agents_online",
		"ghoztty_relay_sessions_active",
		"ghoztty_relay_sessions_total",
		"ghoztty_relay_db_up",
		"ghoztty_relay_devices_total",
		"ghoztty_relay_build_info",
		"ghoztty_relay_http_requests_total",
		"ghoztty_relay_signin_attempts_total",
		"go_goroutines", // default collectors stay registered
	} {
		if !strings.Contains(body, fam) {
			t.Errorf("scrape missing family %s", fam)
		}
	}

	// A healthy just-opened store: db_up 1, no devices yet.
	if v := gaugeValue(t, body, "ghoztty_relay_db_up"); v != 1 {
		t.Fatalf("db_up = %v, want 1", v)
	}
	if v := gaugeValue(t, body, "ghoztty_relay_devices_total"); v != 0 {
		t.Fatalf("devices_total = %v, want 0", v)
	}
}

// TestMetricsBridgeEndToEnd runs the full rendezvous + bridge THROUGH the
// instrumented mux and asserts every M5a signal moves: the three WebSocket
// upgrades succeed (Hijacker preserved — the whole flow would fail otherwise
// and upgrades are labeled 101), agents_online and sessions_active rise and
// fall, sessions_total increments, and bytes are counted per direction.
func TestMetricsBridgeEndToEnd(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	public, metrics, clientToken, _ := newInstrumentedTestServer(t)

	sessionsBefore := testutil.ToFloat64(mSessionsTotal)
	c2aBefore := testutil.ToFloat64(mBridgeBytes.WithLabelValues(dirClientToAgent))
	a2cBefore := testutil.ToFloat64(mBridgeBytes.WithLabelValues(dirAgentToClient))
	upgradesBefore := testutil.ToFloat64(mHTTPRequests.WithLabelValues("GET /v1/client/connect", "101"))

	deviceID, deviceToken := enrollDevice(t, public, clientToken, "metricsbox")

	// Agent comes online -> gauge 1 (scraped live from the Directory).
	control, _, err := websocket.Dial(ctx, wsURL(public.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent control dial: %v", err)
	}
	defer control.Close(websocket.StatusNormalClosure, "")
	waitFor(t, "agents_online=1", func() bool {
		return gaugeValue(t, scrape(t, metrics.URL+"/metrics"), "ghoztty_relay_agents_online") == 1
	})

	// Client connects; agent dials back; bridge forms.
	client, _, err := websocket.Dial(ctx, wsURL(public.URL, "/v1/client/connect?device="+deviceID), &websocket.DialOptions{
		HTTPHeader: bearerHeader(clientToken),
	})
	if err != nil {
		t.Fatalf("client connect dial: %v", err)
	}
	defer client.Close(websocket.StatusNormalClosure, "")

	_, raw, err := control.Read(ctx)
	if err != nil {
		t.Fatalf("read open command: %v", err)
	}
	var cmd struct {
		Type    string `json:"type"`
		Session string `json:"session"`
	}
	if err := json.Unmarshal(raw, &cmd); err != nil || cmd.Type != "open" {
		t.Fatalf("unexpected control command %q: %v", raw, err)
	}

	data, _, err := websocket.Dial(ctx, wsURL(public.URL, "/v1/agent/data?session="+cmd.Session), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent data dial: %v", err)
	}
	defer data.Close(websocket.StatusNormalClosure, "")

	// Session registered: active gauge up, total counter up.
	waitFor(t, "sessions_active=1", func() bool {
		return gaugeValue(t, scrape(t, metrics.URL+"/metrics"), "ghoztty_relay_sessions_active") == 1
	})
	if got := testutil.ToFloat64(mSessionsTotal); got != sessionsBefore+1 {
		t.Fatalf("sessions_total = %v, want %v", got, sessionsBefore+1)
	}

	// Bytes both ways; each direction's counter must advance by >= payload len
	// (WS close frames later may add more — hence >=, and delta-based).
	clientPayload := []byte("hello from client")
	if err := client.Write(ctx, websocket.MessageBinary, clientPayload); err != nil {
		t.Fatalf("client write: %v", err)
	}
	if _, got, err := data.Read(ctx); err != nil || string(got) != string(clientPayload) {
		t.Fatalf("agent read = %q, %v", got, err)
	}
	agentReply := []byte("reply from agent")
	if err := data.Write(ctx, websocket.MessageBinary, agentReply); err != nil {
		t.Fatalf("agent write: %v", err)
	}
	if _, got, err := client.Read(ctx); err != nil || string(got) != string(agentReply) {
		t.Fatalf("client read = %q, %v", got, err)
	}
	waitFor(t, "bridge byte counters", func() bool {
		return testutil.ToFloat64(mBridgeBytes.WithLabelValues(dirClientToAgent)) >= c2aBefore+float64(len(clientPayload)) &&
			testutil.ToFloat64(mBridgeBytes.WithLabelValues(dirAgentToClient)) >= a2cBefore+float64(len(agentReply))
	})

	// Tear down; gauges must return to 0 and the connect upgrade shows as 101.
	client.Close(websocket.StatusNormalClosure, "")
	data.Close(websocket.StatusNormalClosure, "")
	control.Close(websocket.StatusNormalClosure, "")
	waitFor(t, "gauges back to 0", func() bool {
		body := scrape(t, metrics.URL+"/metrics")
		return gaugeValue(t, body, "ghoztty_relay_agents_online") == 0 &&
			gaugeValue(t, body, "ghoztty_relay_sessions_active") == 0
	})
	waitFor(t, "connect upgrade counted as 101", func() bool {
		return testutil.ToFloat64(mHTTPRequests.WithLabelValues("GET /v1/client/connect", "101")) >= upgradesBefore+1
	})
}

// TestMetricsSigninOutcomes drives the M1 gate directly (flag ON) and asserts
// the outcome counter tracks each decision — the same record() hook the enroll
// flows exercise end-to-end in invite_signup_test.go.
func TestMetricsSigninOutcomes(t *testing.T) {
	cfg := &Config{StateDir: t.TempDir(), InviteSignup: true}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	store, err := LoadStore(cfg.DBPath(), cfg.DevicesPath(), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	t.Cleanup(func() { store.Close() })
	gate := NewSigninGate(cfg, store, logger)

	noAcctBefore := testutil.ToFloat64(mSigninAttempts.WithLabelValues(outcomeNoAccount))
	allowedBefore := testutil.ToFloat64(mSigninAttempts.WithLabelValues(outcomeAllowed))

	// Fresh identity, no code -> rejected, counted as no_account.
	if err := gate.Authorize(Identity{Email: "fresh@example.com", Sub: "sub-m5a"}, "", "127.0.0.1", tokenFingerprint("m5a-tok-1")); err == nil {
		t.Fatalf("fresh identity without code should be rejected")
	}
	if got := testutil.ToFloat64(mSigninAttempts.WithLabelValues(outcomeNoAccount)); got != noAcctBefore+1 {
		t.Fatalf("no_account counter = %v, want %v", got, noAcctBefore+1)
	}

	// Same identity with a valid code -> allowed, counted as allowed.
	if err := store.CreateInviteCode("M5ACODE", nil, nil, "test"); err != nil {
		t.Fatalf("create invite: %v", err)
	}
	if err := gate.Authorize(Identity{Email: "fresh@example.com", Sub: "sub-m5a"}, "M5ACODE", "127.0.0.1", tokenFingerprint("m5a-tok-2")); err != nil {
		t.Fatalf("coded sign-in should be allowed: %v", err)
	}
	if got := testutil.ToFloat64(mSigninAttempts.WithLabelValues(outcomeAllowed)); got != allowedBefore+1 {
		t.Fatalf("allowed counter = %v, want %v", got, allowedBefore+1)
	}
}

// TestMetricsAddrOff proves METRICS_ADDR=off disables the listener cleanly.
func TestMetricsAddrOff(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	cfg := &Config{MetricsAddr: "off", StateDir: t.TempDir()}
	store, err := LoadStore(cfg.DBPath(), cfg.DevicesPath(), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	t.Cleanup(func() { store.Close() })

	srv, err := StartMetricsServer(cfg, NewDirectory(logger), store, logger)
	if err != nil {
		t.Fatalf("StartMetricsServer(off): %v", err)
	}
	if srv != nil {
		t.Fatalf("expected nil server when disabled")
	}
}

// TestMetricsAddrBindFailure proves a bad METRICS_ADDR is a hard error (fail
// fast at startup — it is a config mistake, not something to limp past).
func TestMetricsAddrBindFailure(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	cfg := &Config{MetricsAddr: "256.256.256.256:0", StateDir: t.TempDir()}
	store, err := LoadStore(cfg.DBPath(), cfg.DevicesPath(), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	t.Cleanup(func() { store.Close() })

	if _, err := StartMetricsServer(cfg, NewDirectory(logger), store, logger); err == nil {
		t.Fatalf("expected bind error for invalid METRICS_ADDR")
	}
}

// TestMetricsRealListener exercises StartMetricsServer itself end-to-end on a
// real ephemeral port: bind, scrape over TCP, shut down.
func TestMetricsRealListener(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	cfg := &Config{MetricsAddr: "127.0.0.1:0", StateDir: t.TempDir()}
	store, err := LoadStore(cfg.DBPath(), cfg.DevicesPath(), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	t.Cleanup(func() { store.Close() })

	srv, err := StartMetricsServer(cfg, NewDirectory(logger), store, logger)
	if err != nil {
		t.Fatalf("StartMetricsServer: %v", err)
	}
	t.Cleanup(func() { _ = srv.Close() })

	// StartMetricsServer records the resolved bound address on srv.Addr so
	// callers (and this test) can find the ephemeral port.
	body := scrape(t, "http://"+srv.Addr+"/metrics")
	if !strings.Contains(body, "ghoztty_relay_db_up 1") {
		t.Fatalf("real listener scrape missing healthy db_up:\n%s", body)
	}
}
