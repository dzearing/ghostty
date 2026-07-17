import AppKit
import Combine
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
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
        }
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
