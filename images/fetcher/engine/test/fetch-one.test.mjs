// Real Chromium (headed, on the harness's Xvfb display) against the fixture server.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { openBrowser, fetchOne, resolveDoi } from '../lib/browser.mjs';
import { runOnce, newRun } from '../fetcher.mjs';
import { Pacer } from '../lib/pacing.mjs';
import { folderName } from '../lib/doi.mjs';
import { startFixtureServer, H, BIG } from './fixture-server.mjs';
import { SANDBOX, testCfg, tempDirs, request, statusLines, allFiles } from './helpers.mjs';

let fx, dirs, ctx, cfg;
before(async () => {
  fx = await startFixtureServer();
  dirs = tempDirs();
  cfg = testCfg(fx);
  ctx = await openBrowser({ profileDir: dirs.profile, downloadDir: dirs.downloads, sandbox: SANDBOX });
});
after(async () => { await ctx?.close(); await fx?.close(); });

const startsPdf = (p) => fs.readFileSync(p).subarray(0, 5).toString() === '%PDF-';
const tabBlank = () => assert.deepEqual(ctx.pages().map((p) => p.url()), ['about:blank']);

for (const k of ['ok', 'linkonly', 'cdn']) {
  test(`${k}: saved, a real PDF, host is the landing host`, async () => {
    const r = await fetchOne(ctx, `10.5555/${k}`, { cfg });
    assert.equal(r.status, 'saved');
    assert.equal(r.host, H.P);
    assert.ok(startsPdf(r.tmpPdf));
    assert.ok(r.tmpPdf.startsWith(dirs.downloads + path.sep));
    tabBlank();
  });
}

test('the CDN fixture really fetched from the second host', () => {
  assert.ok(fx.hits('cdn', H.C).length >= 1);
});

const cases = [
  ['check', 'needs-owner:check', H.X],
  ['pdfcheck', 'needs-owner:check', H.P],
  ['nopdf', 'not-available:no-pdf-link', H.P],
  ['html', 'not-available:not-a-pdf', H.P],
  ['htmlpage', 'not-available:not-a-pdf', H.P],
  ['404', 'not-available:doi-not-found', ''],
  ['paywall', 'not-available:no-pdf-link', H.P],
];
for (const [k, status, host] of cases) {
  test(`${k}: ${status}`, async () => {
    const r = await fetchOne(ctx, `10.5555/${k}`, { cfg });
    assert.equal(r.status, status);
    assert.equal(r.host, host);
    assert.equal(r.tmpPdf, undefined);
    tabBlank();
  });
}

test('a non-PDF download is deleted from the download folder', () => {
  assert.deepEqual(fs.readdirSync(dirs.downloads).filter((n) => !fs.statSync(path.join(dirs.downloads, n)).isDirectory())
    .map((n) => fs.readFileSync(path.join(dirs.downloads, n)).subarray(0, 5).toString()).filter((h) => h !== '%PDF-'), []);
});

test('slow: not-available:timeout within the configured timeout', async () => {
  const t0 = Date.now();
  const r = await fetchOne(ctx, '10.5555/slow', { cfg });
  assert.equal(r.status, 'not-available:timeout');
  assert.ok(Date.now() - t0 < cfg.timeouts.navMs + 3000, `took ${Date.now() - t0} ms`);
  tabBlank();
});

// ---- through the loop: library route and "nothing moved in" ----
function loopEnv(extraCfg = {}) {
  const d = tempDirs();
  const c = testCfg(fx, extraCfg);
  const logs = [];
  const pacer = new Pacer({ statePath: path.join(d.state, 'pacing.json'), caps: c.caps });
  const go = (run = newRun()) => runOnce({ ctx, pacer, cfg: c, run, papersRoot: d.papers, controlDir: d.control,
                                            downloadDir: dirs.downloads, log: (s) => logs.push(s) });
  return { d, go, logs };
}

test('html through the loop: not-a-pdf and nothing moved into the papers folder', async () => {
  const { d, go } = loopEnv();
  request(d.papers, 'p', 'r.txt', ['10.5555/html']);
  await go();
  const st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st.map((l) => [l[0], l[1]]), [['10.5555/html', 'not-available:not-a-pdf']]);
  assert.equal(fs.existsSync(path.join(d.papers, 'p', folderName('10.5555/html'))), false);
  assert.deepEqual(allFiles(d.papers).filter((f) => !f.includes('/_fetch/')), []);
});

test('paywall with libraryPrefix: saved through the library route, library yes', async () => {
  const { d, go } = loopEnv({ libraryPrefix: fx.libraryPrefix });
  request(d.papers, 'p', 'r.txt', ['10.5555/paywall']);
  await go();
  const st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st, [['10.5555/paywall', 'saved', H.P, st[0][3], 'yes']]);
  const pdf = path.join(d.papers, 'p', folderName('10.5555/paywall'), 'paper.pdf');
  assert.ok(startsPdf(pdf));
  const md = fs.readFileSync(path.join(path.dirname(pdf), 'metadata.md'), 'utf8');
  assert.match(md, /Library route: yes/);
  assert.ok(fx.hits('paywall', H.Y).length === 1);
});

test('paywall without libraryPrefix: no-pdf-link, no library request', async () => {
  const before = fx.log.filter((e) => e.host === H.Y).length;
  const { d, go } = loopEnv();
  request(d.papers, 'p', 'r.txt', ['10.5555/paywall']);
  await go();
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => [l[1], l[4]]), [['not-available:no-pdf-link', 'no']]);
  assert.equal(fx.log.filter((e) => e.host === H.Y).length, before);
});

test('paywall2 lands on a login host: needs-owner:login; the next paywalled DOI makes no library request', async () => {
  const { d, go, logs } = loopEnv({ libraryPrefix: fx.libraryPrefix });
  request(d.papers, 'p', 'r.txt', ['10.5555/paywall2', '10.5555/paywall3']);
  await go();
  const st = statusLines(d.papers, 'p', 'r.txt');
  assert.deepEqual(st.map((l) => [l[0], l[1]]), [['10.5555/paywall2', 'needs-owner:login'],
                                                  ['10.5555/paywall3', 'needs-owner:login']]);
  assert.equal(fx.hits('paywall2', H.Y).length, 1);
  assert.equal(fx.hits('paywall3', H.Y).length, 0);
  // The library prefix, and the login host's name, never reach the status file or the log.
  const text = fs.readFileSync(path.join(d.papers, 'p', '_fetch', 'status', 'r.tsv'), 'utf8') + logs.join('\n');
  assert.ok(!text.includes(fx.libraryPrefix) && !text.includes('/lib') && !text.includes(H.Y) && !text.includes(H.L));
});

// ---------------- fix round 1 ----------------
const settled = async (cond, ms = 3000) => {
  for (const t0 = Date.now(); Date.now() - t0 < ms;) { if (cond()) return true; await new Promise((r) => setTimeout(r, 50)); }
  return cond();
};

for (const k of ['big', 'bignolen']) {
  test(`${k}: a PDF over maxPdfBytes is refused as not-a-pdf and deleted`, async () => {
    assert.ok(BIG > cfg.maxPdfBytes);
    const before = new Set(fs.readdirSync(dirs.downloads));
    const r = await fetchOne(ctx, `10.5555/${k}`, { cfg });
    assert.equal(r.status, 'not-available:not-a-pdf');
    assert.equal(r.tmpPdf, undefined);
    assert.ok(await settled(() => fs.readdirSync(dirs.downloads).every((n) => before.has(n))), 'download left behind');
  });
}

test('big through the loop: nothing in the temp dir or the papers folder', async () => {
  const { d, go } = loopEnv();
  request(d.papers, 'p', 'r.txt', ['10.5555/big']);
  await go();
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => l[1]), ['not-available:not-a-pdf']);
  assert.deepEqual(fs.readdirSync(dirs.downloads), []);
  assert.deepEqual(allFiles(d.papers).filter((f) => !f.includes('/_fetch/')), []);
});

test('a download the landing page starts by itself is cancelled and deleted', async () => {
  const before = new Set(fs.readdirSync(dirs.downloads));
  const mark = fx.log.length;
  const r = await fetchOne(ctx, '10.5555/autodl', { cfg });
  assert.equal(r.status, 'not-available:no-pdf-link');
  assert.ok(fx.log.slice(mark).some((e) => e.path === '/files/junk.bin'), 'fixture did not start its download');
  assert.ok(await settled(() => fs.readdirSync(dirs.downloads).every((n) => before.has(n))), 'stray download left behind');
});

test('autodl through the loop leaves the temp dir empty', async () => {
  const { d, go } = loopEnv();
  request(d.papers, 'p', 'r.txt', ['10.5555/autodl']);
  await go();
  assert.deepEqual(fs.readdirSync(dirs.downloads), []);
});

test('in-fetch guard: a redirect onto a blocked host is classified but no PDF is requested', async () => {
  const mark = fx.log.length;
  const r = await fetchOne(ctx, '10.5555/via1', { cfg, blocked: new Set([H.X]) });
  assert.equal(r.status, 'skipped:host-challenged');
  assert.equal(r.host, H.X);
  assert.equal(fx.log.slice(mark).filter((e) => e.path.startsWith('/pdf/')).length, 0);
  tabBlank();
});

test('a page that moves itself to another host is not sent through the library route', async () => {
  const { d, go } = loopEnv({ libraryPrefix: fx.libraryPrefix });
  const before = fx.log.filter((e) => e.host === H.Y).length;
  request(d.papers, 'p', 'r.txt', ['10.5555/jsmove']);
  await go();
  assert.ok(fx.hits('jsmove', H.V).length >= 1, 'fixture page did not move');
  assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => [l[1], l[4]]), [['not-available:no-pdf-link', 'no']]);
  assert.equal(fx.log.filter((e) => e.host === H.Y).length, before);
});

test('resolver Location handling: non-http and missing are http-error; relative is resolved', async () => {
  assert.deepEqual(await resolveDoi(ctx, '10.5555/locjs', { cfg }), { status: 'not-available:http-error' });
  assert.deepEqual(await resolveDoi(ctx, '10.5555/locnone', { cfg }), { status: 'not-available:http-error' });
  assert.deepEqual(await resolveDoi(ctx, '10.5555/locrel', { cfg }), { url: `${fx.base(H.R)}/relative/locrel`, host: H.R });
  assert.deepEqual(await resolveDoi(ctx, '10.5555/404', { cfg }), { status: 'not-available:doi-not-found' });
});

test('a declared Content-Length over the cap is refused before the body arrives (attachment)', async () => {
  // slowpdf declares 10 MB and then stalls after a few bytes: only the declared length
  // can refuse it; without that check it would end as a timeout.
  const t0 = Date.now();
  const r = await fetchOne(ctx, '10.5555/slowpdf', { cfg });
  assert.equal(r.status, 'not-available:not-a-pdf');
  assert.ok(Date.now() - t0 < cfg.timeouts.downloadMs, `took ${Date.now() - t0} ms`);
});
