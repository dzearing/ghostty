//! The hooks Ghoztty registers with a coding-agent runtime: which purposes
//! exist, which installed script serves each, and the per-event command
//! string a generated hook file carries (T868, the win32 half of Mac's
//! `HookSpec.swift` — the purpose/command half; the file layout half landed
//! in `hook_scripts.zig` with T867).
//!
//! The command shape is Mac's exactly — `bash '<script>' <verb>
//! --runtime=<name>` — because it is the shape measured to work here: Claude
//! Code runs Windows hook commands through a POSIX shell (the marketplace
//! plugin's `bash "${CLAUDE_PLUGIN_ROOT}/..."` hooks run on this box today),
//! and the T866 assets are bash scripts on both platforms. The payload
//! arrives on stdin, NEVER interpolated into the command string.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

const hook_scripts = @import("hook_scripts.zig");
const RuntimeAgent = @import("runtime_agent.zig").RuntimeAgent;

/// How a runtime stores its hooks: a file Ghoztty owns outright (Copilot's
/// auto-loaded hooks dir), or a fragment merged into a shared user-owned
/// config (Claude's `settings.json`).
pub const HookOwnership = enum { dedicated_file, merged_fragment };

/// Every hook Ghoztty registers, and which installed script serves it.
///
/// The banner purposes keep the pane's sticky banner current; the activity
/// purposes own the pane's `idle`/`busy`/`needs_input` state machine (see
/// `ghoztty-activity-state.sh`, which is the single owner of that ordering).
pub const HookPurpose = enum {
    session_start,
    prompt_submit,
    stop,
    activity_session_start,
    activity_pause,
    activity_tool_tick,
    activity_agent_start,
    activity_agent_stop,
    activity_settle,

    /// The verb this purpose passes to its script.
    pub fn verb(self: HookPurpose) []const u8 {
        return switch (self) {
            .session_start => "session-start-hook",
            .prompt_submit => "prompt-hook",
            .stop => "stop-hook",
            .activity_session_start => "session-start",
            .activity_pause => "pause",
            .activity_tool_tick => "tool-tick",
            .activity_agent_start => "agent-start",
            .activity_agent_stop => "agent-stop",
            .activity_settle => "settle",
        };
    }

    /// Whether this purpose runs the activity-state script rather than the
    /// banner script.
    pub fn usesActivityScript(self: HookPurpose) bool {
        return switch (self) {
            .session_start, .prompt_submit, .stop => false,
            else => true,
        };
    }

    /// Full path of the script serving this purpose: the banner script
    /// itself, or its activity-state sibling (resolved via `hook_scripts`,
    /// so exactly one place knows the layout).
    pub fn scriptPath(
        self: HookPurpose,
        alloc: Allocator,
        banner_script_path: []const u8,
    ) Allocator.Error![]u8 {
        if (self.usesActivityScript())
            return hook_scripts.activityStatePath(alloc, banner_script_path);
        return alloc.dupe(u8, banner_script_path);
    }
};

/// Single-quote shell quoting: `'` becomes `'\''`, everything else is
/// literal inside the quotes. Applied to the script path in every generated
/// command.
pub fn shellQuote(alloc: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeByte('\'') catch return error.OutOfMemory;
    for (path) |c| {
        if (c == '\'') {
            w.writeAll("'\\''") catch return error.OutOfMemory;
        } else {
            w.writeByte(c) catch return error.OutOfMemory;
        }
    }
    w.writeByte('\'') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The per-event command a generated hook file runs: the shared script with
/// the event verb and the invoking runtime. No jq, no awk, no pipe — the
/// script reads the runtime's payload from stdin itself (via `ghoztty
/// +json`), so there is no per-runtime normalizer to embed and the shared
/// script is never edited to add a runtime.
pub fn perEventCommand(
    alloc: Allocator,
    purpose: HookPurpose,
    banner_script_path: []const u8,
    runtime: RuntimeAgent,
) Allocator.Error![]u8 {
    const script = try purpose.scriptPath(alloc, banner_script_path);
    defer alloc.free(script);
    const quoted = try shellQuote(alloc, script);
    defer alloc.free(quoted);
    return std.fmt.allocPrint(alloc, "bash {s} {s} --runtime={s}", .{
        quoted, purpose.verb(), @tagName(runtime),
    });
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

test "every purpose has a verb and the banner three avoid the activity script" {
    inline for (std.meta.tags(HookPurpose)) |purpose| {
        try testing.expect(purpose.verb().len > 0);
    }
    try testing.expect(!HookPurpose.session_start.usesActivityScript());
    try testing.expect(!HookPurpose.prompt_submit.usesActivityScript());
    try testing.expect(!HookPurpose.stop.usesActivityScript());
    try testing.expect(HookPurpose.activity_pause.usesActivityScript());
    try testing.expect(HookPurpose.activity_settle.usesActivityScript());
}

test "shellQuote wraps and escapes embedded single quotes" {
    const alloc = testing.allocator;
    {
        const got = try shellQuote(alloc, "/x/banner.sh");
        defer alloc.free(got);
        try testing.expectEqualStrings("'/x/banner.sh'", got);
    }
    {
        const got = try shellQuote(alloc, "/it's/here.sh");
        defer alloc.free(got);
        try testing.expectEqualStrings("'/it'\\''s/here.sh'", got);
    }
}

test "perEventCommand: banner and activity goldens, both runtimes" {
    const alloc = testing.allocator;
    {
        const got = try perEventCommand(alloc, .prompt_submit, "/x/banner.sh", .copilot);
        defer alloc.free(got);
        try testing.expectEqualStrings("bash '/x/banner.sh' prompt-hook --runtime=copilot", got);
    }
    {
        const got = try perEventCommand(alloc, .session_start, "/x/banner.sh", .claude);
        defer alloc.free(got);
        try testing.expectEqualStrings("bash '/x/banner.sh' session-start-hook --runtime=claude", got);
    }
    {
        // Activity purposes resolve the sibling script off the banner path.
        const got = try perEventCommand(
            alloc,
            .activity_pause,
            "C:/Users/u/.config/ghoztty/hooks/ghoztty-banner.sh",
            .claude,
        );
        defer alloc.free(got);
        try testing.expectEqualStrings(
            "bash 'C:/Users/u/.config/ghoztty/hooks/ghoztty-activity-state.sh' pause --runtime=claude",
            got,
        );
    }
}
