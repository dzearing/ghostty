import AppKit
import Testing
@testable import Ghostty

/// A banner link is either a web URL or — since bare file paths autolink — a
/// local file, and the two want different actions. These pin the modifier
/// scheme and the per-kind differences that aren't obvious from the call site:
/// what a click does, what the right-click menu offers, what "copy" puts on
/// the pasteboard, and what a viewer pane is handed to display the link.
@MainActor
struct BannerLinkOpenerTests {
    private let opener = BannerLinkOpener(surface: nil)
    private let web = URL(string: "https://example.com")!
    private let file = URL(fileURLWithPath: "/tmp/a.md")

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    // MARK: - Click routing

    @Test func plainClickOnAWebLinkGoesToTheDefaultBrowser() {
        // Not a viewer split: Ghoztty's WKWebView has its own cookie store, so
        // an authenticated site renders logged-out in a pane.
        #expect(BannerLinkOpener.action(for: web, modifiers: []) == .openWithSystem)
    }

    @Test func plainClickOnAFilePathStillOnlyRevealsIt() {
        // A click must never launch whatever app claims the extension.
        #expect(BannerLinkOpener.action(for: file, modifiers: []) == .revealInFinder)
    }

    @Test func commandClickOpensEitherKindInASidePane() {
        #expect(BannerLinkOpener.action(for: web, modifiers: .command) == .openInSidePane)
        #expect(BannerLinkOpener.action(for: file, modifiers: .command) == .openInSidePane)
    }

    @Test func commandShiftClickGivesTheLinkASurfaceOfItsOwn() {
        // For a URL that's a new Ghoztty window; for a file it's the app that
        // owns it, since a viewer can display a file but never edit one.
        #expect(BannerLinkOpener.action(for: web, modifiers: [.command, .shift])
            == .openInNewWindow)
        #expect(BannerLinkOpener.action(for: file, modifiers: [.command, .shift])
            == .openWithSystem)
    }

    @Test func modifiersWithoutCommandAreAPlainClick() {
        // Shift on its own isn't part of the scheme; it must not swallow the
        // click or route it somewhere surprising.
        #expect(BannerLinkOpener.action(for: web, modifiers: [.shift, .option])
            == .openWithSystem)
        #expect(BannerLinkOpener.action(for: file, modifiers: [.shift, .option])
            == .revealInFinder)
    }

    // MARK: - Menu

    @Test func webLinkMenuLeadsWithTheDefaultBrowser() {
        // The first item is by contract the left-click default. The browser is
        // also the only system handoff for a URL, so it appears exactly once.
        #expect(titles(opener.menu(for: web)) == [
            "Open in Default Browser",
            "-",
            "Open in Side Pane",
            "Open in New Window",
            "-",
            "Copy Link",
        ])
    }

    @Test func fileLinkMenuLeadsWithRevealInFinder() {
        // Same contract: for a file path the left-click default is Reveal in
        // Finder, and Open with Default App stays as its own (Cmd-Shift) item.
        #expect(titles(opener.menu(for: file)) == [
            "Reveal in Finder",
            "-",
            "Open in Side Pane",
            "Open in New Window",
            "-",
            "Open with Default App",
            "-",
            "Copy Path",
        ])
    }

    @Test func copyingAFileLinkYieldsAPlainPath() {
        // `file:///tmp/a b.md` is useless in a shell or another editor.
        #expect(opener.pasteboardString(for: URL(fileURLWithPath: "/tmp/a b.md"))
            == "/tmp/a b.md")
    }

    @Test func copyingAWebLinkYieldsTheFullURL() {
        #expect(opener.pasteboardString(for: URL(string: "https://example.com/x")!)
            == "https://example.com/x")
    }

    @Test func viewerLocationForAFileIsAPathNotAFileURL() {
        // `ViewerView.mode(for:)` reads a non-http location as a literal
        // filesystem path, so handing it "file:///tmp/a.md" would look for a
        // file of that name.
        #expect(opener.viewerLocation(for: URL(fileURLWithPath: "/tmp/a.md")) == "/tmp/a.md")
    }

    @Test func viewerLocationForAWebURLIsTheFullURL() {
        #expect(opener.viewerLocation(for: URL(string: "https://example.com/x")!)
            == "https://example.com/x")
    }
}
