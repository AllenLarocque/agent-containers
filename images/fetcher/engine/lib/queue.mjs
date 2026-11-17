// Request and status files. Everything under the papers root is writable by the research
// agent, so reads go through held directory descriptors (fs-util), refuse links and odd
// file types, sizes are capped, request lines must be DOIs, and status lines are only
// trusted if they re-render byte for byte.
import { parseDoi } from './doi.mjs';
import { statusLine } from './records.mjs';
import { withDir, listAt, readSmall, readSmallAt } from './fs-util.mjs';
import path from 'node:path';

export const REQUEST_NAME = /^[A-Za-z0-9._-]{1,80}\.txt$/;
const PROJECT = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,79}$/;
const MAX_LINES = 200;
const MAX_REF = 9999;                    // records.mjs accepts line:1 .. line:9999
export const MAX_REQUEST_BYTES = 64 * 1024;
const MAX_STATUS_BYTES = 1024 * 1024;
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

export function scanRequests(papersRoot) {
  const out = [];
  const projects = withDir(papersRoot, [], listAt) ?? [];
  for (const project of projects.sort()) {
    if (!PROJECT.test(project)) continue;
    withDir(papersRoot, [project, '_fetch', 'requests'], (fd) => {
      for (const name of listAt(fd).sort()) {
        if (!REQUEST_NAME.test(name)) continue;
        const text = readSmallAt(fd, name, MAX_REQUEST_BYTES);
        if (text !== null) out.push({ project, name, ...parseRequest(text) });
      }
    });
  }
  return out;
}

export const statusName = (requestName) => requestName.replace(/\.txt$/, '.tsv');

// The status file's current text, read through held descriptors; null if absent.
export const statusText = (papersRoot, project, requestName) =>
  withDir(papersRoot, [project, '_fetch', 'status'], (fd) => readSmallAt(fd, statusName(requestName), MAX_STATUS_BYTES));

// doi -> {status, host, date, library}, from lines that re-render exactly.
export function parseStatus(text) {
  const map = new Map();
  if (typeof text !== 'string') return map;
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
