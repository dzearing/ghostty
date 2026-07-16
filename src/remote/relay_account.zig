//! The client-side signed-in Google account for relay auth on Windows (T21a —
//! the Zig analog of `macos/Sources/Features/Remote/RelayAccount.swift`, which
//! uses the macOS Keychain).
//!
//! ## What it stores
//! A single account blob at `%LOCALAPPDATA%\ghoztty\account.dat`:
//! `{client_id, client_secret?, refresh_token, email}`. The OAuth **client**
//! id/secret are persisted alongside the credential (they come from the
//! `GHOSTTY_GOOGLE_CLIENT_ID`/`_SECRET` env or `--client-id=`/`--client-secret=`
//! flags at login) so a GUI-side token refresh needs no environment.
//!
//! ## At rest
//! The blob is DPAPI-encrypted per-user (`CryptProtectData`) on Windows, so it
//! is unreadable by other users and unusable if copied to another machine.
//! The write is atomic (tmp + rename, like `enroll.saveRelayEnv`) and the file
//! gets an owner-only DACL (`win_acl`). On non-Windows (the Mac none-lane
//! regression build) DPAPI is unavailable, so the seam is an identity
//! passthrough — the store is a Windows-only feature; that branch exists only
//! so the module compiles and the pure round-trip test runs off-box.
//!
//! ## The token-resolution seam
//! `resolveIdToken` mints a fresh ID token from the stored refresh grant — the
//! account tier the win32 GUI consults after an explicit `--token` and before
//! the `GHOSTTY_RELAY_TOKEN` env fallback (T21a completes the tiering T21b
//! started).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const google_oauth = @import("google_oauth.zig");
const win_acl = @import("win_acl.zig");

/// The persisted account. Slices are owned when returned from `load` (freed by
/// `deinit`); borrowed when passed to `save`.
pub const Account = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    refresh_token: []const u8,
    email: []const u8,

    /// Free an owned account (as returned by `load`).
    pub fn deinit(self: *Account, alloc: Allocator) void {
        alloc.free(self.client_id);
        if (self.client_secret) |s| alloc.free(s);
        alloc.free(self.refresh_token);
        alloc.free(self.email);
        self.* = undefined;
    }
};

pub const Error = error{
    /// No account.dat (the user is signed out).
    SignedOut,
    /// The file exists but couldn't be decrypted or parsed.
    Corrupt,
};

/// Resolve the account.dat path:
///   1. `GHOSTTY_ACCOUNT_STORE` (explicit full-path override; tests use this),
///   2. Windows: `%LOCALAPPDATA%\ghoztty\account.dat`,
///   3. else `$XDG_CONFIG_HOME/ghoztty/account.dat`, falling back to
///      `$HOME/.config/ghoztty/account.dat` (non-Windows test builds only).
/// Owned by the caller.
pub fn accountPath(alloc: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_ACCOUNT_STORE")) |p| {
        if (p.len > 0) return p;
        alloc.free(p);
    } else |_| {}

    if (builtin.os.tag == .windows) {
        const local = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
        defer alloc.free(local);
        return std.fs.path.join(alloc, &.{ local, "ghoztty", "account.dat" });
    } else {
        if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
            defer alloc.free(xdg);
            if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "ghoztty", "account.dat" });
        } else |_| {}
        const home = try std.process.getEnvVarOwned(alloc, "HOME");
        defer alloc.free(home);
        return std.fs.path.join(alloc, &.{ home, ".config", "ghoztty", "account.dat" });
    }
}

/// The JSON shape persisted inside the (encrypted) blob.
const Stored = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    refresh_token: []const u8,
    email: []const u8,
};

/// Encrypt + write `account` at `path` atomically, then tighten its DACL.
/// Parent directories are created. On POSIX the temp file is mode 0600.
pub fn save(alloc: Allocator, path: []const u8, account: Account) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, Stored{
        .client_id = account.client_id,
        .client_secret = account.client_secret,
        .refresh_token = account.refresh_token,
        .email = account.email,
    }, .{});
    defer alloc.free(json);

    const blob = try protect(alloc, json);
    defer alloc.free(blob);

    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);

    var flags: std.fs.File.CreateFlags = .{ .truncate = true };
    if (builtin.os.tag != .windows) flags.mode = 0o600;
    {
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        const file = try std.fs.cwd().createFile(tmp_path, flags);
        defer file.close();
        try file.writeAll(blob);
        try file.sync();
    }
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
    try std.fs.cwd().rename(tmp_path, path);

    // Owner-only, non-inherited DACL now that it holds a credential (no-op off
    // Windows; POSIX already got 0600). Best-effort.
    win_acl.harden(alloc, path);
}

/// Read + decrypt + parse the account at `path`. Returns an owned `Account`
/// (caller `deinit`s). `error.SignedOut` when the file is absent.
pub fn load(alloc: Allocator, path: []const u8) !Account {
    const blob = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return Error.SignedOut,
        else => return err,
    };
    defer alloc.free(blob);

    const json = unprotect(alloc, blob) catch return Error.Corrupt;
    defer alloc.free(json);

    const parsed = std.json.parseFromSlice(
        Stored,
        alloc,
        json,
        .{ .ignore_unknown_fields = true },
    ) catch return Error.Corrupt;
    defer parsed.deinit();

    // Copy out of the parsed arena into caller-owned slices.
    var acct: Account = .{
        .client_id = try alloc.dupe(u8, parsed.value.client_id),
        .client_secret = null,
        .refresh_token = try alloc.dupe(u8, parsed.value.refresh_token),
        .email = try alloc.dupe(u8, parsed.value.email),
    };
    errdefer acct.deinit(alloc);
    if (parsed.value.client_secret) |s| acct.client_secret = try alloc.dupe(u8, s);
    return acct;
}

/// Delete account.dat (sign out). A missing file is success.
pub fn delete(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
}

/// Whether a signed-in account exists (cheap: file presence, no decrypt).
pub fn isSignedIn(alloc: Allocator, path: []const u8) bool {
    _ = alloc;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Mint a fresh relay bearer (Google ID token) from the stored account's
/// refresh grant, using the persisted client config. This is the GUI's
/// account tier. Returns an owned token (caller frees). `error.SignedOut`
/// when no account is stored; other errors bubble from the token endpoint.
pub fn resolveIdToken(alloc: Allocator, endpoints: google_oauth.Endpoints, path: []const u8) ![]u8 {
    var account = try load(alloc, path);
    defer account.deinit(alloc);

    const client: google_oauth.TokenClient = .{
        .alloc = alloc,
        .endpoints = endpoints,
        .client_id = account.client_id,
        .client_secret = account.client_secret,
    };
    var parsed = try client.refresh(account.refresh_token);
    defer parsed.deinit();

    const id_token = parsed.value.id_token orelse return google_oauth.TokenError.BadResponse;
    const owned = try alloc.dupe(u8, id_token);

    // Google may rotate the refresh token on a refresh grant; persist the new
    // one so the next refresh doesn't fail. Best-effort — a failed re-save
    // doesn't invalidate the token we just minted.
    if (parsed.value.refresh_token) |new_rt| {
        if (!std.mem.eql(u8, new_rt, account.refresh_token)) {
            save(alloc, path, .{
                .client_id = account.client_id,
                .client_secret = account.client_secret,
                .refresh_token = new_rt,
                .email = account.email,
            }) catch {};
        }
    }
    return owned;
}

// =============================================================================
// DPAPI seam (per-user encryption at rest)
// =============================================================================

/// Encrypt `plaintext` for the current user. Windows: DPAPI. Elsewhere:
/// identity passthrough (compile/off-box only — see the file header).
fn protect(alloc: Allocator, plaintext: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) return dpapi.protect(alloc, plaintext);
    return alloc.dupe(u8, plaintext);
}

/// Inverse of `protect`.
fn unprotect(alloc: Allocator, blob: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) return dpapi.unprotect(alloc, blob);
    return alloc.dupe(u8, blob);
}

const dpapi = struct {
    const W = std.os.windows;
    const DWORD = W.DWORD;
    const BOOL = W.BOOL;

    const DATA_BLOB = extern struct {
        cbData: DWORD,
        pbData: ?[*]u8,
    };

    // CRYPTPROTECT_UI_FORBIDDEN — never prompt (we run headless in the CLI/GUI).
    const CRYPTPROTECT_UI_FORBIDDEN: DWORD = 0x1;

    extern "crypt32" fn CryptProtectData(
        pDataIn: *DATA_BLOB,
        szDataDescr: ?[*:0]const u16,
        pOptionalEntropy: ?*DATA_BLOB,
        pvReserved: ?*anyopaque,
        pPromptStruct: ?*anyopaque,
        dwFlags: DWORD,
        pDataOut: *DATA_BLOB,
    ) callconv(.winapi) BOOL;

    extern "crypt32" fn CryptUnprotectData(
        pDataIn: *DATA_BLOB,
        ppszDataDescr: ?*?[*:0]u16,
        pOptionalEntropy: ?*DATA_BLOB,
        pvReserved: ?*anyopaque,
        pPromptStruct: ?*anyopaque,
        dwFlags: DWORD,
        pDataOut: *DATA_BLOB,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

    fn protect(alloc: Allocator, plaintext: []const u8) ![]u8 {
        var in: DATA_BLOB = .{ .cbData = @intCast(plaintext.len), .pbData = @constCast(plaintext.ptr) };
        var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
        if (CryptProtectData(&in, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out) == 0) {
            return error.DpapiFailed;
        }
        defer _ = LocalFree(out.pbData);
        const ptr = out.pbData orelse return error.DpapiFailed;
        return alloc.dupe(u8, ptr[0..out.cbData]);
    }

    fn unprotect(alloc: Allocator, blob: []const u8) ![]u8 {
        var in: DATA_BLOB = .{ .cbData = @intCast(blob.len), .pbData = @constCast(blob.ptr) };
        var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
        if (CryptUnprotectData(&in, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out) == 0) {
            return error.DpapiFailed;
        }
        defer _ = LocalFree(out.pbData);
        const ptr = out.pbData orelse return error.DpapiFailed;
        return alloc.dupe(u8, ptr[0..out.cbData]);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "account store: save then load round-trips (with and without secret)" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "account.dat" });
    defer alloc.free(path);

    // With a client secret.
    try save(alloc, path, .{
        .client_id = "client-123",
        .client_secret = "secret-xyz",
        .refresh_token = "rt-abc",
        .email = "user@example.com",
    });
    {
        var got = try load(alloc, path);
        defer got.deinit(alloc);
        try testing.expectEqualStrings("client-123", got.client_id);
        try testing.expectEqualStrings("secret-xyz", got.client_secret.?);
        try testing.expectEqualStrings("rt-abc", got.refresh_token);
        try testing.expectEqualStrings("user@example.com", got.email);
    }

    // Overwrite without a secret (public client): round-trips as null.
    try save(alloc, path, .{
        .client_id = "client-123",
        .client_secret = null,
        .refresh_token = "rt-def",
        .email = "user@example.com",
    });
    {
        var got = try load(alloc, path);
        defer got.deinit(alloc);
        try testing.expect(got.client_secret == null);
        try testing.expectEqualStrings("rt-def", got.refresh_token);
    }
}

test "account store: load on a missing file is SignedOut" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "nope.dat" });
    defer alloc.free(path);

    try testing.expect(!isSignedIn(alloc, path));
    try testing.expectError(Error.SignedOut, load(alloc, path));
}

test "account store: delete removes the file (idempotent)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "account.dat" });
    defer alloc.free(path);

    try save(alloc, path, .{
        .client_id = "c",
        .refresh_token = "r",
        .email = "e",
    });
    try testing.expect(isSignedIn(alloc, path));
    delete(path);
    try testing.expect(!isSignedIn(alloc, path));
    delete(path); // idempotent: no error on a second delete
}

test {
    testing.refAllDecls(@This());
}
