//! Viewer-side session-layout manifest — the win32 port of the macOS
//! `SessionLayoutManifest` (`macos/Sources/Features/Remote/
//! SessionLayoutManifest.swift`). This is the LOCAL, same-host restore file
//! the GUI writes so that after a quit / logoff / reboot the next launch can
//! rebuild its windows/tabs/splits and re-ATTACH each pane to the session the
//! local `ghoztty-agent` kept alive (T89d/T89e). It is the app's OWN copy;
//! the agent's crash-durable `layout_meta.zig` blob store is the separate
//! cross-machine path (§5.4/T18) and is not involved here.
//!
//! Layering: like `layout_meta.zig`/`session_meta.zig`/`tab_color.zig`, this
//! module depends on nothing but `std` (+ `builtin` for the debug-file split),
//! so it compiles and unit-tests in every app-runtime lane. The topology WALK
//! that reads live `Window`/`Surface` state lives in `App.zig`
//! (`syncSessionLayout`); this module owns the schema and the bytes on disk.
//! The RESTORE reader (probe → rebuild → ATTACH) is T89f2.
//!
//! ## On-disk shape
//!
//!   {"version":1,"windows":[
//!     {"id":"win-0","uuid":"<uuid>","frame":{"x":..,"y":..,"w":..,"h":..},
//!      "maximized":false,
//!      "title_override":..?,"ipc_name":..?,"active_tab":0,
//!      "tabs":[{"nodes":[{"split":{"layout":"horizontal","ratio":0.5,
//!                                  "left":1,"right":2}},
//!                        {"leaf":{"session_id":"<32hex>","pane_id":"<uuid>",
//!                                 "title":..?,"banner":..?}},
//!                        {"leaf":{"session_id":"<32hex>"}}],
//!               "color":"blue"?,"hero_ratio":..?,"title":..?,"active":true}]}]}
//!
//! Keys are the Zig field names verbatim (snake_case). This file is the win32
//! app's private local-restore state and is never decoded by the macOS app
//! (which keeps its own Application Support manifest), so there is no
//! cross-lineage key-compatibility constraint — only the additive within-win32
//! one below.
//!
//! The split tree is stored FLAT (a `nodes` array, index 0 = root) with child
//! `left`/`right` as indices into that same array — this mirrors the internal
//! `SplitTree(V).nodes` representation exactly, so capture is a 1:1 index copy
//! and restore a 1:1 rebuild, and it sidesteps recursive-pointer JSON. A `Node`
//! is a plain object with two mutually-exclusive optional members (`leaf` /
//! `split`) rather than a tagged union, so the JSON needs no union-tag handling.
//!
//! ## Crash safety
//!
//! `writeAtomic` delegates to `atomic_write.writeChunks`, like
//! `layout_meta.writeAtomic` — safe under concurrent writers to the same path
//! (T183). Every field an older/newer build doesn't know is ignored on read
//! (`ignore_unknown_fields`), and absent optionals fall back — the
//! additive-evolution contract the whole app↔agent boundary follows.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const atomic_write = @import("../../remote/agent/atomic_write.zig");

/// On-disk schema version. Bumped only on an INCOMPATIBLE change; additive
/// fields (readers tolerate unknown + absent) need no bump.
pub const format_version: u32 = 1;

/// A hard ceiling on the file we will read back. A layout is a handful of
/// windows, each a small split tree of session ids + titles; 8 MiB comfortably
/// holds the agent's 256-session cap worth and rejects an implausibly large
/// file as corrupt rather than reading it into memory.
pub const max_file_bytes: usize = 8 * 1024 * 1024;

/// Per-pane ceiling on an encoded WP-D3 screen snapshot (T109). A 600-row VT
/// repaint of an ordinary pane is a few tens of KiB; a pane full of per-cell SGR
/// at a huge width can be much more. Anything past this is dropped for that pane
/// (it falls back to the full-ring replay) rather than allowed to dominate the file.
pub const screen_snapshot_max_pane_bytes: usize = 256 * 1024;

/// Whole-file ceiling on encoded snapshots, well under `max_file_bytes` so the
/// TOPOLOGY always fits. This is the load-bearing half of the budget: the
/// snapshot is an optimization, but a manifest that grew past `max_file_bytes`
/// would fail to load at all and cost the user every window. Snapshots are
/// therefore taken first-come (tree order) until the budget runs out; the panes
/// that miss out restore exactly as they did before T109.
pub const screen_snapshot_total_bytes: usize = 3 * 1024 * 1024;

/// Tracks encoded-snapshot bytes across ONE capture pass. Pure arithmetic so the
/// none-runtime lane can assert the two ceilings without a live surface.
pub const SnapshotBudget = struct {
    used: usize = 0,

    /// Claim `encoded_len` bytes for one pane's snapshot. True ⇒ the caller may
    /// record it (and the bytes are now spent); false ⇒ the pane is over the
    /// per-pane ceiling or the file budget is exhausted, so it records nothing.
    /// A rejected claim spends nothing, so a single huge pane cannot starve the
    /// smaller ones behind it.
    pub fn take(self: *SnapshotBudget, encoded_len: usize) bool {
        if (encoded_len == 0) return false;
        if (encoded_len > screen_snapshot_max_pane_bytes) return false;
        if (encoded_len > screen_snapshot_total_bytes - self.used) return false;
        self.used += encoded_len;
        return true;
    }
};

/// Outer window rectangle in screen pixels (matches the Mac `Frame`). For a
/// maximized window this is the restored ("normal") rect; `maximized` records
/// that it should come back maximized (T85 parity).
pub const Frame = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// One split-tree leaf: a terminal or a viewer pane.
/// `session_id` is the agent session to re-ATTACH to on restore (null when the
/// pane was not agent-backed — it restores as an exited pane, tree shape
/// preserved, matching the Mac null-sessionID behavior).
///
/// The four `kind`/`viewer_*` fields describe a VIEWER leaf (T90h, design P12);
/// a terminal leaf leaves all four null, so an ABSENT `kind` means terminal and
/// a manifest written before viewers existed keeps loading unchanged. They are
/// what a viewer restores from — it has no agent session to attach to, so
/// re-opening its location IS its restore:
///
///   * `viewer_location` — where the pane currently IS (it may have navigated
///     away from where it was opened).
///   * `viewer_home_location` — where it was OPENED, the Home button's target.
///     Persisted separately because restore navigates to `viewer_location` and
///     would otherwise silently re-home the pane to wherever it had wandered.
///   * `viewer_origin_directory` — the directory the pane was opened FROM
///     (`--working-directory`, which `+split --view=`/`+new-window --view=`
///     seed with the caller's cwd). This is the worktree-provenance fallback
///     for a pane whose location names no directory of its own — a website or a
///     blank page — so it cannot be re-derived from the location on restore.
///
/// `screen_snapshot` + `screen_snapshot_offset` are the WP-D3 fast re-attach
/// pair (T109): the pane's own structured VT repaint of its screen (base64) and
/// the absolute agent-stream byte offset that repaint reflects. On restore the
/// pane paints the snapshot for an instant, correctly-sized frame and ATTACHes
/// at the offset, so the agent gap-fills only `(offset, S]` instead of replaying
/// its whole retained ring. The ring is a CONCATENATION of segments drawn at
/// different geometries (every attach resize makes conhost append a fresh paint
/// at the new size), so a full-ring replay parsed at any single geometry is
/// faithful only to its own segments — which is the loss this pair removes.
/// Additive and optional in the usual way: a pre-T109 manifest, a viewer leaf, a
/// pane that never produced output, or a snapshot the budget below dropped all
/// decode as null and fall back to the full-ring replay.
///
/// `pane_id` is the pane's stable ghoztty-owned identity (T113) — the value
/// baked into its shell as `$GHOZTTY_PANE_ID`. It MUST round-trip: the
/// re-attached (or agent-RELAUNCHed) process keeps the env it was spawned
/// with, so a restore that generated a fresh id would leave the pane unable to
/// address itself. Additive and optional — a manifest written by a pre-T113
/// build simply has none and its restored panes get fresh ids.
///
/// `banner` is the pane's sticky banner as its raw markdown-subset SOURCE text
/// (T422 — the win32 half of the Mac leaf's `banner`). It is app-side overlay
/// state: it lives in the viewer, not in the PTY, so the agent's replay cannot
/// bring it back and this field is its ONLY way home. Without it every restored
/// pane came up bannerless, and on the agent-restart path the session-interrupted
/// notice then filled the vacant slot — N distinct banners replaced by N copies
/// of one sentence, which is what the user reported. Always null for a viewer
/// leaf (`+set-banner` rejects viewers). Additive and optional in the usual way.
pub const Leaf = struct {
    session_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    ipc_name: ?[]const u8 = null,
    pane_id: ?[]const u8 = null,
    banner: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    viewer_location: ?[]const u8 = null,
    viewer_home_location: ?[]const u8 = null,
    viewer_origin_directory: ?[]const u8 = null,
    screen_snapshot: ?[]const u8 = null,
    screen_snapshot_offset: ?u64 = null,

    /// Whether this leaf describes a VIEWER pane. Absent `kind` ⇒ terminal, so
    /// this is also the compatibility rule for a pre-viewer manifest. One
    /// reader for it, rather than an `eql` at every restore site that would
    /// each have to remember which spelling is the viewer one.
    pub fn isViewer(self: Leaf) bool {
        const k = self.kind orelse return false;
        return std.mem.eql(u8, k, kind_viewer);
    }
};

/// The `Leaf.kind` value for a viewer pane. Written by capture, matched by
/// restore; the terminal kind has no spelling at all (absent means terminal).
pub const kind_viewer = "viewer";

/// One split-tree internal node. `layout` is `"horizontal"` / `"vertical"`
/// (the `SplitTree.Split.Layout` tag name); `ratio` is the left/top child's
/// share (the `f16` tree ratio widened to `f32` for JSON); `left`/`right` are
/// indices into the owning `Tab.nodes` array.
pub const Split = struct {
    layout: []const u8,
    ratio: f32,
    left: u16,
    right: u16,
};

/// A flat split-tree node: EXACTLY one of `leaf`/`split` is non-null (capture
/// always sets one). Kept as two optionals rather than a tagged union so the
/// on-disk JSON is a plain object and needs no union-tag handling on read.
pub const Node = struct {
    leaf: ?Leaf = null,
    split: ?Split = null,

    pub fn isLeaf(self: Node) bool {
        return self.leaf != null;
    }
};

/// One tab: its split tree (flat, `nodes[0]` = root; a single-pane tab is one
/// leaf), plus per-tab presentation state (color T72, hero carousel ratio T59,
/// a pinned tab title T92). `active` marks the tab that was frontmost.
///
/// `uuid` is the tab's stable identity ACROSS runs (T1048), the tab-level
/// analogue of `Window.uuid`: generated once when the tab is created and
/// re-adopted by every restore, so in-place recovery can pair a captured tab
/// with the live one it actually came from instead of counting positions.
/// Additive and optional — a manifest written by a pre-T1048 build has none,
/// and a tab without one simply never pairs (see `pairTabs`), which is the
/// conservative half of that failure rather than the destructive one.
pub const Tab = struct {
    nodes: []const Node = &.{},
    uuid: ?[]const u8 = null,
    color: ?[]const u8 = null,
    hero_ratio: ?f32 = null,
    title: ?[]const u8 = null,
    active: bool = false,
};

/// One window: outer placement, the window-level title pin (T92), its IPC name
/// (`+new-window --target`), the active tab index, and its tabs in order.
///
/// `id` identifies the window WITHIN one file: the IPC name when it has one,
/// else `win-{index}`. It is deliberately NOT stable across app runs — the
/// auto IPC name (`window-N`) and the index both restart per process — so it
/// may only ever be used to tell this file's windows apart.
///
/// `uuid` is the window's stable identity ACROSS runs (T338): generated once
/// when the window is created and re-adopted by every restore, so a key derived
/// from it still names the same window after a quit, a crash, or a rebuild.
/// That is what the agent-side layout blob is keyed on — with `id` as the key,
/// the relaunched app's blank startup window took the dead run's key and
/// silently overwrote the topology "Restore All" exists to read. Additive and
/// optional: a manifest written by a pre-T338 build has none, and the reader
/// falls back to `id` exactly as before.
pub const Window = struct {
    id: []const u8,
    uuid: ?[]const u8 = null,
    frame: ?Frame = null,
    /// Height in pixels of the PRIMARY display of the machine that captured
    /// `frame` (T623). This is the one number a cross-lineage reader needs to
    /// convert the frame's vertical origin between conventions: Cocoa measures
    /// y UP from the bottom-left of the primary screen, win32 DOWN from its
    /// top-left, and the flip about the primary's full frame —
    /// `y' = primary_screen_height - y - h` — is exact for every monitor in
    /// the arrangement and is its own inverse, so the same formula serves both
    /// directions. The work-area height would NOT do: the global coordinate
    /// spaces are anchored at the primary's full frame, and a work-area flip
    /// is off by the menubar/taskbar. Additive: absent in older blobs, and a
    /// reader without it passes the origin through unconverted (the pre-T623
    /// vertically-mirrored fallback). Mac's spelling is `primaryScreenHeight`.
    primary_screen_height: ?i32 = null,
    maximized: bool = false,
    title_override: ?[]const u8 = null,
    ipc_name: ?[]const u8 = null,
    active_tab: u32 = 0,
    tabs: []const Tab = &.{},
};

/// The whole file. `windows` is a present (possibly empty) array so a reader
/// distinguishes "no windows to restore" from a corrupt/absent file.
pub const File = struct {
    version: u32 = format_version,
    windows: []const Window = &.{},
};

/// A parsed file whose backing memory (including every string) is owned by the
/// embedded arena; `deinit()` frees it all.
pub const Parsed = std.json.Parsed(File);

/// Drop absent optionals from the output so the file stays small and an older
/// build never sees a `null` where it expects a value — the additive-evolution
/// contract (readers tolerate both unknown and absent fields).
const stringify_opts: std.json.Stringify.Options = .{
    .emit_null_optional_fields = false,
};

/// Serialize `file` into the on-disk JSON body. Caller frees.
pub fn serialize(alloc: Allocator, file: File) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, file, stringify_opts);
}

/// Parse an on-disk body. The returned `Parsed` owns its strings; caller
/// `deinit`s it. Unknown fields are ignored (newer/older interop). Strings are
/// copied into the arena (`alloc_always`) so the file buffer can be freed
/// immediately.
pub fn parse(alloc: Allocator, bytes: []const u8) !Parsed {
    return std.json.parseFromSlice(File, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Atomically write `bytes` to `path` (creating parent directories as
/// needed). Mirrors `layout_meta.writeAtomic`: concurrent writers to the same
/// path are safe — see `atomic_write` (T183).
pub fn writeAtomic(alloc: Allocator, path: []const u8, bytes: []const u8) !void {
    try atomic_write.writeChunks(alloc, path, &.{bytes}, .{});
}

/// Load + parse the file at `path`. Returns null when ABSENT (normal — a first
/// start, or persistence was off). Any other I/O or parse failure propagates.
/// Caller `deinit`s a non-null result.
pub fn load(alloc: Allocator, path: []const u8) !?Parsed {
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(bytes);
    return try parse(alloc, bytes);
}

/// Resolve `%LOCALAPPDATA%\ghoztty\session-layout[-debug].json`. Caller frees.
/// Null when `%LOCALAPPDATA%` is unset (never on a real Windows session) or the
/// join fails. Debug builds get their own file — the same coexistence pattern
/// as the debug IPC pipe and `window_memory` — so test/dev never clobbers the
/// release app's restore state.
pub fn layoutPath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const name = if (builtin.mode == .Debug)
        "session-layout-debug.json"
    else
        "session-layout.json";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// The identity of a manifest body, for "has anything actually changed since I
/// last wrote?" (T922). `null` is "nothing written yet / unknown"; `deleted` is
/// the empty-window-set case `write` spells as a file delete, kept distinct so
/// it can never collide with a real body's hash.
pub const BodyId = union(enum) {
    deleted,
    hash: u64,

    pub fn eql(self: BodyId, other: BodyId) bool {
        return switch (self) {
            .deleted => other == .deleted,
            .hash => |h| switch (other) {
                .deleted => false,
                .hash => |o| h == o,
            },
        };
    }
};

fn hashBody(body: []const u8) BodyId {
    return .{ .hash = std.hash.Wyhash.hash(0, body) };
}

/// The identity `writeIfChanged` would compare for `file`, without touching the
/// disk — the same derivation, so a test can assert what the skip rule sees.
/// Null only when the body could not be serialized.
pub fn bodyId(alloc: Allocator, file: File) ?BodyId {
    if (file.windows.len == 0) return .deleted;
    const body = serialize(alloc, file) catch return null;
    defer alloc.free(body);
    return hashBody(body);
}

/// Best-effort persist of `file` to the default path — SKIPPED when the bytes
/// would be identical to the last ones this process wrote (`prev`, updated in
/// place). Returns true when the disk was actually touched. Failures are
/// swallowed: the manifest is a convenience, never worth an error dialog
/// (window_memory parity). An empty window set deletes the file rather than
/// leaving a stale one that would restore nothing (Mac `saveLocked` parity).
///
/// Why the skip (T922): the manifest carries each pane's persisted SCREEN, and
/// a screen goes stale the moment the pane prints anything — so `App` now
/// re-captures it on a timer rather than only when the window/tab/split topology
/// mutates. Some of those captures find nothing new, and an atomic write for a
/// byte-identical body is pure churn: a rename over the user's manifest, on a
/// loop, forever. Serializing is the expensive half and happens either way, so
/// the comparison is made on the serialized body rather than by asking the
/// topology whether it changed — which is also the only version that catches "a
/// pane repainted itself back to what it already looked like".
pub fn writeIfChanged(alloc: Allocator, file: File, prev: *?BodyId) bool {
    const path = layoutPath(alloc) orelse return false;
    defer alloc.free(path);

    if (file.windows.len == 0) {
        if (prev.*) |p| if (p.eql(.deleted)) return false;
        std.fs.cwd().deleteFile(path) catch {};
        prev.* = .deleted;
        return true;
    }

    const body = serialize(alloc, file) catch return false;
    defer alloc.free(body);
    const id = hashBody(body);
    if (prev.*) |p| if (p.eql(id)) return false;
    // Only a write that LANDED may be remembered: recording the hash of a body
    // that failed to reach disk would make every later tick skip it as
    // "already written", and the manifest would stay at whatever the last
    // successful write left there.
    writeAtomic(alloc, path, body) catch return false;
    prev.* = id;
    return true;
}

/// Delete the manifest (persistence turned off, or nothing to restore).
/// Best-effort; a missing file is success.
pub fn clear(alloc: Allocator) void {
    const path = layoutPath(alloc) orelse return;
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

/// The stable key a window is stored and matched under: its cross-run `uuid`
/// (T338), falling back to the within-file `id` for a manifest or blob written
/// by a pre-T338 build. This is the SAME derivation `App.pushLayoutBlobs` uses
/// for the agent-side key, which is what lets the two sides be unioned at all.
pub fn windowKey(win: Window) []const u8 {
    return win.uuid orelse win.id;
}

/// Pair a LIVE window walk against a CAPTURED one by identity (T343).
///
/// `live_keys` holds one key per live window in walk order (`Window.layoutUuid`
/// on the win32 side); the result holds one entry per live window: the index of
/// the captured window that window owns, or `null` when the capture has none —
/// a window born after the capture, or one the capture's own filter skipped (a
/// quick terminal, a cross-machine window, a window with no tabs). `null` is
/// always the safe answer: the caller leaves that window alone.
///
/// Every captured entry is handed out AT MOST ONCE, so even a duplicated key
/// cannot make two live windows rebuild from the same topology — the second is
/// skipped, which is the conservative half of that failure rather than the
/// destructive one.
///
/// This replaces the positional join in-place recovery used to do, which was
/// correct only while a hand-copy of `captureSessionLayout`'s skip rule stayed
/// in step with the original AND no window closed in between (the capture is
/// followed by a re-dial that can block for seconds). Either drift silently
/// paired a window with ANOTHER window's captured tree, and nothing asserted.
pub fn pairWindows(
    alloc: Allocator,
    captured: []const Window,
    live_keys: []const []const u8,
) ![]const ?usize {
    const keys = try alloc.alloc([]const u8, captured.len);
    defer alloc.free(keys);
    for (captured, 0..) |cap, ci| keys[ci] = windowKey(cap);
    return pairByKey(alloc, keys, live_keys);
}

/// The stable key a tab is matched under: its cross-run `uuid` (T1048), or the
/// empty string for a tab captured by a pre-T1048 build, which never matches.
pub fn tabKey(tab: Tab) []const u8 {
    return tab.uuid orelse "";
}

/// Pair a LIVE tab walk against a CAPTURED one by identity (T1048) — the
/// tab-level analogue of `pairWindows`, and for the same reason one level down.
///
/// In-place recovery used to hand `captured.tabs[i]` to live tab `i`, which is
/// correct only while the window's tab list has not moved since the capture —
/// and the capture is followed by a re-dial that can block for seconds. A tab
/// closed, inserted or dragged in that gap shifts every later tab, and each one
/// was then rebuilt from its NEIGHBOUR's tree: its sessions re-ATTACHed into
/// the wrong panes. `rebuildTabInPlace`'s correspondence check cannot catch it,
/// because it compares node SHAPES — and two single-pane tabs, the common case,
/// have the same shape.
///
/// `live_keys` holds one key per live tab in walk order (`Window.tabUuid`); the
/// result holds one entry per live tab: the index of the captured tab it owns,
/// or `null` when the capture has none. `null` is always the safe answer — the
/// caller leaves that tab alone, keeping its current panes rather than
/// replacing them with somebody else's.
pub fn pairTabs(
    alloc: Allocator,
    captured: []const Tab,
    live_keys: []const []const u8,
) ![]const ?usize {
    const keys = try alloc.alloc([]const u8, captured.len);
    defer alloc.free(keys);
    for (captured, 0..) |cap, ci| keys[ci] = tabKey(cap);
    return pairByKey(alloc, keys, live_keys);
}

/// The join both pairings are: first unused captured entry whose key matches,
/// else `null`.
///
/// Every captured entry is handed out AT MOST ONCE, so even a duplicated key
/// cannot make two live entries rebuild from the same topology — the second is
/// skipped, which is the conservative half of that failure rather than the
/// destructive one. An EMPTY key never matches anything, on either side: it is
/// how "this entry has no identity to key on" is spelled (a pre-T1048 captured
/// tab), and pairing on it would be the positional guess this replaces.
fn pairByKey(
    alloc: Allocator,
    captured_keys: []const []const u8,
    live_keys: []const []const u8,
) ![]const ?usize {
    const out = try alloc.alloc(?usize, live_keys.len);
    errdefer alloc.free(out);

    const used = try alloc.alloc(bool, captured_keys.len);
    defer alloc.free(used);
    @memset(used, false);

    for (live_keys, 0..) |key, li| {
        out[li] = null;
        if (key.len == 0) continue;
        for (captured_keys, 0..) |cap, ci| {
            if (used[ci]) continue;
            if (cap.len == 0) continue;
            if (!std.mem.eql(u8, cap, key)) continue;
            used[ci] = true;
            out[li] = ci;
            break;
        }
    }
    return out;
}

/// The result of `reconcile`: the restore set, plus how many of its entries came
/// from the AGENT alone. `adopted > 0` is the signal that the local manifest has
/// fallen behind and needs re-writing once the windows are live.
pub const Reconciled = struct {
    /// Local entries first (in file order), then the agent-only ones. Every
    /// `Window` — and every string in it — is BORROWED from the inputs; only the
    /// outer slice is allocated, and the caller frees it.
    windows: []const Window,
    adopted: usize,
};

/// Union the app-local manifest with the layouts the AGENT holds (T194, Mac's
/// `reconcileLayoutEntries`). Pure, so it unit-tests in every app-runtime lane.
///
/// Why this exists: after an app CRASH the local manifest can REGRESS — a
/// relaunch that rebuilt nothing then overwrote it with the one blank window it
/// did open — while the ever-running agent still holds a blob for every window
/// whose PTYs are alive. Restoring from the local file alone loses those windows
/// permanently even though nothing about them actually died.
///
/// Two rules decide the union:
///
///   * **Local wins on key collision.** After a crash the local entry can only
///     be the fresher of the two: it is rewritten on every layout mutation,
///     whereas the agent's copy is a mirror of that same file. Keeping local
///     also keeps the WP-D3 screen snapshots, which are stripped out of a blob
///     on purpose (`layout_blobs.serializeWindow`).
///   * **An agent window whose session is already claimed is dropped**, even
///     when its key is new. One leaf is enough — the same "a window is restored
///     as a unit" rule `App.windowIsOpenOn` applies — because the agent rebinds
///     a session to the NEWEST attach, so restoring two windows over one session
///     would blank the first to make a copy of it.
pub fn reconcile(
    alloc: Allocator,
    local: []const Window,
    agent: []const Window,
) Allocator.Error!Reconciled {
    var out: std.ArrayList(Window) = .empty;
    errdefer out.deinit(alloc);

    var keys: std.StringHashMapUnmanaged(void) = .empty;
    defer keys.deinit(alloc);
    var claimed: std.StringHashMapUnmanaged(void) = .empty;
    defer claimed.deinit(alloc);

    for (local) |win| {
        const gop = try keys.getOrPut(alloc, windowKey(win));
        // A duplicate key within one file is malformed, not a second window.
        if (gop.found_existing) continue;
        try out.append(alloc, win);
        try claimSessions(alloc, &claimed, win);
    }

    var adopted: usize = 0;
    for (agent) |win| {
        const gop = try keys.getOrPut(alloc, windowKey(win));
        if (gop.found_existing) continue;
        if (sessionsClaimed(&claimed, win)) continue;
        try out.append(alloc, win);
        try claimSessions(alloc, &claimed, win);
        adopted += 1;
    }

    return .{ .windows = try out.toOwnedSlice(alloc), .adopted = adopted };
}

/// Record every session id `win` references as spoken for.
fn claimSessions(
    alloc: Allocator,
    claimed: *std.StringHashMapUnmanaged(void),
    win: Window,
) Allocator.Error!void {
    for (win.tabs) |tab| {
        for (tab.nodes) |node| {
            const leaf = node.leaf orelse continue;
            const sid = leaf.session_id orelse continue;
            if (sid.len == 0) continue;
            try claimed.put(alloc, sid, {});
        }
    }
}

/// Carry unrestored manifest windows forward through a wholesale rewrite
/// (T590). win32 regenerates the manifest from the LIVE topology on every sync,
/// so a launch that could not restore a window — the agent was unspawnable, or
/// the liveness probe never landed — used to erase its only surviving record
/// the moment the blank startup window's first sync fired. macOS keeps such
/// entries untouched for the next launch ("local agent unreachable; keeping N
/// manifest entries", `SessionLayoutRestore.swift`); this is that rule
/// translated to the wholesale-rewrite model: the capture is extended with the
/// on-disk entries for every key in `carried`.
///
/// `carried` is the set of window keys (`windowKey`) the launch restore SKIPPED
/// without a positive adjudication — never a window the agent answered about
/// and disowned, which stays dropped so the manifest cannot become immortal.
/// Two rules:
///
///   * **A live key adjudicates.** A carried key that appears in `live` came
///     back (a later Restore All, an adoption) — it is removed from `carried`
///     (its gpa-owned key freed) and its future is the live capture's business.
///   * **The rest ride along.** Every `manifest` window whose key is still in
///     `carried` is appended after the live windows, strings borrowed from the
///     caller's parsed manifest (which must outlive the returned slice).
///
/// Returns `live` itself when there is nothing to carry, else a new slice
/// allocated with `arena`. Pure aside from the `carried` upkeep, so it
/// unit-tests in every app-runtime lane.
pub fn mergeCarried(
    arena: Allocator,
    gpa: Allocator,
    live: []const Window,
    manifest: []const Window,
    carried: *std.StringHashMapUnmanaged(void),
) Allocator.Error![]const Window {
    if (carried.count() == 0) return live;

    for (live) |win| {
        if (carried.fetchRemove(windowKey(win))) |kv| gpa.free(kv.key);
    }
    if (carried.count() == 0) return live;

    var out: std.ArrayList(Window) = .empty;
    errdefer out.deinit(arena);
    try out.appendSlice(arena, live);

    // A malformed manifest could repeat a key; append each carried key once.
    var appended: std.StringHashMapUnmanaged(void) = .empty;
    defer appended.deinit(gpa);
    for (manifest) |win| {
        const key = windowKey(win);
        if (!carried.contains(key)) continue;
        const gop = try appended.getOrPut(gpa, key);
        if (gop.found_existing) continue;
        try out.append(arena, win);
    }
    return try out.toOwnedSlice(arena);
}

/// Whether ANY session `win` references is already spoken for by an accepted
/// window. One is enough — see `reconcile`'s second rule.
fn sessionsClaimed(claimed: *const std.StringHashMapUnmanaged(void), win: Window) bool {
    for (win.tabs) |tab| {
        for (tab.nodes) |node| {
            const leaf = node.leaf orelse continue;
            const sid = leaf.session_id orelse continue;
            if (sid.len == 0) continue;
            if (claimed.contains(sid)) return true;
        }
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "serialize + parse round-trip preserves windows, tabs, tree, order" {
    const alloc = testing.allocator;

    // A two-tab window: tab 0 is a horizontal split of two leaves, tab 1 is a
    // single leaf. Plus a second single-pane window.
    const tab0_nodes = [_]Node{
        .{ .split = .{ .layout = "horizontal", .ratio = 0.5, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session_id = "0123456789abcdef0123456789abcdef", .title = "left" } },
        .{ .leaf = .{ .session_id = "fedcba9876543210fedcba9876543210", .ipc_name = "logs" } },
    };
    const tab1_nodes = [_]Node{
        .{ .leaf = .{ .session_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } },
    };
    const w0_tabs = [_]Tab{
        .{ .nodes = &tab0_nodes, .color = "blue", .hero_ratio = 0.3, .active = true },
        .{ .nodes = &tab1_nodes, .title = "pinned" },
    };
    const w1_nodes = [_]Node{
        .{ .leaf = .{ .session_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" } },
    };
    const w1_tabs = [_]Tab{.{ .nodes = &w1_nodes, .active = true }};
    const windows = [_]Window{
        .{
            .id = "win-0",
            .frame = .{ .x = 10, .y = 20, .w = 800, .h = 600 },
            .maximized = false,
            .title_override = "My Window",
            .ipc_name = "dev",
            .active_tab = 0,
            .tabs = &w0_tabs,
        },
        .{
            .id = "win-1",
            .frame = .{ .x = -5, .y = 0, .w = 1024, .h = 768 },
            .maximized = true,
            .active_tab = 0,
            .tabs = &w1_tabs,
        },
    };
    const file: File = .{ .windows = &windows };

    const body = try serialize(alloc, file);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"version\":1") != null);
    // emit_null_optional_fields=false: absent optionals are dropped.
    try testing.expect(std.mem.indexOf(u8, body, "\"viewer_location\"") == null);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const v = parsed.value;
    try testing.expectEqual(@as(u32, 1), v.version);
    try testing.expectEqual(@as(usize, 2), v.windows.len);

    const w0 = v.windows[0];
    try testing.expectEqualStrings("win-0", w0.id);
    try testing.expect(w0.frame != null);
    try testing.expectEqual(@as(i32, 10), w0.frame.?.x);
    try testing.expectEqual(@as(i32, 600), w0.frame.?.h);
    try testing.expect(!w0.maximized);
    try testing.expectEqualStrings("My Window", w0.title_override.?);
    try testing.expectEqualStrings("dev", w0.ipc_name.?);
    try testing.expectEqual(@as(usize, 2), w0.tabs.len);

    const t0 = w0.tabs[0];
    try testing.expect(t0.active);
    try testing.expectEqualStrings("blue", t0.color.?);
    try testing.expectApproxEqAbs(@as(f32, 0.3), t0.hero_ratio.?, 0.001);
    try testing.expectEqual(@as(usize, 3), t0.nodes.len);
    // Root is the split.
    try testing.expect(!t0.nodes[0].isLeaf());
    const sp = t0.nodes[0].split.?;
    try testing.expectEqualStrings("horizontal", sp.layout);
    try testing.expectApproxEqAbs(@as(f32, 0.5), sp.ratio, 0.001);
    try testing.expectEqual(@as(u16, 1), sp.left);
    try testing.expectEqual(@as(u16, 2), sp.right);
    // Children are leaves with their session ids preserved in order.
    try testing.expect(t0.nodes[1].isLeaf());
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", t0.nodes[1].leaf.?.session_id.?);
    try testing.expectEqualStrings("left", t0.nodes[1].leaf.?.title.?);
    try testing.expectEqualStrings("logs", t0.nodes[2].leaf.?.ipc_name.?);

    const t1 = w0.tabs[1];
    try testing.expect(!t1.active);
    try testing.expectEqualStrings("pinned", t1.title.?);
    try testing.expectEqual(@as(usize, 1), t1.nodes.len);
    try testing.expect(t1.nodes[0].isLeaf());

    const w1 = v.windows[1];
    try testing.expectEqualStrings("win-1", w1.id);
    try testing.expect(w1.maximized);
    try testing.expect(w1.title_override == null);
}

test "T109: screen snapshot + offset round-trip, and are absent when unset" {
    const alloc = testing.allocator;

    const nodes = [_]Node{
        .{ .leaf = .{
            .session_id = "0123456789abcdef0123456789abcdef",
            .screen_snapshot = "G1tIG1tKaGVsbG8=",
            .screen_snapshot_offset = 4_294_967_296, // > u32, so u64 is load-bearing
        } },
        .{ .leaf = .{ .session_id = "fedcba9876543210fedcba9876543210" } },
    };
    const tabs = [_]Tab{.{ .nodes = &nodes, .active = true }};
    const windows = [_]Window{.{ .id = "win-0", .tabs = &tabs }};

    const body = try serialize(alloc, .{ .windows = &windows });
    defer alloc.free(body);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const leaves = parsed.value.windows[0].tabs[0].nodes;
    try testing.expectEqualStrings("G1tIG1tKaGVsbG8=", leaves[0].leaf.?.screen_snapshot.?);
    try testing.expectEqual(@as(u64, 4_294_967_296), leaves[0].leaf.?.screen_snapshot_offset.?);
    // A leaf that recorded none stays null — that is the full-ring fallback.
    try testing.expect(leaves[1].leaf.?.screen_snapshot == null);
    try testing.expect(leaves[1].leaf.?.screen_snapshot_offset == null);
}

test "T109: a pre-snapshot manifest still loads, with null snapshot fields" {
    const alloc = testing.allocator;
    const body =
        \\{"version":1,"windows":[{"id":"win-0","active_tab":0,
        \\"tabs":[{"nodes":[{"leaf":{"session_id":"aaaa","pane_id":"p"}}],"active":true}]}]}
    ;
    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const leaf = parsed.value.windows[0].tabs[0].nodes[0].leaf.?;
    try testing.expectEqualStrings("aaaa", leaf.session_id.?);
    try testing.expect(leaf.screen_snapshot == null);
    try testing.expect(leaf.screen_snapshot_offset == null);
}

test "T422: a pane's sticky banner round-trips, markdown source intact" {
    const alloc = testing.allocator;

    // The banner's raw markdown SOURCE, not its rendering — a restore re-runs
    // the same parser the user's `+set-banner` did, so the delimiters, the pipe
    // table and the escaped newlines all have to survive the JSON verbatim.
    const banner = "**T422** _in progress_\\n| job | state |\\n|---|---:|\\n| lint | `ok` |";
    const nodes = [_]Node{
        .{ .leaf = .{ .session_id = "0123456789abcdef0123456789abcdef", .banner = banner } },
        .{ .leaf = .{ .session_id = "fedcba9876543210fedcba9876543210" } },
    };
    const tabs = [_]Tab{.{ .nodes = &nodes, .active = true }};
    const windows = [_]Window{.{ .id = "win-0", .tabs = &tabs }};

    const body = try serialize(alloc, .{ .windows = &windows });
    defer alloc.free(body);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const leaves = parsed.value.windows[0].tabs[0].nodes;
    try testing.expectEqualStrings(banner, leaves[0].leaf.?.banner.?);
    // A pane with no banner records none, so restore leaves the slot free for
    // the session-interrupted notice rather than setting an empty banner.
    try testing.expect(leaves[1].leaf.?.banner == null);
}

test "T422: a pre-banner manifest still loads, with a null banner" {
    const alloc = testing.allocator;
    const body =
        \\{"version":1,"windows":[{"id":"win-0","active_tab":0,
        \\"tabs":[{"nodes":[{"leaf":{"session_id":"aaaa","title":"zsh"}}],"active":true}]}]}
    ;
    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const leaf = parsed.value.windows[0].tabs[0].nodes[0].leaf.?;
    try testing.expectEqualStrings("zsh", leaf.title.?);
    try testing.expect(leaf.banner == null);
}

test "T109: snapshot budget rejects an oversized pane and stops at the file ceiling" {
    var budget: SnapshotBudget = .{};

    // Nothing to record is not a claim.
    try testing.expect(!budget.take(0));
    try testing.expectEqual(@as(usize, 0), budget.used);

    // Over the per-pane ceiling ⇒ refused, and it spends nothing, so the panes
    // behind it are unaffected.
    try testing.expect(!budget.take(screen_snapshot_max_pane_bytes + 1));
    try testing.expectEqual(@as(usize, 0), budget.used);
    try testing.expect(budget.take(screen_snapshot_max_pane_bytes));
    try testing.expectEqual(screen_snapshot_max_pane_bytes, budget.used);

    // Fill the file budget exactly, then refuse the next byte.
    var full: SnapshotBudget = .{};
    var taken: usize = 0;
    while (taken + screen_snapshot_max_pane_bytes <= screen_snapshot_total_bytes) : (taken += screen_snapshot_max_pane_bytes) {
        try testing.expect(full.take(screen_snapshot_max_pane_bytes));
    }
    try testing.expectEqual(screen_snapshot_total_bytes, full.used);
    try testing.expect(!full.take(1));

    // The ceiling leaves room for the topology itself.
    try testing.expect(screen_snapshot_total_bytes < max_file_bytes);
}

test "serialize an empty window set is a present empty array" {
    const alloc = testing.allocator;
    const body = try serialize(alloc, .{});
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"windows\":[]") != null);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.windows.len);
}

test "writeAtomic + load round-trip; no .tmp leftover; missing file loads null" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "state", "session-layout.json" });
    defer alloc.free(path);

    try testing.expect((try load(alloc, path)) == null);

    const nodes = [_]Node{.{ .leaf = .{ .session_id = "abcabcabcabcabcabcabcabcabcabcab" } }};
    const tabs = [_]Tab{.{ .nodes = &nodes, .active = true }};
    const windows = [_]Window{.{ .id = "w1", .tabs = &tabs, .frame = .{ .x = 1, .y = 2, .w = 3, .h = 4 } }};
    const body = try serialize(alloc, .{ .windows = &windows });
    defer alloc.free(body);
    try writeAtomic(alloc, path, body);

    // No staging leftover of any name — the parent holds exactly the file.
    {
        var dir = try std.fs.cwd().openDir(std.fs.path.dirname(path).?, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next()) |entry| {
            count += 1;
            try testing.expectEqualStrings("session-layout.json", entry.name);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    var loaded = (try load(alloc, path)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.value.windows.len);
    try testing.expectEqualStrings("w1", loaded.value.windows[0].id);
    try testing.expectEqualStrings(
        "abcabcabcabcabcabcabcabcabcabcab",
        loaded.value.windows[0].tabs[0].nodes[0].leaf.?.session_id.?,
    );
}

test "T922: the write-skip rule sees a changed pane SCREEN, not just topology" {
    const alloc = testing.allocator;

    const tabs = [_]Tab{.{ .nodes = &[_]Node{.{ .leaf = .{
        .session_id = "abcabcabcabcabcabcabcabcabcabcab",
        .screen_snapshot = "b2xkIHNjcmVlbg==",
        .screen_snapshot_offset = 4096,
    } }}, .active = true }};
    const windows = [_]Window{.{ .id = "w1", .tabs = &tabs }};

    // The same topology captured twice is the same body: an idle terminal must
    // not cost a manifest rewrite on every refresh tick.
    const first = bodyId(alloc, .{ .windows = &windows }).?;
    try testing.expect(first.eql(bodyId(alloc, .{ .windows = &windows }).?));

    // A pane that painted something new IS a change, even though no window,
    // tab or split moved — the whole reason the refresh exists.
    const moved_tabs = [_]Tab{.{ .nodes = &[_]Node{.{ .leaf = .{
        .session_id = "abcabcabcabcabcabcabcabcabcabcab",
        .screen_snapshot = "bmV3IHNjcmVlbg==",
        .screen_snapshot_offset = 8192,
    } }}, .active = true }};
    const moved = [_]Window{.{ .id = "w1", .tabs = &moved_tabs }};
    try testing.expect(!first.eql(bodyId(alloc, .{ .windows = &moved }).?));
}

test "T922: an empty window set is its own identity, never a body hash" {
    const alloc = testing.allocator;

    const empty = bodyId(alloc, .{}).?;
    try testing.expect(empty.eql(.deleted));
    try testing.expect(empty.eql(bodyId(alloc, .{ .windows = &.{} }).?));

    const tabs = [_]Tab{.{ .nodes = &[_]Node{.{ .leaf = .{ .session_id = "a" } }}, .active = true }};
    const windows = [_]Window{.{ .id = "w1", .tabs = &tabs }};
    try testing.expect(!empty.eql(bodyId(alloc, .{ .windows = &windows }).?));
}

test "viewer leaf round-trips all four fields; a terminal leaf emits none of them" {
    const alloc = testing.allocator;

    // A mixed tab: a terminal leaf beside a viewer leaf that has navigated away
    // from where it was opened (location != home) and carries an origin
    // directory its location could never be re-derived from.
    const nodes = [_]Node{
        .{ .split = .{ .layout = "vertical", .ratio = 0.6, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session_id = "abcabcabcabcabcabcabcabcabcabcab", .pane_id = "t-1" } },
        .{ .leaf = .{
            .pane_id = "v-1",
            .ipc_name = "doc",
            .kind = kind_viewer,
            .viewer_location = "https://example.com/",
            .viewer_home_location = "D:\\git\\ghoztty\\README.md",
            .viewer_origin_directory = "D:\\git\\ghoztty",
        } },
    };
    const tabs = [_]Tab{.{ .nodes = &nodes, .active = true }};
    const windows = [_]Window{.{ .id = "w1", .tabs = &tabs }};

    const body = try serialize(alloc, .{ .windows = &windows });
    defer alloc.free(body);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const out = parsed.value.windows[0].tabs[0].nodes;

    // The terminal leaf keeps its session and stays kind-less — that ABSENCE is
    // the compatibility rule (absent kind ⇒ terminal), so it is asserted on the
    // bytes and not just on the parsed value.
    const term = out[1].leaf.?;
    try testing.expect(!term.isViewer());
    try testing.expect(term.kind == null);
    try testing.expect(term.viewer_home_location == null);
    try testing.expect(term.viewer_origin_directory == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"pane_id\":\"t-1\",\"kind\"") == null);

    const view = out[2].leaf.?;
    try testing.expect(view.isViewer());
    try testing.expect(view.session_id == null);
    try testing.expectEqualStrings("doc", view.ipc_name.?);
    try testing.expectEqualStrings("v-1", view.pane_id.?);
    try testing.expectEqualStrings("https://example.com/", view.viewer_location.?);
    try testing.expectEqualStrings("D:\\git\\ghoztty\\README.md", view.viewer_home_location.?);
    try testing.expectEqualStrings("D:\\git\\ghoztty", view.viewer_origin_directory.?);
}

test "a pre-viewer manifest still loads: absent kind reads as a terminal leaf" {
    const alloc = testing.allocator;

    // Bytes as a build that predates viewer panes wrote them — no `kind`, and
    // an unknown future field beside it to prove `ignore_unknown_fields` still
    // covers the other direction of the same contract.
    const body =
        \\{"version":1,"windows":[{"id":"w1","tabs":[{"nodes":[
        \\{"leaf":{"session_id":"abcabcabcabcabcabcabcabcabcabcab","future_field":7}}
        \\],"active":true}]}]}
    ;
    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    const leaf = parsed.value.windows[0].tabs[0].nodes[0].leaf.?;
    try testing.expect(!leaf.isViewer());
    try testing.expectEqualStrings("abcabcabcabcabcabcabcabcabcabcab", leaf.session_id.?);
}

test "an unrecognized kind is not a viewer, so a newer kind degrades to terminal" {
    // The additive-evolution rule applied to `kind` itself: a manifest from a
    // build that grows a third leaf kind must not have its leaves silently
    // treated as viewers here (which would try to navigate a null location).
    const leaf: Leaf = .{ .kind = "hologram", .session_id = null };
    try testing.expect(!leaf.isViewer());
}

test "window uuid round-trips, is dropped when absent, and falls back to id" {
    const alloc = testing.allocator;

    const nodes = [_]Node{.{ .leaf = .{ .session_id = "abcabcabcabcabcabcabcabcabcabcab" } }};
    const tabs = [_]Tab{.{ .nodes = &nodes, .active = true }};
    const windows = [_]Window{
        .{ .id = "window-1", .uuid = "1AC1F1F0-0000-4000-8000-000000000001", .tabs = &tabs },
        .{ .id = "win-1", .tabs = &tabs },
    };
    const body = try serialize(alloc, .{ .windows = &windows });
    defer alloc.free(body);
    // Present on the window that has one; dropped entirely on the one that
    // doesn't (emit_null_optional_fields=false), so a pre-T338 reader sees the
    // same bytes it always did.
    try testing.expect(std.mem.indexOf(u8, body, "\"uuid\":\"1AC1F1F0") != null);
    try testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, body, "\"id\":\"win-1\",\"uuid\""),
    );

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "1AC1F1F0-0000-4000-8000-000000000001",
        parsed.value.windows[0].uuid.?,
    );
    try testing.expect(parsed.value.windows[1].uuid == null);

    // A manifest from a pre-T338 build parses with a null uuid, which is what
    // makes `uuid orelse id` the correct key derivation for both.
    const legacy =
        \\{"version":1,"windows":[{"id":"win-0","tabs":[{"nodes":[{"leaf":{}}]}]}]}
    ;
    var old = try parse(alloc, legacy);
    defer old.deinit();
    try testing.expect(old.value.windows[0].uuid == null);
    try testing.expectEqualStrings("win-0", old.value.windows[0].uuid orelse old.value.windows[0].id);
}

test "parse tolerates unknown fields and missing optionals (additive interop)" {
    const alloc = testing.allocator;
    // A future build added a per-window field and a per-leaf field we don't
    // know; a leaf omits every optional. Both must parse cleanly.
    const body =
        \\{"version":1,"future_top":true,"windows":[
        \\  {"id":"w","futureWin":42,"tabs":[
        \\    {"nodes":[{"leaf":{"futureLeaf":"x"}}]}
        \\  ]}
        \\]}
    ;
    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.windows.len);
    const w = parsed.value.windows[0];
    try testing.expectEqualStrings("w", w.id);
    try testing.expect(w.frame == null);
    try testing.expectEqual(@as(usize, 1), w.tabs.len);
    const leaf = w.tabs[0].nodes[0].leaf.?;
    try testing.expect(leaf.session_id == null);
    try testing.expect(leaf.title == null);
}

// -- reconcile (T194) ---------------------------------------------------------

/// One single-pane window keyed by `uuid`, holding session `sid`.
fn reconcileWindow(
    id: []const u8,
    uuid: ?[]const u8,
    sid: ?[]const u8,
    nodes: *[1]Node,
    tabs: *[1]Tab,
) Window {
    nodes[0] = .{ .leaf = .{ .session_id = sid } };
    tabs[0] = .{ .nodes = nodes, .active = true };
    return .{ .id = id, .uuid = uuid, .tabs = tabs };
}

test "reconcile: agent-only windows are ADDED after the local ones" {
    const alloc = testing.allocator;
    var ln: [1]Node = undefined;
    var lt: [1]Tab = undefined;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    const local = [_]Window{reconcileWindow("window-1", "uuid-local", "sess-a", &ln, &lt)};
    const agent = [_]Window{reconcileWindow("window-9", "uuid-agent", "sess-b", &an, &at)};

    const r = try reconcile(alloc, &local, &agent);
    defer alloc.free(r.windows);
    try testing.expectEqual(@as(usize, 2), r.windows.len);
    try testing.expectEqual(@as(usize, 1), r.adopted);
    // Local first, in file order; the recovered window trails it.
    try testing.expectEqualStrings("uuid-local", r.windows[0].uuid.?);
    try testing.expectEqualStrings("uuid-agent", r.windows[1].uuid.?);
}

test "reconcile: an empty local manifest recovers the agent's whole set" {
    const alloc = testing.allocator;
    var n0: [1]Node = undefined;
    var t0: [1]Tab = undefined;
    var n1: [1]Node = undefined;
    var t1: [1]Tab = undefined;
    const agent = [_]Window{
        reconcileWindow("win-0", "uuid-0", "sess-0", &n0, &t0),
        reconcileWindow("win-1", "uuid-1", "sess-1", &n1, &t1),
    };

    // This is the crash case the row exists for: the manifest regressed to
    // nothing while every PTY is still alive in the agent.
    const r = try reconcile(alloc, &.{}, &agent);
    defer alloc.free(r.windows);
    try testing.expectEqual(@as(usize, 2), r.windows.len);
    try testing.expectEqual(@as(usize, 2), r.adopted);
}

test "reconcile: LOCAL wins on a key collision" {
    const alloc = testing.allocator;
    var ln: [1]Node = undefined;
    var lt: [1]Tab = undefined;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    // Same uuid, different `id` and title-bearing content: the agent copy is a
    // mirror of an older write of the same window.
    const local = [_]Window{reconcileWindow("fresh", "uuid-same", "sess-a", &ln, &lt)};
    const agent = [_]Window{reconcileWindow("stale", "uuid-same", "sess-a", &an, &at)};

    const r = try reconcile(alloc, &local, &agent);
    defer alloc.free(r.windows);
    try testing.expectEqual(@as(usize, 1), r.windows.len);
    try testing.expectEqual(@as(usize, 0), r.adopted);
    try testing.expectEqualStrings("fresh", r.windows[0].id);
}

test "reconcile: a pre-T338 entry keys on its id, so it still collides" {
    const alloc = testing.allocator;
    var ln: [1]Node = undefined;
    var lt: [1]Tab = undefined;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    const local = [_]Window{reconcileWindow("win-0", null, "sess-a", &ln, &lt)};
    const agent = [_]Window{reconcileWindow("win-0", null, "sess-a", &an, &at)};

    const r = try reconcile(alloc, &local, &agent);
    defer alloc.free(r.windows);
    try testing.expectEqual(@as(usize, 1), r.windows.len);
    try testing.expectEqual(@as(usize, 0), r.adopted);
}

test "reconcile: an agent window whose session is already claimed is dropped" {
    const alloc = testing.allocator;
    var ln: [1]Node = undefined;
    var lt: [1]Tab = undefined;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    // A NEW key but the SAME session: restoring both would hand the agent two
    // attaches for one PTY and blank the first window to make a copy of it.
    const local = [_]Window{reconcileWindow("window-1", "uuid-local", "sess-a", &ln, &lt)};
    const agent = [_]Window{reconcileWindow("window-1", "uuid-other", "sess-a", &an, &at)};

    const r = try reconcile(alloc, &local, &agent);
    defer alloc.free(r.windows);
    try testing.expectEqual(@as(usize, 1), r.windows.len);
    try testing.expectEqual(@as(usize, 0), r.adopted);
    try testing.expectEqualStrings("uuid-local", r.windows[0].uuid.?);
}

test "reconcile: session-less windows never collide with each other" {
    const alloc = testing.allocator;
    var ln: [1]Node = undefined;
    var lt: [1]Tab = undefined;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    // A viewer-only / never-agent-backed window claims no session, so the
    // "already claimed" rule must not fold two of them into one.
    const local = [_]Window{reconcileWindow("window-1", "uuid-local", null, &ln, &lt)};
    const agent = [_]Window{reconcileWindow("window-2", "uuid-agent", null, &an, &at)};

    const r = try reconcile(alloc, &local, &agent);
    defer alloc.free(r.windows);
    try testing.expectEqual(@as(usize, 2), r.windows.len);
    try testing.expectEqual(@as(usize, 1), r.adopted);
}

test "reconcile: both sides empty is an empty answer, not an error" {
    const alloc = testing.allocator;
    const r = try reconcile(alloc, &.{}, &.{});
    defer alloc.free(r.windows);
    try testing.expectEqual(@as(usize, 0), r.windows.len);
    try testing.expectEqual(@as(usize, 0), r.adopted);
}

/// A carried-key set holding gpa-duped copies of `keys`, for the T590 tests.
fn carriedSet(
    alloc: Allocator,
    keys: []const []const u8,
) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    errdefer set.deinit(alloc);
    for (keys) |k| try set.put(alloc, try alloc.dupe(u8, k), {});
    return set;
}

fn freeCarriedSet(alloc: Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.iterator();
    while (it.next()) |e| alloc.free(e.key_ptr.*);
    set.deinit(alloc);
}

test "T590: a carried manifest window rides along after the live capture" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ln: [1]Node = undefined;
    var lt: [1]Tab = undefined;
    var mn: [1]Node = undefined;
    var mt: [1]Tab = undefined;
    var on: [1]Node = undefined;
    var ot: [1]Tab = undefined;
    // The blank startup window is live; the manifest still holds the window the
    // agentless launch could not restore, plus one that was POSITIVELY dropped
    // (its key is not carried) and must stay dropped.
    const live = [_]Window{reconcileWindow("blank", "uuid-live", null, &ln, &lt)};
    const manifest = [_]Window{
        reconcileWindow("old", "uuid-old", "sess-a", &mn, &mt),
        reconcileWindow("dead", "uuid-dead", "sess-b", &on, &ot),
    };
    var carried = try carriedSet(alloc, &.{"uuid-old"});
    defer freeCarriedSet(alloc, &carried);

    const out = try mergeCarried(arena, alloc, &live, &manifest, &carried);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("uuid-live", out[0].uuid.?);
    try testing.expectEqualStrings("uuid-old", out[1].uuid.?);
    // The carry persists for the NEXT sync too — nothing adjudicated it.
    try testing.expectEqual(@as(usize, 1), carried.count());
}

test "T590: a carried key that is live again is adjudicated, not duplicated" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ln: [1]Node = undefined;
    var lt: [1]Tab = undefined;
    var mn: [1]Node = undefined;
    var mt: [1]Tab = undefined;
    // The carried window came back (a later Restore All): the live capture and
    // the on-disk manifest both hold its key.
    const live = [_]Window{reconcileWindow("back", "uuid-back", "sess-a", &ln, &lt)};
    const manifest = [_]Window{reconcileWindow("back", "uuid-back", "sess-a", &mn, &mt)};
    var carried = try carriedSet(alloc, &.{"uuid-back"});
    defer freeCarriedSet(alloc, &carried);

    const out = try mergeCarried(arena, alloc, &live, &manifest, &carried);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("back", out[0].id);
    // Adjudicated: the key left the carry set (and was freed), so a later
    // CLOSE of the window shrinks the manifest — it cannot resurrect.
    try testing.expectEqual(@as(usize, 0), carried.count());
}

test "T590: nothing carried returns the live capture untouched" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ln: [1]Node = undefined;
    var lt: [1]Tab = undefined;
    var mn: [1]Node = undefined;
    var mt: [1]Tab = undefined;
    const live = [_]Window{reconcileWindow("w", "uuid-w", null, &ln, &lt)};
    const manifest = [_]Window{reconcileWindow("old", "uuid-old", "sess-a", &mn, &mt)};
    var carried: std.StringHashMapUnmanaged(void) = .empty;
    defer carried.deinit(alloc);

    const out = try mergeCarried(arena, alloc, &live, &manifest, &carried);
    // Identity, not a copy: the healthy-agent sync path stays allocation-free.
    try testing.expectEqual(live[0..].ptr, out.ptr);
    try testing.expectEqual(@as(usize, 1), out.len);
}

test "T590: a duplicated manifest key is appended once" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    var bn: [1]Node = undefined;
    var bt: [1]Tab = undefined;
    const manifest = [_]Window{
        reconcileWindow("old", "uuid-old", "sess-a", &an, &at),
        reconcileWindow("old2", "uuid-old", "sess-a", &bn, &bt),
    };
    var carried = try carriedSet(alloc, &.{"uuid-old"});
    defer freeCarriedSet(alloc, &carried);

    const out = try mergeCarried(arena, alloc, &.{}, &manifest, &carried);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("old", out[0].id);
}

// -- pairWindows (T343) -------------------------------------------------------

test "T343: pairing follows the uuid when the live walk is reordered" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    var bn: [1]Node = undefined;
    var bt: [1]Tab = undefined;
    var cn: [1]Node = undefined;
    var ct: [1]Tab = undefined;
    // The capture, in the order the capture walk saw them.
    const captured = [_]Window{
        reconcileWindow("win-0", "uuid-a", "sess-a", &an, &at),
        reconcileWindow("win-1", "uuid-b", "sess-b", &bn, &bt),
        reconcileWindow("win-2", "uuid-c", "sess-c", &cn, &ct),
    };

    // …and the live list as the rebuild walk finds it: the middle window closed
    // while the re-dial blocked and the survivors shifted up. A positional join
    // would hand window C's tree to B; the key does not move.
    const live = [_][]const u8{ "uuid-a", "uuid-c" };
    const pairing = try pairWindows(alloc, &captured, &live);
    defer alloc.free(pairing);

    try testing.expectEqual(@as(usize, 2), pairing.len);
    try testing.expectEqual(@as(?usize, 0), pairing[0]);
    try testing.expectEqual(@as(?usize, 2), pairing[1]);
}

test "T343: a live window the capture never saw is skipped, not mispaired" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    const captured = [_]Window{reconcileWindow("win-0", "uuid-a", "sess-a", &an, &at)};

    // `uuid-new` was created after the capture (or is a quick terminal, or a
    // cross-machine window — everything the capture filters out looks the same
    // from here, which is the point of dropping the hand-copied skip rule).
    const live = [_][]const u8{ "uuid-new", "uuid-a" };
    const pairing = try pairWindows(alloc, &captured, &live);
    defer alloc.free(pairing);

    try testing.expect(pairing[0] == null);
    try testing.expectEqual(@as(?usize, 0), pairing[1]);
}

test "T343: a captured window is handed out at most once" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    const captured = [_]Window{reconcileWindow("win-0", "uuid-dup", "sess-a", &an, &at)};

    const live = [_][]const u8{ "uuid-dup", "uuid-dup" };
    const pairing = try pairWindows(alloc, &captured, &live);
    defer alloc.free(pairing);

    try testing.expectEqual(@as(?usize, 0), pairing[0]);
    // The second claimant is skipped rather than rebuilt from a tree that is
    // already someone else's.
    try testing.expect(pairing[1] == null);
}

test "T343: an empty capture pairs nothing and an empty live walk is empty" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    const captured = [_]Window{reconcileWindow("win-0", "uuid-a", "sess-a", &an, &at)};

    const live = [_][]const u8{"uuid-a"};
    const none = try pairWindows(alloc, &.{}, &live);
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 1), none.len);
    try testing.expect(none[0] == null);

    const empty = try pairWindows(alloc, &captured, &.{});
    defer alloc.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "T343: a pre-T338 capture with no uuid still pairs on its id" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    var at: [1]Tab = undefined;
    const captured = [_]Window{reconcileWindow("window-1", null, "sess-a", &an, &at)};

    const live = [_][]const u8{"window-1"};
    const pairing = try pairWindows(alloc, &captured, &live);
    defer alloc.free(pairing);
    try testing.expectEqual(@as(?usize, 0), pairing[0]);
}

// -- pairTabs (T1048) ---------------------------------------------------------

/// A captured tab with the given uuid and a one-leaf tree, for the pairing
/// tests below. The nodes never matter here — only the key does.
fn pairTestTab(uuid: ?[]const u8, nodes: []Node) Tab {
    nodes[0] = .{ .leaf = .{} };
    return .{ .nodes = nodes, .uuid = uuid };
}

test "T1048: tab pairing follows the uuid when a tab closes mid-recovery" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    var bn: [1]Node = undefined;
    var cn: [1]Node = undefined;
    // Three single-pane tabs — the case `capturedNodeShapes` cannot tell apart,
    // which is why the shape check was never the backstop it looked like.
    const captured = [_]Tab{
        pairTestTab("tab-a", &an),
        pairTestTab("tab-b", &bn),
        pairTestTab("tab-c", &cn),
    };

    // The middle tab was closed while `reconnectForRecovery` blocked, so the
    // survivors shifted up. A positional join would rebuild C from B's tree.
    const live = [_][]const u8{ "tab-a", "tab-c" };
    const pairing = try pairTabs(alloc, &captured, &live);
    defer alloc.free(pairing);

    try testing.expectEqual(@as(usize, 2), pairing.len);
    try testing.expectEqual(@as(?usize, 0), pairing[0]);
    try testing.expectEqual(@as(?usize, 2), pairing[1]);
}

test "T1048: a tab opened after the capture is skipped, not mispaired" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    const captured = [_]Tab{pairTestTab("tab-a", &an)};

    const live = [_][]const u8{ "tab-new", "tab-a" };
    const pairing = try pairTabs(alloc, &captured, &live);
    defer alloc.free(pairing);

    try testing.expect(pairing[0] == null);
    try testing.expectEqual(@as(?usize, 0), pairing[1]);
}

test "T1048: a reordered tab keeps its own tree" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    var bn: [1]Node = undefined;
    const captured = [_]Tab{
        pairTestTab("tab-a", &an),
        pairTestTab("tab-b", &bn),
    };

    // Dragged into the other order between the two walks.
    const live = [_][]const u8{ "tab-b", "tab-a" };
    const pairing = try pairTabs(alloc, &captured, &live);
    defer alloc.free(pairing);

    try testing.expectEqual(@as(?usize, 1), pairing[0]);
    try testing.expectEqual(@as(?usize, 0), pairing[1]);
}

test "T1048: a captured tab is handed out at most once" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    const captured = [_]Tab{pairTestTab("tab-dup", &an)};

    const live = [_][]const u8{ "tab-dup", "tab-dup" };
    const pairing = try pairTabs(alloc, &captured, &live);
    defer alloc.free(pairing);

    try testing.expectEqual(@as(?usize, 0), pairing[0]);
    try testing.expect(pairing[1] == null);
}

test "T1048: a pre-T1048 capture with no tab uuid pairs nothing" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    const captured = [_]Tab{pairTestTab(null, &an)};

    // An identity-less captured tab must never match, including against a live
    // tab whose own key is somehow empty — otherwise "no identity" would pair
    // with "no identity" and reintroduce the positional guess.
    const live = [_][]const u8{ "tab-a", "" };
    const pairing = try pairTabs(alloc, &captured, &live);
    defer alloc.free(pairing);

    try testing.expect(pairing[0] == null);
    try testing.expect(pairing[1] == null);
}

test "T1048: an empty capture pairs nothing and an empty live walk is empty" {
    const alloc = testing.allocator;
    var an: [1]Node = undefined;
    const captured = [_]Tab{pairTestTab("tab-a", &an)};

    const live = [_][]const u8{"tab-a"};
    const none = try pairTabs(alloc, &.{}, &live);
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 1), none.len);
    try testing.expect(none[0] == null);

    const empty = try pairTabs(alloc, &captured, &.{});
    defer alloc.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
