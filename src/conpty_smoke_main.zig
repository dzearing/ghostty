//! Root source for the `ghoztty-conpty-smoke` executable (WP2, §13). It lives
//! under `src/` (not `src/remote/agent/`) so the module is rooted at `src/`,
//! letting `src/remote/agent/conpty_smoke.zig` reach `src/pty.zig`,
//! `src/CommandCore.zig`, and `src/os/main.zig` via relative imports — exactly
//! like `src/agent_main.zig` does for the agent daemon.

const smoke = @import("remote/agent/conpty_smoke.zig");

pub const main = smoke.main;
