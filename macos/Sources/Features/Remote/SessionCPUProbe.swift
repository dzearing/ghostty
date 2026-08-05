import Foundation
import GhosttyKit

/// Live per-session CPU for the machine chooser's session rows, fed by the
/// agent's pushed `session_cpu` stream.
///
/// ## Pushed, not polled
/// The client asks for a cadence; the AGENT decides one. It floors the request,
/// stretches it when its own machine is loaded, and reports what it actually used
/// in every frame. A fixed client-side poll would hit a box hardest exactly when
/// it is already struggling, and the chooser has no way to know how loaded the far
/// end is — only the agent does.
///
/// ## One subscription at a time
/// The chooser is transient master-detail UI, so this follows the SELECTED target
/// and nothing else: switching rows tears the old subscription down before
/// starting the new one, and `stop()` on disappear guarantees no stream (and no
/// borrowed connection) outlives the page. Holding one open per machine would
/// mean N live connections for a panel the user closes in seconds.
///
/// ## Every machine gets a meter, and nobody dials twice
/// This used to dial its own TCP connection per machine, and to skip relay
/// machines entirely — the chooser was already dialing relays for
/// `LIST_SESSIONS`, and doing that dance a second time just to draw a meter was
/// not worth the connection. `MachineConnectionPool` removes both halves of that
/// trade: the roster and the meter now BORROW one warm connection per machine, so
/// relays get a meter and direct-TCP machines stop opening a second socket.
///
/// ## Degrading against an older agent
/// The stream is capability-gated. When the agent predates it,
/// `..._session_cpu_subscribe` returns false, `supported` goes false, and the
/// chooser shows no meter — never a stale or invented number, and never a
/// fallback poll the agent did not agree to.
///
/// The corrected-`cpu_pct` skew (`capability.cpu_units`) needs no gate here:
/// `session_cpu` was added AFTER the units fix in the same change set, so an
/// agent that can serve this stream at all necessarily reports corrected units.
@MainActor
final class SessionCPUProbe: ObservableObject {
    /// Per-core CPU% keyed by session id, covering each session's whole process
    /// tree. Empty until the first push lands.
    @Published private(set) var cpuBySession: [String: Float] = [:]

    /// False once we know the current target's agent cannot serve this stream.
    /// The chooser hides the meter entirely rather than showing a wrong number.
    @Published private(set) var supported = true

    /// The cadence the agent last told us it is using. Longer than requested
    /// means it is throttling itself, not that it has stalled.
    @Published private(set) var agentIntervalMs: UInt32 = 0

    /// The cadence we ASK for. Modest on purpose: this is a glanceable indicator
    /// on a transient page, and the agent will stretch it anyway under load.
    private static let requestedIntervalMs: UInt32 = 2000

    /// The key (`SessionBrowserProbe.localKey` or a machine uuid) currently
    /// subscribed, so a repeated select is a no-op instead of a churn of
    /// unsubscribe/dial.
    private var activeKey: String?

    /// The connection carrying the current subscription, and whether we own it.
    ///
    /// Every connection this probe uses today is BORROWED — the local agent's
    /// from `LocalAgentManager` (which owns it for the app's lifetime) and a
    /// machine's from `MachineConnectionPool` (which owns it for as long as our
    /// lease lives). The `owned` distinction stays because the invariant it
    /// encodes is the dangerous one: a borrowed handle must never be freed by
    /// `teardown()`, and anything that reintroduces a probe-dialed connection
    /// must say so here rather than inherit the wrong default.
    private var handle: ghostty_remote_connection_t?
    private var ownsHandle = false

    /// Retained box handed to C as userdata; released after unsubscribe.
    private var box: Unmanaged<CallbackBox>?

    /// The pool lease keeping the selected machine's connection warm. Released
    /// on every teardown, so the connection lasts exactly as long as the row is
    /// selected. Nil for the local agent (no lease — see `handle`).
    private var lease: MachineConnectionPool.Lease?

    /// Generation counter so a dial that completes after we've moved on (or
    /// stopped) drops its connection instead of installing a stale subscription.
    private var generation = 0

    fileprivate final class CallbackBox {
        weak var probe: SessionCPUProbe?
        init(probe: SessionCPUProbe) { self.probe = probe }
    }

    // MARK: Lifecycle

    /// Subscribe to the local agent's stream (the chooser's "This Mac" row).
    func subscribeLocal() {
        let key = SessionBrowserProbe.localKey
        guard activeKey != key else { return }
        teardown()
        activeKey = key
        generation += 1

        // Borrow the warm shared connection. If there isn't one we do without,
        // rather than dialing or spawning an agent just to draw a meter.
        guard let warm = LocalAgentManager.shared.warmSharedHandle else {
            supported = false
            return
        }
        install(handle: warm, owned: false)
    }

    /// Subscribe to a machine's stream over the pool's warm connection for it.
    ///
    /// Works for every transport, relays included: the pool did the dial (and,
    /// for a relay, the one token round-trip) once for the whole selection, and
    /// the roster is riding the same socket. Any lease from a previous selection
    /// is torn down first, and the generation check drops a connection that
    /// arrives after the user has moved on.
    func subscribe(machine: Machine) {
        let key = machine.id.uuidString
        guard activeKey != key else { return }
        teardown()
        activeKey = key
        generation += 1
        let gen = generation

        lease = MachineConnectionPool.shared.acquire(machine: machine) { [weak self] handle in
            guard let self, self.generation == gen, self.activeKey == key else { return }
            guard let handle else {
                // No connection (dial failed, or the link died under us). Drop
                // the stream and show no meter rather than a frozen last value.
                self.uninstall()
                self.supported = false
                return
            }
            self.install(handle: handle, owned: false)
        }
    }

    /// Tear everything down. Call when the chooser disappears — the whole point
    /// of a transient page is that it leaves nothing running behind it.
    func stop() {
        teardown()
        activeKey = nil
        generation += 1
    }

    // MARK: Internals

    private func install(handle newHandle: ghostty_remote_connection_t, owned: Bool) {
        // A machine whose connection died and was re-dialed reinstalls on the
        // same target: drop the old subscription first so its box isn't leaked
        // and no callback survives against a handle we no longer track.
        if handle != nil { uninstall() }
        let newBox = CallbackBox(probe: self)
        let unmanaged = Unmanaged.passRetained(newBox)
        let ok = ghostty_remote_connection_session_cpu_subscribe(
            newHandle,
            Self.requestedIntervalMs,
            sessionCPUTrampoline,
            unmanaged.toOpaque()
        )
        guard ok else {
            // Almost always an agent older than the capability. Not an error to
            // surface — just no meter.
            unmanaged.release()
            if owned { ghostty_remote_connection_free(newHandle) }
            supported = false
            return
        }
        handle = newHandle
        ownsHandle = owned
        box = unmanaged
        supported = true
    }

    /// Drop the subscription (and any OWNED connection) without giving the pool
    /// lease back — the target is unchanged, we just have no live stream on it.
    private func uninstall() {
        if let handle {
            // Unsubscribe FIRST so no callback can fire against a released box.
            ghostty_remote_connection_session_cpu_unsubscribe(handle)
            // Borrowed handles (every one today) belong to their owner; only a
            // handle this probe dialed itself is ours to free.
            if ownsHandle { ghostty_remote_connection_free(handle) }
        }
        handle = nil
        ownsHandle = false
        box?.release()
        box = nil
        cpuBySession = [:]
        agentIntervalMs = 0
    }

    private func teardown() {
        // Unsubscribe before releasing the lease: the pool may free the
        // connection the moment the last lease goes, and a live callback
        // registered on it would then fire into freed memory.
        uninstall()
        lease?.release()
        lease = nil
        supported = true
    }

    /// Apply one pushed sample. Main-actor.
    fileprivate func ingest(_ rows: [String: Float], intervalMs: UInt32) {
        cpuBySession = rows
        agentIntervalMs = intervalMs
    }
}

/// Global, capture-free C callback. Fires on the connection's control-reader
/// thread against borrowed storage, so it copies everything out BEFORE hopping to
/// main — the rows and their strings die the moment this returns.
private func sessionCPUTrampoline(
    _ rows: UnsafePointer<ghostty_session_cpu_s>?,
    _ len: Int,
    _ intervalMs: UInt32,
    _ ud: UnsafeMutableRawPointer?
) {
    guard let ud else { return }
    var copied: [String: Float] = [:]
    if let rows, len > 0 {
        copied.reserveCapacity(len)
        for i in 0..<len {
            let row = rows[i]
            copied[String(cString: row.id)] = row.cpu_pct
        }
    }
    let box = Unmanaged<SessionCPUProbe.CallbackBox>.fromOpaque(ud).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            box.probe?.ingest(copied, intervalMs: intervalMs)
        }
    }
}
