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
  }

  window.__viewer = {
    setMarkdown: setMarkdown,
    setCode: setCode,
    setError: setError,
  };
})();
