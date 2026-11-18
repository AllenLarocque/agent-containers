// Playwright specifics: the two session-holding browsers, their guards, resolving a DOI and
// fetching one paper. No page content leaves this module except as a fixed status code and a
// host name; URLs found on pages are used only to navigate (landingUrl is returned for the
// library route and must never be written or logged by callers).
//
// Two browsers, each a persistent Chromium profile under one folder (/home/agent/.fetcher):
//   profile-direct   ordinary visits (doi.org and publishers) and the owner's check pages; holds
//                    publisher cookies, including any bot-check clearance the owner earned.
//   profile-library  library sign-in and library-routed visits only; holds the library session.
//                    Launched only when needed and closed again when idle.
// A page visited directly never runs in the library profile.
//
// Guards, on both browsers, at all times (Browser.launch):
//   - one tab: any other page (a popup, window.open, target=_blank) has every request aborted and
//     is closed at once;
//   - no request to a forbidden host (classify.forbiddenUrl: loopback, private, link-local, ...)
//     or a non-http(s) scheme: Playwright's context routing for the requests it sees (every page,
//     popups included, but not redirect hops), plus the DevTools Fetch domain on the engine's own
//     tab, which also pauses redirect hops; WebSockets to such hosts are refused through
//     Playwright's WebSocket routing (a script shim in each page: see the design's amendments);
//   - downloads: only the one that results from the engine's own navigation to the chosen PDF URL
//     in the engine's tab is accepted; every other is cancelled and deleted;
//   - dialogs are answered at once (beforeunload: leave; everything else: dismiss);
//   - while fetching, the tab's main frame may not go to a host challenged this run or over its
//     per-host cap (the caller's navCheck); while the owner has a page, it may not leave the hosts
//     of that page (host lock): it is blanked instead.
// Every call that touches a page has a timeout, and every visit has a hard deadline enforced by
// a timer that does not depend on the page: an unresponsive page ends the visit as
// not-available:timeout and the browser is killed and relaunched before anything else.
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';
import { isCheck, isLoginHost, pickPdfUrl, directPdfUrl, hostOf, forbiddenUrl } from './classify.mjs';

export const PROFILES = Object.freeze({ direct: 'profile-direct', library: 'profile-library' });
const DEFAULT_TIMEOUTS = { navMs: 60000, settleMs: 9000, downloadMs: 45000 };
const DEFAULT_MAX_PDF_BYTES = 104857600;
const CLOSE_MS = 5000;                       // closing a page or a context, blanking the tab
const PARK = { left: -4000, top: 0 };        // off the display: there is no window manager, so minimising does nothing
const HOME = { left: 0, top: 0 };
// Unref'd: a timer used only in a race must not keep a finished process alive (the open
// browser keeps the process alive while it is in use).
const sleep = (ms) => new Promise((r) => setTimeout(r, ms).unref());
const isTimeout = (e) => e?.name === 'TimeoutError';
const failed = (e) => (isTimeout(e) ? 'not-available:timeout' : 'not-available:http-error');

export const timeoutsOf = (cfg) => ({ ...DEFAULT_TIMEOUTS, ...cfg.timeouts });
// The hard limit on one visit: cfg.paperDeadlineMs (PAPER_DEADLINE_MS), else navigation + settle +
// download timeouts + 30 s.
export const deadlineMs = (cfg) => {
  const t = timeoutsOf(cfg);
  return cfg.paperDeadlineMs ?? t.navMs + t.settleMs + t.downloadMs + 30000;
};
// A page call's own limit (the deadline is the backstop).
const callMs = (t) => Math.min(t.navMs, 10000);

// The page did not answer a call in time (a busy loop, a blocked renderer).
export class PageHung extends Error {
  constructor() { super('page did not respond'); this.name = 'PageHung'; }
}
const within = (p, ms) => {
  let timer;
  return Promise.race([p, new Promise((_, rej) => { timer = setTimeout(() => rej(new PageHung()), ms); timer.unref(); })])
    .finally(() => clearTimeout(timer));
};

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

// Every process of this user whose command line names this profile (the browser and its helpers).
function profilePids(profileDir) {
  const out = [];
  let pids = [];
  try { pids = fs.readdirSync('/proc').filter((n) => /^[0-9]+$/.test(n) && Number(n) !== process.pid); } catch { return out; }
  for (const pid of pids) {
    let args;
    try { args = fs.readFileSync(`/proc/${pid}/cmdline`, 'latin1').split('\0'); } catch { continue; }
    if (args.some((a) => a === `--user-data-dir=${profileDir}` || a.includes(`${profileDir}/`))) out.push(Number(pid));
  }
  return out;
}
async function killProfile(profileDir) {
  for (let i = 0; i < 50; i++) {
    const pids = profilePids(profileDir);
    if (!pids.length) return;
    for (const pid of pids) { try { process.kill(pid, 'SIGKILL'); } catch { /* gone */ } }
    await sleep(100);
  }
}

// One persistent browser with its single tab and its guards.
export class Browser {
  // sandbox stays on: it is a parameter only so the test harness can run in a container without
  // the seccomp profile the fetcher image provides. testOnlyAllow: "host:port" pairs exempt from
  // the forbidden-host guard, for the tests' loopback fixture server. Production never passes
  // either (fetcher.mjs runLoop takes them only from its caller's options, which parseArgs never
  // produces; the config file and the environment have no such setting).
  constructor({ kind, profileDir, downloadDir, sandbox = true, testOnlyAllow = [] }) {
    this.kind = kind;
    this.profileDir = profileDir;
    this.downloadDir = downloadDir;
    this.sandbox = sandbox !== false;
    this.allow = new Set(testOnlyAllow);
    this.ctx = null;
    this.page = null;
    this.mode = { kind: 'idle' };
    this.want = null;                        // receives the one wanted download (download())
  }

  get open() { return this.ctx !== null; }
  forbidden(url) { return forbiddenUrl(url, this.allow); }

  async launch() {
    setPdfPref(this.profileDir);
    fs.mkdirSync(this.downloadDir, { recursive: true });
    const ctx = await chromium.launchPersistentContext(this.profileDir, {
      headless: false,
      chromiumSandbox: this.sandbox,
      acceptDownloads: true,
      downloadsPath: this.downloadDir,
      viewport: { width: 1280, height: 900 },
      serviceWorkers: 'block',
      args: ['--window-position=0,0'],
    });
    this.ctx = ctx;
    this.mode = { kind: 'idle' };
    this.want = null;
    const [first, ...rest] = ctx.pages();
    this.page = first ?? await ctx.newPage();
    this.#watch(this.page);
    for (const p of rest) this.#extra(p);
    ctx.on('page', (p) => { if (p !== this.page) this.#extra(p); });
    await ctx.route(() => true, (route) => this.#route(route));
    await ctx.routeWebSocket((u) => this.forbidden(u.href), (ws) => ws.close({ code: 1008, reason: 'blocked' }));
    // The DevTools Fetch domain on the engine's tab: sees every request of the tab, redirect hops
    // included (Playwright's routing continues redirect hops without asking).
    this.cdp = await ctx.newCDPSession(this.page);
    const tree = await this.cdp.send('Page.getFrameTree');
    this.mainId = tree.frameTree.frame.id;
    this.cdp.on('Fetch.requestPaused', (e) => this.#paused(e));
    await this.cdp.send('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Request' }] });
    this.page.on('framenavigated', (f) => { if (f === this.page?.mainFrame()) this.#committed(f.url()); });
    return this;
  }

  // Downloads and dialogs, on every page this browser ever has.
  #watch(p) {
    p.on('download', (d) => {
      const w = this.want;
      if (w && p === this.page && w(d)) { this.want = null; return; }
      d.cancel().catch(() => {}).then(() => d.delete().catch(() => {}));
    });
    p.on('dialog', (d) => (d.type() === 'beforeunload' ? d.accept() : d.dismiss()).catch(() => {}));
  }

  #extra(p) {
    this.#watch(p);
    p.close().catch(() => {});
  }

  // Why a request may not go ahead, or null. main: a navigation of the engine's tab's main frame.
  #verdict(url, main) {
    if (this.forbidden(url)) return 'forbidden';
    if (!main) return null;
    const host = hostOf(url);
    const m = this.mode;
    if (m.kind === 'fetch') {
      m.visit.navUrls.add(noHash(url));
      const why = m.visit.navCheck(host);
      if (why) { m.visit.stopped ??= { status: why, host }; return why; }
    } else if (m.kind === 'owner' && m.locked && !m.allow(host)) {
      this.#leave();
      return 'left';
    }
    return null;
  }

  #route(route) {
    const req = route.request();
    let nav = false;
    let frame = null;
    try { nav = req.isNavigationRequest(); } catch { /* not known: treated as a subresource */ }
    try { frame = req.frame(); } catch { /* a worker's request, or a frame not attached yet */ }
    const page = frame ? frame.page() : null;
    // A navigation of anything but the engine's tab (a popup's first load included, whose frame
    // may not be known yet), or any request of another page, is aborted.
    const other = (nav && page !== this.page) || (page && page !== this.page);
    const main = nav && !other && frame === this.page?.mainFrame();
    const no = other ? 'other-tab' : this.#verdict(req.url(), main);
    return (no ? route.abort('blockedbyclient') : route.continue()).catch(() => {});
  }

  #paused(e) {
    const main = e.resourceType === 'Document' && e.frameId === this.mainId;
    const no = this.#verdict(e.request.url, main);
    const cdp = this.cdp;
    (no ? cdp.send('Fetch.failRequest', { requestId: e.requestId, errorReason: 'BlockedByClient' })
        : cdp.send('Fetch.continueRequest', { requestId: e.requestId })).catch(() => {});
  }

  // Where the main frame committed (also error pages and same-document moves).
  #committed(url) {
    const m = this.mode;
    if (m.kind !== 'owner' || !m.locked || url === 'about:blank') return;
    if (!m.allow(hostOf(url))) this.#leave();
  }

  // The owner's page left its hosts: blank it, end the owner mode, tell the caller (once).
  #leave() {
    const m = this.mode;
    if (m.kind !== 'owner') return;
    this.mode = { kind: 'idle' };
    this.page?.goto('about:blank', { timeout: CLOSE_MS }).catch(() => {});
    m.onLeave?.();
  }

  // The tab back to about:blank, other tabs closed; false if the page did not let go in time.
  // A refused navigation still commits its error page a moment later, so the tab is checked again
  // after a short wait.
  async blank() {
    if (!this.open) return true;
    this.mode = { kind: 'idle' };
    this.want = null;
    for (const p of this.ctx.pages()) if (p !== this.page) await within(p.close(), CLOSE_MS).catch(() => {});
    for (let i = 0; i < 3; i++) {
      const ok = await within(this.page.goto('about:blank', { timeout: CLOSE_MS }), CLOSE_MS + 1000).then(() => true, (e) => !(e instanceof PageHung) && null);
      if (ok === false) return false;
      await sleep(50);
      if (ok && this.page.url() === 'about:blank') return true;
    }
    return this.page.url() === 'about:blank';
  }

  // Blank, or kill and relaunch if the page does not let go.
  async reset() {
    if (!(await this.blank())) await this.restart();
  }

  // Close politely with a short timeout, then kill whatever is left of this profile's processes.
  async close() {
    const ctx = this.ctx;
    this.ctx = null;
    this.page = null;
    this.mode = { kind: 'idle' };
    this.want = null;
    if (ctx) await within(ctx.close(), CLOSE_MS).catch(() => {});
    await killProfile(this.profileDir);
  }

  async restart() {
    await this.close();
    await this.launch();
  }

  // Window placement on the single display (no window manager): park off-screen, or bring back.
  async place(where) {
    if (!this.open) return;
    try {
      const { windowId } = await within(this.cdp.send('Browser.getWindowForTarget'), CLOSE_MS);
      await within(this.cdp.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'normal' } }), CLOSE_MS);
      await within(this.cdp.send('Browser.setWindowBounds', { windowId, bounds: where }), CLOSE_MS);
      if (where === HOME) await within(this.page.bringToFront(), CLOSE_MS);
    } catch { /* placement is cosmetic */ }
  }

  // Open a page for the owner under a host lock. lock: 'now' (login: the lock holds from the
  // first navigation) or 'after-landing' (check: the page must first land on the expected host).
  // allow(host) -> bool. onLeave: called once if the locked page later leaves.
  // -> 'landed' (lock in force) | 'left' (the lock fired while opening; tab blank) |
  //    'elsewhere' (landed on a host allow() refuses; tab blank) | 'page-timeout' (restarted)
  async ownerOpen({ url, allow, lock, cfg, onLeave }) {
    const t = timeoutsOf(cfg);
    let left = false;
    const mode = { kind: 'owner', locked: lock === 'now', allow, onLeave: () => { left = true; } };
    this.mode = mode;
    const work = (async () => {
      await this.page.goto(url, { waitUntil: 'domcontentloaded', timeout: t.navMs }).catch(() => {});
      await sleep(t.settleMs);                  // let redirects settle
      // A page that does not answer is not left in front of the owner (PageHung: killed below).
      await within(this.page.evaluate(() => 1), callMs(t)).catch((e) => { if (e instanceof PageHung) throw e; });
      return hostOf(this.page.url());
    })();
    let host;
    try {
      host = await within(work, deadlineMs(cfg));
    } catch {
      await this.restart();
      return 'page-timeout';
    }
    if (left) return 'left';
    if (this.mode !== mode || !allow(host)) { await this.reset(); return 'elsewhere'; }
    mode.locked = true;
    mode.onLeave = onLeave;
    return 'landed';
  }
}

// The two browsers. The library one exists only while a library visit or the owner's sign-in
// needs it; while it is up, the direct window is parked off the display, so the owner sees one.
export class Browsers {
  constructor({ profilesDir, downloadDir, sandbox = true, testOnlyAllow = [] }) {
    const mk = (kind) => new Browser({ kind, profileDir: path.join(profilesDir, PROFILES[kind]), downloadDir, sandbox, testOnlyAllow });
    this.b = { direct: mk('direct'), library: mk('library') };
  }

  async direct() {
    if (!this.b.direct.open) await this.b.direct.launch();
    return this.b.direct;
  }

  async library() {
    const d = await this.direct();
    if (!this.b.library.open) await this.b.library.launch();
    await d.place(PARK);
    await this.b.library.place(HOME);
    return this.b.library;
  }

  get libraryOpen() { return this.b.library.open; }

  async closeLibrary() {
    if (this.b.library.open) await this.b.library.close();
    if (this.b.direct.open) await this.b.direct.place(HOME);
  }

  // Nothing for the owner: the library browser closed, the direct tab blank and in front.
  async idle() {
    await this.closeLibrary();
    if (this.b.direct.open) await this.b.direct.reset();
  }

  async close() {
    await this.b.library.close();
    await this.b.direct.close();
  }
}

// Ask the resolver where a DOI goes, without following the redirect, so the caller can
// pace and skip by publisher host before the browser contacts that host. A request from the
// direct browser's API context (Node's HTTP client, its own timeout; no page is involved).
// -> {url, host} or {status}
export async function resolveDoi(b, doi, { cfg }) {
  const t = timeoutsOf(cfg);
  const start = cfg.resolver + doi;
  let r;
  try {
    r = await b.ctx.request.get(start, { maxRedirects: 0, timeout: t.navMs, failOnStatusCode: false });
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
      if (!hostOf(next) || b.forbidden(next)) return { status: 'not-available:http-error' };
      return { url: next, host: hostOf(next) };
    }
    if (code >= 400) return { status: 'not-available:http-error' };
    return { url: start, host: hostOf(start) };
  } finally {
    await r.dispose().catch(() => {});
  }
}

const noHash = (u) => String(u).split('#')[0];
const str = (v, n) => (typeof v === 'string' ? v.slice(0, n) : '');

// Title, a little body text, the citation_pdf_url and the link targets, in one call with a
// timeout (PageHung if the page does not answer), plus the host the tab was on before and after
// (host: '' if it moved meanwhile). Values are type-checked and capped here: page script runs in
// the same world and could return anything.
async function snapshot(page, t) {
  const before = hostOf(page.url());
  let s = null;
  try {
    s = await within(page.evaluate(() => {
      const meta = document.querySelector('meta[name="citation_pdf_url"]');
      return {
        title: document.title,
        text: document.body ? document.body.innerText.slice(0, 3000) : '',
        meta: meta ? meta.getAttribute('content') : '',
        hrefs: Array.from(document.querySelectorAll('a[href]')).slice(0, 2000).map((a) => a.href),
      };
    }), callMs(t));
  } catch (e) {
    if (e instanceof PageHung) throw e;
    s = null;                                   // a navigation destroyed the context: nothing to read
  }
  const after = hostOf(page.url());
  const o = s !== null && typeof s === 'object' ? s : {};
  return {
    host: before === after ? after : '',
    title: str(o.title, 300),
    text: str(o.text, 3000),
    meta: str(o.meta, 2048),
    hrefs: Array.isArray(o.hrefs) ? o.hrefs.slice(0, 2000).filter((h) => typeof h === 'string' && h.length <= 2048) : [],
    url: page.url(),
  };
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

// Navigate the tab to the PDF URL; a download is the expected outcome. -> {status, tmpPdf?, checkHost?}
// Only a download of a URL the tab's main frame navigated to during this step is taken (b.want);
// every other is cancelled and deleted by the browser's listener.
async function download(b, v, page, url, t, max) {
  if (b.mode.visit !== v) return { status: 'not-available:timeout' };   // this visit was already given up
  const dir = b.downloadDir;
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
  v.navUrls.clear();
  let take;
  const dlP = new Promise((res) => { take = res; });
  const want = (d) => { if (!v.navUrls.has(noHash(d.url()))) return false; take({ d }); return true; };
  b.want = want;
  try {
    // Page-chosen URL, http(s) only (classify.pickPdfUrl); the browser's guards apply to it and
    // to every redirect hop.
    const navP = page.goto(url, { waitUntil: 'domcontentloaded', timeout: t.navMs }).then((r) => ({ r }), (e) => ({ e }));
    const first = await Promise.race([dlP, navP, sleep(t.navMs + 1000).then(() => ({}))]);
    let dl = first.d;
    if (!dl && !v.stopped) {
      // A page loaded (or the navigation was aborted by a starting download): give a
      // download a moment to appear before judging the page.
      const later = await Promise.race([dlP, sleep(first.e ? 2000 : t.settleMs).then(() => ({}))]);
      dl = later.d;
    }
    if (b.want === want) b.want = null;
    if (v.stopped) {
      if (dl) { await dl.cancel().catch(() => {}); await dl.delete().catch(() => {}); }
      return { ...v.stopped };
    }
    if (dl) {
      const out = await finish(dl, t, max, dir, before, () => declaredTooBig);
      if (out.status !== 'saved') {
        await dl.cancel().catch(() => {});
        await dl.delete().catch(() => {});
      }
      return out;
    }
    const nav = await within(navP, 1000).catch(() => ({ e: { name: 'TimeoutError' } }));
    if (nav.e) return { status: failed(nav.e) };
    const s = await snapshot(page, t);
    if (v.stopped) return { ...v.stopped };
    if (s.host && isCheck(s)) return { status: 'needs-owner:check', checkHost: s.host };
    if (nav.r && nav.r.status() >= 400) return { status: 'not-available:http-error' };
    return { status: 'not-available:not-a-pdf' };
  } finally {
    if (b.want === want) b.want = null;
    page.off('response', onResponse);
  }
}

async function visit(b, v, doi, { cfg, library, url, t, max }) {
  const page = b.page;
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
    return v.stopped ? { ...v.stopped } : { status: failed(e), host: '' };
  }
  await sleep(t.settleMs);                      // let redirects and interstitials settle
  if (v.stopped) return { ...v.stopped };
  const host = hostOf(page.url());
  const code = resp ? resp.status() : 0;
  // The landing URL may be sent through the library prefix later. page.url() is under
  // page script's control, so it is offered only while it is still on the host the
  // navigation's redirect chain ended on.
  const navHost = resp ? hostOf(resp.url()) : '';
  const landingUrl = navHost && host === navHost ? page.url() : undefined;

  // Decided by host name only, and only after a library-routed visit.
  if (library && isLoginHost(host, cfg)) return { status: 'needs-owner:login', host };
  const s = await snapshot(page, t);
  if (v.stopped) return { ...v.stopped };
  // A check is recorded against the host the tab is on while the challenge is read (never a
  // host the page names, never one it left meanwhile).
  if (s.host && isCheck(s)) return { status: 'needs-owner:check', host: s.host, checkHost: s.host };
  if (!library && !url && code === 404 && host === hostOf(cfg.resolver)) return { status: 'not-available:doi-not-found', host: '' };
  if (code >= 400) return { status: 'not-available:http-error', host, landingUrl };

  const found = pickPdfUrl({ meta: s.meta, hrefs: s.hrefs }, s.url);
  if (!found) return { status: 'not-available:no-pdf-link', host, landingUrl };
  return { ...(await download(b, v, page, directPdfUrl(found), t, max)), host, landingUrl };
}

// One visit for one paper, in browser b. -> {status, host, tmpPdf?, checkHost?, landingUrl?}
// url: start here instead of resolver+doi (direct), or the landing URL to send through the
// library prefix (library). navCheck(host) -> a skip status or null: asked for every host the
// tab's main frame is about to go to (redirect hops and the page's own moves included); a
// refused host is never contacted, and the visit ends with that status.
// The visit ends by its deadline whatever the page does: an unresponsive page gives
// not-available:timeout, and the browser is killed and relaunched before this returns.
export async function fetchOne(b, doi, { cfg, library = false, url = '', navCheck = () => null }) {
  const t = timeoutsOf(cfg);
  const max = cfg.maxPdfBytes ?? DEFAULT_MAX_PDF_BYTES;
  if (!b.open) await b.launch();
  const v = { navCheck, navUrls: new Set(), stopped: null };
  b.mode = { kind: 'fetch', visit: v };
  let hung = false;
  let r;
  let timer;
  const deadline = new Promise((res) => {
    timer = setTimeout(() => { hung = true; res({ status: 'not-available:timeout', host: '' }); }, deadlineMs(cfg));
  });
  try {
    const work = visit(b, v, doi, { cfg, library, url, t, max }).catch((e) => {
      if (e instanceof TypeError) throw e;
      if (e instanceof PageHung) hung = true;
      return { status: e instanceof PageHung ? 'not-available:timeout' : failed(e), host: '' };
    });
    r = await Promise.race([work, deadline]);
  } finally {
    clearTimeout(timer);
    if (b.mode.visit === v) { b.mode = { kind: 'idle' }; b.want = null; }
  }
  if (hung) {
    if (r.tmpPdf) fs.rmSync(r.tmpPdf, { force: true });
    await b.restart();
    return { status: 'not-available:timeout', host: r.host ?? '' };
  }
  await b.reset();
  // Playwright deletes a context's downloads when the context closes (the library browser closes
  // after its visit): the file is renamed out of its tracking first. emptyDir clears it later.
  if (r.tmpPdf) {
    const kept = `${r.tmpPdf}.pdf`;
    try { fs.renameSync(r.tmpPdf, kept); return { ...r, tmpPdf: kept }; } catch { return { ...r, status: 'not-available:http-error', tmpPdf: undefined }; }
  }
  return r;
}
