// Local HTTP server that plays doi.org, several publishers, a CDN, a library redirector
// and a login host, told apart by the loopback address in the Host header (the test
// container has only its loopback). Every request is logged with the fixture key it
// concerns, so tests can assert that no request was made.
//
//   127.0.0.1  resolver ("doi.org")       127.0.0.4  login host (listed in loginHosts)
//   127.0.0.2  publisher                   127.0.0.5  library redirector (libraryPrefix)
//   127.0.0.3  CDN                         127.0.0.6  a second publisher (challenge host)
//   127.0.0.7  an intermediate redirect host (a "first hop" that is not the landing host)
//   127.0.0.9  a second intermediate redirect host
//   127.0.0.8  NOT allowed: stands for a loopback/private address the browser must never reach
//              (the browser's guard lets through only the "host:port" pairs in `allow`)
//
// Bot checks: check/check2 (on 127.0.0.6) and pcheck (on 127.0.0.2) show a challenge page until a
// test calls pass(host): from then on that host serves them as good articles with a PDF (the owner
// has ticked the box in the view).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures');
const read = (f) => fs.readFileSync(path.join(dir, f));
export const PDF = read('paper.pdf');
export const H = { R: '127.0.0.1', P: '127.0.0.2', C: '127.0.0.3', L: '127.0.0.4', Y: '127.0.0.5', X: '127.0.0.6',
                   V: '127.0.0.7', W: '127.0.0.9', F: '127.0.0.8' };
export const BIG = 100000;                // bytes in the over-size fixture PDFs
const ON_X = new Set(['check', 'check2', 'hok']);

const PAGES = {
  ok: 'article-ok', linkonly: 'article-linkonly', cdn: 'article-cdn', pdfcheck: 'article-pdfcheck',
  nopdf: 'article-nopdf', html: 'article-html', htmlpage: 'article-htmlpage', inject: 'article-inject',
  slowpdf: 'article-slowpdf', paywall: 'article-paywall', paywall2: 'article-paywall', paywall3: 'article-paywall',
  paywallslow: 'article-paywall', jsmove: 'article-jsmove', autodl: 'article-autodl',
  big: 'article-good', bignolen: 'article-good',
  busy: 'article-busy', busypdf: 'article-good', dialog: 'article-dialog', popup: 'article-popup',
  goloop: 'article-goloop', wsloop: 'article-wsloop', pdfx: 'article-pdfx', pdfxr: 'article-good', pleave: 'article-pleave',
};
const PDF_KEYS = /^(ok|inject|hok|paywall[23]?|good[0-9]*|via[0-9]|wia[0-9]|vp[0-9]|popup|ck[a-z]*)$/;
const CHECK_KEYS = /^(check2?|pcheck)$/;

function keyOf(url) {
  let s = url;
  try { s = decodeURIComponent(url); } catch { /* keep raw */ }
  const m = s.match(/10\.5555\/([a-z0-9]+)/) || s.match(/(?:article|pdf|files)\/([a-z0-9]+)/);
  return m ? m[1] : '';
}

export async function startFixtureServer() {
  const log = [];
  const passed = new Set();
  const sockets = new Set();
  let port;
  const base = (h) => `http://${h}:${port}`;

  const send = (res, code, type, body, extra = {}) => {
    res.writeHead(code, { 'content-type': type, 'cache-control': 'no-store', ...extra });
    res.end(body);
  };
  const page = (res, file, host, key, code = 200) => send(res, code, 'text/html; charset=utf-8',
    read(`${file}.html`).toString().replaceAll('__SELF__', base(host)).replaceAll('__CDN__', base(H.C)).replaceAll('__OTHER__', base(H.V))
      .replaceAll('__KEY__', key).replaceAll('__FORBIDDEN__', base(H.F)).replaceAll('__XHOST__', base(H.X))
      .replaceAll('__PUB__', base(H.P)).replaceAll('__LOCAL__', `http://localhost:${port}`));
  const redirect = (res, to) => { res.writeHead(302, { location: to }); res.end(); };
  const pdf = (res) => send(res, 200, 'application/pdf', PDF);
  const hang = () => {};   // never answer; the socket is destroyed at close()

  const server = http.createServer((req, res) => {
    const host = (req.headers.host || '').replace(/:\d+$/, '');
    const u = new URL(req.url, 'http://x');
    const key = keyOf(req.url);
    log.push({ host, path: req.url, key, t: Date.now(), cookie: req.headers.cookie ?? '' });
    if (u.pathname === '/favicon.ico') return send(res, 404, 'text/plain', '');
    if (u.pathname === '/files/junk.bin') return send(res, 200, 'application/octet-stream', Buffer.alloc(5000, 0x41),
      { 'content-disposition': 'attachment; filename="junk.bin"' });

    if (host === H.R) {
      const k = u.pathname.match(/^\/10\.5555\/([a-z0-9]+)$/)?.[1];
      if (u.pathname === '/relative/locrel') return redirect(res, `${base(H.P)}/article/good1`);
      if (!k || k.startsWith('404')) return page(res, 'page', host, '', 404);
      if (k === 'locjs') return redirect(res, 'javascript:alert(1)');
      if (k === 'locnone') { res.writeHead(302); return res.end(); }
      if (k === 'locrel') return redirect(res, '/relative/locrel');
      if (/^(via|vp)[0-9]$/.test(k)) return redirect(res, `${base(H.V)}/go/${k}`);
      if (/^wia[0-9]$/.test(k)) return redirect(res, `${base(H.W)}/go/${k}`);
      return redirect(res, `${base(ON_X.has(k) ? H.X : H.P)}/article/${k}`);
    }
    if (host === H.V || host === H.W) {
      const k = u.pathname.match(/^\/go\/((?:via|wia|vp)[0-9])$/)?.[1];
      if (k) return redirect(res, `${base(k.startsWith('vp') ? H.P : H.X)}/article/${k}`);
      if (u.pathname === '/article/jsmove') return page(res, 'article-paywall', host, 'jsmove');
      return send(res, 404, 'text/plain', 'not found');
    }
    if (host === H.P || host === H.X) {
      let m;
      if ((m = u.pathname.match(/^\/article\/([a-z0-9]+)$/))) {
        const k = m[1];
        if (k === 'slow') return hang();
        if (k === 'neverload') {                          // headers and a start, then nothing: never finishes loading
          res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
          res.write('<!doctype html><html><head><title>Loading</title></head><body><p>Loading');
          return hang();
        }
        if (k === 'redirloop') return redirect(res, `${base(H.F)}/article/landed`);
        if (k.startsWith('ck')) {                          // sets a cookie named after the key (profile separation tests)
          return send(res, 200, 'text/html; charset=utf-8', read('article-good.html').toString().replaceAll('__SELF__', base(host))
            .replaceAll('__KEY__', k), { 'set-cookie': `${k}=1; Path=/` });
        }
        if (CHECK_KEYS.test(k)) return passed.has(host) ? page(res, 'article-good', host, k) : page(res, 'challenge', host, k, 403);
        if (/^paywall[23]?$/.test(k) && u.searchParams.get('lib') === '1') return page(res, 'article-paywall-lib', host, k);
        if (PAGES[k]) return page(res, PAGES[k], host, k);
        if (k === 'hok' || /^(good[0-9]*|via[0-9]|wia[0-9]|vp[0-9])$/.test(k)) return page(res, 'article-good', host, k);
        return page(res, 'page', host, '', 404);
      }
      if ((m = u.pathname.match(/^\/pdf\/([a-z0-9]+)$/))) {
        const k = m[1];
        if (PDF_KEYS.test(k) || (CHECK_KEYS.test(k) && passed.has(host))) return pdf(res);
        if (k === 'pdfcheck') return page(res, 'challenge', host, k, 403);
        if (k === 'html') return send(res, 200, 'text/html', read('page.html'),
          { 'content-disposition': 'attachment; filename="paper.pdf"' });
        if (k === 'htmlpage') return page(res, 'page', host, k);
        if (k === 'busypdf') return page(res, 'busy', host, k);
        if (k === 'pdfxr') return redirect(res, `${base(H.X)}/pdf/pdfxr`);
        if (k === 'big') return send(res, 200, 'application/pdf', Buffer.concat([PDF, Buffer.alloc(BIG - PDF.length, 0x20)]));
        if (k === 'bignolen') {          // chunked: no Content-Length to refuse on
          res.writeHead(200, { 'content-type': 'application/pdf' });
          res.write(PDF);
          for (let i = 0; i < 10; i++) res.write(Buffer.alloc(BIG / 10, 0x20));
          return res.end();
        }
        if (k === 'slowpdf') {
          res.writeHead(200, { 'content-type': 'application/pdf', 'content-length': '10000000',
            'content-disposition': 'attachment; filename="paper.pdf"' });
          res.write('%PDF-1.4\n% partial\n');
          return hang();
        }
      }
      if (u.pathname === '/doi/pdf/10.5555/linkonly') return pdf(res);
      return page(res, 'page', host, '', 404);
    }
    if (host === H.C && u.pathname === '/files/cdn.pdf') return pdf(res);
    if (host === H.L) return page(res, u.pathname === '/logindone' ? 'login-done' : 'login', host, '');
    if (host === H.Y && u.pathname === '/lib') {
      const target = u.searchParams.get('url') || '';
      const k = keyOf(target);
      if (k === 'paywall2' || k === 'paywall3') return redirect(res, `${base(H.L)}/login`);
      if (k === 'paywalldone') return redirect(res, `${base(H.L)}/logindone`);
      if (k === 'paywallfake') return redirect(res, `${base(H.X)}/login`);
      if (k === 'paywallslow') return hang();
      if (k === 'paywall') return redirect(res, `${base(H.P)}/article/paywall?lib=1`);
      return redirect(res, target);
    }
    return send(res, 404, 'text/plain', 'not found');
  });
  server.on('connection', (s) => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
  server.on('upgrade', (req, sock) => {               // WebSocket attempts are logged, then refused
    log.push({ host: (req.headers.host || '').replace(/:\d+$/, ''), path: req.url, key: 'websocket', t: Date.now(), cookie: '' });
    sock.destroy();
  });
  await new Promise((r) => server.listen(0, '0.0.0.0', r));
  port = server.address().port;

  // The "host:port" pairs the browser's guard lets through in tests (every fixture host but H.F).
  const allow = Object.values(H).filter((h) => h !== H.F).map((h) => `${h}:${port}`);
  return {
    port, log, base, allow,
    resolver: `${base(H.R)}/`,
    libraryPrefix: `${base(H.Y)}/lib?url=`,
    pass: (host) => passed.add(host),
    hits: (key, host) => log.filter((e) => e.key === key && (!host || e.host === host)),
    close: () => new Promise((r) => { for (const s of sockets) s.destroy(); server.close(() => r()); }),
  };
}
