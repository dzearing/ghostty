import SwiftUI
#if canImport(AppKit)
import AppKit

/// An `NSVisualEffectView` as a SwiftUI background.
///
/// SwiftUI's own `Material` styles pick both the blur radius and the vibrancy
/// for you, and for a small overlay their choice is too heavy: content passing
/// behind an `.ultraThinMaterial` header dissolves into a colored wash instead
/// of staying legible the way it does under a real sidebar header. Naming the
/// AppKit material directly (e.g. `.headerView`, which is the one a sidebar
/// header actually uses) is the only way to get the platform's own recipe.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
    }
}
// NOTE: a CoreImage `backgroundFilters` blur (which would let a caller pick
// its own radius) does NOT work inside an `NSHostingView`: the content behind
// the representable's layer is not composited where the filter can reach it,
// so the layer renders completely unblurred. There is no adjustable blur
// radius available here — pick a backdrop, don't try to tune one.

extension View {
    /// The platform's Liquid Glass behind this view, falling back to the
    /// closest pre-Tahoe material.
    ///
    /// Reach for this on a small overlay that content scrolls *under* — a
    /// pinned list header, say. Liquid Glass is the only backdrop macOS
    /// offers whose blur is scaled for something card-sized: an
    /// `NSVisualEffectView` (and every SwiftUI `Material`) blurs at one fixed,
    /// window-sized radius, which dissolves a passing row into a flat band.
    ///
    /// NOT for the glass CARD itself — see `GlassCardBackground`, which is
    /// hand-drawn precisely because a system material re-renders when the
    /// window's key state changes and visibly shifts the card's color.
    /// `tint` darkens (or colors) the glass. Pass the surface's own base color
    /// at partial opacity to keep the glass reading as part of that surface —
    /// untinted glass takes on whatever is passing behind it, which on a
    /// selected row means the header briefly turns accent-colored.
    @ViewBuilder
    func glassBackdrop(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: .rect)
        } else {
            self.background {
                ZStack {
                    VisualEffectBackground(
                        material: .headerView,
                        blendingMode: .withinWindow)
                    if let tint { tint }
                }
            }
        }
    }
}
#endif

/// The floating translucent card shared by every "glass" overlay in a pane —
/// the sticky pane banner (`Ghostty.SurfacePaneBanner`) and the viewer pane's
/// table of contents (`ViewerTOCPanel`).
///
/// This exists so those surfaces are identical *by construction* rather than
/// by two sets of hand-matched numbers: when a pane shows a banner above a
/// terminal and a TOC beside a rendered document, the two cards sit inches
/// apart and any drift between them reads as a bug.
enum GlassCard {
    /// Corner radius of the card. Paired with `.continuous` everywhere — the
    /// squircle is a large part of why the card reads as macOS chrome.
    static let cornerRadius: CGFloat = 14

    /// Uniform inner padding between the card's edge and its content.
    static let innerPadding: CGFloat = 12

    /// Margin between the card and the pane edges (the card floats rather
    /// than running edge to edge). Sized so the elevation shadow has room to
    /// render instead of being cut off at the pane edge.
    ///
    /// UNIFORM, and the single source of truth: every glass card leaves this
    /// same gap on all four sides. A per-side fudge (the banner used to shave
    /// its top to `outerMargin * 0.8`) is exactly what makes a banner in one
    /// pane and a TOC card in the next fail to line up at their corners — the
    /// two surfaces sit inches apart and any drift reads as a bug.
    static let outerMargin: CGFloat = 12

    /// The card's fill: a translucent wash over whatever sits behind it —
    /// white on a dark background, black on a light one. Compositing white at
    /// 6% is exactly `lighten(by: 0.06)` of the color behind (black at 4% is
    /// `darken(by: 0.04)`), so the card reads as a shade off its backdrop
    /// without ever holding a color of its own.
    static func fill(isLightBackground: Bool) -> AnyShapeStyle {
        isLightBackground
            ? AnyShapeStyle(Color.black.opacity(0.04))
            : AnyShapeStyle(Color.white.opacity(0.06))
    }

    /// Fallback fill for callers that cannot know their backdrop's color.
    static var materialFill: AnyShapeStyle { AnyShapeStyle(.ultraThinMaterial) }

    /// The card's shape.
    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// The card's glass look, drawn by hand: a translucent wash fill, an
/// elliptical specular sheen, a hairline rim, and a soft elevation shadow.
///
/// Deliberately NOT the system `glassEffect` — its material re-renders when
/// the window's key state changes (the backdrop flips `windowServerAware` and
/// its vibrancy layer turns off on resign), so the card visibly shifted color
/// on every window switch, and its frost washed the pane hue toward grey.
/// Hand-drawn overlays are deterministic: the card stays its backdrop's own
/// color no matter which window is focused.
struct GlassCardBackground: ViewModifier {
    let fill: AnyShapeStyle

    private var shape: RoundedRectangle { GlassCard.shape }

    /// Specular sheen: not a straight linear band but an ellipse of light
    /// centered above the card, so the highlight bulges down into the top in
    /// a curve and falls away toward the corners — plus a faint darkening
    /// along the bottom edge to ground the card. Attached as a background of
    /// the content so it renders above the material but below the text (an
    /// overlay would wash the glyphs too).
    private var sheen: some View {
        ZStack {
            shape.fill(
                EllipticalGradient(
                    stops: [
                        .init(color: .white.opacity(0.10), location: 0),
                        .init(color: .white.opacity(0.03), location: 0.6),
                        .init(color: .clear, location: 1),
                    ],
                    center: UnitPoint(x: 0.5, y: -0.5),
                    startRadiusFraction: 0,
                    endRadiusFraction: 1.15
                )
            )
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.75),
                        .init(color: .black.opacity(0.05), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .allowsHitTesting(false)
    }

    /// Specular rim: a hairline border lit by the same overhead ellipse —
    /// brightest at the top-center, softening around the upper corners,
    /// nearly gone along the bottom.
    private var rim: some View {
        shape.strokeBorder(
            EllipticalGradient(
                stops: [
                    .init(color: .white.opacity(0.28), location: 0),
                    .init(color: .white.opacity(0.10), location: 0.7),
                    .init(color: .white.opacity(0.04), location: 1),
                ],
                center: UnitPoint(x: 0.5, y: -0.5),
                startRadiusFraction: 0,
                endRadiusFraction: 1.3
            ),
            lineWidth: 1
        )
        .allowsHitTesting(false)
    }

    /// Elevation shadow as its own element. The card's fill is a
    /// near-transparent wash, so a `.shadow` on it would be scaled down by
    /// the fill's alpha to nothing — instead blur a dark copy of the shape,
    /// and mask the card's own interior out of it so the wash isn't darkened
    /// from behind.
    private var dropShadow: some View {
        shape
            .fill(Color.black.opacity(0.3))
            .blur(radius: 8)
            .offset(y: 4)
            .mask {
                ZStack {
                    Rectangle().fill(.white).padding(-24)
                    shape.fill(.black).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }

    func body(content: Content) -> some View {
        // Backgrounds stack front-to-back: sheen over the wash fill over the
        // drop shadow.
        content
            .background(sheen)
            .background(shape.fill(fill))
            .background(dropShadow)
            .overlay(rim)
    }
}
