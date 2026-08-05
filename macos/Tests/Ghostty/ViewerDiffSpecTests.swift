import Testing
@testable import Ghostty

/// The diff pane's contract with git: which locations name a diff, and which
/// command each one turns into.
///
/// Pure mapping, so it is checked here rather than by opening a pane — a wrong
/// argument list is the difference between "changes in this branch" and
/// "changes since this branch", and that is not a thing to discover visually.
struct ViewerDiffSpecTests {
    // MARK: - Parsing

    @Test func statusLocationsParse() {
        #expect(ViewerDiffSpec.parse("git-status:")?.kind == .status)
        // The colon is optional: `git-status` is what a person types, and
        // there is nothing after it to lose.
        #expect(ViewerDiffSpec.parse("git-status")?.kind == .status)
        // Whichever form was typed, the pane reports one canonical location,
        // so `+list --json` and the session manifest agree.
        #expect(ViewerDiffSpec.parse("git-status")?.location == "git-status:")
    }

    @Test func rangesAndCommitsAreDistinguished() {
        // Three-dot: "changes in this branch", i.e. against the merge base.
        #expect(ViewerDiffSpec.parse("git-diff:main...HEAD")?.kind == .range("main...HEAD"))
        #expect(ViewerDiffSpec.parse("git-diff:HEAD~3..HEAD")?.kind == .range("HEAD~3..HEAD"))
        // A bare revision is THAT COMMIT's own diff — what "show me what
        // changed in <sha>" means to a human.
        #expect(ViewerDiffSpec.parse("git-diff:abc1234")?.kind == .commit("abc1234"))
        #expect(ViewerDiffSpec.parse("git-diff:v1.2.0")?.kind == .commit("v1.2.0"))
    }

    @Test func emptyRevspecMeansTheBranchAgainstItsBase() {
        #expect(ViewerDiffSpec.parse("git-diff:")?.kind == .branch)
        #expect(ViewerDiffSpec.parse("git-diff")?.kind == .branch)
        // Resolution turns it into an ordinary three-dot range.
        let resolved = ViewerDiffSpec.parse("git-diff:")?.resolving(defaultBase: "origin/main")
        #expect(resolved?.kind == .range("origin/main...HEAD"))
        // ...and leaves an already-concrete spec alone.
        let range = ViewerDiffSpec.parse("git-diff:a..b")?.resolving(defaultBase: "main")
        #expect(range?.kind == .range("a..b"))
    }

    /// The sigil is the whole signal, so nothing that is actually a path or a
    /// URL may be swallowed by the diff scheme.
    @Test func nonDiffLocationsAreRejected() {
        #expect(ViewerDiffSpec.parse("/tmp/README.md") == nil)
        #expect(ViewerDiffSpec.parse("https://example.com") == nil)
        #expect(ViewerDiffSpec.parse("about:blank") == nil)
        #expect(ViewerDiffSpec.parse("git-diff-notes.md") == nil)
        #expect(ViewerDiffSpec.parse("docs/git-status.md") == nil)
        #expect(!ViewerDiffSpec.isDiffLocation("~/git/repo"))
    }

    /// The viewer's own classifier has to agree, or a diff location would be
    /// opened as a relative file path.
    @Test func viewerModeClassifiesDiffLocations() {
        #expect(ViewerView.mode(for: "git-status:").diffSpec?.kind == .status)
        #expect(ViewerView.mode(for: "git-diff:main...HEAD").diffSpec?.kind
            == .range("main...HEAD"))
        #expect(ViewerView.mode(for: "/tmp/a.md").diffSpec == nil)
        #expect(ViewerView.mode(for: "https://example.com").diffSpec == nil)
    }

    @Test func onlyTheWorkingTreeNeedsWatching() {
        #expect(ViewerDiffSpec.parse("git-status:")?.tracksWorkingTree == true)
        #expect(ViewerDiffSpec.parse("git-diff:main...HEAD")?.tracksWorkingTree == false)
        #expect(ViewerDiffSpec.parse("git-diff:abc123")?.tracksWorkingTree == false)
    }

    // MARK: - File-list invocations

    @Test func statusListsThreeSectionsInGitStatusOrder() throws {
        let spec = try #require(ViewerDiffSpec.parse("git-status:"))
        let queries = spec.fileListQueries()
        #expect(queries.map(\.origin) == [.staged, .unstaged, .untracked])

        #expect(queries[0].nameStatus == [
            "diff", "--cached", "--name-status",
            "--no-color", "--no-ext-diff", "-M", "-z",
        ])
        #expect(queries[1].numstat == [
            "diff", "--numstat", "--no-color", "--no-ext-diff", "-M", "-z",
        ])
        // Untracked files have no other side to diff against, so they come
        // from ls-files rather than from a diff at all.
        #expect(queries[2].nameStatus == [
            "ls-files", "--others", "--exclude-standard", "-z",
        ])
    }

    @Test func aRangeIsHandedToGitVerbatim() throws {
        let spec = try #require(ViewerDiffSpec.parse("git-diff:main...HEAD"))
        let queries = spec.fileListQueries()
        #expect(queries.count == 1)
        #expect(queries[0].origin == .committed)
        #expect(queries[0].nameStatus == [
            "diff", "main...HEAD", "--name-status",
            "--no-color", "--no-ext-diff", "-M", "-z",
        ])
    }

    /// `git show` suppresses a merge's diff by default, so `-m --first-parent`
    /// is what makes "show me what changed in this merge" show anything.
    @Test func aCommitUsesShowWithFirstParent() throws {
        let spec = try #require(ViewerDiffSpec.parse("git-diff:abc123"))
        let queries = spec.fileListQueries()
        #expect(queries[0].numstat == [
            "show", "--format=", "-m", "--first-parent", "abc123", "--numstat",
            "--no-color", "--no-ext-diff", "-M", "-z",
        ])
    }

    /// An unresolved `.branch` must produce NO invocation: the caller has to
    /// ask git what the default base is first.
    @Test func anUnresolvedBranchSpecRunsNothing() throws {
        let spec = try #require(ViewerDiffSpec.parse("git-diff:"))
        #expect(spec.fileListQueries().isEmpty)
        #expect(spec.patchArguments(for: Self.file("a.txt", origin: .committed)) == nil)
    }

    // MARK: - Patch invocations

    @Test func patchArgumentsFollowTheFileSOrigin() throws {
        let status = try #require(ViewerDiffSpec.parse("git-status:"))
        #expect(status.patchArguments(for: Self.file("a.txt", origin: .staged)) == [
            "diff", "--cached", "--no-color", "--no-ext-diff", "-M",
            "--unified=3", "--", "a.txt",
        ])
        #expect(status.patchArguments(for: Self.file("a.txt", origin: .unstaged)) == [
            "diff", "--no-color", "--no-ext-diff", "-M", "--unified=3", "--", "a.txt",
        ])
        // git cannot diff an untracked file — the patch is synthesized.
        #expect(status.patchArguments(for: Self.file("a.txt", origin: .untracked)) == nil)
    }

    /// Paths go after `--` so a file named like a revision is never read as
    /// one, and a rename passes BOTH names or git reports an unknown path.
    @Test func renamesPassBothPathsAfterTheSeparator() throws {
        let spec = try #require(ViewerDiffSpec.parse("git-diff:main...HEAD"))
        let renamed = ViewerDiffFile(
            path: "new.txt", oldPath: "old.txt", status: .renamed, origin: .committed)
        #expect(spec.patchArguments(for: renamed) == [
            "diff", "main...HEAD", "--no-color", "--no-ext-diff", "-M",
            "--unified=3", "--", "old.txt", "new.txt",
        ])
    }

    @Test func commitPatchesGoThroughShow() throws {
        let spec = try #require(ViewerDiffSpec.parse("git-diff:abc123"))
        #expect(spec.patchArguments(for: Self.file("a.txt", origin: .committed)) == [
            "show", "--format=", "-m", "--first-parent", "abc123",
            "--no-color", "--no-ext-diff", "-M", "--unified=3", "--", "a.txt",
        ])
    }

    // MARK: - Output parsing

    /// `-z` output is not line-oriented, and a rename carries two paths — the
    /// two reasons this cannot be a `split("\n")`.
    @Test func nameStatusParsesRenamesAndPlainEntries() {
        let output = "M\0a.txt\0R096\0old.txt\0new.txt\0D\0gone.txt\0"
        let entries = ViewerGit.parseNameStatus(output)
        #expect(entries.count == 3)
        #expect(entries[0] == .init(status: .modified, path: "a.txt", oldPath: nil))
        #expect(entries[1] == .init(status: .renamed, path: "new.txt", oldPath: "old.txt"))
        #expect(entries[2] == .init(status: .deleted, path: "gone.txt", oldPath: nil))
    }

    /// A path with a space or a quote would be C-quoted without
    /// `core.quotepath=false` + `-z`; it has to arrive intact.
    @Test func awkwardPathsSurviveParsing() {
        let entries = ViewerGit.parseNameStatus("A\0dir with space/a \"b\".txt\0")
        #expect(entries.first?.path == "dir with space/a \"b\".txt")
    }

    @Test func numstatParsesCountsRenamesAndBinaries() {
        // Plain, rename (empty path field then src + dst), and binary (`-`).
        let output = "12\t3\ta.txt\0" + "4\t5\t\0old.bin\0new.txt\0" + "-\t-\timage.png\0"
        let counts = ViewerGit.parseNumstat(output)
        #expect(counts["a.txt"] == .init(additions: 12, deletions: 3, isBinary: false))
        // Keyed by the file's CURRENT path, which is what the file list uses.
        #expect(counts["new.txt"] == .init(additions: 4, deletions: 5, isBinary: false))
        #expect(counts["old.bin"] == nil)
        #expect(counts["image.png"]?.isBinary == true)
    }

    // MARK: - Helpers

    private static func file(
        _ path: String, origin: ViewerDiffFile.Origin
    ) -> ViewerDiffFile {
        ViewerDiffFile(path: path, status: .modified, origin: origin)
    }
}
