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
        #expect(paths.lockFile.path == paths.directory.path + "/agent.lock")
        #expect(paths.heartbeatFile.path == paths.directory.path + "/agent.heartbeat")
        #expect(paths.logFile.path == paths.directory.path + "/agent.log")
    }
}

struct LocalAgentManagerPortFileTests {
    @Test func parsesTheAgentsExactBody() {
        // The agent writes {"port":N,"pid":P,"startedAt":MS}\n; startedAt is
        // intentionally ignored.
        let data = Data("{\"port\":59246,\"pid\":12345,\"startedAt\":1752500000000}\n".utf8)
        let parsed = LocalAgentManager.parsePortFile(data)
        #expect(parsed == LocalAgentManager.PortFile(port: 59246, pid: 12345))
    }

    @Test func rejectsGarbageZeroAndMissingFields() {
        #expect(LocalAgentManager.parsePortFile(Data()) == nil)
        #expect(LocalAgentManager.parsePortFile(Data("not json".utf8)) == nil)
        #expect(LocalAgentManager.parsePortFile(Data("{\"port\":0,\"pid\":1}".utf8)) == nil)
        #expect(LocalAgentManager.parsePortFile(Data("{\"port\":1,\"pid\":0}".utf8)) == nil)
        #expect(LocalAgentManager.parsePortFile(Data("{\"pid\":1}".utf8)) == nil)
        #expect(LocalAgentManager.parsePortFile(Data("{\"port\":1}".utf8)) == nil)
        // Out-of-range port must not crash the decoder path.
        #expect(LocalAgentManager.parsePortFile(Data("{\"port\":70000,\"pid\":1}".utf8)) == nil)
    }
}
