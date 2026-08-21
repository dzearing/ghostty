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

    /// Take the pane exactly as offered, however narrow.
    ///
    /// A viewer is a leaf in the split tree just like a terminal: the tree
    /// decides how wide the pane is and the leaf gets no vote. Left to itself
    /// SwiftUI sizes a hosted NSView from its Auto Layout minimum — which the
    /// nav bar, pinned leading-to-trailing inside the pane, floors at its own
    /// row of buttons — and then CENTERS the oversized view in the smaller
    /// frame it was given. Squeeze the pane below that floor and the viewer
    /// spills out both sides, painting over the pane next door and off the
    /// edge of the window.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ViewerView,
        context: Context
    ) -> CGSize? {
        // A concrete proposal is the pane's size and is taken verbatim. Nothing
        // else is: an unspecified or infinite dimension is SwiftUI asking what
        // we would LIKE to be, and the honest answer for a pane is "whatever
        // I'm given", so fall back to the size we already have.
        func resolve(_ proposed: CGFloat?, current: CGFloat) -> CGFloat {
            guard let proposed, proposed.isFinite else { return current }
            return proposed
        }
        return CGSize(
            width: resolve(proposal.width, current: nsView.frame.width),
            height: resolve(proposal.height, current: nsView.frame.height))
    }
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
            if viewerView.sidePanelLayout == .compact {
                Button(action: { viewerView.toggleSidePanel() }) {
                    Image(systemName: viewerView.isDiffMode
                        ? "sidebar.leading" : "list.bullet")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(viewerView.sidePanelOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .help(viewerView.sidePanelOpen
                    ? (viewerView.isDiffMode ? "Hide files" : "Hide contents")
                    : (viewerView.isDiffMode ? "Show files" : "Show contents"))
                .accessibilityLabel(viewerView.isDiffMode
                    ? "Changed files" : "Table of contents")
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

            // Diff controls, in the same 24pt squares as the rest of the bar.
            // They live HERE rather than in a second toolbar because a diff
            // pane pins this bar open anyway (see chromeAlwaysVisible), so a
            // separate strip would be a second permanent row of chrome buying
            // nothing. The bar is a single flexible row, so a narrow pane just
            // gives the address field less width.
            if viewerView.isDiffMode {
                Divider().frame(height: 16).padding(.horizontal, 2)

                Button(action: { viewerView.goToPreviousChange() }) {
                    Image(systemName: "chevron.up")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("Previous change")
                .accessibilityLabel("Previous change")

                Button(action: { viewerView.goToNextChange() }) {
                    Image(systemName: "chevron.down")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("Next change")
                .accessibilityLabel("Next change")

                Button(action: { viewerView.toggleDiffViewStyle() }) {
                    Image(systemName: viewerView.diffViewStyle == .split
                        ? "rectangle.split.2x1" : "list.bullet.rectangle")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(viewerView.diffViewStyle == .split
                    ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .help(viewerView.diffViewStyle == .split
                    ? "Side-by-side — switch to unified"
                    : "Unified — switch to side-by-side")
                .accessibilityLabel("Diff layout")

                Divider().frame(height: 16).padding(.horizontal, 2)
            }

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

            // Feedback, trailing. Present only when the pane's content
            // resolves to a git worktree — with nowhere to file a report, the
            // button would be a lie.
            //
            // Icon only, in the same 24pt square as every other control in
            // this bar: a text label here read as a heading rather than a
            // button and broke the row's rhythm. The destination is not lost —
            // it is on the tooltip, and spelled out in the composer's footer
            // once the toolbar is open, which is when it actually matters.
            if let worktree = viewerView.worktree {
                Button(action: { viewerView.toggleFeedback() }) {
                    Image(systemName: "exclamationmark.bubble")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(
                    viewerView.feedbackOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .help("Send feedback to \(worktree.path)")
                .accessibilityLabel("Send feedback to \(worktree.name)")
                .padding(.leading, 4)
            }
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
        .onChange(of: viewerView.addressRevertRequest) { _ in
            // Escape: the abandoned edit goes away and the field shows where
            // the pane actually is again (ViewerView.cancelAddressEditing has
            // already moved focus to the page).
            urlFocused = false
            urlText = viewerView.currentURL
        }
        .onChange(of: urlFocused) { focused in
            // Select-all-on-focus is handled AppKit-side, where the click
            // that granted focus can be followed to its mouse-up.
            viewerView.addressFieldFocusChanged(focused)
        }
    }

}

/// Liquid Glass on macOS 26+, translucent material bar otherwise, with a
/// hairline bottom edge in both cases. Shared by the nav bar and the feedback
/// composer that slides in beneath it, so the two read as one stack of chrome.
struct ChromeBarBackground: ViewModifier {
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
