/* Ghoztty viewer page runtime. The native side (ViewerView) injects content
 * via the window.__viewer API below; everything renders offline from the
 * bundled vendor libraries. */
"use strict";

(function () {
  const md = window.markdownit({
    html: false,
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
    content.innerHTML = md.render(source);
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
