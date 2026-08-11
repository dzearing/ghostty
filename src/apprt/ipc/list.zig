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
        /// Whether this build checks the win-v update channel (T24).
        update_check: bool = false,
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
        /// Pane kind: `"terminal"` or `"viewer"` (JSON key `"type"`). The Mac
        /// server encodes this unconditionally (`IPCMessage.swift:103`), so it
        /// is emitted for terminals too and the default keeps every existing
        /// caller correct. `src/cli/list.zig` already reads it to pick the
        /// `view:` prefix — the gap this closes was server-side only.
        pane_type: []const u8 = "terminal",
        /// The viewed file path or URL; terminals report null, which the Mac
        /// server also encodes rather than omitting (`IPCMessage.swift:104`).
        url: ?[]const u8 = null,
        /// Background tint as `#rrggbb` (T67). Additive and optional like
        /// `build`: null omits the field, so the golden Mac shape below is
        /// unchanged for untinted panes (the Mac server never sends it).
        background_tint: ?[]const u8 = null,
        /// Sticky pane-banner source (T35). Additive and optional like
        /// `background_tint`: null omits the field, keeping the golden Mac
        /// shape unchanged for bannerless panes.
        banner: ?[]const u8 = null,
        /// The session-persistence agent session this pane is bound to
        /// (T332): the join key against `+sessions --json`. Absent for a
        /// plain local ConPTY pane and for viewers; present for local-agent
        /// and cross-machine panes alike. Additive and optional like
        /// `banner`: null omits the field.
        session_id: ?[]const u8 = null,
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

    /// A rectangle in the window's CLIENT coordinates, physical pixels,
    /// right/bottom exclusive — the same convention the win32 chrome's own
    /// geometry modules use, so a published region is the rect the app hit
    /// tests and nothing has to be re-expressed on the way out.
    pub const Rect = struct {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    };

    /// Where the tab strip's clickable regions ARE (T231), so a caller —
    /// today an acceptance script, tomorrow anything that wants to point at a
    /// tab — can ask the product instead of re-deriving `tab_strip_layout`'s
    /// arithmetic in another language. A second implementation of a layout
    /// cannot be type-checked against the first, and the harness's copy had
    /// already rotted twice (a fixed "46px from the right edge" that landed
    /// inside the menu button at 125% DPI, then a modelled tab width that
    /// stopped matching when T235 sized tabs to their titles).
    ///
    /// Every rect is the HIT box the app tests, not the painted square: this
    /// answers "where do I click", and the painted square is that box deflated
    /// by the shared `icon_button` hit padding.
    ///
    /// **`null` means there is nothing there to hit** — a `menu` on a window
    /// whose caption hosts the menu (T260), a tab the strip could not fit, and
    /// every region of a strip that has not painted yet. That is the same
    /// answer the hit tests give, which is the point.
    pub const TabStrip = struct {
        /// The band the strip's content occupies: inside both insets, and the
        /// buttons' own vertical band rather than the full bar. On a merged
        /// caption row (T205) its right edge is the seam, not the window edge.
        band: Rect,
        /// One entry per tab, in `tabs` order.
        tabs: []const ?Rect,
        new_tab: ?Rect,
        menu: ?Rect,
    };

    /// The window's chrome, as the app resolved it (T231). Additive and
    /// optional: absent from a server that does not report it, which is how a
    /// caller tells "this build cannot say" from "this window has no strip"
    /// (`tab_strip: null`).
    pub const Chrome = struct {
        /// The window's DPI, as the APP believes it — the number every DIP
        /// constant below was resolved with, which is not always what
        /// `GetDpiForWindow` answers at the instant a caller asks.
        dpi: i64,
        tab_strip: ?TabStrip = null,
    };

    pub const Window = struct {
        id: []const u8,
        title: []const u8,
        target: ?[]const u8,
        focused: bool,
        tabs: []const Tab,
        /// T231. Windows-only for now (the Mac half is filed); null omits the
        /// field entirely, so the golden Mac shape below is unchanged.
        chrome: ?Chrome = null,
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
        try jws.objectField("update_check");
        try jws.write(b.update_check);
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
        if (w.chrome) |c| try writeChrome(jws, c);
        try jws.endObject();
    }

    fn writeRect(jws: *std.json.Stringify, r: ?Rect) !void {
        const rect = r orelse return jws.write(null);
        try jws.beginObject();
        try jws.objectField("left");
        try jws.write(rect.left);
        try jws.objectField("top");
        try jws.write(rect.top);
        try jws.objectField("right");
        try jws.write(rect.right);
        try jws.objectField("bottom");
        try jws.write(rect.bottom);
        try jws.endObject();
    }

    fn writeChrome(jws: *std.json.Stringify, c: Chrome) !void {
        try jws.objectField("chrome");
        try jws.beginObject();
        try jws.objectField("dpi");
        try jws.write(c.dpi);
        try jws.objectField("tab_strip");
        if (c.tab_strip) |s| {
            try jws.beginObject();
            try jws.objectField("band");
            try writeRect(jws, s.band);
            try jws.objectField("tabs");
            try jws.beginArray();
            for (s.tabs) |t| try writeRect(jws, t);
            try jws.endArray();
            try jws.objectField("new_tab");
            try writeRect(jws, s.new_tab);
            try jws.objectField("menu");
            try writeRect(jws, s.menu);
            try jws.endObject();
        } else {
            try jws.write(null);
        }
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
        // Mac's field order, and unconditional like Mac's encoder: `type` and
        // `url` sit between `exit_code` and `banner`. The Windows-only
        // `background_tint` keeps its place immediately before `banner`.
        try jws.objectField("type");
        try jws.write(term.pane_type);
        try jws.objectField("url");
        try jws.write(term.url);
        if (term.background_tint) |tint| {
            try jws.objectField("background_tint");
            try jws.write(tint);
        }
        if (term.banner) |banner| {
            try jws.objectField("banner");
            try jws.write(banner);
        }
        if (term.session_id) |sid| {
            try jws.objectField("session_id");
            try jws.write(sid);
        }
        try jws.endObject();
    }
};

test "List: banner is additive (T35)" {
    const testing = std.testing;

    const bannered: List.Node = .{ .leaf = .{
        .id = "11",
        .title = "pwsh",
        .working_directory = "",
        .pid = 0,
        .tty = "",
        .name = "11",
        .focused = true,
        .exit_code = null,
        .banner = "**PR #1**\nline2",
    } };
    const tabs = [_]List.Tab{.{
        .id = "0",
        .title = "pwsh",
        .index = 0,
        .selected = true,
        .splits = &bannered,
    }};
    const windows = [_]List.Window{.{
        .id = "1",
        .title = "pwsh",
        .target = null,
        .focused = true,
        .tabs = &tabs,
    }};

    const json = try (List{ .windows = &windows }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[" ++
            "{\"id\":\"1\",\"title\":\"pwsh\",\"target\":null,\"focused\":true,\"tabs\":[" ++
            "{\"id\":\"0\",\"title\":\"pwsh\",\"index\":0,\"selected\":true,\"splits\":" ++
            "{\"type\":\"leaf\",\"terminal\":{\"id\":\"11\",\"title\":\"pwsh\"," ++
            "\"working_directory\":\"\",\"pid\":0,\"tty\":\"\",\"name\":\"11\"," ++
            "\"focused\":true,\"exit_code\":null,\"type\":\"terminal\",\"url\":null," ++
            "\"banner\":\"**PR #1**\\nline2\"}}}]}]}}",
        json,
    );
}

test "List: build provenance is additive (T52)" {
    const testing = std.testing;
    const json = try (List{
        .windows = &.{},
        .build = .{
            .version = "1.2.0-main+abc1234",
            .commit = "abc1234",
            .mode = "Debug",
            .runtime = "win32",
            .update_check = true,
            .exe = "C:\\g\\ghoztty.exe",
            .exe_modified = "2026-07-17 09:31:40 UTC",
            .pid = 42,
        },
    }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[]," ++
            "\"build\":{\"version\":\"1.2.0-main+abc1234\",\"commit\":\"abc1234\"," ++
            "\"mode\":\"Debug\",\"runtime\":\"win32\",\"update_check\":true," ++
            "\"exe\":\"C:\\\\g\\\\ghoztty.exe\"," ++
            "\"exe_modified\":\"2026-07-17 09:31:40 UTC\",\"pid\":42}}}",
        json,
    );
}

test "List: session_id is additive (T332)" {
    const testing = std.testing;

    const bound: List.Node = .{ .leaf = .{
        .id = "3F2A", // pane id (uuid in practice)
        .title = "pwsh",
        .working_directory = "",
        .pid = 0,
        .tty = "",
        .name = "3F2A",
        .focused = true,
        .exit_code = null,
        .session_id = "sess-0a1b2c3d",
    } };
    const tabs = [_]List.Tab{.{
        .id = "0",
        .title = "pwsh",
        .index = 0,
        .selected = true,
        .splits = &bound,
    }};
    const windows = [_]List.Window{.{
        .id = "1",
        .title = "pwsh",
        .target = null,
        .focused = true,
        .tabs = &tabs,
    }};

    const json = try (List{ .windows = &windows }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[" ++
            "{\"id\":\"1\",\"title\":\"pwsh\",\"target\":null,\"focused\":true,\"tabs\":[" ++
            "{\"id\":\"0\",\"title\":\"pwsh\",\"index\":0,\"selected\":true,\"splits\":" ++
            "{\"type\":\"leaf\",\"terminal\":{\"id\":\"3F2A\",\"title\":\"pwsh\"," ++
            "\"working_directory\":\"\",\"pid\":0,\"tty\":\"\",\"name\":\"3F2A\"," ++
            "\"focused\":true,\"exit_code\":null,\"type\":\"terminal\",\"url\":null," ++
            "\"session_id\":\"sess-0a1b2c3d\"}}}]}]}}",
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

test "List: background_tint is additive (T67)" {
    const testing = std.testing;

    const tinted: List.Node = .{ .leaf = .{
        .id = "11",
        .title = "pwsh",
        .working_directory = "",
        .pid = 0,
        .tty = "",
        .name = "11",
        .focused = true,
        .exit_code = null,
        .background_tint = "#334455",
    } };
    const tabs = [_]List.Tab{.{
        .id = "0",
        .title = "pwsh",
        .index = 0,
        .selected = true,
        .splits = &tinted,
    }};
    const windows = [_]List.Window{.{
        .id = "1",
        .title = "pwsh",
        .target = null,
        .focused = true,
        .tabs = &tabs,
    }};

    const json = try (List{ .windows = &windows }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[" ++
            "{\"id\":\"1\",\"title\":\"pwsh\",\"target\":null,\"focused\":true,\"tabs\":[" ++
            "{\"id\":\"0\",\"title\":\"pwsh\",\"index\":0,\"selected\":true,\"splits\":" ++
            "{\"type\":\"leaf\",\"terminal\":{\"id\":\"11\",\"title\":\"pwsh\"," ++
            "\"working_directory\":\"\",\"pid\":0,\"tty\":\"\",\"name\":\"11\"," ++
            "\"focused\":true,\"exit_code\":null,\"type\":\"terminal\",\"url\":null," ++
            "\"background_tint\":\"#334455\"}}}]}]}}",
        json,
    );
}

test "List: viewer leaf reports type/url (T90b)" {
    const testing = std.testing;

    // No win32 pane can produce this yet (viewers land in T90c–T90h), but the
    // wire shape is what `src/cli/list.zig` already renders as `view: <title>
    // <url>`, so it is pinned here rather than discovered later.
    const viewer: List.Node = .{ .leaf = .{
        .id = "11",
        .title = "README.md",
        .working_directory = "",
        .pid = 0,
        .tty = "",
        .name = "doc",
        .focused = true,
        .exit_code = null,
        .pane_type = "viewer",
        .url = "D:\\git\\ghoztty\\README.md",
    } };
    const tabs = [_]List.Tab{.{
        .id = "0",
        .title = "README.md",
        .index = 0,
        .selected = true,
        .splits = &viewer,
    }};
    const windows = [_]List.Window{.{
        .id = "1",
        .title = "README.md",
        .target = null,
        .focused = true,
        .tabs = &tabs,
    }};

    const json = try (List{ .windows = &windows }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[" ++
            "{\"id\":\"1\",\"title\":\"README.md\",\"target\":null,\"focused\":true,\"tabs\":[" ++
            "{\"id\":\"0\",\"title\":\"README.md\",\"index\":0,\"selected\":true,\"splits\":" ++
            "{\"type\":\"leaf\",\"terminal\":{\"id\":\"11\",\"title\":\"README.md\"," ++
            "\"working_directory\":\"\",\"pid\":0,\"tty\":\"\",\"name\":\"doc\"," ++
            "\"focused\":true,\"exit_code\":null,\"type\":\"viewer\"," ++
            "\"url\":\"D:\\\\git\\\\ghoztty\\\\README.md\"}}}]}]}}",
        json,
    );
}

test "List: chrome regions are additive (T231)" {
    const testing = std.testing;

    const leaf: List.Node = .{ .leaf = .{
        .id = "11",
        .title = "pwsh",
        .working_directory = "",
        .pid = 0,
        .tty = "",
        .name = "11",
        .focused = true,
        .exit_code = null,
    } };
    const tabs = [_]List.Tab{.{
        .id = "0",
        .title = "pwsh",
        .index = 0,
        .selected = true,
        .splits = &leaf,
    }};
    // Two tabs' worth of rects with the second one absent — a tab the strip
    // could not fit — beside a menu-less strip (T260). Both nulls are the
    // shape a consumer keys "there is nothing to hit" off.
    const tab_rects = [_]?List.Rect{
        .{ .left = 4, .top = 4, .right = 200, .bottom = 40 },
        null,
    };
    const windows = [_]List.Window{.{
        .id = "1",
        .title = "pwsh",
        .target = null,
        .focused = true,
        .tabs = &tabs,
        .chrome = .{
            .dpi = 120,
            .tab_strip = .{
                .band = .{ .left = 4, .top = 4, .right = 1396, .bottom = 40 },
                .tabs = &tab_rects,
                .new_tab = .{ .left = 206, .top = 4, .right = 244, .bottom = 40 },
                .menu = null,
            },
        },
    }};

    const json = try (List{ .windows = &windows }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[" ++
            "{\"id\":\"1\",\"title\":\"pwsh\",\"target\":null,\"focused\":true,\"tabs\":[" ++
            "{\"id\":\"0\",\"title\":\"pwsh\",\"index\":0,\"selected\":true,\"splits\":" ++
            "{\"type\":\"leaf\",\"terminal\":{\"id\":\"11\",\"title\":\"pwsh\"," ++
            "\"working_directory\":\"\",\"pid\":0,\"tty\":\"\",\"name\":\"11\"," ++
            "\"focused\":true,\"exit_code\":null,\"type\":\"terminal\",\"url\":null}}}]," ++
            "\"chrome\":{\"dpi\":120,\"tab_strip\":{" ++
            "\"band\":{\"left\":4,\"top\":4,\"right\":1396,\"bottom\":40}," ++
            "\"tabs\":[{\"left\":4,\"top\":4,\"right\":200,\"bottom\":40},null]," ++
            "\"new_tab\":{\"left\":206,\"top\":4,\"right\":244,\"bottom\":40}," ++
            "\"menu\":null}}}]}}",
        json,
    );
}

test "List: a window with no tab strip reports chrome with a null tab_strip (T231)" {
    // The tri-state a consumer needs: no `chrome` key at all means the server
    // cannot say (the Mac, or a build older than T231); `tab_strip: null`
    // means this window is showing no strip. Collapsing those two would make
    // an un-upgraded server look like a window with no tabs.
    const testing = std.testing;
    const windows = [_]List.Window{.{
        .id = "1",
        .title = "pwsh",
        .target = null,
        .focused = true,
        .tabs = &.{},
        .chrome = .{ .dpi = 96 },
    }};
    const json = try (List{ .windows = &windows }).serializeResponse(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"windows\":[" ++
            "{\"id\":\"1\",\"title\":\"pwsh\",\"target\":null,\"focused\":true," ++
            "\"tabs\":[],\"chrome\":{\"dpi\":96,\"tab_strip\":null}}]}}",
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
            "\"focused\":true,\"exit_code\":null,\"type\":\"terminal\",\"url\":null}}," ++
            "\"right\":{\"type\":\"leaf\",\"terminal\":{\"id\":\"12\",\"title\":\"pwsh\"," ++
            "\"working_directory\":\"\",\"pid\":0,\"tty\":\"\",\"name\":\"12\"," ++
            "\"focused\":false,\"exit_code\":null,\"type\":\"terminal\",\"url\":null}}}}]}]}}",
        json,
    );
}
