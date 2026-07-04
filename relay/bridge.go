package main

import (
	"context"
	"io"

	"github.com/coder/websocket"
)

// bridge splices two WebSocket connections into a single bidirectional,
// opaque byte pipe. The relay deliberately does NOT understand the payload
// (SSH ciphertext rides inside); it only forwards bytes.
//
// Each side is adapted to a net.Conn via websocket.NetConn using binary
// framing, then io.Copy runs in both directions. When either direction ends
// (EOF, error, or close), both connections are closed so the peer is torn down.
func bridge(client, agent *websocket.Conn) {
	// A dedicated context, canceled when bridging ends, drives both NetConns.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	clientConn := websocket.NetConn(ctx, client, websocket.MessageBinary)
	agentConn := websocket.NetConn(ctx, agent, websocket.MessageBinary)

	errc := make(chan error, 2)
	go func() {
		_, err := io.Copy(agentConn, clientConn) // client -> agent
		errc <- err
	}()
	go func() {
		_, err := io.Copy(clientConn, agentConn) // agent -> client
		errc <- err
	}()

	// Wait for the first direction to finish, then tear everything down. The
	// second io.Copy unblocks once its underlying conn is closed.
	<-errc
	cancel()
	client.Close(websocket.StatusNormalClosure, "bridge closed")
	agent.Close(websocket.StatusNormalClosure, "bridge closed")
}
