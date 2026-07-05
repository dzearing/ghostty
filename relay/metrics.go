package main

// Prometheus /metrics backbone (launch plan §2 + §5 M5a). ALL metrics logic
// lives in this file so the concurrent M2/M4 worktrees only ever see one-line
// hook calls in shared files.
//
// Serving model: metrics are exposed on their OWN listener (METRICS_ADDR,
// default 127.0.0.1:9091), NEVER on the public mux. The public mux is proxied
// by Caddy to the internet; a separate loopback listener means metrics cannot
// be publicly reachable by construction — no auth layer, no Caddy change, and
// Prometheus on the same VM scrapes localhost. METRICS_ADDR=off disables the
// listener entirely; any other value must be a bindable host:port (a bind
// failure at startup is a hard error — it is a config mistake, fail fast).
//
// Registry model: two kinds of collectors, split deliberately.
//   - Event COUNTERS (bridge bytes, HTTP requests, sign-in outcomes, sessions
//     started) are package-level and registered once on the process-global
//     default registry. That keeps every hook a single line at the call site
//     with no plumbing of a Metrics handle through Handler/Directory/bridge.
//   - State GAUGES (agents online, sessions active, DB health, device count,
//     build info) are GaugeFuncs bound to a specific Directory/Store instance,
//     registered on a per-instance registry created by NewMetrics. GaugeFunc
//     reads live state under the owning lock at scrape time, so shared files
//     need no register/unregister hooks at all. (Per-instance registries also
//     keep tests honest: every test server gets fresh gauges without
//     duplicate-registration panics.)
// The /metrics handler gathers BOTH: the default registry (which also carries
// client_golang's free process_*/go_* collectors) plus the instance registry.
//
// Label cardinality is bounded by construction: `route` is the registered
// ServeMux pattern (a small fixed set — never the raw path, so device IDs,
// enroll nonces, and handles cannot leak into labels), `code` is the exact
// HTTP status code (a handful of values), `direction` has two values, and
// `outcome` is the closed signin_attempts enum. No per-user/per-device labels.

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// scrapeProbeTimeout bounds the DB work a single scrape may trigger (ping +
// device count). GaugeFuncs run inline at scrape time, so without this a hung
// SQLite (e.g. a stuck WAL writer) would hang the scrape and, transitively,
// Prometheus' scrape slot. 2s is far above healthy SQLite latency and far
// below Prometheus' default 10s scrape timeout.
const scrapeProbeTimeout = 2 * time.Second

// --- Event counters (process-global; hooks are single lines) ----------------

var (
	// mSessionsTotal counts sessions ever created (pending included — a session
	// that times out before bridging still consumed relay work). Hooked in
	// Directory.CreatePending.
	mSessionsTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ghoztty_relay_sessions_total",
		Help: "Total client connect sessions created (including ones that never bridged).",
	})

	// mBridgeBytes counts payload bytes relayed through live bridges, per
	// direction. Hooked via countingWriter in bridge().
	mBridgeBytes = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "ghoztty_relay_bridge_bytes_total",
		Help: "Total bytes relayed through bridged sessions, by direction.",
	}, []string{"direction"})

	// mHTTPRequests counts completed public-mux requests. `route` is the
	// registered mux pattern (bounded set; empty match reported as
	// "unmatched"), `code` the exact status code written (101 for WebSocket
	// upgrades, which write their status before hijacking).
	mHTTPRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "ghoztty_relay_http_requests_total",
		Help: "Total HTTP requests on the public mux, by route pattern and status code.",
	}, []string{"route", "code"})

	// mSigninAttempts counts sign-in authorization outcomes. With INVITE_SIGNUP
	// ON the label values are the signin_attempts enum (auth_gate.go record);
	// with the flag OFF the legacy allowlist decision is counted as
	// allowlist_allowed/allowlist_rejected (VerifyIDToken) so the launch
	// dashboard has a signal in both worlds. Counting only — auth behavior is
	// untouched.
	mSigninAttempts = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "ghoztty_relay_signin_attempts_total",
		Help: "Total sign-in authorization decisions, by outcome.",
	}, []string{"outcome"})
)

// Flag-OFF (ALLOWED_EMAILS) outcome label values. Distinct names from the
// invite-model enum so a dashboard can tell which model produced the decision.
const (
	outcomeAllowlistAllowed  = "allowlist_allowed"
	outcomeAllowlistRejected = "allowlist_rejected"
)

// bridgeDirection label values.
const (
	dirClientToAgent = "client_to_agent"
	dirAgentToClient = "agent_to_client"
)

// init pre-creates the label children whose value sets are known and closed,
// so the families appear in the very first scrape at 0 (a CounterVec with no
// children emits nothing) and PromQL rate() sees the 0 baseline instead of a
// counter appearing mid-flight. mHTTPRequests stays lazy: its route×code
// combinations are bounded but not worth enumerating.
func init() {
	for _, d := range []string{dirClientToAgent, dirAgentToClient} {
		mBridgeBytes.WithLabelValues(d)
	}
	for _, o := range []string{
		outcomeAllowed, outcomeBlocked, outcomeNoAccount, outcomeBadInvite,
		outcomeExpiredInvite, outcomeRevokedInvite, outcomeExhaustedInvite,
		outcomeNotVerified, outcomeAllowlistAllowed, outcomeAllowlistRejected,
	} {
		mSigninAttempts.WithLabelValues(o)
	}
}

// countingWriter adds every written byte count to a counter before forwarding.
// bridge() wraps each direction's destination with one of these.
type countingWriter struct {
	w io.Writer
	c prometheus.Counter
}

func (cw countingWriter) Write(p []byte) (int, error) {
	n, err := cw.w.Write(p)
	if n > 0 {
		cw.c.Add(float64(n))
	}
	return n, err
}

// --- Instance gauges + /metrics handler --------------------------------------

// Metrics holds the per-instance registry of state gauges bound to one
// Directory/Store pair. Create with NewMetrics; serve with Handler.
type Metrics struct {
	reg *prometheus.Registry
}

// NewMetrics builds the instance registry: GaugeFuncs that read live state at
// scrape time from dir (agents/sessions, under its lock) and store (DB ping +
// device count, with a scrape-bounded timeout), plus build info.
func NewMetrics(dir *Directory, store *Store) *Metrics {
	reg := prometheus.NewRegistry()

	reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "ghoztty_relay_agents_online",
		Help: "Agents currently holding a live control connection.",
	}, func() float64 {
		dir.mu.Lock()
		defer dir.mu.Unlock()
		return float64(len(dir.agents))
	}))

	reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "ghoztty_relay_sessions_active",
		Help: "Sessions currently registered (pending setup or actively bridged).",
	}, func() float64 {
		dir.mu.Lock()
		defer dir.mu.Unlock()
		return float64(len(dir.sessions))
	}))

	reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "ghoztty_relay_db_up",
		Help: "1 if the SQLite database answers a bounded ping at scrape time, else 0.",
	}, func() float64 {
		ctx, cancel := context.WithTimeout(context.Background(), scrapeProbeTimeout)
		defer cancel()
		if err := store.db.PingContext(ctx); err != nil {
			return 0
		}
		return 1
	}))

	// Device count is queried at scrape time rather than maintained on mutation:
	// it is one indexed COUNT(*) on a small table every ~15s, and doing it here
	// (vs hooks on every create/delete/import path) keeps store.go untouched.
	reg.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "ghoztty_relay_devices_total",
		Help: "Enrolled devices in the store (counted at scrape time).",
	}, func() float64 {
		ctx, cancel := context.WithTimeout(context.Background(), scrapeProbeTimeout)
		defer cancel()
		var n float64
		if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices`).Scan(&n); err != nil {
			return -1 // sentinel: the scrape ran but the count failed (db_up will be 0 too)
		}
		return n
	}))

	build := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "ghoztty_relay_build_info",
		Help: "Constant 1, labeled with the relay build version (VCS revision or 'dev').",
	}, []string{"version"})
	build.WithLabelValues(buildVersion()).Set(1)
	reg.MustRegister(build)

	return &Metrics{reg: reg}
}

// buildVersion returns the VCS revision stamped into the binary, or "dev".
// There is no hand-maintained version constant in the relay, and the revision
// is what deploys are actually keyed on.
func buildVersion() string {
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, s := range bi.Settings {
			if s.Key == "vcs.revision" && s.Value != "" {
				return s.Value
			}
		}
	}
	return "dev"
}

// Handler serves the merged view: the default registry (event counters +
// client_golang's process_*/go_* collectors) plus this instance's gauges.
func (m *Metrics) Handler() http.Handler {
	g := prometheus.Gatherers{prometheus.DefaultGatherer, m.reg}
	return promhttp.HandlerFor(g, promhttp.HandlerOpts{})
}

// StartMetricsServer binds METRICS_ADDR and serves /metrics (and only that) on
// it. Returns nil when disabled (METRICS_ADDR=off). A bind failure is returned
// to the caller, which must treat it as fatal: an unbindable METRICS_ADDR is a
// config error and silently running without observability is exactly the
// failure mode metrics exist to prevent. Serving happens on a goroutine so the
// main listener is never blocked.
func StartMetricsServer(cfg *Config, dir *Directory, store *Store, logger *slog.Logger) (*http.Server, error) {
	if strings.EqualFold(cfg.MetricsAddr, "off") {
		logger.Info("metrics listener disabled (METRICS_ADDR=off)")
		return nil, nil
	}

	ln, err := net.Listen("tcp", cfg.MetricsAddr)
	if err != nil {
		return nil, fmt.Errorf("bind metrics listener %s: %w", cfg.MetricsAddr, err)
	}

	mux := http.NewServeMux()
	mux.Handle("GET /metrics", NewMetrics(dir, store).Handler())

	srv := &http.Server{
		// Addr carries the RESOLVED bound address (":0" becomes the real
		// ephemeral port) purely as a read-back for logging/tests; Serve below
		// uses the listener directly.
		Addr:              ln.Addr().String(),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		logger.Info("metrics listening", "addr", ln.Addr().String())
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			// The metrics listener dying does NOT take down the relay: user
			// traffic outranks observability once we are past startup.
			logger.Error("metrics server error", "err", err)
		}
	}()
	return srv, nil
}

// --- Public-mux instrumentation ----------------------------------------------

// InstrumentHTTP wraps the public mux so every completed request increments
// mHTTPRequests. It lives here (not handlers.go) so route handlers stay
// untouched. The route label is resolved via mux.Handler BEFORE serving — it
// returns the registered pattern, never the raw path, which bounds cardinality
// and keeps device IDs / enroll nonces / poll handles out of label values.
func InstrumentHTTP(mux *http.ServeMux) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		route := "unmatched"
		if _, pattern := mux.Handler(r); pattern != "" {
			route = pattern
		}
		sw := &statusCapturingWriter{ResponseWriter: w}
		mux.ServeHTTP(sw, r)
		mHTTPRequests.WithLabelValues(route, strconv.Itoa(sw.status())).Inc()
	})
}

// statusCapturingWriter records the status code written by the handler while
// preserving http.Hijacker: the WebSocket upgrade paths (agent control/data,
// client connect) MUST be able to hijack the underlying conn, and
// coder/websocket writes its 101 via WriteHeader before hijacking — so
// upgrades are labeled 101 for free. Unwrap is implemented too, so
// http.ResponseController-based callers reach the real writer.
type statusCapturingWriter struct {
	http.ResponseWriter
	code        int
	wroteHeader bool
}

func (w *statusCapturingWriter) WriteHeader(code int) {
	if !w.wroteHeader {
		w.code = code
		w.wroteHeader = true
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusCapturingWriter) Write(p []byte) (int, error) {
	if !w.wroteHeader {
		// Implicit 200 on first write, mirroring net/http.
		w.code = http.StatusOK
		w.wroteHeader = true
	}
	return w.ResponseWriter.Write(p)
}

// status returns the recorded code, defaulting to 200 for handlers that never
// write anything (net/http sends 200 on their behalf).
func (w *statusCapturingWriter) status() int {
	if !w.wroteHeader {
		return http.StatusOK
	}
	return w.code
}

// Hijack forwards to the underlying writer's Hijacker. Required so WebSocket
// upgrades keep working through the middleware.
func (w *statusCapturingWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hj, ok := w.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("underlying ResponseWriter does not implement http.Hijacker")
	}
	return hj.Hijack()
}

// Flush forwards to the underlying writer if it supports flushing (the enroll
// HTML pages and long polls don't need it, but be a good citizen).
func (w *statusCapturingWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Unwrap exposes the underlying writer for http.ResponseController users.
func (w *statusCapturingWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}
