const diags = @import("cli/diagnostics.zig");

pub const args = @import("cli/args.zig");
pub const action = @import("cli/action.zig");
pub const ghostty = @import("cli/ghostty.zig");
pub const com_shim = @import("cli/com_shim.zig");
pub const CompatibilityHandler = args.CompatibilityHandler;
pub const compatibilityRenamed = args.compatibilityRenamed;
pub const DiagnosticList = diags.DiagnosticList;
pub const Diagnostic = diags.Diagnostic;
pub const Location = diags.Location;

test {
    @import("std").testing.refAllDecls(@This());

    // refAllDecls is shallow: an action file's tests only run if its
    // namespace is referenced from a test block. The +json helpers carry
    // pure-logic tests the hook scripts depend on (T866).
    _ = @import("cli/json.zig");

    // The forwarding verbs' flag allowlists (T852): pure logic, and the only
    // place that says which flags each of those verbs accepts.
    _ = @import("cli/verb_flags.zig");
}
