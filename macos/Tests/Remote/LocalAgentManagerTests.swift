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
