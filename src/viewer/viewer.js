/* Ghoztty viewer page runtime. The native side (ViewerView) injects content
 * via the window.__viewer API below; everything renders offline from the
 * bundled vendor libraries. */
"use strict";

(function () {
  const md = window.markdownit({
    // Emit raw inline/block HTML (e.g. the GitHub-style <h1>/<p align>/<img>
    // header many READMEs use) instead of escaping it to literal text. This
    // renders arbitrary local files AND remote sites, so the emitted HTML is
    // always run through DOMPurify below before it touches the DOM — script,
    // event handlers, and other active content are stripped, matching the
    // sanitized-subset approach GitHub uses.
    html: true,
    linkify: true,
    typographer: true,
    highlight: function (str, lang) {
      if (lang && window.hljs.getLanguage(lang)) {
        try {
          return window.hljs.highlight(str, { language: lang, ignoreIllegals: true }).value;
        } catch (e) { /* fall through */ }
      }
      return ""; // use markdown-it's default escaping
    },
  }).use(window.markdownitTaskLists, { enabled: false, label: true });

  const content = document.getElementById("content");

  function restoreScroll(y) {
    // Clamp happens naturally; restore after layout.
    requestAnimationFrame(function () {
      window.scrollTo(0, y);
      reportActiveHeading();
    });
  }

  /* Render markdown source. Preserves the current scroll position when
   * re-rendering (live reload). */
  function setMarkdown(source) {
    const y = window.scrollY;
    // md.render emits raw HTML (html: true); sanitize before inserting so an
    // opened file can't inject <script>, onerror=, javascript: URLs, etc. The
    // default DOMPurify profile keeps the tags/attributes a README header needs
    // (<h1>, <p align>, <img width>, <a href>, <br>) and highlight.js/task-list
    // markup (<span class>, <input type=checkbox disabled>).
    content.innerHTML = window.DOMPurify.sanitize(md.render(source));
    // Heading ids are assigned AFTER sanitization, on the live nodes, so the
    // TOC's anchors can never be stripped by DOMPurify (and a file that ships
    // its own heading ids keeps them).
    indexHeadings();
    restoreScroll(y);
  }

  /* Render a plain text / code file, colorized by language id (from the
   * file extension) when highlight.js knows it. */
  function setCode(source, lang) {
    const y = window.scrollY;
    const pre = document.createElement("pre");
    pre.className = "viewer-code";
    const code = document.createElement("code");
    if (lang && window.hljs.getLanguage(lang)) {
      code.className = "language-" + lang;
      code.innerHTML = window.hljs.highlight(source, {
        language: lang,
        ignoreIllegals: true,
      }).value;
    } else {
      code.textContent = source;
    }
    pre.appendChild(code);
    content.replaceChildren(pre);
    // Text/code files have no heading structure: no TOC at all.
    clearHeadingIndex();
    restoreScroll(y);
  }

  /* Show an error card (missing/unreadable file). */
  function setError(title, detail) {
    content.replaceChildren();
    const card = document.createElement("div");
    card.className = "viewer-error";
    const h = document.createElement("h1");
    h.textContent = title;
    const p = document.createElement("p");
    p.textContent = detail;
    card.appendChild(h);
    card.appendChild(p);
    content.appendChild(card);
    clearHeadingIndex();
  }

  /* ---------------------------------------------------------------------
   * Table of contents bridge
   *
   * The TOC itself is drawn NATIVELY (ViewerTOCPanel, on the Swift side) so
   * it is pixel-identical to the pane banner overlay rather than a CSS
   * approximation of it. This page is only the data source: it assigns
   * anchor ids, hands over the heading list after every render, reports
   * which section is at the top of the pane as the user scrolls, and
   * performs the scroll when the native list is clicked.
   *
   * Everything here degrades to a no-op when the message handler is absent
   * (the browser harness, or a WebKit build without the bridge installed),
   * so the page still renders standalone.
   * ------------------------------------------------------------------- */

  /* Headings in document order, and the id last reported as active. */
  let tocHeadings = [];
  let reportedActiveID = null;

  /* Distance below the top of the pane at which a heading counts as "the
   * section you are reading" for scroll-spy. */
  const SPY_MARKER = 88;

  function bridge() {
    return window.webkit
      && window.webkit.messageHandlers
      && window.webkit.messageHandlers.viewerTOC;
  }

  function post(message) {
    const handler = bridge();
    if (!handler) return;
    try {
      handler.postMessage(message);
    } catch (e) { /* handler torn down mid-flight */ }
  }

  /* GitHub-style anchor slug, deduplicated within the document. */
  function slugify(text, used) {
    let base = text
      .toLowerCase()
      .trim()
      .replace(/[^\p{L}\p{N}\s-]/gu, "")
      .replace(/\s+/g, "-");
    if (!base) base = "section";
    let slug = base;
    let n = 1;
    while (used.has(slug)) {
      slug = base + "-" + n;
      n += 1;
    }
    used.add(slug);
    return slug;
  }

  function clearHeadingIndex() {
    tocHeadings = [];
    reportedActiveID = null;
    post({ type: "headings", items: [] });
  }

  /* Assign anchor ids to the rendered headings and hand the list to the
   * native side. Ids are assigned AFTER sanitization, on the live nodes, so
   * they can never be stripped by DOMPurify (and a file that ships its own
   * heading ids keeps them). */
  function indexHeadings() {
    tocHeadings = [];
    reportedActiveID = null;

    const headings = Array.prototype.filter.call(
      content.querySelectorAll("h1, h2, h3, h4, h5, h6"),
      function (h) { return h.textContent.trim() !== ""; });

    // One heading is a title, not a table of contents.
    if (headings.length < 2) {
      clearHeadingIndex();
      return;
    }

    const used = new Set();
    const items = [];
    for (const heading of headings) {
      const text = heading.textContent.trim();
      if (heading.id) {
        used.add(heading.id);
      } else {
        heading.id = slugify(text, used);
      }
      items.push({
        id: heading.id,
        text: text,
        level: Number(heading.tagName.slice(1)),
      });
      tocHeadings.push(heading);
    }

    post({ type: "headings", items: items });
    reportActiveHeading();
  }

  /* Report the section currently at the top of the pane, when it changes. */
  function reportActiveHeading() {
    if (!tocHeadings.length) return;

    let index = 0;
    for (let i = 0; i < tocHeadings.length; i++) {
      if (tocHeadings[i].getBoundingClientRect().top <= SPY_MARKER) {
        index = i;
      } else {
        break;
      }
    }
    // At the very bottom the last sections can never reach the marker; the
    // last heading owns the end of the document.
    const documentEnd =
      window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
    if (documentEnd) index = tocHeadings.length - 1;

    const id = tocHeadings[index].id;
    if (id === reportedActiveID) return;
    reportedActiveID = id;
    post({ type: "active", id: id });
  }

  let spyQueued = false;
  function requestSpyUpdate() {
    if (spyQueued) return;
    spyQueued = true;
    requestAnimationFrame(function () {
      spyQueued = false;
      reportActiveHeading();
    });
  }

  window.addEventListener("scroll", requestSpyUpdate, { passive: true });
  window.addEventListener("resize", requestSpyUpdate);

  function scrollToHeading(heading) {
    const top = heading.getBoundingClientRect().top + window.scrollY - 12;
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    window.scrollTo({
      top: Math.max(0, top),
      behavior: reduceMotion ? "auto" : "smooth",
    });
  }

  /* Reserve space on the left for the native TOC card.
   *
   * The gutter is padding on the PAGE rather than an inset on the web view:
   * the card floats over the document, so the strip behind it has to be the
   * document's own background. Insetting the web view natively instead left
   * a visible seam — that strip painted the window background, not the
   * markdown page's. */
  function setGutter(width) {
    document.body.style.paddingLeft = width > 0 ? width + "px" : "";
    requestSpyUpdate();
  }

  /* Called by the native TOC when a row is clicked. */
  function scrollToAnchor(id) {
    const target = document.getElementById(id);
    if (!target) return;
    scrollToHeading(target);
  }

  // In-document links written by the author ("[jump](#section)") have real
  // targets now that headings carry ids, and need the same treatment: scroll
  // in page instead of escaping to the native link router.
  content.addEventListener("click", function (event) {
    const link = event.target.closest ? event.target.closest("a") : null;
    if (!link || !content.contains(link)) return;
    const href = link.getAttribute("href");
    if (!href || href.charAt(0) !== "#") return;
    let target = null;
    try {
      target = document.getElementById(decodeURIComponent(href.slice(1)));
    } catch (e) {
      target = document.getElementById(href.slice(1));
    }
    if (!target) return;
    event.preventDefault();
    scrollToHeading(target);
  });

  /* ---------------------------------------------------------------------
   * Selection toolbar
   *
   * Selecting text pops a small toolbar with Quote and Copy. Quote hands the
   * selection to the native feedback composer along with enough REFERENTIAL
   * context that an agent reading the report can find what was being
   * discussed: the section it sits under, the containing block's full text,
   * and the offsets of the quote inside that block and inside the document.
   * Text alone is ambiguous — the same sentence can appear twice.
   * ------------------------------------------------------------------- */

  let selectionBar = null;

  function buildSelectionBar() {
    const bar = document.createElement("div");
    bar.className = "viewer-selbar";
    bar.setAttribute("role", "toolbar");
    // The toolbar must never become part of what the user is quoting.
    bar.setAttribute("data-viewer-ui", "true");

    const quote = document.createElement("button");
    quote.type = "button";
    quote.className = "viewer-selbar-btn";
    quote.textContent = "Quote";
    quote.addEventListener("mousedown", function (event) {
      // mousedown, not click: a click would first collapse the selection.
      event.preventDefault();
      event.stopPropagation();
      sendQuote();
    });

    const copy = document.createElement("button");
    copy.type = "button";
    copy.className = "viewer-selbar-btn";
    copy.textContent = "Copy";
    copy.addEventListener("mousedown", function (event) {
      event.preventDefault();
      event.stopPropagation();
      copySelection(copy);
    });

    bar.appendChild(quote);
    bar.appendChild(copy);
    document.body.appendChild(bar);
    return bar;
  }

  function selectionBarElement() {
    if (!selectionBar || !document.body.contains(selectionBar)) {
      selectionBar = buildSelectionBar();
    }
    return selectionBar;
  }

  function hideSelectionBar() {
    if (selectionBar) selectionBar.classList.remove("is-visible");
  }

  /* The live selection, but only when it is a real, non-collapsed range
   * inside the rendered content (never inside our own toolbar). */
  function contentSelection() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;
    const text = String(selection).trim();
    if (!text) return null;
    const range = selection.getRangeAt(0);
    let node = range.commonAncestorContainer;
    if (node.nodeType === 3) node = node.parentNode;
    if (!node || !content.contains(node)) return null;
    if (node.closest && node.closest("[data-viewer-ui]")) return null;
    return { selection: selection, range: range, text: text };
  }

  function showSelectionBarForRange(range) {
    const rect = range.getBoundingClientRect();
    if (!rect || (rect.width === 0 && rect.height === 0)) return;
    const bar = selectionBarElement();
    bar.classList.add("is-visible");
    // Measure after making it visible, then clamp inside the viewport.
    const barRect = bar.getBoundingClientRect();
    let left = rect.left + rect.width / 2 - barRect.width / 2;
    left = Math.max(6, Math.min(left, window.innerWidth - barRect.width - 6));
    let top = rect.top - barRect.height - 8;
    // No room above the selection: sit below it instead.
    if (top < 4) top = rect.bottom + 8;
    bar.style.left = left + window.scrollX + "px";
    bar.style.top = top + window.scrollY + "px";
  }

  function updateSelectionBar() {
    const found = contentSelection();
    if (!found) {
      hideSelectionBar();
      return;
    }
    showSelectionBarForRange(found.range);
  }

  /* A CSS path for a node, stable enough to re-find the block later. */
  function selectorFor(node) {
    if (!node || node === content) return "";
    const parts = [];
    let current = node;
    while (current && current !== content && current.nodeType === 1 && parts.length < 8) {
      if (current.id) {
        parts.unshift("#" + current.id);
        break;
      }
      const parent = current.parentNode;
      let index = 1;
      if (parent) {
        for (const sibling of parent.children) {
          if (sibling === current) break;
          if (sibling.tagName === current.tagName) index += 1;
        }
      }
      parts.unshift(current.tagName.toLowerCase() + ":nth-of-type(" + index + ")");
      current = parent;
    }
    return parts.join(" > ");
  }

  /* The block-level element a node sits in — the unit worth quoting around. */
  function blockFor(node) {
    let current = node.nodeType === 3 ? node.parentNode : node;
    const blocks = "P,LI,BLOCKQUOTE,PRE,TD,TH,H1,H2,H3,H4,H5,H6,DD,DT,FIGCAPTION";
    while (current && current !== content) {
      if (current.matches && current.matches(blocks)) return current;
      current = current.parentNode;
    }
    return content;
  }

  /* The heading whose section contains a node. */
  function headingFor(node) {
    let element = node.nodeType === 3 ? node.parentNode : node;
    const all = Array.prototype.slice.call(
      content.querySelectorAll("h1, h2, h3, h4, h5, h6"));
    if (!all.length) return null;
    let best = null;
    for (const heading of all) {
      const position = heading.compareDocumentPosition(element);
      // Node comes after this heading in document order.
      if (position & Node.DOCUMENT_POSITION_FOLLOWING) best = heading;
    }
    return best;
  }

  /* Character offset of a range's start within an ancestor's text. */
  function offsetWithin(ancestor, range) {
    try {
      const probe = document.createRange();
      probe.selectNodeContents(ancestor);
      probe.setEnd(range.startContainer, range.startOffset);
      return probe.toString().length;
    } catch (e) {
      return -1;
    }
  }

  function sendQuote() {
    const found = contentSelection();
    if (!found) return;
    const range = found.range;
    const block = blockFor(range.startContainer);
    const heading = headingFor(range.startContainer);
    post({
      type: "quote",
      text: found.text,
      headingId: heading ? heading.id : "",
      headingText: heading ? heading.textContent.trim() : "",
      blockSelector: selectorFor(block),
      blockText: block ? block.textContent.trim() : "",
      offsetInBlock: block ? offsetWithin(block, range) : -1,
      documentOffset: offsetWithin(content, range),
    });
    hideSelectionBar();
    window.getSelection().removeAllRanges();
  }

  function copySelection(button) {
    const found = contentSelection();
    if (!found) return;
    const restore = function () { button.textContent = "Copy"; };
    const done = function () {
      button.textContent = "Copied";
      setTimeout(restore, 1200);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(found.text).then(done, done);
    } else {
      try {
        document.execCommand("copy");
      } catch (e) { /* nothing else to try */ }
      done();
    }
  }

  document.addEventListener("mouseup", function () {
    // After the mouseup that finished the drag, so the range is final.
    setTimeout(updateSelectionBar, 0);
  });
  document.addEventListener("keyup", function (event) {
    if (event.shiftKey || event.key === "Escape") setTimeout(updateSelectionBar, 0);
  });
  document.addEventListener("mousedown", function (event) {
    if (event.target.closest && event.target.closest("[data-viewer-ui]")) return;
    hideSelectionBar();
  });
  window.addEventListener("scroll", hideSelectionBar, { passive: true });
  window.addEventListener("resize", hideSelectionBar);

  window.__viewer = {
    setMarkdown: setMarkdown,
    setCode: setCode,
    setError: setError,
    // Called from the native TOC panel.
    scrollToAnchor: scrollToAnchor,
    setGutter: setGutter,
  };
})();
