const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Wake up the app event loop. The `none` runtime has no event loop (it is
    /// the CLI/headless artifact), so this is a no-op. It exists so code that is
    /// generic over the runtime — e.g. `App.Mailbox.push`, exercised by headless
    /// harnesses that drive a real `Termio` — can compile and link.
    pub fn wakeup(self: *const App) void {
        _ = self;
    }

    pub fn performIpc(
        alloc: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        value: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
        return internal_os.ipc_client.sendAction(
            alloc,
            comptime action.wireName(),
            value.arguments,
        );
    }
};
pub const Surface = struct {};
