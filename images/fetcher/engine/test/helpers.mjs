// Shared test setup: temp directories, a test config pointing at the fixture server,
// and small file helpers. The Chromium sandbox is turned off ONLY when the test harness
// says the test container cannot run it (tests/fetcher/run.sh); production never does.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { H } from './fixture-server.mjs';

export const SANDBOX = process.env.FETCHER_TEST_SANDBOX !== 'off';

export function testCfg(fx, extra = {}) {
  return {
    resolver: fx.resolver,
    libraryPrefix: '',
    loginHosts: [H.L],
    caps: { gapMs: 0, hostGapMs: 0, perHost: 30, perDay: 100, libraryPerDay: 20, resolverPerDay: 300 },
    maxPdfBytes: 4096,
    timeouts: { navMs: 3000, settleMs: 300, downloadMs: 3000 },
    ...extra,
  };
}

export function tempDirs() {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fetch-')));
  const d = (n) => { const p = path.join(base, n); fs.mkdirSync(p, { recursive: true }); return p; };
  return { base, papers: d('papers'), profile: d('profile'), state: d('state'), downloads: d('dl'),
           control: d('control'), outside: d('outside') };
}

export function request(papers, project, name, lines) {
  const dir = path.join(papers, project, '_fetch', 'requests');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, name), lines.join('\n') + '\n');
}

export function statusLines(papers, project, name) {
  const p = path.join(papers, project, '_fetch', 'status', name.replace(/\.txt$/, '.tsv'));
  if (!fs.existsSync(p)) return [];
  return fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map((l) => l.split('\t'));
}

export const statusOf = (lines, ref) => lines.filter((l) => l[0] === ref).map((l) => l[1]);

export function allFiles(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...allFiles(p)); else out.push(p);
  }
  return out;
}
