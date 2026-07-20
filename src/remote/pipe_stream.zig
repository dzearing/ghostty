//! A Windows-named-pipe-backed bidirectional byte stream (T89c) — the Windows
//! analogue of `socket_stream.zig`'s `SocketStream`: where that wraps a connected
//! socket fd so `read`→`recv` and `write`→`send`, this wraps a connected named
//! pipe HANDLE so `read`→overlapped `ReadFile` and `write`→overlapped `WriteFile`.
//! It is the transport under the agent's `--listen-pipe` mode (the secure local
//! session-persistence channel on Windows, standing in for the Mac's 0600
//! AF_UNIX socket) and the client side's `tcp_dial.dialPipe`.
//!
//! This module also owns the two endpoint helpers so ALL Windows named-pipe
//! transport logic lives in one place:
//!   - `PipeListener`: bind `\\.\pipe\<name>` with an owner-only DACL (the
//!     IpcServer SDDL pattern — the DACL stands in for the Mac's SO_PEERCRED
//!     same-uid gate) and accept connections, one fresh pipe instance each.
//!   - `dialHandle`: client connect with the PIPE_BUSY→WaitNamedPipe retry loop
//!     (the `os/ipc_client.zig` pattern) + FILE_FLAG_OVERLAPPED.
//!
//! ## Why overlapped I/O (and not plain blocking ReadFile)
//! The `Stream` contract requires `close` to be safe concurrently with a blocked
//! `read` on another thread AND to unblock it (the mux pump parks in `read`).
//! A synchronous `CloseHandle` with a blocking `ReadFile` in flight DEADLOCKS
//! until that I/O completes (the exact PtyChild teardown bug T89b fixed), so
//! every handle here is opened overlapped and `close` does `CancelIoEx` first:
//! the parked read completes with `OPERATION_ABORTED`, which maps to EOF.
//!
//! ## EOF / reset mapping (mirrors `SocketStream`)
//! A peer-closed or torn-down pipe is reported as EOF (`read` returns 0), never
//! an error: `BROKEN_PIPE` / `PIPE_NOT_CONNECTED` / `NO_DATA` / a cancelled or
//! already-closed handle all → 0. `write` to a dead peer → 0, which `writeAll`
//! turns into `error.WriteZero` (a dead lane), exactly like `SocketStream`.
//!
//! The close-vs-read handle race (a reader that passed the `closed` check and
//! issues `ReadFile` after `CloseHandle` recycled the handle value) is the same
//! accepted-and-documented class as `SocketStream`'s fd race: the atomic
//! `closed` flag narrows it and the daemon's one-reader/one-writer usage never
//! exercises it in practice.
//!
//! POSIX builds get compile-clean stubs (`error.PipeUnsupported` /
//! `unreachable`) so `tcp_dial.zig` can reference the types unconditionally;
//! the comptime OS gates in the callers keep them unreached.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const server = @import("agent/server.zig");
const connection = @import("connection.zig");

pub const PipeStream = if (builtin.os.tag == .windows)
    win.Stream
else
    stub.Stream;

pub const PipeListener = if (builtin.os.tag == .windows)
    win.Listener
else
    stub.Listener;

/// Client connect: open `name` (a full `\\.\pipe\...` path) for duplex
/// overlapped I/O. `error.FileNotFound` means nothing is listening (a dead
/// pipe name simply stops existing on Windows — the liveness probe callers
/// rely on this). PIPE_BUSY (all instances momentarily taken) is retried via
/// `WaitNamedPipeW` with a bounded attempt count.
pub const dialHandle = if (builtin.os.tag == .windows)
    win.dialHandle
else
    stub.dialHandle;

// -----------------------------------------------------------------------------
// POSIX stubs — never executed; they exist so the types/fns resolve on all
// targets (callers are comptime-gated on .windows).
// -----------------------------------------------------------------------------

const stub = struct {
    const Stream = struct {
        _unused: u8 = 0,

        pub fn serverStream(self: *@This()) server.Stream {
            _ = self;
            unreachable; // POSIX: pipe transport is Windows-only
        }
        pub fn connectionStream(self: *@This()) connection.Stream {
            _ = self;
            unreachable; // POSIX: pipe transport is Windows-only
        }
    };

    const Listener = struct {
        _unused: u8 = 0,

        pub const BindError = error{ AlreadyListening, BindFailed, OutOfMemory };
        pub fn bind(alloc: Allocator, name: []const u8) BindError!@This() {
            _ = alloc;
            _ = name;
            return error.BindFailed;
        }
        pub fn accept(self: *@This()) !*anyopaque {
            _ = self;
            unreachable;
        }
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    fn dialHandle(alloc: Allocator, name: []const u8) !*anyopaque {
        _ = alloc;
        _ = name;
        return error.PipeUnsupported;
    }
};

// -----------------------------------------------------------------------------
// Windows implementation
// -----------------------------------------------------------------------------

const win = struct {
    const W = std.os.windows;
    const k32 = W.kernel32;

    // --- Win32 declarations missing from std --------------------------------
    const FILE_FLAG_FIRST_PIPE_INSTANCE: W.DWORD = 0x00080000;
    const PIPE_REJECT_REMOTE_CLIENTS: W.DWORD = 0x00000008;
    const PIPE_UNLIMITED_INSTANCES: W.DWORD = 255;
    const CREATE_EVENT_MANUAL_RESET: W.DWORD = 0x00000001;
    const EVENT_ALL_ACCESS: W.DWORD = 0x001F0003;
    const TOKEN_QUERY: W.DWORD = 0x0008;
    const TokenUser: c_int = 1;
    const SDDL_REVISION_1: W.DWORD = 1;

    const SID_AND_ATTRIBUTES = extern struct {
        Sid: *anyopaque,
        Attributes: W.DWORD,
    };
    const TOKEN_USER = extern struct {
        User: SID_AND_ATTRIBUTES,
    };

    extern "kernel32" fn ConnectNamedPipe(
        hNamedPipe: W.HANDLE,
        lpOverlapped: ?*W.OVERLAPPED,
    ) callconv(.winapi) W.BOOL;
    extern "kernel32" fn WaitNamedPipeW(
        lpNamedPipeName: [*:0]const u16,
        nTimeOut: W.DWORD,
    ) callconv(.winapi) W.BOOL;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) W.HANDLE;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "advapi32" fn OpenProcessToken(
        ProcessHandle: W.HANDLE,
        DesiredAccess: W.DWORD,
        TokenHandle: *W.HANDLE,
    ) callconv(.winapi) W.BOOL;
    extern "advapi32" fn GetTokenInformation(
        TokenHandle: W.HANDLE,
        TokenInformationClass: c_int,
        TokenInformation: ?*anyopaque,
        TokenInformationLength: W.DWORD,
        ReturnLength: *W.DWORD,
    ) callconv(.winapi) W.BOOL;
    extern "advapi32" fn ConvertSidToStringSidW(
        Sid: *anyopaque,
        StringSid: *?[*:0]u16,
    ) callconv(.winapi) W.BOOL;
    extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        StringSecurityDescriptor: [*:0]const u16,
        StringSDRevision: W.DWORD,
        SecurityDescriptor: *?*anyopaque,
        SecurityDescriptorSize: ?*W.DWORD,
    ) callconv(.winapi) W.BOOL;

    /// A fresh manual-reset event for one overlapped operation. Per-call (not
    /// per-stream) so concurrent read+write — and any incidental concurrent
    /// writes — can never share (and corrupt) a wait state.
    fn overlappedEvent() !W.HANDLE {
        return k32.CreateEventExW(null, null, CREATE_EVENT_MANUAL_RESET, EVENT_ALL_ACCESS) orelse
            error.EventCreateFailed;
    }

    /// Whether a failed overlapped pipe op means "the lane is dead" (map to
    /// EOF/0) rather than a real error. `OPERATION_ABORTED` is our own
    /// `close`'s CancelIoEx landing; `INVALID_HANDLE` is the close-race where
    /// the handle went away between the flag check and the syscall.
    fn isDeadLane(err: W.Win32Error) bool {
        return switch (err) {
            .BROKEN_PIPE,
            .PIPE_NOT_CONNECTED,
            .NO_DATA,
            .OPERATION_ABORTED,
            .INVALID_HANDLE,
            .HANDLE_EOF,
            => true,
            else => false,
        };
    }

    const Stream = struct {
        handle: W.HANDLE,
        closed: std.atomic.Value(bool) = .{ .raw = false },

        /// Wrap an already-connected overlapped pipe handle (either end).
        pub fn init(handle: W.HANDLE) Stream {
            return .{ .handle = handle };
        }

        /// Allocate a heap `PipeStream` over `handle`. Freed by the caller via
        /// `destroy` (after `close`).
        pub fn create(alloc: Allocator, handle: W.HANDLE) !*Stream {
            const self = try alloc.create(Stream);
            self.* = Stream.init(handle);
            return self;
        }

        pub fn destroy(self: *Stream, alloc: Allocator) void {
            alloc.destroy(self);
        }

        // --- Shared byte ops (both vtable flavours) --------------------------

        fn readImpl(self: *Stream, buf: []u8) anyerror!usize {
            if (self.closed.load(.acquire)) return 0;
            if (buf.len == 0) return 0;

            const ev = try overlappedEvent();
            defer W.CloseHandle(ev);
            var ov = std.mem.zeroes(W.OVERLAPPED);
            ov.hEvent = ev;

            var n: W.DWORD = 0;
            const len: W.DWORD = @intCast(@min(buf.len, std.math.maxInt(W.DWORD)));
            if (k32.ReadFile(self.handle, buf.ptr, len, &n, &ov) != 0) return n;
            switch (W.GetLastError()) {
                .IO_PENDING => {},
                else => |err| return if (isDeadLane(err)) 0 else error.PipeReadFailed,
            }
            // GetOverlappedResult with bWait waits on `ov.hEvent` (non-null), so
            // it completes even if `close` raced the handle away meanwhile —
            // CancelIoEx (or the CloseHandle-cancels-pending-I/O path) always
            // signals the event.
            if (k32.GetOverlappedResult(self.handle, &ov, &n, W.TRUE) == 0) {
                const err = W.GetLastError();
                return if (isDeadLane(err)) 0 else error.PipeReadFailed;
            }
            return n;
        }

        fn writeImpl(self: *Stream, bytes: []const u8) anyerror!usize {
            if (self.closed.load(.acquire)) return 0;
            if (bytes.len == 0) return 0;

            const ev = try overlappedEvent();
            defer W.CloseHandle(ev);
            var ov = std.mem.zeroes(W.OVERLAPPED);
            ov.hEvent = ev;

            var n: W.DWORD = 0;
            const len: W.DWORD = @intCast(@min(bytes.len, std.math.maxInt(W.DWORD)));
            if (k32.WriteFile(self.handle, bytes.ptr, len, &n, &ov) != 0) return n;
            switch (W.GetLastError()) {
                .IO_PENDING => {},
                // A dead/reset peer (or our own close racing in) is a closed
                // lane: surface 0 so `writeAll` yields `error.WriteZero`.
                else => |err| return if (isDeadLane(err)) 0 else error.PipeWriteFailed,
            }
            if (k32.GetOverlappedResult(self.handle, &ov, &n, W.TRUE) == 0) {
                const err = W.GetLastError();
                return if (isDeadLane(err)) 0 else error.PipeWriteFailed;
            }
            return n;
        }

        /// Idempotent. `CancelIoEx` completes any parked overlapped read/write
        /// with `OPERATION_ABORTED` (→ EOF/0); closing the handle then also
        /// breaks the PEER's reads (`BROKEN_PIPE` → its EOF). Safe to call
        /// concurrently with a blocked read (the `Stream` contract).
        fn closeImpl(self: *Stream) void {
            if (self.closed.swap(true, .acq_rel)) return;
            _ = k32.CancelIoEx(self.handle, null);
            W.CloseHandle(self.handle);
        }

        // --- server.Stream adapter (agent side) ------------------------------

        pub fn serverStream(self: *Stream) server.Stream {
            return .{ .ctx = self, .vtable = &server_vtable };
        }

        const server_vtable: server.Stream.VTable = .{
            .read = serverRead,
            .write = serverWrite,
            .close = closeFn,
        };
        fn serverRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
            return readImpl(@ptrCast(@alignCast(ctx)), buf);
        }
        fn serverWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
            return writeImpl(@ptrCast(@alignCast(ctx)), bytes);
        }

        // --- connection.Stream adapter (client side) -------------------------

        pub fn connectionStream(self: *Stream) connection.Stream {
            return .{ .ctx = self, .vtable = &connection_vtable };
        }

        const connection_vtable: connection.Stream.VTable = .{
            .read = connRead,
            .write = connWrite,
            .close = closeFn,
        };
        fn connRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
            return readImpl(@ptrCast(@alignCast(ctx)), buf);
        }
        fn connWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
            return writeImpl(@ptrCast(@alignCast(ctx)), bytes);
        }

        /// Shared close for both vtables.
        fn closeFn(ctx: *anyopaque) void {
            closeImpl(@ptrCast(@alignCast(ctx)));
        }
    };

    const Listener = struct {
        alloc: Allocator,
        name_w: [:0]u16,
        /// Owner-only security descriptor (LocalFree'd in deinit). Null means
        /// construction failed and instances fall back to the default DACL —
        /// still creator-writable-only, same fallback as IpcServer.
        sd: ?*anyopaque,
        /// The created-but-not-yet-connected instance the next accept() waits
        /// on. INVALID_HANDLE_VALUE if the last replacement creation failed
        /// (accept() re-creates it).
        next: W.HANDLE,

        pub const BindError = error{ AlreadyListening, BindFailed, OutOfMemory };

        /// Claim `name` (full `\\.\pipe\...` path): create the FIRST instance
        /// with FILE_FLAG_FIRST_PIPE_INSTANCE so a taken name fails with
        /// `AlreadyListening` — binding doubles as the liveness probe (the
        /// analog of `probeUnixAlive`: a live agent owns the name; a dead
        /// one's pipe simply stops existing).
        pub fn bind(alloc: Allocator, name: []const u8) BindError!Listener {
            const name_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BindFailed,
            };
            errdefer alloc.free(name_w);

            // Best-effort owner-only DACL; fall back to the default DACL
            // rather than refusing to serve (IpcServer precedent).
            const sd = ownerOnlyDescriptor(alloc) catch null;
            errdefer if (sd) |p| {
                _ = LocalFree(p);
            };

            const first = try createInstance(name_w, sd, true);
            return .{ .alloc = alloc, .name_w = name_w, .sd = sd, .next = first };
        }

        pub fn deinit(self: *Listener) void {
            if (self.next != W.INVALID_HANDLE_VALUE) W.CloseHandle(self.next);
            if (self.sd) |p| _ = LocalFree(p);
            self.alloc.free(self.name_w);
            self.* = undefined;
        }

        /// Block until a client connects. Returns the CONNECTED instance
        /// handle (caller owns it — wrap in a `PipeStream`) and pre-creates
        /// the replacement instance so the name stays bound. A transient
        /// failure returns an error; the caller's accept loop should log and
        /// retry (accept() re-creates a missing instance on entry).
        pub fn accept(self: *Listener) !W.HANDLE {
            // Re-create the pending instance if the last replacement failed.
            if (self.next == W.INVALID_HANDLE_VALUE) {
                self.next = try createInstance(self.name_w, self.sd, false);
            }
            const inst = self.next;

            const ev = try overlappedEvent();
            defer W.CloseHandle(ev);
            var ov = std.mem.zeroes(W.OVERLAPPED);
            ov.hEvent = ev;

            if (ConnectNamedPipe(inst, &ov) == 0) {
                switch (W.GetLastError()) {
                    .IO_PENDING => {
                        var n: W.DWORD = 0;
                        if (k32.GetOverlappedResult(inst, &ov, &n, W.TRUE) == 0) {
                            switch (W.GetLastError()) {
                                // Client connected in the create→connect gap.
                                .PIPE_CONNECTED => {},
                                else => return error.AcceptFailed,
                            }
                        }
                    },
                    // Client connected in the create→connect gap.
                    .PIPE_CONNECTED => {},
                    else => return error.AcceptFailed,
                }
            }

            // Replace BEFORE returning so a client dialing between accepts
            // finds an instance (PIPE_BUSY at worst — dialHandle retries).
            self.next = createInstance(self.name_w, self.sd, false) catch W.INVALID_HANDLE_VALUE;
            return inst;
        }

        fn createInstance(name_w: [:0]const u16, sd: ?*anyopaque, first: bool) BindError!W.HANDLE {
            var sa: W.SECURITY_ATTRIBUTES = .{
                .nLength = @sizeOf(W.SECURITY_ATTRIBUTES),
                .lpSecurityDescriptor = sd,
                .bInheritHandle = W.FALSE,
            };
            const open_mode: W.DWORD = W.PIPE_ACCESS_DUPLEX | W.FILE_FLAG_OVERLAPPED |
                (if (first) FILE_FLAG_FIRST_PIPE_INSTANCE else 0);
            const h = k32.CreateNamedPipeW(
                name_w.ptr,
                open_mode,
                W.PIPE_TYPE_BYTE | W.PIPE_READMODE_BYTE | W.PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES,
                64 * 1024,
                64 * 1024,
                0,
                if (sd != null) &sa else null,
            );
            if (h == W.INVALID_HANDLE_VALUE) {
                return switch (W.GetLastError()) {
                    // With FIRST_PIPE_INSTANCE, a taken name comes back as
                    // ACCESS_DENIED (or PIPE_BUSY on some paths).
                    .ACCESS_DENIED, .PIPE_BUSY => error.AlreadyListening,
                    else => error.BindFailed,
                };
            }
            return h;
        }
    };

    fn dialHandle(alloc: Allocator, name: []const u8) !W.HANDLE {
        const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, name);
        defer alloc.free(name_w);

        // The listener replaces its instance right after each accept; the gap
        // shows up as PIPE_BUSY, so wait for a free instance with a bounded
        // retry (the `os/ipc_client.zig` connect pattern).
        var attempts: u8 = 0;
        while (true) {
            const h = k32.CreateFileW(
                name_w.ptr,
                W.GENERIC_READ | W.GENERIC_WRITE,
                0,
                null,
                W.OPEN_EXISTING,
                W.FILE_FLAG_OVERLAPPED,
                null,
            );
            if (h != W.INVALID_HANDLE_VALUE) return h;
            switch (W.GetLastError()) {
                .PIPE_BUSY => {
                    attempts += 1;
                    if (attempts >= 10) return error.ConnectionRefused;
                    _ = WaitNamedPipeW(name_w.ptr, 1000);
                },
                // Nothing is listening: a dead pipe name stops existing.
                .FILE_NOT_FOUND, .PATH_NOT_FOUND => return error.FileNotFound,
                else => return error.ConnectionRefused,
            }
        }
    }

    /// Build an owner-only security descriptor via SDDL: protected DACL with a
    /// single GENERIC_ALL ACE for the current user's SID (the IpcServer.zig
    /// pattern — this DACL is the Windows stand-in for the unix listener's
    /// SO_PEERCRED same-uid gate). Caller LocalFrees the result.
    fn ownerOnlyDescriptor(alloc: Allocator) !*anyopaque {
        var token: W.HANDLE = undefined;
        if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) == 0)
            return error.TokenOpenFailed;
        defer W.CloseHandle(token);

        var needed: W.DWORD = 0;
        _ = GetTokenInformation(token, TokenUser, null, 0, &needed);
        if (needed == 0) return error.TokenInfoFailed;
        const buf = try alloc.alignedAlloc(
            u8,
            std.mem.Alignment.fromByteUnits(@alignOf(TOKEN_USER)),
            needed,
        );
        defer alloc.free(buf);
        if (GetTokenInformation(token, TokenUser, buf.ptr, needed, &needed) == 0)
            return error.TokenInfoFailed;
        const user: *const TOKEN_USER = @ptrCast(buf.ptr);

        var sid_str: ?[*:0]u16 = null;
        if (ConvertSidToStringSidW(user.User.Sid, &sid_str) == 0)
            return error.SidConversionFailed;
        defer _ = LocalFree(sid_str);
        const sid = std.mem.span(sid_str.?);

        // D: DACL, P: protected (no inheritance), A: allow, GA: GENERIC_ALL.
        var sddl_buf: [128]u16 = undefined;
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
        const suffix = std.unicode.utf8ToUtf16LeStringLiteral(")");
        if (prefix.len + sid.len + suffix.len + 1 > sddl_buf.len)
            return error.SidConversionFailed;
        @memcpy(sddl_buf[0..prefix.len], prefix);
        @memcpy(sddl_buf[prefix.len..][0..sid.len], sid);
        @memcpy(sddl_buf[prefix.len + sid.len ..][0..suffix.len], suffix);
        sddl_buf[prefix.len + sid.len + suffix.len] = 0;
        const sddl: [*:0]const u16 = @ptrCast(&sddl_buf);

        var sd: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl,
            SDDL_REVISION_1,
            &sd,
            null,
        ) == 0) return error.DescriptorConversionFailed;
        return sd.?;
    }
};

// =============================================================================
// Tests — a real loopback named-pipe pair (no mock; exercises listener + dial +
// overlapped read/write/close). Windows-only; POSIX skips.
// =============================================================================

const testing = std.testing;

/// A unique-per-process pipe name for one test.
fn testPipeName(buf: []u8, tag: []const u8) ![]const u8 {
    const pid: u32 = if (builtin.os.tag == .windows)
        std.os.windows.GetCurrentProcessId()
    else
        0;
    return std.fmt.bufPrint(buf, "\\\\.\\pipe\\gztt-pstest-{s}-{d}", .{ tag, pid });
}

test "PipeStream: round-trips bytes over a real loopback pipe" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var nbuf: [128]u8 = undefined;
    const name = try testPipeName(&nbuf, "rt");

    var listener = try PipeListener.bind(alloc, name);
    defer listener.deinit();

    const Accepter = struct {
        listener: *PipeListener,
        handle: std.os.windows.HANDLE = undefined,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.handle = self.listener.accept() catch |e| {
                self.err = e;
                return;
            };
        }
    };
    var accepter = Accepter{ .listener = &listener };
    const t = try std.Thread.spawn(.{}, Accepter.run, .{&accepter});

    const client_h = try dialHandle(alloc, name);
    t.join();
    try testing.expect(accepter.err == null);

    var a = PipeStream.init(accepter.handle); // agent end
    var b = PipeStream.init(client_h); // client end
    defer a.serverStream().close();
    defer b.connectionStream().close();

    const sa = a.serverStream();
    const sb = b.connectionStream();

    try sa.writeAll("hello-pipe");
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    while (total < "hello-pipe".len) {
        const n = try sb.read(buf[total..]);
        try testing.expect(n > 0);
        total += n;
    }
    try testing.expectEqualStrings("hello-pipe", buf[0..total]);

    // Reverse direction too.
    try sb.writeAll("pong");
    total = 0;
    while (total < "pong".len) {
        const n = try sa.read(buf[total..]);
        try testing.expect(n > 0);
        total += n;
    }
    try testing.expectEqualStrings("pong", buf[0..total]);
}

test "PipeStream: peer close surfaces as EOF (read returns 0)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var nbuf: [128]u8 = undefined;
    const name = try testPipeName(&nbuf, "eof");

    var listener = try PipeListener.bind(alloc, name);
    defer listener.deinit();

    const Accepter = struct {
        listener: *PipeListener,
        handle: std.os.windows.HANDLE = undefined,
        fn run(self: *@This()) void {
            self.handle = self.listener.accept() catch return;
        }
    };
    var accepter = Accepter{ .listener = &listener };
    const t = try std.Thread.spawn(.{}, Accepter.run, .{&accepter});
    const client_h = try dialHandle(alloc, name);
    t.join();

    var a = PipeStream.init(accepter.handle);
    var b = PipeStream.init(client_h);
    defer b.connectionStream().close();

    // Close side a; side b's next read must observe EOF (0), not an error.
    a.serverStream().close();

    var buf: [64]u8 = undefined;
    const n = try b.connectionStream().read(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "PipeStream: close unblocks a blocked read" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var nbuf: [128]u8 = undefined;
    const name = try testPipeName(&nbuf, "unblk");

    var listener = try PipeListener.bind(alloc, name);
    defer listener.deinit();

    const Accepter = struct {
        listener: *PipeListener,
        handle: std.os.windows.HANDLE = undefined,
        fn run(self: *@This()) void {
            self.handle = self.listener.accept() catch return;
        }
    };
    var accepter = Accepter{ .listener = &listener };
    const at = try std.Thread.spawn(.{}, Accepter.run, .{&accepter});
    const client_h = try dialHandle(alloc, name);
    at.join();

    const a = try PipeStream.create(alloc, accepter.handle);
    defer a.destroy(alloc);
    var b = PipeStream.init(client_h);
    defer b.connectionStream().close();

    const Reader = struct {
        s: *PipeStream,
        got_eof: bool = false,
        fn run(self: *@This()) void {
            var buf: [16]u8 = undefined;
            const n = self.s.serverStream().read(&buf) catch 0;
            self.got_eof = (n == 0);
        }
    };
    var r = Reader{ .s = a };
    const t = try std.Thread.spawn(.{}, Reader.run, .{&r});
    // Give the reader a moment to park in the overlapped wait, then close
    // from this thread — CancelIoEx must complete it with EOF.
    std.Thread.sleep(20 * std.time.ns_per_ms);
    a.serverStream().close();
    t.join();
    try testing.expect(r.got_eof);
}

test "PipeListener: binding a taken name fails with AlreadyListening" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var nbuf: [128]u8 = undefined;
    const name = try testPipeName(&nbuf, "taken");

    var listener = try PipeListener.bind(alloc, name);
    defer listener.deinit();

    try testing.expectError(error.AlreadyListening, PipeListener.bind(alloc, name));
}

test "dialHandle: connecting to a nonexistent pipe fails with FileNotFound" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var nbuf: [128]u8 = undefined;
    const name = try testPipeName(&nbuf, "nope");
    try testing.expectError(error.FileNotFound, dialHandle(testing.allocator, name));
}

test "PipeListener: serves multiple concurrent client connections" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var nbuf: [128]u8 = undefined;
    const name = try testPipeName(&nbuf, "multi");

    var listener = try PipeListener.bind(alloc, name);
    defer listener.deinit();

    const Accepter = struct {
        listener: *PipeListener,
        handles: [2]std.os.windows.HANDLE = undefined,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            for (&self.handles) |*h| {
                h.* = self.listener.accept() catch |e| {
                    self.err = e;
                    return;
                };
            }
        }
    };
    var accepter = Accepter{ .listener = &listener };
    const t = try std.Thread.spawn(.{}, Accepter.run, .{&accepter});

    const c1 = try dialHandle(alloc, name);
    const c2 = try dialHandle(alloc, name);
    t.join();
    try testing.expect(accepter.err == null);

    // Both server ends must round-trip independently.
    var s1 = PipeStream.init(accepter.handles[0]);
    var s2 = PipeStream.init(accepter.handles[1]);
    var k1 = PipeStream.init(c1);
    var k2 = PipeStream.init(c2);
    defer s1.serverStream().close();
    defer s2.serverStream().close();
    defer k1.connectionStream().close();
    defer k2.connectionStream().close();

    try k1.connectionStream().writeAll("one");
    try k2.connectionStream().writeAll("two");

    var buf: [8]u8 = undefined;
    var total: usize = 0;
    while (total < 3) total += try s1.serverStream().read(buf[total..]);
    try testing.expectEqualStrings("one", buf[0..3]);
    total = 0;
    while (total < 3) total += try s2.serverStream().read(buf[total..]);
    try testing.expectEqualStrings("two", buf[0..3]);
}

test {
    testing.refAllDecls(@This());
}
