import AppKit
import Foundation
import Testing
@testable import Ghostty

// MARK: - Test fixtures

/// Writes throwaway image files for the suites below and cleans up after
/// itself. File scope, not nested in a `@MainActor` suite, for the same reason
/// `ViewerDiffPaneTests.Repo` is: an actor-isolated `deinit` running on an
/// arbitrary release thread takes the whole test runner down.
private final class ImageFixtures {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-image-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A PNG of exactly `width` x `height` PIXELS.
    @discardableResult
    func png(_ name: String, width: Int, height: Int) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = directory.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    @discardableResult
    func svg(_ name: String, width: Int, height: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" \
        viewBox="0 0 \(width) \(height)"><rect width="\(width)" height="\(height)" fill="#37f"/></svg>
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func text(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Zoom rules

/// The arithmetic behind an image pane: what 100% means, what best-fit is
/// allowed to do, and where a double-click lands. All of it is pure, so none
/// of these need a window, a screen, or a decoded image.
struct ViewerImageGeometryTests {
    /// A 2x display: 100% is one image pixel per DEVICE pixel, so a 400px-wide
    /// image occupies 200 POINTS. This is the whole "which definition of 100%"
    /// decision, asserted.
    @Test func hundredPercentIsOneImagePixelPerDevicePixel() {
        let g = ViewerImageGeometry(
            naturalSize: CGSize(width: 400, height: 300),
            unitScale: 1.0 / 2.0,
            viewportSize: CGSize(width: 1000, height: 1000))
        #expect(g.magnification(forZoom: 1) == 0.5)
        #expect(g.naturalSize.width * g.magnification(forZoom: 1) == 200)
    }

    /// Vector art has no pixel grid to be 1:1 with, so 100% is its intrinsic
    /// size in points — the same drawing on a 1x and a 2x screen is the same
    /// physical size, which is the point of vector art.
    @Test func vectorArtMeasuresInPoints() {
        let g = ViewerImageGeometry(
            naturalSize: CGSize(width: 200, height: 200),
            unitScale: 1,
            viewportSize: CGSize(width: 1000, height: 1000))
        #expect(g.magnification(forZoom: 1) == 1)
    }

    /// A large image is shrunk to fit both axes.
    @Test func fitShrinksALargeImage() {
        let g = ViewerImageGeometry(
            naturalSize: CGSize(width: 2000, height: 1000),
            unitScale: 1.0 / 2.0,
            viewportSize: CGSize(width: 500, height: 500))
        // Width binds: 2000px * unitScale = 1000pt at 100%, viewport is 500pt.
        #expect(abs(g.fitZoom - 0.5) < 0.0001)
    }

    /// The documented decision: best-fit NEVER enlarges. A 32px icon in a big
    /// pane stays 32 device pixels, crisp and centered, rather than being
    /// blown up into a blurry lie about the asset.
    @Test func fitNeverUpscalesASmallImage() {
        let g = ViewerImageGeometry(
            naturalSize: CGSize(width: 32, height: 32),
            unitScale: 1.0 / 2.0,
            viewportSize: CGSize(width: 900, height: 700))
        #expect(g.fitZoom == 1)
    }

    /// A very large image needs a fit below the ordinary zoom floor, so the
    /// floor has to yield to it — otherwise the pane could not fit it at all.
    @Test func theZoomFloorNeverExcludesFit() {
        let g = ViewerImageGeometry(
            naturalSize: CGSize(width: 40000, height: 200),
            unitScale: 1.0 / 2.0,
            viewportSize: CGSize(width: 400, height: 400))
        #expect(g.fitZoom < ViewerImageGeometry.zoomFloor)
        #expect(g.minZoom == g.fitZoom)
        #expect(g.clamped(g.fitZoom) == g.fitZoom)
    }

    /// The contract: double-click toggles fit ⇄ 100%.
    @Test func doubleClickTogglesFitAndActualSize() {
        let g = ViewerImageGeometry(
            naturalSize: CGSize(width: 2000, height: 1000),
            unitScale: 1.0 / 2.0,
            viewportSize: CGSize(width: 500, height: 500))
        let fit = g.fitZoom
        #expect(fit < 1)
        #expect(g.doubleClickZoom(from: fit) == 1)
        #expect(g.doubleClickZoom(from: 1) == fit)
        // From anywhere else, back to fit.
        #expect(g.doubleClickZoom(from: 3) == fit)
    }

    /// The degenerate case the rule exists for: when the image already fits,
    /// fit AND 100% are the same zoom, so a plain toggle would visibly do
    /// nothing. The gesture goes to 200% instead, and back to fit after.
    @Test func doubleClickOnAnImageThatAlreadyFitsGoesTo200ThenBack() {
        let g = ViewerImageGeometry(
            naturalSize: CGSize(width: 32, height: 32),
            unitScale: 1.0 / 2.0,
            viewportSize: CGSize(width: 900, height: 700))
        #expect(g.fitZoom == 1)
        #expect(g.doubleClickZoom(from: 1) == 2)
        #expect(g.doubleClickZoom(from: 2) == 1)
    }

    /// Cmd-0 is "Actual Size", not "fit" — the same meaning `reset` has in
    /// every other viewer mode.
    @Test func keyboardZoomStepsAndResetsToActualSize() {
        let g = ViewerImageGeometry(
            naturalSize: CGSize(width: 2000, height: 1000),
            unitScale: 1.0 / 2.0,
            viewportSize: CGSize(width: 500, height: 500))
        #expect(g.stepped(from: 1, action: .reset) == 1)
        #expect(g.stepped(from: 1, action: .zoomIn) == ViewerImageGeometry.zoomStep)
        #expect(abs(g.stepped(from: 1, action: .zoomOut) - 1 / ViewerImageGeometry.zoomStep) < 0.0001)
        // And the steps stop at the ceiling rather than running away.
        #expect(g.stepped(from: ViewerImageGeometry.zoomCeiling, action: .zoomIn)
            == ViewerImageGeometry.zoomCeiling)
    }

    /// `NSImage.size` is DPI-derived and lies about pixel counts, which would
    /// silently halve "100%" for any image tagged at 144dpi. The natural size
    /// has to come from the representations.
    @Test func naturalSizeIsPixelsNotDPIScaledPoints() throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // What a 144-dpi tag does to an NSImage: half the size in points.
        rep.size = NSSize(width: 200, height: 100)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        #expect(image.size == NSSize(width: 200, height: 100))

        let natural = try #require(ViewerImageGeometry.naturalSize(of: image))
        #expect(natural.size == CGSize(width: 400, height: 200))
        #expect(!natural.isVector)
    }

    /// SVG loads with no pixel grid at all, which is exactly how vector art is
    /// detected — there is nothing else to detect it by.
    @Test func naturalSizeOfVectorArtIsItsIntrinsicSize() throws {
        let fixtures = try ImageFixtures()
        let url = try fixtures.svg("icon.svg", width: 120, height: 80)
        let image = try #require(NSImage(contentsOf: url))
        let natural = try #require(ViewerImageGeometry.naturalSize(of: image))
        #expect(natural.isVector)
        #expect(natural.size == CGSize(width: 120, height: 80))
    }
}

// MARK: - Mode classification

/// Which files open as an image pane, and what the rest of the viewer thinks
/// such a pane is.
@MainActor
struct ViewerImageModeTests {
    private func isImage(_ path: String) -> Bool {
        if case .image = ViewerView.mode(for: path) { return true }
        return false
    }

    @Test func imageExtensionsOpenAsAnImagePane() {
        for name in [
            "shot.png", "photo.JPG", "a.jpeg", "loop.gif", "art.webp",
            "phone.HEIC", "scan.tiff", "old.bmp", "icon.svg", "app.icns",
        ] {
            #expect(isImage("/tmp/\(name)"), "\(name) should open as an image")
        }
    }

    @Test func everythingElseKeepsItsOldMode() {
        #expect(!isImage("/tmp/readme.md"))
        #expect(!isImage("/tmp/main.swift"))
        #expect(!isImage("/tmp/mock.html"))
        #expect(!isImage("https://example.com/photo.png"))
        // A diff spec is not a path, so its text is never extension-matched.
        #expect(!isImage("git-diff:main...HEAD"))
    }

    /// An image pane is a FILE viewer in every structural respect: it names
    /// its file, it is titled by it, and it is not a live page (so it keeps
    /// the file-mode link routing and does not enable WebKit's swipe
    /// gestures).
    @Test func anImagePaneIsAFileViewer() throws {
        let fixtures = try ImageFixtures()
        let url = try fixtures.png("shot.png", width: 40, height: 40)
        let viewer = ViewerView(location: url.path)
        #expect(viewer.isImageMode)
        #expect(viewer.fileURL?.path == url.path)
        #expect(viewer.location == url.path)
        #expect(viewer.title == "shot.png")
        #expect(!viewer.isLivePage)
        #expect(!viewer.isWebURL)
        #expect(!viewer.isDiffMode)
    }

    /// Dropping an image on the dock (or `open -a Ghoztty shot.png`) opens a
    /// viewer window, the way a markdown file already did. A code file still
    /// opens a terminal — that behavior predates viewers and people rely on it.
    @Test func imagesAndMarkdownOpenAsViewerWindowsFromTheDock() {
        #expect(ViewerView.opensAsViewerWindow(path: "/tmp/shot.png"))
        #expect(ViewerView.opensAsViewerWindow(path: "/tmp/readme.md"))
        #expect(!ViewerView.opensAsViewerWindow(path: "/tmp/main.swift"))
        #expect(!ViewerView.opensAsViewerWindow(path: "/tmp/run.sh"))
    }

    /// Find in an image is meaningless, so Cmd-F is DECLINED (falls through to
    /// its global binding) rather than opening a bar that can only ever say
    /// "no results".
    @Test func findIsDeclinedInAnImagePane() throws {
        let fixtures = try ImageFixtures()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(
            location: try fixtures.png("shot.png", width: 40, height: 40).path)
        viewer.frame = window.contentView!.bounds
        window.contentView!.addSubview(viewer)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        #expect(!viewer.canFind)
        #expect(!viewer.openFind())
        #expect(!viewer.findOpen)
        #expect(!viewer.stepFindFromKeyboard(1))

        // ...and a markdown pane in the same shape still accepts it, so the
        // decline is about the CONTENT and not about being in a test window.
        let doc = ViewerView(location: try fixtures.text("a.md", "# hi").path)
        doc.frame = window.contentView!.bounds
        window.contentView!.addSubview(doc)
        #expect(doc.canFind)
        #expect(doc.openFind())
        doc.closeFind()
    }
}

// MARK: - The mounted surface

/// The native surface in a real pane: it mounts, it fits, and it re-fits when
/// the pane is resized.
@MainActor
struct ViewerImageSurfaceTests {
    private func makeViewer(location: String) -> (NSWindow, ViewerView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(location: location)
        viewer.frame = window.contentView!.bounds
        viewer.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        return (window, viewer)
    }

    private func surface(in viewer: ViewerView) throws -> ViewerImageSurface {
        try #require(viewer.subviews.compactMap { $0 as? ViewerImageSurface }.first)
    }

    /// The surface is mounted over the web view and covers it: the web view
    /// still holds the template (that is what keeps history and the address
    /// working), but nothing of it is visible.
    @Test func theSurfaceIsMountedOverTheWebView() throws {
        let fixtures = try ImageFixtures()
        let (window, viewer) = makeViewer(
            location: try fixtures.png("shot.png", width: 200, height: 100).path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        let surface = try surface(in: viewer)
        #expect(surface.frame == viewer.webView.frame)
        let order = viewer.subviews
        #expect(order.firstIndex(of: surface)! > order.firstIndex(of: viewer.webView)!)
        // A click in the content area lands on the image, not the page behind it.
        let hit = viewer.hitTest(NSPoint(x: viewer.bounds.midX, y: viewer.bounds.midY))
        #expect(hit === surface || hit?.isDescendant(of: surface) == true)
    }

    /// An image opens at best-fit. A 2000x1000 image at 100% would be
    /// 1000x500 points on a 2x screen, which does not fit a pane ~800pt wide
    /// and ~560pt tall once the nav bar takes its row — so it is scaled down.
    @Test func aLargeImageOpensFitted() throws {
        let fixtures = try ImageFixtures()
        let (window, viewer) = makeViewer(
            location: try fixtures.png("big.png", width: 2000, height: 1000).path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        viewer.layoutSubtreeIfNeeded()

        let surface = try surface(in: viewer)
        let scale = window.backingScaleFactor
        let expected = min(
            1,
            min(surface.bounds.width / (2000 / scale),
                surface.bounds.height / (1000 / scale)))
        #expect(abs(surface.currentZoom - expected) < 0.01,
                "opened at \(surface.currentZoom), expected fit \(expected)")
        #expect(surface.currentZoom < 1)
    }

    /// ...and a small one opens at 100%, not blown up to fill the pane.
    @Test func aSmallImageOpensAtActualSize() throws {
        let fixtures = try ImageFixtures()
        let (window, viewer) = makeViewer(
            location: try fixtures.png("tiny.png", width: 32, height: 32).path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        viewer.layoutSubtreeIfNeeded()

        let surface = try surface(in: viewer)
        #expect(abs(surface.currentZoom - 1) < 0.001)
    }

    /// Dragging a split divider re-fits a fitted image — the requirement that
    /// makes an image pane usable in a tree that resizes constantly.
    @Test func resizingThePaneRefitsAFittedImage() throws {
        let fixtures = try ImageFixtures()
        let (window, viewer) = makeViewer(
            location: try fixtures.png("big.png", width: 2000, height: 1000).path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        viewer.layoutSubtreeIfNeeded()

        let surface = try surface(in: viewer)
        let wide = surface.currentZoom

        viewer.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        viewer.layoutSubtreeIfNeeded()
        let narrow = surface.currentZoom
        #expect(narrow < wide, "squeezing the pane should shrink the image to fit")

        viewer.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        viewer.layoutSubtreeIfNeeded()
        #expect(abs(surface.currentZoom - wide) < 0.01, "widening it should fit again")
    }

    /// A zoom the USER chose is not thrown away by a resize. This is the other
    /// half of the rule above, and the reason `isFitting` exists rather than
    /// re-fitting unconditionally.
    @Test func resizingThePaneKeepsAChosenZoom() throws {
        let fixtures = try ImageFixtures()
        let (window, viewer) = makeViewer(
            location: try fixtures.png("big.png", width: 2000, height: 1000).path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        viewer.layoutSubtreeIfNeeded()

        let surface = try surface(in: viewer)
        surface.applyZoomAction(.reset)  // Cmd-0 → 100%
        #expect(abs(surface.currentZoom - 1) < 0.001)

        viewer.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        viewer.layoutSubtreeIfNeeded()
        #expect(abs(surface.currentZoom - 1) < 0.001,
                "a chosen zoom must survive a pane resize")
    }

    /// A file that is not decodable as an image falls through to the template
    /// page's error card — the same card every other file mode uses — rather
    /// than leaving a blank matte.
    @Test func anUndecodableImageFallsBackToTheErrorCard() throws {
        let fixtures = try ImageFixtures()
        let broken = try fixtures.text("broken.png", "this is not a png")
        let (window, viewer) = makeViewer(location: broken.path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        let surface = try surface(in: viewer)
        #expect(surface.url == nil, "nothing should have been decoded")
        // The pane is still an image pane pointed at the file, so a +reload
        // after the file is fixed picks it up.
        #expect(viewer.isImageMode)
        #expect(viewer.fileURL?.path == broken.path)
    }

    /// Detaching (close, with the pane retained by the undo stack) drops the
    /// decoded bitmap; re-attaching brings it back.
    @Test func detachReleasesTheDecodedImage() throws {
        let fixtures = try ImageFixtures()
        let (window, viewer) = makeViewer(
            location: try fixtures.png("big.png", width: 400, height: 400).path)
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        let surface = try surface(in: viewer)
        #expect(surface.url != nil)

        viewer.setDetached(true)
        #expect(surface.url == nil)

        viewer.setDetached(false)
        #expect(surface.url != nil)
    }
}
