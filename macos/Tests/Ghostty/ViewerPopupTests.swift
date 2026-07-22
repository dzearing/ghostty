import AppKit
import Testing
import WebKit
@testable import Ghostty

/// Popup support: `window.open()` / `target="_blank"` in a viewer pane open a
/// new Ghoztty viewer window. These tests cover the two pieces that make that
/// work without needing a full window controller: the UI delegate is actually
/// installed on every viewer (without one WebKit silently drops popups), and a
/// viewer can ADOPT a web view WebKit built rather than creating its own —
/// which is what preserves the opener↔popup link so `window.close()` works.
@MainActor
struct ViewerPopupTests {
    /// Every viewer wires itself as the web view's UI delegate. Without this
    /// `window.open()` and `target="_blank"` do nothing at all.
    @Test func viewerIsItsWebViewsUIDelegate() {
        let viewer = ViewerView(location: ViewerView.blankPage)
        #expect(viewer.webView.uiDelegate === viewer)
        // Sanity: the existing navigation delegate wiring is unchanged.
        #expect(viewer.webView.navigationDelegate === viewer)
    }

    /// A popup adopts the exact web view WebKit created (from its
    /// configuration) instead of building a new one — the contract that keeps
    /// the opener↔popup relationship intact.
    @Test func adoptedPopupWrapsTheGivenWebView() {
        let adopted = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let popup = ViewerView(
            adopting: adopted,
            url: URL(string: "https://example.com/oauth"),
            originDirectory: "/tmp/project")

        #expect(popup.webView === adopted)
        #expect(adopted.uiDelegate === popup)          // chained popups work
        #expect(adopted.navigationDelegate === popup)
        #expect(adopted.superview === popup)           // parented for display
        #expect(popup.isWebURL)
        #expect(popup.location == "https://example.com/oauth")
        #expect(popup.homeLocation == "https://example.com/oauth")
        #expect(popup.originDirectory == "/tmp/project")
    }

    /// A bare `window.open()` with no URL adopts as a blank browser page (the
    /// script writes into it afterwards); the address field shows nothing.
    @Test func adoptedPopupWithoutURLIsBlankPage() {
        let adopted = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let popup = ViewerView(adopting: adopted, url: nil, originDirectory: nil)

        #expect(popup.location == ViewerView.blankPage)
        #expect(popup.isWebURL)
        #expect(popup.currentURL == "")
    }
}
