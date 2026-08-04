import Foundation

/// What a diff viewer pane is showing, parsed from its location string.
///
/// A diff pane's location is a scheme rather than a path, so it survives every
/// affordance a file viewer already has for free: the address bar shows and
/// accepts it, `+list --json` reports it, and the session manifest restores the
/// pane by re-running it. Two schemes, both typeable by a human:
///
/// * `git-status:` — the working tree: staged, unstaged, and untracked.
/// * `git-diff:<revspec>` — anything git can diff. A range (`a..b`, `a...b`)
///   is passed to git verbatim; a bare revision means THAT COMMIT's own
///   changes, which is what "show me what changed in <sha>" means to a human;
///   an empty revspec means "this branch against its default base", resolved
///   at run time (see `ViewerGit.defaultBase`).
///
/// Which repository the spec applies to is NOT part of it: like a relative
/// `--view=` path, it resolves against `--working-directory` (else the caller's
/// cwd), which the pane records as its origin directory and the manifest
/// persists.
struct ViewerDiffSpec: Equatable {
    enum Kind: Equatable {
        /// The working tree — staged, unstaged, and untracked, kept apart.
        case status
        /// A revision range, exactly as git understands it.
        case range(String)
        /// One commit's own diff.
        case commit(String)
        /// The current branch against its default base. Resolved to a
        /// `.range` once git has told us what that base is.
        case branch
    }

    let kind: Kind

    /// The location text this spec was parsed from, so a pane round-trips the
    /// exact string the user typed back into the address bar and the manifest.
    let location: String

    static let statusScheme = "git-status:"
    static let diffScheme = "git-diff:"

    /// True when a location names a diff rather than a file or a website.
    /// Deliberately prefix-only: the sigil is the whole signal, the same way
    /// `http://` is for a website.
    static func isDiffLocation(_ location: String) -> Bool {
        parse(location) != nil
    }

    /// Parse a location, or nil if it does not name a diff.
    ///
    /// The trailing colon is optional so `git-status` alone works — it is the
    /// form a human types, and there is nothing after the colon to lose.
    static func parse(_ location: String) -> ViewerDiffSpec? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "git-status" || trimmed == statusScheme {
            return ViewerDiffSpec(kind: .status, location: statusScheme)
        }
        if trimmed.hasPrefix(statusScheme) {
            // `git-status:<anything>` is still the working tree; there is no
            // second argument to it, and silently rendering something else
            // would be worse than ignoring the noise.
            return ViewerDiffSpec(kind: .status, location: statusScheme)
        }
        guard trimmed == "git-diff" || trimmed.hasPrefix(diffScheme) else { return nil }
        let revspec = trimmed == "git-diff"
            ? ""
            : String(trimmed.dropFirst(diffScheme.count))
                .trimmingCharacters(in: .whitespaces)
        if revspec.isEmpty {
            return ViewerDiffSpec(kind: .branch, location: diffScheme)
        }
        let canonical = diffScheme + revspec
        // A range is anything git would read as one. `..` covers `a..b` and
        // `a...b`; a leading `^` or a `--` pathspec would make this a range
        // expression too, but those are not what a person types into a pane.
        if revspec.contains("..") {
            return ViewerDiffSpec(kind: .range(revspec), location: canonical)
        }
        return ViewerDiffSpec(kind: .commit(revspec), location: canonical)
    }

    /// The same spec with `.branch` replaced by the range it stands for.
    /// Everything else passes through, so callers can resolve unconditionally.
    func resolving(defaultBase: String) -> ViewerDiffSpec {
        guard case .branch = kind else { return self }
        return ViewerDiffSpec(kind: .range("\(defaultBase)...HEAD"), location: location)
    }

    /// True while the underlying content can change without a git command
    /// being run — i.e. by the user saving a file. Only the working tree can;
    /// a commit or a range is a fixed pair of trees.
    var tracksWorkingTree: Bool {
        if case .status = kind { return true }
        return false
    }

    /// What the pane's title bar shows.
    var title: String {
        switch kind {
        case .status: return "Working tree"
        case .branch: return "Branch changes"
        case .range(let spec): return spec
        case .commit(let rev): return rev
        }
    }

    // MARK: - Git invocations
    //
    // Every argument list here is exactly what gets handed to git (after the
    // runner prepends `-C <repo>`), so the mapping from "what the user asked
    // for" to "what we run" is one readable table rather than string-building
    // scattered through the loader.

    /// Flags every diff invocation carries.
    ///
    /// `-z` + `core.quotepath=false` so paths arrive as raw bytes rather than
    /// C-quoted escapes; `-M` so a rename reads as a rename instead of a
    /// delete plus an add; `--no-ext-diff` so a user's configured external
    /// difftool can never be launched from a pane; `--no-color` because we do
    /// our own coloring.
    static let commonFlags = ["--no-color", "--no-ext-diff", "-M", "-z"]

    /// A group of git invocations whose combined output is one section of the
    /// file list. Name/status and numstat are separate commands (git has no
    /// single format carrying both), joined afterwards by path.
    struct FileListQuery: Equatable {
        let origin: ViewerDiffFile.Origin
        let nameStatus: [String]
        let numstat: [String]
    }

    /// Every git invocation needed to build the file list, in display order.
    ///
    /// `.status` yields three sections because that is what the user sees in
    /// `git status`: what is staged, what is not, and what git isn't tracking
    /// at all. Collapsing them into one list would lose the distinction the
    /// user asked to see.
    func fileListQueries() -> [FileListQuery] {
        switch kind {
        case .status:
            return [
                FileListQuery(
                    origin: .staged,
                    nameStatus: ["diff", "--cached", "--name-status"] + Self.commonFlags,
                    numstat: ["diff", "--cached", "--numstat"] + Self.commonFlags),
                FileListQuery(
                    origin: .unstaged,
                    nameStatus: ["diff", "--name-status"] + Self.commonFlags,
                    numstat: ["diff", "--numstat"] + Self.commonFlags),
                FileListQuery(
                    origin: .untracked,
                    // Not a diff at all: git has nothing to compare an
                    // untracked file against, so the list comes from ls-files
                    // and the "patch" is synthesized as an all-added file.
                    nameStatus: ["ls-files", "--others", "--exclude-standard", "-z"],
                    numstat: []),
            ]
        case .range(let spec):
            return [
                FileListQuery(
                    origin: .committed,
                    nameStatus: ["diff", spec, "--name-status"] + Self.commonFlags,
                    numstat: ["diff", spec, "--numstat"] + Self.commonFlags),
            ]
        case .commit(let rev):
            return [
                FileListQuery(
                    origin: .committed,
                    nameStatus: Self.showArguments(rev, ["--name-status"] + Self.commonFlags),
                    numstat: Self.showArguments(rev, ["--numstat"] + Self.commonFlags)),
            ]
        case .branch:
            // Unresolved: the caller must call `resolving(defaultBase:)` first.
            return []
        }
    }

    /// `git show` for one commit, with the diff format the caller wants.
    ///
    /// `--format=` drops the commit header (we only want the diff body).
    /// `-m --first-parent` is what makes a MERGE commit show anything at all:
    /// git suppresses a merge's diff by default, and first-parent is the
    /// "what did this merge bring in" reading a person means.
    private static func showArguments(_ rev: String, _ format: [String]) -> [String] {
        ["show", "--format=", "-m", "--first-parent", rev] + format
    }

    /// The invocation that produces one file's patch, or nil when the file's
    /// content has to be synthesized instead (an untracked file, which git
    /// will not diff because it has no other side to diff against).
    ///
    /// Paths go after `--` so a file named like a revision can never be read
    /// as one. A rename passes BOTH paths, which is what makes git emit the
    /// rename's patch rather than reporting an unknown path.
    func patchArguments(for file: ViewerDiffFile) -> [String]? {
        let paths = file.oldPath.map { [$0, file.path] } ?? [file.path]
        let context = ["--unified=3"]
        switch (kind, file.origin) {
        case (_, .untracked):
            return nil
        case (.status, .staged):
            return ["diff", "--cached"] + Self.patchFlags + context + ["--"] + paths
        case (.status, _):
            return ["diff"] + Self.patchFlags + context + ["--"] + paths
        case (.range(let spec), _):
            return ["diff", spec] + Self.patchFlags + context + ["--"] + paths
        case (.commit(let rev), _):
            return Self.showArguments(rev, Self.patchFlags + context + ["--"] + paths)
        case (.branch, _):
            return nil
        }
    }

    /// Patch flags. `-z` is deliberately absent — it NUL-terminates paths in
    /// the patch header, which would corrupt the very text we are parsing.
    static let patchFlags = ["--no-color", "--no-ext-diff", "-M"]
}

/// One entry in a diff's file list.
struct ViewerDiffFile: Identifiable, Equatable {
    /// Which side of the working tree this entry came from. Only `.status`
    /// diffs produce more than one; a range or a commit is all `.committed`.
    enum Origin: String, Equatable {
        case staged
        case unstaged
        case untracked
        case committed

        /// The section heading this origin groups under, or nil when the diff
        /// has only one section and a heading would be noise.
        var sectionTitle: String? {
            switch self {
            case .staged: return "Staged"
            case .unstaged: return "Changes"
            case .untracked: return "Untracked"
            case .committed: return nil
            }
        }
    }

    enum Status: String, Equatable {
        case added
        case modified
        case deleted
        case renamed
        case copied
        case typeChanged
        case unmerged
        case unknown

        /// The one-letter badge the file tree shows, matching git's own
        /// `--name-status` letters so the pane reads like the CLI.
        var letter: String {
            switch self {
            case .added: return "A"
            case .modified: return "M"
            case .deleted: return "D"
            case .renamed: return "R"
            case .copied: return "C"
            case .typeChanged: return "T"
            case .unmerged: return "U"
            case .unknown: return "?"
            }
        }

        static func parse(_ raw: String) -> Status {
            // Rename/copy letters carry a similarity score (`R096`).
            switch raw.prefix(1) {
            case "A": return .added
            case "M": return .modified
            case "D": return .deleted
            case "R": return .renamed
            case "C": return .copied
            case "T": return .typeChanged
            case "U": return .unmerged
            default: return .unknown
            }
        }
    }

    /// Repo-relative path, and — for a rename — where it came from.
    let path: String
    let oldPath: String?
    let status: Status
    let origin: Origin
    let additions: Int
    let deletions: Int
    /// git reported `-` line counts: there is no text to render.
    let isBinary: Bool

    /// Stable across a refresh: a file can appear in more than one section of
    /// a status diff (staged AND unstaged), and those are different entries.
    var id: String { "\(origin.rawValue):\(path)" }

    /// The last path component — what the tree's leaf row shows.
    var name: String { (path as NSString).lastPathComponent }

    init(
        path: String,
        oldPath: String? = nil,
        status: Status,
        origin: Origin,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.origin = origin
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }
}
