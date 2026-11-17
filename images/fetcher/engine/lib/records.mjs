// Files the fetcher writes are read by AI agents, so they are built only from
// validated values and a fixed template, never from page text.

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

// DOI as requested (already lower-cased by parseDoi). The registrant is allowed to be
// short here because a status line only echoes a DOI; parseDoi decides what is fetched.
const DOI_FIELD = /^10\.[0-9]{1,9}\/[A-Za-z0-9._;()/:<>[\]-]{1,200}$/;
const HOST = /^[a-z0-9.-]{1,253}$/;
const DATE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

function fail(name, value) {
  throw new TypeError(`invalid ${name}: ${JSON.stringify(value)}`);
}

function checkDoi(v) {
  if (typeof v !== 'string' || !DOI_FIELD.test(v) || v.includes('..')) fail('doi', v);
  return v;
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
  return [checkDoi(doi), checkStatus(status), checkHost(host), checkDate(date), checkLibrary(library)].join('\t') + '\n';
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
