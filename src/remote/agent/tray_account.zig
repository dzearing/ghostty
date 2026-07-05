//! Account controller for the tray's Sign in / Sign out actions.
//!
//! The Windows tray (`tray.zig`) is a Win32 message-pump: menu callbacks run on
//! the pump thread and MUST NOT block. Sign in (browser OAuth) and sign out
//! (revoke on the relay) are slow, blocking operations, so this controller owns
//! them — each `request*` spawns a detached worker thread and the pump thread
//! only ever reads a cheap, mutex-guarded snapshot (`view`) to render the menu.
//!
//! This module is deliberately platform-neutral (no Win32) so it compiles and
//! unit-tests on the macOS host like the rest of the agent core; `tray.zig`
//! holds a `?*TrayAccount` (non-null only in relay mode — `--listen` has no
//! account).
//!
//! Lifecycle wiring:
//!   - Sign out: `POST /v1/agent/deenroll` (revoke server-side + clear the local
//!     relay.env), then park the relay link (`link.disconnect`) so the now-dead
//!     token is never dialed again.
//!   - Sign in: run the interactive enroll (browser), adopt the freshly written
//!     token into the live `Creds` immediately (the relay.env watcher would also
//!     pick it up within its poll interval), then un-park the link
//!     (`link.reconnect`) and refresh the displayed email.

const std = @import("std");
const enroll = @import("enroll.zig");
const relay_creds = @import("relay_creds.zig");
const link_control = @import("link_control.zig");

/// What the account section of the menu shows.
pub const Status = enum(u8) {
    /// Bound to an account; `email` (if fetched) names it.
    signed_in,
    /// De-enrolled — no local credential.
    signed_out,
    /// A sign in / sign out is in flight.
    working,
};

pub const TrayAccount = struct {
    alloc: std.mem.Allocator,
    /// HTTP(S) relay base (for whoami/deEnroll/enroll). Borrowed; the daemon
    /// frame that owns it outlives the tray.
    base_url: []const u8,
    /// The live device credential (read for whoami/deEnroll; a new token is
    /// adopted here on sign in).
    creds: *relay_creds.Creds,
    /// The relay link, parked on sign out and un-parked on sign in.
    link: *link_control.LinkControl,

    /// This machine's display name for re-enroll (owned copy — the caller's
    /// hostname buffer does not outlive `init`).
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,

    mutex: std.Thread.Mutex = .{},
    status: Status = .signed_in,
    email_buf: [320]u8 = undefined,
    email_len: usize = 0,
    /// One sign in/out at a time (a second click while working is ignored).
    busy: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        base_url: []const u8,
        machine_name: []const u8,
        creds: *relay_creds.Creds,
        link: *link_control.LinkControl,
    ) TrayAccount {
        var a: TrayAccount = .{ .alloc = alloc, .base_url = base_url, .creds = creds, .link = link };
        const n = @min(machine_name.len, a.name_buf.len);
        @memcpy(a.name_buf[0..n], machine_name[0..n]);
        a.name_len = n;
        return a;
    }

    fn machineName(self: *const TrayAccount) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// A cheap snapshot for menu rendering. Copies the email into `email_out`
    /// (caller-owned) so the lock is never held across a UI call. The returned
    /// `email` slice borrows `email_out`.
    pub const View = struct { status: Status, email: []const u8 };
    pub fn view(self: *TrayAccount, email_out: []u8) View {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(self.email_len, email_out.len);
        @memcpy(email_out[0..n], self.email_buf[0..n]);
        return .{ .status = self.status, .email = email_out[0..n] };
    }

    fn setEmail(self: *TrayAccount, email: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(email.len, self.email_buf.len);
        @memcpy(self.email_buf[0..n], email[0..n]);
        self.email_len = n;
    }

    fn clearEmail(self: *TrayAccount) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.email_len = 0;
    }

    fn setStatus(self: *TrayAccount, s: Status) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.status = s;
    }

    /// Claim the single-op slot, moving to `working`. Returns false if an op is
    /// already in flight (the click is dropped).
    fn tryBegin(self: *TrayAccount) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.busy) return false;
        self.busy = true;
        self.status = .working;
        return true;
    }

    fn end(self: *TrayAccount, s: Status) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.busy = false;
        self.status = s;
    }

    // --- requests (called from the message-pump thread) ---------------------

    /// Fetch the bound account email in the background (read-only; runs even
    /// while an op is in flight). Kicked once at tray startup and after sign in.
    pub fn requestRefresh(self: *TrayAccount) void {
        (std.Thread.spawn(.{}, refreshWorker, .{self}) catch return).detach();
    }

    /// Full de-enroll: revoke on the relay + clear the local credential + park
    /// the link. No-op if an op is already running.
    pub fn requestSignOut(self: *TrayAccount) void {
        if (!self.tryBegin()) return;
        (std.Thread.spawn(.{}, signOutWorker, .{self}) catch {
            self.end(.signed_in); // spawn failed — nothing happened
            return;
        }).detach();
    }

    /// Interactive re-enroll (browser), then adopt the new token + un-park the
    /// link. No-op if an op is already running.
    pub fn requestSignIn(self: *TrayAccount) void {
        if (!self.tryBegin()) return;
        (std.Thread.spawn(.{}, signInWorker, .{self}) catch {
            self.end(.signed_out); // spawn failed — still signed out
            return;
        }).detach();
    }

    // --- workers (each on its own thread) -----------------------------------

    fn refreshWorker(self: *TrayAccount) void {
        const token = self.creds.current();
        if (enroll.whoami(self.alloc, self.base_url, token)) |res| {
            var r = res;
            defer r.deinit(self.alloc);
            self.setEmail(r.email);
        }
    }

    fn signOutWorker(self: *TrayAccount) void {
        const token = self.creds.current();
        enroll.deEnroll(self.alloc, self.base_url, token) catch {
            // Couldn't reach the relay to revoke — stay signed in (the local
            // credential is intentionally left in place; see enroll.deEnroll).
            self.end(.signed_in);
            return;
        };
        // Credential is dead server-side and cleared locally: park the link so
        // the revoked token is never dialed again.
        self.link.disconnect();
        self.clearEmail();
        self.end(.signed_out);
    }

    fn signInWorker(self: *TrayAccount) void {
        enroll.run(self.alloc, self.base_url, self.machineName(), .{}) catch {
            self.end(.signed_out); // enrollment cancelled / failed
            return;
        };
        // Adopt the freshly written token NOW so the reconnect dials with a
        // valid credential (the relay.env watcher would also adopt it within its
        // poll interval; adopting is idempotent — a matching token is a no-op).
        if (enroll.loadDeviceToken(self.alloc)) |tok| {
            self.creds.adopt(tok); // ownership transfers into Creds
        }
        self.link.reconnect();
        // Fetch the email inline (same thread) before we report done.
        const token = self.creds.current();
        if (enroll.whoami(self.alloc, self.base_url, token)) |res| {
            var r = res;
            defer r.deinit(self.alloc);
            self.setEmail(r.email);
        }
        self.end(.signed_in);
    }
};

test "view copies email and status without holding the lock" {
    // A minimal smoke test: init with dummy deps, poke status/email, read back.
    var creds = relay_creds.Creds.init(std.testing.allocator, .relay_env, try std.testing.allocator.dupe(u8, "tok"));
    defer creds.deinit();
    var link: link_control.LinkControl = .{ .host = "example" };
    var acct = TrayAccount.init(std.testing.allocator, "https://relay.example", "mybox", &creds, &link);

    acct.setEmail("me@example.com");
    acct.setStatus(.signed_in);

    var buf: [320]u8 = undefined;
    const v = acct.view(&buf);
    try std.testing.expectEqual(Status.signed_in, v.status);
    try std.testing.expectEqualStrings("me@example.com", v.email);
}
