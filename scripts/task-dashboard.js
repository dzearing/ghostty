#!/usr/bin/env node
'use strict';
/**
 * Windows-parity task dashboard: data layer + tiny localhost server.
 *
 *   node scripts/task-dashboard.js            # serve on http://localhost:7788
 *   node scripts/task-dashboard.js --port 9000
 *   node scripts/task-dashboard.js --once     # print the JSON payload and exit
 *
 * WHY A SERVER AND NOT A .html FILE. A Ghoztty viewer pane renders `.md`
 * through markdown-it and treats every other extension as CODE — see
 * `viewer_content.modeFor()`. So `--view=temp/dashboard.html` would show the
 * HTML *source*, syntax-highlighted, not the page. `http://` locations are the
 * only ones the pane actually browses, so the dashboard is served.
 *
 * The payload is rebuilt from disk on EVERY request, so the page stays current
 * with no file watcher: the page polls `/api/data` and re-renders in place
 * (holding the previous render rather than flashing a skeleton). Edit a task
 * file, and the pane reflects it within the poll interval.
 *
 * History comes from git. Each commit that touched the tasks directory is one
 * `git grep '^status:' <sha>` (~60ms), so the first build of the 250-odd
 * commits takes a few seconds; results are cached in
 * `temp/task-dashboard-history.json` and later runs only process new commits.
 * The cache is invalidated wholesale if the recorded commits are no longer a
 * prefix of `git log` (a rebase), because a partially-rewritten history is
 * worse than a slow rebuild.
 */

const fs = require('fs');
const path = require('path');
const http = require('http');
const { execFileSync } = require('child_process');

const REPO = path.resolve(__dirname, '..');
const REL_TASK_DIR = 'docs/design/windows-parity-tasks';
const REL_DECISION_DIR = 'docs/design/windows-parity-decisions';
const REL_DIGEST_DIR = 'docs/design/windows-parity-digests';
const REL_INDEX = 'docs/design/windows-parity-tasks.md';
// Same escape hatch the PowerShell scripts carry (-TaskDir / -DecisionDir, and
// GHOSTTY_HOST_DEFAULTS before them): point a run at fixtures so the write
// paths can be exercised without filing junk into the real tracker.
const TASK_DIR = process.env.GHOZTTY_TASK_DIR || path.join(REPO, ...REL_TASK_DIR.split('/'));
const DECISION_DIR = process.env.GHOZTTY_DECISION_DIR || path.join(REPO, ...REL_DECISION_DIR.split('/'));
const DIGEST_DIR = process.env.GHOZTTY_DIGEST_DIR || path.join(REPO, ...REL_DIGEST_DIR.split('/'));
const PAGE = path.join(__dirname, 'task-dashboard.page.html');
const CACHE = path.join(REPO, 'temp', 'task-dashboard-history.json');

// Bump when a cached point gains or changes a field, so an old cache is
// rebuilt instead of silently feeding half-populated activity items.
const CACHE_VERSION = 3;

// A gap longer than this between tracker commits is idle time, not work. The
// loop stalled for six days once; reporting that as a six-day "duration" would
// be worse than reporting nothing.
const MAX_PLAUSIBLE_TURN_MS = 6 * 3600 * 1000;

// ---------------------------------------------------------------------------
// Frontmatter
// ---------------------------------------------------------------------------

/** Split `---\n…\n---\n` off the front of a task file. */
function parseFrontmatter(text) {
  if (!text.startsWith('---')) return null;
  const end = text.indexOf('\n---', 3);
  if (end < 0) return null;
  const fields = {};
  for (const line of text.slice(3, end).split(/\r?\n/)) {
    const m = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (m) fields[m[1]] = parseValue(m[2]);
  }
  return { fields, bodyStart: end + 4 };
}

/**
 * Frontmatter values are written by `parity-tasks.ps1` via ConvertTo-Json, so
 * they are JSON scalars/arrays — and PowerShell's ConvertTo-Json emits `>`
 * for a `>` inside a status string ("skipped(split -> T394…)").
 * JSON.parse is therefore the parser, not a regex.
 */
function parseValue(raw) {
  const s = raw.trim();
  if (s === '' || s === 'null') return null;
  try {
    return JSON.parse(s);
  } catch {
    return s.replace(/^"|"$/g, '');
  }
}

/**
 * The bucket a status string falls in. Statuses carry a parenthetical reason
 * (`blocked(GameInputSvc wedge…)`, `skipped(split -> T394…)`), so the bucket is
 * the head before `(` — the reason is kept for display but never for counting.
 */
function bucketOf(status) {
  const head = String(status == null ? '' : status).split('(')[0].trim().toLowerCase();
  if (head === 'done') return 'done';
  if (head === 'in-progress' || head === 'in progress') return 'in_progress';
  if (head === 'blocked') return 'blocked';
  if (head === 'skipped') return 'skipped';
  return 'todo';
}

/** The reason inside `blocked(…)` / `skipped(…)`, or null. */
function statusReason(status) {
  const m = /^[^(]*\((.*)\)\s*$/.exec(String(status == null ? '' : status));
  return m ? m[1] : null;
}

/**
 * What a blocked task is waiting on: a PERSON (`user`) or an EVENT nobody can
 * perform on demand (`event`).
 *
 * The board used to file both under one "Blocked — needs you" heading with a
 * "Mark unblocked" button on every card. For an armed watch — T443, whose
 * condition is "a crash recurs" — that button is a trap: pressing it is the
 * only offered action, it cannot possibly satisfy the condition, and the next
 * loop turn re-parks the task per D27. The user pressed it on 2026-08-16 09:26
 * and again on 2026-08-17 06:04; both times the task was blocked again within
 * ~10 minutes and reappeared on the board, which reads as the board being
 * broken. Splitting the two kinds is what stops the ping-pong: an event card
 * asks for nothing, so there is nothing to press by mistake.
 *
 * Explicit `blocked-on:` wins; otherwise the reason/unblock prose is sniffed,
 * and anything unrecognised stays `user` — a task that genuinely needs a chore
 * must never be demoted into the passive list by a missed keyword.
 */
function blockedOnOf(F, status, unblock) {
  const explicit = String(F['blocked-on'] == null ? '' : F['blocked-on']).trim().toLowerCase();
  if (explicit === 'user' || explicit === 'event') return explicit;
  const text = `${statusReason(status) || ''} ${unblock || ''}`;
  return /armed watch|new occurrence|next occurrence|another occurrence|recurrence|until it recurs/i.test(text)
    ? 'event'
    : 'user';
}

/** First paragraph under `## Summary`, flattened to one line. */
function extractSummary(body) {
  const m = /^##\s+Summary\s*$/m.exec(body);
  if (!m) return '';
  const rest = body.slice(m.index + m[0].length);
  const stop = rest.search(/^\s*#{2,}\s/m);
  const block = (stop < 0 ? rest : rest.slice(0, stop)).trim();
  const para = block.split(/\n\s*\n/)[0] || '';
  return stripMarkdown(para);
}

/** T01 < T89b < T89f1 < T90b < T111a < T428 — number first, then suffix. */
function idOrder(id) {
  const m = /^[A-Za-z]*(\d+)(.*)$/.exec(id || '');
  return m ? [Number(m[1]), m[2]] : [Number.MAX_SAFE_INTEGER, id || ''];
}
function byId(a, b) {
  const [an, as] = idOrder(a.id);
  const [bn, bs] = idOrder(b.id);
  return an - bn || as.localeCompare(bs);
}

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

function loadTasks() {
  const tasks = [];
  for (const f of fs.readdirSync(TASK_DIR)) {
    if (!f.endsWith('.md') || f === 'README.md') continue;
    const full = path.join(TASK_DIR, f);
    let text;
    try {
      text = fs.readFileSync(full, 'utf8');
    } catch {
      continue;
    }
    const fm = parseFrontmatter(text);
    if (!fm) continue;
    const F = fm.fields;
    const status = F.status == null ? 'todo' : String(F.status);
    tasks.push({
      id: String(F.id || path.basename(f, '.md')),
      title: String(F.title || ''),
      // `seat:` is optional and defaults to win — parity-tasks.ps1 says so.
      seat: F.seat == null ? 'win' : String(F.seat),
      // The work queue's sort key. Fractional on purpose so a task can be
      // injected between two others without renumbering. Absent sorts last.
      order: Number.isFinite(Number(F.order)) && F.order !== null && F.order !== '' ? Number(F.order) : null,
      deps: Array.isArray(F.deps) ? F.deps.map(String) : [],
      commits: Array.isArray(F.commits) ? F.commits.map(String) : [],
      status,
      bucket: bucketOf(status),
      reason: statusReason(status),
      // How a human gets this unblocked. Free text, plus an optional command
      // to copy. A blocked task with no `unblock:` is a dead end on a board,
      // which is the complaint this field exists to answer.
      unblock: F.unblock == null ? null : String(F.unblock),
      unblockCommand: F['unblock-command'] == null ? null : String(F['unblock-command']),
      // The command that does the actual WORK, as opposed to `unblock-command:`
      // which only flips the status afterwards. Offering solely the status flip
      // is how a card ends up inviting the one click that cannot help: T857's
      // real blocker is two elevated `powercfg` lines, and the board showed
      // only `set-status … -Status todo`, so pressing the button re-parked the
      // task instead of advancing it. When present this is the primary action.
      unblockDo: F['unblock-do'] == null ? null : String(F['unblock-do']),
      blockedOn: bucketOf(status) === 'blocked' ? blockedOnOf(F, status, F.unblock) : null,
      // Triage rank (P0 severe / P1 feature+polish / P2 infra / P3 reviewed and
      // deliberately last) and the one-line reason for it. Absent means
      // untriaged, which sorts AFTER every band — a task nobody ranked should
      // not outrank one somebody deliberately called P2, nor one somebody
      // deliberately parked at P3 (T345).
      priority: /^P[0123]$/.test(String(F.priority || '')) ? String(F.priority) : null,
      triageReason: F['triage-reason'] == null ? null : String(F['triage-reason']),
      // Milestone membership (the convergence cutline, 2026-08-06): the
      // completion number the user watches is measured against a milestone's
      // deliberate membership, never the ever-growing all-time backlog — a
      // percentage whose denominator grows with every report cannot converge.
      // Absent = outside every milestone; the daily triage promotes tasks in.
      milestone: F.milestone == null ? null : String(F.milestone),
      summary: extractSummary(text.slice(fm.bodyStart)),
      // Written by the loop when it claims a task (go.md step 1). Task titles
      // are defect sentences aimed at whoever will fix them — "the notice
      // never survives the ConPTY repaint" tells a watching human nothing.
      // These two sections are the readable version.
      plain: extractSection(text.slice(fm.bodyStart), 'In plain terms'),
      goals: parseGoals(extractSection(text.slice(fm.bodyStart), 'Goals')),
      // Category tags from the closed vocabulary (parity-tasks.ps1 $ValidTags).
      // Optional — the pre-tag tracker has none — and shown on activity cards
      // and the detail view so user-facing work reads apart from internal.
      tags: Array.isArray(F.tags) ? F.tags.map(String) : [],
      // The task's `## Progress log`: timestamped journal lines the loop
      // appends as it works (go.md step 1), which is what makes a task whose
      // turn died resumable. Last few only — the full log is in /api/task.
      progress: parseProgress(extractSection(text.slice(fm.bodyStart), 'Progress log')),
      // Validation criteria checklist — same shape as goals.
      validation: parseGoals(extractSection(text.slice(fm.bodyStart), 'Validation criteria')),
      file: REL_TASK_DIR + '/' + f,
    });
  }
  return tasks.sort(byId);
}

/**
 * Decisions the loop made that a human might want to overturn. Written by
 * scripts/parity-decisions.ps1; the loop never blocks on one.
 */
function loadDecisions() {
  let files = [];
  try {
    files = fs.readdirSync(DECISION_DIR).filter((f) => /^D\d+\.md$/.test(f));
  } catch {
    return [];
  }
  const out = [];
  for (const f of files) {
    let text;
    try {
      text = fs.readFileSync(path.join(DECISION_DIR, f), 'utf8');
    } catch {
      continue;
    }
    const fm = parseFrontmatter(text);
    if (!fm) continue;
    const F = fm.fields;
    out.push({
      id: String(F.id || path.basename(f, '.md')),
      title: String(F.title || ''),
      task: F.task ? String(F.task) : null,
      kind: String(F.kind || 'assumption'),
      status: String(F.status || 'open'),
      created: F.created ? Date.parse(F.created) : null,
      assumed: F.assumed ? String(F.assumed) : null,
      answer: F.answer ? String(F.answer) : null,
      answeredAt: F.answeredAt ? Date.parse(F.answeredAt) : null,
      note: F.note ? String(F.note) : null,
      options: parseOptions(text.slice(0, fm.bodyStart)),
      why: extractSection(text.slice(fm.bodyStart), 'Why this needs a call'),
      file: REL_DECISION_DIR + '/' + f,
    });
  }
  return out.sort(byId);
}

/**
 * The `options:` block is a nested YAML list, which the flat key:value
 * frontmatter parser above deliberately does not handle — so it gets its own
 * tiny reader rather than a general YAML dependency.
 */
function parseOptions(fmText) {
  const out = [];
  let inOpts = false;
  let list = null; // which of pros/cons/mitigation the current "- item" lines belong to
  for (const line of fmText.split(/\r?\n/)) {
    if (/^options:\s*\[\s*\]\s*$/.test(line)) return [];
    if (/^options:\s*$/.test(line)) { inOpts = true; continue; }
    if (!inOpts) continue;
    if (/^[A-Za-z]/.test(line)) break; // next top-level key
    let m = /^\s*-\s*key:\s*(.+)$/.exec(line);
    if (m) { out.push({ key: m[1].trim(), label: '', detail: '', pros: [], cons: [], mitigation: [] }); list = null; continue; }
    m = /^\s+label:\s*(.+)$/.exec(line);
    if (m && out.length) { out[out.length - 1].label = parseValue(m[1]) || ''; list = null; continue; }
    m = /^\s+detail:\s*(.+)$/.exec(line);
    if (m && out.length) { out[out.length - 1].detail = parseValue(m[1]) || ''; list = null; continue; }
    m = /^\s+(pros|cons|mitigation):\s*$/.exec(line);
    if (m && out.length) { list = m[1]; continue; }
    m = /^\s+-\s+(.+)$/.exec(line);
    if (m && out.length && list) { out[out.length - 1][list].push(String(parseValue(m[1]) || '')); }
  }
  return out;
}

/**
 * Daily digests: one markdown file per day (YYYY-MM-DD.md), written by the
 * loop's 5am step (go.md, "Daily digest") or the tracker-startup catch-up.
 * The list is every date newest-first; only the NEWEST body ships in the poll
 * payload — older ones are a /api/digest fetch away, because the page shows
 * one at a time and yesterday's prose in every poll would be dead weight.
 */
function digestDates() {
  let files = [];
  try {
    files = fs.readdirSync(DIGEST_DIR).filter((f) => /^\d{4}-\d{2}-\d{2}\.md$/.test(f));
  } catch {
    return [];
  }
  return files.map((f) => f.slice(0, -3)).sort().reverse();
}

function readDigest(date) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  let text;
  try {
    text = fs.readFileSync(path.join(DIGEST_DIR, date + '.md'), 'utf8');
  } catch {
    return null;
  }
  const fm = parseFrontmatter(text);
  return { date, body: (fm ? text.slice(fm.bodyStart) : text).trim() };
}

/**
 * `## Progress log` entries -> [{ts, text}], newest LAST (file order is
 * chronological). Lines look like `- 2026-08-05 09:12 [session abc]: text`;
 * the timestamp and session stamp are both optional so a hand-written line
 * still shows up rather than vanishing. Only the last few ship in the poll
 * payload — the cards show recent steps, the dialog fetches the whole file.
 */
function parseProgress(section) {
  const out = [];
  for (const line of String(section || '').split(/\r?\n/)) {
    const m = /^\s*-\s*(?:(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s*)?(?:\[session ([^\]]+)\]\s*)?:?\s*(.+?)\s*$/.exec(line);
    if (m && m[3]) out.push({ ts: m[1] ? Date.parse(m[1]) || null : null, session: m[2] || null, text: stripMarkdown(m[3]) });
  }
  return out.slice(-6);
}

/** A markdown checklist -> [{done, text}]. Anything else in the section is ignored. */
function parseGoals(section) {
  const out = [];
  for (const line of String(section || '').split(/\r?\n/)) {
    const m = /^\s*[-*]\s*\[([ xX])\]\s*(.+?)\s*$/.exec(line);
    if (m) out.push({ done: m[1] !== ' ', text: stripMarkdown(m[2]) });
  }
  return out;
}

/**
 * Flatten inline markdown to plain text. The page renders with textContent, so
 * `**bold**` would otherwise show its asterisks.
 */
function stripMarkdown(s) {
  return String(s || '')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/(^|\W)[*_]([^*_]+)[*_](?=\W|$)/g, '$1$2')
    .replace(/\s+/g, ' ')
    .trim();
}

function extractSection(body, heading) {
  const re = new RegExp('^#{2,3}\\s+' + heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*$', 'm');
  const m = re.exec(body);
  if (!m) return '';
  const rest = body.slice(m.index + m[0].length);
  const stop = rest.search(/^\s*#{2,3}\s/m);
  return (stop < 0 ? rest : rest.slice(0, stop)).trim();
}

const OPEN_BUCKETS = new Set(['todo', 'in_progress', 'blocked']);

function tally(buckets) {
  const c = { done: 0, todo: 0, in_progress: 0, blocked: 0, skipped: 0 };
  for (const b of buckets) if (b in c) c[b]++;
  c.open = c.todo + c.in_progress + c.blocked;
  // Skipped tasks were split into successors; they are not scope, so `total`
  // deliberately excludes them or the completion rate would never reach 100%.
  c.total = c.done + c.open;
  return c;
}

/**
 * A todo task is READY when every dependency is settled. `skipped` counts as
 * settled: a skipped task was split into successors, so waiting on it is
 * waiting on nothing. An unknown dep id counts as settled too, and is reported
 * separately rather than silently parking the task forever.
 */
function annotateReadiness(tasks) {
  const byIdMap = new Map(tasks.map((t) => [t.id.toLowerCase(), t]));
  for (const t of tasks) {
    const waiting = [];
    const missing = [];
    for (const d of t.deps) {
      const dep = byIdMap.get(String(d).toLowerCase());
      if (!dep) {
        missing.push(d);
        continue;
      }
      if (dep.bucket !== 'done' && dep.bucket !== 'skipped') waiting.push(d);
    }
    t.waitingOn = waiting;
    t.missingDeps = missing;
    t.ready = t.bucket === 'todo' && waiting.length === 0;
  }
}

// ---------------------------------------------------------------------------
// History (git)
// ---------------------------------------------------------------------------

function git(args) {
  return execFileSync('git', ['-C', REPO, ...args], {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
  });
}

/**
 * Every commit that touched EITHER tracker format, oldest first.
 *
 * The tracker was a single markdown state table until 2026-07-29, when it was
 * split one-file-per-task. Reading only the directory would start the history
 * at the split and throw away the project's first two and a half weeks — so
 * both are read and the timeline spans both formats.
 */
function commitList() {
  const seen = new Map();
  // Unit separator between fields, record separator between commits — a commit
  // body is multi-line prose, so newline cannot be the record delimiter.
  const FMT = '--format=%H\x1f%at\x1f%s\x1f%b\x1e';
  for (const p of [REL_TASK_DIR, REL_INDEX]) {
    let out = '';
    try {
      out = git(['log', FMT, '--', p]);
    } catch {
      continue;
    }
    for (const rec of out.split('\x1e')) {
      const r = rec.replace(/^\s+/, '');
      if (!r) continue;
      const [sha, ts, subject, body] = r.split('\x1f');
      if (!sha || seen.has(sha)) continue;
      seen.set(sha, {
        sha,
        ts: Number(ts) * 1000,
        subject: (subject || '').trim(),
        body: (body || '').trim(),
      });
    }
  }
  return [...seen.values()].sort((a, b) => a.ts - b.ts);
}

/**
 * id -> bucket at `sha`, from whichever tracker format existed then. The
 * per-file directory wins when it has any content; the old table is the
 * fallback for pre-split commits.
 */
function statusesAt(sha) {
  const dir = statusesFromDir(sha);
  return dir.size ? dir : statusesFromIndex(sha);
}

function statusesFromDir(sha) {
  let out = '';
  try {
    out = git(['grep', '--no-color', '-e', '^status:', sha, '--', REL_TASK_DIR]);
  } catch {
    return new Map(); // git grep exits 1 with no matches
  }
  const map = new Map();
  for (const line of out.split('\n')) {
    if (!line) continue;
    // <sha>:<path>:status: "…"
    const i = line.indexOf(':');
    const j = line.indexOf(':', i + 1);
    if (j < 0) continue;
    const file = line.slice(i + 1, j);
    if (!file.endsWith('.md')) continue;
    const value = line.slice(j + 1).replace(/^status:\s*/, '');
    map.set(path.basename(file, '.md'), bucketOf(parseValue(value)));
  }
  return map;
}

/**
 * Parse the pre-split state table: `| ID | Task | Phase | Deps | Status |
 * Commits |`.
 *
 * The status cell is found by scanning the row from the RIGHT for the first
 * cell whose head is a bucket word, not by column index. Task titles contain
 * both pipes and the word "done" ("Verify keybinds on box — done 2026-07-18
 * via …"), so a fixed index picks up the wrong cell on exactly the rows that
 * matter, and scanning left-to-right finds the title's "done" first.
 */
function statusesFromIndex(sha) {
  let text = '';
  try {
    text = git(['show', sha + ':' + REL_INDEX]);
  } catch {
    return new Map();
  }
  const map = new Map();
  for (const line of text.split(/\r?\n/)) {
    if (!line.startsWith('|')) continue;
    const cells = line.split('|').map((s) => s.trim());
    const id = cells[1];
    if (!/^T\d+[a-z0-9]*$/i.test(id || '')) continue; // skips header + rule rows
    for (let k = cells.length - 1; k >= 2; k--) {
      if (/^(done|todo|in-progress|in progress|blocked|skipped)\b/i.test(cells[k])) {
        map.set(id, bucketOf(cells[k]));
        break;
      }
    }
  }
  return map;
}

function readCache() {
  try {
    const c = JSON.parse(fs.readFileSync(CACHE, 'utf8'));
    if (c.version === CACHE_VERSION && Array.isArray(c.points) && c.last && typeof c.last === 'object') {
      if (!c.since || typeof c.since !== 'object') c.since = {};
      return c;
    }
  } catch {}
  return { version: CACHE_VERSION, points: [], last: {}, since: {} };
}

function writeCache(cache) {
  try {
    fs.mkdirSync(path.dirname(CACHE), { recursive: true });
    fs.writeFileSync(CACHE, JSON.stringify(cache), 'utf8');
  } catch (e) {
    warn('could not write history cache: ' + e.message);
  }
}

/**
 * One point per commit that touched the tasks directory, plus the per-task
 * completion timestamps derived from the transitions between them.
 */
function buildHistory() {
  const commits = commitList();
  let cache = readCache();

  // A rebase makes cached points meaningless. Require them to still be a
  // prefix of the log; otherwise start over.
  const stale = cache.points.some((p, i) => !commits[i] || commits[i].sha !== p.sha);
  if (stale) cache = { version: CACHE_VERSION, points: [], last: {}, since: {} };

  let prev = new Map(Object.entries(cache.last));
  // When each task's CURRENT bucket began (commit timestamp of the last
  // transition) — what "blocked for 3d" / "in flight 2h" is measured from.
  const since = { ...cache.since };
  let added = 0;
  const todo = commits.length - cache.points.length;
  if (todo > 20) warn('building history from ' + todo + ' commits (cached after this run)…');

  for (let i = cache.points.length; i < commits.length; i++) {
    const c = commits[i];
    const cur = statusesAt(c.sha);
    if (cur.size === 0) continue; // a commit from before either tracker existed
    // The FIRST point is a baseline, not a day's work. Whatever was already
    // done when the tracker appeared was completed before it, so counting it
    // as newlyDone would invent a spike on day one and make "completed in the
    // last 7 days" mean "every task ever finished".
    const baseline = cache.points.length === 0 && prev.size === 0;
    const newlyDone = [];
    const filed = [];
    if (!baseline) {
      for (const [id, b] of cur) {
        if (b === 'done' && prev.get(id) !== 'done') newlyDone.push(id);
        if (!prev.has(id)) filed.push(id);
      }
    }
    for (const [id, b] of cur) {
      if (prev.get(id) !== b) since[id] = c.ts;
    }
    cache.points.push({
      sha: c.sha, ts: c.ts, subject: c.subject, body: c.body,
      ...tally(cur.values()), newlyDone, filed,
    });
    prev = cur;
    added++;
  }
  if (added) {
    cache.last = Object.fromEntries(prev);
    cache.since = since;
    writeCache(cache);
  }
  cache.since = since;
  return cache;
}

// ---------------------------------------------------------------------------
// Payload
// ---------------------------------------------------------------------------

/**
 * The activity feed: one item per commit that finished or filed work.
 *
 * The commit message IS the summary of how the app changed — this repo writes
 * narrative subjects ("T421: the app comes back if it dies during the agent
 * refresh"), so there is nothing better to synthesise from.
 *
 * `duration` is the gap since the previous tracker commit, which is the turn
 * that produced this one (go.md runs one task per context). It is reported as
 * null past MAX_PLAUSIBLE_TURN_MS: across an overnight or a stall that gap is
 * idle time, and labelling it "duration" would be a confident lie.
 */
function buildActivity(points, taskById, decisions) {
  const items = [];
  const name = (id) => (taskById.get(id) ? taskById.get(id).title : '');

  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    const done = (p.newlyDone || []).filter((id) => taskById.has(id));
    const filed = (p.filed || []).filter((id) => taskById.has(id));
    if (!done.length && !filed.length) continue;
    const gap = i > 0 ? p.ts - points[i - 1].ts : null;
    // The card's tags are the union of its completed tasks' tags (falling
    // back to filed-task tags for a filing-only commit) — so a reader can
    // tell a user-facing landing from a test-only one without opening it.
    const tagSet = new Set();
    for (const id of done.length ? done : filed) {
      for (const tg of (taskById.get(id) || {}).tags || []) tagSet.add(tg);
    }
    items.push({
      kind: 'work',
      ts: p.ts,
      sha: p.sha.slice(0, 9),
      title: done.length ? done.map((id) => id + ' — ' + name(id)).join(' · ') : p.subject,
      subject: p.subject,
      // First paragraph of the body: the "what actually changed" prose,
      // without the trailing trailers and evidence dumps.
      summary: (p.body || '').split(/\n\s*\n/)[0].replace(/\s+/g, ' ').trim(),
      completed: done.map((id) => ({ id, title: name(id) })),
      filed: filed.map((id) => ({ id, title: name(id) })),
      tags: [...tagSet],
      durationMs: gap != null && gap > 0 && gap <= MAX_PLAUSIBLE_TURN_MS ? gap : null,
    });
  }

  for (const d of decisions) {
    if (d.created) {
      items.push({
        kind: 'decision-opened', ts: d.created, title: d.title,
        decision: d.id, task: d.task, summary: d.assumed ? 'Assumed meanwhile: ' + d.assumed : '',
        completed: [], filed: [], durationMs: null,
      });
    }
    if (d.status === 'resolved' && d.answeredAt) {
      const opt = d.options.filter((o) => o.key === d.answer)[0];
      items.push({
        kind: 'decision-resolved', ts: d.answeredAt, title: d.title,
        decision: d.id, task: d.task,
        summary: 'Resolved: ' + ((opt && opt.label) || d.note || '—'),
        completed: [], filed: [], durationMs: null,
      });
    }
  }

  return items.sort((a, b) => b.ts - a.ts);
}

function branchName() {
  try {
    return git(['rev-parse', '--abbrev-ref', 'HEAD']).trim();
  } catch {
    return '';
  }
}

/**
 * What the go-loop is doing right now, from its lock file.
 *
 * The lock records the pane, the turn number and a heartbeat, but NOT which
 * task is being worked — so "in flight" has to come from tasks marked
 * in-progress (go.md step 1). The heartbeat is what separates "a task is
 * marked in-progress because work is happening" from "someone left it that
 * way in July": the watchdog treats ~45 min of silence as dead, so this does
 * too.
 */
function loopState() {
  let raw;
  try {
    raw = fs.readFileSync(path.join(REPO, 'temp', 'go-loop.lock.json'), 'utf8');
  } catch {
    return null;
  }
  let j;
  try {
    j = JSON.parse(raw.replace(/^﻿/, '')); // PowerShell writes a BOM
  } catch {
    return null;
  }
  if (!j || j.state === 'free') return null;
  const beat = j.heartbeat ? Date.parse(j.heartbeat) : null;
  const age = beat ? Date.now() - beat : null;
  return {
    paneId: j.pane_id || null,
    claudePid: j.claude_pid || null,
    turn: j.turn == null ? null : j.turn,
    acquired: j.acquired ? Date.parse(j.acquired) : null,
    heartbeat: beat,
    heartbeatAgeMs: age,
    // LIVENESS IS THE PROCESS, NOT THE HEARTBEAT. The lock is only refreshed
    // at task boundaries (go.md step 6), so a genuinely long turn goes quiet
    // for an hour while working perfectly — reading that as "not responding"
    // cried wolf on a loop that was 46 minutes into a task. The heartbeat
    // still matters, but as "last checkpoint", not as a pulse.
    running: pidAlive(j.claude_pid) || paneHoldsClaude(j),
    // Kept for the watchdog's own framing: past this it WILL re-enter.
    checkpointStale: age != null && age >= 45 * 60 * 1000,
  };
}

/**
 * Second opinion for `running`, for the window where the lock names a corpse
 * (T440). The upgrade script kills claude and relaunches it in the SAME pane,
 * and nothing re-points the lock until that session reaches go.md step 0 — a
 * whole turn later, unbounded if the resume failed. This card read "Not
 * running" through all of it while work was happening, which is the complaint
 * that filed T440.
 *
 * The rule lives in scripts\go-loop-lock.ps1 (`status` → `owner_alive_by`) and
 * is asked for rather than reimplemented, so the two readers cannot drift.
 * Only reached when the pid is already dead, and cached, because it costs a
 * PowerShell start and the page polls every 5s.
 */
let paneProbe = { at: 0, alive: false, key: null };
const PANE_PROBE_TTL = 30 * 1000;

function paneHoldsClaude(j) {
  if (!j || !j.pane_id) return false;
  const key = j.pane_id + '|' + j.claude_pid;
  if (paneProbe.key === key && Date.now() - paneProbe.at < PANE_PROBE_TTL) return paneProbe.alive;
  let alive = false;
  try {
    const out = execFileSync(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        path.join(REPO, 'scripts', 'go-loop-lock.ps1'), 'status', '-Json'],
      { cwd: REPO, encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'ignore'] }
    );
    const st = JSON.parse(out.replace(/^﻿/, ''));
    alive = st.owner_alive_by === 'pane';
  } catch {
    alive = false; // an unreadable probe must never invent a running loop
  }
  paneProbe = { at: Date.now(), alive, key };
  return alive;
}

/**
 * Is the loop's supervisor itself alive? (T440.)
 *
 * The watchdog died at 09:14 on 2026-08-03 and nothing noticed for thirteen
 * hours: its HKCU Run entry only fires at logon, and the only evidence it was
 * gone was a log that stopped — which nobody reads until they already suspect.
 * It now stamps a heartbeat on every tick, healthy ticks included, so the
 * absence of a supervisor is a state this page can SHOW.
 *
 * Absent file ⇒ `present: false`, not an error: a box that has never installed
 * the watchdog is a real, reportable state too.
 */
function watchdogState(file) {
  let j;
  try {
    j = JSON.parse(
      fs.readFileSync(file || path.join(REPO, 'temp', 'go-loop.watchdog.json'), 'utf8').replace(/^﻿/, '')
    );
  } catch {
    return { present: false, running: false };
  }
  if (!j || !j.tick_at) return { present: false, running: false };
  const tick = Date.parse(j.tick_at);
  const age = isNaN(tick) ? null : Date.now() - tick;
  // Two consecutive missed ticks, floored at 15 min so a hand-run watchdog with
  // a long poll is not reported dead for being slow.
  const poll = (Number(j.poll_seconds) || 300) * 1000;
  const allowed = Math.max(poll * 3, 15 * 60 * 1000);
  return {
    present: true,
    pid: j.watchdog_pid || null,
    tickAt: isNaN(tick) ? null : tick,
    tickAgeMs: age,
    lastTick: j.last_tick || null,
    pollSeconds: Number(j.poll_seconds) || null,
    // Both must hold. A live pid whose ticks stopped is wedged, which supervises
    // exactly as much as a dead one does.
    running: pidAlive(j.watchdog_pid) && age != null && age < allowed,
  };
}

/**
 * Does this pid still exist? Signal 0 tests for the process without touching
 * it; EPERM means it exists and is not ours to signal.
 */
function pidAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

/**
 * Git's last-commit time for a file. Used only for the handful of in-progress
 * and blocked tasks, so one `git log` each is fine; doing it for all 460 would
 * not be.
 */
function lastTouched(relPath) {
  try {
    const out = git(['log', '-1', '--format=%at', '--', relPath]).trim();
    return out ? Number(out) * 1000 : null;
  } catch {
    return null;
  }
}

/**
 * Created / last-modified time for EVERY task file, from ONE
 * `git log --name-only` walk over the tasks directory rather than 485
 * `git log -1` calls (which takes minutes on this box).
 *
 * Two wrinkles worth knowing:
 *
 * 1. A bulk pass rewrites the frontmatter of every task in a single commit —
 *    a re-triage, a field being added or dropped. Counting that as a
 *    modification would stamp the entire tracker "modified today" and destroy
 *    exactly the signal this column exists to carry, so commits whose subject
 *    starts with `chore(triage)` or `chore(tracker)` do not count as
 *    modifications. They still establish `created`, and a file whose ONLY
 *    commit is a bulk one falls back to it — otherwise a task filed in the
 *    same breath as a bulk pass would report no date at all.
 * 2. A task created but not yet committed has no git dates. The filesystem is
 *    the fallback, so a task filed thirty seconds ago still shows up dated.
 */
let dateCache = { head: null, map: null };
function fileDates() {
  let head = '';
  try {
    head = git(['rev-parse', 'HEAD']).trim();
  } catch {}
  if (dateCache.head === head && dateCache.map) return dateCache.map;

  const map = new Map();
  let out = '';
  try {
    // %x1e record separator, then "<ts> <subject>" and the file list.
    out = git(['log', '--name-only', '--format=%x1e%at\x1f%s', '--', REL_TASK_DIR]);
  } catch {
    out = '';
  }
  for (const rec of out.split('\x1e')) {
    if (!rec.trim()) continue;
    const nl = rec.indexOf('\n');
    const headLine = nl < 0 ? rec : rec.slice(0, nl);
    const [tsRaw, subject] = headLine.split('\x1f');
    const ts = Number(tsRaw) * 1000;
    if (!ts) continue;
    const isTriage = /^chore\((triage|tracker)\)/.test((subject || '').trim());
    for (const line of (nl < 0 ? '' : rec.slice(nl + 1)).split('\n')) {
      const p = line.trim();
      if (!p.endsWith('.md') || !p.startsWith(REL_TASK_DIR)) continue;
      const id = path.basename(p, '.md');
      let e = map.get(id);
      if (!e) {
        e = { created: ts, modified: null, modifiedAny: ts };
        map.set(id, e);
      }
      // git log walks newest-first, so every later record is older.
      e.created = Math.min(e.created, ts);
      e.modifiedAny = Math.max(e.modifiedAny, ts);
      if (!isTriage) e.modified = Math.max(e.modified || 0, ts);
    }
  }
  for (const e of map.values()) if (!e.modified) e.modified = e.modifiedAny;

  dateCache = { head, map };
  return map;
}

/**
 * Task files with uncommitted changes. For those the git date is stale by
 * definition, so the filesystem mtime is the newer truth. Everywhere else the
 * git date wins, because a fresh clone gives every file the same checkout
 * mtime and would report the whole tracker as modified today.
 */
function dirtyTasks() {
  const set = new Set();
  let out = '';
  try {
    out = git(['status', '--porcelain', '--', REL_TASK_DIR]);
  } catch {
    return set;
  }
  for (const line of out.split('\n')) {
    const p = line.slice(3).trim().replace(/^"|"$/g, '');
    if (p.endsWith('.md')) set.add(path.basename(p, '.md'));
  }
  return set;
}

/** Filesystem fallback for a task that git has never seen. */
function statDates(relPath) {
  try {
    const s = fs.statSync(path.join(REPO, relPath));
    return { created: Math.round(s.birthtimeMs || s.mtimeMs), modified: Math.round(s.mtimeMs) };
  } catch {
    return { created: null, modified: null };
  }
}

/**
 * Identity of the code currently being served. The page compares it against
 * the value it loaded with and reloads itself when it changes.
 *
 * Without this, editing the page or this file leaves the pane rendering the
 * old HTML against a new API — the poll keeps succeeding, so nothing looks
 * broken, it just silently never changes. A viewer pane does not live-reload
 * an http location the way it does a file, so the page has to do it.
 */
function pageVersion() {
  try {
    return [PAGE, __filename]
      .map((f) => Math.round(fs.statSync(f).mtimeMs))
      .join('-');
  } catch {
    return '0';
  }
}

function buildPayload() {
  const tasks = loadTasks();
  annotateReadiness(tasks);
  const counts = tally(tasks.map((t) => t.bucket));
  const history = buildHistory();

  // The working tree is the newest point: it includes edits that are not
  // committed yet, which is exactly the state the user is looking at.
  const live = new Map(tasks.map((t) => [t.id, t.bucket]));
  const uncommittedDone = [];
  for (const [id, b] of live) {
    if (b === 'done' && history.last[id] !== 'done') uncommittedDone.push(id);
  }
  const series = history.points.map((p) => ({
    ts: p.ts,
    done: p.done,
    open: p.open,
    total: p.total,
  }));
  const now = Date.now();
  series.push({ ts: now, done: counts.done, open: counts.open, total: counts.total });

  // Completion timestamp per task, from the transition that first marked it
  // done. Uncommitted completions are stamped "now" so they still show up.
  const completedAt = {};
  for (const p of history.points) {
    for (const id of p.newlyDone) if (!(id in completedAt)) completedAt[id] = p.ts;
  }
  for (const id of uncommittedDone) if (!(id in completedAt)) completedAt[id] = now;

  // Completions per calendar day, gap-filled so an idle day reads as zero
  // rather than vanishing from the axis.
  const perDay = new Map();
  for (const [, ts] of Object.entries(completedAt)) {
    const d = dayKey(ts);
    perDay.set(d, (perDay.get(d) || 0) + 1);
  }
  const daily = fillDays(perDay, series.length ? series[0].ts : now, now);

  const seats = new Map();
  for (const t of tasks) {
    if (t.bucket === 'skipped') continue;
    if (!seats.has(t.seat)) seats.set(t.seat, { seat: t.seat, done: 0, open: 0, total: 0 });
    const row = seats.get(t.seat);
    if (t.bucket === 'done') row.done++;
    else if (OPEN_BUCKETS.has(t.bucket)) row.open++;
    row.total++;
  }

  const decisions = loadDecisions();
  const taskById = new Map(tasks.map((t) => [t.id, t]));
  const activity = buildActivity(history.points, taskById, decisions);
  const loop = loopState();
  const watchdog = watchdogState();

  // Created / modified for every task, so the table can sort on them.
  const dates = fileDates();
  const dirty = dirtyTasks();

  // Date the file was last touched, for in-progress and blocked tasks only —
  // that is what tells a 20-minute-old "in progress" apart from a five-day-old
  // one nobody ever reset. A DIRTY file's git date is stale by definition (the
  // active turn edits the file long before it commits), so the filesystem
  // mtime wins there — without this the task being worked right now reads as
  // "stale, untouched for days" the moment a turn runs long.
  const STALE_MS = 24 * 3600 * 1000;
  for (const t of tasks) {
    if (t.bucket !== 'in_progress' && t.bucket !== 'blocked') continue;
    const gitTs = lastTouched(t.file);
    const fsTs = dirty.has(t.id) ? statDates(t.file).modified : null;
    t.touchedAt = Math.max(gitTs || 0, fsTs || 0) || null;
    t.staleMs = t.touchedAt ? now - t.touchedAt : null;
    t.stale = t.bucket === 'in_progress' && t.staleMs != null && t.staleMs > STALE_MS;
  }
  for (const t of tasks) {
    const g = dates.get(t.id);
    const fsd = g && !dirty.has(t.id) ? null : statDates(t.file);
    t.createdAt = g ? g.created : fsd.created;
    t.modifiedAt = g ? (fsd ? Math.max(g.modified, fsd.modified || 0) : g.modified) : fsd.modified;
  }

  const priorities = new Map();
  for (const t of tasks) {
    if (!OPEN_BUCKETS.has(t.bucket)) continue;
    const key = t.priority || 'untriaged';
    priorities.set(key, (priorities.get(key) || 0) + 1);
  }

  const digests = digestDates();
  const week = now - 7 * 864e5;
  return {
    digests,
    digest: digests.length ? readDigest(digests[0]) : null,
    priorities: ['P0', 'P1', 'P2', 'P3', 'untriaged'].map((p) => ({ priority: p, open: priorities.get(p) || 0 })),
    generatedAt: now,
    pageVersion: pageVersion(),
    branch: branchName(),
    taskDir: REL_TASK_DIR,
    loop,
    watchdog,
    decisions,
    openDecisions: decisions.filter((d) => d.status !== 'resolved').length,
    activity,
    counts,
    ready: tasks.filter((t) => t.ready).length,
    doneLast7: Object.values(completedAt).filter((ts) => ts >= week).length,
    // The convergence number: closed-vs-total of the M1 milestone's members.
    milestone: (() => {
      const m1 = tasks.filter((t) => t.milestone === 'M1');
      const closed = m1.filter((t) => t.bucket === 'done' || t.bucket === 'skipped').length;
      return { name: 'M1', total: m1.length, closed, open: m1.length - closed };
    })(),
    historyStart: series.length ? series[0].ts : now,
    series,
    daily,
    seats: [...seats.values()].sort((a, b) => b.total - a.total),
    tasks: tasks.map((t) => ({
      ...t,
      completedAt: completedAt[t.id] || null,
      // When the task entered its current bucket. If the on-disk status has
      // not been committed yet, history knows an older state — report "now"
      // rather than the previous transition's stamp, which would inflate a
      // fresh block into days.
      statusSince: history.last[t.id] === t.bucket ? (history.since[t.id] || null) : now,
    })),
  };
}

function dayKey(ts) {
  const d = new Date(ts);
  return (
    d.getFullYear() +
    '-' +
    String(d.getMonth() + 1).padStart(2, '0') +
    '-' +
    String(d.getDate()).padStart(2, '0')
  );
}

function fillDays(perDay, fromTs, toTs) {
  const out = [];
  const d = new Date(fromTs);
  d.setHours(0, 0, 0, 0);
  const end = new Date(toTs);
  end.setHours(0, 0, 0, 0);
  // A guard, not a policy: a corrupt timestamp must not spin forever.
  for (let guard = 0; d <= end && guard < 2000; guard++) {
    const k = dayKey(d.getTime());
    out.push({ day: k, ts: d.getTime(), count: perDay.get(k) || 0 });
    d.setDate(d.getDate() + 1);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

function warn(msg) {
  process.stderr.write(
    '[' + new Date().toISOString() + '] task-dashboard: ' + msg + '\n');
}

/**
 * Writes go through the PowerShell scripts, never through a second copy of
 * the file format here. parity-decisions.ps1 already knows how to resolve a
 * decision and fold it into its task; re-implementing that in JS would be two
 * writers of one format, drifting apart at the first change.
 */
function ps(script, args) {
  const dirs = [];
  if (process.env.GHOZTTY_TASK_DIR) dirs.push('-TaskDir', process.env.GHOZTTY_TASK_DIR);
  if (process.env.GHOZTTY_DECISION_DIR && script === 'parity-decisions.ps1') {
    dirs.push('-DecisionDir', process.env.GHOZTTY_DECISION_DIR);
  }
  return execFileSync(
    'powershell',
    ['-NoProfile', '-NonInteractive', '-File', path.join(__dirname, script), ...args, ...dirs],
    { encoding: 'utf8', cwd: REPO, maxBuffer: 8 * 1024 * 1024 }
  ).trim();
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let b = '';
    req.on('data', (c) => {
      b += c;
      if (b.length > 256 * 1024) reject(new Error('body too large'));
    });
    req.on('end', () => {
      try {
        resolve(b ? JSON.parse(b) : {});
      } catch (e) {
        reject(new Error('bad JSON body'));
      }
    });
    req.on('error', reject);
  });
}

/** Reject anything that is not the shape we expect before it reaches a shell. */
function must(value, re, what) {
  const s = String(value == null ? '' : value);
  if (!re.test(s)) throw new Error('invalid ' + what);
  return s;
}

function handlePost(url, body) {
  if (url === '/api/resolve') {
    const id = must(body.id, /^D\d+$/, 'decision id');
    const args = ['resolve', id];
    if (body.answer) args.push('-Answer', must(body.answer, /^(\d{1,3}|o\d{1,3})$/, 'answer'));
    if (body.note) args.push('-Note', String(body.note).slice(0, 2000));
    if (!body.answer && !body.note) throw new Error('pick an option or write a note');
    return { ok: true, message: ps('parity-decisions.ps1', args) };
  }
  if (url === '/api/status') {
    const id = must(body.id, /^T\d+[a-z0-9]*$/i, 'task id');
    // Only the transitions a human makes from this page. Marking something
    // `done` is the loop's job and needs evidence + a commit sha, so it is
    // deliberately not offered here.
    const status = must(body.status, /^(todo|in-progress|blocked)$/, 'status');
    // Say which button did it, in the task's own progress log. A status flip
    // used to leave no trace anywhere, so a stray click on "Mark unblocked"
    // read exactly like a deliberate, evidence-backed reopen — which is how
    // T443's armed watch came back into the queue with no crash behind it
    // (T564). The label comes from the page; fall back rather than omit it,
    // because "someone clicked something here" still beats silence. The
    // constant prefix is also what keeps the value from ever starting with a
    // `-` and being bound as a parameter name by `powershell -File`.
    const source = 'dashboard: ' +
      String(body.source == null || body.source === '' ? 'status button' : body.source)
        .replace(/[^\x20-\x7e]/g, ' ').slice(0, 120);
    return {
      ok: true,
      message: ps('parity-tasks.ps1', ['set-status', id, '-Status', status, '-SourceNote', source]),
    };
  }
  if (url === '/api/task') {
    const title = String(body.title || '').trim();
    if (!title) throw new Error('a task needs a title');
    const args = ['new', '-Title', title.slice(0, 300)];
    if (body.summary) args.push('-Summary', String(body.summary).slice(0, 4000));
    if (body.seat) args.push('-Seat', must(body.seat, /^(win|mac|any)$/, 'seat'));
    if (Array.isArray(body.tags) && body.tags.length) {
      args.push('-Tags', body.tags.map((t) => must(t, /^[a-z]+$/, 'tag')).join(','));
    }
    return { ok: true, message: ps('parity-tasks.ps1', args) };
  }
  throw new Error('unknown endpoint');
}

function serve(port) {
  const server = http.createServer((req, res) => {
    const url = (req.url || '/').split('?')[0];
    try {
      if (req.method === 'POST') {
        return readBody(req)
          .then((body) => handlePost(url, body))
          .then((r) => send(res, 200, 'application/json; charset=utf-8', JSON.stringify(r)))
          .catch((e) => {
            warn(e.message);
            send(res, 400, 'application/json; charset=utf-8',
              JSON.stringify({ error: String((e.stderr || e.message || e)).trim() }));
          });
      }
      if (url === '/api/data') {
        return send(res, 200, 'application/json; charset=utf-8', JSON.stringify(buildPayload()));
      }
      // Full task text, on demand. The detail popup wants the whole file, and
      // 485 whole files in every poll payload would be megabytes on the wire
      // every five seconds.
      if (url === '/api/task') {
        const id = new URL(req.url, 'http://x').searchParams.get('id') || '';
        // Path traversal: the id is echoed into a filename, so it is matched
        // against the id grammar rather than sanitised.
        if (!/^T\d+[a-z]?\d*$/i.test(id)) {
          return send(res, 400, 'application/json; charset=utf-8', JSON.stringify({ error: 'bad id' }));
        }
        const file = path.join(TASK_DIR, id + '.md');
        let text;
        try {
          text = fs.readFileSync(file, 'utf8');
        } catch {
          return send(res, 404, 'application/json; charset=utf-8', JSON.stringify({ error: 'no such task' }));
        }
        const fm = parseFrontmatter(text);
        return send(res, 200, 'application/json; charset=utf-8', JSON.stringify({
          id,
          file: REL_TASK_DIR + '/' + id + '.md',
          body: fm ? text.slice(fm.bodyStart) : text,
        }));
      }
      // Full commit message, on demand (T505). The activity feed ships only
      // the first paragraph of each commit body; the event detail dialog
      // wants the whole story, and shipping every full body in the poll
      // payload would be the same megabytes-on-the-wire mistake /api/task
      // exists to avoid.
      if (url === '/api/commit') {
        const sha = new URL(req.url, 'http://x').searchParams.get('sha') || '';
        // The sha is handed to git as a revision, so it is matched against
        // the hex grammar rather than sanitised — nothing else resolves.
        if (!/^[0-9a-f]{7,40}$/i.test(sha)) {
          return send(res, 400, 'application/json; charset=utf-8', JSON.stringify({ error: 'bad sha' }));
        }
        let msg;
        try {
          msg = git(['show', '-s', '--format=%B', sha]);
        } catch {
          return send(res, 404, 'application/json; charset=utf-8', JSON.stringify({ error: 'no such commit' }));
        }
        return send(res, 200, 'application/json; charset=utf-8', JSON.stringify({ sha, body: msg.trim() }));
      }
      if (url === '/api/digest') {
        const date = new URL(req.url, 'http://x').searchParams.get('date') || '';
        const d = readDigest(date); // readDigest validates the shape, so no traversal
        if (!d) {
          return send(res, 404, 'application/json; charset=utf-8', JSON.stringify({ error: 'no digest for ' + date }));
        }
        return send(res, 200, 'application/json; charset=utf-8', JSON.stringify(d));
      }
      if (url === '/' || url === '/index.html') {
        return send(res, 200, 'text/html; charset=utf-8', fs.readFileSync(PAGE, 'utf8'));
      }
      send(res, 404, 'text/plain; charset=utf-8', 'not found');
    } catch (e) {
      warn(e.stack || String(e));
      send(res, 500, 'application/json; charset=utf-8', JSON.stringify({ error: String(e.message || e) }));
    }
  });

  server.on('error', (e) => {
    if (e.code === 'EADDRINUSE') {
      // Idempotent by design: re-running the launcher must not spawn a second
      // server or kill the one the pane is already pointed at.
      process.stdout.write('http://localhost:' + port + '/ (already serving)\n');
      process.exit(0);
    }
    warn(e.message);
    process.exit(1);
  });

  // A dashboard that drops ONE request is worth far more than one that
  // vanishes. Every request path above is already guarded, so anything
  // reaching here is asynchronous — a socket error, a rejected promise nobody
  // awaited — and node's default for both is to print to stderr and exit. The
  // server is detached and hidden, so that exit is what the user meets as "the
  // tracker died": a pane showing a dead page, with no crash record anywhere
  // (2026-08-11). Log it and keep serving instead.
  process.on('uncaughtException', (e) => {
    warn('uncaught: ' + (e && e.stack ? e.stack : String(e)));
  });
  process.on('unhandledRejection', (e) => {
    warn('unhandled rejection: ' + (e && e.stack ? e.stack : String(e)));
  });

  server.listen(port, '127.0.0.1', () => {
    process.stdout.write(
      '[' + new Date().toISOString() + '] http://localhost:' + port + '/\n');
  });
}

function send(res, code, type, body) {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(body);
}

/**
 * `--selftest`: assert how this page reads the watchdog beacon (T440).
 *
 * Kept here rather than in the PowerShell acceptance script because the rule is
 * this file's, and a rule asserted from outside drifts. The beacon's WRITE side
 * is covered by go-loop-guard.ps1 section P; this is the READ side.
 */
function selfTest() {
  const tmp = path.join(REPO, 'temp', 'dashboard-selftest-' + process.pid + '.json');
  let failures = 0;
  const check = (name, cond) => {
    console.log((cond ? '  PASS ' : '  FAIL ') + name);
    if (!cond) failures++;
  };
  const write = (o) => {
    fs.mkdirSync(path.dirname(tmp), { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(o), 'utf8');
    return tmp;
  };
  const iso = (msAgo) => new Date(Date.now() - msAgo).toISOString();

  try {
    fs.rmSync(tmp, { force: true });
    let w = watchdogState(tmp);
    check('W1 a box with no beacon reports absent, not an error', w.present === false && w.running === false);

    w = watchdogState(write({ watchdog_pid: process.pid, tick_at: iso(30e3), poll_seconds: 300 }));
    check('W2 a live pid ticking now is running', w.present === true && w.running === true);

    // A dead pid is the 2026-08-03 failure itself: thirteen hours of a beacon
    // that stopped advancing while nobody looked.
    w = watchdogState(write({ watchdog_pid: 999999, tick_at: iso(30e3), poll_seconds: 300 }));
    check('W3 a beacon from a dead process is not running', w.present === true && w.running === false);

    // Wedged supervises exactly as much as dead does.
    w = watchdogState(write({ watchdog_pid: process.pid, tick_at: iso(60 * 60e3), poll_seconds: 300 }));
    check('W4 a live pid whose ticks stopped is not running', w.running === false);

    // ...but a quiet gap inside the allowance is not a fault: three polls, with
    // a 15-minute floor so a hand-run watchdog is not called dead for being slow.
    w = watchdogState(write({ watchdog_pid: process.pid, tick_at: iso(10 * 60e3), poll_seconds: 300 }));
    check('W5 a gap within the allowance is still running', w.running === true);

    w = watchdogState(write({ watchdog_pid: process.pid, poll_seconds: 300 }));
    check('W6 a beacon with no tick time is absent', w.present === false);

    w = watchdogState(write({ watchdog_pid: process.pid, tick_at: iso(30e3), poll_seconds: 300, last_tick: 'nudge' }));
    check('W7 the last tick action is reported', w.lastTick === 'nudge');

    // Progress-log parsing (go.md journaling): the resume path and the
    // in-flight card both read these, so the shapes the tooling writes —
    // and the hand-written degradations — must all parse.
    let pr = parseProgress('- 2026-08-05 09:12: claimed; work starting.\n- 2026-08-05 09:40 [session abc-123]: root cause found.\n- a hand-written line with no stamp\nnot a list line, ignored');
    check('P1 a stamped entry parses ts + text', pr[0].ts != null && pr[0].text === 'claimed; work starting.');
    check('P2 a session stamp is captured', pr[1].session === 'abc-123' && pr[1].text === 'root cause found.');
    check('P3 an unstamped line still shows up', pr[2].ts == null && /hand-written/.test(pr[2].text));
    check('P4 non-list lines are ignored', pr.length === 3);
    pr = parseProgress(Array.from({ length: 10 }, (_, i) => '- 2026-08-05 09:0' + (i % 10) + ': step ' + i).join('\n'));
    check('P5 only the newest few ship in the payload', pr.length === 6 && /step 9/.test(pr[5].text));
    check('P6 an absent section is an empty log', parseProgress('').length === 0);
  } finally {
    fs.rmSync(tmp, { force: true });
  }
  console.log(failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)');
  process.exit(failures === 0 ? 0 : 1);
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('--selftest')) return selfTest();
  if (argv.includes('--once')) {
    process.stdout.write(JSON.stringify(buildPayload(), null, 2) + '\n');
    return;
  }
  const pi = argv.indexOf('--port');
  const port = pi >= 0 && argv[pi + 1] ? Number(argv[pi + 1]) : 7788;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    warn('bad --port');
    process.exit(2);
  }
  serve(port);
}

main();
