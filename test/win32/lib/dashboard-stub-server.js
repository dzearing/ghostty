#!/usr/bin/env node
/**
 * dashboard-stub-server.js - the fixture host for the dashboard's DOM
 * acceptance test (T565).
 *
 * The real server (scripts/task-dashboard.js) is already covered end to end by
 * test/win32/task-dashboard.ps1. What was NOT covered is the PAGE: 74k of
 * inline JS whose buttons only a human clicking them could prove still work.
 * Driving those buttons against the real server is not an option - the two-step
 * unblock and the stale reset POST to /api/status, which rewrites real task
 * files - and the real payload has no guaranteed blocked task, armed watch,
 * stale in-progress row or open decision to click in the first place.
 *
 * So this serves:
 *   GET  /                 the REAL page bytes, with one <script> appended that
 *                          loads the selftest driver. The page itself is never
 *                          edited, so a green run cannot be an artifact of test
 *                          code living inside the subject.
 *   GET  /selftest-dom.js  the driver (test/win32/lib/dashboard-dom-selftest.js)
 *   GET  /api/data         a payload captured from the real builder
 *                          (`node scripts/task-dashboard.js --once`), with the
 *                          four stateful shapes injected so they always render
 *   GET  /api/task?id=     a markdown body, so the task dialog can finish loading
 *   GET  /api/commit?sha=  a commit message, so the event dialog can finish loading
 *   POST /api/status       recorded, answered {ok:true} - NOTHING is written
 *   POST /api/resolve      likewise
 *   GET  /api/_posted      the recorded POSTs, so the harness can assert that a
 *                          click produced a real request rather than only DOM text
 *
 * Usage:
 *   node dashboard-stub-server.js --page <html> --driver <js> --data <json>
 *                                 --port <n> [--break two-step]
 *
 * `--break two-step` is the negative control: it disarms the two-step guard in
 * the served page so the first click posts immediately. A harness that stays
 * green through that is not measuring anything.
 *
 * No dependencies, no repo writes, loopback only.
 */
'use strict';

const fs = require('fs');
const http = require('http');

function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const PAGE = arg('page');
const DRIVER = arg('driver');
const DATA = arg('data');
const PORT = Number(arg('port', '0'));
const BREAK = arg('break', '');

if (!PAGE || !DRIVER || !DATA || !Number.isInteger(PORT) || PORT < 1) {
  console.error('usage: dashboard-stub-server.js --page <html> --driver <js> --data <json> --port <n> [--break two-step]');
  process.exit(2);
}

/* --- the fixture ---------------------------------------------------------- */

const payload = JSON.parse(fs.readFileSync(DATA, 'utf8'));

/* A real task object is the template for the synthetic ones, so the fixture
   cannot drift from the payload's actual shape: every field the page reads is
   present because the builder put it there, and only the handful this test is
   about are overridden. */
const template = (payload.tasks && payload.tasks[0]) || {};
function fixtureTask(over) {
  return Object.assign({}, template, {
    order: null, deps: [], commits: [], tags: ['test'], seat: 'win',
    priority: 'P1', milestone: null, triageReason: null,
    plain: null, goals: [], progress: [], summary: 'Fixture task for the DOM harness.',
    completedAt: null, ready: false, stale: false, staleMs: null,
    blockedOn: null, unblock: null, unblockDo: null, unblockCommand: null,
    reason: null, createdAt: Date.now() - 6 * 864e5, modifiedAt: Date.now() - 3 * 864e5,
    statusSince: Date.now() - 3 * 864e5, touchedAt: Date.now() - 3 * 864e5
  }, over);
}

const DAY = 864e5;
const BLOCKED = fixtureTask({
  id: 'TX901', title: 'Fixture: a blocked task that names a chore',
  status: 'blocked(the sign-in setting is not flipped)', bucket: 'blocked',
  blockedOn: 'chore', reason: 'the sign-in setting is not flipped',
  unblock: 'flip the Windows sign-in setting, then mark this to-do',
  file: 'docs/design/windows-parity-tasks/TX901.md'
});
const WATCHING = fixtureTask({
  id: 'TX902', title: 'Fixture: a task parked on an event that has not happened',
  status: 'blocked(waiting for the crash to recur)', bucket: 'blocked',
  blockedOn: 'event', reason: 'waiting for the crash to recur',
  unblock: 'a new occurrence of the freeze appears in the watchdog log',
  file: 'docs/design/windows-parity-tasks/TX902.md'
});
const STALE = fixtureTask({
  id: 'TX903', title: 'Fixture: an in-progress task nobody has touched in days',
  status: 'in-progress', bucket: 'in_progress',
  stale: true, staleMs: 4 * DAY, touchedAt: Date.now() - 4 * DAY,
  statusSince: Date.now() - 4 * DAY,
  plain: 'A turn claimed this and died before it finished.',
  file: 'docs/design/windows-parity-tasks/TX903.md'
});

const DECISION = {
  id: 'DX90', status: 'open', kind: 'decision', task: 'TX901',
  title: 'Fixture: which way should the pane announce itself?',
  why: 'The Mac build fades the banner; Windows has no such convention.',
  assumed: 'Kept the Mac fade, so work continued.',
  options: [
    { key: 'fade', label: 'Fade it out like Mac (Recommended)', detail: '',
      pros: ['matches the Mac build'], cons: ['unusual on Windows'], mitigation: ['ship it behind the same setting'] },
    { key: 'snap', label: 'Snap it away instantly', detail: '',
      pros: ['feels native'], cons: ['diverges from Mac'], mitigation: [] }
  ]
};

/* Only the synthetic ones are left in the shapes this harness clicks, so every
   assertion below can name exactly one card. Everything else in the payload -
   the timeline, the charts, the task table - stays real. */
payload.tasks = (payload.tasks || [])
  .filter((t) => t.bucket !== 'blocked' && t.bucket !== 'in_progress')
  .concat([BLOCKED, WATCHING, STALE]);
payload.decisions = [DECISION];
payload.openDecisions = 1;

const dataJson = JSON.stringify(payload);

/* --- the page ------------------------------------------------------------- */

let pageHtml = fs.readFileSync(PAGE, 'utf8');
if (BREAK === 'two-step') {
  const before = pageHtml;
  pageHtml = pageHtml.replace('if (!armed && t.unblock) {', 'if (false) {');
  if (pageHtml === before) {
    console.error('negative control could not find the two-step guard to break');
    process.exit(3);
  }
}
pageHtml = pageHtml.replace('</body>', '<script src="/selftest-dom.js"></script>\n</body>');

/* --- what the page posted ------------------------------------------------- */

const posted = [];

function send(res, code, type, body) {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    let buf = '';
    req.on('data', (c) => { buf += c; });
    req.on('end', () => resolve(buf));
  });
}

const server = http.createServer(async (req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (req.method === 'POST') {
    const raw = await readBody(req);
    let body = null;
    try { body = JSON.parse(raw); } catch (e) { body = { parseError: String(e.message) }; }
    posted.push({ url, body, at: Date.now() });
    return send(res, 200, 'application/json', JSON.stringify({ ok: true }));
  }
  if (url === '/' || url === '/index.html') return send(res, 200, 'text/html; charset=utf-8', pageHtml);
  if (url === '/selftest-dom.js') {
    return send(res, 200, 'text/javascript; charset=utf-8', fs.readFileSync(DRIVER, 'utf8'));
  }
  if (url === '/api/data') return send(res, 200, 'application/json', dataJson);
  if (url === '/api/_posted') return send(res, 200, 'application/json', JSON.stringify(posted));
  if (url === '/api/task') {
    return send(res, 200, 'application/json', JSON.stringify({
      body: '# Fixture task\n\n## Summary\n\nThe stub answers every task with this body.\n'
    }));
  }
  if (url === '/api/commit') {
    return send(res, 200, 'application/json', JSON.stringify({
      message: 'fixture commit\n\nThe stub answers every sha with this message.\n'
    }));
  }
  send(res, 404, 'text/plain', 'not found');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('stub listening on ' + PORT);
});
