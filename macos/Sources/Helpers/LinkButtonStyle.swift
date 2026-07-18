import SwiftUI

/// The shared, interactive text-link style for Ghoztty.
///
/// Every in-app text "link" (e.g. the account "Sign Out") should use this one
/// style so links look and behave the same everywhere — rather than each site
/// re-styling a button by hand. It gives a link proper interactive states:
///
/// - **Hover**: brighter color + an underline, and the link pointer (macOS 15+
///   via `Backport.pointerStyle`; a no-op cursor below that, color/underline
///   still apply).
/// - **Pressed**: a slight dim so the click registers.
///
/// Apply with `.buttonStyle(.ghosttyLink)` (or `.ghosttyLink(color:)` to tint
/// it, e.g. a destructive red link).
struct LinkButtonStyle: ButtonStyle {
    /// The link's base color. Defaults to the app accent (the conventional link
    /// color); pass a different color for e.g. a destructive link.
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration, color: color)
    }

    /// A hover-tracking wrapper — a `ButtonStyle` can read `isPressed` from its
    /// configuration but not hover, so the hover state lives in this nested View.
    private struct LinkLabel: View {
        let configuration: Configuration
        let color: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(color)
                // Brighten on hover, dim slightly while pressed.
                .brightness(configuration.isPressed ? -0.12 : (hovering ? 0.22 : 0))
                // Underline only on hover — the classic link affordance.
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(color)
                        .frame(height: 1)
                        .brightness(hovering ? 0.22 : 0)
                        .opacity(hovering ? 1 : 0)
                }
                .contentShape(Rectangle())
                .backport.pointerStyle(.link)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

extension ButtonStyle where Self == LinkButtonStyle {
    /// The shared interactive link style: `.buttonStyle(.ghosttyLink)`.
    static var ghosttyLink: LinkButtonStyle { LinkButtonStyle() }

    /// The shared link style tinted to `color` (e.g. a destructive red link).
    static func ghosttyLink(color: Color) -> LinkButtonStyle { LinkButtonStyle(color: color) }
}
