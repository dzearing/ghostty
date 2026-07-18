const std = @import("std");
const Allocator = std.mem.Allocator;

/// The `+list` response payload: the data model and its JSON serialization,
/// shape-matched to the Mac server's Swift encoder (IPCMessage.swift) — the
/// CLI's human formatter and the ghoztty skill both parse this. The golden
/// tests below pin the shape; keep them in sync with any Mac change.
pub const List = struct {
    windows: []const Window,

    /// Build provenance of the serving instance (T52). Additive and
    /// optional: the Mac server does not send it (yet), and `null` omits
    /// the field entirely, so the golden Mac shape below is unchanged.
    build: ?Build = null,

    pub const Build = struct {
        version: []const u8,
        commit: []const u8,
        mode: []const u8,
        runtime: []const u8,
        exe: []const u8,
        exe_modified: []const u8,
        pid: i64,
    };

    pub const Terminal = struct {
        id: []const u8,
        title: []const u8,
        working_directory: []const u8,
        pid: i64,
        tty: []const u8,
        /// Registered pane name; the Mac falls back to the surface id.
        name: ?[]const u8,
        focused: bool,
        /// null while the child is running.
        exit_code: ?i64,
    };

    pub const Node = union(enum) {
        leaf: Terminal,
        split: Split,

        pub const Split = struct {
            /// "horizontal" or "vertical".
            direction: []const u8,
            ratio: f64,
            left: *const Node,
            right: *const Node,
        };
    };

    pub const Tab = struct {
        id: []const u8,
        title: []const u8,
        index: i64,
        selected: bool,
        splits: *const Node,
    };

    pub const Window = struct {
        id: []const u8,
        title: []const u8,
        target: ?[]const u8,
        focused: bool,
        tabs: []const Tab,
    };

    /// A leaf for an empty tree, matching the Mac server's placeholder.
    pub const empty_terminal: Terminal = .{
        .id = "",
        .title = "",
        .working_directory = "",
        .pid = 0,
        .tty = "",
        .name = null,
        .focused = false,
        .exit_code = null,
    };

    /// Serialize the full success response:
    /// `{"success":true,"data":{"windows":[...]}}`. Caller frees.
    pub fn serializeResponse(self: List, alloc: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        var jws: std.json.Stringify = .{ .writer = &out.writer };
        write: {
            jws.beginObject() catch break :write;
            jws.objectField("success") catch break :write;
            jws.write(true) catch break :write;
            jws.objectField("data") catch break :write;
            jws.beginObject() catch break :write;
            jws.objectField("windows") catch break :write;
            jws.beginArray() catch break :write;
            for (self.windows) |w| writeWindow(&jws, w) catch break :write;
            jws.endArray() catch break :write;
            if (self.build) |b| writeBuild(&jws, b) catch break :write;
            jws.endObject() catch break :write;
            jws.endObject() catch break :write;
            return out.toOwnedSlice();
        }
        return error.OutOfMemory;
    }

    fn writeBuild(jws: *std.json.Stringify, b: Build) !void {
        try jws.objectField("build");
        try jws.beginObject();
        try jws.objectField("version");
        try jws.write(b.version);
        try jws.objectField("commit");
        try jws.write(b.commit);
        try jws.objectField("mode");
        try jws.write(b.mode);
        try jws.objectField("runtime");
        try jws.write(b.runtime);
        try jws.objectField("exe");
        try jws.write(b.exe);
        try jws.objectField("exe_modified");
        try jws.write(b.exe_modified);
        try jws.objectField("pid");
        try jws.write(b.pid);
        try jws.endObject();
    }

    fn writeWindow(jws: *std.json.Stringify, w: Window) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(w.id);
        try jws.objectField("title");
        try jws.write(w.title);
        try jws.objectField("target");
        try jws.write(w.target);
        try jws.objectField("focused");
        try jws.write(w.focused);
        try jws.objectField("tabs");
        try jws.beginArray();
        for (w.tabs) |t| try writeTab(jws, t);
        try jws.endArray();
        try jws.endObject();
    }

    fn writeTab(jws: *std.json.Stringify, t: Tab) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(t.id);
        try jws.objectField("title");
        try jws.write(t.title);
        try jws.objectField("index");
        try jws.write(t.index);
        try jws.objectField("selected");
        try jws.write(t.selected);
        try jws.objectField("splits");
        try writeNode(jws, t.splits);
        try jws.endObject();
    }

    fn writeNode(jws: *std.json.Stringify, node: *const Node) error{WriteFailed}!void {
        try jws.beginObject();
        try jws.objectField("type");
        switch (node.*) {
            .leaf => |term| {
                try jws.write("leaf");
                try jws.objectField("terminal");
                try writeTerminal(jws, term);
            },
            .split => |s| {
                try jws.write("split");
                try jws.objectField("direction");
                try jws.write(s.direction);
                try jws.objectField("ratio");
                try jws.write(s.ratio);
                try jws.objectField("left");
                try writeNode(jws, s.left);
                try jws.objectField("right");
                try writeNode(jws, s.right);
            },
        }
        try jws.endObject();
    }

    fn writeTerminal(jws: *std.json.Stringify, term: Terminal) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(term.id);
        try jws.objectField("title");
        try jws.write(term.title);
        try jws.objectField("working_directory");
        try jws.write(term.working_directory);
        try jws.objectField("pid");
        try jws.write(term.pid);
        try jws.objectField("tty");
        try jws.write(term.tty);
        try jws.objectField("name");
        try jws.write(term.name);
        try jws.objectField("focused");
        try jws.write(term.focused);
        try jws.objectField("exit_code");
        try jws.write(term.exit_code);
        try jws.endObject();
    }
};

test "List: build provenance is additive (T52)" {
    const testing = std.testing;
    const json = try (List{
        .windows = &.{},
        .build = .{
            .version = "1.2.0-main+abc1234",
            .commit = "abc1234",
            .mode = "Debug",
            .runtime = "win32",
            .exe = "C:\\g\\ghoztty.exe",
            .exe_modified = "2026-07-17 09:31:40 UTC",
            .pid = 42,
        },
    }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[]," ++
            "\"build\":{\"version\":\"1.2.0-main+abc1234\",\"commit\":\"abc1234\"," ++
            "\"mode\":\"Debug\",\"runtime\":\"win32\",\"exe\":\"C:\\\\g\\\\ghoztty.exe\"," ++
            "\"exe_modified\":\"2026-07-17 09:31:40 UTC\",\"pid\":42}}}",
        json,
    );
}

test "List: empty tree serializes like the Mac server" {
    const testing = std.testing;
    const json = try (List{ .windows = &.{} }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[]}}",
        json,
    );
}

test "List: golden shape — window with split tab" {
    const testing = std.testing;

    const left: List.Node = .{ .leaf = .{
        .id = "11",
        .title = "nvim",
        .working_directory = "C:\\src",
        .pid = 0,
        .tty = "",
        .name = "ide",
        .focused = true,
        .exit_code = null,
    } };
    const right: List.Node = .{ .leaf = .{
        .id = "12",
        .title = "pwsh",
        .working_directory = "",
        .pid = 0,
        .tty = "",
        .name = "12",
        .focused = false,
        .exit_code = null,
    } };
    const root: List.Node = .{ .split = .{
        .direction = "horizontal",
        .ratio = 0.5,
        .left = &left,
        .right = &right,
    } };
    const tabs = [_]List.Tab{.{
        .id = "0",
        .title = "nvim",
        .index = 0,
        .selected = true,
        .splits = &root,
    }};
    const windows = [_]List.Window{.{
        .id = "1",
        .title = "nvim",
        .target = "dev",
        .focused = true,
        .tabs = &tabs,
    }};

    const json = try (List{ .windows = &windows }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[" ++
            "{\"id\":\"1\",\"title\":\"nvim\",\"target\":\"dev\",\"focused\":true,\"tabs\":[" ++
            "{\"id\":\"0\",\"title\":\"nvim\",\"index\":0,\"selected\":true,\"splits\":" ++
            "{\"type\":\"split\",\"direction\":\"horizontal\",\"ratio\":0.5," ++
            "\"left\":{\"type\":\"leaf\",\"terminal\":{\"id\":\"11\",\"title\":\"nvim\"," ++
            "\"working_directory\":\"C:\\\\src\",\"pid\":0,\"tty\":\"\",\"name\":\"ide\"," ++
            "\"focused\":true,\"exit_code\":null}}," ++
            "\"right\":{\"type\":\"leaf\",\"terminal\":{\"id\":\"12\",\"title\":\"pwsh\"," ++
            "\"working_directory\":\"\",\"pid\":0,\"tty\":\"\",\"name\":\"12\"," ++
            "\"focused\":false,\"exit_code\":null}}}}]}]}}",
        json,
    );
}
