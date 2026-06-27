import SwiftUI

/// Observable backing for the titlebar machine pill. The pill's `NSHostingView` is
/// created ONCE with a view bound to this model; updating `machineName` re-renders
/// the SwiftUI body in place, which lets the titlebar accessory re-measure its width
/// (replacing the hosting view's `rootView` does NOT trigger that re-measure — see
/// TerminalWindow.updateMachinePill / ResetZoomAccessoryView for the same pattern).
final class MachinePillModel: ObservableObject {
    /// The machine display name, or nil when the window is local (pill renders empty).
    @Published var machineName: String?

    /// Top padding to vertically center the pill in the titlebar. Mirrors the
    /// reset-zoom / update accessories' `accessoryTopPadding` convention (titlebar
    /// accessories are top-aligned, so a few points of top inset centers them).
    @Published var topPadding: CGFloat = 4
}

/// A small, tasteful capsule shown at the trailing edge of a remote window's
/// titlebar identifying which machine the window's terminals run on.
///
/// Rendered as a rounded "● name" badge with a subtle translucent background so
/// it reads cleanly in both light and dark appearances. Hosted in an
/// `NSTitlebarAccessoryViewController` on the trailing (`.right`) edge. Renders
/// nothing (zero size) when `model.machineName` is nil, exactly like the reset-zoom
/// accessory does when the surface isn't zoomed.
struct MachinePillView: View {
    @ObservedObject var model: MachinePillModel

    var body: some View {
        if let machineName = model.machineName {
            // VStack + Spacer makes the accessory fill the titlebar height so the
            // top padding can center the capsule vertically (mirrors ResetZoom).
            VStack(spacing: 0) {
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
                Spacer(minLength: 0)
            }
            .padding(.top, model.topPadding)
            // Trailing inset so the capsule doesn't hug the window edge.
            .padding(.trailing, 10)
            .help("Terminal runs on \(machineName)")
            .accessibilityLabel("Remote machine \(machineName)")
        }
    }
}
