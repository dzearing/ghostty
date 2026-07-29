import SwiftUI
#if canImport(AppKit)
import AppKit

extension AttributedString {
    /// Whether any run carries a clickable link. Link-free banner text renders
    /// with plain SwiftUI `Text`; only link-bearing runs are routed through
    /// `BannerText` so they can get the hover affordance (a dotted underline
    /// that becomes solid on hover) and the hit-testing that drives it.
    var hasBannerLink: Bool {
        runs.contains { $0.link != nil }
    }
}

/// Renders a piece of banner inline text via AppKit/TextKit so its links can
/// carry a real hover affordance: a **dotted** underline at rest that becomes a
/// **solid** underline while the pointer is over that specific link. SwiftUI
/// `Text` has no per-link hover hook and links live inline inside flowing/
/// wrapping runs, so the banner owns the hit-testing here instead.
///
/// Used only for runs that actually contain a link (`AttributedString
/// .hasBannerLink`); everything else stays plain SwiftUI `Text`, so the common
/// (link-free) banner is untouched. The three shapes mirror the SwiftUI call
/// sites it replaces:
///   - a wrapping block/cell (`width` set, or `width == nil` + `singleLine ==
///     false`) word-wraps up to `lineLimit` lines and tail-truncates,
///   - a `singleLine` run stays on one line and tail-truncates,
/// matching `Text(...).lineLimit(...).truncationMode(.tail)`.
struct BannerText: NSViewRepresentable {
    /// The pre-styled inline content (bold/italic/code/underline/link runs).
    let attributed: AttributedString

    /// Base font the runs render off of; traits (bold/italic/code) are layered
    /// on per run. Headings pass a larger semibold face; header cells pass bold.
    var baseFont: NSFont = .systemFont(ofSize: 12)

    /// Fixed content width (a table column). When nil the view fills the width
    /// SwiftUI proposes (a `.text` block) or sizes to its content (`singleLine`).
    var width: CGFloat? = nil

    /// Maximum wrapped lines before tail truncation (nil = unlimited).
    var lineLimit: Int? = nil

    /// One line, no wrapping (list-item content, headings, checkbox-cell runs).
    var singleLine: Bool = false

    /// Horizontal alignment of the (possibly wrapped) content.
    var alignment: NSTextAlignment = .left

    /// The pane the banner belongs to, used to resolve link actions (open in a
    /// new window / side pane, relative to this pane). Weak-held by the view.
    var surface: Ghostty.SurfaceView? = nil

    func makeNSView(context: Context) -> BannerTextView {
        BannerTextView()
    }

    func updateNSView(_ view: BannerTextView, context: Context) {
        view.appearance = NSAppearance(
            named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        view.linkSurface = surface
        view.configure(
            attributed: attributed,
            baseFont: baseFont,
            lineLimit: singleLine ? 1 : (lineLimit ?? 0),
            alignment: alignment,
            wraps: !singleLine)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView view: BannerTextView,
        context: Context
    ) -> CGSize? {
        // Wrapping width: the fixed column width if given; otherwise the width
        // SwiftUI proposes (a fill block); `.greatestFiniteMagnitude` means
        // "measure the content's natural single-line width" (single-line runs,
        // or an unspecified proposal).
        let containerWidth = width
            ?? (singleLine ? .greatestFiniteMagnitude
                           : (proposal.width.map { $0 > 0 ? $0 : .greatestFiniteMagnitude }
                              ?? .greatestFiniteMagnitude))
        let used = view.measuredSize(containerWidth: containerWidth)
        let resolvedWidth = width
            ?? (singleLine ? ceil(used.width)
                           : (proposal.width.flatMap { $0 > 0 ? $0 : nil } ?? ceil(used.width)))
        return CGSize(width: resolvedWidth, height: ceil(used.height))
    }
}

/// The TextKit-backed view behind `BannerText`. Lays out an attributed string
/// in a single text container, draws it, and tracks the mouse so the link under
/// the pointer renders with a solid underline while the rest stay dotted.
final class BannerTextView: NSView {
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()

    /// Character ranges of each link and its destination, for hit-testing.
    private var links: [(range: NSRange, url: URL)] = []
    /// The link range currently under the pointer (drawn with a solid
    /// underline; the rest render with a dotted one).
    private var hoveredLink: NSRange?

    /// The pane the banner belongs to; supplies the link-action context.
    weak var linkSurface: Ghostty.SurfaceView?

    /// Actions (open in new window / side pane / browser, copy) for the links
    /// in this view, anchored to `linkSurface`.
    private var linkOpener: BannerLinkOpener { BannerLinkOpener(surface: linkSurface) }

    private var trackingArea: NSTrackingArea?

    // TextKit lays glyphs from the top down; a flipped view matches that so the
    // container origin is the top-left and hit-test points need no y-flip.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textContainer.lineFragmentPadding = 0
        layoutManager.usesFontLeading = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    // MARK: Configuration

    /// Rebuild the styled string and layout parameters. Called from
    /// `updateNSView`; the container width is applied separately from the
    /// view's own frame (see `setFrameSize`) so measurement and display agree.
    func configure(
        attributed: AttributedString,
        baseFont: NSFont,
        lineLimit: Int,
        alignment: NSTextAlignment,
        wraps: Bool
    ) {
        let (ns, links) = Self.makeAttributed(attributed, baseFont: baseFont, alignment: alignment)
        self.links = links
        textStorage.setAttributedString(ns)
        textContainer.maximumNumberOfLines = lineLimit
        textContainer.lineBreakMode = .byTruncatingTail
        // A wrapping view fills its granted width; a single-line view keeps the
        // container wide so nothing wraps except by explicit width later.
        if !wraps {
            textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
        }
        hoveredLink = hoveredLink.flatMap { r in links.contains { $0.range == r } ? r : nil }
        needsDisplay = true
    }

    /// Measure the used size for a given container width without disturbing the
    /// hover state — used by `sizeThatFits`.
    func measuredSize(containerWidth: CGFloat) -> CGSize {
        textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).size
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Wrap to the width SwiftUI actually granted. `.greatestFiniteMagnitude`
        // container widths (single-line runs) were set in `configure` and are
        // left alone here.
        if textContainer.size.width != .greatestFiniteMagnitude {
            textContainer.size = CGSize(width: newSize.width, height: .greatestFiniteMagnitude)
        }
        needsDisplay = true
    }

    // MARK: Drawing

    /// A link's underline: round **dots** at rest, a **solid** 1pt line on
    /// hover. The dots are drawn by hand rather than with `NSUnderlineStyle
    /// .patternDot`, whose pattern reads as coarse dashes at this text size.
    private static let dotDiameter: CGFloat = 1.5
    private static let dotSpacing: CGFloat = 3   // center-to-center

    override func draw(_ dirtyRect: NSRect) {
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
        // Underlines are painted under the glyphs (they don't change glyph
        // advances), so hover only redraws — it never relayouts.
        NSColor.controlAccentColor.setFill()
        for (range, _) in links {
            drawLinkUnderline(charRange: range, solid: range == hoveredLink)
        }
    }

    /// Draw the underline for one link, per line fragment it spans (a link can
    /// wrap across lines in a wrapping cell). The current fill color is used.
    private func drawLinkUnderline(charRange: NSRange, solid: Bool) {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        var index = glyphRange.location
        let end = NSMaxRange(glyphRange)
        while index < end {
            var fragmentRange = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &fragmentRange)
            let segmentEnd = min(end, NSMaxRange(fragmentRange))
            let segment = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: index, length: segmentEnd - index),
                in: textContainer)
            // Sit the line just below the text baseline, a hair above the line
            // fragment's bottom edge so it clears typical descenders.
            let y = fragment.maxY - 2
            if solid {
                NSBezierPath(rect: NSRect(x: segment.minX, y: y - 0.5, width: segment.width, height: 1)).fill()
            } else {
                drawDots(fromX: segment.minX, toX: segment.maxX, y: y)
            }
            index = segmentEnd
        }
    }

    /// A row of evenly spaced round dots centered on `y`, from `fromX` to `toX`.
    private func drawDots(fromX: CGFloat, toX: CGFloat, y: CGFloat) {
        let d = Self.dotDiameter
        var x = fromX
        while x + d <= toX {
            NSBezierPath(ovalIn: NSRect(x: x, y: y - d / 2, width: d, height: d)).fill()
            x += Self.dotSpacing
        }
    }

    // MARK: Hit-testing & hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Only claim clicks that land on a link — points elsewhere fall through to
    /// the SwiftUI card beneath (e.g. its collapse-on-tap). Hover still works:
    /// the tracking area delivers `mouseMoved` regardless of hit-testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return linkRange(at: local) != nil ? self : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let range = linkRange(at: point)
        if range != hoveredLink {
            hoveredLink = range
            needsDisplay = true
        }
        (range != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredLink != nil {
            hoveredLink = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        // `hitTest` only routes clicks here when they land on a link, but
        // re-check so a non-link click falls through to the SwiftUI card
        // (whose tap collapses the banner).
        guard linkRange(at: convert(event.locationInWindow, from: nil)) != nil else {
            super.mouseDown(with: event)
            return
        }
        // Consume the drag/up sequence ourselves. If we let them dispatch
        // normally, the enclosing card's SwiftUI tap gesture would ALSO fire on
        // a link click and collapse the banner. Opening on mouse-up (only if it
        // ends on a link) matches standard click semantics.
        while let next = NSApp.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true) {
            guard next.type == .leftMouseUp else { continue }
            if let range = linkRange(at: convert(next.locationInWindow, from: nil)),
               let url = links.first(where: { $0.range == range })?.url {
                // Modifier-click routing: plain → side pane, Cmd → new window,
                // Cmd-Shift → system browser.
                let mods = next.modifierFlags
                if mods.contains(.command) && mods.contains(.shift) {
                    linkOpener.openInDefaultBrowser(url)
                } else if mods.contains(.command) {
                    linkOpener.openInNewWindow(url)
                } else {
                    linkOpener.openInSidePane(url)
                }
            }
            break
        }
    }

    /// Right-click on a link shows the standard link menu; elsewhere returns nil
    /// so the event falls through (points off links don't hit-test to us anyway).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let range = linkRange(at: convert(event.locationInWindow, from: nil)),
              let url = links.first(where: { $0.range == range })?.url else { return nil }
        return linkOpener.menu(for: url)
    }

    /// The link range under `point` (view coordinates), or nil if the point is
    /// not on a linked glyph.
    private func linkRange(at point: CGPoint) -> NSRange? {
        guard !links.isEmpty, textStorage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: point, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        // `glyphIndex(for:)` clamps to the nearest glyph even when the point is
        // past the text; reject points that don't actually land on the glyph.
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard glyphRect.contains(point) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        return links.first { NSLocationInRange(charIndex, $0.range) }?.range
    }

    // MARK: Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { textStorage.string }

    // MARK: AttributedString → NSAttributedString

    /// Convert the SwiftUI-styled `AttributedString` to an `NSAttributedString`
    /// with real AppKit attributes (fonts resolved per run, links tinted) and
    /// return the link ranges for hit-testing. Link underlines aren't attributes
    /// — they're drawn per-state (dotted / solid) in `drawLinkUnderline`.
    private static func makeAttributed(
        _ attributed: AttributedString,
        baseFont: NSFont,
        alignment: NSTextAlignment
    ) -> (NSAttributedString, [(range: NSRange, url: URL)]) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let result = NSMutableAttributedString()
        var links: [(range: NSRange, url: URL)] = []

        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font(for: run, base: baseFont),
                .paragraphStyle: paragraph,
            ]

            if let url = run.link {
                attrs[.foregroundColor] = NSColor.controlAccentColor
                let start = result.length
                result.append(NSAttributedString(string: text, attributes: attrs))
                links.append((
                    range: NSRange(location: start, length: (text as NSString).length),
                    url: url))
                continue
            }

            attrs[.foregroundColor] = NSColor.labelColor
            // `__underline__` (a non-link underline) stays a solid underline.
            let swiftUIUnderline: Text.LineStyle? = run.underlineStyle
            if swiftUIUnderline != nil {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: text, attributes: attrs))
        }

        return (result, links)
    }

    /// The font a run renders in: `base` with bold/italic traits layered on,
    /// or a monospaced face for a code run — matching how `SurfacePaneBanner`
    /// measures and draws its SwiftUI text.
    private static func font(for run: AttributedString.Runs.Run, base: NSFont) -> NSFont {
        let intent = run.inlinePresentationIntent ?? []
        var font = intent.contains(.code)
            ? NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
            : base
        var traits: NSFontTraitMask = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
        if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        return font
    }
}
#endif
