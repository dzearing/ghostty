//! Agent-side OAuth self-enroll (agent half): browser-first, device-code
//! fallback.
//!
//! `ghoztty-agent --enroll --relay=<base>` turns a fresh machine into an
//! account-owned relay device with NO pre-minted credential:
//!
//!   1. `POST <base>/v1/enroll/start` with this machine's hostname and
//!      `"flow":"web"` → `{enroll_url, device_code_handle, interval,
//!      expires_in}`. Open `enroll_url` in the default browser (best-effort;
//!      the URL is always printed too) — the owner just approves the Google
//!      sign-in there, no code to type. If the relay answers 503 (no web
//!      OAuth client configured), if it ignored the flow field (older
//!      relay), or if `--no-browser`/`--headless-enroll` was passed, fall
//!      back to the device-code flow: start with the default flow and print
//!      "visit <url>, enter code <XXXX-XXXX>".
//!   3. Poll `POST <base>/v1/enroll/poll` every `interval` seconds — the
//!      SAME poll for both flows. A `429 slow_down` grows the interval by 5s
//!      (RFC 8628 §3.5); `denied` / `expired` / `rejected` / `unknown` are
//!      terminal.
//!   4. On `complete`, persist `RELAY_BASE` + `DEVICE_TOKEN` to the agent's
//!      `relay.env` (`%LOCALAPPDATA%\ghoztty\relay.env` on Windows,
//!      `$XDG_CONFIG_HOME/ghoztty/relay.env` or `~/.config/ghoztty/relay.env`
//!      elsewhere; `GHOSTTY_RELAY_ENV` overrides the full path — used by
//!      tests) and tell the user how to start the agent.
//!
//! The relay.env file is the SAME file the Windows installer/launcher already
//! writes and parses, so enroll → run is seamless: `--relay` mode falls back
//! to it when `GHOSTTY_DEVICE_TOKEN` isn't set (env var wins).
//!
//! HTTP is `http_client.zig` — the same native TLS stack as the relay
//! WebSockets, plus plaintext `http://` so the flow can be driven against a
//! loopback test relay (the Go fake-issuer harness).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const http_client = @import("../http_client.zig");
const atomic_write = @import("atomic_write.zig");

/// How much the poll interval grows on a `slow_down` answer (RFC 8628 §3.5).
pub const slow_down_bump_s: u32 = 5;

/// Floor for the poll interval, whatever the server says.
pub const min_interval_s: u32 = 1;

// -----------------------------------------------------------------------------
// Wire types (JSON bodies of the relay's enroll endpoints)
// -----------------------------------------------------------------------------

/// Body of `POST /v1/enroll/start` (200) for the device-code flow.
pub const StartResponse = struct {
    verification_url: []const u8,
    user_code: []const u8,
    device_code_handle: []const u8,
    interval: u32 = 5,
    expires_in: u32 = 900,
};

/// Body of `POST /v1/enroll/start` (200) when the agent ASKED for the web
/// flow. Shape-tolerant: a current relay answers `{enroll_url, ...}`, while
/// an older relay ignores the unknown `flow` field and starts a device-code
/// grant (`{verification_url, user_code, ...}`) — both parse here and the
/// present fields decide which UX runs (see `startFlowOf`).
pub const StartAnyResponse = struct {
    enroll_url: ?[]const u8 = null,
    verification_url: ?[]const u8 = null,
    user_code: ?[]const u8 = null,
    device_code_handle: []const u8 = "",
    interval: u32 = 5,
    expires_in: u32 = 900,
};

/// What a 200 answer to a web-flow start actually granted.
pub const StartFlow = enum {
    /// `enroll_url` present: browser flow.
    web,
    /// Device-code fields present (older relay ignored `flow`).
    device,
    /// Neither — a protocol failure.
    malformed,
};

/// Classify a parsed web-flow start body by which fields it carries.
pub fn startFlowOf(body: StartAnyResponse) StartFlow {
    if (body.device_code_handle.len == 0) return .malformed;
    if (body.enroll_url) |u| {
        if (u.len > 0) return .web;
    }
    if (body.verification_url != null and body.user_code != null) return .device;
    return .malformed;
}

/// What the HTTP status of a web-flow start attempt means.
pub const WebStartAction = enum {
    /// 200 — parse the body (see `startFlowOf`).
    proceed,
    /// 503 — the relay has no web OAuth client; use the device-code flow.
    fallback,
    /// Anything else — enrollment refused, no point retrying another flow.
    refused,
};

/// Classify the HTTP status of a `flow:"web"` start.
pub fn webStartAction(status: u16) WebStartAction {
    return switch (status) {
        200 => .proceed,
        503 => .fallback,
        else => .refused,
    };
}

// -----------------------------------------------------------------------------
// Opening the owner's browser (web flow, best-effort)
// -----------------------------------------------------------------------------

/// The platform command that opens a URL in the default browser.
pub const BrowserCmd = struct {
    argv_buf: [3][]const u8,
    len: usize,

    pub fn argv(self: *const BrowserCmd) []const []const u8 {
        return self.argv_buf[0..self.len];
    }
};

/// Per-OS `argv` for opening `url` in the default browser.
pub fn browserOpenCmd(os_tag: std.Target.Os.Tag, url: []const u8) BrowserCmd {
    return switch (os_tag) {
        // rundll32 works from a GUI-subsystem exe with no console attached
        // (the installer pipes our stdout, there is no shell to `start` in).
        .windows => .{ .argv_buf = .{ "rundll32", "url.dll,FileProtocolHandler", url }, .len = 3 },
        .macos => .{ .argv_buf = .{ "open", url, "" }, .len = 2 },
        else => .{ .argv_buf = .{ "xdg-open", url, "" }, .len = 2 },
    };
}

/// Try to open `url` in the default browser. Best-effort: returns false when
/// the spawn fails or `GHOZTTY_ENROLL_NO_OPEN` is set (tests/automation); the
/// caller always prints the URL as well.
fn openBrowser(alloc: Allocator, url: []const u8) bool {
    if (std.process.getEnvVarOwned(alloc, "GHOZTTY_ENROLL_NO_OPEN")) |v| {
        defer alloc.free(v);
        if (v.len > 0) return false;
    } else |_| {}

    const cmd = browserOpenCmd(builtin.os.tag, url);
    var child = std.process.Child.init(cmd.argv(), alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    // Deliberately NOT waited: `open`/`rundll32`/`xdg-open` normally return
    // immediately, but a misconfigured xdg-open can block until the browser
    // closes — that must not stall the poll loop. The single unreaped child
    // is collected when this short-lived enroll process exits.
    return true;
}

/// Body of `POST /v1/enroll/poll` (any status). Every field is optional on the
/// wire; `status` is the discriminator (`pending`, `slow_down`, `complete`,
/// `denied`, `expired`, `rejected`, `unknown`, `error`).
pub const PollResponse = struct {
    status: []const u8 = "",
    interval: ?u32 = null,
    device_id: ?[]const u8 = null,
    device_token: ?[]const u8 = null,
    relay_base: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// What one poll means for the loop.
pub const PollOutcome = enum {
    /// Keep polling on the current interval.
    pending,
    /// Keep polling; grow the interval by `slow_down_bump_s`.
    slow_down,
    /// Done — the response carries the device credential.
    complete,
    /// Terminal: the owner refused the sign-in.
    denied,
    /// Terminal: the code expired before the owner acted.
    expired,
    /// Terminal: a real sign-in by an identity the relay does not allow.
    rejected,
    /// Terminal: the relay no longer knows the handle (consumed/purged).
    unknown,
    /// Transient upstream trouble — retry on the normal interval.
    transient,
    /// Terminal protocol-level failure (unknown OAuth error, 400, ...).
    failed,
};

/// Classify one poll answer from its HTTP status + parsed body. HTTP status is
/// primary (it is what the relay contractually maps outcomes onto); the body
/// `status` string disambiguates the two 403s and 200 pending vs complete.
pub fn classifyPoll(http_status: u16, body: PollResponse) PollOutcome {
    switch (http_status) {
        200 => {
            if (std.mem.eql(u8, body.status, "complete")) return .complete;
            if (std.mem.eql(u8, body.status, "pending")) return .pending;
            return .failed;
        },
        429 => return .slow_down,
        403 => return if (std.mem.eql(u8, body.status, "rejected")) .rejected else .denied,
        410 => return .expired,
        404 => return .unknown,
        else => {
            if (http_status >= 500) return .transient;
            return .failed;
        },
    }
}

/// The next poll interval after a `slow_down`: at least what the server now
/// advertises, plus the RFC 8628 5-second bump, never below the floor.
pub fn nextIntervalOnSlowDown(current_s: u32, server_interval_s: ?u32) u32 {
    const base = @max(current_s, server_interval_s orelse 0);
    return @max(base, min_interval_s) + slow_down_bump_s;
}

/// The next poll interval after a plain `pending` (the server may have grown
/// it, e.g. after it saw a Google-side slow_down): take the larger.
pub fn nextIntervalOnPending(current_s: u32, server_interval_s: ?u32) u32 {
    return @max(@max(current_s, server_interval_s orelse 0), min_interval_s);
}

// -----------------------------------------------------------------------------
// relay.env — the agent's persisted relay credential
// -----------------------------------------------------------------------------

/// Parsed relay.env contents. Values are owned (duped) — free via `deinit`.
pub const RelayEnv = struct {
    relay_base: ?[]u8 = null,
    device_token: ?[]u8 = null,

    pub fn deinit(self: *RelayEnv, alloc: Allocator) void {
        if (self.relay_base) |v| alloc.free(v);
        if (self.device_token) |v| alloc.free(v);
        self.* = .{};
    }
};

/// Parse relay.env content: `KEY=value` lines, `#` comments, blank lines, and
/// both LF and CRLF endings (the Windows installer writes CRLF). Recognized
/// keys: `RELAY_BASE`, `DEVICE_TOKEN` (and `GHOSTTY_DEVICE_TOKEN` as an
/// alias). Later lines win.
pub fn parseRelayEnv(alloc: Allocator, content: []const u8) !RelayEnv {
    var env: RelayEnv = .{};
    errdefer env.deinit(alloc);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len == 0) continue;
        if (std.mem.eql(u8, key, "RELAY_BASE")) {
            const dup = try alloc.dupe(u8, value);
            if (env.relay_base) |old| alloc.free(old);
            env.relay_base = dup;
        } else if (std.mem.eql(u8, key, "DEVICE_TOKEN") or
            std.mem.eql(u8, key, "GHOSTTY_DEVICE_TOKEN"))
        {
            const dup = try alloc.dupe(u8, value);
            if (env.device_token) |old| alloc.free(old);
            env.device_token = dup;
        }
    }
    return env;
}

/// Render relay.env content for `saveRelayEnv` (LF endings; the Windows
/// launcher's parser accepts both). Owned by the caller.
pub fn formatRelayEnv(alloc: Allocator, relay_base: []const u8, device_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "RELAY_BASE={s}\nDEVICE_TOKEN={s}\n", .{
        relay_base, device_token,
    });
}

/// Resolve the relay.env path:
///   1. `GHOSTTY_RELAY_ENV` (explicit full-path override; tests use this),
///   2. Windows: `%LOCALAPPDATA%\ghoztty\relay.env`,
///   3. else `$XDG_CONFIG_HOME/ghoztty/relay.env`, falling back to
///      `$HOME/.config/ghoztty/relay.env`.
/// Owned by the caller.
pub fn relayEnvPath(alloc: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_RELAY_ENV")) |p| {
        if (p.len > 0) return p;
        alloc.free(p);
    } else |_| {}

    if (builtin.os.tag == .windows) {
        const local = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
        defer alloc.free(local);
        return std.fs.path.join(alloc, &.{ local, "ghoztty", "relay.env" });
    } else {
        if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
            defer alloc.free(xdg);
            if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "ghoztty", "relay.env" });
        } else |_| {}
        const home = try std.process.getEnvVarOwned(alloc, "HOME");
        defer alloc.free(home);
        return std.fs.path.join(alloc, &.{ home, ".config", "ghoztty", "relay.env" });
    }
}

/// Write relay.env at `path` (creating parent directories; mode 0600 on
/// POSIX — it holds a bearer credential).
///
/// The write is ATOMIC: content lands in a staging sibling first (unique name
/// per call — `atomic_write`, T183/T500), then a rename publishes it over the
/// target (plain rename(2) on POSIX; on Windows zig's `Dir.rename` issues
/// FILE_RENAME_INFORMATION with ReplaceIfExists — MoveFileEx-replace
/// semantics — so an existing relay.env is replaced, not an error). A live
/// `--relay` daemon polls this file for a re-enroll (see `relay_creds.zig`)
/// and must never observe a half-written credential.
pub fn saveRelayEnv(alloc: Allocator, path: []const u8, relay_base: []const u8, device_token: []const u8) !void {
    const content = try formatRelayEnv(alloc, relay_base, device_token);
    defer alloc.free(content);

    // `.secret` stages the file 0600 on POSIX (it holds a bearer credential).
    try atomic_write.writeChunks(alloc, path, &.{content}, .{ .secret = true });

    // A crashed earlier save's staging debris IS the credential — sweep it.
    // Safe here because relay.env has a single writer (the enroll flow).
    atomic_write.cleanStaging(path);

    // On Windows the create-flags `mode` is ignored, so the file inherits its
    // parent's ACL (`%LOCALAPPDATA%` — user-scoped, but SYSTEM/Administrators
    // typically inherit read). Tighten it to an owner-only, non-inherited DACL
    // now that it holds a bearer credential. Best-effort: failure never breaks
    // enrollment (POSIX already got 0600 above). No-op on non-Windows.
    win_acl.harden(alloc, path);
}

/// Best-effort: tighten the DACL of the agent's EXISTING relay.env to owner-only
/// (Windows). For installs whose credential was written before ACL hardening —
/// called once at relay-mode startup so a self-update fixes them with no
/// re-enroll. No-op on non-Windows or when the file is absent.
pub fn hardenLocalCredential(alloc: Allocator) void {
    const path = relayEnvPath(alloc) catch return;
    defer alloc.free(path);
    std.fs.cwd().access(path, .{}) catch return; // only touch a file that exists
    win_acl.harden(alloc, path);
}

/// Windows DACL hardening for the credential file (no-op elsewhere). Shared
/// with the client account store — see `../win_acl.zig`.
const win_acl = @import("../win_acl.zig");

/// Load + parse relay.env at `path`. A missing file is an empty env, not an
/// error (the caller decides whether that's fatal).
pub fn loadRelayEnv(alloc: Allocator, path: []const u8) !RelayEnv {
    const content = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer alloc.free(content);
    return parseRelayEnv(alloc, content);
}

/// Convenience for `--relay` mode: the device token from the agent's own
/// relay.env, or null if there is none (missing file, no token line, any
/// error). Owned by the caller.
pub fn loadDeviceToken(alloc: Allocator) ?[]u8 {
    const path = relayEnvPath(alloc) catch return null;
    defer alloc.free(path);
    var env = loadRelayEnv(alloc, path) catch return null;
    defer env.deinit(alloc);
    if (env.device_token) |tok| {
        env.device_token = null; // hand ownership to the caller
        return tok;
    }
    return null;
}

/// Delete the agent's relay.env (and any leftover staging sibling — legacy
/// `.tmp` or a crashed writer's unique-name debris). Best-effort: a missing
/// file is success. Used by "Sign out" to drop the local credential so a
/// restart won't silently reconnect.
pub fn clearLocalCredential(alloc: Allocator) void {
    const path = relayEnvPath(alloc) catch return;
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch {};
    atomic_write.cleanStaging(path);
}

/// The account a device token is bound to, as reported by `/v1/agent/whoami`.
/// All fields are owned by the caller (free via `deinit`).
pub const WhoamiResult = struct {
    email: []u8,
    device_id: []u8,
    name: []u8,

    pub fn deinit(self: *WhoamiResult, alloc: Allocator) void {
        alloc.free(self.email);
        alloc.free(self.device_id);
        alloc.free(self.name);
        self.* = undefined;
    }
};

/// Ask the relay which account this device token is bound to — the data the
/// tray shows as "Signed in as <email>". `GET <base>/v1/agent/whoami` with the
/// bearer token. Returns null on ANY failure (network, non-200, parse, OOM): the
/// caller falls back to a neutral "Signed in" rather than surfacing an error.
pub fn whoami(alloc: Allocator, relay_base: []const u8, token: []const u8) ?WhoamiResult {
    const base = std.mem.trimRight(u8, relay_base, "/");
    const url = std.fmt.allocPrint(alloc, "{s}/v1/agent/whoami", .{base}) catch return null;
    defer alloc.free(url);

    var resp = http_client.getAuth(alloc, url, token, 64 * 1024) catch return null;
    defer resp.deinit(alloc);
    if (resp.status != 200) return null;

    const Wire = struct {
        email: []const u8 = "",
        device_id: []const u8 = "",
        name: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(Wire, alloc, resp.body, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    // Dupe all three out of the arena; free what we have on a mid-way OOM so we
    // never leak a partial result.
    const email = alloc.dupe(u8, parsed.value.email) catch return null;
    const device_id = alloc.dupe(u8, parsed.value.device_id) catch {
        alloc.free(email);
        return null;
    };
    const name = alloc.dupe(u8, parsed.value.name) catch {
        alloc.free(email);
        alloc.free(device_id);
        return null;
    };
    return .{ .email = email, .device_id = device_id, .name = name };
}

/// Revoke this device on the relay AND delete the local credential — the
/// "Sign out" action. `POST <base>/v1/agent/deenroll` with the bearer token
/// deletes the device server-side (its token hash is gone, so it can never
/// reconnect), then relay.env is cleared locally. A 204 (revoked) or a 401
/// (token already dead — a prior de-enroll) both count as signed out; anything
/// else is a hard failure the caller can surface. The local file is cleared
/// regardless, best-effort.
pub fn deEnroll(alloc: Allocator, relay_base: []const u8, token: []const u8) !void {
    const base = std.mem.trimRight(u8, relay_base, "/");
    const url = try std.fmt.allocPrint(alloc, "{s}/v1/agent/deenroll", .{base});
    defer alloc.free(url);

    const status: u16 = blk: {
        var resp = http_client.postAuth(alloc, url, token, null) catch |err| {
            // Couldn't reach the relay: leave the local credential in place so a
            // retry can still revoke it, and report the failure.
            return err;
        };
        defer resp.deinit(alloc);
        break :blk resp.status;
    };
    if (status != 204 and status != 401) return error.DeenrollFailed;

    clearLocalCredential(alloc);
}

// -----------------------------------------------------------------------------
// The enroll driver
// -----------------------------------------------------------------------------

pub const EnrollError = error{
    EnrollUnavailable,
    EnrollRefused,
    EnrollDenied,
    EnrollExpired,
    EnrollRejected,
    EnrollFailed,
};

/// Print to stdout, best-effort (a Windows GUI-subsystem exe may have no
/// stdout at all when double-clicked; the flow still works, just silently —
/// the installer pipes stdout so the prompt IS visible there).
fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

/// Options for `run`.
pub const RunOptions = struct {
    /// Skip the browser (web) flow entirely and use the device-code flow
    /// (`--no-browser` / `--headless-enroll`).
    no_browser: bool = false,
};

/// Run the whole enroll flow against `relay_base` (an `https://` or — for
/// loopback tests — `http://` base URL), registering this machine as
/// `machine_name`. Tries the browser (web) flow first, falling back to the
/// device-code flow when the relay does not offer it or `opts.no_browser` is
/// set. On success relay.env is persisted and instructions are printed.
/// Blocks for as long as the owner takes to sign in (bounded by the flow's
/// `expires_in`).
pub fn run(alloc: Allocator, relay_base: []const u8, machine_name: []const u8, opts: RunOptions) !void {
    const base = std.mem.trimRight(u8, relay_base, "/");
    const start_url = try std.fmt.allocPrint(alloc, "{s}/v1/enroll/start", .{base});
    defer alloc.free(start_url);

    say("ghoztty-agent: enrolling \"{s}\" with relay {s}\n", .{ machine_name, base });

    // --- 1a. Browser (web) flow first: no code to type -------------------------
    if (!opts.no_browser) web: {
        const web_body = try std.json.Stringify.valueAlloc(
            alloc,
            .{ .name = machine_name, .flow = "web" },
            .{},
        );
        defer alloc.free(web_body);

        var resp = http_client.postJson(alloc, start_url, web_body) catch |err| {
            say("ghoztty-agent: could not reach the relay ({s})\n", .{@errorName(err)});
            return err;
        };
        defer resp.deinit(alloc);
        switch (webStartAction(resp.status)) {
            .proceed => {},
            .fallback => {
                say("ghoztty-agent: this relay has no browser sign-in; using the code flow\n", .{});
                break :web;
            },
            .refused => {
                say("ghoztty-agent: enroll start refused (HTTP {d}): {s}\n", .{
                    resp.status, std.mem.trim(u8, resp.body, " \r\n"),
                });
                return EnrollError.EnrollRefused;
            },
        }

        const parsed = std.json.parseFromSlice(StartAnyResponse, alloc, resp.body, .{
            .ignore_unknown_fields = true,
        }) catch {
            say("ghoztty-agent: malformed enroll start response\n", .{});
            return EnrollError.EnrollFailed;
        };
        defer parsed.deinit();
        const s = parsed.value;
        switch (startFlowOf(s)) {
            .web => {
                const enroll_url = s.enroll_url.?;
                if (openBrowser(alloc, enroll_url)) {
                    say(
                        "\nA browser window should have opened to add this machine to your account.\nIf it did not, visit: {s}\n\n",
                        .{enroll_url},
                    );
                } else {
                    say(
                        "\nTo add this machine to your account, visit: {s}\n\n",
                        .{enroll_url},
                    );
                }
                say("ghoztty-agent: waiting for the browser sign-in (link expires in {d}s)\n", .{s.expires_in});
                return pollUntilDone(alloc, base, s.device_code_handle, s.interval, s.expires_in);
            },
            .device => {
                // An older relay ignored the `flow` field and started a
                // device-code grant — run its UX with what we got.
                sayDeviceCodePrompt(s.verification_url.?, s.user_code.?, s.interval, s.expires_in);
                return pollUntilDone(alloc, base, s.device_code_handle, s.interval, s.expires_in);
            },
            .malformed => {
                say("ghoztty-agent: malformed enroll start response\n", .{});
                return EnrollError.EnrollFailed;
            },
        }
    }

    // --- 1b. Device-code flow (headless / fallback) -----------------------------
    const start_body = try std.json.Stringify.valueAlloc(alloc, .{ .name = machine_name }, .{});
    defer alloc.free(start_body);

    var start_resp = http_client.postJson(alloc, start_url, start_body) catch |err| {
        say("ghoztty-agent: could not reach the relay ({s})\n", .{@errorName(err)});
        return err;
    };
    defer start_resp.deinit(alloc);
    switch (start_resp.status) {
        200 => {},
        503 => {
            say("ghoztty-agent: this relay has no sign-in (OIDC) configured; enrollment is unavailable\n", .{});
            return EnrollError.EnrollUnavailable;
        },
        else => {
            say("ghoztty-agent: enroll start refused (HTTP {d}): {s}\n", .{
                start_resp.status, std.mem.trim(u8, start_resp.body, " \r\n"),
            });
            return EnrollError.EnrollRefused;
        },
    }

    const start_parsed = std.json.parseFromSlice(StartResponse, alloc, start_resp.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        say("ghoztty-agent: malformed enroll start response\n", .{});
        return EnrollError.EnrollFailed;
    };
    defer start_parsed.deinit();
    const start = start_parsed.value;

    sayDeviceCodePrompt(start.verification_url, start.user_code, start.interval, start.expires_in);
    return pollUntilDone(alloc, base, start.device_code_handle, start.interval, start.expires_in);
}

/// The device-code flow's "visit URL, enter code" prompt.
fn sayDeviceCodePrompt(verification_url: []const u8, user_code: []const u8, interval_s: u32, expires_in_s: u32) void {
    say(
        "\nTo add this machine to your account, visit {s}\nand enter code: {s}\n\n",
        .{ verification_url, user_code },
    );
    say("ghoztty-agent: waiting for approval (polling every {d}s; code expires in {d}s)\n", .{
        @max(interval_s, min_interval_s), expires_in_s,
    });
}

/// Poll `POST <base>/v1/enroll/poll` until a terminal outcome; on `complete`,
/// persist relay.env and print how to start the agent. Shared by both flows —
/// the relay's poll contract is identical.
fn pollUntilDone(alloc: Allocator, base: []const u8, handle: []const u8, interval: u32, expires_in: u32) !void {
    const poll_url = try std.fmt.allocPrint(alloc, "{s}/v1/enroll/poll", .{base});
    defer alloc.free(poll_url);
    const poll_body = try std.json.Stringify.valueAlloc(
        alloc,
        .{ .device_code_handle = handle },
        .{},
    );
    defer alloc.free(poll_body);

    var interval_s: u32 = @max(interval, min_interval_s);
    const deadline_ms: i64 = std.time.milliTimestamp() +
        @as(i64, expires_in) * std.time.ms_per_s;

    while (true) {
        std.Thread.sleep(@as(u64, interval_s) * std.time.ns_per_s);
        if (std.time.milliTimestamp() > deadline_ms) {
            say("ghoztty-agent: the code expired before the sign-in completed; run --enroll again\n", .{});
            return EnrollError.EnrollExpired;
        }

        var resp = http_client.postJson(alloc, poll_url, poll_body) catch {
            // Transport hiccup (relay restart, flaky network): retry on the
            // normal cadence until the code's own deadline says stop.
            say("ghoztty-agent: relay unreachable; retrying in {d}s\n", .{interval_s});
            continue;
        };
        defer resp.deinit(alloc);

        const parsed = std.json.parseFromSlice(PollResponse, alloc, resp.body, .{
            .ignore_unknown_fields = true,
        }) catch null;
        defer if (parsed) |p| p.deinit();
        const body: PollResponse = if (parsed) |p| p.value else .{};

        switch (classifyPoll(resp.status, body)) {
            .pending => {
                interval_s = nextIntervalOnPending(interval_s, body.interval);
                continue;
            },
            .slow_down => {
                interval_s = nextIntervalOnSlowDown(interval_s, body.interval);
                say("ghoztty-agent: relay asked to slow down; polling every {d}s now\n", .{interval_s});
                continue;
            },
            .transient => {
                say("ghoztty-agent: relay had transient trouble; retrying in {d}s\n", .{interval_s});
                continue;
            },
            .denied => {
                say("ghoztty-agent: enrollment was denied by the account owner\n", .{});
                return EnrollError.EnrollDenied;
            },
            .expired => {
                say("ghoztty-agent: the code expired before the sign-in completed; run --enroll again\n", .{});
                return EnrollError.EnrollExpired;
            },
            .rejected => {
                say("ghoztty-agent: the sign-in succeeded but that account is not allowed on this relay\n", .{});
                return EnrollError.EnrollRejected;
            },
            .unknown => {
                say("ghoztty-agent: the relay no longer knows this enrollment; run --enroll again\n", .{});
                return EnrollError.EnrollFailed;
            },
            .failed => {
                say("ghoztty-agent: enrollment failed (HTTP {d}): {s}\n", .{
                    resp.status, body.@"error" orelse std.mem.trim(u8, resp.body, " \r\n"),
                });
                return EnrollError.EnrollFailed;
            },
            .complete => {
                const device_id = body.device_id orelse "";
                const device_token = body.device_token orelse "";
                if (device_id.len == 0 or device_token.len == 0) {
                    say("ghoztty-agent: complete response missing the device credential\n", .{});
                    return EnrollError.EnrollFailed;
                }
                // Prefer the relay's own advertised public base (it may differ
                // from what we dialed, e.g. behind a proxy); fall back to the
                // --relay argument.
                const final_base = if (body.relay_base) |rb|
                    (if (rb.len > 0) rb else base)
                else
                    base;

                const path = try relayEnvPath(alloc);
                defer alloc.free(path);
                saveRelayEnv(alloc, path, final_base, device_token) catch |err| {
                    say("ghoztty-agent: enrolled, but could not write {s} ({s})\n", .{ path, @errorName(err) });
                    return err;
                };

                say("\nEnrolled as device {s}. Credentials saved to {s}.\n", .{ device_id, path });
                say("Start the agent with: ghoztty-agent --relay={s}\n", .{final_base});
                return;
            },
        }
    }
}

// =============================================================================
// Tests (headless: JSON parsing, relay.env round-trip, backoff arithmetic)
// =============================================================================

const testing = std.testing;

test "StartResponse: parses the relay's enroll start body" {
    const raw =
        \\{"verification_url":"https://www.google.com/device","user_code":"WXYZ-1234",
        \\ "device_code_handle":"opaque-handle","interval":5,"expires_in":600,
        \\ "future_field":true}
    ;
    const parsed = try std.json.parseFromSlice(StartResponse, testing.allocator, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testing.expectEqualStrings("https://www.google.com/device", parsed.value.verification_url);
    try testing.expectEqualStrings("WXYZ-1234", parsed.value.user_code);
    try testing.expectEqualStrings("opaque-handle", parsed.value.device_code_handle);
    try testing.expectEqual(@as(u32, 5), parsed.value.interval);
    try testing.expectEqual(@as(u32, 600), parsed.value.expires_in);
}

test "PollResponse: pending / slow_down / complete bodies parse" {
    const alloc = testing.allocator;

    {
        const p = try std.json.parseFromSlice(PollResponse, alloc,
            \\{"status":"pending","interval":5}
        , .{ .ignore_unknown_fields = true });
        defer p.deinit();
        try testing.expectEqual(PollOutcome.pending, classifyPoll(200, p.value));
    }
    {
        const p = try std.json.parseFromSlice(PollResponse, alloc,
            \\{"status":"slow_down","interval":10}
        , .{ .ignore_unknown_fields = true });
        defer p.deinit();
        try testing.expectEqual(PollOutcome.slow_down, classifyPoll(429, p.value));
        try testing.expectEqual(@as(u32, 10), p.value.interval.?);
    }
    {
        const p = try std.json.parseFromSlice(PollResponse, alloc,
            \\{"status":"complete","device_id":"dev-1","device_token":"tok-1",
            \\ "relay_base":"https://relay.test"}
        , .{ .ignore_unknown_fields = true });
        defer p.deinit();
        try testing.expectEqual(PollOutcome.complete, classifyPoll(200, p.value));
        try testing.expectEqualStrings("dev-1", p.value.device_id.?);
        try testing.expectEqualStrings("tok-1", p.value.device_token.?);
        try testing.expectEqualStrings("https://relay.test", p.value.relay_base.?);
    }
}

test "classifyPoll: terminal + transient statuses" {
    try testing.expectEqual(PollOutcome.denied, classifyPoll(403, .{ .status = "denied" }));
    try testing.expectEqual(PollOutcome.rejected, classifyPoll(403, .{ .status = "rejected" }));
    try testing.expectEqual(PollOutcome.expired, classifyPoll(410, .{ .status = "expired" }));
    try testing.expectEqual(PollOutcome.unknown, classifyPoll(404, .{ .status = "unknown" }));
    try testing.expectEqual(PollOutcome.transient, classifyPoll(502, .{ .status = "error" }));
    try testing.expectEqual(PollOutcome.transient, classifyPoll(500, .{ .status = "error" }));
    try testing.expectEqual(PollOutcome.failed, classifyPoll(400, .{ .status = "error" }));
    // A 200 with an unrecognized status is a protocol failure, not pending.
    try testing.expectEqual(PollOutcome.failed, classifyPoll(200, .{ .status = "surprise" }));
}

test "backoff arithmetic: slow_down adds 5s over the max of ours/theirs" {
    try testing.expectEqual(@as(u32, 10), nextIntervalOnSlowDown(5, null));
    try testing.expectEqual(@as(u32, 15), nextIntervalOnSlowDown(5, 10));
    try testing.expectEqual(@as(u32, 15), nextIntervalOnSlowDown(10, 5));
    // Floor: a zero interval never goes below 1s before the bump.
    try testing.expectEqual(@as(u32, 6), nextIntervalOnSlowDown(0, null));

    // Pending keeps the larger of the two, no bump.
    try testing.expectEqual(@as(u32, 5), nextIntervalOnPending(5, null));
    try testing.expectEqual(@as(u32, 10), nextIntervalOnPending(5, 10));
    try testing.expectEqual(@as(u32, 1), nextIntervalOnPending(0, null));
}

test "webStartAction: 200 proceeds, 503 falls back, the rest refuse" {
    try testing.expectEqual(WebStartAction.proceed, webStartAction(200));
    try testing.expectEqual(WebStartAction.fallback, webStartAction(503));
    try testing.expectEqual(WebStartAction.refused, webStartAction(400));
    try testing.expectEqual(WebStartAction.refused, webStartAction(429));
    try testing.expectEqual(WebStartAction.refused, webStartAction(500));
}

test "StartAnyResponse + startFlowOf: web, old-relay device, malformed" {
    const alloc = testing.allocator;

    { // Current relay: web grant.
        const p = try std.json.parseFromSlice(StartAnyResponse, alloc,
            \\{"enroll_url":"https://relay.test/enroll/nonce-1",
            \\ "device_code_handle":"handle-1","interval":2,"expires_in":900}
        , .{ .ignore_unknown_fields = true });
        defer p.deinit();
        try testing.expectEqual(StartFlow.web, startFlowOf(p.value));
        try testing.expectEqualStrings("https://relay.test/enroll/nonce-1", p.value.enroll_url.?);
        try testing.expectEqual(@as(u32, 2), p.value.interval);
    }
    { // Older relay ignored `flow` and answered a device-code grant.
        const p = try std.json.parseFromSlice(StartAnyResponse, alloc,
            \\{"verification_url":"https://www.google.com/device","user_code":"WXYZ-1234",
            \\ "device_code_handle":"handle-2","interval":5,"expires_in":600}
        , .{ .ignore_unknown_fields = true });
        defer p.deinit();
        try testing.expectEqual(StartFlow.device, startFlowOf(p.value));
    }
    // Neither shape, or no handle: malformed.
    try testing.expectEqual(StartFlow.malformed, startFlowOf(.{ .device_code_handle = "h" }));
    try testing.expectEqual(StartFlow.malformed, startFlowOf(.{
        .enroll_url = "https://relay.test/enroll/n",
    }));
    try testing.expectEqual(StartFlow.malformed, startFlowOf(.{
        .device_code_handle = "h",
        .enroll_url = "",
    }));
}

test "browserOpenCmd: per-OS argv" {
    const url = "https://relay.test/enroll/abc";
    {
        const cmd = browserOpenCmd(.windows, url);
        const argv = cmd.argv();
        try testing.expectEqual(@as(usize, 3), argv.len);
        try testing.expectEqualStrings("rundll32", argv[0]);
        try testing.expectEqualStrings("url.dll,FileProtocolHandler", argv[1]);
        try testing.expectEqualStrings(url, argv[2]);
    }
    {
        const cmd = browserOpenCmd(.macos, url);
        const argv = cmd.argv();
        try testing.expectEqual(@as(usize, 2), argv.len);
        try testing.expectEqualStrings("open", argv[0]);
        try testing.expectEqualStrings(url, argv[1]);
    }
    {
        const cmd = browserOpenCmd(.linux, url);
        const argv = cmd.argv();
        try testing.expectEqual(@as(usize, 2), argv.len);
        try testing.expectEqualStrings("xdg-open", argv[0]);
        try testing.expectEqualStrings(url, argv[1]);
    }
}

test "relay.env: format → parse round-trip" {
    const alloc = testing.allocator;
    const content = try formatRelayEnv(alloc, "https://relay.example.com", "tok-abc123");
    defer alloc.free(content);

    var env = try parseRelayEnv(alloc, content);
    defer env.deinit(alloc);
    try testing.expectEqualStrings("https://relay.example.com", env.relay_base.?);
    try testing.expectEqualStrings("tok-abc123", env.device_token.?);
}

test "relay.env: CRLF, comments, spaces, alias key, later-line wins" {
    const alloc = testing.allocator;
    const content = "# written by install.ps1\r\n" ++
        "RELAY_BASE = https://relay.one \r\n" ++
        "\r\n" ++
        "GHOSTTY_DEVICE_TOKEN=alias-tok\r\n" ++
        "RELAY_BASE=https://relay.two\r\n" ++
        "not a kv line\r\n";
    var env = try parseRelayEnv(alloc, content);
    defer env.deinit(alloc);
    try testing.expectEqualStrings("https://relay.two", env.relay_base.?);
    try testing.expectEqualStrings("alias-tok", env.device_token.?);
}

test "relay.env: empty values are ignored" {
    const alloc = testing.allocator;
    var env = try parseRelayEnv(alloc, "RELAY_BASE=\nDEVICE_TOKEN=\n");
    defer env.deinit(alloc);
    try testing.expect(env.relay_base == null);
    try testing.expect(env.device_token == null);
}

test "relay.env: save → load round-trip on disk" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "nested", "relay.env" });
    defer alloc.free(path);

    try saveRelayEnv(alloc, path, "https://relay.test", "tok-1");
    var env = try loadRelayEnv(alloc, path);
    defer env.deinit(alloc);
    try testing.expectEqualStrings("https://relay.test", env.relay_base.?);
    try testing.expectEqualStrings("tok-1", env.device_token.?);

    // Overwrite rotates the credential in place — the atomic tmp+rename path
    // must replace an EXISTING target (the re-enroll case). Pre-seed a crashed
    // pre-save's fixed-name staging debris: that debris is a credential, and
    // save must sweep it.
    const parent = std.fs.path.dirname(path).?;
    {
        const legacy = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
        defer alloc.free(legacy);
        try std.fs.cwd().writeFile(.{ .sub_path = legacy, .data = "debris" });
    }
    try saveRelayEnv(alloc, path, "https://relay.test", "tok-2");
    var env2 = try loadRelayEnv(alloc, path);
    defer env2.deinit(alloc);
    try testing.expectEqualStrings("tok-2", env2.device_token.?);

    // No staging leftover of ANY name — the directory holds exactly the
    // published file (T500, the T183 tests' stronger form).
    var dir = try std.fs.cwd().openDir(parent, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        count += 1;
        try testing.expectEqualStrings("relay.env", entry.name);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "relay.env: missing file loads as empty" {
    const alloc = testing.allocator;
    var env = try loadRelayEnv(alloc, "/definitely/not/a/real/path/relay.env");
    defer env.deinit(alloc);
    try testing.expect(env.relay_base == null);
    try testing.expect(env.device_token == null);
}

test {
    testing.refAllDecls(@This());
}
