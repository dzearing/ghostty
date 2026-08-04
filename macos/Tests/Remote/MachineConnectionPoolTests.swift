import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the pure half of `MachineConnectionPool`: the endpoint keying
/// and the `Ledger` that decides when to dial, when to wait, and — the one that
/// actually hurts when it is wrong — when a connection may be torn down.
///
/// The C-handle plumbing (dial, subscribe, free) needs a live agent and is
/// exercised against one; everything that can regress SILENTLY lives here. A
/// connection freed while a subscriber still holds it crashes far from its cause,
/// and one never freed just leaks a socket per machine per chooser opening —
/// neither shows up in a screenshot.
struct MachineConnectionPoolTests {
    private func tcpMachine(host: String = "10.0.0.5", port: UInt16 = 7777) -> Machine {
        Machine(name: "box", host: host, port: port)
    }

    private func relayMachine(base: String = "https://relay.test", device: String = "dev-1") -> Machine {
        var m = Machine(name: "winbox", host: "relay", port: 0)
        m.relayBase = base
        m.deviceID = device
        return m
    }

    // MARK: Keying

    /// The pool keys on the ENDPOINT, not the registry row: two rows describing
    /// the same agent must share one connection, or the whole point (one warm
    /// connection per machine) is lost the moment the directory hands back a
    /// duplicate.
    @Test func keysOnEndpointNotRegistryIdentity() {
        let a = tcpMachine()
        let b = tcpMachine()
        #expect(a.id != b.id)
        #expect(MachineConnectionPool.key(for: a) == MachineConnectionPool.key(for: b))

        #expect(MachineConnectionPool.key(for: tcpMachine(port: 7778))
                != MachineConnectionPool.key(for: tcpMachine(port: 7777)))
    }

    /// A relay machine is identified by its device on its relay, never by the
    /// placeholder host/port those rows carry.
    @Test func keysRelayByDevice() {
        #expect(MachineConnectionPool.key(for: relayMachine())
                == MachineConnectionPool.key(for: relayMachine()))
        #expect(MachineConnectionPool.key(for: relayMachine(device: "dev-2"))
                != MachineConnectionPool.key(for: relayMachine(device: "dev-1")))
        // A relay row and a TCP row never collide.
        #expect(MachineConnectionPool.key(for: relayMachine())
                != MachineConnectionPool.key(for: tcpMachine()))
    }

    // MARK: Refcounting

    /// The first borrower dials; the second borrows what the first started. This
    /// is the whole reason the chooser's roster and its CPU meter stop opening
    /// two connections to the same machine.
    @Test func secondSubscriberJoinsTheFirstDial() {
        var ledger = MachineConnectionPool.Ledger()
        #expect(ledger.acquire("m") == .dial)
        #expect(ledger.acquire("m") == .wait)
        #expect(ledger.leaseCount("m") == 2)

        ledger.dialSucceeded("m")
        #expect(ledger.acquire("m") == .deliverReady)
        #expect(ledger.leaseCount("m") == 3)
    }

    /// Releasing one of several leases must NOT tear the connection down. This
    /// is the crash: the chooser switches selection, one probe lets go, the other
    /// is still subscribed, and the handle goes away underneath it.
    @Test func releaseTearsDownOnlyOnTheLastLease() {
        var ledger = MachineConnectionPool.Ledger()
        _ = ledger.acquire("m")
        _ = ledger.acquire("m")
        ledger.dialSucceeded("m")

        #expect(ledger.release("m") == false)
        #expect(ledger.phase("m") == .ready)
        #expect(ledger.release("m") == true)
        #expect(ledger.phase("m") == .absent)
        #expect(ledger.leaseCount("m") == 0)
    }

    /// A release with nothing held must report NO teardown. Otherwise a stray
    /// second release would order the pool to free a connection that a later
    /// lease had since established.
    @Test func releaseBelowZeroIsInert() {
        var ledger = MachineConnectionPool.Ledger()
        _ = ledger.acquire("m")
        #expect(ledger.release("m") == true)
        #expect(ledger.release("m") == false)
        #expect(ledger.leaseCount("m") == 0)

        // ...and the machine can be taken up again cleanly afterwards.
        #expect(ledger.acquire("m") == .dial)
        #expect(ledger.leaseCount("m") == 1)
    }

    /// A dial that lands after the last lease dropped owns nothing: the entry
    /// stays absent so the caller frees the connection it just made instead of
    /// caching a socket for a page the user already closed.
    @Test func dialCompletingAfterTheLastReleaseIsNotInstalled() {
        var ledger = MachineConnectionPool.Ledger()
        #expect(ledger.acquire("m") == .dial)
        #expect(ledger.release("m") == true)

        ledger.dialSucceeded("m")
        #expect(ledger.phase("m") == .absent)
    }

    // MARK: Re-dial policy

    /// An `acquire` is a user selecting the row, so it always gets an attempt
    /// even straight after a failure — no "try again in five seconds" for a
    /// deliberate act.
    @Test func acquireRetriesAFailedMachineImmediately() {
        var ledger = MachineConnectionPool.Ledger()
        _ = ledger.acquire("m")
        ledger.dialFailed("m", at: Date())

        #expect(ledger.acquire("m") == .dial)
        #expect(ledger.phase("m") == .dialing)
    }

    /// The automatic path is the opposite: it rides the chooser's existing 2s
    /// roster tick, so without a cooldown an unreachable machine would be dialed
    /// every two seconds for as long as the panel is open.
    @Test func ensureBacksOffAfterAFailure() {
        var ledger = MachineConnectionPool.Ledger()
        ledger.redialCooldown = 5
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = ledger.acquire("m")
        ledger.dialFailed("m", at: t0)

        #expect(ledger.ensure("m", now: t0.addingTimeInterval(2)) == .hold)
        #expect(ledger.ensure("m", now: t0.addingTimeInterval(5)) == .dial)
    }

    /// Nobody holding the machine means nobody wants it: the tick must not
    /// resurrect a connection for a row the user has navigated away from.
    @Test func ensureNeverDialsForAnUnheldMachine() {
        var ledger = MachineConnectionPool.Ledger()
        #expect(ledger.ensure("m", now: Date()) == .hold)
        #expect(ledger.phase("m") == .absent)
    }

    /// A dead link keeps its leases — the subscribers still want this machine,
    /// its socket just died — and becomes retryable after the cooldown. Losing
    /// the leases here would silently downgrade the roster to polling forever.
    @Test func invalidationKeepsLeasesAndStaysRetryable() {
        var ledger = MachineConnectionPool.Ledger()
        ledger.redialCooldown = 5
        let t0 = Date(timeIntervalSince1970: 2_000)
        _ = ledger.acquire("m")
        _ = ledger.acquire("m")
        ledger.dialSucceeded("m")

        ledger.invalidate("m", at: t0)
        #expect(ledger.leaseCount("m") == 2)
        #expect(ledger.phase("m") == .failed(at: t0))
        #expect(ledger.ensure("m", now: t0.addingTimeInterval(1)) == .hold)
        #expect(ledger.ensure("m", now: t0.addingTimeInterval(6)) == .dial)
    }

    /// Machines are independent: one unreachable box must not hold up another.
    @Test func machinesAreTrackedIndependently() {
        var ledger = MachineConnectionPool.Ledger()
        #expect(ledger.acquire("a") == .dial)
        #expect(ledger.acquire("b") == .dial)
        ledger.dialSucceeded("a")
        ledger.dialFailed("b", at: Date())

        #expect(ledger.phase("a") == .ready)
        #expect(ledger.release("a") == true)
        #expect(ledger.leaseCount("b") == 1)
        #expect(ledger.phase("b") != .absent)
    }
}
