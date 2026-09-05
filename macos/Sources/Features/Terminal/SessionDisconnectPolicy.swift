import Foundation

/// Decides whether a close can offer **Disconnect** — walking away from the
/// panes being closed while their agent sessions (and the processes inside
/// them) keep running on the machine that hosts them — and what the alert
/// should say about it.
///
/// The mechanism already exists on both sides of the wire: freeing a surface
/// DETACHes its agent session by default and only CLOSEs it (terminating the
/// child) when the apprt marked it CLOSE-on-free. "Disconnect" is therefore
/// nothing more than "close the window locally, but do not mark the surfaces".
/// What this type owns is the *policy*: which panes that is honest to offer
/// for, and how to phrase it.
///
/// It is stated over plain facts rather than over `PaneView`/`Machine` so the
/// rules are testable without a GUI, libghostty, or a live agent —
/// `BaseTerminalController.disconnectableViews(in:)` is the thin adapter that
/// supplies those facts.
enum SessionDisconnectPolicy {
    /// The facts about one pane that decide whether a Disconnect would spare
    /// it. Everything here is cheap to read off a live pane and trivial to
    /// fabricate in a test.
    struct PaneFacts {
        /// False for a viewer pane: no terminal, so no agent session to keep.
        var hasSurface: Bool

        /// True once the child is gone. There is nothing left to keep running,
        /// so offering to keep it would be a lie.
        var processExited: Bool

        /// `confirm-close-surface` is not `false`. A user who turned close
        /// confirmation off asked for no prompts; this feature does not get to
        /// reintroduce one for them. (Liveness is NOT folded in here — an idle
        /// remote pane is exactly the case this feature exists for.)
        var confirmCloseEnabled: Bool

        init(hasSurface: Bool, processExited: Bool, confirmCloseEnabled: Bool) {
            self.hasSurface = hasSurface
            self.processExited = processExited
            self.confirmCloseEnabled = confirmCloseEnabled
        }
    }

    /// Whether a window whose terminals run on `machine` hosts sessions a
    /// Disconnect could spare.
    ///
    /// A window with no machine is a plain local window: its shell is a child
    /// of this app, and there is no session to leave behind.
    ///
    /// `isLocalMachine` is excluded DELIBERATELY, and it is not the same
    /// exclusion. Session persistence runs local panes through an agent on
    /// this very Mac, so they do have a session — but "closing a pane ends its
    /// session" is that feature's documented contract (see CLAUDE.md and
    /// `+close`), and the way to leave one running is to quit the app, not to
    /// close the pane. Offering Disconnect there would contradict a promise
    /// the CLI already makes.
    static func machineIsDisconnectable(_ machine: Machine?) -> Bool {
        guard let machine else { return false }
        return !machine.isLocalMachine
    }

    /// Whether a Disconnect would actually spare this pane.
    static func isDisconnectable(_ facts: PaneFacts) -> Bool {
        facts.hasSurface && !facts.processExited && facts.confirmCloseEnabled
    }

    /// The panes a Disconnect would spare, together with the machines their
    /// sessions live on — everything the alert needs to phrase the offer.
    ///
    /// Generic over the pane type so the merge and the wording are testable
    /// without a `PaneView`.
    struct Offer<Pane> {
        var panes: [Pane]

        /// Distinct machine display names, in the order they were contributed.
        /// Usually one; a tab-group close can span several windows and those
        /// windows can sit on different machines.
        var machineNames: [String]

        var isEmpty: Bool { panes.isEmpty }

        static var none: Offer { .init(panes: [], machineNames: []) }

        init(panes: [Pane], machineNames: [String]) {
            self.panes = panes
            self.machineNames = machineNames
        }
    }

    /// Merge the offers of several windows. A tab-group close (Close Window,
    /// Close Other Tabs, Close Tabs on the Right) spans a whole group, which
    /// can mix remote tabs with local ones and even mix machines; empty offers
    /// drop out, so the local tabs contribute nothing and close normally.
    static func merge<Pane>(_ offers: [Offer<Pane>]) -> Offer<Pane> {
        var panes: [Pane] = []
        var names: [String] = []
        for offer in offers where !offer.isEmpty {
            panes.append(contentsOf: offer.panes)
            for name in offer.machineNames where !names.contains(name) {
                names.append(name)
            }
        }
        return .init(panes: panes, machineNames: names)
    }

    /// The alert's informative text for a close that can offer Disconnect.
    ///
    /// Deliberately scope-neutral: the same sentence has to read correctly
    /// whether the user is closing a pane, a tab, a window, or a whole tab
    /// group, so it talks about the SESSIONS at stake rather than about the
    /// thing being closed. Callers supply only the machines and the count;
    /// nobody hand-rolls this string.
    static func informativeText(machineNames: [String], count: Int) -> String {
        // One machine is named; several are not, because there is no honest
        // way to fit a list into the sentence and naming just one of them
        // would be a lie about where the other sessions live.
        let place: String
        switch machineNames.count {
        case 0: place = "the remote machine"
        case 1: place = machineNames[0]
        default: place = "other machines"
        }

        if count <= 1 {
            return "This session runs on \(place). "
                + "Close ends the remote process; "
                + "Disconnect leaves it running so you can resume it later."
        }
        return "\(count) sessions run on \(place). "
            + "Close ends those remote processes; "
            + "Disconnect leaves them running so you can resume them later."
    }
}

/// The "Disconnect" pin, factored out of `SurfaceView` so the ordering
/// invariant it exists for is testable without libghostty.
///
/// A single close marks its surfaces CLOSE-on-free TWICE, from two independent
/// places — `BaseTerminalController.surfaceTreeDidChange` (the leaf left the
/// tree) and `windowWillClose` (the window is going away) — and the order
/// between them varies with which close path ran. Either one firing after the
/// user answered **Disconnect** would silently kill the session they asked to
/// keep. So the answer is recorded as a pin that REFUSES later CLOSE markings,
/// rather than as a one-shot `setSessionCloseIntent(false)` that whichever
/// marking runs last would overwrite. Any future close bookkeeping inherits
/// that protection for free.
struct SessionDetachPin {
    private(set) var isPinned: Bool = false

    /// Record the user's Disconnect.
    mutating func pin() {
        isPinned = true
    }

    /// Release the pin: the surface is live again (an undone close, a pane
    /// moved into another window), so a LATER close is a close like any other.
    mutating func clear() {
        isPinned = false
    }

    /// The intent to actually push down for a requested `closeOnFree` marking,
    /// or nil when the request must be refused because honoring it would undo
    /// the pin. A DETACH marking is never refused — it agrees with the pin.
    func resolve(_ closeOnFree: Bool) -> Bool? {
        if closeOnFree && isPinned { return nil }
        return closeOnFree
    }
}
