package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// doJSON issues an authenticated request with an optional JSON body and
// returns the response. The caller must close resp.Body.
func doJSON(t *testing.T, method, url, token, body string) *http.Response {
	t.Helper()

	var rdr *strings.Reader
	if body != "" {
		rdr = strings.NewReader(body)
	} else {
		rdr = strings.NewReader("")
	}
	req, err := http.NewRequest(method, url, rdr)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	return resp
}

// listDevices fetches /v1/client/devices and returns id -> name.
func listDevices(t *testing.T, ts *httptest.Server, token string) map[string]string {
	t.Helper()

	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/client/devices", token, "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list status = %d, want 200", resp.StatusCode)
	}

	var out struct {
		Devices []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"devices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	m := make(map[string]string, len(out.Devices))
	for _, d := range out.Devices {
		m[d.ID] = d.Name
	}
	return m
}

// listDeviceViews fetches /v1/client/devices and returns id -> full device view.
func listDeviceViews(t *testing.T, ts *httptest.Server, token string) map[string]deviceView {
	t.Helper()

	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/client/devices", token, "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list status = %d, want 200", resp.StatusCode)
	}

	var out struct {
		Devices []deviceView `json:"devices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	m := make(map[string]deviceView, len(out.Devices))
	for _, d := range out.Devices {
		m[d.ID] = d
	}
	return m
}

// TestDeviceHostname covers the hostname field end to end: device-code enroll
// seeds it from the machine name at creation, the list endpoint returns it,
// rename changes ONLY the display name (hostname preserved), and an agent
// control connect carrying X-Ghoztty-Hostname upserts it.
func TestDeviceHostname(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	ts, clientToken, store := newTestServer(t)

	// Device-code self-enroll path (UpsertDevice) seeds hostname = name. Seed
	// with the dev caller's own sub ("dev") so the sub-keyed ownership scoping
	// (ListByOwnerIdent / RenameDeviceByOwner) sees it as the caller's device.
	dev, deviceToken, err := store.UpsertDevice("dev@example.com", "dev", "windows-home")
	if err != nil {
		t.Fatalf("upsert device: %v", err)
	}
	if dev.Hostname != "windows-home" {
		t.Fatalf("enrolled hostname = %q, want %q", dev.Hostname, "windows-home")
	}

	// The list endpoint returns the hostname.
	if got := listDeviceViews(t, ts, clientToken)[dev.ID]; got.Hostname != "windows-home" {
		t.Fatalf("list hostname = %q, want %q", got.Hostname, "windows-home")
	}

	// Rename changes only the display name; hostname is preserved, and the
	// rename response itself carries the (unchanged) hostname.
	resp := doJSON(t, http.MethodPatch, ts.URL+"/v1/client/devices/"+dev.ID, clientToken, `{"name":"MaximusHome"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("rename status = %d, want 200", resp.StatusCode)
	}
	var renamed deviceView
	if err := json.NewDecoder(resp.Body).Decode(&renamed); err != nil {
		t.Fatalf("decode rename resp: %v", err)
	}
	if renamed.Name != "MaximusHome" || renamed.Hostname != "windows-home" {
		t.Fatalf("rename resp = %+v, want name=MaximusHome hostname=windows-home", renamed)
	}
	if got := listDeviceViews(t, ts, clientToken)[dev.ID]; got.Name != "MaximusHome" || got.Hostname != "windows-home" {
		t.Fatalf("after rename list shows %+v, want name=MaximusHome hostname=windows-home", got)
	}

	// An agent control connect with X-Ghoztty-Hostname updates the hostname
	// (the machine was renamed at the OS level, say).
	hdr := bearerHeader(deviceToken)
	hdr.Set("X-Ghoztty-Hostname", "windows-home-2")
	control, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: hdr,
	})
	if err != nil {
		t.Fatalf("agent control dial: %v", err)
	}
	defer control.CloseNow()

	got := listDeviceViews(t, ts, clientToken)[dev.ID]
	if got.Hostname != "windows-home-2" {
		t.Fatalf("hostname after control connect = %q, want %q", got.Hostname, "windows-home-2")
	}
	if got.Name != "MaximusHome" {
		t.Fatalf("name after control connect = %q, want %q (header must not touch name)", got.Name, "MaximusHome")
	}
	if !got.Online {
		t.Fatalf("device not online after control connect")
	}

	// A control connect WITHOUT the header (older agent) leaves it untouched.
	control.CloseNow()
	control2, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent control redial: %v", err)
	}
	defer control2.CloseNow()
	if got := listDeviceViews(t, ts, clientToken)[dev.ID]; got.Hostname != "windows-home-2" {
		t.Fatalf("hostname after headerless connect = %q, want %q", got.Hostname, "windows-home-2")
	}
}

// TestRenameDevice covers PATCH /v1/client/devices/{id}: the new name is
// returned, persisted, and visible in a subsequent list; bad input is a 400
// and an unknown id is a 404.
func TestRenameDevice(t *testing.T) {
	ts, clientToken, _ := newTestServer(t)
	deviceID, _ := enrollDevice(t, ts, clientToken, "oldname")

	resp := doJSON(t, http.MethodPatch, ts.URL+"/v1/client/devices/"+deviceID, clientToken, `{"name":"newname"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("rename status = %d, want 200", resp.StatusCode)
	}
	var out struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode rename resp: %v", err)
	}
	if out.ID != deviceID || out.Name != "newname" {
		t.Fatalf("rename resp = %+v, want id=%s name=newname", out, deviceID)
	}

	if got := listDevices(t, ts, clientToken)[deviceID]; got != "newname" {
		t.Fatalf("list shows name %q after rename, want %q", got, "newname")
	}

	// Empty name is rejected.
	resp2 := doJSON(t, http.MethodPatch, ts.URL+"/v1/client/devices/"+deviceID, clientToken, `{"name":""}`)
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusBadRequest {
		t.Fatalf("empty-name rename status = %d, want 400", resp2.StatusCode)
	}

	// Unknown device id is a 404.
	resp3 := doJSON(t, http.MethodPatch, ts.URL+"/v1/client/devices/no-such-id", clientToken, `{"name":"x"}`)
	resp3.Body.Close()
	if resp3.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown-id rename status = %d, want 404", resp3.StatusCode)
	}
}

// TestDeleteDevice covers DELETE /v1/client/devices/{id}: the device vanishes
// from the list and a repeat delete is a 404 (it is gone, not idempotent-200).
func TestDeleteDevice(t *testing.T) {
	ts, clientToken, _ := newTestServer(t)
	deviceID, _ := enrollDevice(t, ts, clientToken, "doomedbox")

	resp := doJSON(t, http.MethodDelete, ts.URL+"/v1/client/devices/"+deviceID, clientToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204", resp.StatusCode)
	}

	if _, ok := listDevices(t, ts, clientToken)[deviceID]; ok {
		t.Fatalf("device %s still listed after delete", deviceID)
	}

	// Deleting again: the device no longer exists.
	resp2 := doJSON(t, http.MethodDelete, ts.URL+"/v1/client/devices/"+deviceID, clientToken, "")
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusNotFound {
		t.Fatalf("second delete status = %d, want 404", resp2.StatusCode)
	}
}

// TestDeleteRevokesCredential proves delete is a real revocation: the live
// control connection is severed immediately, and the deleted device's token
// gets 401 on every agent endpoint afterwards (it cannot reconnect or
// re-register as that resource).
func TestDeleteRevokesCredential(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	ts, clientToken, _ := newTestServer(t)
	deviceID, deviceToken := enrollDevice(t, ts, clientToken, "revokedbox")

	// Agent comes online.
	control, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent control dial: %v", err)
	}
	defer control.CloseNow()

	// Delete the device while its agent is connected.
	resp := doJSON(t, http.MethodDelete, ts.URL+"/v1/client/devices/"+deviceID, clientToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204", resp.StatusCode)
	}

	// The live control connection is closed by the relay.
	readCtx, readCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readCancel()
	if _, _, err := control.Read(readCtx); err == nil {
		t.Fatalf("expected control read to fail after delete (connection kicked)")
	}

	// The revoked token can no longer authenticate on any agent endpoint.
	for _, path := range []string{"/v1/agent/control", "/v1/agent/data?session=whatever"} {
		_, dialResp, err := websocket.Dial(ctx, wsURL(ts.URL, path), &websocket.DialOptions{
			HTTPHeader: bearerHeader(deviceToken),
		})
		if err == nil {
			t.Fatalf("expected %s dial with revoked token to fail", path)
		}
		if dialResp == nil || dialResp.StatusCode != http.StatusUnauthorized {
			got := 0
			if dialResp != nil {
				got = dialResp.StatusCode
			}
			t.Fatalf("%s with revoked token status = %d, want 401", path, got)
		}
	}
}

// TestCrudOwnerScoping proves rename/delete are strictly owner-scoped: the
// authenticated dev identity gets a 404 (not-enumerable) for a device owned by
// someone else, and the device is untouched.
func TestCrudOwnerScoping(t *testing.T) {
	ts, clientToken, store := newTestServer(t)

	// Seed a device owned by a DIFFERENT identity, directly in the store.
	other, _, err := store.CreateDevice("other@example.com", "", "otherbox")
	if err != nil {
		t.Fatalf("seed other-owner device: %v", err)
	}

	// Rename attempt by the dev identity: 404, name unchanged.
	resp := doJSON(t, http.MethodPatch, ts.URL+"/v1/client/devices/"+other.ID, clientToken, `{"name":"stolen"}`)
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("cross-owner rename status = %d, want 404", resp.StatusCode)
	}
	if got := store.Get(other.ID); got == nil || got.Name != "otherbox" {
		t.Fatalf("cross-owner rename mutated the device: %+v", got)
	}

	// Delete attempt by the dev identity: 404, device still present.
	resp2 := doJSON(t, http.MethodDelete, ts.URL+"/v1/client/devices/"+other.ID, clientToken, "")
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusNotFound {
		t.Fatalf("cross-owner delete status = %d, want 404", resp2.StatusCode)
	}
	if store.Get(other.ID) == nil {
		t.Fatalf("cross-owner delete removed the device")
	}
}

// TestConnectOwnerScoping proves the SESSION-OPEN path — the one that actually
// reaches a shell — is owner-scoped: a caller cannot open a connection to a
// device owned by a different account even if it knows the device ID. The
// ownership check (handlers.go, dev.OwnerEmail != email) returns a
// non-enumerable 404 before any WebSocket upgrade or online check. This is the
// highest-value authorization gate, so it gets a direct regression test.
func TestConnectOwnerScoping(t *testing.T) {
	ts, clientToken, store := newTestServer(t)

	// A device owned by a DIFFERENT identity than the dev caller.
	other, _, err := store.CreateDevice("other@example.com", "", "otherbox")
	if err != nil {
		t.Fatalf("seed other-owner device: %v", err)
	}

	// The dev identity (dev@example.com) tries to open a session to it. A plain
	// GET reaches the ownership gate before the WS upgrade, so we can assert on
	// the status code directly.
	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/client/connect?device="+other.ID, clientToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("cross-account connect status = %d, want 404", resp.StatusCode)
	}

	// The device is untouched — the 404 hid it, it was not removed.
	if store.Get(other.ID) == nil {
		t.Fatalf("cross-account connect mutated/removed the device")
	}
}
