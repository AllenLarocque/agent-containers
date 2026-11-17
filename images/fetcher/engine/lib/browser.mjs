// Playwright specifics: open the session-holding browser, resolve a DOI, fetch one paper.
// No page content leaves this module except as a fixed status code and a host name;
// URLs found on pages are used only to navigate (landingUrl is returned for the library
// route and must never be written or logged by callers).
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';
import { isCheck, isLoginHost, pickPdfUrl, directPdfUrl, hostOf } from './classify.mjs';

const DEFAULT_TIMEOUTS = { navMs: 60000, settleMs: 9000, downloadMs: 45000 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
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
  return chromium.launchPersistentContext(profileDir, {
    headless: false,
    chromiumSandbox: sandbox !== false,
    acceptDownloads: true,
    downloadsPath: downloadDir,
    viewport: { width: 1280, height: 900 },
  });
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
      let next = '';
      try { next = new URL(r.headers().location ?? '', start).href; } catch { /* bad location */ }
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

function startsPdf(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const b = Buffer.alloc(5);
    return fs.readSync(fd, b, 0, 5, 0) === 5 && b.toString('latin1') === '%PDF-';
  } finally {
    fs.closeSync(fd);
  }
}

// Navigate to the PDF URL; a download is the expected outcome. -> {status, tmpPdf?, checkHost?}
async function download(page, url, t) {
  const dlP = page.waitForEvent('download', { timeout: t.navMs }).then((d) => ({ d }), () => ({}));
  const navP = page.goto(url, { waitUntil: 'domcontentloaded', timeout: t.navMs }).then((r) => ({ r }), (e) => ({ e }));
  const first = await Promise.race([dlP, navP]);
  let dl = first.d;
  if (!dl) {
    // A page loaded (or the navigation was aborted by a starting download): give a
    // download a moment to appear before judging the page.
    const later = await Promise.race([dlP, sleep(first.e ? 2000 : t.settleMs).then(() => ({}))]);
    dl = later.d;
  }
  if (!dl) {
    const nav = await navP;
    if (nav.e) return { status: failed(nav.e) };
    if (isCheck(await readPage(page))) return { status: 'needs-owner:check', checkHost: hostOf(page.url()) };
    if (nav.r && nav.r.status() >= 400) return { status: 'not-available:http-error' };
    return { status: 'not-available:not-a-pdf' };
  }
  const TIMEOUT = Symbol('timeout');
  const file = await Promise.race([dl.path().catch(() => null), sleep(t.downloadMs).then(() => TIMEOUT)]);
  if (file === TIMEOUT) {
    await dl.cancel().catch(() => {});
    await dl.delete().catch(() => {});
    return { status: 'not-available:timeout' };
  }
  if (!file) return { status: 'not-available:http-error' };
  if (!startsPdf(file)) {
    fs.rmSync(file, { force: true });
    return { status: 'not-available:not-a-pdf' };
  }
  return { status: 'saved', tmpPdf: file };
}

async function attempt(page, doi, { cfg, library, url, blocked, t }) {
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
  const landingUrl = page.url();
  const host = hostOf(landingUrl);
  const code = resp ? resp.status() : 0;

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
  return { ...(await download(page, pdfUrl, t)), host, landingUrl };
}

// One attempt at one paper. -> {status, host, tmpPdf?, checkHost?, landingUrl?}
// url: start here instead of resolver+doi (direct), or the landing URL to send through
// the library prefix (library). blocked: hosts challenged this run; never contacted from
// here once known (a page reached by redirect is classified but not followed further).
export async function fetchOne(ctx, doi, { cfg, library = false, url = '', blocked = new Set() }) {
  const t = { ...DEFAULT_TIMEOUTS, ...cfg.timeouts };
  const page = ctx.pages()[0] ?? await ctx.newPage();
  try {
    return await attempt(page, doi, { cfg, library, url, blocked, t });
  } catch (e) {
    if (e instanceof TypeError) throw e;
    return { status: failed(e), host: hostOf(page.url()) };
  } finally {
    await page.goto('about:blank', { timeout: 10000 }).catch(() => {});
    for (const p of ctx.pages()) if (p !== page) await p.close().catch(() => {});
  }
}
