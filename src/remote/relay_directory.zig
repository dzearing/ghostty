//! Relay account device-directory client — the Zig counterpart to the macOS
//! `RelayDirectoryClient` (`macos/Sources/Features/Remote/RelayDirectoryClient.swift`).
//!
//! It lists the signed-in account's enrolled relay devices via
//! `GET {base}/v1/client/devices`, which the win32 machine chooser (T22c) opens
//! to populate its list. The `{"devices":[{id,name,hostname?,online},…]}` wire
//! shape and the 401/404/other status mapping mirror the Swift client exactly.
//!
//! Scope split (T22a decision 2): this is a PURE DATA LAYER. The URL join, the
//! JSON parse, and the status→error mapping are pure and unit-tested in the
//! `none` lane below; the live authenticated GET (`listDevices`) is a thin
//! composition of those plus `http_client.getAuth` and is exercised on-box in
//! T22c (against the account, or a fake `GHOSTTY_RELAY_BASE` endpoint, the same
//! trick `ipc-relay-login.ps1` uses). Bearer-token resolution lives with the
//! caller (`IpcHandlers.resolveAccountToken` → `resolveEnvToken`), not here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("http_client.zig");

const log = std.log.scoped(.relay_directory);

/// The dev relay base used when `GHOSTTY_RELAY_BASE` is unset — matches
/// `RelayDirectoryClient.defaultBase` (macOS).
pub const default_base = "https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com";

/// Upper bound on an accepted device-list body. The list is tiny (a handful of
/// devices); this only guards against a misbehaving relay growing our
/// allocation.
const max_body_len = 1 << 20;

/// One device (account resource) as returned by `GET /v1/client/devices`.
/// `hostname` is the machine's OS-reported hostname (distinct from the display
/// `name`), omitted by the relay when unknown — hence optional. `created_at`
/// and any other fields the relay adds are ignored. `online` defaults to false
/// so a relay that omits it for a never-seen device parses instead of erroring.
pub const Device = struct {
    id: []const u8,
    name: []const u8,
    hostname: ?[]const u8 = null,
    online: bool = false,
};

/// The wire shape of the list response: `{"devices":[ … ]}`.
pub const ListResponse = struct {
    devices: []const Device = &.{},
};

/// An owned, parsed device list. All strings are copied into the backing arena
/// (`.alloc_always`), so the input body may be freed immediately. Call
/// `.deinit()` to release.
pub const Parsed = std.json.Parsed(ListResponse);

/// A directory error derived purely from an HTTP status, mirroring the macOS
/// `DirectoryError` cases the relay's status codes produce. `bad_response`
/// (an unparseable body) is a separate parse failure, not a status.
pub const DirectoryError = union(enum) {
    /// The relay rejected the bearer token (HTTP 401).
    unauthorized,
    /// The device/resource is unknown or not owned by this account (HTTP 404).
    not_found,
    /// Any other non-2xx status, code preserved.
    http: u16,
};

/// The typed error set `listDevices` surfaces to callers (the win32 chooser
/// treats any of these as "show an empty list + sign-in hint", never a crash).
pub const FetchError = error{
    Unauthorized,
    NotFound,
    UnexpectedStatus,
    BadResponse,
};

/// Map an HTTP status to a `DirectoryError`, or null for 2xx success. Pure.
pub fn classifyStatus(status: u16) ?DirectoryError {
    if (status >= 200 and status < 300) return null;
    return switch (status) {
        401 => .unauthorized,
        404 => .not_found,
        else => .{ .http = status },
    };
}

/// Join a relay base and a leading-slash-less path into an absolute URL,
/// tolerating a trailing slash on the base (`https://x` and `https://x/` both
/// yield `https://x/<path>`). Pure; caller frees.
pub fn joinUrl(alloc: Allocator, base: []const u8, path: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trimRight(u8, base, "/");
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ trimmed, path });
}

/// Parse a `GET /v1/client/devices` body into an owned device list. All strings
/// are copied into the returned arena (`.alloc_always`), so the caller may free
/// the input body immediately. Unknown fields (`created_at`, …) are tolerated;
/// any malformed body is `error.BadResponse`. Pure.
pub fn parseDevices(alloc: Allocator, body: []const u8) error{ BadResponse, OutOfMemory }!Parsed {
    return std.json.parseFromSlice(ListResponse, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadResponse,
    };
}

/// `GET {base}/v1/client/devices` with the bearer `token`, returning an owned,
/// parsed device list the caller `.deinit()`s. Composes `joinUrl` +
/// `http_client.getAuth` + `classifyStatus` + `parseDevices`. The live GET is
/// exercised on-box (T22c); the pure pieces are unit-tested below.
///
/// The error set is `FetchError` (status/parse) plus the inferred transport
/// errors from `getAuth` (TCP/TLS/allocation). A non-2xx status maps through
/// `classifyStatus` onto `Unauthorized`/`NotFound`/`UnexpectedStatus`.
pub fn listDevices(alloc: Allocator, base: []const u8, token: []const u8) !Parsed {
    const url = try joinUrl(alloc, base, "v1/client/devices");
    defer alloc.free(url);

    var resp = try http_client.getAuth(alloc, url, token, max_body_len);
    defer resp.deinit(alloc);

    if (statusError(resp.status, "list")) |err| return err;

    return parseDevices(alloc, resp.body);
}

// =============================================================================
// Device management: rename + remove (T176)
// =============================================================================

/// An owned, parsed single device — what a rename returns. Same arena rules as
/// `Parsed`.
pub const ParsedDevice = std.json.Parsed(Device);

/// Percent-encode one URL path segment: everything outside RFC 3986's
/// unreserved set is escaped. Device ids are relay-generated and so far always
/// unreserved, but a raw `/` or `?` in one would silently retarget the request
/// at a different endpoint — `appendingPathComponent` (which Mac uses) escapes,
/// so this does too. Pure; caller frees.
pub fn escapePathSegment(alloc: Allocator, seg: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (seg) |c| {
        const unreserved = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
            else => false,
        };
        if (unreserved) {
            try out.append(alloc, c);
        } else {
            try out.appendSlice(alloc, &.{ '%', std.fmt.digitToChar(c >> 4, .upper), std.fmt.digitToChar(c & 0xF, .upper) });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// `v1/client/devices/<escaped id>` — the per-device resource path both
/// management verbs address. Pure; caller frees.
pub fn devicePath(alloc: Allocator, device_id: []const u8) Allocator.Error![]u8 {
    const esc = try escapePathSegment(alloc, device_id);
    defer alloc.free(esc);
    return std.fmt.allocPrint(alloc, "v1/client/devices/{s}", .{esc});
}

/// The rename request body, `{"name":"…"}` with JSON escaping. Pure; caller
/// frees. Mirrors Mac's `JSONEncoder().encode(["name": name])`.
pub fn renameBody(alloc: Allocator, name: []const u8) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{ .name = name }, .{});
}

/// Parse the single-device body a rename returns. Same `.alloc_always` copy
/// rule as `parseDevices`, so the caller may free the source body. Pure.
pub fn parseDevice(alloc: Allocator, body: []const u8) error{ BadResponse, OutOfMemory }!ParsedDevice {
    return std.json.parseFromSlice(Device, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadResponse,
    };
}

/// `PATCH {base}/v1/client/devices/{id}` with `{"name": …}` — rename an owned
/// device, returning the relay's updated view of it (caller `.deinit()`s).
/// Mirrors `RelayDirectoryClient.rename`.
pub fn renameDevice(
    alloc: Allocator,
    base: []const u8,
    token: []const u8,
    device_id: []const u8,
    name: []const u8,
) !ParsedDevice {
    const path = try devicePath(alloc, device_id);
    defer alloc.free(path);
    const url = try joinUrl(alloc, base, path);
    defer alloc.free(url);
    const body = try renameBody(alloc, name);
    defer alloc.free(body);

    var resp = try http_client.requestAuth(alloc, url, "PATCH", token, body, max_body_len);
    defer resp.deinit(alloc);

    if (statusError(resp.status, "rename")) |err| return err;
    return parseDevice(alloc, resp.body);
}

/// `DELETE {base}/v1/client/devices/{id}` — remove an owned device and revoke
/// its credential (the relay answers 204). Mirrors
/// `RelayDirectoryClient.delete`; the body, if any, is ignored.
pub fn deleteDevice(
    alloc: Allocator,
    base: []const u8,
    token: []const u8,
    device_id: []const u8,
) !void {
    const path = try devicePath(alloc, device_id);
    defer alloc.free(path);
    const url = try joinUrl(alloc, base, path);
    defer alloc.free(url);

    var resp = try http_client.requestAuth(alloc, url, "DELETE", token, null, max_body_len);
    defer resp.deinit(alloc);

    if (statusError(resp.status, "delete")) |err| return err;
}

/// `classifyStatus` mapped onto the `FetchError` a caller sees, or null for
/// success. Shared by every verb so one status means one error everywhere.
fn statusError(status: u16, what: []const u8) ?FetchError {
    const derr = classifyStatus(status) orelse return null;
    return switch (derr) {
        .unauthorized => error.Unauthorized,
        .not_found => error.NotFound,
        .http => |code| blk: {
            log.warn("device {s}: relay returned HTTP {d}", .{ what, code });
            break :blk error.UnexpectedStatus;
        },
    };
}

/// The relay base to use: `GHOSTTY_RELAY_BASE` if set and non-empty, else
/// `default_base`. Caller frees. Mirrors `RelayDirectoryClient.defaultBase`.
pub fn resolveBase(alloc: Allocator) Allocator.Error![]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_RELAY_BASE")) |v| {
        if (v.len > 0) return v;
        alloc.free(v);
    } else |_| {}
    return alloc.dupe(u8, default_base);
}

// =============================================================================
// Tests (pure layer — none lane)
// =============================================================================

const testing = std.testing;

test "classifyStatus: 2xx is success (null)" {
    try testing.expect(classifyStatus(200) == null);
    try testing.expect(classifyStatus(204) == null);
}

test "classifyStatus: 401 → unauthorized" {
    try testing.expectEqual(
        @as(std.meta.Tag(DirectoryError), .unauthorized),
        std.meta.activeTag(classifyStatus(401).?),
    );
}

test "classifyStatus: 404 → not_found" {
    try testing.expectEqual(
        @as(std.meta.Tag(DirectoryError), .not_found),
        std.meta.activeTag(classifyStatus(404).?),
    );
}

test "classifyStatus: other non-2xx → http(code)" {
    switch (classifyStatus(500).?) {
        .http => |code| try testing.expectEqual(@as(u16, 500), code),
        else => return error.TestUnexpectedResult,
    }
    switch (classifyStatus(403).?) {
        .http => |code| try testing.expectEqual(@as(u16, 403), code),
        else => return error.TestUnexpectedResult,
    }
}

test "joinUrl: base without trailing slash" {
    const u = try joinUrl(testing.allocator, "https://relay.example.com", "v1/client/devices");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://relay.example.com/v1/client/devices", u);
}

test "joinUrl: base with trailing slash" {
    const u = try joinUrl(testing.allocator, "https://relay.example.com/", "v1/client/devices");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://relay.example.com/v1/client/devices", u);
}

test "parseDevices: well-formed list incl device with no hostname" {
    const body =
        \\{"devices":[
        \\  {"id":"d1","name":"Winbox","hostname":"winbox.local","online":true,"created_at":"2026-01-01"},
        \\  {"id":"d2","name":"Laptop","online":false}
        \\]}
    ;
    var p = try parseDevices(testing.allocator, body);
    defer p.deinit();
    const devs = p.value.devices;
    try testing.expectEqual(@as(usize, 2), devs.len);
    try testing.expectEqualStrings("d1", devs[0].id);
    try testing.expectEqualStrings("Winbox", devs[0].name);
    try testing.expectEqualStrings("winbox.local", devs[0].hostname.?);
    try testing.expect(devs[0].online);
    try testing.expectEqualStrings("d2", devs[1].id);
    try testing.expect(devs[1].hostname == null);
    try testing.expect(!devs[1].online);
}

test "parseDevices: strings survive freeing the input body" {
    // `.alloc_always` must copy strings into the arena so the parsed device
    // list outlives the (here, freed) source body — the exact lifetime
    // `listDevices` relies on (it frees `resp.body` before returning).
    const src = try testing.allocator.dupe(u8,
        \\{"devices":[{"id":"x","name":"n","online":true}]}
    );
    var p = try parseDevices(testing.allocator, src);
    defer p.deinit();
    testing.allocator.free(src); // free the source out from under the parse
    try testing.expectEqualStrings("x", p.value.devices[0].id);
    try testing.expectEqualStrings("n", p.value.devices[0].name);
}

test "parseDevices: empty list" {
    var p = try parseDevices(testing.allocator, "{\"devices\":[]}");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.value.devices.len);
}

test "parseDevices: garbage body → BadResponse" {
    try testing.expectError(error.BadResponse, parseDevices(testing.allocator, "not json at all"));
    try testing.expectError(error.BadResponse, parseDevices(testing.allocator, "{\"devices\":"));
}

// --- Device management (T176) ------------------------------------------------

test "devicePath: the per-device resource under the list endpoint" {
    const p = try devicePath(testing.allocator, "dev-e2e");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("v1/client/devices/dev-e2e", p);
}

test "devicePath composed with joinUrl is the full mac URL" {
    const p = try devicePath(testing.allocator, "abc123");
    defer testing.allocator.free(p);
    const u = try joinUrl(testing.allocator, "https://relay.example.com/", p);
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://relay.example.com/v1/client/devices/abc123", u);
}

test "escapePathSegment: unreserved survives, everything else is percent-encoded" {
    const plain = try escapePathSegment(testing.allocator, "aZ0-._~");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("aZ0-._~", plain);

    // A raw '/' would retarget the request at a different endpoint entirely;
    // '?' would turn the rest into a query string.
    const nasty = try escapePathSegment(testing.allocator, "a/b?c d#e");
    defer testing.allocator.free(nasty);
    try testing.expectEqualStrings("a%2Fb%3Fc%20d%23e", nasty);
}

test "devicePath escapes a hostile device id" {
    const p = try devicePath(testing.allocator, "../devices");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("v1/client/devices/..%2Fdevices", p);
}

test "renameBody: mac's {\"name\": …}, JSON-escaped" {
    const b = try renameBody(testing.allocator, "Winbox");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("{\"name\":\"Winbox\"}", b);

    const q = try renameBody(testing.allocator, "He said \"hi\"\\");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("{\"name\":\"He said \\\"hi\\\"\\\\\"}", q);
}

test "renameBody round-trips through the device parser's escaping rules" {
    const b = try renameBody(testing.allocator, "a\"b");
    defer testing.allocator.free(b);
    const Named = struct { name: []const u8 };
    var p = try std.json.parseFromSlice(Named, testing.allocator, b, .{});
    defer p.deinit();
    try testing.expectEqualStrings("a\"b", p.value.name);
}

test "parseDevice: the single-device body a rename returns" {
    const body =
        \\{"id":"d1","name":"Renamed","hostname":"winbox.local","online":true,"created_at":"x"}
    ;
    var p = try parseDevice(testing.allocator, body);
    defer p.deinit();
    try testing.expectEqualStrings("d1", p.value.id);
    try testing.expectEqualStrings("Renamed", p.value.name);
    try testing.expectEqualStrings("winbox.local", p.value.hostname.?);
    try testing.expect(p.value.online);
}

test "parseDevice: a list body is NOT a device" {
    try testing.expectError(
        error.BadResponse,
        parseDevice(testing.allocator, "{\"devices\":[]}"),
    );
    try testing.expectError(error.BadResponse, parseDevice(testing.allocator, "nope"));
}

test "statusError: one status means one error for every verb" {
    try testing.expect(statusError(200, "list") == null);
    try testing.expect(statusError(204, "delete") == null); // the relay's delete success
    try testing.expectEqual(@as(?FetchError, error.Unauthorized), statusError(401, "rename"));
    try testing.expectEqual(@as(?FetchError, error.NotFound), statusError(404, "delete"));
    try testing.expectEqual(@as(?FetchError, error.UnexpectedStatus), statusError(500, "rename"));
}

test {
    testing.refAllDecls(@This());
}
