import Foundation
import Network

/// App-wide network reachability observer for remote-window reconnect.
///
/// Wraps a single `NWPathMonitor` and posts
/// `.ghosttyNetworkPathDidBecomeSatisfied` (main thread) on every
/// unsatisfied → satisfied transition — i.e. "the machine just got network
/// back" (Wi-Fi re-associated after lid-open, cable plugged in, VPN up).
/// `BaseTerminalController` uses it the same way it uses
/// `NSWorkspace.didWakeNotification`: reset the reconnect backoff and kick an
/// immediate attempt instead of waiting out a timer.
///
/// The initial path update on `start()` never posts (there was no transition;
/// it just seeds `isSatisfied`), so launching with network up doesn't kick
/// anything.
final class NetworkPathMonitor {
    static let shared = NetworkPathMonitor()

    /// Whether the current network path is satisfied. `true` until the first
    /// path update arrives (fail open: never block a reconnect on a monitor
    /// that hasn't reported yet). Main-thread only, like the notification.
    private(set) var isSatisfied: Bool = true

    private let monitor = NWPathMonitor()
    private var started = false
    /// Nil until the first path update (used to suppress the initial "update"
    /// that is a seed, not a transition).
    private var lastStatus: NWPath.Status?

    private init() {}

    /// Idempotent. Called whenever a controller adopts a remote connection —
    /// the first caller starts the monitor for the app's lifetime (a stopped
    /// NWPathMonitor cannot be restarted, so it is never stopped).
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.pathDidUpdate(path)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func pathDidUpdate(_ path: NWPath) {
        let satisfied = path.status == .satisfied
        let previous = lastStatus
        lastStatus = path.status
        isSatisfied = satisfied
        // Only a genuine down → up transition is a "network came back" signal.
        guard satisfied, let previous, previous != .satisfied else { return }
        Ghostty.logger.warning(
            "network path became satisfied (was \(String(describing: previous), privacy: .public)); notifying remote windows")
        NotificationCenter.default.post(
            name: .ghosttyNetworkPathDidBecomeSatisfied, object: self)
    }
}

extension Notification.Name {
    /// Posted (main thread) by `NetworkPathMonitor` when the default network
    /// path transitions from unsatisfied to satisfied.
    static let ghosttyNetworkPathDidBecomeSatisfied =
        Notification.Name("ghosttyNetworkPathDidBecomeSatisfied")
}
