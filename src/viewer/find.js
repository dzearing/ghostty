/* Find-in-page for viewer panes.
 *
 * Injected as a WKUserScript into EVERY page a viewer shows — the bundled
 * markdown/code/diff template AND arbitrary websites. It cannot live in
 * viewer.js, which is a <script src> inside viewer.html and therefore never
 * reaches a real web page (the same trap that once left quoting working on
 * markdown and silently dead on a website).
 *
 * WHY NOT WKWebView's own `find(_:configuration:)`: it reports only
 * `matchFound`. There is no match COUNT and no ordinal, so "3/17" — the whole
 * point of a browser find bar — is unreachable through it, and it marks the
 * current hit as a selection rather than painting every match.
 *
 * WHY NO DOM MUTATION: the CSS Custom Highlight API paints ranges without
 * touching the tree, so a find on someone's live dev server cannot corrupt
 * its rendering, and our own painting can never re-trigger the
 * MutationObserver that keeps the count live. Where the API is missing
 * (WebKit older than Safari 17.2) the current match is shown as an ordinary
 * selection instead — the count and the stepping still work, only the paint
 * degrades.
 */
(function () {
  "use strict";

  if (window.__ghozttyFind) return;

  /* Matches past this are not indexed. The cap exists so a one-letter query on
   * a 20 000-row diff cannot spend a second building ranges; the bar says
   * "5000+" rather than pretending the number is exact. */
  const MAX_MATCHES = 5000;

  /* Re-scan delay after the page mutates. Long enough that a diff appending
   * rows a chunk per frame settles first, short enough to feel live. */
  const RESCAN_DELAY = 200;

  const HIGHLIGHT_ALL = "ghoztty-find";
  const HIGHLIGHT_CURRENT = "ghoztty-find-current";

  /* Dropped between two text runs that are NOT in the same block, so a query
   * can never match across a paragraph or a diff-row boundary (browsers do
   * not either). U+0000 because no realistic query contains it: matching
   * needs no special case, the separator simply never matches. */
  const BREAK = "\u0000";

  /* Never searched. `script`/`style`/`noscript`/`title` are not visible page
   * text at all; a form control's text is not page text and could not be
   * highlighted in place. */
  const SKIP_TAGS = {
    SCRIPT: true, STYLE: true, NOSCRIPT: true, TEXTAREA: true,
    TITLE: true, OPTION: true, SELECT: true,
  };

  /* Tags that start a block, i.e. a boundary a match may not straddle. A
   * static list rather than `getComputedStyle` per element on purpose: the
   * style query would be the single most expensive thing happening per text
   * node, and a 20 000-row diff has tens of thousands of them. */
  const BLOCK_TAGS = {
    ADDRESS: 1, ARTICLE: 1, ASIDE: 1, BLOCKQUOTE: 1, BODY: 1, BR: 1,
    CAPTION: 1, DD: 1, DETAILS: 1, DIALOG: 1, DIV: 1, DL: 1, DT: 1,
    FIELDSET: 1, FIGCAPTION: 1, FIGURE: 1, FOOTER: 1, FORM: 1, H1: 1, H2: 1,
    H3: 1, H4: 1, H5: 1, H6: 1, HEADER: 1, HR: 1, LI: 1, MAIN: 1, NAV: 1,
    OL: 1, P: 1, PRE: 1, SECTION: 1, SUMMARY: 1, TABLE: 1, TBODY: 1, TD: 1,
    TFOOT: 1, TH: 1, THEAD: 1, TR: 1, UL: 1,
  };

  const supportsHighlights =
    typeof window.CSS !== "undefined"
    && !!window.CSS.highlights
    && typeof window.Highlight === "function";

  /* Everything about the search currently on screen. A `hit` is
   * `{ range, offset }` — the offset into the text buffer is what survives a
   * re-scan, since the Range objects themselves are rebuilt. */
  let query = "";
  let hits = [];
  let current = -1;
  let truncated = false;
  /* Buffer offset of the current match, remembered across a re-scan so a page
   * growing underneath the reader keeps their place. */
  let anchor = -1;
  /* The text index, rebuilt only when the page actually changes (the observer
   * drops it) rather than on every keystroke. */
  let index = null;
  let observer = null;
  let rescanTimer = null;

  /* ---------------------------------------------------------------- *
   * Styling
   *
   * The browser find palette — yellow for every match, orange for the
   * current one, dark text on both — rather than the page's own colors. A
   * find highlight has to be recognizable ON a page whose theme we do not
   * know, in light and dark alike, and these two are what every browser has
   * trained people to look for.
   * ---------------------------------------------------------------- */
  function installStyle() {
    if (!supportsHighlights) return;
    if (document.getElementById("ghoztty-find-style")) return;
    const style = document.createElement("style");
    style.id = "ghoztty-find-style";
    style.textContent =
      "::highlight(" + HIGHLIGHT_ALL + "){background-color:#ffe27a;color:#1f2328}"
      + "::highlight(" + HIGHLIGHT_CURRENT + "){background-color:#ff9632;color:#1f2328}";
    (document.head || document.documentElement).appendChild(style);
  }

  /* ---------------------------------------------------------------- *
   * Text index
   * ---------------------------------------------------------------- */

  function contentRoot() {
    return document.body || document.documentElement;
  }

  /* The nearest ancestor that starts a block, used only to decide whether two
   * text runs sit in the same one. */
  function blockOf(element) {
    let node = element;
    while (node && !BLOCK_TAGS[node.tagName]) node = node.parentElement;
    return node || null;
  }

  /* Whitespace is mapped 1:1 onto a space rather than COLLAPSED. Keeping the
   * length identical is what lets a match offset map straight back to a text
   * node with no side table, and it buys the case that actually matters:
   * markdown wrapped in its source ("foo\nbar", rendered as "foo bar") is
   * searchable as the sentence a reader sees. The cost is the converse — an
   * HTML author's newline-plus-indent between two inline elements stays
   * several spaces wide, so a phrase spanning it will not match. That is rare
   * enough to be worth not maintaining an offset table for. */
  function normalize(text) {
    return text.replace(/\s/g, " ");
  }

  /* Lowercase WITHOUT changing the string's length. `toLowerCase()` is
   * length-preserving for everything but a handful of code points (U+0130
   * being the famous one), and one of those would shift every match offset
   * after it onto the wrong character. */
  function fold(text) {
    const lower = text.toLowerCase();
    if (lower.length === text.length) return lower;
    let out = "";
    for (let i = 0; i < text.length; i++) {
      const ch = text.charAt(i);
      const folded = ch.toLowerCase();
      out += folded.length === 1 ? folded : ch;
    }
    return out;
  }

  /* Walk the visible text into one buffer, remembering where each text node
   * landed in it. Cached: rebuilt only when the observer says the page moved. */
  function buildIndex() {
    const root = contentRoot();
    const nodes = [];
    const starts = [];
    const parts = [];
    let length = 0;
    if (!root) return { text: "", folded: "", nodes: nodes, starts: starts };

    /* `closest()` per text node is the walk's most expensive step; skip it
     * entirely on the overwhelmingly common page that has no Ghoztty overlay
     * mounted at all. */
    const hasOverlay = !!document.querySelector("[data-ghoztty-ui]");

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.nodeValue) return NodeFilter.FILTER_REJECT;
        const parent = node.parentElement;
        if (!parent) return NodeFilter.FILTER_REJECT;
        if (SKIP_TAGS[parent.tagName]) return NodeFilter.FILTER_REJECT;
        /* Our own overlays (the selection toolbar) are chrome, not content. */
        if (hasOverlay && parent.closest("[data-ghoztty-ui]")) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });

    let previousBlock = null;
    let node = walker.nextNode();
    while (node) {
      const block = blockOf(node.parentElement);
      if (previousBlock !== null && block !== previousBlock) {
        parts.push(BREAK);
        length += BREAK.length;
      }
      previousBlock = block;
      nodes.push(node);
      starts.push(length);
      const value = normalize(node.nodeValue);
      parts.push(value);
      length += value.length;
      node = walker.nextNode();
    }
    const text = parts.join("");
    return { text: text, folded: fold(text), nodes: nodes, starts: starts };
  }

  function textIndex() {
    if (!index) index = buildIndex();
    return index;
  }

  /* The text node holding buffer offset `offset`, as a position in `starts`.
   * `starts` is ascending, so this is a plain upper-bound search. */
  function nodeAt(starts, offset) {
    let low = 0;
    let high = starts.length - 1;
    let found = 0;
    while (low <= high) {
      const mid = (low + high) >> 1;
      if (starts[mid] <= offset) { found = mid; low = mid + 1; } else { high = mid - 1; }
    }
    return found;
  }

  function makeRange(idx, start, end) {
    const first = nodeAt(idx.starts, start);
    const last = nodeAt(idx.starts, end - 1);
    const range = document.createRange();
    try {
      range.setStart(idx.nodes[first], start - idx.starts[first]);
      range.setEnd(idx.nodes[last], end - idx.starts[last]);
    } catch (e) {
      return null;
    }
    return range;
  }

  /* ---------------------------------------------------------------- *
   * Searching
   * ---------------------------------------------------------------- */

  function findHits(needle) {
    const idx = textIndex();
    const wanted = fold(needle);
    const out = [];
    truncated = false;
    if (!wanted) return out;

    let from = 0;
    for (;;) {
      const at = idx.folded.indexOf(wanted, from);
      if (at < 0) break;
      if (out.length >= MAX_MATCHES) { truncated = true; break; }
      const range = makeRange(idx, at, at + wanted.length);
      /* Text that is in the tree but not laid out — a collapsed menu, a hidden
       * tab panel — has no client rect. Counting it would promise a match the
       * reader can never be scrolled to. */
      if (range && range.getClientRects().length > 0) {
        out.push({ range: range, offset: at });
      }
      from = at + wanted.length;
    }
    return out;
  }

  function paint() {
    if (supportsHighlights) {
      const all = new window.Highlight();
      for (let i = 0; i < hits.length; i++) {
        if (i !== current) all.add(hits[i].range);
      }
      window.CSS.highlights.set(HIGHLIGHT_ALL, all);
      const one = new window.Highlight();
      if (current >= 0 && hits[current]) one.add(hits[current].range);
      window.CSS.highlights.set(HIGHLIGHT_CURRENT, one);
      return;
    }
    /* No Custom Highlight API: show the current match as a selection. Nothing
     * paints the other matches, but the count and the stepping stay honest.
     * The selection toolbar fires on mouseup/keyup, so this never pops it. */
    const selection = window.getSelection();
    if (!selection) return;
    selection.removeAllRanges();
    if (current >= 0 && hits[current]) selection.addRange(hits[current].range.cloneRange());
  }

  function unpaint() {
    if (supportsHighlights) {
      window.CSS.highlights.delete(HIGHLIGHT_ALL);
      window.CSS.highlights.delete(HIGHLIGHT_CURRENT);
      return;
    }
    const selection = window.getSelection();
    if (selection) selection.removeAllRanges();
  }

  function reveal() {
    const hit = hits[current];
    if (!hit) return;
    const element = hit.range.startContainer.parentElement;
    if (!element) return;
    /* scrollIntoView first, because it is the only thing that handles a match
     * inside a NESTED scroller; then a nudge from the range's own rect, since
     * centering the containing paragraph does not center the phrase inside it.
     * Both are instant: a smooth scroll cannot keep up with a held Enter. */
    element.scrollIntoView({ block: "center", inline: "nearest" });
    const rect = hit.range.getBoundingClientRect();
    if (rect.top < window.innerHeight * 0.2 || rect.bottom > window.innerHeight * 0.85) {
      window.scrollBy(0, rect.top - window.innerHeight * 0.4);
    }
  }

  /* Where a fresh query lands: the first match at or below what the reader can
   * already see, as a browser does — searching for something on screen should
   * not throw you to the top of the document. */
  function firstFromViewport() {
    for (let i = 0; i < hits.length; i++) {
      if (hits[i].range.getBoundingClientRect().bottom > 0) return i;
    }
    return hits.length ? 0 : -1;
  }

  /* After a re-scan, the match nearest where the current one used to be. */
  function nearestToAnchor() {
    if (!hits.length) return -1;
    if (anchor < 0) return 0;
    let best = 0;
    let bestDelta = Infinity;
    for (let i = 0; i < hits.length; i++) {
      const delta = Math.abs(hits[i].offset - anchor);
      if (delta < bestDelta) { bestDelta = delta; best = i; }
    }
    return best;
  }

  /* ---------------------------------------------------------------- *
   * Honesty about what is NOT being searched
   * ---------------------------------------------------------------- */

  /* A page may describe its own unsearched content by defining
   * `window.__ghozttyFindScope` — a function returning a short phrase. The
   * diff renderer uses it to say WHICH file is being searched (a diff pane
   * holds one file's patch at a time) and whether its row cap is in force. */
  function scopeNote() {
    const notes = [];
    try {
      if (typeof window.__ghozttyFindScope === "function") {
        const note = window.__ghozttyFindScope();
        if (note) notes.push(String(note));
      }
    } catch (e) { /* a page's hook must never break find */ }
    /* A frame is a separate document with its own scripts; this searches the
     * main frame only. Said only when there is a LAID-OUT frame to miss, so a
     * site's hidden tracking iframe does not produce a permanent warning. */
    const frames = document.querySelectorAll("iframe, frame");
    for (let i = 0; i < frames.length; i++) {
      if (frames[i].getClientRects().length > 0) {
        notes.push("frames not searched");
        break;
      }
    }
    return notes.length ? notes.join(" · ") : null;
  }

  /* ---------------------------------------------------------------- *
   * Reporting
   * ---------------------------------------------------------------- */

  function post() {
    const target = window.webkit
      && window.webkit.messageHandlers
      && window.webkit.messageHandlers.viewerTOC;
    if (!target) return;
    try {
      target.postMessage({
        type: "find",
        query: query,
        total: hits.length,
        index: current >= 0 ? current + 1 : 0,
        truncated: truncated,
        note: scopeNote(),
      });
    } catch (e) { /* handler torn down mid-flight */ }
  }

  /* ---------------------------------------------------------------- *
   * Live re-scan
   * ---------------------------------------------------------------- */

  function startObserving() {
    if (observer || !window.MutationObserver) return;
    observer = new MutationObserver(function () {
      /* The index is now a description of a page that no longer exists. */
      index = null;
      if (!query) return;
      if (rescanTimer) clearTimeout(rescanTimer);
      rescanTimer = setTimeout(rescan, RESCAN_DELAY);
    });
    observer.observe(contentRoot(), {
      childList: true, subtree: true, characterData: true,
    });
  }

  function stopObserving() {
    if (rescanTimer) { clearTimeout(rescanTimer); rescanTimer = null; }
    if (observer) { observer.disconnect(); observer = null; }
  }

  /* The page changed under an open search — a diff appending its rows a chunk
   * per frame, a file viewer re-rendering after a save, a site loading more.
   * Re-index and keep the reader as close to their match as the new content
   * allows, but do NOT scroll: they did not ask to move. */
  function rescan() {
    rescanTimer = null;
    if (!query) return;
    hits = findHits(query);
    current = nearestToAnchor();
    if (current >= 0) anchor = hits[current].offset;
    paint();
    post();
  }

  /* ---------------------------------------------------------------- *
   * API — driven from ViewerView via evaluateJavaScript
   * ---------------------------------------------------------------- */

  function search(text) {
    installStyle();
    query = String(text || "");
    if (!query) {
      clear();
      post();
      return;
    }
    /* Nothing watched the page while find was closed, so the cached index
     * describes a document that may have moved on. */
    if (!observer) index = null;
    hits = findHits(query);
    current = firstFromViewport();
    anchor = current >= 0 ? hits[current].offset : -1;
    paint();
    if (current >= 0) reveal();
    post();
    startObserving();
  }

  function step(delta) {
    if (!hits.length) { post(); return; }
    const count = hits.length;
    current = ((current + delta) % count + count) % count;
    anchor = hits[current].offset;
    paint();
    reveal();
    post();
  }

  function clear() {
    stopObserving();
    unpaint();
    query = "";
    hits = [];
    current = -1;
    truncated = false;
    anchor = -1;
    index = null;
  }

  window.__ghozttyFind = {
    search: search,
    step: step,
    clear: function () { clear(); post(); },
  };
})();
