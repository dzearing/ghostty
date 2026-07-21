import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

/// The viewer's table of contents is drawn natively but sourced from the
/// page: viewer.js assigns heading anchors and posts them over the `viewerTOC`
/// script-message bridge. These tests drive the real WKWebView end to end —
/// a broken bridge or a template that stops emitting headings shows up here
/// rather than as an empty card in a pane.
@MainActor
struct ViewerTOCTests {
    /// Mount a viewer in an offscreen window at a given size, laid out.
    private func makeViewer(location: String, width: CGFloat = 900) -> (NSWindow, ViewerView) {
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

    private func makeFile(named name: String, contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-toc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// Wait until `condition` holds, or give up.
    ///
    /// Deliberately NOT spinning `RunLoop.main.run(until:)`: that is
    /// unavailable from an async context (a hard error under Swift 6) and
    /// re-entering the runloop here races the continuation in `evaluate`.
    /// Awaiting a sleep yields the main actor, which lets the runloop turn
    /// and WebKit deliver its callbacks on its own.
    private func wait(
        upTo seconds: TimeInterval = 10,
        for condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    /// Read a value out of the loaded page.
    private func evaluate(_ script: String, in viewer: ViewerView) async -> String? {
        await withCheckedContinuation { continuation in
            viewer.webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    private static let document = """
    # Title

    Intro paragraph.

    ## First section

    Body.

    ### Nested detail

    Body.

    ## Second section

    Body.
    """

    /// Headings reach the native side with anchors, and nesting is relative
    /// to the document's own top level.
    @Test func headingsArriveFromThePage() async throws {
        let path = try makeFile(named: "doc.md", contents: Self.document)
        let (window, viewer) = makeViewer(location: path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { !viewer.tocItems.isEmpty }, "no headings arrived over the bridge")

        #expect(viewer.tocItems.map(\.text) == [
            "Title", "First section", "Nested detail", "Second section",
        ])
        // h1 is the document's top level, so it sits at depth 0 and the rest
        // indent relative to it.
        #expect(viewer.tocItems.map(\.depth) == [0, 1, 2, 1])
        // Anchors are slugified and non-empty — they are what scrolling uses.
        #expect(viewer.tocItems.map(\.id) == [
            "title", "first-section", "nested-detail", "second-section",
        ])
    }

    /// A wide pane gives the card a gutter, reserved as padding on the PAGE
    /// rather than as an inset on the web view — the strip behind the card
    /// has to paint the document's own background, not this view's.
    @Test func widePaneReservesAPageGutter() async throws {
        let path = try makeFile(named: "doc.md", contents: Self.document)
        let (window, viewer) = makeViewer(location: path, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { !viewer.tocItems.isEmpty })
        #expect(await wait { viewer.tocGutterWidth > 0 }, "gutter never reserved")

        // Card width + a margin on each side.
        #expect(viewer.tocGutterWidth == CGFloat(216 + 14 * 2))
        // The web view still spans the pane; only the page is padded.
        #expect(viewer.webView.frame.minX == 0)
        #expect(viewer.webView.frame.width == 900)
        // And the page actually applied it.
        let padding = await evaluate(
            "getComputedStyle(document.body).paddingLeft", in: viewer)
        #expect(padding == "244px", "body padding was \(padding ?? "nil")")
        // A hosting view for the card is mounted above the web view.
        let overlays = viewer.subviews.filter { $0 !== viewer.webView }
        #expect(!overlays.isEmpty)
    }

    /// Narrowing the pane past the threshold collapses the gutter — the
    /// document reclaims the full width and the card becomes an overlay.
    /// Panes are resized constantly by split drags, so this must ride layout.
    @Test func narrowingThePaneCollapsesTheGutter() async throws {
        let path = try makeFile(named: "doc.md", contents: Self.document)
        let (window, viewer) = makeViewer(location: path, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.tocGutterWidth > 0 })

        viewer.frame = NSRect(x: 0, y: 0, width: 500, height: 700)
        viewer.layoutSubtreeIfNeeded()

        #expect(viewer.tocGutterWidth == 0, "narrow pane must not reserve a gutter")
        // ...and the page dropped the padding with it.
        _ = await wait(upTo: 2) { false }
        let padding = await evaluate(
            "getComputedStyle(document.body).paddingLeft", in: viewer)
        #expect(padding == "0px", "body padding was \(padding ?? "nil")")

        // And widening restores it.
        viewer.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        viewer.layoutSubtreeIfNeeded()
        #expect(viewer.tocGutterWidth == CGFloat(216 + 14 * 2))
    }

    /// One heading is a title, not a table of contents.
    @Test func singleHeadingDocumentGetsNoTOC() async throws {
        let path = try makeFile(
            named: "one.md", contents: "# Just a title\n\nSome prose.\n")
        let (window, viewer) = makeViewer(location: path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        // Give the page time to load and report (it reports an empty list).
        _ = await wait(upTo: 4) { false }
        #expect(viewer.tocItems.isEmpty)
        #expect(viewer.tocGutterWidth == 0)
    }

    /// Text/code viewers are untouched by the TOC work.
    @Test func codeViewerGetsNoTOC() async throws {
        let path = try makeFile(
            named: "sample.swift",
            contents: "struct A {}\nstruct B {}\nstruct C {}\n")
        let (window, viewer) = makeViewer(location: path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        _ = await wait(upTo: 4) { false }
        #expect(viewer.tocItems.isEmpty)
        #expect(viewer.tocGutterWidth == 0)
    }

    /// Detaching a pane (close, undo) tears the card down and gives the
    /// document its full width back — a stale inset would leave a dead strip.
    @Test func detachRemovesTheGutter() async throws {
        let path = try makeFile(named: "doc.md", contents: Self.document)
        let (window, viewer) = makeViewer(location: path, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.tocGutterWidth > 0 })

        viewer.setDetached(true)
        viewer.layoutSubtreeIfNeeded()
        #expect(viewer.tocGutterWidth == 0)
    }
}
