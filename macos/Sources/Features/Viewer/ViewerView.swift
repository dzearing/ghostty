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

    /// The location this viewer was FIRST opened with. Fixed for the pane's
    /// life — it is what the chrome bar's home button returns to.
    let homeLocation: String

    /// The location currently on display: an absolute file path or an
    /// http(s) URL. Follows the user as they navigate (address bar, links,
    /// back/forward), so `+list` and the session manifest report — and
    /// restore — what the pane is actually showing, not where it started.
    private(set) var location: String

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

    /// The mode of the page currently committed in the web view. Not fixed at
    /// init: typing a URL into a file viewer's address bar switches it to
    /// `.web`, and navigating Back over that boundary switches it home again
    /// (see `syncMode(toCommitted:)`).
    private(set) var mode: Mode

    /// The file the template page is showing, if any. Kept separately from
    /// `mode` because the web view's URL while a file is displayed is the
    /// template's `ghoztty-viewer://` address, not the file's — this is what
    /// lets Back cross from a website into the file view and land correctly.
    private var fileLocation: URL?

    /// A blank start page. The browser palette command opens here so the user
    /// can just type an address (the field shows its placeholder, not
    /// "about:blank").
    static let blankPage = "about:blank"

    private(set) var webView: WKWebView!
    private var schemeHandler: ViewerSchemeHandler?
    private var titleObservation: NSKeyValueObservation?
    private var pageLoaded = false
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var reloadDebounce: DispatchWorkItem?
    private var reloadNeedsRearm = false

    // Browser chrome state. The chrome bar (WebChromeBar, hosted in an
    // NSHostingView) peeks in when the mouse hovers the thin strip at the
    // very top of the pane and auto-hides after inactivity. While visible
    // it RESERVES its space: the web view's top is inset below the bar, so
    // the top of the page is never covered and stays clickable. It shows an
    // editable address field + nav controls in every mode.
    @Published private(set) var chromeVisible = false
    @Published private(set) var currentURL: String = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Bumped to ask the chrome bar to focus its address field; the bar
    /// watches this rather than exposing its @FocusState upward.
    @Published private(set) var addressFocusRequest = 0
    private var urlObservation: NSKeyValueObservation?
    private var backObservation: NSKeyValueObservation?
    private var forwardObservation: NSKeyValueObservation?
    private var chromeHideTimer: Timer?
    private var chromeHeld = false
    private var chromeMonitor: Any?
    private var chromeHost: NSHostingView<WebChromeBar>?
    /// Top inset of the web view: 0 with the bar hidden, the bar's height
    /// while it is visible (content starts below the bar, never under it).
    private var webViewTopConstraint: NSLayoutConstraint?

    /// The bar's top offset: -barHeight parks it just above the pane's top
    /// edge (clipped away); 0 is fully slid in. Animated for the slide.
    private var chromeTopConstraint: NSLayoutConstraint?

    // Table of contents. The page (viewer.js) extracts headings from the
    // rendered markdown and reports them — plus the section currently at the
    // top of the pane — over the `viewerTOC` script-message bridge; the card
    // itself is drawn natively (ViewerTOCPanel) so it is the same glass card
    // as the pane banner rather than a CSS lookalike.
    @Published private(set) var tocItems: [ViewerTOCItem] = []
    @Published private(set) var activeHeadingID: String?
    /// Narrow-layout panel state. Deliberately ephemeral: it is an overlay
    /// covering the document, so restoring a session with it open would hide
    /// the content the user actually asked to see.
    @Published private(set) var tocPanelOpen = false
    private var tocPanelHost: NSHostingView<ViewerTOCPanel>?
    private var tocPanelConstraints: [NSLayoutConstraint] = []
    /// Layer-backed wrapper around the panel's hosting view. The slide is a
    /// Core Animation transform on THIS layer: animating the panel's leading
    /// constraint instead re-runs Auto Layout every frame, and every one of
    /// those frames re-lays-out the SwiftUI list inside — which is CPU work
    /// per frame rather than compositing, and visibly stutters.
    private var tocPanelContainer: NSView?
    /// Set for the duration of a user-driven toggle so the slide animates —
    /// `layout()` reaches the same code every frame of a divider drag and
    /// must never start an animation.
    private var animatingTOCPanel = false
    /// Left gutter the page reserves for the TOC card, in CSS px. 0 unless
    /// the card is in gutter layout. Pushed to the page (not applied as a
    /// native inset) so the strip behind the card is the document's own
    /// background — see `pushTOCGutter()`.
    private(set) var tocGutterWidth: CGFloat = 0
    @Published private(set) var tocLayout: TOCLayout = .hidden
    private var tocPanelSignature: TOCPanelSignature?

    /// The size-dependent inputs of the mounted panel, so `layout()` can skip
    /// re-pushing an identical root view.
    private struct TOCPanelSignature: Equatable {
        let width: CGFloat
        let maxHeight: CGFloat
    }

    /// How the table of contents is presented, decided by pane width.
    enum TOCLayout {
        /// No TOC: not a markdown document, or fewer than two headings.
        case hidden
        /// Wide pane: a card in a left gutter, content inset beside it.
        case gutter
        /// Narrow pane: the card is an overlay, opened from the chrome bar.
        case compact
    }

    /// Script-message channel name for the TOC bridge.
    fileprivate static let tocMessageName = "viewerTOC"

    /// Pane width at or above which the TOC gets its own gutter. Below it
    /// the gutter would squeeze the document column too far to read.
    private static let tocGutterMinWidth: CGFloat = 720

    /// Card width, and the range the user may drag it to. One width serves
    /// both layouts (the compact overlay just clamps it to the pane), so
    /// there is a single number to reason about and to persist.
    private static let tocCardDefaultWidth: CGFloat = 240
    private static let tocCardMinWidth: CGFloat = 170
    private static let tocCardMaxWidth: CGFloat = 460

    /// The user's chosen card width. A chrome preference rather than a
    /// property of any one document, so it lives in defaults and applies to
    /// every viewer pane — the same way a sidebar width behaves in a document
    /// app, and unlike a split ratio, which is per-window by nature.
    private static let tocCardWidthDefaultsKey = "ViewerTOCCardWidth"

    private(set) var tocCardWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: tocCardWidthDefaultsKey)
        guard stored > 0 else { return tocCardDefaultWidth }
        return min(tocCardMaxWidth, max(tocCardMinWidth, CGFloat(stored)))
    }()

    /// Thin drag target straddling the card's right edge, mounted only in the
    /// gutter layout (the compact card floats over the document like a menu —
    /// there is no gutter for a resize to redistribute).
    private var tocResizeHandle: TOCResizeHandle?
    private var tocResizeHandleCenterX: NSLayoutConstraint?

    /// True when the displayed page is a website (network allowed) rather
    /// than a rendered local file.
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

    convenience init(location: String) {
        self.init(location: location, homeLocation: location)
    }

    /// `homeLocation` differs from `location` only when a viewer is restored
    /// from a session manifest after the user navigated away from where the
    /// pane was originally opened — home still points at the original.
    init(location: String, homeLocation: String) {
        self.location = location
        self.homeLocation = homeLocation
        self.mode = Self.mode(for: location)
        self.fileLocation = Self.mode(for: location).fileURL
        self.title = Self.initialTitle(for: location)
        super.init(frame: .zero)
        // The chrome bar parks above the top edge between reveals; without
        // clipping it would paint over whatever sits above this pane.
        clipsToBounds = true
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
            chromeTopConstraint = nil
            chromeVisible = false
            webViewTopConstraint?.constant = 0
            // Same reasoning as the chrome bar: these hosting views' root
            // views strongly reference us, so a detached pane sitting in the
            // undo stack would never let go of its web view.
            tocPanelContainer?.removeFromSuperview()
            tocPanelContainer = nil
            tocPanelHost = nil
            tocPanelConstraints = []
            tocPanelSignature = nil
            tocLayout = .hidden
            tocGutterWidth = 0
            if isWebURL {
                webView.pauseAllMediaPlayback()
            }
        } else {
            installEventMonitor()
        }
    }

    /// Classify a location as a website or a file to render. `about:` pages
    /// (the blank start page) count as web — they are navigable, not files.
    static func mode(for location: String) -> Mode {
        if location.hasPrefix("http://") || location.hasPrefix("https://")
            || location.hasPrefix("about:"),
           let url = URL(string: location) {
            return .web(url)
        }
        let url = URL(fileURLWithPath: Self.expandFilePath(location))
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mdwn":
            return .markdown(url)
        default:
            return .code(url)
        }
    }

    /// Strip a `file://` prefix and expand a leading `~` so paths typed into
    /// the address bar behave like paths typed into a shell.
    private static func expandFilePath(_ location: String) -> String {
        var path = location
        if path.hasPrefix("file://") {
            path = URL(string: path)?.path ?? String(path.dropFirst("file://".count))
        }
        return (path as NSString).expandingTildeInPath
    }

    private static func initialTitle(for location: String) -> String {
        switch mode(for: location) {
        case .web(let url): return url.host ?? location
        case .markdown(let url), .code(let url): return url.lastPathComponent
        }
    }

    // MARK: - Web view setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()

        // The scheme handler is registered for EVERY viewer, not just the
        // file-backed ones: a configuration is copied into the web view at
        // init and can never gain a handler afterwards, so a web viewer that
        // is later pointed at a local file (address bar, home button) would
        // otherwise have no way to serve the render template.
        //
        // Every viewer also shares the default (persistent) website data
        // store. File viewers used to get a `.nonPersistent()` one, but now
        // that any pane can browse, one store keeps sessions/logins
        // consistent no matter which kind of viewer the browsing started in.
        let handler = ViewerSchemeHandler(
            baseDirectory: fileLocation?.deletingLastPathComponent()
                ?? FileManager.default.homeDirectoryForCurrentUser)
        config.setURLSchemeHandler(handler, forURLScheme: ViewerSchemeHandler.scheme)
        self.schemeHandler = handler

        // TOC bridge. The proxy holds the viewer WEAKLY on purpose: the
        // content controller retains its handlers and the web view retains
        // the controller, so registering `self` directly would be a cycle
        // that keeps the whole pane (and its web view) alive forever.
        config.userContentController.add(
            ViewerTOCMessageProxy(viewer: self), name: Self.tocMessageName)
        self.currentURL = addressText(for: fileLocation ?? URL(string: location))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = isWebURL
        // Render with the host window's appearance (drives
        // prefers-color-scheme inside the page, switching live).
        webView.underPageBackgroundColor = .windowBackgroundColor
        addSubview(webView)
        let topConstraint = webView.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.webViewTopConstraint = topConstraint
        self.webView = webView

        // Observed for EVERY viewer, not just web ones: a file viewer becomes
        // navigable the moment the user types an address, and an observation
        // installed only for the starting mode would be dead by then.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            guard let self, let pageTitle = webView.title, !pageTitle.isEmpty else { return }
            DispatchQueue.main.async {
                // A file's name is its title; only the web supplies its own.
                guard self.isWebURL else { return }
                self.title = pageTitle
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            guard let self else { return }
            let url = webView.url
            DispatchQueue.main.async { self.currentURL = self.addressText(for: url) }
        }
        backObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            let value = webView.canGoBack
            DispatchQueue.main.async { self?.canGoBack = value }
        }
        forwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            let value = webView.canGoForward
            DispatchQueue.main.async { self?.canGoForward = value }
        }

        installEventMonitor()
    }

    // MARK: - Browser chrome (web mode)

    /// The pane-top strip (in points) that reveals the chrome bar on hover.
    /// Deliberately thin so ordinary interaction with the page never
    /// triggers the bar — only an intentional move to the very top edge.
    private static let chromeRevealHeight: CGFloat = 20

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reloadPage() { webView.reload() }

    /// Explicit on-demand reload (the `+reload` IPC command). Websites
    /// re-fetch from origin, bypassing caches — the point of an explicit
    /// reload is to pick up server-side changes. File modes re-render the
    /// file in place (scroll preserved) and re-arm the watcher in case an
    /// atomic-save event was missed. Either mode falls back to a full
    /// load when the initial page load never completed.
    func reloadContent() {
        switch mode {
        case .web:
            if webView.url == nil {
                load()
            } else {
                webView.reloadFromOrigin()
            }
        case .markdown, .code:
            if pageLoaded {
                startWatchingFile()
                renderFileContent()
            } else {
                load()
            }
        }
    }

    /// Navigate from the chrome URL field. Accepts anything a viewer can
    /// show — a website, or a local file path, which switches the pane back
    /// to rendering a file. Bare input is completed like a browser omnibox
    /// (see completeAddress).
    func navigate(to input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        openLocation(Self.isFilePath(trimmed) ? trimmed : Self.completeAddress(trimmed))
    }

    /// Return to the location this pane was opened with (the home button).
    func goHome() {
        openLocation(homeLocation)
    }

    /// A typed address that names a local file rather than a website: an
    /// explicit `file://`, or a path starting at root or at the home dir.
    /// (A bare word like "docs" is treated as a hostname, as in a browser.)
    static func isFilePath(_ input: String) -> Bool {
        input.hasPrefix("file://") || input.hasPrefix("/") || input.hasPrefix("~/")
    }

    /// Point this pane at a new location, switching between web and
    /// file-rendering mode as needed. The web view keeps its history, so
    /// Back still works across the switch.
    private func openLocation(_ newLocation: String) {
        let newMode = Self.mode(for: newLocation)
        switch newMode {
        case .web(let url):
            mode = newMode
            location = url.absoluteString
            currentURL = addressText(for: url)
            webView.allowsBackForwardNavigationGestures = true
            webView.load(URLRequest(url: url))
        case .markdown(let url), .code(let url):
            mode = newMode
            fileLocation = url
            location = url.path
            title = url.lastPathComponent
            currentURL = addressText(for: url)
            // Relative images in the new file resolve against ITS directory.
            schemeHandler?.baseDirectory = url.deletingLastPathComponent()
            webView.allowsBackForwardNavigationGestures = false
            pageLoaded = false
            startWatchingFile()
            load()
        }
    }

    /// What the address field should show for a committed web-view URL. The
    /// template page's `ghoztty-viewer://` address is an implementation
    /// detail — a file viewer shows the file's own `file://` URL — and the
    /// blank start page shows nothing at all, leaving the field's
    /// "Enter URL" placeholder visible to type into.
    private func addressText(for url: URL?) -> String {
        guard let url else { return "" }
        if url.scheme == ViewerSchemeHandler.scheme {
            return fileLocation?.absoluteString ?? ""
        }
        if url.absoluteString == Self.blankPage { return "" }
        return url.absoluteString
    }

    /// Reveal the chrome bar and put the caret in the address field. Used by
    /// the "Open Browser Pane" command, which opens a blank pane whose whole
    /// point is that the user types an address into it.
    func focusAddressBar() {
        holdChrome(true)
        addressFocusRequest += 1
        // Belt and braces: SwiftUI's @FocusState does not propagate reliably
        // inside an NSHostingView (the same reason chromeKeyboardFocused is
        // checked at the AppKit level), so claim the field directly once the
        // bar has mounted its content.
        DispatchQueue.main.async { [weak self] in
            guard let self, let chromeHost = self.chromeHost,
                  let field = Self.firstTextField(in: chromeHost) else { return }
            self.window?.makeFirstResponder(field)
        }
    }

    /// The address field inside the mounted chrome bar, if it has rendered.
    static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    /// Complete a typed address the way a browser omnibox would:
    /// - an explicit scheme passes through untouched ("http://cnn")
    /// - a scheme-less address gets https:// ("example.org" → https://example.org)
    /// - a single dotless word also gets .com ("cnn" → https://cnn.com,
    ///   "cnn:8080/x" → https://cnn.com:8080/x — port and path survive)
    /// - localhost and 127.0.0.1 get http:// and never .com (dev servers
    ///   are plain HTTP; https://localhost would just fail)
    static func completeAddress(_ input: String) -> String {
        guard !input.contains("://") else { return input }

        // Split into authority (host[:port]) and the trailing path/query.
        let slash = input.firstIndex(of: "/")
        var authority = slash.map { String(input[..<$0]) } ?? input
        let rest = slash.map { String(input[$0...]) } ?? ""

        var port = ""
        if let colon = authority.firstIndex(of: ":") {
            port = String(authority[colon...])
            authority = String(authority[..<colon])
        }

        let isLocal = authority.caseInsensitiveCompare("localhost") == .orderedSame
            || authority == "127.0.0.1"
        if !isLocal, !authority.isEmpty, !authority.contains("."),
           authority.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            authority += ".com"
        }
        return (isLocal ? "http://" : "https://") + authority + port + rest
    }

    /// The address field gained or lost keyboard focus.
    ///
    /// Browser convention is that clicking into the address bar selects the
    /// whole address, ready to be replaced. Selecting it the moment focus
    /// arrives does NOT survive: focus is granted on mouse-DOWN, and AppKit's
    /// field-editor click tracking then runs on to mouse-up, where it places
    /// a plain caret at the click point and wipes the selection out again.
    /// So the selection is applied once the click is FINISHED.
    func addressFieldFocusChanged(_ focused: Bool) {
        holdChrome(focused)
        guard focused else { return }
        selectAddressWhenClickCompletes()
    }

    /// Wait for the mouse button to come back up, then select the address.
    /// Polling the button state rather than watching for a mouse-up EVENT is
    /// deliberate: the field editor's drag-tracking loop consumes that event
    /// itself, so an event monitor may never see it.
    private func selectAddressWhenClickCompletes(attempt: Int = 0) {
        // Keyboard focus (the palette's blank browser pane) has no click in
        // flight and satisfies this on the first pass. The attempt cap stops
        // a held button from polling forever.
        guard NSEvent.pressedMouseButtons != 0, attempt < 100 else {
            selectEntireAddress()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.selectAddressWhenClickCompletes(attempt: attempt + 1)
        }
    }

    /// Select the whole address, unless the user dragged out a range of their
    /// own during the click — that selection was deliberate, so it stands.
    private func selectEntireAddress() {
        guard let chromeHost, let field = Self.firstTextField(in: chromeHost),
              let editor = field.currentEditor() ?? window?.firstResponder as? NSText
        else { return }
        guard editor.selectedRange.length == 0 else { return }
        editor.selectAll(nil)
    }

    /// True while the chrome bar must stay on screen regardless of hover:
    /// the compact TOC layout hosts the contents toggle there, and a control
    /// that slides away before you can reach it is not a control.
    private var chromeAlwaysVisible: Bool { tocLayout == .compact }

    /// Toggle the contents panel (the chrome bar's leading button).
    func toggleTOCPanel() {
        setTOCPanelOpen(!tocPanelOpen)
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
    /// the pane top reveals the chrome bar (all viewer modes).
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
    /// overlay) so it reliably sits above the WKWebView subview. The bar
    /// reserves its space rather than floating over the page: while visible,
    /// the web view's top is inset by the bar height, so top-of-page content
    /// is never covered and stays clickable.
    ///
    /// Reveal/hide is a SLIDE: the bar starts parked just above the pane's
    /// top edge (clipped away) and its top constraint animates to 0 while
    /// the web view's top inset animates to the bar height in the same
    /// group, so the bar visibly pushes the content down and retracts back
    /// up. Constraint animators re-run layout every frame — implicit
    /// animation does not animate constraint-driven layout reliably.
    private func setChromeVisible(_ requested: Bool) {
        // Single choke point for the pin: in the compact TOC layout the bar
        // carries the contents toggle, so nothing may hide it.
        let visible = requested || chromeAlwaysVisible
        chromeVisible = visible

        if visible, chromeHost == nil {
            let host = NSHostingView(rootView: WebChromeBar(viewerView: self))
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host, positioned: .above, relativeTo: webView)
            let top = host.topAnchor.constraint(
                equalTo: topAnchor, constant: -host.fittingSize.height)
            NSLayoutConstraint.activate([
                top,
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            chromeTopConstraint = top
            chromeHost = host
            // Realize the parked-above position now so the first slide
            // animates from offscreen instead of from a zero frame.
            layoutSubtreeIfNeeded()
        }

        guard let chromeHost else { return }
        if visible { chromeHost.isHidden = false }
        let barHeight = chromeHost.fittingSize.height
        let barTop: CGFloat = visible ? 0 : -barHeight
        let contentInset: CGFloat = visible ? barHeight : 0

        // Constraint animation only progresses while the window is actually
        // displayed; snap directly otherwise (hidden panes, tests).
        guard window?.isVisible == true else {
            chromeTopConstraint?.constant = barTop
            webViewTopConstraint?.constant = contentInset
            layoutSubtreeIfNeeded()
            if !visible { chromeHost.isHidden = true }
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            chromeTopConstraint?.animator().constant = barTop
            webViewTopConstraint?.animator().constant = contentInset
        } completionHandler: { [weak self] in
            if !visible, self?.chromeVisible == false {
                self?.chromeHost?.isHidden = true
            }
        }
    }

    // MARK: - Table of contents

    /// A heading list (or the section now at the top of the pane) arrived
    /// from the page.
    fileprivate func handleTOCMessage(_ body: Any) {
        guard let payload = body as? [String: Any],
              let type = payload["type"] as? String
        else { return }

        switch type {
        case "headings":
            let raw = (payload["items"] as? [[String: Any]] ?? [])
                .compactMap { item -> (id: String, text: String, level: Int)? in
                    guard let id = item["id"] as? String,
                          let text = item["text"] as? String,
                          let level = item["level"] as? Int
                    else { return nil }
                    return (id: id, text: text, level: level)
                }
            setTOCItems(ViewerTOCItem.list(from: raw))
        case "active":
            activeHeadingID = payload["id"] as? String
        default:
            break
        }
    }

    private func setTOCItems(_ items: [ViewerTOCItem]) {
        guard items != tocItems else { return }
        tocItems = items
        if items.isEmpty {
            activeHeadingID = nil
            tocPanelOpen = false
        }
        updateTOCLayout()
    }

    /// Scroll the page to a heading (a TOC row was clicked). The panel is an
    /// overlay in the narrow layout, so using it dismisses it.
    func scrollToHeading(id: String) {
        webView.evaluateJavaScript("window.__viewer.scrollToAnchor(\(Self.js(id)))")
        activeHeadingID = id
        if tocLayout == .compact { setTOCPanelOpen(false) }
    }

    func setTOCPanelOpen(_ open: Bool) {
        guard tocPanelOpen != open else { return }
        tocPanelOpen = open
        // Only a deliberate toggle animates. Layout passes reach the same
        // code and must stay silent.
        animatingTOCPanel = true
        updateTOCLayout()
        animatingTOCPanel = false
    }

    /// Mount the panel inside a layer-backed container, so the slide can be
    /// a transform on one layer rather than a relayout of the whole card.
    private func mountTOCPanel(_ panel: ViewerTOCPanel, parked: Bool, cardWidth: CGFloat) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true

        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        addSubview(container, positioned: .above, relativeTo: webView)
        tocPanelConstraints = [
            container.topAnchor.constraint(equalTo: webView.topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
        ]
        NSLayoutConstraint.activate(tocPanelConstraints)
        tocPanelContainer = container
        tocPanelHost = host

        if parked {
            // Realize the parked position before the first slide, so opening
            // animates in from off-edge instead of from nowhere.
            applyTOCPanelState(parked: true, cardWidth: cardWidth, animated: false)
        }
    }

    /// Slide + fade the compact panel in or out.
    ///
    /// Runs entirely on the compositor: the layer's contents are already
    /// rendered, so translating and fading it costs no layout and no SwiftUI
    /// work per frame. The panel's constraints never move.
    private func applyTOCPanelState(parked: Bool, cardWidth: CGFloat, animated: Bool) {
        guard let container = tocPanelContainer, let layer = container.layer else { return }

        let offset = parked ? -(cardWidth + GlassCard.outerMargin * 2) : 0
        let targetTransform = CATransform3DMakeTranslation(offset, 0, 0)
        let targetOpacity: Float = parked ? 0 : 1

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = targetTransform
            layer.opacity = targetOpacity
            CATransaction.commit()
            // A layer transform does not move the VIEW, and AppKit hit-tests
            // views by frame — a parked panel left visible would keep
            // swallowing clicks over the document it slid away from.
            container.isHidden = parked
            return
        }

        // Sliding in: unhide before animating, or there is nothing to see.
        container.isHidden = false

        // Start from what is on screen right now, so a toggle that interrupts
        // the opposite animation continues from there instead of jumping.
        let fromTransform = layer.presentation()?.transform ?? layer.transform
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak container] in
            guard let self, let container else { return }
            // Re-read the state: a fast double-toggle can land here after the
            // opposite animation has already started.
            container.isHidden = self.tocLayout == .compact && !self.tocPanelOpen
        }

        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = fromTransform
        move.toValue = targetTransform
        move.duration = 0.26
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = targetOpacity
        fade.duration = parked ? 0.16 : 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        layer.transform = targetTransform
        layer.opacity = targetOpacity
        layer.add(move, forKey: "toc-slide")
        layer.add(fade, forKey: "toc-fade")
        CATransaction.commit()
    }

    /// Which TOC presentation the pane's current width calls for.
    private var desiredTOCLayout: TOCLayout {
        guard !tocItems.isEmpty else { return .hidden }
        return bounds.width >= Self.tocGutterMinWidth ? .gutter : .compact
    }

    override func layout() {
        super.layout()
        // Panes are resized constantly by split-tree drags, so the gutter ⇄
        // compact switch has to ride layout rather than any one-shot setup.
        updateTOCLayout()
    }

    /// Mount, size, or tear down the TOC views for the current pane width,
    /// and tell the page how much gutter to reserve.
    private func updateTOCLayout() {
        // layout() can run before setupWebView has assigned the web view.
        guard webView != nil else { return }

        let layout = desiredTOCLayout
        if tocLayout != layout {
            tocLayout = layout
            // The compact layout puts the only control that opens the
            // contents panel in the chrome bar, so the bar has to stop
            // auto-hiding. Leaving compact hands it back to hover.
            if layout == .compact {
                setChromeVisible(true)
            } else {
                scheduleChromeHide()
            }
        }

        // The card hangs off the WEB VIEW's top, not the pane's: when the
        // chrome bar slides in it insets the web view, and the TOC has to
        // move down with the content instead of sliding under the bar.
        let available = webView.frame.height > 0 ? webView.frame.height : bounds.height
        let maxCardHeight = max(80, available - GlassCard.outerMargin * 2)
        let cardWidth = layout == .gutter
            ? tocCardWidth
            : min(tocCardWidth,
                  max(120, bounds.width - GlassCard.outerMargin * 2))

        // Mounted in both layouts. A closed compact panel is PARKED off the
        // left edge rather than unmounted: a view that is destroyed on close
        // has nothing to animate, so it could only ever pop.
        let showsPanel = layout != .hidden
        let parked = layout == .compact && !tocPanelOpen

        if showsPanel {
            let panel = ViewerTOCPanel(
                viewerView: self, width: cardWidth, maxHeight: maxCardHeight)
            let signature = TOCPanelSignature(width: cardWidth, maxHeight: maxCardHeight)
            if let host = tocPanelHost {
                // Only push a new root view when its inputs actually moved.
                // This runs from layout(), and re-assigning rootView marks
                // the hosting view dirty — doing that unconditionally would
                // re-enter layout every frame of a divider drag.
                if signature != tocPanelSignature {
                    tocPanelSignature = signature
                    host.rootView = panel
                }
            } else {
                tocPanelSignature = signature
                mountTOCPanel(panel, parked: parked, cardWidth: cardWidth)
            }
            applyTOCPanelState(
                parked: parked,
                cardWidth: cardWidth,
                animated: animatingTOCPanel && window?.isVisible == true)
        } else {
            tocPanelContainer?.removeFromSuperview()
            tocPanelContainer = nil
            tocPanelHost = nil
            tocPanelConstraints = []
            tocPanelSignature = nil
        }

        updateTOCResizeHandle(layout: layout, cardWidth: cardWidth)

        // Only the gutter reserves space; the compact panel floats over the
        // document the way a menu does.
        //
        // The gutter covers the card's LEFT margin plus the card — not a
        // margin on each side. The space between the card's right edge and
        // the text is the document's own left padding (see viewer.css, which
        // uses the same 12px on all four sides), so that gap is one number in
        // one place instead of a card margin and a page padding that have to
        // be added up to reason about.
        let gutter = layout == .gutter
            ? GlassCard.outerMargin + cardWidth
            : 0
        if gutter != tocGutterWidth {
            tocGutterWidth = gutter
            pushTOCGutter()
        }
    }

    /// Mount, move, or tear down the card's resize handle.
    ///
    /// The handle straddles the card's right edge rather than sitting inside
    /// it: a card edge is a 1pt rim, and a target you have to hit exactly is
    /// a target you miss. It is a sibling of the panel (not a subview of the
    /// SwiftUI hosting view) for the same reason the split divider is an
    /// AppKit view — the hosting view and the web view both out-hit-test a
    /// SwiftUI gesture area.
    private func updateTOCResizeHandle(layout: TOCLayout, cardWidth: CGFloat) {
        guard layout == .gutter, let container = tocPanelContainer else {
            tocResizeHandle?.removeFromSuperview()
            tocResizeHandle = nil
            tocResizeHandleCenterX = nil
            return
        }

        let handle: TOCResizeHandle
        if let existing = tocResizeHandle {
            handle = existing
        } else {
            handle = TOCResizeHandle()
            handle.translatesAutoresizingMaskIntoConstraints = false
            handle.onDrag = { [weak self] delta, startWidth in
                self?.setTOCCardWidth(startWidth + delta)
            }
            handle.widthAtDragStart = { [weak self] in
                self?.tocCardWidth ?? Self.tocCardDefaultWidth
            }
            handle.onDragEnded = { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(
                    Double(self.tocCardWidth), forKey: Self.tocCardWidthDefaultsKey)
            }
            addSubview(handle, positioned: .above, relativeTo: container)
            let centerX = handle.centerXAnchor.constraint(
                equalTo: container.leadingAnchor, constant: 0)
            NSLayoutConstraint.activate([
                centerX,
                handle.widthAnchor.constraint(equalToConstant: TOCResizeHandle.grabWidth),
                handle.topAnchor.constraint(
                    equalTo: container.topAnchor, constant: GlassCard.outerMargin),
                handle.bottomAnchor.constraint(
                    equalTo: container.bottomAnchor, constant: -GlassCard.outerMargin),
            ])
            tocResizeHandle = handle
            tocResizeHandleCenterX = centerX
        }

        let edge = GlassCard.outerMargin + cardWidth
        if tocResizeHandleCenterX?.constant != edge {
            tocResizeHandleCenterX?.constant = edge
        }
    }

    /// Apply a dragged card width, clamped to the allowed range and to what
    /// the pane can actually give the document beside it.
    func setTOCCardWidth(_ proposed: CGFloat) {
        // Never let the card starve the document: cap it so the text column
        // keeps at least the width the gutter layout is predicated on.
        let paneCap = max(
            Self.tocCardMinWidth,
            bounds.width - Self.tocGutterMinWidth / 2)
        let clamped = min(
            min(Self.tocCardMaxWidth, paneCap),
            max(Self.tocCardMinWidth, proposed))
        guard clamped != tocCardWidth else { return }
        tocCardWidth = clamped
        // The card, the handle, and the page's gutter all derive from this —
        // one layout pass moves all three together.
        updateTOCLayout()
    }

    /// Hand the gutter width to the page, which reserves it as padding on
    /// the document body.
    ///
    /// The card floats OVER the web view rather than beside it, and the page
    /// makes room for it. Insetting the web view natively looked equivalent
    /// but was not: the reserved strip then painted this view's background
    /// instead of the markdown page's, leaving a visible seam down the edge
    /// of the gutter in both light and dark.
    private func pushTOCGutter() {
        guard pageLoaded else { return }
        webView.evaluateJavaScript("window.__viewer.setGutter(\(tocGutterWidth))")
    }

    /// Drop the TOC entirely (leaving a file view, or tearing the pane down).
    private func clearTOC() {
        setTOCItems([])
        updateTOCLayout()
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
        case homeLocation
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let location = try container.decode(String.self, forKey: .location)
        // Absent in state written before the home button existed: such a
        // viewer had never navigated, so where it is IS its home.
        let home = try container.decodeIfPresent(String.self, forKey: .homeLocation)
        self.init(location: location, homeLocation: home ?? location)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(location, forKey: .location)
        try container.encode(homeLocation, forKey: .homeLocation)
    }
}

extension ViewerView.Mode {
    /// The file this mode renders, nil for a website.
    var fileURL: URL? {
        switch self {
        case .markdown(let url), .code(let url): return url
        case .web: return nil
        }
    }
}

// MARK: - WKNavigationDelegate

extension ViewerView: WKNavigationDelegate {
    /// Reconcile the pane's mode with whatever the web view actually
    /// committed. This is what makes Back/Forward work across a mode switch:
    /// a user who types a URL into a file viewer and then presses Back lands
    /// on the template page again, and the pane must go back to rendering
    /// the file rather than sitting in web mode over a blank template.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        syncMode(toCommitted: webView.url)
    }

    private func syncMode(toCommitted url: URL?) {
        guard let url else { return }
        if url.scheme == ViewerSchemeHandler.scheme {
            guard let fileLocation else { return }
            mode = Self.mode(for: fileLocation.path)
            location = fileLocation.path
            title = fileLocation.lastPathComponent
            webView.allowsBackForwardNavigationGestures = false
            pageLoaded = false
        } else if url.scheme == "http" || url.scheme == "https" || url.scheme == "about" {
            mode = .web(url)
            location = url.absoluteString
            webView.allowsBackForwardNavigationGestures = true
            // A website is not a rendered document: whatever headings the
            // template page last reported are gone with it. (Nothing will
            // arrive to clear them — the bridge only exists in our template.)
            clearTOC()
        }
        currentURL = addressText(for: url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if case .web = mode { return }
        pageLoaded = true
        renderFileContent()
        // A reload/renavigation resets the document, taking the body padding
        // the TOC gutter relies on with it.
        pushTOCGutter()
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

// MARK: - TOC script bridge

/// Receives `viewerTOC` messages from the page and forwards them to the
/// viewer.
///
/// A separate object purely to break a retain cycle: `WKUserContentController`
/// retains its message handlers and the web view retains the controller, so a
/// `ViewerView` registered as its own handler could never be deallocated.
private final class ViewerTOCMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var viewer: ViewerView?

    init(viewer: ViewerView) {
        self.viewer = viewer
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        viewer?.handleTOCMessage(message.body)
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
    var baseDirectory: URL

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
