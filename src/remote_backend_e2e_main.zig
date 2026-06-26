//! Root source for the `remote-backend-e2e` executable (WP4 render de-risk). It
//! lives under `src/` (not `src/remote/`) so the module is rooted at `src/`,
//! letting the harness reach the full app graph (`global.zig`, `renderer.zig`,
//! `termio.zig`, `terminal/main.zig`, `apprt.zig`, `config.zig`, `App.zig`) via
//! relative imports — exactly like the GUI. The actual harness lives in
//! `remote/remote_backend_e2e.zig`.

const e2e = @import("remote/remote_backend_e2e.zig");

pub const main = e2e.main;
