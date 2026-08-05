/* Ghoztty viewer — git diff renderer.
 *
 * Hand-rolled rather than a vendored diff library, and deliberately so: the
 * page already ships highlight.js for the code viewer, so parsing unified
 * hunks here adds ZERO bytes to the offline bundle, and it means the toolbar,
 * the native file tree, and the renderer all agree about what a "change" is
 * instead of the toolbar poking at some library's DOM from outside.
 *
 * Scale is the other reason. The native side hands over ONE file at a time
 * (the file list comes from `git --numstat`, which is cheap even for a
 * thousand files), and the rows for that file are appended in chunks across
 * frames with a hard cap — so a pane never blocks on a pathological file.
 *
 * Everything here is offline. No network, no fetch, no external stylesheet. */
"use strict";

window.__viewerDiff = (function () {
  /* Rows appended per frame, and the point past which we stop and offer a
   * button instead. Both are about the main thread: 600 rows is a few
   * milliseconds of DOM work, and 20k rows is where even chunked appending
   * starts to cost more memory than a diff is worth reading in one go. */
  const CHUNK_ROWS = 600;
  const MAX_ROWS = 20000;
  /* Beyond this, intra-line word highlighting is skipped: on a minified or
   * generated line it is neither cheap nor informative. */
  const MAX_WORD_DIFF_LENGTH = 600;
  /* Distance from the top of the pane a change is scrolled to. */
  const SCROLL_MARGIN = 16;

  function init(options) {
    const root = options.root;
    const post = options.post || function () {};

    /* Everything about what is currently on screen. */
    let state = {
      listing: null,
      file: null,
      style: "unified",
      /* The first line element of each contiguous run of +/- lines. These,
       * not the @@ hunks, are what next/previous-change steps through: a hunk
       * with three separate edits in it is three changes to a reader. */
      changes: [],
      changesBody: null,
      changesDirty: false,
      /* The change the toolbar last navigated to, or -1 when the reader is
       * driving. See `nav`. */
      changeIndex: -1,
      renderToken: 0,
      capLifted: false,
    };

    /* Any scroll the USER starts hands navigation back to where the page
     * actually is. Listening for the input events rather than for `scroll` is
     * the point — a programmatic smooth scroll is indistinguishable from a
     * user one by the time it reaches the scroll event. (The table of contents
     * releases its pinned heading the same way, for the same reason.) */
    ["wheel", "touchmove", "keydown", "mousedown"].forEach(function (type) {
      window.addEventListener(type, function () { state.changeIndex = -1; }, {
        passive: true,
        capture: true,
      });
    });

    /* ------------------------------------------------------------------ *
     * Patch parsing
     * ------------------------------------------------------------------ */

    /* Split a unified diff for ONE file into hunks of typed lines.
     *
     * The `diff --git` / `index` / `---` / `+++` preamble is dropped: the
     * native side already knows the path, the status and the counts, and it
     * renders them in the file header far better than a raw header line does. */
    function parsePatch(text) {
      const hunks = [];
      let hunk = null;
      let binary = false;
      if (!text) return { hunks: hunks, binary: false };

      const lines = text.split("\n");
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line.indexOf("Binary files ") === 0 || line.indexOf("GIT binary patch") === 0) {
          binary = true;
          continue;
        }
        if (line.indexOf("diff --git") === 0) { hunk = null; continue; }
        if (/^(index |old mode |new mode |new file mode |deleted file mode |similarity index |dissimilarity index |rename from |rename to |copy from |copy to |--- |\+\+\+ )/.test(line)) {
          continue;
        }
        /* `@@ -a,b +c,d @@ trailing` — the trailing part is the enclosing
         * function git guessed, which is genuinely useful context. */
        const at = /^@@+ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@+(.*)$/.exec(line);
        if (at) {
          hunk = {
            oldLine: parseInt(at[1], 10),
            newLine: parseInt(at[3], 10),
            context: at[5].trim(),
            lines: [],
          };
          hunks.push(hunk);
          continue;
        }
        if (!hunk) continue;

        const marker = line.charAt(0);
        if (marker === "+") {
          hunk.lines.push({ type: "add", text: line.slice(1) });
        } else if (marker === "-") {
          hunk.lines.push({ type: "del", text: line.slice(1) });
        } else if (marker === " ") {
          hunk.lines.push({ type: "ctx", text: line.slice(1) });
        } else if (marker === "\\") {
          /* "\ No newline at end of file" belongs to the line above it. */
          hunk.lines.push({ type: "note", text: line.slice(1).trim() });
        } else if (line === "" && i === lines.length - 1) {
          /* Trailing newline from the process output. */
        }
      }
      return { hunks: hunks, binary: binary };
    }

    /* ------------------------------------------------------------------ *
     * Syntax highlighting
     *
     * Highlighting each line on its own gets multi-line constructs wrong — a
     * block comment or a template literal restarts on every row. So each hunk
     * is highlighted as TWO contiguous texts (the old side and the new side),
     * which is exactly what those constructs need, and the result is split
     * back into lines afterwards.
     * ------------------------------------------------------------------ */

    function canHighlight(language) {
      return !!(language && window.hljs && window.hljs.getLanguage(language));
    }

    function highlightLines(texts, language) {
      if (!texts.length) return [];
      if (!canHighlight(language)) return texts.map(escapeHTML);
      let html;
      try {
        html = window.hljs.highlight(texts.join("\n"), {
          language: language,
          ignoreIllegals: true,
        }).value;
      } catch (e) {
        return texts.map(escapeHTML);
      }
      const split = splitHighlighted(html);
      /* A highlighter that loses or gains a line would misalign the whole
       * hunk; fall back rather than render the wrong code next to the wrong
       * line number. */
      return split.length === texts.length ? split : texts.map(escapeHTML);
    }

    /* Split highlighted HTML at newlines, carrying open tags across the break.
     *
     * highlight.js emits spans that freely straddle newlines, so a naive
     * `split("\n")` produces rows with unbalanced markup — which the browser
     * then "fixes" by re-nesting the rest of the file inside one span. Closing
     * the open tags at each break and reopening them on the next row is the
     * standard fix, and it is why this is 20 lines rather than one. */
    function splitHighlighted(html) {
      const out = [];
      const open = [];
      let current = "";
      const token = /(<[^>]+>)|(\n)|([^<\n]+)/g;
      let match;
      while ((match = token.exec(html)) !== null) {
        if (match[1]) {
          const tag = match[1];
          if (tag.charAt(1) === "/") {
            open.pop();
          } else if (tag.charAt(tag.length - 2) !== "/") {
            open.push(tag);
          }
          current += tag;
        } else if (match[2]) {
          out.push(current + closers(open.length));
          current = open.join("");
        } else {
          current += match[3];
        }
      }
      out.push(current + closers(open.length));
      return out;
    }

    function closers(n) {
      let s = "";
      for (let i = 0; i < n; i++) s += "</span>";
      return s;
    }

    function escapeHTML(text) {
      return text
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
    }

    /* ------------------------------------------------------------------ *
     * Intra-line word diff
     *
     * When one character on a long line changed, a whole-line red/green pair
     * says "this line is different" and nothing else. Marking the differing
     * span is what turns that back into information.
     *
     * Deliberately a common prefix/suffix rather than a real word-level LCS:
     * it is exact for the edits people actually make (rename a symbol, change
     * an argument, fix a string), costs nothing, and — when it would mark
     * essentially the whole line — is suppressed rather than made noise.
     * ------------------------------------------------------------------ */

    function wordRange(oldText, newText) {
      if (!oldText.length || !newText.length) return null;
      if (oldText.length > MAX_WORD_DIFF_LENGTH ||
          newText.length > MAX_WORD_DIFF_LENGTH) return null;

      let start = 0;
      const max = Math.min(oldText.length, newText.length);
      while (start < max && oldText.charAt(start) === newText.charAt(start)) start++;
      let end = 0;
      while (
        end < max - start &&
        oldText.charAt(oldText.length - 1 - end) === newText.charAt(newText.length - 1 - end)
      ) end++;

      const oldSpan = oldText.length - end - start;
      const newSpan = newText.length - end - start;
      /* Nothing in common worth pointing at: if the shared prefix and suffix
       * are shorter than the changed middle on both sides, the two lines are
       * simply different lines. */
      const shared = start + end;
      if (shared < 3) return null;
      if (shared <= Math.min(oldSpan, newSpan)) return null;
      return { start: start, oldEnd: oldText.length - end, newEnd: newText.length - end };
    }

    /* Wrap the visible characters in [start, end) of already-highlighted HTML
     * in `<span class="d-word">`, without breaking the highlighter's nesting.
     *
     * The span is opened and closed INSIDE each text run rather than around
     * the range as a whole: a range that starts inside one hljs span and ends
     * inside another cannot be wrapped by a single element without producing
     * mis-nested markup that the parser silently rewrites. */
    function markRange(html, start, end) {
      if (end <= start) return html;
      let out = "";
      let visible = 0;
      let marking = false;
      const token = /(<[^>]+>)|(&[a-zA-Z#0-9]+;)|([^<&]+)/g;
      let match;
      while ((match = token.exec(html)) !== null) {
        if (match[1]) {
          if (marking) { out += "</span>"; marking = false; }
          out += match[1];
          continue;
        }
        if (match[2]) {
          const inRange = visible >= start && visible < end;
          if (inRange && !marking) { out += '<span class="d-word">'; marking = true; }
          if (!inRange && marking) { out += "</span>"; marking = false; }
          out += match[2];
          visible += 1;
          continue;
        }
        const text = match[3];
        for (let i = 0; i < text.length; i++) {
          const inRange = visible >= start && visible < end;
          if (inRange && !marking) { out += '<span class="d-word">'; marking = true; }
          if (!inRange && marking) { out += "</span>"; marking = false; }
          out += text.charAt(i);
          visible += 1;
        }
      }
      if (marking) out += "</span>";
      return out;
    }

    /* ------------------------------------------------------------------ *
     * Row building
     *
     * A "row" is a plain object; turning rows into DOM happens later and in
     * chunks, so the expensive part (highlighting) is done once up front and
     * the frame-by-frame part is cheap.
     * ------------------------------------------------------------------ */

    function buildRows(parsed, language) {
      const rows = [];
      for (let h = 0; h < parsed.hunks.length; h++) {
        const hunk = parsed.hunks[h];
        rows.push({ kind: "hunk", text: hunkLabel(hunk) });

        const oldTexts = [];
        const newTexts = [];
        for (let i = 0; i < hunk.lines.length; i++) {
          const line = hunk.lines[i];
          if (line.type === "ctx") { oldTexts.push(line.text); newTexts.push(line.text); }
          else if (line.type === "del") oldTexts.push(line.text);
          else if (line.type === "add") newTexts.push(line.text);
        }
        const oldHTML = highlightLines(oldTexts, language);
        const newHTML = highlightLines(newTexts, language);

        let oldIndex = 0;
        let newIndex = 0;
        let oldNumber = hunk.oldLine;
        let newNumber = hunk.newLine;
        const built = [];
        for (let i = 0; i < hunk.lines.length; i++) {
          const line = hunk.lines[i];
          if (line.type === "note") {
            built.push({ kind: "note", text: line.text });
            continue;
          }
          if (line.type === "ctx") {
            built.push({
              kind: "line", type: "ctx", text: line.text,
              html: oldHTML[oldIndex], oldNumber: oldNumber, newNumber: newNumber,
            });
            oldIndex++; newIndex++; oldNumber++; newNumber++;
          } else if (line.type === "del") {
            built.push({
              kind: "line", type: "del", text: line.text,
              html: oldHTML[oldIndex], oldNumber: oldNumber, newNumber: null,
            });
            oldIndex++; oldNumber++;
          } else {
            built.push({
              kind: "line", type: "add", text: line.text,
              html: newHTML[newIndex], oldNumber: null, newNumber: newNumber,
            });
            newIndex++; newNumber++;
          }
        }
        applyWordDiff(built);
        for (let i = 0; i < built.length; i++) rows.push(built[i]);
      }
      return rows;
    }

    function hunkLabel(hunk) {
      const range = "@@ " + hunk.oldLine + " → " + hunk.newLine;
      return hunk.context ? range + "   " + hunk.context : range;
    }

    /* Pair the removals and additions of each change block and mark what
     * actually differs. Only equal-sized blocks are paired: an unequal block
     * is a rewrite, and pairing line 1 with line 1 there would invent a
     * relationship that isn't in the diff. */
    function applyWordDiff(rows) {
      let i = 0;
      while (i < rows.length) {
        if (rows[i].kind !== "line" || rows[i].type !== "del") { i++; continue; }
        let delEnd = i;
        while (delEnd < rows.length && rows[delEnd].kind === "line" &&
               rows[delEnd].type === "del") delEnd++;
        let addEnd = delEnd;
        while (addEnd < rows.length && rows[addEnd].kind === "line" &&
               rows[addEnd].type === "add") addEnd++;

        const dels = delEnd - i;
        const adds = addEnd - delEnd;
        if (dels > 0 && dels === adds) {
          for (let k = 0; k < dels; k++) {
            const before = rows[i + k];
            const after = rows[delEnd + k];
            const range = wordRange(before.text, after.text);
            if (!range) continue;
            before.html = markRange(before.html, range.start, range.oldEnd);
            after.html = markRange(after.html, range.start, range.newEnd);
          }
        }
        i = addEnd > delEnd ? addEnd : delEnd;
      }
    }

    /* ------------------------------------------------------------------ *
     * Rendering
     * ------------------------------------------------------------------ */

    function setListing(payload) {
      state.listing = payload || {};
      if (payload && payload.style) state.style = payload.style;
      renderShell();
    }

    function setStyle(style) {
      if (style !== "unified" && style !== "split") return;
      if (state.style === style) return;
      state.style = style;
      /* Keep the reader roughly where they were: the same change is at a
       * different pixel offset in the other layout, so anchor on the change
       * nearest the top of the pane rather than on scrollY. */
      const anchor = state.changeIndex >= 0 ? state.changeIndex : nearestChangeIndex();
      renderShell();
      if (anchor >= 0) {
        state.changeIndex = anchor;
        requestAnimationFrame(function () { scrollToChange(anchor); });
      }
    }

    function setFile(payload) {
      const samePath = state.file && payload && state.file.path === payload.path;
      const keepScroll = samePath && !payload.scrollTo ? window.scrollY : null;
      state.file = payload || null;
      state.capLifted = false;
      renderShell();
      if (keepScroll !== null) {
        requestAnimationFrame(function () { window.scrollTo(0, keepScroll); });
      }
    }

    /* Build the whole document: summary, file header, body. */
    function renderShell() {
      state.renderToken += 1;
      const token = state.renderToken;
      state.changes = [];
      state.changesBody = null;
      state.changesDirty = false;
      state.changeIndex = -1;

      root.className = "viewer-diff-root";
      root.replaceChildren();

      const listing = state.listing || {};
      root.appendChild(summaryElement(listing));

      if (listing.message) {
        root.appendChild(noticeElement(listing.message, listing.detail));
        return;
      }
      const file = state.file;
      if (!file) {
        root.appendChild(noticeElement(
          "Select a file",
          "Pick a file from the list to see its diff."));
        return;
      }

      const card = document.createElement("section");
      card.className = "d-file";
      card.appendChild(fileHeaderElement(file));

      const body = document.createElement("div");
      body.className = "d-body " + (state.style === "split" ? "d-split" : "d-unified");
      card.appendChild(body);
      root.appendChild(card);

      if (file.binary) {
        body.appendChild(stubElement("Binary file", "Not shown."));
        return;
      }
      const parsed = parsePatch(file.patch);
      if (parsed.binary) {
        body.appendChild(stubElement("Binary file", "Not shown."));
        return;
      }
      if (!parsed.hunks.length) {
        body.appendChild(stubElement(
          "No textual changes",
          "git reported this file as changed but produced no diff — a mode, "
            + "rename, or whitespace-only change."));
        return;
      }

      const rows = buildRows(parsed, file.language);
      appendRows(body, rows, 0, token, file);
    }

    /* Append rows a chunk at a time so a huge file never blocks the frame. */
    function appendRows(body, rows, start, token, file) {
      if (token !== state.renderToken) return;
      const limit = state.capLifted ? rows.length : Math.min(rows.length, MAX_ROWS);
      const target = Math.min(start + CHUNK_ROWS, limit);
      const fragment = document.createDocumentFragment();

      let next;
      if (state.style === "split") {
        next = appendSplitRows(fragment, rows, start, target);
      } else {
        for (let i = start; i < target; i++) fragment.appendChild(rowElement(rows[i]));
        next = target;
      }
      body.appendChild(fragment);
      /* Re-indexed lazily rather than here: re-scanning the whole body after
       * every chunk is quadratic in the file's length, and nothing needs the
       * index until a navigation asks for it. */
      state.changesBody = body;
      state.changesDirty = true;

      if (next < limit) {
        requestAnimationFrame(function () {
          appendRows(body, rows, next, token, file);
        });
        return;
      }
      if (limit < rows.length) {
        body.appendChild(capElement(rows.length - limit, function () {
          state.capLifted = true;
          renderShell();
        }));
      }
    }

    /* ---- unified ---- */

    function rowElement(row) {
      if (row.kind === "hunk") {
        const el = document.createElement("div");
        el.className = "d-line d-hunk";
        el.appendChild(gutter("", ""));
        const code = document.createElement("code");
        code.className = "d-code";
        code.textContent = row.text;
        el.appendChild(code);
        return el;
      }
      if (row.kind === "note") {
        const el = document.createElement("div");
        el.className = "d-line d-note";
        el.appendChild(gutter("", ""));
        const code = document.createElement("code");
        code.className = "d-code";
        code.textContent = "\\ " + row.text;
        el.appendChild(code);
        return el;
      }
      const el = document.createElement("div");
      el.className = "d-line d-" + row.type;
      el.appendChild(gutter(
        row.oldNumber === null ? "" : String(row.oldNumber),
        row.newNumber === null ? "" : String(row.newNumber)));
      const mark = document.createElement("span");
      mark.className = "d-mark";
      mark.textContent = row.type === "add" ? "+" : (row.type === "del" ? "-" : " ");
      el.appendChild(mark);
      const code = document.createElement("code");
      code.className = "d-code";
      code.innerHTML = row.html;
      el.appendChild(code);
      return el;
    }

    function gutter(oldNumber, newNumber) {
      const wrap = document.createElement("span");
      wrap.className = "d-gutter";
      const a = document.createElement("span");
      a.className = "d-num";
      a.textContent = oldNumber;
      const b = document.createElement("span");
      b.className = "d-num";
      b.textContent = newNumber;
      wrap.appendChild(a);
      wrap.appendChild(b);
      return wrap;
    }

    /* ---- side by side ----
     *
     * A four-column CSS grid, so the left and right halves of a pair are the
     * same grid ROW and therefore always line up — including when a long line
     * wraps, which is the case a two-column flex layout gets wrong. */

    /* Returns the index it actually consumed up to, which may run PAST
     * `target`: a change block is paired as a unit, and splitting one across
     * two chunks would pair its first half against nothing and its second half
     * against nothing — a visible misalignment every 600 rows. */
    function appendSplitRows(fragment, rows, start, target) {
      let i = start;
      while (i < target) {
        const row = rows[i];
        if (row.kind === "hunk" || row.kind === "note") {
          const label = row.kind === "hunk" ? row.text : "\\ " + row.text;
          fragment.appendChild(splitBanner(label, row.kind));
          i++;
          continue;
        }
        if (row.type === "ctx") {
          fragment.appendChild(splitCells(row, row));
          i++;
          continue;
        }
        /* A change block: removals on the left, additions on the right, paired
         * up so a modified line reads across rather than down. */
        let delEnd = i;
        while (delEnd < rows.length && rows[delEnd].kind === "line" &&
               rows[delEnd].type === "del") delEnd++;
        let addEnd = delEnd;
        while (addEnd < rows.length && rows[addEnd].kind === "line" &&
               rows[addEnd].type === "add") addEnd++;
        const pairs = Math.max(delEnd - i, addEnd - delEnd);
        for (let k = 0; k < pairs; k++) {
          const left = i + k < delEnd ? rows[i + k] : null;
          const right = delEnd + k < addEnd ? rows[delEnd + k] : null;
          fragment.appendChild(splitCells(left, right));
        }
        i = addEnd > i ? addEnd : i + 1;
      }
      return i;
    }

    function splitCells(left, right) {
      const el = document.createElement("div");
      el.className = "d-pair";
      el.appendChild(splitSide(left, "old"));
      el.appendChild(splitSide(right, "new"));
      if ((left && left.type === "del") || (right && right.type === "add")) {
        el.classList.add("d-changed");
      }
      return el;
    }

    function splitSide(row, side) {
      const cell = document.createElement("div");
      cell.className = "d-half d-half-" + side;
      if (!row) {
        /* The other side of an unpaired add/delete. It still needs both cells
         * so the grid row keeps its two columns. */
        cell.classList.add("d-empty");
        const blankNumber = document.createElement("span");
        blankNumber.className = "d-num";
        cell.appendChild(blankNumber);
        const filler = document.createElement("code");
        filler.className = "d-code";
        cell.appendChild(filler);
        return cell;
      }
      cell.classList.add("d-" + row.type);
      const number = document.createElement("span");
      number.className = "d-num";
      const value = side === "old" ? row.oldNumber : row.newNumber;
      number.textContent = value === null || value === undefined ? "" : String(value);
      cell.appendChild(number);
      const code = document.createElement("code");
      code.className = "d-code";
      code.innerHTML = row.html;
      cell.appendChild(code);
      return cell;
    }

    function splitBanner(text, kind) {
      const el = document.createElement("div");
      el.className = "d-pair d-banner " + (kind === "hunk" ? "d-hunk" : "d-note");
      const code = document.createElement("code");
      code.className = "d-code";
      code.textContent = text;
      el.appendChild(code);
      return el;
    }

    /* ---- chrome ---- */

    function summaryElement(listing) {
      const el = document.createElement("header");
      el.className = "d-summary";
      const title = document.createElement("h1");
      title.textContent = listing.title || "Diff";
      el.appendChild(title);

      const meta = document.createElement("p");
      meta.className = "d-summary-meta";
      const bits = [];
      if (listing.subtitle) bits.push(listing.subtitle);
      if (listing.fileCount) {
        bits.push(listing.fileCount + (listing.fileCount === 1 ? " file" : " files"));
      }
      meta.textContent = bits.join(" · ");
      if (listing.additions || listing.deletions) {
        const add = document.createElement("span");
        add.className = "d-count-add";
        add.textContent = " +" + (listing.additions || 0);
        const del = document.createElement("span");
        del.className = "d-count-del";
        del.textContent = " −" + (listing.deletions || 0);
        meta.appendChild(add);
        meta.appendChild(del);
      }
      el.appendChild(meta);
      return el;
    }

    function fileHeaderElement(file) {
      const el = document.createElement("div");
      el.className = "d-file-header";

      const badge = document.createElement("span");
      badge.className = "d-status d-status-" + (file.status || "unknown");
      badge.textContent = file.statusLetter || "?";
      el.appendChild(badge);

      el.appendChild(pathElement(file.oldPath ? file.oldPath + " → " : "", file.path));

      if (file.section) {
        const section = document.createElement("span");
        section.className = "d-section";
        section.textContent = file.section;
        el.appendChild(section);
      }

      const counts = document.createElement("span");
      counts.className = "d-file-counts";
      if (file.binary) {
        counts.textContent = "binary";
      } else {
        const add = document.createElement("span");
        add.className = "d-count-add";
        add.textContent = "+" + (file.additions || 0);
        const del = document.createElement("span");
        del.className = "d-count-del";
        del.textContent = "−" + (file.deletions || 0);
        counts.appendChild(add);
        counts.appendChild(del);
      }
      el.appendChild(counts);
      return el;
    }

    /* The path, split so the DIRECTORY ellipsizes and the FILENAME never does.
     * A single truncating element loses the filename — the one part of a path
     * you always need — the moment the header is too narrow. */
    function pathElement(prefix, path) {
      const cut = path.lastIndexOf("/");
      const wrap = document.createElement("span");
      wrap.className = "d-path";
      const dir = document.createElement("span");
      dir.className = "d-dir";
      dir.textContent = prefix + (cut >= 0 ? path.slice(0, cut + 1) : "");
      const name = document.createElement("span");
      name.className = "d-name";
      name.textContent = cut >= 0 ? path.slice(cut + 1) : path;
      wrap.appendChild(dir);
      wrap.appendChild(name);
      wrap.title = prefix + path;
      return wrap;
    }

    function noticeElement(title, detail) {
      const el = document.createElement("div");
      el.className = "d-notice";
      const h = document.createElement("h2");
      h.textContent = title;
      el.appendChild(h);
      if (detail) {
        const p = document.createElement("p");
        p.textContent = detail;
        el.appendChild(p);
      }
      return el;
    }

    function stubElement(title, detail) {
      const el = document.createElement("div");
      el.className = "d-stub";
      const strong = document.createElement("strong");
      strong.textContent = title;
      el.appendChild(strong);
      const span = document.createElement("span");
      span.textContent = " " + detail;
      el.appendChild(span);
      return el;
    }

    function capElement(remaining, onClick) {
      const el = document.createElement("div");
      el.className = "d-stub d-cap";
      const strong = document.createElement("strong");
      strong.textContent = remaining.toLocaleString() + " more lines not shown.";
      el.appendChild(strong);
      const button = document.createElement("button");
      button.type = "button";
      button.className = "d-cap-button";
      button.textContent = "Show the rest";
      button.addEventListener("click", onClick);
      el.appendChild(button);
      return el;
    }

    /* ------------------------------------------------------------------ *
     * Change navigation
     * ------------------------------------------------------------------ */

    /* The first element of each contiguous run of changed lines — a "change"
     * as a reader means it, rather than a `@@` hunk, which can hold several.
     * Rebuilt on demand (see the `changesDirty` flag) so a file still
     * streaming in is navigable without re-scanning the body every frame. */
    function indexChanges() {
      state.changesDirty = false;
      const body = state.changesBody;
      if (!body) { state.changes = []; return; }
      const selector = state.style === "split"
        ? ".d-pair.d-changed"
        : ".d-line.d-add, .d-line.d-del";
      const all = body.querySelectorAll(selector);
      const changes = [];
      let previous = null;
      for (let i = 0; i < all.length; i++) {
        const element = all[i];
        if (!previous || previous.nextElementSibling !== element) changes.push(element);
        previous = element;
      }
      state.changes = changes;
    }

    function offsets() {
      if (state.changesDirty) indexChanges();
      const tops = [];
      for (let i = 0; i < state.changes.length; i++) {
        tops.push(state.changes[i].getBoundingClientRect().top + window.scrollY);
      }
      return tops;
    }

    function nearestChangeIndex() {
      const tops = offsets();
      if (!tops.length) return -1;
      const y = window.scrollY + SCROLL_MARGIN;
      let best = 0;
      for (let i = 0; i < tops.length; i++) {
        if (tops[i] <= y + 1) best = i; else break;
      }
      return best;
    }

    function scrollToChange(index) {
      const tops = offsets();
      if (!tops.length) return;
      const clamped = Math.max(0, Math.min(index, tops.length - 1));
      window.scrollTo({
        top: Math.max(0, tops[clamped] - SCROLL_MARGIN),
        behavior: prefersReducedMotion() ? "auto" : "smooth",
      });
    }

    function prefersReducedMotion() {
      return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    }

    /* Step to the next/previous change, or tell the native side we ran out —
     * it then moves to the adjacent FILE, which is what "next change" means
     * across a diff of many files.
     *
     * Stepping from a remembered INDEX rather than from `window.scrollY` is
     * what makes a fast double-press work: the scroll it starts is smooth, so
     * for the next few hundred milliseconds the page is still sitting at the
     * previous change and a scroll-derived answer would pick that same one
     * again. The index is released the moment the reader scrolls themselves
     * (see the listener above), so it never gets out of step with the page. */
    function nav(direction) {
      const tops = offsets();
      if (!tops.length) {
        post({ type: "diffNavOverflow", direction: direction });
        return;
      }
      const from = state.changeIndex >= 0
        ? state.changeIndex
        : scrollDerivedIndex(tops, direction);
      const target = from + (direction > 0 ? 1 : -1);
      if (target < 0 || target >= tops.length) {
        post({ type: "diffNavOverflow", direction: direction });
        return;
      }
      state.changeIndex = target;
      scrollToChange(target);
    }

    /* Where the reader is, when they got there by scrolling. Biased by
     * direction so the change straddling the top of the pane is treated as
     * "the one you are on" going either way. */
    function scrollDerivedIndex(tops, direction) {
      const y = window.scrollY + SCROLL_MARGIN;
      if (direction > 0) {
        let last = -1;
        for (let i = 0; i < tops.length; i++) {
          if (tops[i] <= y + 2) last = i; else break;
        }
        return last;
      }
      for (let i = tops.length - 1; i >= 0; i--) {
        if (tops[i] < y - 2) return i + 1;
      }
      return 0;
    }

    /* Entering a file from a navigation lands on its first or last change,
     * so walking a diff forwards or backwards reads continuously instead of
     * jumping to each file's top. */
    function applyEntryScroll(where) {
      if (where === "first") {
        state.changeIndex = 0;
        scrollToChange(0);
      } else if (where === "last") {
        const last = Math.max(0, offsets().length - 1);
        state.changeIndex = last;
        scrollToChange(last);
      } else {
        state.changeIndex = -1;
        window.scrollTo(0, 0);
      }
    }

    return {
      setListing: setListing,
      setFile: function (payload) {
        setFile(payload);
        applyEntryScroll(payload && payload.scrollTo);
      },
      setStyle: setStyle,
      nav: nav,
      /* Exposed for tests, which drive the parser and the highlighter split
       * directly rather than through a rendered pane. */
      _parsePatch: parsePatch,
      _splitHighlighted: splitHighlighted,
      _wordRange: wordRange,
      _markRange: markRange,
      _changeCount: function () {
        if (state.changesDirty) indexChanges();
        return state.changes.length;
      },
      _changeIndex: function () { return state.changeIndex; },
    };
  }

  return { init: init };
})();
