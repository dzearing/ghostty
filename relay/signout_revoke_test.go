package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// --- helpers ---------------------------------------------------------------

// signOutSession POSTs /oauth/signout with the given relay session token —
// exactly what RelayAccount.signOut() does today.
func signOutSession(t *testing.T, ts *httptest.Server, sessionToken string) {
	t.Helper()
	resp := doJSON(t, http.MethodPost, ts.URL+"/oauth/signout", sessionToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("signout status = %d, want 204", resp.StatusCode)
	}
}

// listDeviceIDs GETs /v1/client/devices as the given client and returns the ids.
func listDeviceIDs(t *testing.T, ts *httptest.Server, clientToken string) []string {
	t.Helper()
	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/client/devices", clientToken, "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list devices status = %d, want 200", resp.StatusCode)
	}
	var out struct {
		Devices []struct {
			ID     string `json:"id"`
			Online bool   `json:"online"`
		} `json:"devices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode devices: %v", err)
	}
	ids := make([]string, 0, len(out.Devices))
	for _, d := range out.Devices {
		ids = append(ids, d.ID)
	}
	return ids
}

func contains(ids []string, want string) bool {
	for _, id := range ids {
		if id == want {
			return true
		}
	}
	return false
}

// liveBridge brings a device online and establishes one bridged client<->agent
// session through the relay, returning the client and agent-data ends with a
// byte already proven to flow. The control conn is returned so callers can
// assert it gets kicked.
func liveBridge(t *testing.T, ctx context.Context, ts *httptest.Server, clientToken, deviceID, deviceToken string) (client, data, control *websocket.Conn) {
	t.Helper()

	control, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent control dial: %v", err)
	}

	client, _, err = websocket.Dial(ctx, wsURL(ts.URL, "/v1/client/connect?device="+deviceID), &websocket.DialOptions{
		HTTPHeader: bearerHeader(clientToken),
	})
	if err != nil {
		t.Fatalf("client connect dial: %v", err)
	}

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

	data, _, err = websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/data?session="+cmd.Session), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent data dial: %v", err)
	}

	// Prove the bridge carries bytes before the test does anything to it.
	if err := client.Write(ctx, websocket.MessageBinary, []byte("ping")); err != nil {
		t.Fatalf("client write: %v", err)
	}
	if _, got, err := data.Read(ctx); err != nil || string(got) != "ping" {
		t.Fatalf("bridge did not carry bytes: got %q err %v", got, err)
	}
	return client, data, control
}

// bridgeCarries reports whether a byte still round-trips client -> agent.
func bridgeCarries(ctx context.Context, client, data *websocket.Conn, payload string) bool {
	readCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := client.Write(readCtx, websocket.MessageBinary, []byte(payload)); err != nil {
		return false
	}
	_, got, err := data.Read(readCtx)
	return err == nil && string(got) == payload
}

// --- the bug ---------------------------------------------------------------

// TestSignoutAloneLeavesMachineReachable is the REPRODUCTION of the reported
// security bug: signing out of the account in the app running ON an enrolled
// machine revokes only the caller's user SESSION. The machine's device
// enrollment is untouched, so from any other client on the same account the
// machine is still listed, still online, and a session already bridged to it
// keeps flowing.
//
// This is a characterization test of the relay's (correct, deliberate)
// semantics — /oauth/signout is session-scoped by design, because an account
// may own headless hosts that no app is signed in on. It exists to pin down
// that the relay is NOT where the machine gets revoked, so the client must
// revoke it explicitly (see TestDeenrollRevokesAndKicksLiveBridge).
func TestSignoutAloneLeavesMachineReachable(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	f := newFakeIssuer(t)
	f.tokenHandler = okTokenHandler(t, f)
	ts, _ := newBrokerServer(t, f, []string{allowedEmail})

	// The app on the enrolled machine signs in, and a second client on the
	// same account signs in too.
	appSession := sessionToken(t, ts, f, f.validClaims())
	otherSession := sessionToken(t, ts, f, f.validClaims())
	if appSession == "" || otherSession == "" {
		t.Fatal("expected two session tokens")
	}

	// This machine is enrolled with the relay and its agent is online with a
	// live bridged session to the other client.
	deviceID, deviceToken := enrollDevice(t, ts, appSession, "thisbox")
	client, data, control := liveBridge(t, ctx, ts, otherSession, deviceID, deviceToken)
	defer client.CloseNow()
	defer data.CloseNow()
	defer control.CloseNow()

	// The app signs out — today, this and only this.
	signOutSession(t, ts, appSession)

	// The signed-out session really is dead...
	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/client/devices", appSession, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("signed-out session status = %d, want 401", resp.StatusCode)
	}

	// ...but the machine is untouched. This is the bug, from the other
	// client's point of view.
	if !contains(listDeviceIDs(t, ts, otherSession), deviceID) {
		t.Fatal("device disappeared from the account after signout — relay semantics changed")
	}
	if !bridgeCarries(ctx, client, data, "still-flowing") {
		t.Fatal("bridge died on signout — relay semantics changed")
	}
	// And the device credential still authenticates, so the machine can be
	// sent new instructions.
	who := doJSON(t, http.MethodGet, ts.URL+"/v1/agent/whoami", deviceToken, "")
	who.Body.Close()
	if who.StatusCode != http.StatusOK {
		t.Fatalf("device token after signout = %d, want 200", who.StatusCode)
	}
}

// --- the remedy ------------------------------------------------------------

// TestDeenrollRevokesAndKicksLiveBridge proves the endpoint the client must
// call on sign-out does the whole job: the device is gone from the account,
// its credential can never authenticate again, its control connection is
// severed, AND the in-flight BRIDGED session (the user's actual symptom — live
// session data still visible from another client) is torn down.
func TestDeenrollRevokesAndKicksLiveBridge(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	ts, clientToken, store := newTestServer(t)
	deviceID, deviceToken := enrollDevice(t, ts, clientToken, "signoutbox")
	client, data, control := liveBridge(t, ctx, ts, clientToken, deviceID, deviceToken)
	defer client.CloseNow()
	defer data.CloseNow()
	defer control.CloseNow()

	// Self de-enroll: what the machine's own sign-out performs.
	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/agent/deenroll", deviceToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("deenroll status = %d, want 204", resp.StatusCode)
	}

	// Gone from the store and from every other client's device list.
	if store.Get(deviceID) != nil {
		t.Fatal("device still present after de-enroll")
	}
	if contains(listDeviceIDs(t, ts, clientToken), deviceID) {
		t.Fatal("device still listed to the account after de-enroll")
	}

	// The bridged data connection is severed — the agent end reads an error
	// instead of the next client byte.
	readCtx, readCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readCancel()
	if _, _, err := data.Read(readCtx); err == nil {
		t.Fatal("expected the bridged data conn to be closed by the de-enroll")
	}
	// ...and so is the client end of that same bridge.
	clientCtx, clientCancel := context.WithTimeout(ctx, 5*time.Second)
	defer clientCancel()
	if _, _, err := client.Read(clientCtx); err == nil {
		t.Fatal("expected the client end of the bridge to be closed by the de-enroll")
	}
	// ...and the control connection.
	ctlCtx, ctlCancel := context.WithTimeout(ctx, 5*time.Second)
	defer ctlCancel()
	if _, _, err := control.Read(ctlCtx); err == nil {
		t.Fatal("expected the control conn to be closed by the de-enroll")
	}

	// The credential is dead on every device-authenticated surface.
	for _, path := range []string{"/v1/agent/whoami"} {
		r := doJSON(t, http.MethodGet, ts.URL+path, deviceToken, "")
		r.Body.Close()
		if r.StatusCode != http.StatusUnauthorized {
			t.Fatalf("%s with revoked token = %d, want 401", path, r.StatusCode)
		}
	}
	for _, path := range []string{"/v1/agent/control", "/v1/agent/data?session=whatever"} {
		_, dialResp, err := websocket.Dial(ctx, wsURL(ts.URL, path), &websocket.DialOptions{
			HTTPHeader: bearerHeader(deviceToken),
		})
		if err == nil {
			t.Fatalf("expected %s dial with revoked token to fail", path)
		}
		if dialResp == nil || dialResp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("%s with revoked token did not 401", path)
		}
	}

	// And the machine can no longer be reached at all: a fresh connect 404s.
	_, connResp, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/client/connect?device="+deviceID), &websocket.DialOptions{
		HTTPHeader: bearerHeader(clientToken),
	})
	if err == nil {
		t.Fatal("expected connect to a de-enrolled device to fail")
	}
	if connResp == nil || connResp.StatusCode != http.StatusNotFound {
		t.Fatal("connect to a de-enrolled device did not 404")
	}
}

// TestDeenrollIsIdempotent: a retry of the sign-out revocation with a token
// that is already dead reports 401, which the client treats as "already
// revoked" rather than as a failure to retry forever.
func TestDeenrollIsIdempotent(t *testing.T) {
	ts, clientToken, _ := newTestServer(t)
	_, deviceToken := enrollDevice(t, ts, clientToken, "twicebox")

	first := doJSON(t, http.MethodPost, ts.URL+"/v1/agent/deenroll", deviceToken, "")
	first.Body.Close()
	if first.StatusCode != http.StatusNoContent {
		t.Fatalf("first deenroll = %d, want 204", first.StatusCode)
	}
	second := doJSON(t, http.MethodPost, ts.URL+"/v1/agent/deenroll", deviceToken, "")
	second.Body.Close()
	if second.StatusCode != http.StatusUnauthorized {
		t.Fatalf("second deenroll = %d, want 401", second.StatusCode)
	}
}

// TestEnrollResponseCarriesIdNameAndToken pins the shape the app decodes when
// it restores this machine's enrollment on sign-in
// (`RelayDirectoryClient.Enrolled` in `RelayDirectoryClient.swift`, driven by
// `LocalMachineEnrollment.restoreForSignIn`). That decoder requires all three
// fields, so a relay change that dropped one would silently leave a machine
// unenrolled after every sign-in; this fails loudly instead.
func TestEnrollResponseCarriesIdNameAndToken(t *testing.T) {
	ts, clientToken, _ := newTestServer(t)

	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/client/devices", clientToken,
		`{"name":"restoredbox"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("enroll status = %d, want 201", resp.StatusCode)
	}
	var out struct {
		ID    *string `json:"id"`
		Name  *string `json:"name"`
		Token *string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode enroll: %v", err)
	}
	if out.ID == nil || out.Name == nil || out.Token == nil {
		t.Fatalf("enroll response is missing a field the app requires: %+v", out)
	}
	if *out.Name != "restoredbox" {
		t.Fatalf("enroll name = %q, want restoredbox (the app re-enrolls under the machine's remembered name)", *out.Name)
	}
}

// TestWhoamiResponseCarriesEmailDeviceIdAndName pins the shape the app decodes
// to decide WHOSE machine this is before revoking it
// (`RelayDeviceClient.Identity`). Losing `email` there would turn the
// owner check into a decode failure — and a decode failure is reported as
// "couldn't reach the relay", which BLOCKS sign-out. Worth a test.
func TestWhoamiResponseCarriesEmailDeviceIdAndName(t *testing.T) {
	ts, clientToken, _ := newTestServer(t)
	deviceID, deviceToken := enrollDevice(t, ts, clientToken, "identitybox")

	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/agent/whoami", deviceToken, "")
	defer resp.Body.Close()
	var out struct {
		Email    *string `json:"email"`
		DeviceID *string `json:"device_id"`
		Name     *string `json:"name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode whoami: %v", err)
	}
	if out.Email == nil || out.DeviceID == nil || out.Name == nil {
		t.Fatalf("whoami is missing a field the app requires: %+v", out)
	}
	if *out.DeviceID != deviceID || *out.Name != "identitybox" {
		t.Fatalf("whoami identity = %+v, want device %q named identitybox", out, deviceID)
	}
}
