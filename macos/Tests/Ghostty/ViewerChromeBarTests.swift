import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// Omnibox-style completion of addresses typed into the chrome URL field.
@MainActor
struct ViewerAddressCompletionTests {
    @Test func bareWordGetsSchemeAndCom() {
        #expect(ViewerView.completeAddress("cnn") == "https://cnn.com")
        #expect(ViewerView.completeAddress("my-site") == "https://my-site.com")
    }

    @Test func portAndPathSurviveCompletion() {
        #expect(ViewerView.completeAddress("cnn/videos") == "https://cnn.com/videos")
        #expect(ViewerView.completeAddress("cnn:8080/x") == "https://cnn.com:8080/x")
    }

    @Test func dottedHostOnlyGetsScheme() {
        #expect(ViewerView.completeAddress("example.org") == "https://example.org")
        #expect(ViewerView.completeAddress("news.ycombinator.com/item?id=1") == "https://news.ycombinator.com/item?id=1")
    }

    @Test func explicitSchemePassesThrough() {
        #expect(ViewerView.completeAddress("http://cnn") == "http://cnn")
        #expect(ViewerView.completeAddress("https://cnn.com") == "https://cnn.com")
    }

    @Test func localhostGetsPlainHTTPAndNoCom() {
        #expect(ViewerView.completeAddress("localhost:3000") == "http://localhost:3000")
        #expect(ViewerView.completeAddress("127.0.0.1:8642/page") == "http://127.0.0.1:8642/page")
    }
}

/// The viewer chrome bar must reserve space at the pane top while visible:
/// the web view is inset below the bar, so top-of-page content is never
/// covered and stays clickable. (The bar originally floated over the web
/// view, swallowing clicks on anything at the top of the page.)
@MainActor
struct ViewerChromeBarTests {
    /// Mount a viewer in an offscreen window, sized and laid out.
    private func makeViewer(location: String) -> (NSWindow, ViewerView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
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

    private func makeMarkdownFile() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-chrome-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("top-link.md")
        try "[top link](https://example.com)\n\nbody".write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// The revealed bar and the web view split the pane: bar flush at the
    /// top, web view starting at the bar's bottom edge, no overlap.
    @Test func revealedBarReservesSpaceAboveWebView() throws {
        let (window, viewer) = makeViewer(location: try makeMarkdownFile())
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        // Bar hidden: content owns the whole pane.
        #expect(viewer.webView.frame == viewer.bounds)

        viewer.holdChrome(true)
        // Let the hosting view size its SwiftUI content, then lay out.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        viewer.layoutSubtreeIfNeeded()

        let bar = try #require(viewer.subviews.first { $0 !== viewer.webView && !$0.isHidden })
        #expect(bar.frame.height > 0)
        // Non-flipped view: the pane top is maxY.
        #expect(bar.frame.maxY == viewer.bounds.maxY)
        // The web view starts below the bar — nothing is covered.
        #expect(!viewer.webView.frame.intersects(bar.frame))
        #expect(viewer.webView.frame.maxY <= bar.frame.minY)

        // A click at the very top of the page content must reach the web
        // view, not the bar. (viewer fills its superview at origin zero, so
        // viewer coordinates are valid hitTest input.)
        let topOfContent = NSPoint(x: viewer.bounds.midX, y: bar.frame.minY - 1)
        let hit = viewer.hitTest(topOfContent)
        #expect(hit === viewer.webView || hit?.isDescendant(of: viewer.webView) == true)
    }

    /// Web-mode viewers peek the bar the same way file viewers do: hidden
    /// until revealed, and reserving its space while shown.
    @Test func webModePeeksBarWithReservedSpace() throws {
        let (window, viewer) = makeViewer(location: "https://example.invalid/page")
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        // Hidden until hover/reveal: content owns the whole pane.
        #expect(!viewer.chromeVisible)
        #expect(viewer.webView.frame == viewer.bounds)

        viewer.holdChrome(true)
        // Offscreen windows take the non-animated path (geometry lands
        // synchronously); the spin just lets SwiftUI size the bar content.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        viewer.layoutSubtreeIfNeeded()

        let bar = try #require(viewer.subviews.first { $0 !== viewer.webView && !$0.isHidden })
        #expect(bar.frame.height > 0)
        #expect(!viewer.webView.frame.intersects(bar.frame))
    }

    /// Detaching (close/undo) tears down the bar and returns the pane to
    /// full-bleed content, with no stale inset left behind.
    @Test func detachRestoresFullBleedContent() throws {
        let (window, viewer) = makeViewer(location: try makeMarkdownFile())
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        viewer.holdChrome(true)
        // Offscreen windows take the non-animated path (geometry lands
        // synchronously); the spin just lets SwiftUI size the bar content.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        viewer.layoutSubtreeIfNeeded()

        viewer.setDetached(true)
        viewer.layoutSubtreeIfNeeded()
        #expect(viewer.webView.frame == viewer.bounds)
    }
}

/// Every viewer mode — including markdown/code files — gets the full
/// navigation chrome: back, forward, reload, home, and an EDITABLE address
/// field. File viewers used to render a static, read-only label here, which
/// made a file pane a dead end you could not navigate out of.
@MainActor
struct ViewerChromeControlsTests {
    private func mountBar(location: String) async -> (ViewerView, NSHostingView<WebChromeBar>) {
        let viewer = ViewerView(location: location)
        let host = NSHostingView(rootView: WebChromeBar(viewerView: viewer))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 44)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try? await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        return (viewer, host)
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { found.append(field) }
        view.subviews.forEach { found.append(contentsOf: editableFields(in: $0)) }
        return found
    }

    private func buttonCount(in view: NSView) -> Int {
        var count = String(describing: type(of: view)).contains("Button") ? 1 : 0
        view.subviews.forEach { count += buttonCount(in: $0) }
        return count
    }

    private func makeMarkdownFile() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-chrome-controls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.md")
        try "# hi\n".write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    @Test func fileViewerBarHasEditableAddressAndFourNavButtons() async throws {
        let (_, host) = await mountBar(location: try makeMarkdownFile())
        #expect(editableFields(in: host).count == 1)
        // back, forward, reload, home
        #expect(buttonCount(in: host) == 4)
    }

    @Test func webViewerBarHasTheSameControls() async throws {
        let (_, host) = await mountBar(location: "https://example.invalid/page")
        #expect(editableFields(in: host).count == 1)
        #expect(buttonCount(in: host) == 4)
    }

    /// "Open Browser Pane" opens blank and asks for the caret; the address
    /// field must actually take keyboard focus, or the user is left typing
    /// into nothing.
    @Test func focusAddressBarPutsCaretInTheField() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true)
        let viewer = ViewerView(location: ViewerView.blankPage)
        viewer.frame = window.contentView!.bounds
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        viewer.focusAddressBar()
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(viewer.chromeVisible)
        let field = try #require(ViewerView.firstTextField(in: viewer))
        // Focus lands on the field itself, or on the window's field editor
        // acting for it — but NOT on the web view, which is what the pane
        // focuses by default.
        let responder = window.firstResponder
        let isField = (responder as? NSView) === field
        let isFieldEditor = (responder as? NSText)?.delegate === field
        #expect(isField || isFieldEditor)
    }
}
