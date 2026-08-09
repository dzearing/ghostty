//! Which process is LISTENING on a local TCP port (Windows).
//!
//! The Windows answer to `lsof -iTCP:<port> -sTCP:LISTEN -t`, and the first
//! half of the viewer's leg-2 provenance chain (T638): a pane pointed at
//! `http://localhost:3000` is attributable to whatever checkout the dev server
//! on :3000 was started from, and finding that checkout starts with finding the
//! process. The second half — that process's working directory — is
//! `process_cwd.zig`, which pairs with this module and carries the same
//! contract: every failure returns null, never a guess and never a crash.
//!
//! `GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER)` is the documented API
//! for this and needs no elevation: it reports the owning pid of every LISTEN
//! socket on the machine, including processes belonging to other users (whose
//! cwd we then simply fail to read, which is the same null). There is no
//! port->pid syscall, so the whole table is fetched and scanned; it holds a few
//! hundred rows on a busy box, which is why the caller keeps this behind a
//! cache and off the UI thread rather than why it needs to be cleverer.
//!
//! IPv4 and IPv6 are two separate tables. Both are consulted, v4 first, because
//! a dev server may bind either or (usually) both — and a `localhost:PORT` URL
//! says nothing about which family the browser will end up using.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

/// The pid listening on `port`, or null when nothing is (or when the table
/// cannot be read at all).
pub fn forPort(alloc: Allocator, port: u16) ?u32 {
    if (comptime builtin.os.tag != .windows) return null;
    if (port == 0) return null;
    if (scan(MIB_TCPROW_OWNER_PID, alloc, port, AF_INET)) |pid| return pid;
    return scan(MIB_TCP6ROW_OWNER_PID, alloc, port, AF_INET6);
}

/// Fetch one address family's listener table and return the first row whose
/// local port matches. `Row` differs between the families only in its shape —
/// the two fields this reads (`dwLocalPort`, `dwOwningPid`) are named the same
/// in both, so one scan serves both tables.
fn scan(comptime Row: type, alloc: Allocator, port: u16, af: windows.ULONG) ?u32 {
    var size: windows.DWORD = 0;
    // A first call with no buffer reports the size it wants. The table can grow
    // between the sizing call and the real one (sockets open constantly), so
    // the whole thing is a short retry loop rather than two calls — but a
    // BOUNDED one, because a machine whose table grows faster than we can ask
    // is a machine we decline to answer about rather than one we spin on.
    var attempt: usize = 0;
    while (attempt < 4) : (attempt += 1) {
        if (size == 0) {
            _ = GetExtendedTcpTable(null, &size, 0, af, TCP_TABLE_OWNER_PID_LISTENER, 0);
            if (size == 0) return null;
        }

        // Allocated as u32s so the buffer is 4-aligned, which is what both row
        // types need — every field in them is a DWORD or a byte array.
        const words = alloc.alloc(u32, (size + 3) / 4) catch return null;
        defer alloc.free(words);
        const bytes = std.mem.sliceAsBytes(words);

        const rc = GetExtendedTcpTable(
            bytes.ptr,
            &size,
            0,
            af,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        );
        if (rc == ERROR_INSUFFICIENT_BUFFER) continue; // `size` now says how much
        if (rc != 0) return null;

        // The table is `{ DWORD dwNumEntries; Row table[]; }`.
        const count = words[0];
        const rows_off = @sizeOf(u32);
        const want = rows_off + @as(usize, count) * @sizeOf(Row);
        if (want > bytes.len) return null; // a header we do not believe
        const rows: [*]const Row = @ptrCast(@alignCast(bytes.ptr + rows_off));

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const row = rows[i];
            if (localPort(row.dwLocalPort) != port) continue;
            if (row.dwOwningPid == 0) continue;
            return row.dwOwningPid;
        }
        return null;
    }
    return null;
}

/// The port out of a `dwLocalPort` field. The DWORD carries the port in
/// NETWORK byte order in its low two bytes — the same `ntohs((u_short)…)` every
/// C caller of this API writes, and the reason a naive read of :3000 comes back
/// as 47115.
fn localPort(dw: windows.DWORD) u16 {
    return std.mem.bigToNative(u16, @truncate(dw));
}

// -----------------------------------------------------------------------------
// win32
// -----------------------------------------------------------------------------

/// `MIB_TCPROW_OWNER_PID` (iprtrmib.h). Only the last field and the local port
/// are read; the rest is here so the struct's SHAPE is the ABI's rather than a
/// hand-computed offset.
const MIB_TCPROW_OWNER_PID = extern struct {
    dwState: windows.DWORD,
    dwLocalAddr: windows.DWORD,
    dwLocalPort: windows.DWORD,
    dwRemoteAddr: windows.DWORD,
    dwRemotePort: windows.DWORD,
    dwOwningPid: windows.DWORD,
};

/// `MIB_TCP6ROW_OWNER_PID`. Note the field ORDER differs from the v4 row —
/// state sits at the end here, not the start — which is exactly why this is a
/// declared struct and not an offset arithmetic.
const MIB_TCP6ROW_OWNER_PID = extern struct {
    ucLocalAddr: [16]u8,
    dwLocalScopeId: windows.DWORD,
    dwLocalPort: windows.DWORD,
    ucRemoteAddr: [16]u8,
    dwRemoteScopeId: windows.DWORD,
    dwRemotePort: windows.DWORD,
    dwState: windows.DWORD,
    dwOwningPid: windows.DWORD,
};

const AF_INET: windows.ULONG = 2;
const AF_INET6: windows.ULONG = 23;
/// `TCP_TABLE_OWNER_PID_LISTENER` — LISTEN sockets only, with their owning pid.
const TCP_TABLE_OWNER_PID_LISTENER: c_int = 3;
const ERROR_INSUFFICIENT_BUFFER: windows.DWORD = 122;

extern "iphlpapi" fn GetExtendedTcpTable(
    pTcpTable: ?*anyopaque,
    pdwOutBufLen: *windows.DWORD,
    bOrder: windows.BOOL,
    ulAf: windows.ULONG,
    TableClass: c_int,
    Reserved: windows.ULONG,
) callconv(.winapi) windows.DWORD;

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "the row layouts match the ABI" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(MIB_TCPROW_OWNER_PID));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(MIB_TCP6ROW_OWNER_PID));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(MIB_TCP6ROW_OWNER_PID));
}

test "a port is read out of network byte order" {
    // What the API actually stores for :3000 — 0x0BB8 big-endian in the low
    // two bytes. Read without the swap it is 47115, which is the bug this
    // function exists to not have.
    try std.testing.expectEqual(@as(u16, 3000), localPort(0xB80B));
    try std.testing.expectEqual(@as(u16, 80), localPort(0x5000));
}

test "forPort finds THIS process behind a listener it just opened" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    // An ephemeral port, so the test cannot collide with anything on the box.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();

    const pid = forPort(testing.allocator, port) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(windows.GetCurrentProcessId(), pid);
}

test "a port nobody is listening on has no pid" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    // Bind and immediately release: the port was ours a moment ago and is
    // nobody's now, which is a far better "free port" than a guessed number.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    const port = server.listen_address.getPort();
    server.deinit();

    try testing.expect(forPort(testing.allocator, port) == null);
    try testing.expect(forPort(testing.allocator, 0) == null);
}
