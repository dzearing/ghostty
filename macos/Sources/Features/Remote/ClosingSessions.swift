import Foundation

/// Session ids the user has closed but whose agent session has not gone away
/// yet, so the chooser can hide them immediately.
///
/// Closing a pane does not end its session at once. The view is retained by the
/// undo stack for `undo-timeout` (5s by default) so the close can be undone, and
/// only when it is finally freed does the agent get its CLOSE. For those few
/// seconds the session is genuinely still alive, so `LIST_SESSIONS` reports it
/// and the chooser renders it as a "Resume" row.
///
/// That row is a lie in the way that matters: the user closed that window, and
/// offering to resume it invites them to revive something they deliberately got
/// rid of. Worse, it makes a correctly-working close look like a leak — it was
/// mistaken for exactly that during this feature's development. The undo path is
/// Cmd-Z on the window, not a row in a machine picker.
///
/// So the app hides what it knows is on its way out. This is the same
/// optimistic-hide contract `SessionBrowserProbe.markKilled` already uses for the
/// chooser's own Kill button, just driven from the pane-close path instead: an id
/// is hidden from the moment it is marked, and forgotten once a roster refresh
/// confirms it is genuinely gone (so the set cannot grow without bound, and an
/// UNDONE close — which re-adopts the view and clears its close intent — comes
/// back correctly because `unmark` runs then).
@MainActor
final class ClosingSessions {
    static let shared = ClosingSessions()
    private init() {}

    private var ids: Set<String> = []

    /// Hide `id` from session listings: its pane is closed and its session is
    /// only alive for the remainder of the undo window.
    func mark(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        ids.insert(id)
    }

    /// Stop hiding `id` — the close was undone and the pane is live again.
    func unmark(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        ids.remove(id)
    }

    /// True if `id` should be hidden from session listings.
    func isClosing(_ id: String) -> Bool { ids.contains(id) }

    /// Drop ids the agent no longer reports: the close completed, so there is
    /// nothing left to hide and the set must not accumulate. `present` is the id
    /// set from a fresh roster.
    func reconcile(against present: Set<String>) {
        ids.formIntersection(present)
    }

    /// Filter a roster down to what the user should actually see.
    func visible(_ sessions: [BrowsedSession]) -> [BrowsedSession] {
        guard !ids.isEmpty else { return sessions }
        return sessions.filter { !ids.contains($0.id) }
    }
}
