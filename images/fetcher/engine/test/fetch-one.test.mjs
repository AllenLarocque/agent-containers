// Real Chromium (headed, on the harness's Xvfb display) against the fixture server.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fetchOne, resolveDoi, PROFILES } from '../lib/browser.mjs';
import { runOnce, newRun } from '../fetcher.mjs';
import { Pacer } from '../lib/pacing.mjs';
import { folderName } from '../lib/doi.mjs';
import { startFixtureServer, H, BIG } from './fixture-server.mjs';
import { testCfg, tempDirs, request, statusLines, allFiles, browsersFor } from './helpers.mjs';

let fx, dirs, browsers, ctx, cfg;
before(async () => {
  fx = await startFixtureServer();
  dirs = tempDirs();
  cfg = testCfg(fx);
  browsers = browsersFor(fx, dirs);
  ctx = await browsers.direct();          // the direct browser (a Browser; it survives restarts)
});
after(async () => { await browsers?.close(); await fx?.close(); });

const startsPdf = (p) => fs.readFileSync(p).subarray(0, 5).toString() === '%PDF-';
const tabBlank = () => assert.deepEqual(ctx.ctx.pages().map((p) => p.url()), ['about:blank']);

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
  const go = (run = newRun()) => runOnce({ browsers, pacer, cfg: c, run, papersRoot: d.papers, controlDir: d.control,
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

test('in-fetch guard: a redirect onto a blocked host is refused before that host is contacted', async () => {
  const mark = fx.log.length;
  const r = await fetchOne(ctx, '10.5555/via1', { cfg, navCheck: (h) => (h === H.X ? 'skipped:host-challenged' : null) });
  assert.equal(r.status, 'skipped:host-challenged');
  assert.equal(r.host, H.X);
  assert.equal(fx.log.slice(mark).filter((e) => e.path.startsWith('/pdf/')).length, 0);
  assert.equal(fx.log.slice(mark).filter((e) => e.host === H.X).length, 0, 'the blocked host was contacted');
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

// ---------------- final fix wave: a page must not hang the fetcher (B) ----------------
const pageCases = [
  ['busy', 'a busy loop right after load'],
  ['busypdf', 'a busy loop on the PDF page'],
  ['neverload', 'a page that never finishes loading'],
  ['dialog', 'alert/confirm/prompt in a loop and a beforeunload handler'],
];
for (const [k, what] of pageCases) {
  test(`${what}: not-available:timeout within the deadline, and the next paper in the run is saved`, async () => {
    const { d, go } = loopEnv();
    request(d.papers, 'p', 'r.txt', [`10.5555/${k}`, '10.5555/good7']);
    const t0 = Date.now();
    await go();
    const took = Date.now() - t0;
    assert.deepEqual(statusLines(d.papers, 'p', 'r.txt').map((l) => [l[0], l[1]]),
      [[`10.5555/${k}`, 'not-available:timeout'], ['10.5555/good7', 'saved']]);
    assert.ok(took < 30000, `took ${took} ms`);
    tabBlank();
  });
}

test('the per-visit deadline cuts a hung page off even when every page timeout is longer', async () => {
  const c = testCfg(fx, { timeouts: { navMs: 20000, settleMs: 300, downloadMs: 20000 }, paperDeadlineMs: 2500 });
  const t0 = Date.now();
  const r = await fetchOne(ctx, '10.5555/busy', { cfg: c });
  const took = Date.now() - t0;
  assert.equal(r.status, 'not-available:timeout');
  assert.ok(took < 9000, `took ${took} ms (the page call alone would wait 10 s)`);
  const ok = await fetchOne(ctx, '10.5555/ok', { cfg });
  assert.equal(ok.status, 'saved');
  tabBlank();
});

// ---------------- one tab, and it goes only where the engine sends it (C) ----------------
test('popups opened during a fetch are closed and make no request; the paper is still saved', async () => {
  const mark = fx.log.length;
  const r = await fetchOne(ctx, '10.5555/popup', { cfg });
  assert.equal(r.status, 'saved');
  assert.equal(ctx.ctx.pages().length, 1);
  assert.deepEqual(fx.log.slice(mark).filter((e) => /^popup(win|late|blank)$/.test(e.key)), []);
  tabBlank();
});

test('a page that moves itself to a loopback address is blocked: no request reaches it', async () => {
  const mark = fx.log.length;
  const r = await fetchOne(ctx, '10.5555/goloop', { cfg });
  assert.notEqual(r.status, 'saved');
  assert.ok(fx.log.slice(mark).some((e) => e.key === 'goloop'), 'fixture not visited');
  assert.deepEqual(fx.log.slice(mark).filter((e) => e.host === H.F), []);
  tabBlank();
});

test('a redirect hop to a loopback address is blocked (the guard sees redirect hops)', async () => {
  const mark = fx.log.length;
  const r = await fetchOne(ctx, '10.5555/redirloop', { cfg });
  assert.notEqual(r.status, 'saved');
  assert.ok(fx.log.slice(mark).some((e) => e.key === 'redirloop' && e.host === H.P), 'fixture not visited');
  assert.deepEqual(fx.log.slice(mark).filter((e) => e.host === H.F), []);
});

test('WebSockets, images and fetch() to loopback addresses or localhost are blocked', async () => {
  const mark = fx.log.length;
  await fetchOne(ctx, '10.5555/wsloop', { cfg });
  await new Promise((r) => setTimeout(r, 300));
  const bad = fx.log.slice(mark).filter((e) => e.host === H.F || e.host === 'localhost' || e.key === 'websocket');
  assert.deepEqual(bad, []);
  assert.ok(fx.log.slice(mark).some((e) => e.key === 'wsloop'), 'fixture not visited');
});

test('a PDF link to a challenged host, or a PDF redirect onto one, is not followed: no load of that host', async () => {
  const mark = fx.log.length;
  const challenged = (h) => (h === H.X ? 'skipped:host-challenged' : null);
  for (const k of ['pdfx', 'pdfxr']) {
    const r = await fetchOne(ctx, `10.5555/${k}`, { cfg, navCheck: challenged });
    assert.equal(r.status, 'skipped:host-challenged', k);
  }
  assert.deepEqual(fx.log.slice(mark).filter((e) => e.host === H.X), []);
});

test('only the engine\'s own PDF navigation can download: a page-started download is cancelled', async () => {
  const before = new Set(fs.readdirSync(dirs.downloads));
  const r = await fetchOne(ctx, '10.5555/autodl', { cfg });
  assert.equal(r.status, 'not-available:no-pdf-link');
  assert.ok(await settled(() => fs.readdirSync(dirs.downloads).every((n) => before.has(n))), 'stray download left behind');
});

// ---------------- two browser profiles (D) ----------------
test('a direct visit and a library-routed visit use different profiles: neither sees the other\'s cookies', async () => {
  const c = testCfg(fx, { libraryPrefix: fx.libraryPrefix });
  const lib = await browsers.library();
  try {
    assert.ok(lib.profileDir.endsWith(`/${PROFILES.library}`) && ctx.profileDir.endsWith(`/${PROFILES.direct}`));
    let mark = fx.log.length;
    // library visit to P sets cklib; direct visit to P sets ckdirect
    assert.equal((await fetchOne(lib, '10.5555/cklib', { cfg: c, library: true, url: `${fx.base(H.P)}/article/cklib` })).status, 'saved');
    assert.ok(fx.log.slice(mark).some((e) => e.key === 'cklib' && e.host === H.Y), 'not library-routed');
    mark = fx.log.length;
    assert.equal((await fetchOne(ctx, '10.5555/ckdirect', { cfg: c, url: `${fx.base(H.P)}/article/ckdirect` })).status, 'saved');
    const direct = fx.log.slice(mark).filter((e) => e.host === H.P);
    assert.ok(direct.length >= 1);
    assert.ok(direct.every((e) => !e.cookie.includes('cklib')), JSON.stringify(direct));
    mark = fx.log.length;
    assert.equal((await fetchOne(lib, '10.5555/cklibtwo', { cfg: c, library: true, url: `${fx.base(H.P)}/article/cklibtwo` })).status, 'saved');
    const libv = fx.log.slice(mark).filter((e) => e.host === H.P);
    assert.ok(libv.length >= 1 && libv.some((e) => e.cookie.includes('cklib=1')), JSON.stringify(libv));
    assert.ok(libv.every((e) => !e.cookie.includes('ckdirect')), JSON.stringify(libv));
  } finally {
    await browsers.closeLibrary();
  }
  assert.equal(browsers.libraryOpen, false);
});
