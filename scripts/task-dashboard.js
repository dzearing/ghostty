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
const REL_INDEX = 'docs/design/windows-parity-tasks.md';
// Same escape hatch the PowerShell scripts carry (-TaskDir / -DecisionDir, and
// GHOSTTY_HOST_DEFAULTS before them): point a run at fixtures so the write
// paths can be exercised without filing junk into the real tracker.
const TASK_DIR = process.env.GHOZTTY_TASK_DIR || path.join(REPO, ...REL_TASK_DIR.split('/'));
const DECISION_DIR = process.env.GHOZTTY_DECISION_DIR || path.join(REPO, ...REL_DECISION_DIR.split('/'));
const PAGE = path.join(__dirname, 'task-dashboard.page.html');
const CACHE = path.join(REPO, 'temp', 'task-dashboard-history.json');

// Bump when a cached point gains or changes a field, so an old cache is
// rebuilt instead of silently feeding half-populated activity items.
const CACHE_VERSION = 2;

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

/** First paragraph under `## Summary`, flattened to one line. */
function extractSummary(body) {
  const m = /^##\s+Summary\s*$/m.exec(body);
  if (!m) return '';
  const rest = body.slice(m.index + m[0].length);
  const stop = rest.search(/^\s*#{2,}\s/m);
  const block = (stop < 0 ? rest : rest.slice(0, stop)).trim();
  const para = block.split(/\n\s*\n/)[0] || '';
  return para.replace(/\s+/g, ' ').trim();
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
      phase: F.phase == null ? null : String(F.phase),
      deps: Array.isArray(F.deps) ? F.deps.map(String) : [],
      commits: Array.isArray(F.commits) ? F.commits.map(String) : [],
      status,
      bucket: bucketOf(status),
      reason: statusReason(status),
      summary: extractSummary(text.slice(fm.bodyStart)),
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
  for (const line of fmText.split(/\r?\n/)) {
    if (/^options:\s*\[\s*\]\s*$/.test(line)) return [];
    if (/^options:\s*$/.test(line)) { inOpts = true; continue; }
    if (!inOpts) continue;
    if (/^[A-Za-z]/.test(line)) break; // next top-level key
    let m = /^\s*-\s*key:\s*(.+)$/.exec(line);
    if (m) { out.push({ key: m[1].trim(), label: '', detail: '' }); continue; }
    m = /^\s+label:\s*(.+)$/.exec(line);
    if (m && out.length) { out[out.length - 1].label = parseValue(m[1]) || ''; continue; }
    m = /^\s+detail:\s*(.+)$/.exec(line);
    if (m && out.length) { out[out.length - 1].detail = parseValue(m[1]) || ''; }
  }
  return out;
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
    if (c.version === CACHE_VERSION && Array.isArray(c.points) && c.last && typeof c.last === 'object') return c;
  } catch {}
  return { version: CACHE_VERSION, points: [], last: {} };
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
  if (stale) cache = { version: CACHE_VERSION, points: [], last: {} };

  let prev = new Map(Object.entries(cache.last));
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
    cache.points.push({
      sha: c.sha, ts: c.ts, subject: c.subject, body: c.body,
      ...tally(cur.values()), newlyDone, filed,
    });
    prev = cur;
    added++;
  }
  if (added) {
    cache.last = Object.fromEntries(prev);
    writeCache(cache);
  }
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

  const phases = new Map();
  for (const t of tasks) {
    if (t.bucket === 'skipped') continue;
    const key = t.phase || '—';
    if (!phases.has(key)) phases.set(key, { phase: key, done: 0, open: 0, total: 0 });
    const row = phases.get(key);
    if (t.bucket === 'done') row.done++;
    else if (OPEN_BUCKETS.has(t.bucket)) row.open++;
    row.total++;
  }

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

  const week = now - 7 * 864e5;
  return {
    generatedAt: now,
    pageVersion: pageVersion(),
    branch: branchName(),
    taskDir: REL_TASK_DIR,
    decisions,
    openDecisions: decisions.filter((d) => d.status !== 'resolved').length,
    activity,
    counts,
    ready: tasks.filter((t) => t.ready).length,
    doneLast7: Object.values(completedAt).filter((ts) => ts >= week).length,
    historyStart: series.length ? series[0].ts : now,
    series,
    daily,
    phases: [...phases.values()].sort((a, b) => b.total - a.total || a.phase.localeCompare(b.phase)),
    seats: [...seats.values()].sort((a, b) => b.total - a.total),
    tasks: tasks.map((t) => ({ ...t, completedAt: completedAt[t.id] || null })),
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
  process.stderr.write('task-dashboard: ' + msg + '\n');
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
  if (url === '/api/task') {
    const title = String(body.title || '').trim();
    if (!title) throw new Error('a task needs a title');
    const args = ['new', '-Title', title.slice(0, 300)];
    if (body.summary) args.push('-Summary', String(body.summary).slice(0, 4000));
    if (body.seat) args.push('-Seat', must(body.seat, /^(win|mac|any)$/, 'seat'));
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

  server.listen(port, '127.0.0.1', () => {
    process.stdout.write('http://localhost:' + port + '/\n');
  });
}

function send(res, code, type, body) {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(body);
}

function main() {
  const argv = process.argv.slice(2);
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
