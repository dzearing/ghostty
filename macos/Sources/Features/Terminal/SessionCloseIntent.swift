import Foundation

/// Decides which leaves of a replaced surface tree get the "CLOSE my agent
/// session when I am freed" intent.
///
/// The default reading of a tree change is simple: a leaf that LEFT the tree
/// was closed by the user, so its agent session must actually END when the
/// view is eventually freed (after the undo window expires) rather than linger
/// detached in the agent forever. A leaf still PRESENT in the tree is alive, so
/// any pending intent is cleared — that is what un-marks a view brought back by
/// undo.
///
/// That reading is WRONG for a tree SWAP. In-place session recovery
/// (`SessionLayoutRestore.rebuildSessionLayoutController`) replaces a live
/// controller's whole `surfaceTree` with freshly built surfaces that re-ATTACH
/// the SAME agent sessions. Every old leaf "leaves the tree", but nobody closed
/// anything — and marking those leaves CLOSE-on-free means that whenever they
/// finally deallocate (they are retained by the undo stack / an autorelease
/// pool, so it can be minutes later) `Remote.threadExit` takes the CLOSE branch
/// and terminates the child of a session a live on-screen pane is using. That
/// is the 2026-07-21 incident: recovery killing the very sessions it recovered.
///
/// So the invariant is: **a session that is still referenced by the new tree is
/// never marked CLOSE-on-free.** Stating it in terms of session ids (rather
/// than special-casing the rebuild caller) means any future tree-replacing path
/// inherits the protection.
enum SessionCloseIntentPolicy {
    /// The three buckets a tree change sorts leaves into.
    struct Plan<Leaf> {
        /// Leaves present in the new tree. Alive — clear any pending intent.
        var keepAlive: [Leaf]

        /// Leaves that left the tree and took their session with them. Mark
        /// CLOSE-on-free so the agent session actually ends.
        var close: [Leaf]

        /// Leaves that left the tree but whose agent session is still attached
        /// by a leaf of the NEW tree (a rebuild swap). Their intent is
        /// explicitly CLEARED: freeing them must DETACH, never CLOSE, or the
        /// replacement pane loses the session underneath it.
        ///
        /// Only ever holds leaves with a non-empty session id, so a viewer pane
        /// (which has none) can never land here and be wrongly re-attached.
        var spared: [Leaf]
    }

    /// Sort the leaves of a surface-tree change into `Plan` buckets.
    ///
    /// `sessionID` maps a leaf to the agent session it is bound to, or nil for
    /// a leaf with no session (a local exec pane, a viewer). Leaves with no
    /// session id are never spared — there is nothing shared to protect.
    static func plan<Leaf: AnyObject>(
        from: [Leaf],
        to: [Leaf],
        sessionID: (Leaf) -> String?
    ) -> Plan<Leaf> {
        let arrived = Set(to.map(ObjectIdentifier.init))
        let retainedSessions = Set(to.compactMap(sessionID).filter { !$0.isEmpty })

        var close: [Leaf] = []
        var spared: [Leaf] = []
        for leaf in from where !arrived.contains(ObjectIdentifier(leaf)) {
            if let id = sessionID(leaf), !id.isEmpty, retainedSessions.contains(id) {
                spared.append(leaf)
            } else {
                close.append(leaf)
            }
        }
        return Plan(keepAlive: to, close: close, spared: spared)
    }
}
