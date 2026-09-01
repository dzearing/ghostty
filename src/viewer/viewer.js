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

  // DOMPurify's default URI allowlist plus `ghoztty:` / `ghoztty-debug:` —
  // the focus-only custom scheme (src/apprt/ipc/url_scheme.zig on Windows,
  // GhozttyURLScheme.swift on macOS). Without this an
  // `[open the worktree](ghoztty://focus/dev)` link in a rendered document
  // survives markdown-it and is then stripped of its href by the sanitizer,
  // rendering as dead text. Everything else is verbatim DOMPurify default, so
  // `javascript:`/`data:` stay blocked; keep it in sync when the vendored copy
  // is bumped.
  const ALLOWED_URI_REGEXP =
    /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix|ghoztty|ghoztty-debug):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i;

  function sanitize(html) {
    return window.DOMPurify.sanitize(html, { ALLOWED_URI_REGEXP: ALLOWED_URI_REGEXP });
  }

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
    leaveImageMode();
    content.className = "markdown-body";
    // md.render emits raw HTML (html: true); sanitize before inserting so an
    // opened file can't inject <script>, onerror=, javascript: URLs, etc. The
    // default DOMPurify profile keeps the tags/attributes a README header needs
    // (<h1>, <p align>, <img width>, <a href>, <br>) and highlight.js/task-list
    // markup (<span class>, <input type=checkbox disabled>).
    content.innerHTML = sanitize(md.render(source));
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
    leaveImageMode();
    content.className = "markdown-body";
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
    leaveImageMode();
    content.className = "markdown-body";
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
    // A pin belongs to the document that was on screen; a new one (or a live
    // reload) must not inherit a frozen spy.
    pinnedHeadingID = null;
    post({ type: "headings", items: [] });
  }

  /* Assign anchor ids to the rendered headings and hand the list to the
   * native side. Ids are assigned AFTER sanitization, on the live nodes, so
   * they can never be stripped by DOMPurify (and a file that ships its own
   * heading ids keeps them). */
  function indexHeadings() {
    tocHeadings = [];
    reportedActiveID = null;
    pinnedHeadingID = null;

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

  /* The heading the user just clicked in the TOC (or an in-page link).
   *
   * A click starts a SMOOTH scroll, which fires a scroll event on every frame
   * of the way there — and the spy below would happily report each section the
   * page flies past, so clicking a distant heading selected it and then walked
   * the selection off somewhere else before the scroll even finished. While a
   * heading is pinned the spy stays quiet: the user said where they are going,
   * and the animation getting there is not new information.
   *
   * The pin is released by the user's own next scroll gesture (see below), not
   * by the scroll settling: a heading near the end of the document can never
   * reach the spy marker, so "release when the scroll stops" would hand the
   * selection straight back to whichever section could. */
  var pinnedHeadingID = null;

  function pinActiveHeading(id) {
    pinnedHeadingID = id;
    if (reportedActiveID === id) return;
    reportedActiveID = id;
    post({ type: "active", id: id });
  }

  function releasePinnedHeading() {
    if (pinnedHeadingID === null) return;
    pinnedHeadingID = null;
    // Resync NOW rather than through requestAnimationFrame: the pin has been
    // suppressing reports, so the native side is showing a row the reader may
    // have already scrolled away from, and rAF is throttled (or suspended
    // outright) whenever the pane is not visibly on screen.
    reportActiveHeading();
  }

  /* Any scroll the USER starts hands the spy back. Listening for the input
   * events rather than for `scroll` is the whole point — a programmatic
   * smooth scroll is indistinguishable from a user one by the time it reaches
   * the scroll event. Capture phase so a handler that stops propagation
   * can't leave the selection frozen. */
  ["wheel", "touchmove", "keydown", "mousedown"].forEach(function (type) {
    window.addEventListener(type, releasePinnedHeading, {
      passive: true,
      capture: true,
    });
  });

  /* Report the section currently at the top of the pane, when it changes. */
  function reportActiveHeading() {
    if (!tocHeadings.length) return;
    if (pinnedHeadingID !== null) return;

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
    // The gutter covers the card's left margin and the card itself; the gap
    // between the card and the text is the document's own left padding. The
    // class stops the column from centering, which would widen that gap.
    document.body.classList.toggle("viewer-has-gutter", width > 0);
    requestSpyUpdate();
  }

  /* Called by the native TOC when a row is clicked. */
  function scrollToAnchor(id) {
    const target = document.getElementById(id);
    if (!target) return;
    pinActiveHeading(id);
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
    // Same deal as a TOC row: the click, not the flight, says where the
    // reader is. Only headings the TOC actually lists can be pinned — an
    // anchor to some other element has no row to hold, and pinning it would
    // freeze the spy on a selection nothing shows. (The mousedown that
    // preceded this click already released any earlier pin.)
    if (tocHeadings.indexOf(target) !== -1) pinActiveHeading(target.id);
    scrollToHeading(target);
  });

  /* ---------------------------------------------------------------------
   * Git diff mode
   *
   * The renderer itself lives in diff.js (loaded before this file) and is
   * wired up here so it shares this page's message bridge and its `#content`
   * host — a diff is a third thing this one template can render, not a
   * separate page.
   *
   * A diff has no headings, so the heading index is cleared on entry: the
   * native side then swaps the side panel's contents from the table of
   * contents to the file tree, using the same card.
   * ------------------------------------------------------------------- */

  /* ---------------------------------------------------------------------
   * Image mode (T1183)
   *
   * A picture is a fourth thing this one template can render, wired up the
   * same way a diff is: the renderer is image.js (loaded before this file) and
   * it shares this page's message bridge and its `#content` host. An image has
   * no headings, so the index is cleared on entry.
   *
   * Mac renders images on a native surface instead and never calls any of
   * this, so `window.__viewerImage` is allowed to be absent: a build without
   * it renders every other mode exactly as before.
   * ------------------------------------------------------------------- */

  const image = window.__viewerImage
    ? window.__viewerImage.init({ root: content, post: post })
    : null;

  function setImage(url, name, vector) {
    if (!image) return;
    clearHeadingIndex();
    image.setImage(url, name, vector);
  }

  function setImageTransform(scale, fit) {
    if (image) image.setImageTransform(scale, fit);
  }

  function imageZoom(action) {
    if (image) image.zoom(action);
  }

  /* Called by every other mode's entry point: a document replacing a picture
   * must not leave the decoded bitmap, the wheel handler or the resize
   * listener behind. */
  function leaveImageMode() {
    if (image) image.clear();
  }

  const diff = window.__viewerDiff.init({ root: content, post: post });

  function setDiffListing(payload) {
    clearHeadingIndex();
    leaveImageMode();
    diff.setListing(payload);
  }

  function setDiffFile(payload) {
    clearHeadingIndex();
    leaveImageMode();
    diff.setFile(payload);
  }

  window.__viewer = {
    setMarkdown: setMarkdown,
    setCode: setCode,
    setError: setError,
    // Called from the native TOC panel.
    scrollToAnchor: scrollToAnchor,
    setGutter: setGutter,
    // Called from the native diff panel and toolbar.
    setDiffListing: setDiffListing,
    setDiffFile: setDiffFile,
    // Called from the native image pane (T1183); Mac never calls these.
    setImage: setImage,
    setImageTransform: setImageTransform,
    imageZoom: imageZoom,
    setDiffStyle: diff.setStyle,
    diffNav: diff.nav,
    // Reached by tests driving the parser/highlighter directly.
    diff: diff,
  };
})();
