import test from 'node:test';
import assert from 'node:assert/strict';
import { parseDoi, folderName } from '../lib/doi.mjs';

test('parseDoi trims and lower-cases', () => {
  assert.equal(parseDoi(' 10.1111/MEC.15060 '), '10.1111/mec.15060');
  assert.equal(parseDoi('10.1002/(SICI)1097-4571(199806)49:8<693::AID-ASI4>3.0.CO;2-O'),
    '10.1002/(sici)1097-4571(199806)49:8<693::aid-asi4>3.0.co;2-o');
});

test('parseDoi rejects anything that is not a plain DOI', () => {
  for (const bad of ['https://doi.org/10.1/x', '10.1111/a b', '10.1111/a@evil.com', '10.1111/a?x=1',
                     '10.1111/a#f', '10.1111/../x', '10.1111/a\\b', '11.1111/abc', '10.11/abc', '', '10.1111/',
                     '10.1111/a%2fb', '10.1111/a\nb', '10.1111/a\tb', '10.1111/a\0b', '10.1111/café',
                     '10.1111/K', '10.1111/a..b', '10.1111/.', '10.1111/a/./b', '10.1111/a/..',
                     '10.1111/' + 'a'.repeat(201), '10.1234567890/abc', ' ', '\n'])
    assert.equal(parseDoi(bad), null, JSON.stringify(bad));
});

test('parseDoi accepts the length limits', () => {
  assert.equal(parseDoi('10.1234/' + 'a'.repeat(200)), '10.1234/' + 'a'.repeat(200));
  assert.equal(parseDoi('10.123456789/a'), '10.123456789/a');
});

test('parseDoi rejects non-strings', () => {
  for (const bad of [undefined, null, 5, {}, ['10.1111/a']]) assert.equal(parseDoi(bad), null);
});

test('a parsed DOI placed after the resolver keeps host, path and no query or fragment', () => {
  const ok = ['10.1111/mec.15060', '10.1002/(sici)x<y>[z];a:b/c', '10.1/x'.replace('10.1', '10.1111')];
  for (const d of ok) {
    const u = new URL('https://doi.org/' + parseDoi(d));
    assert.equal(u.host, 'doi.org');
    assert.equal(u.search, '');
    assert.equal(u.hash, '');
    assert.ok(u.pathname.startsWith('/10.'));
  }
});

test('folderName', () => {
  assert.match(folderName('10.1016/j.tim.2018.11.003'), /^doi_10_1016_j_tim_2018_11_003_[0-9a-f]{8}$/);
  assert.notEqual(folderName('10.1/a.b'), folderName('10.1/a_b'));
  assert.equal(folderName('10.1/a.b'), folderName('10.1/a.b'));
  const long = folderName('10.1111/' + 'a'.repeat(200));
  assert.match(long, /^doi_[a-z0-9_]{1,100}_[0-9a-f]{8}$/);
  assert.equal(long.length, 'doi_'.length + 100 + 1 + 8);
  assert.match(folderName('10.1002/(sici)x<y>[z];a:b/c'), /^doi_[a-z0-9_]+_[0-9a-f]{8}$/);
});
