import SwiftUI

/// Observable backing for the titlebar machine pill / inline title. The hosting view
/// is created ONCE bound to this model; updating these `@Published` values re-renders
/// the SwiftUI body in place, which lets the titlebar accessory re-measure its width
/// (replacing the hosting view's `rootView` does NOT trigger that — see
/// TerminalWindow / ResetZoomAccessoryView for the same pattern).
final class MachinePillModel: ObservableObject {
    /// The machine display name, or nil when the window is local (pill hidden).
    @Published var machineName: String?

    /// The window title, rendered inline before the pill on the leading edge (so the
    /// pill sits right after the title). Kept in sync with the window's `title`.
    @Published var title: String = ""

    /// Whether the host window is key, to mirror the system title's label vs
    /// secondary-label color.
    @Published var isKeyWindow: Bool = true

    /// Top padding to vertically center content in the titlebar. Mirrors the
    /// reset-zoom / update accessories' `accessoryTopPadding` convention.
    @Published var topPadding: CGFloat = 4
}

/// The rounded "● name" capsule identifying which machine a window's terminals run
/// on. Renders nothing when `machineName` is nil.
struct MachinePillCapsule: View {
    let machineName: String?

    var body: some View {
        if let machineName {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(machineName)
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
            .help("Terminal runs on \(machineName)")
            .accessibilityLabel("Remote machine \(machineName)")
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
                MachinePillCapsule(machineName: model.machineName)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, model.topPadding)
        // Leading inset roughly aligning with where the system title starts.
        .padding(.leading, 6)
    }
}
