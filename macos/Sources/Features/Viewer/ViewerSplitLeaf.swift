import SwiftUI

/// SwiftUI leaf for a viewer pane inside the split tree. Every viewer pane
/// gets a chrome bar mounted by ViewerView itself as an NSHostingView — it
/// peeks in (animated) on mouse-over of the thin strip at the pane top and
/// auto-hides after inactivity. While visible the bar reserves its space
/// (the web view is inset below it), so top-of-page content is never
/// covered. Every pane — website or rendered file — gets the same
/// back/forward/reload/home controls and an editable address field.
struct ViewerSplitLeaf: View {
    @ObservedObject var viewerView: ViewerView

    var body: some View {
        ViewerRepresentable(viewerView: viewerView)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Viewer pane")
    }
}

/// Bridges the ViewerView (an NSView) into SwiftUI.
private struct ViewerRepresentable: NSViewRepresentable {
    let viewerView: ViewerView

    func makeNSView(context: Context) -> ViewerView {
        viewerView
    }

    func updateNSView(_ nsView: ViewerView, context: Context) {}
}

/// Chrome bar for viewer panes: anchored flush to the pane top, stretched
/// full width. Uses Liquid Glass on macOS 26+ (translucent material fallback)
/// so it feels native. Hosted by ViewerView in an NSHostingView; revealed on
/// mouse-over at the pane top, auto-hidden after inactivity. The web view
/// is inset below the bar while it shows, so the bar never covers content.
/// Every viewer mode gets the same interactive toolbar (back/forward/reload/
/// home + an editable address field): a markdown pane is a page you can
/// navigate away from and come home to, not a dead end.
struct WebChromeBar: View {
    @ObservedObject var viewerView: ViewerView

    @State private var urlText: String = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        chrome
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .modifier(ChromeBarBackground())
            .onHover { viewerView.holdChrome($0) }
    }

    /// One bar for every viewer mode: back/forward/reload/home + an
    /// editable, submittable address field. A file viewer is not a dead end —
    /// typing a URL into it navigates the pane to the web, and Home brings it
    /// back to the file it was opened with.
    private var chrome: some View {
        HStack(spacing: 4) {
            // Contents toggle, leading. Only in the compact TOC layout: a
            // wide pane shows the card in its gutter permanently, so there
            // is nothing to toggle. While this is present the bar stops
            // auto-hiding (see ViewerView.chromeAlwaysVisible) — it would be
            // useless otherwise.
            if viewerView.tocLayout == .compact {
                Button(action: { viewerView.toggleTOCPanel() }) {
                    Image(systemName: "list.bullet")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(viewerView.tocPanelOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .help(viewerView.tocPanelOpen ? "Hide contents" : "Show contents")
                .accessibilityLabel("Table of contents")
            }

            Button(action: { viewerView.goBack() }) {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .disabled(!viewerView.canGoBack)
            .help("Back")

            Button(action: { viewerView.goForward() }) {
                Image(systemName: "chevron.right")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .disabled(!viewerView.canGoForward)
            .help("Forward")

            Button(action: { viewerView.reloadPage() }) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .help("Reload")

            Button(action: { viewerView.goHome() }) {
                Image(systemName: "house")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .help("Home — back to \(viewerView.homeLocation)")

            TextField("Enter URL", text: $urlText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($urlFocused)
                .onSubmit {
                    viewerView.navigate(to: urlText)
                    urlFocused = false
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .padding(.leading, 4)
        }
        .onAppear {
            urlText = viewerView.currentURL
            // A pane opened blank by "Open Browser Pane" asks for the caret
            // before this bar exists, so the request is also honored here.
            if viewerView.addressFocusRequest > 0 { urlFocused = true }
        }
        .onChange(of: viewerView.currentURL) { newValue in
            // Never overwrite an address the user is part-way through typing.
            if !urlFocused { urlText = newValue }
        }
        .onChange(of: viewerView.addressFocusRequest) { _ in urlFocused = true }
        .onChange(of: urlFocused) { focused in
            // Select-all-on-focus is handled AppKit-side, where the click
            // that granted focus can be followed to its mouse-up.
            viewerView.addressFieldFocusChanged(focused)
        }
    }

}

/// Liquid Glass on macOS 26+, translucent material bar otherwise, with a
/// hairline bottom edge in both cases.
private struct ChromeBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .rect)
            } else {
                content.background(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }
}
