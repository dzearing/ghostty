import SwiftUI

/// A small, tasteful capsule shown at the trailing edge of a remote window's
/// titlebar identifying which machine the window's terminals run on.
///
/// Rendered as a rounded "● name" badge with a subtle translucent background so
/// it reads cleanly in both light and dark appearances. Hosted in an
/// `NSTitlebarAccessoryViewController` on the trailing (`.right`) edge.
struct MachinePillView: View {
    /// The machine display name, or nil when the window is local (pill hidden).
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
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(.quaternary)
            )
            .padding(.trailing, 8)
            .help("Terminal runs on \(machineName)")
            .accessibilityLabel("Remote machine \(machineName)")
        }
    }
}
