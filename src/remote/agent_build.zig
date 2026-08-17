//! Facts about a `ghoztty-agent` BUILD STAMP, shared by every seat that has to
//! reason about one (T662).
//!
//! The agent outlives the app on purpose, so "which build is actually running"
//! is a question with a real answer that nobody could ask. Two consumers need
//! it and they must never disagree:
//!
//!  - `apprt/win32/agent_upgrade.zig` — the POLICY (restart now / confirm /
//!    leave alone). It answers "should the app do something about this?"
//!  - `cli/sessions.zig` — `+sessions --agent`, which answers "how far behind
//!    is the running agent?" for a human or a script, on both platforms and
//!    with the app not running.
//!
//! The staleness rule lived only in the win32 policy module until T662 needed
//! it from the shared CLI; it is here now so there is exactly ONE authority on
//! what "stale" means, rather than a second spelling of it that can drift.
//! Everything here is pure — no allocation, no I/O, no clock.
//!
//! A stamp is `YYYYMMDD-<git short hash>`, or the literal `dev` when git was
//! unavailable at build time.

const std = @import("std");

// =============================================================================
// Stamps
// =============================================================================

/// Parse `ghoztty-agent --version` output ("ghoztty-agent 20260730-e69d41755")
/// into just the stamp: the LAST whitespace-separated token of the first
/// non-empty line. Returns a slice INTO `out` (no allocation), or null when
/// there is no such token — an empty or whitespace-only output is "unknown",
/// which every caller turns into "don't judge".
pub fn parseVersionOutput(out: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        var last: ?[]const u8 = null;
        while (it.next()) |tok| last = tok;
        return last;
    }
    return null;
}

/// The `YYYYMMDD` date prefix of a stamp as a number, or 0 when it has none
/// (`dev`, or any stamp shape we don't recognize). 0 compares as "no opinion".
fn datePrefix(stamp: []const u8) u64 {
    var n: u64 = 0;
    var digits: usize = 0;
    for (stamp) |c| {
        if (!std.ascii.isDigit(c)) break;
        // A stamp with an absurd digit run is not a date; stop rather than
        // overflow.
        if (digits >= 18) break;
        n = n * 10 + (c - '0');
        digits += 1;
    }
    return if (digits == 0) 0 else n;
}

/// True iff stamp `a` is a NEWER build than `b`, ordered by the `YYYYMMDD`
/// prefix. Equal (or unparseable) dates ⇒ false, so an equal or unknown date
/// never *blocks* a refresh — stamp equality decides that — while a genuinely
/// newer running agent is never downgraded.
pub fn stampIsNewer(a: []const u8, b: []const u8) bool {
    return datePrefix(a) > datePrefix(b);
}

/// Is the running agent an OLDER build than the one the app ships beside?
///
/// `running == null` ⇒ an agent too old to advertise a stamp in its HELLO ⇒
/// stale (it predates the whole feature). Exact match ⇒ current. Newer than
/// bundled ⇒ NOT stale (never downgrade).
pub fn isStale(running: ?[]const u8, bundled: []const u8) bool {
    const r = running orelse return true;
    if (r.len == 0) return true;
    if (std.mem.eql(u8, r, bundled)) return false;
    if (stampIsNewer(r, bundled)) return false;
    return true;
}

/// What to print for a stamp that may be absent. `running == null` is an agent
/// too old to advertise one; `bundled == null` is an unreadable binary.
pub fn stampForLog(stamp: ?[]const u8) []const u8 {
    const s = stamp orelse return "<pre-versioned>";
    return if (s.len == 0) "<pre-versioned>" else s;
}

// =============================================================================
// Calendar distance
// =============================================================================

/// The `YYYYMMDD` head of a stamp as a calendar date, or null when the stamp
/// does not start with exactly eight digits followed by a separator or the end
/// (`dev`, `1.2.3`, `202607301` …), or when those digits are not a real date.
///
/// Stricter than `datePrefix` on purpose: that one only has to ORDER two
/// stamps, and a garbage prefix that orders low is harmless. This one is
/// subtracted to produce a number a human reads as "days behind", and a
/// confidently wrong number there is worse than no number at all.
pub fn stampDate(stamp: []const u8) ?Date {
    if (stamp.len < 8) return null;
    for (stamp[0..8]) |c| if (!std.ascii.isDigit(c)) return null;
    if (stamp.len > 8 and std.ascii.isDigit(stamp[8])) return null;

    const y = std.fmt.parseInt(u16, stamp[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, stamp[4..6], 10) catch return null;
    const d = std.fmt.parseInt(u8, stamp[6..8], 10) catch return null;
    if (m < 1 or m > 12) return null;
    if (d < 1 or d > 31) return null;
    return .{ .year = y, .month = m, .day = d };
}

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    /// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`), so two dates
    /// can simply be subtracted.
    pub fn epochDay(self: Date) i64 {
        const m: i64 = self.month;
        const y: i64 = @as(i64, self.year) - @as(i64, if (m <= 2) 1 else 0);
        const era = @divFloor(y, 400);
        const yoe = y - era * 400; // [0, 399]
        const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) +
            @as(i64, self.day) - 1;
        const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }
};

/// How many CALENDAR DAYS the running build's stamp is behind the bundled
/// one's, or null when either stamp carries no usable date (`dev`, a
/// pre-versioned agent, an unreadable bundled binary).
///
/// Never negative: a running agent that is NEWER is not "behind" by a negative
/// amount, it is a different state entirely (`Status.newer`), and a negative
/// number in that field would read as a countdown.
pub fn daysBehind(running: ?[]const u8, bundled: ?[]const u8) ?i64 {
    const r = stampDate(running orelse return null) orelse return null;
    const b = stampDate(bundled orelse return null) orelse return null;
    const delta = b.epochDay() - r.epochDay();
    return if (delta > 0) delta else null;
}

// =============================================================================
// Status
// =============================================================================

/// Where the running agent stands relative to the build shipped beside the app.
/// The tokens are a machine contract (`+sessions --agent --json`), never prose.
pub const Status = enum {
    /// No agent is running at all, so nothing is behind: the next persistent
    /// session starts the bundled build. Never returned by `classify`, whose
    /// inputs are two stamps — the caller knows whether it reached an agent.
    not_running,
    /// The bundled binary could not be read, so there is nothing to compare
    /// against. Never a judgement on a guess.
    unknown,
    /// The running agent is exactly the build shipped beside this app.
    current,
    /// The running agent is an OLDER build (or predates build stamps).
    stale,
    /// The running agent is NEWER than the bundled one — a dev agent, or an app
    /// rolled back under a newer agent. Never downgraded.
    newer,

    pub fn token(self: Status) []const u8 {
        return switch (self) {
            .not_running => "not_running",
            .unknown => "unknown",
            .current => "current",
            .stale => "stale",
            .newer => "newer",
        };
    }
};

/// The comparison, and only the comparison. `isStale` stays the single
/// authority on staleness; this classifies WHY a not-stale agent is fine, so
/// the two can never disagree.
pub fn classify(running: ?[]const u8, bundled: ?[]const u8) Status {
    const b = bundled orelse return .unknown;
    if (b.len == 0) return .unknown;
    if (isStale(running, b)) return .stale;
    // Not stale ⇒ `running` is non-null, non-empty, and either equal to `b` or
    // newer than it. Those are the only two ways to get here.
    const r = running orelse "";
    return if (std.mem.eql(u8, r, b)) .current else .newer;
}

// =============================================================================
// The CLI report (`+sessions --agent`)
// =============================================================================

/// Everything the CLI learned by dialing (or failing to find) the agent.
pub const Input = struct {
    /// Did we reach a running agent at all? False ⇒ `.not_running`, whatever
    /// the stamps say.
    agent_running: bool = false,
    /// The stamp the running agent advertised in its HELLO. Null with
    /// `agent_running == true` means a pre-versioned agent — which is stale.
    running: ?[]const u8 = null,
    /// The stamp of the `ghoztty-agent` binary beside this CLI, or null when it
    /// could not be read.
    bundled: ?[]const u8 = null,
    live_sessions: ?u32 = null,
    total_sessions: ?u32 = null,
    agent_pid: ?i64 = null,
    /// The running agent advertised `capability.agent_handoff` — it replaces
    /// ITSELF with a newer on-disk build, carrying every holder-backed session
    /// across, so nobody has to restart it (T907).
    handoff_capable: bool = false,
    /// How many LIVE sessions the agent still owns directly (`holder_backed ==
    /// false`). Each one holds a handoff back. Null when the roster could not be
    /// read at all, which is NOT the same as zero and must not read as "ready".
    legacy_sessions: ?u32 = null,
};

/// Whether a stale agent will fix itself, and what it is waiting for (T907).
///
/// Three states rather than a bool, because "it cannot" and "it will, once these
/// close" lead a reader to completely different next steps — and the old
/// `next:` line, which promised a restart at the next quiet moment, is a lie in
/// both of the new ones.
pub const Handoff = enum {
    /// This agent does not replace itself: an older build, or a seat where the
    /// mechanism has not landed. The pre-T907 answer applies.
    unsupported,
    /// It replaces itself, and nothing is in the way.
    ready,
    /// It replaces itself, but sessions it owns directly have to close first.
    draining,

    pub fn token(self: Handoff) []const u8 {
        return @tagName(self);
    }
};

/// Classify the handoff state from what the CLI observed. `legacy == null` (the
/// roster was unreadable) is `draining` rather than `ready`: claiming an upgrade
/// is about to happen, when we could not check what is holding it back, is the
/// direction that reads as a promise and is not one.
pub fn handoffState(capable: bool, legacy: ?u32) Handoff {
    if (!capable) return .unsupported;
    const n = legacy orelse return .draining;
    return if (n == 0) .ready else .draining;
}

/// The answer to "how far behind is the running agent?", in one struct.
pub const Report = struct {
    status: Status,
    running: ?[]const u8,
    bundled: ?[]const u8,
    days_behind: ?i64,
    live_sessions: ?u32,
    total_sessions: ?u32,
    agent_pid: ?i64,
    handoff: Handoff,
    legacy_sessions: ?u32,

    /// The human rendering: four aligned rows, the last of which only appears
    /// when there is something to do about it. Written to `w` so the CLI does
    /// not have to know the shape and a test does not need a process.
    pub fn write(self: Report, w: *std.Io.Writer) !void {
        try w.print("running:  {s}", .{switch (self.status) {
            .not_running => "(no agent running)",
            else => if (self.running) |r| r else "(pre-versioned)",
        }});
        if (self.agent_pid) |pid| try w.print("  (pid {d})", .{pid});
        try w.writeAll("\n");

        try w.print("bundled:  {s}\n", .{self.bundled orelse "(unknown)"});
        try w.writeAll("status:   ");
        try self.writeStatus(w);
        try w.writeAll("\n");

        if (self.status == .stale) {
            try w.writeAll("next:     ");
            switch (self.handoff) {
                .unsupported => try w.writeAll(
                    "Ghoztty restarts it onto the bundled build when no sessions " ++
                        "are open, or when you confirm the restart it offers.\n",
                ),
                // T907. Deliberately says "no session closes" out loud: the whole
                // reason someone runs this command is to find out what an update
                // is going to cost them.
                .ready => try w.writeAll(
                    "It updates itself to the bundled build on its own, and no " ++
                        "session closes.\n",
                ),
                .draining => {
                    try w.writeAll(
                        "It updates itself to the bundled build on its own, and no " ++
                            "session closes — but not yet: ",
                    );
                    if (self.legacy_sessions) |n| {
                        try w.print(
                            "{d} older session{s} still owned by the agent " ++
                                "must close first.\n",
                            .{ n, if (n == 1) "" else "s" },
                        );
                    } else {
                        try w.writeAll("its session roster could not be read.\n");
                    }
                },
            }
        }
    }

    /// The status row's own text: the token, then the clause that makes it
    /// actionable. Split out so the token and its explanation cannot drift.
    pub fn writeStatus(self: Report, w: *std.Io.Writer) !void {
        try w.writeAll(self.status.token());
        switch (self.status) {
            .not_running => try w.writeAll(
                " - the next persistent session starts the bundled build",
            ),
            .unknown => try w.writeAll(
                " - the bundled agent binary could not be read, so there is nothing to compare against",
            ),
            .current => {},
            .newer => try w.writeAll(
                " - the running agent is a NEWER build than the one bundled here (never downgraded)",
            ),
            .stale => {
                if (self.days_behind) |d| {
                    try w.print(" - {d} day{s} behind", .{ d, if (d == 1) "" else "s" });
                } else {
                    try w.writeAll(" - the running agent predates build stamps");
                }
                if (self.live_sessions) |live| {
                    try w.print(", {d} live session{s}", .{ live, if (live == 1) "" else "s" });
                }
            },
        }
    }
};

/// Turn what the CLI observed into the report it prints. Pure, so every arm is
/// reachable from a unit test rather than only from a box with an old agent on
/// it.
pub fn report(in: Input) Report {
    const status: Status = if (!in.agent_running) .not_running else classify(in.running, in.bundled);
    return .{
        .status = status,
        .running = in.running,
        .bundled = in.bundled,
        // Only a stale agent is "behind" — a newer or current one has no
        // distance to report, and `not_running`/`unknown` have nothing to
        // measure.
        .days_behind = if (status == .stale) daysBehind(in.running, in.bundled) else null,
        .live_sessions = in.live_sessions,
        .total_sessions = in.total_sessions,
        .agent_pid = in.agent_pid,
        .handoff = handoffState(in.handoff_capable, in.legacy_sessions),
        .legacy_sessions = in.legacy_sessions,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "parseVersionOutput: the stamp is the last token of the first real line" {
    try testing.expectEqualStrings(
        "20260730-e69d41755",
        parseVersionOutput("ghoztty-agent 20260730-e69d41755\n").?,
    );
    // CRLF is the norm when the child writes through a Windows console.
    try testing.expectEqualStrings(
        "20260730-e69d41755",
        parseVersionOutput("ghoztty-agent 20260730-e69d41755\r\n").?,
    );
    try testing.expectEqualStrings("dev", parseVersionOutput("\n\n  ghoztty-agent dev  \n").?);
    try testing.expectEqualStrings(
        "20260101-abcdef012",
        parseVersionOutput("ghoztty-agent 20260101-abcdef012\nsome warning\n").?,
    );
    try testing.expect(parseVersionOutput("") == null);
    try testing.expect(parseVersionOutput("   \r\n\t\n") == null);
}

test "stampIsNewer orders by the date prefix only" {
    try testing.expect(stampIsNewer("20260730-aaa", "20260719-zzz"));
    try testing.expect(!stampIsNewer("20260719-zzz", "20260730-aaa"));
    // Same date, different hash ⇒ not newer (equality is the caller's business).
    try testing.expect(!stampIsNewer("20260730-aaa", "20260730-bbb"));
    // A dateless stamp has no opinion in either direction against another
    // dateless one, and always loses to a dated one.
    try testing.expect(!stampIsNewer("dev", "dev"));
    try testing.expect(!stampIsNewer("dev", "20260101-a"));
    try testing.expect(stampIsNewer("20260101-a", "dev"));
}

test "isStale: pre-versioned is stale, newer is not, exact match is current" {
    try testing.expect(isStale(null, "20260730-e69d41755"));
    try testing.expect(isStale("", "20260730-e69d41755"));
    try testing.expect(!isStale("20260730-e69d41755", "20260730-e69d41755"));
    try testing.expect(isStale("20260719-574fe0805", "20260730-e69d41755"));
    // Same day, different build ⇒ still stale (any agent-side change counts).
    try testing.expect(isStale("20260730-aaaaaaaaa", "20260730-e69d41755"));
    try testing.expect(!isStale("20260731-aaaaaaaaa", "20260730-e69d41755"));
}

test "stampDate accepts exactly eight leading digits and a real date" {
    const d = stampDate("20260730-e69d41755").?;
    try testing.expectEqual(@as(u16, 2026), d.year);
    try testing.expectEqual(@as(u8, 7), d.month);
    try testing.expectEqual(@as(u8, 30), d.day);
    // A bare date with no hash is still a date.
    try testing.expect(stampDate("20260730") != null);

    // Everything that is not one. A ninth digit is the important one: it means
    // the leading run is not a YYYYMMDD at all, and truncating it to eight
    // would invent a date the stamp never claimed.
    try testing.expect(stampDate("202607301-abc") == null);
    try testing.expect(stampDate("dev") == null);
    try testing.expect(stampDate("") == null);
    try testing.expect(stampDate("2026073") == null);
    try testing.expect(stampDate("2026-07-30") == null);
    // Digits that are not a date.
    try testing.expect(stampDate("20261330-abc") == null);
    try testing.expect(stampDate("20260732-abc") == null);
    try testing.expect(stampDate("20260700-abc") == null);
}

test "Date.epochDay matches known days and spans month/year/leap boundaries" {
    try testing.expectEqual(@as(i64, 0), (Date{ .year = 1970, .month = 1, .day = 1 }).epochDay());
    try testing.expectEqual(@as(i64, 19723), (Date{ .year = 2024, .month = 1, .day = 1 }).epochDay());
    // 2024 is a leap year: Feb 28 → Mar 1 is two days, not one.
    const feb28 = (Date{ .year = 2024, .month = 2, .day = 28 }).epochDay();
    const mar01 = (Date{ .year = 2024, .month = 3, .day = 1 }).epochDay();
    try testing.expectEqual(@as(i64, 2), mar01 - feb28);
    // 2026 is not.
    const feb28_26 = (Date{ .year = 2026, .month = 2, .day = 28 }).epochDay();
    const mar01_26 = (Date{ .year = 2026, .month = 3, .day = 1 }).epochDay();
    try testing.expectEqual(@as(i64, 1), mar01_26 - feb28_26);
    // A year boundary is one day, like any other.
    const dec31 = (Date{ .year = 2025, .month = 12, .day = 31 }).epochDay();
    const jan01 = (Date{ .year = 2026, .month = 1, .day = 1 }).epochDay();
    try testing.expectEqual(@as(i64, 1), jan01 - dec31);
}

test "daysBehind counts calendar days and never goes negative" {
    try testing.expectEqual(@as(?i64, 11), daysBehind("20260719-aaa", "20260730-bbb"));
    // Across a month boundary, which is the shape that catches naive
    // subtraction of the YYYYMMDD integers (20260801 - 20260730 = 71).
    try testing.expectEqual(@as(?i64, 2), daysBehind("20260730-aaa", "20260801-bbb"));
    // Across a year boundary.
    try testing.expectEqual(@as(?i64, 2), daysBehind("20251231-aaa", "20260102-bbb"));

    // Same day (different hash) is not a number of days behind — the agent is
    // stale, but "0 days behind" reads as "not behind".
    try testing.expectEqual(@as(?i64, null), daysBehind("20260730-aaa", "20260730-bbb"));
    // Newer running agent: not behind by a negative amount.
    try testing.expectEqual(@as(?i64, null), daysBehind("20260801-aaa", "20260730-bbb"));
    // Anything without a usable date on either side.
    try testing.expectEqual(@as(?i64, null), daysBehind(null, "20260730-bbb"));
    try testing.expectEqual(@as(?i64, null), daysBehind("dev", "20260730-bbb"));
    try testing.expectEqual(@as(?i64, null), daysBehind("20260719-aaa", null));
    try testing.expectEqual(@as(?i64, null), daysBehind("20260719-aaa", "dev"));
}

test "classify agrees with isStale on every input" {
    const stamps = [_]?[]const u8{ null, "", "dev", "20260719-aaa", "20260730-e69d41755", "20260801-zzz" };
    const bundles = [_]?[]const u8{ null, "", "dev", "20260730-e69d41755" };
    for (stamps) |r| for (bundles) |b| {
        const s = classify(r, b);
        // `not_running` is the caller's state, never a comparison outcome.
        try testing.expect(s != .not_running);
        if (b) |bb| if (bb.len > 0) {
            try testing.expectEqual(isStale(r, bb), s == .stale);
        };
        if (b == null or b.?.len == 0) try testing.expectEqual(Status.unknown, s);
    };
}

test "Status tokens are distinct and machine-shaped" {
    // These are a contract (`--json`), so a token that collided with another —
    // or grew a space — would silently break a script that switches on it.
    const all = [_]Status{ .not_running, .unknown, .current, .stale, .newer };
    for (all, 0..) |a, i| {
        try testing.expect(a.token().len > 0);
        for (a.token()) |c| try testing.expect(c == '_' or std.ascii.isLower(c));
        for (all[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.token(), b.token()));
    }
}

test "report: a stale agent names the distance and the live sessions" {
    const r = report(.{
        .agent_running = true,
        .running = "20260719-574fe0805",
        .bundled = "20260730-e69d41755",
        .live_sessions = 4,
        .total_sessions = 6,
        .agent_pid = 1234,
    });
    try testing.expectEqual(Status.stale, r.status);
    try testing.expectEqual(@as(?i64, 11), r.days_behind);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try r.write(&out.writer);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "running:  20260719-574fe0805  (pid 1234)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bundled:  20260730-e69d41755") != null);
    try testing.expect(std.mem.indexOf(u8, text, "status:   stale - 11 days behind, 4 live sessions") != null);
    // The whole point of the row: what happens next, without reading the docs.
    try testing.expect(std.mem.indexOf(u8, text, "next:") != null);
}

test "report: only a stale agent carries a distance or a next step" {
    const cases = [_]Input{
        .{ .agent_running = true, .running = "20260730-e69d41755", .bundled = "20260730-e69d41755" },
        .{ .agent_running = true, .running = "20260801-zzz", .bundled = "20260730-e69d41755" },
        .{ .agent_running = true, .running = "20260719-aaa", .bundled = null },
        .{ .agent_running = false, .bundled = "20260730-e69d41755" },
    };
    const want = [_]Status{ .current, .newer, .unknown, .not_running };
    for (cases, want) |in, expected| {
        const r = report(in);
        try testing.expectEqual(expected, r.status);
        try testing.expectEqual(@as(?i64, null), r.days_behind);

        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try r.write(&out.writer);
        try testing.expect(std.mem.indexOf(u8, out.written(), "next:") == null);
    }
}

test "report: a pre-versioned agent is stale without inventing a distance" {
    // An agent too old to advertise a stamp is by definition older than any app
    // that knows to look for one — but there is no date to subtract, so the
    // status says WHY rather than printing a made-up number.
    const r = report(.{
        .agent_running = true,
        .running = null,
        .bundled = "20260730-e69d41755",
        .live_sessions = 1,
    });
    try testing.expectEqual(Status.stale, r.status);
    try testing.expectEqual(@as(?i64, null), r.days_behind);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try r.write(&out.writer);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "running:  (pre-versioned)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "predates build stamps, 1 live session") != null);
    // Singular, not "1 live sessions".
    try testing.expect(std.mem.indexOf(u8, text, "1 live sessions") == null);
}

test "report: no agent at all is an answer, not a blank" {
    const r = report(.{ .agent_running = false, .bundled = "20260730-e69d41755" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try r.write(&out.writer);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "running:  (no agent running)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not_running") != null);
    // Nothing is running, so nothing has a pid.
    try testing.expect(std.mem.indexOf(u8, text, "pid") == null);
}

test "handoffState: only a capable agent with a KNOWN, empty drain is ready" {
    try testing.expectEqual(Handoff.unsupported, handoffState(false, 0));
    try testing.expectEqual(Handoff.unsupported, handoffState(false, null));
    try testing.expectEqual(Handoff.unsupported, handoffState(false, 4));
    try testing.expectEqual(Handoff.ready, handoffState(true, 0));
    try testing.expectEqual(Handoff.draining, handoffState(true, 1));
    // Capable but we could not read the roster: `draining`, never `ready`.
    // "Your update is about to happen and costs nothing" is a promise, and we
    // did not check the one thing that could make it false.
    try testing.expectEqual(Handoff.draining, handoffState(true, null));

    // Machine tokens, like `Status.token`.
    for ([_]Handoff{ .unsupported, .ready, .draining }) |h| {
        try testing.expect(h.token().len > 0);
        for (h.token()) |c| try testing.expect(c == '_' or std.ascii.isLower(c));
    }
}

test "report: a self-replacing agent says no session closes" {
    const r = report(.{
        .agent_running = true,
        .running = "20260719-574fe0805",
        .bundled = "20260730-e69d41755",
        .live_sessions = 4,
        .handoff_capable = true,
        .legacy_sessions = 0,
    });
    try testing.expectEqual(Status.stale, r.status);
    try testing.expectEqual(Handoff.ready, r.handoff);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try r.write(&out.writer);
    const text = out.written();
    // The whole reason someone runs this: what is an update going to cost me?
    try testing.expect(std.mem.indexOf(u8, text, "updates itself to the bundled build on its own") != null);
    try testing.expect(std.mem.indexOf(u8, text, "no session closes") != null);
    // And it must NOT still be offering the old, now-wrong promise.
    try testing.expect(std.mem.indexOf(u8, text, "confirm the restart") == null);
}

test "report: a draining agent names what it is waiting for" {
    const draining = report(.{
        .agent_running = true,
        .running = "20260719-574fe0805",
        .bundled = "20260730-e69d41755",
        .live_sessions = 3,
        .handoff_capable = true,
        .legacy_sessions = 2,
    });
    try testing.expectEqual(Handoff.draining, draining.handoff);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try draining.write(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "2 older sessions still owned by the agent must close first") != null);

    // Singular, and the unreadable-roster arm, which must say so rather than
    // print a number it does not have.
    const one = report(.{
        .agent_running = true,
        .running = "20260719-574fe0805",
        .bundled = "20260730-e69d41755",
        .handoff_capable = true,
        .legacy_sessions = 1,
    });
    var out2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out2.deinit();
    try one.write(&out2.writer);
    try testing.expect(std.mem.indexOf(u8, out2.written(), "1 older session still owned") != null);

    const blind = report(.{
        .agent_running = true,
        .running = "20260719-574fe0805",
        .bundled = "20260730-e69d41755",
        .handoff_capable = true,
    });
    var out3: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out3.deinit();
    try blind.write(&out3.writer);
    try testing.expect(std.mem.indexOf(u8, out3.written(), "roster could not be read") != null);
}

test "report: an older agent keeps the pre-T907 next step, word for word" {
    // Standing down on an agent that will never hand itself off means it is
    // never upgraded at all, so the old sentence has to survive exactly.
    const r = report(.{
        .agent_running = true,
        .running = "20260719-574fe0805",
        .bundled = "20260730-e69d41755",
        .live_sessions = 2,
        .legacy_sessions = 2,
    });
    try testing.expectEqual(Handoff.unsupported, r.handoff);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try r.write(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "or when you confirm the restart it offers") != null);
}

test "stampForLog never yields an empty field in a log line" {
    try testing.expectEqualStrings("<pre-versioned>", stampForLog(null));
    try testing.expectEqualStrings("<pre-versioned>", stampForLog(""));
    try testing.expectEqualStrings("20260730-e69d41755", stampForLog("20260730-e69d41755"));
}
