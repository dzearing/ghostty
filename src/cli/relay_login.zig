const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const google_oauth = @import("../remote/google_oauth.zig");
const relay_account = @import("../remote/relay_account.zig");
const enroll = @import("../remote/agent/enroll.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// The Google OAuth Desktop-app client id. Falls back to
    /// `GHOSTTY_GOOGLE_CLIENT_ID`.
    @"client-id": ?[:0]const u8 = null,
    /// The client secret (Desktop clients are issued one). Falls back to
    /// `GHOSTTY_GOOGLE_CLIENT_SECRET`.
    @"client-secret": ?[:0]const u8 = null,
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

/// Sign in to a Google account for relay authentication (T21a). Runs the
/// authorization-code + PKCE flow for a Desktop-app OAuth client entirely in
/// THIS process — no IPC to the GUI: it opens the system browser, catches the
/// redirect on a loopback listener, exchanges the code for tokens, and stores
/// the refresh token (+ client config + email) DPAPI-encrypted at
/// `%LOCALAPPDATA%\ghoztty\account.dat`. The GUI only READS that store.
///
/// The OAuth client id/secret come from `--client-id=`/`--client-secret=` or
/// the `GHOSTTY_GOOGLE_CLIENT_ID`/`GHOSTTY_GOOGLE_CLIENT_SECRET` env, and are
/// PERSISTED with the credential so GUI-side token refreshes need no env.
///
/// Endpoints are `.google` in production; the E2E injects a fake issuer via
/// `GHOSTTY_OAUTH_TOKEN_ENDPOINT` (test-only).
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

    // Resolve the OAuth client: flag first, then env.
    const client_id = nonEmpty(opts.@"client-id") orelse envOwned(alloc, "GHOSTTY_GOOGLE_CLIENT_ID") orelse {
        try stderr.print(
            "Error: no Google OAuth client id. Pass --client-id= or set GHOSTTY_GOOGLE_CLIENT_ID.\n" ++
                "See docs/design/relay-oidc-setup.md.\n",
            .{},
        );
        return 1;
    };
    const client_secret = nonEmpty(opts.@"client-secret") orelse envOwned(alloc, "GHOSTTY_GOOGLE_CLIENT_SECRET");

    const endpoints = resolveEndpoints(alloc);

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

    const url = try google_oauth.authorizationURL(
        alloc,
        endpoints,
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

    // Block until the browser redirect lands (the user completes sign-in), then
    // exchange the code for tokens.
    const code = receiver.waitForCode(300_000) catch |err| {
        switch (err) {
            error.Denied => try stderr.print("Sign-in was not completed.\n", .{}),
            error.StateMismatch => try stderr.print("The sign-in redirect did not match this attempt (state mismatch).\n", .{}),
            error.Timeout => try stderr.print("Timed out waiting for the browser sign-in.\n", .{}),
            else => try stderr.print("Sign-in failed: {}\n", .{err}),
        }
        return 1;
    };

    const client: google_oauth.TokenClient = .{
        .alloc = alloc,
        .endpoints = endpoints,
        .client_id = client_id,
        .client_secret = client_secret,
    };
    var tokens = client.exchange(code, redirect_uri, verifier) catch |err| {
        try stderr.print("Token exchange failed: {}\n", .{err});
        return 1;
    };
    defer tokens.deinit();

    const refresh_token = tokens.value.refresh_token orelse {
        try stderr.print("Google did not return a refresh token (needs access_type=offline + prompt=consent).\n", .{});
        return 1;
    };
    const id_token = tokens.value.id_token orelse {
        try stderr.print("Google did not return an ID token.\n", .{});
        return 1;
    };

    var claims = google_oauth.parseIDTokenClaims(alloc, id_token) catch {
        try stderr.print("Could not parse the Google ID token.\n", .{});
        return 1;
    };
    defer claims.deinit();
    const email = claims.value.email orelse {
        try stderr.print("The Google ID token had no email claim.\n", .{});
        return 1;
    };

    const path = relay_account.accountPath(alloc) catch {
        try stderr.print("Could not resolve the account store path.\n", .{});
        return 1;
    };
    relay_account.save(alloc, path, .{
        .client_id = client_id,
        .client_secret = client_secret,
        .refresh_token = refresh_token,
        .email = email,
    }) catch |err| {
        try stderr.print("Could not save the account: {}\n", .{err});
        return 1;
    };

    {
        var out_buf: [1024]u8 = undefined;
        var out_writer = std.fs.File.stdout().writerStreaming(&out_buf);
        const stdout = &out_writer.interface;
        try stdout.print("Signed in as {s}\n", .{email});
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

/// Endpoints: `.google` in production; `GHOSTTY_OAUTH_TOKEN_ENDPOINT` /
/// `GHOSTTY_OAUTH_AUTH_ENDPOINT` inject a fake issuer for the E2E (test-only).
fn resolveEndpoints(alloc: Allocator) google_oauth.Endpoints {
    var ep = google_oauth.Endpoints.google;
    if (envOwned(alloc, "GHOSTTY_OAUTH_TOKEN_ENDPOINT")) |t| ep.token = t;
    if (envOwned(alloc, "GHOSTTY_OAUTH_AUTH_ENDPOINT")) |a| ep.authorization = a;
    return ep;
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
