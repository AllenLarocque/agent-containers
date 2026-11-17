import test, { before, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { scanRequests, pending } from '../lib/queue.mjs';
import { openBrowser } from '../lib/browser.mjs';
import { runOnce, newRun } from '../fetcher.mjs';
import { Pacer } from '../lib/pacing.mjs';
import { folderName } from '../lib/doi.mjs';
import { startFixtureServer, H, PDF } from './fixture-server.mjs';
import { SANDBOX, testCfg, tempDirs, request, statusLines, statusOf, allFiles } from './helpers.mjs';

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
let fx, ctx, shared;
before(async () => {
  fx = await startFixtureServer();
  shared = tempDirs();
  ctx = await openBrowser({ profileDir: shared.profile, downloadDir: shared.downloads, sandbox: SANDBOX });
});
after(async () => { await ctx?.close(); await fx?.close(); });

function env(extraCfg = {}) {
  const d = tempDirs();
  const cfg = testCfg(fx, extraCfg);
  const logs = [];
  const pacer = new Pacer({ statePath: path.join(d.state, 'pacing.json'), caps: cfg.caps });
  const go = (run = newRun()) => runOnce({ ctx, pacer, cfg, run, papersRoot: d.papers, controlDir: d.control,
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
  fs.writeFileSync(path.join(d.control, 'pause'), '');
  const mark = fx.log.length;
  await go();
  assert.equal(fx.log.length, mark);
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt'), []);
});

// ---------------- the real loop in its own process ----------------
const childPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'child.mjs');
function startChild(d, extra = {}) {
  const opts = { papersRoot: d.papers, profileDir: d.profile, stateDir: d.state, downloadDir: d.downloads,
                 controlDir: d.control, cfg: testCfg(fx), pollMs: 600000, ...extra };
  const f = path.join(d.base, `child-${Date.now()}.json`);
  fs.writeFileSync(f, JSON.stringify(opts));
  const p = spawn(process.execPath, [childPath, f], { stdio: ['ignore', 'pipe', 'pipe'] });
  const out = { text: '' };
  p.stdout.on('data', (b) => { out.text += b; });
  p.stderr.on('data', (b) => { out.text += b; });
  const done = new Promise((r) => p.on('exit', (code, sig) => r({ code, sig })));
  return { p, out, done };
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
  const c1 = startChild(d, { cfg: testCfg(fx, { timeouts: { navMs: 3000, settleMs: 300, downloadMs: 60000 } }) });
  await waitFor(() => fx.hits('slowpdf').some((e) => e.path === '/pdf/slowpdf') &&
                      fs.readdirSync(d.downloads).length > 0);
  await new Promise((r) => setTimeout(r, 300));
  c1.p.kill('SIGKILL');
  await c1.done;
  const leftovers = fs.readdirSync(d.downloads);
  assert.ok(leftovers.length > 0, 'expected a partial download to be left behind');
  const papersFiles = allFiles(d.papers);
  assert.ok(!papersFiles.some((f) => f.includes(folderName('10.5555/slowpdf'))), 'partial PDF in the papers folder');
  assert.ok(!papersFiles.some((f) => path.basename(f).startsWith('.tmp-')));
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => [l[0], l[1]]), [['10.5555/good1', 'saved']]);
  const state1 = JSON.parse(fs.readFileSync(path.join(d.state, 'pacing.json'), 'utf8'));
  assert.equal(state1.total, 2);

  await new Promise((r) => setTimeout(r, 1000));   // let the orphaned browser exit
  const mark = fx.log.length;
  const c2 = startChild(d, { once: true });
  const { code } = await c2.done;
  assert.equal(code, 0, c2.out.text);
  for (const n of leftovers) assert.equal(fs.existsSync(path.join(d.downloads, n)), false, `leftover ${n} kept`);
  assert.equal(newHits(mark, 'good1'), 0);
  const st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st.map((l) => [l[0], l[1]]), [['10.5555/good1', 'saved'], ['10.5555/slowpdf', 'not-available:timeout']]);
  assert.equal(JSON.parse(fs.readFileSync(path.join(d.state, 'pacing.json'), 'utf8')).total, 3);
  assert.ok(!allFiles(d.papers).some((f) => f.includes(folderName('10.5555/slowpdf'))));
});
