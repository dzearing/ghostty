//! Git diff viewer panes: what a `git-status:` / `git-diff:<revspec>` location
//! MEANS, which `git` invocations it turns into, how git's answers parse, and
//! the `window.__viewer` calls that put the result on screen (T463).
//!
//! The win32 half of Mac's `ViewerDiffSpec.swift` + the parsing half of
//! `ViewerGit.swift`. Everything here is pure — string arithmetic, argv shaping
//! and JSON building, no process, no filesystem, no COM — so it asserts in the
//! none lane on either seat. `ViewerDiffProbe.zig` is the half that spawns git,
//! and `ViewerPane.zig` is the half that talks to the page.
//!
//! ## The location IS the spec
//!
//! A diff pane's location is a scheme rather than a path, which is what buys
//! every viewer affordance for free: the address bar shows and accepts it,
//! `+list --json` reports it as the pane's `url`, `+reload` re-runs it, and the
//! session manifest restores the pane by re-running it against the origin
//! directory. Two schemes, both typeable by a human:
//!
//! * `git-status:` — the working tree: staged, unstaged and untracked.
//! * `git-diff:<revspec>` — anything git can diff. A range (`a..b`, `a...b`)
//!   goes to git verbatim; a bare revision means THAT COMMIT's own changes,
//!   which is what "show me what changed in <sha>" means to a person; an empty
//!   revspec means "this branch against its default base", resolved at run time.
//!
//! Which repository it applies to is NOT part of it: like a relative `--view=`
//! path, it resolves against `--working-directory` (else the caller's cwd).
//!
//! `cli/view_arg.isDiffView` is the CLI's copy of the classification and is
//! documented as mirroring `ViewerDiffSpec.parse`; it is IMPORTED here rather
//! than repeated, so the CLI that declines to path-resolve a value and the
//! viewer that renders it can never disagree about which values are diffs.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_arg = @import("../../cli/view_arg.zig");
const content = @import("viewer_content.zig");

pub const status_scheme = "git-status:";
pub const diff_scheme = "git-diff:";

/// What a diff pane is showing. Revspec slices BORROW from the location they
/// were parsed out of, which is the pane's own `location` buffer — a spec never
/// outlives the string it came from.
pub const Kind = union(enum) {
    /// The working tree — staged, unstaged and untracked, kept apart.
    status,
    /// A revision range, exactly as git understands it.
    range: []const u8,
    /// One commit's own diff.
    commit: []const u8,
    /// The current branch against its default base. Becomes a `.range` once git
    /// has said what that base is (see `resolved`).
    branch,
};

pub const Spec = struct {
    kind: Kind,

    /// True while the content can change without a git command being run — i.e.
    /// by the user saving a file. Only the working tree can; a commit or a
    /// range is a fixed pair of trees.
    pub fn tracksWorkingTree(self: Spec) bool {
        return self.kind == .status;
    }

    /// What the pane's title shows.
    pub fn title(self: Spec) []const u8 {
        return switch (self.kind) {
            .status => "Working tree",
            .branch => "Branch changes",
            .range => |s| s,
            .commit => |r| r,
        };
    }

    /// The canonical location text for this spec, written into `buf`. A pane
    /// stores THIS rather than what was typed, so `git-status` and
    /// `git-status:` are one location in the address bar, in `+list --json` and
    /// in the session manifest. Null only when the revspec cannot fit.
    pub fn canonicalLocation(self: Spec, buf: []u8) ?[]const u8 {
        const rev: []const u8 = switch (self.kind) {
            .status => return copy(buf, status_scheme),
            .branch => return copy(buf, diff_scheme),
            .range => |s| s,
            .commit => |r| r,
        };
        if (diff_scheme.len + rev.len > buf.len) return null;
        @memcpy(buf[0..diff_scheme.len], diff_scheme);
        @memcpy(buf[diff_scheme.len..][0..rev.len], rev);
        return buf[0 .. diff_scheme.len + rev.len];
    }

    /// This spec with `.branch` replaced by the range it stands for, built into
    /// `buf`. Everything else passes through, so a caller can resolve
    /// unconditionally.
    pub fn resolved(self: Spec, buf: []u8, default_base: []const u8) Spec {
        if (self.kind != .branch) return self;
        const suffix = "...HEAD";
        if (default_base.len + suffix.len > buf.len) return self;
        @memcpy(buf[0..default_base.len], default_base);
        @memcpy(buf[default_base.len..][0..suffix.len], suffix);
        return .{ .kind = .{ .range = buf[0 .. default_base.len + suffix.len] } };
    }
};

fn copy(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// True when a location names a diff rather than a file or a website.
pub fn isDiffLocation(location: []const u8) bool {
    return parse(location) != null;
}

/// Parse a location, or null when it does not name a diff.
///
/// The trailing colon is optional so a bare `git-status` works — it is the form
/// a human types, and there is nothing after the colon to lose. It is optional
/// ONLY when nothing follows it, which is what keeps `git-diff-notes.md` a file
/// (`view_arg.isDiffView` owns that test, and the CLI relies on the same one to
/// decide whether to path-resolve the value).
pub fn parse(location: []const u8) ?Spec {
    const trimmed = std.mem.trim(u8, location, " \t\r\n");
    if (!view_arg.isDiffView(trimmed)) return null;

    if (std.mem.startsWith(u8, trimmed, "git-status")) {
        // `git-status:<anything>` is still the working tree: there is no second
        // argument to it, and rendering something else would be worse than
        // ignoring the noise.
        return .{ .kind = .status };
    }

    const rev = if (trimmed.len > diff_scheme.len)
        std.mem.trim(u8, trimmed[diff_scheme.len..], " \t")
    else
        "";
    if (rev.len == 0) return .{ .kind = .branch };
    // A range is anything git would read as one. `..` covers `a..b` and
    // `a...b`; a leading `^` or a `--` pathspec would make it a range
    // expression too, but those are not what a person types into a pane.
    if (std.mem.indexOf(u8, rev, "..") != null) return .{ .kind = .{ .range = rev } };
    return .{ .kind = .{ .commit = rev } };
}

// -------------------------------------------------------------------------
// Files
// -------------------------------------------------------------------------

/// Which side of the working tree an entry came from. Only `.status` produces
/// more than one; a range or a commit is all `.committed`.
pub const Origin = enum {
    staged,
    unstaged,
    untracked,
    committed,

    /// The section heading this origin groups under, or null when the diff has
    /// one section and a heading would be noise.
    pub fn sectionTitle(self: Origin) ?[]const u8 {
        return switch (self) {
            .staged => "Staged",
            .unstaged => "Changes",
            .untracked => "Untracked",
            .committed => null,
        };
    }

    pub fn name(self: Origin) []const u8 {
        return @tagName(self);
    }
};

pub const Status = enum {
    added,
    modified,
    deleted,
    renamed,
    copied,
    type_changed,
    unmerged,
    unknown,

    /// The one-letter badge, matching git's own `--name-status` letters so the
    /// pane reads like the CLI.
    pub fn letter(self: Status) []const u8 {
        return switch (self) {
            .added => "A",
            .modified => "M",
            .deleted => "D",
            .renamed => "R",
            .copied => "C",
            .type_changed => "T",
            .unmerged => "U",
            .unknown => "?",
        };
    }

    /// The page's CSS class suffix (`d-status-<name>`), which is Mac's
    /// `Status.rawValue` — camelCase, not Zig's snake_case tag.
    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .type_changed => "typeChanged",
            else => @tagName(self),
        };
    }

    /// Rename/copy letters carry a similarity score (`R096`), so only the first
    /// character is read.
    pub fn parse(raw: []const u8) Status {
        if (raw.len == 0) return .unknown;
        return switch (raw[0]) {
            'A' => .added,
            'M' => .modified,
            'D' => .deleted,
            'R' => .renamed,
            'C' => .copied,
            'T' => .type_changed,
            'U' => .unmerged,
            else => .unknown,
        };
    }
};

/// One entry in a diff's file list. Paths borrow from the git output they were
/// parsed from; `ViewerDiffProbe` owns the copies that outlive it.
pub const File = struct {
    path: []const u8,
    old_path: ?[]const u8 = null,
    status: Status,
    origin: Origin,
    additions: u32 = 0,
    deletions: u32 = 0,
    /// git reported `-` line counts: there is no text to render.
    binary: bool = false,
};

// -------------------------------------------------------------------------
// Git invocations
// -------------------------------------------------------------------------
//
// Every argument list below is exactly what gets handed to git, so the mapping
// from "what the user asked for" to "what we run" is one readable table rather
// than string-building scattered through the loader.

/// Flags every diff invocation carries.
///
/// `-z` + `core.quotepath=false` (in the prefix) so paths arrive as raw bytes
/// rather than C-quoted escapes; `-M` so a rename reads as a rename instead of
/// a delete plus an add; `--no-ext-diff` so a user's configured difftool can
/// never be launched from a pane; `--no-color` because the page does its own.
pub const common_flags = [_][]const u8{ "--no-color", "--no-ext-diff", "-M", "-z" };

/// Patch flags. `-z` is deliberately absent — it NUL-terminates the paths in
/// the patch header, which would corrupt the very text the page parses.
pub const patch_flags = [_][]const u8{ "--no-color", "--no-ext-diff", "-M" };

/// Enough for the longest invocation here: the 5-word prefix, `show --format=
/// -m --first-parent <rev>`, three patch flags, `--unified=3`, `--` and two
/// paths.
pub const max_args = 24;

/// A built git command line. By value — no allocator, no ownership — so the
/// shaping is pure and the strings all borrow from the spec and the repo path.
pub const Argv = struct {
    buf: [max_args][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *Argv, a: []const u8) void {
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = a;
        self.len += 1;
    }

    fn pushAll(self: *Argv, args: []const []const u8) void {
        for (args) |a| self.push(a);
    }

    pub fn slice(self: *const Argv) []const []const u8 {
        return self.buf[0..self.len];
    }
};

/// The words every invocation starts with: the binary, the repository, and the
/// quoting config that makes `-z` output raw bytes.
fn prefix(git: []const u8, repo: []const u8) Argv {
    var a: Argv = .{};
    a.pushAll(&.{ git, "-C", repo, "-c", "core.quotepath=false" });
    return a;
}

/// The sections a spec's file list is built from, in display order.
///
/// `.status` yields three because that is what a user sees in `git status`:
/// what is staged, what is not, and what git is not tracking at all. Collapsing
/// them would lose the distinction they asked to see.
pub fn origins(spec: Spec) []const Origin {
    return switch (spec.kind) {
        .status => &.{ .staged, .unstaged, .untracked },
        .range, .commit => &.{.committed},
        // Unresolved: the caller must `resolved()` first.
        .branch => &.{},
    };
}

/// `git show` for one commit, with the diff format the caller wants.
///
/// `--format=` drops the commit header (only the diff body is wanted).
/// `-m --first-parent` is what makes a MERGE commit show anything at all: git
/// suppresses a merge's diff by default, and first-parent is the "what did this
/// merge bring in" reading a person means.
fn pushShow(a: *Argv, rev: []const u8) void {
    a.pushAll(&.{ "show", "--format=", "-m", "--first-parent", rev });
}

/// The invocation whose output names the files and their statuses.
pub fn nameStatusArgv(spec: Spec, origin: Origin, git: []const u8, repo: []const u8) ?Argv {
    var a = prefix(git, repo);
    switch (origin) {
        // Not a diff at all: git has nothing to compare an untracked file
        // against, so the list comes from ls-files and the "patch" is
        // synthesized as an all-added file.
        .untracked => a.pushAll(&.{ "ls-files", "--others", "--exclude-standard", "-z" }),
        .staged => {
            a.pushAll(&.{ "diff", "--cached", "--name-status" });
            a.pushAll(&common_flags);
        },
        .unstaged => {
            a.pushAll(&.{ "diff", "--name-status" });
            a.pushAll(&common_flags);
        },
        .committed => switch (spec.kind) {
            .range => |s| {
                a.pushAll(&.{ "diff", s, "--name-status" });
                a.pushAll(&common_flags);
            },
            .commit => |r| {
                pushShow(&a, r);
                a.push("--name-status");
                a.pushAll(&common_flags);
            },
            else => return null,
        },
    }
    return a;
}

/// The invocation whose output carries each file's `+N −M`, or null for a
/// section that has no such command (untracked files are counted by reading
/// them).
pub fn numstatArgv(spec: Spec, origin: Origin, git: []const u8, repo: []const u8) ?Argv {
    var a = prefix(git, repo);
    switch (origin) {
        .untracked => return null,
        .staged => {
            a.pushAll(&.{ "diff", "--cached", "--numstat" });
            a.pushAll(&common_flags);
        },
        .unstaged => {
            a.pushAll(&.{ "diff", "--numstat" });
            a.pushAll(&common_flags);
        },
        .committed => switch (spec.kind) {
            .range => |s| {
                a.pushAll(&.{ "diff", s, "--numstat" });
                a.pushAll(&common_flags);
            },
            .commit => |r| {
                pushShow(&a, r);
                a.push("--numstat");
                a.pushAll(&common_flags);
            },
            else => return null,
        },
    }
    return a;
}

/// The invocation that produces one file's patch, or null when the content has
/// to be synthesized instead (an untracked file, which git will not diff
/// because there is no other side).
///
/// Paths go after `--` so a file named like a revision can never be read as
/// one. A rename passes BOTH paths, which is what makes git emit the rename's
/// patch rather than reporting an unknown path.
pub fn patchArgv(spec: Spec, file: File, git: []const u8, repo: []const u8) ?Argv {
    if (file.origin == .untracked) return null;
    var a = prefix(git, repo);
    switch (spec.kind) {
        .status => {
            a.push("diff");
            if (file.origin == .staged) a.push("--cached");
        },
        .range => |s| a.pushAll(&.{ "diff", s }),
        .commit => |r| pushShow(&a, r),
        .branch => return null,
    }
    a.pushAll(&patch_flags);
    a.push("--unified=3");
    a.push("--");
    if (file.old_path) |old| a.push(old);
    a.push(file.path);
    return a;
}

/// The bases a bare `git-diff:` tries, in the order a human means by "the
/// mainline". `origin/HEAD` is asked first and separately (`symbolicRefArgv`),
/// because it NAMES the remote's default branch rather than being a guess —
/// plenty of clones never set it, hence these.
pub const default_base_candidates = [_][]const u8{ "main", "master", "origin/main", "origin/master" };

pub fn symbolicRefArgv(git: []const u8, repo: []const u8) Argv {
    var a = prefix(git, repo);
    a.pushAll(&.{ "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" });
    return a;
}

/// `refs/remotes/origin/main` → `origin/main`. Null for anything else, so a
/// repo without the ref falls through to the candidates rather than diffing
/// against a ref that does not exist.
pub fn parseSymbolicRef(stdout: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    const p = "refs/remotes/";
    if (!std.mem.startsWith(u8, trimmed, p)) return null;
    const rest = trimmed[p.len..];
    return if (rest.len == 0) null else rest;
}

pub fn verifyRefArgv(git: []const u8, repo: []const u8, ref: []const u8) Argv {
    var a = prefix(git, repo);
    a.pushAll(&.{ "rev-parse", "--verify", "--quiet", ref });
    return a;
}

// -------------------------------------------------------------------------
// Output parsing
// -------------------------------------------------------------------------

/// Split `-z` output into its NUL-terminated fields, dropping the empty tail
/// the final terminator produces. Fields borrow from `out`.
pub const Fields = struct {
    out: []const u8,
    i: usize = 0,

    pub fn next(self: *Fields) ?[]const u8 {
        if (self.i >= self.out.len) return null;
        const end = std.mem.indexOfScalarPos(u8, self.out, self.i, 0) orelse self.out.len;
        const field = self.out[self.i..end];
        self.i = end + 1;
        // A trailing terminator yields an empty field that is not a record.
        if (field.len == 0 and self.i >= self.out.len) return null;
        return field;
    }
};

pub fn fields(out: []const u8) Fields {
    return .{ .out = out };
}

pub const NameStatus = struct {
    status: Status,
    path: []const u8,
    old_path: ?[]const u8 = null,
};

/// Walk `--name-status -z` output.
///
/// With `-z` the status letter is its own NUL-terminated field, and a
/// rename/copy is followed by TWO paths rather than one — which is the whole
/// reason this cannot be a line split.
pub const NameStatusIterator = struct {
    f: Fields,

    pub fn next(self: *NameStatusIterator) ?NameStatus {
        while (self.f.next()) |raw| {
            if (raw.len == 0) continue;
            const status = Status.parse(raw);
            if (raw[0] == 'R' or raw[0] == 'C') {
                const source = self.f.next() orelse return null;
                const destination = self.f.next() orelse return null;
                return .{ .status = status, .path = destination, .old_path = source };
            }
            const path = self.f.next() orelse return null;
            return .{ .status = status, .path = path };
        }
        return null;
    }
};

pub fn nameStatus(out: []const u8) NameStatusIterator {
    return .{ .f = fields(out) };
}

pub const LineCount = struct {
    path: []const u8,
    additions: u32 = 0,
    deletions: u32 = 0,
    binary: bool = false,
};

/// Walk `--numstat -z` output.
///
/// A binary file reports `-` for both counts. A rename leaves the path field
/// empty and follows with two NUL-terminated paths, the same shape
/// `--name-status` uses — the SECOND of which is the file's current path, which
/// is what the counts are keyed by.
pub const NumstatIterator = struct {
    f: Fields,

    pub fn next(self: *NumstatIterator) ?LineCount {
        while (self.f.next()) |record| {
            if (record.len == 0) continue;
            var parts = std.mem.splitScalar(u8, record, '\t');
            const add_raw = parts.next() orelse continue;
            const del_raw = parts.next() orelse continue;
            var path = parts.rest();
            if (path.len == 0) {
                _ = self.f.next() orelse return null; // the old path
                path = self.f.next() orelse return null;
            }
            const additions = std.fmt.parseInt(u32, add_raw, 10) catch null;
            const deletions = std.fmt.parseInt(u32, del_raw, 10) catch null;
            return .{
                .path = path,
                .additions = additions orelse 0,
                .deletions = deletions orelse 0,
                // git prints `-` for both counts on a binary file.
                .binary = additions == null and deletions == null,
            };
        }
        return null;
    }
};

pub fn numstat(out: []const u8) NumstatIterator {
    return .{ .f = fields(out) };
}

// -------------------------------------------------------------------------
// The `window.__viewer` calls
// -------------------------------------------------------------------------

/// What the page's diff header shows.
pub const Listing = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    file_count: usize = 0,
    additions: u64 = 0,
    deletions: u64 = 0,
    /// `unified` or `split`, the page's own spelling.
    style: []const u8 = "unified",
    /// Set when the listing is empty for a reason worth explaining — an error,
    /// or a clean working tree. The page renders it as a notice card.
    message: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

/// `window.__viewer.setDiffListing({…})`. Caller owns the result.
pub fn setDiffListingCall(alloc: Allocator, l: Listing) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "window.__viewer.setDiffListing({");
    try appendString(alloc, &out, "title", l.title, true);
    try appendString(alloc, &out, "subtitle", l.subtitle, false);
    try appendNumber(alloc, &out, "fileCount", l.file_count);
    try appendNumber(alloc, &out, "additions", l.additions);
    try appendNumber(alloc, &out, "deletions", l.deletions);
    try appendString(alloc, &out, "style", l.style, false);
    if (l.message) |m| try appendString(alloc, &out, "message", m, false);
    if (l.detail) |d| try appendString(alloc, &out, "detail", d, false);
    try out.appendSlice(alloc, "})");
    return try out.toOwnedSlice(alloc);
}

/// One file's patch, as the page wants it.
pub const FilePayload = struct {
    path: []const u8,
    old_path: ?[]const u8 = null,
    status: Status,
    origin: Origin,
    additions: u32 = 0,
    deletions: u32 = 0,
    binary: bool = false,
    /// The highlight.js language, or "" for plain text.
    language: []const u8 = "",
    patch: []const u8 = "",
    /// `first` / `last` when the pane is walking changes, else null.
    scroll_to: ?[]const u8 = null,
};

/// `window.__viewer.setDiffFile({…})`. Caller owns the result.
pub fn setDiffFileCall(alloc: Allocator, f: FilePayload) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "window.__viewer.setDiffFile({");
    try appendString(alloc, &out, "path", f.path, true);
    if (f.old_path) |o| try appendString(alloc, &out, "oldPath", o, false);
    try appendString(alloc, &out, "status", f.status.name(), false);
    try appendString(alloc, &out, "statusLetter", f.status.letter(), false);
    try appendString(alloc, &out, "origin", f.origin.name(), false);
    if (f.origin.sectionTitle()) |s| try appendString(alloc, &out, "section", s, false);
    try appendNumber(alloc, &out, "additions", f.additions);
    try appendNumber(alloc, &out, "deletions", f.deletions);
    try out.appendSlice(alloc, ", \"binary\": ");
    try out.appendSlice(alloc, if (f.binary) "true" else "false");
    try appendString(alloc, &out, "language", f.language, false);
    try appendString(alloc, &out, "patch", f.patch, false);
    if (f.scroll_to) |s| try appendString(alloc, &out, "scrollTo", s, false);
    try out.appendSlice(alloc, "})");
    return try out.toOwnedSlice(alloc);
}

fn appendString(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
    first: bool,
) Allocator.Error!void {
    if (!first) try out.appendSlice(alloc, ", ");
    try content.appendJsString(alloc, out, key);
    try out.appendSlice(alloc, ": ");
    try content.appendJsString(alloc, out, value);
}

fn appendNumber(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: u64,
) Allocator.Error!void {
    try out.appendSlice(alloc, ", ");
    try content.appendJsString(alloc, out, key);
    try out.print(alloc, ": {d}", .{value});
}

/// The line under the diff's title: which repo, and which kind of diff (Mac's
/// `diffSubtitle`). Written into `buf`.
pub fn subtitle(buf: []u8, spec: Spec, repo: ?[]const u8) []const u8 {
    var len: usize = 0;
    if (repo) |r| {
        const name = std.fs.path.basename(r);
        if (name.len <= buf.len) {
            @memcpy(buf[0..name.len], name);
            len = name.len;
        }
    }
    if (spec.kind == .status) {
        const tail = "staged, unstaged and untracked changes";
        const sep: []const u8 = if (len > 0) " \u{b7} " else "";
        if (len + sep.len + tail.len <= buf.len) {
            @memcpy(buf[len..][0..sep.len], sep);
            len += sep.len;
            @memcpy(buf[len..][0..tail.len], tail);
            len += tail.len;
        }
    }
    return buf[0..len];
}

/// What a pane with no files says, which is not the same sentence for a clean
/// working tree as for a range that changed nothing.
pub fn emptyMessage(buf: []u8, spec: Spec) []const u8 {
    if (spec.kind == .status) return copy(buf, "The working tree is clean.") orelse "";
    return std.fmt.bufPrint(buf, "No changes in {s}.", .{spec.title()}) catch
        "No changes.";
}

/// Why a diff pane has nothing to show. Each case is something the user can act
/// on, which is the point of not collapsing them into one "error".
pub const Failure = union(enum) {
    /// The pane was not opened from a directory at all.
    no_directory,
    /// That directory is in no working tree.
    not_a_repository: []const u8,
    /// A bare `git-diff:` in a repo with no main/master/origin HEAD.
    no_default_base,
    /// git ran and refused — almost always a revspec that names nothing.
    git_failed: []const u8,

    pub fn title(self: Failure) []const u8 {
        return switch (self) {
            .no_directory => "No directory",
            .not_a_repository => "Not a git repository",
            .no_default_base => "No default branch",
            .git_failed => "git could not produce this diff",
        };
    }

    /// The explanatory line, written into `buf`.
    pub fn detail(self: Failure, buf: []u8) []const u8 {
        return switch (self) {
            .no_directory => copy(
                buf,
                "This pane was not opened from a directory, so there is no " ++
                    "repository to diff. Reopen it with --working-directory=<path>.",
            ) orelse "",
            .not_a_repository => |p| std.fmt.bufPrint(
                buf,
                "{s} is not inside a git working tree.",
                .{p},
            ) catch "That directory is not inside a git working tree.",
            .no_default_base => copy(
                buf,
                "This repository has no main, master, or origin/HEAD to compare " ++
                    "against. Name a base explicitly, e.g. git-diff:develop...HEAD.",
            ) orelse "",
            .git_failed => |s| std.fmt.bufPrint(
                buf,
                "git rejected {s}. Check the revision names.",
                .{s},
            ) catch "git rejected that revision. Check the revision names.",
        };
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the schemes parse the way the CLI classifies them" {
    try testing.expectEqual(Kind.status, parse("git-status:").?.kind);
    try testing.expectEqual(Kind.status, parse("git-status").?.kind);
    try testing.expectEqual(Kind.status, parse("  git-status:  ").?.kind);
    // A second argument to git-status is noise, not a different diff.
    try testing.expectEqual(Kind.status, parse("git-status:whatever").?.kind);

    try testing.expectEqual(Kind.branch, parse("git-diff:").?.kind);
    try testing.expectEqual(Kind.branch, parse("git-diff").?.kind);
    try testing.expectEqualStrings("main...HEAD", parse("git-diff:main...HEAD").?.kind.range);
    try testing.expectEqualStrings("v1.2.0..v1.3.0", parse("git-diff:v1.2.0..v1.3.0").?.kind.range);
    try testing.expectEqualStrings("a1b2c3d", parse("git-diff:a1b2c3d").?.kind.commit);

    // The near-miss the CLI's own test guards: a FILE whose name starts with
    // the same letters must never be read as a diff.
    try testing.expect(parse("git-diff-notes.md") == null);
    try testing.expect(parse("git-status-report.txt") == null);
    try testing.expect(parse("README.md") == null);
    try testing.expect(parse("https://example.com") == null);
    try testing.expect(parse("") == null);
}

test "a spec canonicalizes its own location" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("git-status:", parse("git-status").?.canonicalLocation(&buf).?);
    try testing.expectEqualStrings("git-diff:", parse("git-diff").?.canonicalLocation(&buf).?);
    try testing.expectEqualStrings(
        "git-diff:main...HEAD",
        parse("git-diff: main...HEAD ").?.canonicalLocation(&buf).?,
    );
}

test "titles, tracking and the branch resolution" {
    try testing.expectEqualStrings("Working tree", (Spec{ .kind = .status }).title());
    try testing.expectEqualStrings("Branch changes", (Spec{ .kind = .branch }).title());
    try testing.expectEqualStrings("abc123", (Spec{ .kind = .{ .commit = "abc123" } }).title());

    try testing.expect((Spec{ .kind = .status }).tracksWorkingTree());
    try testing.expect(!(Spec{ .kind = .branch }).tracksWorkingTree());
    try testing.expect(!(Spec{ .kind = .{ .range = "a..b" } }).tracksWorkingTree());

    var buf: [64]u8 = undefined;
    const resolved = (Spec{ .kind = .branch }).resolved(&buf, "origin/main");
    try testing.expectEqualStrings("origin/main...HEAD", resolved.kind.range);
    // Everything else passes through untouched, so a caller resolves blind.
    const commit = (Spec{ .kind = .{ .commit = "abc" } }).resolved(&buf, "main");
    try testing.expectEqualStrings("abc", commit.kind.commit);
}

test "git invocations are the table they are documented as" {
    const status: Spec = .{ .kind = .status };
    {
        const a = nameStatusArgv(status, .staged, "git", "D:\\repo").?;
        try testing.expectEqualDeep(@as([]const []const u8, &.{
            "git",       "-C",             "D:\\repo", "-c",   "core.quotepath=false",
            "diff",      "--cached",       "--name-status",    "--no-color",
            "--no-ext-diff", "-M",         "-z",
        }), a.slice());
    }
    {
        const a = nameStatusArgv(status, .untracked, "git", "D:\\repo").?;
        try testing.expectEqualDeep(@as([]const []const u8, &.{
            "git", "-C", "D:\\repo", "-c", "core.quotepath=false",
            "ls-files", "--others", "--exclude-standard", "-z",
        }), a.slice());
        // Untracked files have no numstat command: they are counted by reading.
        try testing.expect(numstatArgv(status, .untracked, "git", "D:\\repo") == null);
    }
    {
        // A bare revision is `git show`, not a diff against it — and the merge
        // flags are what make a merge commit show anything at all.
        const spec: Spec = .{ .kind = .{ .commit = "a1b2c3d" } };
        const a = nameStatusArgv(spec, .committed, "git", "D:\\repo").?;
        try testing.expectEqualStrings("show", a.slice()[5]);
        try testing.expectEqualStrings("--format=", a.slice()[6]);
        try testing.expectEqualStrings("-m", a.slice()[7]);
        try testing.expectEqualStrings("--first-parent", a.slice()[8]);
        try testing.expectEqualStrings("a1b2c3d", a.slice()[9]);
    }
    {
        // A range goes to git verbatim.
        const spec: Spec = .{ .kind = .{ .range = "main...HEAD" } };
        const a = numstatArgv(spec, .committed, "git", "D:\\repo").?;
        try testing.expectEqualStrings("diff", a.slice()[5]);
        try testing.expectEqualStrings("main...HEAD", a.slice()[6]);
        try testing.expectEqualStrings("--numstat", a.slice()[7]);
    }
    // An unresolved `.branch` shapes nothing: the caller must resolve first.
    try testing.expect(nameStatusArgv(.{ .kind = .branch }, .committed, "git", "r") == null);
    try testing.expectEqual(@as(usize, 0), origins(.{ .kind = .branch }).len);
    try testing.expectEqual(@as(usize, 3), origins(.{ .kind = .status }).len);
}

test "a patch names its paths after -- and passes both sides of a rename" {
    const spec: Spec = .{ .kind = .status };
    const file: File = .{
        .path = "new.zig",
        .old_path = "old.zig",
        .status = .renamed,
        .origin = .staged,
    };
    const a = patchArgv(spec, file, "git", "D:\\repo").?;
    const s = a.slice();
    try testing.expectEqualStrings("diff", s[5]);
    try testing.expectEqualStrings("--cached", s[6]);
    try testing.expectEqualStrings("--unified=3", s[s.len - 4]);
    try testing.expectEqualStrings("--", s[s.len - 3]);
    try testing.expectEqualStrings("old.zig", s[s.len - 2]);
    try testing.expectEqualStrings("new.zig", s[s.len - 1]);
    // `-z` must NOT reach a patch: it would NUL-terminate the header paths the
    // page parses.
    for (s) |arg| try testing.expect(!std.mem.eql(u8, arg, "-z"));

    // An untracked file has no other side, so there is nothing to run.
    try testing.expect(patchArgv(spec, .{
        .path = "x",
        .status = .added,
        .origin = .untracked,
    }, "git", "D:\\repo") == null);
}

test "name-status parses -z fields, renames included" {
    var it = nameStatus("M\x00src/a.zig\x00R096\x00old.zig\x00new.zig\x00A\x00b.txt\x00");
    const a = it.next().?;
    try testing.expectEqual(Status.modified, a.status);
    try testing.expectEqualStrings("src/a.zig", a.path);
    try testing.expect(a.old_path == null);

    const b = it.next().?;
    try testing.expectEqual(Status.renamed, b.status);
    try testing.expectEqualStrings("new.zig", b.path);
    try testing.expectEqualStrings("old.zig", b.old_path.?);

    const c = it.next().?;
    try testing.expectEqual(Status.added, c.status);
    try testing.expectEqualStrings("b.txt", c.path);
    try testing.expect(it.next() == null);

    // Truncated output stops rather than inventing an entry.
    var short = nameStatus("M\x00");
    try testing.expect(short.next() == null);
    var empty = nameStatus("");
    try testing.expect(empty.next() == null);
}

test "numstat parses counts, binaries and renames" {
    var it = numstat("3\t1\tsrc/a.zig\x00-\t-\timg.png\x0010\t0\t\x00old.zig\x00new.zig\x00");
    const a = it.next().?;
    try testing.expectEqualStrings("src/a.zig", a.path);
    try testing.expectEqual(@as(u32, 3), a.additions);
    try testing.expectEqual(@as(u32, 1), a.deletions);
    try testing.expect(!a.binary);

    const b = it.next().?;
    try testing.expectEqualStrings("img.png", b.path);
    try testing.expect(b.binary);

    // A rename's counts are keyed by the file's CURRENT path.
    const c = it.next().?;
    try testing.expectEqualStrings("new.zig", c.path);
    try testing.expectEqual(@as(u32, 10), c.additions);
    try testing.expect(it.next() == null);
}

test "the origin HEAD ref parses, or falls through" {
    try testing.expectEqualStrings(
        "origin/main",
        parseSymbolicRef("refs/remotes/origin/main\n").?,
    );
    try testing.expect(parseSymbolicRef("") == null);
    try testing.expect(parseSymbolicRef("refs/heads/main\n") == null);
}

test "the page calls are the shape diff.js reads" {
    const alloc = testing.allocator;
    {
        const js = try setDiffListingCall(alloc, .{
            .title = "Working tree",
            .subtitle = "ghoztty \u{b7} staged, unstaged and untracked changes",
            .file_count = 2,
            .additions = 10,
            .deletions = 3,
        });
        defer alloc.free(js);
        try testing.expectEqualStrings(
            "window.__viewer.setDiffListing({\"title\": \"Working tree\", " ++
                "\"subtitle\": \"ghoztty \u{b7} staged, unstaged and untracked changes\", " ++
                "\"fileCount\": 2, \"additions\": 10, \"deletions\": 3, " ++
                "\"style\": \"unified\"})",
            js,
        );
    }
    {
        // A message and its detail ride the same call; the page renders them as
        // a notice card instead of a diff.
        const js = try setDiffListingCall(alloc, .{
            .title = "Working tree",
            .message = "Not a git repository",
            .detail = "D:\\tmp is not inside a git working tree.",
        });
        defer alloc.free(js);
        try testing.expect(std.mem.indexOf(u8, js, "\"message\": \"Not a git repository\"") != null);
        // The detail's backslashes survive as a JS string, not as escapes.
        try testing.expect(std.mem.indexOf(u8, js, "D:\\\\tmp") != null);
    }
    {
        const js = try setDiffFileCall(alloc, .{
            .path = "src/a.zig",
            .status = .modified,
            .origin = .unstaged,
            .additions = 3,
            .deletions = 1,
            .language = "zig",
            .patch = "@@ -1 +1 @@\n-a\n+b\n",
        });
        defer alloc.free(js);
        try testing.expect(std.mem.startsWith(u8, js, "window.__viewer.setDiffFile({"));
        try testing.expect(std.mem.indexOf(u8, js, "\"path\": \"src/a.zig\"") != null);
        try testing.expect(std.mem.indexOf(u8, js, "\"statusLetter\": \"M\"") != null);
        try testing.expect(std.mem.indexOf(u8, js, "\"section\": \"Changes\"") != null);
        try testing.expect(std.mem.indexOf(u8, js, "\"binary\": false") != null);
        // A raw newline would end the JS string literal mid-patch.
        try testing.expect(std.mem.indexOf(u8, js, "\\n") != null);
        try testing.expect(std.mem.indexOfScalar(u8, js, '\n') == null);
    }
    {
        // A committed file has no section heading — one section needs no label.
        const js = try setDiffFileCall(alloc, .{
            .path = "a",
            .status = .added,
            .origin = .committed,
            .binary = true,
        });
        defer alloc.free(js);
        try testing.expect(std.mem.indexOf(u8, js, "\"section\"") == null);
        try testing.expect(std.mem.indexOf(u8, js, "\"binary\": true") != null);
    }
}

test "the subtitle and the empty message name what the pane is showing" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "ghoztty \u{b7} staged, unstaged and untracked changes",
        subtitle(&buf, .{ .kind = .status }, "D:\\git\\ghoztty"),
    );
    try testing.expectEqualStrings(
        "ghoztty",
        subtitle(&buf, .{ .kind = .{ .range = "a..b" } }, "D:\\git\\ghoztty"),
    );
    try testing.expectEqualStrings("", subtitle(&buf, .{ .kind = .{ .range = "a..b" } }, null));

    try testing.expectEqualStrings(
        "The working tree is clean.",
        emptyMessage(&buf, .{ .kind = .status }),
    );
    try testing.expectEqualStrings(
        "No changes in main...HEAD.",
        emptyMessage(&buf, .{ .kind = .{ .range = "main...HEAD" } }),
    );
}

test "every failure says what to do about it" {
    var buf: [256]u8 = undefined;
    const not_repo: Failure = .{ .not_a_repository = "D:\\tmp" };
    try testing.expectEqualStrings("Not a git repository", not_repo.title());
    try testing.expectEqualStrings(
        "D:\\tmp is not inside a git working tree.",
        not_repo.detail(&buf),
    );
    const bad: Failure = .{ .git_failed = "git-diff:nope" };
    try testing.expectEqualStrings(
        "git rejected git-diff:nope. Check the revision names.",
        bad.detail(&buf),
    );
    try testing.expect(std.mem.indexOf(
        u8,
        (Failure{ .no_default_base = {} }).detail(&buf),
        "git-diff:develop...HEAD",
    ) != null);
}
