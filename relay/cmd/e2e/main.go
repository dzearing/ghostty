// Command e2e is a smoke test for a deployed ghoztty-relay. It enrolls a device,
// opens an agent control+data connection, opens a client connection, and verifies
// a byte payload round-trips through the bridge over the real (w)ss path.
//
// Usage:
//
//	go run ./cmd/e2e -base https://relay.example.com -token <DEV_CLIENT_TOKEN>
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
)

func main() {
	base := flag.String("base", "", "relay base URL, e.g. https://relay.example.com")
	token := flag.String("token", "", "client bearer token (DEV_CLIENT_TOKEN or a Google ID token)")
	flag.Parse()
	if *base == "" || *token == "" {
		log.Fatal("need -base and -token")
	}
	httpBase := strings.TrimRight(*base, "/")
	wsBase := "wss" + strings.TrimPrefix(httpBase, "https")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// 1. Enroll a device (client/OIDC auth).
	devID, devToken := enroll(ctx, httpBase, *token)
	fmt.Printf("✓ enrolled device id=%s\n", devID)

	// 2. Agent: open control, on "open" dial the data conn and echo bytes.
	agentReady := make(chan struct{})
	go runAgent(ctx, wsBase, devToken, agentReady)
	<-agentReady
	fmt.Println("✓ agent control connection online")

	// 3. Client: connect to the device and round-trip a payload through the bridge.
	cc, _, err := websocket.Dial(ctx, wsBase+"/v1/client/connect?device="+devID, authOpts(*token))
	if err != nil {
		log.Fatalf("client connect: %v", err)
	}
	defer cc.CloseNow()

	payload := []byte("hello-through-the-relay")
	if err := cc.Write(ctx, websocket.MessageBinary, payload); err != nil {
		log.Fatalf("client write: %v", err)
	}
	typ, got, err := cc.Read(ctx)
	if err != nil {
		log.Fatalf("client read: %v", err)
	}
	if typ != websocket.MessageBinary || !bytes.Equal(got, append([]byte("echo:"), payload...)) {
		log.Fatalf("✗ unexpected reply: typ=%v data=%q", typ, got)
	}
	fmt.Printf("✓ bridge round-trip OK: sent %q, got %q\n", payload, got)
	fmt.Println("\nALL CHECKS PASSED — relay bridge works end-to-end over WSS")
}

func enroll(ctx context.Context, httpBase, token string) (id, devToken string) {
	body, _ := json.Marshal(map[string]string{"name": "e2e-smoketest"})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, httpBase+"/v1/client/devices", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Fatalf("enroll: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		log.Fatalf("enroll: status %d", resp.StatusCode)
	}
	var out struct {
		ID    string `json:"id"`
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		log.Fatalf("enroll decode: %v", err)
	}
	return out.ID, out.Token
}

// runAgent opens the control channel and, on each "open" command, dials a data
// connection for the session and echoes received bytes back (prefixed "echo:").
func runAgent(ctx context.Context, wsBase, devToken string, ready chan struct{}) {
	ctrl, _, err := websocket.Dial(ctx, wsBase+"/v1/agent/control", authOpts(devToken))
	if err != nil {
		log.Fatalf("agent control dial: %v", err)
	}
	close(ready)
	for {
		typ, data, err := ctrl.Read(ctx)
		if err != nil {
			return
		}
		if typ != websocket.MessageText {
			continue
		}
		var msg struct{ Type, Session string }
		if json.Unmarshal(data, &msg) == nil && msg.Type == "open" {
			go echoData(ctx, wsBase, devToken, msg.Session)
		}
	}
}

func echoData(ctx context.Context, wsBase, devToken, session string) {
	dc, _, err := websocket.Dial(ctx, wsBase+"/v1/agent/data?session="+session, authOpts(devToken))
	if err != nil {
		log.Printf("agent data dial: %v", err)
		return
	}
	defer dc.CloseNow()
	for {
		typ, data, err := dc.Read(ctx)
		if err != nil {
			return
		}
		if err := dc.Write(ctx, typ, append([]byte("echo:"), data...)); err != nil {
			return
		}
	}
}

func authOpts(token string) *websocket.DialOptions {
	return &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}}
}
