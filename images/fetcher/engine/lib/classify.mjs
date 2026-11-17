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
