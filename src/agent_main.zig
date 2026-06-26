//! Root source for the `ghoztty-agent` executable (WP2). It lives under `src/`
//! (not `src/remote/agent/`) so the agent module is rooted at `src/`, letting
//! `src/remote/agent/pty_child.zig` reach `src/pty.zig` and `src/CommandCore.zig`
//! via relative imports while the GUI-free `protocol` module stays a named import.
//! The actual entry point + transport live in `remote/agent/main.zig`.

const agent = @import("remote/agent/main.zig");

pub const main = agent.main;

test {
    @import("std").testing.refAllDecls(agent);
}
