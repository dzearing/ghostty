//! Pure model + geometry for the machine chooser's SESSION ROSTER (T318, the
//! first child of the T146 split).
//!
//! Mac's chooser expands the selected machine into a per-session list in the
//! detail pane: a liveness dot, a real-name label, activity/status badges,
//! cwd + command sublines, and a Kill button
//! (`MachineChooserView.swift:544`, `:608-730`). Everything about WHAT a row
//! says and WHERE its pieces sit lives here so it runs in the none-runtime test
//! lane; `MachineChooser.zig` keeps the GDI calls and the RPC.
//!
//! Two rules from the design system shape the geometry (§1, §3.1): every gap is
//! on the 4 DIP scale, and a session row is a CARD in the detail pane — radius
//! 8, not the list item's 4.

const std = @import("std");

const chooser_cpu = @import("chooser_cpu.zig");
const chooser_layout = @import("chooser_layout.zig");
const chooser_rows = @import("chooser_rows.zig");
const chrome_theme = @import("chrome_theme.zig");
const color_math = @import("color_math.zig");
const icon_button = @import("icon_button.zig");
const type_ramp = @import("type_ramp.zig");

pub const Rgb = color_math.Rgb;
pub const Rect = chooser_layout.Rect;

// ---------------------------------------------------------------------
// The row model
// ---------------------------------------------------------------------

/// One session as the roster sees it — the display-relevant subset of
/// `remote/connection.zig`'s `OwnedSession` (`:660`), copied into a
/// platform-free struct so this module never imports the transport.
///
/// Windows reads that struct DIRECTLY off the wire, so unlike Mac (whose C API
/// dropped the field — T322) `relaunchable` here carries its real value.
pub const Session = struct {
    id: []const u8 = "",
    alive: bool = false,
    /// A dead-but-relaunchable reboot-floor tombstone (§5.4): the recorded
    /// argv/cwd can revive it, so it is still a session worth listing.
    relaunchable: bool = false,
    exit_code: ?i64 = null,
    attached: bool = false,
    /// `idle` | `busy` | `needs_input`.
    activity: []const u8 = "idle",
    pid: i64 = 0,
    title: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    argv: ?[]const u8 = null,
};

/// A session worth showing: still alive (attachable) or a relaunchable
/// tombstone (revivable via RELAUNCH). A dead, non-relaunchable tombstone is an
/// unreconnectable dead end — filtered out as a client-side backstop to the
/// agent's own reap, exactly as Mac's `isConnectable`
/// (`SessionBrowserProbe.swift:56`) intends.
///
/// The Mac comment and the Mac behavior disagree today because its C API omits
/// `relaunchable` (T322), which collapses the test to `alive` and hides the
/// resumable tombstones the term exists to keep. Windows takes the field at its
/// word: the divergence is deliberate, and it is the side that matches what
/// both comments say the rule is.
pub fn isConnectable(s: Session) bool {
    return s.alive or s.relaunchable;
}

/// The last component of a path, for the cwd rung of the label ladder. Handles
/// both separators (a Windows agent reports `\`, a WSL one `/`) and ignores a
/// trailing separator, so `C:\dev\ghoztty\` still names `ghoztty` and a drive
/// root `C:\` names `C:`. A path that is NOTHING but separators (`/`) has no
/// component at all, so the whole string is returned rather than an empty
/// label.
pub fn baseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and isSep(path[end - 1])) end -= 1;
    if (end == 0) return path;
    var start = end;
    while (start > 0 and !isSep(path[start - 1])) start -= 1;
    return path[start..end];
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// A human label for a session row, most-current first — the exact ladder Mac
/// documents at `SessionBrowserProbe.swift:68-75`:
///
/// 1. `live_title` — the title of an OPEN pane bound to this session, read
///    from the app, so a pane rename shows immediately (the agent does not
///    track renames).
/// 2. the agent-reported `title` (captured at session creation / relaunch).
/// 3. `persisted_title` — the saved session-layout title, so a relaunched but
///    not-yet-retitled session still has a name across app restarts.
/// 4. the last component of the cwd, then the command, and finally
/// 5. the real pid. That last rung is deliberate: an opaque session id READS
///    like a number and means nothing, so the pid — a number that can actually
///    be looked up — is shown instead.
///
/// The first four rungs borrow their storage; only the pid rung writes into
/// `buf` (which needs ~24 bytes). An unformattable pid degrades to the literal
/// `"session"` rather than failing the row.
pub fn label(
    buf: []u8,
    s: Session,
    live_title: ?[]const u8,
    persisted_title: ?[]const u8,
) []const u8 {
    if (nonEmpty(live_title)) |t| return t;
    if (nonEmpty(s.title)) |t| return t;
    if (nonEmpty(persisted_title)) |t| return t;
    if (nonEmpty(s.cwd)) |c| return baseName(c);
    if (nonEmpty(s.argv)) |a| return a;
    return std.fmt.bufPrint(buf, "pid {d}", .{s.pid}) catch "session";
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

/// A dead session's exit label — Mac's `exitedLabel`
/// (`MachineChooserView.swift:726`). Writes into `buf` for the coded form.
pub fn exitedLabel(buf: []u8, exit_code: ?i64) []const u8 {
    const code = exit_code orelse return "exited";
    return std.fmt.bufPrint(buf, "exited ({d})", .{code}) catch "exited";
}

/// "3 sessions" / "1 session" — the count Mac puts in the detail subtitle
/// (`MachineChooserView.swift:522-524`). Null when the roster has not loaded,
/// which is the caller's business, not this function's.
pub fn countLabel(buf: []u8, n: usize) []const u8 {
    const unit = if (n == 1) "session" else "sessions";
    return std.fmt.bufPrint(buf, "{d} {s}", .{ n, unit }) catch "sessions";
}

// ---------------------------------------------------------------------
// Badges
// ---------------------------------------------------------------------

/// How a badge is colored. The tone names the MEANING, never a literal — the
/// pixel color is resolved against the surface it lands on (the T206 rule), so
/// every badge clears the 3:1 chrome floor on light and dark alike.
///
/// The tone vocabulary and its three bases moved to `chrome_theme` in T367,
/// when the connection pill needed the same green/amber/red: this alias keeps
/// the roster's own spelling while there is exactly one definition of what each
/// tone means.
pub const Tone = chrome_theme.Tone;

pub const Badge = struct {
    text: []const u8,
    tone: Tone,
};

/// The badge's text color on `bg`, floored to the chrome contrast target.
pub fn badgeInk(bg: Rgb, tone: Tone) Rgb {
    return chrome_theme.toneInk(bg, tone);
}

/// The badge's capsule fill: its own ink at Mac's low alpha over the row card,
/// so the capsule reads as a tint of the thing it labels rather than a second
/// color to reconcile.
pub fn badgeFill(bg: Rgb, tone: Tone) Rgb {
    return chrome_theme.toneFill(bg, tone);
}

/// Is this session LEFT OVER — live on the local agent with no local pane
/// holding it and no other viewer attached (T520)? This is the state a user
/// would want to act on (resume it into a window, or kill it), so it is the one
/// state in the openness slot that earns a warning tone.
///
/// `attached` alone is deliberately NOT the signal: a locally-open session can
/// be detached for a moment during a reconnect swap (its pane still references
/// the id, so `open_locally` stays true and no mark flickers on), and a session
/// attached by ANOTHER machine's viewer is that viewer's, not left over — it
/// already reads `attached`. Local-target only: for a remote machine, that
/// machine's own windows are invisible from here, so "not in any window" would
/// be a guess.
pub fn orphaned(s: Session, open_locally: bool, local_target: bool) bool {
    return local_target and s.alive and !open_locally and !s.attached;
}

/// The badge run for a row, in Mac's order (`MachineChooserView.swift:632-646`):
/// the liveness/activity badge first, then an openness badge.
///
/// - Alive: `busy` / `needs input`, and NOTHING for idle — the default needs no
///   noise.
/// - Dead: the exit label (which is why `exit_buf` is a parameter).
/// - Then `open` when the session is open in one of our panes, else `attached`
///   when some other viewer holds it, else `not in any window` when the caller
///   says the row is `orphaned` (T520) — a live local session nothing shows.
///   Deliberately no `pinned` badge: every persistent local session is pinned,
///   so it is noise, not signal.
///
/// Returns the filled prefix of `out` (which needs room for 2).
pub fn badges(out: []Badge, exit_buf: []u8, s: Session, open_locally: bool, orphan: bool) []const Badge {
    var n: usize = 0;
    if (s.alive) {
        if (activityBadge(s.activity)) |b| {
            if (n < out.len) {
                out[n] = b;
                n += 1;
            }
        }
    } else if (n < out.len) {
        out[n] = .{ .text = exitedLabel(exit_buf, s.exit_code), .tone = .neutral };
        n += 1;
    }

    if (open_locally) {
        if (n < out.len) {
            out[n] = .{ .text = "open", .tone = .good };
            n += 1;
        }
    } else if (s.attached) {
        if (n < out.len) {
            out[n] = .{ .text = "attached", .tone = .neutral };
            n += 1;
        }
    } else if (orphan and n < out.len) {
        out[n] = .{ .text = orphan_text, .tone = .warn };
        n += 1;
    }
    return out[0..n];
}

/// The T520 mark's wording, shared with the roster's log oracle so the badge
/// and the sentence about it cannot drift apart.
pub const orphan_text = "not in any window";

/// The activity badge for a LIVE session, or null for idle.
pub fn activityBadge(activity: []const u8) ?Badge {
    if (std.mem.eql(u8, activity, "busy")) return .{ .text = "busy", .tone = .warn };
    if (std.mem.eql(u8, activity, "needs_input")) return .{ .text = "needs input", .tone = .danger };
    return null;
}

// ---------------------------------------------------------------------
// Placeholders
// ---------------------------------------------------------------------

/// What the roster region is showing. The loading and failed states are states
/// OF THE REGION, never a modal and never a blocked chooser — the threading
/// rule T295 set and `SessionBrowserProbe.swift:142-149` states for Mac.
///
/// `unauthorized` is a SECOND failure and not a nicety: a chooser lists every
/// enrolled device, so "your relay session expired" is the one failure the user
/// can actually act on, and it must not be spelled as "couldn't reach this
/// machine's agent" (T319).
pub const State = enum { loading, failed, unauthorized, loaded };

pub const loading_text = "Loading sessions...";
pub const failed_text = "Couldn't reach this machine's agent";
pub const empty_text = "No active sessions";
/// The SAME wording `MachineChooser` already uses for `error.Unauthorized`
/// (`:755`, `:1663`, `:1673`). One condition, one sentence — a second wording
/// for the same state is how a surface stops reading as one surface.
pub const unauthorized_text = "Session expired — sign in again above.";

/// The placeholder line for a state, or null when the region has real rows to
/// draw instead.
pub fn stateText(state: State) ?[]const u8 {
    return switch (state) {
        .loading => loading_text,
        .failed => failed_text,
        .unauthorized => unauthorized_text,
        .loaded => null,
    };
}

// ---------------------------------------------------------------------
// Which machine the roster is pointed at (T319)
// ---------------------------------------------------------------------

/// The machine whose sessions the detail pane is showing. Windows is
/// master-detail where Mac is a set of expandable rows, so there is exactly one
/// of these at a time and "collapsed" is spelled `none` — no row selected, or a
/// row that has no roster to show.
pub const Target = union(enum) {
    none,
    /// This box's own `ghoztty-agent`.
    local,
    /// A relay device, by its device id. Borrowed from the directory listing,
    /// which outlives the dialog.
    remote: []const u8,
};

pub fn targetEql(a: Target, b: Target) bool {
    return switch (a) {
        .none => b == .none,
        .local => b == .local,
        .remote => |a_id| switch (b) {
            .remote => |b_id| std.mem.eql(u8, a_id, b_id),
            else => false,
        },
    };
}

/// What pointing the roster at `next` should do to it.
pub const Transition = enum {
    /// A different machine: drop what is shown and fetch from scratch. The drop
    /// is not optional — showing machine A's sessions under machine B's name is
    /// worse than showing nothing.
    reset_and_fetch,
    /// Drop what is shown and fetch NOTHING: the selection landed somewhere
    /// with no roster (an empty filter result).
    reset,
    /// The same machine, already resolved: fetch again but KEEP the rows, so a
    /// re-selection never flashes the region back to `loading` under the user
    /// (Mac's `refreshInPlace` vs `fetchIfNeeded`, `SessionBrowserProbe.swift:303-338`).
    refresh_in_place,
    /// The same machine with a fetch already in flight, or nothing to show.
    /// Doing anything here would only cancel work that is about to answer.
    nothing,
};

pub fn transitionFor(
    current: Target,
    next: Target,
    state: State,
    inflight: bool,
) Transition {
    if (!targetEql(current, next)) {
        return if (next == .none) .reset else .reset_and_fetch;
    }
    if (next == .none) return .nothing;
    if (inflight) return .nothing;
    if (state == .loaded) return .refresh_in_place;
    // A previous attempt failed (or never resolved) and the user came back to
    // the row: try again rather than leaving a dead region.
    return .reset_and_fetch;
}

// ---------------------------------------------------------------------
// Resume (T320)
// ---------------------------------------------------------------------

/// Whether a row can be RESUMED — opened here as a pane ATTACHed to its live
/// child. Deliberately NOT `isConnectable`: a *relaunchable* tombstone is worth
/// LISTING (its recorded argv/cwd can revive it) but there is no live process to
/// attach to, and reviving it is `RELAUNCH` — a different verb, and not this
/// task. Mac states the same rule and enforces it in `resume`
/// (`MachineChooserView.swift:167-168`); collapsing the two predicates into one
/// is the bug both comments exist to prevent.
pub fn isResumable(s: Session) bool {
    return s.alive;
}

/// The keyboard sub-cursor is OUT of the roster (the machine row itself is
/// highlighted). Mac spells this `browseCursor == nil`.
pub const no_cursor: i32 = -1;

/// Right arrow: step the cursor INTO the rendered roster (Mac's
/// `enterSessions`, `:815-818`). A roster with nothing rendered — loading,
/// failed, or empty — has nowhere to step, and an already-entered cursor stays
/// where it is rather than jumping home.
pub fn enterCursor(cur: i32, count: usize) i32 {
    if (cur != no_cursor) return cur;
    if (count == 0) return no_cursor;
    return 0;
}

/// Up/Down with the cursor inside the roster (Mac's `move`, `:1313-1319`):
/// stepping above the first row hands navigation BACK to the machine list, and
/// stepping past the last clamps rather than wrapping — a wrap would send the
/// user to the top of a long roster they were walking down.
pub fn moveCursor(cur: i32, delta: i32, count: usize) i32 {
    if (count == 0) return no_cursor;
    const next = cur + delta;
    if (next < no_cursor + 1) return no_cursor;
    const last: i32 = @intCast(count - 1);
    return @min(next, last);
}

/// Hold the cursor inside a roster that changed underneath it. A live refetch
/// (or an optimistic Kill) can shrink the rendered list while the cursor sits
/// past its new end; the row that slid into the index is NOT the row the user
/// was pointing at, so the cursor clamps to the last row rather than silently
/// re-pointing at whatever arrived.
pub fn clampCursor(cur: i32, count: usize) i32 {
    if (cur == no_cursor) return no_cursor;
    if (count == 0) return no_cursor;
    const last: i32 = @intCast(count - 1);
    return std.math.clamp(cur, 0, last);
}

/// What resuming a row means, resolved from the machine the roster is pointed at
/// — Mac's `resumeTarget` (`MachineChooserView.swift:127-133`) with its caller's
/// `session.alive` guard folded in, so there is ONE place that can say yes.
///
/// The chooser does not attach anything itself: it produces one of these,
/// closes, and hands it to `App` — the separation Mac keeps
/// (`WindowTarget.resumeSession`) and the reason `MachineChooser.zig` does not
/// grow an attach path.
pub const Resume = union(enum) {
    /// Not resumable: a dead row, or no machine selected.
    none,
    /// A session of THIS box's `ghoztty-agent`, by id.
    local: []const u8,
    /// A session of a relay machine: its device id and the session id.
    remote: struct { device: []const u8, session: []const u8 },
};

pub fn resumeTarget(target: Target, s: Session) Resume {
    if (!isResumable(s)) return .none;
    if (s.id.len == 0) return .none;
    return switch (target) {
        .none => .none,
        .local => .{ .local = s.id },
        .remote => |device| .{ .remote = .{ .device = device, .session = s.id } },
    };
}

// ---------------------------------------------------------------------
// Restore All (T335)
// ---------------------------------------------------------------------

/// How many ALIVE sessions a machine must have before "Restore All" is offered.
/// Mac's number, and its reason is the reason to port it rather than to soften
/// it (`MachineChooserView.swift:145-155`): with one session there is no
/// TOPOLOGY to rebuild, and resuming that single pane is what the per-session
/// Return already does. A Restore All that lights up on one session is a second
/// button for the first button's job.
pub const restore_all_min_alive: usize = 2;

/// How many of `sessions` are ALIVE — the datum the rule is taken of. This is
/// `isResumable`, deliberately, and NOT `isConnectable`: a relaunchable
/// tombstone is worth LISTING (its recorded argv/cwd can revive it) but has no
/// live child to attach, so a machine holding two tombstones offers a Restore
/// All that would rebuild two fresh shells and call it a restore. Same
/// distinction T320 drew one level down.
pub fn aliveCount(sessions: []const Session) usize {
    var n: usize = 0;
    for (sessions) |s| {
        if (isResumable(s)) n += 1;
    }
    return n;
}

/// Whether a machine with `alive` live sessions can offer "Restore All". Takes
/// the COUNT rather than the sessions so the caller can supply it from whatever
/// it already has (the chooser counts the roster's own rows, which are filtered
/// for optimistic kills); the rule itself lives here, once.
pub fn restoreAllAvailable(alive: usize) bool {
    return alive >= restore_all_min_alive;
}

// ---------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Every number a roster row is built from, in physical pixels. All on the 4
/// DIP scale (§1); the line boxes come from the type ramp so they cannot drift
/// from the text actually drawn in them.
pub const Metrics = struct {
    /// Card padding. Mac's 12/9 -> `lg` and `md`.
    pad_x: i32,
    pad_y: i32,
    /// Between two cards (§3.1's row rhythm at card scale).
    row_gap: i32,
    /// Card corner radius: §3.1's CARD radius (8), which is also Mac's.
    radius: i32,
    /// The liveness dot's reserved column and the dot itself, so a dead row's
    /// hollow ring and a live row's filled dot share one grid.
    dot_col_w: i32,
    dot_d: i32,
    /// The per-session CPU meter's column and the gap to the text after it
    /// (T462). Reserved only when the machine's agent can serve the stream, so
    /// an older agent leaves no dead gutter — see `rowLayout`'s `show_cpu`.
    cpu_col_w: i32,
    cpu_gap: i32,
    /// Column -> text.
    text_gap: i32,
    title_h: i32,
    subline_h: i32,
    line_gap: i32,
    /// Title -> first badge, and badge -> badge.
    badge_gap: i32,
    badge_h: i32,
    badge_pad_x: i32,
    badge_radius: i32,
    /// The Kill button: one icon-button size across the app (§2.1), with its
    /// hit box from the same module.
    kill_w: i32,
    kill_hit_w: i32,
    /// Text column -> Kill button.
    kill_gap: i32,
    /// `CreateFontW` heights for the two roles used here.
    body_font_h: i32,
    caption_font_h: i32,
};

pub fn metrics(scale: f32) Metrics {
    const icon: icon_button.Metrics = .init(scale);
    const caption = type_ramp.caption(scale);
    const body = type_ramp.body(scale);

    // A badge is a capsule around one caption line: the line box plus `xs`
    // above and below, so its height is derived from the text it holds rather
    // than picked. `badge_radius` is half that height, which is what makes it a
    // capsule at every scale instead of a rounded rect at some of them.
    const badge_h = caption.height + px(4, scale);

    return .{
        .pad_x = px(12, scale),
        .pad_y = px(8, scale),
        .row_gap = px(8, scale),
        .radius = px(8, scale),
        .dot_col_w = px(12, scale),
        .dot_d = px(8, scale),
        .cpu_col_w = chooser_cpu.columnWidth(scale),
        .cpu_gap = chooser_cpu.metrics(scale).col_gap,
        .text_gap = px(8, scale),
        .title_h = body.height + px(4, scale),
        .subline_h = caption.height + px(4, scale),
        .line_gap = px(2, scale),
        .badge_gap = px(4, scale),
        .badge_h = badge_h,
        .badge_pad_x = px(4, scale),
        .badge_radius = @divTrunc(badge_h, 2),
        .kill_w = icon.target,
        .kill_hit_w = icon.target + icon.hit_pad * 2,
        .kill_gap = px(8, scale),
        .body_font_h = body.height,
        .caption_font_h = caption.height,
    };
}

/// How many sublines a session's card carries: cwd and/or command, each shown
/// only when the agent reported it.
pub fn sublineCount(s: Session) i32 {
    var n: i32 = 0;
    if (nonEmpty(s.cwd) != null) n += 1;
    if (nonEmpty(s.argv) != null) n += 1;
    return n;
}

/// A card's height for `sublines` extra lines. Mac's rows grow with their
/// content; a fixed height would leave a hole under a session with no cwd.
pub fn rowHeight(m: Metrics, sublines: i32) i32 {
    var h = m.pad_y * 2 + m.title_h;
    var i: i32 = 0;
    while (i < sublines) : (i += 1) h += m.line_gap + m.subline_h;
    // The title line must never be shorter than the controls sitting on it.
    const controls = m.pad_y * 2 + @max(m.title_h, m.kill_w);
    return @max(h, controls);
}

/// Where every piece of one card sits, in physical pixels from the client
/// origin. `title.right` is the FURTHEST the title may run; the caller measures
/// the text and packs the badge run after it (a width that comes from text
/// metrics is measured, never re-derived — the T256 lesson).
pub const RowLayout = struct {
    card: Rect,
    dot: Rect,
    /// The CPU meter's reserved column, on the title's line box (T462). Empty
    /// (zero-width) when the machine's agent cannot serve the stream — a caller
    /// draws a meter into it only when it has a reading, but the SPACE is a
    /// property of the machine, so every row of a supported machine reserves it
    /// and their titles all start at the same x.
    cpu: Rect,
    title: Rect,
    cwd: Rect,
    argv: Rect,
    /// The Kill button's PAINTED square, and the larger box that answers the
    /// click. Gaps are measured against the painted edge; the hit box never
    /// contributes one (design system §1.2).
    kill: Rect,
    kill_hit: Rect,
};

/// `show_cpu` reserves the meter column between the dot and the text (T462).
/// It is a statement about the MACHINE — its agent advertised the `session_cpu`
/// capability — never about the row, so it is the same for every card in one
/// roster and the meters stack into a scannable strip.
pub fn rowLayout(m: Metrics, x: i32, y: i32, w: i32, sublines: i32, show_cpu: bool) RowLayout {
    const h = rowHeight(m, sublines);
    const card: Rect = .{ .left = x, .top = y, .right = x + w, .bottom = y + h };

    const dot_left = card.left + m.pad_x + @divTrunc(m.dot_col_w - m.dot_d, 2);
    // Centered on the title's line box, not on the card: a three-line card's
    // dot belongs beside the name, not floating in the middle of the sublines.
    const dot_top = card.top + m.pad_y + @divTrunc(m.title_h - m.dot_d, 2);

    const kill_left = card.right - m.pad_x - m.kill_w;
    const kill_top = card.top + m.pad_y + @divTrunc(m.title_h - m.kill_w, 2);
    const kill: Rect = .{
        .left = kill_left,
        .top = kill_top,
        .right = kill_left + m.kill_w,
        .bottom = kill_top + m.kill_w,
    };
    const grow = @divTrunc(m.kill_hit_w - m.kill_w, 2);
    const kill_hit: Rect = .{
        .left = kill.left - grow,
        .top = kill.top - grow,
        .right = kill.right + grow,
        .bottom = kill.bottom + grow,
    };

    const cpu_left = card.left + m.pad_x + m.dot_col_w + m.text_gap;
    const cpu_top = card.top + m.pad_y;
    const cpu: Rect = if (show_cpu) .{
        .left = cpu_left,
        .top = cpu_top,
        .right = cpu_left + m.cpu_col_w,
        .bottom = cpu_top + m.title_h,
    } else .{ .left = cpu_left, .top = cpu_top, .right = cpu_left, .bottom = cpu_top + m.title_h };

    const text_left = if (show_cpu) cpu.right + m.cpu_gap else cpu_left;
    const text_right = kill.left - m.kill_gap;
    const title: Rect = .{
        .left = text_left,
        .top = card.top + m.pad_y,
        .right = text_right,
        .bottom = card.top + m.pad_y + m.title_h,
    };

    // The sublines run under the title in the order Mac draws them (cwd, then
    // command); an absent cwd promotes the command into the first slot, which
    // is why both rects are computed from a running cursor.
    var line_top = title.bottom;
    var cwd: Rect = .{ .left = text_left, .top = line_top, .right = text_right, .bottom = line_top };
    var argv: Rect = cwd;
    if (sublines > 0) {
        line_top += m.line_gap;
        cwd = .{
            .left = text_left,
            .top = line_top,
            .right = text_right,
            .bottom = line_top + m.subline_h,
        };
        line_top = cwd.bottom;
    }
    if (sublines > 1) {
        line_top += m.line_gap;
        argv = .{
            .left = text_left,
            .top = line_top,
            .right = text_right,
            .bottom = line_top + m.subline_h,
        };
    }

    return .{
        .card = card,
        .dot = .{
            .left = dot_left,
            .top = dot_top,
            .right = dot_left + m.dot_d,
            .bottom = dot_top + m.dot_d,
        },
        .cpu = cpu,
        .title = title,
        .cwd = cwd,
        .argv = argv,
        .kill = kill,
        .kill_hit = kill_hit,
    };
}

/// A badge capsule of `text_w` measured pixels placed at `x` on the title's
/// line box. Returns the capsule, so the caller can advance by its width plus
/// `badge_gap`.
pub fn badgeBox(m: Metrics, x: i32, title: Rect, text_w: i32) Rect {
    const top = title.top + @divTrunc(title.height() - m.badge_h, 2);
    return .{
        .left = x,
        .top = top,
        .right = x + text_w + m.badge_pad_x * 2,
        .bottom = top + m.badge_h,
    };
}

/// The scroll offset the roster may actually be at: never negative, and never
/// past the last pixel of content. A region taller than its content is pinned
/// at 0 rather than being allowed to scroll into empty space.
pub fn clampScroll(offset: i32, content_h: i32, view_h: i32) i32 {
    const max = @max(content_h - view_h, 0);
    return std.math.clamp(offset, 0, max);
}

/// The card's background: a faint lift off the detail pane, so a row reads as a
/// surface without becoming a second color. Mac's `Color.primary.opacity(0.04)`.
pub fn cardFill(bg: Rgb) Rgb {
    return color_math.mix(bg, chrome_theme.textOn(bg), 0.05);
}

/// The card's background under the pointer — the same wash the rest of the
/// chrome uses for hover, applied on top of the card's own lift so hover is a
/// step and not a repaint in a different language.
pub fn cardHoverFill(bg: Rgb) Rgb {
    return color_math.mix(cardFill(bg), chrome_theme.textOn(bg), chrome_theme.hover_wash);
}

/// The card under the keyboard sub-cursor (T320), and its 1 DIP ring. Both come
/// from `chooser_rows` — the SAME selection fill and border the machine list
/// paints its highlighted row with — because a chooser that says "this is the
/// thing you are driving" in two visual languages is a chooser with two
/// selections. Mac's own session cursor is likewise its accent at a fill plus a
/// stroke (`MachineChooserView.swift:690-697`).
pub fn cursorFill(bg: Rgb, accent: Rgb) Rgb {
    return chooser_rows.selectionFill(bg, accent);
}

pub fn cursorBorder(bg: Rgb, accent: Rgb) Rgb {
    return chooser_rows.selectionBorder(bg, accent);
}

/// The liveness dot: green (floored) when alive, the de-emphasized ink when the
/// session is a tombstone. Shape carries the state too — the caller fills the
/// live dot and strokes the dead one as a ring — so the mark is never color
/// alone (§2.4).
pub fn dotInk(bg: Rgb, alive: bool) Rgb {
    return if (alive) chrome_theme.toneInk(bg, .good) else chrome_theme.toneInk(bg, .neutral);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn contrast(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(color_math.wcagLuminance(a), color_math.wcagLuminance(b));
}

test "isConnectable keeps alive sessions and relaunchable tombstones" {
    try testing.expect(isConnectable(.{ .alive = true }));
    try testing.expect(isConnectable(.{ .alive = false, .relaunchable = true }));
    // A genuinely exited child: an unreconnectable dead end.
    try testing.expect(!isConnectable(.{ .alive = false, .exit_code = 1 }));
    try testing.expect(!isConnectable(.{}));
}

test "baseName handles both separators, trailing separators and roots" {
    try testing.expectEqualStrings("ghoztty", baseName("D:\\git\\ghoztty"));
    try testing.expectEqualStrings("ghoztty", baseName("D:\\git\\ghoztty\\"));
    try testing.expectEqualStrings("ghoztty", baseName("/home/david/ghoztty"));
    try testing.expectEqualStrings("ghoztty", baseName("/home/david/ghoztty/"));
    try testing.expectEqualStrings("home", baseName("/home"));
    // A drive root is its drive letter; only a path that is nothing BUT
    // separators falls back to the whole string (an empty label is worse).
    try testing.expectEqualStrings("C:", baseName("C:\\"));
    try testing.expectEqualStrings("/", baseName("/"));
    try testing.expectEqualStrings("", baseName(""));
}

test "label ladder: every rung, in order" {
    var buf: [32]u8 = undefined;
    const full: Session = .{
        .pid = 4242,
        .title = "agent title",
        .cwd = "D:\\git\\ghoztty",
        .argv = "claude --continue",
    };

    // 1. a live pane's title wins over everything.
    try testing.expectEqualStrings("live", label(&buf, full, "live", "persisted"));
    // 2. then the agent's title.
    try testing.expectEqualStrings("agent title", label(&buf, full, null, "persisted"));
    // 3. then the persisted layout title.
    var s = full;
    s.title = null;
    try testing.expectEqualStrings("persisted", label(&buf, s, null, "persisted"));
    // 4. then the cwd's last component.
    try testing.expectEqualStrings("ghoztty", label(&buf, s, null, null));
    // 5. then the command.
    s.cwd = null;
    try testing.expectEqualStrings("claude --continue", label(&buf, s, null, null));
    // 6. and finally the REAL pid — never the opaque session id.
    s.argv = null;
    try testing.expectEqualStrings("pid 4242", label(&buf, s, null, null));
}

test "label treats empty strings as absent rungs" {
    var buf: [32]u8 = undefined;
    const s: Session = .{ .pid = 7, .title = "", .cwd = "", .argv = "" };
    try testing.expectEqualStrings("pid 7", label(&buf, s, "", ""));
}

test "exitedLabel names the code when there is one" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("exited", exitedLabel(&buf, null));
    try testing.expectEqualStrings("exited (0)", exitedLabel(&buf, 0));
    try testing.expectEqualStrings("exited (137)", exitedLabel(&buf, 137));
}

test "countLabel singularizes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 sessions", countLabel(&buf, 0));
    try testing.expectEqualStrings("1 session", countLabel(&buf, 1));
    try testing.expectEqualStrings("2 sessions", countLabel(&buf, 2));
}

test "badges: idle is unbadged, busy and needs_input are not" {
    var out: [2]Badge = undefined;
    var ebuf: [32]u8 = undefined;

    try testing.expectEqual(
        @as(usize, 0),
        badges(&out, &ebuf, .{ .alive = true, .activity = "idle" }, false, false).len,
    );

    const busy = badges(&out, &ebuf, .{ .alive = true, .activity = "busy" }, false, false);
    try testing.expectEqual(@as(usize, 1), busy.len);
    try testing.expectEqualStrings("busy", busy[0].text);
    try testing.expectEqual(Tone.warn, busy[0].tone);

    const needs = badges(&out, &ebuf, .{ .alive = true, .activity = "needs_input" }, false, false);
    try testing.expectEqualStrings("needs input", needs[0].text);
    try testing.expectEqual(Tone.danger, needs[0].tone);
}

test "badges: open beats attached, and a dead row leads with its exit label" {
    var out: [2]Badge = undefined;
    var ebuf: [32]u8 = undefined;

    // Open in one of our panes AND attached: "open" is what the user cares
    // about, so "attached" is not also shown.
    const open = badges(&out, &ebuf, .{ .alive = true, .attached = true }, true, false);
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqualStrings("open", open[0].text);
    try testing.expectEqual(Tone.good, open[0].tone);

    const elsewhere = badges(&out, &ebuf, .{ .alive = true, .attached = true }, false, false);
    try testing.expectEqualStrings("attached", elsewhere[0].text);

    const dead = badges(&out, &ebuf, .{ .alive = false, .exit_code = 2, .attached = true }, false, false);
    try testing.expectEqual(@as(usize, 2), dead.len);
    try testing.expectEqualStrings("exited (2)", dead[0].text);
    try testing.expectEqualStrings("attached", dead[1].text);
}

test "badges never overrun the caller's buffer" {
    var out: [1]Badge = undefined;
    var ebuf: [32]u8 = undefined;
    const run = badges(&out, &ebuf, .{ .alive = false, .exit_code = 1, .attached = true }, false, false);
    try testing.expectEqual(@as(usize, 1), run.len);
}

test "orphaned: precisely 'no local pane holds this live local session' (T520)" {
    // The one true case: live, local target, no pane, nothing attached.
    try testing.expect(orphaned(.{ .alive = true }, false, true));

    // A pane of ours holds it — even a momentarily-detached one (the reconnect
    // swap): the pane keeps `open_locally` true, so no mark can flicker on.
    try testing.expect(!orphaned(.{ .alive = true }, true, true));
    try testing.expect(!orphaned(.{ .alive = true, .attached = true }, true, true));

    // Another viewer holds it: that is "attached", not "left over".
    try testing.expect(!orphaned(.{ .alive = true, .attached = true }, false, true));

    // A dead (even relaunchable) tombstone is not a LIVE session nothing shows.
    try testing.expect(!orphaned(.{ .alive = false, .relaunchable = true }, false, true));

    // A remote machine's windows are invisible from here — never marked.
    try testing.expect(!orphaned(.{ .alive = true }, false, false));
}

test "badges: an orphaned row reads 'not in any window', and open/attached beat it" {
    var out: [2]Badge = undefined;
    var ebuf: [32]u8 = undefined;

    const orphan = badges(&out, &ebuf, .{ .alive = true }, false, true);
    try testing.expectEqual(@as(usize, 1), orphan.len);
    try testing.expectEqualStrings(orphan_text, orphan[0].text);
    try testing.expectEqual(Tone.warn, orphan[0].tone);

    // A busy orphan carries both stories, activity first (Mac's order).
    const busy = badges(&out, &ebuf, .{ .alive = true, .activity = "busy" }, false, true);
    try testing.expectEqual(@as(usize, 2), busy.len);
    try testing.expectEqualStrings("busy", busy[0].text);
    try testing.expectEqualStrings(orphan_text, busy[1].text);

    // The openness slot is one slot: open and attached still win it.
    const open = badges(&out, &ebuf, .{ .alive = true }, true, false);
    try testing.expectEqualStrings("open", open[0].text);
    const attached = badges(&out, &ebuf, .{ .alive = true, .attached = true }, false, false);
    try testing.expectEqualStrings("attached", attached[0].text);
}

test "sublineCount counts only the lines the agent reported" {
    try testing.expectEqual(@as(i32, 0), sublineCount(.{}));
    try testing.expectEqual(@as(i32, 1), sublineCount(.{ .cwd = "D:\\git" }));
    try testing.expectEqual(@as(i32, 1), sublineCount(.{ .argv = "pwsh" }));
    try testing.expectEqual(@as(i32, 2), sublineCount(.{ .cwd = "D:\\git", .argv = "pwsh" }));
    // Empty strings are not lines.
    try testing.expectEqual(@as(i32, 0), sublineCount(.{ .cwd = "", .argv = "" }));
}

test "row geometry nests inside the card at every scale" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = metrics(scale);
        const w = px(560, scale);
        for ([_]i32{ 0, 1, 2 }) |subs| {
            const r = rowLayout(m, 100, 40, w, subs, false);
            try testing.expectEqual(rowHeight(m, subs), r.card.height());

            // Nothing escapes the card.
            for ([_]Rect{ r.dot, r.title, r.kill }) |piece| {
                try testing.expect(piece.left >= r.card.left);
                try testing.expect(piece.right <= r.card.right);
                try testing.expect(piece.top >= r.card.top);
                try testing.expect(piece.bottom <= r.card.bottom);
            }
            if (subs > 0) try testing.expect(r.cwd.bottom <= r.card.bottom);
            if (subs > 1) try testing.expect(r.argv.bottom <= r.card.bottom);

            // Nothing touches anything (design system §1.2): the text column
            // clears the Kill button's PAINTED edge by a real gap.
            try testing.expectEqual(m.kill_gap, r.kill.left - r.title.right);
            try testing.expect(r.title.left - r.dot.right >= m.text_gap);

            // The hit box may be bigger than the paint, and is never the thing
            // a gap is measured to.
            try testing.expect(r.kill_hit.left <= r.kill.left);
            try testing.expect(r.kill_hit.right >= r.kill.right);
        }
    }
}

test "row geometry: sublines stack in order and only when present" {
    const m = metrics(1.25);
    const one = rowLayout(m, 0, 0, 400, 1, false);
    try testing.expect(one.cwd.height() > 0);
    try testing.expectEqual(@as(i32, 0), one.argv.height());
    try testing.expectEqual(one.title.bottom + m.line_gap, one.cwd.top);

    const two = rowLayout(m, 0, 0, 400, 2, false);
    try testing.expectEqual(two.cwd.bottom + m.line_gap, two.argv.top);
    try testing.expect(two.card.height() > one.card.height());
}

test "every spacing number is on the 4 DIP scale" {
    // §1: the scale is 2/4/8/12/16/24. A value off it is a defect even when it
    // looks fine at 1.0, which is exactly why this is asserted and not intended.
    const allowed = [_]f32{ 2, 4, 8, 12, 16, 24 };
    const m = metrics(1.0);
    const values = [_]i32{ m.pad_x, m.pad_y, m.row_gap, m.radius, m.dot_col_w, m.dot_d, m.cpu_gap, m.text_gap, m.line_gap, m.badge_gap, m.badge_pad_x, m.kill_gap };
    for (values) |v| {
        var ok = false;
        for (allowed) |a| {
            if (v == @as(i32, @intFromFloat(a))) ok = true;
        }
        try testing.expect(ok);
    }
}

test "the CPU column is reserved for the machine, not for the row (T462)" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = metrics(scale);
        const w = px(560, scale);
        const off = rowLayout(m, 100, 40, w, 1, false);
        const on = rowLayout(m, 100, 40, w, 1, true);

        // Without the column nothing is reserved and the text starts where it
        // always did — an agent that cannot serve the stream leaves no gutter.
        try testing.expectEqual(@as(i32, 0), off.cpu.width());
        try testing.expectEqual(off.cpu.right, off.title.left);

        // With it, the column sits between the dot and the text, clearing both
        // by a real gap measured against PAINTED edges (§1.2).
        try testing.expectEqual(m.cpu_col_w, on.cpu.width());
        try testing.expect(on.cpu.left - off.dot.right >= m.text_gap);
        try testing.expectEqual(m.cpu_gap, on.title.left - on.cpu.right);
        try testing.expectEqual(off.title.left + m.cpu_col_w + m.cpu_gap, on.title.left);

        // It rides the TITLE's line box, so a three-line card's meter stays
        // beside the name instead of floating in the middle.
        try testing.expectEqual(on.title.top, on.cpu.top);
        try testing.expectEqual(on.title.bottom, on.cpu.bottom);

        // Reserving it never changes the card's height, nor where the sublines
        // and the Kill button sit — only where the text column starts.
        try testing.expectEqual(off.card.height(), on.card.height());
        try testing.expectEqual(off.kill.left, on.kill.left);
        try testing.expect(on.cpu.right <= on.card.right);

        // Every card of the same roster reserves the same width, whatever it
        // holds: a column that collapses on some rows is not a column.
        const three_line = rowLayout(m, 100, 40, w, 2, true);
        try testing.expectEqual(on.cpu.width(), three_line.cpu.width());
        try testing.expectEqual(on.title.left, three_line.title.left);
    }
}

test "the badge capsule is centered on the title line and pads both sides" {
    // All four common scalings, per the design system's assertion rule — the
    // T520 mark is the longest badge text, so its capsule geometry riding these
    // metrics is what keeps "not in any window" on the title line at every DPI.
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = metrics(scale);
        const r = rowLayout(m, 0, 0, 600, 1, false);
        const text_w = px(40, scale);
        const box = badgeBox(m, r.title.left + 100, r.title, text_w);
        try testing.expectEqual(text_w + m.badge_pad_x * 2, box.width());
        try testing.expectEqual(m.badge_h, box.height());
        // A capsule: the radius is half the height, whatever the scale.
        try testing.expectEqual(@divTrunc(m.badge_h, 2), m.badge_radius);
        // Centered: the slack above equals the slack below (within the odd pixel).
        const above = box.top - r.title.top;
        const below = r.title.bottom - box.bottom;
        try testing.expect(@abs(above - below) <= 1);
        // On the title's line box, never outside it.
        try testing.expect(box.top >= r.title.top and box.bottom <= r.title.bottom);
    }
}

test "clampScroll pins a short roster and stops at the last pixel" {
    try testing.expectEqual(@as(i32, 0), clampScroll(50, 100, 300));
    try testing.expectEqual(@as(i32, 0), clampScroll(-20, 500, 300));
    try testing.expectEqual(@as(i32, 200), clampScroll(999, 500, 300));
    try testing.expectEqual(@as(i32, 120), clampScroll(120, 500, 300));
}

test "badge and dot colors clear the chrome contrast floor on both themes" {
    // The floor carries `chrome_theme`'s own 0.05 tolerance (its palette tests
    // at :295/:336 use the same one): the shared contrast search runs in Lab
    // and sRGB floats, then quantizes to 8 bits, which can land a hair under
    // the target it just cleared — measured 2.9905 for `good` on the light
    // surface. That is a property of `color_math.contrastAdjustedTo` and every
    // accent on the surface pays it, so it is filed as its own task rather than
    // papered over with a per-tone nudge here.
    const floor = chrome_theme.ui_contrast_target - 0.05;
    const dark: Rgb = .{ .r = 32, .g = 32, .b = 32 };
    const light: Rgb = .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 };
    for ([_]Rgb{ dark, light }) |surface| {
        const card = cardFill(surface);
        for ([_]Tone{ .neutral, .warn, .danger, .good }) |tone| {
            const ink = badgeInk(card, tone);
            try testing.expect(contrast(ink, card) >= floor);
        }
        try testing.expect(contrast(dotInk(card, true), card) >= floor);
        try testing.expect(contrast(dotInk(card, false), card) >= floor);
    }
}

// ---------------------------------------------------------------------
// Target / transitions (T319)
// ---------------------------------------------------------------------

test "targetEql compares remote machines by device id, not by tag" {
    try testing.expect(targetEql(.none, .none));
    try testing.expect(targetEql(.local, .local));
    try testing.expect(!targetEql(.local, .none));
    try testing.expect(targetEql(.{ .remote = "dev-a" }, .{ .remote = "dev-a" }));
    // The bug this exists to stop: two DIFFERENT machines comparing equal would
    // leave machine A's sessions on screen under machine B's name.
    try testing.expect(!targetEql(.{ .remote = "dev-a" }, .{ .remote = "dev-b" }));
    try testing.expect(!targetEql(.{ .remote = "dev-a" }, .local));
    try testing.expect(!targetEql(.local, .{ .remote = "dev-a" }));
}

test "moving to another machine always resets and refetches" {
    // ... whatever the old machine's state was: a loaded roster is the WORST
    // thing to keep, because it looks like an answer about the new machine.
    for ([_]State{ .loading, .failed, .unauthorized, .loaded }) |s| {
        try testing.expectEqual(
            Transition.reset_and_fetch,
            transitionFor(.local, .{ .remote = "dev-a" }, s, false),
        );
        try testing.expectEqual(
            Transition.reset_and_fetch,
            transitionFor(.{ .remote = "dev-a" }, .{ .remote = "dev-b" }, s, false),
        );
    }
    // Even mid-flight: the in-flight reply belongs to the OLD machine and is
    // dropped on its serial, so a new fetch has to be started here or the new
    // row would sit on `loading` forever.
    try testing.expectEqual(
        Transition.reset_and_fetch,
        transitionFor(.local, .{ .remote = "dev-a" }, .loading, true),
    );
}

test "re-selecting the same machine refreshes in place, never back to loading" {
    try testing.expectEqual(
        Transition.refresh_in_place,
        transitionFor(.local, .local, .loaded, false),
    );
    try testing.expectEqual(
        Transition.refresh_in_place,
        transitionFor(.{ .remote = "dev-a" }, .{ .remote = "dev-a" }, .loaded, false),
    );
    // A fetch already answering: leave it alone.
    try testing.expectEqual(
        Transition.nothing,
        transitionFor(.local, .local, .loading, true),
    );
    // A failed machine the user came back to: try again.
    for ([_]State{ .loading, .failed, .unauthorized }) |s| {
        try testing.expectEqual(
            Transition.reset_and_fetch,
            transitionFor(.local, .local, s, false),
        );
    }
}

test "a selection with no roster clears the region and dials nothing" {
    try testing.expectEqual(Transition.reset, transitionFor(.local, .none, .loaded, false));
    try testing.expectEqual(
        Transition.reset,
        transitionFor(.{ .remote = "dev-a" }, .none, .loaded, false),
    );
    try testing.expectEqual(Transition.nothing, transitionFor(.none, .none, .loading, false));
}

test "every non-loaded state has a placeholder line and loaded has none" {
    try testing.expectEqualStrings(loading_text, stateText(.loading).?);
    try testing.expectEqualStrings(failed_text, stateText(.failed).?);
    // The expired-credential line is the one the rest of the chooser already
    // uses; a second wording for the same state is the defect.
    try testing.expectEqualStrings(unauthorized_text, stateText(.unauthorized).?);
    try testing.expectEqual(@as(?[]const u8, null), stateText(.loaded));
}

test "the count label agrees with the roster it counts" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 sessions", countLabel(&buf, 0));
    try testing.expectEqualStrings("1 session", countLabel(&buf, 1));
    try testing.expectEqualStrings("2 sessions", countLabel(&buf, 2));
}

// ---------------------------------------------------------------------
// Resume + the keyboard sub-cursor (T320)
// ---------------------------------------------------------------------

test "resumable is alive only - a relaunchable tombstone is listable, not attachable" {
    try testing.expect(isResumable(.{ .alive = true }));
    // Listable (isConnectable) and NOT resumable: reviving it is RELAUNCH.
    const tombstone: Session = .{ .alive = false, .relaunchable = true };
    try testing.expect(isConnectable(tombstone));
    try testing.expect(!isResumable(tombstone));
    try testing.expect(!isResumable(.{ .alive = false, .exit_code = 1 }));
}

test "resumeTarget names the machine the roster is pointed at" {
    const alive: Session = .{ .id = "abc", .alive = true };
    switch (resumeTarget(.local, alive)) {
        .local => |id| try testing.expectEqualStrings("abc", id),
        else => return error.TestUnexpectedResult,
    }
    switch (resumeTarget(.{ .remote = "dev-a" }, alive)) {
        .remote => |r| {
            try testing.expectEqualStrings("dev-a", r.device);
            try testing.expectEqualStrings("abc", r.session);
        },
        else => return error.TestUnexpectedResult,
    }
    // The alive guard lives HERE, so no caller can forget it.
    try testing.expectEqual(Resume.none, resumeTarget(.local, .{ .id = "abc", .relaunchable = true }));
    // No machine selected, and a row with no id, resolve to nothing rather than
    // to a plausible-looking attach.
    try testing.expectEqual(Resume.none, resumeTarget(.none, alive));
    try testing.expectEqual(Resume.none, resumeTarget(.local, .{ .alive = true }));
}

test "restoreAllAvailable: two ALIVE sessions, and tombstones do not count" {
    const alive: Session = .{ .id = "a", .alive = true };
    const alive2: Session = .{ .id = "b", .alive = true };
    const tombstone: Session = .{ .id = "c", .alive = false, .relaunchable = true };
    const dead: Session = .{ .id = "d", .alive = false, .exit_code = 1 };

    // 0 / 1 / 2 alive — the rule's whole domain.
    try testing.expect(!restoreAllAvailable(aliveCount(&.{})));
    try testing.expect(!restoreAllAvailable(aliveCount(&.{alive})));
    try testing.expect(restoreAllAvailable(aliveCount(&.{ alive, alive2 })));

    // Two relaunchable tombstones LOOK like two rows (both are rendered) and
    // must still not offer it: there is nothing to attach to.
    try testing.expectEqual(@as(usize, 0), aliveCount(&.{ tombstone, tombstone }));
    try testing.expect(!restoreAllAvailable(aliveCount(&.{ tombstone, tombstone })));

    // Mixed: one alive among the dead is still one.
    try testing.expectEqual(@as(usize, 1), aliveCount(&.{ tombstone, alive, dead }));
    try testing.expect(!restoreAllAvailable(aliveCount(&.{ tombstone, alive, dead })));
    try testing.expect(restoreAllAvailable(aliveCount(&.{ tombstone, alive, dead, alive2 })));
}

test "the cursor's index space is the RENDERED list, with a dead row planted mid-roster" {
    // What an agent hands back: two live sessions with an unconnectable dead one
    // between them. The roster renders only the connectable rows, so the second
    // rendered row is the THIRD raw session — and a cursor that walked the raw
    // list would resume the wrong pane (Mac's `highlightedSessions` filters for
    // exactly this reason).
    const raw = [_]Session{
        .{ .id = "one", .alive = true },
        .{ .id = "gone", .alive = false, .exit_code = 1 },
        .{ .id = "two", .alive = true },
    };
    var rendered: [raw.len]Session = undefined;
    var n: usize = 0;
    for (raw) |s| {
        if (!isConnectable(s)) continue;
        rendered[n] = s;
        n += 1;
    }
    const rows = rendered[0..n];
    try testing.expectEqual(@as(usize, 2), rows.len);

    // Enter, then walk: every cursor value indexes the rendered list, and the
    // resume it produces names that row's session.
    var cur = enterCursor(no_cursor, rows.len);
    try testing.expectEqual(@as(i32, 0), cur);
    switch (resumeTarget(.local, rows[@intCast(cur)])) {
        .local => |id| try testing.expectEqualStrings("one", id),
        else => return error.TestUnexpectedResult,
    }
    cur = moveCursor(cur, 1, rows.len);
    try testing.expectEqual(@as(i32, 1), cur);
    switch (resumeTarget(.local, rows[@intCast(cur)])) {
        .local => |id| try testing.expectEqualStrings("two", id),
        else => return error.TestUnexpectedResult,
    }
    // Down at the end clamps — it does not wrap to the top of the roster.
    try testing.expectEqual(@as(i32, 1), moveCursor(cur, 1, rows.len));
}

test "the cursor enters, leaves at the top, and never enters an empty roster" {
    // Right into an empty roster is a no-op: there is nothing to point at.
    try testing.expectEqual(no_cursor, enterCursor(no_cursor, 0));
    try testing.expectEqual(@as(i32, 0), enterCursor(no_cursor, 3));
    // Already inside: Right holds position rather than jumping home.
    try testing.expectEqual(@as(i32, 2), enterCursor(2, 3));
    // Up off the first row hands navigation back to the machine list.
    try testing.expectEqual(no_cursor, moveCursor(0, -1, 3));
    // And a roster that emptied under the cursor cannot hold one.
    try testing.expectEqual(no_cursor, moveCursor(1, 1, 0));
}

test "clampCursor holds the cursor inside a roster that shrank" {
    try testing.expectEqual(@as(i32, 1), clampCursor(3, 2));
    try testing.expectEqual(@as(i32, 1), clampCursor(1, 2));
    try testing.expectEqual(no_cursor, clampCursor(0, 0));
    // Out of the roster stays out: a refetch must not pull the cursor in.
    try testing.expectEqual(no_cursor, clampCursor(no_cursor, 5));
}

test "the cursor card wears the chooser's own selection colors" {
    const bg: Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 };
    const accent: Rgb = .{ .r = 0x3D, .g = 0x8E, .b = 0xF8 };
    // Same functions the machine list's highlighted row uses — asserted, not
    // just intended, so a later divergence fails here.
    try testing.expectEqual(chooser_rows.selectionFill(bg, accent), cursorFill(bg, accent));
    try testing.expectEqual(chooser_rows.selectionBorder(bg, accent), cursorBorder(bg, accent));
    // And the ring is distinguishable from the fill it rings.
    try testing.expect(!std.meta.eql(cursorFill(bg, accent), cursorBorder(bg, accent)));
}
