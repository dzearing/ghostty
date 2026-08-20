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
//   {t:"image", png}                              a picture was pasted or dropped
//   {t:"image", err, bytes}                       ...and could not be taken
//
// Down (`chrome.webview.addEventListener("message")`):
//   {t:"vars", ...}                               the design numbers, per layout
//   {t:"seed", text, caret, gen, quotes, images, undo}  replace the document
//   {t:"focus"}                                   put the caret in the box
//   {t:"pick", n}                                 select image chip n, whole
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
//
// ## Image chips are NODES too, but for a different reason (T936)
//
// A chip is a `<span class="i" data-img="N" contenteditable="false">` whose
// text is literally `[Image #N]`. Unlike a quote it needs no identity from the
// node — that text says which picture it is, which is why the host goes on
// deriving the live set from the buffer and nothing about the report, the
// carousel or `Store.live` changed. What the node buys is ATOMICITY: an inline
// non-editable element is one character to the engine, so Backspace beside it
// removes the chip whole instead of eating the `]` and leaving text that no
// longer parses — the thing `chipEndingAt` had to hand-carry, now the
// browser's.
//
// The serialization is therefore load-bearing: a chip contributes exactly its
// own text and no line break, so a document with chips in it reads back
// byte-for-byte as the buffer that seeded it.
//
// ## Ctrl+Z takes a quote or a chip back out (T983)
//
// A quote and a chip arrive as a SEED, because native cannot say "insert this
// here" — and a seed rebuilds the document, which the engine's undo stack has
// no entry for. (Nor can the page make one: in a `plaintext-only` box
// `execCommand("insertHTML")` flattens a block or a chip to its own text, so
// there is no engine command that inserts the NODES this composer is built
// from.) So a seed that stands for one user-visible edit carries `undo:true`,
// and the page keeps what it replaced on a journal of its own.
//
// Ctrl+Z then asks the engine FIRST and falls back to that journal: typing
// since the quote landed unwinds keystroke by keystroke the way it does
// everywhere else, and only once the engine has nothing left does the quote
// itself come out. The order is right for free because a rebuild leaves the
// engine's older steps unapplicable, and Chromium answers those with a no-op
// rather than with damage — which is the same fact this fallback detects: an
// undo that changed nothing is an undo the engine did not have.
//
// Ctrl+Y (and Ctrl+Shift+Z) is the same machine run backwards.
//
// ## Pictures arrive through the engine's own events
//
// `paste` and `drop` carry the picture already decoded. The composer takes it
// off the event, re-encodes anything that is not a PNG through a canvas, and
// posts the bytes up. That replaces the RichEdit path's three hand-carried
// steps — intercept Ctrl+V, ask the clipboard whether it holds a bitmap,
// swallow the `WM_CHAR` the interception left behind — with the event the
// engine was already going to fire.
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
  // An image chip, and where its number lives (T936). Same rule.
  var ICLASS = "i";
  var IATTR = "data-img";
  // The most bytes one pasted picture may carry, from the host's `vars`. Zero
  // until it arrives, which reads as "no cap yet" rather than "refuse
  // everything": a paste in that window is better refused by the store, which
  // has the same number and a message for it.
  var imgMax = 0;

  // The structural-edit journal (T983). Each entry is a whole document — the
  // one an `undo:true` seed replaced — because the edit it stands for is a
  // whole-document replacement and there is nothing smaller to record.
  //
  // Bounded, so a composer somebody quotes into all afternoon cannot grow a
  // journal without end; the oldest step is the one nobody is coming back for.
  var undoStack = [];
  var redoStack = [];
  var JOURNAL_MAX = 32;

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
      } else if (isChip(n)) {
        // An image chip is INLINE and atomic: its text is the chip, it starts
        // no line, and there is nothing inside it worth walking. Anything else
        // here would put a newline into the buffer that the seed did not have,
        // and the round trip is what everything downstream stands on.
        out.s += n.textContent;
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
    return attrNumber(node, QATTR);
  }

  function isChip(node) {
    return node.nodeType === 1 && attrNumber(node, IATTR) > 0;
  }

  function attrNumber(node, name) {
    if (!node.getAttribute) return 0;
    var raw = node.getAttribute(name);
    if (!raw) return 0;
    var n = parseInt(raw, 10);
    return n > 0 ? n : 0;
  }

  // What a chip carrying `n` must read as, and the ONLY text a node may keep
  // its chip role with. Spelled the same way `viewer_feedback_images.zig`
  // spells it, because the host parses the serialized text with that grammar
  // and a node whose text drifted from it would be a picture the report has
  // and the buffer does not.
  function chipText(n) {
    return "[Image #" + n + "]";
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

  // Keep the chip nodes honest, on the same schedule and for the same reason
  // as the quotes above — before every read, not after the edit that might
  // have been the one that broke them.
  //
  // A chip is atomic, so the engine cannot damage one in place; what it CAN do
  // is duplicate one (copy a chip, paste it twice) or carry one into a document
  // where its picture is not the picture that number names any more. Either way
  // the answer is the same as the text derivation's, which has always let the
  // SECOND reference be plain text: the node loses its role and becomes exactly
  // the characters it was showing. Nothing is deleted — the user's text is
  // theirs — and `Store.live` then reads the result the way it always has.
  function normalizeChips() {
    var nodes = el.querySelectorAll("." + ICLASS);
    var seen = {};
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var num = attrNumber(n, IATTR);
      if (num > 0 && !seen[num] && n.textContent === chipText(num)) {
        seen[num] = true;
        continue;
      }
      if (n.parentNode) n.parentNode.replaceChild(document.createTextNode(n.textContent), n);
    }
  }

  function readAll() {
    normalizeQuotes();
    normalizeChips();
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

  function seed(text, caret, atGen, quotes, images, undoable) {
    // `undoable` says this seed IS one user-visible edit — a quote or a chip
    // going in — so what it replaces is worth keeping. Every other seed is the
    // document being replaced by something unrelated (a fresh open, a report
    // cleared behind a send, a native write), and the journal goes with it: an
    // undo that resurrected a report the user already sent would be worse than
    // no undo at all.
    if (undoable) {
      journalPush(undoStack, checkpoint());
      redoStack.length = 0;
    } else {
      undoStack.length = 0;
      redoStack.length = 0;
    }
    gen = typeof atGen === "number" ? atGen : gen;
    build(text, sane(quotes, text.length, "id"), sane(images, text.length, "n"));
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
  //
  // `key` is which field carries the number: `id` for a quote block, `n` for an
  // image chip. Both lists are checked the same way because both describe runs
  // of the same string; what differs is only what the run becomes.
  function sane(spans, len, key) {
    var out = [];
    if (!spans || !spans.length) return out;
    var at = 0;
    for (var i = 0; i < spans.length; i++) {
      var s = spans[i];
      if (!s || !(s[key] > 0)) continue;
      var start = s.start | 0;
      var end = s.end | 0;
      if (start < at || end <= start || end > len) continue;
      out.push({ v: s[key], start: start, end: end });
      at = end;
    }
    return out;
  }

  // Lay the document out as text nodes with a quote block wherever the host
  // named one. The serialization above reproduces `text` exactly as long as
  // each block starts a line, which is the invariant native's own insertion
  // guarantees (a quote is inserted as its own block, with air either side).
  function build(text, quotes, images) {
    el.textContent = "";
    var at = 0;
    for (var i = 0; i < quotes.length; i++) {
      var q = quotes[i];
      if (q.start > at) fill(el, text, at, q.start, images);
      var block = document.createElement("div");
      block.className = QCLASS;
      block.setAttribute(QATTR, String(q.v));
      fill(block, text, q.start, q.end, images);
      el.appendChild(block);
      at = q.end;
    }
    if (at < text.length) fill(el, text, at, text.length, images);
  }

  // `text[from..to)` into `parent`, as text nodes with an atomic chip node
  // wherever the host named one INSIDE the range. A chip can sit inside a
  // quote (paste a picture with the caret in a quoted block), so the two span
  // lists are not siblings - the images are laid into whichever run contains
  // them, and a span straddling a boundary is skipped rather than split.
  function fill(parent, text, from, to, images) {
    var at = from;
    for (var i = 0; i < images.length; i++) {
      var im = images[i];
      if (im.start < at || im.end > to) continue;
      if (im.start > at) parent.appendChild(document.createTextNode(text.slice(at, im.start)));
      parent.appendChild(chipNode(im.v, text.slice(im.start, im.end)));
      at = im.end;
    }
    if (at < to) parent.appendChild(document.createTextNode(text.slice(at, to)));
  }

  // One chip. `contenteditable="false"` is the whole feature: it is what makes
  // the engine treat the run as a single character for the caret, for
  // selection and - the part that matters - for Backspace.
  function chipNode(n, label) {
    var span = document.createElement("span");
    span.className = ICLASS;
    span.setAttribute(IATTR, String(n));
    span.setAttribute("contenteditable", "false");
    span.textContent = label;
    return span;
  }

  // Select image chip `n`, whole - what a click on its thumbnail does.
  function pick(n) {
    var nodes = el.querySelectorAll("." + ICLASS);
    for (var i = 0; i < nodes.length; i++) {
      if (attrNumber(nodes[i], IATTR) !== n) continue;
      var r = document.createRange();
      r.selectNode(nodes[i]);
      var sel = window.getSelection();
      if (sel) {
        sel.removeAllRanges();
        sel.addRange(r);
      }
      if (nodes[i].scrollIntoView) nodes[i].scrollIntoView({ block: "nearest" });
      report(false);
      return;
    }
  }

  // Put the caret `at` code units into the serialized text. The walk is the
  // read path's, minus the string: the same order, so an offset that came out
  // of a snapshot goes back to the character it named.
  function placeCaret(at) {
    var pos = 0;
    var node = null;
    var off = 0;
    // A chip the caret landed against, and which side of it. The caret never
    // goes INSIDE one - it is one character as far as editing is concerned, and
    // a caret between its brackets is a caret in a place the user cannot get to
    // with an arrow key.
    var edge = null;
    var before = false;
    (function visit(parent) {
      for (var n = parent.firstChild; n && !node && !edge; n = n.nextSibling) {
        if (n.nodeType === 3) {
          if (at <= pos + n.data.length) {
            node = n;
            off = at - pos;
            return;
          }
          pos += n.data.length;
        } else if (isChip(n)) {
          var len = n.textContent.length;
          if (at <= pos) {
            edge = n;
            before = true;
            return;
          }
          if (at <= pos + len) {
            edge = n;
            return;
          }
          pos += len;
        } else if (n.nodeType === 1) {
          visit(n);
        }
      }
    })(el);

    var sel = window.getSelection();
    var r = document.createRange();
    if (node) r.setStart(node, Math.min(off, node.data.length));
    else if (edge) {
      if (before) r.setStartBefore(edge);
      else r.setStartAfter(edge);
    } else r.setStart(el, el.childNodes.length);
    r.collapse(true);
    if (sel) {
      sel.removeAllRanges();
      sel.addRange(r);
    }
  }

  // -----------------------------------------------------------------------
  // Undo and redo (T983)
  // -----------------------------------------------------------------------

  // What the document is right now, in one value: the markup (which carries
  // the quote blocks with their ids and the chips with their numbers — the two
  // things a plain-text checkpoint would lose) and where the caret sits in the
  // string that markup serializes to.
  function checkpoint() {
    return { html: el.innerHTML, caret: caretOffset() };
  }

  function journalPush(stack, entry) {
    stack.push(entry);
    if (stack.length > JOURNAL_MAX) stack.shift();
  }

  // Put a checkpoint back, and tell the host — the snapshot that follows is
  // what makes the pane's buffer, the report's quotes and the carousel's live
  // pictures all agree with the document again, exactly as they do after an
  // edit the user made by hand.
  function journalRestore(entry) {
    el.innerHTML = entry.html;
    var text = readAll().s;
    placeCaret(entry.caret >= 0 ? Math.min(entry.caret, text.length) : text.length);
    report(true);
  }

  // One Ctrl+Z (or one Ctrl+Y), engine first.
  //
  // The engine is asked with its own command rather than by letting the key
  // through, because the answer has to be read on this stack: an undo that
  // moved nothing is the signal that its stack is spent and ours is next. That
  // comparison is on the MARKUP, not the text — deleting a quote block can
  // leave the same characters behind as plain text, and an engine step that
  // only restored the block would otherwise read as "nothing happened".
  function history(undoing) {
    var before = el.innerHTML;
    document.execCommand(undoing ? "undo" : "redo");
    if (el.innerHTML !== before) {
      // The engine had a step. Its own `input` event reports it; this is the
      // belt for the paths where a command does not fire one.
      report(false);
      return;
    }
    var from = undoing ? undoStack : redoStack;
    var to = undoing ? redoStack : undoStack;
    if (!from.length) return;
    var entry = from.pop();
    journalPush(to, checkpoint());
    journalRestore(entry);
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
    // The chip's own two numbers, and the cap it refuses a picture at.
    if (v.ipad) root.setProperty("--i-pad", v.ipad + "px");
    if (v.iradius) root.setProperty("--i-radius", v.iradius + "px");
    if (typeof v.imgMax === "number") imgMax = v.imgMax;
    if (typeof v.text === "string") el.setAttribute("data-placeholder", v.text);
    // A scale change moves the line box, so the count the host is laying out
    // from is stale until this is re-measured.
    report(true);
  }

  if (host) {
    host.addEventListener("message", function (e) {
      var m = e.data;
      if (!m || typeof m !== "object") return;
      if (m.t === "seed")
        seed(
          typeof m.text === "string" ? m.text : "",
          m.caret,
          m.gen,
          m.quotes,
          m.images,
          m.undo === true,
        );
      else if (m.t === "vars") applyVars(m);
      else if (m.t === "focus") el.focus();
      else if (m.t === "pick") pick(m.n | 0);
    });
  }

  el.addEventListener("input", function () {
    report(false);
  });

  // Undo and redo, taken from the engine rather than left to it (T983): the
  // chords are handled here so a quote or a chip that arrived as a seed can
  // come back out once the engine's own steps are spent. Ctrl+Y is Windows'
  // redo; Ctrl+Shift+Z is the one users bring with them from everywhere else.
  el.addEventListener("keydown", function (e) {
    if (!e.ctrlKey || e.altKey || e.metaKey) return;
    var k = e.key ? e.key.toLowerCase() : "";
    var undoing = k === "z" && !e.shiftKey;
    var redoing = k === "y" || (k === "z" && e.shiftKey);
    if (!undoing && !redoing) return;
    e.preventDefault();
    history(undoing);
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

  // -----------------------------------------------------------------------
  // Pictures (T936)
  //
  // The engine hands them over already decoded, in the two events a user would
  // expect to work: paste and drop. Everything below is about getting the bytes
  // to the host as a PNG - the host's store, the chip, the carousel and the
  // report are unchanged, because what arrives there is what always arrived.
  // -----------------------------------------------------------------------

  el.addEventListener("paste", function (e) {
    var file = imageIn(e.clipboardData);
    if (!file) return; // text: the engine's own paste, which is the point
    // Only once we KNOW there is a picture: a preventDefault on every paste
    // would take plain text with it.
    e.preventDefault();
    attach(file);
  });

  // A drop that is not handled navigates this view to the file, which would
  // take the whole composer with it - so the default goes either way, and only
  // then do we look for a picture.
  el.addEventListener("dragover", function (e) {
    e.preventDefault();
  });
  el.addEventListener("drop", function (e) {
    e.preventDefault();
    var file = imageIn(e.dataTransfer);
    if (file) attach(file);
  });

  // The first image in a clipboard or a drag. `files` covers a dropped file and
  // a copied one; `items` covers a screenshot, which arrives as an item with no
  // file entry on some paths.
  function imageIn(dt) {
    if (!dt) return null;
    var i;
    if (dt.files) {
      for (i = 0; i < dt.files.length; i++) {
        if (dt.files[i].type.indexOf("image/") === 0) return dt.files[i];
      }
    }
    if (dt.items) {
      for (i = 0; i < dt.items.length; i++) {
        var it = dt.items[i];
        if (it.kind !== "file" || it.type.indexOf("image/") !== 0) continue;
        var f = it.getAsFile();
        if (f) return f;
      }
    }
    return null;
  }

  function attach(file) {
    if (imgMax > 0 && file.size > imgMax) {
      post({ t: "image", err: "too-large", bytes: file.size });
      return;
    }
    toPng(file)
      .then(function (buf) {
        post({ t: "image", png: base64(buf), bytes: buf.byteLength });
      })
      .catch(function () {
        post({ t: "image", err: "unreadable", bytes: file.size });
      });
  }

  // The store takes PNGs and nothing else, so anything else is re-encoded
  // through a canvas - which is how a dropped JPEG or a WebP off a web page
  // becomes an attachment instead of a refusal.
  function toPng(file) {
    if (file.type === "image/png") return file.arrayBuffer();
    if (!window.createImageBitmap || !window.OffscreenCanvas) return Promise.reject();
    return createImageBitmap(file)
      .then(function (bmp) {
        var canvas = new OffscreenCanvas(bmp.width, bmp.height);
        canvas.getContext("2d").drawImage(bmp, 0, 0);
        bmp.close();
        return canvas.convertToBlob({ type: "image/png" });
      })
      .then(function (blob) {
        return blob.arrayBuffer();
      });
  }

  // `PostWebMessageAsJson` carries a JSON string, so the bytes cross as base64.
  // Chunked because `String.fromCharCode.apply` on a megabyte-long array blows
  // the argument limit, which shows up as a paste that silently does nothing.
  function base64(buf) {
    var bytes = new Uint8Array(buf);
    var out = "";
    var chunk = 0x8000;
    for (var i = 0; i < bytes.length; i += chunk) {
      out += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(out);
  }

  el.classList.add("empty");
  post({ t: "ready" });
})();
