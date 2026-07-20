import AppKit
import Combine
import OSLog
import SwiftUI
import WebKit

/// A non-terminal pane content view that renders a markdown file, a text/code
/// file, or a website inside a WKWebView.
///
/// File modes are fully offline: the page template and renderer libraries are
/// bundled app resources served through a custom URL scheme
/// (`ghoztty-viewer://`), which also grants the page read access to the viewed
/// file's directory so relative images resolve. Websites load directly over
/// the network. View-only — no editing.
final class ViewerView: NSView, Codable, ObservableObject {
    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty",
        category: "Viewer")

    /// The viewed location: an absolute file path or an http(s) URL.
    let location: String

    /// Display title: the file's name, or the page title once known (web).
    @Published private(set) var title: String

    enum Mode {
        /// Markdown file rendered through the bundled markdown-it page.
        case markdown(URL)
        /// Plain text / code file rendered through the same page.
        case code(URL)
        /// A website; the web view navigates to it directly.
        case web(URL)
    }

    let mode: Mode

    private(set) var webView: WKWebView!
    private var schemeHandler: ViewerSchemeHandler?
    private var titleObservation: NSKeyValueObservation?
    private var pageLoaded = false
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var reloadDebounce: DispatchWorkItem?
    private var reloadNeedsRearm = false

    // Browser chrome state. The chrome bar is a SwiftUI overlay
    // (WebChromeBar) that appears when the mouse moves near the top of the
    // pane and auto-hides after inactivity so content keeps the space. It
    // shows an editable URL + nav controls for web, and a read-only file://
    // address for markdown/code files.
    @Published private(set) var chromeVisible = false
    @Published private(set) var currentURL: String = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    private var urlObservation: NSKeyValueObservation?
    private var backObservation: NSKeyValueObservation?
    private var forwardObservation: NSKeyValueObservation?
    private var chromeHideTimer: Timer?
    private var chromeHeld = false
    private var chromeMonitor: Any?
    private var chromeHost: NSHostingView<WebChromeBar>?

    /// True when location is a web URL (network allowed) rather than a file.
    var isWebURL: Bool {
        if case .web = mode { return true }
        return false
    }

    /// The file URL for file-backed modes, nil for websites.
    var fileURL: URL? {
        switch mode {
        case .markdown(let url), .code(let url): return url
        case .web: return nil
        }
    }

    init(location: String) {
        self.location = location
        self.mode = Self.mode(for: location)
        self.title = Self.initialTitle(for: location)
        super.init(frame: .zero)
        setupWebView()
        load()
        startWatchingFile()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        fileMonitor?.cancel()
        reloadDebounce?.cancel()
        chromeHideTimer?.invalidate()
        if let chromeMonitor { NSEvent.removeMonitor(chromeMonitor) }
    }

    /// Called when this pane leaves/joins the split tree (close, undo). A
    /// detached pane must go quiet: pause any media (the closed tree is
    /// retained by the undo stack, so deinit is NOT prompt) and tear down
    /// the chrome hosting view, whose rootView strongly references us —
    /// leaving it mounted is a retain cycle that would keep the web view
    /// alive (and audible) forever.
    func setDetached(_ detached: Bool) {
        if detached {
            removeEventMonitor()
            chromeHideTimer?.invalidate()
            chromeHost?.removeFromSuperview()
            chromeHost = nil
            chromeVisible = false
            if isWebURL {
                webView.pauseAllMediaPlayback()
            }
        } else {
            installEventMonitor()
        }
    }

    private static func mode(for location: String) -> Mode {
        if location.hasPrefix("http://") || location.hasPrefix("https://"),
           let url = URL(string: location) {
            return .web(url)
        }
        let url = URL(fileURLWithPath: location)
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mdwn":
            return .markdown(url)
        default:
            return .code(url)
        }
    }

    private static func initialTitle(for location: String) -> String {
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            return URL(string: location)?.host ?? location
        }
        return (location as NSString).lastPathComponent
    }

    // MARK: - Web view setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()

        switch mode {
        case .markdown(let url), .code(let url):
            // Offline page: bundled assets + the file's own directory are
            // served via the custom scheme; nothing persists to disk.
            config.websiteDataStore = .nonPersistent()
            let handler = ViewerSchemeHandler(
                baseDirectory: url.deletingLastPathComponent())
            config.setURLSchemeHandler(handler, forURLScheme: ViewerSchemeHandler.scheme)
            self.schemeHandler = handler
            // Surface the file:// URL in the address bar (read-only — a file
            // viewer never navigates, so this is set once and never changes).
            self.currentURL = url.absoluteString
        case .web:
            break
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = isWebURL
        // Render with the host window's appearance (drives
        // prefers-color-scheme inside the page, switching live).
        webView.underPageBackgroundColor = .windowBackgroundColor
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.webView = webView

        if case .web = mode {
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                guard let self, let pageTitle = webView.title, !pageTitle.isEmpty else { return }
                DispatchQueue.main.async { self.title = pageTitle }
            }
            currentURL = location
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                guard let self, let url = webView.url else { return }
                DispatchQueue.main.async { self.currentURL = url.absoluteString }
            }
            backObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                let value = webView.canGoBack
                DispatchQueue.main.async { self?.canGoBack = value }
            }
            forwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                let value = webView.canGoForward
                DispatchQueue.main.async { self?.canGoForward = value }
            }
        }

        installEventMonitor()
    }

    // MARK: - Browser chrome (web mode)

    /// The pane-top strip (in points) that reveals the chrome bar on hover.
    private static let chromeRevealHeight: CGFloat = 80

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reloadPage() { webView.reload() }

    /// Navigate from the chrome URL field. A bare host gets https://.
    func navigate(to input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate) else { return }
        webView.load(URLRequest(url: url))
    }

    /// The chrome bar calls this while hovered or while the URL field is
    /// focused so auto-hide pauses.
    func holdChrome(_ hold: Bool) {
        chromeHeld = hold
        if hold {
            chromeHideTimer?.invalidate()
            setChromeVisible(true)
        } else {
            scheduleChromeHide()
        }
    }

    /// True while keyboard focus (window first responder) is inside the
    /// chrome bar — the URL field's field editor or any of its buttons.
    /// Checked at hide time at the AppKit level because SwiftUI @FocusState
    /// doesn't propagate reliably inside an NSHostingView.
    private var chromeKeyboardFocused: Bool {
        guard let chromeHost, let responder = window?.firstResponder as? NSView else { return false }
        return responder === chromeHost || responder.isDescendant(of: chromeHost)
    }

    private func scheduleChromeHide(after delay: TimeInterval = 2.0) {
        chromeHideTimer?.invalidate()
        chromeHideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Never hide out from under the user: keep the bar while it is
            // hovered (chromeHeld) or holds keyboard focus; check again later.
            if self.chromeHeld || self.chromeKeyboardFocused {
                self.scheduleChromeHide(after: 1.0)
                return
            }
            self.setChromeVisible(false)
        }
    }

    /// WKWebView swallows normal mouse events, tracking areas over web
    /// content are unreliable, and SwiftUI's focus plumbing can keep first
    /// responder on the last terminal even after a click lands in web
    /// content. One app-local event monitor solves both: clicks inside the
    /// pane claim keyboard focus for the web view, and mouse movement near
    /// the pane top reveals the chrome bar (all viewer modes — the bar shows
    /// an editable URL for web and a read-only file:// address for files).
    private func installEventMonitor() {
        guard chromeMonitor == nil else { return }
        chromeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown: self.handleMouseDown(event)
            case .mouseMoved: self.handleChromeMouseMoved(event)
            default: break
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let chromeMonitor { NSEvent.removeMonitor(chromeMonitor) }
        chromeMonitor = nil
    }

    /// A click anywhere in this pane gives the web view keyboard focus so
    /// pane-level keybinds (Cmd+W, Cmd+D, nav) target THIS pane.
    private func handleMouseDown(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let responder = window.firstResponder as? NSView,
           responder === webView || responder.isDescendant(of: self) {
            return // already ours
        }
        window.makeFirstResponder(webView)
    }

    private func handleChromeMouseMoved(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            if chromeVisible, !chromeHeld { scheduleChromeHide(after: 0.5) }
            return
        }
        // Non-flipped view: the top strip is the high-y band.
        if point.y > bounds.height - Self.chromeRevealHeight {
            if !chromeVisible { setChromeVisible(true) }
            scheduleChromeHide()
        } else if chromeVisible, !chromeHeld {
            scheduleChromeHide(after: 0.7)
        }
    }

    /// Mount/animate the chrome bar hosting view. AppKit-level (not a SwiftUI
    /// overlay) so it reliably layers above the WKWebView subview.
    private func setChromeVisible(_ visible: Bool) {
        chromeVisible = visible

        if visible, chromeHost == nil {
            let host = NSHostingView(rootView: WebChromeBar(viewerView: self))
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host, positioned: .above, relativeTo: webView)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: topAnchor),
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            chromeHost = host
        }

        guard let chromeHost else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            chromeHost.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            if !visible, self?.chromeVisible == false {
                self?.chromeHost?.isHidden = true
            }
        }
        if visible { chromeHost.isHidden = false }
    }

    // MARK: - Loading

    private func load() {
        switch mode {
        case .markdown, .code:
            guard let pageURL = URL(string: "\(ViewerSchemeHandler.scheme)://page/viewer.html") else { return }
            webView.load(URLRequest(url: pageURL))
        case .web(let url):
            webView.load(URLRequest(url: url))
        }
    }

    /// (Re-)inject the file's content into the loaded page. Safe to call
    /// repeatedly — the page preserves scroll position on re-render.
    func renderFileContent() {
        guard pageLoaded, let fileURL else { return }

        let call: String
        do {
            let data = try Data(contentsOf: fileURL)
            guard let text = String(data: data, encoding: .utf8) else {
                call = "window.__viewer.setError(\(Self.js("Not a text file")), \(Self.js(fileURL.path)))"
                webView.evaluateJavaScript(call)
                return
            }
            switch mode {
            case .markdown:
                call = "window.__viewer.setMarkdown(\(Self.js(text)))"
            case .code:
                let lang = Self.highlightLanguage(forExtension: fileURL.pathExtension.lowercased())
                call = "window.__viewer.setCode(\(Self.js(text)), \(Self.js(lang ?? "")))"
            case .web:
                return
            }
        } catch {
            call = "window.__viewer.setError(\(Self.js("Cannot read file")), \(Self.js(fileURL.path)))"
        }
        webView.evaluateJavaScript(call)
    }

    // MARK: - Live reload

    /// Watch the viewed file for changes and re-render (scroll preserved by
    /// the page). Atomic-save editors replace the file via rename, so on
    /// delete/rename events the watcher re-opens the path once the debounce
    /// fires.
    private func startWatchingFile() {
        guard let fileURL else { return }
        fileMonitor?.cancel()
        fileMonitor = nil

        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.fileMonitor?.data ?? []
            let replaced = events.contains(.delete) || events.contains(.rename)
            self.scheduleReload(rearmWatcher: replaced)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileMonitor = source
    }

    private func scheduleReload(rearmWatcher: Bool) {
        // Sticky across the debounce window: a rename followed by a write
        // must still re-arm onto the new inode.
        reloadNeedsRearm = reloadNeedsRearm || rearmWatcher
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.reloadNeedsRearm {
                self.reloadNeedsRearm = false
                // The path was atomically replaced; track the new inode.
                self.startWatchingFile()
            }
            self.renderFileContent()
        }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Encode a string as a JS string literal (JSON is a subset of JS).
    private static func js(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: string,
            options: .fragmentsAllowed
        ), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    /// Map a file extension to a highlight.js language id (common bundle).
    /// Returns nil to render as plain text.
    private static func highlightLanguage(forExtension ext: String) -> String? {
        switch ext {
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx", "mts": return "typescript"
        case "py": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "cs": return "csharp"
        case "m", "mm": return "objectivec"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "swift": return "swift"
        case "php": return "php"
        case "pl", "pm": return "perl"
        case "lua": return "lua"
        case "r": return "r"
        case "sql": return "sql"
        case "sh", "bash", "zsh", "fish": return "bash"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml", "ini", "conf": return "ini"
        case "xml", "html", "htm", "svg", "plist": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "diff", "patch": return "diff"
        case "makefile", "mk": return "makefile"
        case "graphql", "gql": return "graphql"
        case "vb": return "vbnet"
        case "wat", "wasm": return "wasm"
        default: return nil
        }
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // Hand focus straight to the web view so scrolling/keyboard work.
        window?.makeFirstResponder(webView)
        return true
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case location
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(location: try container.decode(String.self, forKey: .location))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(location, forKey: .location)
    }
}

// MARK: - WKNavigationDelegate

extension ViewerView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if case .web = mode { return }
        pageLoaded = true
        renderFileContent()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Websites navigate freely within the pane.
        if case .web = mode {
            decisionHandler(.allow)
            return
        }

        // File modes: only user link clicks get special routing; the page's
        // own loads (template, assets, images) pass through.
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        handleFileModeLink(url)
    }

    /// Route a clicked link in a markdown/code viewer:
    /// - http(s) → default browser
    /// - relative/local markdown file → new viewer split next to this pane
    /// - other local files → open with the default app
    private func handleFileModeLink(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return
        }

        // Relative links render as ghoztty-viewer:// URLs; map them back to
        // a real file next to the viewed file. file:// links come through
        // as-is (markdown-it linkify or explicit file URLs).
        let fileURL: URL?
        if url.scheme == ViewerSchemeHandler.scheme {
            let relative = String(url.path.dropFirst())
            fileURL = schemeHandler?.resolveForNavigation(relative)
        } else if url.isFileURL {
            fileURL = url
        } else {
            fileURL = nil
        }
        guard let fileURL else { return }

        switch Self.mode(for: fileURL.path) {
        case .markdown:
            openViewerSplit(location: fileURL.path)
        default:
            NSWorkspace.shared.open(fileURL)
        }
    }

    /// Open another viewer as a split next to this pane.
    private func openViewerSplit(location: String) {
        guard let controller = window?.windowController as? BaseTerminalController,
              let myPane = controller.surfaceTree.first(where: { $0.viewerView === self })
        else { return }
        controller.newViewerSplit(
            atPane: myPane,
            direction: .right,
            viewer: ViewerView(location: location))
    }
}

// MARK: - Scheme handler

/// Serves the viewer page, its bundled assets, and files under the viewed
/// file's directory over the `ghoztty-viewer://` scheme. Everything is
/// local disk I/O — the handler never touches the network.
final class ViewerSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "ghoztty-viewer"

    /// The viewed file's directory; relative resources (e.g. images referenced
    /// by the markdown) resolve against this.
    private let baseDirectory: URL

    /// The bundled template/assets directory in app Resources.
    private static var resourcesDirectory: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("viewer", isDirectory: true)
    }

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Strip the leading "/" from e.g. ghoztty-viewer://page/vendor/x.js
        let relativePath = String(url.path.dropFirst())

        guard !relativePath.isEmpty, let fileURL = resolve(relativePath) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let response = URLResponse(
                url: url,
                mimeType: Self.mimeType(forExtension: fileURL.pathExtension.lowercased()),
                expectedContentLength: data.count,
                textEncodingName: nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous handler; nothing to cancel.
    }

    /// Resolve a clicked relative link against the viewed file's directory
    /// (never the bundle assets — navigation targets are user files).
    func resolveForNavigation(_ relativePath: String) -> URL? {
        let candidate = baseDirectory.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let absolute = URL(fileURLWithPath: "/" + relativePath)
        if FileManager.default.fileExists(atPath: absolute.path) { return absolute }
        return nil
    }

    /// Resolution order: bundled template assets first (viewer.html, vendor/…),
    /// then the viewed file's directory (relative images), then an absolute
    /// path as-is. Directory-escape via ".." is rejected for the relative
    /// candidates by resolving symlinks and prefix-checking.
    private func resolve(_ relativePath: String) -> URL? {
        if let resources = Self.resourcesDirectory {
            let candidate = resources.appendingPathComponent(relativePath)
            if Self.file(candidate, isUnder: resources) { return candidate }
        }

        let candidate = baseDirectory.appendingPathComponent(relativePath)
        if Self.file(candidate, isUnder: baseDirectory) { return candidate }

        // Absolute reference (e.g. ![](/Users/me/pic.png) in the markdown).
        let absolute = URL(fileURLWithPath: "/" + relativePath)
        if FileManager.default.fileExists(atPath: absolute.path) { return absolute }

        return nil
    }

    private static func file(_ candidate: URL, isUnder root: URL) -> Bool {
        let resolved = candidate.resolvingSymlinksInPath().path
        let rootResolved = root.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(rootResolved + "/") || resolved == rootResolved else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "txt", "md", "markdown": return "text/plain"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
