//! Build-time host tool: copy a PE executable, flipping the optional
//! header's Subsystem field. This is how `ghoztty.com` — the console-
//! subsystem twin of `ghoztty.exe` that makes PowerShell wait for (and wire
//! redirection to) CLI verbs — is produced without a second multi-minute
//! link of the whole app (T245; see `src/cli/com_shim.zig` for the design).
//!
//! Usage: patch-subsystem <input.exe> <console|gui> <output>
//!
//! The Subsystem WORD sits at offset 68 of the optional header in BOTH
//! PE32 and PE32+ (the field layouts diverge only after offset 68 — the
//! same invariant editbin /SUBSYSTEM relies on). The optional-header
//! CheckSum is left untouched: the loader only verifies it for drivers and
//! protected processes, never for ordinary executables.

const std = @import("std");

const IMAGE_SUBSYSTEM_WINDOWS_GUI: u16 = 2;
const IMAGE_SUBSYSTEM_WINDOWS_CUI: u16 = 3;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len != 4) {
        std.log.err("usage: patch-subsystem <input.exe> <console|gui> <output>", .{});
        return error.BadUsage;
    }
    const input = args[1];
    const subsystem: u16 = if (std.mem.eql(u8, args[2], "console"))
        IMAGE_SUBSYSTEM_WINDOWS_CUI
    else if (std.mem.eql(u8, args[2], "gui"))
        IMAGE_SUBSYSTEM_WINDOWS_GUI
    else {
        std.log.err("unknown subsystem '{s}' (want console|gui)", .{args[2]});
        return error.BadUsage;
    };
    const output = args[3];

    const bytes = try std.fs.cwd().readFileAlloc(alloc, input, 256 * 1024 * 1024);

    // DOS header: 'MZ', e_lfanew at 0x3C.
    if (bytes.len < 0x40 or bytes[0] != 'M' or bytes[1] != 'Z')
        return error.NotAPeFile;
    const e_lfanew = std.mem.readInt(u32, bytes[0x3C..][0..4], .little);

    // PE signature, 20-byte COFF header, then the optional header.
    if (bytes.len < e_lfanew + 4 + 20 + 70) return error.TruncatedPeFile;
    if (!std.mem.eql(u8, bytes[e_lfanew..][0..4], "PE\x00\x00"))
        return error.NotAPeFile;
    const opt = e_lfanew + 4 + 20;
    const magic = std.mem.readInt(u16, bytes[opt..][0..2], .little);
    if (magic != 0x10b and magic != 0x20b) return error.UnknownOptionalHeader;

    const subsystem_off = opt + 68;
    const old = std.mem.readInt(u16, bytes[subsystem_off..][0..2], .little);
    if (old != IMAGE_SUBSYSTEM_WINDOWS_GUI and old != IMAGE_SUBSYSTEM_WINDOWS_CUI) {
        // Offset 68 not holding a plausible subsystem value means the file
        // is not what we think it is — refuse rather than corrupt.
        std.log.err("input subsystem field is {d}, expected 2 or 3", .{old});
        return error.UnexpectedSubsystem;
    }
    std.mem.writeInt(u16, bytes[subsystem_off..][0..2], subsystem, .little);

    try std.fs.cwd().writeFile(.{ .sub_path = output, .data = bytes });
}
