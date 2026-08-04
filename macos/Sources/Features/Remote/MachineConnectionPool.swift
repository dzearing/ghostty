import Foundation
import GhosttyKit
import os

/// One warm, shared connection per remote machine, borrowed by every feature
/// that needs to talk to that machine's agent.
///
/// This is the remote-side counterpart to `LocalAgentManager`'s warm shared
/// connection. The local agent has had one since session persistence shipped —
/// which is why the chooser's "This Mac" row gets the agent's PUSHED session
/// roster while remote rows re-dialed on every 2s poll tick, and why relay rows
/// got no per-session CPU meter at all (a second dial for a meter, against a page
/// the user may close in seconds, was not worth it). Both of those are the same
/// missing piece: nowhere to hang a long-lived remote connection.
///
/// ## What a warm connection buys
/// - **Pushed rosters for remote machines.** `sessions_sub` needs a connection
///   that OUTLIVES one RPC; a dial-read-free probe by construction cannot host it.
/// - **One dial, not one per tick.** For a relay machine each old poll tick also
///   paid a `RelayAccount.resolveToken()` round-trip that may hit the Keychain.
/// - **One connection for N subscribers.** The roster and the CPU meter now ride
///   the same socket instead of opening one each.
///
/// ## Lifetime
/// Refcounted by `Lease`, never by guesswork. A connection is dialed on the first
/// `acquire` and freed when the LAST lease releases — so it cannot outlive the
/// transient UI that wanted it, and cannot be torn down while another subscriber
/// is still using it. Releasing is explicit (`Lease.release()`): a `deinit` hook
/// would have to hop to the main actor to do its work, which is exactly the kind
/// of deferred teardown this class exists to avoid.
///
/// ## Callback delivery, and the modal hazard
/// Readiness is reported through the lease's `onChange`. The initial replay for a
/// lease that arrives after the connection is already warm is delivered
/// **asynchronously via `onMainEvenWhenModal`**, for two reasons:
///
///   1. The caller must be able to store the lease before its callback runs.
///   2. `DispatchQueue.main.async` is not sufficient. The chooser's panel is
///      modeless now (78a21daa8), but it still runs AppKit modals of its own —
///      Kill's confirmation `NSAlert`, Rename, Remove — and for as long as one of
///      those is up, main-queue blocks sit undelivered. That is the exact shape
///      of the bug `onMainEvenWhenModal` was written for: a completion that never
///      lands leaves an in-flight flag set forever and freezes the UI.
///
/// Every LATER transition (dial finished, connection died) is delivered
/// **synchronously** on the main actor instead, and that is deliberate: a
/// `nil` means "stop using this handle NOW", and the pool frees it as soon as the
/// notifications return. An async hop there would free the handle before its
/// subscribers had unsubscribed.
///
/// ## Using the connection off the main thread
/// Blocking RPCs (`LIST_SESSIONS`, `CLOSE_SESSION`) must run on a background
/// queue, where the last lease could drop mid-call. `borrow` exists for that: it
/// retains the connection OBJECT for the duration of the call, so the free can
/// never race an in-flight RPC, and drops that retain back on the main actor
/// (`RemoteConnection.deinit` frees the C handle and must not run off-main).
///
/// Long-lived subscriptions (`sessions_sub`, `session_cpu_sub`) are the caller's
/// responsibility in the other direction: unsubscribe SYNCHRONOUSLY on
/// `onChange(nil)` and before releasing the lease, so no C callback can fire
/// against a freed handle.
///
/// The LOCAL agent is deliberately not pooled here — `LocalAgentManager` already
/// owns exactly this for the app's lifetime, and duplicating it would mean two
/// connections to the same agent.
@MainActor
final class MachineConnectionPool {
    static let shared = MachineConnectionPool()

    private static let logger = Logger(
        subsystem: Bundle.loggerSubsystem,
        category: String(describing: MachineConnectionPool.self)
    )

    // MARK: - Lease

    /// A borrow on one machine's warm connection. Holding it keeps the
    /// connection dialed; releasing it may tear the connection down (if it was
    /// the last one).
    ///
    /// `onChange` fires with the live handle when the connection becomes usable
    /// and with `nil` when it stops being usable (dial failed, or the link died).
    /// It may fire more than once — a machine that comes back is re-dialed — so
    /// callers must treat it as a state feed, not a one-shot completion. Capture
    /// the subscriber WEAKLY: the lease holds this closure, and the pool holds
    /// the lease.
    ///
    /// Main-actor isolated on purpose: everything it touches (the pool's tables,
    /// the C handle) is, and a nested type does not inherit the enclosing type's
    /// isolation.
    @MainActor
    final class Lease {
        /// The pool's key for this machine's endpoint (see `key(for:)`).
        let key: String
        fileprivate let machine: Machine
        fileprivate weak var pool: MachineConnectionPool?
        fileprivate let onChange: (ghostty_remote_connection_t?) -> Void
        fileprivate var released = false

        fileprivate init(
            key: String,
            machine: Machine,
            pool: MachineConnectionPool,
            onChange: @escaping (ghostty_remote_connection_t?) -> Void
        ) {
            self.key = key
            self.machine = machine
            self.pool = pool
            self.onChange = onChange
        }

        /// Give the borrow back. Idempotent.
        func release() {
            pool?.release(self)
        }
    }

    // MARK: - Ledger (pure bookkeeping)

    /// The pool's bookkeeping, factored out of the C-handle plumbing.
    ///
    /// Refcounting and re-dial policy are the parts that regress silently — a
    /// connection freed while someone still holds it crashes far from the cause,
    /// and one never freed just leaks a socket per machine per chooser opening.
    /// Keeping them pure means they are unit-testable with no agent, no dial and
    /// no main actor (cf. `LocalAgentManager.SharedLinkDropVerdict`).
    struct Ledger: Equatable {
        /// Where a machine's connection currently is.
        enum Phase: Equatable {
            /// Never dialed, or torn down and forgotten.
            case absent
            /// A dial is in flight.
            case dialing
            /// A live connection exists.
            case ready
            /// The last attempt failed, or the link died, at this time.
            case failed(at: Date)
        }

        /// What the caller must do for a machine, given its phase.
        enum Decision: Equatable {
            /// Nothing live and nothing in flight — start a dial.
            case dial
            /// A dial is already in flight; this lease joins its waiters.
            case wait
            /// A warm connection exists; replay it to this lease.
            case deliverReady
            /// Do nothing right now (too soon to retry, or nobody wants it).
            case hold
        }

        /// How long a failed machine is left alone before an automatic retry.
        /// Only `ensure` (the poll-driven path) honours it; an explicit
        /// `acquire` is a user selecting the row and always gets an attempt.
        var redialCooldown: TimeInterval = 5

        private(set) var phases: [String: Phase] = [:]
        private(set) var leases: [String: Int] = [:]

        func phase(_ key: String) -> Phase { phases[key] ?? .absent }
        func leaseCount(_ key: String) -> Int { leases[key] ?? 0 }

        /// Take a lease on `key` and say what to do next. A failed machine is
        /// retried immediately here: an `acquire` is a deliberate act (the user
        /// selected this row), not a background tick.
        mutating func acquire(_ key: String) -> Decision {
            leases[key, default: 0] += 1
            switch phase(key) {
            case .ready: return .deliverReady
            case .dialing: return .wait
            case .absent, .failed:
                phases[key] = .dialing
                return .dial
            }
        }

        /// What to do to (re)establish `key` WITHOUT taking a lease — the
        /// automatic path, driven by the chooser's existing poll tick. Honours
        /// the cooldown, and refuses to dial for a machine nobody is holding.
        mutating func ensure(_ key: String, now: Date) -> Decision {
            guard leaseCount(key) > 0 else { return .hold }
            switch phase(key) {
            case .ready: return .deliverReady
            case .dialing: return .wait
            case .absent:
                phases[key] = .dialing
                return .dial
            case .failed(let at):
                guard now.timeIntervalSince(at) >= redialCooldown else { return .hold }
                phases[key] = .dialing
                return .dial
            }
        }

        /// Give a lease back. Returns true iff that was the LAST one and the
        /// connection must now be torn down.
        ///
        /// A release against a machine with no leases is INERT, not a teardown.
        /// The pool's own `Lease.released` flag already makes a double-release a
        /// no-op, but the count must not be able to go negative-then-zero here
        /// either: that would report "tear it down" for a connection some LATER
        /// lease had since established.
        mutating func release(_ key: String) -> Bool {
            let current = leaseCount(key)
            guard current > 0 else { return false }
            let remaining = current - 1
            if remaining == 0 {
                leases[key] = nil
                phases[key] = nil
                return true
            }
            leases[key] = remaining
            return false
        }

        mutating func dialSucceeded(_ key: String) {
            // A dial that lands after the last lease dropped owns nothing: leave
            // the entry absent so the caller frees the connection it just made.
            guard leaseCount(key) > 0 else { return }
            phases[key] = .ready
        }

        mutating func dialFailed(_ key: String, at: Date) {
            guard leaseCount(key) > 0 else { return }
            phases[key] = .failed(at: at)
        }

        /// The live connection stopped being usable (the link went dead). Leaves
        /// the machine retryable after the cooldown, with its leases intact —
        /// the subscribers still want it, the socket just died.
        mutating func invalidate(_ key: String, at: Date) {
            guard leaseCount(key) > 0 else { return }
            phases[key] = .failed(at: at)
        }
    }

    // MARK: - State

    private var ledger = Ledger()

    /// Strong owners of the live connections, keyed like the ledger. Holding a
    /// `RemoteConnection` (rather than the raw handle) is what makes `borrow`
    /// safe: a background RPC can retain it for the length of its call.
    private var owners: [String: RemoteConnection] = [:]

    /// Live leases per key. Iterated over a snapshot when notifying, because a
    /// subscriber is allowed to `release()` from inside its own callback.
    private var leases: [String: [Lease]] = [:]

    /// Link-state observers, one per live connection, so a dead transport
    /// invalidates the entry instead of leaving every subscriber wired to a
    /// socket that will never speak again.
    private var linkObservers: [String: NSObjectProtocol] = [:]

    /// Generation per key, bumped on every teardown/invalidate, so a dial that
    /// completes after we moved on frees its connection instead of installing it.
    private var generations: [String: Int] = [:]

    // MARK: - Keying

    /// The pool's identity for a machine: the ENDPOINT, not the registry row.
    /// Two rows that point at the same relay device (or the same host:port)
    /// describe one agent and must share one connection.
    ///
    /// Pure, so `nonisolated`: it reads nothing but its argument.
    nonisolated static func key(for machine: Machine) -> String {
        if let base = machine.relayBase, let device = machine.deviceID {
            return "relay:\(base)|\(device)"
        }
        return "tcp:\(machine.host):\(machine.port)"
    }

    // MARK: - Acquire / release

    /// Take a warm connection for `machine`, dialing if this is the first
    /// borrower. Returns immediately; `onChange` reports readiness (see `Lease`).
    ///
    /// Capture your subscriber weakly in `onChange` — the pool holds the lease
    /// and the lease holds the closure.
    func acquire(
        machine: Machine,
        onChange: @escaping (ghostty_remote_connection_t?) -> Void
    ) -> Lease {
        let key = Self.key(for: machine)
        let lease = Lease(key: key, machine: machine, pool: self, onChange: onChange)
        leases[key, default: []].append(lease)

        switch ledger.acquire(key) {
        case .dial:
            startDial(machine: machine, key: key)
        case .wait:
            break  // the in-flight dial will notify every lease, including this one
        case .deliverReady:
            // Async so the caller can store the lease first, and modal-safe so a
            // confirmation alert can't swallow it (see the type comment). Read
            // the handle at DELIVERY time, not now: the connection may have died
            // (or been replaced) in between, and a lease must never be handed a
            // handle the pool has already let go of.
            onMainEvenWhenModal { [weak self, weak lease] in
                guard let self, let lease, !lease.released,
                      let live = self.owners[key]?.handle
                else { return }
                lease.onChange(live)
            }
        case .hold:
            break
        }
        return lease
    }

    /// Give a lease back. Tears the connection down when it was the last one.
    /// Idempotent — a second call on the same lease does nothing.
    func release(_ lease: Lease) {
        guard !lease.released else { return }
        lease.released = true
        let key = lease.key
        leases[key]?.removeAll { $0 === lease }
        if leases[key]?.isEmpty == true { leases[key] = nil }

        guard ledger.release(key) else { return }
        teardown(key)
    }

    /// Nudge a machine's connection back to life if it died or never came up —
    /// the automatic counterpart to `acquire`, driven by the chooser's existing
    /// roster tick so recovery costs no new timer. Honours the ledger's cooldown
    /// and never dials for a machine with no leases.
    func ensureConnected(machine: Machine) {
        let key = Self.key(for: machine)
        if case .dial = ledger.ensure(key, now: Date()) {
            startDial(machine: machine, key: key)
        }
    }

    // MARK: - Reading the connection

    /// The machine's warm handle if one is live, else nil.
    ///
    /// Safe for main-actor-only use (checking whether to subscribe). For a
    /// BLOCKING call on a background queue use `borrow` instead, which keeps the
    /// connection alive across the call.
    func handle(for machine: Machine) -> ghostty_remote_connection_t? {
        owners[Self.key(for: machine)]?.handle
    }

    /// True iff `machine` has a live warm connection.
    func isWarm(_ machine: Machine) -> Bool { handle(for: machine) != nil }

    /// Run a BLOCKING call against the machine's warm connection on a background
    /// queue. Returns false (having run nothing) when the machine has no warm
    /// connection — the caller then falls back to whatever it did before.
    ///
    /// The connection object is retained for the whole call, so the last lease
    /// dropping mid-RPC cannot free the handle underneath it; the retain is
    /// released back on the main actor because `RemoteConnection.deinit` frees
    /// the C handle and that must not happen on a background queue.
    @discardableResult
    func borrow(
        machine: Machine,
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping (ghostty_remote_connection_t) -> Void
    ) -> Bool {
        guard let owner = owners[Self.key(for: machine)] else { return false }
        let handle = owner.handle
        DispatchQueue.global(qos: qos).async {
            work(handle)
            onMainEvenWhenModal { withExtendedLifetime(owner) {} }
        }
        return true
    }

    // MARK: - Dialing

    /// Dial `machine` off the main thread and install the result. Relay machines
    /// resolve their account token first — ONCE per dial rather than once per
    /// poll tick, which is most of what this class saves them.
    private func startDial(machine: Machine, key: String) {
        let gen = bumpGeneration(key)

        if let base = machine.relayBase, let device = machine.deviceID {
            Task { @MainActor [weak self] in
                let token = await RelayAccount.resolveToken()
                guard let self else { return }
                guard self.generations[key] == gen else { return }
                guard let token else {
                    self.finishDial(key: key, gen: gen, machine: machine, handle: nil)
                    return
                }
                self.dialOffMain(key: key, gen: gen, machine: machine) {
                    AppDelegate.dialRelay(base: base, device: device, token: token)
                }
            }
            return
        }

        let host = machine.host
        let port = machine.port
        dialOffMain(key: key, gen: gen, machine: machine) {
            host.withCString { ghostty_remote_connection_new_tcp($0, port) }
        }
    }

    private func dialOffMain(
        key: String,
        gen: Int,
        machine: Machine,
        dial: @escaping () -> ghostty_remote_connection_t?
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Blocks through the HELLO handshake, so a non-nil handle is already
            // a negotiated connection.
            let handle = dial()
            onMainEvenWhenModal {
                guard let self else {
                    if let handle { ghostty_remote_connection_free(handle) }
                    return
                }
                self.finishDial(key: key, gen: gen, machine: machine, handle: handle)
            }
        }
    }

    /// Install (or discard) a completed dial and notify the machine's leases.
    private func finishDial(
        key: String,
        gen: Int,
        machine: Machine,
        handle: ghostty_remote_connection_t?
    ) {
        // Superseded (torn down, invalidated, re-dialed) while we were dialing:
        // this connection belongs to nobody.
        guard generations[key] == gen else {
            if let handle { ghostty_remote_connection_free(handle) }
            return
        }

        guard let handle else {
            ledger.dialFailed(key, at: Date())
            Self.logger.debug("warm dial failed for \(machine.endpoint, privacy: .public)")
            notify(key, nil)
            return
        }

        // The last lease may have dropped while the dial was in flight; the
        // ledger says so by refusing to go `.ready`, and we must not keep a
        // connection nobody asked for.
        ledger.dialSucceeded(key)
        guard case .ready = ledger.phase(key) else {
            ghostty_remote_connection_free(handle)
            return
        }

        let owner = RemoteConnection(handle: handle, machine: machine)
        owners[key] = owner
        observeLink(owner, key: key)
        Self.logger.info("warm connection ready for \(machine.endpoint, privacy: .public)")
        notify(key, handle)
    }

    // MARK: - Invalidation

    /// Watch one connection's transport FSM. Only `.dead` is acted on: the FSM
    /// enters `reconnecting` after a few missed heartbeats and snaps back on the
    /// next authentic packet, so treating a down EDGE as death would tear down
    /// working connections on a scheduler hiccup (the same reasoning as
    /// `LocalAgentManager.sharedLinkDropSettle`, without needing its settle
    /// window — nothing here rebuilds windows, it just re-dials).
    private func observeLink(_ owner: RemoteConnection, key: String) {
        if let existing = linkObservers[key] {
            NotificationCenter.default.removeObserver(existing)
        }
        linkObservers[key] = NotificationCenter.default.addObserver(
            forName: .ghosttyRemoteConnectionLinkDidChange,
            object: owner,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let conn = note.object as? RemoteConnection,
                      conn === self.owners[key],
                      conn.linkState == .dead
                else { return }
                self.invalidate(key)
            }
        }
    }

    /// Drop a connection that can no longer carry traffic, keeping its leases:
    /// subscribers are told (synchronously, so they unsubscribe before the free)
    /// and the machine becomes retryable after the ledger's cooldown.
    private func invalidate(_ key: String) {
        guard owners[key] != nil else { return }
        Self.logger.info("warm connection died for key \(key, privacy: .public); dropping it")
        ledger.invalidate(key, at: Date())
        _ = bumpGeneration(key)
        // Tell subscribers FIRST — they must stop using the handle before the
        // owner's last reference goes and its deinit frees it.
        notify(key, nil)
        detachOwner(key)
    }

    /// The last lease released: forget the machine entirely.
    private func teardown(_ key: String) {
        _ = bumpGeneration(key)
        detachOwner(key)
    }

    /// Remove the link observer and release the connection owner. Any in-flight
    /// `borrow` still holds its own reference, so the free happens after that
    /// call returns rather than underneath it.
    private func detachOwner(_ key: String) {
        if let observer = linkObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        owners[key] = nil
    }

    @discardableResult
    private func bumpGeneration(_ key: String) -> Int {
        let next = (generations[key] ?? 0) + 1
        generations[key] = next
        return next
    }

    /// Report a transition to every lease on `key`, synchronously (see the type
    /// comment: a `nil` means "stop using this handle now" and the free follows
    /// immediately). Iterates a snapshot — a subscriber may release from inside
    /// its own callback.
    private func notify(_ key: String, _ handle: ghostty_remote_connection_t?) {
        for lease in leases[key] ?? [] where !lease.released {
            lease.onChange(handle)
        }
    }
}
