/* Ghoztty viewer — image panes (T1183).
 *
 * The Windows translation of Mac's `ViewerImageView.swift`. Mac draws the
 * picture on a native `NSScrollView` because AppKit hands it centroid-anchored
 * pinch, elastic edges and momentum for free; win32 has no such scroller to
 * inherit, while a Chromium scroll container brings precision-touchpad panning,
 * inertia and overlay scrollbars with it. So on this side the picture lives in
 * the same bundled template every other file mode renders in — which is also
 * what keeps the nav bar, history, the address, Home, `+list`'s url, session
 * restore and the standard error card working with no new machinery.
 *
 * What this file is NOT allowed to decide is the zoom. Every rule anyone can
 * argue about — what 100% means, that best-fit never upscales, where a
 * double-click lands, the step and the clamp — lives in
 * `src/apprt/win32/viewer_image.zig`, asserted without a browser. This side
 * measures, forwards gestures, and applies the scale that comes back. The one
 * thing it owns is the anchor arithmetic: keeping the point under the pointer
 * under the pointer is a scroll adjustment, not a policy.
 *
 * Everything here is offline: one <img> against a `https://ghoztty-viewer/`
 * URL the pane serves off disk. No network, no fetch, no external stylesheet.
 *
 * Mac never calls any of this — it has its own native surface — so nothing in
 * the shared page may depend on it having run. */
"use strict";

window.__viewerImage = (function () {
  /* Pixels of wheel travel that make one zoom step. A precision touchpad
   * pinch arrives as ctrl+wheel in small increments, and answering every one
   * of them with a 1.25x step would cross the whole zoom range in a flick. */
  const WHEEL_STEP_THRESHOLD = 40;

  function init(options) {
    const root = options.root;
    const post = options.post;

    /* The scroll container and the picture inside it. Built once and reused:
     * a live reload re-points the <img>, it does not rebuild the pane. */
    let stage = null;
    let img = null;

    /* The last scale the native side sent, and the anchor a gesture asked to
     * keep still. `pending` is the anchor for the NEXT transform, in the
     * image's own units, so a zoom that arrives a frame later still lands on
     * the pixel the user pointed at. */
    let scale = 1;
    let pending = null;
    let wheelTravel = 0;

    function build() {
      root.className = "viewer-image-mode";
      root.textContent = "";
      stage = document.createElement("div");
      stage.className = "viewer-image-stage";
      img = document.createElement("img");
      img.className = "viewer-image";
      /* Dragging the <img> to a file manager instead of panning the pane is
       * the browser's default and is never what was meant here. */
      img.draggable = false;
      img.addEventListener("load", onLoad);
      img.addEventListener("error", onError);
      stage.appendChild(img);
      root.appendChild(stage);

      stage.addEventListener("wheel", onWheel, { passive: false });
      stage.addEventListener("dblclick", onDoubleClick);
      window.addEventListener("resize", onResize);
    }

    /* ------------------------------------------------------------------
     * Measuring
     * ------------------------------------------------------------------ */

    function viewport() {
      if (!stage) return { vw: 0, vh: 0 };
      return { vw: stage.clientWidth, vh: stage.clientHeight };
    }

    function dpr() {
      const v = window.devicePixelRatio;
      return v > 0 ? v : 1;
    }

    /* Report a gesture or a measurement. The page always sends everything it
     * currently knows, so a dropped message costs a frame rather than leaving
     * the two sides disagreeing about the picture. */
    function report(event) {
      const v = viewport();
      post({
        type: "image",
        event: event,
        w: naturalWidth(),
        h: naturalHeight(),
        vw: v.vw,
        vh: v.vh,
        dpr: dpr(),
        vector: isVector(),
      });
    }

    /* Vector art has no pixel grid, so 100% means the drawing's own size
     * rather than one image pixel per device pixel.
     *
     * Told to us rather than sniffed: the picture is served from a sentinel
     * url with no extension on it, so the file's name — the only thing that
     * says which kind of art this is — never reaches the browser at all. */
    let vector = false;

    function isVector() {
      return vector;
    }

    /* The picture's own size, measured ONCE when it decodes and remembered.
     * It cannot be re-read later: this file sizes the <img> box itself, so a
     * fallback measurement taken after the first zoom would measure the zoom. */
    let natW = 0;
    let natH = 0;

    function measureNatural() {
      if (!img) {
        natW = 0;
        natH = 0;
        return;
      }
      const box = img.getBoundingClientRect();
      natW = img.naturalWidth || box.width || 0;
      natH = img.naturalHeight || box.height || 0;
    }

    function naturalWidth() {
      return natW;
    }

    function naturalHeight() {
      return natH;
    }

    /* ------------------------------------------------------------------
     * Applying what the native side decided
     * ------------------------------------------------------------------ */

    /* `next` is the CSS scale for the <img>'s natural box; `fit` says the
     * picture is at best-fit, which is the cue to recenter rather than hold an
     * anchor — a fresh fit belongs in the middle of the pane, not wherever the
     * last gesture left the scroll. */
    function setTransform(next, fit) {
      if (!img || !stage) return;
      const previous = scale;
      scale = next > 0 ? next : 1;
      const anchor = pending;
      pending = null;

      /* Held back until the first transform arrives (see `setImage`): a
       * 4000px screenshot laid out at its intrinsic size for one frame before
       * the fit lands is a visible lurch. */
      img.style.visibility = "visible";
      img.style.width = naturalWidth() * scale + "px";
      img.style.height = naturalHeight() * scale + "px";
      /* Hard pixels from 2x up: the only reason to magnify a screenshot that
       * far is to look at individual pixels, and a bilinear smear of them
       * answers no question anyone had. Below that, smooth. */
      img.style.imageRendering = scale * dpr() >= 2 && !isVector() ? "pixelated" : "auto";

      if (fit || !anchor || previous <= 0) {
        centerScroll();
        return;
      }
      /* Keep the pointed-at point under the pointer: its offset in the
       * document scales with the picture, so the scroll has to make up the
       * difference. */
      const ratio = scale / previous;
      stage.scrollLeft = (stage.scrollLeft + anchor.x) * ratio - anchor.x;
      stage.scrollTop = (stage.scrollTop + anchor.y) * ratio - anchor.y;
    }

    /* A picture smaller than the pane is centered by the stage's own flexbox;
     * one larger than it opens at its top-left, the way a document does. */
    function centerScroll() {
      if (!stage) return;
      stage.scrollLeft = 0;
      stage.scrollTop = 0;
    }

    /* Where a gesture landed, relative to the stage's own top-left. That is
     * the frame the scroll adjustment above works in. */
    function anchorFrom(event) {
      if (!stage) return null;
      const box = stage.getBoundingClientRect();
      return { x: event.clientX - box.left, y: event.clientY - box.top };
    }

    /* ------------------------------------------------------------------
     * Gestures
     * ------------------------------------------------------------------ */

    function onWheel(event) {
      /* Plain wheel is panning, which the scroll container already does. Only
       * a zooming wheel is ours — and it must be taken from Chromium, whose
       * own ctrl+wheel is PAGE zoom and knows nothing about this picture. */
      if (!event.ctrlKey) return;
      event.preventDefault();
      wheelTravel += event.deltaY;
      if (Math.abs(wheelTravel) < WHEEL_STEP_THRESHOLD) return;
      const up = wheelTravel < 0;
      wheelTravel = 0;
      pending = anchorFrom(event);
      report(up ? "zoom_in" : "zoom_out");
    }

    function onDoubleClick(event) {
      event.preventDefault();
      pending = anchorFrom(event);
      report("toggle");
    }

    function onResize() {
      report("viewport");
    }

    function onLoad() {
      measureNatural();
      report("loaded");
    }

    function onError() {
      report("failed");
    }

    /* ------------------------------------------------------------------
     * Entry points the native side calls
     * ------------------------------------------------------------------ */

    /* Show `url`, whose bytes the pane serves off disk. `name` titles the
     * document and is the alt text a screen reader gets. */
    function setImage(url, name, isVectorArt) {
      if (!stage) build();
      root.className = "viewer-image-mode";
      vector = !!isVectorArt;
      scale = 1;
      pending = null;
      wheelTravel = 0;
      natW = 0;
      natH = 0;
      img.alt = name || "";
      img.title = name || "";
      /* Cleared first so a re-point at the SAME url (a live reload carries a
       * new revision, but a re-render may not) still fires `load`. */
      img.removeAttribute("src");
      img.style.width = "";
      img.style.height = "";
      /* Nothing is shown until the native side has answered with a scale: the
       * intrinsic size is not the size this pane means, and one frame of it is
       * a visible lurch on anything bigger than the pane. */
      img.style.visibility = "hidden";
      img.src = url;
      /* A cached image can be complete before the listener above ever runs. */
      if (img.complete && img.naturalWidth > 0) onLoad();
    }

    /* A keyboard zoom chord the native side saw first (ctrl +/-/0). Routed
     * back through the same report so there is exactly one path from a gesture
     * to a scale. */
    function zoom(action) {
      pending = null;
      report(action);
    }

    /* Leaving image mode: drop the bitmap so a pane showing a document is not
     * still holding a decoded picture. */
    function clear() {
      if (img) img.removeAttribute("src");
      stage = null;
      img = null;
      window.removeEventListener("resize", onResize);
    }

    return {
      setImage: setImage,
      setImageTransform: setTransform,
      zoom: zoom,
      clear: clear,
    };
  }

  return { init: init };
})();
