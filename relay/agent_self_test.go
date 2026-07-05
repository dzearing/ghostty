package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// TestAgentWhoami: a device authenticates with its own token and learns which
// account it is bound to (the data the tray shows as "Signed in as <email>").
func TestAgentWhoami(t *testing.T) {
	ts, clientToken, _ := newTestServer(t)
	deviceID, deviceToken := enrollDevice(t, ts, clientToken, "whoamibox")

	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/agent/whoami", deviceToken, "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("whoami status = %d, want 200", resp.StatusCode)
	}

	var out struct {
		Email    string `json:"email"`
		DeviceID string `json:"device_id"`
		Name     string `json:"name"`
		Hostname string `json:"hostname"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode whoami: %v", err)
	}
	if out.Email != "dev@example.com" {
		t.Fatalf("whoami email = %q, want dev@example.com", out.Email)
	}
	if out.DeviceID != deviceID {
		t.Fatalf("whoami device_id = %q, want %q", out.DeviceID, deviceID)
	}
	if out.Name != "whoamibox" {
		t.Fatalf("whoami name = %q, want whoamibox", out.Name)
	}
}

// TestAgentWhoamiUnauthorized: a bogus token cannot learn any account identity.
func TestAgentWhoamiUnauthorized(t *testing.T) {
	ts, _, _ := newTestServer(t)

	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/agent/whoami", "not-a-real-token", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("whoami with bad token = %d, want 401", resp.StatusCode)
	}
}

// TestAgentDeenroll: an agent revokes its own registration. The device is
// removed and its token can never authenticate again (this is the relay side of
// the tray "Sign out").
func TestAgentDeenroll(t *testing.T) {
	ts, clientToken, store := newTestServer(t)
	deviceID, deviceToken := enrollDevice(t, ts, clientToken, "signoutbox")

	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/agent/deenroll", deviceToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("deenroll status = %d, want 204", resp.StatusCode)
	}

	// Device is gone from the store.
	if store.Get(deviceID) != nil {
		t.Fatalf("device still present after self de-enroll")
	}

	// The revoked token no longer authenticates on any agent endpoint.
	resp2 := doJSON(t, http.MethodGet, ts.URL+"/v1/agent/whoami", deviceToken, "")
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusUnauthorized {
		t.Fatalf("whoami after de-enroll = %d, want 401", resp2.StatusCode)
	}

	// A repeat de-enroll with the dead token 401s (token maps to no device).
	resp3 := doJSON(t, http.MethodPost, ts.URL+"/v1/agent/deenroll", deviceToken, "")
	resp3.Body.Close()
	if resp3.StatusCode != http.StatusUnauthorized {
		t.Fatalf("repeat de-enroll = %d, want 401", resp3.StatusCode)
	}
}

// TestAgentDeenrollKicksLiveConnection: self de-enroll severs the live control
// connection, just like a client-initiated delete.
func TestAgentDeenrollKicksLiveConnection(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	ts, clientToken, _ := newTestServer(t)
	_, deviceToken := enrollDevice(t, ts, clientToken, "livebox")

	control, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent control dial: %v", err)
	}
	defer control.CloseNow()

	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/agent/deenroll", deviceToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("deenroll status = %d, want 204", resp.StatusCode)
	}

	readCtx, readCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readCancel()
	if _, _, err := control.Read(readCtx); err == nil {
		t.Fatalf("expected control read to fail after self de-enroll (connection kicked)")
	}
}
