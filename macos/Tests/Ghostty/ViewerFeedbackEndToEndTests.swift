import AppKit
import Testing
@testable import Ghostty

/// End-to-end through a real `ViewerView`: async worktree resolution against a
/// live git repo, the feedback affordance gating on it, and `sendFeedback`
/// writing a report — the whole chain the pure-logic tests stub out.
///
/// Serialized: these mount a WKWebView-backed `ViewerView` and share the
/// process-wide `ViewerWorktreeCache` singleton, so running them concurrently
/// (the whole GhosttyTests target uses two runners) lets one test's
/// `invalidateAll` race another's pending resolution.
@MainActor
@Suite(.serialized)
struct ViewerFeedbackEndToEndTests {
    /// A throwaway git repo with one markdown file in it. `repo` is git's OWN
    /// `--show-toplevel` output, so the comparison uses the exact same
    /// canonical form the resolver will produce (`NSString.resolvingSymlinks
    /// InPath` is unreliable for `/private/var`, so it can't be used here).
    private func makeRepo() throws -> (repo: URL, file: URL) {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-feedback-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        _ = runGit(["-C", created.path, "init"])
        let root = runGit(["-C", created.path, "rev-parse", "--show-toplevel"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = URL(fileURLWithPath: root)
        let file = repo.appendingPathComponent("README.md")
        try "# demo\n".write(to: file, atomically: true, encoding: .utf8)
        return (repo, file)
    }

    @discardableResult
    private func runGit(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Await `condition`, yielding to the MainActor executor so the resolver's
    /// main-thread completion can run. A synchronous `RunLoop.main.run` spin
    /// does NOT service it under Swift Testing's @MainActor executor.
    private func wait(upTo seconds: TimeInterval, for condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A viewer opened on a file inside a repo resolves that repo as its
    /// worktree — off the main thread, so the test waits for it.
    @Test func fileViewerResolvesWorktree() async throws {
        let (repo, file) = try makeRepo()
        ViewerWorktreeCache.shared.invalidateAll()
        let viewer = ViewerView(location: file.path)
        await wait(upTo: 5) { viewer.worktree != nil }
        #expect(viewer.worktree?.path == repo.path)
        #expect(viewer.worktree?.name == repo.lastPathComponent)
    }

    /// The full send path: resolve the worktree, compose text plus an image,
    /// call `sendFeedback`, and confirm a machine-readable report with its
    /// image lands in the repo's `.feedback/new/` — and the composer clears.
    @Test func sendFeedbackWritesReportIntoRepo() async throws {
        let (repo, file) = try makeRepo()
        ViewerWorktreeCache.shared.invalidateAll()
        let viewer = ViewerView(location: file.path)
        await wait(upTo: 5) { viewer.worktree != nil }
        let worktree = try #require(viewer.worktree)

        // Compose: prose + one pasted image chip.
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let png = try #require(ViewerFeedbackTextView.pngData(from: image))
        viewer.feedbackModel.textStorage.append(NSAttributedString(
            string: "The header overlaps ",
            attributes: ViewerFeedbackModel.typingAttributes))
        viewer.feedbackModel.insertImage(
            image, png: png,
            at: NSRange(location: viewer.feedbackModel.textStorage.length, length: 0))
        viewer.feedbackModel.syncAttachments()

        viewer.sendFeedback()

        // Success is signalled and the composer cleared.
        guard case .filed = viewer.feedbackModel.status else {
            Issue.record("expected a filed status, got \(String(describing: viewer.feedbackModel.status))")
            return
        }
        #expect(viewer.feedbackModel.isEmpty)

        // A report with a resolvable image path landed in the queue.
        let queue = worktree.url.appendingPathComponent(".feedback/new")
        let reports = try FileManager.default.contentsOfDirectory(atPath: queue.path)
            .filter { $0.hasSuffix(".json") }
        #expect(reports.count == 1)
        let reportURL = queue.appendingPathComponent(reports[0])
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: reportURL)) as! [String: Any]
        #expect(json["worktree"] as? String == repo.path)
        #expect(json["source"] as? String == file.path)
        let body = try #require(json["body"] as? String)
        #expect(body.contains("The header overlaps"))
        // The chip rendered as an image path that actually exists.
        let images = try #require(json["images"] as? [[String: Any]])
        let rel = try #require(images.first?["path"] as? String)
        #expect(FileManager.default.fileExists(
            atPath: queue.appendingPathComponent(rel).path))
    }

    /// Sending with no worktree fails loudly rather than silently dropping the
    /// report — a viewer on a remote site with no origin has nowhere to file.
    @Test func sendWithNoWorktreeReportsFailure() async throws {
        ViewerWorktreeCache.shared.invalidateAll()
        let viewer = ViewerView(location: "https://example.invalid/page")
        await wait(upTo: 2) { false } // let any resolution settle
        #expect(viewer.worktree == nil)

        viewer.feedbackModel.textStorage.append(NSAttributedString(string: "hi"))
        viewer.feedbackModel.syncAttachments()
        viewer.sendFeedback()
        guard case .failed = viewer.feedbackModel.status else {
            Issue.record("expected a failed status")
            return
        }
    }
}
