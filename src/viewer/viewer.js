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
      updateActiveEntry();
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
    buildTableOfContents();
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
    // Text/code files have no heading structure: no TOC chrome at all.
    clearTableOfContents();
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
    clearTableOfContents();
  }

  /* ---------------------------------------------------------------------
   * Table of contents
   *
   * Built in-page from the rendered markdown: the gutter layout reflows the
   * markdown column with plain CSS, and scroll-spy / anchor jumps stay a
   * couple of DOM reads. Gutter-vs-panel is decided by media queries on the
   * pane width (see viewer.css), so a split-divider drag reflows it live
   * with no resize plumbing here.
   * ------------------------------------------------------------------- */

  const toc = document.getElementById("toc");
  const tocList = document.getElementById("toc-list");
  const tocToggle = document.getElementById("toc-toggle");
  /* Headings in document order and their matching TOC links (same indexes). */
  let tocHeadings = [];
  let tocLinks = [];
  let activeLink = null;

  /* Distance below the top of the pane at which a heading counts as "the
   * section you are reading" for scroll-spy. */
  const SPY_MARKER = 88;

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

  function clearTableOfContents() {
    tocList.replaceChildren();
    tocHeadings = [];
    tocLinks = [];
    activeLink = null;
    document.body.classList.remove("viewer-has-toc", "viewer-toc-open");
    setTogglePressed(false);
  }

  function buildTableOfContents() {
    const wasOpen = document.body.classList.contains("viewer-toc-open");
    tocList.replaceChildren();
    tocHeadings = [];
    tocLinks = [];
    activeLink = null;

    const headings = Array.prototype.filter.call(
      content.querySelectorAll("h1, h2, h3, h4, h5, h6"),
      function (h) { return h.textContent.trim() !== ""; });

    // One heading is a title, not a table of contents: show no chrome.
    if (headings.length < 2) {
      clearTableOfContents();
      return;
    }

    const used = new Set();
    let topLevel = 6;
    for (const h of headings) {
      topLevel = Math.min(topLevel, Number(h.tagName.slice(1)));
    }

    for (const heading of headings) {
      const text = heading.textContent.trim();
      if (heading.id) {
        used.add(heading.id);
      } else {
        heading.id = slugify(text, used);
      }

      // Depth is relative to the document's own top level (a file whose
      // headings start at h2 shouldn't be indented a step) and capped so a
      // deeply nested section still fits the card.
      const depth = Math.min(3, Number(heading.tagName.slice(1)) - topLevel);

      const item = document.createElement("li");
      const link = document.createElement("a");
      link.href = "#" + heading.id;
      link.title = text;
      link.style.setProperty("--depth", String(depth));
      const label = document.createElement("span");
      label.className = "viewer-toc-label";
      label.textContent = text;
      link.appendChild(label);
      link.addEventListener("click", function (event) {
        // Never let this become a real navigation: in a file viewer the
        // native side treats link activations as "open that location", and a
        // fragment on the template page's URL is not a location.
        event.preventDefault();
        scrollToHeading(heading);
        closePanel();
      });
      item.appendChild(link);
      tocList.appendChild(item);
      tocHeadings.push(heading);
      tocLinks.push(link);
    }

    document.body.classList.add("viewer-has-toc");
    // A live reload keeps the panel as the user left it.
    if (wasOpen) {
      document.body.classList.add("viewer-toc-open");
      setTogglePressed(true);
    }
    updateActiveEntry();
  }

  function scrollToHeading(heading) {
    const top = heading.getBoundingClientRect().top + window.scrollY - 12;
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    window.scrollTo({
      top: Math.max(0, top),
      behavior: reduceMotion ? "auto" : "smooth",
    });
  }

  /* Highlight the entry for the section currently at the top of the pane. */
  function updateActiveEntry() {
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

    const link = tocLinks[index];
    if (link === activeLink) return;
    if (activeLink) activeLink.classList.remove("is-active");
    activeLink = link;
    link.classList.add("is-active");
    revealInList(link);
  }

  /* Keep the active entry inside a long, independently scrolled TOC.
   * Scrolling the list directly (rather than scrollIntoView) so the page
   * itself is never scrolled as a side effect. */
  function revealInList(link) {
    const listBox = tocList.getBoundingClientRect();
    const linkBox = link.getBoundingClientRect();
    if (linkBox.top < listBox.top) {
      tocList.scrollTop -= listBox.top - linkBox.top + 8;
    } else if (linkBox.bottom > listBox.bottom) {
      tocList.scrollTop += linkBox.bottom - listBox.bottom + 8;
    }
  }

  let spyQueued = false;
  function requestSpyUpdate() {
    if (spyQueued) return;
    spyQueued = true;
    requestAnimationFrame(function () {
      spyQueued = false;
      updateActiveEntry();
    });
  }

  window.addEventListener("scroll", requestSpyUpdate, { passive: true });
  window.addEventListener("resize", requestSpyUpdate);

  function setTogglePressed(open) {
    tocToggle.setAttribute("aria-expanded", open ? "true" : "false");
  }

  function closePanel() {
    document.body.classList.remove("viewer-toc-open");
    setTogglePressed(false);
  }

  tocToggle.addEventListener("click", function (event) {
    event.stopPropagation();
    const open = document.body.classList.toggle("viewer-toc-open");
    setTogglePressed(open);
  });

  // Clicking the content (or pressing Escape) dismisses the slide-over panel.
  document.addEventListener("click", function (event) {
    if (!document.body.classList.contains("viewer-toc-open")) return;
    if (toc.contains(event.target) || tocToggle.contains(event.target)) return;
    closePanel();
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closePanel();
  });

  // The panel is only a narrow-pane affordance; widening the pane into gutter
  // layout leaves no stale open state behind for the next time it narrows.
  const gutterQuery = window.matchMedia("(min-width: 720px)");
  gutterQuery.addEventListener("change", function (event) {
    if (event.matches) closePanel();
    requestSpyUpdate();
  });

  // In-document links written by the author ("[jump](#section)") now have
  // real targets, and need the same treatment as TOC links: scroll in page
  // instead of escaping to the native link router.
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

  window.__viewer = {
    setMarkdown: setMarkdown,
    setCode: setCode,
    setError: setError,
  };
})();
