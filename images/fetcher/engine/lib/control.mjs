// The owner's controls: the files in the control directory (/run/fetcher, the fetcher's own; never
// mounted anywhere the research side can write). fetcherctl (main, below) writes them; the engine
// (serviceControl) reads them between papers. Every file has one fixed format and is validated on
// both sides; anything else is removed unread. No file ever holds a URL, the library prefix or text
// from a web page.
//
//   pause  "<ms>\n"                 the engine starts no paper while it is present. <ms> is the time
//                                   of the last fetcherctl call; IDLE_MS after it the engine removes
//                                   it. `retry` removes it at once.
//   open   "check <host>\n"         open, in the visible browser, the landing page of the first paper
//          "login\n"                waiting on a bot check at <host> (resolver + DOI), or the library
//                                   prefix + the landing URL of the first paper waiting on the login.
//                                   Read once and removed. Opening a page also sets the pause.
//   retry  lines "all" | "login" | "check <host>"   appended; read once and removed.
//   reply  "<word> check <host>\n" | "<word> login\n", word = opened | nothing-waiting | no-prefix:
//                                   the engine's answer to the last open request.
//
// Opening a page for the owner is a plain navigation: the engine never clicks, types or otherwise
// touches page content, and never reads it here.
import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { HOST, STATUS } from './records.mjs';
import { hostOf } from './classify.mjs';
import { loadConfig } from './config.mjs';
import { PROJECT, MAX_STATUS_BYTES, statusRecord } from './queue.mjs';
import { withDir, listAt, readSmall, readSmallAt } from './fs-util.mjs';

export const IDLE_MS = 30 * 60 * 1000;
export const hostOk = (h) => typeof h === 'string' && HOST.test(h);
const MAX_CONTROL_BYTES = 4096;
const PAUSE = /^([0-9]{1,15})\n$/;
const OPEN = /^(?:check ([a-z0-9.-]{1,253})|login)\n$/;
const REPLY = /^(opened|nothing-waiting|no-prefix) (check [a-z0-9.-]{1,253}|login)\n$/;
const { O_WRONLY, O_CREAT, O_EXCL, O_APPEND, O_NOFOLLOW } = fs.constants;

// ---------------- file primitives (fixed names only) ----------------
const file = (dir, name) => path.join(dir, name);

// Whole-file write: a fresh temp file (O_EXCL|O_NOFOLLOW, mode 600) renamed over the name, so a
// link planted at the name is replaced, never followed.
function put(dir, name, text) {
  const tmp = file(dir, `.${name}.${randomBytes(6).toString('hex')}`);
  const fd = fs.openSync(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600);
  try { fs.writeSync(fd, text); } finally { fs.closeSync(fd); }
  fs.renameSync(tmp, file(dir, name));
}
const drop = (dir, name) => fs.rmSync(file(dir, name), { force: true });   // unlink: never follows a link
const read = (dir, name) => readSmall(file(dir, name), MAX_CONTROL_BYTES);    // regular file, no link, capped

// Read once: renamed aside first, so a line appended meanwhile is not lost with the file.
function take(dir, name) {
  const aside = file(dir, `.${name}.taking`);
  try { fs.renameSync(file(dir, name), aside); } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
  const text = readSmall(aside, MAX_CONTROL_BYTES);
  fs.rmSync(aside, { force: true });
  return text;
}

// ---------------- pause ----------------
// -> 'none' | 'paused' | 'expired' (expired or malformed: the caller decides whether to remove it)
export function pauseState(dir, nowMs) {
  if (!fs.existsSync(file(dir, 'pause')) && !isLink(dir, 'pause')) return 'none';
  const m = PAUSE.exec(read(dir, 'pause') ?? '');
  if (!m) return 'expired';
  const t = Number(m[1]);
  return nowMs - t < IDLE_MS && t <= nowMs + 60000 ? 'paused' : 'expired';
}
const isLink = (dir, name) => { try { return fs.lstatSync(file(dir, name)).isSymbolicLink(); } catch { return false; } };
export const setPause = (dir, nowMs) => put(dir, 'pause', `${Math.floor(nowMs)}\n`);

// ---------------- requests ----------------
// -> [{kind: 'all'|'login'} | {kind: 'check', host}]; junk lines are dropped.
export function takeRetry(dir) {
  const text = take(dir, 'retry');
  if (text === null) return [];
  const out = [];
  for (const line of text.split('\n')) {
    if (line === 'all' || line === 'login') out.push({ kind: line });
    else if (line.startsWith('check ') && hostOk(line.slice(6))) out.push({ kind: 'check', host: line.slice(6) });
  }
  return out;
}

// -> {kind: 'check', host} | {kind: 'login'} | null
export function takeOpen(dir) {
  const m = OPEN.exec(take(dir, 'open') ?? '');
  if (!m) return null;
  return m[1] ? { kind: 'check', host: m[1] } : { kind: 'login' };
}

// ---------------- the engine's side ----------------
const waitingOn = (r, h) => r.status === 'needs-owner:check' && (r.host === h || r.hop === h || r.checkHost === h);

// What to retry. "check <host>" forgets that host's challenge and its waiting papers (each of them
// also un-challenges the hosts it recorded), "login" the login block and the login-waiting papers,
// "all" the whole run's results.
export function applyRetryLines(lines, run) {
  for (const l of lines) {
    if (l.kind === 'all') {
      run.challenged.clear();
      run.libraryBlocked = false;
      run.results.clear();
    } else if (l.kind === 'login') {
      run.libraryBlocked = false;
      for (const [doi, r] of run.results) if (r.status === 'needs-owner:login') run.results.delete(doi);
    } else if (l.kind === 'check') {
      run.challenged.delete(l.host);
      for (const [doi, r] of run.results) {
        if ((waitingOn(r, l.host) || r.status === 'skipped:host-challenged') && (r.host === l.host || r.hop === l.host || r.checkHost === l.host)) {
          for (const h of [r.host, r.hop, r.checkHost]) if (h) run.challenged.delete(h);
          run.results.delete(doi);
        }
      }
    }
  }
}

// The page to open for an owner request, from the engine's own memory of this run (never from a
// status file, which the research side can write). -> {url} | {reply}
export function ownerTarget(req, run, cfg) {
  const what = req.kind === 'check' ? `check ${req.host}` : 'login';
  if (req.kind === 'check') {
    for (const [doi, r] of run.results) if (waitingOn(r, req.host)) return { url: cfg.resolver + doi, what };
    return { reply: `nothing-waiting ${what}` };
  }
  if (!cfg.libraryPrefix) return { reply: `no-prefix ${what}` };
  for (const r of run.results.values()) {
    if (r.status === 'needs-owner:login' && hostOf(r.landingUrl)) return { url: cfg.libraryPrefix + encodeURIComponent(r.landingUrl), what };
  }
  return { reply: `nothing-waiting ${what}` };
}

// The visible tab back to about:blank, other tabs closed (between papers and when nothing is asked).
async function blank(ctx) {
  const [page, ...rest] = ctx.pages();
  for (const p of rest) await p.close().catch(() => {});
  if (page && page.url() !== 'about:blank') await page.goto('about:blank', { timeout: 10000 }).catch(() => {});
}

// Called by the engine before every paper. Applies retry requests (which end the pause), opens a
// requested page (which starts the pause), ends a pause after IDLE_MS without a fetcherctl call.
// -> true while paused (start no paper).
export async function serviceControl({ ctx, cfg, run, controlDir, now = Date.now, log = console.log }) {
  const retry = takeRetry(controlDir);
  if (retry.length) {
    applyRetryLines(retry, run);
    if (pauseState(controlDir, now()) !== 'none') log('pause ended (retry)');
    drop(controlDir, 'pause');
    await blank(ctx);
    log(`retry ${retry.map((l) => (l.kind === 'check' ? l.host : l.kind)).join(' ')}`);
  }
  const req = takeOpen(controlDir);
  if (req) {
    const t = ownerTarget(req, run, cfg);
    if (t.url) {
      setPause(controlDir, now());
      const page = ctx.pages()[0] ?? await ctx.newPage();
      await page.goto(t.url, { waitUntil: 'domcontentloaded', timeout: cfg.timeouts?.navMs ?? 60000 }).catch(() => {});
      put(controlDir, 'reply', `opened ${t.what}\n`);
      log(`owner page opened: ${t.what}`);
    } else {
      put(controlDir, 'reply', `${t.reply}\n`);
      log(`owner page not opened: ${t.reply}`);
    }
  }
  const st = pauseState(controlDir, now());
  if (st === 'expired') {
    drop(controlDir, 'pause');
    await blank(ctx);
    log('pause ended (30 minutes without a fetcherctl call)');
    return false;
  }
  return st === 'paused';
}

// Wait up to ms, waking early (checked every stepMs) when an open or retry request arrives.
export async function waitForControl(controlDir, ms, stepMs = 1000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms;) {
    if (fs.existsSync(file(controlDir, 'open')) || fs.existsSync(file(controlDir, 'retry'))) return;
    await new Promise((r) => setTimeout(r, Math.min(stepMs, ms - (Date.now() - t0))));
  }
}

// ---------------- status (fetcherctl status) ----------------
// Built only from status lines that re-render byte for byte (statusRecord); anything else counts as
// invalid. The papers folders are the research side's to write, so everything is bounded: names
// by pattern, files per project, bytes per file and bytes overall.
const STATUS_NAME = /^[A-Za-z0-9._-]{1,80}\.tsv$/;
export const LIMITS = Object.freeze({ projects: 500, filesPerProject: 500, totalBytes: 16 * 1024 * 1024, hostsShown: 20 });

export function statusSummary(papersRoot, limits = LIMITS) {
  const projects = [];
  let bytes = 0;
  let truncated = false;
  const names = (withDir(papersRoot, [], listAt) ?? []).filter((p) => PROJECT.test(p)).sort();
  if (names.length > limits.projects) truncated = true;
  for (const project of names.slice(0, limits.projects)) {
    const s = { project, counts: new Map(), invalid: 0, checkHosts: new Set(), login: false };
    withDir(papersRoot, [project, '_fetch', 'status'], (fd) => {
      const files = listAt(fd).filter((n) => STATUS_NAME.test(n)).sort();
      if (files.length > limits.filesPerProject) truncated = true;
      for (const n of files.slice(0, limits.filesPerProject)) {
        const text = readSmallAt(fd, n, MAX_STATUS_BYTES);
        if (text === null) { s.invalid += 1; continue; }        // a link, a FIFO, a folder or over 1 MiB (size checked before reading)
        bytes += Buffer.byteLength(text);
        if (bytes > limits.totalBytes) { truncated = true; break; }
        const lines = text.split('\n');
        if (lines.at(-1) === '') lines.pop();
        for (const line of lines) {
          const rec = statusRecord(line);
          if (!rec) { s.invalid += 1; continue; }
          s.counts.set(rec.status, (s.counts.get(rec.status) ?? 0) + 1);
          if (rec.status === 'needs-owner:check' && rec.host) s.checkHosts.add(rec.host);
          if (rec.status === 'needs-owner:login') s.login = true;
        }
      }
    });
    if (s.counts.size || s.invalid) projects.push(s);
  }
  return { projects, truncated };
}

export function renderSummary({ projects, truncated }, limits = LIMITS) {
  const out = [];
  if (!projects.length) out.push('no status files yet');
  for (const s of projects) {
    const counts = STATUS.filter((k) => s.counts.has(k)).map((k) => `${k}=${s.counts.get(k)}`);
    if (s.invalid) counts.push(`invalid=${s.invalid}`);
    out.push(`project ${s.project}: ${counts.join(' ')}`);
    const hosts = [...s.checkHosts].sort();
    const more = hosts.length > limits.hostsShown ? ` (+${hosts.length - limits.hostsShown} more)` : '';
    out.push(`  check waiting: ${hosts.length ? hosts.slice(0, limits.hostsShown).join(' ') + more : 'none'}`);
    out.push(`  login waiting: ${s.login ? 'yes' : 'no'}`);
  }
  if (truncated) out.push('(more status files than the read limits allow: not all were read)');
  return out;
}

// ---------------- fetcherctl ----------------
export const USAGE = 'usage: fetcherctl status | view | check <host> | login | retry [<host>|login]';
const REPLY_TEXT = {
  opened: (w) => (w === 'login'
    ? 'opened the library sign-in for the first paper waiting on the login. Check the address bar before typing. When signed in: retry login'
    : `opened the landing page of the first paper waiting on ${w.slice(6)}. When the check is done: retry ${w.slice(6)}`),
  'nothing-waiting': (w) => (w === 'login' ? 'no paper is waiting on the library login in this run: nothing opened'
    : `no paper is waiting on a check at ${w.slice(6)} in this run: nothing opened`),
  'no-prefix': () => 'no library prefix is configured (LIBRARY_LINK_PREFIX): nothing opened',
};
const replyText = (text) => { const m = REPLY.exec(text ?? ''); return m ? { word: m[1], what: m[2], line: REPLY_TEXT[m[1]](m[2]) } : null; };

// fetcherctl's whole behaviour. Arguments are validated before anything is written; the only files
// written are the fixed names above in controlDir. -> exit code.
export async function main(argv, o = {}) {
  const { controlDir = '/run/fetcher', configPath = '/etc/fetcher/config', papersRoot = '/papers', now = Date.now,
          waitMs = 20000, out = (s) => console.log(s), err = (s) => console.error(s) } = o;
  const usage = () => { err(USAGE); return 2; };
  const [cmd, arg, ...extra] = argv;
  if (extra.length) return usage();
  // Validate first: nothing below this block runs for a bad call.
  let what;
  if (cmd === 'status' || cmd === 'view' || cmd === 'login') {
    if (arg !== undefined) return usage();
  } else if (cmd === 'check') {
    if (!hostOk(arg)) { err('fetcherctl: not a host name'); return 2; }
  } else if (cmd === 'retry') {
    if (arg === undefined) what = 'all';
    else if (arg === 'login') what = 'login';
    else if (hostOk(arg)) what = `check ${arg}`;
    else { err('fetcherctl: retry takes a host name, login, or nothing (all)'); return 2; }
  } else {
    return usage();
  }
  if (cmd === 'login') {
    let cfg;
    try { cfg = loadConfig(configPath); } catch { err('fetcherctl: the fetcher config cannot be read'); return 1; }
    if (!cfg.libraryPrefix) { err(REPLY_TEXT['no-prefix']()); return 1; }
  }

  // Any call keeps a running pause alive (it ends IDLE_MS after the last call).
  if (pauseState(controlDir, now()) === 'paused') setPause(controlDir, now());

  if (cmd === 'status') {
    out(`paused: ${pauseState(controlDir, now()) === 'paused' ? 'yes' : 'no'}`);
    const r = replyText(read(controlDir, 'reply'));
    out(`last page request: ${r ? `${r.word} ${r.what}` : 'none'}`);
    for (const line of renderSummary(statusSummary(papersRoot))) out(line);
    return 0;
  }
  if (cmd === 'view') {
    setPause(controlDir, now());
    out('paused: the fetcher finishes the paper in flight, then leaves the browser alone until retry (or 30 minutes without a fetcherctl call)');
    return 0;
  }
  if (cmd === 'retry') {
    const fd = fs.openSync(file(controlDir, 'retry'), O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600);
    try {
      if (!fs.fstatSync(fd).isFile()) throw new Error('retry is not a file');
      fs.writeSync(fd, `${what}\n`);
    } finally { fs.closeSync(fd); }
    drop(controlDir, 'pause');
    out(`retry ${what === 'all' ? 'all waiting papers' : what} requested; pause ended`);
    return 0;
  }
  // check / login: ask the engine to open the page, and wait a little for its answer.
  what = cmd === 'check' ? `check ${arg}` : 'login';
  drop(controlDir, 'reply');
  put(controlDir, 'open', `${what}\n`);
  for (const t0 = Date.now(); Date.now() - t0 < waitMs;) {
    const r = replyText(read(controlDir, 'reply'));
    if (r && r.what === what) { (r.word === 'opened' ? out : err)(r.line); return r.word === 'opened' ? 0 : 1; }
    await new Promise((res) => setTimeout(res, 200));
  }
  out(`requested (${what}): the fetcher opens it after the paper in flight; fetcherctl status shows its answer`);
  return 0;
}
