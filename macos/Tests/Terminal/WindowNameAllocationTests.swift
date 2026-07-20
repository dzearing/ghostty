import Testing
@testable import Ghostty

/// Regression tests for the auto window-name allocator ("window-1",
/// "window-2", …). Two windows must never hold the same target name: the
/// allocator restarts at zero every app launch while session restore
/// re-adopts names persisted by a PREVIOUS run, so any adopted name has to
/// push the allocator past its number or the new run re-mints it (the
/// observed bug: a restored "window-3" plus a fresh "window-3").
///
/// The allocator is process-global state, so every expectation is relative
/// to a freshly minted baseline rather than an absolute counter value.
@MainActor
@Suite struct WindowNameAllocationTests {
    private func number(of name: String) -> Int? {
        Int(name.dropFirst("window-".count))
    }

    @Test func mintIsMonotonic() throws {
        let a = try #require(number(of: BaseTerminalController.mintWindowName()))
        let b = try #require(number(of: BaseTerminalController.mintWindowName()))
        #expect(b == a + 1)
    }

    @Test func adoptedNameIsNeverReminted() throws {
        // Session restore adopts a name whose number is ahead of this run's
        // counter. Without reservation the allocator would hand the same
        // name to a later fresh window.
        let base = try #require(number(of: BaseTerminalController.mintWindowName()))
        let adopted = "window-\(base + 5)"
        BaseTerminalController.reserveWindowName(adopted)

        for _ in 0..<10 {
            #expect(BaseTerminalController.mintWindowName() != adopted)
        }
    }

    @Test func reservationResumesNumberingPastAdoptedName() throws {
        let base = try #require(number(of: BaseTerminalController.mintWindowName()))
        BaseTerminalController.reserveWindowName("window-\(base + 5)")
        let next = try #require(number(of: BaseTerminalController.mintWindowName()))
        #expect(next == base + 6)
    }

    @Test func reservingOlderNameDoesNotRewindAllocator() throws {
        let base = try #require(number(of: BaseTerminalController.mintWindowName()))
        BaseTerminalController.reserveWindowName("window-1")
        let next = try #require(number(of: BaseTerminalController.mintWindowName()))
        #expect(next == base + 1)
    }

    @Test func nonAutoNamesDoNotDisturbAllocator() throws {
        let base = try #require(number(of: BaseTerminalController.mintWindowName()))
        BaseTerminalController.reserveWindowName("ide")
        BaseTerminalController.reserveWindowName("window-x")
        BaseTerminalController.reserveWindowName("window--7")
        BaseTerminalController.reserveWindowName("window-")
        let next = try #require(number(of: BaseTerminalController.mintWindowName()))
        #expect(next == base + 1)
    }
}
