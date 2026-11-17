// Playwright specifics: open the session-holding browser, resolve a DOI, fetch one paper.
// No page content leaves this module except as a fixed status code and a host name;
// URLs found on pages are used only to navigate (landingUrl is returned for the library
// route and must never be written or logged by callers).
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';
import { isCheck, isLoginHost, pickPdfUrl, directPdfUrl, hostOf } from './classify.mjs';

const DEFAULT_TIMEOUTS = { navMs: 60000, settleMs: 9000, downloadMs: 45000 };
const DEFAULT_MAX_PDF_BYTES = 104857600;
// Unref'd: a timer used only in a race must not keep a finished process alive (the open
// browser keeps the process alive while it is in use).
const sleep = (ms) => new Promise((r) => setTimeout(r, ms).unref());
const downloadDirs = new WeakMap();          // ctx -> its downloads folder
const isTimeout = (e) => e?.name === 'TimeoutError';
const failed = (e) => (isTimeout(e) ? 'not-available:timeout' : 'not-available:http-error');

// Make Chromium download PDFs instead of opening its viewer, keeping any other prefs the
// persistent profile already has. The profile volume is the fetcher's own.
function setPdfPref(profileDir) {
  const p = path.join(profileDir, 'Default', 'Preferences');
  fs.mkdirSync(path.dirname(p), { recursive: true });
  let prefs = {};
  try { prefs = JSON.parse(fs.readFileSync(p, 'utf8')); } catch { /* missing or unreadable: start fresh */ }
  if (prefs === null || typeof prefs !== 'object' || Array.isArray(prefs)) prefs = {};
  prefs.plugins = { ...(prefs.plugins ?? {}), always_open_pdf_externally: true };
  prefs.download = { ...(prefs.download ?? {}), prompt_for_download: false };
  fs.writeFileSync(p, JSON.stringify(prefs));
}

// sandbox stays on. It is a parameter only so the test harness can run in a container
// without the seccomp profile the fetcher image provides; production never passes it.
export async function openBrowser({ profileDir, downloadDir, sandbox = true }) {
  setPdfPref(profileDir);
  fs.mkdirSync(downloadDir, { recursive: true });
  const ctx = await chromium.launchPersistentContext(profileDir, {
    headless: false,
    chromiumSandbox: sandbox !== false,
    acceptDownloads: true,
    downloadsPath: downloadDir,
    viewport: { width: 1280, height: 900 },
  });
  downloadDirs.set(ctx, downloadDir);
  return ctx;
}

// Ask the resolver where a DOI goes, without following the redirect, so the caller can
// pace and skip by publisher host before the browser contacts that host.
// -> {url, host} or {status}
export async function resolveDoi(ctx, doi, { cfg }) {
  const t = { ...DEFAULT_TIMEOUTS, ...cfg.timeouts };
  const start = cfg.resolver + doi;
  let r;
  try {
    r = await ctx.request.get(start, { maxRedirects: 0, timeout: t.navMs, failOnStatusCode: false });
  } catch (e) {
    return { status: failed(e) };
  }
  try {
    const code = r.status();
    if (code === 404) return { status: 'not-available:doi-not-found' };
    if (code >= 300 && code < 400) {
      const loc = r.headers().location;
      let next = '';
      // A missing or empty Location is an error (resolving '' would give back the
      // resolver URL itself); a relative one resolves against the resolver URL.
      if (typeof loc === 'string' && loc.trim() !== '') {
        try { next = new URL(loc, start).href; } catch { /* bad location */ }
      }
      if (!hostOf(next)) return { status: 'not-available:http-error' };
      return { url: next, host: hostOf(next) };
    }
    if (code >= 400) return { status: 'not-available:http-error' };
    return { url: start, host: hostOf(start) };
  } finally {
    await r.dispose().catch(() => {});
  }
}

async function readPage(page) {
  const title = await page.title().catch(() => '');
  const text = await page.locator('body').innerText({ timeout: 5000 }).catch(() => '');
  return { title: String(title), text: String(text).slice(0, 3000) };
}

async function findPdf(page) {
  const meta = await page.locator('meta[name="citation_pdf_url"]').first()
    .getAttribute('content', { timeout: 1000 }).catch(() => null);
  const hrefs = await page.locator('a[href]').evaluateAll((as) => as.slice(0, 2000).map((a) => a.href)).catch(() => []);
  return pickPdfUrl({
    meta: typeof meta === 'string' ? meta : '',
    hrefs: Array.isArray(hrefs) ? hrefs.filter((h) => typeof h === 'string') : [],
  }, page.url());
}

// A regular file of at most max bytes (fstat on the open descriptor) starting %PDF-.
function startsPdf(file, max) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > max) return false;
    const b = Buffer.alloc(5);
    return fs.readSync(fd, b, 0, 5, 0) === 5 && b.toString('latin1') === '%PDF-';
  } finally {
    fs.closeSync(fd);
  }
}

const names = (dir) => { try { return fs.readdirSync(dir); } catch { return []; } };

// Bytes in downloads-folder entries that were not there before (only the one wanted
// download may be running; any other is cancelled).
function bytesIn(dir, before) {
  let n = 0;
  for (const e of names(dir)) {
    if (before.has(e)) continue;
    try { n += fs.lstatSync(path.join(dir, e)).size; } catch { /* gone */ }
  }
  return n;
}

// Wait for a started download to finish, refusing it once it is larger than max.
async function finish(dl, t, max, dir, before, tooBig) {
  const DONE = Symbol('done');
  let state = null;
  const pathP = dl.path().then((p) => { state = DONE; return p; }, () => { state = DONE; return null; });
  for (const t0 = Date.now(); state === null;) {
    if (tooBig() || bytesIn(dir, before) > max) return { status: 'not-available:not-a-pdf' };
    if (Date.now() - t0 > t.downloadMs) return { status: 'not-available:timeout' };
    await Promise.race([pathP, sleep(200)]);
  }
  const file = await pathP;
  if (!file) return { status: 'not-available:http-error' };
  if (tooBig() || !startsPdf(file, max)) return { status: 'not-available:not-a-pdf' };
  return { status: 'saved', tmpPdf: file };
}

// Navigate to the PDF URL; a download is the expected outcome. -> {status, tmpPdf?, checkHost?}
// guard.want receives the first download started while it is set; every other download
// is cancelled and deleted by fetchOne's listener.
async function download(page, url, t, guard, max, dir) {
  // Size cap, three ways: a declared Content-Length (Chromium reports the response for
  // attachments; for a PDF turned into a download by the viewer preference it does not),
  // the bytes on disk while the download runs, and fstat before the file is handed on.
  let declaredTooBig = false;
  const onResponse = (r) => {
    const len = Number(r.headers()['content-length']);
    if (r.request().isNavigationRequest() && Number.isFinite(len) && len > max) declaredTooBig = true;
  };
  page.on('response', onResponse);
  const before = new Set(names(dir));
  const dlP = new Promise((res) => { guard.want = (d) => res({ d }); });
  try {
    // Page-chosen URL, http(s) only (classify.pickPdfUrl). Private and link-local
    // addresses are blocked by the container's firewall, not here; page script could
    // reach them anyway.
    const navP = page.goto(url, { waitUntil: 'domcontentloaded', timeout: t.navMs }).then((r) => ({ r }), (e) => ({ e }));
    const first = await Promise.race([dlP, navP, sleep(t.navMs + 1000).then(() => ({}))]);
    let dl = first.d;
    if (!dl) {
      // A page loaded (or the navigation was aborted by a starting download): give a
      // download a moment to appear before judging the page.
      const later = await Promise.race([dlP, sleep(first.e ? 2000 : t.settleMs).then(() => ({}))]);
      dl = later.d;
    }
    guard.want = null;
    if (dl) {
      const out = await finish(dl, t, max, dir, before, () => declaredTooBig);
      if (out.status !== 'saved') {
        await dl.cancel().catch(() => {});
        await dl.delete().catch(() => {});
      }
      return out;
    }
    return await judgePage(page, await navP);
  } finally {
    guard.want = null;
    page.off('response', onResponse);
  }
}

async function judgePage(page, nav) {
  if (nav.e) return { status: failed(nav.e) };
  if (isCheck(await readPage(page))) return { status: 'needs-owner:check', checkHost: hostOf(page.url()) };
  if (nav.r && nav.r.status() >= 400) return { status: 'not-available:http-error' };
  return { status: 'not-available:not-a-pdf' };
}

async function attempt(page, doi, { cfg, library, url, blocked, t, guard, max, dir }) {
  let start;
  if (library) {
    if (!cfg.libraryPrefix || !hostOf(url)) throw new TypeError('library route needs libraryPrefix and a landing URL');
    start = cfg.libraryPrefix + encodeURIComponent(url);
  } else {
    start = url || cfg.resolver + doi;
  }
  let resp;
  try {
    resp = await page.goto(start, { waitUntil: 'domcontentloaded', timeout: t.navMs });
  } catch (e) {
    return { status: failed(e), host: '' };
  }
  await sleep(t.settleMs);                      // let redirects and interstitials settle
  const host = hostOf(page.url());
  const code = resp ? resp.status() : 0;
  // The landing URL may be sent through the library prefix later. page.url() is under
  // page script's control, so it is offered only while it is still on the host the
  // navigation's redirect chain ended on.
  const navHost = resp ? hostOf(resp.url()) : '';
  const landingUrl = navHost && hostOf(page.url()) === navHost ? page.url() : undefined;

  // Decided by host name only, and only after a library-routed visit.
  if (library && isLoginHost(host, cfg)) return { status: 'needs-owner:login', host };
  if (isCheck(await readPage(page))) return { status: 'needs-owner:check', host, checkHost: host };
  if (!library && !url && code === 404 && host === hostOf(cfg.resolver)) return { status: 'not-available:doi-not-found', host: '' };
  if (code >= 400) return { status: 'not-available:http-error', host, landingUrl };
  if (blocked.has(host)) return { status: 'skipped:host-challenged', host };

  const found = await findPdf(page);
  if (!found) return { status: 'not-available:no-pdf-link', host, landingUrl };
  const pdfUrl = directPdfUrl(found);
  if (blocked.has(hostOf(pdfUrl))) return { status: 'skipped:host-challenged', host };
  return { ...(await download(page, pdfUrl, t, guard, max, dir)), host, landingUrl };
}

// One attempt at one paper. -> {status, host, tmpPdf?, checkHost?, landingUrl?}
// url: start here instead of resolver+doi (direct), or the landing URL to send through
// the library prefix (library). blocked: hosts challenged this run; never contacted from
// here once known (a page reached by redirect is classified but not followed further).
// Any download other than the one asked for (e.g. one a landing page starts by itself)
// is cancelled and deleted.
export async function fetchOne(ctx, doi, { cfg, library = false, url = '', blocked = new Set() }) {
  const t = { ...DEFAULT_TIMEOUTS, ...cfg.timeouts };
  const max = cfg.maxPdfBytes ?? DEFAULT_MAX_PDF_BYTES;
  const dir = downloadDirs.get(ctx) ?? '';
  const guard = { want: null };
  const onDownload = (d) => {
    const want = guard.want;
    guard.want = null;
    if (want) return want(d);
    d.cancel().catch(() => {}).then(() => d.delete().catch(() => {}));
  };
  const watch = (p) => p.on('download', onDownload);
  ctx.pages().forEach(watch);
  ctx.on('page', watch);
  const page = ctx.pages()[0] ?? await ctx.newPage();
  try {
    return await attempt(page, doi, { cfg, library, url, blocked, t, guard, max, dir });
  } catch (e) {
    if (e instanceof TypeError) throw e;
    return { status: failed(e), host: hostOf(page.url()) };
  } finally {
    await page.goto('about:blank', { timeout: 10000 }).catch(() => {});
    for (const p of ctx.pages()) if (p !== page) await p.close().catch(() => {});
    ctx.off('page', watch);
    for (const p of ctx.pages()) p.off('download', onDownload);
  }
}
