//! Inter-process Communication to a running Ghostty instance from a separate
//! process.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const lib = @import("../lib/main.zig");

pub const Errors = error{
    /// The IPC failed. If a function returns this error, it's expected that
    /// an a more specific error message will have been written to stderr (or
    /// otherwise shown to the user in an appropriate way).
    IPCFailed,

    /// No running instance was found (socket does not exist).
    NoRunningInstance,
};

/// The JSON response the IPC server sends for every request:
/// `{"success": <bool>, "error": <optional string>, ...}`. Unknown fields
/// (e.g. the `data` payload of a `+read` response) are ignored by
/// `parseResponse`.
pub const Response = struct {
    success: bool = false,
    @"error": ?[]const u8 = null,
};

/// Parse the raw JSON response body from the IPC server. On failure the
/// server includes a human-readable reason in `error` (e.g. "pane 'd1' not
/// found in registry") which callers should surface to the user instead of a
/// generic fallback. The returned `Parsed` owns the string memory; call
/// `deinit` when done.
pub fn parseResponse(
    alloc: Allocator,
    bytes: []const u8,
) error{InvalidResponse}!std.json.Parsed(Response) {
    return std.json.parseFromSlice(
        Response,
        alloc,
        bytes,
        .{ .ignore_unknown_fields = true },
    ) catch error.InvalidResponse;
}

test "parseResponse: success" {
    const testing = std.testing;
    const parsed = try parseResponse(testing.allocator, "{\"success\":true}");
    defer parsed.deinit();
    try testing.expect(parsed.value.success);
    try testing.expect(parsed.value.@"error" == null);
}

test "parseResponse: failure carries the server's error text" {
    const testing = std.testing;
    const parsed = try parseResponse(
        testing.allocator,
        "{\"success\":false,\"error\":\"pane 'd1' not found in registry\"}",
    );
    defer parsed.deinit();
    try testing.expect(!parsed.value.success);
    try testing.expectEqualStrings(
        "pane 'd1' not found in registry",
        parsed.value.@"error".?,
    );
}

test "parseResponse: unknown fields are ignored" {
    const testing = std.testing;
    const parsed = try parseResponse(
        testing.allocator,
        "{\"success\":true,\"data\":{\"text\":\"hello\"}}",
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.success);
}

test "parseResponse: invalid JSON" {
    const testing = std.testing;
    try testing.expectError(
        error.InvalidResponse,
        parseResponse(testing.allocator, "not json"),
    );
}

pub const Target = union(Key) {
    /// Open up a new window in a custom instance of Ghostty.
    class: [:0]const u8,

    /// Detect which instance to open a new window in.
    detect,

    // Sync with: ghostty_ipc_target_tag_e
    pub const Key = enum(c_int) {
        class,
        detect,

        test "ghostty.h Target.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_IPC_TARGET_");
        }
    };

    // Sync with: ghostty_ipc_target_u
    pub const CValue = extern union {
        class: [*:0]const u8,
        detect: void,
    };

    // Sync with: ghostty_ipc_target_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    /// Convert to ghostty_ipc_target_s.
    pub fn cval(self: Target) C {
        return .{
            .key = @as(Key, self),
            .value = switch (self) {
                .class => |class| .{ .class = class.ptr },
                .detect => .{ .detect = {} },
            },
        };
    }
};

pub const Action = union(enum) {
    // A GUIDE TO ADDING NEW ACTIONS:
    //
    // 1. Add the action to the `Key` enum. The order of the enum matters
    //    because it maps directly to the libghostty C enum. For ABI
    //    compatibility, new actions should be added to the end of the enum.
    //
    // 2. Add the action and optional value to the Action union.
    //
    // 3. If the value type is not void, ensure the value is C ABI
    //    compatible (extern). If it is not, add a `C` decl to the value
    //    and a `cval` function to convert to the C ABI compatible value.
    //
    // 4. Update `include/ghostty.h`: add the new key, value, and union
    //    entry. If the value type is void then only the key needs to be
    //    added. Ensure the order matches exactly with the Zig code.

    /// The arguments to pass to Ghostty as the command.
    new_window: NewWindow,

    /// Create a split in an existing window.
    split: Split,

    /// Close a named pane or window.
    close: Close,

    /// Rename a named pane or window in the target registry.
    rename: Rename,

    /// Rearrange the pane layout of a window.
    rearrange: Rearrange,

    /// Send text input to a named pane's terminal.
    send_keys: SendKeys,

    /// Set the activity state of a named pane or window.
    set_state: SetState,

    pub const NewWindow = struct {
        /// A list of command arguments to launch in the new window. If this is
        /// `null` the command configured in the config or the user's default
        /// shell should be launched.
        ///
        /// It is an error for this to be non-`null`, but zero length.
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            /// null terminated list of arguments
            /// it will be null itself if there are no arguments
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *NewWindow.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *NewWindow, alloc: Allocator) Allocator.Error!NewWindow.C {
            var result: NewWindow.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                // add null terminator
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const Split = struct {
        /// A list of command arguments to launch in the split. If this is
        /// `null` the command configured in the config or the user's default
        /// shell should be launched.
        ///
        /// It is an error for this to be non-`null`, but zero length.
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            /// null terminated list of arguments
            /// it will be null itself if there are no arguments
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Split.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Split, alloc: Allocator) Allocator.Error!Split.C {
            var result: Split.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                // add null terminator
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const Close = struct {
        /// A list of command arguments to pass to the close action. If this is
        /// `null` no additional arguments are sent.
        ///
        /// It is an error for this to be non-`null`, but zero length.
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            /// null terminated list of arguments
            /// it will be null itself if there are no arguments
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Close.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Close, alloc: Allocator) Allocator.Error!Close.C {
            var result: Close.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                // add null terminator
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const Rename = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Rename.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Rename, alloc: Allocator) Allocator.Error!Rename.C {
            var result: Rename.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const Rearrange = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Rearrange.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Rearrange, alloc: Allocator) Allocator.Error!Rearrange.C {
            var result: Rearrange.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const SendKeys = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *SendKeys.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *SendKeys, alloc: Allocator) Allocator.Error!SendKeys.C {
            var result: SendKeys.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const SetState = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *SetState.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *SetState, alloc: Allocator) Allocator.Error!SetState.C {
            var result: SetState.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    /// Sync with: ghostty_ipc_action_tag_e
    pub const Key = enum(c_int) {
        new_window,
        split,
        close,
        rename,
        rearrange,
        send_keys,
        set_state,

        /// The wire name of this action: the `action` field of the IPC JSON
        /// request (and the CLI `+<verb>` spelling).
        pub fn wireName(self: Key) [:0]const u8 {
            return switch (self) {
                .new_window => "new-window",
                .split => "split",
                .close => "close",
                .rename => "rename",
                .rearrange => "rearrange",
                .send_keys => "send-keys",
                .set_state => "set-state",
            };
        }

        test "ghostty.h Action.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_IPC_ACTION_");
        }
    };

    /// Sync with: ghostty_ipc_action_u
    pub const CValue = cvalue: {
        const key_fields = @typeInfo(Key).@"enum".fields;
        var union_fields: [key_fields.len]std.builtin.Type.UnionField = undefined;
        for (key_fields, 0..) |field, i| {
            const action = @unionInit(Action, field.name, undefined);
            const Type = t: {
                const Type = @TypeOf(@field(action, field.name));
                // Types can provide custom types for their CValue.
                if (Type != void and @hasDecl(Type, "C")) break :t Type.C;
                break :t Type;
            };

            union_fields[i] = .{
                .name = field.name,
                .type = Type,
                .alignment = @alignOf(Type),
            };
        }

        break :cvalue @Type(.{ .@"union" = .{
            .layout = .@"extern",
            .tag_type = null,
            .fields = &union_fields,
            .decls = &.{},
        } });
    };

    /// Sync with: ghostty_ipc_action_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    comptime {
        // For ABI compatibility, we expect that this is our union size.
        // At the time of writing, we don't promise ABI compatibility
        // so we can change this but I want to be aware of it.
        assert(@sizeOf(CValue) == switch (@sizeOf(usize)) {
            4 => 4,
            8 => 8,
            else => unreachable,
        });
    }

    /// Returns the value type for the given key.
    pub fn Value(comptime key: Key) type {
        inline for (@typeInfo(Action).@"union".fields) |field| {
            const field_key = @field(Key, field.name);
            if (field_key == key) return field.type;
        }

        unreachable;
    }

    /// Convert to ghostty_ipc_action_s.
    pub fn cval(self: Action, alloc: Allocator) C {
        const value: CValue = switch (self) {
            inline else => |v, tag| @unionInit(
                CValue,
                @tagName(tag),
                if (@TypeOf(v) != void and @hasDecl(@TypeOf(v), "cval")) v.cval(alloc) else v,
            ),
        };

        return .{
            .key = @as(Key, self),
            .value = value,
        };
    }
};
