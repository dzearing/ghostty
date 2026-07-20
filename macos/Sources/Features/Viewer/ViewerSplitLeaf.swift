import SwiftUI

/// SwiftUI leaf for a viewer pane inside the split tree. Web panes get a
/// floating browser chrome bar (back/forward/reload + URL field) mounted by
/// ViewerView itself as an NSHostingView above the web view — it reveals on
/// mouse-over near the top of the pane and auto-hides after inactivity so
/// the content keeps the space.
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

/// Browser toolbar for web viewer panes: anchored flush to the pane top,
/// stretched full width — buttons left, the URL field filling the rest.
/// Uses Liquid Glass on macOS 26+ (translucent material fallback) so it
/// feels native. Hosted by ViewerView in an NSHostingView layered above
/// the WKWebView; revealed on mouse-over near the pane top, auto-hidden
/// after inactivity.
struct WebChromeBar: View {
    @ObservedObject var viewerView: ViewerView

    @State private var urlText: String = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
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
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .modifier(ChromeBarBackground())
        .onAppear { urlText = viewerView.currentURL }
        .onChange(of: viewerView.currentURL) { newValue in
            if !urlFocused { urlText = newValue }
        }
        .onHover { viewerView.holdChrome($0) }
        .onChange(of: urlFocused) { viewerView.holdChrome($0) }
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
