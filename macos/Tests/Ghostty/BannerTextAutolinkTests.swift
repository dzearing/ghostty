import AppKit
import Testing
@testable import Ghostty

/// End-to-end through the view that actually draws banner links: banner source
/// → parsed runs → TextKit layout → the hit-testing that drives hover, click,
/// and the right-click menu. `BannerMarkdownTests` proves the parse; this
/// proves an autolinked bare URL or file path really is clickable on screen.
@MainActor
struct BannerTextAutolinkTests {
    private static let font = NSFont.systemFont(ofSize: 12)

    /// A laid-out one-line banner view for `source`.
    private func view(_ source: String, cwd: String? = nil) -> BannerTextView {
        let view = BannerTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 40))
        view.configure(
            attributed: Ghostty.BannerMarkdown.parse(source, cwd: cwd),
            baseFont: Self.font,
            lineLimit: 1,
            alignment: .left,
            wraps: false)
        return view
    }

    /// A point on the baseline text `chars` in from the left, in view
    /// coordinates (the view is flipped, so the first line starts at y = 0).
    private func point(after prefix: String) -> CGPoint {
        let x = (prefix as NSString).size(withAttributes: [.font: Self.font]).width
        return CGPoint(x: x + 4, y: 6)
    }

    @Test func bareURLIsClickableInTheRenderedBanner() {
        let view = view("see https://example.com/x now")
        #expect(view.linkURL(at: point(after: "see ")) == URL(string: "https://example.com/x"))
    }

    @Test func proseAroundTheLinkIsNotClickable() {
        let view = view("see https://example.com/x now")
        #expect(view.linkURL(at: point(after: "")) == nil)
        #expect(view.linkURL(at: point(after: "see https://example.com/x ")) == nil)
    }

    @Test func bareFilePathIsClickableInTheRenderedBanner() {
        let view = view("open ./README.md now", cwd: "/tmp/proj")
        let url = view.linkURL(at: point(after: "open "))
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/tmp/proj/README.md")
    }

    @Test func codeSpannedURLIsNotClickable() {
        // The backtick span renders the URL as literal text, so nothing in the
        // line hit-tests as a link.
        let view = view("see `https://example.com/x` now")
        #expect(view.linkURL(at: point(after: "see ")) == nil)
    }
}
