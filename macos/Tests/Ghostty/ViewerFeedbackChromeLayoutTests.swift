import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

/// Native-layer layout of the feedback composer against the viewer's other
/// chrome — the two bugs a pure SwiftUI test can't see because they live in
/// `ViewerView`'s AppKit subview stack and content inset:
///
///  1. The composer must draw ABOVE the table-of-contents card, not behind it.
///  2. The reserved space above the page must track the composer's height DOWN
///     as well as up, so deleting lines reflows the page back up.
///
/// Serialized like the other WKWebView-backed suites: they mount a real web
/// view and share the process-wide `ViewerWorktreeCache`.
@MainActor
@Suite(.serialized)
struct ViewerFeedbackChromeLayoutTests {
    /// A markdown file inside a throwaway git repo, so the pane resolves a
    /// worktree and the feedback affordance is allowed to open.
    private func makeRepoFile(named name: String = "doc.md", contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", dir.path, "init"]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try? git.run()
        git.waitUntilExit()
        let file = dir.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// Mount a viewer in an offscreen window at a given size, laid out. Not
    /// visible on purpose: `applyTopChromeGeometry` takes its non-animated path
    /// for a hidden window, so layout settles synchronously.
    private func makeViewer(location: String, width: CGFloat) -> (NSWindow, ViewerView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true)
        let viewer = ViewerView(location: location)
        viewer.frame = window.contentView!.bounds
        viewer.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        return (window, viewer)
    }

    /// A failure deadline, not a delay — it returns the moment the condition
    /// holds. Sized for the slowest thing behind these conditions: a real page
    /// load, and a worktree resolution that shells out to `git` off the main
    /// thread. Both have been measured past 10s on a loaded CI runner.
    private func wait(upTo seconds: TimeInterval = 60, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            // WebKit only makes progress while the run loop turns, and the
            // gutter these tests wait on is downstream of a real page load.
            // Sleeping alone is enough on an idle machine and stalls when the
            // main actor is contended by the target's parallel runners.
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Index of the first direct subview whose subtree contains a view matching
    /// `match`. Later index == drawn on top, which is how AppKit orders layers.
    private func layerIndex(in parent: NSView, matching match: (NSView) -> Bool) -> Int? {
        func subtreeContains(_ view: NSView) -> Bool {
            match(view) || view.subviews.contains(where: subtreeContains)
        }
        return parent.subviews.firstIndex(where: subtreeContains)
    }

    // MARK: - Bug 1: composer above the TOC card

    @Test func composerDrawsAboveTheTOCCard() async throws {
        // Three headings + a wide pane => the TOC card gets its own gutter.
        let doc = """
        # Title

        Intro.

        ## First

        Body.

        ## Second

        Body.
        """
        let path = try makeRepoFile(contents: doc)
        ViewerWorktreeCache.shared.invalidateAll()
        let (window, viewer) = makeViewer(location: path, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.sidePanelGutterWidth > 0 }, "TOC gutter never appeared")
        #expect(await wait { viewer.worktree != nil }, "worktree never resolved")

        viewer.setFeedbackOpen(true)
        viewer.layoutSubtreeIfNeeded()

        let composer = layerIndex(in: viewer) { $0 is NSHostingView<ViewerFeedbackBar> }
        let panel = layerIndex(in: viewer) { $0 is NSHostingView<ViewerSidePanel> }
        let composerIndex = try #require(composer, "composer never mounted")
        let panelIndex = try #require(panel, "side panel card never mounted")

        #expect(composerIndex > panelIndex,
                "composer (layer \(composerIndex)) must draw above the side panel card (layer \(panelIndex))")
    }

    /// Order holds regardless of which was created first: here the composer
    /// opens BEFORE the TOC card is mounted, then the card comes in beneath it.
    @Test func composerStaysAboveTOCWhenOpenedFirst() async throws {
        let doc = """
        # Title

        ## First

        Body.

        ## Second

        Body.
        """
        let path = try makeRepoFile(contents: doc)
        ViewerWorktreeCache.shared.invalidateAll()
        let (window, viewer) = makeViewer(location: path, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.worktree != nil }, "worktree never resolved")
        viewer.setFeedbackOpen(true)
        viewer.layoutSubtreeIfNeeded()

        // Now let the TOC card arrive (it mounts `.above webView`, i.e. beneath
        // the already-present composer).
        #expect(await wait { viewer.sidePanelGutterWidth > 0 }, "TOC gutter never appeared")
        viewer.layoutSubtreeIfNeeded()

        let composer = layerIndex(in: viewer) { $0 is NSHostingView<ViewerFeedbackBar> }
        let panel = layerIndex(in: viewer) { $0 is NSHostingView<ViewerSidePanel> }
        let composerIndex = try #require(composer)
        let panelIndex = try #require(panel)
        #expect(composerIndex > panelIndex)
    }

    // MARK: - Bug 2: content inset tracks the composer height both ways

    @Test func contentReflowsUpWhenComposerShrinks() async throws {
        let path = try makeRepoFile(contents: "# Title\n\nBody.\n")
        ViewerWorktreeCache.shared.invalidateAll()
        let (window, viewer) = makeViewer(location: path, width: 600)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await wait { viewer.worktree != nil }, "worktree never resolved")

        viewer.setFeedbackOpen(true)

        // Top inset the page is pushed down by, derived from the web view frame
        // (non-flipped: the pane top is high-y, so the inset is the gap there).
        func topInset() -> CGFloat {
            viewer.layoutSubtreeIfNeeded()
            return viewer.bounds.height - viewer.webView.frame.maxY
        }

        // Drive the bar's reported height synchronously (no `await` between the
        // report and the measurement, so the live GeometryReader can't race it).
        viewer.feedbackBarDidChangeHeight(120)
        let small = topInset()
        viewer.feedbackBarDidChangeHeight(300)
        let grown = topInset()
        viewer.feedbackBarDidChangeHeight(90)
        let shrunk = topInset()

        // Growing reserves more space...
        #expect(grown > small, "inset did not grow: \(small) -> \(grown)")
        // ...and — the actual bug — shrinking gives the space back.
        #expect(shrunk < grown, "inset did not shrink back: \(grown) -> \(shrunk)")

        // The inset tracks the reported height point-for-point (the constant
        // nav-bar height cancels out of the deltas).
        #expect(abs((grown - small) - 180) < 2, "grow delta off: \(grown - small)")
        #expect(abs((grown - shrunk) - 210) < 2, "shrink delta off: \(grown - shrunk)")
    }
}
