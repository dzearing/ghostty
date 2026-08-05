import AppKit
import Testing
import WebKit
@testable import Ghostty

/// Popup support: `window.open()` / `target="_blank"` in a viewer pane hand a
/// web URL to the system default browser, and otherwise open a new Ghoztty
/// viewer window. These tests cover the pieces that work without a full window
/// controller: where a popup is routed, that the UI delegate is actually
/// installed on every viewer (without one WebKit silently drops popups), and
/// that a viewer can ADOPT a web view WebKit built rather than creating its
/// own — which is what preserves the opener↔popup link so `window.close()`
/// works on the in-Ghoztty path.
@MainActor
struct ViewerPopupTests {
    /// The default: a popped-open web URL leaves for the browser, where the
    /// user's cookies actually are.
    @Test func aWebPopupIsHandedToTheDefaultBrowser() {
        let url = URL(string: "https://example.com/oauth")!
        #expect(ViewerView.popupDestination(for: url, modifiers: []) == .defaultBrowser(url))
    }

    /// Cmd-click is the escape hatch that keeps the popup in Ghoztty.
    @Test func commandClickKeepsAPopupInGhoztty() {
        let url = URL(string: "https://example.com/oauth")!
        #expect(ViewerView.popupDestination(for: url, modifiers: .command) == .ghosttyWindow)
    }

    /// A bare `window.open()` has no URL to hand over — the script writes into
    /// the returned window itself — so it must not degrade to a dead click.
    @Test func aPopupWithNoURLStaysInGhoztty() {
        #expect(ViewerView.popupDestination(for: nil, modifiers: []) == .ghosttyWindow)
    }

    /// Guard the scheme rather than handing `NSWorkspace` whatever comes
    /// through, which would resolve to some arbitrary registered handler.
    @Test func aNonWebPopupIsNeverHandedToTheSystem() {
        #expect(ViewerView.popupDestination(
            for: URL(string: "mailto:someone@example.com")!, modifiers: []) == .ghosttyWindow)
        #expect(ViewerView.popupDestination(
            for: URL(string: "about:blank")!, modifiers: []) == .ghosttyWindow)
    }

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
