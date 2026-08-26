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

/// The viewer chrome bar must reserve space at the pane top: the content view
/// is inset below the bar, so top-of-page content is never covered and stays
/// clickable. (The bar originally floated over the web view, swallowing
/// clicks on anything at the top of the page.)
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

    /// The bar and the web view split the pane: bar flush at the top, web
    /// view starting at the bar's bottom edge, no overlap — from the pane's
    /// FIRST layout, with no hover and nothing to wait for.
    @Test func theBarReservesSpaceAboveWebView() throws {
        let (window, viewer) = makeViewer(location: try makeMarkdownFile())
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(viewer.chromeVisible)
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

    /// Same for a live page — the mode is irrelevant, which is the point.
    @Test func livePageReservesBarSpaceToo() throws {
        let (window, viewer) = makeViewer(location: "https://example.invalid/page")
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(viewer.chromeVisible)

        let bar = try #require(viewer.subviews.first { $0 !== viewer.webView && !$0.isHidden })
        #expect(bar.frame.height > 0)
        #expect(bar.frame.maxY == viewer.bounds.maxY)
        #expect(!viewer.webView.frame.intersects(bar.frame))
        #expect(viewer.webView.frame.maxY <= bar.frame.minY)
    }

    /// Detaching (close/undo) tears down the bar and returns the pane to
    /// full-bleed content, with no stale inset left behind.
    @Test func detachRestoresFullBleedContent() throws {
        let (window, viewer) = makeViewer(location: try makeMarkdownFile())
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        // Offscreen windows take the non-animated path (geometry lands
        // synchronously); the spin just lets SwiftUI size the bar content.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        viewer.layoutSubtreeIfNeeded()

        viewer.setDetached(true)
        viewer.layoutSubtreeIfNeeded()
        #expect(viewer.webView.frame == viewer.bounds)
    }
}

/// The navigation bar is pinned open in EVERY viewer mode. It used to peek in
/// on a mouse-to-the-top-edge for markdown and code panes; that was the one
/// mode where content reflowed under the pointer, and where the address, Home,
/// and Back/Forward — the only way out of a viewer pane — had to be hunted for
/// with the mouse first.
@MainActor
struct ViewerChromePinTests {
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

    private func makeFile(named name: String, contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-chrome-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    @Test func websitePaneOpensPinned() throws {
        let (window, viewer) = makeViewer(location: "https://example.invalid/page")
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(viewer.chromeVisible)
    }

    @Test func htmlFilePaneOpensPinned() throws {
        let path = try makeFile(named: "mock.html", contents: "<html><body>hi</body></html>")
        let (window, viewer) = makeViewer(location: path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(viewer.chromeVisible)
    }

    /// The blank browser pane is nothing BUT its address field — hiding the
    /// bar would leave an empty pane with no way to use it.
    @Test func blankBrowserPaneOpensPinned() throws {
        let (window, viewer) = makeViewer(location: ViewerView.blankPage)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(viewer.chromeVisible)
    }

    /// The modes that used to peek. Both now open pinned, with the bar's
    /// space already reserved in the pane's first layout.
    @Test func markdownAndCodePanesOpenPinned() throws {
        for path in [
            try makeFile(named: "a.md", contents: "# hi\n"),
            try makeFile(named: "a.swift", contents: "let x = 1\n"),
        ] {
            let (window, viewer) = makeViewer(location: path)
            defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
            #expect(viewer.chromeVisible, "\(path) should open pinned")
            #expect(viewer.webView.frame.height < viewer.bounds.height,
                    "\(path) should reserve the bar's row")
        }
    }

    /// An image pane too — its content is native, but the chrome is the same
    /// chrome and reserves space the same way.
    @Test func imagePanesOpenPinned() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-chrome-pin-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let file = dir.appendingPathComponent("a.png")
        try rep.representation(using: .png, properties: [:])!.write(to: file)

        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(viewer.chromeVisible)
        #expect(viewer.webView.frame.height < viewer.bounds.height)
    }

    /// A pane's mode is not fixed at open — the address field navigates a
    /// markdown viewer to the web and Back brings it home — and the bar stays
    /// put across all of it. There is no longer anything mode-dependent to
    /// follow.
    @Test func theBarStaysPinnedAcrossAModeChange() throws {
        let path = try makeFile(named: "a.md", contents: "# hi\n")
        let (window, viewer) = makeViewer(location: path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(viewer.chromeVisible)

        viewer.navigate(to: "https://example.invalid/page")
        #expect(viewer.chromeVisible)

        viewer.navigate(to: path)
        #expect(viewer.chromeVisible)
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

        #expect(viewer.focusAddressBar(), "the pane is in a window, so it must accept the focus request")

        // Focus lands on the field itself, or on the window's field editor
        // acting for it — but NOT on the web view, which is what the pane
        // focuses by default.
        //
        // Poll rather than sleep-then-check. The caret arrives within a few
        // tens of milliseconds, but an offscreen test window is never key, so
        // the field loses focus again shortly after and the bar's 2s auto-hide
        // then takes the chrome (and the first responder) with it. A fixed
        // wait races that teardown; waiting for the condition does not.
        let caretInField = await poll {
            guard viewer.chromeVisible,
                  let field = ViewerView.firstTextField(in: viewer)
            else { return false }
            let responder = window.firstResponder
            return (responder as? NSView) === field
                || (responder as? NSText)?.delegate === field
        }

        #expect(caretInField, """
            caret never reached the address field: chromeVisible=\(viewer.chromeVisible) \
            field=\(String(describing: ViewerView.firstTextField(in: viewer))) \
            responder=\(String(describing: window.firstResponder))
            """)
    }
}
