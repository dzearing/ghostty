//! Aggregator for the pure, std-only helpers under `src/build/`.
//!
//! The main test binary roots at `src/main.zig` and therefore reaches none of
//! the build logic — so a `test` block written next to a build helper used to
//! run in no step at all. This module is what `zig build test` runs it from.
//!
//! Only helpers that import nothing but `std` belong here: the point is that
//! their decisions are asserted on every lane and every seat, including the
//! ones whose host could never reproduce the condition being guarded against.

test {
    _ = @import("drive_check.zig");
}
