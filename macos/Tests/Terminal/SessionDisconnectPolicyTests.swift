import Foundation
import Testing
@testable import Ghostty

/// A stand-in for a pane. The policy only ever needs identity, so the rules
/// are testable without a GUI, libghostty, or a live agent.
private final class FakePane {
    let name: String
    init(_ name: String) { self.name = name }
}

private func machine(_ name: String, hostname: String? = nil) -> Machine {
    Machine(name: name, host: "10.0.0.5", port: 7799, hostname: hostname)
}

private func offer(_ names: [String], on machines: [String]) -> SessionDisconnectPolicy.Offer<FakePane> {
    .init(panes: names.map(FakePane.init), machineNames: machines)
}

private func names(_ panes: [FakePane]) -> [String] { panes.map(\.name) }

struct SessionDisconnectPolicyTests {
    // MARK: Which windows may offer Disconnect

    @Test func aPlainLocalWindowOffersNothing() {
        // No machine at all: the shell is a child of this app, so there is no
        // session to leave behind.
        #expect(!SessionDisconnectPolicy.machineIsDisconnectable(nil))
    }

    @Test func theLocalAgentIsExcluded() {
        // Session persistence runs local panes through an agent on this Mac,
        // so they DO have a session -- but "closing a pane ends its session"
        // is that feature's documented contract. Offering Disconnect there
        // would contradict a promise the CLI already makes.
        #expect(!SessionDisconnectPolicy.machineIsDisconnectable(machine("localhost")))
        #expect(!SessionDisconnectPolicy.machineIsDisconnectable(machine("127.0.0.1")))
    }

    @Test func aLocalHostnameBehindADisplayNameIsAlsoExcluded() {
        // `name` is the user-facing label; a machine renamed to "My Mac" whose
        // agent-reported hostname is this Mac is still local.
        let local = ProcessInfo.processInfo.hostName
        #expect(!SessionDisconnectPolicy.machineIsDisconnectable(
            machine("My Mac", hostname: local)))
    }

    @Test func aRealRemoteMachineOffersDisconnect() {
        #expect(SessionDisconnectPolicy.machineIsDisconnectable(machine("winbox")))
    }

    // MARK: Which panes a Disconnect would actually spare

    @Test func aLiveRemoteTerminalIsSpared() {
        #expect(SessionDisconnectPolicy.isDisconnectable(.init(
            hasSurface: true, processExited: false, confirmCloseEnabled: true)))
    }

    @Test func aViewerPaneIsNotSpared() {
        // No terminal, so no agent session to keep running.
        #expect(!SessionDisconnectPolicy.isDisconnectable(.init(
            hasSurface: false, processExited: false, confirmCloseEnabled: true)))
    }

    @Test func anExitedPaneIsNotSpared() {
        // Nothing is left to keep; offering to keep it would be a lie.
        #expect(!SessionDisconnectPolicy.isDisconnectable(.init(
            hasSurface: true, processExited: true, confirmCloseEnabled: true)))
    }

    @Test func confirmCloseOptOutIsHonored() {
        // A user who set `confirm-close-surface = false` asked for no prompts.
        // This feature does not get to reintroduce one for them.
        #expect(!SessionDisconnectPolicy.isDisconnectable(.init(
            hasSurface: true, processExited: false, confirmCloseEnabled: false)))
    }

    // MARK: Merging a tab group's offers

    @Test func mergeConcatenatesPanesAndDedupesMachines() {
        let merged = SessionDisconnectPolicy.merge([
            offer(["a", "b"], on: ["winbox"]),
            offer(["c"], on: ["winbox"]),
        ])
        #expect(names(merged.panes) == ["a", "b", "c"])
        #expect(merged.machineNames == ["winbox"])
    }

    @Test func mergeDropsTheLocalTabsOfAMixedTabGroup() {
        // A tab group can mix a remote window with local ones. The local tabs
        // contribute an empty offer and must close normally.
        let merged = SessionDisconnectPolicy.merge([
            .none,
            offer(["a"], on: ["winbox"]),
            .none,
        ])
        #expect(names(merged.panes) == ["a"])
        #expect(merged.machineNames == ["winbox"])
    }

    @Test func mergeKeepsEveryDistinctMachine() {
        let merged = SessionDisconnectPolicy.merge([
            offer(["a"], on: ["winbox"]),
            offer(["b"], on: ["buildbox"]),
        ])
        #expect(merged.machineNames == ["winbox", "buildbox"])
    }

    @Test func mergingNothingIsEmpty() {
        let merged: SessionDisconnectPolicy.Offer<FakePane> =
            SessionDisconnectPolicy.merge([.none, .none])
        #expect(merged.isEmpty)
        #expect(merged.machineNames.isEmpty)
    }

    // MARK: The wording

    @Test func oneSessionIsNamedInTheSingular() {
        let text = SessionDisconnectPolicy.informativeText(
            machineNames: ["winbox"], count: 1)
        #expect(text == "This session runs on winbox. "
            + "Close ends the remote process; "
            + "Disconnect leaves it running so you can resume it later.")
    }

    @Test func severalSessionsAreCountedAndPluralized() {
        let text = SessionDisconnectPolicy.informativeText(
            machineNames: ["winbox"], count: 3)
        #expect(text == "3 sessions run on winbox. "
            + "Close ends those remote processes; "
            + "Disconnect leaves them running so you can resume them later.")
    }

    @Test func severalMachinesAreNotNamed() {
        // Naming just one of them would be a lie about where the others live,
        // and a list does not fit the sentence.
        let text = SessionDisconnectPolicy.informativeText(
            machineNames: ["winbox", "buildbox"], count: 2)
        #expect(text.hasPrefix("2 sessions run on other machines."))
        #expect(!text.contains("winbox"))
    }

    @Test func aMissingMachineNameFallsBackRatherThanReadingBroken() {
        let text = SessionDisconnectPolicy.informativeText(machineNames: [], count: 1)
        #expect(text.hasPrefix("This session runs on the remote machine."))
    }
}

/// The pin exists to survive the two independent CLOSE markings a single close
/// fires, in either order. These are those orders.
struct SessionDetachPinTests {
    @Test func anUnpinnedSurfaceMarksNormally() {
        let pin = SessionDetachPin()
        #expect(pin.resolve(true) == true)
        #expect(pin.resolve(false) == false)
    }

    @Test func aPinRefusesALaterCloseMarking() {
        // `surfaceTreeDidChange` and `windowWillClose` both mark CLOSE after
        // the user answered Disconnect; both must be refused.
        var pin = SessionDetachPin()
        pin.pin()
        #expect(pin.resolve(true) == nil)
        #expect(pin.resolve(true) == nil)
    }

    @Test func aPinStillAllowsADetachMarking() {
        // A DETACH marking agrees with the pin, so there is nothing to refuse.
        var pin = SessionDetachPin()
        pin.pin()
        #expect(pin.resolve(false) == false)
    }

    @Test func aPinIsStickyNotOneShot() {
        // The whole point: it is not consumed by the first marking it refuses.
        var pin = SessionDetachPin()
        pin.pin()
        _ = pin.resolve(true)
        #expect(pin.isPinned)
    }

    @Test func clearingThePinRestoresNormalClosing() {
        // Re-adoption into a live tree (an undone close, a pane moved to
        // another window) means a LATER close is a close like any other.
        var pin = SessionDetachPin()
        pin.pin()
        pin.clear()
        #expect(!pin.isPinned)
        #expect(pin.resolve(true) == true)
    }
}

/// The controller applies a `SessionCloseIntentPolicy` plan and the pin
/// TOGETHER, and the bug the pin exists for lives in that seam: a single close
/// marks CLOSE from two independent places, in an order that varies by path.
/// These reproduce both orders.
struct SessionDetachPinPlanTests {
    /// The two facts a surface contributes here: what got pushed down to
    /// libghostty, and whether the user pinned it.
    private final class FakeSurface {
        let sessionID: String?
        var pin = SessionDetachPin()
        /// The last intent actually pushed down. False == DETACH (the default).
        var closeOnFree = false

        init(session: String? = nil) { self.sessionID = session }

        /// Mirrors `SurfaceView.setSessionCloseIntent(_:)`.
        func setSessionCloseIntent(_ closeOnFree: Bool) {
            guard let intent = pin.resolve(closeOnFree) else { return }
            self.closeOnFree = intent
        }

        /// Mirrors `SurfaceView.pinSessionDetachOnFree()`.
        func pinDetach() {
            pin.pin()
            setSessionCloseIntent(false)
        }
    }

    /// Mirrors `BaseTerminalController.surfaceTreeDidChange`.
    private func applyTreeChange(from: [FakeSurface], to: [FakeSurface]) {
        let plan = SessionCloseIntentPolicy.plan(
            from: from, to: to, sessionID: { $0.sessionID })
        for view in plan.keepAlive {
            view.pin.clear()
            view.setSessionCloseIntent(false)
        }
        for view in plan.spared { view.setSessionCloseIntent(false) }
        for view in plan.close { view.setSessionCloseIntent(true) }
    }

    /// Mirrors `BaseTerminalController.windowWillClose`.
    private func applyWindowWillClose(_ views: [FakeSurface]) {
        for view in views { view.setSessionCloseIntent(true) }
    }

    @Test func withoutADisconnectACloseStillEndsTheSession() {
        // The control: this is exactly what must keep happening for "Close".
        let a = FakeSurface(session: "s-a")
        applyTreeChange(from: [a], to: [])
        applyWindowWillClose([a])
        #expect(a.closeOnFree)
    }

    @Test func disconnectSurvivesTheTreeChangeThenWindowClose() {
        let a = FakeSurface(session: "s-a")
        a.pinDetach()
        applyTreeChange(from: [a], to: [])
        applyWindowWillClose([a])
        #expect(!a.closeOnFree)
    }

    @Test func disconnectSurvivesTheWindowCloseThenTreeChange() {
        // The other order -- which close path ran decides it, so neither order
        // may be the one that works.
        let a = FakeSurface(session: "s-a")
        a.pinDetach()
        applyWindowWillClose([a])
        applyTreeChange(from: [a], to: [])
        #expect(!a.closeOnFree)
    }

    @Test func undoingTheCloseRestoresNormalClosing() {
        // Undo re-adopts the view into a live tree: it is alive again, so the
        // Disconnect the user chose for the undone close no longer applies.
        let a = FakeSurface(session: "s-a")
        a.pinDetach()
        applyTreeChange(from: [a], to: [])
        applyTreeChange(from: [], to: [a])
        #expect(!a.pin.isPinned)

        // A LATER close is a close like any other.
        applyTreeChange(from: [a], to: [])
        #expect(a.closeOnFree)
    }

    @Test func aRebuildSwapDoesNotClearThePin() {
        // `spared` is an in-place session recovery, not a re-adoption: the
        // departing leaf was never brought back, so a Disconnect recorded on
        // it is still the user's standing answer.
        let old = FakeSurface(session: "s-a")
        let new = FakeSurface(session: "s-a")
        old.pinDetach()
        applyTreeChange(from: [old], to: [new])
        #expect(old.pin.isPinned)
        #expect(!old.closeOnFree)
    }
}
