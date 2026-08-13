import AppKit
import Testing
@testable import Ghostty

/// `+rearrange` rebuilds a window's split tree out of the panes it already
/// has, so a layout may name any leaf of that tree — including a **viewer**
/// pane, which is a first-class leaf of the same `SplitTree<PaneView>`.
///
/// A viewer has no terminal surface (`TargetEntry.surfaceView` is nil for one
/// by design — that nil is how `+read`/`+send-keys`/`+set-state`/`+set-banner`
/// reject viewers), and rearrange used to resolve every name through that
/// accessor. So naming a viewer failed with "no longer alive" — about a pane
/// `+list` was reporting one line earlier.
///
/// A viewer pane is also the only real `PaneView` a unit test can build: a
/// terminal one needs a `Ghostty.SurfaceView`, which needs a live libghostty
/// app. The terminal leg of a mixed layout — and the process/scrollback/focus
/// guarantees that go with it — is covered against the real build by
/// `scripts/e2e/rearrange-viewer.py`.
@MainActor
struct RearrangeLayoutTests {
    // MARK: - Harness

    private static func makeViewerPane(_ label: String) throws -> PaneView {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rearrange-layout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(label).md")
        try "# \(label)".write(to: file, atomically: true, encoding: .utf8)
        return PaneView(viewer: ViewerView(location: file.path))
    }

    /// A left-to-right row of panes, so `leaves()` is `panes` in order.
    private static func makeTree(_ panes: [PaneView]) throws -> SplitTree<PaneView> {
        var tree = SplitTree<PaneView>(view: panes[0])
        for (previous, pane) in zip(panes, panes.dropFirst()) {
            tree = try tree.inserting(view: pane, at: previous, direction: .right)
        }
        return tree
    }

    /// The registry as rearrange sees it: names the caller knows about, each
    /// mapped to a live viewer pane.
    private static func resolver(
        _ panes: [String: PaneView]
    ) -> (String) -> RearrangeLayout.Target? {
        { name in
            guard let pane = panes[name] else { return nil }
            return RearrangeLayout.Target(viewerPane: pane, isAlive: true)
        }
    }

    private static func failure(
        _ result: Result<SplitTree<PaneView>.Node, RearrangeLayout.Failure>
    ) -> String? {
        if case .failure(let failure) = result { return failure.message }
        return nil
    }

    private static func root(
        _ result: Result<SplitTree<PaneView>.Node, RearrangeLayout.Failure>
    ) throws -> SplitTree<PaneView>.Node {
        try result.get()
    }

    // MARK: - Viewer panes

    /// The bug: a layout naming a viewer pane must build, not report the pane
    /// dead. Leaf identity is preserved — the SAME `PaneView` instances come
    /// back — which is what keeps a viewer's rendered page and scroll position
    /// (and a terminal's process and scrollback) alive across the swap.
    @Test func buildsALayoutThatNamesAViewerPane() throws {
        let term = try Self.makeViewerPane("term")
        let viewer = try Self.makeViewerPane("viewer")
        let tree = try Self.makeTree([term, viewer])

        let root = try Self.root(RearrangeLayout.build(
            layoutJSON: """
            {"direction": "horizontal", "ratio": 50,
             "left": {"pane": "term"}, "right": {"pane": "viewer"}}
            """,
            in: tree,
            resolve: Self.resolver(["term": term, "viewer": viewer])))

        guard case .split(let split) = root else {
            Issue.record("expected a split at the root, got \(root)")
            return
        }
        #expect(split.direction == .horizontal)
        #expect(split.ratio == 0.5)
        #expect(split.left == .leaf(view: term))
        #expect(split.right == .leaf(view: viewer))
        #expect(root.leaves().map(ObjectIdentifier.init) == [term, viewer].map(ObjectIdentifier.init))
    }

    /// A layout made only of viewer panes is just as legal.
    @Test func buildsAViewerOnlyLayout() throws {
        let top = try Self.makeViewerPane("top")
        let bottom = try Self.makeViewerPane("bottom")
        let tree = try Self.makeTree([top, bottom])

        let root = try Self.root(RearrangeLayout.build(
            layoutJSON: """
            {"direction": "vertical", "ratio": 30,
             "left": {"pane": "bottom"}, "right": {"pane": "top"}}
            """,
            in: tree,
            resolve: Self.resolver(["top": top, "bottom": bottom])))

        guard case .split(let split) = root else {
            Issue.record("expected a split at the root, got \(root)")
            return
        }
        #expect(split.direction == .vertical)
        #expect(split.ratio == 0.3)
        #expect(root.leaves().map(ObjectIdentifier.init) == [bottom, top].map(ObjectIdentifier.init))
    }

    /// A single viewer is a whole layout: the window becomes that one pane.
    @Test func buildsASingleViewerLayout() throws {
        let viewer = try Self.makeViewerPane("viewer")
        let tree = try Self.makeTree([viewer])

        let root = try Self.root(RearrangeLayout.build(
            layoutJSON: #"{"pane": "viewer"}"#,
            in: tree,
            resolve: Self.resolver(["viewer": viewer])))

        #expect(root == .leaf(view: viewer))
    }

    /// Panes the layout leaves out are simply not in the new tree — that is
    /// how `+rearrange` removes them.
    @Test func dropsPanesTheLayoutOmits() throws {
        let a = try Self.makeViewerPane("a")
        let b = try Self.makeViewerPane("b")
        let c = try Self.makeViewerPane("c")
        let tree = try Self.makeTree([a, b, c])

        let root = try Self.root(RearrangeLayout.build(
            layoutJSON: """
            {"direction": "horizontal", "left": {"pane": "a"}, "right": {"pane": "c"}}
            """,
            in: tree,
            resolve: Self.resolver(["a": a, "b": b, "c": c])))

        let kept = Set(root.leaves().map(ObjectIdentifier.init))
        #expect(kept == Set([a, c].map(ObjectIdentifier.init)))
        #expect(!kept.contains(ObjectIdentifier(b)))
    }

    // MARK: - Errors

    /// "No longer alive" is reserved for a pane that genuinely is: a registry
    /// entry whose weak reference has been collected.
    @Test func reportsADeadPaneAsNoLongerAlive() throws {
        let live = try Self.makeViewerPane("live")
        let tree = try Self.makeTree([live])

        let result = RearrangeLayout.build(
            layoutJSON: """
            {"direction": "horizontal", "left": {"pane": "live"}, "right": {"pane": "gone"}}
            """,
            in: tree,
            resolve: { name in
                switch name {
                case "live": return RearrangeLayout.Target(viewerPane: live, isAlive: true)
                case "gone": return RearrangeLayout.Target(isAlive: false)
                default: return nil
                }
            })

        #expect(Self.failure(result) == "pane 'gone' is no longer alive")
    }

    /// A live pane that belongs to some other window is not something this
    /// window's layout can place.
    @Test func reportsAPaneFromAnotherWindowAsNotInTheTargetWindow() throws {
        let mine = try Self.makeViewerPane("mine")
        let theirs = try Self.makeViewerPane("theirs")
        let tree = try Self.makeTree([mine])
        _ = try Self.makeTree([theirs])

        let result = RearrangeLayout.build(
            layoutJSON: """
            {"direction": "horizontal", "left": {"pane": "mine"}, "right": {"pane": "theirs"}}
            """,
            in: tree,
            resolve: Self.resolver(["mine": mine, "theirs": theirs]))

        #expect(Self.failure(result) == "pane 'theirs' is not in the target window")
    }

    @Test func reportsAnUnknownNameAsNotFoundInRegistry() throws {
        let mine = try Self.makeViewerPane("mine")
        let tree = try Self.makeTree([mine])

        let result = RearrangeLayout.build(
            layoutJSON: """
            {"direction": "horizontal", "left": {"pane": "mine"}, "right": {"pane": "nope"}}
            """,
            in: tree,
            resolve: Self.resolver(["mine": mine]))

        #expect(Self.failure(result) == "pane 'nope' not found in registry")
    }

    @Test func rejectsAPaneNamedTwice() throws {
        let mine = try Self.makeViewerPane("mine")
        let tree = try Self.makeTree([mine])

        let result = RearrangeLayout.build(
            layoutJSON: """
            {"direction": "horizontal", "left": {"pane": "mine"}, "right": {"pane": "mine"}}
            """,
            in: tree,
            resolve: Self.resolver(["mine": mine]))

        #expect(Self.failure(result) == "duplicate pane name in layout: 'mine'")
    }

    @Test func rejectsMalformedLayoutJSON() throws {
        let mine = try Self.makeViewerPane("mine")
        let tree = try Self.makeTree([mine])

        let result = RearrangeLayout.build(
            layoutJSON: "not json",
            in: tree,
            resolve: Self.resolver(["mine": mine]))

        #expect(Self.failure(result)?.hasPrefix("invalid layout JSON:") == true)
    }

    @Test func rejectsASplitNodeMissingAChild() throws {
        let mine = try Self.makeViewerPane("mine")
        let tree = try Self.makeTree([mine])

        let result = RearrangeLayout.build(
            layoutJSON: #"{"direction": "horizontal", "left": {"pane": "mine"}}"#,
            in: tree,
            resolve: Self.resolver(["mine": mine]))

        #expect(Self.failure(result) == "split node must have 'right' child")
    }
}
