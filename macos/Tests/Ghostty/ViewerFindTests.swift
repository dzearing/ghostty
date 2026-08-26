import AppKit
import Testing
import WebKit
@testable import Ghostty

/// The find bar's count label. Pure, because "3/17" is the whole point of
/// having built find in JavaScript rather than on WKWebView's own `find`
/// (which reports only `matchFound`), and it must not be reasoned about only
/// by looking at a running pane.
@MainActor
struct ViewerFindResultTests {
    @Test func saysNothingWithNoQuery() {
        #expect(ViewerFindResult.none.label(hasQuery: false) == nil)
        // A stale count from a previous query must not survive the field
        // being emptied.
        let stale = ViewerFindResult(total: 12, index: 3)
        #expect(stale.label(hasQuery: false) == nil)
    }

    @Test func countsMatchesBrowserStyle() {
        #expect(ViewerFindResult(total: 17, index: 3).label(hasQuery: true) == "3/17")
        #expect(ViewerFindResult(total: 1, index: 1).label(hasQuery: true) == "1/1")
    }

    @Test func saysSoWhenThereAreNoMatches() {
        #expect(ViewerFindResult(total: 0, index: 0).label(hasQuery: true) == "No results")
    }

    /// Past the page-side match cap the total is a floor, not a count, and the
    /// label has to admit it rather than reporting a precise-looking 5000.
    @Test func marksATruncatedCountAsAFloor() {
        let capped = ViewerFindResult(total: 5000, index: 12, truncated: true)
        #expect(capped.label(hasQuery: true) == "12/5000+")
    }

    /// Zero matches is still zero matches even at the cap — the "+" would be a
    /// lie, since a truncated scan that found nothing found nothing.
    @Test func aTruncatedEmptyResultStillReadsAsNoResults() {
        let capped = ViewerFindResult(total: 0, index: 0, truncated: true)
        #expect(capped.label(hasQuery: true) == "No results")
    }
}

/// Decoding the page's `find` message. The bridge is shared with the TOC,
/// quoting, and the link menu, so a malformed or partial payload must degrade
/// rather than throw the pane's find state away.
@MainActor
struct ViewerFindPayloadTests {
    @Test func readsAFullPayload() {
        let result = ViewerFindResult(payload: [
            "total": 17, "index": 3, "truncated": false, "note": "in ViewerView.swift",
        ])
        #expect(result == ViewerFindResult(
            total: 17, index: 3, truncated: false, note: "in ViewerView.swift"))
    }

    @Test func toleratesMissingFields() {
        #expect(ViewerFindResult(payload: [:]) == ViewerFindResult.none)
        #expect(ViewerFindResult(payload: ["total": 4]) == ViewerFindResult(total: 4, index: 0))
    }

    /// An empty note is no note: the bar must not reserve a line for a blank
    /// caption.
    @Test func treatsAnEmptyNoteAsAbsent() {
        #expect(ViewerFindResult(payload: ["note": ""]).note == nil)
    }
}

/// Escape and Return mean different things depending on which of a viewer
/// pane's three text fields has the caret — the address bar, a diff's file
/// filter, and now the find field. Classified purely so the precedence is
/// checkable without a live pane.
@MainActor
struct ViewerFieldKeyActionTests {
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code)!
    }

    private let escape: UInt16 = 53
    private let ret: UInt16 = 36
    private let keypadEnter: UInt16 = 76

    /// The address field owns Escape while it is being edited, even with find
    /// open: an abandoned address edit left sitting in the bar is a lie about
    /// where the pane is, and closing find would not fix it.
    @Test func escapePrefersTheAddressFieldThenTheFilterThenFind() {
        #expect(ViewerView.fieldKeyAction(
            for: key(escape), addressFocused: true, diffFilterFocused: false,
            findFocused: false, findOpen: true) == .revertAddress)
        #expect(ViewerView.fieldKeyAction(
            for: key(escape), addressFocused: false, diffFilterFocused: true,
            findFocused: false, findOpen: true) == .clearDiffFilter)
        #expect(ViewerView.fieldKeyAction(
            for: key(escape), addressFocused: false, diffFilterFocused: false,
            findFocused: true, findOpen: true) == .closeFind)
    }

    /// Escape closes find from the PAGE too, not just from the find field —
    /// that is what a browser does, and the highlights are on the page.
    @Test func escapeClosesFindFromThePage() {
        #expect(ViewerView.fieldKeyAction(
            for: key(escape), addressFocused: false, diffFilterFocused: false,
            findFocused: false, findOpen: true) == .closeFind)
    }

    /// With nothing to dismiss, Escape belongs to whoever else wants it.
    @Test func escapeIsNotClaimedWhenThereIsNothingOpen() {
        #expect(ViewerView.fieldKeyAction(
            for: key(escape), addressFocused: false, diffFilterFocused: false,
            findFocused: false, findOpen: false) == nil)
    }

    /// Return steps matches, and only while the FIND field has the caret —
    /// Return in the filter opens the top file, and in the address it
    /// navigates. Both of those are handled by their own fields' onSubmit.
    @Test func returnStepsMatchesOnlyFromTheFindField() {
        #expect(ViewerView.fieldKeyAction(
            for: key(ret), addressFocused: false, diffFilterFocused: false,
            findFocused: true, findOpen: true) == .findNext)
        #expect(ViewerView.fieldKeyAction(
            for: key(ret, [.shift]), addressFocused: false, diffFilterFocused: false,
            findFocused: true, findOpen: true) == .findPrevious)
        #expect(ViewerView.fieldKeyAction(
            for: key(keypadEnter), addressFocused: false, diffFilterFocused: false,
            findFocused: true, findOpen: true) == .findNext)
        // Not the find field: leave Return alone.
        #expect(ViewerView.fieldKeyAction(
            for: key(ret), addressFocused: false, diffFilterFocused: true,
            findFocused: false, findOpen: true) == nil)
    }

    /// A command/control/option chord is somebody else's (Cmd-G is classified
    /// as a pane chord, not here).
    @Test func modifiedKeysAreNotFieldActions() {
        #expect(ViewerView.fieldKeyAction(
            for: key(escape, [.command]), addressFocused: true, diffFilterFocused: false,
            findFocused: false, findOpen: true) == nil)
        #expect(ViewerView.fieldKeyAction(
            for: key(ret, [.command]), addressFocused: false, diffFilterFocused: false,
            findFocused: true, findOpen: true) == nil)
    }
}

/// Live routing: Cmd-F opens the bar and lands the caret in the find field,
/// Escape closes it and clears the page's highlights, and the whole thing is
/// scoped to the focused pane.
@MainActor
@Suite(.serialized)
struct ViewerFindRoutingTests {
    private func keyEvent(
        _ chars: String, _ flags: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0)!
    }

    private func makePane(location: String) -> (NSWindow, ViewerView, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(location: location)
        viewer.frame = NSRect(x: 0, y: 0, width: 450, height: 600)
        let sibling = FindFocusableView(frame: NSRect(x: 450, y: 0, width: 450, height: 600))
        window.contentView!.addSubview(viewer)
        window.contentView!.addSubview(sibling)
        viewer.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        return (window, viewer, sibling)
    }

    private func markdownFile() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-find-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("doc.md")
        try "# Doc\n\nalpha beta alpha gamma alpha\n".write(
            to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    @Test func cmdFOpensTheFindBarAndFocusesItsField() async throws {
        let (window, viewer, _) = makePane(location: try markdownFile())
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        window.makeFirstResponder(viewer.webView)
        #expect(window.performKeyEquivalent(with: keyEvent("f", [.command])),
                "Cmd-F was not handled by the focused viewer pane")
        #expect(viewer.findOpen, "Cmd-F did not open the find bar")

        // The caret lands in the find field, not the address field: both are
        // NSTextFields inside the pane, so assert on the one find mounted.
        var editor: NSText?
        await poll {
            viewer.layoutSubtreeIfNeeded()
            guard let field = viewer.findFieldForTesting,
                  let text = window.firstResponder as? NSText,
                  field.currentEditor() === text
            else { return false }
            editor = text
            return true
        }
        #expect(editor != nil, """
            find field never took focus: findOpen=\(viewer.findOpen) \
            field=\(String(describing: viewer.findFieldForTesting)) \
            responder=\(String(describing: window.firstResponder))
            """)
    }

    /// Escape closes the bar and clears the page's highlights, but KEEPS the
    /// query — the browser contract. Cmd-G resumes the same search, and
    /// re-opening with Cmd-F comes back to it pre-selected, ready to replace.
    /// What must not survive is the match COUNT: it describes a page that is no
    /// longer highlighted.
    @Test func escapeClosesFindAndClearsTheHighlights() async throws {
        let (window, viewer, _) = makePane(location: try markdownFile())
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        window.makeFirstResponder(viewer.webView)
        #expect(window.performKeyEquivalent(with: keyEvent("f", [.command])))
        viewer.setFindQuery("alpha")
        #expect(viewer.findQuery == "alpha")

        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        #expect(viewer.handleChromeKeyDown(escape),
                "Escape was not consumed while the find bar was open")
        #expect(!viewer.findOpen, "Escape did not close the find bar")
        #expect(viewer.findResult == .none, "Escape left a stale match count")
        #expect(viewer.findQuery == "alpha",
                "Escape threw away the query Cmd-G is supposed to resume")
    }

    /// Cmd-F belongs to the focused pane only: a terminal split in the same
    /// window must keep whatever Cmd-F means globally, because
    /// `performKeyEquivalent` is offered to every view.
    @Test func cmdFIsIgnoredWhileTheViewerIsNotFocused() async throws {
        let (window, viewer, sibling) = makePane(location: try markdownFile())
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        window.makeFirstResponder(sibling)
        #expect(!window.performKeyEquivalent(with: keyEvent("f", [.command])),
                "Cmd-F was swallowed while the viewer was NOT focused")
        #expect(!viewer.findOpen)
    }

    /// Cmd-G with no search yet has nothing to step, so the PANE declines it —
    /// `handle` returns false and `performKeyEquivalent` walks on to `super`
    /// rather than swallowing the key.
    ///
    /// Asserted at the pane's own contract rather than on the window's return
    /// value, because the focused WKWebView below us claims an unhandled Cmd-G
    /// itself (it is the standard "find next" editing chord). That is WebKit's
    /// call about a focused web view and predates this feature; what is ours to
    /// guarantee is that we do not eat it first and do not open an empty bar.
    @Test func cmdGIsDeclinedWithNoActiveSearch() async throws {
        let (window, viewer, _) = makePane(location: try markdownFile())
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        window.makeFirstResponder(viewer.webView)
        #expect(!viewer.stepFindFromKeyboard(1),
                "Cmd-G claimed a step with no query to step through")
        _ = window.performKeyEquivalent(with: keyEvent("g", [.command]))
        #expect(!viewer.findOpen, "Cmd-G opened a find bar with nothing to find")
        #expect(viewer.findQuery.isEmpty)
    }

    /// Cmd-G after a search re-opens the bar and steps, the way Safari does —
    /// the query outlives the bar being closed.
    @Test func cmdGReopensFindAndReusesTheLastQuery() async throws {
        let (window, viewer, _) = makePane(location: try markdownFile())
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        window.makeFirstResponder(viewer.webView)
        #expect(window.performKeyEquivalent(with: keyEvent("f", [.command])))
        viewer.setFindQuery("alpha")
        viewer.closeFind()
        #expect(!viewer.findOpen)

        window.makeFirstResponder(viewer.webView)
        #expect(window.performKeyEquivalent(with: keyEvent("g", [.command])),
                "Cmd-G did not resume the last search")
        #expect(viewer.findOpen)
        #expect(viewer.findQuery == "alpha")
    }

    /// A viewer pane with no window can mount no find bar, so Cmd-F must
    /// report failure instead of swallowing the key.
    @Test func openFindReportsFailureWithNoWindow() {
        let viewer = ViewerView(location: ViewerView.blankPage)
        #expect(!viewer.openFind(), "a windowless viewer claimed it opened a find bar")
    }
}

/// The page-side engine, driven end to end through a real WKWebView.
///
/// This is the part that could not be built on WKWebView's own
/// `find(_:configuration:)` — it reports `matchFound` and nothing else — so
/// the counting, the ordinal, the wrap, and the exclusions are ours and have
/// to be tested as such.
///
/// Serialized: each test stands up a real web view and loads a page.
@MainActor
@Suite(.serialized)
struct ViewerFindEngineTests {
    /// A viewer in a real, sized window: `find.js` filters matches by client
    /// rect and scrolls by viewport height, neither of which a zero-frame web
    /// view has.
    private func makeViewer() -> (NSWindow, ViewerView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(location: ViewerView.blankPage)
        viewer.frame = window.contentView!.bounds
        viewer.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        return (window, viewer)
    }

    private func wait(
        upTo seconds: TimeInterval = 10, for condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    /// Load a page and wait for the DOCUMENT, not for `isLoading`: that flag is
    /// still false in the instant between the call and WebKit starting the
    /// load, so polling it returns before there is a page at all — and a search
    /// pushed into an empty document reports zero matches forever, since
    /// nothing re-runs it.
    private func load(_ html: String, into viewer: ViewerView) async -> Bool {
        viewer.webView.loadHTMLString(
            "<html><body>\(html)</body></html>",
            baseURL: URL(string: "https://example.invalid/"))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let ready = try? await viewer.webView.evaluateJavaScript("""
                document.readyState === 'complete'
                    && !!window.__ghozttyFind
                    && !!document.body && document.body.children.length > 0
                """)
            if (ready as? Bool) == true { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    /// Three visible "alpha"s — one plain, one differently cased, and one
    /// SPLIT ACROSS two inline elements (which is the case a naive per-text-node
    /// search misses) — plus one that is display:none and must not count.
    private let page = """
        <p id="a">alpha beta</p>
        <p id="b">Alpha gamma</p>
        <div><span>al</span><span>pha</span> delta</div>
        <p style="display:none">alpha hidden</p>
        <p>foo</p><p>bar</p>
        """

    @Test func countsEveryVisibleMatchCaseInsensitively() async throws {
        let (window, viewer) = makeViewer()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await load(page, into: viewer), "page never loaded")

        viewer.setFindQuery("alpha")
        #expect(await wait { viewer.findResult.total == 3 },
                "expected 3 matches, got \(viewer.findResult.total)")
        #expect(viewer.findResult.index == 1, "a fresh query starts on the first match")
        #expect(viewer.findResult.label(hasQuery: true) == "1/3")
        #expect(!viewer.findResult.truncated)
    }

    /// The matches are really PAINTED, not just counted: every non-current one
    /// goes into the all-matches highlight and the current one into its own, so
    /// the page shows yellow-with-one-orange the way a browser does. Asserted
    /// through `CSS.highlights` because the paint mutates no DOM and so leaves
    /// nothing else to look at.
    @Test func paintsEveryMatchAndSinglesOutTheCurrentOne() async throws {
        let (window, viewer) = makeViewer()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await load(page, into: viewer))

        viewer.setFindQuery("alpha")
        #expect(await wait { viewer.findResult.total == 3 })

        let supported = (try? await viewer.webView.evaluateJavaScript(
            "!!(window.CSS && CSS.highlights && window.Highlight)")) as? Bool ?? false
        // Below Safari 17.2 there is no Custom Highlight API and the current
        // match is an ordinary selection instead; the count and the stepping
        // (asserted above and below) are the part that must hold either way.
        guard supported else { return }

        let sizes = try? await viewer.webView.evaluateJavaScript("""
            (function () {
              var all = CSS.highlights.get('ghoztty-find');
              var one = CSS.highlights.get('ghoztty-find-current');
              return (all ? all.size : -1) + ',' + (one ? one.size : -1);
            })()
            """)
        #expect(sizes as? String == "2,1",
                "expected 2 other matches + 1 current, got \(String(describing: sizes))")
        // …and the rule that gives them a color.
        let styled = try? await viewer.webView.evaluateJavaScript(
            "!!document.getElementById('ghoztty-find-style')")
        #expect(styled as? Bool == true, "no ::highlight() stylesheet was installed")

        // Closing takes the paint away with it.
        viewer.closeFind()
        #expect(await waitJS(in: viewer, """
            (function () {
              var all = CSS.highlights.get('ghoztty-find');
              var one = CSS.highlights.get('ghoztty-find-current');
              return !all && !one;
            })()
            """), "closing find left highlights on the page")
    }

    /// Poll a boolean expression inside the page.
    private func waitJS(
        in viewer: ViewerView, upTo seconds: TimeInterval = 5, _ script: String
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let value = try? await viewer.webView.evaluateJavaScript(script)
            if (value as? Bool) == true { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    /// Text in the tree but not laid out is not text a reader can be scrolled
    /// to; counting it would promise a match that goes nowhere.
    @Test func skipsTextThatIsNotLaidOut() async throws {
        let (window, viewer) = makeViewer()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await load(page, into: viewer))

        viewer.setFindQuery("hidden")
        #expect(await wait { viewer.findResult.label(hasQuery: true) == "No results" },
                "display:none text was counted as a match")
    }

    /// A query may not run across a block boundary — "foo" and "bar" are two
    /// paragraphs, and no browser matches "foo bar" across them.
    @Test func doesNotMatchAcrossABlockBoundary() async throws {
        let (window, viewer) = makeViewer()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await load(page, into: viewer))

        viewer.setFindQuery("foo bar")
        #expect(await wait { viewer.findResult.total == 0 },
                "a match ran across two paragraphs")
        // The control: the same words DO match inside one block.
        viewer.setFindQuery("pha delta")
        #expect(await wait { viewer.findResult.total == 1 },
                "a match spanning two inline elements was missed")
    }

    @Test func steppingWrapsInBothDirections() async throws {
        let (window, viewer) = makeViewer()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await load(page, into: viewer))

        viewer.setFindQuery("alpha")
        #expect(await wait { viewer.findResult.total == 3 })

        viewer.stepFind(1)
        #expect(await wait { viewer.findResult.index == 2 })
        viewer.stepFind(1)
        #expect(await wait { viewer.findResult.index == 3 })
        // Past the last match, back to the first.
        viewer.stepFind(1)
        #expect(await wait { viewer.findResult.index == 1 }, "next did not wrap")
        // And backwards off the front, to the last.
        viewer.stepFind(-1)
        #expect(await wait { viewer.findResult.index == 3 }, "previous did not wrap")
    }

    /// Emptying the field clears the search rather than leaving the last
    /// count (and the last highlights) sitting on the page.
    @Test func clearingTheQueryClearsTheResult() async throws {
        let (window, viewer) = makeViewer()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await load(page, into: viewer))

        viewer.setFindQuery("alpha")
        #expect(await wait { viewer.findResult.total == 3 })
        viewer.setFindQuery("")
        #expect(await wait { viewer.findResult == .none })
        #expect(viewer.findResult.label(hasQuery: false) == nil)
    }

    /// The page keeps the count live as it changes underneath an open search —
    /// which is what makes find usable on a diff still appending its rows.
    @Test func recountsWhenThePageChanges() async throws {
        let (window, viewer) = makeViewer()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await load(page, into: viewer))

        viewer.setFindQuery("alpha")
        #expect(await wait { viewer.findResult.total == 3 })

        viewer.webView.evaluateJavaScript("""
            var p = document.createElement('p');
            p.textContent = 'alpha again and alpha once more';
            document.body.appendChild(p);
            """, completionHandler: nil)
        #expect(await wait { viewer.findResult.total == 5 },
                "the count did not follow the page, got \(viewer.findResult.total)")
    }

    /// This searches the main frame only, and says so when there is a
    /// laid-out frame whose content it is therefore missing.
    @Test func admitsThatFramesAreNotSearched() async throws {
        let (window, viewer) = makeViewer()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await load(
            "<p>alpha</p><iframe srcdoc=\"<p>alpha</p>\"></iframe>", into: viewer))

        viewer.setFindQuery("alpha")
        #expect(await wait { viewer.findResult.note?.contains("frames not searched") == true },
                "no frame warning; note was \(String(describing: viewer.findResult.note))")
        // The frame's own "alpha" is not in the count.
        #expect(viewer.findResult.total == 1)
    }

    /// A page with no frames and nothing to declare says nothing — the note
    /// line must not become permanent chrome.
    @Test func saysNothingWhenThereIsNothingToDeclare() async throws {
        let (window, viewer) = makeViewer()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await load("<p>alpha</p>", into: viewer))

        viewer.setFindQuery("alpha")
        #expect(await wait { viewer.findResult.total == 1 })
        #expect(viewer.findResult.note == nil)
    }
}

/// The bundled script itself, checked the way the selection toolbar's is —
/// a missing resource must degrade to "Cmd-F does nothing", never a crash.
@MainActor
struct ViewerFindScriptTests {
    @Test func userScriptIsAvailableAndMainFrameOnly() throws {
        let script = try #require(
            ViewerView.findUserScript(), "find.js is missing from the bundle")
        #expect(script.source.contains("__ghozttyFind"))
        #expect(script.injectionTime == .atDocumentEnd)
        #expect(script.isForMainFrameOnly)
    }

    /// Every viewer carries it, whatever mode it started in: a file viewer can
    /// be navigated to a website, and a website pane to a file.
    @Test func everyViewerInjectsIt() {
        for location in ["https://example.invalid/page", "/tmp/nonexistent.md", "git-status:"] {
            let viewer = ViewerView(location: location)
            let scripts = viewer.webView.configuration.userContentController.userScripts
            #expect(
                scripts.contains { $0.source.contains("__ghozttyFind") },
                "no find script for \(location)")
        }
    }
}

/// Minimal first-responder-taking view standing in for a terminal split.
private final class FindFocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
