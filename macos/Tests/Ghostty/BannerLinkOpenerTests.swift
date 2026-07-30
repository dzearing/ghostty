import AppKit
import Testing
@testable import Ghostty

/// A banner link is either a web URL or — since bare file paths autolink — a
/// local file, and the two want different actions. These pin the per-kind
/// differences that aren't obvious from the call site: what the right-click
/// menu offers, what "copy" puts on the pasteboard, and what a viewer pane is
/// handed when asked to display the link.
@MainActor
struct BannerLinkOpenerTests {
    private let opener = BannerLinkOpener(surface: nil)

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    @Test func webLinkMenuIsUnchanged() {
        let menu = opener.menu(for: URL(string: "https://example.com")!)
        #expect(titles(menu) == [
            "Open in Side Pane",
            "Open in New Window",
            "-",
            "Open in Default Browser",
            "-",
            "Copy Link",
        ])
    }

    @Test func fileLinkMenuLeadsWithRevealInFinder() {
        // The first item is the left-click default, which for a file path is
        // Reveal in Finder (not a viewer split, as it is for a URL).
        let menu = opener.menu(for: URL(fileURLWithPath: "/tmp/a.md"))
        #expect(titles(menu) == [
            "Reveal in Finder",
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
