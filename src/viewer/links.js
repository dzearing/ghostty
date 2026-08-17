/* Ghoztty's own right-click menu for links in viewer panes.
 *
 * Injected as a WKUserScript into EVERY page a viewer shows — the bundled
 * markdown/code/diff template AND arbitrary websites — for the same reason
 * selection.js is: viewer.js is a <script src> inside viewer.html and so only
 * ever runs on the template, which would leave a website's links with WebKit's
 * menu and the template's with ours.
 *
 * All this file does is decide whether a right-click landed on a link Ghoztty
 * has actions for, suppress WebKit's menu when it did, and report the href.
 * The menu itself is native (BannerLinkOpener.menu(for:)) — one menu, one
 * modifier scheme, one place the ordering contract lives.
 *
 * It runs in SUBFRAMES too (unlike selection.js, which is main-frame only
 * because its toolbar positions itself in viewport coordinates). The native
 * menu pops up at the POINTER, so an iframe's own coordinate space is
 * irrelevant and a link inside one behaves like any other.
 *
 * Whenever this script declines a click, WebKit's own context menu appears
 * exactly as it does today — that is the fallback for every case below.
 */
(function () {
  "use strict";

  if (window.__ghozttyLinks) return;
  window.__ghozttyLinks = true;

  /* Schemes the native menu has actions for. Everything else keeps WebKit's
   * menu, which is better than ours for it: `mailto:` gets the mail items,
   * `javascript:` is page machinery with no destination at all, and handing an
   * arbitrary scheme to NSWorkspace would resolve it to whatever handler
   * happens to be registered. */
  const SCHEMES = [
    "http:",
    "https:",
    "file:",
    "ghoztty:",
    "ghoztty-debug:",
    "ghoztty-viewer:",
  ];

  function handler() {
    return window.webkit
      && window.webkit.messageHandlers
      && window.webkit.messageHandlers.viewerTOC;
  }

  /* A link into this same document — `#section` in a rendered markdown doc, or
   * a bare `#`. It names a place on the page, not content to open somewhere, so
   * there is nothing for the Ghoztty menu to offer. */
  function sameDocument(url) {
    return url.hash !== ""
      && url.origin === location.origin
      && url.pathname === location.pathname
      && url.search === location.search;
  }

  /* Whether the click landed inside the user's current selection. A
   * right-click on selected text must keep WebKit's Copy / Look Up / Search
   * menu even when the selection happens to contain a link. */
  function insideSelection(node) {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return false;
    try {
      return selection.containsNode(node, true);
    } catch (e) {
      return false;
    }
  }

  document.addEventListener("contextmenu", function (event) {
    const target = event.target;
    if (!target || !target.closest) return;
    const anchor = target.closest("a[href]");
    if (!anchor) return;

    // `.href` is the DOM's own absolute resolution of the attribute, so a
    // relative link arrives already resolved against the page's base.
    const href = anchor.href;
    if (!href) return;
    let url;
    try {
      url = new URL(href);
    } catch (e) {
      return;
    }
    if (SCHEMES.indexOf(url.protocol) < 0) return;
    if (sameDocument(url)) return;
    if (insideSelection(anchor)) return;

    const bridge = handler();
    // Only suppress WebKit's menu once we know we can replace it — a
    // right-click that opens nothing at all reads as a broken page.
    if (!bridge) return;
    event.preventDefault();
    try {
      bridge.postMessage({ type: "linkMenu", href: href });
    } catch (e) { /* handler torn down mid-flight */ }
  }, true);
})();
