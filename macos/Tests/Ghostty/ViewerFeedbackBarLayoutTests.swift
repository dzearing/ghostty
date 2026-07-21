import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// Layout of the redesigned composer, checked through the TCC-free offscreen
/// `NSHostingView` harness rather than by driving the GUI.
///
/// The point is the SHAPE the review asked for: a pill that grows with its
/// content, with the snapshot and send controls inside it on the trailing
/// edge — not a text box with a wide button bolted beside it.
@MainActor
@Suite(.serialized)
struct ViewerFeedbackBarLayoutTests {
    private func makeRepoFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-bar-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", dir.path, "init"]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try? git.run()
        git.waitUntilExit()
        let file = dir.appendingPathComponent("README.md")
        try "# demo\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The composer's circular action controls, found by GEOMETRY.
    ///
    /// Neither class-name sniffing nor `accessibilityLabel` works here: a
    /// SwiftUI `.plain` button renders as a private `_FocusRingView` whose
    /// AppKit-level accessibility label is nil (the label lives in SwiftUI's
    /// own accessibility tree). Geometry is the honest thing to assert anyway
    /// — the review asked for round buttons of a given size in a given place.
    private func circularActions(in host: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            let frame = view.convert(view.bounds, to: host)
            if abs(frame.width - ViewerFeedbackBar.actionButtonSize) <= 1,
               abs(frame.height - ViewerFeedbackBar.actionButtonSize) <= 1 {
                found.append(view)
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found.sorted {
            $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
        }
    }

    private func textView(in view: NSView) -> ViewerFeedbackTextView? {
        if let found = view as? ViewerFeedbackTextView { return found }
        for sub in view.subviews {
            if let found = textView(in: sub) { return found }
        }
        return nil
    }

    /// Mount and wait until SwiftUI has actually produced the content. A fixed
    /// sleep raced the hosting view on a loaded runner.
    private func mount(_ viewer: ViewerView) async -> NSHostingView<ViewerFeedbackBar> {
        let host = NSHostingView(
            rootView: ViewerFeedbackBar(viewerView: viewer, model: viewer.feedbackModel))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 220)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if textView(in: host) != nil, circularActions(in: host).count >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Both circular actions live INSIDE the pill, on the text's trailing side.
    @Test func pillContainsSnapshotAndSendButtons() async throws {
        let viewer = ViewerView(location: try makeRepoFile().path)
        let host = await mount(viewer)

        let input = try #require(textView(in: host), "composer text view never mounted")
        let actions = circularActions(in: host)
        #expect(actions.count == 2, "expected snapshot + send, found \(actions.count)")

        let inputFrame = input.convert(input.bounds, to: host)
        for action in actions {
            let frame = action.convert(action.bounds, to: host)
            // Trailing side of the text, i.e. inside the pill's right edge
            // rather than stacked below or bolted outside the bar.
            #expect(frame.minX >= inputFrame.maxX - 1,
                    "control at \(frame) is not right of the input \(inputFrame)")
            // They share the pill's vertical band rather than floating off it.
            #expect(frame.midY >= inputFrame.minY - 12 && frame.midY <= inputFrame.maxY + 12,
                    "control is not aligned with the input band")
        }

        // The input takes the room: the controls are a small fraction of the
        // bar, not a wide labeled button eating the composer.
        let actionsWidth = actions.reduce(0.0) { $0 + $1.convert($1.bounds, to: host).width }
        #expect(inputFrame.width > actionsWidth * 4,
                "input \(inputFrame.width) is crowded by controls \(actionsWidth)")
    }

    /// The pill starts at one line and grows as the report is written, rather
    /// than committing a tall box up front — and is capped so it can never
    /// swallow the pane it is describing.
    @Test func pillGrowsWithContentUpToACap() async throws {
        let viewer = ViewerView(location: try makeRepoFile().path)
        let host = await mount(viewer)
        let input = try #require(textView(in: host))
        let singleLine = input.convert(input.bounds, to: host).height

        viewer.feedbackModel.textStorage.append(NSAttributedString(
            string: Array(repeating: "a wrapping line of feedback text", count: 14)
                .joined(separator: " "),
            attributes: ViewerFeedbackModel.typingAttributes))
        input.didChangeText()
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if input.convert(input.bounds, to: host).height > singleLine { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        host.layoutSubtreeIfNeeded()

        let grown = input.convert(input.bounds, to: host).height
        #expect(grown > singleLine, "pill did not grow: \(singleLine) -> \(grown)")
        #expect(grown <= ViewerFeedbackBar.maxInputHeight + 1,
                "pill exceeded its cap: \(grown)")
    }
}
