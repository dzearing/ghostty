//! Shared helpers for the agent's test suites (imported only from test code).
//!
//! The wall-clock wait discipline itself (T346/T258) lives one level up in
//! `src/remote/test_util.zig` since T498, so the non-agent lanes share the
//! same helpers; this file re-exports them for the agent-side importers
//! (both agent test binaries root at `src/`, so the relative import is in
//! bounds).

const shared = @import("../test_util.zig");

pub const liveness_ns = shared.liveness_ns;
pub const waitUntil = shared.waitUntil;
pub const waitEvent = shared.waitEvent;
pub const drainRing = shared.drainRing;
