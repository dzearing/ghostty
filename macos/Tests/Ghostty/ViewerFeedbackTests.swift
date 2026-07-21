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

    /// A text-plus-image report lands in `.feedback/new/`, atomically, with
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
            source: "http://localhost:3000/app",
            date: Date(timeIntervalSince1970: 1_770_000_000),
            suffix: "abc123")

        // Report lives in .feedback/new/.
        let queue = dir.appendingPathComponent(".feedback/new")
        #expect(written.reportURL.deletingLastPathComponent().path == queue.path)
        #expect(FileManager.default.fileExists(atPath: written.reportURL.path))

        // Image written alongside and actually on disk.
        #expect(written.imageURLs.count == 1)
        #expect(FileManager.default.fileExists(atPath: written.imageURLs[0].path))

        // Machine-readable, with the metadata the watcher needs.
        let json = try decode(written.reportURL)
        #expect(json["source"] as? String == "http://localhost:3000/app")
        #expect(json["worktree"] as? String == worktree.path)
        #expect(json["version"] as? Int == ViewerFeedbackReport.schemaVersion)
        #expect(json["created"] != nil)

        // The body renders the chip as a path reference resolvable relative to
        // the report's own directory.
        let body = try #require(json["body"] as? String)
        let ref = "\(written.stem)/image-1.png"
        #expect(body.contains(ref))
        let resolved = written.reportURL.deletingLastPathComponent()
            .appendingPathComponent(ref)
        #expect(FileManager.default.fileExists(atPath: resolved.path))

        // No stray temp file left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: queue.path)
        #expect(!leftovers.contains { $0.hasSuffix(".tmp") })
    }

    /// A send with ZERO images still produces a valid report (text only), no
    /// image directory.
    @Test func writesTextOnlyReport() throws {
        let (worktree, dir) = try makeWorktree()
        let written = try ViewerFeedbackReport.write(
            segments: [.text("just words")],
            images: [],
            worktree: worktree,
            source: "/some/file.md",
            date: Date(timeIntervalSince1970: 1_770_000_000),
            suffix: "def456")
        #expect(written.imageURLs.isEmpty)
        let json = try decode(written.reportURL)
        #expect(json["body"] as? String == "just words")
        #expect((json["images"] as? [Any])?.isEmpty == true)
        // No image subdirectory was created.
        let imageDir = dir.appendingPathComponent(".feedback/new/\(written.stem)")
        #expect(!FileManager.default.fileExists(atPath: imageDir.path))
    }

    /// A completely empty submission is rejected.
    @Test func emptySubmissionThrows() throws {
        let (worktree, _) = try makeWorktree()
        #expect(throws: ViewerFeedbackReport.WriteError.empty) {
            try ViewerFeedbackReport.write(
                segments: [.text("   \n ")],
                images: [],
                worktree: worktree,
                source: "x")
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
                source: "x")
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
}
