const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

// The dependency-free JSON helper the bundled hook scripts are built on
// (T866). The Mac flow's bundled scripts shelled out to `jq` and nagged the
// user to install it; a clean Windows box has no jq and the whole point of
// the agent integration is that nothing needs manual wiring. `ghoztty` is by
// definition present wherever the scripts are installed (the app installs
// both), so the app's own JSON is the one parser that is always there — on
// both platforms, because this action lives in the shared CLI core.
//
// Three verbs, matching exactly what the scripts need and nothing more:
//
//   get    — read a JSON object (stdin, or --file=PATH) and print the value
//            of the first listed key holding a non-empty string. With
//            --each, print one line per listed key instead (empty line for a
//            missing/empty/non-string value; embedded newlines become
//            spaces so the output stays line-aligned).
//   merge  — read-modify-write a JSON object file: set each KEY VALUE pair
//            as a string, preserving unrelated keys. Serialized against
//            concurrent writers via the same `<file>.lock` mkdir-mutex
//            protocol the bash scripts used (an old plugin's script and this
//            CLI can race the same state file safely), written via a unique
//            same-directory temp file and an atomic rename, and self-healing:
//            an unparseable state file resets to `{}` instead of wedging.
//   encode — read raw text on stdin and print it as a JSON string literal.
//
// `get` deliberately never fails: a missing file, unparseable input, or
// absent key prints nothing and exits 0, mirroring `jq -r '... // empty'`
// with stderr discarded — the scripts treat emptiness as the signal.

pub const Options = struct {
    _arena: ?ArenaAllocator = null,

    _arguments: std.ArrayList([:0]const u8) = .empty,

    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        try self._arguments.append(alloc, try alloc.dupeZ(u8, arg));
        while (iter.next()) |param| {
            try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
        }

        return false;
    }

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// A parsed `+json` invocation.
pub const Spec = union(enum) {
    get: struct {
        keys: []const []const u8,
        file: ?[]const u8,
        each: bool,
    },
    merge: struct {
        file: []const u8,
        keys: []const []const u8,
        values: []const []const u8,
    },
    encode,
    invalid: []const u8,
};

/// Parse the raw argument vector (everything after `+json`) into a Spec.
/// Pure logic so it unit-tests in every lane. Slices alias the input.
pub fn parseSpec(alloc: Allocator, arguments: []const [:0]const u8) Allocator.Error!Spec {
    if (arguments.len == 0) return .{ .invalid = "missing subcommand: get, merge, or encode" };

    const sub = arguments[0];
    const rest = arguments[1..];

    if (std.mem.eql(u8, sub, "encode")) {
        if (rest.len != 0) return .{ .invalid = "encode takes no arguments (it reads stdin)" };
        return .encode;
    }

    if (std.mem.eql(u8, sub, "get")) {
        var keys: std.ArrayList([]const u8) = .empty;
        var file: ?[]const u8 = null;
        var each = false;
        for (rest) |arg| {
            if (std.mem.startsWith(u8, arg, "--file=")) {
                file = arg["--file=".len..];
            } else if (std.mem.eql(u8, arg, "--each")) {
                each = true;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                return .{ .invalid = "unknown flag for get (expected --file=PATH or --each)" };
            } else {
                try keys.append(alloc, arg);
            }
        }
        if (keys.items.len == 0) return .{ .invalid = "get needs at least one key" };
        return .{ .get = .{ .keys = keys.items, .file = file, .each = each } };
    }

    if (std.mem.eql(u8, sub, "merge")) {
        if (rest.len < 3) return .{ .invalid = "merge needs a file and at least one KEY VALUE pair" };
        const file = rest[0];
        const pairs = rest[1..];
        if (pairs.len % 2 != 0) return .{ .invalid = "merge takes KEY VALUE pairs (odd argument count)" };
        var keys: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < pairs.len) : (i += 2) {
            if (std.mem.startsWith(u8, pairs[i], "--"))
                return .{ .invalid = "merge takes no flags, only FILE then KEY VALUE pairs" };
            try keys.append(alloc, pairs[i]);
            try values.append(alloc, pairs[i + 1]);
        }
        return .{ .merge = .{ .file = file, .keys = keys.items, .values = values.items } };
    }

    return .{ .invalid = "unknown subcommand: expected get, merge, or encode" };
}

/// A UTF-8 BOM at the head of the input is skipped before parsing: Windows
/// pipelines (PowerShell 5.1 piping to a native exe among them) love to
/// prepend one, and a payload that parses everywhere else must parse here.
fn stripBom(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) return text[3..];
    return text;
}

/// The value of the first key in `keys` holding a non-empty string in the
/// JSON object `text`, or null. Unparseable/non-object input is null — never
/// an error — matching the scripts' `jq -r '(.a // .b) // empty'` contract.
/// The returned slice is allocated from `alloc` (arena expected).
pub fn getFirst(alloc: Allocator, text_raw: []const u8, keys: []const []const u8) ?[]const u8 {
    const text = stripBom(text_raw);
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}) catch return null;
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .string => |s| if (s.len > 0) return s,
            else => {},
        }
    }
    return null;
}

/// Write one line per key: the key's string value with embedded newlines
/// flattened to spaces, or an empty line when missing/empty/non-string.
/// Line-alignment is the contract — callers `read -r` one line per key.
pub fn writeEach(
    writer: *std.Io.Writer,
    alloc: Allocator,
    text_raw: []const u8,
    keys: []const []const u8,
) std.Io.Writer.Error!void {
    const text = stripBom(text_raw);
    const obj: ?std.json.ObjectMap = obj: {
        const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}) catch break :obj null;
        break :obj switch (root) {
            .object => |o| o,
            else => null,
        };
    };
    for (keys) |key| {
        value: {
            const o = obj orelse break :value;
            const value = o.get(key) orelse break :value;
            const s = switch (value) {
                .string => |s| s,
                else => break :value,
            };
            for (s) |c| try writer.writeByte(if (c == '\n' or c == '\r') ' ' else c);
        }
        try writer.writeByte('\n');
    }
}

/// Merge KEY VALUE string pairs into the JSON object `cur` (null or
/// unparseable or non-object heals to `{}`), returning the compact
/// serialization. Unrelated keys and their (possibly non-string) values are
/// preserved.
pub fn mergeText(
    alloc: Allocator,
    cur: ?[]const u8,
    keys: []const []const u8,
    values: []const []const u8,
) Allocator.Error![]u8 {
    std.debug.assert(keys.len == values.len);
    var obj: std.json.ObjectMap = obj: {
        const text = stripBom(cur orelse break :obj std.json.ObjectMap.init(alloc));
        const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}) catch
            break :obj std.json.ObjectMap.init(alloc);
        break :obj switch (root) {
            .object => |o| o,
            else => std.json.ObjectMap.init(alloc),
        };
    };
    for (keys, values) |key, value| {
        try obj.put(key, .{ .string = value });
    }
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = obj }, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // Allocating writer only fails on OOM.
    };
}

/// `text` as a JSON string literal (quotes included).
pub fn encodeAlloc(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // Allocating writer only fails on OOM.
    };
}

/// Cap on stdin/state-file input. Hook payloads carry whole prompts; 16MB is
/// far above any real payload without letting a runaway pipe eat the box.
const input_max = 16 * 1024 * 1024;

/// How the bash scripts' mkdir-mutex behaves, mirrored exactly so both
/// implementations interoperate on the same lock: retry at 100ms up to 30
/// tries (~3s), reclaim a lock older than 60s (a killed holder), then
/// proceed best-effort — a hook must degrade, never wedge the agent's turn.
const lock_tries_max = 30;
const lock_retry_ns: u64 = 100 * std.time.ns_per_ms;
const lock_stale_ns: i128 = 60 * std.time.ns_per_s;

fn lockAcquire(lock_path: []const u8) bool {
    var tries: usize = 0;
    var reclaims: usize = 0;
    while (true) {
        std.fs.cwd().makeDir(lock_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Reclaim a stale lock left behind by a killed holder.
                // Bounded (unlike the scripts') so a clock skew can't spin.
                if (reclaims < 3) stale: {
                    var dir = std.fs.cwd().openDir(lock_path, .{}) catch break :stale;
                    const stat = dir.stat() catch {
                        dir.close();
                        break :stale;
                    };
                    dir.close();
                    if (std.time.nanoTimestamp() - stat.mtime > lock_stale_ns) {
                        reclaims += 1;
                        std.fs.cwd().deleteDir(lock_path) catch {};
                        continue;
                    }
                }
                tries += 1;
                if (tries > lock_tries_max) return false;
                std.Thread.sleep(lock_retry_ns);
                continue;
            },
            else => return false,
        };
        return true;
    }
}

fn lockRelease(lock_path: []const u8) void {
    std.fs.cwd().deleteDir(lock_path) catch {};
}

fn readInput(alloc: Allocator, file: ?[]const u8) ?[]u8 {
    if (file) |path| {
        const f = std.fs.cwd().openFile(path, .{}) catch return null;
        defer f.close();
        return f.readToEndAlloc(alloc, input_max) catch null;
    }
    return std.fs.File.stdin().readToEndAlloc(alloc, input_max) catch null;
}

/// Run a merge against the file on disk: lock, read, merge, atomic replace.
/// Failures degrade silently (matching the scripts' unchecked `mv`) — the
/// worst outcome must be a stale banner, never a broken hook.
fn runMerge(
    alloc: Allocator,
    file: []const u8,
    keys: []const []const u8,
    values: []const []const u8,
) Allocator.Error!void {
    const lock_path = try std.mem.concat(alloc, u8, &.{ file, ".lock" });
    const locked = lockAcquire(lock_path);
    defer if (locked) lockRelease(lock_path);

    const cur: ?[]u8 = cur: {
        const f = std.fs.cwd().openFile(file, .{}) catch break :cur null;
        defer f.close();
        break :cur f.readToEndAlloc(alloc, input_max) catch null;
    };
    const merged = try mergeText(alloc, cur, keys, values);

    // Unique temp beside the destination (same volume keeps the rename
    // atomic), then rename over the state file.
    const dir_path = std.fs.path.dirname(file) orelse ".";
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch return;
    defer dir.close();

    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const tmp_name = try std.fmt.allocPrint(alloc, ".merge.{x}", .{&rand_bytes});
    dir.writeFile(.{ .sub_path = tmp_name, .data = merged }) catch return;
    dir.rename(tmp_name, std.fs.path.basename(file)) catch {
        dir.deleteFile(tmp_name) catch {};
    };
}

/// Local JSON helpers for the bundled agent hook scripts.
///
/// This is a plumbing command for scripts, not a general JSON tool: it
/// exists so the hook scripts Ghoztty installs for coding agents need no
/// external JSON dependency (`jq`) on either platform.
///
/// Subcommands:
///
///   * `get <key> [key...]`: Read a JSON object from stdin (or `--file`)
///     and print the value of the first listed key that holds a non-empty
///     string. Prints nothing (exit 0) when no key matches or the input
///     is not a JSON object. With `--each`, print one line per listed key
///     instead — empty line for a missing value, newlines in values
///     flattened to spaces.
///
///   * `merge <file> <key> <value> [key value...]`: Set string keys in the
///     JSON object file, preserving unrelated keys, creating the file if
///     needed, healing an unparseable file to `{}`. The write is atomic
///     and serialized against concurrent writers via a `<file>.lock`
///     mkdir mutex.
///
///   * `encode`: Print stdin as a JSON string literal.
///
/// Flags (get only):
///
///   * `--file=<path>`: Read the JSON object from this file instead of
///     stdin. A missing file reads as empty input.
///
///   * `--each`: One output line per requested key.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const spec = try parseSpec(alloc, opts._arguments.items);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    switch (spec) {
        .invalid => |msg| {
            try stderr.print("+json: {s}\n", .{msg});
            try stderr.print("usage: +json get KEY [KEY...] [--file=PATH] [--each] | +json merge FILE KEY VALUE [KEY VALUE...] | +json encode\n", .{});
            return 2;
        },
        .get => |g| {
            const text = readInput(alloc, g.file) orelse "";
            if (g.each) {
                try writeEach(stdout, alloc, text, g.keys);
            } else if (getFirst(alloc, text, g.keys)) |value| {
                try stdout.writeAll(value);
                try stdout.writeByte('\n');
            }
        },
        .merge => |m| {
            try runMerge(alloc, m.file, m.keys, m.values);
        },
        .encode => {
            const text = readInput(alloc, null) orelse "";
            const literal = try encodeAlloc(alloc, text);
            try stdout.writeAll(literal);
            try stdout.writeByte('\n');
        },
    }

    stdout.flush() catch {};
    return 0;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn testSpec(alloc: Allocator, argv: []const [:0]const u8) !Spec {
    return parseSpec(alloc, argv);
}

test "parseSpec: get with keys, file, each" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const spec = try testSpec(alloc, &.{ "get", "prompt" });
        try testing.expect(spec == .get);
        try testing.expectEqual(@as(usize, 1), spec.get.keys.len);
        try testing.expectEqualStrings("prompt", spec.get.keys[0]);
        try testing.expect(spec.get.file == null);
        try testing.expect(!spec.get.each);
    }
    {
        const spec = try testSpec(alloc, &.{ "get", "session_id", "sessionId", "--file=C:\\x\\state.json", "--each" });
        try testing.expect(spec == .get);
        try testing.expectEqual(@as(usize, 2), spec.get.keys.len);
        try testing.expectEqualStrings("C:\\x\\state.json", spec.get.file.?);
        try testing.expect(spec.get.each);
    }
    {
        const spec = try testSpec(alloc, &.{"get"});
        try testing.expect(spec == .invalid);
    }
    {
        const spec = try testSpec(alloc, &.{ "get", "k", "--nope" });
        try testing.expect(spec == .invalid);
    }
}

test "parseSpec: merge pairs" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const spec = try testSpec(alloc, &.{ "merge", "state.json", "title", "T1", "goal", "g" });
        try testing.expect(spec == .merge);
        try testing.expectEqualStrings("state.json", spec.merge.file);
        try testing.expectEqual(@as(usize, 2), spec.merge.keys.len);
        try testing.expectEqualStrings("goal", spec.merge.keys[1]);
        try testing.expectEqualStrings("g", spec.merge.values[1]);
    }
    {
        // Odd pair count is a usage error, not a silent drop.
        const spec = try testSpec(alloc, &.{ "merge", "state.json", "title" });
        try testing.expect(spec == .invalid);
    }
    {
        const spec = try testSpec(alloc, &.{"merge"});
        try testing.expect(spec == .invalid);
    }
}

test "parseSpec: encode and unknowns" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expect((try testSpec(alloc, &.{"encode"})) == .encode);
    try testing.expect((try testSpec(alloc, &.{ "encode", "x" })) == .invalid);
    try testing.expect((try testSpec(alloc, &.{"frobnicate"})) == .invalid);
    try testing.expect((try testSpec(alloc, &.{})) == .invalid);
}

test "getFirst: first non-empty key wins, escapes decoded" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const text =
        \\{"session_id":"","sessionId":"abc-123","prompt":"line1\nline2 \"quoted\""}
    ;
    // Empty string does not satisfy; falls through to the next key.
    try testing.expectEqualStrings(
        "abc-123",
        getFirst(alloc, text, &.{ "session_id", "sessionId" }).?,
    );
    // JSON escapes arrive decoded, like jq -r.
    try testing.expectEqualStrings(
        "line1\nline2 \"quoted\"",
        getFirst(alloc, text, &.{"prompt"}).?,
    );
    // Missing key, non-object input, garbage input: all null, never error.
    try testing.expect(getFirst(alloc, text, &.{"nope"}) == null);
    try testing.expect(getFirst(alloc, "[1,2]", &.{"a"}) == null);
    try testing.expect(getFirst(alloc, "not json", &.{"a"}) == null);
    try testing.expect(getFirst(alloc, "", &.{"a"}) == null);
    // A UTF-8 BOM (PowerShell 5.1 native-pipe artifact) is tolerated.
    try testing.expectEqualStrings(
        "v",
        getFirst(alloc, "\xEF\xBB\xBF{\"a\":\"v\"}", &.{"a"}).?,
    );
    // Non-string values don't satisfy a key.
    try testing.expect(getFirst(alloc, "{\"a\":42}", &.{"a"}) == null);
}

test "writeEach: line per key, newlines flattened" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.Io.Writer.Allocating = .init(alloc);
    try writeEach(&buf.writer, alloc,
        \\{"title":"T866","did":"a\nb","n":7}
    , &.{ "title", "missing", "did", "n" });
    try testing.expectEqualStrings("T866\n\na b\n\n", buf.written());

    // Garbage input still yields one (empty) line per key.
    var buf2: std.Io.Writer.Allocating = .init(alloc);
    try writeEach(&buf2.writer, alloc, "garbage", &.{ "a", "b" });
    try testing.expectEqualStrings("\n\n", buf2.written());
}

test "mergeText: set, preserve, heal" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Fresh file.
    {
        const out = try mergeText(alloc, null, &.{"title"}, &.{"T1"});
        try testing.expectEqualStrings("{\"title\":\"T1\"}", out);
    }
    // Overwrite one key, preserve others including non-string values.
    {
        const out = try mergeText(
            alloc,
            "{\"title\":\"old\",\"count\":3,\"flag\":true}",
            &.{"title"},
            &.{"new"},
        );
        const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, out, .{});
        try testing.expectEqualStrings("new", root.object.get("title").?.string);
        try testing.expectEqual(@as(i64, 3), root.object.get("count").?.integer);
        try testing.expect(root.object.get("flag").?.bool);
    }
    // Self-heal: unparseable and non-object inputs reset to {}.
    {
        const out = try mergeText(alloc, "###corrupt###", &.{"k"}, &.{"v"});
        try testing.expectEqualStrings("{\"k\":\"v\"}", out);
    }
    {
        const out = try mergeText(alloc, "[1,2,3]", &.{"k"}, &.{"v"});
        try testing.expectEqualStrings("{\"k\":\"v\"}", out);
    }
    // Values with quotes/newlines survive a round-trip.
    {
        const out = try mergeText(alloc, null, &.{"did"}, &.{"- [x] a\n- [x] \"b\""});
        const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, out, .{});
        try testing.expectEqualStrings("- [x] a\n- [x] \"b\"", root.object.get("did").?.string);
    }
}

test "encodeAlloc: JSON string literal" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings("\"\"", try encodeAlloc(alloc, ""));
    try testing.expectEqualStrings(
        "\"a \\\"b\\\" \\n c\"",
        try encodeAlloc(alloc, "a \"b\" \n c"),
    );
}

test "runMerge: creates, merges, and heals a real file" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    const file = try std.fs.path.join(alloc, &.{ dir_path, "state.json" });

    // Create from nothing.
    try runMerge(alloc, file, &.{"title"}, &.{"T866"});
    // Merge preserves and overwrites.
    try runMerge(alloc, file, &.{ "goal", "title" }, &.{ "ship it", "T866b" });
    {
        const text = try tmp.dir.readFileAlloc(alloc, "state.json", 4096);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
        try testing.expectEqualStrings("T866b", root.object.get("title").?.string);
        try testing.expectEqualStrings("ship it", root.object.get("goal").?.string);
    }
    // No temp litter, no leaked lock.
    {
        var it = tmp.dir.iterate();
        var count: usize = 0;
        while (try it.next()) |entry| {
            try testing.expectEqualStrings("state.json", entry.name);
            count += 1;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    // Corrupt state heals rather than wedging.
    try tmp.dir.writeFile(.{ .sub_path = "state.json", .data = "###" });
    try runMerge(alloc, file, &.{"k"}, &.{"v"});
    {
        const text = try tmp.dir.readFileAlloc(alloc, "state.json", 4096);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
        try testing.expectEqualStrings("v", root.object.get("k").?.string);
    }
}

test "runMerge: proceeds best-effort past a held lock" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    const file = try std.fs.path.join(alloc, &.{ dir_path, "state.json" });

    // A fresh (non-stale) lock held by "someone else": the merge must still
    // land after the ~3s retry cap rather than wedging the hook, and must
    // not delete the foreign lock.
    try tmp.dir.makeDir("state.json.lock");
    try runMerge(alloc, file, &.{"k"}, &.{"v"});
    const text = try tmp.dir.readFileAlloc(alloc, "state.json", 4096);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
    try testing.expectEqualStrings("v", root.object.get("k").?.string);
    var lock = try tmp.dir.openDir("state.json.lock", .{});
    lock.close();
}
