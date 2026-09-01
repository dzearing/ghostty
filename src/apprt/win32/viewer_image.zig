//! The zoom rules for an image viewer pane (T1183; Mac's
//! `ViewerImageGeometry` in `ViewerImageView.swift`, same arithmetic).
//!
//! Everything a person can argue about — what "100%" means, whether best-fit
//! may enlarge a small image, where a double-click lands — lives here as
//! arithmetic with no window, no COM and no page in it, so it asserts in the
//! `-Dapp-runtime=none` lane. `ViewerPane` is plumbing on one side of it and
//! `src/viewer/image.js` is plumbing on the other.
//!
//! ## Why the arithmetic is on THIS side of the bridge
//!
//! The picture is drawn by the bundled template rather than by a native
//! surface (the mechanism note in T1183): win32 has no elastic, momentum-y
//! scroll view to inherit the way AppKit does, while a WebView2 scroll
//! container brings precision-touchpad panning, inertia and overlay scrollbars
//! with it. What the page does NOT get to decide is the zoom, because those
//! rules are the feature — so the page reports its viewport, the image's
//! natural size and the gestures, and every zoom it applies came from here.
//! Same split as `viewer_diff.zig` against `ViewerDiffProbe.zig`.
//!
//! Page zoom (`viewer_accel.zig`'s `steppedZoom`) is a different quantity and
//! stays where it is: that scales a DOCUMENT, this scales a picture, and their
//! limits and steps disagree on purpose.
const std = @import("std");
const testing = std.testing;

/// Extensions that open as a picture rather than as highlighted source (Mac's
/// `ViewerView.imageExtensions`, same list).
///
/// A fixed list rather than "whatever this machine's codecs can decode", for
/// the same reason the markdown list is fixed: what a `--view=` path does
/// should be predictable from the path, not from which decoders a given
/// Windows build happens to ship.
///
/// `svg` is here even though it is text — it is a picture, and reading its
/// source is what an editor is for.
pub const extensions = [_][]const u8{
    "png",  "apng", "jpg",  "jpeg", "jpe",  "jfif",
    "gif",  "webp", "avif", "heic", "heif", "tif",
    "tiff", "bmp",  "ico",  "icns", "svg",
};

/// Whether `ext` (no dot, any case) names a picture.
pub fn isImage(ext: []const u8) bool {
    if (ext.len == 0) return false;
    for (extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// Vector art has no pixel grid, so 100% cannot mean "one image pixel per
/// device pixel" for it — it means the drawing's intrinsic size, as in every
/// other vector viewer.
pub const Kind = enum { raster, vector };

/// A ctrl+plus / ctrl+minus / ctrl+0 request, and the two ends of a
/// ctrl+wheel notch. Distinct from `viewer_accel.ZoomAction` because reset
/// means something different here: 100%, not "the default document zoom".
pub const Action = enum { zoom_in, zoom_out, reset };

/// Hard zoom limits. Deliberately wide at the top — an image pane is where you
/// go to count pixels — and loose at the bottom, since `minZoom` also has to
/// admit whatever best-fit needs for a very large image.
pub const zoom_floor: f64 = 0.05;
pub const zoom_ceiling: f64 = 32;

/// Per-press step. Coarser than the page viewer's 1.1 because an image's
/// useful zoom range spans two orders of magnitude where a document's spans
/// one.
pub const zoom_step: f64 = 1.25;

/// How close two zooms have to be to count as the same one. The page reports
/// CSS pixels through a JSON round trip, so an exact compare would make "am I
/// still fitting?" answer no after a resize that changed nothing.
pub const epsilon: f64 = 0.0001;

/// The inputs every rule below is a function of. All lengths are CSS pixels;
/// `natural` is in the image's own units (pixels for raster art, points for
/// vector art), which is also the size the page lays the `<img>` out at before
/// any transform.
pub const Geometry = struct {
    natural_w: f64 = 0,
    natural_h: f64 = 0,
    viewport_w: f64 = 0,
    viewport_h: f64 = 0,
    /// Device pixels per CSS pixel, as the page reports `devicePixelRatio`.
    dpr: f64 = 1,
    kind: Kind = .raster,

    /// CSS pixels per natural unit at 100% zoom — the whole of the "what does
    /// 100% mean" decision, in one number.
    ///
    /// **For a raster image, 100% is one image pixel per DEVICE pixel**, so
    /// this is `1 / dpr`. Two reasons, in order:
    ///
    /// 1. It is the only definition under which 100% is actually pixel-exact.
    ///    Every image pixel lands on exactly one screen pixel, nothing is
    ///    resampled, and a 1px hairline is a 1px hairline — which is the whole
    ///    reason anyone asks for 100% rather than "big enough to read".
    /// 2. Most of what gets opened in these panes is screen capture — the
    ///    feedback composer's own screenshots, an agent's render of a UI.
    ///    Those are captured at device resolution, so 100% shows them at
    ///    exactly the size they were on screen. One image pixel per CSS pixel
    ///    would show a 2x screenshot at twice the size of the screen it came
    ///    from.
    ///
    /// **For vector art it is 1.0**: there are no pixels to be 1:1 with.
    pub fn unitScale(self: Geometry) f64 {
        if (self.kind == .vector) return 1;
        return 1 / @max(self.dpr, 1);
    }

    /// Zoom that fits the whole image in the viewport, **never above 100%**.
    ///
    /// Refusing to upscale is the deliberate half: blowing a 16px icon up to
    /// fill a 900px pane makes a blurry lie out of the asset, and "fit" on an
    /// image that already fits is a no-op everywhere else on the platform. So
    /// a small image opens crisp, centered, at its real size.
    ///
    /// A degenerate input (no image yet, a pane with no width) answers 1
    /// rather than 0 or infinity: the page renders at 100% until it can
    /// measure, which is a picture rather than a blank matte.
    pub fn fitZoom(self: Geometry) f64 {
        const unit = self.unitScale();
        if (self.natural_w <= 0 or self.natural_h <= 0) return 1;
        if (self.viewport_w <= 0 or self.viewport_h <= 0) return 1;
        if (unit <= 0) return 1;
        const raw = @min(
            self.viewport_w / (self.natural_w * unit),
            self.viewport_h / (self.natural_h * unit),
        );
        return @min(1, raw);
    }

    /// The lowest zoom the pane allows. Never above `fitZoom`, or a very large
    /// image could not be fit into a small pane at all.
    pub fn minZoom(self: Geometry) f64 {
        return @min(zoom_floor, self.fitZoom());
    }

    pub fn maxZoom(self: Geometry) f64 {
        return @max(zoom_ceiling, self.fitZoom());
    }

    pub fn clamp(self: Geometry, zoom: f64) f64 {
        return @min(self.maxZoom(), @max(self.minZoom(), zoom));
    }

    /// The CSS transform scale for a zoom, given an `<img>` laid out at the
    /// image's natural size. Mac's `magnification(forZoom:)` — the same
    /// product, because an `NSScrollView` document view at `naturalSize` and a
    /// CSS box at `naturalSize` are the same coordinate space.
    pub fn cssScale(self: Geometry, zoom: f64) f64 {
        return self.clamp(zoom) * self.unitScale();
    }

    /// Whether `zoom` IS best-fit, which is what makes a pane resize re-fit.
    /// Any deliberate zoom clears it: once the user has chosen a
    /// magnification, dragging a split divider must not throw it away.
    pub fn isFit(self: Geometry, zoom: f64) bool {
        return @abs(zoom - self.fitZoom()) < epsilon;
    }

    /// Where a double-click / two-finger double-tap goes from `current`.
    ///
    /// The contract is "toggle between best-fit and 100%", with one honest
    /// exception: when the image is smaller than the pane those two are the
    /// SAME zoom, and a gesture that visibly does nothing reads as a broken
    /// gesture. In that case the first double-click goes to 200% instead, and
    /// the next one comes back to fit — so the toggle always toggles.
    pub fn doubleClickZoom(self: Geometry, current: f64) f64 {
        const fit = self.fitZoom();
        if (@abs(current - fit) >= epsilon) return fit;
        return self.clamp(if (fit >= 1) 2 else 1);
    }

    /// Ctrl+ / Ctrl− / Ctrl-0. Reset is 100% ("Actual Size"), not fit: it
    /// means the same thing here as it does in the other viewer modes, and fit
    /// is one double-click away.
    pub fn stepped(self: Geometry, current: f64, action: Action) f64 {
        return switch (action) {
            .zoom_in => self.clamp(current * zoom_step),
            .zoom_out => self.clamp(current / zoom_step),
            .reset => self.clamp(1),
        };
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "isImage carries the Mac extension table, case-insensitively" {
    try testing.expect(isImage("png"));
    try testing.expect(isImage("PNG"));
    try testing.expect(isImage("Jpeg"));
    try testing.expect(isImage("webp"));
    try testing.expect(isImage("avif"));
    try testing.expect(isImage("icns"));
    // A picture even though it is text: reading SVG source is an editor's job.
    try testing.expect(isImage("svg"));

    try testing.expect(!isImage(""));
    try testing.expect(!isImage("md"));
    try testing.expect(!isImage("zig"));
    try testing.expect(!isImage("html"));
    // Not a prefix match: `.pn` and `.pngx` are not pictures.
    try testing.expect(!isImage("pn"));
    try testing.expect(!isImage("pngx"));
}

test "unitScale: 100% is one image pixel per device pixel, and 1.0 for vectors" {
    try testing.expectApproxEqAbs(
        @as(f64, 0.5),
        (Geometry{ .dpr = 2 }).unitScale(),
        1e-9,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 1),
        (Geometry{ .dpr = 1 }).unitScale(),
        1e-9,
    );
    // A vector has no pixel grid to be 1:1 with, at any scale factor.
    try testing.expectApproxEqAbs(
        @as(f64, 1),
        (Geometry{ .dpr = 2, .kind = .vector }).unitScale(),
        1e-9,
    );
    // A nonsense ratio cannot make 100% larger than life.
    try testing.expectApproxEqAbs(
        @as(f64, 1),
        (Geometry{ .dpr = 0 }).unitScale(),
        1e-9,
    );
}

test "fitZoom shrinks a large image and never enlarges a small one" {
    // 4000x3000 image, 800x600 pane, 1x: fit is 0.2 on both axes.
    const big: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expectApproxEqAbs(@as(f64, 0.2), big.fitZoom(), 1e-9);

    // The CONSTRAINING axis wins: a wide image in a tall pane fits by width.
    const wide: Geometry = .{
        .natural_w = 4000,
        .natural_h = 1000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expectApproxEqAbs(@as(f64, 0.2), wide.fitZoom(), 1e-9);

    // A 16px icon in a 900px pane stays 16px. This is the whole "best-fit
    // never upscales" rule: fit would be 56x, and a 56x icon is a blurry lie.
    const icon: Geometry = .{
        .natural_w = 16,
        .natural_h = 16,
        .viewport_w = 900,
        .viewport_h = 900,
    };
    try testing.expectApproxEqAbs(@as(f64, 1), icon.fitZoom(), 1e-9);

    // On a 2x display the same 4000px image is drawn at half the CSS size, so
    // twice as much of it fits: fit is 0.4, not 0.2.
    const retina: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
        .dpr = 2,
    };
    try testing.expectApproxEqAbs(@as(f64, 0.4), retina.fitZoom(), 1e-9);

    // Degenerate inputs answer 100% rather than 0 or infinity: a pane that has
    // not measured itself yet shows a picture, not a blank matte.
    try testing.expectApproxEqAbs(@as(f64, 1), (Geometry{}).fitZoom(), 1e-9);
    try testing.expectApproxEqAbs(
        @as(f64, 1),
        (Geometry{ .natural_w = 10, .natural_h = 10 }).fitZoom(),
        1e-9,
    );
}

test "the zoom limits always admit fit, however large the image" {
    // 20000px wide in a 400px pane: fit is 0.02, BELOW the floor, and the
    // floor has to give way or the image could not be fitted at all.
    const huge: Geometry = .{
        .natural_w = 20000,
        .natural_h = 20000,
        .viewport_w = 400,
        .viewport_h = 400,
    };
    try testing.expectApproxEqAbs(@as(f64, 0.02), huge.fitZoom(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.02), huge.minZoom(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.02), huge.clamp(0.001), 1e-9);
    try testing.expectApproxEqAbs(zoom_ceiling, huge.clamp(1000), 1e-9);

    // The ordinary case keeps the ordinary floor.
    const normal: Geometry = .{
        .natural_w = 100,
        .natural_h = 100,
        .viewport_w = 400,
        .viewport_h = 400,
    };
    try testing.expectApproxEqAbs(zoom_floor, normal.minZoom(), 1e-9);
    try testing.expectApproxEqAbs(zoom_floor, normal.clamp(0.001), 1e-9);
}

test "cssScale turns a zoom into the transform the page applies" {
    const g: Geometry = .{
        .natural_w = 800,
        .natural_h = 600,
        .viewport_w = 400,
        .viewport_h = 400,
        .dpr = 2,
    };
    // 100% on a 2x display draws the 800px image across 400 CSS pixels — one
    // image pixel per device pixel, which is the whole definition.
    try testing.expectApproxEqAbs(@as(f64, 0.5), g.cssScale(1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), g.cssScale(2), 1e-9);
    // Out-of-range zooms are clamped on the way through, so the page cannot be
    // handed a transform the rules do not allow.
    try testing.expectApproxEqAbs(g.cssScale(zoom_ceiling), g.cssScale(1e6), 1e-9);
}

test "double-click toggles fit and 100%, and still toggles when they coincide" {
    // A big image: fit (0.2) and 100% are different, so it is a plain toggle.
    const big: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expectApproxEqAbs(@as(f64, 1), big.doubleClickZoom(0.2), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2), big.doubleClickZoom(1), 1e-9);
    // From anywhere else, the first click goes to fit.
    try testing.expectApproxEqAbs(@as(f64, 0.2), big.doubleClickZoom(3.7), 1e-9);

    // A small image: fit IS 100%, so the first click has to go somewhere
    // visible or the gesture reads as broken. 200%, then back to fit.
    const icon: Geometry = .{
        .natural_w = 16,
        .natural_h = 16,
        .viewport_w = 900,
        .viewport_h = 900,
    };
    try testing.expectApproxEqAbs(@as(f64, 1), icon.fitZoom(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2), icon.doubleClickZoom(1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), icon.doubleClickZoom(2), 1e-9);
}

test "stepped: 1.25 per press, clamped, and reset means 100%" {
    const g: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expectApproxEqAbs(@as(f64, 1.25), g.stepped(1, .zoom_in), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.8), g.stepped(1, .zoom_out), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), g.stepped(0.2, .reset), 1e-9);
    // Reset is 100%, NOT fit — fit is one double-click away.
    try testing.expect(!g.isFit(g.stepped(0.2, .reset)));
    // The ceiling and the floor hold.
    try testing.expectApproxEqAbs(zoom_ceiling, g.stepped(zoom_ceiling, .zoom_in), 1e-9);
    try testing.expectApproxEqAbs(g.minZoom(), g.stepped(g.minZoom(), .zoom_out), 1e-9);
}

test "isFit tolerates the JSON round trip the page reports through" {
    const g: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expect(g.isFit(0.2));
    try testing.expect(g.isFit(0.2 + epsilon / 2));
    try testing.expect(!g.isFit(0.2 + epsilon * 10));
    try testing.expect(!g.isFit(1));
}
