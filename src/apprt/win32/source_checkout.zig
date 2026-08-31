//! Re-export of the shared "is this exe build output?" answer (T1124, T1146,
//! T1151).
//!
//! The rule it encodes — a build that lives in a source checkout registers
//! nothing — has to hold for the AGENT as well as the app (`adopt.zig` retires
//! the user's standalone MSI install and rewrites their `Run` key), and the
//! agent does not import the win32 apprt. So the implementation moved to
//! `src/os/source_checkout.zig`, which both seats can reach, and this file
//! stays as the name the win32 call sites already use.
const source_checkout = @import("../../os/source_checkout.zig");

pub const inSourceCheckout = source_checkout.inSourceCheckout;
