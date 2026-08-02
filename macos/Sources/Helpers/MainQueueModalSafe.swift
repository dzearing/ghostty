import Foundation
import AppKit   // RunLoop.Mode.modalPanel / .eventTracking are AppKit-provided

/// Run `body` on the main thread, **including while a modal panel is up**.
///
/// `DispatchQueue.main.async` is not sufficient. The main dispatch queue is
/// drained by a run-loop source registered in the *common* modes, and
/// `NSModalPanelRunLoopMode` — the mode `NSApp.runModal(for:)` pumps — is not a
/// member of that set. So for as long as an app-modal panel is on screen,
/// blocks posted with `DispatchQueue.main.async` simply do not execute. They are
/// not dropped; they sit queued until the panel goes away.
///
/// That is easy to mistake for something else entirely. Two symptoms it caused
/// here, both of which were misdiagnosed for a long time:
///
///   * The machine chooser's session roster froze the moment it opened. Its
///     refresh sets an `inflight` flag, calls a background fetch, and clears the
///     flag in the completion. The completion could never land while the panel
///     was up, so the flag stayed set, every subsequent poll short-circuited,
///     and sessions that had already exited kept rendering as live "Resume"
///     rows. Closing and reopening the dialog "fixed" it only because the queued
///     completions finally drained.
///   * `ghoztty +list` appeared to hang whenever the chooser was open, because
///     the IPC handler hops to main and waits on a semaphore.
///
/// Posting through `RunLoop.main` with an explicit mode list schedules the block
/// in modal-panel and event-tracking modes too, so it runs promptly regardless
/// of what the main run loop happens to be doing.
///
/// Use this for any completion a modal UI depends on. Ordinary main-queue work
/// that no modal is waiting on should keep using `DispatchQueue.main.async`.
@inlinable
func onMainEvenWhenModal(_ body: @escaping @MainActor () -> Void) {
    RunLoop.main.perform(inModes: [.default, .common, .modalPanel, .eventTracking]) {
        MainActor.assumeIsolated { body() }
    }
}
