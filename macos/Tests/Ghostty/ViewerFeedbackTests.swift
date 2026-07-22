import AppKit
import Testing
@testable import Ghostty

// MARK: - Worktree resolution (pure logic)

@MainActor
struct ViewerWorktreeResolverTests {
    /// A file viewer attributes to the file's own directory.
    @Test func fileViewerUsesFileDirectory() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("doc.md")
        try "# hi".write(to: file, atomically: true, encoding: .utf8)

        let candidate = ViewerWorktreeResolver.candidateDirectory(
            for: file.path,
            originDirectory: "/somewhere/else",
            portLookup: { _ in nil })
        #expect(candidate == dir.path)
    }

    /// A file whose directory does not exist falls back to the origin rather
    /// than misattributing feedback to a phantom directory.
    @Test func missingFileFallsBackToOrigin() {
        let candidate = ViewerWorktreeResolver.candidateDirectory(
            for: "/no/such/place/doc.md",
            originDirectory: "/origin",
            portLookup: { _ in nil })
        #expect(candidate == "/origin")
    }

    /// A loopback dev-server URL resolves via the port lookup.
    @Test func loopbackUsesPortLookup() {
        let candidate = ViewerWorktreeResolver.candidateDirectory(
            for: "http://localhost:3000/app",
            originDirectory: "/origin",
            portLookup: { port in port == 3000 ? "/served/from" : nil })
        #expect(candidate == "/served/from")
    }

    /// A loopback port with NO listener falls back to the origin directory —
    /// this is the "port with no listener" case the task calls out.
    @Test func loopbackWithNoListenerFallsBackToOrigin() {
        let candidate = ViewerWorktreeResolver.candidateDirectory(
            for: "http://localhost:9999",
            originDirectory: "/origin",
            portLookup: { _ in nil })
        #expect(candidate == "/origin")
    }

    /// A remote site never triggers a port lookup and falls back to origin.
    @Test func remoteSiteFallsBackToOrigin() {
        var looked = false
        let candidate = ViewerWorktreeResolver.candidateDirectory(
            for: "https://example.com/page",
            originDirectory: "/origin",
            portLookup: { _ in looked = true; return nil })
        #expect(candidate == "/origin")
        #expect(!looked)
    }

    /// No file directory and no origin: nothing to attribute to.
    @Test func noOriginAndRemoteYieldsNil() {
        let candidate = ViewerWorktreeResolver.candidateDirectory(
            for: "https://example.com",
            originDirectory: nil,
            portLookup: { _ in nil })
        #expect(candidate == nil)
    }

    @Test func loopbackPortParsing() {
        #expect(ViewerWorktreeResolver.loopbackPort(in: "http://localhost:3000") == 3000)
        #expect(ViewerWorktreeResolver.loopbackPort(in: "http://127.0.0.1:8642/x") == 8642)
        #expect(ViewerWorktreeResolver.loopbackPort(in: "http://0.0.0.0:5173") == 5173)
        #expect(ViewerWorktreeResolver.loopbackPort(in: "http://localhost") == 80)
        // A non-loopback host is not a local dev server.
        #expect(ViewerWorktreeResolver.loopbackPort(in: "https://example.com:3000") == nil)
        // A file path is not a URL with a port.
        #expect(ViewerWorktreeResolver.loopbackPort(in: "/Users/me/doc.md") == nil)
    }

    /// The full pipeline against a REAL repo: resolve a file in this checkout
    /// to its git top-level. (This test file lives inside the repo, so the
    /// repo root is a stable fixture.)
    @Test func resolvesRealRepoRoot() throws {
        let dir = try makeTempDir()
        // A temp dir is not in a repo → no worktree.
        #expect(ViewerWorktreeResolver.repositoryRoot(containing: dir.path) == nil)

        // This source file's directory IS in the repo.
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let root = ViewerWorktreeResolver.repositoryRoot(containing: here)
        #expect(root != nil)
        if let root {
            // The resolved root contains this file.
            #expect(here.hasPrefix(root))
        }
    }

    /// No repo found → resolve returns nil → the button does not appear.
    @Test func noRepoYieldsNoWorktree() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("loose.md")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        let worktree = ViewerWorktreeResolver.resolve(
            location: file.path, originDirectory: nil)
        #expect(worktree == nil)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Report writing (pure logic)

@MainActor
struct ViewerFeedbackReportTests {
    private func makeWorktree() throws -> (ViewerWorktree, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ViewerWorktree(path: dir.path), dir)
    }

    private func pngFixture() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return ViewerFeedbackTextView.pngData(from: image)!
    }

    private func decode(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// A text-plus-image report lands in `temp/feedback/new/`, atomically, with
    /// the image written alongside and referenced by a resolvable path.
    @Test func writesReportWithImage() throws {
        let (worktree, dir) = try makeWorktree()
        let png = pngFixture()
        let segments: [ViewerFeedbackReport.Segment] = [
            .text("See here: "),
            .image(number: 1),
            .text("\nthat is wrong."),
        ]
        let written = try ViewerFeedbackReport.write(
            segments: segments,
            images: [ViewerFeedbackReport.Image(number: 1, png: png)],
            worktree: worktree,
            context: ViewerFeedbackReport.Context(
                source: "http://localhost:3000/app", sourceKind: "web"),
            date: Date(timeIntervalSince1970: 1_770_000_000),
            suffix: "abc123")

        // Report lives in its OWN folder under temp/feedback/new/.
        let queue = dir.appendingPathComponent("temp/feedback/new")
        #expect(written.folderURL.deletingLastPathComponent().path == queue.path)
        #expect(written.folderURL.lastPathComponent == written.stem)
        #expect(written.reportURL.lastPathComponent == "report.json")
        #expect(FileManager.default.fileExists(atPath: written.reportURL.path))

        // Image written inside the same folder and actually on disk.
        #expect(written.imageURLs.count == 1)
        #expect(FileManager.default.fileExists(atPath: written.imageURLs[0].path))

        // Machine-readable, with the context a downstream agent needs.
        let json = try decode(written.reportURL)
        #expect(json["version"] as? Int == ViewerFeedbackReport.schemaVersion)
        #expect(json["created"] != nil)
        let source = try #require(json["source"] as? [String: Any])
        #expect(source["location"] as? String == "http://localhost:3000/app")
        #expect(source["kind"] as? String == "web")
        let wt = try #require(json["worktree"] as? [String: Any])
        #expect(wt["path"] as? String == worktree.path)
        #expect(wt["name"] as? String == worktree.name)

        // The body renders the chip as a path resolvable inside the folder.
        let body = try #require(json["body"] as? String)
        let ref = "images/image-1.png"
        #expect(body.contains(ref))
        #expect(FileManager.default.fileExists(
            atPath: written.folderURL.appendingPathComponent(ref).path))

        // Nothing half-written left behind: staging is gone, queue holds only
        // the finished folder.
        let staging = dir.appendingPathComponent("temp/feedback/.staging")
        let stagingLeft = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(stagingLeft.isEmpty)
        let queued = try FileManager.default.contentsOfDirectory(atPath: queue.path)
        #expect(queued == [written.stem])
    }

    /// A send with ZERO images still produces a valid report (text only), no
    /// image directory.
    @Test func writesTextOnlyReport() throws {
        let (worktree, dir) = try makeWorktree()
        let written = try ViewerFeedbackReport.write(
            segments: [.text("just words")],
            images: [],
            worktree: worktree,
            context: ViewerFeedbackReport.Context(
                source: "/some/file.md", sourceKind: "file"),
            date: Date(timeIntervalSince1970: 1_770_000_000),
            suffix: "def456")
        #expect(written.imageURLs.isEmpty)
        let json = try decode(written.reportURL)
        #expect(json["body"] as? String == "just words")
        #expect((json["images"] as? [Any])?.isEmpty == true)
        // No images subdirectory was created.
        let imageDir = written.folderURL.appendingPathComponent("images")
        #expect(!FileManager.default.fileExists(atPath: imageDir.path))
        _ = dir
    }

    /// A completely empty submission is rejected.
    @Test func emptySubmissionThrows() throws {
        let (worktree, _) = try makeWorktree()
        #expect(throws: ViewerFeedbackReport.WriteError.empty) {
            try ViewerFeedbackReport.write(
                segments: [.text("   \n ")],
                images: [],
                worktree: worktree,
                context: ViewerFeedbackReport.Context(source: "x", sourceKind: "file"))
        }
    }

    /// A chip whose image was removed (dangling reference) is rejected rather
    /// than written with a broken link.
    @Test func danglingChipReferenceThrows() throws {
        let (worktree, _) = try makeWorktree()
        #expect(throws: ViewerFeedbackReport.WriteError.danglingImageReference(number: 2)) {
            try ViewerFeedbackReport.write(
                segments: [.text("a "), .image(number: 2)],
                images: [], // #2 has no matching image
                worktree: worktree,
                context: ViewerFeedbackReport.Context(source: "x", sourceKind: "file"))
        }
    }

    /// Stems sort chronologically as plain strings, so a watcher drains
    /// oldest-first with a directory sort.
    @Test func stemsSortChronologically() {
        let early = ViewerFeedbackReport.makeStem(
            date: Date(timeIntervalSince1970: 1_000), suffix: "zzzzzz")
        let late = ViewerFeedbackReport.makeStem(
            date: Date(timeIntervalSince1970: 2_000), suffix: "000000")
        #expect(early < late)
    }

    // MARK: - Draft staging lifecycle

    /// The staging paths are worktree-relative and stable, so the composer can
    /// display and reveal them.
    @Test func stagingPathsAreWorktreeRelative() throws {
        let (worktree, _) = try makeWorktree()
        #expect(ViewerFeedbackReport.stagingRelativePath == "temp/feedback/.staging")
        let stem = "20260721T000000Z-abc123"
        let url = ViewerFeedbackReport.stagingDirectory(in: worktree, stem: stem)
        #expect(url.path == worktree.url
            .appendingPathComponent("temp/feedback/.staging/\(stem)").path)
    }

    /// `stage` materializes the draft folder in place — a `report.json` plus
    /// the draft's images — WITHOUT publishing it into `new/` yet. This is what
    /// makes the folder openable while the user is still composing.
    @Test func stageMaterializesDraftFolderWithoutPublishing() throws {
        let (worktree, dir) = try makeWorktree()
        let png = pngFixture()
        let stem = "20260721T000000Z-draft1"
        let staging = try ViewerFeedbackReport.stage(
            segments: [.text("wip "), .image(number: 1)],
            images: [ViewerFeedbackReport.Image(number: 1, png: png)],
            worktree: worktree,
            context: ViewerFeedbackReport.Context(source: "/f.md", sourceKind: "file"),
            stem: stem)

        // Compare paths, not URLs: `appendingPathComponent` adds a trailing
        // slash once the directory exists, so the two URLs differ cosmetically.
        #expect(staging.path
            == ViewerFeedbackReport.stagingDirectory(in: worktree, stem: stem).path)
        #expect(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("report.json").path))
        #expect(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("images/image-1.png").path))

        // Nothing published yet: the queue is empty (or absent).
        let queue = dir.appendingPathComponent("temp/feedback/new")
        let queued = (try? FileManager.default.contentsOfDirectory(atPath: queue.path)) ?? []
        #expect(queued.isEmpty)
    }

    /// A work-in-progress folder legitimately has nothing typed in it yet, so
    /// `stage` tolerates an empty draft (unlike `write`, which rejects it).
    @Test func stageToleratesEmptyDraft() throws {
        let (worktree, _) = try makeWorktree()
        let stem = "20260721T000000Z-empty1"
        let staging = try ViewerFeedbackReport.stage(
            segments: [], images: [],
            worktree: worktree,
            context: ViewerFeedbackReport.Context(source: "x", sourceKind: "file"),
            stem: stem)
        #expect(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("report.json").path))
        // No images subdirectory for an image-less draft.
        #expect(!FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("images").path))
    }

    /// The heart of the feature: a file the user dropped into the draft's
    /// staging folder while composing rides along into the published report
    /// (the send reuses the draft's stem instead of minting a fresh folder).
    @Test func sendPublishesFilesDroppedIntoStaging() throws {
        let (worktree, dir) = try makeWorktree()
        let stem = "20260721T120000Z-draft2"

        // Compose: the composer materializes the draft's staging folder.
        try ViewerFeedbackReport.stage(
            segments: [.text("look at this")], images: [],
            worktree: worktree,
            context: ViewerFeedbackReport.Context(source: "/f.md", sourceKind: "file"),
            stem: stem)

        // The user opens the folder and drops an extra file into it.
        let staging = ViewerFeedbackReport.stagingDirectory(in: worktree, stem: stem)
        let dropped = staging.appendingPathComponent("extra-notes.txt")
        try "hand-added".write(to: dropped, atomically: true, encoding: .utf8)

        // Send reuses THIS draft's stem.
        let written = try ViewerFeedbackReport.write(
            segments: [.text("look at this")], images: [],
            worktree: worktree,
            context: ViewerFeedbackReport.Context(source: "/f.md", sourceKind: "file"),
            stem: stem)

        #expect(written.stem == stem)
        // The dropped file was consumed into the published folder, intact.
        let publishedExtra = written.folderURL.appendingPathComponent("extra-notes.txt")
        #expect(FileManager.default.fileExists(atPath: publishedExtra.path))
        #expect(try String(contentsOf: publishedExtra, encoding: .utf8) == "hand-added")
        #expect(FileManager.default.fileExists(atPath: written.reportURL.path))

        // Staging is empty afterward (the whole draft folder moved atomically).
        let stagingRoot = dir.appendingPathComponent("temp/feedback/.staging")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        #expect(left.isEmpty)
    }

    /// Re-staging a draft (as happens each time the folder is revealed or on
    /// send) refreshes report.json + images but never wipes a dropped file.
    @Test func restagePreservesDroppedFiles() throws {
        let (worktree, _) = try makeWorktree()
        let stem = "20260721T130000Z-draft3"
        try ViewerFeedbackReport.stage(
            segments: [.text("first")], images: [], worktree: worktree,
            context: ViewerFeedbackReport.Context(source: "x", sourceKind: "file"),
            stem: stem)
        let staging = ViewerFeedbackReport.stagingDirectory(in: worktree, stem: stem)
        try "keep me".write(
            to: staging.appendingPathComponent("dropped.bin"),
            atomically: true, encoding: .utf8)

        // Refresh with new content.
        try ViewerFeedbackReport.stage(
            segments: [.text("second, edited")], images: [], worktree: worktree,
            context: ViewerFeedbackReport.Context(source: "x", sourceKind: "file"),
            stem: stem)

        #expect(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("dropped.bin").path))
        let body = try #require(
            (try decode(staging.appendingPathComponent("report.json")))["body"] as? String)
        #expect(body == "second, edited")
    }

    /// Abandoned drafts are pruned by age, but a draft being composed now — the
    /// `keeping` stem — and recent ones (another pane's live draft) are left be.
    @Test func pruneRemovesStaleButKeepsCurrentAndRecent() throws {
        let (worktree, _) = try makeWorktree()
        let now = Date(timeIntervalSince1970: 2_000_000)

        func makeStaging(_ stem: String, ageSeconds: TimeInterval) throws {
            let url = ViewerFeedbackReport.stagingDirectory(in: worktree, stem: stem)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-ageSeconds)],
                ofItemAtPath: url.path)
        }

        // "current" is old but protected by `keeping`; "recent" is protected by
        // age; "stale" is neither.
        try makeStaging("current", ageSeconds: 48 * 60 * 60)
        try makeStaging("recent", ageSeconds: 60)
        try makeStaging("stale", ageSeconds: 48 * 60 * 60)

        let removed = ViewerFeedbackReport.pruneStaleStaging(
            in: worktree, keeping: "current", olderThan: 24 * 60 * 60, now: now)

        #expect(removed == ["stale"])
        let root = worktree.url.appendingPathComponent("temp/feedback/.staging")
        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        #expect(left == ["current", "recent"])
    }
}
