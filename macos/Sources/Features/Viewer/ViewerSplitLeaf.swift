import SwiftUI

/// SwiftUI leaf for a viewer pane inside the split tree. Every viewer pane
/// gets a chrome bar mounted by ViewerView itself as an NSHostingView — it
/// peeks in (animated) on mouse-over of the thin strip at the pane top and
/// auto-hides after inactivity. While visible the bar reserves its space
/// (the web view is inset below it), so top-of-page content is never
/// covered. Web panes show back/forward/reload + an editable URL field;
/// file panes (markdown/code) show a read-only, selectable file:// address.
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
/// Web panes get an interactive toolbar (back/forward/reload + an editable
/// URL field); file panes (markdown/code) get a read-only, selectable
/// file:// address so the pane reads like any other page — just not navigable.
struct WebChromeBar: View {
    @ObservedObject var viewerView: ViewerView

    @State private var urlText: String = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        Group {
            if viewerView.isWebURL {
                webChrome
            } else {
                fileChrome
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .modifier(ChromeBarBackground())
        .onHover { viewerView.holdChrome($0) }
    }

    /// Web: back/forward/reload + an editable, submittable URL field.
    private var webChrome: some View {
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
        .onAppear { urlText = viewerView.currentURL }
        .onChange(of: viewerView.currentURL) { newValue in
            if !urlFocused { urlText = newValue }
        }
        .onChange(of: urlFocused) { focused in
            viewerView.holdChrome(focused)
            // Browser convention: clicking into the address bar selects the
            // whole URL. Deferred so it runs after the click's own caret
            // placement; the first responder is the field's editor by then.
            if focused {
                DispatchQueue.main.async {
                    (viewerView.window?.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
        }
    }

    /// File (markdown/code): a read-only, selectable file:// address with a
    /// leading document glyph — no navigation controls (a file viewer never
    /// browses). Long paths truncate in the middle so the filename stays legible.
    private var fileChrome: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            Text(viewerView.currentURL)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .padding(.leading, 4)
                .help(viewerView.currentURL)
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
