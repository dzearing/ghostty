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
//   {t:"ready"}                                   the document exists, seed it
//   {t:"state", text, lines, caret, gen, quotes}  the snapshot, after every edit
//   {t:"focus", on}                               the box gained or lost the caret
//
// Down (`chrome.webview.addEventListener("message")`):
//   {t:"vars", ...}                       the design-system numbers, per layout
//   {t:"seed", text, caret, gen, quotes}  replace the document
//   {t:"focus"}                           put the caret in the box
//
// ## Quotes are NODES, and their identity is an attribute (T935)
//
// A quoted passage is a `<div class="q" data-qid="N">` child of the box. That
// is the whole point of the rebuild: RichEdit had no per-run user field, so
// win32 had to RECOVER a quote's identity by matching its text against
// line-aligned runs, and any edit to the passage silently orphaned its
// metadata. A DOM node carries the id itself, so deleting the block drops the
// metadata with it and editing the block keeps it.
//
// `quotes` in a snapshot is `[{id, start, end}]` over the same string `text`,
// in UTF-16 code units, in document order — the live truth the host serializes
// the report from. `quotes` in a seed is the same shape, and is how the host
// re-attaches ids to a buffer that outlived the page (a closed and reopened
// composer, a native edit): the buffer is plain text, so somebody has to say
// which runs of it are quotes, and that somebody is native exactly once, at
// seed time.
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

  // A quoted block, and where its id lives. Stated once: the stylesheet, the
  // host's assertions and every read below all key on these two.
  var QCLASS = "q";
  var QATTR = "data-qid";

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
        // A block: a quote of ours, or one a paste dropped in. Its content
        // counts; its boundary is a line break, the way any block-level
        // element reads as one.
        if (out.s.length && out.s.charAt(out.s.length - 1) !== "\n") out.s += "\n";
        var id = out.quotes ? quoteId(n) : 0;
        var start = out.s.length;
        walk(n, out);
        // The span is where the block's text ENDED UP in the serialized
        // string, which is the only coordinate system the host and this page
        // both have. Empty blocks never make it here - `normalizeQuotes` has
        // already taken them out.
        if (id > 0 && out.s.length > start) {
          out.quotes.push({ id: id, start: start, end: out.s.length });
        }
      }
    }
  }

  function quoteId(node) {
    if (!node.getAttribute) return 0;
    var raw = node.getAttribute(QATTR);
    if (!raw) return 0;
    var id = parseInt(raw, 10);
    return id > 0 ? id : 0;
  }

  // Keep the quote blocks in a state the host's model can describe, and do it
  // BEFORE every read rather than after an edit that might have been the one
  // that broke them.
  //
  // Two repairs, both of which are the browser's editing behaviour meeting our
  // own invariants rather than hypothetical damage:
  //
  //   * an EMPTIED block is a deleted quote. The node goes, which is what
  //     drops its metadata from the report - the whole reason identity lives
  //     on the node. Never removed while the caret is inside it: the user is
  //     mid-edit and would lose their place.
  //   * a block Chromium SPLIT in two (pressing Enter inside a quote) leaves
  //     two nodes carrying one id. The first keeps it; the second becomes
  //     ordinary text, because a passage the user broke in half is not that
  //     passage any more and the metadata describes the whole of it.
  function normalizeQuotes() {
    var nodes = el.querySelectorAll("." + QCLASS);
    if (!nodes.length) return;
    var sel = window.getSelection();
    var anchor = sel && sel.rangeCount ? sel.getRangeAt(0).endContainer : null;
    var seen = {};
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var id = quoteId(n);
      if (!n.textContent.length) {
        var inside = anchor && (n === anchor || n.contains(anchor));
        if (!inside && n.parentNode) {
          n.parentNode.removeChild(n);
          continue;
        }
      }
      if (id === 0 || seen[id]) {
        n.removeAttribute(QATTR);
        n.classList.remove(QCLASS);
        continue;
      }
      seen[id] = true;
    }
  }

  function readAll() {
    normalizeQuotes();
    var out = { s: "", quotes: [] };
    walk(el, out);
    return out;
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
    var read = readAll();
    var text = read.s;
    el.classList.toggle("empty", text.length === 0);
    var msg = {
      t: "state",
      text: text,
      lines: lineCount(),
      caret: caretOffset(),
      gen: gen,
      quotes: read.quotes,
    };
    // The quotes are part of the key: deleting a block changes what the report
    // carries without necessarily changing the text (the passage can still be
    // there as plain text after a split), and a de-duplicated snapshot is a
    // snapshot the host never sees.
    var key =
      msg.text + " " + msg.lines + " " + msg.caret + "|" + msg.gen + "|" + quoteKey(read.quotes);
    if (!force && key === last) return;
    last = key;
    post(msg);
  }

  function quoteKey(quotes) {
    var s = "";
    for (var i = 0; i < quotes.length; i++) {
      s += quotes[i].id + ":" + quotes[i].start + "-" + quotes[i].end + ",";
    }
    return s;
  }

  // -----------------------------------------------------------------------
  // Writing the document
  // -----------------------------------------------------------------------

  function seed(text, caret, atGen, quotes) {
    gen = typeof atGen === "number" ? atGen : gen;
    build(text, sane(quotes, text.length));
    var at = typeof caret === "number" && caret >= 0 ? Math.min(caret, text.length) : text.length;
    placeCaret(at);
    el.scrollTop = el.scrollHeight;
    report(true);
  }

  // The spans the host may act on: positive ids, inside the text, non-empty,
  // in ascending order and never overlapping. A payload that breaks any of
  // those describes a document that cannot be built, so the offending span is
  // dropped rather than the seed - the report text arriving without one of its
  // washes is survivable; the text not arriving is not.
  function sane(quotes, len) {
    var out = [];
    if (!quotes || !quotes.length) return out;
    var at = 0;
    for (var i = 0; i < quotes.length; i++) {
      var q = quotes[i];
      if (!q || !(q.id > 0)) continue;
      var start = q.start | 0;
      var end = q.end | 0;
      if (start < at || end <= start || end > len) continue;
      out.push({ id: q.id, start: start, end: end });
      at = end;
    }
    return out;
  }

  // Lay the document out as text nodes with a quote block wherever the host
  // named one. The serialization above reproduces `text` exactly as long as
  // each block starts a line, which is the invariant native's own insertion
  // guarantees (a quote is inserted as its own block, with air either side).
  function build(text, quotes) {
    el.textContent = "";
    var at = 0;
    for (var i = 0; i < quotes.length; i++) {
      var q = quotes[i];
      if (q.start > at) el.appendChild(document.createTextNode(text.slice(at, q.start)));
      var block = document.createElement("div");
      block.className = QCLASS;
      block.setAttribute(QATTR, String(q.id));
      block.appendChild(document.createTextNode(text.slice(q.start, q.end)));
      el.appendChild(block);
      at = q.end;
    }
    if (at < text.length) el.appendChild(document.createTextNode(text.slice(at)));
  }

  // Put the caret `at` code units into the serialized text. The walk is the
  // read path's, minus the string: the same order, so an offset that came out
  // of a snapshot goes back to the character it named.
  function placeCaret(at) {
    var pos = 0;
    var node = null;
    var off = 0;
    (function visit(parent) {
      for (var n = parent.firstChild; n && !node; n = n.nextSibling) {
        if (n.nodeType === 3) {
          if (at <= pos + n.data.length) {
            node = n;
            off = at - pos;
            return;
          }
          pos += n.data.length;
        } else if (n.nodeType === 1) {
          visit(n);
        }
      }
    })(el);

    var sel = window.getSelection();
    var r = document.createRange();
    if (node) r.setStart(node, Math.min(off, node.data.length));
    else r.setStart(el, el.childNodes.length);
    r.collapse(true);
    if (sel) {
      sel.removeAllRanges();
      sel.addRange(r);
    }
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
    // The quote block's own numbers, derived natively from the SAME pill
    // colour and accent the band paints with - one derivation, two renderers.
    if (v.qbg) root.setProperty("--q-bg", v.qbg);
    if (v.qaccent) root.setProperty("--q-accent", v.qaccent);
    if (v.qindent) root.setProperty("--q-indent", v.qindent + "px");
    if (v.qbar) root.setProperty("--q-bar", v.qbar + "px");
    if (v.qbarx) root.setProperty("--q-bar-x", v.qbarx + "px");
    if (typeof v.text === "string") el.setAttribute("data-placeholder", v.text);
    // A scale change moves the line box, so the count the host is laying out
    // from is stale until this is re-measured.
    report(true);
  }

  if (host) {
    host.addEventListener("message", function (e) {
      var m = e.data;
      if (!m || typeof m !== "object") return;
      if (m.t === "seed") seed(typeof m.text === "string" ? m.text : "", m.caret, m.gen, m.quotes);
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
