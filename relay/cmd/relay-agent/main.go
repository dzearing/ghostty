// Command relay-agent is the AGENT-side relay connector. It runs on the remote
// machine, registers the machine as an online device, and bridges each incoming
// session to a local target (by default the machine's own sshd at 127.0.0.1:22).
//
// Flow: hold /v1/agent/control; on each {"type":"open","session":S} command, dial
// /v1/agent/data?session=S AND the local target, then splice them. The client's
// ssh thus reaches this machine's sshd through the relay, fully end-to-end.
//
// Auth: the device token is read from $GHOSTTY_DEVICE_TOKEN (issued once at
// enrollment via POST /v1/client/devices).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/coder/websocket"
)

func main() {
	base := flag.String("base", "", "relay base URL, e.g. https://relay.example.com")
	target := flag.String("target", "127.0.0.1:22", "local TCP target to bridge sessions to")
	flag.Parse()
	if *base == "" {
		log.Fatal("relay-agent: -base is required")
	}
	token := os.Getenv("GHOSTTY_DEVICE_TOKEN")
	if token == "" {
		log.Fatal("relay-agent: GHOSTTY_DEVICE_TOKEN is empty")
	}
	wsBase := toWS(*base)

	// Reconnect loop: if the control connection drops, back off and re-register.
	for {
		if err := run(wsBase, token, *target); err != nil {
			log.Printf("relay-agent: control connection ended: %v; reconnecting in 3s", err)
		}
		time.Sleep(3 * time.Second)
	}
}

func run(wsBase, token, target string) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ctrl, _, err := websocket.Dial(ctx, wsBase+"/v1/agent/control", authOpts(token))
	if err != nil {
		return err
	}
	defer ctrl.CloseNow()
	log.Printf("relay-agent: online, bridging sessions to %s", target)

	for {
		typ, data, err := ctrl.Read(ctx)
		if err != nil {
			return err
		}
		if typ != websocket.MessageText {
			continue
		}
		var msg struct{ Type, Session string }
		if json.Unmarshal(data, &msg) != nil || msg.Type != "open" {
			continue
		}
		go bridgeSession(wsBase, token, target, msg.Session)
	}
}

// bridgeSession dials the relay data conn for the session and the local target,
// then splices them until either side ends.
func bridgeSession(wsBase, token, target, session string) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	dc, _, err := websocket.Dial(ctx, wsBase+"/v1/agent/data?session="+session, authOpts(token))
	if err != nil {
		log.Printf("relay-agent: data dial (session %s): %v", session, err)
		return
	}
	defer dc.CloseNow()

	local, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		log.Printf("relay-agent: local dial %s (session %s): %v", target, session, err)
		dc.Close(websocket.StatusInternalError, "local dial failed")
		return
	}
	defer local.Close()

	relayConn := websocket.NetConn(ctx, dc, websocket.MessageBinary)
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(local, relayConn); done <- struct{}{} }() // client -> sshd
	go func() { _, _ = io.Copy(relayConn, local); done <- struct{}{} }() // sshd -> client
	<-done
}

func authOpts(token string) *websocket.DialOptions {
	return &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}}
}

// toWS converts an http(s) base URL to its ws(s) equivalent.
func toWS(base string) string {
	base = strings.TrimRight(base, "/")
	if s, ok := strings.CutPrefix(base, "https://"); ok {
		return "wss://" + s
	}
	if s, ok := strings.CutPrefix(base, "http://"); ok {
		return "ws://" + s
	}
	return base
}
