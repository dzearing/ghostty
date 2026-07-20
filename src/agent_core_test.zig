//! Thin test root for `zig build test-agent`'s agent-core aggregator.
//!
//! The actual tests live in `remote/agent_test.zig`. This wrapper exists only to
//! root the test module at `src/` (not `src/remote/`) so the session store's
//! grid-snapshot emulator can reach `src/terminal` via its relative
//! `../../terminal/main.zig` import (grid_snapshot.zig) without escaping the
//! module path — the same reason `src/agent_main.zig` roots the agent exe at
//! `src/`.
test {
    _ = @import("remote/agent_test.zig");
}
