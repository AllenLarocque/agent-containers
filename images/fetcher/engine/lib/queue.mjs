// Request and status files. Everything under the papers root is writable by the research
// agent, so reads refuse links and odd file types, sizes are capped, request lines must
// be DOIs, and status lines are only trusted if they re-render byte for byte.
import fs from 'node:fs';
import path from 'node:path';
import { parseDoi } from './doi.mjs';
import { statusLine } from './records.mjs';

export const REQUEST_NAME = /^[A-Za-z0-9._-]{1,80}\.txt$/;
const PROJECT = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,79}$/;
const MAX_LINES = 200;
const MAX_REF = 9999;                    // records.mjs accepts line:1 .. line:9999
const MAX_REQUEST_BYTES = 64 * 1024;
const MAX_STATUS_BYTES = 1024 * 1024;
const TERMINAL = (s) => s === 'saved' || s === 'bad-request' || (typeof s === 'string' && s.startsWith('not-available:'));

// root/<segs...> if every component is a real directory (no links); otherwise null.
export function plainDir(root, segs) {
  let p = root;
  for (const s of segs) {
    p = path.join(p, s);
    const st = fs.lstatSync(p, { throwIfNoEntry: false });
    if (!st || !st.isDirectory()) return null;
  }
  return p;
}

// A small regular file, not through a link at its final name; null otherwise.
export function readSmall(file, max) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > max) return null;
    const buf = Buffer.alloc(st.size);
    const n = fs.readSync(fd, buf, 0, st.size, 0);
    return buf.subarray(0, n).toString('utf8');
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

// True if file is a regular file (not a link at its final name) starting with prefix.
export function startsWith(file, prefix) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    if (!fs.fstatSync(fd).isFile()) return false;
    const want = Buffer.from(prefix);
    const buf = Buffer.alloc(want.length);
    return fs.readSync(fd, buf, 0, want.length, 0) === want.length && buf.equals(want);
  } catch {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function parseRequest(text) {
  const lines = text.split('\n');
  if (lines.at(-1) === '') lines.pop();
  const dois = [];
  const bad = [];
  for (let i = 0; i < lines.length && i < MAX_REF; i++) {
    const n = i + 1;
    if (lines[i].trim() === '') continue;
    const doi = n <= MAX_LINES ? parseDoi(lines[i]) : null;
    if (doi === null) bad.push(n);
    else if (!dois.includes(doi)) dois.push(doi);
  }
  return { dois, bad };
}

export function scanRequests(papersRoot) {
  const out = [];
  let projects;
  try { projects = fs.readdirSync(papersRoot).sort(); } catch { return out; }
  for (const project of projects) {
    if (!PROJECT.test(project)) continue;
    const dir = plainDir(papersRoot, [project, '_fetch', 'requests']);
    if (!dir) continue;
    for (const name of fs.readdirSync(dir).sort()) {
      if (!REQUEST_NAME.test(name)) continue;
      const text = readSmall(path.join(dir, name), MAX_REQUEST_BYTES);
      if (text === null) continue;
      out.push({ project, name, ...parseRequest(text) });
    }
  }
  return out;
}

export const statusName = (requestName) => requestName.replace(/\.txt$/, '.tsv');

// doi -> {status, host, date, library}, from lines that re-render exactly.
export function readStatus(statusDir, requestName) {
  const map = new Map();
  const text = statusDir ? readSmall(path.join(statusDir, statusName(requestName)), MAX_STATUS_BYTES) : null;
  if (text === null) return map;
  for (const line of text.split('\n')) {
    const f = line.split('\t');
    if (f.length !== 5 || f[1] === 'bad-request') continue;
    const rec = { doi: f[0], status: f[1], host: f[2] === '-' ? '' : f[2], date: f[3], library: f[4] };
    try {
      if (statusLine(rec) === `${line}\n`) map.set(rec.doi, rec);
    } catch { /* not ours: ignore */ }
  }
  return map;
}

export function pending(request, statusDir) {
  const map = readStatus(statusDir, request.name);
  return request.dois.filter((d) => !TERMINAL(map.get(d)?.status));
}

// The whole status file: one line per requested DOI that has a result, then one per bad line.
export function renderStatus(request, map, date) {
  let s = '';
  for (const doi of request.dois) if (map.has(doi)) s += statusLine({ ...map.get(doi), doi });
  for (const n of request.bad) s += statusLine({ doi: `line:${n}`, status: 'bad-request', host: '', date, library: 'no' });
  return s;
}
