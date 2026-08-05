import AppKit
import Testing
import WebKit
@testable import Ghostty

/// Classification of what the user types into the address field. Pure logic —
/// no web view, no network.
@MainActor
struct ViewerAddressClassificationTests {
    @Test func absoluteAndTildePathsAreFiles() {
        #expect(ViewerView.isFilePath("/tmp/notes.md"))
        #expect(ViewerView.isFilePath("~/notes.md"))
        #expect(ViewerView.isFilePath("file:///tmp/notes.md"))
    }

    /// A bare word is a hostname, exactly as in a browser omnibox — otherwise
    /// "docs" would try to open a file instead of docs.com.
    @Test func bareWordsAndURLsAreNotFiles() {
        #expect(!ViewerView.isFilePath("example.com"))
        #expect(!ViewerView.isFilePath("docs"))
        #expect(!ViewerView.isFilePath("https://example.com/a"))
    }

    /// The blank start page is navigable chrome, not a file to render.
    @Test func blankPageIsWebMode() {
        guard case .web = ViewerView.mode(for: ViewerView.blankPage) else {
            Issue.record("about:blank should be web mode")
            return
        }
    }

    @Test func fileExtensionPicksRenderMode() {
        guard case .markdown = ViewerView.mode(for: "/tmp/a.md") else {
            Issue.record("expected markdown mode")
            return
        }
        guard case .code = ViewerView.mode(for: "/tmp/a.swift") else {
            Issue.record("expected code mode")
            return
        }
    }

    /// An HTML file is a page, not source to highlight — the whole point of
    /// the mode. `.htm` counts too, and case never does.
    @Test func htmlExtensionsRenderRatherThanHighlight() {
        for path in ["/tmp/a.html", "/tmp/a.htm", "/tmp/A.HTML"] {
            guard case .html = ViewerView.mode(for: path) else {
                Issue.record("expected html mode for \(path)")
                return
            }
        }
        // Neighbours that merely LOOK like markup stay code.
        guard case .code = ViewerView.mode(for: "/tmp/a.xml") else {
            Issue.record("expected code mode for .xml")
            return
        }
    }
}

/// End-to-end navigation against a real local HTTP server: the address field
/// must track wherever the page actually goes, the history buttons must
/// reflect real history, and a file viewer must be able to browse away and
/// come home again.
@MainActor
struct ViewerNavigationTests {
    // MARK: - Harness

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

    /// Wait for the pane to finish landing on `url`, then report where it
    /// actually is so a failure names the page it stopped on.
    ///
    /// Polling, not a fixed settle: a real WebKit navigation over loopback HTTP
    /// takes as long as it takes, and on a loaded machine that routinely
    /// outruns any budget short enough to be worth waiting for on an idle one.
    ///
    /// `currentURL` alone is NOT arrival — it is published on commit, while the
    /// load is still running. Navigating again at that point replaces the
    /// in-flight entry instead of pushing a new one, so the pane silently ends
    /// up with no history and `canGoBack` stays false. Waiting for the load to
    /// finish is what makes the next navigation a real history step.
    @discardableResult
    private func arrive(_ viewer: ViewerView, at url: String) async -> String {
        await poll { viewer.currentURL == url && !viewer.webView.isLoading }
        return viewer.currentURL
    }

    /// Serve pages over real HTTP so navigation and history are genuine.
    private func startServer() async throws -> (Process, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<html><head><title>One</title></head><body><h1>one</h1></body></html>"
            .write(to: dir.appendingPathComponent("one.html"), atomically: true, encoding: .utf8)
        try "<html><head><title>Two</title></head><body><h1>two</h1></body></html>"
            .write(to: dir.appendingPathComponent("two.html"), atomically: true, encoding: .utf8)
        // Rewrites its own address without loading a page (history.pushState).
        try "<html><body><script>history.pushState({},'','/pushed')</script></body></html>"
            .write(to: dir.appendingPathComponent("push.html"), atomically: true, encoding: .utf8)

        // Ask the kernel for the port instead of guessing one. These tests run
        // in parallel with each other, and two picking the same number means
        // the second python exits "address already in use" while its viewer is
        // handed a base URL served out of the FIRST test's directory — which
        // does not contain its pages.
        let port = try Self.reserveFreePort()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        proc.currentDirectoryURL = dir
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        // Wait for the socket to actually accept, rather than assuming a fixed
        // budget covers interpreter startup. This is the one wait in the file
        // that nothing downstream can rescue: a WebKit load against a port with
        // no listener is refused immediately and stays refused, so `arrive`'s
        // 15s poll would spin out against a dead connection instead of a slow
        // page. Per PollUntil's own rule, something you expect to BECOME true
        // belongs in `poll` — `settle` was the wrong tool here.
        let up = await poll(timeout: 30) {
            !proc.isRunning || Self.isListening(on: port)
        }
        guard up, proc.isRunning, Self.isListening(on: port) else {
            proc.terminate()
            throw ServerError.neverCameUp(port: port, exited: !proc.isRunning)
        }
        return (proc, "http://127.0.0.1:\(port)")
    }

    private enum ServerError: Error, CustomStringConvertible {
        case neverCameUp(port: Int, exited: Bool)

        var description: String {
            switch self {
            case let .neverCameUp(port, exited):
                return "python3 -m http.server never accepted on 127.0.0.1:\(port)"
                    + (exited ? " (the process exited)" : " (still running)")
            }
        }
    }

    /// Bind port 0, note what the kernel assigned, and hand the number on.
    ///
    /// There is a small window between the close here and python's bind, but
    /// the kernel does not hand the same ephemeral port to two callers in that
    /// window, which is strictly better than picking from a 1000-wide range and
    /// hoping.
    private static func reserveFreePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.neverCameUp(port: 0, exited: true) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ServerError.neverCameUp(port: 0, exited: true) }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { throw ServerError.neverCameUp(port: 0, exited: true) }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    /// Whether anything is accepting on `port`. A loopback connect either
    /// completes or is refused at once, so this is safe inside a `poll`
    /// condition — it never parks the run loop waiting on a network round trip.
    private static func isListening(on port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    /// A scaffolded static mock: `index.html` plus the sibling stylesheet,
    /// script, and image it references relatively. This shape is exactly what
    /// used to need `python3 -m http.server` to be viewable at all.
    private func makeStaticSite(heading: String = "hello") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-html-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.page(heading: heading)
            .write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "h1 { color: rgb(1, 2, 3); }"
            .write(to: dir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try "document.body.dataset.script = 'ran';"
            .write(to: dir.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
        // A real 1×1 PNG, so `naturalWidth` proves the image was fetched and
        // decoded rather than merely requested.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        try Data(base64Encoded: png)!.write(to: dir.appendingPathComponent("dot.png"))
        return dir.appendingPathComponent("index.html")
    }

    /// The page is deliberately taller than the pane so scroll position is a
    /// thing that can be lost.
    private static func page(heading: String) -> String {
        """
        <!doctype html><html><head><title>Mock</title>
        <link rel="stylesheet" href="style.css"></head>
        <body><h1 id="title">\(heading)</h1>
        <img id="pic" src="dot.png">
        <div style="height: 4000px"></div>
        <script src="app.js"></script></body></html>
        """
    }

    private func evaluate(_ script: String, in viewer: ViewerView) async -> String? {
        await withCheckedContinuation { continuation in
            viewer.webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    /// Wait for the page's DOM to say something. Alternates a completed
    /// `evaluateJavaScript` with a run-loop turn rather than putting the eval
    /// inside a `poll` condition — a continuation must never be in flight
    /// while `poll` turns the run loop (see PollUntil).
    @discardableResult
    private func pollDOM(
        _ script: String,
        in viewer: ViewerView,
        until match: (String) -> Bool
    ) async -> String? {
        for _ in 0..<150 {
            let value = await evaluate(script, in: viewer)
            if let value, match(value) { return value }
            await settle(0.1)
        }
        return await evaluate(script, in: viewer)
    }

    /// title | h1 colour | whether the script ran | the image's decoded width.
    private static let probe = """
    [document.querySelector('#title').textContent,
     getComputedStyle(document.querySelector('#title')).color,
     document.body.dataset.script || 'no',
     String(document.getElementById('pic').naturalWidth)].join('|')
    """

    private func makeMarkdownFile(named name: String = "home.md") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-nav-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try "# home\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Web mode

    /// The address field follows the page, and the history buttons enable
    /// only when there is history in that direction.
    @Test func addressAndHistoryTrackNavigation() async throws {
        let (server, base) = try await startServer()
        defer { server.terminate() }

        let (window, viewer) = makeViewer(location: "\(base)/one.html")
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await arrive(viewer, at: "\(base)/one.html") == "\(base)/one.html")
        #expect(!viewer.canGoBack)
        #expect(!viewer.canGoForward)

        viewer.navigate(to: "\(base)/two.html")
        await poll { viewer.currentURL == "\(base)/two.html" && !viewer.webView.isLoading && viewer.canGoBack }
        #expect(viewer.currentURL == "\(base)/two.html")
        #expect(viewer.canGoBack)
        #expect(!viewer.canGoForward)

        viewer.goBack()
        await poll { viewer.currentURL == "\(base)/one.html" && !viewer.webView.isLoading && viewer.canGoForward }
        #expect(viewer.currentURL == "\(base)/one.html")
        #expect(viewer.canGoForward)

        viewer.goForward()
        #expect(await arrive(viewer, at: "\(base)/two.html") == "\(base)/two.html")
    }

    /// A same-document navigation (pushState) changes no page, so only the
    /// URL moves — the field must still follow it.
    @Test func addressTracksSameDocumentNavigation() async throws {
        let (server, base) = try await startServer()
        defer { server.terminate() }

        let (window, viewer) = makeViewer(location: "\(base)/push.html")
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await arrive(viewer, at: "\(base)/pushed") == "\(base)/pushed")
    }

    /// The blank browser pane shows an empty field, so the "Enter URL"
    /// placeholder is what the user sees rather than "about:blank".
    @Test func blankBrowserPaneHasEmptyAddress() async throws {
        let (window, viewer) = makeViewer(location: ViewerView.blankPage)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        await settle(1.0)
        #expect(viewer.currentURL == "")
        #expect(viewer.isWebURL)
    }

    // MARK: - File mode is navigable

    /// A file viewer shows its own file:// address, not the render template's
    /// internal ghoztty-viewer:// URL.
    @Test func fileViewerShowsFileAddress() async throws {
        let file = try makeMarkdownFile()
        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        #expect(await arrive(viewer, at: file.absoluteString) == file.absoluteString)
        #expect(!viewer.isWebURL)
    }

    /// Typing a URL into a FILE viewer switches the pane to web mode, and
    /// Home brings it back to the file it was opened with.
    @Test func fileViewerNavigatesToWebAndHome() async throws {
        let (server, base) = try await startServer()
        defer { server.terminate() }
        let file = try makeMarkdownFile()

        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        await arrive(viewer, at: file.absoluteString)
        #expect(!viewer.isWebURL)

        viewer.navigate(to: "\(base)/one.html")
        await poll { viewer.isWebURL && viewer.currentURL == "\(base)/one.html" && !viewer.webView.isLoading }
        #expect(viewer.isWebURL)
        #expect(viewer.currentURL == "\(base)/one.html")
        #expect(viewer.location == "\(base)/one.html")

        viewer.goHome()
        await poll { !viewer.isWebURL && viewer.currentURL == file.absoluteString && !viewer.webView.isLoading }
        #expect(!viewer.isWebURL)
        #expect(viewer.currentURL == file.absoluteString)
        #expect(viewer.location == file.path)
    }

    /// Back from a website returns to the rendered file rather than stranding
    /// the pane in web mode over the bare template page.
    @Test func backFromWebReturnsToRenderedFile() async throws {
        let (server, base) = try await startServer()
        defer { server.terminate() }
        let file = try makeMarkdownFile()

        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        await arrive(viewer, at: file.absoluteString)

        viewer.navigate(to: "\(base)/one.html")
        await poll { viewer.currentURL == "\(base)/one.html" && !viewer.webView.isLoading && viewer.canGoBack }
        #expect(viewer.canGoBack)

        viewer.goBack()
        await poll { !viewer.isWebURL && viewer.currentURL == file.absoluteString && !viewer.webView.isLoading }
        #expect(!viewer.isWebURL)
        #expect(viewer.currentURL == file.absoluteString)
    }

    /// Home is where the pane STARTED, even after navigating on to a third
    /// place — it is not "the previous page".
    @Test func homeIsTheOriginalLocationNotThePreviousOne() async throws {
        let (server, base) = try await startServer()
        defer { server.terminate() }

        let (window, viewer) = makeViewer(location: "\(base)/one.html")
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        await arrive(viewer, at: "\(base)/one.html")

        viewer.navigate(to: "\(base)/two.html")
        await arrive(viewer, at: "\(base)/two.html")
        viewer.navigate(to: "\(base)/push.html")
        await arrive(viewer, at: "\(base)/pushed")

        viewer.goHome()
        #expect(await arrive(viewer, at: "\(base)/one.html") == "\(base)/one.html")
        #expect(viewer.homeLocation == "\(base)/one.html")
    }

    // MARK: - HTML files render as pages

    /// The file is loaded into the web view as itself: real DOM, and the
    /// stylesheet, script, and image sitting next to it all resolve. The pane
    /// still reports the FILE as its location, so `+list` and the session
    /// manifest are unchanged, and no table of contents lingers.
    @Test func htmlFileRendersWithItsRelativeAssets() async throws {
        let file = try makeStaticSite()
        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(await arrive(viewer, at: file.absoluteString) == file.absoluteString)
        #expect(!viewer.isWebURL)
        #expect(viewer.location == file.path)
        #expect(viewer.title == "index.html")

        let probed = await pollDOM(Self.probe, in: viewer) { $0.hasPrefix("hello|") }
        #expect(probed == "hello|rgb(1, 2, 3)|ran|1")

        // A page rendered by WebKit reports no headings, so the side panel has
        // nothing to show — and must not be showing a previous page's.
        #expect(viewer.tocItems.isEmpty)
        #expect(viewer.sidePanelLayout == .hidden)
    }

    /// Saving the file re-renders the page in place, and the reader keeps
    /// their place in it.
    @Test func htmlFileLiveReloadsOnSaveAndKeepsScroll() async throws {
        let file = try makeStaticSite()
        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        await arrive(viewer, at: file.absoluteString)
        await pollDOM(Self.probe, in: viewer) { $0.hasPrefix("hello|") }

        #expect(await evaluate("String(window.scrollTo(0, 500) || Math.round(window.scrollY))",
                               in: viewer) == "500")

        // `write(atomically:)` replaces the file via rename, which is what an
        // editor's save looks like — the watcher has to re-arm onto the new
        // inode, not just notice a write.
        try Self.page(heading: "edited")
            .write(to: file, atomically: true, encoding: .utf8)

        let probed = await pollDOM(Self.probe, in: viewer) { $0.hasPrefix("edited|") }
        #expect(probed == "edited|rgb(1, 2, 3)|ran|1")
        #expect(await evaluate("String(Math.round(window.scrollY))", in: viewer) == "500")
    }

    /// `+reload` / Cmd+R re-fetches the file, the same way it re-fetches a
    /// website from origin.
    @Test func reloadContentRefetchesTheHTMLFile() async throws {
        let file = try makeStaticSite()
        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        await arrive(viewer, at: file.absoluteString)
        await pollDOM(Self.probe, in: viewer) { $0.hasPrefix("hello|") }

        // Write in place with no rename, so the watcher's rearm path is not
        // what rescues this — the explicit reload has to do the work.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(Self.page(heading: "reloaded").utf8))
        try handle.close()

        viewer.reloadContent()
        let probed = await pollDOM(Self.probe, in: viewer) { $0.hasPrefix("reloaded|") }
        #expect(probed == "reloaded|rgb(1, 2, 3)|ran|1")
    }

    /// An HTML pane is navigable like any other: it can browse away to a real
    /// website, come Back to the rendered file, and Home to where it started.
    @Test func htmlPaneBrowsesAwayAndReturns() async throws {
        let (server, base) = try await startServer()
        defer { server.terminate() }
        let file = try makeStaticSite()

        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        await arrive(viewer, at: file.absoluteString)

        viewer.navigate(to: "\(base)/one.html")
        await poll { viewer.isWebURL && viewer.currentURL == "\(base)/one.html" && !viewer.webView.isLoading && viewer.canGoBack }
        #expect(viewer.isWebURL)
        #expect(viewer.location == "\(base)/one.html")

        viewer.goBack()
        await poll { !viewer.isWebURL && viewer.currentURL == file.absoluteString && !viewer.webView.isLoading }
        #expect(!viewer.isWebURL)
        #expect(viewer.location == file.path)
        #expect(await pollDOM(Self.probe, in: viewer) { $0.hasPrefix("hello|") } == "hello|rgb(1, 2, 3)|ran|1")

        viewer.navigate(to: "\(base)/two.html")
        await arrive(viewer, at: "\(base)/two.html")
        viewer.goHome()
        await poll { !viewer.isWebURL && viewer.currentURL == file.absoluteString && !viewer.webView.isLoading }
        #expect(viewer.location == file.path)
        #expect(viewer.homeLocation == file.path)
    }

    /// A markdown pane pointed at an HTML file switches to rendering it —
    /// and back again — without stranding either mode on the other's page.
    @Test func markdownPaneCanNavigateToAnHTMLFileAndBack() async throws {
        let markdown = try makeMarkdownFile()
        let html = try makeStaticSite()

        let (window, viewer) = makeViewer(location: markdown.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        await arrive(viewer, at: markdown.absoluteString)

        viewer.navigate(to: html.path)
        await poll { viewer.currentURL == html.absoluteString && !viewer.webView.isLoading }
        #expect(viewer.location == html.path)
        #expect(await pollDOM(Self.probe, in: viewer) { $0.hasPrefix("hello|") } == "hello|rgb(1, 2, 3)|ran|1")

        // Back must land on the TEMPLATE page still rendering the markdown —
        // the HTML file must not have overwritten what it was holding.
        viewer.goBack()
        await poll { viewer.currentURL == markdown.absoluteString && !viewer.webView.isLoading }
        #expect(viewer.location == markdown.path)
        #expect(await pollDOM("document.body.innerText", in: viewer) { $0.contains("home") } != nil)
    }

    /// The Quote/Copy toolbar reaches a rendered HTML file. It ships as a
    /// `WKUserScript` injected into every page, so it SHOULD — but "should"
    /// is how quoting silently missed websites before, so this asserts it on
    /// a page WebKit loaded itself rather than on the bundled template.
    @Test func selectionToolbarReachesARenderedHTMLFile() async throws {
        let file = try makeStaticSite()
        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        await arrive(viewer, at: file.absoluteString)
        await pollDOM(Self.probe, in: viewer) { $0.hasPrefix("hello|") }

        // Select the heading and end the drag, the way the toolbar is summoned.
        let select = """
        (function () {
          var range = document.createRange();
          range.selectNodeContents(document.getElementById('title'));
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
          document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
          return String(window.getSelection());
        })()
        """
        #expect(await evaluate(select, in: viewer) == "hello")

        // The toolbar lives in a shadow root so page CSS cannot touch it.
        let shown = await pollDOM(
            """
            (function () {
              var host = document.querySelector('[data-ghoztty-ui]');
              if (!host || !host.shadowRoot) return 'no-host';
              var bar = host.shadowRoot.querySelector('.bar');
              return bar && bar.classList.contains('on') ? 'shown' : 'hidden';
            })()
            """,
            in: viewer) { $0 == "shown" }
        #expect(shown == "shown")
    }

    /// A file that is not there renders the same in-page error card every
    /// other file mode gets, rather than WebKit's blank failure page.
    @Test func missingHTMLFileShowsAnErrorCard() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-html-\(UUID().uuidString)")
            .appendingPathComponent("gone.html")
        let (window, viewer) = makeViewer(location: file.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        let text = await pollDOM("document.body.innerText", in: viewer) {
            $0.contains("Cannot read file")
        }
        #expect(text?.contains("Cannot read file") == true)
    }

    /// A viewer restored from a manifest keeps its original home even though
    /// it reopens at wherever the user had navigated to.
    @Test func restoredViewerKeepsOriginalHome() async throws {
        let file = try makeMarkdownFile()
        let viewer = ViewerView(location: "https://example.invalid/away", homeLocation: file.path)
        #expect(viewer.homeLocation == file.path)
        #expect(viewer.location == "https://example.invalid/away")
    }
}
