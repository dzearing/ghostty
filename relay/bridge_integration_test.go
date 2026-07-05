package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// newTestServer wires up the full relay with DEV_AUTH enabled and returns an
// httptest server, the dev client token, and the backing store (so tests can
// seed devices for other owners). No Google or Caddy involved.
func newTestServer(t *testing.T) (*httptest.Server, string, *Store) {
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
	store, err := LoadStore(cfg.DBPath(), cfg.DevicesPath(), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	// Mirror main.go: bind the invite-code gate (no-op unless INVITE_SIGNUP).
	auth.SetGate(NewSigninGate(cfg, store, logger))
	dir := NewDirectory(logger)
	h := NewHandler(cfg, auth, store, dir, logger)

	mux := http.NewServeMux()
	h.Register(mux)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)

	return ts, cfg.DevClientToken, store
}

func wsURL(httpURL, path string) string {
	return "ws" + strings.TrimPrefix(httpURL, "http") + path
}

// enrollDevice POSTs to /v1/client/devices and returns (deviceID, rawToken).
func enrollDevice(t *testing.T, ts *httptest.Server, clientToken, name string) (string, string) {
	t.Helper()

	body := strings.NewReader(`{"name":"` + name + `"}`)
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/client/devices", body)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+clientToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("enroll: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("enroll status = %d, want 201", resp.StatusCode)
	}

	var out struct {
		ID    string `json:"id"`
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode enroll resp: %v", err)
	}
	if out.ID == "" || out.Token == "" {
		t.Fatalf("enroll returned empty id/token")
	}
	return out.ID, out.Token
}

// TestBridgeEndToEnd proves the full rendezvous + bridge without Google/Caddy:
// enroll a device, open the agent control WS, open the client connect WS, and
// verify bytes round-trip in both directions through the bridge.
func TestBridgeEndToEnd(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	ts, clientToken, _ := newTestServer(t)
	deviceID, deviceToken := enrollDevice(t, ts, clientToken, "testbox")

	// 1. Agent opens its control WS.
	control, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent control dial: %v", err)
	}
	defer control.Close(websocket.StatusNormalClosure, "")

	// 2. Client opens its connect WS. Dial returns at the 101 upgrade, before
	//    the handler sends the open command, so this does not block.
	client, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/client/connect?device="+deviceID), &websocket.DialOptions{
		HTTPHeader: bearerHeader(clientToken),
	})
	if err != nil {
		t.Fatalf("client connect dial: %v", err)
	}
	defer client.Close(websocket.StatusNormalClosure, "")

	// 3. Agent reads the "open" command off the control channel.
	_, raw, err := control.Read(ctx)
	if err != nil {
		t.Fatalf("read open command: %v", err)
	}
	var cmd struct {
		Type    string `json:"type"`
		Session string `json:"session"`
	}
	if err := json.Unmarshal(raw, &cmd); err != nil {
		t.Fatalf("unmarshal open command: %v", err)
	}
	if cmd.Type != "open" || cmd.Session == "" {
		t.Fatalf("unexpected control command: %+v", cmd)
	}

	// 4. Agent dials back its data WS for that session.
	data, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/data?session="+cmd.Session), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent data dial: %v", err)
	}
	defer data.Close(websocket.StatusNormalClosure, "")

	// 5. Client -> agent.
	clientPayload := []byte("hello from client")
	if err := client.Write(ctx, websocket.MessageBinary, clientPayload); err != nil {
		t.Fatalf("client write: %v", err)
	}
	typ, got, err := data.Read(ctx)
	if err != nil {
		t.Fatalf("agent data read: %v", err)
	}
	if typ != websocket.MessageBinary || string(got) != string(clientPayload) {
		t.Fatalf("agent got %q (%v), want %q", got, typ, clientPayload)
	}

	// 6. Agent -> client (reply flows back through the bridge).
	agentReply := []byte("reply from agent")
	if err := data.Write(ctx, websocket.MessageBinary, agentReply); err != nil {
		t.Fatalf("agent write: %v", err)
	}
	_, got2, err := client.Read(ctx)
	if err != nil {
		t.Fatalf("client read: %v", err)
	}
	if string(got2) != string(agentReply) {
		t.Fatalf("client got %q, want %q", got2, agentReply)
	}
}

// TestUnauthorizedRejected confirms fail-closed behavior on the client paths.
func TestUnauthorizedRejected(t *testing.T) {
	ts, _, _ := newTestServer(t)

	// No token.
	resp, err := http.Get(ts.URL + "/v1/client/devices")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no-token status = %d, want 401", resp.StatusCode)
	}

	// Wrong token.
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/client/devices", nil)
	req.Header.Set("Authorization", "Bearer not-the-dev-token")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusUnauthorized {
		t.Fatalf("bad-token status = %d, want 401", resp2.StatusCode)
	}
}

// TestConnectOfflineDevice confirms a connect to an enrolled-but-offline device
// is refused (no agent control connection present).
func TestConnectOfflineDevice(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	ts, clientToken, _ := newTestServer(t)
	deviceID, _ := enrollDevice(t, ts, clientToken, "offlinebox")

	_, resp, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/client/connect?device="+deviceID), &websocket.DialOptions{
		HTTPHeader: bearerHeader(clientToken),
	})
	if err == nil {
		t.Fatalf("expected dial to fail for offline device")
	}
	if resp == nil || resp.StatusCode != http.StatusConflict {
		got := 0
		if resp != nil {
			got = resp.StatusCode
		}
		t.Fatalf("offline connect status = %d, want 409", got)
	}
}

func bearerHeader(token string) http.Header {
	h := http.Header{}
	h.Set("Authorization", "Bearer "+token)
	return h
}
