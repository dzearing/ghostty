//! Root source for the `remote-test-client` executable (WP: TCP transport, and
//! the T89c Windows named-pipe path). It lives under `src/` (not
//! `src/remote/`) so the client module is rooted at `src/` — the SAME reason
//! `src/agent_main.zig` exists for the agent: `src/remote/socket_stream.zig`
//! imports `agent/server.zig`, whose transitive graph (`session.zig` →
//! `grid_snapshot.zig`) reaches `src/terminal/*` via `../../terminal`. Rooted at
//! `src/remote/` that escapes the module path ("import of file outside module
//! path", which is why the client never built for Windows); rooted at `src/` it
//! stays inside, and the shared C deps (pty-c + os libs) are wired the same way
//! the agent wires them.
//!
//! The actual entry point + client logic live in `remote/test_client.zig`.

const client = @import("remote/test_client.zig");

pub const main = client.main;

test {
    @import("std").testing.refAllDecls(client);
}
