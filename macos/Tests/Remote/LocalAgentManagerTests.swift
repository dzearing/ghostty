import Foundation
import Testing
@testable import Ghostty

/// Unit tests for LocalAgentManager's pure pieces: per-lineage path resolution
/// (debug and release apps must never share an agent) and port-file parsing
/// (the contract with the agent's `--port-file` writer).
struct LocalAgentManagerPathsTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    @Test func debugBundleGetsDebugLineage() {
        let paths = LocalAgentManager.Paths(
            bundleID: "com.dzearing.ghoztty.debug", home: home)
        #expect(paths.directory.path == "/Users/test/.config/ghoztty/local-agent-debug")
    }

    @Test func releaseBundleGetsReleaseLineage() {
        let paths = LocalAgentManager.Paths(
            bundleID: "com.dzearing.ghoztty", home: home)
        #expect(paths.directory.path == "/Users/test/.config/ghoztty/local-agent")
    }

    @Test func nilBundleIDFallsBackToReleaseLineage() {
        let paths = LocalAgentManager.Paths(bundleID: nil, home: home)
        #expect(paths.directory.path == "/Users/test/.config/ghoztty/local-agent")
    }

    @Test func stateFilesAreSiblingsInsideTheLineageDirectory() {
        let paths = LocalAgentManager.Paths(
            bundleID: "com.dzearing.ghoztty.debug", home: home)
        #expect(paths.portFile.path == paths.directory.path + "/port.json")
        #expect(paths.socketFile.path == paths.directory.path + "/agent.sock")
        #expect(paths.lockFile.path == paths.directory.path + "/agent.lock")
        #expect(paths.heartbeatFile.path == paths.directory.path + "/agent.heartbeat")
        #expect(paths.logFile.path == paths.directory.path + "/agent.log")
        #expect(paths.sessionsFile.path == paths.directory.path + "/sessions.json")
    }

    @Test func debugAndReleaseGetDistinctLaunchAgentLabels() {
        // The KeepAlive LaunchAgent jobs must never collide across lineages.
        let debug = LocalAgentManager.Paths(
            bundleID: "com.dzearing.ghoztty.debug", home: home)
        let release = LocalAgentManager.Paths(
            bundleID: "com.dzearing.ghoztty", home: home)
        #expect(debug.launchAgentLabel == "com.dzearing.ghoztty.debug.agent")
        #expect(release.launchAgentLabel == "com.dzearing.ghoztty.agent")
        #expect(debug.launchAgentLabel != release.launchAgentLabel)
    }

    @Test func launchAgentPlistLivesUnderTheRealHomeKeyedByLabel() {
        // launchd's gui/<uid> domain only reads ~/Library/LaunchAgents.
        let paths = LocalAgentManager.Paths(
            bundleID: "com.dzearing.ghoztty.debug", home: home)
        #expect(paths.launchAgentPlistURL.path ==
            "/Users/test/Library/LaunchAgents/com.dzearing.ghoztty.debug.agent.plist")
    }
}

struct LocalAgentManagerPortFileTests {
    @Test func parsesTheUDSInfoBody() {
        // The UDS agent writes {"port":0,"pid":P,"socket":"<path>","startedAt":MS}\n;
        // port is 0 (no TCP port) and the supervisor keys off `socket`.
        let data = Data(
            "{\"port\":0,\"pid\":12345,\"socket\":\"/Users/test/.config/ghoztty/local-agent-debug/agent.sock\",\"startedAt\":1752500000000}\n".utf8)
        let parsed = LocalAgentManager.parsePortFile(data)
        #expect(parsed == LocalAgentManager.PortFile(
            port: 0, pid: 12345,
            socket: "/Users/test/.config/ghoztty/local-agent-debug/agent.sock"))
    }

    @Test func stillParsesLegacyTCPBody() {
        // A legacy TCP agent wrote {"port":N,"pid":P,"startedAt":MS}\n (no
        // socket); it must still decode so a mid-upgrade port.json dials TCP.
        let data = Data("{\"port\":59246,\"pid\":12345,\"startedAt\":1752500000000}\n".utf8)
        let parsed = LocalAgentManager.parsePortFile(data)
        #expect(parsed == LocalAgentManager.PortFile(port: 59246, pid: 12345, socket: nil))
    }

    @Test func rejectsGarbageZeroAndMissingFields() {
        #expect(LocalAgentManager.parsePortFile(Data()) == nil)
        #expect(LocalAgentManager.parsePortFile(Data("not json".utf8)) == nil)
        // Neither a usable port nor a socket ⇒ rejected.
        #expect(LocalAgentManager.parsePortFile(Data("{\"port\":0,\"pid\":1}".utf8)) == nil)
        #expect(LocalAgentManager.parsePortFile(Data("{\"port\":1,\"pid\":0}".utf8)) == nil)
        #expect(LocalAgentManager.parsePortFile(Data("{\"pid\":1}".utf8)) == nil)
        #expect(LocalAgentManager.parsePortFile(Data("{\"port\":1}".utf8)) == nil)
        // A UDS record with a dead pid is rejected on the pid gate.
        #expect(LocalAgentManager.parsePortFile(
            Data("{\"port\":0,\"pid\":0,\"socket\":\"/tmp/a.sock\"}".utf8)) == nil)
        // An empty socket string is not a usable endpoint.
        #expect(LocalAgentManager.parsePortFile(
            Data("{\"port\":0,\"pid\":1,\"socket\":\"\"}".utf8)) == nil)
        // Out-of-range port must not crash the decoder path.
        #expect(LocalAgentManager.parsePortFile(Data("{\"port\":70000,\"pid\":1}".utf8)) == nil)
    }

    @Test func udsSocketWinsWhenBothPresent() {
        // A record that carries both a socket and a nonzero port still decodes;
        // dialExisting prefers the socket, but parse just needs one usable.
        let data = Data("{\"port\":5,\"pid\":9,\"socket\":\"/tmp/x.sock\"}".utf8)
        let parsed = LocalAgentManager.parsePortFile(data)
        #expect(parsed == LocalAgentManager.PortFile(port: 5, pid: 9, socket: "/tmp/x.sock"))
    }
}

/// The gate in front of in-place session recovery. Recovery replaces every
/// local window's surface tree, so it must only run on a link that is REALLY
/// down — not on the self-healing heartbeat blip that triggered the 2026-07-21
/// incident (`degraded → reconnecting → connected` in 27ms, agent never
/// restarted, five windows rebuilt for nothing).
struct SharedLinkDropVerdictTests {
    private let agentPid: pid_t = 77545

    private func evaluate(
        state: RemoteConnection.LinkState,
        shared: Bool = true,
        remaining: TimeInterval = 0,
        previous: pid_t? = nil,
        live: pid_t?
    ) -> LocalAgentManager.SharedLinkDropVerdict {
        LocalAgentManager.evaluateSharedLinkDrop(
            linkState: state,
            ownerIsCurrentShared: shared,
            settleRemaining: remaining,
            previousAgentPid: previous ?? agentPid,
            liveAgentPid: live)
    }

    // MARK: Link-state classification

    @Test func onlyNonCarryingStatesCountAsDown() {
        #expect(RemoteConnection.LinkState.connected.isDown == false)
        #expect(RemoteConnection.LinkState.degraded.isDown == false)
        #expect(RemoteConnection.LinkState.reconnecting.isDown == true)
        #expect(RemoteConnection.LinkState.reattaching.isDown == true)
        #expect(RemoteConnection.LinkState.dead.isDown == true)
    }

    // MARK: The regression — a transient edge must not trigger recovery

    @Test func aLinkThatHealsWithinTheWindowNeverTriggersRecovery() {
        // The incident, replayed: the edge fired, and by the time the settle
        // window is re-checked the FSM is back to connected.
        let verdict = evaluate(state: .connected, remaining: 1.75, live: agentPid)
        #expect(verdict == .linkRecovered)
        #expect(verdict.triggersRecovery == false)
    }

    @Test func healingIsHonoredEvenAfterTheWindowElapses() {
        let verdict = evaluate(state: .connected, remaining: -0.25, live: agentPid)
        #expect(verdict == .linkRecovered)
    }

    @Test func degradedIsNotADrop() {
        // Two missed heartbeats: the link is slow, not gone.
        #expect(evaluate(state: .degraded, remaining: -1, live: agentPid) == .linkRecovered)
    }

    @Test func stillDownInsideTheWindowKeepsWatching() {
        let verdict = evaluate(state: .reconnecting, remaining: 1.5, live: nil)
        #expect(verdict == .keepWatching)
        #expect(verdict.triggersRecovery == false)
    }

    @Test func aReplacedOwnerIsNeverRecovered() {
        // A racing new window already dialed a fresh shared connection: this
        // owner is nobody's transport, so rebuilding on it is meaningless.
        let verdict = evaluate(state: .dead, shared: false, remaining: -1, live: nil)
        #expect(verdict == .ownerReplaced)
        #expect(verdict.triggersRecovery == false)
    }

    @Test func aReplacedOwnerWinsOverEveryOtherSignal() {
        #expect(evaluate(
            state: .connected, shared: false, remaining: 1, live: agentPid) == .ownerReplaced)
    }

    // MARK: A confirmed drop still recovers — with an honest reason

    @Test func aRestartedAgentIsReportedAsARestart() {
        let verdict = evaluate(state: .dead, remaining: 0, live: 90210)
        #expect(verdict == .agentRestarted(previousPid: agentPid, currentPid: 90210))
        #expect(verdict.triggersRecovery)
    }

    @Test func aMissingAgentIsReportedAsARestartWithNoPid() {
        let verdict = evaluate(state: .reconnecting, remaining: 0, live: nil)
        #expect(verdict == .agentRestarted(previousPid: agentPid, currentPid: nil))
        #expect(verdict.triggersRecovery)
    }

    @Test func aLiveSameAgentIsReportedAsATransportFailureNotARestart() {
        // The log line that made the incident hard to diagnose asserted a
        // restart that never happened. Same pid ⇒ never claim one.
        let verdict = evaluate(state: .dead, remaining: 0, live: agentPid)
        #expect(verdict == .transportDown(pid: agentPid))
        #expect(verdict.triggersRecovery)
    }

    @Test func anUnknownPreviousPidCannotMasqueradeAsTheSameAgent() {
        // sharedAgentPid is 0 before any dial; pid 0 must never match.
        let verdict = evaluate(state: .dead, remaining: 0, previous: 0, live: 0)
        #expect(verdict == .agentRestarted(previousPid: 0, currentPid: 0))
    }
}
