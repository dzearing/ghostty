import AppKit
import Combine
import OSLog
import SwiftUI
import WebKit

/// A non-terminal pane content view that renders a markdown file, a text/code
/// file, an HTML file, or a website inside a WKWebView.
///
/// Template-backed modes (markdown, code, diff) are fully offline: the page
/// template and renderer libraries are bundled app resources served through a
/// custom URL scheme (`ghoztty-viewer://`), which also grants the page read
/// access to the viewed file's directory so relative images resolve. An HTML
/// file skips the template entirely — the web view loads the file itself, so
/// the page is the document. Websites load directly over the network.
/// View-only — no editing.
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
    private(set) var location: String {
        didSet {
            guard location != oldValue else { return }
            refreshWorktree()
        }
    }

    /// The directory this pane was OPENED from: `--working-directory` at
    /// `+split --view=` / `+new-window --view=` time, else the caller's cwd.
    /// Fixed for the pane's life and persisted in the session manifest.
    ///
    /// This is the fallback leg of worktree provenance: a pane showing a
    /// REMOTE site, a blank page, or a loopback port with nothing listening
    /// has no content-derived directory of its own, and without this the
    /// feedback affordance would simply vanish for those panes.
    let originDirectory: String?

    /// The git worktree the displayed content belongs to, or nil if it
    /// belongs to none (in which case no feedback affordance appears).
    /// Re-resolved off the main thread on every navigation.
    @Published private(set) var worktree: ViewerWorktree?

    /// Guards against a slow resolution for a location the pane has since
    /// navigated away from overwriting the current answer.
    private var worktreeGeneration = 0

    /// Display title: the file's name, or the page title once known (web).
    @Published private(set) var title: String

    enum Mode {
        /// Markdown file rendered through the bundled markdown-it page.
        case markdown(URL)
        /// Plain text / code file rendered through the same page.
        case code(URL)
        /// A git diff, rendered through the same page (see ViewerDiffSpec).
        case diff(ViewerDiffSpec)
        /// A local HTML file, loaded straight into the web view as a live
        /// page. There is no template and nothing to inject: the file IS the
        /// document, so its own CSS/JS/images run exactly as they would if it
        /// were served over http — which is the point, since hosting a static
        /// file behind `python3 -m http.server` was the only way to see it
        /// before.
        case html(URL)
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
    ///
    /// An HTML file is deliberately NOT recorded here: the web view loads it
    /// directly, so its own URL already names it, and overwriting this would
    /// lose the document the template still holds behind it in history.
    private var fileLocation: URL?

    /// The diff the template page is showing, if any. The other half of
    /// `fileLocation`: both name what the TEMPLATE page is rendering, and
    /// exactly one of them is set at a time, so Back out of a website lands
    /// on whichever kind of content the pane was showing before it.
    private var diffSpec: ViewerDiffSpec?

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
    /// Bumped to ask the chrome bar to throw away a half-typed address and
    /// show `currentURL` again (Escape). Same one-way channel as
    /// `addressFocusRequest`.
    @Published private(set) var addressRevertRequest = 0
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

    // The side panel: one card in the pane's left gutter, whose CONTENTS
    // depend on what the pane is showing — a markdown document's table of
    // contents, or a diff's changed-file tree. Everything below is shared by
    // both (see ViewerSidePanel): the card, the gutter/overlay switch, the
    // drag-to-resize handle, and the width preference.
    //
    // The TOC's data comes from the page: viewer.js extracts headings from the
    // rendered markdown and reports them — plus the section currently at the
    // top of the pane — over the `viewerTOC` script-message bridge. The card
    // itself is drawn natively so it is the same glass card as the pane banner
    // rather than a CSS lookalike. The file tree's data comes from git (see
    // "Git diff" below).
    @Published private(set) var tocItems: [ViewerTOCItem] = []
    @Published private(set) var activeHeadingID: String?
    /// Narrow-layout panel state. Deliberately ephemeral: it is an overlay
    /// covering the document, so restoring a session with it open would hide
    /// the content the user actually asked to see.
    @Published private(set) var sidePanelOpen = false
    private var sidePanelHost: NSHostingView<ViewerSidePanel>?
    private var sidePanelConstraints: [NSLayoutConstraint] = []
    /// Layer-backed wrapper around the panel's hosting view. The slide is a
    /// Core Animation transform on THIS layer: animating the panel's leading
    /// constraint instead re-runs Auto Layout every frame, and every one of
    /// those frames re-lays-out the SwiftUI list inside — which is CPU work
    /// per frame rather than compositing, and visibly stutters.
    private var sidePanelContainer: NSView?
    /// Set for the duration of a user-driven toggle so the slide animates —
    /// `layout()` reaches the same code every frame of a divider drag and
    /// must never start an animation.
    private var animatingSidePanel = false
    /// Left gutter the page reserves for the TOC card, in CSS px. 0 unless
    /// the card is in gutter layout. Pushed to the page (not applied as a
    /// native inset) so the strip behind the card is the document's own
    /// background — see `pushSidePanelGutter()`.
    private(set) var sidePanelGutterWidth: CGFloat = 0
    @Published private(set) var sidePanelLayout: SidePanelLayout = .hidden
    private var sidePanelSignature: SidePanelSignature?

    /// The size-dependent inputs of the mounted panel, so `layout()` can skip
    /// re-pushing an identical root view.
    private struct SidePanelSignature: Equatable {
        let width: CGFloat
        let maxHeight: CGFloat
    }

    /// How the side panel is presented, decided by pane width.
    enum SidePanelLayout {
        /// No panel: nothing to list — not a markdown document (or fewer than
        /// two headings), and not a diff with files in it.
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
    private static let sidePanelGutterMinWidth: CGFloat = 720

    /// Card width, and the range the user may drag it to. One width serves
    /// both layouts (the compact overlay just clamps it to the pane), so
    /// there is a single number to reason about and to persist.
    private static let sidePanelDefaultWidth: CGFloat = 240
    private static let sidePanelMinWidth: CGFloat = 170
    private static let sidePanelMaxWidth: CGFloat = 460

    /// The user's chosen card width. A chrome preference rather than a
    /// property of any one document, so it lives in defaults and applies to
    /// every viewer pane — the same way a sidebar width behaves in a document
    /// app, and unlike a split ratio, which is per-window by nature.
    ///
    /// The KEY still says "TOC" from when the card only ever held a table of
    /// contents. It stays that way on purpose: renaming it would silently
    /// reset the width every existing user has already dragged to.
    private static let sidePanelWidthDefaultsKey = "ViewerTOCCardWidth"

    private(set) var sidePanelWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: sidePanelWidthDefaultsKey)
        guard stored > 0 else { return sidePanelDefaultWidth }
        return min(sidePanelMaxWidth, max(sidePanelMinWidth, CGFloat(stored)))
    }()

    /// Thin drag target straddling the card's right edge, mounted only in the
    /// gutter layout (the compact card floats over the document like a menu —
    /// there is no gutter for a resize to redistribute).
    private var sidePanelResizeHandle: SidePanelResizeHandle?
    private var sidePanelResizeHandleCenterX: NSLayoutConstraint?

    /// True when the displayed page is a website (network allowed) rather
    /// than a rendered local file.
    var isWebURL: Bool {
        if case .web = mode { return true }
        return false
    }

    /// True while the web view is showing a page it loaded itself — a website
    /// or a local HTML file — rather than our render template. Such a page
    /// owns its own navigation, history, and media, so the swipe gestures and
    /// the media pause apply to both.
    var isLivePage: Bool {
        switch mode {
        case .web, .html: return true
        case .markdown, .code, .diff: return false
        }
    }

    /// True while the bundled template page is what the web view is actually
    /// displaying. Derived from the committed URL rather than tracked, so it
    /// stays right across Back/Forward, which move between the template and
    /// directly-loaded pages without going through `openLocation`.
    private var showingTemplatePage: Bool {
        webView?.url?.scheme == ViewerSchemeHandler.scheme
    }

    /// True while this pane is rendering a git diff. Drives which side panel
    /// the card shows, which controls the nav bar carries, and whether the
    /// bar may auto-hide.
    var isDiffMode: Bool {
        if case .diff = mode { return true }
        return false
    }

    /// The file URL for file-backed modes, nil for websites and diffs.
    var fileURL: URL? {
        switch mode {
        case .markdown(let url), .code(let url), .html(let url): return url
        case .web, .diff: return nil
        }
    }

    convenience init(location: String, originDirectory: String? = nil) {
        self.init(
            location: location,
            homeLocation: location,
            originDirectory: originDirectory)
    }

    /// `homeLocation` differs from `location` only when a viewer is restored
    /// from a session manifest after the user navigated away from where the
    /// pane was originally opened — home still points at the original.
    ///
    /// `adoptedWebView` is set only for a popup (see `init(adopting:…)`): the
    /// viewer wraps a web view WebKit already built instead of creating its
    /// own, and must not load anything itself.
    init(
        location: String,
        homeLocation: String,
        originDirectory: String? = nil,
        adoptedWebView: WKWebView? = nil
    ) {
        self.location = location
        self.homeLocation = homeLocation
        self.originDirectory = originDirectory
        let mode = Self.mode(for: location)
        self.mode = mode
        self.fileLocation = mode.templateFileURL
        self.diffSpec = mode.diffSpec
        self.title = Self.initialTitle(for: location)
        super.init(frame: .zero)
        // The chrome bar parks above the top edge between reveals; without
        // clipping it would paint over whatever sits above this pane.
        clipsToBounds = true
        setupWebView(adopting: adoptedWebView)
        // A popup adopts a web view WebKit is already driving (see
        // `createWebViewWith`): loading our own request would fight that
        // navigation and break the opener↔popup link, and there is no file to
        // watch. Everything else — chrome, observations, worktree — is shared.
        if adoptedWebView == nil {
            load()
            startWatchingFile()
            // Ask git NOW rather than waiting for the page: the file tree is
            // native and owes the web view nothing, so the panel fills in
            // while the template is still loading. Whatever the page missed is
            // pushed to it on `didFinish`.
            if isDiffMode { refreshDiff(preservingSelection: false) }
        }
        refreshWorktree()
    }

    /// Wrap a web view WebKit created for a popup (`window.open()` /
    /// `target="_blank"`) so it becomes its own viewer. WebKit itself drives
    /// the navigation on that web view, so this viewer must never load
    /// anything — reusing WebKit's own instance is what keeps the
    /// opener↔popup relationship intact so `window.close()` works.
    convenience init(adopting webView: WKWebView, url: URL?, originDirectory: String?) {
        // Popups are always web content; a missing URL (a bare `window.open()`)
        // is the blank page the script goes on to write into.
        let location = url?.absoluteString ?? Self.blankPage
        self.init(
            location: location,
            homeLocation: location,
            originDirectory: originDirectory,
            adoptedWebView: webView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        fileMonitor?.cancel()
        reloadDebounce?.cancel()
        chromeHideTimer?.invalidate()
        diffRefreshTimer?.invalidate()
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
            // Same retain-cycle reasoning as the chrome bar. The composer's
            // CONTENT is safe: it lives in `feedbackModel`, which this view
            // owns, so an undo that re-attaches the pane brings the
            // half-written report back with it.
            feedbackCloseTimer?.invalidate()
            feedbackHost?.removeFromSuperview()
            feedbackHost = nil
            feedbackTopConstraint = nil
            feedbackOpen = false
            // The bar is gone; a re-attach re-mounts and re-measures it. Keep
            // `feedbackDraftStem` so an undo restores the same draft folder.
            feedbackBarHeight = 0
            chromeAnimating = false
            webViewTopConstraint?.constant = 0
            // Same reasoning as the chrome bar: these hosting views' root
            // views strongly reference us, so a detached pane sitting in the
            // undo stack would never let go of its web view.
            sidePanelContainer?.removeFromSuperview()
            sidePanelContainer = nil
            sidePanelHost = nil
            sidePanelConstraints = []
            sidePanelSignature = nil
            sidePanelLayout = .hidden
            sidePanelGutterWidth = 0
            // A detached diff pane must stop polling git. The listing itself
            // is kept, so an undo re-attaches a pane that is already populated
            // and simply resumes refreshing.
            stopWatchingDiff()
            if isLivePage {
                webView.pauseAllMediaPlayback()
            }
        } else {
            installEventMonitor()
            startWatchingDiff()
        }
    }

    /// The bundled selection-toolbar user script, or nil if the resource is
    /// missing (a broken bundle degrades to "no quoting", never a crash).
    ///
    /// Main frame only: the toolbar positions itself in viewport coordinates,
    /// which a subframe's own coordinate space would not match.
    static func selectionUserScript() -> WKUserScript? {
        userScript(named: "selection", degradesTo: "quoting", forMainFrameOnly: true)
    }

    /// The bundled link-context-menu user script, or nil if the resource is
    /// missing (a broken bundle degrades to WebKit's own menu, never a crash).
    ///
    /// ALL frames, unlike the selection toolbar: this script reports a click
    /// and the menu is drawn natively at the pointer, so a subframe's own
    /// coordinate space is irrelevant and a link inside an iframe gets the
    /// same menu as one outside it.
    static func linkMenuUserScript() -> WKUserScript? {
        userScript(named: "links", degradesTo: "the link menu", forMainFrameOnly: false)
    }

    private static func userScript(
        named name: String,
        degradesTo feature: String,
        forMainFrameOnly: Bool
    ) -> WKUserScript? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "js",
            subdirectory: "ghostty/viewer"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            logger.warning("\(name).js missing from bundle; \(feature) disabled")
            return nil
        }
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: forMainFrameOnly)
    }

    /// Classify a location as a diff, a website, or a file to render.
    /// `about:` pages (the blank start page) count as web — they are
    /// navigable, not files.
    ///
    /// The diff schemes come FIRST: `git-status:` and `git-diff:<revspec>`
    /// carry a colon, and every other branch here would happily read one of
    /// them as a relative file path.
    static func mode(for location: String) -> Mode {
        if let spec = ViewerDiffSpec.parse(location) {
            return .diff(spec)
        }
        if location.hasPrefix("http://") || location.hasPrefix("https://")
            || location.hasPrefix("about:"),
           let url = URL(string: location) {
            return .web(url)
        }
        let url = URL(fileURLWithPath: Self.expandFilePath(location))
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mdwn":
            return .markdown(url)
        case "html", "htm":
            return .html(url)
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

    /// A file viewer is titled by its file, INCLUDING a rendered HTML page:
    /// the pane names the thing on disk the user asked for, the same way every
    /// other `--view=<path>` pane does. Only a website supplies its own title.
    private static func initialTitle(for location: String) -> String {
        switch mode(for: location) {
        case .web(let url): return url.host ?? location
        case .markdown(let url), .code(let url), .html(let url): return url.lastPathComponent
        case .diff(let spec): return spec.title
        }
    }

    // MARK: - Web view setup

    private func setupWebView(adopting adopted: WKWebView? = nil) {
        self.currentURL = diffSpec?.location
            ?? addressText(for: fileLocation ?? URL(string: location))

        let webView: WKWebView
        if let adopted {
            // Popup path: WebKit already built this web view from the
            // configuration it handed us in `createWebViewWith`. We reuse that
            // exact instance and never rebuild its configuration — that is what
            // preserves the opener↔popup relationship (and thus
            // `window.close()`). A popup is web content, so it needs no file
            // scheme handler of its own; re-registering one on the inherited
            // configuration would in fact throw.
            webView = adopted
        } else {
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

            // Selection toolbar (Quote / Copy), injected into EVERY page.
            //
            // It cannot ship inside viewer.js: that is a <script src> in
            // viewer.html, so it only ever runs on the bundled template page —
            // which is why quoting used to work on markdown and code but never on
            // an actual website. As a user script it runs in the template AND in
            // arbitrary web content, which is where quoting a dev server's UI
            // matters most.
            if let script = Self.selectionUserScript() {
                config.userContentController.addUserScript(script)
            }

            // Link context menu, injected into every page for the same reason.
            // It only decides whether a right-click landed on a link Ghoztty
            // has actions for and suppresses WebKit's menu when it did; the
            // menu itself is native (see `presentLinkMenu`). A right-click on
            // anything else — page background, an image, selected text, a
            // `mailto:` — still gets WebKit's own menu, unchanged.
            if let script = Self.linkMenuUserScript() {
                config.userContentController.addUserScript(script)
            }

            webView = WKWebView(frame: .zero, configuration: config)
        }

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        // A UI delegate on EVERY viewer is what makes `window.open()` /
        // `target="_blank"` do anything at all (without one WebKit silently
        // drops them), and it lets a popup itself spawn further popups. Weak,
        // like `navigationDelegate`, so assigning `self` is not a retain cycle.
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = isLivePage
        // Trackpad pinch magnifies the pane (native pixel zoom, like Safari's
        // two-finger pinch), for every viewer kind — web, markdown, and code all
        // render in this one web view. This is independent of keyboard page zoom
        // (Cmd+/−/0, see performKeyEquivalent) and is ephemeral: WebKit tracks
        // the magnification itself and we do not persist it, matching Safari.
        webView.allowsMagnification = true
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
        case .html:
            // Re-arm the watcher like the other file modes, then re-fetch the
            // page from disk. `reloadFromOrigin` rather than `reload` because
            // an explicit reload is also how you pick up an edited sibling
            // stylesheet or script — the watcher only sees the HTML file
            // itself, and those subresources sit in WebKit's memory cache.
            startWatchingFile()
            if pageLoaded, !showingTemplatePage {
                webView.reloadFromOrigin()
            } else {
                load()
            }
        case .diff:
            // Re-runs git, so an explicit reload picks up commits, staging,
            // and edits made since the pane was opened. The selected file and
            // scroll position survive it (see refreshDiff).
            if pageLoaded {
                refreshDiff(preservingSelection: true)
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
        // A diff spec is neither a path nor a hostname: without this, omnibox
        // completion would turn `git-diff:main...HEAD` into an https:// URL.
        if ViewerDiffSpec.isDiffLocation(trimmed) {
            openLocation(trimmed)
        } else {
            openLocation(Self.isFilePath(trimmed) ? trimmed : Self.completeAddress(trimmed))
        }
        // Submitting an address hands keyboard focus to the page body, the way a
        // browser omnibox does: you can immediately scroll/interact, and — just
        // as important — the address field genuinely resigns first responder, so
        // a later click back into it registers as a real focus change and
        // re-selects the address. SwiftUI's `@FocusState = false` does not
        // reliably move the AppKit first responder off the field editor here (a
        // recurring NSHostingView limitation elsewhere in this file), so move it
        // explicitly.
        window?.makeFirstResponder(webView)
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
            stopWatchingDiff()
        case .html(let url):
            // Structurally a website — the web view loads it and owns its
            // navigation — so `fileLocation`/`diffSpec` are left alone and
            // Back still lands on whatever the template was rendering. What it
            // adds over `.web` is the file watcher, since it has a file.
            mode = newMode
            location = url.path
            title = url.lastPathComponent
            currentURL = addressText(for: url)
            webView.allowsBackForwardNavigationGestures = true
            pageLoaded = false
            stopWatchingDiff()
            startWatchingFile()
            load()
        case .markdown(let url), .code(let url):
            mode = newMode
            fileLocation = url
            diffSpec = nil
            location = url.path
            title = url.lastPathComponent
            currentURL = addressText(for: url)
            // Relative images in the new file resolve against ITS directory.
            schemeHandler?.baseDirectory = url.deletingLastPathComponent()
            webView.allowsBackForwardNavigationGestures = false
            pageLoaded = false
            stopWatchingDiff()
            clearDiffState()
            startWatchingFile()
            load()
        case .diff(let spec):
            mode = newMode
            diffSpec = spec
            fileLocation = nil
            location = spec.location
            title = spec.title
            currentURL = spec.location
            webView.allowsBackForwardNavigationGestures = false
            pageLoaded = false
            fileMonitor?.cancel()
            fileMonitor = nil
            clearTOC()
            clearDiffState()
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
        if Self.sameFile(url, as: fileURL), let known = fileURL {
            // A directly-loaded HTML file: show the path the pane was opened
            // with rather than WebKit's symlink-resolved rewrite of it, so the
            // field matches `location` and what the user typed.
            return known.absoluteString
        }
        if url.scheme == ViewerSchemeHandler.scheme {
            // The template renders either a file or a diff; the address shows
            // whichever it currently holds, in the form the user can retype.
            if let diffSpec { return diffSpec.location }
            return fileLocation?.absoluteString ?? ""
        }
        if url.absoluteString == Self.blankPage { return "" }
        return url.absoluteString
    }

    /// Reveal the chrome bar and put the caret in the address field with the
    /// whole address selected — the keyboard equivalent of clicking into it.
    /// Used by the "Open Browser Pane" command, which opens a blank pane whose
    /// whole point is that the user types an address into it, and by the
    /// pane-scoped Cmd-D chord (see `paneChord`).
    ///
    /// Returns false when this pane has no address field to focus — it is not
    /// in a window, so no chrome bar can ever mount — so a keybinding can fall
    /// through to its global action instead of swallowing the key.
    @discardableResult
    func focusAddressBar() -> Bool {
        guard window != nil else { return false }
        holdChrome(true)
        addressFocusRequest += 1
        // Belt and braces: SwiftUI's @FocusState does not propagate reliably
        // inside an NSHostingView (the same reason chromeKeyboardFocused is
        // checked at the AppKit level), so claim the field directly once the
        // bar has mounted its content.
        claimAddressField()
        return true
    }

    /// Make the address field first responder and select its whole contents.
    ///
    /// The bar's SwiftUI content is not built in the same run-loop turn the bar
    /// is mounted, so the field usually does not exist yet on the first pass —
    /// this retries until it does rather than firing once and silently missing
    /// (which is what a plain `DispatchQueue.main.async` did when the bar was
    /// mounted by this very call).
    private func claimAddressField(attempt: Int = 0) {
        guard let window, let chromeHost,
              let field = Self.firstTextField(in: chromeHost)
        else {
            // ~1s of retries: long enough for the hosting view to build its
            // content, bounded so a pane that never mounts one stops polling.
            guard attempt < 50 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.claimAddressField(attempt: attempt + 1)
            }
            return
        }
        // A terminal surface sharing this window keeps its `focused` flag set
        // even while the field holds keyboard focus, so its
        // performKeyEquivalent would consume Cmd-C/V before they reach the
        // field editor. Same yield the click path does (addressFieldFocusChanged).
        if let controller = window.windowController as? BaseTerminalController {
            _ = controller.focusedSurface?.resignFirstResponder()
        }
        window.makeFirstResponder(field)
        // Browser convention: the address arrives selected, ready to replace.
        field.currentEditor()?.selectAll(nil)
    }

    /// Escape while editing the address: throw the edit away, put the pane's
    /// real location back in the field, and hand focus to the page — what a
    /// browser omnibox does. Submitting (Return) is the only way an edit takes
    /// effect, so an abandoned edit must never be left sitting in the field
    /// looking like where the pane is.
    func cancelAddressEditing() {
        // Focus first: resigning the field editor commits whatever was typed
        // into the bar's text binding, so the revert has to land after it.
        window?.makeFirstResponder(webView)
        addressRevertRequest += 1
        reclaimPageFocus()
    }

    /// Put keyboard focus back on the page after the address field lets go.
    ///
    /// Needed because dropping the field's SwiftUI `@FocusState` (which the
    /// revert does) parks first responder on the WINDOW a turn later, undoing
    /// the `makeFirstResponder` above — Escape would leave the pane with no
    /// focused content. Only the window-is-first-responder state is corrected,
    /// so a click that lands elsewhere in the meantime keeps its focus.
    private func reclaimPageFocus(attempt: Int = 0) {
        guard attempt < 3 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder === window {
                window.makeFirstResponder(self.webView)
            }
            self.reclaimPageFocus(attempt: attempt + 1)
        }
    }

    /// A key event this pane wants before the focused element sees it (from the
    /// pane's local event monitor). Today: Escape while a chrome text field —
    /// the address bar, or the diff panel's filter — is being edited. Returns
    /// true when the event was consumed.
    ///
    /// AppKit-level rather than a SwiftUI `.onExitCommand` for the same reason
    /// the rest of the chrome's focus handling is: @FocusState does not
    /// propagate reliably inside an NSHostingView, and the field editor — not
    /// the SwiftUI view — is what actually holds the keystroke.
    func handleChromeKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let editingAddress = chromeTextFieldFocused
        let editingFilter = sidePanelTextFieldFocused
        guard editingAddress || editingFilter else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 53,  // Escape
              !mods.contains(.command),
              !mods.contains(.control),
              !mods.contains(.option)
        else { return false }
        if editingAddress {
            cancelAddressEditing()
        } else {
            // Escape in the filter puts the whole list back and hands focus to
            // the diff — the same "throw the edit away" contract the address
            // field has.
            setDiffFilter("")
            window?.makeFirstResponder(webView)
        }
        return true
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
        // Cmd-C / Cmd-V are Ghoztty keybindings (copy_to_clipboard /
        // paste_from_clipboard). A terminal surface sharing this window keeps
        // its `focused` flag set even while the address field has keyboard
        // focus, so its `performKeyEquivalent` consumes those keys before the
        // menu can route copy:/paste: to the field editor — the address bar
        // then can't copy or paste. Make the surface yield its focus state (the
        // same fix the command palette uses on open) so clipboard actions reach
        // the field.
        if let controller = window?.windowController as? BaseTerminalController {
            _ = controller.focusedSurface?.resignFirstResponder()
        }
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
    /// that slides away before you can reach it is not a control. The open
    /// feedback composer pins it for the same reason — and because the
    /// composer hangs off the bar's bottom edge, so retracting the bar would
    /// drag the toolbar the user is typing into off screen with it.
    /// A diff pane pins the bar too: it is where next/previous-change and the
    /// unified⇄side-by-side toggle live, and a control you have to go hunting
    /// for with the mouse before every use is not a control. It also keeps the
    /// revspec visible, which is the one thing a diff pane's chrome should say.
    private var chromeAlwaysVisible: Bool {
        sidePanelLayout == .compact || feedbackOpen || isDiffMode
    }

    /// Toggle the contents panel (the chrome bar's leading button).
    func toggleSidePanel() {
        setSidePanelOpen(!sidePanelOpen)
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

    /// True when the chrome bar's address field (its field editor) holds
    /// keyboard focus — narrower than `chromeKeyboardFocused`, which also covers
    /// the bar's buttons. Only a focused text editor should capture the standard
    /// editing chords (see `performKeyEquivalent`).
    private var chromeTextFieldFocused: Bool {
        window?.firstResponder is NSText && chromeKeyboardFocused
    }

    /// True when the side panel's own text field (the diff filter) holds
    /// keyboard focus. Separate from the chrome bar's because the two live in
    /// different hosting views, and both have to be able to claim the standard
    /// editing chords — a filter field you cannot paste into is broken in
    /// exactly the way the address field used to be.
    private var sidePanelTextFieldFocused: Bool {
        guard let sidePanelHost, window?.firstResponder is NSText,
              let responder = window?.firstResponder as? NSView
        else { return false }
        return responder === sidePanelHost || responder.isDescendant(of: sidePanelHost)
    }

    /// True when keyboard focus is on an element inside THIS viewer pane that
    /// should receive the standard editing chords: the address field's editor or
    /// the web content. Deliberately excludes the bar's buttons and the feedback
    /// composer (which handles the chords itself). Gates the editing routing in
    /// `performKeyEquivalent`.
    private var paneHoldsEditingFocus: Bool {
        chromeTextFieldFocused || sidePanelTextFieldFocused || isViewerContentFocused
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
        chromeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown: self.handleMouseDown(event)
            case .mouseMoved: self.handleChromeMouseMoved(event)
            // Escape in the address field: consumed here (return nil) so the
            // field editor never sees it.
            case .keyDown: if self.handleChromeKeyDown(event) { return nil }
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

        // A focus-GAINING click into the address field selects the whole
        // address (browser omnibox). Detected here at the AppKit level, not from
        // SwiftUI's @FocusState: when the user clicks the web content the
        // WKWebView takes first responder itself, and that focus loss is not
        // observed by @FocusState — so a later click back into the field is not
        // seen as a focus change and would never re-select. Let the click go on
        // to focus the field normally; we only add the selection.
        if addressClickSelectsAll(at: point) {
            selectAddressWhenClickCompletes()
            return
        }

        if let responder = window.firstResponder as? NSView,
           responder === webView || responder.isDescendant(of: self) {
            return // already ours
        }
        window.makeFirstResponder(webView)
    }

    /// Whether a left-click at `point` (in this view's coordinates) should
    /// select the whole address: it lands on the address field, and the field
    /// does NOT already hold keyboard focus. A click into an already-focused
    /// field returns false so it just places the caret (browser omnibox rule).
    func addressClickSelectsAll(at point: NSPoint) -> Bool {
        guard !chromeTextFieldFocused, chromeVisible,
              let chromeHost, let field = Self.firstTextField(in: chromeHost)
        else { return false }
        return field.convert(field.bounds, to: self).contains(point)
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
            // Above the composer too: the composer parks behind the bar and
            // slides out from under it.
            addSubview(host, positioned: .above, relativeTo: feedbackHost ?? webView)
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

        guard chromeHost != nil else { return }
        if visible { chromeHost?.isHidden = false }
        applyTopChromeGeometry(animated: window?.isVisible == true)
    }

    /// Where the nav bar, the composer, and the content top edge belong for
    /// the CURRENT `chromeVisible`/`feedbackOpen` state.
    ///
    /// One function for both, because the two are not independent: the
    /// composer hangs off the bar's bottom edge and both reserve content
    /// space. Computing them in separate places is how they drift into
    /// disagreeing about where "parked" is.
    private struct TopChromeGeometry {
        let barTop: CGFloat
        let composerTop: CGFloat
        let contentInset: CGFloat
    }

    private var topChromeGeometry: TopChromeGeometry {
        let barHeight = chromeHost?.fittingSize.height ?? 0
        let composerHeight = feedbackComposerHeight
        let barTop: CGFloat = chromeVisible ? 0 : -barHeight
        return TopChromeGeometry(
            barTop: barTop,
            // Open: flush under the bar. Parked: pushed up far enough that
            // its bottom edge meets the bar's, i.e. fully behind it.
            composerTop: feedbackOpen
                ? barTop + barHeight
                : barTop + barHeight - composerHeight,
            contentInset: chromeVisible
                ? barHeight + (feedbackOpen ? composerHeight : 0)
                : 0)
    }

    /// The composer bar's current height. Prefer the height the bar most
    /// recently MEASURED for itself (reported live as the pill grows and
    /// shrinks) over the hosting view's fitting size, which lags a content edit
    /// by a layout pass — that lag is what left deleted lines' space unreclaimed.
    private var feedbackComposerHeight: CGFloat {
        guard feedbackHost != nil else { return 0 }
        if feedbackBarHeight > 0 { return feedbackBarHeight }
        return feedbackHost?.fittingSize.height ?? 0
    }

    /// The composer reported a new measured height (its content grew or shrank).
    /// Re-reserve exactly that much space so the page reflows DOWN when lines
    /// are added and back UP when they are deleted — the up-reflow is the one
    /// that used to leak, because nothing recomputed the inset on a plain edit.
    func feedbackBarDidChangeHeight(_ height: CGFloat) {
        guard height > 0, abs(height - feedbackBarHeight) > 0.5 else { return }
        feedbackBarHeight = height
        // Steady-state edits reflow immediately; during the open/close slide
        // the inset is already being animated toward this height and settles to
        // it on completion, so don't fight the animation here.
        guard feedbackOpen, !chromeAnimating else { return }
        applyTopChromeGeometry(animated: false)
    }

    private func applyTopChromeGeometry(animated: Bool) {
        let geometry = topChromeGeometry

        // Constraint animation only progresses while the window is actually
        // displayed; snap directly otherwise (hidden panes, tests).
        guard animated else {
            chromeTopConstraint?.constant = geometry.barTop
            feedbackTopConstraint?.constant = geometry.composerTop
            webViewTopConstraint?.constant = geometry.contentInset
            layoutSubtreeIfNeeded()
            if !chromeVisible { chromeHost?.isHidden = true }
            if !feedbackOpen { feedbackHost?.isHidden = true }
            return
        }

        chromeAnimating = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            chromeTopConstraint?.animator().constant = geometry.barTop
            feedbackTopConstraint?.animator().constant = geometry.composerTop
            webViewTopConstraint?.animator().constant = geometry.contentInset
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.chromeAnimating = false
            if !self.chromeVisible { self.chromeHost?.isHidden = true }
            if !self.feedbackOpen { self.feedbackHost?.isHidden = true }
            // The composer may have grown/shrunk mid-slide; settle the reserved
            // space to the height it actually ended at now the slide is done.
            if self.feedbackOpen { self.applyTopChromeGeometry(animated: false) }
        }
    }

    // MARK: - Worktree provenance

    /// Re-resolve which worktree the pane's content belongs to.
    ///
    /// Live, not one-shot: the address field lets one pane move between a
    /// file, `localhost:3000`, and a remote site, and each of those resolves
    /// to a different worktree or to none — so the affordance has to appear
    /// and disappear with the content. Resolution itself is subprocess work
    /// and runs off the main thread; a cached answer comes back
    /// synchronously, so stepping Back and Forward never flickers the button.
    private func refreshWorktree() {
        worktreeGeneration += 1
        let generation = worktreeGeneration
        let location = self.location
        ViewerWorktreeCache.shared.resolve(
            location: location,
            originDirectory: originDirectory
        ) { [weak self] resolved in
            guard let self, self.worktreeGeneration == generation else { return }
            guard self.worktree != resolved else { return }
            self.worktree = resolved
            // The destination just changed under a composer that is already
            // open. Closing it silently would be worse than useless — the
            // half-written report would look filed — so keep the text and
            // only drop the toolbar when there is nowhere left to file to.
            if resolved == nil, self.feedbackOpen {
                self.setFeedbackOpen(false)
            }
        }
    }

    // MARK: - Feedback composer

    /// The composer's contents. Owned here rather than by the toolbar so a
    /// half-written report survives the toolbar being toggled closed and
    /// reopened, and survives a detach/re-attach (close then undo).
    let feedbackModel = ViewerFeedbackModel()

    @Published private(set) var feedbackOpen = false
    private var feedbackHost: NSHostingView<ViewerFeedbackBar>?
    /// The bar's top offset. Parked it sits fully behind the chrome bar
    /// (clipped by it); open it sits flush beneath it.
    private var feedbackTopConstraint: NSLayoutConstraint?
    private var feedbackCloseTimer: Timer?

    /// The composer's most recently MEASURED height, reported by the bar as its
    /// pill grows and shrinks (see `feedbackBarDidChangeHeight`). The content
    /// inset tracks this so the page reflows in BOTH directions — the un-reclaimed
    /// space after deleting lines used to leak because nothing recomputed the
    /// inset on a plain edit.
    private var feedbackBarHeight: CGFloat = 0

    /// True while the nav-bar / composer slide is animating. Live height
    /// updates defer to it (the slide animates the inset itself and settles to
    /// the measured height on completion) rather than snapping it mid-slide.
    private var chromeAnimating = false

    /// Stable folder name for the report currently being composed, minted when
    /// the composer opens and cleared on send. The footer link, the files the
    /// user drops into the folder, and the eventual atomic publish all refer to
    /// one `temp/feedback/.staging/<stem>` folder for the draft's whole life.
    /// Nil when no draft is in progress.
    private(set) var feedbackDraftStem: String?

    func toggleFeedback() {
        setFeedbackOpen(!feedbackOpen)
    }

    /// Show or hide the composer. Opening with no worktree is a no-op — there
    /// would be nowhere to file the report.
    func setFeedbackOpen(_ open: Bool) {
        guard feedbackOpen != open else { return }
        if open, worktree == nil { return }
        feedbackCloseTimer?.invalidate()
        feedbackOpen = open

        if open {
            // Mint the draft's stable staging-folder name so the footer link
            // has a concrete folder to name and reveal from the moment the
            // composer appears (the folder itself is created lazily — on reveal
            // or on send — so a composer opened and closed without a word
            // leaves nothing behind).
            if feedbackDraftStem == nil {
                feedbackDraftStem = ViewerFeedbackReport.makeStem(
                    date: Date(), suffix: ViewerFeedbackReport.randomSuffix())
            }
            mountFeedbackHost()
            // The composer's only close affordance lives in the chrome bar,
            // so the bar must stop auto-hiding while it is open (same reason
            // the compact TOC layout pins it).
            setChromeVisible(true)
            applyFeedbackState(animated: window?.isVisible == true)
            focusFeedbackInput()
        } else {
            applyFeedbackState(animated: window?.isVisible == true)
            // Hand focus back to the content so the pane is usable again.
            if let responder = window?.firstResponder as? NSView,
               let feedbackHost, responder.isDescendant(of: feedbackHost) {
                window?.makeFirstResponder(webView)
            }
            scheduleChromeHide()
        }
    }

    private func mountFeedbackHost() {
        guard feedbackHost == nil else { return }
        let host = NSHostingView(
            rootView: ViewerFeedbackBar(viewerView: self, model: feedbackModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        // Above the TOC card as well as the web view: the composer spans the
        // full pane width just under the nav bar and must never draw BEHIND the
        // table-of-contents card in the gutter. The TOC layers are mounted
        // `.above webView` too, so anchoring to the topmost of them (rather than
        // to `webView`) is what keeps the composer in front regardless of which
        // was created first. (The chrome bar is lifted back on top just below.)
        addSubview(
            host, positioned: .above,
            relativeTo: sidePanelResizeHandle ?? sidePanelContainer ?? webView)
        // The chrome bar has to stay on top: the composer parks BEHIND it and
        // slides out from under it.
        if let chromeHost {
            addSubview(chromeHost, positioned: .above, relativeTo: host)
        }
        let top = host.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            top,
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        feedbackTopConstraint = top
        feedbackHost = host
        // Realize the parked position before the first slide, so it animates
        // in from behind the bar instead of from a zero frame.
        applyFeedbackState(animated: false)
    }

    /// Slide the composer out from behind the nav bar (or back under it) and
    /// move the content down to make room in the same animation group.
    private func applyFeedbackState(animated: Bool) {
        if feedbackOpen { feedbackHost?.isHidden = false }
        applyTopChromeGeometry(animated: animated)
    }

    /// Put the caret in the composer's text view once SwiftUI has mounted it.
    private func focusFeedbackInput() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let feedbackHost,
                  let textView = Self.firstTextView(in: feedbackHost) else { return }
            self.window?.makeFirstResponder(textView)
        }
    }

    /// The composer's text view inside the mounted bar, if it has rendered.
    static func firstTextView(in view: NSView) -> ViewerFeedbackTextView? {
        if let textView = view as? ViewerFeedbackTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }

    /// Take an interactive screen snapshot into the composer (the `+` button).
    func captureFeedbackScreenshot() {
        guard let feedbackHost,
              let textView = Self.firstTextView(in: feedbackHost) else { return }
        // The capture UI takes over the screen; the bar must not auto-hide
        // out from under the user while they are dragging out a region.
        holdChrome(true)
        textView.captureScreenshot { [weak self] in
            self?.holdChrome(false)
        }
    }

    /// The draft's staging folder, or nil when there is no draft in progress
    /// or no worktree to file to. This is what the footer link reveals and
    /// where the user can drop extra files before sending.
    var feedbackStagingURL: URL? {
        guard let worktree, let stem = feedbackDraftStem else { return nil }
        return ViewerFeedbackReport.stagingDirectory(in: worktree, stem: stem)
    }

    /// Worktree-relative path of the draft's staging folder, for the composer
    /// footer (e.g. `temp/feedback/.staging/<stem>`).
    var feedbackStagingRelativePath: String? {
        guard let stem = feedbackDraftStem, worktree != nil else { return nil }
        return "\(ViewerFeedbackReport.stagingRelativePath)/\(stem)"
    }

    /// Reveal the draft's staging folder in Finder, materializing it — the
    /// draft's images plus a work-in-progress `report.json` — if it doesn't
    /// exist yet, so opening it never shows a stale or empty draft. The user
    /// can drop additional files into the folder before sending; the send path
    /// publishes the whole folder, so those files become part of the report.
    func revealFeedbackStagingFolder() {
        guard let worktree, let stem = feedbackDraftStem else { return }
        let target = ViewerFeedbackReport.stagingDirectory(in: worktree, stem: stem)

        let segments = feedbackModel.segments()
        let images = feedbackModel.imagePayloads()
        let quotes = feedbackModel.quotes.map { quote in
            ViewerFeedbackReport.Quote(
                number: quote.number, text: quote.text,
                headingID: quote.headingID, headingText: quote.headingText,
                blockSelector: quote.blockSelector, blockText: quote.blockText,
                offsetInBlock: quote.offsetInBlock,
                documentOffset: quote.documentOffset,
                // Resolved against the source file at send time, not here.
                sourceLine: nil)
        }
        var context = ViewerFeedbackReport.Context(
            source: location, sourceKind: isWebURL ? "web" : "file")
        context.filePath = fileURL?.path
        context.relativePath = fileURL.flatMap {
            Self.relativePath(of: $0.path, under: worktree.path)
        }
        context.pageTitle = title
        context.paneID = paneID
        context.viewport = "\(Int(bounds.width))x\(Int(bounds.height))"
        context.appVersion = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        do {
            try ViewerFeedbackReport.stage(
                segments: segments, images: images, quotes: quotes,
                worktree: worktree, context: context, stem: stem)
        } catch {
            // Still give the reveal something to select so the user can drop
            // files in — a create-then-open fallback, never a silent no-op.
            try? FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: true)
            Self.logger.warning(
                "failed to materialize feedback staging folder: \(error)")
        }

        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// File the composed report into the detected worktree's queue.
    ///
    /// Gathers the page's own context first — what the user had SELECTED, the
    /// page title — because a report that quotes what someone was pointing at
    /// is actionable where "this is broken" is not. That read is asynchronous
    /// (it crosses into the web view), so the write happens in its completion.
    ///
    /// On success the composer clears, a confirmation replaces the destination
    /// line, and the toolbar closes itself — the user is never left unsure
    /// whether the report was filed.
    func sendFeedback() {
        guard let worktree else {
            feedbackModel.status = .failed("No worktree — nowhere to file this")
            return
        }
        guard !feedbackModel.isEmpty else { return }

        // Snapshot the composer NOW: the JS round-trip below is async, and the
        // user can keep typing during it.
        let segments = feedbackModel.segments()
        let images = feedbackModel.imagePayloads()
        let quotes = feedbackModel.quotes
        // Publish THIS draft's staging folder (with any files the user dragged
        // into it), not a fresh one. Nil when the send skipped the composer.
        let stem = feedbackDraftStem

        readPageContext { [weak self] pageTitle, selection in
            guard let self else { return }
            var context = ViewerFeedbackReport.Context(
                source: self.location,
                sourceKind: self.isWebURL ? "web" : "file")
            context.filePath = self.fileURL?.path
            context.relativePath = self.fileURL.flatMap {
                Self.relativePath(of: $0.path, under: worktree.path)
            }
            context.pageTitle = pageTitle ?? self.title
            context.selection = selection
            context.paneID = self.paneID
            context.viewport = "\(Int(self.bounds.width))x\(Int(self.bounds.height))"
            context.appVersion = Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            self.writeFeedback(
                segments: segments, images: images, quotes: quotes,
                worktree: worktree, context: context, stem: stem)
        }
    }

    /// Ask the page for its title and the user's current selection.
    ///
    /// Best-effort by design: a website that blocks script evaluation, or a
    /// pane whose page never loaded, must still be able to file feedback — it
    /// just files it without a quote.
    private func readPageContext(
        completion: @escaping (String?, String?) -> Void
    ) {
        let js = """
        (function () {
          var s = "";
          try { s = String(window.getSelection()); } catch (e) {}
          return JSON.stringify({ title: document.title || "", selection: s });
        })()
        """
        var finished = false
        let finish = { (title: String?, selection: String?) in
            guard !finished else { return }
            finished = true
            completion(title, selection)
        }
        // A wedged or hostile page must not strand the send.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(nil, nil) }

        webView.evaluateJavaScript(js) { result, _ in
            guard let raw = result as? String,
                  let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                finish(nil, nil)
                return
            }
            let title = (parsed["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let selection = (parsed["selection"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            finish(title, selection)
        }
    }

    /// Resolve git revision off the main thread, then write. Both are blocking
    /// work (a subprocess and file I/O) that has no business on the main queue.
    private func writeFeedback(
        segments: [ViewerFeedbackReport.Segment],
        images: [ViewerFeedbackReport.Image],
        quotes: [ViewerFeedbackQuote],
        worktree: ViewerWorktree,
        context: ViewerFeedbackReport.Context,
        stem: String?
    ) {
        let filePath = fileURL?.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var context = context
            let revision = ViewerWorktreeResolver.revision(at: worktree.path)
            context.branch = revision.branch
            context.commit = revision.commit

            // Locate each quote in the SOURCE file. Mapping rendered DOM back
            // to markdown source is unreliable; searching the file for the
            // passage is not, and a line number is what a reader actually
            // wants. Web pages have no source file, so they get nil.
            let sourceText = filePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            let payloadQuotes = quotes.map { quote in
                ViewerFeedbackReport.Quote(
                    number: quote.number,
                    text: quote.text,
                    headingID: quote.headingID,
                    headingText: quote.headingText,
                    blockSelector: quote.blockSelector,
                    blockText: quote.blockText,
                    offsetInBlock: quote.offsetInBlock,
                    documentOffset: quote.documentOffset,
                    sourceLine: sourceText.flatMap {
                        Self.lineNumber(of: quote.text, in: $0)
                    })
            }

            let result = Result {
                try ViewerFeedbackReport.write(
                    segments: segments, images: images, quotes: payloadQuotes,
                    worktree: worktree, context: context, stem: stem)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let written):
                    self.feedbackModel.reset()
                    // The draft's folder was just published; the next draft
                    // mints its own stem when the composer next opens.
                    self.feedbackDraftStem = nil
                    self.feedbackModel.status = .filed(written.stem)
                    Self.logger.info(
                        "filed feedback report \(written.folderURL.path, privacy: .public)")
                    // Long enough to read the confirmation, short enough that
                    // the pane gives its space back without being asked.
                    self.feedbackCloseTimer?.invalidate()
                    self.feedbackCloseTimer = Timer.scheduledTimer(
                        withTimeInterval: 1.8, repeats: false
                    ) { [weak self] _ in
                        self?.setFeedbackOpen(false)
                    }
                case .failure(let error):
                    self.feedbackModel.status = .failed(Self.feedbackErrorText(error))
                    Self.logger.warning("failed to file feedback report: \(error)")
                }
            }
        }
    }

    /// This pane's stable ghoztty id — the same value `+list --json` reports
    /// and `--target` accepts, so a report names a pane the reader can address.
    /// Owned by the enclosing `PaneView`, so it is resolved through the tree.
    var paneID: String? {
        guard let controller = window?.windowController as? BaseTerminalController,
              let pane = controller.surfaceTree.first(where: { $0.viewerView === self })
        else { return nil }
        return pane.id.uuidString
    }

    /// The 1-based line in `source` where a quoted passage appears, or nil.
    ///
    /// The quote comes from RENDERED text, so it rarely matches the source
    /// byte-for-byte (markdown syntax, wrapped lines, collapsed whitespace).
    /// So: try the whole passage first, then its first line, then a
    /// whitespace-normalized comparison — and give up honestly rather than
    /// report a line that might be wrong.
    static func lineNumber(of quote: String, in source: String) -> Int? {
        let lines = source.components(separatedBy: .newlines)
        func normalize(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .lowercased()
        }

        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        // Wrapped rendering means only the first line is likely contiguous.
        let firstLine = needle
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? needle

        for (index, line) in lines.enumerated() where line.contains(firstLine) {
            return index + 1
        }
        let target = normalize(firstLine)
        guard !target.isEmpty else { return nil }
        for (index, line) in lines.enumerated() where normalize(line).contains(target) {
            return index + 1
        }
        return nil
    }

    /// A path expressed relative to a containing directory, or nil when it is
    /// not inside it. The repo-relative form is what a coding agent can act on.
    static func relativePath(of path: String, under root: String) -> String? {
        let root = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }

    static func feedbackErrorText(_ error: Error) -> String {
        switch error {
        case ViewerFeedbackReport.WriteError.empty:
            return "Nothing to send"
        case ViewerFeedbackReport.WriteError.danglingImageReference(let number):
            return "Image #\(number) is missing"
        default:
            return "Could not write report: \(error.localizedDescription)"
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
        case "quote":
            handleQuoteMessage(payload)
        case "linkMenu":
            presentLinkMenu(payload)
        case "diffNavOverflow":
            // The open file has no further hunk in that direction; the next
            // change is in the next FILE.
            handleDiffNavOverflow((payload["direction"] as? Int) ?? 1)
        default:
            break
        }
    }

    /// The page reported a right-click on a link (see `links.js`, which has
    /// already suppressed WebKit's own menu for it). Shows the SAME menu a
    /// banner link shows — one menu, one modifier scheme, one place the
    /// ordering contract lives, with the first item the left-click default.
    ///
    /// Positioned from the POINTER rather than from the click's page
    /// coordinates: those are CSS pixels inside a view that may be page-zoomed
    /// and pinch-magnified, while the pointer has not moved in the time it took
    /// the message to cross the bridge.
    private func presentLinkMenu(_ payload: [String: Any]) {
        guard let href = payload["href"] as? String,
              let url = URL(string: href),
              let target = resolvedLinkURL(for: url),
              let window
        else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        BannerLinkOpener(anchor: self).menu(for: target)
            .popUp(positioning: nil, at: point, in: self)
    }

    /// The page's selection toolbar sent a passage to quote. Opens the
    /// composer if it is closed — quoting is a request to write feedback — and
    /// inserts the passage as its own block at the caret.
    private func handleQuoteMessage(_ payload: [String: Any]) {
        guard worktree != nil else { return }
        let text = (payload["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }

        var quote = ViewerFeedbackQuote(
            number: feedbackModel.takeQuoteNumber(), text: text)
        quote.headingID = (payload["headingId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        quote.headingText = (payload["headingText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        quote.blockSelector = (payload["blockSelector"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        quote.blockText = (payload["blockText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        quote.offsetInBlock = (payload["offsetInBlock"] as? Int).flatMap { $0 < 0 ? nil : $0 }
        quote.documentOffset = (payload["documentOffset"] as? Int).flatMap { $0 < 0 ? nil : $0 }

        setFeedbackOpen(true)
        // Mount/focus first, then insert at wherever the caret ended up, so
        // the quote lands in the flow the user is writing rather than always
        // at the top.
        DispatchQueue.main.async { [weak self] in
            guard let self, let feedbackHost = self.feedbackHost,
                  let textView = Self.firstTextView(in: feedbackHost) else { return }
            let caret = textView.selectedRange()
            let inserted = self.feedbackModel.insertQuote(quote, at: caret)
            textView.setSelectedRange(
                NSRange(location: inserted.location + inserted.length, length: 0))
            textView.didChangeText()
            textView.scrollRangeToVisible(textView.selectedRange())
            self.window?.makeFirstResponder(textView)
        }
    }

    private func setTOCItems(_ items: [ViewerTOCItem]) {
        guard items != tocItems else { return }
        tocItems = items
        if items.isEmpty {
            activeHeadingID = nil
            sidePanelOpen = false
        }
        updateSidePanelLayout()
    }

    /// Scroll the page to a heading (a TOC row was clicked). The panel is an
    /// overlay in the narrow layout, so using it dismisses it.
    func scrollToHeading(id: String) {
        webView.evaluateJavaScript("window.__viewer.scrollToAnchor(\(Self.js(id)))")
        activeHeadingID = id
        if sidePanelLayout == .compact { setSidePanelOpen(false) }
    }

    func setSidePanelOpen(_ open: Bool) {
        guard sidePanelOpen != open else { return }
        sidePanelOpen = open
        // Only a deliberate toggle animates. Layout passes reach the same
        // code and must stay silent.
        animatingSidePanel = true
        updateSidePanelLayout()
        animatingSidePanel = false
    }

    /// Mount the panel inside a layer-backed container, so the slide can be
    /// a transform on one layer rather than a relayout of the whole card.
    private func mountSidePanel(_ panel: ViewerSidePanel, parked: Bool, cardWidth: CGFloat) {
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
        sidePanelConstraints = [
            container.topAnchor.constraint(equalTo: webView.topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
        ]
        NSLayoutConstraint.activate(sidePanelConstraints)
        sidePanelContainer = container
        sidePanelHost = host

        if parked {
            // Realize the parked position before the first slide, so opening
            // animates in from off-edge instead of from nowhere.
            applySidePanelState(parked: true, cardWidth: cardWidth, animated: false)
        }
    }

    /// Slide + fade the compact panel in or out.
    ///
    /// Runs entirely on the compositor: the layer's contents are already
    /// rendered, so translating and fading it costs no layout and no SwiftUI
    /// work per frame. The panel's constraints never move.
    private func applySidePanelState(parked: Bool, cardWidth: CGFloat, animated: Bool) {
        guard let container = sidePanelContainer, let layer = container.layer else { return }

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
            container.isHidden = self.sidePanelLayout == .compact && !self.sidePanelOpen
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

    /// Which side-panel presentation the pane's current width calls for.
    ///
    /// A diff pane lists files, every other pane lists headings; either way an
    /// empty list means no card, because a card with nothing in it is a strip
    /// of the document taken away for nothing.
    private var desiredSidePanelLayout: SidePanelLayout {
        let hasContent = isDiffMode ? !diffFiles.isEmpty : !tocItems.isEmpty
        guard hasContent else { return .hidden }
        return bounds.width >= Self.sidePanelGutterMinWidth ? .gutter : .compact
    }

    override func layout() {
        super.layout()
        // Panes are resized constantly by split-tree drags, so the gutter ⇄
        // compact switch has to ride layout rather than any one-shot setup.
        updateSidePanelLayout()
    }

    /// Mount, size, or tear down the TOC views for the current pane width,
    /// and tell the page how much gutter to reserve.
    private func updateSidePanelLayout() {
        // layout() can run before setupWebView has assigned the web view.
        guard webView != nil else { return }

        let layout = desiredSidePanelLayout
        if sidePanelLayout != layout {
            sidePanelLayout = layout
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
            ? sidePanelWidth
            : min(sidePanelWidth,
                  max(120, bounds.width - GlassCard.outerMargin * 2))

        // Mounted in both layouts. A closed compact panel is PARKED off the
        // left edge rather than unmounted: a view that is destroyed on close
        // has nothing to animate, so it could only ever pop.
        let showsPanel = layout != .hidden
        let parked = layout == .compact && !sidePanelOpen

        if showsPanel {
            let panel = ViewerSidePanel(
                viewerView: self, width: cardWidth, maxHeight: maxCardHeight)
            let signature = SidePanelSignature(width: cardWidth, maxHeight: maxCardHeight)
            if let host = sidePanelHost {
                // Only push a new root view when its inputs actually moved.
                // This runs from layout(), and re-assigning rootView marks
                // the hosting view dirty — doing that unconditionally would
                // re-enter layout every frame of a divider drag.
                if signature != sidePanelSignature {
                    sidePanelSignature = signature
                    host.rootView = panel
                }
            } else {
                sidePanelSignature = signature
                mountSidePanel(panel, parked: parked, cardWidth: cardWidth)
            }
            applySidePanelState(
                parked: parked,
                cardWidth: cardWidth,
                animated: animatingSidePanel && window?.isVisible == true)
        } else {
            sidePanelContainer?.removeFromSuperview()
            sidePanelContainer = nil
            sidePanelHost = nil
            sidePanelConstraints = []
            sidePanelSignature = nil
        }

        updateSidePanelResizeHandle(layout: layout, cardWidth: cardWidth)

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
        if gutter != sidePanelGutterWidth {
            sidePanelGutterWidth = gutter
            pushSidePanelGutter()
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
    private func updateSidePanelResizeHandle(layout: SidePanelLayout, cardWidth: CGFloat) {
        guard layout == .gutter, let container = sidePanelContainer else {
            sidePanelResizeHandle?.removeFromSuperview()
            sidePanelResizeHandle = nil
            sidePanelResizeHandleCenterX = nil
            return
        }

        let handle: SidePanelResizeHandle
        if let existing = sidePanelResizeHandle {
            handle = existing
        } else {
            handle = SidePanelResizeHandle()
            handle.translatesAutoresizingMaskIntoConstraints = false
            handle.onDrag = { [weak self] delta, startWidth in
                self?.setSidePanelWidth(startWidth + delta)
            }
            handle.widthAtDragStart = { [weak self] in
                self?.sidePanelWidth ?? Self.sidePanelDefaultWidth
            }
            handle.onDragEnded = { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(
                    Double(self.sidePanelWidth), forKey: Self.sidePanelWidthDefaultsKey)
            }
            addSubview(handle, positioned: .above, relativeTo: container)
            let centerX = handle.centerXAnchor.constraint(
                equalTo: container.leadingAnchor, constant: 0)
            NSLayoutConstraint.activate([
                centerX,
                handle.widthAnchor.constraint(equalToConstant: SidePanelResizeHandle.grabWidth),
                handle.topAnchor.constraint(
                    equalTo: container.topAnchor, constant: GlassCard.outerMargin),
                handle.bottomAnchor.constraint(
                    equalTo: container.bottomAnchor, constant: -GlassCard.outerMargin),
            ])
            sidePanelResizeHandle = handle
            sidePanelResizeHandleCenterX = centerX
        }

        let edge = GlassCard.outerMargin + cardWidth
        if sidePanelResizeHandleCenterX?.constant != edge {
            sidePanelResizeHandleCenterX?.constant = edge
        }
    }

    /// Apply a dragged card width, clamped to the allowed range and to what
    /// the pane can actually give the document beside it.
    func setSidePanelWidth(_ proposed: CGFloat) {
        // Never let the card starve the document: cap it so the text column
        // keeps at least the width the gutter layout is predicated on.
        let paneCap = max(
            Self.sidePanelMinWidth,
            bounds.width - Self.sidePanelGutterMinWidth / 2)
        let clamped = min(
            min(Self.sidePanelMaxWidth, paneCap),
            max(Self.sidePanelMinWidth, proposed))
        guard clamped != sidePanelWidth else { return }
        sidePanelWidth = clamped
        // The card, the handle, and the page's gutter all derive from this —
        // one layout pass moves all three together.
        updateSidePanelLayout()
    }

    /// Hand the gutter width to the page, which reserves it as padding on
    /// the document body.
    ///
    /// The card floats OVER the web view rather than beside it, and the page
    /// makes room for it. Insetting the web view natively looked equivalent
    /// but was not: the reserved strip then painted this view's background
    /// instead of the markdown page's, leaving a visible seam down the edge
    /// of the gutter in both light and dark.
    private func pushSidePanelGutter() {
        // Only our own template has a `window.__viewer` to talk to; a website
        // or a rendered HTML file has no panel and no gutter to reserve.
        guard pageLoaded, showingTemplatePage else { return }
        webView.evaluateJavaScript("window.__viewer.setGutter(\(sidePanelGutterWidth))")
    }

    /// Drop the TOC entirely (leaving a file view, or tearing the pane down).
    private func clearTOC() {
        setTOCItems([])
        updateSidePanelLayout()
    }

    // MARK: - Git diff

    /// How a diff's lines are laid out.
    ///
    /// A chrome preference rather than a property of any one diff, so — like
    /// the side panel's width — it lives in defaults and applies to every diff
    /// pane, instead of being something you re-set every time you open one.
    enum DiffViewStyle: String {
        case unified
        case split

        var next: DiffViewStyle { self == .unified ? .split : .unified }
    }

    private static let diffViewStyleDefaultsKey = "ViewerDiffViewStyle"

    @Published private(set) var diffViewStyle: DiffViewStyle = {
        let raw = UserDefaults.standard.string(forKey: diffViewStyleDefaultsKey)
        return raw.flatMap(DiffViewStyle.init(rawValue:)) ?? .unified
    }()

    /// Every changed file in the diff, eagerly (one cheap `--numstat` pass);
    /// each file's PATCH is fetched only when its row is clicked. That split
    /// is what lets a thousand-file range open instantly.
    @Published private(set) var diffFiles: [ViewerDiffFile] = []
    /// The rows the side panel draws — the tree, filtered and folded.
    @Published private(set) var diffRows: [ViewerDiffTree.Row] = []
    @Published private(set) var diffFilter: String = ""
    @Published private(set) var activeDiffFileID: String?

    private var diffCollapsedFolders: Set<String> = []
    /// The working tree the diff is being taken in, and the spec with a bare
    /// `git-diff:` already resolved to a real range. Both are answers from
    /// git, so they exist only once a listing has loaded.
    private var diffRepo: String?
    private var resolvedDiffSpec: ViewerDiffSpec?
    private let diffLoader = ViewerDiffLoader()
    /// Poll for a working-tree diff (see `startWatchingDiff`).
    private var diffRefreshTimer: Timer?
    /// How often a `git-status:` pane re-checks the working tree.
    private static let diffRefreshInterval: TimeInterval = 2.0

    /// True while the panel is showing filter results rather than the tree.
    var isDiffFiltered: Bool { !diffFilter.isEmpty }

    /// The count line in the panel header.
    var diffSummaryText: String {
        guard !diffFiles.isEmpty else { return "" }
        let shown = ViewerDiffTree.visibleFiles(in: diffRows).count
        return shown == diffFiles.count
            ? "\(diffFiles.count)"
            : "\(shown)/\(diffFiles.count)"
    }

    var activeDiffFile: ViewerDiffFile? {
        diffFiles.first { $0.id == activeDiffFileID }
    }

    // MARK: Panel interaction

    func setDiffFilter(_ text: String) {
        guard diffFilter != text else { return }
        diffFilter = text
        rebuildDiffRows()
    }

    func isDiffFolderCollapsed(_ key: String) -> Bool {
        diffCollapsedFolders.contains(key)
    }

    func toggleDiffFolder(_ key: String) {
        if diffCollapsedFolders.contains(key) {
            diffCollapsedFolders.remove(key)
        } else {
            diffCollapsedFolders.insert(key)
        }
        rebuildDiffRows()
    }

    /// Show a file's patch. The panel is an overlay in the narrow layout, so
    /// using it dismisses it — the same rule a TOC row follows.
    func selectDiffFile(_ file: ViewerDiffFile, scrollTo hunk: String? = nil) {
        activeDiffFileID = file.id
        loadDiffPatch(for: file, scrollTo: hunk)
        if sidePanelLayout == .compact { setSidePanelOpen(false) }
    }

    /// Return in the filter field opens the top hit — type a few letters and
    /// go, rather than type and then reach for the mouse.
    func openFirstFilteredFile() {
        guard let first = ViewerDiffTree.visibleFiles(in: diffRows).first else { return }
        selectDiffFile(first)
    }

    /// The filter field gained or lost keyboard focus.
    ///
    /// A terminal surface sharing this window keeps its `focused` flag set even
    /// while this field holds keyboard focus, so its `performKeyEquivalent`
    /// would consume Cmd-C/V before the field editor sees them. Same yield the
    /// address field performs.
    func diffFilterFocusChanged(_ focused: Bool) {
        guard focused else { return }
        if let controller = window?.windowController as? BaseTerminalController {
            _ = controller.focusedSurface?.resignFirstResponder()
        }
    }

    func setDiffViewStyle(_ style: DiffViewStyle) {
        guard diffViewStyle != style else { return }
        diffViewStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.diffViewStyleDefaultsKey)
        guard pageLoaded, isDiffMode else { return }
        webView.evaluateJavaScript(
            "window.__viewer.setDiffStyle(\(Self.js(style.rawValue)))")
    }

    func toggleDiffViewStyle() { setDiffViewStyle(diffViewStyle.next) }

    // MARK: Change navigation

    /// Step to the next / previous change.
    ///
    /// Within the open file this is a hunk jump, done page-side because only
    /// the page knows where the hunks landed. When there is no next hunk the
    /// page says so (`diffNavOverflow`) and we roll over to the adjacent FILE,
    /// which is what "next change" means across a multi-file diff.
    func goToNextChange() { navigateDiff(1) }
    func goToPreviousChange() { navigateDiff(-1) }

    private func navigateDiff(_ direction: Int) {
        guard isDiffMode else { return }
        guard activeDiffFileID != nil else {
            // Nothing open yet: the first change is the first file's.
            if let first = ViewerDiffTree.visibleFiles(in: diffRows).first {
                selectDiffFile(first, scrollTo: direction > 0 ? "first" : "last")
            }
            return
        }
        guard pageLoaded else { return }
        webView.evaluateJavaScript("window.__viewer.diffNav(\(direction))")
    }

    /// The page ran out of hunks in `direction`; move to the adjacent file.
    fileprivate func handleDiffNavOverflow(_ direction: Int) {
        let files = ViewerDiffTree.visibleFiles(in: diffRows)
        guard let current = activeDiffFileID,
              let index = files.firstIndex(where: { $0.id == current })
        else { return }
        let next = index + (direction > 0 ? 1 : -1)
        guard files.indices.contains(next) else { return }
        // Entering a file backwards lands on its LAST hunk, so walking
        // backwards through a diff reads in reverse rather than skipping to
        // each file's top.
        selectDiffFile(files[next], scrollTo: direction > 0 ? "first" : "last")
    }

    // MARK: Loading

    /// Whether the pane can currently ask git anything.
    private var diffDirectory: String? {
        // The origin directory is the pane's `--working-directory` (or the
        // caller's cwd), persisted in the session manifest — so a restored
        // diff pane re-runs against the same repo it was opened for.
        originDirectory ?? worktree?.path
    }

    /// Re-run the diff and reconcile the panel with the result.
    ///
    /// One path serves the first load, `+reload`/Cmd-R, and the working-tree
    /// poll. Nothing is pushed to the page when the file list has not moved,
    /// which is what makes a 2-second poll invisible instead of a flicker.
    func refreshDiff(preservingSelection: Bool, force: Bool = false) {
        guard let spec = diffSpec else { return }
        let previous = diffFiles

        diffLoader.loadListing(spec: spec, directory: diffDirectory) { [weak self] result in
            guard let self, self.isDiffMode else { return }
            switch result {
            case .failure(let error):
                self.diffRepo = nil
                self.resolvedDiffSpec = nil
                self.applyDiffFiles([])
                self.pushDiffListing(message: error.title, detail: error.detail)
            case .success(let listing):
                self.diffRepo = listing.repo
                self.resolvedDiffSpec = listing.spec
                let changed = listing.files != previous
                if changed || force {
                    self.applyDiffFiles(listing.files)
                    self.pushDiffListing(message: listing.message, detail: nil)
                }
                // The selection is read HERE, not snapshotted when the refresh
                // was requested: git runs off the main thread, and a click
                // that lands during a poll's round trip must not be undone by
                // that poll finishing.
                self.reconcileDiffSelection(
                    selection: preservingSelection ? self.activeDiffFileID : nil,
                    previousFiles: previous,
                    force: force)
                self.startWatchingDiff()
            }
        }
    }

    private func applyDiffFiles(_ files: [ViewerDiffFile]) {
        diffFiles = files
        // A folder the user closed stays closed across a refresh. Keys the new
        // listing no longer contains are dropped, so a status pane left open
        // for an afternoon does not accumulate a set of dead folder names.
        if !diffCollapsedFolders.isEmpty {
            let live = Set(ViewerDiffTree.rows(for: files).compactMap(\.folderKey))
            diffCollapsedFolders.formIntersection(live)
        }
        rebuildDiffRows()
    }

    private func rebuildDiffRows() {
        diffRows = ViewerDiffTree.rows(
            for: diffFiles, filter: diffFilter, collapsed: diffCollapsedFolders)
        updateSidePanelLayout()
    }

    /// Decide what should be on screen after a refresh: the same file if it is
    /// still in the diff, its fresh patch if its counts moved, and the first
    /// file when the pane has nothing open yet.
    private func reconcileDiffSelection(
        selection: String?,
        previousFiles: [ViewerDiffFile],
        force: Bool
    ) {
        let visible = ViewerDiffTree.visibleFiles(in: diffRows)
        if let selection, let current = diffFiles.first(where: { $0.id == selection }) {
            activeDiffFileID = selection
            let before = previousFiles.first { $0.id == selection }
            if force || before != current {
                loadDiffPatch(for: current, scrollTo: nil)
            }
            return
        }
        // The selected file left the diff (staged, reverted, committed), or
        // this is the first load: open the first thing in the list rather than
        // leaving the pane blank.
        guard let first = visible.first else {
            activeDiffFileID = nil
            return
        }
        activeDiffFileID = first.id
        loadDiffPatch(for: first, scrollTo: nil)
    }

    private func loadDiffPatch(for file: ViewerDiffFile, scrollTo hunk: String?) {
        guard let repo = diffRepo, let spec = resolvedDiffSpec else { return }
        // Binary files never get a patch; say so immediately rather than
        // spawning a git process that will produce nothing useful.
        guard !file.isBinary else {
            pushDiffFile(file, patch: nil, scrollTo: hunk)
            return
        }
        diffLoader.loadPatch(file: file, spec: spec, repo: repo) { [weak self] file, patch in
            guard let self, self.activeDiffFileID == file.id else { return }
            self.pushDiffFile(file, patch: patch, scrollTo: hunk)
        }
    }

    // MARK: Page bridge

    private func pushDiffListing(message: String?, detail: String?) {
        guard pageLoaded, isDiffMode else { return }
        var payload: [String: Any] = [
            "title": (resolvedDiffSpec ?? diffSpec)?.title ?? "",
            "subtitle": diffSubtitle,
            "fileCount": diffFiles.count,
            "additions": diffFiles.reduce(0) { $0 + $1.additions },
            "deletions": diffFiles.reduce(0) { $0 + $1.deletions },
            "style": diffViewStyle.rawValue,
        ]
        if let message { payload["message"] = message }
        if let detail { payload["detail"] = detail }
        evaluate("window.__viewer.setDiffListing", payload)
    }

    /// The line under the diff's title: which repo, and which kind of diff.
    private var diffSubtitle: String {
        var parts: [String] = []
        if let repo = diffRepo { parts.append((repo as NSString).lastPathComponent) }
        if case .status = (resolvedDiffSpec ?? diffSpec)?.kind {
            parts.append("staged, unstaged and untracked changes")
        }
        return parts.joined(separator: " · ")
    }

    private func pushDiffFile(_ file: ViewerDiffFile, patch: String?, scrollTo hunk: String?) {
        guard pageLoaded, isDiffMode else { return }
        var payload: [String: Any] = [
            "path": file.path,
            "status": file.status.rawValue,
            "statusLetter": file.status.letter,
            "origin": file.origin.rawValue,
            "additions": file.additions,
            "deletions": file.deletions,
            "binary": file.isBinary,
            "language": Self.highlightLanguage(
                forExtension: (file.path as NSString).pathExtension.lowercased()) ?? "",
            "patch": patch ?? "",
        ]
        if let oldPath = file.oldPath { payload["oldPath"] = oldPath }
        if let hunk { payload["scrollTo"] = hunk }
        if let section = file.origin.sectionTitle { payload["section"] = section }
        evaluate("window.__viewer.setDiffFile", payload)
    }

    /// Call a page function with one JSON argument.
    private func evaluate(_ function: String, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("\(function)(\(json))")
    }

    // MARK: Live refresh

    /// Poll the working tree so a `git-status:` pane does not go stale the
    /// moment the user saves a file.
    ///
    /// A poll rather than a file watcher because the thing being watched is a
    /// whole repository: a watcher would have to cover every tracked file, the
    /// index, and HEAD, and would still miss a `git add` performed in another
    /// checkout of the same repo. `git status` is cheap, the work happens off
    /// the main thread, and an unchanged file list pushes nothing to the page —
    /// so the cost of being wrong here is a couple of milliseconds, not a
    /// flicker.
    private func startWatchingDiff() {
        let spec = resolvedDiffSpec ?? diffSpec
        guard spec?.tracksWorkingTree == true, window != nil else {
            stopWatchingDiff()
            return
        }
        guard diffRefreshTimer == nil else { return }
        diffRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.diffRefreshInterval, repeats: true
        ) { [weak self] timer in
            // A pane that has left its window stops polling for good, rather
            // than waking every two seconds to discover it has nothing to do.
            // The run loop owns the timer, so a pane that only ever returns
            // early here would keep it alive for the life of the process.
            guard let self, self.isDiffMode, self.window != nil else {
                timer.invalidate()
                self?.diffRefreshTimer = nil
                return
            }
            self.refreshDiff(preservingSelection: true)
        }
    }

    private func stopWatchingDiff() {
        diffRefreshTimer?.invalidate()
        diffRefreshTimer = nil
    }

    /// Drop the panel's contents (leaving diff mode, or retargeting the pane
    /// at a different revspec). `diffSpec` itself survives, so navigating Back
    /// to the diff restores it.
    private func clearDiffState() {
        stopWatchingDiff()
        diffFiles = []
        diffRows = []
        diffFilter = ""
        activeDiffFileID = nil
        diffCollapsedFolders = []
        diffRepo = nil
        resolvedDiffSpec = nil
        // Take the card down NOW rather than at the next layout pass: the old
        // diff's file list is gone, and a card still showing it while the new
        // one loads is showing a lie.
        updateSidePanelLayout()
    }

    // MARK: - Loading

    private func load() {
        switch mode {
        case .markdown, .code, .diff:
            loadTemplatePage()
        case .html(let url):
            // Read access is scoped to the file's own directory: that is what
            // makes sibling (and nested) CSS, JS, images, and fonts resolve,
            // which is the whole point of rendering the file rather than its
            // source. It is deliberately not widened to the repo root — the
            // grant lets the page's subresource loads read anything beneath
            // it, and a scaffolded mock keeps its assets next to itself. A
            // page reaching UP out of its folder (`../shared/app.css`) is the
            // documented cost of that.
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                // Fall back to the template so a missing file gets the same
                // in-page error card every other file mode gets, instead of
                // WebKit's blank failure page (see renderFileContent).
                loadTemplatePage()
                return
            }
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case .web(let url):
            webView.load(URLRequest(url: url))
        }
    }

    private func loadTemplatePage() {
        guard let pageURL = URL(string: "\(ViewerSchemeHandler.scheme)://page/viewer.html") else { return }
        webView.load(URLRequest(url: pageURL))
    }

    /// (Re-)inject the file's content into the loaded page. Safe to call
    /// repeatedly — the page preserves scroll position on re-render.
    func renderFileContent() {
        guard pageLoaded else { return }
        if case .diff = mode {
            // A diff's content comes from git, not from a file on disk;
            // reloading the listing IS its render (see refreshDiff). Forced,
            // because this is the page announcing it is ready: the listing may
            // already be loaded (see init) and would otherwise push nothing,
            // leaving the freshly-loaded page blank.
            refreshDiff(preservingSelection: true, force: true)
            return
        }
        guard let fileURL else { return }

        if case .html = mode {
            // An HTML file has no content to inject — the web view loaded it
            // directly. Reaching here means `load()` could not open it and
            // fell back to the template, which is now up and waiting for its
            // error card.
            webView.evaluateJavaScript(
                "window.__viewer.setError(\(Self.js("Cannot read file")), \(Self.js(fileURL.path)))")
            return
        }

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
            case .html, .web, .diff:
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
            self.reloadAfterFileChange()
        }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// The watched file changed on disk. Template-backed modes re-inject the
    /// new text; an HTML file is the page itself, so re-fetching it from disk
    /// IS its render.
    ///
    /// `reload()` rather than a fresh `loadFileURL`: it replaces the current
    /// history entry instead of pushing one (so live-saving does not fill the
    /// Back stack), and WebKit restores the scroll offset across it, which is
    /// what keeps a save from throwing you back to the top of a long page.
    private func reloadAfterFileChange() {
        guard case .html = mode else {
            renderFileContent()
            return
        }
        // Showing the error card means the file was unreadable when we last
        // looked; go through `load()` so it gets re-checked and the real page
        // takes over once it is back.
        if showingTemplatePage || !pageLoaded {
            load()
        } else {
            webView.reload()
        }
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

    /// Swallow the hero-navigation chords (Cmd+Shift+Up/Down) before they reach
    /// the inner WKWebView.
    ///
    /// Hero mode navigates panes with an app-wide local key monitor
    /// (`HeroKeyNavigator`) that consumes Cmd+Shift+Up/Down. That works for a
    /// focused terminal, but a focused viewer's first responder is the WKWebView
    /// (see `becomeFirstResponder`), which does NOT honor the monitor's consume:
    /// the same physical keystroke is still delivered to WebKit, which
    /// (1) interprets it as a text-selection command and emits an NSBeep for the
    /// unhandled key, and (2) re-injects it, so the monitor fires a SECOND time
    /// and the hero selection double-steps (skips a pane). Because this view is
    /// an ancestor of the web view, our `performKeyEquivalent` runs first in the
    /// hierarchy's key-equivalent walk; returning `true` here marks the chord
    /// handled so WebKit never sees it — no beep, no re-injection. The monitor
    /// still performs the actual navigation.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isHeroNavChord(event) { return true }
        // Whatever is focused INSIDE this viewer pane — the address field or the
        // web page itself — must get the standard editing chords (Cmd-C/V/X/A)
        // so the pane behaves like a browser. They otherwise don't: Ghoztty
        // binds Cmd-C/V to TERMINAL copy/paste on the surface, so the Edit menu
        // carries no plain Cmd-C/V equivalent that routes copy:/paste:/… to an
        // ordinary AppKit responder — a focused web page or address field is
        // left with no handler and the chord just no-ops. Dispatch them down the
        // focused element's own responder chain here (so it reaches the field
        // editor, or the WKWebView behind its content view), ahead of super's
        // descent, and only while THIS pane holds the focus so a Cmd-C aimed at
        // a terminal split is untouched. The feedback composer is excluded: it
        // services these chords in its own performKeyEquivalent.
        if paneHoldsEditingFocus,
           let selector = Self.editingSelector(for: event),
           window?.firstResponder?.tryToPerform(selector, with: nil) == true {
            return true
        }
        // Cmd+/−/0 zoom the viewer instead of the terminal font size — but only
        // when this viewer's own content is focused, so a focused terminal in
        // the same window keeps its font-size behavior and an unfocused viewer
        // split stays put. Returning true stops the event before the menu's
        // font-size key equivalent (which runs AFTER the view hierarchy's
        // performKeyEquivalent walk) can route it to the terminal.
        if isViewerContentFocused, let action = Self.zoomAction(for: event) {
            handleZoom(action)
            return true
        }
        // Pane-scoped chords (Cmd-R reload, Cmd-D address field). These override
        // their global Ghoztty bindings (prompt_surface_banner / new_split) only
        // while THIS pane holds keyboard focus; every other pane, and every
        // terminal, still gets the global behavior because we fall through to
        // super, whose walk ends at the menu's key equivalent.
        if paneHoldsFocus, let chord = Self.paneChord(for: event), handle(chord) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A chord that belongs to a focused viewer pane rather than to the app.
    enum PaneChord {
        /// Cmd-R — reload in place, the interactive `+reload`.
        case reload
        /// Cmd-D — focus and select the address field.
        case focusAddress
    }

    /// Classify a key event as one of the viewer's pane-scoped chords, or nil
    /// if it is not one. Pure classification (no side effects) so the mapping is
    /// unit-testable without a live pane. Requires exactly Command (no
    /// Control/Option/Shift) so Cmd+Shift+R ("Change Window Title") and the
    /// other Cmd+Shift bindings are untouched.
    static func paneChord(for event: NSEvent) -> PaneChord? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command),
              !mods.contains(.control),
              !mods.contains(.option),
              !mods.contains(.shift)
        else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": return .reload
        case "d": return .focusAddress
        default: return nil
        }
    }

    /// Perform a pane-scoped chord. Returns false when the pane could not
    /// service it, so the caller passes the key on to its global binding rather
    /// than swallowing it.
    private func handle(_ chord: PaneChord) -> Bool {
        switch chord {
        case .reload:
            reloadContent()
            return true
        case .focusAddress:
            return focusAddressBar()
        }
    }

    /// True while keyboard focus is anywhere inside THIS viewer pane — its web
    /// content, its chrome bar's field or buttons, or its feedback composer.
    /// The guard that keeps the pane-scoped chords from firing for a focused
    /// terminal (or another viewer split) in the same window:
    /// `performKeyEquivalent` is offered to every view, not just the focused one.
    private var paneHoldsFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// Cmd+Shift+Up/Down — the exact chord `HeroKeyNavigator` navigates with.
    static func isHeroNavChord(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains([.shift, .command]) else { return false }
        return event.specialKey == .upArrow || event.specialKey == .downArrow
    }

    /// The standard editing action a Cmd-key chord maps to, or nil if the event
    /// is not one. Pure classification (no side effects) so the mapping is
    /// unit-testable without a pasteboard or a live responder. Requires exactly
    /// Command (no Control/Option/Shift) so it never collides with the viewer's
    /// other chords or the app's Cmd-Shift bindings.
    static func editingSelector(for event: NSEvent) -> Selector? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command),
              !mods.contains(.control),
              !mods.contains(.option),
              !mods.contains(.shift)
        else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "x": return #selector(NSText.cut(_:))
        case "a": return #selector(NSText.selectAll(_:))
        default: return nil
        }
    }

    // MARK: - Zoom (keyboard page zoom)

    /// A Cmd+/−/0 keyboard-zoom request. Trackpad pinch is handled entirely by
    /// WebKit (`allowsMagnification`) and is independent of this.
    enum ZoomAction { case zoomIn, zoomOut, reset }

    /// Keyboard page-zoom bounds and per-press step. 1.0 is 100%.
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 3.0
    static let zoomStep: CGFloat = 1.1

    /// Classify a key event as a viewer zoom chord, or nil if it is not one.
    ///
    /// Matches the DEFAULT font-size chords (Cmd + `=`/`+`/`-`/`0`) — the same
    /// keys `Config.zig` binds to increase/decrease/reset_font_size. Deliberately
    /// does NOT consult user-remapped bindings (first-cut simplification).
    /// Requires Command and rejects Control/Option so it never collides with
    /// other chords. `charactersIgnoringModifiers` keeps Shift, so Shift+= ("+")
    /// still reads as zoom-in.
    static func zoomAction(for event: NSEvent) -> ZoomAction? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command),
              !mods.contains(.control),
              !mods.contains(.option),
              let chars = event.charactersIgnoringModifiers
        else { return nil }
        switch chars {
        case "=", "+": return .zoomIn
        case "-": return .zoomOut
        case "0": return .reset
        default: return nil
        }
    }

    /// The next page-zoom factor for an action, clamped to [minZoom, maxZoom].
    static func steppedZoom(from current: CGFloat, action: ZoomAction) -> CGFloat {
        switch action {
        case .zoomIn: return min(maxZoom, current * zoomStep)
        case .zoomOut: return max(minZoom, current / zoomStep)
        case .reset: return 1.0
        }
    }

    /// The keyboard (Cmd+/−/0) page-zoom factor for this pane. 1.0 is 100%.
    /// In-session only — deliberately NOT persisted, so a restored pane comes
    /// back at 100%. Independent of trackpad pinch magnification, which WebKit
    /// tracks itself.
    private var zoomFactor: CGFloat = 1.0

    /// Push the current `zoomFactor` to the web view.
    private func pushZoomToWebView() {
        webView.pageZoom = zoomFactor
    }

    /// Apply a Cmd+/−/0 zoom chord: step the factor and push it to the page.
    private func handleZoom(_ action: ZoomAction) {
        zoomFactor = Self.steppedZoom(from: zoomFactor, action: action)
        pushZoomToWebView()
    }

    /// True when THIS viewer's own web content holds keyboard focus. The guard
    /// that keeps zoom chords from stealing Cmd+/−/0 from a focused terminal in
    /// the same window (performKeyEquivalent is offered to every view, not just
    /// the focused one) and from firing in an unfocused viewer split. The chrome
    /// bar's address field is a descendant of the pane but NOT of the web view,
    /// so it is excluded too.
    private var isViewerContentFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case location
        case homeLocation
        case originDirectory
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let location = try container.decode(String.self, forKey: .location)
        // Absent in state written before the home button existed: such a
        // viewer had never navigated, so where it is IS its home.
        let home = try container.decodeIfPresent(String.self, forKey: .homeLocation)
        // Absent in state written before feedback capture existed: such a
        // pane simply has no fallback leg, so a remote/blank location
        // resolves to no worktree until it is reopened.
        let origin = try container.decodeIfPresent(String.self, forKey: .originDirectory)
        self.init(
            location: location,
            homeLocation: home ?? location,
            originDirectory: origin)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(location, forKey: .location)
        try container.encode(homeLocation, forKey: .homeLocation)
        try container.encodeIfPresent(originDirectory, forKey: .originDirectory)
    }
}

extension ViewerView.Mode {
    /// The file this mode renders, nil for a website or a diff.
    var fileURL: URL? {
        switch self {
        case .markdown(let url), .code(let url), .html(let url): return url
        case .web, .diff: return nil
        }
    }

    /// The file the TEMPLATE page renders, nil for everything the web view
    /// loads itself. An HTML file is excluded on purpose — see `fileLocation`.
    var templateFileURL: URL? {
        switch self {
        case .markdown(let url), .code(let url): return url
        case .html, .web, .diff: return nil
        }
    }

    /// The diff this mode renders, nil for everything else.
    var diffSpec: ViewerDiffSpec? {
        if case .diff(let spec) = self { return spec }
        return nil
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
            // The template page is back on screen — restore whichever kind of
            // content it was rendering. Exactly one of these is ever set.
            if let diffSpec {
                mode = .diff(diffSpec)
                location = diffSpec.location
                title = diffSpec.title
                webView.allowsBackForwardNavigationGestures = false
                pageLoaded = false
                currentURL = diffSpec.location
                return
            }
            guard let fileLocation else { return }
            mode = Self.mode(for: fileLocation.path)
            location = fileLocation.path
            title = fileLocation.lastPathComponent
            webView.allowsBackForwardNavigationGestures = false
            pageLoaded = false
        } else if url.isFileURL {
            // A local file the web view loaded itself: the HTML page this pane
            // was opened with, or one its links led to. Whatever the extension
            // says, WebKit — not our template — is what is rendering it, so
            // the pane is in `.html` mode by definition.
            let file = Self.sameFile(url, as: fileURL) ? (fileURL ?? url) : url
            mode = .html(file)
            location = file.path
            title = file.lastPathComponent
            webView.allowsBackForwardNavigationGestures = true
            leftTemplatePage()
            // Follow the file the pane actually landed on, so a link from one
            // local page to another keeps live-reloading the right one.
            startWatchingFile()
        } else if url.scheme == "http" || url.scheme == "https" || url.scheme == "about" {
            mode = .web(url)
            location = url.absoluteString
            webView.allowsBackForwardNavigationGestures = true
            leftTemplatePage()
        }
        currentURL = addressText(for: url)
    }

    /// The template page is off screen. Whatever it was rendering — a
    /// document's headings, a diff's file tree — is not what the pane is
    /// showing any more, and nothing will arrive to say so (the bridge only
    /// exists inside our template). `fileLocation`/`diffSpec` survive, so
    /// Back over this boundary re-renders it.
    private func leftTemplatePage() {
        clearTOC()
        stopWatchingDiff()
        diffFiles = []
        diffRows = []
        activeDiffFileID = nil
    }

    /// Whether two file URLs name the same file on disk. WebKit hands back a
    /// symlink-resolved URL for a file load (`/var/…` becomes `/private/var/…`
    /// on macOS), and letting that churn `location` would follow the pane into
    /// the session manifest and out of `+list`.
    private static func sameFile(_ lhs: URL?, as rhs: URL?) -> Bool {
        guard let lhs, let rhs, lhs.isFileURL, rhs.isFileURL else { return false }
        return lhs.resolvingSymlinksInPath().standardizedFileURL
            == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A fresh navigation can drop pageZoom; reapply so keyboard zoom sticks
        // as the user follows links / types addresses within the pane (all
        // modes). Cheap no-op at 100%.
        if zoomFactor != 1.0 { pushZoomToWebView() }
        if case .web = mode { return }
        pageLoaded = true
        // An HTML file IS the page — there is no template to inject into, and
        // calling into `window.__viewer` on someone else's document would only
        // throw. (Unless the load failed and we fell back to the template, in
        // which case it is up and waiting for its error card.)
        if case .html = mode, !showingTemplatePage { return }
        renderFileContent()
        // A reload/renavigation resets the document, taking the body padding
        // the TOC gutter relies on with it.
        pushSidePanelGutter()
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

        // A `ghoztty://` link is Ghoztty addressing itself: handle it here, in
        // process, and never navigate. This comes FIRST — ahead of the live-page
        // allow below — for two reasons. WebKit cannot load the scheme at all,
        // so an allowed navigation is a dead click; and handing it to
        // LaunchServices instead would route it to whichever BUILD registered
        // the scheme, so a link clicked in a debug build's pane would raise a
        // window in the release app. Handled here it always means "this app".
        if GhozttyURLScheme.handles(url) {
            decisionHandler(.cancel)
            GhozttyURLScheme.handle(url)
            return
        }

        // Websites navigate freely within the pane — and so does a local HTML
        // file, which is a page in every way that matters. Its links behave
        // exactly as they would if the folder were served over http, which is
        // how these mocks and prototypes had to be viewed before.
        //
        // The ONE exception is a link the user clicked that leads out of the
        // page's own origin (see `isExternalLivePageLink`): Ghoztty's WKWebView
        // keeps its own cookie store, so a hop to another site renders
        // logged-out here, and the browser is where that session lives. It
        // leaves through the SAME scheme a banner link does — plain click to
        // the system, Cmd to a side pane, Cmd-Shift to a surface of its own —
        // so there is one modifier scheme across every link surface.
        //
        // Narrowly gated on a main-frame `.linkActivated`: a page's own
        // redirects, form posts, script navigations, iframe loads, and
        // subresource fetches are the page's business, not the user's click.
        if isLivePage {
            if navigationAction.navigationType == .linkActivated,
               navigationAction.targetFrame?.isMainFrame == true,
               Self.isExternalLivePageLink(from: webView.url, to: url) {
                decisionHandler(.cancel)
                BannerLinkOpener(anchor: self).perform(
                    BannerLinkOpener.action(for: url, modifiers: navigationAction.modifierFlags),
                    on: url)
                return
            }
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
    /// - relative/local markdown or HTML file → new viewer split next to this
    ///   pane (both are things a viewer can now render)
    /// - other local files → open with the default app
    private func handleFileModeLink(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return
        }

        // Relative links render as ghoztty-viewer:// URLs; `resolvedLinkURL`
        // maps them back to a real file next to the viewed file, and passes
        // file:// links (markdown-it linkify or explicit file URLs) straight
        // through. Anything else is a scheme this pane has nothing to do with.
        guard let fileURL = resolvedLinkURL(for: url), fileURL.isFileURL else { return }

        switch Self.mode(for: fileURL.path) {
        case .markdown, .html:
            openViewerSplit(location: fileURL.path)
        default:
            NSWorkspace.shared.open(fileURL)
        }
    }

    /// Whether a link clicked in a LIVE-PAGE viewer (a website, or a local HTML
    /// file, both of which own their own navigation) leads OUT of the page's
    /// own origin, and so belongs somewhere other than this pane.
    ///
    /// "Origin" here is deliberately NOT the web platform's origin. That one
    /// decides what a script may read; this one decides where a PERSON wants a
    /// page to open, and the two want different rules:
    ///
    /// - **http(s) → http(s):** the same **host**, and the same **port as
    ///   written**. The scheme is excluded on purpose, so an `http` → `https`
    ///   upgrade on the same host — the most common same-site hop there is —
    ///   keeps navigating in the pane. The port is included on purpose:
    ///   `localhost:3000` → `localhost:5173` is a hop between two different dev
    ///   servers. A subdomain is a different host and therefore external, which
    ///   is what "a link out to another site" means to a person.
    /// - **file:// → file://:** inside the page's own directory, recursively —
    ///   exactly the read grant `loadFileURL(_:allowingReadAccessTo:)` gave the
    ///   pane, so a scaffolded mock clicks through its own pages while a link
    ///   reaching UP out of the folder (which this pane could never load) stops
    ///   being a dead click. Existence is not checked: a link to a missing
    ///   sibling is the page's own broken link and should get the page's own
    ///   error, not Finder.
    /// - **Across those two families** — a local mock linking to github.com, a
    ///   dev server linking to a `file://` path — there is no shared origin at
    ///   all, so the link is external.
    /// - **Every other scheme** (`javascript:`, `data:`, `blob:`, `about:`,
    ///   `mailto:`, some app's custom scheme) is left exactly as it is today and
    ///   followed in the pane. `javascript:` links are ordinary page machinery,
    ///   and handing an arbitrary scheme to `NSWorkspace` would resolve it to
    ///   whatever handler happens to be registered — the same reason
    ///   `popupDestination(for:modifiers:)` guards its scheme.
    static func isExternalLivePageLink(from page: URL?, to link: URL) -> Bool {
        guard let page else { return false }
        if let pageSite = Self.site(of: page) {
            // A web page. Another site is external; a `file://` link is too
            // (WebKit refuses that navigation outright, so following it in the
            // pane is a dead click).
            guard let linkSite = Self.site(of: link) else { return link.isFileURL }
            return pageSite != linkSite
        }
        guard page.isFileURL else { return false }
        if Self.site(of: link) != nil { return true }
        guard link.isFileURL else { return false }
        return !Self.path(link, isUnder: page.deletingLastPathComponent())
    }

    /// A live page's site: its host plus the port as written, or nil when it is
    /// not an http(s) location at all. A default port is dropped so
    /// `http://x.com:80` and `https://x.com` are the same site.
    private static func site(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        guard let port = url.port,
              port != (scheme == "http" ? 80 : 443)
        else { return host }
        return "\(host):\(port)"
    }

    /// Whether `url` names a path inside `directory`. Purely by path: this
    /// decides where a link opens, not whether a file can be served, so a link
    /// to a not-yet-existing sibling still counts as inside the page's folder.
    private static func path(_ url: URL, isUnder directory: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return target == root || target.hasPrefix(root + "/")
    }

    /// The real destination a clicked link names. A relative link inside the
    /// render template arrives as a `ghoztty-viewer://` URL — an implementation
    /// detail of how the page is served — so it maps back to the file it names;
    /// every other link already IS its destination.
    ///
    /// Nil only when a template link names a file that is not there, which is
    /// also exactly what a left-click on it does: nothing.
    func resolvedLinkURL(for url: URL) -> URL? {
        guard url.scheme == ViewerSchemeHandler.scheme else { return url }
        return schemeHandler?.resolveForNavigation(String(url.path.dropFirst()))
    }

    /// Open another viewer as a split next to this pane.
    private func openViewerSplit(location: String) {
        guard let controller = window?.windowController as? BaseTerminalController,
              let myPane = controller.surfaceTree.first(where: { $0.viewerView === self })
        else { return }
        controller.newViewerSplit(
            atPane: myPane,
            direction: .right,
            // A pane opened from a link in this one inherits this one's
            // origin, so a chain of doc links keeps filing feedback to the
            // same repo.
            viewer: ViewerView(location: location, originDirectory: originDirectory))
    }
}

// MARK: - WKUIDelegate

extension ViewerView: WKUIDelegate {
    /// Where a `window.open()` / `target="_blank"` request ends up.
    enum PopupDestination: Equatable {
        /// Hand the URL to the system default browser and cancel the popup.
        case defaultBrowser(URL)
        /// A `ghoztty://` command: run it in process and cancel the popup.
        case ghozttyCommand(URL)
        /// Open it as its own Ghoztty viewer window.
        case ghosttyWindow
    }

    /// A popup carrying an `http(s)` URL leaves for the default browser. Two
    /// things keep it in Ghoztty: a Cmd-held click (the deliberate escape
    /// hatch), and anything the browser could not be handed — a bare
    /// `window.open()` with no URL, where the script writes into the returned
    /// window itself, or a non-web scheme, which `NSWorkspace` would resolve to
    /// some arbitrary handler.
    static func popupDestination(
        for url: URL?,
        modifiers: NSEvent.ModifierFlags
    ) -> PopupDestination {
        // A `ghoztty://` link is a command, not a destination, and it outranks
        // the Cmd modifier: there is nothing to put in a window. Without this
        // it fell through to `.ghosttyWindow` as a "non-web scheme" and a
        // `target="_blank"` focus link OPENED A VIEWER WINDOW pointed at the
        // command — window creation from the one scheme that must never create
        // anything.
        if let url, GhozttyURLScheme.handles(url) { return .ghozttyCommand(url) }
        guard !modifiers.contains(.command),
              let url,
              url.scheme == "http" || url.scheme == "https"
        else { return .ghosttyWindow }
        return .defaultBrowser(url)
    }

    /// A page called `window.open()` or activated a `target="_blank"` link. A
    /// web URL goes to the **system default browser** and the popup is
    /// cancelled: Ghoztty's `WKWebView` has its own cookie store with no
    /// relationship to Safari or Chrome, so an authenticated site opened here
    /// renders logged-out and a sign-in flow never completes.
    ///
    /// This reverses the earlier decision that a popup should become its own
    /// Ghoztty window precisely so an OAuth popup could `window.close()` itself
    /// and hand a session back to the opener page. The tradeoff is accepted: a
    /// popup that lands in the browser can no longer return a session to the
    /// Ghoztty page that opened it — but that flow was not authenticating in
    /// the first place, so there was never a session to hand back.
    ///
    /// `popupDestination(for:modifiers:)` decides; on its `.ghosttyWindow` path
    /// the returned web view MUST be one built from `configuration` (WebKit's
    /// own object): WebKit drives the navigation on it and keeps the
    /// opener↔popup relationship. Building our own web view and loading the
    /// request ourselves would break `window.close()`. Returning nil cancels
    /// the popup.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        switch Self.popupDestination(
            for: navigationAction.request.url,
            modifiers: navigationAction.modifierFlags) {
        case .defaultBrowser(let url):
            NSWorkspace.shared.open(url)
            return nil
        case .ghozttyCommand(let url):
            GhozttyURLScheme.handle(url)
            return nil
        case .ghosttyWindow:
            break
        }

        // Without a host controller there is nowhere to put a window; drop the
        // popup rather than leak an unparented web view.
        guard let controller = window?.windowController as? BaseTerminalController
        else { return nil }

        // Build the popup's web view from WebKit's configuration and hand it to
        // a new viewer that adopts (never reloads) it.
        let popupWebView = WKWebView(frame: .zero, configuration: configuration)
        let popup = ViewerView(
            adopting: popupWebView,
            url: navigationAction.request.url,
            // A popup inherits its opener's origin, so feedback filed from it
            // still lands in the same repo when the destination can't be
            // derived from the popup's own (often remote) location.
            originDirectory: originDirectory)

        // Honor the size the opener asked for. Sign-in / OAuth popups open at a
        // deliberate small size via `window.open(url, name, "width=…,height=…")`
        // and look broken at a full terminal-window size. `newWindow(tree:)`
        // sizes the window's content to the tree leaf's view bounds, so stamp
        // the requested size onto the popup view before wrapping it; a page that
        // requests no size just cascades at the default like any new window.
        if let width = windowFeatures.width?.doubleValue,
           let height = windowFeatures.height?.doubleValue,
           width > 0, height > 0 {
            popup.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }

        let pane = PaneView(viewer: popup)
        let newController = TerminalController.newWindow(
            controller.ghostty,
            tree: SplitTree<PaneView>(root: .leaf(view: pane), zoomed: nil))
        // A viewer-only window has no focused surface to title it, so pin the
        // popup's title the same way the `+new-window --view` path does.
        newController.titleOverride = pane.title

        // WebKit navigates the returned web view itself — do not load it here.
        return popupWebView
    }

    /// The popup page called `window.close()` (e.g. an OAuth flow finishing).
    /// Close this viewer's own pane: for the single-pane popup window that is
    /// the whole window, matching browser semantics; if the user has since
    /// split it, only the popup pane goes. Viewers own no process, so there is
    /// nothing to confirm.
    func webViewDidClose(_ webView: WKWebView) {
        guard let controller = window?.windowController as? BaseTerminalController,
              let pane = controller.surfaceTree.first(where: { $0.viewerView === self }),
              let node = controller.surfaceTree.root?.node(view: pane)
        else { return }
        controller.closeSurface(node, withConfirmation: false)
    }
}

// MARK: - Link anchor

/// A viewer pane is a link surface too: the links on its page use the same
/// actions, modifier scheme, and right-click menu a banner's do.
extension ViewerView: LinkAnchor {
    var anchorWindow: NSWindow? { window }

    func anchorPane(in tree: SplitTree<PaneView>) -> PaneView? {
        tree.first(where: { $0.viewerView === self })
    }

    var anchorDirectory: String? { originDirectory }
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
