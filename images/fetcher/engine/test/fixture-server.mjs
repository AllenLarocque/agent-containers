// Local HTTP server that plays doi.org, several publishers, a CDN, a library redirector
// and a login host, told apart by the loopback address in the Host header (the test
// container has only its loopback). Every request is logged with the fixture key it
// concerns, so tests can assert that no request was made.
//
//   127.0.0.1  resolver ("doi.org")       127.0.0.4  login host (listed in loginHosts)
//   127.0.0.2  publisher                   127.0.0.5  library redirector (libraryPrefix)
//   127.0.0.3  CDN                         127.0.0.6  a second publisher (challenge host)
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures');
const read = (f) => fs.readFileSync(path.join(dir, f));
export const PDF = read('paper.pdf');
export const H = { R: '127.0.0.1', P: '127.0.0.2', C: '127.0.0.3', L: '127.0.0.4', Y: '127.0.0.5', X: '127.0.0.6' };
const ON_X = new Set(['check', 'check2', 'hok']);

const PAGES = {
  ok: 'article-ok', linkonly: 'article-linkonly', cdn: 'article-cdn', pdfcheck: 'article-pdfcheck',
  nopdf: 'article-nopdf', html: 'article-html', htmlpage: 'article-htmlpage', inject: 'article-inject',
  slowpdf: 'article-slowpdf', paywall: 'article-paywall', paywall2: 'article-paywall', paywall3: 'article-paywall',
};
const PDF_KEYS = /^(ok|inject|hok|paywall[23]?|good[0-9]*)$/;

function keyOf(url) {
  let s = url;
  try { s = decodeURIComponent(url); } catch { /* keep raw */ }
  const m = s.match(/10\.5555\/([a-z0-9]+)/) || s.match(/(?:article|pdf|files)\/([a-z0-9]+)/);
  return m ? m[1] : '';
}

export async function startFixtureServer() {
  const log = [];
  const sockets = new Set();
  let port;
  const base = (h) => `http://${h}:${port}`;

  const send = (res, code, type, body, extra = {}) => {
    res.writeHead(code, { 'content-type': type, 'cache-control': 'no-store', ...extra });
    res.end(body);
  };
  const page = (res, file, host, key, code = 200) => send(res, code, 'text/html; charset=utf-8',
    read(`${file}.html`).toString().replaceAll('__SELF__', base(host)).replaceAll('__CDN__', base(H.C))
      .replaceAll('__KEY__', key));
  const redirect = (res, to) => { res.writeHead(302, { location: to }); res.end(); };
  const pdf = (res) => send(res, 200, 'application/pdf', PDF);
  const hang = () => {};   // never answer; the socket is destroyed at close()

  const server = http.createServer((req, res) => {
    const host = (req.headers.host || '').replace(/:\d+$/, '');
    const u = new URL(req.url, 'http://x');
    const key = keyOf(req.url);
    log.push({ host, path: req.url, key });
    if (u.pathname === '/favicon.ico') return send(res, 404, 'text/plain', '');

    if (host === H.R) {
      const k = u.pathname.match(/^\/10\.5555\/([a-z0-9]+)$/)?.[1];
      if (!k || k === '404') return page(res, 'page', host, '', 404);
      return redirect(res, `${base(ON_X.has(k) ? H.X : H.P)}/article/${k}`);
    }
    if (host === H.P || host === H.X) {
      let m;
      if ((m = u.pathname.match(/^\/article\/([a-z0-9]+)$/))) {
        const k = m[1];
        if (k === 'slow') return hang();
        if (k === 'check' || k === 'check2') return page(res, 'challenge', host, k, 403);
        if (/^paywall[23]?$/.test(k) && u.searchParams.get('lib') === '1') return page(res, 'article-paywall-lib', host, k);
        if (PAGES[k]) return page(res, PAGES[k], host, k);
        if (k === 'hok' || /^good[0-9]*$/.test(k)) return page(res, 'article-good', host, k);
        return page(res, 'page', host, '', 404);
      }
      if ((m = u.pathname.match(/^\/pdf\/([a-z0-9]+)$/))) {
        const k = m[1];
        if (PDF_KEYS.test(k)) return pdf(res);
        if (k === 'pdfcheck') return page(res, 'challenge', host, k, 403);
        if (k === 'html') return send(res, 200, 'text/html', read('page.html'),
          { 'content-disposition': 'attachment; filename="paper.pdf"' });
        if (k === 'htmlpage') return page(res, 'page', host, k);
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
    if (host === H.L) return page(res, 'login', host, '');
    if (host === H.Y && u.pathname === '/lib') {
      const target = u.searchParams.get('url') || '';
      const k = keyOf(target);
      if (k === 'paywall2' || k === 'paywall3') return redirect(res, `${base(H.L)}/login`);
      if (k === 'paywall') return redirect(res, `${base(H.P)}/article/paywall?lib=1`);
      return redirect(res, target);
    }
    return send(res, 404, 'text/plain', 'not found');
  });
  server.on('connection', (s) => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
  await new Promise((r) => server.listen(0, '0.0.0.0', r));
  port = server.address().port;

  return {
    port, log, base,
    resolver: `${base(H.R)}/`,
    libraryPrefix: `${base(H.Y)}/lib?url=`,
    hits: (key, host) => log.filter((e) => e.key === key && (!host || e.host === host)),
    close: () => new Promise((r) => { for (const s of sockets) s.destroy(); server.close(() => r()); }),
  };
}
