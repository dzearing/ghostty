import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The hero divider's grab target.
///
/// It used to be a SwiftUI `DragGesture` on a `ZStack` whose invisible 6pt
/// `Color.clear` was supposed to widen the target. It did not: the resize cursor
/// appeared across the whole band while only the drawn 1pt line could actually
/// be grabbed — the failure SplitView documents ("a SwiftUI-only divider is
/// effectively a 1px target no matter how large its invisible frame is") and
/// solves with an AppKit handle layered over the panes. Hero mode now uses that
/// same handle, so the target is a real NSView and can be measured here.
@MainActor
struct HeroDividerHitTargetTests {
    private func makePanes(_ count: Int) throws -> [PaneView] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hero-divider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<count).map { i in
            let file = dir.appendingPathComponent("pane-\(i).md")
            try "# pane \(i)".write(to: file, atomically: true, encoding: .utf8)
            return PaneView(viewer: ViewerView(location: file.path))
        }
    }

    private func makeTree(_ panes: [PaneView]) throws -> SplitTree<PaneView> {
        var tree = SplitTree<PaneView>(view: panes[0])
        for (previous, pane) in zip(panes, panes.dropFirst()) {
            tree = try tree.inserting(view: pane, at: previous, direction: .down)
        }
        return tree
    }

    private func settle(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    @Test func theGrabZoneIsWiderThanTheDrawnLineAndBeatsThePanes() throws {
        let panes = try makePanes(3)
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: panes.count)
        state.carouselRatio = 0.25

        let width: CGFloat = 1200, height: CGFloat = 800
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: HeroModeView(tree: try makeTree(panes), state: state))
        host.frame = window.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        settle(0.4)
        defer {
            host.removeFromSuperview()
            window.contentView = nil
            settle(0.05)
        }

        let handle = try #require(
            find(DividerHandle.DividerHandleView.self, in: host),
            "hero mode has no AppKit divider handle, so its divider is a 1px target again")
        let handleFrame = handle.convert(handle.bounds, to: nil)

        // The drawn line sits between the two pane containers.
        let pane = try #require(find(HeroPaneContainer.self, in: host))
        let carousel = try #require(find(HeroCarouselContainer.self, in: host))
        let lineBand = CGRect(
            x: pane.convert(pane.bounds, to: nil).maxX,
            y: 0,
            width: carousel.convert(carousel.bounds, to: nil).minX
                - pane.convert(pane.bounds, to: nil).maxX,
            height: height)

        // The handle must extend past the line on BOTH sides — the whole point
        // is grab zone reaching into each pane — and be centred on it.
        #expect(handleFrame.minX < lineBand.minX)
        #expect(handleFrame.maxX > lineBand.maxX)
        #expect(abs(handleFrame.midX - lineBand.midX) < 0.51)
        #expect(handleFrame.width >= 9)

        // ...and it must actually WIN hit testing across its whole width. This
        // is the assertion the old divider could never have passed: outside the
        // 6pt gap the pane's WKWebView and the carousel own those points.
        var x = handleFrame.minX + 0.25
        while x < handleFrame.maxX {
            let hit = window.contentView!.hitTest(NSPoint(x: x, y: height / 2))
            #expect(
                hit === handle,
                "x=\(x) hits \(hit.map { "\(type(of: $0))" } ?? "nil"), not the divider handle")
            x += 0.5
        }

        // The grab zone reaches into the panes, which is exactly what the old
        // one failed to do.
        #expect(handleFrame.minX < pane.convert(pane.bounds, to: nil).maxX)
        #expect(handleFrame.maxX > carousel.convert(carousel.bounds, to: nil).minX)
    }
}
