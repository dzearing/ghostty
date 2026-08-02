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
}
