// The fetcher: a plain loop. It reads request files (DOIs only), fetches one paper at a
// time with the real browser, and writes PDFs, metadata.md and status files built only
// from the DOI, a fixed status code, a host name, a date and yes/no. It never acts on
// page content and never tries to get past a bot check.
//
// Log lines carry DOIs, status codes and host names only (never a URL, a title, page
// text or the library prefix).
//
// A "run" is the state below, shared by the 30 s polling passes of one process: within
// a run each paper gets one attempt, a challenged host is not contacted again (not as a first
// hop, not by redirect, not by a page's own move), and after a login page there are no more
// library-routed visits. A run ends when the process
// restarts, at the next UTC day, or (for one host or the library route) when the owner
// asks for a retry (fetcherctl retry). The owner's controls (pause, opening a page for
// the owner, retry) are lib/control.mjs; this file only wires them in.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { folderName } from './lib/doi.mjs';
import { writeFileInside, moveInside, EscapeError } from './lib/safe-write.mjs';
import { metadataMd, hostField } from './lib/records.mjs';
import { Pacer } from './lib/pacing.mjs';
import { loadConfig } from './lib/config.mjs';
import { hostOf } from './lib/classify.mjs';
import { Browsers, resolveDoi, fetchOne } from './lib/browser.mjs';
import { scanRequests, statusText, parseStatus, pendingIn, renderStatus, statusName } from './lib/queue.mjs';
import { withDir, startsWithAt } from './lib/fs-util.mjs';
import { serviceControl, takeRetry, applyRetryLines, waitForControl } from './lib/control.mjs';

export const DEFAULTS = Object.freeze({
  papersRoot: '/papers',
  configPath: '/etc/fetcher/config',
  profilesDir: '/home/agent/.fetcher',          // profile-direct and profile-library (lib/browser.mjs)
  stateDir: '/home/agent/.fetcher/state',
  downloadDir: '/tmp/fetcher-dl',
  controlDir: '/run/fetcher',
  pollMs: 30000,
});

const LIBRARY_RETRY = new Set(['not-available:no-pdf-link', 'not-available:not-a-pdf', 'not-available:http-error']);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const day = (ms) => new Date(ms).toISOString().slice(0, 10);

export function newRun(date = day(Date.now())) {
  return { date, challenged: new Set(), libraryBlocked: false, results: new Map(), landings: new Map(), scan: new Map() };
}

// A new UTC day starts a new run (challenged hosts and attempts are forgotten).
export const nextRun = (run, nowMs) => (run.date === day(nowMs) ? run : newRun(day(nowMs)));

// Read the control directory's retry requests into the run (lib/control.mjs has the formats).
export const applyRetry = (controlDir, run) => applyRetryLines(takeRetry(controlDir), run);

// A real PDF already in this project's folder for this DOI (no links followed).
function alreadySaved(papersRoot, project, doi) {
  return withDir(papersRoot, [project, folderName(doi)], (fd) => startsWithAt(fd, 'paper.pdf', '%PDF-')) === true;
}

const challenge = (run, ...hosts) => { for (const h of hosts) if (h) run.challenged.add(h); };

// The navigation guard for one visit: every host the tab's main frame is about to go to after the
// first one(s) is refused if it was challenged this run or is at its per-host cap, and otherwise
// counted against the per-host cap and gap (pacer.recordHost) and remembered as a landing host of
// this first hop (its gap is waited for before the hop's next visit).
function hostGuard(run, pacer, hop, approved) {
  const ok = new Set(approved);
  const landings = run.landings.get(hop) ?? new Set();
  run.landings.set(hop, landings);
  return (host) => {
    if (!host || ok.has(host)) return null;
    if (run.challenged.has(host)) return 'skipped:host-challenged';
    const cap = pacer.hostCap(host);
    if (cap) return cap;
    ok.add(host);
    if (landings.size < 20) landings.add(host);
    pacer.recordHost(host);
    return null;
  };
}
const waitFor = (pacer, run, hop) => Math.max(pacer.waitMs(hop), ...[...(run.landings.get(hop) ?? [])].map((h) => pacer.waitMs(h)));

// One paper: pacing, the direct visit (direct browser), and at most one library-routed visit
// (library browser, closed again afterwards).
async function attempt(browsers, doi, { cfg, pacer, run }) {
  // Every network request is paced. The resolver lookup has its own cap and gap
  // (Pacer.checkLookup/lookupWaitMs/recordLookup) and does not count toward the daily
  // total of publisher visits.
  const direct = await browsers.direct();
  const resolver = hostOf(cfg.resolver);
  const capped = pacer.checkLookup(resolver);
  if (capped) return { status: capped, host: '', library: 'no' };
  await sleep(pacer.lookupWaitMs(resolver));
  pacer.recordLookup(resolver);
  const res = await resolveDoi(direct, doi, { cfg });
  if (res.status) return { status: res.status, host: '', library: 'no' };
  const hop = res.host;
  const base = { host: hop, hop, library: 'no' };
  if (run.challenged.has(hop)) return { ...base, status: 'skipped:host-challenged' };
  const skip = pacer.check(hop, false);
  if (skip) return { ...base, status: skip };
  await sleep(waitFor(pacer, run, hop));
  pacer.record(hop, false);
  const r = await fetchOne(direct, doi, { cfg, url: res.url, navCheck: hostGuard(run, pacer, hop, [hop]) });
  // Library-routed results report the direct landing host: a proxy's host could name
  // the owner's institution.
  const host = r.host || hop;
  // Recorded against the host the tab was on when the challenge was read, and nothing else.
  if (r.status === 'needs-owner:check') challenge(run, r.checkHost);
  // Library route only with an http(s) landing URL on the host the direct visit recorded.
  // checkHost and landingUrl stay in the run's memory (an owner's check or login page is opened
  // from them); they are never written or logged.
  if (!LIBRARY_RETRY.has(r.status) || !cfg.libraryPrefix || !r.landingUrl || hostOf(r.landingUrl) !== r.host) {
    return { ...base, host, status: r.status, tmpPdf: r.tmpPdf, checkHost: r.checkHost };
  }
  if (run.libraryBlocked) return { ...base, host, status: 'needs-owner:login', landingUrl: r.landingUrl };
  const lskip = pacer.check(hop, true);
  if (lskip) return { ...base, host, status: lskip };
  await sleep(waitFor(pacer, run, hop));
  pacer.record(hop, true);
  let l;
  try {
    const lib = await browsers.library();
    l = await fetchOne(lib, doi, { cfg, library: true, url: r.landingUrl,
                                  navCheck: hostGuard(run, pacer, hop, [hostOf(cfg.libraryPrefix), hop, r.host]) });
  } finally {
    await browsers.closeLibrary();
  }
  if (l.status === 'needs-owner:login') run.libraryBlocked = true;
  if (l.status === 'needs-owner:check') challenge(run, l.checkHost);
  return { ...base, host, status: l.status, library: 'yes', tmpPdf: l.tmpPdf, checkHost: l.checkHost,
           landingUrl: l.status === 'needs-owner:login' ? r.landingUrl : undefined };
}

// Move the PDF in and write metadata.md. false (and "write refused <doi>") on refusal.
function store(papersRoot, project, doi, r, date, log) {
  const folder = `${project}/${folderName(doi)}`;
  try {
    moveInside(r.tmpPdf, papersRoot, `${folder}/paper.pdf`);
    writeFileInside(papersRoot, `${folder}/metadata.md`, metadataMd({ doi, host: r.host, date, library: r.library }));
    return true;
  } catch (e) {
    fs.rmSync(r.tmpPdf, { force: true });
    log(`${e instanceof EscapeError ? 'write refused' : 'write failed'} ${doi}`);
    return false;
  }
}

// label is a DOI, or the fixed word status-file.
function writeStatus(papersRoot, req, map, date, label, log) {
  try {
    writeFileInside(papersRoot, `${req.project}/_fetch/status/${statusName(req.name)}`, renderStatus(req, map, date));
  } catch (e) {
    log(`${e instanceof EscapeError ? 'write refused' : 'write failed'} ${label}`);
  }
}

// One pass over the pending DOIs of every request file considered (queue.SCAN bounds), taken
// round-robin across projects (one DOI per project in turn), so one project cannot starve the
// others. downloadDir (optional) is emptied after each paper, so nothing a page started by itself
// accumulates there.
export async function runOnce({ browsers, pacer, cfg, run, papersRoot, controlDir, downloadDir, log = console.log, now = Date.now }) {
  const control = () => serviceControl({ browsers, cfg, run, controlDir, now, log });
  if (await control()) return;
  const queues = new Map();                 // project -> [{req, map, doi}]
  for (const req of scanRequests(papersRoot, { cache: run.scan })) {
    const date = day(now());
    const current = statusText(papersRoot, req.project, req.name);
    const map = parseStatus(current);
    if (current !== renderStatus(req, map, date)) writeStatus(papersRoot, req, map, date, 'status-file', log);
    const q = queues.get(req.project) ?? [];
    for (const doi of pendingIn(req, map)) q.push({ req, map, doi });
    queues.set(req.project, q);
  }
  const lists = [...queues.values()];
  for (let i = 0; lists.some((q) => i < q.length); i++) {
    for (const q of lists) {
      if (i >= q.length) continue;
      if (await control()) return;          // paused: the paper in flight is done; the browser is the owner's
      await one(q[i], { browsers, pacer, cfg, run, papersRoot, downloadDir, log, now });
    }
  }
}

async function one({ req, map, doi }, { browsers, pacer, cfg, run, papersRoot, downloadDir, log, now }) {
  const date = day(now());
  const cached = run.results.get(doi);
  let r;
  if (alreadySaved(papersRoot, req.project, doi)) {
    r = cached?.status === 'saved' && cached.project === req.project ? cached : { status: 'saved', host: '', library: 'no' };
  } else if (cached?.refused && cached.project === req.project) {
    return;                                // write refused earlier this run: stays pending, no second attempt
  } else if (cached && !cached.refused && cached.status !== 'saved') {
    r = cached;                            // same paper in another request file: one attempt per run
  } else {
    try {
      r = await attempt(browsers, doi, { cfg, pacer, run });
      if (r.status === 'saved' && !store(papersRoot, req.project, doi, r, date, log)) r = null;
    } finally {
      if (downloadDir) emptyDir(downloadDir);
    }
    if (r === null) {
      run.results.set(doi, { refused: true, project: req.project });
      return;
    }
    delete r.tmpPdf;
    run.results.set(doi, { ...r, project: req.project });
    log(`${doi} ${r.status} ${hostField(r.host)}`);
  }
  map.set(doi, { doi, status: r.status, host: r.host, date, library: r.library });
  writeStatus(papersRoot, req, map, date, doi, log);
}

// Leftovers from a killed run are never complete files; remove them all.
function emptyDir(dir) {
  if (!path.isAbsolute(dir) || path.resolve(dir) === '/') throw new Error('download dir must be an absolute, non-root path');
  fs.mkdirSync(dir, { recursive: true });
  for (const name of fs.readdirSync(dir)) fs.rmSync(path.join(dir, name), { recursive: true, force: true });
}

export async function runLoop(opts = {}) {
  const o = { ...DEFAULTS, ...opts };
  const cfg = o.cfg ?? loadConfig(o.configPath);
  const log = o.log ?? console.log;
  emptyDir(o.downloadDir);
  // sandbox and testOnlyAllow come only from a caller's options (the tests); parseArgs never sets them.
  const browsers = new Browsers({ profilesDir: o.profilesDir, downloadDir: o.downloadDir, sandbox: o.sandbox,
                                  testOnlyAllow: o.testOnlyAllow });
  await browsers.direct();
  const pacer = new Pacer({ statePath: path.join(o.stateDir, 'pacing.json'), caps: cfg.caps });
  const now = o.now ?? Date.now;
  let run = newRun(day(now()));
  try {
    for (;;) {
      run = nextRun(run, now());
      await runOnce({ browsers, pacer, cfg, run, papersRoot: o.papersRoot, controlDir: o.controlDir,
                      downloadDir: o.downloadDir, log, now });
      if (o.once) break;
      await waitForControl(o.controlDir, o.pollMs);   // wakes early for an owner request
    }
  } finally {
    await browsers.close().catch(() => {});
  }
}

// CLI: node fetcher.mjs [--papers=DIR] [--config=FILE] [--profiles=DIR] [--state=DIR]
//                       [--downloads=DIR] [--control=DIR] [--once]
const FLAGS = { '--papers': 'papersRoot', '--config': 'configPath', '--profiles': 'profilesDir', '--state': 'stateDir',
                '--downloads': 'downloadDir', '--control': 'controlDir' };
export function parseArgs(argv) {
  const o = {};
  for (const a of argv) {
    if (a === '--once') { o.once = true; continue; }
    const eq = a.indexOf('=');
    const key = FLAGS[eq < 0 ? a : a.slice(0, eq)];
    if (!key || eq < 0 || !path.isAbsolute(a.slice(eq + 1))) throw new Error(`bad argument: ${a.slice(0, 20)}`);
    o[key] = a.slice(eq + 1);
  }
  return o;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.once('SIGTERM', () => process.exit(0));
  runLoop(parseArgs(process.argv.slice(2))).catch((e) => {
    console.error(`fetcher stopped: ${e?.name ?? 'Error'}`);
    process.exit(1);
  });
}
