import test, { before, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { scanRequests, pending, SCAN } from '../lib/queue.mjs';
import { runOnce, newRun, nextRun, applyRetry, parseArgs, pacing, DEFAULTS } from '../fetcher.mjs';
import { Pacer } from '../lib/pacing.mjs';
import { folderName } from '../lib/doi.mjs';
import { startFixtureServer, H, PDF } from './fixture-server.mjs';
import { testCfg, tempDirs, request, statusLines, statusOf, allFiles, browsersFor } from './helpers.mjs';

// ---------------- scanRequests / pending (no browser) ----------------
describe('scanRequests', () => {
  test('reads valid request files; DOIs, bad lines by number, extra lines past 200 are bad', () => {
    const d = tempDirs();
    const lines = ['https://doi.org/10.5555/good7', '10.5555/good2@evil.com', '10.5555/GOOD1', '', '10.5555/good1'];
    while (lines.length < 200) lines.push('');
    lines.push('10.5555/good9');
    request(d.papers, 'p', 'r1.txt', lines);
    const [r] = scanRequests(d.papers);
    assert.equal(r.project, 'p');
    assert.equal(r.name, 'r1.txt');
    assert.deepEqual(r.dois, ['10.5555/good1']);
    assert.deepEqual(r.bad, [1, 2, 201]);
  });

  test('badly named, linked or misplaced files are ignored', () => {
    const d = tempDirs();
    request(d.papers, 'p', 'ok.txt', ['10.5555/good1']);
    const req = path.join(d.papers, 'p', '_fetch', 'requests');
    for (const n of ['a b.txt', 'x.TXT', 'x.tsv', `${'a'.repeat(81)}.txt`, 'ü.txt'])
      fs.writeFileSync(path.join(req, n), '10.5555/good2\n');
    fs.writeFileSync(path.join(d.outside, 'evil.txt'), '10.5555/good3\n');
    fs.symlinkSync(path.join(d.outside, 'evil.txt'), path.join(req, 'link.txt'));
    fs.mkdirSync(path.join(req, 'dir.txt'));
    fs.writeFileSync(path.join(d.papers, 'p', '_fetch', 'x.txt'), '10.5555/good4\n');
    // A project whose _fetch is a link outside is not read at all.
    fs.mkdirSync(path.join(d.outside, 'requests'));
    fs.writeFileSync(path.join(d.outside, 'requests', 'r.txt'), '10.5555/good5\n');
    fs.mkdirSync(path.join(d.papers, 'q'));
    fs.symlinkSync(d.outside, path.join(d.papers, 'q', '_fetch'));
    assert.deepEqual(scanRequests(d.papers).map((r) => [r.project, r.name, r.dois]), [['p', 'ok.txt', ['10.5555/good1']]]);
  });

  test('a FIFO, an over-size request file and a symlinked project directory are ignored', () => {
    const d = tempDirs();
    request(d.papers, 'p', 'ok.txt', ['10.5555/good1']);
    const req = path.join(d.papers, 'p', '_fetch', 'requests');
    assert.equal(spawnSync('mkfifo', [path.join(req, 'fifo.txt')]).status, 0);
    fs.writeFileSync(path.join(req, 'big.txt'), '10.5555/good2\n'.repeat(5000));      // > 64 KiB
    fs.mkdirSync(path.join(d.outside, 'proj', '_fetch', 'requests'), { recursive: true });
    fs.writeFileSync(path.join(d.outside, 'proj', '_fetch', 'requests', 'r.txt'), '10.5555/good3\n');
    fs.symlinkSync(path.join(d.outside, 'proj'), path.join(d.papers, 'linked'));
    const t0 = Date.now();
    assert.deepEqual(scanRequests(d.papers).map((r) => [r.project, r.name, r.dois]), [['p', 'ok.txt', ['10.5555/good1']]]);
    assert.ok(Date.now() - t0 < 2000, 'the FIFO blocked the scan');
  });

  test('bounded: at most 50 request files per project, lexicographic; the rest untouched', () => {
    const d = tempDirs();
    for (let i = 0; i < 60; i++) request(d.papers, 'p', `r${String(i).padStart(2, '0')}.txt`, [`10.5555/good${i}`]);
    const got = scanRequests(d.papers);
    assert.equal(SCAN.filesPerProject, 50);
    assert.equal(got.length, 50);
    assert.equal(got[0].name, 'r00.txt');
    assert.equal(got.at(-1).name, 'r49.txt');
    assert.equal(fs.readdirSync(path.join(d.papers, 'p', '_fetch', 'requests')).length, 60);
  });

  test('bounded: projects and directory entries read per folder; bytes per pass', () => {
    const d = tempDirs();
    for (const p of ['a', 'b', 'c']) request(d.papers, p, 'r.txt', ['10.5555/good1']);
    assert.deepEqual(scanRequests(d.papers, { limits: { ...SCAN, projects: 2 } }).map((r) => r.project), ['a', 'b']);
    assert.deepEqual(scanRequests(d.papers, { limits: { ...SCAN, totalBytes: 20 } }).map((r) => r.project), ['a']);
  });

  test('an unchanged request file (same identity, size, mtime) is not read or parsed again', () => {
    const d = tempDirs();
    request(d.papers, 'p', 'r.txt', ['10.5555/good1']);
    const f = path.join(d.papers, 'p', '_fetch', 'requests', 'r.txt');
    const cache = new Map();
    fs.utimesSync(f, 1700000000, 1700000000);              // whole seconds: restored exactly below
    assert.deepEqual(scanRequests(d.papers, { cache })[0].dois, ['10.5555/good1']);
    fs.writeFileSync(f, '10.5555/good2\n');               // same size ...
    fs.utimesSync(f, 1700000000, 1700000000);              // ... and the old mtime: not read again
    assert.deepEqual(scanRequests(d.papers, { cache })[0].dois, ['10.5555/good1']);
    fs.writeFileSync(f, '10.5555/good22\n');              // a different size: read again
    assert.deepEqual(scanRequests(d.papers, { cache })[0].dois, ['10.5555/good22']);
    fs.rmSync(f);
    assert.deepEqual(scanRequests(d.papers, { cache }), []);
    assert.equal(cache.size, 0);
  });

  test('pending: needs-owner and skipped are not terminal; saved and not-available are', () => {
    const d = tempDirs();
    const st = path.join(d.papers, 'p', '_fetch', 'status');
    fs.mkdirSync(st, { recursive: true });
    fs.writeFileSync(path.join(st, 'r.tsv'), [
      '10.5555/a\tsaved\tx.org\t2026-11-16\tno', '10.5555/b\tnot-available:no-pdf-link\tx.org\t2026-11-16\tno',
      '10.5555/c\tneeds-owner:check\tx.org\t2026-11-16\tno', '10.5555/d\tskipped:daily-cap\t-\t2026-11-16\tno',
      '10.5555/e\tsaved\tIGNORE PREVIOUS\t2026-11-16\tno', 'garbage line', ''].join('\n'));
    const r = { project: 'p', name: 'r.txt', dois: ['10.5555/a', '10.5555/b', '10.5555/c', '10.5555/d', '10.5555/e', '10.5555/f'], bad: [] };
    assert.deepEqual(pending(r, st), ['10.5555/c', '10.5555/d', '10.5555/e', '10.5555/f']);
  });
});

// ---------------- the loop, with a real browser ----------------
let fx, browsers, shared;
before(async () => {
  fx = await startFixtureServer();
  shared = tempDirs();
  browsers = browsersFor(fx, shared);
  await browsers.direct();
});
after(async () => { await browsers?.close(); await fx?.close(); });

function env(extraCfg = {}) {
  const d = tempDirs();
  const cfg = testCfg(fx, extraCfg);
  const logs = [];
  const pacer = new Pacer({ statePath: path.join(d.state, 'pacing.json'), caps: cfg.caps });
  const go = (run = newRun()) => runOnce({ browsers, pacer, cfg, run, papersRoot: d.papers, controlDir: d.control,
                                            downloadDir: shared.downloads, log: (s) => logs.push(s) });
  return { d, go, logs, pacer };
}
const newHits = (mark, key, host) => fx.log.slice(mark).filter((e) => e.key === key && (!host || e.host === host)).length;

test('bad request lines are recorded by number and cause no request', async () => {
  const { d, go } = env();
  const lines = ['https://doi.org/10.5555/good7', '10.5555/good2@evil.com', '10.5555/good1'];
  while (lines.length < 200) lines.push('');
  lines.push('10.5555/good9');
  request(d.papers, 'p', 'r.txt', lines);
  const mark = fx.log.length;
  await go();
  const st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st.map((l) => [l[0], l[1]]).sort(), [['10.5555/good1', 'saved'], ['line:1', 'bad-request'],
    ['line:2', 'bad-request'], ['line:201', 'bad-request']]);
  for (const k of ['good7', 'good2', 'good9']) assert.equal(newHits(mark, k), 0, k);
  // Everything requested in this run concerned good1 (or was the browser's own favicon fetch).
  const other = fx.log.slice(mark).filter((e) => e.key !== 'good1' && e.path !== '/favicon.ico');
  assert.deepEqual(other, []);
});

test('one status line per DOI; a re-run skips saved and not-available, retries needs-owner', async () => {
  const { d, go } = env();
  request(d.papers, 'p', 'r.txt', ['10.5555/good3', '10.5555/nopdf', '10.5555/check', '10.5555/good3']);
  await go();
  let st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st.map((l) => [l[0], l[1], l[2]]), [['10.5555/good3', 'saved', H.P],
    ['10.5555/nopdf', 'not-available:no-pdf-link', H.P], ['10.5555/check', 'needs-owner:check', H.X]]);
  const mark = fx.log.length;
  await go(newRun());               // a new run (e.g. after a restart)
  assert.equal(newHits(mark, 'good3'), 0);
  assert.equal(newHits(mark, 'nopdf'), 0);
  assert.ok(newHits(mark, 'check', H.X) >= 1);
  st = statusLines(d.papers, 'p', 'r.txt');
  assert.equal(st.length, 3);
});

test('within one run a second pass revisits nothing; a retry request re-opens only that host', async () => {
  const { d, go } = env();
  request(d.papers, 'p', 'r.txt', ['10.5555/check', '10.5555/check2', '10.5555/hok']);
  const run = newRun();
  await go(run);
  let mark = fx.log.length;
  await go(run);
  assert.equal(fx.log.length, mark, 'second pass made requests');
  fs.writeFileSync(path.join(d.control, 'retry'), `check ${H.X}\n`);
  await go(run);
  assert.ok(newHits(mark, 'check', H.X) >= 1);
  assert.equal(fs.existsSync(path.join(d.control, 'retry')), false);
});

test('after a check on a host, later DOIs on that host are skipped:host-challenged with no request', async () => {
  const { d, go } = env();
  request(d.papers, 'p', 'r.txt', ['10.5555/check', '10.5555/check2', '10.5555/hok', '10.5555/good4']);
  const mark = fx.log.length;
  await go();
  const st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st.map((l) => [l[0], l[1], l[2]]), [['10.5555/check', 'needs-owner:check', H.X],
    ['10.5555/check2', 'skipped:host-challenged', H.X], ['10.5555/hok', 'skipped:host-challenged', H.X],
    ['10.5555/good4', 'saved', H.P]]);
  assert.equal(newHits(mark, 'check2', H.X), 0);
  assert.equal(newHits(mark, 'hok', H.X), 0);
});

test('two request files naming the same DOI -> one fetch', async () => {
  const { d, go } = env();
  request(d.papers, 'p', 'a.txt', ['10.5555/ok']);
  request(d.papers, 'p', 'b.txt', ['10.5555/ok']);
  request(d.papers, 'p', 'c.txt', ['10.5555/nopdf']);
  request(d.papers, 'p', 'd.txt', ['10.5555/nopdf']);
  const mark = fx.log.length;
  await go();
  assert.equal(newHits(mark, 'ok', H.R), 1);
  assert.equal(newHits(mark, 'nopdf', H.R), 1);
  for (const n of ['a.txt', 'b.txt']) assert.deepEqual(statusOf(statusLines(d.papers, 'p', n), '10.5555/ok'), ['saved']);
  for (const n of ['c.txt', 'd.txt'])
    assert.deepEqual(statusOf(statusLines(d.papers, 'p', n), '10.5555/nopdf'), ['not-available:no-pdf-link']);
});

test('a PDF already in the project folder is saved with no request; a fake one is not trusted', async () => {
  const { d, go } = env();
  const real = path.join(d.papers, 'p', folderName('10.5555/good5'));
  fs.mkdirSync(real, { recursive: true });
  fs.writeFileSync(path.join(real, 'paper.pdf'), PDF);
  const fake = path.join(d.papers, 'p', folderName('10.5555/good6'));
  fs.mkdirSync(fake, { recursive: true });
  fs.writeFileSync(path.join(fake, 'paper.pdf'), '<html>not a pdf</html>');
  request(d.papers, 'p', 'r.txt', ['10.5555/good5', '10.5555/good6']);
  const mark = fx.log.length;
  await go();
  const st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st.map((l) => [l[0], l[1]]), [['10.5555/good5', 'saved'], ['10.5555/good6', 'saved']]);
  assert.equal(newHits(mark, 'good5'), 0);
  assert.ok(newHits(mark, 'good6') >= 1);
  assert.equal(fs.readFileSync(path.join(fake, 'paper.pdf')).subarray(0, 5).toString(), '%PDF-');
});

test('a symlink planted at the paper folder: nothing written outside, no status line, "write refused" + DOI only', async () => {
  const { d, go, logs } = env();
  fs.mkdirSync(path.join(d.papers, 'p'), { recursive: true });
  fs.symlinkSync(d.outside, path.join(d.papers, 'p', folderName('10.5555/good8')));
  request(d.papers, 'p', 'r.txt', ['10.5555/good8']);
  await go();
  assert.deepEqual(fs.readdirSync(d.outside), []);
  assert.deepEqual(statusOf(statusLines(d.papers, 'p', 'r.txt'), '10.5555/good8'), []);
  assert.deepEqual(logs.filter((l) => l.includes('refused')), ['write refused 10.5555/good8']);
  assert.deepEqual(fs.readdirSync(shared.downloads).filter((n) => !n.startsWith('.')), [], 'download temp left behind');
});

test('pause flag: a pass makes no request and writes nothing', async () => {
  const { d, go } = env();
  request(d.papers, 'p', 'r.txt', ['10.5555/good1']);
  fs.writeFileSync(path.join(d.control, 'pause'), `${Date.now()}\n`);   // lib/control.mjs: "<ms of the last fetcherctl call>\n"
  const mark = fx.log.length;
  await go();
  assert.equal(fx.log.length, mark);
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt'), []);
});

// ---------------- the real loop in its own process ----------------
const childPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'child.mjs');
function startChild(d, extra = {}) {
  const opts = { papersRoot: d.papers, profilesDir: d.profile, stateDir: d.state, downloadDir: d.downloads,
                 controlDir: d.control, cfg: testCfg(fx), pollMs: 600000, testOnlyAllow: fx.allow, ...extra };
  const f = path.join(d.base, `child-${Date.now()}.json`);
  fs.writeFileSync(f, JSON.stringify(opts));
  const p = spawn(process.execPath, [childPath, f], { stdio: ['ignore', 'pipe', 'pipe'] });
  const out = { text: '' };
  p.stdout.on('data', (b) => { out.text += b; });
  p.stderr.on('data', (b) => { out.text += b; });
  const done = new Promise((r) => p.on('exit', (code, sig) => r({ code, sig })));
  return { p, out, done };
}
// Any process (in this container) whose command line names this profile folder.
function browserRunning(profileDir) {
  for (const pid of fs.readdirSync('/proc').filter((n) => /^[0-9]+$/.test(n))) {
    let cmd = '';
    try { cmd = fs.readFileSync(`/proc/${pid}/cmdline`, 'latin1'); } catch { continue; }
    if (cmd.includes(profileDir)) return true;
  }
  return false;
}
const waitFor = async (cond, ms = 30000) => {
  for (const t0 = Date.now(); Date.now() - t0 < ms;) { if (cond()) return; await new Promise((r) => setTimeout(r, 50)); }
  throw new Error('timed out waiting');
};

test('prompt injection: no page text in any file under the papers root or in the engine output', async () => {
  const d = tempDirs();
  request(d.papers, 'p', 'r.txt', ['10.5555/inject']);
  const c = startChild(d, { once: true });
  const { code } = await c.done;
  assert.equal(code, 0, c.out.text);
  assert.deepEqual(statusOf(statusLines(d.papers, 'p', 'r.txt'), '10.5555/inject'), ['saved']);
  const files = allFiles(d.papers);
  assert.ok(files.some((f) => f.endsWith('metadata.md')));
  for (const f of files) assert.ok(!/IGNORE|PREVIOUS INSTRUCTIONS/.test(fs.readFileSync(f, 'latin1')), f);
  assert.ok(c.out.text.includes('10.5555/inject saved'), c.out.text);
  assert.ok(!/IGNORE|PREVIOUS INSTRUCTIONS|\/research/.test(c.out.text), c.out.text);
});

test('kill mid-download and restart: no partial PDF, counts persist, leftover temp files deleted', async () => {
  const d = tempDirs();
  request(d.papers, 'p', 'r.txt', ['10.5555/good1', '10.5555/slowpdf']);
  // slowpdf declares 10 MB; the size cap must allow it so the download really starts.
  const c1 = startChild(d, { cfg: testCfg(fx, { maxPdfBytes: 20000000,
                                                timeouts: { navMs: 3000, settleMs: 300, downloadMs: 60000 } }) });
  try {
    await waitFor(() => fx.hits('slowpdf').some((e) => e.path === '/pdf/slowpdf') &&
                        fs.readdirSync(d.downloads).length > 0);
    await new Promise((r) => setTimeout(r, 300));
  } finally {
    c1.p.kill('SIGKILL');
    await c1.done;
  }
  const leftovers = fs.readdirSync(d.downloads);
  assert.ok(leftovers.length > 0, 'expected a partial download to be left behind');
  const papersFiles = allFiles(d.papers);
  assert.ok(!papersFiles.some((f) => f.includes(folderName('10.5555/slowpdf'))), 'partial PDF in the papers folder');
  assert.ok(!papersFiles.some((f) => path.basename(f).startsWith('.tmp-')));
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => [l[0], l[1]]), [['10.5555/good1', 'saved']]);
  const state1 = JSON.parse(fs.readFileSync(path.join(d.state, 'pacing.json'), 'utf8'));
  assert.equal(state1.total, 2);

  await waitFor(() => !browserRunning(d.profile), 20000);   // the orphaned browser has exited
  const mark = fx.log.length;
  const c2 = startChild(d, { once: true, cfg: testCfg(fx, { maxPdfBytes: 20000000 }) });
  const { code } = await c2.done;
  assert.equal(code, 0, c2.out.text);
  for (const n of leftovers) assert.equal(fs.existsSync(path.join(d.downloads, n)), false, `leftover ${n} kept`);
  assert.equal(newHits(mark, 'good1'), 0);
  const st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st.map((l) => [l[0], l[1]]), [['10.5555/good1', 'saved'], ['10.5555/slowpdf', 'not-available:timeout']]);
  assert.equal(JSON.parse(fs.readFileSync(path.join(d.state, 'pacing.json'), 'utf8')).total, 3);
  assert.ok(!allFiles(d.papers).some((f) => f.includes(folderName('10.5555/slowpdf'))));
});

// ---------------- fix round 1 ----------------
test('resolver lookups are paced: N DOIs that 404 respect the gap between resolver requests', async () => {
  const { d, go } = env({ caps: { gapMs: 300, hostGapMs: 0, perHost: 30, perDay: 100, libraryPerDay: 20, resolverPerDay: 300 } });
  request(d.papers, 'p', 'r.txt', ['10.5555/404a', '10.5555/404b', '10.5555/404c', '10.5555/404d']);
  const mark = fx.log.length;
  await go();
  const times = fx.log.slice(mark).filter((e) => e.host === H.R).map((e) => e.t);
  assert.equal(times.length, 4);
  for (let i = 1; i < times.length; i++) assert.ok(times[i] - times[i - 1] >= 280, `gap ${times[i] - times[i - 1]} ms`);
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => l[1]), Array(4).fill('not-available:doi-not-found'));
});

test('the resolver cap stops further lookups: remaining DOIs are skipped:daily-cap', async () => {
  const { d, go } = env({ caps: { gapMs: 0, hostGapMs: 0, perHost: 30, perDay: 100, libraryPerDay: 20, resolverPerDay: 2 } });
  request(d.papers, 'p', 'r.txt', ['10.5555/404e', '10.5555/404f', '10.5555/404g', '10.5555/good1']);
  const mark = fx.log.length;
  await go();
  assert.equal(fx.log.slice(mark).filter((e) => e.host === H.R).length, 2);
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => [l[0], l[1]]), [
    ['10.5555/404e', 'not-available:doi-not-found'], ['10.5555/404f', 'not-available:doi-not-found'],
    ['10.5555/404g', 'skipped:daily-cap'], ['10.5555/good1', 'skipped:daily-cap']]);
});

test('redirects onto a challenged host from two different first hops: that host is loaded once in all', async () => {
  const { d, go } = env();
  request(d.papers, 'p', 'r.txt', ['10.5555/check', '10.5555/via1', '10.5555/wia1', '10.5555/via2']);
  const mark = fx.log.length;
  await go();
  const st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st.map((l) => [l[0], l[1], l[2]]), [['10.5555/check', 'needs-owner:check', H.X],
    ['10.5555/via1', 'skipped:host-challenged', H.X], ['10.5555/wia1', 'skipped:host-challenged', H.X],
    ['10.5555/via2', 'skipped:host-challenged', H.X]]);
  const onX = fx.log.slice(mark).filter((e) => e.host === H.X && e.path !== '/favicon.ico');
  assert.deepEqual(onX.map((e) => e.key), ['check']);
  const hop = (h, p) => fx.log.slice(mark).filter((e) => e.host === h && e.path === p).length;
  assert.ok(hop(H.V, '/go/via1') === 1 && hop(H.W, '/go/wia1') === 1 && hop(H.V, '/go/via2') === 1, 'the first hops were visited');
});

test('the per-host cap counts the landing host: a redirect onto a capped host is refused before it is contacted', async () => {
  const { d, go } = env({ caps: { gapMs: 0, hostGapMs: 0, perHost: 2, perDay: 100, libraryPerDay: 20, resolverPerDay: 300 } });
  request(d.papers, 'p', 'r.txt', ['10.5555/good1', '10.5555/good2', '10.5555/vp1']);
  const mark = fx.log.length;
  await go();
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => [l[0], l[1], l[2]]), [['10.5555/good1', 'saved', H.P],
    ['10.5555/good2', 'saved', H.P], ['10.5555/vp1', 'skipped:host-cap', H.P]]);
  assert.equal(newHits(mark, 'vp1', H.P), 0);
  assert.equal(fx.log.slice(mark).filter((e) => e.host === H.V && e.path === '/go/vp1').length, 1);
});

test('the landing host is counted against its own cap and pacing (pacing state)', async () => {
  const { d, go, pacer } = env();
  request(d.papers, 'p', 'r.txt', ['10.5555/vp2']);
  await go();
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => [l[1], l[2]]), [['saved', H.P]]);
  const saved = JSON.parse(fs.readFileSync(pacer.statePath, 'utf8'));
  assert.equal(saved.hosts[H.V], 1);
  assert.equal(saved.hosts[H.P], 1);
  assert.equal(saved.total, 1);
});

test('fair across projects: one DOI per project in turn (100 DOIs in one project do not starve 2 in another)', async () => {
  const { d, go } = env({ caps: { gapMs: 0, hostGapMs: 0, perHost: 30, perDay: 100, libraryPerDay: 20, resolverPerDay: 4 } });
  request(d.papers, 'a', 'r.txt', Array.from({ length: 100 }, (_, i) => `10.5555/404x${i}`));
  request(d.papers, 'b', 'r.txt', ['10.5555/good5', '10.5555/good6']);
  await go();
  assert.deepEqual(statusLines(d.papers, 'b', 'r.txt').map((l) => [l[0], l[1]]), [['10.5555/good5', 'saved'], ['10.5555/good6', 'saved']]);
  const a = statusLines(d.papers, 'a', 'r.txt');
  assert.deepEqual(a.slice(0, 2).map((l) => l[1]), ['not-available:doi-not-found', 'not-available:doi-not-found']);
  assert.ok(a.slice(2).every((l) => l[1] === 'skipped:daily-cap'));
});

test('UTC day rollover starts a new run; the same day keeps it', () => {
  const run = newRun('2026-11-16');
  run.challenged.add('x.org');
  run.libraryBlocked = true;
  run.results.set('10.5555/a', { status: 'needs-owner:check' });
  assert.equal(nextRun(run, Date.UTC(2026, 10, 16, 23, 59)), run);
  const next = nextRun(run, Date.UTC(2026, 10, 17, 0, 0, 1));
  assert.notEqual(next, run);
  assert.equal(next.date, '2026-11-17');
  assert.equal(next.challenged.size + next.results.size, 0);
  assert.equal(next.libraryBlocked, false);
});

test('retry lines: login re-opens only the library route; all clears the run; junk is ignored', () => {
  const d = tempDirs();
  const mk = () => {
    const run = newRun();
    run.challenged.add('x.org');
    run.libraryBlocked = true;
    run.results.set('10.5555/a', { status: 'needs-owner:login', host: 'p.org' });
    run.results.set('10.5555/b', { status: 'needs-owner:check', host: 'x.org', hop: 'x.org' });
    return run;
  };
  const retry = (text, run) => { fs.writeFileSync(path.join(d.control, 'retry'), text); applyRetry(d.control, run); return run; };
  let run = retry('login\n', mk());
  assert.equal(run.libraryBlocked, false);
  assert.deepEqual([...run.results.keys()], ['10.5555/b']);
  assert.deepEqual([...run.challenged], ['x.org']);
  assert.equal(fs.existsSync(path.join(d.control, 'retry')), false);
  run = retry('all\n', mk());
  assert.equal(run.libraryBlocked, false);
  assert.equal(run.results.size + run.challenged.size, 0);
  run = retry('check ../../etc\nrm -rf /\ncheck X.ORG\n', mk());
  assert.equal(run.results.size, 2);
  assert.equal(run.libraryBlocked, true);
});

test('CLI arguments: absolute paths for known flags, --once; anything else is refused', () => {
  assert.deepEqual(parseArgs([]), {});
  assert.deepEqual(parseArgs(['--papers=/p', '--config=/c', '--profiles=/pr', '--state=/s', '--downloads=/d', '--control=/r', '--once']),
    { papersRoot: '/p', configPath: '/c', profilesDir: '/pr', stateDir: '/s', downloadDir: '/d', controlDir: '/r', once: true });
  // nothing on the command line turns a guard off or lets loopback through
  for (const bad of [['--papers=rel'], ['--papers'], ['--sandbox=off'], ['--no-sandbox'], ['x'], ['--testOnlyAllow=/x'],
                     ['--allow=/127.0.0.1:3773'], ['--profile=/old']])
    assert.throws(() => parseArgs(bad), /bad argument/, bad[0]);
  assert.equal(DEFAULTS.papersRoot, '/papers');
  assert.equal(DEFAULTS.downloadDir, '/tmp/fetcher-dl');
  assert.equal(DEFAULTS.profilesDir, '/home/agent/.fetcher');
  assert.equal('profileDir' in DEFAULTS, false);
});

test('library-routed navigation that times out: the prefix never reaches stdout/stderr', async () => {
  const d = tempDirs();
  request(d.papers, 'p', 'r.txt', ['10.5555/paywallslow']);
  const c = startChild(d, { once: true, cfg: testCfg(fx, { libraryPrefix: fx.libraryPrefix }) });
  const { code } = await c.done;
  assert.equal(code, 0, c.out.text);
  assert.ok(fx.hits('paywallslow', H.Y).length >= 1, 'library route not taken');
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => [l[1], l[4]]), [['not-available:timeout', 'yes']]);
  assert.ok(c.out.text.includes('10.5555/paywallslow not-available:timeout'), c.out.text);
  assert.ok(!c.out.text.includes('/lib') && !c.out.text.includes(H.Y) && !c.out.text.includes(fx.libraryPrefix), c.out.text);
});

// ---------------- slower pacing an owner request can interrupt (2026-11-18) ----------------
test('pacing: the wait is the gap plus up to half as much again; no wait at all for 0', async () => {
  const d = tempDirs();
  let t = Date.now();
  assert.equal(await pacing({ controlDir: d.control, rand: () => 0.999 })(200), false);
  assert.ok(Date.now() - t >= 290, `waited ${Date.now() - t} ms`);
  t = Date.now();
  assert.equal(await pacing({ controlDir: d.control, rand: () => 0 })(200), false);
  assert.ok(Date.now() - t >= 190 && Date.now() - t < 290, `waited ${Date.now() - t} ms`);
  t = Date.now();
  assert.equal(await pacing({ controlDir: d.control, rand: () => 0.999 })(0), false);
  assert.ok(Date.now() - t < 100);
});

test('pacing: an owner request ends the wait at once and is reported', async () => {
  const d = tempDirs();
  fs.writeFileSync(path.join(d.control, 'retry'), 'all\n');
  const t = Date.now();
  assert.equal(await pacing({ controlDir: d.control })(60000), true);
  assert.ok(Date.now() - t < 500);
});

test('an owner request during a paper\'s wait is served within a second or two; the paper is fetched afterwards, once', async () => {
  const { d, go } = env({ caps: { gapMs: 20000, hostGapMs: 0, perHost: 30, perDay: 100, libraryPerDay: 20, resolverPerDay: 300 } });
  request(d.papers, 'p', 'r.txt', ['10.5555/404a', '10.5555/404b']);
  const run = newRun();
  const mark = fx.log.length;
  const t = Date.now();
  setTimeout(() => fs.writeFileSync(path.join(d.control, 'retry'), 'check nowhere.example\n'), 700);
  assert.equal(await go(run), 'again');                      // the second lookup was waiting out its 20 s gap
  assert.ok(Date.now() - t < 6000, `returned after ${Date.now() - t} ms`);
  assert.equal(fs.existsSync(path.join(d.control, 'retry')), false, 'the request was served');
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => l[0]), ['10.5555/404a']);
  assert.equal(fx.log.slice(mark).filter((e) => e.host === H.R).length, 1);
});
