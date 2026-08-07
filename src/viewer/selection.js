/* Selection toolbar for viewer panes.
 *
 * Injected as a WKUserScript into EVERY page a viewer shows — the bundled
 * markdown/code template AND arbitrary websites. It cannot live in viewer.js,
 * which is a <script src> inside viewer.html and therefore never reaches a
 * real web page; that is why quoting used to work only on markdown.
 *
 * Because it runs inside pages we do not control, it is defensive about the
 * host document: the UI lives in a SHADOW ROOT so page CSS cannot restyle or
 * hide it, and nothing here touches page globals beyond one install guard.
 */
(function () {
  "use strict";

  if (window.__ghozttySelection) return;
  window.__ghozttySelection = true;

  /* Material-standard glyphs: format_quote and content_copy. Recognizable
   * without a label, which is what a selection popover needs — it sits over
   * the user's text and must stay small. */
  const ICON_QUOTE =
    '<path d="M6 17h3l2-4V7H5v6h3zm8 0h3l2-4V7h-6v6h3z"/>';
  const ICON_COPY =
    '<path d="M16 1H4a2 2 0 0 0-2 2v14h2V3h12V1zm3 4H8a2 2 0 0 0-2 2v14a2 2 0 0 0 ' +
    '2 2h11a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2zm0 16H8V7h11v14z"/>';
  const ICON_CHECK = '<path d="M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"/>';

  const STYLE = `
    :host { all: initial; }
    .bar {
      position: fixed;
      z-index: 2147483647;
      display: none;
      gap: 2px;
      padding: 3px;
      border-radius: 9px;
      background: #ffffff;
      border: 1px solid rgba(0, 0, 0, 0.12);
      box-shadow: 0 6px 18px rgba(0, 0, 0, 0.22);
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    }
    .bar.on { display: flex; }
    button {
      appearance: none;
      border: 0;
      margin: 0;
      background: transparent;
      color: #1f2328;
      width: 30px;
      height: 28px;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: 6px;
      cursor: default;
    }
    button:hover { background: rgba(0, 0, 0, 0.08); }
    button:active { background: rgba(0, 0, 0, 0.15); }
    svg { width: 17px; height: 17px; fill: currentColor; display: block; }
    .ok { color: #1a7f37; }
    @media (prefers-color-scheme: dark) {
      .bar {
        background: #1c2128;
        border-color: rgba(255, 255, 255, 0.16);
        box-shadow: 0 6px 18px rgba(0, 0, 0, 0.6);
      }
      button { color: #e6edf3; }
      button:hover { background: rgba(255, 255, 255, 0.12); }
      button:active { background: rgba(255, 255, 255, 0.2); }
      .ok { color: #3fb950; }
    }
  `;

  let host = null;
  let bar = null;
  let copyButton = null;

  function iconButton(label, path) {
    const button = document.createElement("button");
    button.type = "button";
    button.title = label;
    button.setAttribute("aria-label", label);
    button.innerHTML =
      '<svg viewBox="0 0 24 24" aria-hidden="true">' + path + "</svg>";
    return button;
  }

  function build() {
    host = document.createElement("div");
    // The host itself must not be laid out by the page.
    host.style.cssText = "all: initial; position: absolute; top: 0; left: 0;";
    host.setAttribute("data-ghoztty-ui", "true");
    const root = host.attachShadow({ mode: "open" });

    const style = document.createElement("style");
    style.textContent = STYLE;
    root.appendChild(style);

    bar = document.createElement("div");
    bar.className = "bar";

    const quote = iconButton("Quote", ICON_QUOTE);
    quote.addEventListener("mousedown", function (event) {
      // mousedown, not click: a click would collapse the selection first.
      event.preventDefault();
      event.stopPropagation();
      sendQuote();
    });

    copyButton = iconButton("Copy", ICON_COPY);
    copyButton.addEventListener("mousedown", function (event) {
      event.preventDefault();
      event.stopPropagation();
      copySelection();
    });

    /* A host with nowhere to put a quote (no feedback composer yet) sets
     * window.__ghozttyHideQuote before this script runs; the bar then ships
     * Copy alone rather than a Quote button wired to nothing. */
    if (!window.__ghozttyHideQuote) bar.appendChild(quote);
    bar.appendChild(copyButton);
    root.appendChild(bar);
    (document.body || document.documentElement).appendChild(host);
  }

  function ensure() {
    if (!host || !host.isConnected) build();
    return bar;
  }

  function hide() {
    if (bar) bar.classList.remove("on");
  }

  function handler() {
    return window.webkit
      && window.webkit.messageHandlers
      && window.webkit.messageHandlers.viewerTOC;
  }

  function post(message) {
    const target = handler();
    if (!target) return;
    try {
      target.postMessage(message);
    } catch (e) { /* handler torn down mid-flight */ }
  }

  /* The rendered document root: the template page's article, or the whole
   * body on a real website. */
  function contentRoot() {
    return document.getElementById("content") || document.body;
  }

  /* A live, non-collapsed selection that is not inside our own UI. */
  function current() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;
    const text = String(selection).trim();
    if (!text) return null;
    const range = selection.getRangeAt(0);
    let node = range.commonAncestorContainer;
    if (node.nodeType === 3) node = node.parentNode;
    if (!node) return null;
    if (node.closest && node.closest("[data-ghoztty-ui]")) return null;
    return { range: range, text: text };
  }

  function place(range) {
    const rect = range.getBoundingClientRect();
    if (!rect || (rect.width === 0 && rect.height === 0)) return;
    const element = ensure();
    element.classList.add("on");
    const size = element.getBoundingClientRect();
    let left = rect.left + rect.width / 2 - size.width / 2;
    left = Math.max(6, Math.min(left, window.innerWidth - size.width - 6));
    let top = rect.top - size.height - 8;
    // No room above the selection: sit below it.
    if (top < 4) top = rect.bottom + 8;
    // `position: fixed`, so viewport coordinates — no scroll offset, and the
    // bar cannot drift off-target on a page with transformed ancestors.
    element.style.left = left + "px";
    element.style.top = top + "px";
  }

  function update() {
    const found = current();
    if (!found) {
      hide();
      return;
    }
    place(found.range);
  }

  /* A CSS path, stable enough to re-find the block later. */
  function selectorFor(node) {
    const root = contentRoot();
    if (!node || node === root) return "";
    const parts = [];
    let current = node;
    while (current && current !== root && current.nodeType === 1 && parts.length < 8) {
      if (current.id) {
        parts.unshift("#" + current.id);
        break;
      }
      const parent = current.parentNode;
      let index = 1;
      if (parent && parent.children) {
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

  const BLOCKS = "P,LI,BLOCKQUOTE,PRE,TD,TH,H1,H2,H3,H4,H5,H6,DD,DT,FIGCAPTION,ARTICLE,SECTION,DIV";

  /* The block-level element a node sits in — the unit worth quoting around. */
  function blockFor(node) {
    const root = contentRoot();
    let current = node.nodeType === 3 ? node.parentNode : node;
    while (current && current !== root) {
      if (current.matches && current.matches(BLOCKS)) return current;
      current = current.parentNode;
    }
    return root;
  }

  /* The heading whose section contains a node. */
  function headingFor(node) {
    const element = node.nodeType === 3 ? node.parentNode : node;
    const all = Array.prototype.slice.call(
      contentRoot().querySelectorAll("h1, h2, h3, h4, h5, h6"));
    let best = null;
    for (const heading of all) {
      const position = heading.compareDocumentPosition(element);
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

  function trimmed(text, limit) {
    if (!text) return "";
    const value = text.trim();
    return value.length > limit ? value.slice(0, limit) : value;
  }

  function sendQuote() {
    const found = current();
    if (!found) return;
    const range = found.range;
    const block = blockFor(range.startContainer);
    const heading = headingFor(range.startContainer);
    post({
      type: "quote",
      text: found.text,
      headingId: heading && heading.id ? heading.id : "",
      headingText: heading ? trimmed(heading.textContent, 300) : "",
      blockSelector: selectorFor(block),
      // Capped: a website's containing block can be the whole page, and an
      // unbounded blob would bloat every report for no extra locating power.
      blockText: block ? trimmed(block.textContent, 2000) : "",
      offsetInBlock: block ? offsetWithin(block, range) : -1,
      documentOffset: offsetWithin(contentRoot(), range),
    });
    hide();
    const selection = window.getSelection();
    if (selection) selection.removeAllRanges();
  }

  function flashCopied() {
    if (!copyButton) return;
    copyButton.innerHTML =
      '<svg viewBox="0 0 24 24" class="ok" aria-hidden="true">' + ICON_CHECK + "</svg>";
    copyButton.querySelector("svg").classList.add("ok");
    setTimeout(function () {
      copyButton.innerHTML =
        '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICON_COPY + "</svg>";
    }, 1100);
  }

  function copySelection() {
    const found = current();
    if (!found) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(found.text).then(flashCopied, flashCopied);
      return;
    }
    try {
      document.execCommand("copy");
    } catch (e) { /* nothing else to try */ }
    flashCopied();
  }

  document.addEventListener("mouseup", function () {
    // After the mouseup that ended the drag, so the range is final.
    setTimeout(update, 0);
  }, true);
  document.addEventListener("keyup", function (event) {
    if (event.shiftKey || event.key === "Escape") setTimeout(update, 0);
  }, true);
  document.addEventListener("mousedown", function (event) {
    const target = event.target;
    if (target && target.closest && target.closest("[data-ghoztty-ui]")) return;
    hide();
  }, true);
  // Fixed positioning means the bar would otherwise stay put while the text
  // scrolls away from under it.
  window.addEventListener("scroll", hide, true);
  window.addEventListener("resize", hide);
})();
