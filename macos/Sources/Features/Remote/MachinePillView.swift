import SwiftUI

/// Observable backing for the titlebar machine pill / inline title. The hosting view
/// is created ONCE bound to this model; updating these `@Published` values re-renders
/// the SwiftUI body in place, which lets the titlebar accessory re-measure its width
/// (replacing the hosting view's `rootView` does NOT trigger that — see
/// TerminalWindow / ResetZoomAccessoryView for the same pattern).
final class MachinePillModel: ObservableObject {
    /// The machine display name, or nil when the window is local (pill hidden).
    @Published var machineName: String?

    /// WP-D1: the window's connection status. Drives the pill dot color
    /// (green = connected, yellow = reconnecting, red = disconnected) and a
    /// status suffix while not connected.
    @Published var connectionState: RemoteWindowConnectionState = .connected

    /// The window title, rendered inline before the pill on the leading edge (so the
    /// pill sits right after the title). Kept in sync with the window's `title`.
    @Published var title: String = ""

    /// Whether the host window is key, to mirror the system title's label vs
    /// secondary-label color.
    @Published var isKeyWindow: Bool = true

    /// Top padding to vertically center content in the titlebar. Mirrors the
    /// reset-zoom / update accessories' `accessoryTopPadding` convention.
    @Published var topPadding: CGFloat = 4

    /// Invoked when the pill capsule is clicked. Set by `TerminalWindow` (which
    /// knows its `remoteMachine` + `RemoteConnection`) to open the Remote Activity
    /// Monitor on the window's existing connection. Not `@Published` (it doesn't
    /// affect layout; it's read at tap time).
    var onTap: (() -> Void)?
}

/// The rounded "● name" capsule identifying which machine a window's terminals run
/// on. Renders nothing when `machineName` is nil. The dot reflects the window's
/// connection status (WP-D1): green = connected, yellow = reconnecting,
/// red = disconnected; a short status suffix is shown while not connected.
struct MachinePillCapsule: View {
    let machineName: String?
    var connectionState: RemoteWindowConnectionState = .connected

    private var dotColor: Color {
        switch connectionState {
        case .connected: return .green
        case .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

    private var label: String {
        guard let machineName else { return "" }
        switch connectionState {
        case .connected:
            return machineName
        case .reconnecting(let attempt):
            return "\(machineName) — reconnecting… (\(attempt))"
        case .disconnected:
            return "\(machineName) — disconnected"
        }
    }

    private var helpText: String {
        guard let machineName else { return "" }
        switch connectionState {
        case .connected:
            return "Terminal runs on \(machineName)"
        case .reconnecting(let attempt):
            return "Connection to \(machineName) lost — reconnecting (attempt \(attempt))"
        case .disconnected:
            return "Connection to \(machineName) lost — could not reconnect"
        }
    }

    var body: some View {
        if machineName != nil {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(.quaternary)
            )
            .help(helpText)
            .accessibilityLabel(helpText)
        }
    }
}

/// The leading titlebar view for a REMOTE window: the window title followed inline by
/// the machine pill. Used in place of the (hidden) system title so the machine reads
/// as "<title>  ● <machine>" left-aligned, vertically centered in the titlebar.
struct MachineTitlePillView: View {
    @ObservedObject var model: MachinePillModel

    var body: some View {
        // VStack + Spacer makes the accessory fill the titlebar height so topPadding
        // centers the row vertically (mirrors the ResetZoom accessory).
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.title)
                    // Match the system titlebar font/color (see TerminalWindow
                    // titlebarFont / attributedTitle).
                    .font(.system(size: 13))
                    .foregroundStyle(model.isKeyWindow ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The pill is a button so clicking it opens the Activity Monitor.
                // `.plain` keeps the capsule's own styling; hit-testing works
                // because the hosting view is a NonDraggableHostingView (clicks
                // are not swallowed by window dragging).
                Button {
                    model.onTap?()
                } label: {
                    MachinePillCapsule(
                        machineName: model.machineName,
                        connectionState: model.connectionState)
                }
                .buttonStyle(.plain)
                .help(model.machineName.map { "Open Activity Monitor for \($0)" } ?? "")
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, model.topPadding)
        // Leading inset roughly aligning with where the system title starts.
        .padding(.leading, 6)
    }
}
