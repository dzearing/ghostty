//! Deterministic serialization of `std.json.Value` — sorted keys, unescaped
//! slashes, compact or pretty (T868). Mac gets this for free from
//! `JSONSerialization`'s `.sortedKeys`; Zig's `std.json.Stringify` emits
//! object keys in insertion order, so a parse-edit-write cycle would reorder
//! a user's `settings.json` differently on every install run. The hook
//! machinery needs byte-stable output twice over: the merged fragment's
//! ownership matching compares SERIALIZED elements as strings, and the
//! install-state check compares whole files byte-for-byte.
//!
//! Scalars delegate to `std.json.Stringify` (which never escapes `/`, the
//! `.withoutEscapingSlashes` Mac has to ask for), so escaping cannot drift
//! from what `std.json.parseFromSlice` produced. Only the container walk —
//! where ordering lives — is ours.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// One-line form, `{"a":1,"b":2}` — for signature matching and set
/// comparison of individual hook elements.
pub fn compactAlloc(alloc: Allocator, v: std.json.Value) Allocator.Error![]u8 {
    return serializeAlloc(alloc, v, false);
}

/// Pretty form (two-space indent, trailing newline) — what lands on disk.
/// The trailing newline is a deliberate divergence from Mac's
/// `JSONSerialization` (which ends at the closing brace): every other
/// Ghoztty-managed text artifact ends in a newline, and diff tooling
/// complains otherwise. Byte-stability only requires that the choice never
/// changes.
pub fn prettyAlloc(alloc: Allocator, v: std.json.Value) Allocator.Error![]u8 {
    return serializeAlloc(alloc, v, true);
}

fn serializeAlloc(alloc: Allocator, v: std.json.Value, pretty: bool) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    // The only failure an Allocating writer (or our walk) can hit is memory.
    writeValue(alloc, &out.writer, v, if (pretty) 0 else null) catch
        return error.OutOfMemory;
    if (pretty) out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `indent` is the current depth for pretty output, or null for compact.
fn writeValue(alloc: Allocator, w: *Writer, v: std.json.Value, indent: ?u32) (Writer.Error || Allocator.Error)!void {
    switch (v) {
        .object => |o| {
            if (o.count() == 0) return w.writeAll("{}");

            const keys = try alloc.dupe([]const u8, o.keys());
            defer alloc.free(keys);
            std.mem.sort([]const u8, keys, {}, stringLessThan);

            try w.writeByte('{');
            for (keys, 0..) |key, i| {
                if (i > 0) try w.writeByte(',');
                try newlinePad(w, indent, 1);
                try std.json.Stringify.value(std.json.Value{ .string = key }, .{}, w);
                try w.writeAll(if (indent != null) ": " else ":");
                try writeValue(alloc, w, o.get(key).?, childIndent(indent));
            }
            try newlinePad(w, indent, 0);
            try w.writeByte('}');
        },
        .array => |a| {
            if (a.items.len == 0) return w.writeAll("[]");
            try w.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try newlinePad(w, indent, 1);
                try writeValue(alloc, w, item, childIndent(indent));
            }
            try newlinePad(w, indent, 0);
            try w.writeByte(']');
        },
        // Scalars: exactly std.json's spelling (see module doc).
        else => try std.json.Stringify.value(v, .{}, w),
    }
}

fn childIndent(indent: ?u32) ?u32 {
    return if (indent) |i| i + 1 else null;
}

/// In pretty mode, a newline plus (depth + extra) levels of two-space
/// indent; nothing in compact mode.
fn newlinePad(w: *Writer, indent: ?u32, extra: u32) Writer.Error!void {
    const depth = (indent orelse return) + extra;
    try w.writeByte('\n');
    try w.splatByteAll(' ', depth * 2);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn parse(alloc: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
}

test "compact: keys sorted regardless of input order, slashes unescaped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try parse(alloc,
        \\{"zeta":1,"alpha":{"y":false,"x":"a/slash"},"mid":[true,null,"s"]}
    );
    const got = try compactAlloc(alloc, v);
    try testing.expectEqualStrings(
        \\{"alpha":{"x":"a/slash","y":false},"mid":[true,null,"s"],"zeta":1}
    , got);
}

test "compact: identical however the input was ordered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try compactAlloc(alloc, try parse(alloc, "{\"a\":1,\"b\":2}"));
    const b = try compactAlloc(alloc, try parse(alloc, "{\"b\":2,\"a\":1}"));
    try testing.expectEqualStrings(a, b);
}

test "pretty: golden shape with nesting, empties stay inline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try parse(alloc,
        \\{"b":{"n":10},"a":[1,{"k":"v"}],"empty_o":{},"empty_a":[]}
    );
    const got = try prettyAlloc(alloc, v);
    try testing.expectEqualStrings(
        \\{
        \\  "a": [
        \\    1,
        \\    {
        \\      "k": "v"
        \\    }
        \\  ],
        \\  "b": {
        \\    "n": 10
        \\  },
        \\  "empty_a": [],
        \\  "empty_o": {}
        \\}
        \\
    , got);
}

test "string escaping matches std.json (quotes escaped, slashes not)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try parse(alloc,
        \\{"cmd":"bash '/x/y.sh' a \"b\"\nc"}
    );
    const got = try compactAlloc(alloc, v);
    try testing.expectEqualStrings(
        \\{"cmd":"bash '/x/y.sh' a \"b\"\nc"}
    , got);
}

test "round-trip: pretty output reparses to an equal compact form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\{"hooks":{"Stop":[{"hooks":[{"command":"x","timeout":10,"type":"command"}]}]},"theme":"dark"}
    ;
    const first = try compactAlloc(alloc, try parse(alloc, src));
    const pretty = try prettyAlloc(alloc, try parse(alloc, first));
    const second = try compactAlloc(alloc, try parse(alloc, pretty));
    try testing.expectEqualStrings(first, second);
}
