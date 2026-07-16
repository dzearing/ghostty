//! Best-effort owner-only DACL hardening for credential files on Windows.
//!
//! Extracted from `agent/enroll.zig` (T21a) so the client account store
//! (`relay_account.zig`) and the agent's relay.env share one implementation.
//! On Windows, `std.fs.File.CreateFlags.mode` is ignored, so a credential
//! file inherits its parent's ACL (`%LOCALAPPDATA%` — user-scoped, but
//! SYSTEM/Administrators typically inherit read). `harden` replaces that
//! with a single non-inherited ACE granting the owning user full control.
//!
//! Every failure path is a silent no-op: hardening must never break the
//! write that just succeeded (POSIX callers already got 0600 from `mode`).
//! No-op on non-Windows.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const harden = if (builtin.os.tag == .windows) win.harden else fallback.harden;

const fallback = struct {
    fn harden(_: Allocator, _: []const u8) void {}
};

const win = struct {
    const W = std.os.windows;
    const DWORD = W.DWORD;
    const BOOL = W.BOOL;
    const HANDLE = W.HANDLE;

    const TOKEN_QUERY: DWORD = 0x0008;
    const TokenUser: c_int = 1; // TOKEN_INFORMATION_CLASS
    const SE_FILE_OBJECT: c_int = 1;
    const DACL_SECURITY_INFORMATION: DWORD = 0x00000004;
    const PROTECTED_DACL_SECURITY_INFORMATION: DWORD = 0x80000000;
    const ACL_REVISION: DWORD = 2;
    // FILE_ALL_ACCESS: full control for the owning user.
    const FILE_ALL_ACCESS: DWORD = 0x001F01FF;

    const SID_AND_ATTRIBUTES = extern struct { Sid: ?*anyopaque, Attributes: DWORD };
    const TOKEN_USER = extern struct { User: SID_AND_ATTRIBUTES };

    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "advapi32" fn OpenProcessToken(ProcessHandle: HANDLE, DesiredAccess: DWORD, TokenHandle: *HANDLE) callconv(.winapi) BOOL;
    extern "advapi32" fn GetTokenInformation(TokenHandle: HANDLE, TokenInformationClass: c_int, TokenInformation: ?*anyopaque, TokenInformationLength: DWORD, ReturnLength: *DWORD) callconv(.winapi) BOOL;
    extern "advapi32" fn InitializeAcl(pAcl: *anyopaque, nAclLength: DWORD, dwAclRevision: DWORD) callconv(.winapi) BOOL;
    extern "advapi32" fn AddAccessAllowedAce(pAcl: *anyopaque, dwAceRevision: DWORD, AccessMask: DWORD, pSid: *anyopaque) callconv(.winapi) BOOL;
    extern "advapi32" fn SetNamedSecurityInfoW(pObjectName: [*:0]const u16, ObjectType: c_int, SecurityInfo: DWORD, psidOwner: ?*anyopaque, psidGroup: ?*anyopaque, pDacl: ?*anyopaque, pSacl: ?*anyopaque) callconv(.winapi) DWORD;

    fn harden(alloc: Allocator, path: []const u8) void {
        var token: HANDLE = undefined;
        if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) == 0) return;
        defer _ = CloseHandle(token);

        // Current user's SID: TOKEN_USER header + inline SID. A SID is at most
        // 68 bytes, so 256 is ample; a short buffer just skips hardening.
        var info: [256]u8 align(8) = undefined;
        var need: DWORD = 0;
        if (GetTokenInformation(token, TokenUser, &info, info.len, &need) == 0) return;
        const tu: *const TOKEN_USER = @ptrCast(@alignCast(&info));
        const sid = tu.User.Sid orelse return;

        // One-ACE DACL granting the user full control. 1 KiB dwarfs
        // sizeof(ACL)+sizeof(ACE)+sizeof(SID); align(4) as ACLs require.
        var acl_buf: [1024]u8 align(4) = undefined;
        if (InitializeAcl(&acl_buf, acl_buf.len, ACL_REVISION) == 0) return;
        if (AddAccessAllowedAce(&acl_buf, ACL_REVISION, FILE_ALL_ACCESS, sid) == 0) return;

        // Round-trip the WTF-8 path (as Zig hands out on Windows) back to WTF-16.
        const path_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch return;
        defer alloc.free(path_w);

        // PROTECTED_DACL_* strips inheritance, so ONLY our explicit ACE remains.
        _ = SetNamedSecurityInfoW(
            path_w,
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            null,
            null,
            &acl_buf,
            null,
        );
    }
};
