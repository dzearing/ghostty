//! Entry-point selection for Windows GUI-subsystem executables (T100).
//!
//! A Zig exe with `pub fn main` that links the MSVC libc exports a C `main`
//! and relies on the CRT startup object to call it. With
//! `/subsystem:windows`, lld-link infers the entry as `WinMainCRTStartup`
//! (libcmt's exe_winmain.obj), which calls a `WinMain` that a `pub fn main`
//! build never defines — the link dies with
//! `lld-link: undefined symbol: WinMain`.
//!
//! Subsystem and entry point are independent: keeping the GUI subsystem (no
//! console window) while entering through `mainCRTStartup` (full CRT init,
//! then `main(argc, argv)`) is the standard "GUI app with a C main" pattern.
//! MinGW's CRT resolves this on its own, so only the MSVC ABI needs the
//! explicit entry override.

const std = @import("std");

/// Call after setting `exe.subsystem = .Windows` on a Windows target.
pub fn setMsvcGuiEntry(exe: *std.Build.Step.Compile) void {
    const target = exe.root_module.resolved_target orelse return;
    if (target.result.abi != .msvc) return;
    exe.entry = .{ .symbol_name = "mainCRTStartup" };
}
