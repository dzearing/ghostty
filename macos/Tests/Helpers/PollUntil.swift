import AppKit
import Foundation

/// Spin until `condition` holds, or `timeout` elapses. Returns whether it was
/// ever observed to hold.
///
/// Both the run-loop turn and the main-actor yield are needed: WebKit only
/// makes progress while the run loop turns, and the viewer publishes its state
/// via `DispatchQueue.main.async`, which cannot drain while a synchronous test
/// body owns the main actor. Spinning alone makes every navigation look broken.
///
/// Waiting for the CONDITION rather than for a fixed duration is what keeps
/// these tests honest on a loaded machine. A fixed sleep gets it wrong in both
/// directions, and which one you get depends only on how busy the box is:
///
///  - Too early: a real WebKit navigation has not landed inside the budget, so
///    the assertion reads the previous page.
///  - Too late: the state under test has already been torn down again. The
///    address bar is the sharp case — an offscreen test window is never key, so
///    the field takes focus and loses it again a moment later, and the bar's
///    2s auto-hide then pulls the chrome (and the first responder) out from
///    under an assertion that was going to run at 1.6s. That margin is 0.4s on
///    an idle machine and negative on a busy one.
///
/// Polling collapses both: the assertion runs as soon as the state is right,
/// which is typically tens of milliseconds in, so load stops mattering. Give
/// `timeout` plenty of headroom — it is a failure deadline, not a delay, and
/// costs nothing when the condition arrives early.
///
/// Do NOT use this while a `withCheckedContinuation` is in flight — turning the
/// run loop re-enters and races the continuation's resumption. Tests in that
/// shape (`ViewerTOCTests`, which awaits `evaluateJavaScript`) keep their own
/// sleep-only wait, and say so where they define it.
@MainActor
@discardableResult
func poll(
    timeout: TimeInterval = 15,
    until condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Pump the run loop and the main actor for a fixed span, without asserting
/// anything about the result.
///
/// Only correct before a NEGATIVE assertion ("still no history"), where there
/// is no state to wait for and the risk runs the safe way: extra load can only
/// make the wait longer, never turn a pass into a failure. Anything you expect
/// to BECOME true belongs in `poll`.
@MainActor
func settle(_ seconds: TimeInterval) async {
    await poll(timeout: seconds) { false }
}
