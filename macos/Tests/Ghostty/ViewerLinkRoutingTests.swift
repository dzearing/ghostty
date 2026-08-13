import AppKit
import Testing
@testable import Ghostty

/// Where a link clicked in a viewer pane goes, and what its right-click menu
/// offers.
///
/// A live-page viewer (a website or a local HTML file) follows its own links in
/// the pane — that is what makes a dev server at `localhost:3000` and a
/// scaffolded mock usable. The one exception is a link that leads OUT of the
/// page's own origin: Ghoztty's `WKWebView` keeps its own cookie store, so
/// another site renders logged-out here. These pin that origin rule, which is
/// deliberately not the web platform's (see `isExternalLivePageLink`), and pin
/// that the viewer's link menu is `BannerLinkOpener`'s rather than a fork.
@MainActor
struct ViewerLinkRoutingTests {
    private func url(_ string: String) -> URL { URL(string: string)! }
    private func external(_ page: String, _ link: String) -> Bool {
        ViewerView.isExternalLivePageLink(from: url(page), to: url(link))
    }

    // MARK: - Same site, http(s)

    @Test func aLinkWithinTheSameHostIsFollowedInThePane() {
        // The primary use case: clicking through a dev server's own pages.
        #expect(!external("http://localhost:3000/", "http://localhost:3000/settings"))
        #expect(!external("https://example.com/a", "https://example.com/b/c?q=1#frag"))
    }

    @Test func anHTTPToHTTPSUpgradeOnTheSameHostIsNotExternal() {
        // The most common same-site hop there is. Scheme is excluded from the
        // comparison precisely so this keeps navigating in the pane.
        #expect(!external("http://example.com/a", "https://example.com/b"))
        #expect(!external("https://example.com/a", "http://example.com/b"))
    }

    @Test func hostComparisonIgnoresCase() {
        #expect(!external("https://Example.COM/a", "https://example.com/b"))
    }

    // MARK: - Cross site, http(s)

    @Test func aLinkToAnotherSiteLeavesForTheBrowser() {
        #expect(external("https://app.example.com/x", "https://github.com/org/repo"))
    }

    @Test func aSubdomainIsADifferentSite() {
        // "A link out to another site" is what a user means by a different
        // host, and docs.example.com is a different host.
        #expect(external("https://example.com/a", "https://docs.example.com/a"))
    }

    @Test func aDifferentPortIsADifferentDevServer() {
        // localhost:3000 → localhost:5173 is a hop between two dev servers;
        // following it in the pane is the surprise, not the convenience.
        #expect(external("http://localhost:3000/", "http://localhost:5173/"))
        #expect(!external("http://localhost:3000/a", "http://localhost:3000/b"))
    }

    // MARK: - Local HTML pages

    @Test func aPathInsideTheLocalPagesFolderIsFollowedInThePane() {
        // The pane's read grant is the file's own directory, recursively — a
        // scaffolded mock clicking through its own pages.
        #expect(!external("file:///tmp/mock/index.html", "file:///tmp/mock/about.html"))
        #expect(!external("file:///tmp/mock/index.html", "file:///tmp/mock/deep/page.html"))
    }

    @Test func aLocalPageReachingOutOfItsFolderIsExternal() {
        // Outside the read grant, so the pane could never load it anyway.
        #expect(external("file:///tmp/mock/index.html", "file:///tmp/shared/page.html"))
        // A sibling directory that merely shares a name prefix is still out.
        #expect(external("file:///tmp/mock/index.html", "file:///tmp/mockup/page.html"))
    }

    @Test func aLocalMockLinkingToAWebsiteLeavesForTheBrowser() {
        #expect(external("file:///tmp/mock/index.html", "https://github.com/org/repo"))
    }

    @Test func aWebsiteLinkingToALocalFileIsExternal() {
        // WebKit refuses the navigation outright, so following it in the pane
        // is a dead click.
        #expect(external("http://localhost:3000/", "file:///tmp/notes.md"))
    }

    // MARK: - Schemes we deliberately never route

    @Test func pageMachinerySchemesStayInThePane() {
        // `javascript:` links are ordinary page machinery, and handing an
        // arbitrary scheme to NSWorkspace would resolve it to some registered
        // handler — the same reason `popupDestination(for:modifiers:)` guards
        // its scheme.
        for link in ["javascript:void(0)", "data:text/html,x", "about:blank",
                     "mailto:someone@example.com", "blob:https://example.com/abc"] {
            #expect(!external("https://example.com/a", link), "\(link) should stay in the pane")
        }
    }

    @Test func anUnknownPageLocationNeverMakesALinkExternal() {
        // No origin to compare against: leave the page's navigation alone.
        #expect(!ViewerView.isExternalLivePageLink(
            from: nil, to: url("https://github.com")))
        #expect(!external("about:blank", "https://github.com"))
    }

    // MARK: - The menu

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    @Test func aViewerAnchorsTheBannerMenuRatherThanAForkOfIt() {
        // One menu, one modifier scheme, one place the ordering contract lives
        // (first item = the left-click default).
        let viewer = ViewerView(location: "/tmp/mock/index.html", originDirectory: "/tmp/repo")
        let opener = BannerLinkOpener(anchor: viewer)
        #expect(titles(opener.menu(for: url("https://example.com"))) == [
            "Open in Default Browser",
            "-",
            "Open in Side Pane",
            "Open in New Window",
            "-",
            "Copy Link",
        ])
    }

    @Test func aViewerAnchorHandsOnItsOriginDirectory() {
        // A pane opened from a viewer link inherits the origin, so a chain of
        // doc links keeps filing feedback to the same repo.
        let viewer = ViewerView(location: "/tmp/mock/index.html", originDirectory: "/tmp/repo")
        #expect(viewer.anchorDirectory == "/tmp/repo")
    }

    // MARK: - What the menu is built for

    @Test func aRelativeTemplateLinkResolvesToTheFileItNames() throws {
        // Relative links in a rendered markdown doc are `ghoztty-viewer://`
        // URLs; the menu must offer file actions for the file they name, not
        // web actions for an internal scheme.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = directory.appendingPathComponent("index.md")
        try "# hi".write(to: doc, atomically: true, encoding: .utf8)
        let sibling = directory.appendingPathComponent("other.md")
        try "# there".write(to: sibling, atomically: true, encoding: .utf8)

        let viewer = ViewerView(location: doc.path)
        let resolved = viewer.resolvedLinkURL(for: url("ghoztty-viewer://page/other.md"))
        #expect(resolved?.lastPathComponent == "other.md")
        #expect(resolved?.isFileURL == true)
    }

    @Test func aWebLinkIsMenuedAsItself() {
        let viewer = ViewerView(location: ViewerView.blankPage)
        #expect(viewer.resolvedLinkURL(for: url("https://example.com/x"))
            == url("https://example.com/x"))
    }

    @Test func aTemplateLinkToAMissingFileHasNoMenu() {
        // Nothing to act on. A left-click on it does nothing either, so a
        // right-click that offers destinations would be the odd one out.
        let viewer = ViewerView(location: "/tmp/does-not-exist-\(UUID().uuidString)/index.md")
        #expect(viewer.resolvedLinkURL(for: url("ghoztty-viewer://page/nope.md")) == nil)
    }
}
