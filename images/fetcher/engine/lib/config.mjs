// KEY=value config file. Strict: unknown keys, duplicates and malformed values are
// errors, because these values decide where a session-holding browser goes. Error
// messages never contain a value (LIBRARY_PREFIX names the owner's institution).
import fs from 'node:fs';

const HOST = /^[a-z0-9.-]{1,253}$/;
const DEFAULT_LOGIN_HOSTS = ['login.openathens.net', 'go.openathens.net'];
const LOGIN_SUFFIXES = ['.duosecurity.com'];

const urlOk = (v) => { try { const u = new URL(v); return u.protocol === 'https:' && !/\s/.test(v); } catch { return false; } };
const num = (v) => { if (!/^[0-9]{1,9}$/.test(v)) throw new Error('not a whole number'); return Number(v); };

const KEYS = {
  RESOLVER: (v, c) => { if (!urlOk(v) || !v.endsWith('/')) throw new Error('RESOLVER must be an https URL ending in /'); c.resolver = v; },
  LIBRARY_PREFIX: (v, c) => { if (!urlOk(v)) throw new Error('LIBRARY_PREFIX must be an https URL'); c.libraryPrefix = v; },
  LOGIN_HOSTS: (v, c) => {
    for (const h of v.split(',').map((s) => s.trim()).filter(Boolean)) {
      if (!HOST.test(h)) throw new Error('bad host in LOGIN_HOSTS');
      c.loginHosts.push(h);
    }
  },
  GAP_MS: (v, c) => { c.caps.gapMs = num(v); },
  HOST_GAP_MS: (v, c) => { c.caps.hostGapMs = num(v); },
  PER_HOST: (v, c) => { c.caps.perHost = num(v); },
  PER_DAY: (v, c) => { c.caps.perDay = num(v); },
  LIBRARY_PER_DAY: (v, c) => { c.caps.libraryPerDay = num(v); },
  RESOLVER_PER_DAY: (v, c) => { c.caps.resolverPerDay = num(v); },
  MAX_PDF_BYTES: (v, c) => { c.maxPdfBytes = num(v); },
  NAV_TIMEOUT_MS: (v, c) => { c.timeouts.navMs = num(v); },
  SETTLE_MS: (v, c) => { c.timeouts.settleMs = num(v); },
  DOWNLOAD_TIMEOUT_MS: (v, c) => { c.timeouts.downloadMs = num(v); },
  // The hard limit on one browser visit, whatever the page does (default: NAV_TIMEOUT_MS +
  // SETTLE_MS + DOWNLOAD_TIMEOUT_MS + 30 s; browser.mjs deadlineMs).
  PAPER_DEADLINE_MS: (v, c) => { c.paperDeadlineMs = num(v); },
};

export function loadConfig(path) {
  const cfg = {
    resolver: 'https://doi.org/',
    libraryPrefix: '',
    loginHosts: [...DEFAULT_LOGIN_HOSTS],
    caps: { gapMs: 25000, hostGapMs: 60000, perHost: 30, perDay: 100, libraryPerDay: 20, resolverPerDay: 300 },
    maxPdfBytes: 104857600,
    timeouts: { navMs: 60000, settleMs: 9000, downloadMs: 45000 },
  };
  let text;
  try {
    text = fs.readFileSync(path, 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return cfg;
    throw e;
  }
  const seen = new Set();
  text.split('\n').forEach((raw, i) => {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) return;
    const eq = line.indexOf('=');
    const key = eq < 0 ? '' : line.slice(0, eq).trim();
    if (!Object.hasOwn(KEYS, key)) throw new Error(`config line ${i + 1}: unknown or malformed key`);
    if (seen.has(key)) throw new Error(`config line ${i + 1}: duplicate ${key}`);
    seen.add(key);
    try { KEYS[key](line.slice(eq + 1).trim(), cfg); } catch (e) { throw new Error(`config line ${i + 1}: ${e.message}`); }
  });
  return cfg;
}

// Exact login-host names, or a name under a login suffix (.duosecurity.com).
export function isLoginHost(cfg, host) {
  if (typeof host !== 'string') return false;
  const h = host.toLowerCase();
  if (!HOST.test(h) || h.includes('..') || h === '-') return false;
  return cfg.loginHosts.includes(h) || LOGIN_SUFFIXES.some((s) => h.endsWith(s) && h.length > s.length);
}
