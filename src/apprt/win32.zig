//! Vendored from InsipidPoint/ghostty-windows (MIT, same license as upstream
//! Ghostty) and adapted for the Ghoztty fork.
//! Win32 application runtime for Ghostty on Windows.
//! Uses native Win32 API for windowing, input, and clipboard.

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    _ = @import("win32/ConfirmDialog.zig");
    _ = @import("win32/RenameDialog.zig");
    _ = @import("win32/MachineChooser.zig");
    _ = @import("win32/DarkMode.zig");
    // The system accent reader (T304). Listed here so the win32 lane actually
    // COMPILES it before T305 has a caller — an OS-touching module with no
    // reference is not checked by any lane, and discovering that in the
    // wiring task is discovering it too late.
    _ = @import("win32/system_colors.zig");
    // The split tree's leaf type and the viewer leaf it makes room for
    // (T90c). ViewerPane has no constructor caller until T90d, and the same
    // rule as system_colors applies: a module no lane compiles is a module
    // nobody has checked.
    _ = @import("win32/PaneView.zig");
    _ = @import("win32/ViewerPane.zig");
    // The COM callback object every WebView2 handler is an instance of
    // (T376). Listed in its own right, not just as webview2.zig's import:
    // its refcount and interface matching are the part a fifth handler would
    // have got wrong, so the lane should name what it is checking.
    _ = @import("win32/com.zig");
    // The WebView2 host floor (T372): the loader-less runtime probe and the
    // shared environment. Same rule again — T373 is its first caller, and a
    // module that touches the registry, LoadLibraryW and a COM vtable is the
    // last one that should go uncompiled until then.
    _ = @import("win32/webview2.zig");
    // The agent-refresh relaunch guard (T421). Its spec parser is the only
    // thing standing between a malformed environment variable and a guard that
    // waits on the wrong pid, so the lane compiles and checks it in its own
    // right.
    _ = @import("win32/relaunch_guard.zig");
    // The named-target registry (T121). Its auto `window-N` allocator is the
    // thing that must never re-mint a name a restored window already adopted,
    // and that is pure logic worth checking in its own right.
    _ = @import("win32/IpcRegistry.zig");
}
