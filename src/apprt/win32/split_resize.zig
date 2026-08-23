//! Drag SEMANTICS for split dividers (T533) — what the REST of the tree is
//! allowed to do when one divider moves. The pixel math of a single split is
//! `split_geometry.zig`; this decides which OTHER boundaries move, and it is
//! pure for the same reason: no OS imports, so its tests run in every
//! app-runtime lane.
//!
//! **A divider exchanges space between its two adjacent PANES, and nothing
//! else moves.** In the three-column tree
//! `split(r1) -> [p1, split(r2) -> [p2, p3]]`, dragging divider 1 changes r1 —
//! the boundary between p1 and the whole right SUBTREE. Leaving r2 alone makes
//! p2 and p3 shrink proportionally, so divider 2 visibly slides along under a
//! pointer that never touched it (user, 2026-08-06: *"resizing the 1st sizer
//! moves the 2nd sizer … I expect only the 2 panels being sized are"*
//! affected). Holding divider 2 at its absolute pixel position instead makes p2
//! absorb the whole exchange and leaves p3 exactly as wide as it was.
//!
//! Three properties fall out of stating it that way, and each is asserted
//! below:
//!
//!   - **It recurses.** Once divider 2 is pinned, the region between divider 1
//!     and divider 2 is the one that changed, so any boundary inside THAT is
//!     pinned in turn, and so on down. Deep column runs behave like the
//!     three-column case at every level.
//!   - **A perpendicular split is not a boundary on this axis.** Dragging a
//!     vertical line cannot move a horizontal one, but it does change the width
//!     both of its children live in — so the walk passes straight through it
//!     into BOTH children and pins whatever it finds there. A grid does not
//!     shear when one column boundary moves.
//!   - **Nothing is pinned that did not move.** The walk prunes any subtree
//!     whose axis range is unchanged, which is what keeps a drag O(depth) in
//!     the common case and leaves the untouched side of the tree bit-identical.
//!
//! **Every tick is computed from the PRE-DRAG tree, never from the previous
//! tick.** A ratio is an `f16` and `split_geometry.axis` truncates, so
//! re-deriving "hold it where it is now" once per mouse move accumulates a
//! sub-pixel bias into a visible drift over a long drag. `plan()` therefore
//! takes a snapshot of the tree as it was when the divider was grabbed and
//! re-solves the whole thing against the ORIGINAL absolute positions each time,
//! which also makes a drag exactly reversible: drag out and back, and every
//! boundary is on the pixel it started on.
//!
//! **A clamped compensation degrades, it does not oscillate.** A pinned
//! boundary can be squeezed past the [MIN_RATIO, MAX_RATIO] floor its own split
//! obeys — drag divider 1 far enough right and there is no ratio that keeps
//! divider 2 where it was. The clamp then wins, the boundary moves as little as
//! the clamp allows, and the walk continues into the child with the ranges that
//! ACTUALLY resulted, so everything below it is pinned against the real
//! geometry rather than against a position nobody can reach.
//!
//! Mac does not do this (`SplitView.swift` is a nested per-node view whose
//! `split` binding is relative to its own geometry, exactly like our untouched
//! tree), so this is a deliberate divergence filed for the Mac seat rather
//! than a parity port.

const std = @import("std");
const testing = std.testing;
const split_geometry = @import("split_geometry.zig");

pub const Layout = split_geometry.Layout;

/// A split tree flattened for this module: index-addressed, view-free, and
/// with the ratios frozen at drag start. `Window.zig` converts its
/// `SplitTree(PaneView).Node`s into these once per drag.
pub const Node = union(enum) {
    leaf,
    split: Split,

    pub const Split = struct {
        layout: Layout,
        ratio: f32,
        /// Index into the same node slice for the left/top child.
        left: u16,
        /// Index into the same node slice for the right/bottom child.
        right: u16,
    };
};

/// One node's new ratio. The dragged node is always the first entry, so a
/// caller that applies the whole plan in order needs no special case for it.
pub const Adjust = struct {
    handle: u16,
    ratio: f32,
};

/// How deep the compensation walk goes before giving up. A tree this deep on
/// one axis is not reachable by hand, and a bound means a malformed node slice
/// (a cycle) costs a missing compensation rather than a hung message loop.
pub const MAX_DEPTH: usize = 32;

/// A plan buffer big enough for any layout a person builds by hand — one entry
/// per boundary that had to move, which in a column run is one per pane. A
/// caller may pass a smaller slice; `plan` truncates rather than failing (see
/// its doc comment), so the cost of the bound is a distant boundary sliding the
/// way it did before T533, never a wrong resize.
pub const MAX_ADJUSTMENTS: usize = 64;

/// An axis range in physical pixels, end exclusive — the slice of the drag
/// axis a subtree occupies.
const Range = struct {
    start: i32,
    end: i32,

    fn eql(a: Range, b: Range) bool {
        return a.start == b.start and a.end == b.end;
    }
};

const Walker = struct {
    nodes: []const Node,
    layout: Layout,
    scale: f32,
    out: []Adjust,
    len: usize = 0,

    fn push(self: *Walker, handle: u16, ratio: f32) bool {
        if (self.len >= self.out.len) return false;
        self.out[self.len] = .{ .handle = handle, .ratio = ratio };
        self.len += 1;
        return true;
    }

    /// Pin every boundary inside `handle` to where it was, given that the
    /// subtree's axis range moved from `old` to `new`.
    fn walk(self: *Walker, handle: u16, old: Range, new: Range, depth: usize) void {
        if (depth >= MAX_DEPTH) return;
        // Nothing on this axis moved, so nothing below can need pinning. This
        // is the prune that keeps the untouched side of the tree untouched.
        if (old.eql(new)) return;
        if (handle >= self.nodes.len) return;
        const s = switch (self.nodes[handle]) {
            .leaf => return,
            .split => |s| s,
        };

        if (s.layout != self.layout) {
            // A perpendicular split has no boundary on this axis — but both of
            // its children live in the range that just changed.
            self.walk(s.left, old, new, depth + 1);
            self.walk(s.right, old, new, depth + 1);
            return;
        }

        const a_old = split_geometry.axis(old.start, old.end, s.ratio, self.scale);
        // The ratio that would put this divider back on its own pixel — and
        // then the layout it ACTUALLY produces, which differs from the old one
        // only where the clamp bit. Everything below is solved against that
        // real geometry, never against the position it could not reach.
        const held = holdRatio(a_old.split_pos, new);
        const a_new = split_geometry.axis(new.start, new.end, held, self.scale);
        if (!self.push(handle, held)) return;

        self.walk(
            s.left,
            .{ .start = old.start, .end = a_old.band_lo },
            .{ .start = new.start, .end = a_new.band_lo },
            depth + 1,
        );
        self.walk(
            s.right,
            .{ .start = a_old.band_hi, .end = old.end },
            .{ .start = a_new.band_hi, .end = new.end },
            depth + 1,
        );
    }
};

/// The ratio that puts a split's divider at absolute position `pos` inside
/// `region`, clamped to the same [MIN_RATIO, MAX_RATIO] band a dragged ratio
/// obeys — a compensated pane is never squeezed to nothing, exactly as a
/// dragged one is not.
fn holdRatio(pos: i32, region: Range) f32 {
    const total: f32 = @floatFromInt(@max(region.end - region.start, 1));
    // Aim at the CENTER of the target pixel, not its left edge.
    // `split_geometry.axis` truncates the ratio back into a position, so a
    // ratio aimed at the edge lands a pixel low as soon as anything rounds it
    // down — and the ratio really is rounded, to `f16`, on its way into the
    // tree. Aiming half a pixel high centers that error instead of biasing it,
    // which is the difference between a boundary that holds and one that
    // creeps left every time a drag starts.
    const p: f32 = @as(f32, @floatFromInt(pos - region.start)) + 0.5;
    return std.math.clamp(
        p / total,
        split_geometry.MIN_RATIO,
        split_geometry.MAX_RATIO,
    );
}

/// Solve a divider drag: the dragged node's new ratio, plus the compensating
/// ratios that hold every other boundary where it was.
///
/// `nodes` is the tree as it was when the divider was GRABBED (see the module
/// comment); `dragged` indexes it; `region_start`/`region_end` are the dragged
/// node's own layout rect on its own axis — never the whole surface, which is
/// the T495 rule this builds on. Returns how many entries of `out` were
/// filled; entry 0 is always the dragged node itself. A full `out` truncates
/// the plan rather than failing it: the boundaries that did fit are still
/// pinned, and the ones past the end behave as they did before this existed.
pub fn plan(
    nodes: []const Node,
    dragged: u16,
    region_start: i32,
    region_end: i32,
    new_ratio: f32,
    scale: f32,
    out: []Adjust,
) usize {
    if (dragged >= nodes.len) return 0;
    const s = switch (nodes[dragged]) {
        .leaf => return 0,
        .split => |s| s,
    };

    var w: Walker = .{
        .nodes = nodes,
        .layout = s.layout,
        .scale = scale,
        .out = out,
    };
    if (!w.push(dragged, new_ratio)) return 0;

    const a_old = split_geometry.axis(region_start, region_end, s.ratio, scale);
    const a_new = split_geometry.axis(region_start, region_end, new_ratio, scale);
    w.walk(
        s.left,
        .{ .start = region_start, .end = a_old.band_lo },
        .{ .start = region_start, .end = a_new.band_lo },
        1,
    );
    w.walk(
        s.right,
        .{ .start = a_old.band_hi, .end = region_end },
        .{ .start = a_new.band_hi, .end = region_end },
        1,
    );
    return w.len;
}

/// The ratio that shifts a split's divider by `delta` physical pixels inside
/// its own `region_start`..`region_end` range — the KEYBOARD half of a drag
/// (T1129).
///
/// `resize_split` is the same gesture as a divider drag arriving by another
/// input, so it has to land in the same place, which means it has to be
/// expressed the same way: an absolute position for `plan` to solve, never a
/// delta applied to a ratio. A ratio delta is what `SplitTree.resize` does, and
/// it rescales the moved node's whole subtree — so before this existed,
/// ctrl+win+arrow slid the neighbouring dividers that the very same divider
/// dragged with the mouse held still.
///
/// The clamp is `dragRatio`'s, for the same reason: one gesture, one floor.
///
/// Unlike a drag, a keyboard step is solved against the tree as it STANDS —
/// there is no gesture to snapshot, since each press is its own action — so
/// this round-trips ratio -> pixels -> ratio once per press and the rounding
/// has to be centered rather than merely small. `split_geometry.axis`
/// truncates, so aiming at the target pixel's leading edge loses a fraction of
/// a pixel EVERY press, always in the same direction: nudge a divider eight
/// steps right and eight steps back and it lands measurably left of where it
/// started. Aiming half a pixel high is the same correction `holdRatio` makes,
/// for the same reason.
pub fn nudgeRatio(
    region_start: i32,
    region_end: i32,
    ratio: f32,
    scale: f32,
    delta: i32,
) f32 {
    const a = split_geometry.axis(region_start, region_end, ratio, scale);
    return holdRatio(a.split_pos + delta, .{ .start = region_start, .end = region_end });
}

/// How many nodes a keyboard gesture can hold on to. Same bound the drag's
/// own snapshot uses in `Window.zig`; a tree past it simply gets no gesture,
/// which costs a single divider's drift and never a wrong resize.
pub const MAX_GESTURE_NODES: usize = 128;

/// A RUN of keyboard divider steps, treated as one gesture (T1129).
///
/// `resize_split` arrives one press at a time, but a held key is a single
/// movement and has to behave like one. Solving each press against the tree
/// the previous press just wrote round-trips an `f16` ratio through pixels
/// every time, and that rounding does not cancel: measured over eighty presses
/// out and back, a held boundary ended 40px from where it started, and the
/// dragged one did not return to its origin either. The mouse has never had
/// that problem because it re-solves the whole drag from a snapshot taken when
/// the divider was grabbed — so the keyboard keeps the same snapshot and
/// replays its ACCUMULATED offset against it.
///
/// The gesture ends by itself the moment anything else touches the layout:
/// `expect` records the ratios the last plan wrote, and a tree that no longer
/// matches them (an equalize, a mouse drag, a pane closing, a restore) starts
/// a fresh one. Nothing has to remember to call an `end` method, which is the
/// point — there is no key-up to hang one on.
pub const KeyboardGesture = struct {
    /// The tree as it was when the gesture began.
    nodes: [MAX_GESTURE_NODES]Node = undefined,
    /// The ratios the last plan wrote, per node — the fingerprint that says
    /// whether this gesture still owns the layout.
    expect: [MAX_GESTURE_NODES]f16 = undefined,
    len: usize = 0,
    /// Caller-defined scope (the win32 app passes the tab index): two tabs can
    /// hold identically shaped trees, and a gesture must not carry across.
    context: u32 = 0,
    target: u16 = 0,
    region_start: i32 = 0,
    region_end: i32 = 0,
    /// Pixels travelled since the gesture began, summed over its presses.
    offset: i32 = 0,

    /// Whether `tree` is still the tree this gesture was solving.
    fn owns(
        self: *const KeyboardGesture,
        tree: []const Node,
        context: u32,
        target: u16,
        region_start: i32,
        region_end: i32,
    ) bool {
        if (self.len == 0 or self.len != tree.len) return false;
        if (self.context != context or self.target != target) return false;
        if (self.region_start != region_start or self.region_end != region_end) return false;
        for (tree, self.nodes[0..self.len], self.expect[0..self.len]) |now, was, want| {
            switch (now) {
                .leaf => if (was != .leaf) return false,
                .split => |a| switch (was) {
                    .leaf => return false,
                    .split => |b| {
                        // Shape first: a tree rebuilt to the same node count is
                        // a different tree even when the ratios line up.
                        if (a.layout != b.layout or a.left != b.left or a.right != b.right) return false;
                        if (@as(f16, @floatCast(a.ratio)) != want) return false;
                    },
                },
            }
        }
        return true;
    }

    /// Plan one keyboard step, beginning a gesture or continuing the one in
    /// flight. `tree` is the layout as it stands; `out` receives the same
    /// adjustments a drag would produce. Returns how many were written — 0
    /// means no plan (a tree too big to snapshot, or a target that is not a
    /// split on this axis), and the caller moves that one divider alone.
    pub fn step(
        self: *KeyboardGesture,
        tree: []const Node,
        context: u32,
        target: u16,
        region_start: i32,
        region_end: i32,
        scale: f32,
        delta: i32,
        out: []Adjust,
    ) usize {
        if (!self.owns(tree, context, target, region_start, region_end)) {
            self.len = 0;
            if (tree.len == 0 or tree.len > self.nodes.len) return 0;
            if (target >= tree.len or tree[target] == .leaf) return 0;
            @memcpy(self.nodes[0..tree.len], tree);
            self.len = tree.len;
            self.context = context;
            self.target = target;
            self.region_start = region_start;
            self.region_end = region_end;
            self.offset = 0;
            self.markUnmoved();
        }

        self.offset += delta;
        const base = switch (self.nodes[target]) {
            .leaf => return 0,
            .split => |sp| sp.ratio,
        };
        const ratio = nudgeRatio(region_start, region_end, base, scale, self.offset);
        var n = plan(self.nodes[0..self.len], target, region_start, region_end, ratio, scale, out);

        // `plan` prunes any subtree whose axis range did not move — measured
        // against the SNAPSHOT, which is what makes a drag cheap. Replaying a
        // gesture, that prune leaves behind whatever an EARLIER press of the
        // same run wrote there: come back to the position you started at and
        // the divider a previous press had squeezed against its clamp would
        // simply stay squeezed. So anything this run moved and this press does
        // not mention is put back where the snapshot had it.
        n = self.restoreUnplanned(out, n);

        // Fingerprint the layout this plan produces, so the next press can
        // tell "still my gesture" from "somebody else moved something".
        self.markUnmoved();
        for (out[0..n]) |a| {
            if (a.handle < self.len) self.expect[a.handle] = @floatCast(a.ratio);
        }
        return n;
    }

    /// Set the fingerprint to the snapshot itself — "this gesture has moved
    /// nothing yet".
    fn markUnmoved(self: *KeyboardGesture) void {
        for (self.nodes[0..self.len], 0..) |node, i| {
            self.expect[i] = switch (node) {
                .leaf => 0,
                .split => |sp| @floatCast(sp.ratio),
            };
        }
    }

    /// Append an adjustment back to the snapshot ratio for every node this
    /// gesture has moved that `out[0..n]` does not already cover. Returns the
    /// new length; a full buffer truncates, exactly as `plan` does.
    fn restoreUnplanned(self: *const KeyboardGesture, out: []Adjust, n: usize) usize {
        var len = n;
        for (self.nodes[0..self.len], 0..) |node, i| {
            const snapshot: f16 = switch (node) {
                .leaf => continue,
                .split => |sp| @floatCast(sp.ratio),
            };
            if (self.expect[i] == snapshot) continue;
            const handle: u16 = @intCast(i);
            const planned = for (out[0..n]) |a| {
                if (a.handle == handle) break true;
            } else false;
            if (planned) continue;
            if (len >= out.len) break;
            out[len] = .{ .handle = handle, .ratio = snapshot };
            len += 1;
        }
        return len;
    }
};

/// Where a split's divider sits on `layout`'s axis, given a tree and the axis
/// range the ROOT occupies. Perpendicular splits pass their range through to
/// both children untouched, which is what makes this the same one-dimensional
/// view of the tree the compensation walk takes.
///
/// Null when the handle is not a split with that layout — i.e. it has no
/// boundary on this axis to have a position.
pub fn dividerPos(
    nodes: []const Node,
    target: u16,
    root: u16,
    range_start: i32,
    range_end: i32,
    layout: Layout,
    scale: f32,
) ?i32 {
    return posWalk(nodes, target, root, .{ .start = range_start, .end = range_end }, layout, scale, 0);
}

fn posWalk(
    nodes: []const Node,
    target: u16,
    handle: u16,
    range: Range,
    layout: Layout,
    scale: f32,
    depth: usize,
) ?i32 {
    if (depth >= MAX_DEPTH) return null;
    if (handle >= nodes.len) return null;
    const s = switch (nodes[handle]) {
        .leaf => return null,
        .split => |s| s,
    };
    if (s.layout != layout) {
        return posWalk(nodes, target, s.left, range, layout, scale, depth + 1) orelse
            posWalk(nodes, target, s.right, range, layout, scale, depth + 1);
    }
    const a = split_geometry.axis(range.start, range.end, s.ratio, scale);
    if (handle == target) return a.split_pos;
    return posWalk(nodes, target, s.left, .{ .start = range.start, .end = a.band_lo }, layout, scale, depth + 1) orelse
        posWalk(nodes, target, s.right, .{ .start = a.band_hi, .end = range.end }, layout, scale, depth + 1);
}

/// Apply a plan to a mutable node slice — the test-side mirror of what
/// `Window.zig` does with `SplitTree.resizeInPlace`.
pub fn apply(nodes: []Node, adjustments: []const Adjust) void {
    for (adjustments) |a| {
        if (a.handle >= nodes.len) continue;
        switch (nodes[a.handle]) {
            .leaf => {},
            // The real tree stores f16, so the round trip has to happen here
            // too or the tests would assert against a precision the product
            // does not have.
            .split => |*s| s.ratio = @floatCast(@as(f16, @floatCast(a.ratio))),
        }
    }
}

// -- tests -------------------------------------------------------------------

const SCALES = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

/// A boundary that must HOLD, with exactly one physical pixel of slack.
///
/// The slack is the tree's own precision, not a fudge: `SplitTree.Split.ratio`
/// is an `f16`, whose ~2^-11 relative resolution is worth about a pixel across
/// a 3000px surface, and `split_geometry.axis` truncates on the way back. So a
/// boundary can be *reproduced* to a pixel and no better — against a defect
/// that moved it by two hundred. What the slack must never do is accumulate,
/// which is why every tick re-solves from the pre-drag snapshot instead of
/// from the previous answer (asserted by the reversibility test below).
fn expectHeld(before: i32, after: i32) !void {
    testing.expect(@abs(after - before) <= 1) catch |err| {
        std.debug.print("boundary moved: {d} -> {d}\n", .{ before, after });
        return err;
    };
}

/// `split(r1) -> [p1, split(r2) -> [p2, p3]]` — the user's three columns.
fn threeColumns(r1: f32, r2: f32) [5]Node {
    return .{
        .{ .split = .{ .layout = .horizontal, .ratio = r1, .left = 1, .right = 2 } },
        .leaf,
        .{ .split = .{ .layout = .horizontal, .ratio = r2, .left = 3, .right = 4 } },
        .leaf,
        .leaf,
    };
}

test "three columns: dragging divider 1 leaves divider 2 on its pixel" {
    // THE report (2026-08-06). Divider 2's absolute x must not move, at every
    // scale the design system requires.
    for (SCALES) |scale| {
        const w: i32 = 3110;
        var nodes = threeColumns(1.0 / 3.0, 0.5);
        const before = dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?;

        // The dragged node's own region is the whole surface (it is the root).
        var out: [16]Adjust = undefined;
        const n = plan(&nodes, 0, 0, w, 0.2, scale, &out);
        try testing.expect(n >= 2);
        try testing.expectEqual(@as(u16, 0), out[0].handle);
        apply(&nodes, out[0..n]);

        const after = dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?;
        try expectHeld(before, after);
    }
}

test "three columns: the defect itself, pinned" {
    // Without compensation the nested ratio stays 0.5 and divider 2 slides by
    // half the exchanged width — ~207px on the user's window. This is the
    // control for the test above: it fails the moment the walk stops working.
    const w: i32 = 3110;
    var nodes = threeColumns(1.0 / 3.0, 0.5);
    const before = dividerPos(&nodes, 2, 0, 0, w, .horizontal, 1.0).?;

    var out: [16]Adjust = undefined;
    const n = plan(&nodes, 0, 0, w, 0.2, 1.0, &out);
    // Apply ONLY the dragged node, the pre-T533 behavior.
    apply(&nodes, out[0..1]);
    const uncompensated = dividerPos(&nodes, 2, 0, 0, w, .horizontal, 1.0).?;
    try testing.expect(before - uncompensated > 200);

    // And the full plan puts it back.
    var fixed = threeColumns(1.0 / 3.0, 0.5);
    apply(&fixed, out[0..n]);
    try expectHeld(before, dividerPos(&fixed, 2, 0, 0, w, .horizontal, 1.0).?);
}

test "three columns: dragging divider 2 still moves only itself (T495 unchanged)" {
    // The nested divider's own drag has no descendants to compensate, and must
    // not disturb divider 1 — the half the user already confirmed working.
    for (SCALES) |scale| {
        const w: i32 = 3110;
        var nodes = threeColumns(1.0 / 3.0, 0.5);
        const d1_before = dividerPos(&nodes, 0, 0, 0, w, .horizontal, scale).?;

        // Divider 2's region is the right child's rect, not the surface.
        const root = split_geometry.axis(0, w, 1.0 / 3.0, scale);
        var out: [16]Adjust = undefined;
        const n = plan(&nodes, 2, root.band_hi, w, 0.7, scale, &out);
        try testing.expectEqual(@as(usize, 1), n); // nothing below it to pin
        apply(&nodes, out[0..n]);

        try testing.expectEqual(d1_before, dividerPos(&nodes, 0, 0, 0, w, .horizontal, scale).?);
    }
}

test "the pane on the far side keeps its exact width" {
    // The user's sentence, measured as a width rather than as a boundary: p3
    // is not part of the exchange, so it must come out of the drag exactly as
    // wide as it went in.
    for (SCALES) |scale| {
        const w: i32 = 1600;
        var nodes = threeColumns(0.5, 0.5);
        const d2_before = dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?;
        const p3_before = w - d2_before;

        var out: [16]Adjust = undefined;
        const n = plan(&nodes, 0, 0, w, 0.25, scale, &out);
        apply(&nodes, out[0..n]);
        const d2_after = dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?;
        try expectHeld(p3_before, w - d2_after);
    }
}

test "compensation runs on the LEFT of the dragged divider too" {
    // `split(r1) -> [split(rA) -> [p0, p1], p2]`: dragging divider 1 grows the
    // left region, and p1 — the pane adjacent to the divider — is the one that
    // grows. p0 keeps its width, so divider A stays put.
    for (SCALES) |scale| {
        const w: i32 = 1200;
        var nodes = [_]Node{
            .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 1, .right = 4 } },
            .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 2, .right = 3 } },
            .leaf,
            .leaf,
            .leaf,
        };
        const before = dividerPos(&nodes, 1, 0, 0, w, .horizontal, scale).?;

        var out: [16]Adjust = undefined;
        const n = plan(&nodes, 0, 0, w, 0.75, scale, &out);
        apply(&nodes, out[0..n]);
        try expectHeld(before, dividerPos(&nodes, 1, 0, 0, w, .horizontal, scale).?);
    }
}

test "deep nesting: four columns, every downstream boundary held" {
    // `[p1, [p2, [p3, p4]]]`. Pinning divider 2 leaves divider 3's region
    // untouched, so the walk prunes there — the assertion is that both stay
    // put, whichever way that is achieved.
    for (SCALES) |scale| {
        const w: i32 = 2000;
        var nodes = [_]Node{
            .{ .split = .{ .layout = .horizontal, .ratio = 0.25, .left = 1, .right = 2 } },
            .leaf,
            .{ .split = .{ .layout = .horizontal, .ratio = 1.0 / 3.0, .left = 3, .right = 4 } },
            .leaf,
            .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 5, .right = 6 } },
            .leaf,
            .leaf,
        };
        const d2 = dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?;
        const d3 = dividerPos(&nodes, 4, 0, 0, w, .horizontal, scale).?;

        var out: [16]Adjust = undefined;
        const n = plan(&nodes, 0, 0, w, 0.35, scale, &out);
        apply(&nodes, out[0..n]);
        try expectHeld(d2, dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?);
        try expectHeld(d3, dividerPos(&nodes, 4, 0, 0, w, .horizontal, scale).?);
    }
}

test "a perpendicular split is walked THROUGH, not around" {
    // Root column boundary, with a right subtree of two ROWS that each hold
    // their own column boundary. Widening the right subtree must not shear the
    // grid: both rows' column boundaries stay on their pixel, and the row
    // boundary itself is untouched because it is on the other axis.
    for (SCALES) |scale| {
        const w: i32 = 1800;
        var nodes = [_]Node{
            .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 1, .right = 2 } },
            .leaf,
            .{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = 3, .right = 6 } },
            .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 4, .right = 5 } },
            .leaf,
            .leaf,
            .{ .split = .{ .layout = .horizontal, .ratio = 0.25, .left = 7, .right = 8 } },
            .leaf,
            .leaf,
        };
        const top = dividerPos(&nodes, 3, 0, 0, w, .horizontal, scale).?;
        const bottom = dividerPos(&nodes, 6, 0, 0, w, .horizontal, scale).?;
        const row_ratio = nodes[2].split.ratio;

        var out: [16]Adjust = undefined;
        const n = plan(&nodes, 0, 0, w, 0.3, scale, &out);
        apply(&nodes, out[0..n]);
        try expectHeld(top, dividerPos(&nodes, 3, 0, 0, w, .horizontal, scale).?);
        try expectHeld(bottom, dividerPos(&nodes, 6, 0, 0, w, .horizontal, scale).?);
        // The row boundary is on the other axis and is never rewritten.
        try testing.expectEqual(row_ratio, nodes[2].split.ratio);
        for (out[0..n]) |a| try testing.expect(a.handle != 2);
    }
}

test "an untouched subtree is left bit-identical" {
    // The prune, asserted as a property rather than as a count: dragging the
    // root rightward changes nothing about the LEFT subtree's internals, so no
    // adjustment may name a node inside it.
    const w: i32 = 1000;
    var nodes = [_]Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 1, .right = 4 } },
        .{ .split = .{ .layout = .vertical, .ratio = 0.4, .left = 2, .right = 3 } },
        .leaf,
        .leaf,
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 5, .right = 6 } },
        .leaf,
        .leaf,
    };
    var out: [16]Adjust = undefined;
    const n = plan(&nodes, 0, 0, w, 0.6, 1.0, &out);
    for (out[0..n]) |a| try testing.expect(a.handle != 1);
    // A vertical split inside a horizontally-resized subtree has no boundary
    // on the drag axis, so it is never rewritten either.
    apply(&nodes, out[0..n]);
    try testing.expectEqual(@as(f32, 0.4), nodes[1].split.ratio);
}

test "clamp: a squeezed boundary gives way gracefully and stays monotonic" {
    // Drag divider 1 far right and there is no ratio that keeps divider 2
    // where it was — the compensated pane would have to be narrower than the
    // MIN_RATIO floor. The boundary must then move as LITTLE as the clamp
    // allows, and must never move backwards as the squeeze increases.
    const w: i32 = 1000;
    const original = threeColumns(0.2, 0.5);
    const d2 = dividerPos(&original, 2, 0, 0, w, .horizontal, 1.0).?;

    var prev: i32 = d2;
    var i: u32 = 2;
    while (i <= 9) : (i += 1) {
        var nodes = threeColumns(0.2, 0.5);
        var out: [16]Adjust = undefined;
        const r: f32 = @as(f32, @floatFromInt(i)) / 10.0;
        const n = plan(&nodes, 0, 0, w, r, 1.0, &out);
        apply(&nodes, out[0..n]);
        const pos = dividerPos(&nodes, 2, 0, 0, w, .horizontal, 1.0).?;
        // Never left of where it started, never left of the previous step:
        // the squeeze only ever pushes it right, and only once it has to.
        try testing.expect(pos >= prev - 1);
        // And it is never pushed past the floor its own split obeys.
        const region_start = split_geometry.axis(0, w, r, 1.0).band_hi;
        try testing.expect(pos >= region_start);
        prev = pos;
    }
    // The far end really is squeezed — otherwise this test proves nothing.
    try testing.expect(prev > d2);
}

test "clamp: the pinned boundary below a clamped one uses the REAL geometry" {
    // When divider 2 clamps, everything under it must be solved against where
    // divider 2 actually ended up, not against the position it could not
    // reach. The observable: no boundary escapes its parent's region.
    const w: i32 = 1000;
    var nodes = [_]Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.2, .left = 1, .right = 2 } },
        .leaf,
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 3, .right = 4 } },
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 5, .right = 6 } },
        .leaf,
        .leaf,
        .leaf,
    };
    var out: [16]Adjust = undefined;
    const n = plan(&nodes, 0, 0, w, 0.9, 1.0, &out);
    apply(&nodes, out[0..n]);

    const d1 = dividerPos(&nodes, 0, 0, 0, w, .horizontal, 1.0).?;
    const d2 = dividerPos(&nodes, 2, 0, 0, w, .horizontal, 1.0).?;
    const d3 = dividerPos(&nodes, 3, 0, 0, w, .horizontal, 1.0).?;
    try testing.expect(d1 <= d3);
    try testing.expect(d3 <= d2);
    try testing.expect(d2 <= w);
}

test "a drag is reversible: out and back lands on the original pixels" {
    // Why every tick re-solves from the pre-drag snapshot. Fifty motion ticks
    // that end where they began must leave every boundary exactly where it
    // was; solving from the previous tick instead accumulates f16 and
    // truncation error into a visible drift.
    for (SCALES) |scale| {
        const w: i32 = 3110;
        const snapshot = threeColumns(1.0 / 3.0, 0.5);
        const d1 = dividerPos(&snapshot, 0, 0, 0, w, .horizontal, scale).?;
        const d2 = dividerPos(&snapshot, 2, 0, 0, w, .horizontal, scale).?;

        var nodes = snapshot;
        var i: u32 = 0;
        while (i < 50) : (i += 1) {
            const r: f32 = 0.2 + 0.01 * @as(f32, @floatFromInt(i % 25));
            var out: [16]Adjust = undefined;
            // Always from the snapshot — this IS the rule under test.
            nodes = snapshot;
            const n = plan(&snapshot, 0, 0, w, r, scale, &out);
            apply(&nodes, out[0..n]);
        }

        // Final tick: back to the ratio the drag started on.
        var out: [16]Adjust = undefined;
        nodes = snapshot;
        const n = plan(&snapshot, 0, 0, w, 1.0 / 3.0, scale, &out);
        apply(&nodes, out[0..n]);
        try testing.expectEqual(d1, dividerPos(&nodes, 0, 0, 0, w, .horizontal, scale).?);
        try expectHeld(d2, dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?);
    }
}

test "vertical analog: rows for columns, same rule" {
    for (SCALES) |scale| {
        const h: i32 = 1200;
        var nodes = [_]Node{
            .{ .split = .{ .layout = .vertical, .ratio = 1.0 / 3.0, .left = 1, .right = 2 } },
            .leaf,
            .{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = 3, .right = 4 } },
            .leaf,
            .leaf,
        };
        const before = dividerPos(&nodes, 2, 0, 0, h, .vertical, scale).?;
        var out: [16]Adjust = undefined;
        const n = plan(&nodes, 0, 0, h, 0.6, scale, &out);
        apply(&nodes, out[0..n]);
        try expectHeld(before, dividerPos(&nodes, 2, 0, 0, h, .vertical, scale).?);
    }
}

test "a grabbed-but-unmoved divider changes nothing" {
    // The T495 property, extended to the compensation: pushing the CURRENT
    // ratio through `plan` must be a no-op on every boundary, or a mouse-down
    // with no motion would nudge the layout.
    const w: i32 = 3110;
    const snapshot = threeColumns(1.0 / 3.0, 0.5);
    var nodes = snapshot;
    var out: [16]Adjust = undefined;
    const n = plan(&snapshot, 0, 0, w, snapshot[0].split.ratio, 1.0, &out);
    apply(&nodes, out[0..n]);
    try testing.expectEqual(
        dividerPos(&snapshot, 0, 0, 0, w, .horizontal, 1.0).?,
        dividerPos(&nodes, 0, 0, 0, w, .horizontal, 1.0).?,
    );
    try testing.expectEqual(
        dividerPos(&snapshot, 2, 0, 0, w, .horizontal, 1.0).?,
        dividerPos(&nodes, 2, 0, 0, w, .horizontal, 1.0).?,
    );
}

test "a leaf, a bad handle and a full buffer are all answered, not crashed" {
    const w: i32 = 1000;
    var nodes = threeColumns(0.5, 0.5);
    var out: [16]Adjust = undefined;
    try testing.expectEqual(@as(usize, 0), plan(&nodes, 1, 0, w, 0.4, 1.0, &out)); // leaf
    try testing.expectEqual(@as(usize, 0), plan(&nodes, 99, 0, w, 0.4, 1.0, &out)); // out of range

    // A buffer too small to hold the whole plan truncates it: the dragged node
    // is still resized (entry 0), the deeper pins are simply not made.
    var tiny: [1]Adjust = undefined;
    try testing.expectEqual(@as(usize, 1), plan(&nodes, 0, 0, w, 0.4, 1.0, &tiny));
    try testing.expectEqual(@as(u16, 0), tiny[0].handle);
    var none: [0]Adjust = undefined;
    try testing.expectEqual(@as(usize, 0), plan(&nodes, 0, 0, w, 0.4, 1.0, &none));
}

test "a cyclic node slice terminates" {
    // Not reachable from the real tree, but the walk is the only place a
    // malformed slice could hang the message loop.
    var nodes = [_]Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 1, .right = 1 } },
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 0, .right = 0 } },
    };
    var out: [64]Adjust = undefined;
    const n = plan(&nodes, 0, 0, 1000, 0.4, 1.0, &out);
    try testing.expect(n <= out.len);
}

// -- T1129: the keyboard is the same gesture ---------------------------------

/// One `resize_split` press through the whole product path: hand the tree as
/// it stands to the gesture, then apply what it plans — exactly what
/// `Window.resizeSplit` does. Returns the plan length.
fn keyboardStep(
    g: *KeyboardGesture,
    nodes: []Node,
    target: u16,
    region_start: i32,
    region_end: i32,
    scale: f32,
    delta: i32,
    out: []Adjust,
) usize {
    const n = g.step(nodes, 0, target, region_start, region_end, scale, delta, out);
    apply(nodes, out[0..n]);
    return n;
}

test "nudgeRatio moves the divider by the requested pixels, in its own region" {
    for (SCALES) |scale| {
        const w: i32 = 1600;
        // The nested split's region is the right two thirds, not the surface:
        // a step measured against the whole window would move it by the wrong
        // distance, which is the T495 rule this inherits.
        const root = split_geometry.axis(0, w, 1.0 / 3.0, scale);
        const before = split_geometry.axis(root.band_hi, w, 0.5, scale).split_pos;

        const r = nudgeRatio(root.band_hi, w, 0.5, scale, 40);
        const after = split_geometry.axis(root.band_hi, w, r, scale).split_pos;
        try expectHeld(before + 40, after);

        const back = nudgeRatio(root.band_hi, w, r, scale, -40);
        try expectHeld(before, split_geometry.axis(root.band_hi, w, back, scale).split_pos);
    }
}

test "nudgeRatio clamps at the same floor a dragged divider does" {
    const w: i32 = 1000;
    // A step far past the edge cannot squeeze a pane below the [0.1, 0.9]
    // band; it lands ON the band, the way a drag pushed to the limit does.
    try testing.expectEqual(
        split_geometry.MAX_RATIO,
        nudgeRatio(0, w, 0.5, 1.0, 10_000),
    );
    try testing.expectEqual(
        split_geometry.MIN_RATIO,
        nudgeRatio(0, w, 0.5, 1.0, -10_000),
    );
}

test "keyboard: moving divider 1 leaves divider 2 on its pixel" {
    // THE T1129 defect. `SplitTree.resize` fed the nearest matching split a
    // ratio delta, which rescales its whole subtree — so ctrl+win+right slid
    // divider 2 along under divider 1, while a MOUSE drag of that same
    // divider held it still since T533. One gesture, two answers.
    for (SCALES) |scale| {
        const w: i32 = 3110;
        var nodes = threeColumns(1.0 / 3.0, 0.5);
        const d2_before = dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?;
        const d1_before = dividerPos(&nodes, 0, 0, 0, w, .horizontal, scale).?;

        // Sixty steps of the 10px `DIVIDER_STEP` — a held key, not a tap.
        // The count is the point: each press is solved against the tree as it
        // stands, so an error that accumulated would show up here as tens of
        // pixels rather than the one the f16 ratio is worth.
        var g: KeyboardGesture = .{};
        var out: [64]Adjust = undefined;
        for (0..60) |_| {
            _ = keyboardStep(&g, &nodes, 0, 0, w, scale, 10, &out);
        }

        const d1_after = dividerPos(&nodes, 0, 0, 0, w, .horizontal, scale).?;
        // Control: the divider the user asked for really did travel. Without
        // it the hold below would pass on a build that ignores the key.
        try testing.expect(d1_after - d1_before >= 590);
        try expectHeld(d2_before, dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?);
    }
}

test "keyboard: the uncompensated answer is the control" {
    // What the old path produced, so the test above fails the moment the plan
    // stops being applied: divider 2 slides by half of divider 1's travel.
    const w: i32 = 3110;
    var nodes = threeColumns(1.0 / 3.0, 0.5);
    const d2_before = dividerPos(&nodes, 2, 0, 0, w, .horizontal, 1.0).?;

    var out: [64]Adjust = undefined;
    for (0..10) |_| {
        const ratio = nodes[0].split.ratio;
        const r = nudgeRatio(0, w, ratio, 1.0, 10);
        _ = plan(&nodes, 0, 0, w, r, 1.0, &out);
        apply(&nodes, out[0..1]); // dragged node only
    }
    const slid = dividerPos(&nodes, 2, 0, 0, w, .horizontal, 1.0).? - d2_before;
    try testing.expect(slid >= 40);
}

test "keyboard: a run out and back lands on the pixels it started on" {
    // Reversibility is what a user checks by nudging a divider and undoing it
    // by hand. Because the whole run is replayed against ONE snapshot, the
    // offset returning to zero reproduces the original tree EXACTLY — this is
    // an equality, not a tolerance, and it is the assertion that fails if the
    // gesture ever silently restarts mid-run.
    for (SCALES) |scale| {
        const w: i32 = 1600;
        var nodes = threeColumns(0.5, 0.5);
        const d1 = dividerPos(&nodes, 0, 0, 0, w, .horizontal, scale).?;
        const d2 = dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?;

        var g: KeyboardGesture = .{};
        var out: [64]Adjust = undefined;
        for (0..40) |_| _ = keyboardStep(&g, &nodes, 0, 0, w, scale, 10, &out);
        for (0..40) |_| _ = keyboardStep(&g, &nodes, 0, 0, w, scale, -10, &out);

        try testing.expectEqual(d1, dividerPos(&nodes, 0, 0, 0, w, .horizontal, scale).?);
        try testing.expectEqual(d2, dividerPos(&nodes, 2, 0, 0, w, .horizontal, scale).?);
    }
}

test "keyboard: solving each press against the previous one is the control" {
    // What a gesture-less keyboard path produces, and why the equality above
    // is worth asserting: the same eighty presses, each solved against the
    // tree the last one wrote, walk the held boundary tens of pixels away.
    const w: i32 = 1600;
    var nodes = threeColumns(0.5, 0.5);
    const d2 = dividerPos(&nodes, 2, 0, 0, w, .horizontal, 1.0).?;

    var out: [64]Adjust = undefined;
    for (0..80) |i| {
        const delta: i32 = if (i < 40) 10 else -10;
        const ratio = nodes[0].split.ratio;
        const r = nudgeRatio(0, w, ratio, 1.0, delta);
        const n = plan(&nodes, 0, 0, w, r, 1.0, &out);
        apply(&nodes, out[0..n]);
    }
    try testing.expect(@abs(dividerPos(&nodes, 2, 0, 0, w, .horizontal, 1.0).? - d2) > 10);
}

test "keyboard: the gesture ends when anything else moves the layout" {
    // There is no key-up to end it on, so the fingerprint has to. Each of
    // these is a thing that really happens between two presses of a held key:
    // an equalize, a different tab, a window resize.
    const w: i32 = 1600;
    var out: [64]Adjust = undefined;

    {
        var nodes = threeColumns(0.5, 0.5);
        var g: KeyboardGesture = .{};
        _ = keyboardStep(&g, &nodes, 0, 0, w, 1.0, 10, &out);
        try testing.expectEqual(@as(i32, 10), g.offset);

        // Somebody else re-ratios the tree (equalize, a mouse drag, a restore).
        nodes[0].split.ratio = 0.25;
        _ = keyboardStep(&g, &nodes, 0, 0, w, 1.0, 10, &out);
        try testing.expectEqual(@as(i32, 10), g.offset); // a NEW run, not a continuation
        try testing.expectEqual(@as(f32, 0.25), g.nodes[0].split.ratio);
    }

    {
        var nodes = threeColumns(0.5, 0.5);
        var g: KeyboardGesture = .{};
        _ = keyboardStep(&g, &nodes, 0, 0, w, 1.0, 10, &out);
        // Another tab, identically shaped: the context is what tells them apart.
        _ = g.step(&nodes, 1, 0, 0, w, 1.0, 10, &out);
        try testing.expectEqual(@as(i32, 10), g.offset);
        try testing.expectEqual(@as(u32, 1), g.context);
    }

    {
        var nodes = threeColumns(0.5, 0.5);
        var g: KeyboardGesture = .{};
        _ = keyboardStep(&g, &nodes, 0, 0, w, 1.0, 10, &out);
        // The window was resized under the held key, so the pixels the offset
        // was measured in are not the same pixels any more.
        _ = keyboardStep(&g, &nodes, 0, 0, w + 200, 1.0, 10, &out);
        try testing.expectEqual(@as(i32, 10), g.offset);
        try testing.expectEqual(@as(i32, w + 200), g.region_end);
    }

    {
        // A tree bigger than the snapshot buffer gets no gesture at all, and
        // says so with a zero-length plan rather than resizing something else.
        var big: [MAX_GESTURE_NODES + 2]Node = undefined;
        for (&big) |*n| n.* = .leaf;
        big[0] = .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 1, .right = 2 } };
        var g: KeyboardGesture = .{};
        try testing.expectEqual(@as(usize, 0), g.step(&big, 0, 0, 0, w, 1.0, 10, &out));

        // And a target that is not a split is not a divider to move.
        var nodes = threeColumns(0.5, 0.5);
        try testing.expectEqual(@as(usize, 0), g.step(&nodes, 0, 1, 0, w, 1.0, 10, &out));
    }
}

test "keyboard: a perpendicular divider is not disturbed" {
    // `split(h) -> [p1, split(v) -> [p2, p3]]`: a horizontal step changes the
    // width the vertical split lives in, and must leave its own boundary — a
    // position on the OTHER axis — exactly where it was. A grid must not
    // shear when a column boundary moves by keyboard either.
    const w: i32 = 1600;
    const h: i32 = 900;
    var nodes = [_]Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 1, .right = 2 } },
        .leaf,
        .{ .split = .{ .layout = .vertical, .ratio = 0.4, .left = 3, .right = 4 } },
        .leaf,
        .leaf,
    };
    const before = dividerPos(&nodes, 2, 0, 0, h, .vertical, 1.0).?;

    var g: KeyboardGesture = .{};
    var out: [64]Adjust = undefined;
    for (0..6) |_| _ = keyboardStep(&g, &nodes, 0, 0, w, 1.0, 10, &out);

    try testing.expectEqual(before, dividerPos(&nodes, 2, 0, 0, h, .vertical, 1.0).?);
}
