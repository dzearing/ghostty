//! Pure model for the machine chooser's per-row management menu (T176), the
//! behavioral half of T173.
//!
//! Mac's `managementActions` (MachineChooserView.swift:1114-1123) is reached
//! two ways — the `⋯` button in the detail header and a right-click on a
//! master-list row — and both show the SAME item list, derived from the row:
//!
//! | Row        | Menu                                                       |
//! |------------|------------------------------------------------------------|
//! | Local      | none (the row has no management actions at all)            |
//! | direct-TCP | `Host Settings…`                                           |
//! | relay      | `Host Settings…` │ `Rename…` │ `Remove from Account…`      |
//!
//! Nothing is ever greyed: an action that does not apply is ABSENT, matching
//! Mac (`if machine.isRelay` omits the rename/remove group rather than
//! disabling it).
//!
//! `Host Settings…` needs the per-host defaults store, which Windows does not
//! have yet (T174) — so `State.host_settings` gates it, and T174 flips one
//! bool at the call site rather than reshaping the menu. With it off a
//! direct-TCP row has nothing to show and gets no menu, which is why
//! `hasMenu` is derived from `build` instead of from the row kind.
//!
//! No OS imports, so this runs in every app-runtime test lane; the HMENU
//! construction, `TrackPopupMenuEx` and the dispatch live in
//! `MachineChooser.zig` (the `context_menu.zig` / `Surface.zig` split).

const std = @import("std");

/// Stable command ids for `TrackPopupMenuEx`'s `TPM_RETURNCMD`. Zero is
/// reserved — the API returns 0 for "dismissed without choosing".
pub const Id = enum(usize) {
    host_settings = 1,
    rename = 2,
    remove = 3,
};

/// What kind of machine a chooser row names. `local` is the this-machine row;
/// `direct` is a host:port machine (no account resource behind it, so it can
/// never be renamed or removed); `relay` is an enrolled account device.
pub const Kind = enum { local, direct, relay };

/// The row the menu is being built for, plus which capabilities this build
/// actually has wired up.
pub const State = struct {
    kind: Kind,
    /// Whether `Host Settings…` has somewhere to go (T174's per-host defaults
    /// store). False on Windows today.
    host_settings: bool = false,
};

pub const Item = union(enum) {
    separator,
    cmd: struct {
        id: Id,
        /// UTF-16 title ready for `AppendMenuW`.
        title: [:0]const u16,
        /// Mac gives this item `role: .destructive`. Win32 popup menus have no
        /// destructive role, so this only records the intent (and drives the
        /// confirmation the item is required to show).
        destructive: bool = false,
    },
};

/// Upper bound on `build`'s output: 3 commands and the 2 separators between
/// their groups.
pub const max_items = 5;

fn u16lit(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// The menu for `state`, written into `out` and returned as a slice (empty
/// when the row has no management actions). Groups are separated only when
/// both sides are present, so a gated-away `Host Settings…` never leaves a
/// leading separator behind. Pure — unit-tested below.
pub fn build(state: State, out: *[max_items]Item) []Item {
    if (state.kind == .local) return out[0..0];

    var n: usize = 0;
    if (state.host_settings) {
        out[n] = .{ .cmd = .{ .id = .host_settings, .title = u16lit("Host Settings...") } };
        n += 1;
    }

    // Rename/remove act on the ACCOUNT resource, so they exist only for a
    // relay device — a direct-TCP machine has no device id to PATCH or DELETE.
    if (state.kind == .relay) {
        if (n > 0) {
            out[n] = .separator;
            n += 1;
        }
        out[n] = .{ .cmd = .{ .id = .rename, .title = u16lit("Rename...") } };
        n += 1;
        out[n] = .separator;
        n += 1;
        out[n] = .{ .cmd = .{
            .id = .remove,
            .title = u16lit("Remove from Account..."),
            .destructive = true,
        } };
        n += 1;
    }

    return out[0..n];
}

/// True when the row has a menu worth opening. Derived from `build` so the
/// affordance (the `⋯` button, the right-click) can never appear over an
/// empty popup.
pub fn hasMenu(state: State) bool {
    var buf: [max_items]Item = undefined;
    return build(state, &buf).len > 0;
}

/// The device name a `Rename…` should submit, or null when there is nothing
/// to do: Mac trims whitespace, then drops an empty name and a no-op rename
/// (`promptRename`, MachineChooserView.swift:1231-1232). Pure.
pub fn newName(raw: []const u8, current: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, current)) return null;
    return trimmed;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

/// The command ids in `state`'s menu, with separators as null — the shape
/// assertions read against this.
fn shape(state: State, out: *[max_items]?Id) []?Id {
    var buf: [max_items]Item = undefined;
    const items = build(state, &buf);
    for (items, 0..) |item, i| out[i] = switch (item) {
        .separator => null,
        .cmd => |c| c.id,
    };
    return out[0..items.len];
}

test "local rows have no management menu at all" {
    var buf: [max_items]Item = undefined;
    try testing.expectEqual(@as(usize, 0), build(.{ .kind = .local }, &buf).len);
    try testing.expectEqual(@as(usize, 0), build(.{ .kind = .local, .host_settings = true }, &buf).len);
    try testing.expect(!hasMenu(.{ .kind = .local }));
    try testing.expect(!hasMenu(.{ .kind = .local, .host_settings = true }));
}

test "mac shape: relay row is Host Settings | Rename | Remove" {
    var out: [max_items]?Id = undefined;
    const got = shape(.{ .kind = .relay, .host_settings = true }, &out);
    const want = [_]?Id{ .host_settings, null, .rename, null, .remove };
    try testing.expectEqualSlices(?Id, &want, got);
}

test "mac shape: direct-TCP row is Host Settings alone" {
    var out: [max_items]?Id = undefined;
    const got = shape(.{ .kind = .direct, .host_settings = true }, &out);
    const want = [_]?Id{.host_settings};
    try testing.expectEqualSlices(?Id, &want, got);
}

test "rename/remove are account actions: never on a direct-TCP row" {
    var buf: [max_items]Item = undefined;
    for ([_]bool{ false, true }) |hs| {
        for (build(.{ .kind = .direct, .host_settings = hs }, &buf)) |item| switch (item) {
            .separator => {},
            .cmd => |c| try testing.expect(c.id == .host_settings),
        };
    }
}

test "gating Host Settings off leaves no leading separator" {
    var out: [max_items]?Id = undefined;
    const got = shape(.{ .kind = .relay, .host_settings = false }, &out);
    const want = [_]?Id{ .rename, null, .remove };
    try testing.expectEqualSlices(?Id, &want, got);
}

test "a gated-away menu is reported as absent, not empty-but-open" {
    // T176 ships with host_settings off, so a direct-TCP row would otherwise
    // pop an empty menu: `hasMenu` must say no.
    try testing.expect(!hasMenu(.{ .kind = .direct, .host_settings = false }));
    try testing.expect(hasMenu(.{ .kind = .direct, .host_settings = true }));
    try testing.expect(hasMenu(.{ .kind = .relay, .host_settings = false }));
}

test "no menu ever starts or ends with a separator" {
    var buf: [max_items]Item = undefined;
    for ([_]Kind{ .local, .direct, .relay }) |kind| {
        for ([_]bool{ false, true }) |hs| {
            const items = build(.{ .kind = kind, .host_settings = hs }, &buf);
            if (items.len == 0) continue;
            try testing.expect(items[0] != .separator);
            try testing.expect(items[items.len - 1] != .separator);
        }
    }
}

test "nothing is ever greyed: absent instead (mac parity)" {
    // Every item a build emits is a live command; there is no disabled state
    // in the model, which is what keeps it honest with Mac's `if isRelay`.
    var buf: [max_items]Item = undefined;
    const items = build(.{ .kind = .relay, .host_settings = true }, &buf);
    var cmds: usize = 0;
    for (items) |item| switch (item) {
        .separator => {},
        .cmd => cmds += 1,
    };
    try testing.expectEqual(@as(usize, 3), cmds);
}

test "only Remove is destructive" {
    var buf: [max_items]Item = undefined;
    for (build(.{ .kind = .relay, .host_settings = true }, &buf)) |item| switch (item) {
        .separator => {},
        .cmd => |c| try testing.expectEqual(c.id == .remove, c.destructive),
    };
}

test "command ids are unique and nonzero" {
    var buf: [max_items]Item = undefined;
    var seen = std.StaticBitSet(16).initEmpty();
    for (build(.{ .kind = .relay, .host_settings = true }, &buf)) |item| switch (item) {
        .separator => {},
        .cmd => |c| {
            const v = @intFromEnum(c.id);
            try testing.expect(v != 0);
            try testing.expect(!seen.isSet(v));
            seen.set(v);
        },
    };
}

test "newName: trims, and drops empty or unchanged" {
    try testing.expectEqualStrings("Winbox", newName("  Winbox  ", "Old").?);
    try testing.expectEqualStrings("Win box", newName("Win box", "Old").?);
    try testing.expect(newName("", "Old") == null);
    try testing.expect(newName("   \t\r\n", "Old") == null);
    try testing.expect(newName("Old", "Old") == null);
    try testing.expect(newName("  Old  ", "Old") == null);
    // Case is meaningful — a case-only rename is a real rename.
    try testing.expectEqualStrings("OLD", newName("OLD", "Old").?);
}

test {
    testing.refAllDecls(@This());
}
