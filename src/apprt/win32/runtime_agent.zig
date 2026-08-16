//! The coding-agent runtimes Ghoztty can register with (T867, the win32
//! half of Mac's `RuntimeAgent`). One case per supported CLI; the config
//! directory names are the agents' own conventions and identical on both
//! platforms (`%USERPROFILE%\.claude`, `%USERPROFILE%\.copilot`).
//!
//! Deliberately minimal for now: the install-detection probe (Mac's
//! `RuntimeProbe`, login-shell `command -v` + fallback paths) belongs to the
//! registry/service slice (T869) and is NOT here — this module only answers
//! "where does this runtime's config live", which is what the skill and hook
//! installers need.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.
const std = @import("std");

pub const RuntimeAgent = enum {
    claude,
    copilot,

    /// Home-relative config directory the runtime owns.
    pub fn configDirectoryName(self: RuntimeAgent) []const u8 {
        return switch (self) {
            .claude => ".claude",
            .copilot => ".copilot",
        };
    }

    /// User-facing name for dialogs and summaries.
    pub fn displayName(self: RuntimeAgent) []const u8 {
        return switch (self) {
            .claude => "Claude Code",
            .copilot => "Copilot CLI",
        };
    }

    /// Executable whose presence means the runtime is installed (probed by
    /// T869's service; named here so the name lives beside its runtime).
    pub fn binaryName(self: RuntimeAgent) []const u8 {
        return switch (self) {
            .claude => "claude",
            .copilot => "copilot",
        };
    }
};

const testing = std.testing;

test "config directories are the dotfile conventions the CLIs use" {
    try testing.expectEqualStrings(".claude", RuntimeAgent.claude.configDirectoryName());
    try testing.expectEqualStrings(".copilot", RuntimeAgent.copilot.configDirectoryName());
}

test "every runtime has a non-empty display and binary name" {
    inline for (std.meta.tags(RuntimeAgent)) |agent| {
        try testing.expect(agent.displayName().len > 0);
        try testing.expect(agent.binaryName().len > 0);
    }
}
