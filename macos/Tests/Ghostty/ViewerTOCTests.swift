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

    /// A document tall enough that jumping to its last heading is a long,
    /// animated scroll past many others.
    private static var longDocument: String {
        (1...30).map { "## Section \($0)\n\n" + String(repeating: "Filler line.\n", count: 12) }
            .joined(separator: "\n")
    }

    /// Clicking a TOC row selects THAT row and keeps it selected.
    ///
    /// The click starts a smooth scroll, and the scroll spy sees every section
    /// the page flies past on the way — so without a pin the selection lands
    /// on the clicked heading and then walks off it mid-animation, which is
    /// exactly what the reader did not ask for.
    @Test func clickingARowKeepsItSelectedThroughTheScroll() async throws {
        let path = try makeFile(named: "long.md", contents: Self.longDocument)
        let (window, viewer) = makeViewer(location: path, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.tocItems.count >= 30 })

        // Jump from the top of the document to a heading far down it.
        let target = viewer.tocItems[25].id
        viewer.scrollToHeading(id: target)

        // Now stand in for the animation: scroll the page somewhere else and
        // let the resulting scroll event reach the spy. No user input was
        // involved, so the click still owns the selection. (Driving it this
        // way rather than waiting out a real smooth scroll keeps the test
        // deterministic — an offscreen web view may not animate at all.)
        _ = await evaluate("(window.scrollTo(0, 0), 'ok')", in: viewer)
        _ = await wait(upTo: 1.5) { false }
        #expect(
            viewer.activeHeadingID == target,
            "selection drifted to \(viewer.activeHeadingID ?? "nil") during the scroll")

        // ...and the spy is not wedged: a scroll the USER starts hands it back
        // immediately, from wherever the page actually is.
        let diag = await evaluate(
            """
            (function () {
              window.dispatchEvent(new WheelEvent('wheel', {deltaY: 10}));
              return 'scrollY=' + window.scrollY
                + ' h1top=' + Math.round(
                    document.querySelectorAll('h2')[0].getBoundingClientRect().top);
            })()
            """,
            in: viewer)
        let settled = await wait(upTo: 8) {
            viewer.activeHeadingID == viewer.tocItems.first?.id
        }
        let message =
            "spy stayed pinned after the user scrolled: "
            + "\(viewer.activeHeadingID ?? "nil") [\(diag ?? "no diag")]"
        #expect(settled, "\(message)")
    }

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
        #expect(await wait { viewer.sidePanelGutterWidth > 0 }, "gutter never reserved")

        // Pin the width: it is a user preference read from defaults, so
        // whatever this machine happens to have dragged it to must not decide
        // whether the test passes.
        viewer.setSidePanelWidth(240)

        // The card's left margin + the card. The gap on the card's RIGHT is
        // the document's own padding, not part of the gutter.
        let expected = GlassCard.outerMargin + 240
        #expect(viewer.sidePanelGutterWidth == expected)
        // The web view still spans the pane; only the page is padded.
        #expect(viewer.webView.frame.minX == 0)
        #expect(viewer.webView.frame.width == 900)
        // And the page actually applied it.
        _ = await wait(upTo: 1) { false }
        let padding = await evaluate(
            "String(parseFloat(getComputedStyle(document.body).paddingLeft))", in: viewer)
        #expect(
            padding.flatMap(Double.init) == Double(expected),
            "body padding was \(padding ?? "nil")")
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

        #expect(await wait { viewer.sidePanelGutterWidth > 0 })

        viewer.frame = NSRect(x: 0, y: 0, width: 500, height: 700)
        viewer.layoutSubtreeIfNeeded()

        #expect(viewer.sidePanelGutterWidth == 0, "narrow pane must not reserve a gutter")
        // ...and the page dropped the padding with it.
        _ = await wait(upTo: 2) { false }
        let padding = await evaluate(
            "getComputedStyle(document.body).paddingLeft", in: viewer)
        #expect(padding == "0px", "body padding was \(padding ?? "nil")")

        // And widening restores it.
        viewer.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        viewer.layoutSubtreeIfNeeded()
        #expect(viewer.sidePanelGutterWidth == GlassCard.outerMargin + viewer.sidePanelWidth)
    }

    /// Dragging the card's right edge moves the card AND the document's
    /// gutter together — the gutter is derived from the card width, so a
    /// resize that updated only one of them would leave a dead strip or an
    /// overlap. The width is clamped so a drag can neither collapse the card
    /// nor squeeze the document column out of the pane.
    @Test func resizingTheCardMovesTheGutterWithIt() async throws {
        let path = try makeFile(named: "doc.md", contents: Self.document)
        let (window, viewer) = makeViewer(location: path, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.sidePanelGutterWidth > 0 })

        viewer.setSidePanelWidth(320)
        #expect(viewer.sidePanelWidth == 320)
        #expect(viewer.sidePanelGutterWidth == GlassCard.outerMargin + 320)
        _ = await wait(upTo: 1) { false }
        let padding = await evaluate(
            "String(parseFloat(getComputedStyle(document.body).paddingLeft))", in: viewer)
        #expect(
            padding.flatMap(Double.init) == Double(GlassCard.outerMargin + 320),
            "body padding was \(padding ?? "nil")")

        // Absurd drags clamp instead of doing damage.
        viewer.setSidePanelWidth(10)
        let narrow = viewer.sidePanelWidth
        #expect(narrow > 100, "card collapsed to \(narrow)")
        viewer.setSidePanelWidth(5_000)
        #expect(
            viewer.sidePanelWidth < viewer.bounds.width - 300,
            "card ate the document column: \(viewer.sidePanelWidth)")
    }

    /// The measurement that makes a TOC card and a pane banner look like one
    /// design: the card floats `GlassCard.outerMargin` from the pane's edges,
    /// and the document leaves that same margin on every side of itself — so
    /// the first line of text starts one margin right of the card's right
    /// edge, on the same line as the card's top edge.
    @Test func documentAlignsToTheCard() async throws {
        let path = try makeFile(named: "doc.md", contents: Self.document)
        let (window, viewer) = makeViewer(location: path, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.sidePanelGutterWidth > 0 })
        // Let the gutter round-trip into the page.
        _ = await wait(upTo: 2) { false }

        let margin = GlassCard.outerMargin
        // The gutter IS the card's right edge: outerMargin + card width.
        let cardRight = viewer.sidePanelGutterWidth

        // Text left edge = body padding (the gutter) + the column's own
        // padding, with no `margin: auto` slack in between.
        let textLeft = await evaluate(
            """
            (function () {
              var b = document.querySelector('.markdown-body');
              var r = b.getBoundingClientRect();
              var p = parseFloat(getComputedStyle(b).paddingLeft);
              return String(Math.round(r.left + p));
            })()
            """, in: viewer)
        #expect(
            textLeft == String(Int(cardRight + margin)),
            "text left was \(textLeft ?? "nil")")

        // ...and the first line of text starts on the card's top edge.
        let textTop = await evaluate(
            """
            (function () {
              var h = document.querySelector('.markdown-body').firstElementChild;
              return String(Math.round(h.getBoundingClientRect().top));
            })()
            """, in: viewer)
        #expect(textTop == String(Int(margin)), "text top was \(textTop ?? "nil")")
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
        #expect(viewer.sidePanelGutterWidth == 0)
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
        #expect(viewer.sidePanelGutterWidth == 0)
    }

    /// Detaching a pane (close, undo) tears the card down and gives the
    /// document its full width back — a stale inset would leave a dead strip.
    @Test func detachRemovesTheGutter() async throws {
        let path = try makeFile(named: "doc.md", contents: Self.document)
        let (window, viewer) = makeViewer(location: path, width: 900)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await wait { viewer.sidePanelGutterWidth > 0 })

        viewer.setDetached(true)
        viewer.layoutSubtreeIfNeeded()
        // The gutter collapses over a layout pass, not inside `setDetached`, so
        // reading it straight after the call catches the old width on a loaded
        // machine.
        #expect(await wait { viewer.sidePanelGutterWidth == 0 },
                "gutter did not collapse on detach: \(viewer.sidePanelGutterWidth)")
    }
}
