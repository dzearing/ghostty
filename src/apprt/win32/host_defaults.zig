//! Per-host remote defaults (T174): the default working directory and shell a
//! NEW session on a given remote machine starts with, when the caller passes no
//! explicit `--working-directory` / `--shell`.
//!
//! This is the win32 port of Mac's `MachineSettings` + `MachineSettingsStore`
//! (`macos/Sources/Features/Remote/Machine.swift`). Same semantics, same key
//! rule, same "empty means use the remote's own default" contract:
//!
//! - **Key** — the relay DEVICE ID for an enrolled machine (stable across
//!   renames and directory refetches), else `host:port` for a direct-TCP
//!   machine (its only durable identity). Mac's `Machine.settingsKey`.
//! - **Values are REMOTE-native.** `C:\dev` + `wsl.exe` on a Windows host,
//!   `/home/me` + `/bin/zsh` on a Linux one. They ride the agent OPEN's
//!   existing optional `cwd`/`shell` fields, so an older agent ignores nothing
//!   it does not understand.
//! - **Where they apply.** A new remote WINDOW takes both (cwd + shell); a new
//!   tab/split on an existing remote window takes only the SHELL, because its
//!   cwd inherits from the parent pane and a per-host default must not yank a
//!   split away from where its parent is (Mac
//!   `BaseTerminalController.newSplit` / `TerminalController`). Explicit CLI
//!   flags always win over the store.
//! - **Never purged on sign-out.** These are local user preferences (no
//!   secrets, no account resources — the keys are device ids / host:port
//!   strings), so unlike the relay device cache a 401 or a sign-out must not
//!   lose the user's shell choice.
//!
//! Storage: one small JSON file, `%LOCALAPPDATA%\ghoztty\host_defaults.json`
//! (`-debug` suffixed in Debug builds, so dev/test windows never touch the
//! release app's settings), overridable in full by `GHOSTTY_HOST_DEFAULTS`
//! (the `GHOSTTY_ACCOUNT_STORE` pattern — how the acceptance script points the
//! app at a scratch file). A file under LOCALAPPDATA rather than the registry
//! because that is the win32 analog this codebase already uses for app-owned
//! preferences (`window_memory.zig`, `update_check.zig`, `account.dat`);
//! Mac's UserDefaults has no Windows counterpart worth inventing one for.
//!
//! Shape (this file's own format — nothing shares it with Mac's UserDefaults
//! blob):
//!
//! ```json
//! {"hosts":[{"key":"dev-abc","working_directory":"C:\\dev","shell":"wsl.exe"}]}
//! ```
//!
//! Everything except the four IO functions at the bottom is pure (std only, no
//! OS imports), so the parse/normalize/key/round-trip rules are unit-tested.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.win32);

/// Longest accepted stored value. A path or shell longer than this is REFUSED
/// rather than truncated — a half path silently used as a cwd is worse than no
/// default at all (the `ConfirmDialog.readEdit` rule).
pub const MAX_VALUE_LEN: usize = 512;

/// Longest accepted key: a relay device id (a uuid-ish string) or `host:port`.
pub const MAX_KEY_LEN: usize = 256;

/// Cap on stored machines, so a corrupt or hand-grown file cannot make the
/// store unbounded. Far above any real account's device count.
pub const MAX_ENTRIES: usize = 256;

/// The per-host defaults for one machine. Null means "use the remote's own
/// default" (i.e. exactly today's behavior), never "empty string".
pub const Settings = struct {
    working_directory: ?[]const u8 = null,
    shell: ?[]const u8 = null,

    pub fn isEmpty(self: Settings) bool {
        return self.working_directory == null and self.shell == null;
    }
};

/// A machine's stable identity, as the store keys on it. Mirrors
/// `Window.RemoteMachine` without importing it, so this module stays OS-free.
pub const Key = union(enum) {
    /// An enrolled relay device, keyed by its device id.
    relay: []const u8,
    /// A direct-TCP machine, keyed by `host:port`.
    tcp: struct { host: []const u8, port: u16 },
};

/// The key string for `key`, written into `buf`, or null when it has no usable
/// identity (empty device id / host, or too long to key on). Pure.
///
/// The host is NOT normalized (no lowercasing, no `.local` stripping) — Mac's
/// `settingsKey` interpolates the host verbatim, and diverging here would make
/// the same machine key differently on the two platforms.
pub fn formatKey(buf: []u8, key: Key) ?[]const u8 {
    switch (key) {
        .relay => |id| {
            if (id.len == 0 or id.len > buf.len or id.len > MAX_KEY_LEN) return null;
            @memcpy(buf[0..id.len], id);
            return buf[0..id.len];
        },
        .tcp => |t| {
            if (t.host.len == 0) return null;
            const s = std.fmt.bufPrint(buf, "{s}:{d}", .{ t.host, t.port }) catch return null;
            if (s.len > MAX_KEY_LEN) return null;
            return s;
        },
    }
}

/// A stored/typed value as the store keeps it: whitespace-trimmed, with empty
/// (and over-long) collapsing to null. Pure. Returns a slice INTO `v`.
pub fn normalize(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len > MAX_VALUE_LEN) return null;
    return trimmed;
}

/// Shell presets offered by the Host Settings combo box, matching Mac's
/// `shellPresets` exactly: the Windows shells the agent has per-shell argv
/// conventions for (cmd `/c`, powershell/pwsh `-Command`, wsl `--` — see
/// `pty_child.zig`), plus the common POSIX shells. The combo is editable, so
/// any other path can be typed.
pub const shell_presets = [_][]const u8{
    "cmd.exe",
    "powershell.exe",
    "pwsh.exe",
    "wsl.exe",
    "/bin/bash",
    "/bin/zsh",
};

/// One machine's row as it appears on disk.
const Entry = struct {
    key: []const u8,
    working_directory: ?[]const u8 = null,
    shell: ?[]const u8 = null,
};

/// The whole file. A named object (not a bare array) so a later field can be
/// added without changing the document's type.
const FileShape = struct {
    hosts: []const Entry = &.{},
};

/// The parsed store: every machine's defaults, all strings owned by its arena.
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .{},

    pub fn init(alloc: Allocator) Store {
        return .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Parse a store document. NEVER fails: a malformed, truncated or
    /// schema-drifted file degrades to an empty store (the Mac
    /// `try? JSONDecoder` rule) so one bad write can't wedge remote windows.
    /// Rows that carry no usable value are dropped, as are duplicate keys
    /// (first wins) — `set` never writes either, so both mean a hand edit.
    pub fn parse(alloc: Allocator, text: []const u8) Store {
        var store = Store.init(alloc);
        const a = store.arena.allocator();
        // The parse allocates into our arena (including its own inner arena),
        // so its strings live exactly as long as the store and there is
        // nothing to deinit separately.
        const parsed = std.json.parseFromSlice(FileShape, a, text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return store;

        for (parsed.value.hosts) |e| {
            if (store.entries.items.len >= MAX_ENTRIES) break;
            if (e.key.len == 0 or e.key.len > MAX_KEY_LEN) continue;
            const wd = normalize(e.working_directory);
            const sh = normalize(e.shell);
            if (wd == null and sh == null) continue;
            if (store.indexOf(e.key) != null) continue;
            store.entries.append(a, .{
                .key = e.key,
                .working_directory = wd,
                .shell = sh,
            }) catch break;
        }
        return store;
    }

    fn indexOf(self: *const Store, key: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) return i;
        }
        return null;
    }

    /// The defaults stored for `key`, or empty settings when none. Slices
    /// borrow the store's arena — valid until `deinit`.
    pub fn get(self: *const Store, key: []const u8) Settings {
        const i = self.indexOf(key) orelse return .{};
        return .{
            .working_directory = self.entries.items[i].working_directory,
            .shell = self.entries.items[i].shell,
        };
    }

    /// Persist `settings` for `key`. Values are normalized; fully-empty
    /// settings REMOVE the row so the store never accumulates blanks (Mac's
    /// `set` does the same). Strings are copied into the store's arena, so the
    /// caller's buffers may go away immediately.
    pub fn set(
        self: *Store,
        key: []const u8,
        settings: Settings,
    ) error{ OutOfMemory, InvalidKey, StoreFull }!void {
        const a = self.arena.allocator();
        const wd = normalize(settings.working_directory);
        const sh = normalize(settings.shell);
        const existing = self.indexOf(key);

        if (wd == null and sh == null) {
            if (existing) |i| _ = self.entries.orderedRemove(i);
            return;
        }
        if (key.len == 0 or key.len > MAX_KEY_LEN) return error.InvalidKey;

        const dup_wd: ?[]const u8 = if (wd) |v| try a.dupe(u8, v) else null;
        const dup_sh: ?[]const u8 = if (sh) |v| try a.dupe(u8, v) else null;
        if (existing) |i| {
            self.entries.items[i].working_directory = dup_wd;
            self.entries.items[i].shell = dup_sh;
            return;
        }
        if (self.entries.items.len >= MAX_ENTRIES) return error.StoreFull;
        try self.entries.append(a, .{
            .key = try a.dupe(u8, key),
            .working_directory = dup_wd,
            .shell = dup_sh,
        });
    }

    /// The store as its on-disk JSON document. Caller frees.
    pub fn stringify(self: *const Store, alloc: Allocator) Allocator.Error![]u8 {
        return std.json.Stringify.valueAlloc(
            alloc,
            FileShape{ .hosts = self.entries.items },
            // Nulls are omitted so an absent value reads as absent rather than
            // as an explicit `null`, and the file stays hand-readable.
            .{ .emit_null_optional_fields = false, .whitespace = .indent_2 },
        );
    }
};

/// Fixed-size home for one machine's resolved defaults, so a call site can hold
/// them across a dial/OPEN without an allocation or a store kept alive. Declare
/// one on the stack, `lookup` into it, then read through the accessors.
pub const Resolved = struct {
    wd_buf: [MAX_VALUE_LEN]u8 = undefined,
    wd_len: usize = 0,
    shell_buf: [MAX_VALUE_LEN]u8 = undefined,
    shell_len: usize = 0,

    pub fn workingDirectory(self: *const Resolved) ?[]const u8 {
        return if (self.wd_len == 0) null else self.wd_buf[0..self.wd_len];
    }

    pub fn shell(self: *const Resolved) ?[]const u8 {
        return if (self.shell_len == 0) null else self.shell_buf[0..self.shell_len];
    }

    /// Copy `settings` in, dropping any value that does not fit (refused, not
    /// truncated — same rule as `MAX_VALUE_LEN`).
    pub fn assign(self: *Resolved, settings: Settings) void {
        self.wd_len = 0;
        self.shell_len = 0;
        if (settings.working_directory) |v| if (v.len <= self.wd_buf.len) {
            @memcpy(self.wd_buf[0..v.len], v);
            self.wd_len = v.len;
        };
        if (settings.shell) |v| if (v.len <= self.shell_buf.len) {
            @memcpy(self.shell_buf[0..v.len], v);
            self.shell_len = v.len;
        };
    }
};

// ---------------------------------------------------------------------
// Persistence (the only part that touches the filesystem / environment)
// ---------------------------------------------------------------------

/// Resolve the store path:
///   1. `GHOSTTY_HOST_DEFAULTS` (explicit full-path override; tests use this),
///   2. `%LOCALAPPDATA%\ghoztty\host_defaults[-debug].json`.
/// Null when neither is available. Caller frees.
pub fn storePath(alloc: Allocator) ?[]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_HOST_DEFAULTS")) |p| {
        if (p.len > 0) return p;
        alloc.free(p);
    } else |_| {}

    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const name = if (builtin.mode == .Debug)
        "host_defaults-debug.json"
    else
        "host_defaults.json";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// Largest store document read from disk. Bounds a hostile/corrupt file.
const max_file_len: usize = 1 << 20;

/// Load the store from an explicit path. An absent or unreadable file is an
/// empty store, never an error.
pub fn loadFrom(alloc: Allocator, path: []const u8) Store {
    const text = std.fs.cwd().readFileAlloc(alloc, path, max_file_len) catch
        return Store.init(alloc);
    defer alloc.free(text);
    return Store.parse(alloc, text);
}

/// Load the store from its resolved path (empty when there is none).
pub fn load(alloc: Allocator) Store {
    const path = storePath(alloc) orelse return Store.init(alloc);
    defer alloc.free(path);
    return loadFrom(alloc, path);
}

/// Write the store to an explicit path, creating the directory if needed.
pub fn saveTo(alloc: Allocator, store: *const Store, path: []const u8) !void {
    const text = try store.stringify(alloc);
    defer alloc.free(text);
    if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(text);
}

/// Persist the store to its resolved path. Best-effort: a failure is logged,
/// never surfaced — a settings write is a convenience, not worth a dialog.
pub fn save(alloc: Allocator, store: *const Store) void {
    const path = storePath(alloc) orelse return;
    defer alloc.free(path);
    saveTo(alloc, store, path) catch |err| {
        log.warn("host defaults: save failed path={s} err={}", .{ path, err });
    };
}

/// Read `key`'s defaults into `out`. A missing store, a missing row, or a
/// machine with no usable key all leave `out` empty (i.e. "remote default").
pub fn lookup(alloc: Allocator, key: Key, out: *Resolved) void {
    var key_buf: [MAX_KEY_LEN]u8 = undefined;
    const k = formatKey(&key_buf, key) orelse return;
    var store = load(alloc);
    defer store.deinit();
    out.assign(store.get(k));
}

/// Read `key`'s defaults as owned copies is deliberately NOT offered — use
/// `lookup` with a stack `Resolved`. This is the write half: load, set, save.
pub fn update(alloc: Allocator, key: Key, settings: Settings) void {
    var key_buf: [MAX_KEY_LEN]u8 = undefined;
    const k = formatKey(&key_buf, key) orelse return;
    var store = load(alloc);
    defer store.deinit();
    store.set(k, settings) catch |err| {
        log.warn("host defaults: set failed key={s} err={}", .{ k, err });
        return;
    };
    save(alloc, &store);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "formatKey: relay uses the device id verbatim" {
    var buf: [MAX_KEY_LEN]u8 = undefined;
    try testing.expectEqualStrings("dev-abc", formatKey(&buf, .{ .relay = "dev-abc" }).?);
    // Empty id has no identity to key on.
    try testing.expect(formatKey(&buf, .{ .relay = "" }) == null);
}

test "formatKey: tcp is host:port, host NOT normalized (mac parity)" {
    var buf: [MAX_KEY_LEN]u8 = undefined;
    try testing.expectEqualStrings("winbox:7777", formatKey(&buf, .{ .tcp = .{ .host = "winbox", .port = 7777 } }).?);
    try testing.expectEqualStrings("WinBox.local:1", formatKey(&buf, .{ .tcp = .{ .host = "WinBox.local", .port = 1 } }).?);
    try testing.expectEqualStrings("127.0.0.1:65535", formatKey(&buf, .{ .tcp = .{ .host = "127.0.0.1", .port = 65535 } }).?);
    try testing.expect(formatKey(&buf, .{ .tcp = .{ .host = "", .port = 7777 } }) == null);
}

test "formatKey: over-long keys are refused, not truncated" {
    var buf: [MAX_KEY_LEN]u8 = undefined;
    const long = "x" ** (MAX_KEY_LEN + 1);
    try testing.expect(formatKey(&buf, .{ .relay = long }) == null);
    try testing.expect(formatKey(&buf, .{ .tcp = .{ .host = long, .port = 1 } }) == null);
}

test "normalize: trims, and empty means remote default" {
    try testing.expectEqualStrings("C:\\dev", normalize("  C:\\dev  ").?);
    try testing.expectEqualStrings("wsl.exe", normalize("wsl.exe").?);
    try testing.expect(normalize(null) == null);
    try testing.expect(normalize("") == null);
    try testing.expect(normalize("   \t\r\n") == null);
    // Interior spaces are meaningful (`C:\Program Files\…`).
    try testing.expectEqualStrings("C:\\Program Files", normalize(" C:\\Program Files ").?);
    // Over-long is refused rather than cut.
    const long = "x" ** (MAX_VALUE_LEN + 1);
    try testing.expect(normalize(long) == null);
    try testing.expect(normalize("x" ** MAX_VALUE_LEN) != null);
}

test "Settings.isEmpty" {
    try testing.expect((Settings{}).isEmpty());
    try testing.expect(!(Settings{ .shell = "wsl.exe" }).isEmpty());
    try testing.expect(!(Settings{ .working_directory = "C:\\" }).isEmpty());
}

test "store: set then get, per key" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("dev-a", .{ .working_directory = "C:\\dev", .shell = "wsl.exe" });
    try store.set("winbox:7777", .{ .shell = "/bin/zsh" });

    const a = store.get("dev-a");
    try testing.expectEqualStrings("C:\\dev", a.working_directory.?);
    try testing.expectEqualStrings("wsl.exe", a.shell.?);

    const b = store.get("winbox:7777");
    try testing.expect(b.working_directory == null);
    try testing.expectEqualStrings("/bin/zsh", b.shell.?);

    // An unknown machine reads as "remote default".
    try testing.expect(store.get("nope").isEmpty());
}

test "store: set normalizes, and empty settings remove the row" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("dev-a", .{ .working_directory = "  C:\\dev  ", .shell = "   " });
    const got = store.get("dev-a");
    try testing.expectEqualStrings("C:\\dev", got.working_directory.?);
    try testing.expect(got.shell == null);

    // Clearing both fields drops the entry entirely (no blank rows).
    try store.set("dev-a", .{ .working_directory = "", .shell = null });
    try testing.expect(store.get("dev-a").isEmpty());
    try testing.expectEqual(@as(usize, 0), store.entries.items.len);

    // Removing something that was never there is a no-op, not an error.
    try store.set("ghost", .{});
    try testing.expectEqual(@as(usize, 0), store.entries.items.len);
}

test "store: set overwrites in place without duplicating the key" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.set("dev-a", .{ .shell = "cmd.exe" });
    try store.set("dev-a", .{ .shell = "pwsh.exe", .working_directory = "D:\\" });
    try testing.expectEqual(@as(usize, 1), store.entries.items.len);
    try testing.expectEqualStrings("pwsh.exe", store.get("dev-a").shell.?);
    try testing.expectEqualStrings("D:\\", store.get("dev-a").working_directory.?);
}

test "store: the caller's buffers may go away after set" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    {
        var scratch: [16]u8 = undefined;
        @memcpy(scratch[0..7], "wsl.exe");
        try store.set("dev-a", .{ .shell = scratch[0..7] });
        @memset(&scratch, 0); // the dialog's stack buffer being reused
    }
    try testing.expectEqualStrings("wsl.exe", store.get("dev-a").shell.?);
}

test "store: bad keys and a full store are refused, not stored" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expectError(error.InvalidKey, store.set("", .{ .shell = "cmd.exe" }));
    const long_key = "k" ** (MAX_KEY_LEN + 1);
    try testing.expectError(error.InvalidKey, store.set(long_key, .{ .shell = "cmd.exe" }));

    var i: usize = 0;
    var buf: [32]u8 = undefined;
    while (i < MAX_ENTRIES) : (i += 1) {
        try store.set(try std.fmt.bufPrint(&buf, "dev-{d}", .{i}), .{ .shell = "cmd.exe" });
    }
    try testing.expectError(error.StoreFull, store.set("one-too-many", .{ .shell = "cmd.exe" }));
    // ...but updating an EXISTING row still works when full.
    try store.set("dev-0", .{ .shell = "pwsh.exe" });
    try testing.expectEqualStrings("pwsh.exe", store.get("dev-0").shell.?);
}

test "store: stringify round-trips through parse" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.set("dev-a", .{ .working_directory = "C:\\dev", .shell = "wsl.exe" });
    try store.set("winbox:7777", .{ .shell = "/bin/zsh" });

    const text = try store.stringify(testing.allocator);
    defer testing.allocator.free(text);

    var back = Store.parse(testing.allocator, text);
    defer back.deinit();
    try testing.expectEqualStrings("C:\\dev", back.get("dev-a").working_directory.?);
    try testing.expectEqualStrings("wsl.exe", back.get("dev-a").shell.?);
    try testing.expect(back.get("winbox:7777").working_directory == null);
    try testing.expectEqualStrings("/bin/zsh", back.get("winbox:7777").shell.?);
}

test "store: stringify omits absent values instead of emitting null" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.set("dev-a", .{ .shell = "wsl.exe" });
    const text = try store.stringify(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "null") == null);
    try testing.expect(std.mem.indexOf(u8, text, "working_directory") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"shell\"") != null);
}

test "store: a windows path survives JSON escaping" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.set("dev-a", .{ .working_directory = "C:\\Program Files\\x" });
    const text = try store.stringify(testing.allocator);
    defer testing.allocator.free(text);
    var back = Store.parse(testing.allocator, text);
    defer back.deinit();
    try testing.expectEqualStrings("C:\\Program Files\\x", back.get("dev-a").working_directory.?);
}

test "parse: corrupt input degrades to an empty store, never an error" {
    const cases = [_][]const u8{
        "",
        "   ",
        "not json",
        "{",
        "[]",
        "{\"hosts\":\"nope\"}",
        "{\"hosts\":[{\"key\":42}]}",
        "null",
    };
    for (cases) |c| {
        var store = Store.parse(testing.allocator, c);
        defer store.deinit();
        try testing.expectEqual(@as(usize, 0), store.entries.items.len);
        try testing.expect(store.get("dev-a").isEmpty());
    }
}

test "parse: unknown fields are tolerated (forward compatibility)" {
    var store = Store.parse(
        testing.allocator,
        "{\"version\":9,\"hosts\":[{\"key\":\"dev-a\",\"shell\":\"wsl.exe\",\"future\":true}]}",
    );
    defer store.deinit();
    try testing.expectEqualStrings("wsl.exe", store.get("dev-a").shell.?);
}

test "parse: blank rows, bad keys and duplicates are dropped" {
    var store = Store.parse(testing.allocator,
        \\{"hosts":[
        \\  {"key":"dev-a","shell":"wsl.exe"},
        \\  {"key":"blank","working_directory":"  ","shell":""},
        \\  {"key":"","shell":"cmd.exe"},
        \\  {"key":"dev-a","shell":"cmd.exe"}
        \\]}
    );
    defer store.deinit();
    try testing.expectEqual(@as(usize, 1), store.entries.items.len);
    // First wins for a duplicate key.
    try testing.expectEqualStrings("wsl.exe", store.get("dev-a").shell.?);
    try testing.expect(store.get("blank").isEmpty());
}

test "Resolved: assign, read back, and refuse over-long values" {
    var r: Resolved = .{};
    try testing.expect(r.workingDirectory() == null);
    try testing.expect(r.shell() == null);

    r.assign(.{ .working_directory = "C:\\dev", .shell = "wsl.exe" });
    try testing.expectEqualStrings("C:\\dev", r.workingDirectory().?);
    try testing.expectEqualStrings("wsl.exe", r.shell().?);

    // A second assign fully replaces the first (no stale tail).
    r.assign(.{ .shell = "cmd.exe" });
    try testing.expect(r.workingDirectory() == null);
    try testing.expectEqualStrings("cmd.exe", r.shell().?);

    // Exactly at the cap fits; over it is dropped.
    const at_cap = "x" ** MAX_VALUE_LEN;
    r.assign(.{ .working_directory = at_cap });
    try testing.expectEqual(MAX_VALUE_LEN, r.workingDirectory().?.len);
    r.assign(.{});
    try testing.expect(r.workingDirectory() == null);
}

test "loadFrom/saveTo round-trip on a real file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);
    const file = try std.fs.path.join(testing.allocator, &.{ path, "sub", "host_defaults.json" });
    defer testing.allocator.free(file);

    // A store that was never written reads as empty.
    {
        var missing = loadFrom(testing.allocator, file);
        defer missing.deinit();
        try testing.expect(missing.get("dev-a").isEmpty());
    }

    {
        var store = Store.init(testing.allocator);
        defer store.deinit();
        try store.set("dev-a", .{ .working_directory = "C:\\dev", .shell = "wsl.exe" });
        // Writes through a directory that does not exist yet.
        try saveTo(testing.allocator, &store, file);
    }

    var back = loadFrom(testing.allocator, file);
    defer back.deinit();
    try testing.expectEqualStrings("C:\\dev", back.get("dev-a").working_directory.?);
    try testing.expectEqualStrings("wsl.exe", back.get("dev-a").shell.?);

    // Clearing the row leaves a valid, empty document behind (not a stale one).
    {
        var store = loadFrom(testing.allocator, file);
        defer store.deinit();
        try store.set("dev-a", .{});
        try saveTo(testing.allocator, &store, file);
    }
    var cleared = loadFrom(testing.allocator, file);
    defer cleared.deinit();
    try testing.expect(cleared.get("dev-a").isEmpty());
}

test "shell presets match mac's list" {
    try testing.expectEqual(@as(usize, 6), shell_presets.len);
    try testing.expectEqualStrings("cmd.exe", shell_presets[0]);
    try testing.expectEqualStrings("wsl.exe", shell_presets[3]);
    try testing.expectEqualStrings("/bin/zsh", shell_presets[5]);
    // Every preset is a value the store would accept verbatim.
    for (shell_presets) |p| try testing.expectEqualStrings(p, normalize(p).?);
}

test {
    testing.refAllDecls(@This());
}
