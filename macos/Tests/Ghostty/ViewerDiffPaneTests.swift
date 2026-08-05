import AppKit
import Foundation
import Testing
import WebKit
@testable import Ghostty

/// A throwaway git repository for the suite below.
///
/// Declared at FILE SCOPE on purpose. Nested inside the `@MainActor` suite it
/// would inherit that isolation, and its `deinit` then runs actor-isolated code
/// from whatever thread happens to release it — which aborts the whole test
/// RUNNER, taking every other test sharing that process down as collateral.
private final class Repo {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-diff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        git("init", "--initial-branch=main")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        git("config", "commit.gpgsign", "false")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func git(_ arguments: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        try? process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func write(_ relative: String, _ contents: String) {
        let file = url.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// A diff pane driven end to end against a REAL git repository.
///
/// The spec→git mapping is unit-tested next door; what these cover is
/// everything that only shows up once git, the native panel, and the rendered
/// page are wired together: that the file list arrives, that the card follows
/// the pane's width the way the table of contents does, that the filter
/// narrows the list, and that next/previous-change walks hunks and then rolls
/// over into the next file.
///
/// Serialized: every test here stands up a real WKWebView and shells out to git
/// several times. Run in parallel they starve each other — a page load that
/// takes 200ms alone outlasts the whole timeout with a dozen in flight — and
/// the suite then fails for reasons that have nothing to do with the code.
@MainActor
@Suite(.serialized)
struct ViewerDiffPaneTests {
    // MARK: - Fixtures

    /// `src/app.swift` and `docs/readme.md` committed; then app.swift edited
    /// in three separate places (so there are several hunks to walk),
    /// docs/readme.md edited and staged, and `notes.txt` left untracked.
    private func makeRepo() throws -> Repo {
        let repo = try Repo()
        let original = (1...40).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n"
        repo.write("src/app.swift", original)
        repo.write("docs/readme.md", "# Docs\n\nOriginal.\n")
        repo.git("add", ".")
        repo.git("commit", "-m", "initial")

        var lines = original.components(separatedBy: "\n")
        lines[2] = "let line3 = 300"
        lines[20] = "let line21 = 2100"
        lines[38] = "let line39 = 3900"
        repo.write("src/app.swift", lines.joined(separator: "\n"))

        repo.write("docs/readme.md", "# Docs\n\nStaged edit.\n")
        repo.git("add", "docs/readme.md")

        repo.write("notes.txt", "scratch\n")
        return repo
    }

    private func makeViewer(
        location: String, repo: Repo, width: CGFloat = 900
    ) -> (NSWindow, ViewerView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true)
        let viewer = ViewerView(location: location, originDirectory: repo.url.path)
        viewer.frame = window.contentView!.bounds
        viewer.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        return (window, viewer)
    }

    /// Awaiting a sleep yields the main actor, which lets the runloop turn and
    /// WebKit deliver its callbacks — see the note in ViewerTOCTests.
    private func wait(
        upTo seconds: TimeInterval = 15,
        for condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    /// The same, for a condition that has to cross into the page.
    private func waitAsync(
        upTo seconds: TimeInterval = 15,
        for condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    /// Let the runloop turn so a smooth scroll (or a pending render) settles.
    private func settle(_ seconds: TimeInterval = 0.6) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func evaluate(_ script: String, in viewer: ViewerView) async -> String? {
        await withCheckedContinuation { continuation in
            viewer.webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    private func scrollY(in viewer: ViewerView) async -> Double {
        Double(await evaluate("String(Math.round(window.scrollY))", in: viewer) ?? "") ?? -1
    }

    // MARK: - Listing

    /// A `git-status:` pane finds every kind of working-tree change and keeps
    /// staged, unstaged, and untracked apart.
    @Test func workingTreeListsAllThreeSections() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.diffFiles.count >= 3 }, "no files arrived from git")

        let byOrigin = Dictionary(grouping: viewer.diffFiles, by: \.origin)
        #expect(byOrigin[.staged]?.map(\.path) == ["docs/readme.md"])
        #expect(byOrigin[.unstaged]?.map(\.path) == ["src/app.swift"])
        #expect(byOrigin[.untracked]?.map(\.path) == ["notes.txt"])
        // Counts come from --numstat, not from us.
        #expect(byOrigin[.unstaged]?.first?.additions == 3)
        #expect(byOrigin[.unstaged]?.first?.deletions == 3)
        // A pane opens on something rather than on nothing.
        #expect(viewer.activeDiffFileID != nil)
    }

    /// A range diff resolves against the pane's origin directory and lists the
    /// commit's files.
    @Test func aRangeDiffListsCommittedFiles() async throws {
        let repo = try makeRepo()
        repo.git("add", ".")
        repo.git("commit", "-m", "second")
        repo.git("checkout", "-b", "feature")
        repo.write("src/app.swift", "let only = 1\n")
        repo.git("commit", "-am", "feature change")

        let (window, viewer) = makeViewer(location: "git-diff:main...HEAD", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { !viewer.diffFiles.isEmpty })
        #expect(viewer.diffFiles.map(\.path) == ["src/app.swift"])
        #expect(viewer.diffFiles.allSatisfy { $0.origin == .committed })
    }

    /// A bare `git-diff:` finds the default branch itself.
    @Test func bareDiffResolvesTheDefaultBase() async throws {
        let repo = try makeRepo()
        repo.git("add", ".")
        repo.git("commit", "-m", "second")
        repo.git("checkout", "-b", "feature")
        repo.write("newfile.txt", "hello\n")
        repo.git("add", ".")
        repo.git("commit", "-m", "on feature")

        let (window, viewer) = makeViewer(location: "git-diff:", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { !viewer.diffFiles.isEmpty }, "bare git-diff: found nothing")
        #expect(viewer.diffFiles.map(\.path) == ["newfile.txt"])
    }

    /// A pane pointed at a directory that is not a repo says so, rather than
    /// sitting blank.
    @Test func aNonRepositoryReportsItself() {
        let result = ViewerDiffLoader.listingSync(
            spec: ViewerDiffSpec(kind: .status, location: "git-status:"),
            directory: NSTemporaryDirectory())
        guard case .failure(let error) = result else {
            Issue.record("expected a failure outside a repo")
            return
        }
        if case .notARepository = error {} else {
            Issue.record("expected .notARepository, got \(error)")
        }
    }

    /// The address bar shows the diff spec and ACCEPTS one: editing
    /// `git-diff:HEAD~1` to `git-diff:HEAD~2` retargets the pane. This is the
    /// whole reason a diff's location is a typeable scheme rather than an
    /// opaque handle.
    @Test func theAddressBarShowsAndAcceptsTheDiffSpec() async throws {
        let repo = try makeRepo()
        repo.git("add", ".")
        repo.git("commit", "-m", "second")
        repo.write("only-in-third.txt", "third\n")
        repo.git("add", ".")
        repo.git("commit", "-m", "third")

        let (window, viewer) = makeViewer(location: "git-diff:HEAD", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        // The field shows the query, not an internal template URL.
        #expect(viewer.currentURL == "git-diff:HEAD")
        #expect(await wait { viewer.diffFiles.map(\.path) == ["only-in-third.txt"] })

        // Retarget it the way the user would: edit the text and submit.
        viewer.navigate(to: "git-diff:HEAD~1")
        #expect(viewer.currentURL == "git-diff:HEAD~1")
        #expect(viewer.title == "HEAD~1")
        #expect(
            await wait { viewer.diffFiles.contains { $0.path == "notes.txt" } },
            "editing the address did not re-run the diff (got \(viewer.diffFiles.map(\.path)))")
        #expect(!viewer.diffFiles.contains { $0.path == "only-in-third.txt" })

        // A range typed in from scratch works the same way.
        viewer.navigate(to: "git-diff:HEAD~2..HEAD")
        #expect(await wait { viewer.diffFiles.contains { $0.path == "only-in-third.txt" } })

        // ...and Home returns to the spec the pane was opened with.
        viewer.goHome()
        #expect(viewer.currentURL == "git-diff:HEAD")
        #expect(await wait { viewer.diffFiles.map(\.path) == ["only-in-third.txt"] })
    }

    /// A revspec that does not exist reports itself rather than showing a
    /// stale diff or a blank pane.
    @Test func anInvalidRevspecTypedIntoTheAddressBarReportsItself() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.diffFiles.count >= 3 })
        viewer.navigate(to: "git-diff:no-such-ref..also-missing")
        #expect(await wait { viewer.diffFiles.isEmpty },
                "a bad revspec left the previous diff on screen")
        #expect(await waitAsync { await pageHas(".d-notice", in: viewer) },
                "no explanation was rendered")
    }

    // MARK: - The side panel

    /// The file tree is the SAME card as the table of contents, so it obeys
    /// the same rule: a wide pane gives it a gutter reserved as padding on the
    /// page, a narrow one takes the gutter away and makes it an overlay.
    @Test func theFileTreeFollowsThePaneWidthLikeTheTOC() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.sidePanelGutterWidth > 0 }, "gutter never reserved")
        viewer.setSidePanelWidth(240)
        #expect(viewer.sidePanelLayout == .gutter)
        #expect(viewer.sidePanelGutterWidth == GlassCard.outerMargin + 240)
        // The web view still spans the pane; only the page is padded.
        #expect(viewer.webView.frame.minX == 0)

        viewer.frame = NSRect(x: 0, y: 0, width: 500, height: 700)
        viewer.layoutSubtreeIfNeeded()
        #expect(viewer.sidePanelLayout == .compact, "narrow pane must overlay the card")
        #expect(viewer.sidePanelGutterWidth == 0)

        viewer.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        viewer.layoutSubtreeIfNeeded()
        #expect(viewer.sidePanelLayout == .gutter)
        #expect(viewer.sidePanelGutterWidth == GlassCard.outerMargin + viewer.sidePanelWidth)
    }

    /// The filter narrows the list and Return opens the top hit — the "type a
    /// few letters and go" path.
    @Test func theFilterNarrowsTheListAndReturnOpensTheTopHit() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.diffFiles.count >= 3 })

        viewer.setDiffFilter("readme")
        #expect(viewer.isDiffFiltered)
        #expect(ViewerDiffTree.visibleFiles(in: viewer.diffRows).map(\.path)
            == ["docs/readme.md"])
        // Filtering flattens: no folder rows to wade through.
        #expect(!viewer.diffRows.contains {
            if case .folder = $0.kind { return true }
            return false
        })

        viewer.openFirstFilteredFile()
        #expect(viewer.activeDiffFile?.path == "docs/readme.md")

        viewer.setDiffFilter("")
        #expect(!viewer.isDiffFiltered)
        #expect(ViewerDiffTree.visibleFiles(in: viewer.diffRows).count == viewer.diffFiles.count)
    }

    /// A filter that matches nothing empties the panel rather than quietly
    /// showing everything.
    @Test func aFilterWithNoMatchesShowsNothing() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.diffFiles.count >= 3 })
        viewer.setDiffFilter("zzzzz-no-such-file")
        #expect(viewer.diffRows.isEmpty)
    }

    // MARK: - Change navigation

    /// Next-change walks the hunks of the open file...
    @Test func nextChangeWalksHunksWithinAFile() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.diffFiles.count >= 3 })
        let app = try #require(viewer.diffFiles.first { $0.path == "src/app.swift" })
        viewer.selectDiffFile(app)
        // Three separate edits, three hunks — enough to walk.
        #expect(await waitAsync { await pageChangeCount(in: viewer) >= 3 },
                "the page rendered no changes to navigate")

        // Asserted on the change the pane moved TO rather than on
        // `window.scrollY`: this window is never ordered on screen, and an
        // offscreen WKWebView does not reliably run the smooth scroll (the
        // same caveat ViewerTOCTests documents). The index is the decision —
        // "which change is next" — and the scroll is one `window.scrollTo`
        // away from it.
        #expect(await pageChangeIndex(in: viewer) == -1, "nothing navigated to yet")

        viewer.goToNextChange()
        #expect(await waitAsync(upTo: 4) { await pageChangeIndex(in: viewer) == 0 },
                "next change did not move to the first change")

        viewer.goToNextChange()
        #expect(await waitAsync(upTo: 4) { await pageChangeIndex(in: viewer) == 1 },
                "second next change did not advance")

        // ...and previous walks back.
        viewer.goToPreviousChange()
        #expect(await waitAsync(upTo: 4) { await pageChangeIndex(in: viewer) == 0 },
                "previous change did not go back")

        // The file did not change underneath any of that.
        #expect(viewer.activeDiffFile?.path == "src/app.swift")
    }

    /// ...and then rolls over into the next FILE, which is what "next change"
    /// means across a diff of several files.
    @Test func nextChangeRollsOverIntoTheAdjacentFile() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.diffFiles.count >= 3 })
        let visible = ViewerDiffTree.visibleFiles(in: viewer.diffRows)
        #expect(visible.count >= 2)

        // Start on the first file and walk forward until the pane moves on.
        viewer.selectDiffFile(visible[0])
        #expect(await wait { viewer.activeDiffFileID == visible[0].id })
        #expect(await waitAsync(upTo: 8) { await pageChangeCount(in: viewer) >= 1 })

        var moved = false
        for _ in 0..<12 {
            viewer.goToNextChange()
            _ = await wait(upTo: 1) { viewer.activeDiffFileID == visible[1].id }
            if viewer.activeDiffFileID == visible[1].id { moved = true; break }
        }
        #expect(moved, "next change never rolled over to \(visible[1].path)")

        // And back the other way.
        var returned = false
        for _ in 0..<12 {
            viewer.goToPreviousChange()
            _ = await wait(upTo: 1) { viewer.activeDiffFileID == visible[0].id }
            if viewer.activeDiffFileID == visible[0].id { returned = true; break }
        }
        #expect(returned, "previous change never rolled back to \(visible[0].path)")
    }

    /// The unified⇄side-by-side toggle changes the rendered layout and sticks
    /// as a preference across panes.
    @Test func theLayoutToggleSwitchesTheRenderedDiff() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo)
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            UserDefaults.standard.removeObject(forKey: "ViewerDiffViewStyle")
        }

        #expect(await wait { viewer.diffFiles.count >= 3 })
        viewer.setDiffViewStyle(.unified)
        let app = try #require(viewer.diffFiles.first { $0.path == "src/app.swift" })
        viewer.selectDiffFile(app)
        #expect(await waitAsync { await pageHas(".d-unified", in: viewer) })
        #expect(!(await pageHas(".d-split", in: viewer)))

        viewer.toggleDiffViewStyle()
        #expect(viewer.diffViewStyle == .split)
        #expect(await waitAsync { await pageHas(".d-split", in: viewer) },
                "the page did not switch to side-by-side")
        // Side-by-side pairs a removal with its replacement on one grid row.
        #expect(await waitAsync { await pageHas(".d-pair.d-changed", in: viewer) })
        // It is a preference, not a property of this one pane.
        #expect(UserDefaults.standard.string(forKey: "ViewerDiffViewStyle") == "split")
    }

    /// A working-tree pane picks up an edit made behind its back — a status
    /// diff that goes stale the moment you save is worse than no diff.
    @Test func theWorkingTreeDiffRefreshesItself() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.diffFiles.count >= 3 })
        #expect(!viewer.diffFiles.contains { $0.path == "fresh.txt" })

        repo.write("fresh.txt", "new\n")
        #expect(
            await wait(upTo: 12) { viewer.diffFiles.contains { $0.path == "fresh.txt" } },
            "the pane never noticed a new untracked file")
    }

    /// `+reload` / Cmd-R re-runs the diff in place.
    @Test func reloadRerunsTheDiff() async throws {
        let repo = try makeRepo()
        let (window, viewer) = makeViewer(location: "git-status:", repo: repo)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.diffFiles.count >= 3 })
        repo.git("add", ".")
        viewer.reloadContent()
        #expect(
            await wait { viewer.diffFiles.allSatisfy { $0.origin == .staged } },
            "reload did not pick up the staging")
    }

    // MARK: - Page helpers

    private func pageChangeCount(in viewer: ViewerView) async -> Int {
        Int(await evaluate(
            "String(window.__viewer.diff._changeCount())", in: viewer) ?? "") ?? 0
    }

    /// Which change the toolbar last navigated to, or -1 when the reader is
    /// driving with their own scrolling.
    private func pageChangeIndex(in viewer: ViewerView) async -> Int {
        Int(await evaluate(
            "String(window.__viewer.diff._changeIndex())", in: viewer) ?? "") ?? -99
    }

    private func pageHas(_ selector: String, in viewer: ViewerView) async -> Bool {
        await evaluate(
            "String(!!document.querySelector(\(jsString(selector))))", in: viewer) == "true"
    }

    private func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: .fragmentsAllowed)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
