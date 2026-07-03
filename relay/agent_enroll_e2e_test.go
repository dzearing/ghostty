package main

// Drives the REAL Zig `ghoztty-agent --enroll` binary end-to-end against this
// relay wired to the fake Google issuer (the same infrastructure as
// enroll_test.go and enroll_web_test.go) — proving the agent half over a live
// HTTP relay, for BOTH flows:
//
//   - device-code (TestAgentEnrollE2E): the relay has no web client, so the
//     agent's web-first start 503s and it falls back — start → printed user
//     code → owner approval → poll → complete → relay.env persisted → the
//     issued token authenticates the agent control WS.
//   - web (TestAgentEnrollWebE2E): the agent prints the enroll link (browser
//     auto-open suppressed via GHOZTTY_ENROLL_NO_OPEN); the test plays the
//     browser (redirect → callback) and the agent's poll completes.
//
// Gated on GHOZTTY_AGENT_BIN so `go test ./...` stays hermetic (no Zig
// toolchain required). Run them with:
//
//	(cd .. && zig build agent)
//	GHOZTTY_AGENT_BIN=$PWD/../zig-out/bin/ghoztty-agent go test -run TestAgentEnroll -v .

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

var userCodeRe = regexp.MustCompile(`and enter code: (\S+)`)

func TestAgentEnrollE2E(t *testing.T) {
	bin := os.Getenv("GHOZTTY_AGENT_BIN")
	if bin == "" {
		t.Skip("set GHOZTTY_AGENT_BIN=<path to ghoztty-agent> to run the live agent enroll e2e")
	}

	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	ts, store, _ := newEnrollTestServer(t, f)

	envFile := filepath.Join(t.TempDir(), "relay.env")
	cmd := exec.Command(bin, "--enroll", "--relay="+ts.URL)
	cmd.Env = append(os.Environ(), "GHOSTTY_RELAY_ENV="+envFile)
	cmd.Stderr = os.Stderr

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start agent: %v", err)
	}
	defer cmd.Process.Kill() //nolint:errcheck // cleanup on failure paths

	// Stream the agent's stdout: approve the grant the moment the user code is
	// printed (the fake equivalent of the owner completing the Google sign-in),
	// and collect everything for the final assertions.
	lines := make(chan string, 64)
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()

	var all []string
	approved := false
	deadline := time.After(60 * time.Second)
	for {
		select {
		case line, ok := <-lines:
			if !ok {
				goto done
			}
			t.Logf("agent: %s", line)
			all = append(all, line)
			if m := userCodeRe.FindStringSubmatch(line); m != nil && !approved {
				g.setOutcome(t, m[1], "approved", mint(t, f.key, f.validClaims()))
				approved = true
			}
		case <-deadline:
			t.Fatal("timed out waiting for the agent enroll flow to finish")
		}
	}
done:
	if err := cmd.Wait(); err != nil {
		t.Fatalf("agent exited with error: %v\noutput:\n%s", err, strings.Join(all, "\n"))
	}
	if !approved {
		t.Fatalf("agent never printed a user code; output:\n%s", strings.Join(all, "\n"))
	}

	out := strings.Join(all, "\n")
	if !strings.Contains(out, "this relay has no browser sign-in; using the code flow") {
		t.Errorf("missing web->device fallback notice in agent output:\n%s", out)
	}
	if !strings.Contains(out, "To add this machine to your account, visit https://www.google.com/device") {
		t.Errorf("missing verification prompt in agent output:\n%s", out)
	}
	if !strings.Contains(out, "Enrolled as device ") {
		t.Errorf("missing enrollment confirmation in agent output:\n%s", out)
	}
	if !strings.Contains(out, "Start the agent with: ghoztty-agent --relay=https://relay.test") {
		t.Errorf("missing start hint (with the relay's advertised base) in agent output:\n%s", out)
	}

	// The agent persisted the credential to its relay.env.
	raw, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatalf("agent did not write relay.env: %v", err)
	}
	var relayBase, deviceToken string
	for _, line := range strings.Split(string(raw), "\n") {
		if v, ok := strings.CutPrefix(line, "RELAY_BASE="); ok {
			relayBase = strings.TrimSpace(v)
		}
		if v, ok := strings.CutPrefix(line, "DEVICE_TOKEN="); ok {
			deviceToken = strings.TrimSpace(v)
		}
	}
	if relayBase != "https://relay.test" {
		t.Errorf("relay.env RELAY_BASE = %q, want the relay's advertised base https://relay.test", relayBase)
	}
	if deviceToken == "" {
		t.Fatalf("relay.env has no DEVICE_TOKEN:\n%s", raw)
	}

	// The device exists, is owned by the verified identity, and its persisted
	// token authenticates the agent control WS.
	devs := store.ListByOwner(allowedEmail)
	if len(devs) != 1 {
		t.Fatalf("owner has %d devices after agent enroll, want 1", len(devs))
	}
	c, status := dialControl(t, ts, deviceToken)
	if c == nil {
		t.Fatalf("persisted device token rejected on /v1/agent/control (status %d)", status)
	}
	c.CloseNow()
}

var enrollURLRe = regexp.MustCompile(`visit: (\S+)`)

// TestAgentEnrollWebE2E: the real agent binary against a web-enroll-enabled
// relay. The agent asks for the web flow, prints the enroll link (auto-open
// suppressed), and the test plays the owner's browser: follow the link, get
// the Google redirect, come back through the callback with a valid code. The
// agent's unchanged poll loop must then complete and persist relay.env.
func TestAgentEnrollWebE2E(t *testing.T) {
	bin := os.Getenv("GHOZTTY_AGENT_BIN")
	if bin == "" {
		t.Skip("set GHOZTTY_AGENT_BIN=<path to ghoztty-agent> to run the live agent web enroll e2e")
	}

	f := newFakeIssuer(t)
	g := newFakeGoogleWebFlow(f)
	ts, store, _ := newEnrollTestServer(t, f, withWebClient)

	envFile := filepath.Join(t.TempDir(), "relay.env")
	cmd := exec.Command(bin, "--enroll", "--relay="+ts.URL)
	cmd.Env = append(os.Environ(),
		"GHOSTTY_RELAY_ENV="+envFile,
		// Never pop a real browser on the machine running the tests.
		"GHOZTTY_ENROLL_NO_OPEN=1",
	)
	cmd.Stderr = os.Stderr

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start agent: %v", err)
	}
	defer cmd.Process.Kill() //nolint:errcheck // cleanup on failure paths

	lines := make(chan string, 64)
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()

	var all []string
	browsed := false
	deadline := time.After(60 * time.Second)
	for {
		select {
		case line, ok := <-lines:
			if !ok {
				goto done
			}
			t.Logf("agent: %s", line)
			all = append(all, line)
			if m := enrollURLRe.FindStringSubmatch(line); m != nil && !browsed {
				// Play the browser: entry link -> Google redirect -> callback.
				state := authRedirect(t, ts, f, m[1])
				claims := f.validClaims()
				claims["aud"] = testWebClientID
				code := g.newCode(mint(t, f.key, claims))
				if status, _, page := browsePath(t, ts, callbackPath(code, state)); status != 200 {
					t.Errorf("callback status = %d, page:\n%s", status, page)
				}
				browsed = true
			}
		case <-deadline:
			t.Fatal("timed out waiting for the agent web enroll flow to finish")
		}
	}
done:
	if err := cmd.Wait(); err != nil {
		t.Fatalf("agent exited with error: %v\noutput:\n%s", err, strings.Join(all, "\n"))
	}
	if !browsed {
		t.Fatalf("agent never printed an enroll link; output:\n%s", strings.Join(all, "\n"))
	}

	out := strings.Join(all, "\n")
	if strings.Contains(out, "enter code") {
		t.Errorf("web flow printed a device-code prompt:\n%s", out)
	}
	if !strings.Contains(out, "Enrolled as device ") {
		t.Errorf("missing enrollment confirmation in agent output:\n%s", out)
	}

	raw, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatalf("agent did not write relay.env: %v", err)
	}
	var deviceToken string
	for _, line := range strings.Split(string(raw), "\n") {
		if v, ok := strings.CutPrefix(line, "DEVICE_TOKEN="); ok {
			deviceToken = strings.TrimSpace(v)
		}
	}
	if deviceToken == "" {
		t.Fatalf("relay.env has no DEVICE_TOKEN:\n%s", raw)
	}

	if devs := store.ListByOwner(allowedEmail); len(devs) != 1 {
		t.Fatalf("owner has %d devices after web enroll, want 1", len(devs))
	}
	c, status := dialControl(t, ts, deviceToken)
	if c == nil {
		t.Fatalf("web-enrolled token rejected on /v1/agent/control (status %d)", status)
	}
	c.CloseNow()
}
