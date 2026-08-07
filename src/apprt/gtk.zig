// The required comptime API for any apprt.
pub const App = @import("gtk/App.zig");
pub const Surface = @import("gtk/Surface.zig");
pub const resourcesDir = @import("gtk/flatpak.zig").resourcesDir;

// The exported API, custom for the apprt.
pub const class = @import("gtk/class.zig");
pub const WeakRef = @import("gtk/weak_ref.zig").WeakRef;
pub const pre_exec = @import("gtk/pre_exec.zig");
pub const post_fork = @import("gtk/post_fork.zig");

test {
    // Only when GTK is the runtime actually being built. Everything under
    // `gtk/` imports the `gtk`/`adw`/`gobject` modules, which the build only
    // wires up for `-Dapp-runtime=gtk` — so on any other lane these decls
    // cannot compile at all, and `refAllDecls` here is not a test that fails,
    // it is a build that fails.
    //
    // This block used to be unconditional and got away with it because
    // nothing test-reachable named `apprt.gtk`. That is a tripwire, not a
    // guarantee: `renderer/OpenGL.zig`'s `switch (apprt.runtime)` mentions
    // `apprt.gtk` as a comptime value, so the moment any win32 test's
    // reference chain reaches a surface teardown it drags this file's tests
    // in and the whole lane fails with eight "no module named 'adw'" errors
    // in files the change never touched (T165 tripped it by calling into the
    // viewer-split path from the banner overlay's WndProc).
    if (@import("../build_config.zig").app_runtime != .gtk) return;
    @import("std").testing.refAllDecls(@This());
    _ = @import("gtk/ext.zig");
    _ = @import("gtk/key.zig");
    _ = @import("gtk/portal.zig");
}
