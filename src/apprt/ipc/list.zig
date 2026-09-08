const std = @import("std");
const Allocator = std.mem.Allocator;

/// The `+list` response payload: the data model and its JSON serialization,
/// shape-matched to the Mac server's Swift encoder (IPCMessage.swift) — the
/// CLI's human formatter and the ghoztty skill both parse this. The golden
/// tests below pin the shape, and the drift detector at the bottom of this
/// file checks it against the Swift encoder's own source on every test run
/// (T370), so a field added on either seat and not the other is a red lane
/// rather than a field a client silently never sees.
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
        /// Whether the pane is in read-only mode (T574): the machine-readable
        /// half of the badge T445 paints, so an automation that finds
        /// `+send-keys` silently swallowed can ASK why instead of guessing.
        /// Additive and optional on both servers — null (the off state, and
        /// every viewer pane) omits the field, so an older client sees the
        /// shape it always saw.
        readonly: ?bool = null,
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

    /// A cross-machine window's link health, as its reconnect ladder holds it
    /// (T609). This is the ONE thing about a remote window that a caller could
    /// previously learn only by grepping the app log — a side effect of the
    /// implementation rather than a contract, which moves whenever a message is
    /// reworded.
    ///
    /// The shape mirrors the ladder's own state rather than flattening it: a
    /// field that is meaningless in a state is ABSENT in that state, the way
    /// `banner` and `session_id` are absent rather than empty. So `attempt` is
    /// present only while retrying, and `self_healable` only while down.
    pub const Connection = struct {
        /// `"connected"` | `"reconnecting"` | `"disconnected"`.
        state: []const u8,
        /// 1-based fast-ladder attempt; only while `state == "reconnecting"`.
        attempt: ?i64 = null,
        /// Only while `state == "disconnected"`: true when the fast ladder is
        /// spent but a slow background re-dial is still armed (the link may yet
        /// come back on its own), false for a terminal verdict that needs the
        /// user.
        self_healable: ?bool = null,
        /// Only when the disconnection has a reason worth naming (T628):
        /// `"incompatible"` when the far agent answered and disagrees about the
        /// protocol version, which is a machine that is UP and a link that no
        /// retry can restore. Absent for an ordinary drop, so a script reading
        /// for the unusual case does not have to filter the usual one.
        reason: ?[]const u8 = null,
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
        /// T609. Present only for a cross-machine window — a local window has
        /// no link to report on, and absence is what already distinguishes the
        /// two. Additive: null omits the field, so every existing consumer and
        /// the golden Mac shape below are unchanged.
        connection: ?Connection = null,
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
        if (w.connection) |c| try writeConnection(jws, c);
        try jws.endObject();
    }

    fn writeConnection(jws: *std.json.Stringify, c: Connection) !void {
        try jws.objectField("connection");
        try jws.beginObject();
        try jws.objectField("state");
        try jws.write(c.state);
        if (c.attempt) |a| {
            try jws.objectField("attempt");
            try jws.write(a);
        }
        if (c.self_healable) |h| {
            try jws.objectField("self_healable");
            try jws.write(h);
        }
        if (c.reason) |r| {
            try jws.objectField("reason");
            try jws.write(r);
        }
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
        if (term.readonly) |ro| {
            try jws.objectField("readonly");
            try jws.write(ro);
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

test "List: readonly is additive (T574)" {
    const testing = std.testing;

    // A pane with read-only ON carries the flag; the same pane with it OFF
    // must serialize byte-for-byte the way it did before the field existed,
    // which is the whole promise an additive field makes to older clients.
    const base: List.Terminal = .{
        .id = "11",
        .title = "pwsh",
        .working_directory = "",
        .pid = 0,
        .tty = "",
        .name = "11",
        .focused = true,
        .exit_code = null,
    };

    const prefix = "{\"success\":true,\"data\":{\"windows\":[" ++
        "{\"id\":\"1\",\"title\":\"pwsh\",\"target\":null,\"focused\":true,\"tabs\":[" ++
        "{\"id\":\"0\",\"title\":\"pwsh\",\"index\":0,\"selected\":true,\"splits\":" ++
        "{\"type\":\"leaf\",\"terminal\":{\"id\":\"11\",\"title\":\"pwsh\"," ++
        "\"working_directory\":\"\",\"pid\":0,\"tty\":\"\",\"name\":\"11\"," ++
        "\"focused\":true,\"exit_code\":null,\"type\":\"terminal\",\"url\":null";
    const suffix = "}}}]}]}}";

    for ([_]struct { ro: ?bool, want: []const u8 }{
        .{ .ro = true, .want = prefix ++ ",\"readonly\":true" ++ suffix },
        .{ .ro = false, .want = prefix ++ ",\"readonly\":false" ++ suffix },
        .{ .ro = null, .want = prefix ++ suffix },
    }) |case| {
        var term = base;
        term.readonly = case.ro;
        const leaf: List.Node = .{ .leaf = term };
        const tabs = [_]List.Tab{.{
            .id = "0",
            .title = "pwsh",
            .index = 0,
            .selected = true,
            .splits = &leaf,
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
        try testing.expectEqualStrings(case.want, json);
    }
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

test "List: connection is additive and absent for a local window (T609)" {
    const testing = std.testing;

    const leaf: List.Node = .{ .leaf = List.empty_terminal };
    const tabs = [_]List.Tab{.{
        .id = "0",
        .title = "pwsh",
        .index = 0,
        .selected = true,
        .splits = &leaf,
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

    // A local window carries no `connection` key at all — absence is what
    // distinguishes it, exactly as for `chrome` and `banner`.
    try testing.expect(std.mem.indexOf(u8, json, "connection") == null);
}

test "List: connection reports the ladder's three states (T609)" {
    const testing = std.testing;

    const leaf: List.Node = .{ .leaf = List.empty_terminal };
    const tabs = [_]List.Tab{.{
        .id = "0",
        .title = "pwsh",
        .index = 0,
        .selected = true,
        .splits = &leaf,
    }};

    const cases = [_]struct { conn: List.Connection, want: []const u8 }{
        .{
            .conn = .{ .state = "connected" },
            .want = "\"connection\":{\"state\":\"connected\"}",
        },
        .{
            .conn = .{ .state = "reconnecting", .attempt = 2 },
            .want = "\"connection\":{\"state\":\"reconnecting\",\"attempt\":2}",
        },
        .{
            .conn = .{ .state = "disconnected", .self_healable = true },
            .want = "\"connection\":{\"state\":\"disconnected\",\"self_healable\":true}",
        },
        .{
            .conn = .{ .state = "disconnected", .self_healable = false },
            .want = "\"connection\":{\"state\":\"disconnected\",\"self_healable\":false}",
        },
        .{
            .conn = .{ .state = "disconnected", .self_healable = false, .reason = "incompatible" },
            .want = "\"connection\":{\"state\":\"disconnected\",\"self_healable\":false,\"reason\":\"incompatible\"}",
        },
    };

    for (cases) |c| {
        const windows = [_]List.Window{.{
            .id = "1",
            .title = "pwsh",
            .target = "box",
            .focused = true,
            .tabs = &tabs,
            .connection = c.conn,
        }};
        const json = try (List{ .windows = &windows }).serializeResponse(testing.allocator);
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, c.want) != null);
        // The field a state does not carry is omitted, never emitted empty.
        if (c.conn.attempt == null)
            try testing.expect(std.mem.indexOf(u8, json, "attempt") == null);
        if (c.conn.self_healable == null)
            try testing.expect(std.mem.indexOf(u8, json, "self_healable") == null);
        if (c.conn.reason == null)
            try testing.expect(std.mem.indexOf(u8, json, "reason") == null);
    }
}

// ---------------------------------------------------------------------------
// T370 — the drift detector between this encoder and the Mac server's.
//
// `+list --json` has TWO encoders that must produce byte-identical JSON: the
// one above, and `macos/Sources/Features/IPC/IPCMessage.swift`. One client
// reads both. Until this check existed the only thing keeping them together
// was a comment asking whoever touched one to remember the other, and it had
// already been missed — Mac encoded `type` and `url` for months while the Zig
// side emitted neither, and four golden tests asserted the drifted shape as
// correct. Drift is silent in both directions: the win32 lane never compiles
// Swift, and the Mac build never runs this file's tests as a shape check.
//
// So the check reads the Swift ENCODER'S OWN SOURCE, which is checked in and
// therefore reachable from either seat, and compares the field names and
// order it would emit against the field names and order this encoder actually
// emits — read off a real `serializeResponse` call rather than a second
// description of it. Win32-only fields are named explicitly, and naming one
// asserts the Mac does NOT emit it, so the exemption cannot quietly hide the
// day Mac grows the same field.

/// One JSON key the Swift encoder emits, in encode order.
const SwiftKey = struct {
    name: []const u8,
    /// `encodeIfPresent`: the key vanishes when the value is nil. Anything
    /// else is written even when nil, as an explicit `null`.
    conditional: bool,
};

/// A `CodingKeys` entry: the Swift property name and the JSON key it maps to
/// (`case pane_type = "type"`).
const SwiftAlias = struct { name: []const u8, raw: []const u8 };

/// Swift source with `//` comments removed, so a doc comment cannot
/// contribute a brace, a quote, or one of the words scanned for below.
/// Caller frees.
fn swiftStripComments(alloc: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    var in_string = false;
    while (i < src.len) {
        const c = src[i];
        if (in_string) {
            if (c == '\\' and i + 1 < src.len) {
                try out.appendSlice(alloc, src[i .. i + 2]);
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// The brace-balanced body that follows `decl` — `struct TerminalData`,
/// `enum CodingKeys`, `func encode(to encoder: Encoder)`. Null when the
/// declaration is not there, which is how a rename shows up as a failure
/// instead of a vacuous pass.
fn swiftBlock(src: []const u8, decl: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, src, decl) orelse return null;
    var i = at + decl.len;
    while (i < src.len and src[i] != '{') : (i += 1) {}
    if (i >= src.len) return null;

    const start = i + 1;
    var depth: usize = 1;
    var in_string = false;
    i = start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return src[start..i];
            },
            else => {},
        }
    }
    return null;
}

/// The `CodingKeys` map inside a type body, empty when it has none.
fn swiftCodingKeys(alloc: Allocator, body: []const u8) ![]SwiftAlias {
    var out: std.ArrayList(SwiftAlias) = .empty;
    errdefer out.deinit(alloc);

    const block = swiftBlock(body, "enum CodingKeys") orelse
        return out.toOwnedSlice(alloc);

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "case ")) continue;
        var items = std.mem.splitScalar(u8, trimmed["case ".len..], ',');
        while (items.next()) |item| {
            const entry = std.mem.trim(u8, item, " \t\r");
            if (entry.len == 0) continue;
            if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                try out.append(alloc, .{
                    .name = std.mem.trim(u8, entry[0..eq], " \t"),
                    .raw = std.mem.trim(u8, entry[eq + 1 ..], " \t\""),
                });
            } else {
                try out.append(alloc, .{ .name = entry, .raw = entry });
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

fn swiftResolve(aliases: []const SwiftAlias, name: []const u8) []const u8 {
    for (aliases) |a| if (std.mem.eql(u8, a.name, name)) return a.raw;
    return name;
}

/// The JSON keys `decl` encodes, in encode order. Handles both shapes this
/// file uses: an explicit `encode(to:)` body, and a plain `Encodable` struct
/// whose synthesized encoding follows declaration order. Caller frees.
fn swiftEncodedKeys(alloc: Allocator, src: []const u8, decl: []const u8) ![]SwiftKey {
    const body = swiftBlock(src, decl) orelse {
        std.debug.print("T370: '{s}' is not in the Mac encoder any more\n", .{decl});
        return error.SwiftDeclNotFound;
    };
    const aliases = try swiftCodingKeys(alloc, body);
    defer alloc.free(aliases);

    var out: std.ArrayList(SwiftKey) = .empty;
    errdefer out.deinit(alloc);

    if (swiftBlock(body, "func encode(to encoder: Encoder)")) |enc| {
        const marker = "container.encode";
        const for_key = "forKey: .";
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, enc, i, marker)) |at| {
            const conditional = std.mem.startsWith(u8, enc[at..], "container.encodeIfPresent");
            const key_at = std.mem.indexOfPos(u8, enc, at, for_key) orelse {
                std.debug.print("T370: no 'forKey:' after an encode call in {s}\n", .{decl});
                return error.SwiftKeyNotFound;
            };
            var end = key_at + for_key.len;
            while (end < enc.len and (std.ascii.isAlphanumeric(enc[end]) or enc[end] == '_')) end += 1;
            try out.append(alloc, .{
                .name = swiftResolve(aliases, enc[key_at + for_key.len .. end]),
                .conditional = conditional,
            });
            i = end;
        }
    } else {
        // Synthesized `Encodable`: declaration order, every field written
        // even when nil.
        var depth: usize = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const at_top = depth == 0;
            for (trimmed) |c| switch (c) {
                '{' => depth += 1,
                '}' => depth -|= 1,
                else => {},
            };
            if (!at_top) continue;
            if (!std.mem.startsWith(u8, trimmed, "let ") and
                !std.mem.startsWith(u8, trimmed, "var ")) continue;
            const rest = trimmed[4..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            try out.append(alloc, .{
                .name = swiftResolve(aliases, std.mem.trim(u8, rest[0..colon], " \t")),
                .conditional = false,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Assert this encoder's key order for `decl` matches the Mac encoder's, once
/// the deliberately win32-only keys are set aside.
fn expectMacShape(
    alloc: Allocator,
    swift: []const u8,
    decl: []const u8,
    zig_keys: []const []const u8,
    win32_only: []const []const u8,
) !void {
    const mac = try swiftEncodedKeys(alloc, swift, decl);
    defer alloc.free(mac);

    // Calling a key win32-only ASSERTS the Mac does not emit it. The day Mac
    // grows the same field, the exemption is what has to go.
    for (win32_only) |extra| {
        for (mac) |k| {
            if (!std.mem.eql(u8, k.name, extra)) continue;
            std.debug.print(
                "T370 {s}: '{s}' is no longer win32-only — the Mac encoder emits it; " ++
                    "drop it from the exemption list and match Mac's position\n",
                .{ decl, extra },
            );
            return error.MacShapeDrift;
        }
    }

    var i: usize = 0;
    for (zig_keys) |zk| {
        var exempt = false;
        for (win32_only) |extra| {
            if (std.mem.eql(u8, zk, extra)) exempt = true;
        }
        if (exempt) continue;
        if (i >= mac.len) {
            std.debug.print(
                "T370 {s}: this encoder emits '{s}', the Mac encoder does not\n",
                .{ decl, zk },
            );
            return error.MacShapeDrift;
        }
        if (!std.mem.eql(u8, zk, mac[i].name)) {
            std.debug.print(
                "T370 {s}: field {d} is '{s}' here and '{s}' on Mac\n",
                .{ decl, i, zk, mac[i].name },
            );
            return error.MacShapeDrift;
        }
        i += 1;
    }
    if (i != mac.len) {
        std.debug.print(
            "T370 {s}: the Mac encoder emits '{s}', this encoder does not\n",
            .{ decl, mac[i].name },
        );
        return error.MacShapeDrift;
    }
}

test "List: the JSON shape still matches the Mac Swift encoder (T370)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const swift = try swiftStripComments(alloc, @embedFile("macos_ipc_message_swift"));
    defer alloc.free(swift);

    // Every optional populated, so this encoder emits every key it knows how
    // to emit and the order can be read straight off the wire.
    const leaf_left: List.Node = .{ .leaf = .{
        .id = "11",
        .title = "viewer",
        .working_directory = "/home",
        .pid = 7,
        .tty = "conpty",
        .name = "left",
        .focused = true,
        .exit_code = 0,
        .pane_type = "viewer",
        .url = "file:///x.md",
        .background_tint = "#112233",
        .banner = "**PR #1**",
        .readonly = true,
        .session_id = "s1",
    } };
    const leaf_right: List.Node = .{ .leaf = List.empty_terminal };
    const split: List.Node = .{ .split = .{
        .direction = "horizontal",
        .ratio = 0.5,
        .left = &leaf_left,
        .right = &leaf_right,
    } };
    const tabs = [_]List.Tab{.{
        .id = "0",
        .title = "pwsh",
        .index = 0,
        .selected = true,
        .splits = &split,
    }};
    const windows = [_]List.Window{.{
        .id = "1",
        .title = "pwsh",
        .target = "box",
        .focused = true,
        .tabs = &tabs,
        .chrome = .{ .dpi = 96 },
        .connection = .{ .state = "connected" },
    }};
    const json = try (List{
        .windows = &windows,
        .build = .{
            .version = "v",
            .commit = "c",
            .mode = "Debug",
            .runtime = "win32",
            .exe = "e",
            .exe_modified = "m",
            .pid = 1,
        },
    }).serializeResponse(alloc);
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const data = parsed.value.object.get("data").?.object;
    const window = data.get("windows").?.array.items[0].object;
    const tab = window.get("tabs").?.array.items[0].object;
    const node = tab.get("splits").?.object;
    const leaf = node.get("left").?.object;
    const term = leaf.get("terminal").?.object;

    // `build` (T52), `chrome` (T231), `connection` (T609), `background_tint`
    // (T67) and `session_id` (T332) are win32-only on purpose; the Mac half of
    // each is filed separately. Everything else must match name for name and
    // position for position.
    try expectMacShape(alloc, swift, "struct ListStateData", data.keys(), &.{"build"});
    try expectMacShape(alloc, swift, "struct WindowData", window.keys(), &.{ "chrome", "connection" });
    try expectMacShape(alloc, swift, "struct TabData", tab.keys(), &.{});
    try expectMacShape(alloc, swift, "struct TerminalData", term.keys(), &.{ "background_tint", "session_id" });

    // The Swift enum encodes its leaf case then its split case, so the two
    // shapes this encoder writes concatenate into the same sequence.
    var node_keys: std.ArrayList([]const u8) = .empty;
    defer node_keys.deinit(alloc);
    try node_keys.appendSlice(alloc, leaf.keys());
    try node_keys.appendSlice(alloc, node.keys());
    try expectMacShape(alloc, swift, "enum SplitNodeData", node_keys.items, &.{});

    // Order is half the contract; the other half is WHICH keys survive a null
    // value. A key the Mac writes unconditionally must still be there as an
    // explicit null, and one it `encodeIfPresent`s must vanish.
    const bare_leaf: List.Node = .{ .leaf = List.empty_terminal };
    const bare_tabs = [_]List.Tab{.{
        .id = "0",
        .title = "pwsh",
        .index = 0,
        .selected = true,
        .splits = &bare_leaf,
    }};
    const bare_windows = [_]List.Window{.{
        .id = "1",
        .title = "pwsh",
        .target = null,
        .focused = true,
        .tabs = &bare_tabs,
    }};
    const bare_json = try (List{ .windows = &bare_windows }).serializeResponse(alloc);
    defer alloc.free(bare_json);

    var bare_parsed = try std.json.parseFromSlice(std.json.Value, alloc, bare_json, .{});
    defer bare_parsed.deinit();

    const bare_term = bare_parsed.value.object.get("data").?.object
        .get("windows").?.array.items[0].object
        .get("tabs").?.array.items[0].object
        .get("splits").?.object
        .get("terminal").?.object;

    const mac_term = try swiftEncodedKeys(alloc, swift, "struct TerminalData");
    defer alloc.free(mac_term);
    for (mac_term) |k| {
        const present = bare_term.get(k.name) != null;
        if (k.conditional) {
            if (present) {
                std.debug.print(
                    "T370 TerminalData: '{s}' is emitted for a null value here, " ++
                        "the Mac encoder omits it\n",
                    .{k.name},
                );
                return error.MacShapeDrift;
            }
        } else if (!present) {
            std.debug.print(
                "T370 TerminalData: '{s}' is omitted for a null value here, " ++
                    "the Mac encoder writes it as null\n",
                .{k.name},
            );
            return error.MacShapeDrift;
        }
    }
    // The win32-only keys are all additive, so a bare pane carries none.
    for ([_][]const u8{ "background_tint", "session_id" }) |extra| {
        try testing.expect(bare_term.get(extra) == null);
    }
}
