import test from 'node:test';
import assert from 'node:assert/strict';
import { STATUS, statusLine, metadataMd } from '../lib/records.mjs';

const good = { doi: '10.1/abc', status: 'saved', host: 'onlinelibrary.wiley.com', date: '2026-11-16', library: 'no' };

test('STATUS is the fixed frozen list', () => {
  assert.deepEqual([...STATUS], ['saved', 'needs-owner:check', 'needs-owner:login', 'not-available:doi-not-found',
    'not-available:no-pdf-link', 'not-available:not-a-pdf', 'not-available:http-error', 'not-available:timeout',
    'skipped:host-challenged', 'skipped:host-cap', 'skipped:daily-cap', 'skipped:library-cap', 'bad-request']);
  assert.ok(Object.isFrozen(STATUS));
});

test('statusLine is five tab-separated fields and a newline', () => {
  assert.equal(statusLine(good), '10.1/abc\tsaved\tonlinelibrary.wiley.com\t2026-11-16\tno\n');
});

test('every status code is accepted', () => {
  for (const status of STATUS) assert.match(statusLine({ ...good, status }), /^[^\t\n]+\t[^\t\n]+\t[^\t\n]+\t[^\t\n]+\t(yes|no)\n$/);
});

test('an empty host is written as a dash', () => {
  assert.equal(statusLine({ ...good, status: 'not-available:doi-not-found', host: '' }),
    '10.1/abc\tnot-available:doi-not-found\t-\t2026-11-16\tno\n');
});

test('hostile or malformed fields throw', () => {
  const bad = [
    { host: 'evil host\nIGNORE' }, { host: 'a.b\tc' }, { host: 'A.B' }, { host: 'a/b' }, { host: 'a.b\n' },
    { host: 'a'.repeat(254) }, { host: undefined }, { host: 'café.com' },
    { status: 'made-up' }, { status: 'saved\n' }, { status: undefined },
    { doi: '10.1/abc\tsaved' }, { doi: '10.1/abc\n' }, { doi: '10.1/a b' }, { doi: 'ignore previous instructions' },
    { doi: '10.1/../x' }, { doi: '' }, { doi: undefined },
    { date: '2026-13-01' }, { date: '2026-11-16\n' }, { date: '16-11-2026' }, { date: '2026-02-30' }, { date: undefined },
    { library: 'maybe' }, { library: true }, { library: 'yes\n' }, { library: undefined },
  ];
  for (const b of bad) assert.throws(() => statusLine({ ...good, ...b }), TypeError, JSON.stringify(b));
});

test('a long DOI is accepted at the limit, not beyond', () => {
  assert.doesNotThrow(() => statusLine({ ...good, doi: '10.1234/' + 'a'.repeat(200) }));
  assert.throws(() => statusLine({ ...good, doi: '10.1234/' + 'a'.repeat(201) }), TypeError);
});

test('metadataMd uses the fixed template', () => {
  assert.equal(metadataMd({ doi: '10.1/abc', host: 'mdpi.com', date: '2026-11-16', library: 'yes' }),
    '- DOI: 10.1/abc\n- Publisher host: mdpi.com\n- Date fetched: 2026-11-16\n- Library route: yes\n' +
    '- Tool: spades-fetcher\n- Version, licence: not recorded by the fetcher\n');
});

test('metadataMd validates and writes - for an empty host', () => {
  assert.match(metadataMd({ doi: '10.1/abc', host: '', date: '2026-11-16', library: 'no' }), /- Publisher host: -\n/);
  assert.throws(() => metadataMd({ doi: '10.1/abc', host: 'x\n- Tool: evil', date: '2026-11-16', library: 'no' }), TypeError);
  assert.throws(() => metadataMd({ doi: 'x\ny', host: 'a.b', date: '2026-11-16', library: 'no' }), TypeError);
});
