import Testing
@testable import Ghostty

/// The diff panel's file tree: how git's flat list of paths becomes rows, and
/// what the filter does to them.
///
/// A pure transform, so it is tested without a window — which is the point of
/// keeping it out of the view.
struct ViewerDiffTreeTests {
    private func file(
        _ path: String,
        origin: ViewerDiffFile.Origin = .committed,
        status: ViewerDiffFile.Status = .modified,
        oldPath: String? = nil
    ) -> ViewerDiffFile {
        ViewerDiffFile(
            path: path, oldPath: oldPath, status: status, origin: origin,
            additions: 1, deletions: 1)
    }

    /// A chain of single-child directories is ONE row. Four rows of
    /// indentation carrying no information is exactly what a file tree in a
    /// 240pt card cannot afford.
    @Test func singleChildDirectoryChainsCollapse() {
        let rows = ViewerDiffTree.rows(for: [
            file("macos/Sources/Features/Viewer/ViewerView.swift"),
            file("macos/Sources/Features/Viewer/ViewerTOC.swift"),
        ])
        let folders = rows.compactMap { row -> String? in
            if case .folder(let title, _) = row.kind { return title }
            return nil
        }
        #expect(folders == ["macos/Sources/Features/Viewer"])
        #expect(ViewerDiffTree.visibleFiles(in: rows).map(\.name)
            == ["ViewerTOC.swift", "ViewerView.swift"])
    }

    /// A directory that branches keeps its levels — that is real structure.
    @Test func branchingDirectoriesKeepTheirLevels() {
        let rows = ViewerDiffTree.rows(for: [
            file("src/cli/split.zig"),
            file("src/viewer/diff.js"),
        ])
        let folders = rows.compactMap { row -> (String, Int)? in
            if case .folder(let title, _) = row.kind { return (title, row.depth) }
            return nil
        }
        #expect(folders.map(\.0) == ["src", "cli", "viewer"])
        #expect(folders.map(\.1) == [0, 1, 1])
    }

    /// Folders come before files, and both read the way Finder sorts.
    @Test func foldersSortBeforeFiles() {
        let rows = ViewerDiffTree.rows(for: [
            file("README.md"),
            file("zzz/a.txt"),
            file("CHANGELOG.md"),
        ])
        let kinds = rows.map { row -> String in
            switch row.kind {
            case .folder(let title, _): return "d:" + title
            case .file(let file): return "f:" + file.name
            case .section(let title): return "s:" + title
            }
        }
        #expect(kinds == ["d:zzz", "f:a.txt", "f:CHANGELOG.md", "f:README.md"])
    }

    /// A working-tree diff is three lists, not one: which changes are staged
    /// is the thing `git status` exists to tell you.
    @Test func workingTreeSectionsAreKeptApartAndOrdered() {
        let rows = ViewerDiffTree.rows(for: [
            file("c.txt", origin: .untracked, status: .added),
            file("a.txt", origin: .unstaged),
            file("b.txt", origin: .staged),
        ])
        let sections = rows.compactMap { row -> String? in
            if case .section(let title) = row.kind { return title }
            return nil
        }
        #expect(sections == ["Staged · 1", "Changes · 1", "Untracked · 1"])
        // Section rows indent their contents by one step.
        #expect(rows.compactMap(\.file).map(\.name) == ["b.txt", "a.txt", "c.txt"])
        #expect(rows.first { $0.file != nil }?.depth == 1)
    }

    /// A committed diff has one list, so a heading over it would be noise.
    @Test func aCommittedDiffHasNoSectionHeader() {
        let rows = ViewerDiffTree.rows(for: [file("a.txt")])
        #expect(!rows.contains { if case .section = $0.kind { return true }; return false })
        #expect(rows.first?.depth == 0)
    }

    /// The same path staged AND modified is two entries — they are different
    /// diffs, and VS Code's SCM view shows them the same way.
    @Test func oneFileCanAppearInTwoSections() {
        let rows = ViewerDiffTree.rows(for: [
            file("a.txt", origin: .staged),
            file("a.txt", origin: .unstaged),
        ])
        let files = ViewerDiffTree.visibleFiles(in: rows)
        #expect(files.count == 2)
        // ...and their ids differ, so selecting one does not light up the other.
        #expect(Set(files.map(\.id)).count == 2)
    }

    // MARK: - Filter

    /// Filtering flattens the tree: when you are hunting one file in a
    /// thousand, the folders between you and it are in the way.
    @Test func filteringProducesAFlatHitList() {
        let rows = ViewerDiffTree.rows(
            for: [
                file("macos/Sources/Features/Viewer/ViewerView.swift"),
                file("macos/Sources/Features/Viewer/ViewerTOC.swift"),
                file("src/cli/split.zig"),
            ],
            filter: "viewer")
        #expect(!rows.contains { if case .folder = $0.kind { return true }; return false })
        #expect(ViewerDiffTree.visibleFiles(in: rows).map(\.name)
            == ["ViewerTOC.swift", "ViewerView.swift"])
    }

    /// Terms are ANDed and matched against the whole path, which is what makes
    /// `viewer zig` a useful query rather than a literal one.
    @Test func filterTermsAreAndedAcrossThePath() {
        let files = [
            file("src/cli/split.zig"),
            file("src/viewer/diff.js"),
            file("macos/Sources/Features/Viewer/ViewerView.swift"),
        ]
        #expect(ViewerDiffTree.visibleFiles(
            in: ViewerDiffTree.rows(for: files, filter: "src js")).map(\.name)
            == ["diff.js"])
        // Case-insensitive.
        #expect(ViewerDiffTree.visibleFiles(
            in: ViewerDiffTree.rows(for: files, filter: "VIEWERVIEW")).count == 1)
        // A term nothing matches yields nothing, not everything.
        #expect(ViewerDiffTree.rows(for: files, filter: "nope").isEmpty)
        // Blank/whitespace-only filters are no filter at all.
        #expect(ViewerDiffTree.visibleFiles(
            in: ViewerDiffTree.rows(for: files, filter: "   ")).count == 3)
    }

    /// A rename is findable by either of its names.
    @Test func filterMatchesARenameSOldPath() {
        let files = [file("new/name.txt", status: .renamed, oldPath: "legacy/thing.txt")]
        #expect(ViewerDiffTree.visibleFiles(
            in: ViewerDiffTree.rows(for: files, filter: "legacy")).count == 1)
    }

    // MARK: - Collapsing

    @Test func collapsingAFolderHidesItsContentsButNotItself() {
        let files = [
            file("src/cli/split.zig"),
            file("src/viewer/diff.js"),
        ]
        let key = ViewerDiffTree.rows(for: files)
            .compactMap(\.folderKey)
            .first { $0.hasSuffix(":src/cli") }
        let collapsed = ViewerDiffTree.rows(
            for: files, collapsed: Set([key].compactMap { $0 }))

        #expect(collapsed.compactMap(\.folderKey).contains { $0.hasSuffix(":src/cli") })
        #expect(ViewerDiffTree.visibleFiles(in: collapsed).map(\.name) == ["diff.js"])
    }

    /// Navigation steps through exactly what the user can see, so a collapsed
    /// folder's files are not silently walked into.
    @Test func navigationFollowsTheVisibleRows() {
        let files = [file("a/one.txt"), file("b/two.txt")]
        let key = ViewerDiffTree.rows(for: files)
            .compactMap(\.folderKey)
            .first { $0.hasSuffix(":a") }
        let rows = ViewerDiffTree.rows(for: files, collapsed: Set([key].compactMap { $0 }))
        #expect(ViewerDiffTree.visibleFiles(in: rows).map(\.name) == ["two.txt"])
    }
}
