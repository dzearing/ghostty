//! The reference-count arithmetic behind split-tree leaf ownership (T371).
//!
//! `SplitTree` drives a `ref`/`unref`/`eql` protocol against whatever type it
//! stores, and on win32 that is `PaneView` (which in turn holds one reference
//! on the `Surface` underneath a terminal pane). Both counters were open-coded
//! `u32` fields with a `+= 1` here and a `-= 1` there, and neither could be
//! tested: the `.terminal` arm needs a live Surface, which needs an App, a
//! Window and a child HWND, so a unit test cannot construct one and the only
//! signal for a leak or a double-free was a crash or a slow bleed under a long
//! session.
//!
//! So the arithmetic — which is the part that actually goes wrong — lives here
//! instead, with no OS imports, and runs in every app-runtime lane. The owners
//! keep the interesting half (what to free, and in what order); this type keeps
//! the counting and the two preconditions that make an underflow impossible to
//! reach silently:
//!
//!   * `release` on a count that is already zero is an assertion failure, not
//!     a wrap to `maxInt(u32)`. That wrap is exactly how a "free the leaf at
//!     zero" rule turns into a leak of everything underneath: the count goes
//!     enormous, the free never runs, and nothing says so.
//!   * `adoptUnowned` is the ONLY way to release a leaf that never entered a
//!     tree (a `SplitTree.init`/`split` that failed after the pane was
//!     created). The tree's ref/unref pair never ran for it, so the count is
//!     still zero; adopting the reference the tree would have taken lets the
//!     caller free through the normal path rather than open-coding a second
//!     teardown that can drift from the first.
const std = @import("std");

/// A split-tree leaf's reference count.
///
/// Starts at zero on purpose: `SplitTree.init`/`split` call `ref()` to take the
/// first reference, so a freshly created leaf is *unowned* until the tree
/// accepts it.
pub const RefCount = struct {
    value: u32 = 0,

    /// SplitTree took a reference.
    pub fn retain(self: *RefCount) void {
        self.value += 1;
    }

    /// SplitTree dropped a reference. Returns true when that was the LAST one
    /// and the owner must now free the leaf it owns and itself.
    ///
    /// Releasing an unowned count is a bug at the call site, not a state this
    /// type represents: see `adoptUnowned`.
    pub fn release(self: *RefCount) bool {
        std.debug.assert(self.value != 0);
        self.value -= 1;
        return self.value == 0;
    }

    /// True while no tree holds this leaf — i.e. `release` must not be called.
    pub fn isUnowned(self: *const RefCount) bool {
        return self.value == 0;
    }

    /// Adopt the reference the tree would have taken, for a leaf that never
    /// made it into one. After this a single `release` returns true, so the
    /// failure path frees through the same code as the ordinary one.
    pub fn adoptUnowned(self: *RefCount) void {
        std.debug.assert(self.value == 0);
        self.value = 1;
    }
};

// -------------------------------------------------------------------------
// Tests
//
// The fake below is the shape `PaneView` (and `Surface`) have: a leaf it owns,
// a count, and a "free at zero" rule. It is not a mock of the real teardown —
// it exists so the COUNTING can be driven through the same sequences the tree
// drives, and so "freed exactly once" is an assertion rather than a hope.
// -------------------------------------------------------------------------

const FakePane = struct {
    rc: RefCount = .{},
    /// How many times the leaf underneath was released. Anything but 1 by the
    /// end of a sequence is the defect this file exists to catch.
    leaf_freed: *u32,
    self_freed: *u32,

    fn ref(self: *FakePane) *FakePane {
        self.rc.retain();
        return self;
    }

    fn unref(self: *FakePane) void {
        if (!self.rc.release()) return;
        self.leaf_freed.* += 1;
        self.self_freed.* += 1;
    }

    fn destroyUnowned(self: *FakePane) void {
        self.rc.adoptUnowned();
        self.unref();
    }
};

test "a fresh leaf is unowned: the tree has not taken its first reference yet" {
    var rc: RefCount = .{};
    try std.testing.expect(rc.isUnowned());
    rc.retain();
    try std.testing.expect(!rc.isUnowned());
}

test "the last release is the one that frees, and it says so exactly once" {
    var rc: RefCount = .{};
    rc.retain();
    rc.retain();
    rc.retain();
    try std.testing.expect(!rc.release());
    try std.testing.expect(!rc.release());
    try std.testing.expect(rc.release());
    try std.testing.expect(rc.isUnowned());
}

test "the tree's ref/unref pair frees the leaf exactly once" {
    var leaf_freed: u32 = 0;
    var self_freed: u32 = 0;
    var pane: FakePane = .{ .leaf_freed = &leaf_freed, .self_freed = &self_freed };

    // SplitTree.init takes the first reference; deinit drops it.
    _ = pane.ref();
    pane.unref();

    try std.testing.expectEqual(@as(u32, 1), leaf_freed);
    try std.testing.expectEqual(@as(u32, 1), self_freed);
}

test "a pane held by two trees survives the first teardown" {
    var leaf_freed: u32 = 0;
    var self_freed: u32 = 0;
    var pane: FakePane = .{ .leaf_freed = &leaf_freed, .self_freed = &self_freed };

    // The shape `SplitTree.clone` produces: a second holder of the same leaf.
    _ = pane.ref();
    _ = pane.ref();
    pane.unref();
    try std.testing.expectEqual(@as(u32, 0), leaf_freed);

    pane.unref();
    try std.testing.expectEqual(@as(u32, 1), leaf_freed);
}

test "destroyUnowned frees a pane the tree never accepted, without underflowing" {
    var leaf_freed: u32 = 0;
    var self_freed: u32 = 0;
    var pane: FakePane = .{ .leaf_freed = &leaf_freed, .self_freed = &self_freed };

    // `addTab`/`replaceTabRootSurface`/`newSplitAt` take this path when
    // `SplitTree.init` fails after the pane was created: the count is still
    // zero, so a bare `unref` would wrap it to maxInt(u32) and leak the leaf.
    try std.testing.expect(pane.rc.isUnowned());
    pane.destroyUnowned();

    try std.testing.expectEqual(@as(u32, 1), leaf_freed);
    try std.testing.expectEqual(@as(u32, 1), self_freed);
    try std.testing.expect(pane.rc.isUnowned());
}

test "adoptUnowned makes exactly one release the freeing one" {
    var rc: RefCount = .{};
    rc.adoptUnowned();
    try std.testing.expectEqual(@as(u32, 1), rc.value);
    try std.testing.expect(rc.release());
}
