//! Standalone test aggregator for the agent session-server core (WP2). Rooting a
//! `zig test` here (dir = `src/remote/`) lets `agent/server.zig` and
//! `agent/session.zig` reach `protocol.zig` via their `../protocol.zig` relative
//! import without "import outside module path" — the same relative path the real
//! `zig build agent` graph uses. Run:
//!
//!   zig test -Mroot=src/remote/agent_test.zig
//!
//! (No `--dep protocol` needed: protocol is reached relatively, exactly as in the
//! exe build, so the test and the build exercise one consistent module shape.)

test {
    _ = @import("agent/server.zig");
    _ = @import("agent/session.zig");
    _ = @import("agent/grid_snapshot.zig");
    _ = @import("agent/session_meta.zig");
    _ = @import("agent/ring_snapshot.zig");
    _ = @import("agent/metrics.zig");
    _ = @import("agent/keepalive.zig");
    _ = @import("agent/self_update.zig");
    _ = @import("socket_stream.zig");
    _ = @import("socket_rw.zig");
}
