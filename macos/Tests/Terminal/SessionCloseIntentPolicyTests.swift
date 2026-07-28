import Foundation
import Testing
@testable import Ghostty

/// A stand-in for a surface-tree leaf: identity plus the agent session it is
/// bound to. The policy only ever needs those two facts, so the invariant is
/// testable without a GUI, libghostty, or a live agent.
private final class FakeLeaf {
    let name: String
    let sessionID: String?
    init(_ name: String, session: String? = nil) {
        self.name = name
        self.sessionID = session
    }
}

private func plan(
    from: [FakeLeaf], to: [FakeLeaf]
) -> SessionCloseIntentPolicy.Plan<FakeLeaf> {
    SessionCloseIntentPolicy.plan(from: from, to: to, sessionID: { $0.sessionID })
}

private func names(_ leaves: [FakeLeaf]) -> [String] { leaves.map(\.name) }

struct SessionCloseIntentPolicyTests {
    // MARK: The normal readings this policy must preserve

    @Test func leavesStillInTheTreeAreKeptAlive() {
        let a = FakeLeaf("a", session: "s-a")
        let b = FakeLeaf("b", session: "s-b")
        let result = plan(from: [a, b], to: [a, b])
        #expect(names(result.keepAlive) == ["a", "b"])
        #expect(result.close.isEmpty)
        #expect(result.spared.isEmpty)
    }

    @Test func aUserClosedPaneIsMarkedCloseOnFree() {
        // The everyday case: one pane of a split is closed, the rest stay.
        let a = FakeLeaf("a", session: "s-a")
        let b = FakeLeaf("b", session: "s-b")
        let result = plan(from: [a, b], to: [a])
        #expect(names(result.close) == ["b"])
        #expect(names(result.keepAlive) == ["a"])
        #expect(result.spared.isEmpty)
    }

    @Test func closingTheLastPaneStillMarksIt() {
        let a = FakeLeaf("a", session: "s-a")
        let result = plan(from: [a], to: [])
        #expect(names(result.close) == ["a"])
        #expect(result.keepAlive.isEmpty)
    }

    @Test func undoReadoptionClearsTheIntent() {
        // The undo restore assigns the OLD tree back; nothing departs.
        let a = FakeLeaf("a", session: "s-a")
        let result = plan(from: [], to: [a])
        #expect(names(result.keepAlive) == ["a"])
        #expect(result.close.isEmpty)
    }

    // MARK: The regression — a rebuild swap must never CLOSE a live session

    @Test func rebuildSwapSparesEveryReattachedSession() {
        // In-place recovery replaces all three leaves with fresh surfaces that
        // re-ATTACH the same sessions. Pre-fix every old leaf was marked
        // CLOSE-on-free, and killed a live pane's session on dealloc.
        let old = [
            FakeLeaf("old-1", session: "s-1"),
            FakeLeaf("old-2", session: "s-2"),
            FakeLeaf("old-3", session: "s-3"),
        ]
        let new = [
            FakeLeaf("new-1", session: "s-1"),
            FakeLeaf("new-2", session: "s-2"),
            FakeLeaf("new-3", session: "s-3"),
        ]
        let result = plan(from: old, to: new)
        #expect(result.close.isEmpty)
        #expect(names(result.spared) == ["old-1", "old-2", "old-3"])
        #expect(names(result.keepAlive) == ["new-1", "new-2", "new-3"])
    }

    @Test func aSessionDroppedByTheRebuildIsStillClosed() {
        // A partial rebuild (the manifest no longer carries s-2): that session
        // really is going away, so its old leaf must still end the session.
        let old = [
            FakeLeaf("old-1", session: "s-1"),
            FakeLeaf("old-2", session: "s-2"),
        ]
        let new = [FakeLeaf("new-1", session: "s-1")]
        let result = plan(from: old, to: new)
        #expect(names(result.spared) == ["old-1"])
        #expect(names(result.close) == ["old-2"])
    }

    @Test func sparingIsDrivenBySessionIdNotPosition() {
        // The rebuilt tree may reorder leaves; identity of the SESSION is what
        // matters, not where it landed.
        let old = [
            FakeLeaf("old-1", session: "s-1"),
            FakeLeaf("old-2", session: "s-2"),
        ]
        let new = [
            FakeLeaf("new-2", session: "s-2"),
            FakeLeaf("new-1", session: "s-1"),
        ]
        let result = plan(from: old, to: new)
        #expect(result.close.isEmpty)
        #expect(names(result.spared) == ["old-1", "old-2"])
    }

    // MARK: Leaves with no session

    @Test func sessionlessLeavesAreNeverSpared() {
        // Local exec panes and viewer panes have no agent session. Two of them
        // must not be treated as "the same session" just because both are nil.
        let old = [FakeLeaf("old-exec"), FakeLeaf("old-viewer")]
        let new = [FakeLeaf("new-exec"), FakeLeaf("new-viewer")]
        let result = plan(from: old, to: new)
        #expect(result.spared.isEmpty)
        #expect(names(result.close) == ["old-exec", "old-viewer"])
    }

    @Test func emptySessionIdsAreTreatedAsNoSession() {
        let old = [FakeLeaf("old", session: "")]
        let new = [FakeLeaf("new", session: "")]
        let result = plan(from: old, to: new)
        #expect(result.spared.isEmpty)
        #expect(names(result.close) == ["old"])
    }

    @Test func mixedTreeSparesOnlyTheReattachedTerminal() {
        let old = [
            FakeLeaf("old-term", session: "s-1"),
            FakeLeaf("old-viewer"),
        ]
        let new = [
            FakeLeaf("new-term", session: "s-1"),
            FakeLeaf("new-viewer"),
        ]
        let result = plan(from: old, to: new)
        #expect(names(result.spared) == ["old-term"])
        #expect(names(result.close) == ["old-viewer"])
    }
}
