import Foundation
import Testing
@testable import Ghostty

struct WhatsNewTrackingTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "whatsnew-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func firstRunReturnsNilThenStoresCurrent() {
        let (defaults, suite) = freshDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let prev = WhatsNewTracking.snapshotAndAdvance(current: "1.4.0", defaults: defaults)
        #expect(prev == nil)
        #expect(defaults.string(forKey: WhatsNewTracking.defaultsKey) == "1.4.0")
    }

    @Test func secondRunReturnsPreviousThenAdvances() {
        let (defaults, suite) = freshDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        _ = WhatsNewTracking.snapshotAndAdvance(current: "1.4.0", defaults: defaults)
        let prev = WhatsNewTracking.snapshotAndAdvance(current: "1.6.0", defaults: defaults)
        #expect(prev == "1.4.0")
        #expect(defaults.string(forKey: WhatsNewTracking.defaultsKey) == "1.6.0")
    }
}
