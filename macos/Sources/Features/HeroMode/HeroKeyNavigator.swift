import AppKit

/// Key handling for hero-mode navigation (Cmd/Ctrl+Shift+Up/Down).
///
/// This is a reference type on purpose. The local key monitor is installed
/// once, when hero mode appears, but SwiftUI re-creates the `HeroModeView`
/// struct with a new `tree` on every split change. A monitor closure that
/// captured that struct's `tree` would go on navigating the pane list as it
/// was when hero mode was entered: a pane added afterwards was unreachable
/// (Cmd+Shift+Down stopped one pane short of the end) and a pane closed
/// afterwards left the selection pointing past the end.
///
/// So the monitor holds no tree of its own. `HeroModeView` republishes the
/// live pane list from its body — the one place guaranteed to run with the
/// current tree — and every keystroke resolves against that.
final class HeroKeyNavigator {
    /// The hero state this navigator drives. Weak: it belongs to the window's
    /// controller, which outlives hero mode.
    private weak var state: HeroModeState?

    /// The panes hero mode is currently cycling through.
    private var leaves: [PaneView] = []

    private var monitor: Any?

    /// The window hero mode is mounted in, resolved live. Hero mode re-parents
    /// every pane's content view into its own layout, so any mounted leaf
    /// answers for the window. Nil until SwiftUI has mounted the panes.
    private var heroWindow: NSWindow? {
        leaves.lazy.compactMap(\.window).first
    }

    /// Refresh what navigation resolves against. Called from `HeroModeView`'s
    /// body on every render, so it always reflects the current split tree.
    func update(state: HeroModeState, leaves: [PaneView]) {
        self.state = state
        self.leaves = leaves
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// Returns nil when the event was consumed as hero navigation, otherwise
    /// the event so it continues on to the focused pane. Swallowing the event
    /// is what keeps this and the libghostty `goto_split` path (which also
    /// moves the hero selection, see `BaseTerminalController`) from both
    /// firing for one keystroke.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let state, state.isActive else { return event }
        guard leaves.count > 1 else { return event }
        guard event.modifierFlags.contains([.shift, .command]) else { return event }

        // The monitor is app-wide, so it also sees keystrokes aimed at other
        // windows — including another window that is itself in hero mode.
        // Navigate only the window the keystroke belongs to, or one press
        // would step every hero window at once (and each would then pull
        // focus to its own newly selected pane).
        guard let heroWindow, event.window === heroWindow else { return event }

        switch event.specialKey {
        case .upArrow:
            state.selectPrevious(leafCount: leaves.count)
            return nil

        case .downArrow:
            state.selectNext(leafCount: leaves.count)
            return nil

        default:
            return event
        }
    }
}
