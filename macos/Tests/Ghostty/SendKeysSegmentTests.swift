import Testing
@testable import Ghostty

/// The app half of the `+send-keys` wire contract: decoding the `--segments=`
/// payload the CLI sends when a call mixes text with keys.
struct SendKeysSegmentTests {
    typealias Segment = IPCServer.SendKeysSegment

    private func decode(_ encoded: String) -> [Segment]? {
        IPCServer.decodeSendKeysSegments(encoded)
    }

    @Test func decodesTextFollowedByKey() {
        // `+send-keys --target=t "some message" Enter` — the case the flat
        // payload could not express, because the receiver has to be able to
        // tell the trailing `\r` apart from the text before it.
        #expect(decode("t736f6d65,k0d") == [
            .init(kind: .text, bytes: Array("some".utf8)),
            .init(kind: .key, bytes: [0x0d]),
        ])
    }

    @Test func decodesRunsInOrder() {
        #expect(decode("k1b,t696162,k0d") == [
            .init(kind: .key, bytes: [0x1b]),
            .init(kind: .text, bytes: Array("iab".utf8)),
            .init(kind: .key, bytes: [0x0d]),
        ])
    }

    @Test func decodesNonUTF8AndControlBytes() {
        // Hex exists precisely so bytes that are not valid UTF-8 survive the
        // trip through a JSON string.
        #expect(decode("tff00fe") == [.init(kind: .text, bytes: [0xff, 0x00, 0xfe])])
    }

    @Test func decodesUppercaseHex() {
        #expect(decode("k0D") == [.init(kind: .key, bytes: [0x0d])])
    }

    // Malformed input returns nil so the caller falls back to the flat
    // `--keys=` payload — i.e. today's behaviour — rather than failing the
    // send outright.
    @Test(arguments: [
        "",             // empty
        "x0d",          // unknown kind tag
        "t",            // kind tag with no bytes
        "t0",           // odd number of hex digits
        "tzz",          // not hex
        "t6869,",       // trailing separator, so an empty run
        "0d",           // no kind tag
    ])
    func rejectsMalformedPayloads(_ encoded: String) {
        #expect(decode(encoded) == nil)
    }
}
