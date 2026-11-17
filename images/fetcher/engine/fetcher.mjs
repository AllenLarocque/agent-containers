// The fetcher: a plain loop. It reads request files (DOIs only), fetches one paper at a
// time with the real browser, and writes PDFs, metadata.md and status files built only
// from the DOI, a fixed status code, a host name, a date and yes/no. It never acts on
// page content and never tries to get past a bot check.
//
// Log lines carry DOIs, status codes and host names only (never a URL, a title, page
// text or the library prefix).
//
// A "run" is the state below, shared by the 30 s polling passes of one process: within
// a run each paper gets one attempt, a challenged host is not visited again, and after a
// login page there are no more library-routed visits. A run ends when the process
// restarts, at the next UTC day, or (for one host or the library route) when the owner
// drops a retry request into the control directory.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { folderName } from './lib/doi.mjs';
import { writeFileInside, moveInside, EscapeError } from './lib/safe-write.mjs';
import { metadataMd } from './lib/records.mjs';
import { Pacer } from './lib/pacing.mjs';
import { loadConfig } from './lib/config.mjs';
import { hostOf } from './lib/classify.mjs';
import { openBrowser, resolveDoi, fetchOne } from './lib/browser.mjs';
import { scanRequests, readStatus, renderStatus, pending, plainDir, readSmall, startsWith, statusName } from './lib/queue.mjs';

export const DEFAULTS = Object.freeze({
  papersRoot: '/papers',
  configPath: '/etc/fetcher/config',
  profileDir: '/home/agent/.fetcher/profile',
  stateDir: '/home/agent/.fetcher/state',
  downloadDir: '/tmp/fetcher-dl',
  controlDir: '/run/fetcher',
  pollMs: 30000,
});

const LIBRARY_RETRY = new Set(['not-available:no-pdf-link', 'not-available:not-a-pdf', 'not-available:http-error']);
const HOST = /^[a-z0-9.-]{1,253}$/;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const day = (ms) => new Date(ms).toISOString().slice(0, 10);

export function newRun(date = day(Date.now())) {
  return { date, challenged: new Set(), libraryBlocked: false, results: new Map() };
}

// Control hooks (the control directory is the owner's, not mounted to the research side):
//   pause  - while present, no paper is started.
//   retry  - read once and removed; lines "check <host>", "login" or "all".
const paused = (controlDir) => fs.existsSync(path.join(controlDir, 'pause'));

function applyRetry(controlDir, run) {
  const file = path.join(controlDir, 'retry');
  const text = readSmall(file, 4096);
  if (text === null) return;
  fs.rmSync(file, { force: true });
  for (const line of text.split('\n').map((s) => s.trim())) {
    if (line === 'all') {
      run.challenged.clear();
      run.libraryBlocked = false;
      run.results.clear();
    } else if (line === 'login') {
      run.libraryBlocked = false;
      for (const [doi, r] of run.results) if (r.status === 'needs-owner:login') run.results.delete(doi);
    } else if (line.startsWith('check ') && HOST.test(line.slice(6))) {
      const h = line.slice(6);
      run.challenged.delete(h);
      for (const [doi, r] of run.results) {
        if ((r.status === 'needs-owner:check' || r.status === 'skipped:host-challenged') && (r.host === h || r.hop === h)) {
          run.challenged.delete(r.host);
          run.challenged.delete(r.hop);
          run.results.delete(doi);
        }
      }
    }
  }
}

// A real PDF already in this project's folder for this DOI (no links followed).
function alreadySaved(papersRoot, project, doi) {
  if (!plainDir(papersRoot, [project, folderName(doi)])) return false;
  return startsWith(path.join(papersRoot, project, folderName(doi), 'paper.pdf'), '%PDF-');
}

const challenge = (run, ...hosts) => { for (const h of hosts) if (h) run.challenged.add(h); };

// One paper: pacing, the direct visit, and at most one library-routed visit.
async function attempt(ctx, doi, { cfg, pacer, run }) {
  // Daily cap first, so a capped day does not even ask the resolver.
  const daily = pacer.check(hostOf(cfg.resolver), false);
  if (daily === 'skipped:daily-cap') return { status: daily, host: '', library: 'no' };
  const res = await resolveDoi(ctx, doi, { cfg });
  if (res.status) return { status: res.status, host: '', library: 'no' };
  const hop = res.host;
  const base = { host: hop, hop, library: 'no' };
  if (run.challenged.has(hop)) return { ...base, status: 'skipped:host-challenged' };
  const skip = pacer.check(hop, false);
  if (skip) return { ...base, status: skip };
  await sleep(pacer.waitMs(hop));
  pacer.record(hop, false);
  const r = await fetchOne(ctx, doi, { cfg, url: res.url, blocked: run.challenged });
  // Library-routed results report the direct landing host: a proxy's host could name
  // the owner's institution.
  const host = r.host || hop;
  if (r.status === 'needs-owner:check') challenge(run, hop, host, r.checkHost);
  if (!LIBRARY_RETRY.has(r.status) || !cfg.libraryPrefix || !hostOf(r.landingUrl ?? '')) {
    return { ...base, host, status: r.status, tmpPdf: r.tmpPdf };
  }
  if (run.libraryBlocked) return { ...base, host, status: 'needs-owner:login' };
  const lskip = pacer.check(hop, true);
  if (lskip) return { ...base, host, status: lskip };
  await sleep(pacer.waitMs(hop));
  pacer.record(hop, true);
  const l = await fetchOne(ctx, doi, { cfg, library: true, url: r.landingUrl, blocked: run.challenged });
  if (l.status === 'needs-owner:login') run.libraryBlocked = true;
  if (l.status === 'needs-owner:check') challenge(run, l.checkHost);
  return { ...base, host, status: l.status, library: 'yes', tmpPdf: l.tmpPdf };
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

// One pass over every pending DOI in every request file.
export async function runOnce({ ctx, pacer, cfg, run, papersRoot, controlDir, log = console.log, now = Date.now }) {
  applyRetry(controlDir, run);
  if (paused(controlDir)) return;
  for (const req of scanRequests(papersRoot)) {
    const date = day(now());
    const statusDir = plainDir(papersRoot, [req.project, '_fetch', 'status']);
    const map = readStatus(statusDir, req.name);
    const current = statusDir ? readSmall(path.join(statusDir, statusName(req.name)), 1 << 20) : null;
    if (current !== renderStatus(req, map, date)) writeStatus(papersRoot, req, map, date, 'status-file', log);
    for (const doi of pending(req, statusDir)) {
      if (paused(controlDir)) return;
      const cached = run.results.get(doi);
      let r;
      if (alreadySaved(papersRoot, req.project, doi)) {
        r = cached?.status === 'saved' && cached.project === req.project ? cached : { status: 'saved', host: '', library: 'no' };
      } else if (cached?.refused && cached.project === req.project) {
        continue;                          // write refused earlier this run: stays pending, no second attempt
      } else if (cached && !cached.refused && cached.status !== 'saved') {
        r = cached;                        // same paper in another request file: one attempt per run
      } else {
        r = await attempt(ctx, doi, { cfg, pacer, run });
        if (r.status === 'saved' && !store(papersRoot, req.project, doi, r, date, log)) {
          run.results.set(doi, { refused: true, project: req.project });
          continue;
        }
        delete r.tmpPdf;
        run.results.set(doi, { ...r, project: req.project });
        log(`${doi} ${r.status} ${r.host || '-'}`);
      }
      map.set(doi, { doi, status: r.status, host: r.host, date, library: r.library });
      writeStatus(papersRoot, req, map, date, doi, log);
    }
  }
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
  const ctx = await openBrowser({ profileDir: o.profileDir, downloadDir: o.downloadDir, sandbox: o.sandbox });
  const pacer = new Pacer({ statePath: path.join(o.stateDir, 'pacing.json'), caps: cfg.caps });
  let run = newRun();
  try {
    for (;;) {
      if (run.date !== day(Date.now())) run = newRun();
      await runOnce({ ctx, pacer, cfg, run, papersRoot: o.papersRoot, controlDir: o.controlDir, log });
      if (o.once) break;
      await sleep(o.pollMs);
    }
  } finally {
    await ctx.close().catch(() => {});
  }
}

// CLI: node fetcher.mjs [--papers=DIR] [--config=FILE] [--profile=DIR] [--state=DIR]
//                       [--downloads=DIR] [--control=DIR] [--once]
const FLAGS = { '--papers': 'papersRoot', '--config': 'configPath', '--profile': 'profileDir', '--state': 'stateDir',
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
