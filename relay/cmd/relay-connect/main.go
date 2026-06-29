// Command relay-connect is the CLIENT-side relay helper, designed to be used as
// an ssh ProxyCommand:
//
//	ssh -o ProxyCommand="relay-connect -base https://relay -device <id>" <device>
//
// It opens an authenticated /v1/client/connect WebSocket to the relay and splices
// it to this process's stdin/stdout. SSH then runs its handshake END-TO-END with
// the remote sshd over this pipe — the relay only ever sees SSH ciphertext.
//
// Auth: the client bearer token is read from $GHOZTTY_RELAY_TOKEN (a Google ID
// token in production, or the DEV_CLIENT_TOKEN during bring-up).
package main

import (
	"context"
	"flag"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/coder/websocket"
)

func main() {
	base := flag.String("base", "", "relay base URL, e.g. https://relay.example.com")
	device := flag.String("device", "", "target device id")
	flag.Parse()

	if *base == "" || *device == "" {
		fatal("relay-connect: -base and -device are required")
	}
	token := os.Getenv("GHOZTTY_RELAY_TOKEN")
	if token == "" {
		fatal("relay-connect: GHOZTTY_RELAY_TOKEN is empty")
	}

	wsBase := toWS(*base)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	c, _, err := websocket.Dial(ctx, wsBase+"/v1/client/connect?device="+*device, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": {"Bearer " + token}},
	})
	if err != nil {
		fatal("relay-connect: dial: " + err.Error())
	}
	defer c.CloseNow()

	// Splice the WS (as a net.Conn) to stdin/stdout. When either side closes,
	// cancel the context so the other io.Copy unblocks and we exit.
	conn := websocket.NetConn(ctx, c, websocket.MessageBinary)
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(conn, os.Stdin); done <- struct{}{} }() // ssh -> relay
	go func() { _, _ = io.Copy(os.Stdout, conn); done <- struct{}{} }() // relay -> ssh
	<-done
}

func fatal(msg string) {
	_, _ = os.Stderr.WriteString(msg + "\n")
	os.Exit(1)
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
