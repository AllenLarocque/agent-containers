// Request and status files. Everything under the papers root is writable by the research
// agent, so reads go through held directory descriptors (fs-util), refuse links and odd
// file types, sizes are capped, request lines must be DOIs, and status lines are only
// trusted if they re-render byte for byte.
import { parseDoi } from './doi.mjs';
import { statusLine } from './records.mjs';
import { withDir, listAt, readSmall, readSmallAt, readChangedAt } from './fs-util.mjs';
import path from 'node:path';

export const REQUEST_NAME = /^[A-Za-z0-9._-]{1,80}\.txt$/;
export const PROJECT = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,79}$/;
const MAX_LINES = 200;
const MAX_REF = 9999;                    // records.mjs accepts line:1 .. line:9999
export const MAX_REQUEST_BYTES = 64 * 1024;
export const MAX_STATUS_BYTES = 1024 * 1024;
const TERMINAL = (s) => s === 'saved' || s === 'bad-request' || (typeof s === 'string' && s.startsWith('not-available:'));

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

// Bounds on one pass: projects considered, request files per project (lexicographic by name;
// the rest are left untouched and counted as ignored by fetcherctl status), directory entries
// read per folder, and request bytes read per pass.
export const SCAN = Object.freeze({ projects: 500, filesPerProject: 50, listMax: 5000, totalBytes: 16 * 1024 * 1024 });

// The project folders under the papers root, bounded and sorted.
export const projectNames = (papersRoot, limits = SCAN) =>
  (withDir(papersRoot, [], (fd) => listAt(fd, limits.listMax)) ?? []).filter((p) => PROJECT.test(p)).sort().slice(0, limits.projects);

// A held _fetch/requests folder -> {names: the request files considered, ignored: how many more}.
export function requestNames(dirFd, limits = SCAN) {
  const all = listAt(dirFd, limits.listMax).filter((n) => REQUEST_NAME.test(n)).sort();
  return { names: all.slice(0, limits.filesPerProject), ignored: Math.max(0, all.length - limits.filesPerProject) };
}

// Every request file considered this pass -> [{project, name, dois, bad}]. cache (a Map kept by
// the caller between passes): a file whose identity, size and modification time are unchanged is
// not read or parsed again.
export function scanRequests(papersRoot, { cache = null, limits = SCAN } = {}) {
  const out = [];
  const seen = new Set();
  let bytes = 0;
  for (const project of projectNames(papersRoot, limits)) {
    if (bytes > limits.totalBytes) break;
    withDir(papersRoot, [project, '_fetch', 'requests'], (fd) => {
      for (const name of requestNames(fd, limits).names) {
        const key = `${project}/${name}`;
        const prev = cache?.get(key);
        const got = readChangedAt(fd, name, MAX_REQUEST_BYTES, prev);
        if (got === null) continue;
        if (got !== prev) {
          bytes += got.text.length;
          if (bytes > limits.totalBytes) break;
          got.parsed = parseRequest(got.text);
          delete got.text;
        }
        seen.add(key);
        cache?.set(key, got);
        out.push({ project, name, dois: got.parsed.dois, bad: got.parsed.bad });
      }
    });
  }
  if (cache) for (const k of [...cache.keys()]) if (!seen.has(k)) cache.delete(k);
  return out;
}

export const statusName = (requestName) => requestName.replace(/\.txt$/, '.tsv');

// The status file's current text, read through held descriptors; null if absent.
export const statusText = (papersRoot, project, requestName) =>
  withDir(papersRoot, [project, '_fetch', 'status'], (fd) => readSmallAt(fd, statusName(requestName), MAX_STATUS_BYTES));

// One status line (without its newline) -> {doi, status, host, date, library} if it
// re-renders byte for byte; null otherwise. (Also used by fetcherctl status.)
export function statusRecord(line) {
  const f = line.split('\t');
  if (f.length !== 5) return null;
  const rec = { doi: f[0], status: f[1], host: f[2] === '-' ? '' : f[2], date: f[3], library: f[4] };
  try {
    return statusLine(rec) === `${line}\n` ? rec : null;
  } catch {
    return null;                         // not ours
  }
}

// doi -> {status, host, date, library}, from lines that re-render exactly.
export function parseStatus(text) {
  const map = new Map();
  if (typeof text !== 'string') return map;
  for (const line of text.split('\n')) {
    const rec = statusRecord(line);
    if (rec && rec.status !== 'bad-request') map.set(rec.doi, rec);
  }
  return map;
}

export const pendingIn = (request, map) => request.dois.filter((d) => !TERMINAL(map.get(d)?.status));

// Path form (the final name is opened O_NOFOLLOW); the loop uses statusText instead.
export function pending(request, statusDir) {
  return pendingIn(request, parseStatus(readSmall(path.join(statusDir, statusName(request.name)), MAX_STATUS_BYTES)));
}

// The whole status file: one line per requested DOI that has a result, then one per bad line.
export function renderStatus(request, map, date) {
  let s = '';
  for (const doi of request.dois) if (map.has(doi)) s += statusLine({ ...map.get(doi), doi });
  for (const n of request.bad) s += statusLine({ doi: `line:${n}`, status: 'bad-request', host: '', date, library: 'no' });
  return s;
}
