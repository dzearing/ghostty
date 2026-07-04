import Testing
@testable import Ghostty

/// Unit tests for the `AXGhosttyLinkState` accessibility value grammar: the
/// stable machine-readable strings GUI automation parses instead of
/// screenshotting the pill dot. The grammar is a contract — changing it
/// breaks external consumers.
struct RemoteWindowConnectionStateAXValueTests {
    @Test func connected() {
        #expect(RemoteWindowConnectionState.connected.axValue == "connected")
    }

    @Test func reconnectingCarriesAttempt() {
        #expect(RemoteWindowConnectionState.reconnecting(attempt: 1).axValue
            == "reconnecting:1")
        #expect(RemoteWindowConnectionState.reconnecting(attempt: 3).axValue
            == "reconnecting:3")
    }

    @Test func disconnected() {
        #expect(RemoteWindowConnectionState.disconnected.axValue == "disconnected")
    }
}
