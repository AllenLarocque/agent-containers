// Files the fetcher writes are read by AI agents, so they are built only from
// validated values and a fixed template, never from page text.
import { parseDoi } from './doi.mjs';

export const STATUS = Object.freeze([
  'saved',
  'needs-owner:check',
  'needs-owner:login',
  'not-available:doi-not-found',
  'not-available:no-pdf-link',
  'not-available:not-a-pdf',
  'not-available:http-error',
  'not-available:timeout',
  'skipped:host-challenged',
  'skipped:host-cap',
  'skipped:daily-cap',
  'skipped:library-cap',
  'bad-request',
]);

const HOST = /^[a-z0-9.-]{1,253}$/;
const DATE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

function fail(name, value) {
  throw new TypeError(`invalid ${name}: ${JSON.stringify(value)}`);
}

// Exactly what parseDoi accepts (so already lower-case); one pattern for both.
function checkDoi(v) {
  if (parseDoi(v) !== v) fail('doi', v);
  return v;
}
// A rejected request line is never echoed: it is recorded by line number, and only
// together with the bad-request status (which in turn takes no real DOI).
const LINE_REF = /^line:[1-9][0-9]{0,3}$/;
function checkRef(v, status) {
  if (status === 'bad-request') {
    if (typeof v !== 'string' || !LINE_REF.test(v)) fail('doi', v);
    return v;
  }
  return checkDoi(v);
}
// An empty host (no landing page was reached) is written as "-".
function checkHost(v) {
  if (v === '') return '-';
  if (typeof v !== 'string' || !HOST.test(v)) fail('host', v);
  return v;
}
function checkDate(v) {
  if (typeof v !== 'string' || !DATE.test(v)) fail('date', v);
  const d = new Date(`${v}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== v) fail('date', v);
  return v;
}
function checkLibrary(v) {
  if (v !== 'yes' && v !== 'no') fail('library', v);
  return v;
}
function checkStatus(v) {
  if (!STATUS.includes(v)) fail('status', v);
  return v;
}

export function statusLine({ doi, status, host, date, library }) {
  checkStatus(status);
  return [checkRef(doi, status), status, checkHost(host), checkDate(date), checkLibrary(library)].join('\t') + '\n';
}

export function metadataMd({ doi, host, date, library }) {
  return [
    `- DOI: ${checkDoi(doi)}`,
    `- Publisher host: ${checkHost(host)}`,
    `- Date fetched: ${checkDate(date)}`,
    `- Library route: ${checkLibrary(library)}`,
    '- Tool: spades-fetcher',
    '- Version, licence: not recorded by the fetcher',
  ].join('\n') + '\n';
}
