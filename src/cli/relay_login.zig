const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const google_oauth = @import("../remote/google_oauth.zig");
const relay_account = @import("../remote/relay_account.zig");
const relay_directory = @import("../remote/relay_directory.zig");
const relay_session = @import("../remote/relay_session.zig");
const enroll = @import("../remote/agent/enroll.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// The Google OAuth client id (public — it appears in the browser URL).
    /// Falls back to `GHOSTTY_GOOGLE_CLIENT_ID`, then the id baked into this
    /// build via `-Dgoogle-client-id`.
    @"client-id": ?[:0]const u8 = null,
    /// The relay to sign in to (the brokered `/oauth/exchange` endpoint host).
    /// Falls back to `GHOSTTY_RELAY_BASE`, then the built-in default relay.
    relay: ?[:0]const u8 = null,
    /// Don't open a browser — just print the sign-in URL and wait for the
    /// loopback redirect. For headless/automated flows and the E2E.
    @"no-browser": bool = false,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Sign in to a Google account for relay authentication via the relay-brokered
/// (BFF) OAuth flow (T21a origin, T93 brokered model). Runs entirely in THIS
/// process — no IPC to the GUI: it opens the system browser (PKCE +
/// authorization code), catches the redirect on a loopback listener, hands the
/// code to the RELAY's `/oauth/exchange` (the relay holds the client secret
/// and talks to Google server-side), and stores the returned relay session
/// token + expiry + email DPAPI-encrypted at
/// `%LOCALAPPDATA%\ghoztty\account.dat`. The GUI only READS that store, and
/// renews the session at the same relay as it nears expiry. No Google token
/// or client secret ever touches this machine.
///
/// The OAuth client id comes from `--client-id=`, the
/// `GHOSTTY_GOOGLE_CLIENT_ID` env, or the id baked into the build
/// (`-Dgoogle-client-id`). The relay comes from `--relay=`,
/// `GHOSTTY_RELAY_BASE`, or the built-in default.
///
/// The E2E injects a fake authorize endpoint via `GHOSTTY_OAUTH_AUTH_ENDPOINT`
/// (test-only) and a fake relay via `--relay=`.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype, stderr: *std.Io.Writer) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    var arena_state = ArenaAllocator.init(alloc_gpa);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Resolve the OAuth client id: flag, then env, then the build-time bake.
    const client_id = nonEmpty(opts.@"client-id") orelse
        envOwned(alloc, "GHOSTTY_GOOGLE_CLIENT_ID") orelse
        bakedClientID() orelse
    {
        try stderr.print(
            "Error: no Google OAuth client id. This build was made without -Dgoogle-client-id;\n" ++
                "pass --client-id= or set GHOSTTY_GOOGLE_CLIENT_ID.\n",
            .{},
        );
        return 1;
    };

    // The relay that will broker the exchange (and later renew/signout).
    const relay_base = nonEmpty(opts.relay) orelse try relay_directory.resolveBase(alloc);

    // Start the loopback listener BEFORE building the URL (its port is the
    // redirect target).
    var state_buf: [google_oauth.PKCE.base64UrlLen(16)]u8 = undefined;
    google_oauth.PKCE.randomToken(16, &state_buf);
    const state = try alloc.dupe(u8, &state_buf);

    var receiver = google_oauth.LoopbackReceiver.start(alloc, state) catch {
        try stderr.print("Error: couldn't open the loopback listener for the sign-in redirect.\n", .{});
        return 1;
    };
    defer receiver.deinit();
    const redirect_uri = try receiver.redirectUri(alloc);

    var verifier_buf: [google_oauth.PKCE.verifier_len]u8 = undefined;
    google_oauth.PKCE.generateVerifier(&verifier_buf);
    const verifier = try alloc.dupe(u8, &verifier_buf);
    var challenge_buf: [google_oauth.PKCE.challenge_len]u8 = undefined;
    google_oauth.PKCE.challenge(verifier, &challenge_buf);

    const auth_endpoint = envOwned(alloc, "GHOSTTY_OAUTH_AUTH_ENDPOINT") orelse
        google_oauth.google_authorization_endpoint;
    const url = try google_oauth.authorizationURL(
        alloc,
        auth_endpoint,
        client_id,
        redirect_uri,
        state,
        &challenge_buf,
    );

    // Open the browser (unless suppressed), and always print the URL so a
    // headless/automated flow can complete it.
    if (!opts.@"no-browser") {
        _ = openBrowser(alloc, url);
    }
    {
        var out_buf: [4096]u8 = undefined;
        var out_writer = std.fs.File.stdout().writerStreaming(&out_buf);
        const stdout = &out_writer.interface;
        try stdout.print("Open this URL to sign in:\n{s}\n", .{url});
        stdout.flush() catch {};
    }

    // Block until the browser redirect lands (the user completes sign-in),
    // then hand the code to the relay — the brokered exchange (T93).
    const code = receiver.waitForCode(300_000) catch |err| {
        switch (err) {
            error.Denied => try stderr.print("Sign-in was not completed.\n", .{}),
            error.StateMismatch => try stderr.print("The sign-in redirect did not match this attempt (state mismatch).\n", .{}),
            error.Timeout => try stderr.print("Timed out waiting for the browser sign-in.\n", .{}),
            else => try stderr.print("Sign-in failed: {}\n", .{err}),
        }
        return 1;
    };

    var session = relay_session.exchange(alloc, relay_base, code, verifier, redirect_uri) catch |err| {
        switch (err) {
            error.Unauthorized => try stderr.print(
                "The relay rejected the sign-in (not on the allowlist?).\n",
                .{},
            ),
            error.Unavailable => try stderr.print(
                "The relay at {s} has no brokered sign-in configured.\n",
                .{relay_base},
            ),
            else => try stderr.print("Token exchange failed: {}\n", .{err}),
        }
        return 1;
    };
    defer session.deinit();

    const path = relay_account.accountPath(alloc) catch {
        try stderr.print("Could not resolve the account store path.\n", .{});
        return 1;
    };
    relay_account.save(alloc, path, .{
        .session_token = session.value.session_token,
        .expiry = session.value.expiry,
        .email = session.value.email,
        .relay_base = relay_base,
        .picture = session.value.picture,
    }) catch |err| {
        try stderr.print("Could not save the account: {}\n", .{err});
        return 1;
    };

    {
        var out_buf: [1024]u8 = undefined;
        var out_writer = std.fs.File.stdout().writerStreaming(&out_buf);
        const stdout = &out_writer.interface;
        try stdout.print("Signed in as {s}\n", .{session.value.email});
        stdout.flush() catch {};
    }
    return 0;
}

fn nonEmpty(s: ?[:0]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

fn envOwned(alloc: Allocator, name: []const u8) ?[]const u8 {
    const v = std.process.getEnvVarOwned(alloc, name) catch return null;
    return if (v.len == 0) null else v;
}

/// The client id baked at build time (`-Dgoogle-client-id`, or the dev-local
/// `macos/google-client-id.txt`). Null when the build carries none.
fn bakedClientID() ?[]const u8 {
    const id = build_config.google_client_id;
    return if (id.len == 0) null else id;
}

/// Open `url` in the default browser (best-effort). Reuses the enroll flow's
/// per-OS command; `GHOZTTY_ENROLL_NO_OPEN` suppresses it (shared with enroll).
fn openBrowser(alloc: Allocator, url: []const u8) bool {
    const cmd = enroll.browserOpenCmd(builtin.os.tag, url);
    var child = std.process.Child.init(cmd.argv(), alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    return true;
}
