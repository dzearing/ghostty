import Foundation
import Testing
@testable import Ghostty

/// The machine chooser's session-list ordering: the comparator behind the CPU
/// and Name column headers, and the keyboard cursor that has to survive the
/// list re-sorting underneath it.
///
/// Both are pure functions over a roster, which is exactly why they live
/// outside the view — a SwiftUI body is not a place you can assert against.
struct MachineChooserSessionSortTests {
    // MARK: - Fixtures

    /// `BrowsedSession` is decode-only (no memberwise init), so fixtures go
    /// through the same JSON path the agent's roster does.
    private func session(
        id: String,
        title: String? = nil,
        alive: Bool = true,
        cwd: String? = nil,
        pid: Int64 = 1
    ) throws -> BrowsedSession {
        var object: [String: Any] = ["id": id, "alive": alive, "pid": pid]
        if let title { object["title"] = title }
        if let cwd { object["cwd"] = cwd }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(BrowsedSession.self, from: data)
    }

    /// Sort by the label the row shows, with no CPU readings at all.
    private func sortedNames(
        _ sessions: [BrowsedSession],
        by order: MachineChooserSessionSort.Order,
        cpu: [String: Float] = [:]
    ) -> [String] {
        MachineChooserSessionSort.sorted(
            sessions,
            by: order,
            label: { $0.label() },
            cpu: { cpu[$0.id] }
        ).map { $0.label() }
    }

    // MARK: - Name column

    /// Sorting by name orders by the string on screen, not by the opaque
    /// session id behind it — the ids here sort in the exact opposite order.
    @Test func nameSortsByTheLabelTheUserSees() throws {
        let sessions = [
            try session(id: "zzz-1", title: "apples"),
            try session(id: "aaa-2", title: "bananas"),
            try session(id: "mmm-3", title: "cherries"),
        ]
        #expect(sortedNames(sessions, by: .init(key: .name, ascending: true))
            == ["apples", "bananas", "cherries"])
        #expect(sortedNames(sessions, by: .init(key: .name, ascending: false))
            == ["cherries", "bananas", "apples"])
    }

    /// Case must not split the alphabet into two runs — "Zebra" belongs after
    /// "apple", not in a separate uppercase block ahead of it.
    @Test func nameSortIsCaseInsensitive() throws {
        let sessions = [
            try session(id: "1", title: "Zebra"),
            try session(id: "2", title: "apple"),
            try session(id: "3", title: "Mango"),
        ]
        #expect(sortedNames(sessions, by: .init(key: .name, ascending: true))
            == ["apple", "Mango", "Zebra"])
    }

    /// The label falls back through the same chain the row renders, so a
    /// session with no title sorts by the cwd basename it actually displays.
    @Test func nameSortUsesTheRowsFallbackLabel() throws {
        let sessions = [
            try session(id: "1", title: "zulu"),
            try session(id: "2", cwd: "/Users/dz/git/alpha"),
        ]
        #expect(sortedNames(sessions, by: .init(key: .name, ascending: true))
            == ["alpha", "zulu"])
    }

    // MARK: - CPU column

    @Test func cpuSortsHighestFirstWhenDescending() throws {
        let sessions = [
            try session(id: "1", title: "idle"),
            try session(id: "2", title: "busy"),
            try session(id: "3", title: "middling"),
        ]
        let cpu: [String: Float] = ["1": 0, "2": 412, "3": 37]
        #expect(sortedNames(sessions, by: .init(key: .cpu, ascending: false), cpu: cpu)
            == ["busy", "middling", "idle"])
        #expect(sortedNames(sessions, by: .init(key: .cpu, ascending: true), cpu: cpu)
            == ["idle", "middling", "busy"])
    }

    /// A session with no reading yet sorts as 0% — matching its blank meter,
    /// rather than being flung to whichever end an "unknown" sentinel picked.
    @Test func missingCPUReadingSortsAsZero() throws {
        let sessions = [
            try session(id: "1", title: "unmeasured"),
            try session(id: "2", title: "busy"),
        ]
        #expect(sortedNames(sessions, by: .init(key: .cpu, ascending: false), cpu: ["2": 50])
            == ["busy", "unmeasured"])
    }

    /// The whole reason CPU sorting is tolerable on a live-updating list: rows
    /// are ordered by the WHOLE percent the meter draws, so sub-point jitter in
    /// the pushed reading cannot reshuffle rows that look identical.
    @Test func cpuSortIgnoresJitterBelowTheDisplayedPercent() throws {
        let sessions = [
            try session(id: "1", title: "alpha"),
            try session(id: "2", title: "bravo"),
        ]
        // Two consecutive pushes that both render as "12%" on every row.
        let tick1: [String: Float] = ["1": 12.2, "2": 12.4]
        let tick2: [String: Float] = ["1": 12.4, "2": 12.2]
        let order = MachineChooserSessionSort.Order(key: .cpu, ascending: false)
        #expect(sortedNames(sessions, by: order, cpu: tick1)
            == sortedNames(sessions, by: order, cpu: tick2))
    }

    /// Equal values fall through to name and then to id, and that tiebreak is
    /// FIXED — flipping the CPU direction must not also reverse a block of
    /// equal-CPU rows, or every idle session on the machine changes place.
    @Test func equalCPUKeepsOneDeterministicOrderInBothDirections() throws {
        let sessions = [
            try session(id: "3", title: "charlie"),
            try session(id: "1", title: "alpha"),
            try session(id: "2", title: "bravo"),
        ]
        let cpu: [String: Float] = ["1": 0, "2": 0, "3": 0]
        #expect(sortedNames(sessions, by: .init(key: .cpu, ascending: false), cpu: cpu)
            == ["alpha", "bravo", "charlie"])
        #expect(sortedNames(sessions, by: .init(key: .cpu, ascending: true), cpu: cpu)
            == ["alpha", "bravo", "charlie"])
    }

    /// Identically-labeled sessions still get a total order, so `sorted(by:)`
    /// — which is not a stable sort — cannot swap them between renders.
    @Test func identicalLabelsFallBackToSessionID() throws {
        let sessions = [
            try session(id: "b", title: "claude"),
            try session(id: "a", title: "claude"),
        ]
        let sorted = MachineChooserSessionSort.sorted(
            sessions,
            by: .init(key: .name, ascending: true),
            label: { $0.label() },
            cpu: { _ in nil })
        #expect(sorted.map(\.id) == ["a", "b"])
    }

    @Test func displayedCPURoundsToTheDrawnPercent() {
        #expect(MachineChooserSessionSort.displayedCPU(nil) == 0)
        #expect(MachineChooserSessionSort.displayedCPU(0.4) == 0)
        #expect(MachineChooserSessionSort.displayedCPU(0.6) == 1)
        #expect(MachineChooserSessionSort.displayedCPU(412.3) == 412)
    }

    // MARK: - Header interaction

    @Test func clickingTheActiveColumnFlipsItsDirection() {
        let ascending = MachineChooserSessionSort.Order(key: .name, ascending: true)
        let flipped = MachineChooserSessionSort.toggled(ascending, clicking: .name)
        #expect(flipped == .init(key: .name, ascending: false))
        #expect(MachineChooserSessionSort.toggled(flipped, clicking: .name) == ascending)
    }

    /// Switching columns starts each in the direction that column is actually
    /// useful in: names A→Z, CPU busiest-first.
    @Test func clickingAnInactiveColumnUsesItsNaturalDirection() {
        let byName = MachineChooserSessionSort.Order(key: .name, ascending: true)
        #expect(MachineChooserSessionSort.toggled(byName, clicking: .cpu)
            == .init(key: .cpu, ascending: false))

        let byCPU = MachineChooserSessionSort.Order(key: .cpu, ascending: false)
        #expect(MachineChooserSessionSort.toggled(byCPU, clicking: .name)
            == .init(key: .name, ascending: true))
    }

    // MARK: - Keyboard cursor

    /// The cursor is anchored to a session, so a re-sort moves the row under it
    /// and the cursor goes with it. An index would have stayed at slot 0 and
    /// silently switched which session Return resumes.
    @Test func cursorStaysOnItsSessionAcrossAResort() throws {
        let sessions = [
            try session(id: "quiet", title: "alpha"),
            try session(id: "hot", title: "zulu"),
        ]
        let cpu: [String: Float] = ["quiet": 0, "hot": 300]
        let byName = MachineChooserSessionSort.sorted(
            sessions, by: .init(key: .name, ascending: true),
            label: { $0.label() }, cpu: { cpu[$0.id] })
        let byCPU = MachineChooserSessionSort.sorted(
            sessions, by: .init(key: .cpu, ascending: false),
            label: { $0.label() }, cpu: { cpu[$0.id] })

        // The two orders genuinely differ, so slot 0 is a different session.
        #expect(byName.map(\.id) == ["quiet", "hot"])
        #expect(byCPU.map(\.id) == ["hot", "quiet"])

        // Anchored on "quiet" at slot 0 of the name order, the cursor is at
        // slot 1 of the CPU order — stepping DOWN from it there has nowhere to
        // go but stay, while an index-0 cursor would have stepped onto "quiet".
        #expect(MachineChooserSessionSort.cursorID(steppingBy: 1, from: "quiet", in: byCPU)
            == "quiet")
        #expect(MachineChooserSessionSort.cursorID(steppingBy: -1, from: "quiet", in: byCPU)
            == "hot")
    }

    @Test func cursorStepsThroughTheDisplayedOrder() throws {
        let sessions = [
            try session(id: "1", title: "a"),
            try session(id: "2", title: "b"),
            try session(id: "3", title: "c"),
        ]
        #expect(MachineChooserSessionSort.cursorID(steppingBy: 1, from: "1", in: sessions) == "2")
        #expect(MachineChooserSessionSort.cursorID(steppingBy: 1, from: "2", in: sessions) == "3")
        #expect(MachineChooserSessionSort.cursorID(steppingBy: -1, from: "3", in: sessions) == "2")
    }

    /// Up from the first row exits the list, handing navigation back to the
    /// machine column.
    @Test func steppingAboveTheFirstRowLeavesTheList() throws {
        let sessions = [try session(id: "1", title: "a"), try session(id: "2", title: "b")]
        #expect(MachineChooserSessionSort.cursorID(steppingBy: -1, from: "1", in: sessions) == nil)
    }

    /// Down from the last row stays put rather than wrapping — wrapping past
    /// the end of a 47-row list is never what the hand meant.
    @Test func steppingPastTheLastRowStaysOnIt() throws {
        let sessions = [try session(id: "1", title: "a"), try session(id: "2", title: "b")]
        #expect(MachineChooserSessionSort.cursorID(steppingBy: 1, from: "2", in: sessions) == "2")
    }

    /// The anchored session exited (or was killed) while the cursor sat on it:
    /// the cursor leaves rather than landing on whatever took its place.
    @Test func aVanishedAnchorLeavesTheList() throws {
        let sessions = [try session(id: "1", title: "a")]
        #expect(MachineChooserSessionSort.cursorID(steppingBy: 1, from: "gone", in: sessions) == nil)
        #expect(MachineChooserSessionSort.cursorID(steppingBy: 1, from: "gone", in: []) == nil)
    }

    // MARK: - Persistence

    /// A scratch defaults suite, so these never touch the real preference.
    private func scratchDefaults(_ name: String) -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    @Test func unsetPreferenceReadsAsNameAscending() {
        let defaults = scratchDefaults("MachineChooserSessionSortTests.unset")
        defer { UserDefaults.standard.removePersistentDomain(forName: "MachineChooserSessionSortTests.unset") }
        #expect(MachineChooserSessionSort.load(from: defaults) == .initial)
        #expect(MachineChooserSessionSort.Order.initial == .init(key: .name, ascending: true))
    }

    @Test func chosenOrderSurvivesAReload() {
        let suite = "MachineChooserSessionSortTests.roundTrip"
        let defaults = scratchDefaults(suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        MachineChooserSessionSort.save(.init(key: .cpu, ascending: false), to: defaults)
        #expect(MachineChooserSessionSort.load(from: defaults) == .init(key: .cpu, ascending: false))

        MachineChooserSessionSort.save(.init(key: .name, ascending: false), to: defaults)
        #expect(MachineChooserSessionSort.load(from: defaults) == .init(key: .name, ascending: false))
    }

    /// A garbage or hand-edited key falls back instead of failing to load.
    @Test func unknownStoredColumnFallsBackToTheDefault() {
        let suite = "MachineChooserSessionSortTests.garbage"
        let defaults = scratchDefaults(suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        defaults.set("memory", forKey: "MachineChooserSessionSortKey")
        #expect(MachineChooserSessionSort.load(from: defaults) == .initial)
    }
}
