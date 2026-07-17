import SwiftUI

/// SwiftUI leaf for a viewer pane inside the split tree. Placeholder chrome
/// for now; the WKWebView representable replaces the body in T04.
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
