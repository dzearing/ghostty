// The feedback composer's page half (T934).
//
// ## The ownership flip this file IS
//
// The RichEdit this replaces answered `caret()`, `lineCount()` and a text read
// on the same stack the caller was on. A WebView2 cannot: everything crosses
// the process boundary asynchronously. So the direction of truth is inverted -
// the PAGE owns the live document and PUSHES a snapshot up on every change,
// and native keeps the last snapshot as the thing it lays out and serializes
// from. Nothing here ever answers a question; it only reports.
//
// Up (`chrome.webview.postMessage`):
//   {t:"ready"}                           the document exists, seed it
//   {t:"state", text, lines, caret, gen}  the snapshot, after every edit
//   {t:"focus", on}                       the box gained or lost the caret
//
// Down (`chrome.webview.addEventListener("message")`):
//   {t:"vars", ...}                       the design-system numbers, per layout
//   {t:"seed", text, caret, gen}          replace the document
//   {t:"focus"}                           put the caret in the box
//
// `gen` is the seed's generation, echoed in every snapshot that follows it. It
// is what lets the host tell "the user typed this" from "this was measured
// before the seed that replaced it" - the two are indistinguishable by content
// and only one of them may be written back over the buffer.
//
// `caret` is in UTF-16 CODE UNITS, which is what a JS string offset is. Native
// converts it against the same buffer with `utf16_offset.zig`, because the
// pane's buffer is UTF-8 and the two agree only for ASCII (the T648 boundary,
// unchanged by this rebuild).
(function () {
  "use strict";

  var el = document.getElementById("c");
  var host = window.chrome && window.chrome.webview;
  // The generation of the last seed applied. Zero until the host seeds, which
  // is what a snapshot from a page nobody has filled yet reports.
  var gen = 0;

  function post(msg) {
    if (host) host.postMessage(msg);
  }

  // -----------------------------------------------------------------------
  // Reading the document
  //
  // The box is edited as `plaintext-only`, so Chromium keeps its content as
  // text nodes with real "\n" in them - which `white-space: pre-wrap` renders
  // as line breaks. It still emits a <br> in two cases: as the placeholder that
  // gives the caret somewhere to sit on a trailing empty line, and (on some
  // paste paths) as the break itself. Walking handles both, and the ONE rule
  // that separates them is positional: a <br> that is the last node when the
  // text already ends in a newline is the placeholder, not content.
  // -----------------------------------------------------------------------

  function walk(node, out) {
    for (var n = node.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3) {
        out.s += n.data;
      } else if (n.nodeName === "BR") {
        var last = !n.nextSibling && node === el;
        if (last && out.s.charAt(out.s.length - 1) === "\n") continue;
        out.s += "\n";
      } else if (n.nodeType === 1) {
        // A block a paste dropped in. Its content counts; its boundary is a
        // line break, the way any block-level element reads as one.
        if (out.s.length && out.s.charAt(out.s.length - 1) !== "\n") out.s += "\n";
        walk(n, out);
      }
    }
  }

  function readText() {
    var out = { s: "" };
    walk(el, out);
    return out.s;
  }

  // The caret as an offset into `readText()`'s string: the same walk, stopped
  // at the selection's own node and offset.
  function caretOffset() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return -1;
    var r = sel.getRangeAt(0);
    if (!el.contains(r.endContainer) && r.endContainer !== el) return -1;
    var pre = document.createRange();
    pre.selectNodeContents(el);
    try {
      pre.setEnd(r.endContainer, r.endOffset);
    } catch (e) {
      return -1;
    }
    var frag = pre.cloneContents();
    var holder = document.createElement("div");
    holder.appendChild(frag);
    var out = { s: "" };
    // The clone's own trailing <br> is content here, not a placeholder: the
    // placeholder rule keys on `node === el`, which a clone never is.
    walk(holder, out);
    return out.s.length;
  }

  // How many WRAPPED lines the content occupies - the number that decides how
  // tall the pill is, and the reason this is measured rather than counted:
  // one long paragraph with no newline in it can be six lines on screen.
  function lineCount() {
    var lh = parseFloat(getComputedStyle(el).lineHeight);
    if (!(lh > 0)) return 1;
    // scrollHeight is the CONTENT height, so it keeps answering past the point
    // where the box itself stops growing - which is exactly what the caller
    // needs, because native clamps to the layout's own cap.
    var n = Math.round(el.scrollHeight / lh);
    return n > 0 ? n : 1;
  }

  var last = null;

  function report(force) {
    var text = readText();
    el.classList.toggle("empty", text.length === 0);
    var msg = { t: "state", text: text, lines: lineCount(), caret: caretOffset(), gen: gen };
    var key = msg.text + " " + msg.lines + " " + msg.caret + "|" + msg.gen;
    if (!force && key === last) return;
    last = key;
    post(msg);
  }

  // -----------------------------------------------------------------------
  // Writing the document
  // -----------------------------------------------------------------------

  function seed(text, caret, atGen) {
    gen = typeof atGen === "number" ? atGen : gen;
    // One text node, always: the flat model the read path above assumes.
    el.textContent = text;
    var at = typeof caret === "number" && caret >= 0 ? Math.min(caret, text.length) : text.length;
    var node = el.firstChild;
    var sel = window.getSelection();
    var r = document.createRange();
    if (node) {
      r.setStart(node, Math.min(at, node.length));
    } else {
      r.setStart(el, 0);
    }
    r.collapse(true);
    if (sel) {
      sel.removeAllRanges();
      sel.addRange(r);
    }
    el.scrollTop = el.scrollHeight;
    report(true);
  }

  function applyVars(v) {
    var root = document.documentElement.style;
    if (v.face) root.setProperty("--face", v.face);
    if (v.fontPx) root.setProperty("--font-px", v.fontPx + "px");
    if (v.linePx) root.setProperty("--line-px", v.linePx + "px");
    if (v.fg) root.setProperty("--fg", v.fg);
    if (v.bg) root.setProperty("--bg", v.bg);
    if (v.placeholder) root.setProperty("--placeholder", v.placeholder);
    if (v.sel) root.setProperty("--sel", v.sel);
    if (typeof v.text === "string") el.setAttribute("data-placeholder", v.text);
    // A scale change moves the line box, so the count the host is laying out
    // from is stale until this is re-measured.
    report(true);
  }

  if (host) {
    host.addEventListener("message", function (e) {
      var m = e.data;
      if (!m || typeof m !== "object") return;
      if (m.t === "seed") seed(typeof m.text === "string" ? m.text : "", m.caret, m.gen);
      else if (m.t === "vars") applyVars(m);
      else if (m.t === "focus") el.focus();
    });
  }

  el.addEventListener("input", function () {
    report(false);
  });
  // A narrower pane re-wraps the text, which moves the line count without any
  // edit at all - the composer that ends up two lines tall around three lines
  // of text after a split divider is dragged. `report` de-duplicates, so the
  // resize the host performs IN RESPONSE to a new count does not bounce back.
  if (window.ResizeObserver) {
    new ResizeObserver(function () {
      report(false);
    }).observe(el);
  }
  document.addEventListener("selectionchange", function () {
    report(false);
  });
  el.addEventListener("focus", function () {
    post({ t: "focus", on: true });
  });
  el.addEventListener("blur", function () {
    post({ t: "focus", on: false });
  });

  // Dropping a file into the composer is T936's business; until then a drop
  // that navigated this view away would take the whole composer with it.
  el.addEventListener("dragover", function (e) {
    e.preventDefault();
  });
  el.addEventListener("drop", function (e) {
    e.preventDefault();
  });

  el.classList.add("empty");
  post({ t: "ready" });
})();
