import AppKit
import Combine
import GhosttyKit

/// A single leaf pane in a window's split tree: either a terminal surface or
/// a non-terminal viewer (markdown/text/website). This is the ViewType stored
/// in `SplitTree<PaneView>`.
///
/// IMPORTANT: PaneView is never installed in the NSView hierarchy. SwiftUI
/// mounts the *content* view directly (the SurfaceView via SurfaceWrapper, or
/// the ViewerView via its representable). PaneView subclasses NSView only to
/// satisfy SplitTree's ViewType constraint; geometry queries (`bounds`)
/// forward to the mounted content view so split resize math stays correct.
final class PaneView: NSView, Codable, Identifiable, ObservableObject {
    enum Content {
        case terminal(Ghostty.SurfaceView)
        case viewer(ViewerView)
    }

    let content: Content

    /// Stable identity. For terminal panes this mirrors the surface's UUID so
    /// lookups keyed by a surface id (focus restore, undo) keep working.
    let id: UUID

    // Published mirrors of content state. These exist so per-leaf keypath
    // subscriptions (SplitTree.valuesPublisher aggregation of bell/activity,
    // window title tracking) work uniformly across pane kinds.
    @Published private(set) var title: String = ""
    @Published private(set) var bell: Bool = false
    @Published private(set) var activityState: Ghostty.ActivityState = .idle
    @Published private(set) var paneBanner: String?

    var surfaceView: Ghostty.SurfaceView? {
        if case .terminal(let view) = content { return view }
        return nil
    }

    var viewerView: ViewerView? {
        if case .viewer(let view) = content { return view }
        return nil
    }

    /// The NSView that is actually mounted in the window for this pane.
    var contentView: NSView {
        switch content {
        case .terminal(let view): return view
        case .viewer(let view): return view
        }
    }

    /// The libghostty surface backing this pane, if it is a terminal.
    var surface: ghostty_surface_t? { surfaceView?.surface }

    /// Viewers never require close confirmation (nothing is running).
    var needsConfirmQuit: Bool { surfaceView?.needsConfirmQuit ?? false }

    /// Viewers have no child process; treat them as never-exited.
    var processExited: Bool { surfaceView?.processExited ?? false }

    var pwd: String? { surfaceView?.pwd }

    /// Forward geometry to the mounted content view (see class doc).
    override var bounds: NSRect {
        get { contentView.bounds }
        set {}
    }

    /// Forward to the mounted content view's window; PaneView itself is
    /// never installed in a window.
    override var window: NSWindow? { contentView.window }

    init(_ content: Content) {
        self.content = content
        switch content {
        case .terminal(let view): self.id = view.id
        case .viewer: self.id = UUID()
        }
        super.init(frame: .zero)

        switch content {
        case .terminal(let view):
            view.$title.assign(to: &$title)
            view.$bell.assign(to: &$bell)
            view.$activityState.assign(to: &$activityState)
            view.$paneBanner.assign(to: &$paneBanner)
        case .viewer(let view):
            view.$title.assign(to: &$title)
        }
    }

    convenience init(surface: Ghostty.SurfaceView) {
        self.init(.terminal(surface))
    }

    convenience init(viewer: ViewerView) {
        self.init(.viewer(viewer))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    /// Whether the mounted content view is the window's first responder.
    /// (The NSView extension `isFirstResponder` on PaneView itself is always
    /// false since PaneView is never in a window.)
    var contentIsFirstResponder: Bool { contentView.isFirstResponder }

    /// Forward focus change notifications to terminal content. No-op for
    /// viewers (WKWebView manages its own focus ring).
    func focusDidChange(_ focused: Bool) {
        surfaceView?.focusDidChange(focused)
    }

    override func flagsChanged(with event: NSEvent) {
        surfaceView?.flagsChanged(with: event)
    }

    /// Triggers a brief highlight animation on terminal content.
    func highlight() {
        surfaceView?.highlight()
    }

    /// Forward the session close-on-free intent to terminal content
    /// (session persistence: close kills the agent session). Viewer content
    /// uses it as its detach signal: going quiet (pause media, tear down
    /// chrome) when leaving the tree, reviving on undo re-adoption.
    func setSessionCloseIntent(_ intent: Bool) {
        surfaceView?.setSessionCloseIntent(intent)
        viewerView?.setDetached(intent)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case terminal
        case viewer
    }

    private enum Kind: String, Codable {
        case terminal
        case viewer
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) {
            switch kind {
            case .terminal:
                self.init(.terminal(try container.decode(Ghostty.SurfaceView.self, forKey: .terminal)))
            case .viewer:
                self.init(.viewer(try container.decode(ViewerView.self, forKey: .viewer)))
            }
        } else {
            // Legacy saved state: the leaf payload is a bare SurfaceView
            // (pwd/uuid/title keys at this level) from before viewer panes.
            self.init(.terminal(try Ghostty.SurfaceView(from: decoder)))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch content {
        case .terminal(let view):
            try container.encode(Kind.terminal, forKey: .kind)
            try container.encode(view, forKey: .terminal)
        case .viewer(let view):
            try container.encode(Kind.viewer, forKey: .kind)
            try container.encode(view, forKey: .viewer)
        }
    }
}
