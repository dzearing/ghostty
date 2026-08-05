import Foundation

/// How the machine chooser's session list is ordered, plus the pure transforms
/// that apply it.
///
/// Kept out of `MachineChooserView` because none of it needs a view: the
/// comparator and the keyboard cursor's anchoring are plain functions over a
/// roster, and they are the two pieces of this feature most worth testing.
enum MachineChooserSessionSort {
    /// The sortable columns of the session list.
    enum Key: String {
        case name
        case cpu

        /// The direction a column starts in the first time it is clicked. Name
        /// reads A→Z; CPU reads busiest-first, because "what is eating this
        /// machine" is the only reason to sort by it.
        var startsAscending: Bool {
            switch self {
            case .name: return true
            case .cpu: return false
            }
        }

        /// The column header's label.
        var columnTitle: String {
            switch self {
            case .name: return "Name"
            case .cpu: return "CPU"
            }
        }
    }

    /// A column plus a direction — the whole sort state.
    struct Order: Equatable {
        var key: Key
        var ascending: Bool

        /// Name, A→Z. The roster arrives in the agent's own creation order,
        /// which is not an order anyone can predict or scan; alphabetical is,
        /// and it is the one order that does not move on its own.
        static let initial = Order(key: .name, ascending: true)
    }

    // MARK: - Interaction

    /// The order after clicking column `key`: the active column flips
    /// direction, an inactive one becomes active in its natural direction.
    static func toggled(_ order: Order, clicking key: Key) -> Order {
        order.key == key
            ? Order(key: key, ascending: !order.ascending)
            : Order(key: key, ascending: key.startsAscending)
    }

    // MARK: - Sorting

    /// The CPU value a row is sorted by: the whole percent the meter actually
    /// DISPLAYS, not the raw float behind it.
    ///
    /// This is what keeps a CPU-sorted list from twitching. The reading is
    /// re-pushed every couple of seconds and is noisy in its fractional digits,
    /// so comparing raw floats would reshuffle rows that look identical on
    /// screen. Rounding to the displayed integer means the order can only
    /// change when the number you are reading changes — and combined with the
    /// fixed name/id tiebreak below, a screenful of "0%" rows never moves at
    /// all.
    ///
    /// A missing reading (a dead session, or one the agent hasn't reported yet)
    /// sorts as 0, matching its blank meter.
    static func displayedCPU(_ pct: Float?) -> Int {
        guard let pct else { return 0 }
        return Int(pct.rounded())
    }

    /// Sort `sessions` for display.
    ///
    /// `label` must be the string the row actually SHOWS — the user sorts by
    /// what they can read, not by the opaque session id underneath it — and
    /// `cpu` the live reading behind its meter. Both are passed in rather than
    /// derived here because both depend on app state (open panes, the persisted
    /// layout manifest, the CPU stream) that this file has no business knowing
    /// about.
    ///
    /// Both keys are precomputed once per session: `label` walks a
    /// four-step fallback chain, and a comparator that recomputed it would run
    /// that chain O(n log n) times.
    ///
    /// The comparison is a TOTAL order — ties fall through to name and then to
    /// the session id, always ascending regardless of the primary direction.
    /// That is deliberate: `sorted(by:)` is not guaranteed stable, so without a
    /// final unique key equal rows could legitimately swap places on every
    /// re-render.
    static func sorted(
        _ sessions: [BrowsedSession],
        by order: Order,
        label: (BrowsedSession) -> String,
        cpu: (BrowsedSession) -> Float?
    ) -> [BrowsedSession] {
        let rows = sessions.map {
            SortRow(session: $0, name: label($0), cpu: displayedCPU(cpu($0)))
        }
        return rows.sorted { a, b in
            if let primary = compare(a, b, by: order) { return primary }
            // Fixed tiebreak, never flipped by `order.ascending`: the point is
            // that a group of equal values keeps ONE order no matter which way
            // the active column points.
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.session.id < b.session.id
        }.map(\.session)
    }

    /// The active column's comparison, or nil when it can't separate the two
    /// rows (equal values) and the tiebreak has to decide.
    private static func compare(_ a: SortRow, _ b: SortRow, by order: Order) -> Bool? {
        switch order.key {
        case .cpu:
            guard a.cpu != b.cpu else { return nil }
            return order.ascending ? a.cpu < b.cpu : a.cpu > b.cpu
        case .name:
            let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
            guard cmp != .orderedSame else { return nil }
            return order.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    /// A session with its two sort keys resolved.
    private struct SortRow {
        let session: BrowsedSession
        let name: String
        let cpu: Int
    }

    // MARK: - Keyboard cursor

    /// Where the keyboard session cursor lands when it steps by `delta` from
    /// the session anchored by `id`.
    ///
    /// `nil` means LEAVE the list, back to machine navigation: either the step
    /// went above the first row, or the anchored session is no longer in the
    /// roster (it exited, or was killed, while the cursor sat on it). Stepping
    /// past the last row stays on the last row.
    ///
    /// The cursor is anchored to a session ID rather than to an index, and that
    /// is the whole point of this function: the list re-sorts underneath it —
    /// when the user clicks a column header, and on any live CPU tick that
    /// changes a displayed percentage while sorted by CPU. An index would
    /// silently re-point at whatever slid into that slot; the ID follows the
    /// row the user is looking at.
    static func cursorID(
        steppingBy delta: Int,
        from id: String,
        in sessions: [BrowsedSession]
    ) -> String? {
        guard let current = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        let next = current + delta
        if next < 0 { return nil }
        if next >= sessions.count { return sessions.last?.id }
        return sessions[next].id
    }

    // MARK: - Persistence

    private static let keyDefaultsKey = "MachineChooserSessionSortKey"
    private static let ascendingDefaultsKey = "MachineChooserSessionSortAscending"

    /// The stored order, or `.initial` when the user has never chosen one.
    ///
    /// A preference rather than per-open state, matching the viewer's own
    /// chrome preferences (side-panel width, diff layout): how you want to read
    /// a list is a property of you, not of the machine that happened to be
    /// selected when you set it.
    static func load(from defaults: UserDefaults = .standard) -> Order {
        guard let raw = defaults.string(forKey: keyDefaultsKey),
              let key = Key(rawValue: raw)
        else { return .initial }
        // The two halves are always written together, so a stored key with no
        // stored direction means someone hand-edited defaults. Fall back to the
        // column's own natural direction rather than to a bare `false`.
        let ascending = defaults.object(forKey: ascendingDefaultsKey) as? Bool
            ?? key.startsAscending
        return Order(key: key, ascending: ascending)
    }

    static func save(_ order: Order, to defaults: UserDefaults = .standard) {
        defaults.set(order.key.rawValue, forKey: keyDefaultsKey)
        defaults.set(order.ascending, forKey: ascendingDefaultsKey)
    }
}
