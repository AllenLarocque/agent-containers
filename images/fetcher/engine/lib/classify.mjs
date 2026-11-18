// Page classification. Pure functions over values the browser hands back; page text is
// only ever tested against fixed patterns here, never stored, logged or acted on.
import { isLoginHost as loginHostByCfg } from './config.mjs';

// The trial's challenge phrases.
const CHECK = /just a moment|verify you are human|are you a robot|access denied|checking your browser|pardon our interruption|unusual traffic/i;
const SHORT_BODY = 1500;

export function isCheck({ title = '', text = '' } = {}) {
  return CHECK.test(String(title)) || (String(text).length < SHORT_BODY && CHECK.test(String(text)));
}

// Same rule as config.isLoginHost, with the argument order (host, cfg). Swapped
// arguments throw rather than quietly answering false.
export function isLoginHost(host, cfg) {
  if (cfg === null || typeof cfg !== 'object' || !Array.isArray(cfg.loginHosts)) throw new TypeError('isLoginHost(host, cfg)');
  return loginHostByCfg(cfg, host);
}

const HOST = /^[a-z0-9.-]{1,253}$/;

// Lower-case host name of an http(s) URL, without the port; '' for anything else.
export function hostOf(url) {
  try {
    const u = new URL(url);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    return HOST.test(u.hostname) ? u.hostname : '';
  } catch {
    return '';
  }
}

// Hosts the browser never contacts, whatever a page or a redirect asks: loopback, private,
// link-local, shared (CGNAT), unspecified, benchmark, multicast and broadcast IPv4 literals,
// every IPv6 literal (publishers use names), localhost and *.localhost, *.internal (Docker's
// host.docker.internal and friends) and single-label names. The container's firewall also
// denies private ranges, but not its own loopback, where the owner's viewer listens.
const V4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
export function forbiddenHostname(hostname) {
  if (typeof hostname !== 'string' || hostname === '') return true;
  const h = hostname.toLowerCase().replace(/\.$/, '');
  if (h.startsWith('[') || h.includes(':')) return true;
  if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.internal') || !h.includes('.')) return true;
  const m = V4.exec(h);
  if (!m) return false;
  const [a, b, c] = [Number(m[1]), Number(m[2]), Number(m[3])];
  return a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 192 && b === 0 && c === 0) ||
    (a === 198 && (b === 18 || b === 19)) || a >= 224;
}

const DEFAULT_PORT = { 'http:': '80', 'ws:': '80', 'https:': '443', 'wss:': '443' };
const NONE = new Set();
// true for anything the browser must not request: a scheme other than http(s)/ws(s), or a
// forbidden host. allow: "host:port" pairs let through (TESTS ONLY: the fixture server lives on
// loopback; production never passes it, and nothing in the config or the environment sets it).
export function forbiddenUrl(url, allow = NONE) {
  let u;
  try { u = new URL(String(url)); } catch { return true; }
  const port = DEFAULT_PORT[u.protocol];
  if (!port) return true;
  if (allow.has(`${u.hostname}:${u.port || port}`)) return false;
  return forbiddenHostname(u.hostname);
}

const httpUrl = (s, base) => {
  try {
    const u = new URL(s, base);
    return u.protocol === 'http:' || u.protocol === 'https:' ? u.href : '';
  } catch {
    return '';
  }
};

const PDF_LINK = /\/doi\/(e?pdf|pdfdirect)\/|\/pdf(ft)?(\?|$|\/)|\.pdf(\?|$)/i;

// {meta: citation_pdf_url content, hrefs: resolved link hrefs} -> an http(s) URL or ''.
export function pickPdfUrl({ meta = '', hrefs = [] }, pageUrl) {
  const m = meta ? httpUrl(meta, pageUrl) : '';
  if (m) return m;
  for (const h of hrefs) {
    const u = httpUrl(h, pageUrl);
    if (u && PDF_LINK.test(u)) return u;
  }
  return '';
}

// Wiley's /doi/pdf/ and /doi/epdf/ open a viewer; /doi/pdfdirect/ is the file.
export function directPdfUrl(url) {
  const host = hostOf(url);
  if (host !== 'wiley.com' && !host.endsWith('.wiley.com')) return url;
  return url.replace(/\/doi\/e?pdf\//, '/doi/pdfdirect/');
}
