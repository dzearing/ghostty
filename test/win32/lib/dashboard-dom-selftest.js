/**
 * dashboard-dom-selftest.js - drives the dashboard page's controls from inside
 * a real browser and writes a verdict into the DOM (T565).
 *
 * The stub server (dashboard-stub-server.js) appends one <script> tag pointing
 * here to the REAL page bytes, so nothing in scripts/task-dashboard.page.html
 * knows this file exists: a green run is evidence about the shipped page, not
 * about test code embedded in it.
 *
 * Output, read back by test/win32/dashboard-dom.ps1 via `msedge --dump-dom`:
 *   <div id="domselftest">
 *     <div>CHECK PASS C1 the shell renders</div>
 *     <div>CHECK FAIL C3 ... -- detail</div>
 *     ...
 *     <div>T565-DOM-SELFTEST PASS</div>   (or "N FAIL")
 *   </div>
 * plus the same verdict in <title>. Detail text is ASCII and carries no angle
 * brackets or ampersands, so the dumped HTML needs no unescaping.
 *
 * Every check is written so that a control that silently stops working fails
 * it: a click is asserted by the REQUEST it produced (recorded by the stub and
 * read back over /api/_posted), not only by what the DOM says afterwards.
 */
(function () {
  'use strict';

  var results = [];
  var errors = [];
  window.addEventListener('error', function (e) { errors.push(e.message || 'error'); });
  window.addEventListener('unhandledrejection', function (e) {
    errors.push('unhandled rejection: ' + ((e.reason && e.reason.message) || e.reason));
  });

  function check(name, ok, detail) {
    results.push({ name: name, ok: !!ok, detail: clean(detail) });
  }
  function clean(s) {
    return String(s == null ? '' : s).replace(/[<>&]/g, ' ').replace(/\s+/g, ' ').slice(0, 200);
  }

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  /* Polls rather than waits a fixed delay: under a virtual-time budget the
     task queue runs at its own pace, and a fixed sleep is the classic way to
     turn a working page into a flaky test. */
  function waitFor(fn, label, tries) {
    tries = tries || 100;
    return new Promise(function (resolve) {
      var n = 0;
      var t = setInterval(function () {
        var v;
        try { v = fn(); } catch (e) { v = null; }
        if (v || ++n >= tries) { clearInterval(t); resolve(v || null); }
      }, 100);
    });
  }

  function posted() {
    return fetch('/api/_posted', { cache: 'no-store' }).then(function (r) { return r.json(); });
  }
  /* "Nothing was posted" cannot be waited FOR - it can only be settled for.
     A bounded settle is the honest shape: give the click every chance to fire
     a request, then read the recorder once. */
  function postsAfter(ms) { return sleep(ms).then(posted); }

  /* Waits until the recorder has at least n posts (or gives up), so a check
     about a click never races the fetch the click started. */
  function untilPosts(n) {
    return new Promise(function (resolve) {
      var tries = 0;
      var step = function () {
        posted().then(function (p) {
          if (p.length >= n || ++tries >= 100) return resolve(p);
          setTimeout(step, 100);
        }).catch(function () {
          if (++tries >= 100) return resolve([]);
          setTimeout(step, 100);
        });
      };
      step();
    });
  }

  function byText(sel, text, root) {
    var all = (root || document).querySelectorAll(sel);
    for (var i = 0; i < all.length; i++) {
      if ((all[i].textContent || '').indexOf(text) >= 0) return all[i];
    }
    return null;
  }

  /** The card (decision or blocked task) whose .dec-id is exactly `id`. */
  function cardFor(id) {
    var all = document.querySelectorAll('.dec');
    for (var i = 0; i < all.length; i++) {
      var idEl = all[i].querySelector('.dec-id');
      if (idEl && idEl.textContent.trim() === id) return all[i];
    }
    return null;
  }

  /** The in-flight row for `id`. */
  function rowFor(id) {
    var all = document.querySelectorAll('.att-row.in_progress');
    for (var i = 0; i < all.length; i++) {
      var idEl = all[i].querySelector('.dec-id');
      if (idEl && idEl.textContent.trim() === id) return all[i];
    }
    return null;
  }

  function lastPost(p) { return p.length ? p[p.length - 1] : null; }

  /* The page ignores a click while a request is in flight (state.busy), and it
     clears that flag only after the refresh the request triggered. A test that
     clicks the next button too early sees a working control do nothing. */
  function idle() { return waitFor(function () { return !state.busy; }, 'idle'); }

  function finish() {
    var bad = results.filter(function (r) { return !r.ok; }).length;
    var verdict = 'T565-DOM-SELFTEST ' + (bad === 0 ? 'PASS' : bad + ' FAIL');
    var host = document.createElement('div');
    host.id = 'domselftest';
    results.forEach(function (r) {
      var d = document.createElement('div');
      d.textContent = 'CHECK ' + (r.ok ? 'PASS' : 'FAIL') + ' ' + r.name +
        (r.ok || !r.detail ? '' : ' -- ' + r.detail);
      host.appendChild(d);
    });
    var v = document.createElement('div');
    v.textContent = verdict;
    host.appendChild(v);
    document.body.appendChild(host);
    document.title = verdict;
  }

  /* --- the run ------------------------------------------------------------ */

  function run() {
    return waitFor(function () { return window.state && state.data; }, 'data')
      .then(function (ok) {
        check('C1 the page loads its data and renders a view', !!ok &&
          document.querySelector('#view').children.length > 0,
          'view host is empty - the page threw before rendering');
        check('C2 the shell reports no server error', !document.querySelector('#err .err'),
          document.querySelector('#err') ? document.querySelector('#err').textContent : '');
        check('C3 the nav offers every view', document.querySelectorAll('#nav button').length === 4,
          'got ' + document.querySelectorAll('#nav button').length + ' nav buttons');

        /* --- the two-step unblock (T564) --------------------------------- */
        var card = cardFor('TX901');
        var btn = card ? byText('button', 'Mark unblocked', card) : null;
        check('C4 a blocked task renders with a Mark unblocked button', !!btn,
          card ? 'card rendered but no such button' : 'no card for TX901');
        check('C5 that button is the card primary action',
          !!btn && btn.className.indexOf('primary') >= 0, btn ? btn.className : '');
        if (!btn) return;
        btn.click();
        return postsAfter(600).then(function (p) {
          check('C6 the first click ARMS instead of acting',
            p.length === 0, 'it posted ' + p.length + ' request(s) on the first click');
          check('C7 arming re-reads the block condition back at you',
            btn.textContent.indexOf('Yes') >= 0 && btn.className.indexOf('danger') >= 0,
            'button reads "' + btn.textContent + '" class "' + btn.className + '"');
          var toastEl = document.querySelector('#toast');
          check('C8 arming names what the task is blocked until',
            !!toastEl && toastEl.textContent.indexOf('flip the Windows sign-in setting') >= 0,
            toastEl ? toastEl.textContent : 'no toast');
          btn.click();
          return untilPosts(1);
        }).then(function (p) {
          var last = lastPost(p);
          check('C9 the second click puts the task back in the queue',
            !!last && last.url === '/api/status' && last.body.id === 'TX901' && last.body.status === 'todo',
            last ? last.url + ' ' + JSON.stringify(last.body) : 'nothing was posted');
        });
      })
      .then(function () {
        /* --- the armed watch gets a different control -------------------- */
        return waitFor(function () { return cardFor('TX902'); }, 'watch card').then(function (card) {
          var btn = card ? byText('button', 'Reopen anyway', card) : null;
          check('C10 an armed watch offers Reopen anyway, not Mark unblocked', !!btn,
            card ? 'card rendered but no Reopen anyway button' : 'no card for TX902');
          check('C11 that control is deliberately not the primary action',
            !!btn && btn.className.indexOf('primary') < 0, btn ? btn.className : '');
          check('C12 an armed watch is labelled as one',
            !!card && (card.textContent || '').indexOf('Armed watch') >= 0);
        });
      })
      .then(function () {
        /* --- the stale reset --------------------------------------------- */
        return idle().then(function () {
          return waitFor(function () { return rowFor('TX903'); }, 'stale row');
        }).then(function (row) {
          var btn = row ? byText('button', 'Reset to to-do', row) : null;
          check('C13 a stale in-progress task offers a reset', !!btn,
            row ? 'row rendered but no reset button' : 'no in-flight row for TX903');
          check('C14 the row says why it is offering that',
            !!row && (row.textContent || '').indexOf('abandoned') >= 0);
          if (!btn) return null;
          btn.click();
          return untilPosts(2).then(function (p) {
            var last = lastPost(p);
            check('C15 resetting a stale task posts it back to to-do',
              !!last && last.url === '/api/status' && last.body.id === 'TX903' && last.body.status === 'todo',
              last ? last.url + ' ' + JSON.stringify(last.body) : 'nothing was posted');
          });
        });
      })
      .then(function () {
        /* --- decisions ---------------------------------------------------- */
        return idle().then(function () {
          return waitFor(function () { return cardFor('DX90'); }, 'decision card');
        }).then(function (card) {
          check('C16 an open decision renders its card', !!card, 'no card for DX90');
          if (!card) return null;
          var opts = card.querySelectorAll('button.opt');
          check('C17 the decision lists its options', opts.length === 2, 'got ' + opts.length);
          check('C18 the recommended option is first and flagged',
            opts.length > 0 && opts[0].className.indexOf('recommended') >= 0,
            opts.length ? opts[0].className : '');
          var noteBtn = byText('button', 'Resolve with note', card);
          check('C19 the card offers a resolve-with-note button', !!noteBtn);
          if (!noteBtn) return null;
          // An empty note with no option picked must NOT resolve anything.
          noteBtn.click();
          return postsAfter(600).then(function (p) {
            check('C20 resolving with neither an option nor a note posts nothing',
              p.length === 2, 'post count went to ' + p.length);
            var toastEl = document.querySelector('#toast');
            check('C21 and it says what is missing',
              !!toastEl && toastEl.textContent.indexOf('Pick an option') >= 0,
              toastEl ? toastEl.textContent : 'no toast');
            opts[0].click();
            return untilPosts(3);
          }).then(function (p) {
            var last = lastPost(p);
            check('C22 picking an option resolves the decision with that answer',
              !!last && last.url === '/api/resolve' && last.body.id === 'DX90' && last.body.answer === 'fade',
              last ? last.url + ' ' + JSON.stringify(last.body) : 'nothing was posted');
          });
        });
      })
      .then(function () {
        /* --- the tasks view: filter, then open a row ---------------------- */
        go('tasks');
        return waitFor(function () {
          var b = document.querySelector('#tbody');
          return b && b.children.length ? b : null;
        }, 'task rows').then(function (body) {
          check('C23 the tasks view renders rows', !!body && body.children.length > 0);
          if (!body) return null;
          var all = body.children.length;
          var input = document.querySelector('input[type=search]');
          check('C24 the tasks view has a search box', !!input);
          if (!input) return null;
          input.value = 'TX903';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          var narrowed = document.querySelector('#tbody').children.length;
          check('C25 searching narrows the table to the match',
            narrowed === 1 && narrowed < all, 'got ' + narrowed + ' of ' + all + ' rows');
          if (narrowed !== 1) return null;
          document.querySelector('#tbody').children[0].click();
          return waitFor(function () {
            var d = document.querySelector('dialog.taskdlg');
            return d && d.open && (d.textContent || '').indexOf('Fixture task') >= 0 ? d : null;
          }, 'task dialog').then(function (dlg) {
            check('C26 clicking a row opens the task dialog with its body loaded', !!dlg,
              'no open dialog carrying the fetched body');
            if (!dlg) return null;
            dlg.close();
            return waitFor(function () { return !document.querySelector('dialog.taskdlg'); }, 'dialog gone')
              .then(function (gone) {
                check('C27 closing the dialog removes it from the DOM', !!gone,
                  'a closed dialog is still in the document');
                // Put the table back, so the later views are not filtered.
                var i2 = document.querySelector('input[type=search]');
                if (i2) { i2.value = ''; i2.dispatchEvent(new Event('input', { bubbles: true })); }
              });
          });
        });
      })
      .then(function () {
        /* --- the other two views render at all ---------------------------- */
        go('data');
        return waitFor(function () {
          return document.querySelectorAll('#view svg').length > 0;
        }, 'charts').then(function (ok) {
          check('C28 the data view draws its charts', !!ok,
            'no svg under the view host - a chart function threw');
          go('digest');
          return waitFor(function () {
            var b = document.querySelector('#view .digest-body, #view .empty');
            return b && (b.textContent || '').trim().length > 0 ? b : null;
          }, 'digest');
        }).then(function (ok) {
          check('C29 the digest view renders its body', !!ok, 'digest host is empty');
          go('activity');
          return sleep(200);
        });
      })
      .then(function () {
        check('C30 nothing threw during the whole run', errors.length === 0, errors.join(' | '));
      })
      .catch(function (e) {
        check('C99 the selftest ran to completion', false, (e && e.message) || String(e));
      })
      .then(finish);
  }

  run();
})();
