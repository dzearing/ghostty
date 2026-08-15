//! The client-side signed-in relay account on Windows (T21a store + T93
//! brokered model — the Zig analog of
//! `macos/Sources/Features/Remote/RelayAccount.swift`, which uses the macOS
//! Keychain).
//!
//! ## What it stores
//! A single account blob at `%LOCALAPPDATA%\ghoztty\account.dat`:
//! `{session_token, expiry, email, relay_base, picture?}` — the opaque relay
//! **session token** minted by the relay's brokered `/oauth/exchange` (T93).
//! No Google token or OAuth client credential ever touches this store; the
//! confidential client secret and the Google refresh token live only on the
//! relay. `relay_base` records which relay minted the session so renew and
//! sign-out dial the same one.
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
//! `resolveSessionToken` returns the stored session token while it has >60s of
//! life left, else renews it at the stored relay (`/oauth/renew` rotates the
//! token; the rotation is persisted). This is the account tier the win32 GUI
//! consults after an explicit `--token` and before the `GHOSTTY_RELAY_TOKEN`
//! env fallback.
//!
//! ## Legacy stores
//! A pre-T93 account.dat held `{client_id, client_secret?, refresh_token,
//! email}` (the direct-Google flow). The brokered relay no longer accepts raw
//! Google ID tokens as client bearers, so a legacy credential cannot mint
//! anything useful — `load` surfaces it as `Error.Legacy` and the user signs
//! in once more (from the machine chooser's account row — T141 deleted the
//! `+relay-login` CLI verb), which overwrites the store in the new shape.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const relay_session = @import("relay_session.zig");
const win_acl = @import("win_acl.zig");
const atomic_write = @import("agent/atomic_write.zig");

const log = std.log.scoped(.relay_account);

/// Seconds of remaining session-token life below which `resolveSessionToken`
/// renews instead of returning the cached token, so relay calls never race the
/// expiry (Mac `RelayAccount` uses the same 60s leeway).
pub const refresh_leeway_s: i64 = 60;

/// The persisted account. Slices are owned when returned from `load` (freed by
/// `deinit`); borrowed when passed to `save`.
pub const Account = struct {
    /// The opaque relay session token (the Bearer for every relay call).
    session_token: []const u8,
    /// Absolute token expiry, unix seconds (the relay's `expiry`).
    expiry: i64,
    email: []const u8,
    /// The relay base URL the session was minted at (renew/signout target).
    relay_base: []const u8,
    picture: ?[]const u8 = null,

    /// Free an owned account (as returned by `load`).
    pub fn deinit(self: *Account, alloc: Allocator) void {
        alloc.free(self.session_token);
        alloc.free(self.email);
        alloc.free(self.relay_base);
        if (self.picture) |p| alloc.free(p);
        self.* = undefined;
    }

    /// Whether the stored token still has more than the refresh leeway of
    /// life left at `now_unix`. Pure (now passed in for testability).
    pub fn isFresh(self: Account, now_unix: i64) bool {
        return self.expiry - now_unix > refresh_leeway_s;
    }
};

pub const Error = error{
    /// No account.dat (the user is signed out).
    SignedOut,
    /// The file exists but couldn't be decrypted or parsed.
    Corrupt,
    /// A pre-T93 direct-Google store (refresh token, no session token). The
    /// only remedy is one fresh sign-in (see the file header).
    Legacy,
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

/// The JSON shape persisted inside the (encrypted) blob. Every field optional
/// at parse time so one struct probes both the current and the legacy shape
/// (`refresh_token` present + `session_token` absent ⇒ pre-T93 store).
const Stored = struct {
    session_token: ?[]const u8 = null,
    expiry: ?i64 = null,
    email: ?[]const u8 = null,
    relay_base: ?[]const u8 = null,
    picture: ?[]const u8 = null,
    // Legacy (pre-T93) marker — never written anymore.
    refresh_token: ?[]const u8 = null,
};

/// Encrypt + write `account` at `path` atomically, then tighten its DACL.
/// Parent directories are created. On POSIX the temp file is mode 0600.
pub fn save(alloc: Allocator, path: []const u8, account: Account) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .session_token = account.session_token,
        .expiry = account.expiry,
        .email = account.email,
        .relay_base = account.relay_base,
        .picture = account.picture,
    }, .{});
    defer alloc.free(json);

    const blob = try protect(alloc, json);
    defer alloc.free(blob);

    // Staging sibling + rename via the shared recipe (`atomic_write`,
    // T183/T500); `.secret` stages the file 0600 on POSIX. A crashed earlier
    // save's staging debris is a (DPAPI-wrapped) credential — sweep it; safe
    // because account.dat has a single writer (the sign-in flow).
    try atomic_write.writeChunks(alloc, path, &.{blob}, .{ .secret = true });
    atomic_write.cleanStaging(path);

    // Owner-only, non-inherited DACL now that it holds a credential (no-op off
    // Windows; POSIX already got 0600). Best-effort.
    win_acl.harden(alloc, path);
}

/// Read + decrypt + parse the account at `path`. Returns an owned `Account`
/// (caller `deinit`s). `error.SignedOut` when the file is absent;
/// `error.Legacy` for a pre-T93 refresh-token store.
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

    const token = parsed.value.session_token orelse {
        // No session token: a pre-T93 store if it carries the old credential,
        // otherwise plain corruption.
        return if (parsed.value.refresh_token != null) Error.Legacy else Error.Corrupt;
    };

    // Copy out of the parsed arena into caller-owned slices.
    var acct: Account = .{
        .session_token = try alloc.dupe(u8, token),
        .expiry = parsed.value.expiry orelse 0,
        .email = try alloc.dupe(u8, parsed.value.email orelse ""),
        .relay_base = try alloc.dupe(u8, parsed.value.relay_base orelse ""),
        .picture = null,
    };
    errdefer acct.deinit(alloc);
    if (parsed.value.picture) |p| acct.picture = try alloc.dupe(u8, p);
    return acct;
}

/// Delete account.dat (sign out), and any staging sibling a crashed save left
/// behind — that debris is a credential too. A missing file is success.
pub fn delete(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    atomic_write.cleanStaging(path);
}

/// Whether a signed-in account exists (cheap: file presence, no decrypt).
pub fn isSignedIn(alloc: Allocator, path: []const u8) bool {
    _ = alloc;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Resolve a live relay bearer from the stored account: the cached session
/// token while it has >60s of life left, else a renewed (rotated) one from the
/// stored relay's `/oauth/renew` — the rotation is persisted before returning
/// (the old token is dead server-side the moment renew succeeds). This is the
/// GUI's account tier. Returns an owned token (caller frees).
/// `error.SignedOut` / `error.Legacy` when no usable account is stored;
/// `error.Unauthorized` when the relay refused the renewal (sign in again).
pub fn resolveSessionToken(alloc: Allocator, path: []const u8) ![]u8 {
    var account = try load(alloc, path);
    defer account.deinit(alloc);

    if (account.isFresh(std.time.timestamp())) {
        return alloc.dupe(u8, account.session_token);
    }

    var renewed = try relay_session.renew(alloc, account.relay_base, account.session_token);
    defer renewed.deinit();

    const owned = try alloc.dupe(u8, renewed.value.session_token);
    errdefer alloc.free(owned);

    // Persist the rotation. A failed re-save is logged but does not fail this
    // resolution — the minted token is valid for this call; only the NEXT
    // resolve would find a stale store (and land in Unauthorized → re-login).
    save(alloc, path, .{
        .session_token = renewed.value.session_token,
        .expiry = renewed.value.expiry,
        .email = renewed.value.email,
        .relay_base = account.relay_base,
        .picture = renewed.value.picture,
    }) catch |err| {
        log.warn("account: persisting rotated session token failed: {}", .{err});
    };
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

fn tmpAccountPath(alloc: Allocator, tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    return std.fs.path.join(alloc, &.{ dir_path, name });
}

test "account store: save then load round-trips (with and without picture)" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account.dat");
    defer alloc.free(path);

    // With a picture.
    try save(alloc, path, .{
        .session_token = "sess-123",
        .expiry = 1893456000,
        .email = "user@example.com",
        .relay_base = "https://relay.example.com",
        .picture = "https://x/y.png",
    });
    {
        var got = try load(alloc, path);
        defer got.deinit(alloc);
        try testing.expectEqualStrings("sess-123", got.session_token);
        try testing.expectEqual(@as(i64, 1893456000), got.expiry);
        try testing.expectEqualStrings("user@example.com", got.email);
        try testing.expectEqualStrings("https://relay.example.com", got.relay_base);
        try testing.expectEqualStrings("https://x/y.png", got.picture.?);
    }

    // Overwrite without a picture: round-trips as null.
    try save(alloc, path, .{
        .session_token = "sess-456",
        .expiry = 1,
        .email = "user@example.com",
        .relay_base = "https://relay.example.com",
        .picture = null,
    });
    {
        var got = try load(alloc, path);
        defer got.deinit(alloc);
        try testing.expect(got.picture == null);
        try testing.expectEqualStrings("sess-456", got.session_token);
    }

    // A crashed pre-save's staging debris is a credential: save sweeps it, and
    // no staging leftover of ANY name survives — the directory holds exactly
    // the published file (T500).
    try tmp.dir.writeFile(.{ .sub_path = "account.dat.tmp", .data = "debris" });
    try save(alloc, path, .{ .session_token = "s", .expiry = 0, .email = "e", .relay_base = "b" });
    {
        const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(dir_path);
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next()) |entry| {
            count += 1;
            try testing.expectEqualStrings("account.dat", entry.name);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "account store: load on a missing file is SignedOut" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "nope.dat");
    defer alloc.free(path);

    try testing.expect(!isSignedIn(alloc, path));
    try testing.expectError(Error.SignedOut, load(alloc, path));
}

test "account store: a pre-T93 refresh-token store is Legacy" {
    // Off-Windows the DPAPI seam is identity, so a raw legacy JSON file IS a
    // valid legacy blob; on Windows this test writes through `protect` the
    // same way the old code did — either way `load` must classify, not parse.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account.dat");
    defer alloc.free(path);

    const legacy_json =
        \\{"client_id":"cid","client_secret":"sec","refresh_token":"rt","email":"e@x.com"}
    ;
    const blob = try protect(alloc, legacy_json);
    defer alloc.free(blob);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = blob });

    try testing.expect(isSignedIn(alloc, path)); // file presence only
    try testing.expectError(Error.Legacy, load(alloc, path));
}

test "account store: garbage without either token shape is Corrupt" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account.dat");
    defer alloc.free(path);

    const blob = try protect(alloc, "{\"email\":\"only\"}");
    defer alloc.free(blob);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = blob });
    try testing.expectError(Error.Corrupt, load(alloc, path));
}

test "account store: delete removes the file (idempotent)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account.dat");
    defer alloc.free(path);

    try save(alloc, path, .{
        .session_token = "s",
        .expiry = 0,
        .email = "e",
        .relay_base = "b",
    });
    try testing.expect(isSignedIn(alloc, path));
    // Sign-out must also drop a crashed save's staging debris — it holds the
    // credential too (unique-name form, T500).
    try tmp.dir.writeFile(.{ .sub_path = "account.dat.00112233aabbccdd.tmp", .data = "debris" });
    delete(path);
    try testing.expect(!isSignedIn(alloc, path));
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile("account.dat.00112233aabbccdd.tmp"),
    );
    delete(path); // idempotent: no error on a second delete
}

test "isFresh honors the 60s leeway" {
    const acct: Account = .{
        .session_token = "s",
        .expiry = 1000,
        .email = "e",
        .relay_base = "b",
    };
    try testing.expect(acct.isFresh(900)); // 100s left
    try testing.expect(!acct.isFresh(950)); // 50s left — within leeway
    try testing.expect(!acct.isFresh(2000)); // expired
}

test {
    testing.refAllDecls(@This());
}
