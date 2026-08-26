import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// A viewer pane must fit the pane it is given, however narrow. It is a leaf in
/// the split tree exactly like a terminal: the tree decides the width, the leaf
/// does not get a vote. A viewer that reports a minimum width instead gets laid
/// out at that minimum and CENTERED in the smaller frame, so it paints over the
/// pane next door and off the edge of the window.
@MainActor
struct ViewerNarrowPaneTests {
    private func makeMarkdownFile() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-narrow-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("doc.md")
        try "# One\n\nbody\n\n# Two\n\nmore\n".write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// Mount a viewer leaf the way `SplitView` does: a fixed-size frame inside a
    /// much wider container, so an oversized leaf has room to overflow visibly.
    private func mount(
        _ viewer: ViewerView,
        paneWidth: CGFloat,
        containerWidth: CGFloat = 900
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: containerWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true)
        let host = NSHostingView(rootView: ZStack(alignment: .topLeading) {
            ViewerSplitLeaf(viewerView: viewer)
                .frame(width: paneWidth, height: 400)
        })
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        // The chrome bar is a nested NSHostingView; let it size its SwiftUI
        // content before measuring.
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        return window
    }

    @Test func aNarrowPaneNeverMakesTheViewerWiderThanThePane() throws {
        let viewer = ViewerView(location: try makeMarkdownFile())

        let paneWidth: CGFloat = 120
        let window = mount(viewer, paneWidth: paneWidth)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(
            viewer.frame.width <= paneWidth,
            "viewer is \(viewer.frame.width)pt wide in a \(paneWidth)pt pane")
        #expect(
            viewer.frame.minX >= -0.5,
            "viewer starts at x=\(viewer.frame.minX), left of the pane")
    }

    /// The mechanism: the nav bar is pinned leading-to-trailing inside the pane,
    /// so anything it insists on becomes a floor the split tree cannot push
    /// below. It has to compress to the pane, not the other way round — and it
    /// has to do so by fitting the pins, not by Auto Layout breaking one of them.
    @Test func theNavBarCompressesToThePaneRatherThanWideningIt() throws {
        let viewer = ViewerView(location: try makeMarkdownFile())

        let paneWidth: CGFloat = 120
        let window = mount(viewer, paneWidth: paneWidth)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        let bar = try #require(viewer.subviews.first { $0 !== viewer.webView && !$0.isHidden })
        #expect(
            bar.frame.width == paneWidth,
            "nav bar is \(bar.frame.width)pt wide in a \(paneWidth)pt pane")
        #expect(bar.frame.height > 0, "nav bar collapsed to zero height")
    }
}
